; =============================================================================
;  lxevent.asm - epoll, eventfd and timerfd, for Linux programs
;
;  Each is an open file of a kind of its own (LFK_EPOLL, LFK_EVENT,
;  LFK_TIMER) that reads, writes, closes and says whether it is ready
;  through LF_OPS; fstat finds lx_anon_node, as Linux's anonymous inodes.
;
;  An epoll keeps watches (EPW_*): a file and the descriptor it was added
;  by, what is wanted and the data to say with it, on the epoll's list
;  (LF_PRIV) and the file's (LF_WATCH), both under lx_ep_lock. A file's
;  watches go with its last reference, as Linux's do. epoll_wait looks at
;  each watched file as poll does (lf_ready) and waits on poll's queue;
;  EPOLLET says a file again only once something has changed since it was
;  said (lx_poll_gen moved on, or what it is), EPOLLONESHOT once only.
;
;  An eventfd is its count, in LF_POS, changed by LOCK CMPXCHG; a timer
;  (TMR_*) counts in lx_now_ns's nanoseconds, its expirations worked out
;  whenever it is looked at, and tells a wait when it next expires.
; =============================================================================

EPOLL_EVENTS    equ 0x2FFF                  ; IN PRI OUT ERR HUP RDNORM ... MSG RDHUP
EPOLLONESHOT    equ 1 << 30
EPOLLET         equ 1 << 31
EPOLL_CTL_ADD   equ 1
EPOLL_CTL_DEL   equ 2
EPOLL_CTL_MOD   equ 3
EP_MAX_EVENTS   equ 1024                    ; said at once, at most (the rest next time)
EFD_SEMAPHORE   equ 1
TFD_TIMER_ABSTIME equ 1
EVENT_MAX       equ -2                      ; an eventfd's count, at most (2^64 - 2)
LX_ANON_INO     equ 0x7100000000

