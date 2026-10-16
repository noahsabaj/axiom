; =============================================================================
;  crypto.asm - AES-128 on AES-NI, AES-CMAC (RFC 4493) and the Bluetooth LE
;  Security Manager crypto toolbox (Core spec Vol 3 Part H 2.2): e, ah, c1,
;  s1 for legacy pairing and private addresses, f4, f5, f6, g2, h6 for LE
;  Secure Connections. Pure computation: no calls out of this file.
;
;  Byte order. aes_encrypt and aes_cmac use the FIPS-197 / RFC 4493 order
;  (byte 0 is the most significant). Every smp_* function takes and returns
;  values in Bluetooth over-the-air order, least significant byte first,
;  exactly like Linux net/bluetooth/smp.c, which reverses keys, messages and
;  results around AES; PDU fields can be passed straight in. A 7-byte address
;  is the 6-byte BD_ADDR (LSB first) followed by its type byte (0 public,
;  1 random), as in Linux's a[6] = type arrays. For c1 that means
;  ia[6] = iat and ra[6] = rat, so p1 = pres || preq || rat || iat comes out
;  as { iat, rat, preq[0..6], pres[0..6] } in memory, as Linux builds it.
;
;    aes_encrypt(RSI = key[16], RDI = block[16] in/out)
;    aes_cmac(RSI = key[16], RDX = message, ECX = length, RDI = tag[16])
;    smp_e(RSI = key[16], RDI = block[16] in/out)
;    smp_ah(RSI = irk[16], RDX = r[3], RDI = hash[3])
;    smp_c1(RSI = k, RDX = r, RCX = preq[7], R8 = pres[7], R9 = ia[7],
;           R10 = ra[7], RDI = confirm[16])
;    smp_s1(RSI = k, RDX = r1, RCX = r2, RDI = stk[16])
;    smp_f4(RSI = u[32], RDX = v[32], RCX = x[16], R8B = z, RDI = out[16])
;    smp_f5(RSI = w[32], RDX = n1, RCX = n2, R8 = a1[7], R9 = a2[7],
;           RDI = mackey[16], R10 = ltk[16])
;    smp_f6(RSI = w[16], RDX = n1, RCX = n2, R8 = r, R9 = io_cap[3],
;           R10 = a1[7], R11 = a2[7], RDI = out[16])
;    smp_g2(RSI = u[32], RDX = v[32], RCX = x, R8 = y) -> EAX = 0..999999
;    smp_h6(RSI = w[16], EDX = keyID, RDI = out[16])    keyID 'lebr' = 0x6c656272
;    crypto_selftest -> EAX = 0, or the 1-based number of the first failing
;      vector: 1 AES FIPS-197 C.1, 2-5 CMAC RFC 4493 (0, 16, 40, 64 bytes),
;      6 ah, 7 c1, 8 s1, 9 f4, 10 f5, 11 f6, 12 g2, 13 h6. Returns 1 without
;      touching AES if CPUID lacks AES-NI, SSSE3 or SSE4.1.
;
;  Every function preserves all general registers but RAX (and flags are
;  clobbered); XMM0-XMM5 are clobbered, XMM6-XMM15 are untouched. Caller
;  buffers may be unaligned and may overlap the outputs. The key schedule
;  and message scratch live in .bss, so this is main-loop only: one caller
;  at a time, not from interrupts or other CPUs. Key material is left there.
; =============================================================================

SMP_MSG_MAX     equ 80                  ; longest toolbox message (g2)

section .text

; -----------------------------------------------------------------------------
;  AES-128
; -----------------------------------------------------------------------------

; aes_encrypt(RSI = key[16], RDI = block[16]): encrypt one block in place
aes_encrypt:
    call aes_setkey
    movdqu xmm0, [rdi]
    call aes_block
    movdqu [rdi], xmm0
    ret

; aes_setkey(RSI = key[16]) / aes_expand(XMM1 = key): the FIPS-197 key
; schedule into aes_rk. Clobbers RAX, XMM1-XMM5.
aes_setkey:
    movdqu xmm1, [rsi]
aes_expand:
    push rcx
    push rdx
    lea rax, [aes_rk]
    lea rdx, [aes_rcon]
    movdqa xmm5, [aes_rot_mask]
    movdqa [rax], xmm1
    mov ecx, 10
