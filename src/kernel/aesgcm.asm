; =============================================================================
;  aesgcm.asm - AES-128-GCM (NIST SP 800-38D) on AES-NI and PCLMULQDQ: the
;  record protection of TLS_AES_128_GCM_SHA256. 96-bit IVs, 16-byte tags.
;  GHASH multiplies byte-reflected blocks with four carry-less products, a
;  one-bit shift and the two-phase reduction of Gueron and Kounavis, "Intel
;  Carry-Less Multiplication Instruction and its Usage for Computing the GCM
;  Mode" (2014).
;
;    gcm_supported -> CF if the CPU lacks AES-NI, PCLMULQDQ or SSSE3
;    gcm_init(RDI = ctx, RSI = key[16])
;    gcm_seal(RDI = ctx, RSI = iv[12], RDX = aad, RCX = its bytes,
;             R8 = data, R9 = its bytes): encrypted in place, the tag
;             written after it
;    gcm_open(the same, R9 = bytes before the tag) -> CF if the tag is
;             wrong, and then the data is left as it was; else decrypted
;             in place
;
;  A context is GCM_CTX bytes, any alignment. Every function preserves all
;  general registers but RAX and clobbers XMM0-XMM9. Scratch (the round keys
;  copied out aligned, the counter, the hash) lives in .bss: main loop only.
; =============================================================================

GK_RK           equ 0                   ; round keys 0-10
GK_H            equ 176                 ; H = E(0), byte-reflected
GCM_CTX         equ 192

section .text

gcm_supported:
    push rbx
    push rcx
    push rdx
    mov eax, 1
    cpuid
    mov eax, ecx
    and eax, (1 << 25) | (1 << 1) | (1 << 9)
    cmp eax, (1 << 25) | (1 << 1) | (1 << 9)
    clc
    je .out
    stc
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

%macro AES_KEY_STEP 2                   ; round constant, round
    aeskeygenassist xmm2, xmm1, %1
    pshufd xmm2, xmm2, 0xFF
    movdqa xmm3, xmm1
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pxor xmm1, xmm2
    movdqu [rdi + GK_RK + %2 * 16], xmm1
%endmacro

gcm_init:
    movdqu xmm1, [rsi]
    movdqu [rdi + GK_RK], xmm1
    AES_KEY_STEP 0x01, 1
    AES_KEY_STEP 0x02, 2
    AES_KEY_STEP 0x04, 3
    AES_KEY_STEP 0x08, 4
    AES_KEY_STEP 0x10, 5
    AES_KEY_STEP 0x20, 6
    AES_KEY_STEP 0x40, 7
    AES_KEY_STEP 0x80, 8
    AES_KEY_STEP 0x1b, 9
    AES_KEY_STEP 0x36, 10
    call gcm_load
    pxor xmm0, xmm0                     ; H = E(K, 0)
    call gcm_aes
    pshufb xmm0, [gcm_rev]
    movdqu [rdi + GK_H], xmm0
    ret

; gcm_load(RDI = ctx): its round keys and H into the aligned scratch
gcm_load:
    push rcx
    push rsi
    push rdi
    mov rsi, rdi
    lea rdi, [gk_rk]
    mov ecx, GCM_CTX
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; gcm_aes: XMM0 = E(K, XMM0)
gcm_aes:
    pxor xmm0, [gk_rk]
%assign r 1
%rep 9
    aesenc xmm0, [gk_rk + r * 16]
%assign r r + 1
%endrep
    aesenclast xmm0, [gk_rk + 160]
    ret

; gcm_start(RSI = iv[12]): J0 = IV || 1, the hash cleared, the counter at 2
gcm_start:
    push rcx
    push rdi
    push rsi
    lea rdi, [gk_j0]
    mov ecx, 12
    rep movsb
    mov dword [gk_j0 + 12], 0x01000000
    pop rsi
    push rsi
    lea rdi, [gk_cb]
    mov ecx, 12
    rep movsb
    mov dword [gk_n], 2
    pxor xmm0, xmm0
    movdqa [gk_x], xmm0
    pop rsi
    pop rdi
    pop rcx
    ret

; gcm_gfmul: XMM0 = XMM0 * XMM1 in GF(2^128), both byte-reflected.
; Clobbers XMM2-XMM9.
gcm_gfmul:
    movdqa xmm3, xmm0
    pclmulqdq xmm3, xmm1, 0x00
    movdqa xmm4, xmm0
    pclmulqdq xmm4, xmm1, 0x10
    movdqa xmm5, xmm0
    pclmulqdq xmm5, xmm1, 0x01
    movdqa xmm6, xmm0
    pclmulqdq xmm6, xmm1, 0x11
    pxor xmm4, xmm5
    movdqa xmm5, xmm4
    psrldq xmm4, 8
    pslldq xmm5, 8
    pxor xmm3, xmm5
    pxor xmm6, xmm4                     ; XMM6:XMM3 = the 256-bit product
    movdqa xmm7, xmm3                   ; shifted left one bit
    movdqa xmm8, xmm6
    pslld xmm3, 1
    pslld xmm6, 1
    psrld xmm7, 31
    psrld xmm8, 31
    movdqa xmm9, xmm7
    pslldq xmm8, 4
    pslldq xmm7, 4
    psrldq xmm9, 12
    por xmm3, xmm7
    por xmm6, xmm8
    por xmm6, xmm9
    movdqa xmm7, xmm3                   ; reduction, first phase
    movdqa xmm8, xmm3
    movdqa xmm9, xmm3
    pslld xmm7, 31
    pslld xmm8, 30
    pslld xmm9, 25
    pxor xmm7, xmm8
    pxor xmm7, xmm9
    movdqa xmm8, xmm7
    pslldq xmm7, 12
    psrldq xmm8, 4
    pxor xmm3, xmm7
    movdqa xmm2, xmm3                   ; second phase
    movdqa xmm4, xmm3
    movdqa xmm5, xmm3
    psrld xmm2, 1
    psrld xmm4, 2
    psrld xmm5, 7
    pxor xmm2, xmm4
    pxor xmm2, xmm5
    pxor xmm2, xmm8
    pxor xmm3, xmm2
    pxor xmm6, xmm3
    movdqa xmm0, xmm6
    ret

