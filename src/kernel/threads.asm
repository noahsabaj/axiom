; =============================================================================
;  threads.asm - 'threads': what each CPU has done and every thread there is;
;  'threads test', the scheduler's self-test; 'threads spin', load to watch
;  on the dashboard
; =============================================================================

TT_SPAWN        equ 2000                ; threads started and joined
TT_BATCH        equ 50                  ; at once
TT_PINGS        equ 20000               ; round trips between two threads
TT_SLEEPS       equ 50                  ; 1 ms sleeps, timed
TT_FAIR_MS      equ 300
TT_SPREAD_MS    equ 200
TT_KINDS_MS     equ 200
TT_MAX          equ 512                 ; spinners at most

; a spinner's slot
TS_CTRL         equ 0                   ; -> the flag that stops it
TS_PAT          equ 8                   ; what its SIMD registers hold
TS_ITERS        equ 16
TS_BAD          equ 24                  ; checks that found a register changed
TS_TH           equ 32                  ; its thread
TS_CYC          equ 40                  ; the CPU time it had, once it ended
TS_P            equ 48                  ; of that, on P-cores
TS_E            equ 56                  ; on E-cores
TS_SWITCHES     equ 64
TS_BUF          equ 72                  ; 32 bytes, to look at a register
TS_SIZE         equ 112

; a line of the thread listing
TR_ID           equ 0
TR_STATE        equ 8
TR_CPU          equ 16
TR_CLASS        equ 24
TR_P            equ 32
TR_E            equ 40
TR_O            equ 48
TR_SWITCHES     equ 56
TR_MOVES        equ 64
TR_PIN          equ 72
TR_NAME         equ 80
TR_SIZE         equ 112

section .text

; -----------------------------------------------------------------------------
;  threads, threads cpus: records (records.asm), from the words after them
;  (EDI = how many, RSI = them); CF if it failed. threads test and threads
;  spin print.
; -----------------------------------------------------------------------------

; threads spin <count> [perf|eff|any] [seconds], from the shell's words
threads_spin_words:
    mov rdi, [sh_args]
    jmp threads_spin

; threads cpus: what each CPU has done
threads_cpus:
    push rbx
    push r12
    push r13
    push r15
    test edi, edi
    jnz .usage
    COLUMN 'cpu', FT_INT
    COLUMN 'kind', FT_TEXT
    COLUMN 'waiting', FT_INT
    COLUMN 'busy', FT_INT, 0, '%'
    COLUMN 'switches', FT_INT
    COLUMN 'stolen', FT_INT
    COLUMN 'handed', FT_INT
    RDTSC64
    mov r15, rax
    xor r12d, r12d
.cpu:
    cmp r12d, [cpu_count]
    jae .done
    PERCPU rbx, r12
    cmp byte [rbx + PC_SCHED_ON], 0
    je .next
    mov rax, r15                        ; the time not yet counted, counted
    sub rax, [rbx + PC_LAST_TSC]
    mov rcx, [rbx + PC_BUSY_CYC]
    mov rdx, [rbx + PC_IDLE_CYC]
    cmp dword [rbx + PC_BUSY], 0
    je .idle_now
    add rcx, rax
    jmp .counted
.idle_now:
    add rdx, rax
.counted:
    add rdx, rcx
    mov rax, rcx
    imul rax, rax, 100
    test rdx, rdx
    jz .percent
    push rdx
    xor edx, edx
    div qword [rsp]
    add rsp, 8
.percent:
    mov r13, rax
    call rec_row
    xor edi, edi
    mov esi, r12d
    call rec_set
    mov rdi, [rbx + PC_SKIND]
    call sh_kind_name
    mov edi, 1
    mov rsi, rax
    call rec_set
    mov edi, 2
    mov esi, [rbx + PC_RQ_LEN]
    call rec_set
    mov edi, 3
    mov rsi, r13
    call rec_set
    mov edi, 4
    mov rsi, [rbx + PC_SWITCHES]
    call rec_set
    mov edi, 5
    mov rsi, [rbx + PC_STEALS]
    call rec_set
    mov edi, 6
    mov rsi, [rbx + PC_PUSHES]
    call rec_set
.next:
    inc r12d
    jmp .cpu
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: threads cpus"
    stc
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; threads: every thread there is
threads_list:
    push rbx
    push r12
    push r13
    push r14
    push r15
    test edi, edi
    jnz .usage
    COLUMN 'id', FT_INT
    COLUMN 'name', FT_TEXT
    COLUMN 'state', FT_TEXT
    COLUMN 'cpu', FT_INT
    COLUMN 'class', FT_TEXT
    COLUMN 'pinned', FT_BOOL
    COLUMN 'p-time', FT_DUR
    COLUMN 'e-time', FT_DUR
    COLUMN 'other-time', FT_DUR
    COLUMN 'switches', FT_INT
    COLUMN 'moves', FT_INT
    mov rdi, [thread_count]             ; a copy, taken under the lock
    add rdi, 16
    imul rdi, rdi, TR_SIZE
    call kmalloc
    test rax, rax
    jz .no_memory
    mov r14, rax
    mov r13, [thread_count]
    add r13, 16                         ; room
    xor r12d, r12d                      ; lines taken
    pushfq
    cli
    lea rdi, [threads_lock]
    call spin_lock
    mov rbx, [thread_list]
