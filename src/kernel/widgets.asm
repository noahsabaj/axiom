; =============================================================================
;  widgets.asm - the desktop's widgets: cards of frosted glass at its top
;  left, over the wallpaper and under every window. A clock; this month,
;  today ringed; and the system: its load, the memory in use, the CPU's
;  temperature and the battery, each with a bar.
;
;  They are drawn into wg_sf, the part of the wallpaper they cover with
;  them over it, and wall_draw shows that part from there (wg_show). Their
;  glass (the wallpaper behind them blurred, tinted and outlined, as the
;  dock is) is made into wg_bg when the look or the scale changes
;  (wg_looks); what is on them is drawn over a copy of it when a minute
;  turns and every few seconds (wg_tick, wg_paint).
;
;  Measures are points (theme.asm: pt), turned to pixels by wg_looks.
; =============================================================================

WG_MARGIN       equ 16                  ; from the screen's left, and the bar
WG_SMALL        equ 164                 ; a small card's side
WG_GAP          equ 16                  ; between cards
WG_R            equ 22                  ; their corners
WG_PAD          equ 14                  ; inside them
WG_BIG          equ 44                  ; the clock's figures
WG_MID          equ 22                  ; the system's
WG_BAR          equ 5                   ; its bars' height
WG_EVERY_MS     equ 5000                ; the system's card, again this often

; a card: where it is in wg_sf
WC_X            equ 0
WC_Y            equ 8
WC_W            equ 16
WC_H            equ 24
WC_SIZE         equ 32
WG_CARDS        equ 3                   ; the clock, the month, the system

section .text

; wg_looks: the widgets' place and glass at this scale and in this look,
; then what is on them. From desk_looks, after the wallpaper. Preserves
; RBX, RBP, R12-R15.
wg_looks:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov byte [wg_ok], 0
    cmp qword [wall_sf + SF_PTR], 0
    je .out
    mov edi, WG_PAD
    call pt
    mov [wg_pad], rax
    mov edi, WG_R
    call pt
    mov [wg_r], rax
    mov edi, WG_BAR
    call pt
    mov [wg_bar_h], rax
    mov edi, WG_GAP
    call pt
    mov r14, rax                        ; the gap
    mov edi, WG_SMALL
    call pt
    mov r15, rax                        ; a small card's side
    mov rax, [m_blur]                   ; the glass: half again the dock's blur
    mov rcx, rax
    shr rcx, 1
    add rax, rcx
    cmp rax, 64
    jbe .blur
    mov eax, 64
.blur:
    mov [wg_blur], rax
    imul rbx, rax, 3                    ; how far it reads past a card
    mov edi, WG_MARGIN                  ; the cards' top left, on the screen
    call pt
    mov r12, rax
    add rax, [m_bar_h]
    mov r13, rax
    mov rax, r12                        ; the area: the cards, and what the
    sub rax, rbx                        ; blur reads around them
    jns .x
    xor eax, eax
.x:
    mov [wg_x], rax
    mov rax, r13
    sub rax, rbx
    jns .y
    xor eax, eax
.y:
    mov [wg_y], rax
    lea rax, [r15 * 2 + r14]            ; the cards' width, and height
    lea rcx, [r12 + rax]
    add rcx, rbx
    cmp rcx, [scr_w]
    jbe .w
    mov rcx, [scr_w]
.w:
    sub rcx, [wg_x]
    jle .out
    mov [wg_w], rcx
    lea rcx, [r13 + rax]
    add rcx, rbx
    cmp rcx, [scr_h]
    jbe .h
    mov rcx, [scr_h]
