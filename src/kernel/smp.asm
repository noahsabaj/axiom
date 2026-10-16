; =============================================================================
;  smp.asm - wake every logical processor, give each one its own stacks and
;  per-CPU block, and share work across all of them.
;
;  Bring-up is parallel: INIT to every AP, one 10 ms wait, then two rounds of
;  STARTUP IPIs. Each AP runs the trampoline (16 -> 32 -> 64-bit), finds its
;  own index from its APIC id, switches to its stack and reports online.
;
;  Work is shared through one job at a time: the BSP publishes a function and
;  an item count, wakes the APs with an IPI, and every CPU (the BSP included)
;  takes items with an atomic counter until none are left.
; =============================================================================

TRAMP_MIN       equ 0x10000             ; keep the trampoline out of the first 64 KiB
TRAMP_LIMIT     equ 0xA0000             ; and below the legacy video hole

section .text

; -----------------------------------------------------------------------------
;  smp_init_bsp: after ACPI, make sure the BSP is entry 0 in cpu_apic_ids
; -----------------------------------------------------------------------------
smp_init_bsp:
    push rbx
    call lapic_self_id
    mov r8d, eax
    lea rdx, [cpu_apic_ids]
    cmp dword [cpu_count], 0
    jne .search
    mov [rdx], r8d                      ; no MADT: a machine of one
    mov dword [cpu_count], 1
    jmp .set
.search:
    xor ecx, ecx
.next:
    cmp ecx, [cpu_count]
    jae .missing
    cmp [rdx + rcx * 4], r8d
    je .found
    inc ecx
    jmp .next
.missing:                               ; firmware forgot the BSP: put it first
    mov ecx, [cpu_count]
    cmp ecx, MAX_CPUS
    jb .append
    dec ecx
.append:
    mov eax, [rdx]
    mov [rdx + rcx * 4], eax
    mov [rdx], r8d
    cmp ecx, [cpu_count]
    jb .set
    inc dword [cpu_count]
    jmp .set
.found:
    mov eax, [rdx]                      ; swap into slot 0
    mov [rdx + rcx * 4], eax
    mov [rdx], r8d
.set:
    lea rbx, [percpu]
    mov [rbx + PC_APIC_ID], r8
    mov qword [rbx + PC_ONLINE], 1
    mov dword [cpus_online], 1
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  smp_alloc_stacks(RBX = per-CPU block): kernel stack plus three IST stacks
; -----------------------------------------------------------------------------
smp_alloc_stacks:
    push rax
    push rdi
    mov edi, (KSTACK_SIZE + 3 * IST_SIZE) / 4096
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    add rax, [phys_base]
    add rax, KSTACK_SIZE
    mov [rbx + PC_STACK_TOP], rax
    mov [rbx + PC_TSS + TSS_RSP0], rax
    add rax, IST_SIZE
    mov [rbx + PC_TSS + TSS_IST1], rax  ; double fault
    add rax, IST_SIZE
    mov [rbx + PC_TSS + TSS_IST2], rax  ; NMI
    add rax, IST_SIZE
    mov [rbx + PC_TSS + TSS_IST3], rax  ; machine check
    pop rdi
    pop rax
    ret
.oom:
    xor edi, edi
    lea rsi, [str_smp_oom]
    jmp panic

; percpu_block(ECX = index) -> RBX
%macro PERCPU 2                         ; PERCPU dest, index register (64-bit)
    imul %1, %2, PC_SIZE
    add %1, percpu
%endmacro

