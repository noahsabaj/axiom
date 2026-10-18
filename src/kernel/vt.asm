; =============================================================================
;  vt.asm - what a program's output says to its terminal, in xterm's words
;
;  A Linux program writes to its terminal (lxtty.asm) the way it would to
;  xterm: text in UTF-8, and escape sequences that move the cursor, erase,
;  scroll a region, set colors and attributes, switch to the alternate
;  screen, set modes and ask questions. vt_write reads them and changes the
;  terminal's cells (term.asm), under print_lock; the answers to questions
;  (where the cursor is, what the terminal is, its colors) wait in
;  TW_VREPLY for lxtty.asm, which gives them to the program as if typed.
;
;  The screen is the terminal's rows from TW_SCREEN down; the cursor is
;  TW_LINE and TW_CX, its row TW_LINE - TW_SCREEN. A cursor at TW_CX =
;  the columns has written the last column and wraps before the next
;  character. Scrolling the whole main screen puts its top row into the
;  scroll-back; the alternate screen, and a region, scroll in place. A
;  character is a glyph of the font (font_unicode), '?' if the font has
;  none, two cells if it is wide (vt_wide_ranges), none if it combines.
; =============================================================================

VT_ROWS_MAX     equ 256                 ; rows a screen has, at most
VT_SYNC_MS      equ 150                 ; synchronized output holds drawing this long, at most

