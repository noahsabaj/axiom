; =============================================================================
;  linux.asm - Linux programs, unchanged: glibc's ELF files from a root on
;  the boot stick, on Linux's system calls
;
;  'linux <program> [arguments]' finds the program on the Linux PATH in the
;  root (lxfs.asm) and makes it a process: a task with an address space
;  (user.asm's, with Linux's areas, lxmm.asm) and a Linux process's state
;  (LP_*, its TK_LX): its pid, its descriptors (0, 1 and 2 its terminal,
;  the shell it was run in), its directory. The program's ELF file is
;  mapped as its program headers say (ET_EXEC where it was linked, ET_DYN at
;  0x555555554000), and its interpreter (PT_INTERP, ld.so) below LX_MMAP_TOP;
;  its first thread starts at the interpreter's entry, or its own, on a
;  Linux stack: argc, argv, envp and the auxiliary vector (AT_PHDR,
;  AT_ENTRY, AT_BASE, AT_RANDOM, AT_EXECFN ...), with the strings above.
;
;  Its threads are user threads with TF_LINUX: SYSCALL comes to lx_syscall
;  with the frame as user.asm made it, and Linux's numbers index lx_table
;  (one never seen before is said once, and gets -ENOSYS); the result goes
;  back in RAX alone, every other register as it was, by IRETQ. FS is each
;  thread's own (TH_FSBASE, set by arch_prctl, loaded by sched_switch).
;  Faults in its pages fill them in (lxmm.asm); any other fault ends the
;  process as a signal would, said as user.asm says faults.
;
;  A process ends when its last thread does: by exit_group, the last exit,
;  a fault, or a kill (ctrl+C in its shell). Its descriptors close then,
;  and the shell says how it ended. One runs at a time, for now.
; =============================================================================

; errno
EPERM           equ 1
ENOENT          equ 2
ESRCH           equ 3
EINTR           equ 4
EIO             equ 5
ENXIO           equ 6
E2BIG           equ 7
ENOEXEC         equ 8
EBADF           equ 9
ECHILD          equ 10
EAGAIN          equ 11
ENOMEM          equ 12
EACCES          equ 13
EFAULT          equ 14
EBUSY           equ 16
EEXIST          equ 17
ENODEV          equ 19
ENOTDIR         equ 20
EISDIR          equ 21
EINVAL          equ 22
EMFILE          equ 24
ENOTTY          equ 25
ESPIPE          equ 29
EROFS           equ 30
EPIPE           equ 32
ERANGE          equ 34
ENAMETOOLONG    equ 36
ENOSYS          equ 38
ELOOP           equ 40
ENODATA         equ 61
EOPNOTSUPP      equ 95
EAFNOSUPPORT    equ 97
ETIMEDOUT       equ 110

SIGINT          equ 2
SIGILL          equ 4
SIGTRAP         equ 5
SIGBUS          equ 7
SIGFPE          equ 8
SIGKILL         equ 9
SIGSEGV         equ 11