.round:
    ; t = SubWord(RotWord(w3)) ^ Rcon without AESKEYGENASSIST (whose round
    ; constant is an immediate): put RotWord(w3) in all four columns, where
    ; ShiftRows does nothing, and let AESENCLAST do SubBytes and the xor.
    movd xmm4, [rdx]
    pshufd xmm4, xmm4, 0
    movdqa xmm2, xmm1
    pshufb xmm2, xmm5
    aesenclast xmm2, xmm4
    ; w0..w3 become t^w0, t^w0^w1, t^w0^w1^w2, t^w0^w1^w2^w3
    movdqa xmm3, xmm1
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pslldq xmm3, 4
    pxor xmm1, xmm3
    pxor xmm1, xmm2
    add rax, 16
    add rdx, 4
    movdqa [rax], xmm1
    dec ecx
    jnz .round
    pop rdx
    pop rcx
    ret

; aes_block: XMM0 = AES(aes_rk, XMM0). Touches nothing else.
aes_block:
    pxor xmm0, [aes_rk]
    aesenc xmm0, [aes_rk + 16]
    aesenc xmm0, [aes_rk + 32]
    aesenc xmm0, [aes_rk + 48]
    aesenc xmm0, [aes_rk + 64]
    aesenc xmm0, [aes_rk + 80]
    aesenc xmm0, [aes_rk + 96]
    aesenc xmm0, [aes_rk + 112]
    aesenc xmm0, [aes_rk + 128]
    aesenc xmm0, [aes_rk + 144]
    aesenclast xmm0, [aes_rk + 160]
    ret

; -----------------------------------------------------------------------------
;  AES-CMAC, RFC 4493
; -----------------------------------------------------------------------------

; aes_cmac(RSI = key[16], RDX = message, ECX = length, RDI = tag[16])
; Reads exactly ECX bytes of the message; any length, 0 included.
aes_cmac:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    mov r10d, ecx                       ; bytes left (upper half of RCX ignored)
    call aes_setkey
    pxor xmm0, xmm0                     ; L = E(K, 0), K1 = 2L, K2 = 4L
    call aes_block
    call cmac_dbl
    movdqa xmm2, xmm0
    call cmac_dbl
    movdqa xmm3, xmm0
    pxor xmm1, xmm1                     ; chaining value
.block:
    cmp r10, 16
    jbe .last                           ; the last block, even a whole one, is special
    movdqu xmm0, [rdx]
    pxor xmm0, xmm1
    call aes_block
    movdqa xmm1, xmm0
    add rdx, 16
    sub r10, 16
    jmp .block
.last:
    cmp r10, 16
    jne .partial
    movdqu xmm0, [rdx]                  ; complete: M_n ^ K1
    pxor xmm0, xmm2
    jmp .final
.partial:
    lea r8, [cmac_pad]                  ; short or empty: (M_n || 10..0) ^ K2
    pxor xmm0, xmm0
    movdqa [r8], xmm0
    xor ecx, ecx
.copy:
    cmp ecx, r10d
    je .mark
    mov r9b, [rdx + rcx]
    mov [r8 + rcx], r9b
    inc ecx
    jmp .copy
.mark:
    mov byte [r8 + rcx], 0x80
    movdqa xmm0, [r8]
    pxor xmm0, xmm3
.final:
    pxor xmm0, xmm1
    call aes_block
    movdqu [rdi], xmm0
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; cmac_dbl: XMM0 = XMM0 * x in GF(2^128), RFC 4493 bit order (byte 0 holds
; the top bits). Shift left one and fold a carry back in as 0x87.
; Clobbers RAX, R8, R9.
cmac_dbl:
    movq rax, xmm0
    pextrq r8, xmm0, 1
    bswap rax                           ; bytes 0-7 as the high half
    bswap r8                            ; bytes 8-15 as the low half
    mov r9, rax
    sar r9, 63                          ; all ones if the top bit falls out
    and r9d, 0x87
    shld rax, r8, 1
    add r8, r8
    xor r8, r9
    bswap rax
    bswap r8
    movq xmm0, rax
    pinsrq xmm0, r8, 1
    ret

; -----------------------------------------------------------------------------
;  Bluetooth LE Security Manager toolbox (all values LSB first)
; -----------------------------------------------------------------------------

