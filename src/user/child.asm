; =============================================================================
;  child.asm - a program other programs start (SYS_SPAWN); TEST starts it
;
;    child echo   answers each 8-byte number n on the channel it was given
;                 with 2n + 1, until 0 comes or the channel closes; returns
;                 how many it answered
;    child deep   starts another 'child deep', and returns what that one
;                 returned, plus 1; 0 once it may start no more
;    child hold   starts 'child sleep', handing on what it was given, and
;                 waits for ever
;    child sleep  sends 'ready' on the channel it was given, and waits for
;                 ever
; =============================================================================

%include "axe.inc"
WANTS nothing

main:
    push rbx
    push r12
    lea rbx, [rdi + SB_ARGS]
    lea r12, [modes]
.mode:
    mov rsi, [r12]
    test rsi, rsi
    jz .unknown
    mov rdi, rbx
.same:                                  ; the first word, against this mode
    mov al, [rsi]
    test al, al
    jz .end_of_mode
    cmp al, [rdi]
    jne .next
    inc rsi
    inc rdi
    jmp .same
.end_of_mode:
    mov al, [rdi]
    test al, al
    jz .found
    cmp al, ' '
    je .found
.next:
    add r12, 16
    jmp .mode
.found:
    call [r12 + 8]
    jmp .out
.unknown:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
.out:
    pop r12
    pop rbx
    ret

m_echo:
    push rbx
    xor ebx, ebx                        ; how many answered
    mov eax, 98
    cmp dword [ax_gift], 0
    je .out
.next:
    mov edi, [ax_gift]
    lea rsi, [number]
    mov edx, 8
    xor ecx, ecx
    call ax_recv
    cmp rax, 8
    jne .done
    mov rax, [number]
    test rax, rax
    jz .done
    lea rax, [rax * 2 + 1]
    mov [number], rax
    mov edi, [ax_gift]
    lea rsi, [number]
    mov edx, 8
    call ax_send
    cmp rax, 8
    jne .done
    inc ebx
    jmp .next
.done:
    mov eax, ebx
.out:
    pop rbx
    ret

m_deep:
    lea rsi, [s_deep]
    xor edi, edi
    call ax_spawn
    test rax, rax
    js .last                            ; as deep as may be
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_JOIN
    mov [rsp + SQ_HANDLE], edx
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    test rax, rax
    jnz .failed
    lea rax, [rdx + 1]
    ret
.last:
    xor eax, eax
    ret
.failed:
    mov eax, 97
    ret

m_hold:
    lea rsi, [s_sleep]
    mov edi, [ax_gift]
    call ax_spawn
    test rax, rax
    js .failed
    jmp wait_ever
.failed:
    mov eax, 96
    ret

m_sleep:
    mov edi, [ax_gift]
    lea rsi, [s_ready]
    mov edx, 5
    call ax_send
    jmp wait_ever

; wait_ever: a second at a time, in its ring, until killed
wait_ever:
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_TIMEOUT
    call ax_now
    push rax
    mov edi, 1000000
    call ax_us
    pop rcx
    add rax, rcx
    mov [rsp + SQ_DEADLINE], rax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    jmp wait_ever

section .rodata
align 8
modes:          dq k_echo, m_echo, k_deep, m_deep, k_hold, m_hold, k_sleep, m_sleep, 0, 0
k_echo:         db 'echo', 0
k_deep:         db 'deep', 0
k_hold:         db 'hold', 0
k_sleep:        db 'sleep', 0
s_deep:         db 'child deep', 0
s_sleep:        db 'child sleep', 0
s_ready:        db 'ready'
s_usage:        db 'usage: child <echo|deep|hold|sleep>', 0

section .bss
alignb 8
number:         resq 1

AXE_END
