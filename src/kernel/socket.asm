; =============================================================================
;  socket.asm - the network for programs: capabilities to it, and sockets
;
;  A program run from the console gets a handle to the network (OT_NET,
;  SB_NET): any host, any port, every right. From it come narrower ones
;  (RO_NET_SUB): one host ("api.example.com"), every host under a name
;  ("*.example.com"), one port, fewer rights: RT_NET_CONNECT for plain TCP,
;  RT_NET_TLS for TLS with the server's certificate checked,
;  RT_NET_INSECURE for TLS without that, RT_NET_LISTEN to listen on a port.
;  A program handed one reaches that much, and no more.
;
;  A socket (OT_SOCKET) is a connection, or a port listened on. Each has
;  SK_BUF bytes each way in the kernel: RO_SEND copies in what fits, RO_RECV
;  copies out what came, and the main loop moves bytes between those and
;  TCP (through TLS when asked), TCP's window being what is free on the way
;  in. On a ring:
;    RO_NET_CONNECT gives a socket at once; the main loop looks the host up,
;      connects, and for TLS shakes hands. What is sent before then waits.
;      RO_WAIT on a socket with a0 = 1 waits until there is room to send
;      (it is open) or never will be; with a0 = 0, until there is something
;      to receive, or nothing more will come.
;    RO_RECV -> bytes; E_EMPTY if none has come; E_PEER once the other side
;      has finished and all of it is read; E_NET if it failed (after what
;      came before), RO_NET_STATUS saying why
;    RO_SEND -> bytes taken; E_FULL if none fit; E_PEER once it was shut or
;      the other side is gone; E_NET if it failed
;    RO_NET_SHUT: once what was sent has gone, a FIN (plain TCP only)
;    RO_NET_LISTEN, then RO_NET_ACCEPT: a socket for each connection taken,
;      SK_ACCEPT_MAX waiting at most; RO_WAIT (a0 = 0) for the next
;  When a socket's last handle goes, what it had sent still goes out; then
;  it is closed, or reset if that takes more than SK_LINGER_S seconds.
;
;  The program's side (h_*) runs on any CPU; whatever touches DNS, TCP and
;  TLS runs on the main loop (sk_tick, from net_service). sk_lock covers
;  each socket's state, counts and accept queue, taken with interrupts off;
;  waiters are woken under it. Bytes are copied without it: one sender and
;  one receiver at a time (SK_BUSY), into the free part of a buffer or out
;  of the full part, while the main loop works the other end.
; =============================================================================

SK_CIN_BUF      equ 32768               ; TLS: what came, still encrypted
SK_FEED         equ 16384 + 256         ; room kept for one record's plaintext
SK_MAX          equ 32                  ; sockets at once
SK_LINGER_S     equ 10
SK_HOST_MAX     equ 256                 ; the field RO_NET_CONNECT reads
NT_PATTERN_MAX  equ 64                  ; and RO_NET_SUB

; SK_FLAGS
SKF_TLS         equ 1
SKF_INSECURE    equ 2                   ; the certificate not checked
SKF_SHUT        equ 4                   ; the program has finished sending
SKF_SHUT_DONE   equ 8                   ; and TCP was told
SKF_RXEND       equ 16                  ; nothing more will come
SKF_TCPFIN      equ 32                  ; TLS: TCP has finished; the end once what came is read
SKF_GONE        equ 64                  ; no handle to it is left
SKF_NOSEND      equ 128                 ; nothing more can be sent
SKF_LISTENER    equ 256
SKF_CLOSING     equ 512                 ; gone, closed: TCP finishing

%macro SK_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [sk_lock]
    call spin_lock
    pop rdi
%endmacro