.copy:
    test rbx, rbx
    jz .copied
    cmp r12, r13
    jae .copied
    imul rdi, r12, TR_SIZE
    add rdi, r14
    mov rax, [rbx + TH_ID]
    mov [rdi + TR_ID], rax
    mov eax, [rbx + TH_STATE]
    mov [rdi + TR_STATE], rax
    mov rax, [rbx + TH_CPU]
    mov [rdi + TR_CPU], rax
    mov rax, [rbx + TH_CLASS]
    mov [rdi + TR_CLASS], rax
    mov rax, [rbx + TH_CYC_P]
    mov [rdi + TR_P], rax
    mov rax, [rbx + TH_CYC_E]
    mov [rdi + TR_E], rax
    mov rax, [rbx + TH_CYC_O]
    mov [rdi + TR_O], rax
    mov rax, [rbx + TH_SWITCHES]
    mov [rdi + TR_SWITCHES], rax
    mov rax, [rbx + TH_MIGRATIONS]
    mov [rdi + TR_MOVES], rax
    mov rax, [rbx + TH_PIN]
    mov [rdi + TR_PIN], rax
    lea rsi, [rbx + TH_NAME]
    add rdi, TR_NAME
    mov ecx, TH_NAME_LEN
    rep movsb
    inc r12
    mov rbx, [rbx + TH_ALL_NEXT]
    jmp .copy
.copied:
    lea rdi, [threads_lock]
    call spin_unlock
    popfq
    xor r13d, r13d
.line:
    cmp r13, r12
    jae .free
    imul rbx, r13, TR_SIZE
    add rbx, r14
    call rec_row
    xor edi, edi
    mov rsi, [rbx + TR_ID]
    call rec_set
    mov edi, 1
    lea rsi, [rbx + TR_NAME]
    call rec_str
    mov rax, [rbx + TR_STATE]
    lea rcx, [tt_state_names]
    mov rsi, [rcx + rax * 8]
    mov edi, 2
    call rec_set
    mov edi, 3
    mov rsi, [rbx + TR_CPU]
    call rec_set
    mov rax, [rbx + TR_CLASS]
    lea rcx, [tt_class_names]
    mov rsi, [rcx + rax * 8]
    mov edi, 4
    call rec_set
    xor esi, esi
    cmp qword [rbx + TR_PIN], -1
    je .pin
    mov esi, 1
.pin:
    mov edi, 5
    call rec_set
    mov rax, [rbx + TR_P]
    call tt_us
    mov rsi, rax
    mov edi, 6
    call rec_set
    mov rax, [rbx + TR_E]
    call tt_us
    mov rsi, rax
    mov edi, 7
    call rec_set
    mov rax, [rbx + TR_O]
    call tt_us
    mov rsi, rax
    mov edi, 8
    call rec_set
    mov edi, 9
    mov rsi, [rbx + TR_SWITCHES]
    call rec_set
    mov edi, 10
    mov rsi, [rbx + TR_MOVES]
    call rec_set
    inc r13
    jmp .line
.free:
    mov rdi, r14
    call kfree
    clc
    jmp .out
.no_memory:
    KLOG "threads: no memory to list them"
    stc
    jmp .out
.usage:
    KLOG "usage: threads [cpus | test | spin <n> [perf|eff|any] [seconds]]"
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tt_ms(RAX = TSC ticks) -> RAX = milliseconds. Preserves others.
tt_ms:
    push rdx
    xor edx, edx
    div qword [tsc_per_ms]
    pop rdx
    ret

; tt_us(RAX = TSC ticks) -> RAX = microseconds. Preserves others.
tt_us:
    push rdx
    xor edx, edx
    div qword [tsc_per_us]
    pop rdx
    ret

; tt_kind_name(RDI = CPU_KIND_*) -> RAX
tt_kind_name:
    lea rax, [str_tt_kind_p]
    cmp rdi, CPU_KIND_P
    je .out
    lea rax, [str_tt_kind_e]
    cmp rdi, CPU_KIND_E
    je .out
    lea rax, [str_tt_kind_o]
.out:
    ret