; smp_ekey(RSI = key[16]): key schedule for e(), whose key is LSB first.
; Clobbers RAX, XMM1-XMM5.
smp_ekey:
    movdqu xmm1, [rsi]
    pshufb xmm1, [aes_rev_mask]
    jmp aes_expand

; smp_eblock: XMM0 = e(key, XMM0) with the block LSB first, after smp_ekey
smp_eblock:
    pshufb xmm0, [aes_rev_mask]
    call aes_block
    pshufb xmm0, [aes_rev_mask]
    ret

; smp_cmac(RSI = key[16], RDX = message, ECX = length <= SMP_MSG_MAX,
; RDI = tag[16]): Linux smp_aes_cmac, AES-CMAC with key, message and tag
; all byte-reversed. Clobbers RAX, XMM0-XMM5.
smp_cmac:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    movdqu xmm0, [rsi]
    pshufb xmm0, [aes_rev_mask]
    movdqa [smp_kbuf], xmm0
    lea r8, [smp_mrev]
    mov eax, ecx
.swap:                                  ; message byte i lands at len-1-i
    test eax, eax
    jz .mac
    dec eax
    mov r9b, [rdx]
    mov [r8 + rax], r9b
    inc rdx
    jmp .swap
.mac:
    lea rsi, [smp_kbuf]
    mov rdx, r8
    call aes_cmac
    movdqu xmm0, [rdi]
    pshufb xmm0, [aes_rev_mask]
    movdqu [rdi], xmm0
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; smp_e(RSI = key[16], RDI = block[16]): the security function e, in place
smp_e:
    call smp_ekey
    movdqu xmm0, [rdi]
    call smp_eblock
    movdqu [rdi], xmm0
    ret

; smp_ah(RSI = irk[16], RDX = r[3], RDI = hash[3]): random address hash,
; the low 24 bits of e(irk, padding || r)
smp_ah:
    call smp_ekey
    movzx eax, byte [rdx + 2]
    shl eax, 16
    mov ax, [rdx]
    movd xmm0, eax
    call smp_eblock
    movd eax, xmm0
    mov [rdi], ax
    shr eax, 16
    mov [rdi + 2], al
    ret

; smp_c1(RSI = k, RDX = r, RCX = preq[7], R8 = pres[7], R9 = ia[7],
; R10 = ra[7], RDI = confirm[16]): legacy pairing confirm value
; e(k, e(k, r ^ p1) ^ p2), p1 = pres || preq || rat || iat, p2 = 0 || ia || ra
smp_c1:
    mov al, [r9 + 6]                    ; p1, LSB first: iat, rat, preq, pres
    mov [smp_mbuf], al
    mov al, [r10 + 6]
    mov [smp_mbuf + 1], al
    mov eax, [rcx]                      ; 7 bytes as two overlapping dwords
    mov [smp_mbuf + 2], eax
    mov eax, [rcx + 3]
    mov [smp_mbuf + 5], eax
    mov eax, [r8]
    mov [smp_mbuf + 9], eax
    mov eax, [r8 + 3]
    mov [smp_mbuf + 12], eax
    mov eax, [r10]                      ; p2: ra, ia, four zero bytes
    mov [smp_mbuf + 16], eax
    movzx eax, word [r10 + 4]
    mov [smp_mbuf + 20], ax
    mov eax, [r9]
    mov [smp_mbuf + 22], eax
    movzx eax, word [r9 + 4]
    mov [smp_mbuf + 26], ax
    mov dword [smp_mbuf + 28], 0
    call smp_ekey
    movdqu xmm0, [rdx]
    pxor xmm0, [smp_mbuf]
    call smp_eblock
    pxor xmm0, [smp_mbuf + 16]
    call smp_eblock
    movdqu [rdi], xmm0
    ret

; smp_s1(RSI = k, RDX = r1, RCX = r2, RDI = stk[16]): legacy STK,
; e(k, r1' || r2') from the low 64 bits of each random
smp_s1:
    call smp_ekey
    movq xmm0, [rcx]                    ; r2' is the less significant half
    movhps xmm0, [rdx]
    call smp_eblock
    movdqu [rdi], xmm0
    ret

