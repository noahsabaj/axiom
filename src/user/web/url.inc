; =============================================================================
;  web/url.inc - URLs: taken apart, and made whole from a link on a page
;
;  A URL here (U_*): http or https, a host, a port, and its path with any
;  query; the fragment is kept apart (U_FRAG), for the page to scroll to.
;    url_parse(RSI = NUL-ended text, RDI = a URL) -> CF if it is not one we
;      can fetch. "host/path" with no scheme is taken as https (http for a
;      dotted quad or localhost). The path's "." and ".." are undone.
;    url_resolve(RSI = an href, ECX = its bytes, RDX = the URL it is on,
;      RDI = U_TEXT_MAX bytes) -> that link as a whole URL, NUL-ended; CF
;      if it goes nowhere we fetch (mailto:, javascript:, ...)
;    url_copy(RDI = to, RSI = from)
; =============================================================================

U_SCHEME        equ 0                   ; dword: 0 http, 1 https
U_PORT          equ 4                   ; dword
U_HOST          equ 8                   ; 256 bytes, NUL-ended, lower case
U_PATH          equ 264                 ; from '/', with the query
U_FRAG          equ U_PATH + U_TEXT_MAX ; after '#', NUL-ended
U_TEXT          equ U_FRAG + 256        ; the whole URL, without the fragment
U_SIZE          equ U_TEXT + U_TEXT_MAX
U_TEXT_MAX      equ 4096

section .text

url_parse:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
.blank:
    cmp byte [r12], ' '
    jne .scheme
    inc r12
    jmp .blank
.scheme:
    mov rsi, r12
    lea rdi, [s_http_sep]
    call ci_starts
    jne .not_http
    mov dword [rbx + U_SCHEME], 0
    mov dword [rbx + U_PORT], 80
    add r12, rax
    jmp .authority
.not_http:
    lea rdi, [s_https_sep]
    call ci_starts
    jne .bare
    mov dword [rbx + U_SCHEME], 1
    mov dword [rbx + U_PORT], 443
    add r12, rax
    jmp .authority
.bare:                                  ; no scheme of ours: "x:" before any
    mov rsi, r12                        ; '/' is one of another kind, unless
.colon:                                 ; digits follow it (a port)
    mov al, [rsi]
    test al, al
    jz .guess
    cmp al, '/'
    je .guess
    cmp al, ':'
    je .after_colon
    inc rsi
    jmp .colon
.after_colon:
    inc rsi
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .bad
.guess:
    mov dword [rbx + U_SCHEME], 1       ; https, but for an address or localhost
    mov dword [rbx + U_PORT], 443
    movzx eax, byte [r12]
    sub eax, '0'
    cmp eax, 9
    jbe .plain
    mov rsi, r12
    lea rdi, [s_localhost]
    call ci_starts
    jne .authority
.plain:
    mov dword [rbx + U_SCHEME], 0
    mov dword [rbx + U_PORT], 80
.authority:                             ; who ("user:password@"): dropped
    mov rsi, r12
.at_scan:
    mov al, [rsi]
    test al, al
    jz .host_start
    cmp al, '/'
    je .host_start
    cmp al, '?'
    je .host_start
    cmp al, '#'
    je .host_start
    cmp al, '@'
    jne .at_next
    lea r12, [rsi + 1]
.at_next:
    inc rsi
    jmp .at_scan
.host_start:                            ; the host, lower case, up to : / ? #
    lea rdi, [rbx + U_HOST]
    xor ecx, ecx
.host:
    mov al, [r12]
    test al, al
    jz .hosted
    cmp al, '/'
    je .hosted
    cmp al, '?'
    je .hosted
    cmp al, '#'
    je .hosted
    cmp al, ':'
    je .hosted
    call to_lower
    cmp ecx, 255
    jae .bad
    mov [rdi + rcx], al
    inc ecx
    inc r12
    jmp .host
.hosted:
    test ecx, ecx
    jz .bad
    mov byte [rdi + rcx], 0
    cmp byte [r12], ':'
    jne .path
    inc r12
    mov rsi, r12
    mov ecx, 6
    call dec_parse
    jc .path                            ; "host:" alone: the default
    mov r12, rsi
    test eax, eax
    jz .bad
    cmp eax, 65535
    ja .bad
    mov [rbx + U_PORT], eax
