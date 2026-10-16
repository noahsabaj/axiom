; =============================================================================
;  heap.asm - kmalloc and kfree, the kernel's heap
;
;  Up to 1024 bytes, objects come from slabs: a 4 KiB page from pmm each,
;  reached through the direct map, holding objects of one size (16, 32 ...
;  1024 bytes). A slab's first 128 bytes say what it holds, with a bit per
;  object for whether it is handed out, so kfree knows a pointer it never gave
;  out, and one freed twice. A freed object is filled with 0xDF, and kmalloc
;  checks that it still is before handing it out again: a write after free is
;  caught too. Each class keeps one empty slab; other empty ones go back.
;  Larger objects get a vm mapping each (vm_alloc), placed so that the object
;  ends where the mapping does: running off the end faults at once.
;
;  Objects come zeroed and 16-byte aligned. kmalloc and small kfree work on
;  any CPU, in any context; a large kfree is vm_free's, with its rules.
;  heap_bad(RDI = address, RSI = what is wrong) is called for any misuse.
; =============================================================================

HEAP_HDR        equ 128                     ; slab header
HEAP_MAX        equ 1024                    ; larger: a vm mapping each
HEAP_CLASSES    equ 7                       ; 16 << 0 .. 16 << 6
HEAP_POISON     equ 0xDFDFDFDFDFDFDFDF

SL_MAGIC        equ 0
SL_NEXT         equ 8                       ; slabs of the class with room
SL_PREV         equ 16
SL_CLASS        equ 24                      ; dword
SL_SIZE         equ 28                      ; dword, bytes per object
SL_COUNT        equ 32                      ; dword, objects in the slab
SL_USED         equ 36                      ; dword, handed out
SL_LISTED       equ 40                      ; byte: on its class's list
SL_MAP          equ 64                      ; 256 bits: 1 = handed out, or no object

HC_LIST         equ 0                       ; first slab with room
HC_SLABS        equ 8
HC_LISTED       equ 16                      ; slabs on the list
HC_USED         equ 24                      ; objects handed out
HC_SIZE         equ 32

%macro HEAP_LOCK 0
    pushfq
%ifndef HOST_TEST
    cli
%endif
    push rdi
    lea rdi, [heap_lock]
    call spin_lock
    pop rdi
%endmacro

%macro HEAP_UNLOCK 0
    mov dword [heap_lock], 0
    popfq
%endmacro

section .text

; heap_init: the direct map's bounds, for kfree's checks (once pmm is up)
heap_init:
    mov rax, [phys_base]
    mov [heap_lo], rax
    mov rdx, [boot_info]
    add rax, [rdx + BI_PHYS_TOP]
    mov [heap_hi], rax
    ret

; -----------------------------------------------------------------------------
;  kmalloc(RDI = bytes) -> RAX = zeroed, 16-byte aligned memory, 0 if there
;  is none. Preserves all others.
; -----------------------------------------------------------------------------
kmalloc:
    cmp rdi, HEAP_MAX
    ja kmalloc_big
    push rbx
    push rcx
    push rdx
    push rdi
    push rsi
    push r8
    mov eax, 16                         ; the smallest class that fits
    xor ecx, ecx
.class:
    cmp rdi, rax
    jbe .have_class
    shl eax, 1
    inc ecx
    jmp .class
.have_class:
    mov r8d, eax
    HEAP_LOCK
    imul rbx, rcx, HC_SIZE
    lea rax, [heap_class]
    add rbx, rax
    mov rdx, [rbx + HC_LIST]
    test rdx, rdx
    jnz .have_slab
    call heap_new_slab
    test rdx, rdx
    jz .oom
.have_slab:
    xor eax, eax                        ; its first free object
.word:
    mov rsi, [rdx + SL_MAP + rax * 8]
    not rsi
    test rsi, rsi
    jnz .bit
    inc eax
    cmp eax, 4
    jb .word
    mov rdi, rdx
    lea rsi, [str_heap_full]
    call heap_bad
    jmp .oom
