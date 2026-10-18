; =============================================================================
;  lxsig.asm - a Linux process's threads, futexes and signals
;
;  clone with CLONE_VM | CLONE_THREAD | CLONE_SIGHAND makes another thread
;  of the process: a TF_LINUX thread of the same task that starts from a
;  copy of its parent's frame, with RAX 0, the stack and FS base it was
;  given. Every Linux thread starts that way, from a frame (lx_thread_new,
;  the first one's made by lx_spawn), so whenever one goes back to ring 3
;  RBP is its frame, and lx_leave can deliver a signal there.
;
;  Futexes: a waiter is keyed by where the direct map has the word (so
;  private and shared futexes, and processes sharing a page, agree), in one
;  of LX_FUTEX_BUCKETS lists, and waits on a queue of its own
;  (wq_wait_fn), woken one by one; REQUEUE moves waiters between words.
;
;  Signals: a process has its actions (LP_SIGACTS) and the signals pending
;  for it (LP_SIGPEND); a thread its mask, its own pending signals and its
;  alternate stack. A signal sent is set pending, and the threads that may
;  take it are kicked (woken if parked, interrupted if running elsewhere).
;  On its way back to ring 3 (user_leave, then lx_leave) a thread takes
;  the lowest signal its mask lets through: the default action (the
;  process ends, or nothing), or a frame on its stack as Linux builds one
;  (siginfo, ucontext, the XSAVE state), the handler entered with the
;  restorer as its return address; rt_sigreturn puts it all back. A wait in
;  a system call ends early for a signal (user_killed says so): -EINTR, or,
;  for the calls Linux restarts (-ERESTARTSYS), made again when no handler
;  runs or the handler has SA_RESTART. A fault the process has a handler
;  for is delivered the same way, with its address.
; =============================================================================

CLONE_VM        equ 0x00000100
CLONE_SIGHAND   equ 0x00000800
CLONE_THREAD    equ 0x00010000
CLONE_SETTLS    equ 0x00080000
CLONE_PARENT_SETTID equ 0x00100000
CLONE_CHILD_CLEARTID equ 0x00200000
CLONE_CHILD_SETTID equ 0x01000000

FUTEX_WAIT      equ 0
FUTEX_WAKE      equ 1
FUTEX_REQUEUE   equ 3
FUTEX_CMP_REQUEUE equ 4
FUTEX_WAKE_OP   equ 5
FUTEX_WAIT_BITSET equ 9
FUTEX_WAKE_BITSET equ 10
FUTEX_CMD       equ 0x7F                ; less FUTEX_PRIVATE_FLAG, FUTEX_CLOCK_REALTIME
FUTEX_CLOCK_REALTIME equ 256
LX_FUTEX_BUCKETS equ 256

; a futex's waiter, on its thread's stack
FW_NEXT         equ 0
FW_KEY          equ 8                   ; where the direct map has the word
FW_BITSET       equ 16                  ; dword
FW_WOKEN        equ 20                  ; dword: 1 once a wake took it
FW_BUCKET       equ 24                  ; the bucket it is in (REQUEUE moves it)
FW_WQ           equ 32                  ; WQ_SIZE: it waits here
FW_SIZE         equ 48

FB_LOCK         equ 0                   ; dword
FB_HEAD         equ 8
FB_SIZE         equ 16

; signals
SIGHUP          equ 1
SIGABRT         equ 6
SIGUSR1         equ 10
SIGPIPE         equ 13
SIGALRM         equ 14
SIGTERM         equ 15
SIGCHLD         equ 17
SIGSTOP         equ 19
SIG_DFL         equ 0
SIG_IGN         equ 1
SA_SIGINFO      equ 0x00000004
SA_RESTORER     equ 0x04000000
SA_ONSTACK      equ 0x08000000
SA_RESTART      equ 0x10000000
SA_NODEFER      equ 0x40000000
SA_RESETHAND    equ 0x80000000
LSA_HANDLER     equ 0                   ; a process's action for a signal
LSA_FLAGS       equ 8
LSA_RESTORER    equ 16
LSA_MASK        equ 24
LSA_SIZE        equ 32
LX_NSIG         equ 64
SS_ONSTACK      equ 1
SS_DISABLE      equ 2
SS_AUTODISARM   equ 0x80000000
LX_MINSIGSTKSZ  equ 2048
SI_USER         equ 0
SI_KERNEL       equ 0x80
SI_TKILL        equ -6
LX_SIG_FIXED    equ (1 << (SIGKILL - 1)) | (1 << (SIGSTOP - 1))   ; never blocked
LX_SIG_IGNORED  equ 0x087F0000          ; ignored by default: CHLD, CONT, STOP,
                                        ; TSTP, TTIN, TTOU, URG, WINCH
ERESTARTSYS     equ 512                 ; (the kernel's own: never seen in ring 3)

; TH_LXFL
LXF_RESTART     equ 1                   ; a call was cut short: made again if no handler stops that
LXF_NOSIG       equ 2                   ; a wait that signals do not cut short
LXF_SUSPEND     equ 4                   ; rt_sigsuspend's mask: TH_SAVEMASK is the real one

; TH_LXINFO: a fault, for its signal's siginfo and sigcontext
LI_SIGNO        equ 0                   ; dword
LI_CODE         equ 4                   ; dword
LI_ADDR         equ 8
LI_TRAPNO       equ 16
LI_ERR          equ 24

; the frame a handler runs on (rt_sigframe), and ucontext and sigcontext
UC_FLAGS        equ 0
UC_LINK         equ 8
UC_STACK        equ 16                  ; stack_t: sp, flags, size
UC_MCONTEXT     equ 40                  ; sigcontext
UC_SIGMASK      equ 296
UC_SIZE         equ 304
RSF_PRETCODE     equ 0
RSF_UC           equ 8
RSF_INFO         equ RSF_UC + UC_SIZE
RSF_SIZE         equ RSF_INFO + 128
SC_RAX          equ 104
SC_RSP          equ 120
SC_RIP          equ 128
SC_EFLAGS       equ 136
SC_CSGSFS       equ 144
SC_ERR          equ 152
SC_TRAPNO       equ 160
SC_OLDMASK      equ 168
SC_CR2          equ 176
SC_FPSTATE      equ 184
SC_REGS         equ 18                  ; r8 .. rip, eflags: from the frame
UC_FP_XSTATE    equ 1
UC_SIGCONTEXT_SS equ 2
UC_STRICT_RESTORE_SS equ 4
FP_XSTATE_MAGIC1 equ 0x46505853
FP_XSTATE_MAGIC2 equ 0x46505845
FP_SW_BYTES     equ 464                 ; in the FXSAVE area: magic1, sizes
LX_FIX_EFLAGS   equ 0x50DD5             ; the flags a handler's frame may change
EFL_TF          equ 0x100
EFL_DF          equ 0x400
EFL_RF          equ 0x10000
LX_FR_SIZE      equ FR_SS + 8
LX_FP_ROOM      equ 4096                ; the XSAVE area, at most, and its magic

section .text

; -----------------------------------------------------------------------------
;  Threads
; -----------------------------------------------------------------------------

; lx_thread_new(RDI = task, RSI = a frame, LX_FR_SIZE bytes from kmalloc,
; which it takes) -> RAX = a TF_LINUX thread of that task, not started, that
; goes to ring 3 as the frame says, with its own reference and the caller's;
; 0 if out of memory
lx_thread_new:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    lea rdi, [lx_thread_begin]
    mov rsi, r13
    lea rdx, [r12 + OB_NAME]
    call thread_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    or qword [rbx + TH_FLAGS], TF_USER | TF_LINUX
    mov rax, [r12 + TK_AS]
    mov rax, [rax + AS_CR3]
    mov [rbx + TH_CR3], rax
    mov rdi, rbx
    mov rsi, r12
    call thread_set_task
    mov rax, rbx
    jmp .out
.nomem:
    mov rdi, r13
    call kfree
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_thread_begin(RDI = its frame, from lx_thread_new): a Linux thread's
; first instructions, its kernel entry
lx_thread_begin:
    sub rsp, LX_FR_SIZE
    mov rsi, rdi
    mov rdi, rsp
    mov ecx, LX_FR_SIZE / 8
    rep movsq
    lea rdi, [rsi - LX_FR_SIZE]
    call kfree
    mov rbp, rsp
    jmp lx_return

; lx_first_frame(RDI = entry, RSI = stack pointer) -> RAX = a frame for a
; process's first thread (lx_thread_new's), or 0 if out of memory
lx_first_frame:
    push rdi
    push rsi
    mov edi, LX_FR_SIZE
    call kmalloc
    pop rsi
    pop rdi
    test rax, rax
    jz .out
    mov [rax + FR_RIP], rdi
    mov [rax + FR_RSP], rsi
    mov qword [rax + FR_CS], SEL_UCODE
    mov qword [rax + FR_SS], SEL_UDATA
    mov qword [rax + FR_RFLAGS], USER_RFLAGS
.out:
    ret

; clone(flags, stack, parent_tid, child_tid, tls): a thread of this process
; (CLONE_VM | CLONE_THREAD | CLONE_SIGHAND); new processes come with L4
lx_sys_clone:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16                         ; [rsp] = its frame, [+8] = its id
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov eax, ebx
    and eax, CLONE_VM | CLONE_THREAD | CLONE_SIGHAND
    cmp eax, CLONE_VM | CLONE_THREAD | CLONE_SIGHAND
    mov rax, -ENOSYS
    jne .out
    mov rax, -EPERM
    test ebx, CLONE_SETTLS
    jz .tls_ok
    mov rcx, USER_TOP
    cmp r15, rcx
    jae .out
.tls_ok:
    mov edi, LX_FR_SIZE                 ; its frame: ours, but RAX 0 and its stack
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rsp], rax
    mov rdi, rax
    mov rsi, rbp
    mov ecx, LX_FR_SIZE / 8
    rep movsq
    mov qword [rax + FR_RAX], 0
    test r12, r12
    jz .same_stack
    mov [rax + FR_RSP], r12