; a Linux process
LP_PID          equ 0                   ; dword
LP_PPID         equ 4                   ; dword
LP_TASK         equ 8                   ; its task (which holds this)
LP_FDS          equ 16                  ; its descriptors: open files | FD_CLOEXEC
LP_NFD          equ 24                  ; dword: room for
LP_FDLOCK       equ 28                  ; dword
LP_CWD          equ 32                  ; its directory's node
LP_EXE          equ 40                  ; its program's node
LP_TTY          equ 48                  ; its terminal (lxfs.asm's LY_*)
LP_STATUS       equ 56                  ; dword: how it ended, as wait4 says
LP_ENDED        equ 60                  ; dword: 1 once its last thread ended
LP_WQ           equ 64                  ; WQ_SIZE: those waiting for that
LP_LIVE         equ 80                  ; dword: its threads, not yet ended
LP_EXITING      equ 84                  ; dword: 1 once LP_STATUS says how it ends
LP_UMASK        equ 88                  ; dword
LP_COMM         equ 96                  ; 16 bytes: its name (prctl)
LP_SIZE         equ 128

; what an ELF file mapped says (lx_elf_map)
EI_ENTRY        equ 0
EI_PHDR         equ 8                   ; where its program headers are mapped
EI_PHNUM        equ 16
EI_BASE         equ 24                  ; where it was put (its bias)
EI_END          equ 32                  ; the end of its highest segment
EI_INTERP       equ 40                  ; its PT_INTERP, in the cache, or 0
EI_SIZE         equ 48

LX_NSYS         equ 456                 ; Linux's system calls, up to
LX_DYN_BASE     equ 0x555555554000      ; where a PIE program goes
LX_ARGS_MAX     equ 128 * 1024          ; argument and environment strings
LX_META_MAX     equ 256 * 1024          ; META is read in this much first
LX_DEV          equ 0x801               ; st_dev of every file
LX_PID_FIRST    equ 100

; the auxiliary vector
AT_NULL         equ 0
AT_PHDR         equ 3
AT_PHENT        equ 4
AT_PHNUM        equ 5
AT_PAGESZ       equ 6
AT_BASE         equ 7
AT_FLAGS        equ 8
AT_ENTRY        equ 9
AT_UID          equ 11
AT_EUID         equ 12
AT_GID          equ 13
AT_EGID         equ 14
AT_PLATFORM     equ 15
AT_HWCAP        equ 16
AT_CLKTCK       equ 17
AT_SECURE       equ 23
AT_RANDOM       equ 25
AT_HWCAP2       equ 26
AT_EXECFN       equ 31
LX_AUXV         equ 20                  ; pairs, room for, with AT_NULL

section .text

; -----------------------------------------------------------------------------
;  System calls
; -----------------------------------------------------------------------------

; lx_syscall: from syscall_entry, interrupts on, RBP = the frame, RAX = the
; number, RDI, RSI, RDX, RCX (R10), R8, R9 = the arguments
lx_syscall:
    cmp rax, LX_NSYS
    jae lx_unknown
    lea r11, [lx_table]
    mov r11, [r11 + rax * 8]
    test r11, r11
    jz lx_unknown
    call r11
lx_back:
    mov [rbp + FR_RAX], rax
; lx_return(RBP = a frame): back to ring 3 as it says, every register
lx_return:
    cli
    call user_leave
    mov rax, [rbp + FR_RIP]             ; IRETQ to an address not canonical
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
    swapgs
    iretq
.bad_rip:
    sti
    mov edi, SIGSEGV
    jmp lx_die
lx_unknown:
    mov rdi, rax
    call lx_nosys
    mov rax, -ENOSYS
    jmp lx_back

; lx_nosys(RDI = a call's number): said, the first time a program makes it
lx_nosys:
    cmp rdi, 512
    jae .out
    lock bts [lx_nosys_seen], rdi
    jc .out
    call lx_cur_proc
    lea rax, [rax + LP_COMM]
    KLOG "linux: %s: system call %u is not there yet (ENOSYS)", rax, rdi
.out:
    ret

; a call that is not there, quietly
lx_sys_enosys:
    mov rax, -ENOSYS
    ret

; a call that does nothing here, and succeeds
lx_sys_zero:
    xor eax, eax
    ret

; lx_init: lx_table, from lx_calls (once)
lx_init:
    cmp byte [lx_ready], 0
    jne .out
    lea rsi, [lx_calls]
    lea rdi, [lx_table]
.call:
    mov rax, [rsi]
    cmp rax, -1
    je .done
    mov rcx, [rsi + 8]
    mov [rdi + rax * 8], rcx
    add rsi, 16
    jmp .call
.done:
    mov byte [lx_ready], 1
.out:
    ret

; -----------------------------------------------------------------------------
;  Faults, and ends
; -----------------------------------------------------------------------------

; lx_fault(RDI = frame, R12 = CR2): from user_fault, interrupts off. A page
; to fill in is, and it returns; anything else ends the process.
lx_fault:
    mov rax, [rdi + FR_VECTOR]
    cmp eax, 14
    jne .other
    sti
    push rdi
    call lx_page_fault
    pop rdi
    jc .segv
    cli                                 ; (isr_common goes back with them off)
    ret
.segv:
    mov esi, SIGSEGV
    jmp .ends
.other:
    mov esi, SIGSEGV
    lea rcx, [lx_fault_signals]
    cmp eax, 20
    jae .ends
    movzx esi, byte [rcx + rax]
.ends:
    push rdi
    call lx_cur_proc
    mov edi, esi
    call lx_set_status
    pop rdi
    jmp user_fault_said                 ; said, the task killed, lx_thread_exit

; lx_set_status(RAX = process, EDI = wait status): how it ends, unless that
; was said already. Preserves all.
lx_set_status:
    push rcx
    lock bts dword [rax + LP_EXITING], 0
    jc .out
    mov [rax + LP_STATUS], edi
.out:
    pop rcx
    ret

; lx_die(EDI = a signal): the process ends by it (this thread, from a call)
lx_die:
    call lx_cur_proc
    call lx_set_status
    mov rdi, [rax + LP_TASK]
    call task_kill
    jmp lx_thread_exit

; lx_killed: from user_leave, interrupts off: this thread's task is being
; killed. Unless the process said how it ends, by SIGKILL.
lx_killed:
    sti
    call lx_cur_proc
    mov edi, SIGKILL
    call lx_set_status
; lx_thread_exit: interrupts on. This thread ends; the process with its last.
lx_thread_exit:
    call lx_cur_proc
    mov rbx, rax
    lock dec dword [rbx + LP_LIVE]
    jnz .gone
    mov rdi, rbx
    call lx_proc_exit
.gone:
    mov rdi, E_KILLED
    jmp thread_exit

; lx_proc_exit(RDI = process): its last thread is ending. Its descriptors
; close, what it wrote is said, and those waiting for it are told.
lx_proc_exit:
    push rbx
    push r12
    mov rbx, rdi
    xor r12d, r12d
.fd:
    cmp r12d, [rbx + LP_NFD]
    jae .closed
    mov rdi, rbx
    mov esi, r12d
    call lx_fd_close
    inc r12d
    jmp .fd
.closed:
    mov rdi, [rbx + LP_TTY]
    test rdi, rdi
    jz .said
    call ly_flush
.said:
    mov dword [rbx + LP_ENDED], 1
    lea rdi, [rbx + LP_WQ]
    call wq_wake
    mov byte [lx_pending], 1            ; and the main loop, to say so
    mov rdi, [main_thread]
    call thread_unpark
    pop r12
    pop rbx
    ret

; lx_proc_free(RDI = process): its task is going (task_destroy)
lx_proc_free:
    push rbx
    push r12
    mov rbx, rdi
    mov rdi, [rbx + LP_FDS]
    test rdi, rdi
    jz .no_fds
    xor r12d, r12d                      ; any still open (it never ran)
.fd:
    cmp r12d, [rbx + LP_NFD]
    jae .closed
    mov rax, [rdi + r12 * 8]
    and rax, -2
    jz .next
    push rdi
    mov rdi, rax
    call lf_put
    pop rdi
.next:
    inc r12d
    jmp .fd
.closed:
    call kfree
.no_fds:
    mov rdi, [rbx + LP_TTY]
    test rdi, rdi
    jz .no_tty
    call ly_put
.no_tty:
    mov rdi, rbx
    call kfree
    pop r12
    pop rbx
    ret

; exit(code): this thread; the process, if it is the last
lx_sys_exit:
    call lx_cur_proc
    cmp dword [rax + LP_LIVE], 1
    ja lx_thread_exit
; exit_group(code)
lx_sys_exit_group:
    and edi, 0xFF
    shl edi, 8
    call lx_cur_proc
    call lx_set_status
    mov rdi, [rax + LP_TASK]
    call task_kill
    jmp lx_thread_exit

; -----------------------------------------------------------------------------
;  Loading a program
; -----------------------------------------------------------------------------

; lx_elf_map(RDI = address space, RSI = a file's node, its bytes in the
; cache, RDX = where an ET_DYN file goes, or 0 for below LX_MMAP_TOP, RCX =
; EI_SIZE bytes to fill) -> RAX = 0 or -errno: its PT_LOAD segments mapped
lx_elf_map:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 56                         ; [rsp] = the lowest page, [+8] = the
    mov rbx, rdi                        ; end, [+16] = where it goes, [+24] =
    mov r12, rsi                        ; what it says, [+32] = a segment's
    mov [rsp + 16], rdx                 ; start, [+40] = its file end, [+48]
    mov [rsp + 24], rcx                 ; = its prot
    mov r13, [r12 + LN_DATA]            ; R13 = the file's bytes
    mov r14, [r12 + LN_SIZE]
    mov rax, -ENOEXEC
    cmp r14, 64
    jb .out
    cmp dword [r13], 0x464C457F         ; ELF
    jne .out
    cmp word [r13 + 4], 0x0102          ; 64-bit, little-endian
    jne .out
    cmp word [r13 + 18], 62             ; x86-64
    jne .out
    cmp word [r13 + 54], 56             ; e_phentsize
    jne .out
    movzx ecx, word [r13 + 56]          ; e_phnum
    test ecx, ecx
    jz .out
    imul ecx, ecx, 56
    mov rdx, [r13 + 32]                 ; e_phoff
    add rcx, rdx
    jc .out
    cmp rcx, r14
    ja .out
    lea r15, [r13 + rdx]                ; R15 = the program headers
    mov qword [rsp], -1                 ; the lowest page and the end
    mov qword [rsp + 8], 0
    movzx ecx, word [r13 + 56]
    mov rsi, r15
.span:
    cmp dword [rsi], 1                  ; PT_LOAD
    jne .span_next
    mov rax, [rsi + 16]                 ; p_vaddr
    and rax, -4096
    cmp rax, [rsp]
    jae .low
    mov [rsp], rax
.low:
    mov rax, [rsi + 16]
    add rax, [rsi + 40]                 ; + p_memsz
    cmp rax, [rsp + 8]
    jbe .span_next
    mov [rsp + 8], rax
.span_next:
    add rsi, 56
    dec ecx
    jnz .span
    mov rax, -ENOEXEC
    cmp qword [rsp], -1
    je .out                             ; nothing to load
    xor ebp, ebp                        ; RBP = the bias: 0 for ET_EXEC
    cmp word [r13 + 16], 2
    je .placed
    cmp word [r13 + 16], 3
    jne .out
    mov rbp, [rsp + 16]                 ; ET_DYN: where it was asked to go,
    test rbp, rbp
    jnz .dyn
    mov rdi, rbx                        ; or the highest room below the top
    call mm_lock
    mov rsi, [rsp + 8]
    add rsi, 4095
    and rsi, -4096
    sub rsi, [rsp]
    mov rdx, LX_MMAP_TOP
    mov ecx, LX_MMAP_LOW
    call vma_gap
    call mm_unlock
    mov rbp, rax
    mov rax, -ENOMEM
    test rbp, rbp
    jz .out
.dyn:
    sub rbp, [rsp]
.placed:
    movzx ecx, word [r13 + 56]
.segment:
    cmp dword [r15], 1
    jne .segment_next
    push rcx                            ; (the slots are 8 further from here)
    mov rax, [r15 + 16]                 ; p_vaddr and p_offset agree in a page
    sub rax, [r15 + 8]
    test eax, 0xFFF
    jnz .bad_pop
    mov rax, [r15 + 8]                  ; p_offset + p_filesz in the file
    add rax, [r15 + 32]
    jc .bad_pop
    cmp rax, r14
    ja .bad_pop
    mov rax, [r15 + 32]                 ; p_filesz <= p_memsz
    cmp rax, [r15 + 40]
    ja .bad_pop
    mov edx, [r15 + 4]                  ; p_flags: X 1, W 2, R 4 -> PROT_*
    xor ecx, ecx
    test edx, 4
    jz .w
    or ecx, PROT_READ
.w:
    test edx, 2
    jz .x
    or ecx, PROT_WRITE
.x:
    test edx, 1
    jz .prot
    or ecx, PROT_EXEC
.prot:
    mov [rsp + 8 + 48], rcx
    mov rsi, [r15 + 16]
    add rsi, rbp
    mov [rsp + 8 + 32], rsi             ; the segment's start
    mov rax, rsi
    add rax, [r15 + 32]
    mov [rsp + 8 + 40], rax             ; its file end
    cmp qword [r15 + 32], 0
    je .bss
    mov r10, rsi                        ; the file's part
    and rsi, -4096
    sub r10, rsi                        ; how far into its first page
    mov rdx, rax
    add rdx, 4095
    and rdx, -4096
    sub rdx, rsi
    mov rax, [r15 + 8]
    sub rax, r10
    push rax                            ; the offset of its first page
    mov rdi, rbx
    mov rcx, [rsp + 16 + 48]
    xor r8d, r8d
    mov r9, r12
    call lx_map
    add rsp, 8
    cmp rax, -4095
    jae .fail_pop
    mov rax, [rsp + 8 + 40]             ; the rest of its last page: zeroes
    test eax, 0xFFF
    jz .bss
    mov rcx, [r15 + 40]
    cmp rcx, [r15 + 32]
    je .bss
    mov rdi, rbx
    call mm_lock
    mov rsi, [rsp + 8 + 40]
    mov edx, LXA_WRITE | LXA_FORCE
    call lx_ptr
    call mm_unlock
    test rax, rax
    jz .nomem_pop
    mov rdi, rax
    mov ecx, edi
    and ecx, 0xFFF
    neg ecx
    add ecx, 4096
    xor eax, eax
    rep stosb
.bss:
    mov rsi, [rsp + 8 + 40]             ; zeroes from the next page on
    cmp qword [r15 + 32], 0
    jne .bss_from
    mov rsi, [rsp + 8 + 32]
    and rsi, -4096
    jmp .bss_start
.bss_from:
    add rsi, 4095
    and rsi, -4096
.bss_start:
    mov rdx, [r15 + 16]
    add rdx, rbp
    add rdx, [r15 + 40]
    add rdx, 4095
    and rdx, -4096
    cmp rdx, rsi
    jbe .segment_done
    sub rdx, rsi
    mov rdi, rbx
    mov rcx, [rsp + 8 + 48]
    xor r8d, r8d
    xor r9d, r9d
    push 0
    call lx_map
    add rsp, 8
    cmp rax, -4095
    jae .fail_pop
.segment_done:
    pop rcx
.segment_next:
    add r15, 56
    dec ecx
    jnz .segment
    mov rdi, [rsp + 24]                 ; what it says
    mov rax, [r13 + 24]                 ; e_entry
    add rax, rbp
    mov [rdi + EI_ENTRY], rax
    movzx eax, word [r13 + 56]
    mov [rdi + EI_PHNUM], rax
    mov rax, [rsp]
    add rax, rbp
    mov [rdi + EI_BASE], rax
    mov rax, [rsp + 8]
    add rax, rbp
    mov [rdi + EI_END], rax
    mov qword [rdi + EI_PHDR], 0
    mov qword [rdi + EI_INTERP], 0
    movzx ecx, word [r13 + 56]
    mov rsi, [r13 + 32]
    add rsi, r13
.header:
    mov eax, [rsi]
    cmp eax, 6                          ; PT_PHDR
    jne .not_phdr
    mov rax, [rsi + 16]
    add rax, rbp
    mov [rdi + EI_PHDR], rax
    jmp .header_next
.not_phdr:
    cmp eax, 1                          ; the PT_LOAD with the headers in it
    jne .not_load
    cmp qword [rdi + EI_PHDR], 0
    jne .header_next
    mov rax, [r13 + 32]
    sub rax, [rsi + 8]
    jb .header_next
    cmp rax, [rsi + 32]
    jae .header_next
    add rax, [rsi + 16]
    add rax, rbp
    mov [rdi + EI_PHDR], rax
    jmp .header_next
.not_load:
    cmp eax, 3                          ; PT_INTERP
    jne .header_next
    mov rax, [rsi + 8]
    mov rdx, [rsi + 32]
    lea r8, [rax + rdx]
    cmp r8, r14
    ja .header_next
    cmp rdx, 2
    jb .header_next
    add rax, r13
    cmp byte [rax + rdx - 1], 0         ; NUL-ended
    jne .header_next
    mov [rdi + EI_INTERP], rax
.header_next:
    add rsi, 56
    dec ecx
    jnz .header
    xor eax, eax
    jmp .out
.nomem_pop:
    mov rax, -ENOMEM
    jmp .fail_pop
.bad_pop:
    mov rax, -ENOEXEC
.fail_pop:
    pop rcx
.out:
    add rsp, 56
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_exec_image(RDI = address space, empty, RSI = the program's node, RDX =
; its arguments, RCX = its environment (each a block: count, bytes, the
; strings), R8 = the path it was run by) -> RAX = its first thread's entry,
; RDX = its stack pointer; RAX = -errno if it cannot be run
lx_exec_image:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 2 * EI_SIZE + 16           ; the program's, the interpreter's
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov r14, rcx
    mov r15, r8
    mov rdi, r12
    call lx_file_data
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov rsi, r12
    mov rdx, LX_DYN_BASE
    mov rcx, rsp
    call lx_elf_map
    cmp rax, -4095
    jae .out
    mov rax, [rsp + EI_END]             ; its break, after it
    add rax, 4095
    and rax, -4096
    mov [rbx + AS_BRK0], rax
    mov [rbx + AS_BRK], rax
    mov qword [rsp + EI_SIZE + EI_BASE], 0
    mov rax, [rsp + EI_ENTRY]
    mov [rsp + EI_SIZE + EI_ENTRY], rax
    mov rdi, [rsp + EI_INTERP]          ; its interpreter
    test rdi, rdi
    jz .stack
    mov rsi, [lx_root]
    xor edx, edx
    call lx_lookup
    cmp rax, -4095
    jae .out
    mov rbp, rax
    mov rax, -ENOEXEC
    cmp dword [rbp + LN_KIND], LNK_FILE
    jne .out
    mov rdi, rbp
    call lx_file_data
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov rsi, rbp
    xor edx, edx
    lea rcx, [rsp + EI_SIZE]
    call lx_elf_map
    cmp rax, -4095
    jae .out
.stack:
    mov rdi, rbx                        ; the stack
    mov rsi, LX_STACK_TOP - LX_STACK_SIZE
    mov edx, LX_STACK_SIZE
    mov ecx, PROT_READ | PROT_WRITE
    mov r8d, VMF_STACK
    xor r9d, r9d
    push 0
    call lx_map
    add rsp, 8
    cmp rax, -4095
    jae .out
    mov rdi, rbx
    mov rsi, rsp
    mov rdx, r13
    mov rcx, r14
    mov r8, r15
    call lx_stack_build
    cmp rax, -4095
    jae .out
    mov rdx, rax
    mov rax, [rsp + EI_SIZE + EI_ENTRY]
.out:
    add rsp, 2 * EI_SIZE + 16
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_stack_build(RDI = address space, RSI = the two EI_*, RDX = arguments,
; RCX = environment, R8 = the path) -> RAX = the stack pointer, or -errno:
; the first thread's stack, as Linux leaves it
lx_stack_build:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 64
    mov [rsp], rdi                      ; [rsp] = address space
    mov [rsp + 8], rsi                  ; [+8] = the EI_*s
    mov r12, rdx                        ; R12 = arguments, R13 = environment
    mov r13, rcx
    mov r14, r8                         ; R14 = the path
    mov rdi, r14
    call strlen
    lea r15, [rax + 1]                  ; R15 = the strings' bytes
    mov eax, [r12 + 4]
    add r15, rax
    mov eax, [r13 + 4]
    add r15, rax
    add r15, 7 + 16                     ; "x86_64", the random bytes
    mov eax, [r12]                      ; and the vector: argc, argv, envp, auxv
    add eax, [r13]
    add eax, 3 + 2 * LX_AUXV
    shl eax, 3
    lea rbx, [r15 + rax + 16 + 15]      ; RBX = bytes from the stack pointer to the top
    and rbx, -16
    mov rax, -E2BIG
    cmp rbx, LX_ARGS_MAX + 4096
    ja .out
    mov rdi, rbx
    call vm_alloc
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; RBP = it, here; the top is at RBP + RBX
    mov rax, LX_STACK_TOP
    sub rax, rbx
    mov [rsp + 16], rax                 ; [+16] = the stack pointer there
    lea rdi, [rbp + rbx - 8]            ; the strings, down from the top
    mov qword [rdi], 0
    mov rsi, r14                        ; the path
    call .string
    mov [rsp + 24], rax                 ; [+24] = AT_EXECFN
    mov rsi, r13                        ; the environment's strings
    call .block
    mov [rsp + 32], rax                 ; [+32] = the first
    mov rsi, r12
    call .block
    mov [rsp + 40], rax                 ; [+40] = the arguments' first
    lea rsi, [str_lx_platform]
    call .string
    mov [rsp + 48], rax                 ; [+48] = AT_PLATFORM
    sub rdi, 16                         ; 16 random bytes
    push rdi
    mov ecx, 2
.random:
    call lx_random_word
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .random
    pop rdi
    call .user
    mov [rsp + 56], rax                 ; [+56] = AT_RANDOM
    mov rdi, rbp                        ; the vector, from the stack pointer up
    mov eax, [r12]
    stosq                               ; argc
    mov rdx, [rsp + 40]
    mov ecx, [r12]
    call .pointers
    mov rdx, [rsp + 32]
    mov ecx, [r13]
    call .pointers
    mov r8, [rsp + 8]                   ; the auxiliary vector
    mov eax, AT_PHDR
    mov rdx, [r8 + EI_PHDR]
    call .aux
    mov eax, AT_PHENT
    mov edx, 56
    call .aux
    mov eax, AT_PHNUM
    mov rdx, [r8 + EI_PHNUM]
    call .aux
    mov eax, AT_PAGESZ
    mov edx, 4096
    call .aux
    mov eax, AT_BASE
    mov rdx, [r8 + EI_SIZE + EI_BASE]
    call .aux
    mov eax, AT_FLAGS
    xor edx, edx
    call .aux
    mov eax, AT_ENTRY
    mov rdx, [r8 + EI_ENTRY]
    call .aux
    mov eax, AT_UID
    xor edx, edx
    call .aux
    mov eax, AT_EUID
    call .aux
    mov eax, AT_GID
    call .aux
    mov eax, AT_EGID
    call .aux
    mov eax, AT_SECURE
    call .aux
    mov eax, AT_HWCAP
    mov edx, [cpu_f1_edx]
    call .aux
    mov eax, AT_HWCAP2
    xor edx, edx
    call .aux
    mov eax, AT_CLKTCK
    mov edx, 100
    call .aux
    mov eax, AT_RANDOM
    mov rdx, [rsp + 56]
    call .aux
    mov eax, AT_PLATFORM
    mov rdx, [rsp + 48]
    call .aux
    mov eax, AT_EXECFN
    mov rdx, [rsp + 24]
    call .aux
    xor eax, eax                        ; AT_NULL
    xor edx, edx
    call .aux
    mov rdi, [rsp]                      ; all of it, to the program
    mov rsi, [rsp + 16]
    mov rdx, rbp
    mov rcx, rbx
    mov r8d, LXA_WRITE
    call lx_copy
    push rax
    mov rdi, rbp
    call vm_free
    pop rax
    cmp rax, -4095
    jae .out
    mov rax, [rsp + 16]
    jmp .out
.nomem:
    mov rax, -ENOMEM
.out:
    add rsp, 64
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; (RSI = a string, RDI = where the strings below it end) -> RDI = where it
; starts here, RAX = there
.string:
    push rdi
    mov rdi, rsi
    call strlen
    pop rdi
    lea rcx, [rax + 1]
    sub rdi, rcx
    push rdi
    rep movsb
    pop rdi
    jmp .user

; (RSI = a block, RDI as above) -> its strings below RDI, RAX = there
.block:
    mov ecx, [rsi + 4]
    sub rdi, rcx
    push rdi
    add rsi, 8
    rep movsb
    pop rdi
; (RDI = here) -> RAX = there. Preserves others.
.user:
    mov rax, rdi
    sub rax, rbp
    add rax, [rsp + 8 + 16]             ; (past the return address)
    ret

; (RDI = where the vector goes on, RDX = the first string there, ECX = how
; many, each NUL-ended after the one before) -> their pointers, then 0
.pointers:
    test ecx, ecx
    jz .ended
    mov rax, rdx
    stosq
    push rdi
    push rcx
    mov rdi, rdx                        ; the next is past its NUL
    sub rdi, [rsp + 8 + 16 + 16]
    add rdi, rbp
    call strlen
    lea rdx, [rdx + rax + 1]
    pop rcx
    pop rdi
    dec ecx
    jmp .pointers
.ended:
    xor eax, eax
    stosq
    ret

; (EAX = AT_*, RDX = its value) -> a pair, at RDI
.aux:
    stosq
    mov rax, rdx
    stosq
    ret

; lx_random_word -> RAX = 64 random bits (rand_word, which needs no SIMD).
; Preserves others.
lx_random_word:
    cmp byte [rnd_hw], 0
    jne rand_word
    call rand_detect
    jmp rand_word

; lx_random_out(RDI = user dest, RSI = bytes) -> RAX = bytes, or -EFAULT
lx_random_out:
    push rbx
    push r12
    push r13
    sub rsp, 256
    mov r12, rdi
    mov r13, rsi
    xor ebx, ebx
.chunk:
    mov rdx, r13
    sub rdx, rbx
    jz .done
    cmp rdx, 256
    jbe .fill
    mov edx, 256
.fill:
    xor ecx, ecx
.word:
    call lx_random_word
    mov [rsp + rcx], rax
    add ecx, 8
    cmp ecx, edx
    jb .word
    lea rdi, [r12 + rbx]
    mov rsi, rsp
    push rdx
    call lx_copy_out
    pop rdx
    cmp rax, -4095
    jae .out
    add rbx, rdx
    jmp .chunk
.done:
    mov rax, rbx
.out:
    add rsp, 256
    pop r13
    pop r12
    pop rbx
    ret

; lx_spawn(RDI = the program's node, RSI = its arguments, RDX = its
; environment, RCX = the terminal it was run in, R8 = the path) -> RAX = its
; task (a reference), or -errno. The main thread's.
lx_spawn:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 24
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [rsp], r8
    mov rdi, [r12 + LN_NAME]
    call cur_task
    mov rsi, rax
    call task_new
    test rax, rax
    jz .nomem_none
    mov rbx, rax                        ; RBX = the task
    call as_new
    test rax, rax
    jz .nomem
    mov [rbx + TK_AS], rax
    mov edi, LP_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbp, rax                        ; RBP = the process
    mov [rbx + TK_LX], rbp
    mov [rbp + LP_TASK], rbx
    mov eax, 1
    lock xadd [lx_next_pid], eax
    add eax, LX_PID_FIRST
    mov [rbp + LP_PID], eax
    mov dword [rbp + LP_PPID], 1
    mov dword [rbp + LP_UMASK], 0o022
    mov rsi, [r12 + LN_NAME]
    lea rdi, [rbp + LP_COMM]
    mov ecx, 15
.comm:
    lodsb
    stosb
    test al, al
    jz .commed
    dec ecx
    jnz .comm
.commed:
    mov rax, [lx_root]
    mov [rbp + LP_CWD], rax
    mov [rbp + LP_EXE], r12
    mov edi, LX_FD_FIRST * 8
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbp + LP_FDS], rax
    mov dword [rbp + LP_NFD], LX_FD_FIRST
    mov rdi, r15                        ; its terminal: 0, 1 and 2
    call ly_new
    test rax, rax
    jz .nomem
    mov [rbp + LP_TTY], rax
    lea rdi, [str_lxp_tty]
    mov rsi, [lx_root]
    xor edx, edx
    call lx_lookup
    cmp rax, -4095
    jb .tty_node
    xor eax, eax
.tty_node:
    mov [rsp + 8], rax                  ; /dev/tty's node
    xor r15d, r15d
.std:
    mov edi, LFK_TTY
    mov rsi, [rsp + 8]
    mov edx, O_RDWR
    call lf_new
    test rax, rax
    jz .nomem
    mov rdi, [rbp + LP_TTY]
    mov [rax + LF_TTY], rdi
    call ly_get
    mov rcx, [rbp + LP_FDS]
    mov [rcx + r15 * 8], rax
    inc r15d
    cmp r15d, 3
    jb .std
    mov rdi, [rbx + TK_AS]              ; the program in its memory
    mov rsi, r12
    mov rdx, r13
    mov rcx, r14
    mov r8, [rsp]
    call lx_exec_image
    cmp rax, -4095
    jae .failed
    mov rdi, rax                        ; its first thread
    mov rsi, rdx
    xor edx, edx
    mov rcx, rbx
    call user_thread
    test rax, rax
    jz .nomem
    mov r12, rax
    or qword [r12 + TH_FLAGS], TF_LINUX
    mov eax, [rbp + LP_PID]
    mov [r12 + TH_TID], eax
    mov dword [rbp + LP_LIVE], 1
    mov rdi, r12
    call thread_start
    mov rdi, r12
    call thread_put
    lock inc qword [lx_started]
    mov rax, rbx
    jmp .out
.nomem:
    mov rax, -ENOMEM
.failed:
    push rax
    mov rdi, rbx                        ; and all it had, with it
    call obj_put
    pop rax
    jmp .out
.nomem_none:
    mov rax, -ENOMEM
.out:
    add rsp, 24
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The shell: linux, and its end
; -----------------------------------------------------------------------------

; lx_args(RSI = a command line) -> RAX = a block of its words (count, bytes,
; the strings), from the heap; quotes ' and " keep spaces; 0 if out of memory
lx_args:
    push rbx
    push r12
    mov r12, rsi
    mov rdi, rsi
    call strlen
    lea rdi, [rax + 16]
    call kmalloc
    test rax, rax
    jz .out
    mov rbx, rax
    lea rdi, [rbx + 8]
    mov rsi, r12
.word:
    lodsb
    cmp al, ' '
    je .word
    test al, al
    jz .done
    inc dword [rbx]
    dec rsi
    xor edx, edx                        ; the quote we are in, or 0
.char:
    lodsb
    test al, al
    jz .ended
    test dl, dl
    jnz .quoted
    cmp al, ' '
    je .ended
    cmp al, "'"
    je .open
    cmp al, '"'
    je .open
    stosb
    jmp .char
.open:
    mov dl, al
    jmp .char
.quoted:
    cmp al, dl
    je .close
    stosb
    jmp .char
.close:
    xor edx, edx
    jmp .char
.ended:
    push rax
    xor eax, eax
    stosb
    pop rax
    test al, al
    jnz .word
.done:
    lea rax, [rbx + 8]
    sub rdi, rax
    mov [rbx + 4], edi
    mov rax, rbx
.out:
    pop r12
    pop rbx
    ret

; lx_find(RDI = a program's name, or a path) -> RAX = its node, or -errno:
; on the Linux PATH, if it has no slash
lx_find:
    push rbx
    push r12
    push r13
    sub rsp, LX_PATH
    mov r12, rdi
    mov rsi, rdi
.slash:
    lodsb
    test al, al
    jz .search
    cmp al, '/'
    jne .slash
    mov rdi, r12                        ; a path: from /
    mov rsi, [lx_root]
    xor edx, edx
    call lx_lookup
    jmp .check
.search:
    lea r13, [lx_path_dirs]
.dir:
    mov rsi, [r13]
    mov rax, -ENOENT
    test rsi, rsi
    jz .out
    mov rdi, rsp
.copy_dir:
    lodsb
    stosb
    test al, al
    jnz .copy_dir
    mov byte [rdi - 1], '/'
    mov rsi, r12
.copy_name:
    lodsb
    stosb
    test al, al
    jnz .copy_name
    mov rdi, rsp
    mov rsi, [lx_root]
    xor edx, edx
    call lx_lookup
    add r13, 8
    cmp rax, -4095
    jae .dir
.check:
    cmp rax, -4095
    jae .out
    cmp dword [rax + LN_KIND], LNK_FILE
    je .out
    mov rax, -EACCES
.out:
    add rsp, LX_PATH
    pop r13
    pop r12
    pop rbx
    ret

; linux <program> [arguments]
cmd_linux:
    push rbx
    push r12
    push r13
    sub rsp, LX_PATH
    mov rax, [lx_session]
    test rax, rax
    jnz .busy
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call lx_init
    call lx_tree_load
    jc .out
    mov rsi, [sh_args]
    call lx_args
    test rax, rax
    jz .nomem
    mov r12, rax                        ; R12 = the arguments
    lea rdi, [r12 + 8]                  ; the program: its first word
    call lx_find
    cmp rax, -4095
    jae .not_found
    mov rbx, rax
    mov rdi, rbx                        ; the path it is run by
    mov rsi, rsp
    mov edx, LX_PATH
    call lx_node_path
    cmp rax, -4095
    jae .not_found
    mov rdi, rbx
    mov rsi, r12
    lea rdx, [lx_env]
    call con_owner
    mov rcx, rax
    mov r8, rsp
    call lx_spawn
    mov r13, rax
    mov rdi, r12
    call kfree
    cmp r13, -4095
    jae .failed
    call con_owner                      ; what it says goes there
    mov [lx_con], rax
    mov [lx_session], r13               ; (its end, lx_pending, is seen
    call shell_wait                     ; by lx_service, on this thread)
    jmp .out
.failed:
    mov rdi, r13
    neg rdi
    call lx_errname
    mov rcx, [rbx + LN_NAME]
    KLOG "linux: %s cannot run: %s", rcx, rax
    jmp .out
.not_found:
    lea rcx, [r12 + 8]
    cmp rax, -ENOENT
    jne .not_program
    KLOG "linux: %s: no such program in the Linux root", rcx
    jmp .not_run
.not_program:
    mov rdi, rax
    neg rdi
    call lx_errname
    KLOG "linux: %s: %s (errno %u)", rcx, rax, rdi
.not_run:
    mov rdi, r12
    call kfree
    jmp .out
.nomem:
    KLOG "linux: out of memory"
    jmp .out
.busy:
    mov rax, [rax + TK_LX]
    lea rax, [rax + LP_COMM]
    KLOG "linux: %s is still running (ctrl+C stops it)", rax
    jmp .out
.usage:
    KLOG "usage: linux <program> [arguments]: a Linux program from /LINUX on the boot stick"
.out:
    add rsp, LX_PATH
    pop r13
    pop r12
    pop rbx
    ret

; lx_errname(RDI = errno) -> RAX = its name. Preserves others.
lx_errname:
    lea rax, [str_lx_err_other]
    cmp rdi, ENOEXEC
    jne .nomem
    lea rax, [str_lx_err_noexec]
.nomem:
    cmp rdi, ENOMEM
    jne .noent
    lea rax, [str_lx_err_nomem]
.noent:
    cmp rdi, ENOENT
    jne .io
    lea rax, [str_lx_err_noent]
.io:
    cmp rdi, EIO
    jne .acces
    lea rax, [str_lx_err_io]
.acces:
    cmp rdi, EACCES
    jne .out
    lea rax, [str_lx_err_acces]
.out:
    ret

; lx_service: from the main loop. Files programs wait for; the process
; 'linux' started, once it has ended, is said, and goes.
lx_service:
    call lx_load_service
    cmp byte [lx_pending], 0
    je .out
    mov byte [lx_pending], 0            ; (before LP_ENDED is looked at)
    mov rdi, [lx_session]
    test rdi, rdi
    jz .out
    mov rax, [rdi + TK_LX]
    cmp dword [rax + LP_ENDED], 0
    je .out
    mov r11, [lx_con]                   ; said where it was run
    lea rax, [lx_said]
    call con_call
    xor edi, edi
    xchg rdi, [lx_session]
    call obj_put
    mov r11, [lx_con]
    lea rax, [shell_resume]
    call con_call
.out:
    ret

; lx_said(RDI = a task whose process ended): how
lx_said:
    mov rax, [rdi + TK_LX]
    lea rcx, [rax + LP_COMM]
    mov edx, [rax + LP_STATUS]
    movzx esi, dl
    test esi, esi
    jz .exited
    cmp esi, SIGKILL
    je .stopped
    KLOG "linux: %s ended by signal %u", rcx, rsi
    ret
.stopped:
    KLOG "linux: %s stopped", rcx
    ret
.exited:
    shr edx, 8
    and edx, 0xFF
    KLOG "linux: %s exited with %u", rcx, rdx
    ret

; lx_forget(RDI = a terminal): the process run there is killed (ctrl+C
; there, or it closed). Preserves RDI.
lx_forget:
    mov rax, [lx_session]
    test rax, rax
    jz .out
    cmp rdi, [lx_con]
    jne .out
    push rdi
    mov rdi, rax
    call task_kill
    pop rdi
.out:
    ret

; -----------------------------------------------------------------------------
;  Time
; -----------------------------------------------------------------------------

; lx_time_init: the wall clock at boot, from the CMOS clock (taken as UTC)
lx_time_init:
    push rbx
    call rtc_read
    mov rax, [rtc_year]                 ; days since 1970 (days_from_civil)
    mov rcx, [rtc_mon]
    mov rdx, [rtc_day]
    cmp rcx, 2
    ja .march
    dec rax
.march:
    mov r8, rax                         ; R8 = the year, from March
    xor edx, edx
    mov ebx, 400
    div rbx                             ; RAX = era, RDX = year of era
    mov r9, rax
    mov r10, rdx
    mov rax, [rtc_mon]                  ; day of the year, from March
    lea rcx, [rax - 3]
    cmp rax, 2
    ja .doy
    lea rcx, [rax + 9]
.doy:
    imul rax, rcx, 153
    add rax, 2
    xor edx, edx
    mov ebx, 5
    div rbx
    add rax, [rtc_day]
    dec rax
    mov r11, rax                        ; R11 = day of the year
    imul rax, r10, 365                  ; day of the era
    mov rcx, r10
    shr rcx, 2
    add rax, rcx
    mov rcx, r10
    push rax
    mov rax, rcx
    xor edx, edx
    mov ebx, 100
    div rbx
    mov rcx, rax
    pop rax
    sub rax, rcx
    add rax, r11
    imul rcx, r9, 146097
    add rax, rcx
    sub rax, 719468
    imul rax, rax, 86400                ; seconds
    imul rcx, [rtc_hour], 3600
    add rax, rcx
    imul rcx, [rtc_min], 60
    add rax, rcx
    add rax, [rtc_sec]
    mov rbx, rax
    call lx_now_ns                      ; less the time since boot
    mov rcx, 1000000000
    imul rbx, rcx
    sub rbx, rax
    mov [lx_epoch_ns], rbx
    mov rax, rbx
    xor edx, edx
    div rcx
    mov [lx_epoch_boot], rax
    pop rbx
    ret

; lx_now_ns -> RAX = nanoseconds since the TSC started. Preserves others.
lx_now_ns:
    push rcx
    push rdx
    RDTSC64
    xor edx, edx
    mov rcx, [tsc_per_us]
    div rcx                             ; RAX = microseconds, RDX = cycles over
    imul rax, rax, 1000
    push rax
    imul rax, rdx, 1000
    xor edx, edx
    div rcx
    pop rcx
    add rax, rcx
    pop rdx
    pop rcx
    ret

; lx_ts_out(RDI = user timespec, RAX = nanoseconds) -> RAX = 0 or -EFAULT
lx_ts_out:
    push rdi
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    pop rdi
    push rdx
    push rax
    mov rsi, rsp
    mov edx, 16
    call lx_copy_out
    add rsp, 16
    ret

; lx_ts_in(RDI = user timespec) -> RAX = its nanoseconds, or -EFAULT / -EINVAL
lx_ts_in:
    sub rsp, 16
    mov rsi, rdi
    mov rdi, rsp
    mov edx, 16
    call lx_copy_in
    cmp rax, -4095
    jae .out
    mov rax, -EINVAL
    mov rcx, [rsp + 8]
    cmp rcx, 1000000000
    jae .out
    mov rax, [rsp]
    test rax, rax
    js .einval
    mov rdx, 1000000000
    imul rax, rdx
    jo .forever
    add rax, rcx
    jmp .out
.forever:
    mov rax, 0x7FFFFFFFFFFFFFFF
    jmp .out
.einval:
    mov rax, -EINVAL
.out:
    add rsp, 16
    ret

; clock_gettime(clock, ts)
lx_sys_clock_gettime:
    call lx_now_ns
    cmp edi, 0                          ; CLOCK_REALTIME
    je .wall
    cmp edi, 5                          ; CLOCK_REALTIME_COARSE
    jne .out
.wall:
    add rax, [lx_epoch_ns]
.out:
    mov rdi, rsi
    jmp lx_ts_out

; clock_getres(clock, res)
lx_sys_clock_getres:
    xor eax, eax
    test rsi, rsi
    jz .out
    mov rdi, rsi
    mov eax, 1
    jmp lx_ts_out
.out:
    ret

; gettimeofday(tv, tz)
lx_sys_gettimeofday:
    xor eax, eax
    test rdi, rdi
    jz .out
    call lx_now_ns
    add rax, [lx_epoch_ns]
    xor edx, edx
    mov ecx, 1000
    div rcx                             ; microseconds
    xor edx, edx
    mov ecx, 1000000
    div rcx
    push rdx
    push rax
    mov rsi, rsp
    mov edx, 16
    call lx_copy_out
    add rsp, 16
.out:
    ret

; time(tloc)
lx_sys_time:
    push rdi
    call lx_now_ns
    add rax, [lx_epoch_ns]
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    pop rdi
    test rdi, rdi
    jz .out
    push rax
    mov rsi, rax
    call lx_put64
    test rax, rax
    pop rax
    jz .out
    mov rax, -EFAULT
.out:
    ret

; lx_sleep_until(RDI = TSC) -> RAX = 0, or -EINTR if the process is being
; killed first
lx_sleep_until:
    mov rdx, rdi
    lea rdi, [lx_sleep_wq]
    lea rsi, [lx_never]
    call wq_wait
    call user_killed
    neg rax
    and rax, -EINTR
    ret

; lx_ns_tsc(RAX = nanoseconds from now) -> RAX = the TSC then. Preserves others.
lx_ns_tsc:
    push rcx
    push rdx
    xor edx, edx
    mov ecx, 1000
    div rcx                             ; microseconds
    mov rcx, 0x0000FFFFFFFFFFFF         ; (far off: never)
    cmp rax, rcx
    cmova rax, rcx
    imul rax, [tsc_per_us]
    mov rcx, rax
    RDTSC64
    add rax, rcx
    pop rdx
    pop rcx
    ret

; nanosleep(req, rem)
lx_sys_nanosleep:
    call lx_ts_in
    cmp rax, -4095
    jae .out
    call lx_ns_tsc
    mov rdi, rax
    call lx_sleep_until
.out:
    ret

; clock_nanosleep(clock, flags, req, rem)
lx_sys_clock_nanosleep:
    push rbx
    push r12
    mov ebx, edi
    mov r12d, esi
    mov rdi, rdx
    call lx_ts_in
    cmp rax, -4095
    jae .out
    test r12d, 1                        ; TIMER_ABSTIME
    jz .relative
    mov rcx, rax
    call lx_now_ns
    test ebx, ebx
    jz .wall
    cmp ebx, 5
    jne .now
.wall:
    add rax, [lx_epoch_ns]
.now:
    sub rcx, rax
    jbe .zero
    mov rax, rcx
.relative:
    call lx_ns_tsc
    mov rdi, rax
    call lx_sleep_until
    jmp .out
.zero:
    xor eax, eax
.out:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Who it is, and the rest
; -----------------------------------------------------------------------------

lx_sys_getpid:
    call lx_cur_proc
    mov eax, [rax + LP_PID]
    ret

lx_sys_getppid:
    call lx_cur_proc
    mov eax, [rax + LP_PPID]
    ret

lx_sys_gettid:
    mov rax, [gs:PC_CURRENT]
    mov eax, [rax + TH_TID]
    ret

; getgroups(size, list): root's group
lx_sys_getgroups:
    mov eax, 1
    test edi, edi
    jz .out
    mov rdi, rsi
    xor esi, esi
    call lx_put32
    test rax, rax
    jnz .out
    mov eax, 1
.out:
    ret

; uname(buf)
lx_sys_uname:
    sub rsp, 6 * 65 + 10
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, 6 * 65
    rep stosb
    lea rsi, [lx_uts]
    lea rdi, [rsp + 8]
.field:
    lodsq
    test rax, rax
    jz .copy
    push rsi
    push rdi
    mov rsi, rax
.char:
    lodsb
    stosb
    test al, al
    jnz .char
    pop rdi
    pop rsi
    add rdi, 65
    jmp .field
.copy:
    pop rdi
    mov rsi, rsp
    mov edx, 6 * 65
    call lx_copy_out
    add rsp, 6 * 65 + 10
    ret

; arch_prctl(code, addr)
lx_sys_arch_prctl:
    mov rax, -EINVAL
    mov rdx, [gs:PC_CURRENT]
    cmp edi, 0x1002                     ; ARCH_SET_FS
    je .set_fs
    cmp edi, 0x1001                     ; ARCH_SET_GS
    je .set_gs
    cmp edi, 0x1003                     ; ARCH_GET_FS
    je .get_fs
    cmp edi, 0x1004                     ; ARCH_GET_GS
    je .get_gs
    ret
.set_fs:
    mov rax, -EPERM
    mov rcx, USER_TOP
    cmp rsi, rcx
    jae .out
    pushfq
    cli
    mov [rdx + TH_FSBASE], rsi
    mov [gs:PC_FSBASE], rsi
    mov eax, esi
    mov rdx, rsi
    shr rdx, 32
    mov ecx, MSR_FS_BASE
    wrmsr
    popfq
    xor eax, eax
.out:
    ret
.set_gs:
    mov rax, -EPERM
    mov rcx, USER_TOP
    cmp rsi, rcx
    jae .out
    pushfq
    cli
    mov [rdx + TH_GSBASE], rsi
    mov [gs:PC_UGSBASE], rsi
    mov eax, esi
    mov rdx, rsi
    shr rdx, 32
    mov ecx, MSR_KGS_BASE
    wrmsr
    popfq
    xor eax, eax
    ret
.get_fs:
    mov rdi, rsi
    mov rsi, [rdx + TH_FSBASE]
    jmp lx_put64
.get_gs:
    mov rdi, rsi
    mov rsi, [rdx + TH_GSBASE]
    jmp lx_put64

; set_tid_address(tidptr) -> the thread's id
lx_sys_set_tid_address:
    mov rax, [gs:PC_CURRENT]
    mov [rax + TH_CTID], rdi
    mov eax, [rax + TH_TID]
    ret

; rt_sigaction(sig, act, oact, size): the default, for now (L2)
lx_sys_rt_sigaction:
    mov rax, -EINVAL
    dec edi
    cmp edi, 64
    jae .out
    xor eax, eax
    test rdx, rdx
    jz .out
    mov rdi, rdx
    mov esi, 32
    call lx_zero_out
.out:
    ret

; rt_sigprocmask(how, set, oset, size)
lx_sys_rt_sigprocmask:
    push rbx
    push r12
    mov ebx, edi
    mov r12, rsi
    mov r8, [gs:PC_CURRENT]
    test rdx, rdx
    jz .set
    mov rdi, rdx
    mov rsi, [r8 + TH_SIGMASK]
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
    mov rcx, (1 << (SIGKILL - 1)) | (1 << 18)   ; SIGKILL, SIGSTOP: never
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

; sigaltstack(ss, oss)
lx_sys_sigaltstack:
    xor eax, eax
    test rsi, rsi
    jz .out
    sub rsp, 24
    mov qword [rsp], 0
    mov qword [rsp + 8], 2              ; SS_DISABLE
    mov qword [rsp + 16], 0
    mov rdi, rsi
    mov rsi, rsp
    mov edx, 24
    call lx_copy_out
    add rsp, 24
.out:
    ret

; futex(uaddr, op, val, ...): one thread, for now (L2)
lx_sys_futex:
    and esi, 0x7F                       ; less FUTEX_PRIVATE_FLAG
    cmp esi, 1                          ; FUTEX_WAKE
    je .none
    cmp esi, 0                          ; FUTEX_WAIT: it changed, or nothing
    je .wait                            ; would ever wake it
    mov rax, -ENOSYS
    ret
.none:
    xor eax, eax
    ret
.wait:
    mov rax, -EAGAIN
    ret

; prlimit64(pid, resource, new, old) / getrlimit(resource, rlim)
lx_sys_getrlimit:
    mov rdx, rsi
    mov esi, edi
    xor ecx, ecx
    xchg rcx, rdx
    jmp lx_rlimit
lx_sys_prlimit64:
lx_rlimit:
    xor eax, eax
    test rcx, rcx
    jz .out
    sub rsp, 16
    mov qword [rsp], -1                 ; RLIM_INFINITY
    mov qword [rsp + 8], -1
    cmp esi, 3                          ; RLIMIT_STACK
    jne .nofile
    mov qword [rsp], LX_STACK_SIZE
.nofile:
    cmp esi, 7                          ; RLIMIT_NOFILE
    jne .copy
    mov qword [rsp], LX_FD_MAX
    mov qword [rsp + 8], LX_FD_MAX
.copy:
    mov rdi, rcx
    mov rsi, rsp
    mov edx, 16
    call lx_copy_out
    add rsp, 16
.out:
    ret

; sched_getaffinity(pid, size, mask): every CPU online
lx_sys_sched_getaffinity:
    mov rax, -EINVAL
    cmp rsi, 8
    jb .out
    mov ecx, [cpus_online]
    mov rax, -1
    cmp ecx, 64
    jae .mask
    mov eax, 1
    shl rax, cl
    dec rax
.mask:
    mov rdi, rdx
    mov rsi, rax
    call lx_put64
    test rax, rax
    jnz .out
    mov eax, 8
.out:
    ret

; sched_yield()
lx_sys_sched_yield:
    call thread_yield
    xor eax, eax
    ret

; getrandom(buf, count, flags)
lx_sys_getrandom:
    mov rax, -EINVAL
    test edx, ~7
    jnz .out
    mov rax, 0x1FFFFFF
    cmp rsi, rax
    cmova rsi, rax
    jmp lx_random_out
.out:
    ret

; sysinfo(info)
lx_sys_sysinfo:
    sub rsp, 112
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, 112 / 8
    rep stosq
    call lx_now_ns
    xor edx, edx
    mov ecx, 1000000000
    div rcx
    mov [rsp + 8], rax                  ; uptime
    mov rax, [pmm_pages]
    shl rax, 12
    mov [rsp + 8 + 32], rax             ; totalram
    mov rax, [pmm_free_pages]
    shl rax, 12
    mov [rsp + 8 + 40], rax             ; freeram
    mov word [rsp + 8 + 80], 1          ; procs
    mov dword [rsp + 8 + 104], 1        ; mem_unit
    pop rdi
    mov rsi, rsp
    mov edx, 112
    call lx_copy_out
    add rsp, 112
    ret

; getrusage(who, usage): none counted
lx_sys_getrusage:
    mov rdi, rsi
    mov esi, 144
    jmp lx_zero_out

; times(buf) -> clock ticks since boot
lx_sys_times:
    test rdi, rdi
    jz .now
    mov esi, 32
    call lx_zero_out
    test rax, rax
    jnz .out
.now:
    call lx_now_ns
    xor edx, edx
    mov ecx, 10000000
    div rcx
.out:
    ret

; prctl(option, arg2, ...)
lx_sys_prctl:
    cmp edi, 15                         ; PR_SET_NAME
    je .set_name
    cmp edi, 16                         ; PR_GET_NAME
    je .get_name
    cmp edi, 3                          ; PR_GET_DUMPABLE
    je .one
    xor eax, eax
    cmp edi, 1                          ; PR_SET_PDEATHSIG
    je .out
    cmp edi, 4                          ; PR_SET_DUMPABLE
    je .out
    cmp edi, 0x53564D41                 ; PR_SET_VMA
    je .out
    cmp edi, 38                         ; PR_SET_NO_NEW_PRIVS
    je .out
    mov rax, -EINVAL
.out:
    ret
.one:
    mov eax, 1
    ret
.set_name:
    sub rsp, 16
    mov rdi, rsp
    mov edx, 16
    call lx_copy_str
    cmp rax, -4095
    jb .named
    cmp rax, -ENAMETOOLONG
    jne .set_out
.named:
    mov byte [rsp + 15], 0
    call lx_cur_proc
    mov rcx, [rsp]
    mov [rax + LP_COMM], rcx
    mov rcx, [rsp + 8]
    mov [rax + LP_COMM + 8], rcx
    xor eax, eax
.set_out:
    add rsp, 16
    ret
.get_name:
    mov rdi, rsi
    call lx_cur_proc
    lea rsi, [rax + LP_COMM]
    mov edx, 16
    call lx_copy_out
    ret

; socket(...): no network yet (L5)
lx_sys_socket:
    mov rax, -EAFNOSUPPORT
    ret

; getpgrp, getpgid, getsid, setsid: the process is its own
lx_sys_getpgrp:
    jmp lx_sys_getpid

; getresuid(ruid, euid, suid) / getresgid: root's, 0 each
lx_sys_getresuid:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, rsi
    mov r13, rdx
    mov rdi, rbx
    xor esi, esi
    call lx_put32
    test rax, rax
    jnz .out
    mov rdi, r12
    xor esi, esi
    call lx_put32
    test rax, rax
    jnz .out
    mov rdi, r13
    xor esi, esi
    call lx_put32
.out:
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
str_lx_platform: db 'x86_64', 0
str_lx_err_other: db 'not a program it can run', 0
str_lx_err_noexec: db 'not an x86-64 ELF program', 0
str_lx_err_nomem: db 'out of memory', 0
str_lx_err_noent: db 'something it needs is not in the root', 0
str_lx_err_io:  db 'its file could not be read', 0
str_lx_err_acces: db 'not a file it can run', 0
str_lxu_sys:    db 'Linux', 0
str_lxu_node:   db 'axiom', 0
str_lxu_release: db '6.8.0-axiom', 0
str_lxu_version: db '#1 SMP PREEMPT_DYNAMIC Axiom', 0
str_lxu_machine: db 'x86_64', 0
str_lxu_domain: db '(none)', 0
str_lxd_1:      db '/usr/local/bin', 0
str_lxd_2:      db '/usr/bin', 0
str_lxd_3:      db '/bin', 0
str_lxd_4:      db '/usr/local/sbin', 0
str_lxd_5:      db '/usr/sbin', 0
str_lxd_6:      db '/sbin', 0
str_lxd_7:      db '/test', 0
align 8
lx_uts:         dq str_lxu_sys, str_lxu_node, str_lxu_release, str_lxu_version
                dq str_lxu_machine, str_lxu_domain, 0
lx_path_dirs:   dq str_lxd_1, str_lxd_2, str_lxd_3, str_lxd_4, str_lxd_5, str_lxd_6
                dq str_lxd_7, 0
; the signal each exception ends a process by (vectors 0-19)
lx_fault_signals:
    db SIGFPE, SIGTRAP, SIGSEGV, SIGTRAP, SIGSEGV, SIGSEGV, SIGILL, SIGFPE
    db SIGSEGV, SIGFPE, SIGSEGV, SIGBUS, SIGBUS, SIGSEGV, SIGSEGV, SIGSEGV
    db SIGFPE, SIGBUS, SIGSEGV, SIGFPE
align 8
; the environment programs start with
lx_env:
    dd 7, lx_env_end - lx_env_strings
lx_env_strings:
    db 'PATH=/usr/local/bin:/usr/bin:/bin:/usr/local/sbin:/usr/sbin:/sbin', 0
    db 'HOME=/root', 0
    db 'USER=root', 0
    db 'LOGNAME=root', 0
    db 'SHELL=/bin/bash', 0
    db 'TERM=dumb', 0
    db 'PWD=/', 0
lx_env_end:
align 8
lx_never:       dd 0
align 8
; Linux's system calls: its number, and what does it here
lx_calls:
    dq 0, lx_sys_read
    dq 1, lx_sys_write
    dq 2, lx_sys_open
    dq 3, lx_sys_close
    dq 4, lx_sys_stat
    dq 5, lx_sys_fstat
    dq 6, lx_sys_lstat
    dq 8, lx_sys_lseek
    dq 9, lx_sys_mmap
    dq 10, lx_sys_mprotect
    dq 11, lx_sys_munmap
    dq 12, lx_sys_brk
    dq 13, lx_sys_rt_sigaction
    dq 14, lx_sys_rt_sigprocmask
    dq 16, lx_sys_ioctl
    dq 17, lx_sys_pread
    dq 19, lx_sys_readv
    dq 20, lx_sys_writev
    dq 21, lx_sys_access
    dq 24, lx_sys_sched_yield
    dq 25, lx_sys_mremap
    dq 28, lx_sys_madvise
    dq 32, lx_sys_dup
    dq 33, lx_sys_dup2
    dq 35, lx_sys_nanosleep
    dq 39, lx_sys_getpid
    dq 41, lx_sys_socket
    dq 60, lx_sys_exit
    dq 63, lx_sys_uname
    dq 72, lx_sys_fcntl
    dq 79, lx_sys_getcwd
    dq 80, lx_sys_chdir
    dq 81, lx_sys_fchdir
    dq 89, lx_sys_readlink
    dq 95, lx_sys_umask
    dq 96, lx_sys_gettimeofday
    dq 97, lx_sys_getrlimit
    dq 98, lx_sys_getrusage
    dq 99, lx_sys_sysinfo
    dq 100, lx_sys_times
    dq 102, lx_sys_zero                 ; getuid
    dq 104, lx_sys_zero                 ; getgid
    dq 105, lx_sys_zero                 ; setuid
    dq 106, lx_sys_zero                 ; setgid
    dq 107, lx_sys_zero                 ; geteuid
    dq 108, lx_sys_zero                 ; getegid
    dq 110, lx_sys_getppid
    dq 111, lx_sys_getpgrp
    dq 112, lx_sys_getpgrp              ; setsid
    dq 115, lx_sys_getgroups
    dq 118, lx_sys_getresuid
    dq 120, lx_sys_getresuid            ; getresgid
    dq 121, lx_sys_getpgrp              ; getpgid
    dq 124, lx_sys_getpgrp              ; getsid
    dq 131, lx_sys_sigaltstack
    dq 137, lx_sys_statfs
    dq 138, lx_sys_fstatfs
    dq 157, lx_sys_prctl
    dq 158, lx_sys_arch_prctl
    dq 160, lx_sys_zero                 ; setrlimit
    dq 186, lx_sys_gettid
    dq 188, lx_sys_xattr
    dq 189, lx_sys_xattr
    dq 190, lx_sys_xattr
    dq 191, lx_sys_xattr
    dq 192, lx_sys_xattr
    dq 193, lx_sys_xattr
    dq 194, lx_sys_xattr
    dq 195, lx_sys_xattr
    dq 196, lx_sys_xattr
    dq 197, lx_sys_xattr
    dq 198, lx_sys_xattr
    dq 199, lx_sys_xattr
    dq 201, lx_sys_time
    dq 202, lx_sys_futex
    dq 203, lx_sys_zero                 ; sched_setaffinity
    dq 204, lx_sys_sched_getaffinity
    dq 217, lx_sys_getdents64
    dq 221, lx_sys_zero                 ; fadvise64
    dq 218, lx_sys_set_tid_address
    dq 228, lx_sys_clock_gettime
    dq 229, lx_sys_clock_getres
    dq 230, lx_sys_clock_nanosleep
    dq 231, lx_sys_exit_group
    dq 257, lx_sys_openat
    dq 262, lx_sys_newfstatat
    dq 267, lx_sys_readlinkat
    dq 269, lx_sys_faccessat
    dq 273, lx_sys_zero                 ; set_robust_list
    dq 292, lx_sys_dup3
    dq 302, lx_sys_prlimit64
    dq 318, lx_sys_getrandom
    dq 332, lx_sys_statx
    dq 334, lx_sys_enosys               ; rseq
    dq 439, lx_sys_faccessat            ; faccessat2
    dq -1

section .bss
alignb 8
lx_table:       resq LX_NSYS
lx_nosys_seen:  resb 64
lx_session:     resq 1                  ; the process 'linux' started, a task (a reference)
lx_con:         resq 1                  ; the terminal it was run in
lx_epoch_ns:    resq 1                  ; the wall clock when the TSC was 0
lx_epoch_boot:  resq 1                  ; and in seconds
lx_started:     resq 1
lx_sleep_wq:    resb WQ_SIZE
lx_next_pid:    resd 1
lx_ready:       resb 1
lx_pending:     resb 1                  ; the process ended: lx_service says so
