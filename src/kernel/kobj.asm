; =============================================================================
;  kobj.asm - the kinds of object: tasks, events, blocks of memory, and the
;  operations on them by handle
;
;  A task is who acts: it holds a handle table, and threads act for it. It
;  ends once no thread acts for it and no handle to it is left: every handle
;  it held is closed then (task_end), though what still refers to it (a
;  request waiting on a ring) keeps the object until it lets go.
;
;  An event is a flag threads wait for: signalled, it stays so until reset,
;  and every thread waiting wakes. A block of memory is pages of its own; a
;  capability to it may allow reading, writing, or both, of all of it or a
;  window.
;
;  The operations by handle act for the current thread's task and return
;  E_* when refused. They are what system calls will be:
;    h_task_new(RDI = name) -> RAX = a handle to a new task, made by this one
;    h_task_spawn(EDI = task, RSI = entry, RDX = argument, RCX = name) ->
;      RAX = a handle to a thread started acting for it (needs RT_TASK_SPAWN)
;    h_thread_wait(EDI = thread, RSI = TSC deadline or 0) -> RAX = 0 or
;      E_TIMEOUT, RDX = what it returned (needs RT_THREAD_WAIT)
;    h_event_new(RDI = name) -> RAX = a handle to a new event
;    h_event_signal(EDI), h_event_reset(EDI) (need RT_EV_SIGNAL)
;    h_event_wait(EDI, RSI = TSC deadline or 0) -> RAX = 0 or E_TIMEOUT
;      (needs RT_EV_WAIT)
;    h_mem_new(RDI = bytes, RSI = name) -> RAX = a handle to zeroed memory
;    h_mem_read(EDI, RSI = offset, RDX = to, RCX = bytes) -> RAX = bytes
;      (needs RT_MEM_READ; inside the window)
;    h_mem_write(EDI, RSI = offset, RDX = from, RCX = bytes) -> RAX = bytes
;      (needs RT_MEM_WRITE)
;    h_mem_copy(EDI = from, RSI = offset, EDX = to, RCX = offset, R8 =
;      bytes) -> RAX = bytes (needs RT_MEM_READ on one, RT_MEM_WRITE on the
;      other)
; =============================================================================

MEM_MAX         equ 64 << 20            ; the largest block of memory

section .text

; -----------------------------------------------------------------------------
;  Tasks
; -----------------------------------------------------------------------------

; task_new(RDI = name, RSI = the task making it, or 0) -> RAX = a task with
; one reference and an empty handle table; 0 if out of memory
task_new:
    push rbx
    push r12
    mov r12, rsi
    mov rdx, rdi
    mov edi, OT_TASK
    mov esi, TK_SIZE
    call obj_new
    test rax, rax
    jz .out
    mov rbx, rax
    mov rdi, rbx
    call ht_init
    test rax, rax
    jnz .nomem
    mov [rbx + TK_PARENT], r12
    test r12, r12
    jz .made
    mov rdi, r12
    call obj_get
.made:
    mov rax, rbx
    jmp .out
.nomem:
    mov rdi, rbx
    call obj_free
    xor eax, eax
.out:
    pop r12
    pop rbx
    ret

; task_destroy(RDI): its last reference went
task_destroy:
    push r12
    mov r12, rdi
    call cap_drop_all
    mov rdi, [r12 + TK_AS]              ; its pages and page tables (user.asm)
    test rdi, rdi
    jz .no_as
    call as_destroy
.no_as:
    mov rdi, [r12 + TK_SLOTS]
    call kfree
    mov rdi, [r12 + TK_PARENT]
    test rdi, rdi
    jz .free
    call obj_put
.free:
    mov rdi, r12
    call obj_free
    pop r12
    ret

; task_hold(RDI = task) / task_release(RDI): a thread starts or stops acting
; for it. Preserve all.
task_hold:
    lock inc dword [rdi + TK_THREADS]
    jmp obj_get

task_release:
    lock dec dword [rdi + TK_THREADS]
    jnz obj_put
    cmp dword [rdi + OB_CAPS], 0
    jne obj_put
    call task_end                       ; its last thread, and no handle to it
    jmp obj_put

; task_orphan(RDI): the last handle to a task went (its TY_ORPHAN)
task_orphan:
    cmp dword [rdi + TK_THREADS], 0
    je task_end
    ret