; a watch (kmalloc'd)
EPW_NEXT         equ 0                       ; the epoll's next
EPW_LNEXT        equ 8                       ; the file's next
EPW_EP           equ 16                      ; the epoll (its open file)
EPW_LF           equ 24                      ; the file
EPW_FD           equ 32                      ; dword: its descriptor, as added
EPW_EVENTS       equ 36                      ; dword: wanted, with EPOLLET and EPOLLONESHOT
EPW_DATA         equ 40
EPW_GEN          equ 48                      ; dword: lx_poll_gen when last said
EPW_LAST         equ 52                      ; dword: what was said then
EPW_OFF          equ 56                      ; dword: EPOLLONESHOT said it (until EPOLL_CTL_MOD)
EPW_SIZE         equ 64

; a timer (kmalloc'd, LF_PRIV), in nanoseconds as lx_now_ns counts them
TMR_LOCK         equ 0                       ; dword: lx_mutex
TMR_CLOCK        equ 4                       ; dword
TMR_NEXT         equ 8                       ; when it expires next, 0 if disarmed
TMR_INTERVAL     equ 16
TMR_TICKS        equ 24                      ; expirations not yet read
TMR_SIZE         equ 32

section .text

; lx_anon_open(RDI = LF_OPS, EDX = LFK_*, ESI = O_CLOEXEC | O_NONBLOCK, RCX =
; LF_PRIV, R8 = LF_POS) -> RAX = a descriptor for a new open file of that
; kind, or -errno. LF_PRIV is its from here on: freed (kfree) if no file
; could be made, else by its LFO_CLOSE.
lx_anon_open:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13d, esi
    mov r14, rcx
    mov edi, edx
    lea rsi, [lx_anon_node]
    mov edx, r13d
    and edx, O_NONBLOCK
    or edx, O_RDWR
    call lf_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov [rbx + LF_OPS], r12
    mov [rbx + LF_PRIV], r14
    mov [rbx + LF_POS], r8
    call lx_cur_proc
    mov rdi, rax
    mov rsi, rbx
    xor edx, edx
    xor ecx, ecx
    test r13d, O_CLOEXEC
    setnz cl
    call lx_fd_install
    jmp .out
.nomem:
    mov rdi, r14
    call kfree
    mov rax, -ENOMEM
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; for those that neither read nor write
lx_anon_einval:
    mov rax, -EINVAL
    ret

lx_anon_nothing:
    ret

; -----------------------------------------------------------------------------
;  epoll
; -----------------------------------------------------------------------------

; epoll_create(size)
lx_sys_epoll_create:
    mov rax, -EINVAL
    test edi, edi
    jle .out
    xor edi, edi
    jmp lx_sys_epoll_create1
.out:
    ret

; epoll_create1(flags)
lx_sys_epoll_create1:
    mov rax, -EINVAL
    test edi, ~O_CLOEXEC
    jnz .out
    mov esi, edi
    lea rdi, [lx_epoll_ops]
    mov edx, LFK_EPOLL
    xor ecx, ecx
    xor r8d, r8d
    jmp lx_anon_open
.out:
    ret

; epoll_ctl(epfd, op, fd, event)
lx_sys_epoll_ctl:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                         ; [rsp] = the event: a dword, then the data
    mov r12d, esi                       ; R12 = op, R13 = fd, R14 = event
    mov r13d, edx
    mov r14, rcx
    call lx_fd_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax                        ; RBX = the epoll
    mov edi, r13d
    call lx_fd_ref
    cmp rax, -4095
    jae .put_ep
    mov r15, rax                        ; R15 = the file
    mov rax, -EINVAL
    cmp dword [rbx + LF_KIND], LFK_EPOLL
    jne .put
    cmp dword [r15 + LF_KIND], LFK_EPOLL ; (itself, or another: not here)
    je .put
    mov rax, -EPERM                     ; a file or directory, always ready: as Linux
    cmp dword [r15 + LF_KIND], LFK_DIR
    jbe .put
    cmp r12d, EPOLL_CTL_DEL
    je .lock
    mov rax, -EINVAL
    cmp r12d, EPOLL_CTL_ADD
    je .event
    cmp r12d, EPOLL_CTL_MOD
    jne .put
.event:
    mov rdi, rsp
    mov rsi, r14
    mov edx, 12
    call lx_copy_in
    cmp rax, -4095
    jae .put
.lock:
    lea rdi, [lx_ep_lock]
    call lx_mutex_lock
    mov rax, [rbx + LF_PRIV]            ; its watch, if it has one
.find:
    test rax, rax
    jz .found
    cmp [rax + EPW_LF], r15
    jne .find_next
    cmp [rax + EPW_FD], r13d
    je .found
.find_next:
    mov rax, [rax + EPW_NEXT]
    jmp .find
.found:
    cmp r12d, EPOLL_CTL_ADD
    je .add
    test rax, rax
    jz .enoent
    cmp r12d, EPOLL_CTL_DEL
    je .del
    mov ecx, [rsp]                      ; EPOLL_CTL_MOD
    mov [rax + EPW_EVENTS], ecx
    mov rcx, [rsp + 4]
    mov [rax + EPW_DATA], rcx
    mov dword [rax + EPW_OFF], 0
    mov dword [rax + EPW_LAST], 0
    jmp .done
.add:
    test rax, rax
    jnz .eexist
    mov edi, EPW_SIZE
    call kmalloc
    test rax, rax
    jz .enomem
    mov [rax + EPW_EP], rbx
    mov [rax + EPW_LF], r15
    mov [rax + EPW_FD], r13d
    mov ecx, [rsp]
    mov [rax + EPW_EVENTS], ecx
    mov rcx, [rsp + 4]
    mov [rax + EPW_DATA], rcx
    mov rcx, [r15 + LF_WATCH]           ; first on the file's list
    mov [rax + EPW_LNEXT], rcx
    mov [r15 + LF_WATCH], rax
    lea rcx, [rbx + LF_PRIV]            ; last on the epoll's
.tail:
    mov rdx, [rcx]
    test rdx, rdx
    jz .at_tail
    lea rcx, [rdx + EPW_NEXT]
    jmp .tail
.at_tail:
    mov [rcx], rax
    jmp .done
.del:
    mov rdi, rax
    call lx_watch_drop
.done:
    xor eax, eax
    jmp .unlock
.eexist:
    mov rax, -EEXIST
    jmp .unlock
.enoent:
    mov rax, -ENOENT
    jmp .unlock
.enomem:
    mov rax, -ENOMEM
.unlock:
    lea rdi, [lx_ep_lock]
    call lx_mutex_unlock
    call lx_poll_kick                   ; (a wait looks again)
.put:
    mov rdi, r15
    call lf_put
.put_ep:
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

; lx_watch_drop(RDI = a watch), lx_ep_lock held: off both lists, and freed.
; May change RAX, RCX, RDX, RSI, RDI, R8-R11.
lx_watch_drop:
    mov rdx, [rdi + EPW_EP]
    lea rcx, [rdx + LF_PRIV]
.ep:
    mov rax, [rcx]
    test rax, rax
    jz .file
    cmp rax, rdi
    je .ep_found
    lea rcx, [rax + EPW_NEXT]
    jmp .ep
.ep_found:
    mov rax, [rdi + EPW_NEXT]
    mov [rcx], rax
.file:
    mov rdx, [rdi + EPW_LF]
    lea rcx, [rdx + LF_WATCH]
.lf:
    mov rax, [rcx]
    test rax, rax
    jz .free
    cmp rax, rdi
    je .lf_found
    lea rcx, [rax + EPW_LNEXT]
    jmp .lf
.lf_found:
    mov rax, [rdi + EPW_LNEXT]
    mov [rcx], rax
.free:
    jmp kfree

; lx_epoll_forget(RDI = an open file whose last reference is gone, watched):
; off every epoll. May change RAX, RCX, RDX, RSI, RDI, R8-R11.
lx_epoll_forget:
    push rbx
    mov rbx, rdi
    lea rdi, [lx_ep_lock]
    call lx_mutex_lock
.each:
    mov rdi, [rbx + LF_WATCH]
    test rdi, rdi
    jz .done
    call lx_watch_drop
    jmp .each
.done:
    lea rdi, [lx_ep_lock]
    call lx_mutex_unlock
    pop rbx
    ret

; (LFO_CLOSE) an epoll's last reference gone: its watches with it
lx_epoll_close:
    push rbx
    mov rbx, rdi
    lea rdi, [lx_ep_lock]
    call lx_mutex_lock
.each:
    mov rdi, [rbx + LF_PRIV]
    test rdi, rdi
    jz .done
    call lx_watch_drop
    jmp .each
.done:
    lea rdi, [lx_ep_lock]
    call lx_mutex_unlock
    pop rbx
    ret

; (LFO_READY) an epoll polled: POLLIN if a watch would be said
lx_epoll_ready:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    xor r13d, r13d                      ; R13 = the mask, R14 = the soonest
    xor r14d, r14d
    lea rdi, [lx_ep_lock]
    call lx_mutex_lock
    mov r12, [rbx + LF_PRIV]
.each:
    test r12, r12
    jz .done
    cmp dword [r12 + EPW_OFF], 0
    jne .next
    mov rdi, [r12 + EPW_LF]
    call lf_ready
    mov ecx, eax
    mov rax, r14
    call lx_soonest
    mov r14, rax
    mov eax, [r12 + EPW_EVENTS]
    and eax, EPOLL_EVENTS
    or eax, POLLERR | POLLHUP
    test eax, ecx
    jz .next
    mov r13d, POLLIN | POLLRDNORM
    jmp .done
.next:
    mov r12, [r12 + EPW_NEXT]
    jmp .each
.done:
    lea rdi, [lx_ep_lock]
    call lx_mutex_unlock
    mov eax, r13d
    mov rdx, r14
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; epoll_wait(epfd, events, maxevents, timeout ms)
lx_sys_epoll_wait:
    xor r8d, r8d
    xor r9d, r9d
; epoll_pwait(epfd, events, maxevents, timeout ms, sigmask, sigsetsize)
lx_sys_epoll_pwait:
    movsxd rax, ecx
    test rax, rax
    js .forever
    imul rax, rax, 1000000
    jmp lx_epoll_with
.forever:
    mov rax, -1
    jmp lx_epoll_with

; epoll_pwait2(epfd, events, maxevents, timeout timespec, sigmask, sigsetsize)
lx_sys_epoll_pwait2:
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    mov rdi, rcx
    call lx_poll_ts
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    cmp rax, -4095
    jb lx_epoll_with
    cmp rax, -1
    je lx_epoll_with
    ret

; lx_epoll_with(EDI = epfd, RSI = user events, EDX = how many, RAX =
; nanoseconds or -1, R8 = a sigmask or 0, R9 = its size) -> RAX = events
; said, or -errno
lx_epoll_with:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                         ; [rsp] = lx_poll_gen, [rsp + 8] = the soonest
    mov r12, rsi                        ; R12 = events, R13 = how many,
    mov r13d, edx                       ; R14 = the deadline
    call lx_poll_deadline
    mov r14, rax
    mov rax, -EINVAL
    test r13d, r13d
    jle .out
    cmp r13d, EP_MAX_EVENTS
    jbe .count
    mov r13d, EP_MAX_EVENTS
.count:
    call lx_fd_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax                        ; RBX = the epoll
    mov rax, -EINVAL
    cmp dword [rbx + LF_KIND], LFK_EPOLL
    jne .put
    mov rdi, r8
    mov rsi, r9
    call lx_poll_mask
    test rax, rax
    jnz .put
    imul edi, r13d, 12
    call kmalloc
    test rax, rax
    jz .nomem
    mov r15, rax                        ; R15 = the events, here
.again:
    mov esi, [lx_poll_gen]              ; (before looking: nothing missed)
    mov [rsp], esi
    call lx_epoll_scan
    test eax, eax
    jnz .said
    cmp r14, -1
    je .said
    mov [rsp + 8], rdx
    test r14, r14
    jz .wait
    RDTSC64
    cmp rax, r14
    jae .none
.wait:
    mov rax, r14
    mov rdx, [rsp + 8]
    call lx_soonest
    mov rcx, rax
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -EINTR
    jmp .free
.none:
    xor eax, eax
.said:
    test eax, eax
    jz .free
    push rax
    mov rdi, r12
    mov rsi, r15
    imul edx, eax, 12
    call lx_copy_out
    pop rcx
    cmp rax, -4095
    jae .free
    mov eax, ecx
.free:
    mov rdi, r15
    push rax
    call kfree
    pop rax
    jmp .put
.nomem:
    mov rax, -ENOMEM
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

; lx_epoll_scan(RBX = an epoll, R15 = room for R13D events, ESI =
; lx_poll_gen as the look began) -> EAX = events said there, RDX = the
; soonest a watched timer changes, 0 for none
lx_epoll_scan:
    push r12
    sub rsp, 24                         ; [rsp] = said, [+4] = the generation,
    mov dword [rsp], 0                  ; [+8] = the soonest
    mov [rsp + 4], esi
    mov qword [rsp + 8], 0
    lea rdi, [lx_ep_lock]
    call lx_mutex_lock
    mov r12, [rbx + LF_PRIV]
.each:
    test r12, r12
    jz .done
    cmp dword [r12 + EPW_OFF], 0
    jne .next
    mov rdi, [r12 + EPW_LF]
    call lf_ready
    mov ecx, eax
    mov rax, [rsp + 8]
    call lx_soonest
    mov [rsp + 8], rax
    mov eax, [r12 + EPW_EVENTS]
    and eax, EPOLL_EVENTS
    or eax, POLLERR | POLLHUP
    and eax, ecx                        ; EAX = what it is, of what is wanted
    jz .next
    test dword [r12 + EPW_EVENTS], EPOLLET
    jz .say
    mov ecx, [rsp + 4]                  ; said already, and nothing since?
    cmp [r12 + EPW_GEN], ecx
    jne .say
    cmp [r12 + EPW_LAST], eax
    je .next
.say:
    mov ecx, [rsp + 4]
    mov [r12 + EPW_GEN], ecx
    mov [r12 + EPW_LAST], eax
    test dword [r12 + EPW_EVENTS], EPOLLONESHOT
    jz .again_later
    mov dword [r12 + EPW_OFF], 1
.again_later:
    mov ecx, [rsp]
    imul ecx, ecx, 12
    lea rdi, [r15 + rcx]
    mov [rdi], eax
    mov rax, [r12 + EPW_DATA]
    mov [rdi + 4], rax
    inc dword [rsp]
    cmp [rsp], r13d
    jae .done
.next:
    mov r12, [r12 + EPW_NEXT]
    jmp .each
.done:
    lea rdi, [lx_ep_lock]
    call lx_mutex_unlock
    mov eax, [rsp]
    mov rdx, [rsp + 8]
    add rsp, 24
    pop r12
    ret

; -----------------------------------------------------------------------------
;  eventfd
; -----------------------------------------------------------------------------

; eventfd(initval)
lx_sys_eventfd:
    xor esi, esi
; eventfd2(initval, flags)
lx_sys_eventfd2:
    mov rax, -EINVAL
    test esi, ~(EFD_SEMAPHORE | O_NONBLOCK | O_CLOEXEC)
    jnz .out
    mov r8d, edi                        ; LF_POS = the count
    mov ecx, esi                        ; LF_PRIV = EFD_SEMAPHORE or 0
    and ecx, EFD_SEMAPHORE
    lea rdi, [lx_event_ops]
    mov edx, LFK_EVENT
    jmp lx_anon_open
.out:
    ret

; (LFO_READ) all of the count, or 1 of it with EFD_SEMAPHORE; a wait while
; it is 0
lx_event_read:
    push r12
    sub rsp, 16
    mov r12, rsi
    mov rax, -EINVAL
    cmp rdx, 8
    jb .out
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    mov rax, [rbx + LF_POS]
.try:
    test rax, rax
    jz .empty
    xor ecx, ecx                        ; RCX = what it will be
    cmp qword [rbx + LF_PRIV], 0
    je .take
    lea rcx, [rax - 1]
.take:
    lock cmpxchg [rbx + LF_POS], rcx    ; (changed meanwhile: RAX is what it is now)
    jnz .try
    sub rax, rcx
    call lx_poll_kick                   ; (room for a writer)
    mov rdi, r12
    mov rsi, rax
    call lx_put64
    test rax, rax
    jnz .out
    mov eax, 8
    jmp .out
.empty:
    mov rax, -EAGAIN
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    xor ecx, ecx
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -ERESTARTSYS
.out:
    add rsp, 16
    pop r12
    ret

; (LFO_WRITE) a value added to the count; a wait while there is no room
lx_event_write:
    sub rsp, 16                         ; [rsp] = lx_poll_gen, [+8] = the value
    mov rax, -EINVAL
    cmp rdx, 8
    jb .out
    mov rdi, rsi
    call lx_get64
    test rax, rax
    jnz .out
    mov rax, -EINVAL
    cmp rdx, -1
    je .out
    mov [rsp + 8], rdx
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    mov rax, [rbx + LF_POS]
.try:
    mov rcx, EVENT_MAX                  ; the most it may be, for this to fit
    sub rcx, [rsp + 8]
    cmp rax, rcx
    ja .full
    mov rcx, rax
    add rcx, [rsp + 8]
    lock cmpxchg [rbx + LF_POS], rcx
    jnz .try
    call lx_poll_kick
    mov eax, 8
    jmp .out
.full:
    mov rax, -EAGAIN
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    xor ecx, ecx
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -ERESTARTSYS
.out:
    add rsp, 16
    ret

; (LFO_READY) readable with a count, writable with room for 1
lx_event_ready:
    push rcx
    xor eax, eax
    mov rcx, [rdi + LF_POS]
    test rcx, rcx
    jz .no_in
    or eax, POLLIN | POLLRDNORM
.no_in:
    cmp rcx, EVENT_MAX
    jae .no_out
    or eax, POLLOUT | POLLWRNORM
.no_out:
    xor edx, edx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  timerfd
; -----------------------------------------------------------------------------

; timerfd_create(clock, flags)
lx_sys_timerfd_create:
    mov rax, -EINVAL
    test esi, ~(O_NONBLOCK | O_CLOEXEC)
    jnz .out
    cmp edi, 1                          ; MONOTONIC, REALTIME, BOOTTIME and
    jbe .clock                          ; their ALARMs (as the others)
    cmp edi, 7
    jb .out
    cmp edi, 9
    ja .out
.clock:
    push rdi
    push rsi
    mov edi, TMR_SIZE
    call kmalloc
    pop rsi
    pop rdi
    test rax, rax
    jz .nomem
    mov [rax + TMR_CLOCK], edi
    mov rcx, rax
    lea rdi, [lx_timer_ops]
    mov edx, LFK_TIMER
    xor r8d, r8d
    jmp lx_anon_open
.nomem:
    mov rax, -ENOMEM
.out:
    ret

; lx_tm_update(RDI = a timer, its lock held): its expirations, to now.
; Preserves all.
lx_tm_update:
    push rax
    push rcx
    push rdx
    mov rcx, [rdi + TMR_NEXT]
    test rcx, rcx
    jz .out
    call lx_now_ns
    cmp rax, rcx
    jb .out
    mov rdx, [rdi + TMR_INTERVAL]
    test rdx, rdx
    jnz .periodic
    inc qword [rdi + TMR_TICKS]
    mov qword [rdi + TMR_NEXT], 0
    jmp .out
.periodic:
    sub rax, rcx                        ; past it by
    mov rcx, rdx
    xor edx, edx
    div rcx
    inc rax                             ; RAX = expirations
    add [rdi + TMR_TICKS], rax
    imul rax, rcx
    add [rdi + TMR_NEXT], rax
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; lx_tm_tsc(RDI = a timer, its lock held, updated) -> RAX = the TSC when it
; next expires, 0 if disarmed. Preserves others.
lx_tm_tsc:
    mov rax, [rdi + TMR_NEXT]
    test rax, rax
    jz .out
    push rcx
    mov rcx, rax
    call lx_now_ns
    sub rcx, rax
    jg .ahead
    mov ecx, 1
.ahead:
    mov rax, rcx
    call lx_ns_tsc
    pop rcx
.out:
    ret

; lx_tm_say(RDI = a timer, its lock held, updated, RSI = 32 bytes, kernel's):
; its struct itimerspec (the interval, then what is left)
lx_tm_say:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    mov rax, [rbx + TMR_INTERVAL]
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [r12], rax
    mov [r12 + 8], rdx
    xor eax, eax
    mov rcx, [rbx + TMR_NEXT]
    test rcx, rcx
    jz .left
    call lx_now_ns
    sub rcx, rax
    jg .ahead
    mov ecx, 1
.ahead:
    mov rax, rcx
.left:
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [r12 + 16], rax
    mov [r12 + 24], rdx
    pop r12
    pop rbx
    ret

; lx_tsk_ns(RDI = a timespec, kernel's) -> RAX = its nanoseconds (at most
; some 136 years), CF if it is not one
lx_tsk_ns:
    mov rax, [rdi]
    test rax, rax
    js .bad
    mov rcx, [rdi + 8]
    cmp rcx, 1000000000
    jae .bad
    mov rdx, 0xFFFFFFFF
    cmp rax, rdx
    cmova rax, rdx
    imul rax, rax, 1000000000
    add rax, rcx
    clc
    ret
.bad:
    stc
    ret

; timerfd_settime(fd, flags, new, old)
lx_sys_timerfd_settime:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80                         ; [rsp] = new, [+32] = old, [+64] =
    mov r12d, esi                       ; the interval, [+72] = the value
    mov r13, rdx
    mov r14, rcx
    call lx_fd_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rax, -EINVAL
    cmp dword [rbx + LF_KIND], LFK_TIMER
    jne .put
    test r12d, ~3                       ; (TFD_TIMER_CANCEL_ON_SET: no clock is set here)
    jnz .put
    mov rdi, rsp
    mov rsi, r13
    mov edx, 32
    call lx_copy_in
    cmp rax, -4095
    jae .put
    mov rax, -EINVAL
    mov rdi, rsp
    call lx_tsk_ns
    jc .put
    mov [rsp + 64], rax
    lea rdi, [rsp + 16]
    call lx_tsk_ns
    jc .put
    mov [rsp + 72], rax
    mov r15, [rbx + LF_PRIV]            ; R15 = the timer
    lea rdi, [r15 + TMR_LOCK]
    call lx_mutex_lock
    mov rdi, r15
    call lx_tm_update
    lea rsi, [rsp + 32]
    call lx_tm_say
    mov qword [r15 + TMR_TICKS], 0
    mov rax, [rsp + 64]
    mov [r15 + TMR_INTERVAL], rax
    mov rax, [rsp + 72]
    test rax, rax
    jz .set                             ; (0: disarmed)
    test r12d, TFD_TIMER_ABSTIME
    jnz .absolute
    mov rcx, rax
    call lx_now_ns
    add rax, rcx
    jmp .set
.absolute:
    mov ecx, [r15 + TMR_CLOCK]           ; the wall clock's, to ours
    test ecx, ecx
    jz .wall
    cmp ecx, 8
    jne .armed
.wall:
    sub rax, [lx_epoch_ns]
    jg .armed
    mov eax, 1                          ; (gone by: expired)
.armed:
.set:
    mov [r15 + TMR_NEXT], rax
    lea rdi, [r15 + TMR_LOCK]
    call lx_mutex_unlock
    call lx_poll_kick                   ; (waits work out their deadlines again)
    xor eax, eax
    test r14, r14
    jz .put
    mov rdi, r14
    lea rsi, [rsp + 32]
    mov edx, 32
    call lx_copy_out
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; timerfd_gettime(fd, cur)
lx_sys_timerfd_gettime:
    push rbx
    push r12
    push r13
    sub rsp, 32
    mov r12, rsi
    call lx_fd_ref
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rax, -EINVAL
    cmp dword [rbx + LF_KIND], LFK_TIMER
    jne .put
    mov r13, [rbx + LF_PRIV]
    lea rdi, [r13 + TMR_LOCK]
    call lx_mutex_lock
    mov rdi, r13
    call lx_tm_update
    mov rsi, rsp
    call lx_tm_say
    lea rdi, [r13 + TMR_LOCK]
    call lx_mutex_unlock
    mov rdi, r12
    mov rsi, rsp
    mov edx, 32
    call lx_copy_out
.put:
    mov rdi, rbx
    call lf_put
.out:
    add rsp, 32
    pop r13
    pop r12
    pop rbx
    ret

; (LFO_READ) the expirations since the last read; a wait for one
lx_timer_read:
    push r12
    push r13
    sub rsp, 16                         ; [rsp] = lx_poll_gen, [+8] = when it expires
    mov r12, rsi
    mov r13, [rbx + LF_PRIV]
    mov rax, -EINVAL
    cmp rdx, 8
    jb .out
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    lea rdi, [r13 + TMR_LOCK]
    call lx_mutex_lock
    mov rdi, r13
    call lx_tm_update
    mov rsi, [r13 + TMR_TICKS]
    test rsi, rsi
    jz .none
    mov qword [r13 + TMR_TICKS], 0
    lea rdi, [r13 + TMR_LOCK]
    call lx_mutex_unlock
    mov rdi, r12
    call lx_put64
    test rax, rax
    jnz .out
    mov eax, 8
    jmp .out
.none:
    call lx_tm_tsc
    mov [rsp + 8], rax
    lea rdi, [r13 + TMR_LOCK]
    call lx_mutex_unlock
    mov rax, -EAGAIN
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    mov rcx, [rsp + 8]
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -ERESTARTSYS
.out:
    add rsp, 16
    pop r13
    pop r12
    ret

; (LFO_READY) readable once it has expired; else when it will
lx_timer_ready:
    push rbx
    mov rbx, [rdi + LF_PRIV]
    lea rdi, [rbx + TMR_LOCK]
    call lx_mutex_lock
    mov rdi, rbx
    call lx_tm_update
    xor edx, edx
    mov eax, POLLIN | POLLRDNORM
    cmp qword [rbx + TMR_TICKS], 0
    jne .unlock
    call lx_tm_tsc
    mov rdx, rax
    xor eax, eax
.unlock:
    lea rdi, [rbx + TMR_LOCK]
    call lx_mutex_unlock
    pop rbx
    ret

; (LFO_CLOSE) a timer's last reference gone
lx_timer_close:
    mov rdi, [rdi + LF_PRIV]
    jmp kfree

; -----------------------------------------------------------------------------

; lx_event_init: the anonymous files' node (once, from lx_init)
lx_event_init:
    lea rax, [str_lx_anon]
    mov [lx_anon_node + LN_NAME], rax
    mov dword [lx_anon_node + LN_KIND], LNK_ANON
    mov dword [lx_anon_node + LN_MODE], 0o600
    mov rax, LX_ANON_INO
    mov [lx_anon_node + LN_INO], rax
    mov dword [lx_anon_node + LN_STATE], LNS_LOADED
    ret

section .rodata
align 8
lx_epoll_ops:   dq lx_anon_einval, lx_anon_einval, lx_epoll_ready, lx_epoll_close, 0
lx_event_ops:   dq lx_event_read, lx_event_write, lx_event_ready, lx_anon_nothing, 0
lx_timer_ops:   dq lx_timer_read, lx_anon_einval, lx_timer_ready, lx_timer_close, 0
str_lx_anon:    db 'anon_inode', 0

section .bss
alignb 8
lx_anon_node:   resb LN_NODE_SIZE           ; what fstat says of them (lx_event_init)
lx_ep_lock:     resd 1                      ; lx_mutex: every epoll's watches

section .text
