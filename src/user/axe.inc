; =============================================================================
;  axe.inc - what every Axiom program begins with: the header the kernel
;  loads it by (AXE_*, defs.inc), its sections, and a small runtime
;
;  A program defines main (RDI = the start block) -> RAX = its exit code,
;  and ends with AXE_END. Sections: .text (code), .rodata, .data, .bss, each
;  on pages of its own, as the kernel maps them. The runtime, through the
;  program's ring:
;    ax_do(RDI = an entry, SQ_SIZE bytes) -> RAX = its result, RDX = its
;      value: submitted, and waited for
;    ax_submit(RDI = an entry); ax_enter(EDI = take, ESI = wait for) -> RAX;
;    ax_reap -> RAX = result, RDX = value, RCX = data; CF if none waits
;    ax_write(RSI = text, RDX = bytes): onto the console, a line at a time
;    ax_puts(RSI = a NUL-ended line)
;    ax_add(RSI = NUL-ended), ax_addn(RSI, RCX = bytes), ax_addu(RDI),
;      ax_addd(RDI), ax_addx(RDI): onto ax_line; ax_flush writes it
;    ax_now -> RAX = the TSC; ax_us(RDI) -> RAX = that many us in TSC ticks
;    ax_spawn(RSI = NUL-ended "program arguments", EDI = a handle to give it
;      or 0) -> RAX = a handle to the task started, RDX = to its first
;      thread; RAX < 0 if refused. ax_spawn2: EDX = a second handle to give.
;      A desktop, files, the network or the store given is also where the
;      program finds one it wanted (ax_desk, ax_files, ax_net, ax_store).
;    ax_send(EDI = a channel's end, RSI = bytes, RDX = how many, a page at
;      most) -> RAX = the bytes, or E_*
;    ax_recv(EDI = an end, RSI = to, RDX = room, a page at most, RCX = TSC
;      deadline or 0) -> RAX = the next message's bytes, once it comes, or
;      E_* (E_PEER: the other end is closed, and nothing waits)
;  Globals: ax_sb (the start block), ax_ring, ax_ring_va, ax_console, ax_io
;  and ax_io_va (a page of memory to write from), ax_tsc_us, ax_gift (what
;  the task that started it gave it, 0 if nothing; ax_gift2 a second), ax_store (its names in
;  the store, under "name/", if there is a store), ax_net (the network, all
;  of it), ax_desk (the desktop, to open windows on), ax_files (the files on
;  every volume, FAT's; written only where 'vol <n> rw' was said),
;  ax_settings (the machine's settings: RO_SET_LIST, RO_SET_CHANGE, RO_WAIT
;  for a change): each 0 unless it was run from the shell and wanted it, or
;  the shell granted it for that run.
;  Each preserves RBX, RBP, R12-R15, as the kernel's functions do.
;
;  A program says what it needs, once, anywhere in it:
;    WANTS AW_DESK | AW_NET      (AW_NET, AW_STORE, AW_DESK, AW_FILES,
;                                 AW_SETTINGS; or WANTS nothing)
;  The shell gives it that and no more; '+net', '+store', '+desk', '+files'
;  and '+settings' before its name give more, for that run.
; =============================================================================

%include "defs.inc"

; WANTS <AW_* or-ed, or nothing>: what the program needs to be given
%macro WANTS 1
%ifidni %1, nothing
axe_wants equ 0
%else
axe_wants equ %1
%endif
%endmacro

bits 64
default rel
org USER_IMAGE

section .text   align=4096
section .rodata align=4096 follows=.text
section .data   align=4096 follows=.rodata
section .bss    nobits valign=4096 vfollows=.data
sectalign off                           ; align and alignb leave these be

section .text
axe_header:
    db 'AXIOMEX2'
    dq ax_start
    dq section..rodata.start            ; the code ends where the constants begin
    dq section..data.start
    dq axe_data_end
    dq axe_bss_end
    dq axe_wants                        ; what it needs (WANTS)

; RDI = the start block, RSP = USER_STACK_TOP
ax_start:
    mov [ax_sb], rdi
    mov eax, [rdi + SB_RING]
    mov [ax_ring], eax
    mov rax, [rdi + SB_RING_VA]
    mov [ax_ring_va], rax
    mov eax, [rdi + SB_CONSOLE]
    mov [ax_console], eax
    mov rax, [rdi + SB_TSC_PER_US]
    mov [ax_tsc_us], rax
    mov eax, [rdi + SB_GIFT]
    mov [ax_gift], eax
    mov eax, [rdi + SB_GIFT2]
    mov [ax_gift2], eax
    mov eax, [rdi + SB_STORE]
    mov [ax_store], eax
    mov eax, [rdi + SB_NET]
    mov [ax_net], eax
    mov eax, [rdi + SB_DESK]
    mov [ax_desk], eax
    mov eax, [rdi + SB_FILES]
    mov [ax_files], eax
    mov eax, [rdi + SB_SETTINGS]
    mov [ax_settings], eax
    mov edi, 4096                       ; a page to write from
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .exit
    mov [ax_io], eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .exit
    mov [ax_io_va], rax
    mov rdi, [ax_sb]
    call main
.exit:
    mov rdi, rax
    mov eax, SYS_EXIT
    syscall
    ud2

; ax_submit(RDI = an entry): onto the ring, at its tail
ax_submit:
    mov r8, [ax_ring_va]
    mov eax, [r8 + RA_SQ_TAIL]
    mov ecx, [r8 + RA_SQ_ENTRIES]
    dec ecx
    and ecx, eax
    shl ecx, 6
    add ecx, [r8 + RA_SQ_OFF]
    add rcx, r8
    mov rdx, [rdi]
    mov [rcx], rdx
    mov rdx, [rdi + 8]
    mov [rcx + 8], rdx
    mov rdx, [rdi + 16]
    mov [rcx + 16], rdx
    mov rdx, [rdi + 24]
    mov [rcx + 24], rdx
    mov rdx, [rdi + 32]
    mov [rcx + 32], rdx
    mov rdx, [rdi + 40]
    mov [rcx + 40], rdx
    mov rdx, [rdi + 48]
    mov [rcx + 48], rdx
    mov rdx, [rdi + 56]
    mov [rcx + 56], rdx
    inc eax                             ; written before the tail moves
    mov [r8 + RA_SQ_TAIL], eax
    ret

; ax_enter(EDI = entries to take, ESI = completions to wait for) -> RAX
ax_enter:
    mov edx, esi
    mov esi, edi
    mov edi, [ax_ring]
    xor r10d, r10d
    mov eax, SYS_RING_ENTER
    syscall
    ret

; ax_reap -> RAX = result, RDX = value, RCX = data of the next completion;
; CF if there is none
ax_reap:
    mov r8, [ax_ring_va]
    mov eax, [r8 + RA_CQ_HEAD]
    cmp eax, [r8 + RA_CQ_TAIL]
    je .none
    mov ecx, [r8 + RA_CQ_ENTRIES]
    dec ecx
    and ecx, eax
    shl ecx, 5
    add ecx, [r8 + RA_CQ_OFF]
    add rcx, r8
    mov rax, [rcx + CQ_RESULT]
    mov rdx, [rcx + CQ_VALUE]
    mov rcx, [rcx + CQ_DATA]
    inc dword [r8 + RA_CQ_HEAD]
    clc
    ret
.none:
    stc
    ret

; ax_do(RDI = an entry) -> RAX = result, RDX = value
ax_do:
    call ax_submit
    mov edi, 1
    mov esi, 1
    call ax_enter
    call ax_reap
    ret

; ax_write(RSI = text, RDX = bytes, at most a page)
ax_write:
    push rbx
    mov rbx, rdx
    mov rdi, [ax_io_va]
    mov rcx, rdx
    rep movsb
    sub rsp, SQ_SIZE
    mov rdi, rsp
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    mov byte [rsp + SQ_OP], RO_WRITE
    mov eax, [ax_console]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], rbx
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    pop rbx
    ret

