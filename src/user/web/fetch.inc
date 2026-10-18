; =============================================================================
;  web/fetch.inc - one GET, over HTTP/1.1, plain or TLS (the socket's)
;
;    fetch(RDI = a URL) -> RAX = the status (200, 404, ...), or -1 if there
;      was no answer (fetch_why says why, NUL-ended). Then resp_body and
;      resp_len are the body (chunks undone), resp_type the Content-Type
;      and resp_loc the Location, each a pointer and a length (0 if none),
;      all in resp_buf until the next fetch.
;  The request asks for the body as it is (no compression) and for the
;  connection to end after it; the answer is read until it ends, or until
;  its Content-Length or last chunk has come, RESP_MAX bytes at most.
; =============================================================================

RESP_MAX        equ 16 << 20

section .text

fetch:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    xor eax, eax
    mov [resp_len], rax
    mov [resp_type], rax
    mov [resp_type_len], rax
    mov [resp_loc], rax
    mov [resp_loc_len], rax
    mov [resp_hdr_end], rax
    mov [resp_cl], rax
    mov byte [resp_chunked], 0
    mov rax, [resp_buf]
    mov [resp_body], rax
    lea rax, [req_buf]                  ; the request
    mov [out_ptr], rax
    add rax, REQ_MAX - 1
    mov [out_end], rax
    lea rsi, [s_get_sp]
    call put_str
    lea rsi, [rbx + U_PATH]
    call put_str
    lea rsi, [s_req_host]
    call put_str
    lea rsi, [rbx + U_HOST]
    call put_str
    mov eax, 80
    cmp dword [rbx + U_SCHEME], 0
    je .default_port
    mov eax, 443
.default_port:
    cmp [rbx + U_PORT], eax
    je .host_done
    lea rsi, [s_colon]
    call put_str
    mov edi, [rbx + U_PORT]
    call put_u
.host_done:
    lea rsi, [s_req_rest]
    call put_str

    mov edi, [ax_net]                   ; the connection
    lea rsi, [rbx + U_HOST]
    mov edx, [rbx + U_PORT]
    xor ecx, ecx
    cmp dword [rbx + U_SCHEME], 0
    je .plain
    mov ecx, NETF_TLS
.plain:
    call connect
    test rax, rax
    js .refused
    mov r12d, eax                       ; R12D: the socket
    mov edi, r12d
    mov esi, 1
    mov edx, WAIT_US
    call wait_on
    mov edi, r12d
    call status
    cmp al, SKS_OPEN
    jne .failed
    mov edi, r12d
    lea rsi, [req_buf]
    mov rdx, [out_ptr]
    sub rdx, rsi
    call send_all
    test rax, rax
    js .failed

    xor r13d, r13d                      ; R13: bytes that came
.recv:
    mov edx, RESP_MAX
    sub rdx, r13
    jz .received
    cmp rdx, CHUNK
    jbe .room
    mov edx, CHUNK
.room:
    mov edi, r12d
    mov rsi, [resp_buf]
    add rsi, r13
    call recv_wait
    test rax, rax
    jle .ended
    mov r14, rax                        ; R14: what just came
    add r13, rax
    cmp qword [resp_hdr_end], 0
    jne .framed
    mov rsi, r13                        ; the headers' end, in what is new
    sub rsi, r14
    sub rsi, 3
    jns .from
    xor esi, esi
.from:
    mov rdi, [resp_buf]
.blank_line:
    lea rax, [rsi + 4]
    cmp rax, r13
    ja .recv
    cmp dword [rdi + rsi], 0x0A0D0A0D
    je .headers
    inc rsi
    jmp .blank_line
.headers:
    add rsi, 4
    mov [resp_hdr_end], rsi
    call headers
.framed:
    cmp byte [resp_chunked], 0
    jne .chunk_end
    mov rax, [resp_cl]
    test rax, rax
    jz .recv
    add rax, [resp_hdr_end]
    cmp r13, rax
    jb .recv
    jmp .received
.chunk_end:                             ; "\n0\r\n\r\n" last (a trailer: the close)
    mov rax, [resp_hdr_end]
    add rax, 5
    cmp r13, rax
    jb .recv
    mov rax, [resp_buf]
    cmp dword [rax + r13 - 4], 0x0A0D0A0D
    jne .recv
    cmp word [rax + r13 - 6], 0x300A    ; '\n', '0'
    jne .recv
    jmp .received
.ended:
    test r13, r13
    jz .failed
.received:
    mov edi, r12d
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
    cmp qword [resp_hdr_end], 0
    je .not_http
    mov rsi, [resp_buf]                 ; "HTTP/1.x NNN"
    mov rdi, rsi
    lea rdi, [s_http_ver]
    call ci_starts
    jne .not_http
    add rsi, 9
    mov ecx, 3
    call dec_parse
    jc .not_http
    mov r15, rax                        ; R15: the status
    mov rax, [resp_buf]                 ; the body
    add rax, [resp_hdr_end]
    mov [resp_body], rax
    mov rcx, r13
    sub rcx, [resp_hdr_end]
    mov [resp_len], rcx
    cmp byte [resp_chunked], 0
    jne .dechunk
    mov rax, [resp_cl]
    test rax, rax
    jz .done
    cmp rax, rcx
    jae .done
    mov [resp_len], rax
    jmp .done
.dechunk:
    call dechunk
.done:
    mov rax, r15
    jmp .out
.not_http:
    lea rsi, [s_why_not_http]
    jmp .why
.refused:
    lea rsi, [s_why_refused]
    jmp .why
.failed:
    mov edi, r12d
    call status
    push rax
    mov edi, r12d
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
    pop rax
    movzx eax, ah                       ; NETW_*
    lea rsi, [s_why_failed]
    cmp eax, NETW_COUNT
    jae .why
    lea rcx, [netw_why]
    mov rsi, [rcx + rax * 8]
.why:
    lea rdi, [fetch_why]
    mov ecx, 128
    call str_copy
    mov rax, -1
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; headers: the header lines in resp_buf up to resp_hdr_end, for what fetch
; needs (framing, type, location)
headers:
    push rbx
    push r12
    push r13
    mov rbx, [resp_buf]
    mov r12, rbx
    add r12, [resp_hdr_end]             ; R12: the end
.line:                                  ; RBX: this line; R13: its end
    mov r13, rbx
.eol:
    cmp r13, r12
    jae .out
    cmp byte [r13], 10
    je .got_line
    inc r13
    jmp .eol
.got_line:
    mov rsi, rbx
    lea rdi, [h_content_length]
    call ci_starts
    jne .not_cl
    lea rsi, [rbx + rax]
    mov rcx, r13
    sub rcx, rsi
    call dec_parse
    jc .next
    mov [resp_cl], rax
    jmp .next
.not_cl:
    lea rdi, [h_transfer_encoding]
    call ci_starts
    jne .not_te
    lea rsi, [rbx + rax]
    mov rcx, r13
    sub rcx, rsi
    lea rdi, [s_chunked]
    call ci_find
    test rax, rax
    jz .next
    mov byte [resp_chunked], 1
    jmp .next
.not_te:
    lea rdi, [h_content_type]
    call ci_starts
    jne .not_ct
    lea rdi, [resp_type]
    jmp .value
.not_ct:
    lea rdi, [h_location]
    call ci_starts
    jne .next
    lea rdi, [resp_loc]
.value:                                 ; RDI: where its pointer and length go
    lea rsi, [rbx + rax]
.value_blank:
    cmp byte [rsi], ' '
    jne .value_end
    inc rsi
    jmp .value_blank
.value_end:
    mov rcx, r13
    cmp byte [rcx - 1], 13
    jne .no_cr
    dec rcx
.no_cr:
    sub rcx, rsi
    jns .value_set
    xor ecx, ecx
.value_set:
    mov [rdi], rsi
    mov [rdi + 8], rcx
.next:
    lea rbx, [r13 + 1]
    jmp .line
.out:
    pop r13
    pop r12
    pop rbx
    ret

; dechunk: resp_body's chunks joined, in place; resp_len their bytes
dechunk:
    push rbx
    push r12
    push r13
    mov rbx, [resp_body]                ; RBX: read; R12: written; R13: end
    mov r12, rbx
    mov r13, rbx
    add r13, [resp_len]
.chunk:
    xor eax, eax                        ; its size, in hex
    xor ecx, ecx
.hex:
    cmp rbx, r13
    jae .end
    movzx edx, byte [rbx]
    cmp edx, '0'
    jb .size_end
    cmp edx, '9'
    jbe .digit
    or edx, 0x20
    cmp edx, 'a'
    jb .size_end
    cmp edx, 'f'
    ja .size_end
    sub edx, 'a' - 10 - '0'
.digit:
    sub edx, '0'
    shl rax, 4
    add rax, rdx
    inc ecx
    inc rbx
    cmp ecx, 12
    jb .hex
    jmp .end
.size_end:
    test ecx, ecx
    jz .end
.to_eol:
    cmp rbx, r13
    jae .end
    cmp byte [rbx], 10
    je .data
    inc rbx
    jmp .to_eol
.data:
    inc rbx
    test rax, rax
    jz .end
    mov rcx, r13
    sub rcx, rbx
    cmp rax, rcx
    jbe .copy
    mov rax, rcx
.copy:
    mov rcx, rax
    mov rsi, rbx
    mov rdi, r12
    rep movsb
    mov rbx, rsi
    mov r12, rdi
    cmp rbx, r13                        ; then its CRLF
    jae .end
    cmp byte [rbx], 13
    jne .lf
    inc rbx
.lf:
    cmp rbx, r13
    jae .end
    cmp byte [rbx], 10
    jne .chunk
    inc rbx
    jmp .chunk
.end:
    sub r12, [resp_body]
    mov [resp_len], r12
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
s_get_sp:       db 'GET ', 0
s_req_host:     db ' HTTP/1.1', 13, 10, 'Host: ', 0
s_req_rest:     db 13, 10, 'User-Agent: Mozilla/5.0 (Axiom; x86_64) browse/1', 13, 10
                db 'Accept: text/html,text/plain;q=0.9,*/*;q=0.5', 13, 10
                db 'Accept-Encoding: identity', 13, 10
                db 'Accept-Language: en', 13, 10
                db 'Connection: close', 13, 10, 13, 10, 0
s_http_ver:     db 'http/1.', 0
h_content_length: db 'content-length:', 0
h_transfer_encoding: db 'transfer-encoding:', 0
h_content_type: db 'content-type:', 0
h_location:     db 'location:', 0
s_chunked:      db 'chunked', 0
s_why_not_http: db 'the answer was not HTTP', 0
s_why_refused:  db 'no connection could be made', 0
s_why_failed:   db 'the connection failed', 0
s_netw_0:       db 'the connection failed', 0
s_netw_1:       db 'no DNS server is known', 0
s_netw_2:       db 'that is not a host name', 0
s_netw_3:       db 'too many lookups at once', 0
s_netw_4:       db 'there is no such host', 0
s_netw_5:       db 'the host has no address', 0
s_netw_6:       db 'the DNS server could not answer', 0
s_netw_7:       db 'no answer from the DNS server', 0
s_netw_8:       db 'there is no network', 0
s_netw_9:       db 'there is no route to the host', 0
s_netw_10:      db 'the connection was refused', 0
s_netw_11:      db 'the connection was reset', 0
s_netw_12:      db 'the connection timed out', 0
s_netw_13:      db 'the secure connection failed (TLS)', 0
NETW_COUNT      equ 14
align 8
netw_why:       dq s_netw_0, s_netw_1, s_netw_2, s_netw_3, s_netw_4, s_netw_5, s_netw_6
                dq s_netw_7, s_netw_8, s_netw_9, s_netw_10, s_netw_11, s_netw_12, s_netw_13

section .bss
REQ_MAX         equ 8192
alignb 8
resp_buf:       resq 1
resp_body:      resq 1
resp_len:       resq 1
resp_type:      resq 1                  ; resp_type, resp_type_len: one pair
resp_type_len:  resq 1
resp_loc:       resq 1
resp_loc_len:   resq 1
resp_hdr_end:   resq 1
resp_cl:        resq 1
resp_chunked:   resb 1
fetch_why:      resb 128
req_buf:        resb REQ_MAX

section .text