.h:
    sub rcx, [wg_y]
    jle .out
    mov [wg_h], rcx
    sub r12, [wg_x]                     ; each card, in the area
    sub r13, [wg_y]
    lea rdi, [wg_cards]
    mov [rdi + WC_X], r12               ; the clock
    mov [rdi + WC_Y], r13
    mov [rdi + WC_W], r15
    mov [rdi + WC_H], r15
    lea rax, [r12 + r15]                ; the month, at its right
    add rax, r14
    mov [rdi + WC_SIZE + WC_X], rax
    mov [rdi + WC_SIZE + WC_Y], r13
    mov [rdi + WC_SIZE + WC_W], r15
    mov [rdi + WC_SIZE + WC_H], r15
    mov [rdi + 2 * WC_SIZE + WC_X], r12 ; the system, under both, as wide
    lea rax, [r13 + r15]
    add rax, r14
    mov [rdi + 2 * WC_SIZE + WC_Y], rax
    lea rax, [r15 * 2 + r14]
    mov [rdi + 2 * WC_SIZE + WC_W], rax
    mov [rdi + 2 * WC_SIZE + WC_H], r15
    mov edi, 11                         ; the fonts
    call pt
    mov edi, eax
    mov esi, UF_REGULAR
    call uf_size
    mov [wg_f_small], eax
    mov esi, UF_SEMIBOLD
    call uf_size
    mov [wg_f_small_b], eax
    mov edi, 13
    call pt
    mov edi, eax
    mov esi, UF_SEMIBOLD
    call uf_size
    mov [wg_f_head], eax
    mov edi, WG_BIG
    call pt
    mov edi, eax
    call wg_figures
    mov [wg_f_big], eax
    mov edi, WG_MID
    call pt
    mov edi, eax
    call wg_figures
    mov [wg_f_mid], eax
    lea rdi, [wg_bg]                    ; the glass
    mov rsi, [wg_w]
    mov rdx, [wg_h]
    call sf_size
    jc .out
    lea rdi, [wg_sf]
    call sf_size
    jc .out
    lea rsi, [wall_sf]                  ; over the wallpaper under the area
    lea rdi, [wg_bg]
    call wg_copy_in
    lea rdi, [wg_bg]
    call gfx_target
    xor ebx, ebx
.card:
    imul rax, rbx, WC_SIZE
    lea rcx, [wg_cards]
    add rax, rcx
    mov rdi, [rax + WC_X]
    mov rsi, [rax + WC_Y]
    mov rdx, [rax + WC_W]
    mov rcx, [rax + WC_H]
    mov r8, [wg_r]
    mov r9, [wg_blur]
    call gfx_frost
    mov r8d, [th_c + TC_DOCK]
    mov r9d, [th_c + TC_DOCK_A]
    mov r10, [wg_r]
    mov r11d, RC_ALL
    call gfx_rrect
    mov r8d, [th_c + TC_DOCK_EDGE]
    mov r9d, [th_c + TC_DOCK_EDGE_A]
    call gfx_rring
    inc ebx
    cmp ebx, WG_CARDS
    jb .card
    call gfx_target_back
    mov byte [wg_ok], 1
    call wg_paint
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wg_figures(EDI = pixels) -> EAX = the figures' font nearest that size.
; Preserves others.
wg_figures:
    push rcx
    push rdx
    push r8
    push r9
    lea r8, [uf_big_px]
    xor ecx, ecx
    xor eax, eax
    mov r9d, 0x7FFFFFFF
.each:
    cmp ecx, UF_BIG_SIZES
    jae .done
    movzx edx, byte [r8 + rcx]
    sub edx, edi
    jns .abs
    neg edx
.abs:
    cmp edx, r9d
    jae .next
    mov r9d, edx
    mov eax, ecx
.next:
    inc ecx
    jmp .each
.done:
    add eax, UF_BIG
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; wg_copy_in(RSI = a surface the screen's size, RDI = one the area's size):
; the area's part of the first into the second. Preserves RBX, RBP,
; R12-R15.
wg_copy_in:
    push r12
    mov r8, [rsi + SF_PITCH]
    mov r9, [wg_y]
    imul r9, r8
    mov rax, [wg_x]
    lea r9, [r9 + rax * 4]
    add r9, [rsi + SF_PTR]
    mov r10, [rdi + SF_PTR]
    mov r11, [rdi + SF_PITCH]
    mov r12, [wg_h]
.row:
    mov rsi, r9
    mov rdi, r10
    mov rcx, [wg_w]
    rep movsd
    add r9, r8
    add r10, r11
    dec r12
    jnz .row
    pop r12
    ret

; wg_tick: from desk_tick, the clock just read: the cards again when the
; minute turns, and every WG_EVERY_MS. Preserves all.
wg_tick:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rax, [rtc_min]
    cmp rax, [wg_minute]
    jne .paint
    call uptime_ms
    cmp rax, [wg_next]
    jb .out
.paint:
    call wg_paint
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

