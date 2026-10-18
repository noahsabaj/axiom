; =============================================================================
;  desk.asm - the desktop: windows over a background, a bar along the top.
;
;  A window (WN_*) is a frame on the screen around a surface of its own, the
;  client, which its owner draws into (gfx_target) and then says what changed
;  (win_damage). What changed on the screen is a list of rectangles;
;  desk_update composes each one into the back buffer, bottom window to top,
;  the bar last, and copies it to the screen. Windows overlap, move by their
;  title bar, resize from the bottom right corner, raise and take the keys
;  when clicked, and minimise to the bar; the bar has a button for each
;  window and one for a new shell. All of it runs on the main thread, but
;  win_damage and desk_damage, which any thread may call.
; =============================================================================

DESK_MAX        equ 32                  ; windows at once
DMG_MAX         equ 16                  ; rectangles waiting to be composed

WN_X            equ 0                   ; the frame's top left on the screen
WN_Y            equ 8
WN_W            equ 16                  ; the client's size
WN_H            equ 24
WN_SF           equ 32                  ; SF_SIZE: the client's pixels
WN_FLAGS        equ 72                  ; dword WF_*
WN_ID           equ 76                  ; dword: its number in 'win'
WN_OPS          equ 80                  ; its owner's handlers (OP_*)
WN_DATA         equ 88                  ; its owner's
WN_MIN_W        equ 96                  ; the smallest client it takes
WN_MIN_H        equ 104
WN_TITLE        equ 112
WN_TITLE_MAX    equ 160
WN_SIZE         equ WN_TITLE + WN_TITLE_MAX

WF_SHOWN        equ 1 << 0              ; not minimised
WF_CLOSE        equ 1 << 1              ; it has a close button
WF_RESIZE       equ 1 << 2              ; it may be resized
WF_CLOSING      equ 1 << 3              ; it goes at the next desk_service
WF_PROGRAM      equ 1 << 4              ; a program's (its pixels are not ours)

OP_PAINT        equ 0                   ; RBX = window: draw the whole client
OP_KEY          equ 8                   ; RBX, EAX = key code
OP_CLICK        equ 16                  ; RBX, RDI, RSI = where in the client,
                                        ; EDX = button 1..3, ECX = 1 pressed, 0 let go
OP_WHEEL        equ 24                  ; RBX, RDI, RSI, EDX = notches, up positive
OP_CLOSE        equ 32                  ; RBX: it is going; let go of what it holds
OP_MOVE         equ 40                  ; RBX, RDI, RSI: the pointer moved in the client
OP_ASK          equ 48                  ; RBX: its close button; 0: it closes
OP_COUNT        equ 7

P_NONE          equ 0                   ; what is under the pointer
P_BAR           equ 1
P_TITLE         equ 2
P_CLOSE         equ 3
P_MIN           equ 4
P_GRIP          equ 5
P_CLIENT        equ 6
P_FRAME         equ 7

DRAG_NONE       equ 0
DRAG_MOVE       equ 1
DRAG_SIZE       equ 2

section .text

; -----------------------------------------------------------------------------
;  desk_init: the frame's measures, the background and the bar
; -----------------------------------------------------------------------------
desk_init:
    mov rax, [ui_line]
    mov [fr_b], rax
    mov rax, [title_h]
    mov [fr_t], rax
    mov rax, [font_cw]
    imul rax, rax, 3
    mov [fr_btn], rax                   ; a title bar button
    mov rax, [font_ch]
    mov [fr_grip], rax                  ; the corner that resizes
    mov byte [desk_ready], 1
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    jmp desk_damage

; -----------------------------------------------------------------------------
;  Windows
; -----------------------------------------------------------------------------

; win_new(RDI = handlers, RSI = title, RDX = width, RCX = height of the
; client, R8 = x, R9 = y of the frame (x = -1: placed for it), R10D = WF_*)
; -> RAX = the window, 0 if there is no room. It is on top, not focused.
win_new:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    push r8
    push r9
    push r10
    mov edi, WN_SIZE
    call kmalloc
    pop r10
    pop r9
    pop r8
    test rax, rax
    jz .out
    mov rbx, rax
    xor ecx, ecx                        ; a slot in the bar
.slot:
    lea rdx, [desk_wins]
    cmp qword [rdx + rcx * 8], 0
    je .found
    inc ecx
    cmp ecx, DESK_MAX
    jb .slot
    mov rdi, rbx
    call kfree
    xor eax, eax
    jmp .out
.found:
    mov [rdx + rcx * 8], rbx
    mov [rbx + WN_OPS], r12
    or r10d, WF_SHOWN
    mov [rbx + WN_FLAGS], r10d
    inc dword [desk_next_id]
    mov eax, [desk_next_id]
    mov [rbx + WN_ID], eax
    mov rax, [font_cw]
    imul rax, rax, 16
    mov [rbx + WN_MIN_W], rax
    mov rax, [font_ch]
    imul rax, rax, 4
    mov [rbx + WN_MIN_H], rax
    test r10d, WF_PROGRAM               ; a program's: the size of its pixels
    jz .least
    mov [rbx + WN_MIN_W], r14
    mov [rbx + WN_MIN_H], r15
.least:
    mov rdi, rbx
    mov rsi, r13
    call win_title_set
    cmp r8, -1                          ; cascade from the top left
    jne .placed
    mov rax, [desk_next_id]
    and eax, 7
    imul rax, [title_h]
    mov r8, [font_cw]
    imul r8, r8, 4
    add r8, rax
    mov r9, [hdr_h]
    add r9, [font_ch]
    add r9, rax
.placed:
    mov [rbx + WN_X], r8
    mov [rbx + WN_Y], r9
    mov rax, [desk_zn]                  ; on top
    lea rdx, [desk_z]
    mov [rdx + rax * 8], rbx
    inc qword [desk_zn]
    mov rdi, rbx
    mov rsi, r14
    mov rdx, r15
    call win_fit                        ; size, place, paint
    mov rdi, rbx
    call win_damage_whole
    call desk_bar_damage
    mov rax, rbx
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; win_title_set(RDI = window, RSI = title). Preserves all.
win_title_set:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [rdi + WN_TITLE]
    mov ecx, WN_TITLE_MAX - 1