; -----------------------------------------------------------------------------
;  threads spin <count> [perf|eff|any] [seconds]: threads that only compute,
;  for that long, each saying at the end where it ran
; -----------------------------------------------------------------------------
threads_spin:
    push rbx
    push r12
    push r13
    push r14
    mov rsi, rdi
    cmp byte [rsi], 0
    je .usage
    call arg_split
    call arg_uint
    jc .usage
    test eax, eax
    jz .usage
    cmp eax, TT_MAX
    ja .usage
    mov r12d, eax                       ; how many
    xor r13d, r13d                      ; class
    mov r14d, 5                         ; seconds
.word:
    cmp byte [rdi], 0
    je .go
    mov rsi, rdi
    call arg_split
    xor ecx, ecx
.class:
    lea rax, [tt_class_names]
    push rdi
    mov rdi, [rax + rcx * 8]
    call streq
    pop rdi
    test eax, eax
    jnz .classed
    inc ecx
    cmp ecx, 3
    jb .class
    call arg_uint
    jc .usage
    test eax, eax
    jz .usage
    cmp eax, 3600
    ja .usage
    mov r14d, eax
    jmp .word
.classed:
    mov r13d, ecx
    jmp .word
.go:
    lea rax, [tt_class_names]
    mov rax, [rax + r13 * 8]
    KLOG "spin: %u threads (%s) for %u s", r12, rax, r14
    RDTSC64
    mov rbx, r14
    imul rbx, [tsc_hz]
    add rbx, rax                        ; when they stop
.spawn:
    lea rdi, [tt_spin_for]
    mov rsi, rbx
    lea rdx, [str_tt_spin]
    mov ecx, r13d
    call thread_spawn
    test rax, rax
    jz .oom
    mov rdi, rax
    call thread_detach
    dec r12d
    jnz .spawn
    jmp .out
.oom:
    KLOG "spin: out of memory"
    jmp .out
.usage:
    KLOG "usage: threads spin <count> [perf|eff|any] [seconds]"
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tt_spin_for(RDI = TSC when to stop): compute until then, then say where
tt_spin_for:
    push rbx
    mov rbx, rdi
.spin:
    mov ecx, 100000
.work:
    dec ecx
    jnz .work
    RDTSC64
    cmp rax, rbx
    jb .spin
    call thread_account
    mov rbx, [gs:PC_CURRENT]
    mov rax, [rbx + TH_CYC_P]
    add rax, [rbx + TH_CYC_E]
    add rax, [rbx + TH_CYC_O]
    mov rcx, rax                        ; all of it
    call tt_ms
    mov r8, rax
    mov rax, [rbx + TH_CYC_P]
    call tt_percent
    mov r9, rax
    mov rax, [rbx + TH_CYC_E]
    call tt_percent
    KLOG "spin: thread %u ran %u ms, %u%% on P-cores and %u%% on E-cores, and moved %u times", qword [rbx + TH_ID], r8, r9, rax, qword [rbx + TH_MIGRATIONS]
    xor eax, eax
    pop rbx
    ret

; tt_percent(RAX = part, RCX = whole) -> RAX = percent. Preserves others.
tt_percent:
    push rdx
    imul rax, rax, 100
    test rcx, rcx
    jz .zero
    xor edx, edx
    div rcx
    pop rdx
    ret
.zero:
    xor eax, eax
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  threads test
; -----------------------------------------------------------------------------
threads_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov qword [tt_fails], 0
    mov eax, [cpus_online]
    mov [tt_cpus], rax
    call sched_reap
    mov rax, [thread_count]
    mov [tt_base_threads], rax
    mov rax, [heap_objects]
    mov [tt_base_objects], rax
    mov rax, [vm_count]
    sub rax, [stack_cached]             ; kept for new threads, not leaked
    mov [tt_base_vm], rax

    call tt_spawn
    mov edi, 1                          ; switching, on one CPU
    cmp qword [tt_cpus], 1
    ja .one
    xor edi, edi
.one:
    mov esi, edi
    call tt_pingpong
    mov r12, rax
    KLOG "threads test: two threads on one CPU, taking turns %u times: %u ns a switch", TT_PINGS, r12
    cmp qword [tt_cpus], 1              ; waking, from one CPU to another
    jbe .sleep
    mov edi, 1
    xor esi, esi
    cmp qword [tt_cpus], 2
    je .two
    mov esi, 2
.two:
    call tt_pingpong
    mov r12, rax
    KLOG "threads test: two threads on two CPUs, taking turns %u times: %u ns a wake-up", TT_PINGS, r12
.sleep:
    call tt_sleeps
    call tt_fair
    call tt_spread
    call tt_kinds
    call tt_leaks
    cmp qword [tt_fails], 0
    jne .failed
    KLOG "threads test: passed"
    jmp .out
.failed:
    KLOG "threads test: FAILED (%u)", qword [tt_fails]
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

tt_fail:
    inc qword [tt_fails]
    ret

