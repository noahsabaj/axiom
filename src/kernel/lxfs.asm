; =============================================================================
;  lxfs.asm - what Linux programs see of files: a tree in RAM, read-only
;
;  The tree is the root mkroot.py made (tools/mkroot.py): /LINUX/META on the
;  boot stick says each path's kind, its mode and size, or where a link
;  points; a file's bytes are at /LINUX/ROOT<path>. lx_tree_load reads META
;  once, on the main thread, and makes a node (LN_*) for each path, with
;  /dev's devices (null, zero, random, urandom, tty) and /proc/self/exe
;  added. A file's bytes are read whole, the first time a program opens it,
;  into pages of their own that stay (the file cache): FAT is the main
;  thread's alone, so a program's thread asks it (lx_load_list, lx_load_service)
;  and waits. A program's mappings of a file share those pages (lxmm.asm).
;
;  A program's open files are LF_* objects, shared by the descriptors dup
;  made (LF_REFS); its descriptor table (LP_FDS) holds them, bit 0 of each
;  entry its FD_CLOEXEC. Its standard input, output and error are its
;  terminal (lxtty.asm's LY_*): the window it was run in, as a tty.
; =============================================================================

; a node of the tree
LN_NAME         equ 0                   ; its name (from the heap), NUL-ended
LN_PARENT       equ 8
LN_CHILD        equ 16                  ; a directory's first
LN_NEXT         equ 24                  ; its parent's next
LN_KIND         equ 32                  ; dword LNK_*
LN_MODE         equ 36                  ; dword: its permission bits
LN_SIZE         equ 40                  ; bytes
LN_DATA         equ 48                  ; its bytes in the cache (vm), once read
LN_TARGET       equ 56                  ; a link's target (from the heap)
LN_INO          equ 64
LN_STATE        equ 72                  ; dword LNS_*
LN_DONE         equ 76                  ; dword: 1 once read, or not readable
LN_WQ           equ 80                  ; WQ_SIZE: threads waiting for that
LN_DEV          equ 96                  ; dword LND_*: a device's, or a magic link's
LN_WRITABLE     equ 100                 ; byte: mappings may write it
LN_QNEXT        equ 104                 ; on lx_load_list
LN_NODE_SIZE    equ 128

LNK_DIR         equ 1
LNK_FILE        equ 2
LNK_LINK        equ 3
LNK_DEV         equ 4                   ; a character device
LNK_MAGIC       equ 5                   ; a link that is the process's own (/proc/self/exe)
LNK_FIFO        equ 6                   ; a pipe (lxpipe.asm's one node)

LNS_NONE        equ 0
LNS_QUEUED      equ 1
LNS_LOADED      equ 2
LNS_FAILED      equ 3

LND_NULL        equ 1
LND_ZERO        equ 2
LND_RANDOM      equ 3
LND_TTY         equ 4
LND_EXE         equ 5

; an open file
LF_REFS         equ 0                   ; dword: descriptors holding it
LF_KIND         equ 4                   ; dword LFK_*
LF_NODE         equ 8
LF_POS          equ 16
LF_FLAGS        equ 24                  ; dword: O_ACCMODE, O_APPEND, O_NONBLOCK
LF_TTY          equ 32
LF_PIPE         equ 40                  ; a pipe's (lxpipe.asm)
LF_SIZE         equ 48

LFK_FILE        equ 1
LFK_DIR         equ 2
LFK_DEV         equ 3
LFK_TTY         equ 4
LFK_PIPE        equ 5                   ; one end of a pipe

LX_PATH         equ 4096                ; a path, at most (with its NUL)
LX_NAME         equ 255                 ; a name in it
LX_LINKS        equ 40                  ; links followed in one lookup
LX_FD_FIRST     equ 64                  ; descriptors a process starts with room for
LX_FD_MAX       equ 1024

LKF_NOFOLLOW    equ 1                   ; a link at the end is itself
LKF_DIR         equ 2                   ; it must be a directory

O_ACCMODE       equ 3
O_WRONLY        equ 1
O_RDWR          equ 2
O_CREAT         equ 0x40
O_EXCL          equ 0x80
O_TRUNC         equ 0x200
O_APPEND        equ 0x400
O_NONBLOCK      equ 0x800
O_DIRECTORY     equ 0x10000
O_NOFOLLOW      equ 0x20000
O_CLOEXEC       equ 0x80000
O_PATH          equ 0x200000
AT_FDCWD        equ -100
AT_SYMLINK_NOFOLLOW equ 0x100
AT_EMPTY_PATH   equ 0x1000
FD_CLOEXEC      equ 1

S_IFIFO         equ 0o010000
S_IFCHR         equ 0o020000
S_IFDIR         equ 0o040000
S_IFREG         equ 0o100000
S_IFLNK         equ 0o120000
S_IFSOCK        equ 0o140000

section .text

; -----------------------------------------------------------------------------
;  The tree
; -----------------------------------------------------------------------------

; lx_node_new(RDI = parent or 0, RSI = name, EDX = its length, ECX = LNK_*)
; -> RAX = a node, a child of the parent; 0 if out of memory. Preserves others.
lx_node_new:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    mov r12, rdi
    mov rdi, LN_NODE_SIZE
    call kmalloc
    test rax, rax
    jz .out
    mov rbx, rax
    mov ecx, [rsp + 32]
    mov [rbx + LN_KIND], ecx
    mov dword [rbx + LN_MODE], 0o755
    lock inc qword [lx_inodes]
    mov rax, [lx_inodes]
    mov [rbx + LN_INO], rax
    mov edx, [rsp + 24]
    lea rdi, [rdx + 1]
    call kmalloc
    test rax, rax
    jz .nomem
    mov [rbx + LN_NAME], rax
    mov rdi, rax
    mov rsi, [rsp + 16]
    mov ecx, [rsp + 24]
    rep movsb
    mov byte [rdi], 0
    mov [rbx + LN_PARENT], r12
    test r12, r12
    jz .done
    mov rax, [r12 + LN_CHILD]
    mov [rbx + LN_NEXT], rax
    mov [r12 + LN_CHILD], rbx
.done:
    mov rax, rbx
    jmp .out
.nomem:
    mov rdi, rbx
    call kfree
    xor eax, eax
.out:
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; lx_child(RDI = directory, RSI = a name, EDX = its length) -> RAX = the
; child of that name, or 0. Preserves others.
lx_child:
    push rcx
    push rsi
    push rdi
    push r8
    mov rax, [rdi + LN_CHILD]
.next:
    test rax, rax
    jz .out
    mov r8, [rax + LN_NAME]
    xor ecx, ecx
.char:
    cmp ecx, edx
    je .end
    mov dil, [r8 + rcx]
    cmp dil, [rsi + rcx]
    jne .other
    inc ecx
    jmp .char
.end:
    cmp byte [r8 + rcx], 0
    je .out
.other:
    mov rax, [rax + LN_NEXT]
    jmp .next
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

; lx_make(RSI = an absolute path, NUL-, tab- or newline-ended, ECX = LNK_*)
; -> RAX = its node, made with the directories above it if they were not
; there; 0 if out of memory. A node that was there takes the kind.
lx_make:
    push rbx
    push r12
    push r13
    mov r12d, ecx
    mov rbx, [lx_root]
.part:
    cmp byte [rsi], '/'
    jne .name
    inc rsi
    jmp .part
.name:
    mov al, [rsi]
    cmp al, 0
    je .here
    cmp al, 9
    je .here
    cmp al, 10
    je .here
    xor edx, edx                        ; its length
.len:
    mov al, [rsi + rdx]
    cmp al, '/'
    je .got
    cmp al, 0
    je .got
    cmp al, 9
    je .got
    cmp al, 10
    je .got
    inc edx
    jmp .len
.got:
    lea r13, [rsi + rdx]                ; past it
    mov rdi, rbx
    call lx_child
    test rax, rax
    jnz .down
    mov ecx, LNK_DIR                    ; a directory, unless it is the last
    mov al, [r13]
    cmp al, '/'
    je .make
    mov ecx, r12d
.make:
    mov rdi, rbx
    call lx_node_new
    test rax, rax
    jz .out
.down:
    mov rbx, rax
    mov rsi, r13
    jmp .part
.here:
    mov [rbx + LN_KIND], r12d
    mov rax, rbx
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lx_octal(RSI = text) -> EAX = its octal value, RSI past it. Preserves others.
lx_octal:
    push rcx
    xor eax, eax
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 7
    ja .out
    shl eax, 3
    or eax, ecx
    inc rsi
    jmp .digit
.out:
    pop rcx
    ret

; lx_decimal(RSI = text) -> RAX = its value, RSI past it. Preserves others.
lx_decimal:
    push rcx
    push rdx
    xor eax, eax
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .out
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    jmp .digit
.out:
    pop rdx
    pop rcx
    ret

; lx_tree_load -> CF (said why) if there is no Linux root: the tree, from
; /LINUX/META on the boot stick, once. The main thread's.
lx_tree_load:
    cmp qword [lx_root], 0
    jne .have
    push rbx
    push r12
    push r13
    push r14
    push r15
    call lx_time_init
    lea rsi, [str_lx_slash]
    xor edx, edx
    xor edi, edi
    mov ecx, LNK_DIR
    call lx_node_new
    test rax, rax
    jz .nomem
    mov [lx_root], rax
    mov [rax + LN_PARENT], rax          ; the root is its own parent
    call log_volume
    jc .absent
    mov r12d, LX_META_MAX               ; META, read whole
.read:
    mov rdi, r12
    call vm_alloc
    test rax, rax
    jz .nomem
    mov rbx, rax
    lea rsi, [str_lx_meta]
    mov rdi, rbx
    lea rcx, [r12 - 1]                  ; and a NUL after it
    mov byte [fat_hush], 1
    call fat_read_file
    mov byte [fat_hush], 0
    jc .none
    lea rcx, [r12 - 1]
    cmp rdx, rcx
    jbe .parse
    mov rdi, rbx                        ; larger: room for it all
    call vm_free
    lea r12, [rdx + 4096]
    and r12, -4096
    jmp .read
.parse:
    mov byte [rbx + rax], 0
    mov r13, rbx                        ; R13 = the line
.line:
    mov al, [r13]
    test al, al
    jz .parsed
    cmp byte [r13 + 1], 9
    jne .skip
    lea rsi, [r13 + 2]                  ; the path
    mov ecx, LNK_DIR
    cmp al, 'd'
    je .kind
    mov ecx, LNK_FILE
    cmp al, 'f'
    je .kind
    mov ecx, LNK_LINK
    cmp al, 'l'
    jne .skip
.kind:
    mov r14d, ecx
    call lx_make
    test rax, rax
    jz .nomem_meta
    mov r15, rax                        ; R15 = the node
    lea rsi, [r13 + 2]                  ; past the path
.path_end:
    mov al, [rsi]
    cmp al, 9
    je .field
    cmp al, 10
    je .skip
    test al, al
    jz .skip
    inc rsi
    jmp .path_end
.field:
    inc rsi
    cmp r14d, LNK_LINK
    je .target
    call lx_octal
    mov [r15 + LN_MODE], eax
    cmp r14d, LNK_FILE
    jne .skip
    cmp byte [rsi], 9
    jne .skip
    inc rsi
    call lx_decimal
    mov [r15 + LN_SIZE], rax
    jmp .skip
.target:
    xor edx, edx                        ; to the end of the line
.tlen:
    mov al, [rsi + rdx]
    cmp al, 10
    je .tgot
    cmp al, 13
    je .tgot
    test al, al
    jz .tgot
    inc edx
    jmp .tlen
.tgot:
    mov [r15 + LN_SIZE], rdx
    push rsi
    push rdx
    lea rdi, [rdx + 1]
    call kmalloc
    pop rcx
    pop rsi
    test rax, rax
    jz .nomem_meta
    mov [r15 + LN_TARGET], rax
    mov rdi, rax
    rep movsb
    mov byte [rdi], 0
.skip:
    mov al, [r13]
    test al, al
    jz .parsed
    inc r13
    cmp al, 10
    jne .skip
    jmp .line
.parsed:
    mov rdi, rbx
    call vm_free
    lea r12, [lx_extra]                 ; and the devices, /proc/self
.extra:
    mov rsi, [r12]
    test rsi, rsi
    jz .made
    mov ecx, [r12 + 8]
    call lx_make
    test rax, rax
    jz .nomem
    mov ecx, [r12 + 12]
    mov [rax + LN_DEV], ecx
    mov ecx, [r12 + 16]
    mov [rax + LN_MODE], ecx
    mov rcx, [r12 + 24]
    mov [rax + LN_TARGET], rcx
    test rcx, rcx
    jz .extra_next
    mov rdi, rcx
    push rax
    call strlen
    mov rcx, rax
    pop rax
    mov [rax + LN_SIZE], rcx
.extra_next:
    add r12, 32
    jmp .extra
.made:
    KLOG "linux: a root of %u paths, from /LINUX/META on the boot stick", qword [lx_inodes]
    clc
    jmp .out
.none:
    mov rdi, rbx
    call vm_free
.absent:
    KLOG "linux: no Linux root on the boot stick (/LINUX/META; tools/mkroot.py and mkstick.py --linux make one)"
    jmp .fail
.nomem_meta:
    mov rdi, rbx
    call vm_free
.nomem:
    KLOG "linux: out of memory"
.fail:
    mov qword [lx_root], 0              ; (what was made stays, unused)
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
.have:
    clc
    ret

; -----------------------------------------------------------------------------
;  Paths
; -----------------------------------------------------------------------------

; lx_lookup(RDI = a path, RSI = where a relative one starts, EDX = LKF_*)
; -> RAX = its node, or -errno
lx_lookup:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 2 * LX_PATH
    mov r12, rdi                        ; R12 = what is left of the path
    mov rbx, rsi                        ; RBX = where we are
    mov r13d, edx
    xor r14d, r14d                      ; R14 = links followed
    xor ebp, ebp                        ; RBP = which buffer is free next
    mov rax, -ENOENT
    cmp byte [r12], 0
    je .out
.start:
    cmp byte [r12], '/'
    jne .part
    mov rbx, [lx_root]
.part:
    cmp byte [r12], '/'
    jne .name
    inc r12
    jmp .part
.name:
    mov rax, rbx
    cmp byte [r12], 0
    je .out
    mov rax, -ENOTDIR
    cmp dword [rbx + LN_KIND], LNK_DIR
    jne .out
    xor edx, edx
.len:
    mov al, [r12 + rdx]
    test al, al
    jz .got
    cmp al, '/'
    je .got
    inc edx
    jmp .len
.got:
    mov rax, -ENAMETOOLONG
    cmp edx, LX_NAME
    ja .out
    lea r15, [r12 + rdx]                ; R15 = past the name
    cmp edx, 1
    jne .not_dot
    cmp byte [r12], '.'
    jne .not_dot
    mov r12, r15
    jmp .part
.not_dot:
    cmp edx, 2
    jne .child
    cmp word [r12], '..'
    jne .child
    mov rbx, [rbx + LN_PARENT]
    mov r12, r15
    jmp .part
.child:
    mov rdi, rbx
    mov rsi, r12
    call lx_child
    test rax, rax
    jz .enoent
    mov r12, r15
    mov ecx, [rax + LN_KIND]
    cmp ecx, LNK_LINK
    je .link
    cmp ecx, LNK_MAGIC
    je .link
.step:
    mov rbx, rax
    jmp .part
.link:                                  ; followed, unless it ends the path
    mov rcx, r12
.trail:
    cmp byte [rcx], '/'
    jne .trailed
    inc rcx
    jmp .trail
.trailed:
    cmp byte [rcx], 0
    jne .follow
    cmp rcx, r12                        ; a slash after it: followed
    jne .follow
    test r13d, LKF_NOFOLLOW
    jnz .step
.follow:
    inc r14d
    cmp r14d, LX_LINKS
    mov rcx, -ELOOP
    cmova rax, rcx
    ja .out
    cmp dword [rax + LN_KIND], LNK_MAGIC
    je .magic
    mov rsi, [rax + LN_TARGET]          ; target + what is left, in a buffer
    mov rdi, rbp
    imul rdi, rdi, LX_PATH
    add rdi, rsp
    xor ebp, 1
    mov rdx, rdi                        ; RDX = its start
    lea rcx, [rdi + LX_PATH - 1]        ; RCX = its end
.copy_target:
    lodsb
    test al, al
    jz .copied_target
    cmp rdi, rcx
    jae .toolong
    stosb
    jmp .copy_target
.copied_target:
    mov rsi, r12
    cmp byte [rsi], 0
    je .copied
    cmp rdi, rcx
    jae .toolong
    mov al, '/'
    stosb
.copy_rest:
    lodsb
    test al, al
    jz .copied
    cmp rdi, rcx
    jae .toolong
    stosb
    jmp .copy_rest
.copied:
    mov byte [rdi], 0
    mov r12, rdx
    jmp .start                          ; from the link's directory, or /
.magic:
    push rax
    mov edi, [rax + LN_DEV]
    call lx_magic
    pop rcx
    cmp rax, -4095
    jae .out
    jmp .step
.toolong:
    mov rax, -ENAMETOOLONG
    jmp .out
.enoent:
    mov rax, -ENOENT
.out:
    cmp rax, -4095                       ; a directory, if it must be
    jae .done
    test r13d, LKF_DIR
    jz .done
    cmp dword [rax + LN_KIND], LNK_DIR
    je .done
    mov rax, -ENOTDIR
.done:
    add rsp, 2 * LX_PATH
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; lx_magic(EDI = LND_*) -> RAX = the node a magic link is for this process,
; or -errno
lx_magic:
    mov rax, -ENOENT
    cmp edi, LND_EXE
    jne .out
    call lx_cur_proc
    test rax, rax
    jz .none
    mov rax, [rax + LP_EXE]
    test rax, rax
    jnz .out
.none:
    mov rax, -ENOENT
.out:
    ret

; lx_node_path(RDI = node, RSI = a buffer, EDX = its room) -> RAX = the
; length of its path (written there, NUL-ended), or -ENAMETOOLONG
lx_node_path:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    mov r12, rsi
    mov r13d, edx
    cmp r13d, 2
    jb .long
    lea r14, [r12 + r13 - 1]            ; R14 = where the next name ends
    mov byte [r14], 0
    cmp rbx, [lx_root]
    je .root
.up:
    cmp rbx, [lx_root]
    je .moved
    mov rdi, [rbx + LN_NAME]
    call strlen
    mov rcx, rax
    lea rdx, [rcx + 1]
    mov rax, r14
    sub rax, r12
    cmp rax, rdx
    jb .long
    sub r14, rcx
    mov rdi, r14
    mov rsi, [rbx + LN_NAME]
    rep movsb
    dec r14
    mov byte [r14], '/'
    mov rbx, [rbx + LN_PARENT]
    jmp .up
.root:
    dec r14
    mov byte [r14], '/'
.moved:
    lea rcx, [r12 + r13]                ; down to the start of the buffer
    sub rcx, r14
    mov rsi, r14
    mov rdi, r12
    rep movsb
    lea rax, [r12 + r13 - 1]
    sub rax, r14
    jmp .out
.long:
    mov rax, -ENAMETOOLONG
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_path_at(EDI = a directory's descriptor or AT_FDCWD, RSI = a user path,
; RDX = a buffer of LX_PATH, ECX = LKF_*, R8d = 1 if an empty path means the
; descriptor itself) -> RAX = the node, or -errno
lx_path_at:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12, rdx
    mov r13d, ecx
    mov r14d, r8d
    mov rdi, r12
    mov edx, LX_PATH
    call lx_copy_str
    test rax, rax
    js .out
    jnz .path
    test r14d, r14d
    mov rax, -ENOENT
    jz .out
    mov edi, ebx                        ; the descriptor's own node
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rax, [rax + LF_NODE]
    test rax, rax
    jnz .out
    mov rax, -EINVAL
    jmp .out
.path:
    call lx_cur_proc
    mov rsi, [rax + LP_CWD]
    cmp byte [r12], '/'
    je .look
    cmp ebx, AT_FDCWD
    je .look
    mov edi, ebx
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rsi, [rax + LF_NODE]
    test rsi, rsi
    mov rax, -ENOTDIR
    jz .out
.look:
    mov rdi, r12
    mov edx, r13d
    call lx_lookup
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The file cache
; -----------------------------------------------------------------------------

; lx_file_data(RDI = a file's node) -> RAX = its bytes in the cache, read in
; now if they were not, or -EIO
lx_file_data:
    cmp dword [rdi + LN_STATE], LNS_LOADED
    jne .not_yet
    mov rax, [rdi + LN_DATA]
    ret
.not_yet:
    push rbx
    mov rbx, rdi
    mov rax, [gs:PC_CURRENT]
    cmp rax, [main_thread]
    jne .ask
    call lx_load                        ; the main thread reads it itself
    jmp .result
.ask:
    pushfq
    cli
    lea rdi, [lx_load_lock]
    call spin_lock
    cmp dword [rbx + LN_STATE], LNS_NONE
    jne .queued
    mov dword [rbx + LN_STATE], LNS_QUEUED
    mov rax, [lx_load_list]
    mov [rbx + LN_QNEXT], rax
    mov [lx_load_list], rbx
.queued:
    lea rdi, [lx_load_lock]
    call spin_unlock
    popfq
    mov rdi, [main_thread]
    call thread_unpark
    mov rax, [gs:PC_CURRENT]            ; (a signal does not cut this short:
    or dword [rax + TH_LXFL], LXF_NOSIG ; a fault may be waiting on it)
    lea rdi, [rbx + LN_WQ]
    lea rsi, [rbx + LN_DONE]
    xor edx, edx
    call wq_wait
    mov rax, [gs:PC_CURRENT]
    and dword [rax + TH_LXFL], ~LXF_NOSIG
.result:
    mov rax, -EIO
    cmp dword [rbx + LN_STATE], LNS_LOADED
    jne .out
    mov rax, [rbx + LN_DATA]
.out:
    pop rbx
    ret

; lx_load(RBX = a file's node): its bytes read into the cache. The main
; thread's.
lx_load:
    push r12
    push r14
    cmp dword [rbx + LN_STATE], LNS_LOADED
    jae .said
    mov rdi, [rbx + LN_SIZE]
    add rdi, 4095
    and rdi, -4096
    jnz .sized
    mov edi, 4096
.sized:
    call vm_alloc
    test rax, rax
    jz .failed
    mov r12, rax
    cmp qword [rbx + LN_SIZE], 0
    je .read
    lea rdi, [lx_load_path]             ; /LINUX/ROOT and its path
    lea rsi, [str_lx_rootdir]
    mov ecx, str_lx_rootdir_len
    rep movsb
    push rdi
    mov rdi, rbx
    pop rsi
    mov edx, LX_PATH
    call lx_node_path
    cmp rax, -4095
    jae .free
    call log_volume
    jc .free
    lea rsi, [lx_load_path]
    mov rdi, r12
    mov rcx, [rbx + LN_SIZE]
    call fat_read_file
    jc .free
    cmp rax, [rbx + LN_SIZE]
    jne .short
.read:
    mov [rbx + LN_DATA], r12
    mov dword [rbx + LN_STATE], LNS_LOADED
    lock inc qword [lx_files_read]
    mov rax, [rbx + LN_SIZE]
    add [lx_bytes_read], rax
    jmp .said
.short:
    lea rax, [lx_load_path]
    KLOG "linux: %s is shorter on the stick than META says", rax
.free:
    mov rdi, r12
    call vm_free
.failed:
    mov dword [rbx + LN_STATE], LNS_FAILED
.said:
    mov dword [rbx + LN_DONE], 1
    lea rdi, [rbx + LN_WQ]
    call wq_wake
    pop r14
    pop r12
    ret

; lx_load_service: from the main loop, the files programs wait for
lx_load_service:
    push rbx
.next:
    cmp qword [lx_load_list], 0
    je .out
    pushfq
    cli
    lea rdi, [lx_load_lock]
    call spin_lock
    mov rbx, [lx_load_list]
    test rbx, rbx
    jz .unlock
    mov rax, [rbx + LN_QNEXT]
    mov [lx_load_list], rax
.unlock:
    lea rdi, [lx_load_lock]
    call spin_unlock
    popfq
    test rbx, rbx
    jz .out
    call lx_load
    jmp .next
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Open files and descriptors
; -----------------------------------------------------------------------------

; lf_new(EDI = LFK_*, RSI = node or 0, EDX = flags) -> RAX = an open file
; with one reference, or 0. Preserves others.
lf_new:
    push rdi
    push rsi
    push rdx
    mov edi, LF_SIZE
    call kmalloc
    pop rdx
    pop rsi
    pop rdi
    test rax, rax
    jz .out
    mov dword [rax + LF_REFS], 1
    mov [rax + LF_KIND], edi
    mov [rax + LF_NODE], rsi
    mov [rax + LF_FLAGS], edx
.out:
    ret

; lf_get(RDI) / lf_put(RDI): a reference more, or one less (the last frees
; it). Preserve all.
lf_get:
    lock inc dword [rdi + LF_REFS]
    ret

lf_put:
    lock dec dword [rdi + LF_REFS]
    jnz .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    cmp dword [rdi + LF_KIND], LFK_PIPE
    jne .not_pipe
    call lx_pipe_close
    jmp .free
.not_pipe:
    cmp dword [rdi + LF_KIND], LFK_TTY
    jne .free
    push rdi
    mov rdi, [rdi + LF_TTY]
    call ly_put
    pop rdi
.free:
    call kfree
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

; lx_cur_proc -> RAX = the current task's Linux process, or 0. Preserves others.
lx_cur_proc:
    mov rax, [gs:PC_CURRENT]
    mov rax, [rax + TH_TASK]
    test rax, rax
    jz .out
    mov rax, [rax + TK_LX]
.out:
    ret

; lx_fd_get(EDI = a descriptor) -> RAX = its open file, or -EBADF. Preserves
; others.
lx_fd_get:
    push rcx
    call lx_cur_proc
    test edi, edi
    js .bad
    cmp edi, [rax + LP_NFD]
    jae .bad
    mov rcx, [rax + LP_FDS]
    mov eax, edi
    mov rax, [rcx + rax * 8]
    and rax, -2
    jz .bad
    pop rcx
    ret
.bad:
    mov rax, -EBADF
    pop rcx
    ret

; lx_fd_install(RDI = process, RSI = an open file (the descriptor takes its
; reference), EDX = the least descriptor it may be, ECX = FD_CLOEXEC or 0)
; -> RAX = the descriptor, or -EMFILE (the reference dropped)
lx_fd_install:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    lea rdi, [rbx + LP_FDLOCK]
    call lx_mutex_lock
.look:
    mov eax, edx
.slot:
    cmp eax, [rbx + LP_NFD]
    jae .grow
    mov r8, [rbx + LP_FDS]
    cmp qword [r8 + rax * 8], 0
    je .found
    inc eax
    jmp .slot
.found:
    mov r9, r12
    or r9, rcx
    mov [r8 + rax * 8], r9
    jmp .unlock
.grow:
    mov r9d, [rbx + LP_NFD]             ; twice the room
    cmp r9d, LX_FD_MAX
    jae .full
    push rax
    push rcx
    push rdx
    mov rdi, r9
    shl rdi, 4
    call kmalloc
    pop rdx
    pop rcx
    test rax, rax
    jz .nomem
    mov r8, rax
    mov rdi, rax
    mov rsi, [rbx + LP_FDS]
    mov r9d, [rbx + LP_NFD]
    push rcx
    mov ecx, r9d
    rep movsq
    pop rcx
    mov rdi, [rbx + LP_FDS]
    mov [rbx + LP_FDS], r8
    shl dword [rbx + LP_NFD], 1
    call kfree
    pop rax
    jmp .slot
.nomem:
    pop rax
.full:
    mov rdi, r12
    call lf_put
    mov rax, -EMFILE
.unlock:
    lea rdi, [rbx + LP_FDLOCK]
    call lx_mutex_unlock
    pop r12
    pop rbx
    ret

; lx_fd_take(RDI = process, EDI... ) see lx_sys_close
; lx_fd_close(RDI = process, ESI = descriptor) -> RAX = 0 or -EBADF
lx_fd_close:
    push rbx
    mov rbx, rdi
    lea rdi, [rbx + LP_FDLOCK]
    call lx_mutex_lock
    mov rax, -EBADF
    test esi, esi
    js .unlock
    cmp esi, [rbx + LP_NFD]
    jae .unlock
    mov rcx, [rbx + LP_FDS]
    mov esi, esi
    xor edx, edx
    xchg rdx, [rcx + rsi * 8]
    and rdx, -2
    jz .unlock
    mov rdi, rdx
    call lf_put
    xor eax, eax
.unlock:
    push rax
    lea rdi, [rbx + LP_FDLOCK]
    call lx_mutex_unlock
    pop rax
    pop rbx
    ret

; lx_mutex_lock(RDI = a dword) / lx_mutex_unlock(RDI): taken by one thread
; at a time; others yield meanwhile. Preserve all.
lx_mutex_lock:
    push rax
.try:
    mov eax, 1
    xchg eax, [rdi]
    test eax, eax
    jz .taken
    call yield_all
    jmp .try
.taken:
    pop rax
    ret

lx_mutex_unlock:
    mov dword [rdi], 0
    ret

; lx_fd_node(EDI = a descriptor) -> RAX = the node of the regular file it
; has open for reading, or -errno (for mmap)
lx_fd_node:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rcx, rax
    mov rax, -EACCES
    mov edx, [rcx + LF_FLAGS]
    and edx, O_ACCMODE
    cmp edx, O_WRONLY
    je .out
    mov rax, -ENODEV
    cmp dword [rcx + LF_KIND], LFK_FILE
    jne .out
    mov rax, [rcx + LF_NODE]
.out:
    ret

; -----------------------------------------------------------------------------
;  The calls
; -----------------------------------------------------------------------------

; lf_read(RBX = open file, RSI = user buffer, RDX = bytes, R8 = offset, or
; -1 for its position) -> RAX = bytes read, or -errno
lf_read:
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov r14, r8
    mov eax, [rbx + LF_FLAGS]
    and eax, O_ACCMODE
    cmp eax, O_WRONLY
    mov rax, -EBADF
    je .out
    mov eax, [rbx + LF_KIND]
    cmp eax, LFK_FILE
    je .file
    cmp eax, LFK_DEV
    je .dev
    cmp eax, LFK_TTY
    je .tty
    cmp eax, LFK_PIPE
    je .pipe
    mov rax, -EISDIR
    jmp .out
.pipe:
    mov rax, -ESPIPE
    cmp r14, -1
    jne .out
    mov rsi, r12
    mov rdx, r13
    call lx_pipe_read
    jmp .out
.file:
    mov rcx, r14
    cmp rcx, -1
    jne .at
    mov rcx, [rbx + LF_POS]
.at:
    mov rdi, [rbx + LF_NODE]
    mov rax, [rdi + LN_SIZE]
    sub rax, rcx
    jbe .eof
    cmp r13, rax
    cmova r13, rax
    mov rsi, [rdi + LN_DATA]
    add rsi, rcx
    mov rdi, r12
    mov rdx, r13
    call lx_copy_out
    cmp rax, -4095
    jae .out
    cmp r14, -1
    jne .done
    add [rbx + LF_POS], r13
.done:
    mov rax, r13
    jmp .out
.eof:
    xor eax, eax
    jmp .out
.dev:
    mov rcx, [rbx + LF_NODE]
    mov ecx, [rcx + LN_DEV]
    cmp ecx, LND_ZERO
    je .zero
    cmp ecx, LND_RANDOM
    je .random
    xor eax, eax                        ; /dev/null
    jmp .out
.zero:
    mov rdi, r12
    mov rsi, r13
    call lx_zero_out
    test rax, rax
    jnz .out
    mov rax, r13
    jmp .out
.random:
    mov rdi, r12
    mov rsi, r13
    call lx_random_out
    jmp .out
.tty:
    mov rdi, [rbx + LF_TTY]
    mov rsi, r12
    mov rdx, r13
    mov ecx, [rbx + LF_FLAGS]
    call ly_read
.out:
    pop r14
    pop r13
    pop r12
    ret

; lf_write(RBX = open file, RSI = user buffer, RDX = bytes) -> RAX = bytes
; written, or -errno
lf_write:
    push r12
    push r13
    push r14
    mov r12, rsi
    mov r13, rdx
    mov eax, [rbx + LF_FLAGS]
    and eax, O_ACCMODE
    mov rax, -EBADF
    jz .out
    mov eax, [rbx + LF_KIND]
    cmp eax, LFK_TTY
    je .tty
    cmp eax, LFK_PIPE
    je .pipe
    cmp eax, LFK_DEV
    mov rax, -EBADF
    jne .out
    mov rax, r13                        ; a device takes it all
    jmp .out
.pipe:
    mov rsi, r12
    mov rdx, r13
    call lx_pipe_write
    jmp .out
.tty:
    xor r14d, r14d
    sub rsp, 512
.chunk:
    mov rdx, r13
    sub rdx, r14
    jz .written
    cmp rdx, 512
    jbe .take
    mov edx, 512
.take:
    push rdx
    lea rdi, [rsp + 8]
    lea rsi, [r12 + r14]
    call lx_copy_in
    pop rdx
    cmp rax, -4095
    jae .tty_out
    add r14, rdx
    mov rdi, [rbx + LF_TTY]
    mov rsi, rsp
    call ly_write
    jmp .chunk
.written:
    mov rax, r14
.tty_out:
    add rsp, 512
.out:
    pop r14
    pop r13
    pop r12
    ret

; read(fd, buf, count)
lx_sys_read:
    mov r8, -1
lx_read_at:
    push rbx
    push rsi
    push rdx
    push r8
    call lx_fd_get
    pop r8
    pop rdx
    pop rsi
    cmp rax, -4095
    jae .out
    mov rbx, rax
    call lf_read
.out:
    pop rbx
    ret

; pread64(fd, buf, count, offset)
lx_sys_pread:
    mov rax, -EINVAL
    test rcx, rcx
    js .out
    mov r8, rcx
    jmp lx_read_at
.out:
    ret

; write(fd, buf, count)
lx_sys_write:
    push rbx
    push rsi
    push rdx
    call lx_fd_get
    pop rdx
    pop rsi
    cmp rax, -4095
    jae .out
    mov rbx, rax
    call lf_write
.out:
    pop rbx
    ret

; readv(fd, iov, n) / writev(fd, iov, n)
lx_sys_readv:
    xor ecx, ecx
    jmp lx_vector
lx_sys_writev:
    mov ecx, 1
lx_vector:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12 = the vector
    mov r13d, edx                       ; R13 = entries left
    mov r15d, ecx
    xor r14d, r14d                      ; R14 = bytes so far
    mov rax, -EINVAL
    cmp edx, 1024
    ja .out
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rbx, rax
.entry:
    test r13d, r13d
    jz .done
    sub rsp, 16
    mov rdi, rsp
    mov rsi, r12
    mov edx, 16
    call lx_copy_in
    pop rsi                             ; its base
    pop rdx                             ; its length
    cmp rax, -4095
    jae .fault
    add r12, 16
    dec r13d
    test rdx, rdx
    jz .entry
    push rdx
    test r15d, r15d
    jnz .write
    mov r8, -1
    call lf_read
    jmp .moved
.write:
    call lf_write
.moved:
    pop rdx
    cmp rax, -4095
    jae .fault
    add r14, rax
    cmp rax, rdx
    jb .done                            ; short: no further
    jmp .entry
.fault:
    test r14, r14
    jnz .done
    jmp .out
.done:
    mov rax, r14
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lx_open(RDI = node, ESI = flags) -> RAX = an open file, or -errno
lx_open:
    push rbx
    push r12
    mov rbx, rdi
    mov r12d, esi
    mov eax, [rbx + LN_KIND]
    cmp eax, LNK_DIR
    je .dir
    test r12d, O_DIRECTORY
    mov rax, -ENOTDIR
    jnz .out
    test r12d, O_PATH
    jnz .file_path
    mov eax, [rbx + LN_KIND]
    cmp eax, LNK_DEV
    je .dev
    cmp eax, LNK_FILE
    mov rax, -ENXIO
    jne .out
    mov eax, r12d                       ; read-only, all of it
    and eax, O_ACCMODE
    mov rax, -EROFS
    jnz .out
    test r12d, O_TRUNC
    jnz .out
    mov rdi, rbx
    call lx_file_data
    cmp rax, -4095
    jae .out
.file_path:
    mov edi, LFK_FILE
    jmp .make
.dir:
    mov eax, r12d
    and eax, O_ACCMODE
    mov rax, -EISDIR
    jnz .out
    mov edi, LFK_DIR
    jmp .make
.dev:
    cmp dword [rbx + LN_DEV], LND_TTY
    jne .plain_dev
    call lx_cur_proc
    mov rdi, [rax + LP_TTY]
    mov rax, -ENXIO
    test rdi, rdi
    jz .out
    push rdi
    call ly_get
    mov edi, LFK_TTY
    mov rsi, rbx
    mov edx, r12d
    call lf_new
    pop rdi
    test rax, rax
    jz .tty_nomem
    mov [rax + LF_TTY], rdi
    jmp .out
.tty_nomem:
    call ly_put
    mov rax, -ENOMEM
    jmp .out
.plain_dev:
    mov edi, LFK_DEV
.make:
    mov rsi, rbx
    mov edx, r12d
    call lf_new
    test rax, rax
    jnz .out
    mov rax, -ENOMEM
.out:
    pop r12
    pop rbx
    ret

; open(path, flags, mode)
lx_sys_open:
    mov ecx, edx
    mov edx, esi
    mov rsi, rdi
    mov edi, AT_FDCWD
; openat(dirfd, path, flags, mode)
lx_sys_openat:
    push rbx
    push r12
    sub rsp, LX_PATH
    mov r12d, edx                       ; R12 = flags
    mov rdx, rsp
    xor ecx, ecx
    test r12d, O_NOFOLLOW
    jz .follow
    mov ecx, LKF_NOFOLLOW
.follow:
    xor r8d, r8d
    call lx_path_at
    cmp rax, -4095
    jb .found
    cmp rax, -ENOENT                    ; to be made: not here
    jne .out
    test r12d, O_CREAT
    jz .out
    mov rax, -EROFS
    jmp .out
.found:
    mov rbx, rax
    mov rax, -EEXIST
    test r12d, O_CREAT
    jz .open
    test r12d, O_EXCL
    jnz .out
.open:
    mov rdi, rbx
    mov rax, -ELOOP
    cmp dword [rdi + LN_KIND], LNK_LINK
    je .out
    mov esi, r12d
    call lx_open
    cmp rax, -4095
    jae .out
    mov rsi, rax
    call lx_cur_proc
    mov rdi, rax
    xor edx, edx
    xor ecx, ecx
    test r12d, O_CLOEXEC
    jz .install
    mov ecx, FD_CLOEXEC
.install:
    call lx_fd_install
.out:
    add rsp, LX_PATH
    pop r12
    pop rbx
    ret

; close(fd)
lx_sys_close:
    mov esi, edi
    call lx_cur_proc
    mov rdi, rax
    jmp lx_fd_close

; lseek(fd, offset, whence)
lx_sys_lseek:
    push rbx
    push rsi
    push rdx
    call lx_fd_get
    pop rdx
    pop rsi
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov eax, [rbx + LF_KIND]
    cmp eax, LFK_FILE
    je .file
    cmp eax, LFK_DIR
    je .dir
    cmp eax, LFK_DEV
    je .zero
    mov rax, -ESPIPE
    jmp .out
.dir:
    test rsi, rsi                       ; back to the start, only
    jnz .einval
    test edx, edx
    jnz .einval
    mov qword [rbx + LF_POS], 0
.zero:
    xor eax, eax
    jmp .out
.file:
    mov rcx, [rbx + LF_NODE]
    mov rcx, [rcx + LN_SIZE]
    cmp edx, 0                          ; SEEK_SET
    je .set
    cmp edx, 1                          ; SEEK_CUR
    je .cur
    cmp edx, 2                          ; SEEK_END
    je .end
    cmp edx, 3                          ; SEEK_DATA: data until the end
    je .data
    cmp edx, 4                          ; SEEK_HOLE: the end
    je .hole
.einval:
    mov rax, -EINVAL
    jmp .out
.data:
    cmp rsi, rcx
    jae .enxio
    jmp .set
.hole:
    cmp rsi, rcx
    jae .enxio
    mov rsi, rcx
    jmp .set
.enxio:
    mov rax, -ENXIO
    jmp .out
.cur:
    add rsi, [rbx + LF_POS]
    jmp .set
.end:
    add rsi, rcx
.set:
    test rsi, rsi
    js .einval
    mov [rbx + LF_POS], rsi
    mov rax, rsi
.out:
    pop rbx
    ret

; lx_stat_fill(RDI = node, RSI = a struct stat (144 bytes) to fill)
lx_stat_fill:
    push rbx
    push rdi
    push rsi
    mov rbx, rdi
    mov rdi, rsi
    mov ecx, 144 / 8
    xor eax, eax
    rep stosq
    pop rdi
    mov qword [rdi], LX_DEV             ; st_dev
    mov rax, [rbx + LN_INO]
    mov [rdi + 8], rax
    mov qword [rdi + 16], 1             ; st_nlink
    call lx_mode
    mov [rdi + 24], eax
    mov rax, [rbx + LN_SIZE]
    cmp dword [rbx + LN_KIND], LNK_DIR
    jne .size
    mov eax, 4096
    mov qword [rdi + 16], 2
.size:
    cmp dword [rbx + LN_KIND], LNK_DEV
    jne .sized
    xor eax, eax
    call lx_rdev
    mov [rdi + 40], rcx
    xor eax, eax
.sized:
    mov [rdi + 48], rax
    mov qword [rdi + 56], 4096          ; st_blksize
    add rax, 511
    shr rax, 9
    mov [rdi + 64], rax                 ; st_blocks
    mov rax, [lx_epoch_boot]
    mov [rdi + 72], rax                 ; the times: when Axiom started
    mov [rdi + 88], rax
    mov [rdi + 104], rax
    pop rdi
    pop rbx
    ret

; lx_mode(RBX = node) -> EAX = its st_mode. Preserves others.
lx_mode:
    mov eax, [rbx + LN_MODE]
    and eax, 0o7777
    mov ecx, [rbx + LN_KIND]
    cmp ecx, LNK_DIR
    je .dir
    cmp ecx, LNK_DEV
    je .chr
    cmp ecx, LNK_FILE
    je .reg
    cmp ecx, LNK_FIFO
    je .fifo
    or eax, S_IFLNK | 0o777
    ret
.fifo:
    or eax, S_IFIFO
    ret
.dir:
    or eax, S_IFDIR
    ret
.chr:
    or eax, S_IFCHR
    ret
.reg:
    or eax, S_IFREG
    ret

; lx_rdev(RBX = a device's node) -> RCX = its st_rdev. Preserves others.
lx_rdev:
    mov ecx, [rbx + LN_DEV]
    cmp ecx, LND_NULL
    je .null
    cmp ecx, LND_ZERO
    je .zero
    cmp ecx, LND_TTY
    je .tty
    mov ecx, (1 << 8) | 9               ; urandom
    ret
.null:
    mov ecx, (1 << 8) | 3
    ret
.zero:
    mov ecx, (1 << 8) | 5
    ret
.tty:
    mov ecx, (5 << 8) | 0
    ret

; lx_statx_fill(RDI = node, RSI = a struct statx (256 bytes) to fill)
lx_statx_fill:
    push rbx
    push r12
    sub rsp, 144
    mov rbx, rdi
    mov r12, rsi
    mov rdi, r12
    mov ecx, 256 / 8
    xor eax, eax
    rep stosq
    mov rdi, rbx
    mov rsi, rsp
    call lx_stat_fill                   ; from struct stat's
    mov dword [r12], 0x7FF              ; stx_mask: the basic stats
    mov dword [r12 + 4], 4096           ; stx_blksize
    mov eax, [rsp + 16]
    mov [r12 + 16], eax                 ; stx_nlink
    mov eax, [rsp + 24]
    mov [r12 + 28], ax                  ; stx_mode
    mov rax, [rsp + 8]
    mov [r12 + 32], rax                 ; stx_ino
    mov rax, [rsp + 48]
    mov [r12 + 40], rax                 ; stx_size
    mov rax, [rsp + 64]
    mov [r12 + 48], rax                 ; stx_blocks
    mov rax, [rsp + 72]
    mov [r12 + 64], rax                 ; atime, btime, ctime, mtime
    mov [r12 + 80], rax
    mov [r12 + 96], rax
    mov [r12 + 112], rax
    mov rax, [rsp + 40]
    movzx ecx, ah
    mov [r12 + 128], ecx                ; stx_rdev_major, minor
    movzx ecx, al
    mov [r12 + 132], ecx
    mov dword [r12 + 136], LX_DEV >> 8  ; stx_dev_major, minor
    mov dword [r12 + 140], LX_DEV & 0xFF
    add rsp, 144
    pop r12
    pop rbx
    ret

; lx_stat_out(RAX = node or -errno, RBX = user struct stat) -> RAX = 0 or -errno
lx_stat_out:
    cmp rax, -4095
    jae .out
    sub rsp, 144
    mov rdi, rax
    mov rsi, rsp
    call lx_stat_fill
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 144
    call lx_copy_out
    add rsp, 144
.out:
    ret

; stat(path, buf) / lstat(path, buf)
lx_sys_stat:
    xor ecx, ecx
    jmp lx_stat_path
lx_sys_lstat:
    mov ecx, AT_SYMLINK_NOFOLLOW
lx_stat_path:
    mov rdx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
; newfstatat(dirfd, path, buf, flags)
lx_sys_newfstatat:
    push rbx
    sub rsp, LX_PATH
    mov rbx, rdx
    xor r8d, r8d
    test ecx, AT_EMPTY_PATH
    jz .empty
    mov r8d, 1
.empty:
    xor edx, edx
    test ecx, AT_SYMLINK_NOFOLLOW
    jz .follow
    mov edx, LKF_NOFOLLOW
.follow:
    mov ecx, edx
    mov rdx, rsp
    call lx_path_at
    call lx_stat_out
    add rsp, LX_PATH
    pop rbx
    ret

; fstat(fd, buf)
lx_sys_fstat:
    push rbx
    mov rbx, rsi
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rax, [rax + LF_NODE]
    test rax, rax
    jnz .node
    mov rax, -EBADF
    jmp .out
.node:
    call lx_stat_out
.out:
    pop rbx
    ret

; statx(dirfd, path, flags, mask, buf)
lx_sys_statx:
    push rbx
    sub rsp, LX_PATH
    mov rbx, r8
    xor r8d, r8d
    test edx, AT_EMPTY_PATH
    jz .empty
    mov r8d, 1
.empty:
    xor ecx, ecx
    test edx, AT_SYMLINK_NOFOLLOW
    jz .follow
    mov ecx, LKF_NOFOLLOW
.follow:
    mov rdx, rsp
    call lx_path_at
    cmp rax, -4095
    jae .out
    sub rsp, 256
    mov rdi, rax
    mov rsi, rsp
    call lx_statx_fill
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 256
    call lx_copy_out
    add rsp, 256
.out:
    add rsp, LX_PATH
    pop rbx
    ret

; access(path, mode) / faccessat(dirfd, path, mode, flags)
lx_sys_access:
    mov edx, esi
    mov rsi, rdi
    mov edi, AT_FDCWD
    xor ecx, ecx
lx_sys_faccessat:
    push rbx
    sub rsp, LX_PATH
    mov ebx, edx                        ; the mode: R_OK 4, W_OK 2, X_OK 1
    xor r8d, r8d
    test ecx, AT_EMPTY_PATH
    jz .empty
    mov r8d, 1
.empty:
    xor edx, edx
    test ecx, AT_SYMLINK_NOFOLLOW
    jz .follow
    mov edx, LKF_NOFOLLOW
.follow:
    mov ecx, edx
    mov rdx, rsp
    call lx_path_at
    cmp rax, -4095
    jae .out
    mov rcx, rax
    xor eax, eax
    test ebx, 2
    jz .x
    cmp dword [rcx + LN_KIND], LNK_DEV  ; nothing is writable but devices
    je .x
    mov rax, -EROFS
    jmp .out
.x:
    test ebx, 1
    jz .out
    cmp dword [rcx + LN_KIND], LNK_DIR
    je .out
    test dword [rcx + LN_MODE], 0o111
    jnz .out
    mov rax, -EACCES
.out:
    add rsp, LX_PATH
    pop rbx
    ret

; readlink(path, buf, size) / readlinkat(dirfd, path, buf, size)
lx_sys_readlink:
    mov rcx, rdx
    mov rdx, rsi
    mov rsi, rdi
    mov edi, AT_FDCWD
lx_sys_readlinkat:
    push rbx
    push r12
    sub rsp, LX_PATH
    mov rbx, rdx                        ; RBX = where, R12 = its room
    mov r12, rcx
    mov rax, -EINVAL
    test r12, r12
    jle .out
    mov rdx, rsp
    mov ecx, LKF_NOFOLLOW
    xor r8d, r8d
    call lx_path_at
    cmp rax, -4095
    jae .out
    mov ecx, [rax + LN_KIND]
    cmp ecx, LNK_MAGIC
    je .magic
    cmp ecx, LNK_LINK
    mov rcx, rax
    mov rax, -EINVAL
    jne .out
    mov rsi, [rcx + LN_TARGET]
    mov rdx, [rcx + LN_SIZE]
    jmp .copy
.magic:
    mov edi, [rax + LN_DEV]
    call lx_magic
    cmp rax, -4095
    jae .out
    mov rdi, rax
    mov rsi, rsp
    mov edx, LX_PATH
    call lx_node_path
    cmp rax, -4095
    jae .out
    mov rsi, rsp
    mov rdx, rax
.copy:
    cmp rdx, r12
    cmova rdx, r12
    push rdx
    mov rdi, rbx
    call lx_copy_out
    pop rdx
    cmp rax, -4095
    jae .out
    mov rax, rdx
.out:
    add rsp, LX_PATH
    pop r12
    pop rbx
    ret

; getdents64(fd, buf, count)
lx_sys_getdents64:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    sub rsp, 512                        ; one entry, made here
    mov r12, rsi                        ; R12 = where
    mov r13, rdx                        ; R13 = room
    xor r14d, r14d                      ; R14 = bytes given
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rax, -ENOTDIR
    cmp dword [rbx + LF_KIND], LFK_DIR
    jne .out
.entry:
    mov r15, [rbx + LF_POS]             ; 0 '.', 1 '..', then its children
    mov rbp, [rbx + LF_NODE]
    cmp r15, 2
    jb .dots
    mov rbp, [rbp + LN_CHILD]
    lea rcx, [r15 - 2]
.nth:
    test rbp, rbp
    jz .done
    test rcx, rcx
    jz .this
    mov rbp, [rbp + LN_NEXT]
    dec rcx
    jmp .nth
.dots:
    lea rsi, [str_lx_dot]
    test r15, r15
    jz .named
    mov rbp, [rbp + LN_PARENT]
    lea rsi, [str_lx_dotdot]
    jmp .named
.this:
    mov rsi, [rbp + LN_NAME]
.named:
    mov rdi, rsi
    call strlen
    lea rcx, [rax + 19 + 1 + 7]         ; d_ino, d_off, d_reclen, d_type, the name, NUL
    and rcx, -8
    cmp rcx, r13
    ja .full
    mov rdi, rsp
    push rcx
    push rsi
    xor eax, eax
    mov ecx, 512 / 8
    rep stosq
    pop rsi
    pop rcx
    mov rax, [rbp + LN_INO]
    mov [rsp], rax
    lea rax, [r15 + 1]
    mov [rsp + 8], rax
    mov [rsp + 16], cx
    push rcx
    mov eax, [rbp + LN_KIND]            ; DT_*
    lea rdx, [lx_dtypes]
    mov al, [rdx + rax]
    mov [rsp + 8 + 18], al
    lea rdi, [rsp + 8 + 19]
.name:
    lodsb
    stosb
    test al, al
    jnz .name
    pop rcx
    mov rdi, r12
    mov rsi, rsp
    mov rdx, rcx
    push rcx
    call lx_copy_out
    pop rcx
    cmp rax, -4095
    jae .out
    add r12, rcx
    sub r13, rcx
    add r14, rcx
    inc qword [rbx + LF_POS]
    jmp .entry
.full:
    test r14, r14
    jnz .done
    mov rax, -EINVAL
    jmp .out
.done:
    mov rax, r14
.out:
    add rsp, 512
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; getcwd(buf, size)
lx_sys_getcwd:
    push rbx
    push r12
    sub rsp, LX_PATH
    mov rbx, rdi
    mov r12, rsi
    call lx_cur_proc
    mov rdi, [rax + LP_CWD]
    mov rsi, rsp
    mov edx, LX_PATH
    call lx_node_path
    cmp rax, -4095
    jae .out
    lea rdx, [rax + 1]
    mov rax, -ERANGE
    cmp rdx, r12
    ja .out
    push rdx
    mov rdi, rbx
    mov rsi, rsp
    add rsi, 8
    call lx_copy_out
    pop rdx
    cmp rax, -4095
    jae .out
    mov rax, rdx
.out:
    add rsp, LX_PATH
    pop r12
    pop rbx
    ret

; chdir(path)
lx_sys_chdir:
    push rbx
    sub rsp, LX_PATH
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov rdx, rsp
    mov ecx, LKF_DIR
    xor r8d, r8d
    call lx_path_at
    cmp rax, -4095
    jae .out
    mov rbx, rax
    call lx_cur_proc
    mov [rax + LP_CWD], rbx
    xor eax, eax
.out:
    add rsp, LX_PATH
    pop rbx
    ret

; fchdir(fd)
lx_sys_fchdir:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rcx, [rax + LF_NODE]
    mov rax, -ENOTDIR
    test rcx, rcx
    jz .out
    cmp dword [rcx + LN_KIND], LNK_DIR
    jne .out
    call lx_cur_proc
    mov [rax + LP_CWD], rcx
    xor eax, eax
.out:
    ret

; dup(fd)
lx_sys_dup:
    xor esi, esi
    xor edx, edx
    jmp lx_dup_from

; fcntl(fd, cmd, arg)
lx_sys_fcntl:
    cmp esi, 0                          ; F_DUPFD
    je .dupfd
    cmp esi, 1030                       ; F_DUPFD_CLOEXEC
    je .dupfd_cloexec
    cmp esi, 1                          ; F_GETFD
    je .getfd
    cmp esi, 2                          ; F_SETFD
    je .setfd
    cmp esi, 3                          ; F_GETFL
    je .getfl
    cmp esi, 4                          ; F_SETFL
    je .setfl
    cmp esi, 1032                       ; F_GETPIPE_SZ
    je .pipe_size
    cmp esi, 1031                       ; F_SETPIPE_SZ: as it is
    je .pipe_size
    push rdi                            ; locks and the rest: fine, if open
    call lx_fd_get
    pop rdi
    cmp rax, -4095
    jae .out
    xor eax, eax
.out:
    ret
.pipe_size:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    cmp dword [rax + LF_KIND], LFK_PIPE
    mov rax, -EBADF
    jne .out
    mov eax, PIPE_SIZE
    ret
.dupfd:
    mov esi, edx
    xor edx, edx
    jmp lx_dup_from
.dupfd_cloexec:
    mov esi, edx
    mov edx, FD_CLOEXEC
    jmp lx_dup_from
.getfd:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    call lx_cur_proc
    mov rcx, [rax + LP_FDS]
    mov edi, edi
    mov rax, [rcx + rdi * 8]
    and eax, FD_CLOEXEC
    ret
.setfd:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    call lx_cur_proc
    mov rcx, [rax + LP_FDS]
    mov edi, edi
    and edx, FD_CLOEXEC
    and qword [rcx + rdi * 8], -2
    or [rcx + rdi * 8], rdx
    xor eax, eax
    ret
.getfl:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov eax, [rax + LF_FLAGS]
    and eax, O_ACCMODE | O_APPEND | O_NONBLOCK
    or eax, 0x8000                      ; O_LARGEFILE
    ret
.setfl:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    and edx, O_APPEND | O_NONBLOCK
    mov ecx, [rax + LF_FLAGS]
    and ecx, ~(O_APPEND | O_NONBLOCK)
    or ecx, edx
    mov [rax + LF_FLAGS], ecx
    xor eax, eax
    ret

; lx_dup_from(EDI = fd, ESI = the least new descriptor, EDX = FD_CLOEXEC or 0)
lx_dup_from:
    push rbx
    push r12
    push r13
    mov r12d, esi
    mov r13d, edx
    mov rax, -EINVAL
    test esi, esi
    js .out
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rdi, rbx
    call lf_get
    call lx_cur_proc
    mov rdi, rax
    mov rsi, rbx
    mov edx, r12d
    mov ecx, r13d
    call lx_fd_install
.out:
    pop r13
    pop r12
    pop rbx
    ret

; dup2(old, new) / dup3(old, new, flags)
lx_sys_dup2:
    xor edx, edx
    cmp edi, esi
    jne lx_sys_dup3
    call lx_fd_get                      ; the same: if it is open
    cmp rax, -4095
    jae .out
    mov eax, edi
.out:
    ret
lx_sys_dup3:
    push rbx
    push r12
    push r13
    push r14
    mov rax, -EINVAL
    cmp edi, esi
    je .out
    test edx, ~O_CLOEXEC
    jnz .out
    mov r12d, esi                       ; R12 = the new descriptor
    xor r13d, r13d
    test edx, O_CLOEXEC
    jz .flags
    mov r13d, FD_CLOEXEC
.flags:
    mov rax, -EBADF
    test esi, esi
    js .out
    cmp esi, LX_FD_MAX
    jae .out
    call lx_fd_get
    cmp rax, -4095
    jae .out
    mov rbx, rax
    mov rdi, rbx
    call lf_get
    call lx_cur_proc
    mov r14, rax
.room:
    cmp r12d, [r14 + LP_NFD]            ; the table holds it?
    jb .there
    mov rdi, rbx                        ; (grown by installing past its end,
    call lf_get                         ; which takes a reference)
    mov rdi, r14
    mov rsi, rbx
    mov edx, [r14 + LP_NFD]
    xor ecx, ecx
    call lx_fd_install
    cmp rax, -4095
    jae .drop
    mov rdi, r14
    mov esi, eax
    call lx_fd_close
    jmp .room
.there:
    lea rdi, [r14 + LP_FDLOCK]
    call lx_mutex_lock
    mov rcx, [r14 + LP_FDS]
    mov rax, rbx
    or rax, r13
    mov edx, r12d
    xchg rax, [rcx + rdx * 8]
    lea rdi, [r14 + LP_FDLOCK]
    call lx_mutex_unlock
    and rax, -2
    jz .done
    mov rdi, rax                        ; what was there closes
    call lf_put
.done:
    mov eax, r12d
    jmp .out
.drop:
    mov rdi, rbx
    call lf_put
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ioctl(fd, request, arg): a terminal's (lxtty.asm), and O_NONBLOCK
lx_sys_ioctl:
    call lx_fd_get
    cmp rax, -4095
    jae .out
    cmp esi, 0x5421                     ; FIONBIO
    je .fionbio
    cmp esi, 0x5451                     ; FIOCLEX
    je .cloexec
    cmp esi, 0x5450                     ; FIONCLEX
    je .cloexec
    cmp dword [rax + LF_KIND], LFK_TTY
    jne .not_tty
    mov rdi, [rax + LF_TTY]
    jmp ly_ioctl
.not_tty:
    cmp dword [rax + LF_KIND], LFK_PIPE
    jne .no
    cmp esi, 0x541B                     ; FIONREAD
    jne .no
    mov rdi, rax
    call lx_pipe_count
    mov rdi, rdx
    mov esi, eax
    jmp lx_put32
.no:
    mov rax, -ENOTTY
.out:
    ret
.cloexec:
    call lx_cur_proc                    ; (the descriptor is open: lx_fd_get)
    mov rcx, [rax + LP_FDS]
    mov edi, edi
    and qword [rcx + rdi * 8], -2
    cmp esi, 0x5451
    jne .done
    or qword [rcx + rdi * 8], FD_CLOEXEC
    jmp .done
.fionbio:
    push rax
    sub rsp, 16
    mov rdi, rsp
    mov rsi, rdx
    mov edx, 4
    call lx_copy_in
    mov ecx, [rsp]
    add rsp, 16
    pop rdx
    cmp rax, -4095
    jae .out
    and dword [rdx + LF_FLAGS], ~O_NONBLOCK
    test ecx, ecx
    jz .done
    or dword [rdx + LF_FLAGS], O_NONBLOCK
.done:
    xor eax, eax
    ret

; the extended attributes: none here
lx_sys_xattr:
    mov rax, -EOPNOTSUPP
    ret

; statfs(path, buf) / fstatfs(fd, buf): one read-only filesystem
lx_sys_statfs:
    push rbx
    push rsi
    sub rsp, LX_PATH
    mov rsi, rdi
    mov edi, AT_FDCWD
    mov rdx, rsp
    xor ecx, ecx
    xor r8d, r8d
    call lx_path_at
    add rsp, LX_PATH
    pop rbx
    cmp rax, -4095
    jae .out
    call lx_statfs_out
.out:
    pop rbx
    ret
lx_sys_fstatfs:
    push rbx
    mov rbx, rsi
    call lx_fd_get
    cmp rax, -4095
    jae .out
    call lx_statfs_out
.out:
    pop rbx
    ret

; lx_statfs_out(RBX = user struct statfs) -> RAX = 0 or -EFAULT
lx_statfs_out:
    sub rsp, 120
    mov rdi, rsp
    xor eax, eax
    mov ecx, 120 / 8
    rep stosq
    mov qword [rsp], 0x01021994         ; f_type: TMPFS_MAGIC
    mov qword [rsp + 8], 4096           ; f_bsize
    mov qword [rsp + 64], 255           ; f_namelen
    mov qword [rsp + 72], 4096          ; f_frsize
    mov qword [rsp + 80], 1             ; f_flags: ST_RDONLY
    mov rdi, rbx
    mov rsi, rsp
    mov edx, 120
    call lx_copy_out
    add rsp, 120
    ret

; umask(mask)
lx_sys_umask:
    call lx_cur_proc
    and edi, 0o777
    xchg edi, [rax + LP_UMASK]
    mov eax, edi
    ret

section .rodata
str_lx_slash:   db '/', 0
str_lx_dot:     db '.', 0
str_lx_dotdot:  db '..', 0
str_lx_meta:    db '/LINUX/META', 0
str_lx_rootdir: db '/LINUX/ROOT'
str_lx_rootdir_len equ $ - str_lx_rootdir
str_lxp_null:   db '/dev/null', 0
str_lxp_zero:   db '/dev/zero', 0
str_lxp_random: db '/dev/random', 0
str_lxp_urandom: db '/dev/urandom', 0
str_lxp_tty:    db '/dev/tty', 0
str_lxp_exe:    db '/proc/self/exe', 0
str_lxp_stdin:  db '/dev/stdin', 0
str_lxp_stdout: db '/dev/stdout', 0
str_lxp_stderr: db '/dev/stderr', 0
str_lxt_stdin:  db '/dev/tty', 0
lx_dtypes:      db 0, 4, 8, 10, 2, 10   ; DT_* by LNK_*
align 8
; what the tree has that META does not: path, LNK_*, LND_*, mode, link target
lx_extra:
    dq str_lxp_null
    dd LNK_DEV, LND_NULL, 0o666, 0
    dq 0
    dq str_lxp_zero
    dd LNK_DEV, LND_ZERO, 0o666, 0
    dq 0
    dq str_lxp_random
    dd LNK_DEV, LND_RANDOM, 0o666, 0
    dq 0
    dq str_lxp_urandom
    dd LNK_DEV, LND_RANDOM, 0o666, 0
    dq 0
    dq str_lxp_tty
    dd LNK_DEV, LND_TTY, 0o666, 0
    dq 0
    dq str_lxp_stdin
    dd LNK_LINK, 0, 0o777, 0
    dq str_lxt_stdin
    dq str_lxp_stdout
    dd LNK_LINK, 0, 0o777, 0
    dq str_lxt_stdin
    dq str_lxp_stderr
    dd LNK_LINK, 0, 0o777, 0
    dq str_lxt_stdin
    dq str_lxp_exe
    dd LNK_MAGIC, LND_EXE, 0o777, 0
    dq 0
    dq 0

section .bss
alignb 8
lx_root:        resq 1                  ; the tree, once read
lx_inodes:      resq 1
lx_load_list:   resq 1                  ; files programs wait for, for lx_load_service
lx_load_lock:   resd 1
alignb 8
lx_files_read:  resq 1
lx_bytes_read:  resq 1
lx_load_path:   resb LX_PATH + 16
