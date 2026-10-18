; =============================================================================
;  lxpipe.asm - pipes, for Linux programs
;
;  pipe and pipe2 make a pipe (PI_*): a ring of PIPE_SIZE bytes, read from
;  one open file (LFK_PIPE, O_RDONLY) and written from another (O_WRONLY),
;  each shared by however many descriptors and processes hold it. A read
;  waits for bytes, or ends (0) once no file writes it any more; a write
;  waits for room (one of PIPE_BUF bytes or fewer goes in whole), and with
;  no file reading it fails (EPIPE) and sends the writer SIGPIPE. O_NONBLOCK
;  makes either EAGAIN instead of waiting; a signal ends a wait. Waits are
;  poll's (lx_poll_wq): every change kicks them. The bytes move under the
;  pipe's lx_mutex; its ends close by atomic counts, and its last end frees
;  it.
; =============================================================================

PIPE_SIZE       equ 65536               ; (a power of two)
PIPE_BUF        equ 4096                ; written whole, at most
PI_LOCK         equ 0                   ; dword: lx_mutex, the bytes and where they are
PI_READERS      equ 4                   ; dword: open files reading it
PI_WRITERS      equ 8                   ; dword: and writing
PI_ENDS         equ 12                  ; dword: open files, both kinds
PI_HEAD         equ 16                  ; bytes read, ever
PI_TAIL         equ 24                  ; bytes written, ever
PI_BUF          equ 32                  ; PIPE_SIZE bytes (vm)
PI_SIZE         equ 40
SIGPIPE_NUM     equ 13
F_SETPIPE_SZ    equ 1031
F_GETPIPE_SZ    equ 1032
LX_PIPE_INO     equ 0x7000000000

section .text

; pipe(fds)
lx_sys_pipe:
    xor esi, esi
; pipe2(fds, flags)
lx_sys_pipe2:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rdi                        ; R12 = fds
    mov r13d, esi                       ; R13 = flags
    mov rax, -EINVAL
    test r13d, ~(O_CLOEXEC | O_NONBLOCK | 0x4000)   ; (O_DIRECT: as a stream)
    jnz .out
    mov edi, PI_SIZE
    call kmalloc
    test rax, rax
    jz .nomem
    mov rbx, rax                        ; RBX = the pipe
    mov edi, PIPE_SIZE
    call vm_alloc
    test rax, rax
    jz .nomem_pipe
    mov [rbx + PI_BUF], rax
    mov edi, LFK_PIPE                   ; its two ends
    lea rsi, [lx_pipe_node]
    mov edx, r13d
    and edx, O_NONBLOCK
    call lf_new
    test rax, rax
    jz .nomem_buf
    mov r14, rax                        ; R14 = reading
    mov [r14 + LF_PIPE], rbx
    mov edi, LFK_PIPE
    or edx, O_WRONLY
    call lf_new
    test rax, rax
    jz .nomem_reader
    mov r15, rax                        ; R15 = writing
    mov [r15 + LF_PIPE], rbx
    mov dword [rbx + PI_READERS], 1
    mov dword [rbx + PI_WRITERS], 1
    mov dword [rbx + PI_ENDS], 2
    call lx_cur_proc                    ; the descriptors
    mov rdi, rax
    mov rsi, r14
    xor edx, edx
    xor ecx, ecx
    test r13d, O_CLOEXEC
    setnz cl
    call lx_fd_install
    cmp rax, -4095
    jae .no_reader_fd
    mov [rsp], eax
    call lx_cur_proc
    mov rdi, rax
    mov rsi, r15
    xor edx, edx
    xor ecx, ecx
    test r13d, O_CLOEXEC
    setnz cl
    call lx_fd_install
    cmp rax, -4095
    jae .no_writer_fd
    mov [rsp + 4], eax
    mov rdi, r12
    mov rsi, rsp
    mov edx, 8
    call lx_copy_out
    test rax, rax
    jz .out
    mov rbx, rax                        ; (not there to say: both closed again)
    call lx_cur_proc
    mov rdi, rax
    mov esi, [rsp + 4]
    call lx_fd_close
    call lx_cur_proc
    mov rdi, rax
    mov esi, [rsp]
    call lx_fd_close
    mov rax, rbx
    jmp .out
.no_writer_fd:
    mov rbx, rax
    call lx_cur_proc
    mov rdi, rax
    mov esi, [rsp]
    call lx_fd_close
    mov rax, rbx
    jmp .out
.no_reader_fd:
    mov rdi, r15                        ; (the reading end went with it)
    call lf_put
    jmp .out