.same_stack:
    mov eax, 1
    lock xadd [lx_next_pid], eax
    add eax, LX_PID_FIRST
    mov [rsp + 8], eax
    call cur_task
    mov rdi, rax
    mov rsi, [rsp]
    call lx_thread_new
    test rax, rax
    jz .nomem
    mov rdi, rax                        ; RDI = the thread, RSI = this one
    mov rsi, [gs:PC_CURRENT]
    mov eax, [rsp + 8]
    mov [rdi + TH_TID], eax
    mov rax, [rsi + TH_FSBASE]
    test ebx, CLONE_SETTLS
    cmovnz rax, r15
    mov [rdi + TH_FSBASE], rax
    mov rax, [rsi + TH_GSBASE]
    mov [rdi + TH_GSBASE], rax
    mov rax, [rsi + TH_SIGMASK]
    mov [rdi + TH_SIGMASK], rax
    xor eax, eax
    test ebx, CLONE_CHILD_CLEARTID
    cmovnz rax, r14
    mov [rdi + TH_CTID], rax
    mov [rsp], rdi
    test ebx, CLONE_PARENT_SETTID
    jz .no_ptid
    mov rdi, r13
    mov esi, [rsp + 8]
    call lx_put32
.no_ptid:
    test ebx, CLONE_CHILD_SETTID
    jz .no_ctid
    mov rdi, r14
    mov esi, [rsp + 8]
    call lx_put32
.no_ctid:
    call lx_cur_proc
    lock inc dword [rax + LP_LIVE]
    mov rdi, [rsp]
    call thread_start
    mov rdi, [rsp]
    call thread_put
    mov eax, [rsp + 8]
    jmp .out
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

