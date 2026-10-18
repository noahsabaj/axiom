; =============================================================================
;  window.asm - windows for programs, by capability
;
;  A program run from the console gets a handle to the desktop (OT_DESK,
;  SB_DESK). SYS_WINDOW_NEW opens a window on it (OT_WINDOW): its pixels are
;  a block of memory the program maps and draws into, B,G,R,x at width * 4
;  bytes a row, and what happens to it (a key while it has the keys, a
;  button pressed in it and let go, the pointer dragged across it, the wheel,
;  its close button) comes as messages of WE_SIZE bytes from the channel end
;  it was given, at that end's peer. A game may ask for more (WNF_KEYS: each
;  key down and up; WNF_HOVER: the pointer over it with no button held, and
;  leaving). On a ring:
;    RO_WIN_SHOW (a window, a0 = x, a1 = y, a2 = w | h << 32, 0 for all of
;      it): what was drawn there is put on the screen
;    RO_WIN_TITLE (a window, handle2 + a0: a1 bytes of UTF-8): its title
;    RO_WIN_POINTER (a window, a0 = PTRM_*): the arrow over it, none, or
;      none and the pointer held (ptr_mode)
;  Its size is the program's, unless it lets the user resize it (WNF_RESIZE,
;  WNF_FULL: WE_RESIZED says how much shows). The close button only asks
;  (WE_CLOSE); the window goes when its last handle does, and so when the
;  program ends, is killed (ctrl+C), or the shell it was run in closes.
;
;  The program's side runs on any CPU and never touches the desktop: what it
;  asks for is noted in the object (WO_FLAGS) and done by the main loop
;  (wo_service, from desk_service). win_lock covers WO_FLAGS, WO_TITLE,
;  WO_WIN and wo_list; it is taken with interrupts off, and win_damage may
;  be called under it.
; =============================================================================

WO_NEXT         equ 64                  ; wo_list, while it has work or a window
WO_WIN          equ 72                  ; its window on the desktop, 0 if none
WO_MEM          equ 80                  ; its pixels, a reference
WO_CH           equ 88                  ; the channel end it speaks from, a reference
WO_W            equ 96                  ; dword: its size
WO_H            equ 100                 ; dword
WO_FLAGS        equ 104                 ; dword WOF_*: for the main loop to do
WO_WNF          equ 108                 ; dword WNF_*: as it was asked for
WO_TITLE        equ 112
WO_PROG         equ WO_TITLE + WN_TITLE_MAX ; the program's name (the dock's)
WO_PROG_MAX     equ 32
WO_PTRM         equ WO_PROG + WO_PROG_MAX ; dword PTRM_*: the pointer, as it asked
WO_SIZE         equ WO_PTRM + 8

WOF_OPEN        equ 1                   ; its window is to be opened
WOF_TITLE       equ 2                   ; retitled
WOF_GONE        equ 4                   ; and closed: no handle to it is left

%macro WIN_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [win_lock]
    call spin_lock
    pop rdi
%endmacro

