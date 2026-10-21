; =============================================================================
;  spin.asm - never ends on its own: n threads that spin in ring 3, or park
;  in the ring, or go in and out of the kernel, or one of which faults. For
;  ctrl+C and 'user test', which kill it.
;
;    run spin [n] [wait | calls | fault]
; =============================================================================

%include "axe.inc"
WANTS nothing

THREAD_STACK    equ 16384
SPIN_MAX        equ 64

main:
    push rbx
    push r12
    push r13
    lea rbx, [rdi + SB_ARGS]
    xor r12d, r12d                      ; n
.digit:
    movzx eax, byte [rbx]
    sub eax, '0'
    cmp eax, 9
    ja .counted
    imul r12d, r12d, 10
    add r12d, eax
    inc rbx
    jmp .digit
.counted:
    test r12d, r12d
    jnz .some
    mov r12d, 1
.some:
    cmp r12d, SPIN_MAX
    jbe .mode
    mov r12d, SPIN_MAX
.mode:
    cmp byte [rbx], ' '
    jne .moded
    inc rbx
    jmp .mode
.moded:
    lea rax, [spin]                     ; what each thread does
    cmp byte [rbx], 'w'
    jne .not_wait
    lea rax, [park]
.not_wait:
    cmp byte [rbx], 'c'
    jne .not_calls
    lea rax, [calls]
.not_calls:
    mov [work], rax
    mov [first], rax
    cmp byte [rbx], 'f'
    jne .not_fault
    lea rax, [faults]
    mov [first], rax
.not_fault:
    lea rsi, [s_spin]
    call ax_add
    mov edi, r12d
    call ax_addu
    lea rsi, [s_threads]
    call ax_add
    call ax_flush
    mov edi, r12d                       ; stacks for the others
    imul edi, edi, THREAD_STACK
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .out
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .out
    mov r13, rax
    mov ebx, 1
.start:
    cmp ebx, r12d
    jae .run
    lea rsi, [rbx + 1]
    imul rsi, rsi, THREAD_STACK
    add rsi, r13
    mov rdi, [work]
    cmp ebx, 1
    jne .entry
    mov rdi, [first]                    ; the one that faults, if one does
.entry:
    xor edx, edx
    mov eax, SYS_THREAD_NEW
    syscall
    test rax, rax
    js .out
    inc ebx
    jmp .start
.run:
    call [work]                         ; and so does this one
.out:
    pop r13
    pop r12
    pop rbx
    ret

spin:
    pause
    jmp spin

park:                                   ; for a completion that never comes
    xor edi, edi
    mov esi, 1
    call ax_enter
    jmp park

calls:
    mov eax, SYS_YIELD
    syscall
    jmp calls

faults:                                 ; a while, then a fault
    mov ecx, 100000
.wait:
    pause
    dec ecx
    jnz .wait
    xor eax, eax
    mov rax, [rax]
    jmp spin

section .rodata
s_spin:         db 'spin: ', 0
s_threads:      db ' threads', 0

section .bss
alignb 8
work:           resq 1
first:          resq 1

AXE_END
