; =============================================================================
;  sched.asm - kernel threads and the scheduler
;
;  A thread is one vm mapping: its stack (32 KiB), with the thread itself
;  (its fields and an XSAVE area) on the page above, guarded on both sides.
;  Its context is the callee-saved registers on that stack and its SIMD
;  state; a switch is a call into sched_switch on one thread's stack and a
;  return from it on another's. Freed mappings are kept for the next thread,
;  up to 32, so starting one is cheap and ending one shoots down no TLBs.
;
;  Each CPU has a run queue ordered by how much CPU time each thread has had
;  (its virtual runtime), a sleep queue of threads parked until a time, and
;  an idle thread for when the run queue is empty. The least-run thread runs;
;  while others wait it gets a 4 ms slice, which the timer interrupt ends,
;  and the switch happens on the way out of that interrupt. A parked thread
;  keeps its place in time while the others run on, and comes back at most
;  half a slice ahead of the least-run thread there, so a thread that mostly
;  waits (the shell) preempts one that only computes, and answers at once
;  while every CPU is busy.
;
;  Where a thread runs: pinned to one CPU, or wherever costs least. The cost
;  counts the threads a CPU already has, whether it is the kind of core the
;  thread's class wants (perf: P-cores; eff: E-cores; any: P-cores a little
;  sooner), whether its SMT sibling is busy, and the BSP, which runs the
;  shell and takes the interrupts, a little last. A CPU about to idle steals
;  a waiting thread from the busiest queue; a CPU with two threads more than
;  another hands one over; a thread on the wrong kind of core moves when a
;  whole core of the right kind is idle, or swaps with a thread that is on
;  the wrong kind the other way.
;
;  Threads park and unpark: park sleeps until an unpark or a deadline, and an
;  unpark that comes first is kept, so the next park returns at once.
;  Sleeping, joining, the job workers and the main loop's wait are built on
;  that.
;
;  Locks: each CPU's queues have one lock, taken with interrupts off, never
;  two at once. A thread on its way to another CPU is on no queue for a
;  moment; the CPU that takes it waits until its old CPU is off its stack
;  (TH_ONCPU) before switching to it.
; =============================================================================

THREAD_STACK    equ 0x8000              ; 32 KiB
STACK_CACHE     equ 32                  ; freed thread mappings kept
SCHED_SLICE_US  equ 4000
SCHED_GRAN_US   equ 1000                ; how far behind a woken thread must be to preempt
SCHED_BAL_US    equ 10000               ; how often a thread on the wrong kind of core looks
SCHED_HOUSE_US  equ 50000               ; a busy CPU counts its time at least this often

LAPIC_TIMER_INIT equ 0x380
LAPIC_TIMER_CUR  equ 0x390
LAPIC_TIMER_DIV  equ 0x3E0

section .text

; -----------------------------------------------------------------------------
;  sched_init: on the BSP once its LAPIC is on, before the APs start. The code
;  running now becomes the thread "main", pinned to the BSP; the BSP gets an
;  idle thread of its own.
; -----------------------------------------------------------------------------
sched_init:
    push rbx
    mov rax, [tsc_per_us]
    imul rcx, rax, SCHED_SLICE_US
    mov [sched_slice], rcx
    shr rcx, 1
    mov [sched_credit], rcx
    imul rcx, rax, SCHED_GRAN_US
    mov [sched_gran], rcx
    imul rcx, rax, SCHED_BAL_US
    mov [sched_bal], rcx
    imul rcx, rax, SCHED_HOUSE_US
    mov [sched_house], rcx

    mov dword [sched_area], 512         ; FXSAVE's
    test dword [cpu_f1_ecx], 1 << 26    ; XSAVE: cpu_setup_local turned it on
    jz .timer
    mov byte [sched_xsave], 1
    mov eax, 0x0D                       ; for what XCR0 enables: leaf 0's EBX
    xor ecx, ecx                        ; says, but under some hypervisors it
    cpuid                               ; still counts x87 and SSE only, so
    mov r8d, ebx                        ; also the end of each component
    mov r9d, 2
.component:
    bt [cpu_xcr0], r9d
    jnc .component_next
    mov eax, 0x0D
    mov ecx, r9d
    cpuid
    add eax, ebx                        ; its offset plus its size
    cmp eax, r8d
    cmova r8d, eax
.component_next:
    inc r9d
    cmp r9d, 32
    jb .component
    mov [sched_area], r8d
.timer:
    mov eax, [sched_area]               ; a thread's fields and SIMD area, in pages
    add eax, TH_SIZE + 64 + 4095
    and eax, -4096
    mov [sched_tsize], rax
    test dword [cpu_f1_ecx], 1 << 24    ; TSC-deadline timer
    jz .lapic
    mov byte [sched_tsc_deadline], 1
    jmp .handlers
.lapic:
    call sched_calibrate
.handlers:
    mov edi, VEC_TIMER
    lea rsi, [sched_tick]
    call irq_register
    mov edi, VEC_WAKE
    lea rsi, [sched_wake_irq]
    call irq_register

    lea rbx, [percpu]
    call sched_local_init
    lea rdi, [str_th_main]
    mov esi, TF_MAIN
    call sched_adopt
    mov [main_thread], rax
    mov dword [rbx + PC_BUSY], 1
    lea rdi, [sched_idle_loop]          ; the BSP's idle thread
    xor esi, esi
    lea rdx, [str_th_idle0]
    call thread_new
    test rax, rax
    jz sched_oom
    or qword [rax + TH_FLAGS], TF_IDLE
    mov qword [rax + TH_PIN], 0
    mov dword [rax + TH_STATE], TS_READY
    mov [rbx + PC_IDLE_TH], rax
    mov byte [rbx + PC_SCHED_ON], 1
    mov byte [sched_ready], 1
    pop rbx
    ret

; sched_init_ap(RBX = per-CPU block): an AP at the end of its bring-up. The
; code running now becomes its idle thread; it gets a job worker.
sched_init_ap:
    push r12
    call sched_local_init
    xor edi, edi
    mov esi, TF_IDLE
    call sched_adopt
    mov [rbx + PC_IDLE_TH], rax
    lea rdi, [rax + TH_NAME]
    SPRINTF rdi, "idle/%u", qword [rbx + PC_INDEX]
    lea rdi, [job_thread]
    xor esi, esi
    xor edx, edx
    call thread_new
    test rax, rax
    jz sched_oom
    mov r12, rax
    lea rdi, [r12 + TH_NAME]
    SPRINTF rdi, "jobs/%u", qword [rbx + PC_INDEX]
    or qword [r12 + TH_FLAGS], TF_WORKER
    mov rax, [rbx + PC_INDEX]
    mov [r12 + TH_PIN], rax
    mov [rbx + PC_WORKER], r12
    mov byte [rbx + PC_SCHED_ON], 1
    mov rdi, r12
    call thread_start
    pop r12
    ret

sched_oom:
    xor edi, edi
    lea rsi, [str_sched_oom]
    jmp panic

; sched_local_init(RBX = per-CPU block): this CPU's scheduler fields and timer
sched_local_init:
    mov qword [rbx + PC_PUSH_TO], -1
    mov qword [rbx + PC_SIBLING], -1
    mov rax, [rbx + PC_KIND]
    mov [rbx + PC_SKIND], rax
    cmp byte [sched_tsc_deadline], 0
    je .lapic
    mov ecx, LAPIC_LVT_TIMER
    mov eax, VEC_TIMER | (2 << 17)      ; TSC-deadline mode
    jmp lapic_write
