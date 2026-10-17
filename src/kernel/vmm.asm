; =============================================================================
;  vmm.asm - the kernel's own page tables, the vm region, TLB shootdowns,
;  firmware calls, and what a page fault hit
;
;  vmm_init replaces the loader's tables with these:
;    PML4[256]  the direct map of [0, phys_top) at PHYS_BASE, 2 MiB pages,
;               read-write and never executable; the kernel image's code and
;               constants are read-only there too (4 KiB pages)
;    PML4[257]  VM_BASE: 512 GiB for vm_alloc, vm_map_phys and mmio_map, in
;               2 MiB slots. A mapping sits at the top of its slots, with at
;               least one unmapped page below it and the next slot's unmapped
;               first page above it, so running off either end faults.
;    PML4[511]  the kernel image at KERNEL_BASE (code read-only; constants
;               read-only and not executable; data and .bss writable and not
;               executable) and the framebuffer at FB_VIRT, write-combining
;  Nothing is mapped in the lower half, so a null pointer, or a physical
;  address used as a pointer, faults. The upper-half PML4 entries never change
;  after vmm_init, so every set of tables that copies them sees one kernel.
;
;  The firmware tables are the loader's PML4 (below 4 GiB): its identity map
;  of [0, phys_top) stays in PML4[0] and the kernel's upper half is copied in.
;  UEFI runtime calls run on them (fw_enter, fw_leave), and so does an AP
;  from its trampoline until ap_entry.
; =============================================================================

PTE_P           equ 1 << 0
PTE_W           equ 1 << 1
PTE_PWT         equ 1 << 3
PTE_PCD         equ 1 << 4
PTE_A           equ 1 << 5
PTE_D           equ 1 << 6
PTE_PS          equ 1 << 7                  ; a 2 MiB page, in a PDE
PTE_PAT         equ 1 << 7                  ; the PAT bit, in a 4 KiB PTE
PTE_G           equ 1 << 8
PTE_OWN         equ 1 << 9                  ; ours: vm_free gives the page back
PTE_TABLE       equ PTE_P | PTE_W           ; an entry pointing to a table

; leaf flags; vmm_nx adds NX to all but PF_CODE when the CPU has it
PF_CODE         equ PTE_P | PTE_A | PTE_G
PF_RO           equ PTE_P | PTE_A | PTE_G
PF_RW           equ PTE_P | PTE_W | PTE_A | PTE_D | PTE_G
PF_WC           equ PF_RW | PTE_PAT         ; PAT entry 4: write-combining
PF_UC           equ PF_RW | PTE_PCD | PTE_PWT ; PAT entry 3: uncached
PF_BIG          equ PF_RW | PTE_PS

VM_BASE         equ 0xFFFF808000000000      ; PML4[257]
VM_END          equ 0xFFFF810000000000
VM_SLOT         equ 0x200000
VM_SLOTS        equ 262144
VM_PML4_INDEX   equ 257

TLB_ALL_OVER    equ 64                      ; more pages than this: flush everything
ICR_FIXED_OTHERS equ 0x000C4000             ; fixed, to all excluding self

%macro VM_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [vm_lock]
    call spin_lock
    pop rdi
%endmacro

%macro VM_UNLOCK 0
    mov dword [vm_lock], 0
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  vmm_init: build the kernel's tables and move onto them. BSP, once pmm is up,
;  interrupts off. Panics if memory runs out.
; -----------------------------------------------------------------------------
vmm_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test dword [cpu_e1_edx], 1 << 20
    jz .no_nx
    bts qword [vmm_nx], 63
.no_nx:
    mov rdi, KERNEL_BASE                ; where the loader put the image
    call vmm_translate
    jc .no_kernel
    mov [kernel_phys], rax

    call vmm_table_page
    mov [vmm_cr3], rax
    mov [vmm_pml4], rdx
    mov rbx, rdx
    call vmm_table_page                 ; the direct map's PDPT
    or rax, PTE_TABLE
    mov [rbx + 256 * 8], rax
    mov r12, rdx
    call vmm_table_page                 ; the vm region's
    mov [vm_pdpt], rdx
    or rax, PTE_TABLE
    mov [rbx + VM_PML4_INDEX * 8], rax
    call vmm_table_page                 ; the kernel's and the framebuffer's
    or rax, PTE_TABLE
    mov [rbx + 511 * 8], rax

    mov rax, [boot_info]                ; the direct map: a PD per GiB
    mov r13, [rax + BI_PHYS_TOP]
    shr r13, 30
    xor r14d, r14d
.gib:
    call vmm_table_page
    or rax, PTE_TABLE
    mov [r12], rax
    add r12, 8
    mov ecx, 512
.big:
    mov rax, r14
    or rax, PF_BIG
    or rax, [vmm_nx]
    mov [rdx], rax
    add rdx, 8
    add r14, 0x200000
    dec ecx
    jnz .big
    dec r13
    jnz .gib

    mov r12, KERNEL_BASE                ; the kernel image, by section
    mov r13, [kernel_phys]
