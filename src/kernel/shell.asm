; =============================================================================
;  shell.asm - Axiom's command line, one in each terminal (term.asm).
;
;  A line is commands joined by ; (then), && (then, if that worked) and ||
;  (then, if it failed). A command is a pipeline: a head, stages after |
;  (records.asm), and at the end at most one > file or >> file. The head's
;  first word names a thing or a verb; the next, if it is one of the thing's
;  actions, says what to do with it. What a command gives is a table of
;  records, shown (or written out) only at the end. Commands not yet made
;  that way print; piped, what they print becomes a table of lines.
; =============================================================================

LINE_MAX        equ 1000
SH_WORDS        equ 128                 ; words in a command
SH_WBUF         equ 4096                ; their text
SH_STAGES       equ 16                  ; stages in a pipeline
SH_VARS         equ 32                  ; variables
SV_NAME         equ 0                   ; 32 bytes
SV_VALUE        equ 32
SV_SIZE         equ 256
SV_VALUE_MAX    equ SV_SIZE - SV_VALUE

SL_END          equ 0                   ; what ends a command on its line:
SL_THEN         equ 1                   ; ;
SL_AND          equ 2                   ; &&
SL_OR           equ 3                   ; ||
SL_BG           equ 4                   ; &

CE_NAME         equ 0                   ; a command: its name,
CE_RUN          equ 8                   ; what runs it,
CE_HELP         equ 16                  ; what it is,
CE_ACTIONS      equ 24                  ; a thing's actions,
CE_FLAGS        equ 32
CE_SIZE         equ 40
CF_REC          equ 1                   ; it takes words and gives records

AE_NAME         equ 0                   ; an action: its name ("" the default),
AE_RUN          equ 8
AE_ARGS         equ 16                  ; what it takes,
AE_HELP         equ 24                  ; what it does,
AE_FLAGS        equ 32                  ; CF_REC, or 0 if it prints
AE_SIZE         equ 40

section .text

shell_init:
    KLOG "Type 'help' for commands."
    jmp shell_prompt

shell_prompt:
    push rdi
    mov edi, COL_ACCENT
    call con_set_color
    lea rdi, [str_prompt]
    call kputs
    mov edi, COL_TEXT
    call con_set_color
    pop rdi
    ret

; sh_echo(AL): one character to the terminal. Preserves all.
sh_echo:
    jmp con_putc

; shell_wait: the command runs on (a fetch); the prompt of the terminal it
; prints to waits for shell_resume, and keys but ctrl+C are ignored
; meanwhile. Preserves all.
shell_wait:
    push rax
    call con_target
    test rax, rax
    jz .out
    mov byte [rax + TW_SH_WAIT], 1
.out:
    pop rax
    ret

; shell_resume: what the prompt of the terminal this thread prints to
; waited for is over: the prompt comes back, or what was left of the line
; runs, from the main loop (shell_service). Preserves all.
shell_resume:
    push rax
    call con_target
    test rax, rax
    jz .out
    cmp byte [rax + TW_SH_WAIT], 0
    je .out
    cmp byte [rax + TW_SH_REST], 0
    jne .rest
    mov byte [rax + TW_SH_WAIT], 0
    mov byte [rax + TW_SH_FAILED], 0    ; (nothing after it to know)
    call shell_prompt
    jmp .out
.rest:
    mov byte [rax + TW_SH_WAIT], 2
    mov byte [shell_pending], 1
    push rdi
    mov rdi, [main_thread]
    cmp rdi, [gs:PC_CURRENT]
    je .woken
    call thread_unpark
.woken:
    pop rdi
.out:
    pop rax
    ret

; shell_service: from the main loop. The rest of a line, in each terminal
; whose command that answered later is done.
shell_service:
    cmp byte [shell_pending], 0
    jne .some
    ret
.some:
    push rbx
    mov byte [shell_pending], 0
    mov rbx, [term_list]
.next:
    test rbx, rbx
    jz .out
    cmp byte [rbx + TW_SH_WAIT], 2
    jne .on
    mov byte [rbx + TW_SH_WAIT], 0
    mov r11, rbx
    lea rax, [shell_rest]
    call con_call
.on:
    mov rbx, [rbx + TW_NEXT]
    jmp .next
.out:
    pop rbx
    ret

; shell_rest: what was left of the line, in the terminal this thread prints
; to (TW_SH_REST)
shell_rest:
    push rbx
    call con_target
    mov rbx, rax
    test rbx, rbx
    jz .out
    lea rdi, [sh_line]
    lea rsi, [rbx + TW_SH_REST]
    mov ecx, LINE_MAX + 1
    rep movsb
    mov byte [rbx + TW_SH_REST], 0
    mov byte [fat_writing], 0
    xor eax, eax                        ; what it waited for: done, or a
    xchg al, [rbx + TW_SH_FAILED]       ; program that failed
    mov [sh_status], al
    call rec_init
    jc .prompt
    movzx edx, byte [rbx + TW_SH_RLINK]
    lea rsi, [sh_line]
    call sh_sequence
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out
.prompt:
    call shell_prompt
.out:
    pop rbx
    ret

; sh_secret(RDI = line) -> CF if it sets a secret ('claude key <key>'):
; then it is shown as stars, and neither logged nor kept for KEY_UP.
; Preserves all.
sh_secret:
    push rsi
    push rdi
    mov rsi, rdi
.lead:
    cmp byte [rsi], ' '
    jne .word
    inc rsi
    jmp .lead
.word:
    lea rdi, [str_sh_claude]
    call http_prefix
    jc .no
    cmp byte [rsi], ' '
    jne .no
.gap:
    inc rsi
    cmp byte [rsi], ' '
    je .gap
    lea rdi, [str_sh_key]
    call http_prefix
    jc .no
    cmp byte [rsi], ' '
    jne .no
.key:
    inc rsi                             ; and something after it
    cmp byte [rsi], ' '
    je .key
    cmp byte [rsi], 0
    je .no
    stc
    jmp .out
.no:
    clc
.out:
    pop rdi
    pop rsi
    ret

; shell_key(EDI = key code), for the terminal this thread prints to (its
; window has the keys)
shell_key:
    push rbx
    mov eax, edi
    push rax
    call con_target
    mov rbx, rax
    pop rax
    test rbx, rbx
    jz .out
    push rax                            ; a Linux program's, while one has
    mov rdi, rbx                        ; this terminal (lxtty.asm)
    mov esi, eax
    call lt_key
    test eax, eax
    pop rax
    jnz .out
    cmp eax, 3                          ; ctrl+C, always
    je .cancel
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .backspace
    cmp eax, KEY_UP
    je .history
    cmp eax, 12                         ; ctrl+L
    je .clear
    cmp eax, 32
    jb .out
    cmp eax, 126
    ja .out
    mov ecx, [rbx + TW_SH_LEN]
    cmp ecx, LINE_MAX
    jae .out
    lea rdx, [rbx + TW_SH_LINE]
    mov [rdx + rcx], al
    mov byte [rdx + rcx + 1], 0
    inc dword [rbx + TW_SH_LEN]
    lea rdi, [rbx + TW_SH_LINE]
    call sh_secret                      ; the key itself is not shown
    jnc .echo
    mov al, '*'
.echo:
    call sh_echo
    jmp .out
.backspace:
    cmp dword [rbx + TW_SH_LEN], 0
    je .out
    dec dword [rbx + TW_SH_LEN]
    mov al, 8
    call sh_echo
    jmp .out
