; =============================================================================
;  fstest.asm - files through a capability (ax_files): what a program run
;  with them can do, and what it cannot
;
;    fstest        checks on vol0, which 'vol 0 rw' made writable: a folder
;                  made, a file written, read back (all of it, and as much as
;                  fits), listed, renamed, removed; a folder renamed, a
;                  file moved and back, a folder not into itself; paths
;                  with . or .. or //
;                  refused; a handle to one folder (RO_FS_SUB) that reaches
;                  nothing outside it, and keeps no more rights than it was
;                  given; with +desk, the desktop's look mapped and read.
;                  Says "fstest: all N checks passed" and returns 0, or which
;                  check failed
;    fstest ro     checks on vol0 while it is read-only: writes refused
;                  (E_READONLY), reads allowed
;    (fstest given: what fstest starts, given a folder: it finds it as its
;    files, and reads what is in it)
; =============================================================================

%include "axe.inc"
WANTS AW_FILES

CHECKS          equ 27
CHECKS_RO       equ 6
IO_PATH         equ 0                   ; the page: a path's field
IO_PATH2        equ FS_PATH             ; a second one
IO_DATA         equ 2 * FS_PATH         ; what is read, listed, written
IO_ROOM         equ 4096 - IO_DATA

%macro ENTRY 1                          ; RO_*: an entry on the stack, for EDI's files
    sub rsp, SQ_SIZE + 8
    push rdi
    push rcx
    lea rdi, [rsp + 16]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    pop rdi
    mov byte [rsp + SQ_OP], %1
    mov [rsp + SQ_HANDLE], edi
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
%endmacro

%macro GO 0                             ; submitted, waited for: RAX = its result
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
%endmacro

main:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    xor r14d, r14d                      ; R14: the last result, said if it fails
    mov r15d, 1                         ; R15: the check
    mov r12d, [ax_files]                ; R12: every volume
    test r12d, r12d
    jz fail
    cmp byte [rdi + SB_ARGS], 'r'
    je m_ro
    cmp byte [rdi + SB_ARGS], 'g'
    je m_given

    mov r15d, 2                         ; vol0: there, the boot stick, writable
    mov edi, r12d
    call volumes
    test rax, rax
    jle fail
    mov rsi, [ax_io_va]
    cmp dword [rsi + IO_DATA + FV_INDEX], 0
    jne fail
    mov eax, [rsi + IO_DATA + FV_FLAGS]
    and eax, FVF_WRITABLE | FVF_REMOVABLE | FVF_BOOT
    cmp eax, FVF_WRITABLE | FVF_REMOVABLE | FVF_BOOT
    jne fail

    mov r15d, 3                         ; a clean slate: what an earlier run left
    mov edi, r12d
    lea rsi, [p_hello]
    call remove
    mov edi, r12d
    lea rsi, [p_bye]
    call remove
    mov edi, r12d
    lea rsi, [p_dir]
    call remove
    mov edi, r12d
    lea rsi, [p_dir]
    call list
    cmp rax, E_NOFILE
    jne fail

    mov r15d, 4                         ; a folder made
    mov edi, r12d
    lea rsi, [p_dir]
    call mkdir
    test rax, rax
    jnz fail
    mov r15d, 5                         ; not twice
    mov edi, r12d
    lea rsi, [p_dir]
    call mkdir
    cmp rax, E_EXISTS
    jne fail

    mov r15d, 6                         ; a file written
    mov edi, r12d
    lea rsi, [p_hello]
    lea rdx, [s_hello]
    call write
    test rax, rax
    jnz fail
    mov r15d, 7                         ; read back
    mov edi, r12d
    lea rsi, [p_hello]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    lea rsi, [s_hello]
    mov ecx, HELLO_LEN
    call data_is
    jne fail
    mov r15d, 8                         ; as much as fits, and its size
    mov edi, r12d
    lea rsi, [p_hello]
    mov edx, 5
    call read
    cmp rax, HELLO_LEN
    jne fail
    lea rsi, [s_hello]
    mov ecx, 5
    call data_is
    jne fail
    mov rsi, [ax_io_va]
    cmp byte [rsi + IO_DATA + 5], 0     ; and no more
    jne fail

    mov r15d, 9                         ; the folder listed: the file
    mov edi, r12d
    lea rsi, [p_dir]
    call list
    cmp rax, 1
    jne fail
    mov rbx, [ax_io_va]
    add rbx, IO_DATA
    lea rsi, [s_hello_name]
    call entry_is
    jne fail
    cmp qword [rbx + FE_SIZE], HELLO_LEN
    jne fail
    test dword [rbx + FE_ATTR], FEA_DIR
    jnz fail
    mov eax, [rbx + FE_LEN]
    test eax, 7
    jnz fail
    cmp eax, FE_NAME + 10
    jb fail
    mov r15d, 10                        ; the root listed: the folder in it
    mov edi, r12d
    lea rsi, [p_root]
    call list
    test rax, rax
    jle fail
    mov ebp, eax
    mov rbx, [ax_io_va]
    add rbx, IO_DATA
