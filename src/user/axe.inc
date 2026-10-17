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
;  Globals: ax_sb (the start block), ax_ring, ax_ring_va, ax_console, ax_io
;  and ax_io_va (a page of memory to write from), ax_tsc_us.
;  Each preserves RBX, RBP, R12-R15, as the kernel's functions do.
; =============================================================================

%include "defs.inc"

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
    db 'AXIOMEX1'
    dq ax_start
    dq section..rodata.start            ; the code ends where the constants begin
    dq section..data.start
    dq axe_data_end
    dq axe_bss_end

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
ax_ring:        resd 1
ax_console:     resd 1
ax_io:          resd 1
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