.history:
    call sh_erase_line
    lea rdi, [rbx + TW_SH_LINE]
    lea rsi, [rbx + TW_SH_HIST]
    mov ecx, LINE_MAX
    rep movsb
    xor ecx, ecx
.retype:
    lea rdx, [rbx + TW_SH_LINE]
    mov al, [rdx + rcx]
    test al, al
    jz .retyped
    call sh_echo
    inc ecx
    jmp .retype
.retyped:
    mov [rbx + TW_SH_LEN], ecx
    jmp .out
.clear:
    call con_clear
    mov dword [rbx + TW_SH_LEN], 0
    call shell_prompt
    jmp .out
.cancel:
    mov byte [rbx + TW_SH_WAIT], 0      ; (the prompt comes back below)
    mov byte [rbx + TW_SH_REST], 0      ; and the rest of the line is dropped
    mov rdi, rbx                        ; what this terminal started stops:
    call net_forget                     ; a ping, a lookup or a fetch,
    mov rdi, rbx
    call lx_interrupt                   ; a Linux program, SIGINT,
    call user_forget                    ; and a program
    mov dword [rbx + TW_SH_LEN], 0
    lea rdi, [str_ctrl_c]
    call kputs
    call shell_prompt
    jmp .out
.enter:
    mov al, 10
    call sh_echo
    mov ecx, [rbx + TW_SH_LEN]
    lea rdx, [rbx + TW_SH_LINE]
    mov byte [rdx + rcx], 0
    test ecx, ecx
    jz .empty
    lea rdi, [sh_line]                  ; the command line, for the command
    lea rsi, [rbx + TW_SH_LINE]
    mov ecx, LINE_MAX + 1
    rep movsb
    lea rdi, [sh_line]
    call sh_secret
    jc .secret
    lea rdi, [rbx + TW_SH_HIST]
    lea rsi, [sh_line]
    mov ecx, LINE_MAX + 1
    rep movsb
    lea rdi, [sh_line]
    call log_command
    jmp .exec
.secret:
    lea rdi, [str_sh_secret]
    call log_command
.exec:
    mov dword [rbx + TW_SH_LEN], 0
    call shell_exec
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out
    call shell_prompt
    jmp .out
.empty:
    mov dword [rbx + TW_SH_LEN], 0
    call shell_prompt
.out:
    pop rbx
    ret

; sh_erase_line (RBX = terminal): what was typed, rubbed out
sh_erase_line:
.next:
    cmp dword [rbx + TW_SH_LEN], 0
    je .done
    dec dword [rbx + TW_SH_LEN]
    mov al, 8
    call sh_echo
    jmp .next
.done:
    ret

; -----------------------------------------------------------------------------
;  A line: commands, joined
; -----------------------------------------------------------------------------

; shell_exec: run sh_line
shell_exec:
    mov byte [fat_writing], 0           ; nothing is half-written between commands
    call rec_init
    jc .out
    mov byte [sh_status], 0
    lea rsi, [sh_line]
    mov edx, SL_THEN
    call sh_sequence
.out:
    ret

; sh_sequence(RSI = commands, EDX = how the first is joined to what ran
; before it, SL_*): each run or not, as the status says. A command that
; answers later (it set TW_SH_WAIT) keeps the rest of the line for then.
sh_sequence:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13d, edx
.next:
    mov rsi, r12
    call sh_cut
    mov r14d, ecx                       ; what ends this one,
    mov rbx, r8                         ; and what follows it
    cmp r13d, SL_AND
    jne .not_and
    cmp byte [sh_status], 0
    jne .after
.not_and:
    cmp r13d, SL_OR
    jne .run
    cmp byte [sh_status], 0
    je .after
.run:
    xor eax, eax                        ; '&': a program, in the background
    cmp r14d, SL_BG
    sete al
    mov [sh_bg], al
    mov rcx, rdx
    sub rcx, r12
    lea rdi, [sh_cmd]
    mov rsi, r12
    rep movsb
    mov byte [rdi], 0
    lea rsi, [sh_cmd]
    call sh_command
    setc byte [sh_status]
    call con_target
    test rax, rax
    jz .after
    cmp byte [rax + TW_SH_WAIT], 0
    je .after
    mov byte [sh_status], 0             ; it answers later
    cmp r14d, SL_END
    je .out
    mov [rax + TW_SH_RLINK], r14b       ; the rest, for then
    lea rdi, [rax + TW_SH_REST]
    mov rsi, rbx
    mov ecx, LINE_MAX
.keep:
    lodsb
    stosb
    test al, al
    jz .out
    dec ecx
    jnz .keep
    mov byte [rdi], 0
    jmp .out
.after:
    cmp r14d, SL_END
    je .out
    mov r13d, r14d
    mov r12, rbx
    jmp .next
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sh_cut(RSI = commands) -> RDX = where the first ends, ECX = what ends it
; (SL_*), R8 = what follows; ; && || & inside quotes, or after a \, are not
; ends. Preserves others but RAX.
sh_cut:
    push r9
    mov rdx, rsi
    xor r9d, r9d                        ; the quote open, if one is
.scan:
    mov al, [rdx]
    test al, al
    jz .end
    test r9b, r9b
    jz .bare
    cmp al, r9b
    jne .quoted
    xor r9d, r9d
    inc rdx
    jmp .scan
.quoted:
    cmp al, '\'
    jne .step
    cmp r9b, '"'
    jne .step
    cmp byte [rdx + 1], 0
    je .step
    inc rdx
.step:
    inc rdx
    jmp .scan
.bare:
    cmp al, '\'
    jne .not_escape
    cmp byte [rdx + 1], 0
    je .step
    add rdx, 2
    jmp .scan
.not_escape:
    cmp al, '"'
    je .open
    cmp al, 0x27
    je .open
    cmp al, ';'
    je .then
    cmp al, '&'
    je .amp
    cmp al, '|'
    jne .step
    cmp byte [rdx + 1], '|'
    jne .step
    mov ecx, SL_OR
    lea r8, [rdx + 2]
    jmp .out
.open:
    mov r9b, al
    inc rdx
    jmp .scan
.then:
    mov ecx, SL_THEN
    lea r8, [rdx + 1]
    jmp .out
.amp:
    cmp byte [rdx + 1], '&'
    jne .bg
    mov ecx, SL_AND
    lea r8, [rdx + 2]
    jmp .out
.bg:
    mov ecx, SL_BG
    lea r8, [rdx + 1]
    jmp .out
.end:
    xor ecx, ecx
    mov r8, rdx
.out:
    pop r9
    ret

; sh_command(RSI = one command) -> CF if it failed
sh_command:
    call sh_words
    jc .fail
    cmp dword [sh_argc], 0
    je .ok
    jmp sh_pipeline
.ok:
    clc
    ret
.fail:
    stc
    ret

; -----------------------------------------------------------------------------
;  Words
; -----------------------------------------------------------------------------

; sh_words(RSI = a command) -> sh_argv, sh_argc: its words, quotes and \
; taken out, variables put in; | > >> as the tokens sh_tok_*. CF (said
; why) if a quote is not closed, or there are too many or too much.
sh_words:
    push rbx
    push r12
    push r13
    lea rdi, [sh_wbuf]
    xor ebx, ebx
.skip:
    mov al, [rsi]
    cmp al, ' '
    jne .start
    inc rsi
    jmp .skip
.start:
    test al, al
    jz .done
    cmp ebx, SH_WORDS
    jae .too_many
    cmp al, '|'
    je .pipe
    cmp al, '>'
    jne .word
    cmp byte [rsi + 1], '='
    je .word
    cmp byte [rsi + 1], '>'
    je .add
    lea rax, [sh_tok_gt]
    inc rsi
    jmp .token
