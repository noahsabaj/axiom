; =============================================================================
;  pubkey.asm - checking signatures: RSA (PKCS #1 v1.5 and PSS, RFC 8017)
;  with 2048- to 4096-bit keys, and ECDSA (FIPS 186-5) on P-256 and P-384,
;  each with SHA-256, SHA-384 or SHA-512. What certificates and TLS 1.3's
;  CertificateVerify need, on bignum.asm.
;
;    sig_verify(RDI = key, ESI = scheme, RDX = message, RCX = bytes, R8 =
;        signature, R9D = its bytes) -> CF unless the signature is good
;    hash_of(EAX = 4 SHA-256, 5 SHA-384, 6 SHA-512; RDI = digest, RSI =
;        data, RDX = bytes) -> EAX = digest bytes; CF for another number
;    der_tlv(RSI = DER, R11 = its end) -> CF if malformed; else EAX = tag,
;        RDX = contents, RCX = their bytes, RSI past them (changes RAX, RCX,
;        RDX, RSI and R10 only)
;
;  A key (KEY bytes) says what it is (KT_*), and points to the modulus,
;  big-endian with no leading zeros, and holds the public exponent; or to
;  the curve point, uncompressed (04, X, Y). Schemes are TLS's numbers:
;  0x0401/0501/0601 RSA PKCS #1 v1.5 with SHA-256/384/512, 0x0804/0805/0806
;  RSA-PSS with a salt as long as the hash, 0x0403/0503/0603 ECDSA with
;  SHA-256/384/512 on the key's curve, whichever it is (TLS 1.3 ties the
;  curve to the scheme; tls.asm checks that). The ECDSA signature is DER, as
;  in both certificates and TLS.
;
;  And signing, for what Axiom serves with TLS: ECDSA P-256 with SHA-256.
;
;    sig_sign(RDI = out, ECDSA_MAX bytes; RSI = the private key, 32 bytes
;        big-endian; RDX = message, RCX = bytes) -> CF if the key is not
;        one (0 < d < n) or there are no hardware random numbers; else EAX
;        = the signature's bytes (DER, as TLS's 0x0403 wants it)
;    ec_public(RDI = out, 65 bytes; RSI = the private key) -> CF as above;
;        else its public key, uncompressed (04, X, Y)
;
;  The private key and the nonce are secrets, and bignum.asm is not
;  constant-time, so neither is used bare: the point is multiplied by a
;  Montgomery ladder (the same doubling and addition for every bit, the
;  points swapped by mask), on the scalar plus a random multiple of n, from
;  a base point in random projective coordinates; the nonce is inverted
;  times a random number. What the scratch held is wiped afterwards.
;
;  sig_verify, sig_sign, ec_public and hash_of preserve all general
;  registers but RAX, and clobber XMM0-XMM10 (sha256.asm). Scratch in
;  .bss: main loop only.
; =============================================================================

K_TYPE          equ 0
K_LEN           equ 4                   ; bytes at K_PTR
K_E             equ 8                   ; RSA: the public exponent
K_PTR           equ 16
KEY             equ 24

KT_RSA          equ 1
KT_P256         equ 2
KT_P384         equ 3

ECDSA_MAX       equ 72                  ; a P-256 signature, DER, at most

; the curves: 48-byte big-endian slots, the first CV_SIZE bytes used
CV_SIZE         equ 0
CV_P            equ 8
CV_N            equ CV_P + 48
CV_B            equ CV_N + 48
CV_GX           equ CV_B + 48
CV_GY           equ CV_GX + 48

; Jacobian points (X, Y, Z), each coordinate in 8 limbs
PX              equ 0
PY              equ 64
PZ              equ 128
PT              equ 192

section .text

sig_verify:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov [pk_key], rdi
    mov [pk_sig], r8
    mov r9d, r9d
    mov [pk_siglen], r9
    movzx ebx, si                       ; EBX = hash, EBP = 1 PKCS #1, 2 PSS, 3 ECDSA
    movzx ebp, bl
    shr ebx, 8
    cmp ebx, 8
    jne .classic
    mov ebx, ebp
    mov ebp, 2
    jmp .hash
.classic:
    cmp ebp, 1
    je .hash
    cmp ebp, 3
    jne .bad
.hash:
    mov [pk_halg], ebx
    mov eax, ebx
    lea rdi, [pk_hash]
    mov rsi, rdx
    mov rdx, rcx
    call hash_of
    jc .bad
    mov [pk_hlen], eax
    mov rbx, [pk_key]
    mov eax, [rbx + K_TYPE]
    cmp ebp, 3
    je .ec
    cmp eax, KT_RSA
    jne .bad
    cmp ebp, 2
    je .pss
    call rsa_pkcs1
    jmp .out
.pss:
    call rsa_pss
    jmp .out
.ec:
    call ec_verify
    jmp .out
.bad:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

hash_of:
    cmp eax, 4
    jne .not256
    call sha256
    mov eax, 32
    clc
    ret
.not256:
    cmp eax, 5
    jne .not384
    call sha384
    mov eax, 48
    clc
    ret
.not384:
    cmp eax, 6
    jne .unknown
    call sha512
    mov eax, 64
    clc
    ret
.unknown:
    stc
    ret

der_tlv:
    mov r10, r11
    sub r10, rsi
    cmp r10, 2
    jb .bad
    movzx eax, byte [rsi]
    mov dl, al
    and dl, 0x1F
    cmp dl, 0x1F                        ; tag numbers past 30: not in X.509
    je .bad
    movzx ecx, byte [rsi + 1]
    add rsi, 2
    test cl, 0x80
    jz .length
    and ecx, 0x7F
    jz .bad                             ; indefinite: not DER
    cmp ecx, 3
    ja .bad
    mov r10, r11
    sub r10, rsi
    cmp rcx, r10
    ja .bad
    mov edx, ecx
    xor ecx, ecx