; tt_spawn: start and join TT_SPAWN threads, TT_BATCH at a time; each
; returns three times its argument
tt_spawn:
    push rbx
    push r12
    push r13
    push r14
    push r15
    RDTSC64
    mov r15, rax
    xor r12d, r12d                      ; started so far
    xor r14d, r14d                      ; wrong answers
.batch:
    xor r13d, r13d
.start:
    lea rdi, [tt_triple]
    lea rsi, [r12 + r13]
    lea rdx, [str_tt_short]
    xor ecx, ecx
    call thread_spawn
    test rax, rax
    jz .oom
    lea rcx, [tt_handles]
    mov [rcx + r13 * 8], rax
    inc r13d
    cmp r13d, TT_BATCH
    jb .start
    xor r13d, r13d
.join:
    lea rcx, [tt_handles]
    mov rdi, [rcx + r13 * 8]
    call thread_join
    lea rcx, [r12 + r13]
    imul rcx, rcx, 3
    cmp rax, rcx
    je .right
    inc r14d
.right:
    inc r13d
    cmp r13d, TT_BATCH
    jb .join
    add r12d, TT_BATCH
    cmp r12d, TT_SPAWN
    jb .batch
    RDTSC64
    sub rax, r15
    imul rax, rax, 1000
    call tt_us
    xor edx, edx
    mov ecx, TT_SPAWN
    div rcx
    KLOG "threads test: %u threads started and joined, %u at a time: %u ns each, %u wrong answers", TT_SPAWN, TT_BATCH, rax, r14
    test r14d, r14d
    jz .out
    call tt_fail
    jmp .out
.oom:
    KLOG "threads test: out of memory starting threads"
    call tt_fail
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

tt_triple:
    lea rax, [rdi + rdi * 2]
    ret

; tt_pingpong(EDI = A's CPU, ESI = B's CPU) -> RAX = ns for one handover:
; A and B, pinned there, take turns TT_PINGS times each
tt_pingpong:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov dword [pp_turn], 0
    lea rdi, [tt_pong]
    mov esi, TT_PINGS
    lea rdx, [str_tt_pong]
    call thread_new
    test rax, rax
    jz .oom
    mov [pp_b], rax
    mov [rax + TH_PIN], r13
    lea rdi, [tt_ping]
    mov esi, TT_PINGS
    lea rdx, [str_tt_ping]
    call thread_new
    test rax, rax
    jz .oom
    mov [pp_a], rax
    mov [rax + TH_PIN], r12
    RDTSC64
    mov rbx, rax
    mov rdi, [pp_b]
    call thread_start
    mov rdi, [pp_a]
    call thread_start
    mov rdi, [pp_a]
    call thread_join
    mov rdi, [pp_b]
    call thread_join
    RDTSC64
    sub rax, rbx
    imul rax, rax, 1000
    call tt_us
    xor edx, edx
    mov ecx, TT_PINGS * 2
    div rcx
    jmp .out
.oom:
    KLOG "threads test: out of memory"
    call tt_fail
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rbx
    ret

tt_ping:                                ; RDI = rounds
    push rbx
    mov rbx, rdi
.round:
    mov dword [pp_turn], 1
    mov rdi, [pp_b]
    call thread_unpark
.wait:
    cmp dword [pp_turn], 0
    je .next
    call thread_park
    jmp .wait
.next:
    dec rbx
    jnz .round
    xor eax, eax
    pop rbx
    ret

tt_pong:
    push rbx
    mov rbx, rdi
.wait:
    cmp dword [pp_turn], 1
    je .turn
    call thread_park
    jmp .wait
.turn:
    mov dword [pp_turn], 0
    mov rdi, [pp_a]
    call thread_unpark
    dec rbx
    jnz .wait
    xor eax, eax
    pop rbx
    ret

; tt_sleeps: 1 ms sleeps, how late each wakes
tt_sleeps:
    push rbx
    push r12
    push r13
    push r14
    xor r12d, r12d                      ; total lateness
    xor r13d, r13d                      ; the most
    mov r14d, TT_SLEEPS
.sleep:
    RDTSC64
    mov rbx, [tsc_per_ms]
    add rbx, rax
    mov rdi, rbx
    call thread_sleep_until
    RDTSC64
    sub rax, rbx
    add r12, rax
    cmp rax, r13
    cmova r13, rax
    dec r14d
    jnz .sleep
    mov rax, r12
    call tt_us
    xor edx, edx
    mov ecx, TT_SLEEPS
    div rcx
    mov r12, rax
    mov rax, r13
    call tt_us
    KLOG "threads test: %u sleeps of 1 ms: %u us late on average, %u us at most", TT_SLEEPS, r12, rax
    cmp r12, 5000
    jb .out
    call tt_fail
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tt_spinners(EDI = first slot, ESI = how many, EDX = class, RCX = flag that
; stops them, R8 = CPU to start on or -1, R9 = CPU to pin to or -1): start
; spinners in those slots
tt_spinners:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov r12d, edi
    lea r13d, [rdi + rsi]
    mov r14d, edx
    mov r15, rcx
    mov rbp, r8
    push r9