.copy:
    lodsb
    test al, al
    jz .end
    stosb
    dec ecx
    jnz .copy
.end:
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; win_title(RDI = window, RSI = title): a new title, shown. Preserves all.
win_title:
    call win_title_set
    call win_damage_frame
    jmp desk_bar_damage

; win_fit(RDI = window, RSI = width, RDX = height): the client that size, as
; far as the screen and the window's least allow; the frame kept on the
; screen; then painted. Preserves RBX, RBP, R12-R15.
win_fit:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    cmp r12, [rbx + WN_MIN_W]
    jge .w_min
    mov r12, [rbx + WN_MIN_W]
.w_min:
    cmp r13, [rbx + WN_MIN_H]
    jge .h_min
    mov r13, [rbx + WN_MIN_H]
.h_min:
    mov rax, [scr_w]                    ; at most the screen
    sub rax, [fr_b]
    sub rax, [fr_b]
    cmp r12, rax
    jle .w_max
    mov r12, rax
.w_max:
    mov rax, [scr_h]
    sub rax, [hdr_h]
    sub rax, [fr_t]
    sub rax, [fr_b]
    sub rax, [fr_b]
    cmp r13, rax
    jle .h_max
    mov r13, rax
.h_max:
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jnz .sized                          ; a program's pixels keep their size
    lea rdi, [rbx + WN_SF]
    mov rsi, r12
    mov rdx, r13
    call sf_size
    jc .keep
.sized:
    mov [rbx + WN_W], r12
    mov [rbx + WN_H], r13
.keep:
    mov rdi, rbx
    mov rsi, [rbx + WN_X]
    mov rdx, [rbx + WN_Y]
    call win_place
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jnz .out
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_PAINT]
    test rax, rax
    jz .out
    call rax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; win_place(RDI = window, RSI = x, RDX = y): the frame there, as far as its
; title bar stays reachable. Preserves all.
win_place:
    push rax
    push rcx
    push rdx
    push rsi
    call win_outer_w
    mov rcx, [font_cw]                  ; at least 6 columns of the title
    imul rcx, rcx, 6                    ; bar on the screen
    neg rax
    add rax, rcx
    cmp rsi, rax
    jge .left
    mov rsi, rax
.left:
    mov rax, [scr_w]
    sub rax, rcx
    cmp rsi, rax
    jle .right
    mov rsi, rax
.right:
    cmp rdx, [hdr_h]                    ; under the bar
    jge .top
    mov rdx, [hdr_h]
.top:
    mov rax, [scr_h]
    sub rax, [fr_t]
    sub rax, [fr_b]
    cmp rdx, rax
    jle .bottom
    mov rdx, rax
.bottom:
    mov [rdi + WN_X], rsi
    mov [rdi + WN_Y], rdx
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; win_outer_w(RDI) -> RAX = the frame's width
win_outer_w:
    mov rax, [rdi + WN_W]
    add rax, [fr_b]
    add rax, [fr_b]
    ret

; win_outer(RDI = window) -> RDI x, RSI y, RDX w, RCX h of the frame.
; Preserves others but RAX.
win_outer:
    mov rsi, [rdi + WN_Y]
    mov rdx, [rdi + WN_W]
    add rdx, [fr_b]
    add rdx, [fr_b]
    mov rcx, [rdi + WN_H]
    add rcx, [fr_t]
    add rcx, [fr_b]
    add rcx, [fr_b]
    mov rdi, [rdi + WN_X]
    ret

; win_client(RDI = window) -> RDI x, RSI y, RDX w, RCX h of the client on
; the screen. Preserves others.
win_client:
    mov rsi, [rdi + WN_Y]
    add rsi, [fr_b]
    add rsi, [fr_t]
    mov rdx, [rdi + WN_W]
    mov rcx, [rdi + WN_H]
    mov rdi, [rdi + WN_X]
    add rdi, [fr_b]
    ret

; win_damage(RDI = window, RSI = x, RDX = y, RCX = w, R8 = h in the client):
; that part changed. Any thread. Preserves all.
win_damage:
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .out
    push rdi
    push rsi
    push rdx
    push rcx
    add rsi, [rdi + WN_X]
    add rsi, [fr_b]
    add rdx, [rdi + WN_Y]
    add rdx, [fr_b]
    add rdx, [fr_t]
    mov rdi, rsi
    mov rsi, rdx
    mov rdx, rcx
    mov rcx, r8
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
.out:
    ret

; win_damage_all(RDI = window): the whole client changed. Preserves all.
win_damage_all:
    push rsi
    push rdx
    push rcx
    push r8
    xor esi, esi
    xor edx, edx
    mov rcx, [rdi + WN_W]
    mov r8, [rdi + WN_H]
    call win_damage
    pop r8
    pop rcx
    pop rdx
    pop rsi
    ret

; win_damage_whole(RDI = window): the frame and all in it. Preserves all.
win_damage_whole:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    call win_outer
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; win_damage_frame(RDI = window): its title bar. Preserves all.
win_damage_frame:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    call win_outer
    mov rcx, [fr_t]
    add rcx, [fr_b]
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; win_shown(RDI) -> ZF clear if the window is on the screen. Preserves all.
win_shown:
    test dword [rdi + WN_FLAGS], WF_SHOWN
    ret

; win_move(RDI = window, RSI = x, RDX = y). Preserves RBX, RBP, R12-R15.
win_move:
    call win_damage_whole
    call win_place
    jmp win_damage_whole

; win_resize(RDI = window, RSI = width, RDX = height of the client).
; Preserves RBX, RBP, R12-R15.
win_resize:
    test dword [rdi + WN_FLAGS], WF_RESIZE
    jz .out
    push rbx
    mov rbx, rdi
    call win_damage_whole
    mov rdi, rbx
    call win_fit
    mov rdi, rbx
    call win_damage_whole
    pop rbx