; lx_clear_tid: as a thread exits, its CLONE_CHILD_CLEARTID word (or
; set_tid_address's) is zeroed and one waiter there woken (pthread_join)
lx_clear_tid:
    push rbx
    mov rax, [gs:PC_CURRENT]
    xor ebx, ebx
    xchg rbx, [rax + TH_CTID]
    test rbx, rbx
    jz .out
    mov rdi, rbx
    xor esi, esi
    call lx_put32
    test rax, rax
    jnz .out
    mov rdi, rbx
    mov esi, 1
    mov edx, -1
    call lx_futex_wake
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Futexes
; -----------------------------------------------------------------------------

; lx_futex_key(RDI = address space, AS_MMLOCK held, RSI = user address) ->
; RAX = where the direct map has the word (written to it first if it may
; be, so a copy on write happens now, not between a wait and its wake), or
; 0. Preserves others.
lx_futex_key:
    push rdx
    mov edx, LXA_WRITE
    call lx_ptr
    test rax, rax
    jnz .out
    xor edx, edx
    call lx_ptr
.out:
    pop rdx
    ret

; lx_futex_bucket(RAX = a key) -> RDX = its bucket. Preserves others.
lx_futex_bucket:
    mov rdx, rax
    shr rdx, 2
    imul rdx, rdx, 0x61C88647
    shr edx, 24                         ; (8 bits: LX_FUTEX_BUCKETS)
    shl edx, 4                          ; * FB_SIZE
    push rax
    lea rax, [lx_futex_buckets]
    add rdx, rax
    pop rax
    ret

; lx_fb_lock(RDI = a bucket) / lx_fb_unlock(RDI): its lock, with interrupts
; off until it is let go (the caller pushes and pops the flags)
lx_fb_lock:
    push rdi
    lea rdi, [rdi + FB_LOCK]
    call spin_lock
    pop rdi
    ret

lx_fb_unlock:
    push rdi
    lea rdi, [rdi + FB_LOCK]
    call spin_unlock
    pop rdi
    ret

; lx_fw_test(RDI = a waiter) -> EAX = 1 once woken (wq_wait_fn's test)
lx_fw_test:
    mov eax, [rdi + FW_WOKEN]
    ret

; lx_fw_off(RDI = a waiter) -> EAX = 1 if a wake took it, else 0: off its
; bucket either way
lx_fw_off:
    push rcx
    push rdx
    push rsi
.again:
    mov rsi, [rdi + FW_BUCKET]
    pushfq
    cli
    push rdi
    mov rdi, rsi
    call lx_fb_lock
    pop rdi
    cmp rsi, [rdi + FW_BUCKET]          ; moved by a requeue meanwhile
    je .locked
    push rdi
    mov rdi, rsi
    call lx_fb_unlock
    pop rdi
    popfq
    jmp .again
.locked:
    mov eax, 1
    cmp dword [rdi + FW_WOKEN], 0
    jne .unlock
    lea rcx, [rsi + FB_HEAD]
.find:
    mov rdx, [rcx]
    test rdx, rdx
    jz .gone
    cmp rdx, rdi
    je .unlink
    lea rcx, [rdx + FW_NEXT]
    jmp .find
.unlink:
    mov rdx, [rdx + FW_NEXT]
    mov [rcx], rdx
.gone:
    xor eax, eax
.unlock:
    push rdi
    mov rdi, rsi
    call lx_fb_unlock
    pop rdi
    popfq
    pop rsi
    pop rdx
    pop rcx
    ret

; lx_futex_wait(RDI = user address, ESI = the value it must hold, RDX = TSC
; deadline or 0, ECX = bitset) -> RAX = 0 once woken, -EAGAIN if it held
; another value, -ETIMEDOUT, -ERESTARTSYS / -EINTR (a signal, with no / a
; deadline), -EFAULT, -EINVAL
lx_futex_wait:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, FW_SIZE
    mov r12, rdi
    mov r13d, esi
    mov r14, rdx
    mov rax, -EINVAL
    test ecx, ecx
    jz .out
    test r12d, 3
    jnz .out
    mov rdi, rsp                        ; the waiter
    xor eax, eax
    push rcx
    mov ecx, FW_SIZE / 8
    rep stosq
    pop rcx
    mov [rsp + FW_BITSET], ecx
    call lx_cur_as
    mov rbx, rax
    mov rdi, rbx
    call mm_lock
    mov rsi, r12
    call lx_futex_key
    test rax, rax
    jz .fault
    mov r15, rax
    mov [rsp + FW_KEY], rax
    call lx_futex_bucket
    mov [rsp + FW_BUCKET], rdx
    pushfq
    cli
    mov rdi, rdx
    call lx_fb_lock
    cmp [r15], r13d
    jne .other
    mov rax, [rdx + FB_HEAD]
    mov [rsp + 8 + FW_NEXT], rax        ; (past the flags)
    lea rax, [rsp + 8]
    mov [rdx + FB_HEAD], rax
    call lx_fb_unlock
    popfq
    mov rdi, rbx
    call mm_unlock
    lea rdi, [rsp + FW_WQ]
    lea rsi, [lx_fw_test]
    mov rdx, rsp
    mov rcx, r14
    call wq_wait_fn
    mov rdi, rsp
    call lx_fw_off
    test eax, eax
    jnz .woken
    call user_killed                    ; a signal, or the deadline?
    test eax, eax
    jnz .interrupted
    mov rax, -ETIMEDOUT
    jmp .out
.interrupted:
    mov rax, -ERESTARTSYS
    test r14, r14
    jz .out
    mov rax, -EINTR
    jmp .out
.woken:
    xor eax, eax
    jmp .out
.other:
    call lx_fb_unlock
    popfq
    mov rdi, rbx
    call mm_unlock
    mov rax, -EAGAIN
    jmp .out
.fault:
    mov rdi, rbx
    call mm_unlock
    mov rax, -EFAULT
.out:
    add rsp, FW_SIZE
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_fb_wake(RDI = a bucket, locked, RSI = key, EDX = bitset, ECX = at
; most) -> EAX = waiters woken: those of that key first on the list
lx_fb_wake:
    push rbx
    push r8
    push r9
    xor eax, eax
    lea r8, [rdi + FB_HEAD]
.next:
    cmp eax, ecx
    jae .out
    mov r9, [r8]
    test r9, r9
    jz .out
    cmp [r9 + FW_KEY], rsi
    jne .skip
    test [r9 + FW_BITSET], edx
    jz .skip
    mov rbx, [r9 + FW_NEXT]             ; off the list, woken
    mov [r8], rbx
    mov dword [r9 + FW_WOKEN], 1
    push rdi
    lea rdi, [r9 + FW_WQ]
    call wq_wake
    pop rdi
    inc eax
    jmp .next
.skip:
    lea r8, [r9 + FW_NEXT]
    jmp .next
.out:
    pop r9
    pop r8
    pop rbx
    ret

; lx_futex_wake(RDI = user address, ESI = at most, EDX = bitset) -> RAX =
; waiters woken, or -errno
lx_futex_wake:
    push rbx
    push r12
    push r13
    mov rax, -EINVAL
    test edx, edx
    jz .out
    test edi, 3
    jnz .out
    mov r12d, esi
    mov r13d, edx
    push rdi
    call lx_cur_as
    mov rbx, rax
    pop rsi
    mov rdi, rbx
    call mm_lock
    call lx_futex_key
    call mm_unlock
    test rax, rax
    jz .fault
    mov rsi, rax
    call lx_futex_bucket
    mov rdi, rdx
    mov edx, r13d
    mov ecx, r12d
    test ecx, ecx                       ; (an int: at most INT_MAX)
    jns .count
    xor ecx, ecx
.count:
    pushfq
    cli
    call lx_fb_lock
    call lx_fb_wake
    call lx_fb_unlock
    popfq
    jmp .out
.fault:
    mov rax, -EFAULT
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_futex_requeue(RDI = address, ESI = to wake, EDX = to move, RCX = the
; address they move to, R8d = 1 to compare first, R9d = with) -> RAX =
; waiters woken and moved, or -errno
lx_futex_requeue:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = key 1, [+8] = key 2, [+16]
    mov r12d, esi                       ; = bucket 1, [+24] = bucket 2
    mov r13d, edx
    mov r14d, r8d
    mov r15d, r9d
    mov rbp, rcx
    mov rax, -EINVAL
    test r12d, r12d
    js .out
    test r13d, r13d
    js .out
    test edi, 3
    jnz .out
    test ebp, 3
    jnz .out
    push rdi
    call lx_cur_as
    mov rbx, rax
    pop rsi
    mov rdi, rbx
    call mm_lock
    call lx_futex_key
    test rax, rax
    jz .fault
    mov [rsp], rax
    call lx_futex_bucket
    mov [rsp + 16], rdx
    mov rsi, rbp
    call lx_futex_key
    test rax, rax
    jz .fault
    mov [rsp + 8], rax
    call lx_futex_bucket
    mov [rsp + 24], rdx
    pushfq
    cli
    mov rdi, [rsp + 8 + 16]             ; both buckets, the lower first
    mov rsi, [rsp + 8 + 24]
    cmp rdi, rsi
    jbe .order
    xchg rdi, rsi
.order:
    call lx_fb_lock
    cmp rdi, rsi
    je .locked
    mov rdi, rsi
    call lx_fb_lock
.locked:
    test r14d, r14d
    jz .compared
    mov rax, [rsp + 8]
    cmp [rax], r15d
    jne .other
.compared:
    mov rdi, [rsp + 8 + 16]
    mov rsi, [rsp + 8]
    mov edx, -1
    mov ecx, r12d
    call lx_fb_wake
    mov r12d, eax                       ; R12 = woken, then moved too
    lea r8, [rdi + FB_HEAD]             ; up to R13 more move to word 2
.move:
    test r13d, r13d
    jz .done
    mov r9, [r8]
    test r9, r9
    jz .done
    mov rax, [rsp + 8]
    cmp [r9 + FW_KEY], rax
    jne .move_skip
    mov rax, [r9 + FW_NEXT]             ; off bucket 1
    mov [r8], rax
    mov rax, [rsp + 8 + 8]
    mov [r9 + FW_KEY], rax
    mov rax, [rsp + 8 + 24]             ; onto bucket 2
    mov [r9 + FW_BUCKET], rax
    mov rcx, [rax + FB_HEAD]
    mov [r9 + FW_NEXT], rcx
    mov [rax + FB_HEAD], r9
    inc r12d
    dec r13d
    jmp .move
.move_skip:
    lea r8, [r9 + FW_NEXT]
    jmp .move
.done:
    mov eax, r12d
    jmp .unlock
.other:
    mov rax, -EAGAIN
.unlock:
    mov rdi, [rsp + 8 + 16]
    call lx_fb_unlock
    cmp rdi, [rsp + 8 + 24]
    je .unlocked
    mov rdi, [rsp + 8 + 24]
    call lx_fb_unlock
.unlocked:
    popfq
    mov rdi, rbx
    call mm_unlock
    jmp .out
.fault:
    mov rdi, rbx
    call mm_unlock
    mov rax, -EFAULT
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_futex_wake_op(RDI = address 1, ESI = to wake there, EDX = to wake at
; address 2 if the test passes, RCX = address 2, R8d = the operation) ->
; RAX = woken, or -errno: word 2 changed by the operation, atomically, and
; the test made of what it held
lx_futex_wake_op:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32                         ; [rsp] = key 1, [+8] = key 2 (the word)
    mov r12d, esi
    mov r13d, edx
    mov r14d, r8d
    mov rbp, rcx
    mov rax, -EINVAL
    test edi, 3
    jnz .out
    test ebp, 3
    jnz .out
    push rdi
    call lx_cur_as
    mov rbx, rax
    pop rsi
    mov rdi, rbx
    call mm_lock
    call lx_futex_key
    test rax, rax
    jz .fault
    mov [rsp], rax
    mov rsi, rbp
    mov edx, LXA_WRITE
    call lx_ptr
    test rax, rax
    jz .fault
    mov [rsp + 8], rax
    mov ecx, r14d                       ; the operand: 12 bits, signed
    shl ecx, 8
    sar ecx, 20
    test r14d, 1 << 31                  ; FUTEX_OP_OPARG_SHIFT
    jz .operand
    and ecx, 31
    mov edx, 1
    shl edx, cl
    mov ecx, edx
.operand:
    mov r15d, ecx                       ; R15 = the operand
    mov rdi, [rsp + 8]
    mov eax, [rdi]
.atomic:
    mov edx, eax
    mov ecx, r14d
    shr ecx, 28
    and ecx, 7
    cmp ecx, 0                          ; SET
    jne .add
    mov edx, r15d
    jmp .apply
.add:
    cmp ecx, 1
    jne .or
    add edx, r15d
    jmp .apply
.or:
    cmp ecx, 2
    jne .andn
    or edx, r15d
    jmp .apply
.andn:
    cmp ecx, 3
    jne .xor
    mov ecx, r15d
    not ecx
    and edx, ecx
    jmp .apply
.xor:
    cmp ecx, 4
    jne .bad_op
    xor edx, r15d
.apply:
    lock cmpxchg [rdi], edx
    jnz .atomic                         ; (EAX = what it holds now)
    mov ecx, r14d                       ; the test: old against 12 bits
    shl ecx, 20
    sar ecx, 20
    mov edx, r14d
    shr edx, 24
    and edx, 15
    xor r15d, r15d                      ; R15 = 1 if it passes
    cmp edx, 0
    jne .ne
    cmp eax, ecx
    sete r15b
    jmp .tested
.ne:
    cmp edx, 1
    jne .lt
    cmp eax, ecx
    setne r15b
    jmp .tested
.lt:
    cmp edx, 2
    jne .le
    cmp eax, ecx
    setl r15b
    jmp .tested
.le:
    cmp edx, 3
    jne .gt
    cmp eax, ecx
    setle r15b
    jmp .tested
.gt:
    cmp edx, 4
    jne .ge
    cmp eax, ecx
    setg r15b
    jmp .tested
.ge:
    cmp edx, 5
    jne .bad_op
    cmp eax, ecx
    setge r15b
.tested:
    mov rdi, rbx
    call mm_unlock
    mov rax, [rsp]
    call lx_futex_bucket
    mov rdi, rdx
    mov rsi, [rsp]
    mov edx, -1
    mov ecx, r12d
    pushfq
    cli
    call lx_fb_lock
    call lx_fb_wake
    call lx_fb_unlock
    popfq
    mov r12d, eax
    test r15d, r15d
    jz .woken
    mov rax, [rsp + 8]
    call lx_futex_bucket
    mov rdi, rdx
    mov rsi, [rsp + 8]
    mov edx, -1
    mov ecx, r13d
    pushfq
    cli
    call lx_fb_lock
    call lx_fb_wake
    call lx_fb_unlock
    popfq
    add r12d, eax
.woken:
    mov eax, r12d
    jmp .out
.bad_op:
    mov rdi, rbx
    call mm_unlock
    mov rax, -ENOSYS
    jmp .out
.fault:
    mov rdi, rbx
    call mm_unlock
    mov rax, -EFAULT
.out:
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_deadline(RDI = a user timespec or 0, ESI = 1 if absolute, EDX = its
; clock (0 realtime, else monotonic)) -> RAX = a TSC deadline (0: none), or
; -errno
lx_deadline:
    xor eax, eax
    test rdi, rdi
    jz .out
    push rsi
    push rdx
    call lx_ts_in
    pop rdx
    pop rsi
    cmp rax, -4095
    jae .out
    test esi, esi
    jz .relative
    mov rcx, rax                        ; absolute: less now, on its clock
    call lx_now_ns
    test edx, edx
    jnz .mono
    add rax, [lx_epoch_ns]
.mono:
    sub rcx, rax
    mov eax, 0
    cmovg rax, rcx
.relative:
    call lx_ns_tsc
.out:
    ret

; futex(uaddr, op, val, timeout or val2, uaddr2, val3)
lx_sys_futex:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12d, esi
    mov r13d, edx
    mov r14, rcx
    mov r15, r8
    mov eax, r12d
    and eax, FUTEX_CMD
    cmp eax, FUTEX_WAIT
    je .wait
    cmp eax, FUTEX_WAIT_BITSET
    je .wait_bitset
    cmp eax, FUTEX_WAKE
    je .wake
    cmp eax, FUTEX_WAKE_BITSET
    je .wake_bitset
    cmp eax, FUTEX_REQUEUE
    je .requeue
    cmp eax, FUTEX_CMP_REQUEUE
    je .cmp_requeue
    cmp eax, FUTEX_WAKE_OP
    je .wake_op
    mov rax, -ENOSYS                    ; the PI ones
    jmp .out
.wait:
    mov r9d, -1
    mov rdi, r14
    xor esi, esi
    mov edx, 1
    jmp .waits
.wait_bitset:
    mov rdi, r14
    mov esi, 1
    xor edx, edx
    test r12d, FUTEX_CLOCK_REALTIME
    jnz .waits
    inc edx
.waits:
    push r9
    call lx_deadline
    pop rcx
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov esi, r13d
    mov rdx, rax
    call lx_futex_wait
    jmp .out
.wake:
    mov r9d, -1
.wake_bitset:
    mov rdi, rbx
    mov esi, r13d
    mov edx, r9d
    call lx_futex_wake
    jmp .out
.requeue:
    xor r8d, r8d
    jmp .requeues
.cmp_requeue:
    mov r8d, 1
.requeues:
    mov rdi, rbx
    mov esi, r13d
    mov edx, r14d
    mov rcx, r15
    call lx_futex_requeue
    jmp .out
.wake_op:
    mov rdi, rbx
    mov esi, r13d
    mov edx, r14d
    mov rcx, r15
    mov r8d, r9d
    call lx_futex_wake_op
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; set_robust_list(head, len): kept by nobody yet
; (lx_sys_zero)

; -----------------------------------------------------------------------------
;  Sending signals
; -----------------------------------------------------------------------------

; lx_sig_ignored(RDI = process, ESI = signal) -> CF if it would be thrown
; away: its action is SIG_IGN, or SIG_DFL and ignoring it. Preserves all.
lx_sig_ignored:
    push rax
    push rcx
    lea ecx, [esi - 1]
    mov eax, ecx
    shl eax, 5
    add rax, [rdi + LP_SIGACTS]
    mov rax, [rax + LSA_HANDLER]
    cmp rax, SIG_IGN
    je .yes
    test rax, rax
    jnz .no
    cmp ecx, 32
    jae .no
    mov eax, LX_SIG_IGNORED
    bt eax, ecx
    jmp .out                            ; (CF as it says)
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop rcx
    pop rax
    ret

; lx_kick(RDI = a thread): it looks at its signals soon: unparked if
; parked, interrupted if running on another CPU. Preserves all.
lx_kick:
    push rax
    push rsi
    push rdi
    call thread_unpark
    cmp dword [rdi + TH_STATE], TS_RUNNING
    jne .out
    mov rax, [rdi + TH_CPU]
    cmp rax, [gs:PC_INDEX]
    je .out
    PERCPU rdi, rax
    mov edi, [rdi + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_RESCHED
    call lapic_send_ipi
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; lx_signal_proc(RDI = process, ESI = signal 1..64): sent to the process,
; one of its threads takes it. Preserves all.
lx_signal_proc:
    push rax
    push rbx
    push rcx
    push rdi
    push r12
    cmp esi, SIGKILL
    je .kill
    call lx_sig_ignored
    jc .out
    lea ecx, [esi - 1]
    lock bts [rdi + LP_SIGPEND], rcx
    mov r12, [rdi + LP_TASK]
    pushfq                              ; each of its threads looks
    cli
    lea rdi, [threads_lock]
    call spin_lock
    mov rbx, [thread_list]
.thread:
    test rbx, rbx
    jz .done
    cmp [rbx + TH_TASK], r12
    jne .next
    test qword [rbx + TH_FLAGS], TF_LINUX
    jz .next
    mov rdi, rbx
    call lx_kick
.next:
    mov rbx, [rbx + OB_NEXT]
    jmp .thread
.done:
    lea rdi, [threads_lock]
    call spin_unlock
    popfq
    jmp .out
.kill:
    mov rax, rdi
    push rdi
    mov edi, SIGKILL
    call lx_set_status
    pop rdi
    mov rdi, [rdi + LP_TASK]
    call task_kill
.out:
    pop r12
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; lx_signal_tid(RDI = process, ESI = thread id, EDX = signal 0..64) -> RAX
; = 0, or -ESRCH: sent to that thread of the process
lx_signal_tid:
    push rbx
    push r12
    push r13
    push r14
    mov r12, [rdi + LP_TASK]
    mov r13d, esi
    mov r14d, edx
    mov rbx, rdi
    test r14d, r14d
    jz .find
    cmp r14d, SIGKILL
    je .kill
    mov esi, r14d
    call lx_sig_ignored
    jc .find                            ; (it must be there, all the same)
.find:
    pushfq
    cli
    lea rdi, [threads_lock]
    call spin_lock
    mov rax, [thread_list]
.thread:
    test rax, rax
    jz .none
    cmp [rax + TH_TASK], r12
    jne .next
    test qword [rax + TH_FLAGS], TF_LINUX
    jz .next
    cmp [rax + TH_TID], r13d
    je .found
.next:
    mov rax, [rax + OB_NEXT]
    jmp .thread
.found:
    test r14d, r14d
    jz .sent
    mov rdi, rbx
    mov esi, r14d
    call lx_sig_ignored
    jc .sent
    lea ecx, [r14d - 1]
    lock bts [rax + TH_SIGPEND], rcx
    mov rdi, rax
    call lx_kick
.sent:
    xor eax, eax
    jmp .unlock
.none:
    mov rax, -ESRCH
.unlock:
    lea rdi, [threads_lock]
    call spin_unlock
    popfq
    jmp .out
.kill:
    mov rdi, rbx
    mov esi, SIGKILL
    call lx_signal_proc
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_interrupt(RDI = a terminal): ctrl+C there. SIGINT to the process run
; there; a second ctrl+C kills it. Preserves RDI.
lx_interrupt:
    mov rax, [lx_session]
    test rax, rax
    jz .out
    cmp rdi, [lx_con]
    jne .out
    push rdi
    cmp byte [lx_ctrl_c], 0
    jne .kill
    mov byte [lx_ctrl_c], 1
    mov rdi, [rax + TK_LX]
    mov esi, SIGINT
    call lx_signal_proc
    pop rdi
    ret
.kill:
    mov rdi, rax
    call task_kill
    pop rdi
.out:
    ret

; kill(pid, sig): this process's own, for now (L4 adds others)
lx_sys_kill:
    mov rax, -EINVAL
    cmp esi, LX_NSIG
    ja .out
    push rsi
    push rdi
    call lx_cur_proc
    pop rdi
    pop rsi
    test edi, edi                       ; 0, -1, our pid or our group's
    jz .ours
    cmp edi, -1
    je .ours
    mov ecx, edi
    neg ecx
    cmp edi, [rax + LP_PID]
    je .ours
    cmp ecx, [rax + LP_PID]
    je .ours
    mov rax, -ESRCH
    ret
.ours:
    test esi, esi
    jz .zero
    mov rdi, rax
    call lx_signal_proc
.zero:
    xor eax, eax
.out:
    ret

; tgkill(tgid, tid, sig)
lx_sys_tgkill:
    mov rax, -EINVAL
    cmp edx, LX_NSIG
    ja .out
    test edi, edi
    jle .out
    push rsi
    push rdx
    push rdi
    call lx_cur_proc
    pop rdi
    pop rdx
    pop rsi
    cmp edi, [rax + LP_PID]
    jne .none
    mov rdi, rax
    jmp lx_signal_tid
.none:
    mov rax, -ESRCH
.out:
    ret

; tkill(tid, sig)
lx_sys_tkill:
    mov rax, -EINVAL
    cmp esi, LX_NSIG
    ja .out
    test edi, edi
    jle .out
    mov edx, esi
    mov esi, edi
    call lx_cur_proc
    mov rdi, rax
    jmp lx_signal_tid
.out:
    ret

; -----------------------------------------------------------------------------
;  Actions, masks, the alternate stack
; -----------------------------------------------------------------------------

; rt_sigaction(sig, act, oact, sigsetsize)
lx_sys_rt_sigaction:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, LSA_SIZE
    mov ebx, edi
    mov r12, rsi
    mov r13, rdx
    mov rax, -EINVAL
    cmp rcx, 8
    jne .out
    lea eax, [ebx - 1]
    cmp eax, LX_NSIG
    mov rax, -EINVAL
    jae .out
    test r12, r12
    jz .no_fixed
    cmp ebx, SIGKILL
    je .out
    cmp ebx, SIGSTOP
    je .out
.no_fixed:
    call lx_cur_proc
    mov r14, rax
    lea eax, [ebx - 1]
    shl eax, 5
    add rax, [r14 + LP_SIGACTS]
    push rax                            ; [rsp] = its action
    test r12, r12
    jz .old
    lea rdi, [rsp + 8]                  ; the new one, here first
    mov rsi, r12
    mov edx, LSA_SIZE
    call lx_copy_in
    cmp rax, -4095
    jae .pop_out
.old:
    test r13, r13
    jz .set
    mov rdi, r13
    mov rsi, [rsp]
    mov edx, LSA_SIZE
    call lx_copy_out
    cmp rax, -4095
    jae .pop_out
.set:
    xor eax, eax
    test r12, r12
    jz .pop_out
    mov rdi, [rsp]
    mov rcx, LX_SIG_FIXED
    not rcx
    and [rsp + 8 + LSA_MASK], rcx
    mov rcx, [rsp + 8 + LSA_FLAGS]
    mov [rdi + LSA_FLAGS], rcx
    mov rcx, [rsp + 8 + LSA_RESTORER]
    mov [rdi + LSA_RESTORER], rcx
    mov rcx, [rsp + 8 + LSA_MASK]
    mov [rdi + LSA_MASK], rcx
    mov rcx, [rsp + 8 + LSA_HANDLER]
    mov [rdi + LSA_HANDLER], rcx
    mov rdi, r14                        ; ignored now: what is pending goes
    mov esi, ebx
    call lx_sig_ignored
    jnc .done
    lea ecx, [ebx - 1]
    lock btr [r14 + LP_SIGPEND], rcx
    mov rax, [gs:PC_CURRENT]
    lock btr [rax + TH_SIGPEND], rcx
.done:
    xor eax, eax
.pop_out:
    add rsp, 8
.out:
    add rsp, LSA_SIZE
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rt_sigprocmask(how, set, oset, sigsetsize)
lx_sys_rt_sigprocmask:
    push rbx
    push r12
    mov ebx, edi
    mov r12, rsi
    mov rax, -EINVAL
    cmp rcx, 8
    jne .out
    test rdx, rdx
    jz .set
    mov rdi, rdx
    mov rsi, [gs:PC_CURRENT]
    mov rsi, [rsi + TH_SIGMASK]
    call lx_put64
    test rax, rax
    jnz .out
.set:
    xor eax, eax
    test r12, r12
    jz .out
    mov rdi, r12
    call lx_get64
    test rax, rax
    jnz .out
    mov r8, [gs:PC_CURRENT]
    mov rcx, LX_SIG_FIXED
    not rcx
    and rdx, rcx
    cmp ebx, 0                          ; SIG_BLOCK
    je .block
    cmp ebx, 1                          ; SIG_UNBLOCK
    je .unblock
    cmp ebx, 2                          ; SIG_SETMASK
    mov rax, -EINVAL
    jne .out
    mov [r8 + TH_SIGMASK], rdx
    xor eax, eax
    jmp .out
.block:
    or [r8 + TH_SIGMASK], rdx
    jmp .out
.unblock:
    not rdx
    and [r8 + TH_SIGMASK], rdx
.out:
    pop r12
    pop rbx
    ret

; rt_sigpending(set, sigsetsize)
lx_sys_rt_sigpending:
    mov rax, -EINVAL
    cmp rsi, 8
    jne .out
    call lx_cur_proc
    mov rsi, [rax + LP_SIGPEND]
    mov rax, [gs:PC_CURRENT]
    or rsi, [rax + TH_SIGPEND]
    and rsi, [rax + TH_SIGMASK]
    jmp lx_put64
.out:
    ret

; rt_sigsuspend(mask, sigsetsize): that mask until a signal is taken
lx_sys_rt_sigsuspend:
    mov rax, -EINVAL
    cmp rsi, 8
    jne .out
    call lx_get64
    test rax, rax
    jnz .out
    mov rcx, LX_SIG_FIXED
    not rcx
    and rdx, rcx
    mov rax, [gs:PC_CURRENT]
    mov rcx, [rax + TH_SIGMASK]
    mov [rax + TH_SAVEMASK], rcx
    mov [rax + TH_SIGMASK], rdx
    or dword [rax + TH_LXFL], LXF_SUSPEND
    jmp lx_sys_pause
.out:
    ret

; pause(): until a signal is taken
lx_sys_pause:
.again:
    lea rdi, [lx_sleep_wq]
    lea rsi, [lx_never]
    xor edx, edx
    call wq_wait
    call user_killed
    test eax, eax
    jz .again
    mov rax, -EINTR
    ret

; sigaltstack(ss, oss)
lx_sys_sigaltstack:
    push rbx
    push r12
    sub rsp, 24
    mov r12, rdi
    mov rbx, [gs:PC_CURRENT]
    xor ecx, ecx                        ; ECX = 1 while on it
    mov rax, [rbp + FR_RSP]
    sub rax, [rbx + TH_ALTSP]
    cmp rax, [rbx + TH_ALTSIZE]
    jae .where
    mov ecx, 1
.where:
    test rsi, rsi
    jz .new
    mov rax, [rbx + TH_ALTSP]
    mov [rsp], rax
    mov eax, SS_DISABLE
    cmp qword [rbx + TH_ALTSIZE], 0
    je .flags
    mov eax, ecx                        ; SS_ONSTACK, or 0
.flags:
    mov [rsp + 8], rax
    mov rax, [rbx + TH_ALTSIZE]
    mov [rsp + 16], rax
    push rcx
    mov rdi, rsi
    lea rsi, [rsp + 8]
    mov edx, 24
    call lx_copy_out
    pop rcx
    test rax, rax
    jnz .out
.new:
    xor eax, eax
    test r12, r12
    jz .out
    mov rax, -EPERM
    test ecx, ecx
    jnz .out
    mov rdi, rsp
    mov rsi, r12
    mov edx, 24
    call lx_copy_in
    test rax, rax
    jnz .out
    mov eax, [rsp + 8]
    test eax, SS_DISABLE
    jnz .disable
    test eax, ~(SS_ONSTACK | SS_AUTODISARM)
    mov rax, -EINVAL
    jnz .out
    mov rax, -ENOMEM
    cmp qword [rsp + 16], LX_MINSIGSTKSZ
    jb .out
    mov rax, [rsp]
    mov [rbx + TH_ALTSP], rax
    mov rax, [rsp + 16]
    mov [rbx + TH_ALTSIZE], rax
    xor eax, eax
    jmp .out
.disable:
    mov qword [rbx + TH_ALTSP], 0
    mov qword [rbx + TH_ALTSIZE], 0
    xor eax, eax
.out:
    add rsp, 24
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Delivering signals
; -----------------------------------------------------------------------------

; lx_interrupted -> EAX = 1 if the running Linux thread's wait should end:
; its task is being killed, or (unless LXF_NOSIG) a signal its mask lets
; through is pending. From user_killed. Preserves others.
lx_interrupted:
    push rcx
    push rdx
    mov rcx, [gs:PC_CURRENT]
    mov rax, [rcx + TH_TASK]
    test byte [rax + TK_KILL], 1
    jnz .yes
    test dword [rcx + TH_LXFL], LXF_NOSIG
    jnz .no
    mov rax, [rax + TK_LX]
    mov rdx, [rax + LP_SIGPEND]
    or rdx, [rcx + TH_SIGPEND]
    mov rax, [rcx + TH_SIGMASK]
    not rax
    test rdx, rax
    jnz .yes
.no:
    xor eax, eax
    jmp .out
.yes:
    mov eax, 1
.out:
    pop rdx
    pop rcx
    ret

; lx_leave: from user_leave, interrupts off, for a Linux thread: RBP is the
; frame going back to ring 3. Its signals delivered, a call cut short made
; again. Preserves all.
lx_leave:
    push rax
    push rcx
    push rdx
    mov rcx, [gs:PC_CURRENT]
    test dword [rcx + TH_LXFL], LXF_RESTART | LXF_SUSPEND
    jnz .work
    mov rax, [rcx + TH_TASK]
    mov rax, [rax + TK_LX]
    mov rdx, [rax + LP_SIGPEND]
    or rdx, [rcx + TH_SIGPEND]
    mov rax, [rcx + TH_SIGMASK]
    not rax
    test rdx, rax
    jnz .work
    pop rdx
    pop rcx
    pop rax
    ret
.work:
    push rbx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    sti
    call lx_signals
    cli
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    pop rdx
    pop rcx
    pop rax
    jmp user_leave                      ; killed meanwhile, or more to take?

; lx_signals: interrupts on, RBP = the frame: one signal taken (and a
; handler's frame built), or a call cut short made again
lx_signals:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, [gs:PC_CURRENT]
    mov r12, [rbx + TH_TASK]
    mov r12, [r12 + TK_LX]
.next:
    mov rax, [rbx + TH_SIGMASK]         ; the lowest it lets through
    not rax
    mov rcx, [rbx + TH_SIGPEND]
    and rcx, rax
    jz .proc
    bsf rcx, rcx
    lock btr [rbx + TH_SIGPEND], rcx
    jnc .next
    jmp .got
.proc:
    mov rcx, [r12 + LP_SIGPEND]
    and rcx, rax
    jz .none
    bsf rcx, rcx
    lock btr [r12 + LP_SIGPEND], rcx
    jnc .next                           ; another thread took it
.got:
    lea r13d, [ecx + 1]                 ; R13 = the signal
    shl ecx, 5
    mov r14, [r12 + LP_SIGACTS]
    add r14, rcx                        ; R14 = its action
    mov rax, [r14 + LSA_HANDLER]
    cmp rax, SIG_IGN
    je .next
    test rax, rax
    jnz .handler
    mov rdi, r12                        ; the default: nothing,
    mov esi, r13d
    call lx_sig_ignored
    jc .next
    mov rax, r12                        ; or the process ends by it
    mov edi, r13d
    call lx_set_status
    mov rdi, [r12 + LP_TASK]
    call task_kill
    jmp lx_thread_exit
.handler:
    call lx_sig_frame
    jnc .out
    mov rax, r12                        ; no room for its frame: SIGSEGV
    mov edi, SIGSEGV
    call lx_set_status
    mov rdi, [r12 + LP_TASK]
    call task_kill
    jmp lx_thread_exit
.none:
    test dword [rbx + TH_LXFL], LXF_RESTART
    jz .out
    mov rax, [rbp + FR_ERROR]           ; no handler ran: the call, again
    mov [rbp + FR_RAX], rax
    sub qword [rbp + FR_RIP], 2
.out:
    test dword [rbx + TH_LXFL], LXF_SUSPEND
    jz .cleared
    mov rax, [rbx + TH_SAVEMASK]        ; (no handler ran for rt_sigsuspend)
    mov [rbx + TH_SIGMASK], rax
.cleared:
    and dword [rbx + TH_LXFL], ~(LXF_RESTART | LXF_SUSPEND)
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_sig_frame: RBX = this thread, R12 = its process, R13d = the signal,
; R14 = its action (a handler), RBP = the frame -> CF if the frame could
; not be written. The handler's frame on the user stack, the thread's
; frame changed to enter it.
lx_sig_frame:
    push r15
    push rbp
    mov r15, rsp                        ; R15 = where the stack was
    sub rsp, RSF_SIZE + LX_FP_ROOM + 128
    and rsp, -64
    mov r8, rbp                         ; R8 = the thread's frame
    mov rbp, rsp                        ; RBP = the XSAVE area here, then
    lea r9, [rsp + LX_FP_ROOM]          ; R9 = the handler's frame here
    mov rdi, r9
    xor eax, eax
    mov ecx, RSF_SIZE / 8
    rep stosq
    test dword [rbx + TH_LXFL], LXF_RESTART     ; cut short: again, if SA_RESTART
    jz .restarted
    test qword [r14 + LSA_FLAGS], SA_RESTART
    jz .restarted
    mov rax, [r8 + FR_ERROR]
    mov [r8 + FR_RAX], rax
    sub qword [r8 + FR_RIP], 2
.restarted:
    mov rax, [rbx + TH_SIGMASK]         ; the mask to go back to
    test dword [rbx + TH_LXFL], LXF_SUSPEND
    jz .old_mask
    mov rax, [rbx + TH_SAVEMASK]
.old_mask:
    mov [r9 + RSF_UC + UC_SIGMASK], rax
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_OLDMASK], rax
    and dword [rbx + TH_LXFL], ~(LXF_RESTART | LXF_SUSPEND)
    xor edx, edx                        ; RDX = the stack: its own, or the
    mov rax, [r8 + FR_RSP]              ; alternate one
    mov rcx, rax
    sub rcx, [rbx + TH_ALTSP]
    cmp rcx, [rbx + TH_ALTSIZE]
    setb dl                             ; on it already
    mov rcx, rax
    sub rcx, 128                        ; (the red zone)
    test qword [r14 + LSA_FLAGS], SA_ONSTACK
    jz .stack
    cmp qword [rbx + TH_ALTSIZE], 0
    je .stack
    test edx, edx
    jnz .stack
    mov rcx, [rbx + TH_ALTSP]
    add rcx, [rbx + TH_ALTSIZE]
.stack:
    mov rax, [rbx + TH_ALTSP]           ; uc_stack
    mov [r9 + RSF_UC + UC_STACK], rax
    mov eax, SS_DISABLE
    cmp qword [rbx + TH_ALTSIZE], 0
    je .ss_flags
    mov eax, edx
.ss_flags:
    mov [r9 + RSF_UC + UC_STACK + 8], rax
    mov rax, [rbx + TH_ALTSIZE]
    mov [r9 + RSF_UC + UC_STACK + 16], rax
    mov eax, [sched_area]               ; the XSAVE area, 64-aligned, below
    add eax, 4
    sub rcx, rax
    and rcx, -64
    mov r10, rcx                        ; R10 = its address there
    sub rcx, RSF_SIZE                    ; the frame below it, as if called
    and rcx, -16
    sub rcx, 8
    mov r11, rcx                        ; R11 = the frame's address there
    mov rax, [r14 + LSA_RESTORER]       ; filled in: the return address,
    test qword [r14 + LSA_FLAGS], SA_RESTORER
    jz .no_room                         ; (none: nowhere to return to)
    mov [r9 + RSF_PRETCODE], rax
    mov qword [r9 + RSF_UC + UC_FLAGS], UC_FP_XSTATE | UC_SIGCONTEXT_SS | UC_STRICT_RESTORE_SS
    lea rsi, [lx_sc_regs]               ; the registers
    lea rdi, [r9 + RSF_UC + UC_MCONTEXT]
    mov ecx, SC_REGS
.reg:
    movzx eax, byte [rsi]
    mov rax, [r8 + rax]
    stosq
    inc rsi
    dec ecx
    jnz .reg
    mov rax, [r8 + FR_SS]               ; cs, gs, fs, ss
    shl rax, 48
    mov ax, [r8 + FR_CS]
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_CSGSFS], rax
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_FPSTATE], r10
    mov [r9 + RSF_INFO], r13d            ; siginfo: the signal, and
    mov dword [r9 + RSF_INFO + 8], SI_USER
    mov eax, [r12 + LP_PID]             ; who sent it (this process, for now)
    mov [r9 + RSF_INFO + 16], eax
    cmp [rbx + TH_LXINFO + LI_SIGNO], r13d      ; a fault: what and where
    jne .info
    mov eax, [rbx + TH_LXINFO + LI_CODE]
    mov [r9 + RSF_INFO + 8], eax
    mov rax, [rbx + TH_LXINFO + LI_ADDR]
    mov [r9 + RSF_INFO + 16], rax
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_CR2], rax
    mov rax, [rbx + TH_LXINFO + LI_TRAPNO]
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_TRAPNO], rax
    mov rax, [rbx + TH_LXINFO + LI_ERR]
    mov [r9 + RSF_UC + UC_MCONTEXT + SC_ERR], rax
    mov dword [rbx + TH_LXINFO + LI_SIGNO], 0
