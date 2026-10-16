; =============================================================================
;  shim.asm - host test shim for src/kernel/heap.asm (nasm -f win64): the
;  heap included unchanged, with HOST_TEST defined (no CLI in user mode),
;  linked into a DLL with host.c. What the heap needs from the kernel is
;  stood in for here, each keeping the kernel's convention (preserve every
;  register but RAX):
;    pmm_alloc, pmm_free     4 KiB pages from a pool, each one tracked, so a
;                            page freed twice or never handed out is counted
;    vm_alloc, vm_free,      page-aligned blocks from a second pool, freed
;    vm_contains             ones filled with 0xEE
;    spin_lock               the kernel's
;    phys_base, boot_info    0, and a boot block whose direct map is all of
;                            the lower half
;    heap_bad                counts and keeps the last address and reason
;  Exports kc and kcheck (as in tools/test/pki/shim.asm) to call any of it.
; =============================================================================

bits 64
default rel

%define HOST_TEST
%include "bootinfo.inc"

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=4096

global kc, kcheck, kmalloc, kfree, heap_init, s_bench
global heap_objects, heap_bytes, heap_slabs, heap_big, heap_big_bytes, heap_class
global s_bad_count, s_bad_addr, s_bad_why, s_pages_out, s_vm_out, s_errors
global pool, vpool

POOL_PAGES      equ 8192                ; 32 MiB of "physical" pages
VPOOL_PAGES     equ 32768               ; 128 MiB for large objects

%include "heap.asm"

section .text

%macro WIN_SAVE 0
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 168                        ; XMM6-XMM15; leaves RSP 16-aligned
%assign i 6
%rep 10
    movdqu [rsp + (i - 6) * 16], xmm %+ i
%assign i i + 1
%endrep
%endmacro

%macro WIN_RESTORE 0
%assign i 6
%rep 10
    movdqu xmm %+ i, [rsp + (i - 6) * 16]
%assign i i + 1
%endrep
    add rsp, 168
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
%endmacro

; u64 kc(void *target, const u64 args[6], int *cf)
kc:
    WIN_SAVE
    mov rax, rcx
    mov r12, r8
    mov rdi, [rdx]
    mov rsi, [rdx + 8]
    mov rcx, [rdx + 24]
    mov r8, [rdx + 32]
    mov r9, [rdx + 40]
    mov rdx, [rdx + 16]
    call rax
    setc cl
    movzx ecx, cl
    mov [r12], ecx
    WIN_RESTORE
    ret

%macro SNAP 1                           ; every GPR into [kk_regs] + %1
    push rax
    mov rax, [kk_regs]
    mov [rax + %1 + 8], rcx
    mov [rax + %1 + 16], rdx
    mov [rax + %1 + 24], rbx
    mov [rax + %1 + 40], rbp
    mov [rax + %1 + 48], rsi
    mov [rax + %1 + 56], rdi
    mov [rax + %1 + 64], r8
    mov [rax + %1 + 72], r9
    mov [rax + %1 + 80], r10
    mov [rax + %1 + 88], r11
    mov [rax + %1 + 96], r12
    mov [rax + %1 + 104], r13
    mov [rax + %1 + 112], r14
    mov [rax + %1 + 120], r15
    lea rcx, [rsp + 8]
    mov [rax + %1 + 32], rcx
    mov rcx, [rsp]
    mov [rax + %1], rcx
    mov rcx, [rax + %1 + 8]
    pop rax
%endmacro

; void kcheck(void *target, const u64 args[6], int *cf, u64 regs[32])
kcheck:
    WIN_SAVE
    mov [kk_target], rcx
    mov [kk_cf], r8
    mov [kk_regs], r9
    mov rax, rdx
    mov rdi, [rax]
    mov rsi, [rax + 8]
    mov rdx, [rax + 16]
    mov rcx, [rax + 24]
    mov r8, [rax + 32]
    mov r9, [rax + 40]
    mov rax, 0xA0A0A0A0A0A0A0A0
    mov rbx, 0xB1B1B1B1B1B1B1B1
    mov rbp, 0xB5B5B5B5B5B5B5B5
    mov r10, 0x1A1A1A1A1A1A1A1A
    mov r11, 0x1B1B1B1B1B1B1B1B
    mov r12, 0x1C1C1C1C1C1C1C1C
    mov r13, 0x1D1D1D1D1D1D1D1D
    mov r14, 0x1E1E1E1E1E1E1E1E
    mov r15, 0x1F1F1F1F1F1F1F1F
    SNAP 0
    call [kk_target]
    pushfq
    SNAP 128
    pop rcx
    and ecx, 1
    mov rax, [kk_cf]
    mov [rax], ecx
    mov rax, [kk_regs]                  ; RSP as the target left it
    add qword [rax + 128 + 32], 8
    WIN_RESTORE
    ret

; s_bench(RDI = pairs, RSI = size): kmalloc + kfree that many times
s_bench:
    push rdi
    push rcx
    mov rcx, rdi
.pair:
    mov rdi, rsi
    call kmalloc
    mov rdi, rax
    call kfree
    dec rcx
    jnz .pair
    pop rcx
    pop rdi
    ret

; ---- the kernel's side, stood in for ----------------------------------------

spin_lock:
    push rax
.try:
    mov eax, 1
    xchg eax, [rdi]
    test eax, eax
    jz .taken
.wait:
    pause
    cmp dword [rdi], 0
    jne .wait
    jmp .try
.taken:
    pop rax
    ret

s_lock:
    push rdi
    lea rdi, [s_lock_word]
    call spin_lock
    pop rdi
    ret

