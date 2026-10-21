; =============================================================================
;  files/input.inc - the keys and the mouse
;
;  What has the keys: the folder's things (kfocus 0), the search, or a name
;  being changed. Over the window, a menu, an alert or a look takes them
;  first.
; =============================================================================

K_SEARCH        equ 1                   ; kfocus: what has the keys
K_RENAME        equ 2

SEARCH_CAP      equ 120
NAME_CAP        equ 200                 ; a name typed, in bytes

M_SEP           equ 0                   ; a menu's items
M_OPEN          equ 1
M_LOOK          equ 2
M_RENAME        equ 3
M_DUP           equ 4
M_COPY          equ 5
M_CUT           equ 6
M_DELETE        equ 7
M_NEWDIR        equ 8
M_NEWTXT        equ 9
M_PASTE         equ 10
M_ICONS         equ 11
M_LIST          equ 12
M_REREAD        equ 13
MENU_MAX        equ 16

section .text

; on_key(EAX = the key, EDX = the modifiers)
on_key:
    push rbx
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    cmp qword [said], 0                 ; what was said, said
    je .said
    mov qword [said], 0
    or dword [need], N_PATH
.said:
    mov eax, [over]
    cmp eax, O_MENU
    je .menu
    cmp eax, O_ALERT
    je .alert
    cmp eax, O_LOOK
    je .look
    cmp dword [kfocus], K_RENAME
    je .rename
    cmp dword [kfocus], K_SEARCH
    je .search
    call list_key
    jmp .out
.menu:
    call menu_key
    jmp .out
.alert:
    call alert_key
    jmp .out
.look:
    call look_key
    jmp .out
.rename:
    call rename_key
    jmp .out
.search:
    call search_key
.out:
    pop r13
    pop r12
    pop rbx
    ret

; list_key(R12D = the key, R13D = the modifiers): the folder's things have
; the keys
list_key:
    test r13d, WM_CTRL | WM_META
    jnz .ctrl
    test r13d, WM_ALT
    jnz .alt
    mov eax, r12d
    cmp eax, K_UP
    je .up
    cmp eax, K_DOWN
    je .down
    cmp eax, K_LEFT
    je .left
    cmp eax, K_RIGHT
    je .right
    cmp eax, K_HOME
    je .home
    cmp eax, K_END
    je .end
    cmp eax, K_PGUP
    je .page_up
    cmp eax, K_PGDN
    je .page_down
    cmp eax, 10
    je rename_start
    cmp eax, 8
    je go_up
    cmp eax, K_DEL
    je op_ask_delete
    cmp eax, 27
    je .esc
    cmp eax, 9
    je search_focus
    cmp eax, ' '
    je .space
    jb .out
    cmp eax, '~'
    jbe type_select
.out:
    ret
.space:
    cmp dword [ts_len], 0               ; typing a name: a blank in it
    je look_open
    call ax_now
    sub rax, [type_at]
    push rax
    mov edi, TYPE_US
    call ax_us
    pop rcx
    cmp rcx, rax
    jae look_open
    jmp type_select
.esc:
    cmp dword [f_search + KE_LEN], 0    ; the search first, then the choice
    jne search_empty
    mov dword [sel], -1
    or dword [need], N_MAIN | N_PATH
    ret
.up:
    mov eax, 1
    cmp dword [view], V_ICONS
    jne .back
    mov eax, [cols]
.back:
    neg eax
    jmp sel_move
.down:
    mov eax, 1
    cmp dword [view], V_ICONS
    jne sel_move
    mov eax, [cols]
    jmp sel_move
.left:
    cmp dword [view], V_ICONS
    jne .out
    mov eax, -1
    jmp sel_move
.right:
    cmp dword [view], V_ICONS
    jne .out
    mov eax, 1
    jmp sel_move
.home:
    xor eax, eax
    jmp sel_to
.end:
    mov eax, [n]
    dec eax
    jmp sel_to
.page_up:
    call page_items
    neg eax
    jmp sel_move
.page_down:
    call page_items
    jmp sel_move
