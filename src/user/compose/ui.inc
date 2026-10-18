; =============================================================================
;  compose/ui.inc - what compose's controls and cards are drawn with, in
;  points (compose/draw.inc): blended rectangles, rounded ones with
;  anti-aliased corners, shadows, labels, and buttons drawn as the
;  desktop's (kit.inc). The colours are two palettes: the window's (pal),
;  the desktop's theme, its text and accent; and the document's (dpal), its
;  paper and ink, dark with the theme or light whatever it is (ui_theme).
;    blend_rect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour, R9D =
;      alpha 0-255)
;    fill_round(EDI, ESI, EDX, ECX, R8D = radius, R9D = colour)
;    frame_round(EDI, ESI, EDX, ECX, R8D = radius, R9D = edge colour,
;      [ui_fill] = the colour inside): an edge a pixel wide
;    shadow(EDI, ESI, EDX, ECX, R8D = radius): soft, under a card
;    field(EDI, ESI, EDX, ECX, R8D = 1 if it has the keys): a text field's
;      box, the desktop's
;    label(RSI, ECX, EDI = x, ESI2 = [ui_mid] the line's middle, R8D = font,
;      R9D = colour) -> EAX = the x after it: text centred on a line
;    label_c(RSI, ECX, EDI = the centre's x, R8D, R9D): likewise, centred
;    button(RDI = a BT_* entry, ESI = 1 if it is on, EDX = 1 if pressed)
;    bt_x(RDI = a BT_* entry) -> EAX = its x now (BV_RIGHT: from the
;      window's right). Preserves all but RAX.
;  Each preserves RBX, RBP, R12-R15.
; =============================================================================

; colours: two palettes of the same slots. Each C_* is a dword of pal,
; the window's (its text, lines and accent the desktop's), and each D_* of
; dpal, the document's; ui_theme fills them from pal_light or pal_dark and
; the look. A colour is read (mov r8d, C_INK), and put into memory through
; a register (PUT_C).
P_WINDOW        equ 0                   ; behind the pages
P_CHROME        equ 4                   ; the toolbar, the status line
P_HAIRLINE      equ 8
P_INK           equ 12
P_SECOND        equ 16
P_FAINT         equ 20
P_ACCENT        equ 24                  ; the system blue
P_ACCENT_DK     equ 28                  ; pressed, and lit labels
P_SELECT        equ 32                  ; text chosen
P_PAPER         equ 36                  ; pages, slides, cells
P_BUTTON        equ 40
P_BUTTON_EDGE   equ 44
P_BUTTON_ON     equ 48
P_PRESSED       equ 52
P_SEG_TRACK     equ 56
P_TABLE_HEAD    equ 60
P_TABLE_LINE    equ 64
P_GRID_LINE     equ 68
P_GRID_HEAD     equ 72
P_SIDEBAR       equ 76
P_CARD          equ 80                  ; a slide's frame on a page
P_ERROR         equ 84                  ; a cell's error
P_BYTES         equ 88

%define C_WINDOW        dword [pal + P_WINDOW]
%define C_CHROME        dword [pal + P_CHROME]
%define C_HAIRLINE      dword [pal + P_HAIRLINE]
%define C_INK           dword [pal + P_INK]
%define C_SECOND        dword [pal + P_SECOND]
%define C_FAINT         dword [pal + P_FAINT]
%define C_ACCENT        dword [pal + P_ACCENT]
%define C_ACCENT_DK     dword [pal + P_ACCENT_DK]
%define C_SELECT        dword [pal + P_SELECT]
%define C_PAPER         dword [pal + P_PAPER]
%define C_BUTTON        dword [pal + P_BUTTON]
%define C_BUTTON_EDGE   dword [pal + P_BUTTON_EDGE]
%define C_BUTTON_ON     dword [pal + P_BUTTON_ON]
%define C_PRESSED       dword [pal + P_PRESSED]
%define C_SEG_TRACK     dword [pal + P_SEG_TRACK]
%define C_TABLE_HEAD    dword [pal + P_TABLE_HEAD]
%define C_TABLE_LINE    dword [pal + P_TABLE_LINE]
%define C_GRID_LINE     dword [pal + P_GRID_LINE]
%define C_GRID_HEAD     dword [pal + P_GRID_HEAD]
%define C_SIDEBAR       dword [pal + P_SIDEBAR]
%define C_CARD          dword [pal + P_CARD]
%define C_ERROR         dword [pal + P_ERROR]
%define D_WINDOW        dword [dpal + P_WINDOW]
%define D_CHROME        dword [dpal + P_CHROME]
%define D_HAIRLINE      dword [dpal + P_HAIRLINE]
%define D_INK           dword [dpal + P_INK]
%define D_SECOND        dword [dpal + P_SECOND]
%define D_FAINT         dword [dpal + P_FAINT]
%define D_ACCENT        dword [dpal + P_ACCENT]
%define D_ACCENT_DK     dword [dpal + P_ACCENT_DK]
%define D_SELECT        dword [dpal + P_SELECT]
%define D_PAPER         dword [dpal + P_PAPER]
%define D_BUTTON        dword [dpal + P_BUTTON]
%define D_BUTTON_EDGE   dword [dpal + P_BUTTON_EDGE]
%define D_BUTTON_ON     dword [dpal + P_BUTTON_ON]
%define D_PRESSED       dword [dpal + P_PRESSED]
%define D_SEG_TRACK     dword [dpal + P_SEG_TRACK]
%define D_TABLE_HEAD    dword [dpal + P_TABLE_HEAD]
%define D_TABLE_LINE    dword [dpal + P_TABLE_LINE]
%define D_GRID_LINE     dword [dpal + P_GRID_LINE]
%define D_GRID_HEAD     dword [dpal + P_GRID_HEAD]
%define D_SIDEBAR       dword [dpal + P_SIDEBAR]
%define D_CARD          dword [dpal + P_CARD]
%define D_ERROR         dword [dpal + P_ERROR]
C_BLACK         equ 0x000000            ; shadows, the presenter's bars

; PUT_C [memory], C_*: a colour put into a dword. Preserves all.
%macro PUT_C 2
    push rax
    mov eax, %2
    mov %1, eax
    pop rax
%endmacro

UI_FONT         equ UIF + 13            ; the desktop's (compose/draw.inc)
UI_BOLD         equ UIF + UIF_BOLD + 13
UI_SMALL        equ UIF + 11
DOC_FONT        equ WF_SANS * WF_SIZES + WF_PX16    ; the grid's cells

UI_FONT         equ UIF + 13            ; the desktop's (compose/draw.inc)
UI_BOLD         equ UIF + UIF_BOLD + 13
UI_SMALL        equ UIF + 11
DOC_FONT        equ WF_SANS * WF_SIZES + WF_PX16    ; the grid's cells

; a button: where, its size, what it does, its label
BT_X            equ 0                   ; word
BT_Y            equ 2
BT_W            equ 4
BT_H            equ 6
BT_ACT          equ 8                   ; byte: ACT_*
BT_VIEWS        equ 9                   ; byte: 1 << the views it is in, and
BV_RIGHT        equ 0x80                ; its x from the right, as if the
DEF_W           equ 1040                ; window were DEF_W wide
BT_STYLE        equ 10                  ; byte: BS_*
BT_FONT         equ 11                  ; byte
BT_LABEL        equ 16                  ; qword: UTF-8, NUL-ended
BT_SIZE         equ 24
BS_PLAIN        equ 0
BS_PRIMARY      equ 1                   ; filled with the accent
BS_GHOST        equ 2                   ; no edge until it is on

section .text

; px_blend(EAX = what is there, ESI = colour, ECX = alpha) -> EAX. Preserves
; all but RAX, R10, R11.
px_blend:
    push rdx
    mov r11d, eax
    and r11d, 0xFF00FF
    and eax, 0x00FF00
    mov edx, 255
    sub edx, ecx
    imul r11, rdx
    imul rax, rdx
    mov r10d, esi
    and r10d, 0xFF00FF
    imul r10, rcx
    add r11, r10
    mov r10d, esi
    and r10d, 0x00FF00
    imul r10, rcx
    add rax, r10
    add r11, 0x800080
    add rax, 0x008000
    mov r10, r11
    shr r10, 8
    and r10d, 0xFF00FF
    add r11, r10
    shr r11, 8
    and r11d, 0xFF00FF
    mov r10, rax
    shr r10, 8
    and r10d, 0x00FF00
    add rax, r10
    shr rax, 8
    and eax, 0x00FF00
    or eax, r11d
    pop rdx
    ret

; put_px(EDI = x, ESI2: EDX = y, R8D = colour, ECX = alpha): one pixel,
; blended, if it is inside the clip. Preserves all but RAX, R10, R11.
put_px:
    cmp edi, [px_cx0]
    jl .out
    cmp edi, [px_cx1]
    jge .out
    cmp edx, [px_cy0]
    jl .out
    cmp edx, [px_cy1]
    jge .out
    push rsi
    push r9
    mov eax, edx
    imul eax, [px_stride]
    add eax, edi
    mov r9, [px_base]
    lea r9, [r9 + rax * 4]
    mov eax, [r9]
    mov esi, r8d
    call px_blend
    mov [r9], eax
    pop r9
    pop rsi
.out:
    ret

blend_rect:
    add edx, edi                        ; in pixels
    add ecx, esi
    PXX edi
    PXY esi
    PXX edx
    PXY ecx
    sub edx, edi
    sub ecx, esi
; px_blend_rect: blend_rect, in pixels
px_blend_rect:
    push rbx
    push r12
    push r13
    push r14
    lea eax, [rdi + rdx]
    lea ebx, [rsi + rcx]
    cmp edi, [px_cx0]
    cmovl edi, [px_cx0]
    cmp esi, [px_cy0]
    cmovl esi, [px_cy0]
    cmp eax, [px_cx1]
    cmovg eax, [px_cx1]
    cmp ebx, [px_cy1]
    cmovg ebx, [px_cy1]
    sub eax, edi
    jle .out
    sub ebx, esi
    jle .out
    mov r12d, eax                       ; R12D: columns; EBX: rows
    mov eax, esi
    imul eax, [px_stride]
    add eax, edi
    mov r13, [px_base]
    lea r13, [r13 + rax * 4]            ; R13: the row's first pixel
    mov esi, r8d
    mov ecx, r9d
.row:
    mov r14, r13
    mov edx, r12d
.col:
    mov eax, [r14]
    push rdx
    call px_blend
    pop rdx
    mov [r14], eax
    add r14, 4
    dec edx
    jnz .col
    mov eax, [px_stride]
    lea r13, [r13 + rax * 4]
    dec ebx
    jnz .row
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; corner_alpha(EAX = i, ECX = j, pixels in from the corner, R8D = radius)
; -> EAX = how much of that pixel the rounded corner covers, 0-255.
; Preserves all but RAX, XMM0-XMM2.
corner_alpha:
    cvtsi2sd xmm0, r8d                  ; dx = r - (i + 0.5)
    cvtsi2sd xmm1, eax
    subsd xmm0, xmm1
    subsd xmm0, [ui_half]
    cvtsi2sd xmm2, r8d                  ; dy = r - (j + 0.5)
    cvtsi2sd xmm1, ecx
    subsd xmm2, xmm1
    subsd xmm2, [ui_half]
    mulsd xmm0, xmm0
    mulsd xmm2, xmm2
    addsd xmm0, xmm2
    sqrtsd xmm0, xmm0                   ; the distance from the centre
    cvtsi2sd xmm1, r8d
    addsd xmm1, [ui_half]
    subsd xmm1, xmm0                    ; r + 0.5 - d, 0 to 1
    xorpd xmm2, xmm2
    maxsd xmm1, xmm2
    minsd xmm1, [ui_one]
    mulsd xmm1, [ui_255]
    cvtsd2si eax, xmm1
    ret

fill_round:
    call round_px
; px_fill_round: fill_round, in pixels
px_fill_round:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                       ; R12D, R13D: where; R14D, R15D: the size
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r9d                        ; EBX: the colour
    mov eax, r14d                       ; the radius, at most half of each side
    shr eax, 1
    cmp r8d, eax
    jbe .r_w
    mov r8d, eax
.r_w:
    mov eax, r15d
    shr eax, 1
    cmp r8d, eax
    jbe .r_h
    mov r8d, eax
.r_h:
    mov ebp, r8d                        ; EBP: the radius
    mov edi, r12d                       ; the middle band, whole
    lea esi, [r13 + rbp]
    mov edx, r14d
    mov ecx, r15d
    sub ecx, ebp
    sub ecx, ebp
    mov r8d, ebx
    call px_fill_rect
    lea edi, [r12 + rbp]                ; the top and bottom bands, between the corners
    mov esi, r13d
    mov edx, r14d
    sub edx, ebp
    sub edx, ebp
    mov ecx, ebp
    mov r8d, ebx
    call px_fill_rect
    lea edi, [r12 + rbp]
    mov esi, r13d
    add esi, r15d
    sub esi, ebp
    mov edx, r14d
    sub edx, ebp
    sub edx, ebp
    mov ecx, ebp
    mov r8d, ebx
    call px_fill_rect
    test ebp, ebp
    jz .out
    xor ecx, ecx                        ; ECX: j, the corners' rows
.j:
    xor r9d, r9d                        ; R9D: i, their columns
.i:
    mov eax, r9d
    mov r8d, ebp
    call corner_alpha
    test eax, eax
    jz .i_next
    push rcx
    mov ecx, eax                        ; ECX: alpha, for the four corners
    mov r8d, ebx
    mov edx, [rsp]                      ; top left
    add edx, r13d
    lea edi, [r12 + r9]
    call put_px
    mov edi, r12d                       ; top right
    add edi, r14d
    sub edi, r9d
    dec edi
    call put_px
    mov edx, r13d                       ; bottom right
    add edx, r15d
    sub edx, [rsp]
    dec edx
    call put_px
    lea edi, [r12 + r9]                 ; bottom left
    call put_px
    pop rcx
.i_next:
    inc r9d
    cmp r9d, ebp
    jb .i
    inc ecx
    cmp ecx, ebp
    jb .j
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

frame_round:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    call round_px
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    call px_fill_round                  ; the edge's colour, all of it
    lea edi, [r12 + 1]                  ; then inside it, a pixel in
    lea esi, [r13 + 1]
    lea edx, [r14 - 2]
    lea ecx, [r15 - 2]
    lea r8d, [rbx - 1]
    test r8d, r8d
    jns .r
    xor r8d, r8d
.r:
    mov r9d, [ui_fill]
    call px_fill_round
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

shadow:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 8
    call round_px
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r8d
    xor ebx, ebx                        ; EBX: the layer, 3 out to 1 in
.layer:
    cmp ebx, 3
    jae .out
    mov eax, 3                          ; each layer d = 3 - EBX pixels out
    sub eax, ebx
    mov edi, r12d
    sub edi, eax
    lea esi, [r13 + 1]
    sub esi, eax
    add esi, eax                        ; a little lower than it is wide
    mov edx, r14d
    lea edx, [rdx + rax * 2]
    mov ecx, r15d
    lea ecx, [rcx + rax * 2]
    lea r8d, [rbp + rax]
    lea r9, [shadow_alpha]
    movzx r9d, byte [r9 + rbx]
    mov [ui_alpha], r9d
    call round_blend
    inc ebx
    jmp .layer
.out:
    add rsp, 8
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; round_blend(EDI, ESI, EDX, ECX, R8D = radius; [ui_alpha]): black at that
; alpha over a rounded rectangle, roughly (its corners left out)
round_blend:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    shr ebx, 1                          ; corners cut by half the radius
    lea edi, [r12 + rbx]                ; the top band
    mov esi, r13d
    mov edx, r14d
    sub edx, ebx
    sub edx, ebx
    mov ecx, ebx
    mov r8d, C_BLACK
    mov r9d, [ui_alpha]
    call px_blend_rect
    mov edi, r12d                       ; the middle
    lea esi, [r13 + rbx]
    mov edx, r14d
    mov ecx, r15d
    sub ecx, ebx
    sub ecx, ebx
    mov r8d, C_BLACK
    mov r9d, [ui_alpha]
    call px_blend_rect
    lea edi, [r12 + rbx]                ; the bottom band
    mov esi, r13d
    add esi, r15d
    sub esi, ebx
    mov edx, r14d
    sub edx, ebx
    sub edx, ebx
    mov ecx, ebx
    mov r8d, C_BLACK
    mov r9d, [ui_alpha]
    call px_blend_rect
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; field(EDI, ESI, EDX, ECX, R8D = 1 if it has the keys): a text field's
; box, the desktop's (kit_field)
field:
    mov r9d, r8d
    xor r8d, r8d
    call round_px
    mov r8d, r9d
    jmp kit_field

; round_px(EDI, ESI, EDX, ECX, R8D = radius, points) -> the same, pixels.
; Preserves all but those.
round_px:
    add edx, edi
    add ecx, esi
    PXX edi
    PXY esi
    PXX edx
    PXY ecx
    sub edx, edi
    sub ecx, esi
    imul r8d, [g_s]
    add r8d, 2
    sar r8d, 2
    ret

; baseline_mid(R8D = a font, ESI = the middle of a line) -> EDX = the
; baseline that centres capitals there. Preserves all but RDX, R11.
baseline_mid:
    push rax
    cmp r8d, UIF
    jae .ui
    mov edx, r8d
    call font_entry
    mov eax, [r11 + WFT_ASCENT]
    sub eax, [r11 + WFT_DESCENT]
    shr eax, 1
    lea edx, [rsi + rax]
    pop rax
    ret
.ui:
    call ui_cap
    shr eax, 1
    lea edx, [rsi + rax]
    pop rax
    ret

label:
    push rsi
    mov esi, [ui_mid]
    call baseline_mid
    pop rsi
    xor r10d, r10d
    jmp draw_text

label_c:
    push rdi
    push r8
    mov edx, r8d
    call text_px
    pop r8
    pop rdi
    shr eax, 1
    sub edi, eax
    jmp label

bt_x:
    movzx eax, word [rdi + BT_X]
    test byte [rdi + BT_VIEWS], BV_RIGHT
    jz .out
    add eax, [win_w]
    sub eax, DEF_W
.out:
    ret

button:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 24
    mov rbx, rdi
    mov r12d, esi                       ; R12D: on; R13D: pressed
    mov r13d, edx
    call bt_x                           ; [rsp] .. [rsp+12]: where, pixels
    mov edi, eax
    movzx esi, word [rbx + BT_Y]
    movzx edx, word [rbx + BT_W]
    movzx ecx, word [rbx + BT_H]
    xor r8d, r8d
    call round_px
    mov [rsp], edi
    mov [rsp + 4], esi
    mov [rsp + 8], edx
    mov [rsp + 12], ecx
    movzx eax, byte [rbx + BT_STYLE]
    cmp eax, BS_GHOST
    je .ghost
    xor r9d, r9d                        ; the desktop's button
    cmp eax, BS_PRIMARY
    jne .down
    mov r9d, KB_DEFAULT
.down:
    mov eax, r12d
    or eax, r13d
    jz .plain
    or r9d, KB_DOWN
.plain:
    xor r8d, r8d
    call kit_button
    jmp .label
.ghost:                                 ; nothing until it is on or pressed
    mov eax, r12d
    or eax, r13d
    jz .label
    mov edi, TC_TEXT                    ; then a tint of the text's colour
    call kit_c
    and eax, 0xFFFFFF
    or eax, KA(0x22)
    test r13d, r13d
    jz .tint
    xor eax, KA(0x22) ^ KA(0x40)
.tint:
    mov ebp, eax
    mov edi, 6
    call kit_pt
    mov r8d, eax
    mov r9d, ebp
    mov edi, [rsp]
    mov esi, [rsp + 4]
    mov edx, [rsp + 8]
    mov ecx, [rsp + 12]
    call kit_round
.label:
    movzx eax, word [rbx + BT_H]        ; the label, centred
    shr eax, 1
    movzx ecx, word [rbx + BT_Y]
    add eax, ecx
    mov [ui_mid], eax
    mov rsi, [rbx + BT_LABEL]
    call cstr
    mov rdi, rbx
    call bt_x
    movzx edi, word [rbx + BT_W]
    shr edi, 1
    add edi, eax
    movzx r8d, byte [rbx + BT_FONT]
    mov r9d, C_INK
    test r12d, r12d
    jz .ink
    mov r9d, C_ACCENT_DK
.ink:
    cmp byte [rbx + BT_STYLE], BS_PRIMARY
    jne .labelled
    mov r9d, 0xFFFFFF                   ; white on the accent, light or dark
.labelled:
    call label_c
    add rsp, 24
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ui_theme(EDI = 1 if the window is dark, ESI = 1 if the document is):
; pal and dpal from those themes' colours; pal's text, lines and accent,
; and both's chosen text, from the desktop's look if there is one
ui_theme:
    push rbx
    push rsi
    lea rsi, [pal_light]
    test edi, edi
    jz .copy
    lea rsi, [pal_dark]
.copy:
    lea rdi, [pal]
    mov ecx, P_BYTES / 4
    rep movsd
    pop rax
    lea rsi, [pal_light]
    test eax, eax
    jz .copy_doc
    lea rsi, [pal_dark]
.copy_doc:
    lea rdi, [dpal]
    mov ecx, P_BYTES / 4
    rep movsd
    cmp qword [kit_lk], 0
    je .chosen
    lea rbx, [look_slots]
.slot:
    movzx edi, byte [rbx]
    cmp edi, 0xFF
    je .accent
    call kit_c
    movzx ecx, byte [rbx + 1]
    mov [pal + rcx], eax
    add rbx, 2
    jmp .slot
.accent:
    call kit_accent
    mov [pal + P_ACCENT], eax
    mov [pal + P_ACCENT_DK], eax
    mov [dpal + P_ACCENT], eax
.chosen:
    mov eax, [pal + P_PAPER]            ; what is chosen: the accent, faint
    mov esi, [pal + P_ACCENT]
    mov ecx, 0x50
    call px_blend
    mov [pal + P_SELECT], eax
    mov eax, [dpal + P_PAPER]
    mov esi, [dpal + P_ACCENT]
    mov ecx, 0x50
    call px_blend
    mov [dpal + P_SELECT], eax
    pop rbx
    ret

section .rodata
align 4
pal_light:      dd 0xF2F2F5, 0xF7F7F8, 0xD9D9DE, 0x1D1D1F, 0x6E6E73, 0xAEAEB2
                dd 0x0A84FF, 0x0060DF, 0xB4D5FE, 0xFFFFFF, 0xFFFFFF, 0xD1D1D6
                dd 0xE4EEFE, 0xE0E0E5, 0xE5E5EA, 0xF2F2F7, 0xD1D1D6, 0xE0E0E5
                dd 0xF5F5F7, 0xECECEF, 0xFBFBFD, 0xD70015
pal_dark:       dd 0x111113, 0x232326, 0x38383C, 0xEDEDF0, 0x9A9AA0, 0x5E5E64
                dd 0x0A84FF, 0x4DA3FF, 0x2A4A73, 0x1C1C1F, 0x333337, 0x48484D
                dd 0x1D3557, 0x45454A, 0x141416, 0x29292D, 0x46464B, 0x2E2E32
                dd 0x242427, 0x1A1A1D, 0x262629, 0xFF6961
align 8
ui_half:        dq 0.5
ui_one:         dq 1.0
ui_255:         dq 255.0
shadow_alpha:   db 6, 10, 18
look_slots:     db TC_TEXT, P_INK, TC_TEXT2, P_SECOND, TC_TEXT3, P_FAINT
                db TC_TITLE, P_CHROME, TC_SEP, P_HAIRLINE, TC_PANEL, P_SIDEBAR
                db 0xFF                 ; (the look's colours: pal's slots)

section .bss
alignb 4
pal:            resd P_BYTES / 4        ; the window's colours now (ui_theme)
dpal:           resd P_BYTES / 4        ; the document's
ui_fill:        resd 1
ui_mid:         resd 1
ui_alpha:       resd 1

section .text
