; =============================================================================
;  menus.asm - the menu bar's menus, and what it shows at its right.
;
;  At its left, after Axiom's mark and the name of the app in front: File,
;  Edit, View, Window and Help. A press on one of them (or on the mark)
;  opens its menu under it, of frosted glass; letting go over an item does
;  what it says, and a press anywhere else closes it. While one is open,
;  the pointer onto another title opens that one; the arrows choose, Enter
;  does, Esc closes.
;
;  At its right, before the time: the battery (its level, a bolt on its
;  charger, its percent), the network (Wi-Fi's fan, dim off a network, or
;  a wired one's sign) and a magnifier. The battery and the network open
;  a menu that says how they are; the magnifier opens the launcher, where
;  what is typed finds an app (or runs as a command) and Enter opens it.
;
;  An item (MI_*): its label, what it does and with what, its key, and
;  what says whether it may be chosen now and whether it is ticked. The
;  open menu's items are copied (or made, for the windows, the battery,
;  the network and the launcher) into mn_items as it opens.
; =============================================================================

MI_LABEL        equ 0                   ; its text; 0: a line between items
MI_DO           equ 8                   ; what it does (RDI = MI_ARG); 0: a note
MI_ARG          equ 16
MI_KEY          equ 24                  ; its key, as text, or 0
MI_STATE        equ 32                  ; (RDI = MI_ARG) -> EAX = MS_*; 0: none
MI_SIZE         equ 40

MS_OFF          equ 1                   ; not now: dim
MS_CHECK        equ 2                   ; ticked

MN_MAX          equ 48                  ; items in the open menu
MN_TEXT         equ 512                 ; labels made for it as it opens
MN_QUERY        equ 40                  ; what the launcher is asked, at most
MN_BLINK_MS     equ 70                  ; an item chosen: off this long, then on

BT_MARK         equ 0                   ; the bar's titles, left to right
BT_APP          equ 1                   ; (the app's name: not a menu)
BT_FILE         equ 2
BT_EDIT         equ 3
BT_VIEW         equ 4
BT_WINDOW       equ 5
BT_HELP         equ 6
BT_TITLES       equ 7
BT_BATTERY      equ 7                   ; then what is at its right
BT_NET          equ 8
BT_SEARCH       equ 9
BT_ALL          equ 10

NET_NONE        equ 0                   ; st_net: no network,
NET_WIFI_OFF    equ 1                   ; Wi-Fi, not on one,
NET_WIFI        equ 2                   ; Wi-Fi on one,
NET_WIRE_OFF    equ 3                   ; a cable, no link,
NET_WIRE        equ 4                   ; a link

ST_EVERY_MS     equ 5000                ; the battery and the network, looked at
ST_BAT_W        equ 24                  ; the battery's body, points
ST_BAT_H        equ 12
ST_BAT_ALL      equ 27                  ; with its tip
ST_LINE_A       equ 110                 ; its outline's alpha

; an item in a menu's table: label, what it does, with what, MS_* from
%macro ITEM 4
    [section .rodata]
    %%t: db %1, 0
    __SECT__
    dq %%t, %2, %3, 0, %4
%endmacro
; and with its key
%macro ITEMK 5
    [section .rodata]
    %%t: db %1, 0
    %%k: db %5, 0
    __SECT__
    dq %%t, %2, %3, %%k, %4
%endmacro
%macro LINE 0
    dq 0, 0, 0, 0, 0
%endmacro
%macro MENU_END 0
    dq -1
%endmacro

section .text

; mn_metrics: the menus' measures at this scale (desk_metrics). Preserves
; all.
mn_metrics:
    push rax
    push rdi
    PT mb_hp, 8                         ; a title's room either side
    PT mb_pill, 20                      ; the open one's light, its height
    PT mn_drop, 3                       ; a menu: under the bar,
    PT mn_pad, 5                        ; inside it, top and bottom
    PT mn_row, 22                       ; an item,
    PT mn_sep, 11                       ; a line,
    PT mn_r, 10                         ; its corners (the windows' shadow's)
    PT mn_hr, 5                         ; the chosen item's
    PT mn_tick, 9                       ; a tick's left
    PT mn_tx, 24                        ; the labels'
    PT mn_key_gap, 32                   ; from a label to its key
    PT mn_right, 14                     ; the keys' right
    PT mn_min, 180                      ; at least this wide
    PT mn_find_w, 280                   ; the launcher
    PT mn_label_max, 320                ; a label, at most (a window's title)
    PT st_gap, 16                       ; between what is at the bar's right
    pop rdi
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The bar: its titles and what is at its right
; -----------------------------------------------------------------------------

; bar_layout: where each title and what is at the right are (bt_x, bt_w;
; 0 wide: not there); the time made (bar_clock), the battery read.
; Preserves RBX, RBP, R12-R15.
bar_layout:
    push rbx
    push r12
    push r13
    mov r13, [mb_hp]
    mov rax, [m_bar_pad]                ; the mark
    sub rax, r13
    jns .mark
    xor eax, eax
.mark:
    mov [bt_x], rax
    mov rcx, [m_bar_pad]
    add rcx, [m_mark]
    add rcx, r13
    sub rcx, rax
    mov [bt_w], rcx
    lea r12, [rax + rcx]                ; R12: the next one's left
    call bar_app_name                   ; the app's name, in semibold
    mov rdi, rax
    mov esi, [f_title]
    call uf_width
    lea rax, [rax + r13 * 2]
    mov [bt_x + BT_APP * 8], r12
    mov [bt_w + BT_APP * 8], rax
    add r12, rax
    mov ebx, BT_FILE                    ; then the menus'
.title:
    lea rax, [bt_labels]
    mov rdi, [rax + rbx * 8]
    mov esi, [f_body]
    call uf_width
    lea rax, [rax + r13 * 2]
    lea rcx, [bt_x]
    mov [rcx + rbx * 8], r12
    lea rcx, [bt_w]
    mov [rcx + rbx * 8], rax
    add r12, rax
    inc ebx
    cmp ebx, BT_TITLES
    jb .title
    call bar_clock                      ; at the right: the time,
    lea rdi, [bar_clock_text]
    mov esi, [f_body]
    call uf_width
    mov r12, [scr_w]
    sub r12, [m_bar_pad]
    sub r12, rax
    mov [bar_clock_x], r12
    mov edi, 15                         ; then the magnifier,
    call pt
    mov ebx, BT_SEARCH
    call .place
    mov edi, 17                         ; the network,
    call pt
    mov ebx, BT_NET
    call .place
    call bat_info                       ; the battery, if there is one
    mov [st_bat], rax
    cmp rax, E_EMPTY
    je .no_battery
    movzx eax, al
    lea rdi, [st_buf]
    SPRINTF rdi, "%u%%", rax
    lea rdi, [st_buf]
    mov esi, [f_body]
    call uf_width
    mov rbx, rax
    mov edi, ST_BAT_ALL + 5
    call pt
    add rax, rbx
    mov ebx, BT_BATTERY
    call .place
    jmp .out
.no_battery:
    mov qword [bt_w + BT_BATTERY * 8], 0
.out:
    pop r13
    pop r12
    pop rbx
    ret
; RAX = what is there, how wide; EBX = which: left of R12, a gap away
.place:
    sub r12, [st_gap]
    sub r12, rax
    mov rcx, r12
    sub rcx, r13
    lea rdx, [bt_x]
    mov [rdx + rbx * 8], rcx
    lea rax, [rax + r13 * 2]
    lea rdx, [bt_w]
    mov [rdx + rbx * 8], rax
    ret

; bar_at(RDI = x on the bar) -> RAX = the title or what is at the right
; there (BT_*), CF if none. Preserves others.
bar_at:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    push rdi
    call bar_layout
    pop rdi
    xor ecx, ecx
.each:
    cmp ecx, BT_ALL
    jae .none
    cmp ecx, BT_APP
    je .next
    lea rax, [bt_w]
    mov rdx, [rax + rcx * 8]
    test rdx, rdx
    jz .next
    lea rax, [bt_x]
    mov rax, [rax + rcx * 8]
    cmp rdi, rax
    jl .next
    add rax, rdx
    cmp rdi, rax
    jl .found
.next:
    inc ecx
    jmp .each
.found:
    mov eax, ecx
    clc
    jmp .out
.none:
    stc
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; bt_paint(R13 = the baseline): the open menu's title lit, the app's name,
; the titles. From bar_paint, after bar_layout. Preserves RBX, RBP, R12-R15.
bt_paint:
    push rbx
    mov rax, [mn_which]                 ; the open one, lit
    cmp rax, -1
    je .names
    lea rcx, [bt_x]
    mov rdi, [rcx + rax * 8]
    lea rcx, [bt_w]
    mov rdx, [rcx + rax * 8]
    mov rcx, [mb_pill]
    mov rsi, [m_bar_h]
    sub rsi, rcx
    sar rsi, 1
    mov r8d, [th_c + TC_HOVER]
    mov r9d, [th_c + TC_HOVER_A]
    add r9d, r9d
    mov r10, [mn_hr]
    mov r11d, RC_ALL
    call gfx_rrect
.names:
    call bar_app_name
    mov rdx, rax
    mov rdi, [bt_x + BT_APP * 8]
    add rdi, [mb_hp]
    mov rsi, r13
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_title]
    call uf_text
    mov ebx, BT_FILE
.title:
    lea rax, [bt_x]
    mov rdi, [rax + rbx * 8]
    add rdi, [mb_hp]
    lea rax, [bt_labels]
    mov rdx, [rax + rbx * 8]
    mov rsi, r13
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_body]
    call uf_text
    inc ebx
    cmp ebx, BT_TITLES
    jb .title
    pop rbx
    ret

