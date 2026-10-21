; =============================================================================
;  compose/draw.inc - compose's drawing, in points: web/draw.inc's fonts and
;  glyphs (with WF_DOC: its sizes and twice them, gen/docfont.*), drawn at a
;  scale; and the desktop's own font (kit.inc's) for compose's controls
;
;  Everything compose lays out and draws is in points, as it always was; a
;  point is g_s quarters of a pixel (4: one pixel, 8: two, the desktop's
;  scale), from a pixel origin (g_ox, g_oy). Text keeps the advances of its
;  font at its own size, so it is laid out the same at any scale, and is
;  drawn in that face at the size nearest its size scaled (fmap).
;  web/draw.inc's own fill_rect, draw_text and draw_list are px_fill_rect,
;  px_draw_text and px_draw_list here, in pixels, and its clip (pixels too)
;  px_cx0, px_cy0 to px_cx1, px_cy1.
;    font_unpack(RDI = WF_BYTES of memory): the fonts unpacked into it,
;      first of all (they are packed, docfont.pak, a program being 16 MiB
;      at most)
;    scale_set(EDI = quarters of a pixel a point, at most S_MAX, ESI, EDX =
;      the origin, pixels), first, before anything is drawn. Preserves all.
;    target(RDI = pixels, ESI = pixels a row, EDX = width, ECX = height,
;      pixels): where drawing goes, all of it the clip. Preserves all.
;    clip(EDI = x0, ESI = y0, EDX = x1, ECX = y1, points): the clip, inside
;      the target (and kit.inc's, the same). Preserves all.
;    fill_rect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour)
;    draw_text(RSI = text, ECX = bytes, EDI = x, EDX = baseline, R8D = a
;      font, R9D = colour, R10D = DF_PRE or 0) -> EAX = the x after it
;    text_px(RSI = text, ECX = bytes, EDX = a font) -> EAX = its width.
;      Preserves all but RAX, R11 (and, for a UI_* font, those kit_text_w
;      does not keep).
;    draw_list(EDI, ESI = where the document's top left is): the display
;      list's items (layout.inc) inside the clip
;  A font is web/draw.inc's (face * WF_SIZES + size), or a UI font
;  (UIF + points, + UIF_BOLD for the semibold): the desktop's (kit.inc), in
;  the main window only.
; =============================================================================

%define WF_DOC
%define fill_rect px_fill_rect
%define draw_text px_draw_text
%define draw_list px_draw_list
%define clip_x0 px_cx0
%define clip_y0 px_cy0
%define clip_x1 px_cx1
%define clip_y1 px_cy1
%include "web/draw.inc"
%undef fill_rect
%undef draw_text
%undef draw_list
%undef clip_x0
%undef clip_y0
%undef clip_x1
%undef clip_y1

S_MAX           equ 8                   ; twice: the largest docfont.bin has
UIF             equ 0x80                ; a UI font: UIF + points (to 63)
UIF_BOLD        equ 0x40
WF_FONTS        equ WF_FACES * WF_SIZES

; PXX reg, PXY reg: a point's x or y, in pixels (reg 32 bits, not RAX's
; partner in an imul). Preserves all but reg.
%macro PXX 1
    imul %1, [g_s]
    sar %1, 2
    add %1, [g_ox]
%endmacro
%macro PXY 1
    imul %1, [g_s]
    sar %1, 2
    add %1, [g_oy]
%endmacro

section .text

font_unpack:
    mov [wf_base], rdi
    lea rsi, [wf_pak]
    lea rdx, [wf_pak_end]
.next:
    cmp rsi, rdx
    jae .done
    movzx ecx, byte [rsi]
    inc rsi
    cmp ecx, 0x80
    jae .run
    inc ecx                             ; n + 1 bytes as they are
    rep movsb
    jmp .next
.run:
    sub ecx, 0x7D                       ; one byte, n - 125 times
    lodsb
    rep stosb
    jmp .next
.done:
    ret

scale_set:
    mov [g_ox], esi
    mov [g_oy], edx
    cmp edi, [g_s]
    je .out
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov [g_s], edi
    xor ecx, ecx                        ; ECX: each size
.size:
    cmp ecx, WF_SIZES
    jae .faces
    movzx eax, byte [wf_size_px + rcx]  ; EAX: it, scaled
    imul eax, edi
    add eax, 2
    shr eax, 2
    xor esi, esi                        ; ESI: the nearest so far; R8D: how far
    mov r8d, 0x7FFFFFFF
    xor edx, edx
