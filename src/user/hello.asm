; =============================================================================
;  hello.asm - the smallest program worth running: says hello, and where it
;  is, through its ring
;
;    run hello [arguments]
; =============================================================================

%include "axe.inc"

main:
    push rbx
    mov rbx, rdi
    lea rsi, [s_hello]
    call ax_puts
    lea rsi, [s_args]
    call ax_add
    lea rsi, [rbx + SB_ARGS]
    mov ecx, [rbx + SB_ARGS_LEN]
    call ax_addn
    call ax_flush
    lea rsi, [s_code]                   ; where it runs
    call ax_add
    lea rdi, [main]
    call ax_addx
    lea rsi, [s_stack]
    call ax_add
    mov rdi, rsp
    call ax_addx
    lea rsi, [s_ring]
    call ax_add
    mov rdi, [ax_ring_va]
    call ax_addx
    call ax_flush
    xor eax, eax
    pop rbx
    ret

section .rodata
s_hello:        db 'Hello from ring 3!', 10, 0
s_args:         db 'hello: arguments: ', 0
s_code:         db 'hello: code at ', 0
s_stack:        db ', stack at ', 0
s_ring:         db ', ring at ', 0

AXE_END