; -----------------------------------------------------------------------------
;  smp_start: wake every AP the MADT lists
; -----------------------------------------------------------------------------
smp_start:
    push rbx
    push r12
    push r13
    push r14
    cmp dword [cpu_count], 1
    jbe .finish
    call smp_find_trampoline
    test rax, rax
    jz .no_room
    mov [tramp_phys], rax

    mov rdi, rax                        ; copy the trampoline below 1 MiB
    add rdi, [phys_base]
    mov r12, rdi
    lea rsi, [tramp_start]
    mov ecx, tramp_end - tramp_start
    rep movsb
    mov rax, [tramp_phys]               ; patch in its physical addresses
    lea rdx, [rax + (tramp_gdt - tramp_start)]
    mov [r12 + (tramp_gdtr - tramp_start) + 2], edx
    lea rdx, [rax + (tramp_pm32 - tramp_start)]
    mov [r12 + (tramp_far32 - tramp_start)], edx
    lea rdx, [rax + (tramp_lm64 - tramp_start)]
    mov [r12 + (tramp_far64 - tramp_start)], edx
    mov rax, cr3
    mov [r12 + (tramp_cr3 - tramp_start)], rax
    lea rax, [ap_entry]
    mov [r12 + (tramp_entry - tramp_start)], rax

    mov r12d, 1                         ; per-CPU blocks and stacks
.prepare:
    cmp r12d, [cpu_count]
    jae .prepared
    PERCPU rbx, r12
    mov [rbx + PC_SELF], rbx
    mov [rbx + PC_INDEX], r12
    lea rax, [cpu_apic_ids]
    mov eax, [rax + r12 * 4]
    mov [rbx + PC_APIC_ID], rax
    call smp_alloc_stacks
    inc r12d
    jmp .prepare
.prepared:
    mfence
    RDTSC64
    mov [smp_t0], rax

    mov r12d, 1                         ; INIT everyone
.init:
    cmp r12d, [cpu_count]
    jae .init_sent
    PERCPU rbx, r12
    mov edi, [rbx + PC_APIC_ID]
    mov esi, ICR_INIT
    call lapic_send_ipi
    inc r12d
    jmp .init
.init_sent:
    mov edi, 10000
    call delay_us

    mov r13d, 2                         ; two STARTUP rounds
.sipi_round:
    mov r12d, 1
.sipi:
    cmp r12d, [cpu_count]
    jae .sipi_sent
    PERCPU rbx, r12
    cmp qword [rbx + PC_ONLINE], 0
    jne .sipi_next
    mov edi, [rbx + PC_APIC_ID]
    mov rsi, [tramp_phys]
    shr esi, 12
    or esi, ICR_STARTUP
    call lapic_send_ipi
.sipi_next:
    inc r12d
    jmp .sipi
.sipi_sent:
    mov edi, 200
    call delay_us
    dec r13d
    jnz .sipi_round

    RDTSC64                             ; wait up to 500 ms for stragglers
    mov r14, [tsc_per_ms]
    imul r14, r14, 500
    add r14, rax
.wait:
    mov eax, [cpus_online]
    cmp eax, [cpu_count]
    jae .all_up
    pause
    RDTSC64
    cmp rax, r14
    jb .wait
.all_up:
    RDTSC64
    sub rax, [smp_t0]
    call ticks_to_us
    mov [smp_us], rax
    jmp .finish

.no_room:
    KLOG "smp: no free page below 1 MiB for the AP trampoline"
.finish:
    mov byte [smp_ready], 1
    call smp_topology
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; smp_find_trampoline -> RAX = a free page below 640 KiB (0 if none)
smp_find_trampoline:
    push r12
    push r13
    push r14
    call mmap_setup
.next:
    cmp r12, r13
    jae .none
    mov eax, [r12]
    cmp eax, MT_CONVENTIONAL
    je .usable
    cmp eax, MT_BS_CODE
    je .usable
    cmp eax, MT_BS_DATA
    jne .skip
.usable:
    mov rax, [r12 + 8]                  ; region start
    mov rcx, [r12 + 24]
    shl rcx, 12
    add rcx, rax                        ; region end
    cmp rax, TRAMP_MIN
    jae .start_ok
    mov eax, TRAMP_MIN
.start_ok:
    lea rdx, [rax + 0x1000]
    cmp rdx, rcx
    ja .skip
    cmp rdx, TRAMP_LIMIT
    ja .skip
    jmp .out
