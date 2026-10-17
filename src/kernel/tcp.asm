; =============================================================================
;  tcp.asm - TCP. A few connections at once, each opened by something in
;  the kernel (http.asm, socket.asm) that hears about it through a table of
;  four handlers, or accepted on a port it listens on. Retransmission on a
;  timer (RFC 6298: Jacobson's estimate, Karn's rule, backing off), fast
;  retransmit after three duplicate ACKs, slow start and congestion
;  avoidance (RFC 5681), and NewReno's partial ACKs during the recovery
;  (RFC 6582). What arrives in order goes straight to the handler; anything
;  after a gap is dropped and the ACK says what is missing, so the sender
;  fills it in.
;
;    tcp_connect(EDI = address, ESI = port, RDX = handlers) -> RAX = the
;        connection, CF if none is free or there is no route
;    tcp_listen(EDI = port, RSI = handlers for what it accepts, RDX =
;        accept, RCX = the owner's) -> RAX = the listener, CF if the port is
;        taken or no listener is free
;    tcp_unlisten(RDI = listener): no more; those half open go too
;    tcp_write, tcp_room, tcp_close, tcp_abort (RDI = connection), as below
;    tcp_flow(RDI = connection, ESI = bytes, 1 to 65535): from now on the
;        window offered is that, less what has been handed over and not yet
;        consumed; tcp_consumed(RDI, ESI = bytes) says some was, and an ACK
;        tells the other side when the window has opened enough. Without
;        tcp_flow every byte is taken as it comes (a fixed window).
;
;  TC_USER is the owner's. accept(RDI = the connection, established, RSI =
;  the listener) -> CF to refuse it (it is reset); else it may set TC_USER,
;  and TH_OPEN follows on the listener's handlers. A connection half open
;  (SYN_RCVD) has no handlers yet, and is forgotten without a word if its
;  handshake never ends. Main loop only.
;
;  Registers by convention: R12 = connection.
; =============================================================================

MAX_TCP         equ 16
MAX_LISTEN      equ 8
LISTEN_HALF     equ 8                   ; half-open connections a listener may have
TCP_SBUF        equ 131072              ; what one connection can have unacknowledged
TCP_WINDOW      equ 64240               ; what we offer: handlers take everything
TCP_MSS         equ 1460
TCP_RETRIES     equ 8
TCP_WAIT_S      equ 10                  ; TIME_WAIT, and how long FIN_WAIT_2 may last

; connection states
TS_CLOSED       equ 0
TS_SYN_SENT     equ 1
TS_ESTABLISHED  equ 2
TS_FIN_WAIT1    equ 3
TS_FIN_WAIT2    equ 4
TS_CLOSE_WAIT   equ 5
TS_CLOSING      equ 6
TS_LAST_ACK     equ 7
TS_TIME_WAIT    equ 8
TS_SYN_RCVD     equ 9                   ; a SYN came to a listener; SYN+ACK sent

; header flags
TCP_FIN         equ 0x01
TCP_SYN         equ 0x02
TCP_RST         equ 0x04
TCP_PSH         equ 0x08
TCP_ACK         equ 0x10

; TC_FLAGS
TF_CLOSE        equ 1                   ; the handler is done: a FIN follows the data
TF_FINSENT      equ 2                   ; TC_NXT covers our FIN
TF_ACKNOW       equ 4                   ; something arrived that wants an ACK
TF_RECOVERY     equ 8                   ; fast recovery, until TC_RECOVER is acked

; the handlers: RDI = connection; they may change RAX, RCX, RDX, RSI, RDI, R8-R11
TH_OPEN         equ 0                   ; connected
TH_DATA         equ 8                   ; RSI = data, EDX = bytes, in order
TH_FIN          equ 16                  ; the other side has finished sending
TH_GONE         equ 24                  ; ESI = why (below); the connection is no more

TCP_DONE        equ 0
TCP_REFUSED     equ 1
TCP_RESET       equ 2
TCP_TIMEOUT     equ 3

; a connection
TC_STATE        equ 0
TC_RIP          equ 4                   ; the other side, as it travels
TC_LPORT        equ 8                   ; ports, as numbers
TC_RPORT        equ 12
TC_ISS          equ 16                  ; our first sequence number
TC_UNA          equ 20                  ; the oldest one not acknowledged
TC_NXT          equ 24                  ; the next one to send
TC_WND          equ 28                  ; the window they offer
TC_RCV          equ 32                  ; the next one we expect
TC_MSS          equ 36                  ; the largest segment they take
TC_FLAGS        equ 40
TC_RETRIES      equ 44
TC_RTO          equ 48                  ; TSC ticks
TC_RTX_AT       equ 56                  ; TSC: resend, probe, or (waiting) forget
TC_SRTT         equ 64
TC_RTTVAR       equ 72
TC_RTT_AT       equ 80                  ; TSC when the timed segment left, 0 = none
TC_RTT_SEQ      equ 88                  ; an ACK this far ends the timing
TC_SLEN         equ 92                  ; bytes in the send buffer, from TC_UNA on
TC_OPS          equ 96                  ; the handlers
TC_SBUF         equ 104                 ; the send buffer
TC_CWND         equ 112                 ; congestion window, bytes
TC_SSTH         equ 116                 ; slow start threshold
TC_DUPS         equ 120                 ; duplicate ACKs in a row
TC_INDEX        equ 124
TC_RXBY         equ 128                 ; bytes received
TC_TXBY         equ 136                 ; bytes acknowledged
TC_RECOVER      equ 144                 ; TC_NXT when fast recovery began
TC_USER         equ 152                 ; the owner's
TC_HELD         equ 160                 ; dword: handed over, not yet consumed
TC_RLIMIT       equ 164                 ; dword: tcp_flow's, 0 = none
TC_ADV          equ 168                 ; dword: the window last offered
TC_LISTENER     equ 176                 ; what accepted it, or will
TC_MAX          equ 184                 ; dword: past the furthest ever sent
TC_SIZE         equ 256

; a listener
LS_PORT         equ 0                   ; dword, 0 = free
LS_HALF         equ 4                   ; dword: connections half open
LS_OPS          equ 8                   ; the handlers its connections get
LS_ACCEPT       equ 16
LS_USER         equ 24                  ; the owner's
LS_ACCEPTED     equ 32                  ; qword: how many
LS_SIZE         equ 40

section .text

; tcp_connect(EDI = address, ESI = port, RDX = handlers) -> RAX = the
; connection, CF if none is free or there is no route. Preserves others.
tcp_connect:
    push r12
    call tcp_slot
    jc .fail
    mov [r12 + TC_RIP], edi
    mov [r12 + TC_RPORT], esi
    mov [r12 + TC_OPS], rdx
    call tcp_port
    mov [r12 + TC_LPORT], eax
    call net_random
    mov [r12 + TC_ISS], eax
    mov [r12 + TC_UNA], eax
    inc eax
    mov [r12 + TC_NXT], eax
    mov [r12 + TC_MAX], eax
    mov dword [r12 + TC_MSS], 536
    mov rax, [net_second]
    mov [r12 + TC_RTO], rax
    mov dword [r12 + TC_STATE], TS_SYN_SENT
    call tcp_send_syn
    jc .no_route
    mov rax, r12
    clc
    jmp .out
.no_route:
    mov dword [r12 + TC_STATE], TS_CLOSED
    mov qword [r12 + TC_RTX_AT], 0
    call tcp_arm
.fail:
    stc
.out:
    pop r12
    ret

; tcp_write(RDI = connection, RSI = data, EDX = bytes) -> EAX = bytes taken
; (as many as the send buffer has room for). Preserves others.
tcp_write:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    xor eax, eax
    test dword [r12 + TC_FLAGS], TF_CLOSE
    jnz .out
    mov ecx, [r12 + TC_STATE]
    cmp ecx, TS_SYN_SENT
    je .take
    cmp ecx, TS_ESTABLISHED
    je .take
    cmp ecx, TS_CLOSE_WAIT
    jne .out
