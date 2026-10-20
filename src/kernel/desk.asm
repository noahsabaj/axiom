; =============================================================================
;  desk.asm - the desktop: windows over the wallpaper, the menu bar along
;  the top, the dock along the bottom.
;
;  A window (WN_*) is a title bar over a surface of its own, the client,
;  which its owner draws into (gfx_target) and then says what changed
;  (win_damage). It has round corners, a shadow, and three buttons at the
;  left of its title bar: close, minimise into the dock, and zoom to fill
;  the screen (or back). It moves by its title bar, is resized from any
;  edge, raises and takes the keys when clicked; a double click on its
;  title zooms it.
;
;  One that may be resized may also go full screen (win_screen,
;  desk_screen): its client all of the screen, with no frame, bar or dock,
;  over all else and with the keys, until another window takes them or
;  ctrl+meta+F brings it back. A program's is told which of the three it
;  is (zoom_tell, WE_ZOOM) before it is told its new size.
;
;  What changed on the screen is a list of rectangles; desk_update composes
;  each into the back buffer - the wallpaper, the windows bottom to top,
;  the dock, the menu bar - and copies it to the screen. The dock is frosted
;  glass: what is behind it, blurred (a pane, draw.asm), kept until what is
;  behind it changes; then a rectangle that touches it is composed with all
;  the dock and what the blur reads around it, and the blur made again.
;
;  The dock: the apps (DOCK_APPS of them, each launched or brought forward
;  by a click), then programs with windows that are not among them, then,
;  past a line, the windows minimised, each as a small picture of itself.
;  A dot under an app says it runs; the pointer over one names it.
;
;  The menu bar: Axiom's mark, the name of the app in front and the menus,
;  and at the right the battery, the network, the launcher and the time
;  (menus.asm).
;
;  All of it runs on the main thread, but win_damage and desk_damage,
;  which any thread may call. Measures are points (theme.asm: pt).
; =============================================================================

DESK_MAX        equ 32                  ; windows at once
DMG_MAX         equ 16                  ; rectangles waiting to be composed

WN_X            equ 0                   ; the window's top left on the screen
WN_Y            equ 8
WN_W            equ 16                  ; the client's size (the window is as
WN_H            equ 24                  ; wide; its title bar is over it)
WN_SF           equ 32                  ; SF_SIZE: the client's pixels
WN_FLAGS        equ 72                  ; dword WF_*
WN_ID           equ 76                  ; dword: its number in 'win'
WN_OPS          equ 80                  ; its owner's handlers (OP_*)
WN_DATA         equ 88                  ; its owner's
WN_MIN_W        equ 96                  ; the smallest client it takes
WN_MIN_H        equ 104
WN_TITLE        equ 112
WN_TITLE_MAX    equ 160
WN_APP          equ WN_TITLE + WN_TITLE_MAX ; whose it is: the app's name
WN_APP_MAX      equ 32
WN_THUMB        equ WN_APP + WN_APP_MAX ; SF_SIZE: its picture, minimised
WN_ICON         equ WN_THUMB + SF_SIZE  ; SF_SIZE: its app's, if not the dock's
WN_ZX           equ WN_ICON + SF_SIZE   ; where it was before it zoomed
WN_ZY           equ WN_ZX + 8
WN_ZW           equ WN_ZX + 16
WN_ZH           equ WN_ZX + 24
WN_FOCUSED      equ WN_ZX + 32          ; when it last took the keys (a count)
WN_INKED        equ WN_ZX + 40          ; byte: its owner has drawn in it
WN_SX           equ WN_ZX + 48          ; where it was before it went full screen
WN_SY           equ WN_ZX + 56
WN_SW           equ WN_ZX + 64
WN_SH           equ WN_ZX + 72
WN_ZTOLD        equ WN_ZX + 80          ; dword WZ_*: what its program was last told
WN_SIZE         equ WN_ZX + 88

WF_SHOWN        equ 1 << 0              ; not minimised
WF_CLOSE        equ 1 << 1              ; it has a close button
WF_RESIZE       equ 1 << 2              ; it may be resized
WF_CLOSING      equ 1 << 3              ; it goes at the next desk_service
WF_PROGRAM      equ 1 << 4              ; a program's (its pixels are not ours)
WF_ZOOMED       equ 1 << 5              ; it fills the screen (WN_Z* is where it was)
WF_AWAY         equ 1 << 6              ; put away: not on the screen, not in the dock
WF_ANIM         equ 1 << 7              ; moving: motion.asm draws it (or its place in the dock)
WF_SCREEN       equ 1 << 8              ; full screen (desk_screen; WN_S* is where it was)

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
P_GRIP          equ 5                   ; an edge: ECX = which (EDGE_*)
P_CLIENT        equ 6
P_FRAME         equ 7
P_ZOOM          equ 8
P_DOCK          equ 9                   ; ECX = the item

EDGE_L          equ 1
EDGE_R          equ 2
EDGE_T          equ 4
EDGE_B          equ 8

DRAG_NONE       equ 0
DRAG_MOVE       equ 1
DRAG_SIZE       equ 2

; the dock's items
DOCK_APPS       equ 8
DOCK_MAX        equ DOCK_APPS + 2 * DESK_MAX
DI_KIND         equ 0                   ; dword DK_*
DI_APP          equ 4                   ; dword: which app (DK_APP)
DI_WIN          equ 8                   ; its window (DK_EXTRA: one of them)
DI_X            equ 16                  ; where it is
DI_ICON         equ 24                  ; its picture: a surface
DI_LABEL        equ 32
DI_RUN          equ 40                  ; dword: it has windows
DI_MX           equ 48                  ; magnified (motion.asm): its left,
DI_MS           equ 56                  ; its side
DI_SIZE         equ 64
DK_APP          equ 0
DK_EXTRA        equ 1                   ; a program's that is not one of the apps
DK_MIN          equ 2                   ; a window minimised

APP_TERMINAL    equ 0
APP_FILES       equ 1
APP_NOTES       equ 2
APP_SETTINGS    equ 5
APP_SYSTEM      equ 6
APP_MANDEL      equ 7

DOUBLE_MS       equ 400                 ; two clicks this close are a double click

; how long composing takes, by part ('win speed')
DS_WALL         equ 0                   ; the wallpaper and the widgets
DS_WINS         equ 1                   ; the windows
DS_DOCK         equ 2                   ; the dock and the name over it
DS_BAR          equ 3                   ; the menu bar and an open menu
DS_BLIT         equ 4                   ; to the screen
DS_PARTS        equ 5

; DS_LAP part: the time since the last lap is that part's. Preserves all.
%macro DS_LAP 1
    push rdi
    mov edi, %1
    call ds_lap
    pop rdi
%endmacro

section .text

; -----------------------------------------------------------------------------
;  desk_init: the measures, the wallpaper, the menu bar, the dock's icons
; -----------------------------------------------------------------------------
desk_init:
    call desk_metrics
    call desk_looks
    mov byte [desk_ready], 1
    mov byte [dock_dirty], 1
    mov qword [dock_hover], -1
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    jmp desk_damage

; desk_metrics: the measures, at this scale. Preserves all.
desk_metrics:
    push rax
    push rdi
    push rsi
%macro PT 2                             ; PT var, points
    mov edi, %2
    call pt
    mov [%1], rax
%endmacro
%macro PT_EVEN 2
    mov edi, %2
    call pt
    inc rax
    and rax, -2
    mov [%1], rax
%endmacro
    PT m_bar_h, 24
    mov rax, [m_bar_h]
    mov [hdr_h], rax
    PT fr_t, 28
    mov rax, [fr_t]
    mov [title_h], rax
    mov qword [fr_b], 0
    PT m_r, 10
    PT_EVEN m_light, 12
    PT m_light_x, 8
    PT m_light_step, 20
    PT m_grab, 4
    PT_EVEN m_icon, 48
    PT m_dock_pad, 5
    PT m_dock_space, 4
    PT m_dock_gap, 5
    PT m_dock_r, 16
    PT_EVEN m_dot, 4
    PT m_blur, 10
    PT m_tip_h, 24
    PT m_tip_pad, 10
    PT m_tip_gap, 10
    PT m_bar_pad, 14
    PT m_gap, 16
    PT m_mark, 15
    call mn_metrics
    mov rax, [m_blur]
    cmp rax, 64
    jbe .blur_ok
    mov qword [m_blur], 64
.blur_ok:
    mov rax, [m_icon]
    add rax, [m_dock_pad]
    add rax, [m_dock_pad]
    mov [m_dock_h], rax
    mov rax, [scr_h]
    sub rax, [m_dock_gap]
    sub rax, [m_dock_h]
    mov [m_dock_y], rax
    push rcx
    push rdx
    mov rax, [m_icon]                   ; magnified, an icon is at most 1.6
    imul rax, rax, 8                    ; times as big (even)
    add rax, 9
    xor edx, edx
    mov ecx, 10
    div rcx
    add rax, rax
    mov [m_icon_big], rax
    mov rax, [m_icon]                   ; the magnifying reaches 2.5 places
    add rax, [m_dock_space]
    imul rax, rax, 5
    shr rax, 1
    mov [m_dock_reach], rax
    shl rax, 3                          ; and the glass may grow each way:
    xor edx, edx                        ; 0.6 (reach 8/15 + icon/2 + pad)
    mov ecx, 15
    div rcx
    mov rcx, [m_icon]
    shr rcx, 1
    add rax, rcx
    add rax, [m_dock_pad]
    imul rax, rax, 3
    xor edx, edx
    mov ecx, 5
    div rcx
    add rax, 2
    mov [m_dock_ext], rax
    mov rax, [m_icon]                   ; an app starting: how high it bounces
    shr rax, 1
    mov [m_bounce], rax
    mov rax, [m_dock_y]                 ; the top of all the dock draws, but
    add rax, [m_dock_pad]               ; the names
    add rax, [m_icon]
    sub rax, [m_icon_big]
    sub rax, [m_bounce]
    mov [m_dock_top], rax
    pop rdx
    pop rcx
    mov edi, 6                          ; windows stop a little above it
    call pt
    mov rdi, [m_dock_y]
    sub rdi, rax
    mov [m_work_y1], rdi
    ; shadows: the window with the keys casts the larger
    mov rax, [m_r]
    mov [sh_focus + SH_R], rax
    mov [sh_other + SH_R], rax
    PT sh_focus + SH_M, 26
    PT sh_focus + SH_OY, 10
    PT sh_other + SH_M, 14
    PT sh_other + SH_OY, 5
    mov rax, [sh_focus + SH_M]
    add rax, [sh_focus + SH_OY]
    mov [fr_sh], rax                    ; how far past a window it draws
    ; fonts
    mov edi, 13
    call pt
    mov edi, eax
    mov esi, UF_REGULAR
    call uf_size
    mov [f_body], eax
    mov esi, UF_SEMIBOLD
    call uf_size
    mov [f_title], eax
    push rdi
    mov edi, 11
    call pt
    mov edi, eax
    mov esi, UF_REGULAR
    call uf_size
    mov [f_small], eax
    pop rdi
    pop rsi
    pop rdi
    pop rax
    ret

; desk_looks: what the theme makes: the wallpaper, the menu bar's glass,
; the widgets, the shadows, the icons, the pointer. Preserves RBX, RBP, R12-R15.
desk_looks:
    call wall_make
    call bar_make
    call wg_looks
    mov eax, [th_c + TC_SHADOW_A]
    mov [sh_focus + SH_A], eax
    mov eax, [th_c + TC_SHADOW2_A]
    mov [sh_other + SH_A], eax
    lea rdi, [sh_focus]
    call shadow_build
    lea rdi, [sh_other]
    call shadow_build
    call icons_make
    call cursor_make
    ret

; desk_restyle: the theme or the scale changed: everything again
desk_restyle:
    cmp byte [desk_ready], 0
    je .out
    push rbx
    push r12
    call desk_metrics
    call desk_looks
    xor r12d, r12d                      ; each window: its new measures,
.each:                                  ; painted again
    lea rax, [desk_wins]
    mov rbx, [rax + r12 * 8]
    test rbx, rbx
    jz .next
    lea rdi, [rbx + WN_ICON]            ; its icon is made again when needed
    call sf_free
    lea rdi, [rbx + WN_THUMB]
    call sf_free
    test dword [rbx + WN_FLAGS], WF_SHOWN
    jnz .fit
    mov rdi, rbx
    call win_thumb
.fit:
    mov rdi, rbx
    mov rsi, [rbx + WN_W]
    mov rdx, [rbx + WN_H]
    call win_fit
.next:
    inc r12
    cmp r12, DESK_MAX
    jb .each
    mov byte [dock_dirty], 1
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    call desk_damage
    pop r12
    pop rbx
.out:
    ret

; bar_make: the menu bar's glass: the wallpaper under it, blurred and tinted
bar_make:
    push rbx
    mov rbx, [m_blur]
    imul rbx, rbx, 3
    add rbx, [m_bar_h]                  ; the rows the blur reads
    cmp rbx, [scr_h]
    jbe .rows
    mov rbx, [scr_h]
.rows:
    lea rdi, [bar_sf]
    mov rsi, [scr_w]
    mov rdx, rbx
    call sf_size
    jc .out
    mov rsi, [wall_sf + SF_PTR]
    mov rdi, [bar_sf + SF_PTR]
    mov rcx, [wall_sf + SF_PITCH]
    imul rcx, rbx
    shr rcx, 2
    rep movsd
    lea rdi, [bar_sf]
    call gfx_target
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [m_bar_h]
    xor r8d, r8d
    mov r9, [m_blur]
    call gfx_frost
    mov r8d, [th_c + TC_BAR]
    mov r9d, [th_c + TC_BAR_A]
    call gfx_fill_a
    call gfx_target_back
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Windows
; -----------------------------------------------------------------------------