.byte:
    shl ecx, 8
    or cl, [rsi]
    inc rsi
    dec edx
    jnz .byte
.length:
    mov r10, r11
    sub r10, rsi
    cmp rcx, r10
    ja .bad
    mov rdx, rsi
    add rsi, rcx
    clc
    ret
.bad:
    stc
    ret

; -----------------------------------------------------------------------------
;  RSA. These may change any register; CF unless good.
; -----------------------------------------------------------------------------

; rsa_public: pk_em = signature^e mod n, as many bytes as n (RBX = key)
rsa_public:
    mov ecx, [rbx + K_LEN]
    cmp rcx, [pk_siglen]
    jne .bad
    mov rax, [rbx + K_E]
    test al, 1
    jz .bad
    cmp rax, 3
    jb .bad
    mov [pk_e], rax
    lea rdi, [pk_mc]
    mov rsi, [rbx + K_PTR]
    call mont_setup
    jc .bad
    cmp qword [pk_mc + MC_BITS], 2048
    jb .bad
    mov edx, [pk_mc + MC_L]
    lea rdi, [pk_a]
    mov rsi, [pk_sig]
    mov ecx, [rbx + K_LEN]
    call bn_load
    jc .bad
    lea rsi, [pk_a]                     ; the signature must be below n
    lea rdi, [pk_mc + MC_N]
    mov ecx, edx
    call bn_cmp
    jnc .bad
    lea rdi, [pk_a]
    lea rsi, [pk_a]
    lea rcx, [pk_mc]
    call mont_in
    lea rdx, [pk_e]
    mov r8d, 1
    call mont_exp
    call mont_out
    lea rdi, [pk_em]
    lea rsi, [pk_a]
    mov ecx, [rbx + K_LEN]
    call bn_store
    clc
    ret
.bad:
    stc
    ret

; rsa_pkcs1: 00 01 FF .. FF 00 DigestInfo hash, byte for byte
rsa_pkcs1:
    call rsa_public
    jc .bad
    mov r12d, [rbx + K_LEN]             ; R12 = k
    mov r13d, [pk_hlen]
    lea eax, [r13 + 19 + 3 + 8]         ; DigestInfo, 00 01 .. 00, 8 FFs at least
    cmp r12d, eax
    jb .bad
    lea rdi, [pk_em2]
    mov word [rdi], 0x0100
    add rdi, 2
    mov ecx, r12d
    sub ecx, r13d
    sub ecx, 19 + 3
    mov al, 0xFF
    rep stosb
    mov byte [rdi], 0
    inc rdi
    mov eax, [pk_halg]
    sub eax, 4
    imul eax, eax, 19
    lea rsi, [pk_digestinfo]
    add rsi, rax
    mov ecx, 19
    rep movsb
    lea rsi, [pk_hash]
    mov ecx, r13d
    rep movsb
    lea rsi, [pk_em]
    lea rdi, [pk_em2]
    mov ecx, r12d
    repe cmpsb
    jne .bad
    clc
    ret
.bad:
    stc
    ret

; rsa_pss: EMSA-PSS-VERIFY with MGF1 and the salt as long as the hash
rsa_pss:
    call rsa_public
    jc .bad
    mov r12, [pk_mc + MC_BITS]          ; R12 = emBits = modBits - 1
    dec r12
    lea r13, [r12 + 7]                  ; R13 = emLen
    shr r13, 3
    lea r14, [pk_em]                    ; R14 = EM
    cmp r13d, [rbx + K_LEN]
    jae .whole
    cmp byte [r14], 0                   ; a byte shorter than n: that byte is 0
    jne .bad
    inc r14
.whole:
    mov r15d, [pk_hlen]                 ; R15 = hLen = sLen
    lea rax, [r15 * 2 + 2]
    cmp r13, rax
    jb .bad
    cmp byte [r14 + r13 - 1], 0xBC
    jne .bad
    mov rbp, r13                        ; RBP = dbLen
    sub rbp, r15
    dec rbp
    mov rcx, r13                        ; the bits above emBits must be 0
    shl rcx, 3
    sub rcx, r12
    mov eax, 0xFF
    shr eax, cl
    mov [pk_mask], al
    not al
    test [r14], al
    jnz .bad
    lea rdi, [pk_db]                    ; DB = maskedDB ^ MGF1(H, dbLen)
    mov rsi, r14
    mov rcx, rbp
    rep movsb
    xor ebx, ebx                        ; EBX = counter, R12 = bytes done
    xor r12d, r12d
.mgf:
    cmp r12, rbp
    jae .unmasked
    lea rdi, [pk_mgf]
    lea rsi, [r14 + rbp]
    mov rcx, r15
    rep movsb
    mov eax, ebx
    bswap eax
    mov [rdi], eax
    mov eax, [pk_halg]
    lea rdi, [pk_mgf_out]
    lea rsi, [pk_mgf]
    lea rdx, [r15 + 4]
    call hash_of
    xor ecx, ecx
.xor:
    cmp rcx, r15
    jae .block
    cmp r12, rbp
    jae .block
    lea rsi, [pk_mgf_out]
    mov al, [rsi + rcx]
    lea rdi, [pk_db]
    xor [rdi + r12], al
    inc rcx
    inc r12
    jmp .xor
.block:
    inc ebx
    jmp .mgf
.unmasked:
    lea rdi, [pk_db]
    mov al, [pk_mask]
    and [rdi], al
    mov rcx, rbp                        ; zeros, then 01, then the salt
    sub rcx, r15
    dec rcx
    xor eax, eax
.zeros:
    test rcx, rcx
    jz .one
    or al, [rdi]
    inc rdi
    dec rcx
    jmp .zeros