.skip:
    add r12, r14
    jmp .next
.none:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    ret

; -----------------------------------------------------------------------------
;  ap_entry: an AP arrives here in 64-bit mode on the kernel page tables,
;  with no stack and interrupts off
; -----------------------------------------------------------------------------
ap_entry:
    mov eax, 1
    cpuid
    shr ebx, 24
    mov r8d, ebx                        ; 8-bit initial APIC id
    cmp dword [cpu_max_leaf], 0x0B
    jb .search
    mov eax, 0x0B
    xor ecx, ecx
    cpuid
    mov r8d, edx                        ; full x2APIC id
.search:
    lea rdx, [cpu_apic_ids]
    xor ecx, ecx
.next:
    cmp ecx, [cpu_count]
    jae .lost
    cmp [rdx + rcx * 4], r8d
    je .found
    inc ecx
    jmp .next
.found:
    PERCPU rbx, rcx
    mov rsp, [rbx + PC_STACK_TOP]
    call cpu_bringup_local
    mov qword [rbx + PC_ONLINE], 1
    lock inc dword [cpus_online]
    jmp ap_idle
.lost:
    cli
    hlt
    jmp .lost

; cpu_bringup_local(RBX = per-CPU block): everything a CPU needs to run kernel code
cpu_bringup_local:
    call gdt_load
    mov ecx, MSR_GS_BASE
    mov rax, rbx
    mov rdx, rbx
    shr rdx, 32
    wrmsr
    call tss_install
    call idt_load
    call cpu_setup_local
    call lapic_enable_local
    call cpu_identify_local
    ret

; ap_idle: sleep until there is a job, run it, sleep again
ap_idle:
    cli
    mov rax, [job_gen]
    cmp rax, [gs:PC_JOB_GEN]
    jne .work
    sti                                 ; STI's shadow makes STI; HLT atomic
    hlt
    jmp ap_idle
.work:
    mov [gs:PC_JOB_GEN], rax
    sti
    call job_worker
    jmp ap_idle

; -----------------------------------------------------------------------------
;  smp_topology: number the cores within each kind and sort the CPUs for display
;  (P-cores, then E-cores, then everything else; by APIC id within a kind)
; -----------------------------------------------------------------------------
smp_topology:
    push rbx
    push r12
    push r13
    push r14
    xor ecx, ecx                        ; order = 0, 1, 2, ...
    lea rdi, [cpu_order]
.fill:
    cmp ecx, [cpu_count]
    jae .sort
    mov [rdi + rcx * 4], ecx
    inc ecx
    jmp .fill
.sort:                                  ; insertion sort on (kind rank, APIC id)
    mov r12d, 1
.outer:
    cmp r12d, [cpu_count]
    jae .sorted
    mov r13d, [rdi + r12 * 4]           ; the element being placed
    mov ecx, r13d
    call smp_sort_key
    mov r14, rax
    mov ecx, r12d
.inner:
    test ecx, ecx
    jz .place
    mov r8d, [rdi + rcx * 4 - 4]
    push rcx
    mov ecx, r8d
    call smp_sort_key
    pop rcx
    cmp rax, r14
    jbe .place
    mov [rdi + rcx * 4], r8d
    dec ecx
    jmp .inner
.place:
    mov [rdi + rcx * 4], r13d
    inc r12d
    jmp .outer
.sorted:
    mov qword [count_p], 0              ; renumber cores per kind, count threads
    mov qword [count_e], 0
    mov qword [count_other], 0
    mov r12, -1                         ; previous physical core id
    mov r13, -1                         ; previous kind
    xor r14d, r14d                      ; core number within the kind
    xor ecx, ecx
.renumber:
    cmp ecx, [cpu_count]
    jae .done
    mov eax, [rdi + rcx * 4]
    PERCPU rbx, rax
    cmp qword [rbx + PC_ONLINE], 0
    je .renumber_next
    mov rax, [rbx + PC_KIND]
    cmp rax, r13
    je .same_kind
    mov r13, rax
    mov r12, -1
    xor r14d, r14d
    jmp .new_core