.out:
    ret

; win_index(RDI = window) -> RAX = its place in the stack, CF if not there.
; Preserves others.
win_index:
    push rcx
    push rdx
    xor eax, eax
    lea rdx, [desk_z]
.find:
    cmp rax, [desk_zn]
    jae .none
    cmp [rdx + rax * 8], rdi
    je .found
    inc rax
    jmp .find
.found:
    clc
    jmp .out
.none:
    stc
.out:
    pop rdx
    pop rcx
    ret

; win_raise(RDI = window): to the top. Preserves all.
win_raise:
    push rax
    push rcx
    push rdx
    call win_index
    jc .out
    lea rdx, [desk_z]
.shift:
    lea rcx, [rax + 1]
    cmp rcx, [desk_zn]
    jae .top
    mov rcx, [rdx + rcx * 8]
    mov [rdx + rax * 8], rcx
    inc rax
    jmp .shift
.top:
    mov [rdx + rax * 8], rdi
    call win_damage_whole
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; win_focus(RDI = window or 0): it is shown, raised and takes the keys.
; Preserves all.
win_focus:
    push rax
    push rdi
    mov rax, [desk_focus]
    test rax, rax
    jz .old_done
    push rdi
    mov rdi, rax
    call win_damage_frame
    pop rdi
.old_done:
    mov [desk_focus], rdi
    test rdi, rdi
    jz .done
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jnz .shown
    or dword [rdi + WN_FLAGS], WF_SHOWN
.shown:
    call win_raise
    call win_damage_whole
.done:
    call desk_bar_damage
    pop rdi
    pop rax
    ret

; win_minimise(RDI = window): off the screen, still in the bar. Preserves all.
win_minimise:
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .out
    call win_damage_whole
    and dword [rdi + WN_FLAGS], ~WF_SHOWN
    cmp rdi, [desk_focus]
    jne .bar
    push rdi
    call desk_top_shown
    mov rdi, rax
    call win_focus
    pop rdi
.bar:
    call desk_bar_damage
.out:
    ret

; desk_top_shown -> RAX = the topmost window shown, or 0. Preserves others.
desk_top_shown:
    push rcx
    push rdx
    mov rcx, [desk_zn]
    lea rdx, [desk_z]
.down:
    test rcx, rcx
    jz .none
    dec rcx
    mov rax, [rdx + rcx * 8]
    test dword [rax + WN_FLAGS], WF_SHOWN
    jz .down
    test dword [rax + WN_FLAGS], WF_CLOSING
    jnz .down
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; win_close(RDI = window): it goes, at the next desk_service (not while
; its own handlers may be running). Preserves all.
win_close:
    or dword [rdi + WN_FLAGS], WF_CLOSING
    mov byte [desk_reap], 1
    ret

; win_ask(RDI = window): its close button. Its owner is asked (OP_ASK), or
; it closes. -> ZF clear if it was asked.
win_ask:
    mov rax, [rdi + WN_OPS]
    mov rax, [rax + OP_ASK]
    test rax, rax
    jnz .ask
    call win_close
    xor eax, eax
    ret
.ask:
    push rbx
    mov rbx, rdi
    call rax
    pop rbx
    or eax, 1
    ret

; desk_service: from the main loop, windows that are closing go
desk_service:
    cmp byte [desk_reap], 0
    jne .reap
    ret
.reap:
    push rbx
    mov byte [desk_reap], 0
    call wo_service                     ; programs' windows: opened, retitled, gone
.again:
    xor ecx, ecx
    lea rdx, [desk_z]
.find:
    cmp rcx, [desk_zn]
    jae .done
    mov rbx, [rdx + rcx * 8]
    test dword [rbx + WN_FLAGS], WF_CLOSING
    jnz .close
    inc rcx
    jmp .find
.close:
    mov rdi, rbx
    call win_destroy
    jmp .again
.done:
    pop rbx
    ret

; win_destroy(RBX = window): its owner lets go, then it goes
win_destroy:
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_CLOSE]
    test rax, rax
    jz .owned
    call rax
.owned:
    mov rdi, rbx
    call win_damage_whole
    call win_index                      ; out of the stack
    jc .unstacked
    lea rdx, [desk_z]
.shift:
    lea rcx, [rax + 1]
    cmp rcx, [desk_zn]
    jae .last
    mov rcx, [rdx + rcx * 8]
    mov [rdx + rax * 8], rcx
    inc rax
    jmp .shift
.last:
    dec qword [desk_zn]
.unstacked:
    xor ecx, ecx                        ; and out of the bar
    lea rdx, [desk_wins]
.slot:
    cmp [rdx + rcx * 8], rbx
    jne .next
    mov qword [rdx + rcx * 8], 0
.next:
    inc ecx
    cmp ecx, DESK_MAX
    jb .slot
    cmp rbx, [drag_win]
    jne .no_drag
    mov qword [drag_win], 0
    mov byte [drag_mode], DRAG_NONE
.no_drag:
    cmp rbx, [press_win]
    jne .no_press
    mov qword [press_win], 0
.no_press:
    cmp rbx, [desk_focus]
    jne .no_focus
    mov qword [desk_focus], 0
    call desk_top_shown
    mov rdi, rax
    call win_focus
.no_focus:
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jnz .pixels_theirs
    lea rdi, [rbx + WN_SF]
    call sf_free
.pixels_theirs:
    mov rdi, rbx
    call kfree
    jmp desk_bar_damage

; win_by_id(EDI = number) -> RAX = the window, 0 if none. Preserves others.
win_by_id:
    push rcx
    push rdx
    xor ecx, ecx
    lea rdx, [desk_wins]
.find:
    mov rax, [rdx + rcx * 8]
    test rax, rax
    jz .next
    test dword [rax + WN_FLAGS], WF_CLOSING
    jnz .next
    cmp [rax + WN_ID], edi
    je .out