.one:
    test al, al
    jnz .bad
    cmp byte [rdi], 1
    jne .bad
    lea rsi, [rdi + 1]                  ; M' = 8 zeros, the hash, the salt
    lea rdi, [pk_mp]
    xor eax, eax
    mov [rdi], rax
    add rdi, 8
    push rsi
    lea rsi, [pk_hash]
    mov rcx, r15
    rep movsb
    pop rsi
    mov rcx, r15
    rep movsb
    mov eax, [pk_halg]
    lea rdi, [pk_h2]
    lea rsi, [pk_mp]
    lea rdx, [r15 * 2 + 8]
    call hash_of
    lea rsi, [pk_h2]                    ; and its hash is H
    lea rdi, [r14 + rbp]
    mov rcx, r15
    repe cmpsb
    jne .bad
    clc
    ret
.bad:
    stc
    ret

; -----------------------------------------------------------------------------
;  ECDSA. ec_verify may change any register; CF unless good.
; -----------------------------------------------------------------------------

%macro EC_OP 4                          ; function, out, a, b: modulo p
    lea rdi, %2
    lea rsi, %3
    lea rdx, %4
    lea rcx, [ec_p]
    call %1
%endmacro
%define FMUL EC_OP mont_mul,
%define FADD EC_OP mont_add,
%define FSUB EC_OP mont_sub,

ec_verify:
    mov rbx, [pk_key]
    mov eax, [rbx + K_TYPE]
    lea r12, [ec_p256]
    cmp eax, KT_P256
    je .curve
    lea r12, [ec_p384]
    cmp eax, KT_P384
    jne .bad
.curve:
    mov r13d, [r12 + CV_SIZE]           ; R13 = bytes of a number
    mov [ec_size], r13
    lea eax, [r13 * 2 + 1]
    cmp eax, [rbx + K_LEN]
    jne .bad
    mov rsi, [rbx + K_PTR]
    cmp byte [rsi], 4
    jne .bad
    mov rsi, [pk_sig]                   ; SEQUENCE { INTEGER r, INTEGER s }
    mov r11, [pk_siglen]
    add r11, rsi
    call der_tlv
    jc .bad
    cmp eax, 0x30
    jne .bad
    cmp rsi, r11
    jne .bad
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call ec_int
    jc .bad
    mov [ec_rp], r14
    mov [ec_rl], r15
    call ec_int
    jc .bad
    mov [ec_sp], r14
    mov [ec_sl], r15
    cmp rsi, r11
    jne .bad
    lea rdi, [ec_n]
    lea rsi, [r12 + CV_N]
    mov ecx, r13d
    call mont_setup
    lea rdi, [ec_p]
    lea rsi, [r12 + CV_P]
    call mont_setup
    mov rdx, [ec_n + MC_L]
    mov [ec_l], rdx
    lea rdi, [ec_r]                     ; 0 < r, s < n
    mov rsi, [ec_rp]
    mov rcx, [ec_rl]
    call bn_load
    jc .bad
    lea rdi, [ec_s]
    mov rsi, [ec_sp]
    mov rcx, [ec_sl]
    call bn_load
    jc .bad
    lea rsi, [ec_r]
    call ec_scalar_ok
    jc .bad
    lea rsi, [ec_s]
    call ec_scalar_ok
    jc .bad
    mov ecx, [pk_hlen]                  ; e: the hash's leftmost bits, mod n
    cmp ecx, r13d
    cmova ecx, r13d
    lea rdi, [ec_e]
    lea rsi, [pk_hash]
    call bn_load
    lea rsi, [ec_e]
    lea rdi, [ec_n + MC_N]
    mov ecx, edx
    call bn_cmp
    jb .e_ok
    lea rdi, [ec_e]
    lea rsi, [ec_e]
    lea rdx, [ec_n + MC_N]
    call bn_sub
.e_ok:
    mov rdx, [ec_l]
    lea rdi, [ec_w]                     ; w = 1/s = s^(n-2), in Montgomery form
    lea rsi, [ec_s]
    lea rcx, [ec_n]
    call mont_in
    lea rdi, [ec_x]
    lea rsi, [ec_n + MC_N]
    call ec_minus2
    lea rdi, [ec_w]
    lea rsi, [ec_w]
    lea rdx, [ec_x]
    mov r8, [ec_l]
    lea rcx, [ec_n]
    call mont_exp
    lea rdi, [ec_u1]                    ; u1 = e w, u2 = r w, plain
    lea rsi, [ec_e]
    lea rdx, [ec_w]
    call mont_mul
    lea rdi, [ec_u2]
    lea rsi, [ec_r]
    call mont_mul
    mov rsi, [rbx + K_PTR]              ; Q, below p and on the curve
    inc rsi
    lea rdi, [ec_Q + PX]
    call ec_coord
    jc .bad
    add rsi, r13
    lea rdi, [ec_Q + PY]
    call ec_coord
    jc .bad
    lea rdi, [ec_Q + PZ]
    call ec_one
    lea rdi, [ec_bm]
    lea rsi, [r12 + CV_B]
    call ec_coord
    FMUL [ec_t1], [ec_Q + PY], [ec_Q + PY]
    FMUL [ec_t2], [ec_Q + PX], [ec_Q + PX]
    FMUL [ec_t2], [ec_t2], [ec_Q + PX]
    FSUB [ec_t2], [ec_t2], [ec_Q + PX]
    FSUB [ec_t2], [ec_t2], [ec_Q + PX]
    FSUB [ec_t2], [ec_t2], [ec_Q + PX]
    FADD [ec_t2], [ec_t2], [ec_bm]
    lea rsi, [ec_t1]
    lea rdi, [ec_t2]
    mov rcx, [ec_l]
    call bn_cmp
    jne .bad
    lea rdi, [ec_G + PX]                ; G
    lea rsi, [r12 + CV_GX]
    call ec_coord
    lea rdi, [ec_G + PY]
    lea rsi, [r12 + CV_GY]
    call ec_coord
    lea rdi, [ec_G + PZ]
    call ec_one
    lea r12, [ec_G]                     ; G + Q
    lea r14, [ec_Q]
    lea r13, [ec_GQ]
    call ec_add
    lea rdi, [ec_R]                     ; R = u1 G + u2 Q, both at once
    xor eax, eax
    mov ecx, PT
    rep stosb
    lea r12, [ec_R]
    lea r13, [ec_R]
    mov r15, [ec_size]
    shl r15, 3
