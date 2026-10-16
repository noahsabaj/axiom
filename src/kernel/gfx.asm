; =============================================================================
;  gfx.asm - framebuffer, back buffer, rectangles and anti-aliased text
;
;  Everything draws into a back buffer in ordinary RAM; gfx_blit* copy
;  rectangles to the write-combining framebuffer. Pixels are dwords
;  0x00RRGGBB (bytes B,G,R,x). An R,G,B,x framebuffer is swapped while
;  blitting. Drawing is meant for one CPU at a time.
; =============================================================================

section .text

gfx_init:
    push rbx
    mov rbx, [boot_info]
    mov eax, [rbx + BI_FB_WIDTH]
    mov [scr_w], rax
    mov eax, [rbx + BI_FB_HEIGHT]
    mov [scr_h], rax
    mov eax, [rbx + BI_FB_PITCH]
    shl rax, 2
    mov [scr_pitch], rax
    mov rax, [rbx + BI_FB_PHYS]
    and eax, 0xFFF
    mov rcx, FB_VIRT
    add rax, rcx
    mov [fb_ptr], rax
    cmp dword [rbx + BI_FB_FORMAT], 0
    sete byte [fb_swap]

    mov rax, [scr_pitch]                ; back buffer, one spare row for overdraw
    mov rcx, [scr_h]
    inc rcx
    mul rcx
    mov [bb_bytes], rax
    add rax, 0xFFF
    shr rax, 12
    mov rdi, rax
    call pmm_alloc
    test rax, rax
    jz .no_memory
    add rax, [phys_base]
    mov [bb_ptr], rax

    xor ecx, ecx                        ; largest font that still gives 50 rows
    xor r8d, r8d
.font_loop:
    cmp r8d, FONT_SIZES
    jae .font_done
    mov eax, r8d
    shl eax, 4
    lea rsi, [font_sizes]
    mov r9d, [rsi + rax + 12]
    mov rax, [scr_h]
    xor edx, edx
    div r9
    cmp rax, 50
    jb .font_next
    mov ecx, r8d
.font_next:
    inc r8d
    jmp .font_loop
.font_done:
    mov edi, ecx
    call gfx_set_font
    mov byte [gfx_ready], 1
    pop rbx
    ret
.no_memory:
    xor edi, edi
    lea rsi, [str_no_backbuffer]
    jmp panic

; gfx_set_font(EDI = size index). Preserves all.
gfx_set_font:
    push rax
    push rsi
    mov [font_index], rdi
    mov eax, edi
    shl eax, 4
    lea rsi, [font_sizes]
    add rsi, rax
    mov rax, [rsi]
    add rax, font_data
    mov [font_glyphs], rax
    mov eax, [rsi + 8]
    mov [font_cw], rax
    mov eax, [rsi + 12]
    mov [font_ch], rax
    imul eax, [rsi + 8]
    mov [font_glyph_bytes], rax
    pop rsi
    pop rax
    ret

; -----------------------------------------------------------------------------
;  clip(RDI x, RSI y, RDX w, RCX h) -> clipped in place; ZF set when empty
; -----------------------------------------------------------------------------
gfx_clip:
    cmp rdi, [scr_w]
    jae .empty
    cmp rsi, [scr_h]
    jae .empty
    mov rax, [scr_w]
    sub rax, rdi
    cmp rdx, rax
    cmova rdx, rax
    mov rax, [scr_h]
    sub rax, rsi
    cmp rcx, rax
    cmova rcx, rax
    test rdx, rdx
    jz .empty
    test rcx, rcx
    ret
.empty:
    xor eax, eax                        ; ZF = 1
    ret

; gfx_fill(RDI x, RSI y, RDX w, RCX h, R8D color). Preserves all.
gfx_fill:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    call gfx_clip
    jz .out
    mov rax, rsi
    imul rax, [scr_pitch]
    lea r9, [rax + rdi * 4]
    add r9, [bb_ptr]                    ; first pixel
    mov r10, rcx                        ; rows
    mov eax, r8d
.row:
    mov rdi, r9
    mov rcx, rdx
    rep stosd
    add r9, [scr_pitch]
    dec r10
    jnz .row
.out:
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; gfx_blit(RDI x, RSI y, RDX w, RCX h): back buffer -> screen, with the mouse
; cursor kept on top. Preserves all.
gfx_blit:
    call gfx_blit_raw
    jmp cursor_overlay

; gfx_blit_raw: the same, without the cursor
gfx_blit_raw:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call gfx_clip
    jz .out
    mov rax, rsi
    imul rax, [scr_pitch]
    lea r8, [rax + rdi * 4]             ; byte offset of the first pixel
    mov r10, rcx                        ; rows
    shl rdx, 2                          ; bytes per row
.row:
    mov rsi, [bb_ptr]
    add rsi, r8
    mov rdi, [fb_ptr]
    add rdi, r8
    mov rcx, rdx
    cmp byte [fb_swap], 0
    jne .swapped
    rep movsb
    jmp .next
.swapped:
    shr rcx, 2
.swap_px:
    lodsd
    mov r11d, eax                       ; 00RRGGBB -> 00BBGGRR
    bswap eax
    shr eax, 8
    and r11d, 0x0000FF00
    and eax, 0x00FF00FF
    or eax, r11d
    stosd
    dec rcx
    jnz .swap_px
.next:
    add r8, [scr_pitch]
    dec r10
    jnz .row
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

