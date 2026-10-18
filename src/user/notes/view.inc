; =============================================================================
;  notes/view.inc - how Notes looks: its measures, its colours, and drawing
;  what is to be drawn (need: N_*)
;
;  From the top: the tabs, a bar to find in (when open), the text with its
;  line numbers at the left, and a line of status at the foot. The text is
;  the monospaced font's, its cell as the zoom has it; each line is coloured
;  from the state the line before it left (lex), which st_* keeps for the
;  line last asked for.
; =============================================================================

CLS_MAX         equ 16384               ; a line's bytes coloured, at most
TAB_MAX_PT      equ 220                 ; a tab's width, at most

section .text

; measure: the fonts, the cell, where everything is, the colours
measure:
    push rbx
    push r12
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
    mov edi, 20                         ; the cell nearest 20 points, then zoomed
    call kit_pt
    mov r8d, eax
    mov rsi, [kit_mf]
    xor ecx, ecx
    xor r9d, r9d
    mov edx, 0x7FFFFFFF
.size:
    cmp ecx, [rsi + MFB_SIZES]
    jae .sized
    mov eax, ecx
    shl eax, 4
    mov eax, [rsi + MFB_FONTS + rax + 12]
    sub eax, r8d
    jns .abs
    neg eax
.abs:
    cmp eax, edx
    jae .next_size
    mov edx, eax
    mov r9d, ecx
.next_size:
    inc ecx
    jmp .size
.sized:
    mov eax, r9d
    add eax, [zoom]
    jns .not_small
    xor eax, eax
.not_small:
    mov ecx, [rsi + MFB_SIZES]
    dec ecx
    cmp eax, ecx
    jle .not_large
    mov eax, ecx
.not_large:
    sub eax, r9d                        ; as far as it can go
    mov [zoom], eax
    add eax, r9d
    shl eax, 4
    mov edi, [rsi + MFB_FONTS + rax + 12]
    call kit_mono
    mov eax, [kit_mcw]
    mov [cw], eax
    PX lead, 3
    mov eax, [kit_mch]
    add eax, [lead]
    mov [line_h], eax
    PX tab_h, 34
    PX stat_h, 24
    PX pad_top, 6
    xor eax, eax                        ; the bar: one row, or two to replace
    cmp dword [bar], 0
    je .bar_h
    mov edi, 40
    cmp dword [bar], BAR_REPLACE
    jne .bar_one
    mov edi, 72
.bar_one:
    call kit_pt
.bar_h:
    mov [bar_h], eax
    mov eax, [tab_h]
    add eax, [bar_h]
    mov [ed_y0], eax
    mov eax, [kit_h]
    sub eax, [stat_h]
    cmp eax, [ed_y0]
    jge .y1
    mov eax, [ed_y0]
.y1:
    mov [ed_y1], eax
    sub eax, [ed_y0]
    sub eax, [pad_top]
    jg .rows
    mov eax, 1
.rows:
    xor edx, edx
    div dword [line_h]
    test eax, eax
    jnz .some
    inc eax
.some:
    mov [rows], eax
    call gutter
    call colours
    pop r12
    pop rbx
    ret

; gutter: its width, from the digits the last line's number has
gutter:
    push rbx
    call cur_doc
    mov eax, [rbx + D_NLINES]
    mov ecx, 1
.digits:
    cmp eax, 10
    jb .counted
    xor edx, edx
    push rcx
    mov ecx, 10
    div ecx
    pop rcx
    inc ecx
    jmp .digits
.counted:
    cmp ecx, 3
    jae .wide
    mov ecx, 3
.wide:
    mov [gut_digits], ecx
    imul ecx, [cw]
    push rcx
    mov edi, 28
    call kit_pt
    pop rcx
    add eax, ecx
    mov [text_x], eax
    mov eax, [kit_w]
    sub eax, [text_x]
    push rax
    mov edi, 14
    call kit_pt
    mov ecx, eax
    pop rax
    sub eax, ecx
    xor edx, edx
    div dword [cw]
    test eax, eax
    jg .cols
    mov eax, 1
.cols:
    mov [cols], eax
    pop rbx
    ret

