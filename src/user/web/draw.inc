; =============================================================================
;  web/draw.inc - text and boxes, into a window's pixels
;
;  The fonts are webfont.bin (tools/mkwebfont.py), here at wf_bin, found by
;  the tables of gen/webfont.inc. A font is a face and a size, numbered
;  face * WF_SIZES + size. With WF_DOC defined, the fonts are those and
;  twice their sizes (tools/mkdocfont.py), packed at wf_pak: the program
;  unpacks them and points wf_base at them; gen/docfont.inc has the tables.
;    font_entry(EDX = a font) -> R11 = its wf_fonts entry (WFT_*).
;      Preserves all but R11.
;    glyph_at(EAX = a code point, R11 = a font's entry) -> RAX = its glyph
;      (WG_*), the replacement if it has none. Preserves all but RAX.
;    utf8_next(RSI = at, RDX = the end) -> EAX = the code point, RSI past
;      it; a byte that is not UTF-8 is taken as Windows-1252. Preserves
;      all but RAX, RSI.
;    invisible(EAX) -> ZF if the character takes no room (soft hyphen,
;      zero-width spaces and joiners, BOM). Preserves all.
;    text_w64(RSI = text, ECX = bytes, EDX = a font) -> RAX = its advance,
;      in 1/64 pixels, each space a space. Preserves all but RAX, R11.
;  Drawing, into px_base (px_stride pixels a row, B,G,R,x), inside the clip
;  (clip_x0, clip_y0 to clip_x1, clip_y1, exclusive):
;    fill_rect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour)
;    draw_text(RSI = text, ECX = bytes, EDI = x, EDX = baseline, R8D = a
;      font, R9D = colour, R10D = DF_PRE or 0) -> EAX = the pen's x after
;      it. A run of whitespace is one space, but in DF_PRE, where each
;      space is one.
;    draw_list(EDI, ESI = where the document's top left is, in the
;      window): the display list's items (layout.inc) inside the clip
;  Glyphs are blended by their coverage over what is there.
; =============================================================================

; WF_BASE reg: where the fonts are
%macro WF_BASE 1
%ifdef WF_DOC
    mov %1, [wf_base]
%else
    lea %1, [wf_bin]
%endif
%endmacro

section .text

font_entry:
    push rdx
    movzx edx, dl
    imul edx, edx, WFT_SIZE
    lea r11, [wf_fonts + rdx]
    pop rdx
    ret

glyph_at:
    push rcx
    push rdx
    push r8
    cmp eax, 256
    jae .high
    movzx eax, word [wf_low + rax * 2]
    jmp .got
.high:                                  ; wf_high, by halves
    xor ecx, ecx
    mov edx, WF_HIGH
.search:
    cmp ecx, edx
    jae .none
    lea r8d, [rcx + rdx]
    shr r8d, 1
    cmp eax, [wf_high + r8 * 8]
    je .found
    jb .lower
    lea ecx, [r8 + 1]
    jmp .search
.lower:
    mov edx, r8d
    jmp .search
.found:
    mov eax, [wf_high + r8 * 8 + 4]
    jmp .got
.none:
    xor eax, eax
.got:
    imul eax, eax, WG_SIZE
    add rax, [r11 + WFT_GLYPHS]
    WF_BASE rcx
    add rax, rcx
    pop r8
    pop rdx
    pop rcx
    ret

utf8_next:
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, 0x80
    jb .ascii
    push rcx
    push r8
    push r9
    push r10
    cmp eax, 0xC2                       ; a continuation, or overlong
    jb .single
    mov r8d, eax                        ; R8D: the code point so far
    and r8d, 0x1F
    mov ecx, 1                          ; ECX: continuation bytes
    cmp eax, 0xE0
    jb .cont
    mov r8d, eax
    and r8d, 0x0F
    mov ecx, 2
    cmp eax, 0xF0
    jb .cont
    mov r8d, eax
    and r8d, 0x07
    mov ecx, 3
    cmp eax, 0xF5
    jae .single
.cont:
    mov r9, rsi
.byte:
    cmp r9, rdx
    jae .single
    movzx r10d, byte [r9]
    xor r10d, 0x80
    cmp r10d, 0x3F
    ja .single
    shl r8d, 6
    or r8d, r10d
    inc r9
    dec ecx
    jnz .byte
    mov rsi, r9
    mov eax, r8d
    jmp .done
.single:                                ; the byte alone, as Windows-1252
    cmp eax, 0xA0
    jae .done
    lea rcx, [cp1252]
    movzx eax, word [rcx + rax * 2 - 0x100]
.done:
    pop r10
    pop r9
    pop r8
    pop rcx
.ascii:
    ret

invisible:
    cmp eax, 0xAD
    je .out
    cmp eax, 0xFEFF
    je .out
    cmp eax, 0x2060
    je .out
    push rax
    sub eax, 0x200B                     ; U+200B..U+200F
    cmp eax, 4
    ja .no
    cmp eax, eax
    pop rax
    ret
.no:
    pop rax                             ; ZF clear still
.out:
    ret

text_w64:
    push rbx
    push rdx
    push rsi
    call font_entry
    lea rdx, [rsi + rcx]
    xor ebx, ebx
.char:
    cmp rsi, rdx
    jae .done
    call utf8_next
    call invisible
    je .char
    call glyph_at
    movzx eax, word [rax + WG_ADV]
    add rbx, rax
    jmp .char
.done:
    mov rax, rbx
    pop rsi
    pop rdx
    pop rbx
    ret