.kpage:
    lea rax, [kernel_end]
    cmp r12, rax
    jae .kdone
    mov r14d, PF_RW
    lea rax, [kernel_data]
    cmp r12, rax
    jae .knx
    mov r14d, PF_RO
    lea rax, [kernel_rodata]
    cmp r12, rax
    jae .knx
    mov r14d, PF_CODE
    jmp .kmap
.knx:
    or r14, [vmm_nx]
.kmap:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call vmm_map_or_die
    add r12, 4096
    add r13, 4096
    jmp .kpage
.kdone:

    mov rax, [boot_info]                ; the framebuffer, write-combining
    mov r13, [rax + BI_FB_PHYS]
    mov r15, [rax + BI_FB_SIZE]
    test r13, r13
    jz .fbdone
    mov eax, r13d
    and eax, 0xFFF
    add r15, rax
    and r13, ~0xFFF
    mov r12, FB_VIRT
    mov r14d, PF_WC
    or r14, [vmm_nx]
.fbpage:
    test r15, r15
    jle .fbdone
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call vmm_map_or_die
    add r12, 4096
    add r13, 4096
    sub r15, 4096
    jmp .fbpage
.fbdone:

    mov r12, [kernel_phys]              ; the image's code and constants are
    add r12, [phys_base]                ; read-only in the direct map as well
    lea r13, [kernel_data]
    mov rax, KERNEL_BASE
    sub r13, rax
.dpage:
    mov rdi, r12
    call vmm_split
    xor esi, esi
    call vmm_walk
    and qword [rax], ~PTE_W
    add r12, 4096
    sub r13, 4096
    ja .dpage

    mov rax, [vmm_cr3]                  ; over we go
    mov cr3, rax

    mov rax, [boot_info]                ; the loader's PML4 becomes the firmware's
    mov rbx, [rax + BI_PML4]
    mov [fw_cr3], rbx
    add rbx, [phys_base]
    mov rdi, [rbx + 511 * 8]            ; its kernel and framebuffer tables go
    call vmm_free_tables
    mov rsi, [vmm_pml4]
    mov ecx, 256
.copy:
    mov rax, [rsi + rcx * 8]
    mov [rbx + rcx * 8], rax
    inc ecx
    cmp ecx, 512
    jb .copy

    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.no_kernel:
    xor edi, edi
    lea rsi, [str_vmm_nokernel]
    jmp panic