.find:
    lea rsi, [s_dir_name]
    call entry_is
    je .found
    mov eax, [rbx + FE_LEN]
    test eax, eax
    jz fail
    add rbx, rax
    dec ebp
    jnz .find
    jmp fail
.found:
    test dword [rbx + FE_ATTR], FEA_DIR
    jz fail

    mov r15d, 11                        ; renamed
    mov edi, r12d
    lea rsi, [p_hello]
    lea rdx, [p_bye]
    call rename
    test rax, rax
    jnz fail
    mov r15d, 12                        ; the old name gone, the new one there
    mov edi, r12d
    lea rsi, [p_hello]
    mov edx, IO_ROOM
    call read
    cmp rax, E_NOFILE
    jne fail
    mov edi, r12d
    lea rsi, [p_bye]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail

    mov r15d, 13                        ; paths it does not take
    lea rbx, [bad_paths]
.bad:
    mov rsi, [rbx]
    test rsi, rsi
    jz .bad_done
    mov edi, r12d
    mov edx, IO_ROOM
    call read
    cmp rax, [rbx + 8]
    jne fail
    add rbx, 16
    jmp .bad
.bad_done:

    mov r15d, 14                        ; a handle to the folder, to read
    mov edi, r12d
    lea rsi, [p_dir]
    mov edx, RT_FS_READ
    call sub
    test rax, rax
    js fail
    mov r13d, eax                       ; R13: the folder
    mov r15d, 15                        ; it reaches what is in the folder
    mov edi, r13d
    lea rsi, [p_none]
    call list
    cmp rax, 1
    jne fail
    mov edi, r13d
    lea rsi, [p_bye_in]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    mov edi, r13d
    lea rsi, [p_bye_slash]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    mov r15d, 16                        ; not to write; one volume
    mov edi, r13d
    lea rsi, [p_x_in]
    lea rdx, [s_hello]
    call write
    cmp rax, E_RIGHTS
    jne fail
    mov edi, r13d
    call volumes
    cmp rax, 1
    jne fail
    mov r15d, 17                        ; nothing outside it
    mov edi, r13d
    lea rsi, [p_up]
    mov edx, IO_ROOM
    call read
    cmp rax, E_ARG
    jne fail
    mov edi, r13d
    lea rsi, [p_bye]                    ; (a name in the folder, there)
    mov edx, IO_ROOM
    call read
    cmp rax, E_NOFILE
    jne fail
    mov r15d, 18                        ; a file is not a folder
    mov edi, r12d
    lea rsi, [p_bye]
    mov edx, RT_FS_READ
    call sub
    cmp rax, E_ARG
    jne fail
    mov r15d, 19                        ; from the folder's: no more rights
    mov edi, r13d
    lea rsi, [p_none]
    mov edx, RT_FS_READ | RT_FS_WRITE
    call sub
    test rax, rax
    js fail
    mov edi, eax
    lea rsi, [p_x_in]
    lea rdx, [s_hello]
    call write
    cmp rax, E_RIGHTS
    jne fail
    mov r15d, 20                        ; from every volume's: to write too
    mov edi, r12d
    lea rsi, [p_dir]
    mov edx, RT_FS_READ | RT_FS_WRITE
    call sub
    test rax, rax
    js fail
    mov ebp, eax
    mov edi, ebp
    lea rsi, [p_x_in]
    lea rdx, [s_hello]
    call write
    test rax, rax
    jnz fail
    mov edi, ebp
    lea rsi, [p_x_in]
    call remove
    test rax, rax
    jnz fail

    mov r15d, 21                        ; a child given the folder: its files
    mov edi, r12d
    lea rsi, [p_dir]
    mov edx, RT_FS_READ
    call sub
    test rax, rax
    js fail
    mov edi, eax
    xor edx, edx
    lea rsi, [s_given]
    call ax_spawn2
    test rax, rax
    js fail
    sub rsp, SQ_SIZE + 8                ; its first thread, waited for
    lea rdi, [rsp]
    mov ecx, SQ_SIZE / 8
    push rdx
    xor eax, eax
    rep stosq
    pop rdx
    mov byte [rsp + SQ_OP], RO_JOIN
    mov [rsp + SQ_HANDLE], edx
    GO
    test rax, rax
    js fail
    mov rax, rdx                        ; what it returned
    test rax, rax
    jnz fail

    mov r15d, 22                        ; a folder renamed, what it holds with it
    mov edi, r12d
    lea rsi, [p_dir]
    lea rdx, [p_dir2]
    call rename
    test rax, rax
    jnz fail
    mov edi, r12d
    lea rsi, [p_bye2]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    mov edi, r12d
    lea rsi, [p_dir2]
    lea rdx, [p_dir]
    call rename
    test rax, rax
    jnz fail
    mov r15d, 23                        ; a file moved to another folder, and back
    mov edi, r12d
    lea rsi, [p_bye]
    lea rdx, [p_bye_top]
    call rename
    test rax, rax
    jnz fail
    mov edi, r12d
    lea rsi, [p_bye_top]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    mov edi, r12d
    lea rsi, [p_bye_top]
    lea rdx, [p_bye]
    call rename
    test rax, rax
    jnz fail
    mov r15d, 24                        ; not into itself, nor onto a name taken
    mov edi, r12d
    lea rsi, [p_dir]
    lea rdx, [p_dir_in]
    call rename
    cmp rax, E_ARG
    jne fail
    mov edi, r12d
    lea rsi, [p_bye]
    lea rdx, [p_dir]
    call rename
    cmp rax, E_EXISTS
    jne fail

    mov r15d, 25                        ; a folder with things in it stays
    mov edi, r12d
    lea rsi, [p_dir]
    call remove
    test rax, rax
    jns fail
    mov edi, r12d
    lea rsi, [p_bye]
    call remove
    test rax, rax
    jnz fail
    mov edi, r12d
    lea rsi, [p_dir]
    call remove
    test rax, rax
    jnz fail
    mov r15d, 26                        ; gone
    mov edi, r12d
    lea rsi, [p_dir]
    call list
    cmp rax, E_NOFILE
    jne fail

    mov r15d, 27                        ; the desktop's look, if it was given
    mov edi, [ax_desk]
    test edi, edi
    jz .looked
    call look
    jne fail
