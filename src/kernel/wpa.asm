; =============================================================================
;  wpa.asm - the crypto of WPA2-Personal (IEEE 802.11-2020 12.7 and 12.5.3):
;  SHA-1 (FIPS 180-4) and HMAC-SHA1 (RFC 2104) for the EAPOL-Key MIC, the
;  802.11 PRF (12.7.1.2) for the pairwise keys, PBKDF2-HMAC-SHA1 (RFC 8018)
;  for a passphrase's PMK, AES key unwrap (RFC 3394) for the group key, and
;  CCMP (AES-CCM with an 8-byte MIC) for the frames themselves. AES-128 is
;  crypto.asm's (aes_setkey, aes_block, FIPS-197 byte order); this file adds
;  the inverse cipher.
;
;    sha1(RDI = digest[20], RSI = data, RDX = bytes)
;    sha1_init(RDI = ctx), sha1_update(RDI = ctx, RSI = data, RDX = bytes),
;    sha1_final(RDI = ctx, RSI = digest[20])
;    hmac1_init(RDI = hctx, RSI = key, RDX = bytes), hmac1_update(RDI =
;    hctx, RSI = data, RDX = bytes), hmac1_final(RDI = hctx, RSI = mac[20])
;    hmac_sha1(RDI = mac[20], RSI = key, RDX = key bytes, RCX = data,
;        R8 = bytes)
;    prf_sha1(RDI = out, RSI = key, RDX = key bytes, RCX = label (a
;        string), R8 = data, R9 = its bytes, R10 = out bytes)
;    pbkdf2_sha1(RDI = pmk[32], RSI = passphrase, RDX = bytes, RCX = ssid,
;        R8 = bytes): 4096 rounds, as a passphrase becomes a PMK
;    aes_unwrap(RSI = kek[16], RDX = wrapped, ECX = its bytes (24 or more,
;        a multiple of 8), RDI = out, ECX - 8 bytes) -> CF if it does not
;        unwrap to the RFC's check value
;    ccmp_seal(RSI = tk[16], RDI = frame, ECX = header bytes, EDX = body
;        bytes, R8 = PN, R9D = key id): the frame is its 802.11 header, 8
;        bytes for the CCMP header, the body, and 8 bytes for the MIC; the
;        CCMP header is written, the body encrypted in place, the MIC added
;    ccmp_open(RSI = tk[16], RDI = frame, ECX = header bytes, EDX = frame
;        bytes) -> EAX = body bytes, decrypted in place after the CCMP
;        header; CF if the frame is too short or its MIC is wrong
;
;  Contexts belong to the caller (SHA1_CTX and HMAC1_CTX bytes, any
;  alignment) and may be copied. Every function preserves all general
;  registers but RAX and clobbers XMM0-XMM5. Scratch lives in .bss: main
;  loop only, one caller at a time. Key material is left there.
; =============================================================================

S1_H            equ 0                   ; five state words
S1_LEN          equ 24                  ; bytes hashed so far
S1_FILL         equ 32                  ; bytes waiting in S1_BUF
S1_BUF          equ 40
SHA1_CTX        equ 104

H1_IN           equ 0                   ; the inner hash, key ^ ipad absorbed
H1_OUT          equ SHA1_CTX            ; the outer one, key ^ opad absorbed
HMAC1_CTX       equ 2 * SHA1_CTX

section .text

; -----------------------------------------------------------------------------
;  SHA-1
; -----------------------------------------------------------------------------

sha1_init:
    mov dword [rdi + S1_H], 0x67452301
    mov dword [rdi + S1_H + 4], 0xEFCDAB89
    mov dword [rdi + S1_H + 8], 0x98BADCFE
    mov dword [rdi + S1_H + 12], 0x10325476
    mov dword [rdi + S1_H + 16], 0xC3D2E1F0
    mov qword [rdi + S1_LEN], 0
    mov dword [rdi + S1_FILL], 0
    ret

sha1_update:
    push rcx
    push rdx
    push rsi
    add [rdi + S1_LEN], rdx
.more:
    test rdx, rdx
    jz .out
    mov eax, [rdi + S1_FILL]
    test eax, eax
    jnz .fill
    cmp rdx, 64
    jb .fill
    call sha1_block                     ; a whole block straight from the data
    add rsi, 64
    sub rdx, 64
    jmp .more
