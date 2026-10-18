; =============================================================================
;  compose/layout.inc - the blocks laid out: on pages, on a slide, in a
;  slide's frame on a page
;
;  What comes out is web/draw.inc's display list (dl_base to dl_top: text
;  runs and rectangles, drawn by draw_list) and the lines (ln_base, ln_n of
;  LN_*): where each line of each block is, and each cell, image and frame,
;  for the cursor, the mouse and what draw_list cannot draw.
;    layout_pages: the whole document on pages, in document coordinates
;      (x in the window, y from the top of the first page's gap);
;      pg_count pages, doc_h tall
;    slides_build: the slides (sl_*): each frame is one; outside frames,
;      each Heading 1 begins one, and what follows it until the next
;    layout_slide(EDI = a slide, ESI = x, EDX = y): it, at that size
;      (SL_W by SL_H), there
;    slide_of(EDI = a block) -> EAX = the slide it is on (the nearest, if
;      it is on none), or -1 if there are no slides
;    measure(RDI = a block, ESI = from, EDX = to, ECX = LN_FONT's) -> EAX =
;      the width of its text there, 1/64 pixels
;    line_find(EDI = a block, ESI = an offset or a cell) -> RAX = its LN_*,
;      or 0
;  Contexts (CTX_*) pick the sizes: a page's, a slide's, a frame's on a page
;  (two thirds of a slide).
; =============================================================================

WIN_W           equ 1360
WIN_H           equ 900
TB_H            equ 52                  ; the toolbar
ST_H            equ 28                  ; the status line
VIEW_Y          equ TB_H
VIEW_H          equ WIN_H - TB_H - ST_H
PG_W            equ 816                 ; a page: 8.5 by 11 inches at 96 dpi
PG_H            equ 1056
PG_M            equ 88                  ; its margins
PG_GAP          equ 32
PG_X            equ (WIN_W - PG_W) / 2
PG_TEXT         equ PG_W - 2 * PG_M
SIDE_W          equ 228                 ; the slides' sidebar
SL_W            equ 960                 ; a slide
SL_H            equ 540
SL_M            equ 64                  ; its margin
SLIDE_X         equ SIDE_W + (WIN_W - SIDE_W - SL_W) / 2
SLIDE_Y         equ VIEW_Y + (VIEW_H - SL_H) / 2
MINI_W          equ PG_TEXT             ; a frame on a page
MINI_H          equ MINI_W * 9 / 16
MINI_M          equ 40

CTX_PAGE        equ 0
CTX_SLIDE       equ 1
CTX_MINI        equ 2

; display list items: browse's (web/layout.inc), which draw_list draws
DI_KIND         equ 0
DI_FONT         equ 1
DI_FLAGS        equ 2
DI_LEN          equ 4
DI_X            equ 8
DI_Y            equ 12
DI_W            equ 16
DI_COLOR        equ 20
DI_TEXT         equ 24
DI_LINK         equ 32
DI_H            equ 36
DI_SIZE         equ 40
DK_TEXT         equ 1
DK_RECT         equ 2
DF_UNDER        equ 1
DF_PRE          equ 2
DF_STRIKE       equ 4
DL_BYTES        equ 16 << 20

LN_BLK          equ 0                   ; the block (EDIT_BLK: the cell being edited)
LN_START        equ 4                   ; its text, from
LN_END          equ 8                   ; and to
LN_X            equ 12                  ; where the text starts
LN_Y            equ 16                  ; the line's top
LN_H            equ 20
LN_BASE         equ 24                  ; the baseline
LN_CELL         equ 28                  ; a cell's index (row * MAXC + column), or -1
LN_FONT         equ 32                  ; byte: the size; byte: the face it adds
LN_X0           equ 36                  ; what it covers: from
LN_W            equ 40                  ; and how wide
LN_KIND         equ 44                  ; LK_*
LN_SIZE         equ 48
LN_MAX          equ 65536
LK_TEXT         equ 0
LK_CELL         equ 1
LK_BOX          equ 2                   ; an image, a frame
EDIT_BLK        equ -2

SL_TITLE        equ 0                   ; a slide: its title's block, or -1
SL_FIRST        equ 4                   ; the blocks on it
SL_END          equ 8
SL_FRAME        equ 12                  ; its frame, or -1
SL_SIZE         equ 16
SL_MAX          equ 1024
LT_BYTES        equ 1 << 20             ; numbers shown, while laid out

section .text

; lay_reset: no items, no lines
lay_reset:
    mov rax, [dl_base]
    mov [dl_top], rax
    mov dword [ln_n], 0
    mov rax, [lt_base]
    mov [lt_top], rax
    ret

; di_new -> RAX = the next item, zeroed, or 0 if the list is full.
; Preserves all but RAX.
di_new:
    push rcx
    push rdi
    mov rax, [dl_top]
    lea rcx, [rax + DI_SIZE]
    cmp rcx, [dl_end]
    ja .full
    mov [dl_top], rcx
    mov rdi, rax
    push rax
    xor eax, eax
    mov ecx, DI_SIZE / 8
    rep stosq
    pop rax
    pop rdi
    pop rcx
    ret
.full:
    xor eax, eax
    pop rdi
    pop rcx
    ret

; di_rect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour). Preserves all
; but RAX.
di_rect:
    call di_new
    test rax, rax
    jz .out
    mov byte [rax + DI_KIND], DK_RECT
    mov [rax + DI_X], edi
    mov [rax + DI_Y], esi
    mov [rax + DI_W], edx
    mov [rax + DI_H], ecx
    mov [rax + DI_COLOR], r8d
.out:
    ret

; di_text(RSI = text, ECX = bytes, EDI = x, EDX = baseline, R8D = font,
; R9D = colour, R10D = DF_*, R11D = width in 1/64). Preserves all but RAX.
di_text:
    call di_new
    test rax, rax
    jz .out
    mov byte [rax + DI_KIND], DK_TEXT
    mov [rax + DI_FONT], r8b
    or r10d, DF_PRE
    mov [rax + DI_FLAGS], r10w
    mov [rax + DI_LEN], ecx
    mov [rax + DI_X], edi
    mov [rax + DI_Y], edx
    mov [rax + DI_W], r11d
    mov [rax + DI_COLOR], r9d
    mov [rax + DI_TEXT], rsi
.out:
    ret

; ln_new -> RAX = the next line, zeroed but LN_CELL = -1, or 0 if full.
; Preserves all but RAX.
ln_new:
    push rcx
    push rdi
    mov eax, [ln_n]
    cmp eax, LN_MAX
    jae .full
    inc dword [ln_n]
    imul eax, eax, LN_SIZE
    add rax, [ln_base]
    mov rdi, rax
    push rax
    xor eax, eax
    mov ecx, LN_SIZE / 8
    rep stosq
    pop rax
    mov dword [rax + LN_CELL], -1
    pop rdi
    pop rcx
    ret
.full:
    xor eax, eax
    pop rdi
    pop rcx
    ret

; lt_alloc(EDI = bytes) -> RAX, for the length of a layout, or 0.
; Preserves all but RAX.
lt_alloc:
    push rcx
    mov rax, [lt_top]
    lea rcx, [rax + rdi]
    cmp rcx, [lt_end]
    ja .full
    mov [lt_top], rcx
    pop rcx
    ret
.full:
    xor eax, eax
    pop rcx
    ret

; style(EDI = BK_*) -> EAX = the size, ECX = the face it adds, EDX = space
; before, R8D = space after, in the context lc_ctx. Preserves all but those
; and R11.
style:
    mov eax, [lc_ctx]
    imul eax, eax, BK_COUNT
    add eax, edi
    lea r11, [styles]
    lea r11, [r11 + rax * 4]
    movzx eax, byte [r11]
    movzx ecx, byte [r11 + 1]
    movzx edx, byte [r11 + 2]
    movzx r8d, byte [r11 + 3]
    ret

; metrics(EAX = a size) -> R11 = its font's entry (sans), EAX = the line's
; height, ECX = the baseline below its top. Preserves all but those.
metrics:
    push rdx
    mov edx, eax
    call font_entry
    mov eax, [r11 + WFT_LINE]
    mov ecx, eax
    shr ecx, 2
    add eax, ecx                        ; a quarter more than the font's own
    mov ecx, eax                        ; the text centred in it
    sub ecx, [r11 + WFT_ASCENT]
    sub ecx, [r11 + WFT_DESCENT]
    shr ecx, 1
    add ecx, [r11 + WFT_ASCENT]
    pop rdx
    ret

; lc_need(EAX = height): on pages, a new page if it does not fit on this
; one (unless it is the first thing on it). Preserves all.
lc_need:
    cmp byte [lc_paged], 0
    je .out
    push rax
    add eax, [lc_y]
    cmp eax, [lc_bottom]
    pop rax
    jbe .out
    push rax
    mov eax, [lc_top]
    cmp [lc_y], eax
    pop rax
    jbe .out
    call lc_next_page
.out:
    ret

; lc_next_page: the next page's top. Preserves all.
lc_next_page:
    push rax
    inc dword [lc_page]
    mov eax, [lc_page]
    imul eax, eax, PG_H + PG_GAP
    add eax, PG_GAP + PG_M
    mov [lc_y], eax
    mov [lc_top], eax
    add eax, PG_H - 2 * PG_M
    mov [lc_bottom], eax
    pop rax
    ret

; font_of(EAX = attributes, R8D = LN_FONT's) -> EAX = the font. Preserves
; all else.
font_of:
    and eax, A_BOLD | A_ITALIC
    push rcx
    movzx ecx, r8b
    shr r8d, 8                          ; (put back below)
    or eax, r8d
    shl r8d, 8
    or r8d, ecx
    imul eax, eax, WF_SIZES
    add eax, ecx
    pop rcx
    ret

; ch_adv(EAX = a code point, R11 = its font's entry) -> EAX = its advance,
; 1/64 pixels. Preserves all else.
ch_adv:
    cmp eax, ' '
    je .space
    cmp eax, 9
    je .space
    call invisible
    je .none
    call glyph_at
    movzx eax, word [rax + WG_ADV]
    ret
.space:
    mov eax, [r11 + WFT_SPACE]
    ret
.none:
    xor eax, eax
    ret

measure:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov r12, [rdi + BL_TEXT]            ; R12: the text; R13: its attributes
    mov eax, [rdi + BL_CAP]
    lea r13, [r12 + rax]
    mov ebx, esi                        ; EBX: at; R14D: to
    mov r14d, edx
    mov r8d, ecx
    xor ebp, ebp                        ; EBP: the width
.char:
    cmp ebx, r14d
    jae .done
    movzx eax, byte [r13 + rbx]
    call font_of
    mov edx, eax
    call font_entry
    lea rsi, [r12 + rbx]
    lea rdx, [r12 + r14]
    call utf8_next
    sub rsi, r12
    mov ebx, esi
    call ch_adv
    add ebp, eax
    jmp .char
.done:
    mov eax, ebp
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

line_find:
    push rbx
    push rcx
    mov rax, [ln_base]
    mov ecx, [ln_n]
    xor ebx, ebx                        ; RBX: the last of the block's lines
.line:
    test ecx, ecx
    jz .last
    cmp [rax + LN_BLK], edi
    jne .next
    cmp dword [rax + LN_KIND], LK_BOX
    je .box
    cmp dword [rax + LN_KIND], LK_TEXT
    jne .cell
    mov rbx, rax
    cmp esi, [rax + LN_START]
    jb .next
    cmp esi, [rax + LN_END]
    jb .found
    je .at_end                          ; at a line's end: there, if it is the last
    jmp .next
.at_end:
    mov rdx, rax                        ; (the next line starting there wins)
    jmp .next
.cell:
    cmp [rax + LN_CELL], esi
    je .found
    jmp .next
.box:
    mov rbx, rax
.next:
    add rax, LN_SIZE
    dec ecx
    jmp .line
.last:
    mov rax, rbx
.found:
    pop rcx
    pop rbx
    ret

; --- text -----------------------------------------------------------------------

; lay_text(EDI = a block, ESI = x, EDX = width): its lines at lc_y, lc_y
; past them. lt_kind: the style to use (-1: its own); lt_colour; lt_align
; (-1: its own); lt_number: what a numbered item shows.
lay_text:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 88
    ; [rsp]: x, +4 width, +8 size, +12 face, +16 line height, +20 baseline,
    ; +24 align, +28 space after, +32 the line's start, +36 its end,
    ; +40 the pen, +44 the break, +48 the text's x, +52 the block's index
    mov [rsp + 52], edi
    call blk_at
    mov rbx, rax                        ; RBX: the block
    mov [rsp], esi
    mov [rsp + 4], edx
    movzx edi, byte [rbx + BL_KIND]
    cmp dword [lt_kind], -1
    je .kind
    mov edi, [lt_kind]
.kind:
    mov r15d, edi                       ; R15D: the kind it is laid out as
    call style
    mov [rsp + 8], eax
    mov [rsp + 12], ecx
    mov [rsp + 28], r8d
    mov eax, [lc_top]                   ; the space before, unless first
    cmp [lc_y], eax
    jbe .no_before
    add [lc_y], edx
.no_before:
    mov eax, [rsp + 8]
    call metrics
    mov [rsp + 16], eax
    mov [rsp + 20], ecx
    movzx eax, byte [rbx + BL_ALIGN]
    cmp dword [lt_align], -1
    je .align
    mov eax, [lt_align]
.align:
    mov [rsp + 24], eax
    cmp r15d, BK_BULLET                 ; a list's marker, and its indent
    je .list
    cmp r15d, BK_NUMBER
    jne .lines
.list:
    mov eax, [lc_ctx]
    lea rcx, [indents]
    movzx eax, byte [rcx + rax]
    add [rsp], eax
    sub [rsp + 4], eax
    mov eax, [rsp + 16]
    call lc_need
    mov eax, [rsp + 8]                  ; the marker: its font
    mov r8d, eax
    mov edx, eax
    call font_entry
    cmp r15d, BK_NUMBER
    je .number
    lea rsi, [s_bullet]
    mov ecx, 3
    jmp .marker
.number:
    mov edi, 8
    call lt_alloc
    test rax, rax
    jz .lines
    mov rsi, rax
    mov eax, [lt_number]
    xor ecx, ecx
    mov r9d, 10
.digit:
    xor edx, edx
    div r9d
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .digit
    xor edx, edx
.pop_digit:
    pop rax
    mov [rsi + rdx], al
    inc edx
    cmp edx, ecx
    jb .pop_digit
    mov byte [rsi + rcx], '.'
    inc ecx
.marker:
    mov edx, r8d
    call text_w64
    mov r11, rax
    shr eax, 6
    mov edi, [rsp]                      ; ending 8 pixels before the text
    sub edi, eax
    sub edi, 8
    mov edx, [lc_y]
    add edx, [rsp + 20]
    mov r9d, [lt_colour]
    xor r10d, r10d
    call di_text
.lines:
    mov r12, [rbx + BL_TEXT]            ; R12: the text; R13: its attributes
    mov eax, [rbx + BL_CAP]
    lea r13, [r12 + rax]
    mov r14d, [rbx + BL_LEN]            ; R14D: its length
    xor ebp, ebp                        ; EBP: where the next line starts
    test r14d, r14d
    jnz .line
    mov dword [rsp + 32], 0             ; empty: one line, nothing on it
    mov dword [rsp + 36], 0
    call .emit
    jmp .after
.line:
    cmp ebp, r14d
    jae .after
    mov [rsp + 32], ebp
    mov dword [rsp + 40], 0             ; the pen
    mov dword [rsp + 44], -1            ; no break yet
    mov ecx, [rsp + 4]                  ; ECX: the room, 1/64
    shl ecx, 6
.fit:
    cmp ebp, r14d
    jae .all
    movzx eax, byte [r13 + rbp]
    mov r8d, [rsp + 8]
    mov edx, [rsp + 12]
    shl edx, 8
    or r8d, edx
    call font_of
    mov edx, eax
    call font_entry
    lea rsi, [r12 + rbp]
    lea rdx, [r12 + r14]
    push rcx
    call utf8_next
    pop rcx
    mov edx, eax                        ; EDX: the character
    call ch_adv
    sub rsi, r12                        ; ESI: past it
    mov r8d, [rsp + 40]
    add r8d, eax
    cmp r8d, ecx
    jbe .fits
    cmp edx, ' '                        ; a space past the edge hangs there
    je .hang
    cmp ebp, [rsp + 32]                 ; the first on the line goes anyway
    je .fits
    mov eax, [rsp + 44]
    cmp eax, -1
    je .break_here
    mov ebp, eax                        ; back to the last space
    jmp .break_here
.hang:
    mov ebp, esi
    mov [rsp + 44], ebp
    jmp .fit
.fits:
    mov [rsp + 40], r8d
    mov ebp, esi
    cmp edx, ' '
    jne .fit
    mov [rsp + 44], ebp                 ; it may break after a space
    jmp .fit
.all:
    mov ebp, r14d
.break_here:
    mov [rsp + 36], ebp
    call .emit
    jmp .line
.after:
    mov eax, [rsp + 28]
    add [lc_y], eax
    add rsp, 88
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; .emit: the line [rsp+32, rsp+36) (here at +8) at lc_y, lc_y past it
.emit:
    mov eax, [rsp + 8 + 16]
    call lc_need
    mov r8d, [rsp + 8 + 8]              ; R8D: LN_FONT's
    mov eax, [rsp + 8 + 12]
    shl eax, 8
    or r8d, eax
    mov edx, [rsp + 8 + 36]             ; its width, spaces at the end left out
.trail:
    cmp edx, [rsp + 8 + 32]
    jbe .trailed
    cmp byte [r12 + rdx - 1], ' '
    jne .trailed
    dec edx
    jmp .trail
.trailed:
    mov rdi, rbx
    mov esi, [rsp + 8 + 32]
    mov ecx, r8d
    push r8
    call measure
    pop r8
    add eax, 63
    shr eax, 6                          ; EAX: in pixels
    mov edi, [rsp + 8]                  ; EDI: where it starts
    mov ecx, [rsp + 8 + 4]
    sub ecx, eax
    jns .room
    xor ecx, ecx
.room:
    cmp dword [rsp + 8 + 24], AL_CENTER
    jne .right
    shr ecx, 1
    add edi, ecx
    jmp .placed
.right:
    cmp dword [rsp + 8 + 24], AL_RIGHT
    jne .placed
    add edi, ecx
.placed:
    mov [rsp + 8 + 48], edi
    call ln_new                         ; the line
    test rax, rax
    jz .runs
    mov ecx, [rsp + 8 + 52]
    mov [rax + LN_BLK], ecx
    mov ecx, [rsp + 8 + 32]
    mov [rax + LN_START], ecx
    mov ecx, [rsp + 8 + 36]
    mov [rax + LN_END], ecx
    mov [rax + LN_X], edi
    mov ecx, [lc_y]
    mov [rax + LN_Y], ecx
    mov ecx, [rsp + 8 + 16]
    mov [rax + LN_H], ecx
    mov ecx, [lc_y]
    add ecx, [rsp + 8 + 20]
    mov [rax + LN_BASE], ecx
    mov [rax + LN_FONT], r8d
    mov ecx, [rsp + 8]
    mov [rax + LN_X0], ecx
    mov ecx, [rsp + 8 + 4]
    mov [rax + LN_W], ecx
    mov dword [rax + LN_KIND], LK_TEXT
.runs:
    mov esi, [rsp + 8 + 32]             ; ESI: a run's start; the pen in 1/64
    mov dword [rsp + 8 + 40], 0
.run:
    cmp esi, [rsp + 8 + 36]
    jae .emitted
    mov edx, esi                        ; EDX: past the run
    mov al, [r13 + rsi]
.run_len:
    inc edx
    cmp edx, [rsp + 8 + 36]
    jae .run_end
    cmp al, [r13 + rdx]
    je .run_len
.run_end:
    push rdx
    push rsi
    push r8
    mov rdi, rbx                        ; its width
    mov ecx, r8d
    call measure
    pop r8
    pop rsi
    pop rdx
    mov r11d, eax                       ; R11D: the width
    movzx eax, byte [r13 + rsi]
    xor r10d, r10d                      ; R10D: underlined, struck through
    test eax, A_UNDER
    jz .no_under
    or r10d, DF_UNDER
.no_under:
    test eax, A_STRIKE
    jz .no_strike
    or r10d, DF_STRIKE
.no_strike:
    push r8
    call font_of
    mov r9d, [lt_colour]
    push rsi
    push rdx
    mov ecx, edx
    sub ecx, esi
    mov edi, [rsp + 24 + 8 + 40]        ; x: where the line starts and the pen
    sar edi, 6
    add edi, [rsp + 24 + 8 + 48]
    mov edx, [lc_y]
    add edx, [rsp + 24 + 8 + 20]
    mov r8d, eax
    add rsi, r12
    call di_text
    add [rsp + 24 + 8 + 40], r11d
    pop rdx
    pop rsi
    pop r8
    mov esi, edx
    jmp .run
.emitted:
    mov eax, [rsp + 8 + 16]
    add [lc_y], eax
    ret

; --- grids, images, frames --------------------------------------------------------

; lay_grid(EDI = a grid's block, ESI = x, EDX = width): its table at lc_y
lay_grid:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 72
    ; [rsp]: x, +4 width, +8 size, +12 column width, +16 row height,
    ; +20 baseline, +24 the row, +28 the column, +32 rows, +36 columns,
    ; +40 space after, +44 the block's index, +48 the row's top, +52 the face
    mov [rsp + 44], edi
    call blk_at
    mov rbx, [rax + BL_DATA]            ; RBX: the grid
    mov [rsp], esi
    mov [rsp + 4], edx
    mov edi, BK_GRID
    call style
    mov [rsp + 8], eax
    mov [rsp + 40], r8d
    mov eax, [lc_top]
    cmp [lc_y], eax
    jbe .no_before
    add [lc_y], edx
.no_before:
    mov eax, [rsp + 8]
    call metrics
    add eax, 10                         ; 5 above and below
    mov [rsp + 16], eax
    add ecx, 5
    mov [rsp + 20], ecx
    mov eax, [rbx + GR_ROWS]
    mov [rsp + 32], eax
    mov ecx, [rbx + GR_COLS]
    mov [rsp + 36], ecx
    mov eax, [rsp + 4]
    xor edx, edx
    div ecx
    mov [rsp + 12], eax
    mov dword [rsp + 24], 0
.row:
    mov eax, [rsp + 24]
    cmp eax, [rsp + 32]
    jae .done
    mov eax, [rsp + 16]
    call lc_need
    mov eax, [lc_y]
    mov [rsp + 48], eax
    mov eax, [rsp + 12]                 ; R14D: the table's width
    imul eax, [rsp + 36]
    mov r14d, eax
    mov dword [rsp + 52], 0
    cmp dword [rsp + 24], 0             ; a header row: shaded, bold
    jne .lines
    test byte [rbx + GR_FLAGS], GF_HEADER
    jz .lines
    mov dword [rsp + 52], 1
    mov edi, [rsp]
    mov esi, [lc_y]
    mov edx, r14d
    mov ecx, [rsp + 16]
    mov r8d, C_TABLE_HEAD
    call di_rect
.lines:
    mov edi, [rsp]                      ; its line above, and the columns'
    mov esi, [lc_y]
    mov edx, r14d
    mov ecx, 1
    mov r8d, C_TABLE_LINE
    call di_rect
    xor r15d, r15d
.vline:
    cmp r15d, [rsp + 36]
    ja .cells
    mov edi, [rsp + 12]
    imul edi, r15d
    add edi, [rsp]
    cmp r15d, [rsp + 36]                ; the last, inside the table
    jne .vline_at
    dec edi
.vline_at:
    mov esi, [lc_y]
    mov edx, 1
    mov ecx, [rsp + 16]
    mov r8d, C_TABLE_LINE
    call di_rect
    inc r15d
    jmp .vline
.cells:
    mov dword [rsp + 28], 0
.cell:
    mov eax, [rsp + 28]
    cmp eax, [rsp + 36]
    jae .row_done
    call .lay_cell
    inc dword [rsp + 28]
    jmp .cell
.row_done:
    mov eax, [rsp + 16]
    add [lc_y], eax
    inc dword [rsp + 24]
    jmp .row
.done:
    mov eax, [rsp + 12]                 ; the line under it
    imul eax, [rsp + 36]
    mov edx, eax
    mov edi, [rsp]
    mov esi, [lc_y]
    mov ecx, 1
    mov r8d, C_TABLE_LINE
    call di_rect
    inc dword [lc_y]
    mov eax, [rsp + 40]
    add [lc_y], eax
    add rsp, 72
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; .lay_cell: the cell at [rsp+24], [rsp+28] (here +8): its value (or what
; is being typed into it), and its line
.lay_cell:
    mov rdi, rbx
    mov esi, [rsp + 8 + 24]
    mov edx, [rsp + 8 + 28]
    call cell_at
    mov r12, rax                        ; R12: the cell
    mov r13d, [rsp + 8 + 24]            ; R13D: its index
    imul r13d, r13d, MAXC
    add r13d, [rsp + 8 + 28]
    xor ebp, ebp                        ; EBP: 1 if it is being edited
    cmp byte [ed_on], 0
    je .shown
    mov eax, [ed_blk_index]
    cmp eax, [rsp + 8 + 44]
    jne .shown
    cmp [ed_cell], r13d
    jne .shown
    mov ebp, 1
    mov rsi, [ed_blk + BL_TEXT]
    mov ecx, [ed_blk + BL_LEN]
    xor eax, eax
    jmp .text
.shown:
    mov edi, 32
    call lt_alloc
    test rax, rax
    jz .cell_out
    mov rsi, rax
    mov rdi, r12
    call cell_show                      ; RSI, ECX: what it shows; EAX: a number
.text:
    mov r15d, eax                       ; R15D: right-aligned
    mov r8d, [rsp + 8 + 52]             ; the font
    imul r8d, r8d, WF_SIZES
    add r8d, [rsp + 8 + 8]
    mov edx, r8d
    mov r14d, [rsp + 8 + 12]            ; R14D: the room, less 6 each side
    sub r14d, 12
    jns .cut
    xor r14d, r14d
.cut:                                   ; as much as fits
    test ebp, ebp
    jnz .measured                       ; (what is being typed, all of it)
    call text_px
    cmp eax, r14d
    jbe .measured
    test ecx, ecx
    jz .measured
    push rdx
    mov edx, ecx
    push rsi
    call utf8_prev
    pop rsi
    mov ecx, eax
    pop rdx
    jmp .cut
.measured:
    call text_px
    mov r11d, eax
    shl r11d, 6
    mov edi, [rsp + 8 + 12]             ; x: the cell's, and 6 in
    imul edi, [rsp + 8 + 28]
    add edi, [rsp + 8]
    add edi, 6
    test r15d, r15d
    jz .left
    test ebp, ebp
    jnz .left
    add edi, r14d
    sub edi, eax
.left:
    push rdi
    push rsi
    push rcx
    mov edx, [lc_y]
    add edx, [rsp + 24 + 8 + 20]
    mov r9d, C_INK
    xor r10d, r10d
    call di_text
    call ln_new
    pop rcx
    pop rsi
    pop rdi
    test rax, rax
    jz .cell_out
    mov edx, [rsp + 8 + 44]
    test ebp, ebp
    jz .ln_blk
    mov edx, EDIT_BLK
.ln_blk:
    mov [rax + LN_BLK], edx
    mov dword [rax + LN_START], 0
    mov [rax + LN_END], ecx
    mov [rax + LN_X], edi
    mov ecx, [lc_y]
    mov [rax + LN_Y], ecx
    mov ecx, [rsp + 8 + 16]
    mov [rax + LN_H], ecx
    mov ecx, [lc_y]
    add ecx, [rsp + 8 + 20]
    mov [rax + LN_BASE], ecx
    mov [rax + LN_CELL], r13d
    mov ecx, [rsp + 8 + 52]
    shl ecx, 8
    or ecx, [rsp + 8 + 8]
    mov [rax + LN_FONT], ecx
    mov ecx, [rsp + 8 + 12]
    imul ecx, [rsp + 8 + 28]
    add ecx, [rsp + 8]
    mov [rax + LN_X0], ecx
    mov ecx, [rsp + 8 + 12]
    mov [rax + LN_W], ecx
    mov dword [rax + LN_KIND], LK_CELL
.cell_out:
    ret

; lay_image(EDI = an image's block, ESI = x, EDX = width, ECX = the most it
; may be tall): centred at lc_y, a box line for it
lay_image:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    push rdi
    mov edi, BK_IMAGE
    call style
    pop rdi
    push r8                             ; the space after
    mov eax, [lc_top]
    cmp [lc_y], eax
    jbe .no_before
    add [lc_y], edx
.no_before:
    mov edi, r15d
    call blk_at
    mov rbx, [rax + BL_DATA]
    mov eax, [rbx + IM_W]               ; EAX: its width, at most the room
    cmp eax, r13d
    jbe .w
    mov eax, r13d
.w:
    mov ecx, [rbx + IM_H]               ; ECX: its height, as scaled
    imul ecx, eax
    xor edx, edx
    push rax
    mov eax, ecx
    div dword [rbx + IM_W]
    mov ecx, eax
    pop rax
    cmp ecx, r14d                       ; too tall: smaller
    jbe .sized
    mov ecx, r14d
    mov eax, [rbx + IM_W]
    imul eax, ecx
    xor edx, edx
    div dword [rbx + IM_H]
.sized:
    test eax, eax
    jnz .w_ok
    inc eax
.w_ok:
    test ecx, ecx
    jnz .h_ok
    inc ecx
.h_ok:
    push rax
    mov eax, ecx
    call lc_need
    pop rax
    mov edx, r13d                       ; centred
    sub edx, eax
    shr edx, 1
    add edx, r12d
    push rax
    push rcx
    push rdx
    call ln_new
    pop rdx
    pop rcx
    pop r8
    test rax, rax
    jz .placed
    mov [rax + LN_BLK], r15d
    mov [rax + LN_X0], edx
    mov [rax + LN_X], edx
    mov [rax + LN_W], r8d
    mov edx, [lc_y]
    mov [rax + LN_Y], edx
    mov [rax + LN_H], ecx
    mov dword [rax + LN_KIND], LK_BOX
.placed:
    add [lc_y], ecx
    pop r8
    add [lc_y], r8d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lay_blocks(EDI = first, ESI = end, EDX = x, ECX = width, R8D = the most
; an image may be tall): each in turn at lc_y, as lc_ctx has them
lay_blocks:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    mov dword [lt_number], 0
.block:
    cmp ebx, r12d
    jae .out
    mov edi, ebx
    call blk_at
    movzx ecx, byte [rax + BL_KIND]
    cmp ecx, BK_NUMBER                  ; numbered items count up together
    je .numbered
    mov dword [lt_number], 0
    jmp .kind
.numbered:
    inc dword [lt_number]
.kind:
    cmp ecx, BK_GRID
    je .grid
    cmp ecx, BK_IMAGE
    je .image
    cmp ecx, BK_SLIDE
    je .frame
    mov dword [lt_kind], -1
    mov dword [lt_align], -1
    PUT_C [lt_colour], C_INK
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    call lay_text
    inc ebx
    jmp .block
.grid:
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    call lay_grid
    inc ebx
    jmp .block
.image:
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    call lay_image
    inc ebx
    jmp .block
.frame:
    cmp dword [lc_ctx], CTX_PAGE        ; a frame on a page: a slide, there
    jne .frame_text
    mov edi, ebx
    call lay_frame
    mov edi, ebx
    call blk_end
    mov ebx, eax
    jmp .block
.frame_text:                            ; (never nested: its title, as text)
    mov dword [lt_kind], BK_H1
    mov dword [lt_align], -1
    PUT_C [lt_colour], C_INK
    mov edi, ebx
    mov esi, r13d
    mov edx, r14d
    call lay_text
    inc ebx
    jmp .block
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lay_frame(EDI = a frame, on a page): a card two thirds of a slide's size,
; the slide laid out on it; a box line for it
lay_frame:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi
    mov edi, BK_SLIDE                   ; the space before
    call style
    mov eax, [lc_top]
    cmp [lc_y], eax
    jbe .no_before
    add [lc_y], edx
.no_before:
    mov eax, MINI_H
    call lc_need
    call ln_new
    mov r12, rax                        ; R12: its box line
    test rax, rax
    jz .out
    mov [r12 + LN_BLK], ebx
    mov eax, [lc_x]
    mov [r12 + LN_X0], eax
    mov [r12 + LN_X], eax
    mov dword [r12 + LN_W], MINI_W
    mov eax, [lc_y]
    mov [r12 + LN_Y], eax
    mov dword [r12 + LN_H], MINI_H
    mov dword [r12 + LN_KIND], LK_BOX
    mov r13d, [lc_y]                    ; R13D: its top
    push qword [lc_paged]               ; the page's state, kept
    push qword [lc_top]
    push qword [lc_bottom]
    mov byte [lc_paged], 0
    mov dword [lc_ctx], CTX_MINI
    mov edi, ebx
    call frame_slide                    ; ESI, EDX, ECX: its slide
    mov r8d, [lc_x]
    mov r9d, r13d
    mov dword [ls_w], MINI_W
    mov dword [ls_h], MINI_H
    mov dword [ls_m], MINI_M
    call lay_slide_at
    pop qword [lc_bottom]
    pop qword [lc_top]
    pop qword [lc_paged]
    mov dword [lc_ctx], CTX_PAGE
    mov eax, [lc_y]                     ; as tall as it needs to be
    add eax, MINI_M / 2
    sub eax, r13d
    cmp eax, MINI_H
    jae .tall
    mov eax, MINI_H
.tall:
    mov [r12 + LN_H], eax
    add eax, r13d
    mov [lc_y], eax
    mov edi, BK_SLIDE
    call style
    add [lc_y], r8d
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; frame_slide(EDI = a frame) -> ESI = its title (itself), EDX = its first
; block, ECX = the end of them. Preserves all else.
frame_slide:
    push rax
    mov esi, edi
    lea edx, [rdi + 1]
    call blk_end
    mov ecx, eax
    pop rax
    ret

; lay_slide_at(ESI = the title's block or -1, EDX = first, ECX = end, R8D,
; R9D = the slide's top left; ls_w, ls_h, ls_m its size and margin;
; lc_ctx): the title and what follows it, a slide's way. With nothing (or a
; single paragraph) after it, the title is centred, the paragraph under it.
lay_slide_at:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov ebx, esi                        ; EBX: the title
    mov r12d, edx                       ; R12D, R13D: the body
    mov r13d, ecx
    mov r14d, r8d                       ; R14D, R15D: where
    mov r15d, r9d
    mov eax, r15d
    mov [lc_top], eax
    mov eax, [ls_h]
    add eax, r15d
    mov [lc_bottom], eax
    mov eax, r13d                       ; a title slide?
    sub eax, r12d
    jz .centred
    cmp eax, 1
    jne .titled
    mov edi, r12d
    call blk_at
    cmp byte [rax + BL_KIND], BK_PARA
    jne .titled
.centred:
    cmp ebx, -1
    je .titled
    mov eax, [ls_h]                     ; the title, above the middle
    imul eax, eax, 38
    xor edx, edx
    mov ecx, 100
    div ecx
    add eax, r15d
    mov [lc_y], eax
    mov dword [lt_kind], BK_SLIDE
    mov dword [lt_align], AL_CENTER
    PUT_C [lt_colour], C_INK
    mov edi, ebx
    mov esi, r14d
    add esi, [ls_m]
    mov edx, [ls_w]
    sub edx, [ls_m]
    sub edx, [ls_m]
    call lay_text
    mov eax, [ls_m]                     ; then the accent, centred
    shr eax, 3
    add [lc_y], eax
    call .accent_c
    cmp r12d, r13d
    je .out
    mov eax, [ls_m]
    shr eax, 2
    add [lc_y], eax
    mov dword [lt_kind], -1
    mov dword [lt_align], AL_CENTER
    PUT_C [lt_colour], C_SECOND
    mov edi, r12d
    mov esi, r14d
    add esi, [ls_m]
    mov edx, [ls_w]
    sub edx, [ls_m]
    sub edx, [ls_m]
    call lay_text
    jmp .out
.titled:
    mov eax, [ls_m]
    imul eax, eax, 3
    shr eax, 2
    add eax, r15d
    mov [lc_y], eax
    mov [lc_top], eax
    cmp ebx, -1
    je .body
    mov dword [lt_kind], BK_SLIDE
    mov dword [lt_align], -1
    PUT_C [lt_colour], C_INK
    mov edi, ebx
    mov esi, r14d
    add esi, [ls_m]
    mov edx, [ls_w]
    sub edx, [ls_m]
    sub edx, [ls_m]
    call lay_text
    mov eax, [ls_m]                     ; the accent under it
    shr eax, 3
    add [lc_y], eax
    mov edi, r14d
    add edi, [ls_m]
    call .accent
    mov eax, [ls_m]
    shr eax, 1
    add [lc_y], eax
    mov eax, [lc_y]
    mov [lc_top], eax
.body:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    add edx, [ls_m]
    mov ecx, [ls_w]
    sub ecx, [ls_m]
    sub ecx, [ls_m]
    mov r8d, [ls_h]                     ; an image: what is left of the slide
    add r8d, r15d
    sub r8d, [lc_y]
    sub r8d, [ls_m]
    cmp r8d, 40
    jge .room
    mov r8d, 40
.room:
    call lay_blocks
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; .accent(EDI = x): a short bar in the accent at lc_y; .accent_c centred
.accent_c:
    mov edi, [ls_w]
    shr edi, 1
    add edi, r14d
    mov eax, [ls_m]
    shr eax, 1
    shr eax, 1
    sub edi, eax                        ; (half its width: ls_m * 5/8 / 2, near enough)
.accent:
    mov edx, [ls_m]
    imul edx, edx, 5
    shr edx, 3
    mov esi, [lc_y]
    mov ecx, [ls_m]
    shr ecx, 4
    test ecx, ecx
    jnz .thick
    inc ecx
.thick:
    mov r8d, C_ACCENT
    call di_rect
    add [lc_y], ecx
    ret

; --- the views --------------------------------------------------------------------

layout_pages:
    call lay_reset
    mov dword [lc_ctx], CTX_PAGE
    mov byte [lc_paged], 1
    mov dword [lc_page], -1
    call lc_next_page
    mov dword [lc_x], PG_X + PG_M
    xor edi, edi
    mov esi, [nblocks]
    mov edx, PG_X + PG_M
    mov ecx, PG_TEXT
    mov r8d, PG_H - 2 * PG_M
    call lay_blocks
    mov eax, [lc_page]
    inc eax
    mov [pg_count], eax
    imul eax, eax, PG_H + PG_GAP
    add eax, PG_GAP
    mov [doc_h], eax
    ret

slides_build:
    push rbx
    push r12
    push r13
    mov dword [sl_n], 0
    xor ebx, ebx                        ; EBX: the block
    mov r12d, -1                        ; R12D: the slide open, or -1
.block:
    cmp ebx, [nblocks]
    jae .close_last
    mov edi, ebx
    call blk_at
    movzx ecx, byte [rax + BL_KIND]
    cmp ecx, BK_SLIDE
    je .frame
    cmp ecx, BK_H1
    je .heading
    cmp r12d, -1                        ; anything else: into the slide open
    jne .next
    mov edi, -1
    mov esi, ebx
    call .open
    jmp .next
.heading:
    call .close
    mov edi, ebx
    lea esi, [rbx + 1]
    call .open
    jmp .next
.frame:
    call .close
    mov edi, ebx
    lea esi, [rbx + 1]
    call .open
    mov edi, ebx
    call blk_end
    mov ebx, eax
    call .close
    mov eax, [sl_n]                     ; it is a frame's
    dec eax
    shl eax, 4
    add rax, [sl_base]
    mov edx, [rax + SL_TITLE]
    mov [rax + SL_FRAME], edx
    jmp .block
.next:
    inc ebx
    jmp .block
.close_last:
    call .close
    pop r13
    pop r12
    pop rbx
    ret
; .open(EDI = title, ESI = first): a slide begun
.open:
    mov eax, [sl_n]
    cmp eax, SL_MAX
    jae .opened
    shl eax, 4
    add rax, [sl_base]
    mov [rax + SL_TITLE], edi
    mov [rax + SL_FIRST], esi
    mov [rax + SL_END], esi
    mov dword [rax + SL_FRAME], -1
    mov r12d, [sl_n]
    inc dword [sl_n]
.opened:
    ret
; .close: the slide open ends before EBX; one with no title and nothing
; but empty text dropped
.close:
    cmp r12d, -1
    je .closed
    mov eax, r12d
    shl eax, 4
    add rax, [sl_base]
    mov [rax + SL_END], ebx
    mov r12d, -1
    cmp dword [rax + SL_TITLE], -1
    jne .closed
    mov ecx, [rax + SL_FIRST]
.empty:
    cmp ecx, ebx
    jae .drop
    mov edi, ecx
    push rax
    call blk_at
    mov rdx, rax
    pop rax
    cmp byte [rdx + BL_KIND], BK_GRID
    je .closed
    cmp byte [rdx + BL_KIND], BK_IMAGE
    je .closed
    cmp dword [rdx + BL_LEN], 0
    jne .closed
    inc ecx
    jmp .empty
.drop:
    dec dword [sl_n]
.closed:
    ret

slide_of:
    mov eax, -1
    cmp dword [sl_n], 0
    je .out
    push rcx
    push rdx
    xor ecx, ecx
    mov rdx, [sl_base]
.slide:
    cmp ecx, [sl_n]
    jae .last
    mov eax, [rdx + SL_TITLE]           ; from its title (or first block) to its end
    cmp eax, -1
    jne .from
    mov eax, [rdx + SL_FIRST]
.from:
    cmp edi, eax
    jb .before
    cmp edi, [rdx + SL_END]
    jb .found
    inc ecx
    add rdx, SL_SIZE
    jmp .slide
.before:                                ; between slides: the next one
.found:
    mov eax, ecx
    pop rdx
    pop rcx
.out:
    ret
.last:
    lea eax, [rcx - 1]
    pop rdx
    pop rcx
    ret

layout_slide:
    push rbx
    mov ebx, edi
    call lay_reset
    mov dword [lc_ctx], CTX_SLIDE
    mov byte [lc_paged], 0
    mov [lc_x], esi
    mov r8d, esi
    mov r9d, edx
    mov eax, ebx
    shl eax, 4
    add rax, [sl_base]
    mov esi, [rax + SL_TITLE]
    mov edx, [rax + SL_FIRST]
    mov ecx, [rax + SL_END]
    mov dword [ls_w], SL_W
    mov dword [ls_h], SL_H
    mov dword [ls_m], SL_M
    call lay_slide_at
    pop rbx
    ret

section .rodata
; per context, per kind: size, face added, space before, after
styles:
    db WF_PX16, 0, 0, 10,   WF_PX28, 1, 22, 10,  WF_PX24, 1, 18, 8,  WF_PX20, 1, 14, 6
    db WF_PX16, 0, 0, 6,    WF_PX16, 0, 0, 6,    WF_PX16, 0, 10, 14, WF_PX16, 0, 10, 14
    db WF_PX24, 1, 12, 18
    db WF_PX24, 0, 0, 16,   WF_PX36, 1, 0, 20,   WF_PX28, 1, 8, 14,  WF_PX24, 1, 6, 10
    db WF_PX24, 0, 0, 12,   WF_PX24, 0, 0, 12,   WF_PX20, 0, 8, 16,  WF_PX20, 0, 8, 16
    db WF_PX36, 1, 0, 0
    db WF_PX16, 0, 0, 10,   WF_PX24, 1, 0, 12,   WF_PX20, 1, 4, 8,   WF_PX16, 1, 4, 6
    db WF_PX16, 0, 0, 8,    WF_PX16, 0, 0, 8,    WF_PX13, 0, 4, 10,  WF_PX13, 0, 4, 10
    db WF_PX24, 1, 0, 0
indents:        db 28, 40, 26
s_bullet:       db 0xE2, 0x80, 0xA2     ; U+2022
cp1252:         dw 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021
                dw 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F
                dw 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014
                dw 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178

section .bss
alignb 8
dl_base:        resq 1
dl_top:         resq 1
dl_end:         resq 1
ln_base:        resq 1
lt_base:        resq 1
lt_top:         resq 1
lt_end:         resq 1
sl_base:        resq 1
lc_paged:       resq 1                  ; (a byte, kept as a qword)
lc_top:         resq 1                  ; (dwords, kept as qwords)
lc_bottom:      resq 1
ln_n:           resd 1
lc_ctx:         resd 1
lc_x:           resd 1
lc_y:           resd 1
lc_page:        resd 1
lt_kind:        resd 1
lt_align:       resd 1
lt_colour:      resd 1
lt_number:      resd 1
ls_w:           resd 1
ls_h:           resd 1
ls_m:           resd 1
pg_count:       resd 1
doc_h:          resd 1
sl_n:           resd 1

section .text
