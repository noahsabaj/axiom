; =============================================================================
;  settings.asm - the machine's settings: typed, named, kept on the boot stick
;
;  Each setting (cfg_table, SD_*) has a name (display.theme), a kind (SK_*:
;  a choice, a switch, a number, a colour, an offset from UTC, a word), a
;  default, what it takes, a line saying what it is, and a function that
;  makes a change take effect (SD_APPLY, on the main thread). The values are
;  cfg_vals (a qword each, read by whatever they steer) and, for words,
;  cfg_texts.
;
;  A change (cfg_change) comes from the shell ('settings set'), from a
;  program holding the settings by capability (OT_SETTINGS: RO_SET_CHANGE),
;  or from the file at boot. It is noted for the main loop (cfg_pending),
;  which applies it (cfg_service) and, a second after the last change,
;  writes every setting that is not its default to SETTINGS.TXT at the top
;  of the boot stick, beside AXIOM.LOG, by the same rule as the log: that
;  stick alone, and no other file on it. The file is read once the stick is
;  there; a setting changed before that keeps its new value.
;
;  Every program's settings object hears of every change: RO_WAIT on it
;  completes once something changed since it last listed them (SG_CHANGED),
;  so an open Settings window follows the shell, and the shell the window.
; =============================================================================

CFG_TEXT_MAX    equ 64                  ; a word's value, NUL included
CFG_FILE_MAX    equ 8192
CFG_SAVE_MS     equ 1000                ; written this long after the last change
CFG_NOTIFY_MAX  equ 32                  ; settings objects told at once

