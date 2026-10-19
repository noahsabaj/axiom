; =============================================================================
;  theme.asm - how the desktop looks: light or dark, an accent color, the
;  scale it is drawn at, and the wallpaper.
;
;  Colors have names (TC_*): the desktop and the windows draw with th_c +
;  TC_*, never with a color of their own, so a theme changes all of them.
;  The accent (th_accent) is one of eight, each with a light and a dark
;  shade. Text a terminal was given keeps the color it was written in (the
;  dark theme's COL_*); theme_color says what each of those is now.
;
;  The scale: one point is ui_s4 / 4 pixels, so a 2560x1600 screen is drawn
;  as 1280x800 points, and a 1920x1080 one at 1.25 pixels a point. pt()
;  turns points into pixels. Measures in this file and desk.asm are points.
;
;  The wallpaper is in wall.asm.
;
;  In the shell, 'theme' is a thing: theme (as it is), theme dark, theme
;  light, theme accent <name>, theme scale <1..2 in quarters: 4..8>.
; =============================================================================

; TH_* and the colors' names, TC_*, are in defs.inc: programs see them
; in the look (LK_C)

ACCENTS         equ 8

section .text

; theme_init: the scale for this screen, and the dark theme with the blue
; accent. Before desk_init.
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
    mov [ui_s4], eax
    mov byte [th_mode], TH_DARK
    mov byte [th_accent_i], 0
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
    jmp theme_changed

theme_light:
    mov byte [th_mode], TH_LIGHT
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
    jmp theme_changed
.unknown:
    KLOG "theme: no accent '%s' (blue, purple, pink, red, orange, yellow, green, graphite)", rdi
    stc
    ret
.usage:
    KLOG "usage: theme accent <blue|purple|pink|red|orange|yellow|green|graphite>"
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

; the eight accents: dark shade, light shade
accent_colors:
    dd 0x0A84FF, 0x007AFF               ; blue
    dd 0xBF5AF2, 0xAF52DE               ; purple
    dd 0xFF375F, 0xFF2D55               ; pink
    dd 0xFF453A, 0xFF3B30               ; red
    dd 0xFF9F0A, 0xFF9500               ; orange
    dd 0xFFD60A, 0xFFCC00               ; yellow
    dd 0x30D158, 0x28CD41               ; green
    dd 0x98989D, 0x8E8E93               ; graphite
align 8
accent_names:
    dq str_ac_blue, str_ac_purple, str_ac_pink, str_ac_red
    dq str_ac_orange, str_ac_yellow, str_ac_green, str_ac_graphite
str_ac_blue:    db 'blue', 0
str_ac_purple:  db 'purple', 0
str_ac_pink:    db 'pink', 0
str_ac_red:     db 'red', 0
str_ac_orange:  db 'orange', 0
str_ac_yellow:  db 'yellow', 0
str_ac_green:   db 'green', 0
str_ac_graphite: db 'graphite', 0

section .data
align 8
themes_actions:
    ACTION  '',       theme_show,   '', 'how the desktop looks: light or dark, its accent, its scale'
    ACTION  'dark',   theme_dark,   '', 'the dark look'
    ACTION  'light',  theme_light,  '', 'the light look'
    ACTION  'accent', theme_set_accent, '<color>', 'the accent: blue, purple, pink, red, orange, yellow, green or graphite'
    ACTION  'scale',  theme_set_scale, '<4..8>', 'pixels a point, in quarters'
    dq 0, 0, 0, 0, 0

section .bss
alignb 8
ui_s4:          resd 1                  ; quarters of a pixel a point
th_mode:        resb 1                  ; TH_*
th_accent_i:    resb 1                  ; which accent
alignb 4
th_accent:      resd 1                  ; its color in this theme
th_c:           resd TC_COUNT / 4