.slot:
    cmp r12d, r13d
    jae .out
    imul rbx, r12, TS_SIZE
    lea rax, [tt_slots]
    add rbx, rax
    mov rdi, rbx
    xor eax, eax
    mov ecx, TS_SIZE
    rep stosb
    mov [rbx + TS_CTRL], r15
    lea eax, [r12 + 0x11]
    imul eax, eax, 0x01010101
    mov [rbx + TS_PAT], rax
    lea rdi, [tt_spinner]
    mov rsi, rbx
    lea rdx, [str_tt_spinner]
    call thread_new
    test rax, rax
    jz .oom
    mov [rbx + TS_TH], rax
    mov [rax + TH_CLASS], r14
    mov [rax + TH_HINT], rbp
    mov rcx, [rsp]
    mov [rax + TH_PIN], rcx
    mov rdi, rax
    call thread_start
    inc r12d
    jmp .slot
.oom:
    KLOG "threads test: out of memory starting spinners"
    call tt_fail
.out:
    pop r9
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tt_spinner(RDI = its slot): compute until its flag is set, with every SIMD
; register holding a value of its own, looking that they still do
tt_spinner:
    push rbx
    mov rbx, rdi
    mov eax, [rbx + TS_PAT]
%assign i 0
%rep 16
    lea ecx, [rax + i]
    movd xmm %+ i, ecx
    pshufd xmm %+ i, xmm %+ i, 0
%assign i i + 1
%endrep
    test byte [cpu_xcr0], 4             ; AVX: the upper halves too
    jz .spin
%assign i 0
%rep 16
    vinsertf128 ymm %+ i, ymm %+ i, xmm %+ i, 1
%assign i i + 1
%endrep
.spin:
    mov ecx, 20000
.work:
    dec ecx
    jnz .work
    inc qword [rbx + TS_ITERS]
    call tt_look
    mov rax, [rbx + TS_CTRL]
    cmp byte [rax], 0
    je .spin
    xor eax, eax
    pop rbx
    ret

; tt_look(RBX = slot): are the registers still what tt_spinner put there?
tt_look:
    mov r8d, 4                          ; dwords to look at in each
    test byte [cpu_xcr0], 4
    jz .sse
    mov r8d, 8
%assign i 0
%rep 16
    vmovdqu [rbx + TS_BUF], ymm %+ i
    mov edx, [rbx + TS_PAT]
    add edx, i
    call tt_same
%assign i i + 1
%endrep
    ret
.sse:
%assign i 0
%rep 16
    movdqu [rbx + TS_BUF], xmm %+ i
    mov edx, [rbx + TS_PAT]
    add edx, i
    call tt_same
%assign i i + 1
%endrep
    ret

; tt_same(RBX = slot, EDX = value, R8D = dwords): count a change
tt_same:
    xor ecx, ecx
.dword:
    cmp [rbx + TS_BUF + rcx * 4], edx
    jne .changed
    inc ecx
    cmp ecx, r8d
    jb .dword
    ret
.changed:
    inc qword [rbx + TS_BAD]
    ret

; tt_collect(EDI = first slot, ESI = how many): wait for each spinner to end
; (its CPU off its stack, its time all counted), keep what it had, join it.
; Sums in tt_sum, tt_min, tt_max, tt_bad, tt_switches.
tt_collect:
    push rbx
    push r12
    push r13
    mov r12d, edi
    lea r13d, [rdi + rsi]
    mov qword [tt_sum], 0
    mov qword [tt_min], -1
    mov qword [tt_max], 0
    mov qword [tt_bad], 0
    mov qword [tt_switches], 0
.slot:
    cmp r12d, r13d
    jae .out
    imul rbx, r12, TS_SIZE
    lea rax, [tt_slots]
    add rbx, rax
    mov rdi, [rbx + TS_TH]
    test rdi, rdi
    jz .next
.wait:
    cmp dword [rdi + TH_STATE], TS_DEAD
    jne .not_yet
    cmp dword [rdi + TH_ONCPU], 0
    je .ended
.not_yet:
    push rdi
    mov edi, 200
    call thread_sleep_us
    pop rdi
    jmp .wait
.ended:
    mov rax, [rdi + TH_CYC_P]
    mov [rbx + TS_P], rax
    mov rcx, [rdi + TH_CYC_E]
    mov [rbx + TS_E], rcx
    add rax, rcx
    add rax, [rdi + TH_CYC_O]
    mov [rbx + TS_CYC], rax
    add [tt_sum], rax
    cmp rax, [tt_min]
    jae .not_min
    mov [tt_min], rax