.same_kind:
    mov rax, [rbx + PC_CORE]
    cmp rax, r12
    je .sibling
    inc r14
.new_core:
    mov r12, [rbx + PC_CORE]
    mov rax, [rbx + PC_KIND]
    lea rdx, [count_other]
    cmp rax, CPU_KIND_P
    jne .not_p
    lea rdx, [count_p]
.not_p:
    cmp rax, CPU_KIND_E
    jne .count
    lea rdx, [count_e]
.count:
    inc qword [rdx]
.sibling:
    mov [rbx + PC_CORE], r14
.renumber_next:
    inc ecx
    jmp .renumber
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; smp_sort_key(ECX = CPU index) -> RAX = kind rank << 32 | APIC id
smp_sort_key:
    push rbx
    PERCPU rbx, rcx
    mov rax, [rbx + PC_KIND]
    mov edx, 2                          ; unknown kinds sort last
    cmp rax, CPU_KIND_P
    jne .not_p
    xor edx, edx
.not_p:
    cmp rax, CPU_KIND_E
    jne .key
    mov edx, 1
.key:
    mov rax, rdx
    shl rax, 32
    or rax, [rbx + PC_APIC_ID]
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Jobs
;    job_run(RDI = fn, RSI = items, RDX = arg): fn(RDI = item, RSI = arg) is
;      called once per item, items spread over every online CPU
;    job_run_each(RDI = fn, RSI = arg): fn(RDI = CPU index, RSI = arg) runs
;      exactly once on every online CPU
;  Both return when all work is finished. BSP only.
; -----------------------------------------------------------------------------
job_run:
    mov [job_fn], rdi
    mov [job_arg], rdx
    mov [job_count], rsi
    mov qword [job_next], 0
    mov byte [job_each], 0
    jmp job_dispatch

job_run_each:
    mov [job_fn], rdi
    mov [job_arg], rsi
    mov byte [job_each], 1

job_dispatch:
    push rbx
    mov dword [job_checkins], 0
    mov eax, [cpus_online]
    mov [job_cpus], eax
    RDTSC64
    mov [job_t0], rax
    lock inc qword [job_gen]            ; publish (a locked op is a full fence)
    call smp_wake_all
    mov rax, [job_gen]
    mov [gs:PC_JOB_GEN], rax
    call job_worker
.wait:
    mov eax, [job_checkins]
    cmp eax, [job_cpus]
    jae .done
    pause
    jmp .wait
.done:
    RDTSC64
    sub rax, [job_t0]
    mov [job_cycles], rax
    pop rbx
    ret

job_worker:
    push rbx
    push r12
    push r13
    cmp byte [job_each], 0
    jne .each
    xor r12d, r12d                      ; items done here
    xor r13d, r13d                      ; cycles spent in them
    mov qword [gs:PC_ITERS], 0
.take:
    mov eax, 1
    lock xadd [job_next], rax
    cmp rax, [job_count]
    jae .no_more
    mov rbx, rax
    RDTSC64
    sub r13, rax
    mov rdi, rbx
    mov rsi, [job_arg]
    call [job_fn]
    RDTSC64
    add r13, rax
    inc r12
    jmp .take
.no_more:
    mov [gs:PC_JOB_ITEMS], r12
    mov [gs:PC_JOB_CYCLES], r13
    jmp .checkin
.each:
    mov rdi, [gs:PC_INDEX]
    mov rsi, [job_arg]
    call [job_fn]
.checkin:
    lock inc dword [job_checkins]
    pop r13
    pop r12
    pop rbx
    ret

; smp_wake_all: a wake-up IPI to every online AP. Preserves all.
smp_wake_all:
    push rbx
    push rcx
    push rdi
    push rsi
    mov ecx, 1
