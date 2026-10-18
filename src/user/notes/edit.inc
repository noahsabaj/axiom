; =============================================================================
;  notes/edit.inc - the keys and the mouse, in the text: moving, choosing,
;  typing, and what ctrl does
;
;  on_key(EAX = the key, EDX = WM_*), on_press, on_move, on_wheel: from
;  the window's events (kit_ev). What a key does to the text is one undo: a
;  run of typing is one too, until the caret is moved.
; =============================================================================

section .text

on_key:
    mov qword [said], 0
    or dword [need], N_STATUS
    cmp dword [sheet], 0
    jne panel_key
    push rbx
    call cur_doc
    cmp dword [kfocus], 0               ; the bar's field has the keys
    je .text
    push rax
    push rdx
    call bar_key
    pop rdx
    pop rax
    jnc .out
.text:
    call edit_key
.out:
    pop rbx
    ret

; edit_key(RBX, EAX = the key, EDX = WM_*)
edit_key:
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    test r13d, WM_CTRL
    jz .plain
    cmp r12d, 26                        ; ctrl+letter
    ja .ctrl_other
    test r12d, r12d
    jz .out
    lea rcx, [ctrl_keys]
    call [rcx + r12 * 8 - 8]
    jmp .out
.ctrl_other:
    cmp r12d, '='
    je .larger
    cmp r12d, '+'
    je .larger
    cmp r12d, '-'
    je .smaller
    cmp r12d, '0'
    je .zoom_reset
    cmp r12d, 0x1F                      ; ctrl+/
    je .comment
    cmp r12d, K_BTAB
    je .tab_last
    cmp r12d, K_PGUP
    je .tab_last
    cmp r12d, K_PGDN
    je .tab_next
    cmp r12d, K_UP
    je .line_up
    cmp r12d, K_DOWN
    je .line_down
    cmp r12d, K_HOME
    je .start
    cmp r12d, K_END
    je .end
    jmp .plain                          ; ctrl+arrows: by words
.larger:
    mov eax, [zoom]
    push rax
    inc dword [zoom]
    jmp .zoomed
.smaller:
    mov eax, [zoom]
    push rax
    dec dword [zoom]
    jmp .zoomed
.zoom_reset:
    push -1000                          ; nothing to say
    mov dword [zoom], 0
.zoomed:
    call measure
    pop rax
    cmp eax, [zoom]                     ; as far as the font goes: say so
    jne .zoom_seen
    lea rax, [s_zoom_max]
    cmp r12d, '-'
    jne .zoom_said
    lea rax, [s_zoom_min]
.zoom_said:
    mov [said], rax
.zoom_seen:
    call reveal
    mov dword [need], N_ALL
    jmp .out
.comment:
    call cmd_comment
    jmp .out
.tab_last:
    mov eax, -1
    call tab_step
    jmp .out
.tab_next:
    mov eax, 1
    call tab_step
    jmp .out
.line_up:
    mov eax, [rbx + D_TOP]
    dec eax
    call scroll_to
    jmp .out
.line_down:
    mov eax, [rbx + D_TOP]
    inc eax
    call scroll_to
    jmp .out
.start:
    xor eax, eax
    mov edx, r13d
    call caret_to
    jmp .out
.end:
    mov eax, [rbx + D_LEN]
    mov edx, r13d
    call caret_to
    jmp .out
.plain:
    test r13d, WM_ALT                   ; alt+up and down: move the lines
    jz .keys
    cmp r12d, K_UP
    jne .alt_down
    mov eax, -1
    call cmd_move_lines
    jmp .out
.alt_down:
    cmp r12d, K_DOWN
    jne .keys
    mov eax, 1
    call cmd_move_lines
    jmp .out
.keys:
    mov eax, r12d
    cmp eax, 8
    je .backspace
    cmp eax, 9
    je .tab
    cmp eax, 10
    je .enter
    cmp eax, K_ESC
    je .escape
    cmp eax, K_BTAB
    je .outdent
    cmp eax, K_DEL
    je .delete
    cmp eax, K_F1 + 2                   ; F3
    je .again
    cmp eax, K_LEFT
    je .left
    cmp eax, K_RIGHT
    je .right
    cmp eax, K_UP
    je .up
    cmp eax, K_DOWN
    je .down
    cmp eax, K_HOME
    je .home
    cmp eax, K_END
    je .line_end
    cmp eax, K_PGUP
    je .page_up
    cmp eax, K_PGDN
    je .page_down
    cmp eax, ' '
    jb .out
    cmp eax, 0x7F
    jae .out
    call type_char
    jmp .out
.backspace:
    mov edx, r13d
    call cmd_backspace
    jmp .out
.delete:
    mov edx, r13d
    call cmd_delete
    jmp .out
.tab:
    call cmd_tab
    jmp .out
.outdent:
    mov eax, -1
    call cmd_indent
    jmp .out
.enter:
    call cmd_enter
    jmp .out
.escape:
    cmp dword [bar], 0
    je .collapse
    call bar_close
    jmp .out
.collapse:
    mov eax, [rbx + D_CARET]
    xor edx, edx
    call caret_to
    jmp .out
.again:
    mov eax, 1
    test r13d, WM_SHIFT
    jz .again_dir
    mov eax, -1
.again_dir:
    call find_step
    jmp .out
.left:
    call sel_range                      ; what is chosen: to its start
    je .left_one
    test r13d, WM_SHIFT
    jnz .left_one
    xor edx, edx
    call caret_to
    jmp .out
