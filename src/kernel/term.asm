; =============================================================================
;  term.asm - terminals: a window of text with a shell of its own.
;
;  A terminal (TW_*) keeps the last TW_LINES lines it was given, TW_COLS
;  cells each (a cell is a character and its color), wrapped at the width
;  its window has when they are written; the wheel scrolls back through
;  them. Text reaches a terminal through the con_* calls (kprint, kputs and
;  the shell use them), which write to the terminal of the thread printing
;  (TH_CON), else to the first terminal there is: what a command prints
;  later (a ping's replies, a fetch, a program's lines) goes where it was
;  started, because whatever does it later sets TH_CON as it was then
;  (con_call). Writing only changes cells, from any CPU, under print_lock;
;  term_service, on the main thread, draws what changed into the window.
; =============================================================================

TW_LINES        equ 1000                ; lines kept
TW_COLS         equ 256                 ; cells a line has

TW_WIN          equ 0                   ; its window
TW_CELLS        equ 8                   ; TW_LINES x TW_COLS dwords: character | color << 8
TW_COLS_NOW     equ 16                  ; columns the window has room for
TW_ROWS_NOW     equ 24                  ; rows
TW_CX           equ 32                  ; the cursor: column,
TW_LINE         equ 40                  ; and line (counting up from 0, forever)
TW_BACK         equ 48                  ; lines scrolled back (0: at the bottom)
TW_FG           equ 56                  ; dword: color of what is written
TW_ID           equ 60                  ; dword: its number
TW_DIRTY_LO     equ 64                  ; lines changed since drawn: from,
TW_DIRTY_HI     equ 72                  ; to (not included)
TW_SHOWN        equ 80                  ; the first line in the window now, -1 if none
TW_NEXT         equ 88                  ; every terminal
TW_TOP          equ 96                  ; the first line of the view at the bottom (clear)
TW_SH_LEN       equ 104                 ; dword: the line being typed: its length
TW_SH_WAIT      equ 108                 ; byte: a command runs on; the prompt waits
TW_SH_LINE      equ 112                 ; LINE_MAX + 8
TW_SH_HIST      equ TW_SH_LINE + LINE_MAX + 8
TW_SIZE         equ TW_SH_HIST + LINE_MAX + 8

TH_CON          equ 304                 ; a thread's terminal to print to (0: the first)

section .text

; -----------------------------------------------------------------------------
;  Terminals
; -----------------------------------------------------------------------------

; term_open(RDI x, RSI y, RDX w, RCX h of the window; x = -1: placed for it)
; -> RAX = the terminal, 0 if there is no memory or room. It takes the keys.
term_open:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov edi, TW_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov rbx, rax
    mov edi, TW_LINES * TW_COLS * 4
    call vm_alloc
    test rax, rax
    jz .no_cells
    mov [rbx + TW_CELLS], rax
    mov dword [rbx + TW_FG], COL_TEXT
    mov qword [rbx + TW_SHOWN], -1
    inc dword [term_count]
    mov eax, [term_count]
    mov [rbx + TW_ID], eax
    lea rdi, [ui_buf]
    SPRINTF rdi, "shell %u", rax
    pushfq                              ; one of every terminal, from now on
    cli
    lea rdi, [print_lock]
    call spin_lock
    mov rax, [term_list]
    mov [rbx + TW_NEXT], rax
    mov [term_list], rbx
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    lea rdi, [term_ops]
    lea rsi, [ui_buf]
    mov rdx, r14
    mov rcx, r15
    mov r8, r12
    mov r9, r13
    mov r10d, WF_CLOSE | WF_RESIZE
    mov [term_making], rbx              ; for its first paint
    call win_new
    mov qword [term_making], 0
    test rax, rax
    jz .no_window
    mov [rbx + TW_WIN], rax
    mov [rax + WN_DATA], rbx
    mov byte [term_dirty], 1            ; its first drawing
    mov rdi, rax
    call win_focus
    mov rax, rbx
    jmp .out