.lapic:
    mov ecx, LAPIC_TIMER_DIV
    mov eax, 0x0B                       ; divide by 1
    call lapic_write
    mov ecx, LAPIC_LVT_TIMER
    mov eax, VEC_TIMER                  ; one-shot
    jmp lapic_write

; sched_adopt(RBX = per-CPU block, RDI = name or 0, ESI = TF_*) -> RAX: the
; code running now becomes a thread, pinned here, on the CPU's own stack
sched_adopt:
    push r12
    push r13
    mov r13d, esi
    call thread_alloc
    test rax, rax
    jz sched_oom
    mov r12, rax
    mov [r12 + TH_FLAGS], r13
    mov rax, [rbx + PC_INDEX]
    mov [r12 + TH_CPU], rax
    mov [r12 + TH_PIN], rax
    mov [r12 + TH_LAST], rax
    mov rax, [rbx + PC_STACK_TOP]
    mov [r12 + TH_STACK_TOP], rax
    mov dword [r12 + TH_STATE], TS_RUNNING
    mov dword [r12 + TH_ONCPU], 1
    RDTSC64
    mov [r12 + TH_RUN_TSC], rax
    mov [rbx + PC_LAST_TSC], rax
    mov [rbx + PC_CURRENT], r12
    mov rax, r12
    pop r13
    pop r12
    ret

; sched_calibrate: no TSC-deadline timer, so time the LAPIC timer against the TSC
sched_calibrate:
    mov ecx, LAPIC_TIMER_DIV
    mov eax, 0x0B
    call lapic_write
    mov ecx, LAPIC_LVT_TIMER
    mov eax, 0x10000 | VEC_TIMER        ; masked while we count
    call lapic_write
    mov ecx, LAPIC_TIMER_INIT
    mov eax, 0xFFFFFFFF
    call lapic_write
    mov edi, 10000
    call delay_us
    mov ecx, LAPIC_TIMER_CUR
    call lapic_read
    mov ecx, eax
    mov eax, 0xFFFFFFFF
    sub eax, ecx
    xor edx, edx
    mov ecx, 10
    div ecx
    mov [lapic_per_ms], rax
    mov ecx, LAPIC_TIMER_INIT
    xor eax, eax
    jmp lapic_write

; -----------------------------------------------------------------------------
;  sched_topology: after every AP is up and numbered (smp_topology). Each
;  CPU's kind for scheduling, and its SMT sibling: the other thread of the
;  same core.
; -----------------------------------------------------------------------------
sched_topology:
    push rbx
    push r12
    push r13
    mov qword [sched_np], 0
    mov qword [sched_ne], 0
    xor r12d, r12d
.cpu:
    cmp r12d, [cpu_count]
    jae .done
    PERCPU rbx, r12
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    mov rax, [rbx + PC_KIND]
    mov [rbx + PC_SKIND], rax
    cmp rax, CPU_KIND_P
    jne .not_p
    inc qword [sched_np]
.not_p:
    cmp rax, CPU_KIND_E
    jne .not_e
    inc qword [sched_ne]
.not_e:
    mov qword [rbx + PC_SIBLING], -1
    xor r13d, r13d
.other:
    cmp r13d, [cpu_count]
    jae .next
    cmp r13d, r12d
    je .other_next
    PERCPU rcx, r13
    cmp byte [rcx + PC_SCHED_ON], 0
    je .other_next
    mov rax, [rcx + PC_KIND]
    cmp rax, [rbx + PC_KIND]
    jne .other_next
    mov rax, [rcx + PC_CORE]
    cmp rax, [rbx + PC_CORE]
    jne .other_next
    mov [rbx + PC_SIBLING], r13
    jmp .next
.other_next:
    inc r13d
    jmp .other
.next:
    inc r12d
    jmp .cpu
.done:
    pop r13
    pop r12
    pop rbx
    ret

; sched_pretend(EDI = 1): for a test on a machine with one kind of core, the
; scheduler takes the first half of the CPUs for P-cores and the rest for
; E-cores, with no SMT; EDI = 0 goes back to what they are.
sched_pretend:
    test edi, edi
    jz sched_topology
    push rbx
    mov eax, [cpus_online]
    shr eax, 1
    mov r8d, eax
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .done
    PERCPU rbx, rcx
    mov qword [rbx + PC_SIBLING], -1
    mov qword [rbx + PC_SKIND], CPU_KIND_P
    cmp ecx, r8d
    jb .next
    mov qword [rbx + PC_SKIND], CPU_KIND_E
.next:
    inc ecx
    jmp .cpu
.done:
    mov [sched_np], r8
    mov eax, [cpus_online]
    sub rax, r8
    mov [sched_ne], rax
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Threads
;    thread_new(RDI = entry, RSI = argument, RDX = name or 0) -> RAX = a
;      thread not yet started, with a handle for the caller to thread_join or
;      thread_detach; 0 if out of memory. entry(RDI = argument) runs with
;      interrupts on; returning from it is thread_exit(RAX).
;    thread_start(RDI): onto a run queue. Set TH_CLASS, TH_PIN or TH_HINT
;      before this.
;    thread_spawn(RDI = entry, RSI = argument, RDX = name, RCX = class) ->
;      RAX = a started thread's handle, or 0
;    thread_join(RDI) -> RAX = what it returned; gives the handle back
;    thread_put(RDI) = obj_put: a thread is an object (OT_THREAD), acting
;      for a task (TH_TASK), its creator's unless thread_set_task says
;    thread_detach(RDI): gives the handle back; it is freed when it ends
;    thread_exit(RDI = result): never returns
;    thread_yield: let the next thread run
;    thread_park -> RAX = 1: sleep until an unpark (one already sent counts)
;    thread_park_until(RDI = TSC deadline, 0 = none) -> RAX = 1 if unparked,
;      0 if the deadline passed
;    thread_unpark(RDI): wake it if parked, else its next park returns at once
;    thread_sleep_us(RDI = microseconds), thread_sleep_until(RDI = TSC)
;  All preserve RBX, RBP, R12-R15; thread_unpark preserves everything.
; -----------------------------------------------------------------------------

; thread_alloc(RDI = name or 0) -> RAX = a thread from the heap, for code
; that keeps the stack it runs on; 0 if out of memory
thread_alloc:
    push rdi
    mov edi, [sched_area]
    add edi, TH_SIZE + 64
    call kmalloc
    pop rsi
    test rax, rax
    jz .out
    mov rdi, rax
    jmp thread_init
.out:
    ret

; thread_init(RDI = zeroed memory for a thread, RSI = name or 0) -> RAX = it:
; an object with one reference and a SIMD area, acting for the current
; thread's task, not yet started
thread_init:
    push rbx
    mov rdx, rsi
    mov esi, OT_THREAD
    call obj_init
    mov rbx, rax
    lea rax, [rbx + TH_SIZE + 63]
    and rax, -64
    mov [rbx + TH_XSAVE], rax
    mov word [rax], 0x037F              ; x87 control word, for FXRSTOR
    mov dword [rax + 24], 0x1F80        ; MXCSR: every exception masked
    mov qword [rbx + TH_PIN], -1
    mov qword [rbx + TH_HINT], -1
    mov qword [rbx + TH_LAST], -1
    call cur_task
    test rax, rax
    jz .alone
    mov rdi, rax
    call task_hold
    mov [rbx + TH_TASK], rax
