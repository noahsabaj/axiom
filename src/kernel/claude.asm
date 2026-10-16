; =============================================================================
;  claude.asm - 'ask <question>': a conversation with Claude, through the
;  Messages API (POST /v1/messages, the answer streamed as server-sent
;  events), over http.asm's https with the certificate checked as for any
;  other. The answer appears as it is written, wrapped at word boundaries,
;  its Unicode drawn with the console font's symbols or look-alikes
;  (text.asm); the log keeps it as UTF-8. 'claude' shows and changes the
;  settings: the API key (typed, or read from CLAUDE.KEY on the boot stick;
;  kept in memory, never logged or written), the model, the server, and a
;  fresh conversation.
;
;  The conversation is kept in memory (CL_HIST bytes; the oldest exchanges
;  go first when it is full) and sent whole each time, as the API wants.
;  What comes back is undone in layers, a byte at a time, so that it may
;  arrive cut anywhere: the HTTP/1.1 headers, the chunks, lines of events,
;  and each event's JSON (json.asm).
;
;  Handlers keep RBX, RBP and R12-R15, as http.asm's clients must. Scratch
;  in .bss: main loop only.
; =============================================================================

CL_HIST         equ 80 * 1024           ; the conversation: [role][u32 bytes][UTF-8]...
CL_BODY         equ 100 * 1024          ; the request's JSON
CL_HEAD         equ 8192                ; the answer's headers
CL_LINE         equ 65536               ; one line of events
CL_ERR          equ 16384               ; an answer that is not events
CL_TEXT         equ 65536               ; one piece of the answer, decoded
CL_REPLY        equ 64 * 1024           ; the answer, for the conversation
CL_LOGLINE      equ 900
CL_WORD         equ 48
CL_VIEW         equ 2048
CL_TOKENS       equ 4096                ; max_tokens

CR_USER         equ 1
CR_ASSISTANT    equ 2

; the answer's layers: where its bytes are
CP_HEAD         equ 0
CP_BODY         equ 1
CP_DONE         equ 2

; and in the chunks
CK_SIZE         equ 0
CK_EXT          equ 1
CK_DATA         equ 2
CK_CRLF         equ 3
CK_TRAILER      equ 4

section .text

; ask <question>
cmd_ask:
    push rbx
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    cmp qword [http_app], 0
    jne .busy
    call cl_find_key
    jc .out
    mov rdi, rsi
    call strlen
    mov rcx, rax
    mov al, CR_USER
    call cl_hist_add
    jc .too_big
    call cl_build
    jc .too_big_now
    call cl_reset
    mov edi, COL_ACCENT
    call con_set_color
    lea rax, [cl_model]
    KLOG "%s:", rax
    mov edi, COL_TEXT
    call con_set_color
    lea rdi, [cl_url]                   ; the server, and the API's path
    lea rsi, [cl_server]
    call strcpy
    lea rsi, [str_cl_path]
    call strcat
    lea rsi, [cl_url]
    lea rdx, [cl_client]
    movzx ecx, byte [cl_insecure]
    or ecx, HF_QUIET
    call http_fetch
    jc .not_sent
    call shell_wait
    jmp .out
.not_sent:
    call cl_hist_pop
    jmp .out
.too_big_now:
    call cl_hist_pop
.too_big:
    KLOG "ask: that does not fit in a request"
    jmp .out
.busy:
    KLOG "ask: busy with another request (ctrl+C stops it)"
    jmp .out
.usage:
    KLOG "usage: ask <question>; the conversation goes on until 'claude new' ('claude' for the settings)"
.out:
    pop rbx
    ret

; claude [key <key>|key off|model <name>|server <url> [-k]|new]
cmd_claude:
    push rbx
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .status
    call arg_split                      ; RSI = the word, RDI = the rest
    mov rbx, rdi
    lea rdi, [str_cl_key]
    call streq
    test eax, eax
    jnz .key
    lea rdi, [str_cl_model]
    call streq
    test eax, eax
    jnz .model
    lea rdi, [str_cl_server]
    call streq
    test eax, eax
    jnz .server
    lea rdi, [str_cl_new]
    call streq
    test eax, eax
    jnz .new
.usage:
    KLOG "usage: claude [key <key>|key off|model <name>|server <url> [-k]|new]"
    jmp .out

.key:
    cmp qword [http_app], 0             ; (the request in flight holds it)
    jne .busy
    mov rsi, rbx
    lea rdi, [str_cl_off]
    call streq
    test eax, eax
    jnz .key_off
    mov rsi, rbx
    call cl_take_key
    jc .out
    mov byte [cl_keyfrom], 1
    mov eax, [cl_keylen]
    KLOG "claude: API key set (%u characters; kept in memory only, never logged)", rax
    jmp .out
.key_off:
    call cl_wipe_key
    KLOG "claude: API key forgotten"
    jmp .out

.model:
    mov rsi, rbx
    cmp byte [rsi], 0
    je .usage
    xor ecx, ecx
.model_char:
    mov al, [rsi + rcx]
    test al, al
    jz .model_ok
    cmp al, ' '
    jbe .model_bad
    cmp al, '"'
    je .model_bad
    cmp al, '\'
    je .model_bad
    cmp al, '~'
    ja .model_bad
    inc ecx
    cmp ecx, 63
    jb .model_char
.model_bad:
    KLOG "claude: '%s' is not a model name", rsi
    jmp .out
