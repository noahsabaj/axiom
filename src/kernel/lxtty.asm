; =============================================================================
;  lxtty.asm - a terminal, as Linux programs have it; poll and select
;
;  A terminal window (term.asm) has one terminal for programs (LY_*), made
;  the first time a program runs there and kept while the window is open
;  (TW_TTY holds a reference). It is what a tty is on Linux: a line
;  discipline between the keys and the program, as termios says (ICANON's
;  line editing, ECHO, ISIG's ctrl+C, ctrl+\ and ctrl+Z, ICRNL, VMIN and
;  VTIME), and an output side that gives what the program writes (OPOST's
;  ONLCR done) to vt.asm, with a copy, escape sequences left out, to the
;  serial log a line at a time. The window's size is its size; the
;  foreground group is sent SIGWINCH when that changes. The process that
;  has it (LY_FG) is the one 'linux' started there, until it ends; while
;  there is one, the window's keys are its session's (lt_key), xterm's
;  bytes for each, and ISIG's signals go to the foreground process group
;  (LY_PGRP, TIOCSPGRP).
;
;  poll, ppoll, select and pselect6 are here too: an open file that is not
;  a terminal is always ready; a terminal is readable once a read would
;  not wait. Waits for input wait on lx_poll_wq, which lx_poll_kick wakes
;  whenever something may have become readable.
; =============================================================================

; a terminal, as programs have it
LY_CON          equ 0                   ; its window's terminal (term.asm), 0 once closed
LY_LOCK         equ 8                   ; dword: a spinlock: input, LY_CON, LY_FG
LY_REFS         equ 12                  ; dword
LY_WLOCK        equ 16                  ; dword: lx_mutex: one writer at a time
LY_ECHO_LEN     equ 20                  ; dword: echoes not yet shown
LY_FG           equ 24                  ; the foreground process (LP_*), 0 if none
LY_PGRP         equ 32                  ; dword: its process group (TIOCGPGRP)
LY_SID          equ 36                  ; dword: its session (TIOCGSID)
LY_HEAD         equ 40                  ; dword: input, a ring: the next byte to read,
LY_TAIL         equ 44                  ; dword: and to write
LY_EDIT_LEN     equ 48                  ; dword: the line being edited (ICANON)
LY_EOFS         equ 52                  ; dword: ctrl+D on an empty line: reads find an end
LY_OUT_LEN      equ 56                  ; dword: the serial copy's line so far,
LY_OUT_STATE    equ 60                  ; dword: and where it is in an escape sequence
LY_TERMIOS      equ 64                  ; termios2 (TIO_*)
LY_WINSZ        equ 112                 ; winsize: rows, columns, width, height (words)
LY_ECHO         equ 128                 ; LY_ECHO_MAX
LY_IN           equ LY_ECHO + LY_ECHO_MAX
LY_EDIT         equ LY_IN + LY_IN_MAX
LY_OUT          equ LY_EDIT + LY_EDIT_MAX
LY_SIZE         equ LY_OUT + CON_LINE + 8
LY_ECHO_MAX     equ 64
LY_IN_MAX       equ 4096                ; (a power of two)
LY_EDIT_MAX     equ 4096
LY_READ_MAX     equ 1024                ; a read takes at most

; struct termios2
TIO_IFLAG       equ 0
TIO_OFLAG       equ 4
TIO_CFLAG       equ 8
TIO_LFLAG       equ 12
TIO_LINE        equ 16
TIO_CC          equ 17
TIO_ISPEED      equ 36
TIO_OSPEED      equ 40
TIO_SIZE        equ 36                  ; struct termios
TIO2_SIZE       equ 44
VINTR           equ 0
VQUIT           equ 1
VERASE          equ 2
VKILL           equ 3
VEOF            equ 4
VTIME           equ 5
VMIN            equ 6
VSUSP           equ 10
VEOL            equ 11
VWERASE         equ 14
VEOL2           equ 16
ISTRIP          equ 0x20
INLCR           equ 0x40
IGNCR           equ 0x80
ICRNL           equ 0x100
IXON            equ 0x400
IUTF8           equ 0x4000
OPOST           equ 1
ONLCR           equ 4
OCRNL           equ 8
ISIG            equ 1
ICANON          equ 2
ECHO            equ 8
ECHOE           equ 0x10
ECHOK           equ 0x20
ECHONL          equ 0x40
NOFLSH          equ 0x80
ECHOCTL         equ 0x200
ECHOKE          equ 0x800
IEXTEN          equ 0x8000

SIGQUIT         equ 3
SIGTSTP         equ 20
SIGWINCH        equ 28

POLLIN          equ 0x1
POLLPRI         equ 0x2
POLLOUT         equ 0x4
POLLERR         equ 0x8
POLLHUP         equ 0x10
POLLNVAL        equ 0x20
POLLRDNORM      equ 0x40
POLLWRNORM      equ 0x100

; the key codes past ASCII (kbd.asm)
KEY_FIRST       equ 0x80
LT_KEYS         equ 0x9C - KEY_FIRST

; ly_read's locals
LR_GEN          equ LY_READ_MAX         ; dword: lx_poll_gen when it looked
LR_DEADLINE     equ LY_READ_MAX + 8     ; VTIME's, once it began (TSC)
LR_WAIT         equ LY_READ_MAX + 16    ; the deadline of this wait, 0 for none
LR_SIZE         equ LY_READ_MAX + 24
LR_TIMED_OUT    equ 0x40000000          ; in R14: VTIME ran out

; LY_LOCKED / LY_UNLOCK: RBX's lock, interrupts off meanwhile (RDI lost)
%macro LY_LOCKED 0
    pushfq
    cli
    lea rdi, [rbx + LY_LOCK]
    call spin_lock
%endmacro
%macro LY_UNLOCK 0
    lea rdi, [rbx + LY_LOCK]
    call spin_unlock
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  The terminal and its window
; -----------------------------------------------------------------------------

