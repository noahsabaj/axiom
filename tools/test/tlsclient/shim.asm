; =============================================================================
;  shim.asm - host test shim for src/kernel/tls.asm (nasm -f win64), linked
;  into a DLL with host.c. Includes the TLS client and what it stands on
;  (sha256, sha512, aesgcm, x25519, rand, bignum, pubkey, x509 with the
;  built-in roots) unchanged, and exports:
;    kc      u64 kc(void *target, const u64 args[6], int *cf): RDI, RSI,
;            RDX, RCX, R8, R9 from args, call target, return RAX and store
;            the carry flag, preserving what the Windows x64 ABI requires;
;    host_send, host_ops: the client's send function and handlers, which
;            pass each event on to host.c (c_send, c_ready, c_data,
;            c_closed, c_fail) with the Windows ABI.
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=64

global tls_start, tls_input, tls_write, tls_close, tls_abort, tls_error_text
global tls_state, tls_error, tls_alert, tls_certs, tls_cert_bytes, tls_sigalg
global tls_cert_err, tls_verified, x509_extra, x509_anchor, x509_depth, tl_have_key
global kc, host_send, host_ops, tl_text
extern c_send, c_ready, c_data, c_closed, c_fail

%include "sha256.asm"
%include "sha512.asm"
%include "aesgcm.asm"
%include "x25519.asm"
%include "rand.asm"
%include "bignum.asm"
%include "pubkey.asm"
%include "x509.asm"
%include "tls.asm"

section .text

; u64 kc(void *target, const u64 args[6], int *cf)
kc:
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
    ret

; const char *tl_text(int error), Windows ABI
tl_text:
    mov eax, ecx
    jmp tls_error_text

; Into C: RSP aligned, shadow space; RSI, RDI and the callee-saved
; registers survive the Windows ABI, XMM6-15 too.
%macro TO_C 1
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32
    call %1
    mov rsp, rbp
    pop rbp
%endmacro

; send(RSI = bytes, EDX = how many) -> CF
host_send:
    mov rcx, rsi
    TO_C c_send
    test eax, eax
    jz .ok
    stc
    ret
.ok:
    clc
    ret

host_ready:
    TO_C c_ready
    ret

host_data:
    mov rcx, rsi
    TO_C c_data
    ret

host_closed:
    TO_C c_closed
    ret

host_fail:
    mov ecx, eax
    TO_C c_fail
    ret

section .rodata
align 8
host_ops:       dq host_ready, host_data, host_closed, host_fail
