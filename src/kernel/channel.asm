; =============================================================================
;  channel.asm - channels: messages between tasks
;
;  A channel is two ends, each an object (OT_CHANNEL, CH_*). What is sent
;  from one end waits at the other, oldest first, a copy of its bytes. A
;  task keeps one end and hands the other on: RO_GIVE to a task it holds,
;  or as the gift of SYS_SPAWN. On a ring:
;    RO_SEND (an end, handle2 + a0: a1 bytes) copies a block of memory's
;      bytes into a message; E_FULL if CH_QUEUE_MAX wait already
;    RO_RECV (an end, handle2 + a0: room for a1 bytes) copies the next one
;      out -> its bytes; E_EMPTY if none waits, E_RANGE (and it stays) if
;      it does not fit
;    RO_WAIT on an end waits, blocking nothing, until a message is there or
;      the other end has gone; linked to an RO_RECV, it receives the next
;      message when it comes
;  When either end's last handle goes, the other's sends say E_PEER, and
;  so do its receives, once what was sent before is read.
;
;    h_channel_new -> RAX, RDX = handles to the two ends (RT_ALL)
;    h_ch_send(EDI = an end, ESI = memory, RDX = offset, RCX = bytes) ->
;      RAX = bytes (needs RT_CH_SEND, and RT_MEM_READ on the memory)
;    h_ch_recv(EDI, ESI = memory, RDX = offset, RCX = room) -> RAX = bytes
;      (needs RT_CH_RECV, and RT_MEM_WRITE)
;    ch_post(RDI = an end, RSI = bytes in the kernel, RDX = how many) -> RAX
;      = bytes, or E_*: the kernel's own send (a window's events)
;  ch_lock covers every channel's ends and queues, taken with interrupts
;  off; waiters are woken under it. No memory is copied with it held.
; =============================================================================

CH_MSG_MAX      equ 4096                ; bytes in a message, at most
CH_QUEUE_MAX    equ 64                  ; messages waiting at an end, at most

; a message, from the heap
CM_NEXT         equ 0
CM_LEN          equ 8
CM_DATA         equ 16

%macro CH_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [ch_lock]
    call spin_lock
    pop rdi
%endmacro

%macro CH_UNLOCK 0
    push rdi
    lea rdi, [ch_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

h_channel_new:
    push rbx
    push r12
    push r13
    mov edi, OT_CHANNEL
    mov esi, CH_SIZE
    lea rdx, [str_ot_channel]
    call obj_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov edi, OT_CHANNEL
    mov esi, CH_SIZE
    lea rdx, [str_ot_channel]
    call obj_new
    test rax, rax
    jz .nomem_one
    mov r12, rax
    mov [rbx + CH_PEER], r12            ; no other has them yet
    mov [r12 + CH_PEER], rbx
    mov rdi, rbx
    mov esi, RT_ALL
    call handle_new                     ; refused: that end is gone
    cmp rax, E_ANY
    jae .no_first
    mov r13, rax
    mov rdi, r12
    mov esi, RT_ALL
    call handle_new
    cmp rax, E_ANY
    jae .no_second
    mov rdx, rax
    mov rax, r13
    jmp .out
.no_second:
    push rax
    mov edi, r13d
    call handle_close
    pop rax
    jmp .zero
.no_first:
    mov rdi, r12
    call obj_put
    jmp .zero
.nomem_one:
    mov rdi, rbx
    call obj_put
.nomem:
    mov rax, E_NOMEM
.zero:
    xor edx, edx
.out:
    call op_done
    pop r13
    pop r12
    pop rbx
    ret

h_ch_send:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_CHANNEL
    mov edx, RT_CH_SEND
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax                        ; RBX = this end, a reference
    mov rax, E_ARG
    cmp r14, CH_MSG_MAX
    ja .put
    lea rdi, [r14 + CM_DATA]
    call kmalloc
    test rax, rax
    jz .nomem
    mov r15, rax                        ; R15 = the message
    mov [r15 + CM_LEN], r14
    test r14, r14
    jz .send
    mov edi, r12d
    mov rsi, r13
    lea rdx, [r15 + CM_DATA]
    mov rcx, r14
    call h_mem_read
    cmp rax, E_ANY
    jae .free
.send:
    CH_LOCK
    mov rdi, [rbx + CH_PEER]
    mov rax, E_PEER
    test rdi, rdi
    jz .refused
    mov rax, E_FULL
    cmp dword [rdi + CH_COUNT], CH_QUEUE_MAX
    jae .refused
    mov rax, [rdi + CH_TAIL]            ; last in line
    test rax, rax
    jz .first
    mov [rax + CM_NEXT], r15
    jmp .queued
.first:
    mov [rdi + CH_HEAD], r15
.queued:
    mov [rdi + CH_TAIL], r15
    inc dword [rdi + CH_COUNT]
    inc qword [rbx + CH_SENT]
    call ch_wake
    CH_UNLOCK
    mov rax, r14
    jmp .put
.refused:
    CH_UNLOCK
.free:
    push rax
    mov rdi, r15
    call kfree
    pop rax
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    mov rdi, rbx
    call obj_put
.out:
    call op_done
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

h_ch_recv:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_CHANNEL
    mov edx, RT_CH_RECV
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax                        ; RBX = this end, a reference
    CH_LOCK
    mov r15, [rbx + CH_HEAD]            ; R15 = the next message
    test r15, r15
    jz .none
    mov rax, E_RANGE
    cmp [r15 + CM_LEN], r14
    ja .unlock                          ; it does not fit: it stays
    mov rax, [r15 + CM_NEXT]
    mov [rbx + CH_HEAD], rax
    test rax, rax
    jnz .taken
    mov [rbx + CH_TAIL], rax
.taken:
    dec dword [rbx + CH_COUNT]
    mov rdi, rbx
    call ch_settle
    CH_UNLOCK
    mov rcx, [r15 + CM_LEN]
    test rcx, rcx
    jz .got
    mov edi, r12d
    mov rsi, r13
    lea rdx, [r15 + CM_DATA]
    call h_mem_write
    cmp rax, E_ANY
    jae .back
.got:
    lock inc qword [rbx + CH_RECEIVED]
    mov r14, [r15 + CM_LEN]
    mov rdi, r15
    call kfree
    mov rax, r14
    jmp .put
.back:                                  ; not written: first in line again
    CH_LOCK
    mov rcx, [rbx + CH_HEAD]
    mov [r15 + CM_NEXT], rcx
    mov [rbx + CH_HEAD], r15
    test rcx, rcx
    jnz .again
    mov [rbx + CH_TAIL], r15
.again:
    inc dword [rbx + CH_COUNT]
    mov rdi, rbx
    call ch_settle
    jmp .unlock
.none:
    mov rax, E_EMPTY
    cmp qword [rbx + CH_PEER], 0
    jne .unlock
    mov rax, E_PEER
.unlock:
    CH_UNLOCK
.put:
    mov rdi, rbx
    call obj_put
.out:
    call op_done
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ch_post:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rax, E_ARG
    cmp r13, CH_MSG_MAX
    ja .out
    lea rdi, [r13 + CM_DATA]
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rax + CM_LEN], r13
    lea rdi, [rax + CM_DATA]
    mov rsi, r12
    mov rcx, r13
    rep movsb
    mov r12, rax                        ; R12 = the message
    CH_LOCK
    mov rdi, [rbx + CH_PEER]
    mov rax, E_PEER
    test rdi, rdi
    jz .refused
    mov rax, E_FULL
    cmp dword [rdi + CH_COUNT], CH_QUEUE_MAX
    jae .refused
    mov rax, [rdi + CH_TAIL]
    test rax, rax
    jz .first
    mov [rax + CM_NEXT], r12
    jmp .queued