.next:
    inc ecx
    cmp ecx, DESK_MAX
    jb .find
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Damage and composing
; -----------------------------------------------------------------------------

; desk_damage(RDI x, RSI y, RDX w, RCX h on the screen): to be composed
; again. Any thread. Preserves all.
desk_damage:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    call gfx_clip_screen_signed
    jz .out
    pushfq
    cli
    push rdi
    lea rdi, [dmg_lock]
    call spin_lock
    pop rdi
    mov rax, [dmg_n]
    cmp rax, DMG_MAX
    jb .add
    lea r8, [dmg_rects]                 ; full: one rectangle around them all
    call dmg_union
    mov qword [dmg_n], 1
    jmp .unlock
.add:
    shl rax, 5
    lea r8, [dmg_rects]
    mov [r8 + rax], rdi
    mov [r8 + rax + 8], rsi
    add rdi, rdx
    mov [r8 + rax + 16], rdi
    add rsi, rcx
    mov [r8 + rax + 24], rsi
    inc qword [dmg_n]
.unlock:
    lea rdi, [dmg_lock]
    call spin_unlock
    popfq
.out:
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; dmg_union(RDI x, RSI y, RDX w, RCX h, R8 = the list): the list's first
; rectangle becomes the one around them all and this. Under dmg_lock.
dmg_union:
    push r9
    push r10
    add rdx, rdi                        ; RDI..RDX, RSI..RCX
    add rcx, rsi
    xor r9d, r9d
.each:
    cmp r9, [dmg_n]
    jae .done
    mov r10, r9
    shl r10, 5
    add r10, r8
    cmp rdi, [r10]
    jle .x0
    mov rdi, [r10]
.x0:
    cmp rsi, [r10 + 8]
    jle .y0
    mov rsi, [r10 + 8]
.y0:
    cmp rdx, [r10 + 16]
    jge .x1
    mov rdx, [r10 + 16]
.x1:
    cmp rcx, [r10 + 24]
    jge .y1
    mov rcx, [r10 + 24]
.y1:
    inc r9
    jmp .each
.done:
    mov [r8], rdi
    mov [r8 + 8], rsi
    mov [r8 + 16], rdx
    mov [r8 + 24], rcx
    pop r10
    pop r9
    ret

; gfx_clip_screen_signed: as gfx_clip, to the screen, for rectangles that
; may start off it
gfx_clip_screen_signed:
    push r11
    lea rax, [rdi + rdx]
    lea r11, [rsi + rcx]
    test rdi, rdi
    jns .left
    xor edi, edi
.left:
    test rsi, rsi
    jns .top
    xor esi, esi
.top:
    cmp rax, [scr_w]
    jle .right
    mov rax, [scr_w]
.right:
    cmp r11, [scr_h]
    jle .bottom
    mov r11, [scr_h]
.bottom:
    sub rax, rdi
    jle .empty
    sub r11, rsi
    jle .empty
    mov rdx, rax
    mov rcx, r11
    pop r11
    test rdx, rdx
    ret
.empty:
    pop r11
    xor eax, eax
    ret

; desk_pending -> ZF clear if there is something to compose. Preserves all.
desk_pending:
    cmp qword [dmg_n], 0
    ret

; desk_update: compose what changed and show it (main thread)
desk_update:
    cmp byte [desk_ready], 0
    je .out
    cmp qword [dmg_n], 0
    jne .work
.out:
    ret
.work:
    push rbx
    push r12
    sub rsp, DMG_MAX * 32
    pushfq                              ; take the list
    cli
    lea rdi, [dmg_lock]
    call spin_lock
    mov r12, [dmg_n]
    mov rcx, r12
    shl rcx, 5
    lea rsi, [dmg_rects]
    lea rdi, [rsp + 8]
    rep movsb
    mov qword [dmg_n], 0
    lea rdi, [dmg_lock]
    call spin_unlock
    popfq
    xor ebx, ebx
.rect:
    cmp rbx, r12
    jae .done
    mov rax, rbx
    shl rax, 5
    lea rax, [rsp + rax]
    mov rdi, [rax]
    mov rsi, [rax + 8]
    mov rdx, [rax + 16]
    sub rdx, rdi
    mov rcx, [rax + 24]
    sub rcx, rsi
    call desk_compose
    inc rbx
    jmp .rect
.done:
    add rsp, DMG_MAX * 32
    pop r12
    pop rbx
    ret

; desk_compose(RDI x, RSI y, RDX w, RCX h): that part of the screen, again
desk_compose:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    call gfx_target_back
    call gfx_set_clip
    mov r8d, COL_BG                     ; the background
    call gfx_fill
    xor ebx, ebx                        ; windows, bottom to top
.window:
    cmp rbx, [desk_zn]
    jae .bar
    lea rax, [desk_z]
    mov rdi, [rax + rbx * 8]
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .next
    push rdi
    call win_outer                      ; does it reach the rectangle?
    lea rax, [rdi + rdx]
    cmp rax, r12
    jle .skip
    lea rax, [rsi + rcx]
    cmp rax, r13
    jle .skip
    lea rax, [r12 + r14]
    cmp rdi, rax
    jge .skip
    lea rax, [r13 + r15]
    cmp rsi, rax
    jge .skip
    pop rdi
    call desk_frame
    call desk_copy
    jmp .next
.skip:
    pop rdi
.next:
    inc rbx
    jmp .window
.bar:
    cmp r13, [hdr_h]
    jge .shown
    call desk_bar_paint
.shown:
    call gfx_target_back                ; the clip off again
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call gfx_blit
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; desk_frame(RDI = window): its border and title bar into the back buffer.
; Preserves RDI.
desk_frame:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    call win_outer
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov r8d, COL_LINE                   ; the border
    call gfx_fill
    mov rdi, r12                        ; the title bar
    add rdi, [fr_b]
    mov rsi, r13
    add rsi, [fr_b]
    mov rdx, r14
    sub rdx, [fr_b]
    sub rdx, [fr_b]
    mov rcx, [fr_t]
    mov r8d, COL_PANEL
    cmp rbx, [desk_focus]
    jne .bar_color
    mov r8d, COL_PANEL2