colours:
    mov edi, TC_WINDOW
    call kit_c
    mov [c_bg], eax
    mov edi, TC_TITLE
    call kit_c
    mov [c_tabs], eax
    mov edi, TC_SEP
    call kit_c
    mov [c_sep], eax
    mov edi, TC_TEXT
    call kit_c
    mov [c_text], eax
    mov [pal + T_PLAIN * 4], eax
    mov edi, TC_TEXT2
    call kit_c
    mov [c_text2], eax
    mov edi, TC_TEXT3
    call kit_c
    mov [c_text3], eax
    mov edi, TC_LINE
    call kit_c
    mov [c_line], eax
    mov edi, TC_PANEL
    call kit_c
    mov [c_panel], eax
    call kit_accent
    and eax, 0xFFFFFF
    mov [c_caret], eax
    lea rsi, [pal_dark]
    mov ecx, KA(0x22) | 0xFFFFFF        ; the tab in front
    mov edx, KA(0x1C)                   ; the caret's line, in the accent
    mov r8d, KA(0x78)                   ; what is chosen
    mov r9d, KA(0x58) | 0xFFD60A        ; what was found
    call kit_dark
    je .dark
    lea rsi, [pal_light]
    mov ecx, 0xFFFFFF
    mov edx, KA(0x12)
    mov r8d, KA(0x50)
    mov r9d, KA(0x90) | 0xFFE14D
.dark:
    mov [c_tab_on], ecx
    or edx, eax
    mov [c_curline], edx
    or r8d, eax
    mov [c_sel], r8d
    mov [c_match], r9d
    mov eax, [c_text3]
    or eax, KA(0x48)
    mov [c_sel_off], eax
    lea rdi, [pal + 4]                  ; the rest of the palette
    mov ecx, T_COUNT - 1
    rep movsd
    ret

; -----------------------------------------------------------------------------
;  Drawing
; -----------------------------------------------------------------------------

paint:
    push rbx
    push r12
    mov r12d, [need]
    test r12d, r12d
    jz .out
    mov dword [need], 0
    call cur_doc
    cmp dword [sheet], 0                ; a sheet: all of it again, under it
    je .parts
    mov r12d, N_ALL
.parts:
    call d_dirty                        ; changed, or saved: the title says so
    setne al
    movzx eax, al
    mov ecx, [cur]
    shl ecx, 1
    or eax, ecx
    cmp eax, [title_was]
    je .title
    mov [title_was], eax
    or r12d, N_TITLE
.title:
    test r12d, N_TITLE
    jz .tabs
    call set_title
.tabs:
    call kit_unclip
    test r12d, N_TABS
    jz .bar
    call paint_tabs
.bar:
    test r12d, N_FIND
    jz .text
    cmp dword [bar], 0
    je .text
    call paint_bar
.text:
    test r12d, N_TEXT
    jz .caret
    call paint_text
    jmp .status
.caret:
    test r12d, N_CARET
    jz .status
    call caret_row
.status:
    call kit_unclip
    test r12d, N_STATUS
    jz .sheet
    call paint_status
.sheet:
    call kit_unclip
    cmp dword [sheet], 0
    je .show
    call paint_sheet
    call kit_show_all
    jmp .out
.show:
    mov eax, r12d
    and eax, N_TABS | N_TEXT | N_STATUS | N_FIND
    cmp eax, N_TABS | N_TEXT | N_STATUS | N_FIND
    jne .shown
    call kit_show_all
    jmp .out
.shown:
    test r12d, N_TABS
    jz .shown_bar
    xor edi, edi
    xor esi, esi
    mov edx, [kit_w]
    mov ecx, [tab_h]
    call kit_show
.shown_bar:
    test r12d, N_FIND
    jz .shown_text
    xor edi, edi
    mov esi, [tab_h]
    mov edx, [kit_w]
    mov ecx, [bar_h]
    call kit_show
.shown_text:
    test r12d, N_TEXT
    jz .shown_caret
    xor edi, edi
    mov esi, [ed_y0]
    mov edx, [kit_w]
    mov ecx, [ed_y1]
    sub ecx, esi
    call kit_show
    jmp .shown_status