VS_GROUND       equ 0                   ; the parser: text
VS_ESC          equ 1                   ; after ESC
VS_CSI          equ 2                   ; ESC [: parameters
VS_OSC          equ 3                   ; ESC ]: a string, to BEL or ST
VS_OSC_ESC      equ 4                   ; an ESC in it
VS_STR          equ 5                   ; DCS, APC, PM, SOS: a string, ignored
VS_STR_ESC      equ 6
VS_CHARSET      equ 7                   ; ESC ( and the like: the set's name next
VS_ESC_SKIP     equ 8                   ; ESC # or ESC %: one more byte, ignored
VS_CSI_IGNORE   equ 9                   ; a sequence not understood, to its end

VF_WRAP         equ 1 << 0              ; DECAWM
VF_CURSOR       equ 1 << 1              ; DECTCEM: the cursor shows
VF_APPCURSOR    equ 1 << 2              ; DECCKM: arrows as ESC O x
VF_ORIGIN       equ 1 << 3              ; DECOM
VF_INSERT       equ 1 << 4              ; IRM
VF_GRAPHICS     equ 1 << 5              ; G0 is DEC's line drawing set
VF_PASTE        equ 1 << 6              ; bracketed paste
VF_FOCUS        equ 1 << 7              ; focus events
VF_MOUSE        equ 1 << 8              ; mouse reports: clicks,
VF_MOUSE_DRAG   equ 1 << 9              ; drags,
VF_MOUSE_ANY    equ 1 << 10             ; any motion,
VF_MOUSE_SGR    equ 1 << 11             ; in SGR's form
VF_SYNC         equ 1 << 12             ; synchronized output
VF_ALT          equ 1 << 13             ; the alternate screen shows
VF_APPKEYPAD    equ 1 << 14             ; DECKPAM
VF_LNM          equ 1 << 15             ; LF is CR LF too
VF_BLINK        equ 1 << 16             ; the cursor blinks (kept, not shown)
VF_INITIAL      equ VF_WRAP | VF_CURSOR
VF_SAVED        equ 1 << 31             ; TW_VSFLAGS: a cursor was saved
VF_SAVE_MASK    equ VF_WRAP | VF_ORIGIN | VF_GRAPHICS

VT_ATTR_INITIAL equ COL_TEXT << CELL_FG

section .text

; vt_init(RDI = terminal): as a terminal starts. Preserves all.
vt_init:
    push rax
    mov dword [rdi + TW_VFLAGS], VF_INITIAL
    mov rax, VT_ATTR_INITIAL
    mov [rdi + TW_VATTR], rax
    mov dword [rdi + TW_VTOP], 0
    mov dword [rdi + TW_VBOT], -1
    mov dword [rdi + TW_VS], VS_GROUND
    pop rax
    ret

; vt_reset(RDI = terminal, ESI = 1 to put the cursor on a fresh line): as a
; program starts or ends: the main screen, and the modes a terminal starts
; with
vt_reset:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    mov rdx, rbx
    call vt_alt_leave
    mov rdi, rbx
    call vt_init
    mov byte [rdx + TW_VNEED], 0
    mov dword [rdx + TW_VSFLAGS], 0
    mov dword [rdx + TW_VREPLYN], 0
    call tm_mark
    test r12d, r12d
    jz .done
    cmp qword [rdx + TW_CX], 0
    je .done
    call tm_newline
.done:
    mov byte [term_dirty], 1
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop r12
    pop rbx
    ret

; vt_write(RDI = terminal, RSI = bytes, RDX = how many): what they say,
; done. Takes print_lock.
vt_write:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov r14, rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    mov rdx, r14
.byte:
    test r13, r13
    jz .done
    movzx eax, byte [r12]
    inc r12
    dec r13
    call vt_byte
    jmp .byte
.done:
    mov byte [term_dirty], 1
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The parser. Each takes RDX = the terminal (print_lock held), EAX = a
;  byte or a code point; each keeps RBX, RDX and R12-R15.
; -----------------------------------------------------------------------------

vt_byte:
    mov ecx, [rdx + TW_VS]
    cmp ecx, VS_OSC
    jae .strings
    cmp eax, 0x20
    jb .control
    cmp eax, 0x7F
    je .out
    test ecx, ecx
    jz vt_ground
    cmp ecx, VS_ESC
    je vt_esc
    jmp vt_csi
.control:
    cmp eax, 0x1B
    je .escape
    cmp eax, 0x18                       ; CAN, SUB: a sequence abandoned
    je .cancel
    cmp eax, 0x1A
    je .cancel
    jmp vt_control                      ; (the state stays)
.escape:
    mov byte [rdx + TW_VNEED], 0
    mov dword [rdx + TW_VS], VS_ESC
    mov byte [rdx + TW_VINTER], 0
    ret
.cancel:
    mov dword [rdx + TW_VS], VS_GROUND
.out:
    ret
.strings:
    cmp ecx, VS_OSC
    je .osc
    cmp ecx, VS_OSC_ESC
    je .osc_esc
    cmp ecx, VS_STR
    je .str
    cmp ecx, VS_STR_ESC
    je .str_esc
    cmp ecx, VS_CHARSET
    je .charset
    cmp ecx, VS_ESC_SKIP
    je .cancel
    cmp eax, 0x1B                       ; VS_CSI_IGNORE: to the final byte
    je .escape
    cmp eax, 0x40
    jb .out
    cmp eax, 0x7E
    ja .out
    jmp .cancel
.osc:
    cmp eax, 7
    je vt_osc_end
    cmp eax, 0x1B
    je .osc_escape
    cmp eax, 0x18
    je .cancel
    cmp eax, 0x1A
    je .cancel
    mov ecx, [rdx + TW_VOSCN]
    cmp ecx, VT_OSC - 1
    jae .out
    mov [rdx + TW_VOSC + rcx], al
    inc dword [rdx + TW_VOSCN]
    ret
.osc_escape:
    mov dword [rdx + TW_VS], VS_OSC_ESC
    ret
.osc_esc:
    cmp eax, '\'
    je vt_osc_end
.restart:
    mov dword [rdx + TW_VS], VS_ESC     ; an ESC beginning something else
    mov byte [rdx + TW_VINTER], 0
    jmp vt_byte
.str:
    cmp eax, 0x1B
    je .str_escape
    cmp eax, 7
    je .cancel
    cmp eax, 0x18
    je .cancel
    cmp eax, 0x1A
    je .cancel
    ret
.str_escape:
    mov dword [rdx + TW_VS], VS_STR_ESC
    ret
.str_esc:
    cmp eax, '\'
    je .cancel
    jmp .restart
.charset:
    mov dword [rdx + TW_VS], VS_GROUND
    cmp byte [rdx + TW_VINTER], '('     ; G0 alone matters
    jne .out
    and dword [rdx + TW_VFLAGS], ~VF_GRAPHICS
    cmp eax, '0'
    jne .out
    or dword [rdx + TW_VFLAGS], VF_GRAPHICS
    ret

; vt_ground(EAX = a byte, 0x20 and up): text, in UTF-8
vt_ground:
    cmp eax, 0x80
    jae .high
    cmp byte [rdx + TW_VNEED], 0
    je vt_print
    mov byte [rdx + TW_VNEED], 0        ; a character cut short
    push rax
    mov eax, 0xFFFD
    call vt_print
    pop rax
    jmp vt_print
.high:
    cmp eax, 0xC0
    jae .lead
    cmp byte [rdx + TW_VNEED], 0        ; a continuation
    je .bad
    mov ecx, [rdx + TW_VCP]
    shl ecx, 6
    and eax, 0x3F
    or eax, ecx
    mov [rdx + TW_VCP], eax
    dec byte [rdx + TW_VNEED]
    jz vt_print
    ret
.lead:
    cmp byte [rdx + TW_VNEED], 0
    je .start
    push rax
    mov byte [rdx + TW_VNEED], 0
    mov eax, 0xFFFD
    call vt_print
    pop rax
.start:
    cmp eax, 0xE0
    jb .two
    cmp eax, 0xF0
    jb .three
    cmp eax, 0xF8
    jae .bad
    and eax, 0x07
    mov cl, 3
    jmp .need
.three:
    and eax, 0x0F
    mov cl, 2
    jmp .need
.two:
    and eax, 0x1F
    mov cl, 1
.need:
    mov [rdx + TW_VCP], eax
    mov [rdx + TW_VNEED], cl
    ret
.bad:
    mov byte [rdx + TW_VNEED], 0
    mov eax, 0xFFFD
    jmp vt_print

; vt_print(EAX = a code point): written at the cursor
vt_print:
    push rbx
    push r12
    test dword [rdx + TW_VFLAGS], VF_GRAPHICS
    jz .charset
    cmp eax, 0x5F
    jb .charset
    cmp eax, 0x7E
    ja .charset
    lea rcx, [vt_dec_graphics]
    movzx eax, word [rcx + rax * 2 - 0x5F * 2]
.charset:
    call vt_width                       ; ECX = its cells
    test ecx, ecx
    jz .out
    mov [rdx + TW_VLAST], eax
    mov r12d, ecx                       ; R12 = its width
    call vt_glyph
    mov ebx, eax                        ; RBX = its glyph
    mov rcx, [rdx + TW_COLS_NOW]
    cmp r12, rcx
    jbe .fits
    mov r12d, 1                         ; (a window a column wide)
.fits:
    mov rax, [rdx + TW_CX]
    add rax, r12
    cmp rax, rcx
    jbe .room
    test dword [rdx + TW_VFLAGS], VF_WRAP
    jz .no_wrap
    mov qword [rdx + TW_CX], 0
    call vt_index
    jmp .room
.no_wrap:
    sub rcx, r12
    mov [rdx + TW_CX], rcx
.room:
    test dword [rdx + TW_VFLAGS], VF_INSERT
    jz .put
    mov ecx, r12d
    call vt_insert_cells
.put:
    call tm_cell
    mov rax, [rdx + TW_VATTR]
    or rax, rbx
    mov [rdi], rax
    cmp r12d, 2
    jne .one
    mov rax, [rdx + TW_VATTR]
    or rax, CA_WIDE << 8
    mov [rdi + 8], rax
.one:
    add [rdx + TW_CX], r12
    call tm_mark
.out:
    pop r12
    pop rbx
    ret

; vt_control(EAX = a C0 control but ESC, CAN and SUB)
vt_control:
    cmp eax, 8
    je .backspace
    cmp eax, 9
    je .tab
    cmp eax, 10
    jb .out
    cmp eax, 12
    jbe .feed                           ; LF, VT, FF
    cmp eax, 13
    je .cr
.out:
    ret
.backspace:
    call vt_col
    test rax, rax
    jz .out
    dec rax
    mov [rdx + TW_CX], rax
    jmp tm_mark
.tab:
    mov rax, [rdx + TW_CX]
    mov rcx, [rdx + TW_COLS_NOW]
    cmp rax, rcx
    jae .out
    add rax, 8
    and rax, -8
    dec rcx
    cmp rax, rcx
    jbe .tab_set
    mov rax, rcx
.tab_set:
    mov [rdx + TW_CX], rax
    jmp tm_mark
.feed:
    call vt_index
    test dword [rdx + TW_VFLAGS], VF_LNM
    jz .out
.cr:
    mov qword [rdx + TW_CX], 0
    jmp tm_mark

; vt_esc(EAX = the byte after ESC)
vt_esc:
    cmp eax, 0x30
    jae .final
    mov [rdx + TW_VINTER], al           ; ( ) * + - . / name a set;
    cmp eax, '('                        ; # % and space take one byte more
    jb .skip
    mov dword [rdx + TW_VS], VS_CHARSET
    ret
.skip:
    mov dword [rdx + TW_VS], VS_ESC_SKIP
    ret
.final:
    mov dword [rdx + TW_VS], VS_GROUND
    cmp eax, '['
    je .csi
    cmp eax, ']'
    je .osc
    cmp eax, 'P'
    je .str
    cmp eax, '_'
    je .str
    cmp eax, '^'
    je .str
    cmp eax, 'X'
    je .str
    cmp eax, '7'
    je vt_save_cursor
    cmp eax, '8'
    je vt_restore_cursor
    cmp eax, 'D'
    je vt_index
    cmp eax, 'E'
    je .nel
    cmp eax, 'M'
    je vt_rindex
    cmp eax, 'c'
    je vt_ris
    cmp eax, '='
    je .keypad
    cmp eax, '>'
    je .numpad
    ret
.csi:
    mov dword [rdx + TW_VS], VS_CSI
    xor eax, eax
    mov [rdx + TW_VNP], eax
    mov [rdx + TW_VCOLON], eax
    mov [rdx + TW_VPRIV], al
    mov [rdx + TW_VINTER], al
    ret
.osc:
    mov dword [rdx + TW_VS], VS_OSC
    mov dword [rdx + TW_VOSCN], 0
    ret
.str:
    mov dword [rdx + TW_VS], VS_STR
    ret
.nel:
    mov qword [rdx + TW_CX], 0
    call tm_mark
    jmp vt_index
.keypad:
    or dword [rdx + TW_VFLAGS], VF_APPKEYPAD
    ret
.numpad:
    and dword [rdx + TW_VFLAGS], ~VF_APPKEYPAD
    ret

; vt_csi(EAX = a byte of a CSI sequence)
vt_csi:
    cmp eax, '0'
    jb .not_digit
    cmp eax, '9'
    ja .not_digit
    call vt_param_slot
    sub eax, '0'
    mov esi, [rdx + TW_VP + rcx * 4]
    cmp esi, 99999
    ja .out
    imul esi, esi, 10
    add esi, eax
    mov [rdx + TW_VP + rcx * 4], esi
.out:
    ret
.not_digit:
    cmp eax, ';'
    je .next
    cmp eax, ':'
    je .next
    cmp eax, '<'
    jb .other
    cmp eax, '?'
    ja .other
    cmp dword [rdx + TW_VNP], 0         ; < = > ?: before any parameter
    jne .ignore
    cmp byte [rdx + TW_VPRIV], 0
    jne .ignore
    mov [rdx + TW_VPRIV], al
    ret
.other:
    cmp eax, 0x30
    jb .inter
    cmp eax, 0x40
    jb .ignore
    mov dword [rdx + TW_VS], VS_GROUND
    jmp vt_csi_dispatch
.inter:
    mov [rdx + TW_VINTER], al
    ret
.ignore:
    mov dword [rdx + TW_VS], VS_CSI_IGNORE
    ret
.next:
    call vt_param_slot
    mov ecx, [rdx + TW_VNP]
    cmp ecx, VT_PARAMS
    jae .out                            ; (more fold into the last)
    mov dword [rdx + TW_VP + rcx * 4], 0
    inc dword [rdx + TW_VNP]
    cmp eax, ':'
    jne .out
    bts dword [rdx + TW_VCOLON], ecx
    ret

; vt_param_slot -> RCX = the parameter being read (the first, made if
; there is none yet). Preserves others.
vt_param_slot:
    mov ecx, [rdx + TW_VNP]
    test ecx, ecx
    jnz .have
    mov dword [rdx + TW_VNP], 1
    mov dword [rdx + TW_VP], 0
    inc ecx
.have:
    dec ecx
    ret

; vt_param(ECX = which, EAX = its default) -> EAX = it (0 is the default).
; Preserves others.
vt_param:
    cmp ecx, [rdx + TW_VNP]
    jae .out
    cmp dword [rdx + TW_VP + rcx * 4], 0
    je .out
    mov eax, [rdx + TW_VP + rcx * 4]
.out:
    ret

; vt_p1 -> EAX = the first parameter, 1 by default
vt_p1:
    xor ecx, ecx
    mov eax, 1
    jmp vt_param

; vt_p0 -> EAX = the first parameter, 0 by default
vt_p0:
    xor ecx, ecx
    xor eax, eax
    jmp vt_param

; vt_csi_dispatch(EAX = the final byte)
vt_csi_dispatch:
    movzx ecx, byte [rdx + TW_VPRIV]
    test ecx, ecx
    jnz .private
    cmp byte [rdx + TW_VINTER], 0
    jne .inter
    sub eax, 0x40
    lea rcx, [vt_csi_table]
    mov rcx, [rcx + rax * 8]
    test rcx, rcx
    jz .out
    jmp rcx
.private:
    cmp ecx, '?'
    jne .greater
    cmp byte [rdx + TW_VINTER], '$'
    je .rqm_private
    cmp eax, 'h'
    je vt_decset
    cmp eax, 'l'
    je vt_decrst
    cmp eax, 'J'
    je vt_ed
    cmp eax, 'K'
    je vt_el
    cmp eax, 'n'
    je vt_dsr_private
    ret
.rqm_private:
    cmp eax, 'p'
    je vt_rqm_private
    ret
.greater:
    cmp ecx, '>'
    jne .out
    cmp eax, 'c'
    je vt_da2
    cmp eax, 'q'
    je vt_xtversion
    ret
.inter:
    mov cl, [rdx + TW_VINTER]
    cmp eax, 'p'
    jne .out
    cmp cl, '!'
    je vt_soft_reset
    cmp cl, '$'
    je vt_rqm
.out:
    ret

; -----------------------------------------------------------------------------
;  Where things are
; -----------------------------------------------------------------------------

; vt_row -> RAX = the cursor's row. Preserves others.
vt_row:
    mov rax, [rdx + TW_LINE]
    sub rax, [rdx + TW_SCREEN]
    jns .out
    xor eax, eax
.out:
    ret

; vt_col -> RAX = the cursor's column (the last, if it is to wrap).
; Preserves others.
vt_col:
    mov rax, [rdx + TW_CX]
    cmp rax, [rdx + TW_COLS_NOW]
    jb .out
    mov rax, [rdx + TW_COLS_NOW]
    dec rax
.out:
    ret

; vt_bot -> EAX = the scrolling region's last row. Preserves others.
vt_bot:
    mov eax, [rdx + TW_VBOT]
    cmp eax, [rdx + TW_ROWS_NOW]
    jb .out
    mov eax, [rdx + TW_ROWS_NOW]
    dec eax
.out:
    ret

; vt_top -> EAX = its first row. Preserves others.
vt_top:
    push rcx
    call vt_bot
    mov ecx, eax
    mov eax, [rdx + TW_VTOP]
    cmp eax, ecx
    jbe .out
    mov eax, ecx
.out:
    pop rcx
    ret

; vt_line_cells(RAX = a line) -> RDI = its cells. Preserves others.
vt_line_cells:
    push rax
    push rcx
    push rdx
    mov rdi, rdx
    xor edx, edx
    mov ecx, TW_LINES
    div rcx
    imul rdx, rdx, TW_COLS * 8
    add rdx, [rdi + TW_CELLS]
    mov rdi, rdx
    pop rdx
    pop rcx
    pop rax
    ret

; vt_extend(RAX = a line): the lines up to it written (blank), if they were
; not. Preserves all.
vt_extend:
    push rax
    push rcx
    push rdi
    push r8
    mov r8, rax
.more:
    mov rax, [rdx + TW_END]
    cmp rax, r8
    jge .out
    inc rax
    mov [rdx + TW_END], rax
    call vt_line_cells
    xor eax, eax
    mov ecx, TW_COLS
    rep stosq
    jmp .more
.out:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; vt_dirty_rows(EAX = first row, ECX = last): to draw again. Preserves all.
vt_dirty_rows:
    push rax
    push rcx
    mov eax, eax
    mov ecx, ecx
    add rax, [rdx + TW_SCREEN]
    add rcx, [rdx + TW_SCREEN]
    inc rcx
    cmp rax, [rdx + TW_DIRTY_LO]
    jae .lo
    mov [rdx + TW_DIRTY_LO], rax
.lo:
    cmp rcx, [rdx + TW_DIRTY_HI]
    jbe .hi
    mov [rdx + TW_DIRTY_HI], rcx
.hi:
    pop rcx
    pop rax
    ret

; vt_blank -> RAX = an erased cell: the background set, if one is.
; Preserves others.
vt_blank:
    mov rax, [rdx + TW_VATTR]
    test ah, CA_BG
    jz .none
    shr rax, CELL_BG
    shl rax, CELL_BG
    or rax, CA_BG << 8
    ret
.none:
    xor eax, eax
    ret

; vt_goto(ECX = column, EAX = row, signed, kept on the screen): the cursor
; there. Preserves all.
vt_goto:
    push rax
    push rcx
    push rsi
    call tm_mark
    test eax, eax
    jns .row_low
    xor eax, eax
.row_low:
    mov esi, [rdx + TW_ROWS_NOW]
    dec esi
    cmp eax, esi
    jle .row_high
    mov eax, esi
.row_high:
    test ecx, ecx
    jns .col_low
    xor ecx, ecx
.col_low:
    mov esi, [rdx + TW_COLS_NOW]
    dec esi
    cmp ecx, esi
    jle .col_high
    mov ecx, esi
.col_high:
    mov eax, eax
    add rax, [rdx + TW_SCREEN]
    call vt_extend
    mov [rdx + TW_LINE], rax
    mov ecx, ecx
    mov [rdx + TW_CX], rcx
    call tm_mark
    pop rsi
    pop rcx
    pop rax
    ret

; vt_home: the cursor to the first row (of the region, in origin mode)
vt_home:
    xor eax, eax
    test dword [rdx + TW_VFLAGS], VF_ORIGIN
    jz .go
    call vt_top
.go:
    xor ecx, ecx
    jmp vt_goto

; vt_index: the cursor a row down, the region scrolling up if it is at its
; bottom. Preserves all.
vt_index:
    push rax
    push rcx
    push r8
    push r9
    call vt_row
    mov r8d, eax
    call vt_bot
    cmp r8d, eax
    je .scroll
    mov ecx, [rdx + TW_ROWS_NOW]
    dec ecx
    cmp r8d, ecx
    jae .out                            ; the last row, below the region
    call tm_mark
    lea eax, [r8 + 1]
    add rax, [rdx + TW_SCREEN]
    call vt_extend
    mov [rdx + TW_LINE], rax
    call tm_mark
    jmp .out
.scroll:
    mov r8d, eax
    call vt_top
    mov ecx, eax
    mov r9d, 1
    call vt_scroll_up
.out:
    pop r9
    pop r8
    pop rcx
    pop rax
    ret

; vt_rindex: a row up, the region scrolling down if it is at its top.
; Preserves all.
vt_rindex:
    push rax
    push rcx
    push r8
    push r9
    call vt_row
    mov r8d, eax
    call vt_top
    cmp r8d, eax
    je .scroll
    test r8d, r8d
    jz .out
    call vt_col
    mov ecx, eax
    lea eax, [r8 - 1]
    call vt_goto
    jmp .out
.scroll:
    mov ecx, eax
    call vt_bot
    mov r8d, eax
    mov r9d, 1
    call vt_scroll_down
.out:
    pop r9
    pop r8
    pop rcx
    pop rax
    ret

; vt_scroll_up(ECX = first row, R8D = last, R9D = rows): the rows between
; up by that many, blank ones in at the bottom. The whole main screen
; scrolls into the scroll-back. Preserves all.
vt_scroll_up:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10d, ecx                       ; R10 = the first row
    mov eax, r8d
    sub eax, ecx
    inc eax
    cmp r9d, eax
    jbe .many
    mov r9d, eax
.many:
    test r9d, r9d
    jz .out
    test ecx, ecx
    jnz .move
    mov eax, [rdx + TW_ROWS_NOW]
    dec eax
    cmp r8d, eax
    jne .move
    test dword [rdx + TW_VFLAGS], VF_ALT
    jnz .move
    mov rax, [rdx + TW_SCREEN]          ; every row of the screen written,
    add rax, r8
    call vt_extend
.append:
    mov rax, [rdx + TW_END]             ; then new ones below them
    inc rax
    mov [rdx + TW_END], rax
    call vt_line_cells
    call vt_blank
    mov ecx, TW_COLS
    rep stosq
    call tm_scrolled
    inc qword [rdx + TW_LINE]           ; (the cursor keeps its row)
    dec r9d
    jnz .append
    jmp .marked
.move:
    mov rax, [rdx + TW_SCREEN]
    add rax, r8
    call vt_extend
    mov ebx, r10d                       ; EBX = the row being filled
.copy:
    mov eax, ebx
    add eax, r9d
    cmp eax, r8d
    ja .clear
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    mov rsi, rdi
    mov eax, ebx
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    mov ecx, TW_COLS
    rep movsq
    inc ebx
    jmp .copy
.clear:
    cmp ebx, r8d
    ja .marked
    mov eax, ebx
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    call vt_blank
    mov ecx, TW_COLS
    rep stosq
    inc ebx
    jmp .clear
.marked:
    mov eax, r10d
    mov ecx, r8d
    call vt_dirty_rows
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; vt_scroll_down(ECX = first row, R8D = last, R9D = rows): the rows between
; down by that many, blank ones in at the top. Preserves all.
vt_scroll_down:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10d, ecx
    mov eax, r8d
    sub eax, ecx
    inc eax
    cmp r9d, eax
    jbe .many
    mov r9d, eax
.many:
    test r9d, r9d
    jz .out
    mov rax, [rdx + TW_SCREEN]
    add rax, r8
    call vt_extend
    mov ebx, r8d                        ; EBX = the row being filled
.copy:
    mov eax, ebx
    sub eax, r9d
    cmp eax, r10d
    jl .clear
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    mov rsi, rdi
    mov eax, ebx
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    mov ecx, TW_COLS
    rep movsq
    dec ebx
    jmp .copy
.clear:
    cmp ebx, r10d
    jl .marked
    mov eax, ebx
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    call vt_blank
    mov ecx, TW_COLS
    rep stosq
    dec ebx
    jmp .clear
.marked:
    mov eax, r10d
    mov ecx, r8d
    call vt_dirty_rows
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; vt_erase(EAX = row, ECX = first column, R8D = past the last, at most
; TW_COLS): those cells blank. Preserves all.
vt_erase:
    push rax
    push rcx
    push rdi
    push r8
    cmp ecx, r8d
    jae .out
    push rcx
    mov ecx, eax
    call vt_dirty_rows
    pop rcx
    mov eax, eax
    add rax, [rdx + TW_SCREEN]
    call vt_extend
    call vt_line_cells
    mov ecx, ecx
    lea rdi, [rdi + rcx * 8]
    sub r8d, ecx
    mov ecx, r8d
    call vt_blank
    rep stosq
.out:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; vt_erase_row(EAX = row): all of it. Preserves all.
vt_erase_row:
    push rcx
    push r8
    xor ecx, ecx
    mov r8d, TW_COLS
    call vt_erase
    pop r8
    pop rcx
    ret

; vt_insert_cells(ECX = how many): blanks at the cursor, what is there
; and after it moving right (off the edge). Preserves all.
vt_insert_cells:
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, ecx                        ; R9 = how many
    call vt_col
    mov r8, rax                         ; R8 = the column
    mov rcx, [rdx + TW_COLS_NOW]
    sub rcx, r8                         ; RCX = cells from it to the edge
    jbe .out
    cmp r9, rcx
    jbe .many
    mov r9, rcx
.many:
    sub rcx, r9                         ; RCX = cells that move
    mov rax, [rdx + TW_LINE]
    call vt_line_cells
    lea r8, [rdi + r8 * 8]              ; R8 = the cursor's cell
    lea rsi, [r8 + rcx * 8 - 8]         ; the last that moves,
    lea rdi, [rsi + r9 * 8]             ; to its place
    std
    rep movsq
    cld
    mov rdi, r8
    mov rcx, r9
    call vt_blank
    rep stosq
    call tm_mark
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; vt_delete_cells(ECX = how many): those at the cursor gone, what is after
; them moving left, blanks in at the edge. Preserves all.
vt_delete_cells:
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    mov r9d, ecx
    call vt_col
    mov r8, rax
    mov rcx, [rdx + TW_COLS_NOW]
    sub rcx, r8
    jbe .out
    cmp r9, rcx
    jbe .many
    mov r9, rcx
.many:
    sub rcx, r9
    mov rax, [rdx + TW_LINE]
    call vt_line_cells
    lea rdi, [rdi + r8 * 8]
    lea rsi, [rdi + r9 * 8]
    rep movsq
    mov rcx, r9
    call vt_blank
    rep stosq
    call tm_mark
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; vt_save_cursor (ESC 7, CSI s, 1048): the cursor, its attributes, the
; modes that go with it. Preserves all.
vt_save_cursor:
    push rax
    mov rax, [rdx + TW_CX]
    mov [rdx + TW_VSX], rax
    call vt_row
    mov [rdx + TW_VSY], rax
    mov rax, [rdx + TW_VATTR]
    mov [rdx + TW_VSATTR], rax
    mov eax, [rdx + TW_VFLAGS]
    and eax, VF_SAVE_MASK
    or eax, VF_SAVED
    mov [rdx + TW_VSFLAGS], eax
    pop rax
    ret

; vt_restore_cursor (ESC 8, CSI u): them back; home and plain if none were
; saved. Preserves all.
vt_restore_cursor:
    push rax
    push rcx
    test dword [rdx + TW_VSFLAGS], VF_SAVED
    jnz .saved
    mov dword [rdx + TW_VSFLAGS], VF_WRAP | VF_SAVED
    mov qword [rdx + TW_VSX], 0
    mov qword [rdx + TW_VSY], 0
    mov rax, VT_ATTR_INITIAL
    mov [rdx + TW_VSATTR], rax
.saved:
    mov rax, [rdx + TW_VSATTR]
    mov [rdx + TW_VATTR], rax
    mov eax, [rdx + TW_VFLAGS]
    and eax, ~VF_SAVE_MASK
    mov ecx, [rdx + TW_VSFLAGS]
    and ecx, VF_SAVE_MASK
    or eax, ecx
    mov [rdx + TW_VFLAGS], eax
    mov rcx, [rdx + TW_VSX]
    mov rax, [rdx + TW_VSY]
    call vt_goto
    pop rcx
    pop rax
    ret

; vt_alt_enter: the alternate screen, blank; the main one's rows and cursor
; kept. Preserves all.
vt_alt_enter:
    test dword [rdx + TW_VFLAGS], VF_ALT
    jnz .ret
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    cmp qword [rdx + TW_VALT], 0
    je .kept
    mov ecx, [rdx + TW_ROWS_NOW]
    mov [rdx + TW_VALTN], ecx
    mov rax, [rdx + TW_SCREEN]
    add rax, rcx
    dec rax
    call vt_extend
    xor r8d, r8d
.save:
    cmp r8d, [rdx + TW_VALTN]
    jae .saved
    mov eax, r8d
    add rax, [rdx + TW_SCREEN]
    call vt_line_cells
    mov rsi, rdi
    mov eax, r8d
    imul eax, eax, TW_COLS * 8
    mov rdi, [rdx + TW_VALT]
    add rdi, rax
    mov ecx, TW_COLS
    rep movsq
    inc r8d
    jmp .save
.saved:
    mov rax, [rdx + TW_CX]
    mov [rdx + TW_VALTX], rax
    call vt_row
    mov [rdx + TW_VALTY], rax
.kept:
    or dword [rdx + TW_VFLAGS], VF_ALT
    xor r8d, r8d
.clear:
    cmp r8d, [rdx + TW_ROWS_NOW]
    jae .cleared
    mov eax, r8d
    call vt_erase_row
    inc r8d
    jmp .clear
.cleared:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
.ret:
    ret

; vt_alt_leave: the main screen back, as it was. Preserves all.
vt_alt_leave:
    test dword [rdx + TW_VFLAGS], VF_ALT
    jz .ret
    and dword [rdx + TW_VFLAGS], ~VF_ALT
    push rax
    push rcx
    push rsi
    push rdi
    push r8
    xor r8d, r8d
.row:
    cmp r8d, [rdx + TW_ROWS_NOW]
    jae .done
    cmp qword [rdx + TW_VALT], 0
    je .blank
    cmp r8d, [rdx + TW_VALTN]
    jae .blank
    mov eax, r8d
    add rax, [rdx + TW_SCREEN]
    call vt_extend
    call vt_line_cells
    mov eax, r8d
    imul eax, eax, TW_COLS * 8
    mov rsi, [rdx + TW_VALT]
    add rsi, rax
    mov ecx, TW_COLS
    rep movsq
    jmp .next
.blank:
    mov eax, r8d
    call vt_erase_row
.next:
    inc r8d
    jmp .row
.done:
    xor eax, eax
    mov ecx, [rdx + TW_ROWS_NOW]
    dec ecx
    call vt_dirty_rows
    mov rcx, [rdx + TW_VALTX]
    mov rax, [rdx + TW_VALTY]
    call vt_goto
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rax
.ret:
    ret

; vt_ris (ESC c): everything as a terminal starts, the screen blank
vt_ris:
    call vt_alt_leave
    mov rdi, rdx
    call vt_init
    mov dword [rdx + TW_VSFLAGS], 0
    xor r8d, r8d
.clear:
    cmp r8d, [rdx + TW_ROWS_NOW]
    jae .cleared
    mov eax, r8d
    call vt_erase_row
    inc r8d
    jmp .clear
.cleared:
    jmp vt_home

; vt_soft_reset (CSI ! p): the modes and attributes as they start; the
; screen stays
vt_soft_reset:
    mov eax, [rdx + TW_VFLAGS]
    and eax, VF_ALT
    or eax, VF_INITIAL
    mov [rdx + TW_VFLAGS], eax
    mov rax, VT_ATTR_INITIAL
    mov [rdx + TW_VATTR], rax
    mov dword [rdx + TW_VTOP], 0
    mov dword [rdx + TW_VBOT], -1
    mov dword [rdx + TW_VSFLAGS], 0
    jmp tm_mark

; -----------------------------------------------------------------------------
;  CSI sequences: the cursor
; -----------------------------------------------------------------------------

vt_cuu:                                 ; CSI n A
    call vt_p1
    mov r8d, eax
    call vt_row
    mov r9d, eax
    sub eax, r8d
    mov r10d, eax                       ; R10 = the row it goes to
    call vt_top
    cmp r9d, eax                        ; in the region: no further than its top
    jl vt_go_r10
    cmp r10d, eax
    jge vt_go_r10
    mov r10d, eax
vt_go_r10:
    call vt_col
    mov ecx, eax
    mov eax, r10d
    jmp vt_goto

vt_cud:                                 ; CSI n B
    call vt_p1
    mov r8d, eax
    call vt_row
    mov r9d, eax
    add eax, r8d
    mov r10d, eax
    call vt_bot
    cmp r9d, eax
    jg vt_go_r10
    cmp r10d, eax
    jle vt_go_r10
    mov r10d, eax
    jmp vt_go_r10

vt_cuf:                                 ; CSI n C
    call vt_p1
    mov r8d, eax
    call vt_col
    lea ecx, [rax + r8]
    jmp vt_go_col

vt_cub:                                 ; CSI n D
    call vt_p1
    mov r8d, eax
    call vt_col
    mov ecx, eax
    sub ecx, r8d
vt_go_col:                              ; ECX = the column, the row as it is
    call vt_row
    jmp vt_goto

vt_cnl:                                 ; CSI n E
    call vt_cud
    jmp vt_cr

vt_cpl:                                 ; CSI n F
    call vt_cuu
vt_cr:
    mov qword [rdx + TW_CX], 0
    jmp tm_mark

vt_cha:                                 ; CSI n G, CSI n `
    call vt_p1
    lea ecx, [rax - 1]
    jmp vt_go_col

vt_hpr:                                 ; CSI n a
    jmp vt_cuf

vt_vpa:                                 ; CSI n d
    call vt_p1
    lea r10d, [rax - 1]
    test dword [rdx + TW_VFLAGS], VF_ORIGIN
    jz vt_go_r10
    call vt_top
    add r10d, eax
    jmp vt_go_r10

vt_vpr:                                 ; CSI n e
    jmp vt_cud

vt_cup:                                 ; CSI row ; col H, f
    call vt_p1
    lea r10d, [rax - 1]
    mov ecx, 1
    mov eax, 1
    call vt_param
    lea r9d, [rax - 1]                  ; R9 = the column
    test dword [rdx + TW_VFLAGS], VF_ORIGIN
    jz .go
    call vt_top
    add r10d, eax
    call vt_bot
    cmp r10d, eax
    jle .go
    mov r10d, eax
.go:
    mov ecx, r9d
    mov eax, r10d
    jmp vt_goto

vt_cht:                                 ; CSI n I: tab stops forward
    call vt_p1
    mov ecx, eax
    call vt_col
    shr eax, 3
    add eax, ecx
    shl eax, 3
    mov ecx, eax
    jmp vt_go_col

vt_cbt:                                 ; CSI n Z: back
    call vt_p1
    mov r8d, eax
    call vt_col
    mov ecx, eax
.back:
    test ecx, ecx
    jz vt_go_col
    dec ecx
    and ecx, -8
    dec r8d
    jnz .back
    jmp vt_go_col

; -----------------------------------------------------------------------------
;  CSI sequences: erasing, inserting, scrolling
; -----------------------------------------------------------------------------

vt_ed:                                  ; CSI n J
    call vt_p0
    cmp eax, 1
    je .above
    cmp eax, 2
    je .all
    cmp eax, 3
    je .back
    call vt_row                         ; 0: from the cursor down
    mov r9d, eax
    call vt_col
    mov ecx, eax
    mov eax, r9d
    mov r8d, TW_COLS
    call vt_erase
.below:
    inc r9d
    cmp r9d, [rdx + TW_ROWS_NOW]
    jae .out
    mov eax, r9d
    call vt_erase_row
    jmp .below
.above:
    call vt_row
    mov r9d, eax
    call vt_col
    lea r8d, [rax + 1]
    xor ecx, ecx
    mov eax, r9d
    call vt_erase
.up:
    test r9d, r9d
    jz .out
    dec r9d
    mov eax, r9d
    call vt_erase_row
    jmp .up
.all:
    xor r9d, r9d
.row:
    cmp r9d, [rdx + TW_ROWS_NOW]
    jae .out
    mov eax, r9d
    call vt_erase_row
    inc r9d
    jmp .row
.back:
    mov rax, [rdx + TW_SCREEN]          ; 3: the scroll-back, forgotten
    mov [rdx + TW_FLOOR], rax
    mov qword [rdx + TW_BACK], 0
    mov qword [rdx + TW_SHOWN], -1
.out:
    ret

vt_el:                                  ; CSI n K
    call vt_p0
    mov r9d, eax
    call vt_col
    mov ecx, eax
    call vt_row
    cmp r9d, 1
    je .left
    cmp r9d, 2
    je vt_erase_row
    mov r8d, TW_COLS                    ; 0: the cursor to the end
    jmp vt_erase
.left:
    lea r8d, [rcx + 1]
    xor ecx, ecx
    jmp vt_erase

vt_ech:                                 ; CSI n X
    call vt_p1
    mov r8d, eax
    call vt_col
    mov ecx, eax
    add r8d, ecx
    cmp r8d, [rdx + TW_COLS_NOW]
    jbe .erase
    mov r8d, [rdx + TW_COLS_NOW]
.erase:
    call vt_row
    jmp vt_erase

vt_ich:                                 ; CSI n @
    call vt_p1
    mov ecx, eax
    jmp vt_insert_cells

vt_dch:                                 ; CSI n P
    call vt_p1
    mov ecx, eax
    jmp vt_delete_cells

vt_il:                                  ; CSI n L: lines in, at the cursor's
    mov r11d, 1
    jmp vt_lines
vt_dl:                                  ; CSI n M: lines out
    xor r11d, r11d
vt_lines:
    call vt_p1
    mov r9d, eax
    call vt_row
    mov ecx, eax
    call vt_top
    cmp ecx, eax
    jb .out
    call vt_bot
    cmp ecx, eax
    ja .out
    mov r8d, eax
    test r11d, r11d
    jz .delete
    call vt_scroll_down
    jmp vt_cr
.delete:
    call vt_scroll_up
    jmp vt_cr
.out:
    ret

vt_su:                                  ; CSI n S
    call vt_p1
    mov r9d, eax
    call vt_top
    mov ecx, eax
    call vt_bot
    mov r8d, eax
    jmp vt_scroll_up

vt_sd:                                  ; CSI n T
    cmp dword [rdx + TW_VNP], 1         ; (five of them: a mouse's, ignored)
    ja .out
    call vt_p1
    mov r9d, eax
    call vt_top
    mov ecx, eax
    call vt_bot
    mov r8d, eax
    jmp vt_scroll_down
.out:
    ret

vt_rep:                                 ; CSI n b: the last character again
    call vt_p1
    mov ecx, [rdx + TW_COLS_NOW]
    imul ecx, [rdx + TW_ROWS_NOW]
    cmp eax, ecx
    jbe .count
    mov eax, ecx
.count:
    mov r8d, [rdx + TW_VLAST]
    test r8d, r8d
    jz .out
    push rbx
    mov ebx, eax
.again:
    mov eax, r8d
    push r8
    call vt_print
    pop r8
    dec ebx
    jnz .again
    pop rbx
.out:
    ret

vt_stbm:                                ; CSI top ; bottom r
    call vt_p1
    mov r8d, eax
    mov ecx, 1
    mov eax, [rdx + TW_ROWS_NOW]
    call vt_param
    cmp eax, [rdx + TW_ROWS_NOW]
    jbe .bottom
    mov eax, [rdx + TW_ROWS_NOW]
.bottom:
    cmp r8d, eax
    jae .out
    dec r8d
    mov [rdx + TW_VTOP], r8d
    dec eax
    mov ecx, [rdx + TW_ROWS_NOW]
    dec ecx
    cmp eax, ecx
    jne .set
    mov eax, -1                         ; the screen's last row, however many
.set:
    mov [rdx + TW_VBOT], eax
    jmp vt_home
.out:
    ret

vt_scosc:                               ; CSI s (with no parameters)
    cmp dword [rdx + TW_VNP], 0
    jne .out
    jmp vt_save_cursor
.out:
    ret

vt_scorc:                               ; CSI u
    cmp dword [rdx + TW_VNP], 0
    jne .out
    jmp vt_restore_cursor
.out:
    ret

; -----------------------------------------------------------------------------
;  CSI sequences: modes
; -----------------------------------------------------------------------------

vt_sm:                                  ; CSI 4 h, CSI 20 h
    mov r11d, 1
    jmp vt_ansi_modes
vt_rm:
    xor r11d, r11d
vt_ansi_modes:
    xor ecx, ecx
.each:
    cmp ecx, [rdx + TW_VNP]
    jae .out
    mov eax, [rdx + TW_VP + rcx * 4]
    xor esi, esi
    cmp eax, 4
    jne .lnm
    mov esi, VF_INSERT
.lnm:
    cmp eax, 20
    jne .set
    mov esi, VF_LNM
.set:
    test r11d, r11d
    jz .reset
    or [rdx + TW_VFLAGS], esi
    jmp .next
.reset:
    not esi
    and [rdx + TW_VFLAGS], esi
.next:
    inc ecx
    jmp .each
.out:
    ret

; vt_mode_flag(EAX = a private mode) -> ECX = its VF_* flag, 0 if not
; known. Preserves others.
vt_mode_flag:
    push rsi
    lea rsi, [vt_modes]
.find:
    mov ecx, [rsi]
    test ecx, ecx
    jz .out
    cmp eax, ecx
    je .found
    add rsi, 8
    jmp .find
.found:
    mov ecx, [rsi + 4]
.out:
    pop rsi
    ret

vt_decset:                              ; CSI ? n h
    mov r11d, 1
    jmp vt_decmode
vt_decrst:                              ; CSI ? n l
    xor r11d, r11d
vt_decmode:
    push rbx
    push r12
    push r13
    mov r13d, r11d                      ; R13 = 1 to set
    xor ebx, ebx
.each:
    cmp ebx, [rdx + TW_VNP]
    jae .done
    mov r12d, [rdx + TW_VP + rbx * 4]
    cmp r12d, 1049
    je .alt_cursor
    cmp r12d, 1047
    je .alt
    cmp r12d, 47
    je .alt
    cmp r12d, 1048
    je .cursor_saved
    mov eax, r12d
    call vt_mode_flag
    test ecx, ecx
    jz .next
    test r13d, r13d
    jz .reset
    or [rdx + TW_VFLAGS], ecx
    jmp .after
.reset:
    not ecx
    and [rdx + TW_VFLAGS], ecx
.after:
    cmp r12d, 6
    je .home
    cmp r12d, 25
    je .cursor
    cmp r12d, 2026
    je .sync
    jmp .next
.home:
    call vt_home
    jmp .next
.cursor:
    call tm_mark
    jmp .next
.sync:
    test r13d, r13d
    jz .next
    push rdx
    RDTSC64
    pop rdx
    mov [rdx + TW_VSYNC], rax
    jmp .next
.alt_cursor:
    test r13d, r13d
    jz .alt_cursor_off
    test dword [rdx + TW_VFLAGS], VF_ALT
    jnz .next
    call vt_save_cursor
    call vt_alt_enter
    jmp .next
.alt_cursor_off:
    test dword [rdx + TW_VFLAGS], VF_ALT
    jz .next
    call vt_alt_leave
    call vt_restore_cursor
    jmp .next
.alt:
    test r13d, r13d
    jz .alt_off
    call vt_alt_enter
    jmp .next
.alt_off:
    call vt_alt_leave
    jmp .next
.cursor_saved:
    test r13d, r13d
    jz .restore
    call vt_save_cursor
    jmp .next
.restore:
    call vt_restore_cursor
.next:
    inc ebx
    jmp .each
.done:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  CSI sequences: attributes (SGR)
; -----------------------------------------------------------------------------

vt_sgr:                                 ; CSI ... m
    push rbx
    push r12
    mov r12, [rdx + TW_VATTR]           ; R12 = the attributes being made
    xor ebx, ebx                        ; EBX = the parameter
    cmp dword [rdx + TW_VNP], 0
    jne .each
    mov dword [rdx + TW_VNP], 1         ; CSI m is CSI 0 m
    mov dword [rdx + TW_VP], 0
.each:
    cmp ebx, [rdx + TW_VNP]
    jae .done
    mov eax, [rdx + TW_VP + rbx * 4]
    test eax, eax
    jz .reset
    cmp eax, 1
    je .bold
    cmp eax, 2
    je .dim
    cmp eax, 3
    je .italic
    cmp eax, 4
    je .under
    cmp eax, 7
    je .inverse
    cmp eax, 8
    je .hidden
    cmp eax, 21
    je .under_on
    cmp eax, 22
    je .normal
    cmp eax, 23
    je .not_italic
    cmp eax, 24
    je .not_under
    cmp eax, 27
    je .not_inverse
    cmp eax, 28
    je .not_hidden
    cmp eax, 30
    jb .next
    cmp eax, 37
    jbe .fg_base
    cmp eax, 38
    je .fg_more
    cmp eax, 39
    je .fg_default
    cmp eax, 47
    jbe .bg_base
    cmp eax, 48
    je .bg_more
    cmp eax, 49
    je .bg_default
    cmp eax, 58
    je .ul_more
    cmp eax, 90
    jb .next
    cmp eax, 97
    jbe .fg_bright
    cmp eax, 100
    jb .next
    cmp eax, 107
    jbe .bg_bright
    jmp .next
.reset:
    mov r12, VT_ATTR_INITIAL
    jmp .next
.bold:
    or r12, CA_BOLD << 8
    jmp .next
.dim:
    or r12, CA_DIM << 8
    jmp .next
.italic:
    or r12, CA_ITALIC << 8
    jmp .next
.under:
    lea ecx, [rbx + 1]                  ; 4:0 is off, 4:n a kind of on
    cmp ecx, [rdx + TW_VNP]
    jae .under_on
    bt dword [rdx + TW_VCOLON], ecx
    jnc .under_on
    inc ebx
    cmp dword [rdx + TW_VP + rcx * 4], 0
    je .not_under
.under_on:
    or r12, CA_UNDER << 8
    jmp .next
.inverse:
    or r12, CA_INVERSE << 8
    jmp .next
.hidden:
    or r12, CA_HIDDEN << 8
    jmp .next
.normal:
    and r12, ~((CA_BOLD | CA_DIM) << 8)
    jmp .next
.not_italic:
    and r12, ~(CA_ITALIC << 8)
    jmp .next
.not_under:
    and r12, ~(CA_UNDER << 8)
    jmp .next
.not_inverse:
    and r12, ~(CA_INVERSE << 8)
    jmp .next
.not_hidden:
    and r12, ~(CA_HIDDEN << 8)
    jmp .next
.fg_base:
    sub eax, 30
    jmp .fg_index
.fg_bright:
    sub eax, 90 - 8
.fg_index:
    call vt_color256
    jmp .fg
.fg_more:
    call vt_sgr_color
    test eax, eax
    js .next
    jmp .fg
.fg_default:
    mov eax, COL_TEXT
.fg:
    mov rcx, ~(0xFFFFFF << CELL_FG)
    and r12, rcx
    shl rax, CELL_FG
    or r12, rax
    jmp .next
.bg_base:
    sub eax, 40
    jmp .bg_index
.bg_bright:
    sub eax, 100 - 8
.bg_index:
    call vt_color256
    jmp .bg
.bg_more:
    call vt_sgr_color
    test eax, eax
    js .next
.bg:
    mov rcx, ~(0xFFFFFF << CELL_BG)
    and r12, rcx
    shl rax, CELL_BG
    or rax, CA_BG << 8
    or r12, rax
    jmp .next
.bg_default:
    mov rcx, ~((0xFFFFFF << CELL_BG) | (CA_BG << 8))
    and r12, rcx
    jmp .next
.ul_more:
    call vt_sgr_color                   ; (an underline's color: taken, not kept)
.next:
    inc ebx
    jmp .each
.done:
    mov [rdx + TW_VATTR], r12
    pop r12
    pop rbx
    ret

; vt_sgr_color(EBX = the parameter that is 38, 48 or 58) -> EAX = the
; color it names, -1 if none; EBX = the last parameter it took
vt_sgr_color:
    push rcx
    push rsi
    lea ecx, [rbx + 1]                  ; ECX = the kind: 5 or 2
    cmp ecx, [rdx + TW_VNP]
    jae .none
    bt dword [rdx + TW_VCOLON], ecx
    jc .colon
    mov eax, [rdx + TW_VP + rcx * 4]    ; ;5;n or ;2;r;g;b
    cmp eax, 5
    je .semi_index
    cmp eax, 2
    jne .none_kind
    lea esi, [rcx + 1]
    lea ebx, [rcx + 3]
    jmp .rgb
.semi_index:
    lea ebx, [rcx + 1]
    mov esi, ebx
    jmp .index
.colon:
    mov esi, ecx                        ; :5:n, :2:r:g:b or :2:space:r:g:b
.count:
    inc esi
    cmp esi, [rdx + TW_VNP]
    jae .counted
    bt dword [rdx + TW_VCOLON], esi
    jc .count
.counted:
    lea ebx, [rsi - 1]                  ; all of them taken
    mov eax, [rdx + TW_VP + rcx * 4]
    cmp eax, 5
    je .colon_index
    cmp eax, 2
    jne .none_taken
    mov eax, esi
    sub eax, ecx
    lea esi, [rcx + 1]
    cmp eax, 5
    jb .rgb
    inc esi
    jmp .rgb
.colon_index:
    lea esi, [rcx + 1]
.index:
    call .param
    call vt_color256
    jmp .out
.rgb:
    call .param
    and eax, 0xFF
    shl eax, 16
    mov ecx, eax
    inc esi
    call .param
    and eax, 0xFF
    shl eax, 8
    or ecx, eax
    inc esi
    call .param
    and eax, 0xFF
    or eax, ecx
    jmp .out
.none_kind:
    mov ebx, ecx
.none_taken:
.none:
    mov eax, -1
.out:
    pop rsi
    pop rcx
    ret
.param:                                 ; ESI -> EAX = that parameter, 0 if none
    xor eax, eax
    cmp esi, [rdx + TW_VNP]
    jae .no_param
    mov eax, [rdx + TW_VP + rsi * 4]
.no_param:
    ret

; vt_color256(EAX = an xterm color number) -> EAX = its color. Preserves
; others.
vt_color256:
    and eax, 0xFF
    cmp eax, 16
    jb .base
    cmp eax, 232
    jae .gray
    push rcx
    push rdx
    push rsi
    sub eax, 16                         ; 16 + 36 r + 6 g + b
    lea rsi, [vt_cube]
    xor edx, edx
    mov ecx, 36
    div ecx
    movzx ecx, byte [rsi + rax]
    shl ecx, 16
    mov eax, edx
    xor edx, edx
    push rcx
    mov ecx, 6
    div ecx
    pop rcx
    movzx eax, byte [rsi + rax]
    shl eax, 8
    or ecx, eax
    movzx eax, byte [rsi + rdx]
    or eax, ecx
    pop rsi
    pop rdx
    pop rcx
    ret
.gray:
    sub eax, 232
    imul eax, eax, 10
    add eax, 8
    imul eax, eax, 0x010101
    ret
.base:
    push rcx
    lea rcx, [vt_palette]
    mov eax, [rcx + rax * 4]
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Questions, and their answers
; -----------------------------------------------------------------------------

; vt_reply(RSI = bytes, ECX = how many): an answer, for the program to
; read as if typed. Preserves all.
vt_reply:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, [rdx + TW_VREPLYN]
    lea edi, [rax + rcx]
    cmp edi, VT_REPLY
    ja .out
    mov [rdx + TW_VREPLYN], edi
    lea rdi, [rdx + TW_VREPLY + rax]
    rep movsb
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; vt_reply_buf(RDI = past the end of what vt_buf holds): it, as an answer.
; Preserves all.
vt_reply_buf:
    push rcx
    push rsi
    lea rsi, [vt_buf]
    mov rcx, rdi
    sub rcx, rsi
    call vt_reply
    pop rsi
    pop rcx
    ret

; vt_put_num(EAX, RDI) -> RDI past its digits. Preserves others.
vt_put_num:
    push rax
    push rcx
    push rdx
    push rsi
    xor ecx, ecx
    mov esi, 10
.digit:
    xor edx, edx
    div esi
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .digit
.put:
    pop rax
    stosb
    dec ecx
    jnz .put
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; vt_put_csi(RDI = vt_buf) -> RDI past ESC [. Preserves others.
vt_put_csi:
    mov word [rdi], 0x5B1B
    add rdi, 2
    ret

; vt_put_hex(AL, RDI) -> RDI past it as two hex digits, twice (a color's
; part, as xterm says it: e6 -> e6e6). Preserves others.
vt_put_hex:
    push rax
    push rcx
    mov ecx, 2
.twice:
    push rax
    shr al, 4
    call .digit
    pop rax
    push rax
    and al, 0x0F
    call .digit
    pop rax
    dec ecx
    jnz .twice
    pop rcx
    pop rax
    ret
.digit:
    add al, '0'
    cmp al, '9'
    jbe .stored
    add al, 'a' - '0' - 10
.stored:
    stosb
    ret

vt_dsr:                                 ; CSI 5 n, CSI 6 n
    call vt_p0
    cmp eax, 5
    je .ok
    cmp eax, 6
    jne .out
    lea rdi, [vt_buf]
    call vt_put_csi
.position:
    call vt_row
    test dword [rdx + TW_VFLAGS], VF_ORIGIN
    jz .row
    mov ecx, eax
    call vt_top
    sub ecx, eax
    mov eax, ecx
.row:
    inc eax
    call vt_put_num
    mov al, ';'
    stosb
    call vt_col
    inc eax
    call vt_put_num
    mov al, 'R'
    stosb
    jmp vt_reply_buf
.ok:
    lea rsi, [str_vt_ok]
    mov ecx, str_vt_ok_len
    jmp vt_reply
.out:
    ret

vt_dsr_private:                         ; CSI ? 6 n
    call vt_p0
    cmp eax, 6
    jne vt_dsr.out
    lea rdi, [vt_buf]
    call vt_put_csi
    mov al, '?'
    stosb
    jmp vt_dsr.position

vt_da:                                  ; CSI c: what it is
    call vt_p0
    test eax, eax
    jnz .out
    lea rsi, [str_vt_da1]
    mov ecx, str_vt_da1_len
    jmp vt_reply
.out:
    ret

vt_da2:                                 ; CSI > c
    call vt_p0
    test eax, eax
    jnz vt_da.out
    lea rsi, [str_vt_da2]
    mov ecx, str_vt_da2_len
    jmp vt_reply

vt_xtversion:                           ; CSI > q
    lea rsi, [str_vt_version]
    mov ecx, str_vt_version_len
    jmp vt_reply

vt_rqm_private:                         ; CSI ? n $ p: is that mode set?
    call vt_p0
    mov r8d, eax
    call vt_mode_flag
    lea rdi, [vt_buf]
    call vt_put_csi
    mov al, '?'
    stosb
    jmp vt_rqm_answer

vt_rqm:                                 ; CSI n $ p
    call vt_p0
    mov r8d, eax
    xor ecx, ecx
    cmp eax, 4
    jne .lnm
    mov ecx, VF_INSERT
.lnm:
    cmp eax, 20
    jne .asked
    mov ecx, VF_LNM
.asked:
    lea rdi, [vt_buf]
    call vt_put_csi
vt_rqm_answer:                          ; R8D = the mode, ECX = its flag or 0
    mov eax, r8d
    call vt_put_num
    mov al, ';'
    stosb
    xor eax, eax                        ; 0: not known, 1: set, 2: not set
    test ecx, ecx
    jz .say
    inc eax
    test [rdx + TW_VFLAGS], ecx
    jnz .say
    inc eax
.say:
    call vt_put_num
    mov word [rdi], '$y'
    add rdi, 2
    jmp vt_reply_buf

vt_winops:                              ; CSI n t
    call vt_p0
    cmp eax, 18
    je .cells
    cmp eax, 19
    je .cells
    cmp eax, 14
    je .pixels
    cmp eax, 16
    je .cell
    ret
.cells:                                 ; ESC [ 8 ; rows ; columns t
    lea rdi, [vt_buf]
    call vt_put_csi
    mov eax, 8
    mov esi, [rdx + TW_ROWS_NOW]
    mov ecx, [rdx + TW_COLS_NOW]
    jmp .say
.pixels:                                ; ESC [ 4 ; height ; width t
    lea rdi, [vt_buf]
    call vt_put_csi
    mov esi, [rdx + TW_ROWS_NOW]
    imul esi, [font_ch]
    mov ecx, [rdx + TW_COLS_NOW]
    imul ecx, [font_cw]
    mov eax, 4
    jmp .say
.cell:                                  ; ESC [ 6 ; height ; width t
    lea rdi, [vt_buf]
    call vt_put_csi
    mov esi, [font_ch]
    mov ecx, [font_cw]
    mov eax, 6
.say:
    call vt_put_num
    mov al, ';'
    stosb
    mov eax, esi
    call vt_put_num
    mov al, ';'
    stosb
    mov eax, ecx
    call vt_put_num
    mov al, 't'
    stosb
    jmp vt_reply_buf

; vt_osc_end: an OSC string ended: a title, or a question about colors
vt_osc_end:
    mov dword [rdx + TW_VS], VS_GROUND
    mov ecx, [rdx + TW_VOSCN]
    mov byte [rdx + TW_VOSC + rcx], 0
    lea rsi, [rdx + TW_VOSC]
    xor eax, eax                        ; its number
.number:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .numbered
    imul eax, eax, 10
    add eax, ecx
    inc rsi
    jmp .number
.numbered:
    cmp byte [rsi], ';'
    jne .out
    inc rsi
    test eax, eax
    jz .title
    cmp eax, 2
    je .title
    cmp eax, 4
    je .palette
    cmp eax, 10
    je .fg
    cmp eax, 11
    je .bg
    cmp eax, 12
    je .cursor
.out:
    ret
.title:
    lea rdi, [rdx + TW_VTITLE]
    mov r8d, WN_TITLE_MAX - 1
.char:
    test r8d, r8d
    jz .titled
    movzx eax, byte [rsi]
    test eax, eax
    jz .titled
    inc rsi
    cmp eax, 0x80
    jb .plain
    call vt_utf8
    call vt_glyph
.plain:
    cmp eax, 0x20
    jb .char
    stosb
    dec r8d
    jmp .char
.titled:
    mov byte [rdi], 0
    mov byte [rdx + TW_VTITLED], 1
    ret
.palette:                               ; 4 ; n ; ?
    xor eax, eax
.index:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .indexed
    imul eax, eax, 10
    add eax, ecx
    inc rsi
    jmp .index
.indexed:
    cmp word [rsi], ';?'
    jne .out
    mov r8d, eax
    call vt_color256
    mov ecx, eax
    mov eax, 4
    jmp vt_color_reply
.fg:
    mov ecx, [look_text]
    jmp .asked
.bg:
    mov ecx, [look_panel]
    jmp .asked
.cursor:
    mov ecx, [look_accent]
.asked:
    cmp byte [rsi], '?'
    jne .out
    mov r8d, -1
    jmp vt_color_reply

; vt_color_reply(EAX = the OSC's number, ECX = a color, R8D = the palette
; entry, or -1): ESC ] n ; [entry ;] rgb:rrrr/gggg/bbbb ST
vt_color_reply:
    lea rdi, [vt_buf]
    mov word [rdi], 0x5D1B
    add rdi, 2
    call vt_put_num
    mov al, ';'
    stosb
    test r8d, r8d
    js .no_entry
    mov eax, r8d
    call vt_put_num
    mov al, ';'
    stosb
.no_entry:
    mov dword [rdi], 'rgb:'
    add rdi, 4
    mov eax, ecx
    shr eax, 16
    call vt_put_hex
    mov al, '/'
    stosb
    mov eax, ecx
    shr eax, 8
    call vt_put_hex
    mov al, '/'
    stosb
    mov eax, ecx
    call vt_put_hex
    mov word [rdi], 0x5C1B
    add rdi, 2
    jmp vt_reply_buf

; -----------------------------------------------------------------------------
;  Characters
; -----------------------------------------------------------------------------

; vt_utf8(EAX = a byte from 0x80, RSI = the bytes after it) -> EAX = the
; code point, RSI past it (U+FFFD if it is not UTF-8). Preserves others.
vt_utf8:
    push rcx
    cmp eax, 0xC0
    jb .bad
    cmp eax, 0xE0
    jae .three
    and eax, 0x1F
    mov ecx, 1
    jmp .more
.three:
    cmp eax, 0xF0
    jae .four
    and eax, 0x0F
    mov ecx, 2
    jmp .more
.four:
    cmp eax, 0xF8
    jae .bad
    and eax, 0x07
    mov ecx, 3
.more:
    push rbx
.next:
    movzx ebx, byte [rsi]
    sub ebx, 0x80
    cmp ebx, 0x3F
    ja .short
    inc rsi
    shl eax, 6
    or eax, ebx
    dec ecx
    jnz .next
    pop rbx
    pop rcx
    ret
.short:
    pop rbx
.bad:
    mov eax, 0xFFFD
    pop rcx
    ret

; vt_width(EAX = a code point) -> ECX = the cells it takes: 0, 1 or 2.
; Preserves others.
vt_width:
    mov ecx, 1
    cmp eax, 0x300
    jb .out
    push rsi
    xor ecx, ecx
    lea rsi, [vt_zero_ranges]
    call .within
    jc .done
    mov ecx, 2
    lea rsi, [vt_wide_ranges]
    call .within
    jc .done
    mov ecx, 1
.done:
    pop rsi
.out:
    ret
.within:                                ; RSI = ranges -> CF if EAX is in one
    cmp dword [rsi], 0
    je .no
    cmp eax, [rsi]
    jb .after
    cmp eax, [rsi + 4]
    jbe .yes
.after:
    add rsi, 8
    jmp .within
.yes:
    stc
    ret
.no:
    clc
    ret

; vt_glyph(EAX = a code point) -> EAX = its glyph code, '?' if the font
; has none. Preserves others.
vt_glyph:
    cmp eax, 0x20
    jb .unknown
    cmp eax, 0x7F
    jb .out
    push rcx
    push rsi
    push rdi
    push r8
    lea r8, [font_unicode]
    xor ecx, ecx                        ; a binary search: from,
    mov edi, FONT_UNICODE               ; to (not included)
.search:
    cmp ecx, edi
    jae .none
    lea esi, [rcx + rdi]
    shr esi, 1
    cmp eax, [r8 + rsi * 8]
    je .found
    jb .lower
    lea ecx, [rsi + 1]
    jmp .search
.lower:
    mov edi, esi
    jmp .search
.found:
    mov eax, [r8 + rsi * 8 + 4]
    jmp .done
.none:
    mov eax, '?'
.done:
    pop r8
    pop rdi
    pop rsi
    pop rcx
.out:
    ret
.unknown:
    mov eax, '?'
    ret

; vt_glyph_utf8(AL = a glyph code, RDI = where) -> RDI past the character
; in UTF-8. Preserves others.
vt_glyph_utf8:
    push rax
    push rcx
    movzx eax, al
    cmp eax, FONT_EXTRA_BASE
    jb .ascii
    sub eax, FONT_EXTRA_BASE
    cmp eax, FONT_EXTRAS
    jae .unknown
    lea rcx, [font_extra_cp]
    mov eax, [rcx + rax * 4]
    cmp eax, 0x800
    jae .three
    mov ecx, eax
    shr ecx, 6
    or cl, 0xC0
    mov [rdi], cl
    and al, 0x3F
    or al, 0x80
    mov [rdi + 1], al
    add rdi, 2
    jmp .out
.three:
    cmp eax, 0x10000
    jae .unknown
    mov ecx, eax
    shr ecx, 12
    or cl, 0xE0
    mov [rdi], cl
    mov ecx, eax
    shr ecx, 6
    and cl, 0x3F
    or cl, 0x80
    mov [rdi + 1], cl
    and al, 0x3F
    or al, 0x80
    mov [rdi + 2], al
    add rdi, 3
    jmp .out
.unknown:
    mov al, '?'
.ascii:
    stosb
.out:
    pop rcx
    pop rax
    ret

section .rodata
align 8
; CSI's final bytes, 0x40 to 0x7E, with no private marker or intermediate
vt_csi_table:
    dq vt_ich, vt_cuu, vt_cud, vt_cuf, vt_cub, vt_cnl, vt_cpl, vt_cha   ; @ A-G
    dq vt_cup, vt_cht, vt_ed, vt_el, vt_il, vt_dl, 0, 0                 ; H-O
    dq vt_dch, 0, 0, vt_su, vt_sd, 0, 0, 0                              ; P-W
    dq vt_ech, 0, vt_cbt, 0, 0, 0, 0, 0                                 ; X-_
    dq vt_cha, vt_hpr, vt_rep, vt_da, vt_vpa, vt_vpr, vt_cup, 0         ; ` a-g
    dq vt_sm, 0, 0, 0, vt_rm, vt_sgr, vt_dsr, 0                         ; h-o
    dq 0, 0, vt_stbm, vt_scosc, vt_winops, vt_scorc, 0, 0               ; p-w
    dq 0, 0, 0, 0, 0, 0, 0                                              ; x-~
; private modes and their flags (DECSET, DECRQM)
vt_modes:
    dd 1, VF_APPCURSOR
    dd 6, VF_ORIGIN
    dd 7, VF_WRAP
    dd 12, VF_BLINK
    dd 25, VF_CURSOR
    dd 47, VF_ALT
    dd 1000, VF_MOUSE
    dd 1002, VF_MOUSE_DRAG
    dd 1003, VF_MOUSE_ANY
    dd 1004, VF_FOCUS
    dd 1006, VF_MOUSE_SGR
    dd 1047, VF_ALT
    dd 1049, VF_ALT
    dd 2004, VF_PASTE
    dd 2026, VF_SYNC
    dd 0, 0
; the 16 colors (VS Code's terminal's)
vt_palette:
    dd 0x000000, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5
    dd 0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF
vt_cube:        db 0, 95, 135, 175, 215, 255
align 2
; DEC's line drawing set, 0x5F to 0x7E, as code points
vt_dec_graphics:
    dw 0x0020, 0x25C6, 0x2592, 0x2409, 0x240C, 0x240D, 0x240A, 0x00B0  ; _ ` a-f
    dw 0x00B1, 0x2424, 0x240B, 0x2518, 0x2510, 0x250C, 0x2514, 0x253C  ; g-n
    dw 0x2594, 0x2500, 0x2500, 0x2500, 0x2581, 0x251C, 0x2524, 0x2534  ; o-v
    dw 0x252C, 0x2502, 0x2264, 0x2265, 0x03C0, 0x2260, 0x00A3, 0x00B7  ; w-~
align 4
; characters that take no cell (they combine), and those that take two
vt_zero_ranges:
    dd 0x0300, 0x036F, 0x0483, 0x0489, 0x0591, 0x05BD, 0x0610, 0x061A
    dd 0x064B, 0x065F, 0x1AB0, 0x1AFF, 0x1DC0, 0x1DFF, 0x200B, 0x200F
    dd 0x202A, 0x202E, 0x2060, 0x2064, 0x20D0, 0x20FF, 0xFE00, 0xFE0F
    dd 0xFE20, 0xFE2F, 0xFEFF, 0xFEFF, 0x1F3FB, 0x1F3FF, 0xE0000, 0xE0FFF
    dd 0, 0
vt_wide_ranges:
    dd 0x1100, 0x115F, 0x231A, 0x231B, 0x2329, 0x232A, 0x23E9, 0x23EC
    dd 0x23F0, 0x23F0, 0x23F3, 0x23F3, 0x25FD, 0x25FE, 0x2614, 0x2615
    dd 0x2648, 0x2653, 0x267F, 0x267F, 0x2693, 0x2693, 0x26A1, 0x26A1
    dd 0x26AA, 0x26AB, 0x26BD, 0x26BE, 0x26C4, 0x26C5, 0x26CE, 0x26CE
    dd 0x26D4, 0x26D4, 0x26EA, 0x26EA, 0x26F2, 0x26F3, 0x26F5, 0x26F5
    dd 0x26FA, 0x26FA, 0x26FD, 0x26FD, 0x2705, 0x2705, 0x270A, 0x270B
    dd 0x2728, 0x2728, 0x274C, 0x274C, 0x274E, 0x274E, 0x2753, 0x2755
    dd 0x2757, 0x2757, 0x2795, 0x2797, 0x27B0, 0x27B0, 0x27BF, 0x27BF
    dd 0x2B1B, 0x2B1C, 0x2B50, 0x2B50, 0x2B55, 0x2B55, 0x2E80, 0x303E
    dd 0x3041, 0x33FF, 0x3400, 0x4DBF, 0x4E00, 0x9FFF, 0xA000, 0xA4CF
    dd 0xA960, 0xA97F, 0xAC00, 0xD7A3, 0xF900, 0xFAFF, 0xFE10, 0xFE19
    dd 0xFE30, 0xFE6F, 0xFF00, 0xFF60, 0xFFE0, 0xFFE6, 0x16FE0, 0x18AFF
    dd 0x1B000, 0x1B2FF, 0x1F004, 0x1F004, 0x1F0CF, 0x1F0CF, 0x1F18E, 0x1F18E
    dd 0x1F191, 0x1F19A, 0x1F200, 0x1F251, 0x1F300, 0x1F320, 0x1F32D, 0x1F335
    dd 0x1F337, 0x1F37C, 0x1F37E, 0x1F393, 0x1F3A0, 0x1F3CA, 0x1F3CF, 0x1F3D3
    dd 0x1F3E0, 0x1F3F0, 0x1F3F4, 0x1F3F4, 0x1F3F8, 0x1F43E, 0x1F440, 0x1F440
    dd 0x1F442, 0x1F4FC, 0x1F4FF, 0x1F53D, 0x1F54B, 0x1F54E, 0x1F550, 0x1F567
    dd 0x1F57A, 0x1F57A, 0x1F595, 0x1F596, 0x1F5A4, 0x1F5A4, 0x1F5FB, 0x1F64F
    dd 0x1F680, 0x1F6C5, 0x1F6CC, 0x1F6CC, 0x1F6D0, 0x1F6D2, 0x1F6D5, 0x1F6D7
    dd 0x1F6EB, 0x1F6EC, 0x1F6F4, 0x1F6FC, 0x1F7E0, 0x1F7EB, 0x1F90C, 0x1F93A
    dd 0x1F93C, 0x1F945, 0x1F947, 0x1F9FF, 0x1FA70, 0x1FAFF, 0x20000, 0x2FFFD
    dd 0x30000, 0x3FFFD
    dd 0, 0
str_vt_ok:      db 27, '[0n'
str_vt_ok_len   equ $ - str_vt_ok
str_vt_da1:     db 27, '[?62;22c'
str_vt_da1_len  equ $ - str_vt_da1
str_vt_da2:     db 27, '[>0;10;1c'
str_vt_da2_len  equ $ - str_vt_da2
str_vt_version: db 27, 'P>|Axiom', 27, '\'
str_vt_version_len equ $ - str_vt_version

section .bss
vt_buf:         resb 96                 ; an answer being made (print_lock held)
