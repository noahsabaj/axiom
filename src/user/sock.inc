; =============================================================================
;  sock.inc - a program's sockets, through its ring (net.asm, browse.asm)
;
;  The includer defines CHUNK (bytes through the io page at a time, a page
;  at most) and WAIT_US (how long a wait may take, microseconds).
;    op(ESI = RO_*, EDI = handle, EDX = handle2, RCX = a0, R8 = a1,
;      R9 = a2, R10 = deadline) -> RAX; simple(ESI = RO_*, EDI, RCX = a0)
;    connect(EDI = a network handle, RSI = host, EDX = port, ECX = NETF_*)
;      -> RAX = a socket; wait_on(EDI = a socket, ESI = 0 receive / 1 send,
;      RDX = microseconds or 0); status(EDI) -> SKS_* | NETW_* << 8
;    send_all(EDI, RSI = bytes, RDX = how many) -> 0 or E_*;
;      recv_wait(EDI, RSI = to, EDX = room) -> bytes, or E_* (E_PEER: the end)
; =============================================================================

; op(ESI = RO_*, EDI = handle, EDX = handle2, RCX = a0, R8 = a1, R9 = a2,
; R10 = deadline or 0) -> RAX = its result
op:
    sub rsp, SQ_SIZE
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    mov [rsp + 32], rax
    mov [rsp + 40], rax
    mov [rsp + 48], rax
    mov [rsp + 56], rax
    mov [rsp + SQ_OP], sil
    mov [rsp + SQ_HANDLE], edi
    mov [rsp + SQ_HANDLE2], edx
    mov [rsp + SQ_A0], rcx
    mov [rsp + SQ_A1], r8
    mov [rsp + SQ_A2], r9
    mov [rsp + SQ_DEADLINE], r10
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    ret

; host_at(RSI = NUL-ended): into the io page's first 256 bytes, zeros after.
; Preserves RSI.
host_at:
    push rsi
    mov rdi, [ax_io_va]
    xor eax, eax
    mov ecx, 256 / 8
    rep stosq
    mov rdi, [ax_io_va]
    mov ecx, 255
.copy:
    lodsb
    test al, al
    jz .out
    stosb
    dec ecx
    jnz .copy
.out:
    pop rsi
    ret

; connect(EDI = a network handle, RSI = host, EDX = port, ECX = NETF_*) ->
; RAX = a socket's handle
connect:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, edx
    mov r13d, ecx
    call host_at
    mov edi, ebx
    mov esi, RO_NET_CONNECT
    mov edx, [ax_io]
    xor ecx, ecx
    mov r8d, r12d
    mov r9d, r13d
    xor r10d, r10d
    call op
    pop r13
    pop r12
    pop rbx
    ret

; simple(ESI = RO_*, EDI = handle, RCX = a0) -> RAX
simple:
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    jmp op

; wait_on(EDI = a socket, ESI = 0 to receive, 1 to send, RDX = microseconds,
; 0 for ever) -> RAX
wait_on:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, esi
    xor r13d, r13d
    test rdx, rdx
    jz .go
    mov rdi, rdx
    call ax_us
    mov r13, rax
    call ax_now
    add r13, rax
.go:
    mov edi, ebx
    mov esi, RO_WAIT
    xor edx, edx
    mov ecx, r12d
    xor r8d, r8d
    xor r9d, r9d
    mov r10, r13
    call op
    pop r13
    pop r12
    pop rbx
    ret

; send_io(EDI = a socket, EDX = bytes in the io page) -> RAX
send_io:
    mov esi, RO_SEND
    mov r8d, edx
    mov edx, [ax_io]
    xor ecx, ecx
    xor r9d, r9d
    xor r10d, r10d
    jmp op

; recv_io(EDI = a socket, EDX = room) -> RAX: into the io page
recv_io:
    mov esi, RO_RECV
    mov r8d, edx
    mov edx, [ax_io]
    xor ecx, ecx
    xor r9d, r9d
    xor r10d, r10d
    jmp op

; send_all(EDI = a socket, RSI = bytes, RDX = how many) -> RAX = 0, or E_*:
; all of it, waiting for room as it must
send_all:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
.more:
    xor eax, eax
    test r13, r13
    jz .out
    mov r14, r13
    cmp r14, CHUNK
    jbe .chunk
    mov r14d, CHUNK
.chunk:
    mov rdi, [ax_io_va]
    mov rsi, r12
    mov rcx, r14
    rep movsb
.again:
    mov edi, ebx
    mov edx, r14d
    call send_io
    cmp rax, E_FULL
    je .wait
    test rax, rax
    js .out
    add r12, rax                        ; what it took; the rest again
    sub r13, rax
    jmp .more
.wait:
    mov edi, ebx
    mov esi, 1
    mov edx, WAIT_US
    call wait_on
    test rax, rax
    js .out
    jmp .again
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; recv_wait(EDI = a socket, RSI = to, EDX = room, a page at most) -> RAX =
; bytes, once some came, or E_* (E_PEER: the end)
recv_wait:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12, rsi
    mov r13d, edx
.again:
    mov edi, ebx
    mov edx, r13d
    call recv_io
    cmp rax, E_EMPTY
    jne .got
    mov edi, ebx
    xor esi, esi
    mov edx, WAIT_US
    call wait_on
    test rax, rax
    js .out
    jmp .again
.got:
    test rax, rax
    jle .out
    mov rsi, [ax_io_va]
    mov rdi, r12
    mov rcx, rax
    rep movsb
.out:
    pop r13
    pop r12
    pop rbx
    ret

; status(EDI = a socket) -> RAX = RO_NET_STATUS's
status:
    mov esi, RO_NET_STATUS
    xor ecx, ecx
    jmp simple
