; =============================================================================
;  tls.asm - TLS 1.3 (RFC 8446), a client and a server: any number of
;  connections, each a session of its own, over whatever carries its bytes
;  (http.asm and socket.asm put them on TCP). It speaks just
;  TLS_AES_128_GCM_SHA256 with an X25519 key share, which every TLS 1.3
;  peer must take, and has no resumption and no early data.
;
;  The server proves who it is: its certificate chain must lead to a
;  trusted root and name the host (x509.asm), and its CertificateVerify
;  must be its certificate's key's signature over the handshake
;  (pubkey.asm). tls_start can be told not to check the chain (http -k);
;  CertificateVerify is still checked then if the certificate can be read.
;
;  A session is TLS_SESSION bytes (about 100 KiB) the caller owns, any
;  alignment; TLS_USER in it is the caller's, kept from one connection to
;  the next. In every call RDI = the session:
;
;    tls_start(RSI = the server's name: sent as SNI unless it is an IPv4
;        address, and the certificate checked against it; or 0; RDX = send;
;        RCX = handlers; R8 = 1 not to check the certificate chain, else 0;
;        R9 = now, Unix seconds) -> CF if it could not begin (TLS_ERROR
;        says why); else the ClientHello is on its way
;    tls_accept(RSI = the identity; RDX = send; RCX = handlers; R9 = now)
;        -> CF if it could not begin; else the session is a server's,
;        waiting for the client's ClientHello. The identity (TID_*) is the
;        P-256 private key, then the certificates as TLS's Certificate
;        message lists them (each a 24-bit length, the DER, and 00 00 for
;        no extensions), the leaf first; TLS_CHAIN_MAX bytes at most. It
;        must stay while the session lasts. The client is not asked for a
;        certificate; CertificateVerify is ECDSA P-256 with SHA-256.
;    tls_input(RSI = bytes from the other side, RDX = how many)
;    tls_write(RSI = data, RDX = bytes) -> CF if not open, or not sent (then
;        the session is forgotten and TLS_ERROR says why)
;    tls_close    close_notify, if open; then forgotten
;    tls_abort    forgotten, nothing sent
;    tls_error_text(EAX = error; RDI = the session, or 0) -> RAX = what it
;        means
;
;  send(RDI = the session, RSI = bytes, EDX = how many) -> CF if it could
;  not take them all. The handlers, at TLO_*, each with RDI = the session:
;  READY (handshake done), DATA (RSI, EDX: plaintext, valid during the
;  call), CLOSED (the other side's close_notify), FAIL (EAX = error;
;  TLS_ALERT holds the other side's alert for TLE_ALERT, TLS_CERT_ERR the
;  X5E_* for
;  TLE_CERT; the session is already forgotten). At READY, TLS_VERIFIED says
;  whether the chain was checked, and then TLS_ANCHOR names the root and
;  TLS_DEPTH counts the intermediates. Send and the handlers may change
;  RAX, RCX, RDX, RSI, RDI and R8-R11, and may call tls_write, tls_close or
;  tls_abort, on this session or another. Every tls_* preserves all
;  registers but RAX. One thread at a time for all of them (the crypto
;  under them keeps scratch in .bss): the main loop.
; =============================================================================

TLO_READY       equ 0
TLO_DATA        equ 8
TLO_CLOSED      equ 16
TLO_FAIL        equ 24

; tls_state
TL_IDLE         equ 0
TL_WAIT_SH      equ 1                   ; ClientHello sent
TL_WAIT_EE      equ 2                   ; handshake keys in use from here on
TL_WAIT_CERT    equ 3
TL_WAIT_CV      equ 4
TL_WAIT_FIN     equ 5
TL_OPEN         equ 6                   ; application data both ways
TL_DONE         equ 7                   ; the server's close_notify came
TL_FAILED       equ 8                   ; to be reported at the end of tls_input

; tls_error
TLE_RNG         equ 1
TLE_PROTO       equ 2
TLE_VERSION     equ 3
TLE_CIPHER      equ 4
TLE_HRR         equ 5
TLE_MAC         equ 6
TLE_FINISHED    equ 7
TLE_ALERT       equ 8
TLE_TOOBIG      equ 9
TLE_CLIENTCERT  equ 10
TLE_SEND        equ 11
TLE_KEYSHARE    equ 12
TLE_OVERFLOW    equ 13
TLE_CERT        equ 14                  ; tls_cert_err says why
TLE_VERIFY      equ 15
TLE_SIGALG      equ 16
TLE_C_VERSION   equ 17                  ; a server's: what the client offers will not do
TLE_C_CIPHER    equ 18
TLE_C_SIGALG    equ 19
TLE_C_SHARE     equ 20
TLE_COUNT       equ 21

; the identity a server proves (tls_accept)
TID_KEY         equ 0                   ; the P-256 private key, 32 bytes, big-endian
TID_LEN         equ 32                  ; dword: bytes at TID_CHAIN
TID_CHAIN       equ 40
TLS_CHAIN_MAX   equ 16000

TL_REC_MAX      equ 16384 + 256         ; a record's body, encrypted
TL_PLAIN_MAX    equ 16384
TL_HMAX         equ 65536               ; one handshake message, at most

struc TS
alignb 8
S_tls_state:      resd 1
S_tls_error:      resd 1
S_tls_alert:      resd 1                  ; the server's, for TLE_ALERT
S_tls_certs:      resd 1                  ; certificates the server sent
S_tls_cert_bytes: resd 1
S_tls_sigalg:     resd 1                  ; what CertificateVerify used
S_tls_cert_err:   resd 1                  ; X5E_*, for TLE_CERT
S_tls_verified:   resd 1                  ; the chain was checked
S_tl_send:        resq 1
S_tl_ops:         resq 1
S_tl_now:         resq 1
S_tl_insecure:    resb 1
S_tl_server:      resb 1                  ; a server's session (tls_accept)
alignb 8
S_tl_id:          resq 1                  ; a server's identity
S_tl_user:        resq 1                  ; the caller's
S_tls_anchor:     resq 1                  ; the trusted root's name
S_tls_depth:      resd 1                  ; intermediates under it
alignb 16
S_tl_wipe_start:
; c_* is what this side sends with, s_* what it receives with: a client's
; own and the server's, a server's the other way round (tl_mine)
S_tl_c_gcm:       resb GCM_CTX
S_tl_s_gcm:       resb GCM_CTX
S_tl_hash:        resb SHA_CTX            ; the transcript
S_tl_hash2:       resb SHA_CTX
S_tl_priv:        resb 32
S_tl_pub:         resb 32
S_tl_peer:        resb 32
S_tl_shared:      resb 32
S_tl_random:      resb 32
S_tl_sessid:      resb 32                 ; (right after tl_random)
S_tl_secret:      resb 32                 ; early, handshake, then master
S_tl_c_secret:    resb 32                 ; the traffic secrets in use
S_tl_s_secret:    resb 32
S_tl_tmp:         resb 32
S_tl_th:          resb 32                 ; a transcript hash
S_tl_mac_buf:     resb 32
S_tl_key:         resb 16
S_tl_fkey:        resb 32                 ; a finished key
S_tl_c_iv:        resb 16
S_tl_s_iv:        resb 16
S_tl_nonce_buf:   resb 16
S_tl_c_seq:       resq 1
S_tl_s_seq:       resq 1
S_tl_msg:         resb 64
S_tl_sidlen:      resd 1                  ; a server's: the client's session id
S_tl_peer_hs:     resb 32                 ; a server's: the client's handshake secret
S_tl_have_key:    resb 1                  ; S_tl_skey is the server's
alignb 8
S_tl_skey:        resb KEY                ; its key, from x509.asm
S_tl_skeybuf:     resb 512                ; the key's bytes, where it points
alignb 8
S_tl_chain:       resq 2 * X5_MAX         ; certificates: where, how long
S_tl_cvbuf:       resb 64 + 34 + 32
S_tl_rlen:        resd 1
S_tl_hlen:        resd 1
S_tl_host:        resb 256
S_tl_rbuf:        resb 5 + TL_REC_MAX
S_tl_wbuf:        resb 5 + TL_PLAIN_MAX + 17 + 512
S_tl_hbuf:        resb TL_HMAX
S_tl_flight:      resb TLS_CHAIN_MAX + 384 ; a server's: EncryptedExtensions to Finished
S_tl_wipe_end:
endstruc

TLS_SESSION     equ TS_size
TLS_STATE       equ S_tls_state
TLS_ERROR       equ S_tls_error
TLS_ALERT       equ S_tls_alert
TLS_CERTS       equ S_tls_certs
TLS_CERT_BYTES  equ S_tls_cert_bytes
TLS_SIGALG      equ S_tls_sigalg
TLS_CERT_ERR    equ S_tls_cert_err
TLS_VERIFIED    equ S_tls_verified
TLS_HAVE_KEY    equ S_tl_have_key
TLS_USER        equ S_tl_user
TLS_ANCHOR      equ S_tls_anchor
TLS_DEPTH       equ S_tls_depth

