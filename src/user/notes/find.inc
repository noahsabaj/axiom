; =============================================================================
;  notes/find.inc - the bar under the tabs: find, replace, go to a line
;
;  ctrl+F opens it to find, ctrl+H with a second row to replace, ctrl+G to
;  go to a line; Esc or Done closes it. What is typed is found as it is
;  typed, from where the caret was; Enter finds the next (shift: the one
;  before), each found shown chosen and every other on the screen marked.
;  Aa: whether case matters.
; =============================================================================

BAR_FIND        equ 1
BAR_REPLACE     equ 2
BAR_GOTO        equ 3

H_FIND          equ 1                   ; what a press in the bar hits
H_REPL          equ 2
H_GOTO          equ 3
H_PREV          equ 4
H_NEXT          equ 5
H_CASE          equ 6
H_DONE          equ 7
H_ONE           equ 8
H_ALL           equ 9
HIT_SIZE        equ 20                  ; x, y, w, h, what
HITS_MAX        equ 16

section .text

; bar_open(RBX, EAX = BAR_*)
bar_open:
    push r12
    mov r12d, eax
    cmp qword [f_find + KE_BUF], 0      ; its fields, once
    jne .made
    lea rax, [find_text]
    mov [f_find + KE_BUF], rax
    mov dword [f_find + KE_CAP], 255
    lea rax, [repl_text]
    mov [f_repl + KE_BUF], rax
    mov dword [f_repl + KE_CAP], 255
    lea rax, [goto_text]
    mov [f_goto + KE_BUF], rax
    mov dword [f_goto + KE_CAP], 10
.made:
    mov [bar], r12d
    mov dword [kfocus], H_FIND
    cmp r12d, BAR_GOTO
    jne .find
    mov dword [kfocus], H_GOTO
    lea r8, [f_goto]
    xor ecx, ecx
    lea rsi, [goto_text]
    call kit_eset
    jmp .open
.find:
    call sel_range                      ; what is chosen, on one line: found
    je .all
    mov edx, ecx
    sub edx, eax
    cmp edx, 255
    ja .all
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    mov rdi, rsi
    mov ecx, edx
    mov al, 10
    repne scasb
    je .all
    mov ecx, edx
    lea r8, [f_find]
    call kit_eset
    jmp .found
.all:
    mov ecx, [f_find + KE_LEN]          ; else what was found last, all chosen
    mov [f_find + KE_CARET], ecx
    mov dword [f_find + KE_ANCHOR], 0
.found:
    call find_was
    call bar_found
.open:
    call measure
    call reveal
    mov dword [need], N_ALL
    pop r12
    ret

bar_close:
    mov dword [bar], 0
    mov dword [kfocus], 0
    call measure
    call reveal
    mov dword [need], N_ALL
    ret

; bar_key(RBX, EAX = the key, EDX = WM_*) -> CF if it is not the bar's
bar_key:
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    cmp r12d, K_ESC
    jne .enter
    test r13d, WM_CTRL
    jnz .theirs
    call bar_close
    jmp .ours
.enter:
    cmp r12d, 10
    jne .tab
    cmp dword [kfocus], H_GOTO
    je .go
    cmp dword [kfocus], H_REPL
    je .replace
    mov eax, 1
    test r13d, WM_SHIFT
    jz .step
    mov eax, -1
.step:
    call find_step
    jmp .ours
.replace:
    call replace_one
    jmp .ours
.go:
    call goto_line
    jmp .ours
.tab:
    cmp r12d, 9                         ; between the fields, to replace
    je .swap
    cmp r12d, K_BTAB
    jne .f3
.swap:
    test r13d, WM_CTRL
    jnz .theirs
    cmp dword [bar], BAR_REPLACE
    jne .ours
    xor dword [kfocus], H_FIND ^ H_REPL
    or dword [need], N_FIND
    jmp .ours
