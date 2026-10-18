; =============================================================================
;  gfx.asm - framebuffer, back buffer, rectangles and anti-aliased text
;
;  Everything draws into a back buffer in ordinary RAM; gfx_blit* copy
;  rectangles to the write-combining framebuffer. Pixels are dwords
;  0x00RRGGBB (bytes B,G,R,x). An R,G,B,x framebuffer is swapped while
;  blitting. Drawing is meant for one CPU at a time.
; =============================================================================

SF_PTR          equ 0                   ; a surface: its pixels
SF_PITCH        equ 8                   ; bytes per row
SF_W            equ 16
SF_H            equ 24
SF_CAP          equ 32                  ; bytes of memory it has
SF_SIZE         equ 40

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
    mov [back_sf + SF_PTR], rax         ; the back buffer as a surface
    mov rax, [scr_pitch]
    mov [back_sf + SF_PITCH], rax
    mov rax, [scr_w]
    mov [back_sf + SF_W], rax
    mov rax, [scr_h]
    mov [back_sf + SF_H], rax
    call gfx_target_back
    call cpu_has_avx2_fma               ; fills and text 8 pixels at a time
    setnz byte [gfx_avx2]

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
;  Surfaces: what drawing goes into. The back buffer is one (back_sf); each
;  window has its own. gfx_fill and gfx_glyph draw into the target.
; -----------------------------------------------------------------------------

; gfx_target(RDI = surface): draw into it from now on. Preserves all.
gfx_target:
    push rax
    mov rax, [rdi + SF_PTR]
    mov [tg_ptr], rax
    mov rax, [rdi + SF_PITCH]
    mov [tg_pitch], rax
    mov rax, [rdi + SF_W]
    mov [tg_w], rax
    mov rax, [rdi + SF_H]
    mov [tg_h], rax
    mov [tg_cy1], rax
    mov rax, [tg_w]
    mov [tg_cx1], rax
    mov qword [tg_cx0], 0
    mov qword [tg_cy0], 0
    pop rax
    ret

; gfx_save, gfx_restore: the target, its clip and the text colors, kept
; and put back (one deep), around drawing that interrupts other drawing.
; Preserve all.
gfx_save:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [tg_ptr]
    lea rdi, [gfx_saved]
    mov ecx, 8
    rep movsq
    mov eax, [text_fg]
    mov [gfx_saved + 64], eax
    mov eax, [text_bg]
    mov [gfx_saved + 68], eax
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

gfx_restore:
    push rcx
    push rsi
    push rdi
    lea rsi, [gfx_saved]
    lea rdi, [tg_ptr]
    mov ecx, 8
    rep movsq
    mov edi, [gfx_saved + 64]
    mov esi, [gfx_saved + 68]
    call gfx_color
    pop rdi
    pop rsi
    pop rcx
    ret

; gfx_target_back: draw into the back buffer. Preserves all.
gfx_target_back:
    push rdi
    lea rdi, [back_sf]
    call gfx_target
    pop rdi
    ret

; sf_size(RDI = surface, RSI = width, RDX = height) -> CF if there is no
; memory for it (then it is as it was). Its memory grows, never shrinks;
; what it shows afterwards is undefined. Preserves all but RAX.
sf_size:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    test rsi, rsi                       ; at least a pixel
    jnz .w_ok
    inc esi
.w_ok:
    test rdx, rdx
    jnz .h_ok
    inc edx
.h_ok:
    lea rax, [rsi * 4]
    imul rax, rdx                       ; bytes
    cmp rax, [r8 + SF_CAP]
    jbe .fits
    push rsi
    push rdx
    push rax
    add rax, 0xFFFF                     ; in steps of 64 KiB
    and rax, -0x10000
    push rax
    mov rdi, rax
    call vm_alloc
    pop rcx
    test rax, rax
    jz .none
    push rax
    push rcx
    mov rdi, [r8 + SF_PTR]
    test rdi, rdi
    jz .no_old
    call vm_free
.no_old:
    pop rcx
    pop rax
    mov [r8 + SF_PTR], rax
    mov [r8 + SF_CAP], rcx
    pop rax
    pop rdx
    pop rsi
.fits:
    mov [r8 + SF_W], rsi
    mov [r8 + SF_H], rdx
    lea rax, [rsi * 4]
    mov [r8 + SF_PITCH], rax
    clc
    jmp .out