.bit:
    dec r15
    call ec_double
    xor ebp, ebp
    bt qword [ec_u1], r15
    adc ebp, 0
    bt qword [ec_u2], r15
    jnc .picked
    or ebp, 2
.picked:
    test ebp, ebp
    jz .next
    lea r14, [ec_G]
    cmp ebp, 1
    je .add
    lea r14, [ec_Q]
    cmp ebp, 2
    je .add
    lea r14, [ec_GQ]
.add:
    call ec_add
.next:
    test r15, r15
    jnz .bit
    lea rsi, [ec_R + PZ]                ; not the point at infinity
    mov rcx, [ec_l]
    call bn_is_zero
    jz .bad
    lea rdi, [ec_x]                     ; x = X / Z^2, plain, then mod n
    lea rsi, [ec_p + MC_N]
    call ec_minus2
    lea rdi, [ec_t1]
    lea rsi, [ec_R + PZ]
    lea rdx, [ec_x]
    mov r8, [ec_l]
    lea rcx, [ec_p]
    call mont_exp
    FMUL [ec_t2], [ec_t1], [ec_t1]
    FMUL [ec_t2], [ec_R + PX], [ec_t2]
    lea rdi, [ec_t2]
    lea rsi, [ec_t2]
    lea rcx, [ec_p]
    call mont_out
    lea rsi, [ec_t2]
    lea rdi, [ec_n + MC_N]
    mov rcx, [ec_l]
    call bn_cmp
    jb .reduced
    lea rdi, [ec_t2]
    lea rdx, [ec_n + MC_N]
    call bn_sub
.reduced:
    lea rsi, [ec_t2]                    ; and that is r
    lea rdi, [ec_r]
    call bn_cmp
    jne .bad
    clc
    ret
.bad:
    stc
    ret

; ec_int(RSI, R11 = end) -> R14, R15 = an INTEGER's magnitude, at most R13
; bytes; CF if not one, or negative, or too big
ec_int:
    call der_tlv
    jc .bad
    cmp eax, 2
    jne .bad
    test ecx, ecx
    jz .bad
    test byte [rdx], 0x80
    jnz .bad
.strip:
    test ecx, ecx
    jz .done
    cmp byte [rdx], 0
    jne .done
    inc rdx
    dec ecx
    jmp .strip
.done:
    cmp rcx, r13
    ja .bad
    mov r14, rdx
    mov r15, rcx
    clc
    ret
.bad:
    stc
    ret

; ec_scalar_ok(RSI) -> CF unless 0 < it < n
ec_scalar_ok:
    mov rcx, [ec_l]
    call bn_is_zero
    jz .bad
    lea rdi, [ec_n + MC_N]
    call bn_cmp
    jnc .bad
    clc
    ret
.bad:
    stc
    ret

; ec_minus2(RDI = out, RSI = an odd modulus): out = it - 2
ec_minus2:
    mov rcx, [ec_l]
    lea rdx, [bn_one]
    call bn_sub
    mov rsi, rdi
    jmp bn_sub

; ec_coord(RDI = out, RSI = R13 big-endian bytes) -> CF unless below p;
; out in Montgomery form
ec_coord:
    push rsi
    mov ecx, r13d
    mov rdx, [ec_l]
    call bn_load
    jc .out
    push rdi
    mov rsi, rdi
    lea rdi, [ec_p + MC_N]
    mov rcx, rdx
    call bn_cmp
    pop rdi
    cmc
    jc .out
    mov rsi, rdi
    lea rcx, [ec_p]
    call mont_in
    clc
.out:
    pop rsi
    ret

; ec_one(RDI): 1 in Montgomery form
ec_one:
    lea rsi, [ec_p + MC_ONE]
    mov rcx, [ec_l]
    rep movsq
    ret

; ec_double: R13 = 2 R12 (they may be the same point; a = -3, the
; "dbl-2001-b" formulas). Changes RAX, RCX, RDX, RSI, RDI.
ec_double:
    FMUL [ec_d], [r12 + PZ], [r12 + PZ]         ; delta = Z^2
    FMUL [ec_g], [r12 + PY], [r12 + PY]         ; gamma = Y^2
    FMUL [ec_b], [r12 + PX], [ec_g]             ; beta = X gamma
    FSUB [ec_t1], [r12 + PX], [ec_d]
    FADD [ec_t2], [r12 + PX], [ec_d]
    FMUL [ec_t1], [ec_t1], [ec_t2]
    FADD [ec_a], [ec_t1], [ec_t1]
    FADD [ec_a], [ec_a], [ec_t1]                ; alpha = 3 (X - delta)(X + delta)
    FADD [ec_t2], [r12 + PY], [r12 + PZ]
    FMUL [ec_t2], [ec_t2], [ec_t2]
    FSUB [ec_t2], [ec_t2], [ec_g]
    FSUB [r13 + PZ], [ec_t2], [ec_d]            ; Z3 = (Y + Z)^2 - gamma - delta
    FMUL [ec_t1], [ec_a], [ec_a]
    FADD [ec_t2], [ec_b], [ec_b]
    FADD [ec_t2], [ec_t2], [ec_t2]              ; 4 beta
    FADD [ec_t3], [ec_t2], [ec_t2]
    FSUB [r13 + PX], [ec_t1], [ec_t3]           ; X3 = alpha^2 - 8 beta
    FSUB [ec_t2], [ec_t2], [r13 + PX]
    FMUL [ec_t2], [ec_a], [ec_t2]
    FMUL [ec_t1], [ec_g], [ec_g]
    FADD [ec_t1], [ec_t1], [ec_t1]
    FADD [ec_t1], [ec_t1], [ec_t1]
    FADD [ec_t1], [ec_t1], [ec_t1]              ; 8 gamma^2
    FSUB [r13 + PY], [ec_t2], [ec_t1]           ; Y3 = alpha (4 beta - X3) - 8 gamma^2
    ret

