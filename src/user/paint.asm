; =============================================================================
;  paint.asm - a window of its own: draw in it with the mouse
;
;    run paint [width height]
;
;  Opens a window on the desktop (ax_desk, SYS_WINDOW_NEW), 640 by 480 unless
;  told, on paper. The left button draws while it is held; 1 to 5 pick a
;  colour (ink, red, blue, green, gold), shown in its title; c clears it.
;  Esc, or its close button, ends it: "paint: N strokes", and it returns 0.
;  Each change goes to the screen as it is drawn (RO_WIN_SHOW, the part that
;  changed).
; =============================================================================

%include "axe.inc"
WANTS AW_DESK

W_DEF           equ 640
H_DEF           equ 480
BRUSH           equ 3                   ; a dab: this far each way from its centre
PAPER           equ 0xF4F1E8
KEY_ESC         equ 27

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov dword [width], W_DEF
    mov dword [height], H_DEF
    lea rsi, [rdi + SB_ARGS]            ; paint W H
    call number
    jc .sized
    mov r12, rax
    call number
    jc .sized
    lea ecx, [r12 - 1]
    cmp ecx, WIN_MAX
    jae .usage
    lea ecx, [rax - 1]
    cmp ecx, WIN_MAX
    jae .usage
    mov [width], r12d
    mov [height], eax
.sized:
    mov eax, [ax_desk]
    test eax, eax
    jz .no_desk
    mov eax, SYS_CHANNEL_NEW            ; what the window says comes over this
    syscall
    test rax, rax
    js .refused
    mov [ev_end], edx                   ; ours, to receive at
    mov edi, [ax_desk]
    mov esi, [width]
    mov edx, [height]
    mov r10d, eax                       ; the window's, to send from
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js .refused
    mov [win], eax
    mov edi, edx                        ; its pixels, here
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [pixels], rax
    call clear
    call retitle
    lea rsi, [s_open]
    call ax_add
    mov edi, [width]
    call ax_addu
    lea rsi, [s_by]
    call ax_add
    mov edi, [height]
    call ax_addu
    lea rsi, [s_how]
    call ax_add
    call ax_flush
.event:
    mov edi, [ev_end]
    lea rsi, [ev]
    mov edx, WE_SIZE
    xor ecx, ecx
    call ax_recv
    test rax, rax
    js .done                            ; the window is gone
    mov eax, [ev + WE_KIND]
    cmp eax, WE_PRESS
    je .press
    cmp eax, WE_MOVE
    je .move
    cmp eax, WE_RELEASE
    je .release
    cmp eax, WE_KEY
    je .key
    cmp eax, WE_CLOSE
    je .done
    jmp .event
.press:
    cmp dword [ev + WE_CODE], 1
    jne .event
    mov byte [down], 1
    inc qword [strokes]
    mov edi, [ev + WE_X]
    mov esi, [ev + WE_Y]
    mov [last_x], edi
    mov [last_y], esi
    mov edx, edi
    mov ecx, esi
    call stroke
    jmp .event
.move:
    cmp byte [down], 0
    je .event
    mov edi, [last_x]
    mov esi, [last_y]
    mov edx, [ev + WE_X]
    mov ecx, [ev + WE_Y]
    mov [last_x], edx
    mov [last_y], ecx
    call stroke
    jmp .event
.release:
    cmp dword [ev + WE_CODE], 1
    jne .event
    mov byte [down], 0
    jmp .event
.key:
    mov eax, [ev + WE_CODE]
    cmp eax, KEY_ESC
    je .done
    cmp eax, 'c'
    je .clear
    sub eax, '1'
    cmp eax, COLOURS
    jae .event
    mov [colour], eax
    call retitle
    jmp .event
.clear:
    call clear
    jmp .event
.done:
    lea rsi, [s_done]
    call ax_add
    mov rdi, [strokes]
    call ax_addu
    lea rsi, [s_strokes]
    call ax_add
    call ax_flush
    xor eax, eax                        ; and as it ends, its window goes
    jmp .out
.usage:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 1
    jmp .out
.no_desk:
    lea rsi, [s_no_desk]
    call ax_puts
    mov eax, 2
    jmp .out
.refused:
    mov rbx, rax
    lea rsi, [s_refused]
    call ax_add
    mov rdi, rbx
    call ax_addd
    call ax_flush
    mov eax, 3
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; number(RSI = text) -> RAX = the next number in it, RSI past it; CF if
; there is none
number:
    cmp byte [rsi], ' '
    jne .digits
    inc rsi
    jmp number
.digits:
    xor eax, eax
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .none
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .end
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    cmp rax, 1 << 20
    jb .digit
.end:
    clc
    ret
.none:
    stc
    ret

; stroke(EDI, ESI = from, EDX, ECX = to): dabs along the line, then that
; part shown
stroke:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r12d, edi                       ; R12D, R13D: from
    mov r13d, esi
    mov r14d, edx                       ; R14D, R15D: how far
    sub r14d, edi
    mov r15d, ecx
    sub r15d, esi
    mov eax, r14d                       ; EBP = steps: the longer side
    cdq
    xor eax, edx
    sub eax, edx
    mov ebp, eax
    mov eax, r15d
    cdq
    xor eax, edx
    sub eax, edx
    cmp eax, ebp
    jle .steps
    mov ebp, eax