; smp_f4(RSI = u[32], RDX = v[32], RCX = x[16], R8B = z, RDI = out[16]):
; confirm value, AES-CMAC_x(u || v || z)
smp_f4:
    push rcx
    push rdx
    push rsi
    mov [smp_mbuf], r8b                 ; LSB first: z, v, u
    movdqu xmm0, [rdx]
    movdqu [smp_mbuf + 1], xmm0
    movdqu xmm0, [rdx + 16]
    movdqu [smp_mbuf + 17], xmm0
    movdqu xmm0, [rsi]
    movdqu [smp_mbuf + 33], xmm0
    movdqu xmm0, [rsi + 16]
    movdqu [smp_mbuf + 49], xmm0
    mov rsi, rcx
    lea rdx, [smp_mbuf]
    mov ecx, 65
    call smp_cmac
    pop rsi
    pop rdx
    pop rcx
    ret

; smp_f5(RSI = w[32], RDX = n1, RCX = n2, R8 = a1[7], R9 = a2[7],
; RDI = mackey[16], R10 = ltk[16]): key generation from the DHKey w.
; T = AES-CMAC_SALT(w); mackey and ltk are AES-CMAC_T of
; counter || 'btle' || n1 || n2 || a1 || a2 || 256 with counter 0 and 1.
smp_f5:
    push rcx
    push rdx
    push rsi
    push rdi
    mov word [smp_mbuf], 0x0100         ; LSB first: length 256 (00 01), a2, a1,
    mov eax, [r9]                       ; n2, n1, 'btle', counter
    mov [smp_mbuf + 2], eax
    mov eax, [r9 + 3]
    mov [smp_mbuf + 5], eax
    mov eax, [r8]
    mov [smp_mbuf + 9], eax
    mov eax, [r8 + 3]
    mov [smp_mbuf + 12], eax
    movdqu xmm0, [rcx]
    movdqu [smp_mbuf + 16], xmm0
    movdqu xmm0, [rdx]
    movdqu [smp_mbuf + 32], xmm0
    mov dword [smp_mbuf + 48], 0x62746c65   ; bytes 65 6c 74 62: "btle" reversed
    mov byte [smp_mbuf + 52], 0
    mov rdx, rsi                        ; T = AES-CMAC_SALT(w)
    lea rsi, [smp_salt]
    lea rdi, [smp_tbuf]
    mov ecx, 32
    call smp_cmac
    lea rsi, [smp_tbuf]
    lea rdx, [smp_mbuf]
    mov ecx, 53
    mov rdi, [rsp]                      ; the caller's RDI: mackey
    call smp_cmac
    mov byte [smp_mbuf + 52], 1
    mov rdi, r10
    call smp_cmac
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; smp_f6(RSI = w[16], RDX = n1, RCX = n2, R8 = r, R9 = io_cap[3],
; R10 = a1[7], R11 = a2[7], RDI = out[16]): DHKey check,
; AES-CMAC_w(n1 || n2 || r || io_cap || a1 || a2)
smp_f6:
    push rcx
    push rdx
    mov eax, [r11]                      ; LSB first: a2, a1, io_cap, r, n2, n1
    mov [smp_mbuf], eax
    mov eax, [r11 + 3]
    mov [smp_mbuf + 3], eax
    mov eax, [r10]
    mov [smp_mbuf + 7], eax
    mov eax, [r10 + 3]
    mov [smp_mbuf + 10], eax
    movzx eax, word [r9]
    mov [smp_mbuf + 14], ax
    mov al, [r9 + 2]
    mov [smp_mbuf + 16], al
    movdqu xmm0, [r8]
    movdqu [smp_mbuf + 17], xmm0
    movdqu xmm0, [rcx]
    movdqu [smp_mbuf + 33], xmm0
    movdqu xmm0, [rdx]
    movdqu [smp_mbuf + 49], xmm0
    lea rdx, [smp_mbuf]
    mov ecx, 65
    call smp_cmac
    pop rdx
    pop rcx
    ret

