; =============================================================================
;  ringtest.asm - 'rings': each ring and the thread 'async'; and 'rings
;  test', the self-test of rings, requests and timers
; =============================================================================

RT_CQ_MAX       equ 64                  ; completions a test context keeps
RT_WORKERS      equ 8
RT_STRESS_MS    equ 200
RT_BATCHES      equ 1000                ; timed

; a ring as a test uses it
RC_RING         equ 0                   ; its handle
RC_AREA         equ 8                   ; its memory's handle
RC_BASE         equ 16                  ; where that is
RC_GOT          equ 24                  ; dword: completions read into RC_CQ
RC_SQE          equ 32                  ; the entry being written
RC_CQ           equ 96                  ; RT_CQ_MAX completions read
RC_SIZE         equ 96 + RT_CQ_MAX * CQ_SIZE

; a stress worker: its ring first
RW_EV           equ RC_SIZE             ; the event it waits for
RW_OPS          equ RC_SIZE + 8
RW_ODD          equ RC_SIZE + 16
RW_WOKE         equ RC_SIZE + 24
RW_TIMED        equ RC_SIZE + 32
RW_TH           equ RC_SIZE + 40
RW_SIZE         equ RC_SIZE + 64

; a line of the listing
RL_ID           equ 0
RL_MAKER        equ 8
RL_SQN          equ 16
RL_CQN          equ 24
RL_OWED         equ 32
RL_LIVE         equ 40
RL_TAKEN        equ 48
RL_DONE         equ 56
RL_ASYNC        equ 64
RL_CANCELED     equ 72
RL_NAME         equ 80
RL_SIZE         equ 112

; SQE op, flags, data: R15's entry cleared, and those set
%macro SQE 3
    call rc_clear
    mov byte [r15 + RC_SQE + SQ_OP], %1
    mov byte [r15 + RC_SQE + SQ_FLAGS], %2
    mov qword [r15 + RC_SQE + SQ_DATA], %3
%endmacro

section .text

; -----------------------------------------------------------------------------
;  rings [test]
; -----------------------------------------------------------------------------
cmd_rings:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je rings_list
    call arg_split
    lea rdi, [str_ob_test]
    call streq
    test eax, eax
    jnz rings_test
    KLOG "usage: rings [test]"
    ret

rings_list:
    push rbx
    push r12
    push r13
    push r14
    mov eax, [tm_count]
    KLOG "  %u rings; requests: %u in being, %u finished; timers: %u waiting, %u fired", qword [ty_ring + TY_LIVE], qword [rq_live], qword [as_finished], rax, qword [tm_fired]
    mov rdi, [ty_ring + TY_LIVE]        ; a copy, taken under the lock
    add rdi, 8
    imul rdi, rdi, RL_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov r14, rax
    mov r13, [ty_ring + TY_LIVE]
    add r13, 8
    xor r12d, r12d
    pushfq
    cli
    lea rdi, [ty_ring + TY_LOCK]
    call spin_lock
    mov rbx, [ty_ring + TY_LIST]
.copy:
    test rbx, rbx
    jz .copied
    cmp r12, r13
    jae .copied
    imul rdi, r12, RL_SIZE
    add rdi, r14
    mov rax, [rbx + OB_ID]
    mov [rdi + RL_ID], rax
    mov eax, [rbx + OB_MAKER]
    mov [rdi + RL_MAKER], rax
    mov eax, [rbx + RG_SQN]
    mov [rdi + RL_SQN], rax
    mov eax, [rbx + RG_CQN]
    mov [rdi + RL_CQN], rax
    mov eax, [rbx + RG_PROMISED]
    sub eax, [rbx + RG_CQ_TAIL]
    mov [rdi + RL_OWED], rax
    mov eax, [rbx + RG_LIVE]
    mov [rdi + RL_LIVE], rax
    mov rax, [rbx + RG_SUBMITTED]
    mov [rdi + RL_TAKEN], rax
    mov rax, [rbx + RG_COMPLETED]
    mov [rdi + RL_DONE], rax
    mov rax, [rbx + RG_ASYNC]
    mov [rdi + RL_ASYNC], rax
    mov rax, [rbx + RG_CANCELED]
    mov [rdi + RL_CANCELED], rax
    lea rsi, [rbx + OB_NAME]
    add rdi, RL_NAME
    mov ecx, OB_NAME_LEN
    rep movsb
    inc r12
    mov rbx, [rbx + OB_NEXT]
    jmp .copy
.copied:
    lea rdi, [ty_ring + TY_LOCK]
    call spin_unlock
    popfq
    test r12, r12
    jz .free
    KLOG "  ring  name          by  entries  completions  owed  waiting      taken  completed     waited  canceled"
    xor r13d, r13d
.line:
    cmp r13, r12
    jae .free
    imul rbx, r13, RL_SIZE
    add rbx, r14
    lea rsi, [rbx + RL_NAME]
    KLOG "  %4u  %-12s  %2u  %7u  %11u  %4u  %7u  %9u  %9u  %9u  %8u", qword [rbx + RL_ID], rsi, qword [rbx + RL_MAKER], qword [rbx + RL_SQN], qword [rbx + RL_CQN], qword [rbx + RL_OWED], qword [rbx + RL_LIVE], qword [rbx + RL_TAKEN], qword [rbx + RL_DONE], qword [rbx + RL_ASYNC], qword [rbx + RL_CANCELED]
    inc r13
    jmp .line
