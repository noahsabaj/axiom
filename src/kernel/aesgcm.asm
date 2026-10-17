; =============================================================================
;  aesgcm.asm - AES-128-GCM (NIST SP 800-38D) on AES-NI and PCLMULQDQ: the
;  record protection of TLS_AES_128_GCM_SHA256. 96-bit IVs, 16-byte tags.
;  GHASH multiplies byte-reflected blocks with four carry-less products, a
;  one-bit shift and the two-phase reduction of Gueron and Kounavis, "Intel
;  Carry-Less Multiplication Instruction and its Usage for Computing the GCM
;  Mode" (2014).
;
;  On a CPU with VAES, VPCLMULQDQ and AVX2 (gcm_mode 2), 128 bytes at a
;  time go through YMM registers, two blocks to each: eight counter blocks
;  encrypted together, and eight blocks hashed with one reduction, each
;  multiplied by the power of H it needs (X' = (X ^ C1) H^8 ^ C2 H^7 ^ ...
;  ^ C8 H); what is left over goes a block at a time, as on any other CPU
;  (gcm_mode 1).
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
;  A context is GCM_CTX bytes, any alignment, and is only read after
;  gcm_init: one context may be used from several threads at once. Every
;  function preserves all general registers but RAX, clobbers XMM0-XMM9,
;  and in gcm_mode 2 clears the upper halves of the YMM registers. Scratch
;  (the round keys copied out aligned, the counter, the hash) is on the
;  stack, about 600 bytes, wiped before returning: any thread whose SIMD
;  registers are its own may call them, but not a system call's.
; =============================================================================

GK_RK           equ 0                   ; round keys 0-10
GK_H            equ 176                 ; H = E(0), byte-reflected
GK_HP           equ 192                 ; H^8, H^7, ... H^1, byte-reflected
GCM_CTX         equ 320

GF_RK           equ 0                   ; the stack frame: the context first
GF_H            equ GK_H
GF_HP           equ GK_HP
GF_J0           equ 320
GF_CB           equ 336                 ; IV || counter
GF_X            equ 352                 ; the running GHASH
GF_TMP          equ 368
GF_CTRS         equ 384                 ; eight counter blocks (32-aligned)
GF_N            equ 512                 ; dword: the next counter
GF_SIZE         equ 544

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

; gcm_pick: gcm_mode, unless already set (a test may set it to 1 first).
; Preserves all but RAX.
gcm_pick:
    cmp byte [gcm_mode], 0
    jne .out
    push rbx
    push rcx
    push rdx
    mov dl, 1
    mov eax, 1
    cpuid
    and ecx, (1 << 27) | (1 << 28)      ; OSXSAVE, AVX
    cmp ecx, (1 << 27) | (1 << 28)
    jne .set
    xor ecx, ecx
    xgetbv
    and eax, 6                          ; XCR0: SSE and AVX state enabled
    cmp eax, 6
    jne .set
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 1 << 5                    ; AVX2
    jz .set
    and ecx, (1 << 9) | (1 << 10)       ; VAES, VPCLMULQDQ
    cmp ecx, (1 << 9) | (1 << 10)
    jne .set
    mov dl, 2
.set:
    mov [gcm_mode], dl
    pop rdx
    pop rcx
    pop rbx
.out:
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

; GCM_ENTER / GCM_LEAVE: RBX = an aligned frame on the stack, the context
; (RDI) copied into it
%macro GCM_ENTER 0
    push rbx
    push rcx
    push rsi
    push rdi
    push rbp
    mov rbp, rsp
    sub rsp, GF_SIZE
    and rsp, -32
    mov rbx, rsp
    call gcm_pick
    call gcm_frame
%endmacro

%macro GCM_LEAVE 0                      ; keeps the flags
    mov rsp, rbp
    pop rbp
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret
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
    GCM_ENTER
    pxor xmm0, xmm0                     ; H = E(K, 0)
    call gcm_aes
    pshufb xmm0, [gcm_rev]
    movdqu [rdi + GK_H], xmm0
    movdqu [rdi + GK_HP + 7 * 16], xmm0 ; and its powers, H^1 last
    movdqa xmm1, xmm0
    mov ecx, 6 * 16
.power:
    call gcm_gfmul                      ; XMM1 is kept
    movdqu [rdi + GK_HP + rcx], xmm0
    sub ecx, 16
    jns .power
    call gcm_wipe
    GCM_LEAVE

; gcm_frame(RDI = ctx, RBX = the frame): the context into it
gcm_frame:
    push rcx
    push rsi
    push rdi
    mov rsi, rdi
    mov rdi, rbx
    mov ecx, GCM_CTX
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; gcm_wipe: the frame zeroed, keys and all. Preserves all but RAX.
gcm_wipe:
    push rcx
    push rdi
    mov rdi, rbx
    mov ecx, GF_SIZE
    xor eax, eax
    rep stosb
    pop rdi
    pop rcx
    pxor xmm0, xmm0
    pxor xmm1, xmm1
    ret