; ly_new(RDI = a window's terminal, or 0) -> RAX = the terminal programs
; have there, a reference for the caller; 0 if out of memory. Main thread.
ly_new:
    test rdi, rdi
    jz .make
    mov rax, [rdi + TW_TTY]
    test rax, rax
    jz .make
    push rdi
    mov rdi, rax
    call ly_get
    pop rdi
    ret
.make:
    push rbx
    push rdi
    mov edi, LY_SIZE
    call kmalloc
    pop rdi
    test rax, rax
    jz .out
    mov rbx, rax
    mov [rbx + LY_CON], rdi
    mov dword [rbx + LY_REFS], 1
    xchg rdi, rbx
    call ly_defaults
    xchg rdi, rbx
    test rdi, rdi
    jz .made
    inc dword [rbx + LY_REFS]           ; and the window's
    mov [rdi + TW_TTY], rbx
.made:
    mov rax, rbx
.out:
    pop rbx
    ret

; ly_defaults(RDI = terminal): termios as a terminal starts. Preserves all.
ly_defaults:
    push rcx
    push rsi
    push rdi
    lea rsi, [ly_termios_default]
    lea rdi, [rdi + LY_TERMIOS]
    mov ecx, TIO2_SIZE
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    ret

; ly_get(RDI) / ly_put(RDI): a reference more, or one less (the last frees
; it). Preserve all.
ly_get:
    lock inc dword [rdi + LY_REFS]
    ret

ly_put:
    lock dec dword [rdi + LY_REFS]
    jnz .out
    call ly_flush
    call kfree
.out:
    ret

; ly_start(RDI = terminal, RSI = a process): the process has it now, in the
; foreground, as a terminal starts. Main thread.
ly_start:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    LY_LOCKED
    mov rdi, rbx
    call ly_defaults
    xor eax, eax
    mov [rbx + LY_HEAD], eax
    mov [rbx + LY_TAIL], eax
    mov [rbx + LY_EDIT_LEN], eax
    mov [rbx + LY_EOFS], eax
    mov [rbx + LY_ECHO_LEN], eax
    mov [rbx + LY_FG], r12
    mov eax, [r12 + LP_PID]
    mov [rbx + LY_PGRP], eax
    mov [rbx + LY_SID], eax
    call ly_measure
    LY_UNLOCK
    mov rdi, [rbx + LY_CON]
    test rdi, rdi
    jz .out
    xor esi, esi
    call vt_reset
.out:
    pop r12
    pop rbx
    ret

; ly_end(RDI = terminal, RSI = a process that ended): what it wrote said;
; if it had the terminal, the terminal is the shell's again, its screen
; the main one and its cursor on a line of its own
ly_end:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    call ly_flush
    LY_LOCKED
    cmp [rbx + LY_FG], r12
    jne .unlock
    mov qword [rbx + LY_FG], 0
    mov rdi, [rbx + LY_CON]
    test rdi, rdi
    jz .unlock
    mov esi, 1
    call vt_reset
.unlock:
    LY_UNLOCK
    pop r12
    pop rbx
    ret

; lt_detach(RDI = a window's terminal): it closes: its terminal is no
; one's; reads find an end. Main thread.
lt_detach:
    push rbx
    mov rbx, [rdi + TW_TTY]
    test rbx, rbx
    jz .out
    mov qword [rdi + TW_TTY], 0
    LY_LOCKED
    mov qword [rbx + LY_CON], 0
    LY_UNLOCK
    call lx_poll_kick
    mov rdi, rbx
    call ly_put
.out:
    pop rbx
    ret

; lt_resized(RDI = a window's terminal): its rows or columns changed; the
; program is told (SIGWINCH). Main thread.
lt_resized:
    push rbx
    mov rbx, [rdi + TW_TTY]
    test rbx, rbx
    jz .out
    LY_LOCKED
    mov rax, [rbx + LY_WINSZ]
    push rax
    call ly_measure
    pop rax
    cmp rax, [rbx + LY_WINSZ]
    je .unlock
    call ly_winch
.unlock:
    LY_UNLOCK
.out:
    pop rbx
    ret

; ly_measure(RBX = terminal, locked): LY_WINSZ from its window. Preserves
; others.
ly_measure:
    push rax
    push rcx
    push rdx
    mov rcx, [rbx + LY_CON]
    test rcx, rcx
    jz .out
    mov eax, [rcx + TW_ROWS_NOW]
    mov [rbx + LY_WINSZ], ax
    mov edx, eax
    imul edx, [font_ch]
    mov [rbx + LY_WINSZ + 6], dx
    mov eax, [rcx + TW_COLS_NOW]
    mov [rbx + LY_WINSZ + 2], ax
    imul eax, [font_cw]
    mov [rbx + LY_WINSZ + 4], ax
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; ly_winch(RBX = terminal, locked): its size changed: SIGWINCH to the
; foreground. Preserves all.
ly_winch:
    push rsi
    mov esi, SIGWINCH
    call ly_signal_fg
    pop rsi
    ret

; ly_signal_fg(RBX = terminal, locked, ESI = a signal): to its foreground
; process group, or, if that has no process, the process that has the
; terminal. Preserves all.
ly_signal_fg:
    push rax
    push rdi
    mov edi, [rbx + LY_PGRP]
    call lx_signal_group
    test eax, eax
    jnz .out
    mov rdi, [rbx + LY_FG]
    test rdi, rdi
    jz .out
    call lx_signal_proc
.out:
    pop rdi
    pop rax
    ret

; lx_poll_kick: something may be readable now: waits look again. Preserves
; all.
lx_poll_kick:
    lock inc dword [lx_poll_gen]
    push rdi
    lea rdi, [lx_poll_wq]
    call wq_wake
    pop rdi
    ret

; lx_poll_test(RDI = a generation seen) -> EAX = 1 if lx_poll_gen moved on
lx_poll_test:
    mov eax, [lx_poll_gen]
    cmp eax, [rdi]
    setne al
    movzx eax, al
    ret

; -----------------------------------------------------------------------------
;  Keys in
; -----------------------------------------------------------------------------

; lt_key(RDI = a window's terminal, ESI = a key code) -> EAX = 1 if a
; program there took it (it has the terminal), else 0. Main thread.
lt_key:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov rbx, [rdi + TW_TTY]
    xor eax, eax
    test rbx, rbx
    jz .out
    mov r12, rdi
    mov r13d, esi
    LY_LOCKED
    cmp qword [rbx + LY_FG], 0
    je .not_ours
    mov eax, r13d                       ; the key, as xterm's bytes
    mov qword [rsp + 8], 0
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .backspace
    cmp eax, KEY_FIRST
    jb .plain
    sub eax, KEY_FIRST
    cmp eax, LT_KEYS
    jae .fed
    lea rcx, [lt_key_seqs]
    mov rax, [rcx + rax * 8]
    mov [rsp + 8], rax
    cmp r13d, KEY_END                   ; arrows, home and end: ESC O x when
    ja .feed                            ; the program asked (DECCKM)
    test dword [r12 + TW_VFLAGS], VF_APPCURSOR
    jz .feed
    mov byte [rsp + 9], 'O'
    jmp .feed
.enter:
    mov byte [rsp + 8], 13
    jmp .feed
.backspace:
    mov byte [rsp + 8], 0x7F
    jmp .feed
.plain:
    mov [rsp + 8], al
.feed:
    lea r12, [rsp + 8]
.byte:
    movzx eax, byte [r12]
    test eax, eax
    jz .fed
    call ly_input
    inc r12
    jmp .byte
.fed:
    call ly_echo_flush
    LY_UNLOCK
    call lx_poll_kick
    mov eax, 1
    jmp .out
.not_ours:
    LY_UNLOCK
    xor eax, eax
.out:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; ly_input(RBX = terminal, locked, AL = a byte typed): the line discipline.
; Keeps RBX and R12-R15.
ly_input:
    push r12
    push r13
    push r14
    movzx r12d, al                      ; R12 = the byte
    mov r13d, [rbx + LY_TERMIOS + TIO_LFLAG]
    mov r14d, [rbx + LY_TERMIOS + TIO_IFLAG]
    test r14d, ISTRIP
    jz .stripped
    and r12d, 0x7F
.stripped:
    cmp r12d, 13
    jne .not_cr
    test r14d, IGNCR
    jnz .out
    test r14d, ICRNL
    jz .mapped
    mov r12d, 10
    jmp .mapped
.not_cr:
    cmp r12d, 10
    jne .mapped
    test r14d, INLCR
    jz .mapped
    mov r12d, 13
.mapped:
    test r12d, r12d                     ; (0 in c_cc is no character)
    jz .canonical
    test r13d, ISIG
    jz .canonical
    mov esi, SIGINT
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VINTR]
    je .signal
    mov esi, SIGQUIT
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VQUIT]
    je .signal
    mov esi, SIGTSTP
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VSUSP]
    je .signal
.canonical:
    test r13d, ICANON
    jz .raw
    test r12d, r12d
    jz .ordinary
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VERASE]
    je .erase
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VKILL]
    je .kill
    test r13d, IEXTEN
    jz .no_ext
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VWERASE]
    je .werase
