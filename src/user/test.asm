; =============================================================================
;  test.asm - ring 3 checks itself: the start block, the ring, system calls
;  (registers kept, refusals), events, threads, timeouts, memory, its own
;  sections. Says "test: all N checks passed" and returns 0, or says which
;  check failed and returns its number. 'user test' runs it.
; =============================================================================

%include "axe.inc"

ADDS            equ 100000              ; each adder's increments
ADDERS          equ 4
THREAD_STACK    equ 16384
CHECKS          equ 15

main:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi                        ; the start block
    lea rsi, [s_args]
    call ax_add
    lea rsi, [rbx + SB_ARGS]
    mov ecx, [rbx + SB_ARGS_LEN]
    call ax_addn
    lea rsi, [s_args_end]
    call ax_add
    call ax_flush

    mov r15d, 1                         ; the start block says what it should
    cmp dword [rbx + SB_RING], 0
    je fail
    cmp dword [rbx + SB_CONSOLE], 0
    je fail
    cmp qword [rbx + SB_TSC_PER_US], 0
    je fail
    mov rax, [rbx + SB_RING_VA]
    mov rcx, USER_MAPS
    cmp rax, rcx
    jb fail
    lea rax, [main]
    cmp rax, USER_IMAGE + AXE_HDR
    jb fail

    mov r15d, 2                         ; an entry through the ring, and back
    call entry_new
    mov byte [rdi + SQ_OP], RO_NOP
    mov qword [rdi + SQ_DATA], 77
    call ax_submit
    mov edi, 1
    mov esi, 1
    call ax_enter
    cmp rax, 1
    jne fail
    call ax_reap
    jc fail
    test rax, rax
    jnz fail
    cmp rcx, 77
    jne fail

    mov r15d, 3                         ; every register but RCX and R11 kept
    call regs_kept
    test eax, eax
    jnz fail

    mov r15d, 4                         ; a call the kernel does not have
    mov eax, 99
    syscall
    cmp rax, E_ARG
    jne fail
    test rdx, rdx
    jnz fail

    mov r15d, 5                         ; handles: the wrong type, none such
    mov edi, [ax_console]
    mov eax, SYS_MAP
    syscall
    cmp rax, E_TYPE
    jne fail
    mov edi, 0x7FFF0001
    mov eax, SYS_MAP
    syscall
    cmp rax, E_BADH
    jne fail

    mov r15d, 6                         ; no thread starts in the kernel
    mov rdi, 0xFFFFFFFF80000000
    mov rsi, rsp
    xor edx, edx
    mov eax, SYS_THREAD_NEW
    syscall
    cmp rax, E_ARG
    jne fail
    lea rdi, [child]                    ; nor with a stack there
    mov rsi, USER_TOP
    mov eax, SYS_THREAD_NEW
    syscall
    cmp rax, E_ARG
    jne fail

    mov r15d, 7                         ; an event signalled, then waited for
    mov eax, SYS_EVENT_NEW
    syscall
    test rax, rax
    js fail
    mov r12d, eax
    call entry_new
    mov byte [rdi + SQ_OP], RO_SIGNAL
    mov byte [rdi + SQ_FLAGS], SQF_LINK
    mov [rdi + SQ_HANDLE], r12d
    mov qword [rdi + SQ_DATA], 1
    call ax_submit
    call entry_new
    mov byte [rdi + SQ_OP], RO_WAIT
    mov [rdi + SQ_HANDLE], r12d
    mov qword [rdi + SQ_DATA], 2
    call ax_submit
    mov edi, 2
    mov esi, 2
    call ax_enter
    cmp rax, 2
    jne fail
    call ax_reap
    jc fail
    test rax, rax
    jnz fail
    call ax_reap
    jc fail
    test rax, rax
    jnz fail

    mov r15d, 8                         ; a thread of its own, joined
    mov edi, THREAD_STACK
    call mem_map
    test rax, rax
    js fail
    lea rsi, [rax + THREAD_STACK]
    lea rdi, [child]
    mov edx, 41
    mov eax, SYS_THREAD_NEW
    syscall
    test rax, rax
    js fail
    mov r12d, eax
    call entry_new
    mov byte [rdi + SQ_OP], RO_JOIN
    mov [rdi + SQ_HANDLE], r12d
    call ax_do
    test rax, rax
    jnz fail
    cmp rdx, 42
    jne fail
    cmp qword [shared], 82
    jne fail

    mov r15d, 9                         ; a timeout, not before its time
    call ax_now
    mov r13, rax
    mov edi, 2000
    call ax_us
    lea r14, [r13 + rax]
    call entry_new
    mov byte [rdi + SQ_OP], RO_TIMEOUT
    mov [rdi + SQ_DEADLINE], r14
    call ax_do
    call ax_now
    cmp rax, r14
    jb fail

    mov r15d, 10                        ; 64 KiB written here, copied by the
    mov edi, 65536                      ; kernel, read back there
    call mem_map
    test rax, rax
    js fail
    mov r13, rax
    mov r12d, edx
    xor ecx, ecx