.not_min:
    cmp rax, [tt_max]
    jbe .not_max
    mov [tt_max], rax
.not_max:
    mov rax, [rdi + TH_SWITCHES]
    mov [rbx + TS_SWITCHES], rax
    add [tt_switches], rax
    mov rax, [rbx + TS_BAD]
    add [tt_bad], rax
    call thread_join
    mov qword [rbx + TS_TH], 0
.next:
    inc r12d
    jmp .slot
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tt_fair: twice as many spinners as CPUs, placed as the scheduler likes, for
; TT_FAIR_MS while the main thread sleeps: each should have a fair share, the
; main thread should wake on time, and no SIMD register should change
tt_fair:
    push rbx
    push r12
    push r13
    mov r12, [tt_cpus]
    shl r12, 1
    cmp r12, TT_MAX
    jbe .count
    mov r12d, TT_MAX
.count:
    mov byte [tt_stop], 0
    xor edi, edi
    mov esi, r12d
    xor edx, edx
    lea rcx, [tt_stop]
    mov r8, -1
    mov r9, -1
    call tt_spinners
    RDTSC64
    mov rbx, [tsc_per_ms]
    imul rbx, rbx, TT_FAIR_MS
    add rbx, rax
    mov rdi, rbx
    call thread_sleep_until
    RDTSC64
    sub rax, rbx
    mov r13, rax                        ; how late the main thread woke
    mov byte [tt_stop], 1
    xor edi, edi
    mov esi, r12d
    call tt_collect
    mov rax, [tt_sum]
    xor edx, edx
    div r12
    mov rbx, rax                        ; the mean
    mov rax, [tt_min]
    call tt_ms
    mov rcx, rax
    mov rax, [tt_max]
    call tt_ms
    mov rdx, rax
    mov rax, rbx
    call tt_ms
    mov r8, rax
    mov rax, r13
    call tt_us
    KLOG "threads test: %u spinning threads on %u CPUs for %u ms: %u to %u ms of CPU each (%u on average); the main thread woke %u us late", r12, qword [tt_cpus], TT_FAIR_MS, rcx, rdx, r8, rax
    KLOG "threads test: SIMD registers checked across %u switches: %u found changed", qword [tt_switches], qword [tt_bad]
    mov rax, rbx                        ; the least at least half the mean
    shr rax, 1
    cmp [tt_min], rax
    jae .fair
    KLOG "threads test: not fair"
    call tt_fail
.fair:
    mov rax, r13                        ; the main thread within 20 ms
    call tt_us
    cmp rax, 20000
    jb .on_time
    call tt_fail
.on_time:
    cmp qword [tt_bad], 0
    je .intact
    call tt_fail
.intact:
    mov rax, [tt_switches]              ; preempted, not just run to the end
    cmp rax, r12
    ja .out
    KLOG "threads test: no thread was preempted"
    call tt_fail
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tt_spread: twice as many spinners as CPUs, all started on CPU 1: the CPUs
; that idle should take them, until each CPU has its share
tt_spread:
    push rbx
    push r12
    push r13
    cmp qword [tt_cpus], 2
    jb .out
    mov r12, [tt_cpus]
    shl r12, 1
    cmp r12, TT_MAX
    jbe .count
    mov r12d, TT_MAX
.count:
    call tt_moves
    mov r13, rax
    mov byte [tt_stop], 0
    xor edi, edi
    mov esi, r12d
    xor edx, edx
    lea rcx, [tt_stop]
    mov r8d, 1
    mov r9, -1
    call tt_spinners
    mov edi, TT_SPREAD_MS * 1000
    call thread_sleep_us
    mov byte [tt_stop], 1
    xor edi, edi
    mov esi, r12d
    call tt_collect
    call tt_moves
    sub r13, rax
    neg r13                             ; threads stolen or handed over
    mov rax, [tt_sum]
    xor edx, edx
    div r12
    mov rbx, rax
    mov rax, [tt_min]
    call tt_ms
    mov rcx, rax
    mov rax, rbx
    call tt_ms
    KLOG "threads test: %u threads started on CPU 1 spread out: %u stolen or handed over; %u ms of CPU at least, %u on average", r12, r13, rcx, rax
    test r13, r13
    jz .bad
    mov rax, rbx
    imul rax, rax, 3                    ; the least at least 30% of the mean
    xor edx, edx
    mov ecx, 10
    div rcx
    cmp [tt_min], rax
    jae .out
.bad:
    KLOG "threads test: they did not spread"
    call tt_fail
.out:
    pop r13
    pop r12
    pop rbx
    ret

; tt_moves -> RAX = threads every CPU has stolen or handed over
tt_moves:
    push rbx
    xor eax, eax
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .out
    PERCPU rbx, rcx
    add rax, [rbx + PC_STEALS]
    add rax, [rbx + PC_PUSHES]
    inc ecx
    jmp .cpu