.alt:
    cmp r12d, K_LEFT
    je go_back
    cmp r12d, K_RIGHT
    je go_forward
    cmp r12d, K_UP
    je go_up
    ret
.ctrl:
    mov eax, r12d
    cmp eax, 15                         ; ctrl+O
    je op_open
    cmp eax, K_DOWN
    je op_open
    cmp eax, K_UP
    je go_up
    cmp eax, '['
    je go_back
    cmp eax, 27
    je go_back
    cmp eax, ']'
    je go_forward
    cmp eax, 29
    je go_forward
    cmp eax, K_LEFT
    je go_back
    cmp eax, K_RIGHT
    je go_forward
    cmp eax, 14                         ; ctrl+shift+N: a folder
    jne .not_n
    test r13d, WM_SHIFT
    jnz op_newdir
    jmp op_newtxt
.not_n:
    cmp eax, 4                          ; ctrl+D
    je op_dup
    cmp eax, 3                          ; ctrl+C, X, V
    je op_copy
    cmp eax, 24
    je op_cut
    cmp eax, 22
    je op_paste
    cmp eax, 8                          ; ctrl+backspace
    je op_ask_delete
    cmp eax, 6                          ; ctrl+F
    je search_focus
    cmp eax, 18                         ; ctrl+R
    je reread
    cmp eax, 25                         ; ctrl+Y: a look, as on macOS
    je look_open
    cmp eax, 23                         ; ctrl+W
    je .close
    cmp eax, '1'
    je .icons
    cmp eax, '2'
    je .list
    ret
.close:
    mov dword [quitting], 1
    ret
.icons:
    mov eax, V_ICONS
    jmp view_set
.list:
    mov eax, V_LIST
    jmp view_set

; page_items -> EAX: how many things a page of the view moves by
page_items:
    call view_area
    mov eax, ecx
    cmp dword [view], V_ICONS
    je .icons
    xor edx, edx
    div dword [row_h]
    jmp .some
.icons:
    xor edx, edx
    div dword [cell_h]
    imul eax, [cols]
.some:
    cmp eax, 1
    jge .out
    mov eax, 1
.out:
    ret

; sel_move(EAX = by how many): the choice moved, nothing chosen yet: the
; first (or the last, going back)
sel_move:
    cmp dword [n], 0
    je .out
    mov ecx, [sel]
    test ecx, ecx
    jns .from
    xor ecx, ecx
    test eax, eax
    jns sel_to.at
    mov eax, [n]
    dec eax
    jmp sel_to
.from:
    add eax, ecx
    cmp eax, 0
    jge .low
    cmp dword [view], V_ICONS           ; above the first row: stays
    je .out
    xor eax, eax
.low:
    cmp eax, [n]
    jl sel_to
    cmp dword [view], V_ICONS           ; below the last: the last
    jne .last
    mov edx, ecx                        ; unless it was in the last row
    mov eax, ecx
    xor edx, edx
    div dword [cols]
    mov ecx, eax
    mov eax, [n]
    dec eax
    xor edx, edx
    div dword [cols]
    cmp eax, ecx
    je .out
.last:
    mov eax, [n]
    dec eax
    jmp sel_to
.out:
    ret

; sel_to(EAX = which): chosen, and in sight
sel_to:
    test eax, eax
    jns .at
    xor eax, eax
.at:
    cmp dword [n], 0
    je .out
    cmp eax, [n]
    jb .in
    mov eax, [n]
    dec eax
.in:
    mov [sel], eax
    call reveal
    or dword [need], N_MAIN | N_PATH
    cmp dword [over], O_LOOK            ; looking: at this one now
    jne .out
    call look_load
.out:
    ret

; type_select(R12D = a character): the first thing whose name starts with
; what was typed just now
type_select:
    push rbx
    call ax_now
    mov rbx, rax
    sub rax, [type_at]
    push rax
    mov edi, TYPE_US
    call ax_us
    pop rcx
    cmp rcx, rax
    jb .more
    mov dword [ts_len], 0
.more:
    mov [type_at], rbx
    mov eax, [ts_len]
    cmp eax, 63
    jae .find
    mov [ts_buf + rax], r12b
    inc dword [ts_len]
