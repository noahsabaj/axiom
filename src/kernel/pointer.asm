; =============================================================================
;  pointer.asm - the mouse pointer. HID drivers (USB or Bluetooth) post
;  movement with pointer_event from interrupt context; the main loop applies
;  it in pointer_service, moves the cursor and turns buttons and the wheel
;  into actions. The cursor lives only on the screen: gfx_blit repaints it
;  over whatever it copies, so the back buffer never contains it.
;
;  Mouse actions on the Mandelbrot view: left click centres on the point,
;  the wheel zooms around it, right click holds or resumes the zoom, middle
;  click goes back to the start.
; =============================================================================

PTR_RING        equ 64                  ; events, 16 bytes each
CURSOR_W        equ 12
CURSOR_H        equ 19

section .text

; pointer_event(EDI = dx, ESI = dy, EDX = wheel | pan << 16, ECX = buttons,
; R8D = 1 if EDI/ESI are absolute 0..65535). Any context. Preserves all.
pointer_event:
    push rax
    push rbx
    pushfq
    cli
    movzx eax, byte [ptr_head]
    lea ebx, [eax + 1]
    and ebx, PTR_RING - 1
    cmp bl, [ptr_tail]
    je .full
    shl eax, 4
    lea rax, [ptr_ring + rax]
    mov [rax], edi
    mov [rax + 4], esi
    mov [rax + 8], edx
    mov [rax + 12], cx
    mov [rax + 14], r8w
    mov [ptr_head], bl
.full:
    popfq
    pop rbx
    pop rax
    ret

; pointer_pending -> ZF clear if events are waiting
pointer_pending:
    push rax
    mov al, [ptr_tail]
    cmp al, [ptr_head]
    pop rax
    ret

; pointer_service: apply queued events (main loop)
pointer_service:
    mov al, [ptr_tail]
    cmp al, [ptr_head]
    jne .work
    ret
.work:
    push rbx
    push r12
    push r13
    push r14
.next:
    cli
    movzx eax, byte [ptr_tail]
    cmp al, [ptr_head]
    je .drained
    mov ebx, eax
    shl ebx, 4
    lea rbx, [ptr_ring + rbx]
    mov r12d, [rbx]                     ; dx
    mov r13d, [rbx + 4]                 ; dy
    mov r14d, [rbx + 8]                 ; wheel | pan
    movzx ecx, word [rbx + 12]          ; buttons
    movzx edx, word [rbx + 14]          ; absolute?
    inc eax
    and eax, PTR_RING - 1
    mov [ptr_tail], al
    sti
    push rcx
    test edx, edx
    jz .relative
    mov eax, r12d                       ; absolute: scale to the screen
    imul rax, [scr_w]
    shr rax, 16
    mov [ptr_x], rax
    mov eax, r13d
    imul rax, [scr_h]
    shr rax, 16
    mov [ptr_y], rax
    jmp .moved
.relative:
    mov eax, r12d
    call pointer_accel
    add [ptr_x], rax
    mov eax, r13d
    call pointer_accel
    add [ptr_y], rax
.moved:
    call pointer_clamp
    pop rcx
    mov eax, ecx                        ; buttons pressed in this event
    mov edx, [ptr_buttons]
    not edx
    and eax, edx
    mov [ptr_buttons], ecx
    test eax, 1
    jz .right
    push rax
    mov edx, 1
    call pointer_click
    pop rax
.right:
    test eax, 2
    jz .middle
    push rax
    mov edx, 2
    call pointer_click
    pop rax
.middle:
    test eax, 4
    jz .wheel
    mov edx, 3
    call pointer_click
.wheel:
    movsx edx, r14w
    test edx, edx
    jz .next
    call pointer_wheel
    jmp .next
.drained:
    sti
    call cursor_move
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pointer_accel(EAX = signed delta) -> RAX = pixels: faster the faster it moves,
; and scaled up on big screens
pointer_accel:
    push rcx
    push rdx
    movsxd rax, eax
    mov rcx, rax                        ; |d|, capped
    neg rcx
    cmovl rcx, rax
    cmp rcx, 24
    jbe .capped
    mov ecx, 24
.capped:
    add rcx, 8                          ; gain (8 + |d|) / 8
    imul rax, rcx
    mov rcx, [scr_w]                    ; and screen width / 1600
    cmp rcx, 1600
    jbe .small
    imul rax, rcx
    mov ecx, 1600
    cqo
    idiv rcx
.small:
    sar rax, 3
    pop rdx
    pop rcx
    ret

pointer_clamp:
    mov rax, [ptr_x]
    test rax, rax
    jns .x_low
    xor eax, eax
.x_low:
    mov rcx, [scr_w]
    dec rcx
    cmp rax, rcx
    cmovg rax, rcx
    mov [ptr_x], rax
    mov rax, [ptr_y]
    test rax, rax
    jns .y_low
    xor eax, eax
.y_low:
    mov rcx, [scr_h]
    dec rcx
    cmp rax, rcx
    cmovg rax, rcx
    mov [ptr_y], rax
    ret