; smp_g2(RSI = u[32], RDX = v[32], RCX = x[16], R8 = y[16]) -> EAX:
; numeric comparison value, AES-CMAC_x(u || v || y) mod 2^32 mod 10^6
smp_g2:
    push rcx
    push rdx
    push rsi
    push rdi
    movdqu xmm0, [r8]                   ; LSB first: y, v, u
    movdqu [smp_mbuf], xmm0
    movdqu xmm0, [rdx]
    movdqu [smp_mbuf + 16], xmm0
    movdqu xmm0, [rdx + 16]
    movdqu [smp_mbuf + 32], xmm0
    movdqu xmm0, [rsi]
    movdqu [smp_mbuf + 48], xmm0
    movdqu xmm0, [rsi + 16]
    movdqu [smp_mbuf + 64], xmm0
    mov rsi, rcx
    lea rdx, [smp_mbuf]
    mov ecx, 80
    lea rdi, [smp_tbuf]
    call smp_cmac
    mov eax, [smp_tbuf]                 ; the least significant 32 bits
    xor edx, edx
    mov ecx, 1000000
    div ecx
    mov eax, edx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; smp_h6(RSI = w[16], EDX = keyID, RDI = out[16]): link key conversion,
; AES-CMAC_w(keyID). The keyID is the 32-bit value ('lebr' = 0x6c656272),
; so it is sent as its four bytes, least significant first.
smp_h6:
    push rcx
    push rdx
    mov [smp_mbuf], edx
    lea rdx, [smp_mbuf]
    mov ecx, 4
    call smp_cmac
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  crypto_selftest -> EAX = 0 if every known answer matches, else the number
;  of the first vector that does not (see the header)
; -----------------------------------------------------------------------------
crypto_selftest:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov eax, 1                          ; AES-NI, SSE4.1, SSSE3: else #UD below
    cpuid
    mov eax, 1
    and ecx, (1 << 25) | (1 << 19) | (1 << 9)
    cmp ecx, (1 << 25) | (1 << 19) | (1 << 9)
    jne .out

    mov ebx, 1                          ; 1: FIPS-197 C.1
    lea rdi, [crypto_out]
    movdqa xmm0, [crypto_kat_aes_pt]
    movdqa [rdi], xmm0
    lea rsi, [crypto_kat_aes_key]
    call aes_encrypt
    lea rsi, [crypto_kat_aes_ct]
    call crypto_same
    jne .fail

    xor r8d, r8d                        ; 2-5: RFC 4493 examples 1-4
.cmac:
    inc ebx
    lea rsi, [crypto_kat_cmac_key]
    lea rdx, [crypto_kat_cmac_msg]
    lea rax, [crypto_kat_cmac_len]
    movzx ecx, byte [rax + r8]
    lea rdi, [crypto_out]
    call aes_cmac
    mov esi, r8d
    shl esi, 4
    lea rax, [crypto_kat_cmac_tag]
    add rsi, rax
    call crypto_same
    jne .fail
    inc r8d
    cmp r8d, 4
    jb .cmac

    inc ebx                             ; 6: ah
    lea rsi, [crypto_kat_irk]
    lea rdx, [crypto_kat_ah_r]
    lea rdi, [crypto_out]
    call smp_ah
    mov eax, [crypto_out]
    xor eax, [crypto_kat_ah_hash]
    and eax, 0xFFFFFF
    jnz .fail

    inc ebx                             ; 7: c1
    lea rsi, [crypto_kat_zero]
    lea rdx, [crypto_kat_c1_r]
    lea rcx, [crypto_kat_c1_preq]
    lea r8, [crypto_kat_c1_pres]
    lea r9, [crypto_kat_c1_ia]
    lea r10, [crypto_kat_c1_ra]
    lea rdi, [crypto_out]
    call smp_c1
    lea rsi, [crypto_kat_c1_res]
    call crypto_same
    jne .fail

    inc ebx                             ; 8: s1
    lea rsi, [crypto_kat_zero]
    lea rdx, [crypto_kat_s1_r1]
    lea rcx, [crypto_kat_s1_r2]
    lea rdi, [crypto_out]
    call smp_s1
    lea rsi, [crypto_kat_s1_res]
    call crypto_same
    jne .fail

    inc ebx                             ; 9: f4
    lea rsi, [crypto_kat_u]
    lea rdx, [crypto_kat_v]
    lea rcx, [crypto_kat_n1]
    xor r8d, r8d
    lea rdi, [crypto_out]
    call smp_f4
    lea rsi, [crypto_kat_f4_res]
    call crypto_same
    jne .fail

    inc ebx                             ; 10: f5, both keys
    lea rsi, [crypto_kat_dhkey]
    lea rdx, [crypto_kat_n1]
    lea rcx, [crypto_kat_n2]
    lea r8, [crypto_kat_a1]
    lea r9, [crypto_kat_a2]
    lea rdi, [crypto_out]
    lea r10, [crypto_out + 16]
    call smp_f5
    lea rsi, [crypto_kat_mackey]
    call crypto_same
    jne .fail
    lea rsi, [crypto_kat_ltk]
    lea rdi, [crypto_out + 16]
    call crypto_same
    jne .fail

    inc ebx                             ; 11: f6
    lea rsi, [crypto_kat_mackey]
    lea rdx, [crypto_kat_n1]
    lea rcx, [crypto_kat_n2]
    lea r8, [crypto_kat_f6_r]
    lea r9, [crypto_kat_f6_iocap]
    lea r10, [crypto_kat_a1]
    lea r11, [crypto_kat_a2]
    lea rdi, [crypto_out]
    call smp_f6
    lea rsi, [crypto_kat_f6_res]
    call crypto_same
    jne .fail

    inc ebx                             ; 12: g2
    lea rsi, [crypto_kat_u]
    lea rdx, [crypto_kat_v]
    lea rcx, [crypto_kat_n1]
    lea r8, [crypto_kat_n2]
    call smp_g2
    cmp eax, 0x2f9ed5ba % 1000000
    jne .fail

    inc ebx                             ; 13: h6
    lea rsi, [crypto_kat_irk]
    mov edx, 0x6c656272                 ; 'lebr'
    lea rdi, [crypto_out]
    call smp_h6
    lea rsi, [crypto_kat_h6_res]
    call crypto_same
    jne .fail

    xor eax, eax
    jmp .out