; win_new(RDI = handlers, RSI = title, RDX = width, RCX = height of the
; client, R8 = x, R9 = y of the window (x = -1: placed for it), R10D = WF_*,
; R11 = its app's name, 0: the title) -> RAX = the window, 0 if there is no
; room. It is on top, not focused.
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
    push r11
    mov edi, WN_SIZE
    call kmalloc
    pop r11
    pop r10
    pop r9
    pop r8
    test rax, rax
    jz .out
    mov rbx, rax
    push rdi                            ; all of it zero to begin with
    push rcx
    mov rdi, rbx
    mov ecx, WN_SIZE
    xor eax, eax
    rep stosb
    pop rcx
    pop rdi
    xor ecx, ecx                        ; a slot
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
    mov eax, r10d                       ; a program's: the size of its pixels,
    and eax, WF_PROGRAM | WF_RESIZE     ; unless they are the screen's
    cmp eax, WF_PROGRAM
    jne .least
    mov [rbx + WN_MIN_W], r14
    mov [rbx + WN_MIN_H], r15
.least:
    mov rdi, rbx
    mov rsi, r13
    call win_title_set
    test r11, r11
    jnz .app
    mov r11, r13
.app:
    mov rsi, r11
    call win_app_set
    xor r12d, r12d
    cmp r8, -1                          ; cascade from the top left
    jne .placed
    mov r12d, 1                         ; R12D: placed for it
    mov rax, [desk_next_id]
    and eax, 7
    imul rax, [fr_t]
    mov r8, [m_gap]
    imul r8, r8, 6
    add r8, rax
    mov r9, [m_bar_h]
    add r9, [m_gap]
    add r9, [m_gap]
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
    test r12d, r12d
    jz .seen
    mov rax, [rbx + WN_Y]               ; placed for it: above the dock, as
    add rax, [rbx + WN_H]               ; far as it fits under the bar
    add rax, [fr_t]
    sub rax, [m_work_y1]
    jle .seen
    mov rdx, [rbx + WN_Y]
    sub rdx, rax
    mov rcx, [m_bar_h]
    add rcx, [m_gap]
    cmp rdx, rcx
    jge .up
    mov rdx, rcx
.up:
    mov [rbx + WN_Y], rdx
.seen:
    mov rdi, rbx
    call win_damage_whole
    call mv_open                        ; growing into place
    call desk_bar_damage
    mov byte [dock_dirty], 1
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

; win_app_set(RDI = window, RSI = its app's name). Preserves all.
win_app_set:
    push rax
    push rcx
    push rsi
    push rdi
    lea rdi, [rdi + WN_APP]
    mov ecx, WN_APP_MAX - 1
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
; far as the screen and the window's least allow (full screen: the
; screen's, whatever is asked); the window kept on the screen; then
; painted. Preserves RBX, RBP, R12-R15.
win_fit:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    test dword [rbx + WN_FLAGS], WF_SCREEN
    jz .least
    mov r12, [scr_w]                    ; full screen: all of it
    mov r13, [scr_h]
    jmp .h_max
.least:
    cmp r12, [rbx + WN_MIN_W]
    jge .w_min
    mov r12, [rbx + WN_MIN_W]
.w_min:
    cmp r13, [rbx + WN_MIN_H]
    jge .h_min
    mov r13, [rbx + WN_MIN_H]
.h_min:
    mov rax, [scr_w]                    ; at most the screen
    cmp r12, rax
    jle .w_max
    mov r12, rax
.w_max:
    mov rax, [scr_h]
    sub rax, [m_bar_h]
    sub rax, [fr_t]
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
    mov rax, r12                        ; RAX: a size it did not have
    xor rax, [rbx + WN_W]
    mov rcx, r13
    xor rcx, [rbx + WN_H]
    or rax, rcx
    mov [rbx + WN_W], r12
    mov [rbx + WN_H], r13
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jz .keep
    test rax, rax
    jz .keep
    call prog_resized                   ; the program draws it again
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

; win_place(RDI = window, RSI = x, RDX = y): the window there, as far as its
; title bar stays reachable (full screen: its client at the screen's top
; left, the title bar above it). Preserves all.
win_place:
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jnz .screen
    push rax
    push rcx
    push rdx
    push rsi
    call win_outer_w
    mov rcx, [m_gap]                    ; at least some of the title bar on
    imul rcx, rcx, 3                    ; the screen
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
    cmp rdx, [m_bar_h]                  ; under the bar
    jge .top
    mov rdx, [m_bar_h]
.top:
    mov rax, [scr_h]
    sub rax, [fr_t]
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
.screen:
    push rax
    mov qword [rdi + WN_X], 0
    mov rax, [fr_t]
    neg rax
    mov [rdi + WN_Y], rax
    pop rax
    ret

; win_outer_w(RDI) -> RAX = the window's width
win_outer_w:
    mov rax, [rdi + WN_W]
    ret

; win_outer(RDI = window) -> RDI x, RSI y, RDX w, RCX h of the window.
; Preserves others but RAX.
win_outer:
    mov rsi, [rdi + WN_Y]
    mov rdx, [rdi + WN_W]
    mov rcx, [rdi + WN_H]
    add rcx, [fr_t]
    mov rdi, [rdi + WN_X]
    ret

; win_extent(RDI = window) -> RDI x, RSI y, RDX w, RCX h of all it draws,
; its shadow too. Preserves others but RAX.
win_extent:
    call win_outer
    mov rax, [fr_sh]
    sub rdi, rax
    sub rsi, rax
    lea rdx, [rdx + rax * 2]
    lea rcx, [rcx + rax * 2]
    ret

; win_client(RDI = window) -> RDI x, RSI y, RDX w, RCX h of the client on
; the screen. Preserves others.
win_client:
    mov rsi, [rdi + WN_Y]
    add rsi, [fr_t]
    mov rdx, [rdi + WN_W]
    mov rcx, [rdi + WN_H]
    mov rdi, [rdi + WN_X]
    ret

; win_damage(RDI = window, RSI = x, RDX = y, RCX = w, R8 = h in the client):
; that part changed. Any thread. Preserves all.
win_damage:
    mov byte [rdi + WN_INKED], 1
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .out
    push rdi
    push rsi
    push rdx
    push rcx
    add rsi, [rdi + WN_X]
    add rdx, [rdi + WN_Y]
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

; win_damage_whole(RDI = window): it, its shadow and all in it. Preserves all.
win_damage_whole:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    call win_extent
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

; win_set_rect(RDI = window, RSI = x, RDX = y, RCX = width, R8 = height):
; moved and resized at once. Preserves RBX, RBP, R12-R15.
win_set_rect:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rcx
    mov r13, r8
    call win_damage_whole
    mov [rbx + WN_X], rsi
    mov [rbx + WN_Y], rdx
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jz .placed
    call win_fit
    jmp .shown
.placed:
    mov rsi, [rbx + WN_X]
    mov rdx, [rbx + WN_Y]
    call win_place
.shown:
    mov rdi, rbx
    call win_damage_whole
    pop r13
    pop r12
    pop rbx
    ret

; win_zoom(RDI = window): to fill the screen between the bar and the dock,
; or back to where it was (full screen: out of it, zoomed). Preserves RBX,
; RBP, R12-R15.
win_zoom:
    test dword [rdi + WN_FLAGS], WF_RESIZE
    jz .out
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jz .zoom
    mov esi, WZ_ZOOMED
    jmp win_set_zoom
.zoom:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    call win_outer                      ; R12..R15: the window where it was
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rdi, rbx
    test dword [rdi + WN_FLAGS], WF_ZOOMED
    jnz .back
    mov rax, [rdi + WN_X]               ; where it was
    mov [rdi + WN_ZX], rax
    mov rax, [rdi + WN_Y]
    mov [rdi + WN_ZY], rax
    mov rax, [rdi + WN_W]
    mov [rdi + WN_ZW], rax
    mov rax, [rdi + WN_H]
    mov [rdi + WN_ZH], rax
    or dword [rdi + WN_FLAGS], WF_ZOOMED
    call zoom_tell
    call zoom_rect
    jmp .set
.back:
    and dword [rdi + WN_FLAGS], ~WF_ZOOMED
    call zoom_tell
    mov rsi, [rdi + WN_ZX]
    mov rdx, [rdi + WN_ZY]
    mov rcx, [rdi + WN_ZW]
    mov r8, [rdi + WN_ZH]
.set:
    call win_set_rect
    mov rdi, rbx                        ; from there to here
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    mov r8, r15
    call mv_zoom
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.out:
    ret

; zoom_rect -> RSI x, RDX y, RCX w, R8 h: a window zoomed, between the bar
; and the dock. Preserves others.
zoom_rect:
    xor esi, esi
    mov rdx, [m_bar_h]
    mov rcx, [scr_w]
    mov r8, [m_work_y1]
    sub r8, rdx
    sub r8, [fr_t]
    ret

; win_set_zoom(RDI = window, ESI = WZ_*): full screen, zoomed or neither, as
; asked (RO_WIN_ZOOM); only one that may be resized. From full screen it
; goes straight there. Preserves RBX, RBP, R12-R15.
win_set_zoom:
    test dword [rdi + WN_FLAGS], WF_RESIZE
    jz .out
    cmp esi, WZ_SCREEN
    je win_screen
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jnz .screen
    xor eax, eax                        ; zoomed now, or not
    test dword [rdi + WN_FLAGS], WF_ZOOMED
    setnz al
    cmp eax, esi
    jne win_zoom
.out:
    ret
.screen:
    cmp esi, WZ_ZOOMED
    je .to_zoomed
    test dword [rdi + WN_FLAGS], WF_ZOOMED
    jz win_unscreen
    and dword [rdi + WN_FLAGS], ~WF_ZOOMED ; to where it was before it zoomed
    mov rax, [rdi + WN_ZX]
    mov [rdi + WN_SX], rax
    mov rax, [rdi + WN_ZY]
    mov [rdi + WN_SY], rax
    mov rax, [rdi + WN_ZW]
    mov [rdi + WN_SW], rax
    mov rax, [rdi + WN_ZH]
    mov [rdi + WN_SH], rax
    jmp win_unscreen
.to_zoomed:
    test dword [rdi + WN_FLAGS], WF_ZOOMED
    jnz win_unscreen
    or dword [rdi + WN_FLAGS], WF_ZOOMED ; zoomed, and from there back to
    mov rax, [rdi + WN_SX]              ; where it was
    mov [rdi + WN_ZX], rax
    mov rax, [rdi + WN_SY]
    mov [rdi + WN_ZY], rax
    mov rax, [rdi + WN_SW]
    mov [rdi + WN_ZW], rax
    mov rax, [rdi + WN_SH]
    mov [rdi + WN_ZH], rax
    call zoom_rect
    mov [rdi + WN_SX], rsi
    mov [rdi + WN_SY], rdx
    mov [rdi + WN_SW], rcx
    mov [rdi + WN_SH], r8
    jmp win_unscreen

; win_screen(RDI = window): full screen: all of the screen its client, over
; all else, with the keys; no frame, bar or dock (desk_screen). Only one
; that may be resized; one full screen already leaves it first, as it
; loses the keys. Preserves all.
win_screen:
    test dword [rdi + WN_FLAGS], WF_RESIZE
    jz .out
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jnz .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, rdi
    call mv_forget                      ; at once: nothing of it moves on,
    call mn_close                       ; no menu stays open, nothing is
    mov byte [drag_mode], DRAG_NONE     ; dragged
    mov qword [drag_win], 0
    mov qword [dock_press], -1
    test dword [rbx + WN_FLAGS], WF_SHOWN
    jnz .shown
    or dword [rbx + WN_FLAGS], WF_SHOWN ; out of the dock
    and dword [rbx + WN_FLAGS], ~WF_AWAY
    lea rdi, [rbx + WN_THUMB]
    call sf_free
    mov byte [dock_dirty], 1
.shown:
    mov rdi, rbx
    call win_focus                      ; the keys, on top
    mov rax, [rbx + WN_X]               ; where to come back to
    mov [rbx + WN_SX], rax
    mov rax, [rbx + WN_Y]
    mov [rbx + WN_SY], rax
    mov rax, [rbx + WN_W]
    mov [rbx + WN_SW], rax
    mov rax, [rbx + WN_H]
    mov [rbx + WN_SH], rax
    or dword [rbx + WN_FLAGS], WF_SCREEN
    mov [desk_screen], rbx
    lea rax, [rbx + WN_TITLE]
    KLOG "desk: '%s' goes full screen", rax
    call zoom_tell
    mov rsi, [scr_w]
    mov rdx, [scr_h]
    call win_fit
    mov qword [hover_win], 0            ; no frame's buttons, no dock's name
    mov qword [dock_hover], -1
    cmp rbx, [grab_win]
    jne .held
    mov qword [grab_win], 0             ; held in its middle now (ptr_mode)
.held:
    call desk_damage_screen
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; win_unscreen(RDI = window): out of full screen, back where it was; its
; program told so (WE_ZOOM), then its size. Preserves all.
win_unscreen:
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jz .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbx
    mov rbx, rdi
    and dword [rbx + WN_FLAGS], ~WF_SCREEN
    cmp rbx, [desk_screen]
    jne .left
    mov qword [desk_screen], 0
.left:
    mov rax, [rbx + WN_SX]
    mov [rbx + WN_X], rax
    mov rax, [rbx + WN_SY]
    mov [rbx + WN_Y], rax
    lea rax, [rbx + WN_TITLE]
    KLOG "desk: '%s' leaves full screen", rax
    call zoom_tell
    mov rsi, [rbx + WN_SW]
    mov rdx, [rbx + WN_SH]
    call win_fit
    cmp rbx, [grab_win]
    jne .held
    mov qword [grab_win], 0             ; held in its middle there (ptr_mode)
.held:
    call desk_damage_screen             ; the desk again, all of it
    pop rbx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; win_screen_flip(RDI = window): full screen, or out of it. Preserves all.
win_screen_flip:
    test dword [rdi + WN_FLAGS], WF_SCREEN
    jnz win_unscreen
    jmp win_screen

; zoom_tell(RDI = window): a program's is told whether it is full screen,
; zoomed or neither, if that is not what it was last told (WE_ZOOM).
; Preserves all.
zoom_tell:
    test dword [rdi + WN_FLAGS], WF_PROGRAM
    jz .out
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
    mov rbx, rdi
    mov esi, WZ_SCREEN
    test dword [rbx + WN_FLAGS], WF_SCREEN
    jnz .state
    mov esi, WZ_ZOOMED
    test dword [rbx + WN_FLAGS], WF_ZOOMED
    jnz .state
    mov esi, WZ_NORMAL
.state:
    cmp esi, [rbx + WN_ZTOLD]
    je .told
    mov [rbx + WN_ZTOLD], esi
    call prog_zoom
.told:
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

; win_focus(RDI = window or 0): it is shown, raised and takes the keys; one
; full screen that loses them leaves it (told WE_FOCUS 0 first). Preserves
; all.
win_focus:
    push rax
    push rdi
    mov rax, [desk_focus]
    test rax, rax
    jz .old_done
    push rdi
    mov rdi, rax                        ; its shadow and title change too
    call win_damage_whole
    cmp rax, [rsp]
    je .same
    push rsi                            ; a program's is told
    xor esi, esi
    call focus_tell
    pop rsi
.same:
    pop rdi
.old_done:
    mov rax, [desk_screen]
    test rax, rax
    jz .screen_done
    cmp rax, rdi
    je .screen_done
    push rdi
    mov rdi, rax
    call win_unscreen
    pop rdi
.screen_done:
    mov rax, [desk_focus]
    cmp rdi, rax
    je .tell_done
    test rdi, rdi
    jz .tell_done
    push rsi
    mov esi, 1
    call focus_tell
    pop rsi
.tell_done:
    mov [desk_focus], rdi
    test rdi, rdi
    jz .done
    inc qword [desk_focus_n]
    mov rax, [desk_focus_n]
    mov [rdi + WN_FOCUSED], rax
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jnz .shown
    test dword [rdi + WN_FLAGS], WF_AWAY
    jnz .appear
    call mv_back                        ; out of its place in the dock
    jmp .show
.appear:
    call mv_open                        ; or growing into place
.show:
    or dword [rdi + WN_FLAGS], WF_SHOWN
    and dword [rdi + WN_FLAGS], ~WF_AWAY
    push rdi
    lea rdi, [rdi + WN_THUMB]           ; out of the dock
    call sf_free
    pop rdi
    mov byte [dock_dirty], 1
.shown:
    call win_raise
    call win_damage_whole
.done:
    call desk_bar_damage
    mov byte [dock_dirty], 1
    pop rdi
    pop rax
    ret

; focus_tell(RDI = window, ESI = 1: it has the keys, 0: not): a program's
; window is told. Preserves all.
focus_tell:
    test dword [rdi + WN_FLAGS], WF_PROGRAM
    jz .out
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
    mov rbx, rdi
    call prog_focus
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
.out:
    ret

; win_minimise(RDI = window): off the screen, into the dock. Preserves all.
win_minimise:
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .out
    call win_unscreen                   ; (out of full screen first)
    call win_damage_whole
    call win_thumb
    call mv_minimise                    ; into its place there
    and dword [rdi + WN_FLAGS], ~WF_SHOWN
    mov byte [dock_dirty], 1
    cmp rdi, [desk_focus]
    jne .bar
    push rdi
    call desk_last_focused
    mov rdi, rax
    call win_focus
    pop rdi
.bar:
    call desk_bar_damage
.out:
    ret

; win_put_away(RDI = window): off the screen and out of the dock, until its
; app in the dock brings it back (win_focus). The built-in windows start so,
; and their close buttons do it. Preserves all.
win_put_away:
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .away
    call win_unscreen                   ; (out of full screen first)
    call mv_close                       ; shrinking away
    call win_damage_whole
.away:
    and dword [rdi + WN_FLAGS], ~WF_SHOWN
    or dword [rdi + WN_FLAGS], WF_AWAY
    mov byte [dock_dirty], 1
    cmp rdi, [desk_focus]
    jne .bar
    push rax
    push rdi
    call desk_last_focused
    mov rdi, rax
    call win_focus
    pop rdi
    pop rax
.bar:
    call desk_bar_damage
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

; desk_last_focused -> RAX = of the windows shown, the one that had the keys
; last; else the topmost; or 0. Preserves others.
desk_last_focused:
    push rcx
    push rdx
    push rsi
    push r8
    xor eax, eax
    xor esi, esi                        ; RSI: when it had them
    mov rcx, [desk_zn]
    lea rdx, [desk_z]
.each:
    test rcx, rcx
    jz .seen
    dec rcx
    mov r8, [rdx + rcx * 8]
    test dword [r8 + WN_FLAGS], WF_SHOWN
    jz .each
    test dword [r8 + WN_FLAGS], WF_CLOSING
    jnz .each
    cmp [r8 + WN_FOCUSED], rsi
    jbe .each
    mov rsi, [r8 + WN_FOCUSED]
    mov rax, r8
    jmp .each
.seen:
    test rax, rax
    jnz .out
    call desk_top_shown
.out:
    pop r8
    pop rsi
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
    mov rdi, rbx
    cmp rbx, [desk_screen]              ; full screen: gone at once, and the
    jne .shrink                         ; desk all there again
    mov qword [desk_screen], 0
    and dword [rbx + WN_FLAGS], ~WF_SCREEN
    call desk_damage_screen
    jmp .forget
.shrink:
    call mv_close                       ; shrinking away, from its picture now
.forget:
    call mv_forget                      ; (and nothing of it moves on)
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
    xor ecx, ecx                        ; and out of the list
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
    cmp rbx, [hover_win]
    jne .no_hover
    mov qword [hover_win], 0
.no_hover:
    cmp rbx, [ptr_over]
    jne .not_over
    mov qword [ptr_over], 0
.not_over:
    cmp rbx, [grab_win]
    jne .not_held
    mov qword [grab_win], 0             ; (ptr_mode shows the arrow again)
.not_held:
    cmp rbx, [desk_focus]
    jne .no_focus
    mov qword [desk_focus], 0
    call desk_last_focused              ; the keys back where they were
    mov rdi, rax
    call win_focus
.no_focus:
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jnz .pixels_theirs
    lea rdi, [rbx + WN_SF]
    call sf_free
.pixels_theirs:
    lea rdi, [rbx + WN_THUMB]
    call sf_free
    lea rdi, [rbx + WN_ICON]
    call sf_free
    mov rdi, rbx
    call kfree
    mov byte [dock_dirty], 1
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

; win_thumb(RDI = window): its picture for the dock, from its client.
; Preserves all.
win_thumb:
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
    push r14
    push r15
    mov rbx, rdi
    cmp qword [rbx + WN_SF + SF_PTR], 0
    je .out
    mov rax, [rbx + WN_W]               ; the picture: the icon's size, its
    mov rcx, [rbx + WN_H]               ; sides as the window's
    add rcx, [fr_t]
    test rax, rax
    jz .out
    mov r12, [m_icon]                   ; width
    mov r13, [m_icon]                   ; height
    cmp rax, rcx
    jae .wide
    mov rax, [m_icon]                   ; taller: width = icon * w / h
    imul rax, [rbx + WN_W]
    xor edx, edx
    div rcx
    mov r12, rax
    jmp .sized
.wide:
    mov rax, [m_icon]                   ; wider: height = icon * h / w
    imul rax, rcx
    xor edx, edx
    div qword [rbx + WN_W]
    mov r13, rax
.sized:
    cmp r12, 4
    jb .out
    cmp r13, 4
    jb .out
    lea rdi, [rbx + WN_THUMB]
    mov rsi, r12
    mov rdx, r13
    call img_new
    jc .out
    ; its title bar's share, in the title bar's color
    mov rax, [fr_t]
    imul rax, r13
    mov rcx, [rbx + WN_H]
    add rcx, [fr_t]
    xor edx, edx
    div rcx
    mov r14, rax                        ; rows of title bar
    ; each pixel: the client's pixel at the middle of where it falls
    xor r9d, r9d                        ; y
.row:
    cmp r9, r13
    jae .shape
    mov rdi, r9
    imul rdi, [rbx + WN_THUMB + SF_PITCH]
    add rdi, [rbx + WN_THUMB + SF_PTR]
    cmp r9, r14
    jb .title_row
    mov rax, r9                         ; the client's row
    sub rax, r14
    shl rax, 1
    inc rax
    imul rax, [rbx + WN_H]
    mov rcx, r13
    sub rcx, r14
    shl rcx, 1
    jz .next_row
    xor edx, edx
    div rcx
    cmp rax, [rbx + WN_SF + SF_H]
    jae .next_row
    imul rax, [rbx + WN_SF + SF_PITCH]
    mov r15, rax
    add r15, [rbx + WN_SF + SF_PTR]
    xor r8d, r8d                        ; x
.col:
    cmp r8, r12
    jae .next_row
    lea rax, [r8 * 2 + 1]
    imul rax, [rbx + WN_W]
    mov rcx, r12
    shl rcx, 1
    xor edx, edx
    div rcx
    cmp rax, [rbx + WN_SF + SF_W]
    jae .col_next
    mov eax, [r15 + rax * 4]
    or eax, 0xFF000000
    mov [rdi + r8 * 4], eax
.col_next:
    inc r8
    jmp .col
.title_row:
    mov eax, [th_c + TC_TITLE]
    or eax, 0xFF000000
    mov rcx, r12
    rep stosd
.next_row:
    inc r9
    jmp .row
.shape:
    ; round corners: what is outside them, clear
    lea rdi, [rbx + WN_THUMB]
    call gfx_target
    mov edi, 4
    call pt
    mov r10, rax
    xor edi, edi
    xor esi, esi
    mov rdx, r12
    mov rcx, r13
    call img_round
    call gfx_target_back
.out:
    pop r15
    pop r14
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

; img_round(RDI x, RSI y, RDX w, RCX h, R10 = radius): the target's pixels
; outside the rounded rectangle's corners faded out by how much is outside.
; Preserves all.
img_round:
    push rbx
    push r11
    lea rbx, [span_round]
    mov r11d, RC_ALL
    call rr_walk
    pop r11
    pop rbx
    ret

; span_round: rr_walk's span: each pixel kept by its coverage
span_round:
    test rsi, rsi
    jz .out
    push rbx
.px:
    movzx eax, byte [rsi]
    add rsi, rdx
    cmp eax, 255
    je .next
    mov ebx, eax
    shr ebx, 7
    add ebx, eax
    mov eax, [rdi]
    SCALE eax, ebx, r10d
    mov [rdi], eax
.next:
    add rdi, 4
    dec rcx
    jnz .px
    pop rbx
.out:
    ret

; -----------------------------------------------------------------------------
;  Damage and composing
; -----------------------------------------------------------------------------

; desk_damage(RDI x, RSI y, RDX w, RCX h on the screen): to be composed
; again. Any thread. Preserves all.
desk_damage:
    push r8
    xor r8d, r8d
    call desk_damage_own
    pop r8
    ret

; desk_damage_screen: all of the screen, to be composed again. Any thread.
; Preserves all.
desk_damage_screen:
    push rdi
    push rsi
    push rdx
    push rcx
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; desk_damage_own(RDI x, RSI y, RDX w, RCX h, R8 = a pane of glass or 0):
; as desk_damage, by the pane's own drawing: what is behind it is as it
; was. Any thread. Preserves all.
desk_damage_own:
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
    lea rax, [dock_gl]                  ; what is behind the glass changed
    cmp rax, r8
    je .dock
    call gl_touch
.dock:
    lea rax, [mn_gl]
    cmp rax, r8
    je .menu
    call gl_touch
.menu:
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
    jne .out
    cmp byte [dock_dirty], 0
.out:
    ret

; desk_update: compose what changed and show it (main thread)
desk_update:
    cmp byte [desk_ready], 0
    je .out
    cmp byte [dock_dirty], 0
    je .laid
    call dock_layout
.laid:
    cmp qword [dmg_n], 0
    jne .work
.out:
    ret
.work:
    push rbx
    push r12
    push r13
    RDTSC64
    mov r13, rax                        ; when it began
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
    mov al, [dock_gl + GL_STALE]        ; and what changed behind the glass
    or [dock_gl + GL_TAKEN], al
    mov byte [dock_gl + GL_STALE], 0
    mov al, [mn_gl + GL_STALE]
    or [mn_gl + GL_TAKEN], al
    mov byte [mn_gl + GL_STALE], 0
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
    call desk_glass                     ; all the glass it touches, with it
    mov rax, rdx                        ; its pixels, counted
    imul rax, rcx
    add [ds_px], rax
    call desk_compose
    inc rbx
    jmp .rect
.done:
    add rsp, DMG_MAX * 32
    RDTSC64                             ; how long it took
    sub rax, r13
    add [ds_cycles], rax
    inc qword [ds_frames]
    cmp rax, [ds_max]
    jbe .longest
    mov [ds_max], rax
.longest:
    pop r13
    pop r12
    pop rbx
    ret

; ds_lap(EDI = a part, DS_*): the time since the last lap is its. Preserves
; all.
ds_lap:
    push rax
    push rdx
    RDTSC64
    mov rdx, rax
    sub rax, [ds_last]
    mov [ds_last], rdx
    lea rdx, [ds_parts]
    add [rdx + rdi * 8], rax
    pop rdx
    pop rax
    ret

; ds_say: how fast the desk composed since it was last asked; then from 0
ds_say:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rax, [ds_cycles]                ; each frame's, in hundredths of a ms
    mov ecx, 100
    mul rcx
    div qword [tsc_per_ms]
    xor edx, edx
    mov rcx, [ds_frames]
    test rcx, rcx
    jz .mean
    div rcx
.mean:
    mov rbx, rax
    mov rax, [ds_max]
    mov ecx, 100
    mul rcx
    div qword [tsc_per_ms]
    mov r12, rax
    mov rax, [ds_px]                    ; pixels, in tenths of a million
    xor edx, edx
    mov ecx, 100000
    div rcx
    KLOG "desk: %u frames, %h ms each, the longest %h ms, %t Mpx composed", qword [ds_frames], rbx, r12, rax
    xor ecx, ecx                        ; each part's share
    xor ebx, ebx
.sum:
    lea rax, [ds_parts]
    add rbx, [rax + rcx * 8]
    inc ecx
    cmp ecx, DS_PARTS
    jb .sum
    test rbx, rbx
    jnz .shares
    inc ebx
.shares:
    xor ecx, ecx
    lea r8, [ds_share]
.share:
    lea rax, [ds_parts]
    mov rax, [rax + rcx * 8]
    mov edx, 100
    mul rdx
    div rbx
    mov [r8 + rcx * 8], rax
    inc ecx
    cmp ecx, DS_PARTS
    jb .share
    KLOG "desk: wallpaper %u%%, windows %u%%, dock %u%%, bar and menus %u%%, to the screen %u%%", qword [ds_share], qword [ds_share + 8], qword [ds_share + 16], qword [ds_share + 24], qword [ds_share + 32]
    lea rdi, [ds_frames]                ; from 0
    xor eax, eax
    mov ecx, DS_PARTS + 4
    rep stosq
    call ml_say                         ; and what held the main loop longest
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; desk_glass(RDI x, RSI y, RDX w, RCX h) -> the rectangle grown to hold
; all a pane of glass reads, if what is behind it changed and the rectangle
; touches that (the pane is made again as it is composed). Full screen,
; none shows: they wait. Preserves others.
desk_glass:
    cmp qword [desk_screen], 0
    jne .out
    push rax
    lea rax, [dock_gl]
    call gl_grow
    lea rax, [mn_gl]
    call gl_grow
    lea rax, [dock_gl]                  ; (the menu's may reach the dock's)
    call gl_grow
    pop rax
.out:
    ret

; dock_pane: the dock's pane of glass where the dock is; made again if that
; changed. Preserves all.
dock_pane:
    push rax
    push rcx
    lea rax, [dock_gl]
    mov rcx, [m_blur]
    mov [rax + GL_B], rcx
    lea rcx, [rcx + rcx * 2]
    mov [rax + GL_M], rcx
    mov rcx, [dock_x]                   ; as wide as it may grow, magnified
    sub rcx, [m_dock_ext]
    cmp rcx, [rax + GL_X]
    jne .moved
    mov rcx, [dock_w]
    add rcx, [m_dock_ext]
    add rcx, [m_dock_ext]
    cmp rcx, [rax + GL_W]
    jne .moved
    mov rcx, [m_dock_y]
    cmp rcx, [rax + GL_Y]
    jne .moved
    mov rcx, [m_dock_h]
    cmp rcx, [rax + GL_H]
    je .out
.moved:
    mov rcx, [dock_x]
    sub rcx, [m_dock_ext]
    mov [rax + GL_X], rcx
    mov rcx, [dock_w]
    add rcx, [m_dock_ext]
    add rcx, [m_dock_ext]
    mov [rax + GL_W], rcx
    mov rcx, [m_dock_y]
    mov [rax + GL_Y], rcx
    mov rcx, [m_dock_h]
    mov [rax + GL_H], rcx
    mov byte [rax + GL_STALE], 1
.out:
    pop rcx
    pop rax
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
    push rax
    push rdx
    RDTSC64
    mov [ds_last], rax
    pop rdx
    pop rax
    call gfx_target_back
    call gfx_set_clip
    mov rdi, [desk_screen]              ; one full screen: it alone
    test rdi, rdi
    jnz .screen
    call wall_draw                      ; the wallpaper
    DS_LAP DS_WALL
    xor ebx, ebx                        ; windows, bottom to top
.window:
    cmp rbx, [desk_zn]
    jae .dock
    lea rax, [desk_z]
    mov rdi, [rax + rbx * 8]
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .next
    test dword [rdi + WN_FLAGS], WF_ANIM ; moving: drawn as it moves
    jnz .next
    push rdi
    call win_extent                     ; does it reach the rectangle?
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
    jmp .next
.skip:
    pop rdi
.next:
    inc rbx
    jmp .window
.dock:
    mov edi, MVL_WINS                   ; what moves over the windows
    call motion_paint
    DS_LAP DS_WINS
    lea rax, [r13 + r15]                ; the dock, if it is in it
    cmp rax, [m_dock_top]
    jle .tip
    call dock_paint
.tip:
    call tip_paint
    mov edi, MVL_TOP                    ; what moves over the dock
    call motion_paint
    DS_LAP DS_DOCK
    cmp r13, [m_bar_h]                  ; the menu bar
    jge .menu
    call bar_paint
.menu:
    call mn_paint                       ; an open menu, over all
    mov edi, MVL_MENU                   ; and a menu fading
    call motion_paint
    DS_LAP DS_BAR
    jmp .shown
.screen:
    call screen_paint
    DS_LAP DS_WINS
.shown:
    call gfx_target_back                ; the clip off again
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    call gfx_blit
    DS_LAP DS_BLIT
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; screen_paint(RDI = the window full screen): its client, all of the
; screen, within the clip; black where its pixels do not reach. Preserves
; RBX, RBP, R12-R15.
screen_paint:
    push rbx
    mov rbx, rdi
    mov rax, [rbx + WN_SF + SF_W]       ; RAX by RCX: its pixels, on the screen
    mov rcx, [rbx + WN_SF + SF_H]
    cmp qword [rbx + WN_SF + SF_PTR], 0
    jne .some
    xor eax, eax
    xor ecx, ecx
.some:
    cmp rax, [scr_w]
    jbe .w
    mov rax, [scr_w]
.w:
    cmp rcx, [scr_h]
    jbe .h
    mov rcx, [scr_h]
.h:
    push rax
    push rcx
    xor r8d, r8d                        ; black beyond them: at the right,
    mov rdi, rax
    xor esi, esi
    mov rdx, [scr_w]
    sub rdx, rax
    mov rcx, [scr_h]
    call gfx_fill
    mov rcx, [rsp]                      ; and below
    xor edi, edi
    mov rsi, rcx
    mov rdx, [rsp + 8]
    mov rcx, [scr_h]
    sub rcx, rsi
    call gfx_fill
    pop rcx
    pop rdx
    test rdx, rdx
    jz .out
    test rcx, rcx
    jz .out
    lea rax, [rbx + WN_SF]              ; then them, square
    mov [span_sf], rax
    mov qword [span_x], 0
    mov qword [span_y], 0
    xor edi, edi
    xor esi, esi
    xor r10d, r10d
    mov r11d, RC_ALL
    lea rbx, [span_copy]
    call rr_walk
.out:
    pop rbx
    ret

; wall_draw: the wallpaper, within the clip
wall_draw:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rdi, [tg_cx0]
    mov rsi, [tg_cy0]
    mov rdx, [tg_cx1]
    sub rdx, rdi
    jle .out
    mov rcx, [tg_cy1]
    sub rcx, rsi
    jle .out
    cmp qword [wall_sf + SF_PTR], 0
    je .plain
    lea r8, [wall_sf]
    call sf_copy_rows
    call wg_show                        ; the widgets over it
    jmp .out
.plain:
    mov r8d, COL_BG
    call gfx_fill
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; sf_copy_rows(RDI x, RSI y, RDX w, RCX h, R8 = a surface the screen's
; size): that part of it into the target at the same place. Preserves all.
sf_copy_rows:
    push rax
    push rcx
    push rsi
    push rdi
    push r9
    push r10
    mov r9, rsi
    imul r9, [r8 + SF_PITCH]
    lea r9, [r9 + rdi * 4]
    add r9, [r8 + SF_PTR]               ; from
    mov r10, rsi
    imul r10, [tg_pitch]
    lea r10, [r10 + rdi * 4]
    add r10, [tg_ptr]                   ; to
    mov rax, rcx
.row:
    mov rsi, r9
    mov rdi, r10
    mov rcx, rdx
    rep movsd
    add r9, [r8 + SF_PITCH]
    add r10, [tg_pitch]
    dec rax
    jnz .row
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; desk_frame(RDI = window): its shadow, title bar, buttons, title, client
; and outline into the back buffer, within the clip. Preserves RDI.
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
    lea r8, [sh_other]                  ; its shadow
    cmp rbx, [desk_focus]
    jne .shadow
    lea r8, [sh_focus]
.shadow:
    call gfx_shadow
    mov rdi, r12                        ; the title bar
    mov rsi, r13
    mov rdx, r14
    mov rcx, [fr_t]
    mov r8d, [th_c + TC_TITLE_OFF]
    cmp rbx, [desk_focus]
    jne .bar_color
    mov r8d, [th_c + TC_TITLE]
.bar_color:
    mov r9d, 256
    mov r10, [m_r]
    mov r11d, RC_TOP
    cmp qword [rbx + WN_H], 0
    jne .bar
    mov r11d, RC_ALL
.bar:
    call gfx_rrect
    mov rdi, r12                        ; the line under it
    mov rsi, r13
    add rsi, [fr_t]
    dec rsi
    mov rdx, r14
    mov ecx, 1
    mov r8d, [th_c + TC_SEP]
    mov r9d, 160
    call gfx_fill_a
    call frame_buttons
    call frame_title
    ; the client, its bottom corners round
    cmp qword [rbx + WN_SF + SF_PTR], 0
    je .outline
    mov rdi, rbx
    call win_client
    mov [span_sf], rbx                  ; (WN_SF is at WN_SF: a surface)
    add qword [span_sf], WN_SF
    mov [span_x], rdi
    mov [span_y], rsi
    mov rax, [rbx + WN_SF + SF_W]       ; no more than its pixels
    cmp rdx, rax
    jbe .w
    mov rdx, rax
.w:
    mov rax, [rbx + WN_SF + SF_H]
    cmp rcx, rax
    jbe .h
    mov rcx, rax
.h:
    mov r10, [m_r]
    mov r11d, RC_BOTTOM
    push rbx
    lea rbx, [span_copy]
    call rr_walk
    pop rbx
.outline:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8d, [th_c + TC_EDGE]
    mov r9d, [th_c + TC_EDGE_A]
    mov r10, [m_r]
    call gfx_rring
    mov rdi, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; frame_buttons (RBX = window, R12, R13 = its top left): close, minimise,
; zoom; colored on the window with the keys or under the pointer
frame_buttons:
    push r14
    push r15
    xor r14d, r14d                      ; which
.each:
    cmp r14, 3
    jae .out
    mov rdi, r14                        ; RDI, RSI = its box
    imul rdi, [m_light_step]
    add rdi, r12
    add rdi, [m_light_x]
    mov rsi, [fr_t]
    sub rsi, [m_light]
    sar rsi, 1
    add rsi, r13
    lea rax, [light_colors]
    mov r8d, [rax + r14 * 4]
    cmp rbx, [desk_focus]
    je .lit
    cmp rbx, [hover_win]
    je .lit
    mov r8d, [th_c + TC_LIGHT_OFF]
.lit:
    cmp r14, 2                          ; no zoom for a window of one size
    jne .able
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jnz .able
    mov r8d, [th_c + TC_LIGHT_OFF]
.able:
    test r14, r14                       ; nor a close without its button
    jnz .draw
    test dword [rbx + WN_FLAGS], WF_CLOSE
    jnz .draw
    mov r8d, [th_c + TC_LIGHT_OFF]
.draw:
    mov rdx, [m_light]
    mov r9d, 256
    call gfx_circle
    mov r9d, 40                         ; an edge a little darker
    mov r15d, r8d
    mov r8d, 0x000000
    mov rcx, rdx
    mov r10, rdx
    shr r10, 1
    call gfx_rring
    cmp rbx, [hover_win]                ; under the pointer: what each does
    jne .next
    call light_mark
.next:
    inc r14
    jmp .each
.out:
    pop r15
    pop r14
    ret

; light_mark(RDI, RSI = a button's box, R14 = which): what it does on it,
; in a darker shade of it: x, - or +
light_mark:
    push rbx
    push r8
    push r9
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rbx, [m_light]
    lea rax, [light_marks]
    mov r8d, [rax + r14 * 4]
    test r14, r14
    jz .x
    mov rdx, rbx                        ; a bar across: half the box long,
    shr rdx, 1                          ; an eighth thick
    mov rcx, rbx
    shr rcx, 3
    jnz .thick
    inc ecx
.thick:
    mov rax, rbx
    sub rax, rdx
    shr rax, 1
    lea rdi, [r12 + rax]
    mov rax, rbx
    sub rax, rcx
    shr rax, 1
    lea rsi, [r13 + rax]
    mov r9d, 220
    call gfx_fill_a
    cmp r14, 2                          ; and one down, for +
    jne .out
    xchg rdx, rcx
    mov rax, rbx
    sub rax, rdx
    shr rax, 1
    lea rdi, [r12 + rax]
    mov rax, rbx
    sub rax, rcx
    shr rax, 1
    lea rsi, [r13 + rax]
    call gfx_fill_a
    jmp .out
.x:
    shl r12, 8                          ; in 1/256 pixels
    shl r13, 8
    mov rax, rbx
    shl rax, 8
    imul rcx, rax, 3                    ; the arms: from 0.3 to 0.7 of the box
    xor edx, edx
    push rax
    mov rax, rcx
    mov ecx, 10
    div rcx
    mov r9, rax                         ; 0.3
    pop rax
    mov r10, rax
    sub r10, r9                         ; 0.7
    xor edx, edx
    mov ecx, 24
    div rcx
    mov r11, rax                        ; half its thickness, about
    lea rdi, [light_pts]
    ; \: (a, a) to (b, b)
    lea rax, [r12 + r9]
    add rax, r11
    mov [rdi], eax
    lea rax, [r13 + r9]
    sub rax, r11
    mov [rdi + 4], eax
    lea rax, [r12 + r10]
    add rax, r11
    mov [rdi + 8], eax
    lea rax, [r13 + r10]
    sub rax, r11
    mov [rdi + 12], eax
    lea rax, [r12 + r10]
    sub rax, r11
    mov [rdi + 16], eax
    lea rax, [r13 + r10]
    add rax, r11
    mov [rdi + 20], eax
    lea rax, [r12 + r9]
    sub rax, r11
    mov [rdi + 24], eax
    lea rax, [r13 + r9]
    add rax, r11
    mov [rdi + 28], eax
    ; /: (b, a) to (a, b)
    lea rax, [r12 + r10]
    sub rax, r11
    mov [rdi + 32], eax
    lea rax, [r13 + r9]
    sub rax, r11
    mov [rdi + 36], eax
    lea rax, [r12 + r10]
    add rax, r11
    mov [rdi + 40], eax
    lea rax, [r13 + r9]
    add rax, r11
    mov [rdi + 44], eax
    lea rax, [r12 + r9]
    add rax, r11
    mov [rdi + 48], eax
    lea rax, [r13 + r10]
    add rax, r11
    mov [rdi + 52], eax
    lea rax, [r12 + r9]
    sub rax, r11
    mov [rdi + 56], eax
    lea rax, [r13 + r10]
    sub rax, r11
    mov [rdi + 60], eax
    mov esi, 4
    mov edx, r8d
    mov ecx, 220
    call gfx_poly
    lea rdi, [light_pts + 32]
    call gfx_poly
.out:
    pop r13
    pop r12
    pop r9
    pop r8
    pop rbx
    ret

; frame_title (RBX = window, R12, R13 = its top left, R14 = width): the
; title, in the middle of the bar, clear of the buttons
frame_title:
    push r15
    mov r15, [m_light_step]             ; the room: past the buttons, and as
    imul r15, r15, 3                    ; much at the right
    add r15, [m_light_x]
    mov r9, r14
    sub r9, r15
    sub r9, r15
    jle .out                            ; the most it may be wide
    lea rdi, [rbx + WN_TITLE]
    mov esi, [f_title]
    call uf_width
    cmp rax, r9
    jbe .fits
    mov rax, r9
.fits:
    mov rdi, r14                        ; centred
    sub rdi, rax
    sar rdi, 1
    add rdi, r12
    push rdi
    mov edi, [f_title]                  ; the baseline: the middle, and half
    call uf_metrics                     ; a capital below it
    mov esi, [rax + UFT_CAP]
    pop rdi
    mov rax, [fr_t]
    add rax, rsi
    shr rax, 1
    lea rsi, [r13 + rax]
    lea rdx, [rbx + WN_TITLE]
    mov ecx, [th_c + TC_TEXT3]
    cmp rbx, [desk_focus]
    jne .color
    mov ecx, [th_c + TC_TEXT]
.color:
    mov r8d, [f_title]
    call uf_text_max
.out:
    pop r15
    ret

; span_copy: rr_walk's span: the pixels of span_sf, whose top left is at
; span_x, span_y
span_copy:
    push rbx
    push r8
    push r9
    push r14
    mov rax, r13
    sub rax, [span_y]
    mov rbx, [span_sf]
    imul rax, [rbx + SF_PITCH]
    mov r8, r12
    sub r8, [span_x]
    lea rax, [rax + r8 * 4]
    add rax, [rbx + SF_PTR]
    mov rbx, rax
    test rsi, rsi
    jnz .masked
    push rsi
    mov rsi, rbx
    rep movsd
    pop rsi
    jmp .out
.masked:
    mov r8d, [rbx]
    add rbx, 4
    movzx eax, byte [rsi]
    add rsi, rdx
    test eax, eax
    jz .next
    cmp eax, 255
    je .all
    mov r9d, eax
    shr r9d, 7
    add r9d, eax
    mov r14d, 256
    sub r14d, r9d
    mov eax, [rdi]
    MIX eax, r8d, r9d, r14d, r10d, r11d
    mov [rdi], eax
    jmp .next
.all:
    mov [rdi], r8d
.next:
    add rdi, 4
    dec rcx
    jnz .masked
.out:
    pop r14
    pop r9
    pop r8
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The menu bar
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
    mov rcx, [m_bar_h]
    call desk_damage
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

; bar_paint: the bar, within the clip
bar_paint:
    push rbx
    push r12
    push r13
    ; its glass
    mov rdi, [tg_cx0]
    mov rdx, [tg_cx1]
    sub rdx, rdi
    jle .out
    mov rsi, [tg_cy0]
    mov rcx, [m_bar_h]
    cmp rcx, [tg_cy1]
    jle .rows
    mov rcx, [tg_cy1]
.rows:
    sub rcx, rsi
    jle .out
    cmp qword [bar_sf + SF_PTR], 0
    je .text
    lea r8, [bar_sf]
    call sf_copy_rows
.text:
    mov edi, [f_body]                   ; the baseline: the middle, plus half
    call uf_metrics                     ; a capital
    mov eax, [rax + UFT_CAP]
    add rax, [m_bar_h]
    shr rax, 1
    mov r13, rax
    call bar_layout                     ; where each thing is
    call bt_paint                       ; the open menu's title lit, the app,
    call bar_mark                       ; the menus; the mark
    mov rdi, [bar_clock_x]              ; at the right: the time,
    mov rsi, r13
    lea rdx, [bar_clock_text]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_body]
    call uf_text
    call st_paint                       ; and the battery, the network, the
.out:                                   ; launcher
    pop r13
    pop r12
    pop rbx
    ret

; bar_app_name -> RAX = the name of the app in front: its dock name, or
; its own. Preserves RDI.
bar_app_name:
    lea rax, [str_finder]
    mov rsi, [desk_focus]
    test rsi, rsi
    jz .out
    push rdi
    mov rdi, rsi
    call win_app
    pop rdi
    test eax, eax
    js .own
    imul eax, eax, DA_SIZE
    lea rsi, [dock_apps]
    mov rax, [rsi + rax + DA_LABEL]
    ret
.own:
    mov rsi, [desk_focus]
    lea rax, [rsi + WN_APP]
.out:
    ret

; bar_mark: Axiom's mark at the left of the bar: a triangle, open inside
bar_mark:
    push rbx
    push r12
    push r13
    mov rbx, [m_mark]                   ; its side
    mov r12, [m_bar_pad]                ; its left
    mov r13, [m_bar_h]                  ; its top
    sub r13, rbx
    sar r13, 1
    shl rbx, 8
    shl r12, 8
    shl r13, 8
    lea rdi, [light_pts]
    ; outside: apex, bottom right, bottom left; then in, the other way, and
    ; back out (the two sides of the cut cancel)
    mov rax, rbx
    shr rax, 1
    add rax, r12
    mov [rdi], eax                      ; apex
    mov [rdi + 4], r13d
    lea rax, [r12 + rbx]
    mov [rdi + 8], eax                  ; bottom right
    lea rax, [r13 + rbx]
    mov [rdi + 12], eax
    mov [rdi + 16], r12d                ; bottom left
    mov [rdi + 20], eax
    mov rax, rbx                        ; back to the apex, then in
    shr rax, 1
    add rax, r12
    mov [rdi + 24], eax
    mov [rdi + 28], r13d
    mov rcx, rbx                        ; the inner triangle: a third of it
    shr rcx, 2
    mov [rdi + 32], eax                 ; inner apex
    lea rdx, [r13 + rcx * 2]
    mov [rdi + 36], edx
    lea rdx, [r12 + rcx]                ; inner bottom left
    mov [rdi + 40], edx
    lea rdx, [r13 + rbx]
    sub rdx, rcx
    mov [rdi + 44], edx
    lea rdx, [r12 + rbx]                ; inner bottom right
    sub rdx, rcx
    mov [rdi + 48], edx
    lea rdx, [r13 + rbx]
    sub rdx, rcx
    mov [rdi + 52], edx
    mov [rdi + 56], eax                 ; inner apex again
    lea rdx, [r13 + rcx * 2]
    mov [rdi + 60], edx
    mov esi, 8
    mov edx, [th_accent]
    mov ecx, 256
    call gfx_poly
    pop r13
    pop r12
    pop rbx
    ret

; bar_clock: bar_clock_text = the day and the time, as "Sat 18 Oct  14:05"
bar_clock:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    call rtc_read
    mov rax, [rtc_year]                 ; the weekday, by Sakamoto's method
    mov rcx, [rtc_mon]
    cmp rcx, 3
    jae .y
    dec rax
.y:
    mov r8, rax
    mov r9, rax
    shr r9, 2
    add r8, r9
    mov r9, rax
    xor edx, edx
    push rax
    mov rax, r9
    mov r9d, 100
    div r9
    sub r8, rax
    pop rax
    xor edx, edx
    mov r9d, 400
    div r9
    add r8, rax
    lea rax, [dow_t]
    movzx eax, byte [rax + rcx - 1]
    add r8, rax
    add r8, [rtc_day]
    mov rax, r8
    xor edx, edx
    mov r9d, 7
    div r9
    lea rax, [day_names]
    lea r8, [rax + rdx * 4]
    mov rcx, [rtc_mon]
    dec rcx
    lea rax, [month_names]
    lea r9, [rax + rcx * 4]
    lea rdi, [bar_clock_text]
    SPRINTF rdi, "%s %u %s  %u:%02u", r8, qword [rtc_day], r9, qword [rtc_hour], qword [rtc_min]
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; desk_tick: twice a second (ui_refresh): the clock, when its minute turns
desk_tick:
    push rax
    call rtc_read
    mov rax, [rtc_min]
    cmp rax, [bar_minute]
    je .out
    mov [bar_minute], rax
    call desk_bar_damage
.out:
    call st_tick                        ; the battery and the network,
    call wg_tick                        ; the widgets
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The dock
; -----------------------------------------------------------------------------

; win_app(RDI = window) -> EAX = its app in the dock, -1 if none. Preserves
; others.
win_app:
    push rcx
    push rsi
    push rdi
    lea rax, [term_ops]
    cmp [rdi + WN_OPS], rax
    je .terminal
    cmp rdi, [sys_win]
    je .system
    cmp rdi, [cpu_win]
    je .system
    cmp rdi, [demo_win]
    je .mandel
    xor ecx, ecx
.each:
    cmp ecx, DOCK_APPS
    jae .none
    imul rax, rcx, DA_SIZE
    lea rsi, [dock_apps]
    mov rsi, [rsi + rax + DA_PROG]
    test rsi, rsi
    jz .next
    push rdi
    lea rdi, [rdi + WN_APP]
    call str_same_case
    pop rdi
    jz .found
.next:
    inc ecx
    jmp .each
.found:
    mov eax, ecx
    jmp .out
.terminal:
    mov eax, APP_TERMINAL
    jmp .out
.system:
    mov eax, APP_SYSTEM
    jmp .out
.mandel:
    mov eax, APP_MANDEL
    jmp .out
.none:
    mov eax, -1
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; str_same_case(RDI, RSI = text) -> ZF set if they are the same, but for
; case. Preserves all.
str_same_case:
    push rax
    push rcx
    push rsi
    push rdi
.each:
    mov al, [rdi]
    mov cl, [rsi]
    or al, 0x20
    or cl, 0x20
    cmp al, cl
    jne .out
    cmp byte [rdi], 0
    je .same
    cmp byte [rsi], 0
    je .out
    inc rdi
    inc rsi
    jmp .each
.same:
    cmp byte [rsi], 0
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; dock_layout: the dock's items and where each is, again; what changed,
; damaged
dock_layout:
    push rbx
    push r12
    push r13
    push r14
    mov byte [dock_dirty], 0
    call dock_damage                    ; where it was
    xor r12d, r12d                      ; items
    lea r13, [dock_items]
    xor ebx, ebx                        ; the apps
.app:
    cmp ebx, DOCK_APPS
    jae .extras
    mov dword [r13 + DI_KIND], DK_APP
    mov [r13 + DI_APP], ebx
    mov qword [r13 + DI_WIN], 0
    imul rax, rbx, SF_SIZE
    lea rcx, [app_icons]
    add rax, rcx
    mov [r13 + DI_ICON], rax
    imul rax, rbx, DA_SIZE
    lea rcx, [dock_apps]
    mov rax, [rcx + rax + DA_LABEL]
    mov [r13 + DI_LABEL], rax
    mov edi, ebx
    call dock_running
    mov [r13 + DI_RUN], rax
    add r13, DI_SIZE
    inc r12
    inc ebx
    jmp .app
.extras:
    xor ebx, ebx                        ; windows of other programs: one each
.extra:
    cmp ebx, DESK_MAX
    jae .minimised
    lea rax, [desk_wins]
    mov rdi, [rax + rbx * 8]
    test rdi, rdi
    jz .extra_next
    test dword [rdi + WN_FLAGS], WF_CLOSING | WF_AWAY
    jnz .extra_next
    call win_app
    test eax, eax
    jns .extra_next
    lea rcx, [dock_items]               ; one of its app already?
    imul rax, r12, DI_SIZE
    add rax, rcx
.seen:
    cmp rcx, rax
    jae .new_extra
    cmp dword [rcx + DI_KIND], DK_EXTRA
    jne .seen_next
    mov rsi, [rcx + DI_WIN]
    lea rsi, [rsi + WN_APP]
    push rdi
    lea rdi, [rdi + WN_APP]
    call str_same_case
    pop rdi
    je .extra_next
.seen_next:
    add rcx, DI_SIZE
    jmp .seen
.new_extra:
    cmp qword [rdi + WN_ICON + SF_PTR], 0
    jne .has_icon
    call icon_for
.has_icon:
    mov dword [r13 + DI_KIND], DK_EXTRA
    mov dword [r13 + DI_APP], -1
    mov [r13 + DI_WIN], rdi
    lea rax, [rdi + WN_ICON]
    mov [r13 + DI_ICON], rax
    lea rax, [rdi + WN_APP]
    mov [r13 + DI_LABEL], rax
    mov qword [r13 + DI_RUN], 1
    add r13, DI_SIZE
    inc r12
.extra_next:
    inc ebx
    jmp .extra
.minimised:
    mov [dock_sep], r12                 ; the line, before these
    xor ebx, ebx
.min:
    cmp ebx, DESK_MAX
    jae .place
    lea rax, [desk_wins]
    mov rdi, [rax + rbx * 8]
    test rdi, rdi
    jz .min_next
    test dword [rdi + WN_FLAGS], WF_SHOWN | WF_CLOSING | WF_AWAY
    jnz .min_next
    cmp qword [rdi + WN_THUMB + SF_PTR], 0
    jne .has_thumb
    call win_thumb
.has_thumb:
    mov dword [r13 + DI_KIND], DK_MIN
    mov dword [r13 + DI_APP], -1
    mov [r13 + DI_WIN], rdi
    lea rax, [rdi + WN_THUMB]
    mov [r13 + DI_ICON], rax
    lea rax, [rdi + WN_TITLE]
    mov [r13 + DI_LABEL], rax
    mov qword [r13 + DI_RUN], 0
    add r13, DI_SIZE
    inc r12
.min_next:
    inc ebx
    jmp .min
.place:
    mov [dock_n], r12
    ; the width: the icons, the space between, the line if there is one
    mov rax, [m_icon]
    add rax, [m_dock_space]
    imul rax, r12
    sub rax, [m_dock_space]
    add rax, [m_dock_pad]
    add rax, [m_dock_pad]
    cmp [dock_sep], r12
    jae .no_sep
    add rax, [m_dock_space]
    add rax, [m_dock_space]
    inc rax
.no_sep:
    mov [dock_w], rax
    mov rcx, [scr_w]
    sub rcx, rax
    sar rcx, 1
    mov [dock_x], rcx
    add rcx, [m_dock_pad]               ; each item's x
    lea r13, [dock_items]
    xor ebx, ebx
.x:
    cmp rbx, r12
    jae .placed
    cmp rbx, [dock_sep]
    jne .at
    test rbx, rbx
    jz .at
    add rcx, [m_dock_space]
    add rcx, [m_dock_space]
    inc rcx
.at:
    mov [r13 + DI_X], rcx
    add rcx, [m_icon]
    add rcx, [m_dock_space]
    add r13, DI_SIZE
    inc rbx
    jmp .x
.placed:
    call dock_magnify                   ; magnified as it is now,
    call dock_pane                      ; its glass,
    call dock_damage                    ; and where it is now
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; dock_running(EDI = an app) -> RAX = 1 if it has a window (not put away).
; Preserves others.
dock_running:
    push rcx
    push rdx
    push rdi
    mov edx, edi
    xor ecx, ecx
.each:
    lea rax, [desk_wins]
    mov rdi, [rax + rcx * 8]
    test rdi, rdi
    jz .next
    test dword [rdi + WN_FLAGS], WF_CLOSING | WF_AWAY
    jnz .next
    call win_app
    cmp eax, edx
    je .yes
.next:
    inc ecx
    cmp ecx, DESK_MAX
    jb .each
    xor eax, eax
    jmp .out
.yes:
    mov eax, 1
.out:
    pop rdi
    pop rdx
    pop rcx
    ret

; dock_damage: the dock and the name over it, where they were drawn last
; and where they are now. Preserves all.
dock_damage:
    push rax
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    cmp qword [dock_w], 0
    je .out
    call dock_extent
    mov rax, [dock_seen_x0]             ; with where it was drawn
    mov [dock_seen_x0], rdi
    cmp rax, rdi
    jge .x0
    mov rdi, rax
.x0:
    mov rax, [dock_seen_x1]
    mov [dock_seen_x1], rdx
    cmp rax, rdx
    jle .x1
    mov rdx, rax
.x1:
    mov rax, [dock_seen_y0]
    mov [dock_seen_y0], rsi
    cmp rax, rsi
    jge .y0
    mov rsi, rax
.y0:
    sub rdx, rdi
    mov rcx, [scr_h]                    ; down to the screen's bottom
    sub rcx, rsi
    lea r8, [dock_gl]                   ; its own: its glass is as it was
    call desk_damage_own
.out:
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rax
    ret

; dock_paint: the dock, within the clip: its icons magnified round the
; pointer (DI_MX, DI_MS), an app's bouncing as it starts
dock_paint:
    push rbx
    push r12
    push r13
    push r14
    cmp qword [dock_w], 0
    je .out
    mov rdi, [dock_mx0]                 ; glass: blurred, tinted, outlined
    mov rsi, [m_dock_y]
    mov rdx, [dock_mx1]
    sub rdx, rdi
    mov rcx, [m_dock_h]
    lea rax, [dock_gl]
    mov r10, [m_dock_r]
    call glass_paint
    mov r8d, [th_c + TC_DOCK]
    mov r9d, [th_c + TC_DOCK_A]
    mov r10, [m_dock_r]
    mov r11d, RC_ALL
    call gfx_rrect
    mov r8d, [th_c + TC_DOCK_EDGE]
    mov r9d, [th_c + TC_DOCK_EDGE_A]
    call gfx_rring
    lea r12, [dock_items]
    xor ebx, ebx
.item:
    cmp rbx, [dock_n]
    jae .out
    cmp rbx, [dock_sep]                 ; the line before the minimised:
    jne .icon                           ; midway from the item before
    test rbx, rbx
    jz .icon
    mov rdi, [r12 - DI_SIZE + DI_MX]
    add rdi, [r12 - DI_SIZE + DI_MS]
    add rdi, [r12 + DI_MX]
    sar rdi, 1
    mov rsi, [m_dock_y]
    add rsi, [m_dock_pad]
    add rsi, [m_dock_pad]
    mov edx, 1
    mov rcx, [m_icon]
    sub rcx, [m_dock_pad]
    sub rcx, [m_dock_pad]
    mov r8d, [th_c + TC_DOCK_EDGE]
    mov r9d, 90
    call gfx_fill_a
.icon:
    cmp dword [r12 + DI_KIND], DK_MIN   ; a window going in or coming out:
    jne .picture                        ; it is drawn as it moves
    mov rax, [r12 + DI_WIN]
    test dword [rax + WN_FLAGS], WF_ANIM
    jnz .next
.picture:
    mov rdx, [r12 + DI_ICON]
    cmp qword [rdx + SF_PTR], 0
    je .dot
    xor r13d, r13d                      ; R13: how far up, bouncing
    cmp dword [r12 + DI_KIND], DK_APP
    jne .alpha
    mov eax, [r12 + DI_APP]
    call dock_rise
    mov r13, rax
.alpha:
    mov r8d, 256
    cmp rbx, [dock_press]               ; held down: darker
    jne .sized
    mov r8d, 170
.sized:
    mov r14, [r12 + DI_MS]              ; R14: its side
    cmp r14, [m_icon]
    jne .scaled
    mov rdi, [r12 + DI_MX]              ; as made: centred in its place
    mov rax, [m_icon]
    sub rax, [rdx + SF_W]
    sar rax, 1
    add rdi, rax
    mov rsi, [m_dock_y]
    add rsi, [m_dock_pad]
    mov rax, [m_icon]
    sub rax, [rdx + SF_H]
    sar rax, 1
    add rsi, rax
    sub rsi, r13
    call gfx_image
    jmp .dot
.scaled:
    mov r9d, r8d                        ; magnified: from an app's big icon,
    mov r8, rdx                         ; else its own scaled; centred in its
    cmp dword [r12 + DI_KIND], DK_APP   ; place, on the icons' line
    jne .from
    mov eax, [r12 + DI_APP]
    imul rax, rax, SF_SIZE
    lea rcx, [app_icons_big]
    add rax, rcx
    cmp qword [rax + SF_PTR], 0
    je .from
    mov r8, rax
.from:
    mov rax, [rdx + SF_W]               ; the size: its own, scaled
    imul rax, r14
    xor edx, edx
    div qword [m_icon]
    mov rsi, rax                        ; (w)
    mov rdx, [r12 + DI_ICON]
    mov rax, [rdx + SF_H]
    imul rax, r14
    xor edx, edx
    div qword [m_icon]
    mov rcx, rax                        ; h
    mov rdx, rsi                        ; w
    mov rdi, r14
    sub rdi, rdx
    sar rdi, 1
    add rdi, [r12 + DI_MX]
    mov rsi, [m_dock_y]
    add rsi, [m_dock_pad]
    add rsi, [m_icon]
    sub rsi, r14
    mov rax, r14
    sub rax, rcx
    sar rax, 1
    add rsi, rax
    sub rsi, r13
    mov r10d, 1
    call pic_draw
.dot:
    cmp qword [r12 + DI_RUN], 0
    je .next
    mov rdi, [r12 + DI_MX]
    mov rax, [r12 + DI_MS]
    sub rax, [m_dot]
    sar rax, 1
    add rdi, rax
    mov rsi, [m_dock_y]
    add rsi, [m_dock_h]
    mov rax, [m_dock_pad]
    add rax, [m_dot]
    sar rax, 1
    sub rsi, rax
    mov rdx, [m_dot]
    mov r8d, [th_c + TC_TEXT]
    mov r9d, 200
    call gfx_circle
.next:
    add r12, DI_SIZE
    inc rbx
    jmp .item
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tip_paint: the name of the item under the pointer, over it
tip_paint:
    push rbx
    push r12
    push r13
    mov rbx, [dock_hover]
    cmp rbx, [dock_n]
    jae .out
    imul rbx, rbx, DI_SIZE
    lea rax, [dock_items]
    add rbx, rax
    cmp dword [rbx + DI_KIND], DK_APP   ; not while it bounces, starting
    jne .named
    mov eax, [rbx + DI_APP]
    lea rcx, [dock_bounce]
    cmp qword [rcx + rax * 8], 0
    jne .out
.named:
    mov rdi, [rbx + DI_LABEL]
    mov esi, [f_body]
    call uf_width
    mov r12, rax                        ; the text's width
    lea rdx, [rax + 0]
    add rdx, [m_tip_pad]
    add rdx, [m_tip_pad]                ; the pill's
    mov rdi, [rbx + DI_MX]
    mov rax, [rbx + DI_MS]
    sub rax, rdx
    sar rax, 1
    add rdi, rax
    mov rax, [scr_w]                    ; on the screen
    sub rax, rdx
    cmp rdi, rax
    jle .right
    mov rdi, rax
.right:
    test rdi, rdi
    jns .left
    xor edi, edi
.left:
    mov r13, rdi
    mov rsi, [m_dock_y]                 ; over the item's top, or the dock's
    add rsi, [m_dock_pad]
    add rsi, [m_icon]
    sub rsi, [rbx + DI_MS]
    cmp rsi, [m_dock_y]
    jle .over
    mov rsi, [m_dock_y]
.over:
    sub rsi, [m_tip_gap]
    sub rsi, [m_tip_h]
    mov rcx, [m_tip_h]
    mov r8d, [th_c + TC_TIP]
    mov r9d, [th_c + TC_TIP_A]
    mov r10, rcx
    shr r10, 1
    mov r11d, RC_ALL
    call gfx_rrect
    mov r8d, [th_c + TC_DOCK_EDGE]
    mov r9d, [th_c + TC_DOCK_EDGE_A]
    call gfx_rring
    push rsi
    mov edi, [f_body]
    call uf_metrics
    pop rsi
    mov eax, [rax + UFT_CAP]
    add rax, [m_tip_h]
    shr rax, 1
    add rsi, rax
    mov rdi, r13
    add rdi, [m_tip_pad]
    mov rdx, [rbx + DI_LABEL]
    mov ecx, [th_c + TC_TIP_TEXT]
    mov r8d, [f_body]
    call uf_text
.out:
    pop r13
    pop r12
    pop rbx
    ret

; dock_at(RDI x, RSI y) -> RAX = the item there (as magnified), CF if none.
; Preserves others.
dock_at:
    push rcx
    push rdx
    xor ecx, ecx
    lea rdx, [dock_items]
.each:
    cmp rcx, [dock_n]
    jae .none
    mov rax, [rdx + DI_MX]
    cmp rdi, rax
    jl .next
    add rax, [rdx + DI_MS]
    cmp rdi, rax
    jge .next
    mov rax, [m_dock_y]                 ; below its top, or the dock's
    add rax, [m_dock_pad]
    add rax, [m_icon]
    sub rax, [rdx + DI_MS]
    cmp rax, [m_dock_y]
    jle .top
    mov rax, [m_dock_y]
.top:
    cmp rsi, rax
    jge .found
.next:
    add rdx, DI_SIZE
    inc rcx
    jmp .each
.found:
    mov rax, rcx
    clc
    jmp .out
.none:
    stc
.out:
    pop rdx
    pop rcx
    ret

; dock_spot(RDI = a window) -> RDI x, RSI y, RDX w, RCX h: its picture in
; the dock, minimised; CF if it is not there. Preserves others but RAX.
dock_spot:
    push r8
    xor ecx, ecx
    lea r8, [dock_items]
.each:
    cmp rcx, [dock_n]
    jae .none
    cmp dword [r8 + DI_KIND], DK_MIN
    jne .next
    cmp [r8 + DI_WIN], rdi
    je .found
.next:
    add r8, DI_SIZE
    inc rcx
    jmp .each
.found:
    mov rax, [r8 + DI_ICON]             ; its size (as magnified), centred
    mov rdx, [rax + SF_W]               ; in its place, on the icons' line
    mov rcx, [rax + SF_H]
    test rdx, rdx
    jz .square
    test rcx, rcx
    jnz .sized
.square:
    mov rdx, [m_icon]
    mov rcx, rdx
.sized:
    push r9
    mov r9, rdx
    mov rax, rcx
    imul rax, [r8 + DI_MS]
    xor edx, edx
    div qword [m_icon]
    mov rcx, rax                        ; h
    mov rax, r9
    imul rax, [r8 + DI_MS]
    xor edx, edx
    div qword [m_icon]
    mov rdx, rax                        ; w
    pop r9
    mov rdi, [r8 + DI_MS]
    sub rdi, rdx
    sar rdi, 1
    add rdi, [r8 + DI_MX]
    mov rsi, [r8 + DI_MS]
    sub rsi, rcx
    sar rsi, 1
    add rsi, [m_dock_y]
    add rsi, [m_dock_pad]
    add rsi, [m_icon]
    sub rsi, [r8 + DI_MS]
    pop r8
    clc
    ret
.none:
    pop r8
    stc
    ret

; dock_click(RAX = an item): what it is for
dock_click:
    push rbx
    imul rbx, rax, DI_SIZE
    lea rax, [dock_items]
    add rbx, rax
    mov eax, [rbx + DI_KIND]
    cmp eax, DK_APP
    je .app
    mov rdi, [rbx + DI_WIN]             ; a window: forward
    test rdi, rdi
    jz .out
    cmp eax, DK_MIN
    je .focus
    call win_app_front                  ; a program's: its topmost
.focus:
    call win_focus
    jmp .out
.app:
    mov edi, [rbx + DI_APP]
    call app_open
.out:
    pop rbx
    ret

; app_open(EDI = an app): its windows forward, if it has any; else it
; starts (the dock's apps, the menus)
app_open:
    push rbx
    mov ebx, edi
    call app_front
    jnc .out
    cmp ebx, APP_TERMINAL
    je .terminal
    cmp ebx, APP_SYSTEM                 ; built in: their windows are always
    je .out                             ; there, put away or not
    cmp ebx, APP_MANDEL
    je .out
    imul rax, rbx, DA_SIZE
    lea rcx, [dock_apps]
    mov rdi, [rcx + rax + DA_PROG]
    lea rsi, [str_empty]
    xor edx, edx
    mov ecx, 1                          ; not tied to a prompt
    call user_start
    jc .out
    jmp .bounce
.terminal:
    call term_new
.bounce:
    mov edi, ebx                        ; its icon bounces as it starts
    call dock_bounce_start
.out:
    pop rbx
    ret

; app_front(EDI = an app) -> CF if it has no window; else its topmost is
; focused - or, when it is in front already and it is the terminal, a new
; terminal opens. Preserves RBX, RBP, R12-R15.
app_front:
    push rbx
    push r12
    mov r12d, edi
    mov rdi, [desk_focus]               ; in front already
    test rdi, rdi
    jz .find
    call win_app
    cmp eax, r12d
    jne .find
    cmp r12d, APP_TERMINAL
    jne .done
    call term_new
    jmp .done
.find:
    mov rbx, [desk_zn]                  ; its topmost shown, else any
.down:
    test rbx, rbx
    jz .any
    dec rbx
    lea rax, [desk_z]
    mov rdi, [rax + rbx * 8]
    test dword [rdi + WN_FLAGS], WF_SHOWN
    jz .down
    test dword [rdi + WN_FLAGS], WF_CLOSING
    jnz .down
    call win_app
    cmp eax, r12d
    jne .down
    call win_focus
    cmp r12d, APP_SYSTEM                ; System is two windows
    jne .done
    call system_front
    jmp .done
.any:
    xor ebx, ebx
.slot:
    cmp ebx, DESK_MAX
    jae .none
    lea rax, [desk_wins]
    mov rdi, [rax + rbx * 8]
    inc ebx
    test rdi, rdi
    jz .slot
    test dword [rdi + WN_FLAGS], WF_CLOSING
    jnz .slot
    call win_app
    cmp eax, r12d
    jne .slot
    call win_focus
    cmp r12d, APP_SYSTEM
    jne .done
    call system_front
.done:
    clc
    jmp .out
.none:
    stc
.out:
    pop r12
    pop rbx
    ret

; system_front: both of System's windows forward
system_front:
    mov rdi, [cpu_win]
    test rdi, rdi
    jz .sys
    call win_focus
.sys:
    mov rdi, [sys_win]
    test rdi, rdi
    jz .out
    call win_focus
.out:
    ret

; win_app_front(RDI = window) -> RDI = the topmost shown window of its app
; (by its app name), itself if none. Preserves others.
win_app_front:
    push rax
    push rcx
    push rsi
    mov rsi, rdi
    mov rcx, [desk_zn]
.down:
    test rcx, rcx
    jz .out
    dec rcx
    lea rax, [desk_z]
    mov rax, [rax + rcx * 8]
    test dword [rax + WN_FLAGS], WF_SHOWN
    jz .down
    push rdi
    push rsi
    lea rdi, [rax + WN_APP]
    lea rsi, [rsi + WN_APP]
    call str_same_case
    pop rsi
    pop rdi
    jne .down
    mov rdi, rax
.out:
    pop rsi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The pointer and the keys
; -----------------------------------------------------------------------------

; desk_hit(RDI x, RSI y) -> RAX = the window there (0: none), EDX = P_*,
; R8, R9 = the point in its client, ECX = the edges (P_GRIP) or the dock's
; item (P_DOCK); full screen, that window's client everywhere. Preserves
; RBX, RBP, R12-R15.
desk_hit:
    mov rax, [desk_screen]
    test rax, rax
    jz .desk
    mov r8, rdi                         ; (its client's top left is the
    mov r9, rsi                         ; screen's)
    xor ecx, ecx
    mov edx, P_CLIENT
    ret
.desk:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    cmp r13, [m_bar_h]
    jge .dock
    xor eax, eax
    mov edx, P_BAR
    jmp .out
.dock:
    call dock_at
    jc .windows
    mov rcx, rax
    xor eax, eax
    mov edx, P_DOCK
    jmp .out
.windows:
    mov rbx, [desk_zn]
.down:
    test rbx, rbx
    jz .nothing
    dec rbx
    lea rax, [desk_z]
    mov r14, [rax + rbx * 8]
    test dword [r14 + WN_FLAGS], WF_SHOWN
    jz .down
    mov rdi, r14
    call win_outer
    mov r8, r12                         ; the point, from the window's corner
    sub r8, rdi
    mov r9, r13
    sub r9, rsi
    ; within the edges' reach, outside it?
    mov rax, [m_grab]
    xor ecx, ecx
    test dword [r14 + WN_FLAGS], WF_RESIZE
    jz .inside
    mov r10, rax
    neg r10                             ; -grab
    cmp r8, r10
    jl .down
    cmp r9, r10
    jl .down
    lea r11, [rdx + rax]
    cmp r8, r11
    jge .down
    lea r11, [rcx + 0]
    mov r11, [r14 + WN_H]
    add r11, [fr_t]
    add r11, rax
    cmp r9, r11
    jge .down
    cmp r8, rax                         ; which edges
    jge .not_l
    or ecx, EDGE_L
.not_l:
    mov r11, rdx
    sub r11, rax
    cmp r8, r11
    jl .not_r
    or ecx, EDGE_R
.not_r:
    test r9, r9
    jns .not_t
    or ecx, EDGE_T
.not_t:
    mov r11, [r14 + WN_H]
    add r11, [fr_t]
    sub r11, rax
    cmp r9, r11
    jl .not_b
    or ecx, EDGE_B
.not_b:
    test ecx, ecx
    jz .inside_ok
    mov rax, r14
    mov edx, P_GRIP
    jmp .out
.inside:
    test r8, r8                         ; a window of one size: inside only
    js .down
    test r9, r9
    js .down
    cmp r8, rdx
    jge .down
    mov rax, [r14 + WN_H]
    add rax, [fr_t]
    cmp r9, rax
    jge .down
.inside_ok:
    mov rax, r14
    cmp r9, [fr_t]                      ; the title bar
    jl .title
    sub r9, [fr_t]                      ; the client
    mov edx, P_CLIENT
    jmp .out
.title:
    mov rcx, r8                         ; a button? each a step wide
    sub rcx, [m_light_x]
    js .title_bar
    sub rcx, [m_light_step]
    js .b_close
    sub rcx, [m_light_step]
    js .b_min
    mov rdx, [m_light_step]
    shr rdx, 1
    sub rcx, rdx
    js .b_zoom
.title_bar:
    mov edx, P_TITLE
    jmp .out
.b_close:
    mov edx, P_CLOSE
    test dword [rax + WN_FLAGS], WF_CLOSE
    jnz .out
    mov edx, P_TITLE
    jmp .out
.b_min:
    mov edx, P_MIN
    jmp .out
.b_zoom:
    mov edx, P_ZOOM
    jmp .out
.nothing:
    xor eax, eax
    mov edx, P_NONE
.out:
    pop r14
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
    push r13
    mov r12d, edx
    cmp qword [desk_screen], 0          ; (full screen: no bar, no menus)
    jne .hit
    call mn_press                       ; the bar's, or an open menu's?
    jc .done
.hit:
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call desk_hit
    mov rbx, rax
    mov r13d, ecx
    cmp edx, P_BAR
    je .done
    cmp edx, P_DOCK
    je .dock
    test rbx, rbx
    jz .done
    cmp rbx, [desk_screen]              ; (it has the keys, on top)
    je .focused
    mov rdi, rbx
    call win_focus
.focused:
    cmp edx, P_CLIENT
    je .client
    cmp r12d, 1                         ; the frame's parts: the left button
    jne .done
    cmp edx, P_TITLE
    je .title
    cmp edx, P_GRIP
    je .size
    cmp edx, P_CLOSE
    je .close
    cmp edx, P_ZOOM
    je .zoom
    cmp edx, P_MIN
    jne .done
    mov rdi, rbx
    call win_minimise
    jmp .done
.close:
    mov rdi, rbx
    call win_ask
    jmp .done
.zoom:
    mov rdi, rbx
    call win_zoom
    jmp .done
.title:
    RDTSC64                             ; twice, quickly: zoom
    mov rcx, rax
    sub rax, [click_at]
    mov [click_at], rcx
    cmp rbx, [click_win]
    mov [click_win], rbx
    jne .move
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, DOUBLE_MS
    cmp rax, rcx
    jae .move
    mov qword [click_win], 0
    mov rdi, rbx
    call win_zoom
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
    mov [drag_edges], r13d
    mov rax, [ptr_x]
    mov [drag_dx], rax
    mov rax, [ptr_y]
    mov [drag_dy], rax
    mov rax, [rbx + WN_X]
    mov [drag_x0], rax
    mov rax, [rbx + WN_Y]
    mov [drag_y0], rax
    mov rax, [rbx + WN_W]
    mov [drag_w0], rax
    mov rax, [rbx + WN_H]
    mov [drag_h0], rax
    and dword [rbx + WN_FLAGS], ~WF_ZOOMED
    mov rdi, rbx
    call zoom_tell
    jmp .done
.client:
    mov [press_win], rbx
    mov byte [grab_off], 0              ; a click: held again, if it holds it
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
.dock:
    cmp r12d, 1
    jne .done
    mov [dock_press], r13
    call dock_damage
.done:
    pop r13
    pop r12
    pop rbx
.out:
    ret

; desk_release(EDX = button)
desk_release:
    call mn_release                     ; over an open menu's item: it is done
    cmp edx, 1
    jne .press
    mov byte [drag_mode], DRAG_NONE
    mov qword [drag_win], 0
    mov rax, [dock_press]               ; a dock item let go of over itself
    cmp rax, -1
    je .press
    mov qword [dock_press], -1
    call dock_damage
    push rax
    push rdx
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call dock_at
    mov rcx, rax
    pop rdx
    pop rax
    jc .press
    cmp rcx, rax
    jne .press
    push rdx
    call dock_click
    pop rdx
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
    push rbx
    call desk_hover                     ; what is under it now
    mov rax, [press_win]                ; a button held in a client
    test rax, rax
    jnz .client
    mov rdi, [ptr_x]                    ; or the client under the pointer
    mov rsi, [ptr_y]
    call desk_hit
    cmp edx, P_CLIENT
    jne .none
    mov rbx, rax
    mov [ptr_over], rbx
    call prog_left                      ; the one it was over, told
    jmp .tell
.none:
    xor ebx, ebx
    mov [ptr_over], rbx
    call prog_left
    pop rbx
    ret
.client:
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
    and dword [rdi + WN_FLAGS], ~WF_ZOOMED
    call zoom_tell
    jmp win_move
.size:
    ; from where it was: each edge held follows the pointer
    mov rsi, [drag_x0]
    mov rdx, [drag_y0]
    mov rcx, [drag_w0]
    mov r8, [drag_h0]
    mov rax, [ptr_x]
    sub rax, [drag_dx]                  ; how far it went
    mov r9, [ptr_y]
    sub r9, [drag_dy]
    test dword [drag_edges], EDGE_R
    jz .not_r
    add rcx, rax
.not_r:
    test dword [drag_edges], EDGE_B
    jz .not_b
    add r8, r9
.not_b:
    mov rdi, [drag_win]
    test dword [drag_edges], EDGE_L
    jz .not_l
    mov r10, rcx                        ; no smaller than it may be: the
    sub r10, rax                        ; left edge stops
    cmp r10, [rdi + WN_MIN_W]
    jge .l_ok
    mov rax, rcx
    sub rax, [rdi + WN_MIN_W]
.l_ok:
    add rsi, rax
    sub rcx, rax
.not_l:
    test dword [drag_edges], EDGE_T
    jz .not_t
    mov r10, r8
    sub r10, r9
    cmp r10, [rdi + WN_MIN_H]
    jge .t_ok
    mov r9, r8
    sub r9, [rdi + WN_MIN_H]
.t_ok:
    add rdx, r9
    sub r8, r9
.not_t:
    cmp rsi, [rdi + WN_X]
    jne .resized
    cmp rdx, [rdi + WN_Y]
    jne .resized
    cmp rcx, [rdi + WN_W]
    jne .resized
    cmp r8, [rdi + WN_H]
    je .out
.resized:
    jmp win_set_rect
.out:
    ret

; desk_hover: what is under the pointer, for the buttons that light and
; the dock's names
desk_hover:
    call mn_hover                       ; an open menu's item, or another menu
    call dock_point                     ; the dock magnified round it
    push rbx
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call desk_hit
    mov rbx, -1                         ; the dock's item
    cmp edx, P_DOCK
    jne .tip
    mov rbx, rcx
.tip:
    cmp rbx, [dock_hover]
    je .buttons
    mov [dock_hover], rbx
    call dock_damage
.buttons:
    xor ecx, ecx                        ; the window whose buttons it is over
    cmp edx, P_CLOSE
    je .over
    cmp edx, P_MIN
    je .over
    cmp edx, P_ZOOM
    jne .set
.over:
    mov rcx, rax
.set:
    mov rax, [hover_win]
    cmp rcx, rax
    je .out
    mov [hover_win], rcx
    test rax, rax
    jz .new
    mov rdi, rax
    call win_damage_frame
.new:
    test rcx, rcx
    jz .out
    mov rdi, rcx
    call win_damage_frame
.out:
    pop rbx
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

; desk_key(EAX = key code): to an open menu; else to the window with the
; keys; with none, to the first shell, brought forward. Ctrl+meta+F is the
; desk's: the window with the keys full screen, or back.
desk_key:
    cmp qword [mn_which], -1
    jne mn_key
    cmp eax, 'F' - 64
    jne .key
    mov cl, [kbd_got]
    and cl, WM_CTRL | WM_META
    cmp cl, WM_CTRL | WM_META
    jne .key
    mov rdi, [desk_focus]
    test rdi, rdi
    jnz win_screen_flip
    ret
.key:
    push rbx
    mov rbx, [desk_focus]
    test rbx, rbx
    jnz .to
    mov rbx, [con_first]
    test rbx, rbx
    jz .out
    mov rbx, [rbx + TW_WIN]
    test rbx, rbx
    jz .out
    mov rdi, rbx
    call win_focus
.to:
    mov rdx, [rbx + WN_OPS]
    mov rdx, [rdx + OP_KEY]
    test rdx, rdx
    jz .out
    call rdx
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  win [move|size|raise|min|zoom|screen|close <n> ...]
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
    push rdi
    mov rdi, r12
    lea rsi, [str_win_speed]
    call streq
    pop rdi
    test eax, eax
    jnz .speed
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
    lea rsi, [str_win_zoom]
    call streq
    test eax, eax
    jnz .zoom
    mov rdi, r12
    lea rsi, [str_win_screen]
    call streq
    test eax, eax
    jnz .screen
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
.zoom:
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jz .fixed
    mov rdi, rbx
    call win_zoom
    jmp .said
.screen:
    test dword [rbx + WN_FLAGS], WF_RESIZE
    jz .fixed
    mov rdi, rbx
    call win_screen_flip
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
    test dword [rbx + WN_FLAGS], WF_AWAY
    jnz .put_away
    KLOG "desk: '%s' is asked to close", rax
    jmp .out
.put_away:
    KLOG "desk: '%s' is put away (its app in the dock brings it back)", rax
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
.speed:
    call ds_say
    jmp .out
.usage:
    KLOG "usage: win [move <n> <x> <y> | size <n> <w> <h> | raise <n> | min <n> | zoom <n> | screen <n> | close <n> | speed]"
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
    test dword [rbx + WN_FLAGS], WF_AWAY
    jz .state
    lea rdx, [str_win_away]
.state:
    cmp rbx, [desk_focus]
    jne .say
    lea rdx, [str_win_focused]
    cmp rbx, [desk_screen]
    jne .say
    lea rdx, [str_win_full]
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
str_win_move:   db 'move', 0
str_win_size:   db 'size', 0
str_win_raise:  db 'raise', 0
str_win_min:    db 'min', 0
str_win_zoom:   db 'zoom', 0
str_win_screen: db 'screen', 0
str_win_close:  db 'close', 0
str_win_speed:  db 'speed', 0
str_win_shown:  db 'shown', 0
str_win_hidden: db 'minimised', 0
str_win_away:   db 'away', 0
str_win_focused: db 'focused', 0
str_win_full:   db 'full screen', 0
str_finder:     db 'Axiom', 0
str_empty:      db 0
align 4
light_colors:   dd 0xFF5F57, 0xFEBC2E, 0x28C840 ; close, minimise, zoom
light_marks:    dd 0x8C1A10, 0x985712, 0x0A6517 ; what each does, on it
dow_t:          db 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4
day_names:      db 'Sun', 0, 'Mon', 0, 'Tue', 0, 'Wed', 0, 'Thu', 0, 'Fri', 0, 'Sat', 0
month_names:    db 'Jan', 0, 'Feb', 0, 'Mar', 0, 'Apr', 0, 'May', 0, 'Jun', 0
                db 'Jul', 0, 'Aug', 0, 'Sep', 0, 'Oct', 0, 'Nov', 0, 'Dec', 0

; the dock's apps: the name it shows, the program it runs (0: built in),
; how its icon is drawn (icons.asm)
DA_LABEL        equ 0
DA_PROG         equ 8
DA_ICON         equ 16
DA_SIZE         equ 24
align 8
dock_apps:
    dq str_app_terminal, 0, icon_terminal
    dq str_app_files, str_prog_files, icon_files
    dq str_app_notes, str_prog_notes, icon_notes
    dq str_app_browse, str_prog_browse, icon_browse
    dq str_app_paint, str_prog_paint, icon_paint
    dq str_app_settings, str_prog_settings, icon_settings
    dq str_app_system, 0, icon_system
    dq str_app_mandel, 0, icon_mandel
str_app_terminal: db 'Terminal', 0
str_app_files:  db 'Files', 0
str_app_notes:  db 'Notes', 0
str_app_browse: db 'Browse', 0
str_app_paint:  db 'Paint', 0
str_app_settings: db 'Settings', 0
str_app_system: db 'System', 0
str_prog_files: db 'files', 0
str_prog_notes: db 'notes', 0
str_prog_browse: db 'browse', 0
str_prog_paint: db 'paint', 0
str_prog_settings: db 'settings', 0

section .data
desk_ready:     db 0
desk_reap:      db 0
drag_mode:      db DRAG_NONE
dock_dirty:     db 0
align 8
dock_hover:     dq -1                   ; the dock's item under the pointer
dock_press:     dq -1                   ; and the one held down

section .bss
alignb 8
fr_b:           resq 1                  ; a window: its border (none),
fr_t:           resq 1                  ; its title bar
fr_sh:          resq 1                  ; how far its shadow reaches
m_bar_h:        resq 1                  ; the menu bar's height
m_r:            resq 1                  ; a window's corners
m_light:        resq 1                  ; its buttons: across,
m_light_x:      resq 1                  ; the first's left,
m_light_step:   resq 1                  ; one to the next
m_grab:         resq 1                  ; how near an edge resizes
m_icon:         resq 1                  ; the dock: an icon,
m_dock_pad:     resq 1                  ; around them,
m_dock_space:   resq 1                  ; between them,
m_dock_gap:     resq 1                  ; under the dock,
m_dock_r:       resq 1                  ; its corners,
m_dock_h:       resq 1
m_dock_y:       resq 1                  ; its top
m_dock_top:     resq 1                  ; its icons' highest, magnified
m_icon_big:     resq 1                  ; an icon, magnified the most
m_dock_reach:   resq 1                  ; how far the magnifying reaches
m_dock_ext:     resq 1                  ; how far the glass grows each way
m_bounce:       resq 1                  ; how high an icon bounces
m_dot:          resq 1                  ; an app that runs
m_work_y1:      resq 1                  ; where windows that fill stop
m_blur:         resq 1                  ; the glass's blur
m_tip_h:        resq 1                  ; a name over the dock
m_tip_pad:      resq 1
m_tip_gap:      resq 1
m_bar_pad:      resq 1
m_gap:          resq 1                  ; between windows placed
m_mark:         resq 1                  ; Axiom's mark in the bar
ds_frames:      resq 1                  ; 'win speed': frames composed,
ds_cycles:      resq 1                  ; the time it took,
ds_max:         resq 1                  ; the longest,
ds_px:          resq 1                  ; pixels composed,
ds_parts:       resq DS_PARTS           ; the time by part (cleared with those)
ds_share:       resq DS_PARTS
ds_last:        resq 1
f_body:         resd 1                  ; fonts: text,
f_title:        resd 1                  ; titles,
f_small:        resd 1                  ; small
alignb 8
alignb 8
dock_gl:        resb GL_SIZE            ; the dock's glass
sh_focus:       resb SH_SIZE            ; the shadow of the window with the keys
sh_other:       resb SH_SIZE            ; of the others
bar_sf:         resb SF_SIZE            ; the menu bar's glass
desk_wins:      resq DESK_MAX           ; by slot
desk_z:         resq DESK_MAX           ; bottom to top
desk_zn:        resq 1
desk_focus:     resq 1                  ; the window with the keys
desk_screen:    resq 1                  ; the window full screen, 0 if none:
                                        ; shown, on top, with the keys
desk_focus_n:   resq 1                  ; how many times the keys have moved
desk_next_id:   resq 1
hover_win:      resq 1                  ; the window whose buttons the pointer is on
drag_win:       resq 1
drag_dx:        resq 1
drag_dy:        resq 1
drag_x0:        resq 1                  ; where a window resized began
drag_y0:        resq 1
drag_w0:        resq 1
drag_h0:        resq 1
drag_edges:     resd 1
alignb 8
press_win:      resq 1                  ; a client a button was pressed in
click_at:       resq 1                  ; the last press on a title bar: when,
click_win:      resq 1                  ; and on which window
span_sf:        resq 1                  ; span_copy's source
span_x:         resq 1
span_y:         resq 1
dmg_lock:       resd 1
alignb 8
dmg_n:          resq 1
dmg_rects:      resq DMG_MAX * 4        ; left, top, right, bottom
dock_n:         resq 1
dock_sep:       resq 1                  ; the first item past the line
dock_x:         resq 1
dock_w:         resq 1
dock_items:     resb DOCK_MAX * DI_SIZE
app_icons:      resb DOCK_APPS * SF_SIZE
bar_minute:     resq 1
bar_clock_text: resb 64
light_pts:      resd 32