.nomem_reader:
    mov rdi, r14                        ; its last end: the pipe with it
    mov dword [rbx + PI_READERS], 1
    mov dword [rbx + PI_ENDS], 1
    call lf_put
    jmp .nomem
.nomem_buf:
    mov rdi, [rbx + PI_BUF]
    call vm_free
.nomem_pipe:
    mov rdi, rbx
    call kfree
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

; lx_pipe_close(RDI = a pipe's open file, its last reference gone): that end
; closed; the pipe freed with its last. Preserves all.
lx_pipe_close:
    push rax
    push rdi
    mov rax, rdi
    mov rdi, [rax + LF_PIPE]
    mov eax, [rax + LF_FLAGS]
    and eax, O_ACCMODE
    jz .reader
    lock dec dword [rdi + PI_WRITERS]
    jmp .closed
.reader:
    lock dec dword [rdi + PI_READERS]
.closed:
    call lx_poll_kick                   ; (a reader's end, a writer's EPIPE)
    lock dec dword [rdi + PI_ENDS]
    jnz .out
    push rdi
    mov rdi, [rdi + PI_BUF]
    call vm_free
    pop rdi
    call kfree
.out:
    pop rdi
    pop rax
    ret

; lx_pipe_read(RBX = a pipe's open file, RSI = user buffer, RDX = bytes) ->
; RAX = bytes read, 0 once nothing writes it, or -errno
lx_pipe_read:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + LF_PIPE]            ; R14 = the pipe
    xor eax, eax
    test r13, r13
    jz .out
.again:
    mov eax, [lx_poll_gen]              ; (before looking: nothing missed)
    mov [rsp], eax
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_lock
    mov r15, [r14 + PI_TAIL]
    sub r15, [r14 + PI_HEAD]            ; R15 = bytes there
    jnz .some
    xor eax, eax                        ; none: an end, unless something writes it
    cmp dword [r14 + PI_WRITERS], 0
    je .unlock
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    mov rax, -EAGAIN
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .out
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    xor ecx, ecx
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -ERESTARTSYS
    jmp .out
.some:
    cmp r13, r15
    cmova r13, r15                      ; R13 = bytes to read
    mov rdi, r12
    mov rsi, [r14 + PI_HEAD]
    mov rdx, r13
    call lx_pipe_out
    test rax, rax
    jnz .unlock
    add [r14 + PI_HEAD], r13
    mov rax, r13
.unlock:
    push rax
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    call lx_poll_kick                   ; (room for a writer)
    pop rax
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; (R14 = the pipe, RDI = user buffer, RSI = where in the ring, as PI_HEAD
; counts, RDX = bytes, no more than there are) -> RAX = 0 or -EFAULT
lx_pipe_out:
    push r12
    push r13
    push r15
    mov r12, rdi
    mov r13, rdx
    and esi, PIPE_SIZE - 1
    mov r15d, PIPE_SIZE                 ; to the ring's end, then from its start
    sub r15, rsi
    cmp r15, r13
    cmova r15, r13
    add rsi, [r14 + PI_BUF]
    mov rdx, r15
    call lx_copy_out
    test rax, rax
    jnz .out
    mov rdx, r13
    sub rdx, r15
    jz .out
    lea rdi, [r12 + r15]
    mov rsi, [r14 + PI_BUF]
    call lx_copy_out
.out:
    pop r15
    pop r13
    pop r12
    ret

; lx_pipe_write(RBX = a pipe's open file, RSI = user buffer, RDX = bytes)
; -> RAX = bytes written, or -errno
lx_pipe_write:
    push r12
    push r13
    push r14
    push r15
    sub rsp, 16
    mov r12, rsi
    mov r13, rdx
    mov r14, [rbx + LF_PIPE]            ; R14 = the pipe
    mov qword [rsp + 8], 0              ; [rsp + 8] = bytes written
    xor eax, eax
    test r13, r13
    jz .out
.again:
    mov eax, [lx_poll_gen]
    mov [rsp], eax
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_lock
    cmp dword [r14 + PI_READERS], 0
    je .broken
    mov r15, [r14 + PI_TAIL]            ; R15 = room
    sub r15, [r14 + PI_HEAD]
    neg r15
    add r15, PIPE_SIZE
    mov rcx, r13                        ; RCX = what it must have: all of a
    sub rcx, [rsp + 8]                  ; small write, else a byte
    cmp rcx, PIPE_BUF
    jbe .need
    mov ecx, 1
.need:
    cmp r15, rcx
    jae .room
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    mov rax, -EAGAIN
    test dword [rbx + LF_FLAGS], O_NONBLOCK
    jnz .partial
    lea rdi, [lx_poll_wq]
    lea rsi, [lx_poll_test]
    mov rdx, rsp
    xor ecx, ecx
    call wq_wait_fn
    test eax, eax
    jnz .again
    call user_killed
    test eax, eax
    jz .again
    mov rax, -ERESTARTSYS
    jmp .partial
.room:
    mov rdx, r13
    sub rdx, [rsp + 8]
    cmp rdx, r15
    cmova rdx, r15                      ; RDX = bytes to write now
    mov r15, rdx
    mov rsi, r12
    add rsi, [rsp + 8]
    mov rdi, [r14 + PI_TAIL]
    call lx_pipe_in
    test rax, rax
    jnz .unlock_partial
    add [r14 + PI_TAIL], r15
    add [rsp + 8], r15
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    call lx_poll_kick                   ; (bytes for a reader)
    cmp [rsp + 8], r13
    jb .again
    mov rax, r13
    jmp .out
.broken:
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    call lx_cur_proc                    ; SIGPIPE, to this thread
    mov rdi, rax
    mov rsi, [gs:PC_CURRENT]
    mov esi, [rsi + TH_TID]
    mov edx, SIGPIPE_NUM
    call lx_signal_tid
    mov rax, -EPIPE
    jmp .partial
.unlock_partial:
    push rax
    lea rdi, [r14 + PI_LOCK]
    call lx_mutex_unlock
    pop rax
.partial:
    cmp qword [rsp + 8], 0              ; what was written, if any was
    je .out
    mov rax, [rsp + 8]
.out:
    add rsp, 16
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; (R14 = the pipe, RDI = where in the ring, as PI_TAIL counts, RSI = user
; buffer, RDX = bytes, no more than the room) -> RAX = 0 or -EFAULT
lx_pipe_in:
    push r12
    push r13
    push r15
    mov r12, rsi
    mov r13, rdx
    and edi, PIPE_SIZE - 1
    mov r15d, PIPE_SIZE
    sub r15, rdi
    cmp r15, r13
    cmova r15, r13
    add rdi, [r14 + PI_BUF]
    mov rdx, r15
    call lx_copy_in
    test rax, rax
    jnz .out
    mov rdx, r13
    sub rdx, r15
    jz .out
    mov rdi, [r14 + PI_BUF]
    lea rsi, [r12 + r15]
    call lx_copy_in
.out:
    pop r15
    pop r13
    pop r12
    ret

; lx_pipe_ready(RDI = a pipe's open file) -> EAX = its poll events: a reader
; POLLIN with bytes there, POLLHUP with no writer; a writer POLLOUT with
; room, POLLERR with no reader. Preserves others.
lx_pipe_ready:
    push rcx
    push rdx
    mov rcx, [rdi + LF_PIPE]
    mov rdx, [rcx + PI_TAIL]
    sub rdx, [rcx + PI_HEAD]
    xor eax, eax
    test dword [rdi + LF_FLAGS], O_ACCMODE
    jnz .writer
    test rdx, rdx
    jz .no_bytes
    or eax, POLLIN | POLLRDNORM
.no_bytes:
    cmp dword [rcx + PI_WRITERS], 0
    jne .out
    or eax, POLLHUP
    jmp .out
.writer:
    cmp rdx, PIPE_SIZE
    jae .full
    or eax, POLLOUT | POLLWRNORM
.full:
    cmp dword [rcx + PI_READERS], 0
    jne .out
    or eax, POLLERR
.out:
    pop rdx
    pop rcx
    ret

; lx_pipe_count(RDI = a pipe's open file) -> EAX = bytes in it (FIONREAD).
; Preserves others.
lx_pipe_count:
    mov rax, [rdi + LF_PIPE]
    push rcx
    mov rcx, [rax + PI_TAIL]
    sub rcx, [rax + PI_HEAD]
    mov eax, ecx
    pop rcx
    ret

section .bss
alignb 8
lx_pipe_node:   resb LN_NODE_SIZE       ; what fstat says of a pipe (lx_pipe_init)

section .text

; lx_pipe_init: the pipes' node (once, from lx_init)
lx_pipe_init:
    lea rax, [str_lx_pipe]
    mov [lx_pipe_node + LN_NAME], rax
    mov dword [lx_pipe_node + LN_KIND], LNK_FIFO
    mov dword [lx_pipe_node + LN_MODE], 0o600
    mov rax, LX_PIPE_INO
    mov [lx_pipe_node + LN_INO], rax
    mov dword [lx_pipe_node + LN_STATE], LNS_LOADED
    ret

section .rodata
str_lx_pipe:    db 'pipe', 0

section .text
