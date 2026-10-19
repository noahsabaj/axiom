; =============================================================================
;  user.asm - ring 3: programs from the boot stick, each a task with page
;  tables of its own, talking to the kernel through its ring
;
;  A program is a flat file (src/user/*.asm, through axe.inc): the AXE_*
;  header, then its code, its constants and its data, each on pages of their
;  own. 'run' reads it from /EFI/AXIOM on the boot stick (or the volume
;  chosen) and makes it a task with an address space: the kernel's upper
;  half, which every set of tables shares and ring 3 cannot touch, and below
;  it, for this task alone,
;    USER_START      the start block (SB_*): handles to its ring, the ring's
;                    memory and the console; where the ring is; the TSC
;                    rate; the arguments. Read-only.
;    USER_IMAGE      the program: code read-only, constants read-only and
;                    not executable, data and zeroes writable and not
;                    executable
;    USER_MAPS on    each block of memory it maps (SYS_MAP), a guard page
;                    after each
;    USER_STACK_TOP  its first thread's 64 KiB stack is below, and nothing
;                    below that
;  The first thread starts at the header's entry with RDI = the start block
;  and RSP = USER_STACK_TOP; every other register is 0.
;
;  SYSCALL comes in at syscall_entry: onto the thread's kernel stack, a frame
;  as an interrupt's (FR_*), interrupts on, the call, then back by SYSRET.
;  The calls (SYS_*) are what a ring cannot do for a task: enter the ring,
;  make memory and map and unmap it, make rings, events, threads and
;  channels, start a program, yield, exit.
;  Everything else is an entry on a ring, writing to the console (RO_WRITE)
;  too. The kernel never touches a task's pages at their user addresses, and
;  SMAP would stop it: a ring and a block of memory are pages in the vm
;  region too, and the kernel reads and writes them there.
;
;  A fault in ring 3 ends the task, not the machine: what it was and where
;  is said, and the task is killed. Killing one (task_kill) marks it; each of
;  its threads ends the next time it would go back to ring 3 (one parked is
;  woken, one running on another CPU is interrupted). When the first thread
;  ends, the rest are killed. A task's pages, its page tables and its
;  mappings go when the task does. A mapping is its capability's: it goes
;  when that handle is closed, revoked or given away, or by SYS_UNMAP, and
;  the task's TLBs are flushed before the memory can go.
;
;  A program starts another with SYS_SPAWN, and may give it a handle (its
;  number in SB_GIFT): the main thread loads it (the boot stick is read
;  there alone), a child of the task that asked, which gets handles to it
;  and its first thread. Killing a task kills its children, and theirs; a
;  killed task with no thread left closes its handles at once. It may also
;  name a channel's end for the child's console: what the child, and what
;  it starts, write goes there as messages (TK_OUT), waiting while the
;  other end has CH_QUEUE_MAX unread, and that end hears E_PEER once they
;  have all ended (a fleet node's job's log, say).
;
;  Neither a system call nor an interrupt saves SIMD state: nothing they run
;  uses SIMD (macros.inc), and the scheduler keeps each thread's. It keeps
;  each thread's FS and GS bases too, but only a Linux program can set them
;  (arch_prctl): a native program's are 0, with no thread-local storage
;  (FSGSBASE is off).
;
;    <program> [arguments], or run <program> [arguments]: the prompt
;      waits for it, ctrl+C stops it; with '&' after it, it runs on in the
;      background (user_start: a job; as many as USER_JOBS at once)
;    user_load(RDI = path, RSI = arguments, RDX = name, RCX = the task
;      starting it or 0 for the shell, R8D = a handle of that task's to give
;      it or 0, R9 = what the shell grants it beyond what its header WANTS,
;      AW_*) -> RAX = a task (a reference), RDX = its first thread, started
;      (a reference, for user_wait); RAX = 0 if it could not be loaded
;      (said why), RDX = E_*. One the shell runs gets the network, its
;      names in the store and the desktop only as it wants or is granted
;      them, and writes to the shell's terminal; one a task starts gets
;      none of them, only what it is given, and writes where its parent does
;    user_wait(RDI = task, RSI = its first thread) -> RAX = what that thread
;      returned, once it and every other thread of the task have ended
;    task_kill(RDI = task)
; =============================================================================

; a program run from the shell: a job
JB_TASK         equ 0                   ; a reference; 0: the slot is free
JB_FIRST        equ 8                   ; its first thread, until user_wait
JB_CON          equ 16                  ; the terminal it was run from (0: gone)
JB_EXIT         equ 24                  ; what its first thread returned
JB_FLAGS        equ 32                  ; dword: JF_*
JB_SIZE         equ 40
JF_BACK         equ 1                   ; in the background: no prompt waits for it
JF_ENDED        equ 2                   ; it ended: user_service says so
USER_JOBS       equ 16
USER_RUNNING    equ 256

; an address space
AS_PML4         equ 0                   ; its PML4, where the direct map has it
AS_CR3          equ 8
AS_LOCK         equ 16                  ; dword
AS_NMAPS        equ 20                  ; dword
AS_NEXT         equ 24                  ; where the next mapping goes
AS_MAPS         equ 32                  ; AS_MAX of AM_SIZE
AS_MAX          equ 128                 ; blocks mapped at once (a heap, a window, files)
AS_LX           equ AS_MAPS + AS_MAX * AM_SIZE ; a Linux program's memory (lxmm.asm):
AS_VMAS         equ AS_LX + 0           ; its areas (VA_SIZE each, by address), or 0
AS_NVMA         equ AS_LX + 8           ; dword: how many
AS_VCAP         equ AS_LX + 12          ; dword: room for
AS_MMLOCK       equ AS_LX + 16          ; dword: the areas and the pages under them
AS_REFS         equ AS_LX + 20          ; dword: tasks sharing it, less one (vfork)
AS_BRK0         equ AS_LX + 24          ; where its break started
AS_BRK          equ AS_LX + 32          ; and where it is
AS_VBYTES       equ AS_LX + 40          ; bytes of AS_VMAS mapped
AS_SIZE         equ AS_LX + 64
AM_OBJ          equ 0                   ; a mapping: the memory (a reference)
AM_VA           equ 8                   ; where
AM_LEN          equ 16                  ; bytes
AM_SIZE         equ 32

PTE_U           equ 1 << 2              ; ring 3 may use it
UF_CODE         equ PTE_P | PTE_U | PTE_A
UF_RO           equ PTE_P | PTE_U | PTE_A       ; with NX
UF_RW           equ PTE_P | PTE_W | PTE_U | PTE_A | PTE_D ; with NX
UF_TABLE        equ PTE_P | PTE_W | PTE_U
USER_FMASK      equ (1 << 8) | (1 << 9) | (1 << 10) | (1 << 14) | (1 << 18) ; TF IF DF NT AC
USER_RFLAGS     equ 0x202               ; IF, and the bit always set

USER_RING_N     equ 64                  ; entries in a program's ring
CON_WRITE_MAX   equ 4096                ; bytes in one RO_WRITE
CON_LINE        equ 200                 ; a longer line is cut in pieces
USER_NAME_MAX   equ 64

; a program's request for another (sys_spawn), on its kernel stack until done
SR_NEXT         equ 0
SR_TASK         equ 8                   ; the task asking
SR_TEXT         equ 16                  ; "program arguments", NUL-ended, from the heap
SR_GIFT         equ 24                  ; dword: a handle of its to give
SR_DONE         equ 28                  ; dword: 1 once done
SR_THREAD       equ 32                  ; the thread asking
SR_RAX          equ 40                  ; what it gets back
SR_RDX          equ 48
SR_GIFT2        equ 56                  ; dword: a second, or 0
SR_OUT          equ 64                  ; a channel's end for its console (held), or 0
SR_SIZE         equ 72
SPAWN_TEXT_MAX  equ 255
SPAWN_DEPTH     equ 8                   ; programs started by programs, this deep
SPAWN_TASK_RIGHTS equ RT_DUP | RT_GIVE | RT_INFO | RT_TASK_HANDLES | RT_TASK_KILL
SPAWN_THREAD_RIGHTS equ RT_DUP | RT_GIVE | RT_INFO | RT_THREAD_WAIT
UT_KILL_US      equ 1000000             ; how long a killed task may take to end (TCG, busy hosts)

section .text

; -----------------------------------------------------------------------------
;  Boot, and each CPU
; -----------------------------------------------------------------------------

; user_boot: the console, which every program gets a capability to
user_boot:
    mov edi, OT_CONSOLE
    mov esi, OB_SIZE
    lea rdx, [str_ot_console]
    call obj_new
    test rax, rax
    jz .oom
    mov [console_obj], rax              ; the kernel's reference, kept
    ret
.oom:
    xor edi, edi
    lea rsi, [str_user_oom]
    jmp panic

; user_setup_local: SYSCALL and SYSRET on this CPU (cpu_setup_local).
; Preserves all.
user_setup_local:
    push rax
    push rcx
    push rdx
    mov ecx, MSR_EFER
    rdmsr
    or eax, 1                           ; SCE
    wrmsr
    mov ecx, MSR_STAR                   ; SYSCALL: CS 0x08, SS 0x10; SYSRET:
    xor eax, eax                        ; SS 0x18 | 3, CS 0x20 | 3
    mov edx, (SEL_KDATA << 16) | SEL_KCODE
    wrmsr
    mov ecx, MSR_LSTAR
    lea rax, [syscall_entry]
    mov rdx, rax
    shr rdx, 32
    wrmsr
    mov ecx, MSR_FMASK                  ; and in the kernel, none of these
    mov eax, USER_FMASK
    xor edx, edx
    wrmsr
    mov ecx, MSR_KGS_BASE               ; ring 3's GS base
    xor eax, eax
    wrmsr
    mov ecx, MSR_FS_BASE                ; and FS's (PC_FSBASE says 0)
    wrmsr
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  In and out of ring 3
; -----------------------------------------------------------------------------

; syscall_entry: SYSCALL, with interrupts off (USER_FMASK)
syscall_entry:
    swapgs
    mov [gs:PC_USER_RSP], rsp
    mov rsp, [gs:PC_KSTACK]
    push SEL_UDATA                      ; a frame as an interrupt's
    push qword [gs:PC_USER_RSP]
    push r11                            ; RFLAGS
    push SEL_UCODE
    push rcx                            ; RIP
    push 0
    push VEC_SYSCALL
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsp
    sti
    mov rcx, r10                        ; the fourth argument where the kernel has it
    mov r11, [gs:PC_CURRENT]
    test qword [r11 + TH_FLAGS], TF_LINUX
    jnz lx_syscall                      ; a Linux program's (linux.asm)
    cmp rax, SYS_COUNT
    jae .unknown
    lea r11, [sys_table]
    call [r11 + rax * 8]
    jmp .done
.unknown:
    mov rax, E_ARG
    xor edx, edx
.done:
    mov [rbp + FR_RAX], rax
    mov [rbp + FR_RDX], rdx
    cli
    call user_leave
    mov rax, [rbp + FR_RIP]             ; SYSRET to an address not canonical
    shr rax, 47                         ; would fault in ring 0
    jnz .bad_rip
    mov rsp, rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16                         ; vector and error code
    mov rcx, [rsp]                      ; RIP
    mov r11, [rsp + 16]                 ; RFLAGS
    mov rsp, [rsp + 24]
    swapgs
    o64 sysret
.bad_rip:                               ; as a fault
    sti
    mov rax, [gs:PC_CURRENT]
    mov rdi, [rax + TH_TASK]
    lock bts dword [rdi + TK_KILL], 1
    call task_kill
    mov rdi, E_FAULT
    jmp thread_exit

; user_leave: on the way back to ring 3, interrupts off: a thread whose task
; is being killed goes no further; a Linux thread takes its signals (RBP is
; its frame). Preserves all.
user_leave:
    push rax
    mov rax, [gs:PC_CURRENT]
    mov rax, [rax + TH_TASK]
    test byte [rax + TK_KILL], 1
    pop rax
    jnz .killed
    push rax
    mov rax, [gs:PC_CURRENT]
    test qword [rax + TH_FLAGS], TF_LINUX
    pop rax
    jnz lx_leave                        ; its signals (lxsig.asm)
    ret
.killed:
    mov rax, [gs:PC_CURRENT]
    test qword [rax + TH_FLAGS], TF_LINUX
    jnz lx_killed                       ; its process is told (linux.asm)
    mov rdi, E_KILLED
    test byte [rax + TH_FLAGS], TF_FIRST
    jz .end
    mov rax, [rax + TH_TASK]
    test byte [rax + TK_KILL], 4        ; ended by EXIT_TASK: with its code
    jz .end
    mov rdi, [rax + TK_CODE]
.end:
    jmp thread_exit

; user_killed -> EAX = 1 if the running thread is a user thread whose task
; is being killed (so it waits no more), or a Linux thread with a signal to
; take, else 0. Preserves others.
user_killed:
    mov rax, [gs:PC_CURRENT]
    test byte [rax + TH_FLAGS], TF_USER
    jz .no
    test byte [rax + TH_FLAGS], TF_LINUX
    jnz lx_interrupted                  ; or a signal is pending (lxsig.asm)
    mov rax, [rax + TH_TASK]
    mov eax, [rax + TK_KILL]
    and eax, 1
    ret
.no:
    xor eax, eax
    ret

; user_begin: a user thread's first instructions (its kernel entry), into
; ring 3 at TH_UENTRY with RSP = TH_USSTACK, RDI = TH_UARG, the rest 0
user_begin:
    cli
    call user_leave                     ; killed before it ever ran
    mov rax, [gs:PC_CURRENT]
    push SEL_UDATA
    push qword [rax + TH_USTACK]
    push USER_RFLAGS
    push SEL_UCODE
    push qword [rax + TH_UENTRY]
    mov rdi, [rax + TH_UARG]
    xor eax, eax
    xor ebx, ebx
    xor ecx, ecx
    xor edx, edx
    xor esi, esi
    xor ebp, ebp
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    xor r12d, r12d
    xor r13d, r13d
    xor r14d, r14d
    xor r15d, r15d
    swapgs
    iretq

; user_fault(RDI = frame): an exception in ring 3, interrupts off. Says what
; and where, kills the task, and ends this thread. A Linux program's goes to
; lx_fault, which returns if it was a page to fill in.
user_fault:
    mov r12, cr2
    mov rax, [gs:PC_CURRENT]
    test qword [rax + TH_FLAGS], TF_LINUX
    jnz lx_fault
; user_fault_said(RDI = frame, R12 = CR2 as it was)
user_fault_said:
    mov rbx, rdi
    sti
    mov r13, [gs:PC_CURRENT]
    mov r13, [r13 + TH_TASK]
    lock bts dword [r13 + TK_KILL], 1   ; by a fault
    lea r14, [r13 + OB_NAME]
    mov rax, [rbx + FR_VECTOR]
    lea rcx, [exception_names]
    mov r15, [rcx + rax * 8]
    cmp eax, 14
    je .page_fault
    KLOG "%s: %s at %p", r14, r15, qword [rbx + FR_RIP]
    jmp .kill
.page_fault:
    mov rcx, [rbx + FR_ERROR]
    lea rdx, [str_pf_read]              ; what it was doing
    test ecx, 1 << 1
    jz .verb
    lea rdx, [str_pf_write]
.verb:
    test ecx, 1 << 4
    jz .verb_done
    lea rdx, [str_pf_fetch]
.verb_done:
    lea r8, [str_pf_unmapped]           ; and what stood in the way
    test ecx, 1 << 0
    jz .said
    lea r8, [str_pf_readonly]
    test ecx, 1 << 1
    jnz .said
    lea r8, [str_pf_nx]
    test ecx, 1 << 4
    jnz .said
    lea r8, [str_pf_forbidden]
.said:
    KLOG "%s: %s at %p: %s %p%s", r14, r15, qword [rbx + FR_RIP], rdx, r12, r8
.kill:
    lock inc qword [user_faults]
    mov rdi, r13
    call task_kill
    mov rax, [gs:PC_CURRENT]
    test qword [rax + TH_FLAGS], TF_LINUX
    jnz lx_thread_exit
    mov rdi, E_FAULT
    jmp thread_exit

; task_kill(RDI = task): each of its threads ends when next it would go back
; to ring 3; those parked are woken, those running elsewhere interrupted.
; The tasks it started are killed too, and theirs. Preserves all.
task_kill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    lock bts dword [r12 + TK_KILL], 0
    pushfq
    cli
    lea rdi, [threads_lock]
    call spin_lock
    mov rbx, [thread_list]
.thread:
    test rbx, rbx
    jz .done
    cmp [rbx + TH_TASK], r12
    jne .next
    test byte [rbx + TH_FLAGS], TF_USER
    jz .next
    mov rdi, rbx
    call thread_unpark                  ; parked: on its way out
    cmp dword [rbx + TH_STATE], TS_RUNNING
    jne .next
    mov rax, [rbx + TH_CPU]
    cmp rax, [gs:PC_INDEX]
    je .next
    PERCPU rdi, rax                     ; running elsewhere: out of ring 3
    mov edi, [rdi + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_RESCHED
    call lapic_send_ipi
.next:
    mov rbx, [rbx + OB_NEXT]
    jmp .thread
.done:
    lea rdi, [threads_lock]
    call spin_unlock
    popfq
.children:                              ; a task it started, not killed yet
    pushfq
    cli
    lea rdi, [ty_task + TY_LOCK]
    call spin_lock
    mov rbx, [ty_task + TY_LIST]
.child:
    test rbx, rbx
    jz .looked
    cmp [rbx + TK_PARENT], r12
    jne .next_child
    test byte [rbx + TK_KILL], 1
    jnz .next_child
    mov rdi, rbx
    call obj_tryget                     ; not one on its way out
    jnc .looked
.next_child:
    mov rbx, [rbx + OB_NEXT]
    jmp .child
.looked:
    lea rdi, [ty_task + TY_LOCK]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .killed
    mov rdi, rbx
    call task_kill
    call obj_put
    jmp .children
.killed:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The calls (RDI, RSI, RDX, RCX = the arguments) -> RAX, RDX
; -----------------------------------------------------------------------------

; sys_exit(RDI = code, ESI = EXIT_TASK or 0): this thread ends. The task
; ends too if it is the first, or with EXIT_TASK: its first thread returns
; the code the first EXIT_TASK said.
sys_exit:
    mov rax, [gs:PC_CURRENT]
    mov rcx, [rax + TH_TASK]
    test byte [rax + TH_FLAGS], TF_FIRST
    jnz .first
    cmp esi, EXIT_TASK
    jne .exit
    lock bts dword [rcx + TK_KILL], 3   ; one code is said: the first's
    jc .kill
    mov [rcx + TK_CODE], rdi
    lock bts dword [rcx + TK_KILL], 2
.kill:
    push rdi
    mov rdi, rcx
    call task_kill
    pop rdi
.exit:
    jmp thread_exit
.first:
    push rdi                            ; the first: its task ends with it
    mov rdi, rcx
    call task_kill
    pop rdi
    test byte [rcx + TK_KILL], 4        ; with a code said before
    jz .exit
    mov rdi, [rcx + TK_CODE]
    jmp thread_exit

sys_ring_enter:
    call h_ring_enter
    xor edx, edx
    ret

sys_ring_new:
    lea rsi, [str_user_ring]
    call h_ring_new
    cmp rax, E_ANY
    jb .out
    xor edx, edx
.out:
    ret

sys_mem_new:
    lea rsi, [str_user_mem]
    call h_mem_new
    xor edx, edx
    ret

sys_map:
    call user_map
    xor edx, edx
    ret

sys_event_new:
    lea rdi, [str_user_event]
    call h_event_new
    xor edx, edx
    ret

sys_yield:
    call thread_yield
    xor eax, eax
    xor edx, edx
    ret

; sys_thread_new(RDI = entry, RSI = RSP, RDX = RDI) -> RAX = a handle to a
; thread of this task, started
sys_thread_new:
    push rbx
    push r12
    mov rax, E_ARG                      ; both in the lower half
    mov rcx, USER_TOP
    cmp rdi, rcx
    jae .out
    cmp rsi, rcx
    jae .out
    call cur_task
    mov r12, rax
    mov rax, E_KILLED
    test byte [r12 + TK_KILL], 1
    jnz .out
    mov rcx, r12
    call user_thread
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov rdi, r12                        ; the creator's reference goes into it
    mov rsi, rbx
    mov edx, RT_ALL
    call cap_new
    cmp rax, E_ANY
    jae .no_handle
    push rax
    mov rdi, rbx
    call thread_start
    pop rax
    jmp .out
.no_handle:                             ; never to start: its own reference too
    push rax
    mov rdi, rbx
    call thread_put
    pop rax
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    xor edx, edx
    pop r12
    pop rbx
    ret

sys_channel_new:
    jmp h_channel_new

; sys_tls(RDI = an FS base, in the lower half): this thread's from now on,
; kept as a Linux thread's is (TH_FSBASE, loaded by sched_switch)
sys_tls:
    mov rax, E_ARG
    mov rcx, USER_TOP
    cmp rdi, rcx
    jae .out
    pushfq
    cli
    mov rax, [gs:PC_CURRENT]
    mov [rax + TH_FSBASE], rdi
    mov [gs:PC_FSBASE], rdi
    mov eax, edi
    mov rdx, rdi
    shr rdx, 32
    mov ecx, MSR_FS_BASE
    wrmsr
    popfq
    xor eax, eax
.out:
    xor edx, edx
    ret

; sys_futex_wait(RDI = an address, ESI = the value, RDX = TSC deadline or
; 0) -> RAX = 0 once a SYS_FUTEX_WAKE woke it, E_CONFLICT if the dword held
; another value, E_TIMEOUT, E_KILLED, E_RANGE (not the program's), E_ARG
; (not 4-aligned). Linux's futexes (lxsig.asm), keyed by where the word is
; (so tasks sharing memory share them too).
sys_futex_wait:
    mov ecx, -1                         ; woken by any wake
    call lx_futex_wait
    jmp futex_result

; sys_futex_wake(RDI = an address, ESI = at most) -> RAX = threads woken
sys_futex_wake:
    mov edx, -1
    call lx_futex_wake
; futex_result(RAX = Linux's result) -> RAX = ours, RDX = 0
futex_result:
    xor edx, edx
    test rax, rax
    jns .out
    cmp rax, -EAGAIN
    je .conflict
    cmp rax, -ETIMEDOUT
    je .timeout
    cmp rax, -EFAULT
    je .range
    cmp rax, -EINVAL
    je .arg
    mov rax, E_KILLED                   ; (-EINTR, -ERESTARTSYS: being killed)
    ret
.conflict:
    mov rax, E_CONFLICT
    ret
.timeout:
    mov rax, E_TIMEOUT
    ret
.range:
    mov rax, E_RANGE
    ret
.arg:
    mov rax, E_ARG
.out:
    ret

; sys_info(EDI = SI_*) -> RAX: SI_CLOCK, microseconds since 1970 (the RTC
; read at boot, taken as UTC, kept since by the TSC); SI_CPUS, CPUs running;
; SI_RAM and SI_RAM_FREE, bytes of memory and of it free; SI_UPTIME,
; milliseconds since power-on; SI_BATTERY, the battery as last read
; (bat_info)
sys_info:
    cmp edi, SI_CLOCK
    je .clock
    cmp edi, SI_CPUS
    je .cpus
    cmp edi, SI_RAM
    je .ram
    cmp edi, SI_RAM_FREE
    je .ram_free
    cmp edi, SI_UPTIME
    je .uptime
    cmp edi, SI_BATTERY
    je .battery
    mov rax, E_ARG
    xor edx, edx
    ret
.battery:
    call bat_info
    xor edx, edx
    ret
.ram:
    mov rax, [pmm_usable_bytes]
    xor edx, edx
    ret
.ram_free:
    mov rax, [pmm_free_pages]
    shl rax, 12
    xor edx, edx
    ret
.uptime:
    call uptime_ms
    xor edx, edx
    ret
.clock:
    RDTSC64
    xor edx, edx
    div qword [tsc_per_us]
    add rax, [rtc_epoch_us]
    xor edx, edx
    ret
.cpus:
    mov eax, [cpus_online]
    xor edx, edx
    ret

; h_task_kill(EDI = a task with an address space) -> RAX = 0 (needs
; RT_TASK_KILL): it, and the tasks it started
h_task_kill:
    mov esi, OT_TASK
    mov edx, RT_TASK_KILL
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    mov rax, E_TYPE
    cmp qword [rdi + TK_AS], 0
    je .put
    call task_kill
    xor eax, eax
.put:
    call obj_put
.out:
    ret

; sys_spawn(EDI = memory, RSI = offset, EDX = bytes there of "program
; arguments", RDX's high dword = a channel's end for what its console writes
; (needs RT_CH_SEND), or 0; RCX = a handle to give it, or 0, R8 = a second,
; or 0) -> RAX = a handle to the task it started, RDX = to its first thread
; (RO_JOIN for what it returns). The main thread reads the file, so it does
; the loading; this thread waits for it, and is not cut short meanwhile.
sys_spawn:
    push rbx
    push r12
    push r13
    sub rsp, SR_SIZE
    mov rbx, rsp                        ; RBX = the request
    mov [rbx + SR_GIFT], ecx
    mov [rbx + SR_GIFT2], r8d
    mov qword [rbx + SR_TEXT], 0
    mov qword [rbx + SR_OUT], 0
    mov r12d, edi
    mov r13, rsi
    mov rdi, rdx                        ; where its console goes
    shr rdi, 32
    jz .its_text
    push rdx
    mov esi, OT_CHANNEL
    mov edx, RT_CH_SEND
    call handle_get
    pop rdx
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call out_hold
    mov [rbx + SR_OUT], rdi             ; held, until the child takes it
.its_text:
    mov edx, edx
    mov rax, E_ARG
    test rdx, rdx
    jz .out
    cmp rdx, SPAWN_TEXT_MAX
    ja .out
    push rdx
    lea rdi, [rdx + 1]                  ; zeroed: NUL-ended
    call kmalloc
    pop rcx
    test rax, rax
    jz .nomem
    mov [rbx + SR_TEXT], rax
    mov edi, r12d
    mov rsi, r13
    mov rdx, rax
    call h_mem_read
    cmp rax, E_ANY
    jae .free
    call cur_task
    mov [rbx + SR_TASK], rax
    mov rcx, rax
    mov rax, E_KILLED
    test byte [rcx + TK_KILL], 1
    jnz .free
    xor edx, edx                        ; how many programs above it
.depth:
    mov rcx, [rcx + TK_PARENT]
    test rcx, rcx
    jz .shallow
    cmp qword [rcx + TK_AS], 0
    je .shallow
    inc edx
    cmp edx, SPAWN_DEPTH
    jb .depth
    mov rax, E_FULL
    jmp .free
.shallow:
    mov dword [rbx + SR_DONE], 0
    mov rax, [gs:PC_CURRENT]
    mov [rbx + SR_THREAD], rax
    pushfq
    cli
    lea rdi, [spawn_lock]
    call spin_lock
    mov rax, [spawn_tail]               ; last in line
    mov qword [rbx + SR_NEXT], 0
    test rax, rax
    jz .first
    mov [rax + SR_NEXT], rbx
    jmp .queued
.first:
    mov [spawn_list], rbx
.queued:
    mov [spawn_tail], rbx
    lea rdi, [spawn_lock]
    call spin_unlock
    popfq
    mov rdi, [main_thread]
    call thread_unpark
.wait:
    cmp dword [rbx + SR_DONE], 0
    jne .done
    call thread_park
    jmp .wait
.done:
    mov rax, [rbx + SR_RAX]
    mov rdx, [rbx + SR_RDX]
    jmp .free_rdx
.free:
    xor edx, edx
.free_rdx:
    push rax
    push rdx
    mov rdi, [rbx + SR_TEXT]
    call kfree
    pop rdx
    pop rax
    jmp .back
.nomem:
    mov rax, E_NOMEM
.out:
    xor edx, edx
.back:
    mov rdi, [rbx + SR_OUT]             ; unless the child took it
    call out_drop
    add rsp, SR_SIZE
    pop r13
    pop r12
    pop rbx
    ret

; out_hold(RDI = a channel's end, a reference the caller gives): kept as a
; task's console (TK_OUT), counted as a capability so that the end stays
; open while a task writes to it. Preserves all.
out_hold:
    lock inc dword [rdi + OB_CAPS]
    ret

; out_drop(RDI = such an end, or 0): let go; with its last capability gone,
; its peer hears so. Preserves all.
out_drop:
    test rdi, rdi
    jz .none
    lock dec dword [rdi + OB_CAPS]
    jnz .put
    call obj_orphaned
.put:
    jmp obj_put
.none:
    ret

; spawn_service: on the main thread, each program a program asked for, loaded
spawn_service:
    call fs_service                     ; and their files (fscap.asm)
    push rbx
    push r12
.next:
    cmp qword [spawn_list], 0
    je .out
    pushfq
    cli
    lea rdi, [spawn_lock]
    call spin_lock
    mov rbx, [spawn_list]
    test rbx, rbx
    jz .unlock
    mov rax, [rbx + SR_NEXT]
    mov [spawn_list], rax
    test rax, rax
    jnz .unlock
    mov [spawn_tail], rax
.unlock:
    lea rdi, [spawn_lock]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .out
    call spawn_one
    mov r12, [rbx + SR_THREAD]          ; the request is gone once it is done
    mov rdi, r12
    call obj_get
    mov dword [rbx + SR_DONE], 1
    call thread_unpark
    call obj_put
    jmp .next
.out:
    pop r12
    pop rbx
    ret

; spawn_one(RBX = a request): its program loaded, a child of the task that
; asked, which gets handles to it and its first thread
spawn_one:
    push r12
    push r13
    mov qword [rbx + SR_RDX], 0
    mov rsi, [rbx + SR_TEXT]
    call arg_split
    mov rax, E_ARG
    cmp byte [rsi], 0
    je .said
    mov r12, rdi                        ; its arguments
    call user_path
    mov rcx, [rbx + SR_TASK]
    mov rax, E_KILLED
    test byte [rcx + TK_KILL], 1
    jnz .said
    lea rdi, [user_path_buf]
    mov rsi, r12
    lea rdx, [user_name_buf]
    mov r8d, [rbx + SR_GIFT2]           ; what it is given: both
    shl r8, 32
    mov eax, [rbx + SR_GIFT]
    or r8, rax
    xor r9d, r9d                        ; (a task's child: nothing granted)
    mov rax, [rbx + SR_OUT]             ; where its console goes, for user_load
    mov [user_out], rax
    mov qword [rbx + SR_OUT], 0
    call user_load
    push rdi
    mov rdi, [user_out]                 ; not taken: it failed before its task
    mov qword [user_out], 0
    call out_drop
    pop rdi
    test rax, rax
    jz .failed
    mov r12, rax                        ; the task, R13 its first thread
    mov r13, rdx
    mov rdi, r12
    call obj_get                        ; ours, while we look
    mov rdi, [rbx + SR_TASK]
    mov rsi, r12
    mov edx, SPAWN_TASK_RIGHTS
    call cap_new
    mov [rbx + SR_RAX], rax
    cmp rax, E_ANY
    jae .no_task
    mov rdi, [rbx + SR_TASK]
    mov rsi, r13
    mov edx, SPAWN_THREAD_RIGHTS
    call cap_new
    mov [rbx + SR_RDX], rax
    cmp rax, E_ANY
    jae .no_thread
    mov rax, [rbx + SR_TASK]            ; killed meanwhile: so is this
    test byte [rax + TK_KILL], 1
    jz .put
    jmp .kill
.no_thread:                             ; the task's handle stays, and says it was killed
    mov [rbx + SR_RAX], rax
    mov qword [rbx + SR_RDX], 0
    jmp .kill
.no_task:
    mov rdi, r13
    call obj_put
.kill:
    mov rdi, r12
    call task_kill
.put:
    mov rdi, r12
    call obj_put
    jmp .out
.failed:
    mov rax, rdx
.said:
    mov [rbx + SR_RAX], rax
.out:
    pop r13
    pop r12
    ret

; gift_slot(EAX = a handle the new task was given, RBP = its start block;
; that task the current one): where a handle of its kind goes as well
; (SB_DESK, SB_FILES, SB_NET, SB_STORE, SB_SOUND), if that is empty. Preserves RAX.
gift_slot:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, eax
    call handle_info                    ; EAX = its type
    lea rsi, [gift_slots]
.each:
    mov ecx, [rsi]
    test ecx, ecx
    jz .out
    cmp eax, ecx
    je .found
    add rsi, 8
    jmp .each
.found:
    mov ecx, [rsi + 4]
    cmp dword [rbp + rcx], 0
    jne .out
    mov eax, [rsp + 32]
    mov [rbp + rcx], eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; user_thread(RDI = entry, RSI = RSP, RDX = RDI, RCX = task) -> RAX = a
; thread of that task to run in ring 3, not started, with its own reference
; and the caller's; 0 if out of memory
user_thread:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    lea rdi, [user_begin]
    xor esi, esi
    lea rdx, [r15 + OB_NAME]
    call thread_new
    test rax, rax
    jz .out
    mov rbx, rax
    or qword [rbx + TH_FLAGS], TF_USER
    mov [rbx + TH_UENTRY], r12
    mov [rbx + TH_USTACK], r13
    mov [rbx + TH_UARG], r14
    mov rax, [r15 + TK_AS]
    mov rax, [rax + AS_CR3]
    mov [rbx + TH_CR3], rax
    mov rdi, rbx
    mov rsi, r15
    call thread_set_task
    mov rax, rbx
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; user_map(EDI = a handle to memory) -> RAX = where the current task has its
; window now: writable if the handle allows writing (it must allow reading),
; whole pages only. Mapped already: where it is. The mapping is the
; capability's (CAP_MAPVA), and goes with it.
user_map:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    push rdi                            ; [rsp] = the handle
    mov esi, OT_MEMORY
    mov edx, RT_MEM_READ
    call handle_get                     ; RDX, RCX = the window
    cmp rax, E_ANY
    jae .out
    mov rbx, rax                        ; RBX = the memory, a reference
    mov r14, rdx
    mov r15, rcx
    mov rax, E_ARG
    test r15, r15
    jz .put
    mov r8, r14
    or r8, r15
    test r8d, 0xFFF
    jnz .put
    call cur_task
    mov r12, rax                        ; R12 = this task, for cap_find
    mov rbp, [r12 + TK_AS]
    mov rax, E_ARG
    test rbp, rbp
    jz .put                             ; a task with no address space
    CAP_LOCK                            ; mapped already? and its rights
    mov esi, [rsp + 8]
    call cap_find
    cmp rax, E_ANY
    jae .early
    mov r13d, [rax + CAP_RIGHTS]
    mov rax, [rax + CAP_MAPVA]
.early:
    CAP_UNLOCK
    test rax, rax
    jnz .put                            ; refused just now, or mapped: that
    mov rdi, rbp
    mov rsi, rbx
    mov rdx, r14
    mov rcx, r15
    mov r8d, UF_RO
    test r13d, RT_MEM_WRITE
    jz .flags
    mov r8d, UF_RW
.flags:
    or r8, [vmm_nx]
    call as_map_mem                     ; the reference goes into the mapping
    cmp rax, E_ANY
    jae .put
    mov r14, rax                        ; R14 = where
    CAP_LOCK                            ; the capability's, if it is still there
    mov esi, [rsp + 8]
    call cap_find
    cmp rax, E_ANY
    jae .lost
    cmp [rax + CAP_OBJ], rbx
    mov rcx, E_BADH
    jne .lost_rcx
    mov rcx, [rax + CAP_MAPVA]          ; another thread mapped it meanwhile
    test rcx, rcx
    jnz .lost_rcx
    mov [rax + CAP_MAPVA], r14
    mov [rax + CAP_MAPLEN], r15
    CAP_UNLOCK
    mov rax, r14
    jmp .out
.lost_rcx:
    mov rax, rcx
.lost:                                  ; RAX = what to say: ours goes again
    CAP_UNLOCK
    push rax
    mov rdi, rbp
    mov rsi, r14
    call as_take
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r14
    call unmap_flush
    pop rax
    jmp .out
.put:
    push rax
    mov rdi, rbx
    call obj_put
    pop rax
.out:
    pop rdi
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sys_unmap(EDI = a handle to memory this task has mapped) -> RAX = 0: the
; mapping goes, and the handle stays
sys_unmap:
    push rbx
    push r12
    call cur_task
    mov r12, rax
    CAP_LOCK
    mov esi, edi
    call cap_find
    cmp rax, E_ANY
    jae .refused
    mov rdi, rax
    mov rax, E_ARG
    cmp qword [rdi + CAP_MAPVA], 0
    je .refused
    call cap_unmap
    mov rbx, [rdi + CAP_OBJ]
    xor esi, esi
    xor edx, edx
    xchg rsi, [rdi + CAP_MAPVA]
    xchg rdx, [rdi + CAP_MAPLEN]
    CAP_UNLOCK
    mov rdi, rbx
    call unmap_flush
    xor eax, eax
    jmp .out
.refused:
    CAP_UNLOCK
.out:
    xor edx, edx
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Address spaces
; -----------------------------------------------------------------------------

; as_new -> RAX = an address space with nothing in its lower half, 0 if out
; of memory
as_new:
    push rbx
    mov edi, AS_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov rbx, rax
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .nomem
    lock inc qword [user_tables]
    mov [rbx + AS_CR3], rax
    add rax, [phys_base]
    mov [rbx + AS_PML4], rax
    lea rdi, [rax + 256 * 8]            ; the kernel's half, as in every set
    mov rsi, [vmm_pml4]
    add rsi, 256 * 8
    mov ecx, 256
    rep movsq
    mov rax, USER_MAPS
    mov [rbx + AS_NEXT], rax
    mov rax, rbx
    jmp .out
.nomem:
    mov rdi, rbx
    call kfree
    xor eax, eax
.out:
    pop rbx
    ret

; as_release(RDI): a task is done with it: destroyed, if no other task
; shares it (AS_REFS, a vfork)
as_release:
    lock dec dword [rdi + AS_REFS]
    jns .shared
    jmp as_destroy
.shared:
    ret

; as_destroy(RDI): no thread runs on it any more. Its mappings' references,
; its own pages, its page tables, and it.
as_destroy:
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.map:
    cmp r12d, [rbx + AS_NMAPS]
    jae .tables
    imul eax, r12d, AM_SIZE
    mov rdi, [rbx + rax + AS_MAPS + AM_OBJ]
    call obj_put
    inc r12d
    jmp .map
.tables:
    xor r12d, r12d
.entry:
    mov rax, [rbx + AS_PML4]
    mov rdi, [rax + r12 * 8]
    test dil, PTE_P
    jz .next
    and rdi, [vmm_addr_mask]
    add rdi, [phys_base]
    mov esi, 2
    call as_free_table
.next:
    inc r12d
    cmp r12d, 256
    jb .entry
    mov rdi, [rbx + AS_CR3]
    mov esi, 1
    call pmm_free
    lock dec qword [user_tables]
    mov rdi, [rbx + AS_VMAS]            ; a Linux program's areas
    test rdi, rdi
    jz .no_areas
    call vm_free
.no_areas:
    mov rdi, rbx
    call kfree
    pop r12
    pop rbx
    ret

; as_free_table(RDI = a table, where the direct map has it, ESI = its level:
; 2 a PDPT, 1 a PD, 0 a PT): the pages of ours it maps, the tables under it,
; and it
as_free_table:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12d, esi
    xor r13d, r13d
.entry:
    mov rax, [rbx + r13 * 8]
    test al, PTE_P
    jz .next
    mov rdi, rax
    and rdi, [vmm_addr_mask]
    test r12d, r12d
    jnz .table
    test eax, PTE_OWN                   ; a memory object's page is its own
    jz .next
    mov esi, 1
    call pmm_free
    lock dec qword [user_pages]
    jmp .next
.table:
    add rdi, [phys_base]
    lea esi, [r12 - 1]
    call as_free_table
.next:
    inc r13d
    cmp r13d, 512
    jb .entry
    mov rdi, rbx
    sub rdi, [phys_base]
    mov esi, 1
    call pmm_free
    lock dec qword [user_tables]
    pop r13
    pop r12
    pop rbx
    ret

; as_pte(RDI = address space, RSI = a user address) -> RAX = where the direct
; map has its PTE, the tables above it made if missing; 0 if out of memory.
; Preserves others.
as_pte:
    push rcx
    push rdx
    push rdi
    mov rax, [rdi + AS_PML4]
    mov ecx, 39
.level:
    mov rdx, rsi
    shr rdx, cl
    and edx, 511
    lea rdx, [rax + rdx * 8]
    cmp ecx, 12
    je .found
    mov rax, [rdx]
    test al, PTE_P
    jnz .down
    push rdx
    mov edi, 1
    call pmm_alloc_zero
    pop rdx
    test rax, rax
    jz .out
    lock inc qword [user_tables]
    or rax, UF_TABLE
    mov [rdx], rax
.down:
    and rax, [vmm_addr_mask]
    add rax, [phys_base]
    sub ecx, 9
    jmp .level
.found:
    mov rax, rdx
.out:
    pop rdi
    pop rdx
    pop rcx
    ret

; as_fill(RDI = address space, RSI = first page, RDX = end, a page boundary,
; RCX = flags, R8 = bytes to copy in, R9 = how many) -> RAX = 0, or E_NOMEM:
; fresh pages of its own, for a task that does not run yet
as_fill:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rbp, r9
.page:
    xor eax, eax
    cmp r12, r13
    jae .out
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .nomem
    mov rdx, rax
    mov rdi, rbx
    mov rsi, r12
    call as_pte
    test rax, rax
    jz .nomem_page
    lock inc qword [user_pages]
    mov rcx, rdx
    or rcx, r14
    or rcx, PTE_OWN
    mov [rax], rcx
    mov ecx, 4096                       ; its share of the bytes
    cmp rbp, rcx
    cmovb rcx, rbp
    sub rbp, rcx
    mov rdi, rdx
    add rdi, [phys_base]
    mov rsi, r15
    add r15, rcx
    rep movsb
    add r12, 4096
    jmp .page
.nomem_page:
    mov rdi, rdx
    mov esi, 1
    call pmm_free
.nomem:
    mov rax, E_NOMEM
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; as_map_mem(RDI = address space, RSI = memory (a reference, which the
; mapping keeps if it is made), RDX = offset, RCX = bytes, both whole pages,
; R8 = flags) -> RAX = where it is now, or E_FULL or E_NOMEM
as_map_mem:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    pushfq
    cli
    lea rdi, [rbx + AS_LOCK]
    call spin_lock
    mov rax, E_FULL
    cmp dword [rbx + AS_NMAPS], AS_MAX
    jae .unlock
    mov rbp, [rbx + AS_NEXT]            ; never mapped before: nothing to flush
    xor ecx, ecx                        ; first every table it needs, so that
.tables:                                ; nothing is half mapped
    cmp rcx, r14
    jae .map
    mov rdi, rbx
    lea rsi, [rbp + rcx]
    call as_pte
    test rax, rax
    jz .nomem
    add rcx, 4096
    jmp .tables
.map:
    xor ecx, ecx
.page:
    cmp rcx, r14
    jae .mapped
    mov rdi, [r12 + MO_BASE]
    add rdi, r13
    add rdi, rcx
    call vmm_translate                  ; its pages are ours: always mapped
    mov rdx, rax
    mov rdi, rbx
    lea rsi, [rbp + rcx]
    call as_pte
    or rdx, r15
    mov [rax], rdx
    add rcx, 4096
    jmp .page
.mapped:
    imul eax, [rbx + AS_NMAPS], AM_SIZE
    mov [rbx + rax + AS_MAPS + AM_OBJ], r12
    mov [rbx + rax + AS_MAPS + AM_VA], rbp
    mov [rbx + rax + AS_MAPS + AM_LEN], r14
    inc dword [rbx + AS_NMAPS]
    lea rax, [rbp + r14 + 4096]         ; and a guard page
    mov [rbx + AS_NEXT], rax
    mov rax, rbp
    jmp .unlock
.nomem:
    mov rax, E_NOMEM
.unlock:
    lea rdi, [rbx + AS_LOCK]
    call spin_unlock
    popfq
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; as_take(RDI = address space, RSI = where a mapping is) -> RAX = its bytes,
; 0 if there is none: its PTEs cleared and it gone, its reference the
; caller's to drop once the TLBs are flushed (unmap_flush). cap_lock may be
; held. Preserves others.
as_take:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rbx, rdi
    pushfq
    cli
    lea rdi, [rbx + AS_LOCK]
    call spin_lock
    xor ecx, ecx
.find:
    cmp ecx, [rbx + AS_NMAPS]
    jae .none
    imul eax, ecx, AM_SIZE
    lea r8, [rbx + rax + AS_MAPS]
    cmp [r8 + AM_VA], rsi
    je .found
    inc ecx
    jmp .find
.found:
    mov rdx, [r8 + AM_LEN]
    xor ecx, ecx
.page:
    cmp rcx, rdx
    jae .cleared
    push rsi
    add rsi, rcx
    mov rdi, rbx
    call as_pte                         ; its tables are there: never 0
    pop rsi
    mov qword [rax], 0
    add rcx, 4096
    jmp .page
.cleared:
    dec dword [rbx + AS_NMAPS]          ; the last one into its place
    imul eax, [rbx + AS_NMAPS], AM_SIZE
    lea rcx, [rbx + rax + AS_MAPS]
    mov rax, [rcx + AM_OBJ]
    mov [r8 + AM_OBJ], rax
    mov rax, [rcx + AM_VA]
    mov [r8 + AM_VA], rax
    mov rax, [rcx + AM_LEN]
    mov [r8 + AM_LEN], rax
    mov rax, rdx
    jmp .unlock
.none:
    xor eax, eax
.unlock:
    lea rdi, [rbx + AS_LOCK]
    call spin_unlock
    popfq
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; cap_unmap(RDI = a capability), cap_lock held: if its holder has it mapped,
; the mapping's PTEs go, and CAP_MAPLEN says what cap_flush is to flush (0:
; nothing was there). Preserves all.
cap_unmap:
    cmp qword [rdi + CAP_MAPVA], 0
    je .out
    push rax
    push rsi
    push rdi
    mov rsi, [rdi + CAP_MAPVA]
    mov rax, [rdi + CAP_TASK]
    mov rdi, [rax + TK_AS]
    call as_take
    pop rdi
    mov [rdi + CAP_MAPLEN], rax
    pop rsi
    pop rax
.out:
    ret

; cap_flush(RDI = a capability cap_unmap took the mapping of, no lock held):
; the TLBs flushed, then the mapping's reference dropped. Preserves all.
cap_flush:
    push rdx
    push rsi
    push rdi
    xor esi, esi
    xor edx, edx
    xchg rsi, [rdi + CAP_MAPVA]
    xchg rdx, [rdi + CAP_MAPLEN]
    mov rdi, [rdi + CAP_OBJ]
    call unmap_flush
    pop rdi
    pop rsi
    pop rdx
    ret

; unmap_flush(RDI = memory, RSI = where it was mapped, RDX = bytes, 0 for
; nothing): every CPU forgets it, then the mapping's reference goes. No lock
; held. Preserves all.
unmap_flush:
    test rsi, rsi
    jz .out
    test rdx, rdx
    jz .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rdi
    mov rdi, rsi
    mov rsi, rdx
    shr rsi, 12
    call tlb_shootdown
    pop rdi
    call obj_put
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; -----------------------------------------------------------------------------
;  The console
; -----------------------------------------------------------------------------

; h_con_write(EDI = the console, ESI = memory, RDX = offset, RCX = bytes) ->
; RAX = bytes: the text, as lines on the console and the serial log (needs
; RT_CON_WRITE, and RT_MEM_READ on the memory). Bytes below a space but
; newlines show as dots. A task with a channel for its console (TK_OUT)
; sends it there instead, as it is, one message.
h_con_write:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, esi
    mov r13, rdx
    mov r14, rcx
    mov esi, OT_CONSOLE
    mov edx, RT_CON_WRITE
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call obj_put
    mov rax, E_ARG
    cmp r14, CON_WRITE_MAX
    ja .out
    xor eax, eax
    test r14, r14
    jz .out
    lea rdi, [r14 + 1]
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    mov edi, r12d
    mov rsi, r13
    mov rdx, rbx
    mov rcx, r14
    call h_mem_read
    cmp rax, E_ANY
    jae .free
    mov rdi, rbx
    mov rsi, rax
    call cur_task                       ; where the program was run
    mov rdx, [rax + TK_OUT]
    test rdx, rdx
    jnz .to_channel
    mov r11, [rax + TK_CON]
    lea rax, [con_lines]
    call con_call
    mov rax, r14
.free:
    push rax
    mov rdi, rbx
    call kfree
    pop rax
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.to_channel:
    mov rdi, rdx                        ; RDI = the end, RSI = the bytes
    mov rdx, rsi
    mov rsi, rbx
    call con_out
    mov rax, r14
    jmp .free

; con_out(RDI = a task's console's channel end, RSI = text, RDX = bytes): one
; message from it, waiting while its peer has CH_QUEUE_MAX unread; dropped
; once the peer is gone, or the task is killed
con_out:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
.again:
    mov rdi, rbx
    mov rsi, r12
    mov rdx, r13
    call ch_post
    cmp rax, E_FULL
    jne .out
    call cur_task
    test byte [rax + TK_KILL], 1
    jnz .out
    mov edi, 2000
    call thread_sleep_us
    jmp .again
.out:
    pop r13
    pop r12
    pop rbx
    ret

; con_lines(RDI = text, RSI = bytes, with one more to spare after them):
; each line logged, cut at CON_LINE
con_lines:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea r12, [rdi + rsi]                ; the end
.line:
    cmp rbx, r12
    jae .out
    mov r13, rbx                        ; this line's start
.scan:
    cmp rbx, r12
    jae .say
    mov rax, rbx
    sub rax, r13
    cmp rax, CON_LINE
    jae .say
    mov al, [rbx]
    cmp al, 10
    je .newline
    cmp al, ' '
    jae .shown
    mov byte [rbx], '.'
.shown:
    inc rbx
    jmp .scan
.newline:
    mov byte [rbx], 0
    inc rbx
    KLOG "%s", r13
    jmp .line
.say:
    mov al, [rbx]                       ; ended there for now
    push rax
    mov byte [rbx], 0
    KLOG "%s", r13
    pop rax
    mov [rbx], al
    jmp .line
.out:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Loading a program, and waiting for it
; -----------------------------------------------------------------------------

user_load:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56                         ; [rsp] = the entry, [rsp + 8] = a
    mov r12, rdi                        ; buffer of its own, [rsp + 16] = the
    mov r13, rsi                        ; buffer's size, [rsp + 24] = what to
    mov r15, rdx                        ; say if it fails, [rsp + 32] = the
    mov [rsp + 32], rcx                 ; task starting it, [rsp + 40] = the
    mov [rsp + 40], r8                  ; gifts (dwords), [rsp + 48] = what it is given
    mov [rsp + 48], r9                  ; (AW_*: granted, and then wanted)
    mov qword [rsp + 24], E_ARG
    xor r14d, r14d                      ; no task yet
    xor ebp, ebp                        ; no start block yet
    mov [rsp + 8], r14
    push r14
    call log_volume                     ; the boot stick, or the volume chosen
    jnc .volume
    call fat_vol
    jc .no_volume
.volume:
    mov rsi, r12
    lea rdi, [fat_file]
    mov ecx, FAT_FILE_MAX
    call fat_read_file
    jc .no_volume
    lea rbx, [fat_file]
    mov qword [rsp + 24], FAT_FILE_MAX
    cmp rdx, FAT_FILE_MAX
    jbe .read
    cmp rdx, USER_IMAGE_MAX             ; larger: a buffer of its own
    ja .too_big_pop
    lea rdi, [rdx + 8191]               ; a page to spare
    and rdi, -4096
    mov [rsp + 24], rdi
    call vm_alloc
    test rax, rax
    jz .nomem_pop
    mov [rsp + 16], rax
    mov rbx, rax
    mov rsi, r12
    mov rdi, rbx
    mov rcx, [rsp + 24]
    call fat_read_file
    jc .no_volume
.read:
    pop r14
    cmp rax, AXE_HDR                    ; the header, then
    jb .not_axe
    lea rdi, [rbx + rax]                ; past the end of the file, zeroes (a
    mov rcx, [rsp + 16]                 ; section may end before its page does)
    sub rcx, rax
    xor eax, eax
    rep stosb
    mov rax, 'AXIOMEX2'
    cmp [rbx + AXE_MAGIC], rax
    jne .not_axe
    mov rax, [rbx + AXE_TEXT_END]
    mov rcx, [rbx + AXE_RODATA_END]
    mov rdx, [rbx + AXE_DATA_END]
    mov r9, [rbx + AXE_BSS_END]
    mov r10, USER_IMAGE
    cmp rax, r10
    jbe .not_axe
    test eax, 0xFFF
    jnz .not_axe
    test ecx, 0xFFF
    jnz .not_axe
    cmp rcx, rax
    jb .not_axe
    cmp rdx, rcx
    jb .not_axe
    cmp r9, rdx
    jb .not_axe
    mov r11, USER_IMAGE + USER_IMAGE_MAX
    cmp r9, r11
    ja .not_axe
    mov r11, rdx                        ; the file holds all but the zeroes
    sub r11, r10
    cmp r11, [rsp + 16]
    ja .not_axe
    mov r11, [rbx + AXE_ENTRY]          ; and the entry is code
    lea r10, [r10 + AXE_HDR]
    cmp r11, r10
    jb .not_axe
    cmp r11, rax
    jae .not_axe
    mov rax, [rbx + AXE_WANTS]          ; what it wants, and nothing else
    test rax, ~AW_ALL
    jnz .not_axe
    or [rsp + 48], rax

    mov rsi, [rsp + 32]                 ; the task
    test rsi, rsi
    jnz .parent
    call cur_task
    mov rsi, rax
.parent:
    mov rdi, r15
    call task_new
    test rax, rax
    jz .nomem
    mov r14, rax
    mov rdi, [user_out]                 ; spawn_one's: where its console goes,
    test rdi, rdi                       ; instead of where its parent's does
    jz .out_kept
    mov qword [user_out], 0
    xchg rdi, [r14 + TK_OUT]
    call out_drop
.out_kept:
    cmp qword [rsp + 32], 0             ; run from the shell: it writes there
    jne .written
    call con_target
    mov [r14 + TK_CON], rax
.written:
    call as_new
    test rax, rax
    jz .nomem
    mov [r14 + TK_AS], rax
    mov r12, rax                        ; R12 = its address space from here on
    mov rdi, r12                        ; code
    mov rsi, USER_IMAGE
    mov rdx, [rbx + AXE_TEXT_END]
    mov ecx, UF_CODE
    mov r8, rbx
    mov r9, rdx
    sub r9, rsi
    call as_fill
    test rax, rax
    jnz .nomem
    mov rdi, r12                        ; constants
    mov rsi, [rbx + AXE_TEXT_END]
    mov rdx, [rbx + AXE_RODATA_END]
    mov ecx, UF_RO
    or rcx, [vmm_nx]
    lea r8, [rbx + rsi - USER_IMAGE]
    mov r9, rdx
    sub r9, rsi
    call as_fill
    test rax, rax
    jnz .nomem
    mov rdi, r12                        ; data, and zeroes
    mov rsi, [rbx + AXE_RODATA_END]
    mov rdx, [rbx + AXE_BSS_END]
    add rdx, 4095
    and rdx, -4096
    mov ecx, UF_RW
    or rcx, [vmm_nx]
    lea r8, [rbx + rsi - USER_IMAGE]
    mov r9, [rbx + AXE_DATA_END]
    sub r9, rsi
    call as_fill
    test rax, rax
    jnz .nomem
    mov rdi, r12                        ; the stack
    mov rsi, USER_STACK_TOP - USER_STACK_SIZE
    mov rdx, USER_STACK_TOP
    mov ecx, UF_RW
    or rcx, [vmm_nx]
    xor r8d, r8d
    xor r9d, r9d
    call as_fill
    test rax, rax
    jnz .nomem
    mov rax, [rbx + AXE_ENTRY]
    mov [rsp], rax                      ; the file's buffer is free from here
    call user_load_free

    mov edi, 4096                       ; the start block
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbp, rax
    mov rax, [tsc_per_us]
    mov [rbp + SB_TSC_PER_US], rax
    lea rdi, [rbp + SB_ARGS]
    mov rsi, r13
    xor ecx, ecx
.arg:
    cmp ecx, SB_ARGS_MAX
    jae .args
    mov al, [rsi + rcx]
    test al, al
    jz .args
    mov [rdi + rcx], al
    inc ecx
    jmp .arg
.args:
    mov [rbp + SB_ARGS_LEN], ecx
    mov rcx, [gs:PC_CURRENT]            ; its handles: made as the task
    push qword [rcx + TH_TASK]
    mov [rcx + TH_TASK], r14
    mov edi, USER_RING_N
    lea rsi, [str_user_ring]
    call h_ring_new
    cmp rax, E_ANY
    jae .as_us
    mov [rbp + SB_RING], eax
    mov [rbp + SB_RING_MEM], edx
    mov edi, edx
    call user_map
    cmp rax, E_ANY
    jae .as_us
    mov [rbp + SB_RING_VA], rax
    mov rdi, [console_obj]
    call obj_get
    mov esi, RT_CON_WRITE | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .as_us
    mov [rbp + SB_CONSOLE], eax
    cmp qword [rsp + 8 + 32], 0         ; run from the shell: what it wants,
    jne .given                          ; or was granted, and no more
    test qword [rsp + 8 + 48], AW_STORE
    jz .no_store
    mov rdi, r15                        ; its own names in the store
    call st_program
    mov [rbp + SB_STORE], eax
.no_store:
    test qword [rsp + 8 + 48], AW_NET
    jz .no_net
    call sk_program                     ; the network
    mov [rbp + SB_NET], eax
.no_net:
    test qword [rsp + 8 + 48], AW_DESK
    jz .no_desk
    call desk_program                   ; the desktop
    mov [rbp + SB_DESK], eax
.no_desk:
    test qword [rsp + 8 + 48], AW_FILES
    jz .no_files
    xor esi, esi
    test qword [rsp + 8 + 48], AW_UPDATE
    jz .files
    mov esi, RT_FS_KERNEL               ; and a new kernel
.files:
    call files_program                  ; the files, on every volume
    mov [rbp + SB_FILES], eax
.no_files:
    test qword [rsp + 8 + 48], AW_SOUND
    jz .given
    call snd_program                    ; the speakers
    mov [rbp + SB_SOUND], eax
.given:
    xor eax, eax
    mov esi, [rsp + 8 + 40]             ; and what it is given
    test esi, esi
    jz .as_us
    mov rdi, [rsp + 8 + 32]
    mov rdx, r14
    call task_give
    cmp rax, E_ANY
    jae .as_us
    mov [rbp + SB_GIFT], eax
    call gift_slot
    mov esi, [rsp + 8 + 44]             ; a second
    test esi, esi
    jz .gifts
    mov rdi, [rsp + 8 + 32]
    mov rdx, r14
    call task_give
    cmp rax, E_ANY
    jae .as_us
    mov [rbp + SB_GIFT2], eax
    call gift_slot
.gifts:
    xor eax, eax
.as_us:
    mov rcx, [gs:PC_CURRENT]
    pop qword [rcx + TH_TASK]
    cmp rax, E_ANY
    jae .refused
    mov rdi, r12
    mov rsi, USER_START
    lea rdx, [rsi + 4096]
    mov ecx, UF_RO
    or rcx, [vmm_nx]
    mov r8, rbp
    mov r9d, 4096
    call as_fill
    test rax, rax
    jnz .nomem
    mov rdi, rbp
    call kfree
    xor ebp, ebp

    mov rdi, [rsp]                      ; its first thread
    mov rsi, USER_STACK_TOP
    mov edx, USER_START
    mov rcx, r14
    call user_thread
    test rax, rax
    jz .nomem
    mov rbx, rax
    or qword [rbx + TH_FLAGS], TF_FIRST
    mov rdi, rbx
    call thread_start
    lock inc qword [user_started]
    mov rax, r14
    mov rdx, rbx
    jmp .out

.too_big_pop:
    pop r14
    KLOG "run: %s is larger than %u bytes", r12, qword USER_IMAGE_MAX
    mov qword [rsp + 24], E_RANGE
    jmp .fail
.nomem_pop:
    pop r14
    jmp .nomem
.no_volume:
    pop r14
    jmp .fail
.not_axe:
    KLOG "run: %s is not an Axiom program", r12
    jmp .fail
.refused:
    mov [rsp + 24], rax
    mov rdi, rax
    call err_text
    KLOG "run: %s", rax
    jmp .fail
.nomem:
    KLOG "run: out of memory"
    mov qword [rsp + 24], E_NOMEM
.fail:
    call user_load_free
    test rbp, rbp
    jz .no_block
    mov rdi, rbp
    call kfree
.no_block:
    test r14, r14                       ; its tables and pages with it
    jz .none
    mov rdi, r14
    call obj_put
.none:
    xor eax, eax
    mov rdx, [rsp + 24]
.out:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; user_load_free: from user_load, its buffer for a file larger than
; fat_file, if it has one (at its [rsp + 8]). Preserves all.
user_load_free:
    push rax
    push rdi
    xor edi, edi
    xchg rdi, [rsp + 32]
    test rdi, rdi
    jz .out
    call vm_free
.out:
    pop rdi
    pop rax
    ret

user_wait:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
.join:                                  ; on the main thread, it loads what the
    mov rax, [gs:PC_CURRENT]            ; program starts meanwhile
    cmp rax, [main_thread]
    jne .joined
    call spawn_service
    RDTSC64
    imul rdx, [tsc_per_us], 1000
    add rdx, rax
    lea rdi, [r12 + TH_WQ]
    lea rsi, [r12 + TH_ENDED]
    call wq_wait
    test eax, eax
    jz .join
.joined:
    mov rdi, r12
    call thread_join                    ; gives the reference back
    mov r12, rax
    mov rdi, rbx                        ; the first thread ended: so do the rest
    call task_kill
.reap:
    call sched_reap
    mov rax, [gs:PC_CURRENT]
    cmp rax, [main_thread]
    jne .reaped
    call spawn_service
.reaped:
    cmp dword [rbx + TK_THREADS], 0
    je .ended
    mov edi, 100
    call thread_sleep_us
    jmp .reap
.ended:
    mov rax, r12
    pop r12
    pop rbx
    ret

; user_said(RDI = task, RSI = what its first thread returned): how it ended
user_said:
    lea rcx, [rdi + OB_NAME]
    test byte [rdi + TK_KILL], 2
    jnz .fault
    cmp rsi, E_KILLED
    je .killed
    KLOG "run: %s exited with %d", rcx, rsi
    ret
.fault:
    KLOG "run: %s ended by a fault", rcx
    ret
.killed:
    lock inc qword [user_kills]
    KLOG "run: %s stopped", rcx
    ret

; -----------------------------------------------------------------------------
;  The shell: programs by name, several at once, and their ends
; -----------------------------------------------------------------------------

; run <program> [arguments]: as typing its name (+net and '&' too)
cmd_run:
    push r12
    mov rsi, [sh_args]
    call arg_split
    cmp byte [rsi], 0
    je .usage
    mov r12, rdi                        ; the arguments
    mov rdi, rsi
    mov rsi, r12
    mov edx, [sh_grants]
    movzx ecx, byte [sh_bg]
    call user_start
    jmp .out
.usage:
    KLOG "usage: run <program> [arguments]: /EFI/AXIOM/<PROGRAM>.AXE on the boot stick"
.out:
    pop r12
    ret

; user_found(RDI = a program's name, or a path) -> CF if there is no such
; program (said nothing). Preserves all but RAX.
user_found:
    push rcx
    push rdx
    push rsi
    push rdi
    push r14
    mov rsi, rdi
    call user_path
    call log_volume                     ; where user_load looks
    jnc .volume
    call fat_vol
    jc .out
.volume:
    lea rsi, [user_path_buf]
    mov byte [fat_hush], 1
    call fat_resolve
    mov byte [fat_hush], 0
    jc .out
    test byte [fat_ent + 11], 0x10      ; a file, not a folder
    jz .out
    stc
.out:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; user_start(RDI = a program's name or path, RSI = its arguments, EDX = what
; it is granted beyond what it wants (AW_*), ECX = 1 for the background):
; the program runs in a job of this terminal's. In front, the prompt waits
; for it; ctrl+C stops it. -> CF if it did not start (said why)
user_start:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    mov r13d, edx
    mov r15d, ecx
    mov r14, rdi
    lea rbx, [user_jobs]                ; a slot
    xor eax, eax
.slot:
    cmp eax, USER_JOBS
    jae .full
    cmp qword [rbx + JB_TASK], 0
    je .free
    add rbx, JB_SIZE
    inc eax
    jmp .slot
.free:
    mov rsi, r14
    call user_path
    lea rdi, [user_path_buf]
    mov rsi, r12
    lea rdx, [user_name_buf]
    xor ecx, ecx
    xor r8d, r8d
    mov r9d, r13d
    call user_load
    test rax, rax
    jz .fail
    mov [rbx + JB_TASK], rax
    mov [rbx + JB_FIRST], rdx
    mov r14, rax
    call con_target                     ; said there when it ends
    mov [rbx + JB_CON], rax
    xor eax, eax
    test r15d, r15d
    jz .flags
    mov eax, JF_BACK
.flags:
    mov [rbx + JB_FLAGS], eax
    lea rdi, [user_waiter]
    mov rsi, rbx
    lea rdx, [str_user_wait]
    xor ecx, ecx
    call thread_spawn
    test rax, rax
    jz .no_waiter
    mov rdi, rax
    call thread_detach
    test r15d, r15d
    jnz .back
    call shell_wait
    clc
    jmp .out
.back:
    lea rax, [r14 + OB_NAME]
    KLOG "run: %s in the background, task %u ('tasks stop %u' stops it)", rax, qword [r14 + OB_ID], qword [r14 + OB_ID]
    clc
    jmp .out
.no_waiter:                             ; then here, at once
    mov rdi, r14
    call task_kill
    mov rdi, rbx
    call user_waiter
    call user_service
    stc
    jmp .out
.full:
    KLOG "run: %u programs run from here already ('tasks' lists them)", USER_JOBS
.fail:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; user_path(RSI = a program's name, or a path): user_path_buf = its path,
; user_name_buf = its name, upper case and without a path or an extension
user_path:
    push rbx
    lea rdi, [user_path_buf]
    mov rbx, rsi
.slash:                                 ; a path is used as it is
    mov al, [rbx]
    test al, al
    jz .name
    cmp al, '/'
    je .path
    inc rbx
    jmp .slash
.path:
    xor ecx, ecx
.copy_path:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .last
    inc ecx
    cmp ecx, USER_NAME_MAX * 2 - 1
    jb .copy_path
    mov byte [rdi + rcx], 0
.last:                                  ; its name is the last part
    lea rbx, [rsi + rcx]
.back:
    cmp rbx, rsi
    je .named
    cmp byte [rbx - 1], '/'
    je .named
    dec rbx
    jmp .back
.name:                                  ; a name: /EFI/AXIOM/<NAME>.AXE
    push rsi
    lea rsi, [str_user_dir]
.dir:
    lodsb
    stosb
    test al, al
    jnz .dir
    dec rdi
    pop rsi
    mov rbx, rsi
    xor ecx, ecx
    xor edx, edx                        ; 1 once it has a dot
.copy_name:
    mov al, [rsi + rcx]
    test al, al
    jz .ext
    cmp al, '.'
    jne .upper
    mov edx, 1
.upper:
    cmp al, 'a'
    jb .put
    cmp al, 'z'
    ja .put
    sub al, 32
.put:
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, USER_NAME_MAX - 1
    jb .copy_name
.ext:
    add rdi, rcx
    test edx, edx
    jnz .ended
    mov dword [rdi], '.AXE'
    add rdi, 4
.ended:
    mov byte [rdi], 0
.named:                                 ; RBX = the name, up to a dot
    lea rdi, [user_name_buf]
    xor ecx, ecx
.copy:
    mov al, [rbx + rcx]
    test al, al
    jz .done
    cmp al, '.'
    je .done
    cmp al, 'a'
    jb .keep
    cmp al, 'z'
    ja .keep
    sub al, 32
.keep:
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, USER_NAME_MAX - 1
    jb .copy
.done:
    mov byte [rdi + rcx], 0
    pop rbx
    ret

; user_waiter(RDI = a job): a thread of its own, until its program has ended
user_waiter:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + JB_TASK]
    mov rsi, [rbx + JB_FIRST]
    call user_wait
    mov [rbx + JB_EXIT], rax
    lock or dword [rbx + JB_FLAGS], JF_ENDED
    mov byte [user_pending], 1
    mov rdi, [main_thread]
    call thread_unpark
    xor eax, eax
    pop rbx
    ret

; user_service: from the main loop. A program that ended is said where it
; was run, and goes; a prompt that waited for it comes back.
user_service:
    call lx_service                     ; and Linux's (linux.asm)
    call spawn_service
    cmp byte [user_pending], 0
    je .out
    mov byte [user_pending], 0
    push rbx
    push r12
    lea rbx, [user_jobs]
    xor r12d, r12d
.job:
    cmp r12d, USER_JOBS
    jae .done
    test dword [rbx + JB_FLAGS], JF_ENDED
    jz .next
    mov rdi, [rbx + JB_TASK]
    mov rsi, [rbx + JB_EXIT]
    mov r11, [rbx + JB_CON]
    lea rax, [user_said]
    call con_call
    mov rdi, [rbx + JB_TASK]
    push qword [rbx + JB_CON]
    push qword [rbx + JB_FLAGS]
    push qword [rbx + JB_EXIT]
    mov qword [rbx + JB_TASK], 0        ; the slot is free
    mov dword [rbx + JB_FLAGS], 0
    call obj_put
    pop rdx
    pop rax
    pop r11
    test eax, JF_BACK
    jnz .next
    test r11, r11
    jz .next
    test rdx, rdx                       ; for && and || after it
    setnz byte [r11 + TW_SH_FAILED]
    lea rax, [shell_resume]
    call con_call
.next:
    add rbx, JB_SIZE
    inc r12d
    jmp .job
.done:
    pop r12
    pop rbx
.out:
    ret

; user_forget(RDI = a terminal): ctrl+C there; the program in front there
; is stopped (not those in the background)
user_forget:
    push rax
    xor eax, eax
    jmp user_stop

; user_close(RDI = a terminal): it closed; every program run there is
; stopped, and said in the first terminal
user_close:
    push rax
    mov eax, 1

; user_stop(RDI = a terminal, EAX = 1 for every job there, 0 for the one in
; front; pushed RAX): the end of user_forget and user_close
user_stop:
    push rbx
    push rcx
    push rdi
    push rsi
    mov rsi, rdi
    mov ecx, eax
    lea rbx, [user_jobs]
    xor eax, eax
.job:
    cmp eax, USER_JOBS
    jae .done
    cmp qword [rbx + JB_TASK], 0
    je .next
    cmp [rbx + JB_CON], rsi
    jne .next
    test ecx, ecx
    jnz .stop
    test dword [rbx + JB_FLAGS], JF_BACK
    jnz .next
.stop:
    mov rdi, [rbx + JB_TASK]
    push rax
    push rcx
    push rsi
    call task_kill
    pop rsi
    pop rcx
    pop rax
    test ecx, ecx
    jz .next
    mov qword [rbx + JB_CON], 0         ; its terminal is gone: nothing waits
    lock or dword [rbx + JB_FLAGS], JF_BACK
.next:
    add rbx, JB_SIZE
    inc eax
    jmp .job
.done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; user [test]
cmd_user:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je user_list
    call arg_split
    lea rdi, [str_ob_test]
    call streq
    test eax, eax
    jnz user_test
    KLOG "usage: user [test]"
    ret

user_list:
    push rbx
    push rcx
    lea rdi, [user_running]             ; the programs running, by name
    lea rbx, [user_jobs]
    xor ecx, ecx
.job:
    cmp ecx, USER_JOBS
    jae .listed
    mov rax, [rbx + JB_TASK]
    test rax, rax
    jz .next
    lea rdx, [user_running + USER_RUNNING - OB_NAME_LEN - 3]
    cmp rdi, rdx
    jae .listed
    lea rdx, [user_running]
    cmp rdi, rdx
    je .name
    mov word [rdi], ', '
    add rdi, 2
.name:
    lea rsi, [rax + OB_NAME]
.char:
    lodsb
    test al, al
    jz .next
    stosb
    jmp .char
.next:
    add rbx, JB_SIZE
    inc ecx
    jmp .job
.listed:
    mov byte [rdi], 0
    lea rax, [user_running]
    cmp byte [rax], 0
    jne .say
    lea rax, [str_user_none]
.say:
    KLOG "  programs: %u started, %u ended by a fault, %u stopped; running: %s", qword [user_started], qword [user_faults], qword [user_kills], rax
    KLOG "  their pages: %u, and %u page tables", qword [user_pages], qword [user_tables]
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  user test: programs that check themselves, faults of every kind, and
;  killing; then nothing may be left
; -----------------------------------------------------------------------------
user_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov qword [ut_fails], 0
    KLOG "user test: ring 3 on %u CPUs", qword [cpus_online]
    lea rdi, [str_ut_test]              ; once to warm up, before the count
    lea rsi, [str_ut_args]
    xor ecx, ecx
    call ut_run
    jc .no_program
    lea rbx, [str_ut_test]
    call ut_expect_ok
    lea rdi, [ut_base]
    call ut_counts

    lea rdi, [str_ut_test]              ; the self-test
    lea rsi, [str_ut_args]
    xor ecx, ecx
    call ut_run
    jc .no_program
    lea rbx, [str_ut_test]
    call ut_expect_ok

    lea r12, [ut_faults_list]           ; a fault of each kind ends the task
.fault:
    mov r13, [r12]
    test r13, r13
    jz .kills
    lea rdi, [str_ut_fault]
    mov rsi, r13
    xor ecx, ecx
    call ut_run
    jc .no_program
    cmp rax, E_FAULT
    jne .fault_bad
    test edx, 2
    jz .fault_bad
    KLOG "user test: fault %s: the task ended, the kernel went on", r13
    jmp .fault_next
.fault_bad:
    KLOG "user test: FAILED: fault %s ended with %d (kill %u)", r13, rax, rdx
    inc qword [ut_fails]
.fault_next:
    add r12, 8
    jmp .fault

.kills:
    lea r12, [ut_kill_list]             ; tasks that never end on their own
.kill:
    mov r13, [r12]
    test r13, r13
    jz .leaks
    lea rdi, [str_ut_spin]
    mov rsi, r13
    mov ecx, [r12 + 24]                 ; killed after that long, or not
    call ut_run
    jc .no_program
    mov r14, rax
    mov r15, rdx
    KLOG "user test: spin %s: killed, gone in %u us; it returned %d", r13, rcx, rax
    cmp rcx, UT_KILL_US
    ja .kill_bad
    mov rax, [r12 + 8]                  ; how it should end
    cmp r14, rax
    jne .kill_bad
    mov eax, r15d
    and eax, 2
    cmp rax, [r12 + 16]
    je .kill_next
.kill_bad:
    KLOG "user test: FAILED: spin %s (kill %u)", r13, r15
    inc qword [ut_fails]
.kill_next:
    add r12, 32
    jmp .kill

.leaks:
    mov r12d, 100                       ; tasks a program started end after it
.settle:
    call sched_reap
    mov rax, [ty_task + TY_LIVE]
    cmp rax, [ut_base]
    jbe .settled
    mov edi, 10000
    call thread_sleep_us
    dec r12d
    jnz .settle
.settled:
    lea rdi, [ut_now]
    call ut_counts
    KLOG "user test: %u tasks (%u before), %u threads (%u), %u blocks of memory (%u), %u rings (%u), %u heap objects (%u), %u vm mappings (%u), %u user pages (%u), %u user page tables (%u), %u channel ends (%u)", qword [ut_now], qword [ut_base], qword [ut_now + 8], qword [ut_base + 8], qword [ut_now + 16], qword [ut_base + 16], qword [ut_now + 24], qword [ut_base + 24], qword [ut_now + 32], qword [ut_base + 32], qword [ut_now + 40], qword [ut_base + 40], qword [ut_now + 48], qword [ut_base + 48], qword [ut_now + 56], qword [ut_base + 56], qword [ut_now + 64], qword [ut_base + 64]
    xor ecx, ecx
.compare:
    lea rdx, [ut_now]
    mov rax, [rdx + rcx * 8]
    lea rdx, [ut_base]
    cmp rax, [rdx + rcx * 8]
    jne .leak
    inc ecx
    cmp ecx, UT_COUNTS
    jb .compare
    jmp .verdict
.leak:
    KLOG "user test: FAILED: not all of it came back"
    inc qword [ut_fails]
.verdict:
    cmp qword [ut_fails], 0
    jne .failed
    KLOG "user test: passed"
    jmp .out
.failed:
    KLOG "user test: FAILED, %u problems", qword [ut_fails]
    jmp .out
.no_program:
    KLOG "user test: FAILED: the programs are not on the boot stick (/EFI/AXIOM/*.AXE)"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ut_run(RDI = a program's name, RSI = arguments, ECX = microseconds after
; which to kill it, 0 = never) -> RAX = what its first thread returned, EDX
; = its TK_KILL bits, RCX = microseconds from the kill to its end; CF if it
; could not be loaded
ut_run:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13d, ecx
    mov rsi, rdi
    call user_path
    lea rdi, [user_path_buf]
    mov rsi, r12
    lea rdx, [user_name_buf]
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d                        ; what it wants
    call user_load
    test rax, rax
    jz .none
    mov rbx, rax
    mov r12, rdx
    xor r14d, r14d
    test r13d, r13d
    jz .wait
    mov edi, r13d
    call thread_sleep_us
    RDTSC64
    mov r14, rax
    mov rdi, rbx
    call task_kill
.wait:
    mov rdi, rbx
    mov rsi, r12
    call user_wait
    mov r12, rax
    xor ecx, ecx
    test r14, r14
    jz .took
    RDTSC64
    sub rax, r14
    xor edx, edx
    div qword [tsc_per_us]
    mov rcx, rax
.took:
    mov r13d, [rbx + TK_KILL]
    mov rdi, rbx
    call obj_put
    mov rax, r12
    mov edx, r13d
    clc
    jmp .out
.none:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ut_expect_ok(RBX = its name, RAX = what it returned, EDX = kill bits:
; killed once it ended, as every task is, but not by a fault)
ut_expect_ok:
    test rax, rax
    jnz .bad
    test edx, 2
    jnz .bad
    ret
.bad:
    KLOG "user test: FAILED: %s returned %d (kill %u)", rbx, rax, rdx
    inc qword [ut_fails]
    ret

; ut_counts(RDI = UT_COUNTS qwords): what is live, once the dead are gone
ut_counts:
    push rdi
    mov edi, 20000
    call thread_sleep_us
    call sched_reap
    pop rdi
    mov rax, [ty_task + TY_LIVE]
    mov [rdi], rax
    mov rax, [thread_count]
    mov [rdi + 8], rax
    mov rax, [ty_memory + TY_LIVE]
    mov [rdi + 16], rax
    mov rax, [ty_ring + TY_LIVE]
    mov [rdi + 24], rax
    mov rax, [heap_objects]
    mov [rdi + 32], rax
    mov rax, [vm_count]
    mov [rdi + 40], rax
    mov rax, [user_pages]
    mov [rdi + 48], rax
    mov rax, [user_tables]
    mov [rdi + 56], rax
    mov rax, [ty_channel + TY_LIVE]
    mov [rdi + 64], rax
    ret
UT_COUNTS       equ 9

section .rodata
str_ot_console: db 'console', 0
align 4
gift_slots:     dd OT_DESK, SB_DESK, OT_FILES, SB_FILES, OT_NET, SB_NET, OT_STORE, SB_STORE
                dd OT_SOUND, SB_SOUND
                dd 0, 0
str_user_oom:   db 'Out of memory for the console', 0
str_user_ring:  db 'ring', 0
str_user_mem:   db 'memory', 0
str_user_event: db 'event', 0
str_user_wait:  db 'run', 0
str_user_none:  db 'none', 0
str_user_dir:   db '/EFI/AXIOM/', 0
str_ut_test:    db 'test', 0
str_ut_args:    db 'one two  three', 0
str_ut_fault:   db 'fault', 0
str_ut_spin:    db 'spin', 0
str_utf_null:   db 'null', 0
str_utf_write:  db 'write', 0
str_utf_exec:   db 'exec', 0
str_utf_kernel: db 'kernel', 0
str_utf_priv:   db 'priv', 0
str_utf_ud:     db 'ud', 0
str_utf_div:    db 'div', 0
str_utf_stack:  db 'stack', 0
str_utf_gp:     db 'gp', 0
str_utf_int:    db 'int', 0
str_utf_io:     db 'io', 0
str_utf_unmap:  db 'unmap', 0
str_utf_close:  db 'close', 0
str_utf_revoke: db 'revoke', 0
str_uts_4:      db '4', 0
str_uts_wait:   db '3 wait', 0
str_uts_fault:  db '3 fault', 0
str_uts_syscalls: db '3 calls', 0
align 8
ut_faults_list: dq str_utf_null, str_utf_write, str_utf_exec, str_utf_kernel, str_utf_priv
                dq str_utf_ud, str_utf_div, str_utf_stack, str_utf_gp, str_utf_int
                dq str_utf_io, str_utf_unmap, str_utf_close, str_utf_revoke, 0
; each: its arguments, what it returns, its kill bit 1, microseconds to the kill
ut_kill_list:   dq str_uts_4, E_KILLED, 0, 20000         ; spinning in ring 3
                dq str_uts_wait, E_KILLED, 0, 20000      ; parked in its ring
                dq str_uts_syscalls, E_KILLED, 0, 20000  ; in and out of the kernel
                dq str_uts_fault, E_KILLED, 2, 0         ; another thread faults: no kill
                dq 0
sys_table:      dq sys_exit, sys_ring_enter, sys_ring_new, sys_mem_new, sys_map
                dq sys_event_new, sys_thread_new, sys_yield, sys_unmap
                dq sys_spawn, sys_channel_new, sys_window_new, sys_sound_new
                dq sys_tls, sys_futex_wait, sys_futex_wake, sys_info

section .bss
alignb 8
console_obj:    resq 1
spawn_list:     resq 1                  ; requests for the main thread, oldest first
user_out:       resq 1                  ; spawn_one's channel for user_load's task
spawn_tail:     resq 1
spawn_lock:     resd 1
alignb 8
user_jobs:      resb USER_JOBS * JB_SIZE ; the programs run from the shell
user_started:   resq 1
user_faults:    resq 1
user_kills:     resq 1
user_pages:     resq 1                  ; pages of programs' own, in all
user_tables:    resq 1                  ; and their page tables
ut_fails:       resq 1
ut_base:        resq UT_COUNTS
ut_now:         resq UT_COUNTS
user_pending:   resb 1                  ; the program ended: user_service says so
user_path_buf:  resb USER_NAME_MAX * 2
user_name_buf:  resb USER_NAME_MAX
user_running:   resb USER_RUNNING         ; 'user': their names