.fail:
    mov eax, ebx
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; crypto_same(RDI = got[16], RSI = expected[16]) -> ZF = 1 if equal.
; Clobbers EAX, XMM0, XMM1.
crypto_same:
    movdqu xmm0, [rdi]
    movdqu xmm1, [rsi]
    pcmpeqb xmm0, xmm1
    pmovmskb eax, xmm0
    cmp eax, 0xFFFF
    ret

section .rodata
align 16
aes_rot_mask:   dd 0x0c0f0e0d, 0x0c0f0e0d, 0x0c0f0e0d, 0x0c0f0e0d  ; RotWord(w3) x4
aes_rev_mask:   db 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0
aes_rcon:       dd 0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36
align 16
smp_salt:       db 0xbe, 0x83, 0x60, 0x5a, 0xdb, 0x0b, 0x37, 0x60   ; f5 SALT, LSB first
                db 0x38, 0xa5, 0xf5, 0xaa, 0x91, 0x83, 0x88, 0x6c

; known answers: FIPS-197 C.1, RFC 4493 section 4, and Core spec Vol 3
; Part H Appendix D as in Linux smp.c (the SMP ones LSB first)
align 16
crypto_kat_aes_key:
    db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07
    db 0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f
crypto_kat_aes_pt:
    db 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77
    db 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff
crypto_kat_aes_ct:
    db 0x69, 0xc4, 0xe0, 0xd8, 0x6a, 0x7b, 0x04, 0x30
    db 0xd8, 0xcd, 0xb7, 0x80, 0x70, 0xb4, 0xc5, 0x5a
crypto_kat_cmac_key:
    db 0x2b, 0x7e, 0x15, 0x16, 0x28, 0xae, 0xd2, 0xa6
    db 0xab, 0xf7, 0x15, 0x88, 0x09, 0xcf, 0x4f, 0x3c
crypto_kat_cmac_msg:
    db 0x6b, 0xc1, 0xbe, 0xe2, 0x2e, 0x40, 0x9f, 0x96
    db 0xe9, 0x3d, 0x7e, 0x11, 0x73, 0x93, 0x17, 0x2a
    db 0xae, 0x2d, 0x8a, 0x57, 0x1e, 0x03, 0xac, 0x9c
    db 0x9e, 0xb7, 0x6f, 0xac, 0x45, 0xaf, 0x8e, 0x51
    db 0x30, 0xc8, 0x1c, 0x46, 0xa3, 0x5c, 0xe4, 0x11
    db 0xe5, 0xfb, 0xc1, 0x19, 0x1a, 0x0a, 0x52, 0xef
    db 0xf6, 0x9f, 0x24, 0x45, 0xdf, 0x4f, 0x9b, 0x17
    db 0xad, 0x2b, 0x41, 0x7b, 0xe6, 0x6c, 0x37, 0x10
