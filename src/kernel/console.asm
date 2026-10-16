; =============================================================================
;  console.asm - a scrolling text region on the back buffer
; =============================================================================

section .text

; con_init(RDI x, RSI y, RDX width px, RCX height px): place the console and clear it
con_init:
    push rax
    push rdx
    mov [con_x], rdi
    mov [con_y], rsi
    mov rax, rdx
    xor edx, edx
    div qword [font_cw]
    mov [con_cols], rax
    mov rax, rcx
    xor edx, edx
    div qword [font_ch]
    mov [con_rows], rax
    pop rdx
    pop rax
    mov byte [con_ready], 1
    ; fall through

; con_clear: blank the region and home the cursor. Preserves all.
con_clear:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    mov rdi, [con_x]
    mov rsi, [con_y]
    mov rdx, [con_cols]
    imul rdx, [font_cw]
    mov rcx, [con_rows]
    imul rcx, [font_ch]
    mov r8d, [con_bg]
    call gfx_fill
    mov qword [con_cx], 0
    mov qword [con_cy], 0
    mov qword [con_dirty_lo], 0
    mov rax, [con_rows]
    mov [con_dirty_hi], rax
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; con_write(RDI string). Preserves all.
con_write:
    cmp byte [con_ready], 0
    je .out
    push rax
    push rdi
.next:
    mov al, [rdi]
    test al, al
    jz .done
    call con_putc
    inc rdi
    jmp .next
.done:
    pop rdi
    pop rax
.out:
    ret

; con_putc(AL). Preserves all.
con_putc:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    cmp al, 10
    je .newline
    cmp al, 13
    je .carriage
    cmp al, 8
    je .backspace
    cmp al, 9
    je .tab
    mov rcx, [con_cx]
    cmp rcx, [con_cols]
    jb .draw
    call con_newline
.draw:
    movzx edx, al
    call con_draw_at_cursor
    inc qword [con_cx]
    jmp .out
.newline:
    call con_newline
    jmp .out
.carriage:
    mov qword [con_cx], 0
    jmp .out
.backspace:
    cmp qword [con_cx], 0
    je .out
    dec qword [con_cx]
    mov edx, ' '
    call con_draw_at_cursor
    jmp .out
.tab:
    mov edx, ' '
    call con_draw_at_cursor
    inc qword [con_cx]
    test qword [con_cx], 3
    jz .out
    mov rcx, [con_cx]
    cmp rcx, [con_cols]
    jb .tab
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; draw EDX at the cursor in the console colors
con_draw_at_cursor:
    push rdi
    push rsi
    mov edi, [con_fg]
    mov esi, [con_bg]
    call gfx_color
    mov rdi, [con_cx]
    imul rdi, [font_cw]
    add rdi, [con_x]
    mov rsi, [con_cy]
    imul rsi, [font_ch]
    add rsi, [con_y]
    call gfx_glyph
    mov rax, [con_cy]
    call con_mark
    pop rsi
    pop rdi
    ret

; con_mark(RAX = row): widen the dirty range
con_mark:
    cmp rax, [con_dirty_lo]
    jae .lo_ok
    mov [con_dirty_lo], rax
.lo_ok:
    inc rax
    cmp rax, [con_dirty_hi]
    jbe .hi_ok
    mov [con_dirty_hi], rax
.hi_ok:
    dec rax
    ret

con_newline:
    push rax
    mov qword [con_cx], 0
    mov rax, [con_cy]
    inc rax
    cmp rax, [con_rows]
    jb .set
    call con_scroll
    mov rax, [con_rows]
    dec rax
.set:
    mov [con_cy], rax
    pop rax
    ret

; con_scroll: move the region up one text row and clear the last row
con_scroll:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, [con_rows]
    dec r8
    imul r8, [font_ch]                  ; pixel rows to move
    jz .clear
    mov rax, [con_y]
    imul rax, [scr_pitch]
    mov rdx, [con_x]
    lea rdi, [rax + rdx * 4]
    add rdi, [bb_ptr]                   ; destination row
    mov rsi, [font_ch]
    imul rsi, [scr_pitch]
    add rsi, rdi                        ; source row, one text line below
    mov r9, [con_cols]
    imul r9, [font_cw]
    shl r9, 2                           ; bytes per pixel row
.move:
    push rsi
    push rdi
    mov rcx, r9
    rep movsb
    pop rdi
    pop rsi
    add rsi, [scr_pitch]
    add rdi, [scr_pitch]
    dec r8
    jnz .move
.clear:
    mov rdi, [con_x]
    mov rsi, [con_rows]
    dec rsi
    imul rsi, [font_ch]
    add rsi, [con_y]
    mov rdx, [con_cols]
    imul rdx, [font_cw]
    mov rcx, [font_ch]
    mov r8d, [con_bg]
    call gfx_fill
    mov qword [con_dirty_lo], 0
    mov rax, [con_rows]
    mov [con_dirty_hi], rax
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; con_flush: push dirty rows to the screen. Preserves all.
con_flush:
    cmp byte [con_ready], 0
    je .out
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    mov rax, [con_dirty_lo]
    mov rcx, [con_dirty_hi]
    cmp rax, rcx
    jae .clean
    sub rcx, rax
    imul rcx, [font_ch]
    mov rsi, rax
    imul rsi, [font_ch]
    add rsi, [con_y]
    mov rdi, [con_x]
    mov rdx, [con_cols]
    imul rdx, [font_cw]
    call gfx_blit
    mov rax, [con_rows]
    mov [con_dirty_lo], rax
    mov qword [con_dirty_hi], 0
.clean:
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
.out:
    ret

; con_set_color(EDI fg). Preserves all.
con_set_color:
    mov [con_fg], edi
    ret

section .data
align 8
con_fg:         dd COL_TEXT
con_bg:         dd COL_BG
con_ready:      db 0

section .bss
alignb 8
con_x:          resq 1
con_y:          resq 1
con_cols:       resq 1
con_rows:       resq 1
con_cx:         resq 1
con_cy:         resq 1
con_dirty_lo:   resq 1
con_dirty_hi:   resq 1