; pointer_in_view -> CF = 0 and RDI, RSI = position inside the Mandelbrot view
pointer_in_view:
    mov rdi, [ptr_x]
    sub rdi, [m_view_x]
    jb .out
    cmp rdi, [m_width]
    jae .no
    mov rsi, [ptr_y]
    sub rsi, [m_view_y]
    jb .out
    cmp rsi, [m_height]
    jae .no
    clc
    ret
.no:
    stc
.out:
    ret

; pointer_click(EDX = button 1 left, 2 right, 3 middle)
pointer_click:
    call pointer_in_view
    jc .out
    call mandel_click
.out:
    ret

; pointer_wheel(EDX = signed notches, up is positive)
pointer_wheel:
    call pointer_in_view
    jc .out
    call mandel_wheel
.out:
    ret

; -----------------------------------------------------------------------------
;  The cursor
; -----------------------------------------------------------------------------

; cursor_move: show the cursor where the pointer is now
cursor_move:
    push rdi
    push rsi
    push rdx
    push rcx
    mov rdi, [cur_x]                    ; where it was
    mov rsi, [cur_y]
    mov rax, [ptr_x]
    mov [cur_x], rax
    mov rax, [ptr_y]
    mov [cur_y], rax
    cmp byte [cursor_shown], 0
    je .first
    call cursor_size
    call gfx_blit_raw                   ; uncover the old spot
.first:
    mov byte [cursor_shown], 1
    call cursor_paint
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; cursor_size -> RDX = width, RCX = height in pixels
cursor_size:
    call cursor_scale
    imul edx, eax, CURSOR_W
    imul ecx, eax, CURSOR_H
    ret

; cursor_scale -> EAX = 1 or 2, matching the font size
cursor_scale:
    mov eax, 1
    cmp qword [font_ch], 30
    jb .out
    mov eax, 2
.out:
    ret

; cursor_overlay(RDI x, RSI y, RDX w, RCX h): a rectangle was just copied to
; the screen; repaint the cursor if it overlaps. Preserves all.
cursor_overlay:
    cmp byte [cursor_shown], 0
    je .out
    push rax
    push rdx
    push rcx
    lea rax, [rdi + rdx]                ; rect right > cursor left?
    cmp rax, [cur_x]
    jbe .no
    lea rax, [rsi + rcx]
    cmp rax, [cur_y]
    jbe .no
    call cursor_size
    mov rax, [cur_x]
    add rax, rdx
    cmp rdi, rax                        ; rect left < cursor right?
    jae .no
    mov rax, [cur_y]
    add rax, rcx
    cmp rsi, rax
    jae .no
    call cursor_paint
.no:
    pop rcx
    pop rdx
    pop rax
.out:
    ret

; cursor_paint: draw the arrow straight onto the framebuffer. Preserves all.
cursor_paint:
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
    call cursor_scale
    mov r11d, eax                       ; scale
    lea rsi, [cursor_art]
    xor r8d, r8d                        ; row
.row:
    cmp r8d, CURSOR_H
    jae .done
    xor r9d, r9d                        ; column
.col:
    cmp r9d, CURSOR_W
    jae .next_row
    movzx eax, byte [rsi]
    inc rsi
    mov ebx, CURSOR_EDGE
    cmp al, 'X'
    je .px
    mov ebx, CURSOR_FILL
    cmp al, '.'
    jne .next_col
.px:
    xor r10d, r10d                      ; scaled block: r11 x r11 pixels
.sub_y:
    cmp r10d, r11d
    jae .next_col
    mov eax, r8d
    imul eax, r11d
    add eax, r10d
    add rax, [cur_y]
    cmp rax, [scr_h]
    jae .next_sub
    imul rax, [scr_pitch]
    mov rdi, rax
    mov eax, r9d
    imul eax, r11d
    add rax, [cur_x]
    xor ecx, ecx
.sub_x:
    cmp ecx, r11d
    jae .next_sub
    lea rdx, [rax + rcx]
    cmp rdx, [scr_w]
    jae .next_sub
    lea rdx, [rdi + rdx * 4]
    add rdx, [fb_ptr]
    mov [rdx], ebx
    inc ecx
    jmp .sub_x
.next_sub:
    inc r10d
    jmp .sub_y
.next_col:
    inc r9d
    jmp .col
.next_row:
    inc r8d
    jmp .row
.done:
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

CURSOR_EDGE     equ 0x0A0A0A            ; grey levels: the same in RGB and BGR
CURSOR_FILL     equ 0xF4F4F4

section .rodata
cursor_art:
    db 'X           '
    db 'XX          '
    db 'X.X         '
    db 'X..X        '
    db 'X...X       '
    db 'X....X      '
    db 'X.....X     '
    db 'X......X    '
    db 'X.......X   '
    db 'X........X  '
    db 'X.........X '
    db 'X......XXXXX'
    db 'X...X..X    '
    db 'X..XX..X    '
    db 'X.X  X..X   '
    db 'XX   X..X   '
    db 'X     X..X  '
    db '      X..X  '
    db '       XX   '

section .data
cursor_shown:   db 0

section .bss
alignb 8
ptr_x:          resq 1
ptr_y:          resq 1
cur_x:          resq 1
cur_y:          resq 1
ptr_buttons:    resd 1
ptr_head:       resb 1
ptr_tail:       resb 1
alignb 16
ptr_ring:       resb PTR_RING * 16