.shown_caret:
    test r12d, N_CARET
    jz .shown_status
    mov eax, [caret_row_y]
    test eax, eax
    js .shown_status
    xor edi, edi
    mov esi, eax
    mov edx, [kit_w]
    mov ecx, [line_h]
    call kit_show
.shown_status:
    test r12d, N_STATUS
    jz .out
    xor edi, edi
    mov esi, [kit_h]
    sub esi, [stat_h]
    mov edx, [kit_w]
    mov ecx, [stat_h]
    call kit_show
.out:
    pop r12
    pop rbx
    ret

; set_title: the window's: its document's name, "— Edited" if changed
set_title:
    lea rdi, [title_buf]
    call doc_name
    call d_dirty
    je .end
    lea rsi, [s_edited]
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    dec rdi
.end:
    mov byte [rdi], 0
    lea rsi, [title_buf]
    jmp kit_title

; doc_name(RBX, RDI = room) -> its name there, RDI at its end (not ended)
doc_name:
    cmp dword [rbx + D_NEW], 0
    jne .untitled
    mov eax, [rbx + D_NAME]
    lea rsi, [rbx + D_PATH + rax]
    cmp byte [rsi], 0
    jne .copy
.untitled:
    lea rsi, [s_untitled]
.copy:
    lodsb
    test al, al
    jz .done
    stosb
    jmp .copy
.done:
    ret

; -----------------------------------------------------------------------------
;  The tabs
; -----------------------------------------------------------------------------

; tab_measure -> EAX = a tab's width, ECX = where the first begins, EDX =
; where the + is
tab_measure:
    push rbx
    mov edi, 10
    call kit_pt
    mov ebx, eax                        ; EBX: the margin
    mov edi, 30
    call kit_pt
    mov edx, [kit_w]
    sub edx, ebx
    sub edx, eax                        ; EDX: the +
    push rdx
    mov eax, edx
    sub eax, ebx
    sub eax, ebx
    xor edx, edx
    div dword [ndocs]
    push rax
    mov edi, TAB_MAX_PT
    call kit_pt
    pop rcx
    cmp ecx, eax
    jbe .narrow
    mov ecx, eax
.narrow:
    mov eax, ecx
    mov ecx, ebx
    pop rdx
    pop rbx
    ret

paint_tabs:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    xor edi, edi
    xor esi, esi
    mov edx, [kit_w]
    mov ecx, [tab_h]
    mov r8d, [c_tabs]
    call kit_fill
    xor edi, edi
    mov esi, [tab_h]
    dec esi
    mov edx, [kit_w]
    mov ecx, 1
    mov r8d, [c_sep]
    call kit_fill
    call tab_measure
    mov r13d, eax                       ; R13D: a tab's width
    mov r12d, ecx                       ; R12D: where this one begins
    mov [plus_x], edx
    xor r14d, r14d                      ; R14D: which
.each:
    cmp r14d, [ndocs]
    jae .plus
    imul eax, r14d, D_SIZE
    lea rbx, [docs + rax]
    mov edi, 5
    call kit_pt
    mov r15d, eax                       ; R15D: its inset, above and below
    cmp r14d, [cur]
    jne .behind
    call kit_dark                       ; in front: raised
    je .flat
    mov edi, r12d
    add edi, 2
    mov esi, r15d
    mov edx, r13d
    sub edx, 4
    mov ecx, [tab_h]
    sub ecx, r15d
    sub ecx, r15d
    push rdi
    push rsi
    push rdx
    push rcx
    mov edi, 7
    call kit_pt
    mov r8d, eax
    mov edi, 2
    call kit_pt
    mov r9d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    call kit_shadow
.flat:
    mov edi, 7
    call kit_pt
    mov r8d, eax
    mov edi, r12d
    add edi, 2
    mov esi, r15d
    mov edx, r13d
    sub edx, 4
    mov ecx, [tab_h]
    sub ecx, r15d
    sub ecx, r15d
    mov r9d, [c_tab_on]
    call kit_round
    jmp .label
.behind:
    test r14d, r14d                     ; a line between two behind
    jz .label
    lea eax, [r14 - 1]
    cmp eax, [cur]
    je .label
    mov edi, r12d
    mov esi, [tab_h]
    shr esi, 2
    add esi, 1
    mov edx, 1
    mov ecx, [tab_h]
    shr ecx, 1
    mov r8d, [c_line]
    call kit_fill