%macro WIN_UNLOCK 0
    push rdi
    lea rdi, [win_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  The program's side
; -----------------------------------------------------------------------------

; desk_program -> EAX = a handle to the desktop, in the current task, for a
; program run from the console; 0 if none could be made. Preserves others.
desk_program:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, OT_DESK
    mov esi, OB_SIZE
    lea rdx, [str_ot_desk]
    call obj_new
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, RT_DESK_WINDOW | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; sys_window_new(EDI = the desktop, ESI = width, EDX = height, ECX = a
; channel's end, R8D = WNF_*) -> RAX = a handle to the window, RDX = to its
; pixels. The program keeps its handle to the end: closing it cuts what the
; window says. One the user may resize has pixels for the whole screen, a
; row of them the screen's width.
sys_window_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test r8d, WNF_FULL                  ; full is resizable, zoomed
    jz .flags
    or r8d, WNF_RESIZE
.flags:
    and r8d, WNF_RESIZE | WNF_FULL | WNF_KEYS | WNF_HOVER
    push r8                             ; [RSP]: WNF_*
    mov r12d, esi
    mov r13d, edx
    mov r14d, ecx
    mov esi, OT_DESK
    mov edx, RT_DESK_WINDOW
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call obj_put
    mov rax, E_ARG
    lea ecx, [r12 - 1]                  ; 1 to WIN_MAX each way
    cmp ecx, WIN_MAX
    jae .out
    lea ecx, [r13 - 1]
    cmp ecx, WIN_MAX
    jae .out
    mov edi, r14d
    mov esi, OT_CHANNEL
    mov edx, RT_CH_SEND
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r15, rax                        ; R15 = the end, a reference
    mov edi, OT_WINDOW
    mov esi, WO_SIZE
    lea rdx, [str_ot_window]
    call obj_new
    test rax, rax
    jz .no_object
    mov rbx, rax                        ; RBX = the window, its first reference
    mov [rbx + WO_CH], r15
    mov eax, [rsp]
    mov [rbx + WO_WNF], eax
    mov edi, r12d
    imul rdi, r13
    test eax, WNF_RESIZE
    jz .pixels
    cmp r12, [scr_w]                    ; within the screen, which its pixels
    cmova r12, [scr_w]                  ; cover
    cmp r13, [scr_h]
    cmova r13, [scr_h]
    mov rdi, [scr_w]
    imul rdi, [scr_h]
.pixels:
    mov [rbx + WO_W], r12d
    mov [rbx + WO_H], r13d
    shl rdi, 2
    lea rsi, [str_win_pixels]
    call mem_new
    test rax, rax
    jz .no_pixels
    mov [rbx + WO_MEM], rax
    call cur_task                       ; titled as the program, to begin with
    lea rsi, [rax + OB_NAME]
    lea rdi, [rbx + WO_TITLE]
    mov ecx, OB_NAME_LEN - 1
.name:
    lodsb
    test al, al
    jz .named
    stosb
    dec ecx
    jnz .name
.named:
    mov byte [rdi], 0
    lea rsi, [rbx + WO_TITLE]           ; and so is whose it is
    lea rdi, [rbx + WO_PROG]
    mov ecx, WO_PROG_MAX - 1
.prog:
    lodsb
    test al, al
    jz .progged
    stosb
    dec ecx
    jnz .prog
.progged:
    mov byte [rdi], 0
    mov dword [rbx + WO_FLAGS], WOF_OPEN
    mov rdi, [rbx + WO_MEM]             ; the program's handles: its pixels,
    call obj_get
    mov esi, RT_MEM_READ | RT_MEM_WRITE | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .no_handle
    mov r13, rax
    mov rdi, rbx                        ; and the window
    call obj_get
    mov esi, RT_WIN_DRAW | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .no_window
    mov r12, rax
    WIN_LOCK                            ; the first reference: the list's
    mov rax, [wo_list]
    mov [rbx + WO_NEXT], rax
    mov [wo_list], rbx
    WIN_UNLOCK
    call wo_kick
    mov rax, r12
    mov rdx, r13
    jmp .done
.no_window:
    push rax
    mov edi, r13d
    call handle_close
    pop rax
    jmp .no_handle
.no_pixels:
    mov rax, E_NOMEM
.no_handle:
    mov rdi, rbx                        ; wo_destroy lets go of the end
    call obj_put
    jmp .out
.no_object:
    mov rdi, r15
    call obj_put
    mov rax, E_NOMEM
.out:
    xor edx, edx
.done:
    call op_done
    pop r8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_win_show(EDI = a window, RSI = x, RDX = y, RCX = w | h << 32, 0 for all
; of it) -> RAX = 0 (needs RT_WIN_DRAW): that part of it to the screen
h_win_show:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_WINDOW
    mov edx, RT_WIN_DRAW
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    WIN_LOCK
    mov rdi, [rbx + WO_WIN]
    test rdi, rdi
    jz .unlock                          ; not open yet: it will be shown whole
    mov ecx, [rbx + WO_W]
    mov r8d, [rbx + WO_H]
    xor esi, esi
    xor edx, edx
    test r14, r14
    jz .show
    cmp r12, rcx                        ; within it
    jae .unlock
    cmp r13, r8
    jae .unlock
    sub rcx, r12
    sub r8, r13
    mov eax, r14d
    cmp rax, rcx
    cmovb rcx, rax
    mov rax, r14
    shr rax, 32
    cmp rax, r8
    cmovb r8, rax
    mov rsi, r12
    mov rdx, r13
.show:
    call win_damage
.unlock:
    WIN_UNLOCK
    mov rdi, [main_thread]              ; composed by the main loop
    call thread_unpark
    mov rdi, rbx
    call obj_put
    xor eax, eax
.out:
    call op_done
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_win_pointer(EDI = a window, RSI = PTRM_*) -> RAX = 0 (needs
; RT_WIN_DRAW): the pointer over it as it asks, from the main loop's next
; turn (ptr_mode)
h_win_pointer:
    push rbx
    push r12
    mov r12, rsi
    mov esi, OT_WINDOW
    mov edx, RT_WIN_DRAW
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    cmp r12, PTRM_GRAB
    ja .put
    mov [rbx + WO_PTRM], r12d
    mov rdi, [main_thread]
    call thread_unpark
    xor eax, eax
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop r12
    pop rbx
    ret

; h_win_title(EDI = a window, ESI = memory, RDX = where in it, RCX = bytes)
; -> RAX = 0 (needs RT_WIN_DRAW, and RT_MEM_READ)
h_win_title:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, WN_TITLE_MAX
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_WINDOW
    mov edx, RT_WIN_DRAW
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    cmp r14, WN_TITLE_MAX - 1
    ja .put
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov rcx, r14
    call h_mem_read
    cmp rax, E_ANY
    jae .put
    mov byte [rsp + r14], 0
    push 0                              ; UTF-8 to the font's bytes, in place
    xor ecx, ecx                        ; (RSP: utf8_step's state)
    xor edx, edx
.decode:
    cmp rcx, r14
    jae .decoded
    mov al, [rsp + 8 + rcx]
    inc rcx
    test al, al
    jz .decoded
    mov rdi, rsp
    call utf8_step
    jc .decode
    call glyph_of
    test eax, eax
    jz .decode
    cmp eax, ' '                        ; a line's end, a space
    jae .glyph
    mov eax, ' '
.glyph:
    mov [rsp + 8 + rdx], al
    inc rdx
    jmp .decode
.decoded:
    mov byte [rsp + 8 + rdx], 0
    pop rax
    mov r14, rdx
    WIN_LOCK
    mov rsi, rsp
    add rsi, 8                          ; (past what WIN_LOCK pushed)
    lea rdi, [rbx + WO_TITLE]
    lea rcx, [r14 + 1]
    rep movsb
    or dword [rbx + WO_FLAGS], WOF_TITLE
    WIN_UNLOCK
    call wo_kick
    xor eax, eax
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    add rsp, WN_TITLE_MAX
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wo_orphan(RDI = a window): its last handle went (its TY_ORPHAN): it closes
wo_orphan:
    WIN_LOCK
    or dword [rdi + WO_FLAGS], WOF_GONE
    WIN_UNLOCK
    jmp wo_kick

; wo_destroy(RDI): its last reference went
wo_destroy:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + WO_MEM]
    test rdi, rdi
    jz .no_pixels
    call obj_put
.no_pixels:
    mov rdi, [rbx + WO_CH]
    call obj_put
    mov rdi, rbx
    call obj_free
    pop rbx
    ret

; wo_kick: the main loop has something to do for a window. Preserves all.
wo_kick:
    mov byte [desk_reap], 1
    push rdi
    mov rdi, [main_thread]
    call thread_unpark
    pop rdi
    ret

; -----------------------------------------------------------------------------
;  The main loop's side
; -----------------------------------------------------------------------------

; wo_service: what programs asked of their windows, done (from desk_service)
wo_service:
    push rbx
    push r12
    push r13
    sub rsp, WN_TITLE_MAX
.next:
    WIN_LOCK
    lea r12, [wo_list]                  ; R12 = where the link to RBX is
    mov rbx, [r12]
.find:
    test rbx, rbx
    jz .none
    cmp dword [rbx + WO_FLAGS], 0
    jne .found
    lea r12, [rbx + WO_NEXT]
    mov rbx, [r12]
    jmp .find
.found:
    xor r13d, r13d                      ; R13D = what to do
    xchg r13d, [rbx + WO_FLAGS]
    test r13d, WOF_GONE
    jz .stays
    mov rax, [rbx + WO_NEXT]            ; off the list: its reference is ours
    mov [r12], rax
    jmp .taken
.stays:
    mov rdi, rbx
    call obj_get
.taken:
    lea rsi, [rbx + WO_TITLE]
    lea rdi, [rsp + 8]                  ; (past what WIN_LOCK pushed)
    mov ecx, WN_TITLE_MAX
    rep movsb
    WIN_UNLOCK
    test r13d, WOF_GONE
    jnz .gone
    test r13d, WOF_OPEN
    jz .title
    call wo_open
    jmp .put
.title:
    mov rdi, [rbx + WO_WIN]             ; (only the main loop changes it)
    test rdi, rdi
    jz .put
    mov rsi, rsp
    call win_title
    jmp .put
.gone:
    mov rdi, [rbx + WO_WIN]
    test rdi, rdi
    jz .put                             ; never opened, or closed already
    call win_close
.put:
    mov rdi, rbx
    call obj_put
    jmp .next
.none:
    WIN_UNLOCK
    add rsp, WN_TITLE_MAX
    pop r13
    pop r12
    pop rbx
    ret

; wo_open(RBX = a window, [RSP + 8] = its title): on the desktop, on top,
; with the keys
wo_open:
    lea rdi, [prog_ops]
    lea rsi, [rsp + 8]
    mov edx, [rbx + WO_W]
    mov ecx, [rbx + WO_H]
    mov r8, -1
    xor r9d, r9d
    mov r10d, WF_CLOSE | WF_PROGRAM
    test dword [rbx + WO_WNF], WNF_RESIZE
    jz .new
    or r10d, WF_RESIZE
.new:
    lea r11, [rbx + WO_PROG]
    call win_new
    test rax, rax
    jz .full
    mov rdi, rax
    mov rax, [rbx + WO_MEM]             ; its pixels are the program's
    mov rax, [rax + MO_BASE]
    mov [rdi + WN_SF + SF_PTR], rax
    mov eax, [rbx + WO_W]
    mov [rdi + WN_SF + SF_W], rax
    shl rax, 2
    test dword [rbx + WO_WNF], WNF_RESIZE
    jz .pitch
    mov rax, [scr_w]                    ; a row: the screen's width
    shl rax, 2
.pitch:
    mov [rdi + WN_SF + SF_PITCH], rax
    mov eax, [rbx + WO_H]
    mov [rdi + WN_SF + SF_H], rax
    mov [rdi + WN_DATA], rbx
    push rdi
    mov rdi, rbx                        ; the desktop's reference
    call obj_get
    pop rdi
    WIN_LOCK
    mov [rbx + WO_WIN], rdi
    WIN_UNLOCK
    test dword [rbx + WO_WNF], WNF_FULL
    jz .sized
    push rdi
    call win_zoom                       ; filling the screen, to begin with
    pop rdi
    jmp .focus                          ; (and told its size, if not the same)
.sized:
    test dword [rbx + WO_WNF], WNF_RESIZE
    jz .focus
    push rbx                            ; the size it was given, if the
    push rdi                            ; screen took less
    mov rbx, rdi
    call prog_resized
    pop rdi
    pop rbx
.focus:
    jmp win_focus
.full:
    lea rax, [rsp + 8]
    KLOG "desk: no room for '%s'", rax
    ret

; wo_post(RBX = its window on the desktop, EDI = WE_*, ESI = code, EDX = x,
; ECX = y): said to the program
wo_post:
    sub rsp, WE_SIZE
    mov [rsp + WE_KIND], edi
    mov [rsp + WE_CODE], esi
    mov [rsp + WE_X], edx
    mov [rsp + WE_Y], ecx
    mov rdi, [rbx + WN_DATA]
    mov rdi, [rdi + WO_CH]
    mov rsi, rsp
    mov edx, WE_SIZE
    call ch_post
    add rsp, WE_SIZE
    ret

; its handlers (OP_*)
prog_key:
    mov esi, eax
    mov edi, WE_KEY
    movzx edx, byte [kbd_got]           ; with the modifiers it came with
    xor ecx, ecx
    jmp wo_post

prog_click:
    mov r8d, WE_RELEASE
    test ecx, ecx
    jz .let_go
    mov r8d, WE_PRESS
.let_go:
    mov ecx, esi
    mov esi, edx
    mov edx, edi
    mov edi, r8d
    jmp wo_post

prog_wheel:
    mov ecx, esi
    mov esi, edx
    mov edx, edi
    mov edi, WE_WHEEL
    jmp wo_post

prog_move:
    cmp rbx, [press_win]                ; while a button is held in it
    je .post
    cmp rbx, [grab_win]                 ; or it holds the pointer
    je .post
    mov rax, [rbx + WN_DATA]            ; or always, if it asked
    test rax, rax
    jz .out
    test dword [rax + WO_WNF], WNF_HOVER
    jz .out
    mov [wo_hover], rbx
.post:
    mov ecx, esi
    mov edx, edi
    call ptr_delta
    mov edi, WE_MOVE
    jmp wo_post
.out:
    ret

; prog_left(RBX = the window whose client the pointer is over now, 0 if
; none): the one it was over, which asked (WNF_HOVER), told it left.
; Preserves RBX, R8, R9.
prog_left:
    mov rax, [wo_hover]
    test rax, rax
    jz .out
    cmp rax, rbx
    je .out
    mov qword [wo_hover], 0
    push rbx
    push r8
    push r9
    mov rbx, rax
    mov edi, WE_LEAVE
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call wo_post
    pop r9
    pop r8
    pop rbx
.out:
    ret

; win_key_event(EAX = a key down or up, from key_next): to the window with
; the keys, if it is a program's that asked (WNF_KEYS)
win_key_event:
    test eax, 1 << 8                    ; ctrl and alt down together: a pointer
    jz .tell                            ; held is let go (until clicked)
    mov ecx, eax
    shr ecx, 16
    and ecx, WM_CTRL | WM_ALT
    cmp ecx, WM_CTRL | WM_ALT
    jne .tell
    cmp qword [grab_win], 0
    je .tell
    mov byte [grab_off], 1
.tell:
    push rbx
    mov rbx, [desk_focus]
    test rbx, rbx
    jz .out
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jz .out
    mov rdi, [rbx + WN_DATA]
    test rdi, rdi
    jz .out
    test dword [rdi + WO_WNF], WNF_KEYS
    jz .out
    movzx esi, al                       ; the usage
    mov edi, WE_KEYUP
    test eax, 1 << 8
    jz .up
    mov edi, WE_KEYDOWN
.up:
    shr eax, 16
    movzx edx, al                       ; WM_*
    xor ecx, ecx
    call wo_post
.out:
    pop rbx
    ret

prog_ask:
    mov edi, WE_CLOSE
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    jmp wo_post

; prog_resized(RBX = its window on the desktop, its client now WN_W by
; WN_H): its pixels shown that size, and the program told. Preserves RBX,
; RBP, R12-R15.
prog_resized:
    mov rdi, [rbx + WN_DATA]
    test rdi, rdi
    jz .out                             ; not its yet (win_new)
    mov rax, [rbx + WN_W]
    mov rcx, [rbx + WN_H]
    mov [rbx + WN_SF + SF_W], rax
    mov [rbx + WN_SF + SF_H], rcx
    WIN_LOCK
    mov [rdi + WO_W], eax
    mov [rdi + WO_H], ecx
    WIN_UNLOCK
    mov edx, eax
    mov edi, WE_RESIZED
    xor esi, esi
    jmp wo_post
.out:
    ret

; prog_focus(RBX = its window, ESI = 1: it has the keys now, 0: not)
prog_focus:
    cmp qword [rbx + WN_DATA], 0
    je .out
    mov edi, WE_FOCUS
    xor edx, edx
    xor ecx, ecx
    jmp wo_post
.out:
    ret

prog_close:
    cmp rbx, [wo_hover]
    jne .not_over
    mov qword [wo_hover], 0
.not_over:
    mov rdi, [rbx + WN_DATA]
    WIN_LOCK
    mov qword [rdi + WO_WIN], 0
    WIN_UNLOCK
    jmp obj_put

section .rodata
str_ot_desk:    db 'desktop', 0
str_ot_window:  db 'window', 0
str_win_pixels: db 'pixels', 0

align 8
prog_ops:       dq 0, prog_key, prog_click, prog_wheel, prog_close, prog_move, prog_ask

section .bss
alignb 8
wo_list:        resq 1                  ; programs' windows, newest first
wo_hover:       resq 1                  ; the window (WNF_HOVER) the pointer is over
win_lock:       resd 1