.take:
    mov ecx, TCP_SBUF
    sub ecx, [r12 + TC_SLEN]
    cmp edx, ecx
    cmova edx, ecx
    mov rdi, [r12 + TC_SBUF]
    mov eax, [r12 + TC_SLEN]
    add rdi, rax
    mov ecx, edx
    rep movsb
    add [r12 + TC_SLEN], edx
    cmp dword [r12 + TC_STATE], TS_SYN_SENT
    je .taken
    call tcp_output
.taken:
    mov eax, edx
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; tcp_room(RDI = connection) -> EAX = the bytes tcp_write would take now.
; Preserves others.
tcp_room:
    xor eax, eax
    test dword [rdi + TC_FLAGS], TF_CLOSE
    jnz .out
    cmp dword [rdi + TC_STATE], TS_SYN_SENT
    je .room
    cmp dword [rdi + TC_STATE], TS_ESTABLISHED
    je .room
    cmp dword [rdi + TC_STATE], TS_CLOSE_WAIT
    jne .out
.room:
    mov eax, TCP_SBUF
    sub eax, [rdi + TC_SLEN]
.out:
    ret

; tcp_close(RDI = connection): nothing more to send; a FIN follows the data.
; The handlers still hear the rest, then TH_GONE. Preserves all but RAX.
tcp_close:
    push rsi
    push r12
    mov r12, rdi
    cmp dword [r12 + TC_STATE], TS_SYN_SENT
    jne .synced
    mov qword [r12 + TC_OPS], 0         ; not connected yet: just forget it
    xor esi, esi
    call tcp_free
    jmp .out
.synced:
    or dword [r12 + TC_FLAGS], TF_CLOSE
    call tcp_output
.out:
    pop r12
    pop rsi
    ret

; tcp_abort(RDI = connection): a reset, and it is forgotten at once, without
; TH_GONE. Preserves all but RAX.
tcp_abort:
    push rcx
    push rdx
    push rsi
    push r12
    mov r12, rdi
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_ESTABLISHED
    jb .forget
    cmp eax, TS_TIME_WAIT
    je .forget
    mov eax, [r12 + TC_NXT]
    mov edx, TCP_RST
    xor ecx, ecx
    call tcp_segment
.forget:
    mov qword [r12 + TC_OPS], 0
    xor esi, esi
    call tcp_free
    pop r12
    pop rsi
    pop rdx
    pop rcx
    ret

tcp_listen:
    push r8
    push r9
    push r10
    xor r8d, r8d                        ; a free listener
    lea r9, [tcp_listeners]
    mov r10d, MAX_LISTEN
.scan:
    mov eax, [r9 + LS_PORT]
    test eax, eax
    jnz .used
    test r8, r8
    jnz .next
    mov r8, r9
    jmp .next
.used:
    cmp eax, edi
    je .refused                         ; someone listens there already
.next:
    add r9, LS_SIZE
    dec r10d
    jnz .scan
    test r8, r8
    jz .refused
    test edi, edi
    jz .refused
    cmp edi, 65535
    ja .refused
    mov [r8 + LS_PORT], edi
    mov dword [r8 + LS_HALF], 0
    mov [r8 + LS_OPS], rsi
    mov [r8 + LS_ACCEPT], rdx
    mov [r8 + LS_USER], rcx
    mov qword [r8 + LS_ACCEPTED], 0
    mov rax, r8
    clc
    jmp .out
.refused:
    stc
.out:
    pop r10
    pop r9
    pop r8
    ret

tcp_unlisten:
    push rcx
    push r12
    mov dword [rdi + LS_PORT], 0
    xor ecx, ecx
.next:
    cmp ecx, MAX_TCP
    jae .out
    imul r12, rcx, TC_SIZE
    lea rax, [tcp_conns]
    add r12, rax
    inc ecx
    cmp [r12 + TC_LISTENER], rdi
    jne .next
    cmp dword [r12 + TC_STATE], TS_SYN_RCVD
    jne .next
    push rdi
    mov rdi, r12
    call tcp_abort
    pop rdi
    jmp .next
.out:
    pop r12
    pop rcx
    ret

tcp_flow:
    push rax
    cmp esi, 65535
    jbe .set
    mov esi, 65535
.set:
    mov [rdi + TC_RLIMIT], esi
    pop rax
    ret

tcp_consumed:
    push rax
    push rcx
    push r12
    mov r12, rdi
    mov eax, [r12 + TC_HELD]
    sub eax, esi
    jae .held
    xor eax, eax
.held:
    mov [r12 + TC_HELD], eax
    cmp dword [r12 + TC_RLIMIT], 0
    je .out
    mov eax, [r12 + TC_STATE]           ; still taking data?
    cmp eax, TS_ESTABLISHED
    je .open
    cmp eax, TS_FIN_WAIT1
    je .open
    cmp eax, TS_FIN_WAIT2
    jne .out
.open:
    call tcp_window                     ; worth saying? from under a segment,
    mov ecx, [r12 + TC_ADV]             ; or by half the limit
    cmp ecx, [r12 + TC_MSS]
    jae .half
    cmp eax, [r12 + TC_MSS]
    jae .say
.half:
    sub eax, ecx
    jbe .out
    mov ecx, [r12 + TC_RLIMIT]
    shr ecx, 1
    cmp eax, ecx
    jb .out
.say:
    or dword [r12 + TC_FLAGS], TF_ACKNOW
    call tcp_output
.out:
    pop r12
    pop rcx
    pop rax
    ret

; tcp_window(R12) -> EAX = the window to offer now. Preserves others.
tcp_window:
    mov eax, TCP_WINDOW
    cmp dword [r12 + TC_RLIMIT], 0
    je .out
    mov eax, [r12 + TC_RLIMIT]
    sub eax, [r12 + TC_HELD]
    jae .out
    xor eax, eax
.out:
    ret

; -----------------------------------------------------------------------------
;  Connections
; -----------------------------------------------------------------------------

; tcp_slot -> R12 = a connection, zeroed, with its index and send buffer: a
; free one, else one in TIME_WAIT. CF if all are busy. Preserves others.
tcp_slot:
    push rax
    push rcx
    push rdx
    push rdi
    xor ecx, ecx
    xor edx, edx
.next:
    cmp ecx, MAX_TCP
    jae .end
    imul r12, rcx, TC_SIZE
    lea rax, [tcp_conns]
    add r12, rax
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .take
    cmp dword [r12 + TC_STATE], TS_TIME_WAIT
    jne .skip
    test rdx, rdx
    jnz .skip
    mov rdx, r12
.skip:
    inc ecx
    jmp .next
.end:
    test rdx, rdx
    jz .none
    mov r12, rdx
    mov ecx, [r12 + TC_INDEX]
.take:
    push rcx
    mov rdi, r12
    mov ecx, TC_SIZE
    xor eax, eax
    rep stosb
    pop rcx
    mov [r12 + TC_INDEX], ecx
    imul rax, rcx, TCP_SBUF
    lea rdx, [tcp_sbufs]
    add rax, rdx
    mov [r12 + TC_SBUF], rax
    call tcp_arm
    clc
    jmp .out
.none:
    stc
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; tcp_port -> EAX = a port of our own that no connection uses. Preserves others.
tcp_port:
    push rcx
    push rdx
.again:
    call net_random
    and eax, 0x3FFF
    add eax, 49152
    xor ecx, ecx
.check:
    cmp ecx, MAX_TCP
    jae .out
    imul rdx, rcx, TC_SIZE
    inc ecx
    cmp dword [tcp_conns + rdx + TC_STATE], TS_CLOSED
    je .check
    cmp [tcp_conns + rdx + TC_LPORT], eax
    je .again
    jmp .check