.left_one:
    mov eax, [rbx + D_CARET]
    test r13d, WM_CTRL | WM_ALT
    jz .left_char
    call word_back
    jmp .left_go
.left_char:
    call char_back
.left_go:
    mov edx, r13d
    call caret_to
    jmp .out
.right:
    call sel_range
    je .right_one
    test r13d, WM_SHIFT
    jnz .right_one
    mov eax, ecx
    xor edx, edx
    call caret_to
    jmp .out
.right_one:
    mov eax, [rbx + D_CARET]
    test r13d, WM_CTRL | WM_ALT
    jz .right_char
    call word_forth
    jmp .right_go
.right_char:
    call char_forth
.right_go:
    mov edx, r13d
    call caret_to
    jmp .out
.up:
    mov eax, -1
    mov edx, r13d
    call caret_lines
    jmp .out
.down:
    mov eax, 1
    mov edx, r13d
    call caret_lines
    jmp .out
.page_up:
    mov eax, [rows]
    dec eax
    neg eax
    jmp .page
.page_down:
    mov eax, [rows]
    dec eax
.page:
    push rax
    add eax, [rbx + D_TOP]
    call scroll_to
    pop rax
    mov edx, r13d
    call caret_lines
    jmp .out
.home:
    mov eax, [rbx + D_CARET]            ; where its text begins, else its start
    call line_of
    call line_at
    mov ecx, eax
    mov rsi, [rbx + D_BUF]
.blank:
    cmp ecx, edx
    jae .homed
    cmp byte [rsi + rcx], ' '
    je .blank_next
    cmp byte [rsi + rcx], 9
    jne .homed
.blank_next:
    inc ecx
    jmp .blank
.homed:
    cmp ecx, [rbx + D_CARET]
    je .home_go
    xchg eax, ecx
.home_go:
    mov edx, r13d
    call caret_to
    jmp .out
.line_end:
    mov eax, [rbx + D_CARET]
    call line_of
    call line_at
    mov eax, edx
    mov edx, r13d
    call caret_to
.out:
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  Where things are
; -----------------------------------------------------------------------------

; sel_range(RBX) -> EAX = where what is chosen begins, ECX = ends; ZF if
; nothing is. Preserves others.
sel_range:
    mov eax, [rbx + D_CARET]
    mov ecx, [rbx + D_ANCHOR]
    cmp eax, ecx
    jbe .ordered
    xchg eax, ecx
.ordered:
    cmp eax, ecx
    ret

; caret_to(RBX, EAX = a place, EDX = WM_*: shift keeps the anchor)
caret_to:
    mov [rbx + D_CARET], eax
    test edx, WM_SHIFT
    jnz .kept
    mov [rbx + D_ANCHOR], eax
.kept:
    mov dword [rbx + D_WANT], -1
moved:
    mov dword [rbx + D_TYPING], 0
    or dword [need], N_TEXT | N_STATUS
    jmp reveal

; caret_lines(RBX, EAX = lines down, or up if less than 0, EDX = WM_*)
caret_lines:
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    mov eax, [rbx + D_WANT]             ; the column it keeps to
    test eax, eax
    jns .want
    mov eax, [rbx + D_CARET]
    call col_of
    mov [rbx + D_WANT], eax
.want:
    mov eax, [rbx + D_CARET]
    call line_of
    add eax, r12d
    js .first
    cmp eax, [rbx + D_NLINES]
    jae .last
    mov ecx, [rbx + D_WANT]
    call at_col
    jmp .go
.first:
    xor eax, eax
    jmp .go
.last:
    mov eax, [rbx + D_LEN]
.go:
    mov [rbx + D_CARET], eax
    test r13d, WM_SHIFT
    jnz .kept
    mov [rbx + D_ANCHOR], eax
.kept:
    call moved
    pop r13
    pop r12
    ret

; char_back(RBX, EAX = a place) -> EAX = the character's before it
char_back:
    test eax, eax
    jz .out
    mov rsi, [rbx + D_BUF]
.back:
    dec eax
    jz .out
    mov cl, [rsi + rax]
    and cl, 0xC0
    cmp cl, 0x80
    je .back
.out:
    ret

; char_forth(RBX, EAX) -> EAX = past the character there
char_forth:
    cmp eax, [rbx + D_LEN]
    jae .out
    mov rsi, [rbx + D_BUF]
.forth:
    inc eax
    cmp eax, [rbx + D_LEN]
    jae .out
    mov cl, [rsi + rax]
    and cl, 0xC0
    cmp cl, 0x80
    je .forth
.out:
    ret

; word_back(RBX, EAX) -> EAX = where the word before it begins
word_back:
    mov rsi, [rbx + D_BUF]
.spaces:
    test eax, eax
    jz .out
    push rax
    mov al, [rsi + rax - 1]
    call k_wordch
    pop rax
    jnz .word
    dec eax
    jmp .spaces
.word:
    test eax, eax
    jz .out
    push rax
    mov al, [rsi + rax - 1]
    call k_wordch
    pop rax
    jz .out
    dec eax
    jmp .word
.out:
    ret

; word_forth(RBX, EAX) -> EAX = where the word after it ends
word_forth:
    mov rsi, [rbx + D_BUF]
.spaces:
    cmp eax, [rbx + D_LEN]
    jae .out
    push rax
    mov al, [rsi + rax]
    call k_wordch
    pop rax
    jnz .word
    inc eax
    jmp .spaces
.word:
    cmp eax, [rbx + D_LEN]
    jae .out
    push rax
    mov al, [rsi + rax]
    call k_wordch
    pop rax
    jz .out
    inc eax
    jmp .word
