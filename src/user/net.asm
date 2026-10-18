; =============================================================================
;  net.asm - a program on the network, through its capability (ax_net)
;
;    net get <host> <port> [tls|insecure] [text]
;        connects (TLS: the certificate checked; insecure: not), sends the
;        text ("\r" and "\n" in it as such), shuts its side if plain TCP,
;        and says what comes back, a line at a time ("net| ..."), 64 lines
;        at most; returns 0 once the other side has ended it cleanly
;    net echo <host> <port> <n> <bytes> [tls|insecure]
;        n connections at once (16 at most), each sending that many bytes of
;        a pattern of its own while checking that the same comes back
;    net serve <port> <n>
;        listens, and sends back what comes on each of n connections, one
;        after another, until its other side has finished
;    net test [resetting port]
;        what its capability lets it do and what not: narrower handles,
;        bad arguments, failures and how they are told, the limit; says
;        "net: all N checks passed" and returns 0, or which failed
; =============================================================================

%include "axe.inc"
WANTS AW_NET

ECHO_MAX        equ 16
GOT_MAX         equ 65536
LINES_MAX       equ 64
CHUNK           equ 4096                ; through the io page
WAIT_US         equ 15000000            ; how long anything may take
SOCKETS_MAX     equ 32                  ; the kernel's SK_MAX

%include "sock.inc"

main:
    push rbx
    lea rsi, [rdi + SB_ARGS]            ; the start block is read-only: a copy to cut up
    lea rdi, [args]
    mov ecx, [rsi - SB_ARGS + SB_ARGS_LEN]
    rep movsb
    mov byte [rdi], 0
    lea rbx, [args]
    cmp dword [ax_net], 0
    jne .net
    lea rsi, [s_no_net]
    call ax_puts
    mov eax, 98
    jmp .out
.net:
    lea rdi, [s_get]
    call is_word
    jne .not_get
    call m_get
    jmp .out
.not_get:
    lea rdi, [s_echo]
    call is_word
    jne .not_echo
    call m_echo
    jmp .out
.not_echo:
    lea rdi, [s_serve]
    call is_word
    jne .not_serve
    call m_serve
    jmp .out
.not_serve:
    lea rdi, [s_test]
    call is_word
    jne .usage
    call m_test
    jmp .out
.usage:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Words
; -----------------------------------------------------------------------------

; is_word(RBX = the arguments left, RDI = a word) -> ZF if they begin with
; it, and RBX past it then
is_word:
    mov rsi, rbx
.space:
    cmp byte [rsi], ' '
    jne .same
    inc rsi
    jmp .space
.same:
    mov al, [rdi]
    test al, al
    jz .end
    cmp al, [rsi]
    jne .out
    inc rsi
    inc rdi
    jmp .same
.end:
    mov al, [rsi]
    test al, al
    jz .yes
    cmp al, ' '
    jne .out
.yes:
    mov rbx, rsi
    xor eax, eax
.out:
    ret

; next_arg(RBX) -> RSI = the next word, NUL-ended there now ("" if none); RBX
; past it
next_arg:
    cmp byte [rbx], ' '
    jne .start
    inc rbx
    jmp next_arg
.start:
    mov rsi, rbx
.scan:
    mov al, [rbx]
    test al, al
    jz .out
    cmp al, ' '
    je .cut
    inc rbx
    jmp .scan
.cut:
    mov byte [rbx], 0
    inc rbx
.out:
    ret

; number(RSI = a word) -> RAX, CF if it is not one
number:
    xor eax, eax
    cmp byte [rsi], 0
    je .no
.digit:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .yes
    sub ecx, '0'
    cmp ecx, 9
    ja .no
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    jmp .digit
.yes:
    clc
    ret
.no:
    stc
    ret

; flags_word(RBX) -> EAX = NETF_* for a "tls" or "insecure" next, RBX past
; it; else 0
flags_word:
    lea rdi, [s_tls]
    call is_word
    mov eax, NETF_TLS
    je .out
    lea rdi, [s_insecure]
    call is_word
    mov eax, NETF_TLS | NETF_INSECURE
    je .out
    xor eax, eax
