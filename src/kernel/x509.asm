; =============================================================================
;  x509.asm - certificates (RFC 5280): read from DER, and a server's chain
;  checked the way browsers do it, on pubkey.asm:
;
;    - each certificate is signed by the next one up, which must be a CA
;      (basicConstraints, keyCertSign if keyUsage is there, its pathLen
;      kept), until one is signed by a trusted root: Mozilla's list,
;      gen/roots.asm, made by tools/mkroots.py;
;    - every certificate on the way is within its dates, give or take a
;      day: the clock is the CMOS one, which Windows keeps in local time;
;    - the server's own certificate names the host (subjectAltName, DNS
;      names with a leading "*." wildcard, or IPv4 addresses; no falling
;      back to the common name), is for TLS servers if it says what it is
;      for (extendedKeyUsage, keyUsage), and has a key Axiom can check
;      CertificateVerify with;
;    - no critical extension Axiom does not understand. Revocation is not
;      checked.
;
;    x509_chain(RSI = list of (DER pointer, bytes) qword pairs, server's
;        first; ECX = how many; RDX = host name or IPv4 address, a C
;        string; R8 = now, Unix seconds) -> CF and EAX = X5E_* if the
;        chain will not do; else x509_key is the server's key (a copy),
;        x509_anchor the trusted root's name, x509_depth the number of
;        intermediate certificates used
;    x509_leaf(RSI = DER, ECX = bytes) -> CF and EAX = X5E_*; else
;        x509_key is its key (nothing checked)
;    x509_parse(RSI = DER, ECX = bytes, RDI = CERT) -> CF and EAX = X5E_*
;    x509_unix(EDI = year, ESI = month, EDX = day, ECX = hour, R8D =
;        minute, R9D = second) -> RAX = Unix seconds
;    x509_error_text(EAX = X5E_*) -> RAX
;
;  x509_extra may point to more trusted roots, in gen/roots.asm's format
;  (the host tests put their own CA there). Only the first X5_MAX
;  certificates of a chain are looked at. All preserve every general
;  register but RAX, and clobber XMM0-XMM10. Scratch in .bss: main loop
;  only; a chain's CERTs point into its DER, so they last as long as it.
; =============================================================================

X5_MAX          equ 8

; X5E_*: why a chain will not do
X5E_MALFORMED   equ 1
X5E_ALGORITHM   equ 2
X5E_KEY         equ 3
X5E_EXPIRED     equ 4
X5E_NOTYET      equ 5
X5E_NAME        equ 6
X5E_ISSUER      equ 7
X5E_SIGNATURE   equ 8
X5E_NOTCA       equ 9
X5E_PATHLEN     equ 10
X5E_PURPOSE     equ 11
X5E_CRITICAL    equ 12
X5E_CLOCK       equ 13
X5E_COUNT       equ 14

; a certificate, read
CT_ERR          equ 0                   ; X5E_*, 0 if it read well
CT_FLAGS        equ 4                   ; CTF_*
CT_TBS          equ 8                   ; what is signed, the whole TLV
CT_TBSLEN       equ 16
CT_SCHEME       equ 20                  ; its signature's, as pubkey.asm has it; 0 unknown
CT_SIG          equ 24
CT_SIGLEN       equ 32
CT_ISSLEN       equ 36
CT_ISS          equ 40                  ; issuer and subject: Name TLVs
CT_SUB          equ 48
CT_SUBLEN       equ 56
CT_PATHLEN      equ 60
CT_SAN          equ 64                  ; subjectAltName's GeneralNames, inside
CT_SANLEN       equ 72
CT_NB           equ 80                  ; notBefore, notAfter: Unix seconds
CT_NA           equ 88
CT_KEY          equ 96                  ; KEY; K_TYPE 0 if not one Axiom can use
CERT            equ 128

CTF_CA          equ 1
CTF_KU          equ 2                   ; keyUsage there
CTF_KU_SIGN     equ 4                   ;  digitalSignature
CTF_KU_CERT     equ 8                   ;  keyCertSign
CTF_EKU         equ 16                  ; extendedKeyUsage there
CTF_EKU_OK      equ 32                  ;  serverAuth or anyExtendedKeyUsage
CTF_SAN         equ 64
CTF_PATHLEN     equ 128

X5_SLACK        equ 86400               ; a day either way, for the clock
X5_CLOCK_MIN    equ 1735689600          ; 2025-01-01: before that, no clock

section .text

x509_chain:
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
    mov [x5_host], rdx
    mov [x5_now], r8
    mov qword [x509_anchor], 0
    mov dword [x509_depth], 0
    mov eax, X5E_MALFORMED
    test ecx, ecx
    jz .fail
    cmp ecx, X5_MAX
    jbe .count
    mov ecx, X5_MAX