.add:
    lea rax, [sh_tok_add]
    add rsi, 2
    jmp .token
.pipe:
    lea rax, [sh_tok_pipe]
    inc rsi
.token:
    mov [sh_argv + rbx * 8], rax
    inc ebx
    jmp .skip
.word:
    mov r12, rdi                        ; where it begins
    xor r13d, r13d                      ; 1 once it had quotes
.char:
    lea rax, [sh_wbuf + SH_WBUF - 2]
    cmp rdi, rax
    jae .too_long
    mov al, [rsi]
    test al, al
    jz .ended
    cmp al, ' '
    je .ended
    cmp al, '|'
    je .ended
    cmp al, '>'
    jne .not_gt
    cmp byte [rsi + 1], '='
    jne .ended
.not_gt:
    cmp al, '\'
    je .escape
    cmp al, 0x27
    je .single
    cmp al, '"'
    je .double
    cmp al, '$'
    je .var
    stosb
    inc rsi
    jmp .char
.escape:                                ; \ before what the shell gives a
    mov al, [rsi + 1]                   ; meaning to takes it as it is;
    lea rcx, [sh_escapable]             ; before anything else it stays
.escapable:                             ; (\n reaches a program as typed)
    cmp byte [rcx], 0
    je .backslash
    cmp al, [rcx]
    je .escaped
    inc rcx
    jmp .escapable
.escaped:
    inc rsi
    stosb
    inc rsi
    jmp .char
.backslash:
    mov al, '\'
    stosb
    inc rsi
    jmp .char
.var:
    call sh_expand
    jc .too_long
    jmp .char
.single:
    mov r13d, 1
    inc rsi
.single_char:
    lea rax, [sh_wbuf + SH_WBUF - 2]
    cmp rdi, rax
    jae .too_long
    mov al, [rsi]
    test al, al
    jz .open_quote
    inc rsi
    cmp al, 0x27
    je .char
    stosb
    jmp .single_char
.double:
    mov r13d, 1
    inc rsi
.double_char:
    lea rax, [sh_wbuf + SH_WBUF - 2]
    cmp rdi, rax
    jae .too_long
    mov al, [rsi]
    test al, al
    jz .open_quote
    cmp al, '"'
    je .double_end
    cmp al, '$'
    je .double_var
    cmp al, '\'
    jne .double_plain
    mov cl, [rsi + 1]
    cmp cl, '"'
    je .double_escape
    cmp cl, '\'
    je .double_escape
    cmp cl, '$'
    jne .double_plain
.double_escape:
    inc rsi
    mov al, [rsi]
.double_plain:
    stosb
    inc rsi
    jmp .double_char
.double_var:
    call sh_expand
    jc .too_long
    jmp .double_char
.double_end:
    inc rsi
    jmp .char
.ended:
    cmp rdi, r12
    jne .keep
    test r13d, r13d
    jz .skip                            ; nothing (an unset variable, alone)
.keep:
    mov byte [rdi], 0
    inc rdi
    mov [sh_argv + rbx * 8], r12
    inc ebx
    jmp .skip
.done:
    mov [sh_argc], ebx
    mov qword [sh_argv + rbx * 8], 0
    clc
    jmp .out
.too_many:
    KLOG "that command has too many words (%u at most)", SH_WORDS
    stc
    jmp .out
.too_long:
    KLOG "that command is too long"
    stc
    jmp .out
.open_quote:
    KLOG "a quote is not closed"
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; sh_expand(RSI = at a $, RDI = where the word goes on) -> RSI past what it
; read, RDI past the variable's value (nothing if it is not set); a $ not
; before a name stays a $. CF if there is no room. Preserves others.
sh_expand:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    lea r9, [rsi + 1]                   ; just after the $
    mov rsi, r9
    xor r8d, r8d                        ; ${name}?
    cmp byte [rsi], '{'
    jne .name
    mov r8d, 1
    inc rsi
.name:
    mov rdx, rsi
.name_char:
    mov al, [rsi]
    call sh_name_char
    jnc .name_end
    inc rsi
    jmp .name_char
.name_end:
    mov rcx, rsi
    sub rcx, rdx
    jz .dollar
    test r8d, r8d
    jz .look
    cmp byte [rsi], '}'
    jne .dollar
    inc rsi
.look:
    call sh_var_find
    test rax, rax
    jz .ok
    lea rax, [rax + SV_VALUE]
.copy:
    mov cl, [rax]
    test cl, cl
    jz .ok
    lea rdx, [sh_wbuf + SH_WBUF - 2]
    cmp rdi, rdx
    jae .full
    mov [rdi], cl
    inc rdi
    inc rax
    jmp .copy
.dollar:
    mov rsi, r9
    mov byte [rdi], '$'
    inc rdi
.ok:
    clc
    jmp .out
.full:
    stc
.out:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; sh_name_char(AL) -> CF if it can be in a variable's name: A-Z a-z 0-9 _.
; Preserves all.
sh_name_char:
    cmp al, '_'
    je .yes
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
    push rax
    or al, 0x20
    cmp al, 'a'
    jb .not
    cmp al, 'z'
    ja .not
    pop rax
.yes:
    stc
    ret
.not:
    pop rax
.no:
    clc
    ret

; sh_var_find(RDX = a name, ECX = its length) -> RAX = its variable, 0 if
; there is none; case aside. Preserves others.
sh_var_find:
    push rbx
    push rsi
    push rdi
    push r8
    lea rbx, [sh_vars]
    xor r8d, r8d
.slot:
    cmp r8d, SH_VARS
    jae .none
    cmp byte [rbx + SV_NAME], 0
    je .next
    xor esi, esi
.compare:
    cmp esi, ecx
    jae .end
    movzx eax, byte [rbx + rsi]
    movzx edi, byte [rdx + rsi]
    TOLOWER eax
    TOLOWER edi
    cmp eax, edi
    jne .next
    inc esi
    jmp .compare
.end:
    mov esi, ecx
    cmp byte [rbx + rsi], 0
    jne .next
    mov rax, rbx
    jmp .out
.next:
    add rbx, SV_SIZE
    inc r8d
    jmp .slot
.none:
    xor eax, eax
.out:
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

; sh_join(EDI = words, RSI = them) -> [sh_args] = sh_joined, the words a
; space apart (what commands that print read). Preserves all.
sh_join:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    mov r8d, edi
    lea rdi, [sh_joined]
    lea rdx, [sh_joined + LINE_MAX]
    xor ecx, ecx
.word:
    cmp ecx, r8d
    jae .done
    test ecx, ecx
    jz .first
    cmp rdi, rdx
    jae .done
    mov byte [rdi], ' '
    inc rdi
.first:
    mov rax, [rsi + rcx * 8]
.char:
    mov r9b, [rax]
    test r9b, r9b
    jz .next
    cmp rdi, rdx
    jae .done
    mov [rdi], r9b
    inc rdi
    inc rax
    jmp .char
.next:
    inc ecx
    jmp .word
.done:
    mov byte [rdi], 0
    lea rax, [sh_joined]
    mov [sh_args], rax
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; sh_is_token(RAX = a word) -> CF if it is | > or >>. Preserves all.
sh_is_token:
    push rdx
    lea rdx, [sh_tok_pipe]
    cmp rax, rdx
    je .yes
    lea rdx, [sh_tok_gt]
    cmp rax, rdx
    je .yes
    lea rdx, [sh_tok_add]
    cmp rax, rdx
    je .yes
    pop rdx
    clc
    ret
.yes:
    pop rdx
    stc
    ret