.free:
    mov rdi, r14
    call kfree
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  A ring as a test uses it: R15 = its RC_*
; -----------------------------------------------------------------------------

; rc_open(R15, EDI = entries) -> RAX = 0, or E_*
rc_open:
    lea rsi, [str_rt_ring]
    call h_ring_new
    cmp rax, E_ANY
    jae .out
    mov [r15 + RC_RING], rax
    mov [r15 + RC_AREA], rdx
    mov dword [r15 + RC_GOT], 0
    mov edi, edx
    mov esi, OT_MEMORY
    mov edx, RT_MEM_READ | RT_MEM_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rcx, [rax + MO_BASE]
    mov [r15 + RC_BASE], rcx
    mov rdi, rax
    call obj_put
    xor eax, eax
.out:
    ret

; rc_close(R15): its handles closed
rc_close:
    mov edi, [r15 + RC_RING]
    call handle_close
    mov edi, [r15 + RC_AREA]
    jmp handle_close

; rc_clear(R15): its entry zeroed. Preserves all.
rc_clear:
    push rax
    push rcx
    push rdi
    lea rdi, [r15 + RC_SQE]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    pop rcx
    pop rax
    ret

; rc_push(R15): its entry written into the ring, the tail moved. Preserves
; all.
rc_push:
    push rax
    push rcx
    push rsi
    push rdi
    mov rdi, [r15 + RC_BASE]
    mov eax, [rdi + RA_SQ_TAIL]
    mov ecx, [rdi + RA_SQ_ENTRIES]
    dec ecx
    and ecx, eax
    shl ecx, 6
    add ecx, [rdi + RA_SQ_OFF]
    add rdi, rcx
    lea rsi, [r15 + RC_SQE]
    mov ecx, SQ_SIZE / 8
    rep movsq
    mov rdi, [r15 + RC_BASE]
    inc dword [rdi + RA_SQ_TAIL]
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; rc_enter(R15, ESI = entries to take, EDX = completions to wait for, ECX
; = milliseconds to wait at most, 0 for no deadline) -> RAX
rc_enter:
    xor eax, eax
    test ecx, ecx
    jz .go
    mov edi, ecx
    call ob_deadline
.go:
    mov rcx, rax
    mov edi, [r15 + RC_RING]
    jmp h_ring_enter

; rc_reap(R15) -> EAX = completions read into RC_CQ, after those there
rc_reap:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, [r15 + RC_BASE]
    xor eax, eax
.next:
    mov ecx, [rbx + RA_CQ_HEAD]
    cmp ecx, [rbx + RA_CQ_TAIL]
    je .out
    cmp dword [r15 + RC_GOT], RT_CQ_MAX
    jae .out
    mov esi, [rbx + RA_CQ_ENTRIES]
    dec esi
    and esi, ecx
    shl esi, 5
    add esi, [rbx + RA_CQ_OFF]
    add rsi, rbx
    mov edi, [r15 + RC_GOT]
    shl edi, 5
    lea rdi, [rdi + RC_CQ]
    add rdi, r15
    mov ecx, CQ_SIZE / 8
    rep movsq
    inc dword [r15 + RC_GOT]
    inc dword [rbx + RA_CQ_HEAD]
    inc eax
    jmp .next
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rc_forget(R15): none read. Preserves all.
rc_forget:
    mov dword [r15 + RC_GOT], 0
    ret

; rc_find(R15, RDI = data) -> RAX = the result of the first completion read
; with that data, RDX = its value, ECX = its place; RAX = RT_NONE, ECX = -1
; if there is none
RT_NONE         equ 0x7E57
rc_find:
    push rsi
    xor ecx, ecx
    lea rsi, [r15 + RC_CQ]
.look:
    cmp ecx, [r15 + RC_GOT]
    jae .none
    cmp [rsi + CQ_DATA], rdi
    je .found
    add rsi, CQ_SIZE
    inc ecx
    jmp .look
.found:
    mov rax, [rsi + CQ_RESULT]
    mov rdx, [rsi + CQ_VALUE]
    pop rsi
    ret
.none:
    mov eax, RT_NONE
    xor edx, edx
    mov ecx, -1
    pop rsi
    ret

; rt_drain(R15): every completion waiting read and dropped
rt_drain:
    push rax
    push rdi
    mov rdi, [r15 + RC_BASE]
    mov eax, [rdi + RA_CQ_TAIL]
    mov [rdi + RA_CQ_HEAD], eax
    pop rdi
    pop rax
    ret

; -----------------------------------------------------------------------------
;  rings test
; -----------------------------------------------------------------------------
rings_test:
    push rbx
    mov qword [test_fails], 0
    lea rax, [str_rt_name]
    mov [test_name], rax
    call sched_reap
    call rt_counts
    lea rsi, [rt_now]
    lea rdi, [rt_base_counts]
    mov ecx, 9
    rep movsq
    call rt_basic
    call rt_async
    call rt_timeouts
    call rt_links
    call rt_cancel
    call rt_join
    call rt_copy
    call rt_full
    call rt_corrupt
    call rt_orphan
    call rt_stress
    call rt_speed
    call rt_leaks
    cmp qword [test_fails], 0
    jne .failed
    KLOG "rings test: passed"
    jmp .out