; wg_paint: what is on the cards, now, over their glass; then shown.
; Preserves RBX, RBP, R12-R15.
wg_paint:
    cmp byte [wg_ok], 0
    je .out
    push rbx
    mov rsi, [wg_bg + SF_PTR]           ; the glass again (the two the same
    mov rdi, [wg_sf + SF_PTR]           ; size: the same pitch)
    mov rcx, [wg_bg + SF_PITCH]
    imul rcx, [wg_h]
    shr rcx, 2
    rep movsd
    call rtc_read
    mov rax, [rtc_min]
    mov [wg_minute], rax
    call uptime_ms
    add rax, WG_EVERY_MS
    mov [wg_next], rax
    lea rdi, [wg_sf]
    call gfx_target
    lea rbx, [wg_cards]
    call wg_clock
    add rbx, WC_SIZE
    call wg_month
    add rbx, WC_SIZE
    call wg_system
    call gfx_target_back
    cmp byte [desk_ready], 0
    je .done
    mov rdi, [wg_x]
    mov rsi, [wg_y]
    mov rdx, [wg_w]
    mov rcx, [wg_h]
    call desk_damage
.done:
    pop rbx
.out:
    ret

; wg_show: the widgets where the clip meets them (wall_draw, after the
; wallpaper). Preserves all.
wg_show:
    cmp byte [wg_ok], 0
    je .none
    cmp byte [wg_hidden], 0             ; put away (View's menu)
    je .some
.none:
    ret
.some:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov rcx, [tg_cx0]                   ; across: the clip within the area
    mov rax, [wg_x]
    cmp rcx, rax
    jge .x0
    mov rcx, rax
.x0:
    mov rdx, [tg_cx1]
    add rax, [wg_w]
    cmp rdx, rax
    jle .x1
    mov rdx, rax
.x1:
    sub rdx, rcx
    jle .out
    mov r8, [tg_cy0]                    ; down
    mov rax, [wg_y]
    cmp r8, rax
    jge .y0
    mov r8, rax
.y0:
    mov r9, [tg_cy1]
    add rax, [wg_h]
    cmp r9, rax
    jle .y1
    mov r9, rax
.y1:
    sub r9, r8
    jle .out
    mov rsi, r8                         ; from
    sub rsi, [wg_y]
    imul rsi, [wg_sf + SF_PITCH]
    mov rax, rcx
    sub rax, [wg_x]
    lea rsi, [rsi + rax * 4]
    add rsi, [wg_sf + SF_PTR]
    mov rdi, r8                         ; to
    imul rdi, [tg_pitch]
    lea rdi, [rdi + rcx * 4]
    add rdi, [tg_ptr]
    mov r10, rdx
.row:
    push rsi
    push rdi
    mov rcx, r10
    rep movsd
    pop rdi
    pop rsi
    add rsi, [wg_sf + SF_PITCH]
    add rdi, [tg_pitch]
    dec r9
    jnz .row
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The cards. Each: RBX = its WC_*; draws into the target (wg_sf).
; -----------------------------------------------------------------------------

; wg_clock: the weekday, the time in large figures, the date
wg_clock:
    push r12
    mov rax, [rtc_year]
    mov rcx, [rtc_mon]
    mov rdx, [rtc_day]
    call wg_dow
    lea rcx, [wg_day_names]
    mov rdx, [rcx + rax * 8]
    mov edi, [wg_f_head]                ; at the top
    call wg_cap
    mov rsi, [rbx + WC_Y]
    add rsi, [wg_pad]
    add rsi, rax
    mov ecx, [th_accent]
    mov r8d, [wg_f_head]
    call wg_centre
    lea rdi, [wg_buf]                   ; the time, in the middle
    SPRINTF rdi, "%u:%02u", qword [rtc_hour], qword [rtc_min]
    mov edi, [wg_f_big]
    call wg_cap
    mov rsi, [rbx + WC_H]
    add rsi, rax
    shr rsi, 1
    add rsi, [rbx + WC_Y]
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [wg_f_big]
    call wg_centre
    mov rcx, [rtc_mon]                  ; the date, at the foot
    lea rax, [wg_month_names]
    mov r12, [rax + rcx * 8 - 8]
    lea rdi, [wg_buf]
    SPRINTF rdi, "%u %s", qword [rtc_day], r12
    mov rsi, [rbx + WC_Y]
    add rsi, [rbx + WC_H]
    sub rsi, [wg_pad]
    mov edi, 2
    call pt
    sub rsi, rax
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, [wg_f_head]
    call wg_centre
    pop r12
    ret

; wg_month: the month's name, the weekdays' letters, its days (from
; Monday), today in a red disc
wg_month:
    push r12
    push r13
    push r14
    push r15
    mov rcx, [rtc_mon]                  ; its name, in capitals
    lea rax, [wg_month_names]
    mov rsi, [rax + rcx * 8 - 8]
    lea rdi, [wg_buf]
.upper:
    lodsb
    cmp al, 'a'
    jb .put
    cmp al, 'z'
    ja .put
    sub al, 32
.put:
    stosb
    test al, al
    jnz .upper
    mov edi, [wg_f_small_b]
    call wg_cap
    mov rdi, [rbx + WC_X]
    add rdi, [wg_pad]
    mov rsi, [rbx + WC_Y]
    add rsi, [wg_pad]
    add rsi, rax
    mov r12, rsi                        ; R12: the name's baseline
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_T_BAD]
    mov r8d, [wg_f_small_b]
    call uf_text
    mov edi, 6                          ; seven rows under it: the letters,
    call pt                             ; then six weeks
    add r12, rax
    mov rax, [rbx + WC_Y]
    add rax, [rbx + WC_H]
    mov rcx, [wg_pad]
    shr rcx, 1
    sub rax, rcx
    sub rax, r12
    xor edx, edx
    mov ecx, 7
    div rcx
    mov [wg_row_h], rax
    mov rax, [rbx + WC_W]               ; seven columns, half the margin out
    sub rax, [wg_pad]
    xor edx, edx
    mov ecx, 7
    div rcx
    mov [wg_col_w], rax
    mov rax, [wg_pad]
    shr rax, 1
    add rax, [rbx + WC_X]
    mov [wg_col_x], rax
    mov [wg_row_y], r12
    xor r13d, r13d                      ; the letters