.out:
    pop rbx
    ret

; tt_kinds: perf threads on P-cores, eff threads on E-cores, and a perf
; thread that had to start on an E-core moving once a P-core idles. On a
; machine with one kind of core, the scheduler is told half are P-cores.
tt_kinds:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov byte [tt_pretend], 0
    cmp qword [sched_np], 0
    je .pretend
    cmp qword [sched_ne], 0
    jne .kinds
.pretend:
    cmp qword [tt_cpus], 4
    jb .skip
    mov byte [tt_pretend], 1
    mov edi, 1
    call sched_pretend
.kinds:
    xor r12d, r12d                      ; P-cores (whole ones)
    xor r13d, r13d                      ; P CPUs
    xor r14d, r14d                      ; E CPUs
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .counted
    PERCPU rbx, rcx
    cmp byte [rbx + PC_SCHED_ON], 0
    je .cpu_next
    cmp qword [rbx + PC_SKIND], CPU_KIND_E
    jne .not_e
    inc r14d
    jmp .cpu_next
.not_e:
    cmp qword [rbx + PC_SKIND], CPU_KIND_P
    jne .cpu_next
    inc r13d
    mov rax, [rbx + PC_SIBLING]
    cmp rax, -1
    je .whole
    cmp rax, rcx
    jb .cpu_next                        ; its sibling counted the core
.whole:
    inc r12d
.cpu_next:
    inc ecx
    jmp .cpu
.counted:
    mov [tt_np], r13
    mov [tt_ne], r14
    lea eax, [r12 + r14]
    cmp eax, TT_MAX
    ja .skip_restore
    mov byte [tt_stop], 0               ; a perf thread for each P-core, an eff
    xor edi, edi                        ; thread for each E-core
    mov esi, r12d
    mov edx, THC_PERF
    lea rcx, [tt_stop]
    mov r8, -1
    mov r9, -1
    call tt_spinners
    mov edi, r12d
    mov esi, r14d
    mov edx, THC_EFF
    lea rcx, [tt_stop]
    mov r8, -1
    mov r9, -1
    call tt_spinners
    mov edi, TT_KINDS_MS * 1000
    call thread_sleep_us
    mov byte [tt_stop], 1
    xor edi, edi
    lea esi, [r12 + r14]
    call tt_collect
    xor edi, edi                        ; the perf threads' share on P-cores
    mov esi, r12d
    mov edx, TS_P
    call tt_share
    mov r15, rax
    mov edi, r12d                       ; the eff threads' on E-cores
    mov esi, r14d
    mov edx, TS_E
    call tt_share
    mov rbx, rax
    lea rax, [str_tt_real]
    cmp byte [tt_pretend], 0
    je .said
    lea rax, [str_tt_pretend]
.said:
    KLOG "threads test: %s: %u perf threads ran %u%% of their time on P-cores, %u eff threads %u%% on E-cores", rax, r12, r15, r14, rbx
    cmp r15, 90
    jb .misplaced
    cmp rbx, 90
    jae .misfit
.misplaced:
    call tt_fail

.misfit:                                ; every P CPU busy with a pinned thread
    xor r15d, r15d                      ; slots used
    xor ecx, ecx
.block:
    cmp ecx, [cpu_count]
    jae .blocked
    PERCPU rbx, rcx
    cmp byte [rbx + PC_SCHED_ON], 0
    je .block_next
    cmp qword [rbx + PC_SKIND], CPU_KIND_P
    jne .block_next
    push rcx
    mov edi, r15d
    mov esi, 1
    xor edx, edx
    lea rcx, [tt_stop2]
    mov r8, -1
    mov r9, [rsp]
    mov byte [tt_stop2], 0
    call tt_spinners
    pop rcx
    inc r15d
.block_next:
    inc ecx
    jmp .block
.blocked:
    mov byte [tt_stop], 0               ; then a perf thread: an E-core for now
    mov edi, r15d
    mov esi, 1
    mov edx, THC_PERF
    lea rcx, [tt_stop]
    mov r8, -1
    mov r9, -1
    call tt_spinners
    mov edi, 30000
    call thread_sleep_us
    imul rbx, r15, TS_SIZE
    lea rax, [tt_slots]
    add rbx, rax
    mov rax, [rbx + TS_TH]
    test rax, rax
    jz .misfit_bad
    mov rax, [rax + TH_CPU]
    PERCPU rcx, rax
    mov r12, [rcx + PC_SKIND]           ; where it started
    mov byte [tt_stop2], 1              ; the P-cores go idle
    RDTSC64
    mov r13, rax
    mov r14d, 500                       ; then up to 500 ms