.failed:
    KLOG "rings test: FAILED (%u)", qword [test_fails]
.out:
    pop rbx
    ret

; rt_counts: what there is now, into rt_now
rt_counts:
    mov rax, [ty_ring + TY_LIVE]
    mov [rt_now], rax
    mov rax, [rq_live]
    mov [rt_now + 8], rax
    mov eax, [tm_count]
    mov [rt_now + 16], rax
    mov rax, [ty_event + TY_LIVE]
    mov [rt_now + 24], rax
    mov rax, [ty_memory + TY_LIVE]
    mov [rt_now + 32], rax
    mov rax, [ty_thread + TY_LIVE]
    mov [rt_now + 40], rax
    mov rax, [task_kernel]
    mov eax, [rax + TK_USED]
    mov [rt_now + 48], rax
    mov rax, [heap_objects]
    mov [rt_now + 56], rax
    mov rax, [vm_count]
    sub rax, [stack_cached]
    mov [rt_now + 64], rax
    ret

; entries done at once, and their completions
rt_basic:
    push rbx
    push r12
    push r13
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    OB_WANT 0, "making a ring of 8"
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    SQE RO_NOP, 0, 1
    call rc_push
    SQE RO_NOP, 0, 2
    call rc_push
    SQE RO_SIGNAL, 0, 3
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    SQE RO_DUP, 0, 4
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov qword [r15 + RC_SQE + SQ_A0], RT_EV_SIGNAL
    call rc_push
    SQE 99, 0, 5
    call rc_push
    SQE RO_SIGNAL, 0, 6
    mov dword [r15 + RC_SQE + SQ_HANDLE], 0x7FFF1234
    call rc_push
    SQE RO_WAIT, 0, 7
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    mov esi, 7
    mov edx, 7
    mov ecx, 100
    call rc_enter
    OB_WANT 7, "entries taken"
    call rc_reap
    OB_WANT 7, "completions"
    mov edi, 1
    call rc_find
    OB_WANT 0, "a nop"
    mov edi, 2
    call rc_find
    mov eax, ecx
    OB_WANT 1, "the second nop's completion, second"
    mov edi, 3
    call rc_find
    OB_WANT 0, "signalling an event"
    mov edi, 4
    call rc_find
    OB_GOT "deriving a handle"
    mov r13, rax
    mov edi, 5
    call rc_find
    OB_WANT E_ARG, "an operation there is not"
    mov edi, 6
    call rc_find
    OB_WANT E_BADH, "signalling through a handle never given out"
    mov edi, 7
    call rc_find
    OB_WANT 0, "waiting for an event signalled already"
    mov rax, [r15 + RC_BASE]
    mov eax, [rax + RA_SQ_HEAD]
    OB_WANT 7, "the submission head the kernel wrote"
    mov edi, r13d
    call handle_info
    mov rax, rdx
    OB_WANT RT_EV_SIGNAL, "the rights of the handle derived through the ring"
    mov edi, r13d
    call handle_close
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: 7 entries in one go: nops, a signal, a dup with fewer rights, a wait already satisfied, an unknown operation and a forged handle, each completed with what it should"
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; a wait that another thread satisfies
rt_async:
    push rbx
    push r12
    push r13
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    SQE RO_WAIT, 0, 10
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 1, "a wait taken"
    call rc_reap
    OB_WANT 0, "completions before the event is signalled"
    mov [rt_helper_h], r12
    lea rdi, [rt_signal_later]
    xor esi, esi
    lea rdx, [str_rt_helper]
    mov ecx, THC_ANY
    call thread_spawn
    mov r13, rax
    mov esi, 0
    mov edx, 1
    mov ecx, 1000
    call rc_enter
    RDTSC64
    sub rax, [rt_signal_tsc]
    imul rax, rax, 1000
    xor edx, edx
    div qword [tsc_per_us]
    mov [rt_wake_ns], rax
    call rc_reap
    OB_WANT 1, "completions once another thread signalled it"
    mov edi, 10
    call rc_find
    OB_WANT 0, "the wait's result"
    mov rdi, r13
    call thread_join
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: a wait in the ring, nobody blocked on it; another thread signalled the event 2 ms later, and the thread waiting on the ring saw its completion %u ns after", qword [rt_wake_ns]
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

rt_signal_later:                        ; the helper: 2 ms, then the signal
    mov edi, 2000
    call thread_sleep_us
    RDTSC64
    mov [rt_signal_tsc], rax
    mov edi, [rt_helper_h]
    call h_event_signal
    xor eax, eax
    ret