.letter:
    lea rax, [wg_letters]
    lea rdx, [rax + r13 * 2]
    mov rax, r13
    xor r14d, r14d                      ; row 0
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, [wg_f_small_b]
    call wg_cell
    inc r13
    cmp r13, 7
    jb .letter
    mov rax, [rtc_year]                 ; the 1st's column, from Monday
    mov rcx, [rtc_mon]
    mov edx, 1
    call wg_dow
    add rax, 6
    xor edx, edx
    mov ecx, 7
    div rcx
    mov r15, rdx                        ; R15: the cell of the 1st
    mov rax, [rtc_mon]                  ; R12: days in the month
    lea rcx, [wg_month_days]
    movzx r12d, byte [rcx + rax - 1]
    cmp rax, 2
    jne .days
    mov rax, [rtc_year]                 ; a leap year's February
    test eax, 3
    jnz .days
    xor edx, edx
    mov ecx, 100
    div rcx
    test rdx, rdx
    jnz .leap
    test eax, 3                         ; a century: only every fourth
    jnz .days
.leap:
    inc r12d
.days:
    mov r13d, 1                         ; R13: the day
.day:
    cmp r13, r12
    ja .out
    lea rdi, [wg_buf]
    SPRINTF rdi, "%u", r13
    lea rax, [r15 + r13 - 1]
    xor edx, edx
    mov ecx, 7
    div rcx
    lea r14, [rax + 1]                  ; its row (after the letters)
    mov rax, rdx                        ; its column
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [wg_f_small]
    cmp r13, [rtc_day]
    jne .cell
    call wg_today                       ; a disc under it, the text white
.cell:
    call wg_cell
    inc r13
    jmp .day
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; wg_cell(RAX = column, R14 = row, RDX = text, ECX = color, R8D = font):
; the text in the middle of that cell of the month. Preserves RBX, RBP,
; R12-R15.
wg_cell:
    push rdx
    push rcx
    mov rdi, rax
    call wg_cell_middle                 ; -> RDI, RSI: its middle
    pop rcx
    pop rdx
    push rdi
    push rsi
    mov rdi, rdx
    mov esi, r8d
    call uf_width
    pop rsi
    pop rdi
    shr rax, 1
    sub rdi, rax
    push rdi
    mov edi, r8d
    call wg_cap
    pop rdi
    shr rax, 1
    add rsi, rax                        ; the baseline: half a capital down
    jmp uf_text