.out:
    ret

; word_at(RBX, EAX) -> EAX..ECX = the word there (or the one character, if
; it is not in one)
word_at:
    mov rsi, [rbx + D_BUF]
    mov ecx, eax
    cmp eax, [rbx + D_LEN]
    jae .out
    push rax
    mov al, [rsi + rax]
    call k_wordch
    pop rax
    jz .one
.back:
    test eax, eax
    jz .forth
    push rax
    mov al, [rsi + rax - 1]
    call k_wordch
    pop rax
    jz .forth
    dec eax
    jmp .back
.forth:
    cmp ecx, [rbx + D_LEN]
    jae .out
    push rax
    mov al, [rsi + rcx]
    call k_wordch
    pop rax
    jz .out
    inc ecx
    jmp .forth
.one:
    push rax
    call char_forth
    mov ecx, eax
    pop rax
.out:
    ret

; lines_chosen(RBX) -> EAX = the first line what is chosen touches, ECX =
; the last (not the one it ends at the start of)
lines_chosen:
    call sel_range
    push rcx
    call line_of
    pop rcx
    push rax
    mov eax, ecx
    call line_of
    mov edx, eax                        ; EDX: the line it ends on
    pop rax
    cmp edx, eax
    jbe .one
    push rax
    push rdx
    mov eax, edx
    call line_at
    pop rdx
    cmp eax, ecx                        ; at its start: not that one
    pop rax
    jne .one
    dec edx
.one:
    mov ecx, edx
    ret

; shift_pos(EAX = a place) -> EAX = where it is after the edit at
; last_pos (last_n bytes put in, or taken out if less than 0)
shift_pos:
    mov ecx, [last_n]
    mov edx, [last_pos]
    test ecx, ecx
    js .removed
    cmp eax, edx
    jb .out
    add eax, ecx
    ret
.removed:
    neg ecx
    cmp eax, edx
    jbe .out
    add edx, ecx
    cmp eax, edx
    jae .after
    mov eax, [last_pos]
    ret
.after:
    sub eax, ecx
.out:
    ret

; lines_done(RBX, R12D..R13D = the lines changed): one line: what was
; chosen, moved as its text was; else all of them chosen
lines_done:
    cmp r12d, r13d
    jne .all
    mov eax, [was_caret]
    call shift_pos
    mov [rbx + D_CARET], eax
    mov eax, [was_anchor]
    call shift_pos
    mov [rbx + D_ANCHOR], eax
    jmp moved
.all:
    mov eax, r12d
    call line_at
    mov [rbx + D_ANCHOR], eax
    mov eax, r13d
    call line_at
    mov [rbx + D_CARET], edx
    jmp moved

; lines_begin(RBX) -> EAX..ECX = the lines chosen: one undo, from here
lines_begin:
    call ed_begin
    mov eax, [rbx + D_CARET]
    mov [was_caret], eax
    mov eax, [rbx + D_ANCHOR]
    mov [was_anchor], eax
    mov dword [last_n], 0
    mov dword [last_pos], 0
    jmp lines_chosen

; scratch_room(ECX = bytes) -> RAX = memory of that many, at least; CF if
; there is none
scratch_room:
    cmp ecx, [scratch_cap]
    jbe .have
    push rcx
    lea edi, [rcx + 4095]
    and edi, -4096
    push rdi
    call kit_alloc
    pop rdi
    pop rcx
    jc .out
    push rax
    push rdx
    push rdi
    mov edi, [scratch_h]
    test edi, edi
    jz .first
    call kit_free
.first:
    pop rdi
    pop rdx
    pop rax
    mov [scratch], rax
    mov [scratch_h], edx
    mov [scratch_cap], edi
.have:
    mov rax, [scratch]
    clc
.out:
    ret

; -----------------------------------------------------------------------------
;  Typing
; -----------------------------------------------------------------------------

; typing(RBX): what follows joins the run of typing, or begins one
typing:
    call sel_range
    jne .new
    cmp dword [rbx + D_TYPING], 0
    jne .out
.new:
    call ed_begin
    mov dword [rbx + D_TYPING], 1
.out:
    ret

; put_text(RBX, RSI = bytes, ECX = how many): in place of what is chosen,
; the caret after them
put_text:
    push r12
    push r13
    mov r12, rsi
    mov r13d, ecx
    call del_chosen
    mov esi, [rbx + D_CARET]
    mov rdx, r12
    mov ecx, r13d
    call ed_insert
    jnc .done
    lea rax, [s_full]
    mov [said], rax
.done:
    mov dword [rbx + D_WANT], -1
    call reveal
    call grew
    pop r13
    pop r12
    ret

; del_chosen(RBX): what is chosen, gone
del_chosen:
    call sel_range
    je .out
    sub ecx, eax
    mov esi, eax
    call ed_delete
.out:
    ret

; grew: the gutter as wide as the lines' numbers now need
grew:
    push rax
    mov eax, [gut_digits]
    push rax
    call gutter
    pop rax
    cmp eax, [gut_digits]
    je .out
    or dword [need], N_TEXT
.out:
    pop rax
    ret

type_char:
    mov [k_char_in], al
    call typing
    lea rsi, [k_char_in]
    mov ecx, 1
    jmp put_text

cmd_tab:
    call lines_chosen                   ; lines chosen: indent them
    cmp ecx, eax
    jne .lines
    call typing
    mov eax, [rbx + D_CARET]            ; else spaces, to the next stop
    call col_of
    and eax, TABW - 1
    mov ecx, TABW
    sub ecx, eax
    lea rsi, [s_four]
    jmp put_text
