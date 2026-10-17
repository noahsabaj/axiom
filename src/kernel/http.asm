; =============================================================================
;  http.asm - one request at a time over tcp.asm, or for https:// over
;  tls.asm on top of it, for a client: 'http <url> [file]' here, which GETs
;  over HTTP/1.0 (so the server closes when it is done and never sends
;  chunks) and keeps the answer in memory (1 MiB at most), then shows the
;  status line, a few headers and the start of the body, or saves the body
;  to a file on the current volume; or claude.asm. For https the server's
;  certificate must name the host and lead to a trusted root (tls.asm,
;  x509.asm), dates taken from the CMOS clock; 'http -k' fetches without
;  checking who the server is, as curl's -k does.
;
;    http_fetch(RSI = URL, RDX = the client, ECX = HF_* flags) -> CF (said
;        why) if it could not begin; else the client hears how it goes
;    http_hangup    the client has what it wants: closed now (close_notify
;        first for https), and neither DONE nor LOST follows. Preserves all.
;
;  The client is a table of handlers, at HA_*: REQUEST (-> RSI = the
;  request, RDX = its bytes; http_host, http_port and http_path are set),
;  DATA (RSI = bytes of the answer, EDX = how many), DONE (the server
;  closed: the answer is whole) and LOST (it ended early, already said why,
;  or was stopped). They may change RAX, RCX, RDX, RSI, RDI and R8-R11.
; =============================================================================

HTTP_MAX        equ 1024 * 1024
HTTP_LINES      equ 20                  ; of the body, shown
HTTP_LINE       equ 150                 ; characters of a line, shown

HA_REQUEST      equ 0
HA_DATA         equ 8
HA_DONE         equ 16
HA_LOST         equ 24

HF_INSECURE     equ 1                   ; do not check the certificate chain
HF_QUIET        equ 2                   ; only warnings and failures are said

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
    jc .out
    call net_ready
    jc .out
    mov [http_app], rdx
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

; http_end: the answer is whole; the client hears it
http_end:
    mov qword [http_conn], 0
    mov rax, [http_app]
    mov qword [http_app], 0
    test rax, rax
    jz .out
    jmp [rax + HA_DONE]
.out:
    ret

; http_lost: it ended early, and has said why; the client hears it
http_lost:
    mov qword [http_conn], 0
    mov rax, [http_app]
    mov qword [http_app], 0
    test rax, rax
    jz .out
    jmp [rax + HA_LOST]
.out:
    ret

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
    call tcp_close
.out:
    pop rdi
    pop rax
    ret

; http_cancel: ctrl+C. Preserves all.
http_cancel:
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
    mov rax, [http_app]
    test rax, rax
    jz http_drop
    call [rax + HA_REQUEST]
    cmp byte [http_tls], 0
    jne .tls
    mov rdi, [http_conn]
    call tcp_write
    cmp rax, rdx
    je .out
    KLOG "http: the request is too big to send"
    jmp http_drop
.tls:
    lea rdi, [http_ts]
    call tls_write
    jnc .out
    KLOG "https: the request would not go out"
    jmp http_drop
.out:
    ret

; http_get_request: http's own GET
http_get_request:
    mov rcx, [http_port]
    lea rdx, [http_host]
    lea rsi, [http_path]
    cmp ecx, [http_defport]
    jne .port
    SPRINTF http_req, `GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`, rsi, rdx
    jmp .made
.port:
    mov ecx, ecx
    SPRINTF http_req, `GET %s HTTP/1.0\r\nHost: %s:%u\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`, rsi, rdx, rcx
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
    je http_app_data
    mov edx, edx
    lea rdi, [http_ts]
    jmp tls_input
.out:
    ret

http_app_data:
    mov rax, [http_app]
    test rax, rax
    jz .out
    jmp [rax + HA_DATA]
.out:
    ret

http_t_fin:
    cmp byte [http_tls], 0
    je http_fin
    cmp rdi, [http_conn]
    jne .out
    cmp dword [http_ts + TLS_STATE], TL_OPEN
    jne .early
    cmp byte [http_quiet], 0            ; (a quiet client knows if it is whole)
    jne .quiet
    KLOG "https: the server closed without close_notify (the answer may be cut short)"
.quiet:
    call http_tls_abort
    call tcp_close
    jmp http_end
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

http_tls_closed:                        ; the server's close_notify: the end
    lea rdi, [http_ts]
    call tls_close
    mov rdi, [http_conn]
    call tcp_close
    jmp http_end

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

; http's own GET: RSI = data, EDX = bytes
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

http_fin:
    cmp rdi, [http_conn]
    jne .out
    call tcp_close
    jmp http_end
.out:
    ret

; ESI = why
http_gone:
    cmp rdi, [http_conn]
    jne .out
    mov qword [http_conn], 0
    call http_tls_abort
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

; http's own GET: the end of it, whole or not
http_get_done:
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
    mov rax, [http_total]
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
str_h_type:     db 'content-type:', 0
str_h_location: db 'location:', 0
align 8
http_ops:       dq http_t_open, http_t_data, http_t_fin, http_gone
http_tls_ops:   dq http_tls_ready, http_app_data, http_tls_closed, http_tls_fail
http_get:       dq http_get_request, http_data, http_get_done, http_get_lost

section .bss
alignb 8
http_conn:      resq 1
http_app:       resq 1                  ; the client, while one runs
http_len:       resq 1                  ; bytes kept
http_total:     resq 1                  ; bytes that came
http_t0:        resq 1
http_port:      resq 1
http_ip:        resd 1
http_defport:   resd 1                  ; 80, or 443 for https
http_tls:       resb 1
http_insecure:  resb 1                  ; -k
http_quiet:     resb 1
http_host:      resb 256
http_path:      resb 512
http_file:      resb 256
http_req:       resb 1024
http_text:      resb HTTP_LINE + 8
http_buf:       resb HTTP_MAX
alignb 16
http_ts:        resb TLS_SESSION            ; its TLS session, for https