gfx_blit_all:
    push rdi
    push rsi
    push rdx
    push rcx
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    call gfx_blit
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; -----------------------------------------------------------------------------
;  Text
; -----------------------------------------------------------------------------

; gfx_color(EDI fg, ESI bg): bg = GFX_CLEAR draws without a background.
; Preserves all.
GFX_CLEAR       equ 0xFFFFFFFF
gfx_color:
    cmp edi, [text_fg]
    jne .changed
    cmp esi, [text_bg]
    jne .changed
    ret
.changed:
    mov [text_fg], edi
    mov [text_bg], esi
    cmp esi, GFX_CLEAR
    je .done
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    xor r8d, r8d                        ; alpha 0..255
.alpha:
    xor r10d, r10d                      ; result pixel
    mov ecx, 16                         ; channel shift: 16, 8, 0
.channel:
    mov eax, [text_fg]
    shr eax, cl
    and eax, 0xFF
    imul eax, r8d                       ; fg * a
    mov ebx, [text_bg]
    shr ebx, cl
    and ebx, 0xFF
    mov r9d, 255
    sub r9d, r8d
    imul ebx, r9d                       ; bg * (255 - a)
    add eax, ebx
    add eax, 127
    imul eax, eax, 0x8081               ; / 255
    shr eax, 23
    shl eax, cl
    or r10d, eax
    sub ecx, 8
    jns .channel
    lea rax, [text_ramp]
    mov [rax + r8 * 4], r10d
    inc r8d
    cmp r8d, 256
    jb .alpha
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
.done:
    ret

; gfx_glyph(RDI x, RSI y, EDX character). Preserves all.
gfx_glyph:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    movzx edx, dl
    cmp edx, 32
    jb .unknown
    cmp edx, 127
    jb .ascii
    sub edx, FONT_EXTRA_BASE
    jb .unknown
    cmp edx, FONT_EXTRAS
    jae .unknown
    add edx, 95
    jmp .index
.unknown:
    mov edx, '?'
.ascii:
    sub edx, 32
.index:
    mov rax, [scr_w]                    ; whole glyph must fit
    sub rax, [font_cw]
    cmp rdi, rax
    ja .out
    mov rax, [scr_h]
    sub rax, [font_ch]
    cmp rsi, rax
    ja .out
    imul rdx, [font_glyph_bytes]
    add rdx, [font_glyphs]              ; coverage bytes
    mov rax, rsi
    imul rax, [scr_pitch]
    lea r8, [rax + rdi * 4]
    add r8, [bb_ptr]                    ; destination
    mov r9, [font_ch]
    lea r11, [text_ramp]
    cmp dword [text_bg], GFX_CLEAR
    je .blend_row
.opaque_row:
    mov rcx, [font_cw]
    mov rdi, r8
.opaque_px:
    movzx eax, byte [rdx]
    mov eax, [r11 + rax * 4]
    mov [rdi], eax
    inc rdx
    add rdi, 4
    dec rcx
    jnz .opaque_px
    add r8, [scr_pitch]
    dec r9
    jnz .opaque_row
    jmp .out
.blend_row:
    mov rcx, [font_cw]
    mov rdi, r8
.blend_px:
    movzx r10d, byte [rdx]
    test r10d, r10d
    jz .blend_next
    cmp r10d, 255
    jne .blend_mix
    mov eax, [text_fg]
    mov [rdi], eax
    jmp .blend_next
.blend_mix:
    push rcx
    push rdx
    xor ebx, ebx
    mov ecx, 16
.blend_channel:
    mov eax, [text_fg]
    shr eax, cl
    and eax, 0xFF
    imul eax, r10d
    mov edx, [rdi]
    shr edx, cl
    and edx, 0xFF
    mov esi, 255
    sub esi, r10d
    imul edx, esi
    add eax, edx
    add eax, 127
    imul eax, eax, 0x8081
    shr eax, 23
    shl eax, cl
    or ebx, eax
    sub ecx, 8
    jns .blend_channel
    mov [rdi], ebx
    pop rdx
    pop rcx
.blend_next:
    inc rdx
    add rdi, 4
    dec rcx
    jnz .blend_px
    add r8, [scr_pitch]
    dec r9
    jnz .blend_row
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; gfx_text(RDI x, RSI y, RDX string) -> RAX = x after the text. Preserves others.
gfx_text:
    push rdx
    push rdi
.next:
    movzx eax, byte [rdx]
    test eax, eax
    jz .done
    push rdx
    mov edx, eax
    call gfx_glyph
    pop rdx
    add rdi, [font_cw]
    inc rdx
    jmp .next
.done:
    mov rax, rdi
    pop rdi
    pop rdx
    ret

; gfx_text_width(RDI string) -> RAX pixels
gfx_text_width:
    call strlen
    imul rax, [font_cw]
    ret

section .rodata
str_no_backbuffer: db 'Not enough memory for the screen back buffer', 0

section .data
align 8
text_fg:        dd 0xFFFFFFFE
text_bg:        dd 0xFFFFFFFE
gfx_ready:      db 0
fb_swap:        db 0

section .bss
alignb 8
scr_w:          resq 1
scr_h:          resq 1
scr_pitch:      resq 1                  ; bytes per scanline
fb_ptr:         resq 1                  ; write-combining mapping
bb_ptr:         resq 1                  ; back buffer
bb_bytes:       resq 1
font_index:     resq 1
font_glyphs:    resq 1
font_cw:        resq 1
font_ch:        resq 1
font_glyph_bytes: resq 1
alignb 16
text_ramp:      resd 256