; deadlines
rt_timeouts:
    push rbx
    push r12
    push r13
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    mov edi, 2
    call ob_deadline
    mov r13, rax                        ; in 2 ms
    SQE RO_WAIT, 0, 20
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov [r15 + RC_SQE + SQ_DEADLINE], r13
    call rc_push
    mov edi, 1
    call ob_deadline
    SQE RO_TIMEOUT, 0, 21
    mov [r15 + RC_SQE + SQ_DEADLINE], rax
    call rc_push
    SQE RO_TIMEOUT, 0, 22               ; no time given
    call rc_push
    mov esi, 3
    mov edx, 3
    mov ecx, 1000
    call rc_enter
    OB_WANT 3, "entries taken"
    RDTSC64
    cmp rax, r13
    setae al
    movzx eax, al
    OB_WANT 1, "the wait's deadline past once it said so"
    call rc_reap
    mov edi, 20
    call rc_find
    OB_WANT E_TIMEOUT, "a wait of 2 ms for an event never signalled"
    mov eax, ecx
    OB_WANT 2, "its completion, last"
    mov edi, 21
    call rc_find
    OB_WANT 0, "a timeout of 1 ms"
    mov eax, ecx
    OB_WANT 1, "its completion, second"
    mov edi, 22
    call rc_find
    OB_WANT E_ARG, "a timeout with no time"
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: a 1 ms timeout and a 2 ms wait completed in the order of their deadlines, after them; a timeout with no time refused"
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; entries linked
rt_links:
    push rbx
    push r12
    push r13
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making another"
    mov r13, rax
    SQE RO_WAIT, SQF_LINK, 30
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    SQE RO_SIGNAL, SQF_LINK, 31
    mov [r15 + RC_SQE + SQ_HANDLE], r13d
    call rc_push
    SQE RO_NOP, 0, 32
    call rc_push
    mov esi, 3
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 3, "a chain of three taken"
    call rc_reap
    OB_WANT 0, "completions before its first is satisfied"
    mov edi, r12d
    call h_event_signal
    mov edi, 100
    call ob_deadline
    mov rsi, rax
    mov edi, r13d
    call h_event_wait
    OB_WANT 0, "the second event, signalled by the entry linked after the wait, nobody in the ring"
    mov esi, 0
    mov edx, 3
    mov ecx, 100
    call rc_enter
    call rc_reap
    OB_WANT 3, "the chain's completions"
    mov edi, 30
    call rc_find
    OB_WANT 0, "the wait"
    mov eax, ecx
    OB_WANT 0, "its completion, first"
    mov edi, 31
    call rc_find
    OB_WANT 0, "the signal linked after it"
    mov eax, ecx
    OB_WANT 1, "its completion, second"
    mov edi, 32
    call rc_find
    OB_WANT 0, "the nop linked after that"
    mov eax, ecx
    OB_WANT 2, "its completion, third"
    call rc_forget                      ; chains that fail
    SQE RO_SIGNAL, SQF_LINK, 33
    mov dword [r15 + RC_SQE + SQ_HANDLE], 0x7FFF1234
    call rc_push
    SQE RO_NOP, 0, 34
    call rc_push
    mov edi, r12d
    call h_event_reset
    mov edi, 1
    call ob_deadline
    SQE RO_WAIT, SQF_LINK, 35
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov [r15 + RC_SQE + SQ_DEADLINE], rax
    call rc_push
    SQE RO_NOP, 0, 36
    call rc_push
    mov esi, 4
    mov edx, 4
    mov ecx, 200
    call rc_enter
    OB_WANT 4, "two chains taken"
    call rc_reap
    OB_WANT 4, "their completions"
    mov edi, 33
    call rc_find
    OB_WANT E_BADH, "a signal through a forged handle"
    mov edi, 34
    call rc_find
    OB_WANT E_CANCELED, "what was linked after it"
    mov edi, 35
    call rc_find
    OB_WANT E_TIMEOUT, "a wait that timed out"
    mov edi, 36
    call rc_find
    OB_WANT E_CANCELED, "what was linked after that"
    mov edi, r12d
    call handle_close
    mov edi, r13d
    call handle_close
    call rc_close
    KLOG "rings test: a wait linked to a signal linked to a nop: the signal went out once the wait was satisfied, with nobody in the ring, and the three completed in order; after a refusal or a timeout the rest of a chain was canceled"
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; RO_CANCEL
rt_cancel:
    push r12
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    SQE RO_WAIT, 0, 40
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    SQE RO_CANCEL, 0, 41
    mov qword [r15 + RC_SQE + SQ_A0], 40
    call rc_push
    SQE RO_CANCEL, 0, 42
    mov qword [r15 + RC_SQE + SQ_A0], 999
    call rc_push
    mov esi, 2
    mov edx, 3
    mov ecx, 100
    call rc_enter
    OB_WANT 2, "two cancels taken"
    call rc_reap
    OB_WANT 3, "completions"
    mov edi, 40
    call rc_find
    OB_WANT E_CANCELED, "the wait canceled"
    mov edi, 41
    call rc_find
    OB_WANT 1, "requests the cancel took back"
    mov edi, 42
    call rc_find
    OB_WANT 0, "requests a cancel of nothing took back"
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: a wait never satisfied, canceled by an entry naming its data; a cancel naming nothing took back nothing"
    pop r15
    pop r12
    ret