.info:
    lea rdi, [rbp + 512]                ; (XSAVE leaves its header but XSTATE_BV)
    xor eax, eax
    mov ecx, 8
    rep stosq
    cli                                 ; the SIMD state, as the thread left it
    cmp byte [sched_xsave], 0
    je .fxsave
    mov eax, [cpu_xcr0]
    xor edx, edx
    xsave64 [rbp]
    jmp .saved
.fxsave:
    fxsave64 [rbp]
.saved:
    lea rax, [lx_fp_init]               ; and a clean one for the handler
    cmp byte [sched_xsave], 0
    je .fxinit
    push rax
    mov eax, [cpu_xcr0]
    xor edx, edx
    pop rcx
    xrstor64 [rcx]
    jmp .inited
.fxinit:
    fxrstor64 [rax]
.inited:
    sti
    mov dword [rbp + FP_SW_BYTES], FP_XSTATE_MAGIC1     ; what Linux says of it
    mov eax, [sched_area]
    lea ecx, [eax + 4]
    mov [rbp + FP_SW_BYTES + 4], ecx
    mov ecx, [cpu_xcr0]
    mov [rbp + FP_SW_BYTES + 8], rcx
    mov [rbp + FP_SW_BYTES + 16], eax
    mov dword [rbp + rax], FP_XSTATE_MAGIC2
    push r8
    push r9
    push r10
    push r11
    mov rdi, [rbx + TH_TASK]            ; both, to the program's stack
    mov rdi, [rdi + TK_AS]
    mov rsi, r10
    mov rdx, rbp
    mov ecx, [sched_area]
    add ecx, 4
    mov r8d, LXA_WRITE
    call lx_copy
    mov r11, [rsp]
    mov r9, [rsp + 16]
    test rax, rax
    jnz .copy_failed
    mov rdi, [rbx + TH_TASK]
    mov rdi, [rdi + TK_AS]
    mov rsi, r11
    mov rdx, r9
    mov ecx, RSF_SIZE
    mov r8d, LXA_WRITE
    call lx_copy
