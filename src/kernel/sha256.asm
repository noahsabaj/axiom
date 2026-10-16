; =============================================================================
;  sha256.asm - SHA-256 (FIPS 180-4), HMAC-SHA256 (RFC 2104), HKDF (RFC 5869)
;  and TLS 1.3's HKDF-Expand-Label (RFC 8446 7.1): the hash and key schedule
;  of TLS_AES_128_GCM_SHA256.
;
;  Blocks go through the SHA extensions (SHA-NI) when CPUID has them, else
;  plain x86; sha256_mode says which (set it to 1 before the first use to
;  force plain x86, as the host tests do).
;
;    sha256_init(RDI = ctx)
;    sha256_update(RDI = ctx, RSI = data, RDX = bytes)
;    sha256_final(RDI = ctx, RSI = digest[32])
;    sha256(RDI = digest[32], RSI = data, RDX = bytes)
;    hmac_init(RDI = hctx, RSI = key, RDX = bytes)
;    hmac_update(RDI = hctx, RSI = data, RDX = bytes)
;    hmac_final(RDI = hctx, RSI = mac[32])
;    hmac_sha256(RDI = mac[32], RSI = key, RDX = key bytes, RCX = data, R8 = bytes)
;    hkdf_extract(RDI = prk[32], RSI = salt, RDX = bytes, RCX = ikm, R8 = bytes)
;    hkdf_expand(RDI = out, RSI = prk[32], RDX = info, RCX = bytes, R8 = out bytes)
;    tls13_expand_label(RDI = out, RSI = secret[32], RDX = label, a string
;        without "tls13 ", RCX = context, R8 = its bytes (64 at most),
;        R9 = out bytes)
;
;  Contexts belong to the caller (SHA_CTX and HMAC_CTX bytes, any alignment)
;  and may be copied to fork a running hash, as TLS does with its
;  transcript. Every function preserves all general registers but RAX and
;  clobbers XMM0-XMM10. Scratch lives in .bss: main loop only, one caller
;  at a time.
; =============================================================================

SC_H            equ 0                   ; eight state words
SC_LEN          equ 32                  ; bytes hashed so far
SC_FILL         equ 40                  ; bytes waiting in SC_BUF
SC_BUF          equ 48
SHA_CTX         equ 112

HM_IN           equ 0                   ; the inner hash, key ^ ipad absorbed
HM_OUT          equ SHA_CTX             ; the outer one, key ^ opad absorbed
HMAC_CTX        equ 2 * SHA_CTX

section .text

; -----------------------------------------------------------------------------
;  SHA-256
; -----------------------------------------------------------------------------

sha256_init:
    push rcx
    push rsi
    push rdi
    lea rsi, [sha_h0]
    mov ecx, 32
    rep movsb
    pop rdi
    mov qword [rdi + SC_LEN], 0
    mov dword [rdi + SC_FILL], 0
    pop rsi
    pop rcx
    ret

sha256_update:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    add [r8 + SC_LEN], rdx
    mov eax, [r8 + SC_FILL]
    test eax, eax
    jz .whole
    mov ecx, 64                         ; top up the waiting block
    sub ecx, eax
    cmp rdx, rcx
    cmovb rcx, rdx
    lea rdi, [r8 + SC_BUF]
    add rdi, rax
    sub rdx, rcx
    add [r8 + SC_FILL], ecx
    rep movsb
    cmp dword [r8 + SC_FILL], 64
    jne .out
    push rsi
    push rdx
    mov rdi, r8
    lea rsi, [r8 + SC_BUF]
    mov edx, 1
    call sha256_blocks
    pop rdx
    pop rsi
    mov dword [r8 + SC_FILL], 0
.whole:
    mov rcx, rdx                        ; whole blocks straight from the data
    shr rcx, 6
    jz .tail
    push rdx
    mov rdi, r8
    mov rdx, rcx
    call sha256_blocks
    pop rdx
    shl rcx, 6
    add rsi, rcx
    and edx, 63
.tail:
    mov ecx, edx
    test ecx, ecx
    jz .out
    lea rdi, [r8 + SC_BUF]
    mov [r8 + SC_FILL], ecx
    rep movsb
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