.looked:
    mov edi, CHECKS
    jmp passed

; fstest ro: on vol0 while it is read-only
m_ro:
    mov r15d, 2                         ; vol0: there, not writable
    mov edi, r12d
    call volumes
    test rax, rax
    jle fail
    mov rsi, [ax_io_va]
    test dword [rsi + IO_DATA + FV_FLAGS], FVF_WRITABLE
    jnz fail
    mov r15d, 3                         ; not written
    mov edi, r12d
    lea rsi, [p_ro]
    lea rdx, [s_hello]
    call write
    cmp rax, E_READONLY
    jne fail
    mov r15d, 4                         ; nothing made
    mov edi, r12d
    lea rsi, [p_dir]
    call mkdir
    cmp rax, E_READONLY
    jne fail
    mov r15d, 5                         ; but read
    mov edi, r12d
    lea rsi, [p_root]
    call list
    test rax, rax
    jle fail
    mov r15d, 6                         ; a folder's handle, to write: still not
    mov edi, r12d
    lea rsi, [p_root]
    mov edx, RT_FS_READ | RT_FS_WRITE
    call sub
    test rax, rax
    js fail
    mov edi, eax
    lea rsi, [p_ro_in]
    lea rdx, [s_hello]
    call write
    cmp rax, E_READONLY
    jne fail
    mov edi, CHECKS_RO
    jmp passed