.copy_failed:
    pop r11
    pop r10
    pop r9
    pop r8
    test rax, rax
    jnz .no_room
    mov rax, [r14 + LSA_MASK]           ; its mask while it runs
    test qword [r14 + LSA_FLAGS], SA_NODEFER
    jnz .masked
    lea ecx, [r13d - 1]
    bts rax, rcx
.masked:
    or rax, [rbx + TH_SIGMASK]
    mov rcx, LX_SIG_FIXED
    not rcx
    and rax, rcx
    mov [rbx + TH_SIGMASK], rax
    mov rax, [r14 + LSA_HANDLER]        ; the thread's frame: into the handler
    test dword [r14 + LSA_FLAGS], SA_RESETHAND
    jz .kept
    mov qword [r14 + LSA_HANDLER], SIG_DFL
    and qword [r14 + LSA_FLAGS], ~SA_SIGINFO
.kept:
    mov [r8 + FR_RIP], rax
    mov [r8 + FR_RSP], r11
    mov [r8 + FR_RDI], r13
    lea rax, [r11 + RSF_INFO]
    mov [r8 + FR_RSI], rax
    lea rax, [r11 + RSF_UC]
    mov [r8 + FR_RDX], rax
    mov qword [r8 + FR_RAX], 0
    and qword [r8 + FR_RFLAGS], ~(EFL_TF | EFL_DF | EFL_RF)
    mov qword [r8 + FR_CS], SEL_UCODE
    mov qword [r8 + FR_SS], SEL_UDATA
    clc
    jmp .out