; wg_cell_middle(RDI = column, R14 = row) -> RDI, RSI: the cell's middle.
; Preserves others but RAX.
wg_cell_middle:
    mov rax, [wg_col_w]
    imul rdi, rax
    shr rax, 1
    add rdi, rax
    add rdi, [wg_col_x]
    mov rax, [wg_row_h]
    mov rsi, r14
    imul rsi, rax
    shr rax, 1
    add rsi, rax
    add rsi, [wg_row_y]
    ret

; wg_today(RAX = column, R14 = row): today's disc there -> ECX = the
; color its number is drawn in, R8D its font. Preserves RAX, RDX.
wg_today:
    push rax
    push rdx
    push rdi
    push rsi
    mov rdi, rax
    call wg_cell_middle
    mov rdx, [wg_row_h]                 ; as wide as a row is high, or a column
    cmp rdx, [wg_col_w]                 ; wide
    jbe .d
    mov rdx, [wg_col_w]
.d:
    mov rax, rdx
    shr rax, 1
    sub rdi, rax
    sub rsi, rax
    mov r8d, [th_c + TC_T_BAD]
    mov r9d, 256
    call gfx_circle
    mov ecx, 0xFFFFFF
    mov r8d, [wg_f_small_b]
    pop rsi
    pop rdi
    pop rdx
    pop rax
    ret

; wg_system: "System", how long it has been up; then four of its measures,
; two by two, each a label, a figure and a bar
wg_system:
    push r12
    push r13
    push r14
    push r15
    mov edi, [wg_f_head]
    call wg_cap
    mov r12, rax
    mov rdi, [rbx + WC_X]
    add rdi, [wg_pad]
    mov rsi, [rbx + WC_Y]
    add rsi, [wg_pad]
    add rsi, r12
    mov r13, rsi                        ; R13: the heading's baseline
    lea rdx, [str_wg_system]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [wg_f_head]
    call uf_text
    call uptime_ms                      ; up h:mm, at the right
    xor edx, edx
    mov ecx, 60000
    div rcx
    xor edx, edx
    mov ecx, 60
    div rcx
    lea rdi, [wg_buf]
    SPRINTF rdi, "up %u:%02u", rax, rdx
    lea rdi, [wg_buf]
    mov esi, [wg_f_small]
    call uf_width
    mov rdi, [rbx + WC_X]
    add rdi, [rbx + WC_W]
    sub rdi, [wg_pad]
    sub rdi, rax
    mov rsi, r13
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, [wg_f_small]
    call uf_text
    mov edi, 10                         ; the cells under it
    call pt
    add r13, rax
    mov rax, [rbx + WC_Y]
    add rax, [rbx + WC_H]
    sub rax, [wg_pad]
    sub rax, r13
    shr rax, 1
    mov [wg_row_h], rax
    mov [wg_row_y], r13
    mov rax, [rbx + WC_W]
    sub rax, [wg_pad]
    sub rax, [wg_pad]
    sub rax, [wg_pad]
    shr rax, 1
    mov [wg_col_w], rax
    ; the load: of each CPU's share, how much is used
    call load_info
    mov r12, rax
    lea rdi, [wg_buf]
    SPRINTF rdi, "%h", r12
    imul rax, r12, 10                   ; per mille of the CPUs
    mov ecx, [cpus_online]
    test ecx, ecx
    jnz .cpus
    inc ecx
.cpus:
    xor edx, edx
    div rcx
    xor r14d, r14d
    lea r15, [str_wg_load]
    call wg_measure
    ; the memory in use
    mov rax, [pmm_free_pages]
    shl rax, 12
    mov rcx, [pmm_usable_bytes]
    sub rcx, rax
    jns .used
    xor ecx, ecx
.used:
    mov rax, rcx
    imul rax, rax, 1000
    mov rcx, [pmm_usable_bytes]
    test rcx, rcx
    jnz .of
    inc rcx