; ec_add: R13 = R12 + R14 (R13 may be R12; "add-2007-bl"), the point at
; infinity (Z = 0) and doubling included. Changes RAX, RCX, RDX, RSI, RDI.
ec_add:
    lea rsi, [r12 + PZ]
    mov rcx, [ec_l]
    call bn_is_zero
    jnz .p
    mov rsi, r14                        ; P at infinity: Q
    jmp .copy
.p:
    lea rsi, [r14 + PZ]
    mov rcx, [ec_l]
    call bn_is_zero
    jnz .both
    mov rsi, r12                        ; Q at infinity: P
    jmp .copy
.both:
    FMUL [ec_z1z1], [r12 + PZ], [r12 + PZ]
    FMUL [ec_z2z2], [r14 + PZ], [r14 + PZ]
    FMUL [ec_u1f], [r12 + PX], [ec_z2z2]
    FMUL [ec_u2f], [r14 + PX], [ec_z1z1]
    FMUL [ec_s1], [r12 + PY], [r14 + PZ]
    FMUL [ec_s1], [ec_s1], [ec_z2z2]
    FMUL [ec_s2], [r14 + PY], [r12 + PZ]
    FMUL [ec_s2], [ec_s2], [ec_z1z1]
    FSUB [ec_h], [ec_u2f], [ec_u1f]
    FSUB [ec_rr], [ec_s2], [ec_s1]
    lea rsi, [ec_h]
    mov rcx, [ec_l]
    call bn_is_zero
    jnz .general
    lea rsi, [ec_rr]                    ; the same x: the same point, or opposites
    call bn_is_zero
    jz ec_double
    lea rdi, [r13 + PZ]
    xor eax, eax
    rep stosq
    ret
.general:
    FMUL [ec_t1], [r12 + PZ], [r14 + PZ]
    FMUL [ec_z3], [ec_t1], [ec_h]               ; Z3 = Z1 Z2 H
    FMUL [ec_h2], [ec_h], [ec_h]
    FMUL [ec_h3], [ec_h], [ec_h2]
    FMUL [ec_v], [ec_u1f], [ec_h2]
    FMUL [ec_t1], [ec_rr], [ec_rr]
    FSUB [ec_t1], [ec_t1], [ec_h3]
    FSUB [ec_t1], [ec_t1], [ec_v]
    FSUB [ec_x3], [ec_t1], [ec_v]               ; X3 = r^2 - H^3 - 2 V
    FSUB [ec_t1], [ec_v], [ec_x3]
    FMUL [ec_t1], [ec_rr], [ec_t1]
    FMUL [ec_t2], [ec_s1], [ec_h3]
    FSUB [r13 + PY], [ec_t1], [ec_t2]           ; Y3 = r (V - X3) - S1 H^3
    lea rsi, [ec_x3]
    lea rdi, [r13 + PX]
    mov ecx, 64
    rep movsb
    lea rsi, [ec_z3]
    lea rdi, [r13 + PZ]
    mov ecx, 64
    rep movsb
    ret
.copy:
    cmp rsi, r13
    je .same
    mov rdi, r13
    mov ecx, PT
    rep movsb
.same:
    ret

; -----------------------------------------------------------------------------
;  Signing, on P-256
; -----------------------------------------------------------------------------

%macro SIGN_SAVE 0
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro SIGN_RESTORE 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
%endmacro

sig_sign:
    SIGN_SAVE
    mov [pk_sig], rdi
    mov rbx, rsi                        ; RBX = the key
    mov eax, 4                          ; SHA-256
    lea rdi, [pk_hash]
    mov rsi, rdx
    mov rdx, rcx
    call hash_of
    call ec_setup256
    lea rdi, [ec_priv]                  ; d
    mov rsi, rbx
    mov ecx, 32
    mov edx, 4
    call bn_load
    lea rsi, [ec_priv]
    call ec_scalar_ok
    jc .bad
    lea rdi, [ec_e]                     ; e: the hash, mod n
    lea rsi, [pk_hash]
    mov ecx, 32
    mov edx, 4
    call bn_load
    lea rsi, [ec_e]
    lea rdi, [ec_n + MC_N]
    mov ecx, 4
    call bn_cmp
    jb .try
    lea rdi, [ec_e]
    lea rdx, [ec_n + MC_N]
    call bn_sub
.try:
    lea rdi, [ec_k]                     ; the nonce k
    lea rsi, [ec_n]
    call ec_random
    jc .bad
    lea rsi, [ec_k]
    call ec_mul_g
    jc .bad
    lea r12, [ec_L0]
    call ec_affine
    lea rsi, [ec_x]                     ; r = x mod n
    lea rdi, [ec_n + MC_N]
    mov ecx, 4
    call bn_cmp
    jb .r
    lea rdi, [ec_x]
    lea rdx, [ec_n + MC_N]
    call bn_sub