; st_paint(R13 = the baseline): the battery, the network, the magnifier.
; After bar_layout. Preserves RBX, RBP, R12-R15.
st_paint:
    push rbx
    push r12
    mov rax, [bt_w + BT_BATTERY * 8]    ; the battery: the icon at the right,
    test rax, rax
    jz .net
    mov r12, [bt_x + BT_BATTERY * 8]
    add r12, rax
    sub r12, [mb_hp]
    mov edi, ST_BAT_ALL
    call pt
    sub r12, rax
    mov edi, ST_BAT_H
    call pt
    mov rsi, [m_bar_h]
    sub rsi, rax
    sar rsi, 1
    mov rdi, r12
    call st_battery
    movzx eax, byte [st_bat]            ; its percent before it
    lea rdi, [st_buf]
    SPRINTF rdi, "%u%%", rax
    lea rdi, [st_buf]
    mov esi, [f_body]
    call uf_width
    mov rbx, rax
    mov edi, 5
    call pt
    mov rdi, r12
    sub rdi, rax
    sub rdi, rbx
    mov rsi, r13
    lea rdx, [st_buf]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_body]
    call uf_text
.net:
    mov edi, 12                         ; the network: a fan, or a cable's sign
    call pt
    mov rdx, [m_bar_h]
    sub rdx, rax
    sar rdx, 1
    mov rdi, [bt_x + BT_NET * 8]
    add rdi, [mb_hp]
    call st_net
    lea rsi, [st_fan]
    cmp eax, NET_WIRE_OFF
    jb .sign
    lea rsi, [st_wire]
.sign:
    mov ecx, [th_c + TC_TEXT]
    mov r8d, 256
    cmp eax, NET_WIFI
    je .shape
    cmp eax, NET_WIRE
    je .shape
    mov r8d, 80                         ; off a network: dim
.shape:
    call st_shapes
    mov edi, 15                         ; the magnifier
    call pt
    mov rdx, [m_bar_h]
    sub rdx, rax
    sar rdx, 1
    mov rdi, [bt_x + BT_SEARCH * 8]
    add rdi, [mb_hp]
    lea rsi, [st_lens]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, 256
    call st_shapes
    pop r12
    pop rbx
    ret

; st_battery(RDI x, RSI y = its top left): the battery as [st_bat] says:
; an outline, filled as far as it is charged, a tip, a bolt on its charger
st_battery:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov edi, ST_BAT_W
    call pt
    mov r14, rax                        ; R14, R15: its body
    mov edi, ST_BAT_H
    call pt
    mov r15, rax
    mov edi, 7                          ; corners of 3.5 points
    call pt
    shr rax, 1
    mov r10, rax
    mov edi, 1                          ; the outline: a point thick
    call pt
    mov rbx, rax
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r8d, [th_c + TC_TEXT]
    mov r9d, ST_LINE_A
.line:
    call gfx_rring
    inc rdi
    inc rsi
    sub rdx, 2
    sub rcx, 2
    dec r10
    jns .r_ok
    xor r10d, r10d
.r_ok:
    dec rbx
    jnz .line
    mov edi, 3                          ; its tip: 1.5 points by 4, a point
    call pt                             ; past the body
    shr rax, 1
    jnz .tip_w
    inc eax
.tip_w:
    mov rdx, rax
    mov edi, 4
    call pt
    mov rcx, rax
    mov rsi, r15
    sub rsi, rcx
    sar rsi, 1
    add rsi, r13
    mov edi, 1
    call pt
    lea rdi, [r12 + r14]
    add rdi, rax
    mov r8d, [th_c + TC_TEXT]
    mov r9d, ST_LINE_A
    mov r10, rdx
    mov r11d, RC_TR | RC_BR
    call gfx_rrect
    mov edi, 2                          ; the charge, two points in
    call pt
    mov rbx, rax
    lea rdi, [r12 + rbx]
    lea rsi, [r13 + rbx]
    mov rdx, r14
    sub rdx, rbx
    sub rdx, rbx
    mov rcx, r15
    sub rcx, rbx
    sub rcx, rbx
    movzx eax, byte [st_bat]
    cmp eax, 100
    jbe .level
    mov eax, 100
.level:
    imul rax, rdx                       ; as wide as it is charged
    xor edx, edx
    mov r8d, 100
    div r8
    mov rdx, rax
    test rdx, rdx
    jz .bolt
    mov r8d, [th_c + TC_T_GOOD]         ; green on its charger, red when low
    test dword [st_bat], SI_BAT_PLUGGED
    jnz .fill
    mov r8d, [th_c + TC_T_BAD]
    cmp byte [st_bat], 15
    jbe .fill
    mov r8d, [th_c + TC_TEXT]
.fill:
    mov edi, 3                          ; corners of 1.5 points
    call pt
    shr rax, 1
    mov r10, rax
    mov r9d, 256
    mov r11d, RC_ALL
    lea rdi, [r12 + rbx]
    call gfx_rrect
.bolt:
    test dword [st_bat], SI_BAT_PLUGGED
    jz .out
    mov rdi, r12
    mov rdx, r13
    lea rsi, [st_bolt]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, 256
    call st_shapes
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; st_shapes(RSI = a list of shapes, RDI x, RDX y = its top left, ECX =
; color, R8D = alpha): each filled. A list: dw how many, then each: dw its
; points, then each point dw x, y in 1/32 points. Preserves all.
st_shapes:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    push r12
    mov r12d, ecx
    movzx r11d, word [rsi]              ; R11: shapes left
    add rsi, 2
    mov r10d, [ui_s4]                   ; 1/32 point -> 1/256 pixel
    add r10d, r10d
    shl rdi, 8
    shl rdx, 8