.lines:
    mov eax, 1
    jmp cmd_indent

; cmd_enter: a new line, as far in as this one; further after { ( [ or
; Python's :, and the } after the caret a line below
cmd_enter:
    push r12
    push r13
    push r14
    push r15
    call ed_begin
    mov dword [rbx + D_TYPING], 1
    mov ecx, 4096
    call scratch_room
    jc .out
    mov r12, rax                        ; R12: what goes in
    mov byte [r12], 10
    mov r13d, 1                         ; R13D: its bytes
    call sel_range
    mov r15d, eax                       ; R15D: where it goes
    mov [enter_end], ecx
    call line_of
    call line_at                        ; the line's indent, up to there
    mov rsi, [rbx + D_BUF]
    mov r14d, eax
.indent:
    cmp r14d, r15d
    jae .indented
    mov al, [rsi + r14]
    cmp al, ' '
    je .copy
    cmp al, 9
    jne .indented
.copy:
    cmp r13d, 1024
    jae .indented
    mov [r12 + r13], al
    inc r13d
    inc r14d
    jmp .indent
.indented:
    mov r14d, r15d                      ; what is before it, past blanks
.before:
    test r14d, r14d
    jz .put
    movzx eax, byte [rsi + r14 - 1]
    cmp al, ' '
    je .before_next
    cmp al, 9
    jne .opened
.before_next:
    dec r14d
    jmp .before
.opened:
    cmp al, '{'
    je .deeper
    cmp al, '('
    je .deeper
    cmp al, '['
    je .deeper
    cmp al, ':'
    jne .put
    cmp dword [rbx + D_LANG], L_PY
    jne .put
.deeper:
    mov edx, r13d                       ; EDX: where the indent ends
    mov dword [r12 + r13], '    '
    add r13d, TABW
    mov ecx, [enter_end]                ; a closer just after: a line below
    cmp ecx, [rbx + D_LEN]
    jae .put
    movzx ecx, byte [rsi + rcx]
    cmp cl, '}'
    je .closing
    cmp cl, ')'
    je .closing
    cmp cl, ']'
    jne .put
.closing:
    mov r14d, r13d                      ; R14D: the caret, in what goes in
    mov byte [r12 + r13], 10
    inc r13d
    mov ecx, 1
.again:
    cmp ecx, edx
    jae .closed
    mov al, [r12 + rcx]
    mov [r12 + r13], al
    inc r13d
    inc ecx
    jmp .again
.closed:
    mov rsi, r12
    mov ecx, r13d
    call put_text
    lea eax, [r15 + r14]
    xor edx, edx
    call caret_to
    mov dword [rbx + D_TYPING], 1
    jmp .out
.put:
    mov rsi, r12
    mov ecx, r13d
    call put_text
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; cmd_backspace(RBX, EDX = WM_*)
cmd_backspace:
    push r12
    mov r12d, edx
    call typing
    call sel_range
    jne .chosen
    mov eax, [rbx + D_CARET]
    test eax, eax
    jz .out
    test r12d, WM_CTRL | WM_ALT
    jz .spaces
    call word_back
    jmp .cut
.spaces:
    call line_of                        ; in an indent of spaces: back to a stop
    call line_at
    mov edx, eax                        ; EDX: the line's start
    mov ecx, eax
    mov rsi, [rbx + D_BUF]
.blank:
    cmp ecx, [rbx + D_CARET]
    jae .in_indent
    cmp byte [rsi + rcx], ' '
    jne .one
    inc ecx
    jmp .blank
.in_indent:
    mov eax, ecx
    sub eax, edx
    jz .one
    dec eax
    and eax, -TABW
    add eax, edx
    jmp .cut
.one:
    mov eax, [rbx + D_CARET]
    call char_back
.cut:
    mov ecx, [rbx + D_CARET]
    sub ecx, eax
    mov esi, eax
    call ed_delete
    jmp .done
.chosen:
    call del_chosen
.done:
    mov dword [rbx + D_WANT], -1
    call reveal
    call grew
.out:
    pop r12
    ret

; cmd_delete(RBX, EDX = WM_*)
cmd_delete:
    push r12
    mov r12d, edx
    call typing
    call sel_range
    jne .chosen
    mov eax, [rbx + D_CARET]
    cmp eax, [rbx + D_LEN]
    jae .out
    test r12d, WM_CTRL | WM_ALT
    jz .one
    call word_forth
    jmp .cut
.one:
    call char_forth
.cut:
    mov esi, [rbx + D_CARET]
    mov ecx, eax
    sub ecx, esi
    call ed_delete
    jmp .done
.chosen:
    call del_chosen
.done:
    mov dword [rbx + D_WANT], -1
    call reveal
    call grew
.out:
    pop r12
    ret

; cmd_indent(RBX, EAX = 1 in, -1 out): the lines chosen, by a tab stop
cmd_indent:
    push r12
    push r13
    push r14
    push r15
    mov r15d, eax
    call lines_begin
    mov r12d, eax                       ; R12D..R13D: the lines
    mov r13d, ecx
    mov r14d, ecx                       ; from the last, so places stay put
.each:
    cmp r14d, r12d
    jl .done
    mov eax, r14d
    call line_at
    test r15d, r15d
    js .out_one
    cmp eax, edx                        ; an empty line stays empty
    je .next
    mov esi, eax
    mov [last_pos], eax
    mov dword [last_n], TABW
    lea rdx, [s_four]
    mov ecx, TABW
    call ed_insert
    jmp .next
.out_one:
    mov esi, eax                        ; up to a stop of spaces, or a tab
    mov rdi, [rbx + D_BUF]
    xor ecx, ecx
    cmp eax, edx
    je .next
    cmp byte [rdi + rax], 9
    jne .spaces
    mov ecx, 1
    jmp .cut
.spaces:
    lea r8d, [rax + rcx]
    cmp r8d, edx
    jae .cut
    cmp ecx, TABW
    jae .cut
    cmp byte [rdi + r8], ' '
    jne .cut
    inc ecx
    jmp .spaces
.cut:
    test ecx, ecx
    jz .next
    mov [last_pos], esi
    mov [last_n], ecx
    neg dword [last_n]
    call ed_delete
.next:
    dec r14d
    jmp .each
.done:
    call lines_done
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; cmd_comment(RBX): the lines chosen made comments, or made code again
cmd_comment:
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov eax, [rbx + D_LANG]
    lea rcx, [comment_marks]
    mov rbp, [rcx + rax * 8]            ; RBP: how a comment begins here
    test rbp, rbp
    jz .out
    mov rdi, rbp
    call k_strlen
    mov r15d, eax                       ; R15D: its bytes
    call lines_begin
    mov r12d, eax
    mov r13d, ecx
    mov r14d, r12d                      ; all comments already? And how far in
    mov dword [ind_min], 0x7FFFFFFF
    mov dword [all_marked], 1
.scan:
    cmp r14d, r13d
    jg .scanned
    mov eax, r14d
    call line_indent                    ; EAX: where its text begins, ECX: how far
    cmp eax, edx
    je .scan_next                       ; blank
    cmp ecx, [ind_min]
    jge .not_less
    mov [ind_min], ecx
.not_less:
    call marked
    je .scan_next
    mov dword [all_marked], 0
.scan_next:
    inc r14d
    jmp .scan
.scanned:
    cmp dword [ind_min], 0x7FFFFFFF     ; all blank
    je .out
    mov r14d, r13d
.each:
    cmp r14d, r12d
    jl .done
    mov eax, r14d
    call line_indent
    cmp eax, edx
    je .next
    cmp dword [all_marked], 0
    je .mark
    mov esi, eax                        ; the mark, and a space after it
    mov ecx, r15d
    lea r8d, [rax + rcx]
    cmp r8d, edx
    jae .unmark
    mov rdi, [rbx + D_BUF]
    cmp byte [rdi + r8], ' '
    jne .unmark
    inc ecx
.unmark:
    mov [last_pos], esi
    mov [last_n], ecx
    neg dword [last_n]
    call ed_delete
    jmp .next
.mark:
    mov eax, r14d                       ; at the least indent of them
    mov ecx, [ind_min]
    call at_col
    push rax
    lea rdi, [mark_buf]
    xor ecx, ecx
.copy:
    mov dl, [rbp + rcx]
    test dl, dl
    jz .copied
    mov [rdi + rcx], dl
    inc ecx
    jmp .copy
.copied:
    mov byte [rdi + rcx], ' '
    inc ecx
    pop rsi
    mov [last_pos], esi
    mov [last_n], ecx
    lea rdx, [mark_buf]
    call ed_insert
.next:
    dec r14d
    jmp .each
.done:
    call lines_done
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; line_indent(RBX, EAX = a line) -> EAX = where its text begins, ECX = its
; column, EDX = where the line ends
line_indent:
    call line_at
    mov rsi, [rbx + D_BUF]
.each:
    cmp eax, edx
    jae .done
    cmp byte [rsi + rax], ' '
    je .next
    cmp byte [rsi + rax], 9
    jne .done
.next:
    inc eax
    jmp .each
.done:
    push rax
    push rdx
    call col_of
    mov ecx, eax
    pop rdx
    pop rax
    ret

; marked(RBX, RBP = a comment's mark, R15D = its bytes, EAX = where a
; line's text begins, EDX = its end) -> ZF if it begins with the mark
marked:
    lea ecx, [rax + r15]
    cmp ecx, edx
    ja .no
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    xor ecx, ecx
.each:
    cmp ecx, r15d
    jae .yes
    mov dl, [rsi + rcx]
    cmp dl, [rbp + rcx]
    jne .no
    inc ecx
    jmp .each
.yes:
    xor ecx, ecx
    ret
.no:
    test esp, esp
    ret

; cmd_move_lines(RBX, EAX = -1 up, 1 down): the lines chosen, past the one
; before or after them
cmd_move_lines:
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov ebp, eax
    call lines_chosen
    mov r12d, eax                       ; R12D..R13D: the lines
    mov r13d, ecx
    test ebp, ebp
    js .up
    lea eax, [r13 + 1]
    cmp eax, [rbx + D_NLINES]
    jae .out
    call line_at                        ; the one after: R14D..R15D
    mov r14d, eax
    mov r15d, edx
    mov eax, r12d
    call line_at
    push rax                            ; [rsp]: where they begin
    mov eax, r13d
    call line_at
    mov ecx, r15d                       ; the whole: theirs and the one after
    pop rax
    push rdx                            ; [rsp]: where they end
    push rax
    sub ecx, eax
    add ecx, 1
    call scratch_room
    jc .pop2
    mov rdi, rax
    mov rsi, [rbx + D_BUF]              ; the one after, a LF, then them
    add rsi, r14
    mov ecx, r15d
    sub ecx, r14d
    rep movsb
    mov byte [rdi], 10
    inc rdi
    pop rax
    pop rdx
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    mov ecx, edx
    sub ecx, eax
    rep movsb
    push rax                            ; its start, for the edit
    mov ecx, r15d                       ; the caret, as far on
    sub ecx, r14d
    inc ecx
    mov r14d, ecx                       ; R14D: how far they move
    jmp .replace
.up:
    test r12d, r12d
    jz .out
    lea eax, [r12 - 1]
    call line_at                        ; the one before: R14D..R15D
    mov r14d, eax
    mov r15d, edx
    mov eax, r12d
    call line_at
    push rax
    mov eax, r13d
    call line_at
    pop rax
    push rdx                            ; [rsp]: where they end
    push rax
    mov ecx, edx
    sub ecx, r14d
    add ecx, 1
    call scratch_room
    jc .pop2
    mov rdi, rax
    pop rax                             ; them, a LF, then the one before
    pop rdx
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    mov ecx, edx
    sub ecx, eax
    rep movsb
    mov byte [rdi], 10
    inc rdi
    mov rsi, [rbx + D_BUF]
    add rsi, r14
    mov ecx, r15d
    sub ecx, r14d
    rep movsb
    push r14                            ; its start, for the edit
    mov ecx, r15d
    sub ecx, r14d
    inc ecx
    neg ecx
    mov r14d, ecx
.replace:
    sub rdi, [scratch]
    mov r15d, edi                       ; R15D: the bytes made
    call ed_begin
    mov eax, [rbx + D_CARET]
    add eax, r14d
    mov [moved_caret], eax
    mov eax, [rbx + D_ANCHOR]
    add eax, r14d
    mov [moved_anchor], eax
    pop rsi                             ; where it begins
    push rsi
    mov ecx, r15d
    call ed_delete
    pop rsi
    mov rdx, [scratch]
    mov ecx, r15d
    call ed_insert
    mov eax, [moved_caret]
    mov [rbx + D_CARET], eax
    mov eax, [moved_anchor]
    mov [rbx + D_ANCHOR], eax
    call moved
    jmp .out
.pop2:
    add rsp, 16
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  What ctrl and a letter do
; -----------------------------------------------------------------------------

cmd_all:
    mov dword [rbx + D_ANCHOR], 0
    mov eax, [rbx + D_LEN]
    mov edx, WM_SHIFT
    jmp caret_to

cmd_copy:
    call sel_range
    je .out
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    sub ecx, eax
    call kit_cb_set
.out:
    ret

cmd_cut:
    call sel_range
    je .out
    call cmd_copy
    call ed_begin
    call del_chosen
    call reveal
    call grew
.out:
    ret

cmd_paste:
    mov ecx, [kit_cb_len]
    test ecx, ecx
    jz .out
    call ed_begin
    mov rsi, [kit_cb]
    call put_text
    mov dword [rbx + D_TYPING], 0
.out:
    ret

cmd_undo:
    test r13d, WM_SHIFT                 ; ctrl+shift+Z: redo
    jnz cmd_redo
    call ed_undo
    jmp undone
cmd_redo:
    call ed_redo
undone:
    call grew
    call reveal
    or dword [need], N_TEXT | N_STATUS | N_TABS | N_TITLE
    ret

cmd_duplicate:
    call sel_range                      ; what is chosen, again after it
    jne .chosen
    mov eax, [rbx + D_CARET]            ; else the line, below
    call line_of
    call line_at
    push rax
    push rdx
    mov ecx, edx
    sub ecx, eax
    inc ecx
    call scratch_room
    pop rdx
    pop rsi
    jc .out
    mov rdi, rax
    mov byte [rdi], 10
    inc rdi
    mov ecx, edx
    sub ecx, esi
    push rdx
    push rcx
    add rsi, [rbx + D_BUF]
    rep movsb
    pop rcx
    pop rsi                             ; at its end
    inc ecx
    mov eax, [rbx + D_CARET]            ; the caret, as far on in the new one
    add eax, ecx
    push rax
    call ed_begin
    mov rdx, [scratch]
    call ed_insert
    pop rax
    xor edx, edx
    call caret_to
    jmp .out
.chosen:
    sub ecx, eax
    push rax
    push rcx
    call scratch_room
    pop rcx
    pop rsi
    jc .out
    push rsi
    push rcx
    mov rdi, rax
    add rsi, [rbx + D_BUF]
    rep movsb
    pop rcx
    pop rsi
    push rsi
    push rcx
    add esi, ecx                        ; after it
    call ed_begin
    mov rdx, [scratch]
    call ed_insert
    pop rcx                             ; the copy, chosen
    pop rax
    add eax, ecx
    mov [rbx + D_ANCHOR], eax
    add eax, ecx
    mov [rbx + D_CARET], eax
    call moved
.out:
    call grew
    ret

cmd_new:
    call doc_new
    jc .out
    call tab_shown
.out:
    ret

cmd_close:
    mov eax, [cur]
    jmp tab_close

cmd_save:
    test r13d, WM_SHIFT
    jnz cmd_save_as
    cmp dword [rbx + D_NEW], 0
    jne cmd_save_as
    jmp save_doc
cmd_save_as:
    mov eax, S_SAVE
    jmp sheet_open

cmd_open:
    mov eax, S_OPEN
    jmp sheet_open

cmd_find:
    mov eax, BAR_FIND
    jmp bar_open
cmd_replace:
    mov eax, BAR_REPLACE
    jmp bar_open
cmd_goto:
    mov eax, BAR_GOTO
    jmp bar_open

cmd_tab_next:
    mov eax, 1
    test r13d, WM_SHIFT
    jz tab_step
    mov eax, -1
    jmp tab_step

cmd_none:
    ret

; save_doc(RBX): to its file; the status line says how it went
save_doc:
    call doc_save
    test rax, rax
    jnz .failed
    lea rax, [s_saved]
    mov [said], rax
    or dword [need], N_TABS | N_TITLE | N_STATUS
    clc
    ret
.failed:
    call error_text
    mov [said], rax
    or dword [need], N_STATUS
    stc
    ret

; error_text(RAX = E_*) -> RAX = what to say
error_text:
    lea rcx, [s_e_readonly]
    cmp rax, E_READONLY
    je .out
    lea rcx, [s_e_nofile]
    cmp rax, E_NOFILE
    je .out
    lea rcx, [s_e_exists]
    cmp rax, E_EXISTS
    je .out
    lea rcx, [s_e_nomem]
    cmp rax, E_NOMEM
    je .out
    lea rcx, [s_e_nofiles]
    cmp dword [ax_files], 0
    je .out
    lea rcx, [s_e_other]
.out:
    mov rax, rcx
    ret

; -----------------------------------------------------------------------------
;  Tabs
; -----------------------------------------------------------------------------

; tab_shown(EAX in cur): it is the one in front now
tab_shown:
    mov qword [st_doc], 0
    call cur_doc
    call gutter
    call bar_found
    mov dword [need], N_ALL
    ret

; tab_step(EAX = 1 the next, -1 the one before)
tab_step:
    add eax, [cur]
    jns .wrap_high
    mov eax, [ndocs]
    dec eax
.wrap_high:
    cmp eax, [ndocs]
    jb .set
    xor eax, eax
.set:
    mov [cur], eax
    jmp tab_shown

; tab_close(EAX = which): if it has changed, asked first
tab_close:
    push rbx
    mov [cur], eax
    call cur_doc
    call d_dirty
    je .close
    mov eax, S_CLOSE
    call sheet_open
    pop rbx
    ret
.close:
    pop rbx
tab_gone:                               ; RBX in cur: closed now
    push rbx
    call cur_doc
    call doc_close
    pop rbx
    cmp dword [ndocs], 0
    jne .rest
    mov dword [quitting], 2             ; the last: Notes ends
    ret
.rest:
    mov eax, [cur]
    cmp eax, [ndocs]
    jb .shown
    mov eax, [ndocs]
    dec eax
    mov [cur], eax
.shown:
    call tab_shown
    cmp dword [quitting], 0             ; quitting: the next changed one
    jne ask_quit
    ret

; ask_quit: each tab changed is asked about, then Notes ends
ask_quit:
    mov dword [quitting], 1
    xor eax, eax
.each:
    cmp eax, [ndocs]
    jae .done
    push rax
    mov [cur], eax
    call cur_doc
    call d_dirty
    pop rax
    jne .ask
    inc eax
    jmp .each
.ask:
    call tab_shown
    mov eax, S_CLOSE
    jmp sheet_open
.done:
    mov dword [quitting], 2
    ret

; -----------------------------------------------------------------------------
;  The mouse
; -----------------------------------------------------------------------------

on_press:
    cmp dword [sheet], 0
    jne panel_press
    push rbx
    push r12
    push r13
    call cur_doc
    mov r12d, [kit_ev + WE_X]
    mov r13d, [kit_ev + WE_Y]
    cmp dword [kit_ev + WE_CODE], 1
    jne .out
    cmp r13d, [tab_h]
    jl .tabs
    mov eax, [ed_y0]
    cmp r13d, eax
    jl .bar
    cmp r13d, [ed_y1]
    jge .out
    cmp dword [kfocus], 0               ; the keys back to the text
    je .text
    mov dword [kfocus], 0
    or dword [need], N_FIND
.text:
    mov edi, r12d
    mov esi, r13d
    call pos_at
    mov ecx, [kit_clicks]
    cmp ecx, 2
    je .word
    ja .line
    cmp r12d, [text_x]                  ; in the gutter: the line
    jl .line
    mov dword [dragging], 1
    xor edx, edx
    call caret_to
    jmp .out
.word:
    mov dword [dragging], 2
    call word_at
    mov [rbx + D_ANCHOR], eax
    mov [rbx + D_CARET], ecx
    mov [drag_a], eax
    mov [drag_b], ecx
    call moved
    jmp .out
.line:
    mov dword [dragging], 3
    call line_of
    push rax
    call line_at
    mov [rbx + D_ANCHOR], eax
    mov [drag_a], eax
    pop rax
    inc eax
    cmp eax, [rbx + D_NLINES]
    jb .next_line
    mov eax, [rbx + D_LEN]
    jmp .line_end
.next_line:
    call line_at
.line_end:
    mov [rbx + D_CARET], eax
    mov [drag_b], eax
    call moved
    jmp .out
.tabs:
    call tab_measure
    cmp r12d, edx                       ; the +
    jge .plus
    mov r8d, eax
    mov eax, r12d
    sub eax, ecx
    js .out
    xor edx, edx
    div r8d
    cmp eax, [ndocs]
    jae .out
    push rax
    mov edi, 28                         ; at its left: close it, if its ×
    call kit_pt                         ; or its dot shows
    mov ecx, eax
    pop rax
    cmp edx, ecx
    jae .pick
    cmp eax, [cur]
    je .close
    push rbx
    imul ebx, eax, D_SIZE
    lea rcx, [docs]
    add rbx, rcx
    call d_dirty
    pop rbx
    je .pick
.close:
    call tab_close
    jmp .out
.pick:
    cmp eax, [cur]
    je .out
    mov [cur], eax
    call tab_shown
    jmp .out
.plus:
    call cmd_new
    jmp .out
.bar:
    call bar_press
.out:
    pop r13
    pop r12
    pop rbx
    ret

on_move:
    cmp dword [sheet], 0
    jne .out
    cmp dword [dragging], 0
    je .out
    push rbx
    call cur_doc
    mov edi, [kit_ev + WE_X]
    mov esi, [kit_ev + WE_Y]
    cmp esi, [ed_y0]                    ; above or below: it scrolls
    jge .not_above
    mov eax, [rbx + D_TOP]
    dec eax
    call scroll_to
    mov esi, [ed_y0]
.not_above:
    cmp esi, [ed_y1]
    jl .in
    mov eax, [rbx + D_TOP]
    inc eax
    call scroll_to
    mov esi, [ed_y1]
    dec esi
.in:
    call pos_at
    cmp dword [dragging], 1
    je .char
    cmp dword [dragging], 2
    je .word
    call line_of                        ; by lines
    push rax
    call line_at
    mov ecx, eax
    pop rax
    cmp ecx, [drag_a]
    jae .line_after
    mov eax, ecx
    mov ecx, [drag_b]
    jmp .ends
.line_after:
    inc eax
    cmp eax, [rbx + D_NLINES]
    jb .next_line
    mov eax, [rbx + D_LEN]
    jmp .line_end
.next_line:
    call line_at
.line_end:
    mov ecx, [drag_a]
    jmp .ends
.word:
    call word_at
    cmp eax, [drag_a]
    jae .word_after
    mov ecx, [drag_b]
    jmp .ends
.word_after:
    mov eax, ecx
    mov ecx, [drag_a]
.ends:
    mov [rbx + D_ANCHOR], ecx
    mov [rbx + D_CARET], eax
    mov dword [rbx + D_WANT], -1
    call moved
    pop rbx
    ret
.char:
    mov edx, WM_SHIFT
    call caret_to
    pop rbx
.out:
    ret

on_wheel:
    cmp dword [sheet], 0
    jne panel_wheel
    push rbx
    call cur_doc
    mov eax, [kit_ev + WE_CODE]
    imul eax, eax, -3
    add eax, [rbx + D_TOP]
    call scroll_to
    pop rbx
    ret

; pos_at(RBX, EDI = x, ESI = y, in the window) -> EAX = the place in the
; text nearest
pos_at:
    mov eax, esi
    sub eax, [ed_y0]
    sub eax, [pad_top]
    cdq
    idiv dword [line_h]
    test edx, edx                       ; below zero: up a line
    jns .row
    dec eax
.row:
    add eax, [rbx + D_TOP]
    jns .not_above
    xor eax, eax
.not_above:
    cmp eax, [rbx + D_NLINES]
    jb .line
    mov eax, [rbx + D_NLINES]
    dec eax
.line:
    mov ecx, edi
    sub ecx, [text_x]
    jns .right
    xor ecx, ecx
.right:
    push rax
    mov eax, [cw]
    shr eax, 1
    add eax, ecx
    xor edx, edx
    div dword [cw]
    add eax, [rbx + D_LEFT]
    mov ecx, eax
    pop rax
    jmp at_col

section .rodata
align 8
ctrl_keys:      dq cmd_all, cmd_none, cmd_copy, cmd_duplicate      ; A B C D
                dq cmd_none, cmd_find, cmd_goto, cmd_replace       ; E F G H
                dq cmd_tab_next, cmd_none, cmd_none, cmd_none      ; I(tab) J K L
                dq cmd_none, cmd_new, cmd_open, cmd_none           ; M N O P
                dq cmd_none, cmd_none, cmd_save, cmd_none          ; Q R S T
                dq cmd_none, cmd_paste, cmd_close, cmd_cut         ; U V W X
                dq cmd_redo, cmd_undo                              ; Y Z
comment_marks:  dq 0, m_asm, m_c, m_hash, m_hash, 0, 0
m_asm:          db ';', 0
m_c:            db '//', 0
m_hash:         db '#', 0
s_four:         db '    '
s_full:         db 'There is no more room for text.', 0
s_saved:        db 'Saved.', 0
s_zoom_max:     db 'The text is at its largest.', 0
s_zoom_min:     db 'The text is at its smallest.', 0
s_e_readonly:   db 'The volume is read-only: say "vol <n> rw" in the shell to write it.', 0
s_e_nofile:     db 'There is no such folder.', 0
s_e_exists:     db 'That name is taken.', 0
s_e_nomem:      db 'There was not enough memory.', 0
s_e_nofiles:    db 'Notes was not given the files (run it with +files).', 0
s_e_other:      db 'It could not be saved.', 0

section .bss
alignb 8
scratch:        resq 1
scratch_h:      resd 1
scratch_cap:    resd 1
drag_a:         resd 1                  ; what a double or triple click chose
drag_b:         resd 1
ind_min:        resd 1
all_marked:     resd 1
moved_caret:    resd 1
moved_anchor:   resd 1
enter_end:      resd 1
was_caret:      resd 1
was_anchor:     resd 1
last_pos:       resd 1
last_n:         resd 1
k_char_in:      resb 4
mark_buf:       resb 8