; ax_puts(RSI = a NUL-ended line)
ax_puts:
    xor edx, edx
.len:
    cmp byte [rsi + rdx], 0
    je ax_write
    inc rdx
    jmp .len

; ax_add(RSI = NUL-ended text): onto ax_line
ax_add:
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je ax_addn
    inc rcx
    jmp .len

; ax_addn(RSI = text, RCX = bytes)
ax_addn:
    mov eax, [ax_len]
    lea rdi, [ax_line]
    add rdi, rax
    mov edx, AX_LINE_MAX
    sub edx, eax
    cmp ecx, edx
    jbe .fits
    mov ecx, edx
.fits:
    add [ax_len], ecx
    rep movsb
    ret

; ax_addu(RDI = unsigned), ax_addd(RDI = signed), ax_addx(RDI = in hex)
ax_addd:
    test rdi, rdi
    jns ax_addu
    push rdi
    lea rsi, [ax_minus]
    mov ecx, 1
    call ax_addn
    pop rdi
    neg rdi
ax_addu:
    mov rax, rdi
    lea rsi, [ax_digits + 24]
    mov ecx, 10
.digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digit
    lea rcx, [ax_digits + 24]
    sub rcx, rsi
    jmp ax_addn

ax_addx:
    mov rax, rdi
    lea rsi, [ax_digits + 24]
.digit:
    mov edx, eax
    and edx, 15
    lea rcx, [ax_hex]
    mov dl, [rcx + rdx]
    dec rsi
    mov [rsi], dl
    shr rax, 4
    jnz .digit
    dec rsi
    mov byte [rsi], 'x'
    dec rsi
    mov byte [rsi], '0'
    lea rcx, [ax_digits + 24]
    sub rcx, rsi
    jmp ax_addn

; ax_flush: ax_line onto the console, and empty again
ax_flush:
    lea rsi, [ax_line]
    mov edx, [ax_len]
    mov dword [ax_len], 0
    jmp ax_write

; ax_now -> RAX = the TSC
ax_now:
    rdtsc
    shl rdx, 32
    or rax, rdx
    ret

; ax_us(RDI = microseconds) -> RAX = TSC ticks
ax_us:
    mov rax, [ax_tsc_us]
    imul rax, rdi
    ret

; ax_spawn(RSI = "program arguments", EDI = a handle to give, or 0)
; ax_spawn2(RSI, EDI, EDX = a second handle to give, or 0)
ax_spawn:
    xor edx, edx
ax_spawn2:
    push rbx
    push r12
    mov ebx, edi
    mov r12d, edx
    mov rdi, [ax_io_va]                 ; the text, from the page
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 4095
    jb .copy
.copied:
    mov edi, [ax_io]
    xor esi, esi
    mov edx, ecx
    mov r10d, ebx
    mov r8d, r12d
    mov eax, SYS_SPAWN
    syscall
    pop r12
    pop rbx
    ret

; ax_send(EDI = a channel's end, RSI = bytes, RDX = how many)
ax_send:
    push rbx
    push r12
    mov ebx, edi
    mov r12, rdx
    mov rdi, [ax_io_va]
    mov rcx, rdx
    rep movsb
    sub rsp, SQ_SIZE
    call ax_entry
    mov byte [rsp + SQ_OP], RO_SEND
    mov [rsp + SQ_HANDLE], ebx
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], r12
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    pop r12
    pop rbx
    ret

; ax_recv(EDI = an end, RSI = to, RDX = room, RCX = deadline): RO_WAIT on
; it, linked to RO_RECV into a page of its own, then copied out
ax_recv:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    cmp qword [ax_rx_va], 0             ; the page, the first time
    jne .page
    mov edi, 4096
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .out
    mov [ax_rx], eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .out
    mov [ax_rx_va], rax
.page:
    sub rsp, SQ_SIZE + 16
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WAIT
    mov byte [rsp + SQ_FLAGS], SQF_LINK
    mov [rsp + SQ_HANDLE], ebx
    mov [rsp + SQ_DEADLINE], r14
    mov qword [rsp + SQ_DATA], 1
    mov rdi, rsp
    call ax_submit
    call ax_entry
    mov byte [rsp + SQ_OP], RO_RECV
    mov [rsp + SQ_HANDLE], ebx
    mov eax, [ax_rx]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], r13
    mov qword [rsp + SQ_DATA], 2
    mov rdi, rsp
    call ax_submit
    mov edi, 2
    mov esi, 2
    call ax_enter
    call ax_reap                        ; both, in whichever order
    mov [rsp + SQ_SIZE], rax
    mov [rsp + SQ_SIZE + 8], rcx
    call ax_reap
    cmp rcx, 2
    je .result
    mov rax, [rsp + SQ_SIZE]            ; the receive was the first
.result:
    add rsp, SQ_SIZE + 16
    test rax, rax
    js .out
    mov rsi, [ax_rx_va]
    mov rdi, r12
    mov rcx, rax
    rep movsb
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ax_entry: the entry at [RSP + 8] (the caller's [RSP]) zeroed. Preserves
; all but RCX and RDI.
ax_entry:
    push rax
    lea rdi, [rsp + 16]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rax
    ret

AX_LINE_MAX     equ 512

section .rodata
ax_minus:       db '-'
ax_hex:         db '0123456789abcdef'

section .bss
alignb 8
ax_sb:          resq 1
ax_ring_va:     resq 1
ax_io_va:       resq 1
ax_tsc_us:      resq 1
ax_rx_va:       resq 1
ax_ring:        resd 1
ax_console:     resd 1
ax_io:          resd 1
ax_gift:        resd 1
ax_gift2:       resd 1
ax_store:       resd 1
ax_net:         resd 1
ax_desk:        resd 1
ax_files:       resd 1
ax_settings:    resd 1
ax_rx:          resd 1
ax_len:         resd 1
ax_digits:      resb 24
ax_line:        resb AX_LINE_MAX

section .text

; AXE_END: last in every program
%macro AXE_END 0
section .data
axe_data_end:
section .bss
axe_bss_end:
%endmacro
