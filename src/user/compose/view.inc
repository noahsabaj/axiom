; =============================================================================
;  compose/view.inc - the window painted: the toolbar, the view (pages,
;  slides or the grid), the status line; and the presenter's slide
;
;  Everything is painted again each time (paint_all), from a layout made
;  again (view_layout). What is laid out is in document coordinates; the
;  view's origin in the window is vw_ox, vw_oy. The slides' thumbnails are
;  each slide painted whole into the offscreen picture (off_px, a slide's
;  size) and made five times smaller; they are kept until the document
;  changes (thumb_gen).
;    view_layout: the lines (and display list) for the view shown; on
;      pages, scrolled to the cursor if vw_follow
;    paint_all: all of the window, into win_px
;    pres_paint(RDI = pixels, ESI = width, EDX = height): the slide being
;      presented, as large as fits, on black
;    picture(EDI = width, ESI = height) -> RAX = a new image (IM_*): a
;      landscape, for an image block to start with
; =============================================================================

V_PAGES         equ 0
V_SLIDES        equ 1
V_GRID          equ 2

GV_FB_H         equ 44                  ; the grid: its formula bar
GV_ROW_H        equ 26
GV_COL_W        equ 120
GV_HEAD_W       equ 52
GV_TAB_H        equ 36
GV_TOP          equ VIEW_Y + GV_FB_H    ; its column letters
GV_CELLS_Y      equ GV_TOP + GV_ROW_H
GV_BOTTOM       equ WIN_H - ST_H - GV_TAB_H
GV_ROWS         equ (GV_BOTTOM - GV_CELLS_Y + GV_ROW_H - 1) / GV_ROW_H
GV_COLS         equ (WIN_W - GV_HEAD_W + GV_COL_W - 1) / GV_COL_W

TH_W            equ SL_W / 5            ; a slide's thumbnail
TH_H            equ SL_H / 5
TH_X            equ 26
TH_ITEM         equ TH_H + 22
TH_MAX          equ 128                 ; thumbnails kept
TH_BYTES        equ TH_W * TH_H * 4

PIC_W           equ 480
PIC_H           equ 270

%define C_SLIDE_RING    C_ACCENT

section .text

; target(RDI = pixels, ESI = pixels a row, EDX = width, ECX = height):
; where drawing goes, all of it the clip. Preserves all.
target:
    mov [px_base], rdi
    mov [px_stride], esi
    mov dword [clip_x0], 0
    mov dword [clip_y0], 0
    mov [clip_x1], edx
    mov [clip_y1], ecx
    ret

target_win:
    push rdi
    push rsi
    push rdx
    push rcx
    mov rdi, [win_px]
    mov esi, WIN_W
    mov edx, WIN_W
    mov ecx, WIN_H
    call target
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; clip(EDI = x0, ESI = y0, EDX = x1, ECX = y1), inside the target's own.
; Preserves all.
clip:
    mov [clip_x0], edi
    mov [clip_y0], esi
    mov [clip_x1], edx
    mov [clip_y1], ecx
    ret

; ring_shadow(EDI = x, ESI = y, EDX = w, ECX = h): a soft shadow around a
; card, outside it only, a little more below. Preserves RBX, RBP, R12-R15.
ring_shadow:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, 1                          ; EBX: how far out
.ring:
    cmp ebx, 5
    jae .out
    mov r9d, 5                          ; alpha: fainter further out
    sub r9d, ebx
    imul r9d, r9d, 7
    mov edi, r12d                       ; above, a little
    sub edi, ebx
    lea esi, [r13 + rbx]
    sub esi, ebx
    sub esi, ebx
    inc esi
    lea edx, [r14 + rbx * 2]
    mov ecx, 1
    mov r8d, C_BLACK
    push r9
    shr r9d, 1
    call blend_rect
    pop r9
    mov edi, r12d                       ; below, further
    sub edi, ebx
    mov esi, r13d
    add esi, r15d
    lea esi, [rsi + rbx - 1]
    lea edx, [r14 + rbx * 2]
    mov ecx, 1
    mov r8d, C_BLACK
    push r9
    call blend_rect
    pop r9
    mov edi, r12d                       ; left and right
    sub edi, ebx
    mov esi, r13d
    sub esi, ebx
    add esi, 2
    mov edx, 1
    lea ecx, [r15 + rbx * 2 - 3]
    mov r8d, C_BLACK
    push r9
    shr r9d, 1
    call blend_rect
    pop r9
    mov edi, r12d
    add edi, r14d
    lea edi, [rdi + rbx - 1]
    mov esi, r13d
    sub esi, ebx
    add esi, 2
    mov edx, 1
    lea ecx, [r15 + rbx * 2 - 3]
    mov r8d, C_BLACK
    shr r9d, 1
    call blend_rect
    inc ebx
    jmp .ring
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- a string being built, for labels --------------------------------------------

sb_reset:
    mov dword [sb_len], 0
    ret

; sb_str(RSI = NUL-ended). Preserves all but RSI, RAX.
sb_str:
    mov al, [rsi]
    test al, al
    jz .out
    call sb_char
    inc rsi
    jmp sb_str
.out:
    ret

; sb_mem(RSI, ECX). Preserves all but RSI, RCX, RAX.
sb_mem:
    test ecx, ecx
    jz .out
    mov al, [rsi]
    call sb_char
    inc rsi
    dec ecx
    jmp sb_mem
.out:
    ret

; sb_char(AL). Preserves all.
sb_char:
    push rcx
    mov ecx, [sb_len]
    cmp ecx, SB_MAX
    jae .out
    mov [sb_buf + rcx], al
    inc dword [sb_len]
.out:
    pop rcx
    ret

; sb_num(EAX = unsigned). Preserves all but RAX.
sb_num:
    push rcx
    push rdx
    push rbx
    xor ebx, ebx
    mov ecx, 10
.digit:
    xor edx, edx
    div ecx
    push rdx
    inc ebx
    test eax, eax
    jnz .digit
.put:
    pop rax
    add al, '0'
    call sb_char
    dec ebx
    jnz .put
    pop rbx
    pop rdx
    pop rcx
    ret