; RO_JOIN
rt_join:
    push r12
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [rt_child]
    xor esi, esi
    lea rdx, [str_rt_helper]
    mov ecx, THC_ANY
    call thread_spawn
    mov rdi, rax                        ; its handle's reference into a handle
    mov esi, RT_ALL
    call handle_new
    OB_GOT "a handle to a thread"
    mov r12, rax
    SQE RO_JOIN, 0, 50
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    mov esi, 1
    mov edx, 1
    mov ecx, 1000
    call rc_enter
    call rc_reap
    OB_WANT 1, "the join's completion"
    mov edi, 50
    call rc_find
    push rdx
    OB_WANT 0, "joining a thread"
    pop rax
    OB_WANT 42, "what the thread returned, in the completion"
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: a join completed when the thread ended, with what it returned"
    pop r15
    pop r12
    ret

rt_child:
    mov edi, 1000
    call thread_sleep_us
    mov eax, 42
    ret

; RO_COPY
rt_copy:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    mov edi, 8192
    lea rsi, [str_rt_mem]
    call h_mem_new
    OB_GOT "making 8 KiB of memory"
    mov r12, rax
    mov edi, 4096
    lea rsi, [str_rt_mem]
    call h_mem_new
    OB_GOT "making 4 KiB"
    mov r13, rax
    xor eax, eax
.fill:
    lea rdi, [ob_buf]
    mov [rdi + rax], al
    inc eax
    cmp eax, 256
    jb .fill
    xor ebx, ebx
.write:
    mov edi, r12d
    mov rsi, rbx
    lea rdx, [ob_buf]
    mov ecx, 256
    call h_mem_write
    add ebx, 256
    cmp ebx, 8192
    jb .write
    mov edi, r13d                       ; a read-only window on the second
    xor esi, esi
    mov edx, 4096
    mov ecx, RT_MEM_READ
    call handle_window
    OB_GOT "a read-only window"
    mov r14, rax
    SQE RO_COPY, 0, 60
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov qword [r15 + RC_SQE + SQ_A0], 100
    mov [r15 + RC_SQE + SQ_HANDLE2], r13d
    mov qword [r15 + RC_SQE + SQ_A1], 8
    mov qword [r15 + RC_SQE + SQ_A2], 200
    call rc_push
    SQE RO_COPY, 0, 61
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov [r15 + RC_SQE + SQ_HANDLE2], r14d
    mov qword [r15 + RC_SQE + SQ_A2], 10
    call rc_push
    SQE RO_COPY, 0, 62
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    mov qword [r15 + RC_SQE + SQ_A0], 8000
    mov [r15 + RC_SQE + SQ_HANDLE2], r13d
    mov qword [r15 + RC_SQE + SQ_A2], 200
    call rc_push
    SQE RO_COPY, 0, 63                  ; within one block, overlapping
    mov [r15 + RC_SQE + SQ_HANDLE], r13d
    mov [r15 + RC_SQE + SQ_HANDLE2], r13d
    mov qword [r15 + RC_SQE + SQ_A1], 1
    mov qword [r15 + RC_SQE + SQ_A2], 300
    call rc_push
    mov esi, 4
    mov edx, 4
    mov ecx, 100
    call rc_enter
    call rc_reap
    OB_WANT 4, "completions"
    mov edi, 60
    call rc_find
    OB_WANT 200, "copying 200 bytes from one block to another"
    mov edi, 61
    call rc_find
    OB_WANT E_RIGHTS, "copying into a read-only window"
    mov edi, 62
    call rc_find
    OB_WANT E_RANGE, "copying from past the end"
    mov edi, 63
    call rc_find
    OB_WANT 300, "copying 300 bytes one byte along, in the same block"
    mov edi, r13d
    xor esi, esi
    lea rdx, [ob_buf2]
    mov ecx, 256
    call h_mem_read
    movzx eax, byte [ob_buf2 + 9]
    OB_WANT 100, "the byte at 9: what was at 100 of the first, moved one along"
    movzx eax, byte [ob_buf2 + 1]
    OB_WANT 0, "the byte at 1: what was at 0, moved one along"
    movzx eax, byte [ob_buf2 + 208]
    OB_WANT 43, "the byte at 208: the copy's last, 299 of the first, moved one along"
    mov edi, r14d
    call handle_close
    mov edi, r13d
    call handle_close
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: copies between blocks of memory by handle: the bytes right, an overlapping one too; into a read-only window and from past the end refused"
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; no completion without a place for it
rt_full:
    push rbx
    push r12
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    xor ebx, ebx
.first:
    SQE RO_WAIT, 0, rbx
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    inc ebx
    cmp ebx, 8
    jb .first
    mov esi, 8
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 8, "eight waits taken"
.second:
    SQE RO_WAIT, 0, rbx
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    inc ebx
    cmp ebx, 16
    jb .second
    mov esi, 8
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 8, "eight more taken: sixteen completions owed, as many as there are places"
    SQE RO_NOP, 0, 100
    call rc_push
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 0, "an entry with every place promised"
    mov edi, r12d
    call h_event_signal
    xor esi, esi
    mov edx, 16
    mov ecx, 200
    call rc_enter
    call rc_reap
    OB_WANT 16, "the waits' completions, once the event was signalled"
    call rc_forget
    mov esi, 1
    mov edx, 1
    mov ecx, 100
    call rc_enter
    OB_WANT 1, "the entry left, taken once they were read"
    call rc_reap
    mov edi, 100
    call rc_find
    OB_WANT 0, "its result"
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: with 16 completions owed in a ring with places for 16, a 17th entry waited in the queue until they were read"
    pop r15
    pop r12
    pop rbx
    ret