.of:
    xor edx, edx
    div rcx
    mov r12, rax
    xor edx, edx
    mov ecx, 10
    div rcx
    lea rdi, [wg_buf]
    SPRINTF rdi, "%u%%", rax
    mov rax, r12
    mov r14d, 1
    lea r15, [str_wg_memory]
    call wg_measure
    ; the CPU's temperature, of 100 C
    call cpu_heat
    cmp rax, E_EMPTY
    je .no_heat
    mov r12, rax
    lea rdi, [wg_buf]
    SPRINTF rdi, {"%u", G_DEGREE}, r12
    imul rax, r12, 10
    jmp .heat
.no_heat:
    lea rdi, [wg_buf]
    SPRINTF rdi, "--"
    xor eax, eax
.heat:
    mov r14d, 2
    lea r15, [str_wg_cpu]
    call wg_measure
    ; the battery
    call bat_info
    lea r15, [str_wg_battery]
    cmp rax, E_EMPTY
    je .no_battery
    test eax, SI_BAT_PLUGGED
    jz .on_battery
    lea r15, [str_wg_charging]
.on_battery:
    movzx r12d, al
    lea rdi, [wg_buf]
    SPRINTF rdi, "%u%%", r12
    imul rax, r12, 10
    neg rax                             ; a battery's bar: worse when low
    jmp .battery
.no_battery:
    lea rdi, [wg_buf]
    SPRINTF rdi, "--"
    xor eax, eax