.bar_color:
    call gfx_fill
    cmp rbx, [desk_focus]               ; the accent mark of the focused one
    jne .title
    mov rdi, r12
    add rdi, [fr_b]
    mov rsi, r13
    add rsi, [fr_b]
    mov rdx, [ui_line]
    imul rdx, rdx, 3
    mov rcx, [fr_t]
    mov r8d, COL_ACCENT
    call gfx_fill
.title:
    mov rax, [fr_t]                     ; text row, centred in the bar
    sub rax, [font_ch]
    sar rax, 1
    add rax, r13
    add rax, [fr_b]
    mov [frame_ty], rax
    mov rax, r14                        ; columns for the title: all but
    sub rax, [fr_btn]                   ; the buttons and a margin
    sub rax, [fr_btn]
    sub rax, [font_cw]
    sub rax, [font_cw]
    cqo
    idiv qword [font_cw]
    test rax, rax
    jle .buttons
    mov r9, rax
    mov rdi, r12
    add rdi, [font_cw]
    mov rsi, [frame_ty]
    lea rdx, [rbx + WN_TITLE]
    mov ecx, COL_DIM
    mov r8d, COL_PANEL
    cmp rbx, [desk_focus]
    jne .title_text
    mov ecx, COL_TEXT
    mov r8d, COL_PANEL2
.title_text:
    call ui_text_max
.buttons:
    mov r15d, COL_PANEL                 ; right to left: close, minimise
    cmp rbx, [desk_focus]
    jne .btn_bg
    mov r15d, COL_PANEL2
.btn_bg:
    mov rdi, r12
    add rdi, r14
    sub rdi, [fr_b]
    test dword [rbx + WN_FLAGS], WF_CLOSE
    jz .minimise
    sub rdi, [fr_btn]
    mov rdx, [font_cw]                  ; the glyph, in the middle
    add rdx, rdi
    mov rsi, [frame_ty]
    push rdi
    mov rdi, rdx
    lea rdx, [str_btn_close]
    mov ecx, COL_DIM
    mov r8d, r15d
    call ui_text
    pop rdi
.minimise:
    sub rdi, [fr_btn]
    mov rdx, [font_cw]
    add rdx, rdi
    mov rsi, [frame_ty]
    mov rdi, rdx
    lea rdx, [str_btn_min]
    mov ecx, COL_DIM
    mov r8d, r15d
    call ui_text
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jz .done
    mov rdi, rbx                        ; the grip: two marks in the corner
    call win_client
    add rdi, rdx
    add rsi, rcx
    mov rax, [ui_line]
    imul rax, rax, 2
    sub rdi, rax
    sub rsi, rax
    mov r12, rdi
    mov r13, rsi
    mov rax, [fr_grip]
    shr rax, 1
    sub rdi, rax
    mov rdx, rax
    mov rcx, [ui_line]
    mov r8d, COL_FAINT
    call gfx_fill
    mov rdi, r12
    mov rsi, r13
    mov rax, [fr_grip]
    shr rax, 1
    sub rsi, rax
    mov rdx, [ui_line]
    mov rcx, rax
    call gfx_fill
.done:
    mov rdi, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; desk_copy(RDI = window): its client into the back buffer, within the clip.
; Preserves RDI.
desk_copy:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    cmp qword [rbx + WN_SF + SF_PTR], 0
    je .out
    call win_client
    mov r12, rdi                        ; where the client starts
    mov r13, rsi
    call gfx_clip
    jz .out
    mov rax, rsi                        ; source: row, column in the client
    sub rax, r13
    imul rax, [rbx + WN_SF + SF_PITCH]
    mov r8, rdi
    sub r8, r12
    lea r8, [rax + r8 * 4]
    add r8, [rbx + WN_SF + SF_PTR]
    mov rax, rsi                        ; destination
    imul rax, [scr_pitch]
    lea r9, [rax + rdi * 4]
    add r9, [bb_ptr]
    mov r10, rcx                        ; rows
.row:
    mov rsi, r8
    mov rdi, r9
    mov rcx, rdx
    rep movsd
    add r8, [rbx + WN_SF + SF_PITCH]
    add r9, [scr_pitch]
    dec r10
    jnz .row
.out:
    mov rdi, rbx
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The bar
; -----------------------------------------------------------------------------

; desk_bar_damage: the bar changed. Preserves all.
desk_bar_damage:
    push rdi
    push rsi
    push rdx
    push rcx
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [hdr_h]
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; desk_status(RSI = text): the right end of the bar. Preserves all.
desk_status:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [bar_status]
    mov ecx, 159
.copy:
    lodsb
    test al, al
    jz .end
    stosb
    dec ecx
    jnz .copy
.end:
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    jmp desk_bar_damage