.model_ok:
    lea rdi, [cl_model]
    call strcpy
    lea rax, [cl_model]
    KLOG "claude: model %s from the next question on", rax
    jmp .out

.server:
    cmp qword [http_app], 0
    jne .busy
    mov rsi, rbx
    mov byte [cl_insecure], 0
    cmp byte [rsi], 0
    jne .server_url
    lea rsi, [str_cl_default]
.server_url:
    call arg_split
    push rsi
    mov rsi, rdi                        ; after the URL: -k?
    lea rdi, [str_cl_dash_k]
    call streq
    pop rsi
    test eax, eax
    jz .server_k
    mov byte [cl_insecure], 1
.server_k:
    mov rdi, rsi
    call strlen
    cmp eax, 200
    ja .usage
    lea rdi, [cl_server]
    call strcpy
    mov rdi, rax                        ; no '/' at the end
.server_trim:
    lea rcx, [cl_server]
    cmp rdi, rcx
    je .server_said
    cmp byte [rdi - 1], '/'
    jne .server_said
    dec rdi
    mov byte [rdi], 0
    jmp .server_trim
.server_said:
    lea rax, [cl_server]
    cmp byte [cl_insecure], 0
    jne .server_insecure
    KLOG "claude: server %s", rax
    jmp .out
.server_insecure:
    KLOG "claude: server %s, its certificate NOT checked (-k)", rax
    jmp .out

.new:
    cmp qword [http_app], 0
    jne .busy
    call cl_forget
    KLOG "claude: a new conversation"
    jmp .out

.busy:
    KLOG "claude: not while a question is being answered"
    jmp .out

.status:
    lea rax, [cl_model]
    lea rcx, [cl_server]
    KLOG "claude: model %s, server %s", rax, rcx
    cmp dword [cl_keylen], 0
    jne .has_key
    KLOG "claude: no API key yet: 'claude key <key>', or a file CLAUDE.KEY on the boot stick holding it"
    jmp .conversation
.has_key:
    mov eax, [cl_keylen]
    lea rcx, [str_cl_typed]
    lea rdx, [str_cl_file]
    cmp byte [cl_keyfrom], 2
    cmove rcx, rdx
    KLOG "claude: API key set (%u characters, %s)", rax, rcx
.conversation:
    mov eax, [cl_hcount]
    KLOG "claude: %u message(s) so far, %b ('claude new' starts afresh)", rax, qword [cl_hlen]
.out:
    pop rbx
    ret

; strcpy(RDI = to, RSI = from) -> RAX = the NUL at the end of the copy;
; strcat(RDI, RSI): from at the end of RDI's string. Preserve others.
strcpy:
    push rsi
    push rdi
.next:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .done
    inc rsi
    inc rdi
    jmp .next
.done:
    mov rax, rdi
    pop rdi
    pop rsi
    ret

strcat:
    push rdi
.end:
    cmp byte [rdi], 0
    je .copy
    inc rdi
    jmp .end
.copy:
    call strcpy
    pop rdi
    ret

; -----------------------------------------------------------------------------
;  The key
; -----------------------------------------------------------------------------

; cl_take_key(RSI = text) -> CF (said why) if it holds no key; else
; cl_key. The first word; 'NAME=' before it, and quotes around it, go.
; Preserves all but RAX.
cl_take_key:
    push rcx
    push rdx
    push rsi
    push rdi
.lead:
    mov al, [rsi]
    cmp al, ' '
    je .skip
    cmp al, 9
    je .skip
    cmp al, 10
    je .skip
    cmp al, 13
    je .skip
    cmp al, '"'
    je .skip
    cmp al, "'"
    jne .word
.skip:
    inc rsi
    jmp .lead
.word:
    mov rdx, rsi                        ; past an '=' in the word, if any
.eq:
    mov al, [rdx]
    cmp al, ' '
    jbe .copy
    inc rdx
    cmp al, '='
    jne .eq
    mov rsi, rdx
    jmp .lead
.copy:
    lea rdi, [cl_key]
    xor ecx, ecx
.char:
    mov al, [rsi + rcx]
    cmp al, ' '
    jbe .end
    cmp al, '"'
    je .end
    cmp al, "'"
    je .end
    cmp al, '~'
    ja .bad
    cmp ecx, 250
    jae .bad
    mov [rdi + rcx], al
    inc ecx
    jmp .char
.end:
    cmp ecx, 20
    jb .bad
    mov byte [rdi + rcx], 0
    mov [cl_keylen], ecx
    clc
    jmp .out
.bad:
    call cl_wipe_key
    KLOG "claude: that is not an API key (it starts sk-ant-)"
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; cl_wipe_key. Preserves all.
cl_wipe_key:
    push rax
    push rcx
    push rdi
    lea rdi, [cl_key]
    xor eax, eax
    mov ecx, 256
    rep stosb
    mov [cl_keylen], eax
    mov [cl_keyfrom], al
    pop rdi
    pop rcx
    pop rax
    ret

