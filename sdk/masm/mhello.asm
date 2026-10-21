; mhello: an Axiom program in MASM, as docs/ABI.md has it: the start block,
; the ring, a block of memory to hand the kernel bytes in, the console, the
; clock, a second thread joined, and a window: drawn, titled, shown, its
; keys (as text, and down and up) and its close button.
;
;   mhello [words]
;
; Built by tools/masm.py (ml64, link.exe, tools/mkaxe.py).
; wants: AW_DESK

OPTION CASEMAP:NONE
INCLUDE axiom.inc

WIN_W           EQU 320
WIN_H           EQU 200
COLOR           EQU 003060A0h           ; 0x00RRGGBB
RECV_AT         EQU 2048                ; where in the io block a message comes

.data?
ring_va         QWORD ?                 ; the ring's memory
io_va           QWORD ?                 ; the io block: bytes for the kernel
tsc_us          QWORD ?                 ; TSC ticks a microsecond
ring_h          DWORD ?
con_h           DWORD ?
desk_h          DWORD ?
io_h            DWORD ?
end_h           DWORD ?                 ; our end of the window's channel
win_h           DWORD ?
ALIGN 16
sqe             BYTE SQ_SIZE DUP (?)    ; a request, made here, then submitted
args            BYTE 256 DUP (?)

.const
s_args          BYTE "mhello: args [", 0
s_close         BYTE "]", 10, 0
s_slept         BYTE "mhello: slept ", 0
s_ms            BYTE " ms", 10, 0
s_thread        BYTE "mhello: thread returned ", 0
s_nl            BYTE 10, 0
s_open          BYTE "mhello: window open", 10, 0
s_title         BYTE "MASM on Axiom", 0
s_key           BYTE "mhello: key ", 0
s_down          BYTE "mhello: down 0x", 0
s_up            BYTE "mhello: up 0x", 0
s_bye           BYTE "mhello: bye", 10, 0
s_nodesk        BYTE "mhello: no desktop", 10, 0
hex             BYTE "0123456789abcdef"

.code

; The first thread: RDI = the start block, RSP 16-aligned.
start PROC
    mov eax, DWORD PTR [rdi + SB_RING]
    mov ring_h, eax
    mov rax, QWORD PTR [rdi + SB_RING_VA]
    mov ring_va, rax
    mov eax, DWORD PTR [rdi + SB_CONSOLE]
    mov con_h, eax
    mov eax, DWORD PTR [rdi + SB_DESK]
    mov desk_h, eax
    mov rax, QWORD PTR [rdi + SB_TSC_PER_US]
    mov tsc_us, rax
    lea rsi, [rdi + SB_ARGS]            ; the arguments, kept (at most 255 bytes)
    lea rdx, args
    mov ecx, 255
copy_args:
    mov al, BYTE PTR [rsi]
    mov BYTE PTR [rdx], al
    test al, al
    jz args_kept
    inc rsi
    inc rdx
    loop copy_args
    mov BYTE PTR [rdx], 0
args_kept:

    mov eax, SYS_MEM_NEW                ; the io block
    mov edi, 4096
    syscall
    test rax, rax
    js fail
    mov io_h, eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js fail
    mov io_va, rax

    mov rdi, io_va                      ; mhello: args [...]
    lea rsi, s_args
    call put_str
    lea rsi, args
    call put_str
    lea rsi, s_close
    call put_str
    call say

    rdtsc                               ; 50 ms, by RO_TIMEOUT's deadline
    shl rdx, 32
    or rax, rdx
    mov rbx, rax                        ; RBX: when it began
    imul rcx, tsc_us, 50000
    add rax, rcx
    push rax
    call clear_sqe
    pop rax
    mov BYTE PTR sqe[SQ_OP], RO_TIMEOUT
    mov QWORD PTR sqe[SQ_DEADLINE], rax
    call ring_call
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, rbx
    xor edx, edx
    div tsc_us                          ; microseconds
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rbx, rax
    mov rdi, io_va
    lea rsi, s_slept
    call put_str
    mov rax, rbx
    call put_dec
    lea rsi, s_ms
    call put_str
    call say

    mov eax, SYS_MEM_NEW                ; a thread, on a stack of its own
    mov edi, 65536
    syscall
    test rax, rax
    js fail
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js fail
    lea rsi, [rax + 65536]              ; its RSP: the top, 16-aligned
    lea rdi, worker
    mov edx, 21                         ; its RDI
    mov eax, SYS_THREAD_NEW
    syscall
    test rax, rax
    js fail
    push rax
    call clear_sqe
    pop rax
    mov BYTE PTR sqe[SQ_OP], RO_JOIN    ; once it ends: what it returned
    mov DWORD PTR sqe[SQ_HANDLE], eax
    call ring_call
    mov rbx, rdx
    mov rdi, io_va
    lea rsi, s_thread
    call put_str
    mov rax, rbx
    call put_dec
    lea rsi, s_nl
    call put_str
    call say

    cmp desk_h, 0
    jne window
    mov rdi, io_va
    lea rsi, s_nodesk
    call put_str
    call say
    jmp bye