; bar_layout: where each button is (bar_n of them: the new-shell button,
; then a window's, in slot order). Preserves RBX, RBP, R12-R15.
bar_layout:
    push rbx
    push r12
    push r13
    lea rdi, [bar_status]               ; the status takes the right end
    call strlen
    add rax, 2
    imul rax, [font_cw]
    mov r13, [scr_w]
    sub r13, rax                        ; buttons stop there
    lea rdi, [str_brand]
    call strlen
    add rax, 2
    imul rax, [font_cw]
    mov r12, rax                        ; x
    xor ebx, ebx                        ; buttons so far
    lea rax, [str_bar_shell]
    xor ecx, ecx
    call .button
    xor ecx, ecx                        ; then one per window
.slot:
    lea rax, [desk_wins]
    mov rax, [rax + rcx * 8]
    test rax, rax
    jz .next
    test dword [rax + WN_FLAGS], WF_CLOSING
    jnz .next
    push rcx
    mov rcx, rax
    lea rax, [rax + WN_TITLE]
    call .button
    pop rcx
    jc .done
.next:
    inc ecx
    cmp ecx, DESK_MAX
    jb .slot
.done:
    mov [bar_n], rbx
    pop r13
    pop r12
    pop rbx
    ret
; RAX = label, RCX = window (0: the new shell) -> CF if it does not fit
.button:
    push rcx
    mov rdi, rax
    call strlen
    cmp rax, 16
    jbe .short
    mov eax, 16
.short:
    add rax, 2
    imul rax, [font_cw]
    add rax, r12
    cmp rax, r13
    ja .full
    lea rdx, [bar_x0]
    mov [rdx + rbx * 8], r12
    lea rdx, [bar_x1]
    mov [rdx + rbx * 8], rax
    lea rdx, [bar_lab]
    mov [rdx + rbx * 8], rdi
    pop rcx
    lea rdx, [bar_win]
    mov [rdx + rbx * 8], rcx
    inc rbx
    mov r12, rax
    add r12, [ui_line]
    add r12, [ui_line]
    clc
    ret
.full:
    pop rcx
    stc
    ret

; desk_bar_paint: the bar, within the clip
desk_bar_paint:
    push rbx
    push r12
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [hdr_h]
    mov r8d, COL_PANEL
    call gfx_fill
    xor edi, edi
    mov rsi, [hdr_h]
    sub rsi, [ui_line]
    mov rdx, [scr_w]
    mov rcx, [ui_line]
    mov r8d, COL_LINE
    call gfx_fill
    mov rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 1
    lea rdx, [str_brand]
    mov ecx, COL_ACCENT
    mov r8d, COL_PANEL
    call ui_text
    call bar_layout
    xor ebx, ebx
.button:
    cmp rbx, [bar_n]
    jae .status
    lea rax, [bar_win]
    mov r12, [rax + rbx * 8]            ; its window, or 0
    mov r8d, COL_PANEL                  ; the button
    test r12, r12
    jz .box
    cmp r12, [desk_focus]
    jne .box
    mov r8d, COL_PANEL2
.box:
    push r8
    lea rax, [bar_x0]
    mov rdi, [rax + rbx * 8]
    lea rax, [bar_x1]
    mov rdx, [rax + rbx * 8]
    sub rdx, rdi
    mov rsi, [font_ch]
    shr rsi, 2
    mov rcx, [hdr_h]
    sub rcx, [ui_line]
    sub rcx, rsi
    sub rcx, rsi
    call gfx_fill
    pop r8
    mov ecx, COL_ACCENT                 ; and its label
    test r12, r12
    jz .label
    mov ecx, COL_DIM
    test dword [r12 + WN_FLAGS], WF_SHOWN
    jnz .shown
    mov ecx, COL_FAINT
.shown:
    cmp r12, [desk_focus]
    jne .label
    mov ecx, COL_TEXT
.label:
    lea rax, [bar_x0]
    mov rdi, [rax + rbx * 8]
    add rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 1
    lea rax, [bar_lab]
    mov rdx, [rax + rbx * 8]
    mov r9d, 16
    call ui_text_max
    inc rbx
    jmp .button
.status:
    mov rdi, [scr_w]
    sub rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 1
    lea rdx, [bar_status]
    mov ecx, COL_TEXT
    mov r8d, COL_PANEL
    call ui_text_right
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The pointer and the keys
; -----------------------------------------------------------------------------

; desk_hit(RDI x, RSI y) -> RAX = the window there (0: none), EDX = P_*,
; R8, R9 = the point in its client. Preserves RBX, RBP, R12-R15.
desk_hit:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    cmp r13, [hdr_h]
    jge .windows
    xor eax, eax
    mov edx, P_BAR
    jmp .out
.windows:
    mov rbx, [desk_zn]
.down:
    test rbx, rbx
    jz .nothing
    dec rbx
    lea rax, [desk_z]
    mov rdi, [rax + rbx * 8]
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .down
    push rdi
    call win_outer
    mov rax, r12
    sub rax, rdi
    jl .miss
    cmp rax, rdx
    jge .miss
    mov rax, r13
    sub rax, rsi
    jl .miss
    cmp rax, rcx
    jge .miss
    pop rax                             ; this one
    mov rdi, rax
    push rax
    call win_client
    mov r8, r12
    sub r8, rdi
    mov r9, r13
    sub r9, rsi
    pop rax
    cmp r9, 0                           ; above the client: the title bar
    jl .title
    cmp r8, 0
    jl .frame
    cmp r8, rdx
    jge .frame
    cmp r9, rcx
    jge .frame
    test dword [rax + WN_FLAGS], WF_RESIZE
    jz .client
    mov r10, rdx                        ; the corner grip
    sub r10, r8
    cmp r10, [fr_grip]
    jg .client
    mov r10, rcx
    sub r10, r9
    cmp r10, [fr_grip]
    jg .client
    mov edx, P_GRIP
    jmp .out
.client:
    mov edx, P_CLIENT
    jmp .out
.frame:
    mov edx, P_FRAME
    test dword [rax + WN_FLAGS], WF_RESIZE
    jz .out
    cmp r8, rdx                         ; the frame's own corner resizes too
    jl .out
    cmp r9, rcx
    jl .out
    mov edx, P_GRIP
    jmp .out
.title:
    mov r10, rdi                        ; from the client's right edge
    add r10, rdx
    sub r10, r12
    jl .title_bar
    test dword [rax + WN_FLAGS], WF_CLOSE
    jz .min_only
    cmp r10, [fr_btn]
    jge .past_close
    mov edx, P_CLOSE
    jmp .out
.past_close:
    sub r10, [fr_btn]
.min_only:
    cmp r10, [fr_btn]
    jge .title_bar
    mov edx, P_MIN
    jmp .out
.title_bar:
    mov edx, P_TITLE
    jmp .out
.miss:
    pop rdi
    jmp .down
.nothing:
    xor eax, eax
    mov edx, P_NONE
.out:
    pop r13
    pop r12
    pop rbx
    ret

; desk_press(EDX = button 1 left, 2 right, 3 middle) at the pointer
desk_press:
    cmp byte [desk_ready], 0
    je .out
    push rbx
    push r12
    mov r12d, edx
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call desk_hit
    mov rbx, rax
    cmp edx, P_BAR
    je .bar
    test rbx, rbx
    jz .done
    mov rdi, rbx
    call win_focus
    cmp edx, P_CLIENT
    je .client
    cmp r12d, 1                         ; the frame's parts: the left button
    jne .done
    cmp edx, P_TITLE
    je .move
    cmp edx, P_GRIP
    je .size
    cmp edx, P_CLOSE
    je .close
    cmp edx, P_MIN
    jne .done
    mov rdi, rbx
    call win_minimise
    jmp .done
.close:
    mov rdi, rbx
    call win_ask
    jmp .done
.move:
    mov byte [drag_mode], DRAG_MOVE
    mov [drag_win], rbx
    mov rax, [ptr_x]
    sub rax, [rbx + WN_X]
    mov [drag_dx], rax
    mov rax, [ptr_y]
    sub rax, [rbx + WN_Y]
    mov [drag_dy], rax
    jmp .done
.size:
    mov byte [drag_mode], DRAG_SIZE
    mov [drag_win], rbx
    mov rax, [ptr_x]
    sub rax, [rbx + WN_W]
    mov [drag_dx], rax
    mov rax, [ptr_y]
    sub rax, [rbx + WN_H]
    mov [drag_dy], rax
    jmp .done
.client:
    mov [press_win], rbx
    mov rdi, r8
    mov rsi, r9
    mov edx, r12d
    mov ecx, 1
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_CLICK]
    test rax, rax
    jz .done
    call rax
    jmp .done