; task_end(RDI): no thread acts for it, and no handle to it is left: every
; handle it holds is closed, once. No lock held. Preserves all.
task_end:
    lock bts dword [rdi + TK_ENDED], 0
    jc .out
    push rax
    push r12
    mov r12, rdi
    call cap_drop_all
    pop r12
    pop rax
.out:
    ret

; thread_set_task(RDI = a thread not yet started, RSI = the task it is to
; act for). Preserves all.
thread_set_task:
    push rax
    mov rax, rdi
    mov rdi, rsi
    call task_hold
    xchg rdi, [rax + TH_TASK]           ; RDI = the one it had
    test rdi, rdi
    jz .out
    call task_release
.out:
    mov rdi, rax
    pop rax
    ret

h_task_new:
    push rbx
    push r12
    mov rbx, rdi
    call cur_task
    mov r12, rax
    mov rdi, rbx
    mov rsi, r12
    call task_new
    test rax, rax
    jz .nomem
    mov rdi, r12
    mov rsi, rax
    mov edx, RT_ALL
    call cap_new
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    call op_done
    pop r12
    pop rbx
    ret

h_task_spawn:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_TASK
    mov edx, RT_TASK_SPAWN
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r15, rax                        ; the task, a reference
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    call thread_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r15
    call thread_set_task
    call cur_task
    mov rdi, rax
    mov rsi, rbx                        ; its handle's reference goes into ours
    mov edx, RT_ALL
    call cap_new
    test rax, rax
    js .no_handle
    push rax
    mov rdi, rbx
    call thread_start
    pop rax
    jmp .put
.no_handle:                             ; never to start: its own reference too
    mov rdi, rbx
    call thread_put
    jmp .put
.nomem:
    mov rax, E_NOMEM
.put:
    mov rdi, r15
    call obj_put
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

h_thread_wait:
    push rbx
    push r12
    mov r12, rsi
    mov esi, OT_THREAD
    mov edx, RT_THREAD_WAIT
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    lea rdi, [rbx + TH_WQ]
    lea rsi, [rbx + TH_ENDED]
    mov rdx, r12
    call wq_wait
    mov rdx, [rbx + TH_EXIT]
    mov rdi, rbx
    call obj_put
    test eax, eax                       ; 1 -> 0, 0 -> E_TIMEOUT
    mov eax, 0
    jnz .out
    mov rax, E_TIMEOUT
.out:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Wait queues
; -----------------------------------------------------------------------------

; wq_wait(RDI = queue, RSI = a dword flag, RDX = TSC deadline or 0) -> RAX
; = 1 once the flag is set, 0 if the deadline passed first
wq_wait:
    mov rcx, rdx
    mov rdx, rsi
    lea rsi, [wq_flag]
    jmp wq_wait_fn

wq_flag:                                ; RDI = a dword flag -> EAX = it
    mov eax, [rdi]
    ret

; wq_wait_fn(RDI = queue, RSI = a test, RDX = its argument, RCX = TSC
; deadline or 0) -> RAX = 1 once the test (RDI = the argument -> EAX nonzero
; when done; the queue's lock held, so it must be quick and preserve all
; but RAX) passes, 0 if the deadline came first. Whoever makes it pass
; wakes the queue.
wq_wait_fn:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, EW_SIZE                    ; this thread's place on the queue
    mov r12, rdi
    mov r15, rsi
    mov r13, rdx
    mov r14, rcx
.again:
    pushfq
    cli
    lea rdi, [r12 + WQ_LOCK]
    call spin_lock
    mov rdi, r13
    call r15
    test eax, eax
    jnz .set
    mov rax, [gs:PC_CURRENT]
    mov [rsp + 8 + EW_THREAD], rax      ; past the flags just pushed
    mov qword [rsp + 8 + EW_FN], 0
    mov rax, [r12 + WQ_HEAD]
    mov [rsp + 8 + EW_NEXT], rax
    lea rax, [rsp + 8]
    mov [r12 + WQ_HEAD], rax
    lea rdi, [r12 + WQ_LOCK]
    call spin_unlock
    popfq
    mov rdi, r14
    call thread_park_until
    pushfq
    cli
    lea rdi, [r12 + WQ_LOCK]
    call spin_lock
    lea rax, [rsp + 8]                  ; off the queue, unless a wake took it
    lea rcx, [r12 + WQ_HEAD]