%macro SK_UNLOCK 0
    push rdi
    lea rdi, [sk_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  The program's side
; -----------------------------------------------------------------------------

; sk_program -> EAX = a handle to all of the network, in the current task,
; for a program run from the console; 0 if none could be made. Preserves
; others.
sk_program:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, OT_NET
    mov esi, NT_SIZE
    lea rdx, [str_ot_net]
    call obj_new
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, RT_NET_ALL | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; h_net_connect(EDI = the network, ESI = memory, RDX = where the host is in
; it, RCX = port, R8 = NETF_*) -> RAX = a handle to a socket
h_net_connect:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, SK_HOST_MAX
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rax, E_ARG
    test r15, ~(NETF_TLS | NETF_INSECURE)
    jnz .out
    mov edx, RT_NET_CONNECT
    test r15d, NETF_TLS
    jz .get
    mov edx, RT_NET_TLS
    test r15d, NETF_INSECURE
    jz .get
    mov edx, RT_NET_INSECURE
.get:
    mov eax, r15d
    and eax, NETF_TLS | NETF_INSECURE
    cmp eax, NETF_INSECURE              ; unchecked, but not TLS?
    mov rax, E_ARG
    je .out
    mov esi, OT_NET
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax                        ; RBX = the network, a reference
    call nt_port
    jc .put
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov ecx, SK_HOST_MAX
    call h_mem_read
    cmp rax, E_ANY
    jae .put
    mov rdi, rsp
    mov ecx, SK_HOST_MAX
    call sk_field
    jc .put
    mov rsi, rsp
    lea rdi, [rbx + NT_PATTERN]
    call sk_match
    mov rax, E_RIGHTS
    jc .put
    xor edi, edi
    test r15d, NETF_TLS
    jz .made
    mov edi, SKF_TLS
    test r15d, NETF_INSECURE
    jz .made
    or edi, SKF_INSECURE
.made:
    call sk_new_socket
    cmp rax, E_ANY
    jae .put
    mov rdi, rax
    mov [rdi + SK_PORT], r14d
    mov dword [rdi + SK_STATE], SKS_LOOKUP
    push rdi
    lea rdi, [rdi + SK_HOST]
    mov rsi, rsp
    add rsi, 8
    mov ecx, SK_HOST_MAX
    rep movsb
    pop rdi
    call sk_hand_out
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    add rsp, SK_HOST_MAX
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; nt_port(RBX = the network, R14 = a port) -> CF and RAX = E_* if it is not
; one, or not one this capability reaches. Preserves others.
nt_port:
    mov rax, E_ARG
    test r14, r14
    jz .no
    cmp r14, 65535
    ja .no
    mov eax, [rbx + NT_PORT]
    test eax, eax
    jz .yes
    cmp rax, r14
    mov rax, E_RIGHTS
    jne .no
.yes:
    clc
    ret
.no:
    stc
    ret

; sk_field(RDI = a field read from a program, ECX = its bytes) -> CF and
; RAX = E_ARG unless it holds text: not empty, NUL-ended. Preserves others.
sk_field:
    push rcx
    push rdi
    xor eax, eax
    cmp [rdi], al
    je .bad
    repne scasb
    jne .bad
    pop rdi
    pop rcx
    clc
    ret
.bad:
    mov rax, E_ARG
    pop rdi
    pop rcx
    stc
    ret

; h_net_listen(EDI = the network, RSI = a port) -> RAX = a handle to a socket
; listening there (whether the port was free, it says once it has tried)
h_net_listen:
    push rbx
    push r14
    mov r14, rsi
    mov esi, OT_NET
    mov edx, RT_NET_LISTEN
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    call nt_port
    jc .put
    mov edi, SKF_LISTENER
    call sk_new_socket
    cmp rax, E_ANY
    jae .put
    mov rdi, rax
    mov [rdi + SK_PORT], r14d
    mov dword [rdi + SK_STATE], SKS_LISTEN
    call sk_hand_out
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop r14
    pop rbx
    ret

; h_net_accept(EDI = a socket listening) -> RAX = a handle to the oldest
; connection it took, or E_EMPTY if none waits (E_NET if it failed)
h_net_accept:
    push rbx
    push r12
    mov esi, OT_SOCKET
    mov edx, RT_SK_RECV
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    test dword [rbx + SK_FLAGS], SKF_LISTENER
    jz .put
    SK_LOCK
    mov ecx, [rbx + SK_ACN]
    test ecx, ecx
    jz .none
    mov r12, [rbx + SK_ACQ]             ; R12 = the oldest, the queue's reference
    dec ecx
    mov [rbx + SK_ACN], ecx
    lea rdi, [rbx + SK_ACQ]
    lea rsi, [rdi + 8]
    rep movsq
    call sk_settle
    SK_UNLOCK
    mov rdi, r12
    mov esi, RT_SK_SEND | RT_SK_RECV | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .put
    lock or dword [r12 + SK_FLAGS], SKF_GONE ; no handle: the main loop lets it go
    call sk_kick
    jmp .put
.none:
    mov rax, E_EMPTY
    cmp dword [rbx + SK_STATE], SKS_FAILED
    jne .unlock
    mov rax, E_NET
.unlock:
    SK_UNLOCK
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop r12
    pop rbx
    ret

; h_net_status(EDI = a socket) -> RAX = SKS_* | why << 8 (NETW_*, once
; failed) | TLS's error << 16 (for NETW_TLS)
h_net_status:
    xor esi, esi
    xor edx, edx
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    mov eax, OT_SOCKET
    cmp [rdi + OB_TYPE], eax
    mov rax, E_TYPE
    jne .put
    movzx eax, byte [rdi + SK_TLSE]
    shl eax, 8
    mov al, [rdi + SK_WHY]
    shl eax, 8
    mov al, [rdi + SK_STATE]
.put:
    call obj_put
.out:
    jmp op_done

; h_net_shut(EDI = a socket) -> RAX = 0: once what was sent has gone, a FIN
h_net_shut:
    push rbx
    mov esi, OT_SOCKET
    mov edx, RT_SK_SEND
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    test dword [rbx + SK_FLAGS], SKF_TLS | SKF_LISTENER
    jnz .put
    lock or dword [rbx + SK_FLAGS], SKF_SHUT
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    call sk_kick
    xor eax, eax
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop rbx
    ret

; h_net_sub(EDI = the network, ESI = memory, RDX = where a host pattern is
; in it, RCX = a port or 0, R8 = rights) -> RAX = a handle to the network
; that reaches no more than both this one and they do (needs RT_DUP)
h_net_sub:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, NT_PATTERN_MAX
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov r15d, r8d
    push rdi
    mov esi, OT_NET
    mov edx, RT_DUP
    call handle_get
    pop rdi
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    call handle_info                    ; EDX = this one's rights
    and r15d, edx
    mov rax, E_ARG
    cmp r14, 65535
    ja .put
    mov eax, [rbx + NT_PORT]            ; a port it reaches
    test eax, eax
    jz .pattern
    test r14, r14
    cmovz r14, rax
    cmp r14, rax
    mov rax, E_RIGHTS
    jne .put
.pattern:
    mov edi, r12d
    mov rsi, r13
    mov rdx, rsp
    mov ecx, NT_PATTERN_MAX
    call h_mem_read
    cmp rax, E_ANY
    jae .put
    cmp byte [rsp], 0                   ; "" for any, if this one is
    je .any
    mov rdi, rsp
    mov ecx, NT_PATTERN_MAX
    call sk_field
    jc .put
    mov rsi, rsp
    lea rdi, [rbx + NT_PATTERN]
    call sk_match                       ; within it
    jnc .new
    mov rax, E_RIGHTS
    jmp .put
.any:
    mov rax, E_RIGHTS
    cmp byte [rbx + NT_PATTERN], 0
    jne .put
.new:
    mov edi, OT_NET
    mov esi, NT_SIZE
    lea rdx, [str_ot_net]
    call obj_new
    test rax, rax
    jz .nomem
    mov [rax + NT_PORT], r14d
    lea rdi, [rax + NT_PATTERN]
    mov rsi, rsp
    mov ecx, NT_PATTERN_MAX
    rep movsb
    mov rdi, rax
    mov esi, r15d
    call handle_new
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    add rsp, NT_PATTERN_MAX
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sk_match(RSI = a host, or a pattern, RDI = a pattern) -> CF unless the
; pattern reaches it: "" reaches every host; "*.name" every one ending in
; ".name" (and "*.name" itself, and patterns under it); anything else only
; itself. Letters' case does not matter. Preserves all.
sk_match:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    cmp byte [rdi], 0
    je .yes
    call sk_same
    je .yes
    cmp word [rdi], '*.'
    jne .no
    inc rdi                             ; ".name"
    call strlen
    mov rcx, rax
    push rdi
    mov rdi, rsi
    call strlen
    pop rdi
    cmp rax, rcx
    jbe .no
    add rsi, rax
    sub rsi, rcx                        ; its end, as long
    call sk_same
    je .yes
.no:
    stc
    jmp .out
.yes:
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; sk_same(RSI, RDI = two texts) -> ZF if they are the same, but for case.
; Preserves all but flags.
sk_same:
    push rax
    push rcx
    push rsi
    push rdi
.char:
    mov al, [rsi]
    mov cl, [rdi]
    inc rsi
    inc rdi
    cmp al, 'A'
    jb .a
    cmp al, 'Z'
    ja .a
    or al, 0x20
.a:
    cmp cl, 'A'
    jb .c
    cmp cl, 'Z'
    ja .c
    or cl, 0x20
.c:
    cmp al, cl
    jne .out
    test al, al
    jnz .char
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; sk_new_socket(EDI = SKF_* to begin with) -> RAX = a socket (one
; reference), its buffers got; else E_FULL (SK_MAX live) or E_NOMEM
sk_new_socket:
    push rbx
    push r12
    mov r12d, edi
    mov eax, 1
    lock xadd [sk_live], eax
    cmp eax, SK_MAX
    jb .room
    lock dec dword [sk_live]
    mov rax, E_FULL
    jmp .out
.room:
    mov edi, OT_SOCKET
    mov esi, SK_SIZE
    lea rdx, [str_ot_socket]
    call obj_new
    test rax, rax
    jz .no_object
    mov rbx, rax
    mov [rbx + SK_FLAGS], r12d
    test r12d, SKF_LISTENER
    jnz .made
    mov edi, SK_BUF
    call kmalloc
    mov [rbx + SK_RX], rax
    test rax, rax
    jz .free
    mov edi, SK_BUF
    call kmalloc
    mov [rbx + SK_TX], rax
    test rax, rax
    jz .free
    test r12d, SKF_TLS
    jz .made
    mov edi, SK_CIN_BUF
    call kmalloc
    mov [rbx + SK_CIN], rax
    test rax, rax
    jz .free
    mov edi, TLS_SESSION
    call kmalloc
    mov [rbx + SK_TLS], rax
    test rax, rax
    jz .free
    mov [rax + TLS_USER], rbx
.made:
    lock inc qword [sk_made]
    mov rax, rbx
    jmp .out
.free:
    mov rdi, rbx                        ; sk_destroy frees what it got
    call obj_put
    jmp .nomem
.no_object:
    lock dec dword [sk_live]
.nomem:
    mov rax, E_NOMEM
.out:
    pop r12
    pop rbx
    ret

; sk_hand_out(RDI = a socket just made, its one reference) -> RAX = a handle
; to it in the current task; and it is the main loop's to start
sk_hand_out:
    push rbx
    mov rbx, rdi
    call obj_get                        ; the main loop's
    mov rdi, rbx
    mov esi, RT_SK_SEND | RT_SK_RECV | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .refused
    SK_LOCK
    mov rcx, [sk_new]
    mov [rbx + SK_NEXT], rcx
    mov [sk_new], rbx
    SK_UNLOCK
    call sk_kick
    jmp .out
.refused:
    push rax
    mov rdi, rbx                        ; never the main loop's after all
    call obj_put
    pop rax
.out:
    pop rbx
    ret

; h_sk_send(EDI = a socket, ESI = memory, RDX = offset, RCX = bytes) ->
; RAX = the bytes taken (as many as there is room for)
h_sk_send:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_SOCKET
    mov edx, RT_SK_SEND
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax                        ; RBX = the socket, a reference
    mov rax, E_ARG
    test dword [rbx + SK_FLAGS], SKF_LISTENER
    jnz .put
    xor eax, eax
    test r14, r14
    jz .put
    xor ecx, ecx
    call sk_take
    SK_LOCK
    mov r15, E_NET
    mov eax, [rbx + SK_STATE]
    cmp eax, SKS_FAILED
    je .refused
    mov r15, E_PEER
    cmp eax, SKS_ENDED
    je .refused
    test dword [rbx + SK_FLAGS], SKF_SHUT | SKF_NOSEND
    jnz .refused
    mov eax, [rbx + SK_TX_HEAD]
    mov ecx, [rbx + SK_TX_LEN]
    SK_UNLOCK
    mov r15, E_FULL
    mov edx, SK_BUF
    sub edx, ecx                        ; room
    jz .given
    cmp r14, rdx
    cmova r14, rdx                      ; R14 = what goes in
    add eax, ecx
    and eax, SK_BUF - 1
    mov r15d, eax                       ; R15 = where
    mov ecx, SK_BUF
    sub ecx, eax
    cmp rcx, r14
    cmova rcx, r14                      ; up to the end
    push rcx
    mov edi, r12d
    mov rsi, r13
    mov rdx, [rbx + SK_TX]
    add rdx, r15
    call h_mem_read
    pop rcx
    cmp rax, E_ANY
    jae .failed
    mov rdx, r14                        ; then from the start
    sub rdx, rcx
    jz .copied
    mov edi, r12d
    lea rsi, [r13 + rcx]
    mov rcx, rdx
    mov rdx, [rbx + SK_TX]
    call h_mem_read
    cmp rax, E_ANY
    jae .failed
.copied:
    SK_LOCK
    add [rbx + SK_TX_LEN], r14d
    call sk_settle
    SK_UNLOCK
    mov r15, r14
    call sk_kick
    jmp .given
.failed:
    mov r15, rax
    jmp .given
.refused:
    SK_UNLOCK
.given:
    xor ecx, ecx
    call sk_give
    mov rax, r15
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; h_sk_recv(EDI = a socket, ESI = memory, RDX = offset, RCX = room) -> RAX =
; the bytes received (as many as came, and fit)
h_sk_recv:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_SOCKET
    mov edx, RT_SK_RECV
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_ARG
    test dword [rbx + SK_FLAGS], SKF_LISTENER
    jnz .put
    mov ecx, 1
    call sk_take
    SK_LOCK
    mov eax, [rbx + SK_RX_HEAD]
    mov ecx, [rbx + SK_RX_LEN]
    test ecx, ecx
    jnz .some
    mov r15, E_PEER                     ; nothing: the end, a failure, or not yet
    test dword [rbx + SK_FLAGS], SKF_RXEND
    jnz .refused
    mov r15, E_NET
    cmp dword [rbx + SK_STATE], SKS_FAILED
    je .refused
    mov r15, E_EMPTY
.refused:
    SK_UNLOCK
    jmp .given
.some:
    SK_UNLOCK
    cmp r14, rcx
    cmova r14, rcx                      ; R14 = what comes out
    xor r15d, r15d
    test r14, r14
    jz .given
    mov r15d, eax                       ; R15 = from where
    mov ecx, SK_BUF
    sub ecx, eax
    cmp rcx, r14
    cmova rcx, r14
    push rcx
    mov edi, r12d
    mov rsi, r13
    mov rdx, [rbx + SK_RX]
    add rdx, r15
    call h_mem_write
    pop rcx
    cmp rax, E_ANY
    jae .failed
    mov rdx, r14
    sub rdx, rcx
    jz .copied
    mov edi, r12d
    lea rsi, [r13 + rcx]
    mov rcx, rdx
    mov rdx, [rbx + SK_RX]
    call h_mem_write
    cmp rax, E_ANY
    jae .failed
.copied:
    SK_LOCK
    mov eax, [rbx + SK_RX_HEAD]
    add eax, r14d
    and eax, SK_BUF - 1
    mov [rbx + SK_RX_HEAD], eax
    sub [rbx + SK_RX_LEN], r14d
    call sk_settle
    SK_UNLOCK
    lock add [rbx + SK_FREED], r14d     ; TCP may offer it again
    mov r15, r14
    call sk_kick
    jmp .given
.failed:
    mov r15, rax
.given:
    mov ecx, 1
    call sk_give
    mov rax, r15
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    call op_done
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sk_take(RBX = a socket, ECX = 0 to send, 1 to receive): the program's one
; at a time on that side; sk_give lets the next. Preserve all.
sk_take:
    lock bts dword [rbx + SK_BUSY], ecx
    jnc .taken
    pause
    jmp sk_take
.taken:
    ret

sk_give:
    lock btr dword [rbx + SK_BUSY], ecx
    ret

; sk_kick: the main loop, to move what changed. From anywhere. Preserves all.
sk_kick:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov byte [net_pending], 1
    mov rdi, [main_thread]
    call thread_unpark
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

; sk_settle(RBX = a socket), sk_lock held: SK_RREADY and SK_WREADY as they
; are now; those waiting for one set are woken, and Linux programs' polls
; look again (lxsock.asm). Preserves all.
sk_settle:
    call lx_poll_kick
    push rax
    push rcx
    push rdi
    mov eax, 1                          ; something to receive, or no more ever
    cmp dword [rbx + SK_RX_LEN], 0
    jne .read
    test dword [rbx + SK_FLAGS], SKF_RXEND | SKF_GONE
    jnz .read
    mov ecx, [rbx + SK_STATE]
    cmp ecx, SKS_FAILED
    je .read
    cmp ecx, SKS_ENDED
    je .read
    cmp dword [rbx + SK_ACN], 0
    jne .read
    xor eax, eax
.read:
    mov [rbx + SK_RREADY], eax
    test eax, eax
    jz .write
    lea rdi, [rbx + SK_RWQ]
    call wq_wake
.write:
    mov eax, 1                          ; room to send, or never again
    mov ecx, [rbx + SK_STATE]
    cmp ecx, SKS_FAILED
    je .written
    cmp ecx, SKS_ENDED
    je .written
    test dword [rbx + SK_FLAGS], SKF_SHUT | SKF_NOSEND | SKF_GONE
    jnz .written
    xor eax, eax
    cmp ecx, SKS_OPEN
    jne .written
    cmp dword [rbx + SK_TX_LEN], SK_BUF
    jae .written
    mov eax, 1
.written:
    mov [rbx + SK_WREADY], eax
    test eax, eax
    jz .out
    lea rdi, [rbx + SK_WWQ]
    call wq_wake
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; sk_orphan(RDI = a socket): its last handle went (its TY_ORPHAN)
sk_orphan:
    push rbx
    mov rbx, rdi
    lock or dword [rbx + SK_FLAGS], SKF_GONE
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    call sk_kick
    pop rbx
    ret

; sk_destroy(RDI): its last reference went; the main loop is done with it
sk_destroy:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SK_RX]
    call kfree
    mov rdi, [rbx + SK_TX]
    call kfree
    mov rdi, [rbx + SK_CIN]
    call kfree
    mov rdi, [rbx + SK_TLS]
    call kfree
    lock dec dword [sk_live]
    mov rdi, rbx
    call obj_free
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The main loop's side
; -----------------------------------------------------------------------------