.label:
    mov edi, 16                         ; at the left: changed, or close
    call kit_pt
    lea ebp, [r12 + rax]                ; EBP: its centre
    call d_dirty
    je .clean
    mov edi, 7
    call kit_pt
    mov edx, eax
    mov ecx, eax
    mov r8d, eax
    shr r8d, 1
    mov edi, ebp
    shr eax, 1
    sub edi, eax
    mov esi, [tab_h]
    sub esi, edx
    shr esi, 1
    mov r9d, [c_text2]
    call kit_round
    jmp .name
.clean:
    cmp r14d, [cur]
    jne .name
    mov edi, ebp
    mov esi, [tab_h]
    shr esi, 1
    mov edx, [c_text2]
    call x_mark
.name:
    lea rdi, [tab_name]                 ; its name, to fit
    call doc_name
    lea rcx, [tab_name]
    sub rdi, rcx
    mov ecx, edi
    mov edi, 60
    call kit_pt
    mov edx, r13d
    sub edx, eax
    lea rsi, [tab_name]
    mov r8d, [f_ui]
    call fit_text                       ; ECX: its bytes, EAX: its width
    mov edi, r13d                       ; centred
    sub edi, eax
    sar edi, 1
    add edi, r12d
    push rdi
    push rcx
    mov edx, [f_ui]
    mov esi, 0
    mov ecx, [tab_h]
    call kit_base
    mov edx, eax
    pop rcx
    pop rdi
    lea rsi, [tab_name]
    mov r8d, [f_ui]
    mov r9d, [c_text]
    cmp r14d, [cur]
    je .write
    mov r9d, [c_text2]
.write:
    call kit_text
    add r12d, r13d
    inc r14d
    jmp .each
.plus:
    mov edi, 15
    call kit_pt
    mov ebx, eax
    mov edi, [plus_x]
    add edi, ebx
    mov esi, [tab_h]
    shr esi, 1
    mov edx, [c_text2]
    call plus_mark
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

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

; x_mark(EDI = x, ESI = y, its centre, EDX = colour): a small ×
x_mark:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, 4
    call kit_pt
    mov ebx, eax                        ; EBX: half its size, in 16ths
    shl ebx, 4
    mov edi, 5
    call kit_pt
    lea r8d, [rax * 4]                  ; its thickness: 1.25 points
    shl r12d, 4
    shl r13d, 4
    add r12d, 8                         ; the centre of the pixel
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

; plus_mark(EDI = x, ESI = y, its centre, EDX = colour): a +
plus_mark:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, 6
    call kit_pt
    mov ebx, eax                        ; EBX: half its size, in 16ths
    shl ebx, 4
    mov edi, 3
    call kit_pt
    lea r8d, [rax * 8]                  ; its thickness: 1.5 points
    shl r12d, 4
    shl r13d, 4
    add r12d, 8
    add r13d, 8
    push r8
    mov edi, r12d
    sub edi, ebx
    mov esi, r13d
    lea edx, [r12 + rbx]
    mov ecx, r13d
    mov r9d, r14d
    call kit_stroke
    pop r8
    mov edi, r12d
    mov esi, r13d
    sub esi, ebx
    mov edx, r12d
    lea ecx, [r13 + rbx]
    mov r9d, r14d
    call kit_stroke
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The text
; -----------------------------------------------------------------------------

paint_text:
    push rbx
    push r12
    call cur_doc
    mov dword [caret_row_y], -1
    xor edi, edi                        ; above the first line, and below the last
    mov esi, [ed_y0]
    mov edx, [kit_w]
    mov ecx, [pad_top]
    mov r8d, [c_bg]
    call kit_fill
    mov eax, [rows]
    imul eax, [line_h]
    add eax, [pad_top]
    add eax, [ed_y0]
    xor edi, edi
    mov esi, eax
    mov edx, [kit_w]
    mov ecx, [ed_y1]
    sub ecx, eax
    jle .rows
    mov r8d, [c_bg]
    call kit_fill
.rows:
    xor r12d, r12d
.each:
    cmp r12d, [rows]
    jae .scroller
    mov ecx, r12d
    call paint_row
    inc r12d
    jmp .each