; indices that make no sense
rt_corrupt:
    push rbx
    push r15
    lea r15, [rt_ctx]
    mov edi, 8
    call rc_open
    mov rbx, [r15 + RC_BASE]
    add dword [rbx + RA_SQ_TAIL], 1000
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT E_ARG, "a submission tail 1000 past the head"
    sub dword [rbx + RA_SQ_TAIL], 1000
    add dword [rbx + RA_CQ_HEAD], 5000
    SQE RO_NOP, 0, 1
    call rc_push
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 0, "an entry while the completion head is past the tail"
    sub dword [rbx + RA_CQ_HEAD], 5000
    mov esi, 1
    mov edx, 1
    mov ecx, 100
    call rc_enter
    OB_WANT 1, "the entry, once the head made sense again"
    call rc_close
    KLOG "rings test: a submission tail too far ahead refused; a completion head past the tail took nothing, and nothing broke"
    pop r15
    pop rbx
    ret

; a ring closed with requests waiting
rt_orphan:
    push rbx
    push r12
    push r13
    push r15
    lea r15, [rt_ctx]
    call rt_settle                      ; the requests before this one freed
    mov rbx, [rq_live]
    mov r13d, [tm_count]
    mov edi, 8
    call rc_open
    lea rdi, [str_rt_ev]
    call h_event_new
    OB_GOT "making an event"
    mov r12, rax
    SQE RO_WAIT, 0, 70
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    mov edi, 10000
    call ob_deadline
    SQE RO_TIMEOUT, 0, 71
    mov [r15 + RC_SQE + SQ_DEADLINE], rax
    call rc_push
    SQE RO_WAIT, SQF_LINK, 72
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    call rc_push
    SQE RO_NOP, 0, 73
    call rc_push
    mov esi, 4
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    OB_WANT 4, "two waits, a 10 s timeout and a nop linked after a wait"
    mov rax, [rq_live]
    sub rax, rbx
    OB_WANT 4, "requests in being"
    mov eax, [tm_count]
    sub eax, r13d
    OB_WANT 1, "timers waiting"
    call rings_list                     ; as 'rings' shows it
    call rc_close
    call rt_settle
    mov rax, [rq_live]
    sub rax, rbx
    OB_WANT 0, "requests left once the ring's handles were closed"
    mov eax, [tm_count]
    sub eax, r13d
    OB_WANT 0, "timers left"
    mov edi, r12d
    mov esi, OT_EVENT
    xor edx, edx
    call handle_get
    OB_GOT "looking at the event"
    mov rdi, rax
    mov eax, [rdi + OB_REFS]
    call obj_put
    OB_WANT 2, "references to the event (its handle's and the look's)"
    mov edi, r12d
    call handle_close
    KLOG "rings test: a ring closed with two waits, a 10 s timeout and a chain waiting: all canceled, their requests and timer gone, the event let go"
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; rt_settle: until the thread 'async' has finished what it was given (up to
; 200 ms)
rt_settle:
    push rbx
    mov ebx, 200
.wait:
    mov edi, 1000
    call thread_sleep_us
    cmp qword [as_list], 0
    jne .more
    mov rax, [async_thread]             ; and is parked again
    cmp dword [rax + TH_STATE], TS_PARKED
    je .out
.more:
    dec ebx
    jnz .wait
.out:
    pop rbx
    ret

; threads each with a ring, waits woken and timing out
rt_stress:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea rdi, [str_rt_shared]
    call h_event_new
    OB_GOT "making an event"
    mov [rt_shared], rax
    mov r12d, [cpus_online]
    cmp r12d, RT_WORKERS
    jbe .some
    mov r12d, RT_WORKERS
.some:
    cmp r12d, 2
    jae .enough
    mov r12d, 2
.enough:
    lea rdi, [rt_workers]
    xor eax, eax
    mov ecx, RT_WORKERS * RW_SIZE / 8
    rep stosq
    xor ebx, ebx
.events:
    cmp ebx, r12d
    jae .made
    lea rdi, [str_rt_ev]
    call h_event_new
    imul rcx, rbx, RW_SIZE
    lea rdx, [rt_workers]
    add rcx, rdx
    mov [rcx + RW_EV], rax
    inc ebx
    jmp .events
.made:
    mov byte [rt_stop], 0
    xor ebx, ebx
.start:
    cmp ebx, r12d
    jae .started
    imul rsi, rbx, RW_SIZE
    lea rax, [rt_workers]
    add rsi, rax
    push rsi
    lea rdi, [rt_worker]
    lea rdx, [str_rt_worker]
    mov ecx, THC_ANY
    call thread_spawn
    pop rsi
    mov [rsi + RW_TH], rax
    inc ebx
    jmp .start