.no_ext:
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VEOF]
    je .eof
    cmp r12d, 10
    je .line
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VEOL]
    je .line
    cmp r12b, [rbx + LY_TERMIOS + TIO_CC + VEOL2]
    je .line
.ordinary:
    mov ecx, [rbx + LY_EDIT_LEN]
    cmp ecx, LY_EDIT_MAX - 1            ; (room kept for the line's end)
    jae .out
    mov [rbx + LY_EDIT + rcx], r12b
    inc dword [rbx + LY_EDIT_LEN]
    mov eax, r12d
    call ly_echo
    jmp .out
.line:
    mov ecx, [rbx + LY_EDIT_LEN]
    mov [rbx + LY_EDIT + rcx], r12b
    inc dword [rbx + LY_EDIT_LEN]
    mov eax, r12d
    test r13d, ECHO
    jnz .echo_line
    cmp r12d, 10
    jne .commit
    test r13d, ECHONL
    jz .commit
    call ly_put_echo
    jmp .commit
.echo_line:
    call ly_echo
.commit:
    call ly_commit
    jmp .out
.eof:
    cmp dword [rbx + LY_EDIT_LEN], 0
    jne .commit
    inc dword [rbx + LY_EOFS]
    jmp .out
.erase:
    call ly_rubout
    jmp .out
.kill:
    cmp dword [rbx + LY_EDIT_LEN], 0
    je .out
    call ly_rubout
    jmp .kill
.werase:                                ; spaces, then a word
    mov ecx, [rbx + LY_EDIT_LEN]
    test ecx, ecx
    jz .out
    cmp byte [rbx + LY_EDIT + rcx - 1], ' '
    jne .word
    call ly_rubout
    jmp .werase
.word:
    mov ecx, [rbx + LY_EDIT_LEN]
    test ecx, ecx
    jz .out
    cmp byte [rbx + LY_EDIT + rcx - 1], ' '
    je .out
    call ly_rubout
    jmp .word
.raw:
    mov eax, r12d
    call ly_in_put
    mov eax, r12d
    call ly_echo
    jmp .out
.signal:
    push rsi
    mov eax, r12d                       ; ^C
    call ly_echo
    pop rsi
    test r13d, NOFLSH
    jnz .send
    xor eax, eax
    mov [rbx + LY_HEAD], eax
    mov [rbx + LY_TAIL], eax
    mov [rbx + LY_EDIT_LEN], eax
.send:
    call ly_signal_fg
.out:
    pop r14
    pop r13
    pop r12
    ret

; ly_in_put(RBX = terminal, locked, AL): onto the input ring, if there is
; room. Preserves all.
ly_in_put:
    push rcx
    push rdx
    mov ecx, [rbx + LY_TAIL]
    lea edx, [ecx + 1]
    and edx, LY_IN_MAX - 1
    cmp edx, [rbx + LY_HEAD]
    je .full
    mov [rbx + LY_IN + rcx], al
    mov [rbx + LY_TAIL], edx
.full:
    pop rdx
    pop rcx
    ret

; ly_in_count(RBX or RDI = terminal) -> EAX = bytes on the input ring.
; Preserves others.
ly_in_count:
    mov rdi, rbx
ly_in_count_rdi:
    mov eax, [rdi + LY_TAIL]
    sub eax, [rdi + LY_HEAD]
    and eax, LY_IN_MAX - 1
    ret

; ly_commit(RBX, locked): the line edited, onto the ring for reading.
; Preserves others but RAX, RCX.
ly_commit:
    xor ecx, ecx
.byte:
    cmp ecx, [rbx + LY_EDIT_LEN]
    jae .done
    mov al, [rbx + LY_EDIT + rcx]
    call ly_in_put
    inc ecx
    jmp .byte
.done:
    mov dword [rbx + LY_EDIT_LEN], 0
    ret

; ly_rubout(RBX, locked): the last character of the line edited, gone, and
; from the screen (ECHOE). Preserves R12-R15.
ly_rubout:
    mov ecx, [rbx + LY_EDIT_LEN]
    test ecx, ecx
    jz .out
.back:
    dec ecx
    movzx eax, byte [rbx + LY_EDIT + rcx]
    test ecx, ecx
    jz .gone
    mov edx, eax
    and edx, 0xC0
    cmp edx, 0x80                       ; UTF-8's continuation: its lead too
    je .back
.gone:
    mov [rbx + LY_EDIT_LEN], ecx
    mov edx, [rbx + LY_TERMIOS + TIO_LFLAG]
    test edx, ECHO
    jz .out
    test edx, ECHOE
    jz .out
    mov ecx, 1                          ; its width: 2 if it showed as ^X
    test edx, ECHOCTL
    jz .rub
    cmp eax, 0x7F
    je .two
    cmp eax, 9
    je .rub
    cmp eax, 0x20
    jae .rub
.two:
    mov ecx, 2
.rub:
    mov al, 8
    call ly_put_echo
    mov al, ' '
    call ly_put_echo
    mov al, 8
    call ly_put_echo
    dec ecx
    jnz .rub
.out:
    ret

; ly_echo(RBX, locked, AL): shown, if ECHO says so (a control as ^X, if
; ECHOCTL). Preserves all.
ly_echo:
    push rax
    test dword [rbx + LY_TERMIOS + TIO_LFLAG], ECHO
    jz .out
    test dword [rbx + LY_TERMIOS + TIO_LFLAG], ECHOCTL
    jz .plain
    cmp al, 0x7F
    je .control
    cmp al, 0x20
    jae .plain
    cmp al, 9
    je .plain
    cmp al, 10
    je .plain
.control:
    push rax
    mov al, '^'
    call ly_put_echo
    pop rax
    xor al, 0x40
.plain:
    call ly_put_echo
.out:
    pop rax
    ret

; ly_put_echo(RBX, locked, AL): to show. Preserves all.
ly_put_echo:
    push rcx
    mov ecx, [rbx + LY_ECHO_LEN]
    cmp ecx, LY_ECHO_MAX
    jb .room
    call ly_echo_flush
    xor ecx, ecx
.room:
    mov [rbx + LY_ECHO + rcx], al
    inc dword [rbx + LY_ECHO_LEN]
    pop rcx
    ret

; ly_echo_flush(RBX, locked): the echoes, shown. Preserves all.
ly_echo_flush:
    cmp dword [rbx + LY_ECHO_LEN], 0
    je .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rsi, [rbx + LY_ECHO]
    mov edx, [rbx + LY_ECHO_LEN]
    mov dword [rbx + LY_ECHO_LEN], 0
    call ly_emit
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

; -----------------------------------------------------------------------------
;  Output
; -----------------------------------------------------------------------------

; ly_emit(RBX = terminal, locked, RSI = bytes, RDX = how many): to the
; window, as OPOST says (ONLCR: LF as CR LF). Keeps RBX and R12-R15.
ly_emit:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 1024
    mov r12, rsi
    mov r13, rdx
    mov r15, [rbx + LY_CON]
    test r15, r15
    jz .out
.chunk:
    xor r14d, r14d
.byte:
    test r13, r13
    jz .write
    cmp r14d, 1024 - 2
    jae .write
    movzx eax, byte [r12]
    inc r12
    dec r13
    test dword [rbx + LY_TERMIOS + TIO_OFLAG], OPOST
    jz .put
    cmp eax, 10
    jne .cr
    test dword [rbx + LY_TERMIOS + TIO_OFLAG], ONLCR
    jz .put
    mov byte [rsp + r14], 13
    inc r14d
    jmp .put
.cr:
    cmp eax, 13
    jne .put
    test dword [rbx + LY_TERMIOS + TIO_OFLAG], OCRNL
    jz .put
    mov eax, 10
.put:
    mov [rsp + r14], al
    inc r14d
    jmp .byte
.write:
    test r14d, r14d
    jz .out
    mov rdi, r15
    mov rsi, rsp
    mov edx, r14d
    call vt_write
    test r13, r13
    jnz .chunk
.out:
    add rsp, 1024
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; ly_replies(RBX = terminal, locked): what its window answered (vt.asm),
; to the program as if typed
ly_replies:
    mov rdi, [rbx + LY_CON]
    test rdi, rdi
    jz .none
    cmp dword [rdi + TW_VREPLYN], 0
    je .none
    push r12
    push r13
    sub rsp, VT_REPLY
    push rdi
    lea rdi, [print_lock]               ; (interrupts are off)
    call spin_lock
    pop rdi
    mov r13d, [rdi + TW_VREPLYN]
    mov dword [rdi + TW_VREPLYN], 0
    lea rsi, [rdi + TW_VREPLY]
    mov rdi, rsp
    mov ecx, r13d
    rep movsb
    lea rdi, [print_lock]
    call spin_unlock
    xor r12d, r12d
.byte:
    cmp r12d, r13d
    jae .done
    mov al, [rsp + r12]
    call ly_input
    inc r12d
    jmp .byte
.done:
    add rsp, VT_REPLY
    pop r13
    pop r12
.none:
    ret

; ly_write(RDI = terminal, RSI = bytes, RDX = how many): what a program
; writes: to its window, and a copy to the serial log
ly_write:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    lea rdi, [rbx + LY_WLOCK]
    call lx_mutex_lock
    mov rsi, r12
    mov rdx, r13
    call ly_mirror
    LY_LOCKED
    mov rsi, r12
    mov rdx, r13
    call ly_emit
    call ly_replies
    call ly_echo_flush
    LY_UNLOCK
    call lx_poll_kick
    lea rdi, [rbx + LY_WLOCK]
    call lx_mutex_unlock
    pop r13
    pop r12
    pop rbx
    ret

; ly_mirror(RBX = terminal, its writer's lock held, RSI = bytes, RDX = how
; many): the serial log's copy: text, a line at a time (a line also ends
; where the cursor moves to another row), escape sequences and other
; controls left out
ly_mirror:
    test rdx, rdx
    jz .out
    movzx eax, byte [rsi]
    inc rsi
    dec rdx
    mov ecx, [rbx + LY_OUT_STATE]
    test ecx, ecx
    jnz .escape
    cmp eax, 27
    je .esc
    cmp eax, 10
    je .line
    cmp eax, 9
    je .put
    cmp eax, 0x20
    jb ly_mirror
    cmp eax, 0x7F
    je ly_mirror