.first:
    mov [rdi + CH_HEAD], r12
.queued:
    mov [rdi + CH_TAIL], r12
    inc dword [rdi + CH_COUNT]
    inc qword [rbx + CH_SENT]
    call ch_wake
    CH_UNLOCK
    mov rax, r13
    jmp .out
.refused:
    CH_UNLOCK
    push rax
    mov rdi, r12
    call kfree
    pop rax
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop r13
    pop r12
    pop rbx
    ret

; ch_wake(RDI = an end), ch_lock held: something to see there; whatever
; waits is woken. Preserves all.
ch_wake:
    mov dword [rdi + CH_READY], 1
    push rdi
    lea rdi, [rdi + CH_WQ]
    call wq_wake
    pop rdi
    ret

; ch_settle(RDI = an end), ch_lock held: CH_READY again, once a message was
; taken or put back. Preserves all.
ch_settle:
    cmp dword [rdi + CH_COUNT], 0
    jne ch_wake
    cmp qword [rdi + CH_PEER], 0
    je ch_wake
    mov dword [rdi + CH_READY], 0
    ret

; ch_cut(RDI = an end): it and its peer, apart; whatever waits at either is
; woken. No lock held. Preserves all.
ch_cut:
    CH_LOCK
    push rax
    mov rax, [rdi + CH_PEER]
    test rax, rax
    jz .cut
    mov qword [rax + CH_PEER], 0
    mov qword [rdi + CH_PEER], 0
    push rdi
    mov rdi, rax
    call ch_wake
    pop rdi
.cut:
    call ch_wake
    pop rax
    CH_UNLOCK
    ret

; ch_orphan(RDI): no handle to this end is left (its TY_ORPHAN)
ch_orphan:
    jmp ch_cut

; ch_destroy(RDI): its last reference went; what still waited at it goes
ch_destroy:
    push rbx
    push r12
    mov rbx, rdi
    call ch_cut
    mov r12, [rbx + CH_HEAD]
.message:
    test r12, r12
    jz .free
    mov rdi, r12
    mov r12, [r12 + CM_NEXT]
    call kfree
    jmp .message
.free:
    mov rdi, rbx
    call obj_free
    pop r12
    pop rbx
    ret

section .rodata
str_ot_channel: db 'channel', 0

section .bss
alignb 4
ch_lock:        resd 1
