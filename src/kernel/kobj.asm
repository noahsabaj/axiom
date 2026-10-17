; =============================================================================
;  kobj.asm - the kinds of object: tasks, events, blocks of memory, and the
;  operations on them by handle
;
;  A task is who acts: it holds a handle table, and threads act for it. It
;  ends when nothing refers to it any more (no handle to it, no thread acting
;  for it), and then every handle it held is closed.
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
    jmp obj_put

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
    push rbx
    push r12
    push r13
    push r14
    sub rsp, EW_SIZE                    ; this thread's place on the queue
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
.again:
    pushfq
    cli
    lea rdi, [r12 + WQ_LOCK]
    call spin_lock
    cmp dword [r13], 0
    jne .set
    mov rax, [gs:PC_CURRENT]
    mov [rsp + 8 + EW_THREAD], rax      ; past the flags just pushed
    mov rax, [r12 + WQ_HEAD]
    mov [rsp + 8 + EW_NEXT], rax
    lea rax, [rsp + 8]
    mov [r12 + WQ_HEAD], rax
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
    cmp dword [r13], 0
    jne .set
    call spin_unlock
    popfq
    test r14, r14
    jz .again
    RDTSC64
    cmp rax, r14
    jb .again
    xor eax, eax
    jmp .out
.set:
    call spin_unlock
    popfq
    mov eax, 1
.out:
    add rsp, EW_SIZE
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wq_wake(RDI = queue): every thread waiting on it. From anywhere, an
; interrupt handler too. Preserves all.
wq_wake:
    push rax
    push rdi
    push rsi
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
    mov rdi, [rax + EW_THREAD]
    mov rax, [rax + EW_NEXT]            ; before it can go
    call thread_unpark
    jmp .wake
.woken:
    lea rdi, [rsi + WQ_LOCK]
    call spin_unlock
    popfq
    pop rsi
    pop rdi
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