.no_room:
    stc
.out:
    mov rsp, r15
    pop rbp
    pop r15
    ret

; rt_sigreturn(): back from a handler, as its frame says
lx_sys_rt_sigreturn:
    push rbx
    push r12
    push r13
    mov r12, rsp
    sub rsp, UC_SIZE + LX_FP_ROOM + 128
    and rsp, -64
    mov rbx, [gs:PC_CURRENT]
    lea r13, [rsp + LX_FP_ROOM]         ; R13 = the ucontext, here
    mov rdi, r13
    mov rsi, [rbp + FR_RSP]             ; (the restorer's RSP: past pretcode)
    mov edx, UC_SIZE
    call lx_copy_in
    test rax, rax
    jnz .bad
    lea rsi, [lx_sc_regs]               ; the registers
    lea rdx, [r13 + UC_MCONTEXT]
    mov ecx, SC_REGS - 1                ; (all but RFLAGS)
.reg:
    movzx eax, byte [rsi]
    mov rdi, [rdx]
    mov [rbp + rax], rdi
    add rdx, 8
    inc rsi
    dec ecx
    jnz .reg
    mov rax, [r13 + UC_MCONTEXT + SC_EFLAGS]    ; the flags it may change
    and rax, LX_FIX_EFLAGS
    mov rcx, [rbp + FR_RFLAGS]
    and rcx, ~LX_FIX_EFLAGS
    or rax, rcx
    mov [rbp + FR_RFLAGS], rax
    mov qword [rbp + FR_CS], SEL_UCODE
    mov qword [rbp + FR_SS], SEL_UDATA
    mov rax, [r13 + UC_SIGMASK]
    mov rcx, LX_SIG_FIXED
    not rcx
    and rax, rcx
    mov [rbx + TH_SIGMASK], rax
    and dword [rbx + TH_LXFL], ~(LXF_RESTART | LXF_SUSPEND)
    mov rsi, [r13 + UC_MCONTEXT + SC_FPSTATE]   ; its SIMD state
    test rsi, rsi
    jz .fp_init
    mov rdi, rsp
    mov edx, [sched_area]
    call lx_copy_in
    test rax, rax
    jnz .bad
    cmp byte [sched_xsave], 0
    je .fx
    mov eax, [cpu_xcr0]                 ; a header XRSTOR takes
    and [rsp + 512], rax
    mov qword [rsp + 520], 0
    lea rdi, [rsp + 528]
    xor eax, eax
    mov ecx, 6
    rep stosq
.fx:
    mov eax, [lx_mxcsr_mask]
    and [rsp + 24], eax
    cli
    cmp byte [sched_xsave], 0
    je .fxrstor
    mov eax, [cpu_xcr0]
    xor edx, edx
    xrstor64 [rsp]
    jmp .restored
.fxrstor:
    fxrstor64 [rsp]
    jmp .restored
.fp_init:
    cli
    lea rcx, [lx_fp_init]
    cmp byte [sched_xsave], 0
    je .fxinit
    mov eax, [cpu_xcr0]
    xor edx, edx
    xrstor64 [rcx]
    jmp .restored
.fxinit:
    fxrstor64 [rcx]
.restored:
    sti
    mov rsp, r12
    pop r13
    pop r12
    pop rbx
    jmp lx_return                       ; (RAX as the frame has it)
.bad:
    mov rsp, r12
    pop r13
    pop r12
    pop rbx
    mov edi, SIGSEGV
    jmp lx_die

; lx_fault_signal(RDI = frame, ESI = signal, R12 = CR2) -> CF if the
; process has no handler for it that may run now (then the fault ends it);
; else it is pending for this thread, with what and where
lx_fault_signal:
    push rax
    push rcx
    push rdx
    call lx_cur_proc
    lea ecx, [esi - 1]
    mov edx, ecx
    shl edx, 5
    add rdx, [rax + LP_SIGACTS]
    cmp qword [rdx + LSA_HANDLER], SIG_IGN
    jbe .none                           ; SIG_DFL, SIG_IGN
    mov rax, [gs:PC_CURRENT]
    bt [rax + TH_SIGMASK], rcx
    jc .none
    mov [rax + TH_LXINFO + LI_SIGNO], esi
    mov rdx, [rdi + FR_VECTOR]
    mov [rax + TH_LXINFO + LI_TRAPNO], rdx
    mov rcx, [rdi + FR_ERROR]
    mov [rax + TH_LXINFO + LI_ERR], rcx
    mov dword [rax + TH_LXINFO + LI_CODE], SI_KERNEL
    mov qword [rax + TH_LXINFO + LI_ADDR], 0
    cmp edx, 14
    jne .not_pf
    mov [rax + TH_LXINFO + LI_ADDR], r12
    and ecx, 1                          ; SEGV_MAPERR 1, SEGV_ACCERR 2
    inc ecx
    mov [rax + TH_LXINFO + LI_CODE], ecx
    jmp .set
.not_pf:
    mov rcx, [rdi + FR_RIP]             ; the others: where it was
    cmp edx, 13
    je .set                             ; (#GP: SI_KERNEL, no address)
    mov [rax + TH_LXINFO + LI_ADDR], rcx
    mov dword [rax + TH_LXINFO + LI_CODE], 1
.set:
    lea ecx, [esi - 1]
    lock bts [rax + TH_SIGPEND], rcx
    clc
    jmp .out
.none:
    stc
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; lx_sig_init: what delivery needs, once (lx_init)
lx_sig_init:
    sub rsp, 512 + 64
    mov rax, rsp
    add rax, 63
    and rax, -64
    fxsave64 [rax]                      ; MXCSR_MASK, 0 meaning 0xFFBF
    mov ecx, [rax + 28]
    test ecx, ecx
    jnz .mask
    mov ecx, 0xFFBF
.mask:
    mov [lx_mxcsr_mask], ecx
    add rsp, 512 + 64
    ret

section .rodata
; the frame's offset of each of sigcontext's first registers: r8 .. r15,
; rdi, rsi, rbp, rbx, rdx, rax, rcx, rsp, rip, eflags
lx_sc_regs:
    db FR_R8, FR_R9, FR_R10, FR_R11, FR_R12, FR_R13, FR_R14, FR_R15
    db FR_RDI, FR_RSI, FR_RBP, FR_RBX, FR_RDX, FR_RAX, FR_RCX, FR_RSP
    db FR_RIP, FR_RFLAGS

section .data
align 64
; a SIMD state as a handler starts with: x87 and SSE at their defaults, the
; rest at their init state (XSTATE_BV 0)
lx_fp_init:
    dw 0x037F                           ; FCW
    times 22 db 0
    dd 0x1F80                           ; MXCSR
    times 512 + 64 - 28 db 0

section .bss
alignb 64
lx_futex_buckets: resb LX_FUTEX_BUCKETS * FB_SIZE
lx_mxcsr_mask:  resd 1
lx_ctrl_c:      resb 1                  ; ctrl+C was pressed once for it

section .text