.fill:
    mov ecx, 64                         ; what fits in the buffer
    sub ecx, eax
    cmp rcx, rdx
    jbe .take
    mov ecx, edx
.take:
    push rdi
    lea rdi, [rdi + S1_BUF + rax]
    sub rdx, rcx
    add eax, ecx
    rep movsb
    pop rdi
    mov [rdi + S1_FILL], eax
    cmp eax, 64
    jne .more
    mov dword [rdi + S1_FILL], 0
    push rsi
    lea rsi, [rdi + S1_BUF]
    call sha1_block
    pop rsi
    jmp .more
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

sha1_final:
    push rcx
    push rdx
    push rsi
    mov rax, [rdi + S1_LEN]
    shl rax, 3
    bswap rax
    mov [s1_lenbe], rax
    mov eax, [rdi + S1_FILL]            ; 0x80, then zeros up to 56 mod 64
    mov edx, 55
    sub edx, eax
    and edx, 63
    inc edx
    lea rsi, [s1_pad]
    call sha1_update
    lea rsi, [s1_lenbe]
    mov edx, 8
    call sha1_update
    pop rsi
    xor ecx, ecx
.word:
    mov eax, [rdi + S1_H + rcx * 4]
    bswap eax
    mov [rsi + rcx * 4], eax
    inc ecx
    cmp ecx, 5
    jb .word
    pop rdx
    pop rcx
    ret

sha1:
    push rsi
    push rdi
    lea rdi, [s1_ctx]
    call sha1_init
    call sha1_update
    mov rsi, [rsp]                      ; the digest
    call sha1_final
    pop rdi
    pop rsi
    ret

; sha1_block(RDI = ctx, RSI = 64 bytes)
sha1_block:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    lea r13, [s1_w]
    xor ecx, ecx
.load:
    mov eax, [rsi + rcx * 4]
    bswap eax
    mov [r13 + rcx * 4], eax
    inc ecx
    cmp ecx, 16
    jb .load
.expand:
    mov eax, [r13 + rcx * 4 - 12]
    xor eax, [r13 + rcx * 4 - 32]
    xor eax, [r13 + rcx * 4 - 56]
    xor eax, [r13 + rcx * 4 - 64]
    rol eax, 1
    mov [r13 + rcx * 4], eax
    inc ecx
    cmp ecx, 80
    jb .expand
    mov r8d, [rdi + S1_H]               ; a
    mov r9d, [rdi + S1_H + 4]           ; b
    mov r10d, [rdi + S1_H + 8]          ; c
    mov r11d, [rdi + S1_H + 12]         ; d
    mov r12d, [rdi + S1_H + 16]         ; e
    xor ecx, ecx
.round:
    cmp ecx, 20
    jb .choose
    cmp ecx, 40
    jb .parity
    cmp ecx, 60
    jb .majority
    mov eax, r9d
    xor eax, r10d
    xor eax, r11d
    add eax, 0xCA62C1D6
    jmp .mix
.choose:
    mov eax, r10d                       ; (b & (c ^ d)) ^ d
    xor eax, r11d
    and eax, r9d
    xor eax, r11d
    add eax, 0x5A827999
    jmp .mix
.parity:
    mov eax, r9d
    xor eax, r10d
    xor eax, r11d
    add eax, 0x6ED9EBA1
    jmp .mix
.majority:
    mov eax, r9d                        ; ((b | c) & d) | (b & c)
    mov edx, r9d
    or eax, r10d
    and edx, r10d
    and eax, r11d
    or eax, edx
    add eax, 0x8F1BBCDC
.mix:
    add eax, r12d
    add eax, [r13 + rcx * 4]
    mov edx, r8d
    rol edx, 5
    add eax, edx
    mov r12d, r11d
    mov r11d, r10d
    mov r10d, r9d
    rol r10d, 30
    mov r9d, r8d
    mov r8d, eax
    inc ecx
    cmp ecx, 80
    jb .round
    add [rdi + S1_H], r8d
    add [rdi + S1_H + 4], r9d
    add [rdi + S1_H + 8], r10d
    add [rdi + S1_H + 12], r11d
    add [rdi + S1_H + 16], r12d
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  HMAC-SHA1, the PRF, PBKDF2
; -----------------------------------------------------------------------------