.put:
    mov ecx, [rbx + LY_OUT_LEN]
    mov [rbx + LY_OUT + rcx], al
    inc ecx
    mov [rbx + LY_OUT_LEN], ecx
    cmp ecx, CON_LINE
    jb ly_mirror
.line:
    call ly_say
    jmp ly_mirror
.esc:
    mov dword [rbx + LY_OUT_STATE], 1
    jmp ly_mirror
.escape:
    cmp ecx, 1
    jne .in_csi
    mov ecx, 2                          ; ESC [: to a final byte
    cmp eax, '['
    je .state
    mov ecx, 3                          ; ESC ] P _ ^ X: a string, to BEL or ST
    cmp eax, ']'
    je .state
    cmp eax, 'P'
    je .state
    cmp eax, '_'
    je .state
    cmp eax, '^'
    je .state
    cmp eax, 'X'
    je .state
    mov ecx, 5                          ; ESC ( B and the like: a byte more
    cmp eax, 0x30
    jb .state
    xor ecx, ecx
.state:
    mov [rbx + LY_OUT_STATE], ecx
    jmp ly_mirror
.in_csi:
    cmp ecx, 2
    jne .in_string
    cmp eax, 0x40
    jb ly_mirror
    mov dword [rbx + LY_OUT_STATE], 0
    cmp dword [rbx + LY_OUT_LEN], 0     ; the cursor to another row, or the
    je ly_mirror                        ; screen erased: the line so far ends
    cmp eax, 'H'
    je .line
    cmp eax, 'f'
    je .line
    cmp eax, 'd'
    je .line
    cmp eax, 'A'
    je .line
    cmp eax, 'B'
    je .line
    cmp eax, 'J'
    je .line
    jmp ly_mirror
.in_string:
    cmp ecx, 3
    jne .string_esc
    cmp eax, 7
    je .ground
    cmp eax, 27
    jne ly_mirror
    mov ecx, 4
    jmp .state
.string_esc:
    cmp ecx, 4
    jne .ground
    mov ecx, 3
    cmp eax, '\'
    jne .state
.ground:
    xor ecx, ecx
    jmp .state
.out:
    ret

; ly_flush(RDI = terminal): a line not ended yet, to the serial log.
; Preserves all.
ly_flush:
    push rbx
    push rdi
    mov rbx, rdi
    lea rdi, [rbx + LY_WLOCK]
    call lx_mutex_lock
    cmp dword [rbx + LY_OUT_LEN], 0
    je .unlock
    call ly_say
.unlock:
    lea rdi, [rbx + LY_WLOCK]
    call lx_mutex_unlock
    pop rdi
    pop rbx
    ret

; ly_say(RBX = terminal, its writer's lock held): its line, to the serial
; log. Preserves all.
ly_say:
    push rax
    push rcx
    push rdi
    mov ecx, [rbx + LY_OUT_LEN]
    mov word [rbx + LY_OUT + rcx], 10
    mov dword [rbx + LY_OUT_LEN], 0
    pushfq
    cli
    lea rdi, [print_lock]               ; (whole, between the kernel's lines)
    call spin_lock
    lea rdi, [rbx + LY_OUT]
    call serial_text
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Reading
; -----------------------------------------------------------------------------

; ly_read(RDI = terminal, RSI = user buffer, RDX = bytes, ECX = the open
; file's flags) -> RAX = bytes read, 0 at an end, or -errno: a line, with
; ICANON; else as VMIN and VTIME say
ly_read:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, LR_SIZE
    mov r15, rsp                        ; R15 = the locals
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14d, ecx
    and r14d, ~LR_TIMED_OUT
    xor eax, eax
    test r13, r13
    jz .out
    cmp r13, LY_READ_MAX
    jbe .sized
    mov r13d, LY_READ_MAX
.sized:
    mov qword [r15 + LR_DEADLINE], 0
.again:
    LY_LOCKED
    mov eax, [lx_poll_gen]
    mov [r15 + LR_GEN], eax
    call ly_in_count
    test dword [rbx + LY_TERMIOS + TIO_LFLAG], ICANON
    jz .raw
    test eax, eax
    jnz .line
    cmp dword [rbx + LY_EOFS], 0
    je .none
    dec dword [rbx + LY_EOFS]
    jmp .nothing
.line:
    xor ecx, ecx                        ; to the line's end, at most
.line_byte:
    cmp rcx, r13
    jae .taken
    mov edx, [rbx + LY_HEAD]
    cmp edx, [rbx + LY_TAIL]
    je .taken
    movzx eax, byte [rbx + LY_IN + rdx]
    inc edx
    and edx, LY_IN_MAX - 1
    mov [rbx + LY_HEAD], edx
    mov [r15 + rcx], al
    inc ecx
    cmp eax, 10
    je .taken
    test eax, eax
    jz .line_byte
    cmp al, [rbx + LY_TERMIOS + TIO_CC + VEOL]
    je .taken
    cmp al, [rbx + LY_TERMIOS + TIO_CC + VEOL2]
    je .taken
    jmp .line_byte
.raw:
    movzx edx, byte [rbx + LY_TERMIOS + TIO_CC + VMIN]
    cmp rdx, r13
    jbe .min
    mov edx, r13d
.min:
    movzx ecx, byte [rbx + LY_TERMIOS + TIO_CC + VTIME]
    test edx, edx
    jnz .counted
    test eax, eax                       ; VMIN 0: what there is,
    jnz .take
    test ecx, ecx                       ; now, or within VTIME
    jz .nothing
    test r14d, LR_TIMED_OUT
    jnz .nothing
    jmp .timed
.counted:
    cmp eax, edx                        ; VMIN bytes: they are there,
    jae .take
    test eax, eax
    jz .none                            ; or none: wait for the first,
    test ecx, ecx
    jz .none
    test r14d, LR_TIMED_OUT             ; then VTIME, from it
    jnz .take
    jmp .timed
.take:
    xor ecx, ecx
.take_byte:
    cmp rcx, r13
    jae .taken
    mov edx, [rbx + LY_HEAD]
    cmp edx, [rbx + LY_TAIL]
    je .taken
    movzx eax, byte [rbx + LY_IN + rdx]
    inc edx
    and edx, LY_IN_MAX - 1
    mov [rbx + LY_HEAD], edx
    mov [r15 + rcx], al
    inc ecx
    jmp .take_byte
.taken:
    mov r13d, ecx
    LY_UNLOCK
    mov rdi, r12
    mov rsi, r15
    mov rdx, r13
    call lx_copy_out
    cmp rax, -4095
    jae .out
    mov rax, r13
    jmp .out
.nothing:
    LY_UNLOCK
    xor eax, eax
    jmp .out
.timed:
    mov rax, [r15 + LR_DEADLINE]        ; VTIME: tenths of a second
    test rax, rax
    jnz .deadline
    imul ecx, ecx, 100
    imul rcx, [tsc_per_ms]
    push rdx
    RDTSC64
    pop rdx
    add rax, rcx
    mov [r15 + LR_DEADLINE], rax
.deadline:
    mov [r15 + LR_WAIT], rax
    jmp .wait
.none:
    mov qword [r15 + LR_WAIT], 0
.wait:
    cmp qword [rbx + LY_CON], 0         ; no window: nothing will come
    je .nothing
    LY_UNLOCK
    mov rax, -EAGAIN
    test r14d, O_NONBLOCK
    jnz .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    lea rdx, [r15 + LR_GEN]
    mov rcx, [r15 + LR_WAIT]
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed                    ; a signal, or VTIME's end
    test eax, eax
    jnz .interrupted
    or r14d, LR_TIMED_OUT
    jmp .again
.interrupted:
    mov rax, -ERESTARTSYS
.out:
    add rsp, LR_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ly_ready(RDI = terminal) -> EAX = poll's events it has: POLLIN once a read
; would not wait, POLLOUT always, POLLHUP once its window closed.
; Preserves others.
ly_ready:
    push rcx
    mov eax, POLLOUT | POLLWRNORM
    mov ecx, [rdi + LY_TAIL]
    cmp ecx, [rdi + LY_HEAD]
    jne .in
    cmp dword [rdi + LY_EOFS], 0
    jne .in
    cmp qword [rdi + LY_CON], 0
    jne .out
    or eax, POLLHUP
.in:
    or eax, POLLIN | POLLRDNORM
.out:
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  ioctl
; -----------------------------------------------------------------------------

; ly_ioctl(RDI = terminal, ESI = request, RDX = argument) -> RAX
ly_ioctl:
    push rbx
    push r12
    push r13
    sub rsp, 48
    mov rbx, rdi
    mov r12, rdx
    mov r13d, esi
    cmp esi, 0x5401                     ; TCGETS
    je .get
    cmp esi, 0x802C542A                 ; TCGETS2
    je .get2
    cmp esi, 0x5402                     ; TCSETS, TCSETSW, TCSETSF
    jb .other
    cmp esi, 0x5404
    jbe .set
    cmp esi, 0x5413                     ; TIOCGWINSZ
    je .get_winsz
    cmp esi, 0x5414                     ; TIOCSWINSZ
    je .set_winsz
    cmp esi, 0x540F                     ; TIOCGPGRP
    je .get_pgrp
    cmp esi, 0x5410                     ; TIOCSPGRP
    je .set_pgrp
    cmp esi, 0x5429                     ; TIOCGSID
    je .get_sid
    cmp esi, 0x541B                     ; FIONREAD
    je .nread
    cmp esi, 0x5411                     ; TIOCOUTQ
    je .zero_out
    cmp esi, 0x540B                     ; TCFLSH
    je .flush
    cmp esi, 0x5412                     ; TIOCSTI
    je .sti
    cmp esi, 0x402C542B                 ; TCSETS2, TCSETSW2, TCSETSF2
    jb .other
    cmp esi, 0x402C542D
    jbe .set2
.other:
    xor eax, eax
    cmp esi, 0x540E                     ; TIOCSCTTY
    je .out
    cmp esi, 0x5422                     ; TIOCNOTTY
    je .out
    cmp esi, 0x540C                     ; TIOCEXCL, TIOCNXCL
    je .out
    cmp esi, 0x540D
    je .out
    cmp esi, 0x5409                     ; TCSBRK, TCXONC
    je .out
    cmp esi, 0x540A
    je .out
    cmp esi, 0x5425                     ; TCSBRKP
    je .out
    mov rax, -ENOTTY
    jmp .out
.get:
    mov edx, TIO_SIZE
    jmp .get_size
.get2:
    mov edx, TIO2_SIZE
.get_size:
    mov rdi, r12
    lea rsi, [rbx + LY_TERMIOS]
    call lx_copy_out
    jmp .result
.set:
    mov edx, TIO_SIZE
    jmp .set_size
.set2:
    mov edx, TIO2_SIZE
.set_size:
    push rdx
    lea rdi, [rsp + 8]
    mov rsi, r12
    call lx_copy_in
    pop rcx
    cmp rax, -4095
    jae .out
    LY_LOCKED
    lea rsi, [rsp + 8]                  ; (past the flags)
    lea rdi, [rbx + LY_TERMIOS]
    rep movsb
    mov eax, r13d
    and eax, 0xFF
    cmp eax, 0x04                       ; ...SF: input thrown away
    je .flushed
    cmp eax, 0x2D
    je .flushed
    test dword [rbx + LY_TERMIOS + TIO_LFLAG], ICANON
    jnz .set_done
    call ly_commit                      ; not ICANON: a line half typed is input
    jmp .set_done
.flushed:
    xor eax, eax
    mov [rbx + LY_HEAD], eax
    mov [rbx + LY_TAIL], eax
    mov [rbx + LY_EDIT_LEN], eax
    mov [rbx + LY_EOFS], eax
.set_done:
    LY_UNLOCK
    call lx_poll_kick
    xor eax, eax
    jmp .out
.get_winsz:
    mov rdi, r12
    lea rsi, [rbx + LY_WINSZ]
    mov edx, 8
    call lx_copy_out
    jmp .result
.set_winsz:
    mov rdi, rsp
    mov rsi, r12
    mov edx, 8
    call lx_copy_in
    cmp rax, -4095
    jae .out
    mov rcx, [rsp]
    LY_LOCKED
    cmp rcx, [rbx + LY_WINSZ]
    je .same
    mov [rbx + LY_WINSZ], rcx
    call ly_winch
.same:
    LY_UNLOCK
    xor eax, eax
    jmp .out
.get_pgrp:
    mov esi, [rbx + LY_PGRP]
    jmp .put32
.get_sid:
    mov esi, [rbx + LY_SID]
    jmp .put32
.nread:
    mov rdi, rbx
    call ly_in_count_rdi
    mov esi, eax
    jmp .put32
.zero_out:
    xor esi, esi
.put32:
    mov rdi, r12
    call lx_put32
    jmp .out
.set_pgrp:
    call .get32
    cmp rax, -4095
    jae .out
    mov [rbx + LY_PGRP], ecx
    xor eax, eax
    jmp .out
.flush:
    xor eax, eax
    cmp r12, 1                          ; TCOFLUSH: nothing waits to go out
    je .out
    LY_LOCKED
    xor eax, eax
    mov [rbx + LY_HEAD], eax
    mov [rbx + LY_TAIL], eax
    mov [rbx + LY_EDIT_LEN], eax
    mov [rbx + LY_EOFS], eax
    LY_UNLOCK
    xor eax, eax
    jmp .out
.sti:
    mov rdi, rsp
    mov rsi, r12
    mov edx, 1
    call lx_copy_in
    cmp rax, -4095
    jae .out
    LY_LOCKED
    mov al, [rsp + 8]
    call ly_input
    call ly_echo_flush
    LY_UNLOCK
    call lx_poll_kick
    xor eax, eax
    jmp .out
.result:
    cmp rax, -4095
    jae .out
    xor eax, eax
.out:
    add rsp, 48
    pop r13
    pop r12
    pop rbx
    ret
.get32:                                 ; R12 -> ECX = the int there, RAX = 0 or -EFAULT
    lea rdi, [rsp + 8]
    mov rsi, r12
    mov edx, 4
    call lx_copy_in
    mov ecx, [rsp + 8]
    ret

; -----------------------------------------------------------------------------
;  poll, ppoll, select, pselect6
; -----------------------------------------------------------------------------

; lx_poll_scan(RDI = struct pollfd array, kernel's, ESI = how many) -> EAX
; = how many have events, their revents set
lx_poll_scan:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d                      ; R13 = with events
.each:
    test r12d, r12d
    jz .done
    mov word [rbx + 6], 0
    mov edi, [rbx]
    test edi, edi
    js .next
    call lx_fd_get
    cmp rax, -4095
    jb .open
    mov eax, POLLNVAL
    jmp .set
.open:
    cmp dword [rax + LF_KIND], LFK_TTY
    je .tty
    cmp dword [rax + LF_KIND], LFK_PIPE
    je .pipe
    mov eax, POLLIN | POLLOUT | POLLRDNORM | POLLWRNORM
    jmp .events
.pipe:
    mov rdi, rax
    call lx_pipe_ready
    jmp .events
.tty:
    mov rdi, [rax + LF_TTY]
    call ly_ready
.events:
    movzx ecx, word [rbx + 4]
    or ecx, POLLERR | POLLHUP
    and eax, ecx
.set:
    mov [rbx + 6], ax
    test eax, eax
    jz .next
    inc r13d
.next:
    add rbx, 8
    dec r12d
    jmp .each
.done:
    mov eax, r13d
    pop r13
    pop r12
    pop rbx
    ret

; lx_poll_wait(RDI = pollfds, ESI = how many, RDX = a TSC deadline, 0 for
; none, -1 not to wait) -> RAX = how many have events, 0 at the deadline,
; -EINTR if a signal came
lx_poll_wait:
    push rbx
    push r12
    push r13
    sub rsp, 16
    mov rbx, rdi
    mov r12d, esi
    mov r13, rdx
.again:
    mov eax, [lx_poll_gen]              ; (before looking: nothing missed)
    mov [rsp], eax
    mov rdi, rbx
    mov esi, r12d
    call lx_poll_scan
    test eax, eax
    jnz .out
    cmp r13, -1
    je .out
    test r13, r13
    jz .wait
    RDTSC64
    cmp rax, r13
    jae .timeout
.wait:
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    mov rcx, r13
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again                           ; (the deadline: looked at once more)
    mov rax, -EINTR
    jmp .out
.timeout:
    xor eax, eax
.out:
    add rsp, 16
    pop r13
    pop r12
    pop rbx
    ret

; lx_poll_deadline(RAX = nanoseconds, or -1 for none) -> RAX = poll's
; deadline: 0 for none, -1 for now, else when (TSC)
lx_poll_deadline:
    cmp rax, -1
    je .forever
    test rax, rax
    jz .now
    call lx_ns_tsc
    ret
.forever:
    xor eax, eax
    ret
.now:
    mov rax, -1
    ret

; poll(fds, nfds, timeout in ms)
lx_sys_poll:
    movsxd rdx, edx
    test rdx, rdx
    js .forever
    imul rdx, rdx, 1000000
    mov rax, rdx
    jmp lx_poll_with
.forever:
    mov rax, -1
; lx_poll_with(RDI = user pollfds, ESI = how many, RAX = nanoseconds or -1)
lx_poll_with:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13d, esi
    call lx_poll_deadline
    mov r14, rax
    mov rax, -EINVAL
    cmp r13d, LX_FD_MAX
    ja .out
    lea edi, [r13 * 8 + 8]
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    lea edx, [r13 * 8]
    call lx_copy_in
    cmp rax, -4095
    jae .free
    mov rdi, rbx
    mov esi, r13d
    mov rdx, r14
    call lx_poll_wait
    cmp rax, -4095
    jae .free
    push rax
    mov rdi, r12
    mov rsi, rbx
    lea edx, [r13 * 8]
    call lx_copy_out
    pop rcx
    cmp rax, -4095
    jae .free
    mov rax, rcx
.free:
    mov rdi, rbx
    call kfree
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_poll_mask(RDI = user sigset or 0, RSI = its size) -> RAX = 0, or
; -errno: while the call waits, that mask (as rt_sigsuspend has it)
lx_poll_mask:
    xor eax, eax
    test rdi, rdi
    jz .out
    mov rax, -EINVAL
    cmp rsi, 8
    jne .out
    call lx_get64
    test rax, rax
    jnz .out
    mov rcx, LX_SIG_FIXED
    not rcx
    and rdx, rcx
    mov rax, [gs:PC_CURRENT]
    mov rcx, [rax + TH_SIGMASK]
    mov [rax + TH_SAVEMASK], rcx
    mov [rax + TH_SIGMASK], rdx
    or dword [rax + TH_LXFL], LXF_SUSPEND
    xor eax, eax
.out:
    ret

; lx_poll_ts(RDI = user timespec or 0) -> RAX = nanoseconds, -1 for none,
; or -errno
lx_poll_ts:
    mov rax, -1
    test rdi, rdi
    jz .out
    call lx_ts_in
.out:
    ret

; ppoll(fds, nfds, timeout timespec, sigmask, sigsetsize)
lx_sys_ppoll:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    mov rdi, rdx
    push rcx
    push r8
    call lx_poll_ts
    pop rsi
    pop rdi
    cmp rax, -4095
    jb .ts
    cmp rax, -1
    jne .out
.ts:
    mov r13, rax
    call lx_poll_mask
    test rax, rax
    jnz .out
    mov rdi, rbx
    mov esi, r12d
    mov rax, r13
    call lx_poll_with
.out:
    pop r13
    pop r12
    pop rbx
    ret

; select(nfds, readfds, writefds, exceptfds, timeout timeval)
lx_sys_select:
    push rbx
    sub rsp, 16
    mov rbx, rdi
    mov rax, -1
    test r8, r8
    jz .forever
    push rsi
    push rdx
    push rcx
    lea rdi, [rsp + 24]
    mov rsi, r8
    mov edx, 16
    call lx_copy_in
    pop rcx
    pop rdx
    pop rsi
    cmp rax, -4095
    jae .out
    mov rax, -EINVAL
    mov r8, [rsp + 8]                   ; microseconds
    cmp r8, 1000000
    jae .out
    mov rax, [rsp]
    test rax, rax
    js .einval
    imul rax, rax, 1000000
    add rax, r8
    imul rax, rax, 1000
.forever:
    mov rdi, rbx
    call lx_select_with
.out:
    add rsp, 16
    pop rbx
    ret
.einval:
    mov rax, -EINVAL
    jmp .out

; pselect6(nfds, readfds, writefds, exceptfds, timeout timespec, sigmask
; {set, size})
lx_sys_pselect6:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; the mask's set and size; the timeout
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r9
    mov rdi, r8
    call lx_poll_ts
    cmp rax, -4095
    jb .ts
    cmp rax, -1
    jne .out
.ts:
    mov [rsp + 16], rax
    test r15, r15
    jz .select
    mov rdi, rsp
    mov rsi, r15
    mov edx, 16
    call lx_copy_in
    cmp rax, -4095
    jae .out
    mov rdi, [rsp]
    mov rsi, [rsp + 8]
    call lx_poll_mask
    test rax, rax
    jnz .out
.select:
    mov edi, ebx
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    mov rax, [rsp + 16]
    call lx_select_with
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_select_with(EDI = nfds, RSI, RDX, RCX = user fd_sets or 0, RAX =
; nanoseconds or -1) -> RAX = descriptors ready, or -errno
lx_select_with:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 3 * 128 + 32
    mov ebx, edi                        ; RBX = nfds
    mov [rsp + 384], rsi                ; the sets, the user's
    mov [rsp + 392], rdx
    mov [rsp + 400], rcx
    call lx_poll_deadline
    mov [rsp + 408], rax
    mov rax, -EINVAL
    test ebx, ebx
    js .out
    cmp ebx, LX_FD_MAX
    ja .out
    lea r12d, [rbx + 63]                ; R12 = bytes of a set, in qwords
    shr r12d, 6
    shl r12d, 3
    xor r13d, r13d                      ; the sets, here (0s if not given)
.copy:
    mov rdi, r13                        ; the set's place here
    shl rdi, 7
    add rdi, rsp
    push rdi
    xor eax, eax
    mov ecx, 16
    rep stosq
    pop rdi
    mov rsi, [rsp + 384 + r13 * 8]
    test rsi, rsi
    jz .copied
    mov edx, r12d
    call lx_copy_in
    cmp rax, -4095
    jae .out
.copied:
    inc r13d
    cmp r13d, 3
    jb .copy
    lea edi, [rbx * 8 + 8]              ; a pollfd for each descriptor named
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; RBP = the pollfds
    xor r13d, r13d                      ; R13 = descriptor
    xor r14d, r14d                      ; R14 = pollfds
.each:
    cmp r13d, ebx
    jae .made
    xor ecx, ecx
    bt [rsp], r13
    jnc .no_read
    or ecx, POLLIN
.no_read:
    bt [rsp + 128], r13
    jnc .no_write
    or ecx, POLLOUT
.no_write:
    bt [rsp + 256], r13
    jnc .no_except
    or ecx, POLLPRI
.no_except:
    test ecx, ecx
    jz .skip
    mov [rbp + r14 * 8], r13d
    mov [rbp + r14 * 8 + 4], cx
    inc r14d
.skip:
    inc r13d
    jmp .each
.made:
    mov rdi, rbp
    mov esi, r14d
    mov rdx, [rsp + 408]
    call lx_poll_wait
    cmp rax, -4095
    jae .free
    xor eax, eax                        ; the sets again: those ready
    mov ecx, 48
    mov rdi, rsp
    rep stosq
    xor r13d, r13d
    xor r15d, r15d                      ; R15 = bits set
.result:
    cmp r13d, r14d
    jae .results
    mov ecx, [rbp + r13 * 8]
    movzx eax, word [rbp + r13 * 8 + 6]
    test eax, POLLNVAL
    jnz .badf
    test eax, POLLIN | POLLHUP | POLLERR
    jz .not_read
    movzx edx, word [rbp + r13 * 8 + 4]
    test edx, POLLIN
    jz .not_read
    bts [rsp], rcx
    inc r15d
.not_read:
    test eax, POLLOUT | POLLERR
    jz .not_write
    movzx edx, word [rbp + r13 * 8 + 4]
    test edx, POLLOUT
    jz .not_write
    bts [rsp + 128], rcx
    inc r15d
.not_write:
    test eax, POLLPRI
    jz .next_result
    bts [rsp + 256], rcx
    inc r15d
.next_result:
    inc r13d
    jmp .result
.results:
    xor r13d, r13d                      ; back to the user's sets
.back:
    mov rdi, [rsp + 384 + r13 * 8]
    test rdi, rdi
    jz .back_next
    mov rsi, r13
    shl rsi, 7
    add rsi, rsp
    mov edx, r12d
    call lx_copy_out
    cmp rax, -4095
    jae .free
.back_next:
    inc r13d
    cmp r13d, 3
    jb .back
    mov eax, r15d
    jmp .free
.badf:
    mov rax, -EBADF
.free:
    mov rdi, rbp
    call kfree
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    add rsp, 3 * 128 + 32
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
align 8
; a terminal's termios as it starts: ICRNL IXON IUTF8; OPOST ONLCR; B38400
; CS8 CREAD HUPCL; ISIG ICANON ECHO ECHOE ECHOK ECHOCTL ECHOKE IEXTEN; and
; ^C ^\ DEL ^U ^D, VTIME 0, VMIN 1, ^Q ^S ^Z, ^R ^O ^W ^V
ly_termios_default:
    dd ICRNL | IXON | IUTF8, OPOST | ONLCR, 0x4BF
    dd ISIG | ICANON | ECHO | ECHOE | ECHOK | ECHOCTL | ECHOKE | IEXTEN
    db 0                                ; c_line
    db 3, 0x1C, 0x7F, 0x15, 4, 0, 1, 0, 0x11, 0x13, 0x1A, 0, 0x12, 0x0F, 0x17, 0x16
    db 0, 0, 0
    dd 38400, 38400
; xterm's bytes for the keys past ASCII, from KEY_FIRST (8 each)
%macro KEYSEQ 1
%%s: db %1
    times 8 - ($ - %%s) db 0
%endmacro
lt_key_seqs:
    KEYSEQ {27, '[A'}                   ; up
    KEYSEQ {27, '[B'}                   ; down
    KEYSEQ {27, '[D'}                   ; left
    KEYSEQ {27, '[C'}                   ; right
    KEYSEQ {27, '[H'}                   ; home
    KEYSEQ {27, '[F'}                   ; end
    KEYSEQ {27, '[5~'}                  ; page up
    KEYSEQ {27, '[6~'}                  ; page down
    KEYSEQ {27, '[2~'}                  ; insert
    KEYSEQ {27, '[3~'}                  ; delete
    KEYSEQ {27, '[Z'}                   ; shift+tab
    times 5 dq 0
    KEYSEQ {27, 'OP'}                   ; F1
    KEYSEQ {27, 'OQ'}
    KEYSEQ {27, 'OR'}
    KEYSEQ {27, 'OS'}
    KEYSEQ {27, '[15~'}                 ; F5
    KEYSEQ {27, '[17~'}
    KEYSEQ {27, '[18~'}
    KEYSEQ {27, '[19~'}
    KEYSEQ {27, '[20~'}
    KEYSEQ {27, '[21~'}
    KEYSEQ {27, '[23~'}
    KEYSEQ {27, '[24~'}                 ; F12

section .bss
alignb 8
lx_poll_wq:     resb WQ_SIZE            ; waits for input (and poll's, select's)
lx_poll_gen:    resd 1                  ; moves on whenever input may have come