.scroller:
    mov edi, 10
    call kit_pt
    mov edi, [kit_w]
    sub edi, eax
    mov esi, [ed_y0]
    add esi, 2
    mov edx, [ed_y1]
    sub edx, esi
    sub edx, 2
    mov ecx, [rbx + D_NLINES]
    add ecx, [rows]                     ; it scrolls as far as the last at the top
    dec ecx
    mov r8d, [rows]
    mov r9d, [rbx + D_TOP]
    call kit_scroller
    call kit_unclip
    pop r12
    pop rbx
    ret

; caret_row: the caret's line alone, drawn again
caret_row:
    push rbx
    call cur_doc
    mov dword [caret_row_y], -1
    mov eax, [rbx + D_CARET]
    call line_of
    sub eax, [rbx + D_TOP]
    js .out
    cmp eax, [rows]
    jae .out
    mov ecx, eax
    call paint_row
.out:
    call kit_unclip
    pop rbx
    ret

; paint_row(RBX, ECX = a row shown): its line, its number, what is chosen
; and found on it, the caret
paint_row:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, ecx
    mov eax, ecx                        ; its top
    imul eax, [line_h]
    add eax, [ed_y0]
    add eax, [pad_top]
    mov [row_y], eax
    call kit_unclip
    xor edi, edi
    mov esi, [ed_y0]
    mov edx, [kit_w]
    mov ecx, [ed_y1]
    sub ecx, esi
    call kit_clip
    xor edi, edi
    mov esi, [row_y]
    mov edx, [kit_w]
    mov ecx, [line_h]
    mov r8d, [c_bg]
    call kit_fill
    mov r13d, [rbx + D_TOP]             ; R13D: its line
    add r13d, r12d
    cmp r13d, [rbx + D_NLINES]
    jae .out
    mov eax, r13d
    call line_at
    mov r14d, eax                       ; R14D..R15D: its bytes
    mov r15d, edx
    mov eax, [rbx + D_CARET]
    call line_of
    mov ebp, eax                        ; EBP: the caret's line
    cmp ebp, r13d
    jne .chosen
    mov eax, [row_y]
    mov [caret_row_y], eax
    mov eax, [rbx + D_CARET]            ; the caret's line, if nothing is chosen
    cmp eax, [rbx + D_ANCHOR]
    jne .chosen
    cmp dword [focused], 0
    je .chosen
    xor edi, edi
    mov esi, [row_y]
    mov edx, [kit_w]
    mov ecx, [line_h]
    mov r8d, [c_curline]
    call kit_fill
.chosen:
    call row_found
    mov eax, [rbx + D_CARET]            ; what is chosen, on this line
    mov ecx, [rbx + D_ANCHOR]
    cmp eax, ecx
    je .number
    jb .ordered
    xchg eax, ecx
.ordered:
    cmp ecx, r14d                       ; ends before it
    jbe .number
    cmp eax, r15d                       ; begins after it (its LF chosen: on it)
    ja .number
    push rcx
    mov edi, [text_x]                   ; from
    cmp eax, r14d
    jbe .from
    call col_of
    sub eax, [rbx + D_LEFT]
    imul eax, [cw]
    add eax, [text_x]
    mov edi, eax
.from:
    pop rcx
    mov edx, [kit_w]                    ; to: past the end, all the way
    cmp ecx, r15d
    ja .to
    mov eax, ecx
    push rdi
    call col_of
    pop rdi
    sub eax, [rbx + D_LEFT]
    imul eax, [cw]
    add eax, [text_x]
    mov edx, eax
.to:
    cmp edi, [text_x]
    jge .left_in
    mov edi, [text_x]
.left_in:
    sub edx, edi
    jle .number
    mov esi, [row_y]
    mov ecx, [line_h]
    mov r8d, [c_sel]
    cmp dword [focused], 0
    jne .sel
    mov r8d, [c_sel_off]
.sel:
    call kit_fill