; fstest given: started by fstest, given its folder
m_given:
    mov r15d, 2                         ; what it was given is its files
    cmp r12d, [ax_gift]
    jne fail
    mov r15d, 3                         ; the folder: one thing in it
    mov edi, r12d
    lea rsi, [p_none]
    call list
    cmp rax, 1
    jne fail
    mov r15d, 4                         ; read
    mov edi, r12d
    lea rsi, [p_bye_in]
    mov edx, IO_ROOM
    call read
    cmp rax, HELLO_LEN
    jne fail
    xor eax, eax
    jmp done

passed:
    push rdi
    lea rsi, [s_passed]
    call ax_add
    pop rdi
    call ax_addu
    lea rsi, [s_passed_end]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp done
fail:
    mov r14, rax
    lea rsi, [s_check]
    call ax_add
    mov edi, r15d
    call ax_addu
    lea rsi, [s_failed]
    call ax_add
    mov rdi, r14
    call ax_addd
    call ax_flush
    mov eax, r15d
done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Files, through the ring
; -----------------------------------------------------------------------------

; path_at(RSI = a NUL-ended path, ECX = IO_PATH or IO_PATH2): into the
; page's field there, zeroes after. Preserves RDI, RDX.
path_at:
    push rdi
    mov rdi, [ax_io_va]
    add rdi, rcx
    push rdi
    push rcx
    xor eax, eax
    mov ecx, FS_PATH / 8
    rep stosq
    pop rcx
    pop rdi
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    pop rdi
    ret


; volumes(EDI = files) -> RAX = how many, FV_* records at IO_DATA
volumes:
    call clear
    ENTRY RO_FS_VOLUMES
    mov qword [rsp + SQ_A0], IO_DATA
    mov qword [rsp + SQ_A1], IO_ROOM
    GO
    ret

; list(EDI = files, RSI = a folder) -> RAX = how many, FE_* records at IO_DATA
list:
    call clear
    mov ecx, IO_PATH
    call path_at
    ENTRY RO_FS_LIST
    mov qword [rsp + SQ_A0], IO_PATH
    mov qword [rsp + SQ_A1], IO_DATA
    mov qword [rsp + SQ_A2], IO_ROOM
    GO
    ret

; read(EDI = files, RSI = a file, EDX = room) -> RAX = its size, as much as
; fits at IO_DATA
read:
    call clear
    mov ecx, IO_PATH
    call path_at
    ENTRY RO_FS_READ
    mov qword [rsp + SQ_A0], IO_PATH
    mov qword [rsp + SQ_A1], IO_DATA
    mov [rsp + SQ_A2], rdx
    GO
    ret

; write(EDI = files, RSI = a file, RDX = NUL-ended text) -> RAX
write:
    mov ecx, IO_PATH
    call path_at
    push rdi
    mov rsi, rdx
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    xor edx, edx
.copy:
    lodsb
    test al, al
    jz .copied
    stosb
    inc edx
    jmp .copy
.copied:
    pop rdi
    ENTRY RO_FS_WRITE
    mov qword [rsp + SQ_A0], IO_PATH
    mov qword [rsp + SQ_A1], IO_DATA
    mov [rsp + SQ_A2], rdx
    GO
    ret

; mkdir, remove(EDI = files, RSI = a path) -> RAX
mkdir:
    mov ecx, IO_PATH
    call path_at
    ENTRY RO_FS_MKDIR
    mov qword [rsp + SQ_A0], IO_PATH
    GO
    ret
remove:
    mov ecx, IO_PATH
    call path_at
    ENTRY RO_FS_REMOVE
    mov qword [rsp + SQ_A0], IO_PATH
    GO
    ret