fill_rect:
    push rbx
    lea eax, [rdi + rdx]                ; EAX, EBX: the far corner
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
    mov edx, esi
    imul edx, [px_stride]
    add edx, edi
    mov rsi, [px_base]
    lea rsi, [rsi + rdx * 4]            ; RSI: the row's first pixel
    mov edx, eax
.row:
    mov rdi, rsi
    mov ecx, edx
    mov eax, r8d
    rep stosd
    mov eax, [px_stride]
    lea rsi, [rsi + rax * 4]
    dec ebx
    jnz .row
.out:
    pop rbx
    ret

draw_text:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12: at; R13: the end
    lea r13, [rsi + rcx]
    mov r14d, edi                       ; R14D: the pen, 1/64 pixels
    shl r14d, 6
    mov r15d, edx                       ; R15D: the baseline
    mov ebp, r10d                       ; EBP: DF_*
    mov ebx, r9d                        ; EBX: the colour
    mov edx, r8d
    call font_entry
    mov [dt_font], r11
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
    mov r11, [dt_font]
    call glyph_at
    push rax
    mov edi, r14d
    sar edi, 6
    mov esi, r15d
    call blit
    pop rax
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

; blit(RAX = a glyph, EDI = the pen's x, ESI = the baseline, EBX = colour):
; its coverage blended into the pixels, inside the clip. Preserves RBX,
; RBP, R12-R15.
blit:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    movzx r8d, byte [rax + WG_W]        ; R8D: its width
    movzx r9d, byte [rax + WG_H]
    test r8d, r8d
    jz .out
    test r9d, r9d
    jz .out
    movsx ecx, byte [rax + WG_LEFT]     ; EDI, ESI: its top left
    add edi, ecx
    movsx ecx, byte [rax + WG_TOP]
    sub esi, ecx
    mov r10d, [rax + WG_DATA]           ; R10: its coverage
    WF_BASE rcx
    add r10, rcx
    xor r12d, r12d                      ; columns [R12D, R13D) of it
    mov eax, [clip_x0]
    sub eax, edi
    cmp eax, r12d
    cmovg r12d, eax
    mov r13d, r8d
    mov eax, [clip_x1]
    sub eax, edi
    cmp eax, r13d
    cmovl r13d, eax
    cmp r12d, r13d
    jge .out
    xor r14d, r14d                      ; rows [R14D, R15D)
    mov eax, [clip_y0]
    sub eax, esi
    cmp eax, r14d
    cmovg r14d, eax
    mov r15d, r9d
    mov eax, [clip_y1]
    sub eax, esi
    cmp eax, r15d
    cmovl r15d, eax
    cmp r14d, r15d
    jge .out
    mov [rsp], r12d                     ; the columns, kept
    mov [rsp + 4], r13d
.row:
    lea eax, [rsi + r14]                ; RBP: the pixel at its first column
    imul eax, [px_stride]
    add eax, edi
    add eax, [rsp]
    mov rbp, [px_base]
    lea rbp, [rbp + rax * 4]
    mov eax, r14d                       ; R9: its coverage there
    imul eax, r8d
    add eax, [rsp]
    lea r9, [r10 + rax]
    mov edx, [rsp + 4]                  ; EDX: how many
    sub edx, [rsp]
.column:
    movzx ecx, byte [r9]
    test ecx, ecx
    jz .next
    cmp ecx, 255
    je .solid
    mov eax, [rbp]                      ; colour * a + what is there * (255 - a),
    mov r11d, eax                       ; by /255, two channels at a time
    and r11d, 0xFF00FF
    and eax, 0x00FF00
    mov r12d, 255
    sub r12d, ecx
    imul r11, r12
    imul rax, r12
    mov r12d, ebx
    and r12d, 0xFF00FF
    imul r12, rcx
    add r11, r12
    mov r12d, ebx
    and r12d, 0x00FF00
    imul r12, rcx
    add rax, r12
    add r11, 0x800080
    add rax, 0x008000
    mov r12, r11
    shr r12, 8
    and r12d, 0xFF00FF
    add r11, r12
    shr r11, 8
    and r11d, 0xFF00FF
    mov r12, rax
    shr r12, 8
    and r12d, 0x00FF00
    add rax, r12
    shr rax, 8
    and eax, 0x00FF00
    or eax, r11d
    mov [rbp], eax
    jmp .next
.solid:
    mov [rbp], ebx
.next:
    inc r9
    add rbp, 4
    dec edx
    jnz .column
    inc r14d
    cmp r14d, r15d
    jb .row
.out:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
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
    movzx edx, byte [rbx + DI_FONT]     ; R14D: the baseline, here
    call font_entry
    mov r14d, [rbx + DI_Y]
    add r14d, r13d
    mov eax, r14d                       ; nothing of it inside: past it
    add eax, [r11 + WFT_DESCENT]
    cmp eax, [clip_y0]
    jle .next
    mov eax, r14d
    sub eax, [r11 + WFT_ASCENT]
    cmp eax, [clip_y1]
    jge .next
    mov r15, r11
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

section .rodata
%ifdef WF_DOC                           ; compose's: twice the sizes too, packed
%include "gen/docfont.inc"
wf_pak:         incbin "gen/docfont.pak"
wf_pak_end:
%else
%include "gen/webfont.inc"
align 16
wf_bin:         incbin "gen/webfont.bin"
%endif

section .bss
alignb 8
px_base:        resq 1
dt_font:        resq 1
px_stride:      resd 1
clip_x0:        resd 1
clip_y0:        resd 1
clip_x1:        resd 1
clip_y1:        resd 1

section .text