; cl_find_key -> CF (said why) if there is none: the one set, else
; CLAUDE.KEY at the top of the boot stick. Preserves all but RAX.
cl_find_key:
    cmp dword [cl_keylen], 0
    jne .have
    push rcx
    push rdx
    push rsi
    push rdi
    push r14
    call log_volume
    jc .none
    mov edi, [r14 + VF_ROOT]
    lea rsi, [str_cl_keyname]
    call fat_lookup                     ; (quietly: it may well not be there)
    jc .none
    lea rsi, [str_cl_keypath]
    lea rdi, [cl_keyfile]
    mov ecx, 511
    call fat_read_file
    jc .none
    lea rsi, [cl_keyfile]
    mov byte [rsi + rax], 0
    call cl_take_key
    lea rdi, [cl_keyfile]               ; that copy goes
    mov ecx, 512
    xor eax, eax
    rep stosb
    cmp dword [cl_keylen], 0
    je .none_said
    mov byte [cl_keyfrom], 2
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "claude: API key read from vol%u:/CLAUDE.KEY", rax
    clc
    jmp .out
.none:
    KLOG "ask: no API key: 'claude key <key>', or a file CLAUDE.KEY on the boot stick holding it (console.anthropic.com gives keys)"
.none_said:
    stc
.out:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret
.have:
    clc
    ret

; -----------------------------------------------------------------------------
;  The conversation
; -----------------------------------------------------------------------------

; cl_hist_add(AL = CR_*, RSI = text, RCX = bytes) -> CF if it cannot fit
; even alone. The oldest exchanges go to make room. Preserves all but RAX.
cl_hist_add:
    push rcx
    push rdx
    push rsi
    push rdi
    mov dl, al
.room:
    mov rax, [cl_hlen]
    add rax, rcx
    add rax, 5
    cmp rax, CL_HIST
    jbe .fits
    cmp qword [cl_hlen], 0
    je .full
    call cl_hist_drop
    jmp .room
.fits:
    lea rdi, [cl_hist]
    mov rax, [cl_hlen]
    mov [cl_hlast], rax
    add rdi, rax
    mov [rdi], dl
    mov [rdi + 1], ecx
    add rdi, 5
    lea rax, [rcx + 5]
    add [cl_hlen], rax
    rep movsb
    inc dword [cl_hcount]
    clc
    jmp .out
.full:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; cl_hist_drop: the oldest exchange goes (a question and what followed it,
; up to the next question). Preserves all.
cl_hist_drop:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [cl_hist]
    xor ecx, ecx                        ; RCX = bytes to remove
.entry:
    cmp rcx, [cl_hlen]
    jae .cut
    mov eax, [rsi + rcx + 1]
    lea rcx, [rcx + rax + 5]
    dec dword [cl_hcount]
    cmp rcx, [cl_hlen]
    jae .cut
    cmp byte [rsi + rcx], CR_USER
    jne .entry
.cut:
    mov rax, [cl_hlen]
    sub rax, rcx
    mov [cl_hlen], rax
    sub [cl_hlast], rcx
    lea rdi, [cl_hist]
    add rsi, rcx
    mov rcx, rax
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; cl_hist_pop: the last message goes (a question that got no answer).
; Preserves all.
cl_hist_pop:
    push rax
    cmp dword [cl_hcount], 0
    je .out
    mov rax, [cl_hlast]
    mov [cl_hlen], rax
    dec dword [cl_hcount]
.out:
    pop rax
    ret

; cl_forget: a new conversation. Preserves all.
cl_forget:
    mov qword [cl_hlen], 0
    mov qword [cl_hlast], 0
    mov dword [cl_hcount], 0
    ret

; cl_build -> cl_body, cl_blen; CF if even the last question alone does
; not fit. The oldest exchanges go until it does. Preserves all but RAX.
cl_build:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
.again:
    lea rdi, [cl_body]
    lea r8, [cl_body + CL_BODY]         ; R8 = the end of the room
    lea rsi, [str_cl_j1]                ; {"model":"
    call .text
    lea rsi, [cl_model]
    call .escaped
    lea rsi, [str_cl_j2]                ; ","max_tokens":...,"system":"
    call .text
    lea rsi, [str_cl_system]
    call .escaped
    lea rsi, [str_cl_j3]                ; ","messages":[
    call .text
    lea r9, [cl_hist]
    xor edx, edx                        ; RDX = where in the conversation
.message:
    cmp rdx, [cl_hlen]
    jae .end
    test rdx, rdx
    jz .first
    lea rsi, [str_cl_comma]
    call .text
.first:
    lea rsi, [str_cl_juser]             ; {"role":"user","content":"
    cmp byte [r9 + rdx], CR_USER
    je .role
    lea rsi, [str_cl_jasst]
.role:
    call .text
    mov ecx, [r9 + rdx + 1]
    lea rsi, [r9 + rdx + 5]
    lea rdx, [rdx + rcx + 5]
    push rdx
    mov rdx, r8
    sub rdx, rdi
    call json_escape
    pop rdx
    jc .full
    add rdi, rax
    lea rsi, [str_cl_jclose]            ; "}
    call .text
    jmp .message
.end:
    lea rsi, [str_cl_jend]              ; ]}
    call .text
    lea rax, [cl_body]
    sub rdi, rax
    mov [cl_blen], rdi
    clc
    jmp .out
.full:
    cmp dword [cl_hcount], 1
    jbe .no
    call cl_hist_drop
    jmp .again
.no:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; .text(RSI = a string, as it is), .escaped(RSI = a string, escaped):
; at RDI, which moves on; on no room, out through .full
.text:
    mov al, [rsi]
    test al, al
    jz .text_end
    cmp rdi, r8
    jae .no_room
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .text
.text_end:
    ret
.escaped:
    push rdi
    mov rdi, rsi
    call strlen
    pop rdi
    mov rcx, rax
    mov rdx, r8
    sub rdx, rdi
    call json_escape
    jc .no_room
    add rdi, rax
    ret