window:
    mov eax, SYS_CHANNEL_NEW            ; RAX: the end the window takes, RDX: ours
    syscall
    test rax, rax
    js fail
    mov end_h, edx
    mov r10, rax
    mov edi, desk_h
    mov esi, WIN_W
    mov edx, WIN_H
    mov r8d, WNF_KEYS                   ; keys down and up too
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js fail
    mov win_h, eax
    mov edi, edx                        ; its pixels, mapped
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js fail
    mov rdi, rax                        ; WIN_W a row: it cannot be resized
    mov eax, COLOR
    mov ecx, WIN_W * WIN_H
    rep stosd

    mov rdi, io_va                      ; its title
    lea rsi, s_title
    call put_str
    mov rbx, rdi
    sub rbx, io_va
    call clear_sqe
    mov BYTE PTR sqe[SQ_OP], RO_WIN_TITLE
    mov eax, win_h
    mov DWORD PTR sqe[SQ_HANDLE], eax
    mov eax, io_h
    mov DWORD PTR sqe[SQ_HANDLE2], eax
    mov QWORD PTR sqe[SQ_A1], rbx
    call ring_call
    call clear_sqe                      ; what was drawn, shown (all of it)
    mov BYTE PTR sqe[SQ_OP], RO_WIN_SHOW
    mov eax, win_h
    mov DWORD PTR sqe[SQ_HANDLE], eax
    call ring_call
    mov rdi, io_va
    lea rsi, s_open
    call put_str
    call say

events:                                 ; once a message waits, take it
    call clear_sqe
    mov BYTE PTR sqe[SQ_OP], RO_WAIT
    mov eax, end_h
    mov DWORD PTR sqe[SQ_HANDLE], eax
    call ring_call
    test rax, rax
    js bye
    call clear_sqe
    mov BYTE PTR sqe[SQ_OP], RO_RECV
    mov eax, end_h
    mov DWORD PTR sqe[SQ_HANDLE], eax
    mov eax, io_h
    mov DWORD PTR sqe[SQ_HANDLE2], eax
    mov QWORD PTR sqe[SQ_A0], RECV_AT
    mov QWORD PTR sqe[SQ_A1], WE_SIZE
    call ring_call
    cmp rax, E_EMPTY
    je events
    test rax, rax
    js bye
    mov rsi, io_va
    add rsi, RECV_AT
    mov eax, DWORD PTR [rsi + WE_KIND]
    mov ebx, DWORD PTR [rsi + WE_CODE]
    cmp eax, WE_CLOSE
    je bye
    cmp eax, WE_KEY
    je key
    cmp eax, WE_KEYDOWN
    je down
    cmp eax, WE_KEYUP
    je up
    jmp events
key:
    mov rdi, io_va                      ; mhello: key 97
    lea rsi, s_key
    call put_str
    mov eax, ebx
    call put_dec
    lea rsi, s_nl
    call put_str
    call say
    cmp ebx, 'q'
    je bye
    jmp events
down:
    lea rsi, s_down
    jmp usage
up:
    lea rsi, s_up
usage:
    mov rdi, io_va                      ; mhello: down 0x04
    call put_str
    mov eax, ebx
    call put_hex2
    lea rsi, s_nl
    call put_str
    call say
    jmp events

bye:
    mov rdi, io_va
    lea rsi, s_bye
    call put_str
    call say
    xor edi, edi                        ; exit 0: the task ends with its first thread
    mov eax, SYS_EXIT
    syscall
fail:
    mov rdi, rax                        ; an E_*, as the exit code
    mov eax, SYS_EXIT
    syscall