.steps:
    xor ebx, ebx
.dab:
    mov edi, r12d
    mov esi, r13d
    test ebp, ebp
    jz .at
    mov eax, r14d                       ; from + how far * i / steps
    imul eax, ebx
    cdq
    idiv ebp
    add edi, eax
    mov eax, r15d
    imul eax, ebx
    cdq
    idiv ebp
    add esi, eax
.at:
    call dab
    inc ebx
    cmp ebx, ebp
    jle .dab
    mov edi, r12d                       ; what changed: around both ends
    mov esi, r13d
    lea edx, [r12 + r14]
    lea ecx, [r13 + r15]
    cmp edi, edx
    jle .x_order
    xchg edi, edx
.x_order:
    cmp esi, ecx
    jle .y_order
    xchg esi, ecx
.y_order:
    sub edi, BRUSH
    sub esi, BRUSH
    add edx, BRUSH
    add ecx, BRUSH
    call show
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dab(EDI = x, ESI = y): the brush there, as far as the window goes
dab:
    mov eax, [colour]
    lea rcx, [colours]
    mov r8d, [rcx + rax * 4]
    lea r9d, [rsi - BRUSH]              ; R9D = the row
.row:
    cmp r9d, 0
    jl .next_row
    cmp r9d, [height]
    jge .next_row
    lea r10d, [rdi - BRUSH]             ; R10D = the column
.column:
    cmp r10d, 0
    jl .next_column
    cmp r10d, [width]
    jge .next_column
    mov eax, r9d
    imul eax, [width]
    add eax, r10d
    mov rdx, [pixels]
    mov [rdx + rax * 4], r8d
.next_column:
    inc r10d
    lea eax, [rdi + BRUSH]
    cmp r10d, eax
    jle .column
.next_row:
    inc r9d
    lea eax, [rsi + BRUSH]
    cmp r9d, eax
    jle .row
    ret

; show(EDI, ESI = top left, EDX, ECX = bottom right, inclusive; either may
; be outside): that part to the screen
show:
    xor eax, eax
    test edi, edi
    cmovs edi, eax
    test esi, esi
    cmovs esi, eax
    sub edx, edi
    jl .out
    inc edx
    sub ecx, esi
    jl .out
    inc ecx
    sub rsp, SQ_SIZE
    push rdi
    push rcx
    lea rdi, [rsp + 16]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    pop rdi
    mov byte [rsp + SQ_OP], RO_WIN_SHOW
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_A0], rdi
    mov [rsp + SQ_A1], rsi
    mov eax, edx                        ; w | h << 32
    shl rcx, 32
    or rax, rcx
    mov [rsp + SQ_A2], rax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
.out:
    ret

; clear: paper all over, shown
clear:
    mov rdi, [pixels]
    mov ecx, [width]
    imul ecx, [height]
    mov eax, PAPER
    rep stosd
    xor edi, edi
    xor esi, esi
    mov edx, [width]
    dec edx
    mov ecx, [height]
    dec ecx
    jmp show

; retitle: "paint · <colour>"
retitle:
    mov rdi, [ax_io_va]
    lea rsi, [s_title]
.title:
    lodsb
    test al, al
    jz .name
    stosb
    jmp .title
.name:
    mov eax, [colour]
    lea rcx, [colour_names]
    mov rsi, [rcx + rax * 8]
.copy:
    lodsb
    test al, al
    jz .titled
    stosb
    jmp .copy
.titled:
    sub rdi, [ax_io_va]
    sub rsp, SQ_SIZE
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_WIN_TITLE
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], rdi
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    ret

section .rodata
COLOURS         equ 5
colours:        dd 0x1B1F27, 0xD9483B, 0x2F6BD8, 0x2E9E5B, 0xE0A526
s_ink:          db 'ink', 0
s_red:          db 'red', 0
s_blue:         db 'blue', 0
s_green:        db 'green', 0
s_gold:         db 'gold', 0
align 8
colour_names:   dq s_ink, s_red, s_blue, s_green, s_gold
s_title:        db 'paint ', 0xC2, 0xB7, ' ', 0
s_open:         db 'paint: a window ', 0
s_by:           db 'x', 0
s_how:          db '; the left button draws, 1-5 pick a colour, c clears, Esc ends', 0
s_done:         db 'paint: ', 0
s_strokes:      db ' strokes', 0
s_usage:        db 'usage: run paint [width height], each 1 to 4096', 10, 0
s_no_desk:      db 'paint: no desktop to open a window on', 10, 0
s_refused:      db 'paint: refused: ', 0

section .data
colour:         dd 0

section .bss
alignb 8
pixels:         resq 1
strokes:        resq 1
width:          resd 1
height:         resd 1
win:            resd 1
ev_end:         resd 1
last_x:         resd 1
last_y:         resd 1
ev:             resb WE_SIZE
down:           resb 1

AXE_END