.f3:
    cmp r12d, K_F1 + 2
    je .theirs
    cmp r12d, K_UP                      ; up and down: nothing, here
    je .ours
    cmp r12d, K_DOWN
    je .ours
    test r13d, WM_CTRL                  ; ctrl: the field's, or the editor's
    jz .field
    cmp r12d, 1
    je .field
    cmp r12d, 3
    je .field
    cmp r12d, 22
    je .field
    cmp r12d, 24
    je .field
    jmp .theirs
.field:
    call bar_field
    mov eax, r12d
    mov edx, r13d
    call kit_ekey
    jc .theirs
    or dword [need], N_FIND
    cmp dword [kfocus], H_FIND
    jne .ours
    call find_was                       ; changed: found again, from the start
    jne .ours                           ; of what is chosen
    call bar_found
    call sel_range
    mov esi, eax
    mov eax, 1
    call find_from
    or dword [need], N_TEXT | N_FIND
.ours:
    clc
    jmp .out
.theirs:
    stc
.out:
    pop r13
    pop r12
    ret

; bar_field -> R8 = the field with the keys
bar_field:
    lea r8, [f_find]
    cmp dword [kfocus], H_REPL
    jne .goto
    lea r8, [f_repl]
.goto:
    cmp dword [kfocus], H_GOTO
    jne .out
    lea r8, [f_goto]
.out:
    ret

; find_was -> ZF clear if what is to be found is what it was (was_text);
; it is, now
find_was:
    mov ecx, [f_find + KE_LEN]
    cmp ecx, [was_len]
    jne .changed
    lea rsi, [find_text]
    lea rdi, [was_text]
    repe cmpsb
    jne .changed
    test esp, esp
    ret
.changed:
    mov ecx, [f_find + KE_LEN]
    mov [was_len], ecx
    lea rsi, [find_text]
    lea rdi, [was_text]
    rep movsb
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
;  Finding
; -----------------------------------------------------------------------------

; match(RBX, EAX = a place) -> ZF if what is to be found is there.
; Preserves all.
match:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov ecx, [f_find + KE_LEN]
    test ecx, ecx
    jz .no
    lea edx, [rax + rcx]
    cmp edx, [rbx + D_LEN]
    ja .no
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    lea rdi, [find_text]
.each:
    mov al, [rsi]
    mov dl, [rdi]
    cmp al, dl
    je .next
    cmp dword [case_on], 0
    jne .no
    or al, 0x20                         ; a letter, either case
    or dl, 0x20
    cmp al, dl
    jne .no
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
.next:
    inc rsi
    inc rdi
    dec ecx
    jnz .each
    xor eax, eax
    jmp .out
.no:
    test esp, esp
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; find(RBX, ESI = from, EAX = 1 on, -1 back) -> EAX = where it is next,
; round past the end if need be; -1 if nowhere
find:
    push r12
    push r13
    mov r12d, [rbx + D_LEN]
    sub r12d, [f_find + KE_LEN]         ; R12D: the last place it can be
    js .none
    cmp dword [f_find + KE_LEN], 0
    je .none
    mov r13d, esi                       ; R13D: where it began
    test eax, eax
    js .back
    mov eax, esi
.on:
    cmp eax, r12d
    jg .wrap
    call match
    je .out
    inc eax
    jmp .on
.wrap:
    xor eax, eax
.on2:
    cmp eax, r13d
    jae .none
    cmp eax, r12d
    jg .none
    call match
    je .out
    inc eax
    jmp .on2
.back:
    lea eax, [rsi - 1]
    cmp eax, r12d
    jle .back_each
    mov eax, r12d
.back_each:
    test eax, eax
    js .wrap_back
    call match
    je .out
    dec eax
    jmp .back_each
.wrap_back:
    mov eax, r12d
.back2:
    cmp eax, r13d
    jl .none
    call match
    je .out
    dec eax
    jmp .back2
.none:
    mov eax, -1
.out:
    pop r13
    pop r12
    ret

; find_step(RBX, EAX = 1 the next, -1 the one before): chosen
find_step:
    push rax
    call sel_range
    pop rdx
    test edx, edx
    js .back
    mov esi, ecx                        ; on: from after what is chosen
    mov eax, 1
    jmp find_from
