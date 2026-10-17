; =============================================================================
;  http.asm - HTTP/1.1, one request at a time over tcp.asm, or for https://
;  over tls.asm on top of it, for a client: 'http <url> [file]' here, which
;  GETs and keeps the answer in memory (1 MiB at most), then shows the
;  status line, a few headers and the start of the body, or saves the body
;  to a file on the current volume; or claude.asm. For https the server's
;  certificate must name the host and lead to a trusted root (tls.asm,
;  x509.asm), dates taken from the CMOS clock; 'http -k' fetches without
;  checking who the server is, as curl's -k does.
;
;  The answer is taken apart here: the status line and headers, then a body
;  of Content-Length bytes, in chunks, or up to the close, as the headers
;  say (none after 204 and 304; 1xx answers are passed over). When it is
;  whole and the server allows, the connection is kept (one, HTTP_IDLE_S
;  seconds at most), and the next request to the same server, the same way,
;  goes on it without a new handshake; if the server closes it just then,
;  before anything comes back, the request goes again on a new one.
;
;    http_fetch(RSI = URL, RDX = the client, ECX = HF_* flags) -> CF (said
;        why) if it could not begin; else the client hears how it goes
;    http_hangup    the client has what it wants: closed now (close_notify
;        first for https), and neither DONE nor LOST follows. Preserves all.
;    http_header(RSI = headers, RDI = a lowercase name and its colon) ->
;        RSI = its value; CF if there is none. Preserves others.
;
;  The client is a table of handlers, at HA_*: REQUEST (-> RSI = the
;  request, RDX = its bytes; http_host, http_port and http_path are set; no
;  "Connection: close" unless it means it), HEAD (EAX = the status, RSI =
;  the status line and headers, NUL-terminated, RDX = their bytes), DATA
;  (RSI = bytes of the body, EDX = how many), DONE (EAX = 0: the body is
;  whole; else the connection closed before its end) and LOST (it ended
;  early, already said why, or was stopped). They may change RAX, RCX, RDX,
;  RSI, RDI and R8-R11.
; =============================================================================

HTTP_MAX        equ 1024 * 1024
HTTP_HEAD       equ 8192                ; the status line and headers, at most
HTTP_IDLE_S     equ 30                  ; a connection kept, unused, at most
HTTP_LINES      equ 20                  ; of the body, shown
HTTP_LINE       equ 150                 ; characters of a line, shown

HA_REQUEST      equ 0
HA_HEAD         equ 8
HA_DATA         equ 16
HA_DONE         equ 24
HA_LOST         equ 32

HF_INSECURE     equ 1                   ; do not check the certificate chain
HF_QUIET        equ 2                   ; only warnings and failures are said

; where the answer is
HP_HEAD         equ 0
HP_BODY         equ 1
HP_DONE         equ 2

; how its body comes
HB_LENGTH       equ 0                   ; Content-Length bytes
HB_CHUNKED      equ 1
HB_CLOSE        equ 2                   ; up to the close

; and in the chunks
CK_SIZE         equ 0
CK_EXT          equ 1
CK_DATA         equ 2
CK_CRLF         equ 3
CK_TRAILER      equ 4

section .text

; http [-k] <url> [file]
cmd_http:
    push r12
    push r13
    cmp qword [http_app], 0             ; (not while one runs: the file is its)
    jne .busy
    mov rsi, [sh_args]
    xor r13d, r13d                      ; R13 = HF_*
    cmp word [rsi], '-k'
    jne .url
    mov al, [rsi + 2]
    test al, al
    jz .flag
    cmp al, ' '
    jne .url
.flag:
    mov r13d, HF_INSECURE
    call arg_split
    mov rsi, rdi
.url:
    cmp byte [rsi], 0
    je .usage
    call arg_split
    mov r12, rsi                        ; the URL
    mov rsi, rdi                        ; the file, if any
    call arg_split
    lea rdi, [http_file]
    xor ecx, ecx
.file:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .filed
    inc ecx
    cmp ecx, 255
    jb .file
    mov byte [rdi + rcx], 0
.filed:
    mov rsi, r12
    lea rdx, [http_get]
    mov ecx, r13d
    call http_fetch
    jc .out
    call shell_wait                     ; the prompt comes back with the answer
    jmp .out
.busy:
    KLOG "http: a fetch is under way (ctrl+C stops it)"
    jmp .out
.usage:
    KLOG "usage: http [-k] <[https://]host[:port][/path]> [file], e.g. http https://example.com (-k: do not check the certificate)"
.out:
    pop r13
    pop r12
    ret

http_fetch:
    push rcx
    push rdx
    push rsi
    cmp qword [http_app], 0
    jne .busy
    mov eax, ecx
    and al, HF_INSECURE
    mov [http_insecure], al
    and cl, HF_QUIET
    mov [http_quiet], cl
    xor eax, eax
    mov [http_len], rax
    mov [http_total], rax
    call http_url
    jc .not_url
    call net_ready
    jc .not_url
    mov [http_app], rdx
    call http_fresh
    call http_kept
    jnc .reuse
    lea rsi, [http_host]
    call ip_parse
    jc .name
    cmp byte [rsi], 0
    jne .name
    call http_connect
    jmp .started