.find:
    mov rdx, [rcx]
    test rdx, rdx
    jz .off
    cmp rdx, rax
    je .unlink
    lea rcx, [rdx + EW_NEXT]
    jmp .find
.unlink:
    mov rdx, [rdx + EW_NEXT]
    mov [rcx], rdx
.off:
    mov rdi, r13
    call r15
    test eax, eax
    jnz .set
    lea rdi, [r12 + WQ_LOCK]
    call spin_unlock
    popfq
    call user_killed                    ; a thread of a task being killed
    test eax, eax                       ; waits no more
    jnz .timeout
    test r14, r14
    jz .again
    RDTSC64
    cmp rax, r14
    jb .again
.timeout:
    xor eax, eax
    jmp .out
.set:
    lea rdi, [r12 + WQ_LOCK]
    call spin_unlock
    popfq
    mov eax, 1
.out:
    add rsp, EW_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wq_add(RDI = queue, RSI = an entry, EW_THREAD and EW_FN set, RDX = a dword
; flag) -> RAX = 1 if the flag was set already (and the entry not added),
; else 0: on the queue. Preserves others.
wq_add:
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [rdi + WQ_LOCK]
    call spin_lock
    pop rdi
    mov eax, 1
    cmp dword [rdx], 0
    jne .unlock
    mov rax, [rdi + WQ_HEAD]
    mov [rsi + EW_NEXT], rax
    mov [rdi + WQ_HEAD], rsi
    xor eax, eax
.unlock:
    lea rdi, [rdi + WQ_LOCK]
    call spin_unlock
    popfq
    pop rdi
    ret

; wq_remove(RDI = queue, RSI = an entry) -> RAX = 1 if it was on the queue,
; else 0. Once it returns, no wake is calling the entry's EW_FN. Preserves
; others.
wq_remove:
    push rcx
    push rdx
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [rdi + WQ_LOCK]
    call spin_lock
    pop rdi
    lea rcx, [rdi + WQ_HEAD]
    xor eax, eax
.find:
    mov rdx, [rcx]
    test rdx, rdx
    jz .done
    cmp rdx, rsi
    je .unlink
    lea rcx, [rdx + EW_NEXT]
    jmp .find
.unlink:
    mov rdx, [rdx + EW_NEXT]
    mov [rcx], rdx
    mov eax, 1
.done:
    lea rdi, [rdi + WQ_LOCK]
    call spin_unlock
    popfq
    pop rdi
    pop rdx
    pop rcx
    ret

; wq_wake(RDI = queue): every thread waiting on it unparked, every EW_FN
; called. From anywhere, an interrupt handler too. Preserves all.
wq_wake:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    pushfq
    cli
    mov rsi, rdi
    lea rdi, [rsi + WQ_LOCK]
    call spin_lock
    mov rax, [rsi + WQ_HEAD]
    mov qword [rsi + WQ_HEAD], 0
.wake:
    test rax, rax
    jz .woken
    mov rdi, rax
    mov rax, [rax + EW_NEXT]            ; before it can go
    cmp qword [rdi + EW_FN], 0
    jne .call
    mov rdi, [rdi + EW_THREAD]
    call thread_unpark
    jmp .wake
.call:
    push rax
    push rsi
    call [rdi + EW_FN]
    pop rsi
    pop rax
    jmp .wake
.woken:
    lea rdi, [rsi + WQ_LOCK]
    call spin_unlock
    popfq
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
;  Events
; -----------------------------------------------------------------------------

; event_new(RDI = name) -> RAX = an event, not signalled, or 0
event_new:
    mov rdx, rdi
    mov edi, OT_EVENT
    mov esi, EV_SIZE
    jmp obj_new

; event_signal(RDI) / event_reset(RDI). Preserve all.
event_signal:
    mov dword [rdi + EV_STATE], 1
    lock inc qword [rdi + EV_SIGNALS]
    push rdi
    lea rdi, [rdi + EV_WQ]
    call wq_wake
    pop rdi
    ret

event_reset:
    mov dword [rdi + EV_STATE], 0
    ret

; event_wait(RDI, RSI = TSC deadline or 0) -> RAX = 1 if signalled, 0 if the
; deadline passed
event_wait:
    lea rdx, [rdi + EV_STATE]
    xchg rdx, rsi
    lea rdi, [rdi + EV_WQ]
    jmp wq_wait

h_event_new:
    call event_new
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov esi, RT_ALL
    call handle_new
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    jmp op_done