.find:
    xor ebx, ebx
.each:
    cmp ebx, [n]
    jae .out
    mov eax, ebx
    call entry
    add rsi, FE_NAME
    xor ecx, ecx
.cmp:
    cmp ecx, [ts_len]
    jae .found
    mov al, [rsi + rcx]
    mov dl, [ts_buf + rcx]
    LOWER al
    LOWER dl
    cmp al, dl
    jne .next
    inc ecx
    jmp .cmp
.next:
    inc ebx
    jmp .each
.found:
    mov eax, ebx
    call sel_to
.out:
    pop rbx
    ret

; view_set(EAX = V_*)
view_set:
    cmp eax, [view]
    je .out
    mov [view], eax
    call clamp_scroll
    call reveal
    or dword [need], N_TOOL | N_MAIN
.out:
    ret

; sort_by(EAX = SORT_*): by it; again, the other way. Dates and sizes start
; with the largest, as Finder's do.
sort_by:
    cmp eax, [sort_key]
    jne .new
    xor dword [sort_down], 1
    jmp .sort
.new:
    mov [sort_key], eax
    xor ecx, ecx
    cmp eax, SORT_DATE
    je .down
    cmp eax, SORT_SIZE
    jne .way
.down:
    mov ecx, 1
.way:
    mov [sort_down], ecx
.sort:
    call remember
    call arrange
    call reveal
    or dword [need], N_MAIN
    ret

; reread: the volumes and the folder, read again
reread:
    call vols_read
    call remember
    call list_dir
    call clamp_scroll
    mov dword [need], N_ALL
    ret

; -----------------------------------------------------------------------------
;  The search
; -----------------------------------------------------------------------------

; search_clear: nothing searched for
search_clear:
    lea rax, [search_buf]
    mov [f_search + KE_BUF], rax
    mov dword [f_search + KE_CAP], SEARCH_CAP
    mov dword [f_search + KE_LEN], 0
    mov dword [f_search + KE_CARET], 0
    mov dword [f_search + KE_ANCHOR], 0
    mov dword [f_search + KE_SCROLL], 0
    mov dword [search_was], 0
    ret

; search_focus: the keys to the search
search_focus:
    mov dword [kfocus], K_SEARCH
    mov dword [f_search + KE_ANCHOR], 0 ; what is in it chosen
    mov eax, [f_search + KE_LEN]
    mov [f_search + KE_CARET], eax
    call caret_reset
    or dword [need], N_TOOL
    ret

; search_empty: the search emptied, all shown again
search_empty:
    mov dword [f_search + KE_LEN], 0
    mov dword [f_search + KE_CARET], 0
    mov dword [f_search + KE_ANCHOR], 0
    mov dword [f_search + KE_SCROLL], 0
    jmp searched

; search_key(R12D, R13D): the search has the keys
search_key:
    mov eax, r12d
    cmp eax, 27
    je .esc
    cmp eax, 10
    je .to_list
    cmp eax, K_DOWN
    je .to_list
    cmp eax, 9
    je .to_list
    lea r8, [f_search]
    mov eax, r12d
    mov edx, r13d
    call kit_ekey
    jc .not_its
    or dword [need], N_TOOL
    jmp searched
.not_its:
    test r13d, WM_CTRL | WM_META        ; ctrl+W and the rest
    jnz list_key
    ret
.esc:
    cmp dword [f_search + KE_LEN], 0
    jne search_empty
    mov dword [kfocus], 0
    or dword [need], N_TOOL
    ret
.to_list:
    mov dword [kfocus], 0
    or dword [need], N_TOOL | N_MAIN
    cmp dword [sel], 0
    jge .out
    xor eax, eax
    jmp sel_to
.out:
    ret

; searched: if what is searched for changed, what is shown again
searched:
    mov ecx, [f_search + KE_LEN]
    cmp ecx, [search_was]
    jne .changed
    mov rsi, [f_search + KE_BUF]
    lea rdi, [search_old]
    repe cmpsb
    je .out