; sk_tick: from net_service. Sockets just made are taken on and begun; each
; one's bytes are moved; those done with are let go.
sk_tick:
    cmp qword [sk_new], 0
    jne .new
    cmp qword [sk_list], 0
    jne .new
    ret
.new:
    push rbx
    push r12
    SK_LOCK
    mov rbx, [sk_new]
    mov qword [sk_new], 0
    SK_UNLOCK
.adopt:
    test rbx, rbx
    jz .list
    mov r12, [rbx + SK_NEXT]
    call sk_link
    call sk_begin
    mov rbx, r12
    jmp .adopt
.list:
    mov rbx, [sk_list]
.each:
    test rbx, rbx
    jz .out
    mov r12, [rbx + SK_NEXT]
    call sk_step
    mov rbx, r12
    jmp .each
.out:
    pop r12
    pop rbx
    ret

; sk_link(RBX), sk_unlink(RBX): onto sk_list, and off it. Preserve all.
sk_link:
    push rax
    mov rax, [sk_list]
    mov [rbx + SK_NEXT], rax
    mov qword [rbx + SK_PREV], 0
    test rax, rax
    jz .first
    mov [rax + SK_PREV], rbx
.first:
    mov [sk_list], rbx
    pop rax
    ret

sk_unlink:
    push rax
    push rcx
    mov rax, [rbx + SK_NEXT]
    mov rcx, [rbx + SK_PREV]
    test rax, rax
    jz .last
    mov [rax + SK_PREV], rcx