.bar:
    cmp r12d, 1
    jne .done
    call bar_layout
    mov rax, [ptr_x]
    xor ecx, ecx
.button:
    cmp rcx, [bar_n]
    jae .done
    lea rdx, [bar_x0]
    cmp rax, [rdx + rcx * 8]
    jl .next
    lea rdx, [bar_x1]
    cmp rax, [rdx + rcx * 8]
    jl .hit
.next:
    inc rcx
    jmp .button
.hit:
    lea rdx, [bar_win]
    mov rdi, [rdx + rcx * 8]
    test rdi, rdi
    jz .new_shell
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .restore
    cmp rdi, [desk_focus]               ; the focused one minimises
    jne .restore
    call win_minimise
    jmp .done
.restore:
    call win_focus
    jmp .done
.new_shell:
    call term_new
.done:
    pop r12
    pop rbx
.out:
    ret

; desk_release(EDX = button)
desk_release:
    cmp edx, 1
    jne .press
    mov byte [drag_mode], DRAG_NONE
    mov qword [drag_win], 0
.press:
    mov rax, [press_win]
    test rax, rax
    jz .out
    push rbx
    push r12
    mov rbx, rax
    mov r12d, edx
    mov qword [press_win], 0
    mov rdi, rbx
    call win_client
    mov rax, [ptr_x]
    sub rax, rdi
    mov rdi, rax
    mov rax, [ptr_y]
    sub rax, rsi
    mov rsi, rax
    mov edx, r12d
    xor ecx, ecx
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_CLICK]
    test rax, rax
    jz .done
    call rax
.done:
    pop r12
    pop rbx
.out:
    ret

; desk_motion: the pointer moved (once for each batch of movement)
desk_motion:
    movzx eax, byte [drag_mode]
    cmp eax, DRAG_MOVE
    je .move
    cmp eax, DRAG_SIZE
    je .size
    mov rax, [press_win]                ; a button held in a client
    test rax, rax
    jnz .client
    mov rdi, [ptr_x]                    ; or the client under the pointer
    mov rsi, [ptr_y]
    push rbx
    call desk_hit
    cmp edx, P_CLIENT
    jne .none
    mov rbx, rax
    jmp .tell
.none:
    pop rbx
    ret
.client:
    push rbx
    mov rbx, rax
    mov rdi, rbx
    call win_client
    mov r8, [ptr_x]
    sub r8, rdi
    mov r9, [ptr_y]
    sub r9, rsi
.tell:
    mov rdi, r8
    mov rsi, r9
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_MOVE]
    test rax, rax
    jz .told
    call rax
.told:
    pop rbx
    ret
.move:
    mov rdi, [drag_win]
    mov rsi, [ptr_x]
    sub rsi, [drag_dx]
    mov rdx, [ptr_y]
    sub rdx, [drag_dy]
    cmp rsi, [rdi + WN_X]
    jne .moved
    cmp rdx, [rdi + WN_Y]
    je .out
.moved:
    jmp win_move
.size:
    mov rdi, [drag_win]
    mov rsi, [ptr_x]
    sub rsi, [drag_dx]
    mov rdx, [ptr_y]
    sub rdx, [drag_dy]
    cmp rsi, [rdi + WN_W]
    jne .resized
    cmp rdx, [rdi + WN_H]
    je .out
.resized:
    jmp win_resize
.out:
    ret

; desk_wheel(EDX = notches, up positive) at the pointer
desk_wheel:
    push rbx
    push r12
    mov r12d, edx
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call desk_hit
    cmp edx, P_CLIENT
    jne .out
    mov rbx, rax
    mov rdi, r8
    mov rsi, r9
    mov edx, r12d
    mov rax, [rbx + WN_OPS]
    mov rax, [rax + OP_WHEEL]
    test rax, rax
    jz .out
    call rax
.out:
    pop r12
    pop rbx
    ret