hmac1_init:
    push rcx
    push rdx
    push rsi
    push rdi
    push rdi
    lea rdi, [h1_key]
    xor eax, eax
    mov ecx, 64
    rep stosb
    lea rdi, [h1_key]
    cmp rdx, 64
    jbe .short
    call sha1                           ; a longer key is its hash
    jmp .pads
.short:
    mov rcx, rdx
    rep movsb
.pads:
    pop rdi
    mov al, 0x36
    call hmac1_pad
    add rdi, H1_OUT
    mov al, 0x5C
    call hmac1_pad
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; hmac1_pad(RDI = the hash, AL = the pad byte): it starts on key ^ pad
hmac1_pad:
    push rcx
    push rdx
    push rsi
    push r8
    lea rsi, [h1_key]
    lea r8, [h1_block]
    xor ecx, ecx
.byte:
    mov dl, [rsi + rcx]
    xor dl, al
    mov [r8 + rcx], dl
    inc ecx
    cmp ecx, 64
    jb .byte
    call sha1_init
    mov rsi, r8
    mov edx, 64
    call sha1_update
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

hmac1_update:
    jmp sha1_update                     ; the inner hash is first

hmac1_final:
    push rdx
    push rsi
    push rdi
    push rsi
    lea rsi, [h1_inner]
    call sha1_final
    add rdi, H1_OUT
    mov edx, 20
    call sha1_update
    pop rsi
    call sha1_final
    pop rdi
    pop rsi
    pop rdx
    ret

hmac_sha1:
    push rdx
    push rsi
    push rdi
    push rdi
    lea rdi, [h1_ctx]
    call hmac1_init
    mov rsi, rcx
    mov rdx, r8
    call hmac1_update
    pop rsi
    call hmac1_final
    pop rdi
    pop rsi
    pop rdx
    ret

; prf_sha1: HMAC-SHA1(K, label || 0 || data || i) for i = 0, 1, ... until
; there is enough; the string's terminator is the 0
prf_sha1:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    mov r11, rdi                        ; where the output goes
    mov r12, rsi                        ; the key
    xor ebx, ebx
.next:
    test r10, r10
    jz .done
    lea rdi, [h1_ctx2]
    mov rsi, r12
    call hmac1_init
    push rdx
    mov rsi, rcx
    xor edx, edx
.strlen:
    cmp byte [rsi + rdx], 0
    je .label
    inc edx
    jmp .strlen
.label:
    inc edx                             ; and its terminator
    call hmac1_update
    mov rsi, r8
    mov rdx, r9
    call hmac1_update
    mov [h1_count], bl
    lea rsi, [h1_count]
    mov edx, 1
    call hmac1_update
    lea rsi, [h1_t]
    call hmac1_final
    pop rdx
    push rcx
    mov ecx, 20
    cmp r10, rcx
    cmovb ecx, r10d
    sub r10, rcx
    mov rdi, r11
    rep movsb
    mov r11, rdi
    pop rcx
    inc ebx
    jmp .next
.done:
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

pbkdf2_sha1:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    mov r12, rdi
    mov r9, rcx                         ; the salt: the SSID
    push rdi
    lea rdi, [p2_key]                   ; HMAC keyed once; each round copies it
    call hmac1_init
    pop rdi
    mov ebx, 1                          ; T1, then T2
.block:
    call p2_keyed
    mov rsi, r9
    mov rdx, r8
    call hmac1_update
    mov eax, ebx
    bswap eax
    mov [p2_int], eax
    lea rsi, [p2_int]
    mov edx, 4
    call hmac1_update
    lea rsi, [p2_u]
    call hmac1_final
    mov rax, [p2_u]                     ; T = U1
    mov [p2_t], rax
    mov rax, [p2_u + 8]
    mov [p2_t + 8], rax
    mov eax, [p2_u + 16]
    mov [p2_t + 16], eax
    mov ecx, 4095