.changed:
    mov ecx, [f_search + KE_LEN]
    mov [search_was], ecx
    mov rsi, [f_search + KE_BUF]
    lea rdi, [search_old]
    rep movsb
    call remember
    call arrange
    mov dword [scroll], 0
    call clamp_scroll
    call reveal
    or dword [need], N_TOOL | N_MAIN | N_PATH
.out:
    ret

; -----------------------------------------------------------------------------
;  Over the window
; -----------------------------------------------------------------------------

; menu_key(R12D): a menu's items chosen with the arrows
menu_key:
    mov eax, r12d
    cmp eax, 27
    je menu_close
    cmp eax, 10
    je .enter
    cmp eax, ' '
    je .enter
    cmp eax, K_DOWN
    je .down
    cmp eax, K_UP
    je .up
    ret
.enter:
    mov eax, [menu_hl]
    test eax, eax
    js .out
    jmp menu_do
.down:
    mov eax, [menu_hl]
.next:
    inc eax
    cmp eax, [menu_n]
    jb .is
    xor eax, eax
.is:
    cmp dword [menu_ids + rax * 4], M_SEP
    je .next
    jmp .lit
.up:
    mov eax, [menu_hl]
    test eax, eax
    jns .prev
    mov eax, [menu_n]
.prev:
    dec eax
    jns .was
    mov eax, [menu_n]
    dec eax
.was:
    cmp dword [menu_ids + rax * 4], M_SEP
    je .prev
.lit:
    mov [menu_hl], eax
    or dword [need], N_ALL
.out:
    ret

; menu_open(EDI = x, ESI = y, EAX = 1 for what is chosen, 0 for the folder)
menu_open:
    mov [menu_x], edi
    mov [menu_y], esi
    mov dword [menu_n], 0
    mov dword [menu_hl], -1
    test eax, eax
    jz .folder
    mov eax, M_OPEN
    call menu_add
    mov eax, M_LOOK
    call menu_add
    mov eax, M_SEP
    call menu_add
    mov eax, M_RENAME
    call menu_add
    mov eax, M_DUP
    call menu_add
    mov eax, M_SEP
    call menu_add
    mov eax, M_COPY
    call menu_add
    mov eax, M_CUT
    call menu_add
    cmp byte [clip_path], 0
    je .delete
    mov eax, M_PASTE
    call menu_add
.delete:
    mov eax, M_SEP
    call menu_add
    mov eax, M_DELETE
    call menu_add
    jmp .open
.folder:
    mov eax, M_NEWDIR
    call menu_add
    mov eax, M_NEWTXT
    call menu_add
    cmp byte [clip_path], 0
    je .views
    mov eax, M_SEP
    call menu_add
    mov eax, M_PASTE
    call menu_add
.views:
    mov eax, M_SEP
    call menu_add
    mov eax, M_ICONS
    call menu_add
    mov eax, M_LIST
    call menu_add
    mov eax, M_SEP
    call menu_add
    mov eax, M_REREAD
    call menu_add
.open:
    mov dword [over], O_MENU
    mov dword [need], N_ALL
    ret

menu_add:
    mov ecx, [menu_n]
    cmp ecx, MENU_MAX
    jae .out
    mov [menu_ids + rcx * 4], eax
    inc dword [menu_n]
.out:
    ret

menu_close:
    mov dword [over], 0
    mov dword [need], N_ALL
    ret

; menu_do(EAX = which item): the menu gone, and that done
menu_do:
    mov eax, [menu_ids + rax * 4]
    push rax
    call menu_close
    pop rax
    cmp eax, M_OPEN
    je op_open
    cmp eax, M_LOOK
    je look_open
    cmp eax, M_RENAME
    je rename_start
    cmp eax, M_DUP
    je op_dup
    cmp eax, M_COPY
    je op_copy
    cmp eax, M_CUT
    je op_cut
    cmp eax, M_DELETE
    je op_ask_delete
    cmp eax, M_NEWDIR
    je op_newdir
    cmp eax, M_NEWTXT
    je op_newtxt
    cmp eax, M_PASTE
    je op_paste
    cmp eax, M_REREAD
    je reread
    cmp eax, M_ICONS
    jne .list
    mov eax, V_ICONS
    jmp view_set