.out:
    pop rdx
    pop rcx
    ret

; tcp_find -> R12 = the connection the segment in ts_* belongs to, CF if
; none. Preserves others.
tcp_find:
    push rax
    push rcx
    xor ecx, ecx
.next:
    cmp ecx, MAX_TCP
    jae .none
    imul r12, rcx, TC_SIZE
    lea rax, [tcp_conns]
    add r12, rax
    inc ecx
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .next
    mov eax, [ts_src]
    cmp [r12 + TC_RIP], eax
    jne .next
    mov eax, [ts_sport]
    cmp [r12 + TC_RPORT], eax
    jne .next
    mov eax, [ts_dport]
    cmp [r12 + TC_LPORT], eax
    jne .next
    clc
    jmp .out
.none:
    stc
.out:
    pop rcx
    pop rax
    ret

; tcp_free(R12, ESI = why): the connection is no more; its handlers hear
; TH_GONE (after it is free, so they may open another). Preserves all.
tcp_free:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call tcp_half_gone
    mov rcx, [r12 + TC_OPS]
    mov qword [r12 + TC_OPS], 0
    mov dword [r12 + TC_STATE], TS_CLOSED
    mov qword [r12 + TC_RTX_AT], 0
    call tcp_arm
    test rcx, rcx
    jz .out
    mov rdi, r12
    call [rcx + TH_GONE]
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; tcp_half_gone(R12): if it was half open, its listener has one fewer.
; Preserves all.
tcp_half_gone:
    cmp dword [r12 + TC_STATE], TS_SYN_RCVD
    jne .out
    push rax
    mov rax, [r12 + TC_LISTENER]
    test rax, rax
    jz .none
    dec dword [rax + LS_HALF]
.none:
    pop rax
    mov dword [r12 + TC_STATE], TS_CLOSED   ; (not twice)
.out:
    ret

; tcp_time_wait(R12): both sides are done. The connection lingers a while
; for a FIN sent again; its handlers hear TH_GONE now. Preserves all.
tcp_time_wait:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov dword [r12 + TC_STATE], TS_TIME_WAIT
    call net_clock
    mov rdx, [net_second]
    imul rdx, rdx, TCP_WAIT_S
    add rax, rdx
    mov [r12 + TC_RTX_AT], rax
    call tcp_arm
    mov rcx, [r12 + TC_OPS]
    mov qword [r12 + TC_OPS], 0
    test rcx, rcx
    jz .out
    mov rdi, r12
    xor esi, esi
    call [rcx + TH_GONE]
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; tcp_event(R12, EAX = TH_OPEN, TH_DATA or TH_FIN; RSI, EDX as that one
; wants). Preserves all.
tcp_event:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rcx, [r12 + TC_OPS]
    test rcx, rcx
    jz .out
    mov rdi, r12
    call [rcx + rax]
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Out
; -----------------------------------------------------------------------------

; tcp_segment(R12, EAX = sequence number, EDX = flags, RSI = data, ECX =
; bytes) -> CF if there is no route. A SYN carries our MSS. Preserves all
; but RAX.
tcp_segment:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea r8, [net_frame + NET_PAYLOAD]
    mov r9d, eax
    mov ebx, 20
    test dl, TCP_SYN
    jz .copy
    mov ebx, 24
    mov dword [r8 + 20], 0xB4050402     ; MSS 1460: kind 2, length 4, 05 B4
.copy:
    lea rdi, [r8 + rbx]
    push rcx
    rep movsb
    pop rcx
    add ecx, ebx                        ; the segment's bytes
    mov eax, [r12 + TC_LPORT]
    xchg al, ah
    mov [r8], ax
    mov eax, [r12 + TC_RPORT]
    xchg al, ah
    mov [r8 + 2], ax
    mov eax, r9d
    bswap eax
    mov [r8 + 4], eax
    mov eax, [r12 + TC_RCV]
    bswap eax
    mov [r8 + 8], eax
    lea eax, [ebx * 4]                  ; header length in dwords, high nibble
    mov [r8 + 12], al
    mov [r8 + 13], dl
    call tcp_window
    mov [r12 + TC_ADV], eax
    xchg al, ah
    mov [r8 + 14], ax
    mov dword [r8 + 16], 0              ; checksum, urgent pointer
    mov eax, [net_ip]                   ; the pseudo-header
    mov [tcp_ph], eax
    mov eax, [r12 + TC_RIP]
    mov [tcp_ph + 4], eax
    mov eax, ecx
    xchg al, ah
    movzx eax, ax
    add eax, 0x0600                     ; a zero byte, then 6
    lea rsi, [tcp_ph]
    push rcx
    mov ecx, 8
    call net_sum
    pop rcx
    mov rsi, r8
    call net_sum
    call net_fold
    mov [r8 + 16], ax
    mov edi, [r12 + TC_RIP]
    mov esi, 6
    call ip_send
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; tcp_send_syn(R12) -> CF if there is no route: a SYN, or for a connection
; half open a SYN+ACK. Timed unless it is sent again. Preserves all but RAX.
tcp_send_syn:
    push rcx
    push rdx
    mov eax, [r12 + TC_ISS]
    mov edx, TCP_SYN
    cmp dword [r12 + TC_STATE], TS_SYN_RCVD
    jne .flags
    mov edx, TCP_SYN | TCP_ACK
.flags:
    xor ecx, ecx
    call tcp_segment
    jc .out
    cmp dword [r12 + TC_RETRIES], 0
    jne .timer
    call net_clock
    mov [r12 + TC_RTT_AT], rax
    mov eax, [r12 + TC_ISS]
    inc eax
    mov [r12 + TC_RTT_SEQ], eax
.timer:
    call tcp_rearm
    clc
.out:
    pop rdx
    pop rcx
    ret

; tcp_output(R12): what the windows allow, then the FIN once the data is
; out, else an ACK if one is owed. Preserves all but RAX.
tcp_output:
    push rbx
    push rcx
    push rdx
    push rsi
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_ESTABLISHED
    jb .ack
    cmp eax, TS_TIME_WAIT
    je .ack
.more:
    test dword [r12 + TC_FLAGS], TF_FINSENT
    jnz .ack
    mov ebx, [r12 + TC_NXT]
    sub ebx, [r12 + TC_UNA]             ; in flight
    mov ecx, [r12 + TC_SLEN]
    sub ecx, ebx                        ; not sent yet
    jbe .fin
    mov eax, [r12 + TC_WND]
    cmp eax, [r12 + TC_CWND]
    cmova eax, [r12 + TC_CWND]
    sub eax, ebx
    jle .blocked
    cmp ecx, eax
    cmova ecx, eax
    cmp ecx, [r12 + TC_MSS]
    cmova ecx, [r12 + TC_MSS]
    mov rsi, [r12 + TC_SBUF]
    add rsi, rbx
    mov eax, [r12 + TC_NXT]
    mov edx, TCP_ACK | TCP_PSH
    call tcp_segment
    jc .out
    add [r12 + TC_NXT], ecx
    call tcp_sent
    and dword [r12 + TC_FLAGS], ~TF_ACKNOW
    call tcp_time_it
    call tcp_rtx_idle
    jmp .more
.fin:
    test dword [r12 + TC_FLAGS], TF_CLOSE
    jz .ack
    mov eax, [r12 + TC_NXT]
    mov edx, TCP_ACK | TCP_FIN
    xor ecx, ecx
    call tcp_segment
    jc .out
    inc dword [r12 + TC_NXT]
    call tcp_sent
    or dword [r12 + TC_FLAGS], TF_FINSENT
    and dword [r12 + TC_FLAGS], ~TF_ACKNOW
    mov eax, TS_FIN_WAIT1
    cmp dword [r12 + TC_STATE], TS_ESTABLISHED
    je .state
    mov eax, TS_LAST_ACK
    cmp dword [r12 + TC_STATE], TS_CLOSE_WAIT
    jne .fin_sent