.no_room:
    add rsp, 8                          ; (from inside .text or .escaped)
    jmp .full

; -----------------------------------------------------------------------------
;  http.asm's client
; -----------------------------------------------------------------------------

; cl_request -> RSI = the request, RDX = its bytes
cl_request:
    lea rdx, [http_host]
    lea rsi, [http_path]
    lea r8, [cl_key]
    mov r9, [cl_blen]
    mov ecx, [http_port]
    cmp ecx, [http_defport]
    jne .port
    SPRINTF cl_req, `POST %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: Axiom/0.1\r\nx-api-key: %s\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\naccept: text/event-stream\r\ncontent-length: %u\r\nConnection: close\r\n\r\n`, rsi, rdx, r8, r9
    jmp .body
.port:
    SPRINTF cl_req, `POST %s HTTP/1.1\r\nHost: %s:%u\r\nUser-Agent: Axiom/0.1\r\nx-api-key: %s\r\nanthropic-version: 2023-06-01\r\ncontent-type: application/json\r\naccept: text/event-stream\r\ncontent-length: %u\r\nConnection: close\r\n\r\n`, rsi, rdx, rcx, r8, r9
.body:
    mov [cl_reqhead], rax
    lea rdi, [cl_req]
    add rdi, rax
    lea rsi, [cl_body]
    mov rcx, r9
    rep movsb
    lea rsi, [cl_req]
    lea rdx, [rax + r9]
    ret

; cl_data(RSI = bytes of the answer, EDX = how many)
cl_data:
    push rbx
    mov ebx, edx
.next:
    test ebx, ebx
    jz .end
    cmp byte [cl_phase], CP_DONE
    je .end
    lodsb
    dec ebx
    call cl_byte
    jmp .next
.end:
    call cl_view_flush
    cmp byte [cl_phase], CP_DONE
    jne .out
    call http_hangup                    ; all there: no need to wait for the close
    call cl_finish
.out:
    pop rbx
    ret

; cl_end_text: the answer's text so far ends its line, on the screen and in
; the log, before anything else is said
cl_end_text:
    call cl_word_flush
    cmp byte [cl_spoke], 0
    je .out
    call cl_view_sync
    cmp qword [cl_vcol], 0
    je .flush
    mov al, 10
    call cl_view_out
.flush:
    call cl_view_flush
    call cl_log_flush
.out:
    ret

; cl_done: the server closed
cl_done:
    call cl_end_text
    cmp byte [cl_phase], CP_DONE
    je cl_finish
    cmp byte [cl_phase], CP_HEAD
    jne .body
    KLOG "ask: the server closed without answering"
    mov byte [cl_failed], 1
    jmp cl_finish
.body:
    cmp byte [cl_sse], 0
    jne .cut
    call cl_body_end                    ; an answer that ends at the close
    jmp cl_finish
.cut:
    cmp byte [cl_complete], 0
    jne cl_finish
    mov byte [cl_failed], 1
    KLOG "ask: the answer was cut short (the connection closed early)"
    jmp cl_finish

; cl_lost: it ended early (said why), or was stopped
cl_lost:
    mov byte [cl_failed], 1
    jmp cl_finish

; cl_finish: the answer is over, whole or not; what became of it
cl_finish:
    push rbx
    mov byte [cl_phase], CP_DONE
    call cl_end_text
    cmp byte [cl_spoke], 0
    je .quiet
    mov rcx, [cl_rlen]                  ; what was said joins the conversation
    lea rsi, [cl_reply]
    mov al, CR_ASSISTANT
    call cl_hist_add
    jmp .report
.quiet:
    call cl_hist_pop                    ; nothing said: the question goes too
.report:
    lea rdi, [cl_req]                   ; (it held the key)
    mov ecx, 1024
    xor eax, eax
    rep stosb
    cmp byte [cl_complete], 0
    je .resume
    RDTSC64
    sub rax, [cl_t0]
    xor edx, edx
    div qword [tsc_per_ms]
    xor edx, edx
    mov ecx, 100
    div rcx                             ; tenths of a second
    mov rbx, rax
    lea rcx, [cl_stop]
    lea rdx, [str_cl_end_turn]
    cmp byte [rcx], 0
    je .said
    mov rdi, rcx
    mov rsi, rdx
    call streq
    test eax, eax
    jnz .said
    lea rdx, [cl_stop]
    lea rdi, [str_cl_max_tokens]
    mov rsi, rdx
    call streq
    test eax, eax
    jz .stop
    mov eax, CL_TOKENS
    KLOG "ask: cut at %u tokens, the most an answer may have here", rax
    jmp .said
.stop:
    KLOG "ask: it stopped: %s", rdx
.said:
    KLOG "(%t s; %u tokens in, %u out)", rbx, qword [cl_tin], qword [cl_tout]
.resume:
    pop rbx
    jmp shell_resume

; -----------------------------------------------------------------------------
;  The answer, a byte at a time (AL). Keep RBX, RSI.
; -----------------------------------------------------------------------------

cl_byte:
    cmp byte [cl_phase], CP_HEAD
    je cl_head_byte
    cmp byte [cl_phase], CP_BODY
    je cl_body_byte
    ret