.shape:
    test r11d, r11d
    jz .out
    movzx r9d, word [rsi]               ; its points
    add rsi, 2
    lea rbx, [st_pts]
    mov ecx, r9d
.point:
    movsx eax, word [rsi]
    imul eax, r10d
    add eax, edi
    mov [rbx], eax
    movsx eax, word [rsi + 2]
    imul eax, r10d
    add eax, edx
    mov [rbx + 4], eax
    add rsi, 4
    add rbx, 8
    dec ecx
    jnz .point
    push rsi
    push rdi
    push rdx
    lea rdi, [st_pts]
    mov esi, r9d
    mov edx, r12d
    mov ecx, r8d
    call gfx_poly
    pop rdx
    pop rdi
    pop rsi
    dec r11d
    jmp .shape
.out:
    pop r12
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; st_net -> EAX = NET_*: the network, as the bar shows it. Preserves others.
st_net:
    push rcx
    mov rcx, [rtw_nic]                  ; Wi-Fi, if there is its card
    test rcx, rcx
    jz .wire
    mov eax, NET_WIFI_OFF
    cmp byte [rtw_js], JS_LINKED
    jne .out
    mov eax, NET_WIFI
    jmp .out
.wire:
    mov rcx, [net_nic]                  ; else the interface with the address
    mov eax, NET_NONE
    test rcx, rcx
    jz .out
    mov eax, NET_WIRE_OFF
    cmp dword [rcx + NI_SPEED], 0
    jle .out
    mov eax, NET_WIRE
.out:
    pop rcx
    ret

; st_tick: from desk_tick: the bar again when the battery or the network
; changed. Preserves all.
st_tick:
    push rax
    push rcx
    push rdx
    call uptime_ms
    cmp rax, [st_due]
    jb .out
    add rax, ST_EVERY_MS
    mov [st_due], rax
    call bat_info
    mov rcx, rax
    call st_net
    shl rax, 56
    xor rcx, rax
    cmp rcx, [st_seen]
    je .out
    mov [st_seen], rcx
    call desk_bar_damage
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The open menu
; -----------------------------------------------------------------------------

; mn_open(RAX = BT_*): its menu, under it (another that was open, closed).
; Preserves RBX, RBP, R12-R15.
mn_open:
    push rbx
    mov rbx, rax
    call mn_damage                      ; where the last one was
    mov [mn_which], rbx
    mov rax, [ptr_x]                    ; the pointer as it is: not moved
    mov [mn_px], rax
    mov rax, [ptr_y]
    mov [mn_py], rax
    cmp rbx, BT_SEARCH
    jne .fill
    mov qword [mn_query_n], 0
    mov byte [mn_query], 0
.fill:
    call bar_layout
    call mn_fill
    call mn_measure
    mov qword [mn_hot], -1
    cmp rbx, BT_SEARCH                  ; the launcher: its first, chosen
    jne .shown
    mov rdx, 1
    call mn_step
.shown:
    call mn_damage
    call desk_bar_damage
    pop rbx
    ret

; mn_close_fade: the open menu closed, fading away. Preserves all.
mn_close_fade:
    cmp qword [mn_which], -1
    je .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    call mn_area                        ; as it is on the screen, below the
    mov rax, [m_bar_h]                  ; bar (which changes at once)
    cmp rsi, rax
    jge .below
    add rcx, rsi
    sub rcx, rax
    mov rsi, rax
.below:
    call mv_fade
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    call mn_close
.out:
    ret

; mn_close: the open menu, closed. Preserves all.
mn_close:
    cmp qword [mn_which], -1
    je .out
    call mn_damage
    mov qword [mn_which], -1
    mov qword [mn_gl + GL_W], 0         ; no glass
    mov dword [mn_gl + GL_STALE], 0
    call desk_bar_damage
.out:
    ret

; mn_refill: what the launcher shows, again (what is typed changed)
mn_refill:
    call mn_damage
    call mn_fill
    call mn_measure
    mov qword [mn_hot], -1
    mov rdx, 1
    call mn_step
    jmp mn_damage

; mn_do(RAX = an item): chosen: it blinks (mn_motion), then the menu
; closes and the item does what it does
mn_do:
    call mv_on
    jz mn_done
    mov [mn_blink], rax
    mov qword [mn_hot], -1
    push rax
    RDTSC64
    mov [mn_blink_t0], rax
    pop rax
    call mn_damage
    jmp mv_kick

; mn_done(RAX = an item): the menu closed, fading; then what the item does
mn_done:
    mov qword [mn_blink], -1
    imul rax, rax, MI_SIZE
    lea rcx, [mn_items]
    add rax, rcx
    mov rcx, [rax + MI_DO]
    mov rdi, [rax + MI_ARG]
    call mn_close_fade
    test rcx, rcx
    jz .out
    jmp rcx
.out:
    ret