.list:
    cmp eax, M_LIST
    jne .out
    mov eax, V_LIST
    jmp view_set
.out:
    ret

; alert_key(R12D): Enter deletes, Esc does not
alert_key:
    cmp r12d, 10
    je op_delete
    cmp r12d, 27
    je alert_close
    ret

alert_close:
    mov dword [over], 0
    mov dword [need], N_ALL
    ret

; look_key(R12D, R13D): space or Esc closes; the arrows go on to the next
; thing; the text scrolls with the page keys
look_key:
    mov eax, r12d
    cmp eax, ' '
    je look_close
    cmp eax, 27
    je look_close
    cmp eax, 10
    je .open
    cmp eax, 15
    je .open
    cmp eax, K_PGDN
    je .page_down
    cmp eax, K_PGUP
    je .page_up
    cmp eax, K_HOME
    je .home
    test r13d, WM_CTRL | WM_META
    jnz .ctrl
    jmp list_key                        ; the arrows choose, and it follows
.ctrl:
    cmp eax, 25                         ; ctrl+Y again
    je look_close
    cmp eax, 23
    je look_close
    ret
.open:
    call look_close
    jmp op_open
.page_down:
    mov eax, 20
    jmp look_scroll
.page_up:
    mov eax, -20
    jmp look_scroll
.home:
    mov dword [ql_top], 0
    mov dword [need], N_ALL
    ret

; look_scroll(EAX = lines down)
look_scroll:
    add eax, [ql_top]
    mov ecx, [ql_lines]
    dec ecx
    cmp eax, ecx
    jle .max
    mov eax, ecx
.max:
    test eax, eax
    jns .min
    xor eax, eax
.min:
    cmp eax, [ql_top]
    je .out
    mov [ql_top], eax
    mov dword [need], N_ALL
.out:
    ret

; -----------------------------------------------------------------------------
;  The mouse
; -----------------------------------------------------------------------------

on_press:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, [kit_ev + WE_X]           ; R12D, R13D: where
    mov r13d, [kit_ev + WE_Y]
    mov r14d, [kit_ev + WE_CODE]        ; R14D: which button
    cmp qword [said], 0
    je .said
    mov qword [said], 0
    or dword [need], N_PATH
.said:
    cmp dword [over], 0
    jne .over
    cmp dword [kfocus], K_RENAME        ; a name being typed: kept, unless the
    jne .regions                        ; press is in it
    call in_rename
    jc .commit
    lea r8, [f_rename]
    mov edi, r12d
    xor esi, esi
    mov r9d, [ren_font]
    call kit_eclick
    or dword [need], N_MAIN
    jmp .out
.commit:
    call rename_commit
.regions:
    cmp r12d, [side_w]
    jl .side
    cmp r13d, [tool_h]
    jl .tool
    mov eax, [kit_h]
    sub eax, [path_h]
    cmp r13d, eax
    jge .path
    cmp dword [kfocus], K_SEARCH        ; the keys back to the list
    jne .main
    mov dword [kfocus], 0
    or dword [need], N_TOOL
.main:
    call press_main
    jmp .out
.side:
    lea rsi, [side_hits]
    mov edi, r12d
    mov edx, r13d
    call hit_at
    test eax, eax
    jz .out
    sub eax, H_VOL
    call vol_go
    jmp .out
.tool:
    lea rsi, [tool_hits]
    mov edi, r12d
    mov edx, r13d
    call hit_at
    cmp eax, H_SEARCH
    je .search
    cmp eax, H_CLEAR
    je .clear
    cmp dword [kfocus], K_SEARCH
    jne .button
    mov dword [kfocus], 0
    or dword [need], N_TOOL
.button:
    cmp eax, H_BACK
    je .back
    cmp eax, H_FWD
    je .fwd
    cmp eax, H_VICONS
    je .icons
    cmp eax, H_VLIST
    je .list
    jmp .out
.back:
    call go_back
    jmp .out
.fwd:
    call go_forward
    jmp .out
.icons:
    mov eax, V_ICONS
    call view_set
    jmp .out