.round:
    call p2_keyed
    lea rsi, [p2_u]
    mov edx, 20
    call hmac1_update
    call hmac1_final                    ; U(j) = HMAC(U(j - 1)), in place
    mov rax, [p2_u]
    xor [p2_t], rax
    mov rax, [p2_u + 8]
    xor [p2_t + 8], rax
    mov eax, [p2_u + 16]
    xor [p2_t + 16], eax
    dec ecx
    jnz .round
    lea rsi, [p2_t]
    mov rdi, r12
    mov ecx, 20
    cmp ebx, 1
    je .copy
    mov ecx, 12                         ; 32 bytes in all
.copy:
    rep movsb
    mov r12, rdi
    inc ebx
    cmp ebx, 2
    jbe .block
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; p2_keyed -> RDI = p2_ctx, a copy of the keyed HMAC
p2_keyed:
    push rcx
    push rsi
    lea rsi, [p2_key]
    lea rdi, [p2_ctx]
    mov ecx, HMAC1_CTX
    rep movsb
    lea rdi, [p2_ctx]
    pop rsi
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  AES-128 inverse cipher, key unwrap
; -----------------------------------------------------------------------------

; aes_dec_setup: the equivalent inverse cipher's schedule from aes_rk
aes_dec_setup:
    movdqa xmm0, [aes_rk + 160]
    movdqa [aes_dk], xmm0
%assign i 1
%rep 9
    aesimc xmm0, [aes_rk + (10 - i) * 16]
    movdqa [aes_dk + i * 16], xmm0
%assign i i + 1
%endrep
    movdqa xmm0, [aes_rk]
    movdqa [aes_dk + 160], xmm0
    ret

; aes_dblock: XMM0 = AES^-1(XMM0)
aes_dblock:
    pxor xmm0, [aes_dk]
%assign i 1
%rep 9
    aesdec xmm0, [aes_dk + i * 16]
%assign i i + 1
%endrep
    aesdeclast xmm0, [aes_dk + 160]
    ret

aes_unwrap:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp ecx, 24
    jb .bad
    test ecx, 7
    jnz .bad
    call aes_setkey
    call aes_dec_setup
    mov r8d, ecx
    shr r8d, 3
    dec r8d                             ; n, the 64-bit blocks of key data
    mov r9, [rdx]                       ; A
    push rdi
    lea rsi, [rdx + 8]                  ; R[1..n]
    lea ecx, [r8 * 8]
    rep movsb
    pop rdi
    mov r10d, 5                         ; j = 5 .. 0
.round:
    mov ecx, r8d                        ; i = n .. 1
.block:
    mov eax, r8d                        ; t = n * j + i, big-endian into A
    imul eax, r10d
    add eax, ecx
    bswap rax
    xor rax, r9
    movq xmm0, rax
    lea r11, [rdi + rcx * 8 - 8]
    pinsrq xmm0, qword [r11], 1
    call aes_dblock
    movq r9, xmm0
    pextrq qword [r11], xmm0, 1
    dec ecx
    jnz .block
    dec r10d
    jns .round
    mov rax, 0xA6A6A6A6A6A6A6A6
    cmp r9, rax
    jne .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  CCMP
; -----------------------------------------------------------------------------