.state:
    mov [r12 + TC_STATE], eax
.fin_sent:
    call tcp_rtx_idle
    jmp .ack
.blocked:
    test ebx, ebx                       ; a closed window, nothing in flight:
    jnz .ack
    call tcp_rtx_idle                   ; the timer probes it
.ack:
    test dword [r12 + TC_FLAGS], TF_ACKNOW
    jz .out
    and dword [r12 + TC_FLAGS], ~TF_ACKNOW
    mov eax, [r12 + TC_NXT]
    mov edx, TCP_ACK
    xor ecx, ecx
    call tcp_segment
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; tcp_sent(R12): TC_MAX moved up to TC_NXT, if that has passed it (going
; back to resend leaves it where it was). Preserves all but RAX.
tcp_sent:
    mov eax, [r12 + TC_NXT]
    sub eax, [r12 + TC_MAX]
    js .out
    mov eax, [r12 + TC_NXT]
    mov [r12 + TC_MAX], eax
.out:
    ret

; tcp_time_it(R12): time the segment just sent, unless one is being timed.
; Preserves all.
tcp_time_it:
    cmp qword [r12 + TC_RTT_AT], 0
    jne .out
    push rax
    call net_clock
    mov [r12 + TC_RTT_AT], rax
    mov eax, [r12 + TC_NXT]
    mov [r12 + TC_RTT_SEQ], eax
    pop rax
.out:
    ret

; tcp_fast_retransmit(R12): three duplicate ACKs: the oldest segment again,
; half the window, and recovery until what is out now is acknowledged.
; Preserves all but RAX.
tcp_fast_retransmit:
    call tcp_halve
    mov eax, [r12 + TC_SSTH]
    mov [r12 + TC_CWND], eax
    mov eax, [r12 + TC_NXT]
    mov [r12 + TC_RECOVER], eax
    or dword [r12 + TC_FLAGS], TF_RECOVERY
    ; fall through

; tcp_send_oldest(R12): the oldest unacknowledged segment, again, and the
; timer restarted. Preserves all but RAX.
tcp_send_oldest:
    push rcx
    push rdx
    push rsi
    mov qword [r12 + TC_RTT_AT], 0
    mov ecx, [r12 + TC_SLEN]
    cmp ecx, [r12 + TC_MSS]
    cmova ecx, [r12 + TC_MSS]
    test ecx, ecx
    jz .out                             ; only the FIN is out: the timer has it
    mov eax, [r12 + TC_UNA]
    mov edx, TCP_ACK | TCP_PSH
    mov rsi, [r12 + TC_SBUF]
    call tcp_segment
    call tcp_rearm
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; tcp_halve(R12): the slow start threshold, half of what is in flight but
; two segments at least. Preserves all but RAX.
tcp_halve:
    push rdx
    mov eax, [r12 + TC_NXT]
    sub eax, [r12 + TC_UNA]
    shr eax, 1
    mov edx, [r12 + TC_MSS]
    add edx, edx
    cmp eax, edx
    cmovb eax, edx
    mov [r12 + TC_SSTH], eax
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  Timers
; -----------------------------------------------------------------------------

; tcp_rearm(R12): the timer, a full RTO from now. Preserves all.
tcp_rearm:
    push rax
    call net_clock
    add rax, [r12 + TC_RTO]
    mov [r12 + TC_RTX_AT], rax
    call tcp_arm
    pop rax
    ret

; tcp_rtx_idle(R12): the timer, if it is not running. Preserves all.
tcp_rtx_idle:
    cmp qword [r12 + TC_RTX_AT], 0
    jne .out
    call tcp_rearm
.out:
    ret

; tcp_arm: tcp_next, the earliest timer of any connection. Preserves all.
tcp_arm:
    push rax
    push rcx
    push rdx
    xor eax, eax
    xor ecx, ecx
.next:
    imul rdx, rcx, TC_SIZE
    cmp dword [tcp_conns + rdx + TC_STATE], TS_CLOSED
    je .skip
    mov rdx, [tcp_conns + rdx + TC_RTX_AT]
    test rdx, rdx
    jz .skip
    test rax, rax
    jz .take
    cmp rdx, rax
    jae .skip
.take:
    mov rax, rdx
.skip:
    inc ecx
    cmp ecx, MAX_TCP
    jb .next
    mov [tcp_next], rax
    pop rdx
    pop rcx
    pop rax
    ret