; rename(EDI = files, RSI = a file, RDX = its new path) -> RAX
rename:
    mov ecx, IO_PATH
    call path_at
    mov rsi, rdx
    mov ecx, IO_PATH2
    call path_at
    ENTRY RO_FS_RENAME
    mov qword [rsp + SQ_A0], IO_PATH
    mov qword [rsp + SQ_A1], IO_PATH2
    GO
    ret

; sub(EDI = files, RSI = a folder, EDX = rights) -> RAX = a handle to it
sub:
    mov ecx, IO_PATH
    call path_at
    ENTRY RO_FS_SUB
    mov qword [rsp + SQ_A0], IO_PATH
    mov [rsp + SQ_A1], rdx
    GO
    ret

; clear: the page's data zeroed. Preserves RDI, RSI, RDX.
clear:
    push rdi
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    xor eax, eax
    mov ecx, IO_ROOM / 8
    rep stosq
    pop rdi
    ret

; data_is(RSI = bytes, ECX = how many) -> ZF if IO_DATA begins with them
data_is:
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    repe cmpsb
    ret

; entry_is(RBX = an FE_* record, RSI = a name) -> ZF if it has that name,
; case aside
entry_is:
    lea rdi, [rbx + FE_NAME]
.char:
    mov al, [rsi]
    mov ah, [rdi]
    or al, 0x20
    or ah, 0x20
    cmp al, ah
    jne .out
    cmp byte [rsi], 0
    je .out
    inc rsi
    inc rdi
    jmp .char
.out:
    ret

; look(EDI = the desktop) -> ZF if its look maps, and says sensible things
look:
    sub rsp, SQ_SIZE + 8
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_DESK_LOOK
    mov [rsp + SQ_HANDLE], edi
    GO
    test rax, rax
    js .no
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .no
    mov r14, rax
    cmp dword [rax + LK_SERIAL], 1
    jb .no
    mov ecx, [rax + LK_S4]
    cmp ecx, 4
    jb .no
    cmp ecx, 8
    ja .no
    cmp dword [rax + LK_UF], LK_HEAD
    jne .no
    cmp dword [rax + LK_SCR_W], 0
    je .no
    cmp eax, eax
    ret
.no:
    test rsp, rsp                       ; ZF clear
    ret

section .rodata
p_root:         db 'vol0:/', 0
p_dir:          db 'vol0:/fstest', 0
p_hello:        db 'vol0:/fstest/hello.txt', 0
p_bye:          db 'vol0:/fstest/bye.txt', 0
p_dir2:         db 'vol0:/fstest2', 0
p_bye2:         db 'vol0:/fstest2/bye.txt', 0
p_bye_top:      db 'vol0:/fsbye.txt', 0
p_dir_in:       db 'vol0:/fstest/inner', 0
p_ro:           db 'vol0:/fstest.txt', 0
p_ro_in:        db 'fstest.txt', 0
p_none:         db '', 0
p_bye_in:       db 'bye.txt', 0
p_bye_slash:    db '/bye.txt', 0
p_x_in:         db 'x.txt', 0
p_up:           db '../bye.txt', 0
p_dots:         db 'vol0:/fstest/../fstest/bye.txt', 0
p_dot:          db 'vol0:/fstest/./bye.txt', 0
p_double:       db 'vol0:/fstest//bye.txt', 0
p_back:         db 'vol0:/fstest\bye.txt', 0
p_novol:        db 'vol9:/bye.txt', 0
p_novol2:       db 'fstest/bye.txt', 0
p_nocolon:      db 'vol0/fstest/bye.txt', 0
s_hello:        db 'hello, files'
HELLO_LEN       equ $ - s_hello
                db 0
s_hello_name:   db 'hello.txt', 0
s_given:        db 'fstest given', 0
s_dir_name:     db 'fstest', 0
s_passed:       db 'fstest: all ', 0
s_passed_end:   db ' checks passed', 0
s_check:        db 'fstest: check ', 0
s_failed:       db ' failed: ', 0
align 8
bad_paths:      dq p_dots, E_ARG, p_dot, E_ARG, p_double, E_ARG, p_back, E_ARG
                dq p_novol, E_NOFILE, p_novol2, E_NOFILE, p_nocolon, E_NOFILE, 0, 0

AXE_END
