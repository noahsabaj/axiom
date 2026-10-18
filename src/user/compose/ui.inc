; =============================================================================
;  compose/ui.inc - what compose's controls are drawn with, over web/draw.inc
;  (px_base, px_stride, the clip): blended rectangles, rounded ones with
;  anti-aliased corners, labels, buttons. All of compose's look is here and
;  in the colours below, so it can follow the desktop's shared widgets and
;  themes when they come.
;    blend_rect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour, R9D =
;      alpha 0-255)
;    fill_round(EDI, ESI, EDX, ECX, R8D = radius, R9D = colour)
;    frame_round(EDI, ESI, EDX, ECX, R8D = radius, R9D = edge colour,
;      [ui_fill] = the colour inside): an edge a pixel wide
;    shadow(EDI, ESI, EDX, ECX, R8D = radius): soft, under a card
;    text_px(RSI = text, ECX = bytes, EDX = a font) -> EAX = its width in
;      pixels. Preserves all but RAX, R11.
;    label(RSI, ECX, EDI = x, ESI2 = [ui_mid] the line's middle, R8D = font,
;      R9D = colour) -> EAX = the x after it: text centred on a line
;    label_c(RSI, ECX, EDI = the centre's x, R8D, R9D): likewise, centred
;    button(RDI = a BT_* entry, ESI = 1 if it is on, EDX = 1 if pressed)
;  Each preserves RBX, RBP, R12-R15.
; =============================================================================

; colours: compose's theme
C_WINDOW        equ 0xF2F2F5            ; behind the pages
C_CHROME        equ 0xF7F7F8            ; the toolbar, the status line
C_HAIRLINE      equ 0xD9D9DE
C_INK           equ 0x1D1D1F
C_SECOND        equ 0x6E6E73
C_FAINT         equ 0xAEAEB2
C_ACCENT        equ 0x0A84FF            ; the system blue
C_ACCENT_DK     equ 0x0060DF
C_SELECT        equ 0xB4D5FE            ; text chosen
C_PAPER         equ 0xFFFFFF
C_BUTTON        equ 0xFFFFFF
C_BUTTON_EDGE   equ 0xD1D1D6
C_BUTTON_ON     equ 0xE4EEFE
C_PRESSED       equ 0xE0E0E5
C_SEG_TRACK     equ 0xE5E5EA
C_TABLE_HEAD    equ 0xF2F2F7
C_TABLE_LINE    equ 0xD1D1D6
C_GRID_LINE     equ 0xE0E0E5
C_GRID_HEAD     equ 0xF5F5F7
C_SIDEBAR       equ 0xECECEF
C_BLACK         equ 0x000000

UI_FONT         equ WF_SANS * WF_SIZES + WF_PX16
UI_BOLD         equ WF_BOLD * WF_SIZES + WF_PX16
UI_SMALL        equ WF_SANS * WF_SIZES + WF_PX13

; a button: where, its size, what it does, its label
BT_X            equ 0                   ; word
BT_Y            equ 2
BT_W            equ 4
BT_H            equ 6
BT_ACT          equ 8                   ; byte: ACT_*
BT_VIEWS        equ 9                   ; byte: 1 << the views it is in
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
    cmp edi, [clip_x0]
    jl .out
    cmp edi, [clip_x1]
    jge .out
    cmp edx, [clip_y0]
    jl .out
    cmp edx, [clip_y1]
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
    push rbx
    push r12
    push r13
    push r14
    lea eax, [rdi + rdx]
    lea ebx, [rsi + rcx]
    cmp edi, [clip_x0]
    cmovl edi, [clip_x0]
    cmp esi, [clip_y0]
    cmovl esi, [clip_y0]
    cmp eax, [clip_x1]
    cmovg eax, [clip_x1]
    cmp ebx, [clip_y1]
    cmovg ebx, [clip_y1]
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
    call fill_rect
    lea edi, [r12 + rbp]                ; the top and bottom bands, between the corners
    mov esi, r13d
    mov edx, r14d
    sub edx, ebp
    sub edx, ebp
    mov ecx, ebp
    mov r8d, ebx
    call fill_rect
    lea edi, [r12 + rbp]
    mov esi, r13d
    add esi, r15d
    sub esi, ebp
    mov edx, r14d
    sub edx, ebp
    sub edx, ebp
    mov ecx, ebp
    mov r8d, ebx
    call fill_rect
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
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    call fill_round                     ; the edge's colour, all of it
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
    call fill_round
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
    call blend_rect
    mov edi, r12d                       ; the middle
    lea esi, [r13 + rbx]
    mov edx, r14d
    mov ecx, r15d
    sub ecx, ebx
    sub ecx, ebx
    mov r8d, C_BLACK
    mov r9d, [ui_alpha]
    call blend_rect
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
    call blend_rect
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

text_px:
    call text_w64
    add rax, 63
    shr rax, 6
    ret

; baseline_mid(R8D = a font, ESI = the middle of a line) -> EDX = the
; baseline that centres capitals there. Preserves all but RDX, R11.
baseline_mid:
    push rax
    mov edx, r8d
    call font_entry
    mov eax, [r11 + WFT_ASCENT]
    sub eax, [r11 + WFT_DESCENT]
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

button:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi                       ; R12D: on; R13D: pressed
    mov r13d, edx
    movzx eax, byte [rbx + BT_STYLE]
    cmp eax, BS_PRIMARY
    je .primary
    mov r14d, C_BUTTON                  ; R14D: its fill; R15D: its edge
    mov r15d, C_BUTTON_EDGE
    cmp eax, BS_GHOST
    jne .state
    mov r14d, C_CHROME
    mov r15d, C_CHROME
.state:
    test r12d, r12d
    jz .pressed
    mov r14d, C_BUTTON_ON
    mov r15d, C_BUTTON_ON
.pressed:
    test r13d, r13d
    jz .draw
    mov r14d, C_PRESSED
    mov r15d, C_PRESSED
    jmp .draw
.primary:
    mov r14d, C_ACCENT
    mov r15d, C_ACCENT
    test r13d, r13d
    jz .draw
    mov r14d, C_ACCENT_DK
    mov r15d, C_ACCENT_DK
.draw:
    mov [ui_fill], r14d
    movzx edi, word [rbx + BT_X]
    movzx esi, word [rbx + BT_Y]
    movzx edx, word [rbx + BT_W]
    movzx ecx, word [rbx + BT_H]
    mov r8d, 7
    mov r9d, r15d
    call frame_round
    movzx eax, word [rbx + BT_H]        ; the label, centred
    shr eax, 1
    movzx ecx, word [rbx + BT_Y]
    add eax, ecx
    mov [ui_mid], eax
    mov rsi, [rbx + BT_LABEL]
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .len_done
    inc ecx
    jmp .len
.len_done:
    movzx edi, word [rbx + BT_W]
    shr edi, 1
    movzx eax, word [rbx + BT_X]
    add edi, eax
    movzx r8d, byte [rbx + BT_FONT]
    mov r9d, C_INK
    test r12d, r12d
    jz .ink
    mov r9d, C_ACCENT_DK
.ink:
    cmp byte [rbx + BT_STYLE], BS_PRIMARY
    jne .labelled
    mov r9d, C_PAPER
.labelled:
    call label_c
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
align 8
ui_half:        dq 0.5
ui_one:         dq 1.0
ui_255:         dq 255.0
shadow_alpha:   db 6, 10, 18

section .bss
alignb 4
ui_fill:        resd 1
ui_mid:         resd 1
ui_alpha:       resd 1

section .text