.none:
    pop rax
    pop rdx
    pop rsi
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; sf_free(RDI = surface): its memory goes. Preserves all.
sf_free:
    push rax
    push rdi
    mov rax, rdi
    mov rdi, [rax + SF_PTR]
    mov qword [rax + SF_PTR], 0
    mov qword [rax + SF_CAP], 0
    mov qword [rax + SF_W], 0
    mov qword [rax + SF_H], 0
    test rdi, rdi
    jz .out
    call vm_free
.out:
    pop rdi
    pop rax
    ret

; gfx_clip_screen: as gfx_clip, to the screen
gfx_clip_screen:
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
    xor eax, eax
    ret

; -----------------------------------------------------------------------------
;  clip(RDI x, RSI y, RDX w, RCX h) -> clipped in place to the target; ZF
;  set when empty
; -----------------------------------------------------------------------------
gfx_clip:
    push r11
    lea rax, [rdi + rdx]                ; right and bottom edges
    lea r11, [rsi + rcx]
    cmp rdi, [tg_cx0]                   ; (signed: a rectangle may start
    jge .left                           ; off the target)
    mov rdi, [tg_cx0]
.left:
    cmp rsi, [tg_cy0]
    jge .top
    mov rsi, [tg_cy0]
.top:
    cmp rax, [tg_cx1]
    jle .right
    mov rax, [tg_cx1]
.right:
    cmp r11, [tg_cy1]
    jle .bottom
    mov r11, [tg_cy1]
.bottom:
    sub rax, rdi
    jle .empty
    sub r11, rsi
    jle .empty
    mov rdx, rax
    mov rcx, r11
    pop r11
    test rdx, rdx                       ; ZF = 0
    ret
.empty:
    pop r11
    xor eax, eax                        ; ZF = 1
    ret

; gfx_set_clip(RDI x, RSI y, RDX w, RCX h): drawing into the target stays
; inside this rectangle (and the target). Preserves all.
gfx_set_clip:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    mov qword [tg_cx0], 0
    mov qword [tg_cy0], 0
    mov rax, [tg_w]
    mov [tg_cx1], rax
    mov rax, [tg_h]
    mov [tg_cy1], rax
    call gfx_clip
    jnz .set
    xor edx, edx                        ; nothing
    xor ecx, ecx
.set:
    mov [tg_cx0], rdi
    mov [tg_cy0], rsi
    add rdi, rdx
    mov [tg_cx1], rdi
    add rsi, rcx
    mov [tg_cy1], rsi
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
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
    imul rax, [tg_pitch]
    lea r9, [rax + rdi * 4]
    add r9, [tg_ptr]                    ; first pixel
    mov r10, rcx                        ; rows
    mov eax, r8d
    cmp rdx, 8
    jb .row
    cmp byte [gfx_avx2], 0
    jne .wide
.row:
    mov rdi, r9
    mov rcx, rdx
    rep stosd
    add r9, [tg_pitch]
    dec r10
    jnz .row
    jmp .out
.wide:                                  ; 8 pixels or more: 8 at a time, the
    vmovd xmm0, r8d                     ; last 8 overlapping what came before
    vpbroadcastd ymm0, xmm0
    lea rdx, [rdx * 4 - 32]             ; RDX = where the last 8 start
.wide_row:
    mov rdi, r9
    lea rcx, [r9 + rdx]
    lea rsi, [rcx - 96]                 ; 32 more fit while RDI <= RSI
.wide_4:
    cmp rdi, rsi
    ja .wide_1
    vmovdqu [rdi], ymm0
    vmovdqu [rdi + 32], ymm0
    vmovdqu [rdi + 64], ymm0
    vmovdqu [rdi + 96], ymm0
    sub rdi, -128
    jmp .wide_4
.wide_1:
    cmp rdi, rcx
    jae .wide_last
    vmovdqu [rdi], ymm0
    add rdi, 32
    jmp .wide_1
.wide_last:
    vmovdqu [rcx], ymm0
    add r9, [tg_pitch]
    dec r10
    jnz .wide_row
    vzeroupper
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
    call gfx_clip_screen
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
    mov byte [ramp_stale], 1            ; made when a glyph needs it
    ret

; gfx_ramp: text_ramp[a] = fg over bg at coverage a, for gfx_glyph's
; pixel-at-a-time way. Preserves all.
gfx_ramp:
    mov byte [ramp_stale], 0
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
    push r12
    push r13
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
    imul rdx, [font_glyph_bytes]
    add rdx, [font_glyphs]              ; coverage bytes
    mov rax, [font_cw]                  ; the cell, clipped: right, bottom
    add rax, rdi
    mov rcx, [font_ch]
    add rcx, rsi
    cmp rax, [tg_cx1]
    jle .right
    mov rax, [tg_cx1]