.battery:
    mov r14d, 3
    call wg_measure
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; wg_measure(R14 = which cell, R15 = its label, wg_buf = its figure, RAX =
; how full its bar is, per mille; negative: a battery's, worse when low)
wg_measure:
    push r12
    push r13
    mov r12, rax
    mov rax, r14                        ; the cell's top left
    and eax, 1
    mov rdi, [wg_col_w]
    add rdi, [wg_pad]
    imul rdi, rax
    add rdi, [rbx + WC_X]
    add rdi, [wg_pad]
    mov [wg_col_x], rdi
    mov rax, r14
    shr eax, 1
    imul rax, [wg_row_h]
    add rax, [wg_row_y]
    mov r13, rax
    mov edi, [wg_f_small]               ; the label
    call wg_cap
    add r13, rax
    mov rdi, [wg_col_x]
    mov rsi, r13
    mov rdx, r15
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, [wg_f_small]
    call uf_text
    mov edi, [wg_f_mid]                 ; the figure
    call wg_cap
    add r13, rax
    mov edi, 6
    call pt
    add r13, rax
    mov rdi, [wg_col_x]
    mov rsi, r13
    lea rdx, [wg_buf]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [wg_f_mid]
    call uf_text
    mov edi, 7                          ; the bar: its track, then how full
    call pt
    add r13, rax
    mov rdi, [wg_col_x]
    mov rsi, r13
    mov rdx, [wg_col_w]
    mov rcx, [wg_bar_h]
    mov r8d, [th_c + TC_TEXT]
    mov r9d, 40
    mov r10, rcx
    shr r10, 1
    mov r11d, RC_ALL
    call gfx_rrect
    mov r8d, [th_c + TC_T_GOOD]         ; its color: by how full, or for a
    mov rax, r12                        ; battery how empty
    test rax, rax
    js .battery
    cmp rax, 700
    jb .fill
    mov r8d, [th_c + TC_T_WARN]
    cmp rax, 900
    jb .fill
    mov r8d, [th_c + TC_T_BAD]
    jmp .fill
.battery:
    neg rax
    cmp rax, 300
    ja .fill
    mov r8d, [th_c + TC_T_WARN]
    cmp rax, 150
    ja .fill
    mov r8d, [th_c + TC_T_BAD]
.fill:
    test rax, rax
    jz .out
    cmp rax, 1000
    jbe .part
    mov eax, 1000
.part:
    imul rax, rdx
    push rdx
    xor edx, edx
    mov ecx, 1000
    div rcx
    pop rdx
    mov rcx, [wg_bar_h]
    cmp rax, rcx                        ; at least its round ends
    jae .wide
    mov rax, rcx
.wide:
    mov rdx, rax
    mov r9d, 256
    call gfx_rrect
.out:
    pop r13
    pop r12
    ret

; wg_centre(RBX = a card, RSI = baseline, RDX = text, ECX = color, R8D =
; font): the text across the middle of the card. Preserves all but RAX.
wg_centre:
    push rdi
    push rsi
    mov rdi, rdx
    mov esi, r8d
    call uf_width
    pop rsi
    mov rdi, [rbx + WC_W]
    sub rdi, rax
    sar rdi, 1
    add rdi, [rbx + WC_X]
    call uf_text
    pop rdi
    ret

; wg_cap(EDI = font) -> RAX = a capital's height in it. Preserves others.
wg_cap:
    call uf_metrics
    mov eax, [rax + UFT_CAP]
    ret

; wg_dow(RAX = year, RCX = month 1..12, RDX = day) -> RAX = its weekday,
; 0 Sunday .. 6 (Sakamoto's method). Preserves others.
wg_dow:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, rdx
    cmp rcx, 3
    jae .year
    dec rax
.year:
    mov rdi, rax                        ; y + y/4 - y/100 + y/400
    mov rdx, rax
    shr rdx, 2
    add rdi, rdx
    push rcx
    push rax
    xor edx, edx
    mov ecx, 100
    div rcx
    sub rdi, rax
    pop rax
    xor edx, edx
    mov ecx, 400
    div rcx
    add rdi, rax
    pop rcx
    lea rax, [dow_t]
    movzx eax, byte [rax + rcx - 1]
    add rdi, rax
    add rdi, rsi
    mov rax, rdi
    xor edx, edx
    mov ecx, 7
    div rcx
    mov rax, rdx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

section .rodata
str_wg_system:  db 'System', 0
str_wg_load:    db 'Load', 0
str_wg_memory:  db 'Memory', 0
str_wg_cpu:     db 'CPU', 0
str_wg_battery: db 'Battery', 0
str_wg_charging: db 'Battery, charging', 0
wg_letters:     db 'M', 0, 'T', 0, 'W', 0, 'T', 0, 'F', 0, 'S', 0, 'S', 0
wg_month_days:  db 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31
str_wg_sun:     db 'Sunday', 0
str_wg_mon:     db 'Monday', 0
str_wg_tue:     db 'Tuesday', 0
str_wg_wed:     db 'Wednesday', 0
str_wg_thu:     db 'Thursday', 0
str_wg_fri:     db 'Friday', 0
str_wg_sat:     db 'Saturday', 0
str_wg_jan:     db 'January', 0
str_wg_feb:     db 'February', 0
str_wg_mar:     db 'March', 0
str_wg_apr:     db 'April', 0
str_wg_may:     db 'May', 0
str_wg_jun:     db 'June', 0
str_wg_jul:     db 'July', 0
str_wg_aug:     db 'August', 0
str_wg_sep:     db 'September', 0
str_wg_oct:     db 'October', 0
str_wg_nov:     db 'November', 0
str_wg_dec:     db 'December', 0
align 8
wg_day_names:
    dq str_wg_sun, str_wg_mon, str_wg_tue, str_wg_wed, str_wg_thu, str_wg_fri, str_wg_sat
wg_month_names:
    dq str_wg_jan, str_wg_feb, str_wg_mar, str_wg_apr, str_wg_may, str_wg_jun
    dq str_wg_jul, str_wg_aug, str_wg_sep, str_wg_oct, str_wg_nov, str_wg_dec

section .bss
alignb 8
wg_bg:          resb SF_SIZE            ; the cards' glass, over the wallpaper
wg_sf:          resb SF_SIZE            ; and what is on them
wg_cards:       resb WC_SIZE * WG_CARDS
wg_x:           resq 1                  ; the area, on the screen
wg_y:           resq 1
wg_w:           resq 1
wg_h:           resq 1
wg_pad:         resq 1
wg_r:           resq 1
wg_blur:        resq 1
wg_bar_h:       resq 1
wg_minute:      resq 1                  ; when they were drawn
wg_next:        resq 1                  ; and when again
wg_row_y:       resq 1                  ; a card's rows and columns, as it is
wg_row_h:       resq 1                  ; drawn
wg_col_x:       resq 1
wg_col_w:       resq 1
wg_f_small:     resd 1                  ; the fonts
wg_f_small_b:   resd 1
wg_f_head:      resd 1
wg_f_big:       resd 1
wg_f_mid:       resd 1
wg_ok:          resb 1                  ; they are made
wg_hidden:      resb 1                  ; not shown
wg_buf:         resb 64