.count:
    mov [x5_n], ecx
    mov eax, X5E_CLOCK
    mov r9, X5_CLOCK_MIN
    cmp r8, r9
    jb .fail
    mov r12, rsi
    xor ebp, ebp
.parse:                                 ; every one read; errors kept in CT_ERR
    cmp ebp, [x5_n]
    jae .parsed
    mov rax, rbp
    shl rax, 4
    mov rsi, [r12 + rax]
    mov rcx, [r12 + rax + 8]
    imul rdi, rbp, CERT
    lea rax, [x5_certs]
    add rdi, rax
    call x509_parse
    inc ebp
    jmp .parse
.parsed:
    lea rbx, [x5_certs]                 ; the server's own
    mov eax, [rbx + CT_ERR]
    test eax, eax
    jnz .fail
    mov eax, X5E_KEY
    cmp dword [rbx + CT_KEY + K_TYPE], 0
    je .fail
    call x5_dates
    jc .fail
    call x5_purpose
    jc .fail
    call x5_name
    jc .fail
    call x5_copy_key
    xor r12d, r12d                      ; R12 = the one whose signer we want
    mov r13d, 1                         ; R13 = those used, a bit each
    xor r14d, r14d                      ; R14 = intermediates so far
.step:
    imul rbx, r12, CERT
    lea rax, [x5_certs]
    add rbx, rax
    mov r15d, X5E_ALGORITHM             ; R15 = the best reason, if none is found
    cmp dword [rbx + CT_SCHEME], 0
    je .fail_best
    mov r15d, X5E_ISSUER
    call x5_try_roots
    jnc .trusted
    mov ebp, 1                          ; EBP = a candidate signer
.candidate:
    cmp ebp, [x5_n]
    jae .fail_best
    bt r13d, ebp
    jc .next
    imul rdi, rbp, CERT
    lea rax, [x5_certs]
    add rdi, rax
    mov ecx, [rdi + CT_SUBLEN]          ; its subject must be our issuer
    test ecx, ecx
    jz .next
    cmp ecx, [rbx + CT_ISSLEN]
    jne .next
    push rdi
    mov rsi, [rdi + CT_SUB]
    mov rdi, [rbx + CT_ISS]
    repe cmpsb
    pop rdi
    jne .next
    mov eax, [rdi + CT_ERR]
    test eax, eax
    jnz .reason
    mov eax, X5E_NOTCA
    mov ecx, [rdi + CT_FLAGS]
    test ecx, CTF_CA
    jz .reason
    test ecx, CTF_KU
    jz .ku_ok
    test ecx, CTF_KU_CERT
    jz .reason
.ku_ok:
    mov eax, X5E_PATHLEN
    test ecx, CTF_PATHLEN
    jz .length_ok
    cmp r14d, [rdi + CT_PATHLEN]
    ja .reason
.length_ok:
    push rbx
    mov rbx, rdi
    call x5_dates
    pop rbx
    jc .reason
    mov eax, X5E_KEY
    cmp dword [rdi + CT_KEY + K_TYPE], 0
    je .reason
    push rdi
    lea rdi, [rdi + CT_KEY]
    call x5_signed
    pop rdi
    mov eax, X5E_SIGNATURE
    jc .reason
    bts r13d, ebp                       ; up one
    mov r12d, ebp
    inc r14d
    jmp .step
.reason:
    mov r15d, eax
.next:
    inc ebp
    jmp .candidate
.trusted:
    mov [x509_depth], r14d
    xor eax, eax
    clc
    jmp .out
.fail_best:
    mov eax, r15d
.fail:
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

x509_leaf:
    push rbx
    push rdi
    lea rdi, [x5_certs]
    call x509_parse
    jc .out
    lea rbx, [x5_certs]
    mov eax, X5E_KEY
    cmp dword [rbx + CT_KEY + K_TYPE], 0
    stc
    je .out
    call x5_copy_key
    xor eax, eax
    clc
.out:
    pop rdi
    pop rbx
    ret

x509_error_text:
    cmp eax, X5E_COUNT
    jb .known
    xor eax, eax
.known:
    push rcx
    lea rcx, [x5_error_texts]
    mov rax, [rcx + rax * 8]
    pop rcx
    ret

x509_unix:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10d, edx                       ; R10 = day
    mov ebx, edi                        ; year, from March
    cmp esi, 2
    ja .march
    dec ebx
    add esi, 12