; vmm_free_tables(RDI = a PML4 entry): free the PDPT it points to and the
; tables under it, not the pages they map (the loader's, once they are unused)
vmm_free_tables:
    push rbx
    push r12
    push r13
    push rsi
    test dil, PTE_P
    jz .out
    mov rbx, rdi
    and rbx, [vmm_addr_mask]
    xor r12d, r12d
.pdpte:
    mov rax, rbx
    add rax, [phys_base]
    mov rdi, [rax + r12 * 8]
    test dil, PTE_P
    jz .next_pdpte
    test dil, PTE_PS
    jnz .next_pdpte
    and rdi, [vmm_addr_mask]
    mov r13, rdi                        ; a PD
    xor ecx, ecx
.pde:
    mov rax, r13
    add rax, [phys_base]
    mov rdi, [rax + rcx * 8]
    test dil, PTE_P
    jz .next_pde
    test dil, PTE_PS
    jnz .next_pde
    and rdi, [vmm_addr_mask]            ; a PT
    mov esi, 1
    call pmm_free
.next_pde:
    inc ecx
    cmp ecx, 512
    jb .pde
    mov rdi, r13
    mov esi, 1
    call pmm_free
.next_pdpte:
    inc r12d
    cmp r12d, 512
    jb .pdpte
    mov rdi, rbx
    mov esi, 1
    call pmm_free
.out:
    pop rsi
    pop r13
    pop r12
    pop rbx
    ret

; vmm_table_page -> RAX = physical address of a zeroed page, RDX = where the
; direct map has it. Panics if memory ran out.
vmm_table_page:
    push rdi
    mov edi, 1
    call pmm_alloc_zero
    pop rdi
    test rax, rax
    jz vmm_oom
    mov rdx, rax
    add rdx, [phys_base]
    ret

vmm_oom:
    xor edi, edi
    lea rsi, [str_vmm_oom]
    jmp panic

; -----------------------------------------------------------------------------
;  vmm_walk(RDI = virtual address, ESI = 1 to make missing tables) -> RAX =
;  where the direct map has its 4 KiB PTE in the kernel's tables; 0 if a table
;  is missing (or could not be made) or a large page maps it. Never makes a
;  PML4 entry. Preserves others.
; -----------------------------------------------------------------------------
vmm_walk:
    push rcx
    push rdx
    push rdi
    mov rdx, rdi
    mov rax, [vmm_pml4]
    mov ecx, 39
.level:
    mov rdi, rdx
    shr rdi, cl
    and edi, 511
    lea rdi, [rax + rdi * 8]
    cmp ecx, 12
    je .found
    mov rax, [rdi]
    test al, PTE_P
    jz .missing
    test al, PTE_PS
    jnz .fail
.next:
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    sub ecx, 9
    jmp .level
.missing:
    test esi, esi
    jz .fail
    cmp ecx, 39
    je .fail
    push rdi
    mov edi, 1
    call pmm_alloc_zero
    pop rdi
    test rax, rax
    jz .fail
    or rax, PTE_TABLE
    mov [rdi], rax
    jmp .next
.found:
    mov rax, rdi
    jmp .out
.fail:
    xor eax, eax
.out:
    pop rdi
    pop rdx
    pop rcx
    ret

; vmm_map(RDI = virtual, RSI = physical, RDX = flags): one 4 KiB page in the
; kernel's tables. CF = 1 if a table could not be made. Preserves all but RAX.
vmm_map:
    push rsi
    mov esi, 1
    call vmm_walk
    pop rsi
    test rax, rax
    jz .fail
    push rsi
    or rsi, rdx
    mov [rax], rsi
    pop rsi
    clc
    ret
.fail:
    stc
    ret

vmm_map_or_die:
    call vmm_map
    jc vmm_oom
    ret

; vmm_split(RDI = virtual address): the 2 MiB page that maps it becomes a PT
; of 4 KiB pages with the same flags. For vmm_init, before the tables are
; live; the PML4 and PDPT entries must exist. Preserves all but RAX.
vmm_split:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rax, [vmm_pml4]
    mov rcx, rdi
    shr rcx, 39
    and ecx, 511
    mov rax, [rax + rcx * 8]
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    mov rcx, rdi
    shr rcx, 30
    and ecx, 511
    mov rax, [rax + rcx * 8]
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    mov rcx, rdi
    shr rcx, 21
    and ecx, 511
    lea rbx, [rax + rcx * 8]            ; the PDE
    mov rsi, [rbx]
    test esi, PTE_PS
    jz .out
    call vmm_table_page
    mov rcx, rsi
    and rcx, [vmm_addr_mask]            ; the 2 MiB page's physical address
    mov r8, rsi
    and r8, [vmm_split_mask]            ; its flags, but not PS
    push rax
    mov eax, 512
.pte:
    mov rsi, rcx
    or rsi, r8
    mov [rdx], rsi
    add rdx, 8
    add rcx, 4096
    dec eax
    jnz .pte
    pop rax
    or rax, PTE_TABLE
    mov [rbx], rax
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  vmm_lookup(RDI = virtual address) -> RAX = the entry that maps it, RDX =
;  the size of its page; CF = 1 if nothing maps it. Walks the tables in CR3.
;  vmm_translate(RDI) -> RAX = its physical address, CF = 1 if unmapped.
;  Both preserve the others.
; -----------------------------------------------------------------------------
vmm_lookup:
    push rcx
    mov rax, cr3
    and rax, [vmm_addr_mask]
    mov ecx, 39
.level:
    add rax, [phys_base]
    mov rdx, rdi
    shr rdx, cl
    and edx, 511
    mov rax, [rax + rdx * 8]
    test al, PTE_P
    jz .none
    cmp ecx, 12
    je .leaf
    cmp ecx, 39
    je .table
    test al, PTE_PS
    jnz .leaf                           ; 1 GiB or 2 MiB
.table:
    and rax, [vmm_addr_mask]
    sub ecx, 9
    jmp .level
.leaf:
    mov edx, 1
    shl rdx, cl
    clc
    jmp .out
.none:
    stc
.out:
    pop rcx
    ret

vmm_translate:
    push rdx
    push rsi
    call vmm_lookup
    jc .out
    and rax, [vmm_addr_mask]
    lea rsi, [rdx - 1]                  ; offset into the page
    mov rdx, rsi
    not rdx
    and rax, rdx                        ; drops a large page's PAT bit too
    and rsi, rdi
    add rax, rsi
    clc
.out:
    pop rsi
    pop rdx
    ret

; vmm_audit -> RAX = leaf entries in the kernel's upper half that are both
; writable and executable (W^X wants none), RDX = leaf entries looked at
vmm_audit:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    xor eax, eax
    xor edx, edx
    mov r8, [vmm_pml4]
    mov ecx, 256
.pml4e:
    mov rsi, [r8 + rcx * 8]
    mov ebx, 39
    call .table
    inc ecx
    cmp ecx, 512
    jb .pml4e
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret
.table:                                 ; RSI = an entry at level RBX: count under it
    test sil, PTE_P
    jz .done
    cmp ebx, 12
    je .leaf
    cmp ebx, 39
    je .down
    test sil, PTE_PS
    jnz .leaf
.down:
    and rsi, [vmm_addr_mask]
    add rsi, [phys_base]
    push rcx
    push rsi
    sub ebx, 9
    xor ecx, ecx
.entry:
    mov rdi, [rsp]
    mov rsi, [rdi + rcx * 8]
    call .table
    inc ecx
    cmp ecx, 512
    jb .entry
    add ebx, 9
    pop rsi
    pop rcx
.done:
    ret
.leaf:
    inc rdx
    test sil, PTE_W
    jz .done
    bt rsi, 63
    jc .done
    inc rax
    ret

; -----------------------------------------------------------------------------
;  Firmware calls. fw_enter (interrupts off) -> RAX = the CR3 to give back to
;  fw_leave(RDI); in between, the identity map is there for the firmware.
; -----------------------------------------------------------------------------
fw_enter:
    mov rax, [fw_cr3]
    test rax, rax
    jz .loader                          ; before vmm_init: the loader's tables
    push rdx
    mov rdx, cr3
    mov cr3, rax
    mov rax, rdx
    pop rdx
    ret
.loader:
    mov rax, cr3
    ret

fw_leave:
    mov cr3, rdi
    ret

; -----------------------------------------------------------------------------
;  The vm region
;    vm_alloc(RDI = bytes) -> RAX = that many zeroed bytes, read-write, not
;      executable, page-aligned, guarded; 0 if memory or room ran out
;    vm_map_phys(RDI = physical, RSI = bytes, RDX = PF_* flags) -> RAX = where
;      that range is mapped (the same offset into its first page), 0 if out
;    vm_free(RDI = an address in the first page of either) -> RAX = pages
;      unmapped. Panics on anything else. Not from interrupt handlers, and
;      not with a spinlock held (it shoots down other CPUs' TLB entries).
;    vm_contains(RDI) -> CF = 1 if the address is in the vm region
;  All preserve every register but RAX.
; -----------------------------------------------------------------------------
vm_alloc:
    push rdx
    push rsi
    mov rsi, -1
    mov edx, PF_RW | PTE_OWN
    call vm_map
    pop rsi
    pop rdx
    ret

vm_map_phys:
    push rcx
    push rdi
    push rsi
    mov rcx, rdi
    and ecx, 0xFFF                      ; the offset into the first page
    lea rax, [rsi + rcx]
    mov rsi, rdi
    and rsi, ~0xFFF
    mov rdi, rax
    call vm_map
    test rax, rax
    jz .out
    add rax, rcx
.out:
    pop rsi
    pop rdi
    pop rcx
    ret

; vm_map(RDI = bytes, RSI = first physical page or -1 for fresh zeroed pages
; of our own, RDX = flags) -> RAX = start of the mapping, 0 if out
vm_map:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    test rdi, rdi
    jz .none
    lea r12, [rdi + 0xFFF]
    shr r12, 12                         ; pages
    mov rax, r12
    shr rax, 26                         ; 256 GiB at most
    jnz .none
    lea r13, [r12 + 512]
    shr r13, 9                          ; slots: the pages and one more
    mov r15, rdx
    and r15, ~PTE_OWN
    cmp rsi, -1
    jne .flags
    or r15, PTE_OWN
.flags:
    or r15, [vmm_nx]
    VM_LOCK
    call vm_find
    jc .full
    lea rax, [r14 + r13]                ; the mapping ends where the slots do
    shl rax, 21
    mov rbx, VM_BASE
    add rbx, rax
    mov rax, r12
    shl rax, 12
    sub rbx, rax
    xor ecx, ecx
.page:
    cmp rcx, r12
    jae .mapped
    mov rdi, rcx
    shl rdi, 12
    add rdi, rbx
    push rsi
    mov esi, 1
    call vmm_walk
    pop rsi
    test rax, rax
    jz .oom
    mov rdx, rax
    cmp rsi, -1
    jne .given
    push rdi
    mov edi, 1
    call pmm_alloc_zero
    pop rdi
    test rax, rax
    jz .oom
    jmp .set
.given:
    mov rax, rcx
    shl rax, 12
    add rax, rsi
.set:
    or rax, r15
    mov [rdx], rax
    inc qword [vm_pages]
    inc rcx
    jmp .page
.mapped:
    lock inc qword [vm_count]           ; vm_free takes it off outside the lock
    VM_UNLOCK
    mov rax, rbx
    jmp .out
.oom:
    VM_UNLOCK
    mov rdi, r14
    mov rsi, r13
    mov rdx, rbx
    mov rcx, r12
    call vm_release
    jmp .none
.full:
    VM_UNLOCK
.none:
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; vm_find(R13 = slots) -> R14 = the first of that many free slots, now taken;
; CF = 1 if there is no such run. Next fit from vm_hint. Holds vm_lock.
vm_find:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    lea rdi, [vm_bitmap]
    mov rcx, [vm_hint]
    xor edx, edx                        ; wrapped yet?
.try:
    lea rsi, [rcx + r13]
    cmp rsi, VM_SLOTS
    jbe .check
    test edx, edx
    jnz .fail
    inc edx
    xor ecx, ecx
    jmp .try
.check:
    mov rax, rcx
.scan:
    cmp rax, rsi
    jae .found
    bt [rdi], rax
    jc .busy
    inc rax
    jmp .scan
.busy:
    lea rcx, [rax + 1]
    jmp .try
.found:
    mov r14, rcx
    mov rax, rcx
.take:
    bts [rdi], rax
    inc rax
    cmp rax, rsi
    jb .take
    mov [vm_hint], rsi
    add [vm_slots_used], r13
    clc
    jmp .out
.fail:
    stc
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; vm_pde(RDI = slot) -> RAX = where the direct map has its PDE, 0 if its PD
; does not exist yet. Preserves others.
vm_pde:
    push rcx
    mov rax, [vm_pdpt]
    mov rcx, rdi
    shr rcx, 9
    mov rax, [rax + rcx * 8]
    test al, PTE_P
    jz .none
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    mov ecx, edi
    and ecx, 511
    lea rax, [rax + rcx * 8]
    pop rcx
    ret
.none:
    xor eax, eax
    pop rcx
    ret

; vm_release(RDI = first slot, RSI = slots, RDX = start of the mapping, RCX =
; its pages) -> RAX = pages that were mapped. Unmaps every slot at its PDE,
; shoots the TLBs down, then gives back our pages and the PTs and frees the
; slots. Preserves others.
vm_release:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    push r9
    push r10
    mov r8, rdi
    lea r9, [rdi + rsi]
    VM_LOCK
    mov rdi, r8
.unmap:
    cmp rdi, r9
    jae .unmapped
    call vm_pde
    test rax, rax
    jz .unmap_next
    and qword [rax], ~PTE_P             ; the PT stays reachable from here
.unmap_next:
    inc rdi
    jmp .unmap
.unmapped:
    VM_UNLOCK
    mov rdi, rdx
    mov rsi, rcx
    call tlb_shootdown
    VM_LOCK
    xor ebx, ebx
    mov rdi, r8
.slot:
    cmp rdi, r9
    jae .released
    call vm_pde
    test rax, rax
    jz .free_slot
    mov r10, rax
    mov rax, [r10]
    and rax, [vmm_addr_mask]
    jz .free_slot
    push rdi
    mov rdx, rax                        ; the PT
    add rax, [phys_base]
    xor ecx, ecx
.pte:
    mov rdi, [rax + rcx * 8]
    test rdi, rdi
    jz .pte_next
    inc rbx
    test edi, PTE_OWN
    jz .pte_next
    and rdi, [vmm_addr_mask]
    mov esi, 1
    call pmm_free
.pte_next:
    inc ecx
    cmp ecx, 512
    jb .pte
    mov rdi, rdx
    mov esi, 1
    call pmm_free
    mov qword [r10], 0
    pop rdi
.free_slot:
    lea rax, [vm_bitmap]
    btr [rax], rdi
    dec qword [vm_slots_used]
    inc rdi
    jmp .slot
.released:
    sub [vm_pages], rbx
    VM_UNLOCK
    mov rax, rbx
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

vm_free:
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    mov rbx, rdi
    and rbx, ~0xFFF                     ; its first page
    call vm_contains
    jnc .bad
    mov rax, VM_BASE + 4096
    cmp rbx, rax
    jb .bad
    lea rdi, [rbx - 4096]               ; nothing mapped just below it
    xor esi, esi
    call vmm_walk
    test rax, rax
    jz .count_pages
    test byte [rax], PTE_P
    jnz .bad
.count_pages:
    xor ecx, ecx
.count:
    mov rdi, rcx
    shl rdi, 12
    add rdi, rbx
    xor esi, esi
    call vmm_walk
    test rax, rax
    jz .counted
    test byte [rax], PTE_P
    jz .counted
    inc rcx
    jmp .count
.counted:
    test rcx, rcx
    jz .bad
    mov rax, rcx                        ; it must end where its slots end
    shl rax, 12
    add rax, rbx
    mov rdx, VM_BASE
    sub rax, rdx
    test eax, VM_SLOT - 1
    jnz .bad
    shr rax, 21
    lea rdi, [rbx - 4096]
    sub rdi, rdx
    shr rdi, 21                         ; first slot
    mov rsi, rax
    sub rsi, rdi                        ; slots
    lea rax, [rcx + 512]
    shr rax, 9
    cmp rax, rsi
    jne .bad
    lea rax, [vm_bitmap]
    bt [rax], rdi
    jnc .bad
    mov rdx, rbx
    call vm_release
    lock dec qword [vm_count]
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
.bad:
    mov rdi, [rsp + 8]
    lea rsi, [str_vm_bad]
    jmp mem_bad

vm_contains:
    push rax
    mov rax, rdi
    shr rax, 39
    cmp eax, (VM_BASE >> 39) & 0x1FFFFFF
    pop rax
    je .yes
    clc
    ret
.yes:
    stc
    ret

; mem_bad(RDI = address, RSI = what is wrong with it): panic, saying so
heap_bad:
mem_bad:
    mov rdx, rdi
    lea rdi, [mem_bad_text]
    SPRINTF rdi, "%s: %p", rsi, rdx
    lea rsi, [mem_bad_text]
    xor edi, edi
    jmp panic

; -----------------------------------------------------------------------------
;  mmio_map(RDI = physical, RSI = bytes) -> RAX = mapped address (0 on failure)
;  Below phys_top the direct map already covers it (the MTRRs make device
;  memory uncached there). Above it (64-bit BARs sit high), it is mapped
;  uncached in the vm region.
; -----------------------------------------------------------------------------
mmio_map:
    push rdx
    mov rax, rdi
    add rax, rsi
    mov rdx, [boot_info]
    cmp rax, [rdx + BI_PHYS_TOP]
    jbe .direct
    mov edx, PF_UC
    call vm_map_phys
    pop rdx
    ret
.direct:
    mov rax, rdi
    add rax, [phys_base]
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  TLB shootdown
;    tlb_shootdown(RDI = virtual address, RSI = pages): those pages leave this
;      CPU's TLB and every other online CPU's before it returns. Waiting for
;      the lock or the answers, it answers anyone else's, so two at once are
;      safe; but the caller must not hold a lock another CPU may spin on with
;      interrupts off. Preserves all.
;    tlb_service: answer a shootdown this CPU has not answered yet (its IPI
;      handler; also called by anyone spinning with interrupts off).
; -----------------------------------------------------------------------------
tlb_shootdown:
    push rax
    push rdi
    push rsi
    call tlb_flush_local
    cmp byte [smp_ready], 0
    je .out
    cmp dword [cpus_online], 1
    jbe .out
    pushfq
    cli
.lock:
    mov eax, 1
    xchg eax, [tlb_lock]
    test eax, eax
    jz .locked
    call tlb_service
    pause
    jmp .lock
.locked:
    mov [tlb_va], rdi
    mov [tlb_pages], rsi
    mov dword [tlb_acks], 0
    mov eax, [cpus_online]
    dec eax
    mov [tlb_want], eax
    lock inc qword [tlb_gen]
    mov rax, [tlb_gen]
    mov [gs:PC_TLB_GEN], rax            ; not for us: done above
    inc qword [tlb_count]
    xor edi, edi
    mov esi, ICR_FIXED_OTHERS | VEC_TLB
    call lapic_send_ipi
.wait:
    mov eax, [tlb_acks]
    cmp eax, [tlb_want]
    jae .answered
    pause
    jmp .wait
.answered:
    mov dword [tlb_lock], 0
    popfq
.out:
    pop rsi
    pop rdi
    pop rax
    ret

tlb_service:
    push rax
    push rdi
    push rsi
    mov rax, [tlb_gen]
    cmp rax, [gs:PC_TLB_GEN]
    je .out
    mov [gs:PC_TLB_GEN], rax
    mov rdi, [tlb_va]
    mov rsi, [tlb_pages]
    call tlb_flush_local
    lock inc dword [tlb_acks]
.out:
    pop rsi
    pop rdi
    pop rax
    ret

tlb_irq:
    jmp tlb_service

; tlb_flush_local(RDI = virtual address, RSI = pages). Preserves all.
tlb_flush_local:
    push rax
    push rdi
    push rsi
    cmp rsi, TLB_ALL_OVER
    ja .all
.page:
    test rsi, rsi
    jz .out
    invlpg [rdi]
    add rdi, 4096
    dec rsi
    jmp .page
.all:
    mov rax, cr4
    test eax, 1 << 7
    jz .no_global
    btr rax, 7                          ; PGE off and on: global entries too
    mov cr4, rax
    bts rax, 7
    mov cr4, rax
    jmp .out
.no_global:
    mov rax, cr3
    mov cr3, rax
.out:
    pop rsi
    pop rdi
    pop rax
    ret

; tlb_init: the shootdown IPI's handler (once, before the APs start)
tlb_init:
    mov edi, VEC_TLB
    lea rsi, [tlb_irq]
    jmp irq_register

; -----------------------------------------------------------------------------
;  vmm_where(RDI = buffer, RSI = address) -> RAX = bytes written: what lives
;  at an address, in words, for a fault report. Preserves others.
; -----------------------------------------------------------------------------
vmm_where:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov rbx, rsi
    lea rdx, [str_at_null]
    cmp rbx, 0x10000
    jb .say
    bt rbx, 63
    jc .upper
    mov rax, rbx
    shr rax, 47
    lea rdx, [str_at_noncanon]
    jnz .say
    lea rdx, [str_at_lower]
    mov rax, [boot_info]
    cmp rbx, [rax + BI_PHYS_TOP]
    jae .say
    lea rdx, [str_at_physical]
    jmp .say
.upper:
    mov rax, PHYS_BASE
    lea rdx, [str_at_noncanon]
    cmp rbx, rax
    jb .say
    mov rcx, [boot_info]
    mov rcx, [rcx + BI_PHYS_TOP]
    add rcx, rax
    cmp rbx, rcx
    jae .not_direct
    lea rdx, [str_at_direct]
    mov rcx, rbx                        ; the kernel image's copy?
    sub rcx, rax
    sub rcx, [kernel_phys]
    lea rax, [kernel_end]
    mov r8, KERNEL_BASE
    sub rax, r8
    cmp rcx, rax
    jae .say
    lea rdx, [str_at_direct_kernel]
    jmp .say
.not_direct:
    mov rax, VM_BASE
    lea rdx, [str_at_past_direct]
    cmp rbx, rax
    jb .say
    mov rax, VM_END
    cmp rbx, rax
    jb .vm
    mov rax, FB_VIRT
    lea rdx, [str_at_kernel_space]
    cmp rbx, rax
    jb .say
    mov rcx, [boot_info]
    mov r8, [rcx + BI_FB_SIZE]
    mov ecx, [rcx + BI_FB_PHYS]
    and ecx, 0xFFF
    add rcx, r8
    add rcx, rax
    cmp rbx, rcx
    lea rdx, [str_at_fb]
    jb .say
    mov rax, KERNEL_BASE
    lea rdx, [str_at_kernel_space]
    cmp rbx, rax
    jb .say
    lea rdx, [str_at_code]
    lea rax, [kernel_rodata]
    cmp rbx, rax
    jb .say
    lea rdx, [str_at_const]
    lea rax, [kernel_data]
    cmp rbx, rax
    jb .say
    lea rdx, [str_at_data]
    lea rax, [kernel_end]
    cmp rbx, rax
    jb .say
    lea rdx, [str_at_past_kernel]
    jmp .say

.vm:                                    ; a CPU's stack, or around one?
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .not_stack
    PERCPU r8, rcx
    xor r9d, r9d
.stack:
    cmp r9d, 4
    jae .cpu_next
    lea rax, [vmm_stacks]
    movzx r10d, word [rax + r9 * 8]     ; offset of the top in the block
    mov rax, [r8 + r10]
    test rax, rax
    jz .stack_next
    cmp rbx, rax                        ; just above the top?
    jb .below_top
    add rax, 4096
    cmp rbx, rax
    jb .above
    jmp .stack_next
.below_top:
    lea r10, [vmm_stacks]
    mov r10d, [r10 + r9 * 8 + 4]        ; its size
    sub rax, r10                        ; its bottom
    cmp rbx, rax
    jae .stack_next                     ; on the stack itself
    lea r10, [rax - 4096]
    and r10, -VM_SLOT                   ; where its slots begin
    cmp rbx, r10
    jb .stack_next
    lea rax, [vmm_stack_names]
    mov rax, [rax + r9 * 8]
    SPRINTF rdi, "the guard page below CPU %u's %s (a stack overflow)", rcx, rax
    jmp .out
.above:
    lea rax, [vmm_stack_names]
    mov rax, [rax + r9 * 8]
    SPRINTF rdi, "just above the top of CPU %u's %s", rcx, rax
    jmp .out
.stack_next:
    inc r9d
    jmp .stack
.cpu_next:
    inc ecx
    jmp .cpu
.not_stack:
    mov rsi, rbx                        ; a thread's stack, or under one?
    call thread_where
    test rax, rax
    jnz .out
    push rdi
    mov rdi, rbx
    and rdi, ~0xFFF
    xor esi, esi
    lea rdx, [str_at_vm]
    call vmm_walk                       ; mapped?
    test rax, rax
    jz .not_mapped
    test byte [rax], PTE_P
    jnz .vm_said
.not_mapped:
    lea rdx, [str_at_vm_past]
    sub rdi, 4096                       ; just past the end of one?
    call vmm_walk
    test rax, rax
    jz .not_past
    test byte [rax], PTE_P
    jnz .vm_said
.not_past:
    mov rax, rbx
    mov rcx, VM_BASE
    sub rax, rcx
    shr rax, 21
    lea rcx, [vm_bitmap]
    lea rdx, [str_at_vm_below]
    bt [rcx], rax
    jc .vm_said
    lea rdx, [str_at_vm_free]
.vm_said:
    pop rdi
.say:
    SPRINTF rdi, "%s", rdx
.out:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; vmm_fault_text(RDI = buffer, RSI = interrupt frame) -> RAX = bytes written:
; a line saying what a page fault or a double fault ran into, or nothing
vmm_fault_text:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rsi
    mov rax, [rbx + FR_VECTOR]
    cmp eax, 14
    je .page_fault
    cmp eax, 8
    jne .nothing
    SPRINTF rdi, "cause: a fault the CPU could not deliver"
    add rdi, rax
    mov rsi, [panic_cr2]
    test rsi, rsi
    jz .end_line
    SPRINTF rdi, "; the last page fault was at %p: ", rsi
    add rdi, rax
    call vmm_where
    add rdi, rax
    jmp .end_line
.page_fault:
    mov rcx, [rbx + FR_ERROR]
    lea rdx, [str_pf_read]              ; what it was doing
    test ecx, 1 << 1
    jz .verb
    lea rdx, [str_pf_write]
.verb:
    test ecx, 1 << 4
    jz .verb_done
    lea rdx, [str_pf_fetch]
.verb_done:
    lea r8, [str_pf_unmapped]           ; and what stood in the way
    test ecx, 1 << 0
    jz .said
    lea r8, [str_pf_readonly]
    test ecx, 1 << 1
    jnz .said
    lea r8, [str_pf_nx]
    test ecx, 1 << 4
    jnz .said
    lea r8, [str_pf_forbidden]
.said:
    test ecx, 1 << 3
    jz .compose
    lea r8, [str_pf_reserved]
.compose:
    mov rsi, [panic_cr2]
    SPRINTF rdi, "cause: %s %p%s: ", rdx, rsi, r8
    add rdi, rax
    call vmm_where
    add rdi, rax
.end_line:
    mov word [rdi], 10
    inc rdi
    mov rax, rdi
    sub rax, [rsp + 8]
    jmp .out
.nothing:
    mov byte [rdi], 0
    xor eax, eax
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
str_vmm_oom:    db 'Out of memory for page tables', 0
str_vmm_nokernel: db 'The loader did not map the kernel where it should be', 0
str_vm_bad:     db 'vm_free: not the start of a vm mapping', 0
str_at_null:    db 'a null pointer', 0
str_at_noncanon: db 'not a canonical address', 0
str_at_lower:   db 'the lower half, where nothing is mapped', 0
str_at_physical: db 'the lower half, where nothing is mapped (a physical address used as a pointer?)', 0
str_at_direct:  db 'the direct map of physical memory', 0
str_at_direct_kernel: db "the direct map's view of the kernel image", 0
str_at_past_direct: db 'past the end of the direct map', 0
str_at_kernel_space: db 'kernel space where nothing is mapped', 0
str_at_fb:      db 'the framebuffer', 0
str_at_code:    db 'kernel code', 0
str_at_const:   db 'kernel constants', 0
str_at_data:    db 'kernel data', 0
str_at_past_kernel: db 'past the end of the kernel image', 0
str_at_vm_free: db 'free vm space (used after vm_free?)', 0
str_at_vm_past: db 'just past the end of a vm mapping (an overrun?)', 0
str_at_vm_below: db 'the guard pages below a vm mapping (an underrun, or a stack overflow?)', 0
str_at_vm:      db 'a vm mapping', 0
str_pf_read:    db 'a read from', 0
str_pf_write:   db 'a write to', 0
str_pf_fetch:   db 'running code at', 0
str_pf_unmapped: db ', where nothing is mapped', 0
str_pf_readonly: db ', which is read-only', 0
str_pf_nx:      db ', which is not code', 0
str_pf_forbidden: db ', which the page does not allow', 0
str_pf_reserved: db ', with reserved bits set in a page table entry', 0
str_stack_k:    db 'kernel stack', 0
str_stack_df:   db 'double-fault stack', 0
str_stack_nmi:  db 'NMI stack', 0
str_stack_mc:   db 'machine-check stack', 0
align 8
vmm_addr_mask:  dq 0x000FFFFFFFFFF000
vmm_split_mask: dq 0x800000000000017F   ; NX, G, D, A, PCD, PWT, W, P
vmm_stacks:                             ; where each stack's top is kept, its size
    dw PC_STACK_TOP, 0
    dd KSTACK_SIZE
    dw PC_TSS + TSS_IST1, 0
    dd IST_SIZE
    dw PC_TSS + TSS_IST2, 0
    dd IST_SIZE
    dw PC_TSS + TSS_IST3, 0
    dd IST_SIZE
vmm_stack_names:
    dq str_stack_k, str_stack_df, str_stack_nmi, str_stack_mc

section .data
align 8
vmm_nx:         dq 0                    ; NX in an entry, or 0 without it
vm_hint:        dq 0
vm_lock:        dd 0
tlb_lock:       dd 0

section .bss
alignb 8
vmm_cr3:        resq 1                  ; the kernel's PML4, physical
vmm_pml4:       resq 1                  ; and where the direct map has it
fw_cr3:         resq 1                  ; the firmware's (the loader's) PML4
kernel_phys:    resq 1                  ; where the image is
vm_pdpt:        resq 1
vm_count:       resq 1                  ; mappings
vm_pages:       resq 1                  ; pages mapped
vm_slots_used:  resq 1
tlb_gen:        resq 1
tlb_va:         resq 1
tlb_pages:      resq 1
tlb_count:      resq 1                  ; shootdowns sent
tlb_acks:       resd 1
tlb_want:       resd 1
mem_bad_text:   resb 160
alignb 64
vm_bitmap:      resb VM_SLOTS / 8