.r:
    lea rsi, [ec_x]
    call bn_is_zero
    jz .try
    lea rdi, [ec_r]
    mov ecx, 8
    rep movsq
    lea rdi, [ec_bl]                    ; b, to blind k's inverse
    lea rsi, [ec_n]
    call ec_random
    jc .bad
    lea rcx, [ec_n]                     ; mod n, in Montgomery form:
    lea rdi, [ec_w]
    lea rsi, [ec_k]
    call mont_in
    lea rdi, [ec_u1]
    lea rsi, [ec_bl]
    call mont_in
    lea rdi, [ec_w]
    lea rsi, [ec_w]
    lea rdx, [ec_u1]
    call mont_mul                       ; k b
    lea rdi, [ec_u2]
    lea rsi, [ec_n + MC_N]
    call ec_minus2
    lea rdi, [ec_w]
    lea rsi, [ec_w]
    lea rdx, [ec_u2]
    mov r8, [ec_l]
    lea rcx, [ec_n]
    call mont_exp                       ; 1 / (k b)
    lea rdi, [ec_w]
    lea rsi, [ec_w]
    lea rdx, [ec_u1]
    call mont_mul                       ; 1 / k
    lea rdi, [ec_u1]
    lea rsi, [ec_r]
    call mont_in
    lea rdi, [ec_u2]
    lea rsi, [ec_priv]
    call mont_in
    lea rdi, [ec_u1]
    lea rsi, [ec_u1]
    lea rdx, [ec_u2]
    call mont_mul                       ; r d
    lea rdi, [ec_u2]
    lea rsi, [ec_e]
    call mont_in
    lea rdi, [ec_u1]
    lea rsi, [ec_u1]
    lea rdx, [ec_u2]
    call mont_add                       ; e + r d
    lea rdi, [ec_u1]
    lea rsi, [ec_u1]
    lea rdx, [ec_w]
    call mont_mul                       ; s = (e + r d) / k
    lea rdi, [ec_s]
    lea rsi, [ec_u1]
    call mont_out
    lea rsi, [ec_s]
    mov ecx, 4
    call bn_is_zero
    jz .try
    mov rdi, [pk_sig]
    call ec_der
    call ec_forget
    clc
    jmp .out
.bad:
    call ec_forget
    stc
.out:
    SIGN_RESTORE
    ret

ec_public:
    SIGN_SAVE
    mov rbx, rdi
    mov r14, rsi
    call ec_setup256
    lea rdi, [ec_priv]
    mov rsi, r14
    mov ecx, 32
    mov edx, 4
    call bn_load
    lea rsi, [ec_priv]
    call ec_scalar_ok
    jc .bad
    lea rsi, [ec_priv]
    call ec_mul_g
    jc .bad
    lea r12, [ec_L0]
    call ec_affine
    mov byte [rbx], 4
    lea rdi, [rbx + 1]
    lea rsi, [ec_x]
    mov ecx, 32
    call bn_store
    lea rdi, [rbx + 33]
    lea rsi, [ec_y]
    call bn_store
    call ec_forget
    clc
    jmp .out
.bad:
    call ec_forget
    stc
.out:
    SIGN_RESTORE
    ret

; ec_setup256: P-256's contexts in ec_p and ec_n, ec_size and ec_l
ec_setup256:
    lea rsi, [ec_p256]
    mov qword [ec_size], 32
    lea rdi, [ec_n]
    add rsi, CV_N
    mov ecx, 32
    call mont_setup
    lea rdi, [ec_p]
    lea rsi, [ec_p256 + CV_P]
    call mont_setup
    mov rax, [ec_n + MC_L]
    mov [ec_l], rax
    ret

; ec_random(RDI = 4 limbs, RSI = ec_n or ec_p) -> CF if there are no
; hardware random numbers; else 0 < it < that modulus
ec_random:
    push rdi
    push rsi
.again:
    lea rdi, [ec_rnd]
    mov ecx, 32
    call rand_bytes
    jc .out
    mov rdi, [rsp + 8]
    lea rsi, [ec_rnd]
    mov edx, 4
    call bn_load
    mov rsi, rdi
    mov ecx, 4
    call bn_is_zero
    jz .again
    mov rdi, [rsp]
    add rdi, MC_N
    call bn_cmp
    jnc .again
    clc
.out:
    pop rsi
    pop rdi
    ret

; ec_mul_g(RSI = a scalar, 4 limbs, 0 < it < n) -> CF if there are no
; hardware random numbers; else ec_L0 = it times G (Jacobian, Montgomery
; form). Changes every register but RBX, RBP, R14 and R15.
ec_mul_g:
    push rbx
    push rbp
    push r14
    push r15
    mov rbx, rsi
    lea rdi, [ec_rnd]                   ; the scalar blinded: k + m n, m with
    mov ecx, 8                          ; its top two bits set, so that
    call rand_bytes                     ; 2^319 < it < 2^320
    jc .out
    mov rbp, [ec_rnd]
    bts rbp, 63
    bts rbp, 62
    lea rsi, [ec_n + MC_N]
    lea rdi, [ec_kk]
    xor r8d, r8d
    xor ecx, ecx
.mul:
    mov rax, [rsi + rcx * 8]
    mul rbp
    add rax, r8
    adc rdx, 0
    add rax, [rbx + rcx * 8]
    adc rdx, 0
    mov [rdi + rcx * 8], rax
    mov r8, rdx
    inc ecx
    cmp ecx, 4
    jb .mul
    mov [rdi + 32], r8
    lea r12, [ec_p256]                  ; G, in Montgomery form
    mov r13d, 32
    lea rdi, [ec_L0 + PX]
    lea rsi, [r12 + CV_GX]
    call ec_coord
    lea rdi, [ec_L0 + PY]
    lea rsi, [r12 + CV_GY]
    call ec_coord
    lea rdi, [ec_lam]                   ; and as (l^2 X, l^3 Y, l), l random
    lea rsi, [ec_p]
    call ec_random
    jc .out
    lea rdi, [ec_L0 + PZ]
    lea rsi, [ec_lam]
    lea rcx, [ec_p]
    call mont_in
    FMUL [ec_t1], [ec_L0 + PZ], [ec_L0 + PZ]
    FMUL [ec_L0 + PX], [ec_L0 + PX], [ec_t1]
    FMUL [ec_t1], [ec_t1], [ec_L0 + PZ]
    FMUL [ec_L0 + PY], [ec_L0 + PY], [ec_t1]
    lea r12, [ec_L0]                    ; the ladder: L1 - L0 = G all along,
    lea r13, [ec_L1]                    ; from G and 2 G for the top bit
    call ec_double
    mov r15d, 319