.alone:
    mov rax, rbx
    pop rbx
    ret

thread_new:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    call sched_reap                     ; what earlier threads left
    call thread_mapping
    test rax, rax
    jz .out
    lea rdi, [rax + THREAD_STACK]       ; the thread, above its stack
    mov rsi, r14
    mov r14, rax
    call thread_init
    mov rbx, rax
    mov [rbx + TH_STACK], r14
    mov [rbx + TH_STACK_TOP], rbx
    lea rdx, [rbx - 72]                 ; what sched_switch pops, then returns
    mov [rbx + TH_RSP], rdx             ; into thread_begin with RSP 16-aligned
    xor eax, eax
    mov [rdx], rax                      ; r15
    mov [rdx + 8], rax                  ; r14
    mov [rdx + 16], r13                 ; r13 = the argument
    mov [rdx + 24], r12                 ; r12 = the entry
    mov [rdx + 32], rbx                 ; rbx = the thread
    mov [rdx + 40], rax                 ; rbp
    lea rcx, [thread_begin]
    mov [rdx + 48], rcx
    mov [rdx + 56], rax
    mov [rdx + 64], rax
    mov dword [rbx + TH_REFS], 2        ; its own, and the caller's handle
    mov rax, rbx
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

thread_begin:                           ; a new thread's first instructions
    sti
    mov rdi, r13
    call r12
    mov rdi, rax
    jmp thread_exit

thread_spawn:
    push rbx
    push r12
    mov r12, rcx
    call thread_new
    test rax, rax
    jz .out
    mov rbx, rax
    mov [rbx + TH_CLASS], r12
    mov rdi, rbx
    call thread_start
    mov rax, rbx
.out:
    pop r12
    pop rbx
    ret

thread_start:
    push rbx
    push r12
    pushfq
    cli
    mov rbx, rdi
    call sched_pick_cpu
    PERCPU r12, rax
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rax, [r12 + PC_MIN_VR]
    mov [rbx + TH_VR], rax
    mov dword [rbx + TH_STATE], TS_READY
    mov rdi, rbx
    call rq_insert
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    mov rdi, r12
    mov rsi, rbx
    call sched_kick
    call sched_now_if_due
    popfq
    pop r12
    pop rbx
    ret

; sched_now_if_due: from a function that saved RFLAGS with pushfq just
; before calling here (so [rsp + 8]) and has interrupts off: if it was
; called with them on and this CPU should switch, switch now
sched_now_if_due:
    test qword [rsp + 8], 1 << 9
    jz .out
    cmp byte [gs:PC_RESCHED], 0
    je .out
    jmp sched_yield_off
.out:
    ret

thread_detach:
thread_put:                             ; drop a reference
    jmp obj_put

; thread_destroy(RDI): its last reference went (the destroy of OT_THREAD)
thread_destroy:
    push rdi
    mov rax, rdi
    xor edi, edi
    xchg rdi, [rax + TH_TASK]
    test rdi, rdi
    jz .no_task
    call task_release
.no_task:
    mov rdi, [rsp]
    cmp dword [rdi + TH_STATE], TS_NEW
    jne .unlinked                       ; one that ran is off the list once reaped
    call obj_unlink
.unlinked:
    mov rax, [rdi + TH_STACK]
    test rax, rax
    jnz .mapped
    pop rdi
    jmp kfree                           ; code that kept its stack: from the heap
.mapped:
    mov rdi, rax
    call thread_unmap
    pop rdi
    ret

; thread_mapping -> RAX = a thread's mapping: its stack, then sched_tsize
; zeroed bytes; one kept from an ended thread, or new. 0 if out of memory.
thread_mapping:
    push rcx
    push rdi
    pushfq
    cli
    lea rdi, [stack_lock]
    call spin_lock
    mov rax, [stack_cache]
    test rax, rax
    jz .taken
    mov rcx, [rax]
    mov [stack_cache], rcx
    dec qword [stack_cached]
.taken:
    lea rdi, [stack_lock]
    call spin_unlock
    popfq
    test rax, rax
    jz .new
    push rax
    lea rdi, [rax + THREAD_STACK]
    mov rcx, [sched_tsize]
    shr rcx, 3
    xor eax, eax
    rep stosq
    pop rax
    jmp .out
.new:
    mov rdi, [sched_tsize]
    add rdi, THREAD_STACK
    call vm_alloc
.out:
    pop rdi
    pop rcx
    ret