.list:
    mov eax, V_LIST
    call view_set
    jmp .out
.search:
    cmp dword [kfocus], K_SEARCH
    je .in_search
    call search_focus
.in_search:
    lea r8, [f_search]
    mov edi, r12d
    xor esi, esi
    mov r9d, [f_ui]
    call kit_eclick
    or dword [need], N_TOOL
    jmp .out
.clear:
    call search_empty
    call search_focus
    jmp .out
.path:
    lea rsi, [path_hits]
    mov edi, r12d
    mov edx, r13d
    call hit_at
    test eax, eax
    jz .out
    sub eax, H_CRUMB
    call crumb_go
    jmp .out
.over:
    lea rsi, [over_hits]
    mov edi, r12d
    mov edx, r13d
    call hit_at
    mov ecx, [over]
    cmp ecx, O_MENU
    je .menu
    cmp ecx, O_ALERT
    je .alert
    cmp eax, H_L_CLOSE                  ; a look
    je .look_close
    cmp eax, H_L_OPEN
    je .look_open
    call in_card                        ; outside it: closed
    jnc .out
.look_close:
    call look_close
    jmp .out
.look_open:
    call look_close
    call op_open
    jmp .out
.menu:
    cmp eax, H_MENU
    jb .menu_off
    sub eax, H_MENU
    call menu_do
    jmp .out
.menu_off:
    call menu_close
    jmp .out
.alert:
    cmp eax, H_A_OK
    je .delete
    cmp eax, H_A_CANCEL
    jne .out
    call alert_close
    jmp .out
.delete:
    call op_delete
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; press_main(R12D, R13D = where, R14D = which button): in what the folder
; holds
press_main:
    cmp dword [view], V_LIST            ; the list's headings sort it
    jne .item
    mov eax, [main_y]
    add eax, [head_h]
    cmp r13d, eax
    jge .item
    mov eax, SORT_NAME
    cmp r12d, [date_x]
    jl .sort
    cmp dword [show_date], 0
    je .size
    mov eax, SORT_DATE
    cmp r12d, [size_x]
    jl .sort
.size:
    mov eax, SORT_SIZE
    cmp r12d, [kind_x]
    jl .sort
    cmp dword [show_kind], 0
    je .sort
    mov eax, SORT_KIND
.sort:
    jmp sort_by
.item:
    mov edi, r12d
    mov esi, r13d
    call item_at
    test eax, eax
    js .nothing
    cmp eax, [sel]
    je .same
    mov [sel], eax
    call reveal
    or dword [need], N_MAIN | N_PATH
.same:
    cmp r14d, 2
    je .menu_on
    cmp r14d, 1
    jne .out
    cmp dword [kit_clicks], 2
    jne .out
    jmp op_open
.menu_on:
    mov edi, r12d
    mov esi, r13d
    mov eax, 1
    jmp menu_open
.nothing:
    cmp dword [sel], 0
    jl .none
    mov dword [sel], -1
    or dword [need], N_MAIN | N_PATH
.none:
    cmp r14d, 2
    jne .out
    mov edi, r12d
    mov esi, r13d
    xor eax, eax
    jmp menu_open
.out:
    ret

; in_rename(R12D, R13D) -> CF if not in the field a name is typed in
in_rename:
    mov eax, r12d
    sub eax, [ren_x]
    js .no
    cmp eax, [ren_w]
    jge .no
    mov eax, r13d
    sub eax, [ren_y]
    js .no
    cmp eax, [ren_h]
    jge .no
    clc
    ret
.no:
    stc
    ret

; in_card(R12D, R13D) -> CF if in the card shown
in_card:
    mov eax, r12d
    sub eax, [card_x]
    js .no
    cmp eax, [card_w]
    jge .no
    mov eax, r13d
    sub eax, [card_y]
    js .no
    cmp eax, [card_h]
    jge .no
    stc
    ret
.no:
    clc
    ret