.out:
    ret

; -----------------------------------------------------------------------------
;  The ring
; -----------------------------------------------------------------------------

; sub(EDI = a network handle, RSI = a pattern, EDX = port, ECX = rights) ->
; RAX = a narrower handle
sub_net:
    push rbx
    push r12
    push r13
    mov ebx, edi
    mov r12d, edx
    mov r13d, ecx
    call host_at
    mov edi, ebx
    mov esi, RO_NET_SUB
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

; say_failed(EDI = a socket): "net: failed, why W (TLS's error E)"
say_failed:
    call status
    push rax
    lea rsi, [s_failed]
    call ax_add
    mov rdi, [rsp]
    and edi, 0xFF
    call ax_addu
    lea rsi, [s_why]
    call ax_add
    mov rdi, [rsp]
    shr edi, 8
    and edi, 0xFF
    call ax_addu
    lea rsi, [s_tlse]
    call ax_add
    pop rdi
    shr edi, 16
    and edi, 0xFF
    call ax_addu
    jmp ax_flush

; say_err(RSI = text, RDI = a result): the text, then the number
say_err:
    push rdi
    call ax_add
    pop rdi
    call ax_addd
    jmp ax_flush

; -----------------------------------------------------------------------------
;  net get
; -----------------------------------------------------------------------------

m_get:
    push r12
    push r13
    push r14
    push r15
    call next_arg
    mov r12, rsi                        ; R12 = host
    call next_arg
    call number
    jc .usage
    mov r13, rax                        ; R13 = port
    call flags_word
    mov r14d, eax                       ; R14 = NETF_*
    cmp byte [rbx], ' '                 ; the text: escapes undone
    jne .text
    inc rbx
.text:
    lea rdi, [text]
.char:
    mov al, [rbx]
    inc rbx
    test al, al
    jz .texted
    cmp al, '\'
    jne .put
    mov al, [rbx]
    cmp al, 'n'
    mov ah, 10
    je .escape
    cmp al, 'r'
    mov ah, 13
    je .escape
    mov al, '\'
    jmp .put
.escape:
    inc rbx
    mov al, ah
.put:
    stosb
    jmp .char
.texted:
    lea rax, [text]
    sub rdi, rax
    mov r15, rdi                        ; R15 = its bytes

    mov edi, [ax_net]
    mov rsi, r12
    mov edx, r13d
    mov ecx, r14d
    call connect
    test rax, rax
    js .refused
    mov r12d, eax                       ; R12 = the socket
    mov edi, r12d
    mov esi, 1
    mov edx, WAIT_US
    call wait_on                        ; until it is open, or failed
    mov edi, r12d
    call status
    cmp al, SKS_OPEN
    jne .failed
    lea rsi, [s_connected]
    call ax_puts
    mov edi, r12d
    lea rsi, [text]
    mov rdx, r15
    call send_all
    test rax, rax
    js .failed
    test r14d, NETF_TLS
    jnz .read
    mov edi, r12d
    mov esi, RO_NET_SHUT
    xor ecx, ecx
    call simple
.read:
    xor r13d, r13d                      ; R13 = bytes that came
.next:
    lea rsi, [got]
    mov eax, GOT_MAX - CHUNK
    cmp r13, rax
    jbe .room
    mov r13d, eax                       ; past that, counted only... (kept at the end)
.room:
    add rsi, r13
    mov edi, r12d
    mov edx, CHUNK
    call recv_wait
    test rax, rax
    jle .ended
    add r13, rax
    add [got_total], rax
    jmp .next
.ended:
    mov r15, rax
    lea rsi, [got]
    mov rcx, r13
    call lines
    lea rsi, [s_bytes]
    call ax_add
    mov rdi, [got_total]
    call ax_addu
    cmp r15, E_PEER
    jne .then_failed
    lea rsi, [s_ended]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp .out
.then_failed:
    lea rsi, [s_then]
    call ax_add
    call ax_flush
