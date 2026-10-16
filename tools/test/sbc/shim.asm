; =============================================================================
;  shim.asm - src/kernel/sbc.asm built as a Win64 object for the host test:
;  the kernel's sections and `bits 64` / `default rel`, the encoder included
;  as the kernel includes it, and Windows x64 ABI wrappers around its
;  register convention. sbc_rc_call runs one entry point with every general
;  register loaded from sbc_rc_in and saves them all to sbc_rc_out after, so
;  the C side can check that nothing but RAX changed.
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=64

global sbc_setup_w, sbc_encode_w, sbc_samples_w, sbc_rc_call
global sbc_rc_in, sbc_rc_out
global sbc_cos, sbc_proto4, sbc_proto8

%include "sbc.asm"

; XMM6-XMM15 are callee-saved in the Win64 ABI; the kernel convention lets
; the encoder clobber them
%macro save_xmm 0
    movdqu [rsp], xmm6
    movdqu [rsp + 16], xmm7
    movdqu [rsp + 32], xmm8
    movdqu [rsp + 48], xmm9
    movdqu [rsp + 64], xmm10
    movdqu [rsp + 80], xmm11
    movdqu [rsp + 96], xmm12
    movdqu [rsp + 112], xmm13
    movdqu [rsp + 128], xmm14
    movdqu [rsp + 144], xmm15
%endmacro

%macro restore_xmm 0
    movdqu xmm6, [rsp]
    movdqu xmm7, [rsp + 16]
    movdqu xmm8, [rsp + 32]
    movdqu xmm9, [rsp + 48]
    movdqu xmm10, [rsp + 64]
    movdqu xmm11, [rsp + 80]
    movdqu xmm12, [rsp + 96]
    movdqu xmm13, [rsp + 112]
    movdqu xmm14, [rsp + 128]
    movdqu xmm15, [rsp + 144]
%endmacro

section .text

; int sbc_setup_w(int freq, int mode, int blocks, int subbands, int alloc,
;                 int bitpool)
sbc_setup_w:
    push rdi
    push rsi
    sub rsp, 168
    save_xmm
    mov edi, ecx
    mov esi, edx
    mov edx, r8d
    mov ecx, r9d
    mov r8d, [rsp + 168 + 16 + 40]      ; past the saves, return address and
    mov r9d, [rsp + 168 + 16 + 48]      ; shadow space: arguments 5 and 6
    call sbc_setup
    restore_xmm
    add rsp, 168
    pop rsi
    pop rdi
    ret

; int sbc_encode_w(const int16_t *pcm, uint8_t *out)
sbc_encode_w:
    push rdi
    push rsi
    sub rsp, 168
    save_xmm
    mov rsi, rcx
    mov rdi, rdx
    call sbc_encode
    restore_xmm
    add rsp, 168
    pop rsi
    pop rdi
    ret

; int sbc_samples_w(void)
sbc_samples_w:
    jmp sbc_samples

; uint64_t sbc_rc_call(int which): 0 sbc_setup, 1 sbc_encode, 2 sbc_samples.
; sbc_rc_in: RBX RCX RDX RSI RDI RBP R8-R15, [14] bytes to misalign RSP by,
; [15] RAX. sbc_rc_out: the same registers after the call, [14] = RSP
; difference (0 when the stack came back balanced), [15] = RAX.
sbc_rc_call:
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
    sub rsp, 168
    save_xmm
    lea rax, [sbc_setup]
    cmp ecx, 1
    jb .go
    lea rax, [sbc_encode]
    je .go
    lea rax, [sbc_samples]
.go:
    mov [rc_target], rax
    mov [rc_rsp], rsp
    sub rsp, [sbc_rc_in + 14 * 8]
    mov rbx, [sbc_rc_in + 0 * 8]
    mov rcx, [sbc_rc_in + 1 * 8]
    mov rdx, [sbc_rc_in + 2 * 8]
    mov rsi, [sbc_rc_in + 3 * 8]
    mov rdi, [sbc_rc_in + 4 * 8]
    mov rbp, [sbc_rc_in + 5 * 8]
    mov r8, [sbc_rc_in + 6 * 8]
    mov r9, [sbc_rc_in + 7 * 8]
    mov r10, [sbc_rc_in + 8 * 8]
    mov r11, [sbc_rc_in + 9 * 8]
    mov r12, [sbc_rc_in + 10 * 8]
    mov r13, [sbc_rc_in + 11 * 8]
    mov r14, [sbc_rc_in + 12 * 8]
    mov r15, [sbc_rc_in + 13 * 8]
    mov rax, [sbc_rc_in + 15 * 8]
    call [rc_target]
    mov [sbc_rc_out + 0 * 8], rbx
    mov [sbc_rc_out + 1 * 8], rcx
    mov [sbc_rc_out + 2 * 8], rdx
    mov [sbc_rc_out + 3 * 8], rsi
    mov [sbc_rc_out + 4 * 8], rdi
    mov [sbc_rc_out + 5 * 8], rbp
    mov [sbc_rc_out + 6 * 8], r8
    mov [sbc_rc_out + 7 * 8], r9
    mov [sbc_rc_out + 8 * 8], r10
    mov [sbc_rc_out + 9 * 8], r11
    mov [sbc_rc_out + 10 * 8], r12
    mov [sbc_rc_out + 11 * 8], r13
    mov [sbc_rc_out + 12 * 8], r14
    mov [sbc_rc_out + 13 * 8], r15
    mov [sbc_rc_out + 15 * 8], rax
    mov rax, rsp
    add rax, [sbc_rc_in + 14 * 8]
    sub rax, [rc_rsp]
    mov [sbc_rc_out + 14 * 8], rax
    mov rsp, [rc_rsp]
    restore_xmm
    add rsp, 168
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
    mov rax, [sbc_rc_out + 15 * 8]
    ret

section .data
align 8
sbc_rc_in:      times 16 dq 0
sbc_rc_out:     times 16 dq 0

section .bss
alignb 8
rc_target:      resq 1
rc_rsp:         resq 1
