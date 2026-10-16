; =============================================================================
;  http.asm - 'http <url> [file]': one GET over tcp.asm, or for https://
;  over tls.asm on top of it. The answer is kept in memory (1 MiB at most);
;  at the end come the status line, a few headers, and the start of the
;  body, or the body goes to a file on the current volume. HTTP/1.0, so the
;  server closes when it is done and never sends chunks. For https the
;  server's certificate must name the host and lead to a trusted root
;  (tls.asm, x509.asm), dates taken from the CMOS clock; 'http -k' fetches
;  without checking who the server is, as curl's -k does.
; =============================================================================

HTTP_MAX        equ 1024 * 1024
HTTP_LINES      equ 20                  ; of the body, shown
HTTP_LINE       equ 150                 ; characters of a line, shown

section .text

; http [-k] <url> [file]
cmd_http:
    push r12
    push r13
    cmp qword [http_conn], 0            ; (not while one is running: -k is its)
    jne .busy
    mov rsi, [sh_args]
    mov byte [http_insecure], 0
    cmp word [rsi], '-k'
    jne .url
    mov al, [rsi + 2]
    test al, al
    jz .flag
    cmp al, ' '
    jne .url
.flag:
    mov byte [http_insecure], 1
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
    cmp qword [http_conn], 0
    jne .busy
    mov rsi, r12
    call http_url
    jc .out
    call net_ready
    jc .out
    lea rsi, [http_host]
    call ip_parse
    jc .name
    cmp byte [rsi], 0
    jne .name
    call http_begin
    jmp .out
.name:
    lea rsi, [http_host]
    mov edx, 2
    call dns_lookup
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

