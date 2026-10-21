; =============================================================================
;  shim.asm - host test shim for what checks certificates (nasm -f win64):
;  src/kernel/sha256.asm, sha512.asm, rand.asm, bignum.asm, pubkey.asm and
;  x509.asm
;  (with gen/roots.asm), included unchanged, linked into a DLL with host.c.
;  Exports:
;    kc      u64 kc(void *target, const u64 args[6], int *cf): RDI, RSI,
;            RDX, RCX, R8, R9 from args, call target, return RAX and store
;            the carry flag, preserving what the Windows x64 ABI requires;
;    kcheck  void kcheck(void *target, const u64 args[6], int *cf, u64
;            regs[32]): the same, with every other register but RSP loaded
;            with a pattern; all sixteen (encoding order) before the call go
;            to regs[0..15], after it to regs[16..31];
;    x5_text const char *x5_text(int error), Windows ABI.
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=64

global kc, kcheck, x5_text
global sha384, sha512, mont_setup, mont_mul, mont_in, mont_out, mont_add, mont_sub
global mont_exp, bn_load, bn_store, sig_verify, sig_sign, ec_public
global x509_chain, x509_leaf, x509_parse
global x509_unix, x509_extra, x509_anchor, x509_depth, x509_key, x509_roots

%include "sha256.asm"
%include "sha512.asm"
%include "rand.asm"
%include "bignum.asm"
%include "pubkey.asm"
%include "x509.asm"

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

x5_text:
    mov eax, ecx
    jmp x509_error_text

section .bss
alignb 8
kk_target:      resq 1
kk_cf:          resq 1
kk_regs:        resq 1