; ccm_prep(RDI = frame, ECX = header bytes, R8 = PN): the nonce into
; ccm_b0 and ccm_a (B0's length and the counter left to the caller) and
; the additional data, formatted, into ccm_aad
ccm_prep:
    push rbx
    push rcx
    push rdx
    push rsi
    push r9
    movzx ebx, byte [rdi]               ; frame control
    movzx edx, byte [rdi + 1]
    xor esi, esi                        ; the nonce's flags: priority, management
    mov eax, ebx
    and eax, 0x0C
    cmp eax, 0x08                       ; data
    je .data
    test eax, eax
    jnz .nonce
    mov esi, 0x10                       ; management (a robust frame)
    jmp .nonce
.data:
    test ebx, 0x80                      ; QoS: the priority is the TID
    jz .nonce
    mov r9d, 24
    mov eax, edx
    and eax, 3
    cmp eax, 3
    jne .qos
    add r9d, 6
.qos:
    movzx esi, byte [rdi + r9]
    and esi, 0x0F
.nonce:
    mov [ccm_b0 + 1], sil
    mov eax, [rdi + 10]                 ; A2
    mov [ccm_b0 + 2], eax
    mov ax, [rdi + 14]
    mov [ccm_b0 + 6], ax
    mov rax, r8                         ; PN5 .. PN0
    shl rax, 16
    bswap rax
    mov [ccm_b0 + 8], eax
    shr rax, 32
    mov [ccm_b0 + 12], al
    shr eax, 8
    mov [ccm_b0 + 13], al
    mov byte [ccm_b0], 0x59             ; flags: additional data, M = 8, L = 2
    movdqu xmm0, [ccm_b0]
    movdqu [ccm_a], xmm0
    mov byte [ccm_a], 0x01              ; L = 2
    pxor xmm0, xmm0
    movdqu [ccm_aad], xmm0
    movdqu [ccm_aad + 16], xmm0
    mov eax, ebx                        ; FC: a data frame's subtype bits 4-6 masked
    mov ecx, ebx
    and ecx, 0x0C
    cmp ecx, 0x08
    jne .fc
    and eax, 0x8F
.fc:
    mov [ccm_aad + 2], al
    mov eax, edx                        ; Retry, PwrMgt, MoreData masked, Protected set
    and eax, ~0x38 & 0xFF
    or eax, 0x40
    test ebx, 0x80
    jz .flags
    cmp ecx, 0x08
    jne .flags
    and eax, 0x7F                       ; QoS data: Order masked too
.flags:
    mov [ccm_aad + 3], al
    movdqu xmm0, [rdi + 4]              ; A1, A2, A3
    movdqu [ccm_aad + 4], xmm0
    mov ax, [rdi + 20]
    mov [ccm_aad + 20], ax
    movzx eax, byte [rdi + 22]          ; SC: the fragment number only
    and eax, 0x0F
    mov [ccm_aad + 22], al
    mov r9d, 22                         ; additional data so far
    mov eax, edx
    and eax, 3
    cmp eax, 3
    jne .a4_done
    mov eax, [rdi + 24]                 ; A4
    mov [ccm_aad + 2 + 22], eax
    mov ax, [rdi + 28]
    mov [ccm_aad + 2 + 26], ax
    mov r9d, 28
.a4_done:
    cmp ecx, 0x08
    jne .len
    test ebx, 0x80
    jz .len
    movzx eax, byte [rdi + r9 + 2]      ; QC: in the frame 2 bytes on (past SC)
    and eax, 0x0F
    lea rsi, [ccm_aad + 2]
    mov [rsi + r9], al
    add r9d, 2
.len:
    mov eax, r9d
    xchg al, ah
    mov [ccm_aad], ax
    pop r9
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ccm_mac_start(EDX = body bytes): XMM1 = the CBC-MAC over B0 and the
; additional data. Clobbers RAX, XMM0.
ccm_mac_start:
    mov eax, edx
    xchg al, ah
    mov [ccm_b0 + 14], ax
    movdqu xmm0, [ccm_b0]
    call aes_block
    movdqu xmm1, [ccm_aad]
    pxor xmm0, xmm1
    call aes_block
    movdqu xmm1, [ccm_aad + 16]
    pxor xmm0, xmm1
    call aes_block
    movdqa xmm1, xmm0
    ret

; ccm_ctr(EAX = i) -> XMM2 = AES(A_i). Clobbers XMM0.
ccm_ctr:
    xchg al, ah
    mov [ccm_a + 14], ax
    movdqu xmm0, [ccm_a]
    call aes_block
    movdqa xmm2, xmm0
    ret

ccmp_seal:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    mov ecx, ecx
    mov edx, edx
    call aes_setkey
    mov eax, ecx                        ; the CCMP header: PN0 PN1 0 keyid|ExtIV PN2..PN5
    mov [rdi + rax], r8w
    mov byte [rdi + rax + 2], 0
    mov ebx, r9d
    shl ebx, 6
    or ebx, 0x20
    mov [rdi + rax + 3], bl
    mov rbx, r8
    shr rbx, 16
    mov [rdi + rax + 4], ebx
    call ccm_prep
    lea rsi, [rdi + rcx + 8]            ; the body
    lea r11, [rsi + rdx]                ; and the MIC after it
    call ccm_mac_start
    mov r10d, edx                       ; bytes left
    mov ebx, 1                          ; the counter
.block:
    test r10d, r10d
    jz .mic
    pxor xmm3, xmm3
    movdqu [ccm_tmp], xmm3
    mov ecx, 16
    cmp r10d, ecx
    cmovb ecx, r10d
    push rcx
    push rsi
    lea rdi, [ccm_tmp]
    rep movsb
    pop rsi
    pop rcx
    movdqu xmm3, [ccm_tmp]              ; the plaintext, zero padded
    pxor xmm1, xmm3
    movdqa xmm0, xmm1
    call aes_block
    movdqa xmm1, xmm0
    mov eax, ebx
    call ccm_ctr
    pxor xmm3, xmm2
    movdqu [ccm_tmp], xmm3
    push rsi
    mov rdi, rsi
    lea rsi, [ccm_tmp]
    sub r10d, ecx
    rep movsb
    pop rsi
    add rsi, 16
    inc ebx
    jmp .block
.mic:
    xor eax, eax
    call ccm_ctr
    pxor xmm1, xmm2
    movq [r11], xmm1
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

ccmp_open:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r10
    push r11
    mov ecx, ecx
    lea eax, [rcx + 16]
    cmp edx, eax
    jb .bad
    mov eax, ecx
    test byte [rdi + rax + 3], 0x20     ; ExtIV
    jz .bad
    movzx r8d, word [rdi + rax]         ; PN1 PN0
    mov ebx, [rdi + rax + 4]            ; PN5 .. PN2
    shl rbx, 16
    or r8, rbx
    sub edx, ecx
    sub edx, 16                         ; the body
    mov r11d, edx
    call aes_setkey
    call ccm_prep
    lea rsi, [rdi + rcx + 8]
    call ccm_mac_start
    mov r10d, edx
    mov ebx, 1
.block:
    test r10d, r10d
    jz .mic
    pxor xmm3, xmm3
    movdqu [ccm_tmp], xmm3
    mov ecx, 16
    cmp r10d, ecx
    cmovb ecx, r10d
    push rcx
    push rsi
    lea rdi, [ccm_tmp]
    rep movsb
    pop rsi
    pop rcx
    mov eax, ebx
    call ccm_ctr
    movdqu xmm3, [ccm_tmp]
    pxor xmm3, xmm2
    movdqu [ccm_tmp], xmm3
    push rcx
    push rsi
    mov rdi, rsi
    lea rsi, [ccm_tmp]
    rep movsb                           ; the plaintext, in place
    pop rsi
    pop rcx
    pxor xmm3, xmm3                     ; and again, zero padded, for the MAC
    movdqu [ccm_tmp], xmm3
    push rcx
    push rsi
    lea rdi, [ccm_tmp]
    rep movsb
    pop rsi
    pop rcx
    movdqu xmm3, [ccm_tmp]
    pxor xmm1, xmm3
    movdqa xmm0, xmm1
    call aes_block
    movdqa xmm1, xmm0
    sub r10d, ecx
    add rsi, rcx
    inc ebx
    jmp .block
.mic:
    xor eax, eax
    call ccm_ctr
    pxor xmm1, xmm2
    movq rax, xmm1
    cmp rax, [rsi]                      ; the MIC follows the body
    jne .bad
    mov eax, r11d
    clc
    jmp .out
.bad:
    xor eax, eax
    stc
.out:
    pop r11
    pop r10
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
s1_pad:         db 0x80
                times 63 db 0

section .bss
alignb 16
aes_dk:         resb 11 * 16            ; the inverse cipher's round keys
ccm_b0:         resb 16
ccm_a:          resb 16
ccm_aad:        resb 32
ccm_tmp:        resb 16
s1_w:           resd 80
s1_ctx:         resb SHA1_CTX
s1_lenbe:       resq 1
h1_key:         resb 64
h1_block:       resb 64
h1_inner:       resb 20
h1_t:           resb 20
h1_count:       resb 1
h1_ctx:         resb HMAC1_CTX
h1_ctx2:        resb HMAC1_CTX
p2_key:         resb HMAC1_CTX
p2_ctx:         resb HMAC1_CTX
p2_u:           resb 20
p2_t:           resb 20
p2_int:         resd 1