cl_head_byte:
    mov rcx, [cl_hdlen]
    cmp rcx, CL_HEAD - 1
    jae .too_long
    lea rdx, [cl_head]
    mov [rdx + rcx], al
    inc rcx
    mov [cl_hdlen], rcx
    cmp al, 10
    jne .out
    cmp rcx, 2                          ; LF LF, or LF CR LF: the end
    jb .out
    cmp byte [rdx + rcx - 2], 10
    je cl_headers
    cmp rcx, 3
    jb .out
    cmp byte [rdx + rcx - 2], 13
    jne .out
    cmp byte [rdx + rcx - 3], 10
    je cl_headers
.out:
    ret
.too_long:
    KLOG "ask: the answer's headers do not end"
    mov byte [cl_failed], 1
    mov byte [cl_phase], CP_DONE
    ret

; cl_headers: the status, and how the body comes
cl_headers:
    push rsi
    lea rsi, [cl_head]
    mov rdx, [cl_hdlen]
    mov byte [rsi + rdx], 0
    lea rdi, [str_cl_http1]
    call http_prefix
    jc .not_http
.version:                               ; HTTP/1.x NNN
    mov al, [rsi]
    cmp al, ' '
    je .status
    cmp al, 10
    jbe .not_http
    inc rsi
    jmp .version
.status:
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
    mov [cl_status], eax
.line:                                  ; each header line
    mov al, [rsi]
    test al, al
    jz .end
    inc rsi
    cmp al, 10
    jne .line
    lea rdi, [str_cl_h_te]
    call http_prefix
    jc .type
    lea rdi, [str_cl_chunked]
    call cl_line_has
    jc .line
    mov byte [cl_chunked], 1
    jmp .line
.type:
    lea rdi, [str_h_type]
    call http_prefix
    jc .length
    lea rdi, [str_cl_events]
    call cl_line_has
    jc .line
    mov byte [cl_sse], 1
    jmp .line
.length:
    lea rdi, [str_cl_h_len]
    call http_prefix
    jc .line
.space:
    cmp byte [rsi], ' '
    jne .number
    inc rsi
    jmp .space
.number:
    xor eax, eax
.ldigit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .length_end
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    jmp .ldigit
.length_end:
    mov [cl_clen], rax
    jmp .line
.end:
    cmp dword [cl_status], 200
    je .ok
    mov byte [cl_sse], 0                ; an error, in JSON: kept whole
.ok:
    mov byte [cl_phase], CP_BODY
    cmp byte [cl_chunked], 0
    jne .out
    cmp qword [cl_clen], 0
    jne .out
    call cl_body_end                    ; Content-Length: 0
    jmp .out
.not_http:
    KLOG "ask: the server does not answer in HTTP"
    mov byte [cl_failed], 1
    mov byte [cl_phase], CP_DONE
.out:
    pop rsi
    ret

; cl_line_has(RSI = in a line, RDI = lowercase text) -> CF unless the text
; is in the rest of the line, in any case. Preserves all.
cl_line_has:
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

cl_body_byte:
    cmp byte [cl_chunked], 0
    jne .chunked
    call cl_content
    inc qword [cl_got]
    mov rax, [cl_got]
    cmp rax, [cl_clen]                  ; (-1 when none was given)
    jae cl_body_end
    ret
.chunked:
    movzx ecx, byte [cl_ck]
    cmp ecx, CK_DATA
    je .data
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
    inc dword [cl_trail]
    ret
.trailer_line:
    cmp dword [cl_trail], 0
    je cl_body_end
    mov dword [cl_trail], 0
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
    mov rax, [cl_cksize]
    shr rax, 28                         ; a chunk over 4 GiB: not real
    jnz .broken
    mov rax, [cl_cksize]
    shl rax, 4
    or rax, rdx
    mov [cl_cksize], rax
    ret
.to_ext:
    mov byte [cl_ck], CK_EXT
    ret
.ext:
    cmp al, 10
    jne .out
.size_end:
    cmp qword [cl_cksize], 0
    je .last
    mov byte [cl_ck], CK_DATA
    ret
.last:
    mov byte [cl_ck], CK_TRAILER
    mov dword [cl_trail], 0
    ret
.data:
    call cl_content
    dec qword [cl_cksize]
    jnz .out
    mov byte [cl_ck], CK_CRLF
    ret
.crlf:
    cmp al, 10
    jne .out
    mov byte [cl_ck], CK_SIZE
    ret
.broken:
    KLOG "ask: the answer's chunks are broken"
    mov byte [cl_failed], 1
    mov byte [cl_phase], CP_DONE
.out:
    ret

; cl_body_end: the body is all there
cl_body_end:
    cmp byte [cl_phase], CP_DONE
    je .out
    mov byte [cl_phase], CP_DONE
    cmp byte [cl_sse], 0
    jne .events
    call cl_error
    ret
.events:
    cmp qword [cl_linelen], 0           ; a last event with no line end
    je .out
    call cl_event_line
.out:
    ret

; cl_content(AL): a byte of the body proper
cl_content:
    cmp byte [cl_sse], 0
    je .keep
    cmp al, 10
    je cl_event_line
    mov rcx, [cl_linelen]
    cmp rcx, CL_LINE
    jae .out                            ; too long: the event will not parse
    lea rdx, [cl_line]
    mov [rdx + rcx], al
    inc qword [cl_linelen]
.out:
    ret
.keep:
    mov rcx, [cl_errlen]
    cmp rcx, CL_ERR
    jae .out
    lea rdx, [cl_err]
    mov [rdx + rcx], al
    inc qword [cl_errlen]
    ret