.back:
    mov esi, eax                        ; back: from before it
    mov eax, -1

; find_from(RBX, ESI = from, EAX = 1 or -1): the next found, chosen
find_from:
    call find
    test eax, eax
    js .none
    mov [rbx + D_ANCHOR], eax
    add eax, [f_find + KE_LEN]
    mov [rbx + D_CARET], eax
    mov dword [rbx + D_WANT], -1
    call moved
    call bar_index
    or dword [need], N_FIND
    ret
.none:
    cmp dword [f_find + KE_LEN], 0
    je .out
    lea rax, [s_not_found]
    mov [said], rax
    or dword [need], N_STATUS
.out:
    ret

; bar_found(RBX): how many there are
bar_found:
    push r12
    xor ecx, ecx
    cmp dword [f_find + KE_LEN], 0
    je .counted
    mov r12d, [rbx + D_LEN]
    sub r12d, [f_find + KE_LEN]
    xor eax, eax
.each:
    cmp eax, r12d
    jg .counted
    cmp ecx, 9999
    jae .counted
    call match
    jne .next
    inc ecx
    add eax, [f_find + KE_LEN]
    jmp .each
.next:
    inc eax
    jmp .each
.counted:
    mov [found_n], ecx
    pop r12
    call bar_index
    or dword [need], N_FIND
    ret

; bar_index(RBX): which of them is the one chosen, 0 if none is
bar_index:
    push r12
    mov dword [found_i], 0
    call sel_range
    mov edx, ecx
    sub edx, eax
    cmp edx, [f_find + KE_LEN]
    jne .out
    call match
    jne .out
    mov r12d, eax                       ; count those before it, and it
    xor eax, eax
    xor ecx, ecx
.each:
    cmp eax, r12d
    jg .done
    call match
    jne .next
    inc ecx
    add eax, [f_find + KE_LEN]
    jmp .each
.next:
    inc eax
    jmp .each
.done:
    mov [found_i], ecx
.out:
    pop r12
    ret

; replace_one(RBX): what is chosen, if it is what is found, replaced; then
; the next found
replace_one:
    call sel_range
    mov edx, ecx
    sub edx, eax
    cmp edx, [f_find + KE_LEN]
    jne .next
    call match
    jne .next
    call ed_begin
    lea rsi, [repl_text]
    mov ecx, [f_repl + KE_LEN]
    test ecx, ecx
    jnz .put
    call del_chosen
    call reveal
    jmp .counted
.put:
    call put_text
.counted:
    call bar_found
.next:
    mov eax, 1
    jmp find_step

; replace_all(RBX): every one replaced, one undo
replace_all:
    push r12
    push r13
    push r14
    push r15
    cmp dword [f_find + KE_LEN], 0
    je .out
    call bar_found
    mov eax, [found_n]
    test eax, eax
    jz .none
    mov ecx, [f_repl + KE_LEN]          ; room for the new text
    imul ecx, eax
    add ecx, [rbx + D_LEN]
    inc ecx
    call scratch_room
    jc .out
    mov rdi, rax                        ; RDI: where it is made
    xor r12d, r12d                      ; R12D: where in the old
    xor r13d, r13d                      ; R13D: how many
    mov r14d, [rbx + D_LEN]
    sub r14d, [f_find + KE_LEN]
.each:
    mov rsi, [rbx + D_BUF]
    cmp r12d, r14d
    jg .rest
    mov eax, r12d
    call match
    je .found
    mov al, [rsi + r12]
    stosb
    inc r12d
    jmp .each
.found:
    lea rsi, [repl_text]
    mov ecx, [f_repl + KE_LEN]
    rep movsb
    add r12d, [f_find + KE_LEN]
    inc r13d
    jmp .each
.rest:
    mov ecx, [rbx + D_LEN]
    sub ecx, r12d
    jle .made
    add rsi, r12
    rep movsb