; desk_key(EAX = key code): to the window with the keys
desk_key:
    push rbx
    mov rbx, [desk_focus]
    test rbx, rbx
    jz .out
    mov rdx, [rbx + WN_OPS]
    mov rdx, [rdx + OP_KEY]
    test rdx, rdx
    jz .out
    call rdx
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  win [move|size|raise|min|close <n> ...]
; -----------------------------------------------------------------------------
cmd_win:
    push rbx
    push r12
    push r13
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .list
    call arg_split
    mov r12, rsi                        ; the verb
    mov rsi, rdi
    call arg_split
    mov r13, rdi                        ; what follows the number
    call arg_uint
    jc .usage
    mov ebx, eax
    mov edi, eax
    call win_by_id
    test rax, rax
    jz .no_window
    mov rbx, rax
    mov rdi, r12
    lea rsi, [str_win_move]
    call streq
    test eax, eax
    jnz .move
    mov rdi, r12
    lea rsi, [str_win_size]
    call streq
    test eax, eax
    jnz .size
    mov rdi, r12
    lea rsi, [str_win_raise]
    call streq
    test eax, eax
    jnz .raise
    mov rdi, r12
    lea rsi, [str_win_min]
    call streq
    test eax, eax
    jnz .min
    mov rdi, r12
    lea rsi, [str_win_close]
    call streq
    test eax, eax
    jnz .close
    jmp .usage
.move:
    call .two
    jc .usage
    mov rdi, rbx
    call win_move
    jmp .said
.size:
    call .two
    jc .usage
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jz .fixed
    mov rdi, rbx
    call win_resize
    jmp .said
.raise:
    mov rdi, rbx
    call win_focus
    jmp .said
.min:
    mov rdi, rbx
    call win_minimise
    jmp .said
.close:
    test dword [rbx + WN_FLAGS], WF_CLOSE
    jz .stays
    mov rdi, rbx
    call win_ask
    lea rax, [rbx + WN_TITLE]
    jnz .asked
    KLOG "desk: '%s' closes", rax
    jmp .out
.asked:
    KLOG "desk: '%s' is asked to close", rax
    jmp .out
.said:
    mov rdi, rbx
    call win_say
    jmp .out
.list:
    xor ebx, ebx
.each:
    lea rax, [desk_wins]
    mov rdi, [rax + rbx * 8]
    test rdi, rdi
    jz .next
    call win_say
.next:
    inc ebx
    cmp ebx, DESK_MAX
    jb .each
    jmp .out
.fixed:
    lea rax, [rbx + WN_TITLE]
    KLOG "desk: '%s' keeps its size", rax
    jmp .out
.stays:
    lea rax, [rbx + WN_TITLE]
    KLOG "desk: '%s' can be minimised, not closed", rax
    jmp .out
.no_window:
    KLOG "desk: no window %u ('win' lists them)", rbx
    jmp .out
.usage:
    KLOG "usage: win [move <n> <x> <y> | size <n> <w> <h> | raise <n> | min <n> | close <n>]"
.out:
    pop r13
    pop r12
    pop rbx
    ret
; R13 = "<a> <b>" -> RSI = a, RDX = b; CF if not two numbers
.two:
    mov rsi, r13
    call arg_split
    push rdi
    call arg_uint
    pop rsi
    jc .bad
    push rax
    call arg_split
    call arg_uint
    pop rsi
    jc .bad
    mov edx, eax
    mov esi, esi
    clc
    ret
.bad:
    stc
    ret

; win_say(RDI = window): a line about it
win_say:
    push rbx
    mov rbx, rdi
    mov eax, [rbx + WN_ID]
    lea rcx, [rbx + WN_TITLE]
    lea rdx, [str_win_shown]
    test dword [rbx + WN_FLAGS], WF_SHOWN
    jnz .state
    lea rdx, [str_win_hidden]
.state:
    cmp rbx, [desk_focus]
    jne .say
    lea rdx, [str_win_focused]
.say:
    lea rdi, [term_ops]                 ; a shell: how much it holds
    cmp [rbx + WN_OPS], rdi
    je .shell
    KLOG "desk: %u '%s' at %d,%d, %ux%u, %s", rax, rcx, qword [rbx + WN_X], qword [rbx + WN_Y], qword [rbx + WN_W], qword [rbx + WN_H], rdx
    pop rbx
    ret
.shell:
    mov rdi, [rbx + WN_DATA]
    mov rsi, [rdi + TW_END]
    inc rsi
    mov rdi, [rdi + TW_BACK]
    KLOG "desk: %u '%s' at %d,%d, %ux%u, %s, %u lines, %u back", rax, rcx, qword [rbx + WN_X], qword [rbx + WN_Y], qword [rbx + WN_W], qword [rbx + WN_H], rdx, rsi, rdi
    pop rbx
    ret

section .rodata
str_btn_close:  db 'x', 0
str_btn_min:    db '_', 0
str_bar_shell:  db '+ shell', 0
str_win_move:   db 'move', 0
str_win_size:   db 'size', 0
str_win_raise:  db 'raise', 0
str_win_min:    db 'min', 0
str_win_close:  db 'close', 0
str_win_shown:  db 'shown', 0
str_win_hidden: db 'minimised', 0
str_win_focused: db 'focused', 0

section .data
desk_ready:     db 0
desk_reap:      db 0
drag_mode:      db DRAG_NONE

section .bss
alignb 8
fr_b:           resq 1                  ; the frame: its border,
fr_t:           resq 1                  ; title bar,
fr_btn:         resq 1                  ; a button in it,
fr_grip:        resq 1                  ; the corner that resizes
frame_ty:       resq 1
desk_wins:      resq DESK_MAX           ; by slot: the bar's order
desk_z:         resq DESK_MAX           ; bottom to top
desk_zn:        resq 1
desk_focus:     resq 1                  ; the window with the keys
desk_next_id:   resq 1
drag_win:       resq 1
drag_dx:        resq 1
drag_dy:        resq 1
press_win:      resq 1                  ; a client a button was pressed in
dmg_lock:       resd 1
alignb 8
dmg_n:          resq 1
dmg_rects:      resq DMG_MAX * 4        ; left, top, right, bottom
bar_n:          resq 1
bar_x0:         resq DESK_MAX + 1
bar_x1:         resq DESK_MAX + 1
bar_win:        resq DESK_MAX + 1
bar_lab:        resq DESK_MAX + 1
bar_status:     resb 160