.bit:
    dec r15d
    xor eax, eax
    bt qword [ec_kk], r15
    setc al
    mov ebp, eax
    call ec_cswap
    lea r12, [ec_L1]                    ; L1 = L0 + L1
    lea r14, [ec_L0]
    lea r13, [ec_L1]
    call ec_add
    lea r12, [ec_L0]                    ; L0 = 2 L0
    lea r13, [ec_L0]
    call ec_double
    mov eax, ebp
    call ec_cswap
    test r15d, r15d
    jnz .bit
    clc
.out:
    pop r15
    pop r14
    pop rbp
    pop rbx
    ret

; ec_cswap(EAX = 0 or 1): ec_L0 and ec_L1 swapped if 1, the same work
; either way
ec_cswap:
    push rcx
    push rdx
    push rsi
    push rdi
    neg rax
    lea rsi, [ec_L0]
    lea rdi, [ec_L1]
    xor ecx, ecx
.q:
    mov rdx, [rsi + rcx * 8]
    xor rdx, [rdi + rcx * 8]
    and rdx, rax
    xor [rsi + rcx * 8], rdx
    xor [rdi + rcx * 8], rdx
    inc ecx
    cmp ecx, PT / 8
    jb .q
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ec_affine(R12 = a point, not at infinity) -> ec_x, ec_y: its coordinates,
; plain
ec_affine:
    lea rdi, [ec_x]                     ; 1/Z = Z^(p - 2)
    lea rsi, [ec_p + MC_N]
    call ec_minus2
    lea rdi, [ec_t1]
    lea rsi, [r12 + PZ]
    lea rdx, [ec_x]
    mov r8, [ec_l]
    lea rcx, [ec_p]
    call mont_exp
    FMUL [ec_t2], [ec_t1], [ec_t1]
    FMUL [ec_t3], [ec_t2], [ec_t1]
    FMUL [ec_x], [r12 + PX], [ec_t2]
    FMUL [ec_y], [r12 + PY], [ec_t3]
    lea rcx, [ec_p]
    lea rdi, [ec_x]
    mov rsi, rdi
    call mont_out
    lea rdi, [ec_y]
    mov rsi, rdi
    jmp mont_out

; ec_der(RDI = out): SEQUENCE { INTEGER r, INTEGER s }, from ec_r and ec_s
; -> EAX = its bytes
ec_der:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + 2]
    lea rsi, [ec_r]
    call ec_der_int
    lea rsi, [ec_s]
    call ec_der_int
    mov rax, rdi
    sub rax, rbx
    mov byte [rbx], 0x30
    lea ecx, [rax - 2]
    mov [rbx + 1], cl
    pop rbx
    ret

; ec_der_int(RDI = out, RSI = 4 limbs, not zero) -> RDI past it, as an
; INTEGER
ec_der_int:
    push rdi
    lea rdi, [ec_rnd + 1]
    mov ecx, 32
    call bn_store
    pop rdi
    mov byte [ec_rnd], 0
    lea rsi, [ec_rnd + 1]
.strip:
    cmp byte [rsi], 0
    jne .lead
    inc rsi
    dec ecx
    jmp .strip
.lead:
    test byte [rsi], 0x80               ; positive
    jz .copy
    dec rsi
    inc ecx
.copy:
    mov byte [rdi], 2
    mov [rdi + 1], cl
    add rdi, 2
    rep movsb
    ret

; ec_forget: the scratch that held secrets, wiped
ec_forget:
    push rax
    push rcx
    push rdi
    xor eax, eax
    lea rdi, [ec_wipe]
    mov ecx, ec_wipe_end - ec_wipe
    rep stosb
    lea rdi, [bn_t]
    mov ecx, (BN_LIMBS + 2) * 8
    rep stosb
    lea rdi, [bn_s]
    mov ecx, BN_LIMBS * 8
    rep stosb
    lea rdi, [bn_acc]
    mov ecx, BN_LIMBS * 8
    rep stosb
    pop rdi
    pop rcx
    pop rax
    ret

section .rodata
pk_digestinfo:  db 0x30, 0x31, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01
                db 0x65, 0x03, 0x04, 0x02, 0x01, 0x05, 0x00, 0x04, 0x20  ; SHA-256
                db 0x30, 0x41, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01
                db 0x65, 0x03, 0x04, 0x02, 0x02, 0x05, 0x00, 0x04, 0x30  ; SHA-384
                db 0x30, 0x51, 0x30, 0x0d, 0x06, 0x09, 0x60, 0x86, 0x48, 0x01
                db 0x65, 0x03, 0x04, 0x02, 0x03, 0x05, 0x00, 0x04, 0x40  ; SHA-512
align 8
ec_p256:        dq 32
                db 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00  ; p
                db 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff
                times 16 db 0
                db 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff  ; n
                db 0xbc, 0xe6, 0xfa, 0xad, 0xa7, 0x17, 0x9e, 0x84, 0xf3, 0xb9, 0xca, 0xc2, 0xfc, 0x63, 0x25, 0x51
                times 16 db 0
                db 0x5a, 0xc6, 0x35, 0xd8, 0xaa, 0x3a, 0x93, 0xe7, 0xb3, 0xeb, 0xbd, 0x55, 0x76, 0x98, 0x86, 0xbc  ; b
                db 0x65, 0x1d, 0x06, 0xb0, 0xcc, 0x53, 0xb0, 0xf6, 0x3b, 0xce, 0x3c, 0x3e, 0x27, 0xd2, 0x60, 0x4b
                times 16 db 0
                db 0x6b, 0x17, 0xd1, 0xf2, 0xe1, 0x2c, 0x42, 0x47, 0xf8, 0xbc, 0xe6, 0xe5, 0x63, 0xa4, 0x40, 0xf2  ; G
                db 0x77, 0x03, 0x7d, 0x81, 0x2d, 0xeb, 0x33, 0xa0, 0xf4, 0xa1, 0x39, 0x45, 0xd8, 0x98, 0xc2, 0x96
                times 16 db 0
                db 0x4f, 0xe3, 0x42, 0xe2, 0xfe, 0x1a, 0x7f, 0x9b, 0x8e, 0xe7, 0xeb, 0x4a, 0x7c, 0x0f, 0x9e, 0x16
                db 0x2b, 0xce, 0x33, 0x57, 0x6b, 0x31, 0x5e, 0xce, 0xcb, 0xb6, 0x40, 0x68, 0x37, 0xbf, 0x51, 0xf5
                times 16 db 0