; mn_motion -> EAX = 1 while an item chosen blinks: off a moment, on a
; moment, then done (motion_service's step)
mn_motion:
    mov rax, [mn_blink]
    cmp rax, -1
    je .still
    mov rax, [mv_now]
    sub rax, [mn_blink_t0]
    xor edx, edx
    div qword [tsc_per_ms]
    mov ecx, [mv_scale]
    imul ecx, ecx, MN_BLINK_MS
    jecxz .done                         ; (motion turned off)
    xor edx, edx
    div rcx                             ; RAX: the phase
    cmp rax, 2
    jae .done
    mov rdx, -1                         ; off, then on
    test rax, rax
    jz .hot
    mov rdx, [mn_blink]
.hot:
    cmp rdx, [mn_hot]
    je .going
    mov [mn_hot], rdx
    call mn_damage
.going:
    mov eax, 1
    ret
.done:
    mov rax, [mn_blink]
    mov [mn_hot], rax
    push rbx
    call mn_done
    pop rbx
.still:
    xor eax, eax
    ret

; mn_blinking -> CF if an item chosen blinks still: then it is done at
; once (the keys and the pointer are for what comes after). Preserves all.
mn_blinking:
    cmp qword [mn_blink], -1
    je .no
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rax, [mn_blink]
    call mn_done
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.no:
    ret

; mn_usable(RAX = an item) -> CF if it may not be chosen: a line, a note,
; or off now. Preserves all.
mn_usable:
    push rax
    push rcx
    push rdx
    push rdi
    imul rax, rax, MI_SIZE
    lea rcx, [mn_items]
    add rax, rcx
    cmp qword [rax + MI_LABEL], 0
    je .no
    cmp qword [rax + MI_DO], 0
    je .no
    mov rcx, [rax + MI_STATE]
    test rcx, rcx
    jz .yes
    mov rdi, [rax + MI_ARG]
    call rcx
    test eax, MS_OFF
    jnz .no
.yes:
    clc
    jmp .out
.no:
    stc
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; mn_step(RDX = +1 or -1): the next item that may be chosen, that way, round
; the end
mn_step:
    push rbx
    mov rbx, [mn_n]
    test rbx, rbx
    jz .out
    mov rax, [mn_hot]
.next:
    add rax, rdx
    jns .low
    mov rax, [mn_n]
    dec rax
.low:
    cmp rax, [mn_n]
    jb .high
    xor eax, eax
.high:
    call mn_usable
    jnc .found
    dec rbx
    jnz .next
    jmp .out
.found:
    mov [mn_hot], rax
    call mn_damage
.out:
    pop rbx
    ret

; mn_beside(RDX = +1 or -1): the title's menu that way, round the end
mn_beside:
    mov rax, [mn_which]
    cmp rax, BT_TITLES
    jae .out
.again:
    add rax, rdx
    jns .low
    mov eax, BT_TITLES - 1
.low:
    cmp rax, BT_TITLES
    jb .high
    mov eax, BT_MARK
.high:
    cmp rax, BT_APP
    je .again
    jmp mn_open
.out:
    ret

; -----------------------------------------------------------------------------
;  Its items
; -----------------------------------------------------------------------------

; mn_fill: mn_items and mn_n for [mn_which]
mn_fill:
    push rbx
    push r12
    mov qword [mn_n], 0
    mov qword [mn_text_n], 0
    mov rax, [mn_which]
    cmp rax, BT_BATTERY
    je .battery
    cmp rax, BT_NET
    je .net
    cmp rax, BT_SEARCH
    je .search
    lea rcx, [bt_menus]
    mov rsi, [rcx + rax * 8]
    call mn_copy
    cmp qword [mn_which], BT_WINDOW
    jne .out
    xor ebx, ebx                        ; the Window menu: each window
.win:
    lea rax, [desk_wins]
    mov r12, [rax + rbx * 8]
    test r12, r12
    jz .next
    test dword [r12 + WN_FLAGS], WF_CLOSING
    jnz .next
    lea rsi, [r12 + WN_TITLE]
    lea rdx, [mn_window]
    mov rcx, r12
    xor r8d, r8d
    lea r9, [ms_window]
    call mn_add
.next:
    inc ebx
    cmp ebx, DESK_MAX
    jb .win
    jmp .out
.battery:
    call mn_fill_battery
    jmp .out
.net:
    call mn_fill_net
    jmp .out
.search:
    call mn_fill_search
.out:
    pop r12
    pop rbx
    ret

; mn_add(RSI = label, RDX = what it does, RCX = with what, R8 = key, R9 =
; state): an item more. Preserves all.
mn_add:
    push rax
    push rdi
    mov rax, [mn_n]
    cmp rax, MN_MAX
    jae .out
    imul rdi, rax, MI_SIZE
    lea rax, [mn_items]
    add rdi, rax
    mov [rdi + MI_LABEL], rsi
    mov [rdi + MI_DO], rdx
    mov [rdi + MI_ARG], rcx
    mov [rdi + MI_KEY], r8
    mov [rdi + MI_STATE], r9
    inc qword [mn_n]
.out:
    pop rdi
    pop rax
    ret

; mn_note(RSI = text): a line that says something. Preserves all.
mn_note:
    push rdx
    push rcx
    push r8
    push r9
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call mn_add
    pop r9
    pop r8
    pop rcx
    pop rdx
    ret

; mn_line: a line between items. Preserves all.
mn_line:
    push rsi
    xor esi, esi
    call mn_note
    pop rsi
    ret

; mn_copy(RSI = a menu's table): its items
mn_copy:
.each:
    cmp qword [rsi], -1
    je .out
    push rsi
    mov rdx, [rsi + MI_DO]
    mov rcx, [rsi + MI_ARG]
    mov r8, [rsi + MI_KEY]
    mov r9, [rsi + MI_STATE]
    mov rsi, [rsi + MI_LABEL]
    call mn_add
    pop rsi
    add rsi, MI_SIZE
    jmp .each
.out:
    ret

; mn_text_at -> RDI = where the next label made goes. Preserves others.
mn_text_at:
    lea rdi, [mn_text]
    add rdi, [mn_text_n]
    ret

; mn_text_made(RAX = its length): past it. Preserves all.
mn_text_made:
    push rax
    inc rax
    add [mn_text_n], rax
    pop rax
    ret

; the battery's menu: how charged, on what, then System
mn_fill_battery:
    push r12
    push r13
    call bat_info
    mov r13, rax
    lea rsi, [str_mn_no_battery]
    cmp rax, E_EMPTY
    je .said
    movzx eax, r13b
    call mn_text_at
    mov r12, rdi
    SPRINTF rdi, "Battery %u%%", rax
    call mn_text_made
    mov rsi, r12
    call mn_note
    lea rsi, [str_mn_on_battery]
    test r13d, SI_BAT_PLUGGED
    jz .said
    lea rsi, [str_mn_charger]
    test r13d, SI_BAT_HELD
    jz .said
    lea rsi, [str_mn_held]
.said:
    call mn_note
    call mn_line
    lea rsi, [str_mn_system]
    lea rdx, [mn_app]
    mov ecx, APP_SYSTEM
    xor r8d, r8d
    xor r9d, r9d
    call mn_add
    pop r13
    pop r12
    ret

; the network's: what it is on, its address, then 'net' in a terminal
mn_fill_net:
    push r12
    call st_net
    lea rcx, [mn_net_says]
    mov rsi, [rcx + rax * 8]
    cmp eax, NET_WIRE
    jne .said
    mov rax, [net_nic]
    mov eax, [rax + NI_SPEED]
    call mn_text_at
    mov r12, rdi
    SPRINTF rdi, "Wired, %u Mbit/s", rax
    call mn_text_made
    mov rsi, r12
.said:
    call mn_note
    mov eax, [net_ip]
    test eax, eax
    jz .more
    call mn_text_at
    mov r12, rdi
    SPRINTF rdi, "Address %I", rax
    call mn_text_made
    mov rsi, r12
    call mn_note
.more:
    call mn_line
    lea rsi, [str_mn_net_more]
    lea rdx, [mn_run]
    lea rcx, [str_mn_cmd_net]
    xor r8d, r8d
    xor r9d, r9d
    call mn_add
    pop r12
    ret

; the launcher's: each app whose name has what is typed in it; then what
; is typed, to run
mn_fill_search:
    push rbx
    push r12
    xor ebx, ebx
.app:
    imul rax, rbx, DA_SIZE
    lea rcx, [dock_apps]
    mov rsi, [rcx + rax + DA_LABEL]
    lea rdi, [mn_query]
    call str_has
    jc .next
    lea rdx, [mn_app]
    mov ecx, ebx
    xor r8d, r8d
    xor r9d, r9d
    call mn_add
.next:
    inc ebx
    cmp ebx, DOCK_APPS
    jb .app
    cmp qword [mn_query_n], 0
    je .out
    cmp qword [mn_n], 0
    je .run
    call mn_line
.run:
    call mn_text_at
    mov r12, rdi
    lea rax, [mn_query]
    SPRINTF rdi, "Run '%s' in a terminal", rax
    call mn_text_made
    mov rsi, r12
    lea rdx, [mn_run]
    lea rcx, [mn_query]
    xor r8d, r8d
    xor r9d, r9d
    call mn_add
.out:
    pop r12
    pop rbx
    ret

; str_has(RSI = text, RDI = what) -> CF if it is not in it, as letters of
; either case. Preserves all.
str_has:
    push rax
    push rcx
    push rdx
    push rsi
.from:
    xor ecx, ecx
.same:
    movzx eax, byte [rdi + rcx]
    test eax, eax
    jz .yes
    movzx edx, byte [rsi + rcx]
    test edx, edx
    jz .no
    cmp al, 'A'
    jb .a
    cmp al, 'Z'
    ja .a
    add al, 32
.a:
    cmp dl, 'A'
    jb .d
    cmp dl, 'Z'
    ja .d
    add dl, 32
.d:
    cmp eax, edx
    jne .on
    inc ecx
    jmp .same
.on:
    inc rsi
    cmp byte [rsi - 1], 0
    jne .from
.no:
    stc
    jmp .out
.yes:
    clc
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; mn_measure: the open menu's size and place
mn_measure:
    push rbx
    push r12
    push r13
    xor r12d, r12d                      ; the widest
    xor r13d, r13d                      ; how high
    xor ebx, ebx
.each:
    cmp rbx, [mn_n]
    jae .sized
    imul rsi, rbx, MI_SIZE
    lea rax, [mn_items]
    add rsi, rax
    mov rdi, [rsi + MI_LABEL]
    test rdi, rdi
    jnz .item
    add r13, [mn_sep]
    jmp .next
.item:
    add r13, [mn_row]
    push rsi
    mov esi, [f_body]
    call uf_width
    pop rsi
    cmp rax, [mn_label_max]
    jbe .label
    mov rax, [mn_label_max]
.label:
    mov rcx, rax
    mov rdi, [rsi + MI_KEY]
    test rdi, rdi
    jz .wide
    push rcx
    mov esi, [f_body]
    call uf_width
    pop rcx
    add rcx, rax
    add rcx, [mn_key_gap]
.wide:
    cmp rcx, r12
    jbe .next
    mov r12, rcx
.next:
    inc rbx
    jmp .each
.sized:
    add r12, [mn_tx]
    add r12, [mn_right]
    mov rax, [mn_min]
    cmp qword [mn_which], BT_SEARCH
    jne .least
    mov rax, [mn_find_w]                ; the launcher: its question too
    add r13, [mn_row]
    add r13, [mn_sep]
.least:
    cmp r12, rax
    jae .w
    mov r12, rax
.w:
    add r13, [mn_pad]
    add r13, [mn_pad]
    mov [mn_w], r12
    mov [mn_h], r13
    mov rax, [mn_which]                 ; under its title; under what is at
    lea rcx, [bt_x]                     ; the right, by its right
    mov rdi, [rcx + rax * 8]
    cmp rax, BT_TITLES
    jb .x
    lea rcx, [bt_w]
    add rdi, [rcx + rax * 8]
    sub rdi, r12
.x:
    mov rax, [scr_w]                    ; on the screen
    sub rax, r12
    sub rax, [mn_pad]
    cmp rdi, rax
    jle .x1
    mov rdi, rax
.x1:
    cmp rdi, [mn_pad]
    jge .x0
    mov rdi, [mn_pad]
.x0:
    mov [mn_x], rdi
    mov rax, [m_bar_h]
    add rax, [mn_drop]
    mov [mn_y], rax
    lea rax, [mn_gl]                    ; its glass, made again
    mov [rax + GL_X], rdi
    mov rcx, [mn_y]
    mov [rax + GL_Y], rcx
    mov [rax + GL_W], r12
    mov [rax + GL_H], r13
    mov rcx, [m_blur]
    mov [rax + GL_B], rcx
    lea rcx, [rcx + rcx * 2]            ; what it reads: three blurs around,
    mov rdi, [sh_other + SH_M]          ; and its shadow
    add rdi, [sh_other + SH_OY]
    cmp rcx, rdi
    jge .reach
    mov rcx, rdi
.reach:
    mov [rax + GL_M], rcx
    mov byte [rax + GL_STALE], 1
    pop r13
    pop r12
    pop rbx
    ret

; mn_top -> RAX = the first item's top. Preserves others.
mn_top:
    mov rax, [mn_y]
    add rax, [mn_pad]
    cmp qword [mn_which], BT_SEARCH
    jne .out
    add rax, [mn_row]
    add rax, [mn_sep]
.out:
    ret

; mn_inside(RDI x, RSI y) -> CF if outside the open menu. Preserves all.
mn_inside:
    push rax
    cmp qword [mn_which], -1
    je .no
    mov rax, [mn_x]
    cmp rdi, rax
    jl .no
    add rax, [mn_w]
    cmp rdi, rax
    jge .no
    mov rax, [mn_y]
    cmp rsi, rax
    jl .no
    add rax, [mn_h]
    cmp rsi, rax
    jge .no
    clc
    pop rax
    ret
.no:
    stc
    pop rax
    ret

; mn_at(RDI x, RSI y) -> RAX = the item there that may be chosen, CF if
; none. Preserves others.
mn_at:
    call mn_inside
    jc .out
    push rbx
    push rcx
    push rdx
    call mn_top
    mov rdx, rax                        ; RDX: this one's top
    xor ebx, ebx
.each:
    cmp rbx, [mn_n]
    jae .none
    imul rax, rbx, MI_SIZE
    lea rcx, [mn_items]
    mov rcx, [rcx + rax + MI_LABEL]
    mov rax, [mn_sep]
    test rcx, rcx
    jz .high
    mov rax, [mn_row]
.high:
    add rax, rdx
    cmp rsi, rdx
    jl .none
    cmp rsi, rax
    jl .found
    mov rdx, rax
    inc rbx
    jmp .each
.found:
    mov rax, rbx
    call mn_usable
    jmp .done
.none:
    stc
.done:
    pop rdx
    pop rcx
    pop rbx
.out:
    ret

; -----------------------------------------------------------------------------
;  Showing it
; -----------------------------------------------------------------------------

; mn_area -> RDI, RSI, RDX, RCX: the open menu with its shadow. Preserves
; others.
mn_area:
    push rax
    mov rax, [sh_other + SH_M]
    mov rdi, [mn_x]
    sub rdi, rax
    mov rsi, [mn_y]
    sub rsi, rax
    mov rdx, [mn_w]
    lea rdx, [rdx + rax * 2]
    mov rcx, [mn_h]
    lea rcx, [rcx + rax * 2]
    add rcx, [sh_other + SH_OY]
    pop rax
    ret

; mn_damage: the open menu's place, to be composed again. Preserves all.
mn_damage:
    cmp qword [mn_which], -1
    je .out
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    call mn_area
    lea r8, [mn_gl]                     ; its own: its glass is as it was
    call desk_damage_own
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
.out:
    ret

; mn_paint: the open menu, where the clip meets it (desk_compose, last):
; its shadow, its glass, its items. Preserves RBX, RBP, R12-R15.
mn_paint:
    cmp qword [mn_which], -1
    jne .some
    ret
.some:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call mn_area                        ; does the clip meet it?
    lea rax, [rdi + rdx]
    cmp rax, [tg_cx0]
    jle .out
    cmp rdi, [tg_cx1]
    jge .out
    lea rax, [rsi + rcx]
    cmp rax, [tg_cy0]
    jle .out
    cmp rsi, [tg_cy1]
    jge .out
    mov rdi, [mn_x]
    mov rsi, [mn_y]
    mov rdx, [mn_w]
    mov rcx, [mn_h]
    lea r8, [sh_other]
    call gfx_shadow
    lea rax, [mn_gl]
    mov r10, [mn_r]
    call glass_paint
    mov r8d, [th_c + TC_TIP]
    mov r9d, [th_c + TC_TIP_A]
    sub r9d, 45
    mov r10, [mn_r]
    mov r11d, RC_ALL
    call gfx_rrect
    mov r8d, [th_c + TC_DOCK_EDGE]
    mov r9d, [th_c + TC_DOCK_EDGE_A]
    call gfx_rring
    mov edi, [f_body]                   ; R15: a row's baseline, from its top
    call uf_metrics
    mov eax, [rax + UFT_CAP]
    add rax, [mn_row]
    shr rax, 1
    mov r15, rax
    mov r13, [mn_y]                     ; R13: this row's top
    add r13, [mn_pad]
    cmp qword [mn_which], BT_SEARCH
    jne .rows
    call mn_paint_query
    add r13, [mn_row]
    call mn_paint_line
    add r13, [mn_sep]
.rows:
    xor ebx, ebx
.row:
    cmp rbx, [mn_n]
    jae .out
    imul r12, rbx, MI_SIZE
    lea rax, [mn_items]
    add r12, rax
    cmp qword [r12 + MI_LABEL], 0
    jne .item
    call mn_paint_line
    add r13, [mn_sep]
    jmp .next
.item:
    xor r14d, r14d                      ; R14: its state
    mov rax, [r12 + MI_STATE]
    test rax, rax
    jz .stated
    mov rdi, [r12 + MI_ARG]
    call rax
    mov r14d, eax
.stated:
    mov ecx, [th_c + TC_TEXT2]          ; a note
    cmp qword [r12 + MI_DO], 0
    je .ink
    mov ecx, [th_c + TC_TEXT3]          ; off now
    test r14d, MS_OFF
    jnz .ink
    mov ecx, [th_c + TC_TEXT]
    cmp rbx, [mn_hot]
    jne .ink
    mov rdi, [mn_x]                     ; the chosen one: on the accent
    add rdi, [mn_pad]
    mov rsi, r13
    mov rdx, [mn_w]
    sub rdx, [mn_pad]
    sub rdx, [mn_pad]
    mov rcx, [mn_row]
    mov r8d, [th_accent]
    mov r9d, 256
    mov r10, [mn_hr]
    mov r11d, RC_ALL
    call gfx_rrect
    mov ecx, 0xFFFFFF
.ink:
    mov [mn_ink], ecx
    lea rsi, [r13 + r15]
    test r14d, MS_CHECK
    jz .label
    mov rdi, [mn_x]
    add rdi, [mn_tick]
    lea rdx, [str_mn_tick]
    mov r8d, [f_body]
    call uf_text
.label:
    mov rdi, [mn_x]
    add rdi, [mn_tx]
    mov rdx, [r12 + MI_LABEL]
    mov r8d, [f_body]
    mov r9, [mn_label_max]
    call uf_text_max
    mov rdi, [r12 + MI_KEY]             ; its key, at the right
    test rdi, rdi
    jz .done
    push rsi
    mov esi, [f_body]
    call uf_width
    pop rsi
    mov rdi, [mn_x]
    add rdi, [mn_w]
    sub rdi, [mn_right]
    sub rdi, rax
    mov rdx, [r12 + MI_KEY]
    mov ecx, [mn_ink]
    cmp rbx, [mn_hot]
    je .key
    test r14d, MS_OFF
    jnz .key
    mov ecx, [th_c + TC_TEXT2]
.key:
    call uf_text
.done:
    add r13, [mn_row]
.next:
    inc rbx
    jmp .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; mn_paint_line(R13 = its row's top): a line across the menu, in the middle
mn_paint_line:
    mov rdi, [mn_x]
    add rdi, [mn_pad]
    add rdi, [mn_pad]
    mov rsi, [mn_sep]
    shr rsi, 1
    add rsi, r13
    mov rdx, [mn_w]
    sub rdx, [mn_pad]
    sub rdx, [mn_pad]
    sub rdx, [mn_pad]
    sub rdx, [mn_pad]
    mov ecx, 1
    mov r8d, [th_c + TC_TEXT]
    mov r9d, 40
    xor r10d, r10d
    mov r11d, RC_ALL
    jmp gfx_rrect

; mn_paint_query(R13 = its top, R15 = a row's baseline): the launcher's
; question: a magnifier, what is typed (or what to type) and the caret
mn_paint_query:
    mov edi, 15
    call pt
    mov rdx, [mn_row]
    sub rdx, rax
    sar rdx, 1
    add rdx, r13
    mov rdi, [mn_x]
    add rdi, [mn_tick]
    lea rsi, [st_lens]
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, 256
    call st_shapes
    mov rdi, [mn_x]
    add rdi, [mn_tx]
    add rdi, [mn_pad]
    lea rsi, [r13 + r15]
    lea rdx, [mn_query]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_body]
    cmp qword [mn_query_n], 0
    jne .typed
    push rdi                            ; nothing yet: what it is for, dim
    lea rdx, [str_mn_find]
    mov ecx, [th_c + TC_TEXT3]
    call uf_text
    pop rax
    jmp .caret
.typed:
    call uf_text
.caret:
    push rax                            ; the caret, after what is typed: a
    mov edi, 4                          ; point wide, four in from the row's
    call pt                             ; top and bottom
    lea rsi, [r13 + rax]
    mov rcx, [mn_row]
    sub rcx, rax
    sub rcx, rax
    mov edi, 1
    call pt
    mov rdx, rax
    pop rdi
    add rdi, rdx
    mov r8d, [th_accent]
    mov r9d, 256
    xor r10d, r10d
    mov r11d, RC_ALL
    jmp gfx_rrect

; -----------------------------------------------------------------------------
;  The pointer and the keys (from desk.asm's)
; -----------------------------------------------------------------------------

; mn_press: a button pressed at the pointer -> CF if it was the menus':
; on the bar, a title opens its menu (or closes it, open); in an open
; menu, nothing until it is let go; elsewhere an open menu closes.
mn_press:
    call mn_blinking
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    cmp rsi, [m_bar_h]
    jge .below
    call bar_at
    jc .bar
    cmp rax, [mn_which]
    jne .open
    call mn_close_fade
    stc
    ret
.open:
    call mn_open
    stc
    ret
.bar:
    call mn_close_fade
    stc
    ret
.below:
    cmp qword [mn_which], -1
    je .not
    call mn_inside
    jnc .ours
    call mn_close_fade
.ours:
    stc
    ret
.not:
    clc
    ret

; mn_release(EDX = the button): let go over an item of the open menu, it
; is done. Preserves RDX.
mn_release:
    cmp qword [mn_which], -1
    je .out
    cmp qword [mn_blink], -1            ; (chosen already)
    jne .out
    cmp edx, 1
    jne .out
    push rdx
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    call mn_at
    jc .none
    call mn_do
.none:
    pop rdx
.out:
    ret

; mn_hover: the pointer moved: with a menu open, another title opens its
; menu, and the item under it is chosen
mn_hover:
    cmp qword [mn_which], -1
    je .out
    cmp qword [mn_blink], -1            ; chosen: it blinks, as it is
    jne .out
    mov rdi, [ptr_x]
    mov rsi, [ptr_y]
    cmp rdi, [mn_px]                    ; only if it moved: a pointer left
    jne .moved                          ; where it was keeps the keys' choice
    cmp rsi, [mn_py]
    je .out
.moved:
    mov [mn_px], rdi
    mov [mn_py], rsi
    cmp rsi, [m_bar_h]
    jge .items
    call bar_at
    jc .out
    cmp rax, [mn_which]
    je .out
    jmp mn_open
.items:
    call mn_at
    jnc .hot
    mov rax, -1
.hot:
    cmp rax, [mn_hot]
    je .out
    mov [mn_hot], rax
    call mn_damage
.out:
    ret

; mn_key(EAX = key code): the open menu's: Esc, Enter, the arrows; the
; launcher's, what is typed too
mn_key:
    cmp qword [mn_blink], -1            ; one chosen blinks: done at once,
    je .keys                            ; and the key for what comes after
    call mn_blinking
    jmp desk_key
.keys:
    cmp eax, 27
    je mn_close_fade
    cmp eax, 10
    je .enter
    cmp eax, 13
    je .enter
    mov rdx, 1
    cmp eax, KEY_DOWN
    je mn_step
    cmp eax, KEY_RIGHT
    je mn_beside
    mov rdx, -1
    cmp eax, KEY_UP
    je mn_step
    cmp eax, KEY_LEFT
    je mn_beside
    cmp qword [mn_which], BT_SEARCH
    jne .out
    mov rcx, [mn_query_n]
    lea rdx, [mn_query]
    cmp eax, 8
    je .back
    cmp eax, 32
    jb .out
    cmp eax, 127
    jae .out
    cmp rcx, MN_QUERY - 1
    jae .out
    mov [rdx + rcx], al
    mov byte [rdx + rcx + 1], 0
    inc qword [mn_query_n]
    jmp mn_refill
.back:
    test rcx, rcx
    jz .out
    dec rcx
    mov [mn_query_n], rcx
    mov byte [rdx + rcx], 0
    jmp mn_refill
.enter:
    mov rax, [mn_hot]
    cmp rax, -1
    je .out
    call mn_usable
    jc .out
    jmp mn_do
.out:
    ret

; -----------------------------------------------------------------------------
;  What the items do (RDI = the item's MI_ARG), and their states
; -----------------------------------------------------------------------------

; an app: its windows forward, or it starts
mn_app:
    jmp app_open

; the launcher (Help's way to it, by the keys too)
mn_find:
    mov eax, BT_SEARCH
    jmp mn_open

; a new terminal
mn_terminal:
    jmp term_new

; a new terminal, the command RDI typed into it
mn_run:
    push rbx
    mov rbx, rdi
    call term_new
    mov rax, [desk_focus]
    test rax, rax
    jz .out
    lea rcx, [term_ops]
    cmp [rax + WN_OPS], rcx
    jne .out
.char:
    movzx eax, byte [rbx]
    test eax, eax
    jz .enter
    call desk_key
    inc rbx
    jmp .char
.enter:
    mov eax, 10
    call desk_key
.out:
    pop rbx
    ret

mn_restart:
    jmp cmd_reboot

mn_shut_down:
    jmp cmd_poweroff

; the window with the keys: closed (as its close button), minimised, zoomed
mn_close_window:
    mov rdi, [desk_focus]
    test rdi, rdi
    jz .out
    test dword [rdi + WN_FLAGS], WF_CLOSE
    jz .out
    call win_ask
.out:
    ret

mn_minimise:
    mov rdi, [desk_focus]
    test rdi, rdi
    jz .out
    call win_minimise
.out:
    ret

mn_zoom:
    mov rdi, [desk_focus]
    test rdi, rdi
    jz .out
    call win_zoom
.out:
    ret

mn_screen:
    mov rdi, [desk_focus]
    test rdi, rdi
    jz .out
    test dword [rdi + WN_FLAGS], WF_RESIZE
    jz .out
    jmp win_screen_flip
.out:
    ret

; a key to the window with the keys (Edit's)
mn_key_to:
    mov eax, edi
    jmp desk_key

; the light or the dark look
mn_look:
    mov [th_mode], dil
    jmp theme_apply

; the scale, a quarter of a pixel a point bigger (+1) or smaller (-1)
mn_scale:
    mov eax, [ui_s4]
    add eax, edi
    cmp eax, 4
    jl .out
    cmp eax, 8
    jg .out
    mov [ui_s4], eax
    jmp theme_apply
.out:
    ret

; the widgets, shown or not
mn_widgets:
    xor byte [wg_hidden], 1
    mov rdi, [wg_x]
    mov rsi, [wg_y]
    mov rdx, [wg_w]
    mov rcx, [wg_h]
    jmp desk_damage

; a window from the Window menu, forward (if it is still there)
mn_window:
    xor ecx, ecx
    lea rax, [desk_wins]
.find:
    cmp [rax + rcx * 8], rdi
    je .found
    inc ecx
    cmp ecx, DESK_MAX
    jb .find
    ret
.found:
    test dword [rdi + WN_FLAGS], WF_CLOSING
    jnz .out
    call win_focus
.out:
    ret

; states: -> EAX = MS_*. Preserve others.
ms_focus:                               ; a window has the keys
    xor eax, eax
    cmp qword [desk_focus], 0
    jne .out
    mov eax, MS_OFF
.out:
    ret

ms_closable:                            ; and it may be closed
    push rcx
    mov eax, MS_OFF
    mov rcx, [desk_focus]
    test rcx, rcx
    jz .out
    test dword [rcx + WN_FLAGS], WF_CLOSE
    jz .out
    xor eax, eax
.out:
    pop rcx
    ret

ms_resizable:                           ; and resized
    push rcx
    mov eax, MS_OFF
    mov rcx, [desk_focus]
    test rcx, rcx
    jz .out
    test dword [rcx + WN_FLAGS], WF_RESIZE
    jz .out
    xor eax, eax
.out:
    pop rcx
    ret

ms_screen:                              ; and resized, ticked full screen
    push rcx
    mov eax, MS_OFF
    mov rcx, [desk_focus]
    test rcx, rcx
    jz .out
    test dword [rcx + WN_FLAGS], WF_RESIZE
    jz .out
    xor eax, eax
    test dword [rcx + WN_FLAGS], WF_SCREEN
    jz .out
    mov eax, MS_CHECK
.out:
    pop rcx
    ret

ms_program:                             ; and it is a program's: keys for it
    push rcx
    mov eax, MS_OFF
    mov rcx, [desk_focus]
    test rcx, rcx
    jz .out
    test dword [rcx + WN_FLAGS], WF_PROGRAM
    jz .out
    xor eax, eax
.out:
    pop rcx
    ret

ms_look:                                ; the look it is
    xor eax, eax
    cmp dil, [th_mode]
    jne .out
    mov eax, MS_CHECK
.out:
    ret

ms_scale:                               ; as big, or small, as it goes
    push rcx
    xor eax, eax
    mov ecx, [ui_s4]
    add ecx, edi
    cmp ecx, 4
    jl .off
    cmp ecx, 8
    jle .out
.off:
    mov eax, MS_OFF
.out:
    pop rcx
    ret

ms_widgets:                             ; shown
    xor eax, eax
    cmp byte [wg_hidden], 0
    jne .out
    mov eax, MS_CHECK
.out:
    ret

ms_window:                              ; the one with the keys
    xor eax, eax
    cmp rdi, [desk_focus]
    jne .out
    mov eax, MS_CHECK
.out:
    ret

section .data
align 8
mn_which:       dq -1                   ; the open menu (BT_*), -1 none
mn_hot:         dq -1                   ; its item chosen
mn_px:          dq -1                   ; the pointer when last seen
mn_py:          dq -1
mn_blink:       dq -1                   ; an item chosen, blinking

; the menus
mn_axiom:
    ITEM 'About Axiom', mn_app, APP_SYSTEM, 0
    ITEM {'Settings', G_ELLIPSIS}, mn_app, APP_SETTINGS, 0
    LINE
    ITEM 'Restart', mn_restart, 0, 0
    ITEM 'Shut Down', mn_shut_down, 0, 0
    MENU_END
mn_file:
    ITEM 'New Terminal', mn_terminal, 0, 0
    ITEM 'Open Files', mn_app, APP_FILES, 0
    ITEM 'Open Notes', mn_app, APP_NOTES, 0
    LINE
    ITEM 'Close Window', mn_close_window, 0, ms_closable
    MENU_END
mn_edit:
    ITEMK 'Undo', mn_key_to, 'Z' - 64, ms_program, {UG_CTRL, 'Z'}
    LINE
    ITEMK 'Cut', mn_key_to, 'X' - 64, ms_program, {UG_CTRL, 'X'}
    ITEMK 'Copy', mn_key_to, 'C' - 64, ms_program, {UG_CTRL, 'C'}
    ITEMK 'Paste', mn_key_to, 'V' - 64, ms_program, {UG_CTRL, 'V'}
    ITEMK 'Select All', mn_key_to, 'A' - 64, ms_program, {UG_CTRL, 'A'}
    MENU_END
mn_view:
    ITEM 'Light Look', mn_look, TH_LIGHT, ms_look
    ITEM 'Dark Look', mn_look, TH_DARK, ms_look
    LINE
    ITEM 'Bigger', mn_scale, 1, ms_scale
    ITEM 'Smaller', mn_scale, -1, ms_scale
    LINE
    ITEM 'Widgets', mn_widgets, 0, ms_widgets
    MENU_END
mn_window_menu:
    ITEM 'Minimise', mn_minimise, 0, ms_focus
    ITEM 'Zoom', mn_zoom, 0, ms_resizable
    ITEMK 'Full Screen', mn_screen, 0, ms_screen, {UG_CTRL, UG_CMD, 'F'}
    LINE
    MENU_END                            ; then each window
mn_help:
    ITEM {'Find an App', G_ELLIPSIS}, mn_find, 0, 0
    ITEM 'Axiom Help', mn_run, str_mn_cmd_help, 0
    ITEM 'About Axiom', mn_app, APP_SYSTEM, 0
    MENU_END

section .rodata
align 8
bt_labels:      dq 0, 0, str_bt_file, str_bt_edit, str_bt_view, str_bt_window, str_bt_help
bt_menus:       dq mn_axiom, 0, mn_file, mn_edit, mn_view, mn_window_menu, mn_help
mn_net_says:    dq str_mn_no_net, str_mn_wifi_off, str_mn_wifi, str_mn_wire_off, 0
str_bt_file:    db 'File', 0
str_bt_edit:    db 'Edit', 0
str_bt_view:    db 'View', 0
str_bt_window:  db 'Window', 0
str_bt_help:    db 'Help', 0
str_mn_tick:    db G_CHECK, 0
str_mn_find:    db 'Open an app, or run a command', 0
str_mn_no_battery: db 'No battery', 0
str_mn_on_battery: db 'On its battery', 0
str_mn_charger: db 'On its charger', 0
str_mn_held:    db 'On its charger, held at 80%', 0
str_mn_system:  db 'System', G_ELLIPSIS, 0
str_mn_no_net:  db 'No network', 0
str_mn_wifi_off: db 'Wi-Fi: not on a network', 0
str_mn_wifi:    db 'Wi-Fi: on a network', 0
str_mn_wire_off: db 'Wired: no link', 0
str_mn_net_more: db 'Network Details', G_ELLIPSIS, 0
str_mn_cmd_net: db 'net', 0
str_mn_cmd_help: db 'help', 0
align 2
st_lens:       dw 2           ; the magnifier, 15 points square: a ring, a handle
    dw 50
    dw 379, 200, 373, 154, 355, 110, 327, 73, 290, 45, 246, 27
    dw 200, 21, 154, 27, 110, 45, 73, 73, 45, 110, 27, 154
    dw 21, 200, 27, 246, 45, 290, 73, 327, 110, 355, 154, 373
    dw 200, 379, 246, 373, 290, 355, 327, 327, 355, 290, 373, 246
    dw 379, 200, 331, 200, 327, 234, 314, 266, 293, 293, 266, 314
    dw 234, 327, 200, 331, 166, 327, 134, 314, 107, 293, 86, 266
    dw 73, 234, 69, 200, 73, 166, 86, 134, 107, 107, 134, 86
    dw 166, 73, 200, 69, 234, 73, 266, 86, 293, 107, 314, 134
    dw 327, 166, 331, 200
    dw 14
    dw 423, 466, 437, 474, 453, 474, 466, 466, 474, 453, 474, 437
    dw 466, 423, 338, 295, 325, 287, 309, 287, 295, 295, 287, 309
    dw 287, 325, 295, 338
st_fan:        dw 3           ; Wi-Fi, 17 x 12 points: a fan of three from its point
    dw 12
    dw 272, 378, 349, 301, 336, 290, 321, 281, 306, 274, 289, 270
    dw 272, 269, 255, 270, 238, 274, 223, 281, 208, 290, 195, 301
    dw 32
    dw 435, 215, 412, 195, 387, 178, 360, 165, 332, 155, 302, 149
    dw 272, 147, 242, 149, 212, 155, 184, 165, 157, 178, 132, 195
    dw 109, 215, 99, 238, 109, 262, 133, 272, 157, 262, 173, 248
    dw 190, 236, 210, 227, 230, 220, 251, 216, 272, 214, 293, 216
    dw 314, 220, 334, 227, 354, 236, 371, 248, 387, 262, 411, 272
    dw 435, 262, 445, 238
    dw 32
    dw 521, 129, 486, 98, 448, 73, 407, 52, 363, 38, 318, 29
    dw 272, 26, 226, 29, 181, 38, 137, 52, 96, 73, 58, 98
    dw 23, 129, 13, 152, 23, 176, 47, 186, 71, 176, 99, 152
    dw 130, 131, 163, 114, 198, 103, 235, 95, 272, 93, 309, 95
    dw 346, 103, 381, 114, 414, 131, 445, 152, 473, 176, 497, 186
    dw 521, 176, 531, 152
st_wire:       dw 7           ; a wired network, 17 x 12: a box over two, joined
    dw 8
    dw 210, 16, 334, 16, 360, 42, 360, 126, 334, 152, 210, 152
    dw 184, 126, 184, 42
    dw 4
    dw 256, 152, 288, 152, 288, 200, 256, 200
    dw 4
    dw 72, 200, 472, 200, 472, 232, 72, 232
    dw 4
    dw 72, 232, 104, 232, 104, 256, 72, 256
    dw 4
    dw 440, 232, 472, 232, 472, 256, 440, 256
    dw 8
    dw 34, 256, 158, 256, 184, 282, 184, 358, 158, 384, 34, 384
    dw 8, 358, 8, 282
    dw 8
    dw 386, 256, 510, 256, 536, 282, 536, 358, 510, 384, 386, 384
    dw 360, 358, 360, 282
st_bolt:       dw 1           ; charging: over the battery's body, 24 x 12
    dw 6
    dw 429, 29, 243, 224, 362, 224, 336, 355, 522, 160, 403, 160

section .bss
alignb 8
bt_x:           resq BT_ALL             ; the bar's titles and what is at its
bt_w:           resq BT_ALL             ; right: where (0 wide: not there)
bar_clock_x:    resq 1
mb_hp:          resq 1                  ; measures (mn_metrics)
mb_pill:        resq 1
mn_drop:        resq 1
mn_pad:         resq 1
mn_row:         resq 1
mn_sep:         resq 1
mn_r:           resq 1
mn_hr:          resq 1
mn_tick:        resq 1
mn_tx:          resq 1
mn_key_gap:     resq 1
mn_right:       resq 1
mn_min:         resq 1
mn_find_w:      resq 1
mn_label_max:   resq 1
st_gap:         resq 1
mn_x:           resq 1                  ; the open menu: where,
mn_y:           resq 1
mn_w:           resq 1
mn_h:           resq 1
mn_n:           resq 1                  ; its items
mn_items:       resb MN_MAX * MI_SIZE
mn_text_n:      resq 1
mn_query_n:     resq 1
st_bat:         resq 1                  ; the battery, as last read (bat_info)
st_due:        resq 1                  ; st_tick: when next,
st_seen:        resq 1                  ; and what it saw
alignb 8
mn_gl:          resb GL_SIZE            ; the open menu's glass
mn_blink_t0:    resq 1                  ; when it was chosen
st_pts:         resd 2 * POLY_MAX
mn_ink:         resd 1
mn_text:        resb MN_TEXT
mn_query:       resb MN_QUERY
st_buf:         resb 16