.name:
    lea rsi, [http_host]
    mov edx, 2
    call dns_lookup                     ; then http_begin, or http_dns_failed
.started:
    jnc .out
    mov qword [http_app], 0
    jmp .out
.reuse:
    cmp byte [http_quiet], 0
    jne .send
    lea rdx, [http_host]
    lea rsi, [http_path]
    mov ecx, [http_port]
    KLOG "http: GET %s from %s (%I) port %u, on the connection kept open", rsi, rdx, qword [http_ip], rcx
.send:
    RDTSC64
    mov [http_t0], rax
    call http_send
    jnc .out                            ; (clear)
    mov rdi, [http_conn]                ; it would not go: a new connection
    mov qword [http_conn], 0
    call tcp_abort
    call http_tls_abort
    mov byte [http_reused], 0
    mov eax, [http_ip]
    call http_connect
    jmp .started
.not_url:
    mov al, [http_ktls]                 ; (a connection kept is still that)
    mov [http_tls], al
    stc
    jmp .out
.busy:
    KLOG "http: busy with another request (ctrl+C stops it)"
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; http_url(RSI = text) -> http_host, http_port, http_path; CF (said why) if
; it is not a URL Axiom can fetch. Preserves all but RAX.
http_url:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rsi
    mov byte [http_tls], 0
    mov dword [http_defport], 80
    lea rdi, [str_https]
    call http_prefix
    jc .plain
    mov byte [http_tls], 1
    mov dword [http_defport], 443
    jmp .scheme
.plain:
    lea rdi, [str_http]
    call http_prefix
.scheme:
    lea rdi, [http_host]
    xor ecx, ecx
.host:
    mov al, [rsi]
    test al, al
    jz .host_end
    cmp al, '/'
    je .host_end
    cmp al, ':'
    je .host_end
    cmp ecx, 253
    jae .bad
    mov [rdi + rcx], al
    inc ecx
    inc rsi
    jmp .host
.host_end:
    test ecx, ecx
    jz .bad
    mov byte [rdi + rcx], 0
    mov eax, [http_defport]
    mov [http_port], eax
    cmp byte [rsi], ':'
    jne .path
    inc rsi
    xor eax, eax
    xor ecx, ecx                        ; digits seen
.digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .port_end
    imul eax, eax, 10
    add eax, edx
    cmp eax, 65535
    ja .bad
    inc ecx
    inc rsi
    jmp .digit
.port_end:
    test ecx, ecx
    jz .bad
    test eax, eax
    jz .bad
    mov [http_port], eax
    cmp byte [rsi], 0
    je .path
    cmp byte [rsi], '/'
    jne .bad
.path:
    lea rdi, [http_path]
    xor ecx, ecx
    cmp byte [rsi], '/'
    je .copy
    mov byte [rdi], '/'
    inc ecx
.copy:
    mov al, [rsi]
    mov [rdi + rcx], al
    test al, al
    jz .done
    inc rsi
    inc ecx
    cmp ecx, 500
    jb .copy
    jmp .bad
.done:
    clc
    jmp .out
.bad:
    KLOG "http: '%s' is not a URL Axiom can fetch", r8
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; http_prefix(RSI = text, RDI = a lowercase prefix) -> CF if the text does
; not start with it (in any case); else RSI just past it. Preserves others.
http_prefix:
    push rax
    push rcx
    xor ecx, ecx
.next:
    mov al, [rdi + rcx]
    test al, al
    jz .match
    mov ah, [rsi + rcx]
    cmp ah, 'A'
    jb .cmp
    cmp ah, 'Z'
    ja .cmp
    or ah, 0x20
.cmp:
    cmp al, ah
    jne .no
    inc ecx
    jmp .next
.match:
    add rsi, rcx
    clc
    jmp .out
.no:
    stc
.out:
    pop rcx
    pop rax
    ret

http_header:
    push rdx
    mov rdx, rsi
.line:
    mov al, [rsi]                       ; past the line before
    test al, al
    jz .none
    inc rsi
    cmp al, 10
    jne .line
    call http_prefix
    jc .line
.space:
    cmp byte [rsi], ' '
    je .skip
    cmp byte [rsi], 9
    jne .found
.skip:
    inc rsi
    jmp .space
.found:
    pop rdx
    clc
    ret
.none:
    mov rsi, rdx
    pop rdx
    stc
    ret

; http_line_has(RSI = in a line, RDI = lowercase text) -> CF unless the text
; is in the rest of the line, in any case. Preserves all.
http_line_has:
    push rsi
.at:
    mov al, [rsi]
    test al, al
    jz .no
    cmp al, 10
    je .no
    call http_prefix
    jnc .yes
    inc rsi
    jmp .at
.yes:
    pop rsi
    clc
    ret
.no:
    pop rsi
    stc
    ret