; -----------------------------------------------------------------------------
;  A pipeline
; -----------------------------------------------------------------------------

; sh_pipeline: sh_argv run: the head, each stage, then the table shown or
; written to the file -> CF if something failed
sh_pipeline:
    push rbx
    push r12
    push r13
    push r14
    mov byte [sh_redir], 0
    mov dword [sh_stage], 0
    mov dword [sh_nstages], 1
    xor ecx, ecx                        ; the word
    xor edx, edx                        ; where the stage it is in began
.scan:
    cmp ecx, [sh_argc]
    jae .scanned
    mov rax, [sh_argv + rcx * 8]
    lea r8, [sh_tok_pipe]
    cmp rax, r8
    je .pipe
    lea r8, [sh_tok_gt]
    cmp rax, r8
    je .gt
    lea r8, [sh_tok_add]
    cmp rax, r8
    je .redirect
.next:
    inc ecx
    jmp .scan
.pipe:
    cmp ecx, edx
    je .empty
    mov eax, [sh_nstages]
    cmp eax, SH_STAGES
    jae .too_many
    lea edx, [ecx + 1]
    mov [sh_stage + rax * 4], edx
    inc dword [sh_nstages]
    jmp .next
.gt:                                    ; 'where <field> > <value>' compares
    mov eax, ecx
    sub eax, edx
    cmp eax, 2
    jne .redirect
    mov rdi, [sh_argv + rdx * 8]
    lea rsi, [str_sh_where]
    call rec_ieq
    test eax, eax
    jz .redirect
    lea rax, [ro_gt]
    mov [sh_argv + rcx * 8], rax
    jmp .next
.redirect:                              ; then one word, and the end
    lea eax, [ecx + 2]
    cmp eax, [sh_argc]
    jne .bad_redirect
    mov rax, [sh_argv + rcx * 8 + 8]
    call sh_is_token
    jc .bad_redirect
    mov [sh_redir_path], rax
    mov rax, [sh_argv + rcx * 8]
    lea r8, [sh_tok_add]
    cmp rax, r8
    sete al
    inc al
    mov [sh_redir], al                  ; 1 written, 2 added to
    mov [sh_argc], ecx
.scanned:
    cmp ecx, edx                        ; (ECX = the end)
    je .empty
    xor ecx, ecx                        ; the head
    call sh_range
    lea rsi, [sh_argv + rax * 8]
    mov edi, edx
    xor edx, edx
    cmp dword [sh_nstages], 1
    seta dl
    cmp byte [sh_redir], 0
    je .piped
    mov edx, 1
.piped:
    call rec_clear
    call sh_head
    jc .fail
    call con_target                     ; it answers later: nothing to pipe
    test rax, rax
    jz .stages
    cmp byte [rax + TW_SH_WAIT], 0
    je .stages
    cmp dword [sh_nstages], 1
    jne .later
    cmp byte [sh_redir], 0
    je .ok
.later:
    KLOG "(that answers later, so what it says is not piped)"
    jmp .ok
.stages:
    mov r12d, 1
.stage:
    cmp r12d, [sh_nstages]
    jae .end
    mov ecx, r12d
    call sh_range
    lea rsi, [sh_argv + rax * 8]
    mov edi, edx
    call rec_stage
    jc .fail
    inc r12d
    jmp .stage
.end:
    cmp byte [sh_redir], 0
    je .show
    call sh_redirect
    jmp .out
.show:
    call rec_show
.ok:
    clc
    jmp .out
.empty:
    KLOG "a | or a > needs a command before it, and a | one after it"
    jmp .fail
.too_many:
    KLOG "that pipeline has too many stages (%u at most)", SH_STAGES
    jmp .fail
.bad_redirect:
    KLOG "> and >> take one file, and come last"
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sh_range(ECX = a stage) -> EAX = its first word, EDX = how many
; Preserves others.
sh_range:
    mov eax, [sh_stage + rcx * 4]
    lea edx, [ecx + 1]
    cmp edx, [sh_nstages]
    jae .last
    mov edx, [sh_stage + rdx * 4]
    dec edx                             ; (the | before it)
    sub edx, eax
    ret
.last:
    mov edx, [sh_argc]
    sub edx, eax
    ret

; sh_find(RSI = a name) -> RAX = its command; CF if there is none.
; Preserves others.
sh_find:
    push rdi
    push rbx
    lea rbx, [commands]
.next:
    mov rdi, [rbx + CE_NAME]
    test rdi, rdi
    jz .none
    call rec_ieq
    test eax, eax
    jnz .found
    add rbx, CE_SIZE
    jmp .next
.found:
    mov rax, rbx
    clc
    jmp .out
.none:
    stc
.out:
    pop rbx
    pop rdi
    ret

; sh_action(RDI = actions, RSI = a word) -> RAX = the action it names, 0 if
; none (the default is not named). Preserves others.
sh_action:
    push rbx
    push rdi
    mov rbx, rdi
.next:
    mov rdi, [rbx + AE_NAME]
    test rdi, rdi
    jz .none
    cmp byte [rdi], 0
    je .skip
    call rec_ieq
    test eax, eax
    jnz .found
.skip:
    add rbx, AE_SIZE
    jmp .next
.found:
    mov rax, rbx
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rbx
    ret

; sh_head(EDI = words, RSI = them, EDX = 1 if what it gives goes on to a
; stage or a file) -> CF if it failed
sh_head:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13, rsi
    mov r15d, edx
    mov dword [sh_grants], 0
.grant:                                 ; +net, +store, +desk, +files, +sound: for a program
    mov rsi, [r13]
    cmp byte [rsi], '+'
    jne .granted
    inc rsi
    call sh_grant
    jc .out
    or [sh_grants], eax
    add r13, 8
    dec r12d
    jnz .grant
    KLOG "+net, +store, +desk, +files and +sound come before a program's name"
    stc
    jmp .out
.granted:
    mov rsi, [r13]
    call sh_find
    jc .unknown
    mov rbx, rax
    lea rax, [cmd_run]                  ; run takes them too
    cmp [rbx + CE_RUN], rax
    je .run
    mov rax, [rbx + CE_NAME]
    cmp dword [sh_grants], 0
    jne .granted_command
    cmp byte [sh_bg], 0
    jne .background_command
.run:
    mov r14, [rbx + CE_ACTIONS]
    test r14, r14
    jnz .thing
    lea edi, [r12d - 1]
    lea rsi, [r13 + 8]
    call sh_join
    test dword [rbx + CE_FLAGS], CF_REC
    jz .prints
    call [rbx + CE_RUN]
    jmp .out
.prints:                                ; what it prints, a table if piped
    mov rax, [rbx + CE_RUN]
    call sh_print_run
    jmp .out
.thing:
    cmp r12d, 2
    jb .default
    mov rdi, r14
    mov rsi, [r13 + 8]
    call sh_action
    test rax, rax
    jz .default
    mov r14, rax
    lea edi, [r12d - 2]
    lea rsi, [r13 + 16]
    jmp .act
.default:
    mov rax, [r14 + AE_NAME]
    cmp byte [rax], 0
    jne .no_default
    lea edi, [r12d - 1]
    lea rsi, [r13 + 8]
.act:
    call sh_join
    test dword [r14 + AE_FLAGS], CF_REC
    jz .act_prints
    call [r14 + AE_RUN]
    jmp .out
.act_prints:
    mov rax, [r14 + AE_RUN]
    call sh_print_run
    jmp .out