.near:
    cmp edx, WF_SIZES
    jae .found
    movzx r9d, byte [wf_size_px + rdx]
    sub r9d, eax
    jns .abs
    neg r9d
.abs:
    cmp r9d, r8d
    jae .far
    mov r8d, r9d
    mov esi, edx
.far:
    inc edx
    jmp .near
.found:
    mov [fmap + rcx], sil
    inc ecx
    jmp .size
.faces:                                 ; the other faces: the same sizes
    mov ecx, WF_SIZES
.face:
    cmp ecx, WF_FONTS
    jae .done
    mov eax, ecx
    xor edx, edx
    mov esi, WF_SIZES
    div esi                             ; EAX: the face; EDX: the size
    movzx edx, byte [fmap + rdx]
    imul eax, eax, WF_SIZES
    add eax, edx
    mov [fmap + rcx], al
    inc ecx
    jmp .face
.done:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

target:
    mov [px_base], rdi
    mov [px_stride], esi
    mov [t_w], edx
    mov [t_h], ecx
    mov dword [px_cx0], 0
    mov dword [px_cy0], 0
    mov [px_cx1], edx
    mov [px_cy1], ecx
    jmp clip_kit

clip:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    PXX edi
    PXY esi
    PXX edx
    PXY ecx
    xor eax, eax
    test edi, edi
    cmovs edi, eax
    test esi, esi
    cmovs esi, eax
    cmp edx, [t_w]
    cmovg edx, [t_w]
    cmp ecx, [t_h]
    cmovg ecx, [t_h]
    mov [px_cx0], edi
    mov [px_cy0], esi
    mov [px_cx1], edx
    mov [px_cy1], ecx
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
; clip_kit: kit.inc's clip, the same. Preserves all.
clip_kit:
    push rax
    mov eax, [px_cx0]
    mov [kit_cx0], eax
    mov eax, [px_cy0]
    mov [kit_cy0], eax
    mov eax, [px_cx1]
    mov [kit_cx1], eax
    mov eax, [px_cy1]
    mov [kit_cy1], eax
    pop rax
    ret

fill_rect:
    add edx, edi                        ; EDX, ECX: the far corner
    add ecx, esi
    PXX edi
    PXY esi
    PXX edx
    PXY ecx
    sub edx, edi
    sub ecx, esi
    jmp px_fill_rect

; ui_font(R8D = a UI font) -> EAX = kit.inc's, nearest. Preserves all but RAX.
ui_font:
    push rdi
    push rsi
    mov edi, r8d
    and edi, UIF_BOLD - 1
    xor esi, esi
    test r8d, UIF_BOLD
    setnz sil
    call kit_font
    pop rsi
    pop rdi
    ret

