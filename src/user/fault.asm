; =============================================================================
;  fault.asm - does what a program must not, of the kind asked for; the
;  kernel should end it, and go on
;
;    run fault <null | write | exec | kernel | priv | ud | div | stack | gp |
;               int | io>
; =============================================================================

%include "axe.inc"

main:
    push rbx
    push r12
    lea rbx, [rdi + SB_ARGS]
    lea r12, [kinds]
.kind:
    mov rsi, [r12]
    test rsi, rsi
    jz .unknown
    mov rdi, rbx
.same:                                  ; the first word, against this kind
    mov al, [rsi]
    test al, al
    jz .end_of_kind
    cmp al, [rdi]
    jne .next
    inc rsi
    inc rdi
    jmp .same
.end_of_kind:
    mov al, [rdi]
    test al, al
    jz .found
    cmp al, ' '
    je .found
.next:
    add r12, 16
    jmp .kind
.found:
    lea rsi, [s_doing]
    call ax_add
    mov rsi, [r12]
    call ax_add
    call ax_flush
    call [r12 + 8]
    lea rsi, [s_survived]               ; it should never come back
    call ax_puts
    xor eax, eax
    jmp .out
.unknown:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 1
.out:
    pop r12
    pop rbx
    ret

f_null:                                 ; nothing is mapped at 0
    xor eax, eax
    mov rax, [rax]
    ret

f_write:                                ; code is read-only
    lea rax, [main]
    mov byte [rax], 0xC3
    ret

f_exec:                                 ; data is not code
    lea rax, [not_code]
    call rax
    ret

f_kernel:                               ; the kernel's half is not ring 3's
    mov rax, 0xFFFFFFFF80000000
    mov rax, [rax]
    ret

f_priv:                                 ; nor are its instructions
    cli
    ret

f_ud:
    ud2

f_div:
    xor ecx, ecx
    xor edx, edx
    mov eax, 1
    div ecx
    ret

f_stack:                                ; down into the page below the stack
    push rax
    call f_stack
    ret

f_gp:                                   ; an address not canonical
    mov rax, 0x8000000000000000
    mov rax, [rax]
    ret

f_int:                                  ; no gate is open to ring 3
    int 0x80
    ret

f_io:                                   ; nor any port
    in al, 0x60
    ret

section .rodata
align 8
kinds:          dq k_null, f_null, k_write, f_write, k_exec, f_exec, k_kernel, f_kernel
                dq k_priv, f_priv, k_ud, f_ud, k_div, f_div, k_stack, f_stack
                dq k_gp, f_gp, k_int, f_int, k_io, f_io, 0, 0
k_null:         db 'null', 0
k_write:        db 'write', 0
k_exec:         db 'exec', 0
k_kernel:       db 'kernel', 0
k_priv:         db 'priv', 0
k_ud:           db 'ud', 0
k_div:          db 'div', 0
k_stack:        db 'stack', 0
k_gp:           db 'gp', 0
k_int:          db 'int', 0
k_io:           db 'io', 0
s_doing:        db 'fault: ', 0
s_survived:     db 'fault: survived', 0
s_usage:        db 'usage: run fault <null|write|exec|kernel|priv|ud|div|stack|gp|int|io>', 0

section .data
not_code:       db 0xC3                 ; ret, were it allowed to run

AXE_END