crypto_kat_cmac_tag:
    db 0xbb, 0x1d, 0x69, 0x29, 0xe9, 0x59, 0x37, 0x28   ; 0 bytes
    db 0x7f, 0xa3, 0x7d, 0x12, 0x9b, 0x75, 0x67, 0x46
    db 0x07, 0x0a, 0x16, 0xb4, 0x6b, 0x4d, 0x41, 0x44   ; 16
    db 0xf7, 0x9b, 0xdd, 0x9d, 0xd0, 0x4a, 0x28, 0x7c
    db 0xdf, 0xa6, 0x67, 0x47, 0xde, 0x9a, 0xe6, 0x30   ; 40
    db 0x30, 0xca, 0x32, 0x61, 0x14, 0x97, 0xc8, 0x27
    db 0x51, 0xf0, 0xbe, 0xbf, 0x7e, 0x3b, 0x9d, 0x92   ; 64
    db 0xfc, 0x49, 0x74, 0x17, 0x79, 0x36, 0x3c, 0xfe
crypto_kat_cmac_len:
    db 0, 16, 40, 64

align 16
crypto_kat_zero:                        ; c1 and s1 key
    times 16 db 0
crypto_kat_irk:                         ; ah irk, h6 w
    db 0x9b, 0x7d, 0x39, 0x0a, 0xa6, 0x10, 0x10, 0x34
    db 0x05, 0xad, 0xc8, 0x57, 0xa3, 0x34, 0x02, 0xec
crypto_kat_ah_r:
    db 0x94, 0x81, 0x70
crypto_kat_ah_hash:
    db 0xaa, 0xfb, 0x0d, 0x00
crypto_kat_c1_r:
    db 0xe0, 0x2e, 0x70, 0xc6, 0x4e, 0x27, 0x88, 0x63
    db 0x0e, 0x6f, 0xad, 0x56, 0x21, 0xd5, 0x83, 0x57
crypto_kat_c1_preq:
    db 0x01, 0x01, 0x00, 0x00, 0x10, 0x07, 0x07
crypto_kat_c1_pres:
    db 0x02, 0x03, 0x00, 0x00, 0x08, 0x00, 0x05
crypto_kat_c1_ia:
    db 0xa6, 0xa5, 0xa4, 0xa3, 0xa2, 0xa1, 0x01  ; iat = 1 (random)
crypto_kat_c1_ra:
    db 0xb6, 0xb5, 0xb4, 0xb3, 0xb2, 0xb1, 0x00  ; rat = 0 (public)
crypto_kat_c1_res:
    db 0x86, 0x3b, 0xf1, 0xbe, 0xc5, 0x4d, 0xa7, 0xd2
    db 0xea, 0x88, 0x89, 0x87, 0xef, 0x3f, 0x1e, 0x1e
crypto_kat_s1_r1:
    db 0x88, 0x77, 0x66, 0x55, 0x44, 0x33, 0x22, 0x11
    times 8 db 0
crypto_kat_s1_r2:
    db 0x00, 0xff, 0xee, 0xdd, 0xcc, 0xbb, 0xaa, 0x99
    times 8 db 0
crypto_kat_s1_res:
    db 0x62, 0xa0, 0x6d, 0x79, 0xae, 0x16, 0x42, 0x5b
    db 0x9b, 0xf4, 0xb0, 0xe8, 0xf0, 0xe1, 0x1f, 0x9a
crypto_kat_u:                           ; f4 and g2
    db 0xe6, 0x9d, 0x35, 0x0e, 0x48, 0x01, 0x03, 0xcc
    db 0xdb, 0xfd, 0xf4, 0xac, 0x11, 0x91, 0xf4, 0xef
    db 0xb9, 0xa5, 0xf9, 0xe9, 0xa7, 0x83, 0x2c, 0x5e
    db 0x2c, 0xbe, 0x97, 0xf2, 0xd2, 0x03, 0xb0, 0x20