.last:
    test rcx, rcx
    jz .head
    mov [rcx + SK_NEXT], rax
    jmp .out
.head:
    mov [sk_list], rax
.out:
    pop rcx
    pop rax
    ret

; sk_begin(RBX = a socket just taken on): a lookup, a connection, or the
; port listened on
sk_begin:
    test dword [rbx + SK_FLAGS], SKF_GONE
    jnz .out                            ; sk_step lets it go
    cmp dword [rbx + SK_STATE], SKS_LISTEN
    je .listen
    xor edx, edx
    mov esi, NETW_DOWN
    call net_up
    jc sk_fail
    lea rsi, [rbx + SK_HOST]
    lea rdi, [rbx + SK_ADDR]
    call addr_parse
    jnc sk_connect
.name:
    lea rsi, [rbx + SK_HOST]
    mov edx, DQ_SOCKET
    mov rcx, rbx
    call dns_lookup                     ; then sock_dns_done, or _failed
    jnc .out
    mov esi, eax                        ; DNS_* are NETW_*
    xor edx, edx
    jmp sk_fail
.listen:
    mov edi, [rbx + SK_PORT]
    lea rsi, [sk_tcp_ops]
    lea rdx, [sk_accept]
    mov rcx, rbx
    call tcp_listen
    jc .in_use
    mov [rbx + SK_LISTENER], rax
    mov eax, [rbx + SK_PORT]
    KLOG "net: a program listens on port %u", rax
    mov esi, SKS_LISTEN                 ; (so whoever waits to know hears)
    call sk_state