.no_default:
    mov rax, [rbx + CE_NAME]
    cmp r12d, 2
    jb .say_what
    mov rcx, [r13 + 8]
    KLOG "%s has no action '%s': 'help %s' lists them", rax, rcx, rax
    stc
    jmp .out
.say_what:
    KLOG "%s needs an action: 'help %s' lists them", rax, rax
    stc
    jmp .out
.unknown:
    mov rdi, [r13]                      ; a program, by its name or path
    call user_found
    jnc .program
    call rec_stage_of
    test rax, rax
    jnz .stage
    mov rax, [r13]
    KLOG "unknown command '%s' - try 'help'", rax
    stc
    jmp .out
.program:
    cmp byte [sh_bg], 0
    je .start
    test r15d, r15d
    jnz .background_piped
.start:
    lea edi, [r12d - 1]
    lea rsi, [r13 + 8]
    call sh_join
    mov rdi, [r13]
    mov rsi, [sh_args]
    mov edx, [sh_grants]
    movzx ecx, byte [sh_bg]
    call user_start
    jmp .out
.granted_command:
    KLOG "+net, +store, +desk, +files and +sound are for programs; '%s' is a command", rax
    stc
    jmp .out
.background_command:
    KLOG "'&' is for programs; '%s' is a command", rax
    stc
    jmp .out
.background_piped:
    KLOG "a program in the background has no | or > after it"
    stc
    jmp .out
.stage:
    mov rax, [r13]
    KLOG "'%s' is a stage: it comes after a |, as in 'files | %s ...'", rax, rax
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sh_grant(RSI = what follows a +) -> EAX = what it grants (AW_*); CF (said
; why) if it is none of them. Preserves others.
sh_grant:
    push rbx
    push rdi
    lea rbx, [sh_grants_names]
.next:
    mov rdi, [rbx]
    test rdi, rdi
    jz .none
    call rec_ieq
    test eax, eax
    jnz .found
    add rbx, 16
    jmp .next
.found:
    mov eax, [rbx + 8]
    clc
    jmp .out
.none:
    KLOG "'+%s' is not something a program can be given; there are +net, +store, +desk, +files and +sound", rsi
    stc
.out:
    pop rdi
    pop rbx
    ret

; sh_print_run(RAX = a command that prints, R15D = 1 if piped; EDI, RSI:
; its words, for one that wants them): run, what it prints captured as a
; table of lines if piped -> CF clear
sh_print_run:
    test r15d, r15d
    jz .plain
    call rec_capture_start
    call rax
    call rec_capture_stop
    clc
    ret
.plain:
    call rax
    clc
    ret

; sh_redirect: the table as text (or JSON), written to sh_redir_path, or
; added to the end of it -> CF if it could not be
sh_redirect:
    push rbx
    push r12
    push r13
    push r14
    call fat_vol
    jc .fail
    mov rdi, [rec_tmp]
    mov esi, TB_BYTES
    call rec_write
    jc .too_much
    mov r12, rax
    mov rsi, [sh_redir_path]
    cmp byte [sh_redir], 2
    je .add
.write:
    mov rdi, [rec_tmp]
    mov rcx, r12
    call fat_write_file
    jc .fail
    KLOG "wrote %b to %s", r12, rsi
    clc
    jmp .out
.add:
    mov byte [fat_hush], 1
    call fat_resolve
    mov byte [fat_hush], 0
    jc .write                           ; not there yet: as >
    test byte [fat_ent + 11], 0x10
    jnz .folder
    mov r13d, [fat_ent + 28]            ; what it has
    lea rdi, [r13 + r12 + 1]
    call vm_alloc
    test rax, rax
    jz .no_memory
    mov rbx, rax
    mov rdi, rbx
    mov rcx, r13
    call fat_read_file
    jc .free
    mov r13, rax
    lea rdi, [rbx + r13]
    mov rsi, [rec_tmp]
    mov rcx, r12
    rep movsb
    mov rsi, [sh_redir_path]
    mov rdi, rbx
    lea rcx, [r13 + r12]
    call fat_write_file
    jc .free
    KLOG "added %b to %s", r12, rsi
    mov rdi, rbx
    call vm_free
    clc
    jmp .out
.free:
    mov rdi, rbx
    call vm_free
    jmp .fail
.folder:
    KLOG "%s is a folder", rsi
    jmp .fail
.no_memory:
    KLOG "no memory for that"
    jmp .fail
.too_much:
    KLOG "that is more than a file is given at once (%b)", TB_BYTES
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Commands
; -----------------------------------------------------------------------------

; help [command]: every command, or a thing's actions
cmd_help:
    push rbx
    push r12
    push r13
    test edi, edi
    jnz .one
    COLUMN 'command', FT_TEXT
    COLUMN 'about', FT_TEXT
    lea rbx, [commands]
.next:
    cmp qword [rbx + CE_NAME], 0
    je .done
    call rec_row
    xor edi, edi
    mov rsi, [rbx + CE_NAME]
    call rec_set
    mov edi, 1
    mov rsi, [rbx + CE_HELP]
    call rec_set
    add rbx, CE_SIZE
    jmp .next
.one:
    mov rsi, [rsi]
    call sh_find
    jc .unknown
    mov rbx, rax
    COLUMN 'use', FT_TEXT
    COLUMN 'about', FT_TEXT
    mov r12, [rbx + CE_ACTIONS]
    test r12, r12
    jnz .action
    call rec_row
    xor edi, edi
    mov rsi, [rbx + CE_NAME]
    call rec_set
    mov edi, 1
    mov rsi, [rbx + CE_HELP]
    call rec_set
    jmp .done
.action:
    cmp qword [r12 + AE_NAME], 0
    je .done
    call rec_row
    call rec_begin                      ; <thing> [action] [what it takes]
    mov rsi, [rbx + CE_NAME]
    call rec_puts
    mov rsi, [r12 + AE_NAME]
    cmp byte [rsi], 0
    je .args
    mov ecx, 1
    call rec_spaces
    call rec_puts
.args:
    mov rsi, [r12 + AE_ARGS]
    cmp byte [rsi], 0
    je .use
    mov ecx, 1
    call rec_spaces
    call rec_puts
.use:
    xor edi, edi
    lea rsi, [rec_line]
    call rec_str
    mov edi, 1
    mov rsi, [r12 + AE_HELP]
    call rec_set
    add r12, AE_SIZE
    jmp .action
.done:
    clc
    jmp .out
.unknown:
    KLOG "no command '%s': 'help' lists them", rsi
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; set [name [value...]]: every variable; one removed; or one given a value
cmd_set:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    test r12d, r12d
    jz .list
    mov rdx, [r13]                      ; the name
    xor ecx, ecx
.measure:
    mov al, [rdx + rcx]
    test al, al
    jz .measured
    call sh_name_char
    jnc .bad_name
    inc ecx
    jmp .measure
.measured:
    test ecx, ecx
    jz .bad_name
    cmp ecx, SV_VALUE - 1
    ja .bad_name
    call sh_var_find
    mov rbx, rax
    cmp r12d, 1
    je .remove
    lea edi, [r12d - 1]                 ; the value
    lea rsi, [r13 + 8]
    call sh_join
    lea rdi, [sh_joined]
    push rcx
    call strlen
    pop rcx
    cmp rax, SV_VALUE_MAX - 1
    ja .long
    test rbx, rbx
    jnz .value
    lea rbx, [sh_vars]                  ; a slot of its own
    xor eax, eax
.free:
    cmp eax, SH_VARS
    jae .full
    cmp byte [rbx + SV_NAME], 0
    je .claim
    add rbx, SV_SIZE
    inc eax
    jmp .free
