; =============================================================================
;  lxmm.asm - a Linux program's memory: its areas (VMAs) and the pages
;  under them, filled in when first touched
;
;  An address space (user.asm's AS_*) of a Linux program keeps its areas in
;  AS_VMAS: an array of VA_SIZE entries ordered by address, none
;  overlapping, each with its protection (PROT_*), whether it is shared, and
;  what it shows: zeroes (anonymous), or a file's bytes from an offset.
;  Nothing is mapped until it is touched: a page fault in an area fills the
;  page in (lx_fill), with a zeroed page of the program's own (PTE_OWN), or
;  the file's own page in the file cache (lxfs.asm), read-only, until the
;  program writes to it and gets a copy (copy on write). A page an area
;  does not allow is never filled in; a PROT_NONE page that was filled in
;  before stays, without PTE_U.
;
;  mmap, munmap, mprotect, mremap, madvise and brk change the areas and the
;  pages under them; pages taken away leave every CPU's TLB before they are
;  freed. The areas and pages are under the address space's AS_MMLOCK,
;  which a thread waiting for yields on (interrupts stay on): page faults,
;  the system calls here, and the kernel's copies to and from a program's
;  memory take it. The kernel never touches a program's pages at their user
;  addresses (SMAP): it walks the tables, filling pages in as a fault would,
;  and uses the direct map.
;
;    lx_copy_in(RDI = kernel dest, RSI = user source, RDX = bytes) -> RAX =
;      0 or -EFAULT; lx_copy_out(RDI = user dest, RSI = kernel source, RDX)
;    lx_zero_out(RDI = user dest, RSI = bytes) -> RAX = 0 or -EFAULT
;    lx_copy_str(RDI = kernel dest, RSI = user string, RDX = room) -> RAX =
;      its length, -EFAULT, or -ENAMETOOLONG
;    lx_get64(RDI = user address) -> RAX = 0 or -EFAULT, RDX = the qword
;    lx_put64(RDI = user address, RSI = qword), lx_put32 -> RAX = 0 / -EFAULT
;    lx_map(RDI = address space, RSI = start, RDX = bytes, ECX = prot, R8d =
;      VMF_*, R9 = a file's node or 0, [rsp + 8] = its offset) -> RAX = start
;      or -errno: an area exactly there, what was there gone
; =============================================================================

PROT_READ       equ 1
PROT_WRITE      equ 2
PROT_EXEC       equ 4
MAP_SHARED      equ 0x01
MAP_PRIVATE     equ 0x02
MAP_TYPE        equ 0x0F
MAP_FIXED       equ 0x10
MAP_ANONYMOUS   equ 0x20
MAP_32BIT       equ 0x40
MAP_FIXED_NOREPLACE equ 0x100000
MREMAP_MAYMOVE  equ 1
MREMAP_FIXED    equ 2
MADV_DONTNEED   equ 4
MADV_FREE       equ 8

; an area
VA_START        equ 0
VA_END          equ 8
VA_NODE         equ 16                  ; the file it shows (lxfs.asm), 0 if zeroes
VA_OFF          equ 24                  ; the file's offset at VA_START
VA_PROT         equ 32                  ; dword PROT_*
VA_FLAGS        equ 36                  ; dword VMF_*
VA_SIZE         equ 40
VMF_SHARED      equ 1                   ; writes reach the file, not a copy
VMF_STACK       equ 2                   ; the first thread's stack
VMF_HEAP        equ 4                   ; the break's

LX_MMAP_TOP     equ 0x7FFFF7FFF000      ; mmap places areas down from here
LX_MMAP_LOW     equ 0x10000             ; and never below
LX_32_LOW       equ 0x40000000          ; MAP_32BIT: in [1 GiB, 2 GiB)
LX_32_TOP       equ 0x80000000
LX_STACK_TOP    equ 0x7FFFFFFFF000      ; the first thread's stack is below
LX_STACK_SIZE   equ 8 << 20

; what an access is (lx_fill)
LXA_WRITE       equ 1
LXA_EXEC        equ 2
LXA_FORCE       equ 4                   ; the kernel's own: whatever the area allows

LX_ZAP_BATCH    equ 64                  ; pages freed at once, after a shootdown

section .text

; -----------------------------------------------------------------------------
;  The lock, and the tables
; -----------------------------------------------------------------------------

; mm_lock(RDI = address space) / mm_unlock(RDI). Preserve all.
mm_lock:
    push rax
.try:
    mov eax, 1
    xchg eax, [rdi + AS_MMLOCK]
    test eax, eax
    jz .taken
    call yield_all
    jmp .try
.taken:
    pop rax
    ret

mm_unlock:
    mov dword [rdi + AS_MMLOCK], 0
    ret

; yield_all: thread_yield, preserving all
yield_all:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call thread_yield
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; as_pte_get(RDI = address space, RSI = a user address) -> RAX = where the
; direct map has its PTE, or 0 if a table above it is missing; then RDX =
; the next address a table could hold (all between is unmapped). Preserves
; others.
as_pte_get:
    push rcx
    mov rax, [rdi + AS_PML4]
    mov ecx, 39
.level:
    mov rdx, rsi
    shr rdx, cl
    and edx, 511
    lea rax, [rax + rdx * 8]
    cmp ecx, 12
    je .found
    mov rdx, [rax]
    test dl, PTE_P
    jz .missing
    and rdx, [vmm_addr_mask]
    add rdx, [phys_base]
    mov rax, rdx
    sub ecx, 9
    jmp .level
.found:
    pop rcx
    ret
.missing:
    mov edx, 1                          ; the end of what that entry covers
    shl rdx, cl
    dec rdx
    or rdx, rsi
    inc rdx
    xor eax, eax
    pop rcx
    ret

; lx_pte_flags(EDI = PROT_*) -> RAX = the flags of a page of the program's
; own in an area with that protection (PROT_NONE: present, but not for
; ring 3). Preserves others.
lx_pte_flags:
    mov eax, PTE_P | PTE_A
    test edi, PROT_READ | PROT_WRITE | PROT_EXEC
    jz .nx
    or eax, PTE_U
    test edi, PROT_WRITE
    jz .exec
    or eax, PTE_W | PTE_D
.exec:
    test edi, PROT_EXEC
    jnz .out
.nx:
    or rax, [vmm_nx]
.out:
    ret

; lx_flush(RDI = address space, RSI = first page, RDX = pages): every CPU
; forgets them. A program with one thread whose tables are this CPU's only
; needs this CPU's TLB. No spinlock held. Preserves all.
lx_flush:
    test rdx, rdx
    jz .out
    push rax
    push rcx
    push rsi
    push rdi
    mov rax, [rdi + AS_CR3]
    cmp rax, [gs:PC_CR3]
    jne .all
    cmp dword [rdi + AS_REFS], 0
    jne .all
    mov rax, [gs:PC_CURRENT]
    mov rax, [rax + TH_TASK]
    cmp dword [rax + TK_THREADS], 1
    ja .all
    cmp rdx, TLB_ALL_OVER
    ja .reload
    mov rcx, rdx
.page:
    invlpg [rsi]
    add rsi, 4096
    dec rcx
    jnz .page
    jmp .done
.reload:
    mov rax, cr3
    mov cr3, rax
    jmp .done
.all:
    mov rdi, rsi
    mov rsi, rdx
    call tlb_shootdown
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
.out:
    ret

; lx_page_new -> RAX = a zeroed page of a program's own (physical), 0 if
; there is none. Preserves others.
lx_page_new:
    push rdi
    mov edi, 1
    call pmm_alloc_zero
    pop rdi
    test rax, rax
    jz .out
    lock inc qword [user_pages]
.out:
    ret

; lx_page_copy(RSI = a page, physical) -> RAX = a page of the program's own
; with what it holds, 0 if there is none. Preserves others.
lx_page_copy:
    push rcx
    push rsi
    push rdi
    push rdi
    mov edi, 1
    call pmm_alloc
    pop rdi
    test rax, rax
    jz .out
    lock inc qword [user_pages]
    mov rdi, rax
    add rdi, [phys_base]
    add rsi, [phys_base]
    mov ecx, 512
    rep movsq
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; lx_page_free(RDI = a page of a program's own, physical). Preserves all.
lx_page_free:
    push rsi
    mov esi, 1
    call pmm_free
    pop rsi
    lock dec qword [user_pages]
    ret

; -----------------------------------------------------------------------------
;  Areas
; -----------------------------------------------------------------------------

; vma_find(RDI = address space, RSI = address) -> RAX = the area holding it,
; or 0; RDX = the index of the first area ending above it. Preserves others.
vma_find:
    push rcx
    push r8
    xor ecx, ecx                        ; [RCX, R8): where it may be
    mov r8d, [rdi + AS_NVMA]
.half:
    cmp rcx, r8
    jae .found
    lea rdx, [rcx + r8]
    shr rdx, 1
    imul rax, rdx, VA_SIZE
    add rax, [rdi + AS_VMAS]
    cmp [rax + VA_END], rsi
    ja .left
    lea rcx, [rdx + 1]
    jmp .half
.left:
    mov r8, rdx
    jmp .half
.found:
    mov rdx, rcx
    xor eax, eax
    cmp edx, [rdi + AS_NVMA]
    jae .out
    imul rax, rdx, VA_SIZE
    add rax, [rdi + AS_VMAS]
    cmp [rax + VA_START], rsi
    jbe .out
    xor eax, eax
.out:
    pop r8
    pop rcx
    ret

; vma_at(RDI = address space, EDX = index) -> RAX = that area. Preserves others.
vma_at:
    push rdx
    mov edx, edx
    imul rax, rdx, VA_SIZE
    add rax, [rdi + AS_VMAS]
    pop rdx
    ret

; vma_room(RDI = address space, ESI = more) -> CF if there is no memory:
; room for that many more areas. Preserves all but RAX.
vma_room:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov eax, [rdi + AS_NVMA]
    add eax, esi
    cmp eax, [rdi + AS_VCAP]
    jbe .ok
    mov r8, rdi
    mov edx, [rdi + AS_VCAP]            ; twice as many, at least a page's
    add edx, edx
    cmp edx, eax
    cmovb edx, eax
    imul rdi, rdx, VA_SIZE
    add rdi, 4095
    and rdi, -4096
    push rdi
    call vm_alloc
    pop rcx
    test rax, rax
    jz .nomem
    mov [r8 + AS_VBYTES], rcx
    push rax
    xor edx, edx                        ; how many fit
    mov rax, rcx
    mov ecx, VA_SIZE
    div rcx
    mov [r8 + AS_VCAP], eax
    pop rax
    mov rsi, [r8 + AS_VMAS]
    mov [r8 + AS_VMAS], rax
    test rsi, rsi
    jz .ok
    push rsi
    mov rdi, rax
    mov eax, [r8 + AS_NVMA]
    imul ecx, eax, VA_SIZE
    rep movsb
    pop rdi
    call vm_free
.ok:
    clc
    jmp .out
.nomem:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; vma_insert(RDI = address space, EDX = index, RSI = an area to copy in) ->
; CF if there is no memory. Preserves all but RAX.
vma_insert:
    push rcx
    push rsi
    push rdi
    push r8
    push rsi
    mov esi, 1
    call vma_room
    pop rsi
    jc .out
    mov r8, rdi
    push rsi
    mov eax, [r8 + AS_NVMA]             ; those from there on, one up
    sub eax, edx
    imul ecx, eax, VA_SIZE
    mov eax, [r8 + AS_NVMA]
    imul rsi, rax, VA_SIZE
    add rsi, [r8 + AS_VMAS]
    lea rdi, [rsi + VA_SIZE - 1]
    dec rsi
    std
    rep movsb
    cld
    pop rsi
    mov rdi, r8
    call vma_at
    mov rdi, rax
    mov ecx, VA_SIZE
    rep movsb
    inc dword [r8 + AS_NVMA]
    clc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

; vma_delete(RDI = address space, EDX = index). Preserves all.
vma_delete:
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    call vma_at
    mov rdi, rax
    lea rsi, [rax + VA_SIZE]
    mov eax, [r8 + AS_NVMA]
    sub eax, edx
    dec eax
    imul ecx, eax, VA_SIZE
    rep movsb
    dec dword [r8 + AS_NVMA]
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; vma_split(RDI = address space, EDX = index, RSI = an address inside it,
; on a page) -> CF if there is no memory: two areas, meeting there.
; Preserves all but RAX.
vma_split:
    push rcx
    push rdx
    push rsi
    push r8
    sub rsp, VA_SIZE
    mov r8, rsi
    call vma_at
    mov rcx, [rax + VA_START]           ; the second half: a copy, from there
    push rdi
    lea rdi, [rsp + 8]
    mov rsi, rax
    push rcx
    mov ecx, VA_SIZE
    rep movsb
    pop rcx
    pop rdi
    mov [rsp + VA_START], r8
    mov rax, r8
    sub rax, rcx
    add [rsp + VA_OFF], rax
    inc edx
    mov rsi, rsp
    call vma_insert
    jc .out
    dec edx                             ; and the first ends there
    call vma_at
    mov [rax + VA_END], r8
    clc
.out:
    lea rsp, [rsp + VA_SIZE]
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; vma_mergeable(RAX = an area, RCX = the next one) -> ZF if they can be one:
; touching, alike, and a file's offsets running on. Preserves all.
vma_mergeable:
    push rdx
    mov rdx, [rax + VA_END]
    cmp rdx, [rcx + VA_START]
    jne .out
    mov edx, [rax + VA_PROT]
    cmp edx, [rcx + VA_PROT]
    jne .out
    mov edx, [rax + VA_FLAGS]
    cmp edx, [rcx + VA_FLAGS]
    jne .out
    mov rdx, [rax + VA_NODE]
    cmp rdx, [rcx + VA_NODE]
    jne .out
    test rdx, rdx
    jz .out                             ; zeroes: offsets mean nothing (ZF)
    mov rdx, [rax + VA_END]
    sub rdx, [rax + VA_START]
    add rdx, [rax + VA_OFF]
    cmp rdx, [rcx + VA_OFF]
.out:
    pop rdx
    ret

; vma_merge(RDI = address space, EDX = index): it and the one after it
; become one if they can. Preserves all.
vma_merge:
    push rax
    push rcx
    push rdx
    lea eax, [edx + 1]
    cmp eax, [rdi + AS_NVMA]
    jae .out
    call vma_at
    lea rcx, [rax + VA_SIZE]
    call vma_mergeable
    jne .out
    mov rcx, [rcx + VA_END]
    mov [rax + VA_END], rcx
    inc edx
    call vma_delete
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; vma_merge_around(RDI = address space, RSI = start, RDX = end): areas
; touching that range merge with their neighbours where they can.
; Preserves all.
vma_merge_around:
    push rax
    push rcx
    push rdx
    push r8
    mov r8, rdx
    test rsi, rsi
    jz .from
    dec rsi
    call vma_find                       ; RDX = the first ending above start - 1
    inc rsi
.next:
    cmp edx, [rdi + AS_NVMA]
    jae .out
    call vma_at
    cmp [rax + VA_START], r8
    ja .out
    push rdx
    call vma_merge
    pop rdx
    call vma_at                         ; merged into it: try it again
    lea rcx, [rax + VA_SIZE]
    push rcx
    lea ecx, [edx + 1]
    cmp ecx, [rdi + AS_NVMA]
    pop rcx
    jae .out
    call vma_mergeable
    je .next
    inc edx
    jmp .next
.from:
    xor edx, edx
    jmp .next
.out:
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; vma_free_range(RDI = address space, RSI = start, RDX = end) -> CF if the
; range is not free (some area overlaps it). Preserves all but RAX.
vma_free_range:
    push rdx
    push r8
    mov r8, rdx
    call vma_find
    test rax, rax
    jnz .taken
    cmp edx, [rdi + AS_NVMA]
    jae .free
    call vma_at
    cmp [rax + VA_START], r8
    jb .taken
.free:
    clc
    jmp .out
.taken:
    stc
.out:
    pop r8
    pop rdx
    ret

; vma_gap(RDI = address space, RSI = bytes, RDX = top, RCX = low) -> RAX =
; the highest start below the top for that many bytes no area holds, or 0.
; Preserves others.
vma_gap:
    push rbx
    push rdx
    push r8
    push r9
    mov r8, rdx                         ; R8 = the gap's end, falling
    mov r9d, [rdi + AS_NVMA]
.area:
    test r9d, r9d
    jz .last
    dec r9d
    imul rax, r9, VA_SIZE
    add rax, [rdi + AS_VMAS]
    mov rbx, [rax + VA_START]
    cmp rbx, r8
    jae .area                           ; above the window
    mov rdx, [rax + VA_END]
    cmp rdx, r8
    jae .inside                         ; across its end
    mov rbx, r8                         ; the gap [end, R8)
    sub rbx, rdx
    cmp rbx, rsi
    jae .fits
    mov rbx, [rax + VA_START]
.inside:
    mov r8, rbx
    cmp r8, rcx
    jbe .none
    jmp .area
.fits:
    mov rax, r8
    sub rax, rsi
    cmp rax, rcx
    jb .none
    jmp .out
.last:
    mov rax, r8
    sub rax, rcx
    jb .none
    cmp rax, rsi
    jb .none
    mov rax, r8
    sub rax, rsi
    jmp .out
.none:
    xor eax, eax
.out:
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Pages: filled in, taken away, changed
; -----------------------------------------------------------------------------

; lx_fill(RDI = address space, AS_MMLOCK held, RSI = address, EDX = LXA_*)
; -> RAX = 0 once the page is there as the access needs it, or -EFAULT (no
; area allows it), -ENOMEM
lx_fill:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    and r12, -4096
    mov r13d, edx
    call vma_find
    test rax, rax
    jz .fault
    mov r14, rax                        ; R14 = the area
    mov r15d, [r14 + VA_PROT]
    test r13d, LXA_FORCE
    jnz .allowed
    test r15d, PROT_READ | PROT_WRITE | PROT_EXEC
    jz .fault
    test r13d, LXA_WRITE
    jz .exec
    test r15d, PROT_WRITE
    jz .fault
.exec:
    test r13d, LXA_EXEC
    jz .allowed
    test r15d, PROT_EXEC
    jz .fault
.allowed:
    mov rdi, rbx
    mov rsi, r12
    call as_pte
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; RBP = the PTE
    mov edi, r15d
    call lx_pte_flags                   ; RAX = the flags for a page of its own
    mov rcx, [rbp]
    test cl, PTE_P
    jnz .present
    mov rdx, [r14 + VA_NODE]
    test rdx, rdx
    jz .zeroes
    mov rsi, r12                        ; the file's offset
    sub rsi, [r14 + VA_START]
    add rsi, [r14 + VA_OFF]
    mov rdi, [rdx + LN_SIZE]
    add rdi, 4095
    and rdi, -4096
    cmp rsi, rdi
    jae .zeroes                         ; past its end
    push rax
    mov rdi, [rdx + LN_DATA]
    add rdi, rsi
    call vmm_translate                  ; the cache's page
    mov rsi, rax
    pop rax
    test dword [r14 + VA_FLAGS], VMF_SHARED
    jnz .file_shared
    test r13d, LXA_WRITE
    jnz .file_copy
.file_page:                             ; the file's own page, read-only
    and rax, ~(PTE_W | PTE_D)
    or rax, rsi
    mov [rbp], rax
    jmp .done
.file_shared:                           ; writable too, if the file is
    test byte [rdx + LN_WRITABLE], 1
    jz .file_page
    or rax, rsi
    mov [rbp], rax
    jmp .done
.file_copy:
    push rax
    call lx_page_copy
    mov rcx, rax
    pop rax
    test rcx, rcx
    jz .nomem
    or rax, rcx
    or rax, PTE_OWN
    mov [rbp], rax
    jmp .done
.zeroes:
    mov rcx, rax
    call lx_page_new
    test rax, rax
    jz .nomem
    or rax, rcx
    or rax, PTE_OWN
    mov [rbp], rax
    jmp .done

.present:                               ; there: as it should be, or written now
    test cl, PTE_U
    jz .reflag                          ; (PROT_NONE before)
    test r13d, LXA_WRITE
    jz .done
    test cl, PTE_W
    jnz .done
.reflag:
    test ecx, PTE_OWN
    jnz .own
    test r13d, LXA_WRITE                ; the file's page, to be written: a copy
    jz .file_ro
    test r13d, LXA_FORCE
    jnz .copy
    mov rdx, [r14 + VA_NODE]
    test dword [r14 + VA_FLAGS], VMF_SHARED
    jz .copy
    test rdx, rdx
    jz .copy
    test byte [rdx + LN_WRITABLE], 1
    jnz .file_rw
.copy:
    mov rsi, rcx
    and rsi, [vmm_addr_mask]
    push rax
    call lx_page_copy
    mov rcx, rax
    pop rax
    test rcx, rcx
    jz .nomem
    or rax, rcx
    or rax, PTE_OWN
    jmp .changed
.file_ro:
    and rax, ~(PTE_W | PTE_D)
.file_rw:
    and rcx, [vmm_addr_mask]
    or rax, rcx
    jmp .changed
.own:
    and rcx, [vmm_addr_mask]
    or rax, rcx
    or rax, PTE_OWN
.changed:
    mov [rbp], rax
    mov rdi, rbx
    mov rsi, r12
    mov edx, 1
    call lx_flush
.done:
    xor eax, eax
    jmp .out
.nomem:
    mov rax, -ENOMEM
    jmp .out
.fault:
    mov rax, -EFAULT
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_ptr(RDI = address space, AS_MMLOCK held, RSI = user address, EDX =
; LXA_*) -> RAX = where the direct map has that byte, 0 if the program may
; not touch it so. Preserves others.
lx_ptr:
    push rcx
    push rdx
    push r8
    mov r8d, edx
    mov rax, USER_TOP
    cmp rsi, rax
    jae .no
    mov ecx, 2                          ; the walk, then once more after a fill
.walk:
    push rdx
    call as_pte_get
    pop rdx
    test rax, rax
    jz .fill
    mov rax, [rax]
    test al, PTE_P
    jz .fill
    test r8d, LXA_FORCE
    jz .user
    test r8d, LXA_WRITE                 ; the kernel's own write: to a page of
    jz .ok                              ; the program's own
    test eax, PTE_OWN
    jz .fill
    jmp .ok
.user:
    test al, PTE_U
    jz .fill
    test r8d, LXA_WRITE
    jz .ok
    test al, PTE_W
    jz .fill
.ok:
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    mov rdx, rsi
    and edx, 0xFFF
    add rax, rdx
    jmp .out
.fill:
    dec ecx
    jz .no
    push rcx
    push rsi
    push rdi
    mov edx, r8d
    call lx_fill
    pop rdi
    pop rsi
    pop rcx
    test rax, rax
    jz .walk
.no:
    xor eax, eax
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; lx_zap(RDI = address space, AS_MMLOCK held, RSI = start, RDX = end, both
; on pages): no page there any more; the program's own freed once no TLB
; has them
lx_zap:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, LX_ZAP_BATCH * 8
    mov rbx, rdi
    mov r12, rsi                        ; R12 = where we are
    mov r13, rdx
    mov r14, rsi                        ; R14 = from where pages went, unflushed
    xor ebp, ebp                        ; RBP = pages to free
    xor r15d, r15d                      ; R15 = 1 once one went
.page:
    cmp r12, r13
    jae .end
    mov rdi, rbx
    mov rsi, r12
    call as_pte_get
    test rax, rax
    jz .skip
    mov rcx, [rax]
    test cl, PTE_P
    jz .next
    mov qword [rax], 0
    mov r15d, 1
    test ecx, PTE_OWN
    jz .next
    and rcx, [vmm_addr_mask]
    mov [rsp + rbp * 8], rcx
    inc ebp
    cmp ebp, LX_ZAP_BATCH
    jb .next
    lea rdx, [r12 + 4096]               ; full: flush and free them
    call .free
.next:
    add r12, 4096
    jmp .page
.skip:
    mov r12, rdx
    jmp .page
.end:
    mov rdx, r13
    call .free
    add rsp, LX_ZAP_BATCH * 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.free:                                  ; RDX = the end of what went
    test r15d, r15d
    jz .freed
    mov rdi, rbx
    mov rsi, r14
    cmp rdx, r13
    cmova rdx, r13
    sub rdx, r14
    shr rdx, 12
    call lx_flush
    mov r14, r12
    add r14, 4096
    xor r15d, r15d
.each:
    test ebp, ebp
    jz .freed
    dec ebp
    mov rdi, [rsp + 8 + rbp * 8]        ; (past .free's return address)
    call lx_page_free
    jmp .each
.freed:
    ret

; lx_reprotect(RDI = address space, AS_MMLOCK held, RSI = start, RDX = end,
; ECX = PROT_*): the pages there as an area with that protection has them
lx_reprotect:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rsi
    mov edi, ecx
    call lx_pte_flags
    mov rbp, rax                        ; RBP = the flags
    xor r15d, r15d
.page:
    cmp r12, r13
    jae .end
    mov rdi, rbx
    mov rsi, r12
    call as_pte_get
    test rax, rax
    jz .skip
    mov rcx, [rax]
    test cl, PTE_P
    jz .next
    mov rdx, rcx
    and rdx, [vmm_addr_mask]
    or rdx, rbp
    test ecx, PTE_OWN
    jz .theirs
    or rdx, PTE_OWN
    jmp .set
.theirs:                                ; a file's page stays read-only
    and rdx, ~(PTE_W | PTE_D)
.set:
    mov [rax], rdx
    mov r15d, 1
.next:
    add r12, 4096
    jmp .page
.skip:
    mov r12, rdx
    jmp .page
.end:
    test r15d, r15d
    jz .out
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r13
    sub rdx, r14
    shr rdx, 12
    call lx_flush
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_unmap(RDI = address space, AS_MMLOCK held, RSI = start, RDX = end, on
; pages) -> RAX = 0, or -ENOMEM: no area there any more, nor any page
lx_unmap:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov esi, 2                          ; at most two splits
    call vma_room
    jc .nomem
    mov rsi, r12
    call vma_find
    test rax, rax
    jz .whole
    cmp [rax + VA_START], r12
    jae .whole
    mov rsi, r12                        ; it starts before: split there
    call vma_split
    inc edx
.whole:
    cmp edx, [rbx + AS_NVMA]
    jae .zap
    mov rdi, rbx
    call vma_at
    cmp [rax + VA_START], r13
    jae .zap
    cmp [rax + VA_END], r13
    jbe .drop
    mov rsi, r13                        ; it ends after: split there
    call vma_split
.drop:
    call vma_delete
    jmp .whole
.zap:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call lx_zap
    xor eax, eax
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_map_locked(RDI = address space, AS_MMLOCK held, RSI = start, RDX =
; bytes, ECX = prot, R8d = VMF_*, R9 = node, R10 = offset) -> RAX = start or
; -errno: an area exactly there, what was there before gone
lx_map_locked:
    push rbx
    push r12
    sub rsp, VA_SIZE
    mov rbx, rdi
    mov r12, rsi
    mov [rsp + VA_START], rsi
    add rdx, rsi
    mov [rsp + VA_END], rdx
    mov [rsp + VA_PROT], ecx
    mov [rsp + VA_FLAGS], r8d
    mov [rsp + VA_NODE], r9
    mov [rsp + VA_OFF], r10
    call lx_unmap
    test rax, rax
    jnz .out
    mov rdi, rbx
    mov rsi, r12
    call vma_find                       ; EDX = where it goes
    mov rsi, rsp
    call vma_insert
    jc .nomem
    mov rsi, [rsp + VA_START]
    mov rdx, [rsp + VA_END]
    call vma_merge_around
    mov rax, r12
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    mov rdi, rbx
    add rsp, VA_SIZE
    pop r12
    pop rbx
    ret

lx_map:
    push r10
    mov r10, [rsp + 16]
    call mm_lock
    call lx_map_locked
    call mm_unlock
    pop r10
    ret

; -----------------------------------------------------------------------------
;  Copies to and from a program's memory (the current task's)
; -----------------------------------------------------------------------------

; lx_cur_as -> RAX = the current task's address space. Preserves others.
lx_cur_as:
    mov rax, [gs:PC_CURRENT]
    mov rax, [rax + TH_TASK]
    mov rax, [rax + TK_AS]
    ret

; lx_copy(RDI = address space, RSI = user address, RDX = kernel address,
; RCX = bytes, R8d = LXA_WRITE to the program, 0 from it) -> RAX = 0 or
; -EFAULT
lx_copy:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    call mm_lock
.page:
    test r14, r14
    jz .done
    mov rdi, rbx
    mov rsi, r12
    mov edx, r15d
    call lx_ptr
    test rax, rax
    jz .fault
    mov ecx, r12d                       ; to the end of this page, at most
    and ecx, 0xFFF
    neg ecx
    add ecx, 4096
    cmp rcx, r14
    cmova rcx, r14
    add r12, rcx
    sub r14, rcx
    mov rsi, r13
    mov rdi, rax
    test r15d, LXA_WRITE
    jnz .move
    xchg rsi, rdi
.move:
    add r13, rcx
    rep movsb
    jmp .page
.done:
    xor eax, eax
    jmp .out
.fault:
    mov rax, -EFAULT
.out:
    mov rdi, rbx
    call mm_unlock
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

lx_copy_in:
    mov rcx, rdx
    mov rdx, rdi
    xor r8d, r8d
    jmp lx_copy_cur

lx_copy_out:
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov r8d, LXA_WRITE
lx_copy_cur:
    call lx_cur_as
    mov rdi, rax
    jmp lx_copy

; lx_zero_out(RDI = user dest, RSI = bytes) -> RAX = 0 or -EFAULT
lx_zero_out:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
.page:
    test r13, r13
    jz .done
    mov rdi, rbx
    mov rsi, r12
    mov edx, LXA_WRITE
    call lx_ptr
    test rax, rax
    jz .fault
    mov ecx, r12d
    and ecx, 0xFFF
    neg ecx
    add ecx, 4096
    cmp rcx, r13
    cmova rcx, r13
    add r12, rcx
    sub r13, rcx
    mov rdi, rax
    xor eax, eax
    rep stosb
    jmp .page
.done:
    xor eax, eax
    jmp .out
.fault:
    mov rax, -EFAULT
.out:
    mov rdi, rbx
    call mm_unlock
    pop r13
    pop r12
    pop rbx
    ret

; lx_copy_str: see the top
lx_copy_str:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                        ; R12 = where it goes
    mov r13, rsi                        ; R13 = where it is
    mov r14, rdx                        ; R14 = room left
    xor r15d, r15d                      ; R15 = its length so far
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
.page:
    mov rdi, rbx
    mov rsi, r13
    xor edx, edx
    call lx_ptr
    test rax, rax
    jz .fault
    mov ecx, r13d
    and ecx, 0xFFF
    neg ecx
    add ecx, 4096
.byte:
    test r14, r14
    jz .long
    mov dl, [rax]
    mov [r12 + r15], dl
    test dl, dl
    jz .done
    inc rax
    inc r13
    inc r15
    dec r14
    dec ecx
    jnz .byte
    jmp .page
.done:
    mov rax, r15
    jmp .out
.long:
    mov rax, -ENAMETOOLONG
    jmp .out
.fault:
    mov rax, -EFAULT
.out:
    mov rdi, rbx
    call mm_unlock
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

lx_get64:
    sub rsp, 8
    mov rsi, rdi
    mov rdi, rsp
    mov edx, 8
    call lx_copy_in
    pop rdx
    ret

lx_put64:
    push rsi
    mov rsi, rsp
    mov edx, 8
    call lx_copy_out
    pop rsi
    ret

lx_put32:
    push rsi
    mov rsi, rsp
    mov edx, 4
    call lx_copy_out
    pop rsi
    ret

; -----------------------------------------------------------------------------
;  The page fault, and the system calls
; -----------------------------------------------------------------------------

; lx_page_fault(RDI = frame, R12 = CR2) -> CF if no area allows it
lx_page_fault:
    push rbx
    mov rax, [rdi + FR_ERROR]
    xor edx, edx
    test eax, 1 << 1
    jz .fetch
    or edx, LXA_WRITE
.fetch:
    test eax, 1 << 4
    jz .access
    or edx, LXA_EXEC
.access:
    test eax, 1 << 3                    ; a reserved bit: never ours
    jnz .no
    call lx_cur_as
    mov rbx, rax
    mov rdi, rax
    mov rsi, r12
    call mm_lock
    call lx_fill
    mov rdi, rbx
    call mm_unlock
    test rax, rax
    jnz .no
    clc
    jmp .out
.no:
    stc
.out:
    pop rbx
    ret

; mmap(addr, length, prot, flags, fd, offset)
lx_sys_mmap:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r12, rdi                        ; R12 = the address asked for
    mov rax, -EINVAL
    test rsi, rsi
    jz .out
    lea r13, [rsi + 4095]               ; R13 = bytes
    and r13, -4096
    jz .nomem_out
    mov rax, USER_TOP
    cmp r13, rax
    ja .nomem_out
    mov r14d, edx                       ; R14 = prot
    and r14d, PROT_READ | PROT_WRITE | PROT_EXEC
    mov r15d, ecx                       ; R15 = flags
    mov rbp, r9                         ; RBP = the offset
    mov rax, -EINVAL
    test ebp, 0xFFF
    jnz .out
    mov eax, r15d
    and eax, MAP_TYPE
    cmp eax, MAP_SHARED
    jb .einval
    cmp eax, MAP_PRIVATE + MAP_SHARED
    ja .einval
    xor ebx, ebx                        ; RBX = the file's node, or 0
    test r15d, MAP_ANONYMOUS
    jnz .placed_file
    mov edi, r8d
    call lx_fd_node                     ; a regular file open for reading
    cmp rax, -4095
    jae .out
    mov rbx, rax
    test r15d, MAP_SHARED
    jz .loaded
    test r14d, PROT_WRITE
    jz .loaded
    test byte [rbx + LN_WRITABLE], 1
    mov rax, -EACCES
    jz .out
.loaded:
    mov rdi, rbx
    call lx_file_data                   ; its bytes, in the cache
    cmp rax, -4095
    jae .out
.placed_file:
    call lx_cur_as
    mov rdi, rax
    call mm_lock
    test r15d, MAP_FIXED | MAP_FIXED_NOREPLACE
    jz .anywhere
    mov rax, -EINVAL
    test r12d, 0xFFF
    jnz .unlock
    mov rcx, USER_TOP
    sub rcx, r13
    cmp r12, rcx
    ja .unlock
    test r15d, MAP_FIXED
    jnz .there
    mov rsi, r12
    lea rdx, [r12 + r13]
    call vma_free_range
    mov rax, -EEXIST
    jc .unlock
    jmp .there
.anywhere:
    test r12, r12                       ; a hint: there, if it is free
    jz .gap
    and r12, -4096
    cmp r12, LX_MMAP_LOW
    jb .gap
    mov rcx, USER_TOP
    sub rcx, r13
    cmp r12, rcx
    ja .gap
    mov rsi, r12
    lea rdx, [r12 + r13]
    call vma_free_range
    jnc .there
.gap:
    mov rsi, r13
    mov rdx, LX_MMAP_TOP
    mov ecx, LX_MMAP_LOW
    test r15d, MAP_32BIT
    jz .find
    mov edx, LX_32_TOP
    mov ecx, LX_32_LOW
.find:
    call vma_gap
    mov r12, rax
    mov rax, -ENOMEM
    test r12, r12
    jz .unlock
.there:
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    xor r8d, r8d
    test r15d, MAP_SHARED
    jz .private
    test rbx, rbx
    jz .private                         ; shared zeroes: as private, for now
    mov r8d, VMF_SHARED
.private:
    mov r9, rbx
    mov r10, rbp
    call lx_map_locked
.unlock:
    call mm_unlock
    jmp .out
.einval:
    mov rax, -EINVAL
    jmp .out
.nomem_out:
    mov rax, -ENOMEM
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; munmap(addr, length)
lx_sys_munmap:
    mov rax, -EINVAL
    test edi, 0xFFF
    jnz .out
    test rsi, rsi
    jz .out
    lea rdx, [rdi + rsi + 4095]
    and rdx, -4096
    mov rcx, USER_TOP
    cmp rdx, rcx
    ja .out
    cmp rdx, rdi
    jbe .out
    mov rsi, rdi
    call lx_cur_as
    mov rdi, rax
    push rdi
    call mm_lock
    call lx_unmap
    pop rdi
    call mm_unlock
.out:
    ret

; mprotect(addr, length, prot)
lx_sys_mprotect:
    push rbx
    push r12
    push r13
    push r14
    mov rax, -EINVAL
    test edi, 0xFFF
    jnz .out
    mov r12, rdi
    lea r13, [rdi + rsi + 4095]
    and r13, -4096
    mov rcx, USER_TOP
    cmp r13, rcx
    ja .out
    xor eax, eax
    cmp r13, r12
    jbe .out
    mov r14d, edx
    and r14d, PROT_READ | PROT_WRITE | PROT_EXEC
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
    mov esi, 2
    call vma_room
    jc .nomem
    mov rsi, r12                        ; all of it in areas?
.covered:
    cmp rsi, r13
    jae .split
    call vma_find
    test rax, rax
    jz .nomem
    mov rsi, [rax + VA_END]
    jmp .covered
.split:
    mov rsi, r12
    call vma_find
    cmp [rax + VA_START], r12
    jae .each
    call vma_split
    inc edx
.each:
    cmp edx, [rbx + AS_NVMA]
    jae .pages
    call vma_at
    cmp [rax + VA_START], r13
    jae .pages
    cmp [rax + VA_END], r13
    jbe .set
    mov rsi, r13
    call vma_split
    call vma_at
.set:
    mov [rax + VA_PROT], r14d
    inc edx
    jmp .each
.pages:
    mov rsi, r12
    mov rdx, r13
    mov ecx, r14d
    call lx_reprotect
    mov rsi, r12
    mov rdx, r13
    call vma_merge_around
    xor eax, eax
    jmp .unlock
.nomem:
    mov rax, -ENOMEM
.unlock:
    mov rdi, rbx
    call mm_unlock
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; madvise(addr, length, advice): MADV_DONTNEED and MADV_FREE drop the pages
; (zeroes, or the file's bytes, when touched again); the rest are hints
lx_sys_madvise:
    xor eax, eax
    cmp edx, MADV_DONTNEED
    je .drop
    cmp edx, MADV_FREE
    jne .out
.drop:
    mov rax, -EINVAL
    test edi, 0xFFF
    jnz .out
    lea rdx, [rdi + rsi + 4095]
    and rdx, -4096
    mov rcx, USER_TOP
    cmp rdx, rcx
    ja .out
    mov rsi, rdi
    call lx_cur_as
    mov rdi, rax
    push rdi
    call mm_lock
    call lx_zap
    pop rdi
    call mm_unlock
    xor eax, eax
.out:
    ret

; brk(addr) -> the break: moved there if it can be
lx_sys_brk:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
    mov rax, [rbx + AS_BRK]
    cmp r12, [rbx + AS_BRK0]
    jb .unlock
    mov r13, [rbx + AS_BRK]             ; R13 = its end now, R14 = then
    add r13, 4095
    and r13, -4096
    lea r14, [r12 + 4095]
    and r14, -4096
    cmp r14, r13
    je .moved
    jb .shrink
    mov rsi, r13                        ; more: if nothing is in the way
    mov rdx, r14
    call vma_free_range
    mov rax, [rbx + AS_BRK]
    jc .unlock
    mov rsi, r13
    mov rdx, r14
    sub rdx, r13
    mov ecx, PROT_READ | PROT_WRITE
    mov r8d, VMF_HEAP
    xor r9d, r9d
    xor r10d, r10d
    call lx_map_locked
    test rax, rax
    mov rax, [rbx + AS_BRK]
    js .unlock
    jmp .moved
.shrink:
    mov rsi, r14
    mov rdx, r13
    call lx_unmap
.moved:
    mov [rbx + AS_BRK], r12
    mov rax, r12
.unlock:
    mov rdi, rbx
    call mm_unlock
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; mremap(old, old length, new length, flags, new address)
lx_sys_mremap:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, VA_SIZE
    mov rax, -EINVAL
    test edi, 0xFFF
    jnz .out
    test ecx, ~(MREMAP_MAYMOVE | MREMAP_FIXED)
    jnz .out
    test ecx, MREMAP_FIXED              ; (not done)
    jnz .out
    mov r12, rdi                        ; R12 = where
    lea r13, [rsi + 4095]               ; R13 = its bytes
    and r13, -4096
    lea r14, [rdx + 4095]               ; R14 = the bytes it is to have
    and r14, -4096
    jz .out
    test r13, r13
    jz .out
    mov r15d, ecx
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
    mov rsi, r12                        ; one area holds all of it
    call vma_find
    test rax, rax
    jz .efault
    lea rcx, [r12 + r13]
    cmp [rax + VA_END], rcx
    jb .efault
    mov rsi, rax                        ; a copy of it
    push rdi
    lea rdi, [rsp + 8]
    mov ecx, VA_SIZE
    rep movsb
    pop rdi
    cmp r14, r13
    ja .grow
    lea rsi, [r12 + r14]                ; smaller: the rest goes
    lea rdx, [r12 + r13]
    call lx_unmap
    mov rax, r12
    jmp .unlock
.grow:
    lea rsi, [r12 + r13]                ; room after it?
    lea rdx, [r12 + r14]
    mov rax, USER_TOP
    cmp rdx, rax
    ja .move
    call vma_free_range
    jc .move
    mov rcx, [rsp + VA_OFF]             ; then it grows there
    sub rsi, [rsp + VA_START]
    add rcx, rsi
    lea rsi, [r12 + r13]
    mov rdx, r14
    sub rdx, r13
    mov r10, rcx
    mov ecx, [rsp + VA_PROT]
    mov r8d, [rsp + VA_FLAGS]
    mov r9, [rsp + VA_NODE]
    call lx_map_locked
    cmp rax, -4095
    jae .unlock
    mov rax, r12
    jmp .unlock
.move:
    mov rax, -ENOMEM
    test r15d, MREMAP_MAYMOVE
    jz .unlock
    mov rsi, r14
    mov rdx, LX_MMAP_TOP
    mov ecx, LX_MMAP_LOW
    call vma_gap
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; RBP = where it goes
    mov rcx, [rsp + VA_OFF]             ; its area there
    mov rsi, r12
    sub rsi, [rsp + VA_START]
    add rcx, rsi
    mov r10, rcx
    mov rsi, rbp
    mov rdx, r14
    mov ecx, [rsp + VA_PROT]
    mov r8d, [rsp + VA_FLAGS]
    mov r9, [rsp + VA_NODE]
    call lx_map_locked
    cmp rax, -4095
    jae .unlock
    xor ecx, ecx                        ; its pages move
.page:
    cmp rcx, r13
    jae .moved
    lea rsi, [r12 + rcx]
    call as_pte_get
    test rax, rax
    jz .next
    mov rdx, [rax]
    test dl, PTE_P
    jz .next
    mov qword [rax], 0
    lea rsi, [rbp + rcx]
    call as_pte
    test rax, rax
    jz .next                            ; (no table: that page is lost)
    mov [rax], rdx
.next:
    add rcx, 4096
    jmp .page
.moved:
    mov rsi, r12                        ; the old place: its area, its TLBs
    mov rdx, r13
    shr rdx, 12
    call lx_flush
    mov rsi, r12
    lea rdx, [r12 + r13]
    call lx_unmap
    mov rax, rbp
    jmp .unlock
.efault:
    mov rax, -EFAULT
    jmp .unlock
.nomem:
    mov rax, -ENOMEM
.unlock:
    push rax
    mov rdi, rbx
    call mm_unlock
    pop rax
.out:
    add rsp, VA_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
