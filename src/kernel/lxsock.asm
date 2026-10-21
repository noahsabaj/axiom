; =============================================================================
;  lxsock.asm - sockets, for Linux programs
;
;  A socket is an open file (LFK_SOCK) whose LF_PRIV is its state (XS_*):
;  TCP over Axiom's own (socket.asm's OT_SOCKET objects), UDP of its own on
;  net.asm's, and AF_UNIX pairs made of two pipes (lxpipe.asm). fstat finds
;  lx_sock_node, a socket.
;
;  TCP: connect makes a socket object, its host the address as text (so no
;  lookup), and hands it to the main loop to connect; listen makes one that
;  listens, and accept takes what it accepted. The bytes go through the
;  object's two rings as RO_SEND and RO_RECV move them: a Linux thread
;  copies, one at a time each way (sk_take), and the main loop does TCP.
;  sk_settle kicks poll's waiters, so a read, a write or a connect waits as
;  poll does. Close lets the object go; what was sent still goes out first
;  (socket.asm's linger).
;
;  UDP: a socket with a port (one from LX_PORT_FIRST on if it did not ask
;  for one) is on lx_udp_list. udp_input and udp6_input give it what comes
;  to that port (lx_udp_input: a datagram each, XD_*), and what it sends
;  waits on lx_udp_txq for the main loop to send (lx_udp_tick). lx_udp_lock
;  covers both, and every socket's queue, with interrupts off.
;
;  AF_UNIX: socketpair. Each end reads one pipe and writes the other; a
;  pair of datagram sockets is a stream here. Nothing has a name: connect
;  finds none (ENOENT), and bind can make none in a read-only tree.
;
;  /etc/resolv.conf is the kernel's too, said afresh at each open: the DNS
;  servers DHCP, a router's advertisement or 'ip' gave (lx_resolv_fill).
; =============================================================================

AF_UNSPEC       equ 0
AF_UNIX         equ 1
AF_INET         equ 2
AF_INET6        equ 10
SOCK_STREAM     equ 1
SOCK_DGRAM      equ 2
SOCK_SEQPACKET  equ 5
SOCK_TYPE_MASK  equ 0xF                 ; (with O_NONBLOCK and O_CLOEXEC above)
IPPROTO_TCP     equ 6
IPPROTO_UDP     equ 17
IPPROTO_IPV6    equ 41
SOL_SOCKET      equ 1
SO_REUSEADDR    equ 2
SO_TYPE         equ 3
SO_ERROR        equ 4
SO_DONTROUTE    equ 5
SO_BROADCAST    equ 6
SO_SNDBUF       equ 7
SO_RCVBUF       equ 8
SO_KEEPALIVE    equ 9
SO_OOBINLINE    equ 10
SO_LINGER       equ 13
SO_REUSEPORT    equ 15
SO_PASSCRED     equ 16
SO_PEERCRED     equ 17
SO_RCVTIMEO     equ 20
SO_SNDTIMEO     equ 21
SO_ACCEPTCONN   equ 30
SO_PROTOCOL     equ 38
SO_DOMAIN       equ 39
SO_RCVTIMEO_NEW equ 66
SO_SNDTIMEO_NEW equ 67
TCP_NODELAY     equ 1
TCP_MAXSEG      equ 2
IPV6_V6ONLY     equ 26
MSG_PEEK        equ 2
MSG_TRUNC       equ 0x20
MSG_DONTWAIT    equ 0x40
MSG_WAITALL     equ 0x100
MSG_NOSIGNAL    equ 0x4000
SHUT_RDWR       equ 2
POLLRDHUP       equ 0x2000
UIO_MAXIOV      equ 1024
LX_PORT_FIRST   equ 32768               ; ports for sockets that ask for none:
LX_PORT_COUNT   equ 16384               ; to 49151 (Axiom's DNS asks from 49152)
UDP4_MAX        equ 1472                ; a datagram's bytes, at most: one frame
UDP6_MAX        equ 1452
XS_QMAX         equ 212992              ; bytes waiting on a UDP socket, at most
LX_SOCK_INO     equ 0x7200000000

; a socket (kmalloc'd, LF_PRIV)
XS_LOCK         equ 0                   ; dword lx_mutex: its state (connect, bind, listen, shutdown)
XS_RLOCK        equ 4                   ; dword lx_mutex: UDP, one receiver at a time
XS_DOMAIN       equ 8                   ; dword AF_*
XS_TYPE         equ 12                  ; dword SOCK_*, as made
XS_PROTO        equ 16                  ; dword IPPROTO_*, 0 for AF_UNIX
XS_KIND         equ 20                  ; dword XSK_*
XS_STATE        equ 24                  ; dword XSS_*
XS_SHUT         equ 28                  ; dword: 1 reading is shut, 2 writing
XS_ERROR        equ 32                  ; dword: an errno for SO_ERROR
XS_OPTS         equ 36                  ; dword: options set (lx_sock_bools' bits)
XS_LPORT        equ 40                  ; dword: its port, 0 until it has one
XS_RPORT        equ 44                  ; dword: the other side's
XS_LADDR        equ 48                  ; its address (16 bytes; :: for any)
XS_RADDR        equ 64                  ; the other side's
XS_RCVTIMEO     equ 80                  ; nanoseconds, 0 for none
XS_SNDTIMEO     equ 88
XS_SK           equ 96                  ; TCP: the socket object, a reference
XS_OLDSK        equ 104                 ; the one before (a connect that failed)
XS_NEXT         equ 112                 ; UDP: on lx_udp_list, once it has a port
XS_QHEAD        equ 120                 ; UDP: datagrams come (XD_*), oldest first
XS_QTAIL        equ 128
XS_QBYTES       equ 136                 ; dword
XS_SAID         equ 140                 ; dword: bit 0 once a read said TCP's failure
XS_PIN          equ 144                 ; AF_UNIX: the pipe it reads
XS_POUT         equ 152                 ; and the one it writes
XS_SIZE         equ 160

XSK_TCP         equ 1
XSK_UDP         equ 2
XSK_UNIX        equ 3

XSS_NEW         equ 0
XSS_CONNECTING  equ 1                   ; TCP: until a look sees it open, or failed
XSS_CONNECTED   equ 2
XSS_LISTENING   equ 3

; a datagram (kmalloc'd): come, or to go
XD_NEXT         equ 0
XD_ADDR         equ 8                   ; who from, or to (16 bytes)
XD_PORT         equ 24                  ; dword: their port
XD_SPORT        equ 28                  ; dword: ours, going
XD_LEN          equ 32                  ; dword
XD_DATA         equ 40

; an address a program gave, read (lx_sa_read)
XA_ADDR         equ 0                   ; 16 bytes
XA_PORT         equ 16                  ; dword
XA_FAMILY       equ 20                  ; dword
XA_SIZE         equ 24

%macro UDP_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [lx_udp_lock]
    call spin_lock
    pop rdi
%endmacro

%macro UDP_UNLOCK 0
    push rdi
    lea rdi, [lx_udp_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  Making them, and letting them go
; -----------------------------------------------------------------------------

; socket(domain, type, protocol)
lx_sys_socket:
    push rbx
    push r12
    mov r12d, esi                       ; R12 = the type, with its flags
    mov rax, -EINVAL
    test esi, ~(SOCK_TYPE_MASK | O_NONBLOCK | O_CLOEXEC)
    jnz .out
    and esi, SOCK_TYPE_MASK
    cmp edi, AF_UNIX
    je .unix
    cmp edi, AF_INET
    je .inet
    cmp edi, AF_INET6
    je .inet
    mov rax, -EAFNOSUPPORT              ; (netlink among them: glibc does without)
    jmp .out
.unix:
    mov rax, -EPROTONOSUPPORT
    test edx, edx
    jnz .out
    mov rax, -ESOCKTNOSUPPORT
    cmp esi, SOCK_STREAM
    je .unix_type
    cmp esi, SOCK_DGRAM
    je .unix_type
    cmp esi, SOCK_SEQPACKET
    jne .out
.unix_type:
    mov ecx, XSK_UNIX
    jmp .make
.inet:
    mov ecx, XSK_TCP
    mov eax, IPPROTO_TCP
    cmp esi, SOCK_STREAM
    je .proto
    mov ecx, XSK_UDP
    mov eax, IPPROTO_UDP
    cmp esi, SOCK_DGRAM
    je .proto
    mov rax, -ESOCKTNOSUPPORT           ; (raw ones too)
    jmp .out
.proto:
    test edx, edx
    jz .proto_set
    cmp edx, eax
    mov rax, -EPROTONOSUPPORT           ; (ping's ICMP among them)
    jne .out
.proto_set:
    mov edx, eax
.make:
    call lx_sock_new
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov esi, r12d
    call lx_sock_open
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    pop r12
    pop rbx
    ret

; lx_sock_new(EDI = AF_*, ESI = SOCK_*, EDX = IPPROTO_*, ECX = XSK_*) -> RAX
; = a socket's state, new, or 0. Preserves others.
lx_sock_new:
    push rdi
    mov edi, XS_SIZE
    call kmalloc
    pop rdi
    test rax, rax
    jz .out
    mov [rax + XS_DOMAIN], edi
    mov [rax + XS_TYPE], esi
    mov [rax + XS_PROTO], edx
    mov [rax + XS_KIND], ecx
.out:
    ret

; lx_sock_open(RDI = a socket's state, ESI = O_NONBLOCK | O_CLOEXEC) -> RAX =
; a descriptor for it, or -errno. The state is the file's from here on (or
; freed, if no file could be made).
lx_sock_open:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    mov edi, LFK_SOCK
    lea rsi, [lx_sock_node]
    mov edx, r13d
    and edx, O_NONBLOCK
    or edx, O_RDWR
    call lf_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    lea rax, [lx_sock_ops]
    mov [rbx + LF_OPS], rax
    mov [rbx + LF_PRIV], r12
    call lx_cur_proc
    mov rdi, rax
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    test r13d, O_CLOEXEC
    setnz cl
    call lx_fd_install                  ; (none free: the file goes, and the socket)
    jmp .out
.nomem:
    mov rdi, r12
    call lx_sock_free
    mov rax, -ENOMEM
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_sock_free(RDI = a socket's state): all it holds let go, and it freed
lx_sock_free:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + XS_SK]
    call lx_sk_release
    mov rdi, [rbx + XS_OLDSK]
    call lx_sk_release
    cmp dword [rbx + XS_KIND], XSK_UDP
    jne .pin
    call lx_udp_unbind
.pin:
    mov rdi, [rbx + XS_PIN]             ; AF_UNIX: the ends not shut already
    test rdi, rdi
    jz .pout
    test dword [rbx + XS_SHUT], 1
    jnz .pout
    xor esi, esi
    call lx_pipe_end
.pout:
    mov rdi, [rbx + XS_POUT]
    test rdi, rdi
    jz .free
    test dword [rbx + XS_SHUT], 2
    jnz .free
    mov esi, 1
    call lx_pipe_end
.free:
    mov rdi, rbx
    call kfree
    pop rbx
    ret

; lx_sk_release(RDI = a socket object, or 0): ours no more. What it sent
; still goes; the main loop lets it go after.
lx_sk_release:
    test rdi, rdi
    jz .out
    push rdi
    call sk_orphan
    pop rdi
    jmp obj_put
.out:
    ret

; lx_sk_start(RDI = a socket object just made, its one reference ours): the
; main loop's to begin, with a reference of its own
lx_sk_start:
    push rbx
    mov rbx, rdi
    call obj_get
    SK_LOCK
    mov rcx, [sk_new]
    mov [rbx + SK_NEXT], rcx
    mov [sk_new], rbx
    SK_UNLOCK
    call sk_kick
    pop rbx
    ret

; (LFO_CLOSE) a socket's last reference gone
lx_sock_close:
    mov rdi, [rdi + LF_PRIV]
    jmp lx_sock_free

; lx_sock_ref(EDI = a descriptor) -> RAX = its open file, a reference (lf_put
; it), or -EBADF, or -ENOTSOCK. Preserves others.
lx_sock_ref:
    call lx_fd_ref
    cmp rax, -4095
    jae .out
    cmp dword [rax + LF_KIND], LFK_SOCK
    je .out
    push rdi
    mov rdi, rax
    call lf_put
    pop rdi
    mov rax, -ENOTSOCK
.out:
    ret

; -----------------------------------------------------------------------------
;  Addresses, waits, errors
; -----------------------------------------------------------------------------

; lx_sa_read(RDI = a user sockaddr, ESI = its length, RDX = where to put it
; (XA_*)) -> RAX = 0 or -errno. AF_UNSPEC and AF_UNIX come with no address.
lx_sa_read:
    push rbx
    push r12
    sub rsp, 32
    mov rbx, rdx
    mov r12d, esi
    mov rax, -EINVAL
    cmp r12d, 2
    jl .out
    cmp r12d, 28
    jbe .len
    mov r12d, 28
.len:
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    mov [rbx], rax
    mov [rbx + 8], rax
    mov rsi, rdi
    mov rdi, rsp
    mov edx, r12d
    call lx_copy_in
    test rax, rax
    jnz .out
    movzx eax, word [rsp]
    mov [rbx + XA_FAMILY], eax
    movzx ecx, word [rsp + 2]
    xchg cl, ch
    mov [rbx + XA_PORT], ecx
    cmp eax, AF_INET
    je .four
    cmp eax, AF_INET6
    je .six
    cmp eax, AF_UNSPEC
    je .none
    cmp eax, AF_UNIX
    je .none
    mov rax, -EAFNOSUPPORT
    jmp .out
.four:
    mov rax, -EINVAL
    cmp r12d, 16
    jb .out
    mov eax, [rsp + 4]
    mov rdi, rbx
    call addr_set4
    jmp .none
.six:
    mov rax, -EINVAL
    cmp r12d, 24
    jb .out
    mov rax, [rsp + 8]
    mov [rbx], rax
    mov rax, [rsp + 16]
    mov [rbx + 8], rax
.none:
    xor eax, eax
.out:
    add rsp, 32
    pop r12
    pop rbx
    ret

; lx_sa_write(RDI = a user sockaddr, or 0 for none, RSI = its length's user
; pointer, RDX = an address (16 bytes), ECX = a port, R8D = the family to
; say it as) -> RAX = 0 or -errno: as much of it as there is room for, and
; its whole length. AF_INET6 says an IPv4 address as ::ffff:a.b.c.d.
lx_sa_write:
    xor eax, eax
    test rdi, rdi
    jz .ret
    push rbx
    push r12
    push r13
    sub rsp, 48                         ; [rsp] = it, [rsp + 32] = room, [rsp + 40] = length
    mov r12, rdi
    mov r13, rsi
    mov rbx, rdx
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 24], rax
    mov [rsp], r8w
    xchg cl, ch
    mov [rsp + 2], cx
    mov eax, 2                          ; AF_UNIX: unnamed
    cmp r8d, AF_UNIX
    je .made
    cmp r8d, AF_INET6
    je .six
    mov eax, [rbx + 12]
    mov [rsp + 4], eax
    mov eax, 16
    jmp .made
.six:
    mov rax, [rbx]
    mov [rsp + 8], rax
    mov rax, [rbx + 8]
    mov [rsp + 16], rax
    mov eax, 28
.made:
    mov [rsp + 40], eax
    lea rdi, [rsp + 32]
    mov rsi, r13
    mov edx, 4
    call lx_copy_in
    test rax, rax
    jnz .out
    mov edx, [rsp + 32]
    mov rax, -EINVAL
    test edx, edx
    js .out
    cmp edx, [rsp + 40]
    jbe .room
    mov edx, [rsp + 40]
.room:
    test edx, edx
    jz .len
    mov rdi, r12
    mov rsi, rsp
    call lx_copy_out
    test rax, rax
    jnz .out
.len:
    mov rdi, r13
    mov esi, [rsp + 40]
    call lx_put32
.out:
    add rsp, 48
    pop r13
    pop r12
    pop rbx
.ret:
    ret

; lx_our_addr(RDI = where, RSI = an address talked to): ours, toward it.
; Preserves others.
lx_our_addr:
    push rax
    push rsi
    call addr_is4
    jne .six
    mov eax, [net_ip]
    call addr_set4
    jmp .out
.six:
    lea rsi, [ip6_gua]
    call addr_copy
.out:
    pop rsi
    pop rax
    ret

; lx_unreachable(RSI = an address) -> CF if it is nobody Axiom can reach:
; any (0.0.0.0, ::) or loopback (127/8, ::1), there being no loopback here.
; Preserves all.
lx_unreachable:
    push rax
    call addr_is4
    jne .six
    mov eax, [rsi + 12]
    test eax, eax
    jz .yes
    cmp al, 127
    je .yes
    jmp .no
.six:
    cmp qword [rsi], 0
    jne .no
    mov rax, [rsi + 8]
    test rax, rax
    jz .yes
    bswap rax
    cmp rax, 1
    je .yes
.no:
    pop rax
    clc
    ret
.yes:
    pop rax
    stc
    ret

; lx_sock_deadline(RAX = nanoseconds from now, 0 for none) -> RAX = a TSC
; deadline, 0 for none. Preserves others.
lx_sock_deadline:
    test rax, rax
    jz .out
    call lx_ns_tsc
.out:
    ret

; lx_sock_wait(RDI = where the lx_poll_gen seen before looking is, RSI = a
; TSC deadline or 0) -> RAX = 0 to look again, -EAGAIN at the deadline,
; -ERESTARTSYS if a signal came (-EINTR with a deadline: SO_RCVTIMEO's)
lx_sock_wait:
    push rsi
    mov rcx, rsi
    mov rdx, rdi
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    call wq_wait_fn
    pop rsi
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jnz .signal
    test rsi, rsi
    jz .again
    RDTSC64
    cmp rax, rsi
    jb .again
    mov rax, -EAGAIN
    ret
.signal:
    mov rax, -ERESTARTSYS
    test rsi, rsi
    jz .out
    mov rax, -EINTR
.out:
    ret
.again:
    xor eax, eax
    ret

; lx_netw_errno(EAX = NETW_*) -> EAX = the errno Linux would say
lx_netw_errno:
    cmp eax, NETW_REFUSED
    je .refused
    cmp eax, NETW_RESET
    je .reset
    cmp eax, NETW_TIMEOUT
    je .timeout
    cmp eax, NETW_INUSE
    je .in_use
    cmp eax, NETW_DOWN
    je .down
    mov eax, EHOSTUNREACH
    ret
.refused:
    mov eax, ECONNREFUSED
    ret
.reset:
    mov eax, ECONNRESET
    ret
.timeout:
    mov eax, ETIMEDOUT
    ret
.in_use:
    mov eax, EADDRINUSE
    ret
.down:
    mov eax, ENETUNREACH
    ret

; lx_sk_errno(RAX = what sk_new_socket said, E_*) -> RAX = -errno
lx_sk_errno:
    cmp rax, E_NOMEM
    mov rax, -ENOMEM
    je .out
    mov rax, -ENOBUFS                   ; SK_MAX of them, Axiom's programs' too
.out:
    ret

; lx_sigpipe: SIGPIPE, to the running thread (a write with nobody to read it)
lx_sigpipe:
    call lx_cur_proc
    mov rdi, rax
    mov rsi, [gs:PC_CURRENT]
    mov esi, [rsi + TH_TID]
    mov edx, SIGPIPE_NUM
    jmp lx_signal_tid

; lx_port_take -> EAX = a port, from LX_PORT_FIRST on, round. Preserves others.
lx_port_take:
    mov eax, 1
    lock xadd [lx_port_next], eax
    and eax, LX_PORT_COUNT - 1
    add eax, LX_PORT_FIRST
    ret

; lx_iov_in(RDI = user iovecs, RSI = how many) -> RAX = a copy of them
; (kmalloc'd), or -errno
lx_iov_in:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    mov rax, -EMSGSIZE
    cmp r13, UIO_MAXIOV
    ja .out
    mov rdi, r13
    shl rdi, 4
    add rdi, 16
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdx, r13
    shl rdx, 4
    jz .done
    mov rdi, rbx
    mov rsi, r12
    call lx_copy_in
    test rax, rax
    jnz .fault
.done:
    mov rax, rbx
    jmp .out
.fault:
    push rax
    mov rdi, rbx
    call kfree
    pop rax
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  connect, bind, listen, accept
; -----------------------------------------------------------------------------

; connect(fd, addr, addrlen)
lx_sys_connect:
    push rbx
    push r12
    push r13
    sub rsp, 32                         ; the address (XA_*)
    mov r13, rsi
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    mov rdi, r13
    mov esi, edx
    mov rdx, rsp
    call lx_sa_read
    test rax, rax
    jnz .put
    mov eax, [r12 + XS_KIND]
    cmp eax, XSK_TCP
    je .tcp
    cmp eax, XSK_UDP
    je .udp
    mov rax, -EISCONN                   ; AF_UNIX: a pair is connected; nothing
    cmp qword [r12 + XS_PIN], 0         ; else has a name to connect to
    jne .put
    mov rax, -ENOENT
    jmp .put
.udp:
    mov rdi, rsp
    call lx_udp_connect
    jmp .put
.tcp:
    mov rdi, rsp
    call lx_tcp_connect
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; lx_tcp_connect(RBX = the file, R12 = its socket, RDI = where to (XA_*))
; -> RAX = 0 once connected, or -errno (-EINPROGRESS if it may not wait)
lx_tcp_connect:
    push r13
    push r14
    sub rsp, 16                         ; [rsp] = lx_poll_gen
    mov r13, rdi
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    call lx_tcp_settle
    mov rax, -EISCONN
    cmp dword [r12 + XS_STATE], XSS_CONNECTED
    je .unlock
    mov rax, -EALREADY
    cmp dword [r12 + XS_STATE], XSS_CONNECTING
    je .unlock
    mov rax, -EINVAL
    cmp dword [r12 + XS_STATE], XSS_LISTENING
    je .unlock
    xor eax, eax
    cmp dword [r13 + XA_FAMILY], AF_UNSPEC ; (nothing to undo)
    je .unlock
    mov rax, -EAFNOSUPPORT
    cmp dword [r13 + XA_FAMILY], AF_UNIX
    je .unlock
    mov eax, [r12 + XS_ERROR]           ; a failure not yet said: now
    test eax, eax
    jz .fresh
    mov dword [r12 + XS_ERROR], 0
    neg rax
    jmp .unlock
.fresh:
    mov rsi, r13
    call lx_unreachable
    mov rax, -ECONNREFUSED
    jc .unlock
    mov rax, -ENETUNREACH
    cmp dword [nic_count], 0
    je .unlock
    xor edi, edi
    call sk_new_socket
    cmp rax, E_ANY
    jae .no_object
    mov r14, rax                        ; R14 = the socket object
    mov eax, [r13 + XA_PORT]
    mov [r14 + SK_PORT], eax
    mov dword [r14 + SK_STATE], SKS_LOOKUP
    SPRINTF r14 + SK_HOST, "%A", r13    ; (an address: sk_begin looks nothing up)
    lea rdi, [r12 + XS_RADDR]
    mov rsi, r13
    call addr_copy
    mov eax, [r13 + XA_PORT]
    mov [r12 + XS_RPORT], eax
    mov rdi, [r12 + XS_OLDSK]
    call lx_sk_release
    mov rax, [r12 + XS_SK]
    mov [r12 + XS_OLDSK], rax
    mov [r12 + XS_SK], r14
    mov dword [r12 + XS_STATE], XSS_CONNECTING
    mov rdi, r14
    call lx_sk_start
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    mov rax, -EINPROGRESS
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .out
    mov rax, [r12 + XS_SNDTIMEO]
    call lx_sock_deadline
    mov r13, rax                        ; R13 = when to stop waiting, or 0
.wait:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    cmp dword [r14 + SK_STATE], SKS_OPEN
    jae .settle                         ; open, ended or failed
    mov rdi, rsp
    mov rsi, r13
    call lx_sock_wait
    test rax, rax
    jz .wait
    cmp rax, -EAGAIN
    mov rax, -EINPROGRESS               ; SO_SNDTIMEO: it goes on
    je .out
    mov rax, -EINTR                     ; a signal: never restarted, as Linux's
    jmp .out
.settle:
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    call lx_tcp_settle
    xor eax, eax
    cmp dword [r12 + XS_STATE], XSS_CONNECTED
    je .unlock
    mov eax, [r12 + XS_ERROR]
    mov dword [r12 + XS_ERROR], 0
    neg rax
    jmp .unlock
.no_object:
    call lx_sk_errno
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
.out:
    add rsp, 16
    pop r14
    pop r13
    ret

; lx_tcp_settle(R12 = a TCP socket): a connect that has finished, seen:
; connected, or failed (XS_ERROR says why). Preserves RBX, RBP, R12-R15.
lx_tcp_settle:
    cmp dword [r12 + XS_STATE], XSS_CONNECTING
    jne .out
    mov rdi, [r12 + XS_SK]
    mov eax, [rdi + SK_STATE]
    cmp eax, SKS_FAILED
    je .failed
    cmp eax, SKS_OPEN
    jb .out
    mov dword [r12 + XS_STATE], XSS_CONNECTED ; (open, or over already)
    mov rsi, [rdi + SK_TCP]
    test rsi, rsi
    jz .local
    mov eax, [rsi + TC_LPORT]
    mov [r12 + XS_LPORT], eax
.local:
    lea rdi, [r12 + XS_LADDR]
    lea rsi, [r12 + XS_RADDR]
    jmp lx_our_addr
.failed:
    mov eax, [rdi + SK_WHY]
    call lx_netw_errno
    mov [r12 + XS_ERROR], eax
    mov dword [r12 + XS_STATE], XSS_NEW
.out:
    ret

; lx_udp_connect(R12 = a UDP socket, RDI = whom (XA_*)) -> RAX = 0 or
; -errno: from it alone, to it unless said otherwise
lx_udp_connect:
    push r13
    mov r13, rdi
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    cmp dword [r13 + XA_FAMILY], AF_UNSPEC
    je .disconnect
    mov rax, -EAFNOSUPPORT
    cmp dword [r13 + XA_FAMILY], AF_UNIX
    je .unlock
    call lx_udp_autobind
    test rax, rax
    jnz .unlock
    lea rdi, [r12 + XS_RADDR]
    mov rsi, r13
    call addr_copy
    mov eax, [r13 + XA_PORT]
    mov [r12 + XS_RPORT], eax
    lea rdi, [r12 + XS_LADDR]
    lea rsi, [r12 + XS_RADDR]
    call lx_our_addr
    mov dword [r12 + XS_STATE], XSS_CONNECTED
    xor eax, eax
    jmp .unlock
.disconnect:
    mov dword [r12 + XS_STATE], XSS_NEW
    mov dword [r12 + XS_RPORT], 0
    xor eax, eax
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
    pop r13
    ret

; bind(fd, addr, addrlen)
lx_sys_bind:
    push rbx
    push r12
    push r13
    sub rsp, 32                         ; the address (XA_*)
    mov r13, rsi
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    mov rdi, r13
    mov esi, edx
    mov rdx, rsp
    call lx_sa_read
    test rax, rax
    jnz .put
    mov rax, -EROFS                     ; AF_UNIX: no name can be made
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .put
    mov rax, -EAFNOSUPPORT
    mov ecx, [rsp + XA_FAMILY]
    cmp ecx, AF_INET
    je .family
    cmp ecx, AF_INET6
    jne .put
.family:
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    mov rax, -EINVAL
    cmp dword [r12 + XS_LPORT], 0
    jne .unlock
    cmp dword [r12 + XS_STATE], XSS_NEW
    jne .unlock
    lea rdi, [r12 + XS_LADDR]
    mov rsi, rsp
    call addr_copy
    mov edi, [rsp + XA_PORT]
    cmp dword [r12 + XS_KIND], XSK_UDP
    je .udp
    test edi, edi                       ; TCP: the port it would listen on
    jnz .tcp_port
    call lx_port_take
    mov edi, eax
.tcp_port:
    mov [r12 + XS_LPORT], edi
    xor eax, eax
    jmp .unlock
.udp:
    call lx_udp_bind
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; listen(fd, backlog)
lx_sys_listen:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16                         ; [rsp] = lx_poll_gen, [rsp + 8] = how long
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    mov rax, -EOPNOTSUPP
    cmp dword [r12 + XS_KIND], XSK_TCP
    jne .put
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    xor eax, eax
    cmp dword [r12 + XS_STATE], XSS_LISTENING
    je .unlock
    mov rax, -EINVAL
    cmp dword [r12 + XS_STATE], XSS_NEW
    jne .unlock
    mov r13d, [r12 + XS_LPORT]          ; R13 = its port
    test r13d, r13d
    jnz .port
    call lx_port_take
    mov r13d, eax
.port:
    mov edi, SKF_LISTENER
    call sk_new_socket
    cmp rax, E_ANY
    jae .no_object
    mov r14, rax                        ; R14 = the socket object
    mov [r14 + SK_PORT], r13d
    mov dword [r14 + SK_STATE], SKS_LISTEN
    mov rdi, [r12 + XS_OLDSK]
    call lx_sk_release
    mov rax, [r12 + XS_SK]
    mov [r12 + XS_OLDSK], rax
    mov [r12 + XS_SK], r14
    mov rdi, r14
    call lx_sk_start
    mov eax, 2000000000                 ; the main loop says within 2 s
    call lx_ns_tsc
    mov [rsp + 8], rax
.wait:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    cmp qword [r14 + SK_LISTENER], 0
    jne .listening
    cmp dword [r14 + SK_STATE], SKS_FAILED
    je .failed
    RDTSC64
    cmp rax, [rsp + 8]
    jae .listening                      ; (not said yet: as if it listens)
    mov rdi, rsp
    mov rsi, [rsp + 8]
    call lx_sock_wait
    jmp .wait
.failed:
    mov eax, [r14 + SK_WHY]
    call lx_netw_errno
    neg rax
    jmp .unlock
.listening:
    mov [r12 + XS_LPORT], r13d
    mov dword [r12 + XS_STATE], XSS_LISTENING
    xor eax, eax
    jmp .unlock
.no_object:
    call lx_sk_errno
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; accept(fd, addr, addrlen)
lx_sys_accept:
    xor ecx, ecx
; accept4(fd, addr, addrlen, flags)
lx_sys_accept4:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64                         ; [rsp] = lx_poll_gen, [rsp + 8] = addr,
    mov [rsp + 8], rsi                  ; [rsp + 16] = addrlen, [rsp + 24] = deadline,
    mov [rsp + 16], rdx                 ; [rsp + 32] = who (16 bytes), [rsp + 48] = port
    mov r13d, ecx                       ; R13 = flags
    mov rax, -EINVAL
    test ecx, ~(O_NONBLOCK | O_CLOEXEC)
    jnz .out
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov r15, rax                        ; R15 = the file listening
    mov r12, [r15 + LF_PRIV]
    mov rax, -EOPNOTSUPP
    cmp dword [r12 + XS_KIND], XSK_TCP
    jne .put
    mov rax, -EINVAL
    cmp dword [r12 + XS_STATE], XSS_LISTENING
    jne .put
    mov rax, [r12 + XS_RCVTIMEO]
    call lx_sock_deadline
    mov [rsp + 24], rax
    mov rbx, [r12 + XS_SK]              ; RBX = the socket object listening
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    SK_LOCK
    mov ecx, [rbx + SK_ACN]
    test ecx, ecx
    jz .none
    mov r14, [rbx + SK_ACQ]             ; R14 = the oldest: the queue's reference, ours
    dec ecx
    mov [rbx + SK_ACN], ecx
    lea rdi, [rbx + SK_ACQ]
    lea rsi, [rdi + 8]
    rep movsq
    call sk_settle
    SK_UNLOCK
    mov edi, [r12 + XS_DOMAIN]
    mov esi, SOCK_STREAM
    mov edx, IPPROTO_TCP
    mov ecx, XSK_TCP
    call lx_sock_new
    test rax, rax
    jz .nomem
    mov [rax + XS_SK], r14
    mov dword [rax + XS_STATE], XSS_CONNECTED
    mov ecx, [r12 + XS_LPORT]
    mov [rax + XS_LPORT], ecx
    mov ecx, [r14 + SK_PORT]
    mov [rax + XS_RPORT], ecx
    mov [rsp + 48], ecx
    lea rdi, [rax + XS_RADDR]
    lea rsi, [r14 + SK_ADDR]
    call addr_copy
    lea rdi, [rsp + 32]
    call addr_copy
    mov r14, rax                        ; R14 = the new socket
    lea rdi, [r14 + XS_LADDR]
    lea rsi, [r14 + XS_RADDR]
    call lx_our_addr
    mov rdi, r14
    mov esi, r13d
    call lx_sock_open
    cmp rax, -4095
    jae .put
    mov r13, rax                        ; R13 = its descriptor
    mov rdi, [rsp + 8]
    mov rsi, [rsp + 16]
    lea rdx, [rsp + 32]
    mov ecx, [rsp + 48]
    mov r8d, [r12 + XS_DOMAIN]
    call lx_sa_write                    ; (nowhere to say it: taken all the same)
    mov rax, r13
    jmp .put
.nomem:
    mov rdi, r14
    call lx_sk_release
    mov rax, -ENOMEM
    jmp .put
.none:
    mov ecx, [rbx + SK_STATE]
    SK_UNLOCK
    mov rax, -EINVAL
    cmp ecx, SKS_FAILED
    je .put
    mov rax, -EAGAIN
    test dword [r15 + LF_FLAGS], O_NONBLOCK
    jnz .put
    mov rdi, rsp
    mov rsi, [rsp + 24]
    call lx_sock_wait
    test rax, rax
    jz .again
.put:
    mov rdi, r15
    call lf_put
.out:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; socketpair(domain, type, protocol, sv)
lx_sys_socketpair:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                         ; the two descriptors
    mov r12d, esi                       ; R12 = the type, with its flags
    mov r13, rcx                        ; R13 = sv
    mov rax, -EINVAL
    test esi, ~(SOCK_TYPE_MASK | O_NONBLOCK | O_CLOEXEC)
    jnz .out
    mov rax, -EOPNOTSUPP
    cmp edi, AF_INET
    je .out
    cmp edi, AF_INET6
    je .out
    mov rax, -EAFNOSUPPORT
    cmp edi, AF_UNIX
    jne .out
    mov rax, -EPROTONOSUPPORT
    test edx, edx
    jnz .out
    mov eax, esi
    and eax, SOCK_TYPE_MASK
    cmp eax, SOCK_STREAM
    je .type
    cmp eax, SOCK_DGRAM
    je .type
    cmp eax, SOCK_SEQPACKET
    mov rax, -ESOCKTNOSUPPORT
    jne .out
.type:
    call lx_pipe_new
    test rax, rax
    jz .nomem
    mov r14, rax                        ; R14 = a pipe from end 0 to end 1
    call lx_pipe_new
    test rax, rax
    jz .nomem_one
    mov r15, rax                        ; R15 = and back
    mov edi, AF_UNIX
    mov esi, r12d
    and esi, SOCK_TYPE_MASK
    xor edx, edx
    mov ecx, XSK_UNIX
    call lx_sock_new
    test rax, rax
    jz .nomem_two
    mov rbx, rax                        ; RBX = end 0
    mov [rbx + XS_POUT], r14
    mov [rbx + XS_PIN], r15
    mov dword [rbx + XS_STATE], XSS_CONNECTED
    call lx_sock_new
    test rax, rax
    jz .nomem_end
    mov [rax + XS_POUT], r15
    mov [rax + XS_PIN], r14
    mov dword [rax + XS_STATE], XSS_CONNECTED
    mov r14, rax                        ; R14 = end 1 (each end has its pipes now)
    mov rdi, rbx
    mov esi, r12d
    call lx_sock_open
    cmp rax, -4095
    jae .no_fd0
    mov [rsp], eax
    mov rdi, r14
    mov esi, r12d
    call lx_sock_open
    cmp rax, -4095
    jae .no_fd1
    mov [rsp + 4], eax
    mov rdi, r13
    mov rsi, rsp
    mov edx, 8
    call lx_copy_out
    test rax, rax
    jz .out
    mov rbx, rax                        ; (nowhere to say them: both closed)
    call lx_cur_proc
    mov rdi, rax
    mov esi, [rsp + 4]
    call lx_fd_close
    jmp .close_fd0
.no_fd1:
    mov rbx, rax
.close_fd0:
    call lx_cur_proc
    mov rdi, rax
    mov esi, [rsp]
    call lx_fd_close
    mov rax, rbx
    jmp .out
.no_fd0:
    mov rbx, rax                        ; (end 0 went with its file)
    mov rdi, r14
    call lx_sock_free
    mov rax, rbx
    jmp .out
.nomem_end:
    mov rdi, rbx                        ; end 0's halves, then end 1's
    call lx_sock_free
    mov rdi, r14
    xor esi, esi
    call lx_pipe_end
    mov rdi, r15
    mov esi, 1
    call lx_pipe_end
    jmp .nomem
.nomem_two:
    mov rdi, r15
    xor esi, esi
    call lx_pipe_end
    mov rdi, r15
    mov esi, 1
    call lx_pipe_end
.nomem_one:
    mov rdi, r14
    xor esi, esi
    call lx_pipe_end
    mov rdi, r14
    mov esi, 1
    call lx_pipe_end
.nomem:
    mov rax, -ENOMEM
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; shutdown(fd, how)
lx_sys_shutdown:
    push rbx
    push r12
    push r13
    mov r13d, esi
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    mov rax, -EINVAL
    cmp r13d, SHUT_RDWR
    ja .put
    inc r13d                            ; R13 = 1 reading, 2 writing, 3 both
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .unix
    mov rax, -ENOTCONN
    mov ecx, [r12 + XS_STATE]
    cmp ecx, XSS_CONNECTED
    je .connected
    cmp ecx, XSS_CONNECTING
    jne .unlock
.connected:
    cmp dword [r12 + XS_KIND], XSK_TCP
    jne .said
    test r13d, 2
    jz .said
    test dword [r12 + XS_SHUT], 2
    jnz .said
    push rbx
    mov rbx, [r12 + XS_SK]              ; a FIN once what was sent has gone
    lock or dword [rbx + SK_FLAGS], SKF_SHUT
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    call sk_kick
    pop rbx
    jmp .said
.unix:
    mov rax, -ENOTCONN
    cmp qword [r12 + XS_PIN], 0
    je .unlock
    test r13d, 1
    jz .unix_write
    test dword [r12 + XS_SHUT], 1
    jnz .unix_write
    mov rdi, [r12 + XS_PIN]
    xor esi, esi
    call lx_pipe_end
.unix_write:
    test r13d, 2
    jz .said
    test dword [r12 + XS_SHUT], 2
    jnz .said
    mov rdi, [r12 + XS_POUT]
    mov esi, 1
    call lx_pipe_end
.said:
    or [r12 + XS_SHUT], r13d
    call lx_poll_kick
    xor eax, eax
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
.put:
    mov rdi, rbx
    call lf_put
.out:
    pop r13
    pop r12
    pop rbx
    ret

; getsockname(fd, addr, addrlen)
lx_sys_getsockname:
    xor ecx, ecx
    jmp lx_sock_name

; getpeername(fd, addr, addrlen)
lx_sys_getpeername:
    mov ecx, 1
; lx_sock_name(EDI = fd, RSI = addr, RDX = addrlen, ECX = 1 for the other
; side's) -> RAX
lx_sock_name:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = the address, [rsp + 16] = the port
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    cmp dword [r12 + XS_KIND], XSK_TCP
    jne .settled
    call lx_tcp_settle
.settled:
    lea rsi, [r12 + XS_LADDR]
    mov ecx, [r12 + XS_LPORT]
    test r15d, r15d
    jz .copy
    mov rax, -ENOTCONN
    cmp dword [r12 + XS_STATE], XSS_CONNECTED
    jne .unlock
    lea rsi, [r12 + XS_RADDR]
    mov ecx, [r12 + XS_RPORT]
.copy:
    mov rdi, rsp
    call addr_copy
    mov [rsp + 16], ecx
    xor eax, eax
.unlock:
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
    test rax, rax
    jnz .put
    mov rdi, r13
    mov rsi, r14
    mov rdx, rsp
    mov ecx, [rsp + 16]
    mov r8d, [r12 + XS_DOMAIN]
    call lx_sa_write
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Options
; -----------------------------------------------------------------------------

; lx_sock_bool(EDI = level, ESI = name) -> EAX = its bit in XS_OPTS, CF if
; it is not one of those. Preserves others.
lx_sock_bool:
    push rcx
    lea rcx, [lx_sock_bools]
.each:
    cmp dword [rcx], -1
    je .none
    cmp [rcx], edi
    jne .next
    cmp [rcx + 4], esi
    je .found
.next:
    add rcx, 12
    jmp .each
.found:
    mov eax, [rcx + 8]
    pop rcx
    clc
    ret
.none:
    pop rcx
    stc
    ret

; setsockopt(fd, level, name, value, length)
lx_sys_setsockopt:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = the value, [rsp + 24] = its length,
    mov r13d, esi                       ; [rsp + 28] = the bit
    mov r14d, edx
    mov r15, rcx
    mov [rsp + 24], r8d
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    mov edi, r13d
    mov esi, r14d
    call lx_sock_bool
    jc .not_bool
    mov [rsp + 28], eax
    mov rax, -EINVAL
    cmp dword [rsp + 24], 4
    jl .put
    mov rdi, rsp
    mov rsi, r15
    mov edx, 4
    call lx_copy_in
    test rax, rax
    jnz .put
    mov ecx, [rsp + 28]
    lock btr dword [r12 + XS_OPTS], ecx
    cmp dword [rsp], 0
    je .done
    lock bts dword [r12 + XS_OPTS], ecx
    jmp .done
.not_bool:
    cmp r13d, SOL_SOCKET
    jne .other
    lea r14, [r12 + XS_RCVTIMEO]
    cmp esi, SO_RCVTIMEO
    je .time
    cmp esi, SO_RCVTIMEO_NEW
    je .time
    lea r14, [r12 + XS_SNDTIMEO]
    cmp esi, SO_SNDTIMEO
    je .time
    cmp esi, SO_SNDTIMEO_NEW
    je .time
    jmp .done                           ; the rest: taken, nothing done
.other:
    test r13d, r13d                     ; IPPROTO_IP
    jz .done
    cmp r13d, IPPROTO_TCP
    je .done
    cmp r13d, IPPROTO_UDP
    je .done
    cmp r13d, IPPROTO_IPV6
    je .done
    mov rax, -ENOPROTOOPT
    jmp .put
.time:
    mov rax, -EINVAL                    ; a timeval
    cmp dword [rsp + 24], 16
    jl .put
    mov rdi, rsp
    mov rsi, r15
    mov edx, 16
    call lx_copy_in
    test rax, rax
    jnz .put
    mov rcx, [rsp]                      ; seconds
    mov rdx, [rsp + 8]                  ; microseconds
    mov rax, -EDOM
    test rcx, rcx
    js .put
    cmp rdx, 1000000
    jae .put
    mov rax, 1 << 32                    ; (a century and more: as never)
    cmp rcx, rax
    cmova rcx, rax
    imul rcx, rcx, 1000000000
    imul rdx, rdx, 1000
    add rcx, rdx
    mov [r14], rcx
.done:
    xor eax, eax
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; getsockopt(fd, level, name, value, length)
lx_sys_getsockopt:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = what it is (16 bytes), [rsp + 16] =
    mov r13d, esi                       ; room, [rsp + 20] = its size, [rsp + 24] =
    mov r14d, edx                       ; the length's pointer
    mov r15, rcx
    mov [rsp + 24], r8
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov r12, [rbx + LF_PRIV]
    lea rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    mov edx, 4
    call lx_copy_in
    test rax, rax
    jnz .put
    mov rax, -EINVAL
    cmp dword [rsp + 16], 0
    jl .put
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov dword [rsp + 20], 4
    mov edi, r13d
    mov esi, r14d
    call lx_sock_bool
    jc .not_bool
    bt dword [r12 + XS_OPTS], eax
    setc byte [rsp]
    jmp .say
.not_bool:
    cmp r13d, SOL_SOCKET
    je .socket
    mov rax, -ENOPROTOOPT
    cmp r13d, IPPROTO_TCP
    jne .put
    cmp r14d, TCP_MAXSEG
    jne .put
    mov ecx, 1460
    jmp .int
.socket:
    mov eax, r14d
    mov ecx, [r12 + XS_TYPE]
    cmp eax, SO_TYPE
    je .int
    mov ecx, [r12 + XS_DOMAIN]
    cmp eax, SO_DOMAIN
    je .int
    mov ecx, [r12 + XS_PROTO]
    cmp eax, SO_PROTOCOL
    je .int
    xor ecx, ecx
    cmp dword [r12 + XS_STATE], XSS_LISTENING
    sete cl
    cmp eax, SO_ACCEPTCONN
    je .int
    mov ecx, SK_BUF
    cmp eax, SO_SNDBUF
    je .int
    cmp eax, SO_RCVBUF
    jne .not_buf
    cmp dword [r12 + XS_KIND], XSK_UDP
    jne .int
    mov ecx, XS_QMAX
    jmp .int
.not_buf:
    cmp eax, SO_ERROR
    je .error
    mov rcx, [r12 + XS_RCVTIMEO]
    cmp eax, SO_RCVTIMEO
    je .timeval
    cmp eax, SO_RCVTIMEO_NEW
    je .timeval
    mov rcx, [r12 + XS_SNDTIMEO]
    cmp eax, SO_SNDTIMEO
    je .timeval
    cmp eax, SO_SNDTIMEO_NEW
    je .timeval
    cmp eax, SO_LINGER
    je .linger
    cmp eax, SO_PEERCRED
    je .cred
    mov rax, -ENOPROTOOPT
    jmp .put
.error:
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    cmp dword [r12 + XS_KIND], XSK_TCP
    jne .error_said
    call lx_tcp_settle
.error_said:
    xor ecx, ecx
    xchg ecx, [r12 + XS_ERROR]
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
.int:
    mov [rsp], ecx
    jmp .say
.timeval:
    mov rax, rcx
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rsp], rax                      ; seconds
    mov rax, rdx
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [rsp + 8], rax                  ; microseconds
    mov dword [rsp + 20], 16
    jmp .say
.linger:
    mov dword [rsp + 20], 8             ; off
    jmp .say
.cred:
    mov rax, -ENOPROTOOPT               ; AF_UNIX's: the other end is this process
    cmp dword [r12 + XS_KIND], XSK_UNIX ; (a pair is made by one); uid, gid 0
    jne .put
    call lx_cur_proc
    mov eax, [rax + LP_PID]
    mov [rsp], eax
    mov dword [rsp + 20], 12
.say:
    mov edx, [rsp + 16]                 ; as much as there is room for
    cmp edx, [rsp + 20]
    jbe .room
    mov edx, [rsp + 20]
.room:
    mov [rsp + 16], edx
    test edx, edx
    jz .len
    mov rdi, r15
    mov rsi, rsp
    call lx_copy_out
    test rax, rax
    jnz .put
.len:
    mov rdi, [rsp + 24]
    mov esi, [rsp + 16]
    call lx_put32
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Sending and receiving
; -----------------------------------------------------------------------------

; sendto(fd, buf, len, flags, addr, addrlen)
lx_sys_sendto:
    push rbx
    sub rsp, 16                         ; the one iovec
    mov [rsp], rsi
    mov [rsp + 8], rdx
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rdi, rsp
    mov esi, 1
    mov edx, ecx
    mov rcx, r8
    mov r8d, r9d
    call lx_sock_send
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 16
    pop rbx
    ret

; recvfrom(fd, buf, len, flags, addr, addrlen)
lx_sys_recvfrom:
    push rbx
    sub rsp, 16
    mov [rsp], rsi
    mov [rsp + 8], rdx
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rdi, rsp
    mov esi, 1
    mov edx, ecx
    mov rcx, r8
    mov r8, r9
    call lx_sock_recv
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 16
    pop rbx
    ret

; sendmsg(fd, msg, flags)
lx_sys_sendmsg:
    push rbx
    mov rbx, rsi
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov rbx, rax
    call lx_sock_sendmsg
    mov rdi, rbx
    call lf_put
.out:
    pop rbx
    ret

; recvmsg(fd, msg, flags)
lx_sys_recvmsg:
    push rbx
    mov rbx, rsi
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov rbx, rax
    call lx_sock_recvmsg
    mov rdi, rbx
    call lf_put
.out:
    pop rbx
    ret

; sendmmsg(fd, msgvec, vlen, flags)
lx_sys_sendmmsg:
    xor r8d, r8d
    jmp lx_mmsg

; recvmmsg(fd, msgvec, vlen, flags, timeout): each after the first only if
; it has come already (the timeout is not looked at)
lx_sys_recvmmsg:
    mov r8d, 1
; lx_mmsg(EDI = fd, RSI = mmsghdrs, EDX = how many, ECX = flags, R8D = 1 to
; receive) -> RAX = how many went, or -errno if none did
lx_mmsg:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rsi
    mov r13d, edx
    mov r14d, ecx
    mov [rsp + 8], r8d
    call lx_sock_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    cmp r13d, UIO_MAXIOV
    jbe .count
    mov r13d, UIO_MAXIOV
.count:
    xor r15d, r15d                      ; R15 = done
.each:
    cmp r15d, r13d
    jae .done
    mov rdi, r15
    shl rdi, 6
    add rdi, r12
    mov edx, r14d
    cmp dword [rsp + 8], 0
    je .send
    test r15d, r15d
    jz .first
    or edx, MSG_DONTWAIT
.first:
    call lx_sock_recvmsg
    jmp .one
.send:
    call lx_sock_sendmsg
.one:
    cmp rax, -4095
    jae .stopped
    mov rdi, r15
    shl rdi, 6
    add rdi, r12
    add rdi, 56                         ; msg_len
    mov esi, eax
    call lx_put32
    inc r15d
    jmp .each
.stopped:
    test r15d, r15d
    jz .put
.done:
    mov eax, r15d
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_sock_sendmsg(RBX = a socket's file, RDI = a user msghdr, EDX = flags)
; -> RAX (control messages are not looked at)
lx_sock_sendmsg:
    push r12
    push r13
    sub rsp, 64                         ; the msghdr
    mov r13d, edx
    mov rsi, rdi
    mov rdi, rsp
    mov edx, 56
    call lx_copy_in
    test rax, rax
    jnz .out
    mov rdi, [rsp + 16]                 ; its iovecs, in
    mov rsi, [rsp + 24]
    call lx_iov_in
    cmp rax, -4095
    jae .out
    mov r12, rax
    mov rdi, r12
    mov esi, [rsp + 24]
    mov edx, r13d
    mov rcx, [rsp]                      ; msg_name
    mov r8d, [rsp + 8]                  ; msg_namelen
    call lx_sock_send
    push rax
    mov rdi, r12
    call kfree
    pop rax
.out:
    add rsp, 64
    pop r13
    pop r12
    ret

; lx_sock_recvmsg(RBX = a socket's file, RDI = a user msghdr, EDX = flags)
; -> RAX; no control messages come
lx_sock_recvmsg:
    push r12
    push r13
    push r14
    sub rsp, 64                         ; the msghdr, then [rsp + 56] = msg_flags
    mov r14, rdi                        ; R14 = the user's msghdr
    mov r13d, edx
    mov rsi, rdi
    mov rdi, rsp
    mov edx, 56
    call lx_copy_in
    test rax, rax
    jnz .out
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    call lx_iov_in
    cmp rax, -4095
    jae .out
    mov r12, rax
    mov rdi, r12
    mov esi, [rsp + 24]
    mov edx, r13d
    mov rcx, [rsp]                      ; msg_name
    lea r8, [r14 + 8]                   ; msg_namelen, the user's
    call lx_sock_recv
    mov r13, rax                        ; R13 = what it says
    mov [rsp + 56], edx
    mov rdi, r12
    call kfree
    mov rax, r13
    cmp rax, -4095
    jae .out
    lea rdi, [r14 + 40]                 ; msg_controllen: none
    xor esi, esi
    call lx_put64
    test rax, rax
    jnz .out
    lea rdi, [r14 + 48]
    mov esi, [rsp + 56]
    call lx_put32
    test rax, rax
    jnz .out
    mov rax, r13
.out:
    add rsp, 64
    pop r14
    pop r13
    pop r12
    ret

; (LFO_READ) RBX = a socket's file, RSI = user buffer, RDX = bytes
lx_sock_read:
    sub rsp, 16
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov rdi, rsp
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call lx_sock_recv
    add rsp, 16
    ret

; (LFO_WRITE)
lx_sock_write:
    sub rsp, 16
    mov [rsp], rsi
    mov [rsp + 8], rdx
    mov rdi, rsp
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    call lx_sock_send
    add rsp, 16
    ret

; lx_sock_send(RBX = a socket's file, RDI = iovecs (the kernel's), ESI = how
; many, EDX = MSG_*, RCX = where to (a user sockaddr) or 0, R8D = its
; length) -> RAX = bytes sent, or -errno
lx_sock_send:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = flags for each piece, [rsp + 8] =
    mov r12, [rbx + LF_PRIV]            ; the deadline, [rsp + 16] = which piece,
    mov r13, rdi                        ; [rsp + 24] = its bytes
    mov r14d, esi
    mov eax, edx
    and eax, MSG_NOSIGNAL
    test edx, MSG_DONTWAIT
    jz .nonblock
    or eax, O_NONBLOCK
.nonblock:
    mov r9d, [rbx + LF_FLAGS]
    and r9d, O_NONBLOCK
    or eax, r9d
    mov [rsp], eax
    cmp dword [r12 + XS_KIND], XSK_UDP
    jne .stream
    mov rdi, r13
    mov esi, r14d
    mov rdx, rcx
    mov ecx, r8d
    call lx_udp_send
    jmp .out
.stream:
    mov rax, [r12 + XS_SNDTIMEO]
    call lx_sock_deadline
    mov [rsp + 8], rax
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .unix
    mov eax, [r12 + XS_STATE]
    cmp eax, XSS_CONNECTING
    je .pieces
    cmp eax, XSS_CONNECTED
    je .pieces
    mov eax, [r12 + XS_ERROR]           ; a connect that failed says so
    test eax, eax
    jnz .error
    mov rax, -ENOTCONN
    cmp dword [r12 + XS_STATE], XSS_LISTENING
    je .out
    jmp .broken
.unix:
    mov rax, -ENOTCONN
    cmp qword [r12 + XS_POUT], 0
    je .out
    test dword [r12 + XS_SHUT], 2
    jz .pieces
.broken:
    test dword [rsp], MSG_NOSIGNAL
    jnz .epipe
    call lx_sigpipe
.epipe:
    mov rax, -EPIPE
    jmp .out
.error:
    mov dword [r12 + XS_ERROR], 0
    neg rax
    jmp .out
.pieces:
    xor r15d, r15d                      ; R15 = sent
    mov qword [rsp + 16], 0
.piece:
    mov rcx, [rsp + 16]
    cmp ecx, r14d
    jae .done
    inc qword [rsp + 16]
    shl rcx, 4
    mov rsi, [r13 + rcx]
    mov rdx, [r13 + rcx + 8]
    test rdx, rdx
    jz .piece
    mov [rsp + 24], rdx
    mov ecx, [rsp]
    mov r8, [rsp + 8]
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .to_pipe
    call lx_tcp_put
    jmp .sent
.to_pipe:
    mov rdi, [r12 + XS_POUT]
    call lx_pipe_wr
.sent:
    cmp rax, -4095
    jae .failed
    add r15, rax
    cmp rax, [rsp + 24]
    jb .done                            ; short: no more now
    jmp .piece
.failed:
    test r15, r15
    jz .out
.done:
    mov rax, r15
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; lx_sock_recv(RBX = a socket's file, RDI = iovecs (the kernel's), ESI = how
; many, EDX = MSG_*, RCX = where to say who sent it (a user sockaddr) or 0,
; R8 = its length's user pointer) -> RAX = bytes, or -errno; RDX = msg_flags
lx_sock_recv:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = flags for each piece, [rsp + 8] =
    mov r12, [rbx + LF_PRIV]            ; the deadline, [rsp + 16] = the name, then
    mov r13, rdi                        ; which piece, [rsp + 24] = the name's length,
    mov r14d, esi                       ; then the piece's bytes
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    mov eax, edx
    and eax, MSG_PEEK | MSG_WAITALL | MSG_TRUNC
    test edx, MSG_DONTWAIT
    jz .nonblock
    or eax, O_NONBLOCK
.nonblock:
    mov r9d, [rbx + LF_FLAGS]
    and r9d, O_NONBLOCK
    or eax, r9d
    mov [rsp], eax
    mov rax, [r12 + XS_RCVTIMEO]
    call lx_sock_deadline
    mov [rsp + 8], rax
    cmp dword [r12 + XS_KIND], XSK_UDP
    jne .stream
    mov rdi, r13
    mov esi, r14d
    mov edx, [rsp]
    mov rcx, [rsp + 16]
    mov r8, [rsp + 24]
    mov r9, [rsp + 8]
    call lx_udp_recv
    jmp .out_flags
.stream:
    cmp qword [rsp + 16], 0             ; a stream's bytes have no name
    je .named
    mov rdi, [rsp + 24]
    xor esi, esi
    call lx_put32
    test rax, rax
    jnz .out
.named:
    mov rax, -ENOTCONN
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .unix
    mov ecx, [r12 + XS_STATE]
    cmp ecx, XSS_CONNECTING
    je .pieces
    cmp ecx, XSS_CONNECTED
    je .pieces
    jmp .out
.unix:
    cmp qword [r12 + XS_PIN], 0
    je .out
    xor eax, eax
    test dword [r12 + XS_SHUT], 1
    jnz .out
.pieces:
    xor r15d, r15d                      ; R15 = received
    mov qword [rsp + 16], 0
.piece:
    mov rcx, [rsp + 16]
    cmp ecx, r14d
    jae .done
    inc qword [rsp + 16]
    shl rcx, 4
    mov rsi, [r13 + rcx]
    mov rdx, [r13 + rcx + 8]
    test rdx, rdx
    jz .piece
    mov [rsp + 24], rdx
    mov ecx, [rsp]
    mov r8, [rsp + 8]
    cmp dword [r12 + XS_KIND], XSK_UNIX
    je .from_pipe
    call lx_tcp_get
    jmp .got
.from_pipe:
    mov rdi, [r12 + XS_PIN]
    call lx_pipe_rd
.got:
    cmp rax, -4095
    jae .failed
    add r15, rax
    cmp rax, [rsp + 24]
    jb .done
    test dword [rsp], MSG_PEEK
    jnz .done
    or dword [rsp], O_NONBLOCK          ; the rest: what has come already
    jmp .piece
.failed:
    test r15, r15
    jz .out
.done:
    mov rax, r15
.out:
    xor edx, edx
.out_flags:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; lx_tcp_put(R12 = a TCP socket, RSI = user bytes, RDX = how many, ECX =
; O_NONBLOCK | MSG_NOSIGNAL, R8 = a TSC deadline or 0) -> RAX = bytes taken
; (all of them, unless it may not wait), or -errno
lx_tcp_put:
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = lx_poll_gen, [rsp + 4] = flags,
    mov [rsp + 4], ecx                  ; [rsp + 8] = the deadline, [rsp + 16] =
    mov [rsp + 8], r8                   ; bytes this time
    mov r13, rsi
    mov r14, rdx
    xor r15d, r15d                      ; R15 = taken
    mov rbx, [r12 + XS_SK]              ; RBX = the socket object
.again:
    mov eax, [lx_poll_gen]              ; (before looking: nothing missed)
    mov [rsp], eax
    cmp r15, r14
    jae .done
    xor ecx, ecx
    call sk_take
    SK_LOCK
    mov eax, [rbx + SK_STATE]
    cmp eax, SKS_FAILED
    je .failed
    cmp eax, SKS_ENDED
    je .broken
    test dword [rbx + SK_FLAGS], SKF_SHUT | SKF_NOSEND
    jnz .broken
    xor edx, edx                        ; EDX = room: none until it is open
    cmp eax, SKS_OPEN
    jne .room
    mov edx, SK_BUF
    sub edx, [rbx + SK_TX_LEN]
.room:
    mov eax, [rbx + SK_TX_HEAD]
    add eax, [rbx + SK_TX_LEN]
    and eax, SK_BUF - 1                 ; EAX = where
    SK_UNLOCK
    test edx, edx
    jz .full
    mov rcx, r14
    sub rcx, r15
    cmp rcx, rdx
    cmova rcx, rdx
    mov [rsp + 16], rcx                 ; what goes in
    mov edx, SK_BUF
    sub edx, eax
    cmp rdx, rcx
    cmova rdx, rcx                      ; RDX = to the ring's end
    mov rdi, [rbx + SK_TX]
    add rdi, rax
    lea rsi, [r13 + r15]
    push rdx
    call lx_copy_in
    pop rdx
    test rax, rax
    jnz .fault
    mov rcx, [rsp + 16]
    sub rcx, rdx
    jz .copied
    mov rdi, [rbx + SK_TX]              ; then from its start
    lea rsi, [r13 + r15]
    add rsi, rdx
    mov rdx, rcx
    call lx_copy_in
    test rax, rax
    jnz .fault
.copied:
    mov rcx, [rsp + 16]
    SK_LOCK
    add [rbx + SK_TX_LEN], ecx
    call sk_settle
    SK_UNLOCK
    call sk_kick
    add r15, [rsp + 16]
    xor ecx, ecx
    call sk_give
    jmp .again
.full:
    xor ecx, ecx
    call sk_give
    mov rax, -EAGAIN
    test dword [rsp + 4], O_NONBLOCK
    jnz .partial
    mov rdi, rsp
    mov rsi, [rsp + 8]
    call lx_sock_wait
    test rax, rax
    jz .again
    jmp .partial
.failed:
    mov eax, [rbx + SK_WHY]
    SK_UNLOCK
    call lx_netw_errno
    neg rax
    push rax
    xor ecx, ecx
    call sk_give
    pop rax
    jmp .partial
.broken:
    SK_UNLOCK
    xor ecx, ecx
    call sk_give
    test r15, r15
    jnz .done
    test dword [rsp + 4], MSG_NOSIGNAL
    jnz .epipe
    call lx_sigpipe
.epipe:
    mov rax, -EPIPE
    jmp .out
.fault:
    xor ecx, ecx
    call sk_give
    mov rax, -EFAULT
.partial:
    test r15, r15
    jz .out
.done:
    mov rax, r15
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; lx_tcp_get(R12 = a TCP socket, RSI = user buffer, RDX = room, ECX =
; O_NONBLOCK | MSG_PEEK | MSG_WAITALL, R8 = a TSC deadline or 0) -> RAX =
; bytes, 0 at the end, or -errno. A failure is said once, then the end.
lx_tcp_get:
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 32                         ; as lx_tcp_put's
    mov [rsp + 4], ecx
    mov [rsp + 8], r8
    mov r13, rsi
    mov r14, rdx
    xor r15d, r15d                      ; R15 = received
    mov rbx, [r12 + XS_SK]
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    cmp r15, r14
    jae .done
    test dword [r12 + XS_SHUT], 1
    jnz .done
    mov ecx, 1
    call sk_take
    SK_LOCK
    mov eax, [rbx + SK_RX_HEAD]
    mov edx, [rbx + SK_RX_LEN]
    mov r8d, [rbx + SK_STATE]
    mov r9d, [rbx + SK_FLAGS]
    SK_UNLOCK
    test edx, edx
    jnz .some
    mov ecx, 1
    call sk_give
    test r9d, SKF_RXEND
    jnz .done
    cmp r8d, SKS_ENDED
    je .done
    cmp r8d, SKS_FAILED
    je .failed
    test r15, r15                       ; something already: that, unless all
    jz .none                            ; of it is wanted
    test dword [rsp + 4], MSG_WAITALL
    jz .done
.none:
    mov rax, -EAGAIN
    test dword [rsp + 4], O_NONBLOCK
    jnz .partial
    mov rdi, rsp
    mov rsi, [rsp + 8]
    call lx_sock_wait
    test rax, rax
    jz .again
    jmp .partial
.failed:
    lock bts dword [r12 + XS_SAID], 0
    jc .done
    mov eax, [rbx + SK_WHY]
    call lx_netw_errno
    neg rax
    jmp .partial
.some:
    mov rcx, r14
    sub rcx, r15
    cmp rcx, rdx
    cmova rcx, rdx
    mov [rsp + 16], rcx                 ; what comes out
    mov edx, SK_BUF
    sub edx, eax
    cmp rdx, rcx
    cmova rdx, rcx                      ; RDX = to the ring's end
    lea rdi, [r13 + r15]
    mov rsi, [rbx + SK_RX]
    add rsi, rax
    push rdx
    call lx_copy_out
    pop rdx
    test rax, rax
    jnz .fault
    mov rcx, [rsp + 16]
    sub rcx, rdx
    jz .copied
    lea rdi, [r13 + r15]                ; then from its start
    add rdi, rdx
    mov rsi, [rbx + SK_RX]
    mov rdx, rcx
    call lx_copy_out
    test rax, rax
    jnz .fault
.copied:
    mov rcx, [rsp + 16]
    add r15, rcx
    test dword [rsp + 4], MSG_PEEK
    jnz .peeked
    SK_LOCK
    mov eax, [rbx + SK_RX_HEAD]
    add eax, ecx
    and eax, SK_BUF - 1
    mov [rbx + SK_RX_HEAD], eax
    sub [rbx + SK_RX_LEN], ecx
    call sk_settle
    SK_UNLOCK
    lock add [rbx + SK_FREED], ecx      ; TCP may offer it again
    call sk_kick
    mov ecx, 1
    call sk_give
    test dword [rsp + 4], MSG_WAITALL
    jnz .again
    jmp .done
.peeked:
    mov ecx, 1
    call sk_give
    jmp .done
.fault:
    mov ecx, 1
    call sk_give
    mov rax, -EFAULT
.partial:
    test r15, r15
    jz .out
.done:
    mov rax, r15
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  UDP
; -----------------------------------------------------------------------------

; lx_udp_autobind(R12 = a UDP socket, its XS_LOCK held) -> RAX = 0, or
; -errno: a port, if it has none
lx_udp_autobind:
    xor eax, eax
    cmp dword [r12 + XS_LPORT], 0
    jne .out
    xor edi, edi
    jmp lx_udp_bind
.out:
    ret

; lx_udp_bind(R12 = a UDP socket, its XS_LOCK held, EDI = a port, 0 for
; any) -> RAX = 0, or -errno: that port its, and on lx_udp_list
lx_udp_bind:
    mov rax, -EINVAL
    cmp dword [r12 + XS_LPORT], 0
    jne .ret
    push rbx
    mov ebx, edi
    UDP_LOCK
    test ebx, ebx
    jnz .given
    mov ecx, LX_PORT_COUNT
.pick:
    call lx_port_take
    mov edi, eax
    call lx_udp_used
    test rax, rax
    jz .take
    dec ecx
    jnz .pick
    mov rax, -EADDRINUSE                ; every one
    jmp .unlock
.given:
    mov edi, ebx
    call lx_udp_used
    test rax, rax
    mov rax, -EADDRINUSE
    jnz .unlock
.take:
    mov [r12 + XS_LPORT], edi
    mov rax, [lx_udp_list]
    mov [r12 + XS_NEXT], rax
    mov [lx_udp_list], r12
    xor eax, eax
.unlock:
    UDP_UNLOCK
    pop rbx
.ret:
    ret

; lx_udp_used(EDI = a port), lx_udp_lock held -> RAX = the socket that has
; it, or 0. Preserves others.
lx_udp_used:
    mov rax, [lx_udp_list]
.each:
    test rax, rax
    jz .out
    cmp [rax + XS_LPORT], edi
    je .out
    mov rax, [rax + XS_NEXT]
    jmp .each
.out:
    ret

; lx_udp_unbind(RBX = a UDP socket, its last reference gone): off
; lx_udp_list, and what came for it let go
lx_udp_unbind:
    cmp dword [rbx + XS_LPORT], 0
    je .out
    UDP_LOCK
    lea rax, [lx_udp_list]              ; RAX = where the link to it is
.find:
    mov rcx, [rax]
    test rcx, rcx
    jz .gone
    cmp rcx, rbx
    je .found
    lea rax, [rcx + XS_NEXT]
    jmp .find
.found:
    mov rcx, [rbx + XS_NEXT]
    mov [rax], rcx
.gone:
    mov rdi, [rbx + XS_QHEAD]
    mov qword [rbx + XS_QHEAD], 0
    mov qword [rbx + XS_QTAIL], 0
    UDP_UNLOCK
.free:
    test rdi, rdi
    jz .out
    push qword [rdi + XD_NEXT]
    call kfree
    pop rdi
    jmp .free
.out:
    ret

; lx_udp_send(R12 = a UDP socket, RDI = iovecs (the kernel's), ESI = how
; many, RDX = where to (a user sockaddr) or 0 for whom it is connected to,
; ECX = its length) -> RAX = bytes, or -errno: one datagram, for the main
; loop to send
lx_udp_send:
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 48                         ; [rsp] = where to (XA_*), [rsp + 32] =
    mov r13, rdi                        ; which piece, [rsp + 40] = how far
    mov r14d, esi
    test rdx, rdx
    jz .connected
    mov rdi, rdx
    mov esi, ecx
    mov rdx, rsp
    call lx_sa_read
    test rax, rax
    jnz .out
    mov rax, -EAFNOSUPPORT
    mov ecx, [rsp + XA_FAMILY]
    cmp ecx, AF_INET
    je .to
    cmp ecx, AF_INET6
    je .to
    jmp .out
.connected:
    mov rax, -EDESTADDRREQ
    cmp dword [r12 + XS_STATE], XSS_CONNECTED
    jne .out
    mov rdi, rsp
    lea rsi, [r12 + XS_RADDR]
    call addr_copy
    mov eax, [r12 + XS_RPORT]
    mov [rsp + XA_PORT], eax
.to:
    mov rax, -EPIPE
    test dword [r12 + XS_SHUT], 2
    jnz .out
    mov rax, -EINVAL
    cmp dword [rsp + XA_PORT], 0
    je .out
    mov rax, -ENETUNREACH
    cmp dword [nic_count], 0
    je .out
    xor r15d, r15d                      ; R15 = its bytes, all the pieces'
    xor ecx, ecx
.sum:
    cmp ecx, r14d
    jae .summed
    mov rax, rcx
    shl rax, 4
    mov rdx, [r13 + rax + 8]
    cmp rdx, 65536
    jae .big
    add r15, rdx
    inc ecx
    jmp .sum
.summed:
    mov eax, UDP4_MAX
    mov rsi, rsp
    call addr_is4
    je .max
    mov eax, UDP6_MAX
.max:
    cmp r15, rax
    ja .big
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_lock
    call lx_udp_autobind
    push rax
    lea rdi, [r12 + XS_LOCK]
    call lx_mutex_unlock
    pop rax
    test rax, rax
    jnz .out
    lea rdi, [r15 + XD_DATA]
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax                        ; RBX = the datagram
    lea rdi, [rbx + XD_ADDR]
    mov rsi, rsp
    call addr_copy
    mov eax, [rsp + XA_PORT]
    mov [rbx + XD_PORT], eax
    mov eax, [r12 + XS_LPORT]
    mov [rbx + XD_SPORT], eax
    mov [rbx + XD_LEN], r15d
    mov qword [rsp + 32], 0
    mov qword [rsp + 40], 0
.gather:
    mov rcx, [rsp + 32]
    cmp ecx, r14d
    jae .gathered
    inc qword [rsp + 32]
    shl rcx, 4
    mov rdx, [r13 + rcx + 8]
    test rdx, rdx
    jz .gather
    mov rsi, [r13 + rcx]
    lea rdi, [rbx + XD_DATA]
    add rdi, [rsp + 40]
    add [rsp + 40], rdx
    call lx_copy_in
    test rax, rax
    jz .gather
    push rax
    mov rdi, rbx
    call kfree
    pop rax
    jmp .out
.gathered:
    UDP_LOCK
    mov qword [rbx + XD_NEXT], 0
    mov rax, [lx_udp_txt]
    test rax, rax
    jz .first
    mov [rax + XD_NEXT], rbx
    jmp .queued
.first:
    mov [lx_udp_txq], rbx
.queued:
    mov [lx_udp_txt], rbx
    UDP_UNLOCK
    call sk_kick
    mov rax, r15
    jmp .out
.big:
    mov rax, -EMSGSIZE
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; lx_udp_recv(R12 = a UDP socket, RDI = iovecs (the kernel's), ESI = how
; many, EDX = O_NONBLOCK | MSG_PEEK | MSG_TRUNC, RCX = where to say who
; sent it, or 0, R8 = its length's user pointer, R9 = a TSC deadline or 0)
; -> RAX = bytes (MSG_TRUNC: the datagram's), or -errno; RDX = msg_flags
lx_udp_recv:
    push rbx
    push r13
    push r14
    push r15
    sub rsp, 48                         ; [rsp] = lx_poll_gen, [rsp + 4] = flags,
    mov r13, rdi                        ; [rsp + 8] = deadline, [rsp + 16] = name,
    mov r14d, esi                       ; [rsp + 24] = its length, [rsp + 32] = bytes
    mov [rsp + 4], edx                  ; this piece, [rsp + 40] = which piece
    mov [rsp + 8], r9
    mov [rsp + 16], rcx
    mov [rsp + 24], r8
    lea rdi, [r12 + XS_RLOCK]
    call lx_mutex_lock
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    UDP_LOCK
    mov rbx, [r12 + XS_QHEAD]           ; (only this receiver takes it off)
    UDP_UNLOCK
    test rbx, rbx
    jnz .some
    xor eax, eax
    test dword [r12 + XS_SHUT], 1
    jnz .said
    mov rax, -EAGAIN
    test dword [rsp + 4], O_NONBLOCK
    jnz .said
    lea rdi, [r12 + XS_RLOCK]
    call lx_mutex_unlock
    mov rdi, rsp
    mov rsi, [rsp + 8]
    call lx_sock_wait
    push rax
    lea rdi, [r12 + XS_RLOCK]
    call lx_mutex_lock
    pop rax
    test rax, rax
    jz .again
    jmp .said
.some:
    xor r15d, r15d                      ; R15 = copied
    mov qword [rsp + 40], 0
.piece:
    mov rcx, [rsp + 40]
    cmp ecx, r14d
    jae .scattered
    inc qword [rsp + 40]
    mov eax, [rbx + XD_LEN]
    sub rax, r15
    jz .scattered
    shl rcx, 4
    mov rdx, [r13 + rcx + 8]
    cmp rdx, rax
    cmova rdx, rax
    test rdx, rdx
    jz .piece
    mov [rsp + 32], rdx
    mov rdi, [r13 + rcx]
    lea rsi, [rbx + r15 + XD_DATA]
    call lx_copy_out
    test rax, rax
    jnz .said
    add r15, [rsp + 32]
    jmp .piece
.scattered:
    mov rdi, [rsp + 16]
    mov rsi, [rsp + 24]
    lea rdx, [rbx + XD_ADDR]
    mov ecx, [rbx + XD_PORT]
    mov r8d, [r12 + XS_DOMAIN]
    call lx_sa_write
    test rax, rax
    jnz .said
    xor edx, edx
    mov eax, [rbx + XD_LEN]
    cmp r15, rax
    jae .whole
    mov edx, MSG_TRUNC                  ; more than there was room for
    test dword [rsp + 4], MSG_TRUNC
    jnz .whole
    mov rax, r15
.whole:
    mov [rsp + 32], rax
    mov [rsp + 40], rdx
    test dword [rsp + 4], MSG_PEEK
    jnz .kept
    UDP_LOCK
    mov rax, [rbx + XD_NEXT]
    mov [r12 + XS_QHEAD], rax
    test rax, rax
    jnz .popped
    mov qword [r12 + XS_QTAIL], 0
.popped:
    mov eax, [rbx + XD_LEN]
    sub [r12 + XS_QBYTES], eax
    UDP_UNLOCK
    mov rdi, rbx
    call kfree
.kept:
    mov rax, [rsp + 32]
    mov rdx, [rsp + 40]
    jmp .unlock
.said:
    xor edx, edx
.unlock:
    push rax
    push rdx
    lea rdi, [r12 + XS_RLOCK]
    call lx_mutex_unlock
    pop rdx
    pop rax
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; lx_udp_input(EAX = the port it came to, RDX = from whom (16 bytes), RSI =
; its payload, ECX = the payload's bytes; its UDP header at RSI - 8): from
; udp_input and udp6_input, on the main loop -> CF if a Linux socket has
; that port (it has the datagram now, or did not want it). Preserves all.
lx_udp_input:
    cmp qword [lx_udp_list], 0
    jne .some
    clc
    ret
.some:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12d, eax                       ; R12 = the port
    mov r13, rdx                        ; R13 = from whom
    lea rdi, [rcx + XD_DATA]
    call kmalloc
    test rax, rax
    jz .not_taken
    mov rbx, rax                        ; RBX = the datagram
    mov [rbx + XD_LEN], ecx
    movzx eax, word [rsi - 8]
    xchg al, ah
    mov [rbx + XD_PORT], eax
    lea rdi, [rbx + XD_ADDR]
    push rsi
    mov rsi, r13
    call addr_copy
    pop rsi
    lea rdi, [rbx + XD_DATA]
    rep movsb
    UDP_LOCK
    mov edi, r12d
    call lx_udp_used
    test rax, rax
    jz .nobody
    cmp dword [rax + XS_STATE], XSS_CONNECTED ; connected: from that one only
    jne .wanted
    mov ecx, [rbx + XD_PORT]
    cmp ecx, [rax + XS_RPORT]
    jne .unwanted
    lea rsi, [rbx + XD_ADDR]
    lea rdi, [rax + XS_RADDR]
    call addr_eq
    jne .unwanted
.wanted:
    mov ecx, [rbx + XD_LEN]
    add ecx, [rax + XS_QBYTES]
    cmp ecx, XS_QMAX
    ja .unwanted                        ; (too much waits: dropped, as UDP may be)
    mov [rax + XS_QBYTES], ecx
    mov qword [rbx + XD_NEXT], 0
    mov rcx, [rax + XS_QTAIL]
    test rcx, rcx
    jz .first
    mov [rcx + XD_NEXT], rbx
    jmp .queued
.first:
    mov [rax + XS_QHEAD], rbx
.queued:
    mov [rax + XS_QTAIL], rbx
    UDP_UNLOCK
    call lx_poll_kick
    stc
    jmp .out
.unwanted:
    UDP_UNLOCK
    mov rdi, rbx
    call kfree
    stc
    jmp .out
.nobody:
    UDP_UNLOCK
    mov rdi, rbx
    call kfree
.not_taken:
    clc
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; lx_udp_tick: from net_service, what Linux programs sent, sent
lx_udp_tick:
    cmp qword [lx_udp_txq], 0
    jne .some
    ret
.some:
    push rbx
.next:
    UDP_LOCK
    mov rbx, [lx_udp_txq]
    test rbx, rbx
    jz .taken
    mov rax, [rbx + XD_NEXT]
    mov [lx_udp_txq], rax
    test rax, rax
    jnz .taken
    mov qword [lx_udp_txt], 0
.taken:
    UDP_UNLOCK
    test rbx, rbx
    jz .out
    lea rsi, [rbx + XD_ADDR]
    call addr_is4
    jne .six
    lea rdi, [net_frame + UDP_PAYLOAD]
    lea rsi, [rbx + XD_DATA]
    mov ecx, [rbx + XD_LEN]
    rep movsb
    mov edi, [rbx + XD_ADDR + 12]
    mov esi, [rbx + XD_SPORT]
    mov edx, [rbx + XD_PORT]
    mov ecx, [rbx + XD_LEN]
    call udp_send                       ; (no route: lost, as UDP may be)
    jmp .sent
.six:
    lea rdi, [net_frame + UDP6_PAYLOAD]
    lea rsi, [rbx + XD_DATA]
    mov ecx, [rbx + XD_LEN]
    rep movsb
    lea rdi, [rbx + XD_ADDR]
    mov esi, [rbx + XD_SPORT]
    mov edx, [rbx + XD_PORT]
    mov ecx, [rbx + XD_LEN]
    call udp6_send
.sent:
    mov rdi, rbx
    call kfree
    jmp .next
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  poll, ioctl
; -----------------------------------------------------------------------------

; (LFO_READY) RDI = a socket's file -> EAX = poll's mask, RDX = 0. Looks
; without locks; preserves RBX, RBP, R12-R15.
lx_sock_ready:
    mov rsi, [rdi + LF_PRIV]
    xor edx, edx
    xor eax, eax
    mov ecx, [rsi + XS_KIND]
    cmp ecx, XSK_UDP
    je .udp
    cmp ecx, XSK_UNIX
    je .unix
    mov ecx, [rsi + XS_STATE]
    cmp ecx, XSS_NEW
    je .new
    mov rdi, [rsi + XS_SK]
    mov r8d, [rdi + SK_STATE]
    cmp ecx, XSS_LISTENING
    je .listening
    cmp r8d, SKS_FAILED
    je .failed
    cmp ecx, XSS_CONNECTING             ; (not yet looked at: as it is now)
    jne .connected
    cmp r8d, SKS_OPEN
    jb .out                             ; still connecting
.connected:
    cmp dword [rdi + SK_RX_LEN], 0
    je .no_bytes
    or eax, POLLIN | POLLRDNORM
.no_bytes:
    cmp r8d, SKS_ENDED
    je .ended
    test dword [rdi + SK_FLAGS], SKF_RXEND
    jnz .rx_end
    test dword [rsi + XS_SHUT], 1
    jz .write
.rx_end:
    or eax, POLLIN | POLLRDNORM | POLLRDHUP
    jmp .write
.ended:
    or eax, POLLIN | POLLRDNORM | POLLRDHUP | POLLHUP
.write:
    cmp r8d, SKS_OPEN
    jne .out
    test dword [rdi + SK_FLAGS], SKF_SHUT | SKF_NOSEND
    jnz .out
    cmp dword [rdi + SK_TX_LEN], SK_BUF
    jae .out
    or eax, POLLOUT | POLLWRNORM
    ret
.failed:
    mov eax, POLLIN | POLLRDNORM | POLLOUT | POLLWRNORM | POLLERR | POLLHUP
    ret
.listening:
    cmp dword [rdi + SK_ACN], 0
    je .no_conn
    or eax, POLLIN | POLLRDNORM
.no_conn:
    cmp r8d, SKS_FAILED
    jne .out
    or eax, POLLERR
    ret
.new:
    mov eax, POLLOUT | POLLWRNORM | POLLHUP ; (unconnected: as Linux says)
    cmp dword [rsi + XS_ERROR], 0
    je .out
    or eax, POLLERR
    ret
.udp:
    mov eax, POLLOUT | POLLWRNORM
    cmp qword [rsi + XS_QHEAD], 0
    je .udp_shut
    or eax, POLLIN | POLLRDNORM
.udp_shut:
    test dword [rsi + XS_SHUT], 1
    jz .out
    or eax, POLLIN | POLLRDNORM | POLLRDHUP
    ret
.unix:
    mov rdi, [rsi + XS_PIN]
    test rdi, rdi
    jz .unix_alone
    xor r8d, r8d                        ; R8 = how many ways are over
    mov rcx, [rdi + PI_TAIL]
    cmp rcx, [rdi + PI_HEAD]
    je .unix_empty
    or eax, POLLIN | POLLRDNORM
.unix_empty:
    cmp dword [rdi + PI_WRITERS], 0     ; the other end writes no more
    je .unix_in_over
    test dword [rsi + XS_SHUT], 1
    jz .unix_out
.unix_in_over:
    or eax, POLLIN | POLLRDNORM | POLLRDHUP
    inc r8d
.unix_out:
    mov rdi, [rsi + XS_POUT]
    cmp dword [rdi + PI_READERS], 0
    je .unix_out_over
    test dword [rsi + XS_SHUT], 2
    jnz .unix_out_over
    mov rcx, [rdi + PI_TAIL]
    sub rcx, [rdi + PI_HEAD]
    cmp rcx, PIPE_SIZE
    jae .unix_hup
    or eax, POLLOUT | POLLWRNORM
    jmp .unix_hup
.unix_out_over:
    or eax, POLLOUT | POLLWRNORM        ; (a write would not wait: EPIPE)
    inc r8d
.unix_hup:
    cmp r8d, 2
    jb .out
    or eax, POLLHUP
    ret
.unix_alone:
    mov eax, POLLOUT | POLLWRNORM | POLLHUP
.out:
    ret

; (LFO_IOCTL) RDI = a socket's file, ESI = request, RDX = arg
lx_sock_ioctl:
    mov r8, [rdi + LF_PRIV]
    cmp esi, 0x541B                     ; FIONREAD
    je .nread
    xor ecx, ecx
    cmp esi, 0x8905                     ; SIOCATMARK: never
    je .put
    mov eax, esi
    and eax, 0xFF00
    cmp eax, 0x8900                     ; SIOCGIF* and the like: no interfaces
    mov rax, -ENODEV                    ; to say
    je .out
    mov rax, -ENOTTY
.out:
    ret
.nread:
    xor ecx, ecx
    mov eax, [r8 + XS_KIND]
    cmp eax, XSK_TCP
    jne .nread_udp
    cmp dword [r8 + XS_STATE], XSS_LISTENING
    je .put
    mov rax, [r8 + XS_SK]
    test rax, rax
    jz .put
    mov ecx, [rax + SK_RX_LEN]
    jmp .put
.nread_udp:
    cmp eax, XSK_UDP
    jne .nread_unix
    UDP_LOCK                            ; the next datagram's bytes
    mov rax, [r8 + XS_QHEAD]
    test rax, rax
    jz .udp_none
    mov ecx, [rax + XD_LEN]
.udp_none:
    UDP_UNLOCK
    jmp .put
.nread_unix:
    mov rax, [r8 + XS_PIN]
    test rax, rax
    jz .put
    mov rcx, [rax + PI_TAIL]
    sub rcx, [rax + PI_HEAD]
.put:
    mov rdi, rdx
    mov esi, ecx
    jmp lx_put32

; -----------------------------------------------------------------------------
;  /etc/resolv.conf
; -----------------------------------------------------------------------------

; lx_resolv_init: /etc/resolv.conf, the kernel's, made with the tree
; (lx_tree_load, on the main thread)
lx_resolv_init:
    push rbx
    lea rsi, [str_lxp_resolv]
    mov ecx, LNK_FILE
    call lx_make
    test rax, rax
    jz .out
    mov rbx, rax
    mov edi, 4096
    call vm_alloc
    test rax, rax
    jz .out
    mov [rbx + LN_DATA], rax
    mov dword [rbx + LN_MODE], 0o644
    mov dword [rbx + LN_STATE], LNS_LOADED
    mov dword [rbx + LN_DONE], 1
    mov [lx_resolv_node], rbx
    mov rdi, rbx
    call lx_resolv_fill
.out:
    pop rbx
    ret

; lx_resolv_fill(RDI = its node): what it says now. Each open says it afresh.
lx_resolv_fill:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, [rbx + LN_DATA]
    mov eax, [net_dns]
    test eax, eax
    jz .six
    SPRINTF r12, `nameserver %I\n`, rax
    add r12, rax
.six:
    lea rsi, [ip6_dns]
    mov rax, [rsi]
    or rax, [rsi + 8]
    jz .options
    SPRINTF r12, `nameserver %A\n`, rsi
    add r12, rax
.options:
    SPRINTF r12, `options timeout:2 attempts:2\n`
    add r12, rax
    sub r12, [rbx + LN_DATA]
    mov [rbx + LN_SIZE], r12
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------

; lx_sock_init: the sockets' node (once, from lx_init)
lx_sock_init:
    lea rax, [str_lx_socket]
    mov [lx_sock_node + LN_NAME], rax
    mov dword [lx_sock_node + LN_KIND], LNK_SOCK
    mov dword [lx_sock_node + LN_MODE], 0o777
    mov rax, LX_SOCK_INO
    mov [lx_sock_node + LN_INO], rax
    mov dword [lx_sock_node + LN_STATE], LNS_LOADED
    ret

section .rodata
align 8
lx_sock_ops:    dq lx_sock_read, lx_sock_write, lx_sock_ready, lx_sock_close, lx_sock_ioctl
lx_sock_bools:                          ; level, name, its bit in XS_OPTS
    dd SOL_SOCKET, SO_REUSEADDR, 0
    dd SOL_SOCKET, SO_KEEPALIVE, 1
    dd SOL_SOCKET, SO_BROADCAST, 2
    dd SOL_SOCKET, SO_REUSEPORT, 3
    dd SOL_SOCKET, SO_OOBINLINE, 4
    dd SOL_SOCKET, SO_PASSCRED, 5
    dd SOL_SOCKET, SO_DONTROUTE, 6
    dd IPPROTO_TCP, TCP_NODELAY, 7
    dd IPPROTO_IPV6, IPV6_V6ONLY, 8
    dd -1
str_lx_socket:  db 'socket', 0
str_lxp_resolv: db '/etc/resolv.conf', 0

section .bss
alignb 8
lx_sock_node:   resb LN_NODE_SIZE       ; what fstat says of a socket (lx_sock_init)
lx_resolv_node: resq 1
lx_udp_list:    resq 1                  ; UDP sockets with a port
lx_udp_txq:     resq 1                  ; datagrams to send, oldest first
lx_udp_txt:     resq 1                  ; (and the newest)
lx_udp_lock:    resd 1
lx_port_next:   resd 1

section .text