.failed:
    mov edi, r12d
    call say_failed
    mov eax, 3
    jmp .out
.refused:
    lea rsi, [s_refused]
    mov rdi, rax
    call say_err
    mov eax, 2
    jmp .out
.usage:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; lines(RSI = text, RCX = bytes): each line said, "net| " before it, 64 at
; most; '\r' left out
lines:
    push r12
    push r13
    push r14
    mov r12, rsi
    lea r13, [rsi + rcx]
    xor r14d, r14d
.line:
    cmp r12, r13
    jae .out
    cmp r14d, LINES_MAX
    jae .out
    lea rsi, [s_bar]
    call ax_add
.char:
    cmp r12, r13
    jae .said
    mov al, [r12]
    inc r12
    cmp al, 10
    je .said
    cmp al, 13
    je .char
    mov [one], al
    lea rsi, [one]
    mov ecx, 1
    call ax_addn
    jmp .char
.said:
    call ax_flush
    inc r14d
    jmp .line
.out:
    pop r14
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  net echo
; -----------------------------------------------------------------------------

; pattern(ECX = which connection, RAX = where in its bytes) -> AL = the byte
; there. Preserves others.
%macro PATTERN 0
    push rdx
    mov rdx, rax
    imul eax, eax, 31
    shr rdx, 8
    add eax, edx
    imul edx, ecx, 7
    add eax, edx
    pop rdx
%endmacro

m_echo:
    push r12
    push r13
    push r14
    push r15
    push rbp
    call next_arg
    mov r12, rsi                        ; R12 = host
    call next_arg
    call number
    jc .usage
    mov r13, rax                        ; R13 = port
    call next_arg
    call number
    jc .usage
    test rax, rax
    jz .usage
    cmp rax, ECHO_MAX
    ja .usage
    mov r14, rax                        ; R14 = connections
    call next_arg
    call number
    jc .usage
    mov r15, rax                        ; R15 = bytes each
    call flags_word
    mov ebp, eax                        ; EBP = NETF_*
    xor ebx, ebx
.open:
    mov edi, [ax_net]
    mov rsi, r12
    mov edx, r13d
    mov ecx, ebp
    call connect
    test rax, rax
    js .refused
    mov [hs + rbx * 4], eax
    mov qword [sent + rbx * 8], 0
    mov qword [recvd + rbx * 8], 0
    mov byte [okay + rbx], 1
    inc ebx
    cmp rbx, r14
    jb .open
    mov edi, 60000000
    call ax_us
    mov [deadline], rax
    call ax_now
    add [deadline], rax

.round:                                 ; each, as far as it goes now
    mov byte [progress], 0
    mov byte [all_done], 1
    xor ebx, ebx
.each:
    mov rax, [recvd + rbx * 8]
    cmp rax, r15
    jae .next
    mov byte [all_done], 0
    mov rax, [sent + rbx * 8]           ; what it has to send
    cmp rax, r15
    jae .receive
    mov rdx, r15
    sub rdx, rax
    cmp rdx, CHUNK
    jbe .fill
    mov edx, CHUNK
.fill:
    push rdx
    mov rdi, [ax_io_va]
    mov ecx, ebx
    xor r8d, r8d
.byte:
    push rax
    PATTERN
    mov [rdi + r8], al
    pop rax
    inc rax
    inc r8
    cmp r8, rdx
    jb .byte
    pop rdx
    mov edi, [hs + rbx * 4]
    call send_io
    cmp rax, E_FULL
    je .receive
    test rax, rax
    js .broke
    add [sent + rbx * 8], rax
    mov byte [progress], 1
.receive:
    mov edi, [hs + rbx * 4]
    mov edx, CHUNK
    call recv_io
    cmp rax, E_EMPTY
    je .next
    test rax, rax
    jle .broke                          ; ended before all of it came back
    mov byte [progress], 1
    mov rdx, rax                        ; the same as went?
    mov rsi, [ax_io_va]
    mov rax, [recvd + rbx * 8]
    add [recvd + rbx * 8], rdx
    mov ecx, ebx
    xor r8d, r8d