ec_p384:        dq 48
                db 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff  ; p
                db 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xfe
                db 0xff, 0xff, 0xff, 0xff, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xff, 0xff, 0xff, 0xff
                db 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff  ; n
                db 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xc7, 0x63, 0x4d, 0x81, 0xf4, 0x37, 0x2d, 0xdf
                db 0x58, 0x1a, 0x0d, 0xb2, 0x48, 0xb0, 0xa7, 0x7a, 0xec, 0xec, 0x19, 0x6a, 0xcc, 0xc5, 0x29, 0x73
                db 0xb3, 0x31, 0x2f, 0xa7, 0xe2, 0x3e, 0xe7, 0xe4, 0x98, 0x8e, 0x05, 0x6b, 0xe3, 0xf8, 0x2d, 0x19  ; b
                db 0x18, 0x1d, 0x9c, 0x6e, 0xfe, 0x81, 0x41, 0x12, 0x03, 0x14, 0x08, 0x8f, 0x50, 0x13, 0x87, 0x5a
                db 0xc6, 0x56, 0x39, 0x8d, 0x8a, 0x2e, 0xd1, 0x9d, 0x2a, 0x85, 0xc8, 0xed, 0xd3, 0xec, 0x2a, 0xef
                db 0xaa, 0x87, 0xca, 0x22, 0xbe, 0x8b, 0x05, 0x37, 0x8e, 0xb1, 0xc7, 0x1e, 0xf3, 0x20, 0xad, 0x74  ; G
                db 0x6e, 0x1d, 0x3b, 0x62, 0x8b, 0xa7, 0x9b, 0x98, 0x59, 0xf7, 0x41, 0xe0, 0x82, 0x54, 0x2a, 0x38
                db 0x55, 0x02, 0xf2, 0x5d, 0xbf, 0x55, 0x29, 0x6c, 0x3a, 0x54, 0x5e, 0x38, 0x72, 0x76, 0x0a, 0xb7
                db 0x36, 0x17, 0xde, 0x4a, 0x96, 0x26, 0x2c, 0x6f, 0x5d, 0x9e, 0x98, 0xbf, 0x92, 0x92, 0xdc, 0x29
                db 0xf8, 0xf4, 0x1d, 0xbd, 0x28, 0x9a, 0x14, 0x7c, 0xe9, 0xda, 0x31, 0x13, 0xb5, 0xf0, 0xb8, 0xc0
                db 0x0a, 0x60, 0xb1, 0xce, 0x1d, 0x7e, 0x81, 0x9d, 0x7a, 0x43, 0x1d, 0x7c, 0x90, 0xea, 0x0e, 0x5f

section .bss
alignb 8
pk_key:         resq 1
pk_sig:         resq 1
pk_siglen:      resq 1
pk_e:           resq 1                  ; the exponent, as one limb
pk_halg:        resd 1
pk_hlen:        resd 1
pk_mask:        resb 1
alignb 8
pk_hash:        resb 64
pk_h2:          resb 64
pk_mgf:         resb 64 + 4
pk_mgf_out:     resb 64
pk_mp:          resb 8 + 64 + 64
alignb 8
pk_mc:          resb MONT_CTX
pk_a:           resq BN_LIMBS
pk_em:          resb BN_LIMBS * 8
pk_em2:         resb BN_LIMBS * 8
pk_db:          resb BN_LIMBS * 8
ec_size:        resq 1
ec_l:           resq 1
ec_rp:          resq 1
ec_rl:          resq 1
ec_sp:          resq 1
ec_sl:          resq 1
ec_p:           resb MONT_CTX
ec_n:           resb MONT_CTX
ec_wipe:                                ; (to ec_wipe_end: wiped after signing)
ec_r:           resq 8
ec_s:           resq 8
ec_e:           resq 8
ec_w:           resq 8
ec_x:           resq 8
ec_u1:          resq 8
ec_u2:          resq 8
ec_bm:          resq 8
ec_t1:          resq 8
ec_t2:          resq 8
ec_t3:          resq 8
ec_d:           resq 8
ec_g:           resq 8
ec_b:           resq 8
ec_a:           resq 8
ec_z1z1:        resq 8
ec_z2z2:        resq 8
ec_u1f:         resq 8
ec_u2f:         resq 8
ec_s1:          resq 8
ec_s2:          resq 8
ec_h:           resq 8
ec_rr:          resq 8
ec_h2:          resq 8
ec_h3:          resq 8
ec_v:           resq 8
ec_x3:          resq 8
ec_z3:          resq 8
ec_G:           resb PT
ec_Q:           resb PT
ec_GQ:          resb PT
ec_y:           resq 8
ec_priv:        resq 8                  ; d
ec_k:           resq 8                  ; the nonce
ec_kk:          resq 8                  ; a scalar, blinded (5 limbs)
ec_bl:          resq 8                  ; what the nonce's inverse is blinded by
ec_lam:         resq 8
ec_rnd:         resb 40
alignb 8
ec_L0:          resb PT                 ; the ladder's two points
ec_L1:          resb PT
ec_wipe_end:
ec_R:           resb PT