.bit:
    bsf rsi, rsi
    shl eax, 6
    add eax, esi
    bts [rdx + SL_MAP], rax
    inc dword [rdx + SL_USED]
    inc qword [rbx + HC_USED]
    imul eax, r8d
    lea rdi, [rdx + HEAP_HDR + rax]
    mov rsi, rdi
    mov ecx, r8d                        ; still as kfree left it?
    shr ecx, 3
    mov rax, HEAP_POISON
    repe scasq
    je .clean
    mov rdi, rsi
    push rsi
    lea rsi, [str_heap_written]
    call heap_bad
    pop rsi
.clean:
    mov rdi, rsi
    mov ecx, r8d
    shr ecx, 3
    xor eax, eax
    rep stosq
    mov eax, [rdx + SL_USED]
    cmp eax, [rdx + SL_COUNT]
    jb .counted
    call heap_unlist                    ; full now
.counted:
    add [heap_bytes], r8
    inc qword [heap_objects]
    HEAP_UNLOCK
    mov rax, rsi
    jmp .out
.oom:
    HEAP_UNLOCK
    xor eax, eax
.out:
    pop r8
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

kmalloc_big:
    push rcx
    push rdi
    lea rcx, [rdi + 15]
    and rcx, -16
    mov rdi, rcx
    call vm_alloc
    test rax, rax
    jz .out
    lea rdi, [rcx + 0xFFF]              ; the object ends where the mapping does
    and rdi, ~0xFFF
    add rax, rdi
    sub rax, rcx
    lock inc qword [heap_big]
    lock add [heap_big_bytes], rdi
.out:
    pop rdi
    pop rcx
    ret

; heap_new_slab(ECX = class, R8 = object size, RBX = the class) -> RDX = a
; new slab, on the class's list; 0 if memory ran out. Holds heap_lock.
heap_new_slab:
    push rax
    push rcx
    push rdi
    push rsi
    push r9
    mov edi, 1
    call pmm_alloc
    test rax, rax
    jz .oom
    add rax, [phys_base]
    mov rdx, rax
    mov rdi, rax                        ; header zeroed, objects poisoned
    push rcx
    mov ecx, HEAP_HDR / 8
    xor eax, eax
    rep stosq
    mov ecx, (4096 - HEAP_HDR) / 8
    mov rax, HEAP_POISON
    rep stosq
    pop rcx
    mov rax, 'AXSLAB01'
    mov [rdx + SL_MAGIC], rax
    mov [rdx + SL_CLASS], ecx
    mov [rdx + SL_SIZE], r8d
    push rdx
    mov eax, 4096 - HEAP_HDR
    xor edx, edx
    div r8d
    pop rdx
    mov [rdx + SL_COUNT], eax
    lea rdi, [rdx + SL_MAP]             ; bits past the last object stay set
    mov ecx, eax
    xor esi, esi
.map:
    mov rax, -1
    mov r9d, ecx
    sub r9d, esi                        ; objects in this qword
    jle .store
    xor eax, eax
    cmp r9d, 64
    jge .store
    mov rax, -1
    push rcx
    mov ecx, r9d
    shl rax, cl
    pop rcx
.store:
    mov [rdi], rax
    add rdi, 8
    add esi, 64
    cmp esi, 256
    jb .map
    inc qword [rbx + HC_SLABS]
    inc qword [heap_slabs]
    call heap_list
    jmp .out
.oom:
    xor edx, edx
.out:
    pop r9
    pop rsi
    pop rdi
    pop rcx
    pop rax
    ret

; heap_list(RBX = class, RDX = slab): onto the front of the list.
; heap_unlist: off it. Both hold heap_lock and preserve all.
heap_list:
    push rax
    mov rax, [rbx + HC_LIST]
    mov [rdx + SL_NEXT], rax
    mov qword [rdx + SL_PREV], 0
    test rax, rax
    jz .first
    mov [rax + SL_PREV], rdx
.first:
    mov [rbx + HC_LIST], rdx
    mov byte [rdx + SL_LISTED], 1
    inc qword [rbx + HC_LISTED]
    pop rax
    ret

heap_unlist:
    push rax
    push rcx
    mov rax, [rdx + SL_PREV]
    mov rcx, [rdx + SL_NEXT]
    test rax, rax
    jz .head
    mov [rax + SL_NEXT], rcx
    jmp .after
