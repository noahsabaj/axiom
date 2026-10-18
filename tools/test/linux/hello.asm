; hello: a Linux program of our own, a static ELF file with no library under
; it, for the first steps of Axiom's Linux system calls. It says hello, grows
; its break, touches pages of an anonymous mapping (demand paging), reads
; /etc/hostname, and exits with 7.
;   nasm -f bin -o hello hello.asm         (tools/mkroot.py does it)
BITS 64
org 0x400000

ehdr:
    db 0x7F, "ELF", 2, 1, 1, 0
    times 8 db 0
    dw 2                                ; ET_EXEC
    dw 62                               ; x86-64
    dd 1
    dq start
    dq phdr - ehdr
    dq 0
    dd 0
    dw 64, 56, 1, 0, 0, 0
phdr:
    dd 1, 7                             ; PT_LOAD, RWX
    dq 0, ehdr, ehdr
    dq file_end - ehdr, mem_end - ehdr
    dq 0x1000

%macro SAY 2                            ; text, length
    mov eax, 1
    mov edi, 1
    lea rsi, [%1]
    mov edx, %2
    syscall
%endmacro

start:
    SAY msg_hello, msg_hello_len
    mov eax, 12                         ; brk(0), then 64 KiB more
    xor edi, edi
    syscall
    mov rbx, rax
    lea rdi, [rax + 65536]
    mov eax, 12
    syscall
    lea rcx, [rbx + 65536]
    cmp rax, rcx
    jne fail
    mov byte [rbx + 65535], 1           ; the last byte of it
    mov eax, 9                          ; mmap(0, 1 MiB, RW, PRIVATE|ANON)
    xor edi, edi
    mov esi, 1 << 20
    mov edx, 3
    mov r10d, 0x22
    mov r8, -1
    xor r9d, r9d
    syscall
    cmp rax, -4096
    ja fail
    mov rbx, rax
    xor ecx, ecx
.touch:                                 ; each page, first written here
    mov [rbx + rcx], ecx
    add ecx, 4096
    cmp ecx, 1 << 20
    jb .touch
    mov eax, [rbx + 4096 * 200]
    cmp eax, 4096 * 200
    jne fail
    SAY msg_mem, msg_mem_len
    mov eax, 2                          ; open("/etc/hostname", O_RDONLY)
    lea rdi, [path]
    xor esi, esi
    syscall
    test eax, eax
    js fail
    mov edi, eax
    xor eax, eax                        ; read(fd, buf, 64)
    lea rsi, [buf]
    mov edx, 64
    syscall
    test eax, eax
    jle fail
    mov r12d, eax
    SAY msg_host, msg_host_len
    mov eax, 1
    mov edi, 1
    lea rsi, [buf]
    mov edx, r12d
    syscall
    mov eax, 231                        ; exit_group(7)
    mov edi, 7
    syscall
fail:
    SAY msg_fail, msg_fail_len
    mov eax, 231
    mov edi, 1
    syscall

msg_hello:  db "hello: a Linux program on Axiom", 10
msg_hello_len equ $ - msg_hello
msg_mem:    db "hello: brk and mmap work", 10
msg_mem_len equ $ - msg_mem
msg_host:   db "hello: /etc/hostname says "
msg_host_len equ $ - msg_host
msg_fail:   db "hello: FAILED", 10
msg_fail_len equ $ - msg_fail
path:       db "/etc/hostname", 0
file_end:
buf:        resb 64
mem_end:
