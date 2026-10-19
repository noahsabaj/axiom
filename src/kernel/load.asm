; =============================================================================
;  load.asm - the load average, as Unix's uptime gives it and fleet's info
;  reports it (os.getloadavg()[0]): every 5 s, the threads that want a CPU,
;  folded into an exponential average over a minute as Linux folds them
;  (fixed point, 11 bits; 1884 / 2048 = e^(-5 s / 1 min)).
;
;  The threads that want a CPU: those running, as each CPU's busy time over
;  the 5 s (so 'main', which samples, counts only for the time it ran), and
;  those waiting on the run queues as the sample is taken, but for the one
;  'main' took its CPU from to take it.
; =============================================================================

LOAD_SHIFT      equ 11
LOAD_ONE        equ 1 << LOAD_SHIFT
LOAD_EXP        equ 1884                ; e^(-5 s / 1 min), fixed point
LOAD_STEP_S     equ 5
LOAD_STEPS_MAX  equ 60                  ; 5 minutes unsampled: the past forgotten

section .text

; load_service: from the main loop. A sample every 5 s; a longer gap (a
; command that kept 'main') folds in as many as it spans, at its average.
load_service:
    RDTSC64
    cmp rax, [load_next]
    jb .out
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15, rax                        ; now
    mov r9, [tsc_per_ms]
    imul r9, r9, LOAD_STEP_S * 1000     ; a step, in TSC
    lea rax, [r15 + r9]
    mov [load_next], rax
    mov r10, r15                        ; the time sampled
    sub r10, [load_at]
    xor r13d, r13d                      ; busy, all CPUs, in TSC
    xor r14d, r14d                      ; threads waiting
    xor r12d, r12d
.cpu:
    cmp r12d, [cpu_count]
    jae .summed
    PERCPU rbx, r12
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    mov eax, [rbx + PC_RQ_LEN]
    cmp rbx, [gs:abs PC_SELF]
    jne .waiting
    test eax, eax                       ; here, one fewer: the thread 'main'
    jz .waiting                         ; took the CPU from to sample, whose
    dec eax                             ; time its busy time already holds
.waiting:
    add r14, rax
    mov rax, [rbx + PC_BUSY_CYC]        ; its busy time up to now
    cmp dword [rbx + PC_BUSY], 0
    je .counted
    mov rcx, r15
    sub rcx, [rbx + PC_LAST_TSC]
    jle .counted                        ; (counted on its CPU a moment ago)
    add rax, rcx
.counted:
    lea rdx, [load_busy]
    mov rcx, rax
    sub rcx, [rdx + r12 * 8]            ; since the last sample
    mov [rdx + r12 * 8], rax
    jle .next
    cmp rcx, r10
    jbe .add
    mov rcx, r10                        ; (no more than all of it)
.add:
    add r13, rcx
.next:
    inc r12d
    jmp .cpu
.summed:
    cmp qword [load_at], 0
    mov [load_at], r15
    je .done                            ; the first: where busy times begin
    mov rax, r13                        ; CPUs busy, on average, fixed point
    mov ecx, LOAD_ONE
    mul rcx
    div r10
    shl r14, LOAD_SHIFT
    add r14, rax                        ; the threads that wanted a CPU
    mov rax, r10                        ; steps it spans
    xor edx, edx
    div r9
    mov ecx, eax
    test ecx, ecx
    jnz .some
    mov ecx, 1
.some:
    cmp ecx, LOAD_STEPS_MAX
    jbe .fold
    mov ecx, LOAD_STEPS_MAX
.fold:
    mov rax, [load_avg]
    mov rbx, rax
    imul rax, rax, LOAD_EXP
    mov rdx, r14
    imul rdx, rdx, LOAD_ONE - LOAD_EXP
    add rax, rdx
    cmp r14, rbx
    jb .down
    add rax, LOAD_ONE - 1               ; rising: up (as Linux, to reach it)
.down:
    shr rax, LOAD_SHIFT
    mov [load_avg], rax
    dec ecx
    jnz .fold
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.out:
    ret

; load_info -> RAX = the load average over the last minute, in hundredths.
; Any thread. Preserves others.
load_info:
    mov rax, [load_avg]
    imul rax, rax, 100
    add rax, LOAD_ONE / 2
    shr rax, LOAD_SHIFT
    ret

section .bss
alignb 8
load_next:      resq 1                  ; TSC: the next sample
load_at:        resq 1                  ; the last one, or 0
load_avg:       resq 1                  ; the average, fixed point
load_busy:      resq MAX_CPUS           ; each CPU's busy time, at the last