; tcp_tick: from net_service, with net_now fresh
tcp_tick:
    mov rax, [tcp_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    push rcx
    push r12
    xor ecx, ecx
.next:
    imul r12, rcx, TC_SIZE
    lea rax, [tcp_conns]
    add r12, rax
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .skip
    mov rax, [r12 + TC_RTX_AT]
    test rax, rax
    jz .skip
    cmp rax, [net_now]
    ja .skip
    call tcp_timeout
.skip:
    inc ecx
    cmp ecx, MAX_TCP
    jb .next
    call tcp_arm
    pop r12
    pop rcx
.out:
    ret

; tcp_timeout(R12): its timer ran out. Send again from the oldest
; unacknowledged byte, with the timer doubled and the window down to one
; segment; give up after TCP_RETRIES. Preserves all but RAX.
tcp_timeout:
    push rcx
    push rdx
    push rsi
    mov qword [r12 + TC_RTX_AT], 0
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_TIME_WAIT
    je .forget
    cmp eax, TS_FIN_WAIT2
    je .forget
    inc dword [r12 + TC_RETRIES]
    cmp dword [r12 + TC_RETRIES], TCP_RETRIES
    ja .give_up
    mov rax, [r12 + TC_RTO]             ; back off
    add rax, rax
    mov rdx, [net_second]
    imul rdx, rdx, 60
    cmp rax, rdx
    cmova rax, rdx
    mov [r12 + TC_RTO], rax
    mov qword [r12 + TC_RTT_AT], 0      ; Karn: no sample from a segment sent twice
    mov dword [r12 + TC_DUPS], 0
    and dword [r12 + TC_FLAGS], ~TF_RECOVERY
    cmp dword [r12 + TC_STATE], TS_SYN_SENT
    je .syn
    cmp dword [r12 + TC_STATE], TS_SYN_RCVD
    jne .data
.syn:
    call tcp_send_syn
    jmp .out
.data:
    call tcp_halve
    mov eax, [r12 + TC_MSS]
    mov [r12 + TC_CWND], eax
    mov eax, [r12 + TC_UNA]             ; go back
    mov [r12 + TC_NXT], eax
    and dword [r12 + TC_FLAGS], ~TF_FINSENT
    cmp dword [r12 + TC_WND], 0
    jne .resend
    cmp dword [r12 + TC_SLEN], 0
    je .resend
    mov edx, TCP_ACK                    ; a closed window: one byte, to probe it
    mov rsi, [r12 + TC_SBUF]
    mov ecx, 1
    call tcp_segment
    inc dword [r12 + TC_NXT]
    call tcp_sent
    call tcp_rearm
    jmp .out
.resend:
    call tcp_output
    mov eax, [r12 + TC_NXT]
    cmp eax, [r12 + TC_UNA]
    je .out
    call tcp_rearm
    jmp .out
.give_up:
    mov esi, TCP_TIMEOUT
    call tcp_free
    jmp .out
.forget:
    xor esi, esi
    call tcp_free
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; tcp_rtt(R12, RAX = a round trip in TSC ticks): the smoothed estimate, its
; variation, and the RTO from them: 200 ms to 60 s. Preserves all but RAX.
tcp_rtt:
    push rcx
    push rdx
    mov rcx, [r12 + TC_SRTT]
    test rcx, rcx
    jnz .update
    mov [r12 + TC_SRTT], rax            ; the first sample
    shr rax, 1
    mov [r12 + TC_RTTVAR], rax
    jmp .rto
.update:
    mov rdx, rcx
    sub rdx, rax
    jns .abs
    neg rdx
.abs:
    mov rcx, [r12 + TC_RTTVAR]          ; RTTVAR = 3/4 RTTVAR + 1/4 |SRTT - R|
    push rax
    mov rax, rcx
    shr rax, 2
    sub rcx, rax
    shr rdx, 2
    add rcx, rdx
    mov [r12 + TC_RTTVAR], rcx
    pop rax
    mov rcx, [r12 + TC_SRTT]            ; SRTT = 7/8 SRTT + 1/8 R
    mov rdx, rcx
    shr rdx, 3
    sub rcx, rdx
    shr rax, 3
    add rcx, rax
    mov [r12 + TC_SRTT], rcx
.rto:
    mov rax, [r12 + TC_RTTVAR]
    shl rax, 2
    mov rdx, [tsc_per_ms]               ; the clock's granularity: 1 ms
    cmp rax, rdx
    cmovb rax, rdx
    add rax, [r12 + TC_SRTT]
    mov rdx, [tsc_per_ms]
    imul rdx, rdx, 200
    cmp rax, rdx
    cmovb rax, rdx
    mov rdx, [net_second]
    imul rdx, rdx, 60
    cmp rax, rdx
    cmova rax, rdx
    mov [r12 + TC_RTO], rax
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  In
; -----------------------------------------------------------------------------

; tcp_input(RBX, RDI = IP header, EDX = its bytes, ECX = the packet's bytes)
tcp_input:
    mov eax, [net_ip]
    test eax, eax
    jz .out
    cmp [rdi + 16], eax                 ; to us alone, never a broadcast
    jne .out
    lea rsi, [rdi + rdx]
    sub ecx, edx
    cmp ecx, 20
    jb .out
    call tcp_pseudo
    call net_sum
    call net_fold
    test eax, eax
    jnz .out
    movzx eax, byte [rsi + 12]          ; header length
    shr eax, 4
    shl eax, 2
    cmp eax, 20
    jb .out
    cmp eax, ecx
    ja .out
    lea rdx, [rsi + rax]
    mov [ts_data], rdx
    sub ecx, eax
    mov [ts_len], ecx
    call tcp_options
    movzx eax, byte [rsi + 13]
    mov [ts_flags], eax
    mov eax, [rsi + 4]
    bswap eax
    mov [ts_seq], eax
    mov eax, [rsi + 8]
    bswap eax
    mov [ts_ack], eax
    movzx eax, word [rsi + 14]
    xchg al, ah
    mov [ts_wnd], eax
    movzx eax, word [rsi]
    xchg al, ah
    mov [ts_sport], eax
    movzx eax, word [rsi + 2]
    xchg al, ah
    mov [ts_dport], eax
    mov eax, [rdi + 12]
    mov [ts_src], eax
    push r12
    call tcp_find
    jc .stray
    call tcp_arrive
    jmp .done
.stray:
    call tcp_passive
    jnc .done
    call tcp_refuse
.done:
    pop r12
.out:
    ret

; tcp_pseudo(RDI = IP header, ECX = TCP bytes) -> EAX = the pseudo-header's
; sum. Preserves others.
tcp_pseudo:
    push rcx
    push rsi
    mov eax, ecx
    xchg al, ah
    movzx eax, ax
    add eax, 0x0600
    lea rsi, [rdi + 12]
    mov ecx, 8
    call net_sum
    pop rsi
    pop rcx
    ret

; tcp_options(RSI = segment, EAX = header bytes): the MSS into ts_mss, 0 if
; it has none. Preserves all but RAX.
tcp_options:
    push rcx
    push rdx
    push rdi
    mov dword [ts_mss], 0
    lea rdi, [rsi + 20]
    lea rdx, [rsi + rax]                ; the end
.next:
    cmp rdi, rdx
    jae .out
    movzx eax, byte [rdi]
    test eax, eax                       ; end of the list
    jz .out
    cmp eax, 1                          ; padding
    jne .long
    inc rdi
    jmp .next
.long:
    lea rcx, [rdi + 1]
    cmp rcx, rdx
    jae .out
    movzx ecx, byte [rdi + 1]
    cmp ecx, 2
    jb .out
    push rax
    lea rax, [rdi + rcx]
    cmp rax, rdx
    pop rax
    ja .out
    cmp eax, 2
    jne .skip
    cmp ecx, 4
    jne .skip
    movzx eax, word [rdi + 2]
    xchg al, ah
    mov [ts_mss], eax
.skip:
    add rdi, rcx
    jmp .next
.out:
    pop rdi
    pop rdx
    pop rcx
    ret

; tcp_passive: a SYN for no connection, to a port listened on: a connection
; half open, SYN+ACK sent. CF if it is not that, or no room. Clobbers R12.
tcp_passive:
    push rcx
    push rdx
    push rsi
    mov eax, [ts_flags]
    and eax, TCP_SYN | TCP_ACK | TCP_RST | TCP_FIN
    cmp eax, TCP_SYN
    jne .no
    lea rsi, [tcp_listeners]
    mov ecx, MAX_LISTEN
    mov eax, [ts_dport]
.find:
    cmp [rsi + LS_PORT], eax
    je .found
    add rsi, LS_SIZE
    dec ecx
    jnz .find
    jmp .no
.found:
    cmp dword [rsi + LS_HALF], LISTEN_HALF
    jae .drop                           ; too many already: as if it was lost
    call tcp_slot
    jc .drop
    inc dword [rsi + LS_HALF]
    mov [r12 + TC_LISTENER], rsi
    mov eax, [ts_src]
    mov [r12 + TC_RIP], eax
    mov eax, [ts_sport]
    mov [r12 + TC_RPORT], eax
    mov eax, [ts_dport]
    mov [r12 + TC_LPORT], eax
    call net_random
    mov [r12 + TC_ISS], eax
    mov [r12 + TC_UNA], eax
    inc eax
    mov [r12 + TC_NXT], eax
    mov [r12 + TC_MAX], eax
    mov eax, [ts_seq]
    inc eax
    mov [r12 + TC_RCV], eax
    mov eax, [ts_wnd]
    mov [r12 + TC_WND], eax
    call tcp_their_mss
    mov rax, [net_second]
    mov [r12 + TC_RTO], rax
    mov dword [r12 + TC_STATE], TS_SYN_RCVD
    call tcp_send_syn                   ; (no route: the timer tries again)
.drop:
    clc                                 ; taken, or dropped: no reset
    jmp .out
.no:
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; tcp_their_mss(R12): the MSS the SYN in ts_* offered (536 without one),
; within 64 and ours; the congestion window from it. Preserves all but RAX.
tcp_their_mss:
    mov eax, [ts_mss]
    test eax, eax
    jnz .mss
    mov eax, 536                        ; the default without the option
.mss:
    cmp eax, TCP_MSS
    jbe .mss_max
    mov eax, TCP_MSS
.mss_max:
    cmp eax, 64
    jae .mss_min
    mov eax, 64
.mss_min:
    mov [r12 + TC_MSS], eax
    imul eax, eax, 10                   ; RFC 6928's initial window
    mov [r12 + TC_CWND], eax
    mov dword [r12 + TC_SSTH], 0x7FFFFFFF
    ret

; tcp_refuse: a segment for no connection gets a reset, unless it is one.
; Clobbers R12.
tcp_refuse:
    test byte [ts_flags], TCP_RST
    jnz .out
    lea r12, [tcp_scratch]
    mov eax, [ts_src]
    mov [r12 + TC_RIP], eax
    mov eax, [ts_sport]
    mov [r12 + TC_RPORT], eax
    mov eax, [ts_dport]
    mov [r12 + TC_LPORT], eax
    test byte [ts_flags], TCP_ACK
    jz .no_ack
    mov eax, [ts_ack]                   ; where it thinks we are
    mov edx, TCP_RST
    jmp .send
.no_ack:
    mov eax, [ts_seq]                   ; acknowledge all of it
    add eax, [ts_len]
    test byte [ts_flags], TCP_SYN
    jz .syn
    inc eax
.syn:
    test byte [ts_flags], TCP_FIN
    jz .fin
    inc eax
.fin:
    mov [r12 + TC_RCV], eax
    xor eax, eax
    mov edx, TCP_RST | TCP_ACK
.send:
    xor ecx, ecx
    call tcp_segment
.out:
    ret

; tcp_arrive(R12): the segment in ts_*, for this connection
tcp_arrive:
    cmp dword [r12 + TC_STATE], TS_SYN_RCVD
    je tcp_arrive_half
    cmp dword [r12 + TC_STATE], TS_SYN_SENT
    jne .synced
    test byte [ts_flags], TCP_ACK
    jz .drop                            ; no simultaneous open
    mov eax, [r12 + TC_ISS]
    inc eax
    cmp [ts_ack], eax
    jne tcp_refuse                      ; an ACK for something never sent
    test byte [ts_flags], TCP_RST
    jz .syn
    mov esi, TCP_REFUSED
    jmp tcp_free
.syn:
    test byte [ts_flags], TCP_SYN
    jz .drop
    mov eax, [ts_seq]
    inc eax
    mov [r12 + TC_RCV], eax
    mov eax, [ts_ack]
    mov [r12 + TC_UNA], eax
    mov eax, [ts_wnd]
    mov [r12 + TC_WND], eax
    call tcp_their_mss
    cmp qword [r12 + TC_RTT_AT], 0      ; the SYN's round trip
    je .no_rtt
    call net_clock
    sub rax, [r12 + TC_RTT_AT]
    call tcp_rtt
    mov qword [r12 + TC_RTT_AT], 0
.no_rtt:
    mov dword [r12 + TC_RETRIES], 0
    mov qword [r12 + TC_RTX_AT], 0
    call tcp_arm
    mov dword [r12 + TC_STATE], TS_ESTABLISHED
    or dword [r12 + TC_FLAGS], TF_ACKNOW
    mov eax, TH_OPEN
    call tcp_event
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .drop
    jmp tcp_output

.synced:
    test byte [ts_flags], TCP_RST
    jz .no_rst
    mov eax, [ts_seq]
    cmp eax, [r12 + TC_RCV]             ; exactly where we are, or ignored
    jne .drop
    mov esi, TCP_RESET
    jmp tcp_free
.no_rst:
    test byte [ts_flags], TCP_SYN
    jz .no_syn
    or dword [r12 + TC_FLAGS], TF_ACKNOW ; a SYN now: say where we are
    jmp tcp_output
.no_syn:
    test byte [ts_flags], TCP_ACK
    jz .drop

    mov eax, [ts_ack]                   ; the acknowledgment
    sub eax, [r12 + TC_UNA]
    jz .same
    js .data                            ; an old one
    mov edx, [ts_ack]
    sub edx, [r12 + TC_MAX]
    jg .too_new
    mov edx, [ts_ack]
    sub edx, [r12 + TC_NXT]
    jle .acked
    mov edx, [ts_ack]                   ; sent before going back to resend:
    mov [r12 + TC_NXT], edx             ; taken, so on from there
    sub edx, [r12 + TC_UNA]
    cmp edx, [r12 + TC_SLEN]
    jbe .acked
    or dword [r12 + TC_FLAGS], TF_FINSENT ; and past the data: our FIN
.acked:
    call tcp_acked
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .drop
    jmp .window
.too_new:
    or dword [r12 + TC_FLAGS], TF_ACKNOW ; for something not sent
    jmp tcp_output
.same:
    cmp dword [ts_len], 0               ; a duplicate?
    jne .window
    test byte [ts_flags], TCP_FIN
    jnz .window
    mov eax, [r12 + TC_NXT]
    cmp eax, [r12 + TC_UNA]
    je .window
    mov eax, [ts_wnd]
    cmp eax, [r12 + TC_WND]
    jne .window
    inc dword [r12 + TC_DUPS]
    cmp dword [r12 + TC_DUPS], 3
    jne .window
    test dword [r12 + TC_FLAGS], TF_RECOVERY
    jnz .window                         ; once per loss
    call tcp_fast_retransmit
.window:
    mov eax, [ts_wnd]
    cmp dword [r12 + TC_WND], 0
    mov [r12 + TC_WND], eax
    jne .data
    test eax, eax
    jz .data
    test dword [r12 + TC_FLAGS], TF_FINSENT
    jnz .data
    mov eax, [r12 + TC_NXT]             ; it opened with only a probe out: the
    sub eax, [r12 + TC_UNA]             ; probe was not taken, so go back now
    cmp eax, 1                          ; rather than when the timer runs out
    jne .data
    mov eax, [r12 + TC_UNA]
    mov [r12 + TC_NXT], eax

.data:                                  ; data and a FIN
    mov ecx, [ts_len]
    test byte [ts_flags], TCP_FIN
    jnz .incoming
    test ecx, ecx
    jz .respond
.incoming:
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_ESTABLISHED
    je .accept
    cmp eax, TS_FIN_WAIT1
    je .accept
    cmp eax, TS_FIN_WAIT2
    je .accept
    or dword [r12 + TC_FLAGS], TF_ACKNOW ; after their FIN: say where we are
    jmp .respond
.accept:
    mov eax, [r12 + TC_RCV]
    sub eax, [ts_seq]                   ; how much of it we have already
    js .resync                          ; a gap before it
    cmp eax, ecx
    ja .resync                          ; all of it, and its FIN
    mov rsi, [ts_data]
    add rsi, rax
    sub ecx, eax
    jz .fin
    cmp dword [r12 + TC_RLIMIT], 0      ; flow control: what the window holds
    je .take
    call tcp_window
    cmp ecx, eax
    jbe .held
    mov ecx, eax                        ; the rest, and a FIN after it, wait
    and dword [ts_flags], ~TCP_FIN
    or dword [r12 + TC_FLAGS], TF_ACKNOW
    test ecx, ecx
    jz .respond
.held:
    add [r12 + TC_HELD], ecx
.take:
    mov edx, ecx
    add [r12 + TC_RCV], ecx
    add [r12 + TC_RXBY], rcx
    or dword [r12 + TC_FLAGS], TF_ACKNOW
    mov eax, TH_DATA
    call tcp_event
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .drop
.fin:
    test byte [ts_flags], TCP_FIN
    jz .respond
    inc dword [r12 + TC_RCV]
    or dword [r12 + TC_FLAGS], TF_ACKNOW
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_ESTABLISHED
    jne .fin_wait
    mov dword [r12 + TC_STATE], TS_CLOSE_WAIT
    mov eax, TH_FIN
    call tcp_event
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .drop
    jmp .respond
.fin_wait:
    cmp eax, TS_FIN_WAIT1
    jne .both_done
    mov dword [r12 + TC_STATE], TS_CLOSING
    jmp .respond
.both_done:                             ; FIN_WAIT2
    call tcp_output
    jmp tcp_time_wait
.resync:
    or dword [r12 + TC_FLAGS], TF_ACKNOW
.respond:
    jmp tcp_output
.drop:
    ret

; tcp_arrive_half(R12): the segment, for a connection half open. Its
; handshake's last ACK makes it established and accepted; then whatever
; else the segment holds is taken as on any connection.
tcp_arrive_half:
    test byte [ts_flags], TCP_RST
    jz .no_rst
    mov eax, [ts_seq]
    cmp eax, [r12 + TC_RCV]
    jne .drop
    xor esi, esi
    jmp tcp_free                        ; (no handlers: no word)
.no_rst:
    test byte [ts_flags], TCP_SYN
    jz .no_syn
    mov eax, [ts_seq]                   ; their SYN again: ours again
    inc eax
    cmp eax, [r12 + TC_RCV]
    jne .drop
    jmp tcp_send_syn
.no_syn:
    test byte [ts_flags], TCP_ACK
    jz .drop
    mov eax, [r12 + TC_ISS]
    inc eax
    cmp [ts_ack], eax
    jne tcp_refuse                      ; an ACK for something never sent
    mov [r12 + TC_UNA], eax
    mov eax, [ts_wnd]
    mov [r12 + TC_WND], eax
    cmp qword [r12 + TC_RTT_AT], 0      ; the SYN+ACK's round trip
    je .no_rtt
    call net_clock
    sub rax, [r12 + TC_RTT_AT]
    call tcp_rtt
    mov qword [r12 + TC_RTT_AT], 0
.no_rtt:
    call tcp_half_gone                  ; (state CLOSED for a moment)
    mov dword [r12 + TC_RETRIES], 0
    mov qword [r12 + TC_RTX_AT], 0
    call tcp_arm
    mov dword [r12 + TC_STATE], TS_ESTABLISHED
    mov rsi, [r12 + TC_LISTENER]
    test rsi, rsi
    jz .refuse
    cmp dword [rsi + LS_PORT], 0        ; stopped listening meanwhile
    je .refuse
    mov rax, [rsi + LS_OPS]
    mov [r12 + TC_OPS], rax
    inc qword [rsi + LS_ACCEPTED]
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov rdi, r12
    call [rsi + LS_ACCEPT]
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    jc .refuse
    mov eax, TH_OPEN
    call tcp_event
    cmp dword [r12 + TC_STATE], TS_CLOSED
    je .drop
    jmp tcp_arrive                      ; the rest of the segment, established
.refuse:
    mov qword [r12 + TC_OPS], 0
    mov rdi, r12
    jmp tcp_abort
.drop:
    ret

; tcp_acked(R12, EAX = bytes newly acknowledged; the ACK in ts_ack): out of
; the send buffer, a round trip measured, the congestion window grown, the
; timer stopped or restarted, our FIN's fate. Preserves all but RAX.
tcp_acked:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, eax
    mov ecx, [r12 + TC_SLEN]            ; data acknowledged; any more was the FIN
    cmp ecx, edx
    cmova ecx, edx
    add [r12 + TC_TXBY], rcx
    push rcx
    mov rdi, [r12 + TC_SBUF]
    lea rsi, [rdi + rcx]
    mov eax, [r12 + TC_SLEN]
    sub eax, ecx
    mov [r12 + TC_SLEN], eax
    mov ecx, eax
    rep movsb
    pop rcx
    mov eax, [ts_ack]
    mov [r12 + TC_UNA], eax
    cmp qword [r12 + TC_RTT_AT], 0
    je .no_rtt
    mov eax, [ts_ack]
    sub eax, [r12 + TC_RTT_SEQ]
    js .no_rtt
    call net_clock
    sub rax, [r12 + TC_RTT_AT]
    call tcp_rtt
    mov qword [r12 + TC_RTT_AT], 0
.no_rtt:
    mov dword [r12 + TC_RETRIES], 0
    mov dword [r12 + TC_DUPS], 0
    mov eax, [r12 + TC_CWND]
    cmp eax, [r12 + TC_SSTH]
    jae .avoid
    mov esi, edx                        ; slow start: what was acked, a segment at most
    cmp esi, [r12 + TC_MSS]
    cmova esi, [r12 + TC_MSS]
    add eax, esi
    jmp .cwnd
.avoid:
    push rdx                            ; avoidance: about a segment per round trip
    mov esi, eax
    mov eax, [r12 + TC_MSS]
    imul eax, eax
    xor edx, edx
    div esi
    test eax, eax
    jnz .grow
    inc eax
.grow:
    add eax, esi
    pop rdx
.cwnd:
    cmp eax, 0x40000000
    jbe .cwnd_ok
    mov eax, 0x40000000
.cwnd_ok:
    mov [r12 + TC_CWND], eax
    test dword [r12 + TC_FLAGS], TF_RECOVERY
    jz .timer
    mov eax, [ts_ack]
    sub eax, [r12 + TC_RECOVER]
    js .partial
    and dword [r12 + TC_FLAGS], ~TF_RECOVERY ; all of it: recovered
    jmp .timer
.partial:
    call tcp_send_oldest                ; the next hole, at once
    jmp .our_fin
.timer:
    mov eax, [r12 + TC_NXT]
    cmp eax, [r12 + TC_UNA]
    jne .running
    mov qword [r12 + TC_RTX_AT], 0
    call tcp_arm
    jmp .our_fin
.running:
    call tcp_rearm
.our_fin:
    cmp edx, ecx
    jbe .out
    test dword [r12 + TC_FLAGS], TF_FINSENT
    jz .out
    mov eax, [r12 + TC_STATE]
    cmp eax, TS_FIN_WAIT1
    jne .closing
    mov dword [r12 + TC_STATE], TS_FIN_WAIT2
    call net_clock                      ; they have a while to finish too
    mov rdx, [net_second]
    imul rdx, rdx, TCP_WAIT_S
    add rax, rdx
    mov [r12 + TC_RTX_AT], rax
    call tcp_arm
    jmp .out
.closing:
    cmp eax, TS_CLOSING
    jne .last
    call tcp_time_wait
    jmp .out
.last:
    cmp eax, TS_LAST_ACK
    jne .out
    xor esi, esi
    call tcp_free
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Shell
; -----------------------------------------------------------------------------

; tcp [echo <port> | stop <port>]
cmd_tcp:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je tcp_list
    call arg_split
    push rdi                            ; the port's text
    lea rdi, [str_tcp_echo]
    call streq
    mov ecx, eax
    lea rdi, [str_tcp_stop]
    call streq
    pop rsi
    test ecx, ecx
    jnz .echo
    test eax, eax
    jnz .stop
.usage:
    KLOG "usage: tcp [echo <port> | stop <port>]"
    ret
.echo:
    call arg_uint
    jc .usage
    mov edi, eax
    lea rsi, [tcp_echo_ops]
    lea rdx, [tcp_echo_accept]
    xor ecx, ecx
    call tcp_listen
    jc .taken
    KLOG "tcp: echoing what comes to port %u", rdi
    ret
.taken:
    KLOG "tcp: cannot listen on port %u (taken, or no listener free)", rdi
    ret
.stop:
    call arg_uint
    jc .usage
    lea rdi, [tcp_listeners]
    mov ecx, MAX_LISTEN
.find:
    cmp [rdi + LS_PORT], eax
    je .found
    add rdi, LS_SIZE
    dec ecx
    jnz .find
    KLOG "tcp: nothing listens on port %u", rax
    ret
.found:
    mov ecx, eax
    call tcp_unlisten
    KLOG "tcp: port %u: no longer listening (%u accepted)", rcx, qword [rdi + LS_ACCEPTED]
    ret

; -----------------------------------------------------------------------------
;  tcp echo: what comes is sent back, through a 16 KiB window. Bytes are
;  consumed (the window opens) only once TCP's send buffer has them; the
;  rest waits in tcp_echo_buf, tried again after each round of the network.
; -----------------------------------------------------------------------------

TCP_ECHO_WIN    equ 16384

; tcp_echo_accept(RDI = a connection, RSI = the listener)
tcp_echo_accept:
    mov esi, TCP_ECHO_WIN
    call tcp_flow
    mov eax, [rdi + TC_INDEX]
    mov dword [tcp_echo_len + rax * 4], 0
    mov byte [tcp_echo_fin + rax], 0
    mov ecx, [rdi + TC_RPORT]
    mov edx, [rdi + TC_RIP]
    KLOG "tcp: echo: %I:%u connected", rdx, rcx
    clc
    ret

tcp_echo_open:
    ret

; RSI = data, EDX = bytes: behind what waits, then as much as goes out
tcp_echo_data:
    push rbx
    mov ebx, [rdi + TC_INDEX]
    imul rax, rbx, TCP_ECHO_WIN
    lea rcx, [tcp_echo_buf]
    add rax, rcx
    mov ecx, [tcp_echo_len + rbx * 4]
    push rdi
    lea rdi, [rax + rcx]
    add ecx, edx
    cmp ecx, TCP_ECHO_WIN               ; (the window keeps it within)
    ja .over
    mov [tcp_echo_len + rbx * 4], ecx
    mov ecx, edx
    rep movsb
    pop rdi
    call tcp_echo_flush
    pop rbx
    ret
.over:
    pop rdi
    KLOG "tcp: echo: more came than the window allows"
    call tcp_abort
    pop rbx
    ret

; tcp_echo_flush(RDI = a connection): what waits, into TCP's send buffer
tcp_echo_flush:
    push rbx
    push rcx
    push rdx
    push rsi
    mov ebx, [rdi + TC_INDEX]
    mov edx, [tcp_echo_len + rbx * 4]
    test edx, edx
    jz .fin
    imul rsi, rbx, TCP_ECHO_WIN
    lea rax, [tcp_echo_buf]
    add rsi, rax
    call tcp_write
    test eax, eax
    jz .out
    mov ecx, [tcp_echo_len + rbx * 4]   ; what is left, to the front
    sub ecx, eax
    mov [tcp_echo_len + rbx * 4], ecx
    push rdi
    mov rdi, rsi
    add rsi, rax
    rep movsb
    pop rdi
    mov esi, eax
    call tcp_consumed
    cmp dword [tcp_echo_len + rbx * 4], 0
    jne .out
.fin:
    cmp byte [tcp_echo_fin + rbx], 1    ; they are done, and so are we
    jne .out
    mov byte [tcp_echo_fin + rbx], 2
    call tcp_close
.out:
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

tcp_echo_eof:
    mov eax, [rdi + TC_INDEX]
    mov byte [tcp_echo_fin + rax], 1
    jmp tcp_echo_flush

tcp_echo_gone:
    mov eax, [rdi + TC_INDEX]
    mov dword [tcp_echo_len + rax * 4], 0
    mov byte [tcp_echo_fin + rax], 0
    mov ecx, [rdi + TC_RPORT]
    mov edx, [rdi + TC_RIP]
    KLOG "tcp: echo: %I:%u gone (%u): %b echoed", rdx, rcx, rsi, qword [rdi + TC_TXBY]
    ret

; tcp_echo_tick: from net_service, after the rest. Preserves all but RAX.
tcp_echo_tick:
    push rcx
    push rdi
    xor ecx, ecx
.next:
    imul rdi, rcx, TC_SIZE
    lea rax, [tcp_conns]
    add rdi, rax
    inc ecx
    cmp dword [tcp_echo_len + rcx * 4 - 4], 0
    je .skip
    lea rax, [tcp_echo_ops]
    cmp [rdi + TC_OPS], rax
    jne .skip
    call tcp_echo_flush
.skip:
    cmp ecx, MAX_TCP
    jb .next
    pop rdi
    pop rcx
    ret

tcp_list:
    push rbx
    push r12
    push r13
    xor ebx, ebx
    xor r13d, r13d
.next:
    cmp ebx, MAX_TCP
    jae .end
    imul r12, rbx, TC_SIZE
    lea rax, [tcp_conns]
    add r12, rax
    inc ebx
    mov eax, [r12 + TC_STATE]
    test eax, eax
    jz .next
    inc r13d
    mov rcx, [tcp_state_names + rax * 8]
    mov eax, [r12 + TC_LPORT]
    mov edx, [r12 + TC_RIP]
    mov esi, [r12 + TC_RPORT]
    mov rdi, [r12 + TC_SRTT]
    push rax
    push rdx
    mov rax, rdi
    xor edx, edx
    div qword [tsc_per_ms]
    mov rdi, rax
    pop rdx
    pop rax
    KLOG "tcp: port %u to %I:%u, %s, %b in, %b out, rtt %u ms", rax, rdx, rsi, rcx, qword [r12 + TC_RXBY], qword [r12 + TC_TXBY], rdi
    mov eax, [r12 + TC_RLIMIT]
    test eax, eax
    jz .next
    mov ecx, [r12 + TC_ADV]
    mov edx, [r12 + TC_HELD]
    KLOG "      window offered %u of %u, %u held", rcx, rax, rdx
    jmp .next
.end:
    lea r12, [tcp_listeners]
    mov ebx, MAX_LISTEN
.listener:
    mov eax, [r12 + LS_PORT]
    test eax, eax
    jz .no_listener
    inc r13d
    mov ecx, [r12 + LS_HALF]
    KLOG "tcp: listening on port %u: %u accepted, %u half open", rax, qword [r12 + LS_ACCEPTED], rcx
.no_listener:
    add r12, LS_SIZE
    dec ebx
    jnz .listener
    test r13d, r13d
    jnz .out
    KLOG "tcp: no connections"
.out:
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
str_ts_closed:      db 'closed', 0
str_ts_syn_sent:    db 'connecting', 0
str_ts_established: db 'established', 0
str_ts_fin_wait1:   db 'closing (FIN sent)', 0
str_ts_fin_wait2:   db 'closing (FIN acknowledged)', 0
str_ts_close_wait:  db 'they have closed', 0
str_ts_closing:     db 'closing (both FINs)', 0
str_ts_last_ack:    db 'closing (last ACK)', 0
str_ts_time_wait:   db 'time-wait', 0
str_ts_syn_rcvd:    db 'accepting', 0
str_tcp_echo:       db 'echo', 0
str_tcp_stop:       db 'stop', 0
align 8
tcp_echo_ops:       dq tcp_echo_open, tcp_echo_data, tcp_echo_eof, tcp_echo_gone
align 8
tcp_state_names:
    dq str_ts_closed, str_ts_syn_sent, str_ts_established, str_ts_fin_wait1
    dq str_ts_fin_wait2, str_ts_close_wait, str_ts_closing, str_ts_last_ack
    dq str_ts_time_wait, str_ts_syn_rcvd

section .bss
alignb 8
tcp_conns:      resb MAX_TCP * TC_SIZE
tcp_listeners:  resb MAX_LISTEN * LS_SIZE
tcp_echo_len:   resd MAX_TCP                ; bytes waiting to go back
tcp_echo_fin:   resb MAX_TCP                ; 1: they are done; 2: so are we
alignb 16
tcp_echo_buf:   resb MAX_TCP * TCP_ECHO_WIN
tcp_scratch:    resb TC_SIZE            ; for resets to segments of no connection
ts_data:        resq 1                  ; the segment being looked at
ts_seq:         resd 1
ts_ack:         resd 1
ts_wnd:         resd 1
ts_flags:       resd 1
ts_len:         resd 1
ts_src:         resd 1
ts_sport:       resd 1
ts_dport:       resd 1
ts_mss:         resd 1
tcp_ph:         resd 2                  ; pseudo-header addresses
tcp_sbufs:      resb MAX_TCP * TCP_SBUF