.fill:
    lea rax, [rcx * 8 + 1]
    mov [r13 + rcx * 8], rax
    inc ecx
    cmp ecx, 65536 / 8
    jb .fill
    mov edi, 65536
    call mem_map
    test rax, rax
    js fail
    mov r14, rax
    call entry_new
    mov byte [rdi + SQ_OP], RO_COPY
    mov [rdi + SQ_HANDLE], r12d
    mov [rdi + SQ_HANDLE2], edx
    mov qword [rdi + SQ_A2], 65536
    call ax_do
    cmp rax, 65536
    jne fail
    xor ecx, ecx
.compare:
    lea rax, [rcx * 8 + 1]
    cmp [r14 + rcx * 8], rax
    jne fail
    inc ecx
    cmp ecx, 65536 / 8
    jb .compare

    mov r15d, 11                        ; threads on several CPUs, one counter
    mov edi, THREAD_STACK * ADDERS
    call mem_map
    test rax, rax
    js fail
    mov r13, rax
    xor ebp, ebp
.adder:
    lea rsi, [rbp + 1]
    imul rsi, rsi, THREAD_STACK
    add rsi, r13
    lea rdi, [adder]
    xor edx, edx
    mov eax, SYS_THREAD_NEW
    syscall
    test rax, rax
    js fail
    lea rcx, [adders]
    mov [rcx + rbp * 4], eax
    inc ebp
    cmp ebp, ADDERS
    jb .adder
    xor ebp, ebp
.join:
    call entry_new
    mov byte [rdi + SQ_OP], RO_JOIN
    lea rcx, [adders]
    mov eax, [rcx + rbp * 4]
    mov [rdi + SQ_HANDLE], eax
    call ax_do
    test rax, rax
    jnz fail
    inc ebp
    cmp ebp, ADDERS
    jb .join
    cmp qword [counter], ADDS * ADDERS
    jne fail

    mov r15d, 12                        ; its sections, as the file has them
    cmp qword [zeroes], 0
    jne fail
    cmp qword [zeroes + 4096], 0
    jne fail
    mov rax, 0x1122334455667788
    cmp [data_value], rax
    jne fail
    mov rax, 0x8877665544332211
    cmp [const_value], rax
    jne fail
    mov qword [zeroes + 4096], 5        ; and they may be written
    mov qword [data_value], 6

    mov r15d, 13                        ; a second ring of its own
    mov edi, 8
    mov eax, SYS_RING_NEW
    syscall
    test rax, rax
    js fail
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js fail
    cmp dword [rax + RA_SQ_ENTRIES], 8
    jne fail
    cmp dword [rax + RA_CQ_ENTRIES], 16
    jne fail

    mov r15d, 14                        ; the console: a bad handle, too much
    call entry_new
    mov byte [rdi + SQ_OP], RO_WRITE
    mov eax, [ax_io]                    ; memory is no console
    mov [rdi + SQ_HANDLE], eax
    mov [rdi + SQ_HANDLE2], eax
    mov qword [rdi + SQ_A1], 4
    call ax_do
    cmp rax, E_TYPE
    jne fail
    call entry_new
    mov byte [rdi + SQ_OP], RO_WRITE
    mov eax, [ax_console]
    mov [rdi + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rdi + SQ_HANDLE2], eax
    mov qword [rdi + SQ_A0], 4000       ; past the end of its page
    mov qword [rdi + SQ_A1], 200
    call ax_do
    cmp rax, E_RANGE
    jne fail

    mov r15d, 15                        ; yields, while others use SIMD too
    call simd_kept
    test eax, eax
    jnz fail

    lea rsi, [s_passed]
    call ax_add
    mov edi, CHECKS
    call ax_addu
    lea rsi, [s_passed_end]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp done