; gcm_ghash(RSI = data, RCX = bytes): into gk_x, the last block zero-padded.
; Preserves all but RAX.
gcm_ghash:
    push rcx
    push rsi
    push rdi
    movdqu xmm1, [gk_h]
.block:
    test rcx, rcx
    jz .out
    cmp rcx, 16
    jb .partial
    movdqu xmm0, [rsi]
    add rsi, 16
    sub rcx, 16
    jmp .mul
.partial:
    pxor xmm0, xmm0
    movdqa [gk_tmp], xmm0
    lea rdi, [gk_tmp]
    rep movsb                           ; RCX = 0 after
    movdqa xmm0, [gk_tmp]
.mul:
    pshufb xmm0, [gcm_rev]
    pxor xmm0, [gk_x]
    call gcm_gfmul
    movdqa [gk_x], xmm0
    jmp .block
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; gcm_ctr(RSI = data, RCX = bytes): XORed with E(K, counter) in place,
; counting from gk_n. Preserves all but RAX.
gcm_ctr:
    push rcx
    push rdx
    push rsi
    push rdi
.block:
    test rcx, rcx
    jz .out
    mov eax, [gk_n]
    inc dword [gk_n]
    bswap eax
    mov [gk_cb + 12], eax
    movdqa xmm0, [gk_cb]
    call gcm_aes
    cmp rcx, 16
    jb .partial
    movdqu xmm1, [rsi]
    pxor xmm1, xmm0
    movdqu [rsi], xmm1
    add rsi, 16
    sub rcx, 16
    jmp .block
.partial:
    movdqa [gk_tmp], xmm0
    lea rdi, [gk_tmp]
.byte:
    mov al, [rdi]
    xor [rsi], al
    inc rdi
    inc rsi
    dec rcx
    jnz .byte
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; gcm_tag(RCX = aad bytes, R9 = data bytes) -> XMM0 = the tag: the lengths
; hashed in, then E(K, J0) ^ GHASH. Preserves all but RAX.
gcm_tag:
    push rcx
    push rsi
    mov rax, rcx
    shl rax, 3
    bswap rax
    mov [gk_tmp], rax
    mov rax, r9
    shl rax, 3
    bswap rax
    mov [gk_tmp + 8], rax
    lea rsi, [gk_tmp]
    mov ecx, 16
    call gcm_ghash
    movdqa xmm0, [gk_j0]
    call gcm_aes
    movdqa xmm1, [gk_x]
    pshufb xmm1, [gcm_rev]
    pxor xmm0, xmm1
    pop rsi
    pop rcx
    ret

gcm_seal:
    push rcx
    push rsi
    call gcm_load
    call gcm_start
    mov rsi, rdx                        ; the additional data
    call gcm_ghash
    push rcx
    mov rsi, r8                         ; encrypt, then hash the ciphertext
    mov rcx, r9
    call gcm_ctr
    call gcm_ghash
    pop rcx
    call gcm_tag
    movdqu [r8 + r9], xmm0
    pop rsi
    pop rcx
    ret

gcm_open:
    push rcx
    push rsi
    call gcm_load
    call gcm_start
    mov rsi, rdx
    call gcm_ghash
    push rcx
    mov rsi, r8                         ; hash the ciphertext first
    mov rcx, r9
    call gcm_ghash
    pop rcx
    call gcm_tag
    movdqu xmm1, [r8 + r9]              ; compare in constant time
    pxor xmm0, xmm1
    pxor xmm2, xmm2
    pcmpeqb xmm0, xmm2
    pmovmskb eax, xmm0
    cmp eax, 0xFFFF
    jne .bad
    mov rsi, r8
    mov rcx, r9
    call gcm_ctr
    clc
    jmp .out
.bad:
    stc
.out:
    pop rsi
    pop rcx
    ret

section .rodata
align 16
gcm_rev:        db 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0

section .bss
alignb 16
gk_rk:          resb 176                ; gcm_load copies the context here
gk_h:           resb 16
gk_j0:          resb 16
gk_cb:          resb 16                 ; IV || counter
gk_x:           resb 16                 ; the running GHASH
gk_tmp:         resb 16
gk_n:           resd 1