.claim:
    mov rdi, rbx
    mov rsi, rdx
    rep movsb
    mov byte [rdi], 0
.value:
    lea rdi, [rbx + SV_VALUE]
    lea rsi, [sh_joined]
    mov ecx, SV_VALUE_MAX
    call rec_copyz
    clc
    jmp .out
.remove:
    test rbx, rbx
    jz .removed
    mov byte [rbx + SV_NAME], 0
.removed:
    clc
    jmp .out
.list:
    COLUMN 'name', FT_TEXT
    COLUMN 'value', FT_TEXT
    lea rbx, [sh_vars]
    xor r12d, r12d
.each:
    cmp r12d, SH_VARS
    jae .listed
    cmp byte [rbx + SV_NAME], 0
    je .each_next
    call rec_row
    xor edi, edi
    lea rsi, [rbx + SV_NAME]
    call rec_str
    mov edi, 1
    lea rsi, [rbx + SV_VALUE]
    call rec_str
.each_next:
    add rbx, SV_SIZE
    inc r12d
    jmp .each
.listed:
    clc
    jmp .out
.bad_name:
    KLOG "a variable's name is letters, digits and _ (%u at most)", SV_VALUE - 1
    stc
    jmp .out
.long:
    KLOG "a variable holds %u characters at most", SV_VALUE_MAX - 1
    stc
    jmp .out
.full:
    KLOG "there are %u variables already: 'set <name>' removes one", SH_VARS
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; linux <program> [arguments]: cmd_linux (linux.asm) reads them from
; [sh_args] as lx_args splits them, at spaces with ' and " keeping them
; together; the shell has split them already (EDI words, RSI them), so
; each goes back quoted where it has to be
sh_linux:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    lea rdi, [sh_joined]
    lea r8, [sh_joined + LINE_MAX - 8]  ; room for a ' as '"'"', a quote, the 0
    xor ebx, ebx                        ; the word
.word:
    cmp ebx, r12d
    jae .done
    test ebx, ebx
    jz .first
    mov byte [rdi], ' '
    inc rdi
.first:
    mov rsi, [r13 + rbx * 8]
    cmp byte [rsi], 0                   ; an empty word: ''
    je .quote
    mov rcx, rsi
.look:
    mov al, [rcx]
    test al, al
    jz .plain
    cmp al, ' '
    je .quote
    cmp al, 0x27
    je .quote
    cmp al, '"'
    je .quote
    inc rcx
    jmp .look
.plain:
    mov al, [rsi]
    test al, al
    jz .next
    cmp rdi, r8
    jae .long
    stosb
    inc rsi
    jmp .plain
.quote:
    cmp rdi, r8
    jae .long
    mov byte [rdi], 0x27
    inc rdi
.quoted:
    mov al, [rsi]
    test al, al
    jz .unquote
    cmp rdi, r8
    jae .long
    inc rsi
    cmp al, 0x27
    je .apostrophe
    stosb
    jmp .quoted
.apostrophe:                            ; '"'"': out, a ' in double quotes,
    mov eax, 0x22272227                 ; and back in
    stosd
    mov byte [rdi], 0x27
    inc rdi
    jmp .quoted
.unquote:
    mov byte [rdi], 0x27
    inc rdi
.next:
    inc ebx
    jmp .word
.done:
    mov byte [rdi], 0
    lea rax, [sh_joined]
    mov [sh_args], rax
    pop r13
    pop r12
    pop rbx
    jmp cmd_linux
.long:
    KLOG "that command is too long"
    pop r13
    pop r12
    pop rbx
    ret

cmd_info:
    push rbx
    xor ebx, ebx
.next:
    lea rax, [info_labels]
    mov rax, [rax + rbx * 8]
    imul rdx, rbx, INFO_LEN
    lea rcx, [info_lines]
    add rdx, rcx
    KLOG "%-10s %s", rax, rdx
    inc ebx
    cmp ebx, SYS_LINES
    jb .next
    pop rbx
    ret

; cpus: each logical CPU, in the dashboard's order
cmd_cpus:
    push rbx
    push r12
    COLUMN 'cpu', FT_TEXT
    COLUMN 'kind', FT_TEXT
    COLUMN 'apic', FT_INT
    COLUMN 'core', FT_INT
    COLUMN 'thread', FT_INT
    COLUMN 'clock', FT_INT, 0, ' MHz'
    COLUMN 'heat', FT_INT, 0, {G_DEGREE, 'C'}
    COLUMN 'jobs', FT_INT
    COLUMN 'mcycles', FT_INT
    xor r12d, r12d
.next:
    cmp r12d, [cpu_count]
    jae .done
    lea rax, [cpu_order]
    mov eax, [rax + r12 * 4]
    PERCPU rbx, rax
    call rec_row
    call ui_tile_label
    xor edi, edi
    lea rsi, [ui_buf]
    call rec_str
    mov rdi, [rbx + PC_KIND]
    call sh_kind_name
    mov edi, 1
    mov rsi, rax
    call rec_set
    mov edi, 2
    mov rsi, [rbx + PC_APIC_ID]
    call rec_set
    mov edi, 3
    mov rsi, [rbx + PC_CORE]
    call rec_set
    mov edi, 4
    mov rsi, [rbx + PC_THREAD]
    call rec_set
    mov edi, 5                          ; no reading (as under QEMU): none
    mov rsi, [rbx + PC_MHZ]
    call sh_set_reading
    mov edi, 6
    mov rsi, [rbx + PC_TEMP]
    call sh_set_reading
    mov edi, 7
    mov rsi, [rbx + PC_JOB_ITEMS]
    call rec_set
    mov edi, 8
    mov rsi, [rbx + PC_JOB_CYCLES]
    shr rsi, 20
    call rec_set
    inc r12d
    jmp .next
.done:
    clc
    pop r12
    pop rbx
    ret

; sh_set_reading(EDI = column, RSI = a reading, 0 if there is none).
; Preserves all.
sh_set_reading:
    test rsi, rsi
    jz rec_none
    jmp rec_set

; sh_kind_name(RDI = CPU_KIND_*) -> RAX = perf, eff or core
sh_kind_name:
    lea rax, [str_sh_perf]
    cmp rdi, CPU_KIND_P
    je .out
    lea rax, [str_sh_eff]
    cmp rdi, CPU_KIND_E
    je .out
    lea rax, [str_sh_core]
.out:
    ret

cmd_pci:
    push rbx
    push r12
    xor r12d, r12d
    lea rbx, [pci_devices]
.next:
    cmp r12d, [pci_count]
    jae .done
    mov rdi, rbx
    lea rsi, [ui_buf2]
    call pci_describe
    movzx eax, byte [rbx + PE_BUS]
    movzx ecx, byte [rbx + PE_DEV]
    movzx edx, byte [rbx + PE_FN]
    movzx r8d, word [rbx + PE_VENDOR]
    movzx r9d, word [rbx + PE_DEVICE]
    lea r10, [ui_buf2]
    lea r11, [str_sh_vmd]
    cmp byte [rbx + PE_SEG], 0
    jne .say
    lea r11, [str_sh_novmd]
.say:
    KLOG "  %s%02x:%02x.%u  %04x:%04x  %s", r11, rax, rcx, rdx, r8, r9, r10
    add rbx, PCI_ENTRY
    inc r12d
    jmp .next
.done:
    pop r12
    pop rbx
    ret

cmd_acpi:
    push rbx
    xor ebx, ebx
