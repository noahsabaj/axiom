; =============================================================================
;  lxproc.asm - Linux processes: fork, vfork, execve, wait4, groups, kill
;
;  Every process is on lx_procs (LP_NEXT, in the order they started, under
;  lx_procs_spin, a spinlock taken with interrupts off), which holds a
;  reference to its task until it is waited for: its parent's wait4 or
;  waitid takes it off, or, if it has no parent (the one 'linux' started,
;  or one whose parent ended first) or its parent ignores SIGCHLD, it goes
;  as it ends. A process that ends tells its parent (its exit signal,
;  SIGCHLD, and lx_poll_kick for the waits) and leaves its children
;  without one; the session's leader ending ends the whole session.
;
;  fork, vfork and clone without CLONE_THREAD make a process: a task of its
;  own, its descriptors (the open files shared), a copy of its signals'
;  actions, and either a copy of the memory (lx_as_fork: each page of its
;  own copied, the file cache's shared as they were) or, with CLONE_VM, the
;  same memory, the parent waiting (CLONE_VFORK) until the child execs or
;  ends. Its one thread starts from a copy of the caller's frame, RAX 0.
;
;  execve maps a program into a new address space and the process goes on
;  in it: the old one released, descriptors with FD_CLOEXEC closed, handled
;  signals back to SIG_DFL, the thread's registers, TLS and SIMD state
;  clean. A file starting '#!' runs the interpreter it names.
;
;  A process starts in its parent's process group and session; setpgid and
;  setsid change them, and the terminal's foreground group (TIOCSPGRP) is
;  what its ctrl+C and the like signal. kill reaches a process, a group,
;  or the session's every other process.
; =============================================================================

CLONE_FILES     equ 0x00000400
CLONE_PIDFD     equ 0x00001000
CLONE_VFORK     equ 0x00004000
CLONE_NEWS      equ 0x7E020000              ; the namespaces: none here
CSIGNAL         equ 0xFF                    ; clone's exit signal
WNOHANG         equ 1
WUNTRACED       equ 2
WEXITED         equ 4
WCONTINUED      equ 8
WNOWAIT         equ 0x01000000
WALL_FLAGS      equ 0xE0000000              ; __WNOTHREAD, __WALL, __WCLONE
P_ALL           equ 0
P_PID           equ 1
P_PGID          equ 2
CLD_EXITED      equ 1
CLD_KILLED      equ 2
SA_NOCLDWAIT    equ 2
LX_SHEBANG      equ 256                     ; a script's '#!' line, at most
LX_EXEC_DEPTH   equ 4                       ; interpreters run by interpreters

section .text

; -----------------------------------------------------------------------------
;  The list
; -----------------------------------------------------------------------------

; lx_procs_lock -> RAX = the flags lx_procs_unlock takes: the list is this
; CPU's, interrupts off. Preserves others.
lx_procs_lock:
    pushfq
    cli
    push rdi
    lea rdi, [lx_procs_spin]
    call spin_lock
    pop rdi
    pop rax
    ret

; lx_procs_unlock(RAX = lx_procs_lock's flags). Preserves all.
lx_procs_unlock:
    push rdi
    lea rdi, [lx_procs_spin]
    call spin_unlock
    pop rdi
    push rax
    popfq
    ret

; lx_proc_add(RDI = process): at the end of the list, which takes the
; caller's reference to its task. Preserves all.
lx_proc_add:
    push rax
    push rcx
    call lx_procs_lock
    mov qword [rdi + LP_NEXT], 0
    lea rcx, [lx_procs]                 ; RCX = the link that will point to it
.walk:
    cmp qword [rcx], 0
    je .here
    mov rcx, [rcx]
    add rcx, LP_NEXT
    jmp .walk
.here:
    mov [rcx], rdi
    call lx_procs_unlock
    pop rcx
    pop rax
    ret

; lx_proc_unlink(RDI = process), the list's lock held: off the list (its
; reference now the caller's), if it is on it -> CF if it was not.
; Preserves all.
lx_proc_unlink:
    push rax
    push rcx
    lea rcx, [lx_procs]
.walk:
    mov rax, [rcx]
    test rax, rax
    jz .absent
    cmp rax, rdi
    je .found
    lea rcx, [rax + LP_NEXT]
    jmp .walk
.found:
    mov rax, [rdi + LP_NEXT]
    mov [rcx], rax
    mov dword [rdi + LP_REAPED], 1
    clc
    jmp .out
.absent:
    stc
.out:
    pop rcx
    pop rax
    ret

; lx_proc_find(EDI = a pid), the list's lock held -> RAX = that process, or
; 0. Preserves others.
lx_proc_find:
    mov rax, [lx_procs]
.walk:
    test rax, rax
    jz .out
    cmp [rax + LP_PID], edi
    je .out
    mov rax, [rax + LP_NEXT]
    jmp .walk
.out:
    ret

; lx_proc_gone(RDI = a process whose last thread is ending, its descriptors
; closed): it has ended. Its children have no parent now (those that ended
; go); its parent is told, or, with none, it goes; a session's leader takes
; the session with it.
lx_proc_gone:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    xor r13d, r13d                      ; R13 = processes off the list (by LP_NEXT)
    call lx_procs_lock
    mov r12, rax
    mov rdi, [lx_procs]                 ; its children
.child:
    test rdi, rdi
    jz .children_done
    mov rcx, [rdi + LP_NEXT]
    cmp [rdi + LP_PARENT], rbx
    jne .child_next
    mov qword [rdi + LP_PARENT], 0
    cmp dword [rdi + LP_ENDED], 0
    je .child_next
    call lx_proc_unlink                 ; ended already: nobody will wait for it
    mov [rdi + LP_NEXT], r13
    mov r13, rdi
.child_next:
    mov rdi, rcx
    jmp .child
.children_done:
    mov dword [rbx + LP_ENDED], 1       ; (wait4 sees it from here on)
    mov rdi, [rbx + LP_PARENT]
    test rdi, rdi
    jz .reap
    mov esi, [rbx + LP_EXITSIG]
    test esi, esi
    jz .told
    call lx_signal_proc
.told:
    mov rax, [rdi + LP_SIGACTS]         ; a parent ignoring SIGCHLD keeps no zombies
    cmp qword [rax + (SIGCHLD - 1) * LSA_SIZE + LSA_HANDLER], SIG_IGN
    je .reap
    test dword [rax + (SIGCHLD - 1) * LSA_SIZE + LSA_FLAGS], SA_NOCLDWAIT
    jz .leader
.reap:
    mov rdi, rbx
    call lx_proc_unlink
    jc .leader
    mov [rbx + LP_NEXT], r13
    mov r13, rbx
.leader:
    mov eax, [rbx + LP_PID]             ; a session's leader: the rest goes too
    cmp eax, [rbx + LP_SID]
    jne .unlock
    mov rdi, [lx_procs]
.kill:
    test rdi, rdi
    jz .unlock
    cmp [rdi + LP_SID], eax
    jne .kill_next
    cmp rdi, rbx
    je .kill_next
    cmp dword [rdi + LP_ENDED], 0
    jne .kill_next
    mov esi, SIGKILL
    call lx_signal_proc
.kill_next:
    mov rdi, [rdi + LP_NEXT]
    jmp .kill
.unlock:
    mov rax, r12
    call lx_procs_unlock
    lea rdi, [rbx + LP_WQ]              ; a vfork's parent, and the waits
    call wq_wake
    call lx_poll_kick
.drop:
    test r13, r13
    jz .out
    mov rdi, [r13 + LP_TASK]
    mov r13, [r13 + LP_NEXT]
    call obj_put
    jmp .drop
.out:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  fork, vfork, clone
; -----------------------------------------------------------------------------

; fork()
lx_sys_fork:
    mov edi, SIGCHLD
    jmp lx_fork_plain

; vfork()
lx_sys_vfork:
    mov edi, CLONE_VM | CLONE_VFORK | SIGCHLD
lx_fork_plain:
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
; lx_fork(EDI = clone's flags, RSI = the child's stack or 0, RDX =
; parent_tid, RCX = child_tid, R8 = tls), RBP = the caller's frame -> RAX =
; the child's pid, or -errno: a process
lx_fork:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48                         ; [rsp] = the child, [+8] its task,
    mov ebx, edi                        ; [+16] its thread, [+24] its pid,
    mov r12, rsi                        ; [+32] this process
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rax, -EINVAL
    test ebx, CLONE_SIGHAND             ; actions shared need memory shared
    jz .sighand_ok
    test ebx, CLONE_VM
    jz .out
.sighand_ok:
    test ebx, CLONE_FILES | CLONE_PIDFD ; not here
    jnz .out
    mov rax, -EPERM
    test ebx, CLONE_NEWS
    jnz .out
    test ebx, CLONE_SETTLS
    jz .tls_ok
    mov rcx, USER_TOP
    cmp r15, rcx
    jae .out
.tls_ok:
    call lx_cur_proc
    mov [rsp + 32], rax
    lea rdi, [rax + LP_COMM]            ; a task of its own, nobody's child
    xor esi, esi                        ; (its end is the process's own)
    call task_new
    test rax, rax
    jz .nomem_none
    mov [rsp + 8], rax
    call lx_cur_as                      ; its memory: ours, or a copy
    mov rdi, rax
    test ebx, CLONE_VM
    jz .copy_as
    lock inc dword [rdi + AS_REFS]
    jmp .as
.copy_as:
    call lx_as_fork
    test rax, rax
    jz .nomem
.as:
    mov rcx, [rsp + 8]
    mov [rcx + TK_AS], rax
    mov edi, LP_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rsp], rax
    mov rcx, [rsp + 8]
    mov [rcx + TK_LX], rax
    mov [rax + LP_TASK], rcx
    mov rdi, rax
    mov rsi, [rsp + 32]
    call lx_proc_copy
    test rax, rax
    jnz .failed
    mov eax, 1
    lock xadd [lx_next_pid], eax
    add eax, LX_PID_FIRST
    mov [rsp + 24], eax
    mov rcx, [rsp]
    mov [rcx + LP_PID], eax
    mov eax, ebx
    and eax, CSIGNAL
    mov [rcx + LP_EXITSIG], eax
    mov rax, [rsp + 32]
    mov [rcx + LP_PARENT], rax
    mov edx, [rax + LP_PID]
    mov [rcx + LP_PPID], edx
    mov dword [rcx + LP_LIVE], 1
    test ebx, CLONE_VFORK
    jz .frame
    mov dword [rcx + LP_VFORK], 1
.frame:
    mov edi, LX_FR_SIZE                 ; its thread: from our frame, RAX 0
    call kmalloc
    test rax, rax
    jz .nomem
    mov rdi, rax
    mov rsi, rbp
    mov ecx, LX_FR_SIZE / 8
    rep movsq
    mov qword [rax + FR_RAX], 0
    test r12, r12
    jz .same_stack
    mov [rax + FR_RSP], r12
.same_stack:
    mov rdi, [rsp + 8]
    mov rsi, rax
    call lx_thread_new
    test rax, rax
    jz .nomem
    mov [rsp + 16], rax
    mov rdi, rax                        ; RDI = it, RSI = this thread
    mov rsi, [gs:PC_CURRENT]
    mov eax, [rsp + 24]
    mov [rdi + TH_TID], eax
    mov rax, [rsi + TH_FSBASE]
    test ebx, CLONE_SETTLS
    cmovnz rax, r15
    mov [rdi + TH_FSBASE], rax
    mov rax, [rsi + TH_GSBASE]
    mov [rdi + TH_GSBASE], rax
    mov rax, [rsi + TH_SIGMASK]
    mov [rdi + TH_SIGMASK], rax
    test ebx, CLONE_VM                  ; our alternate stack, unless it is ours
    jnz .no_alt
    mov rax, [rsi + TH_ALTSP]
    mov [rdi + TH_ALTSP], rax
    mov rax, [rsi + TH_ALTSIZE]
    mov [rdi + TH_ALTSIZE], rax
.no_alt:
    xor eax, eax
    test ebx, CLONE_CHILD_CLEARTID
    cmovnz rax, r14
    mov [rdi + TH_CTID], rax
    test ebx, CLONE_PARENT_SETTID
    jz .no_ptid
    mov rdi, r13
    mov esi, [rsp + 24]
    call lx_put32
.no_ptid:
    test ebx, CLONE_CHILD_SETTID        ; (in its memory)
    jz .no_ctid
    mov rax, [rsp + 8]
    mov rdi, [rax + TK_AS]
    mov rsi, r14
    lea rdx, [rsp + 24]
    mov ecx, 4
    mov r8d, LXA_WRITE
    call lx_copy
.no_ctid:
    mov rdi, [rsp + 8]                  ; ours, for as long as we look at it
    call obj_get
    mov rdi, [rsp]                      ; the list takes task_new's
    call lx_proc_add
    lock inc qword [lx_started]
    mov rdi, [rsp + 16]
    call thread_start
    mov rdi, [rsp + 16]
    call thread_put
    test ebx, CLONE_VFORK
    jz .started
    mov rax, [gs:PC_CURRENT]            ; until it execs or ends (a kill
    or dword [rax + TH_LXFL], LXF_NOSIG ; cuts that short, no signal does)
    mov rdx, [rsp]
    lea rdi, [rdx + LP_WQ]
    lea rsi, [lx_vfork_test]
    xor ecx, ecx
    call wq_wait_fn
    mov rax, [gs:PC_CURRENT]
    and dword [rax + TH_LXFL], ~LXF_NOSIG
.started:
    mov rdi, [rsp + 8]
    call obj_put
    mov eax, [rsp + 24]
    jmp .out
.nomem:
    mov rax, -ENOMEM
.failed:
    mov rdi, [rsp + 8]                  ; and all it had, with it
    push rax
    call obj_put
    pop rax
    jmp .out
.nomem_none:
    mov rax, -ENOMEM
.out:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_vfork_test(RDI = a vfork's child) -> EAX = 1 once it has exec'd or ended
lx_vfork_test:
    xor eax, eax
    cmp dword [rdi + LP_VFORK], 0
    sete al
    or eax, [rdi + LP_ENDED]
    ret

; lx_proc_copy(RDI = a new process, RSI = the one it is forked from) -> RAX
; = 0, or -ENOMEM: its group, session, directory, program, name and
; terminal; a copy of its actions; its descriptors, the open files shared
lx_proc_copy:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov eax, [r12 + LP_PGID]
    mov [rbx + LP_PGID], eax
    mov eax, [r12 + LP_SID]
    mov [rbx + LP_SID], eax
    mov eax, [r12 + LP_UMASK]
    mov [rbx + LP_UMASK], eax
    mov rax, [r12 + LP_CWD]
    mov [rbx + LP_CWD], rax
    mov rax, [r12 + LP_EXE]
    mov [rbx + LP_EXE], rax
    mov rax, [r12 + LP_COMM]
    mov [rbx + LP_COMM], rax
    mov rax, [r12 + LP_COMM + 8]
    mov [rbx + LP_COMM + 8], rax
    mov rdi, [r12 + LP_TTY]
    mov [rbx + LP_TTY], rdi
    test rdi, rdi
    jz .no_tty
    call ly_get
.no_tty:
    mov edi, LX_NSIG * LSA_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + LP_SIGACTS], rax
    mov rdi, rax
    mov rsi, [r12 + LP_SIGACTS]
    mov ecx, LX_NSIG * LSA_SIZE / 8
    rep movsq
    lea rdi, [r12 + LP_FDLOCK]
    call lx_mutex_lock
    mov r13d, [r12 + LP_NFD]
    lea rdi, [r13 * 8]
    call kmalloc
    test rax, rax
    jz .nomem_fds
    mov [rbx + LP_FDS], rax
    mov [rbx + LP_NFD], r13d
    mov rsi, [r12 + LP_FDS]
    xor ecx, ecx
.fd:
    cmp ecx, r13d
    jae .fds_done
    mov rdx, [rsi + rcx * 8]
    mov [rax + rcx * 8], rdx
    and rdx, -2
    jz .fd_next
    mov rdi, rdx
    call lf_get
.fd_next:
    inc ecx
    jmp .fd
.fds_done:
    lea rdi, [r12 + LP_FDLOCK]
    call lx_mutex_unlock
    xor eax, eax
    jmp .out
.nomem_fds:
    lea rdi, [r12 + LP_FDLOCK]
    call lx_mutex_unlock
.nomem:
    mov rax, -ENOMEM
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_as_fork(RDI = a Linux program's address space) -> RAX = a copy of it,
; or 0 if out of memory: its areas, its break, and under them each page
; filled in: a copy of each of its own, the file cache's shared as they are
lx_as_fork:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    call as_new
    test rax, rax
    jz .out
    mov rbp, rax
    mov rdi, rbx
    call mm_lock
    mov rax, [rbx + AS_BRK0]
    mov [rbp + AS_BRK0], rax
    mov rax, [rbx + AS_BRK]
    mov [rbp + AS_BRK], rax
    mov rdi, rbp
    mov esi, [rbx + AS_NVMA]
    call vma_room
    jc .nomem
    mov ecx, [rbx + AS_NVMA]
    mov [rbp + AS_NVMA], ecx
    imul ecx, ecx, VA_SIZE
    mov rsi, [rbx + AS_VMAS]
    mov rdi, [rbp + AS_VMAS]
    rep movsb
    xor r12d, r12d                      ; R12 = the area
.area:
    cmp r12d, [rbx + AS_NVMA]
    jae .done
    mov rdi, rbx
    mov edx, r12d
    call vma_at
    mov r13, [rax + VA_START]           ; R13 = the page
    mov r14, [rax + VA_END]
.page:
    cmp r13, r14
    jae .next_area
    mov rdi, rbx
    mov rsi, r13
    call as_pte_get
    test rax, rax
    jz .no_table
    mov r15, [rax]
    test r15d, PTE_P
    jz .next_page
    mov rsi, r15                        ; RSI = the page, R15 = its flags
    and rsi, [vmm_addr_mask]
    xor r15, rsi
    test r15d, PTE_OWN
    jz .share
    call lx_page_copy
    test rax, rax
    jz .nomem
    jmp .put
.share:
    mov rax, rsi
.put:
    or r15, rax                         ; R15 = its PTE in the copy
    mov rdi, rbp
    mov rsi, r13
    call as_pte
    test rax, rax
    jz .nomem_page
    mov [rax], r15
.next_page:
    add r13, 4096
    jmp .page
.no_table:
    cmp rdx, r13                        ; nothing mapped below RDX
    jbe .next_page
    mov r13, rdx
    jmp .page
.next_area:
    inc r12d
    jmp .area
.nomem_page:
    test r15d, PTE_OWN
    jz .nomem
    mov rdi, r15
    and rdi, [vmm_addr_mask]
    call lx_page_free
.nomem:
    mov rdi, rbx
    call mm_unlock
    mov rdi, rbp
    call as_destroy
    xor eax, eax
    jmp .out
.done:
    mov rdi, rbx
    call mm_unlock
    mov rax, rbp
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  execve
; -----------------------------------------------------------------------------

; execve(path, argv, envp)
lx_sys_execve:
    xor r8d, r8d
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
; execveat(dirfd, path, argv, envp, flags)
lx_sys_execveat:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48                         ; [rsp] = the path, here, [+8] = the
    mov ebx, edi                        ; arguments, [+16] = the environment
    mov r12, rsi                        ; (blocks: count, bytes, strings),
    mov r13, rdx                        ; [+24] = the program's node, [+32] =
    mov r14, rcx                        ; interpreters so far, [+40] = its
    mov r15d, r8d                       ; address space
    xor eax, eax
    mov [rsp], rax
    mov [rsp + 8], rax
    mov [rsp + 16], rax
    mov [rsp + 32], rax
    mov rax, -EINVAL
    test r15d, ~(AT_EMPTY_PATH | AT_SYMLINK_NOFOLLOW)
    jnz .out
    mov edi, LX_PATH
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rsp], rax
    mov edi, LX_ARGS_MAX + 4096
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [rsp + 8], rax
    mov edi, LX_ARGS_MAX + 4096
    call vm_alloc
    test rax, rax
    jz .nomem
    mov [rsp + 16], rax
    mov edi, ebx                        ; the program
    mov rsi, r12
    mov rdx, [rsp]
    xor ecx, ecx
    test r15d, AT_SYMLINK_NOFOLLOW
    jz .follow
    mov ecx, LKF_NOFOLLOW
.follow:
    xor r8d, r8d
    test r15d, AT_EMPTY_PATH
    setnz r8b
    call lx_path_at
    cmp rax, -4095
    jae .out
    mov [rsp + 24], rax
    mov rdi, [rsp + 8]                  ; its arguments and environment, here
    mov rsi, r13
    call lx_strv_in
    test rax, rax
    jnz .out
    mov rdi, [rsp + 16]
    mov rsi, r14
    call lx_strv_in
    test rax, rax
    jnz .out
.program:
    mov rdi, [rsp + 24]                 ; a file one may run
    mov rax, -EACCES
    cmp dword [rdi + LN_KIND], LNK_FILE
    jne .out
    test dword [rdi + LN_MODE], 0o111
    jz .out
    call lx_file_data
    cmp rax, -4095
    jae .out
    mov rdi, [rsp + 24]
    cmp qword [rdi + LN_SIZE], 2
    jb .image
    cmp word [rax], '#!'
    jne .image
    inc dword [rsp + 32]                ; a script: its interpreter's turn
    mov rax, -ELOOP
    cmp dword [rsp + 32], LX_EXEC_DEPTH
    ja .out
    mov rsi, [rsp + 8]
    mov rdx, [rsp]
    call lx_shebang
    cmp rax, -4095
    jae .out
    mov [rsp + 24], rax
    jmp .program
.image:
    call lx_cur_proc                    ; (threads besides this one: not yet)
    cmp dword [rax + LP_LIVE], 1
    mov rax, -EAGAIN
    jne .out
    call as_new
    test rax, rax
    jz .nomem
    mov [rsp + 40], rax
    mov rdi, rax
    mov rsi, [rsp + 24]
    mov rdx, [rsp + 8]
    mov rcx, [rsp + 16]
    mov r8, [rsp]
    call lx_exec_image
    cmp rax, -4095
    jb .mapped
    mov rdi, [rsp + 40]                 ; (the process goes on as it was)
    push rax
    call as_destroy
    pop rax
    jmp .out
.mapped:
    mov r12, rax                        ; R12 = the entry, R13 = the stack
    mov r13, rdx
    mov rdi, [rsp + 40]                 ; past here, nothing fails
    mov rsi, [rsp + 24]
    call lx_exec_commit
    mov rdi, rbp                        ; every register 0, as a program starts
    xor eax, eax
    mov ecx, (FR_RAX + 8) / 8
    rep stosq
    mov [rbp + FR_RIP], r12
    mov [rbp + FR_RSP], r13
    mov qword [rbp + FR_RFLAGS], USER_RFLAGS
    xor eax, eax
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    mov rbx, rax
    mov rdi, [rsp]
    test rdi, rdi
    jz .no_path
    call kfree
.no_path:
    mov rdi, [rsp + 8]
    test rdi, rdi
    jz .no_args
    call vm_free
.no_args:
    mov rdi, [rsp + 16]
    test rdi, rdi
    jz .no_env
    call vm_free
.no_env:
    mov rax, rbx
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_strv_in(RDI = a block, LX_ARGS_MAX + 8 bytes, RSI = a user array of
; strings ended by 0, or 0) -> RAX = 0, -EFAULT or -E2BIG: the strings, as
; lx_args leaves them (a count, their bytes, then each NUL-ended)
lx_strv_in:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov qword [rbx], 0
    xor eax, eax
    test r12, r12
    jz .out
    lea r13, [rbx + 8]                  ; R13 = where the next goes
.each:
    mov rdi, r12
    call lx_get64
    test rax, rax
    jnz .out
    test rdx, rdx
    jz .out
    mov rdi, r13
    mov rsi, rdx
    mov edx, LX_ARGS_MAX
    sub edx, [rbx + 4]
    call lx_copy_str
    cmp rax, -ENAMETOOLONG
    je .big
    test rax, rax
    js .out
    lea r13, [r13 + rax + 1]
    inc eax
    add [rbx + 4], eax
    inc dword [rbx]
    add r12, 8
    jmp .each
.big:
    mov rax, -E2BIG
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_strv_shift(RDI = a block): its first string gone. Preserves others.
lx_strv_shift:
    cmp dword [rdi], 0
    je .out
    push rax
    push rcx
    push rsi
    push rdi
    push rdi
    lea rdi, [rdi + 8]
    call strlen
    pop rdi
    lea rcx, [rax + 1]                  ; RCX = its bytes
    dec dword [rdi]
    sub [rdi + 4], ecx
    lea rsi, [rdi + 8 + rcx]
    mov ecx, [rdi + 4]
    add rdi, 8
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rax
.out:
    ret

; lx_strv_unshift(RDI = a block, RSI = a string) -> RAX = 0, or -E2BIG:
; the string, first. Preserves others.
lx_strv_unshift:
    push rcx
    push rsi
    push rdi
    push rdx
    push rdi
    mov rdi, rsi
    call strlen
    pop rdi
    lea rdx, [rax + 1]                  ; RDX = its bytes
    mov eax, [rdi + 4]
    add rax, rdx
    cmp rax, LX_ARGS_MAX
    mov rax, -E2BIG
    ja .out
    push rsi
    push rdi
    mov ecx, [rdi + 4]                  ; the rest along, from the end
    lea rsi, [rdi + 8 + rcx - 1]
    lea rdi, [rsi + rdx]
    std
    rep movsb
    cld
    pop rdi
    pop rsi
    inc dword [rdi]
    add [rdi + 4], edx
    push rdi
    add rdi, 8
    mov rcx, rdx
    rep movsb
    pop rdi
    xor eax, eax
.out:
    pop rdx
    pop rdi
    pop rsi
    pop rcx
    ret

; lx_shebang(RDI = a script's node, its bytes in the cache, RSI = its
; arguments, RDX = the path it was run by) -> RAX = its interpreter's node,
; or -errno; the arguments now the interpreter's: its name, the one
; argument the '#!' line may give, the path, then those after argv[0]
lx_shebang:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, LX_SHEBANG + 16
    mov r12, rsi                        ; R12 = the arguments
    mov r13, rdx                        ; R13 = the path
    mov rsi, [rdi + LN_DATA]            ; its line, here
    add rsi, 2
    mov rcx, [rdi + LN_SIZE]
    sub rcx, 2
    cmp rcx, LX_SHEBANG - 1
    jbe .length
    mov ecx, LX_SHEBANG - 1
.length:
    mov rdi, rsp
    xor eax, eax
.line:
    test rcx, rcx
    jz .ended
    lodsb
    cmp al, 10
    je .ended
    test al, al
    je .ended
    stosb
    dec rcx
    jmp .line
.ended:
    mov byte [rdi], 0
    mov rbx, rsp                        ; RBX = the interpreter's name
.lead:
    cmp byte [rbx], ' '
    je .skip_lead
    cmp byte [rbx], 9
    jne .name
.skip_lead:
    inc rbx
    jmp .lead
.name:
    mov rax, -ENOEXEC
    cmp byte [rbx], 0
    je .out
    mov r14, rbx
.name_end:
    mov al, [r14]
    test al, al
    jz .no_arg
    cmp al, ' '
    je .name_done
    cmp al, 9
    je .name_done
    inc r14
    jmp .name_end
.name_done:
    mov byte [r14], 0
    inc r14                             ; R14 = its argument, if any
.arg_lead:
    cmp byte [r14], ' '
    je .skip_arg
    cmp byte [r14], 9
    jne .arg
.skip_arg:
    inc r14
    jmp .arg_lead
.arg:
    mov rdi, r14                        ; (spaces and tabs at its end dropped)
    call strlen
    lea r15, [r14 + rax]
.trim:
    cmp r15, r14
    jbe .trimmed
    cmp byte [r15 - 1], ' '
    je .drop
    cmp byte [r15 - 1], 9
    jne .trimmed
.drop:
    dec r15
    jmp .trim
.trimmed:
    mov byte [r15], 0
    cmp r15, r14
    jne .args
.no_arg:
    xor r14d, r14d
.args:
    mov rdi, r12                        ; interpreter, argument, path, argv[1..]
    call lx_strv_shift
    mov rsi, r13
    call lx_strv_unshift
    test rax, rax
    jnz .out
    test r14, r14
    jz .no_arg_in
    mov rsi, r14
    call lx_strv_unshift
    test rax, rax
    jnz .out
.no_arg_in:
    mov rsi, rbx
    call lx_strv_unshift
    test rax, rax
    jnz .out
    call lx_cur_proc                    ; (a relative one from the directory)
    mov rsi, [rax + LP_CWD]
    mov rdi, rbx
    xor edx, edx
    call lx_lookup
.out:
    add rsp, LX_SHEBANG + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_exec_commit(RDI = an address space with the program in it, RSI = the
; program's node): this process goes on in it, as execve leaves one
lx_exec_commit:
    push rbx
    push r12
    push r13
    mov r12, rdi
    mov r13, rsi
    call lx_cur_proc
    mov rbx, rax
    call cur_task
    mov rsi, [gs:PC_CURRENT]
    cli
    mov rdi, [rax + TK_AS]              ; RDI = the old one
    mov [rax + TK_AS], r12
    mov rax, [r12 + AS_CR3]
    mov [rsi + TH_CR3], rax
    mov cr3, rax
    mov [gs:PC_CR3], rax
    xor eax, eax                        ; no TLS yet
    mov [rsi + TH_FSBASE], rax
    mov [rsi + TH_GSBASE], rax
    mov [gs:PC_FSBASE], rax
    mov [gs:PC_UGSBASE], rax
    xor edx, edx
    mov ecx, MSR_FS_BASE
    wrmsr
    mov ecx, MSR_KGS_BASE
    wrmsr
    lea rcx, [lx_fp_init]               ; and SIMD state as it starts
    cmp byte [sched_xsave], 0
    je .fxinit
    mov eax, [cpu_xcr0]
    xor edx, edx
    xrstor64 [rcx]
    jmp .fp_done
.fxinit:
    fxrstor64 [rcx]
.fp_done:
    sti
    xor eax, eax
    mov [rsi + TH_ALTSP], rax
    mov [rsi + TH_ALTSIZE], rax
    mov [rsi + TH_CTID], rax
    mov dword [rsi + TH_LXFL], 0
    call as_release                     ; (a vfork's parent keeps it)
    cmp dword [rbx + LP_VFORK], 0       ; that parent goes on now
    je .vforked
    mov dword [rbx + LP_VFORK], 0
    lea rdi, [rbx + LP_WQ]
    call wq_wake
.vforked:
    lea rdi, [rbx + LP_FDLOCK]          ; descriptors with FD_CLOEXEC close
    call lx_mutex_lock
    xor ecx, ecx
.fd:
    cmp ecx, [rbx + LP_NFD]
    jae .fds_done
    mov rsi, [rbx + LP_FDS]
    mov rax, [rsi + rcx * 8]
    test al, FD_CLOEXEC
    jz .fd_next
    mov qword [rsi + rcx * 8], 0
    and rax, -2
    mov rdi, rax
    call lf_put
.fd_next:
    inc ecx
    jmp .fd
.fds_done:
    lea rdi, [rbx + LP_FDLOCK]
    call lx_mutex_unlock
    mov rsi, [rbx + LP_SIGACTS]         ; handlers gone (ignoring stays)
    mov ecx, LX_NSIG
.action:
    cmp qword [rsi + LSA_HANDLER], SIG_IGN
    jbe .action_next
    xor eax, eax
    mov [rsi + LSA_HANDLER], rax
    mov [rsi + LSA_FLAGS], rax
    mov [rsi + LSA_RESTORER], rax
    mov [rsi + LSA_MASK], rax
.action_next:
    add rsi, LSA_SIZE
    dec ecx
    jnz .action
    mov [rbx + LP_EXE], r13             ; its program, and name
    mov rsi, [r13 + LN_NAME]
    lea rdi, [rbx + LP_COMM]
    mov ecx, 15
.comm:
    lodsb
    stosb
    test al, al
    jz .commed
    dec ecx
    jnz .comm
    mov byte [rdi], 0
.commed:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  wait4, waitid
; -----------------------------------------------------------------------------

; lx_wait(ESI = which children: wait4's pid, EDX = WNOHANG, WNOWAIT) -> RAX
; = a child that has ended (a reference to its task for the caller: off the
; list, unless WNOWAIT), 0 if none has yet (WNOHANG), -ECHILD, or
; -ERESTARTSYS
lx_wait:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 16
    mov r12d, esi
    mov r13d, edx
    call lx_cur_proc
    mov rbx, rax
    mov dword [rsp + 4], 0              ; a signal came: look once more, then say so
.again:
    mov eax, [lx_poll_gen]              ; (before looking: nothing missed)
    mov [rsp], eax
    call lx_procs_lock
    mov r14, rax
    xor ecx, ecx                        ; ECX = children it may mean
    mov rdi, [lx_procs]
.each:
    test rdi, rdi
    jz .looked
    cmp [rdi + LP_PARENT], rbx
    jne .next
    test r12d, r12d
    jg .pid
    mov eax, [rdi + LP_PGID]
    cmp r12d, -1
    je .match
    mov edx, [rbx + LP_PGID]
    test r12d, r12d
    jz .group
    mov edx, r12d
    neg edx
.group:
    cmp eax, edx
    jne .next
    jmp .match
.pid:
    cmp [rdi + LP_PID], r12d
    jne .next
.match:
    inc ecx
    cmp dword [rdi + LP_ENDED], 0
    jne .found
.next:
    mov rdi, [rdi + LP_NEXT]
    jmp .each
.found:
    test r13d, WNOWAIT
    jnz .keep
    call lx_proc_unlink
    jmp .taken
.keep:
    push rdi
    mov rdi, [rdi + LP_TASK]
    call obj_get
    pop rdi
.taken:
    mov rax, r14
    call lx_procs_unlock
    mov rax, rdi
    jmp .out
.looked:
    mov rax, r14
    call lx_procs_unlock
    mov rax, -ECHILD
    test ecx, ecx
    jz .out
    xor eax, eax
    test r13d, WNOHANG
    jnz .out
    mov rax, -ERESTARTSYS               ; (a child that ended as the signal
    cmp dword [rsp + 4], 0              ; came is said first, as Linux does)
    jne .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    xor ecx, ecx
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    mov [rsp + 4], eax
    jmp .again
.out:
    add rsp, 16
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wait4(pid, wstatus, options, rusage)
lx_sys_wait4:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi                        ; R12 = wstatus, R13 = rusage
    mov r13, rcx
    mov rax, -EINVAL
    test edx, ~(WNOHANG | WUNTRACED | WCONTINUED | WALL_FLAGS)
    jnz .out
    mov esi, edi
    and edx, WNOHANG
    call lx_wait
    cmp rax, -4095
    jae .out
    test rax, rax
    jz .out
    mov rbx, rax                        ; RBX = the child
    mov r14d, [rbx + LP_PID]
    test r12, r12
    jz .status_done
    mov rdi, r12
    mov esi, [rbx + LP_STATUS]
    call lx_put32
    test rax, rax
    jnz .drop
.status_done:
    test r13, r13
    jz .usage_done
    mov rdi, r13                        ; (struct rusage: nothing counted)
    mov esi, 144
    call lx_zero_out
    test rax, rax
    jnz .drop
.usage_done:
    mov eax, r14d
.drop:
    mov rdi, [rbx + LP_TASK]
    push rax
    call obj_put
    pop rax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; waitid(idtype, id, infop, options, rusage)
lx_sys_waitid:
    push rbx
    push r12
    push r13
    push r14
    sub rsp, 128
    mov r12, rdx                        ; R12 = infop, R13 = rusage
    mov r13, r8
    mov r14d, ecx                       ; R14 = options
    mov rax, -EINVAL
    test ecx, ~(WNOHANG | WUNTRACED | WEXITED | WCONTINUED | WNOWAIT | WALL_FLAGS)
    jnz .out
    test ecx, WEXITED | WUNTRACED | WCONTINUED
    jz .out
    cmp edi, P_ALL
    je .all
    cmp edi, P_PID
    je .pid
    cmp edi, P_PGID
    jne .out
    neg esi                             ; wait4's way: -group, or 0 for ours
    jmp .which
.pid:
    test esi, esi
    jle .out
    jmp .which
.all:
    mov esi, -1
.which:
    mov rdi, rsp
    xor eax, eax
    mov ecx, 128 / 8
    rep stosq
    xor ebx, ebx
    test r14d, WEXITED                  ; (stops and continues: none here)
    jz .info
    mov edx, r14d
    and edx, WNOHANG | WNOWAIT
    call lx_wait
    cmp rax, -4095
    jae .out
    mov rbx, rax
    test rbx, rbx
    jz .info
    mov dword [rsp], SIGCHLD            ; si_signo
    mov eax, [rbx + LP_PID]
    mov [rsp + 16], eax                 ; si_pid
    mov eax, [rbx + LP_STATUS]
    mov ecx, eax
    and ecx, 0x7F
    jz .exited
    mov dword [rsp + 8], CLD_KILLED     ; si_code
    mov [rsp + 24], ecx                 ; si_status
    jmp .dropped
.exited:
    mov dword [rsp + 8], CLD_EXITED
    shr eax, 8
    and eax, 0xFF
    mov [rsp + 24], eax
.dropped:
    mov rdi, [rbx + LP_TASK]
    call obj_put
.info:
    xor eax, eax
    test r12, r12
    jz .usage
    mov rdi, r12
    mov rsi, rsp
    mov edx, 128
    call lx_copy_out
    test rax, rax
    jnz .out
.usage:
    test r13, r13
    jz .out
    mov rdi, r13
    mov esi, 144
    call lx_zero_out
.out:
    add rsp, 128
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Process groups, sessions, kill
; -----------------------------------------------------------------------------

; getpgrp()
lx_sys_getpgrp:
    call lx_cur_proc
    mov eax, [rax + LP_PGID]
    ret

; getpgid(pid)
lx_sys_getpgid:
    mov edx, LP_PGID
    jmp lx_proc_field

; getsid(pid)
lx_sys_getsid:
    mov edx, LP_SID
; lx_proc_field(EDI = a pid, 0 for this process, EDX = a dword of LP_*) ->
; RAX = that process's, or -ESRCH
lx_proc_field:
    test edi, edi
    jnz .other
    call lx_cur_proc
    mov eax, [rax + rdx]
    ret
.other:
    mov rax, -ESRCH
    js .out
    push rbx
    call lx_procs_lock
    mov rbx, rax
    call lx_proc_find
    test rax, rax
    jz .none
    mov eax, [rax + rdx]
    jmp .unlock
.none:
    mov rax, -ESRCH
.unlock:
    xchg rax, rbx
    call lx_procs_unlock
    mov rax, rbx
    pop rbx
.out:
    ret

; setpgid(pid, pgid): this process or a child of its, into a group of this
; session (a new one, with its pid)
lx_sys_setpgid:
    push rbx
    push r12
    push r13
    mov rax, -EINVAL
    test esi, esi
    js .out
    mov r12d, edi
    mov r13d, esi
    call lx_cur_proc
    mov rbx, rax                        ; RBX = this process
    call lx_procs_lock
    push rax
    mov rdi, rbx                        ; RDI = the one to move
    test r12d, r12d
    jz .found
    mov edi, r12d
    call lx_proc_find
    mov rdi, rax
    mov rax, -ESRCH
    test rdi, rdi
    jz .unlock
    cmp rdi, rbx
    je .found
    cmp [rdi + LP_PARENT], rbx
    jne .unlock
.found:
    test r13d, r13d
    jnz .group
    mov r13d, [rdi + LP_PID]
.group:
    mov rax, -EPERM
    mov ecx, [rdi + LP_SID]
    cmp ecx, [rbx + LP_SID]             ; this session's,
    jne .unlock
    cmp ecx, [rdi + LP_PID]             ; not its leader
    je .unlock
    cmp r13d, [rdi + LP_PID]            ; a group of its own, or one there is
    je .set
    mov rcx, [lx_procs]
.look:
    test rcx, rcx
    jz .unlock
    cmp [rcx + LP_PGID], r13d
    jne .look_next
    mov edx, [rcx + LP_SID]
    cmp edx, [rbx + LP_SID]
    je .set
.look_next:
    mov rcx, [rcx + LP_NEXT]
    jmp .look
.set:
    mov [rdi + LP_PGID], r13d
    xor eax, eax
.unlock:
    mov rcx, rax
    pop rax
    call lx_procs_unlock
    mov rax, rcx
.out:
    pop r13
    pop r12
    pop rbx
    ret

; setsid(): a session of its own, and a group, unless a group has its pid
lx_sys_setsid:
    push rbx
    call lx_cur_proc
    mov rbx, rax
    call lx_procs_lock
    mov rcx, rax
    mov eax, [rbx + LP_PID]
    mov rdx, [lx_procs]
.look:
    test rdx, rdx
    jz .free
    cmp [rdx + LP_PGID], eax
    je .taken
    mov rdx, [rdx + LP_NEXT]
    jmp .look
.free:
    mov [rbx + LP_PGID], eax
    mov [rbx + LP_SID], eax
    jmp .unlock
.taken:
    mov rax, -EPERM
.unlock:
    xchg rax, rcx
    call lx_procs_unlock
    mov rax, rcx
    pop rbx
    ret

; lx_signal_group(EDI = a process group, ESI = a signal, or 0) -> EAX = how
; many processes it has that have not ended (each sent the signal).
; Preserves others.
lx_signal_group:
    push rbx
    push rcx
    push rdx
    push rdi
    xor ecx, ecx
    mov edx, edi
    call lx_procs_lock
    push rax
    mov rbx, [lx_procs]
.each:
    test rbx, rbx
    jz .done
    cmp [rbx + LP_PGID], edx
    jne .next
    cmp dword [rbx + LP_ENDED], 0
    jne .next
    inc ecx
    test esi, esi
    jz .next
    mov rdi, rbx
    call lx_signal_proc
.next:
    mov rbx, [rbx + LP_NEXT]
    jmp .each
.done:
    pop rax
    call lx_procs_unlock
    mov eax, ecx
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; kill(pid, sig): a process (pid > 0), this one's group (0), every other
; process of the session (-1), or a group (-group)
lx_sys_kill:
    push rbx
    push r12
    push r13
    mov rax, -EINVAL
    cmp esi, LX_NSIG
    ja .out
    mov r12d, edi
    mov r13d, esi
    call lx_cur_proc
    mov rbx, rax
    test r12d, r12d
    jg .one
    jz .own_group
    cmp r12d, -1
    je .all
    mov edi, r12d
    neg edi
    jmp .group
.own_group:
    mov edi, [rbx + LP_PGID]
.group:
    mov esi, r13d
    call lx_signal_group
    test eax, eax
    jnz .sent
    mov rax, -ESRCH
    jmp .out
.one:
    call lx_procs_lock
    mov rcx, rax
    mov edi, r12d
    call lx_proc_find
    test rax, rax
    jz .none
    test r13d, r13d
    jz .found
    mov rdi, rax
    mov esi, r13d
    call lx_signal_proc
.found:
    mov rax, rcx
    call lx_procs_unlock
.sent:
    xor eax, eax
    jmp .out
.none:
    mov rax, rcx
    call lx_procs_unlock
    mov rax, -ESRCH
    jmp .out
.all:
    call lx_procs_lock
    push rax
    xor ecx, ecx
    mov rdi, [lx_procs]
.each:
    test rdi, rdi
    jz .each_done
    cmp rdi, rbx
    je .each_next
    mov eax, [rdi + LP_SID]
    cmp eax, [rbx + LP_SID]
    jne .each_next
    cmp dword [rdi + LP_ENDED], 0
    jne .each_next
    inc ecx
    test r13d, r13d
    jz .each_next
    mov esi, r13d
    call lx_signal_proc
.each_next:
    mov rdi, [rdi + LP_NEXT]
    jmp .each
.each_done:
    pop rax
    call lx_procs_unlock
    test ecx, ecx
    jnz .sent
    mov rax, -ESRCH
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tgkill(tgid, tid, sig): a thread of any process
lx_sys_tgkill:
    mov rax, -EINVAL
    cmp edx, LX_NSIG
    ja .out
    test edi, edi
    jle .out
    test esi, esi
    jle .out
    push rbx
    push r12
    push r13
    mov r12d, esi
    mov r13d, edx
    call lx_procs_lock
    mov rbx, rax
    call lx_proc_find
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, r12d
    mov edx, r13d
    call lx_signal_tid
    jmp .unlock
.none:
    mov rax, -ESRCH
.unlock:
    xchg rax, rbx
    call lx_procs_unlock
    mov rax, rbx
    pop r13
    pop r12
    pop rbx
.out:
    ret

section .bss
alignb 8
lx_procs:       resq 1                  ; every process, the first started first
lx_procs_spin:  resd 1

section .text