.path:                                  ; '/' first; spaces as %20
    lea rdi, [rbx + U_PATH]
    xor ecx, ecx
    cmp byte [r12], '/'
    je .path_char
    mov byte [rdi], '/'
    inc ecx
.path_char:
    mov al, [r12]
    test al, al
    jz .pathed
    cmp al, '#'
    je .pathed
    cmp ecx, U_TEXT_MAX - 4
    jae .bad
    cmp al, ' '
    je .space
    cmp al, 9
    je .skip
    cmp al, 13
    je .skip
    cmp al, 10
    je .skip
    mov [rdi + rcx], al
    inc ecx
.skip:
    inc r12
    jmp .path_char
.space:
    mov dword [rdi + rcx], '%20'
    add ecx, 3
    inc r12
    jmp .path_char
.pathed:
    mov byte [rdi + rcx], 0
    mov byte [rbx + U_FRAG], 0
    cmp byte [r12], '#'
    jne .normal
    inc r12
    lea rdi, [rbx + U_FRAG]
    mov rsi, r12
    mov ecx, 256
    call str_copy
.normal:
    lea rdi, [rbx + U_PATH]
    call path_norm
    mov rdi, rbx
    call url_text
    clc
    jmp .out
.bad:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; url_text(RDI = a URL): its U_TEXT, from the rest
url_text:
    push rbx
    mov rbx, rdi
    lea rax, [rbx + U_TEXT]
    mov [out_ptr], rax
    add rax, U_TEXT_MAX - 1
    mov [out_end], rax
    call url_origin
    lea rsi, [rbx + U_PATH]
    call put_str
    pop rbx
    ret

; url_origin(RBX = a URL): "scheme://host[:port]" onto out_ptr
url_origin:
    lea rsi, [s_http_sep]
    cmp dword [rbx + U_SCHEME], 0
    je .scheme
    lea rsi, [s_https_sep]
.scheme:
    call put_str
    lea rsi, [rbx + U_HOST]
    call put_str
    mov eax, 80
    cmp dword [rbx + U_SCHEME], 0
    je .default
    mov eax, 443
.default:
    cmp [rbx + U_PORT], eax
    je .out
    lea rsi, [s_colon]
    call put_str
    mov edi, [rbx + U_PORT]
    call put_u
.out:
    ret

; path_norm(RDI = a path from '/', NUL-ended, with any query): "." and ".."
; undone in the path, in place
path_norm:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi                        ; RBX: read, at a '/' or the end
    mov r12, rdi                        ; R12: written
    mov r13, rdi                        ; R13: the start
.segment:
    mov al, [rbx]
    test al, al
    jz .end
    cmp al, '?'
    je .query
    lea r14, [rbx + 1]                  ; [R14, RSI): the segment
    mov rsi, r14
.seg_end:
    mov al, [rsi]
    test al, al
    jz .seg_done
    cmp al, '/'
    je .seg_done
    cmp al, '?'
    je .seg_done
    inc rsi
    jmp .seg_end
.seg_done:
    mov rcx, rsi
    sub rcx, r14
    mov rbx, rsi
    cmp rcx, 1
    jne .not_dot
    cmp byte [r14], '.'
    je .dropped                         ; ".": nothing
.not_dot:
    cmp rcx, 2
    jne .keep
    cmp word [r14], '..'
    jne .keep
.back:                                  ; "..": the last segment written goes
    cmp r12, r13
    je .dropped
    dec r12
    cmp byte [r12], '/'
    jne .back
.dropped:                               ; at the path's end, a '/' stays
    cmp byte [rbx], '/'
    je .segment
    mov byte [r12], '/'
    inc r12
    jmp .segment
.keep:
    mov byte [r12], '/'
    inc r12
.keep_char:
    cmp r14, rbx
    jae .segment
    mov al, [r14]
    mov [r12], al
    inc r14
    inc r12
    jmp .keep_char
.query:
    cmp r12, r13                        ; nothing left of the path: "/"
    jne .query_copy
    mov byte [r12], '/'
    inc r12
.query_copy:
    mov al, [rbx]
    mov [r12], al
    test al, al
    jz .done
    inc rbx
    inc r12
    jmp .query_copy
.end:
    cmp r12, r13
    jne .ended
    mov byte [r12], '/'
    inc r12
.ended:
    mov byte [r12], 0
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

