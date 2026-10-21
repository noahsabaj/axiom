; =============================================================================
;  files/view.inc - the window: its measures and colours, and drawing it
;
;  The sidebar (the volumes) runs down the left; right of it the toolbar
;  (back, forward, the folder's name, icons or a list, the search), what
;  the folder holds, and the path bar. Over them, at times, a menu, an
;  alert or a look at a file. Each part is drawn again only when it
;  changed, and only it is shown.
; =============================================================================

V_ICONS         equ 0                   ; how the folder is shown
V_LIST          equ 1

O_MENU          equ 1                   ; what is over the window
O_ALERT         equ 2
O_LOOK          equ 3

H_VOL           equ 1                   ; what a press finds (the volumes: H_VOL + i)
H_BACK          equ 32
H_FWD           equ 33
H_VICONS        equ 34
H_VLIST         equ 35
H_SEARCH        equ 36
H_CLEAR         equ 37
H_CRUMB         equ 40                  ; + i: the path bar's parts
H_MENU          equ 64                  ; + i: a menu's items
H_A_CANCEL      equ 96
H_A_OK          equ 97
H_L_CLOSE       equ 98
H_L_OPEN        equ 99

HIT_SIZE        equ 20
HITS_MAX        equ 40
CRUMBS_MAX      equ 24

section .text

; measure: the fonts, the parts' places and sizes, the colours
measure:
    mov edi, 13
    mov esi, KF_REGULAR
    call kit_font
    mov [f_ui], eax
    mov edi, 13
    mov esi, KF_BOLD
    call kit_font
    mov [f_bold], eax
    mov edi, 11
    mov esi, KF_REGULAR
    call kit_font
    mov [f_small], eax
    mov edi, 11
    mov esi, KF_BOLD
    call kit_font
    mov [f_head], eax
    mov edi, 15
    mov esi, KF_BOLD
    call kit_font
    mov [f_title], eax
    mov edi, 12
    mov esi, KF_REGULAR
    call kit_font
    mov [f_label], eax
    mov edi, 8
    mov esi, KF_BOLD
    call kit_font
    mov [f_badge], eax
    PX tool_h, 52
    PX path_h, 28
    PX side_w, 196
    mov eax, [kit_w]                    ; a third of the window at most
    xor edx, edx
    mov ecx, 3
    div ecx
    cmp [side_w], eax
    jbe .side
    mov [side_w], eax
.side:
    mov eax, [side_w]
    mov [main_x], eax
    mov eax, [tool_h]
    mov [main_y], eax
    mov eax, [kit_w]
    sub eax, [side_w]
    mov [main_w], eax
    mov eax, [kit_h]
    sub eax, [tool_h]
    sub eax, [path_h]
    jns .high
    xor eax, eax
.high:
    mov [main_h], eax
    PX gpad, 12
    PX row_h, 24
    PX head_h, 28
    PX cell_w, 104
    PX big, 64
    PX small, 18
    PX side_row_h, 28
    PX badge_min, 40
    mov edx, [f_label]
    call kit_line
    mov [lab_h], eax
    mov edi, 20                         ; the cell: the icon, two lines under it
    call kit_pt
    add eax, [big]
    add eax, [lab_h]
    add eax, [lab_h]
    mov [cell_h], eax
    mov eax, [main_w]                   ; as many across as fit
    sub eax, [gpad]
    sub eax, [gpad]
    xor edx, edx
    div dword [cell_w]
    cmp eax, 1
    jge .cols
    mov eax, 1
.cols:
    mov [cols], eax
    mov edi, 14                         ; the list's columns, from the right
    call kit_pt
    mov ecx, [main_x]
    add ecx, [main_w]
    sub ecx, eax
    mov [list_r], ecx
    mov edi, 12
    call kit_pt
    add eax, [main_x]
    mov [name_x], eax
    PX kind_w, 130
    PX size_w, 84
    PX date_w, 178
    mov dword [show_kind], 1
    mov dword [show_date], 1
    call columns
    mov edi, 230
    call kit_pt
    mov ecx, [date_x]
    sub ecx, [name_x]
    cmp ecx, eax
    jge .wide
    mov dword [show_kind], 0
    call columns
    mov edi, 230
    call kit_pt
    mov ecx, [date_x]
    sub ecx, [name_x]
    cmp ecx, eax
    jge .wide
    mov dword [show_date], 0
    call columns
.wide:
    call colours
    jmp clamp_scroll

; columns: where the list's columns start, by what is shown
columns:
    mov eax, [list_r]
    cmp dword [show_kind], 0
    je .kind
    sub eax, [kind_w]
.kind:
    mov [kind_x], eax
    sub eax, [size_w]
    mov [size_x], eax
    cmp dword [show_date], 0
    je .date
    sub eax, [date_w]
.date:
    mov [date_x], eax
    ret

; colours: the theme's, and those made from it
colours:
    mov edi, TC_WINDOW
    call kit_c
    mov [c_bg], eax
    mov edi, TC_TITLE
    call kit_c
    mov [c_side], eax
    mov edi, TC_SEP
    call kit_c
    mov [c_sep], eax
    mov edi, TC_LINE
    call kit_c
    mov [c_line], eax
    mov edi, TC_TEXT
    call kit_c
    mov [c_text], eax
    mov edi, TC_TEXT2
    call kit_c
    mov [c_text2], eax
    mov edi, TC_TEXT3
    call kit_c
    mov [c_text3], eax
    mov edi, TC_PANEL
    call kit_c
    mov [c_panel], eax
    mov edi, TC_TIP
    call kit_c
    mov [c_tip], eax
    mov edi, TC_TIP_TEXT
    call kit_c
    mov [c_tip_text], eax
    call kit_accent
    and eax, 0xFFFFFF
    mov [c_accent], eax
    call kit_dark
    jne .light
    mov dword [c_stripe], KA(0x0C) | 0xFFFFFF
    mov dword [c_hilite], KA(0x26) | 0xFFFFFF
    mov dword [c_side_sel], KA(0x24) | 0xFFFFFF
    mov dword [c_sel_off], KA(0x34) | 0xFFFFFF
    mov dword [c_edge], KA(0x30) | 0xFFFFFF
    mov dword [c_seg], KA(0x14) | 0xFFFFFF
    mov dword [c_seg_on], KA(0x40) | 0xFFFFFF
    ret
.light:
    mov dword [c_stripe], KA(0x0A) | 0x000000
    mov dword [c_hilite], KA(0x1C) | 0x000000
    mov dword [c_side_sel], KA(0x16) | 0x000000
    mov dword [c_sel_off], KA(0x20) | 0x000000
    mov dword [c_edge], KA(0x28) | 0x000000
    mov dword [c_seg], KA(0x0E) | 0x000000
    mov dword [c_seg_on], 0xFFFFFF
    ret

; view_area -> EAX = the top of where things scroll, ECX = its height
view_area:
    mov eax, [main_y]
    mov ecx, [main_h]
    cmp dword [view], V_LIST
    jne .out
    add eax, [head_h]
    sub ecx, [head_h]
    jns .out
    xor ecx, ecx
.out:
    ret

; content_h -> EAX = the height of all the folder's things, shown
content_h:
    cmp dword [view], V_LIST
    je .list
    mov eax, [n]
    add eax, [cols]
    dec eax
    xor edx, edx
    div dword [cols]
    imul eax, [cell_h]
    add eax, [gpad]
    add eax, [gpad]
    ret
.list:
    mov eax, [n]
    imul eax, [row_h]
    ret

; clamp_scroll: no further than there is
clamp_scroll:
    call content_h
    push rax
    call view_area
    pop rax
    sub eax, ecx
    jns .max
    xor eax, eax
.max:
    cmp [scroll], eax
    jle .low
    mov [scroll], eax
.low:
    cmp dword [scroll], 0
    jge .out
    mov dword [scroll], 0
.out:
    ret

; item_box(EAX = which) -> EAX = its top, ECX = its height, in the
; content (before scrolling)
item_box:
    cmp dword [view], V_LIST
    je .list
    xor edx, edx
    div dword [cols]
    imul eax, [cell_h]
    add eax, [gpad]
    mov ecx, [cell_h]
    ret
.list:
    imul eax, [row_h]
    mov ecx, [row_h]
    ret

; reveal: the one chosen in sight
reveal:
    mov eax, [sel]
    test eax, eax
    js .out
    call item_box
    push rax
    push rcx
    call view_area
    mov edx, ecx                        ; EDX: the height shown
    pop rcx
    pop rax
    cmp eax, [scroll]
    jge .below
    mov [scroll], eax
    jmp .out
.below:
    add eax, ecx
    sub eax, edx
    cmp eax, [scroll]
    jle .out
    mov [scroll], eax
.out:
    jmp clamp_scroll

; item_at(EDI = x, ESI = y) -> EAX = what is there, -1 if nothing
item_at:
    push rbx
    mov ebx, edi
    call view_area
    sub esi, eax
    js .none
    cmp esi, ecx
    jge .none
    add esi, [scroll]
    cmp dword [view], V_LIST
    je .list
    sub esi, [gpad]
    js .none
    mov eax, ebx
    sub eax, [main_x]
    sub eax, [gpad]
    js .none
    xor edx, edx
    div dword [cell_w]
    cmp eax, [cols]
    jae .none
    mov ecx, eax                        ; ECX: its column
    push rdx
    mov edi, 8                          ; in from its sides
    call kit_pt
    pop rdx
    cmp edx, eax
    jl .none
    mov r8d, [cell_w]
    sub r8d, eax
    cmp edx, r8d
    jge .none
    mov eax, esi
    xor edx, edx
    div dword [cell_h]
    imul eax, [cols]
    add eax, ecx
    jmp .have
.list:
    mov eax, esi
    xor edx, edx
    div dword [row_h]
.have:
    cmp eax, [n]
    jae .none
    pop rbx
    ret
.none:
    mov eax, -1
    pop rbx
    ret

; title_set: the window called what the folder is
title_set:
    cmp dword [kit_win], 0
    je .out
    call dir_name
    call kit_title
.out:
    ret

; -----------------------------------------------------------------------------
;  Drawing
; -----------------------------------------------------------------------------

paint:
    push r12
    mov r12d, [need]
    test r12d, r12d
    jz .out
    mov dword [need], 0
    cmp dword [over], 0
    je .parts
    mov r12d, N_ALL
.parts:
    test r12d, N_SIDE
    jz .tool
    call paint_side
.tool:
    test r12d, N_TOOL
    jz .main
    call paint_tool
.main:
    test r12d, N_MAIN
    jz .path
    call paint_main
.path:
    test r12d, N_PATH
    jz .over
    call paint_path
.over:
    cmp dword [over], 0
    je .show
    call paint_over
.show:
    cmp r12d, N_ALL
    jne .some
    call kit_show_all
    jmp .out
.some:
    test r12d, N_SIDE
    jz .show_tool
    xor edi, edi
    xor esi, esi
    mov edx, [side_w]
    mov ecx, [kit_h]
    call kit_show
.show_tool:
    test r12d, N_TOOL
    jz .show_main
    mov edi, [side_w]
    xor esi, esi
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, [tool_h]
    call kit_show
.show_main:
    test r12d, N_MAIN
    jz .show_path
    mov edi, [main_x]
    mov esi, [main_y]
    mov edx, [main_w]
    mov ecx, [main_h]
    call kit_show
.show_path:
    test r12d, N_PATH
    jz .out
    mov edi, [side_w]
    mov esi, [kit_h]
    sub esi, [path_h]
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, [path_h]
    call kit_show
.out:
    pop r12
    ret

; text_at(RSI = text, ECX = bytes, EDI = x, EDX = a line's top, EAX = its
; height, R8D = font, R9D = colour): drawn on its baseline. -> EAX = the x
; after it
text_at:
    push rdi
    push rsi
    push rcx
    push r8
    push r9
    mov esi, edx
    mov edx, r8d
    mov ecx, eax
    call kit_base
    mov edx, eax
    pop r9
    pop r8
    pop rcx
    pop rsi
    pop rdi
    jmp kit_text

; fit_text(RSI = text, ECX = bytes, EDX = width, R8D = font) -> ECX = the
; bytes that fit, "…" after them in place of the rest; EAX = their width.
; The text's room must hold 3 bytes more.
fit_text:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rsi
    mov r12d, ecx
    mov r13d, edx
    mov r14d, r8d
    mov edx, r14d
    call kit_text_w
    cmp eax, r13d
    jbe .fits
    lea rsi, [s_more]
    mov ecx, 3
    mov edx, r14d
    call kit_text_w
    sub r13d, eax                       ; room for the rest, before the …
.shorter:
    test r12d, r12d
    jz .cut
    dec r12d                            ; a character less
    mov al, [rbx + r12]
    and al, 0xC0
    cmp al, 0x80
    je .shorter
    mov rsi, rbx
    mov ecx, r12d
    mov edx, r14d
    call kit_text_w
    cmp eax, r13d
    ja .shorter
.cut:
    mov eax, [s_more]
    mov [rbx + r12], ax
    shr eax, 16
    mov [rbx + r12 + 2], al
    add r12d, 3
    mov rsi, rbx
    mov ecx, r12d
    mov edx, r14d
    call kit_text_w
.fits:
    mov ecx, r12d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fit_into(RSI = NUL-ended, EDX = width, R8D = font) -> RSI = fit_buf
; holding it, fitted, ECX = its bytes, EAX = its width
fit_into:
    push rdx
    push r8
    call k_slen
    cmp ecx, 240
    jbe .short
    mov ecx, 240
.short:
    lea rdi, [fit_buf]
    push rcx
    rep movsb
    pop rcx
    pop r8
    pop rdx
    lea rsi, [fit_buf]
    call fit_text
    lea rsi, [fit_buf]
    ret

; hit_add(EDI = x, ESI = y, EDX = w, ECX = h, R8D = what): where a press
; finds it, in hit_tab. Preserves all but RAX.
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

; hits_new(RDI = a table): emptied, and where hit_add puts them
hits_new:
    mov [hit_tab], rdi
    mov dword [rdi], 0
    ret

; hit_at(RSI = a table, EDI = x, EDX = y) -> EAX = what is there, 0 if
; nothing
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
    ret
.next:
    add rsi, HIT_SIZE
    dec ecx
    jmp .each
.none:
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
;  The sidebar
; -----------------------------------------------------------------------------

paint_side:
    push rbx
    push r12
    push r13
    push r14
    lea rdi, [side_hits]
    call hits_new
    xor edi, edi
    xor esi, esi
    mov edx, [side_w]
    mov ecx, [kit_h]
    mov r8d, [c_side]
    call kit_fill
    mov edi, [side_w]
    dec edi
    xor esi, esi
    mov edx, 1
    mov ecx, [kit_h]
    mov r8d, [c_sep]
    call kit_fill
    mov edi, 10
    call kit_pt
    mov r12d, eax                       ; R12D: the rows' left
    mov r14d, [side_w]
    sub r14d, eax
    sub r14d, eax                       ; R14D: their width
    mov edi, 12
    call kit_pt
    mov r13d, eax                       ; R13D: where we are
    lea rsi, [s_locations]              ; the heading
    call k_slen
    mov edi, 8
    push rcx
    call kit_pt
    pop rcx
    lea edi, [r12 + rax]
    mov edx, r13d
    push rdi
    mov edi, 20
    call kit_pt
    pop rdi
    lea rsi, [s_locations]
    mov r8d, [f_head]
    mov r9d, [c_text3]
    call text_at
    mov edi, 22
    call kit_pt
    add r13d, eax
    cmp dword [confined], 0
    je .volumes
    mov edi, r12d                       ; one folder given: it alone
    mov esi, r13d
    mov edx, r14d
    mov ecx, [side_row_h]
    mov r8d, H_VOL
    call hit_add
    lea rsi, [s_this_folder]
    mov eax, 1
    mov ecx, SR_FOLDER
    call side_row
    jmp .out
.volumes:
    xor ebx, ebx
.each:
    cmp ebx, [nvols]
    jae .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [side_row_h]
    lea r8d, [rbx + H_VOL]
    call hit_add
    imul eax, ebx, FV_SIZE
    lea rsi, [vols + rax]
    xor ecx, ecx                        ; ECX: SR_*
    test dword [rsi + FV_FLAGS], FVF_REMOVABLE
    jz .fixed
    or ecx, SR_REMOVABLE
.fixed:
    test dword [rsi + FV_FLAGS], FVF_WRITABLE
    jnz .rw
    or ecx, SR_LOCKED
.rw:
    mov eax, [rsi + FV_INDEX]
    push rcx
    push rax
    call dir_vol
    pop rdx
    cmp eax, edx
    sete al
    movzx eax, al
    push rax
    mov eax, edx
    call vol_label
    pop rax
    pop rcx
    call side_row
    add r13d, [side_row_h]
    inc ebx
    jmp .each
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

SR_REMOVABLE    equ 1
SR_LOCKED       equ 2
SR_FOLDER       equ 4

; side_row(RSI = its name, EAX = 1 if it is where we are, ECX = SR_*;
; R12D, R13D = where, R14D = how wide)
side_row:
    push rbx
    push rbp
    push r15
    mov rbx, rsi
    mov ebp, ecx
    test eax, eax
    jz .icon
    mov edi, 6
    call kit_pt
    mov r8d, eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, [side_row_h]
    mov r9d, [c_side_sel]
    call kit_round
.icon:
    mov edi, 16                         ; its icon, in the accent
    call kit_pt
    mov r15d, eax
    mov esi, [side_row_h]
    sub esi, eax
    sar esi, 1
    add esi, r13d
    mov edi, 8
    push rsi
    call kit_pt
    pop rsi
    lea edi, [r12 + rax]
    test ebp, SR_FOLDER
    jz .drive
    mov [icon_x], edi
    mov [icon_y], esi
    mov [icon_s], r15d
    call folder_icon
    jmp .name
.drive:
    mov edx, r15d
    mov ecx, ebp
    and ecx, SR_REMOVABLE
    mov r9d, [c_accent]
    call drive_icon
.name:
    mov edi, 32                         ; its name, fitted
    call kit_pt
    mov edx, r14d
    sub edx, eax
    push rax
    mov edi, 22
    call kit_pt
    sub edx, eax
    mov rsi, rbx
    mov r8d, [f_ui]
    call fit_into
    pop rax
    lea edi, [r12 + rax]
    mov edx, r13d
    mov eax, [side_row_h]
    mov r8d, [f_ui]
    mov r9d, [c_text]
    call text_at
    test ebp, SR_LOCKED                 ; read-only: a lock at its right
    jz .out
    mov edi, 12
    call kit_pt
    mov edx, eax
    mov esi, [side_row_h]
    sub esi, eax
    sar esi, 1
    add esi, r13d
    lea edi, [r12 + r14]
    sub edi, eax
    push rdx
    push rsi
    push rdi
    mov edi, 6
    call kit_pt
    pop rdi
    pop rsi
    pop rdx
    sub edi, eax
    mov r9d, [c_text3]
    call lock_icon
.out:
    pop r15
    pop rbp
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The toolbar
; -----------------------------------------------------------------------------

paint_tool:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [tool_hits]
    call hits_new
    mov edi, [side_w]
    xor esi, esi
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, [tool_h]
    mov r8d, [c_side]
    call kit_fill
    mov edi, [side_w]
    mov esi, [tool_h]
    dec esi
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, 1
    mov r8d, [c_sep]
    call kit_fill
    mov edi, 28
    call kit_pt
    mov r14d, eax                       ; R14D: a button's size
    mov r13d, [tool_h]
    sub r13d, eax
    sar r13d, 1                         ; R13D: the buttons' top
    mov edi, 10
    call kit_pt
    mov r12d, [side_w]
    add r12d, eax                       ; R12D: where we are, going right
    mov edi, r12d                       ; back
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, H_BACK
    call hit_add
    mov eax, [back_n]
    xor edx, edx
    call nav_button
    add r12d, r14d
    mov edi, 2
    call kit_pt
    add r12d, eax
    mov edi, r12d                       ; forward
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, H_FWD
    call hit_add
    mov eax, [fwd_n]
    mov edx, 1
    call nav_button
    add r12d, r14d
    mov edi, 14
    call kit_pt
    add r12d, eax                       ; the title's left
    mov edi, 196                        ; the search, at the right
    call kit_pt
    mov r15d, eax                       ; R15D: its width
    mov edi, 12
    call kit_pt
    mov ebx, [kit_w]
    sub ebx, eax
    sub ebx, r15d                       ; EBX: its left
    mov edi, 34                         ; the view's buttons left of it
    call kit_pt
    mov [seg_w], eax
    mov edi, 12
    call kit_pt
    mov ecx, ebx
    sub ecx, eax
    sub ecx, [seg_w]
    sub ecx, [seg_w]
    mov [seg_x], ecx
    push rcx
    mov edi, 12                         ; the folder's name, between
    call kit_pt
    pop rcx
    sub ecx, eax
    sub ecx, r12d
    jle .segments
    push rcx
    call dir_name
    pop rdx
    mov r8d, [f_title]
    call fit_into
    mov edi, r12d
    xor edx, edx
    mov eax, [tool_h]
    mov r8d, [f_title]
    mov r9d, [c_text]
    call text_at
.segments:
    mov edi, 6
    call kit_pt
    mov r8d, eax
    mov edi, [seg_x]
    mov esi, r13d
    mov edx, [seg_w]
    add edx, edx
    mov ecx, r14d
    mov r9d, [c_seg]
    call kit_round
    mov edi, 2                          ; the one chosen, raised
    call kit_pt
    mov edi, [seg_x]
    add edi, eax
    mov ecx, [view]
    imul ecx, [seg_w]
    add edi, ecx
    lea esi, [r13 + rax]
    mov edx, [seg_w]
    sub edx, eax
    sub edx, eax
    mov ecx, r14d
    sub ecx, eax
    sub ecx, eax
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 5
    call kit_pt
    mov r8d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov r9d, [c_seg_on]
    call kit_round
    mov edi, [seg_x]
    mov esi, r13d
    mov edx, [seg_w]
    mov ecx, r14d
    mov r8d, H_VICONS
    call hit_add
    add edi, edx
    mov r8d, H_VLIST
    call hit_add
    mov edi, 13
    call kit_pt
    mov edx, eax
    mov edi, [seg_w]
    shr edi, 1
    add edi, [seg_x]
    mov esi, r14d
    shr esi, 1
    add esi, r13d
    mov r9d, [c_text2]
    cmp dword [view], V_ICONS
    jne .grid
    mov r9d, [c_text]
.grid:
    push rsi
    push rdx
    call grid_glyph
    pop rdx
    pop rsi
    mov edi, [seg_w]
    shr edi, 1
    add edi, [seg_x]
    add edi, [seg_w]
    mov r9d, [c_text2]
    cmp dword [view], V_LIST
    jne .list
    mov r9d, [c_text]
.list:
    call list_glyph
    mov edi, 24                         ; the search field: room for its lens
    call kit_pt
    mov [f_search + KE_INDENT], eax
    cmp dword [f_search + KE_LEN], 0    ; the clear button first, to find it first
    je .field
    mov edi, 22
    call kit_pt
    lea edi, [rbx + r15]
    sub edi, eax
    mov esi, r13d
    mov edx, eax
    mov ecx, r14d
    mov r8d, H_CLEAR
    call hit_add
.field:
    mov edi, ebx
    mov esi, r13d
    mov edx, r15d
    mov ecx, r14d
    mov r8d, H_SEARCH
    call hit_add
    xor r10d, r10d
    cmp dword [kfocus], K_SEARCH
    jne .keys
    mov r10d, 1
.keys:
    lea r8, [f_search]
    mov edi, ebx
    mov esi, r13d
    mov edx, r15d
    mov ecx, r14d
    mov r9d, [f_ui]
    call kit_edraw
    mov edi, 15                         ; its lens
    call kit_pt
    lea edi, [rbx + rax]
    mov esi, r14d
    shr esi, 1
    add esi, r13d
    push rdi
    push rsi
    mov edi, 12
    call kit_pt
    mov edx, eax
    pop rsi
    pop rdi
    mov r9d, [c_text3]
    call kit_dark
    jne .lens
    mov r9d, [c_text2]
.lens:
    call lens
    cmp dword [f_search + KE_LEN], 0
    jne .clear
    cmp dword [kfocus], K_SEARCH
    je .out
    lea rsi, [s_search]                 ; empty, without the keys: what it is for
    call k_slen
    mov edi, [f_search + KE_X]
    mov edx, r13d
    mov eax, r14d
    mov r8d, [f_ui]
    mov r9d, [c_text3]
    call text_at
    jmp .out
.clear:
    mov edi, 7                          ; a round button, a cross on it
    call kit_pt
    mov edx, eax
    add edx, edx
    lea edi, [rbx + r15]
    sub edi, edx
    push rdi
    mov edi, 6
    call kit_pt
    pop rdi
    sub edi, eax
    mov esi, r14d
    sub esi, edx
    sar esi, 1
    add esi, r13d
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    mov r9d, [c_text3]
    push rdi
    push rsi
    push rdx
    call kit_round
    pop rdx
    pop rsi
    pop rdi
    shr edx, 1
    add edi, edx
    add esi, edx
    mov edx, [c_bg]
    call x_mark
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; nav_button(EAX = how many there are to go to, EDX = 0 back, 1 forward;
; R12D, R13D = where, R14D = its size)
nav_button:
    mov r9d, [c_text2]
    test eax, eax
    jnz .on
    mov r9d, [c_text3]
    and r9d, 0xFFFFFF
    or r9d, KA(0x70)
.on:
    push r9
    push rdx
    mov edi, 6
    call kit_pt
    mov ecx, eax
    pop rdx
    pop r9
    mov edi, r14d
    shr edi, 1
    add edi, r12d
    mov esi, r14d
    shr esi, 1
    add esi, r13d
    jmp chevron

; x_mark(EDI = x, ESI = y, its middle, EDX = colour): a small ×
x_mark:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, 3
    call kit_pt
    mov ebx, eax                        ; EBX: half its size, in 16ths
    shl ebx, 4
    mov edi, 5
    call kit_pt
    lea r8d, [rax * 4]                  ; 1.25 points thick
    shl r12d, 4
    shl r13d, 4
    add r12d, 8
    add r13d, 8
    push r8
    mov edi, r12d
    sub edi, ebx
    mov esi, r13d
    sub esi, ebx
    lea edx, [r12 + rbx]
    lea ecx, [r13 + rbx]
    mov r9d, r14d
    call kit_stroke
    pop r8
    mov edi, r12d
    add edi, ebx
    mov esi, r13d
    sub esi, ebx
    mov edx, r12d
    sub edx, ebx
    lea ecx, [r13 + rbx]
    mov r9d, r14d
    call kit_stroke
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  What the folder holds
; -----------------------------------------------------------------------------

paint_main:
    mov edi, [main_x]
    mov esi, [main_y]
    mov edx, [main_w]
    mov ecx, [main_h]
    call kit_clip
    mov edi, [main_x]
    mov esi, [main_y]
    mov edx, [main_w]
    mov ecx, [main_h]
    mov r8d, [c_bg]
    call kit_fill
    cmp dword [view], V_LIST
    je .list
    call paint_icons
    jmp .out
.list:
    call paint_list
.out:
    jmp kit_unclip

; empty_say: nothing to show; why, in the middle of where things would be
empty_say:
    lea rsi, [s_empty]
    cmp dword [bad], 0
    je .search
    lea rsi, [s_cant_read]
    jmp .say
.search:
    cmp dword [f_search + KE_LEN], 0
    je .say
    lea rsi, [s_no_results]
.say:
    push rsi
    call k_slen
    mov edx, [f_ui]
    call kit_text_w
    pop rsi
    mov edi, [main_w]
    sub edi, eax
    sar edi, 1
    add edi, [main_x]
    push rdi
    push rsi
    call view_area
    mov edx, eax
    mov eax, ecx
    pop rsi
    pop rdi
    call k_slen
    mov r8d, [f_ui]
    mov r9d, [c_text3]
    jmp text_at

; scroller: where the view is, at its right
scroller:
    call view_area
    push rax
    push rcx
    call content_h
    mov ebx, eax
    mov edi, 9
    call kit_pt
    mov edi, [main_x]
    add edi, [main_w]
    sub edi, eax
    pop rdx
    pop rsi
    push rdx
    mov edi, 4
    push rdi
    call kit_pt
    pop rdi
    pop rdx
    mov edi, [main_x]
    add edi, [main_w]
    push rax
    mov edi, 9
    call kit_pt
    mov edi, [main_x]
    add edi, [main_w]
    sub edi, eax
    pop rax
    add esi, eax
    sub edx, eax
    sub edx, eax
    mov ecx, ebx
    push rdx
    call view_area
    pop rdx
    mov r8d, ecx
    mov r9d, [scroll]
    jmp kit_scroller

; paint_icons: a grid of them
paint_icons:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [n], 0
    jne .some
    call empty_say
    jmp .out
.some:
    mov eax, [scroll]                   ; R12D: the first row in sight
    xor edx, edx
    div dword [cell_h]
    imul eax, [cols]
    mov r12d, eax                       ; R12D: which
.each:
    cmp r12d, [n]
    jae .scroller
    mov eax, r12d
    xor edx, edx
    div dword [cols]
    mov r13d, edx                       ; R13D: its column
    imul eax, [cell_h]
    add eax, [gpad]
    add eax, [main_y]
    sub eax, [scroll]
    mov r14d, eax                       ; R14D: its cell's top
    mov eax, [main_y]
    add eax, [main_h]
    cmp r14d, eax
    jge .scroller
    imul r13d, [cell_w]
    add r13d, [gpad]
    add r13d, [main_x]                  ; R13D: its cell's left
    mov eax, r12d
    call entry
    mov rbx, rsi                        ; RBX: its record
    mov edi, 6                          ; R15D: its icon's top
    call kit_pt
    lea r15d, [r14 + rax]
    cmp r12d, [sel]
    jne .icon
    mov edi, 6                          ; chosen: a backdrop
    call kit_pt
    mov edi, [cell_w]
    sub edi, [big]
    shr edi, 1
    add edi, r13d
    sub edi, eax
    mov esi, r15d
    sub esi, eax
    mov edx, [big]
    lea edx, [rdx + rax * 2]
    mov ecx, edx
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 10
    call kit_pt
    mov r8d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov r9d, [c_hilite]
    call kit_round
.icon:
    mov edi, [cell_w]
    sub edi, [big]
    shr edi, 1
    add edi, r13d
    mov esi, r15d
    mov edx, [big]
    call icon_at
    mov edi, 8                          ; its name, under it
    call kit_pt
    add r15d, [big]
    add r15d, eax
    cmp r12d, [sel]
    jne .label
    cmp dword [kfocus], K_RENAME
    jne .label
    mov edi, 10                         ; being renamed: the field
    call kit_pt
    mov edi, r13d
    sub edi, eax
    mov esi, r15d
    mov edx, [cell_w]
    lea edx, [rdx + rax * 2]
    mov ecx, [lab_h]
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 6
    call kit_pt
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    add ecx, eax
    sub esi, eax
    shr eax, 1
    add esi, eax
    mov r9d, [f_label]
    call rename_field
    jmp .next
.label:
    mov edi, r13d
    lea rsi, [rbx + FE_NAME]
    xor ecx, ecx
    cmp r12d, [sel]
    sete cl
    mov edx, r15d
    call label_paint
.next:
    inc r12d
    jmp .each
.scroller:
    call scroller
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rename_field(EDI, ESI, EDX, ECX = where, R9D = font): the field a name
; is typed in, kept to find presses in it
rename_field:
    mov [ren_x], edi
    mov [ren_y], esi
    mov [ren_w], edx
    mov [ren_h], ecx
    mov [ren_font], r9d
    lea r8, [f_rename]
    mov r10d, 1
    jmp kit_edraw

; label_paint(RSI = a name, EDI = its cell's left, EDX = the top, ECX = 1
; if chosen): in up to two lines, centred, broken between words if it can
; be
label_paint:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, edx
    mov ebp, ecx
    call k_slen
    cmp ecx, 200
    jbe .short
    mov ecx, 200
.short:
    lea rdi, [lab_buf]
    push rcx
    rep movsb
    pop rcx
    mov r14d, ecx                       ; R14D: its bytes
    mov edi, 8
    call kit_pt
    mov r15d, [cell_w]
    sub r15d, eax                       ; R15D: the room across
    lea rsi, [lab_buf]
    mov ecx, r14d
    mov edx, [f_label]
    call kit_text_w
    mov [lab_w1], eax
    mov dword [lab_n2], 0
    cmp eax, r15d
    jbe .lines
    mov ebx, r14d                       ; too wide: the most that fits
.fit:
    test ebx, ebx
    jz .broke
    dec ebx
    mov al, [lab_buf + rbx]
    and al, 0xC0
    cmp al, 0x80
    je .fit
    lea rsi, [lab_buf]
    mov ecx, ebx
    mov edx, [f_label]
    call kit_text_w
    cmp eax, r15d
    ja .fit
    mov ecx, ebx                        ; then back to a break, if there is one
.brk:
    cmp ecx, 1
    jbe .broke
    mov al, [lab_buf + rcx - 1]
    cmp al, ' '
    je .at
    cmp al, '-'
    je .at
    cmp al, '_'
    je .at
    dec ecx
    jmp .brk
.at:
    mov ebx, ecx
.broke:
    test ebx, ebx
    jnz .split
    mov ebx, 1
.split:
    lea rsi, [lab_buf]                  ; the first line
    mov ecx, ebx
    mov edx, [f_label]
    call kit_text_w
    mov [lab_w1], eax
    mov [lab_n1], ebx
    lea rsi, [lab_buf + rbx]            ; the rest, fitted
    lea rdi, [lab_buf2]
    mov ecx, r14d
    sub ecx, ebx
    push rcx
    rep movsb
    pop rcx
    lea rsi, [lab_buf2]
    mov edx, r15d
    mov r8d, [f_label]
    call fit_text
    mov [lab_n2], ecx
    mov [lab_w2], eax
    jmp .drawn
.lines:
    mov [lab_n1], r14d
.drawn:
    mov r9d, [c_text]                   ; R9D: its colour
    test ebp, ebp
    jz .text
    mov eax, [lab_w1]                   ; chosen: on the accent
    cmp dword [lab_n2], 0
    je .one
    cmp eax, [lab_w2]
    jae .one
    mov eax, [lab_w2]
.one:
    push rax
    mov edi, 10
    call kit_pt
    pop rdx
    add edx, eax
    mov edi, [cell_w]
    sub edi, edx
    sar edi, 1
    add edi, r12d
    mov esi, r13d
    mov ecx, [lab_h]
    cmp dword [lab_n2], 0
    je .pill
    add ecx, [lab_h]
.pill:
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 5
    call kit_pt
    mov r8d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov r9d, [c_accent]
    cmp dword [focused], 0
    jne .on
    mov r9d, [c_sel_off]
.on:
    call kit_round
    mov r9d, 0xFFFFFF
    cmp dword [focused], 0
    jne .text
    mov r9d, [c_text]
.text:
    mov [lab_ink], r9d
    mov edi, [cell_w]                   ; the first line
    sub edi, [lab_w1]
    sar edi, 1
    add edi, r12d
    lea rsi, [lab_buf]
    mov ecx, [lab_n1]
    mov edx, r13d
    mov eax, [lab_h]
    mov r8d, [f_label]
    call text_at
    cmp dword [lab_n2], 0
    je .out
    mov edi, [cell_w]                   ; the second
    sub edi, [lab_w2]
    sar edi, 1
    add edi, r12d
    lea rsi, [lab_buf2]
    mov ecx, [lab_n2]
    mov edx, r13d
    add edx, [lab_h]
    mov eax, [lab_h]
    mov r8d, [f_label]
    mov r9d, [lab_ink]
    call text_at
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; paint_list: a heading, then a row for each thing
paint_list:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov edi, [main_x]                   ; the heading
    mov esi, [main_y]
    add esi, [head_h]
    dec esi
    mov edx, [main_w]
    mov ecx, 1
    mov r8d, [c_line]
    call kit_fill
    lea rsi, [s_h_name]
    mov edi, [name_x]
    mov eax, SORT_NAME
    call heading
    cmp dword [show_date], 0
    je .h_size
    lea rsi, [s_h_date]
    mov edi, [date_x]
    mov eax, SORT_DATE
    call heading
.h_size:
    lea rsi, [s_h_size]
    mov edi, [size_x]
    mov eax, SORT_SIZE
    call heading
    cmp dword [show_kind], 0
    je .rows
    lea rsi, [s_h_kind]
    mov edi, [kind_x]
    mov eax, SORT_KIND
    call heading
.rows:
    call view_area
    mov edi, [main_x]
    mov esi, eax
    mov edx, [main_w]
    call kit_clip
    cmp dword [n], 0
    jne .some
    call empty_say
    jmp .out
.some:
    mov eax, [scroll]
    xor edx, edx
    div dword [row_h]
    mov r12d, eax                       ; R12D: which
.each:
    cmp r12d, [n]
    jae .scroller
    mov eax, r12d
    imul eax, [row_h]
    mov r13d, eax
    call view_area
    add r13d, eax
    sub r13d, [scroll]                  ; R13D: its top
    add eax, ecx
    cmp r13d, eax
    jge .scroller
    mov eax, r12d
    call entry
    mov rbx, rsi                        ; RBX: its record
    call list_row
    inc r12d
    jmp .each
.scroller:
    call scroller
.out:
    call kit_unclip
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; heading(RSI = its name, EDI = its column's left, EAX = SORT_*): the
; column's heading, a line before it, a chevron if the list is sorted by it
heading:
    push rbx
    push r12
    push r13
    mov rbx, rsi
    mov r12d, edi
    mov r13d, eax
    cmp edi, [name_x]                   ; a line between columns
    je .name
    mov edi, 7
    call kit_pt
    mov esi, eax
    add esi, [main_y]
    mov ecx, [head_h]
    sub ecx, eax
    sub ecx, eax
    mov edi, r12d
    mov edx, 1
    mov r8d, [c_line]
    call kit_fill
.name:
    mov edi, 8
    call kit_pt
    add r12d, eax
    cmp r12d, [name_x]
    jbe .at
    jmp .text
.at:
    mov r12d, [name_x]
.text:
    mov rsi, rbx
    call k_slen
    mov r8d, [f_small]
    mov r9d, [c_text2]
    cmp r13d, [sort_key]
    jne .plain
    mov r8d, [f_head]
    mov r9d, [c_text]
.plain:
    push r8
    push r9
    mov edi, r12d
    mov edx, [main_y]
    mov eax, [head_h]
    call text_at
    pop r9
    pop r8
    cmp r13d, [sort_key]
    jne .out
    mov r12d, eax                       ; the chevron: down for the other way
    mov edi, 9
    call kit_pt
    add r12d, eax
    mov edi, 3
    call kit_pt
    mov ecx, eax
    mov edi, r12d
    mov esi, [head_h]
    shr esi, 1
    add esi, [main_y]
    mov edx, 2
    cmp dword [sort_down], 0
    je .up
    mov edx, 3
.up:
    mov r9d, [c_text2]
    call chevron
.out:
    pop r13
    pop r12
    pop rbx
    ret

; list_row(RBX = a record, R12D = which, R13D = its top)
list_row:
    push r14
    push r15
    test r12d, 1                        ; every other row, a stripe
    jz .chosen
    mov edi, [main_x]
    mov esi, r13d
    mov edx, [main_w]
    mov ecx, [row_h]
    mov r8d, [c_stripe]
    call kit_fill
.chosen:
    mov r14d, [c_text]                  ; R14D, R15D: its inks
    mov r15d, [c_text2]
    cmp r12d, [sel]
    jne .icon
    mov edi, 6
    call kit_pt
    mov edi, [main_x]
    add edi, eax
    mov edx, [main_w]
    sub edx, eax
    sub edx, eax
    push rdi
    push rdx
    mov edi, 5
    call kit_pt
    mov r8d, eax
    pop rdx
    pop rdi
    mov esi, r13d
    mov ecx, [row_h]
    mov r9d, [c_sel_off]
    cmp dword [focused], 0
    je .round
    mov r9d, [c_accent]
    mov r14d, 0xFFFFFF
    mov r15d, KA(0xC8) | 0xFFFFFF
.round:
    call kit_round
.icon:
    mov edi, [name_x]
    mov esi, [row_h]
    sub esi, [small]
    sar esi, 1
    add esi, r13d
    mov edx, [small]
    call icon_at
    mov edi, 8                          ; its name
    call kit_pt
    add eax, [small]
    add eax, [name_x]
    mov [col_at], eax
    cmp r12d, [sel]
    jne .name
    cmp dword [kfocus], K_RENAME
    jne .name
    mov edi, 4                          ; being renamed: the field
    call kit_pt
    mov edi, [col_at]
    sub edi, eax
    mov edx, [date_x]
    sub edx, edi
    sub edx, eax
    sub edx, eax
    mov esi, r13d
    mov ecx, [row_h]
    mov r9d, [f_ui]
    call rename_field
    jmp .date
.name:
    mov edi, 12
    call kit_pt
    mov edx, [date_x]
    sub edx, [col_at]
    sub edx, eax
    lea rsi, [rbx + FE_NAME]
    mov r8d, [f_ui]
    call fit_into
    mov edi, [col_at]
    mov edx, r13d
    mov eax, [row_h]
    mov r8d, [f_ui]
    mov r9d, r14d
    call text_at
.date:
    cmp dword [show_date], 0
    je .size
    lea rdi, [row_buf]
    mov rsi, rbx
    call fmt_when
    mov byte [rdi], 0
    mov edi, 16
    call kit_pt
    mov edx, [date_w]
    sub edx, eax
    lea rsi, [row_buf]
    mov r8d, [f_ui]
    call fit_into
    push rcx
    mov edi, 8
    call kit_pt
    pop rcx
    mov edi, [date_x]
    add edi, eax
    mov edx, r13d
    mov eax, [row_h]
    mov r8d, [f_ui]
    mov r9d, r15d
    call text_at
.size:
    lea rdi, [row_buf]                  ; its size, at the column's right
    lea rsi, [s_dashes]
    test dword [rbx + FE_ATTR], FEA_DIR
    jnz .dashes
    mov rax, [rbx + FE_SIZE]
    call fmt_size
    jmp .sized
.dashes:
    call str_cat
.sized:
    mov byte [rdi], 0
    lea rsi, [row_buf]
    call k_slen
    push rcx
    mov edx, [f_ui]
    call kit_text_w
    pop rcx
    push rax
    mov edi, 12
    call kit_pt
    pop rdx
    mov edi, [size_x]
    add edi, [size_w]
    sub edi, eax
    sub edi, edx
    lea rsi, [row_buf]
    mov edx, r13d
    mov eax, [row_h]
    mov r8d, [f_ui]
    mov r9d, r15d
    call text_at
    cmp dword [show_kind], 0            ; its kind
    je .out
    mov rsi, rbx
    call kind_of
    call kind_rec
    mov rsi, [rsi + KD_NAME]
    mov edi, 16
    call kit_pt
    mov edx, [list_r]
    sub edx, [kind_x]
    sub edx, eax
    mov r8d, [f_ui]
    call fit_into
    push rcx
    mov edi, 8
    call kit_pt
    pop rcx
    mov edi, [kind_x]
    add edi, eax
    mov edx, r13d
    mov eax, [row_h]
    mov r8d, [f_ui]
    mov r9d, r15d
    call text_at
.out:
    pop r15
    pop r14
    ret

; fmt_size(RAX = bytes, RDI) -> "12 KB" there, RDI past it (as Finder:
; a thousand to a kilobyte)
fmt_size:
    cmp rax, 1000
    jae .kb
    push rax
    call put_dec
    pop rax
    lea rsi, [s_bytes]
    cmp rax, 1
    jne .unit
    lea rsi, [s_byte]
    jmp .unit
.kb:
    cmp rax, 1000000
    jae .mb
    add rax, 500
    xor edx, edx
    mov ecx, 1000
    div rcx
    call put_dec
    lea rsi, [s_kb]
    jmp .unit
.mb:
    mov ecx, 1000000
    lea rsi, [s_mb]
    cmp rax, 1000000000
    jb .tenths
    mov ecx, 1000000000
    lea rsi, [s_gb]
.tenths:
    push rsi
    push rcx
    xor edx, edx                        ; tenths, rounded
    mov r8, rcx
    shr rcx, 1
    imul rax, rax, 10
    add rax, rcx
    xor edx, edx
    div r8
    pop rcx
    xor edx, edx
    mov ecx, 10
    div rcx
    push rdx
    call put_dec
    pop rax
    test eax, eax
    jz .whole
    mov byte [rdi], '.'
    inc rdi
    call put_dec
.whole:
    pop rsi
.unit:
    jmp str_cat

; fmt_when(RSI = a record, RDI) -> "18 Oct 2026 at 14:03" there, RDI past
; it; "--" if it was never said
fmt_when:
    push rbx
    mov rbx, rsi
    movzx eax, word [rbx + FE_YEAR]
    test eax, eax
    jz .never
    movzx eax, byte [rbx + FE_DAY]
    call put_dec
    mov byte [rdi], ' '
    inc rdi
    movzx eax, byte [rbx + FE_MONTH]
    dec eax
    cmp eax, 11
    jbe .month
    xor eax, eax
.month:
    lea rsi, [s_months + rax * 4]
    movsw
    movsb
    mov byte [rdi], ' '
    inc rdi
    movzx eax, word [rbx + FE_YEAR]
    call put_dec
    lea rsi, [s_at]
    call str_cat
    movzx eax, byte [rbx + FE_HOUR]
    call two_digits
    mov byte [rdi], ':'
    inc rdi
    movzx eax, byte [rbx + FE_MIN]
    call two_digits
    pop rbx
    ret
.never:
    lea rsi, [s_dashes]
    call str_cat
    pop rbx
    ret

; two_digits(EAX < 100, RDI)
two_digits:
    xor edx, edx
    mov ecx, 10
    div ecx
    add al, '0'
    stosb
    lea eax, [rdx + '0']
    stosb
    ret

; -----------------------------------------------------------------------------
;  The path bar
; -----------------------------------------------------------------------------

paint_path:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [path_hits]
    call hits_new
    mov r13d, [kit_h]
    sub r13d, [path_h]                  ; R13D: its top
    mov edi, [side_w]
    mov esi, r13d
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, [path_h]
    mov r8d, [c_bg]
    call kit_fill
    mov edi, [side_w]
    mov esi, r13d
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, 1
    mov r8d, [c_line]
    call kit_fill
    lea rdi, [stat_buf]                 ; at the right: what was said, or
    mov rsi, [said]                     ; how many things there are
    mov r15d, [c_text]
    test rsi, rsi
    jnz .said
    mov r15d, [c_text2]
    mov eax, [n]
    push rax
    call put_dec
    pop rax
    lea rsi, [s_items]
    cmp eax, 1
    jne .items
    lea rsi, [s_item]
.items:
    call str_cat
    call dir_vol
    test eax, eax
    js .stat
    call vol_rec
    jc .stat
    test dword [rsi + FV_FLAGS], FVF_WRITABLE
    jnz .stat
    lea rsi, [s_read_only]
.said:
    call str_cat
.stat:
    mov byte [rdi], 0
    mov edi, 14
    call kit_pt
    mov r14d, eax
    lea rsi, [stat_buf]
    call k_slen
    push rcx
    mov edx, [f_small]
    call kit_text_w
    pop rcx
    mov ebx, [kit_w]
    sub ebx, r14d
    sub ebx, eax                        ; EBX: where it starts
    mov edi, [side_w]                   ; long: from the bar's left
    add edi, r14d
    cmp ebx, edi
    jge .placed
    mov ebx, edi
.placed:
    mov edi, ebx
    lea rsi, [stat_buf]
    mov edx, r13d
    mov eax, [path_h]
    mov r8d, [f_small]
    mov r9d, r15d
    call text_at
    cmp qword [said], 0                 ; said: it has the bar
    jne .out
    mov edi, [side_w]                   ; the path, left of it
    mov esi, r13d
    mov edx, ebx
    sub edx, edi
    sub edx, r14d
    jle .out
    mov ecx, [path_h]
    call kit_clip
    mov r12d, [side_w]
    add r12d, r14d                      ; R12D: where we are
    call crumbs
    call kit_unclip
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; crumbs: the folders the one shown is in, each a way back to it (R12D =
; the left, R13D = the bar's top)
crumbs:
    push rbx
    push rbp
    xor ebp, ebp                        ; EBP: which
    xor ebx, ebx                        ; EBX: where in dir the next starts
    cmp dword [confined], 0
    je .vol
    lea rsi, [s_this_folder]
    mov eax, SR_FOLDER
    jmp .first
.vol:
    lea rsi, [dir]                      ; past "vol<n>:"
.colon:
    mov al, [rsi + rbx]
    inc ebx
    cmp al, ':'
    jne .colon
    mov [crumb_end], ebx
    cmp byte [dir + rbx], '/'
    jne .label
    inc ebx
.label:
    push rbx
    call dir_vol
    call vol_rec
    mov eax, 0
    jc .fixed
    test dword [rsi + FV_FLAGS], FVF_REMOVABLE
    jz .fixed
    mov eax, SR_REMOVABLE
.fixed:
    push rax
    call dir_vol
    call vol_label
    pop rax
    pop rbx
    jmp .one
.first:
    mov dword [crumb_end], 0
.one:
    call crumb
    inc ebp
.next:
    cmp byte [dir + rbx], 0
    je .out
    cmp ebp, CRUMBS_MAX
    jae .out
    xor ecx, ecx                        ; the next name
.name:
    mov al, [dir + rbx + rcx]
    test al, al
    jz .named
    cmp al, '/'
    je .named
    mov [crumb_name + rcx], al
    inc ecx
    cmp ecx, 120
    jb .name
.named:
    mov byte [crumb_name + rcx], 0
    add ebx, ecx
    mov [crumb_end + rbp * 4], ebx
    cmp byte [dir + rbx], '/'
    jne .sep
    inc ebx
.sep:
    push rbx
    lea rsi, [s_crumb_sep]              ; ›, then it
    call k_slen
    mov edi, r12d
    mov edx, r13d
    mov eax, [path_h]
    mov r8d, [f_small]
    mov r9d, [c_text3]
    call text_at
    mov r12d, eax
    lea rsi, [crumb_name]
    mov eax, SR_FOLDER
    pop rbx
    call crumb
    inc ebp
    jmp .next
.out:
    pop rbp
    pop rbx
    ret

; crumb(RSI = its name, EAX = SR_*, EBP = which; R12D = where, moved past
; it; R13D = the bar's top)
crumb:
    push rbx
    push r14
    push r15
    mov rbx, rsi
    mov r15d, eax
    mov r14d, r12d                      ; R14D: its left
    mov edi, 14
    call kit_pt
    mov edx, eax
    mov esi, [path_h]
    sub esi, eax
    sar esi, 1
    add esi, r13d
    mov edi, r12d
    test r15d, SR_FOLDER
    jz .drive
    mov [icon_x], edi
    mov [icon_y], esi
    mov [icon_s], edx
    push rdx
    call folder_icon
    pop rdx
    jmp .name
.drive:
    push rdx
    mov ecx, r15d
    and ecx, SR_REMOVABLE
    mov r9d, [c_text2]
    call drive_icon
    pop rdx
.name:
    add r12d, edx
    mov edi, 5
    call kit_pt
    add r12d, eax
    mov rsi, rbx
    call k_slen
    mov edi, r12d
    mov edx, r13d
    mov eax, [path_h]
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call text_at
    mov r12d, eax
    mov edi, r14d                       ; a press on it goes there
    mov esi, r13d
    mov edx, r12d
    sub edx, r14d
    mov ecx, [path_h]
    lea r8d, [rbp + H_CRUMB]
    call hit_add
    pop r15
    pop r14
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Over the window: a menu, an alert, a look
; -----------------------------------------------------------------------------

paint_over:
    lea rdi, [over_hits]
    call hits_new
    mov eax, [over]
    cmp eax, O_MENU
    je paint_menu
    cmp eax, O_ALERT
    je paint_alert
    cmp eax, O_LOOK
    je paint_look
    ret

; paint_menu: its items, at menu_x, menu_y (moved to fit)
paint_menu:
    push rbx
    push r12
    push r13
    push r14
    push r15
    PX m_item_h, 24
    PX m_sep_h, 11
    PX m_pad, 5
    PX m_w, 230
    mov eax, [m_pad]                    ; its height
    add eax, eax
    xor ecx, ecx
.height:
    cmp ecx, [menu_n]
    jae .measured
    cmp dword [menu_ids + rcx * 4], M_SEP
    je .sep_h
    add eax, [m_item_h]
    jmp .next_h
.sep_h:
    add eax, [m_sep_h]
.next_h:
    inc ecx
    jmp .height
.measured:
    mov [m_h], eax
    mov eax, [kit_w]                    ; inside the window
    sub eax, [m_w]
    sub eax, 4
    cmp [menu_x], eax
    jle .x
    mov [menu_x], eax
.x:
    mov eax, [kit_h]
    sub eax, [m_h]
    sub eax, 4
    cmp [menu_y], eax
    jle .y
    mov [menu_y], eax
.y:
    cmp dword [menu_y], 4
    jge .y_ok
    mov dword [menu_y], 4
.y_ok:
    cmp dword [menu_x], 4
    jge .x_ok
    mov dword [menu_x], 4
.x_ok:
    mov edi, 8
    call kit_pt
    mov r12d, eax                       ; R12D: its corners
    mov edi, [menu_x]
    mov esi, [menu_y]
    mov edx, [m_w]
    mov ecx, [m_h]
    mov r8d, r12d
    push rdi
    mov edi, 14
    call kit_pt
    mov r9d, eax
    pop rdi
    call kit_shadow
    mov edi, [menu_x]
    mov esi, [menu_y]
    mov edx, [m_w]
    mov ecx, [m_h]
    mov r8d, r12d
    mov r9d, [c_tip]
    call kit_round
    mov edi, [menu_x]
    mov esi, [menu_y]
    mov edx, [m_w]
    mov ecx, [m_h]
    mov r8d, r12d
    mov r9d, [c_edge]
    mov r10d, 1
    call kit_frame
    mov r13d, [menu_y]
    add r13d, [m_pad]                   ; R13D: where we are
    xor ebx, ebx                        ; EBX: which
.each:
    cmp ebx, [menu_n]
    jae .out
    mov r14d, [menu_ids + rbx * 4]      ; R14D: its M_*
    cmp r14d, M_SEP
    jne .item
    mov edi, 12
    call kit_pt
    mov edi, [menu_x]
    add edi, eax
    mov edx, [m_w]
    sub edx, eax
    sub edx, eax
    mov esi, [m_sep_h]
    shr esi, 1
    add esi, r13d
    mov ecx, 1
    mov r8d, [c_edge]
    call kit_fill
    add r13d, [m_sep_h]
    jmp .next
.item:
    mov edi, [menu_x]
    add edi, [m_pad]
    mov esi, r13d
    mov edx, [m_w]
    sub edx, [m_pad]
    sub edx, [m_pad]
    mov ecx, [m_item_h]
    lea r8d, [rbx + H_MENU]
    call hit_add
    mov r15d, [c_tip_text]              ; R15D: its ink
    cmp ebx, [menu_hl]
    jne .label
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 5
    call kit_pt
    mov r8d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    mov r9d, [c_accent]
    call kit_round
    mov r15d, 0xFFFFFF
.label:
    mov eax, r14d
    lea rsi, [m_labels]
    mov rsi, [rsi + rax * 8]
    call k_slen
    mov edi, 12
    push rcx
    push rsi
    call kit_pt
    pop rsi
    pop rcx
    mov edi, [menu_x]
    add edi, [m_pad]
    add edi, eax
    mov edx, r13d
    mov eax, [m_item_h]
    mov r8d, [f_ui]
    mov r9d, r15d
    call text_at
    mov eax, r14d                       ; its keys, at the right
    lea rsi, [m_keys]
    mov rsi, [rsi + rax * 8]
    test rsi, rsi
    jz .keyless
    push rsi
    call k_slen
    mov edx, [f_ui]
    call kit_text_w
    pop rsi
    push rax
    mov edi, 12
    call kit_pt
    pop rdx
    mov edi, [menu_x]
    add edi, [m_w]
    sub edi, [m_pad]
    sub edi, eax
    sub edi, edx
    call k_slen
    mov edx, r13d
    mov eax, [m_item_h]
    mov r8d, [f_ui]
    mov r9d, [c_text3]
    cmp ebx, [menu_hl]
    jne .keys
    mov r9d, KA(0xC0) | 0xFFFFFF
.keys:
    call text_at
.keyless:
    add r13d, [m_item_h]
.next:
    inc ebx
    jmp .each
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; card(EDI = width, ESI = height): a card over the window, the window
; dimmed under it, centred across, high -> card_x, card_y
card:
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov [card_w], edi
    mov [card_h], esi
    xor edi, edi
    xor esi, esi
    mov edx, [kit_w]
    mov ecx, [kit_h]
    mov r8d, KA(0x40) | 0x000000
    call kit_fill
    mov eax, [kit_w]
    sub eax, r12d
    sar eax, 1
    mov [card_x], eax
    mov eax, [kit_h]
    sub eax, r13d
    sar eax, 1
    cmp eax, [tool_h]
    jle .y
    mov eax, [tool_h]
.y:
    mov [card_y], eax
    mov edi, 12
    call kit_pt
    mov [card_r], eax
    mov edi, 24
    call kit_pt
    mov r9d, eax
    mov edi, [card_x]
    mov esi, [card_y]
    mov edx, r12d
    mov ecx, r13d
    mov r8d, [card_r]
    call kit_shadow
    mov edi, [card_x]
    mov esi, [card_y]
    mov edx, r12d
    mov ecx, r13d
    mov r8d, [card_r]
    mov r9d, [c_panel]
    cmp dword [over], O_LOOK
    jne .fill
    mov r9d, [c_bg]
.fill:
    call kit_round
    mov edi, [card_x]
    mov esi, [card_y]
    mov edx, r12d
    mov ecx, r13d
    mov r8d, [card_r]
    mov r9d, [c_edge]
    mov r10d, 1
    call kit_frame
    pop r13
    pop r12
    ret

; paint_alert: whether to delete what is chosen
paint_alert:
    push rbx
    push r12
    push r13
    push r14
    mov edi, 420
    call kit_pt
    mov r12d, eax                       ; R12D: its width
    mov edi, 154
    call kit_pt
    mov esi, eax
    mov edi, r12d
    call card
    mov edi, 22
    call kit_pt
    mov r13d, eax                       ; R13D: its padding
    lea rdi, [alert_buf]                ; the question
    lea rsi, [s_ask_del1]
    call str_cat
    lea rsi, [alert_name]
    call str_cat
    lea rsi, [s_ask_del2]
    call str_cat
    mov byte [rdi], 0
    mov edi, 19
    call kit_pt
    mov ecx, eax
    mov eax, [card_y]
    add eax, r13d
    mov edi, [card_x]
    add edi, r13d
    mov edx, r12d
    sub edx, r13d
    sub edx, r13d
    lea rsi, [alert_buf]
    mov r8d, [f_bold]
    mov r9d, [c_text]
    call wrap_text
    mov r14d, eax                       ; then what it means
    mov edi, 6
    call kit_pt
    add r14d, eax
    mov edi, 17
    call kit_pt
    mov ecx, eax
    mov eax, r14d
    mov edi, [card_x]
    add edi, r13d
    mov edx, r12d
    sub edx, r13d
    sub edx, r13d
    lea rsi, [s_ask_del3]
    cmp dword [alert_dir], 0
    je .what
    lea rsi, [s_ask_del4]
.what:
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call wrap_text
    mov edi, 28                         ; the buttons, at the right
    call kit_pt
    mov ebx, eax                        ; EBX: their height
    mov edi, 88
    call kit_pt
    mov r14d, eax                       ; R14D: their width
    mov esi, [card_y]
    mov edi, 154
    push rsi
    call kit_pt
    pop rsi
    add esi, eax
    sub esi, r13d
    sub esi, ebx
    mov edi, [card_x]
    add edi, r12d
    sub edi, r13d
    sub edi, r14d
    push rdi
    push rsi
    mov edx, r14d
    mov ecx, ebx
    mov r8d, H_A_OK
    call hit_add
    lea r8, [s_delete]
    mov r9d, KB_DEFAULT
    call kit_button
    pop rsi
    pop rdi
    push rsi
    push rdi
    mov edi, 10
    call kit_pt
    pop rdi
    pop rsi
    sub edi, eax
    sub edi, r14d
    mov edx, r14d
    mov ecx, ebx
    push rdi
    push rsi
    mov r8d, H_A_CANCEL
    call hit_add
    pop rsi
    pop rdi
    lea r8, [s_cancel]
    xor r9d, r9d
    call kit_button
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wrap_text(RSI = NUL-ended text, EDI = x, EAX = the first line's top,
; EDX = width, ECX = a line's height, R8D = font, R9D = colour): broken at
; blanks -> EAX = the top below it
wrap_text:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov rbx, rsi                        ; RBX: the line's start
    mov [rsp], edi
    mov r12d, eax                       ; R12D: its top
    mov r13d, edx
    mov ebp, ecx
    mov r14d, r8d
    mov r15d, r9d
.line:
    cmp byte [rbx], 0
    je .done
    xor ecx, ecx                        ; ECX: what fits
    xor r8d, r8d                        ; R8D: up to the last blank
.grow:
    mov al, [rbx + rcx]
    test al, al
    jz .end
    cmp al, ' '
    jne .more
    mov r8d, ecx
.more:
    inc ecx
    push rcx
    push r8
    mov rsi, rbx
    mov edx, r14d
    call kit_text_w
    pop r8
    pop rcx
    cmp eax, r13d
    jbe .grow
    test r8d, r8d                       ; too wide: back to the blank
    jz .whole
    mov ecx, r8d
    jmp .draw
.whole:
    dec ecx
    jnz .draw
    inc ecx
    jmp .draw
.end:
.draw:
    push rcx
    mov rsi, rbx
    mov edi, [rsp + 8]
    mov edx, r12d
    mov eax, ebp
    mov r8d, r14d
    mov r9d, r15d
    call text_at
    pop rcx
    add rbx, rcx
    add r12d, ebp
.blank:
    cmp byte [rbx], ' '
    jne .line
    inc rbx
    jmp .blank
.done:
    mov eax, r12d
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; paint_look: a file, looked at: its text, or what it is
paint_look:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov edi, 760
    call kit_pt
    mov r12d, eax                       ; R12D: its width
    mov edi, 60
    call kit_pt
    mov ecx, [kit_w]
    sub ecx, eax
    cmp r12d, ecx
    jbe .w
    mov r12d, ecx
.w:
    mov r13d, [kit_h]                   ; R13D: its height
    sub r13d, eax
    mov edi, r12d
    mov esi, r13d
    call card
    mov edi, 40
    call kit_pt
    mov r14d, eax                       ; R14D: its header's height
    mov edi, [card_x]                   ; the header, the bar's colour
    mov esi, [card_y]
    mov edx, r12d
    mov ecx, r14d
    add ecx, [card_r]
    mov r8d, [card_r]
    mov r9d, [c_side]
    call kit_round
    mov edi, [card_x]
    mov esi, [card_y]
    add esi, r14d
    mov edx, r12d
    mov ecx, [card_r]
    mov r8d, [c_bg]
    call kit_fill
    mov edi, [card_x]
    mov esi, [card_y]
    add esi, r14d
    mov edx, r12d
    mov ecx, 1
    mov r8d, [c_sep]
    call kit_fill
    mov edi, 12                         ; close, at the left
    call kit_pt
    mov ebx, eax
    mov edi, 14
    call kit_pt
    mov edi, [card_x]
    add edi, eax
    mov esi, r14d
    sub esi, ebx
    sar esi, 1
    add esi, [card_y]
    push rdi
    push rsi
    mov edx, ebx
    mov ecx, ebx
    mov r8d, H_L_CLOSE
    call hit_add
    mov r8d, ebx
    shr r8d, 1
    mov edx, ebx
    mov ecx, ebx
    mov r9d, 0xFF5F57
    call kit_round
    pop rsi
    pop rdi
    shr ebx, 1
    add edi, ebx
    add esi, ebx
    mov edx, KA(0x90) | 0x4D0000
    call x_mark
    xor r15d, r15d                      ; R15D: the open button's left
    cmp dword [ql_text], 0              ; text: open it, at the right
    je .title
    mov edi, 130
    call kit_pt
    mov ebx, eax
    mov edi, 12
    call kit_pt
    mov edi, [card_x]
    add edi, r12d
    sub edi, eax
    sub edi, ebx
    mov r15d, edi
    mov edi, 26
    call kit_pt
    mov ecx, eax
    mov esi, r14d
    sub esi, eax
    sar esi, 1
    add esi, [card_y]
    mov edi, r15d
    mov edx, ebx
    push rsi
    push rcx
    mov r8d, H_L_OPEN
    call hit_add
    pop rcx
    pop rsi
    lea r8, [s_open_notes]
    xor r9d, r9d
    call kit_button
.title:
    mov edi, 300                        ; its name, in the middle
    call kit_pt
    mov edx, eax
    lea rsi, [ql_name]
    mov r8d, [f_bold]
    call fit_into
    mov edi, r12d
    sub edi, eax
    sar edi, 1
    add edi, [card_x]
    mov edx, [card_y]
    mov eax, r14d
    mov r8d, [f_bold]
    mov r9d, [c_text]
    call text_at
    mov edi, [card_x]                   ; what it holds, inside it
    inc edi
    mov esi, [card_y]
    add esi, r14d
    inc esi
    mov edx, r12d
    sub edx, 2
    mov ecx, r13d
    sub ecx, r14d
    sub ecx, [card_r]
    call kit_clip
    cmp dword [ql_text], 0
    je .about
    call look_text
    jmp .done
.about:
    call look_about
.done:
    call kit_unclip
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; look_text: the file's lines from ql_top, in the monospaced font (R12D =
; the card's width, R13D its height, R14D its header's)
look_text:
    push rbx
    push rbp
    push r15
    mov edi, 16
    call kit_pt
    mov edi, eax
    call kit_mono
    mov edi, 4
    call kit_pt
    add eax, [kit_mch]
    mov [ql_line_h], eax
    mov edi, 16
    call kit_pt
    mov ebp, [card_x]
    add ebp, eax                        ; EBP: the lines' left
    mov ebx, [card_y]
    add ebx, r14d
    mov edi, 12
    call kit_pt
    add ebx, eax                        ; EBX: a line's top
    mov rsi, [ql_va]                    ; the first line shown
    add rsi, FS_PATH
    mov rdx, rsi
    add rdx, [ql_len]                   ; RDX: the end
    mov ecx, [ql_top]
.skip:
    test ecx, ecx
    jz .lines
    cmp rsi, rdx
    jae .lines
    lodsb
    cmp al, 10
    jne .skip
    dec ecx
    jmp .skip
.lines:
    mov eax, [card_y]                   ; until the card's bottom
    add eax, r13d
    sub eax, [card_r]
    sub eax, [ql_line_h]
    mov [ql_bottom], eax
    mov eax, [card_x]
    add eax, r12d
    sub eax, ebp
    mov [ql_right], eax
    add [ql_right], ebp
.line:
    cmp ebx, [ql_bottom]
    jg .out
    cmp rsi, rdx
    jae .out
    xor r15d, r15d                      ; R15D: the column
.char:
    cmp rsi, rdx
    jae .out
    movzx eax, byte [rsi]
    cmp al, 10
    je .eol
    cmp al, 13
    je .cr
    cmp al, 9
    je .tab
    push rdx
    call kit_utf8
    pop rdx
    mov ecx, r15d
    imul ecx, [kit_mcw]
    lea edi, [rbp + rcx]
    mov ecx, edi
    add ecx, [kit_mcw]
    cmp ecx, [ql_right]
    jg .past
    push rsi
    push rdx
    mov esi, ebx
    mov r9d, [c_text]
    call kit_mchar
    pop rdx
    pop rsi
.past:
    inc r15d
    jmp .char
.cr:
    inc rsi
    jmp .char
.tab:
    inc rsi
    add r15d, 4
    and r15d, -4
    jmp .char
.eol:
    inc rsi
    add ebx, [ql_line_h]
    jmp .line
.out:
    pop r15
    pop rbp
    pop rbx
    ret

; look_about: what a file is, when it is not text (R12D, R13D, R14D as
; look_text)
look_about:
    push rbx
    push r15
    mov edi, 128                        ; its icon, large
    call kit_pt
    mov ebx, eax
    mov edi, r12d
    sub edi, eax
    sar edi, 1
    add edi, [card_x]
    mov esi, r13d
    sub esi, r14d
    sub esi, eax
    push rdi
    mov edi, 90
    call kit_pt
    pop rdi
    sub esi, eax
    sar esi, 1
    add esi, r14d
    add esi, [card_y]
    mov r15d, esi
    push rbx
    lea rbx, [ql_rec]
    mov edx, [rsp]
    call icon_at
    pop rbx
    add r15d, ebx                       ; its kind, its size; when written
    mov edi, 14
    call kit_pt
    add r15d, eax
    lea rdi, [row_buf]
    lea rsi, [ql_rec]
    call kind_of
    call kind_rec
    mov rsi, [rsi + KD_NAME]
    call str_cat
    test dword [ql_rec + FE_ATTR], FEA_DIR
    jnz .kind
    lea rsi, [s_dot]
    call str_cat
    mov rax, [ql_rec + FE_SIZE]
    call fmt_size
.kind:
    mov byte [rdi], 0
    lea rsi, [row_buf]
    call centred
    lea rdi, [row_buf]
    lea rsi, [s_modified]
    call str_cat
    lea rsi, [ql_rec]
    call fmt_when
    mov byte [rdi], 0
    lea rsi, [row_buf]
    call centred
    pop r15
    pop rbx
    ret

; centred(RSI = NUL-ended; R15D = the line's top, moved down; R12D = the
; card's width): a line in the card's middle
centred:
    push rsi
    call k_slen
    mov edx, [f_ui]
    call kit_text_w
    pop rsi
    mov edi, r12d
    sub edi, eax
    sar edi, 1
    add edi, [card_x]
    call k_slen
    mov edx, r15d
    mov edi, edi
    push rdi
    mov edx, [f_ui]
    call kit_line
    mov r8d, eax
    pop rdi
    mov edx, r15d
    add r15d, r8d
    mov eax, r8d
    mov r8d, [f_ui]
    mov r9d, [c_text2]
    jmp text_at

section .rodata
s_more:         db 0xE2, 0x80, 0xA6, 0
s_locations:    db 'Locations', 0
s_search:       db 'Search', 0
s_empty:        db 'This folder is empty.', 0
s_cant_read:    db 'This folder could not be read.', 0
s_no_results:   db 'No Results', 0
s_h_name:       db 'Name', 0
s_h_date:       db 'Date Modified', 0
s_h_size:       db 'Size', 0
s_h_kind:       db 'Kind', 0
s_dashes:       db '--', 0
s_bytes:        db ' bytes', 0
s_byte:         db ' byte', 0
s_kb:           db ' KB', 0
s_mb:           db ' MB', 0
s_gb:           db ' GB', 0
s_months:       db 'Jan', 0, 'Feb', 0, 'Mar', 0, 'Apr', 0, 'May', 0, 'Jun', 0
                db 'Jul', 0, 'Aug', 0, 'Sep', 0, 'Oct', 0, 'Nov', 0, 'Dec', 0
s_at:           db ' at ', 0
s_items:        db ' items', 0
s_item:         db ' item', 0
s_read_only:    db '  ', 0xC2, 0xB7, '  Read-only', 0
s_crumb_sep:    db '  ', 0xE2, 0x80, 0xBA, '  ', 0
s_ask_del1:     db 'Are you sure you want to delete ', 0xE2, 0x80, 0x9C, 0
s_ask_del2:     db 0xE2, 0x80, 0x9D, '?', 0
s_ask_del3:     db "It will be deleted at once. You can't undo this.", 0
s_ask_del4:     db "It and everything in it will be deleted at once. You can't undo this.", 0
s_delete:       db 'Delete', 0
s_cancel:       db 'Cancel', 0
s_open_notes:   db 'Open with Notes', 0
s_dot:          db '  ', 0xC2, 0xB7, '  ', 0
s_modified:     db 'Modified ', 0

section .bss
alignb 8
said:           resq 1                  ; what the path bar says, for now
hit_tab:        resq 1
f_ui:           resd 1
f_bold:         resd 1
f_small:        resd 1
f_head:         resd 1
f_title:        resd 1
f_label:        resd 1
f_badge:        resd 1
view:           resd 1                  ; V_*
over:           resd 1                  ; O_*, 0 if nothing
scroll:         resd 1                  ; pixels of it above what is shown
tool_h:         resd 1
path_h:         resd 1
side_w:         resd 1
main_x:         resd 1
main_y:         resd 1
main_w:         resd 1
main_h:         resd 1
gpad:           resd 1
row_h:          resd 1
head_h:         resd 1
cell_w:         resd 1
cell_h:         resd 1
big:            resd 1
small:          resd 1
lab_h:          resd 1
cols:           resd 1
side_row_h:     resd 1
badge_min:      resd 1
list_r:         resd 1
name_x:         resd 1
date_x:         resd 1
size_x:         resd 1
kind_x:         resd 1
kind_w:         resd 1
size_w:         resd 1
date_w:         resd 1
show_date:      resd 1
show_kind:      resd 1
col_at:         resd 1
seg_x:          resd 1
seg_w:          resd 1
lab_w1:         resd 1
lab_w2:         resd 1
lab_n1:         resd 1
lab_n2:         resd 1
lab_ink:        resd 1
m_item_h:       resd 1
m_sep_h:        resd 1
m_pad:          resd 1
m_w:            resd 1
m_h:            resd 1
card_x:         resd 1
card_y:         resd 1
card_r:         resd 1
card_w:         resd 1
card_h:         resd 1
ren_x:          resd 1                  ; the field a name is typed in
ren_y:          resd 1
ren_w:          resd 1
ren_h:          resd 1
ren_font:       resd 1
ql_line_h:      resd 1
ql_bottom:      resd 1
ql_right:       resd 1
c_bg:           resd 1
c_side:         resd 1
c_sep:          resd 1
c_line:         resd 1
c_text:         resd 1
c_text2:        resd 1
c_text3:        resd 1
c_panel:        resd 1
c_tip:          resd 1
c_tip_text:     resd 1
c_accent:       resd 1
c_stripe:       resd 1
c_hilite:       resd 1
c_side_sel:     resd 1
c_sel_off:      resd 1
c_edge:         resd 1
c_seg:          resd 1
c_seg_on:       resd 1
crumb_end:      resd CRUMBS_MAX         ; where in dir each part ends
side_hits:      resb 8 + HITS_MAX * HIT_SIZE
tool_hits:      resb 8 + HITS_MAX * HIT_SIZE
path_hits:      resb 8 + HITS_MAX * HIT_SIZE
over_hits:      resb 8 + HITS_MAX * HIT_SIZE
fit_buf:        resb 256
lab_buf:        resb 208
lab_buf2:       resb 208
row_buf:        resb 256
stat_buf:       resb 256
crumb_name:     resb 128
alert_buf:      resb FS_PATH + 128
