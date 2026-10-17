; =============================================================================
;  fault.asm - does what a program must not, of the kind asked for; the
;  kernel should end it, and go on
;
;    run fault <null | write | exec | kernel | priv | ud | div | stack | gp |
;               int | io | unmap | close | revoke>
;  The last three touch memory after its mapping went: unmapped, its handle
;  closed, or revoked from the handle it was derived from.
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

f_unmap:                                ; unmapped: gone
    call mapped
    push rax
    mov edi, edx
    mov eax, SYS_UNMAP
    syscall
    pop rax
    mov rax, [rax]
    ret

f_close:                                ; its handle closed: gone
    call mapped
    push rax
    mov edi, edx
    call close
    pop rax
    mov rax, [rax]
    ret

f_revoke:                               ; mapped through one derived, revoked
    push rbx
    mov edi, 4096
    mov eax, SYS_MEM_NEW
    syscall
    mov ebx, eax
    call entry
    mov byte [rdi + SQ_OP], RO_DUP
    mov [rdi + SQ_HANDLE], ebx
    mov qword [rdi + SQ_A0], RT_ALL
    call ax_do
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    mov qword [rax], 1                  ; there, until
    push rax
    call entry
    mov byte [rdi + SQ_OP], RO_REVOKE
    mov [rdi + SQ_HANDLE], ebx
    call ax_do
    pop rax
    pop rbx
    mov rax, [rax]
    ret

; mapped -> RAX = a page mapped, there to be touched, EDX = its handle
mapped:
    mov edi, 4096
    mov eax, SYS_MEM_NEW
    syscall
    push rax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    pop rdx
    mov qword [rax], 1
    ret

; close(EDI = a handle)
close:
    push rdi
    call entry
    pop rax
    mov byte [rdi + SQ_OP], RO_CLOSE
    mov [rdi + SQ_HANDLE], eax
    jmp ax_do

; entry -> RDI = an entry, zeroed
entry:
    lea rdi, [an_entry]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    lea rdi, [an_entry]
    ret

section .rodata
align 8
kinds:          dq k_null, f_null, k_write, f_write, k_exec, f_exec, k_kernel, f_kernel
                dq k_priv, f_priv, k_ud, f_ud, k_div, f_div, k_stack, f_stack
                dq k_gp, f_gp, k_int, f_int, k_io, f_io, k_unmap, f_unmap
                dq k_close, f_close, k_revoke, f_revoke, 0, 0
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
k_unmap:        db 'unmap', 0
k_close:        db 'close', 0
k_revoke:       db 'revoke', 0
s_doing:        db 'fault: ', 0
s_survived:     db 'fault: survived', 0
s_usage:        db 'usage: run fault <null|write|exec|kernel|priv|ud|div|stack|gp|int|io|unmap|close|revoke>', 0

section .data
not_code:       db 0xC3                 ; ret, were it allowed to run

section .bss
alignb 8
an_entry:       resb SQ_SIZE

AXE_END