.march:
    sub esi, 3                          ; ESI = months since March
    mov eax, ebx
    xor edx, edx
    mov edi, 400
    div edi
    mov r8, rax                         ; R8 = era
    imul eax, eax, 400
    sub ebx, eax                        ; EBX = year of the era
    imul eax, esi, 153
    add eax, 2
    xor edx, edx
    mov edi, 5
    div edi
    lea r9, [rax + r10 - 1]             ; R9 = day of the year
    imul eax, ebx, 365
    add r9, rax
    mov eax, ebx
    shr eax, 2
    add r9, rax
    mov eax, ebx
    xor edx, edx
    mov edi, 100
    div edi
    sub r9, rax                         ; R9 = day of the era
    imul rax, r8, 146097
    add rax, r9
    sub rax, 719468                     ; days since 1970
    imul rax, rax, 86400
    mov ecx, [rsp + 6 * 8]              ; the hour, minute, second
    imul rcx, rcx, 3600
    add rax, rcx
    mov ecx, [rsp + 2 * 8]
    imul rcx, rcx, 60
    add rax, rcx
    mov ecx, [rsp + 1 * 8]
    add rax, rcx
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Reading one
; -----------------------------------------------------------------------------

x509_parse:
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
    mov rbp, rsp                        ; for leaving from inside
    mov rbx, rdi
    push rcx
    xor eax, eax
    mov ecx, CERT
    rep stosb
    pop rcx
    mov ecx, ecx
    lea r11, [rsi + rcx]
    call der_tlv                        ; Certificate ::= SEQUENCE {
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    cmp rsi, r11
    jne .malformed
    mov r14, r11                        ; R14 = its end
    mov rsi, rdx
    mov r12, rsi
    call der_tlv                        ;   tbsCertificate
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    mov [rbx + CT_TBS], r12
    mov rax, rsi
    sub rax, r12
    mov [rbx + CT_TBSLEN], eax
    mov r13, rsi                        ; R13 = after it
    mov rsi, rdx
    lea r11, [rdx + rcx]
    cmp rsi, r11
    jae .malformed
    cmp byte [rsi], 0xA0                ;   [0] version, any
    jne .serial
    call der_tlv
    jc .malformed
.serial:
    call der_tlv
    jc .malformed
    cmp eax, 2
    jne .malformed
    mov r15, rsi                        ;   signature: R15, x5_alglen
    call der_tlv
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    mov rax, rsi
    sub rax, r15
    mov [x5_alglen], rax
    call x5_sigalg
    mov [rbx + CT_SCHEME], eax
    mov r8, rsi                         ;   issuer
    call der_tlv
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    mov [rbx + CT_ISS], r8
    mov rax, rsi
    sub rax, r8
    mov [rbx + CT_ISSLEN], eax
    call der_tlv                        ;   validity
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call x5_time
    jc .malformed
    mov [rbx + CT_NB], rax
    call x5_time
    jc .malformed
    mov [rbx + CT_NA], rax
    cmp rsi, r11
    jne .malformed
    pop r11
    pop rsi
    mov r8, rsi                         ;   subject
    call der_tlv
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    mov [rbx + CT_SUB], r8
    mov rax, rsi
    sub rax, r8
    mov [rbx + CT_SUBLEN], eax
    call der_tlv                        ;   subjectPublicKeyInfo
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    call x5_spki
    jc .malformed
.optional:
    cmp rsi, r11
    jae .tbs_end
    movzx eax, byte [rsi]
    and eax, 0xDF
    cmp eax, 0x81                       ;   [1], [2] unique IDs
    je .skip
    cmp eax, 0x82
    je .skip
    cmp byte [rsi], 0xA3                ;   [3] extensions
    jne .malformed
    call der_tlv
    jc .malformed
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    cmp rsi, r11
    jne .malformed
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call x5_extensions
    jc .fail
    pop r11
    pop rsi
    jmp .optional
.skip:
    call der_tlv
    jc .malformed
    jmp .optional
.tbs_end:
    cmp rsi, r11
    jne .malformed
    mov rsi, r13                        ;   signatureAlgorithm, as in the TBS
    mov r11, r14
    mov r8, rsi
    call der_tlv
    jc .malformed
    cmp eax, 0x30
    jne .malformed
    mov rcx, rsi
    sub rcx, r8
    cmp rcx, [x5_alglen]
    jne .malformed
    push rsi
    mov rsi, r8
    mov rdi, r15
    repe cmpsb
    pop rsi
    jne .malformed
    call der_tlv                        ;   signatureValue }
    jc .malformed
    cmp eax, 3
    jne .malformed
    test ecx, ecx
    jz .malformed
    cmp byte [rdx], 0
    jne .malformed
    inc rdx
    dec ecx
    mov [rbx + CT_SIG], rdx
    mov [rbx + CT_SIGLEN], ecx
    cmp rsi, r11
    jne .malformed
    xor eax, eax
    clc
    jmp .out
.malformed:
    mov eax, X5E_MALFORMED
.fail:
    mov [rbx + CT_ERR], eax
    stc
.out:
    mov rsp, rbp
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