.right:
    cmp rcx, [tg_cy1]
    jle .bottom
    mov rcx, [tg_cy1]
.bottom:
    mov rbx, [tg_cy0]                   ; top: skip rows of coverage
    sub rbx, rsi
    jle .top
    add rsi, rbx
    imul rbx, [font_cw]
    add rdx, rbx
.top:
    mov rbx, [tg_cx0]                   ; left: skip columns
    sub rbx, rdi
    jle .left
    add rdi, rbx
    add rdx, rbx
.left:
    sub rax, rdi
    jle .out
    sub rcx, rsi
    jle .out
    mov r12, rax                        ; columns drawn
    mov r13, [font_cw]
    sub r13, rax                        ; coverage skipped after each row
    mov r9, rcx                         ; rows
    mov rax, rsi
    imul rax, [tg_pitch]
    lea r8, [rax + rdi * 4]
    add r8, [tg_ptr]                    ; destination
    cmp r12, 8
    jb .one_by_one
    cmp byte [gfx_avx2], 0
    jne .simd
.one_by_one:
    lea r11, [text_ramp]
    cmp dword [text_bg], GFX_CLEAR
    je .blend_row
    cmp byte [ramp_stale], 0
    je .opaque_row
    call gfx_ramp
.opaque_row:
    mov rcx, r12
    mov rdi, r8
.opaque_px:
    movzx eax, byte [rdx]
    mov eax, [r11 + rax * 4]
    mov [rdi], eax
    inc rdx
    add rdi, 4
    dec rcx
    jnz .opaque_px
    add rdx, r13
    add r8, [tg_pitch]
    dec r9
    jnz .opaque_row
    jmp .out
.blend_row:
    mov rcx, r12
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
    add rdx, r13
    add r8, [tg_pitch]
    dec r9
    jnz .blend_row
    jmp .out
; 8 pixels at a time, each channel (fg * a + bg * (255 - a) + 127) / 255 in
; 16-bit lanes, the division as gfx_ramp's (* 0x8081 >> 23): the same pixels
; as one at a time. A row's last 8 overlap what came before.
.simd:
    vpxor xmm7, xmm7, xmm7
    vmovdqu ymm9, [glyph_spread]
    vpbroadcastw ymm5, [glyph_w255]
    vpbroadcastw ymm6, [glyph_w127]
    vpbroadcastw ymm8, [glyph_w8081]
    mov eax, [text_fg]
    and eax, 0x00FFFFFF
    vmovd xmm3, eax
    vpbroadcastd ymm3, xmm3
    vpunpcklbw ymm3, ymm3, ymm7         ; YMM3 = fg, a word a channel
    lea r10, [r12 - 8]                  ; R10 = where a row's last 8 start
    cmp dword [text_bg], GFX_CLEAR
    je .simd_blend
    mov eax, [text_bg]
    and eax, 0x00FFFFFF
    vmovd xmm4, eax
    vpbroadcastd ymm4, xmm4
    vpunpcklbw ymm4, ymm4, ymm7         ; YMM4 = bg
.so_row:
    xor ecx, ecx
.so_px:
    vpmovzxbd ymm0, [rdx + rcx]         ; coverage, a dword a pixel
    vpshufb ymm0, ymm0, ymm9            ; a, a, a, 0
    vpunpcklbw ymm1, ymm0, ymm7         ; pixels 0, 1, 4, 5
    vpunpckhbw ymm2, ymm0, ymm7         ; pixels 2, 3, 6, 7
    vpsubw ymm10, ymm5, ymm1
    vpsubw ymm11, ymm5, ymm2
    vpmullw ymm1, ymm1, ymm3
    vpmullw ymm2, ymm2, ymm3
    vpmullw ymm10, ymm10, ymm4
    vpmullw ymm11, ymm11, ymm4
    vpaddw ymm1, ymm1, ymm10
    vpaddw ymm2, ymm2, ymm11
    vpaddw ymm1, ymm1, ymm6
    vpaddw ymm2, ymm2, ymm6
    vpmulhuw ymm1, ymm1, ymm8
    vpmulhuw ymm2, ymm2, ymm8
    vpsrlw ymm1, ymm1, 7
    vpsrlw ymm2, ymm2, 7
    vpackuswb ymm1, ymm1, ymm2
    vmovdqu [r8 + rcx * 4], ymm1
    cmp rcx, r10
    jae .so_next
    add rcx, 8
    cmp rcx, r10
    jbe .so_px
    mov rcx, r10                        ; the last 8: drawn again, the same
    jmp .so_px