; sb_cell(EAX = a cell's index): its name, as A1. Preserves all but RAX.
sb_cell:
    push rdx
    push rcx
    xor edx, edx
    mov ecx, MAXC
    div ecx
    push rax
    lea eax, [rdx + 'A']
    call sb_char
    pop rax
    inc eax
    call sb_num
    pop rcx
    pop rdx
    ret

; sb_label(EDI = x, R8D = font, R9D = colour, [ui_mid]): the string drawn
sb_label:
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    jmp label

; --- the layout --------------------------------------------------------------------

view_layout:
    mov eax, [view]
    cmp eax, V_PAGES
    je .pages
    cmp eax, V_SLIDES
    je .slides
    call lay_reset                      ; the grid: drawn as it is
    ret
.pages:
    call layout_pages
    mov dword [vw_ox], 0
    cmp byte [vw_follow], 0
    je .scrolled
    mov byte [vw_follow], 0
    call cursor_line
    test rax, rax
    jz .scrolled
    mov ecx, [rax + LN_Y]               ; above what is shown: up to it
    sub ecx, 24
    cmp ecx, [scroll_y]
    jge .below
    mov [scroll_y], ecx
    jmp .scrolled
.below:
    mov ecx, [rax + LN_Y]               ; below it: up until it shows
    add ecx, [rax + LN_H]
    add ecx, 24
    sub ecx, VIEW_H
    cmp ecx, [scroll_y]
    jle .scrolled
    mov [scroll_y], ecx
.scrolled:
    call scroll_clamp
    mov eax, VIEW_Y
    sub eax, [scroll_y]
    mov [vw_oy], eax
    ret
.slides:
    call slides_build
    mov dword [vw_ox], 0
    mov dword [vw_oy], 0
    mov edi, [cur_blk]
    call slide_of
    mov [vw_slide], eax
    cmp eax, -1
    je .no_slide
    mov edi, eax
    mov esi, SLIDE_X
    mov edx, SLIDE_Y
    jmp layout_slide
.no_slide:
    jmp lay_reset

; scroll_clamp: the pages' scroll inside the document
scroll_clamp:
    mov eax, [doc_h]
    sub eax, VIEW_H
    jns .max
    xor eax, eax
.max:
    cmp [scroll_y], eax
    jle .min
    mov [scroll_y], eax
.min:
    cmp dword [scroll_y], 0
    jge .out
    mov dword [scroll_y], 0
.out:
    ret

; cursor_line -> RAX = the line the cursor is on, or 0
cursor_line:
    mov edi, [cur_blk]
    mov esi, [cur_off]
    cmp byte [ed_on], 0
    je line_find
    mov edi, EDIT_BLK
    mov esi, [ed_cell]
    jmp line_find

; --- painting ------------------------------------------------------------------------

paint_all:
    call target_win
    cmp dword [view], V_SLIDES
    jne .laid
    call slides_build
    call thumbs_update                  ; (before the layout: they make their own)
.laid:
    call view_layout
    call target_win
    mov eax, [view]
    cmp eax, V_PAGES
    je .pages
    cmp eax, V_SLIDES
    je .slides
    call paint_grid
    jmp .chrome
.pages:
    call paint_pages
    jmp .chrome
.slides:
    call paint_slides
.chrome:
    call target_win
    call paint_toolbar
    call paint_status
    mov byte [vw_follow], 0
    ret

paint_pages:
    push rbx
    push r12
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, WIN_H - ST_H
    call clip
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_H
    mov r8d, C_WINDOW
    call fill_rect
    xor ebx, ebx                        ; each page that shows
.page:
    cmp ebx, [pg_count]
    jae .pages_done
    mov r12d, ebx
    imul r12d, r12d, PG_H + PG_GAP
    add r12d, PG_GAP
    add r12d, [vw_oy]                   ; R12D: its top, in the window
    lea eax, [r12 + PG_H + 8]
    cmp eax, VIEW_Y
    jl .next_page
    cmp r12d, WIN_H - ST_H
    jge .pages_done
    mov edi, PG_X
    mov esi, r12d
    mov edx, PG_W
    mov ecx, PG_H
    call ring_shadow
    mov edi, PG_X
    mov esi, r12d
    mov edx, PG_W
    mov ecx, PG_H
    mov r8d, C_PAPER
    call fill_rect
    cmp dword [pg_count], 1             ; its number, at its foot
    je .next_page
    call sb_reset
    lea eax, [rbx + 1]
    call sb_num
    lea eax, [r12 + PG_H - PG_M / 2]
    mov [ui_mid], eax
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    mov edi, PG_X + PG_W / 2
    mov r8d, UI_SMALL
    mov r9d, C_FAINT
    call label_c
.next_page:
    inc ebx
    jmp .page
.pages_done:
    call paint_cards
    call paint_sel
    mov edi, [vw_ox]
    mov esi, [vw_oy]
    call draw_list
    call paint_images
    call paint_cursor
    pop r12
    pop rbx
    ret

; paint_cards: each slide frame on a page, a card under its text
paint_cards:
    push rbx
    push r12
    mov rbx, [ln_base]
    mov r12d, [ln_n]
.line:
    test r12d, r12d
    jz .out
    cmp dword [rbx + LN_KIND], LK_BOX
    jne .next
    mov edi, [rbx + LN_BLK]
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .next
    mov edi, [rbx + LN_X0]
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov edx, [rbx + LN_W]
    mov ecx, [rbx + LN_H]
    call ring_shadow
    PUT_C [ui_fill], C_CARD
    mov edi, [rbx + LN_X0]
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov edx, [rbx + LN_W]
    mov ecx, [rbx + LN_H]
    mov r8d, 8
    mov r9d, C_HAIRLINE
    call frame_round
.next:
    add rbx, LN_SIZE
    dec r12d
    jmp .line
.out:
    pop r12
    pop rbx
    ret

; paint_sel: what is chosen, behind its text; a cell or an image chosen
; whole, a tint over it afterwards (paint_images)
paint_sel:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    call sel_any
    je .out
    call sel_range
    mov [ps_b0], eax
    mov [ps_o0], edx
    mov [ps_b1], ecx
    mov [ps_o1], r8d
    mov rbx, [ln_base]
    mov ebp, [ln_n]
.line:
    test ebp, ebp
    jz .out
    mov eax, [rbx + LN_BLK]
    cmp eax, [ps_b0]
    jb .next
    cmp eax, [ps_b1]
    ja .next
    cmp dword [rbx + LN_KIND], LK_TEXT
    jne .box
    mov r12d, [rbx + LN_START]          ; R12D .. R13D: the part of it chosen
    mov r13d, [rbx + LN_END]
    cmp eax, [ps_b0]
    jne .from
    cmp r12d, [ps_o0]
    jae .from
    mov r12d, [ps_o0]
.from:
    cmp eax, [ps_b1]
    jne .to
    cmp r13d, [ps_o1]
    jbe .to
    mov r13d, [ps_o1]
.to:
    cmp r12d, r13d
    ja .next
    xor r15d, r15d                      ; R15D: 6 more, past a line's end it goes on
    cmp r13d, [rbx + LN_END]
    jne .measure
    cmp eax, [ps_b1]
    je .measure
    mov r15d, 6
.measure:
    mov edi, eax
    call blk_at
    mov r14, rax                        ; R14: the block
    mov rdi, r14
    mov esi, [rbx + LN_START]
    mov edx, r12d
    mov ecx, [rbx + LN_FONT]
    call measure
    add eax, 32
    sar eax, 6
    mov r12d, eax                       ; R12D: from, in pixels
    mov rdi, r14
    mov esi, [rbx + LN_START]
    mov edx, r13d
    mov ecx, [rbx + LN_FONT]
    call measure
    add eax, 32
    sar eax, 6
    add eax, r15d
    sub eax, r12d                       ; EAX: how wide
    jle .next
    mov edx, eax
    mov edi, [rbx + LN_X]
    add edi, r12d
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov ecx, [rbx + LN_H]
    mov r8d, C_SELECT
    call fill_rect
    jmp .next
.box:
.next:
    add rbx, LN_SIZE
    dec ebp
    jmp .line
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; in_sel(EAX = a block) -> CF if it is chosen whole. Preserves all.
in_sel:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    mov r9d, eax
    call sel_any
    je .no
    call sel_range
    cmp r9d, eax
    jb .no
    cmp r9d, ecx
    ja .no
    cmp r9d, eax                        ; a grid or an image is one character
    jne .end
    test edx, edx
    jnz .no
.end:
    cmp r9d, ecx
    jne .yes
    test r8d, r8d
    jz .no
.yes:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    stc
    ret
.no:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    clc
    ret

; paint_images: each image's pixels in its box; one chosen, tinted
paint_images:
    push rbx
    push r12
    mov rbx, [ln_base]
    mov r12d, [ln_n]
.line:
    test r12d, r12d
    jz .out
    cmp dword [rbx + LN_KIND], LK_TEXT
    je .next
    mov eax, [rbx + LN_BLK]
    cmp eax, EDIT_BLK
    je .next
    cmp dword [rbx + LN_KIND], LK_CELL
    je .cell
    mov edi, eax
    call blk_at
    cmp byte [rax + BL_KIND], BK_IMAGE
    jne .next
    push rbx
    mov rax, [rax + BL_DATA]
    mov edi, [rbx + LN_X0]
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov edx, [rbx + LN_W]
    mov ecx, [rbx + LN_H]
    mov rbx, rax
    call img_draw
    pop rbx
.cell:
    mov eax, [rbx + LN_BLK]
    call in_sel
    jnc .next
    mov edi, [rbx + LN_X0]
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov edx, [rbx + LN_W]
    mov ecx, [rbx + LN_H]
    mov r8d, C_ACCENT
    mov r9d, 60
    call blend_rect
.next:
    add rbx, LN_SIZE
    dec r12d
    jmp .line
.out:
    pop r12
    pop rbx
    ret

; img_draw(RBX = an image, EDI = x, ESI = y, EDX = w, ECX = h): scaled
; there (each pixel the nearest), inside the clip
img_draw:
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov [rsp], edi                      ; [rsp]: x, +4 y, +8 w, +12 h
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    test edx, edx
    jle .out
    test ecx, ecx
    jle .out
    mov r12d, esi                       ; R12D: the row, in the window
    cmp r12d, [clip_y0]
    jge .row
    mov r12d, [clip_y0]
.row:
    mov eax, [rsp + 4]
    add eax, [rsp + 12]
    cmp r12d, eax
    jge .out
    cmp r12d, [clip_y1]
    jge .out
    mov eax, r12d                       ; R14: the image's row
    sub eax, [rsp + 4]
    imul eax, [rbx + IM_H]
    xor edx, edx
    div dword [rsp + 12]
    imul eax, [rbx + IM_W]
    lea r14, [rbx + IM_PX + rax * 4]
    mov eax, r12d                       ; R15: the window's row
    imul eax, [px_stride]
    mov r15, [px_base]
    lea r15, [r15 + rax * 4]
    mov r13d, [rsp]                     ; R13D: the column
    cmp r13d, [clip_x0]
    jge .col
    mov r13d, [clip_x0]
.col:
    mov eax, [rsp]
    add eax, [rsp + 8]
    cmp r13d, eax
    jge .row_done
    cmp r13d, [clip_x1]
    jge .row_done
    mov eax, r13d
    sub eax, [rsp]
    imul eax, [rbx + IM_W]
    xor edx, edx
    div dword [rsp + 8]
    mov eax, [r14 + rax * 4]
    mov [r15 + r13 * 4], eax
    inc r13d
    jmp .col
.row_done:
    inc r12d
    jmp .row
.out:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    ret

; paint_cursor: the caret, or a ring round the cell or image the cursor is
; on
paint_cursor:
    push rbx
    push r12
    cmp byte [ed_on], 0
    jne .editing
    call sel_any
    jne .out
    call cursor_line
    test rax, rax
    jz .out
    mov rbx, rax
    cmp dword [rbx + LN_KIND], LK_TEXT
    jne .ring
    call cursor_xy
    test rdx, rdx
    jz .out
    mov edi, eax
    jmp .caret
.editing:
    call cursor_line
    test rax, rax
    jz .out
    mov rbx, rax
    cmp dword [rbx + LN_BLK], EDIT_BLK
    jne .ring
    lea rdi, [ed_blk]
    xor esi, esi
    mov edx, [ed_off]
    mov ecx, [rbx + LN_FONT]
    call measure
    add eax, 32
    sar eax, 6
    add eax, [rbx + LN_X]
    mov edi, eax
    push rdi
    call .cell_ring
    pop rdi
.caret:
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov eax, [rbx + LN_H]               ; most of the line's height
    mov ecx, eax
    shr eax, 3
    add esi, eax
    sub ecx, eax
    sub ecx, eax
    mov edx, 2
    dec edi
    mov r8d, C_INK
    call fill_rect
    jmp .out
.ring:
    call .cell_ring
.out:
    pop r12
    pop rbx
    ret
.cell_ring:                             ; RBX: a cell's or an image's line
    mov edi, [rbx + LN_X0]
    add edi, [vw_ox]
    mov esi, [rbx + LN_Y]
    add esi, [vw_oy]
    mov edx, [rbx + LN_W]
    mov ecx, [rbx + LN_H]
    mov r8d, C_ACCENT
    jmp ring2

; ring2(EDI, ESI, EDX, ECX, R8D = colour): an edge two pixels wide, just
; inside the box. Preserves RBX, RBP, R12-R15.
ring2:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, ecx
    mov ecx, 2                          ; top
    call fill_rect
    mov edi, r12d                       ; bottom
    lea esi, [r13 + rbx - 2]
    mov edx, r14d
    mov ecx, 2
    call fill_rect
    mov edi, r12d                       ; left
    mov esi, r13d
    mov edx, 2
    mov ecx, ebx
    call fill_rect
    lea edi, [r12 + r14 - 2]            ; right
    mov esi, r13d
    mov edx, 2
    mov ecx, ebx
    call fill_rect
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- slides --------------------------------------------------------------------------

paint_slides:
    push rbx
    push r12
    push r13
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, WIN_H - ST_H
    call clip
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_H
    mov r8d, C_WINDOW
    call fill_rect
    mov edi, 0                          ; the sidebar
    mov esi, VIEW_Y
    mov edx, SIDE_W
    mov ecx, VIEW_H
    mov r8d, C_SIDEBAR
    call fill_rect
    mov edi, SIDE_W - 1
    mov esi, VIEW_Y
    mov edx, 1
    mov ecx, VIEW_H
    mov r8d, C_HAIRLINE
    call fill_rect
    cmp byte [vw_follow], 0
    je .no_follow
    call side_follow
    jmp .followed
.no_follow:
    call side_follow.clamp
.followed:
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, SIDE_W - 1
    mov ecx, WIN_H - ST_H
    call clip
    xor ebx, ebx                        ; each thumbnail
.thumb:
    cmp ebx, [sl_n]
    jae .thumbs_done
    mov r12d, ebx                       ; R12D: its top
    imul r12d, r12d, TH_ITEM
    add r12d, VIEW_Y + 14
    sub r12d, [side_scroll]
    lea eax, [r12 + TH_ITEM]
    cmp eax, VIEW_Y
    jl .thumb_next
    cmp r12d, WIN_H - ST_H
    jge .thumbs_done
    cmp ebx, [vw_slide]                 ; the one shown: ringed in the accent
    jne .plain
    mov edi, TH_X - 4
    lea esi, [r12 - 4]
    mov edx, TH_W + 8
    mov ecx, TH_H + 8
    mov r8d, 7
    mov r9d, C_SLIDE_RING
    call fill_round
    jmp .picture
.plain:
    mov edi, TH_X
    mov esi, r12d
    mov edx, TH_W
    mov ecx, TH_H
    call ring_shadow
.picture:
    mov edi, ebx
    mov esi, TH_X
    mov edx, r12d
    call thumb_draw
    call sb_reset                       ; its number
    lea eax, [rbx + 1]
    call sb_num
    lea eax, [r12 + 10]
    mov [ui_mid], eax
    mov edi, TH_X - 20
    mov r8d, UI_SMALL
    mov r9d, C_SECOND
    cmp ebx, [vw_slide]
    jne .number
    mov r9d, C_ACCENT_DK
.number:
    call sb_label
.thumb_next:
    inc ebx
    jmp .thumb
.thumbs_done:
    mov edi, SIDE_W
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, WIN_H - ST_H
    call clip
    cmp dword [vw_slide], -1
    je .empty
    mov edi, SLIDE_X
    mov esi, SLIDE_Y
    mov edx, SL_W
    mov ecx, SL_H
    call ring_shadow
    mov edi, SLIDE_X
    mov esi, SLIDE_Y
    mov edx, SL_W
    mov ecx, SL_H
    mov r8d, C_PAPER
    call fill_rect
    mov edi, SLIDE_X
    mov esi, SLIDE_Y
    mov edx, SLIDE_X + SL_W
    mov ecx, SLIDE_Y + SL_H
    call clip
    call paint_sel
    mov edi, 0
    mov esi, 0
    call draw_list
    call paint_images
    call paint_cursor
    jmp .out
.empty:
    mov dword [ui_mid], SLIDE_Y + SL_H / 2 - 14
    lea rsi, [s_no_slides]
    call cstr
    mov edi, SLIDE_X + SL_W / 2
    mov r8d, UI_BOLD
    mov r9d, C_SECOND
    call label_c
    mov dword [ui_mid], SLIDE_Y + SL_H / 2 + 14
    lea rsi, [s_no_slides2]
    call cstr
    mov edi, SLIDE_X + SL_W / 2
    mov r8d, UI_FONT
    mov r9d, C_FAINT
    call label_c
.out:
    pop r13
    pop r12
    pop rbx
    ret

; cstr(RSI = NUL-ended) -> ECX = its length. Preserves all but RCX.
cstr:
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .out
    inc ecx
    jmp .len
.out:
    ret

; side_follow: the sidebar scrolled so the slide shown is in it
side_follow:
    mov eax, [vw_slide]
    cmp eax, -1
    je .clamp
    imul eax, eax, TH_ITEM
    cmp eax, [side_scroll]
    jge .below
    mov [side_scroll], eax
    jmp .clamp
.below:
    add eax, TH_ITEM + 28
    sub eax, VIEW_H
    cmp eax, [side_scroll]
    jle .clamp
    mov [side_scroll], eax
.clamp:
    mov eax, [sl_n]
    imul eax, eax, TH_ITEM
    add eax, 28
    sub eax, VIEW_H
    jns .max
    xor eax, eax
.max:
    cmp [side_scroll], eax
    jle .min
    mov [side_scroll], eax
.min:
    cmp dword [side_scroll], 0
    jge .out
    mov dword [side_scroll], 0
.out:
    ret

; slide_render(EDI = a slide): painted whole into off_px, at (0, 0). The
; layout is then that slide's.
slide_render:
    push rbx
    mov ebx, edi
    mov rdi, [off_px]
    mov esi, SL_W
    mov edx, SL_W
    mov ecx, SL_H
    call target
    xor edi, edi
    xor esi, esi
    mov edx, SL_W
    mov ecx, SL_H
    mov r8d, C_PAPER
    call fill_rect
    mov edi, ebx
    xor esi, esi
    xor edx, edx
    call layout_slide
    xor edi, edi
    xor esi, esi
    call draw_list
    push qword [vw_ox]
    mov dword [vw_ox], 0
    mov dword [vw_oy], 0
    call paint_images_plain
    pop qword [vw_ox]
    pop rbx
    ret

; paint_images_plain: paint_images, nothing tinted
paint_images_plain:
    push qword [cur_blk]                ; (with cur_off)
    push qword [anc_blk]                ; (with anc_off)
    mov rax, [cur_blk]
    mov [anc_blk], rax
    call paint_images
    pop qword [anc_blk]
    pop qword [cur_blk]
    ret

; thumbs_update: the thumbnails painted again if the document has changed
; (all of them if the slides have, else the one the cursor is on)
thumbs_update:
    push rbx
    mov eax, [doc_gen]
    cmp eax, [thumb_gen]
    jne .changed
    mov eax, [sl_n]
    cmp eax, [thumb_n]
    je .out
.changed:
    mov eax, [doc_gen]
    mov [thumb_gen], eax
    mov eax, [sl_n]
    cmp eax, [thumb_n]
    jne .all
    cmp byte [thumbs_all], 0
    jne .all
    mov edi, [cur_blk]                  ; the cursor's slide only
    call slide_of
    cmp eax, -1
    je .out
    mov edi, eax
    call thumb_make
    jmp .out
.all:
    mov byte [thumbs_all], 0
    mov eax, [sl_n]
    mov [thumb_n], eax
    xor ebx, ebx
.each:
    cmp ebx, [sl_n]
    jae .out
    cmp ebx, TH_MAX
    jae .out
    mov edi, ebx
    call thumb_make
    inc ebx
    jmp .each
.out:
    pop rbx
    ret

; thumb_make(EDI = a slide): rendered, then each 5 by 5 pixels averaged
; into its thumbnail
thumb_make:
    cmp edi, TH_MAX
    jae .none
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    call slide_render
    mov eax, ebx
    imul eax, eax, TH_BYTES
    mov r12, [th_px]
    add r12, rax                        ; R12: the thumbnail
    xor r13d, r13d                      ; R13D: its row
.row:
    cmp r13d, TH_H
    jae .done
    xor r14d, r14d                      ; R14D: its column
.col:
    cmp r14d, TH_W
    jae .row_next
    mov eax, r13d                       ; RSI: the 5 by 5 square's first
    imul eax, eax, 5 * SL_W
    lea eax, [rax + r14 * 4]
    add eax, r14d                       ; (+ column * 5)
    mov rsi, [off_px]
    lea rsi, [rsi + rax * 4]
    xor r8d, r8d                        ; R8D, R9D, R10D: blue, green, red
    xor r9d, r9d
    xor r10d, r10d
    mov ecx, 5
.sq_row:
    mov edx, 5
    mov rdi, rsi
.sq_col:
    movzx eax, byte [rdi]
    add r8d, eax
    movzx eax, byte [rdi + 1]
    add r9d, eax
    movzx eax, byte [rdi + 2]
    add r10d, eax
    add rdi, 4
    dec edx
    jnz .sq_col
    add rsi, SL_W * 4
    dec ecx
    jnz .sq_row
    mov ecx, 25
    mov eax, r10d
    xor edx, edx
    div ecx
    mov r15d, eax
    shl r15d, 16
    mov eax, r9d
    xor edx, edx
    div ecx
    shl eax, 8
    or r15d, eax
    mov eax, r8d
    xor edx, edx
    div ecx
    or r15d, eax
    mov eax, r13d
    imul eax, eax, TH_W
    add eax, r14d
    mov [r12 + rax * 4], r15d
    inc r14d
    jmp .col
.row_next:
    inc r13d
    jmp .row
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.none:
    ret

; thumb_draw(EDI = a slide, ESI = x, EDX = y): its thumbnail there (white,
; past those kept)
thumb_draw:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, esi
    mov r13d, edx
    cmp edi, TH_MAX
    jb .kept
    mov edi, r12d
    mov esi, r13d
    mov edx, TH_W
    mov ecx, TH_H
    mov r8d, C_PAPER
    call fill_rect
    jmp .out
.kept:
    imul edi, edi, TH_BYTES
    mov rbx, [th_px]
    add rbx, rdi
    xor r14d, r14d                      ; R14D: the row
.row:
    cmp r14d, TH_H
    jae .out
    lea edx, [r13 + r14]
    cmp edx, [clip_y0]
    jl .next
    cmp edx, [clip_y1]
    jge .out
    imul edx, [px_stride]
    add edx, r12d
    mov rdi, [px_base]
    lea rdi, [rdi + rdx * 4]
    mov eax, r14d
    imul eax, eax, TH_W * 4
    lea rsi, [rbx + rax]
    mov ecx, TH_W
    rep movsd
.next:
    inc r14d
    jmp .row
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- the grid ------------------------------------------------------------------------

; grid_shown -> RAX = the grid the view shows (the cursor's), RBX kept; 0
; if the cursor is on none
grid_shown:
    call cur_ptr
    cmp byte [rax + BL_KIND], BK_GRID
    jne .none
    mov rax, [rax + BL_DATA]
    ret
.none:
    xor eax, eax
    ret

; grid_scroll: the first row and column shown, so the cursor's cell shows
grid_scroll:
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx                             ; EAX: the row; EDX: the column
    cmp eax, [gv_row0]
    jge .row_below
    mov [gv_row0], eax
.row_below:
    lea ecx, [rax - GV_ROWS + 2]
    cmp ecx, [gv_row0]
    jle .col
    mov [gv_row0], ecx
.col:
    cmp edx, [gv_col0]
    jge .col_right
    mov [gv_col0], edx
.col_right:
    lea ecx, [rdx - GV_COLS + 2]
    cmp ecx, [gv_col0]
    jle .out
    mov [gv_col0], ecx
.out:
    ret

paint_grid:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 40
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, WIN_H - ST_H
    call clip
    mov edi, 0
    mov esi, VIEW_Y
    mov edx, WIN_W
    mov ecx, VIEW_H
    mov r8d, C_PAPER
    call fill_rect
    call grid_shown
    test rax, rax
    jz .empty
    mov rbx, rax                        ; RBX: the grid
    cmp byte [vw_follow], 0
    je .scrolled
    call grid_scroll
.scrolled:
    ; the formula bar: the cell's name, then what was typed in it
    mov edi, 0
    mov esi, GV_TOP - 1
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_HAIRLINE
    call fill_rect
    PUT_C [ui_fill], C_PAPER
    mov edi, 12
    mov esi, VIEW_Y + 7
    mov edx, 72
    mov ecx, 30
    mov r8d, 6
    mov r9d, C_BUTTON_EDGE
    call frame_round
    call sb_reset
    mov eax, [cur_off]
    call sb_cell
    mov dword [ui_mid], VIEW_Y + 22
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    mov edi, 48
    mov r8d, UI_BOLD
    mov r9d, C_INK
    call label_c
    lea rsi, [s_fx]
    mov ecx, 2
    mov edi, 98
    mov r8d, WF_ITALIC * WF_SIZES + WF_PX16
    mov r9d, C_FAINT
    call label
    PUT_C [ui_fill], C_PAPER
    mov edi, 124
    mov esi, VIEW_Y + 7
    mov edx, WIN_W - 136
    mov ecx, 30
    mov r8d, 6
    mov r9d, C_BUTTON_EDGE
    cmp byte [ed_on], 0
    je .bar
    mov r9d, C_ACCENT
.bar:
    call frame_round
    mov edi, 124
    mov esi, VIEW_Y
    mov edx, WIN_W - 16
    mov ecx, GV_TOP - 1
    call clip
    cmp byte [ed_on], 0
    jne .bar_edit
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    mov rdi, rbx
    mov esi, eax
    call cell_at
    mov rsi, [rax + CE_TEXT]
    mov ecx, [rax + CE_LEN]
    mov edi, 136
    mov r8d, UI_FONT
    mov r9d, C_INK
    call label
    jmp .bar_done
.bar_edit:                              ; what is being typed, and the caret
    mov rsi, [ed_blk + BL_TEXT]
    mov ecx, [ed_off]
    mov edx, UI_FONT
    call text_px
    mov [rsp + 32], eax
    mov rsi, [ed_blk + BL_TEXT]
    mov ecx, [ed_blk + BL_LEN]
    mov edi, 136
    mov r8d, UI_FONT
    mov r9d, C_INK
    call label
    mov edi, [rsp + 32]
    add edi, 135
    mov esi, VIEW_Y + 12
    mov edx, 2
    mov ecx, 20
    mov r8d, C_INK
    call fill_rect
.bar_done:
    mov edi, 0
    mov esi, GV_TOP
    mov edx, WIN_W
    mov ecx, GV_BOTTOM
    call clip
    ; the column letters and the row numbers
    mov edi, 0
    mov esi, GV_TOP
    mov edx, WIN_W
    mov ecx, GV_ROW_H
    mov r8d, C_GRID_HEAD
    call fill_rect
    mov edi, 0
    mov esi, GV_TOP
    mov edx, GV_HEAD_W
    mov ecx, GV_BOTTOM - GV_TOP
    mov r8d, C_GRID_HEAD
    call fill_rect
    mov eax, [cur_off]                  ; [rsp+24], [rsp+28]: the cursor's
    xor edx, edx                        ; row and column
    mov ecx, MAXC
    div ecx
    mov [rsp + 24], eax
    mov [rsp + 28], edx
    xor r12d, r12d                      ; R12D: a column shown
.letters:
    cmp r12d, GV_COLS
    jae .letters_done
    mov eax, r12d
    add eax, [gv_col0]
    cmp eax, MAXC
    jae .letters_done
    mov r13d, eax
    mov edi, r12d                       ; its line
    imul edi, edi, GV_COL_W
    add edi, GV_HEAD_W + GV_COL_W - 1
    mov esi, GV_TOP
    mov edx, 1
    mov ecx, GV_BOTTOM - GV_TOP
    mov r8d, C_GRID_LINE
    call fill_rect
    cmp r13d, [rsp + 28]                ; the cursor's: marked
    jne .letter
    mov edi, r12d
    imul edi, edi, GV_COL_W
    add edi, GV_HEAD_W
    mov esi, GV_TOP
    mov edx, GV_COL_W - 1
    mov ecx, GV_ROW_H
    mov r8d, C_BUTTON_ON
    call fill_rect
.letter:
    lea eax, [r13 + 'A']
    mov [sb_buf], al
    mov dword [ui_mid], GV_TOP + GV_ROW_H / 2
    lea rsi, [sb_buf]
    mov ecx, 1
    mov edi, r12d
    imul edi, edi, GV_COL_W
    add edi, GV_HEAD_W + GV_COL_W / 2
    mov r8d, UI_SMALL
    mov r9d, C_SECOND
    call label_c
    inc r12d
    jmp .letters
.letters_done:
    xor r12d, r12d                      ; R12D: a row shown
.numbers:
    cmp r12d, GV_ROWS
    jae .numbers_done
    mov eax, r12d
    add eax, [gv_row0]
    cmp eax, MAXR
    jae .numbers_done
    mov r13d, eax
    mov esi, r12d                       ; its line
    imul esi, esi, GV_ROW_H
    add esi, GV_CELLS_Y + GV_ROW_H - 1
    mov edi, 0
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_GRID_LINE
    call fill_rect
    cmp r13d, [rsp + 24]
    jne .number
    mov esi, r12d
    imul esi, esi, GV_ROW_H
    add esi, GV_CELLS_Y
    mov edi, 0
    mov edx, GV_HEAD_W - 1
    mov ecx, GV_ROW_H - 1
    mov r8d, C_BUTTON_ON
    call fill_rect
.number:
    call sb_reset
    lea eax, [r13 + 1]
    call sb_num
    mov eax, r12d
    imul eax, eax, GV_ROW_H
    add eax, GV_CELLS_Y + GV_ROW_H / 2
    mov [ui_mid], eax
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    mov edi, GV_HEAD_W / 2
    mov r8d, UI_SMALL
    mov r9d, C_SECOND
    call label_c
    inc r12d
    jmp .numbers
.numbers_done:
    mov edi, 0
    mov esi, GV_CELLS_Y - 1
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_HAIRLINE
    call fill_rect
    mov edi, GV_HEAD_W - 1
    mov esi, GV_TOP
    mov edx, 1
    mov ecx, GV_BOTTOM - GV_TOP
    mov r8d, C_HAIRLINE
    call fill_rect
    ; the cells
    mov edi, GV_HEAD_W
    mov esi, GV_CELLS_Y
    mov edx, WIN_W
    mov ecx, GV_BOTTOM
    call clip
    xor r12d, r12d                      ; R12D: the row shown
.cell_row:
    cmp r12d, GV_ROWS
    jae .cells_done
    mov eax, r12d
    add eax, [gv_row0]
    cmp eax, MAXR
    jae .cells_done
    xor r13d, r13d                      ; R13D: the column shown
.cell_col:
    cmp r13d, GV_COLS
    jae .cell_row_next
    mov edx, r13d
    add edx, [gv_col0]
    cmp edx, MAXC
    jae .cell_row_next
    mov esi, r12d
    add esi, [gv_row0]
    mov [rsp + 16], esi                 ; [rsp+16], [rsp+20]: its row, column
    mov [rsp + 20], edx
    mov rdi, rbx
    call cell_at
    mov r14, rax                        ; R14: the cell
    mov ebp, r13d                       ; EBP: its x; R15D: its y
    imul ebp, ebp, GV_COL_W
    add ebp, GV_HEAD_W
    mov r15d, r12d
    imul r15d, r15d, GV_ROW_H
    add r15d, GV_CELLS_Y
    mov eax, [rsp + 16]                 ; the one being typed into: what is typed
    cmp eax, [rsp + 24]
    jne .value
    mov eax, [rsp + 20]
    cmp eax, [rsp + 28]
    jne .value
    cmp byte [ed_on], 0
    je .value
    mov rsi, [ed_blk + BL_TEXT]
    mov ecx, [ed_blk + BL_LEN]
    xor eax, eax
    jmp .show
.value:
    cmp dword [r14 + CE_LEN], 0
    je .cell_next
    mov rdi, r14
    lea rsi, [gv_buf]
    call cell_show
.show:
    mov [rsp + 8], eax                  ; [rsp+8]: right-aligned
    mov [rsp], rsi
    mov [rsp + 12], ecx
    mov edi, ebp
    mov esi, r15d
    lea edx, [rbp + GV_COL_W - 1]
    lea ecx, [r15 + GV_ROW_H - 1]
    cmp edx, WIN_W
    jle .clip_x
    mov edx, WIN_W
.clip_x:
    cmp ecx, GV_BOTTOM
    jle .clip_y
    mov ecx, GV_BOTTOM
.clip_y:
    cmp edi, GV_HEAD_W
    jge .clip_set
    mov edi, GV_HEAD_W
.clip_set:
    call clip
    lea eax, [r15 + GV_ROW_H / 2]
    mov [ui_mid], eax
    mov r9d, C_INK
    cmp byte [r14 + CE_KIND], VK_ERR
    jne .ink
    mov r9d, C_ERROR
.ink:
    lea edi, [rbp + 6]
    cmp dword [rsp + 8], 0
    je .left
    mov rsi, [rsp]
    mov ecx, [rsp + 12]
    mov edx, UI_FONT
    call text_px
    lea edi, [rbp + GV_COL_W - 7]
    sub edi, eax
.left:
    mov rsi, [rsp]
    mov ecx, [rsp + 12]
    mov r8d, UI_FONT
    mov r9d, C_INK
    cmp byte [r14 + CE_KIND], VK_ERR
    jne .draw_cell
    mov r9d, C_ERROR
.draw_cell:
    call label
    mov edi, GV_HEAD_W
    mov esi, GV_CELLS_Y
    mov edx, WIN_W
    mov ecx, GV_BOTTOM
    call clip
.cell_next:
    inc r13d
    jmp .cell_col
.cell_row_next:
    inc r12d
    jmp .cell_row
.cells_done:
    mov eax, [rsp + 24]                 ; the cursor's cell: ringed
    sub eax, [gv_row0]
    js .tabs
    cmp eax, GV_ROWS
    jae .tabs
    mov ecx, [rsp + 28]
    sub ecx, [gv_col0]
    js .tabs
    cmp ecx, GV_COLS
    jae .tabs
    imul esi, eax, GV_ROW_H
    add esi, GV_CELLS_Y - 1
    imul edi, ecx, GV_COL_W
    add edi, GV_HEAD_W - 1
    mov edx, GV_COL_W + 1
    mov ecx, GV_ROW_H + 1
    mov r8d, C_ACCENT
    call ring2
.tabs:
    call paint_tabs
    jmp .out
.empty:
    mov dword [ui_mid], VIEW_Y + VIEW_H / 2 - 14
    lea rsi, [s_no_grid]
    call cstr
    mov edi, WIN_W / 2
    mov r8d, UI_BOLD
    mov r9d, C_SECOND
    call label_c
    mov dword [ui_mid], VIEW_Y + VIEW_H / 2 + 14
    lea rsi, [s_no_grid2]
    call cstr
    mov edi, WIN_W / 2
    mov r8d, UI_FONT
    mov r9d, C_FAINT
    call label_c
    call paint_tabs
.out:
    add rsp, 40
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; paint_tabs: a tab for each grid in the document, under the cells; the
; cursor's lit. gv_tabs: where each is, for the mouse.
paint_tabs:
    push rbx
    push r12
    push r13
    mov edi, 0
    mov esi, GV_BOTTOM
    mov edx, WIN_W
    mov ecx, WIN_H - ST_H
    call clip
    mov edi, 0
    mov esi, GV_BOTTOM
    mov edx, WIN_W
    mov ecx, GV_TAB_H
    mov r8d, C_CHROME
    call fill_rect
    mov edi, 0
    mov esi, GV_BOTTOM
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_HAIRLINE
    call fill_rect
    mov dword [gv_ntabs], 0
    mov r12d, 12                        ; R12D: the next tab's x
    xor ebx, ebx
.block:
    cmp ebx, [nblocks]
    jae .out
    cmp dword [gv_ntabs], GV_TABS_MAX
    jae .out
    mov edi, ebx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    jne .next
    mov r13, rax
    mov rsi, [r13 + BL_TEXT]            ; its name, or "Grid"
    mov ecx, [r13 + BL_LEN]
    test ecx, ecx
    jnz .named
    lea rsi, [s_grid]
    mov ecx, 4
.named:
    push rsi
    push rcx
    mov edx, UI_FONT
    call text_px
    add eax, 28
    mov r13d, eax                       ; R13D: its width
    mov ecx, [gv_ntabs]
    mov [gv_tabs + rcx * 8], r12d
    mov [gv_tabs + rcx * 8 + 4], ebx
    inc dword [gv_ntabs]
    cmp ebx, [cur_blk]
    jne .plain
    PUT_C [ui_fill], C_BUTTON
    mov edi, r12d
    mov esi, GV_BOTTOM + 5
    mov edx, r13d
    mov ecx, GV_TAB_H - 10
    mov r8d, 6
    mov r9d, C_BUTTON_EDGE
    call frame_round
.plain:
    pop rcx
    pop rsi
    mov dword [ui_mid], GV_BOTTOM + GV_TAB_H / 2
    lea edi, [r12 + 14]
    mov r8d, UI_FONT
    mov r9d, C_SECOND
    cmp ebx, [cur_blk]
    jne .label
    mov r8d, UI_BOLD
    mov r9d, C_INK
.label:
    call label
    lea r12d, [r12 + r13 + 6]
    mov ecx, [gv_ntabs]
    mov [gv_tabs + rcx * 8], r12d       ; (the end of the last)
.next:
    inc ebx
    jmp .block
.out:
    pop r13
    pop r12
    pop rbx
    ret

; --- the toolbar and the status line ------------------------------------------------

paint_toolbar:
    push rbx
    push r12
    call target_win
    mov edi, 0
    mov esi, 0
    mov edx, WIN_W
    mov ecx, TB_H - 1
    mov r8d, C_CHROME
    call fill_rect
    mov edi, 0
    mov esi, TB_H - 1
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_HAIRLINE
    call fill_rect
    mov edi, SEG_X                      ; the views: one control of three
    mov esi, SEG_Y
    mov edx, SEG_W * 3 + 4
    mov ecx, SEG_H
    mov r8d, 8
    mov r9d, C_SEG_TRACK
    call fill_round
    mov edi, [view]
    imul edi, edi, SEG_W
    add edi, SEG_X + 2
    mov esi, SEG_Y + 2
    mov edx, SEG_W
    mov ecx, SEG_H - 4
    mov r8d, 7
    mov r9d, C_BUTTON_EDGE
    PUT_C [ui_fill], C_BUTTON
    call frame_round
    xor ebx, ebx
.seg:
    cmp ebx, 3
    jae .buttons
    mov dword [ui_mid], SEG_Y + SEG_H / 2
    lea rax, [seg_labels]
    mov rsi, [rax + rbx * 8]
    call cstr
    mov edi, ebx
    imul edi, edi, SEG_W
    add edi, SEG_X + 2 + SEG_W / 2
    mov r8d, UI_FONT
    mov r9d, C_SECOND
    cmp ebx, [view]
    jne .seg_label
    mov r8d, UI_BOLD
    mov r9d, C_INK
.seg_label:
    call label_c
    inc ebx
    jmp .seg
.buttons:
    lea rbx, [buttons]
.button:
    cmp byte [rbx + BT_ACT], 0
    je .out
    mov ecx, [view]
    mov eax, 1
    shl eax, cl
    test [rbx + BT_VIEWS], al
    jz .next
    movzx edi, byte [rbx + BT_ACT]
    call act_on
    mov esi, eax
    xor edx, edx
    movzx eax, byte [rbx + BT_ACT]
    cmp eax, [pressed_act]
    jne .draw
    mov edx, 1
.draw:
    mov rdi, rbx
    call button
.next:
    add rbx, BT_SIZE
    jmp .button
.out:
    pop r12
    pop rbx
    ret

paint_status:
    push rbx
    call target_win
    mov edi, 0
    mov esi, WIN_H - ST_H
    mov edx, WIN_W
    mov ecx, ST_H
    mov r8d, C_CHROME
    call fill_rect
    mov edi, 0
    mov esi, WIN_H - ST_H
    mov edx, WIN_W
    mov ecx, 1
    mov r8d, C_HAIRLINE
    call fill_rect
    mov dword [ui_mid], WIN_H - ST_H / 2
    call sb_reset                       ; where the cursor is
    mov eax, [view]
    cmp eax, V_PAGES
    je .pages
    cmp eax, V_SLIDES
    je .slides
    call cur_kind
    cmp eax, BK_GRID
    jne .where
    call cur_ptr
    mov rsi, [rax + BL_TEXT]
    mov ecx, [rax + BL_LEN]
    call sb_mem
    lea rsi, [s_dot]
    call sb_str
    mov eax, [cur_off]
    call sb_cell
    jmp .where
.pages:
    lea rsi, [s_page]
    call sb_str
    call cursor_line
    mov ecx, 1
    test rax, rax
    jz .page_n
    mov eax, [rax + LN_Y]
    xor edx, edx
    mov ecx, PG_H + PG_GAP
    div ecx
    lea ecx, [rax + 1]
.page_n:
    mov eax, ecx
    call sb_num
    lea rsi, [s_of]
    call sb_str
    mov eax, [pg_count]
    call sb_num
    lea rsi, [s_dot]
    call sb_str
    call word_count
    call sb_num
    lea rsi, [s_words]
    call sb_str
    jmp .where
.slides:
    cmp dword [vw_slide], -1
    je .where
    lea rsi, [s_slide]
    call sb_str
    mov eax, [vw_slide]
    inc eax
    call sb_num
    lea rsi, [s_of]
    call sb_str
    mov eax, [sl_n]
    call sb_num
.where:
    mov edi, 16
    mov r8d, UI_SMALL
    mov r9d, C_SECOND
    call sb_label
    cmp byte [st_msg], 0                ; a message, in the middle
    je .name
    lea rsi, [st_msg]
    call cstr
    mov edi, WIN_W / 2
    mov r8d, UI_SMALL
    mov r9d, C_INK
    call label_c
.name:
    call sb_reset                       ; the document's name, and if it is saved
    lea rsi, [doc_name]
    call sb_str
    lea rsi, [s_saved]
    cmp byte [modified], 0
    je .state
    lea rsi, [s_edited]
.state:
    call sb_str
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    mov edx, UI_SMALL
    call text_px
    mov edi, WIN_W - 16
    sub edi, eax
    mov r8d, UI_SMALL
    mov r9d, C_SECOND
    call sb_label
    pop rbx
    ret

; word_count -> EAX = the words in the document's text
word_count:
    push rbx
    push r12
    push r13
    xor r12d, r12d                      ; R12D: words
    xor ebx, ebx
.block:
    cmp ebx, [nblocks]
    jae .out
    mov edi, ebx
    call blk_texty
    jz .next
    call blk_at
    cmp byte [rax + BL_KIND], BK_PARA   ; (not a frame's title: it is a slide's)
    mov rsi, [rax + BL_TEXT]
    mov ecx, [rax + BL_LEN]
    xor r13d, r13d                      ; R13D: inside a word
.char:
    test ecx, ecx
    jz .next
    movzx eax, byte [rsi]
    cmp eax, ' '
    jbe .gap
    test r13d, r13d
    jnz .on
    inc r12d
    mov r13d, 1
    jmp .on
.gap:
    xor r13d, r13d
.on:
    inc rsi
    dec ecx
    jmp .char
.next:
    inc ebx
    jmp .block
.out:
    mov eax, r12d
    pop r13
    pop r12
    pop rbx
    ret

; --- presenting ------------------------------------------------------------------------

pres_paint:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56
    mov [rsp], rdi                      ; [rsp]: the pixels; +8 w, +12 h
    mov [rsp + 8], esi
    mov [rsp + 12], edx
    mov rdi, [rsp]                      ; black, all of it
    mov esi, [rsp + 8]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call target
    xor edi, edi
    xor esi, esi
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    mov r8d, C_BLACK
    call fill_rect
    call slides_build
    mov edi, [pres_slide]
    cmp edi, [sl_n]
    jae .out
    call slide_render
    ; as large as fits, 16:9: [rsp+16] x0, +20 y0, +24 w, +28 h
    mov eax, [rsp + 8]
    imul eax, eax, 9
    mov ecx, [rsp + 12]
    imul ecx, ecx, 16
    cmp eax, ecx
    jbe .wide
    mov eax, [rsp + 12]                 ; the height decides
    mov [rsp + 28], eax
    imul eax, eax, 16
    xor edx, edx
    mov ecx, 9
    div ecx
    mov [rsp + 24], eax
    jmp .placed
.wide:
    mov eax, [rsp + 8]
    mov [rsp + 24], eax
    imul eax, eax, 9
    xor edx, edx
    mov ecx, 16
    div ecx
    mov [rsp + 28], eax
.placed:
    mov eax, [rsp + 8]
    sub eax, [rsp + 24]
    shr eax, 1
    mov [rsp + 16], eax
    mov eax, [rsp + 12]
    sub eax, [rsp + 28]
    shr eax, 1
    mov [rsp + 20], eax
    ; each pixel: the slide's four nearest, weighed (16.16)
    mov eax, SL_W << 16                 ; [rsp+32], [rsp+36]: steps
    xor edx, edx
    div dword [rsp + 24]
    mov [rsp + 32], eax
    mov eax, SL_H << 16
    xor edx, edx
    div dword [rsp + 28]
    mov [rsp + 36], eax
    xor r12d, r12d                      ; R12D: the row
.row:
    cmp r12d, [rsp + 28]
    jae .out
    mov eax, r12d                       ; R13D: y in the slide, 16.16
    imul eax, [rsp + 36]
    mov ecx, [rsp + 36]
    shr ecx, 1
    add eax, ecx
    sub eax, 0x8000
    jns .y_in
    xor eax, eax
.y_in:
    cmp eax, (SL_H - 1) << 16
    jb .y_ok
    mov eax, ((SL_H - 1) << 16) - 1
.y_ok:
    mov r13d, eax
    mov eax, r12d                       ; R15: the row's first pixel
    add eax, [rsp + 20]
    imul eax, [rsp + 8]
    add eax, [rsp + 16]
    mov r15, [rsp]
    lea r15, [r15 + rax * 4]
    mov eax, r13d                       ; RBP: the slide's row above
    shr eax, 16
    imul eax, eax, SL_W * 4
    mov rbp, [off_px]
    add rbp, rax
    xor r14d, r14d                      ; R14D: the column
.col:
    cmp r14d, [rsp + 24]
    jae .row_next
    mov eax, r14d
    imul eax, [rsp + 32]
    mov ecx, [rsp + 32]
    shr ecx, 1
    add eax, ecx
    sub eax, 0x8000
    jns .x_in
    xor eax, eax
.x_in:
    cmp eax, (SL_W - 1) << 16
    jb .x_ok
    mov eax, ((SL_W - 1) << 16) - 1
.x_ok:
    mov ebx, eax                        ; EBX: x, 16.16
    shr eax, 16
    lea rsi, [rbp + rax * 4]            ; RSI: the pixel above and left
    movzx r8d, bx                       ; R8D: the weight across, R9D: down
    shr r8d, 8
    movzx r9d, r13w
    shr r9d, 8
    xor r10d, r10d                      ; R10D: the colour
    mov ecx, 0                          ; each channel
.channel:
    movzx eax, byte [rsi + rcx]
    movzx edx, byte [rsi + rcx + 4]
    sub edx, eax
    imul edx, r8d
    sar edx, 8
    add eax, edx                        ; EAX: across the top
    movzx edx, byte [rsi + rcx + SL_W * 4]
    movzx r11d, byte [rsi + rcx + SL_W * 4 + 4]
    sub r11d, edx
    imul r11d, r8d
    sar r11d, 8
    add edx, r11d                       ; EDX: across the bottom
    sub edx, eax
    imul edx, r9d
    sar edx, 8
    add eax, edx
    shl ecx, 3
    shl eax, cl
    shr ecx, 3
    or r10d, eax
    inc ecx
    cmp ecx, 3
    jb .channel
    mov [r15 + r14 * 4], r10d
    inc r14d
    jmp .col
.row_next:
    inc r12d
    jmp .row
.out:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; --- a picture ---------------------------------------------------------------------------

picture:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                       ; R12D, R13D: its size
    mov r13d, esi
    mov eax, r12d
    imul eax, r13d
    lea edi, [rax * 4 + IM_PX]
    call da_alloc
    test rax, rax
    jz .out
    mov rbx, rax
    mov [rbx + IM_W], r12d
    mov [rbx + IM_H], r13d
    xor r15d, r15d                      ; R15D: y
.row:
    cmp r15d, r13d
    jae .done
    xor r14d, r14d                      ; R14D: x
.col:
    cmp r14d, r12d
    jae .row_next
    ; the far hill: its top at 52% down, falling away from 30% across; the
    ; near one at 66%, from 75% across (x in 1/10000 of the width)
    mov eax, r14d
    imul eax, eax, 10000
    xor edx, edx
    div r12d
    mov r10d, eax                       ; R10D: x, 0 to 9999
    imul r8d, r13d, 52
    mov eax, r8d
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r8d, eax                        ; R8D: the far hill's top
    lea eax, [r10 - 3000]
    imul eax, eax
    mov ecx, r13d
    imul rax, rcx
    shr rax, 15
    xor edx, edx
    mov ecx, 10000
    div rcx
    add r8d, eax
    imul r9d, r13d, 66
    mov eax, r9d
    xor edx, edx
    mov ecx, 100
    div ecx
    mov r9d, eax                        ; R9D: the near hill's top
    lea eax, [r10 - 7500]
    imul eax, eax
    mov ecx, r13d
    imul rax, rcx
    shr rax, 14
    xor edx, edx
    mov ecx, 10000
    div rcx
    add r9d, eax
    cmp r15d, r9d
    jae .near
    cmp r15d, r8d
    jae .far
    ; the sky: blue above, paler down, a sun at (72%, 26%)
    mov eax, r15d
    imul eax, eax, 120
    xor edx, edx
    div r13d                            ; EAX: 0..120 down
    mov ecx, 0x5A + 0
    add ecx, eax                        ; red
    mov edx, 0x9C
    add edx, eax
    shr eax, 1
    mov r10d, 0xE8
    add r10d, eax                       ; blue
    cmp ecx, 255
    jbe .r
    mov ecx, 255
.r:
    cmp edx, 255
    jbe .g
    mov edx, 255
.g:
    cmp r10d, 255
    jbe .b
    mov r10d, 255
.b:
    push rcx
    push rdx
    mov eax, r12d                       ; the sun: within 7% of the width
    imul eax, eax, 72
    xor edx, edx
    mov ecx, 100
    div ecx
    sub eax, r14d
    imul eax, eax
    mov r11d, eax
    mov eax, r13d
    imul eax, eax, 26
    xor edx, edx
    div ecx
    sub eax, r15d
    imul eax, eax
    add r11d, eax
    mov eax, r12d
    imul eax, eax, 7
    xor edx, edx
    div ecx
    imul eax, eax
    pop rdx
    pop rcx
    cmp r11d, eax
    ja .sky
    mov ecx, 0xFF
    mov edx, 0xD8
    mov r10d, 0x70
.sky:
    shl ecx, 16
    shl edx, 8
    or ecx, edx
    or ecx, r10d
    jmp .put
.far:
    mov ecx, 0x6FA86A
    jmp .put
.near:
    mov eax, r15d                       ; darker down
    sub eax, r9d
    shr eax, 2
    mov ecx, 0x4E
    sub ecx, eax
    jns .near_ok
    xor ecx, ecx
.near_ok:
    mov edx, 0x96
    sub edx, eax
    shl ecx, 16
    shl edx, 8
    or ecx, edx
    or ecx, 0x48
.put:
    mov eax, r15d
    imul eax, r12d
    add eax, r14d
    mov [rbx + IM_PX + rax * 4], ecx
    inc r14d
    jmp .col
.row_next:
    inc r15d
    jmp .row
.done:
    mov rax, rbx
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
s_no_slides:    db 'No slides yet', 0
s_no_slides2:   db 'Each Heading 1 begins one, or add one with + Slide', 0
s_no_grid:      db 'No grid here', 0
s_no_grid2:     db 'Add one with + Grid, or click a table on a page', 0
s_fx:           db 'fx'
s_grid:         db 'Grid'
s_dot:          db '  ', 0xC2, 0xB7, '  ', 0
s_page:         db 'Page ', 0
s_slide:        db 'Slide ', 0
s_of:           db ' of ', 0
s_words:        db ' words', 0
s_saved:        db '', 0
s_edited:       db '  ', 0xE2, 0x80, 0x94, '  Edited', 0

section .bss
alignb 8
win_px:         resq 1
off_px:         resq 1
th_px:          resq 1
SB_MAX          equ 240
sb_buf:         resb 256
gv_buf:         resb 32
GV_TABS_MAX     equ 32
gv_tabs:        resd 2 * (GV_TABS_MAX + 1)
gv_ntabs:       resd 1
sb_len:         resd 1
vw_ox:          resd 1
vw_oy:          resd 1
vw_slide:       resd 1
scroll_y:       resd 1
side_scroll:    resd 1
gv_row0:        resd 1
gv_col0:        resd 1
thumb_gen:      resd 1
thumb_n:        resd 1
pres_slide:     resd 1
ps_b0:          resd 1
ps_o0:          resd 1
ps_b1:          resd 1
ps_o1:          resd 1
vw_follow:      resb 1
thumbs_all:     resb 1

section .text
