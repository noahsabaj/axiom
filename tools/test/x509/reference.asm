; tools/test/x509/reference.asm - what of src/kernel/x509.asm moved to Rust
; (src/rust/src/x509.rs), as it was in assembly: x509_parse and what it
; calls, x509_unix and x5_name, with pubkey.asm's der_tlv and KEY, which they
; used. What tools/test/x509/run.py holds the Rust to, case for case.

K_TYPE          equ 0
K_LEN           equ 4                   ; bytes at K_PTR
K_E             equ 8                   ; RSA: the public exponent
K_PTR           equ 16
KEY             equ 24

KT_RSA          equ 1
KT_P256         equ 2
KT_P384         equ 3

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

section .bss
alignb 8
x5_host:        resq 1
x5_hlen:        resq 1
x5_alglen:      resq 1
x5_ip:          resd 1