.check:
    push rax
    PATTERN
    cmp [rsi + r8], al
    pop rax
    je .same
    mov byte [okay + rbx], 0
.same:
    inc rax
    inc r8
    cmp r8, rdx
    jb .check
    jmp .next
.broke:
    mov edi, [hs + rbx * 4]
    call say_failed
    mov byte [okay + rbx], 0
    mov [recvd + rbx * 8], r15          ; no more from it
.next:
    inc ebx
    cmp rbx, r14
    jb .each
    cmp byte [all_done], 0
    jne .done
    cmp byte [progress], 0
    jne .round
    call ax_now
    cmp rax, [deadline]
    ja .late
    xor ebx, ebx                        ; nothing moved: wait a little, on the first unfinished
.first:
    mov rax, [recvd + rbx * 8]
    cmp rax, r15
    jb .wait
    inc ebx
    jmp .first
.wait:
    mov edi, [hs + rbx * 4]
    xor esi, esi
    mov edx, 20000
    call wait_on
    jmp .round
.late:
    lea rsi, [s_late]
    call ax_puts
    xor ebx, ebx
.unfinished:
    mov rax, [recvd + rbx * 8]
    cmp rax, r15
    jae .fine
    mov byte [okay + rbx], 0
    lea rsi, [s_conn]                   ; how far it got
    call ax_add
    mov edi, ebx
    call ax_addu
    lea rsi, [s_sent]
    call ax_add
    mov rdi, [sent + rbx * 8]
    call ax_addu
    lea rsi, [s_back]
    call ax_add
    mov rdi, [recvd + rbx * 8]
    call ax_addu
    call ax_flush
.fine:
    inc ebx
    cmp rbx, r14
    jb .unfinished

.done:
    xor ebx, ebx
    xor r12d, r12d                      ; R12 = how many came back right
.close:
    movzx eax, byte [okay + rbx]
    add r12d, eax
    test ebp, NETF_TLS
    jnz .closing
    mov edi, [hs + rbx * 4]
    mov esi, RO_NET_SHUT
    xor ecx, ecx
    call simple
.closing:
    mov edi, [hs + rbx * 4]
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
    inc ebx
    cmp rbx, r14
    jb .close
    lea rsi, [s_echoed]
    call ax_add
    mov edi, r12d
    call ax_addu
    lea rsi, [s_of]
    call ax_add
    mov rdi, r14
    call ax_addu
    lea rsi, [s_right]
    call ax_add
    mov rdi, r15
    call ax_addu
    lea rsi, [s_each]
    call ax_add
    call ax_flush
    xor eax, eax
    cmp r12, r14
    je .out
    mov eax, 4
    jmp .out
.refused:
    lea rsi, [s_refused]
    mov rdi, rax
    call say_err
    mov eax, 2
    jmp .out
.usage:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  net serve
; -----------------------------------------------------------------------------

m_serve:
    push r12
    push r13
    push r14
    push r15
    call next_arg
    call number
    jc .usage
    mov r12, rax                        ; R12 = port
    call next_arg
    call number
    jc .usage
    mov r13, rax                        ; R13 = connections to serve
    mov edi, [ax_net]
    mov esi, RO_NET_LISTEN
    mov rcx, r12
    call simple
    test rax, rax
    js .refused
    mov r14d, eax                       ; R14 = the socket listening
    xor ebx, ebx
.accept:
    cmp rbx, r13
    jae .served
    mov edi, r14d
    mov esi, RO_NET_ACCEPT
    xor ecx, ecx
    call simple
    cmp rax, E_EMPTY
    jne .accepted
    mov edi, r14d
    xor esi, esi
    mov edx, 60000000
    call wait_on
    test rax, rax
    jns .accept
    jmp .listen_failed
.accepted:
    test rax, rax
    js .listen_failed
    mov r15d, eax                       ; R15 = the connection
    mov qword [got_total], 0