h_event_signal:
    mov esi, OT_EVENT
    mov edx, RT_EV_SIGNAL
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call event_signal
    call obj_put
    xor eax, eax
.out:
    ret

h_event_reset:
    mov esi, OT_EVENT
    mov edx, RT_EV_SIGNAL
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call event_reset
    call obj_put
    xor eax, eax
.out:
    ret

h_event_wait:
    push rbx
    push r12
    mov r12, rsi
    mov esi, OT_EVENT
    mov edx, RT_EV_WAIT
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rdi, rbx
    mov rsi, r12
    call event_wait
    mov rdi, rbx
    call obj_put
    test eax, eax                       ; 1 -> 0, 0 -> E_TIMEOUT
    mov eax, 0
    jnz .out
    mov rax, E_TIMEOUT
.out:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Memory
; -----------------------------------------------------------------------------

; mem_new(RDI = bytes, RSI = name) -> RAX = a block of that many zeroed
; bytes, in whole pages; 0 if out of memory or too large
mem_new:
    push rbx
    push r12
    lea r12, [rdi + 4095]
    and r12, -4096
    jz .none
    cmp r12, MEM_MAX
    ja .none
    mov rdx, rsi
    mov edi, OT_MEMORY
    mov esi, MO_SIZE
    call obj_new
    test rax, rax
    jz .out
    mov rbx, rax
    mov rdi, r12
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [rbx + MO_BASE], rax
    mov [rbx + MO_BYTES], r12
    mov rax, rbx
    jmp .out
.nomem:
    mov rdi, rbx
    call obj_free
.none:
    xor eax, eax
.out:
    pop r12
    pop rbx
    ret

mem_destroy:
    push rdi
    mov rdi, [rdi + MO_BASE]
    test rdi, rdi
    jz .free
    call vm_free
.free:
    pop rdi
    jmp obj_free

h_mem_new:
    call mem_new
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov esi, RT_ALL
    call handle_new
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    jmp op_done

h_mem_copy:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; where in the first
    mov r13d, edx                       ; the second
    mov r14, rcx                        ; where in it
    mov r15, r8                         ; bytes
    mov esi, OT_MEMORY
    mov edx, RT_MEM_READ
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rbx, rax
    mov rax, E_RANGE                    ; inside its window
    sub rcx, r12
    jb .put_from
    cmp r15, rcx
    ja .put_from
    add r12, rdx                        ; from its first byte
    mov edi, r13d
    mov esi, OT_MEMORY
    mov edx, RT_MEM_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .put_from
    mov rbp, rax
    mov rax, E_RANGE
    sub rcx, r14
    jb .put_to
    cmp r15, rcx
    ja .put_to
    add r14, rdx
    mov rsi, [rbx + MO_BASE]
    add rsi, r12
    mov rdi, [rbp + MO_BASE]
    add rdi, r14
    mov rcx, r15
    cmp rdi, rsi                        ; overlapping, the end first
    jbe .forward
    lea rax, [rsi + rcx]
    cmp rdi, rax
    jae .forward
.backward:
    test rcx, rcx
    jz .copied
    dec rcx
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    jmp .backward
.forward:
    rep movsb
.copied:
    mov rax, r15
.put_to:
    mov rdi, rbp
    call obj_put
.put_from:
    mov rdi, rbx
    call obj_put
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

h_mem_read:
    push rbx
    mov ebx, RT_MEM_READ
    jmp mem_copy

h_mem_write:
    push rbx
    mov ebx, RT_MEM_WRITE

; mem_copy (RBX pushed, EBX = the right needed; the arguments of h_mem_read
; and h_mem_write)
mem_copy:
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; the offset in the window
    mov r13, rdx                        ; the kernel's buffer
    mov r14, rcx                        ; bytes
    mov esi, OT_MEMORY
    mov edx, ebx
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r15, rax
    mov rax, E_RANGE                    ; inside the window
    sub rcx, r12
    jb .put
    cmp r14, rcx
    ja .put
    mov rsi, [r15 + MO_BASE]
    add rsi, rdx
    add rsi, r12
    mov rdi, r13
    cmp ebx, RT_MEM_READ
    je .copy
    xchg rsi, rdi
.copy:
    mov rcx, r14
    rep movsb
    mov rax, r14
.put:
    mov rdi, r15
    call obj_put
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