.made:
    sub rdi, [scratch]
    mov r15d, edi
    mov eax, [rbx + D_CARET]            ; the caret stays near where it was
    mov [was_caret], eax
    call ed_begin
    xor esi, esi
    mov ecx, [rbx + D_LEN]
    call ed_delete
    xor esi, esi
    mov rdx, [scratch]
    mov ecx, r15d
    call ed_insert
    mov eax, [was_caret]
    cmp eax, [rbx + D_LEN]
    jbe .caret
    mov eax, [rbx + D_LEN]
.caret:
    xor edx, edx
    call caret_to
    call grew
    call bar_found
    lea rdi, [said_buf]                 ; "12 replaced"
    mov eax, r13d
    call put_dec
    lea rsi, [s_replaced]
    call str_cat
    mov byte [rdi], 0
    lea rax, [said_buf]
    mov [said], rax
    jmp .out
.none:
    lea rax, [s_not_found]
    mov [said], rax
.out:
    or dword [need], N_STATUS | N_TEXT | N_FIND
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; goto_line(RBX): to the line the field names, and the bar closes
goto_line:
    xor eax, eax
    xor ecx, ecx
    lea rsi, [goto_text]
.digit:
    cmp ecx, [f_goto + KE_LEN]
    jae .number
    movzx edx, byte [rsi + rcx]
    sub edx, '0'
    cmp edx, 9
    ja .next
    imul eax, eax, 10
    add eax, edx
    cmp eax, 100000000
    ja .number
.next:
    inc ecx
    jmp .digit
.number:
    test eax, eax
    jz .close
    dec eax
    cmp eax, [rbx + D_NLINES]
    jb .line
    mov eax, [rbx + D_NLINES]
    dec eax
.line:
    push rax
    call line_at
    xor edx, edx
    call caret_to
    pop rax
    mov ecx, [rows]                     ; in the middle of the text
    shr ecx, 1
    sub eax, ecx
    call scroll_to
.close:
    jmp bar_close

; -----------------------------------------------------------------------------
;  Drawing it, and pressing it
; -----------------------------------------------------------------------------