sha256_final:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi
    mov r9, rsi
    mov rax, [r8 + SC_LEN]              ; the length in bits, big-endian
    shl rax, 3
    bswap rax
    mov [sha_lenbe], rax
    mov eax, 55                         ; 0x80, zeros, up to 56 mod 64
    sub eax, [r8 + SC_FILL]
    and eax, 63
    lea edx, [eax + 1]
    lea rsi, [sha_pad]
    call sha256_update
    lea rsi, [sha_lenbe]
    mov edx, 8
    call sha256_update
    xor ecx, ecx
.word:
    mov eax, [r8 + rcx * 4]
    bswap eax
    mov [r9 + rcx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .word
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

sha256:
    push rsi
    push rdi
    push rdi
    lea rdi, [sha_ctx]
    call sha256_init
    call sha256_update
    pop rsi
    call sha256_final
    pop rdi
    pop rsi
    ret

; sha256_blocks(RDI = state, RSI = data, RDX = blocks). Preserves all but RAX.
sha256_blocks:
    test rdx, rdx
    jz .out
    cmp byte [sha256_mode], 0
    jne .known
    call sha256_detect
.known:
    cmp byte [sha256_mode], 2
    je sha256_blocks_ni
    jmp sha256_blocks_x86
.out:
    ret

; sha256_detect: SHA-NI (and the SSSE3 and SSE4.1 it leans on) or not
sha256_detect:
    push rbx
    push rcx
    push rdx
    mov byte [sha256_mode], 1
    xor eax, eax
    cpuid
    cmp eax, 7
    jb .out
    mov eax, 1
    cpuid
    test ecx, 1 << 9                    ; SSSE3
    jz .out
    test ecx, 1 << 19                   ; SSE4.1
    jz .out
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 1 << 29                   ; SHA
    jz .out
    mov byte [sha256_mode], 2
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; The SHA extensions, as in Intel's reference and Linux's sha256_ni_asm.S:
; state as ABEF (XMM1) and CDGH (XMM2), message words in XMM3-XMM6.
%macro SHA_NI_GROUP 1                   ; rounds 4g .. 4g+3
    %assign g %1
    %assign cur 3 + (g % 4)
    %assign prv 3 + ((g + 3) % 4)
    %assign nxt 3 + ((g + 1) % 4)
    %if g < 4
        movdqu xmm0, [rsi + g * 16]
        pshufb xmm0, xmm8
        movdqa xmm%[cur], xmm0
    %else
        movdqa xmm0, xmm%[cur]
    %endif
    paddd xmm0, [rcx + g * 16]
    sha256rnds2 xmm2, xmm1, xmm0
    %if g >= 3 && g <= 14
        movdqa xmm7, xmm%[cur]
        palignr xmm7, xmm%[prv], 4
        paddd xmm%[nxt], xmm7
        sha256msg2 xmm%[nxt], xmm%[cur]
    %endif
    pshufd xmm0, xmm0, 0x0E
    sha256rnds2 xmm1, xmm2, xmm0
    %if g >= 1 && g <= 12
        sha256msg1 xmm%[prv], xmm%[cur]
    %endif
%endmacro

sha256_blocks_ni:
    push rcx
    push rdx
    push rsi
    shl rdx, 6
    add rdx, rsi                        ; the end
    lea rcx, [sha_k]
    movdqu xmm1, [rdi]                  ; DCBA, HGFE -> ABEF, CDGH
    movdqu xmm2, [rdi + 16]
    pshufd xmm1, xmm1, 0xB1
    pshufd xmm2, xmm2, 0x1B
    movdqa xmm7, xmm1
    palignr xmm1, xmm2, 8
    pblendw xmm2, xmm7, 0xF0
    movdqa xmm8, [sha_flip]
.block:
    movdqa xmm9, xmm1
    movdqa xmm10, xmm2
%assign gg 0
%rep 16
    SHA_NI_GROUP gg
%assign gg gg + 1
%endrep
    paddd xmm1, xmm9
    paddd xmm2, xmm10
    add rsi, 64
    cmp rsi, rdx
    jne .block
    pshufd xmm1, xmm1, 0x1B             ; back to DCBA, HGFE
    pshufd xmm2, xmm2, 0xB1
    movdqa xmm7, xmm1
    pblendw xmm1, xmm2, 0xF0
    palignr xmm2, xmm7, 8
    movdqu [rdi], xmm1
    movdqu [rdi + 16], xmm2
    pop rsi
    pop rdx
    pop rcx
    ret

; Plain x86: a..h in R8D..R15D, renamed rather than moved each round.
%macro SHA_ROUND 9                      ; a b c d e f g h t
    mov eax, %5
    mov ecx, %5
    ror eax, 6
    ror ecx, 11
    xor eax, ecx
    ror ecx, 14
    xor eax, ecx                        ; S1(e)
    mov ecx, %6
    xor ecx, %7
    and ecx, %5
    xor ecx, %7                         ; Ch(e, f, g)
    add eax, ecx
    add eax, [rdx + %9 * 4]             ; K[t]
    add eax, [rbx + %9 * 4]             ; W[t]
    add %8, eax                         ; h + S1 + Ch + K + W = T1
    add %4, %8                          ; d += T1
    mov eax, %1
    mov ecx, %1
    ror eax, 2
    ror ecx, 13
    xor eax, ecx
    ror ecx, 9
    xor eax, ecx                        ; S0(a)
    mov ecx, %1
    add eax, %8                         ; T1 + S0
    mov %8, %1
    or ecx, %2
    and %8, %2
    and ecx, %3
    or ecx, %8                          ; Maj(a, b, c)
    lea %8, [eax + ecx]                 ; the new a
%endmacro

sha256_blocks_x86:
    push rbx
    push rcx
    push rdx
    push rsi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbp, rdx
    lea rbx, [sha_w]
    lea rdx, [sha_k]
.block:
    xor ecx, ecx
.load:
    mov eax, [rsi + rcx * 4]
    bswap eax
    mov [rbx + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .load
.schedule:
    mov eax, [rbx + rcx * 4 - 8]        ; s1(W[t-2])
    mov r8d, eax
    mov r9d, eax
    ror r8d, 17
    ror r9d, 19
    shr eax, 10
    xor eax, r8d
    xor eax, r9d
    add eax, [rbx + rcx * 4 - 28]       ; + W[t-7]
    mov r10d, [rbx + rcx * 4 - 60]      ; + s0(W[t-15])
    mov r8d, r10d
    mov r9d, r10d
    ror r8d, 7
    ror r9d, 18
    shr r10d, 3
    xor r10d, r8d
    xor r10d, r9d
    add eax, r10d
    add eax, [rbx + rcx * 4 - 64]       ; + W[t-16]
    mov [rbx + rcx * 4], eax
    inc ecx
    cmp ecx, 64
    jb .schedule
    mov r8d, [rdi]
    mov r9d, [rdi + 4]
    mov r10d, [rdi + 8]
    mov r11d, [rdi + 12]
    mov r12d, [rdi + 16]
    mov r13d, [rdi + 20]
    mov r14d, [rdi + 24]
    mov r15d, [rdi + 28]
%xdefine RA r8d
%xdefine RB r9d
%xdefine RC r10d
%xdefine RD r11d
%xdefine RE r12d
%xdefine RF r13d
%xdefine RG r14d
%xdefine RH r15d
%assign t 0
%rep 64
    SHA_ROUND RA, RB, RC, RD, RE, RF, RG, RH, t
    %xdefine RT RH
    %xdefine RH RG
    %xdefine RG RF
    %xdefine RF RE
    %xdefine RE RD
    %xdefine RD RC
    %xdefine RC RB
    %xdefine RB RA
    %xdefine RA RT
%assign t t + 1
%endrep
    add [rdi], r8d
    add [rdi + 4], r9d
    add [rdi + 8], r10d
    add [rdi + 12], r11d
    add [rdi + 16], r12d
    add [rdi + 20], r13d
    add [rdi + 24], r14d
    add [rdi + 28], r15d
    add rsi, 64
    dec rbp
    jnz .block
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  HMAC-SHA256
; -----------------------------------------------------------------------------

hmac_init:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    lea rdi, [hm_key]                   ; the key, as one zero-padded block
    xor eax, eax
    mov ecx, 64
    rep stosb
    lea rdi, [hm_key]
    cmp rdx, 64
    jbe .short
    call sha256                         ; longer keys are hashed first
    jmp .pads
.short:
    mov rcx, rdx
    rep movsb
.pads:
    mov al, 0x36
    lea rdi, [r8 + HM_IN]
    call hmac_pad
    mov al, 0x5c
    lea rdi, [r8 + HM_OUT]
    call hmac_pad
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; hmac_pad(RDI = a hash context, AL = the pad byte): it starts with key ^ pad
hmac_pad:
    push rbx
    lea rsi, [hm_key]
    lea rbx, [hm_block]
    xor ecx, ecx
.byte:
    mov dl, [rsi + rcx]
    xor dl, al
    mov [rbx + rcx], dl
    inc ecx
    cmp ecx, 64
    jb .byte
    pop rbx
    call sha256_init
    lea rsi, [hm_block]
    mov edx, 64
    jmp sha256_update

hmac_update:
    jmp sha256_update                   ; HM_IN is at 0

hmac_final:
    push rdx
    push rsi
    push rdi
    push rsi
    lea rsi, [hm_inner]
    call sha256_final
    add rdi, HM_OUT
    mov edx, 32
    call sha256_update
    pop rsi
    call sha256_final
    pop rdi
    pop rsi
    pop rdx
    ret

hmac_sha256:
    push rdx
    push rsi
    push rdi
    push rdi
    lea rdi, [hm_ctx]
    call hmac_init
    mov rsi, rcx
    mov rdx, r8
    call hmac_update
    pop rsi
    call hmac_final
    pop rdi
    pop rsi
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  HKDF
; -----------------------------------------------------------------------------

hkdf_extract:
    jmp hmac_sha256                     ; HMAC(salt, ikm); no salt is a zero key

hkdf_expand:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r12
    push r13
    push r14
    mov r12, rsi                        ; PRK
    mov r13, rdx                        ; info
    mov r14, rcx                        ; and its bytes
    mov ecx, 255 * 32
    cmp r8, rcx
    cmova r8, rcx
    mov byte [hk_count], 0
.block:
    test r8, r8
    jz .out
    inc byte [hk_count]
    push rdi
    lea rdi, [hk_ctx]
    mov rsi, r12
    mov edx, 32
    call hmac_init
    cmp byte [hk_count], 1
    je .first
    lea rsi, [hk_t]                     ; T(i-1)
    call hmac_update
.first:
    mov rsi, r13
    mov rdx, r14
    call hmac_update
    lea rsi, [hk_count]
    mov edx, 1
    call hmac_update
    lea rsi, [hk_t]
    call hmac_final
    pop rdi
    mov ecx, 32
    cmp r8, rcx
    cmovb rcx, r8
    sub r8, rcx
    lea rsi, [hk_t]
    rep movsb
    jmp .block
.out:
    pop r14
    pop r13
    pop r12
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; HkdfLabel: uint16 length, opaque label<7..255> = "tls13 " + label,
; opaque context<0..255>
tls13_expand_label:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rdi
    lea rdi, [hk_info]
    mov eax, r9d
    xchg al, ah
    mov [rdi], ax
    lea rax, [rdi + 3]                  ; "tls13 " and the label
    mov dword [rax], 'tls1'
    mov word [rax + 4], '3 '
    add rax, 6
.label:
    mov cl, [rdx]
    test cl, cl
    jz .labelled
    mov [rax], cl
    inc rax
    inc rdx
    lea rcx, [hk_info + 3 + 6 + 100]
    cmp rax, rcx
    jb .label
.labelled:
    mov rcx, rax
    sub rcx, rdi
    sub ecx, 3
    mov [rdi + 2], cl
    mov ecx, 64
    cmp r8, rcx
    cmova r8, rcx
    mov [rax], r8b
    inc rax
    mov rdi, rax
    mov rsi, [rsp + 48]                 ; the context (RCX on entry)
    mov rcx, r8
    rep movsb
    mov rcx, rdi
    lea rdx, [hk_info]
    sub rcx, rdx                        ; the label's bytes
    mov rdi, r10
    mov rsi, [rsp + 32]                 ; the secret (RSI on entry)
    mov r8, r9
    call hkdf_expand
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

section .rodata
align 16
sha_flip:       db 3, 2, 1, 0, 7, 6, 5, 4, 11, 10, 9, 8, 15, 14, 13, 12
sha_k:
    dd 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5
    dd 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174
    dd 0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da
    dd 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967
    dd 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85
    dd 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070
    dd 0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3
    dd 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2
sha_h0:
    dd 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19
sha_pad:        db 0x80
                times 63 db 0

section .data
sha256_mode:    db 0                    ; 0 not looked yet, 1 plain x86, 2 SHA-NI

section .bss
alignb 16
sha_w:          resd 64
sha_lenbe:      resq 1
sha_ctx:        resb SHA_CTX
hm_ctx:         resb HMAC_CTX
hk_ctx:         resb HMAC_CTX
hm_key:         resb 64
hm_block:       resb 64
hm_inner:       resb 32
hk_t:           resb 32
hk_info:        resb 3 + 6 + 100 + 1 + 64
hk_count:       resb 1