.started:
    lea rdi, [rt_signaller]
    mov esi, r12d
    lea rdx, [str_rt_helper]
    mov ecx, THC_ANY
    call thread_spawn
    mov r13, rax
    mov edi, RT_STRESS_MS * 1000
    call thread_sleep_us
    mov byte [rt_stop], 1
    mov rdi, r13
    call thread_join
    xor ebx, ebx
    xor eax, eax
    mov [rt_ops], rax
    mov [rt_odd], rax
    mov [rt_woke], rax
    mov [rt_timed], rax
.join:
    cmp ebx, r12d
    jae .joined
    imul r14, rbx, RW_SIZE
    lea rax, [rt_workers]
    add r14, rax
    mov rdi, [r14 + RW_TH]
    test rdi, rdi
    jz .counted
    call thread_join
.counted:
    mov rax, [r14 + RW_OPS]
    add [rt_ops], rax
    mov rax, [r14 + RW_ODD]
    add [rt_odd], rax
    mov rax, [r14 + RW_WOKE]
    add [rt_woke], rax
    mov rax, [r14 + RW_TIMED]
    add [rt_timed], rax
    mov edi, [r14 + RW_EV]
    call handle_close
    inc ebx
    jmp .join
.joined:
    mov edi, [rt_shared]
    call handle_close
    KLOG "rings test: %u threads, each with a ring, for %u ms: %u entries, %u waits woken and %u timed out (each with what was linked after it run or canceled to match), %u unexpected results", r12, RT_STRESS_MS, qword [rt_ops], qword [rt_woke], qword [rt_timed], qword [rt_odd]
    mov rax, [rt_odd]
    OB_WANT 0, "unexpected results"
    xor eax, eax
    cmp qword [rt_ops], 0
    setne al
    OB_WANT 1, "entries done"
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

rt_worker:                              ; RDI = its RW_*, a ring first
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    mov rbx, rdi
    mov edi, 16
    call rc_open
    test rax, rax
    jnz .broken
.batch:
    cmp byte [rt_stop], 0
    jne .done
    call rc_forget
    RDTSC64
    mov r12, rax                        ; now
    SQE RO_NOP, 0, 1
    call rc_push
    call rc_push
    SQE RO_SIGNAL, 0, 2
    mov eax, [rt_shared]
    mov [r15 + RC_SQE + SQ_HANDLE], eax
    call rc_push
    mov rax, [tsc_per_us]
    imul rax, rax, 200
    add rax, r12
    SQE RO_WAIT, SQF_LINK, 3
    mov ecx, [rbx + RW_EV]
    mov [r15 + RC_SQE + SQ_HANDLE], ecx
    mov [r15 + RC_SQE + SQ_DEADLINE], rax
    call rc_push
    SQE RO_NOP, 0, 4
    call rc_push
    mov rax, [tsc_per_us]
    imul rax, rax, 100
    add rax, r12
    SQE RO_TIMEOUT, 0, 5
    mov [r15 + RC_SQE + SQ_DEADLINE], rax
    call rc_push
    mov esi, 6
    mov edx, 6
    mov ecx, 1000
    call rc_enter
    cmp rax, 6
    jne .odd
    call rc_reap
    cmp eax, 6
    jne .odd
    add qword [rbx + RW_OPS], 6
    mov edi, 1
    call rc_find
    test rax, rax
    jnz .odd
    mov edi, 2
    call rc_find
    test rax, rax
    jnz .odd
    mov edi, 5
    call rc_find
    test rax, rax
    jnz .odd
    mov edi, 4
    call rc_find
    mov r14, rax
    mov edi, 3
    call rc_find
    test rax, rax
    jnz .timed
    inc qword [rbx + RW_WOKE]
    test r14, r14
    jnz .odd
    jmp .batch
.timed:
    cmp rax, E_TIMEOUT
    jne .odd
    inc qword [rbx + RW_TIMED]
    cmp r14, E_CANCELED
    jne .odd
    jmp .batch
.odd:
    inc qword [rbx + RW_ODD]
    call rt_drain                       ; whatever came, dropped
    jmp .batch
.broken:
    inc qword [rbx + RW_ODD]
    jmp .out
.done:
    call rc_close
.out:
    xor eax, eax
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

rt_signaller:                           ; RDI = how many workers
    push rbx
    push r12
    mov r12d, edi
.round:
    cmp byte [rt_stop], 0
    jne .done
    xor ebx, ebx
.signal:
    cmp ebx, r12d
    jae .signalled
    imul rax, rbx, RW_SIZE
    lea rcx, [rt_workers]
    add rax, rcx
    mov edi, [rax + RW_EV]
    call h_event_signal
    inc ebx
    jmp .signal
.signalled:
    mov edi, 50
    call thread_sleep_us
    xor ebx, ebx
.reset:
    cmp ebx, r12d
    jae .was_reset
    imul rax, rbx, RW_SIZE
    lea rcx, [rt_workers]
    add rax, rcx
    mov edi, [rax + RW_EV]
    call h_event_reset
    inc ebx
    jmp .reset
.was_reset:
    mov edi, 150
    call thread_sleep_us
    jmp .round
.done:
    xor eax, eax
    pop r12
    pop rbx
    ret