; gcm_aes: XMM0 = E(K, XMM0)
gcm_aes:
    pxor xmm0, [rbx + GF_RK]
%assign r 1
%rep 9
    aesenc xmm0, [rbx + GF_RK + r * 16]
%assign r r + 1
%endrep
    aesenclast xmm0, [rbx + GF_RK + 160]
    ret

; gcm_start(RSI = iv[12]): J0 = IV || 1, the hash cleared, the counter at 2
gcm_start:
    mov rax, [rsi]
    mov [rbx + GF_J0], rax
    mov [rbx + GF_CB], rax
    mov eax, [rsi + 8]
    mov [rbx + GF_J0 + 8], eax
    mov [rbx + GF_CB + 8], eax
    mov dword [rbx + GF_J0 + 12], 0x01000000
    mov dword [rbx + GF_N], 2
    pxor xmm0, xmm0
    movdqa [rbx + GF_X], xmm0
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

; gcm_ghash(RSI = data, RCX = bytes): into GF_X, the last block
; zero-padded. Preserves all but RAX.
gcm_ghash:
    push rcx
    push rsi
    push rdi
    cmp rcx, 128
    jb .one
    cmp byte [gcm_mode], 2
    jne .one
    call gcm_ghash8
.one:
    movdqu xmm1, [rbx + GF_H]
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
    movdqa [rbx + GF_TMP], xmm0
    lea rdi, [rbx + GF_TMP]
    rep movsb                           ; RCX = 0 after
    movdqa xmm0, [rbx + GF_TMP]
.mul:
    pshufb xmm0, [gcm_rev]
    pxor xmm0, [rbx + GF_X]
    call gcm_gfmul
    movdqa [rbx + GF_X], xmm0
    jmp .block
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; GH_PAIR ymm, offset: the products of two blocks and two powers of H
; added into YMM5 (low halves), YMM6 (high) and YMM7 (middle)
%macro GH_PAIR 2
    vmovdqu ymm4, [rbx + GF_HP + %2]
    vpclmulqdq ymm8, %1, ymm4, 0x00
    vpxor ymm5, ymm5, ymm8
    vpclmulqdq ymm8, %1, ymm4, 0x11
    vpxor ymm6, ymm6, ymm8
    vpclmulqdq ymm8, %1, ymm4, 0x10
    vpxor ymm7, ymm7, ymm8
    vpclmulqdq ymm8, %1, ymm4, 0x01
    vpxor ymm7, ymm7, ymm8
%endmacro

; gcm_ghash8(RSI = data, RCX >= 128): every whole 128 bytes into GF_X;
; RSI and RCX moved past them. VAES mode only. Clobbers YMM0-YMM9.
gcm_ghash8:
.chunk:
    vbroadcasti128 ymm9, [gcm_rev]
    vmovdqu ymm0, [rsi]
    vmovdqu ymm1, [rsi + 32]
    vmovdqu ymm2, [rsi + 64]
    vmovdqu ymm3, [rsi + 96]
    vpshufb ymm0, ymm0, ymm9
    vpshufb ymm1, ymm1, ymm9
    vpshufb ymm2, ymm2, ymm9
    vpshufb ymm3, ymm3, ymm9
    vmovdqa xmm4, [rbx + GF_X]          ; the hash so far into the first block
    vpxor ymm0, ymm0, ymm4
    vpxor xmm5, xmm5, xmm5
    vpxor xmm6, xmm6, xmm6
    vpxor xmm7, xmm7, xmm7
    GH_PAIR ymm0, 0                     ; H^8, H^7
    GH_PAIR ymm1, 32
    GH_PAIR ymm2, 64
    GH_PAIR ymm3, 96                    ; H^2, H^1
    vextracti128 xmm8, ymm5, 1          ; the two halves of each added
    vpxor xmm5, xmm5, xmm8
    vextracti128 xmm8, ymm6, 1
    vpxor xmm6, xmm6, xmm8
    vextracti128 xmm8, ymm7, 1
    vpxor xmm7, xmm7, xmm8
    vpslldq xmm8, xmm7, 8               ; XMM6:XMM3 = the 256-bit sum
    vpxor xmm3, xmm5, xmm8
    vpsrldq xmm8, xmm7, 8
    vpxor xmm6, xmm6, xmm8
    vpsrld xmm7, xmm3, 31               ; shifted left one bit
    vpsrld xmm8, xmm6, 31
    vpslld xmm3, xmm3, 1
    vpslld xmm6, xmm6, 1
    vpsrldq xmm9, xmm7, 12
    vpslldq xmm8, xmm8, 4
    vpslldq xmm7, xmm7, 4
    vpor xmm3, xmm3, xmm7
    vpor xmm6, xmm6, xmm8
    vpor xmm6, xmm6, xmm9
    vpslld xmm7, xmm3, 31               ; reduction, first phase
    vpslld xmm8, xmm3, 30
    vpslld xmm9, xmm3, 25
    vpxor xmm7, xmm7, xmm8
    vpxor xmm7, xmm7, xmm9
    vpsrldq xmm8, xmm7, 4
    vpslldq xmm7, xmm7, 12
    vpxor xmm3, xmm3, xmm7
    vpsrld xmm2, xmm3, 1                ; second phase
    vpsrld xmm4, xmm3, 2
    vpsrld xmm5, xmm3, 7
    vpxor xmm2, xmm2, xmm4
    vpxor xmm2, xmm2, xmm5
    vpxor xmm2, xmm2, xmm8
    vpxor xmm3, xmm3, xmm2
    vpxor xmm0, xmm6, xmm3
    vmovdqa [rbx + GF_X], xmm0
    add rsi, 128
    sub rcx, 128
    cmp rcx, 128
    jae .chunk
    vzeroupper
    ret

