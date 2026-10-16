; =============================================================================
;  tls.asm - a TLS 1.3 client (RFC 8446), one connection at a time, over
;  whatever carries its bytes (http.asm puts it on TCP). It offers just
;  TLS_AES_128_GCM_SHA256 and an X25519 key share, which every TLS 1.3
;  server must take, and accepts no resumption and no early data.
;
;  The server's certificate chain is received and counted but NOT verified
;  yet: the connection is private and tamper-proof against anyone who is
;  not in the middle of it, but nothing proves the server is who it says.
;
;    tls_start(RDI = server name for SNI, or 0; RSI = send; RDX = handlers)
;        -> CF if it could not begin (tls_error says why); else the
;        ClientHello is on its way
;    tls_input(RSI = bytes from the server, RDX = how many)
;    tls_write(RSI = data, RDX = bytes) -> CF if not open, or not sent (then
;        the session is forgotten and tls_error says why)
;    tls_close    close_notify, if open; then forgotten
;    tls_abort    forgotten, nothing sent
;    tls_error_text(EAX = error) -> RAX = what it means
;
;  send(RSI = bytes, EDX = how many) -> CF if it could not take them all.
;  The handlers, at TLO_*: READY (handshake done), DATA (RSI, EDX:
;  plaintext, valid during the call), CLOSED (the server's close_notify),
;  FAIL (EAX = error; tls_alert holds the server's alert for TLE_ALERT;
;  the session is already forgotten). Send and the handlers may change RAX,
;  RCX, RDX, RSI, RDI and R8-R11, and may call tls_write, tls_close or
;  tls_abort. Every tls_* preserves all registers but RAX. Main loop only.
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
TLE_COUNT       equ 14

TL_REC_MAX      equ 16384 + 256         ; a record's body, encrypted
TL_PLAIN_MAX    equ 16384
TL_HMAX         equ 65536               ; one handshake message, at most

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
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call tl_wipe
    mov [tl_send], r13
    mov [tl_ops], r14
    xor eax, eax
    mov [tls_error], eax
    mov [tls_alert], eax
    mov [tls_certs], eax
    mov [tls_cert_bytes], eax
    mov [tls_sigalg], eax
    test r12, r12                       ; the name, for SNI
    jz .named
    lea rdi, [tl_host]
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
    lea rdi, [tl_priv]                  ; a fresh key pair, random, session id
    mov ecx, 32
    call rand_bytes
    jc .no_rng
    lea rdi, [tl_random]
    mov ecx, 64                         ; tl_sessid follows
    call rand_bytes
    jc .no_rng
    lea rdi, [tl_pub]
    lea rsi, [tl_priv]
    call x25519_base
    lea rdi, [tl_hash]
    call sha256_init
    mov dword [tls_state], TL_WAIT_SH
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
    mov [tls_error], eax
    stc
.out:
    TL_RESTORE
    ret

tls_input:
    TL_SAVE
    mov r12, rsi                        ; R12 = what is left, R13 = how much
    mov r13, rdx
.more:
    mov eax, [tls_state]
    cmp eax, TL_WAIT_SH
    jb .out
    cmp eax, TL_OPEN
    ja .done
    test r13, r13
    jz .out
    mov ecx, [tl_rlen]
    mov eax, 5                          ; the header first
    cmp ecx, 5
    jb .want
    movzx eax, word [tl_rbuf + 3]
    xchg al, ah
    add eax, 5
.want:
    sub eax, ecx
    cmp rax, r13
    cmova rax, r13
    lea rdi, [tl_rbuf]
    add rdi, rcx
    mov rsi, r12
    mov ecx, eax
    rep movsb
    mov r12, rsi
    sub r13, rax
    mov ebx, [tl_rlen]                  ; before
    add [tl_rlen], eax
    mov ecx, [tl_rlen]
    cmp ecx, 5
    jb .more
    cmp ebx, 5
    jae .whole
    call tl_check_header                ; it has just come
    jc .done
.whole:
    movzx eax, word [tl_rbuf + 3]
    xchg al, ah
    add eax, 5
    cmp [tl_rlen], eax
    jb .more
    mov dword [tl_rlen], 0
    call tl_record
    jmp .more
.done:
    cmp dword [tls_state], TL_FAILED    ; tell the handlers once
    jne .out
    mov dword [tls_state], TL_IDLE
    mov rax, [tl_ops]
    test rax, rax
    jz .out
    mov rcx, rax
    mov eax, [tls_error]
    call [rcx + TLO_FAIL]
.out:
    TL_RESTORE
    ret

tls_write:
    TL_SAVE
    cmp dword [tls_state], TL_OPEN
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
    mov dword [tls_state], TL_IDLE      ; the caller hears it from CF
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
    mov eax, [tls_state]
    cmp eax, TL_OPEN
    jb .forget
    cmp eax, TL_DONE
    ja .forget
    mov word [tl_msg], 0x0001           ; warning, close_notify
    lea rsi, [tl_msg]
    mov ecx, 2
    mov al, 21
    call tl_seal_send
.forget:
    call tl_wipe
    TL_RESTORE
    ret

tls_abort:
    TL_SAVE
    call tl_wipe
    TL_RESTORE
    ret

tls_error_text:
    cmp eax, TLE_COUNT
    jb .known
    xor eax, eax
.known:
    lea rcx, [tl_error_texts]
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
    lea rdi, [tl_wipe_start]
    lea rcx, [tl_wipe_end]
    sub rcx, rdi
    rep stosb
    mov dword [tls_state], TL_IDLE
    pop rcx
    pop rdi
    ret

; tl_fail(EAX = error) -> CF: an alert to the server if one fits, then all
; forgotten; tls_input tells the handlers
tl_fail:
    mov [tls_error], eax
    lea rcx, [tl_alert_for]
    movzx ecx, byte [rcx + rax]
    cmp ecx, 0xFF
    je .quiet
    mov eax, [tls_state]
    cmp eax, TL_WAIT_SH
    jb .quiet
    cmp eax, TL_DONE
    ja .quiet
    mov byte [tl_msg], 2                ; fatal
    mov [tl_msg + 1], cl
    cmp eax, TL_WAIT_SH
    jne .sealed
    mov dword [tl_wbuf], 0x00030315     ; 15 03 03 00: an alert in the clear
    mov word [tl_wbuf + 4], 0x0202      ; 02, then fatal (02)
    mov [tl_wbuf + 6], cl
    lea rsi, [tl_wbuf]
    mov ecx, 7
    call tl_send_raw
    jmp .quiet
.sealed:
    lea rsi, [tl_msg]
    mov ecx, 2
    mov al, 21
    call tl_seal_send
.quiet:
    call tl_wipe
    mov dword [tls_state], TL_FAILED
    stc
    ret

; tl_send_raw(RSI = bytes, ECX = how many) -> CF
tl_send_raw:
    mov edx, ecx
    mov rax, [tl_send]
    call rax
    ret

; tl_seal_send(AL = content type, RSI = data, ECX = bytes up to 16384) -> CF:
; one record under the client's current key
tl_seal_send:
    push rbx
    mov ebx, ecx
    mov byte [tl_wbuf], 23              ; application_data, TLS 1.2 on the outside
    mov word [tl_wbuf + 1], 0x0303
    lea edx, [rbx + 17]
    xchg dl, dh
    mov [tl_wbuf + 3], dx
    lea rdi, [tl_wbuf + 5]
    rep movsb
    mov [rdi], al                       ; the real type, inside
    lea rsi, [tl_c_iv]
    mov rax, [tl_c_seq]
    inc qword [tl_c_seq]
    call tl_nonce
    lea rdi, [tl_c_gcm]
    lea rsi, [tl_nonce_buf]
    lea rdx, [tl_wbuf]
    mov ecx, 5
    lea r8, [tl_wbuf + 5]
    lea r9d, [rbx + 1]
    call gcm_seal
    lea rsi, [tl_wbuf]
    lea ecx, [rbx + 5 + 17]
    call tl_send_raw
    pop rbx
    ret

; tl_nonce(RSI = iv[12], RAX = sequence number): tl_nonce_buf = iv ^ seq
tl_nonce:
    mov ecx, [rsi + 8]
    mov rdx, [rsi]
    mov [tl_nonce_buf], rdx
    mov [tl_nonce_buf + 8], ecx
    bswap rax
    xor [tl_nonce_buf + 4], rax
    ret

; tl_check_header: the record header just in, sane? -> CF
tl_check_header:
    movzx eax, byte [tl_rbuf]
    sub eax, 20                         ; change_cipher_spec .. application_data
    cmp eax, 3
    ja .bad
    cmp byte [tl_rbuf + 1], 3
    jne .bad
    movzx eax, word [tl_rbuf + 3]
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
    movzx ebx, byte [tl_rbuf]
    movzx ecx, word [tl_rbuf + 3]
    xchg cl, ch
    lea rsi, [tl_rbuf + 5]
    cmp ebx, 20                         ; change_cipher_spec: ignored while
    jne .not_ccs                        ; the handshake lasts
    cmp dword [tls_state], TL_OPEN
    jae .bad
    cmp ecx, 1
    jne .bad
    cmp byte [rsi], 1
    jne .bad
    jmp .ok
.not_ccs:
    cmp dword [tls_state], TL_WAIT_SH
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
    lea rsi, [tl_s_iv]
    mov rax, [tl_s_seq]
    inc qword [tl_s_seq]
    call tl_nonce
    lea rdi, [tl_s_gcm]
    lea rsi, [tl_nonce_buf]
    lea rdx, [tl_rbuf]
    mov ecx, 5
    lea r8, [tl_rbuf + 5]
    lea r9d, [r12 - 16]
    call gcm_open
    jc .mac
    lea ecx, [r12 - 16]                 ; the type is the last byte not zero
    lea rdx, [tl_rbuf + 5]
.strip:
    dec ecx
    js .bad
    movzx ebx, byte [rdx + rcx]
    test ebx, ebx
    jz .strip
    cmp ecx, TL_PLAIN_MAX
    ja .big
    lea rsi, [tl_rbuf + 5]
.inner:                                 ; EBX = type, RSI, ECX = content
    cmp ebx, 22
    je .handshake
    cmp ebx, 21
    je .alert
    cmp ebx, 23
    jne .bad
    cmp dword [tls_state], TL_OPEN
    jne .bad
    test ecx, ecx
    jz .ok
    mov edx, ecx
    mov rax, [tl_ops]
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
    cmp dword [tls_state], TL_OPEN      ; close_notify
    jne .fatal
    mov dword [tls_state], TL_DONE
    mov rax, [tl_ops]
    call [rax + TLO_CLOSED]
.ignore:
    clc
    ret
.fatal:
    mov [tls_alert], eax
    mov dword [tls_state], TL_FAILED    ; (so tl_fail answers nothing)
    mov eax, TLE_ALERT
    jmp tl_fail
.bad:
    mov eax, TLE_PROTO
    jmp tl_fail

; tl_handshake(RSI, ECX = handshake bytes) -> CF: gathered, then each whole
; message handled
tl_handshake:
    push rbx
    mov eax, [tl_hlen]
    lea edx, [rax + rcx]
    cmp edx, TL_HMAX
    ja .big
    lea rdi, [tl_hbuf]
    add rdi, rax
    rep movsb
    mov [tl_hlen], edx
.message:
    mov eax, [tls_state]                ; a handler may have closed it
    cmp eax, TL_WAIT_SH
    jb .done
    cmp eax, TL_OPEN
    ja .done
    mov ecx, [tl_hlen]
    cmp ecx, 4
    jb .done
    movzx eax, byte [tl_hbuf + 1]
    shl eax, 16
    movzx edx, word [tl_hbuf + 2]
    xchg dl, dh
    or eax, edx
    add eax, 4
    cmp eax, TL_HMAX
    ja .big
    cmp ecx, eax
    jb .done
    mov ebx, eax
    lea rsi, [tl_hbuf]
    mov ecx, ebx
    call tl_message
    jc .out
    mov eax, [tls_state]
    cmp eax, TL_WAIT_SH
    jb .done
    cmp eax, TL_OPEN
    ja .done
    lea rdi, [tl_hbuf]                  ; the rest moves down
    lea rsi, [rdi + rbx]
    mov ecx, [tl_hlen]
    sub ecx, ebx
    mov [tl_hlen], ecx
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
    lea rdi, [tl_hash]
    mov edx, ecx
    call sha256_update
    pop rdi
    ret

; tl_hash_now: tl_th = the transcript's hash so far
tl_hash_now:
    push rsi
    push rdi
    push rcx
    lea rsi, [tl_hash]
    lea rdi, [tl_hash2]
    mov ecx, SHA_CTX
    rep movsb
    lea rdi, [tl_hash2]
    lea rsi, [tl_th]
    call sha256_final
    pop rcx
    pop rdi
    pop rsi
    ret

; tl_message(RSI = message, ECX = its bytes with the header) -> CF
tl_message:
    movzx eax, byte [rsi]
    mov edx, [tls_state]
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
    mov dword [tls_state], TL_WAIT_CERT
    jmp .ok
.cert:
    cmp eax, 13
    je .client_cert
    cmp eax, 11
    jne .bad
    jmp tl_certificate
.cv:
    cmp eax, 15                         ; CertificateVerify: its algorithm noted
    jne .bad
    cmp ecx, 6
    jb .bad
    movzx eax, word [rsi + 4]
    xchg al, ah
    mov [tls_sigalg], eax
    call tl_transcript
    mov dword [tls_state], TL_WAIT_FIN
    jmp .ok
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
    cmp ecx, [tl_hlen]                  ; the keys change after it, so nothing
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
    lea rdi, [tl_sessid]
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
    lea rdi, [tl_peer]
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
    lea rdi, [tl_shared]                ; the shared secret
    lea rsi, [tl_priv]
    lea rdx, [tl_peer]
    call x25519
    xor eax, eax
    xor ecx, ecx
    lea rdx, [tl_shared]
.zero:
    or al, [rdx + rcx]
    inc ecx
    cmp ecx, 32
    jb .zero
    test al, al
    jz .weak
    call tl_handshake_keys
    mov dword [tls_state], TL_WAIT_EE
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
    lea rdi, [tl_secret]                ; early secret: no PSK
    xor esi, esi
    xor edx, edx
    lea rcx, [tl_zero32]
    mov r8d, 32
    call hkdf_extract
    EL tl_tmp, tl_secret, str_tl_derived, tl_empty_hash, 32, 32
    lea rdi, [tl_secret]                ; handshake secret
    lea rsi, [tl_tmp]
    mov edx, 32
    lea rcx, [tl_shared]
    mov r8d, 32
    call hkdf_extract
    call tl_hash_now
    EL tl_c_secret, tl_secret, str_tl_c_hs, tl_th, 32, 32
    EL tl_s_secret, tl_secret, str_tl_s_hs, tl_th, 32, 32
    jmp tl_both_keys

; tl_both_keys: keys and IVs from tl_c_secret and tl_s_secret, counting anew
tl_both_keys:
    call tl_client_keys
    ; fall through

tl_server_keys:
    EL tl_key, tl_s_secret, str_tl_key, 0, 0, 16
    lea rdi, [tl_s_gcm]
    lea rsi, [tl_key]
    call gcm_init
    EL tl_s_iv, tl_s_secret, str_tl_iv, 0, 0, 12
    mov qword [tl_s_seq], 0
    ret

tl_client_keys:
    EL tl_key, tl_c_secret, str_tl_key, 0, 0, 16
    lea rdi, [tl_c_gcm]
    lea rsi, [tl_key]
    call gcm_init
    EL tl_c_iv, tl_c_secret, str_tl_iv, 0, 0, 12
    mov qword [tl_c_seq], 0
    ret

; tl_certificate(RSI, ECX) -> CF: the chain counted (not verified)
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
    add r12, rax
    add [tls_cert_bytes], eax
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
    mov [tls_certs], ebx
    mov rsi, r14
    mov ecx, r15d
    call tl_transcript
    mov dword [tls_state], TL_WAIT_CV
    clc
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

; tl_mac(RSI = traffic secret): tl_mac_buf = HMAC(its finished key, tl_th)
tl_mac:
    lea rdi, [tl_fkey]
    lea rdx, [str_tl_finished]
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, 32
    call tls13_expand_label
    lea rdi, [tl_mac_buf]
    lea rsi, [tl_fkey]
    mov edx, 32
    lea rcx, [tl_th]
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
    lea rsi, [tl_s_secret]
    call tl_mac
    xor eax, eax                        ; compared in constant time
    xor ecx, ecx
    lea rsi, [tl_mac_buf]
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
    lea rsi, [tl_c_secret]              ; our Finished
    call tl_mac
    mov dword [tl_msg], 0x20000014
    lea rsi, [tl_mac_buf]
    lea rdi, [tl_msg + 4]
    mov ecx, 32
    rep movsb
    lea rsi, [tl_msg]
    mov ecx, 36
    mov al, 22
    call tl_seal_send
    jc .send
    EL tl_tmp, tl_secret, str_tl_derived, tl_empty_hash, 32, 32
    lea rdi, [tl_secret]                ; the master secret
    lea rsi, [tl_tmp]
    mov edx, 32
    lea rcx, [tl_zero32]
    mov r8d, 32
    call hkdf_extract
    EL tl_c_secret, tl_secret, str_tl_c_ap, tl_th, 32, 32
    EL tl_s_secret, tl_secret, str_tl_s_ap, tl_th, 32, 32
    call tl_both_keys
    mov dword [tls_state], TL_OPEN
    mov rax, [tl_ops]
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
    EL tl_tmp, tl_s_secret, str_tl_upd, 0, 0, 32
    lea rsi, [tl_tmp]
    lea rdi, [tl_s_secret]
    mov ecx, 32
    rep movsb
    call tl_server_keys
    pop rax
    test eax, eax
    jz .ok
    mov dword [tl_msg], 0x01000018      ; KeyUpdate(update_not_requested)
    mov byte [tl_msg + 4], 0
    lea rsi, [tl_msg]
    mov ecx, 5
    mov al, 22
    call tl_seal_send
    jc .send
    EL tl_tmp, tl_c_secret, str_tl_upd, 0, 0, 32
    lea rsi, [tl_tmp]
    lea rdi, [tl_c_secret]
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
    lea rdi, [tl_wbuf + 9]              ; after the record and message headers
    mov word [rdi], 0x0303
    add rdi, 2
    lea rsi, [tl_random]
    mov ecx, 32
    rep movsb
    mov byte [rdi], 32
    inc rdi
    lea rsi, [tl_sessid]
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
    lea rsi, [tl_host]
    rep movsb
.no_sni:
    lea rsi, [tl_ch_exts]
    mov ecx, tl_ch_exts_len
    rep movsb
    lea rsi, [tl_pub]
    mov ecx, 32
    rep movsb
    mov rax, rdi
    sub rax, rbx
    sub eax, 2
    xchg al, ah
    mov [rbx], ax
    mov rbx, rdi                        ; the message's length
    lea rax, [tl_wbuf + 9]
    sub rbx, rax
    mov byte [tl_wbuf + 5], 1           ; ClientHello
    mov byte [tl_wbuf + 6], 0
    mov eax, ebx
    xchg al, ah
    mov [tl_wbuf + 7], ax
    mov dword [tl_wbuf], 0x00010316     ; 16 03 01: handshake, as TLS 1.0
    lea eax, [rbx + 4]
    xchg al, ah
    mov [tl_wbuf + 3], ax
    lea rsi, [tl_wbuf + 5]
    lea ecx, [rbx + 4]
    call tl_transcript
    lea rsi, [tl_wbuf]
    lea ecx, [rbx + 9]
    call tl_send_raw
    pop rbx
    ret

; tl_sni_len -> ECX = the name's length, or 0 for none or an IPv4 address
tl_sni_len:
    xor ecx, ecx
    xor edx, edx                        ; EDX = anything but digits and dots
    lea rsi, [tl_host]
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

section .rodata
tl_ch_suites:   db 0x00, 0x02, 0x13, 0x01  ; TLS_AES_128_GCM_SHA256
                db 0x01, 0x00              ; no compression
tl_ch_suites_len equ $ - tl_ch_suites
tl_ch_exts:     db 0x00, 0x0a, 0x00, 0x04, 0x00, 0x02, 0x00, 0x1d  ; groups: x25519
                db 0x00, 0x0d, 0x00, 0x16, 0x00, 0x14              ; signature algorithms
                db 0x04, 0x03, 0x05, 0x03, 0x06, 0x03              ;  ECDSA P-256/384/521
                db 0x08, 0x04, 0x08, 0x05, 0x08, 0x06              ;  RSA-PSS
                db 0x04, 0x01, 0x05, 0x01, 0x06, 0x01              ;  RSA PKCS#1
                db 0x08, 0x07                                      ;  Ed25519
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

; the alert we send for each error (0xFF: none)
tl_alert_for:   db 0xFF, 80, 10, 70, 40, 40, 20, 51, 0xFF, 80, 40, 0xFF, 47, 22

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
align 8
tl_error_texts: dq str_tle_0, str_tle_rng, str_tle_proto, str_tle_version
                dq str_tle_cipher, str_tle_hrr, str_tle_mac, str_tle_finished
                dq str_tle_alert, str_tle_toobig, str_tle_clientcert, str_tle_send
                dq str_tle_keyshare, str_tle_overflow

section .bss
alignb 8
tls_state:      resd 1
tls_error:      resd 1
tls_alert:      resd 1                  ; the server's, for TLE_ALERT
tls_certs:      resd 1                  ; certificates the server sent
tls_cert_bytes: resd 1
tls_sigalg:     resd 1                  ; what CertificateVerify used
tl_send:        resq 1
tl_ops:         resq 1
alignb 16
tl_wipe_start:
tl_c_gcm:       resb GCM_CTX
tl_s_gcm:       resb GCM_CTX
tl_hash:        resb SHA_CTX            ; the transcript
tl_hash2:       resb SHA_CTX
tl_priv:        resb 32
tl_pub:         resb 32
tl_peer:        resb 32
tl_shared:      resb 32
tl_random:      resb 32
tl_sessid:      resb 32                 ; (right after tl_random)
tl_secret:      resb 32                 ; early, handshake, then master
tl_c_secret:    resb 32                 ; the traffic secrets in use
tl_s_secret:    resb 32
tl_tmp:         resb 32
tl_th:          resb 32                 ; a transcript hash
tl_mac_buf:     resb 32
tl_key:         resb 16
tl_fkey:        resb 32                 ; a finished key
tl_c_iv:        resb 16
tl_s_iv:        resb 16
tl_nonce_buf:   resb 16
tl_c_seq:       resq 1
tl_s_seq:       resq 1
tl_msg:         resb 64
tl_rlen:        resd 1
tl_hlen:        resd 1
tl_host:        resb 256
tl_rbuf:        resb 5 + TL_REC_MAX
tl_wbuf:        resb 5 + TL_PLAIN_MAX + 17 + 512
tl_hbuf:        resb TL_HMAX
tl_wipe_end:
