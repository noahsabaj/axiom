; =============================================================================
;  settings.asm - the machine's settings, in a window
;
;    run settings
;
;  A sidebar of categories (display, desktop, keyboard, ...), and the
;  settings of the one chosen as cards: a switch, a row of choices, a
;  slider, swatches, a stepper or a field, each with what it is beneath.
;  Everything goes through the settings handle the shell gave it
;  (ax_settings, WANTS AW_SETTINGS): RO_SET_LIST reads them all, as records
;  (SI_*), RO_SET_CHANGE changes one, and an RO_WAIT on the handle ends when
;  any changed, from here, the shell or another window: then they are read
;  and drawn again. Its colours are the look's own (display.theme,
;  display.accent), so it changes with them.
;
;  Keys: up and down choose the category; Esc closes it (and ends a field's
;  editing first); in a field, Enter keeps what was typed.
; =============================================================================

%include "axe.inc"
WANTS AW_DESK | AW_SETTINGS

W               equ 1280                ; the window
H               equ 860
SIDE            equ 300                 ; the sidebar's width
CAT_TOP         equ 96                  ; its first category
CAT_H           equ 50
CARD_X          equ SIDE + 36
CARD_W          equ W - SIDE - 72
CARD_H          equ 104
CARD_GAP        equ 16
CARDS_TOP       equ 124
LIST_BYTES      equ 32 * SI_SIZE        ; room for 32 settings
CAT_MAX         equ 16
HIT_MAX         equ 160
EDIT_MAX        equ 63
KEY_ESC         equ 27
KEY_UP          equ 0x80
KEY_DOWN        equ 0x81

F_TITLE         equ WF_BOLD * WF_SIZES + WF_PX36
F_HEAD          equ WF_BOLD * WF_SIZES + WF_PX24
F_LABEL         equ WF_SANS * WF_SIZES + WF_PX20
F_SMALL         equ WF_SANS * WF_SIZES + WF_PX16

; what a click can land on (HT_KIND)
HK_CAT          equ 1                   ; HT_ARG = the category
HK_SWITCH       equ 2
HK_CHOICE       equ 3                   ; HT_ARG = the choice
HK_SLIDER       equ 4
HK_SWATCH       equ 5                   ; HT_ARG = the colour
HK_STEP         equ 6                   ; HT_ARG = -1 or 1
HK_FIELD        equ 7
HT_X0           equ 0
HT_Y0           equ 4
HT_X1           equ 8
HT_Y1           equ 12
HT_KIND         equ 16
HT_INDEX        equ 20                  ; the setting
HT_ARG          equ 24
HT_SIZE         equ 32

; ring completions, by their data
D_CHANNEL       equ 1                   ; the window said something
D_SETTINGS      equ 3                   ; a setting changed
D_OP            equ 4                   ; what op() waits for

; draw.inc's display list is browse's (web/layout.inc); here only its names
DI_KIND         equ 0                   ; byte DK_*
DI_FONT         equ 1                   ; byte
DI_FLAGS        equ 2                   ; word DF_*
DI_LEN          equ 4                   ; dword: the text's bytes
DI_X            equ 8                   ; dword
DI_Y            equ 12                  ; dword: text: the baseline; rect: its top
DI_W            equ 16                  ; dword: text: 1/64 pixels; rect: pixels
DI_COLOR        equ 20                  ; dword
DI_TEXT         equ 24
DI_LINK         equ 32                  ; dword: a link's index + 1, or 0
DI_H            equ 36                  ; dword: a rect's height
DI_SIZE         equ 40
DK_TEXT         equ 1
DK_RECT         equ 2
DF_UNDER        equ 1
DF_PRE          equ 2
DF_STRIKE       equ 4
DF_MASK         equ 7

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov eax, [ax_settings]
    test eax, eax
    jz .no_settings
    mov eax, [ax_desk]
    test eax, eax
    jz .no_desk
    mov edi, LIST_BYTES                 ; the records come into this
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .refused
    mov [list_mem], eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [list], rax
    mov edi, 4096                       ; and what the window says, into this
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .refused
    mov [rx_mem], eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [rx], rax
    mov eax, SYS_CHANNEL_NEW
    syscall
    test rax, rax
    js .refused
    mov [ev_end], edx
    mov edi, [ax_desk]
    mov esi, W
    mov edx, H
    mov r10d, eax
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js .refused
    mov [win], eax
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [px_base], rax
    mov dword [px_stride], W
    mov dword [editing], -1
    mov dword [drag], -1
    mov dword [wrong], -1
    call title
    call reload
    call paint
.loop:
    cmp byte [gone], 0
    jne .done
    cmp byte [ch_ready], 0
    je .changed
    mov byte [ch_ready], 0
    call event
    jmp .loop
.changed:
    cmp byte [set_dirty], 0
    je .wait
    mov byte [set_dirty], 0
    call reload
    call paint
    jmp .loop
.wait:
    call arm
    jmp .loop
.done:
    xor eax, eax
    jmp .out
.no_settings:
    lea rsi, [s_no_settings]
    call ax_puts
    mov eax, 2
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

; -----------------------------------------------------------------------------
;  The ring: two waits at once (the window, the settings), and ops between
; -----------------------------------------------------------------------------

; arm: a wait on each that has none, then until something completes
arm:
    push rbx
    xor ebx, ebx
    sub rsp, SQ_SIZE
    cmp byte [w_channel], 0
    jne .settings
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WAIT
    mov eax, [ev_end]
    mov [rsp + SQ_HANDLE], eax
    mov qword [rsp + SQ_DATA], D_CHANNEL
    mov rdi, rsp
    call ax_submit
    mov byte [w_channel], 1
    inc ebx
.settings:
    cmp byte [w_settings], 0
    jne .enter
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WAIT
    mov eax, [ax_settings]
    mov [rsp + SQ_HANDLE], eax
    mov qword [rsp + SQ_DATA], D_SETTINGS
    mov rdi, rsp
    call ax_submit
    mov byte [w_settings], 1
    inc ebx
.enter:
    add rsp, SQ_SIZE
    mov edi, ebx
    mov esi, 1
    call ax_enter
    call drain
    pop rbx
    ret

; drain: every completion there is, seen to
drain:
    call ax_reap
    jc .out
    cmp rcx, D_CHANNEL
    je .channel
    cmp rcx, D_SETTINGS
    je .settings
    mov [op_result], rax
    mov byte [op_done], 1
    jmp drain
.channel:
    mov byte [w_channel], 0
    test rax, rax
    js .gone
    mov byte [ch_ready], 1
    jmp drain
.gone:
    mov byte [gone], 1
    jmp drain
.settings:
    test rax, rax
    js drain                            ; (refused: it stays armed, never again)
    mov byte [w_settings], 0
    mov byte [set_dirty], 1
    jmp drain
.out:
    ret

; op(RDI = an entry) -> RAX = its result, once it completed; what else
; completes meanwhile is seen to
op:
    mov qword [rdi + SQ_DATA], D_OP
    mov byte [op_done], 0
    call ax_submit
    mov edi, 1
    mov esi, 1
    call ax_enter
.reap:
    call drain
    cmp byte [op_done], 0
    jne .done
    xor edi, edi
    mov esi, 1
    call ax_enter
    jmp .reap
.done:
    mov rax, [op_result]
    ret

; reload: every setting, into list; the categories found in them
reload:
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_SET_LIST
    mov eax, [ax_settings]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [list_mem]
    mov [rsp + SQ_HANDLE2], eax
    mov qword [rsp + SQ_A1], LIST_BYTES
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    test rax, rax
    jns .some
    xor eax, eax
.some:
    cmp eax, LIST_BYTES / SI_SIZE
    jbe .fits
    mov eax, LIST_BYTES / SI_SIZE
.fits:
    mov [count], eax
    xor ecx, ecx                        ; ECX = a setting, EDX = categories
    xor edx, edx
.each:
    cmp ecx, [count]
    jae .counted
    mov eax, ecx
    imul eax, eax, SI_SIZE
    add rax, [list]
    mov rsi, rax                        ; its category: up to the dot
    xor r8d, r8d
.prefix:
    mov al, [rsi + r8]
    test al, al
    jz .prefixed
    cmp al, '.'
    je .prefixed
    inc r8d
    jmp .prefix
.prefixed:
    test edx, edx                       ; the same as the one before?
    jz .new
    lea r9d, [rdx - 1]
    cmp [cat_len + r9 * 4], r8d
    jne .new
    mov rdi, [cat_name + r9 * 8]
    push rcx
    mov ecx, r8d
    push rsi
    repe cmpsb
    pop rsi
    pop rcx
    jne .new
    inc dword [cat_count + r9 * 4]
    jmp .next
.new:
    cmp edx, CAT_MAX
    jae .next
    mov [cat_name + rdx * 8], rsi
    mov [cat_len + rdx * 4], r8d
    mov [cat_first + rdx * 4], ecx
    mov dword [cat_count + rdx * 4], 1
    inc edx
.next:
    inc ecx
    jmp .each
.counted:
    mov [cats], edx
    mov eax, [cat]
    cmp eax, edx
    jb .look
    mov dword [cat], 0
.look:
    jmp look

; look: the colours, as display.theme and display.accent have them
look:
    lea rsi, [p_dark]
    mov rdi, [list]
    xor ecx, ecx
.find:
    cmp ecx, [count]
    jae .copy
    push rsi
    push rcx
    lea rsi, [s_theme]
    call same
    pop rcx
    pop rsi
    jne .accent
    cmp qword [rdi + SI_VALUE], 1
    jne .accent
    lea rsi, [p_light]
.accent:
    push rsi
    push rcx
    lea rsi, [s_accent]
    call same
    pop rcx
    pop rsi
    jne .next
    mov eax, [rdi + SI_VALUE]
    mov [c_accent], eax
.next:
    add rdi, SI_SIZE
    inc ecx
    jmp .find
.copy:
    lea rdi, [c_bg]
    mov ecx, 7
    rep movsd
    mov eax, [c_accent]                 ; and what is written on it
    call on_colour
    mov [c_on_accent], eax
    ret

; same(RDI = a record's name, RSI = a name) -> ZF if they are the same.
; Preserves RDI.
same:
    push rdi
.char:
    mov al, [rsi]
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    test al, al
    jnz .char
.out:
    pop rdi
    ret

; on_colour(EAX = a colour) -> EAX = text that reads on it: dark or white
on_colour:
    push rcx
    push rdx
    mov ecx, eax
    shr ecx, 16
    and ecx, 0xFF
    imul edx, ecx, 299
    mov ecx, eax
    shr ecx, 8
    and ecx, 0xFF
    imul ecx, ecx, 587
    add edx, ecx
    and eax, 0xFF
    imul eax, eax, 114
    add edx, eax
    mov eax, 0xFFFFFF
    cmp edx, 165 * 1000
    jb .out
    mov eax, 0x1D1D1F
.out:
    pop rdx
    pop rcx
    ret

; record(ECX = a setting) -> RBX = its record
record:
    mov ebx, ecx
    imul ebx, ebx, SI_SIZE
    add rbx, [list]
    ret

; change(ECX = a setting, RDX = its new value) -> RAX = 0 or E_*
change:
    mov r8d, ecx
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_SET_CHANGE
    mov eax, [ax_settings]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_A0], r8
    mov [rsp + SQ_A1], rdx
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    ret

; change_text(ECX = a setting): to what the field holds -> RAX = 0 or E_*
change_text:
    mov rdi, [ax_io_va]
    lea rsi, [edit_buf]
    push rcx
    mov ecx, [edit_len]
    rep movsb
    pop rcx
    mov r8d, ecx
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_SET_CHANGE
    mov eax, [ax_settings]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A0], r8
    mov eax, [edit_len]
    mov [rsp + SQ_A2], rax
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    ret

; title: "Settings"
title:
    mov rdi, [ax_io_va]
    lea rsi, [s_title]
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [rdi + rcx], al
    inc ecx
    jmp .copy
.copied:
    sub rsp, SQ_SIZE
    push rcx
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    mov byte [rsp + SQ_OP], RO_WIN_TITLE
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], rcx
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    ret

; show: the whole window to the screen
show:
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WIN_SHOW
    mov eax, [win]
    mov [rsp + SQ_HANDLE], eax
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    ret

; -----------------------------------------------------------------------------
;  What the window says
; -----------------------------------------------------------------------------

; event: the next message from the window, seen to
event:
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_RECV
    mov eax, [ev_end]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [rx_mem]
    mov [rsp + SQ_HANDLE2], eax
    mov qword [rsp + SQ_A1], WE_SIZE
    mov rdi, rsp
    call op
    add rsp, SQ_SIZE
    cmp rax, WE_SIZE
    jl .out
    mov rsi, [rx]
    mov eax, [rsi + WE_KIND]
    cmp eax, WE_CLOSE
    je .close
    cmp eax, WE_KEY
    je key
    cmp eax, WE_PRESS
    je press
    cmp eax, WE_MOVE
    je move
    cmp eax, WE_RELEASE
    je .release
.out:
    ret
.close:
    mov byte [gone], 1
    ret
.release:
    mov dword [drag], -1
    ret

; key(RSI = the event)
key:
    mov eax, [rsi + WE_CODE]
    cmp dword [editing], 0
    jge .field
    cmp eax, KEY_ESC
    je .close
    cmp eax, KEY_UP
    je .up
    cmp eax, KEY_DOWN
    je .down
    ret
.close:
    mov byte [gone], 1
    ret
.up:
    cmp dword [cat], 0
    je .out
    dec dword [cat]
    jmp paint
.down:
    mov eax, [cat]
    inc eax
    cmp eax, [cats]
    jae .out
    mov [cat], eax
    jmp paint
.field:
    cmp eax, KEY_ESC
    je .cancel
    cmp eax, 13
    je .enter
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .back
    cmp eax, 127
    je .back
    cmp eax, ' '
    jb .out
    cmp eax, '~'
    ja .out
    mov ecx, [edit_len]
    cmp ecx, EDIT_MAX
    jae .out
    mov [edit_buf + rcx], al
    inc dword [edit_len]
    jmp paint
.back:
    cmp dword [edit_len], 0
    je .out
    dec dword [edit_len]
    jmp paint
.cancel:
    mov dword [editing], -1
    mov dword [wrong], -1
    jmp paint
.enter:
    mov ecx, [editing]
    call change_text
    test rax, rax
    js .refused
    mov dword [editing], -1
    mov dword [wrong], -1
    jmp paint
.refused:
    mov eax, [editing]
    mov [wrong], eax
    jmp paint
.out:
    ret

; press(RSI = the event): what was under the pointer, done
press:
    cmp dword [rsi + WE_CODE], 1
    jne .out
    mov edi, [rsi + WE_X]
    mov esi, [rsi + WE_Y]
    call hit
    test rbx, rbx
    jz .nothing
    push rsi                            ; a copy: painting makes them again
    push rdi
    mov rsi, rbx
    lea rdi, [pressed]
    lea rbx, [pressed]
    mov ecx, HT_SIZE
    rep movsb
    pop rdi
    pop rsi
    mov ecx, [rbx + HT_INDEX]
    mov eax, [rbx + HT_KIND]
    cmp eax, HK_FIELD
    je .field
    cmp dword [editing], 0              ; a click elsewhere ends the editing
    jl .kind
    mov dword [editing], -1
    mov dword [wrong], -1
    push rax
    push rcx
    push rdi
    call paint
    pop rdi
    pop rcx
    pop rax
.kind:
    cmp eax, HK_CAT
    je .cat
    cmp eax, HK_SWITCH
    je .switch
    cmp eax, HK_CHOICE
    je .choice
    cmp eax, HK_SWATCH
    je .choice
    cmp eax, HK_STEP
    je .step
    cmp eax, HK_SLIDER
    je .slider
.out:
    ret
.nothing:
    cmp dword [editing], 0
    jl .out
    mov dword [editing], -1
    mov dword [wrong], -1
    jmp paint
.cat:
    mov eax, [rbx + HT_ARG]
    mov [cat], eax
    jmp paint
.switch:
    push rbx
    call record
    mov rdx, [rbx + SI_VALUE]
    pop rbx
    xor edx, 1
    jmp change
.choice:
    mov edx, [rbx + HT_ARG]
    jmp change
.step:
    push rbx
    movsxd rax, dword [rbx + HT_ARG]
    call record
    imul rax, [rbx + SI_STEP]
    mov rdx, [rbx + SI_VALUE]
    add rdx, rax
    cmp rdx, [rbx + SI_MIN]
    jl .no_step
    cmp rdx, [rbx + SI_MAX]
    jg .no_step
    pop rbx
    jmp change
.no_step:
    pop rbx
    ret
.slider:
    mov [drag], ecx                     ; (EDI: the pointer's x)
    mov eax, [rbx + HT_X0]
    mov [drag_x0], eax
    mov eax, [rbx + HT_X1]
    mov [drag_x1], eax
    jmp slide
.field:
    cmp [editing], ecx
    je .out
    mov [editing], ecx
    mov dword [wrong], -1
    push rbx
    call record                         ; it starts as it is
    lea rsi, [rbx + SI_TEXT]
    pop rbx
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [edit_buf + rcx], al
    inc ecx
    cmp ecx, EDIT_MAX
    jb .copy
.copied:
    mov [edit_len], ecx
    jmp paint

; move(RSI = the event): a slider follows the pointer while it is held
move:
    cmp dword [drag], 0
    jl .out
    mov edi, [rsi + WE_X]
    jmp slide
.out:
    ret

; slide(EDI = the pointer's x): the slider being dragged, there
slide:
    mov ecx, [drag]
    call record
    mov eax, edi
    sub eax, [drag_x0]
    jge .left
    xor eax, eax
.left:
    mov r8d, [drag_x1]
    sub r8d, [drag_x0]
    cmp eax, r8d
    jle .right
    mov eax, r8d
.right:
    mov r9, [rbx + SI_MAX]              ; min + round(x * (max - min) / w / step) * step
    sub r9, [rbx + SI_MIN]
    imul rax, r9
    mov r10, [rbx + SI_STEP]
    test r10, r10
    jnz .stepped
    mov r10d, 1
.stepped:
    movsxd r8, r8d
    imul r8, r10                        ; RAX / (w * step), rounded
    mov rdx, r8
    shr rdx, 1
    add rax, rdx
    cqo
    idiv r8
    imul rax, r10
    add rax, [rbx + SI_MIN]
    cmp rax, [rbx + SI_VALUE]
    je .same
    mov rdx, rax
    jmp change
.same:
    ret

; hit(EDI = x, ESI = y) -> RBX = what is there (HT_*), 0 for nothing.
; Preserves RDI, RSI.
hit:
    lea rbx, [hits]
    mov ecx, [hit_n]
.next:
    test ecx, ecx
    jz .none
    cmp edi, [rbx + HT_X0]
    jl .skip
    cmp edi, [rbx + HT_X1]
    jge .skip
    cmp esi, [rbx + HT_Y0]
    jl .skip
    cmp esi, [rbx + HT_Y1]
    jge .skip
    ret
.skip:
    add rbx, HT_SIZE
    dec ecx
    jmp .next
.none:
    xor ebx, ebx
    ret

; add_hit(EDI = x, ESI = y, EDX = w, ECX = h, R8D = HK_*, R9D = setting,
; R10D = arg). Preserves all.
add_hit:
    push rax
    push rbx
    mov eax, [hit_n]
    cmp eax, HIT_MAX
    jae .out
    inc dword [hit_n]
    imul eax, eax, HT_SIZE
    lea rbx, [hits + rax]
    mov [rbx + HT_X0], edi
    mov [rbx + HT_Y0], esi
    lea eax, [rdi + rdx]
    mov [rbx + HT_X1], eax
    lea eax, [rsi + rcx]
    mov [rbx + HT_Y1], eax
    mov [rbx + HT_KIND], r8d
    mov [rbx + HT_INDEX], r9d
    mov [rbx + HT_ARG], r10d
.out:
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Drawing
; -----------------------------------------------------------------------------

; paint: the whole window, drawn and shown
paint:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov dword [hit_n], 0
    call clip_all
    xor edi, edi                        ; the window
    xor esi, esi
    mov edx, W
    mov ecx, H
    mov r8d, [c_panel]
    call fill_rect
    xor edi, edi                        ; the sidebar
    xor esi, esi
    mov edx, SIDE
    mov ecx, H
    mov r8d, [c_bg]
    call fill_rect
    mov edi, SIDE
    xor esi, esi
    mov edx, 1
    mov ecx, H
    mov r8d, [c_line]
    call fill_rect
    lea rsi, [s_title]
    mov edi, 32
    mov edx, 58
    mov r8d, F_HEAD
    mov r9d, [c_text]
    call text
    xor r12d, r12d                      ; each category
.cat:
    cmp r12d, [cats]
    jae .cards
    mov r13d, r12d
    imul r13d, r13d, CAT_H
    add r13d, CAT_TOP                   ; R13D = its top
    mov r14d, [c_text]
    cmp r12d, [cat]
    jne .cat_name
    mov edi, 16
    mov esi, r13d
    mov edx, SIDE - 32
    mov ecx, CAT_H - 8
    mov r8d, [c_accent]
    mov r9d, 10
    call rrect
    mov r14d, [c_on_accent]
.cat_name:
    mov rsi, [cat_name + r12 * 8]       ; capitalised
    mov ecx, [cat_len + r12 * 4]
    call label_of
    lea rsi, [label]
    mov edi, 36
    lea edx, [r13 + 29]
    mov r8d, F_LABEL
    mov r9d, r14d
    call text
    mov edi, 16
    mov esi, r13d
    mov edx, SIDE - 32
    mov ecx, CAT_H - 8
    mov r8d, HK_CAT
    xor r9d, r9d
    mov r10d, r12d
    call add_hit
    inc r12d
    jmp .cat
.cards:
    mov eax, [cats]
    test eax, eax
    jz .shown
    mov eax, [cat]                      ; its name, big
    mov rsi, [cat_name + rax * 8]
    mov ecx, [cat_len + rax * 4]
    call label_of
    lea rsi, [label]
    mov edi, CARD_X
    mov edx, 76
    mov r8d, F_TITLE
    mov r9d, [c_text]
    call text
    mov eax, [cat]
    mov r12d, [cat_first + rax * 4]     ; R12D = the setting
    mov r15d, [cat_count + rax * 4]
    add r15d, r12d                      ; R15D = past the category's last
    mov r13d, CARDS_TOP                 ; R13D = the card's top
.card:
    cmp r12d, r15d
    jae .shown
    mov ecx, r12d
    call record                         ; RBX = its record
    call card
    add r13d, CARD_H + CARD_GAP
    inc r12d
    jmp .card
.shown:
    call show
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; card(RBX = a record, R12D = which, R13D = the card's top): it, with its
; control. Preserves RBX, R12-R15.
card:
    mov edi, CARD_X
    mov esi, r13d
    mov edx, CARD_W
    mov ecx, CARD_H
    mov r8d, [c_card]
    mov r9d, 14
    call rrect
    mov rsi, rbx                        ; the name after the dot, as a label
.dot:
    lodsb
    test al, al
    jz .whole
    cmp al, '.'
    jne .dot
    jmp .named
.whole:
    mov rsi, rbx
.named:
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .label
    inc ecx
    jmp .len
.label:
    call label_of
    lea rsi, [label]
    mov edi, CARD_X + 24
    lea edx, [r13 + 40]
    mov r8d, F_LABEL
    mov r9d, [c_text]
    call text
    test dword [rbx + SI_FLAGS], SIF_RESTART
    jz .about
    lea rsi, [s_restart]                ; (EAX: past the label)
    lea edi, [rax + 14]
    lea edx, [r13 + 40]
    mov r8d, F_SMALL
    mov r9d, [c_faint]
    call text
.about:
    lea rsi, [rbx + SI_ABOUT]
    mov r9d, [c_dim]
    cmp [wrong], r12d
    jne .say
    lea rsi, [s_wrong]
    mov r9d, 0xFF453A
.say:
    mov dword [clip_x1], CARD_X + CARD_W - 24
    mov edi, CARD_X + 24
    lea edx, [r13 + 78]
    mov r8d, F_SMALL
    call text
    call clip_all
    mov eax, [rbx + SI_KIND]            ; the control, at the right
    cmp eax, SK_SWITCH
    je switch
    cmp eax, SK_CHOICE
    je choices
    cmp eax, SK_NUMBER
    je slider
    cmp eax, SK_COLOUR
    je swatches
    cmp eax, SK_ZONE
    je stepper
    cmp eax, SK_TEXT
    je field
    ret

CTL_RIGHT       equ CARD_X + CARD_W - 24 ; where controls end
CTL_Y           equ 16                  ; their top, in the card

; switch: a pill, the knob at the right when on
switch:
    mov edi, CTL_RIGHT - 60
    lea esi, [r13 + CTL_Y + 3]
    mov edx, 60
    mov ecx, 34
    mov r8d, [c_line]
    cmp qword [rbx + SI_VALUE], 0
    je .pill
    mov r8d, [c_accent]
.pill:
    mov r9d, 17
    call rrect
    mov edi, CTL_RIGHT - 60 + 3
    cmp qword [rbx + SI_VALUE], 0
    je .knob
    mov edi, CTL_RIGHT - 28 - 3
.knob:
    lea esi, [r13 + CTL_Y + 6]
    mov edx, 28
    mov ecx, 28
    mov r8d, 0xFFFFFF
    mov r9d, 14
    call rrect
    mov edi, CTL_RIGHT - 60
    lea esi, [r13 + CTL_Y + 3]
    mov edx, 60
    mov ecx, 34
    mov r8d, HK_SWITCH
    mov r9d, r12d
    xor r10d, r10d
    call add_hit
    ret

; choices: a segmented row, the chosen one filled
choices:
    push r14
    push r15
    lea rsi, [rbx + SI_CHOICES]         ; R14D = the width of them all
    xor r14d, r14d
    xor r15d, r15d                      ; R15D = how many
.measure:
    cmp r15, [rbx + SI_MAX]
    jae .measured
    call seg_w
    add r14d, eax
    call next_name
    inc r15d
    jmp .measure
.measured:
    mov edi, CTL_RIGHT                  ; the row: a trough
    sub edi, r14d
    lea esi, [r13 + CTL_Y]
    mov edx, r14d
    mov ecx, 40
    mov r8d, [c_line]
    mov r9d, 10
    call rrect
    mov r14d, edi                       ; R14D = the next segment's x
    lea rsi, [rbx + SI_CHOICES]
    xor r15d, r15d
.segment:
    cmp r15, [rbx + SI_MAX]
    jae .out
    call seg_w
    push rsi
    push rax
    mov r9d, [c_text]
    cmp r15, [rbx + SI_VALUE]
    jne .name
    lea edi, [r14 + 2]
    lea esi, [r13 + CTL_Y + 2]
    lea edx, [rax - 4]
    mov ecx, 36
    mov r8d, [c_accent]
    mov r9d, 8
    call rrect
    mov r9d, [c_on_accent]
.name:
    mov rsi, [rsp + 8]
    lea edi, [r14 + 18]
    lea edx, [r13 + CTL_Y + 26]
    mov r8d, F_SMALL
    call text
    mov edi, r14d
    lea esi, [r13 + CTL_Y]
    mov edx, [rsp]
    mov ecx, 40
    mov r8d, HK_CHOICE
    mov r9d, r12d
    mov r10d, r15d
    call add_hit
    pop rax
    pop rsi
    add r14d, eax
    call next_name
    inc r15d
    jmp .segment
.out:
    pop r15
    pop r14
    ret

; seg_w(RSI = a choice's name) -> EAX = its segment's width. Preserves
; others.
seg_w:
    push rdx
    push r11
    mov edx, F_SMALL
    call text_w
    add eax, 36
    pop r11
    pop rdx
    ret

; next_name(RSI = a name) -> RSI = the one after it
next_name:
    lodsb
    test al, al
    jnz next_name
    ret

; slider: a track, filled up to the value, a knob, and the value
slider:
    push r14
    lea rsi, [rbx + SI_TEXT]            ; the value, at the right
    mov edx, F_SMALL
    call text_w
    mov edi, CTL_RIGHT
    sub edi, eax
    lea edx, [r13 + CTL_Y + 26]
    mov r8d, F_SMALL
    mov r9d, [c_dim]
    call text
    SLIDER_W    equ 320
    SLIDER_X    equ CTL_RIGHT - 110 - SLIDER_W
    mov edi, SLIDER_X                   ; the track
    lea esi, [r13 + CTL_Y + 17]
    mov edx, SLIDER_W
    mov ecx, 6
    mov r8d, [c_line]
    mov r9d, 3
    call rrect
    mov rax, [rbx + SI_VALUE]           ; R14D = the knob's centre
    sub rax, [rbx + SI_MIN]
    imul rax, rax, SLIDER_W
    mov rcx, [rbx + SI_MAX]
    sub rcx, [rbx + SI_MIN]
    jg .span
    mov ecx, 1
.span:
    cqo
    idiv rcx
    lea r14d, [rax + SLIDER_X]
    mov edi, SLIDER_X                   ; filled to it
    lea esi, [r13 + CTL_Y + 17]
    mov edx, eax
    mov ecx, 6
    mov r8d, [c_accent]
    mov r9d, 3
    call rrect
    lea edi, [r14 - 15]                 ; the knob, ringed
    lea esi, [r13 + CTL_Y + 5]
    mov edx, 30
    mov ecx, 30
    mov r8d, [c_line]
    mov r9d, 15
    call rrect
    lea edi, [r14 - 14]
    lea esi, [r13 + CTL_Y + 6]
    mov edx, 28
    mov ecx, 28
    mov r8d, 0xFFFFFF
    mov r9d, 14
    call rrect
    mov edi, SLIDER_X
    lea esi, [r13 + CTL_Y]
    mov edx, SLIDER_W
    mov ecx, 40
    mov r8d, HK_SLIDER
    mov r9d, r12d
    xor r10d, r10d
    call add_hit
    pop r14
    ret

; swatches: a dot of each colour, the one chosen ringed
swatches:
    push r14
    push r15
    xor r15d, r15d                      ; how many
.count:
    cmp r15d, 16
    jae .counted
    cmp r15, [rbx + SI_MAX]
    jae .counted
    inc r15d
    jmp .count
.counted:
    imul r14d, r15d, -42
    add r14d, CTL_RIGHT                 ; R14D = the first's x
    xor ecx, ecx
.dot:
    cmp ecx, r15d
    jae .out
    push rcx
    mov eax, [rbx + SI_SWATCHES + rcx * 4]
    cmp rax, [rbx + SI_VALUE]
    jne .plain
    lea edi, [r14 + 2]                  ; chosen: a ring around it
    lea esi, [r13 + CTL_Y + 2]
    mov edx, 36
    mov ecx, 36
    mov r8d, [c_text]
    mov r9d, 18
    call rrect
    lea edi, [r14 + 5]
    lea esi, [r13 + CTL_Y + 5]
    mov edx, 30
    mov ecx, 30
    mov r8d, [c_card]
    mov r9d, 15
    call rrect
.plain:
    lea edi, [r14 + 7]
    lea esi, [r13 + CTL_Y + 7]
    mov edx, 26
    mov ecx, 26
    mov rax, [rsp]
    mov r8d, [rbx + SI_SWATCHES + rax * 4]
    mov r9d, 13
    call rrect
    mov rax, [rsp]
    mov edi, r14d
    lea esi, [r13 + CTL_Y]
    mov edx, 40
    mov ecx, 40
    mov r8d, HK_SWATCH
    mov r9d, r12d
    mov r10d, [rbx + SI_SWATCHES + rax * 4]
    call add_hit
    pop rcx
    add r14d, 42
    inc ecx
    jmp .dot
.out:
    pop r15
    pop r14
    ret

; stepper: [-] the value [+]
stepper:
    STEP_W      equ 190                 ; the value's room
    mov edi, CTL_RIGHT - 40
    mov r10d, 1
    lea rsi, [s_plus]
    call step_button
    mov edi, CTL_RIGHT - 40 - STEP_W - 40
    mov r10d, -1
    lea rsi, [s_minus]
    call step_button
    lea rsi, [rbx + SI_TEXT]            ; the value, centred
    mov edx, F_LABEL
    call text_w
    mov edi, CTL_RIGHT - 40 - STEP_W / 2
    shr eax, 1
    sub edi, eax
    lea edx, [r13 + CTL_Y + 28]
    mov r8d, F_LABEL
    mov r9d, [c_text]
    jmp text

; step_button(EDI = x, RSI = its sign, R10D = which way)
step_button:
    push rdi
    push rsi
    lea esi, [r13 + CTL_Y]
    mov edx, 40
    mov ecx, 40
    mov r8d, [c_line]
    mov r9d, 10
    call rrect
    mov edi, [rsp + 8]
    lea esi, [r13 + CTL_Y]
    mov edx, 40
    mov ecx, 40
    mov r8d, HK_STEP
    mov r9d, r12d
    call add_hit
    pop rsi
    pop rdi
    add edi, 14
    lea edx, [r13 + CTL_Y + 28]
    mov r8d, F_LABEL
    mov r9d, [c_text]
    jmp text

; field: a box with the text; while it is edited, what was typed and a
; caret
field:
    FIELD_W     equ 380
    mov edi, CTL_RIGHT - FIELD_W
    lea esi, [r13 + CTL_Y]
    mov edx, FIELD_W
    mov ecx, 40
    mov r8d, [c_line]
    cmp [editing], r12d
    jne .border
    mov r8d, [c_accent]
.border:
    mov r9d, 10
    call rrect
    mov edi, CTL_RIGHT - FIELD_W + 2
    lea esi, [r13 + CTL_Y + 2]
    mov edx, FIELD_W - 4
    mov ecx, 36
    mov r8d, [c_panel]
    mov r9d, 8
    call rrect
    mov edi, CTL_RIGHT - FIELD_W
    lea esi, [r13 + CTL_Y]
    mov edx, FIELD_W
    mov ecx, 40
    mov r8d, HK_FIELD
    mov r9d, r12d
    xor r10d, r10d
    call add_hit
    mov dword [clip_x1], CTL_RIGHT - 8
    cmp [editing], r12d
    je .editing
    lea rsi, [rbx + SI_TEXT]
    mov edi, CTL_RIGHT - FIELD_W + 14
    lea edx, [r13 + CTL_Y + 26]
    mov r8d, F_SMALL
    mov r9d, [c_text]
    call text
    jmp clip_all
.editing:
    lea rsi, [edit_buf]
    mov ecx, [edit_len]
    mov edi, CTL_RIGHT - FIELD_W + 14
    lea edx, [r13 + CTL_Y + 26]
    mov r8d, F_SMALL
    mov r9d, [c_text]
    xor r10d, r10d
    call draw_text
    lea edi, [rax + 1]                  ; the caret
    lea esi, [r13 + CTL_Y + 9]
    mov edx, 2
    mov ecx, 22
    mov r8d, [c_accent]
    call fill_rect
    jmp clip_all

; -----------------------------------------------------------------------------
;  Drawing's pieces
; -----------------------------------------------------------------------------

; clip_all: drawing anywhere in the window
clip_all:
    mov dword [clip_x0], 0
    mov dword [clip_y0], 0
    mov dword [clip_x1], W
    mov dword [clip_y1], H
    ret

; text(RSI = NUL-ended, EDI = x, EDX = baseline, R8D = font, R9D = colour)
; -> EAX = the pen's x after it. Preserves RBX, RBP, R12-R15.
text:
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .draw
    inc ecx
    jmp .len
.draw:
    xor r10d, r10d
    jmp draw_text

; text_w(RSI = NUL-ended, EDX = font) -> EAX = its width in pixels.
; Preserves all but RAX, R11.
text_w:
    push rcx
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .measure
    inc ecx
    jmp .len
.measure:
    call text_w64
    add eax, 63
    shr eax, 6
    pop rcx
    ret

; label_of(RSI = a name, ECX = its bytes): into label, as a person would
; write it: the first letter capital, a '-' a space
label_of:
    lea rdi, [label]
    mov r11, rdi
    cmp ecx, 47
    jbe .copy
    mov ecx, 47
.copy:
    test ecx, ecx
    jz .done
    lodsb
    cmp al, '-'
    jne .letter
    mov al, ' '
.letter:
    cmp rdi, r11
    jne .put
    cmp al, 'a'
    jb .put
    cmp al, 'z'
    ja .put
    sub al, 32
.put:
    stosb
    dec ecx
    jmp .copy
.done:
    mov byte [rdi], 0
    cmp word [label], 'Ip'              ; IPv4, IPv6: as they are written
    jne .out
    cmp byte [label + 2], 'v'
    jne .out
    mov byte [label + 1], 'P'
.out:
    ret

; rrect(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour, R9D = the
; corners' radius): filled, its corners round. Preserves RDI, RSI, RDX,
; RCX, R8, R9, RBX, R12-R15.
rrect:
    push rdi
    push rsi
    push rdx
    push rcx
    push r10
    push r11
    push rbx
    push rbp
    mov ebx, edi                        ; EBX, EBP = x, y; R10D = w; R11D = h
    mov ebp, esi
    mov r10d, edx
    mov r11d, ecx
    lea eax, [r9 + r9]                  ; a radius that fits
    cmp eax, r10d
    jle .w_fits
    mov r9d, r10d
    shr r9d, 1
.w_fits:
    lea eax, [r9 + r9]
    cmp eax, r11d
    jle .h_fits
    mov r9d, r11d
    shr r9d, 1
.h_fits:
    xor ecx, ecx                        ; ECX = the row
.row:
    cmp ecx, r11d
    jae .out
    xor eax, eax                        ; EAX = how far in, at its ends
    mov edx, r9d                        ; the corner's: from the nearer edge
    sub edx, ecx
    mov edi, ecx
    sub edi, r11d
    lea edi, [rdi + r9 + 1]
    cmp edi, edx
    cmovg edx, edi
    test edx, edx
    jle .fill
    push rcx                            ; r - sqrt(r^2 - (d - 1/2)^2)
    lea eax, [rdx + rdx - 1]
    imul eax, eax                       ; (2d - 1)^2
    mov ecx, r9d
    imul ecx, ecx
    shl ecx, 2
    sub ecx, eax                        ; (2r)^2 - (2d - 1)^2
    xor eax, eax
.root:
    lea edx, [rax + 1]
    imul edx, edx
    cmp edx, ecx
    jg .rooted
    inc eax
    jmp .root
.rooted:
    shr eax, 1                          ; sqrt of that, halved
    mov edx, r9d
    sub edx, eax
    mov eax, edx
    pop rcx
.fill:
    push rcx
    push rax
    lea edi, [rbx + rax]
    lea esi, [rbp + rcx]
    mov edx, r10d
    sub edx, eax
    sub edx, eax
    mov ecx, 1
    call fill_rect
    pop rax
    pop rcx
    inc ecx
    jmp .row
.out:
    pop rbp
    pop rbx
    pop r11
    pop r10
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    ret

%include "web/draw.inc"

section .rodata
; the look's colours (the kernel's look_dark and look_light): behind, a
; window, a card, a line, text, dim, faint
p_dark:         dd 0x0A0D13, 0x10151F, 0x161C29, 0x232B3B, 0xE6EDF3, 0x7D8796, 0x4A5262
p_light:        dd 0xE5E5EA, 0xFFFFFF, 0xF2F2F7, 0xD1D1D6, 0x1D1D1F, 0x6E6E73, 0xAEAEB2
s_theme:        db 'display.theme', 0
s_accent:       db 'display.accent', 0
s_title:        db 'Settings', 0
s_restart:      db 'at the next start', 0
s_wrong:        db 'Not one it takes: Enter keeps it, Esc puts it back', 0
s_plus:         db '+', 0
s_minus:        db 0xE2, 0x88, 0x92, 0
s_no_settings:  db "settings: not given the settings (run it as 'run settings', or '+settings')", 10, 0
s_no_desk:      db 'settings: no desktop to open a window on', 10, 0
s_refused:      db 'settings: refused: ', 0
; draw.inc reads a byte that is not UTF-8 as Windows-1252 (web/html.inc's)
cp1252:         dw 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021
                dw 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F
                dw 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014
                dw 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178

section .data
c_accent:       dd 0x5EEAD4

section .bss
alignb 8
list:           resq 1
dl_base:        resq 1                  ; (draw.inc's draw_list: not used)
dl_top:         resq 1
rx:             resq 1
op_result:      resq 1
cat_name:       resq CAT_MAX
cat_len:        resd CAT_MAX
cat_first:      resd CAT_MAX
cat_count:      resd CAT_MAX
c_bg:           resd 1                  ; the colours, from look (in p_dark's order)
c_panel:        resd 1
c_card:         resd 1
c_line:         resd 1
c_text:         resd 1
c_dim:          resd 1
c_faint:        resd 1
c_on_accent:    resd 1
list_mem:       resd 1
rx_mem:         resd 1
ev_end:         resd 1
win:            resd 1
count:          resd 1
cats:           resd 1
cat:            resd 1
editing:        resd 1                  ; the setting whose field is edited, or -1
edit_len:       resd 1
wrong:          resd 1                  ; the field that refused what was typed, or -1
drag:           resd 1                  ; the slider held, or -1
drag_x0:        resd 1
drag_x1:        resd 1
hit_n:          resd 1
hits:           resb HIT_MAX * HT_SIZE
pressed:        resb HT_SIZE            ; the one clicked
edit_buf:       resb EDIT_MAX + 1
label:          resb 48
w_channel:      resb 1                  ; a wait is armed on the window
w_settings:     resb 1                  ; and on the settings
ch_ready:       resb 1
set_dirty:      resb 1
op_done:        resb 1
gone:           resb 1

AXE_END