.out:
    ret
.in_use:
    mov esi, NETW_INUSE
    xor edx, edx
    jmp sk_fail

; sock_dns_done(RDI = a socket, RAX = its host's address): from dns_done
sock_dns_done:
    push rbx
    mov rbx, rdi
    mov rsi, rax
    lea rdi, [rbx + SK_ADDR]
    call addr_copy
    call sk_connect
    pop rbx
    ret

; sock_dns_failed(RDI = a socket, ESI = why, DNS_*): from dns_failed
sock_dns_failed:
    push rbx
    mov rbx, rdi
    xor edx, edx
    call sk_fail
    pop rbx
    ret

; sk_connect(RBX = a socket, SK_ADDR known): TCP's SYN on its way
sk_connect:
    lea rdi, [rbx + SK_ADDR]
    mov esi, [rbx + SK_PORT]
    lea rdx, [sk_tcp_ops]
    call tcp_connect
    jc .no_route
    mov [rbx + SK_TCP], rax
    mov [rax + TC_USER], rbx
    mov rdi, rax
    mov esi, 65535                      ; as much as SK_RX holds
    test dword [rbx + SK_FLAGS], SKF_TLS
    jz .flow
    mov esi, SK_CIN_BUF
.flow:
    call tcp_flow
    mov esi, SKS_CONNECT
    jmp sk_state
.no_route:
    mov esi, NETW_NOROUTE
    xor edx, edx
    jmp sk_fail

; sk_state(RBX, ESI = SKS_*): its state now, and who waits hears. Preserves
; all.
sk_state:
    SK_LOCK
    mov [rbx + SK_STATE], esi
    call sk_settle
    SK_UNLOCK
    ret

; sk_fail(RBX, ESI = why, NETW_*; EDX = TLS's error for NETW_TLS): it failed,
; unless it had already ended. Its lookup, its session and its port go now;
; its connection on sk_step (TCP may be calling a handler).
sk_fail:
    mov eax, [rbx + SK_STATE]
    cmp eax, SKS_FAILED
    je .out
    cmp eax, SKS_ENDED
    je .out
    mov [rbx + SK_WHY], esi
    mov [rbx + SK_TLSE], edx
    mov byte [net_pending], 1           ; round again, for sk_step
    cmp eax, SKS_LOOKUP
    jne .tls
    mov rdi, rbx
    call dns_forget
.tls:
    mov rdi, [rbx + SK_TLS]
    test rdi, rdi
    jz .listener
    call tls_abort
.listener:
    xor edi, edi
    xchg rdi, [rbx + SK_LISTENER]
    test rdi, rdi
    jz .state
    call tcp_unlisten
    call sk_drop_queue
.state:
    mov esi, SKS_FAILED
    call sk_state
.out:
    ret

; sk_step(RBX = a socket on sk_list): its bytes moved, what failed let go of
sk_step:
    mov eax, [rbx + SK_STATE]
    cmp eax, SKS_FAILED
    jne .live
    xor edi, edi
    xchg rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz .gone
    call tcp_abort
    jmp .gone
.live:
    cmp eax, SKS_CONNECT
    jb .gone
    cmp eax, SKS_OPEN
    ja .gone
    call sk_rx
    call sk_tx
.gone:
    test dword [rbx + SK_FLAGS], SKF_GONE
    jnz sk_linger
    ret

; sk_rx(RBX): what the program read, offered again; for TLS, what came fed
; to it, as much as SK_RX has room for what it gives
sk_rx:
    xor esi, esi
    xchg esi, [rbx + SK_FREED]
    test dword [rbx + SK_FLAGS], SKF_TLS
    jnz .feed
    mov rdi, [rbx + SK_TCP]
    test esi, esi
    jz .out
    test rdi, rdi
    jz .out
    jmp tcp_consumed
.feed:
    mov ecx, [rbx + SK_CIN_LEN]
    test ecx, ecx
    jz .fed
    cmp dword [rbx + SK_STATE], SKS_FAILED
    je .out
    mov eax, SK_BUF
    sub eax, [rbx + SK_RX_LEN]
    sub eax, SK_FEED                    ; what it may give, a record more
    jle .out
    cmp ecx, eax
    cmova ecx, eax
    mov edx, SK_CIN_BUF
    sub edx, [rbx + SK_CIN_HEAD]
    cmp ecx, edx
    cmova ecx, edx                      ; in one piece
    mov rdi, [rbx + SK_TLS]
    mov rsi, [rbx + SK_CIN]
    mov eax, [rbx + SK_CIN_HEAD]
    add rsi, rax
    mov edx, ecx
    call tls_input
    mov eax, [rbx + SK_CIN_HEAD]
    add eax, ecx
    and eax, SK_CIN_BUF - 1
    mov [rbx + SK_CIN_HEAD], eax
    sub [rbx + SK_CIN_LEN], ecx
    mov rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz .feed
    mov esi, ecx
    call tcp_consumed
    jmp .feed
.fed:
    test dword [rbx + SK_FLAGS], SKF_TCPFIN
    jz .out
    lock or dword [rbx + SK_FLAGS], SKF_RXEND ; all of it read: the end
    cmp qword [rbx + SK_TCP], 0
    jne .settle
    mov rdi, [rbx + SK_TLS]
    call tls_abort
    mov esi, SKS_ENDED
    jmp sk_state
.settle:
    SK_LOCK
    call sk_settle
    SK_UNLOCK
.out:
    ret

; sk_tx(RBX): what the program sent, to TCP (through TLS), as much as it
; takes; then, if the program shut it, a FIN
sk_tx:
    cmp dword [rbx + SK_STATE], SKS_OPEN
    jne .out
    test dword [rbx + SK_FLAGS], SKF_NOSEND
    jnz .out
    mov rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz .out
.more:
    mov ecx, [rbx + SK_TX_LEN]
    test ecx, ecx
    jz .empty
    mov eax, [rbx + SK_TX_HEAD]
    mov edx, SK_BUF
    sub edx, eax
    cmp ecx, edx
    cmova ecx, edx                      ; in one piece
    mov rsi, [rbx + SK_TX]
    add rsi, rax
    test dword [rbx + SK_FLAGS], SKF_TLS
    jnz .tls
    mov edx, ecx
    call tcp_write
    test eax, eax
    jz .out
    jmp .taken
.tls:
    call tcp_room                       ; a record, with room for its overhead
    sub eax, 64
    jle .out
    cmp ecx, eax
    cmova ecx, eax
    mov eax, 16384
    cmp ecx, eax
    cmova ecx, eax
    push rdi
    mov rdi, [rbx + SK_TLS]
    mov edx, ecx
    call tls_write
    pop rdi
    jc .tls_failed
    mov eax, ecx
.taken:
    SK_LOCK
    mov edx, [rbx + SK_TX_HEAD]
    add edx, eax
    and edx, SK_BUF - 1
    mov [rbx + SK_TX_HEAD], edx
    sub [rbx + SK_TX_LEN], eax
    add [rbx + SK_TXBY], rax
    call sk_settle
    SK_UNLOCK
    jmp .more
.empty:
    mov eax, [rbx + SK_FLAGS]
    and eax, SKF_SHUT | SKF_SHUT_DONE
    cmp eax, SKF_SHUT
    jne .out
    lock or dword [rbx + SK_FLAGS], SKF_SHUT_DONE
    jmp tcp_close
.tls_failed:
    mov rdi, [rbx + SK_TLS]
    mov edx, [rdi + TLS_ERROR]
    mov esi, NETW_TLS
    jmp sk_fail
.out:
    ret

; sk_linger(RBX): no handle to it is left. What waits for an answer, or
; listens, goes now; an open connection once what was sent has gone and
; TCP has closed it, or SK_LINGER_S seconds on
sk_linger:
    mov eax, [rbx + SK_STATE]
    cmp eax, SKS_OPEN
    je .open
    cmp eax, SKS_LISTEN
    je .listener
    cmp eax, SKS_ENDED
    jae sk_drop                         ; ended or failed: nothing left
.abort:
    mov rdi, rbx
    call dns_forget
    mov rdi, [rbx + SK_TLS]
    test rdi, rdi
    jz .tcp
    call tls_abort
.tcp:
    xor edi, edi
    xchg rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz sk_drop
    call tcp_abort
    jmp sk_drop
.listener:
    xor edi, edi
    xchg rdi, [rbx + SK_LISTENER]
    test rdi, rdi
    jz .queue
    call tcp_unlisten
.queue:
    call sk_drop_queue
    jmp sk_drop
.open:
    call net_clock
    mov rcx, [rbx + SK_GONE_AT]
    test rcx, rcx
    jnz .timed
    mov rcx, [net_second]
    imul rcx, rcx, SK_LINGER_S
    add rcx, rax
    mov [rbx + SK_GONE_AT], rcx
.timed:
    cmp rax, rcx
    jae .abort
    mov rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz sk_drop
    xor esi, esi                        ; what still comes, nobody reads
    SK_LOCK
    xchg esi, [rbx + SK_RX_LEN]
    SK_UNLOCK
    test dword [rbx + SK_FLAGS], SKF_TLS
    jz .consumed
    xor esi, esi
    xchg esi, [rbx + SK_CIN_LEN]
.consumed:
    call tcp_consumed
    mov rdi, [rbx + SK_TCP]
    test dword [rbx + SK_FLAGS], SKF_CLOSING
    jnz .out
    cmp dword [rbx + SK_TX_LEN], 0
    jne .out                            ; what it sent goes first
    lock or dword [rbx + SK_FLAGS], SKF_CLOSING
    test dword [rbx + SK_FLAGS], SKF_TLS
    jz .close
    push rdi
    mov rdi, [rbx + SK_TLS]
    call tls_close                      ; close_notify
    pop rdi
.close:
    jmp tcp_close
.out:
    ret

; sk_drop(RBX): off sk_list, the main loop's reference dropped
sk_drop:
    call sk_unlink
    mov rdi, [rbx + SK_TLS]             ; its keys wiped, here
    test rdi, rdi
    jz .settle
    call tls_abort
.settle:
    SK_LOCK
    call sk_settle                      ; whatever still waits on it
    SK_UNLOCK
    mov rdi, rbx
    jmp obj_put

; sk_drop_queue(RBX = a socket that listened): the connections it took that
; nobody accepted, let go
sk_drop_queue:
    push r12
    push r13
    SK_LOCK
    mov r12d, [rbx + SK_ACN]
    mov dword [rbx + SK_ACN], 0
    SK_UNLOCK
    xor r13d, r13d
.each:
    cmp r13d, r12d
    jae .out
    mov rdi, [rbx + SK_ACQ + r13 * 8]
    lock or dword [rdi + SK_FLAGS], SKF_GONE
    call obj_put                        ; the queue's; the main loop has another
    inc r13d
    jmp .each
.out:
    pop r13
    pop r12
    ret

; sk_accept(RDI = a connection established, RSI = the listener) -> CF to
; refuse it: tcp_listen's accept
sk_accept:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov rbx, [rsi + LS_USER]            ; RBX = the socket listening
    test dword [rbx + SK_FLAGS], SKF_GONE
    jnz .refuse
    cmp dword [rbx + SK_STATE], SKS_LISTEN
    jne .refuse
    cmp dword [rbx + SK_ACN], SK_ACCEPT_MAX
    jae .refuse
    xor edi, edi
    call sk_new_socket
    cmp rax, E_ANY
    jae .refuse
    mov r13, rax                        ; R13 = the new one, the main loop's
    mov [r13 + SK_TCP], r12
    mov [r12 + TC_USER], r13
    lea rsi, [r12 + TC_RA]
    lea rdi, [r13 + SK_ADDR]
    call addr_copy
    mov ecx, [r12 + TC_RPORT]
    mov [r13 + SK_PORT], ecx
    mov dword [r13 + SK_STATE], SKS_CONNECT
    lea rax, [r12 + TC_RA]
    SPRINTF r13 + SK_HOST, "%A", rax
    mov rdi, r12
    mov esi, 65535
    call tcp_flow
    xchg rbx, r13
    call sk_link
    xchg rbx, r13
    mov rdi, r13
    call obj_get                        ; the queue's
    SK_LOCK
    mov eax, [rbx + SK_ACN]
    mov [rbx + SK_ACQ + rax * 8], r13
    inc dword [rbx + SK_ACN]
    call sk_settle
    SK_UNLOCK
    clc
    jmp .out
.refuse:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  TCP's handlers, and TLS's (tcp.asm, tls.asm: RDI = the connection, or the
;  session)
; -----------------------------------------------------------------------------

sk_t_open:
    push rbx
    mov rbx, [rdi + TC_USER]
    test rbx, rbx
    jz .out
    cmp dword [rbx + SK_STATE], SKS_CONNECT
    jne .out
    test dword [rbx + SK_FLAGS], SKF_TLS
    jnz .tls
    mov esi, SKS_OPEN
    call sk_state
    jmp .out
.tls:
    mov esi, SKS_HANDSHAKE
    call sk_state
    call rtc_read                       ; now, for the certificate's dates
    mov edi, [rtc_year]
    mov esi, [rtc_mon]
    mov edx, [rtc_day]
    mov ecx, [rtc_hour]
    mov r8d, [rtc_min]
    mov r9d, [rtc_sec]
    call x509_unix
    mov r9, rax
    xor r8d, r8d
    test dword [rbx + SK_FLAGS], SKF_INSECURE
    setnz r8b
    mov rdi, [rbx + SK_TLS]
    lea rsi, [rbx + SK_HOST]
    lea rdx, [sk_tls_send]
    lea rcx, [sk_tls_ops]
    call tls_start
    jnc .out
    mov edx, [rdi + TLS_ERROR]
    mov esi, NETW_TLS
    call sk_fail
.out:
    pop rbx
    ret

sk_t_data:
    push rbx
    mov rbx, [rdi + TC_USER]
    test rbx, rbx
    jz .out
    cmp dword [rbx + SK_STATE], SKS_FAILED
    je .out
    test dword [rbx + SK_FLAGS], SKF_TLS
    jnz .tls
    call sk_rx_put
    jmp .out
.tls:
    mov ecx, SK_CIN_BUF                 ; for sk_rx to feed to TLS
    sub ecx, [rbx + SK_CIN_LEN]
    cmp edx, ecx
    cmova edx, ecx                      ; (TCP's window keeps it within)
    mov eax, [rbx + SK_CIN_HEAD]
    add eax, [rbx + SK_CIN_LEN]
    and eax, SK_CIN_BUF - 1
    add [rbx + SK_CIN_LEN], edx
    mov ecx, SK_CIN_BUF
    sub ecx, eax
    cmp ecx, edx
    cmova ecx, edx
    sub edx, ecx
    mov rdi, [rbx + SK_CIN]
    add rdi, rax
    rep movsb
    mov ecx, edx
    mov rdi, [rbx + SK_CIN]
    rep movsb
.out:
    pop rbx
    ret

sk_t_fin:
    push rbx
    mov rbx, [rdi + TC_USER]
    test rbx, rbx
    jz .out
    test dword [rbx + SK_FLAGS], SKF_TLS
    jnz .tls
    lock or dword [rbx + SK_FLAGS], SKF_RXEND
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    jmp .out
.tls:
    lock or dword [rbx + SK_FLAGS], SKF_TCPFIN ; the end once TLS has had the rest
.out:
    pop rbx
    ret

sk_t_gone:
    push rbx
    mov rbx, [rdi + TC_USER]
    test rbx, rbx
    jz .out
    mov qword [rbx + SK_TCP], 0
    cmp dword [rbx + SK_STATE], SKS_FAILED
    je .out
    cmp esi, TCP_DONE
    jne .failed
    lock or dword [rbx + SK_FLAGS], SKF_NOSEND
    test dword [rbx + SK_FLAGS], SKF_TLS
    jz .ended
    test dword [rbx + SK_FLAGS], SKF_GONE
    jnz .ended
    cmp dword [rbx + SK_CIN_LEN], 0
    je .ended
    lock or dword [rbx + SK_FLAGS], SKF_TCPFIN ; sk_rx ends it, after the rest
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    jmp .out
.ended:
    lock or dword [rbx + SK_FLAGS], SKF_RXEND
    mov rdi, [rbx + SK_TLS]
    test rdi, rdi
    jz .state
    call tls_abort
.state:
    mov esi, SKS_ENDED
    call sk_state
    jmp .out
.failed:
    mov eax, NETW_REFUSED
    cmp esi, TCP_REFUSED
    je .why
    mov eax, NETW_TIMEOUT
    cmp esi, TCP_TIMEOUT
    je .why
    mov eax, NETW_RESET
.why:
    mov esi, eax
    xor edx, edx
    call sk_fail
.out:
    pop rbx
    ret

; sk_rx_put(RBX = a socket, RSI = bytes, EDX = how many): for the program
; to receive (TCP's window, or the feeding, keeps it within SK_BUF)
sk_rx_put:
    test edx, edx
    jz .out
    SK_LOCK
    mov eax, [rbx + SK_RX_HEAD]
    mov ecx, [rbx + SK_RX_LEN]
    SK_UNLOCK
    add eax, ecx
    and eax, SK_BUF - 1                 ; where it goes
    neg ecx
    add ecx, SK_BUF                     ; room, at least
    cmp edx, ecx
    cmova edx, ecx
    push rdx
    mov ecx, SK_BUF
    sub ecx, eax
    cmp ecx, edx
    cmova ecx, edx
    sub edx, ecx
    mov rdi, [rbx + SK_RX]
    add rdi, rax
    rep movsb
    mov ecx, edx
    mov rdi, [rbx + SK_RX]
    rep movsb
    pop rdx
    SK_LOCK
    add [rbx + SK_RX_LEN], edx
    add [rbx + SK_RXBY], rdx
    call sk_settle
    SK_UNLOCK
.out:
    ret

; send(RDI = a session, RSI, EDX) -> CF if TCP's buffer could not take it all
sk_tls_send:
    mov rax, [rdi + TLS_USER]
    mov rdi, [rax + SK_TCP]
    test rdi, rdi
    jz .no
    push rdx
    call tcp_write
    pop rdx
    cmp eax, edx
    ret
.no:
    stc
    ret

sk_tls_ready:
    push rbx
    mov rbx, [rdi + TLS_USER]
    mov esi, SKS_OPEN
    call sk_state
    pop rbx
    ret

sk_tls_data:
    push rbx
    mov rbx, [rdi + TLS_USER]
    call sk_rx_put
    pop rbx
    ret

sk_tls_closed:                          ; the server's close_notify: nothing more
    push rbx
    mov rbx, [rdi + TLS_USER]
    lock or dword [rbx + SK_FLAGS], SKF_RXEND | SKF_NOSEND
    SK_LOCK
    call sk_settle
    SK_UNLOCK
    mov rdi, [rbx + SK_TCP]
    test rdi, rdi
    jz .out
    call tcp_close
.out:
    pop rbx
    ret

sk_tls_fail:
    push rbx
    mov rbx, [rdi + TLS_USER]
    mov edx, eax
    mov esi, NETW_TLS
    call sk_fail
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  'sockets': what programs have open
; -----------------------------------------------------------------------------

cmd_sockets:
    push rbx
    push r12
    mov eax, [sk_live]
    KLOG "sockets: %u live, %u made", rax, qword [sk_made]
    mov rbx, [sk_list]
.each:
    test rbx, rbx
    jz .out
    mov eax, [rbx + SK_STATE]
    lea rcx, [sk_state_names]
    mov rax, [rcx + rax * 8]
    mov ecx, [rbx + SK_PORT]
    lea rdx, [rbx + SK_HOST]
    mov esi, [rbx + SK_WHY]
    mov r8d, [rbx + SK_FLAGS]
    lea r12, [str_sk_plain]
    test r8d, SKF_TLS
    jz .kind
    lea r12, [str_sk_tls]
.kind:
    KLOG "  #%u %s %s:%u %s, why %u, %u in, %u out", qword [rbx + OB_ID], rax, rdx, rcx, r12, rsi, qword [rbx + SK_RXBY], qword [rbx + SK_TXBY]
    mov rbx, [rbx + SK_NEXT]
    jmp .each
.out:
    pop r12
    pop rbx
    ret

section .rodata
str_ot_net:     db 'network', 0
str_ot_socket:  db 'socket', 0
str_sk_plain:   db 'tcp', 0
str_sk_tls:     db 'tls', 0
str_sks_0:      db '-', 0
str_sks_lookup: db 'looking up', 0
str_sks_connect: db 'connecting', 0
str_sks_hand:   db 'shaking hands', 0
str_sks_open:   db 'open', 0
str_sks_ended:  db 'ended', 0
str_sks_failed: db 'failed', 0
str_sks_listen: db 'listening', 0

align 8
sk_state_names: dq str_sks_0, str_sks_lookup, str_sks_connect, str_sks_hand
                dq str_sks_open, str_sks_ended, str_sks_failed, str_sks_listen
sk_tcp_ops:     dq sk_t_open, sk_t_data, sk_t_fin, sk_t_gone
sk_tls_ops:     dq sk_tls_ready, sk_tls_data, sk_tls_closed, sk_tls_fail

section .bss
alignb 8
sk_new:         resq 1                  ; made by programs, for the main loop to take on
sk_list:        resq 1                  ; the main loop's
sk_made:        resq 1
sk_live:        resd 1
sk_lock:        resd 1