.number:
    lea rdi, [num_buf]                  ; its number, at the right of the gutter
    lea eax, [r13 + 1]
    call put_dec
    lea rsi, [num_buf]
    sub rdi, rsi
    mov ecx, edi
    mov eax, [gut_digits]
    sub eax, ecx
    imul eax, [cw]
    push rax
    mov edi, 14
    call kit_pt
    pop rdi
    add edi, eax
    mov edx, [lead]
    shr edx, 1
    add edx, [row_y]
    mov r9d, [c_text3]
    cmp r13d, ebp
    jne .write_number
    mov r9d, [c_text2]
.write_number:
    lea rsi, [num_buf]
    call kit_mtext
    mov edi, [text_x]                   ; the text, right of the gutter
    mov esi, [ed_y0]
    mov edx, [kit_w]
    sub edx, edi
    mov ecx, [ed_y1]
    sub ecx, esi
    call kit_clip
    mov eax, r13d
    call row_lex
    call row_text
    cmp ebp, r13d                       ; the caret
    jne .out
    cmp dword [caret_on], 0
    je .out
    cmp dword [focused], 0
    je .out
    cmp dword [sheet], 0
    jne .out
    cmp dword [kfocus], 0
    jne .out
    mov eax, [rbx + D_CARET]
    call col_of
    sub eax, [rbx + D_LEFT]
    js .out
    imul eax, [cw]
    add eax, [text_x]
    lea r12d, [rax - 1]                 ; R12D: where, a pixel before the cell
    mov edi, 1
    call kit_pt
    lea edx, [rax + 1]
    mov edi, r12d
    mov esi, [lead]
    shr esi, 2
    add esi, [row_y]
    mov ecx, [line_h]
    mov eax, [lead]
    shr eax, 1
    sub ecx, eax
    mov r8d, [c_caret]
    call kit_fill
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; row_lex(RBX, EAX = a line; R14D..R15D its bytes): cls, its colours
row_lex:
    push r12
    mov r12d, eax
    call state_at
    mov rsi, [rbx + D_BUF]
    add rsi, r14
    mov ecx, r15d
    sub ecx, r14d
    cmp ecx, CLS_MAX
    jbe .short
    mov ecx, CLS_MAX
.short:
    mov edx, [rbx + D_LANG]
    mov [lex_lang], edx
    lea rdi, [cls]
    call lex
    pop r12
    ret

; state_at(RBX, R12D = a line) -> EAX = the state lex begins it in; st_*
; keep it, for the next line asked for after it
state_at:
    push r13
    push r14
    push r15
    xor eax, eax
    cmp dword [rbx + D_LANG], L_PLAIN
    je .out
    mov r13d, 0                         ; R13D: from here
    xor r14d, r14d                      ; R14D: in this state
    cmp [st_doc], rbx
    jne .from
    mov eax, [rbx + D_EDITS]
    cmp [st_edits], eax
    jne .from
    cmp [st_line], r12d
    ja .from
    mov r13d, [st_line]
    mov r14d, [st_state]
.from:
    mov eax, [rbx + D_LANG]
    mov [lex_lang], eax
.each:
    cmp r13d, r12d
    jae .done
    mov eax, r13d
    call line_at
    mov rsi, [rbx + D_BUF]
    add rsi, rax
    mov ecx, edx
    sub ecx, eax
    cmp ecx, CLS_MAX
    jbe .short
    mov ecx, CLS_MAX
.short:
    mov eax, r14d
    lea rdi, [cls]
    call lex
    mov r14d, eax
    inc r13d
    jmp .each
.done:
    mov [st_doc], rbx
    mov eax, [rbx + D_EDITS]
    mov [st_edits], eax
    mov [st_line], r13d
    mov [st_state], r14d
    mov eax, r14d
.out:
    pop r15
    pop r14
    pop r13
    ret