url_resolve:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi                        ; R12, R13D: the href, trimmed
    mov r13d, ecx
    mov rbx, rdx                        ; RBX: the URL it is on
    mov [out_ptr], rdi
    lea rax, [rdi + U_TEXT_MAX - 1]
    mov [out_end], rax
    mov byte [rdi], 0
.trim_front:
    test r13d, r13d
    jz .here
    cmp byte [r12], ' '
    ja .trim_back
    inc r12
    dec r13d
    jmp .trim_front
.trim_back:
    cmp byte [r12 + r13 - 1], ' '
    ja .trimmed
    dec r13d
    jmp .trim_back
.trimmed:
    mov rsi, r12                        ; a scheme: letters, then ':'
    xor ecx, ecx
.scheme:
    cmp ecx, r13d
    jae .relative
    mov al, [rsi + rcx]
    cmp al, ':'
    je .has_scheme
    call to_lower
    cmp al, 'a'
    jb .relative
    cmp al, 'z'
    jbe .letter
    cmp al, '+'
    je .letter
    cmp al, '-'
    je .letter
    cmp al, '.'
    jne .relative
.letter:
    inc ecx
    jmp .scheme
.has_scheme:
    test ecx, ecx
    jz .relative
    mov rsi, r12
    lea rdi, [s_http_sep]
    mov ecx, r13d
    call ci_prefix_n
    je .whole
    lea rdi, [s_https_sep]
    call ci_prefix_n
    je .whole
    stc                                 ; mailto:, javascript:, data:, ...
    jmp .out
.whole:
    mov rsi, r12
    mov ecx, r13d
    call put_n
    clc
    jmp .out
.relative:
    cmp r13d, 2
    jb .not_net
    cmp word [r12], '//'
    jne .not_net
    lea rsi, [s_http]                   ; "//host/...": this page's scheme
    cmp dword [rbx + U_SCHEME], 0
    je .net_scheme
    lea rsi, [s_https]
.net_scheme:
    call put_str
    mov rsi, r12
    mov ecx, r13d
    call put_n
    clc
    jmp .out
.not_net:
    call url_origin
    cmp byte [r12], '/'
    je .tail                            ; "/path": from the root
    cmp byte [r12], '?'
    je .query
    cmp byte [r12], '#'
    je .fragment
    lea rsi, [rbx + U_PATH]             ; "path": beside this page, after its
    mov rcx, rsi                        ; last '/' before the query
    xor edx, edx
.last_slash:
    mov al, [rcx]
    test al, al
    jz .dir
    cmp al, '?'
    je .dir
    cmp al, '/'
    jne .next_char
    lea rdx, [rcx + 1]
.next_char:
    inc rcx
    jmp .last_slash
.dir:
    mov rcx, rdx
    sub rcx, rsi
    call put_n
    jmp .tail
.query:                                 ; "?q": this path, a new query
    lea rsi, [rbx + U_PATH]
    xor ecx, ecx
.path_len:
    mov al, [rsi + rcx]
    test al, al
    jz .path_put
    cmp al, '?'
    je .path_put
    inc ecx
    jmp .path_len
.path_put:
    call put_n
    jmp .tail
.fragment:                              ; "#f": this page
    lea rsi, [rbx + U_PATH]
    call put_str
.tail:
    mov rsi, r12
    mov ecx, r13d
    call put_n
    clc
    jmp .out
.here:                                  ; "": this page
    call url_origin
    lea rsi, [rbx + U_PATH]
    call put_str
    clc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ci_prefix_n(RSI = bytes, ECX = how many, RDI = lower-case NUL-ended) ->
; ZF if they begin with it. Preserves all but RAX.
ci_prefix_n:
    push rcx
    push rsi
    push rdi
.char:
    cmp byte [rdi], 0
    je .yes
    test ecx, ecx
    jz .no
    mov al, [rsi]
    call to_lower
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.no:
    or eax, 1                           ; ZF clear
    jmp .out
.yes:
    cmp eax, eax
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

url_copy:
    mov ecx, U_SIZE
    rep movsb
    ret

section .rodata
s_http_sep:     db 'http://', 0
s_https_sep:    db 'https://', 0
s_http:         db 'http:', 0
s_https:        db 'https:', 0
s_localhost:    db 'localhost', 0
s_colon:        db ':', 0

section .text