.next:
    cmp ebx, [acpi_table_count]
    jae .done
    lea rax, [acpi_table_sigs]
    mov eax, [rax + rbx * 4]
    mov [ui_buf], eax
    mov byte [ui_buf + 4], 0
    lea rax, [acpi_table_ptrs]
    mov rdx, [rax + rbx * 8]            ; mapped address
    mov rcx, rdx
    sub rcx, [phys_base]                ; physical address
    mov edx, [rdx + 4]                  ; length
    lea rax, [ui_buf]
    KLOG "  %s  at %p  %u bytes", rax, rcx, rdx
    inc ebx
    jmp .next
.done:
    pop rbx
    ret

cmd_demo:
    cmp byte [mandel_ok], 0
    je .unsupported
    xor byte [demo_on], 1
    cmp byte [demo_on], 0
    je .off
    KLOG "demo on"
    ret
.off:
    KLOG "demo paused (the cores go back to sleep)"
    ret
.unsupported:
    KLOG "this CPU has no AVX2 + FMA"
    ret

cmd_bench:
    cmp byte [mandel_ok], 0
    je cmd_demo.unsupported
    mov eax, [cpus_online]
    KLOG "rendering one frame on 1 core, then on %u threads...", rax
    call mandel_bench
    mov rax, [bench_one_cycles]
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_per_ms]
    mov r8, rax                         ; tenths of a ms
    mov rax, [bench_all_cycles]
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_per_ms]
    mov r9, rax
    mov rax, [bench_one_cycles]
    imul rax, rax, 10
    xor edx, edx
    mov rcx, [bench_all_cycles]
    test rcx, rcx
    jz .no_speedup
    div rcx
.no_speedup:
    mov r10, rax                        ; speedup in tenths
    mov rax, [bench_iters]              ; tenths of G iter/s, all cores
    mov rcx, [bench_all_cycles]
    xor r11d, r11d
    test rcx, rcx
    jz .report
    mul qword [tsc_hz]
    div rcx
    mov r11, rax                        ; iterations a second
.report:
    KLOG "  1 core   %t ms", r8
    cmp r11, 1000000000
    jb .mega
    mov rax, r11
    xor edx, edx
    mov ecx, 100000000
    div rcx
    KLOG {"  all      %t ms   ", G_MIDDOT, " speedup %t", G_TIMES, "   ", G_MIDDOT, " %t G iter/s"}, r9, r10, rax
    ret
.mega:
    mov rax, r11
    xor edx, edx
    mov ecx, 1000000
    div rcx
    KLOG {"  all      %t ms   ", G_MIDDOT, " speedup %t", G_TIMES, "   ", G_MIDDOT, " %u M iter/s"}, r9, r10, rax
    ret

cmd_clear:
    call con_clear
    ret

cmd_uptime:
    call uptime_ms
    KLOG "up %u ms since power-on", rax
    ret

cmd_echo:
    KLOG "%s", qword [sh_args]
    ret

cmd_reboot:
    KLOG "rebooting..."
    call log_final
    jmp power_reboot

cmd_poweroff:
    KLOG "powering off..."
    call log_final
    jmp power_off

section .rodata
str_prompt:     db 'axiom> ', 0
str_sh_vmd:     db 'vmd ', 0
str_sh_novmd:   db 0
str_ctrl_c:     db '^C', 10, 0
str_sh_claude:  db 'claude', 0
str_sh_key:     db 'key', 0
str_sh_secret:  db 'claude key (not logged)', 0
str_sh_where:   db 'where', 0
str_sh_perf:    db 'perf', 0
str_sh_eff:     db 'eff', 0
str_sh_core:    db 'core', 0
str_sh_net:     db 'net', 0
str_sh_store:   db 'store', 0
str_sh_desk:    db 'desk', 0
str_sh_files:   db 'files', 0
str_sh_sound:   db 'sound', 0
align 8
sh_grants_names: dq str_sh_net, AW_NET, str_sh_store, AW_STORE, str_sh_desk, AW_DESK
                dq str_sh_files, AW_FILES, str_sh_sound, AW_SOUND, 0, 0
sh_escapable:   db ' "$|>;&\', 0x27, 0   ; what a \ takes as it is
sh_tok_pipe:    db '|', 0
sh_tok_gt:      db '>', 0
sh_tok_add:     db '>>', 0

%macro COMMAND 3                        ; name, handler, help: it prints
    dq %%name, %2, %%help, 0, 0
    [section .rodata]
    %%name: db %1, 0
    %%help: db %3, 0
    __SECT__
%endmacro

%macro VERB 3                           ; name, handler, help: it takes words
    dq %%name, %2, %%help, 0, CF_REC    ; (EDI, RSI) and gives records
    [section .rodata]
    %%name: db %1, 0
    %%help: db %3, 0
    __SECT__
%endmacro

%macro THING 3                          ; name, its actions, help
    dq %%name, 0, %%help, %2, CF_REC
    [section .rodata]
    %%name: db %1, 0
    %%help: db %3, 0
    __SECT__
%endmacro

%macro ACTION 4-5 CF_REC                ; name ('' for the default), handler,
    dq %%name, %2, %%args, %%help, %5   ; what it takes, what it does [, 0 if
    [section .rodata]                   ; it prints]
    %%name: db %1, 0
    %%args: db %3, 0
    %%help: db %4, 0
    __SECT__
%endmacro

%macro MEMNAME 1
    dq %%s
    [section .rodata]
    %%s: db %1, 0
    __SECT__
%endmacro