fail:
    lea rsi, [s_check]
    call ax_add
    mov edi, r15d
    call ax_addu
    lea rsi, [s_failed]
    call ax_add
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

; entry_new -> RDI = the entry, zeroed
entry_new:
    lea rdi, [entry]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    lea rdi, [entry]
    ret

; mem_map(EDI = bytes) -> RAX = where, EDX = its handle; RAX < 0 if refused
mem_map:
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .out
    push rax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    pop rdx
.out:
    ret

; regs_kept -> EAX = 0 if a system call kept every register it should, and
; gave RDX back as 0
regs_kept:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, 0x1111111111111111
    mov rbp, 0x2222222222222222
    mov rsi, 0x3333333333333333
    mov rdi, 0x4444444444444444
    mov r8, 0x5555555555555555
    mov r9, 0x6666666666666666
    mov r10, 0x7777777777777777
    mov r12, 0x8888888888888888
    mov r13, 0x9999999999999999
    mov r14, 0xAAAAAAAAAAAAAAAA
    mov r15, 0xBBBBBBBBBBBBBBBB
    mov rdx, 0xCCCCCCCCCCCCCCCC
    mov eax, SYS_YIELD
    syscall
    test rax, rax
    jnz .bad
    test rdx, rdx
    jnz .bad
    mov rax, 0x1111111111111111
    cmp rbx, rax
    jne .bad
    mov rax, 0x2222222222222222
    cmp rbp, rax
    jne .bad
    mov rax, 0x3333333333333333
    cmp rsi, rax
    jne .bad
    mov rax, 0x4444444444444444
    cmp rdi, rax
    jne .bad
    mov rax, 0x5555555555555555
    cmp r8, rax
    jne .bad
    mov rax, 0x6666666666666666
    cmp r9, rax
    jne .bad
    mov rax, 0x7777777777777777
    cmp r10, rax
    jne .bad
    mov rax, 0x8888888888888888
    cmp r12, rax
    jne .bad
    mov rax, 0x9999999999999999
    cmp r13, rax
    jne .bad
    mov rax, 0xAAAAAAAAAAAAAAAA
    cmp r14, rax
    jne .bad
    mov rax, 0xBBBBBBBBBBBBBBBB
    cmp r15, rax
    jne .bad
    xor eax, eax
    jmp .out
.bad:
    mov eax, 1
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; simd_kept -> EAX = 0 if XMM registers held across many yields
simd_kept:
    mov rax, 0x0123456789ABCDEF
    movq xmm0, rax
    punpcklqdq xmm0, xmm0               ; both halves
    mov rax, 0x0F1E2D3C4B5A6978
    movq xmm7, rax
    movq xmm15, rax
    mov ecx, 200
.yield:
    push rcx
    mov eax, SYS_YIELD
    syscall
    pop rcx
    dec ecx
    jnz .yield
    mov rdx, 0x0123456789ABCDEF
    movq rax, xmm0
    cmp rax, rdx
    jne .bad
    pshufd xmm1, xmm0, 0xEE             ; the upper half
    movq rax, xmm1
    cmp rax, rdx
    jne .bad
    mov rdx, 0x0F1E2D3C4B5A6978
    movq rax, xmm7
    cmp rax, rdx
    jne .bad
    movq rax, xmm15
    cmp rax, rdx
    jne .bad
    xor eax, eax
    ret
.bad:
    mov eax, 1
    ret

; child(RDI = n): shared = 2n, and it returns n + 1
child:
    lea rax, [rdi + rdi]
    mov [shared], rax
    lea rdi, [rdi + 1]
    mov eax, SYS_EXIT
    syscall

adder:
    mov ecx, ADDS
.add:
    lock inc qword [counter]
    dec ecx
    jnz .add
    xor edi, edi
    mov eax, SYS_EXIT
    syscall

section .rodata
const_value:    dq 0x8877665544332211
s_args:         db "test: arguments '", 0
s_args_end:     db "'", 0
s_passed:       db 'test: all ', 0
s_passed_end:   db ' checks passed', 0
s_check:        db 'test: check ', 0
s_failed:       db ' failed', 0

section .data
align 8
data_value:     dq 0x1122334455667788

section .bss
alignb 8
shared:         resq 1
counter:        resq 1
adders:         resd ADDERS
entry:          resb SQ_SIZE
alignb 4096
zeroes:         resb 8192

AXE_END