start ENDP

; The second thread: RDI = what it was started with -> twice it.
worker PROC
    lea rdi, [rdi + rdi]
    mov eax, SYS_EXIT
    syscall
worker ENDP

; ring_call: sqe submitted, and waited for -> RAX = its result, RDX = its
; value. Loses RCX, R8-R11.
ring_call PROC
    push rsi
    push rdi
    mov r8, ring_va
    mov eax, DWORD PTR [r8 + RA_SQ_TAIL]   ; its slot: SQ_OFF + (tail & (n - 1)) * 64
    mov ecx, DWORD PTR [r8 + RA_SQ_ENTRIES]
    dec ecx
    and ecx, eax
    shl ecx, 6
    mov edx, DWORD PTR [r8 + RA_SQ_OFF]
    add rcx, rdx
    lea rdi, [r8 + rcx]
    lea rsi, sqe
    mov ecx, SQ_SIZE / 8
    rep movsq
    inc eax                             ; then the tail (x86 keeps the order)
    mov DWORD PTR [r8 + RA_SQ_TAIL], eax
    mov eax, SYS_RING_ENTER             ; one taken, one waited for
    mov edi, ring_h
    mov esi, 1
    mov edx, 1
    xor r10d, r10d
    syscall
reap:
    mov r8, ring_va
    mov eax, DWORD PTR [r8 + RA_CQ_HEAD]
    cmp eax, DWORD PTR [r8 + RA_CQ_TAIL]
    jne reaped
    mov eax, SYS_RING_ENTER             ; none yet: wait for one
    mov edi, ring_h
    xor esi, esi
    mov edx, 1
    xor r10d, r10d
    syscall
    jmp reap
reaped:
    mov ecx, DWORD PTR [r8 + RA_CQ_ENTRIES]
    dec ecx
    and ecx, eax
    shl ecx, 5
    mov edx, DWORD PTR [r8 + RA_CQ_OFF]
    add rcx, rdx
    add rcx, r8
    inc eax
    mov rdx, QWORD PTR [rcx + CQ_VALUE]
    mov rcx, QWORD PTR [rcx + CQ_RESULT]   ; read before the head moves past it
    mov DWORD PTR [r8 + RA_CQ_HEAD], eax
    mov rax, rcx
    pop rdi
    pop rsi
    ret
ring_call ENDP

; clear_sqe: a request of zeroes to begin with. Loses RAX.
clear_sqe PROC
    push rdi
    push rcx
    lea rdi, sqe
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    pop rdi
    ret
clear_sqe ENDP

; say: the io block, from its start to RDI, to the console. Loses RAX,
; RCX, RDX, R8-R11.
say PROC
    mov rax, rdi
    sub rax, io_va
    push rax
    call clear_sqe
    pop rax
    mov BYTE PTR sqe[SQ_OP], RO_WRITE
    mov ecx, con_h
    mov DWORD PTR sqe[SQ_HANDLE], ecx
    mov ecx, io_h
    mov DWORD PTR sqe[SQ_HANDLE2], ecx
    mov QWORD PTR sqe[SQ_A1], rax
    jmp ring_call
say ENDP

; put_str: RSI = a NUL-ended string, to RDI -> RDI past it. Loses RAX.
put_str PROC
next_char:
    lodsb
    test al, al
    jz put_done
    stosb
    jmp next_char
put_done:
    ret
put_str ENDP

; put_dec: RAX in decimal, to RDI -> RDI past it. Loses RAX.
put_dec PROC
    push rbx
    push rcx
    push rdx
    mov ebx, 10
    xor ecx, ecx
divide:
    xor edx, edx
    div rbx
    add dl, '0'
    push rdx
    inc ecx
    test rax, rax
    jnz divide
digits:
    pop rax
    stosb
    loop digits
    pop rdx
    pop rcx
    pop rbx
    ret
put_dec ENDP

; put_hex2: AL as two hex digits, to RDI -> RDI past them. Loses RAX.
put_hex2 PROC
    push rbx
    lea rbx, hex
    movzx eax, al
    push rax
    shr eax, 4
    mov al, BYTE PTR [rbx + rax]
    stosb
    pop rax
    and eax, 15
    mov al, BYTE PTR [rbx + rax]
    stosb
    pop rbx
    ret
put_hex2 ENDP

END
