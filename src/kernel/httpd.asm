; =============================================================================
;  httpd.asm - 'httpd <port>': a small HTTP/1.1 server for the files on the
;  current volume, read only. GET and HEAD; a file comes with its length
;  and a type from its extension; a directory with its index.html, or a
;  listing of it (a directory asked for without its last '/' is sent there
;  first, so that the listing's links work). Connections are kept, as
;  HTTP/1.1 has them unless either side says otherwise (HTTP/1.0 only with
;  "Connection: keep-alive"), and closed after HV_IDLE_S seconds unused;
;  requests sent one after another without waiting are answered in order.
;  A request's body is passed over. Each connection's requests come
;  through a window of HV_REQ_MAX bytes (tcp_flow), so a client cannot
;  send faster than it is answered; answers go out as TCP's send buffer
;  takes them, the rest after each round of the network (hd_tick).
;
;  A file is read whole into memory (HV_FILE_MAX at most) with its headers
;  in front, so the main loop waits on the drive meanwhile. Every request
;  is logged: who, what, the status and the body's bytes.
;
;  State per TCP connection, by TC_INDEX. Main loop only.
; =============================================================================

HV_REQ_MAX      equ 4096                ; a request's head, and what follows it
HV_FILE_MAX     equ 8 * 1024 * 1024
HV_IDLE_S       equ 30
HV_LIST_MAX     equ 128 * 1024          ; a directory's listing

HV_CONN         equ 0                   ; the TCP connection; 0 = none
HV_RESP         equ 8                   ; the answer: headers, then body (kmalloc)
HV_RLEN         equ 16
HV_SENT         equ 24                  ; of it, handed to TCP
HV_SKIP         equ 32                  ; a request's body: bytes to pass over
HV_IDLE         equ 40                  ; net_clock when last busy
HV_REQLEN       equ 48                  ; dword: bytes in HV_REQ
HV_FLAGS        equ 52                  ; dword
HV_COUNT        equ 56                  ; dword: requests answered on it
HV_REQ          equ 64
HV_SIZE         equ HV_REQ + HV_REQ_MAX + 64

HVF_CLOSE       equ 1                   ; closed once this answer has gone
HVF_FIN         equ 2                   ; they have finished sending
HVF_DONE        equ 4                   ; closed here: nothing more

section .text

; httpd [<port> | stop]
cmd_httpd:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je hd_status
    call arg_split
    lea rdi, [str_hd_stop]
    call streq
    test eax, eax
    jnz hd_stop
    call arg_uint
    jc .usage
    test eax, eax
    jz .usage
    cmp eax, 65535
    ja .usage
    cmp qword [hd_listener], 0
    jne .running
    mov edi, eax
    lea rsi, [hd_ops]
    lea rdx, [hd_accept]
    xor ecx, ecx
    call tcp_listen
    jc .taken
    mov [hd_listener], rax
    mov [hd_port], rdi
    KLOG "httpd: serving the current volume on port %u, read only ('httpd stop' ends it)", rdi
    ret
.running:
    KLOG "httpd: already serving on port %u", qword [hd_port]
    ret
.taken:
    KLOG "httpd: cannot listen on port %u (taken, or no listener free)", rdi
    ret
.usage:
    KLOG "usage: httpd <port> | httpd stop | httpd (what it is doing)"
    ret

hd_status:
    cmp qword [hd_listener], 0
    je .idle
    mov eax, [hd_live]
    KLOG "httpd: serving on port %u: %u connection(s) open, %u request(s), %b sent", qword [hd_port], rax, qword [hd_requests], qword [hd_bytes]
    ret
.idle:
    KLOG "httpd: not serving ('httpd <port>' starts it)"
    ret

hd_stop:
    push rbx
    push rcx
    mov rdi, [hd_listener]
    test rdi, rdi
    jz .none
    call tcp_unlisten
    mov qword [hd_listener], 0
    lea rbx, [hd_conns]
    mov ecx, MAX_TCP
.next:
    mov rdi, [rbx + HV_CONN]
    test rdi, rdi
    jz .skip
    call tcp_abort
    call hd_free
.skip:
    add rbx, HV_SIZE
    dec ecx
    jnz .next
    KLOG "httpd: stopped (%u request(s), %b sent)", qword [hd_requests], qword [hd_bytes]
    jmp .out
.none:
    KLOG "httpd: not serving"
.out:
    pop rcx
    pop rbx
    ret

; hd_slot(RDI = connection) -> RBX = its state. Preserves others.
hd_slot:
    push rax
    mov eax, [rdi + TC_INDEX]
    imul rbx, rax, HV_SIZE
    lea rax, [hd_conns]
    add rbx, rax
    pop rax
    ret

; hd_free(RBX): the state let go. Preserves all.
hd_free:
    cmp qword [rbx + HV_CONN], 0
    je .out
    push rax
    push rdi
    mov rdi, [rbx + HV_RESP]
    call kfree
    mov qword [rbx + HV_RESP], 0
    mov qword [rbx + HV_CONN], 0
    dec dword [hd_live]
    pop rdi
    pop rax
.out:
    ret

; -----------------------------------------------------------------------------
;  TCP's side (RDI = the connection)
; -----------------------------------------------------------------------------

; hd_accept(RDI, RSI = the listener)
hd_accept:
    push rbx
    push rcx
    push rdi
    call hd_slot
    mov rdi, rbx
    mov ecx, HV_REQ / 8
    xor eax, eax
    rep stosq
    pop rdi
    mov [rbx + HV_CONN], rdi
    call net_clock
    mov [rbx + HV_IDLE], rax
    inc dword [hd_live]
    mov esi, HV_REQ_MAX
    call tcp_flow
    pop rcx
    pop rbx
    clc
    ret

hd_open:
    ret

; RSI = data, EDX = bytes: behind what waits
hd_data:
    push rbx
    call hd_slot
    cmp [rbx + HV_CONN], rdi
    jne .out
    mov ecx, [rbx + HV_REQLEN]
    lea eax, [rcx + rdx]
    cmp eax, HV_REQ_MAX                 ; (the window keeps it within)
    ja .over
    mov [rbx + HV_REQLEN], eax
    push rdi
    lea rdi, [rbx + HV_REQ + rcx]
    mov ecx, edx
    rep movsb
    pop rdi
    call net_clock
    mov [rbx + HV_IDLE], rax
    call hd_work
.out:
    pop rbx
    ret
.over:
    KLOG "httpd: more came than the window allows"
    call tcp_abort
    call hd_free
    pop rbx
    ret

hd_fin:
    push rbx
    call hd_slot
    cmp [rbx + HV_CONN], rdi
    jne .out
    or dword [rbx + HV_FLAGS], HVF_FIN
    call hd_work
.out:
    pop rbx
    ret

hd_gone:
    push rbx
    call hd_slot
    cmp [rbx + HV_CONN], rdi
    jne .out
    call hd_free
.out:
    pop rbx
    ret

; hd_tick: from net_service. Answers on their way go on; connections
; unused for HV_IDLE_S are closed. Preserves all but RAX.
hd_tick:
    cmp dword [hd_live], 0
    je .quick
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rbx, [hd_conns]
    mov ecx, MAX_TCP
.next:
    mov rdi, [rbx + HV_CONN]
    test rdi, rdi
    jz .skip
    test dword [rbx + HV_FLAGS], HVF_DONE
    jnz .skip
    cmp qword [rbx + HV_RESP], 0
    je .idle
    push rcx
    call hd_work
    pop rcx
    jmp .skip
.idle:
    cmp dword [rbx + HV_REQLEN], 0
    jne .skip
    call net_clock
    sub rax, [rbx + HV_IDLE]
    mov rdx, [net_second]
    imul rdx, rdx, HV_IDLE_S
    cmp rax, rdx
    jb .skip
    or dword [rbx + HV_FLAGS], HVF_DONE
    call tcp_close
.skip:
    add rbx, HV_SIZE
    dec ecx
    jnz .next
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
.quick:
    ret

; -----------------------------------------------------------------------------
;  A connection's requests, one after another (RBX = state, RDI = connection)
; -----------------------------------------------------------------------------

; hd_work: the answer on its way goes on; once it has gone, the next request
; that is all here is answered, and so on. Preserves RBX, RDI.
hd_work:
    push r12
    mov r12, rdi
.again:
    test dword [rbx + HV_FLAGS], HVF_DONE
    jnz .out
    cmp qword [rbx + HV_RESP], 0
    je .ready
    call hd_push
    jc .out                             ; not all of it has gone yet
.ready:
    test dword [rbx + HV_FLAGS], HVF_CLOSE
    jnz .close
    mov rax, [rbx + HV_SKIP]            ; a request's body, passed over
    test rax, rax
    jz .request
    mov ecx, [rbx + HV_REQLEN]
    cmp rax, rcx
    cmova rax, rcx
    test eax, eax
    jz .wait
    sub [rbx + HV_SKIP], rax
    mov ecx, eax
    call hd_eat
    jmp .again
.request:
    cmp dword [rbx + HV_REQLEN], 0
    je .wait
    mov al, [rbx + HV_REQ]              ; blank lines before one: passed over
    cmp al, 13
    je .blank
    cmp al, 10
    jne .head
.blank:
    mov ecx, 1
    call hd_eat
    jmp .again
.head:
    call hd_head_end
    jnc .parse
    cmp dword [rbx + HV_REQLEN], HV_REQ_MAX
    jb .wait
    lea rax, [str_hd_q]                 ; it does not end
    mov [hd_mtext], rax
    mov byte [hd_target], 0
    mov byte [hd_meth], 0
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    mov eax, 431
    call hd_error
    jmp .again
.parse:
    push rcx
    call hd_request
    pop rcx
    call hd_eat
    jmp .again
.wait:
    test dword [rbx + HV_FLAGS], HVF_FIN
    jz .out                             ; more to come
.close:
    or dword [rbx + HV_FLAGS], HVF_DONE
    mov rdi, r12
    call tcp_close
.out:
    mov rdi, r12
    pop r12
    ret

; hd_push(RBX, R12) -> CF if the answer has not all gone to TCP yet
hd_push:
    mov rsi, [rbx + HV_RESP]
    mov rdx, [rbx + HV_RLEN]
    sub rdx, [rbx + HV_SENT]
    jz .done
    add rsi, [rbx + HV_SENT]
    cmp rdx, 1024 * 1024
    jbe .write
    mov edx, 1024 * 1024
.write:
    mov rdi, r12
    call tcp_write
    add [rbx + HV_SENT], rax
    add [hd_bytes], rax
    mov rax, [rbx + HV_SENT]
    cmp rax, [rbx + HV_RLEN]
    jb .more
.done:
    mov rdi, [rbx + HV_RESP]
    call kfree
    mov qword [rbx + HV_RESP], 0
    call net_clock
    mov [rbx + HV_IDLE], rax
    clc
    ret
.more:
    stc
    ret

; hd_eat(RBX, R12, ECX = bytes): off the front of what came; the window
; opens by as much. Preserves RBX, R12.
hd_eat:
    mov edx, ecx
    mov eax, [rbx + HV_REQLEN]
    sub eax, ecx
    mov [rbx + HV_REQLEN], eax
    lea rdi, [rbx + HV_REQ]
    lea rsi, [rdi + rcx]
    mov ecx, eax
    rep movsb
    mov rdi, r12
    mov esi, edx
    jmp tcp_consumed

; hd_head_end(RBX) -> ECX = the bytes of the request's head, its empty line
; included; CF if it has not all come. Preserves others but RAX, RDX, RSI.
hd_head_end:
    mov edx, [rbx + HV_REQLEN]
    lea rsi, [rbx + HV_REQ]
    xor ecx, ecx
.next:
    cmp ecx, edx
    jae .none
    cmp byte [rsi + rcx], 10
    jne .on
    lea eax, [rcx + 1]                  ; LF, then LF or CR LF: the end
    cmp eax, edx
    jae .none
    cmp byte [rsi + rax], 10
    je .found
    cmp byte [rsi + rax], 13
    jne .on
    inc eax
    cmp eax, edx
    jae .none
    cmp byte [rsi + rax], 10
    je .found
.on:
    inc ecx
    jmp .next
.found:
    lea ecx, [rax + 1]
    clc
    ret
.none:
    stc
    ret

; hd_request(RBX, R12, ECX = its head's bytes): the request taken apart and
; answered (HV_RESP); HV_SKIP is its body, HVF_CLOSE if the connection ends
; after it
hd_request:
    push r13
    push r14
    push r15
    inc dword [rbx + HV_COUNT]
    inc qword [hd_requests]
    lea r13, [rbx + HV_REQ]             ; R13 = the request
    mov byte [r13 + rcx - 1], 0         ; (its last LF)
    lea rax, [hd_mbuf]
    mov [hd_mtext], rax
    mov byte [hd_mbuf], 0
    mov byte [hd_target], 0
    mov byte [hd_meth], 0
    xor eax, eax
    mov [hd_clen], rax
    mov [hd_conn_close], al
    mov [hd_conn_keep], al
    mov [hd_te], al
    mov [hd_ka_echo], al
    mov rsi, r13                        ; the method
    lea rdi, [hd_mbuf]
    mov ecx, 15
    call hd_token
    jc .bad
    lea rdi, [hd_target]                ; the target
    mov ecx, 255
    call hd_token
    jnc .version
    test eax, eax
    jz .bad
    mov eax, 414
    jmp .close_with
.version:
    lea rdi, [str_hd_http1]
    call hd_word
    jnc .minor
    lea rdi, [str_hd_http]
    call hd_word
    jc .bad
    mov eax, 505
    jmp .close_with
.minor:
    movzx r14d, byte [rsi]              ; R14 = the minor version
    sub r14d, '0'
    cmp r14d, 9
    ja .bad
    inc rsi
    cmp byte [rsi], 13
    je .lines
    cmp byte [rsi], 10
    jne .bad
.lines:                                 ; each header line
    mov al, [rsi]
    test al, al
    jz .headers_done
    inc rsi
    cmp al, 10
    jne .lines
    lea rdi, [str_h_connection]
    call http_prefix
    jc .length
    lea rdi, [str_h_close]
    call http_line_has
    jc .keep_alive
    mov byte [hd_conn_close], 1
    jmp .lines
.keep_alive:
    lea rdi, [str_h_keep_alive]
    call http_line_has
    jc .lines
    mov byte [hd_conn_keep], 1
    jmp .lines
.length:
    lea rdi, [str_h_length]
    call http_prefix
    jc .te
.space:
    cmp byte [rsi], ' '
    jne .number
    inc rsi
    jmp .space
.number:
    xor eax, eax
    xor ecx, ecx                        ; digits
.digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .number_end
    cmp ecx, 15
    jae .bad
    imul rax, rax, 10
    add rax, rdx
    inc ecx
    inc rsi
    jmp .digit
.number_end:
    test ecx, ecx
    jz .bad
    mov [hd_clen], rax
    jmp .lines
.te:
    lea rdi, [str_h_te]
    call http_prefix
    jc .lines
    mov byte [hd_te], 1
    jmp .lines
.headers_done:
    test r14d, r14d                     ; kept? HTTP/1.1 unless "close";
    jz .one_oh                          ; HTTP/1.0 only with "keep-alive"
    cmp byte [hd_conn_close], 0
    je .kept
    jmp .closing
.one_oh:
    cmp byte [hd_conn_keep], 0
    je .closing
    cmp byte [hd_conn_close], 0
    jne .closing
    mov byte [hd_ka_echo], 1
    jmp .kept
.closing:
    or dword [rbx + HV_FLAGS], HVF_CLOSE
.kept:
    cmp byte [hd_te], 0                 ; a body in chunks: where it ends is
    je .body                            ; not worked out here
    mov eax, 501
    jmp .close_with
.body:
    mov rax, [hd_clen]
    mov [rbx + HV_SKIP], rax
    lea rsi, [hd_mbuf]
    lea rdi, [str_hd_get]
    call streq
    mov r15d, eax                       ; R15: 1 for GET, 2 for HEAD, 0 neither
    lea rdi, [str_hd_head]
    call streq
    test eax, eax
    jz .method
    mov r15d, 2
.method:
    mov [hd_meth], r15b
    test r15d, r15d
    jnz .path
    mov eax, 405
    jmp .answer
.path:
    call hd_decode
    jc .bad
    call hd_serve
    jmp .out
.bad:
    mov eax, 400
.close_with:
    or dword [rbx + HV_FLAGS], HVF_CLOSE
.answer:
    call hd_error
.out:
    pop r15
    pop r14
    pop r13
    ret

; hd_token(RSI = text, RDI = to, ECX = most) -> the text up to a space,
; copied and NUL-ended, RSI past the space; CF if the line ends first (EAX
; = 0) or it is longer (EAX = 1). Preserves others.
hd_token:
    push rcx
    push rdi
.next:
    mov al, [rsi]
    cmp al, ' '
    je .end
    jb .short
    test ecx, ecx
    jz .long
    mov [rdi], al
    inc rdi
    inc rsi
    dec ecx
    jmp .next
.end:
    mov byte [rdi], 0
    inc rsi
    pop rdi
    pop rcx
    clc
    ret
.short:
    xor eax, eax
    jmp .fail
.long:
    mov eax, 1
.fail:
    mov byte [rdi], 0
    pop rdi
    pop rcx
    stc
    ret

; hd_word(RSI = text, RDI = a prefix) -> RSI past it; CF if the text does not
; start with it (exactly). Preserves others.
hd_word:
    push rax
    push rcx
    xor ecx, ecx
.next:
    mov al, [rdi + rcx]
    test al, al
    jz .match
    cmp al, [rsi + rcx]
    jne .no
    inc ecx
    jmp .next
.match:
    add rsi, rcx
    pop rcx
    pop rax
    clc
    ret
.no:
    pop rcx
    pop rax
    stc
    ret

; hd_decode: hd_target -> hd_path: the path alone (no query), %XX undone;
; CF if it is not a path from the root, or it would climb out of it
hd_decode:
    push rsi
    push rdi
    lea rsi, [hd_target]
    lea rdi, [hd_path]
    cmp byte [rsi], '/'
    jne .bad
.next:
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, '?'
    je .end
    cmp al, '#'
    je .end
    inc rsi
    cmp al, '%'
    jne .put
    call .hex
    jc .bad
    shl al, 4
    mov ah, al
    call .hex
    jc .bad
    or al, ah
    jz .bad
.put:
    cmp al, '\'
    je .bad
    cmp al, ' '
    jb .bad
    cmp al, 0x7F
    je .bad
    mov [rdi], al
    inc rdi
    jmp .next
.end:
    mov byte [rdi], 0
    lea rsi, [hd_path]                  ; no "/.." part
.dots:
    mov al, [rsi]
    test al, al
    jz .ok
    inc rsi
    cmp al, '/'
    jne .dots
    cmp word [rsi], '..'
    jne .dots
    mov al, [rsi + 2]
    test al, al
    jz .bad
    cmp al, '/'
    je .bad
    jmp .dots
.ok:
    pop rdi
    pop rsi
    clc
    ret
.bad:
    pop rdi
    pop rsi
    stc
    ret
; .hex: [RSI] -> AL = its value, RSI on; CF if it is not a hex digit
.hex:
    mov al, [rsi]
    inc rsi
    or al, 0x20
    sub al, '0'
    cmp al, 9
    jbe .digit
    sub al, 'a' - '0'
    cmp al, 5
    ja .not_hex
    add al, 10
.digit:
    clc
    ret
.not_hex:
    stc
    ret

; hd_serve: hd_path, from the current volume
hd_serve:
    push r14
    push r15
    mov r14, [vol_current]
    test r14, r14
    jz .unavailable
    cmp dword [r14 + VO_FS], FS_FAT32
    jne .unavailable
    cmp byte [r14 + VF_MOUNTED], 0
    je .unavailable
    mov byte [fat_ioerr], 0
    lea rsi, [hd_path]
    call hd_resolve
    jc .missing
    test byte [fat_ent + 11], 0x10
    jz .file
    mov r15d, eax                       ; a directory: R15D = its cluster
    lea rdi, [hd_path]
    call strlen
    cmp byte [rdi + rax - 1], '/'
    jne .redirect
    cmp eax, 200
    ja .listing
    push rax
    lea rdi, [hd_path]
    lea rsi, [str_hd_index]
    call strcat
    lea rsi, [hd_path]
    call hd_resolve
    pop rcx
    jc .no_index
    test byte [fat_ent + 11], 0x10
    jnz .no_index
    call hd_file
    jmp .out
.no_index:
    lea rax, [hd_path]
    mov byte [rax + rcx], 0
    cmp byte [fat_ioerr], 0
    jne .error
.listing:
    mov edi, r15d
    call hd_listing
    jmp .out
.file:
    call hd_file
    jmp .out
.redirect:
    lea rsi, [hd_path]
    SPRINTF hd_extra, `Location: %s/\r\n`, rsi
    mov eax, 301
    call hd_error
    jmp .out
.missing:
    cmp byte [fat_ioerr], 0
    jne .error
    mov eax, 404
    call hd_error
    jmp .out
.error:
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    mov eax, 500
    call hd_error
    jmp .out
.unavailable:
    mov eax, 503
    call hd_error
.out:
    pop r15
    pop r14
    ret

; hd_resolve(R14, RSI = path): fat_resolve without a word if it is not there
hd_resolve:
    mov byte [fat_hush], 1
    call fat_resolve
    mov byte [fat_hush], 0
    ret

; hd_file(R14): the file at hd_path, whose entry is in fat_ent
hd_file:
    mov ecx, [fat_ent + 28]
    cmp rcx, HV_FILE_MAX
    ja .too_big
    lea rsi, [hd_path]
    call hd_type
    mov eax, 200
    xor edx, edx
    push rcx
    call hd_begin
    pop rcx
    jc .out
    test rdi, rdi
    jz .out                             ; HEAD
    test rcx, rcx
    jz .out
    lea rsi, [hd_path]
    mov byte [fat_hush], 1
    call fat_read_file
    mov byte [fat_hush], 0
    jc .failed
    cmp rax, rcx
    jne .failed
.out:
    ret
.failed:                                ; the drive let it down: not that
    mov rdi, [rbx + HV_RESP]            ; answer (none of it has gone), but 500
    call kfree
    mov qword [rbx + HV_RESP], 0
    lea rax, [hd_path]
    KLOG "httpd: %s could not be read", rax
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    mov eax, 500
    jmp hd_error
.too_big:
    lea rax, [hd_path]
    mov edx, HV_FILE_MAX
    KLOG "httpd: %s is more than the %b served", rax, rdx
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    mov eax, 500
    jmp hd_error

; hd_listing(R14, EDI = the directory's cluster): its files, as HTML
hd_listing:
    push r15
    call dir_open
    lea r15, [hd_list]                  ; R15 = where it is written to
    lea rsi, [str_hd_l1]
    call hd_put
    lea rsi, [hd_path]
    call hd_put_html
    lea rsi, [str_hd_l2]
    call hd_put
    lea rsi, [hd_path]
    call hd_put_html
    lea rsi, [str_hd_l3]
    call hd_put
.next:
    call dir_next
    jc .end
    cmp word [fat_name], '.'
    je .next
    cmp word [fat_name], '..'
    jne .entry
    cmp byte [fat_name + 2], 0
    je .next
.entry:
    lea rax, [hd_list + HV_LIST_MAX - 2048]
    cmp r15, rax
    jae .full
    lea rsi, [str_hd_li]
    call hd_put
    lea rsi, [fat_name]
    call hd_put_url
    test byte [fat_ent + 11], 0x10
    jz .quote
    mov byte [r15], '/'
    inc r15
.quote:
    lea rsi, [str_hd_li2]
    call hd_put
    lea rsi, [fat_name]
    call hd_put_html
    test byte [fat_ent + 11], 0x10
    jz .file
    lea rsi, [str_hd_dir_end]
    call hd_put
    jmp .next
.file:
    mov eax, [fat_ent + 28]
    SPRINTF r15, `</a> %b\n`, rax
    add r15, rax
    jmp .next
.full:
    lea rsi, [str_hd_more]
    call hd_put
.end:
    cmp byte [fat_ioerr], 0
    jne .failed
    lea rsi, [str_hd_l4]
    call hd_put
    lea rcx, [hd_list]
    sub r15, rcx                        ; R15 = the bytes
    mov rcx, r15
    lea rsi, [str_hd_html]
    mov eax, 200
    xor edx, edx
    call hd_begin
    jc .out
    test rdi, rdi
    jz .out
    lea rsi, [hd_list]
    mov rcx, r15
    rep movsb
    jmp .out
.failed:
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    mov eax, 500
    call hd_error
.out:
    pop r15
    ret

; hd_put(RSI = a string): at R15, which moves on. Preserves others.
hd_put:
    push rax
.next:
    mov al, [rsi]
    test al, al
    jz .out
    mov [r15], al
    inc r15
    inc rsi
    jmp .next
.out:
    pop rax
    ret

; hd_put_html(RSI): the same, with & < > " written as HTML has them
hd_put_html:
    push rax
    push rsi
.next:
    mov al, [rsi]
    test al, al
    jz .out
    inc rsi
    cmp al, '&'
    je .amp
    cmp al, '<'
    je .lt
    cmp al, '>'
    je .gt
    cmp al, '"'
    je .quot
    mov [r15], al
    inc r15
    jmp .next
.amp:
    push rsi
    lea rsi, [str_hd_amp]
    jmp .entity
.lt:
    push rsi
    lea rsi, [str_hd_lt]
    jmp .entity
.gt:
    push rsi
    lea rsi, [str_hd_gt]
    jmp .entity
.quot:
    push rsi
    lea rsi, [str_hd_quot]
.entity:
    call hd_put
    pop rsi
    jmp .next
.out:
    pop rsi
    pop rax
    ret

; hd_put_url(RSI): the same, as a URL's path has it (%XX but for letters,
; digits and - . _ ~)
hd_put_url:
    push rax
    push rcx
    push rsi
.next:
    mov al, [rsi]
    test al, al
    jz .out
    inc rsi
    mov cl, al
    or cl, 0x20
    cmp cl, 'a'
    jb .digit
    cmp cl, 'z'
    jbe .plain
.digit:
    cmp al, '0'
    jb .mark
    cmp al, '9'
    jbe .plain
.mark:
    cmp al, '-'
    je .plain
    cmp al, '.'
    je .plain
    cmp al, '_'
    je .plain
    cmp al, '~'
    je .plain
    mov byte [r15], '%'
    push rdx
    lea rdx, [hex_digits]
    movzx ecx, al
    shr ecx, 4
    mov cl, [rdx + rcx]
    mov [r15 + 1], cl
    movzx ecx, al
    and ecx, 15
    mov cl, [rdx + rcx]
    mov [r15 + 2], cl
    pop rdx
    add r15, 3
    jmp .next
.plain:
    mov [r15], al
    inc r15
    jmp .next
.out:
    pop rsi
    pop rcx
    pop rax
    ret

; hd_type(RSI = a path) -> RSI = its media type, from its extension.
; Preserves others.
hd_type:
    push rax
    push rdi
    push r8
    xor r8d, r8d                        ; just past the last '.', after any '/'
.scan:
    mov al, [rsi]
    test al, al
    jz .scanned
    inc rsi
    cmp al, '/'
    jne .dot
    xor r8d, r8d
    jmp .scan
.dot:
    cmp al, '.'
    jne .scan
    mov r8, rsi
    jmp .scan
.scanned:
    lea rdi, [hd_types]
    test r8, r8
    jz .default
.next:
    mov rax, [rdi]
    test rax, rax
    jz .default
    mov rsi, r8
    push rdi
    mov rdi, rax
    call http_prefix
    pop rdi
    jc .on
    cmp byte [rsi], 0
    je .found
.on:
    add rdi, 16
    jmp .next
.found:
    mov rsi, [rdi + 8]
    jmp .out
.default:
    lea rsi, [str_hd_binary]
.out:
    pop r8
    pop rdi
    pop rax
    ret

; hd_phrase(EAX = a status) -> RAX = its reason phrase. Preserves others.
hd_phrase:
    push rsi
    lea rsi, [hd_phrases]
.next:
    cmp dword [rsi], 0
    je .found
    cmp [rsi], eax
    je .found
    add rsi, 16
    jmp .next
.found:
    mov rax, [rsi + 8]
    pop rsi
    ret

; hd_error(EAX = a status): an answer of that, with a line of text; for
; 301, hd_extra holds its Location
hd_error:
    push r13
    mov r13d, eax
    lea rdx, [hd_extra]
    cmp eax, 301
    je .said
    lea rdx, [str_hd_allow]
    cmp eax, 405
    je .said
    xor edx, edx
.said:
    call hd_phrase
    SPRINTF hd_ebody, `%u %s\n`, r13, rax
    mov ecx, eax
    lea rsi, [str_hd_text]
    mov eax, r13d
    push rcx
    call hd_begin
    pop rcx
    jc .out
    test rdi, rdi
    jz .out
    lea rsi, [hd_ebody]
    rep movsb
.out:
    pop r13
    ret

; hd_begin(EAX = the status, RSI = the media type, RCX = the body's bytes,
; RDX = more header lines or 0) -> RDI = where the body goes in HV_RESP,
; 0 for HEAD (headers alone); CF if there is no memory for it (then the
; connection is closed without an answer)
hd_begin:
    push r8
    push r9
    push r10
    push r13
    push r14
    push r15
    mov r13d, eax                       ; R13 = the status
    mov r14, rcx                        ; R14 = the body's bytes
    mov r15, rsi                        ; R15 = the type
    test rdx, rdx
    jnz .extra
    lea rdx, [str_hd_none]
.extra:
    call hd_phrase
    mov r8, rax
    lea r9, [str_hd_none]
    test dword [rbx + HV_FLAGS], HVF_CLOSE
    jz .keep
    lea r9, [str_hd_conn_close]
    jmp .made
.keep:
    cmp byte [hd_ka_echo], 0
    je .made
    lea r9, [str_hd_conn_keep]
.made:
    SPRINTF hd_head, `HTTP/1.1 %u %s\r\nServer: Axiom\r\nContent-Type: %s\r\nContent-Length: %u\r\n%s%s\r\n`, r13, r8, r15, r14, rdx, r9
    mov r10d, eax                       ; R10 = the headers' bytes
    mov rdi, r10
    cmp byte [hd_meth], 2
    je .size
    add rdi, r14
.size:
    mov r9, rdi
    call kmalloc
    test rax, rax
    jz .no_memory
    mov [rbx + HV_RESP], rax
    mov [rbx + HV_RLEN], r9
    mov qword [rbx + HV_SENT], 0
    mov rdi, rax
    lea rsi, [hd_head]
    mov ecx, r10d
    rep movsb
    lea rax, [r12 + TC_RA]
    KLOG "httpd: %A %s %s: %u, %b", rax, qword [hd_mtext], qword [hd_target_p], r13, r14
    cmp byte [hd_meth], 2
    jne .body
    xor edi, edi
.body:
    clc
    jmp .out
.no_memory:                             ; no answer: the connection ends
    KLOG "httpd: no memory for an answer of %b", r9
    or dword [rbx + HV_FLAGS], HVF_CLOSE
    xor edi, edi
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r10
    pop r9
    pop r8
    ret

section .rodata
str_hd_stop:    db 'stop', 0
str_hd_q:       db '?', 0
str_hd_get:     db 'GET', 0
str_hd_head:    db 'HEAD', 0
str_hd_http1:   db 'HTTP/1.', 0
str_hd_http:    db 'HTTP/', 0
str_hd_index:   db 'index.html', 0
str_hd_none:    db 0
str_hd_conn_close: db `Connection: close\r\n`, 0
str_hd_conn_keep: db `Connection: keep-alive\r\n`, 0
str_hd_allow:   db `Allow: GET, HEAD\r\n`, 0
str_hd_text:    db 'text/plain; charset=utf-8', 0
str_hd_html:    db 'text/html; charset=utf-8', 0
str_hd_binary:  db 'application/octet-stream', 0
str_hd_l1:      db `<!doctype html>\n<meta charset="utf-8">\n<title>`, 0
str_hd_l2:      db `</title>\n<h1>`, 0
str_hd_l3:      db `</h1>\n<ul>\n`, 0
str_hd_l4:      db `</ul>\n`, 0
str_hd_li:      db '<li><a href="', 0
str_hd_li2:     db '">', 0
str_hd_dir_end: db `/</a>\n`, 0
str_hd_more:    db `<li>(and more)\n`, 0
str_hd_amp:     db '&amp;', 0
str_hd_lt:      db '&lt;', 0
str_hd_gt:      db '&gt;', 0
str_hd_quot:    db '&quot;', 0

str_ht_html:    db 'html', 0
str_ht_htm:     db 'htm', 0
str_ht_txt:     db 'txt', 0
str_ht_log:     db 'log', 0
str_ht_md:      db 'md', 0
str_ht_asm:     db 'asm', 0
str_ht_inc:     db 'inc', 0
str_ht_py:      db 'py', 0
str_ht_json:    db 'json', 0
str_ht_css:     db 'css', 0
str_ht_js:      db 'js', 0
str_ht_png:     db 'png', 0
str_ht_jpg:     db 'jpg', 0
str_ht_jpeg:    db 'jpeg', 0
str_ht_gif:     db 'gif', 0
str_ht_svg:     db 'svg', 0
str_ht_pdf:     db 'pdf', 0
str_mt_plain:   db 'text/plain; charset=utf-8', 0
str_mt_md:      db 'text/markdown; charset=utf-8', 0
str_mt_json:    db 'application/json', 0
str_mt_css:     db 'text/css', 0
str_mt_js:      db 'text/javascript', 0
str_mt_png:     db 'image/png', 0
str_mt_jpeg:    db 'image/jpeg', 0
str_mt_gif:     db 'image/gif', 0
str_mt_svg:     db 'image/svg+xml', 0
str_mt_pdf:     db 'application/pdf', 0

str_hp_200:     db 'OK', 0
str_hp_301:     db 'Moved Permanently', 0
str_hp_400:     db 'Bad Request', 0
str_hp_404:     db 'Not Found', 0
str_hp_405:     db 'Method Not Allowed', 0
str_hp_414:     db 'URI Too Long', 0
str_hp_431:     db 'Request Header Fields Too Large', 0
str_hp_500:     db 'Internal Server Error', 0
str_hp_501:     db 'Not Implemented', 0
str_hp_503:     db 'Service Unavailable', 0
str_hp_505:     db 'HTTP Version Not Supported', 0
str_hp_other:   db 'Error', 0

align 8
hd_ops:         dq hd_open, hd_data, hd_fin, hd_gone
hd_types:       dq str_ht_html, str_hd_html, str_ht_htm, str_hd_html
                dq str_ht_txt, str_mt_plain, str_ht_log, str_mt_plain
                dq str_ht_md, str_mt_md, str_ht_asm, str_mt_plain
                dq str_ht_inc, str_mt_plain, str_ht_py, str_mt_plain
                dq str_ht_json, str_mt_json, str_ht_css, str_mt_css
                dq str_ht_js, str_mt_js, str_ht_png, str_mt_png
                dq str_ht_jpg, str_mt_jpeg, str_ht_jpeg, str_mt_jpeg
                dq str_ht_gif, str_mt_gif, str_ht_svg, str_mt_svg
                dq str_ht_pdf, str_mt_pdf
                dq 0, 0
hd_phrases:     dd 200, 0
                dq str_hp_200
                dd 301, 0
                dq str_hp_301
                dd 400, 0
                dq str_hp_400
                dd 404, 0
                dq str_hp_404
                dd 405, 0
                dq str_hp_405
                dd 414, 0
                dq str_hp_414
                dd 431, 0
                dq str_hp_431
                dd 500, 0
                dq str_hp_500
                dd 501, 0
                dq str_hp_501
                dd 503, 0
                dq str_hp_503
                dd 505, 0
                dq str_hp_505
                dd 0, 0
                dq str_hp_other
hd_target_p:    dq hd_target

section .bss
alignb 8
hd_listener:    resq 1
hd_port:        resq 1
hd_requests:    resq 1
hd_bytes:       resq 1                  ; handed to TCP
hd_clen:        resq 1                  ; the request's Content-Length
hd_mtext:       resq 1                  ; its method, for the log
hd_live:        resd 1                  ; connections with state
hd_meth:        resb 1                  ; 1 GET, 2 HEAD
hd_conn_close:  resb 1
hd_conn_keep:   resb 1
hd_te:          resb 1
hd_ka_echo:     resb 1                  ; HTTP/1.0 kept: say so
hd_mbuf:        resb 16
hd_target:      resb 264
hd_path:        resb 280
hd_extra:       resb 320
hd_head:        resb 1024
hd_ebody:       resb 64
alignb 16
hd_list:        resb HV_LIST_MAX
alignb 64
hd_conns:       resb MAX_TCP * HV_SIZE
