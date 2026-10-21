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
;  What reads what the server sent is in Rust (src/rust/src/x509.rs):
;  x509_parse, x509_unix and x5_name are its entry points here, as they
;  were. The chain is checked here, on pubkey.asm and sha256.asm.
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
    push rsi
    RUST_ENTER                          ; rs_x509_unix(year, month, day, hour,
    call rs_x509_unix                   ; minute, second): as they are
    RUST_LEAVE
    pop rsi
    ret

; -----------------------------------------------------------------------------
;  Reading one
; -----------------------------------------------------------------------------

x509_parse:
    push rsi
    RUST_ENTER
    mov edx, ecx                        ; rs_x509_parse(CERT, DER, bytes)
    call rs_x509_parse
    cmp rdx, 1                          ; CF: it will not do (EAX = X5E_*)
    RUST_LEAVE
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
    RUST_ENTER
    mov rdi, rbx                        ; rs_x509_name(CERT, host)
    mov rsi, [x5_host]
    call rs_x509_name
    cmp rax, 1                          ; CF: it does not name it
    mov eax, X5E_NAME
    RUST_LEAVE
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
x5_now:         resq 1
alignb 8
x5_rkey:        resb KEY
x5_ihash:       resb 32
x5_keybuf:      resb 512
x5_certs:       resb CERT * X5_MAX