; http_fresh: an answer to come. Preserves all.
http_fresh:
    mov byte [http_phase], HP_HEAD
    mov byte [http_mode], HB_CLOSE
    mov byte [http_ck], CK_SIZE
    mov byte [http_keep], 0
    mov byte [http_reused], 0
    mov qword [http_hdlen], 0
    mov qword [http_rx], 0
    mov qword [http_left], 0
    mov dword [http_trail], 0
    mov dword [http_status], 0
    ret

; http_kept -> CF unless the connection kept from before goes to the same
; server, the same way, and has not been kept too long: then it is this
; request's. One that does not fit is closed. Preserves all but RAX.
http_kept:
    cmp byte [http_idle], 0
    je .none
    push rsi
    push rdi
    mov al, [http_tls]
    cmp al, [http_ktls]
    jne .close
    mov al, [http_insecure]
    cmp al, [http_kinsecure]
    jne .close
    mov eax, [http_port]
    cmp eax, [http_kport]
    jne .close
    lea rsi, [http_host]
    lea rdi, [http_khost]
    call streq
    test eax, eax
    jz .close
    call net_clock
    cmp rax, [http_idle_until]
    jae .close
    mov byte [http_idle], 0
    mov byte [http_reused], 1
    pop rdi
    pop rsi
    clc
    ret
.close:
    call http_forget
    pop rdi
    pop rsi
.none:
    stc
    ret

; http_forget: the connection kept is closed (close_notify first for
; https). Preserves all.
http_forget:
    cmp byte [http_idle], 0
    je .out
    mov byte [http_idle], 0
    push rax
    push rdi
    mov rdi, [http_conn]
    test rdi, rdi
    jz .gone
    cmp byte [http_ktls], 0
    je .tcp
    push rdi
    lea rdi, [http_ts]
    call tls_close                      ; (sent through http_conn)
    pop rdi
.tcp:
    mov qword [http_conn], 0
    call tcp_close
.gone:
    pop rdi
    pop rax
.out:
    ret