; x5_sigalg(RDX, RCX = an AlgorithmIdentifier's insides) -> EAX = scheme, 0
; if not one Axiom checks. Changes RAX and R10 only.
x5_sigalg:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .none
    cmp eax, 6
    jne .none
    mov r8, r11                         ; parameters: none, or NULL
    sub r8, rsi
    jz .params_ok
    cmp r8, 2
    jne .none
    cmp word [rsi], 0x0005
    jne .none
.params_ok:
    lea rsi, [x5_algs]
.entry:
    movzx eax, byte [rsi]
    test eax, eax
    jz .none
    cmp eax, ecx
    jne .skip
    push rsi
    push rcx
    lea rdi, [rsi + 1]
    mov rsi, rdx
    repe cmpsb
    pop rcx
    pop rsi
    jne .skip
    movzx eax, word [rsi + rcx + 1]
    jmp .out
.skip:
    movzx eax, byte [rsi]
    lea rsi, [rsi + rax + 3]
    jmp .entry
.none:
    xor eax, eax
.out:
    pop r11
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; x5_time(RSI, R11) -> RAX = a UTCTime or GeneralizedTime, Unix seconds;
; RSI past it; CF if not one. Changes RAX, RCX, RDX, RDI, R8-R10.
x5_time:
    call der_tlv
    jc .bad
    cmp eax, 0x17
    je .utc
    cmp eax, 0x18
    jne .bad
    cmp ecx, 15                         ; YYYYMMDDHHMMSSZ
    jne .bad
    call x5_digits
    jc .bad
    imul edi, eax, 100
    call x5_digits
    jc .bad
    add edi, eax
    jmp .rest
.utc:
    cmp ecx, 13                         ; YYMMDDHHMMSSZ, 1950-2049
    jne .bad
    call x5_digits
    jc .bad
    lea edi, [rax + 2000]
    cmp eax, 50
    jb .rest
    sub edi, 100
.rest:
    push rsi
    call x5_digits                      ; month
    jc .bad_pop
    mov esi, eax
    dec eax
    cmp eax, 11
    ja .bad_pop
    call x5_digits                      ; day
    jc .bad_pop
    mov r9d, eax
    dec eax
    cmp eax, 30
    ja .bad_pop
    call x5_digits                      ; hour
    jc .bad_pop
    mov ecx, eax
    cmp eax, 23
    ja .bad_pop
    call x5_digits                      ; minute
    jc .bad_pop
    mov r8d, eax
    cmp eax, 59
    ja .bad_pop
    call x5_digits                      ; second (a leap one as 59)
    jc .bad_pop
    cmp eax, 60
    ja .bad_pop
    cmp eax, 59
    jbe .second
    mov eax, 59
.second:
    cmp byte [rdx], 'Z'
    jne .bad_pop
    push rdx
    mov edx, r9d
    mov r9d, eax
    call x509_unix
    pop rdx
    pop rsi
    clc
    ret
.bad_pop:
    pop rsi
.bad:
    stc
    ret

; x5_digits(RDX) -> EAX = two decimal digits there; RDX past them; CF if not
x5_digits:
    movzx eax, byte [rdx]
    sub eax, '0'
    cmp eax, 9
    ja .bad
    imul eax, eax, 10
    movzx r10d, byte [rdx + 1]
    sub r10d, '0'
    cmp r10d, 9
    ja .bad
    add eax, r10d
    add rdx, 2
    clc
    ret
.bad:
    stc
    ret

; x5_spki(RDX, RCX = SubjectPublicKeyInfo's insides) -> CT_KEY (K_TYPE 0
; for a kind Axiom cannot use); CF if malformed. RBX = the CERT. Changes
; RAX, RCX, RDX, R8-R10.
x5_spki:
    push rsi
    push rdi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv                        ; AlgorithmIdentifier
    jc .bad
    cmp eax, 0x30
    jne .bad
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .bad_pop
    cmp eax, 6
    jne .bad_pop
    xor r8d, r8d                        ; R8D = the type
    lea rdi, [x5_oid_rsa]
    call x5_oid_is
    jne .ec
    mov r8d, KT_RSA
    jmp .alg_done
.ec:
    lea rdi, [x5_oid_ec]
    call x5_oid_is
    jne .alg_done
    call der_tlv                        ; the named curve
    jc .bad_pop
    cmp eax, 6
    jne .alg_done
    lea rdi, [x5_oid_p256]
    call x5_oid_is
    jne .not256
    mov r8d, KT_P256
    jmp .alg_done
.not256:
    lea rdi, [x5_oid_p384]
    call x5_oid_is
    jne .alg_done
    mov r8d, KT_P384
.alg_done:
    pop r11
    pop rsi
    call der_tlv                        ; subjectPublicKey BIT STRING
    jc .bad
    cmp eax, 3
    jne .bad
    test ecx, ecx
    jz .bad
    cmp byte [rdx], 0
    jne .bad
    inc rdx
    dec ecx
    cmp rsi, r11
    jne .bad
    cmp r8d, KT_RSA
    je .rsa
    test r8d, r8d
    jz .done
    mov eax, 65                         ; a point: 04, X, Y
    cmp r8d, KT_P256
    je .size
    mov eax, 97
.size:
    cmp ecx, eax
    jne .unusable
    cmp byte [rdx], 4
    jne .unusable
    mov [rbx + CT_KEY + K_LEN], ecx
    mov [rbx + CT_KEY + K_PTR], rdx
    mov [rbx + CT_KEY + K_TYPE], r8d
    jmp .done
.rsa:                                   ; RSAPublicKey ::= SEQUENCE { n, e }
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .bad
    cmp eax, 0x30
    jne .bad
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .bad
    cmp eax, 2
    jne .bad
    test ecx, ecx
    jz .bad
    test byte [rdx], 0x80
    jnz .unusable
.strip:
    cmp byte [rdx], 0
    jne .stripped
    inc rdx
    dec ecx
    jz .unusable
    jmp .strip
.stripped:
    cmp ecx, 256                        ; 2048 to 4096 bits, near enough
    jb .unusable
    cmp ecx, 512
    ja .unusable
    mov [rbx + CT_KEY + K_LEN], ecx
    mov [rbx + CT_KEY + K_PTR], rdx
    call der_tlv
    jc .bad
    cmp eax, 2
    jne .bad
    test ecx, ecx
    jz .bad
    cmp ecx, 8
    ja .unusable
    test byte [rdx], 0x80
    jnz .unusable
    xor eax, eax
.e:
    shl rax, 8
    mov al, [rdx]
    inc rdx
    dec ecx
    jnz .e
    mov [rbx + CT_KEY + K_E], rax
    cmp rsi, r11
    jne .bad
    mov dword [rbx + CT_KEY + K_TYPE], KT_RSA
    jmp .done
.unusable:
    mov dword [rbx + CT_KEY + K_TYPE], 0
.done:
    clc
    jmp .out
.bad_pop:
    pop r11
    pop rsi
.bad:
    stc
.out:
    pop r11
    pop rdi
    pop rsi
    ret

; x5_oid_is(RDX, RCX = an OID's bytes, RDI = length byte then bytes) -> ZF
x5_oid_is:
    push rcx
    push rsi
    push rdi
    movzx eax, byte [rdi]
    cmp eax, ecx
    jne .out
    inc rdi
    mov rsi, rdx
    repe cmpsb
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; x5_extensions(RSI, R11 = the Extensions' insides) -> CF and EAX; RBX =
; the CERT. Changes RAX, RCX, RDX, RSI, R8-R10, R12.
x5_extensions:
.next:
    cmp rsi, r11
    jae .done
    call der_tlv                        ; Extension ::= SEQUENCE {
    jc .bad
    cmp eax, 0x30
    jne .bad
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv                        ;   extnID
    jc .bad_pop
    cmp eax, 6
    jne .bad_pop
    mov r8, rdx
    mov r9, rcx
    xor r12d, r12d                      ;   critical BOOLEAN DEFAULT FALSE
    cmp rsi, r11
    jae .bad_pop
    cmp byte [rsi], 1
    jne .value
    call der_tlv
    jc .bad_pop
    cmp ecx, 1
    jne .bad_pop
    movzx r12d, byte [rdx]
.value:
    call der_tlv                        ;   extnValue OCTET STRING }
    jc .bad_pop
    cmp eax, 4
    jne .bad_pop
    cmp rsi, r11
    jne .bad_pop
    cmp r9, 3                           ; 2.5.29.x
    jne .unknown
    cmp word [r8], 0x1D55
    jne .unknown
    movzx eax, byte [r8 + 2]
    cmp eax, 15
    je .key_usage
    cmp eax, 17
    je .alt_names
    cmp eax, 19
    je .basic
    cmp eax, 37
    je .ext_key_usage
    cmp eax, 32                         ; certificatePolicies, policyConstraints,
    je .known                           ; inhibitAnyPolicy: no policies asked
    cmp eax, 36                         ; for, so nothing they could forbid
    je .known
    cmp eax, 54
    je .known
.unknown:
    test r12d, r12d
    jz .known
    pop r11
    pop rsi
    mov eax, X5E_CRITICAL
    stc
    ret
.key_usage:
    call x5_key_usage
    jmp .parsed
.alt_names:
    call x5_alt_names
    jmp .parsed
.basic:
    call x5_basic
    jmp .parsed
.ext_key_usage:
    call x5_ext_key_usage
.parsed:
    jc .bad_pop
.known:
    pop r11
    pop rsi
    jmp .next
.done:
    clc
    ret
.bad_pop:
    pop r11
    pop rsi
.bad:
    mov eax, X5E_MALFORMED
    stc
    ret

; The extensions' values: RDX, RCX = the OCTET STRING's insides, RBX = the
; CERT -> CF if malformed. Change RAX, RCX, RDX, R10.

x5_key_usage:                           ; BIT STRING
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .out
    cmp eax, 3
    jne .bad
    test ecx, ecx
    jz .bad
    or dword [rbx + CT_FLAGS], CTF_KU
    cmp ecx, 2
    jb .ok
    mov al, [rdx + 1]
    test al, 0x80                       ; digitalSignature (0)
    jz .cert
    or dword [rbx + CT_FLAGS], CTF_KU_SIGN
.cert:
    test al, 0x04                       ; keyCertSign (5)
    jz .ok
    or dword [rbx + CT_FLAGS], CTF_KU_CERT
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r11
    pop rsi
    ret

x5_alt_names:                           ; GeneralNames ::= SEQUENCE OF GeneralName
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .out
    cmp eax, 0x30
    jne .bad
    mov [rbx + CT_SAN], rdx
    mov [rbx + CT_SANLEN], ecx
    or dword [rbx + CT_FLAGS], CTF_SAN
    clc
    jmp .out
.bad:
    stc
.out:
    pop r11
    pop rsi
    ret

x5_basic:                               ; SEQUENCE { cA BOOLEAN, pathLen INTEGER }
    push rsi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .out
    cmp eax, 0x30
    jne .bad
    mov rsi, rdx
    lea r11, [rdx + rcx]
    cmp rsi, r11
    jae .ok
    cmp byte [rsi], 1
    jne .length
    call der_tlv
    jc .out
    cmp ecx, 1
    jne .bad
    cmp byte [rdx], 0
    je .length
    or dword [rbx + CT_FLAGS], CTF_CA
.length:
    cmp rsi, r11
    jae .ok
    call der_tlv
    jc .out
    cmp eax, 2
    jne .bad
    test ecx, ecx
    jz .bad
    cmp ecx, 4
    ja .bad
    test byte [rdx], 0x80
    jnz .bad
    xor eax, eax
.digit:
    shl eax, 8
    mov al, [rdx]
    inc rdx
    dec ecx
    jnz .digit
    mov [rbx + CT_PATHLEN], eax
    or dword [rbx + CT_FLAGS], CTF_PATHLEN
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r11
    pop rsi
    ret

x5_ext_key_usage:                       ; SEQUENCE OF KeyPurposeId
    push rsi
    push rdi
    push r11
    mov rsi, rdx
    lea r11, [rdx + rcx]
    call der_tlv
    jc .out
    cmp eax, 0x30
    jne .bad
    or dword [rbx + CT_FLAGS], CTF_EKU
    mov rsi, rdx
    lea r11, [rdx + rcx]
.purpose:
    cmp rsi, r11
    jae .ok
    call der_tlv
    jc .out
    cmp eax, 6
    jne .bad
    lea rdi, [x5_oid_server]
    call x5_oid_is
    je .server
    lea rdi, [x5_oid_any]
    call x5_oid_is
    jne .purpose
.server:
    or dword [rbx + CT_FLAGS], CTF_EKU_OK
    jmp .purpose
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r11
    pop rdi
    pop rsi
    ret

; -----------------------------------------------------------------------------
;  Checking. RBX = the CERT; CF and EAX = X5E_* if it fails.
; -----------------------------------------------------------------------------

x5_dates:
    push rcx
    mov rax, [x5_now]
    add rax, X5_SLACK
    cmp rax, [rbx + CT_NB]
    mov eax, X5E_NOTYET
    jb .bad
    mov rcx, [x5_now]
    sub rcx, X5_SLACK
    cmp rcx, [rbx + CT_NA]
    mov eax, X5E_EXPIRED
    ja .bad
    clc
    pop rcx
    ret
.bad:
    stc
    pop rcx
    ret

x5_purpose:
    push rcx
    mov ecx, [rbx + CT_FLAGS]
    mov eax, X5E_PURPOSE
    test ecx, CTF_EKU
    jz .usage
    test ecx, CTF_EKU_OK
    jz .bad
.usage:
    test ecx, CTF_KU
    jz .ok
    test ecx, CTF_KU_SIGN
    jz .bad
.ok:
    clc
    pop rcx
    ret
.bad:
    stc
    pop rcx
    ret

; x5_name: the host in the server's certificate's subjectAltName.
; Changes RCX, RDX, RSI, R8-R11.
x5_name:
    mov rsi, [x5_host]
    test rsi, rsi
    jz .bad
    xor ecx, ecx
.length:
    cmp byte [rsi + rcx], 0
    je .counted
    inc ecx
    cmp ecx, 255
    jb .length
    jmp .bad
.counted:
    test ecx, ecx                       ; "example.com." is example.com
    jz .bad
    cmp byte [rsi + rcx - 1], '.'
    jne .trimmed
    dec ecx
    jz .bad
.trimmed:
    mov [x5_hlen], rcx
    test dword [rbx + CT_FLAGS], CTF_SAN
    jz .bad
    call x5_ipv4
    setnc r8b                           ; R8B = an address, not a name
    mov rsi, [rbx + CT_SAN]
    mov r11d, [rbx + CT_SANLEN]
    add r11, rsi
.entry:
    cmp rsi, r11
    jae .bad
    call der_tlv
    jc .bad
    test r8b, r8b
    jz .dns
    cmp eax, 0x87                       ; [7] iPAddress
    jne .entry
    cmp ecx, 4
    jne .entry
    mov eax, [rdx]
    cmp eax, [x5_ip]
    je .ok
    jmp .entry
.dns:
    cmp eax, 0x82                       ; [2] dNSName
    jne .entry
    call x5_dns
    jc .entry
.ok:
    clc
    ret
.bad:
    mov eax, X5E_NAME
    stc
    ret

; x5_dns(RDX, RCX = a dNSName) -> CF unless it names x5_host. Changes RAX.
x5_dns:
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    mov rdi, [x5_host]
    mov r9, [x5_hlen]
    cmp rcx, 4                          ; "*.x.y" at least
    jb .plain
    cmp word [rdx], 0x2E2A              ; "*."
    jne .plain
    lea rsi, [rdx + 2]                  ; another dot: no "*.com"
    lea rax, [rcx - 2]
.dot:
    cmp byte [rsi], '.'
    je .wild
    inc rsi
    dec rax
    jnz .dot
    jmp .no
.wild:
    xor eax, eax                        ; the host's first label, one at least
.label:
    cmp rax, r9
    jae .no
    cmp byte [rdi + rax], '.'
    je .labelled
    inc rax
    jmp .label
.labelled:
    test rax, rax
    jz .no
    add rdi, rax                        ; its ".rest" against the pattern's
    sub r9, rax
    inc rdx
    dec rcx
.plain:
    cmp rcx, r9
    jne .no
.char:
    test rcx, rcx
    jz .yes
    movzx eax, byte [rdx]
    call x5_lower
    mov ah, al
    mov al, [rdi]
    call x5_lower
    cmp al, ah
    jne .no
    inc rdx
    inc rdi
    dec rcx
    jmp .char
.yes:
    clc
    jmp .out
.no:
    stc
.out:
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

x5_lower:
    cmp al, 'A'
    jb .out
    cmp al, 'Z'
    ja .out
    add al, 32
.out:
    ret

; x5_ipv4(x5_host, x5_hlen) -> CF unless it is a dotted IPv4 address, then
; in x5_ip. Changes RAX, RCX, RDX, RSI, R9, R10.
x5_ipv4:
    mov rsi, [x5_host]
    mov rcx, [x5_hlen]
    xor edx, edx                        ; EDX = the part's value
    xor r9d, r9d                        ; R9 = digits in it
    xor r10d, r10d                      ; R10 = parts done
.char:
    test rcx, rcx
    jz .end
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp eax, '.'
    je .part
    sub eax, '0'
    cmp eax, 9
    ja .no
    imul edx, edx, 10
    add edx, eax
    inc r9d
    cmp r9d, 3
    ja .no
    cmp edx, 255
    ja .no
    jmp .char
.part:
    test r9d, r9d
    jz .no
    cmp r10d, 3
    jae .no
    lea rax, [x5_ip]
    mov [rax + r10], dl
    inc r10d
    xor edx, edx
    xor r9d, r9d
    jmp .char
.end:
    test r9d, r9d
    jz .no
    cmp r10d, 3
    jne .no
    lea rax, [x5_ip]
    mov [rax + 3], dl
    clc
    ret
.no:
    stc
    ret

; x5_signed(RDI = KEY) -> CF unless it signed the CERT at RBX
x5_signed:
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    mov esi, [rbx + CT_SCHEME]
    mov rdx, [rbx + CT_TBS]
    mov ecx, [rbx + CT_TBSLEN]
    mov r8, [rbx + CT_SIG]
    mov r9d, [rbx + CT_SIGLEN]
    call sig_verify
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    ret

; x5_try_roots -> CF unless a trusted root signed the CERT at RBX (then
; x509_anchor); R15D = X5E_SIGNATURE if one by that name did not. Changes
; RAX, RCX, RDX, RSI, RDI.
x5_try_roots:
    lea rdi, [x5_ihash]
    mov rsi, [rbx + CT_ISS]
    mov edx, [rbx + CT_ISSLEN]
    call sha256
    lea rsi, [x509_roots]
    call .table
    jnc .out
    mov rsi, [x509_extra]
    test rsi, rsi
    stc
    jz .out
    call .table
.out:
    ret
.table:                                 ; RSI = roots, in gen/roots.asm's format
    movzx eax, word [rsi]
    test eax, eax
    jz .none
    lea rdi, [rsi + 16]
    push rsi
    lea rsi, [x5_ihash]
    mov ecx, 32
    repe cmpsb
    pop rsi
    jne .skip
    movzx eax, byte [rsi + 2]
    mov [x5_rkey + K_TYPE], eax
    movzx eax, word [rsi + 4]
    mov [x5_rkey + K_LEN], eax
    mov rax, [rsi + 8]
    mov [x5_rkey + K_E], rax
    lea rax, [rsi + 48]
    mov [x5_rkey + K_PTR], rax
    lea rdi, [x5_rkey]
    call x5_signed
    jc .wrong
    movzx eax, word [rsi + 4]
    lea rax, [rsi + 48 + rax]
    mov [x509_anchor], rax
    clc
    ret
.wrong:
    mov r15d, X5E_SIGNATURE
.skip:
    movzx eax, word [rsi]
    add rsi, rax
    jmp .table
.none:
    stc
    ret

; x5_copy_key: x509_key = the CERT at RBX's key, its bytes copied
x5_copy_key:
    push rcx
    push rsi
    push rdi
    lea rsi, [rbx + CT_KEY]
    lea rdi, [x509_key]
    mov ecx, KEY
    rep movsb
    mov rsi, [rbx + CT_KEY + K_PTR]
    lea rdi, [x5_keybuf]
    mov [x509_key + K_PTR], rdi
    mov ecx, [rbx + CT_KEY + K_LEN]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

section .rodata
; signature algorithms: the OID's bytes, then the scheme
x5_algs:        db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0B
                dw 0x0401                               ; sha256WithRSAEncryption
                db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0C
                dw 0x0501                               ; sha384WithRSAEncryption
                db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x0D
                dw 0x0601                               ; sha512WithRSAEncryption
                db 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x02
                dw 0x0403                               ; ecdsa-with-SHA256
                db 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x03
                dw 0x0503                               ; ecdsa-with-SHA384
                db 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x04, 0x03, 0x04
                dw 0x0603                               ; ecdsa-with-SHA512
                db 0
x5_oid_rsa:     db 9, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01  ; rsaEncryption
x5_oid_ec:      db 7, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01              ; id-ecPublicKey
x5_oid_p256:    db 8, 0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x03, 0x01, 0x07        ; prime256v1
x5_oid_p384:    db 5, 0x2B, 0x81, 0x04, 0x00, 0x22                          ; secp384r1
x5_oid_server:  db 8, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01        ; serverAuth
x5_oid_any:     db 4, 0x55, 0x1D, 0x25, 0x00                                ; anyExtendedKeyUsage

; the TLS alert for each X5E_*
x5_alerts:      db 42, 42, 43, 43, 45, 45, 42, 48, 42, 42, 42, 43, 43, 46

str_x5e_0:      db 'no error', 0
str_x5e_malformed: db "the server's certificate is malformed", 0
str_x5e_algorithm: db 'a certificate is signed with an algorithm Axiom does not check', 0
str_x5e_key:    db 'a certificate has a key Axiom cannot use (RSA under 2048 bits or over 4096, or a curve but P-256 and P-384)', 0
str_x5e_expired: db 'a certificate in the chain has expired', 0
str_x5e_notyet: db 'a certificate in the chain is not valid yet (is the clock right? date)', 0
str_x5e_name:   db 'the certificate is for another name', 0
str_x5e_issuer: db 'the chain does not lead to a trusted root', 0
str_x5e_signature: db "a certificate's signature is wrong", 0
str_x5e_notca:  db 'a certificate is signed by one that is not a CA', 0
str_x5e_pathlen: db 'the chain is longer than a CA in it allows', 0
str_x5e_purpose: db 'the certificate is not for TLS servers', 0
str_x5e_critical: db 'a certificate has a critical extension Axiom does not know', 0
str_x5e_clock:  db 'the clock says it is before 2025, so dates cannot be checked (date)', 0
align 8
x5_error_texts: dq str_x5e_0, str_x5e_malformed, str_x5e_algorithm, str_x5e_key
                dq str_x5e_expired, str_x5e_notyet, str_x5e_name, str_x5e_issuer
                dq str_x5e_signature, str_x5e_notca, str_x5e_pathlen, str_x5e_purpose
                dq str_x5e_critical, str_x5e_clock

%include "gen/roots.asm"

section .data
align 8
x509_extra:     dq 0                    ; more roots (the host tests)

section .bss
alignb 8
x509_key:       resb KEY                ; the server's key, from x509_chain or x509_leaf
x509_anchor:    resq 1                  ; the trusted root's name
x509_depth:     resd 1
x5_n:           resd 1
x5_host:        resq 1
x5_hlen:        resq 1
x5_now:         resq 1
x5_alglen:      resq 1
x5_ip:          resd 1
alignb 8
x5_rkey:        resb KEY
x5_ihash:       resb 32
x5_keybuf:      resb 512
x5_certs:       resb CERT * X5_MAX