.poll:
    mov edi, 1000
    call thread_sleep_us
    mov rax, [rbx + TS_TH]
    mov rax, [rax + TH_CPU]
    PERCPU rcx, rax
    cmp qword [rcx + PC_SKIND], CPU_KIND_P
    je .moved
    dec r14d
    jnz .poll
.moved:
    RDTSC64
    sub rax, r13
    call tt_us
    mov r13, rax
    mov byte [tt_stop], 1
    xor edi, edi
    lea esi, [r15 + 1]
    call tt_collect
    mov rax, r13
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov rcx, rax                        ; ms
    mov rdi, r12
    call tt_kind_name
    KLOG "threads test: a perf thread started on an %s CPU while every P-core was busy; moved to a P-core %u ms after they went idle", rax, rcx
    cmp r12, CPU_KIND_E
    jne .misfit_bad
    test r14d, r14d
    jnz .restore
.misfit_bad:
    KLOG "threads test: the perf thread did not move to a P-core"
    call tt_fail
    jmp .restore
.skip_restore:
    KLOG "threads test: too many cores for the P/E test"
.restore:
    cmp byte [tt_pretend], 0
    je .out
    xor edi, edi
    call sched_pretend
    jmp .out
.skip:
    KLOG "threads test: one kind of core and fewer than 4 CPUs: no P/E test"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; tt_share(EDI = first slot, ESI = how many, EDX = TS_P or TS_E) -> RAX =
; percent of those spinners' CPU time there
tt_share:
    push rbx
    xor r8d, r8d                        ; there
    xor r9d, r9d                        ; all
    lea r10d, [rdi + rsi]
.slot:
    cmp edi, r10d
    jae .done
    imul rbx, rdi, TS_SIZE
    lea rax, [tt_slots]
    add rbx, rax
    add r8, [rbx + rdx]
    add r9, [rbx + TS_CYC]
    inc edi
    jmp .slot
.done:
    mov rax, r8
    mov rcx, r9
    call tt_percent
    test r9, r9
    jnz .out
    mov eax, 100                        ; no threads, nothing wrong
.out:
    pop rbx
    ret

; tt_leaks: every thread gone, and what it had
tt_leaks:
    mov edi, 20000
    call thread_sleep_us
    call sched_reap
    mov rax, [vm_count]
    sub rax, [stack_cached]
    KLOG "threads test: %u threads (%u before), %u heap objects (%u), %u vm mappings (%u) and %u kept for new threads", qword [thread_count], qword [tt_base_threads], qword [heap_objects], qword [tt_base_objects], rax, qword [tt_base_vm], qword [stack_cached]
    mov rax, [thread_count]
    cmp rax, [tt_base_threads]
    jne .leak
    mov rax, [heap_objects]
    cmp rax, [tt_base_objects]
    jne .leak
    mov rax, [vm_count]
    sub rax, [stack_cached]
    cmp rax, [tt_base_vm]
    jne .leak
    ret
.leak:
    KLOG "threads test: not all of it came back"
    jmp tt_fail

section .rodata
str_tt_test:    db 'test', 0
str_tt_spin:    db 'spin', 0
str_tt_short:   db 'short', 0
str_tt_ping:    db 'ping', 0
str_tt_pong:    db 'pong', 0
str_tt_spinner: db 'spinner', 0
str_tt_kind_p:  db 'P', 0
str_tt_kind_e:  db 'E', 0
str_tt_kind_o:  db '-', 0
str_tt_yes:     db 'yes', 0
str_tt_no:      db '', 0
str_tt_real:    db 'P-cores and E-cores', 0
str_tt_pretend: db 'P-cores and E-cores (pretended: the first half of the CPUs for P-cores)', 0
str_ts_new:     db 'new', 0
str_ts_ready:   db 'ready', 0
str_ts_running: db 'running', 0
str_ts_parked:  db 'parked', 0
str_ts_dead:    db 'dead', 0
str_thc_any:    db 'any', 0
str_thc_perf:   db 'perf', 0
str_thc_eff:    db 'eff', 0

section .data
align 8
tt_state_names: dq str_ts_new, str_ts_ready, str_ts_running, str_ts_parked, str_ts_dead
tt_class_names: dq str_thc_any, str_thc_perf, str_thc_eff

section .bss
alignb 8
tt_fails:       resq 1
tt_cpus:        resq 1
tt_base_threads: resq 1
tt_base_objects: resq 1
tt_base_vm:     resq 1
tt_sum:         resq 1
tt_min:         resq 1
tt_max:         resq 1
tt_bad:         resq 1
tt_switches:    resq 1
tt_np:          resq 1
tt_ne:          resq 1
pp_a:           resq 1
pp_b:           resq 1
pp_turn:        resd 1
tt_stop:        resb 1
tt_stop2:       resb 1
tt_pretend:     resb 1
alignb 8
tt_handles:     resq TT_BATCH
alignb 64
tt_slots:       resb TT_MAX * TS_SIZE
