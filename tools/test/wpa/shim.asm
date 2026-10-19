; =============================================================================
;  shim.asm - host test shim for the WPA2 crypto: src/kernel/wpa.asm, with
;  crypto.asm's AES-128 under it (nasm -f win64, linked into a DLL that
;  tools/test/wpa/run.py loads with ctypes). Exports every entry point and
;    kc      void kc(void *target, const u64 args[7], u64 out[3]): RDI, RSI,
;            RDX, RCX, R8, R9, R10 from args, the other registers loaded with
;            patterns, call target; out[0] = RAX, out[1] = the carry flag,
;            out[2] = a bit for each register but RAX and RSP that came back
;            changed (bit n: rbx rbp rsi rdi rcx rdx r8 r9 r10 r11 r12 r13 r14
;            r15). Preserves what the Windows x64 ABI requires.
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=64

global sha1, sha1_init, sha1_update, sha1_final
global hmac1_init, hmac1_update, hmac1_final, hmac_sha1
global prf_sha1, pbkdf2_sha1, aes_unwrap, ccmp_seal, ccmp_open
global kc

%include "crypto.asm"
%include "wpa.asm"

section .text

%macro CHECK 2                          ; register, its bit
    cmp %1, [kc_in + %2 * 8]
    je %%same
    or qword [kc_mask], 1 << %2
%%same:
%endmacro

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
    mov [kc_target], rcx
    mov [kc_out], r8
    mov rdi, [rdx]
    mov rsi, [rdx + 8]
    mov rcx, [rdx + 24]
    mov r8, [rdx + 32]
    mov r9, [rdx + 40]
    mov r10, [rdx + 48]
    mov rdx, [rdx + 16]
    mov rbx, 0x5B5B5B5B5B5B5B01
    mov rbp, 0x5B5B5B5B5B5B5B02
    mov r11, 0x5B5B5B5B5B5B5B03
    mov r12, 0x5B5B5B5B5B5B5B04
    mov r13, 0x5B5B5B5B5B5B5B05
    mov r14, 0x5B5B5B5B5B5B5B06
    mov r15, 0x5B5B5B5B5B5B5B07
    mov [kc_in + 0 * 8], rbx
    mov [kc_in + 1 * 8], rbp
    mov [kc_in + 2 * 8], rsi
    mov [kc_in + 3 * 8], rdi
    mov [kc_in + 4 * 8], rcx
    mov [kc_in + 5 * 8], rdx
    mov [kc_in + 6 * 8], r8
    mov [kc_in + 7 * 8], r9
    mov [kc_in + 8 * 8], r10
    mov [kc_in + 9 * 8], r11
    mov [kc_in + 10 * 8], r12
    mov [kc_in + 11 * 8], r13
    mov [kc_in + 12 * 8], r14
    mov [kc_in + 13 * 8], r15
    mov qword [kc_mask], 0
    call [kc_target]
    setc byte [kc_cf]
    CHECK rbx, 0
    CHECK rbp, 1
    CHECK rsi, 2
    CHECK rdi, 3
    CHECK rcx, 4
    CHECK rdx, 5
    CHECK r8, 6
    CHECK r9, 7
    CHECK r10, 8
    CHECK r11, 9
    CHECK r12, 10
    CHECK r13, 11
    CHECK r14, 12
    CHECK r15, 13
    mov rcx, [kc_out]
    mov [rcx], rax
    movzx eax, byte [kc_cf]
    mov [rcx + 8], rax
    mov rax, [kc_mask]
    mov [rcx + 16], rax
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

section .bss
kc_target:      resq 1
kc_out:         resq 1
kc_in:          resq 14
kc_mask:        resq 1
kc_cf:          resb 1