section .data
align 8
commands:
    VERB    'help',     cmd_help,     'help [command]: every command, or what a thing can do'
    THING   'files',    files_actions, 'the files of the volume in use: list, show, copy, move, new, write, remove, find'
    VERB    'go',       cmd_go,       'go [folder]: there (to / alone)'
    VERB    'here',     cmd_here,     'the folder you are in'
    VERB    'set',      cmd_set,      'set [name [value...]]: every variable ($name), one removed, or one set'
    COMMAND 'shell',    cmd_shell,    'a new shell, in a window of its own'
    COMMAND 'screen',   cmd_screen,   "what this shell's window shows, as text, to the serial log"
    COMMAND 'win',      cmd_win,      'win [move <n> <x> <y> | size <n> <w> <h> | raise <n> | min <n> | zoom <n> | close <n>]: the windows'
    THING   'theme',    themes_actions, 'how the desktop looks: light or dark, its accent, its scale'
    COMMAND 'info',     cmd_info,     'what this machine is'
    VERB    'cpus',     cmd_cpus,     'each logical CPU: kind, core, clock, heat, work'
    THING   'heat',     heat_actions, "the CPU's temperature now, from its package's sensor"
    THING   'mem',      mem_actions,  'memory: what uses it, by firmware type, what an address is; a self-test'
    THING   'threads',  threads_actions, 'every thread; each CPU; a self-test of the scheduler; load to watch'
    THING   'tasks',    tasks_actions, 'every task: its threads and handles; one stopped'
    COMMAND 'objects',  cmd_objects,  'objects [test | audit | <task id>]: objects and tasks, the handles a task holds, the audit ring, or a self-test of capabilities'
    COMMAND 'rings',    cmd_rings,    'rings [test]: each ring, its entries and completions, and the thread that finishes requests; or a self-test'
    COMMAND 'run',      cmd_run,      'run <program> [arguments]: /EFI/AXIOM/<PROGRAM>.AXE in ring 3, as its name alone runs it (for one a command hides: run net)'
    COMMAND 'linux',    sh_linux,     'linux <program> [arguments]: a Linux program from the root in /LINUX on the boot stick; ctrl+C stops it'
    COMMAND 'user',     cmd_user,     'user [test]: programs run, their pages; or a self-test of ring 3'
    COMMAND 'pci',      cmd_pci,      'PCI Express functions'
    COMMAND 'acpi',     cmd_acpi,     'firmware ACPI tables'
    COMMAND 'usb',      usb_list,     'USB devices, hubs and what drives them'
    COMMAND 'disks',    cmd_disks,    'drives and their volumes'
    COMMAND 'iommu',    cmd_iommu,    'iommu [test]: VT-d units, the DMA domain of each driver, faults; or a self-test, an NVMe read refused'
    COMMAND 'nvme',     cmd_nvme,     'nvme [test]: NVMe controllers and their queues; or a self-test, reading from every CPU at once'
    COMMAND 'store',    cmd_store,    'store [put|get|rm|ls|diff|commit|abort|log|snap|rollback|undo|verify|format|test]: the object store'
    COMMAND 'vol',      cmd_vol,      'vol <n> [rw|ro]: pick a volume, allow writes'
    COMMAND 'date',     cmd_date,     'the clock'
    THING   'sound',    snd_actions,  'the sound device and its volume; a test tone'
    COMMAND 'net',      cmd_net,      'network interfaces, link and address'
    COMMAND 'ip',       cmd_ip,       'ip <a.b.c.d/n> [gateway] [dns]: set the address by hand'
    COMMAND 'ip6',      cmd_ip6,      'ip6: IPv6 addresses and neighbours; ip6 <address>/64 [router] [dns], ip6 auto, ip6 prefer [off]'
    COMMAND 'dhcp',     cmd_dhcp,     'ask the network for an address'
    COMMAND 'ping',     cmd_ping,     'ping <address or name> [count]'
    COMMAND 'host',     cmd_host,     'host <name>: look up its address'
    COMMAND 'arp',      cmd_arp,      'the neighbours Axiom knows'
    COMMAND 'http',     cmd_http,     'http [-k] <[https://]host[:port][/path]> [file]: fetch a page; -k: no certificate check'
    COMMAND 'ask',      cmd_ask,      'ask <question>: ask Claude; the conversation goes on'
    COMMAND 'claude',   cmd_claude,   'claude [key <key>|model <name>|server <url> [-k]|new]: settings for ask'
    COMMAND 'httpd',    cmd_httpd,    'httpd <port>: serve the current volume over HTTP, read only; httpd stop'
    COMMAND 'tcp',      cmd_tcp,      'TCP connections; tcp echo <port>, tcp stop <port>'
    COMMAND 'sockets',  cmd_sockets,  'what programs have open on the network'
    COMMAND 'crypto',   cmd_crypto,   'check the TLS crypto against its test vectors, and time it'
    COMMAND 'log',      cmd_log,      'log [save|on|off]: AXIOM.LOG on the boot stick'
    COMMAND 'demo',     cmd_demo,     'pause or resume the Mandelbrot zoom'
    COMMAND 'bench',    cmd_bench,    'one core against all of them'
    COMMAND 'uptime',   cmd_uptime,   'time since power-on'
    COMMAND 'echo',     cmd_echo,     'echo <words>: them, as a line'
    COMMAND 'clear',    cmd_clear,    'clear the console (also ctrl+L)'
    COMMAND 'panic',    cmd_panic,    'panic [null|code|const|nx|stack|guard|twice|after|page|vm|thread]: test the crash screen, or a kind of memory fault'
    THING   'harness',  harness_actions, 'test runs on a machine no one is at (tools/hw/hp1.py): its script, its log'
    THING   'update',   update_actions, 'a new kernel: tried at the next start, then kept, or given up on its own'
    THING   'battery',  battery_actions, "a laptop's battery: its charge; kept between 75% and 80% on its charger"
    COMMAND 'reboot',   cmd_reboot,   'restart the machine'
    COMMAND 'poweroff', cmd_poweroff, 'turn the machine off'
    dq 0, 0, 0, 0, 0

files_actions:
    ACTION  '',       files_list,   '[folder | pattern]', 'what is there: name, kind, size, changed'
    ACTION  'show',   files_show,   '<file>', 'its lines'
    ACTION  'copy',   files_copy,   '<from>... <to>', 'a copy (into <to>, if it is a folder)'
    ACTION  'move',   files_move,   '<from>... <to>', 'moved (into <to>, if it is a folder)'
    ACTION  'new',    files_new,    '<name>[/]', 'an empty file, or a folder if the name ends in /'
    ACTION  'write',  files_write,  '<file> <text>...', 'the text and a newline, as all the file holds'
    ACTION  'remove', files_remove, '<path or pattern>...', 'gone (a folder only if it is empty)'
    ACTION  'find',   files_find,   '[pattern]', 'everything below here that matches, with its path'
    dq 0, 0, 0, 0, 0

mem_actions:
    ACTION  '',       mem_show,     '[<hex address>]', 'what uses memory: the kernel, page tables, the vm region, the heap'
    ACTION  'kinds',  mem_kinds,    '', 'memory by the firmware type it has'
    ACTION  'at',     mem_at,       '<hex address>', 'what is there, and how it is mapped'
    ACTION  'test',   mem_test,     '', 'a self-test of the heap and the vm region', 0
    dq 0, 0, 0, 0, 0

threads_actions:
    ACTION  '',       threads_list, '', 'every thread: state, CPU, class, its time on each kind of core'
    ACTION  'cpus',   threads_cpus, '', 'each CPU: kind, waiting, busy, switches, stolen, handed over'
    ACTION  'test',   threads_test, '', 'a self-test of the scheduler', 0
    ACTION  'spin',   threads_spin_words, '<n> [perf|eff|any] [seconds]', 'threads that only compute, to watch', 0
    dq 0, 0, 0, 0, 0

tasks_actions:
    ACTION  '',       tasks_list,   '', 'every task: who made it, its threads, handles, operations, refusals'
    ACTION  'stop',   tasks_stop,   '<id or program>...', 'programs stopped (by id, or each of that name), and what they started'
    dq 0, 0, 0, 0, 0

mem_type_names:
    MEMNAME 'reserved'
    MEMNAME 'loader code'
    MEMNAME 'loader data'
    MEMNAME 'boot code'
    MEMNAME 'boot data'
    MEMNAME 'runtime code'
    MEMNAME 'runtime data'
    MEMNAME 'conventional'
    MEMNAME 'unusable'
    MEMNAME 'ACPI reclaim'
    MEMNAME 'ACPI NVS'
    MEMNAME 'MMIO'
    MEMNAME 'MMIO ports'
    MEMNAME 'PAL code'
    MEMNAME 'persistent'
    MEMNAME 'other'

demo_on:        db 0

section .bss
alignb 8
sh_args:        resq 1                  ; the words, a space apart (sh_joined)
sh_redir_path:  resq 1                  ; > or >>: the file
sh_argv:        resq SH_WORDS + 1
sh_argc:        resd 1
sh_nstages:     resd 1
sh_stage:       resd SH_STAGES          ; where each stage begins in sh_argv
sh_status:      resb 1                  ; 1: the last command failed
sh_bg:          resb 1                  ; 1: the command came with '&'
alignb 4
sh_grants:      resd 1                  ; what +net, +store, +desk, +files granted (AW_*)
sh_redir:       resb 1                  ; 0, 1 for >, 2 for >>
shell_pending:  resb 1                  ; a terminal has the rest of a line to run
alignb 8
sh_line:        resb LINE_MAX + 8
sh_cmd:         resb LINE_MAX + 8
sh_joined:      resb LINE_MAX + 8
sh_wbuf:        resb SH_WBUF
sh_vars:        resb SH_VARS * SV_SIZE