crypto_kat_v:
    db 0xfd, 0xc5, 0x7f, 0xf4, 0x49, 0xdd, 0x4f, 0x6b
    db 0xfb, 0x7c, 0x9d, 0xf1, 0xc2, 0x9a, 0xcb, 0x59
    db 0x2a, 0xe7, 0xd4, 0xee, 0xfb, 0xfc, 0x0a, 0x90
    db 0x9a, 0xbb, 0xf6, 0x32, 0x3d, 0x8b, 0x18, 0x55
crypto_kat_n1:                          ; f4/g2 x, f5/f6 n1
    db 0xab, 0xae, 0x2b, 0x71, 0xec, 0xb2, 0xff, 0xff
    db 0x3e, 0x73, 0x77, 0xd1, 0x54, 0x84, 0xcb, 0xd5
crypto_kat_n2:                          ; g2 y, f5/f6 n2
    db 0xcf, 0xc4, 0x3d, 0xff, 0xf7, 0x83, 0x65, 0x21
    db 0x6e, 0x5f, 0xa7, 0x25, 0xcc, 0xe7, 0xe8, 0xa6
crypto_kat_f4_res:
    db 0x2d, 0x87, 0x74, 0xa9, 0xbe, 0xa1, 0xed, 0xf1
    db 0x1c, 0xbd, 0xa9, 0x07, 0xf1, 0x16, 0xc9, 0xf2
crypto_kat_dhkey:                       ; f5 w
    db 0x98, 0xa6, 0xbf, 0x73, 0xf3, 0x34, 0x8d, 0x86
    db 0xf1, 0x66, 0xf8, 0xb4, 0x13, 0x6b, 0x79, 0x99
    db 0x9b, 0x7d, 0x39, 0x0a, 0xa6, 0x10, 0x10, 0x34
    db 0x05, 0xad, 0xc8, 0x57, 0xa3, 0x34, 0x02, 0xec
crypto_kat_a1:
    db 0xce, 0xbf, 0x37, 0x37, 0x12, 0x56, 0x00
crypto_kat_a2:
    db 0xc1, 0xcf, 0x2d, 0x70, 0x13, 0xa7, 0x00
crypto_kat_mackey:                      ; f5 mackey, f6 w
    db 0x20, 0x6e, 0x63, 0xce, 0x20, 0x6a, 0x3f, 0xfd
    db 0x02, 0x4a, 0x08, 0xa1, 0x76, 0xf1, 0x65, 0x29
crypto_kat_ltk:
    db 0x38, 0x0a, 0x75, 0x94, 0xb5, 0x22, 0x05, 0x98
    db 0x23, 0xcd, 0xd7, 0x69, 0x11, 0x79, 0x86, 0x69
crypto_kat_f6_r:
    db 0xc8, 0x0f, 0x2d, 0x0c, 0xd2, 0x42, 0xda, 0x08
    db 0x54, 0xbb, 0x53, 0xb4, 0x3b, 0x34, 0xa3, 0x12
crypto_kat_f6_iocap:
    db 0x02, 0x01, 0x01
crypto_kat_f6_res:
    db 0x61, 0x8f, 0x95, 0xda, 0x09, 0x0b, 0x6c, 0xd2
    db 0xc5, 0xe8, 0xd0, 0x9c, 0x98, 0x73, 0xc4, 0xe3
crypto_kat_h6_res:
    db 0x99, 0x63, 0xb1, 0x80, 0xe2, 0xa9, 0xd3, 0xe8
    db 0x1c, 0xc9, 0x6d, 0xe7, 0x02, 0xe1, 0x9a, 0x2d

section .bss
alignb 16
aes_rk:         resb 11 * 16            ; expanded key, rounds 0-10
cmac_pad:       resb 16                 ; the padded last block
smp_kbuf:       resb 16                 ; a toolbox key, reversed
smp_tbuf:       resb 16                 ; f5's T, g2's full tag
smp_mbuf:       resb SMP_MSG_MAX        ; a toolbox message as Linux lays it out
smp_mrev:       resb SMP_MSG_MAX        ; ... and reversed for AES-CMAC
crypto_out:     resb 32                 ; selftest results