; pt_of(EAX = pixels, ECX = the origin's) -> EAX = points, rounded up.
; Preserves all but RAX.
pt_of:
    push rdx
    sub eax, ecx
    shl eax, 2
    add eax, [g_s]
    dec eax
    cdq
    idiv dword [g_s]
    pop rdx
    ret

draw_text:
    cmp r8d, UIF
    jae .ui
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12: at; R13: the end
    lea r13, [rsi + rcx]
    mov r14d, edi                       ; R14D: the pen, 1/64 points
    shl r14d, 6
    mov r15d, edx                       ; R15D: the baseline, pixels
    PXY r15d
    mov ebp, r10d                       ; EBP: DF_*
    mov ebx, r9d                        ; EBX: the colour
    mov edx, r8d                        ; the font: its advances; the scaled one
    call font_entry                     ; (fmap): its glyphs
    mov [dt_font], r11
    movzx edx, byte [fmap + r8]
    call font_entry
    mov [dt_sfont], r11
.char:
    cmp r12, r13
    jae .done
    mov rsi, r12
    mov rdx, r13
    call utf8_next
    mov r12, rsi
    cmp eax, ' '
    je .space
    cmp eax, 9
    jb .glyph
    cmp eax, 13
    jbe .space
.glyph:
    call invisible
    je .char
    push rax
    mov r11, [dt_sfont]
    call glyph_at
    mov edi, r14d                       ; the pen, in pixels
    imul edi, [g_s]
    sar edi, 8
    add edi, [g_ox]
    mov esi, r15d
    call blit
    pop rax
    mov r11, [dt_font]
    call glyph_at
    movzx eax, word [rax + WG_ADV]
    add r14d, eax
    jmp .char
.space:
    test ebp, DF_PRE
    jnz .one
.collapse:                              ; the rest of the run: nothing
    cmp r12, r13
    jae .one
    movzx eax, byte [r12]
    cmp eax, ' '
    je .more
    cmp eax, 9
    jb .one
    cmp eax, 13
    ja .one
.more:
    inc r12
    jmp .collapse
.one:
    mov r11, [dt_font]
    add r14d, [r11 + WFT_SPACE]
    jmp .char
.done:
    lea eax, [r14 + 63]
    sar eax, 6
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.ui:                                    ; the desktop's font: kit_text
    PXX edi
    PXY edx
    call ui_font
    mov r8d, eax
    call kit_text
    mov ecx, [g_ox]
    jmp pt_of

text_px:
    cmp edx, UIF
    jae .ui
    call text_w64
    add rax, 63
    shr rax, 6
    ret
.ui:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r8d, edx
    call ui_font
    mov edx, eax
    call kit_text_w
    xor ecx, ecx
    call pt_of
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ui_cap(R8D = a UI font) -> EAX = its capitals' height, points. Preserves
; all but RAX, R11.
ui_cap:
    push rdx
    push rcx
    call ui_font
    mov edx, eax
    call k_fe
    mov eax, [r11 + LKF_CAP]
    xor ecx, ecx
    call pt_of
    pop rcx
    pop rdx
    ret

draw_list:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                       ; R12D, R13D: the document's origin
    mov r13d, esi
    mov rbx, [dl_base]
.item:
    cmp rbx, [dl_top]
    jae .done
    cmp byte [rbx + DI_KIND], DK_RECT
    je .rect
    mov r14d, [rbx + DI_Y]              ; R14D: the baseline, here
    add r14d, r13d
    movzx edx, byte [rbx + DI_FONT]     ; nothing of it inside: past it
    movzx edx, byte [fmap + rdx]
    call font_entry
    mov eax, r14d
    PXY eax
    mov ecx, eax
    add eax, [r11 + WFT_DESCENT]
    cmp eax, [px_cy0]
    jle .next
    sub ecx, [r11 + WFT_ASCENT]
    cmp ecx, [px_cy1]
    jge .next
    movzx edx, byte [rbx + DI_FONT]
    call font_entry
    mov r15, r11                        ; R15: the font, at its size
    mov rsi, [rbx + DI_TEXT]
    mov ecx, [rbx + DI_LEN]
    mov edi, [rbx + DI_X]
    add edi, r12d
    mov edx, r14d
    movzx r8d, byte [rbx + DI_FONT]
    mov r9d, [rbx + DI_COLOR]
    movzx r10d, word [rbx + DI_FLAGS]
    and r10d, DF_PRE
    call draw_text
    movzx eax, word [rbx + DI_FLAGS]
    test eax, DF_UNDER | DF_STRIKE
    jz .next
    mov ebp, 1                          ; EBP: the line's thickness
    cmp dword [r15 + WFT_ASCENT], 22
    jb .thin
    mov ebp, 2
.thin:
    mov esi, [r15 + WFT_DESCENT]        ; under: half the descent down
    shr esi, 1
    add esi, r14d
    test eax, DF_UNDER
    jnz .line
    mov esi, [r15 + WFT_ASCENT]         ; through: about the middle of an x
    imul esi, esi, 3
    shr esi, 3
    neg esi
    add esi, r14d
.line:
    mov edi, [rbx + DI_X]
    add edi, r12d
    mov edx, [rbx + DI_W]
    add edx, 63
    shr edx, 6
    mov ecx, ebp
    mov r8d, [rbx + DI_COLOR]
    call fill_rect
    jmp .next
.rect:
    mov edi, [rbx + DI_X]
    add edi, r12d
    mov esi, [rbx + DI_Y]
    add esi, r13d
    mov edx, [rbx + DI_W]
    mov ecx, [rbx + DI_H]
    mov r8d, [rbx + DI_COLOR]
    call fill_rect
.next:
    add rbx, DI_SIZE
    jmp .item
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .bss
alignb 8
fmap:           resb WF_FONTS           ; each font: the one drawn at g_s
g_s:            resd 1                  ; quarters of a pixel a point (0:
                                        ; scale_set not yet called)
alignb 8
wf_base:        resq 1                  ; the fonts, unpacked
dt_sfont:       resq 1
g_ox:           resd 1                  ; the origin, pixels
g_oy:           resd 1
t_w:            resd 1                  ; the target, pixels
t_h:            resd 1

section .text