; http_begin(EAX = the server's address): from cmd_http, or from dns_done
http_begin:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp qword [http_conn], 0
    jne .out
    mov [http_ip], eax
    lea rdx, [http_host]
    lea rsi, [http_path]
    mov ecx, [http_port]
    KLOG "http: GET %s from %s (%I) port %u", rsi, rdx, rax, rcx
    mov edi, eax
    mov esi, ecx
    lea rdx, [http_ops]
    call tcp_connect
    jc .fail
    mov [http_conn], rax
    xor eax, eax
    mov [http_len], rax
    mov [http_total], rax
    RDTSC64
    mov [http_t0], rax
    jmp .out
.fail:
    KLOG "http: cannot connect (no route, or every connection is busy)"
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; http_cancel: ctrl+C. Preserves all.
http_cancel:
    cmp qword [http_conn], 0
    je .out
    push rdi
    mov rdi, [http_conn]
    mov qword [http_conn], 0
    call tcp_abort
    call tls_abort
    pop rdi
    KLOG "http: stopped"
.out:
    ret

; -----------------------------------------------------------------------------
;  The connection's handlers (RDI = the connection)
; -----------------------------------------------------------------------------

http_open:
    mov rcx, [http_port]
    lea rdx, [http_host]
    lea rsi, [http_path]
    cmp ecx, [http_defport]
    jne .port
    SPRINTF http_req, `GET %s HTTP/1.0\r\nHost: %s\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`, rsi, rdx
    jmp .send
.port:
    mov ecx, ecx
    SPRINTF http_req, `GET %s HTTP/1.0\r\nHost: %s:%u\r\nUser-Agent: Axiom/0.1\r\nAccept: */*\r\nConnection: close\r\n\r\n`, rsi, rdx, rcx
.send:
    mov edx, eax
    lea rsi, [http_req]
    cmp byte [http_tls], 0
    jne .tls
    mov rdi, [http_conn]
    call tcp_write
    ret
.tls:
    call tls_write
    jnc .out
    KLOG "https: the request would not go out"
    jmp http_drop
.out:
    ret

; http_drop: the connection given up, at once
http_drop:
    mov rdi, [http_conn]
    test rdi, rdi
    jz .out
    mov qword [http_conn], 0
    call tcp_abort
    call tls_abort
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
    mov r8, rax
    movzx ecx, byte [http_insecure]
    lea rdi, [http_host]
    lea rsi, [http_tls_send]
    lea rdx, [http_tls_ops]
    call tls_start
    jnc .out
    mov eax, [tls_error]
    call tls_error_text
    KLOG "https: %s", rax
    jmp http_drop
.out:
    ret

http_t_data:
    cmp byte [http_tls], 0
    je http_data
    mov edx, edx
    jmp tls_input

http_t_fin:
    cmp byte [http_tls], 0
    je http_fin
    cmp rdi, [http_conn]
    jne .out
    cmp dword [tls_state], TL_OPEN
    jne .early
    KLOG "https: the server closed without close_notify (the answer may be cut short)"
    call tls_abort
    call tcp_close
    jmp http_finish
.early:
    KLOG "https: the server closed the connection during the TLS handshake"
    call tls_abort
    call tcp_close
    mov qword [http_conn], 0
.out:
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
    mov eax, [tls_certs]
    mov ecx, [tls_cert_bytes]
    cmp dword [tls_verified], 0
    je .unchecked
    mov edx, [x509_depth]
    lea rsi, [http_host]
    KLOG "https: TLS 1.3, AES-128-GCM, X25519; certificate for %s checked: %u intermediate(s), trusted root %s", rsi, rdx, qword [x509_anchor]
    jmp http_open
.unchecked:
    KLOG "https: TLS 1.3, AES-128-GCM, X25519; %u certificate(s), %b, NOT checked (-k): this may not be the real server", rax, rcx
    jmp http_open

http_tls_closed:                        ; the server's close_notify: the end
    call tls_close
    mov rdi, [http_conn]
    call tcp_close
    jmp http_finish

; EAX = what went wrong
http_tls_fail:
    mov ecx, eax
    call tls_error_text
    cmp ecx, TLE_ALERT
    jne .say
    mov ecx, [tls_alert]
    KLOG "https: the server sent alert %u and gave up", rcx
    jmp .drop
.say:
    cmp ecx, TLE_CERT
    jne .plain
    lea rsi, [http_host]
    KLOG "https: not fetched: %s (%s); 'http -k' fetches it anyway, without knowing who sends it", rax, rsi
    jmp .drop
.plain:
    KLOG "https: %s", rax
.drop:
    mov rdi, [http_conn]
    test rdi, rdi
    jz .out
    mov qword [http_conn], 0
    call tcp_abort
    cmp qword [http_total], 0
    je .out
    KLOG "http: %b had arrived", qword [http_total]
.out:
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

http_fin:
    cmp rdi, [http_conn]
    jne .out
    call tcp_close
    call http_finish
.out:
    ret

; ESI = why
http_gone:
    cmp rdi, [http_conn]
    jne .out
    mov qword [http_conn], 0
    call tls_abort
    mov eax, [http_port]
    cmp esi, TCP_REFUSED
    je .refused
    cmp esi, TCP_RESET
    je .reset
    cmp esi, TCP_TIMEOUT
    je .timeout
    KLOG "http: the connection ended early"
    jmp .partial
.refused:
    KLOG "http: %I refused the connection on port %u", qword [http_ip], rax
    ret
.reset:
    KLOG "http: the server reset the connection"
    jmp .partial
.timeout:
    KLOG "http: no answer from %I (timed out)", qword [http_ip]
.partial:
    cmp qword [http_total], 0
    je .out
    KLOG "http: %b had arrived", qword [http_total]
.out:
    ret

; http_finish: the whole answer is in; what it says
http_finish:
    push rbx
    push r12
    push r13
    push r14
    mov qword [http_conn], 0
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
http_tls_ops:   dq http_tls_ready, http_data, http_tls_closed, http_tls_fail

section .bss
alignb 8
http_conn:      resq 1
http_len:       resq 1                  ; bytes kept
http_total:     resq 1                  ; bytes that came
http_t0:        resq 1
http_port:      resq 1
http_ip:        resd 1
http_defport:   resd 1                  ; 80, or 443 for https
http_tls:       resb 1
http_insecure:  resb 1                  ; -k
http_host:      resb 256
http_path:      resb 512
http_file:      resb 256
http_req:       resb 1024
http_text:      resb HTTP_LINE + 8
http_buf:       resb HTTP_MAX