; thread_unmap(RDI = a thread's mapping, no longer used): kept for the next
; thread, or freed. Preserves all.
thread_unmap:
    push rax
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [stack_lock]
    call spin_lock
    pop rax
    cmp qword [stack_cached], STACK_CACHE
    jae .full
    mov rdi, [stack_cache]
    mov [rax], rdi
    mov [stack_cache], rax
    inc qword [stack_cached]
    lea rdi, [stack_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rax
    ret
.full:
    lea rdi, [stack_lock]
    call spin_unlock
    popfq
    pop rdi
    call vm_free
    pop rax
    ret

thread_join:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + TH_WQ]
    lea rsi, [rbx + TH_ENDED]
    xor edx, edx
    call wq_wait
    mov rax, [rbx + TH_EXIT]
    mov rdi, rbx
    call thread_put
    pop rbx
    ret

thread_exit:
    cli
    mov rbx, [gs:PC_CURRENT]
    mov [rbx + TH_EXIT], rdi
    mov dword [rbx + TH_STATE], TS_DEAD
    mov dword [rbx + TH_ENDED], 1
    lea rdi, [rbx + TH_WQ]              ; whoever waits for it
    call wq_wake
    lea rdi, [zombie_lock]
    call spin_lock
    mov rax, [zombies]
    mov [rbx + TH_NEXT], rax
    mov [zombies], rbx
    lea rdi, [zombie_lock]
    call spin_unlock
    mov rax, [gs:PC_SELF]
    lea rdi, [rax + PC_RQ_LOCK]
    call spin_lock
    call schedule_locked                ; and never back
    ud2

thread_yield:
    pushfq
    cli
    call sched_yield_off
    popfq
    ret

; sched_yield_off: thread_yield with interrupts already off
sched_yield_off:
    mov rax, [gs:PC_SELF]
    lea rdi, [rax + PC_RQ_LOCK]
    call spin_lock
    jmp schedule_locked

thread_park:
    xor edi, edi
thread_park_until:
    push rbx
    push r12
    pushfq
    cli
    mov r12, [gs:PC_SELF]
    mov rbx, [r12 + PC_CURRENT]
    push rdi
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    pop rdi
    xor eax, eax
    xchg eax, [rbx + TH_TOKEN]
    test eax, eax
    jnz .unlock                         ; an unpark came first: RAX = 1
    test rdi, rdi
    jz .park
    RDTSC64
    cmp rax, rdi
    mov eax, 0
    jae .unlock                         ; the deadline has passed
.park:
    mov dword [rbx + TH_WOKEN], 0
    mov dword [rbx + TH_STATE], TS_PARKED
    mov [rbx + TH_WAKE_AT], rdi
    test rdi, rdi
    jz .sleep
    mov rdi, rbx
    call sq_insert
.sleep:
    call schedule_locked
    mov eax, [rbx + TH_WOKEN]
    jmp .out
.unlock:
    push rax
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    pop rax
.out:
    popfq
    pop r12
    pop rbx
    ret

thread_unpark:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    pushfq
    cli
    mov rbx, rdi
.again:
    mov rax, [rbx + TH_CPU]
    PERCPU r12, rax
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rax, [r12 + PC_INDEX]
    cmp rax, [rbx + TH_CPU]
    je .locked
    lea rdi, [r12 + PC_RQ_LOCK]         ; it moved meanwhile
    call spin_unlock
    pause
    jmp .again
.locked:
    cmp dword [rbx + TH_STATE], TS_PARKED
    je .wake
    mov dword [rbx + TH_TOKEN], 1
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    jmp .done
.wake:
    cmp qword [rbx + TH_WAKE_AT], 0
    je .unslept
    mov rdi, rbx
    call sq_remove
    mov qword [rbx + TH_WAKE_AT], 0
.unslept:
    mov dword [rbx + TH_WOKEN], 1
    mov dword [rbx + TH_STATE], TS_READY
    mov rax, [r12 + PC_MIN_VR]          ; how far ahead of the least-run here now
    sub [rbx + TH_VR], rax
    call sched_credit_vr
    mov rdi, rbx
    call sched_pick_cpu
    cmp rax, [r12 + PC_INDEX]
    jne .elsewhere
    mov rax, [r12 + PC_MIN_VR]
    add [rbx + TH_VR], rax
    mov rdi, rbx
    call rq_insert
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    mov rdi, r12
    mov rsi, rbx
    call sched_kick
    jmp .done
.elsewhere:
    mov [rbx + TH_CPU], rax             ; later unparks go there
    mov r13, rax
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    mov rdi, r13
    mov rsi, rbx
    call sched_enqueue_on
.done:
    call sched_now_if_due
    popfq
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; sched_credit_vr(RBX = a waking thread, its TH_VR made relative to the
; least-run thread where it slept): it comes back at most half a slice ahead
; of that thread, however long it slept
sched_credit_vr:
    mov rax, [sched_credit]
    neg rax
    cmp [rbx + TH_VR], rax
    jge .out
    mov [rbx + TH_VR], rax
.out:
    ret

; thread_account: the running thread's time, counted up to now
thread_account:
    push rbx
    push r12
    push r13
    pushfq
    cli
    mov r12, [gs:PC_SELF]
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rbx, [r12 + PC_CURRENT]
    RDTSC64
    mov r13, rax
    call sched_account
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    popfq
    pop r13
    pop r12
    pop rbx
    ret

thread_sleep_us:
    imul rdi, [tsc_per_us]
    RDTSC64
    add rdi, rax
thread_sleep_until:
    push rbx
    mov rbx, rdi
.again:
    RDTSC64
    cmp rax, rbx
    jae .out
    mov rdi, rbx
    call thread_park_until
    jmp .again
.out:
    pop rbx
    ret

; sched_reap: free what dead threads left, once no CPU is on their stacks.
; Not from interrupt handlers, nor with a spinlock held.
sched_reap:
    push rbx
.next:
    cmp qword [zombies], 0
    je .out
    pushfq
    cli
    lea rdi, [zombie_lock]
    call spin_lock
    lea rcx, [zombies]
.find:
    mov rbx, [rcx]
    test rbx, rbx
    jz .found
    cmp dword [rbx + TH_ONCPU], 0
    je .take
    lea rcx, [rbx + TH_NEXT]
    jmp .find
.take:
    mov rax, [rbx + TH_NEXT]
    mov [rcx], rax
.found:
    lea rdi, [zombie_lock]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .out                             ; only ones still being left
    mov rdi, rbx
    call obj_unlink
    inc qword [threads_ended]
    xor edi, edi                        ; it acts for its task no more
    xchg rdi, [rbx + TH_TASK]
    test rdi, rdi
    jz .no_task
    call task_release
.no_task:
    mov rdi, rbx
    call thread_put
    jmp .next
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The run queue and the sleep queue, with R12 = the per-CPU block and its
;  lock held. Preserve all but RAX, RCX, RDX.
; -----------------------------------------------------------------------------

; rq_insert(RDI): after every thread that has had as much time or less
rq_insert:
    mov rax, [r12 + PC_INDEX]
    mov [rdi + TH_CPU], rax
    lea rcx, [r12 + PC_RQ]
.walk:
    mov rdx, [rcx]
    test rdx, rdx
    jz .here
    mov rax, [rdx + TH_VR]
    sub rax, [rdi + TH_VR]
    jg .here
    lea rcx, [rdx + TH_NEXT]
    jmp .walk
.here:
    mov [rdi + TH_NEXT], rdx
    mov [rcx], rdi
    inc dword [r12 + PC_RQ_LEN]
    ret

; rq_pop -> RAX = the least-run thread, taken off, or 0
rq_pop:
    mov rax, [r12 + PC_RQ]
    test rax, rax
    jz .out
    mov rcx, [rax + TH_NEXT]
    mov [r12 + PC_RQ], rcx
    mov qword [rax + TH_NEXT], 0
    dec dword [r12 + PC_RQ_LEN]
.out:
    ret

; rq_remove(RDI): take it off
rq_remove:
    lea rcx, [r12 + PC_RQ]
.walk:
    mov rax, [rcx]
    test rax, rax
    jz .out
    cmp rax, rdi
    je .found
    lea rcx, [rax + TH_NEXT]
    jmp .walk
.found:
    mov rax, [rdi + TH_NEXT]
    mov [rcx], rax
    mov qword [rdi + TH_NEXT], 0
    dec dword [r12 + PC_RQ_LEN]
.out:
    ret

; sq_insert(RDI): by TH_WAKE_AT, soonest first
sq_insert:
    lea rcx, [r12 + PC_SLEEPQ]
    mov rax, [rdi + TH_WAKE_AT]
.walk:
    mov rdx, [rcx]
    test rdx, rdx
    jz .here
    cmp [rdx + TH_WAKE_AT], rax
    ja .here
    lea rcx, [rdx + TH_NEXT]
    jmp .walk
.here:
    mov [rdi + TH_NEXT], rdx
    mov [rcx], rdi
    ret

; sq_remove(RDI)
sq_remove:
    lea rcx, [r12 + PC_SLEEPQ]
.walk:
    mov rax, [rcx]
    test rax, rax
    jz .out
    cmp rax, rdi
    je .found
    lea rcx, [rax + TH_NEXT]
    jmp .walk
.found:
    mov rax, [rdi + TH_NEXT]
    mov [rcx], rax
    mov qword [rdi + TH_NEXT], 0
.out:
    ret

; sched_wake_here(RDI = a parked thread off the sleep queue): ready, here
sched_wake_here:
    push rbx
    mov rbx, rdi
    mov dword [rbx + TH_STATE], TS_READY
    mov rax, [r12 + PC_MIN_VR]
    sub [rbx + TH_VR], rax
    call sched_credit_vr
    mov rax, [r12 + PC_MIN_VR]
    add [rbx + TH_VR], rax
    mov rdi, rbx
    call rq_insert
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  schedule_locked: interrupts off, this CPU's queues locked (unlocked here).
;  The current thread has said what it is: still runnable (back on a queue,
;  here or where PC_PUSH_TO says), parked or dead (on none). The least-run
;  thread runs next, or the idle thread. Returns when the current thread
;  runs again, maybe on another CPU. Preserves RBX, RBP, R12-R15.
; -----------------------------------------------------------------------------
schedule_locked:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, [gs:PC_SELF]
    mov rbx, [r12 + PC_CURRENT]
    mov byte [r12 + PC_RESCHED], 0
    RDTSC64
    mov r13, rax                        ; now
    call sched_account
    mov r14, -1                         ; a CPU to hand the current thread to
    mov eax, [rbx + TH_STATE]
    cmp eax, TS_RUNNING
    jne .pick                           ; parked or dead: on no queue
.runnable:
    mov dword [rbx + TH_STATE], TS_READY
    test qword [rbx + TH_FLAGS], TF_IDLE
    jnz .pick                           ; on no queue, but there when none wait
    mov rax, [r12 + PC_PUSH_TO]
    cmp rax, -1
    je .requeue
    mov qword [r12 + PC_PUSH_TO], -1
    cmp rbx, [r12 + PC_PUSH_WHO]        ; asked for this thread, not one since
    jne .requeue
    cmp qword [rbx + TH_PIN], -1
    jne .requeue
    mov r14, rax
    mov rax, [r12 + PC_MIN_VR]
    sub [rbx + TH_VR], rax
    mov [rbx + TH_CPU], r14             ; unparks go there from now
    jmp .pick
.requeue:
    mov rdi, rbx
    call rq_insert
.pick:
    call rq_pop
    test rax, rax
    jnz .next
    mov rax, [r12 + PC_IDLE_TH]
.next:
    mov rbp, rax
    mov dword [rbp + TH_STATE], TS_RUNNING
    xor eax, eax
    test qword [rbp + TH_FLAGS], TF_IDLE
    setz al
    mov [r12 + PC_BUSY], eax
    mov rax, r13
    add rax, [sched_slice]
    mov [r12 + PC_SLICE_END], rax
    mov rax, [rbp + TH_VR]
    mov [r12 + PC_CUR_VR], rax
    mov qword [r12 + PC_WANTS], 0
    mov rdi, rbp
    call sched_misfit
    jnc .fits
    mov [r12 + PC_WANTS], rax
    cmp qword [r12 + PC_BALANCE_AT], 0
    jne .fits                           ; a look already due
    mov rax, r13
    add rax, [sched_bal]
    mov [r12 + PC_BALANCE_AT], rax
.fits:
    mov rdi, rbp
    call sched_min_vr
    call sched_arm
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    cmp r14, -1
    je .switch
    mov rdi, r14
    mov rsi, rbx
    call sched_enqueue_on
    inc qword [r12 + PC_PUSHES]
.switch:
    cmp rbp, rbx
    je .out
    inc qword [r12 + PC_SWITCHES]
    inc qword [rbp + TH_SWITCHES]
    mov [rbp + TH_RUN_TSC], r13
    mov rax, [r12 + PC_INDEX]
    mov [rbp + TH_CPU], rax
    cmp rax, [rbp + TH_LAST]
    je .same_cpu
    cmp qword [rbp + TH_LAST], -1
    je .first
    inc qword [rbp + TH_MIGRATIONS]
.first:
    mov [rbp + TH_LAST], rax
.same_cpu:
    mov rdi, rbx
    mov rsi, rbp
    call sched_switch
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sched_switch(RDI = this thread, RSI = the next): interrupts off. Returns
; when this thread is switched to again.
sched_switch:
    push rbp
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov [rdi + TH_RSP], rsp
    mov r8, [rdi + TH_XSAVE]
    cmp byte [sched_xsave], 0
    je .fxsave
    mov eax, [cpu_xcr0]
    xor edx, edx
    xsave64 [r8]
    jmp .saved
.fxsave:
    fxsave64 [r8]
.saved:
    mov rax, [rsi + TH_CR3]             ; the next one's tables, before this one
    test rax, rax                       ; lets go of its own (they may go then)
    jnz .tables
    mov rax, [vmm_cr3]
.tables:
    cmp rax, [gs:PC_CR3]
    je .same_tables
    mov cr3, rax
    mov [gs:PC_CR3], rax
.same_tables:
    mfence                              ; all of it seen before another CPU takes it
    mov dword [rdi + TH_ONCPU], 0       ; from here on, hands off this stack
.wait:
    cmp dword [rsi + TH_ONCPU], 0       ; is its old CPU still leaving it?
    je .take
    pause
    jmp .wait
.take:
    mov dword [rsi + TH_ONCPU], 1
    mov [gs:PC_CURRENT], rsi
    mov rax, [rsi + TH_FSBASE]          ; ring 3's FS and GS bases, its own
    cmp rax, [gs:PC_FSBASE]
    je .fs_same
    mov [gs:PC_FSBASE], rax
    mov rdx, rax
    shr rdx, 32
    mov ecx, MSR_FS_BASE
    wrmsr
.fs_same:
    mov rax, [rsi + TH_GSBASE]
    cmp rax, [gs:PC_UGSBASE]
    je .gs_same
    mov [gs:PC_UGSBASE], rax
    mov rdx, rax
    shr rdx, 32
    mov ecx, MSR_KGS_BASE               ; (swapgs makes it GS in ring 3)
    wrmsr
.gs_same:
    mov rax, [rsi + TH_STACK_TOP]       ; where ring 3 comes back in
    mov [gs:PC_KSTACK], rax
    mov [gs:PC_TSS + TSS_RSP0], rax
    mov r8, [rsi + TH_XSAVE]
    cmp byte [sched_xsave], 0
    je .fxrstor
    mov eax, [cpu_xcr0]
    xor edx, edx
    xrstor64 [r8]
    jmp .loaded
.fxrstor:
    fxrstor64 [r8]
.loaded:
    mov rsp, [rsi + TH_RSP]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    pop rbp
    ret

; sched_account(R12 = per-CPU block, RBX = its current thread, R13 = now):
; the time since the last count goes to the thread. Clobbers RAX, RCX.
sched_account:
    mov rax, r13
    sub rax, [r12 + PC_LAST_TSC]
    mov [r12 + PC_LAST_TSC], r13
    test qword [rbx + TH_FLAGS], TF_IDLE
    jnz .idle
    add [r12 + PC_BUSY_CYC], rax
    add [rbx + TH_VR], rax
    mov rcx, [rbx + TH_VR]
    mov [r12 + PC_CUR_VR], rcx
    mov rcx, [r12 + PC_SKIND]
    cmp rcx, CPU_KIND_P
    je .p
    cmp rcx, CPU_KIND_E
    je .e
    add [rbx + TH_CYC_O], rax
    ret
.p:
    add [rbx + TH_CYC_P], rax
    ret
.e:
    add [rbx + TH_CYC_E], rax
    ret
.idle:
    add [r12 + PC_IDLE_CYC], rax
    ret

; sched_min_vr(R12, RDI = the current thread): PC_MIN_VR moves up to the
; least of it and the run queue's first. Clobbers RAX, RCX, RDX.
sched_min_vr:
    mov rcx, [r12 + PC_RQ]
    test qword [rdi + TH_FLAGS], TF_IDLE
    jnz .queue_only
    mov rax, [rdi + TH_VR]
    test rcx, rcx
    jz .have
    mov rdx, [rcx + TH_VR]
    cmp rdx, rax
    jge .have
    mov rax, rdx
    jmp .have
.queue_only:
    test rcx, rcx
    jz .out
    mov rax, [rcx + TH_VR]
.have:
    cmp rax, [r12 + PC_MIN_VR]
    jle .out
    mov [r12 + PC_MIN_VR], rax
.out:
    ret

; sched_misfit(R12, RDI = a thread) -> CF = 1 if it runs on the wrong kind
; of core here and could move, with RAX = the kind it wants. Clobbers RAX, RCX.
sched_misfit:
    cmp qword [rdi + TH_PIN], -1
    jne .fits
    test qword [rdi + TH_FLAGS], TF_IDLE
    jnz .fits
    mov rcx, [r12 + PC_SKIND]
    cmp rcx, CPU_KIND_UNKNOWN
    je .fits
    mov eax, CPU_KIND_P                 ; perf and any want P-cores
    cmp qword [rdi + TH_CLASS], THC_EFF
    jne .want
    mov eax, CPU_KIND_E
.want:
    cmp rcx, rax
    je .fits
    stc
    ret
.fits:
    clc
    ret

; sched_arm(R12, R13 = now): the timer, for the slice's end if others wait,
; the first sleeper, and the next look for a better core
sched_arm:
    xor eax, eax
    cmp dword [r12 + PC_RQ_LEN], 0
    je .sleepers
    cmp dword [r12 + PC_BUSY], 0
    je .sleepers
    mov rax, [r12 + PC_SLICE_END]
.sleepers:
    mov rcx, [r12 + PC_SLEEPQ]
    test rcx, rcx
    jz .balance
    mov rcx, [rcx + TH_WAKE_AT]
    call .min
.balance:
    mov rcx, [r12 + PC_BALANCE_AT]
    test rcx, rcx
    jz .house
    call .min
.house:
    cmp dword [r12 + PC_BUSY], 0        ; a busy CPU counts its time now and then
    je sched_timer_set
    mov rcx, r13
    add rcx, [sched_house]
    call .min
    jmp sched_timer_set
.min:                                   ; RAX = the sooner of RAX (0 = none) and RCX
    test rax, rax
    jz .take
    cmp rcx, rax
    jae .keep
.take:
    mov rax, rcx
.keep:
    ret

; sched_timer_set(R12, RAX = TSC deadline or 0, R13 = now): this CPU's timer
sched_timer_set:
    cmp rax, [r12 + PC_TIMER_AT]
    je .out
    mov [r12 + PC_TIMER_AT], rax
    push rcx
    push rdx
    cmp byte [sched_tsc_deadline], 0
    je .lapic
    mov rdx, rax
    shr rdx, 32
    mov ecx, MSR_TSC_DEADLINE
    wrmsr
    jmp .done
.lapic:
    test rax, rax
    jz .write
    sub rax, r13
    jbe .soon
    mov rcx, 1 << 40                    ; far enough: it is set again when it fires
    cmp rax, rcx
    cmova rax, rcx
    mul qword [lapic_per_ms]
    div qword [tsc_per_ms]
    mov ecx, 0xFFFFFFFF
    cmp rax, rcx
    cmova rax, rcx
    test eax, eax
    jnz .write
.soon:
    mov eax, 1
.write:
    mov ecx, LAPIC_TIMER_INIT
    call lapic_write
.done:
    pop rdx
    pop rcx
.out:
    ret

; -----------------------------------------------------------------------------
;  sched_tick: the timer interrupt. Wakes sleepers whose time has come, ends
;  a slice when others wait, moves a thread off the wrong kind of core, and
;  hands a waiting thread to a CPU that idles.
; -----------------------------------------------------------------------------
sched_tick:
    push rbx
    push r12
    push r13
    push r14
    cmp byte [harness_on], 0            ; a test run: the watchdog reloaded
    je .no_run
    call harness_tick
.no_run:
    mov r12, [gs:PC_SELF]
    cmp byte [r12 + PC_SCHED_ON], 0
    je .out
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov qword [r12 + PC_TIMER_AT], 0
    RDTSC64
    mov r13, rax
    mov rbx, [r12 + PC_CURRENT]
    call sched_account
.wake:
    mov rdi, [r12 + PC_SLEEPQ]
    test rdi, rdi
    jz .woken
    cmp [rdi + TH_WAKE_AT], r13
    ja .woken
    mov rax, [rdi + TH_NEXT]
    mov [r12 + PC_SLEEPQ], rax
    mov qword [rdi + TH_WAKE_AT], 0
    mov dword [rdi + TH_WOKEN], 0
    call sched_wake_here
    jmp .wake
.woken:
    cmp dword [r12 + PC_RQ_LEN], 0
    je .balance
    cmp dword [r12 + PC_BUSY], 0
    je .resched
    cmp r13, [r12 + PC_SLICE_END]
    jae .resched
    mov rax, [r12 + PC_RQ]              ; a woken thread well behind this one?
    mov rax, [rax + TH_VR]
    add rax, [sched_gran]
    sub rax, [rbx + TH_VR]
    jl .resched
    jmp .balance
.resched:
    mov byte [r12 + PC_RESCHED], 1
.balance:
    mov r14, -1
    mov rax, [r12 + PC_BALANCE_AT]
    test rax, rax
    jz .spread
    cmp r13, rax
    jb .spread
    mov qword [r12 + PC_BALANCE_AT], 0
    mov rdi, rbx
    call sched_misfit
    jc .misfit
    cmp dword [r12 + PC_RQ_LEN], 0
    jne .later                          ; one waiting here may not fit: later
    jmp .spread
.misfit:
    call sched_better_cpu
    cmp rax, -1
    jne .move
    call sched_swap_cpu                 ; or one there that wants it here
    cmp rax, -1
    je .later
.move:
    mov [r12 + PC_PUSH_WHO], rbx
    mov [r12 + PC_PUSH_TO], rax
    mov byte [r12 + PC_RESCHED], 1
    jmp .spread
.later:
    mov rax, r13
    add rax, [sched_bal]
    mov [r12 + PC_BALANCE_AT], rax
.spread:
    cmp dword [r12 + PC_RQ_LEN], 0
    je .arm
    call sched_spread
    test rax, rax
    jz .arm
    mov r14, rdx                        ; RAX = the thread, RDX = its new CPU
    push rax
.arm:
    mov rdi, rbx
    call sched_min_vr
    call sched_arm
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    cmp r14, -1
    je .out
    pop rsi
    mov rdi, r14
    call sched_enqueue_on
    inc qword [r12 + PC_PUSHES]
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; sched_spread(R12, queues locked) -> RAX = a waiting thread taken off this
; queue for a CPU with at least two threads fewer, RDX = that CPU; RAX = 0
; if none
sched_spread:
    push rbx
    mov rbx, [r12 + PC_RQ]
.find:
    test rbx, rbx
    jz .none
    cmp qword [rbx + TH_PIN], -1
    je .found
    mov rbx, [rbx + TH_NEXT]
    jmp .find
.found:
    mov rdi, rbx
    call sched_pick_cpu
    cmp rax, [r12 + PC_INDEX]
    je .none
    PERCPU rcx, rax
    mov edx, [rcx + PC_RQ_LEN]
    add edx, [rcx + PC_BUSY]
    add edx, 2
    mov ecx, [r12 + PC_RQ_LEN]
    add ecx, [r12 + PC_BUSY]
    cmp edx, ecx
    ja .none
    push rax
    mov rdi, rbx
    call rq_remove
    mov rax, [r12 + PC_MIN_VR]
    sub [rbx + TH_VR], rax
    pop rdx
    mov [rbx + TH_CPU], rdx
    mov rax, rbx
    pop rbx
    ret
.none:
    xor eax, eax
    pop rbx
    ret

; sched_better_cpu(R12, RDI = a thread on the wrong kind of core) -> RAX = a
; CPU of the right kind whose whole core is idle (the BSP last), or -1
sched_better_cpu:
    push rbx
    push rdx
    push rsi
    call sched_misfit
    jnc .none
    mov edx, CPU_KIND_P
    cmp qword [rdi + TH_CLASS], THC_EFF
    jne .search
    mov edx, CPU_KIND_E
.search:
    xor esi, esi                        ; tried so far; CPU (esi + 1) mod count
.cpu:
    cmp esi, [cpu_count]
    jae .none
    lea ecx, [rsi + 1]
    cmp ecx, [cpu_count]
    jb .index
    xor ecx, ecx
.index:
    PERCPU rbx, rcx
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    cmp [rbx + PC_SKIND], rdx
    jne .next
    cmp dword [rbx + PC_BUSY], 0
    jne .next
    cmp dword [rbx + PC_RQ_LEN], 0
    jne .next
    mov rax, [rbx + PC_SIBLING]
    cmp rax, -1
    je .found
    PERCPU rax, rax
    cmp dword [rax + PC_BUSY], 0
    jne .next
    cmp dword [rax + PC_RQ_LEN], 0
    jne .next
.found:
    mov eax, ecx
    jmp .out
.next:
    inc esi
    jmp .cpu
.none:
    mov rax, -1
.out:
    pop rsi
    pop rdx
    pop rbx
    ret

; sched_swap_cpu(R12, RDI = a thread on the wrong kind of core here) -> RAX =
; a CPU of the kind it wants that runs, with none waiting, a thread wanting
; this CPU's kind; that CPU is asked to send it here. -1 if none. Reads only
; the other CPUs' blocks. Clobbers RCX, RDX.
sched_swap_cpu:
    push rbx
    push rsi
    push rdi
    call sched_misfit
    jnc .none
    mov rdx, rax                        ; the kind it wants
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .none
    PERCPU rbx, rcx
    cmp rbx, r12
    je .next
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    cmp [rbx + PC_SKIND], rdx
    jne .next
    cmp dword [rbx + PC_RQ_LEN], 0
    jne .next
    mov rax, [r12 + PC_SKIND]
    cmp [rbx + PC_WANTS], rax           ; its thread would rather be here
    jne .next
    mov rax, [rbx + PC_CURRENT]         ; compared there, never followed here
    mov [rbx + PC_PUSH_WHO], rax
    mov rax, [r12 + PC_INDEX]
    mov [rbx + PC_PUSH_TO], rax
    mov byte [rbx + PC_RESCHED], 1
    mov edi, [rbx + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_RESCHED
    call lapic_send_ipi
    mov eax, ecx
    jmp .out
.next:
    inc ecx
    jmp .cpu
.none:
    mov rax, -1
.out:
    pop rdi
    pop rsi
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Where a thread goes
; -----------------------------------------------------------------------------

; sched_pick_cpu(RDI = thread) -> RAX = the CPU index for it. Preserves others.
sched_pick_cpu:
    mov rax, [rdi + TH_PIN]
    cmp rax, -1
    jne .out
    mov rax, [rdi + TH_HINT]
    cmp rax, -1
    je .score
    mov qword [rdi + TH_HINT], -1
.out:
    ret
.score:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    xor r8d, r8d                        ; best CPU
    mov r9d, 0x7FFFFFFF                 ; its cost
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .done
    PERCPU rbx, rcx
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    mov eax, [rbx + PC_RQ_LEN]
    add eax, [rbx + PC_BUSY]
    shl eax, 6                          ; 64 a thread
    add eax, 16
    mov rdx, [rbx + PC_SKIND]
    mov rsi, [rdi + TH_CLASS]
    cmp rsi, THC_PERF
    jne .not_perf
    cmp rdx, CPU_KIND_E
    jne .kind_done
    add eax, 24
    jmp .kind_done
.not_perf:
    cmp rsi, THC_EFF
    jne .any
    cmp rdx, CPU_KIND_P
    jne .kind_done
    add eax, 24
    jmp .kind_done
.any:
    cmp rdx, CPU_KIND_E
    jne .kind_done
    add eax, 4
.kind_done:
    mov rsi, [rbx + PC_SIBLING]
    cmp rsi, -1
    je .sibling_done
    PERCPU r10, rsi
    mov esi, [r10 + PC_RQ_LEN]
    or esi, [r10 + PC_BUSY]
    jz .sibling_done
    add eax, 16                         ; it would share a core
.sibling_done:
    test ecx, ecx
    jnz .not_bsp
    add eax, 8
.not_bsp:
    cmp rcx, [rdi + TH_LAST]
    jne .compare
    sub eax, 2                          ; its cache is warm there
.compare:
    cmp eax, r9d
    jge .next
    mov r9d, eax
    mov r8d, ecx
.next:
    inc ecx
    jmp .cpu
.done:
    mov rax, r8
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sched_enqueue_on(RDI = CPU index, RSI = a ready thread on no queue, its
; TH_VR relative): onto that CPU's run queue, waking it if it should switch.
; Interrupts off, no queue locked.
sched_enqueue_on:
    push rbx
    push r12
    mov rbx, rsi
    PERCPU r12, rdi
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rax, [r12 + PC_MIN_VR]
    add [rbx + TH_VR], rax
    mov rdi, rbx
    call rq_insert
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    mov rdi, r12
    mov rsi, rbx
    call sched_kick
    pop r12
    pop rbx
    ret

; sched_kick(RDI = per-CPU block, RSI = a thread just queued there): if it
; should run now (the CPU idles, or it is well behind the running thread),
; ask for a switch, with an IPI if that CPU is another; if it has to wait,
; wake a CPU that idles, to steal it. Preserves all.
sched_kick:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    cmp dword [rdi + PC_BUSY], 0
    je .resched
    mov rcx, [rdi + PC_CUR_VR]          ; its running thread's
    RDTSC64
    sub rax, [rdi + PC_LAST_TSC]        ; and its time since that was counted
    add rcx, rax
    mov rax, [rsi + TH_VR]
    add rax, [sched_gran]
    sub rax, rcx
    jge .wait_here
.resched:
    mov al, 1
    xchg al, [rdi + PC_RESCHED]
    test al, al
    jnz .out                            ; already asked
    cmp rdi, [gs:PC_SELF]
    je .out                             ; ours: the interrupt's end, or the caller
    mov edi, [rdi + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_RESCHED
    call lapic_send_ipi
    jmp .out
.wait_here:                             ; it waits: a CPU that idles can take it
    cmp qword [rsi + TH_PIN], -1
    jne .out
    xor ecx, ecx
.idle:
    cmp ecx, [cpu_count]
    jae .out
    PERCPU rdi, rcx
    cmp byte [rdi + PC_SCHED_ON], 0
    je .next_idle
    cmp dword [rdi + PC_BUSY], 0
    jne .next_idle
    cmp dword [rdi + PC_RQ_LEN], 0
    jne .next_idle
    mov al, 1
    xchg al, [rdi + PC_RESCHED]
    test al, al
    jnz .out                            ; already woken
    cmp rdi, [gs:PC_SELF]
    je .out
    mov edi, [rdi + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_RESCHED
    call lapic_send_ipi
    jmp .out
.next_idle:
    inc ecx
    jmp .idle
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; sched_steal(R12 = this CPU's block, interrupts off, no lock held) -> EAX =
; 1 if a thread waiting on another CPU's queue was moved here
sched_steal:
    push rbx
    push r13
    push r14
    push r15
    xor r14d, r14d                      ; other CPUs idle: P-cores
    xor r15d, r15d                      ; E-cores
    xor r13d, r13d                      ; the busiest queue's CPU block
    xor ebx, ebx                        ; and its length
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .scanned
    PERCPU rdx, rcx
    cmp rdx, r12
    je .next
    cmp byte [rdx + PC_SCHED_ON], 0
    je .next
    mov eax, [rdx + PC_RQ_LEN]
    cmp eax, ebx
    jbe .not_busiest
    mov ebx, eax
    mov r13, rdx
.not_busiest:
    test eax, eax
    jnz .next
    cmp dword [rdx + PC_BUSY], 0
    jne .next
    cmp qword [rdx + PC_SKIND], CPU_KIND_P
    jne .idle_e
    inc r14d
    jmp .next
.idle_e:
    cmp qword [rdx + PC_SKIND], CPU_KIND_E
    jne .next
    inc r15d
.next:
    inc ecx
    jmp .cpu
.scanned:
    test ebx, ebx
    jz .none
    push r12
    mov r12, r13
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rbx, [r12 + PC_RQ]
.find:
    test rbx, rbx
    jz .give_up
    cmp qword [rbx + TH_PIN], -1
    jne .skip
    mov rax, [rsp]                      ; what kind are we?
    mov rax, [rax + PC_SKIND]
    cmp rax, CPU_KIND_P
    jne .on_e
    cmp qword [rbx + TH_CLASS], THC_EFF ; leave it for an idle E-core
    jne .take
    test r15d, r15d
    jnz .skip
    jmp .take
.on_e:
    cmp rax, CPU_KIND_E
    jne .take
    cmp qword [rbx + TH_CLASS], THC_EFF
    je .take
    test r14d, r14d                     ; leave it for an idle P-core
    jnz .skip
    jmp .take
.skip:
    mov rbx, [rbx + TH_NEXT]
    jmp .find
.give_up:
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    pop r12
    jmp .none
.take:
    mov rdi, rbx
    call rq_remove
    mov rax, [r12 + PC_MIN_VR]
    sub [rbx + TH_VR], rax
    mov rax, [rsp]
    mov rax, [rax + PC_INDEX]
    mov [rbx + TH_CPU], rax
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    pop r12
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    mov rax, [r12 + PC_MIN_VR]
    add [rbx + TH_VR], rax
    mov rdi, rbx
    call rq_insert
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_unlock
    inc qword [r12 + PC_STEALS]
    mov eax, 1
    jmp .out
.none:
    xor eax, eax
.out:
    pop r15
    pop r14
    pop r13
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The idle thread: whatever waits here, or something to steal; else what
;  dead threads left, else sleep until an interrupt
; -----------------------------------------------------------------------------
sched_idle_loop:
    cli
    mov r12, [gs:PC_SELF]
    cmp byte [r12 + PC_RESCHED], 0
    jne .run
    cmp dword [r12 + PC_RQ_LEN], 0
    jne .run
    call sched_steal
    test eax, eax
    jnz .run
    cmp qword [zombies], 0
    jne .reap
    call cpu_idle                       ; STI; HLT or STI; MWAIT, atomic
    jmp sched_idle_loop
.run:
    lea rdi, [r12 + PC_RQ_LOCK]
    call spin_lock
    call schedule_locked
    jmp sched_idle_loop
.reap:
    sti
    call sched_reap
    jmp sched_idle_loop

; sched_preempt: isr_common, on the way out of an interrupt that asked for a
; switch (interrupts off)
sched_preempt:
    cmp qword [gs:PC_CURRENT], 0
    je .out
    jmp sched_yield_off
.out:
    ret

; sched_wake_irq: a job was published; this CPU's worker takes its share
sched_wake_irq:
    mov rdi, [gs:PC_WORKER]
    test rdi, rdi
    jz .out
    jmp thread_unpark
.out:
    ret

; sched_irq_main: a device interrupt; the drivers run from the main loop
sched_irq_main:
    mov rdi, [main_thread]
    test rdi, rdi
    jz .out
    jmp thread_unpark
.out:
    ret

; -----------------------------------------------------------------------------
;  thread_where(RDI = buffer, RSI = address) -> RAX = length of what it says
;  about the address if it is on or under a thread's stack, else 0
; -----------------------------------------------------------------------------
thread_where:
    push rbx
    push rcx
    push rdx
    pushfq
    cli
    cmp dword [panic_active], 0         ; the other CPUs are stopped, locks and all
    jne .walk
    push rdi
    lea rdi, [threads_lock]
    call spin_lock
    pop rdi
.walk:
    mov rbx, [thread_list]
.thread:
    test rbx, rbx
    jz .none
    mov rax, [rbx + TH_STACK]
    test rax, rax
    jz .next
    cmp rsi, rax
    jb .below
    cmp rsi, [rbx + TH_STACK_TOP]
    jae .next
    lea rax, [rbx + TH_NAME]
    SPRINTF rdi, "the stack of thread %u, %s", qword [rbx + TH_ID], rax
    jmp .said
.below:
    lea rdx, [rax - 4096]
    and rdx, -VM_SLOT
    cmp rsi, rdx
    jb .next
    lea rax, [rbx + TH_NAME]
    SPRINTF rdi, "the guard page below the stack of thread %u, %s (a stack overflow)", qword [rbx + TH_ID], rax
    jmp .said
.next:
    mov rbx, [rbx + TH_ALL_NEXT]
    jmp .thread
.none:
    xor eax, eax
.said:
    cmp dword [panic_active], 0
    jne .out
    push rdi
    lea rdi, [threads_lock]
    call spin_unlock
    pop rdi
.out:
    popfq
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
str_th_main:    db 'main', 0
str_th_idle0:   db 'idle/0', 0
str_sched_oom:  db 'Out of memory for the scheduler', 0

section .data
align 8
sched_ready:    db 0
sched_xsave:    db 0                    ; XSAVE, else FXSAVE
sched_tsc_deadline: db 0

section .bss
alignb 8
main_thread:    resq 1
threads_ended:  resq 1
zombies:        resq 1
sched_slice:    resq 1                  ; TSC ticks
sched_gran:     resq 1
sched_credit:   resq 1
sched_bal:      resq 1
sched_house:    resq 1
sched_tsize:    resq 1                  ; bytes above a thread's stack
stack_cache:    resq 1                  ; ended threads' mappings, linked by their first qword
stack_cached:   resq 1
sched_np:       resq 1                  ; online CPUs the scheduler takes for P-cores
sched_ne:       resq 1                  ; and for E-cores
lapic_per_ms:   resq 1
sched_area:     resd 1                  ; bytes of SIMD state
stack_lock:     resd 1
zombie_lock:    resd 1
