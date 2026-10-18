; =============================================================================
;  hello.asm - the smallest program worth running: says hello, where it is,
;  and what it was given (the network, the store, the desktop), through its
;  ring
;
;    hello [arguments]
; =============================================================================

%include "axe.inc"
WANTS nothing

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
    lea rsi, [s_given]                  ; and what it was given
    call ax_add
    xor ebx, ebx                        ; how many
    cmp dword [ax_net], 0
    je .no_net
    lea rsi, [s_net]
    call ax_add
    inc ebx
.no_net:
    cmp dword [ax_store], 0
    je .no_store
    lea rsi, [s_store]
    call ax_add
    inc ebx
.no_store:
    cmp dword [ax_desk], 0
    je .no_desk
    lea rsi, [s_desk]
    call ax_add
    inc ebx
.no_desk:
    cmp dword [ax_settings], 0
    je .no_settings
    lea rsi, [s_settings]
    call ax_add
    inc ebx
.no_settings:
    test ebx, ebx
    jnz .given
    lea rsi, [s_nothing]
    call ax_add
.given:
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
s_given:        db 'hello: given:', 0
s_net:          db ' net', 0
s_store:        db ' store', 0
s_desk:         db ' desk', 0
s_settings:     db ' settings', 0
s_nothing:      db ' nothing', 0

AXE_END
