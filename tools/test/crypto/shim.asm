; =============================================================================
;  shim.asm - host test shim for src/kernel/crypto.asm (nasm -f win64).
;  Sets up what kernel.asm normally provides (bits 64, default rel, the four
;  sections), includes crypto.asm unchanged, and exports:
;    w_*     Windows x64 ABI wrappers (RCX, RDX, R8, R9, then stack) around
;            each kernel entry point, preserving RBX, RBP, RDI, RSI, R12-R15
;            and XMM6-XMM15 as the ABI requires;
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

global aes_encrypt, aes_cmac, smp_e, smp_ah, smp_c1, smp_s1
global smp_f4, smp_f5, smp_f6, smp_g2, smp_h6, crypto_selftest
global w_aes_encrypt, w_aes_cmac, w_smp_e, w_smp_ah, w_smp_c1, w_smp_s1
global w_smp_f4, w_smp_f5, w_smp_f6, w_smp_g2, w_smp_h6, w_crypto_selftest
global kcall

%include "crypto.asm"

section .text

; Wrapper frame: RSI and RDI pushed, then 40 bytes holding XMM6/XMM7 (the
; kernel may clobber XMM0-XMM7, the ABI keeps XMM6 and up). Stack argument
; n (1-based, so 5 is the first one on the stack) sits at [rsp + ARG(n)].
%define ARG(n) (56 + 8 + 8 * ((n) - 1))

%macro W_ENTER 0
    push rsi
    push rdi
    sub rsp, 40
    movdqu [rsp], xmm6
    movdqu [rsp + 16], xmm7
%endmacro

%macro W_LEAVE 0
    movdqu xmm6, [rsp]
    movdqu xmm7, [rsp + 16]
    add rsp, 40
    pop rdi
    pop rsi
    ret
%endmacro

; void w_aes_encrypt(const u8 key[16], u8 block[16])
w_aes_encrypt:
    W_ENTER
    mov rsi, rcx
    mov rdi, rdx
    call aes_encrypt
    W_LEAVE

; void w_aes_cmac(const u8 key[16], const u8 *msg, u32 len, u8 tag[16])
w_aes_cmac:
    W_ENTER
    mov rsi, rcx
    mov ecx, r8d
    mov rdi, r9
    call aes_cmac
    W_LEAVE

; void w_smp_e(const u8 key[16], u8 block[16])
w_smp_e:
    W_ENTER
    mov rsi, rcx
    mov rdi, rdx
    call smp_e
    W_LEAVE

; void w_smp_ah(const u8 irk[16], const u8 r[3], u8 hash[3])
w_smp_ah:
    W_ENTER
    mov rsi, rcx
    mov rdi, r8
    call smp_ah
    W_LEAVE

; void w_smp_c1(k, r, preq[7], pres[7], ia[7], ra[7], out[16])
w_smp_c1:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov r8, r9
    mov r9, [rsp + ARG(5)]
    mov r10, [rsp + ARG(6)]
    mov rdi, [rsp + ARG(7)]
    call smp_c1
    W_LEAVE

; void w_smp_s1(k, r1, r2, out)
w_smp_s1:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov rdi, r9
    call smp_s1
    W_LEAVE

; void w_smp_f4(u[32], v[32], x[16], u8 z, out[16])
w_smp_f4:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov r8, r9
    mov rdi, [rsp + ARG(5)]
    call smp_f4
    W_LEAVE

; void w_smp_f5(w[32], n1, n2, a1[7], a2[7], mackey[16], ltk[16])
w_smp_f5:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov r8, r9
    mov r9, [rsp + ARG(5)]
    mov rdi, [rsp + ARG(6)]
    mov r10, [rsp + ARG(7)]
    call smp_f5
    W_LEAVE

; void w_smp_f6(w[16], n1, n2, r, io_cap[3], a1[7], a2[7], out[16])
w_smp_f6:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov r8, r9
    mov r9, [rsp + ARG(5)]
    mov r10, [rsp + ARG(6)]
    mov r11, [rsp + ARG(7)]
    mov rdi, [rsp + ARG(8)]
    call smp_f6
    W_LEAVE

; u32 w_smp_g2(u[32], v[32], x[16], y[16])
w_smp_g2:
    W_ENTER
    mov rsi, rcx
    mov rcx, r8
    mov r8, r9
    call smp_g2
    W_LEAVE

; void w_smp_h6(w[16], u32 key_id, out[16])
w_smp_h6:
    W_ENTER
    mov rsi, rcx
    mov rdi, r8
    call smp_h6
    W_LEAVE

; int w_crypto_selftest(void)
w_crypto_selftest:
    W_ENTER
    call crypto_selftest
    W_LEAVE

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
