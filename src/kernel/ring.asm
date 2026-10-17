; =============================================================================
;  ring.asm - rings: how a task asks for many things at once, and hears when
;  each is done; and the kernel's timers
;
;  A ring is a submission queue and a completion queue in a block of memory
;  the task shares with the kernel (RA_*). The task writes entries (SQ_*)
;  and moves the submission tail; h_ring_enter takes them and does each,
;  and for each writes one completion (CQ_*) carrying the entry's data back;
;  the task reads those and moves the completion head. One h_ring_enter
;  takes any number of entries and waits for any number of completions, or
;  for none.
;
;  Most operations are done at once, inside h_ring_enter. Waiting for an
;  event or a message (RO_WAIT on an event or a channel's end), for a
;  thread to end, or for a time (RO_WAIT, RO_JOIN, RO_TIMEOUT)
;  blocks nothing: each becomes a request, whose completion is written when
;  it happens, from whatever made it happen, an interrupt handler too.
;  Entries linked (SQF_LINK) run in order, each once the one before it
;  succeeded; when one fails, the rest of the chain completes E_CANCELED.
;  RO_CANCEL takes back requests still waiting. Every entry taken gets one
;  completion, and an entry is taken only when its completion has a place
;  waiting for it: a full completion queue leaves entries where they are.
;
;  The thread 'async' finishes each request once it has completed: off its
;  wait queue and its timer, references dropped, and what was linked after
;  it done, acting for the task that asked. It also runs the kernel's timers
;  (timer_add, timer_cancel: a heap by deadline), each on that thread.
;
;  When no handle to a ring is left, whatever still waits on it is canceled.
;
;    h_ring_new(EDI = entries, a power of two up to RING_MAX, RSI = name) ->
;      RAX = a handle to the ring, RDX = a handle to its memory; twice as
;      many completions as entries
;    h_ring_enter(EDI = ring, ESI = entries to take, at most, EDX =
;      completions to wait for, RCX = TSC deadline or 0) -> RAX = entries
;      taken (needs RT_RING_ENTER); E_ARG if the indices make no sense
; =============================================================================

RING_MAX        equ 4096
RING_CHAIN      equ 16                  ; linked entries in one chain, at most
TM_FIRST        equ 64                  ; places in the timers' heap at first

; a request: an entry that waits
RQ_STATE        equ 0                   ; dword RQS_*
RQ_HOW          equ 4                   ; dword HOW_*: what completed it
RQ_RING         equ 8                   ; its ring, a reference once armed
RQ_TASK         equ 16                  ; the task it acts for, a reference
RQ_OBJ          equ 24                  ; what it waits for, a reference
RQ_WQ           equ 32                  ; the queue it waits on
RQ_ENTRY        equ 40                  ; EW_SIZE: its place there
RQ_TIMER        equ 64                  ; TM_SIZE: its deadline
RQ_RESULT       equ 96
RQ_NEXT         equ 104                 ; what is linked after it
RQ_PNEXT        equ 112                 ; its ring's requests waiting
RQ_PPREV        equ 120
RQ_DONE         equ 128                 ; those for the thread 'async' to finish
RQ_SQE          equ 136                 ; SQ_SIZE: its entry
RQ_SIZE         equ 200

RQS_ARMING      equ 1                   ; going onto its queue and timer
RQS_PENDING     equ 2
RQS_DONE        equ 3                   ; completed, to be finished
RQS_EARLY       equ 4                   ; + HOW_*: completed while arming

HOW_WAKE        equ 0
HOW_TIMEOUT     equ 1
HOW_CANCEL      equ 2
HOW_NOMEM       equ 3

; a timer, inside what it is for
TM_DEADLINE     equ 0                   ; TSC
TM_FN           equ 8                   ; (RDI = TM_ARG), on the thread 'async'
TM_ARG          equ 16
TM_INDEX        equ 24                  ; dword: its place in the heap, -1 if none
TM_SIZE         equ 32

%macro TM_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [tm_lock]
    call spin_lock
    pop rdi
%endmacro

%macro TM_UNLOCK 0
    push rdi
    lea rdi, [tm_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

; -----------------------------------------------------------------------------
;  Timers
; -----------------------------------------------------------------------------

; timer_add(RDI = a timer, TM_DEADLINE, TM_FN and TM_ARG set, not queued) ->
; RAX = 0, or E_NOMEM. Preserves others.
timer_add:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, rdi
.retry:
    TM_LOCK
    mov ecx, [tm_count]
    cmp ecx, [tm_cap]
    jae .grow
    mov rsi, [tm_heap]
    mov [rsi + rcx * 8], rbx
    mov [rbx + TM_INDEX], ecx
    inc dword [tm_count]
    mov edi, ecx
    call tm_up
    TM_UNLOCK
    test eax, eax
    jnz .added
    mov rdi, [async_thread]             ; the soonest now: it looks again
    test rdi, rdi
    jz .added
    call thread_unpark
.added:
    xor eax, eax
    jmp .out
.grow:
    TM_UNLOCK
    mov edx, [tm_cap]
    add edx, edx
    lea rdi, [rdx * 8]
    call kmalloc
    test rax, rax
    jz .nomem
    TM_LOCK
    mov ecx, [tm_count]
    cmp ecx, [tm_cap]
    jb .raced                           ; another grew it, or one went
    mov rsi, [tm_heap]
    mov rdi, rax
    rep movsq
    xchg rax, [tm_heap]                 ; RAX = the old one, to free
    mov [tm_cap], edx
.raced:
    TM_UNLOCK
    mov rdi, rax
    call kfree
    jmp .retry
.nomem:
    mov rax, E_NOMEM
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; timer_cancel(RDI = a timer) -> RAX = 1 if it was queued, now not; 0 if it
; was not (never added, or due and taken). Preserves others.
timer_cancel:
    TM_LOCK
    mov eax, [rdi + TM_INDEX]
    cmp eax, -1
    je .none
    push rdi
    mov edi, eax
    call tm_take
    pop rdi
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    TM_UNLOCK
    ret

; timer_due(RDI = TSC now) -> RAX = a timer due, taken off the heap, or 0;
; then RDX = the soonest deadline left, 0 if none
timer_due:
    TM_LOCK
    xor eax, eax
    xor edx, edx
    cmp dword [tm_count], 0
    je .out
    mov rdx, [tm_heap]
    mov rdx, [rdx]                      ; the soonest
    cmp [rdx + TM_DEADLINE], rdi
    ja .later
    mov rax, rdx
    push rdi
    xor edi, edi
    call tm_take
    pop rdi
    xor edx, edx
    jmp .out
.later:
    mov rdx, [rdx + TM_DEADLINE]
.out:
    TM_UNLOCK
    ret

; tm_up(EDI = a place in the heap) -> EAX = where that timer ends, moved
; toward the root while sooner than its parent. tm_lock held. Preserves
; others.
tm_up:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rsi, [tm_heap]
    mov eax, edi
.up:
    test eax, eax
    jz .out
    lea ecx, [rax - 1]
    shr ecx, 1                          ; its parent
    mov rdx, [rsi + rax * 8]
    mov r8, [rsi + rcx * 8]
    mov rdi, [rdx + TM_DEADLINE]
    cmp rdi, [r8 + TM_DEADLINE]
    jae .out
    mov [rsi + rax * 8], r8
    mov [r8 + TM_INDEX], eax
    mov [rsi + rcx * 8], rdx
    mov [rdx + TM_INDEX], ecx
    mov eax, ecx
    jmp .up
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; tm_down(EDI = a place) -> EAX = where that timer ends, moved away from the
; root while later than a child. tm_lock held. Preserves others.
tm_down:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov rsi, [tm_heap]
    mov eax, edi
.down:
    lea ecx, [rax * 2 + 1]              ; its first child
    cmp ecx, [tm_count]
    jae .out
    lea edx, [rcx + 1]
    cmp edx, [tm_count]
    jae .child
    mov r8, [rsi + rcx * 8]
    mov r9, [rsi + rdx * 8]
    mov rdi, [r9 + TM_DEADLINE]
    cmp rdi, [r8 + TM_DEADLINE]
    jae .child
    mov ecx, edx                        ; the second is sooner
.child:
    mov r8, [rsi + rax * 8]
    mov r9, [rsi + rcx * 8]
    mov rdi, [r9 + TM_DEADLINE]
    cmp rdi, [r8 + TM_DEADLINE]
    jae .out
    mov [rsi + rax * 8], r9
    mov [r9 + TM_INDEX], eax
    mov [rsi + rcx * 8], r8
    mov [r8 + TM_INDEX], ecx
    mov eax, ecx
    jmp .down
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; tm_take(EDI = a place): that timer off the heap (TM_INDEX -1), the last
; one in its place. tm_lock held. Preserves all.
tm_take:
    push rax
    push rcx
    push rsi
    push rdi
    mov edi, edi
    mov rsi, [tm_heap]
    mov rax, [rsi + rdi * 8]
    mov dword [rax + TM_INDEX], -1
    dec dword [tm_count]
    mov ecx, [tm_count]                 ; the last
    cmp edi, ecx
    je .out
    mov rax, [rsi + rcx * 8]
    mov [rsi + rdi * 8], rax
    mov [rax + TM_INDEX], edi
    call tm_down
    mov edi, eax
    call tm_up
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The thread 'async'
; -----------------------------------------------------------------------------

; async_boot: once the scheduler is up; the timers' heap, and the thread
async_boot:
    mov edi, TM_FIRST * 8
    call kmalloc
    test rax, rax
    jz .oom
    mov [tm_heap], rax
    mov dword [tm_cap], TM_FIRST
    lea rdi, [async_main]
    xor esi, esi
    lea rdx, [str_async]
    mov ecx, THC_ANY
    call thread_spawn
    test rax, rax
    jz .oom
    mov [async_thread], rax             ; its handle, kept
    ret
.oom:
    xor edi, edi
    lea rsi, [str_async_oom]
    jmp panic

async_main:
.loop:
    pushfq                              ; the requests completed
    cli
    lea rdi, [as_lock]
    call spin_lock
    xor ebx, ebx
    xchg rbx, [as_list]
    call spin_unlock
    popfq
.finish:
    test rbx, rbx
    jz .timers
    mov rdi, rbx
    mov rbx, [rbx + RQ_DONE]
    call rq_finish
    inc qword [as_finished]
    jmp .finish
.timers:
    RDTSC64
    mov rdi, rax
    call timer_due
    test rax, rax
    jz .park
    inc qword [tm_fired]
    mov rdi, [rax + TM_ARG]
    call [rax + TM_FN]
    jmp .loop
.park:
    mov rdi, rdx                        ; until the next timer, or a push
    call thread_park_until
    jmp .loop

; as_push(RDI = a request completed): for the thread 'async' to finish. From
; anywhere. Preserves all.
as_push:
    push rax
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [as_lock]
    call spin_lock
    pop rdi
    mov rax, [as_list]
    mov [rdi + RQ_DONE], rax
    mov [as_list], rdi
    lea rdi, [as_lock]
    call spin_unlock
    popfq
    mov rdi, [async_thread]
    call thread_unpark
    pop rdi
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Requests
; -----------------------------------------------------------------------------

; rq_new(RDI = an entry) -> RAX = a request holding a copy of it, or 0.
; Preserves others.
rq_new:
    push rcx
    push rsi
    push rdi
    mov rsi, rdi
    mov edi, RQ_SIZE
    call kmalloc
    test rax, rax
    jz .out
    lock inc qword [rq_live]
    mov dword [rax + RQ_TIMER + TM_INDEX], -1
    lea rdi, [rax + RQ_SQE]
    mov ecx, SQ_SIZE / 8
    rep movsq
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; rq_free(RDI). Preserves all.
rq_free:
    lock dec qword [rq_live]
    jmp kfree

; rq_claim(RDI = a request, ESI = HOW_*) -> EAX = 1: the caller completes it
; (rq_complete); 2: noted while it is being armed, and its arming completes
; it; 0: already completed. Preserves others.
rq_claim:
    push rcx
.again:
    mov eax, [rdi + RQ_STATE]
    cmp eax, RQS_PENDING
    jne .arming
    mov ecx, RQS_DONE
    lock cmpxchg [rdi + RQ_STATE], ecx
    jne .again
    mov [rdi + RQ_HOW], esi
    mov eax, 1
    pop rcx
    ret
.arming:
    cmp eax, RQS_ARMING
    jne .late
    lea ecx, [rsi + RQS_EARLY]
    lock cmpxchg [rdi + RQ_STATE], ecx
    jne .again
    mov eax, 2
    pop rcx
    ret
.late:
    xor eax, eax
    pop rcx
    ret

; rq_complete(RDI = a request claimed): its result from RQ_HOW, its
; completion written, and on to the thread 'async'. From anywhere.
; Preserves all.
rq_complete:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    mov eax, [rdi + RQ_HOW]
    movzx r8d, byte [rdi + RQ_SQE + SQ_OP]
    xor ecx, ecx                        ; the value
    cmp eax, HOW_WAKE
    jne .not_woken
    xor edx, edx
    cmp r8d, RO_JOIN
    jne .result
    mov rcx, [rdi + RQ_OBJ]             ; what the thread returned
    mov rcx, [rcx + TH_EXIT]
    jmp .result
.not_woken:
    mov rdx, E_CANCELED
    cmp eax, HOW_CANCEL
    je .result
    mov rdx, E_NOMEM
    cmp eax, HOW_NOMEM
    je .result
    mov rdx, E_TIMEOUT                  ; its deadline came
    cmp r8d, RO_TIMEOUT
    jne .result
    xor edx, edx                        ; which is what RO_TIMEOUT waits for
.result:
    mov [rdi + RQ_RESULT], rdx
    mov rsi, [rdi + RQ_SQE + SQ_DATA]
    push rdi
    mov rdi, [rdi + RQ_RING]
    call ring_post
    pop rdi
    call as_push
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rq_fire(RDI = a request's wait-queue entry): what it waits for happened
; (its EW_FN; the queue's lock held). Preserves all.
rq_fire:
    push rax
    push rsi
    push rdi
    sub rdi, RQ_ENTRY
    mov esi, HOW_WAKE
    call rq_claim
    cmp eax, 1
    jne .out
    call rq_complete
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; rq_timeout(RDI = a request): its deadline came (its TM_FN)
rq_timeout:
    mov esi, HOW_TIMEOUT
    call rq_claim
    cmp eax, 1
    jne .out
    call rq_complete
.out:
    ret

; ring_arm(RDI = ring, RSI = a request: its entry, one that waits, and what
; is linked after it in RQ_NEXT) -> RAX = 0: it waits now (or completed
; already); else E_*: refused, nothing done. Acts for the current task.
ring_arm:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov rbx, rsi
    xor r13d, r13d                      ; what it waits for
    xor r14d, r14d                      ; and the flag that says it happened
    movzx eax, byte [rbx + RQ_SQE + SQ_OP]
    cmp eax, RO_TIMEOUT
    je .timeout
    mov edi, [rbx + RQ_SQE + SQ_HANDLE]
    cmp eax, RO_JOIN
    je .join
    push rdi
    call handle_info                    ; an event, or a channel's end
    pop rdi
    cmp rax, E_ANY
    jae .out                            ; refused (and counted) once
    cmp rax, OT_CHANNEL
    je .channel
    mov esi, OT_EVENT
    mov edx, RT_EV_WAIT
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r13, rax
    lea r14, [r13 + EV_STATE]
    lea rax, [r13 + EV_WQ]
    jmp .queue
.join:
    mov esi, OT_THREAD
    mov edx, RT_THREAD_WAIT
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r13, rax
    lea r14, [r13 + TH_ENDED]
    lea rax, [r13 + TH_WQ]
    jmp .queue
.channel:                               ; until a message waits, or its peer is gone
    mov esi, OT_CHANNEL
    mov edx, RT_CH_RECV
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r13, rax
    lea r14, [r13 + CH_READY]
    lea rax, [r13 + CH_WQ]
.queue:
    mov [rbx + RQ_WQ], rax
    jmp .arm
.timeout:
    mov rax, E_ARG                      ; it needs a time to wait for
    cmp qword [rbx + RQ_SQE + SQ_DEADLINE], 0
    je .out
.arm:
    mov [rbx + RQ_OBJ], r13
    mov dword [rbx + RQ_STATE], RQS_ARMING
    mov rdi, r12
    call obj_get
    mov [rbx + RQ_RING], r12
    call cur_task
    mov rdi, rax
    call obj_get
    mov [rbx + RQ_TASK], rax
    pushfq                              ; on its ring's list of those waiting
    cli
    lea rdi, [r12 + RG_LOCK]
    call spin_lock
    mov rax, [r12 + RG_PENDING]
    mov [rbx + RQ_PNEXT], rax
    mov qword [rbx + RQ_PPREV], 0
    test rax, rax
    jz .first
    mov [rax + RQ_PPREV], rbx
.first:
    mov [r12 + RG_PENDING], rbx
    inc dword [r12 + RG_LIVE]
    inc qword [r12 + RG_ASYNC]
    bt dword [r12 + RG_FLAGS], RGF_ORPHAN
    setc cl
    call spin_unlock
    popfq
    test cl, cl
    jz .wait_queue
    mov rdi, rbx                        ; no handle to its ring is left
    mov esi, HOW_CANCEL
    call rq_claim
.wait_queue:
    mov rdi, [rbx + RQ_WQ]
    test rdi, rdi
    jz .deadline
    lea rsi, [rbx + RQ_ENTRY]
    mov [rsi + EW_THREAD], rbx
    lea rax, [rq_fire]
    mov [rsi + EW_FN], rax
    mov rdx, r14
    call wq_add
    test eax, eax
    jz .deadline
    mov rdi, rbx                        ; it had happened already
    mov esi, HOW_WAKE
    call rq_claim
.deadline:
    mov rax, [rbx + RQ_SQE + SQ_DEADLINE]
    test rax, rax
    jz .armed
    mov [rbx + RQ_TIMER + TM_DEADLINE], rax
    lea rax, [rq_timeout]
    mov [rbx + RQ_TIMER + TM_FN], rax
    mov [rbx + RQ_TIMER + TM_ARG], rbx
    lea rdi, [rbx + RQ_TIMER]
    call timer_add
    test rax, rax
    jz .armed
    mov rdi, rbx
    mov esi, HOW_NOMEM
    call rq_claim
.armed:
    mov eax, RQS_ARMING                 ; it waits, unless something came first
    mov ecx, RQS_PENDING
    lock cmpxchg [rbx + RQ_STATE], ecx
    je .done
    sub eax, RQS_EARLY
    mov [rbx + RQ_HOW], eax
    mov dword [rbx + RQ_STATE], RQS_DONE
    mov rdi, rbx
    call rq_complete
.done:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rq_finish(RDI = a request completed): on the thread 'async', off its queue
; and timer, its references dropped, and what was linked after it run
rq_finish:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov rdi, [rbx + RQ_WQ]
    test rdi, rdi
    jz .no_queue
    lea rsi, [rbx + RQ_ENTRY]
    call wq_remove
.no_queue:
    lea rdi, [rbx + RQ_TIMER]
    call timer_cancel
    mov rdi, [rbx + RQ_OBJ]
    test rdi, rdi
    jz .no_obj
    call obj_put
.no_obj:
    mov r12, [rbx + RQ_RING]
    pushfq                              ; off its ring's list
    cli
    lea rdi, [r12 + RG_LOCK]
    call spin_lock
    mov rax, [rbx + RQ_PNEXT]
    mov rcx, [rbx + RQ_PPREV]
    test rax, rax
    jz .no_next
    mov [rax + RQ_PPREV], rcx
.no_next:
    test rcx, rcx
    jz .head
    mov [rcx + RQ_PNEXT], rax
    jmp .unlinked
.head:
    mov [r12 + RG_PENDING], rax
.unlinked:
    dec dword [r12 + RG_LIVE]
    call spin_unlock
    popfq
    mov rsi, [rbx + RQ_NEXT]            ; what was linked after it
    test rsi, rsi
    jz .put
    xor edx, edx
    mov rax, [rbx + RQ_RESULT]
    cmp rax, E_ANY
    setae dl                            ; it failed: the rest are canceled
    mov rax, [gs:PC_CURRENT]            ; done acting for its task
    mov r13, [rax + TH_TASK]
    mov rcx, [rbx + RQ_TASK]
    mov [rax + TH_TASK], rcx
    mov rdi, r12
    call ring_run
    mov rax, [gs:PC_CURRENT]
    mov [rax + TH_TASK], r13
.put:
    mov rdi, [rbx + RQ_TASK]
    call obj_put
    mov rdi, r12
    call obj_put
    mov rdi, rbx
    call rq_free
    pop r13
    pop r12
    pop rbx
    ret

; ring_run(RDI = ring, RSI = requests linked through RQ_NEXT, EDX = 1 if
; they are canceled): each done in order, for the current task, until one
; waits (and holds the rest); each completed is freed
ring_run:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov rbx, rsi
    mov r13d, edx
.next:
    test rbx, rbx
    jz .out
    mov r14, [rbx + RQ_NEXT]
    mov rdx, E_CANCELED
    test r13d, r13d
    jnz .post
    movzx eax, byte [rbx + RQ_SQE + SQ_OP]
    cmp eax, RO_COUNT
    jae .now
    lea rcx, [ro_async]
    cmp byte [rcx + rax], 0
    je .now
    mov rdi, r12
    mov rsi, rbx
    call ring_arm
    cmp rax, E_ANY
    jb .out                             ; it waits, with the rest after it
    mov rdx, rax
    jmp .failed
.now:
    mov rdi, r12
    lea rsi, [rbx + RQ_SQE]
    call ring_exec                      ; RAX = result, RDX = value
    mov rcx, rdx
    mov rdx, rax
    cmp rax, E_ANY
    jb .post_value
.failed:
    mov r13d, 1
.post:
    xor ecx, ecx
.post_value:
    mov rdi, r12
    mov rsi, [rbx + RQ_SQE + SQ_DATA]
    movzx r8d, byte [rbx + RQ_SQE + SQ_OP]
    call ring_post
    mov rdi, rbx
    call rq_free
    mov rbx, r14
    jmp .next
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ring_exec(RDI = ring, RSI = an entry, one that does not wait) -> RAX =
; its result, RDX = its value (0). For the current task.
ring_exec:
    push rbx
    push r12
    mov r12, rdi
    mov rbx, rsi
    movzx eax, byte [rbx + SQ_OP]
    cmp eax, RO_COUNT
    jae .bad
    lea rcx, [ro_exec]
    jmp [rcx + rax * 8]
.nop:
    xor eax, eax
    jmp .out
.signal:
    mov edi, [rbx + SQ_HANDLE]
    call h_event_signal
    jmp .out
.reset:
    mov edi, [rbx + SQ_HANDLE]
    call h_event_reset
    jmp .out
.copy:
    mov edi, [rbx + SQ_HANDLE]
    mov rsi, [rbx + SQ_A0]
    mov edx, [rbx + SQ_HANDLE2]
    mov rcx, [rbx + SQ_A1]
    mov r8, [rbx + SQ_A2]
    call h_mem_copy
    jmp .out
.dup:
    mov edi, [rbx + SQ_HANDLE]
    mov esi, [rbx + SQ_A0]
    mov rdx, [rbx + SQ_A1]
    call handle_dup
    jmp .out
.close:
    mov edi, [rbx + SQ_HANDLE]
    call handle_close
    jmp .out
.give:
    mov edi, [rbx + SQ_HANDLE]
    mov esi, [rbx + SQ_HANDLE2]
    call handle_give
    jmp .out
.revoke:
    mov edi, [rbx + SQ_HANDLE]
    call handle_revoke
    jmp .out
.cancel:
    mov rdi, r12
    mov rsi, [rbx + SQ_A0]
    xor edx, edx
    call ring_cancel
    jmp .out
.write:
    mov edi, [rbx + SQ_HANDLE]
    mov esi, [rbx + SQ_HANDLE2]
    mov rdx, [rbx + SQ_A0]
    mov rcx, [rbx + SQ_A1]
    call h_con_write
    jmp .out
.send:
    mov edi, [rbx + SQ_HANDLE]
    mov esi, [rbx + SQ_HANDLE2]
    mov rdx, [rbx + SQ_A0]
    mov rcx, [rbx + SQ_A1]
    call h_ch_send
    jmp .out
.recv:
    mov edi, [rbx + SQ_HANDLE]
    mov esi, [rbx + SQ_HANDLE2]
    mov rdx, [rbx + SQ_A0]
    mov rcx, [rbx + SQ_A1]
    call h_ch_recv
    jmp .out
.kill:
    mov edi, [rbx + SQ_HANDLE]
    call h_task_kill
    jmp .out
.bad:
    mov rax, E_ARG                      ; one it does not know
.out:
    xor edx, edx
    pop r12
    pop rbx
    ret

; ring_cancel(RDI = ring, RSI = the data of those to cancel, EDX = 1 for all
; of them) -> RAX = how many requests waiting were canceled
ring_cancel:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14d, edx
    xor ebx, ebx                        ; those to complete, through RQ_DONE
    xor r9d, r9d                        ; how many
    pushfq
    cli
    lea rdi, [r12 + RG_LOCK]
    call spin_lock
    mov rdi, [r12 + RG_PENDING]
.find:
    test rdi, rdi
    jz .found
    test r14d, r14d
    jnz .match
    cmp [rdi + RQ_SQE + SQ_DATA], r13
    jne .next
.match:
    mov esi, HOW_CANCEL
    call rq_claim
    test eax, eax
    jz .next
    inc r9d
    cmp eax, 1
    jne .next                           ; its arming completes it
    mov [rdi + RQ_DONE], rbx
    mov rbx, rdi
.next:
    mov rdi, [rdi + RQ_PNEXT]
    jmp .find
.found:
    lea rdi, [r12 + RG_LOCK]
    call spin_unlock
    popfq
    lock add [r12 + RG_CANCELED], r9
.complete:
    test rbx, rbx
    jz .out
    mov rdi, rbx
    mov rbx, [rbx + RQ_DONE]
    call rq_complete
    jmp .complete
.out:
    mov eax, r9d
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Rings
; -----------------------------------------------------------------------------

; ring_post(RDI = ring, RSI = data, RDX = result, RCX = value, R8D = RO_*):
; a completion written, in the place promised it, and whoever waits for
; one woken. From anywhere. Preserves all.
ring_post:
    push rax
    push rbx
    push r9
    pushfq
    cli
    push rdi
    lea rdi, [rdi + RG_LOCK]
    call spin_lock
    pop rdi
    mov eax, [rdi + RG_CQ_TAIL]
    mov r9d, eax
    mov ebx, [rdi + RG_CQN]
    dec ebx
    and eax, ebx
    shl eax, 5                          ; CQ_SIZE
    mov rbx, [rdi + RG_CQ_BASE]
    add rbx, rax
    mov [rbx + CQ_DATA], rsi
    mov [rbx + CQ_RESULT], rdx
    mov [rbx + CQ_VALUE], rcx
    mov [rbx + CQ_OP], r8d
    inc r9d
    mov [rdi + RG_CQ_TAIL], r9d
    mov rbx, [rdi + RG_BASE]
    mov [rbx + RA_CQ_TAIL], r9d
    inc qword [rdi + RG_COMPLETED]
    push rdi
    lea rdi, [rdi + RG_LOCK]
    call spin_unlock
    pop rdi
    popfq
    push rdi
    lea rdi, [rdi + RG_WQ]
    call wq_wake
    pop rdi
    pop r9
    pop rbx
    pop rax
    ret

; ring_take(R12 = ring, RDI = 64 bytes): the next entry copied there, and
; taken; its completion promised. Preserves all.
ring_take:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, [r12 + RG_SQ_HEAD]
    mov ecx, [r12 + RG_SQN]
    dec ecx
    and ecx, eax
    shl ecx, 6                          ; SQ_SIZE
    mov rsi, [r12 + RG_SQ_BASE]
    add rsi, rcx
    mov ecx, SQ_SIZE / 8
    rep movsq
    inc eax
    mov [r12 + RG_SQ_HEAD], eax
    mov rsi, [r12 + RG_BASE]
    mov [rsi + RA_SQ_HEAD], eax
    inc dword [r12 + RG_PROMISED]
    inc qword [r12 + RG_SUBMITTED]
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; ring_chain(R12 = ring, ECX = how many entries this chain is, at most, a
; place for each one's completion promised) -> EAX = entries taken
ring_chain:
    push rbx
    push rbp
    push r13
    push r14
    push r15
    sub rsp, SQ_SIZE                    ; the entry, copied out of reach
    mov r13d, ecx
    xor ebp, ebp                        ; taken
    xor r14d, r14d                      ; 1 once one failed
.entry:
    cmp ebp, r13d
    jae .out
    mov rdi, rsp
    call ring_take
    inc ebp
    call .more                          ; R15D = whether another follows
    test r14d, r14d
    jnz .cancel
    movzx eax, byte [rsp + SQ_OP]
    cmp eax, RO_COUNT
    jae .now
    lea rcx, [ro_async]
    cmp byte [rcx + rax], 0
    jne .async
.now:
    mov rdi, r12
    mov rsi, rsp
    call ring_exec
    mov rcx, rdx
    mov rdx, rax
    cmp rax, E_ANY
    jb .post
    mov r14d, 1
    jmp .post
.cancel:
    mov rdx, E_CANCELED
    xor ecx, ecx
.post:
    mov rdi, r12
    mov rsi, [rsp + SQ_DATA]
    movzx r8d, byte [rsp + SQ_OP]
    call ring_post
    test r15d, r15d
    jnz .entry
    jmp .out
.nomem:
    mov r14d, 1
    mov rdx, E_NOMEM
    xor ecx, ecx
    jmp .post
.async:                                 ; a request, and those linked after it
    mov rdi, rsp
    call rq_new
    test rax, rax
    jz .nomem
    mov rbx, rax                        ; the first
    mov rdx, rax                        ; the last
.successor:
    test r15d, r15d
    jz .run
    mov rdi, rsp
    call ring_take
    inc ebp
    call .more
    mov rdi, rsp
    call rq_new
    test rax, rax
    jz .short
    mov [rdx + RQ_NEXT], rax
    mov rdx, rax
    jmp .successor
.run:
    mov rdi, r12
    mov rsi, rbx
    xor edx, edx
    call ring_run                       ; it waits, or is refused and the rest canceled
    jmp .out
.short:                                 ; out of memory: none of it runs
    mov rdi, r12
    mov rsi, rbx
    mov edx, 1
    call ring_run
    jmp .nomem
.more:                                  ; R15D = 1 if the entry links the next,
    movzx r15d, byte [rsp + 8 + SQ_FLAGS] ; and the chain is not at its end
    and r15d, SQF_LINK
    cmp ebp, r13d
    jb .linked
    xor r15d, r15d
.linked:
    ret
.out:
    mov eax, ebp
    add rsp, SQ_SIZE
    pop r15
    pop r14
    pop r13
    pop rbp
    pop rbx
    ret

; ring_ready(RDI = the ring, then how many completions) -> EAX = 1 once that
; many wait to be read (the test wq_wait_fn makes). Preserves others.
ring_ready:
    push rcx
    mov rcx, [rdi]
    mov eax, [rcx + RG_CQ_TAIL]
    mov rcx, [rcx + RG_BASE]
    sub eax, [rcx + RA_CQ_HEAD]
    cmp eax, [rdi + 8]
    setae al
    movzx eax, al
    pop rcx
    ret

; ring_orphan(RDI = ring): no handle to it is left (its TY_ORPHAN)
ring_orphan:
    lock bts dword [rdi + RG_FLAGS], RGF_ORPHAN
    xor esi, esi
    mov edx, 1
    jmp ring_cancel

; ring_destroy(RDI): its last reference went
ring_destroy:
    cmp dword [rdi + RG_LIVE], 0
    jne .waiting
    push rdi
    mov rdi, [rdi + RG_AREA]
    call obj_put
    pop rdi
    jmp obj_free
.waiting:
    xor edi, edi
    lea rsi, [str_ring_live]
    jmp panic

h_ring_new:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    mov rax, E_ARG                      ; a power of two, up to RING_MAX
    test r12d, r12d
    jz .out
    cmp r12d, RING_MAX
    ja .out
    lea ecx, [r12 - 1]
    test ecx, r12d
    jnz .out
    mov edi, r12d                       ; the header, the entries, the completions
    shl edi, 7                          ; SQ_SIZE + 2 * CQ_SIZE each
    add edi, RA_HDR
    mov rsi, r13
    call mem_new
    test rax, rax
    jz .nomem
    mov rbx, rax                        ; the memory
    mov edi, OT_RING
    mov esi, RG_SIZE
    mov rdx, r13
    call obj_new
    test rax, rax
    jz .nomem_ring
    mov [rax + RG_AREA], rbx
    mov rcx, [rbx + MO_BASE]
    mov [rax + RG_BASE], rcx
    lea rdx, [rcx + RA_HDR]
    mov [rax + RG_SQ_BASE], rdx
    mov edx, r12d
    shl edx, 6
    add edx, RA_HDR
    mov [rcx + RA_CQ_OFF], edx
    add rdx, rcx
    mov [rax + RG_CQ_BASE], rdx
    mov [rax + RG_SQN], r12d
    mov [rcx + RA_SQ_ENTRIES], r12d
    lea edx, [r12 * 2]
    mov [rax + RG_CQN], edx
    mov [rcx + RA_CQ_ENTRIES], edx
    mov dword [rcx + RA_SQ_OFF], RA_HDR
    mov rdx, [tsc_per_us]
    mov [rcx + RA_TSC_PER_US], rdx
    mov rdi, rax                        ; a handle to it: its reference goes in
    mov esi, RT_ALL
    call handle_new
    cmp rax, E_ANY
    jae .out                            ; dropped, its memory with it
    mov r12, rax
    mov rdi, rbx                        ; and one to its memory
    call obj_get
    mov esi, RT_ALL
    call handle_new
    cmp rax, E_ANY
    jae .no_area
    mov rdx, rax
    mov rax, r12
    jmp .out
.no_area:
    push rax
    mov edi, r12d
    call handle_close
    pop rax
    jmp .out
.nomem_ring:
    mov rdi, rbx
    call obj_put
.nomem:
    mov rax, E_NOMEM
.out:
    call op_done
    pop r13
    pop r12
    pop rbx
    ret

h_ring_enter:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24                         ; for ring_ready: the ring, how many
    mov r13d, esi
    mov r14d, edx
    mov r15, rcx
    mov esi, OT_RING
    mov edx, RT_RING_ENTER
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov r12, rax
    xor ebp, ebp                        ; entries taken
    test r13d, r13d
    jz .wait
    lock bts dword [r12 + RG_FLAGS], RGF_SUBMIT
    jc .wait                            ; another thread is taking them
.chain:
    cmp ebp, r13d
    jae .taken
    mov rbx, [r12 + RG_BASE]
    mov eax, [rbx + RA_SQ_TAIL]
    sub eax, [r12 + RG_SQ_HEAD]         ; written, not yet taken
    jz .taken
    cmp eax, [r12 + RG_SQN]
    ja .corrupt
    mov ecx, r13d
    sub ecx, ebp
    cmp eax, ecx
    jae .left
    mov ecx, eax                        ; ECX = what may be taken
.left:
    cmp ecx, RING_CHAIN
    jbe .scan
    mov ecx, RING_CHAIN
.scan:                                  ; EDX = the next chain's length
    mov eax, [r12 + RG_SQ_HEAD]
    mov edi, [r12 + RG_SQN]
    dec edi
    mov rsi, [r12 + RG_SQ_BASE]
    mov edx, 1
.link:
    cmp edx, ecx
    jae .scanned
    mov r8d, eax
    and r8d, edi
    shl r8d, 6
    test byte [rsi + r8 + SQ_FLAGS], SQF_LINK
    jz .scanned
    inc edx
    inc eax
    jmp .link
.scanned:
    mov eax, [r12 + RG_PROMISED]        ; a place for each of its completions
    sub eax, [rbx + RA_CQ_HEAD]
    cmp eax, [r12 + RG_CQN]
    ja .taken                           ; a head past the tail: no room
    mov ecx, [r12 + RG_CQN]
    sub ecx, eax
    cmp ecx, edx
    jb .taken
    mov ecx, edx
    call ring_chain
    add ebp, eax
    jmp .chain
.corrupt:
    test ebp, ebp
    jnz .taken
    lock btr dword [r12 + RG_FLAGS], RGF_SUBMIT
    mov rbx, E_ARG
    jmp .put
.taken:
    lock btr dword [r12 + RG_FLAGS], RGF_SUBMIT
.wait:
    mov ebx, ebp                        ; what it returns
    test r14d, r14d
    jz .put
    cmp r14d, [r12 + RG_CQN]
    jbe .want
    mov r14d, [r12 + RG_CQN]
.want:
    mov [rsp], r12
    mov [rsp + 8], r14
    lea rdi, [r12 + RG_WQ]
    lea rsi, [ring_ready]
    mov rdx, rsp
    mov rcx, r15
    call wq_wait_fn
.put:
    mov rdi, r12
    call obj_put
    mov rax, rbx
.out:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .rodata
str_async:      db 'async', 0
str_async_oom:  db 'Out of memory for the thread async', 0
str_ring_live:  db 'ring_destroy: requests still waiting on it', 0
align 8
ro_exec:        dq ring_exec.nop, ring_exec.signal, ring_exec.reset, ring_exec.bad
                dq ring_exec.bad, ring_exec.bad, ring_exec.copy, ring_exec.dup
                dq ring_exec.close, ring_exec.give, ring_exec.revoke, ring_exec.cancel
                dq ring_exec.write, ring_exec.send, ring_exec.recv, ring_exec.kill
ro_async:       db 0, 0, 0, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ; which wait: RO_WAIT, RO_JOIN, RO_TIMEOUT

section .bss
alignb 8
async_thread:   resq 1
as_list:        resq 1                  ; requests completed, to finish
as_finished:    resq 1
rq_live:        resq 1                  ; requests in being
tm_heap:        resq 1                  ; the timers queued, soonest first
tm_fired:       resq 1
tm_count:       resd 1
tm_cap:         resd 1
tm_lock:        resd 1
as_lock:        resd 1