; cl_event_line: a line of events is in cl_line
cl_event_line:
    push rsi
    push r11
    lea rsi, [cl_line]
    mov r11, rsi
    add r11, [cl_linelen]
    mov qword [cl_linelen], 0
    cmp r11, rsi
    je .out
    cmp byte [r11 - 1], 13
    jne .cr
    dec r11
.cr:
    lea rdi, [str_cl_data]
    call http_prefix
    jc .out
    call cl_event
.out:
    pop r11
    pop rsi
    ret

; cl_event(RSI = an event's JSON, R11 = its end)
cl_event:
    push r12
    mov r12, rsi                        ; R12 = the event
    lea rdi, [str_cl_type]
    call json_get
    jc .out
    lea rdi, [str_cl_ev_delta]
    call json_is
    je .delta
    lea rdi, [str_cl_ev_start]
    call json_is
    je .start
    lea rdi, [str_cl_ev_mdelta]
    call json_is
    je .mdelta
    lea rdi, [str_cl_ev_stop]
    call json_is
    je .stop
    lea rdi, [str_cl_ev_error]
    call json_is
    je .error
    jmp .out
.delta:                                 ; {"delta": {"type": "text_delta", "text": ...}}
    mov rsi, r12
    lea rdi, [str_cl_delta]
    call json_get
    jc .out
    mov r8, rsi
    lea rdi, [str_cl_type]
    call json_get
    jc .out
    lea rdi, [str_cl_text_delta]
    call json_is
    jne .out
    mov rsi, r8
    lea rdi, [str_cl_text]
    call json_get
    jc .out
    lea rdi, [cl_text]
    mov ecx, CL_TEXT
    call json_str
    jc .out
    lea rsi, [cl_text]
    mov rcx, rax
    call cl_say
    jmp .out
.start:                                 ; {"message": {"usage": {"input_tokens": n}}}
    mov rsi, r12
    lea rdi, [str_cl_message]
    call json_get
    jc .out
    lea rdi, [str_cl_usage]
    call json_get
    jc .out
    lea rdi, [str_cl_in]
    call json_get
    jc .out
    call json_num
    jc .out
    mov [cl_tin], rax
    jmp .out
.mdelta:                                ; {"delta": {"stop_reason": ...}, "usage": {"output_tokens": n}}
    mov rsi, r12
    lea rdi, [str_cl_delta]
    call json_get
    jc .usage
    lea rdi, [str_cl_reason]
    call json_get
    jc .usage
    lea rdi, [cl_stop]
    mov ecx, 31
    call json_str
    jc .usage
    lea rdi, [cl_stop]
    mov byte [rdi + rax], 0
.usage:
    mov rsi, r12
    lea rdi, [str_cl_usage]
    call json_get
    jc .out
    lea rdi, [str_cl_out]
    call json_get
    jc .out
    call json_num
    jc .out
    mov [cl_tout], rax
    jmp .out
.stop:
    mov byte [cl_complete], 1
    mov byte [cl_phase], CP_DONE
    jmp .out
.error:                                 ; {"error": {"type": ..., "message": ...}}
    call cl_end_text
    mov rsi, r12
    call cl_api_error
    mov rax, rdi
    KLOG "ask: the API stopped: %s (%s)", rax, rdx
    mov byte [cl_failed], 1
    mov byte [cl_phase], CP_DONE
.out:
    pop r12
    ret

; cl_api_error(RSI = JSON with an "error" in it, R11 = its end) -> RDI =
; its message, RDX = its type, in cl_emsg and cl_etype ("" if missing)
cl_api_error:
    mov byte [cl_emsg], 0
    mov byte [cl_etype], 0
    lea rdi, [str_cl_ev_error]
    call json_get
    jc .out
    mov r8, rsi
    lea rdi, [str_cl_type]
    call json_get
    jc .message
    lea rdi, [cl_etype]
    mov ecx, 63
    call json_str
    jc .message
    mov byte [rdi + rax], 0
.message:
    mov rsi, r8
    lea rdi, [str_cl_msg]
    call json_get
    jc .out
    lea rdi, [cl_emsg]
    mov ecx, 400
    call json_str
    jc .out
    mov byte [rdi + rax], 0
.out:
    lea rdi, [cl_emsg]
    lea rdx, [cl_etype]
    ret

; cl_error: an answer that is not events (most often an error, in JSON)
cl_error:
    push rsi
    push r11
    lea rsi, [cl_err]
    mov r11, rsi
    add r11, [cl_errlen]
    call json_ws
    call cl_api_error
    mov ecx, [cl_status]
    cmp byte [rdi], 0
    je .raw
    mov rax, rdi
    KLOG "ask: the API answered %u: %s (%s)", rcx, rax, rdx
    cmp ecx, 401
    jne .out
    KLOG "ask: the API key was refused ('claude key <key>' sets another)"
    jmp .out
.raw:
    lea rdi, [cl_head]                  ; the status line, and the start of the body
    xor eax, eax
.status_line:
    cmp byte [rdi + rax], 13
    jbe .cut
    inc eax
    cmp eax, 100
    jb .status_line
.cut:
    mov byte [rdi + rax], 0
    KLOG "ask: unexpected answer: %s", rdi
    lea rsi, [cl_err]
    mov rcx, [cl_errlen]
    cmp rcx, 600
    jbe .show
    mov ecx, 600
.show:
    call print_text
.out:
    mov byte [cl_failed], 1
    pop r11
    pop rsi
    ret

; -----------------------------------------------------------------------------
;  What Claude says: into the conversation, the log, and onto the screen
; -----------------------------------------------------------------------------

; cl_say(RSI = UTF-8, RCX = bytes)
cl_say:
    push rbx
    push r12
    mov rbx, rcx
    mov r12, rsi
    cmp byte [cl_spoke], 0
    jne .reply
    mov byte [cl_spoke], 1
.reply:
    mov rax, CL_REPLY                   ; the conversation keeps what fits
    sub rax, [cl_rlen]
    cmp rcx, rax
    cmova rcx, rax
    lea rdi, [cl_reply]
    add rdi, [cl_rlen]
    add [cl_rlen], rcx
    rep movsb
    mov rsi, r12
.byte:
    test rbx, rbx
    jz .out
    lodsb
    dec rbx
    call cl_log_byte
    lea rdi, [cl_u8]
    call utf8_step
    jc .byte
    call glyph_of
    test eax, eax
    jz .byte
    call cl_view_glyph
    jmp .byte
.out:
    pop r12
    pop rbx
    ret

; cl_log_byte(AL): into the log, a line at a time. Preserves all.
cl_log_byte:
    push rcx
    push rdx
    mov rcx, [cl_loglen]
    lea rdx, [cl_logline]
    mov [rdx + rcx], al
    inc rcx
    mov [cl_loglen], rcx
    cmp al, 10
    je .flush
    cmp rcx, CL_LOGLINE
    jb .out
    mov byte [rdx + rcx], 10            ; a long line, in pieces
    inc qword [cl_loglen]
.flush:
    call cl_log_flush
.out:
    pop rdx
    pop rcx
    ret

; cl_log_flush: the log line so far, to the log and the serial port.
; Preserves all.
cl_log_flush:
    push rax
    push rcx
    push rdi
    mov rcx, [cl_loglen]
    test rcx, rcx
    jz .out
    lea rdi, [cl_logline]
    cmp byte [rdi + rcx - 1], 10
    je .ended
    mov byte [rdi + rcx], 10
    inc rcx
.ended:
    mov byte [rdi + rcx], 0
    mov qword [cl_loglen], 0
    pushfq
    cli
    push rdi
    lea rdi, [print_lock]
    call spin_lock
    pop rdi
    call serial_text
    call log_append
    lea rdi, [print_lock]
    call spin_unlock
    popfq
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; cl_view_glyph(AL): a character for the screen, words kept whole
cl_view_glyph:
    cmp al, 10
    je .newline
    cmp al, ' '
    je .space
    mov ecx, [cl_wlen]
    cmp ecx, CL_WORD
    jb .keep
    push rax
    call cl_word_flush
    pop rax
    xor ecx, ecx
.keep:
    lea rdx, [cl_word]
    mov [rdx + rcx], al
    inc dword [cl_wlen]
    ret
.newline:
    call cl_word_flush
    mov al, 10
    jmp cl_view_out
.space:
    call cl_word_flush
    call cl_view_sync
    mov rcx, [cl_vcol]
    cmp rcx, [con_cols]
    jae .out                            ; the row is full: the wrap is the space
    mov al, ' '
    jmp cl_view_out
.out:
    ret

; cl_word_flush: the word so far, on this row if it fits, else the next
cl_word_flush:
    mov ecx, [cl_wlen]
    test ecx, ecx
    jz .out
    call cl_view_sync
    mov rax, [cl_vcol]
    test rax, rax
    jz .chars
    add rax, rcx
    cmp rax, [con_cols]
    jbe .chars
    mov al, 10
    call cl_view_out
.chars:
    xor ecx, ecx
.char:
    cmp ecx, [cl_wlen]
    jae .done
    lea rdx, [cl_word]
    mov al, [rdx + rcx]
    push rcx
    call cl_view_out
    pop rcx
    inc ecx
    jmp .char
.done:
    mov dword [cl_wlen], 0
.out:
    ret

; cl_view_sync: before the first character of a batch, the column is the
; console's (something else may have printed since)
cl_view_sync:
    cmp qword [cl_vlen], 0
    jne .out
    push rax
    mov rax, [con_cx]
    mov [cl_vcol], rax
    pop rax
.out:
    ret

; cl_view_out(AL): into the batch for the screen, the column kept as
; con_putc will have it
cl_view_out:
    call cl_view_sync
    mov rcx, [cl_vlen]
    cmp rcx, CL_VIEW - 1
    jb .room
    push rax
    call cl_view_flush
    call cl_view_sync
    pop rax
    xor ecx, ecx
.room:
    lea rdx, [cl_view]
    mov [rdx + rcx], al
    inc qword [cl_vlen]
    cmp al, 10
    je .newline
    mov rcx, [cl_vcol]
    cmp rcx, [con_cols]
    jb .advance
    xor ecx, ecx                        ; con_putc wraps first
.advance:
    inc rcx
    mov [cl_vcol], rcx
    ret
.newline:
    mov qword [cl_vcol], 0
    ret

; cl_view_flush: the batch onto the screen
cl_view_flush:
    push rdi
    mov rcx, [cl_vlen]
    test rcx, rcx
    jz .out
    lea rdi, [cl_view]
    mov byte [rdi + rcx], 0
    call kputs
    call sh_flush
    mov qword [cl_vlen], 0
.out:
    pop rdi
    ret

; cl_reset: a new answer to come
cl_reset:
    push rdi
    push rcx
    lea rdi, [cl_state]
    mov ecx, cl_state_end - cl_state
    xor eax, eax
    rep stosb
    mov qword [cl_clen], -1
    RDTSC64
    mov [cl_t0], rax
    pop rcx
    pop rdi
    ret

section .rodata
str_cl_key:         db 'key', 0
str_cl_model:       db 'model', 0
str_cl_server:      db 'server', 0
str_cl_new:         db 'new', 0
str_cl_off:         db 'off', 0
str_cl_dash_k:      db '-k', 0
str_cl_typed:       db 'typed in', 0
str_cl_file:        db 'from CLAUDE.KEY', 0
str_cl_default:     db 'https://api.anthropic.com', 0
str_cl_path:        db '/v1/messages', 0
str_cl_keyname:     db 'CLAUDE.KEY', 0
str_cl_keypath:     db '/CLAUDE.KEY', 0
str_cl_http1:       db 'http/1.', 0
str_cl_h_te:        db 'transfer-encoding:', 0
str_cl_h_len:       db 'content-length:', 0
str_cl_chunked:     db 'chunked', 0
str_cl_events:      db 'text/event-stream', 0
str_cl_data:        db 'data:', 0
str_cl_type:        db 'type', 0
str_cl_delta:       db 'delta', 0
str_cl_text:        db 'text', 0
str_cl_text_delta:  db 'text_delta', 0
str_cl_message:     db 'message', 0
str_cl_usage:       db 'usage', 0
str_cl_in:          db 'input_tokens', 0
str_cl_out:         db 'output_tokens', 0
str_cl_reason:      db 'stop_reason', 0
str_cl_msg:         db 'message', 0
str_cl_ev_delta:    db 'content_block_delta', 0
str_cl_ev_start:    db 'message_start', 0
str_cl_ev_mdelta:   db 'message_delta', 0
str_cl_ev_stop:     db 'message_stop', 0
str_cl_ev_error:    db 'error', 0
str_cl_end_turn:    db 'end_turn', 0
str_cl_max_tokens:  db 'max_tokens', 0
str_cl_j1:          db '{"model":"', 0
str_cl_j2:          db '","max_tokens":', CL_TOKENS / 1000 + '0', (CL_TOKENS / 100) % 10 + '0'
                    db (CL_TOKENS / 10) % 10 + '0', CL_TOKENS % 10 + '0', ',"stream":true,"system":"', 0
str_cl_j3:          db '","messages":[', 0
str_cl_juser:       db '{"role":"user","content":"', 0
str_cl_jasst:       db '{"role":"assistant","content":"', 0
str_cl_jclose:      db '"}', 0
str_cl_comma:       db ',', 0
str_cl_jend:        db ']}', 0
str_cl_system:      db "You are Claude, talking with the user through Axiom, a small operating "
                    db "system written from scratch in x86-64 assembly, running on the user's own "
                    db "PC. Axiom's console shows plain text only: Markdown is not rendered, so do "
                    db "not use it (no bold, headings, tables or code fences); lists with - or "
                    db "numbers are fine. Prefer ASCII characters. The screen is small and cannot "
                    db "scroll back, so keep answers short unless asked for more.", 0

align 8
cl_client:          dq cl_request, cl_data, cl_done, cl_lost

section .data
cl_model:           db 'claude-opus-5-5', 0
                    times 64 - ($ - cl_model) db 0
cl_server:          db 'https://api.anthropic.com', 0
                    times 208 - ($ - cl_server) db 0

section .bss
alignb 8
cl_state:                               ; zeroed for each answer
cl_t0:              resq 1
cl_hdlen:           resq 1
cl_clen:            resq 1              ; Content-Length, -1 for none
cl_got:             resq 1
cl_cksize:          resq 1
cl_linelen:         resq 1
cl_errlen:          resq 1
cl_rlen:            resq 1
cl_tin:             resq 1
cl_tout:            resq 1
cl_loglen:          resq 1
cl_vcol:            resq 1
cl_vlen:            resq 1
cl_u8:              resq 1              ; utf8_step's
cl_status:          resd 1
cl_trail:           resd 1
cl_wlen:            resd 1
cl_phase:           resb 1
cl_ck:              resb 1
cl_chunked:         resb 1
cl_sse:             resb 1
cl_spoke:           resb 1
cl_complete:        resb 1
cl_failed:          resb 1
cl_stop:            resb 32
cl_state_end:
alignb 8
cl_hlen:            resq 1
cl_hlast:           resq 1              ; where the last message starts
cl_blen:            resq 1
cl_reqhead:         resq 1
cl_hcount:          resd 1
cl_keylen:          resd 1
cl_keyfrom:         resb 1              ; 1 typed, 2 from CLAUDE.KEY
cl_insecure:        resb 1
cl_key:             resb 256
cl_keyfile:         resb 512
cl_url:             resb 256
cl_etype:           resb 64
cl_emsg:            resb 408
cl_word:            resb CL_WORD
cl_logline:         resb CL_LOGLINE + 8
cl_view:            resb CL_VIEW
cl_head:            resb CL_HEAD
cl_err:             resb CL_ERR + 8
cl_line:            resb CL_LINE
cl_text:            resb CL_TEXT
cl_reply:           resb CL_REPLY
cl_hist:            resb CL_HIST
cl_body:            resb CL_BODY
cl_req:             resb CL_BODY + 2048
