; =============================================================================
;  motion.asm - what moves on the desktop: a window opening and closing,
;  going into the dock and coming out of it, zooming; a menu fading as it
;  closes. (The dock's own motion - its icons growing under the pointer,
;  one bouncing while its app starts - is desk.asm's dock_motion; a menu's
;  item blinking as it is chosen, menus.asm's mn_motion.)
;
;  Each is a slot (MV_*): where it is at the start and at the end, how much
;  of it shows at each, and how long it takes. motion_service, from the
;  main loop, takes a step of all of them about 60 times a second, eased,
;  and has the desk compose where each was and is; motion_paint draws them
;  as it does. A window that moves so is drawn from a picture of it
;  (mv_picture): desk_frame's, over black and over white, which gives each
;  pixel's color and how much of it there is, its shadow too - scaled,
;  from the half of it that fits (pic_draw). The pictures' memory is kept
;  while things move, and MV_KEEP_MS after, for what moves next.
;
;  'motion off' stops it all; 'motion slow' makes it ten times slower.
;  Main thread.
; =============================================================================

MV_MAX          equ 6                   ; at once
MV_LEVELS       equ 4                   ; a picture and its halves
MV_LINE         equ 4096                ; the widest picture

MV_KIND         equ 0                   ; dword MVK_* (0: a free slot)
MV_EASE         equ 4                   ; dword MVE_*
MV_T0           equ 8                   ; when it began (TSC; 0: at its first step)
MV_DUR          equ 16                  ; how long it takes (TSC ticks)
MV_WIN          equ 24                  ; its window, while it is one's
MV_FROM         equ 32                  ; x, y, w, h: the window at the start,
MV_TO           equ 64                  ; at the end,
MV_NOW          equ 96                  ; and now
MV_A0           equ 128                 ; dword: how much of it shows at the
MV_A1           equ 132                 ; start, at the end (0..256),
MV_ALPHA        equ 136                 ; and now
MV_LAYER        equ 140                 ; dword MVL_*
MV_DRAWN        equ 144                 ; x, y, w, h: its picture as drawn (w 0: not yet)
MV_PW           equ 176                 ; the window's size in the picture,
MV_PH           equ 184
MV_PM           equ 192                 ; and the margin around it (its shadow)
MV_ASKED        equ 200                 ; when it was asked for (MVK_OPEN)
MV_PIC          equ 208                 ; SF_SIZE * MV_LEVELS: the picture, its halves
MV_SIZE         equ MV_PIC + SF_SIZE * MV_LEVELS

MVK_OPEN        equ 1                   ; a window shows: it grows into place
MVK_CLOSE       equ 2                   ; one goes: it shrinks away
MVK_MIN         equ 3                   ; into its place in the dock
MVK_BACK        equ 4                   ; out of the dock
MVK_ZOOM        equ 5                   ; from one rectangle to another
MVK_FADE        equ 6                   ; a part of the screen (a menu closing)

MVE_OUT         equ 0                   ; quick, then slowing
MVE_IN_OUT      equ 1                   ; slow, quick, slow

MVL_WINS        equ 0                   ; over the windows, under the dock
MVL_TOP         equ 1                   ; over the dock
MVL_MENU        equ 2                   ; over all

MV_FRAME_MS     equ 16                  ; a step each (about 60 a second)
MV_OPEN_MS      equ 200
MV_CLOSE_MS     equ 160
MV_MIN_MS       equ 380
MV_ZOOM_MS      equ 240
MV_FADE_MS      equ 180
MV_WAIT_MS      equ 300                 ; a program's new window: for its pixels, at most
MV_KEEP_MS      equ 10000               ; the pictures' memory, kept once nothing moves

%macro MV_PUT 1                         ; RDI, RSI, RDX, RCX: into a rectangle of the slot RBX
    mov [rbx + %1], rdi
    mov [rbx + %1 + 8], rsi
    mov [rbx + %1 + 16], rdx
    mov [rbx + %1 + 24], rcx
%endmacro

%macro MV_GET 1                         ; and out of it
    mov rdi, [rbx + %1]
    mov rsi, [rbx + %1 + 8]
    mov rdx, [rbx + %1 + 16]
    mov rcx, [rbx + %1 + 24]
%endmacro

section .text

; -----------------------------------------------------------------------------
;  The steps
; -----------------------------------------------------------------------------

; motion_service: from the main loop, before the desk composes: a step of
; all that moves, when one is due
motion_service:
    RDTSC64
    cmp rax, [mv_due]
    jb .out
    push rbx
    push r12
    mov [mv_now], rax
    mov byte [mv_kicked], 0
    xor r12d, r12d                      ; R12D: anything still moving
    lea rbx, [mv_slots]
.slot:
    cmp dword [rbx + MV_KIND], 0
    je .next
    call mv_step
    or r12d, eax
.next:
    add rbx, MV_SIZE
    lea rax, [mv_slots + MV_SIZE * MV_MAX]
    cmp rbx, rax
    jb .slot
    call dock_motion                    ; the dock's own
    or r12d, eax
    call mn_motion                      ; a menu's item, chosen
    or r12d, eax
    test r12d, r12d
    jnz .moving
    call mv_spare                       ; the next step: none (or the
    jmp .due                            ; pictures' memory freed),
.moving:
    mov qword [mv_idle], 0
    mov rax, [tsc_per_ms]               ; or a frame on
    imul rax, rax, MV_FRAME_MS
    add rax, [mv_now]
.due:
    cmp byte [mv_kicked], 0             ; (or at once: something began)
    je .set
    xor eax, eax
.set:
    mov [mv_due], rax
    pop r12
    pop rbx
.out:
    ret

; mv_spare -> RAX = when motion_service is next wanted, -1 for never: with
; nothing moving, the pictures' memory is kept MV_KEEP_MS, then freed.
; Preserves others.
mv_spare:
    mov rax, -1
    cmp byte [mv_held], 0
    je .out
    cmp qword [mv_idle], 0
    jne .since
    mov rax, [mv_now]                   ; still from now
    mov [mv_idle], rax
.since:
    mov eax, MV_KEEP_MS
    imul rax, [tsc_per_ms]
    add rax, [mv_idle]
    cmp rax, [mv_now]
    ja .out
    push rbx
    push rcx
    push rdi
    lea rbx, [mv_slots]                 ; (all free, nothing moving)
.slot:
    xor ecx, ecx
.level:
    imul rdi, rcx, SF_SIZE
    lea rdi, [rbx + rdi + MV_PIC]
    call sf_free
    inc ecx
    cmp ecx, MV_LEVELS
    jb .level
    add rbx, MV_SIZE
    lea rax, [mv_slots + MV_SIZE * MV_MAX]
    cmp rbx, rax
    jb .slot
    lea rdi, [mv_black]
    call sf_free
    mov byte [mv_held], 0
    pop rdi
    pop rcx
    pop rbx
    mov rax, -1
.out:
    ret

; motion_deadline(RAX = when the main loop must wake) -> RAX = that, or the
; next step if sooner. Preserves others.
motion_deadline:
    cmp rax, [mv_due]
    jbe .out
    mov rax, [mv_due]
.out:
    ret

; mv_kick: something began to move: a step at once. Preserves all.
mv_kick:
    mov qword [mv_due], 0
    mov byte [mv_kicked], 1
    ret

; mv_on -> ZF set if nothing may move now (motion off, or no desk yet).
; Preserves all but the flags.
mv_on:
    cmp byte [desk_ready], 0
    je .out
    cmp dword [mv_scale], 0
.out:
    ret

; mv_ticks(EAX = milliseconds) -> RAX = TSC ticks, at the speed set.
; Preserves others.
mv_ticks:
    imul eax, [mv_scale]
    imul rax, [tsc_per_ms]
    ret

; mv_step(RBX = a slot) -> EAX = 1 if it goes on, 0 if it is done
mv_step:
    push r12
    push r13
    cmp qword [rbx + MV_T0], 0
    jne .timed
    mov rdi, [rbx + MV_WIN]             ; a window opening: its picture now
    test dword [rdi + WN_FLAGS], WF_PROGRAM
    jz .picture
    cmp byte [rdi + WN_INKED], 0        ; a program's: once it has drawn,
    jne .picture                        ; or it waited long enough
    mov eax, MV_WAIT_MS
    call mv_ticks
    add rax, [rbx + MV_ASKED]
    cmp rax, [mv_now]
    ja .going
.picture:
    call mv_picture
    jc .end
    MV_GET MV_FROM
    MV_PUT MV_NOW
    mov eax, [rbx + MV_A0]
    mov [rbx + MV_ALPHA], eax
    mov rax, [mv_now]
    mov [rbx + MV_T0], rax
.timed:
    mov rax, [mv_now]                   ; how far along: 0..65536
    sub rax, [rbx + MV_T0]
    jae .since
    xor eax, eax
.since:
    shl rax, 16
    xor edx, edx
    mov rcx, [rbx + MV_DUR]
    test rcx, rcx
    jz .whole
    div rcx
    cmp rax, 65536
    jb .along
.whole:
    mov eax, 65536
.along:
    mov r13d, eax                       ; R13D: that
    mov edx, [rbx + MV_EASE]
    call mv_ease
    mov r12, rax                        ; R12: that, eased
    cmp dword [rbx + MV_KIND], MVK_MIN  ; into the dock: its place there now
    jne .lerp
    mov rdi, [rbx + MV_WIN]
    call dock_spot
    jc .lerp
    MV_PUT MV_TO
.lerp:
    xor ecx, ecx                        ; now: from + (to - from) * eased
.each:
    mov rax, [rbx + rcx + MV_TO]
    sub rax, [rbx + rcx + MV_FROM]
    imul rax, r12
    sar rax, 16
    add rax, [rbx + rcx + MV_FROM]
    mov [rbx + rcx + MV_NOW], rax
    add ecx, 8
    cmp ecx, 32
    jb .each
    cmp qword [rbx + MV_NOW + 16], 1    ; (a pixel at least)
    jge .w
    mov qword [rbx + MV_NOW + 16], 1
.w:
    cmp qword [rbx + MV_NOW + 24], 1
    jge .h
    mov qword [rbx + MV_NOW + 24], 1
.h:
    mov eax, [rbx + MV_A1]
    sub eax, [rbx + MV_A0]
    imul eax, r12d
    sar eax, 16
    add eax, [rbx + MV_A0]
    mov [rbx + MV_ALPHA], eax
    call mv_redraw
    cmp r13d, 65536
    jae .end
.going:
    mov eax, 1
    jmp .out
.end:
    call mv_end
    xor eax, eax
.out:
    pop r13
    pop r12
    ret

; mv_ease(EAX = how far along, 0..65536; EDX = MVE_*) -> RAX = that, eased.
; Preserves others.
mv_ease:
    push rcx
    push rdx
    mov ecx, eax
    cmp edx, MVE_IN_OUT
    je .in_out
    mov eax, 65536                      ; quick, then slowing: 1 - (1 - p)^3
    sub eax, ecx
    call .cube
    mov ecx, 65536
    sub ecx, eax
    mov eax, ecx
    jmp .out
.in_out:
    cmp ecx, 32768                      ; the first half: 4 p^3
    jae .second
    mov eax, ecx
    call .cube
    shl eax, 2
    jmp .out
.second:
    mov eax, 65536                      ; the second: 1 - 4 (1 - p)^3
    sub eax, ecx
    call .cube
    shl eax, 2
    mov ecx, 65536
    sub ecx, eax
    mov eax, ecx
.out:
    pop rdx
    pop rcx
    ret
; EAX = x, 0..65536 -> RAX = x^3, 16.16. Clobbers RDX.
.cube:
    mov edx, eax
    imul rax, rdx
    shr rax, 16
    imul rax, rdx
    shr rax, 16
    ret

; mv_bounds(RBX = a slot) -> RDI x, RSI y, RDX w, RCX h: its picture where
; the window is now (MV_NOW), its margin scaled as it is. Preserves others
; but RAX.
mv_bounds:
    push r8
    push r9
    push r10
    mov r8, [rbx + MV_NOW + 16]         ; its size now
    mov r9, [rbx + MV_NOW + 24]
    mov rax, [rbx + MV_PM]              ; the margin across, scaled,
    imul rax, r8
    xor edx, edx
    div qword [rbx + MV_PW]
    mov r10, rax
    mov rax, [rbx + MV_PM]              ; and down
    imul rax, r9
    xor edx, edx
    div qword [rbx + MV_PH]
    mov rsi, [rbx + MV_NOW + 8]
    sub rsi, rax
    lea rcx, [r9 + rax * 2]
    mov rdi, [rbx + MV_NOW]
    sub rdi, r10
    lea rdx, [r8 + r10 * 2]
    pop r10
    pop r9
    pop r8
    ret

; mv_redraw(RBX = a slot): its picture where the window is now; where it
; was drawn and where it is, composed again. Preserves others but RAX,
; RCX, RDX, RSI, RDI.
mv_redraw:
    push r8
    push r9
    push r10
    push r11
    call mv_bounds
    mov r8, [rbx + MV_DRAWN]            ; and the rectangle around it and
    mov r9, [rbx + MV_DRAWN + 8]        ; where it was
    mov r10, [rbx + MV_DRAWN + 16]
    mov r11, [rbx + MV_DRAWN + 24]
    MV_PUT MV_DRAWN
    test r10, r10
    jz .damage
    add r10, r8                         ; to edges
    add r11, r9
    add rdx, rdi
    add rcx, rsi
    cmp r8, rdi
    jge .x0
    mov rdi, r8
.x0:
    cmp r9, rsi
    jge .y0
    mov rsi, r9
.y0:
    cmp r10, rdx
    jle .x1
    mov rdx, r10
.x1:
    cmp r11, rcx
    jle .y1
    mov rcx, r11
.y1:
    sub rdx, rdi
    sub rcx, rsi
.damage:
    call mv_damage
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; mv_damage(RBX = a slot, RDI x, RSI y, RDX w, RCX h): to be composed again
; (over the dock, what is behind the dock's glass is as it was). Preserves
; all.
mv_damage:
    push r8
    xor r8d, r8d
    cmp dword [rbx + MV_LAYER], MVL_WINS
    je .damage
    lea r8, [dock_gl]
.damage:
    call desk_damage_own
    pop r8
    ret

; mv_begin(RBX = a slot, MV_NOW set): it begins now, drawn at once.
; Preserves all.
mv_begin:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    RDTSC64
    mov [rbx + MV_T0], rax
    call mv_redraw
    call mv_kick
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; mv_end(RBX = a slot): done: the window it was drawn as it is again, and
; where it was drawn, composed; its picture's memory kept (mv_spare frees
; it). Preserves all.
mv_end:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    MV_GET MV_DRAWN                     ; where it was drawn
    test rdx, rdx
    jz .drawn
    call mv_damage
.drawn:
    mov rdi, [rbx + MV_WIN]
    test rdi, rdi
    jz .free
    and dword [rdi + WN_FLAGS], ~WF_ANIM
    cmp dword [rbx + MV_KIND], MVK_MIN
    je .dock
    call win_damage_whole
    jmp .free
.dock:
    call dock_damage                    ; (its picture there now)
.free:
    mov dword [rbx + MV_KIND], 0
    mov qword [rbx + MV_WIN], 0
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; mv_slot -> RBX = a free slot, cleared, its picture empty (its memory, if
; it has any, kept), CF if none. Preserves others.
mv_slot:
    push rax
    lea rbx, [mv_slots]
.each:
    cmp dword [rbx + MV_KIND], 0
    je .found
    add rbx, MV_SIZE
    lea rax, [mv_slots + MV_SIZE * MV_MAX]
    cmp rbx, rax
    jb .each
    pop rax
    stc
    ret
.found:
    push rcx
    push rdi
    mov rdi, rbx
    mov ecx, MV_PIC
    xor eax, eax
    rep stosb
    xor ecx, ecx                        ; its levels: none yet
.level:
    imul rdi, rcx, SF_SIZE
    mov qword [rbx + rdi + MV_PIC + SF_W], 0
    mov qword [rbx + rdi + MV_PIC + SF_H], 0
    inc ecx
    cmp ecx, MV_LEVELS
    jb .level
    mov byte [mv_held], 1               ; (memory, perhaps, from now)
    pop rdi
    pop rcx
    pop rax
    clc
    ret

; mv_find(RDI = a window) -> RBX = its slot, CF if none. Preserves others.
mv_find:
    push rax
    lea rbx, [mv_slots]
.each:
    cmp dword [rbx + MV_KIND], 0
    je .next
    cmp [rbx + MV_WIN], rdi
    je .found
.next:
    add rbx, MV_SIZE
    lea rax, [mv_slots + MV_SIZE * MV_MAX]
    cmp rbx, rax
    jb .each
    pop rax
    stc
    ret
.found:
    pop rax
    clc
    ret

; mv_forget(RDI = a window): whatever of it moves, done with now: it is
; drawn as it is. Preserves all.
mv_forget:
    push rbx
.again:
    call mv_find
    jc .out
    call mv_end
    jmp .again
.out:
    pop rbx
    ret

; mv_moving(RDI = a window) -> ZF clear if it moves (opening, into the dock
; or out, zooming). Preserves all but the flags.
mv_moving:
    test dword [rdi + WN_FLAGS], WF_ANIM
    ret

; -----------------------------------------------------------------------------
;  What begins to move
; -----------------------------------------------------------------------------

; mv_open(RDI = a window): it shows, growing into place (its picture taken
; at its first step: what it shows by then). Preserves all.
mv_open:
    call mv_on
    jz .out0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call mv_forget
    call mv_slot
    jc .out
    mov dword [rbx + MV_KIND], MVK_OPEN
    mov dword [rbx + MV_EASE], MVE_OUT
    mov dword [rbx + MV_LAYER], MVL_WINS
    mov [rbx + MV_WIN], rdi
    or dword [rdi + WN_FLAGS], WF_ANIM
    mov eax, MV_OPEN_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    RDTSC64
    mov [rbx + MV_ASKED], rax
    call win_outer
    MV_PUT MV_TO
    mov eax, 60000                      ; from a little smaller, and nothing
    call rect_scale
    MV_PUT MV_FROM
    mov dword [rbx + MV_A1], 256
    call mv_kick
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; mv_close(RDI = a window, about to go or be put away): it shrinks away,
; from a picture of it now. Preserves all.
mv_close:
    call mv_on
    jz .out0
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .out0
    test dword [rdi + WN_FLAGS], WF_ANIM ; moving still: it just goes
    jnz mv_forget
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call mv_slot
    jc .out
    call mv_picture
    jc .none
    mov dword [rbx + MV_KIND], MVK_CLOSE
    mov dword [rbx + MV_EASE], MVE_OUT
    mov dword [rbx + MV_LAYER], MVL_WINS
    mov eax, MV_CLOSE_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    call win_outer
    MV_PUT MV_FROM
    MV_PUT MV_NOW
    mov eax, 60000                      ; to a little smaller, and nothing
    call rect_scale
    MV_PUT MV_TO
    mov dword [rbx + MV_A0], 256
    mov dword [rbx + MV_ALPHA], 256
    call mv_begin
    jmp .out
.none:
    call mv_end                         ; (what of the picture there was)
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; mv_minimise(RDI = a window, about to be minimised): into its place in the
; dock (found as the dock is laid out again), from a picture of it now; or
; back the way it came, if it is coming out. Preserves all.
mv_minimise:
    call mv_on
    jz .out0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call mv_find
    jc .new
    cmp dword [rbx + MV_KIND], MVK_BACK
    jne .forget
    mov dword [rbx + MV_KIND], MVK_MIN  ; turned around, from where it is
    call mv_turn
    jmp .out
.forget:
    call mv_forget
.new:
    call mv_slot
    jc .out
    call mv_picture
    jc .none
    mov dword [rbx + MV_KIND], MVK_MIN
    mov dword [rbx + MV_EASE], MVE_IN_OUT
    mov dword [rbx + MV_LAYER], MVL_TOP
    mov [rbx + MV_WIN], rdi
    or dword [rdi + WN_FLAGS], WF_ANIM  ; (its place in the dock: empty till then)
    mov eax, MV_MIN_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    call win_outer
    MV_PUT MV_FROM
    MV_PUT MV_TO
    MV_PUT MV_NOW
    mov dword [rbx + MV_A0], 256
    mov dword [rbx + MV_A1], 200
    mov dword [rbx + MV_ALPHA], 256
    call mv_begin
    jmp .out
.none:
    call mv_end
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; mv_back(RDI = a window, minimised, about to be shown): out of its place in
; the dock, from a picture of it; or back the way it went, if it is going
; in. Preserves all.
mv_back:
    call mv_on
    jz .out0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    call mv_find
    jc .new
    cmp dword [rbx + MV_KIND], MVK_MIN
    jne .forget
    mov dword [rbx + MV_KIND], MVK_BACK ; turned around, from where it is
    call mv_turn
    jmp .out
.forget:
    call mv_forget
.new:
    call mv_slot
    jc .out
    call dock_spot                      ; where it is in the dock
    jc .open
    MV_PUT MV_FROM
    MV_PUT MV_NOW
    mov rdi, r12
    call mv_picture
    jc .none
    mov dword [rbx + MV_KIND], MVK_BACK
    mov dword [rbx + MV_EASE], MVE_IN_OUT
    mov dword [rbx + MV_LAYER], MVL_TOP
    mov [rbx + MV_WIN], r12
    or dword [r12 + WN_FLAGS], WF_ANIM
    mov eax, MV_MIN_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    mov rdi, r12
    call win_outer
    MV_PUT MV_TO
    mov dword [rbx + MV_A0], 200
    mov dword [rbx + MV_A1], 256
    mov dword [rbx + MV_ALPHA], 200
    call mv_begin
    jmp .out
.none:
    call mv_end
    jmp .out
.open:
    mov rdi, r12                        ; not in the dock: it opens
    call mv_open
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; mv_turn(RBX = a slot, its kind just turned between MVK_MIN and MVK_BACK):
; from where it is now, the other way. Preserves all.
mv_turn:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    MV_GET MV_NOW
    MV_PUT MV_FROM
    mov eax, [rbx + MV_ALPHA]
    mov [rbx + MV_A0], eax
    mov dword [rbx + MV_A1], 200
    cmp dword [rbx + MV_KIND], MVK_MIN
    je .time
    mov dword [rbx + MV_A1], 256
    mov rdi, [rbx + MV_WIN]
    call win_outer
    MV_PUT MV_TO
.time:
    RDTSC64
    mov [rbx + MV_T0], rax
    call mv_kick
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; mv_zoom(RDI = a window, just zoomed or back; RSI x, RDX y, RCX w, R8 h:
; the window where it was): from there to where it is now, from a picture
; of it now. Preserves all.
mv_zoom:
    call mv_on
    jz .out0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call mv_forget
    call mv_slot
    jc .out
    mov [rbx + MV_FROM], rsi
    mov [rbx + MV_FROM + 8], rdx
    mov [rbx + MV_FROM + 16], rcx
    mov [rbx + MV_FROM + 24], r8
    mov [rbx + MV_NOW], rsi
    mov [rbx + MV_NOW + 8], rdx
    mov [rbx + MV_NOW + 16], rcx
    mov [rbx + MV_NOW + 24], r8
    call mv_picture
    jc .none
    mov dword [rbx + MV_KIND], MVK_ZOOM
    mov dword [rbx + MV_EASE], MVE_OUT
    mov dword [rbx + MV_LAYER], MVL_WINS
    mov [rbx + MV_WIN], rdi
    or dword [rdi + WN_FLAGS], WF_ANIM
    mov eax, MV_ZOOM_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    call win_outer
    MV_PUT MV_TO
    mov dword [rbx + MV_A0], 256
    mov dword [rbx + MV_A1], 256
    mov dword [rbx + MV_ALPHA], 256
    call mv_begin
    jmp .out
.none:
    call mv_end
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; mv_fade(RDI x, RSI y, RDX w, RCX h): that part of the screen, as the back
; buffer has it now, fading away over what is composed there after.
; Preserves all.
mv_fade:
    call mv_on
    jz .out0
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call gfx_clip_screen_signed
    jz .out
    call mv_slot
    jc .out
    MV_PUT MV_FROM
    MV_PUT MV_TO
    MV_PUT MV_NOW
    mov [rbx + MV_PW], rdx              ; (no margin)
    mov [rbx + MV_PH], rcx
    push rdi
    push rsi
    lea rdi, [rbx + MV_PIC]
    mov rsi, rdx
    mov rdx, rcx
    call sf_size
    pop rsi
    pop rdi
    jc .none
    mov rax, rsi                        ; from the back buffer, each pixel
    imul rax, [back_sf + SF_PITCH]      ; whole
    lea rax, [rax + rdi * 4]
    add rax, [back_sf + SF_PTR]
    mov r8, [rbx + MV_PIC + SF_PTR]
    mov r9, [rbx + MV_PIC + SF_H]
.row:
    mov rsi, rax
    mov rdi, r8
    mov rcx, [rbx + MV_PIC + SF_W]
    push rax
.px:
    lodsd
    or eax, 0xFF000000
    stosd
    dec rcx
    jnz .px
    pop rax
    add rax, [back_sf + SF_PITCH]
    add r8, [rbx + MV_PIC + SF_PITCH]
    dec r9
    jnz .row
    mov dword [rbx + MV_KIND], MVK_FADE
    mov dword [rbx + MV_EASE], MVE_OUT
    mov dword [rbx + MV_LAYER], MVL_MENU
    mov eax, MV_FADE_MS
    call mv_ticks
    mov [rbx + MV_DUR], rax
    mov dword [rbx + MV_A0], 256
    mov dword [rbx + MV_ALPHA], 256
    call mv_begin
    jmp .out
.none:
    call mv_end
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.out0:
    ret

; rect_scale(RDI x, RSI y, RDX w, RCX h, RAX = a factor, 16.16): the
; rectangle that much of its size, about its middle. Preserves others.
rect_scale:
    push r8
    push r9
    mov r8, rdx
    imul r8, rax
    sar r8, 16
    mov r9, rdx
    sub r9, r8
    sar r9, 1
    add rdi, r9
    mov rdx, r8
    mov r8, rcx
    imul r8, rax
    sar r8, 16
    mov r9, rcx
    sub r9, r8
    sar r9, 1
    add rsi, r9
    mov rcx, r8
    pop r9
    pop r8
    ret

; -----------------------------------------------------------------------------
;  Pictures
; -----------------------------------------------------------------------------

; mv_picture(RBX = a slot, RDI = a window) -> CF if there is no memory: its
; picture (MV_PIC and its halves; MV_PW, MV_PH, MV_PM): desk_frame's over
; black and over white, which give each pixel's color and how much of it
; there is. Preserves all but RAX.
mv_picture:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rax, [r12 + WN_W]               ; the window in it, and its shadow's
    mov [rbx + MV_PW], rax              ; margin around it
    mov rax, [r12 + WN_H]
    add rax, [fr_t]
    mov [rbx + MV_PH], rax
    mov rax, [fr_sh]
    mov [rbx + MV_PM], rax
    call win_extent
    mov r14, rdx                        ; R14, R15: the picture's size
    mov r15, rcx
    cmp r14, MV_LINE - 2
    ja .none
    lea rdi, [mv_black]
    mov rsi, r14
    mov rdx, r15
    call sf_size
    jc .none
    lea rdi, [rbx + MV_PIC]
    call sf_size
    jc .none
    push qword [r12 + WN_X]             ; drawn with its shadow's corner at
    push qword [r12 + WN_Y]             ; 0, 0
    mov rax, [fr_sh]
    mov [r12 + WN_X], rax
    mov [r12 + WN_Y], rax
    lea rdi, [mv_black]
    xor r8d, r8d
    call .drawn
    lea rdi, [rbx + MV_PIC]
    mov r8d, 0xFFFFFF
    call .drawn
    pop qword [r12 + WN_Y]
    pop qword [r12 + WN_X]
    call gfx_target_back
    mov rsi, [mv_black + SF_PTR]        ; each pixel, from the two
    mov rdi, [rbx + MV_PIC + SF_PTR]
    mov rcx, r14
    imul rcx, r15
    movdqa xmm5, [mv_green]
    pcmpeqb xmm6, xmm6
    movdqa xmm7, [mv_alpha]
.four:
    cmp rcx, 4                          ; four at once
    jb .rest
    movdqu xmm0, [rsi]                  ; over black: their colors
    movdqu xmm1, [rdi]                  ; over white: and what shows through
    psubusb xmm1, xmm0                  ; (green: white's less black's)
    pand xmm1, xmm5
    psrld xmm1, 8
    movdqa xmm2, xmm1                   ; in each byte of its pixel
    pslld xmm2, 8
    por xmm1, xmm2
    movdqa xmm2, xmm1
    pslld xmm2, 16
    por xmm1, xmm2
    pxor xmm1, xmm6                     ; how much of each there is
    por xmm0, xmm7                      ; its alpha that; its colors no more
    pminub xmm0, xmm1
    movdqu [rdi], xmm0
    add rsi, 16
    add rdi, 16
    sub rcx, 4
    jmp .four
.rest:
    test rcx, rcx
    jz .mixed
.px:
    mov eax, [rsi]                      ; over black: its color, premultiplied
    mov edx, [rdi]                      ; over white: and what shows through
    shr edx, 8
    and edx, 0xFF
    mov r8d, eax
    shr r8d, 8
    and r8d, 0xFF
    sub edx, r8d                        ; (green: white's less black's)
    jns .through
    xor edx, edx
.through:
    mov r8d, 255
    sub r8d, edx                        ; R8D: how much of it there is
    jns .much
    xor r8d, r8d
.much:
    mov edx, eax                        ; and its colors no more than that
    and edx, 0xFF
    cmp edx, r8d
    jbe .b
    mov edx, r8d
.b:
    mov r9d, edx
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    cmp edx, r8d
    jbe .g
    mov edx, r8d
.g:
    shl edx, 8
    or r9d, edx
    mov edx, eax
    shr edx, 16
    and edx, 0xFF
    cmp edx, r8d
    jbe .r
    mov edx, r8d
.r:
    shl edx, 16
    or r9d, edx
    shl r8d, 24
    or r9d, r8d
    mov [rdi], r9d
    add rsi, 4
    add rdi, 4
    dec rcx
    jnz .px
.mixed:
    lea rsi, [rbx + MV_PIC]             ; its halves, to draw it small
    mov r13d, 1
.half:
    cmp r13d, MV_LEVELS
    jae .made
    cmp qword [rsi + SF_W], 48
    jb .made
    cmp qword [rsi + SF_H], 48
    jb .made
    lea rdi, [rsi + SF_SIZE]
    call pic_half
    jc .made
    add rsi, SF_SIZE
    inc r13d
    jmp .half
.made:
    mov rdi, r12
    clc
    jmp .out
.none:
    lea rdi, [mv_black]
    call sf_free
    mov rdi, r12
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret
; RDI = a surface, R8D = a color: it, all that color; the window over it
.drawn:
    call gfx_target
    xor edi, edi
    xor esi, esi
    mov rdx, r14
    mov rcx, r15
    call gfx_fill
    mov rdi, r12
    jmp desk_frame

; pic_half(RSI = a picture's level, RDI = the next) -> CF if there is no
; memory: the next, half the size: each pixel the mean of two by two (at
; the right and the bottom, of what there is). Preserves all.
pic_half:
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
    mov rbx, rsi
    mov r8, rdi
    mov rsi, [rbx + SF_W]
    inc rsi
    shr rsi, 1
    mov rdx, [rbx + SF_H]
    inc rdx
    shr rdx, 1
    call sf_size
    jc .out
    xor r9d, r9d                        ; its rows
.row:
    cmp r9, [r8 + SF_H]
    jae .done
    lea rax, [r9 + r9]                  ; from two rows (the last, alone)
    lea rcx, [rax + 1]
    cmp rcx, [rbx + SF_H]
    jb .two
    mov rcx, rax
.two:
    imul rax, [rbx + SF_PITCH]
    add rax, [rbx + SF_PTR]
    imul rcx, [rbx + SF_PITCH]
    add rcx, [rbx + SF_PTR]
    mov r10, r9
    imul r10, [r8 + SF_PITCH]
    add r10, [r8 + SF_PTR]
    mov r11, [rbx + SF_W]               ; whole pairs
    shr r11, 1
    jz .last
.pair:
    movq xmm0, [rax]
    movq xmm1, [rcx]
    pavgb xmm0, xmm1                    ; down,
    pshuflw xmm1, xmm0, 0xEE
    pavgb xmm0, xmm1                    ; and across
    movd [r10], xmm0
    add rax, 8
    add rcx, 8
    add r10, 4
    dec r11
    jnz .pair
.last:
    test byte [rbx + SF_W], 1           ; a column left alone
    jz .next
    movd xmm0, [rax]
    movd xmm1, [rcx]
    pavgb xmm0, xmm1
    movd [r10], xmm0
.next:
    inc r9
    jmp .row
.done:
    clc
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

; motion_paint(EDI = a layer, MVL_*): what moves there, within the clip.
; Preserves all.
motion_paint:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r12
    mov r12d, edi
    lea rbx, [mv_slots]
.slot:
    cmp dword [rbx + MV_KIND], 0
    je .next
    cmp [rbx + MV_LAYER], r12d
    jne .next
    MV_GET MV_DRAWN
    test rdx, rdx
    jz .next
    lea r8, [rbx + MV_PIC]
    mov r9d, [rbx + MV_ALPHA]
    mov r10d, MV_LEVELS
    call pic_draw
.next:
    add rbx, MV_SIZE
    lea rax, [mv_slots + MV_SIZE * MV_MAX]
    cmp rbx, rax
    jb .slot
    pop r12
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

; pic_draw(RDI x, RSI y, RDX w, RCX h, R8 = a picture: R10 levels, each a
; surface of premultiplied B,G,R,A half the last's size (one with no
; pixels ends them); R9D = how much of it shows, 0..256): the picture
; scaled to that rectangle, over the target within the clip - smoothly,
; between its pixels, from the smallest level at least that size.
; Preserves all.
pic_draw:
    test r9d, r9d
    jz .none
    test rdx, rdx
    jle .none
    test rcx, rcx
    jle .none
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov [pd_x], rdi
    mov [pd_y], rsi
    mov [pd_w], rdx
    mov [pd_h], rcx
    mov [pd_a], r9d
    mov rbx, r8                         ; RBX: the level
    dec r10
.level:
    test r10, r10
    jz .chosen
    cmp qword [rbx + SF_SIZE + SF_PTR], 0
    je .chosen
    cmp [rbx + SF_SIZE + SF_W], rdx
    jb .chosen
    cmp [rbx + SF_SIZE + SF_H], rcx
    jb .chosen
    add rbx, SF_SIZE
    dec r10
    jmp .level
.chosen:
    cmp qword [rbx + SF_PTR], 0
    je .out
    mov r14, [rbx + SF_W]               ; R14, R15: its size
    mov r15, [rbx + SF_H]
    test r14, r14
    jz .out
    test r15, r15
    jz .out
    cmp r14, MV_LINE - 2
    ja .out
    mov rax, r14                        ; its pixels for each of the
    shl rax, 16                         ; rectangle's, 16.16
    xor edx, edx
    div qword [pd_w]
    mov [pd_sx], rax
    mov rax, r15
    shl rax, 16
    xor edx, edx
    div qword [pd_h]
    mov [pd_sy], rax
    mov rdi, [pd_x]                     ; within the clip
    mov rsi, [pd_y]
    mov rdx, [pd_w]
    mov rcx, [pd_h]
    call gfx_clip
    jz .out
    mov [pd_cx], rdi
    mov [pd_cw], rdx
    mov r13, rcx                        ; R13: rows
    mov rbp, rsi                        ; RBP: the row on the target
    mov rax, rdi                        ; its first column, where in the
    sub rax, [pd_x]                     ; picture (signed)
    call pd_u
    mov [pd_u0], rax
    test rax, rax
    jns .k0
    xor eax, eax
.k0:
    shr rax, 16
    mov [pd_k0], rax                    ; the first column read
    mov rax, rdi                        ; and the last: the one after that
    add rax, rdx                        ; of the last pixel
    dec rax
    sub rax, [pd_x]
    call pd_u
    test rax, rax
    jns .k1
    xor eax, eax
.k1:
    shr rax, 16
    inc rax
    cmp rax, r14
    jb .k2
    lea rax, [r14 - 1]
.k2:
    sub rax, [pd_k0]
    inc rax
    mov r12, rax                        ; R12: the columns read
    lea r11, [r14 - 1]                  ; R11: the last column, 16.16
    shl r11, 16
    pxor xmm7, xmm7
    movd xmm6, [pd_a]
    pshuflw xmm6, xmm6, 0               ; how much shows, four words
.row:
    mov rax, rbp                        ; where in the picture: between rows
    sub rax, [pd_y]                     ; y0 and y0 + 1, fy of the way
    call pd_v
    mov rcx, rax
    shr rcx, 16
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    lea r8, [rcx + 1]
    cmp r8, r15
    jb .y1
    mov r8, rcx
.y1:
    imul rcx, [rbx + SF_PITCH]
    add rcx, [rbx + SF_PTR]
    imul r8, [rbx + SF_PITCH]
    add r8, [rbx + SF_PTR]
    mov rax, [pd_k0]
    lea rcx, [rcx + rax * 4]
    lea r8, [r8 + rax * 4]
    mov eax, 256                        ; the two rows as one line:
    sub eax, edx                        ; (y0 (256 - fy) + y1 fy) / 256
    movd xmm4, eax
    pshuflw xmm4, xmm4, 0
    punpcklqdq xmm4, xmm4
    movd xmm5, edx
    pshuflw xmm5, xmm5, 0
    punpcklqdq xmm5, xmm5
    lea rdi, [mv_line]
    mov r9, r12
.pair:
    cmp r9, 2
    jb .one
    movq xmm0, [rcx]
    movq xmm1, [r8]
    punpcklbw xmm0, xmm7
    punpcklbw xmm1, xmm7
    pmullw xmm0, xmm4
    pmullw xmm1, xmm5
    paddw xmm0, xmm1
    psrlw xmm0, 8
    packuswb xmm0, xmm0
    movq [rdi], xmm0
    add rcx, 8
    add r8, 8
    add rdi, 8
    sub r9, 2
    jmp .pair
.one:
    test r9, r9
    jz .spare
    movd xmm0, [rcx]
    movd xmm1, [r8]
    punpcklbw xmm0, xmm7
    punpcklbw xmm1, xmm7
    pmullw xmm0, xmm4
    pmullw xmm1, xmm5
    paddw xmm0, xmm1
    psrlw xmm0, 8
    packuswb xmm0, xmm0
    movd [rdi], xmm0
    add rdi, 4
.spare:
    mov eax, [rdi - 4]                  ; one more, as the last
    mov [rdi], eax
    mov rdi, rbp                        ; across: each pixel between two of
    imul rdi, [tg_pitch]                ; the line, over the target's
    mov rax, [pd_cx]
    lea rdi, [rdi + rax * 4]
    add rdi, [tg_ptr]
    mov rcx, [pd_cw]
    mov r8, [pd_u0]                     ; R8: where in the picture, 16.16
    mov r9, [pd_k0]
    shl r9, 16                          ; R9: the line's first column
    lea r10, [mv_line]
.px:
    mov rax, r8
    test rax, rax
    jns .left
    xor eax, eax
.left:
    cmp rax, r11
    jle .right
    mov rax, r11
.right:
    sub rax, r9
    mov edx, eax
    shr rax, 16                         ; its column in the line,
    shr edx, 8
    and edx, 0xFF                       ; and fx of the way to the next
    movq xmm0, [r10 + rax * 4]
    punpcklbw xmm0, xmm7
    mov eax, 256
    sub eax, edx
    movd xmm1, eax
    pshuflw xmm1, xmm1, 0
    movd xmm2, edx
    pshuflw xmm2, xmm2, 0
    punpcklqdq xmm1, xmm2               ; 256 - fx four times, fx four times
    pmullw xmm0, xmm1
    movdqa xmm1, xmm0
    psrldq xmm1, 8
    paddw xmm0, xmm1
    psrlw xmm0, 8                       ; the pixel, four words
    cmp dword [pd_a], 256
    jae .whole
    pmullw xmm0, xmm6
    psrlw xmm0, 8
.whole:
    pextrw eax, xmm0, 3                 ; how much of it there is
    test eax, eax
    jz .next
    mov edx, eax
    shr edx, 7
    add eax, edx
    mov edx, 256
    sub edx, eax                        ; and of the target's pixel under it
    jbe .over
    movd xmm1, [rdi]
    punpcklbw xmm1, xmm7
    movd xmm2, edx
    pshuflw xmm2, xmm2, 0
    pmullw xmm1, xmm2
    psrlw xmm1, 8
    paddw xmm0, xmm1
.over:
    packuswb xmm0, xmm0
    movd [rdi], xmm0
.next:
    add r8, [pd_sx]
    add rdi, 4
    dec rcx
    jnz .px
    inc rbp
    dec r13
    jnz .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.none:
    ret

; pd_u(RAX = a column of pic_draw's rectangle) -> RAX = where its middle is
; in the picture, 16.16, from the middle of the first pixel (signed).
; Preserves others.
pd_u:
    lea rax, [rax * 2 + 1]
    imul rax, [pd_sx]
    sar rax, 1
    sub rax, 32768
    ret

; pd_v(RAX = a row of it, R15 = the picture's height) -> RAX = where in the
; picture, 16.16, within it. Preserves others.
pd_v:
    lea rax, [rax * 2 + 1]
    imul rax, [pd_sy]
    sar rax, 1
    sub rax, 32768
    jns .top
    xor eax, eax
.top:
    push rdx
    lea rdx, [r15 - 1]
    shl rdx, 16
    cmp rax, rdx
    jle .in
    mov rax, rdx
.in:
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  The dock: magnified round the pointer, an app's icon bouncing as it starts
;
;  Over the dock, each icon grows by how near the pointer it is: 1 + g f(d),
;  f a smooth bump (1 - (d/R)^2)^2 reaching R, 2.5 places. Each moves away
;  from the pointer by g F(d), F the bump's integral, so that they stand side
;  by side as they grow; the one under the pointer stays under it (so where
;  the pointer is, dock_at finds the item it would have unmagnified). g eases
;  to 0.6 as the pointer comes, back to 0 as it goes. Icons grow upwards,
;  over the glass, which widens round them.
; -----------------------------------------------------------------------------

DOCK_G          equ 39322               ; magnified the most: 0.6 bigger, 16.16
DOCK_RAMP_MS    equ 160                 ; to that, or back
BOUNCE_MS       equ 500                 ; an icon's bounce, up and down
BOUNCE_MAX      equ 3                   ; at most, with no window yet

; dock_point: the pointer moved: over the dock, it magnifies round it; off
; it, back. Preserves all.
dock_point:
    push rax
    push rcx
    call mv_on
    jz .off
    xor ecx, ecx                        ; ECX: over it
    cmp qword [dock_w], 0
    je .set
    cmp byte [drag_mode], DRAG_NONE
    jne .set
    cmp qword [desk_screen], 0          ; (full screen: no dock)
    jne .set
    mov rax, [ptr_y]
    cmp rax, [dock_mtop]
    jl .set
    mov rax, [ptr_x]
    cmp rax, [dock_mx0]
    jl .set
    cmp rax, [dock_mx1]
    jge .set
    mov ecx, 1
    cmp rax, [dock_px]                  ; round it, as it moves
    je .set
    mov [dock_px], rax
    cmp qword [dock_ramp], 0
    je .set
    call dock_magnify
    call dock_damage
.set:
    cmp cl, [dock_over]
    je .out
    mov [dock_over], cl                 ; magnifying, or back: from now
    push rdx
    RDTSC64
    mov [dock_ramp_t], rax
    pop rdx
    call mv_kick
.out:
    pop rcx
    pop rax
    ret
.off:
    mov byte [dock_over], 0             ; (motion off: not at all)
    cmp qword [dock_ramp], 0
    je .out
    mov qword [dock_ramp], 0
    call dock_magnify
    call dock_damage
    jmp .out

; dock_motion -> EAX = 1 while the dock moves on: magnifying or back, an
; app's icon bouncing (motion_service's step)
dock_motion:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    xor r12d, r12d                      ; R12D: it moves on
    cmp dword [mv_scale], 0
    je .still                           ; (motion off: dock_point undoes it)
    mov rax, [dock_ramp]                ; magnifying, or back
    movzx ecx, byte [dock_over]
    shl ecx, 16
    cmp rax, rcx
    je .bounces
    mov rax, [mv_now]
    mov rdx, rax
    xchg rdx, [dock_ramp_t]
    sub rax, rdx                        ; since the last step
    jae .since
    xor eax, eax
.since:
    mov rcx, [tsc_per_ms]               ; (a tenth of a second at most)
    imul rcx, rcx, 100
    cmp rax, rcx
    jbe .step
    mov rax, rcx
.step:
    shl rax, 16                         ; of the whole way
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, DOCK_RAMP_MS
    mov edx, [mv_scale]
    imul rcx, rdx
    xor edx, edx
    div rcx
    mov rcx, [dock_ramp]
    cmp byte [dock_over], 0
    je .back
    add rcx, rax
    cmp rcx, 1 << 16
    jb .ramped
    mov ecx, 1 << 16
    jmp .ramped
.back:
    sub rcx, rax
    ja .ramped
    xor ecx, ecx
.ramped:
    mov [dock_ramp], rcx
    call dock_magnify
    call dock_damage
    movzx eax, byte [dock_over]
    shl eax, 16
    cmp rcx, rax
    je .bounces
    mov r12d, 1
.bounces:
    xor ebx, ebx                        ; each app's icon bouncing
    xor esi, esi                        ; ESI: any
.app:
    lea rax, [dock_bounce]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .app_next
    mov esi, 1
    mov rax, [mv_now]
    sub rax, rcx
    jbe .going
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, BOUNCE_MS
    mov edx, [mv_scale]
    imul rcx, rdx
    xor edx, edx
    div rcx                             ; RAX: bounces done
    lea rcx, [dock_bounces]
    cmp rax, [rcx + rbx * 8]
    je .going                           ; this one goes on
    mov [rcx + rbx * 8], rax            ; one more done: it stays down if its
    cmp rax, BOUNCE_MAX                 ; window is there, or that was enough
    jae .stop
    mov edi, ebx
    call dock_running
    test eax, eax
    jz .going
.stop:
    lea rax, [dock_bounce]
    mov qword [rax + rbx * 8], 0
    jmp .app_next
.going:
    mov r12d, 1
.app_next:
    inc ebx
    cmp ebx, DOCK_APPS
    jb .app
    test esi, esi
    jz .still
    call dock_damage
.still:
    mov eax, r12d
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; dock_magnify: each item's place and side, magnified round dock_px as far
; as dock_ramp has come (DI_MX its left, DI_MS its side); the glass's ends
; round them (dock_mx0, dock_mx1), the icons' top (dock_mtop). Preserves all.
dock_magnify:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov rax, [dock_ramp]                ; g: of DOCK_G, eased (p^2 (3 - 2p))
    mov rcx, rax
    imul rcx, rax
    mov rdx, 3 << 16
    sub rdx, rax
    sub rdx, rax
    imul rcx, rdx
    shr rcx, 32
    imul rcx, rcx, DOCK_G
    shr rcx, 16
    mov [dock_gm], rcx
    mov rsi, [m_icon]                   ; RSI: the biggest
    lea r8, [dock_items]
    xor r9d, r9d
.item:
    cmp r9, [dock_n]
    jae .ends
    mov r10, [m_icon]                   ; R10: its middle, unmagnified
    shr r10, 1
    add r10, [r8 + DI_X]
    mov r11, r10                        ; R11: the pointer to it
    sub r11, [dock_px]
    mov rax, r11
    test rax, rax
    jns .near
    neg rax
.near:
    call dock_bump                      ; RAX = f, RDX = F
    imul rax, [dock_gm]                 ; its side: 1 + g f times
    shr rax, 16
    imul rax, [m_icon]
    add rax, 1 << 15
    shr rax, 16
    add rax, [m_icon]
    mov [r8 + DI_MS], rax
    cmp rax, rsi
    jbe .side
    mov rsi, rax
.side:
    mov rax, rdx                        ; its middle: g F further away
    imul rax, [dock_gm]
    mov rcx, 1 << 31
    add rax, rcx
    shr rax, 32
    test r11, r11
    jns .away
    neg rax
.away:
    add rax, r10
    mov rcx, [r8 + DI_MS]
    shr rcx, 1
    sub rax, rcx
    mov [r8 + DI_MX], rax
    add r8, DI_SIZE
    inc r9
    jmp .item
.ends:
    mov rax, [m_dock_y]                 ; the icons' top (the glass's, if
    add rax, [m_dock_pad]               ; higher)
    add rax, [m_icon]
    sub rax, rsi
    cmp rax, [m_dock_y]
    jle .top
    mov rax, [m_dock_y]
.top:
    mov [dock_mtop], rax
    mov rax, [dock_x]                   ; the glass: round the first and the
    mov rcx, [dock_w]                   ; last, their pad magnified as they
    add rcx, rax                        ; are
    mov r9, [dock_n]
    test r9, r9
    jz .glass
    lea r8, [dock_items]
    mov rax, [r8 + DI_MS]
    imul rax, [m_dock_pad]
    xor edx, edx
    div qword [m_icon]
    neg rax
    add rax, [r8 + DI_MX]
    mov r10, rax
    imul r9, r9, DI_SIZE
    lea r8, [r8 + r9 - DI_SIZE]
    mov rax, [r8 + DI_MS]
    imul rax, [m_dock_pad]
    xor edx, edx
    div qword [m_icon]
    add rax, [r8 + DI_MX]
    add rax, [r8 + DI_MS]
    mov rcx, rax
    mov rax, r10
.glass:
    mov [dock_mx0], rax
    mov [dock_mx1], rcx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; dock_bump(RAX = how far from the pointer, px) -> RAX = f, how much an icon
; there grows (16.16, 1 under the pointer, 0 from m_dock_reach on); RDX = F,
; the bump's integral to there (px, 16.16). Preserves others.
dock_bump:
    push rcx
    push rsi
    push rdi
    mov rcx, [m_dock_reach]
    cmp rax, rcx
    jae .past
    shl rax, 16
    xor edx, edx
    div rcx                             ; t = d / R
    mov rcx, rax
    imul rax, rax
    shr rax, 16
    mov rsi, rax                        ; t^2
    mov rdx, 1 << 16
    sub rdx, rax
    imul rdx, rdx
    shr rdx, 16
    push rdx                            ; f = (1 - t^2)^2
    mov rax, rsi
    imul rax, rcx
    shr rax, 16
    mov rdi, rax                        ; t^3
    imul rax, rsi
    shr rax, 16                         ; t^5
    imul rax, rax, 3                    ; F = R (t - 2/3 t^3 + 1/5 t^5)
    imul rdi, rdi, 10                   ;   = R (15 t - 10 t^3 + 3 t^5) / 15
    sub rax, rdi
    imul rcx, rcx, 15
    add rax, rcx
    imul rax, [m_dock_reach]
    xor edx, edx
    mov ecx, 15
    div rcx
    mov rdx, rax
    pop rax
    jmp .out
.past:
    mov rax, rcx                        ; F = R 8/15; f = 0
    shl rax, 19
    xor edx, edx
    mov ecx, 15
    div rcx
    mov rdx, rax
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; dock_extent -> RDI x0, RSI y0, RDX x1: what the dock draws now, the name
; over it too (down to the bottom of the screen). Preserves others.
dock_extent:
    push rax
    push rcx
    mov rdi, [dock_mx0]
    sub rdi, [m_icon]                   ; (a name may stand past its ends)
    mov rdx, [dock_mx1]
    add rdx, [m_icon]
    mov rsi, [dock_mtop]
    sub rsi, [m_tip_h]
    sub rsi, [m_tip_gap]
    sub rsi, [m_tip_gap]
    xor ecx, ecx                        ; an icon bouncing: higher still
.bounce:
    lea rax, [dock_bounce]
    cmp qword [rax + rcx * 8], 0
    jne .up
    inc ecx
    cmp ecx, DOCK_APPS
    jb .bounce
    jmp .out
.up:
    sub rsi, [m_bounce]
.out:
    pop rcx
    pop rax
    ret

; dock_rise(EAX = an app) -> RAX = how far up its icon is, bouncing.
; Preserves others.
dock_rise:
    push rcx
    push rdx
    mov eax, eax
    lea rcx, [dock_bounce]
    mov rcx, [rcx + rax * 8]
    test rcx, rcx
    jz .none
    mov rax, [mv_now]
    sub rax, rcx
    jbe .none
    mov edx, [mv_scale]
    test edx, edx
    jz .none
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, BOUNCE_MS
    imul rcx, rdx
    xor edx, edx
    div rcx                             ; RDX: into this bounce
    mov rax, rdx
    shl rax, 16
    xor edx, edx
    div rcx                             ; u: how far, 16.16
    mov rcx, 1 << 16                    ; up and down: 4 u (1 - u)
    sub rcx, rax
    imul rax, rcx
    shr rax, 14
    imul rax, [m_bounce]
    shr rax, 16
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; dock_bounce_start(EDI = an app): its icon bounces as it starts, until its
; window is there. Preserves all.
dock_bounce_start:
    call mv_on
    jz .out
    cmp edi, DOCK_APPS
    jae .out
    push rax
    push rcx
    push rdx
    mov ecx, edi
    lea rax, [dock_bounce]
    cmp qword [rax + rcx * 8], 0
    jne .done                           ; bouncing already
    RDTSC64
    lea rdx, [dock_bounce]
    mov [rdx + rcx * 8], rax
    lea rdx, [dock_bounces]
    mov qword [rdx + rcx * 8], 0
    call mv_kick
.done:
    pop rdx
    pop rcx
    pop rax
.out:
    ret

section .data
align 8
dock_seen_x0:   dq 0x7FFFFFFFFFFFFFFF   ; the dock as drawn last: its left,
dock_seen_x1:   dq -0x7FFFFFFFFFFFFFFF  ; its right,
dock_seen_y0:   dq 0x7FFFFFFFFFFFFFFF   ; its top
dock_mtop:      dq 0x3FFFFFFFFFFFFFFF   ; its icons' top, magnified

section .bss
alignb 8
dock_ramp:      resq 1                  ; how magnified: 0..65536, to be eased
dock_ramp_t:    resq 1                  ; when it last stepped
dock_px:        resq 1                  ; round where
dock_gm:        resq 1                  ; g: the most bigger, 16.16
dock_mx0:       resq 1                  ; the glass magnified: its left,
dock_mx1:       resq 1                  ; its right
dock_bounce:    resq DOCK_APPS          ; each app: when it began bouncing,
dock_bounces:   resq DOCK_APPS          ; and its bounces done
dock_over:      resb 1                  ; the pointer is over the dock

section .text

; -----------------------------------------------------------------------------
;  motion [on | off | slow]
; -----------------------------------------------------------------------------
cmd_motion:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .say
    call arg_split
    mov rdi, rsi
    mov edx, 1
    lea rsi, [str_mv_on]
    call streq
    test eax, eax
    jnz .set
    xor edx, edx
    lea rsi, [str_mv_off]
    call streq
    test eax, eax
    jnz .set
    mov edx, 10
    lea rsi, [str_mv_slow]
    call streq
    test eax, eax
    jnz .set
    KLOG "usage: motion [on | off | slow]"
    ret
.set:
    mov [mv_scale], edx
.say:
    mov eax, [mv_scale]
    lea rcx, [str_mv_off]
    test eax, eax
    jz .said
    lea rcx, [str_mv_on]
    cmp eax, 1
    je .said
    lea rcx, [str_mv_slow]
.said:
    KLOG "motion: %s", rcx
    ret

section .rodata
align 16
mv_green:       times 4 dd 0x0000FF00   ; mv_picture's: a pixel's green,
mv_alpha:       times 4 dd 0xFF000000   ; its alpha
str_mv_on:      db 'on', 0
str_mv_off:     db 'off', 0
str_mv_slow:    db 'slow', 0

section .data
align 8
mv_due:         dq -1                   ; when the next step is (TSC; -1: none)
mv_scale:       dd 1                    ; how slow: 1, 10; 0: no motion

section .bss
alignb 8
mv_now:         resq 1                  ; the step's time
mv_idle:        resq 1                  ; since when nothing moves (0: it does)
mv_kicked:      resb 1                  ; something began during it
mv_held:        resb 1                  ; pictures' memory may be kept
alignb 8
mv_slots:       resb MV_SIZE * MV_MAX
mv_black:       resb SF_SIZE            ; a window over black, while pictured
pd_x:           resq 1                  ; pic_draw's rectangle,
pd_y:           resq 1
pd_w:           resq 1
pd_h:           resq 1
pd_sx:          resq 1                  ; its steps in the picture,
pd_sy:          resq 1
pd_cx:          resq 1                  ; within the clip,
pd_cw:          resq 1
pd_u0:          resq 1                  ; the first column there,
pd_k0:          resq 1                  ; and the first read
pd_a:           resd 1
alignb 16
mv_line:        resd MV_LINE + 4        ; a line between two rows of a picture