section .text

%macro TL_SAVE 0
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

%macro TL_RESTORE 0
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

; -----------------------------------------------------------------------------
;  The interface
; -----------------------------------------------------------------------------

tls_start:
    TL_SAVE
    mov rbp, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call tl_begin
    mov [rbp + S_tl_insecure], r8b
    test r12, r12                       ; the name, for SNI
    jz .named
    lea rdi, [rbp + S_tl_host]
    xor ecx, ecx
.copy:
    mov al, [r12 + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .named
    inc ecx
    cmp ecx, 255
    jb .copy
    mov byte [rdi + rcx], 0
.named:
    lea rdi, [rbp + S_tl_priv]                  ; a fresh key pair, random, session id
    mov ecx, 32
    call rand_bytes
    jc .no_rng
    lea rdi, [rbp + S_tl_random]
    mov ecx, 64                         ; tl_sessid follows
    call rand_bytes
    jc .no_rng
    lea rdi, [rbp + S_tl_pub]
    lea rsi, [rbp + S_tl_priv]
    call x25519_base
    lea rdi, [rbp + S_tl_hash]
    call sha256_init
    mov dword [rbp + S_tls_state], TL_WAIT_SH
    call tl_client_hello
    jc .no_send
    clc
    jmp .out
.no_rng:
    mov eax, TLE_RNG
    jmp .fail
.no_send:
    mov eax, TLE_SEND
.fail:
    push rax
    call tl_wipe
    pop rax
    mov [rbp + S_tls_error], eax
    stc
.out:
    TL_RESTORE
    ret

tls_accept:
    TL_SAVE
    mov rbp, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    call tl_begin
    mov byte [rbp + S_tl_server], 1
    mov [rbp + S_tl_id], r12
    cmp dword [r12 + TID_LEN], TLS_CHAIN_MAX
    ja .big
    lea rdi, [rbp + S_tl_priv]          ; our key pair, and our random
    mov ecx, 32
    call rand_bytes
    jc .no_rng
    lea rdi, [rbp + S_tl_random]
    mov ecx, 32
    call rand_bytes
    jc .no_rng
    lea rdi, [rbp + S_tl_pub]
    lea rsi, [rbp + S_tl_priv]
    call x25519_base
    lea rdi, [rbp + S_tl_hash]
    call sha256_init
    mov dword [rbp + S_tls_state], TL_WAIT_SH   ; a server's: for the ClientHello
    clc
    jmp .out
.big:
    mov eax, TLE_TOOBIG
    jmp .fail
.no_rng:
    mov eax, TLE_RNG
.fail:
    push rax
    call tl_wipe
    pop rax
    mov [rbp + S_tls_error], eax
    stc
.out:
    TL_RESTORE
    ret

; tl_begin(R13 = send, R14 = handlers, R9 = now): a session wiped and begun,
; a client's
tl_begin:
    call tl_wipe
    mov [rbp + S_tl_send], r13
    mov [rbp + S_tl_ops], r14
    mov [rbp + S_tl_now], r9
    xor eax, eax
    mov [rbp + S_tl_insecure], al
    mov [rbp + S_tl_server], al
    mov [rbp + S_tl_id], rax
    mov [rbp + S_tls_anchor], rax
    mov [rbp + S_tls_depth], eax
    mov [rbp + S_tls_error], eax
    mov [rbp + S_tls_alert], eax
    mov [rbp + S_tls_certs], eax
    mov [rbp + S_tls_cert_bytes], eax
    mov [rbp + S_tls_sigalg], eax
    mov [rbp + S_tls_cert_err], eax
    mov [rbp + S_tls_verified], eax
    ret

tls_input:
    TL_SAVE
    mov rbp, rdi
    mov r12, rsi                        ; R12 = what is left, R13 = how much
    mov r13, rdx
.more:
    mov eax, [rbp + S_tls_state]
    cmp eax, TL_WAIT_SH
    jb .out
    cmp eax, TL_OPEN
    ja .done
    test r13, r13
    jz .out
    mov ecx, [rbp + S_tl_rlen]
    mov eax, 5                          ; the header first
    cmp ecx, 5
    jb .want
    movzx eax, word [rbp + S_tl_rbuf + 3]
    xchg al, ah
    add eax, 5
.want:
    sub eax, ecx
    cmp rax, r13
    cmova rax, r13
    lea rdi, [rbp + S_tl_rbuf]
    add rdi, rcx
    mov rsi, r12
    mov ecx, eax
    rep movsb
    mov r12, rsi
    sub r13, rax
    mov ebx, [rbp + S_tl_rlen]                  ; before
    add [rbp + S_tl_rlen], eax
    mov ecx, [rbp + S_tl_rlen]
    cmp ecx, 5
    jb .more
    cmp ebx, 5
    jae .whole
    call tl_check_header                ; it has just come
    jc .done
.whole:
    movzx eax, word [rbp + S_tl_rbuf + 3]
    xchg al, ah
    add eax, 5
    cmp [rbp + S_tl_rlen], eax
    jb .more
    mov dword [rbp + S_tl_rlen], 0
    call tl_record
    jmp .more
.done:
    cmp dword [rbp + S_tls_state], TL_FAILED    ; tell the handlers once
    jne .out
    mov dword [rbp + S_tls_state], TL_IDLE
    mov rax, [rbp + S_tl_ops]
    test rax, rax
    jz .out
    mov rcx, rax
    mov eax, [rbp + S_tls_error]
    mov rdi, rbp
    call [rcx + TLO_FAIL]
.out:
    TL_RESTORE
    ret

tls_write:
    TL_SAVE
    mov rbp, rdi
    cmp dword [rbp + S_tls_state], TL_OPEN
    jne .refuse
    mov r12, rsi
    mov r13, rdx
.record:
    test r13, r13
    jz .sent
    mov ecx, TL_PLAIN_MAX
    cmp r13, rcx
    cmovb ecx, r13d
    sub r13, rcx
    mov rsi, r12
    add r12, rcx
    mov al, 23
    call tl_seal_send
    jnc .record
    mov eax, TLE_SEND
    call tl_fail
    mov dword [rbp + S_tls_state], TL_IDLE      ; the caller hears it from CF
    stc
    jmp .out
.sent:
    clc
    jmp .out
.refuse:
    stc
.out:
    TL_RESTORE
    ret

tls_close:
    TL_SAVE
    mov rbp, rdi
    mov eax, [rbp + S_tls_state]
    cmp eax, TL_OPEN
    jb .forget
    cmp eax, TL_DONE
    ja .forget
    mov word [rbp + S_tl_msg], 0x0001           ; warning, close_notify
    lea rsi, [rbp + S_tl_msg]
    mov ecx, 2
    mov al, 21
    call tl_seal_send
.forget:
    call tl_wipe
    TL_RESTORE
    ret

tls_abort:
    TL_SAVE
    mov rbp, rdi
    call tl_wipe
    TL_RESTORE
    ret

tls_error_text:
    cmp eax, TLE_CERT
    jne .tls
    test rdi, rdi
    jz .tls
    mov eax, [rdi + S_tls_cert_err]
    jmp x509_error_text
.tls:
    cmp eax, TLE_COUNT
    jb .known
    xor eax, eax
.known:
    lea rcx, [tl_error_texts]
    test rdi, rdi
    jz .text
    cmp byte [rdi + S_tl_server], 0
    je .text
    lea rcx, [tl_error_texts_s]         ; a server's: the client did it
.text:
    mov rax, [rcx + rax * 8]
    ret

; -----------------------------------------------------------------------------
;  Inside. These keep RBX, RBP and R12-R15 and may change the rest; those
;  that can fail return CF, the failure already recorded (tl_fail).
; -----------------------------------------------------------------------------

; tl_wipe: every key and buffer cleared, the state idle (the handlers and
; the error stay)
tl_wipe:
    push rdi
    push rcx
    xor eax, eax
    lea rdi, [rbp + S_tl_wipe_start]
    mov ecx, S_tl_wipe_end - S_tl_wipe_start
    rep stosb
    mov dword [rbp + S_tls_state], TL_IDLE
    pop rcx
    pop rdi
    ret

; tl_fail(EAX = error) -> CF: an alert to the server if one fits, then all
; forgotten; tls_input tells the handlers
tl_fail:
    mov [rbp + S_tls_error], eax
    lea rcx, [tl_alert_for]
    movzx ecx, byte [rcx + rax]
    cmp eax, TLE_CERT                   ; the certificate's own reason
    jne .alert
    mov ecx, [rbp + S_tls_cert_err]
    lea rdx, [x5_alerts]
    movzx ecx, byte [rdx + rcx]
.alert:
    cmp ecx, 0xFF
    je .quiet
    mov eax, [rbp + S_tls_state]
    cmp eax, TL_WAIT_SH
    jb .quiet
    cmp eax, TL_DONE
    ja .quiet
    mov byte [rbp + S_tl_msg], 2                ; fatal
    mov [rbp + S_tl_msg + 1], cl
    cmp eax, TL_WAIT_SH
    jne .sealed
    mov dword [rbp + S_tl_wbuf], 0x00030315     ; 15 03 03 00: an alert in the clear
    mov word [rbp + S_tl_wbuf + 4], 0x0202      ; 02, then fatal (02)
    mov [rbp + S_tl_wbuf + 6], cl
    lea rsi, [rbp + S_tl_wbuf]
    mov ecx, 7
    call tl_send_raw
    jmp .quiet
.sealed:
    lea rsi, [rbp + S_tl_msg]
    mov ecx, 2
    mov al, 21
    call tl_seal_send
.quiet:
    call tl_wipe
    mov dword [rbp + S_tls_state], TL_FAILED
    stc
    ret

; tl_send_raw(RSI = bytes, ECX = how many) -> CF
tl_send_raw:
    mov edx, ecx
    mov rax, [rbp + S_tl_send]
    mov rdi, rbp
    call rax
    ret

; tl_seal_send(AL = content type, RSI = data, ECX = bytes up to 16384) -> CF:
; one record under the client's current key
tl_seal_send:
    push rbx
    mov ebx, ecx
    mov byte [rbp + S_tl_wbuf], 23              ; application_data, TLS 1.2 on the outside
    mov word [rbp + S_tl_wbuf + 1], 0x0303
    lea edx, [rbx + 17]
    xchg dl, dh
    mov [rbp + S_tl_wbuf + 3], dx
    lea rdi, [rbp + S_tl_wbuf + 5]
    rep movsb
    mov [rdi], al                       ; the real type, inside
    lea rsi, [rbp + S_tl_c_iv]
    mov rax, [rbp + S_tl_c_seq]
    inc qword [rbp + S_tl_c_seq]
    call tl_nonce
    lea rdi, [rbp + S_tl_c_gcm]
    lea rsi, [rbp + S_tl_nonce_buf]
    lea rdx, [rbp + S_tl_wbuf]
    mov ecx, 5
    lea r8, [rbp + S_tl_wbuf + 5]
    lea r9d, [rbx + 1]
    call gcm_seal
    lea rsi, [rbp + S_tl_wbuf]
    lea ecx, [rbx + 5 + 17]
    call tl_send_raw
    pop rbx
    ret

; tl_nonce(RSI = iv[12], RAX = sequence number): tl_nonce_buf = iv ^ seq
tl_nonce:
    mov ecx, [rsi + 8]
    mov rdx, [rsi]
    mov [rbp + S_tl_nonce_buf], rdx
    mov [rbp + S_tl_nonce_buf + 8], ecx
    bswap rax
    xor [rbp + S_tl_nonce_buf + 4], rax
    ret

; tl_check_header: the record header just in, sane? -> CF
tl_check_header:
    movzx eax, byte [rbp + S_tl_rbuf]
    sub eax, 20                         ; change_cipher_spec .. application_data
    cmp eax, 3
    ja .bad
    cmp byte [rbp + S_tl_rbuf + 1], 3
    jne .bad
    movzx eax, word [rbp + S_tl_rbuf + 3]
    xchg al, ah
    test eax, eax
    jz .bad
    cmp eax, TL_REC_MAX
    ja .big
    clc
    ret
.big:
    mov eax, TLE_OVERFLOW
    jmp tl_fail
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; tl_record: one whole record in tl_rbuf -> CF
tl_record:
    push rbx
    push r12
    movzx ebx, byte [rbp + S_tl_rbuf]
    movzx ecx, word [rbp + S_tl_rbuf + 3]
    xchg cl, ch
    lea rsi, [rbp + S_tl_rbuf + 5]
    cmp ebx, 20                         ; change_cipher_spec: ignored while
    jne .not_ccs                        ; the handshake lasts
    cmp dword [rbp + S_tls_state], TL_OPEN
    jae .bad
    cmp ecx, 1
    jne .bad
    cmp byte [rsi], 1
    jne .bad
    jmp .ok
.not_ccs:
    cmp ebx, 21                         ; an alert in the clear during the
    jne .clear                          ; handshake: the other side may not
    cmp dword [rbp + S_tls_state], TL_OPEN      ; have its keys yet
    jae .clear
    cmp ecx, 2
    je .alert
.clear:
    cmp dword [rbp + S_tls_state], TL_WAIT_SH
    jne .sealed
    cmp ecx, TL_PLAIN_MAX
    ja .big
    jmp .inner
.sealed:
    cmp ebx, 23
    jne .bad
    cmp ecx, 17
    jb .bad
    mov r12d, ecx
    lea rsi, [rbp + S_tl_s_iv]
    mov rax, [rbp + S_tl_s_seq]
    inc qword [rbp + S_tl_s_seq]
    call tl_nonce
    lea rdi, [rbp + S_tl_s_gcm]
    lea rsi, [rbp + S_tl_nonce_buf]
    lea rdx, [rbp + S_tl_rbuf]
    mov ecx, 5
    lea r8, [rbp + S_tl_rbuf + 5]
    lea r9d, [r12 - 16]
    call gcm_open
    jc .mac
    lea ecx, [r12 - 16]                 ; the type is the last byte not zero
    lea rdx, [rbp + S_tl_rbuf + 5]
.strip:
    dec ecx
    js .bad
    movzx ebx, byte [rdx + rcx]
    test ebx, ebx
    jz .strip
    cmp ecx, TL_PLAIN_MAX
    ja .big
    lea rsi, [rbp + S_tl_rbuf + 5]
.inner:                                 ; EBX = type, RSI, ECX = content
    cmp ebx, 22
    je .handshake
    cmp ebx, 21
    je .alert
    cmp ebx, 23
    jne .bad
    cmp dword [rbp + S_tls_state], TL_OPEN
    jne .bad
    test ecx, ecx
    jz .ok
    mov edx, ecx
    mov rax, [rbp + S_tl_ops]
    mov rdi, rbp
    call [rax + TLO_DATA]
.ok:
    clc
    jmp .out
.handshake:
    test ecx, ecx
    jz .bad
    call tl_handshake
    jmp .out
.alert:
    call tl_alert_in
    jmp .out
.mac:
    mov eax, TLE_MAC
    call tl_fail
    jmp .out
.big:
    mov eax, TLE_OVERFLOW
    call tl_fail
    jmp .out
.bad:
    mov eax, TLE_PROTO
    call tl_fail
.out:
    pop r12
    pop rbx
    ret

; tl_alert_in(RSI, ECX = the alert) -> CF
tl_alert_in:
    cmp ecx, 2
    jne .bad
    movzx eax, byte [rsi + 1]
    cmp eax, 90                         ; user_canceled: a close_notify follows
    je .ignore
    test eax, eax
    jnz .fatal
    cmp dword [rbp + S_tls_state], TL_OPEN      ; close_notify
    jne .fatal
    mov dword [rbp + S_tls_state], TL_DONE
    mov rax, [rbp + S_tl_ops]
    mov rdi, rbp
    call [rax + TLO_CLOSED]
.ignore:
    clc
    ret
.fatal:
    mov [rbp + S_tls_alert], eax
    mov dword [rbp + S_tls_state], TL_FAILED    ; (so tl_fail answers nothing)
    mov eax, TLE_ALERT
    jmp tl_fail
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; tl_handshake(RSI, ECX = handshake bytes) -> CF: gathered, then each whole
; message handled
tl_handshake:
    push rbx
    mov eax, [rbp + S_tl_hlen]
    lea edx, [rax + rcx]
    cmp edx, TL_HMAX
    ja .big
    lea rdi, [rbp + S_tl_hbuf]
    add rdi, rax
    rep movsb
    mov [rbp + S_tl_hlen], edx
.message:
    mov eax, [rbp + S_tls_state]                ; a handler may have closed it
    cmp eax, TL_WAIT_SH
    jb .done
    cmp eax, TL_OPEN
    ja .done
    mov ecx, [rbp + S_tl_hlen]
    cmp ecx, 4
    jb .done
    movzx eax, byte [rbp + S_tl_hbuf + 1]
    shl eax, 16
    movzx edx, word [rbp + S_tl_hbuf + 2]
    xchg dl, dh
    or eax, edx
    add eax, 4
    cmp eax, TL_HMAX
    ja .big
    cmp ecx, eax
    jb .done
    mov ebx, eax
    lea rsi, [rbp + S_tl_hbuf]
    mov ecx, ebx
    call tl_message
    jc .out
    mov eax, [rbp + S_tls_state]
    cmp eax, TL_WAIT_SH
    jb .done
    cmp eax, TL_OPEN
    ja .done
    lea rdi, [rbp + S_tl_hbuf]                  ; the rest moves down
    lea rsi, [rdi + rbx]
    mov ecx, [rbp + S_tl_hlen]
    sub ecx, ebx
    mov [rbp + S_tl_hlen], ecx
    rep movsb
    jmp .message
.done:
    clc
    jmp .out
.big:
    mov eax, TLE_TOOBIG
    call tl_fail
.out:
    pop rbx
    ret

; tl_transcript(RSI, ECX = a handshake message): into the running hash
tl_transcript:
    push rdi
    lea rdi, [rbp + S_tl_hash]
    mov edx, ecx
    call sha256_update
    pop rdi
    ret

; tl_hash_now: tl_th = the transcript's hash so far
tl_hash_now:
    push rsi
    push rdi
    push rcx
    lea rsi, [rbp + S_tl_hash]
    lea rdi, [rbp + S_tl_hash2]
    mov ecx, SHA_CTX
    rep movsb
    lea rdi, [rbp + S_tl_hash2]
    lea rsi, [rbp + S_tl_th]
    call sha256_final
    pop rcx
    pop rdi
    pop rsi
    ret

; tl_message(RSI = message, ECX = its bytes with the header) -> CF
tl_message:
    movzx eax, byte [rsi]
    cmp byte [rbp + S_tl_server], 0
    jne tl_server_message
    mov edx, [rbp + S_tls_state]
    cmp edx, TL_WAIT_SH
    je .sh
    cmp edx, TL_WAIT_EE
    je .ee
    cmp edx, TL_WAIT_CERT
    je .cert
    cmp edx, TL_WAIT_CV
    je .cv
    cmp edx, TL_WAIT_FIN
    je .fin
    cmp eax, 4                          ; open: tickets (not used) and key updates
    je .ok
    cmp eax, 24
    je tl_key_update
    jmp .bad
.sh:
    cmp eax, 2
    jne .bad
    jmp tl_server_hello
.ee:
    cmp eax, 8                          ; EncryptedExtensions: nothing we asked for
    jne .bad
    call tl_transcript
    mov dword [rbp + S_tls_state], TL_WAIT_CERT
    jmp .ok
.cert:
    cmp eax, 13
    je .client_cert
    cmp eax, 11
    jne .bad
    jmp tl_certificate
.cv:
    cmp eax, 15
    jne .bad
    jmp tl_cert_verify
.fin:
    cmp eax, 20
    jne .bad
    jmp tl_finished
.ok:
    clc
    ret
.client_cert:
    mov eax, TLE_CLIENTCERT
    jmp tl_fail
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; TL_NEED n: at least n bytes between R12 and R13, else .bad
%macro TL_NEED 1
    mov r10, r13
    sub r10, r12
    cmp r10, %1
    jb .bad
%endmacro

; tl_server_hello(RSI, ECX) -> CF
tl_server_hello:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi
    mov r15d, ecx
    cmp ecx, [rbp + S_tl_hlen]                  ; the keys change after it, so nothing
    jne .bad                            ; may follow it in the same record
    lea r12, [rsi + 4]
    lea r13, [rsi + rcx]
    TL_NEED 35
    lea rsi, [r12 + 2]                  ; HelloRetryRequest's special random?
    lea rdi, [tl_hrr_random]
    mov ecx, 32
    repe cmpsb
    je .retry
    add r12, 34
    movzx ecx, byte [r12]               ; our session id, echoed
    cmp ecx, 32
    jne .bad
    TL_NEED 33
    lea rsi, [r12 + 1]
    lea rdi, [rbp + S_tl_sessid]
    repe cmpsb
    jne .bad
    add r12, 33
    TL_NEED 5
    movzx ebx, word [r12]               ; the cipher suite, kept for later
    xchg bl, bh
    cmp byte [r12 + 2], 0
    jne .bad
    movzx eax, word [r12 + 3]
    xchg al, ah
    add r12, 5
    TL_NEED rax
    lea r13, [r12 + rax]
    xor r8d, r8d                        ; R8 = supported_versions said 1.3,
    xor r9d, r9d                        ; R9 = a key share came
.ext:
    cmp r12, r13
    jae .exts_done
    TL_NEED 4
    movzx ecx, word [r12]
    xchg cl, ch
    movzx edx, word [r12 + 2]
    xchg dl, dh
    add r12, 4
    TL_NEED rdx
    cmp ecx, 0x002b
    je .version
    cmp ecx, 0x0033
    je .share
.next_ext:
    add r12, rdx
    jmp .ext
.version:
    cmp edx, 2
    jne .bad
    cmp word [r12], 0x0403              ; 03 04
    jne .old
    mov r8d, 1
    jmp .next_ext
.share:
    cmp edx, 36
    jne .bad
    cmp dword [r12], 0x2000_1d00        ; 00 1d (X25519), 00 20
    jne .bad
    lea rsi, [r12 + 4]
    lea rdi, [rbp + S_tl_peer]
    mov ecx, 32
    rep movsb
    mov r9d, 1
    jmp .next_ext
.exts_done:
    test r8d, r8d
    jz .old
    cmp ebx, 0x1301
    jne .cipher
    test r9d, r9d
    jz .bad
    mov rsi, r14
    mov ecx, r15d
    call tl_transcript
    lea rdi, [rbp + S_tl_shared]                ; the shared secret
    lea rsi, [rbp + S_tl_priv]
    lea rdx, [rbp + S_tl_peer]
    call x25519
    xor eax, eax
    xor ecx, ecx
    lea rdx, [rbp + S_tl_shared]
.zero:
    or al, [rdx + rcx]
    inc ecx
    cmp ecx, 32
    jb .zero
    test al, al
    jz .weak
    call tl_handshake_keys
    mov dword [rbp + S_tls_state], TL_WAIT_EE
    clc
    jmp .out
.retry:
    mov eax, TLE_HRR
    jmp .fail
.old:
    mov eax, TLE_VERSION
    jmp .fail
.cipher:
    mov eax, TLE_CIPHER
    jmp .fail
.weak:
    mov eax, TLE_KEYSHARE
    jmp .fail
.bad:
    mov eax, TLE_PROTO
.fail:
    call tl_fail
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; EL out, secret, label, context (or 0), its bytes, out bytes
%macro EL 6
    lea rdi, [%1]
    lea rsi, [%2]
    lea rdx, [%3]
    %ifidn %4, 0
        xor ecx, ecx
    %else
        lea rcx, [%4]
    %endif
    mov r8d, %5
    mov r9d, %6
    call tls13_expand_label
%endmacro

; tl_handshake_keys: from the shared secret and the transcript so far, the
; handshake secrets and both directions' keys
tl_handshake_keys:
    lea rdi, [rbp + S_tl_secret]                ; early secret: no PSK
    xor esi, esi
    xor edx, edx
    lea rcx, [tl_zero32]
    mov r8d, 32
    call hkdf_extract
    EL rbp + S_tl_tmp, rbp + S_tl_secret, str_tl_derived, tl_empty_hash, 32, 32
    lea rdi, [rbp + S_tl_secret]                ; handshake secret
    lea rsi, [rbp + S_tl_tmp]
    mov edx, 32
    lea rcx, [rbp + S_tl_shared]
    mov r8d, 32
    call hkdf_extract
    call tl_hash_now
    EL rbp + S_tl_c_secret, rbp + S_tl_secret, str_tl_c_hs, rbp + S_tl_th, 32, 32
    EL rbp + S_tl_s_secret, rbp + S_tl_secret, str_tl_s_hs, rbp + S_tl_th, 32, 32
    call tl_mine
    jmp tl_both_keys

; tl_mine: on a server, the client's and the server's secrets swapped, so
; that tl_c_secret is the one this side sends with
tl_mine:
    cmp byte [rbp + S_tl_server], 0
    je .out
    push rcx
    push rdx
    xor ecx, ecx
.swap:
    mov rax, [rbp + S_tl_c_secret + rcx * 8]
    mov rdx, [rbp + S_tl_s_secret + rcx * 8]
    mov [rbp + S_tl_s_secret + rcx * 8], rax
    mov [rbp + S_tl_c_secret + rcx * 8], rdx
    inc ecx
    cmp ecx, 4
    jb .swap
    pop rdx
    pop rcx
.out:
    ret

; tl_both_keys: keys and IVs from tl_c_secret and tl_s_secret, counting anew
tl_both_keys:
    call tl_client_keys
    ; fall through

tl_server_keys:
    EL rbp + S_tl_key, rbp + S_tl_s_secret, str_tl_key, 0, 0, 16
    lea rdi, [rbp + S_tl_s_gcm]
    lea rsi, [rbp + S_tl_key]
    call gcm_init
    EL rbp + S_tl_s_iv, rbp + S_tl_s_secret, str_tl_iv, 0, 0, 12
    mov qword [rbp + S_tl_s_seq], 0
    ret

tl_client_keys:
    EL rbp + S_tl_key, rbp + S_tl_c_secret, str_tl_key, 0, 0, 16
    lea rdi, [rbp + S_tl_c_gcm]
    lea rsi, [rbp + S_tl_key]
    call gcm_init
    EL rbp + S_tl_c_iv, rbp + S_tl_c_secret, str_tl_iv, 0, 0, 12
    mov qword [rbp + S_tl_c_seq], 0
    ret

; tl_certificate(RSI, ECX) -> CF: the chain counted and checked (or, not
; to be checked, the server's own certificate read for its key)
tl_certificate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi
    mov r15d, ecx
    lea r12, [rsi + 4]
    lea r13, [rsi + rcx]
    TL_NEED 1                           ; the request context, empty here
    movzx eax, byte [r12]
    inc r12
    TL_NEED rax
    add r12, rax
    TL_NEED 3
    movzx eax, byte [r12]               ; the list
    shl eax, 16
    movzx ecx, word [r12 + 1]
    xchg cl, ch
    or eax, ecx
    add r12, 3
    TL_NEED rax
    lea r13, [r12 + rax]
    xor ebx, ebx
.entry:
    cmp r12, r13
    jae .counted
    TL_NEED 3
    movzx eax, byte [r12]
    shl eax, 16
    movzx ecx, word [r12 + 1]
    xchg cl, ch
    or eax, ecx
    test eax, eax
    jz .bad
    add r12, 3
    TL_NEED rax
    cmp ebx, X5_MAX                     ; the first few kept for x509.asm
    jae .kept
    mov ecx, ebx
    shl ecx, 4
    lea rdx, [rbp + S_tl_chain]
    mov [rdx + rcx], r12
    mov [rdx + rcx + 8], rax
.kept:
    add r12, rax
    add [rbp + S_tls_cert_bytes], eax
    inc ebx
    TL_NEED 2                           ; the entry's extensions
    movzx eax, word [r12]
    xchg al, ah
    add r12, 2
    TL_NEED rax
    add r12, rax
    jmp .entry
.counted:
    test ebx, ebx                       ; there must be one
    jz .bad
    mov [rbp + S_tls_certs], ebx
    cmp byte [rbp + S_tl_insecure], 0
    jne .unchecked
    lea rsi, [rbp + S_tl_chain]
    mov ecx, ebx
    cmp ecx, X5_MAX
    jbe .chain
    mov ecx, X5_MAX
.chain:
    lea rdx, [rbp + S_tl_host]
    mov r8, [rbp + S_tl_now]
    call x509_chain
    jc .refused
    mov dword [rbp + S_tls_verified], 1
    mov byte [rbp + S_tl_have_key], 1
    mov rax, [x509_anchor]
    mov [rbp + S_tls_anchor], rax
    mov eax, [x509_depth]
    mov [rbp + S_tls_depth], eax
    call tl_keep_key
    jmp .checked
.unchecked:
    mov rsi, [rbp + S_tl_chain]                 ; its key, if Axiom can read it
    mov ecx, [rbp + S_tl_chain + 8]
    call x509_leaf
    setnc byte [rbp + S_tl_have_key]
    call tl_keep_key
.checked:
    mov rsi, r14
    mov ecx, r15d
    call tl_transcript
    mov dword [rbp + S_tls_state], TL_WAIT_CV
    clc
    jmp .out
.refused:
    mov [rbp + S_tls_cert_err], eax
    mov eax, TLE_CERT
    call tl_fail
    jmp .out
.bad:
    mov eax, TLE_PROTO
    call tl_fail
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tl_keep_key: x509_key and the bytes it points to into the session, before
; another session's certificate can replace them
tl_keep_key:
    push rcx
    push rsi
    push rdi
    lea rsi, [x509_key]
    lea rdi, [rbp + S_tl_skey]
    mov ecx, KEY
    rep movsb
    mov rsi, [x509_key + K_PTR]
    lea rdi, [rbp + S_tl_skeybuf]
    mov [rbp + S_tl_skey + K_PTR], rdi
    mov ecx, [x509_key + K_LEN]
    cmp ecx, 512
    jbe .copy
    mov ecx, 512
.copy:
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; tl_cert_verify(RSI, ECX = CertificateVerify) -> CF: the server's signature
; over the handshake so far, with its certificate's key, in a scheme that
; suits that key (RFC 8446 4.4.3); not checked only if http -k was given
; and the certificate could not be read
tl_cert_verify:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov r13d, ecx
    cmp ecx, 8
    jb .bad
    movzx eax, word [rsi + 4]           ; the scheme, then the signature
    xchg al, ah
    mov [rbp + S_tls_sigalg], eax
    mov ebx, eax
    movzx edx, word [rsi + 6]
    xchg dl, dh
    lea eax, [rdx + 8]
    cmp eax, ecx
    jne .bad
    cmp byte [rbp + S_tl_have_key], 0
    je .noted
    mov eax, [rbp + S_tl_skey + K_TYPE]
    mov ecx, KT_P256
    cmp ebx, 0x0403
    je .suits
    mov ecx, KT_P384
    cmp ebx, 0x0503
    je .suits
    mov ecx, KT_RSA
    cmp ebx, 0x0804
    jb .sigalg
    cmp ebx, 0x0806
    ja .sigalg
.suits:
    cmp eax, ecx
    jne .sigalg
    call tl_hash_now
    lea rdi, [rbp + S_tl_cvbuf]                 ; 64 spaces, the context, 0, the hash
    mov ecx, 64
    mov al, ' '
    rep stosb
    lea rsi, [str_tl_cv]
    mov ecx, str_tl_cv_len              ; with its 0
    rep movsb
    lea rsi, [rbp + S_tl_th]
    mov ecx, 32
    rep movsb
    lea rdi, [rbp + S_tl_skey]
    mov esi, ebx
    lea rdx, [rbp + S_tl_cvbuf]
    mov ecx, 64 + str_tl_cv_len + 32
    lea r8, [r12 + 8]
    movzx r9d, word [r12 + 6]
    rol r9w, 8
    call sig_verify
    jc .wrong
.noted:
    mov rsi, r12
    mov ecx, r13d
    call tl_transcript
    mov dword [rbp + S_tls_state], TL_WAIT_FIN
    clc
    jmp .out
.sigalg:
    mov eax, TLE_SIGALG
    call tl_fail
    jmp .out
.wrong:
    mov eax, TLE_VERIFY
    call tl_fail
    jmp .out
.bad:
    mov eax, TLE_PROTO
    call tl_fail
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tl_mac(RSI = traffic secret): tl_mac_buf = HMAC(its finished key, tl_th)
tl_mac:
    lea rdi, [rbp + S_tl_fkey]
    lea rdx, [str_tl_finished]
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 32
    call tls13_expand_label
    lea rdi, [rbp + S_tl_mac_buf]
    lea rsi, [rbp + S_tl_fkey]
    mov edx, 32
    lea rcx, [rbp + S_tl_th]
    mov r8d, 32
    jmp hmac_sha256

; tl_finished(RSI, ECX) -> CF: the server's Finished checked; ours sent;
; the application keys in place; READY
tl_finished:
    push rbx
    push r12
    mov r12, rsi
    mov ebx, ecx
    cmp ecx, 4 + 32
    jne .bad
    call tl_hash_now
    lea rsi, [rbp + S_tl_s_secret]
    call tl_mac
    xor eax, eax                        ; compared in constant time
    xor ecx, ecx
    lea rsi, [rbp + S_tl_mac_buf]
.cmp:
    mov dl, [rsi + rcx]
    xor dl, [r12 + 4 + rcx]
    or al, dl
    inc ecx
    cmp ecx, 32
    jb .cmp
    test al, al
    jnz .wrong
    mov rsi, r12
    mov ecx, ebx
    call tl_transcript
    call tl_hash_now                    ; tl_th = up to the server's Finished
    lea rsi, [tl_ccs]                   ; middlebox compatibility (RFC 8446 D.4)
    mov ecx, 6
    call tl_send_raw
    jc .send
    lea rsi, [rbp + S_tl_c_secret]              ; our Finished
    call tl_mac
    mov dword [rbp + S_tl_msg], 0x20000014
    lea rsi, [rbp + S_tl_mac_buf]
    lea rdi, [rbp + S_tl_msg + 4]
    mov ecx, 32
    rep movsb
    lea rsi, [rbp + S_tl_msg]
    mov ecx, 36
    mov al, 22
    call tl_seal_send
    jc .send
    EL rbp + S_tl_tmp, rbp + S_tl_secret, str_tl_derived, tl_empty_hash, 32, 32
    lea rdi, [rbp + S_tl_secret]                ; the master secret
    lea rsi, [rbp + S_tl_tmp]
    mov edx, 32
    lea rcx, [tl_zero32]
    mov r8d, 32
    call hkdf_extract
    EL rbp + S_tl_c_secret, rbp + S_tl_secret, str_tl_c_ap, rbp + S_tl_th, 32, 32
    EL rbp + S_tl_s_secret, rbp + S_tl_secret, str_tl_s_ap, rbp + S_tl_th, 32, 32
    call tl_both_keys
    mov dword [rbp + S_tls_state], TL_OPEN
    mov rax, [rbp + S_tl_ops]
    mov rdi, rbp
    call [rax + TLO_READY]
    clc
    jmp .out
.wrong:
    mov eax, TLE_FINISHED
    call tl_fail
    jmp .out
.send:
    mov eax, TLE_SEND
    call tl_fail
    jmp .out
.bad:
    mov eax, TLE_PROTO
    call tl_fail
.out:
    pop r12
    pop rbx
    ret

; tl_key_update(RSI, ECX) -> CF: the server's key moves on; if it asks, so
; does ours, and it hears that first
tl_key_update:
    cmp ecx, 5
    jne .bad
    movzx eax, byte [rsi + 4]
    cmp eax, 1
    ja .bad
    push rax
    EL rbp + S_tl_tmp, rbp + S_tl_s_secret, str_tl_upd, 0, 0, 32
    lea rsi, [rbp + S_tl_tmp]
    lea rdi, [rbp + S_tl_s_secret]
    mov ecx, 32
    rep movsb
    call tl_server_keys
    pop rax
    test eax, eax
    jz .ok
    mov dword [rbp + S_tl_msg], 0x01000018      ; KeyUpdate(update_not_requested)
    mov byte [rbp + S_tl_msg + 4], 0
    lea rsi, [rbp + S_tl_msg]
    mov ecx, 5
    mov al, 22
    call tl_seal_send
    jc .send
    EL rbp + S_tl_tmp, rbp + S_tl_c_secret, str_tl_upd, 0, 0, 32
    lea rsi, [rbp + S_tl_tmp]
    lea rdi, [rbp + S_tl_c_secret]
    mov ecx, 32
    rep movsb
    call tl_client_keys
.ok:
    clc
    ret
.send:
    mov eax, TLE_SEND
    jmp tl_fail
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; tl_client_hello -> CF if it could not be sent
tl_client_hello:
    push rbx
    lea rdi, [rbp + S_tl_wbuf + 9]              ; after the record and message headers
    mov word [rdi], 0x0303
    add rdi, 2
    lea rsi, [rbp + S_tl_random]
    mov ecx, 32
    rep movsb
    mov byte [rdi], 32
    inc rdi
    lea rsi, [rbp + S_tl_sessid]
    mov ecx, 32
    rep movsb
    lea rsi, [tl_ch_suites]
    mov ecx, tl_ch_suites_len
    rep movsb
    mov rbx, rdi                        ; the extensions' length goes here
    add rdi, 2
    call tl_sni_len
    test ecx, ecx
    jz .no_sni
    mov word [rdi], 0                   ; server_name
    lea eax, [rcx + 5]
    xchg al, ah
    mov [rdi + 2], ax
    lea eax, [rcx + 3]
    xchg al, ah
    mov [rdi + 4], ax
    mov byte [rdi + 6], 0               ; host_name
    mov eax, ecx
    xchg al, ah
    mov [rdi + 7], ax
    add rdi, 9
    lea rsi, [rbp + S_tl_host]
    rep movsb
.no_sni:
    lea rsi, [tl_ch_exts]
    mov ecx, tl_ch_exts_len
    rep movsb
    lea rsi, [rbp + S_tl_pub]
    mov ecx, 32
    rep movsb
    mov rax, rdi
    sub rax, rbx
    sub eax, 2
    xchg al, ah
    mov [rbx], ax
    mov rbx, rdi                        ; the message's length
    lea rax, [rbp + S_tl_wbuf + 9]
    sub rbx, rax
    mov byte [rbp + S_tl_wbuf + 5], 1           ; ClientHello
    mov byte [rbp + S_tl_wbuf + 6], 0
    mov eax, ebx
    xchg al, ah
    mov [rbp + S_tl_wbuf + 7], ax
    mov dword [rbp + S_tl_wbuf], 0x00010316     ; 16 03 01: handshake, as TLS 1.0
    lea eax, [rbx + 4]
    xchg al, ah
    mov [rbp + S_tl_wbuf + 3], ax
    lea rsi, [rbp + S_tl_wbuf + 5]
    lea ecx, [rbx + 4]
    call tl_transcript
    lea rsi, [rbp + S_tl_wbuf]
    lea ecx, [rbx + 9]
    call tl_send_raw
    pop rbx
    ret

; tl_sni_len -> ECX = the name's length, or 0 for none or an IPv4 address
tl_sni_len:
    xor ecx, ecx
    xor edx, edx                        ; EDX = anything but digits and dots
    lea rsi, [rbp + S_tl_host]
    cmp byte [rsi], '['                 ; an IPv6 address: no name either
    je .out
.char:
    movzx eax, byte [rsi + rcx]
    test eax, eax
    jz .end
    inc ecx
    cmp eax, '.'
    je .char
    sub eax, '0'
    cmp eax, 9
    jbe .char
    inc edx
    jmp .char
.end:
    test edx, edx
    jnz .out
    xor ecx, ecx
.out:
    ret

; -----------------------------------------------------------------------------
;  The server's side. Its states: TL_WAIT_SH, waiting for the ClientHello
;  (in the clear); TL_WAIT_FIN, our flight sent, waiting for the client's
;  Finished; then TL_OPEN.
; -----------------------------------------------------------------------------

; tl_server_message(EAX = type, RSI, ECX = a whole handshake message) -> CF
tl_server_message:
    mov edx, [rbp + S_tls_state]
    cmp edx, TL_WAIT_SH
    je .hello
    cmp edx, TL_WAIT_FIN
    je .fin
    cmp edx, TL_OPEN
    jne .bad
    cmp eax, 24
    je tl_key_update
    jmp .bad
.hello:
    cmp eax, 1
    jne .bad
    jmp tl_client_hello_in
.fin:
    cmp eax, 20
    jne .bad
    jmp tl_client_finished
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; tl_client_hello_in(RSI, ECX = ClientHello) -> CF: what the client offers
; checked; our ServerHello and flight sent, the handshake keys in use
tl_client_hello_in:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi
    mov r15d, ecx
    cmp ecx, [rbp + S_tl_hlen]          ; the keys change after it, so nothing
    jne .bad                            ; may follow it in the same record
    lea r12, [rsi + 4]
    lea r13, [rsi + rcx]
    TL_NEED 35                          ; the version, the random, the id's length
    movzx ecx, byte [r12 + 34]
    cmp ecx, 32
    ja .bad
    add r12, 35
    TL_NEED rcx
    mov [rbp + S_tl_sidlen], ecx        ; the session id, to echo
    mov rsi, r12
    lea rdi, [rbp + S_tl_sessid]
    add r12, rcx
    rep movsb
    xor ebx, ebx                        ; EBX: 1 AES-128-GCM, 2 TLS 1.3, 4 an
    TL_NEED 2                           ; X25519 share, 8 ECDSA P-256
    movzx eax, word [r12]               ; the cipher suites
    xchg al, ah
    add r12, 2
    test eax, eax
    jz .bad
    test eax, 1
    jnz .bad
    TL_NEED rax
    lea rdx, [r12 + rax]
.suite:
    cmp word [r12], 0x0113              ; 13 01
    jne .next_suite
    or ebx, 1
.next_suite:
    add r12, 2
    cmp r12, rdx
    jb .suite
    TL_NEED 2                           ; compression: none, alone
    cmp word [r12], 0x0001              ; 01 00
    jne .bad
    add r12, 2
    cmp r12, r13                        ; no extensions: not TLS 1.3
    je .exts_done
    TL_NEED 2
    movzx eax, word [r12]
    xchg al, ah
    add r12, 2
    mov r10, r13
    sub r10, r12
    cmp rax, r10
    jne .bad
.ext:
    cmp r12, r13
    jae .exts_done
    TL_NEED 4
    movzx ecx, word [r12]
    xchg cl, ch
    movzx edx, word [r12 + 2]
    xchg dl, dh
    add r12, 4
    TL_NEED rdx
    lea r8, [r12 + rdx]                 ; R8 = its end
    cmp ecx, 0x002b
    je .versions
    cmp ecx, 0x0033
    je .shares
    cmp ecx, 0x000d
    je .sigalgs
.next_ext:
    mov r12, r8
    jmp .ext
.versions:                              ; a byte's length, then two each
    test edx, edx
    jz .bad
    movzx eax, byte [r12]
    inc eax
    cmp eax, edx
    jne .bad
    lea rsi, [r12 + 1]
.version:
    lea rax, [rsi + 2]
    cmp rax, r8
    ja .next_ext
    cmp word [rsi], 0x0403              ; 03 04
    jne .next_version
    or ebx, 2
.next_version:
    add rsi, 2
    jmp .version
.shares:                                ; a length, then group, length, key
    cmp edx, 2
    jb .bad
    movzx eax, word [r12]
    xchg al, ah
    add eax, 2
    cmp eax, edx
    jne .bad
    lea rsi, [r12 + 2]
.share:
    lea rax, [rsi + 4]
    cmp rax, r8
    ja .next_ext
    movzx ecx, word [rsi + 2]
    xchg cl, ch
    lea rax, [rsi + rcx + 4]
    cmp rax, r8
    ja .bad
    cmp word [rsi], 0x1d00              ; 00 1d: X25519
    jne .next_share
    cmp ecx, 32
    jne .bad
    push rsi
    add rsi, 4
    lea rdi, [rbp + S_tl_peer]
    mov ecx, 32
    rep movsb
    pop rsi
    or ebx, 4
.next_share:
    movzx ecx, word [rsi + 2]
    xchg cl, ch
    lea rsi, [rsi + rcx + 4]
    jmp .share
.sigalgs:
    cmp edx, 2
    jb .bad
    movzx eax, word [r12]
    xchg al, ah
    add eax, 2
    cmp eax, edx
    jne .bad
    lea rsi, [r12 + 2]
.sigalg:
    lea rax, [rsi + 2]
    cmp rax, r8
    ja .next_ext
    cmp word [rsi], 0x0304              ; 04 03
    jne .next_sigalg
    or ebx, 8
.next_sigalg:
    add rsi, 2
    jmp .sigalg
.exts_done:
    mov eax, TLE_C_VERSION
    test ebx, 2
    jz .fail
    mov eax, TLE_C_CIPHER
    test ebx, 1
    jz .fail
    mov eax, TLE_C_SIGALG
    test ebx, 8
    jz .fail
    mov eax, TLE_C_SHARE
    test ebx, 4
    jz .fail
    mov rsi, r14
    mov ecx, r15d
    call tl_transcript
    lea rdi, [rbp + S_tl_shared]        ; the shared secret
    lea rsi, [rbp + S_tl_priv]
    lea rdx, [rbp + S_tl_peer]
    call x25519
    xor eax, eax
    xor ecx, ecx
    lea rdx, [rbp + S_tl_shared]
.zero:
    or al, [rdx + rcx]
    inc ecx
    cmp ecx, 32
    jb .zero
    test al, al
    jz .weak
    call tl_server_hello_out
    jc .out
    call tl_handshake_keys
    call tl_flight
    jmp .out
.weak:
    mov eax, TLE_KEYSHARE
    jmp .fail
.bad:
    mov eax, TLE_PROTO
.fail:
    call tl_fail
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tl_server_hello_out -> CF: ServerHello in the clear, into the transcript;
; then a change_cipher_spec if the client is in middlebox compatibility
; mode (it sent a session id)
tl_server_hello_out:
    lea rdi, [rbp + S_tl_wbuf + 9]      ; after the record and message headers
    mov word [rdi], 0x0303
    add rdi, 2
    lea rsi, [rbp + S_tl_random]
    mov ecx, 32
    rep movsb
    mov ecx, [rbp + S_tl_sidlen]
    mov [rdi], cl
    inc rdi
    lea rsi, [rbp + S_tl_sessid]
    rep movsb
    lea rsi, [tl_sh_rest]
    mov ecx, tl_sh_rest_len
    rep movsb
    lea rsi, [rbp + S_tl_pub]
    mov ecx, 32
    rep movsb
    lea rcx, [rbp + S_tl_wbuf + 9]
    mov rax, rdi
    sub rax, rcx                        ; EAX = the message's body
    mov byte [rbp + S_tl_wbuf + 5], 2   ; ServerHello
    mov byte [rbp + S_tl_wbuf + 6], 0
    mov edx, eax
    xchg dl, dh
    mov [rbp + S_tl_wbuf + 7], dx
    mov dword [rbp + S_tl_wbuf], 0x00030316     ; 16 03 03: handshake
    lea edx, [rax + 4]
    xchg dl, dh
    mov [rbp + S_tl_wbuf + 3], dx
    push rax
    lea rsi, [rbp + S_tl_wbuf + 5]
    lea ecx, [rax + 4]
    call tl_transcript
    pop rax
    lea rsi, [rbp + S_tl_wbuf]
    lea ecx, [rax + 9]
    call tl_send_raw
    jc .send
    cmp dword [rbp + S_tl_sidlen], 0
    je .done
    lea rsi, [tl_ccs]
    mov ecx, 6
    call tl_send_raw
    jc .send
.done:
    clc
    ret
.send:
    mov eax, TLE_SEND
    jmp tl_fail

; tl_put24(RDI = where, EAX = a number below 2^24): big-endian, 3 bytes
tl_put24:
    mov [rdi + 2], al
    mov [rdi + 1], ah
    shr eax, 16
    mov [rdi], al
    ret

; tl_flight -> CF: EncryptedExtensions, Certificate, CertificateVerify and
; Finished, under our handshake key, each into the transcript; then the
; application secrets, ours in use, the client's kept for its Finished
tl_flight:
    push rbx
    push r12
    push r13
    lea rbx, [rbp + S_tl_flight]        ; RBX = where the next message goes
    mov dword [rbx], 0x02000008         ; EncryptedExtensions, with none
    mov word [rbx + 4], 0
    mov rsi, rbx
    mov ecx, 6
    call tl_transcript
    add rbx, 6
    mov r12, [rbp + S_tl_id]            ; Certificate: no context, the list
    mov r13d, [r12 + TID_LEN]
    mov byte [rbx], 11
    lea eax, [r13 + 4]
    lea rdi, [rbx + 1]
    call tl_put24
    mov byte [rbx + 4], 0
    mov eax, r13d
    lea rdi, [rbx + 5]
    call tl_put24
    lea rdi, [rbx + 8]
    lea rsi, [r12 + TID_CHAIN]
    mov ecx, r13d
    rep movsb
    mov rsi, rbx
    lea ecx, [r13 + 8]
    call tl_transcript
    lea rbx, [rbx + r13 + 8]
    call tl_hash_now                    ; CertificateVerify: 64 spaces, the
    lea rdi, [rbp + S_tl_cvbuf]         ; context, 0, the hash, signed
    mov ecx, 64
    mov al, ' '
    rep stosb
    lea rsi, [str_tl_cv]
    mov ecx, str_tl_cv_len
    rep movsb
    lea rsi, [rbp + S_tl_th]
    mov ecx, 32
    rep movsb
    lea rdi, [rbx + 8]
    lea rsi, [r12 + TID_KEY]
    lea rdx, [rbp + S_tl_cvbuf]
    mov ecx, 64 + str_tl_cv_len + 32
    call sig_sign
    jc .rng
    mov byte [rbx], 15
    mov byte [rbx + 1], 0
    lea ecx, [rax + 4]
    xchg cl, ch
    mov [rbx + 2], cx
    mov word [rbx + 4], 0x0304          ; 04 03: ECDSA P-256, SHA-256
    mov ecx, eax
    xchg cl, ch
    mov [rbx + 6], cx
    lea r13d, [rax + 8]
    mov rsi, rbx
    mov ecx, r13d
    call tl_transcript
    add rbx, r13
    call tl_hash_now                    ; Finished, with ours
    lea rsi, [rbp + S_tl_c_secret]
    call tl_mac
    mov dword [rbx], 0x20000014
    lea rsi, [rbp + S_tl_mac_buf]
    lea rdi, [rbx + 4]
    mov ecx, 32
    rep movsb
    mov rsi, rbx
    mov ecx, 36
    call tl_transcript
    add rbx, 36
    lea r12, [rbp + S_tl_flight]        ; sent, in records of 16 KiB at most
    sub rbx, r12
.record:
    mov ecx, TL_PLAIN_MAX
    cmp rbx, rcx
    cmovb ecx, ebx
    sub rbx, rcx
    mov rsi, r12
    add r12, rcx
    mov al, 22
    call tl_seal_send
    jc .send
    test rbx, rbx
    jnz .record
    call tl_hash_now                    ; tl_th = up to our Finished
    lea rsi, [rbp + S_tl_s_secret]      ; the client's handshake secret, for
    lea rdi, [rbp + S_tl_peer_hs]       ; its Finished
    mov ecx, 32
    rep movsb
    EL rbp + S_tl_tmp, rbp + S_tl_secret, str_tl_derived, tl_empty_hash, 32, 32
    lea rdi, [rbp + S_tl_secret]        ; the master secret
    lea rsi, [rbp + S_tl_tmp]
    mov edx, 32
    lea rcx, [tl_zero32]
    mov r8d, 32
    call hkdf_extract
    EL rbp + S_tl_c_secret, rbp + S_tl_secret, str_tl_c_ap, rbp + S_tl_th, 32, 32
    EL rbp + S_tl_s_secret, rbp + S_tl_secret, str_tl_s_ap, rbp + S_tl_th, 32, 32
    call tl_mine
    call tl_client_keys                 ; ours now; the client's once it has finished
    mov dword [rbp + S_tls_state], TL_WAIT_FIN
    clc
    jmp .out
.rng:
    mov eax, TLE_RNG
    call tl_fail
    jmp .out
.send:
    mov eax, TLE_SEND
    call tl_fail
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tl_client_finished(RSI, ECX) -> CF: the client's Finished checked; its
; application key in use; READY
tl_client_finished:
    push rbx
    push r12
    mov r12, rsi
    mov ebx, ecx
    cmp ecx, 4 + 32
    jne .bad
    call tl_hash_now
    lea rsi, [rbp + S_tl_peer_hs]
    call tl_mac
    xor eax, eax                        ; compared in constant time
    xor ecx, ecx
    lea rsi, [rbp + S_tl_mac_buf]
.cmp:
    mov dl, [rsi + rcx]
    xor dl, [r12 + 4 + rcx]
    or al, dl
    inc ecx
    cmp ecx, 32
    jb .cmp
    test al, al
    jnz .wrong
    mov rsi, r12
    mov ecx, ebx
    call tl_transcript
    call tl_server_keys                 ; what it sends with from here on
    mov dword [rbp + S_tls_state], TL_OPEN
    mov rax, [rbp + S_tl_ops]
    mov rdi, rbp
    call [rax + TLO_READY]
    clc
    jmp .out
.wrong:
    mov eax, TLE_FINISHED
    call tl_fail
    jmp .out
.bad:
    mov eax, TLE_PROTO
    call tl_fail
.out:
    pop r12
    pop rbx
    ret

section .rodata
tl_sh_rest:     db 0x13, 0x01, 0x00                ; AES-128-GCM, no compression
                db 0x00, 0x2e                      ; the extensions:
                db 0x00, 0x2b, 0x00, 0x02, 0x03, 0x04  ; TLS 1.3
                db 0x00, 0x33, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20  ; our X25519 share
tl_sh_rest_len equ $ - tl_sh_rest
tl_ch_suites:   db 0x00, 0x02, 0x13, 0x01  ; TLS_AES_128_GCM_SHA256
                db 0x01, 0x00              ; no compression
tl_ch_suites_len equ $ - tl_ch_suites
tl_ch_exts:     db 0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d  ; groups: x25519
                db 0x00, 0x0d, 0x00, 0x12, 0x00, 0x10              ; signature algorithms:
                db 0x04, 0x03, 0x05, 0x03                          ;  ECDSA P-256, P-384
                db 0x08, 0x04, 0x08, 0x05, 0x08, 0x06              ;  RSA-PSS
                db 0x04, 0x01, 0x05, 0x01, 0x06, 0x01              ;  RSA PKCS#1 (certificates)
                db 0x00, 0x2b, 0x00, 0x03, 0x02, 0x03, 0x04        ; versions: TLS 1.3
                db 0x00, 0x33, 0x00, 0x26, 0x00, 0x24, 0x00, 0x1d, 0x00, 0x20  ; key share
tl_ch_exts_len equ $ - tl_ch_exts
tl_hrr_random:  db 0xCF, 0x21, 0xAD, 0x74, 0xE5, 0x9A, 0x61, 0x11
                db 0xBE, 0x1D, 0x8C, 0x02, 0x1E, 0x65, 0xB8, 0x91
                db 0xC2, 0xA2, 0x11, 0x16, 0x7A, 0xBB, 0x8C, 0x5E
                db 0x07, 0x9E, 0x09, 0xE2, 0xC8, 0xA8, 0x33, 0x9C
tl_empty_hash:  db 0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14
                db 0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24
                db 0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c
                db 0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55
tl_zero32:      times 32 db 0
tl_ccs:         db 20, 3, 3, 0, 1, 1
str_tl_derived: db 'derived', 0
str_tl_c_hs:    db 'c hs traffic', 0
str_tl_s_hs:    db 's hs traffic', 0
str_tl_c_ap:    db 'c ap traffic', 0
str_tl_s_ap:    db 's ap traffic', 0
str_tl_key:     db 'key', 0
str_tl_iv:      db 'iv', 0
str_tl_finished: db 'finished', 0
str_tl_upd:     db 'traffic upd', 0
str_tl_cv:      db 'TLS 1.3, server CertificateVerify', 0
str_tl_cv_len   equ $ - str_tl_cv

; the alert we send for each error (0xFF: none)
tl_alert_for:   db 0xFF, 80, 10, 70, 40, 40, 20, 51, 0xFF, 80, 40, 0xFF, 47, 22, 42, 51, 47
                db 70, 40, 40, 40

str_tle_0:      db 'no error', 0
str_tle_rng:    db 'no hardware random numbers (RDSEED or RDRAND) for keys', 0
str_tle_proto:  db 'the server broke the TLS protocol', 0
str_tle_version: db 'the server does not speak TLS 1.3', 0
str_tle_cipher: db 'the server chose a cipher other than AES-128-GCM', 0
str_tle_hrr:    db 'the server wants a key exchange other than X25519', 0
str_tle_mac:    db 'a record failed its authentication', 0
str_tle_finished: db "the server's Finished does not match the handshake", 0
str_tle_alert:  db 'the server sent an alert', 0
str_tle_toobig: db 'a handshake message over 64 KiB', 0
str_tle_clientcert: db 'the server wants a client certificate', 0
str_tle_send:   db 'the connection would not take the bytes', 0
str_tle_keyshare: db "the server's key share is no good", 0
str_tle_overflow: db 'a record longer than TLS allows', 0
str_tle_cert:   db 'the certificate will not do', 0
str_tle_verify: db "the server's signature over the handshake is wrong (it does not hold its certificate's key)", 0
str_tle_sigalg: db 'the server signed the handshake in a way that does not suit its key', 0
str_tle_c_version: db 'the client does not speak TLS 1.3', 0
str_tle_c_cipher: db 'the client does not offer AES-128-GCM', 0
str_tle_c_sigalg: db 'the client does not take ECDSA P-256 signatures', 0
str_tle_c_share: db 'the client sends no X25519 key share', 0
str_tle_s_proto: db 'the client broke the TLS protocol', 0
str_tle_s_finished: db "the client's Finished does not match the handshake", 0
str_tle_s_alert: db 'the client sent an alert', 0
str_tle_s_keyshare: db "the client's key share is no good", 0
align 8
tl_error_texts: dq str_tle_0, str_tle_rng, str_tle_proto, str_tle_version
                dq str_tle_cipher, str_tle_hrr, str_tle_mac, str_tle_finished
                dq str_tle_alert, str_tle_toobig, str_tle_clientcert, str_tle_send
                dq str_tle_keyshare, str_tle_overflow, str_tle_cert, str_tle_verify
                dq str_tle_sigalg, str_tle_c_version, str_tle_c_cipher, str_tle_c_sigalg
                dq str_tle_c_share
tl_error_texts_s: dq str_tle_0, str_tle_rng, str_tle_s_proto, str_tle_version
                dq str_tle_cipher, str_tle_hrr, str_tle_mac, str_tle_s_finished
                dq str_tle_s_alert, str_tle_toobig, str_tle_clientcert, str_tle_send
                dq str_tle_s_keyshare, str_tle_overflow, str_tle_cert, str_tle_verify
                dq str_tle_sigalg, str_tle_c_version, str_tle_c_cipher, str_tle_c_sigalg
                dq str_tle_c_share