SD_NAME         equ 0                   ; a setting: its name,
SD_KIND         equ 8                   ; byte SK_*,
SD_FLAGS        equ 9                   ; byte SIF_RESTART or 0,
SD_ABOUT        equ 16                  ; what it is,
SD_DEFAULT      equ 24                  ; its default (a word's: its text),
SD_MIN          equ 32                  ; a number's or a zone's range and step;
SD_MAX          equ 40                  ; for a word, SD_STEP says which words
SD_STEP         equ 48                  ; it takes (CW_*)
SD_LIST         equ 56                  ; a choice's names (0-ended), or a
                                        ; colour's swatches (name, 0xRRGGBB pairs)
SD_UNIT         equ 64                  ; a number's unit ('' for none)
SD_APPLY        equ 72                  ; (RDI = the value) on the main thread, or 0
SD_SIZE         equ 80

CW_HOST         equ 1                   ; a host name: letters, digits and -
CW_IPV4         equ 2                   ; automatic, or a.b.c.d/n [router] [dns]
CW_WORD         equ 3                   ; printable, no spaces or quotes

SG_CHANGED      equ OB_SIZE             ; dword: 1 once a setting changed
SG_WQ           equ OB_SIZE + 8         ; WQ_SIZE: rings waiting for that
SG_SIZE         equ SG_WQ + WQ_SIZE

%assign cfg_n 0

; SETTING id, 'name', kind, flags, default, min, max, step, list, 'unit',
; apply, 'about'
%macro SETTING 12
%1 equ cfg_n
%assign cfg_n cfg_n + 1
    dq %%name
    db %3, %4, 0, 0, 0, 0, 0, 0
    dq %%about, %5, %6, %7, %8, %9, %%unit, %11
    [section .rodata]
    %%name: db %2, 0
    %%unit: db %10, 0
    %%about: db %12, 0
    __SECT__
%endmacro

; The tables are in .data so that the macros' strings, in .rodata, stay
; out of them.
section .data
align 8
cfg_table:
    SETTING CFG_THEME, 'display.theme', SK_CHOICE, 0, 0, 0, 0, 0, cfg_themes, '', cfg_apply_look, \
        'the look of windows and the bar: dark or light'
    SETTING CFG_ACCENT, 'display.accent', SK_COLOUR, 0, 0x0A84FF, 0, 0, 0, cfg_accents, '', cfg_apply_look, \
        'the colour of the prompt, of headings and of what is chosen'
    SETTING CFG_TEXT_SIZE, 'display.text-size', SK_CHOICE, SIF_RESTART, 0, 0, 0, 0, cfg_sizes, '', 0, \
        'the size of text, and of the bar and the frames with it (auto: the largest that leaves 50 lines)'
    SETTING CFG_SCALE, 'display.scale', SK_CHOICE, 0, 0, 0, 0, 0, cfg_scales, '', cfg_apply_look,         "the size the desktop is drawn at: its bar, dock and windows (auto: the screen's own)"
    SETTING CFG_WALLPAPER, 'desktop.wallpaper', SK_CHOICE, 0, 0, 0, 0, 0, cfg_walls, '', cfg_apply_look, \
        'what is behind the windows'
    SETTING CFG_CLOCK, 'desktop.clock', SK_CHOICE, 0, 0, 0, 0, 0, cfg_clocks, '', cfg_apply_clock, \
        'the clock at the right end of the bar'
    SETTING CFG_DEMO, 'desktop.demo', SK_SWITCH, 0, 1, 0, 1, 1, 0, '', cfg_apply_demo, \
        "the Mandelbrot zoom, from the start ('demo' pauses it for now)"
    SETTING CFG_REPEAT_DELAY, 'keyboard.repeat-delay', SK_NUMBER, 0, 500, 150, 2000, 50, 0, 'ms', 0, \
        'how long a key is held before it repeats'
    SETTING CFG_REPEAT_RATE, 'keyboard.repeat-rate', SK_NUMBER, 0, 30, 2, 60, 1, 0, '/s', 0, \
        'how fast a held key repeats'
    SETTING CFG_LAYOUT, 'keyboard.layout', SK_CHOICE, 0, 0, 0, 0, 0, cfg_layouts, '', 0, \
        'what each key types'
    SETTING CFG_POINTER_SPEED, 'pointer.speed', SK_NUMBER, 0, 5, 1, 10, 1, 0, '', 0, \
        'how far the pointer goes for a move of the mouse'
    SETTING CFG_NATURAL, 'pointer.natural-scrolling', SK_SWITCH, 0, 0, 0, 1, 1, 0, '', 0, \
        'the wheel moves what is shown rather than the view'
    SETTING CFG_ZONE, 'time.zone', SK_ZONE, 0, 0, -720, 840, 30, 0, '', cfg_apply_zone, \
        "how far from UTC the machine's clock is (Windows keeps it in local time)"
    SETTING CFG_HOST, 'network.name', SK_TEXT, 0, str_cfg_axiom, 0, 0, CW_HOST, 0, '', 0, \
        "this machine's name, as DHCP and Linux programs are told it"
    SETTING CFG_IPV4, 'network.ipv4', SK_TEXT, 0, str_cfg_automatic, 0, 0, CW_IPV4, 0, '', cfg_apply_ipv4, \
        'automatic (from DHCP), or an address by hand: a.b.c.d/n [router] [dns]'
    SETTING CFG_IPV6_FIRST, 'network.ipv6-first', SK_SWITCH, 0, 0, 0, 1, 1, 0, '', cfg_apply_ipv6, \
        'IPv6 before IPv4, for a name that has both'
    SETTING CFG_POWER_BUTTON, 'power.button', SK_CHOICE, 0, 0, 0, 0, 0, cfg_buttons, '', 0, \
        'what pressing the power button does'
    SETTING CFG_LOG, 'system.log', SK_SWITCH, 0, 1, 0, 1, 1, 0, '', cfg_apply_log, \
        "AXIOM.LOG on the boot stick, saved every 10 s ('log off' stops it for now)"
    SETTING CFG_MODEL, 'claude.model', SK_TEXT, 0, cfg_model_default, 0, 0, CW_WORD, 0, '', cfg_apply_model, \
        "the model 'ask' talks to"
cfg_table_end:
CFG_COUNT       equ cfg_n

%macro CNAME 1
    dq %%s
    [section .rodata]
    %%s: db %1, 0
    __SECT__
%endmacro

%macro SWATCH 2
    dq %%s, %2
    [section .rodata]
    %%s: db %1, 0
    __SECT__
%endmacro

align 8
cfg_themes:     CNAME 'dark'
                CNAME 'light'
                dq 0
cfg_sizes:      CNAME 'auto'
                CNAME 'small'
                CNAME 'medium'
                CNAME 'large'
                dq 0
cfg_scales:     CNAME 'auto'             ; theme.asm's ui_s4: 1x is 4
                CNAME '1x'
                CNAME '1.25x'
                CNAME '1.5x'
                CNAME '1.75x'
                CNAME '2x'
                dq 0
cfg_walls:      CNAME 'mountains'                   ; wall.asm's
                CNAME 'aurora'                      ; and theme.asm's walls
                CNAME 'plain'
                CNAME 'dusk'
                CNAME 'ocean'
                CNAME 'graphite'
                dq 0
cfg_clocks:     CNAME '24-hour'
                CNAME '12-hour'
                CNAME 'off'
                dq 0
cfg_layouts:    CNAME 'us'
                CNAME 'dvorak'
                CNAME 'colemak'
                dq 0
cfg_buttons:    CNAME 'off'
                CNAME 'restart'
                CNAME 'nothing'
                dq 0
cfg_accents:    SWATCH 'blue', 0x0A84FF ; theme.asm's accents, in accent_colors'
                SWATCH 'purple', 0xBF5AF2 ; order (their dark shades)
                SWATCH 'pink', 0xFF375F
                SWATCH 'red', 0xFF453A
                SWATCH 'orange', 0xFF9F0A
                SWATCH 'yellow', 0xFFD60A
                SWATCH 'green', 0x30D158
                SWATCH 'teal', 0x40C8E0
                SWATCH 'graphite', 0x98989D
                dq 0, 0


CW_ANY_TEXT     equ 0
CFG_LIST_MAX    equ 16                  ; choices or swatches, at most

section .text

; -----------------------------------------------------------------------------
;  Values
; -----------------------------------------------------------------------------

; cfg_init: every setting at its default, then as SETTINGS.TXT has it when
; the loader found one; the look from them. Before anything reads one.
cfg_init:
    push rbx
    push rdi
    push rsi
    xor ebx, ebx
.next:
    cmp ebx, CFG_COUNT
    jae .done
    imul rdi, rbx, SD_SIZE
    lea rsi, [cfg_table]
    add rdi, rsi
    mov rax, [rdi + SD_DEFAULT]
    cmp byte [rdi + SD_KIND], SK_TEXT
    jne .value
    mov rsi, rax                        ; a word: its text
    mov rdi, rbx
    shl rdi, 6                          ; CFG_TEXT_MAX
    lea rax, [cfg_texts]
    add rdi, rax
    mov ecx, CFG_TEXT_MAX
    call rec_copyz
    xor eax, eax
.value:
    mov [cfg_vals + rbx * 8], rax
    inc ebx
    jmp .next
.done:
    mov rax, [boot_info]                ; SETTINGS.TXT, as the loader read it
    cmp word [rax + BI_EXT], BI_SETTINGS_LEN + 8 ; (a loader from before it: none)
    jb .looked
    mov rcx, [rax + BI_SETTINGS_LEN]
    mov rsi, [rax + BI_SETTINGS]
    test rcx, rcx
    jz .looked
    test rsi, rsi
    jz .looked
    cmp rcx, CFG_FILE_MAX - 1
    jbe .fits
    mov ecx, CFG_FILE_MAX - 1
.fits:
    add rsi, [phys_base]
    lea rdi, [cfg_file]
    mov byte [rdi + rcx], 0
    rep movsb
    push r12
    push r13
    push r15
    call cfg_read_text
    mov [cfg_early_n], r12
    pop r15
    pop r13
    pop r12
    mov byte [cfg_early], 1
    mov qword [cfg_touched], 0          ; (as if they had been the defaults)
.looked:                                ; (theme_init takes the look from them)
    pop rsi
    pop rdi
    pop rbx
    ret

; cfg_desc(EDI = a setting) -> RAX = its description. Preserves others.
cfg_desc:
    mov eax, edi
    imul eax, eax, SD_SIZE
    push rcx
    lea rcx, [cfg_table]
    add rax, rcx
    pop rcx
    ret

; cfg_text(EDI = a setting) -> RAX = its word (cfg_texts). Preserves others.
cfg_text:
    mov eax, edi
    shl eax, 6
    push rcx
    lea rcx, [cfg_texts]
    add rax, rcx
    pop rcx
    ret

; cfg_find(RSI = a name) -> EAX = the setting; CF if there is none.
; Case aside. Preserves others.
cfg_find:
    push rcx
    push rdi
    xor ecx, ecx
.next:
    cmp ecx, CFG_COUNT
    jae .none
    mov edi, ecx
    call cfg_desc
    mov rdi, [rax + SD_NAME]
    call rec_ieq
    test eax, eax
    jnz .found
    inc ecx
    jmp .next
.found:
    mov eax, ecx
    clc
    jmp .out
.none:
    stc
.out:
    pop rdi
    pop rcx
    ret

; cfg_choices(RAX = a description) -> ECX = how many choices or swatches
; it has. Preserves others.
cfg_choices:
    push rdx
    push rsi
    xor ecx, ecx
    mov rsi, [rax + SD_LIST]
    test rsi, rsi
    jz .out
    mov edx, 8                          ; a choice: a name each
    cmp byte [rax + SD_KIND], SK_COLOUR
    jne .next
    mov edx, 16                         ; a swatch: a name and a colour
.next:
    cmp qword [rsi], 0
    je .out
    inc ecx
    add rsi, rdx
    jmp .next
.out:
    pop rsi
    pop rdx
    ret

; cfg_check(EDI = a setting, RSI = a value) -> CF if it does not take it.
; Preserves all.
cfg_check:
    push rax
    push rcx
    call cfg_desc
    movzx ecx, byte [rax + SD_KIND]
    cmp ecx, SK_CHOICE
    je .choice
    cmp ecx, SK_COLOUR
    je .colour
    cmp ecx, SK_TEXT
    je .bad
    cmp rsi, [rax + SD_MIN]             ; a switch, a number, a zone
    jl .bad
    cmp rsi, [rax + SD_MAX]
    jg .bad
    jmp .ok
.choice:
    call cfg_choices
    cmp rsi, rcx
    jae .bad
    jmp .ok
.colour:
    cmp rsi, 0xFFFFFF
    ja .bad
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop rcx
    pop rax
    ret

; cfg_is_default(EDI = a setting) -> ZF if it is at its default.
; Preserves all.
cfg_is_default:
    push rax
    push rsi
    push rdi
    call cfg_desc
    cmp byte [rax + SD_KIND], SK_TEXT
    je .text
    mov rsi, [rax + SD_DEFAULT]
    mov eax, edi
    cmp rsi, [cfg_vals + rax * 8]
    jmp .out
.text:
    mov rsi, [rax + SD_DEFAULT]
    call cfg_text
    mov rdi, rax
    call streq
    cmp eax, 1
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; cfg_change(EDI = a setting, RSI = its value, RDX = a word's text, or 0)
; -> EAX = 1 if that changed it: kept, noted for the main loop, and told
; to every settings object. Checked already. Any thread. Preserves others.
cfg_change:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, edi
    pushfq
    cli
    lea rdi, [cfg_lock]
    call spin_lock
    mov edi, ebx
    call cfg_desc
    cmp byte [rax + SD_KIND], SK_TEXT
    je .text
    cmp [cfg_vals + rbx * 8], rsi
    je .same
    mov [cfg_vals + rbx * 8], rsi
    jmp .changed
.text:
    call cfg_text
    mov rdi, rax
    mov rsi, rdx
    call streq
    test eax, eax
    jnz .same
    mov ecx, CFG_TEXT_MAX
    call rec_copyz
.changed:
    lock bts qword [cfg_touched], rbx
    lock bts qword [cfg_pending], rbx
    mov byte [cfg_dirty], 1
    inc qword [cfg_gen]
    RDTSC64
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, CFG_SAVE_MS
    add rax, rcx
    mov [cfg_save_at], rax
    lea rdi, [cfg_lock]
    call spin_unlock
    popfq
    call cfg_notify
    mov rdi, [main_thread]              ; to be applied, and kept
    test rdi, rdi
    jz .told
    call thread_unpark
.told:
    mov eax, 1
    jmp .out
.same:
    lea rdi, [cfg_lock]
    call spin_unlock
    popfq
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; cfg_reset(EDI = a setting) -> EAX = 1 if it was not at its default.
; Preserves others.
cfg_reset:
    push rdx
    push rsi
    call cfg_desc
    mov rsi, [rax + SD_DEFAULT]
    xor edx, edx
    cmp byte [rax + SD_KIND], SK_TEXT
    jne .set
    mov rdx, rsi
    xor esi, esi
.set:
    call cfg_change
    pop rsi
    pop rdx
    ret

; cfg_notify: every settings object hears that something changed, and what
; waits on one wakes. Preserves all.
cfg_notify:
    push rax
    push rbx
    push rcx
    push rdi
    sub rsp, CFG_NOTIFY_MAX * 8
    xor ebx, ebx                        ; found, with a reference each
    pushfq
    cli
    lea rdi, [ty_settings + TY_LOCK]
    call spin_lock
    mov rax, [ty_settings + TY_LIST]
.find:
    test rax, rax
    jz .found
    cmp ebx, CFG_NOTIFY_MAX
    jae .found
    mov rdi, rax
    call obj_tryget
    jc .skip
    mov [rsp + 8 + rbx * 8], rdi        ; (past the flags pushed)
    inc ebx
.skip:
    mov rax, [rax + OB_NEXT]
    jmp .find
.found:
    lea rdi, [ty_settings + TY_LOCK]
    call spin_unlock
    popfq
    xor ecx, ecx
.tell:
    cmp ecx, ebx
    jae .done
    mov rdi, [rsp + rcx * 8]
    mov dword [rdi + SG_CHANGED], 1
    push rdi
    lea rdi, [rdi + SG_WQ]
    call wq_wake
    pop rdi
    call obj_put
    inc ecx
    jmp .tell
.done:
    add rsp, CFG_NOTIFY_MAX * 8
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Text: a value read, shown, and what a setting takes
; -----------------------------------------------------------------------------

; cfg_parse(EDI = a setting, RSI = text, which a word's check may rewrite
; in place) -> RAX = the value it reads as (0 for a word); CF if the
; setting does not take it. Preserves others.
cfg_parse:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8d, edi
    call cfg_desc
    mov rbx, rax
    movzx ecx, byte [rbx + SD_KIND]
    cmp ecx, SK_CHOICE
    je .choice
    cmp ecx, SK_SWITCH
    je .switch
    cmp ecx, SK_NUMBER
    je .number
    cmp ecx, SK_COLOUR
    je .colour
    cmp ecx, SK_ZONE
    je .zone
    mov edi, [rbx + SD_STEP]            ; a word
    call cfg_word_ok
    jc .bad
    xor eax, eax
    jmp .ok
.choice:
    mov rdx, [rbx + SD_LIST]
    xor ecx, ecx
.choice_next:
    mov rdi, [rdx + rcx * 8]
    test rdi, rdi
    jz .bad
    call rec_ieq
    test eax, eax
    jnz .choice_found
    inc ecx
    jmp .choice_next
.choice_found:
    mov eax, ecx
    jmp .ok
.switch:
    lea rdx, [cfg_switch_words]
.switch_next:
    mov rdi, [rdx]
    test rdi, rdi
    jz .bad
    call rec_ieq
    test eax, eax
    jnz .switch_found
    add rdx, 16
    jmp .switch_next
.switch_found:
    mov rax, [rdx + 8]
    jmp .ok
.number:
    call rec_uint
    jc .bad
    mov rdx, rax
    call cfg_skip_spaces
    cmp byte [rsi], 0
    je .number_ok
    mov rdi, [rbx + SD_UNIT]            ; its unit may follow
    cmp byte [rdi], 0
    je .bad
    call rec_ieq
    test eax, eax
    jz .bad
.number_ok:
    mov rax, rdx
    jmp .range
.colour:
    mov rdx, [rbx + SD_LIST]
.swatch:
    mov rdi, [rdx]
    test rdi, rdi
    jz .hex
    call rec_ieq
    test eax, eax
    jnz .swatch_found
    add rdx, 16
    jmp .swatch
.swatch_found:
    mov rax, [rdx + 8]
    jmp .ok
.hex:
    cmp byte [rsi], '#'
    jne .hex_digits
    inc rsi
.hex_digits:
    xor eax, eax
    xor ecx, ecx
.hex_next:
    movzx edx, byte [rsi]
    test edx, edx
    jz .hex_end
    call cfg_hex_digit
    jc .bad
    shl eax, 4
    or eax, edx
    inc rsi
    inc ecx
    cmp ecx, 6
    ja .bad
    jmp .hex_next
.hex_end:
    cmp ecx, 6
    jne .bad
    jmp .ok
.zone:
    call cfg_parse_zone
    jc .bad
.range:
    mov rsi, rax
    mov edi, r8d
    call cfg_check
    jc .bad
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; cfg_skip_spaces(RSI) -> RSI past any spaces. Preserves others.
cfg_skip_spaces:
    cmp byte [rsi], ' '
    jne .out
    inc rsi
    jmp cfg_skip_spaces
.out:
    ret

; cfg_hex_digit(EDX = a character) -> EDX = its value; CF if it is not a
; hex digit. Preserves others.
cfg_hex_digit:
    sub edx, '0'
    cmp edx, 9
    jbe .ok
    or edx, 0x20                        ; (a letter, lower case)
    sub edx, 'a' - '0'
    cmp edx, 5
    ja .bad
    add edx, 10
.ok:
    clc
    ret
.bad:
    stc
    ret

; cfg_parse_zone(RSI = text: UTC, UTC+2, +02:00, -5, UTC-03:30, +0530) ->
; RAX = minutes east of UTC; CF if it is none of those. Preserves others.
cfg_parse_zone:
    push rcx
    push rdx
    push rsi
    mov al, [rsi]                       ; UTC or GMT first, perhaps
    or al, 0x20
    cmp al, 'u'
    je .prefix
    cmp al, 'g'
    jne .sign
.prefix:
    mov al, [rsi + 1]
    or al, 0x20
    cmp al, 'm'
    je .second
    cmp al, 't'
    jne .bad
.second:
    mov al, [rsi + 2]
    or al, 0x20
    cmp al, 't'
    je .third
    cmp al, 'c'
    jne .bad
.third:
    add rsi, 3
    xor eax, eax
    cmp byte [rsi], 0
    je .ok
.sign:
    xor ecx, ecx                        ; ECX = 1 if west
    cmp byte [rsi], '+'
    je .signed
    cmp byte [rsi], '-'
    jne .bad
    inc ecx
.signed:
    inc rsi
    push rsi
    call rec_uint                       ; hours (or hhmm)
    pop rdx
    jc .bad
    sub rdx, rsi
    neg rdx                             ; RDX = its digits
    cmp edx, 4
    je .hhmm
    cmp edx, 2
    ja .bad
    imul eax, eax, 60
    cmp byte [rsi], ':'
    jne .end
    inc rsi
    push rax
    push rsi
    call rec_uint                       ; minutes
    pop rdx
    jc .bad_pop
    sub rdx, rsi
    cmp rdx, -2
    jne .bad_pop
    cmp eax, 59
    ja .bad_pop
    pop rdx
    add eax, edx
    jmp .end
.hhmm:
    xor edx, edx
    push rcx
    mov ecx, 100
    div ecx
    pop rcx
    cmp edx, 59
    ja .bad
    imul eax, eax, 60
    add eax, edx
.end:
    cmp byte [rsi], 0
    jne .bad
    test ecx, ecx
    jz .ok
    neg rax
.ok:
    clc
    jmp .out
.bad_pop:
    pop rax
.bad:
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; cfg_word_ok(EDI = CW_*, RSI = text) -> CF if it is not such a word; one
; that is may be written again in its usual form (automatic, lower case).
; Preserves all.
cfg_word_ok:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    xor ecx, ecx                        ; its length
.measure:
    cmp byte [rsi + rcx], 0
    je .measured
    inc ecx
    jmp .measure
.measured:
    test ecx, ecx
    jz .bad
    cmp ecx, CFG_TEXT_MAX - 1
    jae .bad
    cmp edi, CW_HOST
    je .host
    cmp edi, CW_IPV4
    je .ipv4
    xor ecx, ecx                        ; any word: printable, no spaces
.word:
    mov al, [rsi + rcx]
    test al, al
    jz .ok
    cmp al, ' '
    jbe .bad
    cmp al, '"'
    je .bad
    cmp al, '\'
    je .bad
    cmp al, '~'
    ja .bad
    inc ecx
    jmp .word
.host:                                  ; letters, digits, - (not at an end)
    cmp byte [rsi], '-'
    je .bad
    cmp byte [rsi + rcx - 1], '-'
    je .bad
.host_next:
    mov al, [rsi]
    test al, al
    jz .ok
    inc rsi
    cmp al, '-'
    je .host_next
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .host_next
    or al, 0x20
    cmp al, 'a'
    jb .bad
    cmp al, 'z'
    jbe .host_next
    jmp .bad
.ipv4:
    lea rdi, [str_cfg_automatic]
    call rec_ieq
    test eax, eax
    jz .address
    mov rdi, rsi                        ; written as it is spelt
    lea rsi, [str_cfg_automatic]
    mov ecx, CFG_TEXT_MAX
    call rec_copyz
    jmp .ok
.address:
    call ip_parse                       ; a.b.c.d/n
    jc .bad
    cmp byte [rsi], '/'
    jne .bad
    inc rsi
    push rsi
    call rec_uint
    pop rdx
    jc .bad
    test eax, eax
    jz .bad
    cmp eax, 32
    ja .bad
    mov ecx, 2                          ; then a router and a DNS server, perhaps
.more:
    cmp byte [rsi], 0
    je .ok
    cmp byte [rsi], ' '
    jne .bad
    call cfg_skip_spaces
    cmp byte [rsi], 0
    je .ok
    test ecx, ecx
    jz .bad
    call ip_parse
    jc .bad
    dec ecx
    jmp .more
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; cfg_show(EDI = a setting, RSI = a value, RDX = a word's text, RCX = room
; for CFG_TEXT_MAX bytes): the value as the shell shows it. Preserves all.
cfg_show:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rcx
    call cfg_desc
    mov rbx, rax
    movzx eax, byte [rbx + SD_KIND]
    cmp eax, SK_CHOICE
    je .choice
    cmp eax, SK_SWITCH
    je .switch
    cmp eax, SK_NUMBER
    je .number
    cmp eax, SK_COLOUR
    je .colour
    cmp eax, SK_ZONE
    je .zone
    mov rsi, rdx                        ; a word
    jmp .copy
.choice:
    mov rax, [rbx + SD_LIST]
    mov rsi, [rax + rsi * 8]
    jmp .copy
.switch:
    lea rax, [str_cfg_on]
    test rsi, rsi
    lea rsi, [str_cfg_off]
    cmovnz rsi, rax
    jmp .copy
.number:
    mov rax, [rbx + SD_UNIT]
    cmp byte [rax], 0
    je .bare
    SPRINTF r8, "%d %s", rsi, rax
    jmp .out
.bare:
    SPRINTF r8, "%d", rsi
    jmp .out
.colour:
    mov rax, [rbx + SD_LIST]            ; a swatch's name, if it is one
.swatch:
    cmp qword [rax], 0
    je .hex
    cmp [rax + 8], rsi
    je .named
    add rax, 16
    jmp .swatch
.named:
    mov rsi, [rax]
    jmp .copy
.hex:
    SPRINTF r8, "#%06x", rsi
    jmp .out
.zone:
    test rsi, rsi
    jnz .offset
    lea rsi, [str_cfg_utc]
    jmp .copy
.offset:
    mov ecx, '+'
    mov rax, rsi
    test rax, rax
    jns .east
    mov ecx, '-'
    neg rax
.east:
    xor edx, edx
    push rcx
    mov ecx, 60
    div rcx
    pop rcx
    SPRINTF r8, "UTC%c%02u:%02u", rcx, rax, rdx
    jmp .out
.copy:
    mov rdi, r8
    mov ecx, CFG_TEXT_MAX
    call rec_copyz
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cfg_show_now(EDI = a setting, RCX = room): its value now. Preserves all.
cfg_show_now:
    push rax
    push rdx
    push rsi
    call cfg_text
    mov rdx, rax
    mov eax, edi
    mov rsi, [cfg_vals + rax * 8]
    call cfg_show
    pop rsi
    pop rdx
    pop rax
    ret

; cfg_show_default(EDI = a setting, RCX = room). Preserves all.
cfg_show_default:
    push rax
    push rdx
    push rsi
    call cfg_desc
    mov rsi, [rax + SD_DEFAULT]
    mov rdx, rsi
    call cfg_show
    pop rsi
    pop rdx
    pop rax
    ret

; cfg_takes(EDI = a setting, RCX = room for 256 bytes): what it takes, in
; words. Preserves all.
cfg_takes:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rcx
    mov byte [r8], 0
    call cfg_desc
    mov rbx, rax
    movzx eax, byte [rbx + SD_KIND]
    cmp eax, SK_CHOICE
    je .list
    cmp eax, SK_COLOUR
    je .list
    cmp eax, SK_SWITCH
    je .switch
    cmp eax, SK_NUMBER
    je .number
    cmp eax, SK_ZONE
    je .zone
    lea rsi, [str_cfg_takes_word]       ; a word
    cmp qword [rbx + SD_STEP], CW_HOST
    jne .not_host
    lea rsi, [str_cfg_takes_host]
.not_host:
    cmp qword [rbx + SD_STEP], CW_IPV4
    jne .copy
    lea rsi, [str_cfg_takes_ipv4]
.copy:
    mov rdi, r8
    mov ecx, 256
    call rec_copyz
    jmp .out
.switch:
    lea rsi, [str_cfg_takes_switch]
    jmp .copy
.number:
    mov rax, [rbx + SD_UNIT]
    cmp byte [rax], 0
    je .number_bare
    SPRINTF r8, "%d to %d %s", qword [rbx + SD_MIN], qword [rbx + SD_MAX], rax
    jmp .out
.number_bare:
    SPRINTF r8, "%d to %d", qword [rbx + SD_MIN], qword [rbx + SD_MAX]
    jmp .out
.zone:
    lea rsi, [str_cfg_takes_zone]
    jmp .copy
.list:                                  ; a, b or c (a colour: or #rrggbb)
    mov rax, rbx
    call cfg_choices
    mov r9d, ecx                        ; how many
    mov rsi, [rbx + SD_LIST]
    mov rdi, r8
    xor ecx, ecx
.item:
    cmp ecx, r9d
    jae .listed
    test ecx, ecx
    jz .name
    lea rax, [str_cfg_comma]
    lea rdx, [r9 - 1]
    cmp ecx, edx
    jne .sep
    cmp byte [rbx + SD_KIND], SK_COLOUR
    je .sep
    lea rax, [str_cfg_or]
.sep:
    push rsi
    mov rsi, rax
    call cfg_cat
    pop rsi
.name:
    push rsi
    mov rsi, [rsi]
    call cfg_cat
    pop rsi
    add rsi, 8
    cmp byte [rbx + SD_KIND], SK_COLOUR
    jne .item_next
    add rsi, 8
.item_next:
    inc ecx
    jmp .item
.listed:
    cmp byte [rbx + SD_KIND], SK_COLOUR
    jne .out
    lea rsi, [str_cfg_or_hex]
    call cfg_cat
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cfg_cat(RDI = where the text goes on, RSI = text) -> RDI = its new end.
; Preserves others.
cfg_cat:
    push rax
    push rsi
.next:
    mov al, [rsi]
    mov [rdi], al
    test al, al
    jz .out
    inc rsi
    inc rdi
    jmp .next
.out:
    pop rsi
    pop rax
    ret

; cfg_say_takes(EDI = a setting, RSI = what it was given): said, in the
; terminal. Preserves all.
cfg_say_takes:
    push rax
    push rcx
    lea rcx, [cfg_takes_buf]
    call cfg_takes
    call cfg_desc
    mov rax, [rax + SD_NAME]
    KLOG "%s takes %s, not '%s'", rax, rcx, rsi
    pop rcx
    pop rax
    ret

; cfg_kind_name(EDI = a setting) -> RAX = its kind, in words. Preserves others.
cfg_kind_name:
    call cfg_desc
    movzx eax, byte [rax + SD_KIND]
    lea rcx, [cfg_kind_names]
    mov rax, [rcx + rax * 8]
    ret

; -----------------------------------------------------------------------------
;  The main loop's side: changes applied, the file read and written
; -----------------------------------------------------------------------------

; cfg_service: from the main loop
cfg_service:
    push rbx
    push r14
    cmp byte [cfg_loaded], 0
    jne .apply
    call log_volume                     ; the boot stick, once it is here
    jc .apply
    call cfg_load
.apply:
    xor eax, eax
    xchg rax, [cfg_pending]
    mov rbx, rax
.each:
    test rbx, rbx
    jz .save
    bsf rcx, rbx
    btr rbx, rcx
    mov edi, ecx
    call cfg_desc
    mov rax, [rax + SD_APPLY]
    test rax, rax
    jz .each
    mov rdi, [cfg_vals + rcx * 8]
    push rbx
    call rax
    pop rbx
    jmp .each
.save:
    call power_button
    test eax, eax
    jz .kept
    call cfg_power_pressed
.kept:
    cmp byte [cfg_dirty], 0
    je .out
    cmp byte [cfg_loaded], 0
    je .out
    RDTSC64
    cmp rax, [cfg_save_at]
    jb .out
    call cfg_save
.out:
    pop r14
    pop rbx
    ret

; cfg_final: before a reboot or a power-off, what changed is kept.
; Preserves all.
cfg_final:
    push rax
    cmp byte [cfg_dirty], 0
    je .out
    cmp byte [cfg_loaded], 0
    je .out
    call cfg_save
.out:
    pop rax
    ret

; cfg_load(R14 = the boot stick): SETTINGS.TXT read, if it is there. Lines
; of 'name = value'; # begins a remark.
cfg_load:
    push rbx
    push r12
    push r13
    push r15
    mov byte [cfg_loaded], 1
    cmp byte [cfg_early], 0             ; the loader had it: read at boot
    jne .early
    mov edi, [r14 + VF_ROOT]
    lea rsi, [str_cfg_name]
    call fat_lookup                     ; (quietly: it may well not be there)
    jc .none
    lea rsi, [str_cfg_path]
    lea rdi, [cfg_file]
    mov ecx, CFG_FILE_MAX - 1
    call fat_read_file
    jc .unread
    mov byte [cfg_file + rax], 0
    call cfg_read_text
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "settings: %u read from vol%u:/SETTINGS.TXT", r12, rax
    jmp .out
.early:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "settings: %u read at boot, kept in vol%u:/SETTINGS.TXT", qword [cfg_early_n], rax
    jmp .out
.unread:
    KLOG "settings: SETTINGS.TXT could not be read; the defaults stand"
    jmp .out
.none:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "settings: the defaults (vol%u:/SETTINGS.TXT keeps any change)", rax
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; cfg_read_text: the settings in cfg_file (NUL at the end), 'name = value'
; lines, '#' for a remark; any changed this boot already stay so -> R12 =
; how many were read. Clobbers RAX, RBX, RCX, RDX, RSI, RDI, R13, R15.
cfg_read_text:
    movzx r15d, byte [cfg_dirty]        ; what this boot changed already stays so
    xor r12d, r12d                      ; settings read
    xor r13d, r13d                      ; the line's number
    lea rbx, [cfg_file]
.line:
    cmp byte [rbx], 0
    je .read
    inc r13d
    mov rsi, rbx                        ; its end, made a NUL
.end:
    mov al, [rbx]
    test al, al
    jz .ended
    inc rbx
    cmp al, 10
    jne .end
    mov byte [rbx - 1], 0
.ended:
    lea rdi, [rbx - 1]                  ; no CR or spaces at the end
.trim:
    cmp rdi, rsi
    jb .trimmed
    mov al, [rdi]
    cmp al, 13
    je .cut
    cmp al, ' '
    je .cut
    cmp al, 9
    je .cut
    test al, al
    jz .back
    jmp .trimmed
.cut:
    mov byte [rdi], 0
.back:
    dec rdi
    jmp .trim
.trimmed:
    call cfg_skip_spaces
    mov al, [rsi]
    test al, al
    jz .line
    cmp al, '#'
    je .line
    mov rdx, rsi                        ; the name
.name:
    mov al, [rsi]
    test al, al
    jz .no_value
    cmp al, ' '
    je .named
    cmp al, '='
    je .named
    inc rsi
    jmp .name
.named:
    mov byte [rsi], 0
    inc rsi
.equals:
    mov al, [rsi]
    cmp al, ' '
    je .skip
    cmp al, '='
    jne .value
.skip:
    inc rsi
    jmp .equals
.value:
    push rsi
    mov rsi, rdx
    call cfg_find
    pop rsi
    jc .unknown
    mov edi, eax
    bt qword [cfg_touched], rdi         ; changed this boot: that stays
    jc .line
    call cfg_parse
    jc .bad
    mov rdx, rsi                        ; (a word's text)
    mov rsi, rax
    call cfg_change
    inc r12d
    jmp .line
.no_value:
    KLOG "settings: SETTINGS.TXT line %u: '%s' has no value", r13, rdx
    jmp .line
.unknown:
    KLOG "settings: SETTINGS.TXT line %u: no setting '%s'", r13, rdx
    jmp .line
.bad:
    KLOG "settings: SETTINGS.TXT line %u:", r13
    call cfg_say_takes
    jmp .line
.read:
    mov [cfg_dirty], r15b
    ret

; cfg_save: every setting not at its default, to SETTINGS.TXT on the boot
; stick. Preserves all but RAX.
cfg_save:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r14
    call log_volume
    jc .out                             ; not here now: later
    mov byte [cfg_dirty], 0
    lea rdi, [cfg_file]
    lea rsi, [str_cfg_head]
    call cfg_cat
    xor ebx, ebx
.next:
    cmp ebx, CFG_COUNT
    jae .write
    push rdi
    mov edi, ebx
    call cfg_is_default
    pop rdi
    je .skip
    mov r12, rdi
    mov edi, ebx
    call cfg_desc
    mov rax, [rax + SD_NAME]
    lea rcx, [cfg_show_buf]
    call cfg_show_now
    SPRINTF r12, "%s = %s", rax, rcx
    lea rdi, [r12 + rax]
    mov byte [rdi], 10
    inc rdi
.skip:
    inc ebx
    jmp .next
.write:
    lea rcx, [cfg_file]
    sub rdi, rcx
    mov rcx, rdi
    mov dl, [r14 + VO_WRITABLE]         ; this one file needs no 'vol <n> rw'
    mov byte [r14 + VO_WRITABLE], 1
    lea rsi, [str_cfg_path]
    lea rdi, [cfg_file]
    call fat_write_file
    mov [r14 + VO_WRITABLE], dl
    jc .failed
    cmp byte [cfg_said], 0
    jne .out
    mov byte [cfg_said], 1
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "settings: kept in vol%u:/SETTINGS.TXT", rax
    jmp .out
.failed:
    KLOG "settings: SETTINGS.TXT could not be written"
.out:
    pop r14
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  What a change does (SD_APPLY: RDI = the value, on the main thread)
; -----------------------------------------------------------------------------

cfg_apply_look:                         ; display.theme, .accent, .scale, desktop.wallpaper
    call cfg_theme
    jc theme_apply                      ; (not when theme.asm made the change)
    ret

cfg_apply_clock:
    jmp desk_bar_damage                 ; the menu bar's clock, at once

; cfg_power_pressed: the power button, as power.button says
cfg_power_pressed:
    mov rax, [cfg_vals + CFG_POWER_BUTTON * 8]
    cmp rax, 1
    je .restart
    ja .nothing
    KLOG "power button: powering off..."
    call log_final
    jmp power_off
.restart:
    KLOG "power button: rebooting..."
    call log_final
    jmp power_reboot
.nothing:
    KLOG "power button: pressed ('settings set power.button off' makes it turn the machine off)"
    ret

cfg_apply_zone:
    jmp lx_time_init                    ; Linux programs' UTC

cfg_apply_demo:
    cmp byte [sm_no_demo], 0            ; the firmware said not to (tests)
    jne .out
    test edi, edi
    jz .set
    movzx edi, byte [mandel_ok]
.set:
    mov [demo_on], dil
.out:
    ret

cfg_apply_log:
    mov [log_auto], dil
    ret

cfg_apply_ipv6:
    mov [ip6_prefer], dil
    ret

cfg_apply_model:
    push rsi
    push rdi
    mov edi, CFG_MODEL
    call cfg_text
    mov rsi, rax
    lea rdi, [cl_model]
    call strcpy
    pop rdi
    pop rsi
    ret

; network.ipv4: DHCP, or the address by hand, as 'dhcp' and 'ip' would
cfg_apply_ipv4:
    push rbx
    cmp dword [nic_count], 0
    je .out
    mov rbx, [sh_args]                  ; (the shell's, put back after)
    mov edi, CFG_IPV4
    call cfg_text
    mov rsi, rax
    lea rdi, [str_cfg_automatic]
    call streq
    test eax, eax
    jnz .automatic
    lea rdi, [cfg_ip_args]
    mov ecx, CFG_TEXT_MAX
    call rec_copyz
    mov [sh_args], rdi
    call cmd_ip
    jmp .back
.automatic:
    cmp byte [net_static], 0            ; it is already
    je .back
    call cmd_dhcp
.back:
    mov [sh_args], rbx
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  What other parts of the kernel read
; -----------------------------------------------------------------------------

; cfg_repeat_delay -> EDI = ms before a held key repeats. Preserves others.
cfg_repeat_delay:
    mov edi, [cfg_vals + CFG_REPEAT_DELAY * 8]
    ret

; cfg_repeat_every -> EDI = ms between repeats. Preserves others.
cfg_repeat_every:
    push rax
    push rcx
    push rdx
    mov ecx, [cfg_vals + CFG_REPEAT_RATE * 8]
    mov eax, 1000
    xor edx, edx
    test ecx, ecx
    jz .out
    div ecx
.out:
    mov edi, eax
    pop rdx
    pop rcx
    pop rax
    ret

; cfg_key(EDX = what a key types on a US keyboard) -> EDX = what it types
; with the layout chosen. Preserves others.
cfg_key:
    push rax
    push rsi
    mov rax, [cfg_vals + CFG_LAYOUT * 8]
    test rax, rax
    jz .out
    lea rsi, [cfg_dvorak]
    cmp rax, 1
    je .find
    lea rsi, [cfg_colemak]
.find:
    mov al, [rsi]
    test al, al
    jz .out
    cmp al, dl
    je .found
    add rsi, 2
    jmp .find
.found:
    movzx edx, byte [rsi + 1]
.out:
    pop rsi
    pop rax
    ret

; cfg_font(ECX = the font gfx_init would choose) -> ECX = the one
; display.text-size asks for (auto: that one). Preserves others.
cfg_font:
    push rax
    mov rax, [cfg_vals + CFG_TEXT_SIZE * 8]
    test rax, rax
    jz .out
    lea ecx, [eax - 1]                  ; small, medium, large: 10x20, 15x30, 20x40
    cmp ecx, FONT_SIZES - 1
    jbe .out
    mov ecx, FONT_SIZES - 1
.out:
    pop rax
    ret

; cfg_pointer(RAX = a move, in pixels) -> RAX = scaled by pointer.speed
; (5 leaves it be). Preserves others.
cfg_pointer:
    push rcx
    push rdx
    mov rcx, [cfg_vals + CFG_POINTER_SPEED * 8]
    imul rax, rcx
    mov ecx, 5
    cqo
    idiv rcx
    pop rdx
    pop rcx
    ret

; cfg_wheel(EDX = notches, up positive) -> EDX, turned round for natural
; scrolling. Preserves others.
cfg_wheel:
    cmp qword [cfg_vals + CFG_NATURAL * 8], 0
    je .out
    neg edx
.out:
    ret

; cfg_host -> RSI = this machine's name. Preserves others.
cfg_host:
    push rax
    push rdi
    mov edi, CFG_HOST
    call cfg_text
    mov rsi, rax
    pop rdi
    pop rax
    ret

; cfg_zone -> RAX = minutes east of UTC that the machine's clock keeps.
; Preserves others.
cfg_zone:
    mov rax, [cfg_vals + CFG_ZONE * 8]
    ret

; cfg_clock(RDI = room for 16 bytes) -> RAX = the clock for the bar, as
; desktop.clock says (0 bytes when it is off). Preserves others.
cfg_clock:
    push rcx
    push rdx
    push r8
    mov rcx, [cfg_vals + CFG_CLOCK * 8]
    cmp rcx, 2
    je .off
    call rtc_read
    mov rax, [rtc_hour]
    test rcx, rcx
    jnz .twelve
    SPRINTF rdi, "%02u:%02u", rax, qword [rtc_min]
    jmp .out
.twelve:
    lea r8, [str_cfg_am]
    cmp rax, 12
    jb .morning
    lea r8, [str_cfg_pm]
    sub rax, 12
.morning:
    test rax, rax
    jnz .hour
    mov eax, 12
.hour:
    SPRINTF rdi, "%u:%02u %s", rax, qword [rtc_min], r8
    jmp .out
.off:
    mov byte [rdi], 0
    xor eax, eax
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  The look: theme.asm's, from display.theme, display.accent,
;  display.scale and desktop.wallpaper. The shell's 'theme' changes them through here too, so
;  what it says is kept and every Settings window hears of it.
; -----------------------------------------------------------------------------

; cfg_theme: th_mode, th_accent_i, th_wall and ui_s4 from the settings (an
; accent that is no swatch: the nearest one; scale auto: th_auto_s4, once
; theme_init has set it) -> CF if any of them changed.
; Preserves all.
cfg_theme:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor ebx, ebx                        ; BL: something changed
    mov eax, [cfg_vals + CFG_THEME * 8]
    cmp al, [th_mode]
    je .mode
    mov [th_mode], al
    mov bl, 1
.mode:
    mov edi, [cfg_vals + CFG_ACCENT * 8]
    xor ecx, ecx                        ; ECX: this accent, ESI: the nearest,
    xor esi, esi                        ; EDX: how far it was
    mov edx, -1
.accent:
    lea rax, [accent_colors]
    mov eax, [rax + rcx * 8]
    push rcx
    push rdx
    call cfg_rgb_far
    pop rdx
    pop rcx
    cmp eax, edx
    jae .farther
    mov edx, eax
    mov esi, ecx
.farther:
    inc ecx
    cmp ecx, ACCENTS
    jb .accent
    cmp sil, [th_accent_i]
    je .accent_same
    mov [th_accent_i], sil
    mov bl, 1
.accent_same:
    mov eax, [cfg_vals + CFG_WALLPAPER * 8]
    cmp al, [th_wall]
    je .wall
    mov [th_wall], al
    mov bl, 1
.wall:
    mov eax, [cfg_vals + CFG_SCALE * 8]
    add eax, 3                          ; 1x: 4 quarters a point
    cmp eax, 3
    jne .scale
    mov eax, [th_auto_s4]
    test eax, eax
    jz .scaled                          ; (before theme_init)
.scale:
    cmp eax, [ui_s4]
    je .scaled
    mov [ui_s4], eax
    mov bl, 1
.scaled:
    neg bl                              ; CF if BL was 1
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; cfg_rgb_far(EAX, EDI = two 0xRRGGBB) -> EAX = how far apart they are,
; channel by channel. Loses RCX, RDX.
cfg_rgb_far:
    push rbx
    push rsi
    mov esi, eax
    xor ebx, ebx
    mov ecx, 16
.channel:
    mov eax, esi
    shr eax, cl
    and eax, 0xFF
    mov edx, edi
    shr edx, cl
    and edx, 0xFF
    sub eax, edx
    jns .abs
    neg eax
.abs:
    add ebx, eax
    sub ecx, 8
    jns .channel
    mov eax, ebx
    pop rsi
    pop rbx
    ret

; cfg_set_look(EDI = CFG_THEME, CFG_ACCENT, CFG_SCALE or CFG_WALLPAPER, RSI = its
; value): theme.asm changed it itself (the shell's 'theme'): kept, and
; told to every settings object. Preserves all.
cfg_set_look:
    push rax
    push rdx
    xor edx, edx
    call cfg_change
    pop rdx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The shell: settings [name | pattern], settings set, settings reset
;  (records.asm; EDI = how many words, RSI = them; CF if it failed)
; -----------------------------------------------------------------------------

; settings [name | pattern | category]: every setting, those that match, or
; one, as a record
settings_list:
    push rbx
    push r12
    push r13
    push r14
    cmp edi, 1
    ja .usage
    xor r13d, r13d                      ; R13: the pattern, 0 for all
    test edi, edi
    jz .table
    mov r13, [rsi]
    mov [cfg_asked], r13
    mov rsi, r13
    call cfg_find
    jnc .one
    mov rdi, r13
    call rec_wild
    test eax, eax
    jnz .table
    lea rdi, [cfg_pattern]              ; a category: display -> display.*
    SPRINTF rdi, "%s.*", r13
    mov r13, rdi
.table:
    COLUMN 'name', FT_TEXT
    COLUMN 'value', FT_TEXT
    COLUMN 'default', FT_TEXT
    COLUMN 'kind', FT_TEXT
    COLUMN 'about', FT_TEXT
    xor ebx, ebx
    xor r14d, r14d                      ; how many matched
.next:
    cmp ebx, CFG_COUNT
    jae .listed
    mov edi, ebx
    call cfg_desc
    mov r12, rax
    test r13, r13
    jz .row
    mov rdi, r13
    mov rsi, [r12 + SD_NAME]
    call glob_match
    test eax, eax
    jz .skip
.row:
    inc r14d
    call rec_row
    xor edi, edi
    mov rsi, [r12 + SD_NAME]
    call rec_set
    mov edi, ebx
    lea rcx, [cfg_show_buf]
    call cfg_show_now
    mov edi, 1
    mov rsi, rcx
    call rec_str
    mov edi, ebx
    call cfg_show_default
    mov edi, 2
    call rec_str
    mov edi, ebx
    push rcx
    call cfg_kind_name
    pop rcx
    mov edi, 3
    mov rsi, rax
    call rec_set
    mov edi, 4
    mov rsi, [r12 + SD_ABOUT]
    call rec_set
.skip:
    inc ebx
    jmp .next
.listed:
    test r14d, r14d
    jnz .ok
    test r13, r13
    jz .ok
    KLOG "settings: no setting is called '%s' ('settings' lists them)", qword [cfg_asked]
    jmp .fail
.one:
    mov ebx, eax
    call cfg_record_table
.ok:
    clc
    jmp .out
.usage:
    KLOG "settings [name | pattern]: one name, or a pattern ('help settings')"
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cfg_record_table(EBX = a setting): it, as one record
cfg_record_table:
    push r12
    COLUMN 'name', FT_TEXT
    COLUMN 'value', FT_TEXT
    COLUMN 'default', FT_TEXT
    COLUMN 'kind', FT_TEXT
    COLUMN 'takes', FT_TEXT
    COLUMN 'applies', FT_TEXT
    COLUMN 'about', FT_TEXT
    mov edi, TBF_RECORD
    call rec_flag
    call rec_row
    mov edi, ebx
    call cfg_desc
    mov r12, rax
    xor edi, edi
    mov rsi, [r12 + SD_NAME]
    call rec_set
    mov edi, ebx
    lea rcx, [cfg_show_buf]
    call cfg_show_now
    mov edi, 1
    mov rsi, rcx
    call rec_str
    mov edi, ebx
    call cfg_show_default
    mov edi, 2
    call rec_str
    mov edi, ebx
    call cfg_kind_name
    mov edi, 3
    mov rsi, rax
    call rec_set
    mov edi, ebx
    lea rcx, [cfg_takes_buf]
    call cfg_takes
    mov edi, 4
    mov rsi, rcx
    call rec_str
    lea rsi, [str_cfg_now]
    test byte [r12 + SD_FLAGS], SIF_RESTART
    jz .applies
    lea rsi, [str_cfg_restart]
.applies:
    mov edi, 5
    call rec_set
    mov edi, 6
    mov rsi, [r12 + SD_ABOUT]
    call rec_set
    pop r12
    ret

; cfg_category(RSI = a word) -> RDI = cfg_pattern: the word, then .*, so
; that 'display' means every display.* setting. Preserves others.
cfg_category:
    push rax
    push rcx
    lea rdi, [cfg_pattern]
    mov ecx, 60
    call rec_copyz
    push rdi
    call strlen
    pop rdi
    mov word [rdi + rax], '.*'
    mov byte [rdi + rax + 2], 0
    pop rcx
    pop rax
    ret

; cfg_change_cols: the columns 'settings set' and 'reset' give
cfg_change_cols:
    COLUMN 'name', FT_TEXT
    COLUMN 'value', FT_TEXT
    COLUMN 'was', FT_TEXT
    ret

; cfg_change_row(EBX = a setting, cfg_was_buf = what it was): a row
; saying so. Preserves RBX, R12-R15.
cfg_change_row:
    call rec_row
    mov edi, ebx
    call cfg_desc
    xor edi, edi
    mov rsi, [rax + SD_NAME]
    call rec_set
    mov edi, ebx
    lea rcx, [cfg_show_buf]
    call cfg_show_now
    mov edi, 1
    mov rsi, rcx
    call rec_str
    mov edi, 2
    lea rsi, [cfg_was_buf]
    call rec_str
    ret

; settings set <name> <value...>: changed, applied and kept; the setting,
; with what it was
settings_set:
    push rbx
    push r12
    push r13
    cmp edi, 2
    jb .usage
    mov r12, rsi
    mov r13d, edi
    mov rsi, [r12]
    call cfg_find
    jc .unknown
    mov ebx, eax
    mov edi, ebx
    lea rcx, [cfg_was_buf]
    call cfg_show_now
    lea edi, [r13d - 1]                 ; the value: the words after the name
    lea rsi, [r12 + 8]
    call sh_join
    lea rsi, [sh_joined]
    mov edi, ebx
    call cfg_parse
    jc .bad
    mov rdx, rsi                        ; (a word's text)
    mov rsi, rax
    call cfg_change
    call cfg_service                    ; applied now
    call cfg_change_cols
    call cfg_change_row
    clc
    jmp .out
.bad:
    call cfg_say_takes
    stc
    jmp .out
.usage:
    KLOG "settings set <name> <value>: 'settings' lists the names, 'settings <name>' what one takes"
    stc
    jmp .out
.unknown:
    KLOG "settings: no setting is called '%s' ('settings' lists them)", qword [r12]
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; settings reset <name | pattern | all>...: back to their defaults
settings_reset:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test edi, edi
    jz .usage
    mov r12, rsi
    mov r13d, edi
    xor r15d, r15d                      ; 1 once one named nothing
    call cfg_change_cols
.word:
    test r13d, r13d
    jz .done
    mov r14, [r12]
    lea rdi, [str_cfg_all]
    mov rsi, r14
    call rec_ieq
    test eax, eax
    jz .named
    lea r14, [str_cfg_star]
.named:
    mov rsi, r14
    call cfg_find
    jc .pattern
    mov ebx, eax
    call .one
    jmp .next
.pattern:
    mov rdi, r14
    call rec_wild
    test eax, eax
    jnz .match
    mov rsi, r14
    call cfg_category
    mov r14, rdi
.match:
    mov dword [cfg_matched], 0
    xor ebx, ebx
.each:
    cmp ebx, CFG_COUNT
    jae .matched
    mov edi, ebx
    call cfg_desc
    mov rdi, r14
    mov rsi, [rax + SD_NAME]
    call glob_match
    test eax, eax
    jz .each_next
    inc dword [cfg_matched]
    call .one
.each_next:
    inc ebx
    jmp .each
.matched:
    cmp dword [cfg_matched], 0
    jne .next
    KLOG "settings: no setting is called '%s' ('settings' lists them)", qword [r12]
    mov r15d, 1
.next:
    add r12, 8
    dec r13d
    jmp .word
.done:
    call cfg_service                    ; applied now
    cmp r15d, 1
    cmc                                 ; CF if one named nothing
    jmp .out
.usage:
    KLOG "settings reset <name | pattern | all>...: back to the default"
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.one:                                   ; EBX: reset, and said
    mov edi, ebx
    lea rcx, [cfg_was_buf]
    call cfg_show_now
    call cfg_reset
    jmp cfg_change_row

; -----------------------------------------------------------------------------
;  Programs: the settings by capability (OT_SETTINGS)
; -----------------------------------------------------------------------------

; cfg_program -> EAX = a handle to the settings, to read and change, in
; the current task; 0 if none could be made. Preserves others.
cfg_program:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, OT_SETTINGS
    mov esi, SG_SIZE
    lea rdx, [str_ot_settings]
    call obj_new
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, RT_SET_READ | RT_SET_CHANGE | RT_DUP | RT_GIVE | RT_INFO
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

; cfg_record(EDI = a setting, RSI = SI_SIZE bytes): it, as RO_SET_LIST
; gives it. Preserves all.
cfg_record:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r12
    mov r8, rsi
    mov r12d, edi
    mov rdi, r8
    xor eax, eax
    mov ecx, SI_SIZE / 8
    rep stosq
    mov edi, r12d
    call cfg_desc
    mov rbx, rax
    mov rsi, [rbx + SD_NAME]
    lea rdi, [r8 + SI_NAME]
    mov ecx, 32
    call rec_copyz
    movzx eax, byte [rbx + SD_KIND]
    mov [r8 + SI_KIND], eax
    movzx eax, byte [rbx + SD_FLAGS]
    mov edi, r12d
    call cfg_is_default
    je .flags
    or eax, SIF_CHANGED
.flags:
    mov [r8 + SI_FLAGS], eax
    mov rax, [cfg_vals + r12 * 8]
    mov [r8 + SI_VALUE], rax
    xor eax, eax
    cmp byte [rbx + SD_KIND], SK_TEXT
    je .default
    mov rax, [rbx + SD_DEFAULT]
.default:
    mov [r8 + SI_DEFAULT], rax
    mov rax, [rbx + SD_MIN]
    mov [r8 + SI_MIN], rax
    mov rax, [rbx + SD_MAX]
    mov [r8 + SI_MAX], rax
    mov rax, [rbx + SD_STEP]
    mov [r8 + SI_STEP], rax
    mov rax, rbx
    call cfg_choices
    test ecx, ecx
    jz .text
    mov [r8 + SI_MAX], rcx
.text:
    mov edi, r12d
    lea rcx, [r8 + SI_TEXT]
    call cfg_show_now
    mov rsi, [rbx + SD_UNIT]
    lea rdi, [r8 + SI_UNIT]
    mov ecx, 16
    call rec_copyz
    mov rsi, [rbx + SD_LIST]            ; the choices' or swatches' names
    test rsi, rsi
    jz .about
    lea rdi, [r8 + SI_CHOICES]
    lea rdx, [r8 + SI_CHOICES + 127]
    xor ecx, ecx
.choice:
    mov rax, [rsi]
    test rax, rax
    jz .about
.char:
    cmp rdi, rdx
    jae .about
    push rcx
    mov cl, [rax]
    mov [rdi], cl
    inc rdi
    inc rax
    test cl, cl
    pop rcx
    jnz .char
    add rsi, 8
    cmp byte [rbx + SD_KIND], SK_COLOUR
    jne .choice_next
    mov eax, [rsi]
    mov [r8 + SI_SWATCHES + rcx * 4], eax
    add rsi, 8
.choice_next:
    inc ecx
    cmp ecx, CFG_LIST_MAX
    jb .choice
.about:
    mov rsi, [rbx + SD_ABOUT]
    lea rdi, [r8 + SI_ABOUT]
    mov ecx, 128
    call rec_copyz
    pop r12
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; h_set_list(EDI = the settings, ESI = memory, RDX = where in it, RCX =
; room) -> RAX = how many settings there are (needs RT_SET_READ, and
; RT_MEM_WRITE): a record for each that fits; what RO_WAIT waited for, seen
h_set_list:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, SI_SIZE
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_SETTINGS
    mov edx, RT_SET_READ
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov dword [rbx + SG_CHANGED], 0
    xor r15d, r15d
.next:
    cmp r15d, CFG_COUNT
    jae .done
    lea rax, [r15 + 1]
    shl rax, 9                          ; SI_SIZE
    cmp rax, r14
    ja .done
    mov edi, r15d
    mov rsi, rsp
    call cfg_record
    mov edi, r12d
    mov rsi, r15
    shl rsi, 9
    add rsi, r13
    mov rdx, rsp
    mov ecx, SI_SIZE
    call h_mem_write
    cmp rax, E_ANY
    jae .put
    inc r15d
    jmp .next
.done:
    mov eax, CFG_COUNT
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    add rsp, SI_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_set_change(EDI = the settings, ESI = memory, RDX = which, RCX = the
; value, or where its text is, R8 = 0, or the text's bytes) -> RAX = 0
; (needs RT_SET_CHANGE; for text, RT_MEM_READ)
h_set_change:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, CFG_TEXT_MAX
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov esi, OT_SETTINGS
    mov edx, RT_SET_CHANGE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_RANGE
    cmp r13, CFG_COUNT
    jae .put
    test r15, r15
    jz .value
    mov rax, E_ARG
    cmp r15, CFG_TEXT_MAX - 1
    jae .put
    mov edi, r12d
    mov rsi, r14
    mov rdx, rsp
    mov rcx, r15
    call h_mem_read
    cmp rax, E_ANY
    jae .put
    mov byte [rsp + r15], 0
    mov edi, r13d
    mov rsi, rsp
    call cfg_parse
    mov rdx, rsp
    mov rsi, rax
    jc .arg
    jmp .change
.value:
    mov edi, r13d
    call cfg_desc
    cmp byte [rax + SD_KIND], SK_TEXT
    je .arg
    mov rsi, r14
    call cfg_check
    jc .arg
    xor edx, edx
.change:
    mov edi, r13d
    call cfg_change
    xor eax, eax
    jmp .put
.arg:
    mov rax, E_ARG
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    add rsp, CFG_TEXT_MAX
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
str_ot_settings:    db 'settings', 0
str_cfg_axiom:      db 'axiom', 0
str_cfg_automatic:  db 'automatic', 0
cfg_model_default:  db 'claude-opus-5-5', 0
str_cfg_on:         db 'on', 0
str_cfg_off:        db 'off', 0
str_cfg_yes:        db 'yes', 0
str_cfg_no:         db 'no', 0
str_cfg_true:       db 'true', 0
str_cfg_false:      db 'false', 0
str_cfg_utc:        db 'UTC', 0
str_cfg_am:         db 'am', 0
str_cfg_pm:         db 'pm', 0
str_cfg_all:        db 'all', 0
str_cfg_star:       db '*', 0
str_cfg_comma:      db ', ', 0
str_cfg_or:         db ' or ', 0
str_cfg_or_hex:     db ', or #rrggbb', 0
str_cfg_now:        db 'now', 0
str_cfg_restart:    db 'at the next start', 0
str_cfg_takes_switch: db 'on or off', 0
str_cfg_takes_zone: db 'an offset from UTC, UTC-12:00 to UTC+14:00 (UTC, UTC+2, -05:00)', 0
str_cfg_takes_host: db 'a name of letters, digits and -, up to 63', 0
str_cfg_takes_ipv4: db 'automatic, or a.b.c.d/n [router] [dns]', 0
str_cfg_takes_word: db 'one word, up to 63 characters', 0
str_cfg_name:       db 'SETTINGS.TXT', 0
str_cfg_path:       db '/SETTINGS.TXT', 0
str_cfg_head:       db "# Axiom's settings: those that are not as they came.", 10
                    db "# 'settings' in Axiom's shell lists every one, and what it takes;", 10
                    db "# 'settings set <name> <value>' changes one. Lines: name = value", 10, 0
str_cfg_k_choice:   db 'choice', 0
str_cfg_k_switch:   db 'switch', 0
str_cfg_k_number:   db 'number', 0
str_cfg_k_colour:   db 'colour', 0
str_cfg_k_zone:     db 'zone', 0
str_cfg_k_text:     db 'text', 0
align 8
cfg_kind_names:     dq str_cfg_k_text, str_cfg_k_choice, str_cfg_k_switch, str_cfg_k_number
                    dq str_cfg_k_colour, str_cfg_k_zone, str_cfg_k_text
cfg_switch_words:   dq str_cfg_on, 1, str_cfg_off, 0, str_cfg_yes, 1, str_cfg_no, 0
                    dq str_cfg_true, 1, str_cfg_false, 0, 0, 0

; keyboard.layout: what a key types on a US keyboard, and with the layout
; (pairs; what is not here stays as it is)
cfg_dvorak:     db '-[', '=]', '_{', '+}', 'q', 0x27, 'w,', 'e.', 'rp', 'ty', 'yf'
                db 'ug', 'ic', 'or', 'pl', '[/', ']=', 'Q"', 'W<', 'E>', 'RP', 'TY'
                db 'YF', 'UG', 'IC', 'OR', 'PL', '{?', '}+', 'so', 'de', 'fu', 'gi'
                db 'hd', 'jh', 'kt', 'ln', ';s', 0x27, '-', 'SO', 'DE', 'FU', 'GI'
                db 'HD', 'JH', 'KT', 'LN', ':S', '"_', 'z;', 'xq', 'cj', 'vk', 'bx'
                db 'nb', ',w', '.v', '/z', 'Z:', 'XQ', 'CJ', 'VK', 'BX', 'NB', '<W'
                db '>V', '?Z', 0
cfg_colemak:    db 'ef', 'rp', 'tg', 'yj', 'ul', 'iu', 'oy', 'p;', 'sr', 'ds', 'ft'
                db 'gd', 'jn', 'ke', 'li', ';o', 'nk', 'EF', 'RP', 'TG', 'YJ', 'UL'
                db 'IU', 'OY', 'P:', 'SR', 'DS', 'FT', 'GD', 'JN', 'KE', 'LI', ':O'
                db 'NK', 0

section .bss
alignb 8
cfg_vals:       resq CFG_COUNT          ; each setting's value
cfg_early_n:    resq 1                  ; how many the loader's copy set
cfg_early:      resb 1                  ; SETTINGS.TXT read at boot
cfg_touched:    resq 1                  ; changed this boot (a bit each)
cfg_pending:    resq 1                  ; changed, to be applied
cfg_gen:        resq 1                  ; changes, ever
cfg_save_at:    resq 1                  ; TSC: written to the stick then
cfg_asked:      resq 1
cfg_lock:       resd 1
cfg_matched:    resd 1
cfg_dirty:      resb 1                  ; changed since written
cfg_loaded:     resb 1                  ; the stick was looked at
cfg_said:       resb 1
alignb 8
cfg_texts:      resb CFG_COUNT * CFG_TEXT_MAX
cfg_show_buf:   resb CFG_TEXT_MAX
cfg_was_buf:    resb CFG_TEXT_MAX
cfg_pattern:    resb CFG_TEXT_MAX + 8
cfg_ip_args:    resb CFG_TEXT_MAX
cfg_takes_buf:  resb 256
cfg_file:       resb CFG_FILE_MAX

section .text