.echo:
    mov edi, r15d
    lea rsi, [got]
    mov edx, CHUNK
    call recv_wait
    test rax, rax
    jle .finished
    add [got_total], rax
    mov edi, r15d
    lea rsi, [got]
    mov rdx, rax
    call send_all
    test rax, rax
    jns .echo
.finished:
    cmp rax, E_PEER
    je .served_one
    mov edi, r15d
    call say_failed
.served_one:
    mov edi, r15d
    mov esi, RO_NET_SHUT
    xor ecx, ecx
    call simple
    mov edi, r15d
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
    inc ebx
    lea rsi, [s_served]
    call ax_add
    mov edi, ebx
    call ax_addu
    lea rsi, [s_colon]
    call ax_add
    mov rdi, [got_total]
    call ax_addu
    lea rsi, [s_bytes_back]
    call ax_add
    call ax_flush
    jmp .accept
.served:
    mov edi, r14d
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
    xor eax, eax
    jmp .out
.listen_failed:
    mov edi, r14d
    call say_failed
    mov eax, 3
    jmp .out
.refused:
    lea rsi, [s_refused]
    mov rdi, rax
    call say_err
    mov eax, 2
    jmp .out
.usage:
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  net test
; -----------------------------------------------------------------------------

; expect(RAX = what came, RDI = what should have, or OK for any handle):
; counted; said if not
OK              equ 1 << 40

expect:
    inc dword [checks]
    mov rcx, OK
    cmp rdi, rcx
    jne .exact
    test rax, rax
    jns .out
    jmp .wrong
.exact:
    cmp rax, rdi
    je .out
.wrong:
    inc dword [wrong]
    push rax                            ; kept for the caller
    push rdi
    push rax
    lea rsi, [s_check]
    call ax_add
    mov edi, [checks]
    call ax_addu
    lea rsi, [s_gave]
    call ax_add
    pop rdi
    call ax_addd
    lea rsi, [s_wanted]
    call ax_add
    pop rdi
    call ax_addd
    call ax_flush
    pop rax
.out:
    ret

; pause_ms(EDI = milliseconds)
pause_ms:
    push rbx
    imul edi, edi, 1000
    call ax_us
    mov rbx, rax
    call ax_now
    lea r10, [rax + rbx]
    mov esi, RO_TIMEOUT
    xor edi, edi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    call op
    pop rbx
    ret

%macro CONNECT 4                        ; network, host, port, flags
    mov edi, %1
    lea rsi, [%2]
    mov edx, %3
    mov ecx, %4
    call connect
%endmacro

%macro SUB 4                            ; network, pattern, port, rights
    mov edi, %1
    lea rsi, [%2]
    mov edx, %3
    mov ecx, %4
    call sub_net
%endmacro

%macro EXPECT 1
    mov rdi, %1
    call expect
%endmacro

%macro CLOSE 1
    mov edi, %1
    mov esi, RO_CLOSE
    xor ecx, ecx
    call simple
%endmacro

m_test:
    push r12
    push r13
    push r14
    push r15
    push rbp
    call next_arg
    call number
    mov [reset_port], rax
    jnc .ports
    mov qword [reset_port], 0
