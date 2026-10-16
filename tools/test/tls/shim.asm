; =============================================================================
;  shim.asm - host test shim for the TLS crypto: src/kernel/sha256.asm,
;  aesgcm.asm and x25519.asm (nasm -f win64). Sets up what kernel.asm
;  normally provides, includes the three unchanged, and exports:
;    kc      u64 kc(void *target, const u64 args[6], int *cf): RDI, RSI,
;            RDX, RCX, R8, R9 from args, call target, return RAX and store
;            the carry flag; preserves what the Windows x64 ABI requires
;            (the kernel functions may clobber XMM0-XMM10);
;    kcall   kcall(target, regs_t *in, regs_t *out, int misalign): load every
;            GPR but RSP and XMM0-XMM15 from *in, call target (with RSP 16-
;            or only 8-byte aligned at its entry), snapshot every register
;            into *out, and store the RSP change in out->gpr[4].
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=64

global sha256_init, sha256_update, sha256_final, sha256, sha256_mode
global hmac_init, hmac_update, hmac_final, hmac_sha256
global hkdf_extract, hkdf_expand, tls13_expand_label
global gcm_supported, gcm_init, gcm_seal, gcm_open
global x25519, x25519_base
global kc, kcall

%include "sha256.asm"
%include "aesgcm.asm"
%include "x25519.asm"

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

; regs_t: gpr[16] in encoding order (rax rcx rdx rbx rsp rbp rsi rdi r8-r15),
; then xmm[16][16]
R_XMM           equ 16 * 8

; void kcall(void *target, regs_t *in, regs_t *out, int misalign)
kcall:
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 168                        ; XMM6-XMM15; leaves RSP 16-aligned
    movdqu [rsp + 0], xmm6
    movdqu [rsp + 16], xmm7
    movdqu [rsp + 32], xmm8
    movdqu [rsp + 48], xmm9
    movdqu [rsp + 64], xmm10
    movdqu [rsp + 80], xmm11
    movdqu [rsp + 96], xmm12
    movdqu [rsp + 112], xmm13
    movdqu [rsp + 128], xmm14
    movdqu [rsp + 144], xmm15
    mov [kc_target], rcx
    mov [kc_out], r8
    mov [kc_saved_rsp], rsp
    test r9d, r9d
    jz .load
    sub rsp, 8                          ; target sees RSP = 0 mod 16 on entry
.load:
%assign i 0
%rep 16
    movdqu xmm %+ i, [rdx + R_XMM + i * 16]
%assign i i + 1
%endrep
    mov rax, [rdx + 0]
    mov rcx, [rdx + 8]
    mov rbx, [rdx + 24]
    mov rbp, [rdx + 40]
    mov rsi, [rdx + 48]
    mov rdi, [rdx + 56]
    mov r8, [rdx + 64]
    mov r9, [rdx + 72]
    mov r10, [rdx + 80]
    mov r11, [rdx + 88]
    mov r12, [rdx + 96]
    mov r13, [rdx + 104]
    mov r14, [rdx + 112]
    mov r15, [rdx + 120]
    mov rdx, [rdx + 16]
    mov [kc_rsp_before], rsp
    call [kc_target]
    mov [kc_rsp_after], rsp
    push rax
    mov rax, [kc_out]
    mov [rax + 8], rcx
    mov [rax + 16], rdx
    mov [rax + 24], rbx
    mov [rax + 40], rbp
    mov [rax + 48], rsi
    mov [rax + 56], rdi
    mov [rax + 64], r8
    mov [rax + 72], r9
    mov [rax + 80], r10
    mov [rax + 88], r11
    mov [rax + 96], r12
    mov [rax + 104], r13
    mov [rax + 112], r14
    mov [rax + 120], r15
    pop rcx
    mov [rax + 0], rcx
%assign i 0
%rep 16
    movdqu [rax + R_XMM + i * 16], xmm %+ i
%assign i i + 1
%endrep
    mov rcx, [kc_rsp_after]
    sub rcx, [kc_rsp_before]
    mov [rax + 32], rcx
    mov rsp, [kc_saved_rsp]
    movdqu xmm6, [rsp + 0]
    movdqu xmm7, [rsp + 16]
    movdqu xmm8, [rsp + 32]
    movdqu xmm9, [rsp + 48]
    movdqu xmm10, [rsp + 64]
    movdqu xmm11, [rsp + 80]
    movdqu xmm12, [rsp + 96]
    movdqu xmm13, [rsp + 112]
    movdqu xmm14, [rsp + 128]
    movdqu xmm15, [rsp + 144]
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

section .bss
alignb 8
kc_target:      resq 1
kc_out:         resq 1
kc_saved_rsp:   resq 1
kc_rsp_before:  resq 1
kc_rsp_after:   resq 1