s_unlock:
    mov dword [s_lock_word], 0
    ret

; pmm_alloc(RDI = pages) -> RAX = address of that many pages, 0 if none
pmm_alloc:
    push rcx
    push rdx
    push rsi
    call s_lock
    lea rsi, [pool_map]
    xor ecx, ecx
.try:
    lea rdx, [rcx + rdi]
    cmp rdx, POOL_PAGES
    ja .none
    mov rax, rcx
.scan:
    cmp rax, rdx
    jae .found
    cmp byte [rsi + rax], 0
    jne .busy
    inc rax
    jmp .scan
.busy:
    lea rcx, [rax + 1]
    jmp .try
.found:
    mov rax, rcx
.take:
    mov byte [rsi + rax], 1
    inc rax
    cmp rax, rdx
    jb .take
    add [s_pages_out], rdi
    mov rax, rcx
    shl rax, 12
    lea rdx, [pool]
    add rax, rdx
    jmp .out
.none:
    xor eax, eax
.out:
    call s_unlock
    pop rsi
    pop rdx
    pop rcx
    ret

; pmm_free(RDI = address, RSI = pages)
pmm_free:
    push rax
    push rcx
    push rdx
    call s_lock
    lea rax, [pool]
    mov rcx, rdi
    sub rcx, rax
    test ecx, 0xFFF
    jnz .bad
    shr rcx, 12
    lea rdx, [rcx + rsi]
    cmp rdx, POOL_PAGES
    ja .bad
    lea rax, [pool_map]
.page:
    cmp rcx, rdx
    jae .out
    cmp byte [rax + rcx], 0
    je .bad
    mov byte [rax + rcx], 0
    dec qword [s_pages_out]
    inc rcx
    jmp .page
.bad:
    inc qword [s_errors]
.out:
    call s_unlock
    pop rdx
    pop rcx
    pop rax
    ret

; vm_alloc(RDI = bytes) -> RAX = zeroed, page-aligned, 0 if none
vm_alloc:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    test rdi, rdi
    jz .zero
    lea r8, [rdi + 0xFFF]
    shr r8, 12                          ; pages
    call s_lock
    lea rsi, [vpool_map]
    xor ecx, ecx
.try:
    lea rdx, [rcx + r8]
    cmp rdx, VPOOL_PAGES
    ja .none
    mov rax, rcx
.scan:
    cmp rax, rdx
    jae .found
    cmp byte [rsi + rax], 0
    jne .busy
    inc rax
    jmp .scan
.busy:
    lea rcx, [rax + 1]
    jmp .try
.found:
    mov rax, rcx
.take:
    mov byte [rsi + rax], 1
    inc rax
    cmp rax, rdx
    jb .take
    lea rax, [vpool_len]
    mov [rax + rcx * 4], r8d
    inc qword [s_vm_out]
    call s_unlock
    mov rax, rcx
    shl rax, 12
    lea rdx, [vpool]
    add rax, rdx
    mov rdi, rax
    mov rcx, r8
    shl rcx, 9
    mov rdx, rax
    xor eax, eax
    rep stosq
    mov rax, rdx
    jmp .out
.none:
    call s_unlock
.zero:
    xor eax, eax
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; vm_free(RDI = in the first page of a block) -> RAX = its pages
vm_free:
    push rcx
    push rdx
    push rdi
    push rsi
    call s_lock
    lea rax, [vpool]
    mov rcx, rdi
    and rcx, ~0xFFF
    sub rcx, rax
    shr rcx, 12
    cmp rcx, VPOOL_PAGES
    jae .bad
    lea rax, [vpool_len]
    mov edx, [rax + rcx * 4]
    test edx, edx
    jz .bad
    mov dword [rax + rcx * 4], 0
    push rcx                            ; poison it, while it is still ours
    lea rdi, [vpool]
    shl rcx, 12
    add rdi, rcx
    mov rcx, rdx
    shl rcx, 9
    mov rax, 0xEEEEEEEEEEEEEEEE
    rep stosq
    pop rcx
    lea rsi, [vpool_map]
    push rdx
.page:
    mov byte [rsi + rcx], 0
    inc rcx
    dec edx
    jnz .page
    pop rdx
    dec qword [s_vm_out]
    call s_unlock
    mov eax, edx
    jmp .out
.bad:
    inc qword [s_errors]
    call s_unlock
    xor eax, eax
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

vm_contains:
    push rax
    push rdx
    lea rax, [vpool]
    mov rdx, rdi
    sub rdx, rax
    cmp rdx, VPOOL_PAGES * 4096         ; CF = in the pool
    pop rdx
    pop rax
    ret

heap_bad:
    lock inc qword [s_bad_count]
    mov [s_bad_addr], rdi
    mov [s_bad_why], rsi
    ret

section .data
align 8
phys_base:      dq 0
boot_info:      dq s_bootinfo
s_bootinfo:
    times BI_PHYS_TOP db 0
    dq 1 << 47
    times BI_SIZE - BI_PHYS_TOP - 8 db 0
s_lock_word:    dd 0

section .bss
alignb 4096
pool:           resb POOL_PAGES * 4096
vpool:          resb VPOOL_PAGES * 4096
pool_map:       resb POOL_PAGES
vpool_map:      resb VPOOL_PAGES
alignb 8
vpool_len:      resd VPOOL_PAGES
s_bad_count:    resq 1
s_bad_addr:     resq 1
s_bad_why:      resq 1
s_pages_out:    resq 1
s_vm_out:       resq 1
s_errors:       resq 1
kk_target:      resq 1
kk_cf:          resq 1
kk_regs:        resq 1