.ports:
    ; one host, one port, plain TCP only
    SUB [ax_net], h_host, 7, RT_NET_CONNECT | RT_DUP
    EXPECT OK
    mov r12d, eax                       ; R12 = it
    CONNECT r12d, h_other, 7, 0
    EXPECT E_RIGHTS
    CONNECT r12d, h_host, 8, 0
    EXPECT E_RIGHTS
    CONNECT r12d, h_host, 7, NETF_TLS
    EXPECT E_RIGHTS
    SUB r12d, h_any, 0, RT_ALL          ; none wider
    EXPECT E_RIGHTS
    SUB r12d, h_host, 8, RT_ALL
    EXPECT E_RIGHTS
    SUB r12d, h_host, 0, RT_ALL         ; its port, its rights
    EXPECT OK
    mov r13d, eax                       ; R13 = that
    CONNECT r13d, h_host, 8, 0
    EXPECT E_RIGHTS
    CONNECT r13d, h_host, 7, NETF_TLS
    EXPECT E_RIGHTS
    ; every host under a name
    SUB [ax_net], h_under, 0, RT_ALL
    EXPECT OK
    mov r14d, eax                       ; R14 = it
    SUB r14d, h_a_under, 0, RT_ALL
    EXPECT OK
    mov edi, eax
    call close_ok
    SUB r14d, h_under_b, 0, RT_ALL
    EXPECT OK
    mov edi, eax
    call close_ok
    SUB r14d, h_name, 0, RT_ALL
    EXPECT E_RIGHTS
    SUB r14d, h_evil, 0, RT_ALL
    EXPECT E_RIGHTS
    SUB r14d, h_suffix, 0, RT_ALL
    EXPECT E_RIGHTS
    CONNECT r14d, h_host, 7, 0
    EXPECT E_RIGHTS
    ; arguments
    CONNECT [ax_net], h_any, 7, 0
    EXPECT E_ARG
    CONNECT [ax_net], h_host, 0, 0
    EXPECT E_ARG
    CONNECT [ax_net], h_host, 70000, 0
    EXPECT E_ARG
    CONNECT [ax_net], h_host, 7, 4
    EXPECT E_ARG
    CONNECT [ax_net], h_host, 7, NETF_INSECURE
    EXPECT E_ARG
    mov edi, [ax_net]
    mov esi, RO_NET_LISTEN
    xor ecx, ecx
    call simple
    EXPECT E_ARG
    mov edi, r12d
    mov esi, RO_NET_LISTEN
    mov ecx, 7
    call simple
    EXPECT E_RIGHTS
    ; a failure, and how it is told
    CONNECT [ax_net], h_bad, 7, 0
    EXPECT OK
    mov r15d, eax                       ; R15 = it
    mov edi, r15d
    mov esi, 2
    xor edx, edx
    call wait_on
    EXPECT E_ARG
    mov edi, r15d
    mov esi, 1
    mov edx, 5000000
    call wait_on
    EXPECT 0
    mov edi, r15d
    call status
    EXPECT SKS_FAILED | (NETW_BADNAME << 8)
    mov edi, r15d
    mov edx, 16
    call recv_io
    EXPECT E_NET
    mov edi, r15d
    mov edx, 1
    call send_io
    EXPECT E_NET
    mov edi, r15d
    mov esi, RO_NET_ACCEPT
    xor ecx, ecx
    call simple
    EXPECT E_ARG
    mov edi, r15d                       ; a copy that may only receive
    mov esi, RO_DUP
    mov ecx, RT_SK_RECV
    call simple
    EXPECT OK
    mov ebp, eax
    mov edi, ebp
    mov edx, 1
    call send_io
    EXPECT E_RIGHTS
    CLOSE ebp
    ; listening
    mov edi, [ax_net]
    mov esi, RO_NET_LISTEN
    mov ecx, 7777
    call simple
    EXPECT OK
    mov ebp, eax                        ; EBP = it
    mov edi, ebp
    mov edx, 1
    call send_io
    EXPECT E_ARG
    mov edi, ebp
    mov esi, RO_NET_ACCEPT
    xor ecx, ecx
    call simple
    EXPECT E_EMPTY
    CONNECT [ax_net], h_host, 7, NETF_TLS | NETF_INSECURE
    EXPECT OK
    mov [tls_sock], eax
    mov edi, eax
    mov esi, RO_NET_SHUT
    xor ecx, ecx
    call simple
    EXPECT E_ARG
    ; no more than SOCKETS_MAX at once: three are open
    xor ebx, ebx
.many:
    CONNECT [ax_net], h_bad, 7, 0
    test rax, rax
    js .full
    mov [hs_many + rbx * 4], eax
    inc ebx
    cmp ebx, SOCKETS_MAX
    jb .many
.full:
    EXPECT E_FULL
    mov eax, ebx
    EXPECT SOCKETS_MAX - 3
.unmany:
    test ebx, ebx
    jz .unmanied
    dec ebx
    CLOSE [hs_many + rbx * 4]
    jmp .unmany