; http_begin(EAX = the server's address): from dns_done
http_begin:
    cmp qword [http_app], 0
    je .out
    call http_connect
    jc http_lost
.out:
    ret

; http_dns_failed: the lookup for http_fetch went nowhere (and said why)
http_dns_failed:
    cmp qword [http_conn], 0
    je http_lost
    ret

; http_connect(EAX = the server's address) -> CF (said why) if it cannot
http_connect:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp qword [http_conn], 0
    jne .fail
    mov [http_ip], eax
    cmp byte [http_quiet], 0
    jne .connect
    lea rdx, [http_host]
    lea rsi, [http_path]
    mov ecx, [http_port]
    KLOG "http: GET %s from %s (%I) port %u", rsi, rdx, rax, rcx
.connect:
    mov edi, eax
    mov esi, [http_port]
    lea rdx, [http_ops]
    call tcp_connect
    jc .fail
    mov [http_conn], rax
    RDTSC64
    mov [http_t0], rax
    clc
    jmp .out
.fail:
    KLOG "http: cannot connect (no route, or every connection is busy)"
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; http_retry -> CF unless the request was taken care of again: a connection
; kept from before may close just as it is used, and if nothing came back
; on it, the request goes once more, on a new connection (or, if that
; cannot be had, the client hears it is lost). The old one is gone already.
http_retry:
    cmp byte [http_reused], 0
    je .no
    cmp qword [http_rx], 0
    jne .no
    mov qword [http_conn], 0
    call http_tls_abort
    call http_fresh
    cmp byte [http_quiet], 0
    jne .again
    KLOG "http: the connection kept open had closed; again, on a new one"
.again:
    mov eax, [http_ip]
    call http_connect
    jnc .done
    call http_lost
.done:
    clc
    ret
.no:
    stc
    ret

; http_end(EAX = 0 if the body is whole): the client hears it
http_end:
    mov byte [http_phase], HP_DONE
    mov byte [http_reused], 0
    mov rcx, [http_app]
    mov qword [http_app], 0
    test rcx, rcx
    jz .out
    jmp [rcx + HA_DONE]
.out:
    ret

; http_lost: it ended early, and has said why; the client hears it
http_lost:
    mov qword [http_conn], 0
    mov byte [http_idle], 0
    mov byte [http_reused], 0
    mov rax, [http_app]
    mov qword [http_app], 0
    test rax, rax
    jz .out
    jmp [rax + HA_LOST]
.out:
    ret

; http_complete: the answer is whole. The connection is kept for the next
; request if the server allows, or closed; then the client hears it.
http_complete:
    cmp byte [http_keep], 0
    je .close
    mov rdi, [http_conn]
    test rdi, rdi
    jz .done
    mov byte [http_idle], 1
    lea rdi, [http_khost]
    lea rsi, [http_host]
    call strcpy
    mov eax, [http_port]
    mov [http_kport], eax
    mov al, [http_tls]
    mov [http_ktls], al
    mov al, [http_insecure]
    mov [http_kinsecure], al
    call net_clock
    mov rdx, [net_second]
    imul rdx, rdx, HTTP_IDLE_S
    add rax, rdx
    mov [http_idle_until], rax
    jmp .done
.close:
    mov rdi, [http_conn]
    test rdi, rdi
    jz .done
    cmp byte [http_tls], 0
    je .tcp
    push rdi
    lea rdi, [http_ts]
    call tls_close                      ; (sent through http_conn)
    pop rdi
.tcp:
    mov qword [http_conn], 0
    call tcp_close
.done:
    xor eax, eax
    jmp http_end

http_hangup:
    push rax
    push rdi
    mov rdi, [http_conn]
    test rdi, rdi
    jz .out
    cmp byte [http_tls], 0
    je .tcp
    push rdi
    lea rdi, [http_ts]
    call tls_close                      ; (sent through http_conn)
    pop rdi
.tcp:
    mov qword [http_conn], 0
    mov qword [http_app], 0
    mov byte [http_idle], 0
    call tcp_close
.out:
    pop rdi
    pop rax
    ret

; http_cancel: ctrl+C. Preserves all.
http_cancel:
    cmp qword [http_app], 0             ; (a connection only kept stays)
    je .out
    cmp qword [http_conn], 0
    je .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rdi, [http_conn]
    call tcp_abort
    lea rdi, [http_ts]
    call tls_abort
    cmp byte [http_quiet], 0
    jne .client_first
    KLOG "http: stopped"
    call http_lost
    jmp .said
.client_first:                          ; (it may be in the middle of a line)
    call http_lost
    KLOG "http: stopped"
.said:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; -----------------------------------------------------------------------------
;  The connection's handlers (RDI = the connection)
; -----------------------------------------------------------------------------

; http_open: the client's request goes out
http_open:
    cmp qword [http_app], 0
    je http_drop
    call http_send
    jc http_drop
    ret

; http_send -> CF (said why) if the client's request would not go out
http_send:
    mov rax, [http_app]
    call [rax + HA_REQUEST]
    cmp byte [http_tls], 0
    jne .tls
    mov rdi, [http_conn]
    call tcp_write
    cmp rax, rdx
    je .sent
    KLOG "http: the request is too big to send"
    stc
    ret
.tls:
    lea rdi, [http_ts]
    call tls_write
    jnc .sent
    KLOG "https: the request would not go out"
    stc
    ret
.sent:
    clc
    ret

; http_get_request: http's own GET
http_get_request:
    mov rcx, [http_port]
    lea rdx, [http_host]
    lea rsi, [http_path]
    cmp ecx, [http_defport]
    jne .port
    SPRINTF http_req, `GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\n\r\n`, rsi, rdx
    jmp .made
.port:
    mov ecx, ecx
    SPRINTF http_req, `GET %s HTTP/1.1\r\nHost: %s:%u\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\n\r\n`, rsi, rdx, rcx
.made:
    mov edx, eax
    lea rsi, [http_req]
    ret

; http_drop: the connection given up, at once; the client hears it
http_drop:
    mov rdi, [http_conn]
    test rdi, rdi
    jz .out
    mov qword [http_conn], 0
    call tcp_abort
    lea rdi, [http_ts]
    call tls_abort
    jmp http_lost
.out:
    ret

; -----------------------------------------------------------------------------
;  https: the TCP handlers pass everything through tls.asm, whose handlers
;  are these
; -----------------------------------------------------------------------------

http_t_open:
    cmp byte [http_tls], 0
    je http_open
    call rtc_read                       ; now, for the certificate's dates
    push rdi
    mov edi, [rtc_year]
    mov esi, [rtc_mon]
    mov edx, [rtc_day]
    mov ecx, [rtc_hour]
    mov r8d, [rtc_min]
    mov r9d, [rtc_sec]
    call x509_unix
    pop rdi
    mov r9, rax
    movzx r8d, byte [http_insecure]
    lea rdi, [http_ts]
    lea rsi, [http_host]
    lea rdx, [http_tls_send]
    lea rcx, [http_tls_ops]
    call tls_start
    jnc .out
    mov eax, [rdi + TLS_ERROR]
    call tls_error_text
    KLOG "https: %s", rax
    jmp http_drop
.out:
    ret

http_t_data:
    cmp rdi, [http_conn]                ; (not after a hangup)
    jne .out
    cmp byte [http_tls], 0
    je http_input
    mov edx, edx
    lea rdi, [http_ts]
    jmp tls_input
.out:
    ret

http_t_fin:
    cmp byte [http_tls], 0
    je http_fin
    cmp rdi, [http_conn]
    jne .out
    cmp dword [http_ts + TLS_STATE], TL_OPEN
    jne .early
    cmp byte [http_phase], HP_BODY      ; (a body framed knows if it is whole)
    jne .closed
    cmp byte [http_mode], HB_CLOSE
    jne .closed
    cmp byte [http_quiet], 0            ; (a quiet client knows if it is whole)
    jne .closed
    KLOG "https: the server closed without close_notify (the answer may be cut short)"
.closed:
    call http_tls_abort
    call tcp_close
    jmp http_closed
.early:
    KLOG "https: the server closed the connection during the TLS handshake"
    call http_tls_abort
    call tcp_close
    jmp http_lost
.out:
    ret

; http_tls_abort: the session forgotten. Preserves all but RAX.
http_tls_abort:
    push rdi
    lea rdi, [http_ts]
    call tls_abort
    pop rdi
    ret

; send(RSI, EDX) -> CF if TCP's buffer could not take it all
http_tls_send:
    push rdx
    mov rdi, [http_conn]
    call tcp_write
    pop rdx
    cmp eax, edx
    ret

http_tls_ready:
    mov eax, [http_ts + TLS_CERTS]
    mov ecx, [http_ts + TLS_CERT_BYTES]
    cmp dword [http_ts + TLS_VERIFIED], 0
    je .unchecked
    cmp byte [http_quiet], 0
    jne http_open
    mov edx, [http_ts + TLS_DEPTH]
    lea rsi, [http_host]
    KLOG "https: TLS 1.3, AES-128-GCM, X25519; certificate for %s checked: %u intermediate(s), trusted root %s", rsi, rdx, qword [http_ts + TLS_ANCHOR]
    jmp http_open
.unchecked:
    KLOG "https: TLS 1.3, AES-128-GCM, X25519; %u certificate(s), %b, NOT checked (-k): this may not be the real server", rax, rcx
    jmp http_open

http_tls_closed:                        ; the server's close_notify
    lea rdi, [http_ts]
    call tls_close
    mov rdi, [http_conn]
    call tcp_close
    jmp http_closed

; EAX = what went wrong
http_tls_fail:
    mov ecx, eax
    lea rdi, [http_ts]
    call tls_error_text
    cmp ecx, TLE_ALERT
    jne .say
    mov ecx, [http_ts + TLS_ALERT]
    KLOG "https: the server sent alert %u and gave up", rcx
    jmp .drop
.say:
    cmp ecx, TLE_CERT
    jne .plain
    lea rsi, [http_host]
    cmp byte [http_quiet], 0
    jne .quiet
    KLOG "https: not fetched: %s (%s); 'http -k' fetches it anyway, without knowing who sends it", rax, rsi
    jmp .drop
.quiet:
    KLOG "https: %s cannot prove who it is: %s", rsi, rax
    jmp .drop
.plain:
    KLOG "https: %s", rax
.drop:
    mov rdi, [http_conn]
    test rdi, rdi
    jz .out
    mov qword [http_conn], 0
    call tcp_abort
    jmp http_lost
.out:
    ret

http_fin:
    cmp rdi, [http_conn]
    jne .out
    call tcp_close
    jmp http_closed
.out:
    ret

; http_closed: the server has closed the connection, which is closed here
; too; if it was only kept, it is forgotten
http_closed:
    mov qword [http_conn], 0
    cmp qword [http_app], 0
    je .kept
    cmp byte [http_phase], HP_BODY
    jne .early
    xor eax, eax
    cmp byte [http_mode], HB_CLOSE
    je http_end                         ; the close ends it
    inc eax
    jmp http_end                        ; cut short
.early:
    call http_retry
    jnc .out
    cmp qword [http_hdlen], 0
    jne .cut
    KLOG "http: the server closed without answering"
    jmp http_lost
.cut:
    KLOG "http: the server closed in the middle of the answer's headers"
    jmp http_lost
.kept:
    mov byte [http_idle], 0
.out:
    ret

; ESI = why
http_gone:
    cmp rdi, [http_conn]
    jne .out
    mov qword [http_conn], 0
    call http_tls_abort
    cmp qword [http_app], 0
    jne .fetch
    mov byte [http_idle], 0             ; only kept: forgotten
    ret
.fetch:
    push rsi
    call http_retry
    pop rsi
    jnc .out
    mov eax, [http_port]
    cmp esi, TCP_REFUSED
    je .refused
    cmp esi, TCP_RESET
    je .reset
    cmp esi, TCP_TIMEOUT
    je .timeout
    KLOG "http: the connection ended early"
    jmp http_lost
.refused:
    KLOG "http: %I refused the connection on port %u", qword [http_ip], rax
    jmp http_lost
.reset:
    KLOG "http: the server reset the connection"
    jmp http_lost
.timeout:
    KLOG "http: no answer from %I (timed out)", qword [http_ip]
    jmp http_lost
.out:
    ret

; -----------------------------------------------------------------------------
;  The answer, taken apart
; -----------------------------------------------------------------------------

; http_input(RSI = bytes of the answer, EDX = how many), as they come
http_input:
    cmp qword [http_app], 0
    jne .fetch
    cmp byte [http_idle], 0             ; on a connection only kept: not
    je .out                             ; asked for, so it is not kept
    mov byte [http_idle], 0
    mov rdi, [http_conn]
    mov qword [http_conn], 0
    call tcp_abort
    jmp http_tls_abort
.fetch:
    push rbx
    push r12
    mov r12, rsi                        ; R12 = where, EBX = what is left
    mov ebx, edx
    add [http_rx], rbx
.next:
    test ebx, ebx
    jz .end
    cmp qword [http_app], 0             ; (hung up, or given up)
    je .pop
    movzx eax, byte [http_phase]
    cmp eax, HP_HEAD
    je .head
    cmp eax, HP_BODY
    jne .extra
    movzx eax, byte [http_mode]
    cmp eax, HB_CHUNKED
    je .chunked
    mov ecx, ebx
    cmp eax, HB_CLOSE
    je .give
    cmp rcx, [http_left]
    cmova rcx, [http_left]
    sub [http_left], rcx
    jnz .give
    mov byte [http_phase], HP_DONE
.give:
    call .data
    jmp .next
.head:
    mov al, [r12]
    inc r12
    dec ebx
    call http_head_byte
    jmp .next
.chunked:
    cmp byte [http_ck], CK_DATA
    jne .chunk_byte
    mov ecx, ebx
    cmp rcx, [http_left]
    cmova rcx, [http_left]
    sub [http_left], rcx
    jnz .chunk_data
    mov byte [http_ck], CK_CRLF
.chunk_data:
    call .data
    jmp .next
.chunk_byte:
    mov al, [r12]
    inc r12
    dec ebx
    call http_chunk_byte
    jmp .next
.extra:
    mov byte [http_keep], 0             ; more than the answer: not kept
.end:
    cmp qword [http_app], 0
    je .pop
    cmp byte [http_phase], HP_DONE
    jne .pop
    pop r12
    pop rbx
    jmp http_complete
.pop:
    pop r12
    pop rbx
.out:
    ret
; .data(ECX = bytes at R12): to the client
.data:
    mov rsi, r12
    mov edx, ecx
    add r12, rcx
    sub ebx, ecx
    mov rax, [http_app]
    jmp [rax + HA_DATA]

; http_head_byte(AL): one more of the status line and headers
http_head_byte:
    mov rcx, [http_hdlen]
    cmp rcx, HTTP_HEAD - 1
    jae .too_long
    lea rdx, [http_head]
    mov [rdx + rcx], al
    inc rcx
    mov [http_hdlen], rcx
    cmp al, 10
    jne .out
    cmp rcx, 2                          ; LF LF, or LF CR LF: the end
    jb .out
    cmp byte [rdx + rcx - 2], 10
    je http_headers
    cmp rcx, 3
    jb .out
    cmp byte [rdx + rcx - 2], 13
    jne .out
    cmp byte [rdx + rcx - 3], 10
    je http_headers
.out:
    ret
.too_long:
    KLOG "http: the answer's headers do not end"
    jmp http_drop

; http_headers: they are all in; the status, how the body comes, whether
; the connection may be kept; then the client hears them
http_headers:
    push rbx
    push r12
    push r13
    lea rsi, [http_head]
    mov rdx, [http_hdlen]
    mov byte [rsi + rdx], 0
    lea rdi, [str_h_http1]
    call http_prefix
    jc .not_http
    movzx ebx, byte [rsi]               ; the minor version
    inc rsi
    cmp byte [rsi], ' '
    jne .not_http
    inc rsi
    xor eax, eax
    mov ecx, 3
.digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .not_http
    imul eax, eax, 10
    add eax, edx
    inc rsi
    dec ecx
    jnz .digit
    mov [http_status], eax
    xor r12d, r12d                      ; R12: 1 chunked, 2 a length
    xor r13d, r13d                      ; R13 = the length
    xor eax, eax
    cmp ebx, '1'                        ; HTTP/1.1 keeps by default, 1.0 not
    setae al
    mov [http_keep], al
    lea rsi, [http_head]
.line:
    mov al, [rsi]
    test al, al
    jz .end
    inc rsi
    cmp al, 10
    jne .line
    lea rdi, [str_h_te]
    call http_prefix
    jc .length
    lea rdi, [str_h_chunked]
    call http_line_has
    jc .line
    or r12d, 1
    jmp .line
.length:
    lea rdi, [str_h_length]
    call http_prefix
    jc .connection
.space:
    cmp byte [rsi], ' '
    jne .number
    inc rsi
    jmp .space
.number:
    xor r13d, r13d
    xor ecx, ecx                        ; digits
.ldigit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .length_end
    mov rax, r13
    shr rax, 40                         ; past a TiB: not real
    jnz .not_http
    imul r13, r13, 10
    add r13, rdx
    inc ecx
    inc rsi
    jmp .ldigit
.length_end:
    test ecx, ecx
    jz .not_http
    or r12d, 2
    jmp .line
.connection:
    lea rdi, [str_h_connection]
    call http_prefix
    jc .line
    lea rdi, [str_h_close]
    call http_line_has
    jc .alive
    mov byte [http_keep], 0
    jmp .line
.alive:
    lea rdi, [str_h_keep_alive]
    call http_line_has
    jc .line
    mov byte [http_keep], 1
    jmp .line
.end:
    mov eax, [http_status]
    cmp eax, 101
    je .not_http                        ; (no other protocols here)
    cmp eax, 200
    jae .final
    mov qword [http_hdlen], 0           ; 1xx: the answer is still to come
    jmp .out
.final:
    mov byte [http_phase], HP_BODY
    cmp eax, 204
    je .no_body
    cmp eax, 304
    je .no_body
    test r12d, 1
    jz .not_chunked
    mov byte [http_mode], HB_CHUNKED
    mov byte [http_ck], CK_SIZE
    mov qword [http_left], 0
    test r12d, 2
    jz .heard
    mov byte [http_keep], 0             ; both: something is off, so not kept
    jmp .heard
.not_chunked:
    test r12d, 2
    jz .to_close
    mov byte [http_mode], HB_LENGTH
    mov [http_left], r13
    test r13, r13
    jnz .heard
.no_body:
    mov byte [http_phase], HP_DONE
    jmp .heard
.to_close:
    mov byte [http_mode], HB_CLOSE
    mov byte [http_keep], 0
.heard:
    mov eax, [http_status]
    lea rsi, [http_head]
    mov rdx, [http_hdlen]
    mov rcx, [http_app]
    call [rcx + HA_HEAD]
    jmp .out
.not_http:
    KLOG "http: the server does not answer in HTTP"
    pop r13
    pop r12
    pop rbx
    jmp http_drop
.out:
    pop r13
    pop r12
    pop rbx
    ret

; http_chunk_byte(AL): one more of the chunks' framing
http_chunk_byte:
    movzx ecx, byte [http_ck]
    cmp ecx, CK_SIZE
    je .size
    cmp ecx, CK_EXT
    je .ext
    cmp ecx, CK_CRLF
    je .crlf
    cmp al, 10                          ; CK_TRAILER: up to an empty line
    je .trailer_line
    cmp al, 13
    je .out
    inc dword [http_trail]
    ret
.trailer_line:
    cmp dword [http_trail], 0
    jne .next_trailer
    mov byte [http_phase], HP_DONE
    ret
.next_trailer:
    mov dword [http_trail], 0
    ret
.size:
    cmp al, 10
    je .size_end
    cmp al, 13
    je .out
    cmp al, ';'
    je .to_ext
    cmp al, ' '
    je .to_ext
    cmp al, 9
    je .to_ext
    movzx edx, al
    or edx, 0x20
    sub edx, '0'
    cmp edx, 9
    jbe .hex
    sub edx, 'a' - '0'
    cmp edx, 5
    ja .broken
    add edx, 10
.hex:
    mov rax, [http_left]
    shr rax, 28                         ; a chunk over 4 GiB: not real
    jnz .broken
    inc dword [http_trail]              ; (digits seen)
    mov rax, [http_left]
    shl rax, 4
    or rax, rdx
    mov [http_left], rax
    ret
.to_ext:
    mov byte [http_ck], CK_EXT
    ret
.ext:
    cmp al, 10
    jne .out
.size_end:
    cmp dword [http_trail], 0
    je .broken                          ; no size at all
    mov dword [http_trail], 0
    cmp qword [http_left], 0
    je .last
    mov byte [http_ck], CK_DATA
    ret
.last:
    mov byte [http_ck], CK_TRAILER
    ret
.crlf:
    cmp al, 10
    jne .out
    mov byte [http_ck], CK_SIZE
    ret
.broken:
    KLOG "http: the answer's chunks are broken"
    jmp http_drop
.out:
    ret

; -----------------------------------------------------------------------------
;  http's own GET
; -----------------------------------------------------------------------------

; the status line and headers, kept ahead of the body
http_get_head:
    lea rdi, [http_buf]
    mov rcx, rdx
    mov [http_len], rcx
    rep movsb
    ret

; RSI = data, EDX = bytes
http_data:
    mov eax, edx
    add [http_total], rax
    mov ecx, edx
    mov rax, HTTP_MAX
    sub rax, [http_len]
    cmp rcx, rax
    cmova rcx, rax
    lea rdi, [http_buf]
    add rdi, [http_len]
    add [http_len], rcx
    rep movsb
    ret

; EAX = 0 if the body is whole
http_get_done:
    test eax, eax
    jz .whole
    KLOG "http: the connection closed before the end of the answer"
.whole:
    call http_finish
    jmp shell_resume

http_get_lost:
    cmp qword [http_total], 0
    je .out
    KLOG "http: %b had arrived", qword [http_total]
.out:
    jmp shell_resume

; http_finish: the whole answer is in; what it says
http_finish:
    push rbx
    push r12
    push r13
    push r14
    RDTSC64
    sub rax, [http_t0]
    xor edx, edx
    div qword [tsc_per_ms]
    KLOG "http: %b in %u ms", qword [http_total], rax
    lea r12, [http_buf]                 ; R12 = where we are, R13 = the end
    mov r13, r12
    add r13, [http_len]
    call http_line
    jc .empty
    lea rax, [http_text]
    KLOG "http: %s", rax
.header:
    call http_line
    jc .no_body
    cmp byte [http_text], 0             ; the blank line
    je .body
    lea rsi, [http_text]
    lea rdi, [str_h_type]
    call http_prefix
    jnc .show
    lea rdi, [str_h_location]
    call http_prefix
    jnc .show
    lea rdi, [str_h_te]
    call http_prefix
    jnc .show
    jmp .header
.show:
    lea rax, [http_text]
    KLOG "  %s", rax
    jmp .header
.body:
    mov rbx, r13
    sub rbx, r12
    cmp byte [http_file], 0
    je .print
    mov r14, [vol_current]
    test r14, r14
    jz .no_volume
    lea rsi, [http_file]
    mov rdi, r12
    mov rcx, rbx
    call fat_write_file
    jc .done
    lea rax, [http_file]
    KLOG "http: %b saved to %s", rbx, rax
    jmp .done
.no_volume:
    KLOG "http: no volume to save to ('disks', then 'vol <n> rw')"
    jmp .done
.print:
    mov r14d, HTTP_LINES
.line:
    cmp r12, r13
    jae .done
    dec r14d
    js .more
    call http_line
    lea rax, [http_text]
    KLOG "%s", rax
    jmp .line
.more:
    KLOG "... %b of body in all ('http <url> <file>' saves it)", rbx
    jmp .done
.empty:
    KLOG "http: the server sent nothing"
    jmp .out
.no_body:
    KLOG "http: the headers never ended"
.done:
    mov rax, [http_total]               ; the body that came, and the headers
    add rax, [http_hdlen]
    cmp rax, [http_len]
    jbe .out
    mov eax, HTTP_MAX
    KLOG "http: only the first %b were kept", rax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; http_line(R12 = where, R13 = the end) -> http_text = the line, printable
; and cut short; R12 past it. CF if there was none. Preserves others.
http_line:
    push rax
    push rcx
    push rdi
    cmp r12, r13
    jae .none
    lea rdi, [http_text]
    xor ecx, ecx
.char:
    cmp r12, r13
    jae .end
    mov al, [r12]
    inc r12
    cmp al, 10
    je .end
    cmp al, 13
    je .char
    cmp al, 9
    jne .printable
    mov al, ' '
.printable:
    cmp al, ' '
    jb .dot
    cmp al, '~'
    jbe .keep
.dot:
    mov al, '.'
.keep:
    cmp ecx, HTTP_LINE
    jae .char
    mov [rdi + rcx], al
    inc ecx
    jmp .char
.end:
    mov byte [rdi + rcx], 0
    clc
    jmp .out
.none:
    stc
.out:
    pop rdi
    pop rcx
    pop rax
    ret

section .rodata
str_http:       db 'http://', 0
str_https:      db 'https://', 0
str_h_http1:    db 'http/1.', 0
str_h_type:     db 'content-type:', 0
str_h_location: db 'location:', 0
str_h_te:       db 'transfer-encoding:', 0
str_h_length:   db 'content-length:', 0
str_h_connection: db 'connection:', 0
str_h_chunked:  db 'chunked', 0
str_h_close:    db 'close', 0
str_h_keep_alive: db 'keep-alive', 0
align 8
http_ops:       dq http_t_open, http_t_data, http_t_fin, http_gone
http_tls_ops:   dq http_tls_ready, http_input, http_tls_closed, http_tls_fail
http_get:       dq http_get_request, http_get_head, http_data, http_get_done, http_get_lost

section .bss
alignb 8
http_conn:      resq 1
http_app:       resq 1                  ; the client, while one runs
http_len:       resq 1                  ; bytes kept
http_total:     resq 1                  ; bytes of body that came
http_t0:        resq 1
http_port:      resq 1
http_hdlen:     resq 1                  ; of http_head
http_rx:        resq 1                  ; bytes of the answer so far
http_left:      resq 1                  ; of Content-Length, or of the chunk
http_idle_until: resq 1                 ; net_clock: a kept one is closed then
http_ip:        resd 1
http_defport:   resd 1                  ; 80, or 443 for https
http_status:    resd 1
http_trail:     resd 1                  ; the chunks': characters in a line
http_kport:     resd 1                  ; the connection kept: where it goes
http_tls:       resb 1
http_insecure:  resb 1                  ; -k
http_quiet:     resb 1
http_phase:     resb 1                  ; HP_*
http_mode:      resb 1                  ; HB_*
http_ck:        resb 1                  ; CK_*
http_keep:      resb 1                  ; the server allows it to be kept
http_idle:      resb 1                  ; http_conn is only kept, for later
http_reused:    resb 1                  ; this request went on one kept
http_ktls:      resb 1
http_kinsecure: resb 1
http_khost:     resb 256
http_host:      resb 256
http_path:      resb 512
http_file:      resb 256
http_req:       resb 1024
http_text:      resb HTTP_LINE + 8
http_head:      resb HTTP_HEAD + 8
http_buf:       resb HTTP_MAX
alignb 16
http_ts:        resb TLS_SESSION            ; its TLS session, for https