; row_found(RBX, R14D..R15D = a line's bytes, row_y): those found on it
; marked
row_found:
    cmp dword [bar], BAR_FIND
    je .marking
    cmp dword [bar], BAR_REPLACE
    jne .out
.marking:
    cmp dword [f_find + KE_LEN], 0
    je .out
    push r12
    mov r12d, r14d
.each:
    mov eax, r12d
    add eax, [f_find + KE_LEN]
    cmp eax, r15d
    ja .done
    mov eax, r12d
    call match
    jne .next
    call col_of
    sub eax, [rbx + D_LEFT]
    imul eax, [cw]
    add eax, [text_x]
    push rax
    mov eax, r12d
    add eax, [f_find + KE_LEN]
    call col_of
    sub eax, [rbx + D_LEFT]
    imul eax, [cw]
    add eax, [text_x]
    pop rdi
    mov edx, eax
    sub edx, edi
    cmp edi, [text_x]
    jge .in
    sub edi, [text_x]
    add edx, edi
    mov edi, [text_x]
.in:
    test edx, edx
    jle .skip
    mov esi, [row_y]
    mov ecx, [line_h]
    mov r8d, [c_match]
    call kit_fill
.skip:
    add r12d, [f_find + KE_LEN]
    jmp .each
.next:
    inc r12d
    jmp .each
.done:
    pop r12
.out:
    ret

; hit_add(EDI = x, ESI = y, EDX = w, ECX = h, R8D = what): where a press
; finds it, in hit_tab (a count, then HITS_MAX records). Preserves all but
; RAX.
hit_add:
    push r9
    mov r9, [hit_tab]
    mov eax, [r9]
    cmp eax, HITS_MAX
    jae .out
    inc dword [r9]
    imul eax, eax, HIT_SIZE
    lea r9, [r9 + rax + 8]
    mov [r9], edi
    mov [r9 + 4], esi
    mov [r9 + 8], edx
    mov [r9 + 12], ecx
    mov [r9 + 16], r8d
.out:
    pop r9
    ret

; hit_at(RSI = a table of hits, EDI = x, EDX = y) -> EAX = what is there,
; 0 if nothing; R8 = its record
hit_at:
    mov ecx, [rsi]
    add rsi, 8
.each:
    test ecx, ecx
    jz .none
    mov eax, edi
    sub eax, [rsi]
    js .next
    cmp eax, [rsi + 8]
    jge .next
    mov eax, edx
    sub eax, [rsi + 4]
    js .next
    cmp eax, [rsi + 12]
    jge .next
    mov eax, [rsi + 16]
    mov r8, rsi
    ret
.next:
    add rsi, HIT_SIZE
    dec ecx
    jmp .each
.none:
    xor eax, eax
    ret

paint_bar:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call cur_doc
    lea rax, [bar_hits]
    mov [hit_tab], rax
    mov dword [bar_hits], 0
    mov eax, [caret_on]
    and eax, [focused]
    mov [kit_caret], eax
    xor edi, edi
    mov esi, [tab_h]
    mov edx, [kit_w]
    mov ecx, [bar_h]
    mov r8d, [c_panel]
    call kit_fill
    xor edi, edi
    mov esi, [tab_h]
    add esi, [bar_h]
    dec esi
    mov edx, [kit_w]
    mov ecx, 1
    mov r8d, [c_sep]
    call kit_fill
    PX bar_pad, 10
    PX bar_fh, 24
    mov r13d, [tab_h]                   ; R13D: the row's top
    mov edi, 8
    call kit_pt
    add r13d, eax
    mov r12d, [bar_pad]                 ; R12D: where things go, from the left
    cmp dword [bar], BAR_GOTO
    jne .find
    lea rsi, [s_goto]                   ; Go to line [   ]
    call k_slen
    push rcx
    mov edx, [f_ui]
    call kit_text_w
    pop rcx
    push rax
    mov edx, [f_ui]
    mov esi, r13d
    push rcx
    mov ecx, [bar_fh]
    call kit_base
    pop rcx
    mov edx, eax
    lea rsi, [s_goto]
    mov edi, r12d
    mov r8d, [f_ui]
    mov r9d, [c_text2]
    call kit_text
    pop rax
    add r12d, eax
    add r12d, [bar_pad]
    mov edi, 110
    call kit_pt
    mov r14d, eax
    lea r8, [f_goto]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r9d, [f_ui]
    mov r10d, 1
    call kit_edraw
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r8d, H_GOTO
    call hit_add
    jmp .done_button
.find:
    mov edi, 340                        ; the field: what is left, 160 to 380
    call kit_pt
    mov r14d, [kit_w]
    sub r14d, eax
    mov edi, 160
    call kit_pt
    cmp r14d, eax
    jge .wide_enough
    mov r14d, eax
.wide_enough:
    mov edi, 380
    call kit_pt
    cmp r14d, eax
    jle .not_too_wide
    mov r14d, eax
.not_too_wide:
    lea r8, [f_find]
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r9d, [f_ui]
    xor r10d, r10d
    cmp dword [kfocus], H_FIND
    sete r10b
    call kit_edraw
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r8d, H_FIND
    call hit_add
    lea rdi, [count_buf]                ; 3 of 12, or none
    cmp dword [f_find + KE_LEN], 0
    je .counted
    mov eax, [found_n]
    test eax, eax
    jnz .some
    lea rsi, [s_no_results]
    call str_cat
    jmp .counted
.some:
    mov eax, [found_i]
    test eax, eax
    jz .total
    call put_dec
    lea rsi, [s_of]
    call str_cat
.total:
    mov eax, [found_n]
    call put_dec
    cmp dword [found_i], 0
    jne .counted
    lea rsi, [s_matches]
    cmp dword [found_n], 1
    jne .plural
    lea rsi, [s_match]
.plural:
    call str_cat
.counted:
    mov byte [rdi], 0
    lea rsi, [count_buf]
    call k_slen
    lea edi, [r12 + r14]
    add edi, [bar_pad]
    push rcx
    push rdi
    mov edx, [f_small]
    mov esi, r13d
    mov ecx, [bar_fh]
    call kit_base
    mov edx, eax
    pop rdi
    pop rcx
    lea rsi, [count_buf]
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call kit_text
    cmp dword [bar], BAR_REPLACE        ; the second row: replace with
    jne .buttons
    mov edi, 32
    call kit_pt
    lea r15d, [r13 + rax]               ; R15D: its top
    lea r8, [f_repl]
    mov edi, r12d
    mov esi, r15d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r9d, [f_ui]
    xor r10d, r10d
    cmp dword [kfocus], H_REPL
    sete r10b
    call kit_edraw
    mov edi, r12d
    mov esi, r15d
    mov edx, r14d
    mov ecx, [bar_fh]
    mov r8d, H_REPL
    call hit_add
    lea edi, [r12 + r14]
    add edi, [bar_pad]
    lea rsi, [s_replace]
    mov edx, 76
    mov r8d, H_ONE
    mov ecx, r15d
    call bar_button
    add edi, eax
    mov edx, [bar_pad]
    shr edx, 1
    add edi, edx
    lea rsi, [s_all]
    mov edx, 50
    mov r8d, H_ALL
    mov ecx, r15d
    call bar_button
.buttons:
    mov edi, 60                         ; at the right: < > Aa Done
    call kit_pt
    mov edi, [kit_w]
    sub edi, [bar_pad]
    sub edi, eax
    push rdi
    lea rsi, [s_done]
    mov edx, 60
    mov r8d, H_DONE
    mov ecx, r13d
    call bar_button
    pop rdi
    push rdi
    mov edi, 44
    call kit_pt
    pop rdi
    sub edi, eax
    push rdi
    lea rsi, [s_case]
    mov edx, 34
    mov r8d, H_CASE
    mov ecx, r13d
    call bar_button
    pop rdi
    push rdi
    mov edi, 64
    call kit_pt
    pop rdi
    sub edi, eax
    push rdi
    lea rsi, [s_empty]
    mov edx, 28
    mov r8d, H_PREV
    mov ecx, r13d
    call bar_button
    pop rdi
    push rdi
    add edi, eax                        ; and its chevron
    mov edx, eax
    shr edx, 1
    sub edi, edx
    mov esi, r13d
    mov eax, [bar_fh]
    shr eax, 1
    add esi, eax
    mov edx, -1
    call chevron
    pop rdi
    push rdi
    mov edi, 30
    call kit_pt
    pop rdi
    add edi, eax
    push rdi
    lea rsi, [s_empty]
    mov edx, 28
    mov r8d, H_NEXT
    mov ecx, r13d
    call bar_button
    pop rdi
    mov edx, eax
    shr edx, 1
    add edi, edx
    mov esi, r13d
    mov eax, [bar_fh]
    shr eax, 1
    add esi, eax
    mov edx, 1
    call chevron
    jmp .out
.done_button:
    mov edi, 60
    call kit_pt
    mov edi, [kit_w]
    sub edi, [bar_pad]
    sub edi, eax
    lea rsi, [s_done]
    mov edx, 60
    mov r8d, H_DONE
    mov ecx, r13d
    call bar_button
.out:
    mov dword [kit_caret], 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; bar_button(EDI = x, ECX = y, RSI = its label, EDX = its width in points,
; R8D = what it is) -> EAX = its width; RDI kept
bar_button:
    push rdi
    push rsi
    push rcx
    push r8
    mov edi, edx
    call kit_pt
    mov edx, eax
    pop r8
    pop rsi                             ; y
    pop rax                             ; its label
    pop rdi
    push rdi
    push rdx
    mov ecx, [bar_fh]
    push rax
    call hit_add
    pop rax
    mov r9d, 0
    cmp r8d, H_CASE                     ; Aa, while on
    jne .draw
    cmp dword [case_on], 0
    je .draw
    mov r9d, KB_DEFAULT
.draw:
    mov r8, rax
    call kit_button
    pop rax
    pop rdi
    ret

; chevron(EDI = x, ESI = y, its centre, EDX = -1 left, 1 right)
chevron:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, 4
    call kit_pt
    shl eax, 4
    mov ebx, eax                        ; EBX: half its height, in 16ths
    shl r12d, 4
    shl r13d, 4
    add r12d, 8
    add r13d, 8
    mov eax, ebx
    shr eax, 1
    imul eax, r14d                      ; the point, half as far out
    add eax, r12d
    mov [chev_x], eax
    mov eax, ebx
    shr eax, 1
    imul eax, r14d
    neg eax
    add eax, r12d
    mov r12d, eax                       ; R12D: the ends' x
    mov edi, 3
    call kit_pt
    lea r8d, [rax * 8]
    push r8
    mov edi, r12d
    mov esi, r13d
    sub esi, ebx
    mov edx, [chev_x]
    mov ecx, r13d
    mov r9d, [c_text2]
    call kit_stroke
    pop r8
    mov edi, r12d
    lea esi, [r13 + rbx]
    mov edx, [chev_x]
    mov ecx, r13d
    mov r9d, [c_text2]
    call kit_stroke
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; k_slen(RSI = NUL-ended) -> ECX = its bytes. Preserves others.
k_slen:
    push rdi
    push rax
    mov rdi, rsi
    call k_strlen
    mov ecx, eax
    pop rax
    pop rdi
    ret

; bar_press(RBX): a press in the bar
bar_press:
    lea rsi, [bar_hits]
    mov edi, [kit_ev + WE_X]
    mov edx, [kit_ev + WE_Y]
    call hit_at
    cmp eax, H_FIND
    je .field
    cmp eax, H_REPL
    je .field
    cmp eax, H_GOTO
    je .field
    cmp eax, H_PREV
    je .prev
    cmp eax, H_NEXT
    je .next
    cmp eax, H_CASE
    je .case
    cmp eax, H_DONE
    je bar_close
    cmp eax, H_ONE
    je replace_one
    cmp eax, H_ALL
    je replace_all
    ret
.field:
    mov [kfocus], eax
    call bar_field
    mov edi, [kit_ev + WE_X]
    xor esi, esi
    mov r9d, [f_ui]
    call kit_eclick
    or dword [need], N_FIND | N_TEXT
    ret
.prev:
    mov eax, -1
    jmp find_step
.next:
    mov eax, 1
    jmp find_step
.case:
    xor dword [case_on], 1
    call bar_found
    or dword [need], N_FIND | N_TEXT
    ret

section .rodata
s_goto:         db 'Go to line', 0
s_no_results:   db 'No results', 0
s_of:           db ' of ', 0
s_match:        db ' match', 0
s_matches:      db ' matches', 0
s_replace:      db 'Replace', 0
s_all:          db 'All', 0
s_done:         db 'Done', 0
s_case:         db 'Aa', 0
s_empty:        db 0
s_not_found:    db 'Not found.', 0
s_replaced:     db ' replaced.', 0

section .bss
alignb 8
f_find:         resb KE_SIZE
f_repl:         resb KE_SIZE
f_goto:         resb KE_SIZE
bar:            resd 1                  ; BAR_*, 0 if it is closed
kfocus:         resd 1                  ; 0: the text has the keys; else H_*
case_on:        resd 1
found_n:        resd 1
found_i:        resd 1
was_len:        resd 1
bar_pad:        resd 1
bar_fh:         resd 1
chev_x:         resd 1
hit_tab:        resq 1                  ; where hit_add puts them
bar_hits:       resb 8 + HITS_MAX * HIT_SIZE
find_text:      resb 256
was_text:       resb 256
repl_text:      resb 256
goto_text:      resb 16
count_buf:      resb 32
said_buf:       resb 48