.unmanied:
    CLOSE ebp
    CLOSE [tls_sock]
    CLOSE r15d
    ; a server that resets the connection it took
    mov edi, 300                        ; (let go of on the main loop, not at once)
    call pause_ms
    mov rdx, [reset_port]
    test rdx, rdx
    jz .reset
    CONNECT [ax_net], h_host, edx, 0
    EXPECT OK
    mov r15d, eax
    mov edi, r15d                       ; until it has failed
    xor esi, esi
    mov edx, 10000000
    call wait_on
    mov edi, r15d
    call status
    EXPECT SKS_FAILED | (NETW_RESET << 8)
    CLOSE r15d
.reset:
    CLOSE r14d
    CLOSE r13d
    CLOSE r12d
    cmp dword [wrong], 0
    jne .wrong
    lea rsi, [s_all]
    call ax_add
    mov edi, [checks]
    call ax_addu
    lea rsi, [s_passed]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp .out
.wrong:
    mov edi, [wrong]
    call ax_addu
    lea rsi, [s_of]
    call ax_add
    mov edi, [checks]
    call ax_addu
    lea rsi, [s_failed_checks]
    call ax_add
    call ax_flush
    mov eax, 5
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; close_ok(EDI = a handle, if it is one)
close_ok:
    test edi, edi
    js .out
    mov esi, RO_CLOSE
    xor ecx, ecx
    jmp simple
.out:
    ret

section .rodata
s_get:          db 'get', 0
s_echo:         db 'echo', 0
s_serve:        db 'serve', 0
s_test:         db 'test', 0
s_tls:          db 'tls', 0
s_insecure:     db 'insecure', 0
s_usage:        db 'usage: net get <host> <port> [tls|insecure] [text] | echo <host> <port> <n> <bytes> [tls|insecure] | serve <port> <n> | test [resetting port]', 0
s_no_net:       db 'net: no network handle (run from the console)', 0
s_connected:    db 'net: connected', 0
s_refused:      db 'net: refused, ', 0
s_failed:       db 'net: failed, state ', 0
s_why:          db ', why ', 0
s_tlse:         db ', TLS error ', 0
s_bar:          db 'net| ', 0
s_bytes:        db 'net: ', 0
s_ended:        db ' bytes, ended', 0
s_then:         db ' bytes, then', 0
s_late:         db 'net: echo: out of time', 0
s_conn:         db 'net: echo: connection ', 0
s_sent:         db ': sent ', 0
s_back:         db ', back ', 0
s_echoed:       db 'net: echo: ', 0
s_of:           db ' of ', 0
s_right:        db ' right, ', 0
s_each:         db ' bytes each', 0
s_served:       db 'net: served ', 0
s_colon:        db ': ', 0
s_bytes_back:   db ' bytes back', 0
s_check:        db 'net: check ', 0
s_gave:         db ' gave ', 0
s_wanted:       db ', wanted ', 0
s_all:          db 'net: all ', 0
s_passed:       db ' checks passed', 0
s_failed_checks: db ' checks failed', 0
h_host:         db '10.0.2.2', 0
h_other:        db '10.0.2.3', 0
h_any:          db 0
h_under:        db '*.axiom.test', 0
h_a_under:      db 'a.axiom.test', 0
h_under_b:      db '*.b.axiom.test', 0
h_name:         db 'axiom.test', 0
h_evil:         db 'evilaxiom.test', 0
h_suffix:       db 'axiom.test.evil', 0
h_bad:          db 'bad..name', 0

section .bss
alignb 8
got_total:      resq 1
deadline:       resq 1
reset_port:    resq 1
sent:           resq ECHO_MAX
recvd:          resq ECHO_MAX
hs:             resd ECHO_MAX
hs_many:        resd SOCKETS_MAX
checks:         resd 1
wrong:          resd 1
tls_sock:       resd 1
okay:           resb ECHO_MAX
progress:       resb 1
all_done:       resb 1
one:            resb 1
args:           resb 4096
text:           resb 4096
got:            resb GOT_MAX

AXE_END
