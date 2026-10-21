; =============================================================================
;  theme.asm - how the desktop looks: light or dark, an accent color, the
;  scale it is drawn at, and the wallpaper.
;
;  Colors have names (TC_*): the desktop and the windows draw with th_c +
;  TC_*, never with a color of their own, so a theme changes all of them.
;  The accent (th_accent) is one of nine, each with a light and a dark
;  shade. Text a terminal was given keeps the color it was written in (the
;  dark theme's COL_*); theme_color says what each of those is now.
;
;  The scale: one point is ui_s4 / 4 pixels, so a 2560x1600 screen is drawn
;  as 1280x800 points, and a 1920x1080 one at 1.25 pixels a point. pt()
;  turns points into pixels. Measures in this file and desk.asm are points.
;
;  The wallpaper is made, not stored: wall.asm's mountains over a lake, or
;  one of the gradients here (wall_grad: a gradient and soft light over it,
;  computed at a quarter of the size, then drawn smooth and dithered), as
;  desktop.wallpaper names.
;
;  The look, the accent, the scale and the wallpaper are settings
;  (settings.asm: display.theme, display.accent, display.scale,
;  desktop.wallpaper): kept on the stick, and changed from the shell's
;  'settings set' or a Settings window as from here (cfg_theme,
;  cfg_set_look). display.scale auto is th_auto_s4, this screen's own.
;
;  In the shell, 'theme' is a thing: theme (as it is), theme dark, theme
;  light, theme accent <name>, theme scale <1..2 in quarters: 4..8>.
; =============================================================================

; TH_* and the colors' names, TC_*, are in defs.inc: programs see them
; in the look (LK_C)

; the wallpaper: a gradient top to bottom, and WALL_BLOBS soft lights
WALL_BLOBS      equ 5
WB_X            equ 0                   ; its centre, thousandths of the width,
WB_Y            equ 4                   ; and of the height
WB_R            equ 8                   ; its reach, thousandths of the width
WB_COLOR        equ 12
WB_A            equ 16                  ; 0..256 at its centre
WB_SIZE         equ 20
WL_TOP          equ 0
WL_BOTTOM       equ 4
WL_BLOBS        equ 8
WL_SIZE         equ WL_BLOBS + WALL_BLOBS * WB_SIZE

ACCENTS         equ 9

section .text

; theme_init: the scale for this screen, and the look the settings say
; (after cfg_init). Before desk_init.
theme_init:
    push rax
    push rcx
    push rdx
    mov rax, [scr_h]                    ; about 800 points high: quarters
    shl rax, 2
    xor edx, edx
    mov ecx, 800
    div rcx
    cmp eax, 4
    jae .low
    mov eax, 4
.low:
    cmp eax, 8
    jbe .high
    mov eax, 8
.high:
    mov [th_auto_s4], eax
    mov [ui_s4], eax
    call cfg_theme                      ; th_mode, th_accent_i, th_wall, ui_s4
    call theme_load
    pop rdx
    pop rcx
    pop rax
    ret

; pt(EDI = points) -> RAX = pixels at this scale, at least 1. Preserves others.
pt:
    mov eax, edi
    imul eax, [ui_s4]
    add eax, 2
    shr eax, 2
    jnz .out
    inc eax
.out:
    ret

; theme_load: th_c and th_accent from th_mode and th_accent_i. Preserves all.
theme_load:
    push rax
    push rcx
    push rsi
    push rdi
    lea rsi, [th_dark_c]
    cmp byte [th_mode], TH_LIGHT
    jne .copy
    lea rsi, [th_light_c]
.copy:
    lea rdi, [th_c]
    mov ecx, TC_COUNT / 4
    rep movsd
    movzx eax, byte [th_accent_i]
    lea rsi, [accent_colors]
    lea rsi, [rsi + rax * 8]
    movzx ecx, byte [th_mode]
    mov eax, [rsi + rcx * 4]
    mov [th_accent], eax
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; theme_color(EAX = a color text was written in) -> EAX = the color it is
; drawn in now. Preserves others.
theme_color:
    push rcx
    push rdx
    push rsi
    lea rsi, [theme_map]
.find:
    mov ecx, [rsi]
    cmp ecx, -1
    je .out                             ; not one of ours: as it is
    cmp ecx, eax
    je .found
    add rsi, 8
    jmp .find
.found:
    mov ecx, [rsi + 4]
    cmp ecx, -1
    je .accent
    lea rdx, [th_c]
    mov eax, [rdx + rcx]
    jmp .out
.accent:
    mov eax, [th_accent]
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; theme_apply: th_mode, th_accent_i or ui_s4 changed: everything drawn again
theme_apply:
    call theme_load
    call desk_restyle
    jmp look_update                     ; and programs told

; -----------------------------------------------------------------------------
;  wall_grad: one of the gradient wallpapers (walls: th_wall - 1), into
;  wall_sf (the screen's size), for wall.asm's wall_make
; -----------------------------------------------------------------------------
wall_grad:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    lea rdi, [wall_sf]
    mov rsi, [scr_w]
    mov rdx, [scr_h]
    call sf_size
    jc .out
    ; the grid: a point every 4 pixels, and one past the edge
    mov rax, [scr_w]
    shr rax, 2
    add rax, 2
    mov [wall_gw], rax
    mov rcx, [scr_h]
    shr rcx, 2
    add rcx, 2
    mov [wall_gh], rcx
    imul rax, rcx
    imul rax, rax, 12                   ; 3 dwords a point: R, G, B in 8.8
    mov rdi, rax
    call vm_alloc
    test rax, rax
    jz .out
    mov [wall_grid], rax
    movzx eax, byte [th_wall]           ; desktop.wallpaper: 0 is wall.asm's
    dec eax                             ; (a gradient's, from 1)
    cmp eax, WALLS
    jb .wall
    xor eax, eax
.wall:
    shl eax, 1
    movzx ecx, byte [th_mode]
    add eax, ecx
    lea rbx, [walls]
    mov rbx, [rbx + rax * 8]
.params:
    cvtsi2ss xmm8, qword [scr_w]
    cvtsi2ss xmm9, qword [scr_h]
    mov r15, [wall_grid]
    xor r13d, r13d                      ; gy
.gy:
    cmp r13, [wall_gh]
    jae .grid_done
    xor r12d, r12d                      ; gx
.gx:
    cmp r12, [wall_gw]
    jae .gy_next
    ; the point, in pixels
    mov rax, r12
    shl rax, 2
    cvtsi2ss xmm6, rax                  ; x
    mov rax, r13
    shl rax, 2
    cvtsi2ss xmm7, rax                  ; y
    ; the gradient: t = 0.75 y / h + 0.25 x / w
    movss xmm0, xmm7
    divss xmm0, xmm9
    mulss xmm0, [f_0_75]
    movss xmm1, xmm6
    divss xmm1, xmm8
    mulss xmm1, [f_0_25]
    addss xmm0, xmm1
    minss xmm0, [f_one]
    mov eax, [rbx + WL_TOP]
    mov edx, [rbx + WL_BOTTOM]
    call .lerp_colors                   ; -> XMM3, XMM4, XMM5 = R, G, B
    ; the lights over it
    xor ebp, ebp
.blob:
    cmp ebp, WALL_BLOBS
    jae .store
    imul rcx, rbp, WB_SIZE
    lea rcx, [rbx + WL_BLOBS + rcx]
    mov eax, [rcx + WB_A]
    test eax, eax
    jz .blob_next
    cvtsi2ss xmm0, dword [rcx + WB_X]   ; its centre and reach, in pixels
    mulss xmm0, xmm8
    divss xmm0, [f_1000]
    subss xmm0, xmm6
    mulss xmm0, xmm0
    cvtsi2ss xmm1, dword [rcx + WB_Y]
    mulss xmm1, xmm9
    divss xmm1, [f_1000]
    subss xmm1, xmm7
    mulss xmm1, xmm1
    addss xmm0, xmm1                    ; d^2
    cvtsi2ss xmm1, dword [rcx + WB_R]
    mulss xmm1, xmm8
    divss xmm1, [f_1000]
    mulss xmm1, xmm1                    ; r^2
    divss xmm0, xmm1                    ; t = d^2 / r^2
    comiss xmm0, [f_one]
    jae .blob_next
    movss xmm1, [f_one]                 ; w = a (1 - t)^2
    subss xmm1, xmm0
    mulss xmm1, xmm1
    cvtsi2ss xmm0, dword [rcx + WB_A]
    divss xmm0, [f_256]
    mulss xmm1, xmm0
    mov eax, [rcx + WB_COLOR]           ; each channel toward the light's
    mov edx, eax
    shr edx, 16
    and edx, 0xFF
    cvtsi2ss xmm0, edx
    subss xmm0, xmm3
    mulss xmm0, xmm1
    addss xmm3, xmm0
    mov edx, eax
    shr edx, 8
    and edx, 0xFF
    cvtsi2ss xmm0, edx
    subss xmm0, xmm4
    mulss xmm0, xmm1
    addss xmm4, xmm0
    mov edx, eax
    and edx, 0xFF
    cvtsi2ss xmm0, edx
    subss xmm0, xmm5
    mulss xmm0, xmm1
    addss xmm5, xmm0
.blob_next:
    inc ebp
    jmp .blob
.store:
    mulss xmm3, [f_256]                 ; 8.8
    mulss xmm4, [f_256]
    mulss xmm5, [f_256]
    cvtss2si eax, xmm3
    mov [r15], eax
    cvtss2si eax, xmm4
    mov [r15 + 4], eax
    cvtss2si eax, xmm5
    mov [r15 + 8], eax
    add r15, 12
    inc r12
    jmp .gx
.gy_next:
    inc r13
    jmp .gy
.grid_done:
    ; the screen: each row from the two grid rows around it, each pixel
    ; from the two points of that around it, with a dither
    xor r13d, r13d                      ; y
.row:
    cmp r13, [scr_h]
    jae .made
    mov rax, r13                        ; the grid rows, and the weight of
    shr rax, 2                          ; the lower one (0..3 quarters)
    mov rcx, r13
    and ecx, 3
    mov rsi, rax
    imul rsi, [wall_gw]
    imul rsi, rsi, 12
    add rsi, [wall_grid]                ; upper
    mov rdi, [wall_gw]
    imul rdi, rdi, 12
    add rdi, rsi                        ; lower
    lea r8, [wall_row]                  ; this row of the grid, 8.8
    mov r9, [wall_gw]
    imul r9, r9, 3                      ; values
    mov r10d, 4
    sub r10d, ecx                       ; upper's weight
.vrow:
    mov eax, [rsi]
    imul eax, r10d
    mov edx, [rdi]
    imul edx, ecx
    add eax, edx
    shr eax, 2
    mov [r8], eax
    add rsi, 4
    add rdi, 4
    add r8, 4
    dec r9
    jnz .vrow
    mov rdi, r13                        ; the pixels
    imul rdi, [wall_sf + SF_PITCH]
    add rdi, [wall_sf + SF_PTR]
    mov rax, r13
    and eax, 3
    lea r14, [bayer4]
    lea r14, [r14 + rax * 4]
    xor r12d, r12d                      ; x
    lea rsi, [wall_row]
.px:
    cmp r12, [scr_w]
    jae .row_next
    mov rcx, r12
    and ecx, 3                          ; the right one's weight
    mov r10d, 4
    sub r10d, ecx
    movzx r11d, byte [r14 + rcx]        ; the dither
    xor ebp, ebp                        ; the pixel
    xor edx, edx                        ; channel: R, G, B
.chan:
    mov eax, [rsi + rdx * 4]
    imul eax, r10d
    mov r8d, [rsi + rdx * 4 + 12]
    imul r8d, ecx
    add eax, r8d
    shr eax, 2
    add eax, r11d
    shr eax, 8
    cmp eax, 255
    jbe .chan_ok
    mov eax, 255
.chan_ok:
    shl ebp, 8
    or ebp, eax
    inc edx
    cmp edx, 3
    jb .chan
    mov [rdi], ebp
    add rdi, 4
    inc r12
    test r12, 3
    jnz .px
    add rsi, 12                         ; the next point
    jmp .px
.row_next:
    inc r13
    jmp .row
.made:
    mov rdi, [wall_grid]
    call vm_free
    mov qword [wall_grid], 0
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; XMM0 = t, EAX = from, EDX = to -> XMM3, XMM4, XMM5 = R, G, B (0..255)
.lerp_colors:
    push rcx
    mov ecx, 16
    call .lerp_one
    movss xmm3, xmm1
    mov ecx, 8
    call .lerp_one
    movss xmm4, xmm1
    xor ecx, ecx
    call .lerp_one
    movss xmm5, xmm1
    pop rcx
    ret
.lerp_one:
    push rax
    push rdx
    shr eax, cl
    and eax, 0xFF
    shr edx, cl
    and edx, 0xFF
    cvtsi2ss xmm1, eax
    cvtsi2ss xmm2, edx
    subss xmm2, xmm1
    mulss xmm2, xmm0
    addss xmm1, xmm2
    pop rdx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  theme: the thing in the shell
; -----------------------------------------------------------------------------

; theme: as it is, a record
theme_show:
    COLUMN 'look', FT_TEXT
    COLUMN 'accent', FT_TEXT
    COLUMN 'scale', FT_INT, 2
    push rdi
    mov edi, TBF_RECORD
    call rec_flag
    pop rdi
    call rec_row
    lea rsi, [str_th_dark]
    cmp byte [th_mode], TH_LIGHT
    jne .mode
    lea rsi, [str_th_light]
.mode:
    xor edi, edi
    call rec_str
    movzx eax, byte [th_accent_i]
    lea rsi, [accent_names]
    mov rsi, [rsi + rax * 8]
    mov edi, 1
    call rec_str
    mov eax, [ui_s4]                    ; quarters, as hundredths
    imul eax, eax, 25
    mov esi, eax
    mov edi, 2
    call rec_set
    clc
    ret

theme_dark:
    mov byte [th_mode], TH_DARK
    jmp theme_mode_set

theme_light:
    mov byte [th_mode], TH_LIGHT
theme_mode_set:
    mov edi, CFG_THEME                  ; kept, as display.theme
    movzx esi, byte [th_mode]
    call cfg_set_look
    jmp theme_changed

; theme accent <name>
theme_set_accent:
    cmp edi, 1
    jne .usage
    mov rdi, [rsi]
    xor ecx, ecx
.find:
    cmp ecx, ACCENTS
    jae .unknown
    lea rax, [accent_names]
    mov rsi, [rax + rcx * 8]
    push rcx
    push rdi
    call streq
    pop rdi
    pop rcx
    test eax, eax
    jnz .found
    inc ecx
    jmp .find
.found:
    mov [th_accent_i], cl
    mov edi, CFG_ACCENT                 ; kept, as display.accent
    lea rax, [accent_colors]
    mov esi, [rax + rcx * 8]
    call cfg_set_look
    jmp theme_changed
.unknown:
    KLOG "theme: no accent '%s' (blue, purple, pink, red, orange, yellow, green, teal, graphite)", rdi
    stc
    ret
.usage:
    KLOG "usage: theme accent <blue|purple|pink|red|orange|yellow|green|teal|graphite>"
    stc
    ret

; theme scale <4..8>: quarters of a pixel a point
theme_set_scale:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    call arg_uint
    jc .usage
    cmp eax, 4
    jb .usage
    cmp eax, 8
    ja .usage
    mov [ui_s4], eax
    mov edi, CFG_SCALE                  ; kept, as display.scale (1x: 1)
    lea esi, [eax - 3]
    call cfg_set_look
    jmp theme_changed
.usage:
    KLOG "usage: theme scale <4..8>: pixels a point, in quarters (4: 1, 6: 1.5, 8: 2)"
    stc
    ret

; the change made, then as it is now
theme_changed:
    call theme_apply
    jmp theme_show

section .rodata
align 4
f_0_25:         dd 0.25                 ; for wall_grad
f_0_75:         dd 0.75
f_256:          dd 256.0
f_1000:         dd 1000.0
str_th_dark:    db 'dark', 0
str_th_light:   db 'light', 0

; each TC_*, dark then light
th_dark_c:
    dd 0x1E1E20, 0x323236, 0x28282B, 0x0C0C0E    ; window, title, title off, sep
    dd 0xFFFFFF, 34                             ; edge
    dd 0xF2F2F7, 0x9A9AA0, 0x5E5E64             ; text 1, 2, 3
    dd 0x1E1E22, 150                            ; bar
    dd 0x2A2A2E, 140, 0xFFFFFF, 40              ; dock, its edge
    dd 150, 80                                  ; shadows
    dd 0x48484C                                 ; buttons off
    dd 0x2C2C30, 235, 0xF2F2F7                  ; tooltip
    dd 0x2A2A2E, 0x38383C                       ; panel, line
    dd 0x9A9AA0, 0x5E5E64, 0x32D74B, 0xFFD60A   ; dim, faint, good, warn
    dd 0xFF453A, 0x64D2FF, 0xFF9F0A, 0x5AC8FA   ; bad, blue, P-core, E-core
    dd 0xE5E5E5, 0xFFFFFF, 0xE5E510, 0xF5F543   ; xterm's white, bright, yellows
    dd 0xFFFFFF, 26                             ; hover
th_light_c:
    dd 0xFFFFFF, 0xEDEDF0, 0xF6F6F8, 0xD6D6DA
    dd 0x000000, 40
    dd 0x1D1D1F, 0x6E6E73, 0xAEAEB2
    dd 0xF4F4F6, 150
    dd 0xF4F4F6, 150, 0x000000, 26
    dd 90, 45
    dd 0xD4D4D8
    dd 0xF6F6F8, 240, 0x1D1D1F
    dd 0xF4F4F6, 0xE2E2E6
    dd 0x6E6E73, 0xAEAEB2, 0x248A3D, 0xB25000
    dd 0xD70015, 0x0071A4, 0xC93400, 0x0071A4
    dd 0x6E6E73, 0x1D1D1F, 0x8F7A00, 0x9E8600
    dd 0x000000, 20

; the colors text is written in, and the TC_* each is drawn in (-1: the
; accent); -1 ends it
theme_map:
    dd COL_TEXT, TC_TEXT
    dd COL_DIM, TC_T_DIM
    dd COL_FAINT, TC_T_FAINT
    dd COL_ACCENT, -1
    dd COL_BLUE, TC_T_BLUE
    dd COL_GOOD, TC_T_GOOD
    dd COL_WARN, TC_T_WARN
    dd COL_BAD, TC_T_BAD
    dd COL_PCORE, TC_T_PCORE
    dd COL_ECORE, TC_T_ECORE
    dd COL_PANEL, TC_WINDOW
    dd 0xE5E5E5, TC_T_WHITE
    dd 0xFFFFFF, TC_T_BRIGHT
    dd 0xE5E510, TC_T_YELLOW
    dd 0xF5F543, TC_T_YELLOW2
    dd -1, -1

; the nine accents (graphite last, as icons.asm has it): dark shade, light shade
accent_colors:
    dd 0x0A84FF, 0x007AFF               ; blue
    dd 0xBF5AF2, 0xAF52DE               ; purple
    dd 0xFF375F, 0xFF2D55               ; pink
    dd 0xFF453A, 0xFF3B30               ; red
    dd 0xFF9F0A, 0xFF9500               ; orange
    dd 0xFFD60A, 0xFFCC00               ; yellow
    dd 0x30D158, 0x28CD41               ; green
    dd 0x40C8E0, 0x30B0C7               ; teal
    dd 0x98989D, 0x8E8E93               ; graphite
align 8
accent_names:
    dq str_ac_blue, str_ac_purple, str_ac_pink, str_ac_red
    dq str_ac_orange, str_ac_yellow, str_ac_green, str_ac_teal, str_ac_graphite
str_ac_blue:    db 'blue', 0
str_ac_purple:  db 'purple', 0
str_ac_pink:    db 'pink', 0
str_ac_red:     db 'red', 0
str_ac_orange:  db 'orange', 0
str_ac_yellow:  db 'yellow', 0
str_ac_green:   db 'green', 0
str_ac_teal:    db 'teal', 0
str_ac_graphite: db 'graphite', 0

; the gradient wallpapers, as desktop.wallpaper's choices after the first
; (mountains: wall.asm) have them (settings.asm, cfg_walls): for each, the
; dark theme's and the light's
WALLS           equ 5
align 8
walls:          dq grad_aurora_dark, grad_aurora_light            ; aurora
                dq grad_plain_dark, grad_plain_light
                dq grad_dusk, grad_dusk
                dq grad_ocean, grad_ocean
                dq grad_graphite, grad_graphite

; aurora: night, a deep blue going violet, with lights of indigo, teal and
; rose; day, a pale lilac going blue, with peach, sky and mint
align 4
grad_aurora_dark:
    dd 0x0B1030, 0x150A2A
    dd 180, 260, 520, 0x3B2FB0, 230
    dd 820, 220, 460, 0x0E7490, 200
    dd 560, 920, 560, 0x7C2D92, 210
    dd 980, 980, 380, 0xD9466F, 150
    dd 420, 480, 300, 0x1D4ED8, 110
grad_aurora_light:
    dd 0xEDE7FB, 0xDCEBFB
    dd 160, 220, 520, 0xFFD2B8, 230
    dd 840, 260, 460, 0xB8E0FF, 230
    dd 560, 940, 560, 0xD8C7FF, 220
    dd 960, 960, 380, 0xC4F1E1, 200
    dd 420, 520, 320, 0xFFE7C2, 120
grad_plain_dark:                        ; one colour, no lights
    dd COL_BG, COL_BG
    times WALL_BLOBS dd 0, 0, 1, 0, 0
grad_plain_light:
    dd 0xE5E5EA, 0xE5E5EA
    times WALL_BLOBS dd 0, 0, 1, 0, 0
grad_dusk:                              ; violet into coral, a warm light low
    dd 0x231C42, 0xC9736A
    dd 780, 900, 520, 0xF2A65A, 120
    dd 200, 200, 420, 0x4B2A7B, 140
    times WALL_BLOBS - 2 dd 0, 0, 1, 0, 0
grad_ocean:                             ; deep into shallow, light from above
    dd 0x0A2342, 0x2C8BA6
    dd 500, 0, 620, 0x3FB8C9, 110
    dd 150, 950, 480, 0x06304F, 160
    times WALL_BLOBS - 2 dd 0, 0, 1, 0, 0
grad_graphite:
    dd 0x1C1C1E, 0x58585E
    times WALL_BLOBS dd 0, 0, 1, 0, 0

section .data
align 8
themes_actions:
    ACTION  '',       theme_show,   '', 'how the desktop looks: light or dark, its accent, its scale'
    ACTION  'dark',   theme_dark,   '', 'the dark look'
    ACTION  'light',  theme_light,  '', 'the light look'
    ACTION  'accent', theme_set_accent, '<color>', 'the accent: blue, purple, pink, red, orange, yellow, green, teal or graphite'
    ACTION  'scale',  theme_set_scale, '<4..8>', 'pixels a point, in quarters'
    dq 0, 0, 0, 0, 0

section .bss
alignb 8
ui_s4:          resd 1                  ; quarters of a pixel a point
th_mode:        resb 1                  ; TH_*
th_accent_i:    resb 1                  ; which accent
th_wall:        resb 1                  ; which wallpaper: 0 mountains, else walls
alignb 4
th_auto_s4:     resd 1                  ; ui_s4 for this screen (display.scale auto)
th_accent:      resd 1                  ; its color in this theme
th_c:           resd TC_COUNT / 4
alignb 8
wall_grid:      resq 1                  ; wall_grad's: its grid of points,
wall_gw:        resq 1                  ; how wide,
wall_gh:        resq 1                  ; how tall
wall_row:       resd (4096 / 4 + 4) * 3 ; a row of it, 8.8