.next:
    cmp ecx, [cpu_count]
    jae .done
    PERCPU rbx, rcx
    cmp qword [rbx + PC_ONLINE], 0
    je .skip
    mov edi, [rbx + PC_APIC_ID]
    mov esi, ICR_FIXED | VEC_WAKE
    call lapic_send_ipi
.skip:
    inc ecx
    jmp .next
.done:
    pop rsi
    pop rdi
    pop rcx
    pop rbx
    ret

; smp_stop_others: NMI every other CPU (used by panic). Preserves all.
smp_stop_others:
    cmp byte [smp_ready], 0
    je .out
    push rdi
    push rsi
    xor edi, edi
    mov esi, ICR_NMI_OTHERS
    call lapic_send_ipi
    pop rsi
    pop rdi
.out:
    ret

; telemetry_sample_all: every CPU reads its own frequency and temperature
telemetry_sample_all:
    cmp byte [smp_ready], 0
    je .bsp_only
    lea rdi, [telemetry_job]
    xor esi, esi
    jmp job_run_each
.bsp_only:
    jmp cpu_sample_local

telemetry_job:
    jmp cpu_sample_local

; -----------------------------------------------------------------------------
;  The AP trampoline. Copied below 1 MiB; the BSP patches the physical
;  addresses of tramp_gdt, tramp_pm32 and tramp_lm64 before any AP runs it.
; -----------------------------------------------------------------------------
align 16
tramp_start:
bits 16
    cli
    cld
    mov ax, cs
    mov ds, ax
    xor ebx, ebx
    mov bx, ax
    shl ebx, 4                          ; EBX = where we are
    o32 lgdt [tramp_gdtr - tramp_start]
    mov eax, cr0
    or al, 1                            ; protected mode
    mov cr0, eax
    jmp far dword [tramp_far32 - tramp_start]
bits 32
tramp_pm32:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov eax, cr4
    or eax, 1 << 5                      ; PAE
    mov cr4, eax
    mov eax, [ebx + (tramp_cr3 - tramp_start)]
    mov cr3, eax
    mov ecx, MSR_EFER
    rdmsr
    or eax, 1 << 8                      ; long mode enable
    wrmsr
    mov eax, cr0
    or eax, 0x80000000                  ; paging on: long mode, compatibility
    mov cr0, eax
    jmp far dword [ebx + (tramp_far64 - tramp_start)]
bits 64
tramp_lm64:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax
    mov ebx, ebx
    mov rax, [rbx + (tramp_entry - tramp_start)]
    jmp rax
align 8
tramp_gdt:
    dq 0
    dq 0x00AF9A000000FFFF               ; 0x08 64-bit code
    dq 0x00CF92000000FFFF               ; 0x10 data
    dq 0x00CF9A000000FFFF               ; 0x18 32-bit code
tramp_gdtr:
    dw 4 * 8 - 1
    dd 0                                ; physical address of tramp_gdt
tramp_far32:
    dd 0                                ; physical address of tramp_pm32
    dw 0x18
tramp_far64:
    dd 0                                ; physical address of tramp_lm64
    dw 0x08
align 8
tramp_cr3:      dq 0
tramp_entry:    dq 0
tramp_end:

section .rodata
str_smp_oom:    db 'Out of memory for per-CPU stacks', 0

section .data
smp_ready:      db 0
job_each:       db 0

section .bss
alignb 64
job_gen:        resq 1                  ; bumped for every job
job_fn:         resq 1
job_arg:        resq 1
job_count:      resq 1
job_t0:         resq 1
job_cycles:     resq 1                  ; wall time of the last job, TSC ticks
alignb 64
job_next:       resq 1                  ; next item, on its own cache line
alignb 64
job_checkins:   resd 1
job_cpus:       resd 1
cpus_online:    resd 1
alignb 8
tramp_phys:     resq 1
smp_t0:         resq 1
smp_us:         resq 1                  ; bring-up time
count_p:        resq 1                  ; physical cores by kind
count_e:        resq 1
count_other:    resq 1
cpu_order:      resd MAX_CPUS           ; display order