; gcm_ctr(RSI = data, RCX = bytes): XORed with E(K, counter) in place,
; counting from GF_N. Preserves all but RAX.
gcm_ctr:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp rcx, 128
    jb .block
    cmp byte [gcm_mode], 2
    jne .block
    call gcm_ctr8
.block:
    test rcx, rcx
    jz .out
    mov eax, [rbx + GF_N]
    inc dword [rbx + GF_N]
    bswap eax
    mov [rbx + GF_CB + 12], eax
    movdqa xmm0, [rbx + GF_CB]
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
    movdqa [rbx + GF_TMP], xmm0
    lea rdi, [rbx + GF_TMP]
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

; gcm_ctr8(RSI = data, RCX >= 128): every whole 128 bytes XORed with eight
; counter blocks' keystream; RSI and RCX moved past them. VAES mode only.
; Clobbers RDX, RDI, YMM0-YMM4.
gcm_ctr8:
.chunk:
    lea rdi, [rbx + GF_CTRS]
    mov edx, 8
.counter:
    mov rax, [rbx + GF_CB]
    mov [rdi], rax
    mov eax, [rbx + GF_CB + 8]
    mov [rdi + 8], eax
    mov eax, [rbx + GF_N]
    inc dword [rbx + GF_N]
    bswap eax
    mov [rdi + 12], eax
    add rdi, 16
    dec edx
    jnz .counter
    vbroadcasti128 ymm4, [rbx + GF_RK]
    vpxor ymm0, ymm4, [rbx + GF_CTRS]
    vpxor ymm1, ymm4, [rbx + GF_CTRS + 32]
    vpxor ymm2, ymm4, [rbx + GF_CTRS + 64]
    vpxor ymm3, ymm4, [rbx + GF_CTRS + 96]
%assign r 1
%rep 9
    vbroadcasti128 ymm4, [rbx + GF_RK + r * 16]
    vaesenc ymm0, ymm0, ymm4
    vaesenc ymm1, ymm1, ymm4
    vaesenc ymm2, ymm2, ymm4
    vaesenc ymm3, ymm3, ymm4
%assign r r + 1
%endrep
    vbroadcasti128 ymm4, [rbx + GF_RK + 160]
    vaesenclast ymm0, ymm0, ymm4
    vaesenclast ymm1, ymm1, ymm4
    vaesenclast ymm2, ymm2, ymm4
    vaesenclast ymm3, ymm3, ymm4
    vpxor ymm0, ymm0, [rsi]
    vpxor ymm1, ymm1, [rsi + 32]
    vpxor ymm2, ymm2, [rsi + 64]
    vpxor ymm3, ymm3, [rsi + 96]
    vmovdqu [rsi], ymm0
    vmovdqu [rsi + 32], ymm1
    vmovdqu [rsi + 64], ymm2
    vmovdqu [rsi + 96], ymm3
    add rsi, 128
    sub rcx, 128
    cmp rcx, 128
    jae .chunk
    vzeroupper
    ret

; gcm_tag(RCX = aad bytes, R9 = data bytes) -> XMM0 = the tag: the lengths
; hashed in, then E(K, J0) ^ GHASH. Preserves all but RAX.
gcm_tag:
    push rcx
    push rsi
    mov rax, rcx
    shl rax, 3
    bswap rax
    mov [rbx + GF_TMP], rax
    mov rax, r9
    shl rax, 3
    bswap rax
    mov [rbx + GF_TMP + 8], rax
    lea rsi, [rbx + GF_TMP]
    mov ecx, 16
    call gcm_ghash
    movdqa xmm0, [rbx + GF_J0]
    call gcm_aes
    movdqa xmm1, [rbx + GF_X]
    pshufb xmm1, [gcm_rev]
    pxor xmm0, xmm1
    pop rsi
    pop rcx
    ret

gcm_seal:
    GCM_ENTER
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
    call gcm_wipe
    GCM_LEAVE

gcm_open:
    GCM_ENTER
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
    call gcm_wipe
    clc
    GCM_LEAVE
.bad:
    call gcm_wipe
    stc
    GCM_LEAVE

section .rodata
align 16
gcm_rev:        db 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0

section .data
gcm_mode:       db 0                    ; 0 not looked yet, 1 AES-NI, 2 VAES