; what entries cost
rt_speed:
    push rbx
    push r12
    push r13
    push r14
    push r15
    lea r15, [rt_ctx]
    mov edi, 32
    call rc_open
    RDTSC64                             ; batches of 32 nops
    mov r13, rax
    mov r12d, RT_BATCHES
.batch:
    SQE RO_NOP, 0, 0
    mov ebx, 32
.nops:
    call rc_push
    dec ebx
    jnz .nops
    mov esi, 32
    mov edx, 32
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r12d
    jnz .batch
    RDTSC64
    sub rax, r13
    mov ecx, RT_BATCHES * 32
    call ob_ns
    mov [rt_nop_ns], rax
    RDTSC64                             ; one nop an entry
    mov r13, rax
    mov r12d, RT_BATCHES * 4
.one:
    call rc_push
    mov esi, 1
    mov edx, 1
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r12d
    jnz .one
    RDTSC64
    sub rax, r13
    mov ecx, RT_BATCHES * 4
    call ob_ns
    mov [rt_enter_ns], rax
    lea rdi, [str_rt_ev]
    call h_event_new
    mov r12, rax
    SQE RO_SIGNAL, 0, 0                 ; batches of 32 signals
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    RDTSC64
    mov r13, rax
    mov r14d, RT_BATCHES
.signals:
    mov ebx, 32
.signal:
    call rc_push
    dec ebx
    jnz .signal
    mov esi, 32
    mov edx, 32
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r14d
    jnz .signals
    RDTSC64
    sub rax, r13
    mov ecx, RT_BATCHES * 32
    call ob_ns
    mov [rt_signal_ns], rax
    mov edi, r12d                       ; a wait, then the signal that ends it
    call h_event_reset
    SQE RO_WAIT, 0, 0
    mov [r15 + RC_SQE + SQ_HANDLE], r12d
    RDTSC64
    mov r13, rax
    mov r14d, RT_BATCHES
.waits:
    call rc_push
    mov esi, 1
    xor edx, edx
    xor ecx, ecx
    call rc_enter
    mov edi, r12d
    call h_event_signal
    mov edi, r12d
    call h_event_reset
    xor esi, esi
    mov edx, 1
    xor ecx, ecx
    call rc_enter
    call rt_drain
    dec r14d
    jnz .waits
    RDTSC64
    sub rax, r13
    mov ecx, RT_BATCHES
    call ob_ns
    mov [rt_wait_ns], rax
    call rt_settle
    mov edi, r12d
    call handle_close
    call rc_close
    KLOG "rings test: a nop %u ns in batches of 32, %u ns one at a time; a signal %u ns in batches of 32; a wait taken, then signalled and its completion read, %u ns", qword [rt_nop_ns], qword [rt_enter_ns], qword [rt_signal_ns], qword [rt_wait_ns]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; everything made is gone
rt_leaks:
    call rt_settle
    mov edi, 20000
    call thread_sleep_us
    call sched_reap
    call rt_counts
    KLOG "rings test: %u rings (%u before), %u requests (%u), %u timers (%u), %u events (%u), %u blocks of memory (%u), %u threads (%u), %u handles held by the kernel (%u), %u heap objects (%u), %u vm mappings (%u)", qword [rt_now], qword [rt_base_counts], qword [rt_now + 8], qword [rt_base_counts + 8], qword [rt_now + 16], qword [rt_base_counts + 16], qword [rt_now + 24], qword [rt_base_counts + 24], qword [rt_now + 32], qword [rt_base_counts + 32], qword [rt_now + 40], qword [rt_base_counts + 40], qword [rt_now + 48], qword [rt_base_counts + 48], qword [rt_now + 56], qword [rt_base_counts + 56], qword [rt_now + 64], qword [rt_base_counts + 64]
    xor ecx, ecx
.compare:
    lea rdx, [rt_now]
    mov rax, [rdx + rcx * 8]
    lea rdx, [rt_base_counts]
    cmp rax, [rdx + rcx * 8]
    jne .leak
    inc ecx
    cmp ecx, 9
    jb .compare
    ret
.leak:
    KLOG "rings test: not all of it came back"
    inc qword [test_fails]
    ret

section .rodata
str_rt_name:    db 'rings test', 0
str_rt_ring:    db 'test', 0
str_rt_ev:      db 'test', 0
str_rt_mem:     db 'test', 0
str_rt_shared:  db 'shared', 0
str_rt_helper:  db 'helper', 0
str_rt_worker:  db 'ringer', 0

section .bss
alignb 8
rt_base_counts: resq 9
rt_now:         resq 9
rt_helper_h:    resq 1
rt_signal_tsc:  resq 1
rt_wake_ns:     resq 1
rt_shared:      resq 1
rt_ops:         resq 1
rt_odd:         resq 1
rt_woke:        resq 1
rt_timed:       resq 1
rt_nop_ns:      resq 1
rt_enter_ns:    resq 1
rt_signal_ns:   resq 1
rt_wait_ns:     resq 1
rt_ctx:         resb RC_SIZE
alignb 8
rt_workers:     resb RT_WORKERS * RW_SIZE
rt_stop:        resb 1