; vol_go(EAX = which of the sidebar's): the top of it
vol_go:
    lea rdi, [path_buf]
    cmp dword [confined], 0
    je .vol
    mov byte [rdi], 0
    jmp .go
.vol:
    cmp eax, [nvols]
    jae .out
    imul eax, eax, FV_SIZE
    mov eax, [vols + rax + FV_INDEX]
    mov dword [rdi], 'vol'
    add rdi, 3
    call put_dec
    mov word [rdi], ':'
.go:
    lea rsi, [path_buf]
    jmp nav_to
.out:
    ret

; crumb_go(EAX = which part of the path): the folder it names
crumb_go:
    cmp eax, CRUMBS_MAX
    jae .out
    mov ecx, [crumb_end + rax * 4]
    lea rsi, [dir]
    lea rdi, [path_buf]
    rep movsb
    mov byte [rdi], 0
    lea rsi, [path_buf]
    jmp nav_to
.out:
    ret

; on_wheel: the view scrolled, or the text looked at
on_wheel:
    mov eax, [kit_ev + WE_CODE]
    cmp dword [over], O_LOOK
    je .look
    cmp dword [over], 0
    jne .out
    mov ecx, [row_h]
    cmp dword [view], V_LIST
    je .step
    mov edi, 40
    push rax
    call kit_pt
    mov ecx, eax
    pop rax
.step:
    imul ecx, ecx, 3
    imul eax, ecx
    neg eax
    add eax, [scroll]
    mov ecx, [scroll]
    mov [scroll], eax
    push rcx
    call clamp_scroll
    pop rcx
    cmp ecx, [scroll]
    je .out
    or dword [need], N_MAIN
.out:
    ret
.look:
    imul eax, eax, -3
    jmp look_scroll

section .bss
alignb 8
kfocus:         resd 1                  ; K_*, 0: the folder's things
ts_len:         resd 1                  ; typed to choose
search_was:     resd 1
menu_n:         resd 1
menu_hl:        resd 1                  ; the item lit, -1 none
menu_x:         resd 1
menu_y:         resd 1
menu_ids:       resd MENU_MAX
ts_buf:         resb 64
f_search:       resb KE_SIZE
f_rename:       resb KE_SIZE
search_buf:     resb SEARCH_CAP + 8
search_old:     resb SEARCH_CAP + 8

section .rodata
align 8
m_labels:       dq 0, s_m_open, s_m_look, s_m_rename, s_m_dup, s_m_copy, s_m_cut
                dq s_m_delete, s_m_newdir, s_m_newtxt, s_m_paste, s_m_icons
                dq s_m_list, s_m_reread
m_keys:         dq 0, s_mk_open, s_mk_look, s_mk_rename, s_mk_dup, s_mk_copy
                dq s_mk_cut, s_mk_delete, s_mk_newdir, s_mk_newtxt, s_mk_paste
                dq s_mk_icons, s_mk_list, s_mk_reread
s_m_open:       db 'Open', 0
s_m_look:       db 'Quick Look', 0
s_m_rename:     db 'Rename', 0
s_m_dup:        db 'Duplicate', 0
s_m_copy:       db 'Copy', 0
s_m_cut:        db 'Cut', 0
s_m_delete:     db 'Delete', 0
s_m_newdir:     db 'New Folder', 0
s_m_newtxt:     db 'New Text File', 0
s_m_paste:      db 'Paste', 0
s_m_icons:      db 'as Icons', 0
s_m_list:       db 'as List', 0
s_m_reread:     db 'Read Again', 0
s_mk_open:      db 'Ctrl+O', 0
s_mk_look:      db 'Space', 0
s_mk_rename:    db 'Enter', 0
s_mk_dup:       db 'Ctrl+D', 0
s_mk_copy:      db 'Ctrl+C', 0
s_mk_cut:       db 'Ctrl+X', 0
s_mk_delete:    db 'Delete', 0
s_mk_newdir:    db 'Ctrl+Shift+N', 0
s_mk_newtxt:    db 'Ctrl+N', 0
s_mk_paste:     db 'Ctrl+V', 0
s_mk_icons:     db 'Ctrl+1', 0
s_mk_list:      db 'Ctrl+2', 0
s_mk_reread:    db 'Ctrl+R', 0