.so_next:
    add rdx, r12
    add rdx, r13
    add r8, [tg_pitch]
    dec r9
    jnz .so_row
    vzeroupper
    jmp .out
.simd_blend:                            ; over what is there: coverage 0 keeps
    vpbroadcastd ymm12, [text_fg]       ; it, 255 is fg itself
    vpcmpeqd ymm13, ymm13, ymm13
    vpsrld ymm13, ymm13, 8              ; YMM13 = 0x00FFFFFF
    vpsrld ymm14, ymm13, 16             ; YMM14 = 255
.sb_row:
    xor ecx, ecx
    xor esi, esi                        ; RSI = pixels of these 8 already drawn
.sb_px:
    mov rax, [rdx + rcx]
    test esi, esi
    jz .sb_fresh
    push rcx                            ; the last 8: those already drawn
    lea ecx, [esi * 8]                  ; blended once, not twice
    mov rbx, -1
    shl rbx, cl
    and rax, rbx
    pop rcx
.sb_fresh:
    test rax, rax
    jz .sb_skip                         ; nothing to draw in these 8
    vmovq xmm0, rax
    vpmovzxbd ymm0, xmm0
    vmovdqu ymm15, [r8 + rcx * 4]       ; what is there
    vpand ymm4, ymm15, ymm13
    vpshufb ymm2, ymm0, ymm9
    vpunpcklbw ymm1, ymm2, ymm7
    vpunpckhbw ymm2, ymm2, ymm7
    vpunpcklbw ymm10, ymm4, ymm7
    vpunpckhbw ymm11, ymm4, ymm7
    vpsubw ymm4, ymm5, ymm1
    vpmullw ymm10, ymm10, ymm4
    vpsubw ymm4, ymm5, ymm2
    vpmullw ymm11, ymm11, ymm4
    vpmullw ymm1, ymm1, ymm3
    vpmullw ymm2, ymm2, ymm3
    vpaddw ymm1, ymm1, ymm10
    vpaddw ymm2, ymm2, ymm11
    vpaddw ymm1, ymm1, ymm6
    vpaddw ymm2, ymm2, ymm6
    vpmulhuw ymm1, ymm1, ymm8
    vpmulhuw ymm2, ymm2, ymm8
    vpsrlw ymm1, ymm1, 7
    vpsrlw ymm2, ymm2, 7
    vpackuswb ymm1, ymm1, ymm2
    vpcmpeqd ymm4, ymm0, ymm7
    vpblendvb ymm1, ymm1, ymm15, ymm4   ; coverage 0: as it was
    vpcmpeqd ymm4, ymm0, ymm14
    vpblendvb ymm1, ymm1, ymm12, ymm4   ; 255: fg
    vmovdqu [r8 + rcx * 4], ymm1
.sb_skip:
    cmp rcx, r10
    jae .sb_next
    add rcx, 8
    xor esi, esi
    cmp rcx, r10
    jbe .sb_px
    mov rsi, rcx
    sub rsi, r10
    mov rcx, r10
    jmp .sb_px
.sb_next:
    add rdx, r12
    add rdx, r13
    add r8, [tg_pitch]
    dec r9
    jnz .sb_row
    vzeroupper
    jmp .out
.out:
    pop r13
    pop r12
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
align 32
glyph_spread:   db 0, 0, 0, 0x80, 4, 4, 4, 0x80, 8, 8, 8, 0x80, 12, 12, 12, 0x80
                db 0, 0, 0, 0x80, 4, 4, 4, 0x80, 8, 8, 8, 0x80, 12, 12, 12, 0x80
glyph_w255:     dw 255
glyph_w127:     dw 127
glyph_w8081:    dw 0x8081

section .data
align 8
text_fg:        dd 0xFFFFFFFE
text_bg:        dd 0xFFFFFFFE
gfx_ready:      db 0
ramp_stale:     db 1
gfx_avx2:       db 0
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
back_sf:        resb SF_SIZE
tg_ptr:         resq 1                  ; the target: what gfx_fill and gfx_glyph draw into
tg_pitch:       resq 1
tg_w:           resq 1
tg_h:           resq 1
tg_cx0:         resq 1                  ; and the clip within it: left, top,
tg_cy0:         resq 1
tg_cx1:         resq 1                  ; right, bottom (exclusive)
tg_cy1:         resq 1
gfx_saved:      resb 72