.head:
    mov [rbx + HC_LIST], rcx
.after:
    test rcx, rcx
    jz .done
    mov [rcx + SL_PREV], rax
.done:
    mov byte [rdx + SL_LISTED], 0
    dec qword [rbx + HC_LISTED]
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  kfree(RDI = what kmalloc gave, or 0). Preserves all.
; -----------------------------------------------------------------------------
kfree:
    test rdi, rdi
    jz .null
    call vm_contains
    jc kfree_big
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    test edi, 15
    jnz .not_ours
    cmp rdi, [heap_lo]
    jb .not_ours
    cmp rdi, [heap_hi]
    jae .not_ours
    mov rsi, rdi
    and rsi, ~0xFFF                     ; its slab
    mov rax, 'AXSLAB01'
    cmp [rsi + SL_MAGIC], rax
    jne .not_ours
    mov rax, rdi
    sub rax, rsi
    sub rax, HEAP_HDR
    jb .not_ours
    mov r8d, [rsi + SL_SIZE]
    xor edx, edx
    div r8
    test rdx, rdx
    jnz .not_start
    cmp eax, [rsi + SL_COUNT]
    jae .not_ours
    mov rdx, rsi
    mov rcx, rax
    HEAP_LOCK
    btr [rdx + SL_MAP], rcx
    jnc .twice
    dec dword [rdx + SL_USED]
    push rdi
    mov rcx, r8
    shr ecx, 3
    mov rax, HEAP_POISON
    rep stosq
    pop rdi
    mov eax, [rdx + SL_CLASS]
    imul rbx, rax, HC_SIZE
    lea rax, [heap_class]
    add rbx, rax
    dec qword [rbx + HC_USED]
    sub [heap_bytes], r8
    dec qword [heap_objects]
    cmp byte [rdx + SL_LISTED], 0
    jne .listed
    call heap_list                      ; it was full
.listed:
    cmp dword [rdx + SL_USED], 0
    jne .unlock
    cmp qword [rbx + HC_LISTED], 1      ; empty: keep it if it is the only one
    jbe .unlock
    call heap_unlist
    dec qword [rbx + HC_SLABS]
    dec qword [heap_slabs]
    mov qword [rdx + SL_MAGIC], 0
    HEAP_UNLOCK
    push rdi
    mov rdi, rdx
    sub rdi, [phys_base]
    push rsi
    mov esi, 1
    call pmm_free
    pop rsi
    pop rdi
    jmp .out
.unlock:
    HEAP_UNLOCK
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.null:
    ret
.twice:
    HEAP_UNLOCK
    lea rsi, [str_heap_twice]
    call heap_bad
    jmp .out
.not_start:
    lea rsi, [str_heap_inside]
    call heap_bad
    jmp .out
.not_ours:
    lea rsi, [str_heap_foreign]
    call heap_bad
    jmp .out

kfree_big:
    push rax
    test edi, 15
    jnz .bad
    call vm_free
    test rax, rax                       ; (it panics first, in the kernel)
    jz .out
    shl rax, 12
    lock sub [heap_big_bytes], rax
    lock dec qword [heap_big]
.out:
    pop rax
    ret
.bad:
    push rsi
    lea rsi, [str_heap_foreign]
    call heap_bad
    pop rsi
    pop rax
    ret

section .rodata
str_heap_full:  db 'kmalloc: a full slab on the list (the heap is damaged)', 0
str_heap_written: db 'kmalloc: written to after it was freed', 0
str_heap_twice: db 'kfree: freed twice', 0
str_heap_inside: db 'kfree: not the start of an object', 0
str_heap_foreign: db 'kfree: not something kmalloc gave out', 0

section .data
align 4
heap_lock:      dd 0

section .bss
alignb 8
heap_lo:        resq 1
heap_hi:        resq 1
heap_objects:   resq 1                  ; small objects handed out
heap_bytes:     resq 1                  ; and their bytes, by class size
heap_slabs:     resq 1
heap_big:       resq 1                  ; large objects
heap_big_bytes: resq 1                  ; and the bytes mapped for them
heap_class:     resb HEAP_CLASSES * HC_SIZE