.no_window:
    mov rdi, rbx                        ; (its window's handlers never ran)
    call term_unlist
    mov rdi, [rbx + TW_CELLS]
    call vm_free
.no_cells:
    mov rdi, rbx
    call kfree
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; term_new: a terminal of its own, with a prompt (the bar's button, 'shell')
term_new:
    push rbx
    mov rdi, -1
    mov rdx, [font_cw]
    imul rdx, rdx, 84
    mov rcx, [font_ch]
    imul rcx, rcx, 24
    call term_open
    test rax, rax
    jz .none
    mov rbx, rax
    mov eax, [rbx + TW_ID]
    KLOG "desk: shell %u opens", rax
    mov rdi, rbx
    lea rax, [shell_prompt]
    mov r11, rbx
    call con_call
    jmp .out
.none:
    KLOG "desk: no room for another shell"
.out:
    pop rbx
    ret

; term_unlist(RDI = terminal): out of the list; nothing prints to it after
term_unlist:
    push rax
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [print_lock]
    call spin_lock
    pop rdi
    lea rax, [term_list]
.find:
    cmp [rax], rdi
    je .found
    mov rax, [rax]
    test rax, rax
    jz .gone
    add rax, TW_NEXT
    jmp .find
.found:
    push rcx
    mov rcx, [rdi + TW_NEXT]
    mov [rax], rcx
    pop rcx
.gone:
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rax
    ret

; The window's handlers: RBX = the window
term_paint:
    mov rdi, [rbx + WN_DATA]
    test rdi, rdi
    jnz .have
    mov rdi, [term_making]              ; still being made
    test rdi, rdi
    jz .out
.have:
    push r12
    mov r12, rdi
    call term_measure
    mov qword [r12 + TW_SHOWN], -1      ; all of it, again
    mov rdi, r12
    call term_draw
    pop r12
.out:
    ret

term_key:
    mov rcx, [rbx + WN_DATA]
    cmp qword [rcx + TW_BACK], 0        ; a key brings the view back down
    je .bottom
    mov qword [rcx + TW_BACK], 0
    mov qword [rcx + TW_SHOWN], -1
    mov byte [term_dirty], 1
.bottom:
    mov edi, eax
    mov r11, rcx
    lea rax, [shell_key]
    jmp con_call

term_wheel:
    mov rdi, [rbx + WN_DATA]
    imul edx, edx, 3                    ; three lines a notch
    movsxd rdx, edx
    add rdx, [rdi + TW_BACK]
    jns .floor
    xor edx, edx
.floor:
    mov rax, [rdi + TW_LINE]            ; no further back than the oldest
    inc rax
    cmp rax, TW_LINES
    jbe .kept
    mov eax, TW_LINES
.kept:
    sub rax, [rdi + TW_ROWS_NOW]
    jns .most
    xor eax, eax
.most:
    cmp rdx, rax
    jbe .set
    mov rdx, rax
.set:
    cmp rdx, [rdi + TW_BACK]
    je .out
    mov [rdi + TW_BACK], rdx
    mov qword [rdi + TW_SHOWN], -1
    mov byte [term_dirty], 1
.out:
    ret

term_close:
    push r12
    mov r12, [rbx + WN_DATA]
    mov rdi, r12                        ; what it started stops
    call con_forget
    mov rdi, r12                        ; and nothing prints to it again
    call term_unlist
    cmp r12, [con_first]
    jne .free
    mov qword [con_first], 0
.free:
    mov eax, [r12 + TW_ID]
    KLOG "desk: shell %u closes", rax
    mov rdi, [r12 + TW_CELLS]
    call vm_free
    mov rdi, r12
    call kfree
    mov qword [rbx + WN_DATA], 0
    pop r12
    ret

; term_measure(R12 = terminal, RBX = its window): rows and columns from
; the window's size
term_measure:
    mov rdi, rbx
    mov rax, [font_ch]
    shr rax, 2
    mov [term_pad_y], rax
    mov rax, [rdi + WN_W]
    sub rax, [font_cw]                  ; half a cell each side
    xor edx, edx
    div qword [font_cw]
    test rax, rax
    jnz .cols
    inc eax
.cols:
    cmp rax, TW_COLS
    jbe .cols_ok
    mov eax, TW_COLS
.cols_ok:
    mov [r12 + TW_COLS_NOW], rax
    mov rax, [rdi + WN_H]
    mov rcx, [font_ch]
    shr rcx, 1
    sub rax, rcx                        ; a quarter row top and bottom
    xor edx, edx
    div qword [font_ch]
    test rax, rax
    jnz .rows
    inc eax
.rows:
    mov [r12 + TW_ROWS_NOW], rax
    ret

; -----------------------------------------------------------------------------
;  Drawing (the main thread)
; -----------------------------------------------------------------------------

; term_service: what changed in every terminal, into its window
term_service:
    cmp byte [term_dirty], 0
    jne .work
    ret
.work:
    push rbx
    mov byte [term_dirty], 0
    mov rbx, [term_list]
.each:
    test rbx, rbx
    jz .done
    cmp qword [rbx + TW_WIN], 0
    je .next
    mov rdi, rbx
    call term_draw
.next:
    mov rbx, [rbx + TW_NEXT]
    jmp .each
.done:
    pop rbx
    ret

; term_draw(RDI = terminal): the lines that changed, or all of them
term_draw:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov rbx, [r12 + TW_WIN]
    test rbx, rbx                       ; (its window is not linked yet)
    jz .out
    pushfq                              ; what to draw: under print_lock
    cli
    lea rdi, [print_lock]
    call spin_lock
    mov r13, [r12 + TW_DIRTY_LO]
    mov r14, [r12 + TW_DIRTY_HI]
    mov qword [r12 + TW_DIRTY_LO], -1
    mov qword [r12 + TW_DIRTY_HI], 0
    call term_first                     ; RAX = the first line to show
    mov r15, rax
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    lea rdi, [rbx + WN_SF]
    call gfx_target
    mov rax, [r12 + TW_SHOWN]
    cmp rax, -1
    je .all
    cmp rax, r15
    je .lines
    jg .all                             ; back up the scroll: all again
    mov rcx, r15                        ; down by fewer than a screen: move
    sub rcx, rax                        ; the pixels up, draw the new lines
    cmp rcx, [r12 + TW_ROWS_NOW]
    jae .all
    call term_scroll
    mov rax, [r12 + TW_SHOWN]           ; the lines that came into view
    add rax, [r12 + TW_ROWS_NOW]
    cmp r13, rax
    jbe .new_lo
    mov r13, rax
.new_lo:
    mov rax, r15
    add rax, [r12 + TW_ROWS_NOW]
    cmp r14, rax
    jae .new_hi
    mov r14, rax
.new_hi:
    mov [r12 + TW_SHOWN], r15
    call term_lines
    mov rdi, rbx
    call win_damage_all
    jmp .out
.all:
    xor esi, esi                        ; the background, then every line
    xor edi, edi
    mov rdx, [rbx + WN_W]
    mov rcx, [rbx + WN_H]
    mov r8d, COL_PANEL
    call gfx_fill
    mov [r12 + TW_SHOWN], r15
    mov r13, r15
    mov r14, r15
    add r14, [r12 + TW_ROWS_NOW]
    call term_lines
    mov rdi, rbx
    call win_damage_all
    jmp .out
.lines:
    cmp r13, r14
    jae .out
    call term_lines                     ; and only those rows on the screen
    mov rax, r13
    cmp rax, r15
    jge .from
    mov rax, r15
.from:
    mov rcx, r14
    mov rdx, r15
    add rdx, [r12 + TW_ROWS_NOW]
    cmp rcx, rdx
    jle .to
    mov rcx, rdx
.to:
    sub rcx, rax
    jle .out
    sub rax, r15
    imul rax, [font_ch]
    add rax, [term_pad_y]
    mov rdx, rax                        ; y
    imul rcx, [font_ch]
    mov r8, rcx                         ; h
    mov rdi, rbx
    xor esi, esi
    mov rcx, [rbx + WN_W]
    call win_damage
.out:
    call gfx_target_back
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; term_first(R12) -> RAX = the first line the window shows. Preserves others.
term_first:
    push rcx
    mov rax, [r12 + TW_LINE]
    mov rcx, [r12 + TW_ROWS_NOW]
    dec rcx
    sub rax, rcx                        ; the cursor's line at the bottom,
    cmp rax, [r12 + TW_TOP]             ; or the top after a clear
    jge .back
    mov rax, [r12 + TW_TOP]
.back:
    sub rax, [r12 + TW_BACK]
    jns .out
    xor eax, eax
.out:
    pop rcx
    ret

; term_scroll(R12, RBX = window, RCX = rows): the text in the surface up
; by that many rows (the target is the surface)
term_scroll:
    push rsi
    push rdi
    push rcx
    mov rax, [r12 + TW_ROWS_NOW]
    sub rax, rcx                        ; rows that stay
    imul rax, [font_ch]
    imul rax, [rbx + WN_SF + SF_PITCH]  ; bytes
    mov rdi, [term_pad_y]
    imul rdi, [rbx + WN_SF + SF_PITCH]
    add rdi, [rbx + WN_SF + SF_PTR]
    imul rcx, [font_ch]
    imul rcx, [rbx + WN_SF + SF_PITCH]
    lea rsi, [rdi + rcx]
    mov rcx, rax
    rep movsb
    pop rcx
    pop rdi
    pop rsi
    ret

; term_lines(R12, RBX = window, R13..R14 = lines, R15 = the first shown):
; those of them in view, drawn (the target is the surface)
term_lines:
    push r13
    cmp r13, r15
    jge .line
    mov r13, r15
.line:
    cmp r13, r14
    jge .done
    mov rax, r15
    add rax, [r12 + TW_ROWS_NOW]
    cmp r13, rax
    jge .done
    call term_line
    inc r13
    jmp .line
.done:
    pop r13
    ret

; term_line(R12, RBX, R13 = line, R15): one row
term_line:
    push r14
    push r15
    mov rax, r13                        ; its y
    sub rax, r15
    imul rax, [font_ch]
    add rax, [term_pad_y]
    mov r15, rax
    mov rdi, [font_cw]                  ; the row's background
    shr rdi, 1
    mov rsi, r15
    mov rdx, [rbx + WN_W]
    mov rcx, [font_ch]
    mov r8d, COL_PANEL
    call gfx_fill
    cmp r13, [r12 + TW_LINE]            ; written yet?
    jg .out
    mov rax, [r12 + TW_LINE]            ; still kept?
    sub rax, r13
    cmp rax, TW_LINES
    jae .out
    mov rax, r13
    xor edx, edx
    mov ecx, TW_LINES
    div rcx
    imul rdx, rdx, TW_COLS * 4
    add rdx, [r12 + TW_CELLS]
    mov r14, rdx                        ; its cells
    xor ecx, ecx
.cell:
    cmp rcx, [r12 + TW_COLS_NOW]
    jae .cursor
    mov eax, [r14 + rcx * 4]
    test al, al
    jz .next
    cmp al, ' '
    je .next
    push rcx
    push rax
    mov edi, eax
    shr edi, 8
    mov esi, COL_PANEL
    call gfx_color
    pop rdx
    mov rdi, [rsp]
    imul rdi, [font_cw]
    mov rax, [font_cw]
    shr rax, 1
    add rdi, rax
    mov rsi, r15
    movzx edx, dl
    call gfx_glyph
    pop rcx
.next:
    inc rcx
    jmp .cell
.cursor:
    cmp r13, [r12 + TW_LINE]            ; the cursor: a bar under its cell
    jne .out
    cmp qword [r12 + TW_BACK], 0
    jne .out
    mov rdi, [r12 + TW_CX]
    cmp rdi, [r12 + TW_COLS_NOW]
    jb .in_row
    mov rdi, [r12 + TW_COLS_NOW]
    dec rdi
.in_row:
    imul rdi, [font_cw]
    mov rax, [font_cw]
    shr rax, 1
    add rdi, rax
    mov rsi, r15
    add rsi, [font_ch]
    mov rcx, [ui_line]
    add rcx, rcx
    sub rsi, rcx
    mov rdx, [font_cw]
    mov r8d, COL_ACCENT
    call gfx_fill
.out:
    pop r15
    pop r14
    ret

; -----------------------------------------------------------------------------
;  Writing: the con_* calls. Any CPU.
; -----------------------------------------------------------------------------

; con_target -> RAX = the terminal this thread prints to, 0 if there is
; none. Preserves others.
con_target:
    mov rax, [gs:PC_CURRENT]
    test rax, rax
    jz .first
    mov rax, [rax + TH_CON]
    test rax, rax
    jz .first
    push rcx                            ; still a terminal? (one closed
    mov rcx, [term_list]                ; while something printed there)
.known:
    test rcx, rcx
    jz .unknown
    cmp rcx, rax
    je .found
    mov rcx, [rcx + TW_NEXT]
    jmp .known
.found:
    pop rcx
    ret
.unknown:
    pop rcx
.first:
    mov rax, [con_first]
    test rax, rax
    jnz .out
    mov rax, [term_list]                ; the first is gone: the oldest left
    test rax, rax
    jz .out
.oldest:
    cmp qword [rax + TW_NEXT], 0
    je .chosen
    mov rax, [rax + TW_NEXT]
    jmp .oldest
.chosen:
    mov [con_first], rax
.out:
    ret

; con_owner -> RAX = the terminal this thread prints to as it says, 0 for
; the first (what to keep for printing later). Preserves others.
con_owner:
    mov rax, [gs:PC_CURRENT]
    test rax, rax
    jz .out
    mov rax, [rax + TH_CON]
.out:
    ret

; con_call(RAX = function, R11 = terminal or 0): call it printing to that
; terminal. Every register reaches it as it was but RAX and R11; what it
; returns comes back (RAX, flags); R11 is lost.
con_call:
    push rax                            ; the function
    mov rax, [gs:PC_CURRENT]
    test rax, rax
    jz .plain
    push rax                            ; the thread,
    push qword [rax + TH_CON]           ; and where it printed
    mov [rax + TH_CON], r11
    mov rax, [rsp + 16]
    call rax
    pop r11                             ; (no flags change from here on)
    push rax
    mov rax, [rsp + 8]
    mov [rax + TH_CON], r11
    pop rax
    lea rsp, [rsp + 16]
    ret
.plain:
    pop rax                             ; (before the scheduler: no threads)
    jmp rax

; con_forget(RDI = terminal): whatever it started (a lookup, a fetch, a
; ping, a program) stops; what they say as they stop goes to it
con_forget:
    mov r11, rdi
    lea rax, [.stop]
    jmp con_call
.stop:
    push rdi
    call net_forget
    pop rdi
    jmp user_forget

; con_write(RDI = string). Under print_lock. Preserves all.
con_write:
    push rax
    push rdx
    push rdi
    call con_target
    test rax, rax
    jz .out
    mov rdx, rax
.next:
    mov al, [rdi]
    test al, al
    jz .out
    call tm_putc
    inc rdi
    jmp .next
.out:
    pop rdi
    pop rdx
    pop rax
    ret

; con_putc(AL): one character. Takes print_lock. Preserves all.
con_putc:
    push rdx
    push rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    push rax
    call con_target
    mov rdx, rax
    pop rax
    test rdx, rdx
    jz .none
    call tm_putc
.none:
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rdx
    ret

; con_flush: on the main thread, with interrupts on, what was printed is
; drawn now rather than when the main loop comes round again, at most every
; 30 ms (a long command shows its lines as it goes). Preserves all.
con_flush:
    cmp byte [desk_ready], 0
    je .out
    cmp byte [con_flushing], 0
    jne .out
    push rax
    pushfq
    pop rax
    test eax, 0x200                     ; (while booting, interrupts are off
    jnz .on                             ; and nothing else holds a lock)
    cmp byte [ints_on], 0
    jne .no
.on:
    mov rax, [gs:PC_CURRENT]
    cmp rax, [main_thread]
    jne .no
    push rdx
    RDTSC64
    pop rdx
    cmp rax, [con_flush_at]
    jb .no
    push rcx
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 30
    add rax, rcx
    mov [con_flush_at], rax
    pop rcx
    mov byte [con_flushing], 1
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call gfx_save
    call term_service
    call desk_update
    call gfx_restore
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    mov byte [con_flushing], 0
.no:
    pop rax
.out:
    ret

; con_clear: the terminal empty, the cursor at its top. Preserves all.
con_clear:
    push rax
    push rcx
    push rdx
    push rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    call con_target
    test rax, rax
    jz .none
    mov rdx, rax
    cmp qword [rdx + TW_CX], 0          ; on a line of its own, at the top
    je .fresh
    call tm_newline
.fresh:
    mov rax, [rdx + TW_LINE]
    mov [rdx + TW_TOP], rax
    mov qword [rdx + TW_SHOWN], -1
    mov qword [rdx + TW_BACK], 0
    mov byte [term_dirty], 1
.none:
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; con_set_color(EDI = color) for what this thread writes next. Preserves all.
con_set_color:
    push rax
    call con_target
    test rax, rax
    jz .out
    mov [rax + TW_FG], edi
.out:
    pop rax
    ret

; con_metrics: con_cols and con_cx, the columns and the cursor's column of
; the terminal this thread prints to. Preserves all.
con_metrics:
    push rax
    push rcx
    call con_target
    test rax, rax
    jz .none
    mov rcx, [rax + TW_COLS_NOW]
    mov [con_cols], rcx
    mov rcx, [rax + TW_CX]
    mov [con_cx], rcx
    jmp .out
.none:
    mov qword [con_cols], 80
    mov qword [con_cx], 0
.out:
    pop rcx
    pop rax
    ret

; tm_putc(AL, RDX = terminal). Under print_lock. Preserves all.
tm_putc:
    push rax
    push rcx
    push rdi
    mov byte [term_dirty], 1
    cmp al, 10
    je .newline
    cmp al, 13
    je .carriage
    cmp al, 8
    je .backspace
    cmp al, 9
    je .tab
    mov rcx, [rdx + TW_CX]
    cmp rcx, [rdx + TW_COLS_NOW]
    jb .put
    call tm_newline
.put:
    call tm_cell
    movzx ecx, al
    mov eax, [rdx + TW_FG]
    shl eax, 8
    or eax, ecx
    mov [rdi], eax
    inc qword [rdx + TW_CX]
    call tm_mark
    jmp .out
.newline:
    call tm_newline
    jmp .out
.carriage:
    mov qword [rdx + TW_CX], 0
    call tm_mark
    jmp .out
.backspace:
    cmp qword [rdx + TW_CX], 0
    jne .back
    cmp qword [rdx + TW_LINE], 0        ; to the end of the row above, where
    je .out                             ; a long line wrapped
    call tm_mark
    dec qword [rdx + TW_LINE]
    mov rcx, [rdx + TW_COLS_NOW]
    mov [rdx + TW_CX], rcx
.back:
    dec qword [rdx + TW_CX]
    call tm_cell
    mov dword [rdi], 0
    call tm_mark
    jmp .out
.tab:
    mov al, ' '
    call tm_putc
    test qword [rdx + TW_CX], 3
    jz .out
    mov rcx, [rdx + TW_CX]
    cmp rcx, [rdx + TW_COLS_NOW]
    jb .tab
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; tm_cell(RDX) -> RDI = the cell at the cursor. Preserves others.
tm_cell:
    push rax
    push rdx
    mov rdi, rdx
    mov rax, [rdi + TW_LINE]
    xor edx, edx
    push rcx
    mov ecx, TW_LINES
    div rcx
    pop rcx
    imul rdx, rdx, TW_COLS * 4
    add rdx, [rdi + TW_CELLS]
    mov rax, [rdi + TW_CX]
    lea rdi, [rdx + rax * 4]
    pop rdx
    pop rax
    ret

; tm_newline(RDX): the cursor to the start of a new, empty line. Preserves all.
tm_newline:
    push rax
    push rcx
    push rdi
    call tm_mark                        ; (the cursor leaves this row)
    inc qword [rdx + TW_LINE]
    mov qword [rdx + TW_CX], 0
    call tm_cell
    xor eax, eax
    mov ecx, TW_COLS
    rep stosd
    call tm_mark
    cmp qword [rdx + TW_BACK], 0        ; scrolled back: the view stays put
    je .out
    inc qword [rdx + TW_BACK]
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; tm_mark(RDX): the cursor's line changed. Preserves all.
tm_mark:
    push rax
    mov rax, [rdx + TW_LINE]
    cmp rax, [rdx + TW_DIRTY_LO]
    jae .lo
    mov [rdx + TW_DIRTY_LO], rax
.lo:
    inc rax
    cmp rax, [rdx + TW_DIRTY_HI]
    jbe .hi
    mov [rdx + TW_DIRTY_HI], rax
.hi:
    pop rax
    ret

; -----------------------------------------------------------------------------
;  shell: a terminal of its own
; -----------------------------------------------------------------------------
cmd_shell:
    jmp term_new

section .rodata
align 8
term_ops:       dq term_paint, term_key, 0, term_wheel, term_close, 0

section .data
term_dirty:     db 0
con_flushing:   db 0
ints_on:        db 0                    ; the boot has turned interrupts on

section .bss
alignb 8
term_list:      resq 1                  ; every terminal, newest first
con_first:      resq 1                  ; where printing goes when no terminal is named
term_making:    resq 1
term_pad_y:     resq 1                  ; the text's margin at the top
term_count:     resd 1
alignb 8
con_cols:       resq 1                  ; con_metrics
con_cx:         resq 1
con_flush_at:   resq 1