; row_text(RBX, R14D..R15D = a line's bytes, cls its colours): drawn at row_y
row_text:
    push r12
    push r13
    push rbp
    xor r12d, r12d                      ; R12D: its column
    mov r13d, r14d                      ; R13D: where in it
    mov ebp, [lead]
    shr ebp, 1
    add ebp, [row_y]                    ; EBP: the cells' top
.each:
    cmp r13d, r15d
    jae .out
    mov rsi, [rbx + D_BUF]
    movzx eax, byte [rsi + r13]
    cmp eax, 9
    jne .char
    add r12d, TABW
    and r12d, -TABW
    inc r13d
    jmp .each
.char:
    mov ecx, r12d                       ; where, if it is to be seen
    sub ecx, [rbx + D_LEFT]
    cmp ecx, [cols]
    jg .out
    lea rsi, [rsi + r13]
    mov rdx, [rbx + D_BUF]
    add rdx, r15
    push rcx
    call kit_utf8
    pop rcx
    mov edx, r13d                       ; its colour, from its first byte
    sub edx, r14d
    mov r9d, [c_text]
    cmp edx, CLS_MAX
    jae .colour
    movzx edx, byte [cls + rdx]
    mov r9d, [pal + rdx * 4]
.colour:
    sub rsi, [rbx + D_BUF]
    mov r13d, esi
    inc r12d
    test ecx, ecx
    js .each
    mov edi, ecx
    imul edi, [cw]
    add edi, [text_x]
    mov esi, ebp
    call kit_mchar
    jmp .each
.out:
    pop rbp
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  The status line
; -----------------------------------------------------------------------------

paint_status:
    push rbx
    push r12
    push r13
    call cur_doc
    mov r12d, [kit_h]
    sub r12d, [stat_h]                  ; R12D: its top
    xor edi, edi
    mov esi, r12d
    mov edx, [kit_w]
    mov ecx, [stat_h]
    mov r8d, [c_bg]
    call kit_fill
    xor edi, edi
    mov esi, r12d
    mov edx, [kit_w]
    mov ecx, 1
    mov r8d, [c_line]
    call kit_fill
    lea rdi, [stat_buf]                 ; at the left: where the caret is
    cmp dword [said], 0
    je .where
    mov rsi, [said]
    call str_cat
    jmp .left
.where:
    lea rsi, [s_line]
    call str_cat
    mov eax, [rbx + D_CARET]
    call line_of
    inc eax
    call put_dec
    lea rsi, [s_col]
    call str_cat
    mov eax, [rbx + D_CARET]
    call col_of
    inc eax
    call put_dec
    mov eax, [rbx + D_CARET]
    sub eax, [rbx + D_ANCHOR]
    jz .left
    jns .count
    neg eax
.count:
    lea rsi, [s_dot]
    push rax
    call str_cat
    pop rax
    call put_dec
    lea rsi, [s_chosen]
    call str_cat
.left:
    mov byte [rdi], 0
    mov edi, 14
    call kit_pt
    mov r13d, eax                       ; R13D: the margin
    mov edx, [f_small]
    mov esi, r12d
    mov ecx, [stat_h]
    call kit_base
    mov [stat_base], eax
    lea rdi, [stat_buf]
    call k_strlen
    mov ecx, eax
    lea rsi, [stat_buf]
    mov edi, r13d
    mov edx, [stat_base]
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call kit_text
    cmp dword [said], 0                 ; something said: it has the bar
    jne .done
    lea rdi, [stat_buf]                 ; at the right: what it is
    lea rsi, [s_spaces]
    call str_cat
    lea rsi, [s_utf8]
    call str_cat
    lea rsi, [s_lf]
    cmp dword [rbx + D_CRLF], 0
    je .ends
    lea rsi, [s_crlf]
.ends:
    call str_cat
    mov eax, [rbx + D_KIND]
    imul eax, eax, KD_SIZE
    lea rsi, [kinds]
    mov rsi, [rsi + rax + KD_NAME]
    call str_cat
    mov byte [rdi], 0
    lea rdi, [stat_buf]
    call k_strlen
    mov ecx, eax
    push rcx
    lea rsi, [stat_buf]
    mov edx, [f_small]
    call kit_text_w
    pop rcx
    mov edi, [kit_w]
    sub edi, r13d
    sub edi, eax
    lea rsi, [stat_buf]
    mov edx, [stat_base]
    mov r8d, [f_small]
    mov r9d, [c_text2]
    call kit_text
.done:
    pop r13
    pop r12
    pop rbx
    ret

; str_cat(RSI = NUL-ended, RDI) -> copied there, RDI at its end (not ended)
str_cat:
    lodsb
    test al, al
    jz .out
    stosb
    jmp str_cat
.out:
    ret

; -----------------------------------------------------------------------------
;  Where the caret is, kept in sight
; -----------------------------------------------------------------------------

; reveal(RBX): the caret's line and column shown, scrolling if they were not
reveal:
    mov eax, [rbx + D_CARET]
    call line_of
    mov ecx, [rbx + D_TOP]
    cmp eax, ecx
    jae .below_top
    mov [rbx + D_TOP], eax
    or dword [need], N_TEXT
    jmp .column
.below_top:
    add ecx, [rows]
    cmp eax, ecx
    jb .column
    sub eax, [rows]
    inc eax
    mov [rbx + D_TOP], eax
    or dword [need], N_TEXT
.column:
    mov eax, [rbx + D_CARET]
    call col_of
    mov ecx, [rbx + D_LEFT]
    cmp eax, ecx
    jae .right
    sub eax, 8                          ; a little of what is before, too
    jns .left
    xor eax, eax
.left:
    mov [rbx + D_LEFT], eax
    or dword [need], N_TEXT
    ret
.right:
    add ecx, [cols]
    cmp eax, ecx
    jb .out
    sub eax, [cols]
    add eax, 8
    mov [rbx + D_LEFT], eax
    or dword [need], N_TEXT
.out:
    ret

; scroll_to(RBX, EAX = the first line to show): as far as there is
scroll_to:
    test eax, eax
    jns .not_neg
    xor eax, eax
.not_neg:
    mov ecx, [rbx + D_NLINES]
    dec ecx
    cmp eax, ecx
    jle .set
    mov eax, ecx
.set:
    cmp eax, [rbx + D_TOP]
    je .out
    mov [rbx + D_TOP], eax
    or dword [need], N_TEXT
.out:
    ret

section .rodata
align 4
pal_dark:       dd 0x7F8C98, 0xFF7AB2, 0xFF8170, 0xD9C97C, 0xFFA14F
                dd 0x6BDFFF, 0x67B7A4, 0xFF7AB2
pal_light:      dd 0x5D6C79, 0x9B2393, 0xC41A16, 0x1C00CF, 0x643820
                dd 0x0B4F79, 0x326D74, 0x9B2393
s_more:         db 0xE2, 0x80, 0xA6, 0  ; …
s_untitled:     db 'Untitled', 0
s_edited:       db ' ', 0xE2, 0x80, 0x94, ' Edited', 0
s_line:         db 'Line ', 0
s_col:          db ', Column ', 0
s_dot:          db '   ', 0xC2, 0xB7, '   ', 0
s_chosen:       db ' selected', 0
s_spaces:       db 'Spaces: 4      ', 0
s_utf8:         db 'UTF-8      ', 0
s_lf:           db 'LF      ', 0
s_crlf:         db 'CRLF      ', 0

section .bss
alignb 8
st_doc:         resq 1                  ; the line lex last began, and how
said:           resq 1                  ; a word for the status line, until a key
st_edits:       resd 1
st_line:        resd 1
st_state:       resd 1
f_ui:           resd 1
f_bold:         resd 1
f_small:        resd 1
zoom:           resd 1
cw:             resd 1                  ; the cell's width
lead:           resd 1                  ; between lines
line_h:         resd 1
tab_h:          resd 1
bar_h:          resd 1
stat_h:         resd 1
pad_top:        resd 1
ed_y0:          resd 1                  ; the text, from here
ed_y1:          resd 1                  ; to here
rows:           resd 1
cols:           resd 1
gut_digits:     resd 1
text_x:         resd 1
plus_x:         resd 1
row_y:          resd 1
caret_row_y:    resd 1
stat_base:      resd 1
title_was:      resd 1                  ; the tab and whether it had changed, titled
c_bg:           resd 1
c_tabs:         resd 1
c_tab_on:       resd 1
c_sep:          resd 1
c_text:         resd 1
c_text2:        resd 1
c_text3:        resd 1
c_line:         resd 1
c_panel:        resd 1
c_curline:      resd 1
c_sel:          resd 1
c_sel_off:      resd 1
c_caret:        resd 1
c_match:        resd 1
pal:            resd T_COUNT
title_buf:      resb FS_PATH + 32
tab_name:       resb FS_PATH + 8
stat_buf:       resb 160
num_buf:        resb 16
cls:            resb CLS_MAX
