; =============================================================================
;  memtest.asm - the 'mem' command (what memory holds, what an address is, a
;  self-test of the heap and the vm region) and 'panic', which can also make
;  each kind of memory fault on purpose, to see it caught and named
; =============================================================================

MT_SLOTS        equ 512                 ; live objects in the one-CPU test
MT_OPS          equ 40000
MT_CPU_SLOTS    equ 64                  ; per CPU, in the all-CPU test
MT_CPU_OPS      equ 4000
MT_TIMED        equ 100000              ; kmalloc(64) + kfree pairs, timed
MT_VM_TIMED     equ 1000                ; vm_alloc(16 KiB) + vm_free pairs

section .text

; -----------------------------------------------------------------------------
;  mem [test | <hex address>]
; -----------------------------------------------------------------------------
cmd_mem:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je mem_report
    lea rdi, [str_mt_test]
    call streq
    test eax, eax
    jnz mem_test
    call arg_hex
    jc .usage
    jmp mem_where
.usage:
    KLOG "usage: mem [test | <hex address>]"
    ret

mem_report:
    push rbx
    xor ebx, ebx
.next:
    lea rax, [mem_by_type]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .skip
    lea rax, [mem_type_names]
    mov rax, [rax + rbx * 8]
    KLOG "  %-14s %b", rax, rcx
.skip:
    inc ebx
    cmp ebx, 16
    jb .next
    mov rax, [pmm_free_pages]
    shl rax, 12
    KLOG "  usable %b, free %b, bitmap at %p", qword [pmm_usable_bytes], rax, qword [pmm_bitmap_phys]
    KLOG "  page tables at %p; the firmware's at %p, the only ones with an identity map", qword [vmm_cr3], qword [fw_cr3]
    lea rax, [kernel_rodata]
    mov rcx, KERNEL_BASE
    sub rax, rcx
    lea rdx, [kernel_data]
    lea rcx, [kernel_rodata]
    sub rdx, rcx
    lea r8, [kernel_end]
    lea rcx, [kernel_data]
    sub r8, rcx
    KLOG "  kernel at %p: code %b, read-only; constants %b and data %b, not executable", qword [kernel_phys], rax, rdx, r8
    mov rax, [vm_pages]
    shl rax, 12
    KLOG "  vm: %u mappings, %b, in %u of %u slots; %u TLB shootdowns", qword [vm_count], rax, qword [vm_slots_used], VM_SLOTS, qword [tlb_count]
    KLOG "  heap: %u objects, %b, in %u slabs; %u large, %b", qword [heap_objects], qword [heap_bytes], qword [heap_slabs], qword [heap_big], qword [heap_big_bytes]
    pop rbx
    ret

; mem_where(RAX = address): what is there and how it is mapped
mem_where:
    push rbx
    push r12
    mov rbx, rax
    lea rdi, [mt_text]
    mov rsi, rbx
    call vmm_where
    mov rdi, rbx
    call vmm_lookup
    jc .unmapped
    mov r12, rax                        ; the entry
    mov rdi, rbx
    call vmm_translate
    mov r8, rax
    lea r9, [str_mt_ro]
    test r12d, PTE_W
    jz .w
    lea r9, [str_mt_rw]
.w:
    lea r10, [str_mt_x]
    bt r12, 63
    jnc .x
    lea r10, [str_mt_nx]
.x:
    mov eax, r12d                       ; memory type: PAT, PCD, PWT
    shr eax, 3
    and eax, 3
    mov ecx, 7                          ; the PAT bit: 7 in a PTE, 12 above
    cmp rdx, 4096
    je .pat
    mov ecx, 12
.pat:
    bt r12, rcx
    jnc .type
    or eax, 4
.type:
    lea rcx, [mt_types]
    mov r11, [rcx + rax * 8]
    lea rax, [mt_text]
    KLOG "  %p: %s", rbx, rax
    KLOG "    physical %p, %s, %s, %s, in a %b page", r8, r9, r10, r11, rdx
    jmp .out
.unmapped:
    lea rax, [mt_text]
    KLOG "  %p: %s; nothing is mapped there", rbx, rax
.out:
    pop r12
    pop rbx
    ret

; arg_hex(RSI = text) -> RAX = its value, hex with or without 0x; CF if it
; is not one. Preserves others.
arg_hex:
    push rcx
    push rdx
    push rsi
    cmp word [rsi], '0x'
    jne .start
    add rsi, 2
.start:
    xor eax, eax
    xor edx, edx                        ; digits
.digit:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .end
    or ecx, 0x20                        ; lower case
    sub ecx, '0'
    cmp ecx, 9
    jbe .add
    sub ecx, 'a' - '0'
    cmp ecx, 5
    ja .bad
    add ecx, 10
.add:
    shl rax, 4
    or rax, rcx
    inc rsi
    inc edx
    cmp edx, 16
    ja .bad
    jmp .digit
.end:
    test edx, edx
    jz .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  mem test: random kmalloc and kfree on this CPU, then on all of them at
;  once (large objects too, so vm_free shoots TLBs down from every CPU), each
;  object checked: aligned, zeroed, and its pattern intact when it is freed.
;  Then timings.
; -----------------------------------------------------------------------------
mem_test:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, [heap_objects]             ; what the heap holds before
    mov r13, [heap_big]
    mov r14, [vm_count]
    mov r15, [tlb_count]
    mov edi, MT_SLOTS * 16
    call kmalloc
    test rax, rax
    jz .no_memory
    mov rbx, rax
    RDTSC64
    mov rcx, rax
    mov rdi, rbx
    mov esi, MT_SLOTS
    mov edx, MT_OPS
    mov r8d, 1 << 20                    ; up to 1 MiB
    call mt_run
    mov [mt_fail], rax
    mov rdi, rbx
    call kfree
    mov rax, [mt_fail]
    KLOG "mem test: %u operations on one CPU, %u failed", MT_OPS, rax

    mov dword [mt_cpu_fail], 0
    lea rdi, [mt_job]
    xor esi, esi
    call job_run_each
    mov eax, [mt_cpu_fail]
    add [mt_fail], rax
    mov ecx, [cpus_online]
    mov rdx, [tlb_count]
    sub rdx, r15
    KLOG "mem test: %u operations on each of %u CPUs, %u failed; %u TLB shootdowns", MT_CPU_OPS, rcx, rax, rdx

    call vmm_audit                      ; W^X, everywhere
    mov r8, rax
    mov r10, rdx
    mov rdi, [kernel_phys]              ; the direct map's view of our code
    add rdi, [phys_base]
    call vmm_lookup
    mov r9d, 1
    jc .alias
    and eax, PTE_W
    mov r9d, eax
.alias:
    lea rax, [str_mt_ro]
    test r9d, r9d
    jz .alias_said
    lea rax, [str_mt_rw]
.alias_said:
    KLOG "mem test: %u page table entries, %u both writable and executable; the direct map's view of kernel code is %s", r10, r8, rax
    add r8, r9
    add [mt_fail], r8

    mov rax, [heap_objects]             ; all of it given back?
    cmp rax, r12
    jne .leak
    mov rax, [heap_big]
    cmp rax, r13
    jne .leak
    mov rax, [vm_count]
    cmp rax, r14
    jne .leak
    jmp .timed
.leak:
    inc qword [mt_fail]
    KLOG "mem test: not all of it came back: %u objects (was %u), %u large (was %u), %u vm mappings (was %u)", qword [heap_objects], r12, qword [heap_big], r13, qword [vm_count], r14

.timed:
    RDTSC64
    mov r12, rax
    mov ebx, MT_TIMED
.pair:
    mov edi, 64
    call kmalloc
    mov rdi, rax
    call kfree
    dec ebx
    jnz .pair
    RDTSC64
    sub rax, r12
    mov rcx, [tsc_per_us]
    imul rcx, rcx, MT_TIMED / 10000
    xor edx, edx
    div rcx                             ; tenths of a ns, per pair
    mov r12, rax
    RDTSC64
    mov r13, rax
    mov ebx, MT_VM_TIMED
.vm_pair:
    mov edi, 16384
    call vm_alloc
    mov rdi, rax
    call vm_free
    dec ebx
    jnz .vm_pair
    RDTSC64
    sub rax, r13
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_per_us]
    xor edx, edx
    mov ecx, MT_VM_TIMED
    div rcx                             ; tenths of a us, per pair
    KLOG "mem test: kmalloc(64) + kfree %t ns; vm_alloc(16 KiB) + vm_free %t us, with its shootdown", r12, rax
    cmp qword [mt_fail], 0
    jne .failed
    KLOG "mem test: passed"
    jmp .out
.failed:
    KLOG "mem test: FAILED"
    jmp .out
.no_memory:
    KLOG "mem test: no memory for the test"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; mt_job(RDI = CPU index): this CPU's share of the all-CPU test
mt_job:
    push rbx
    push r12
    mov r12, rdi
    mov edi, MT_CPU_SLOTS * 16
    call kmalloc
    test rax, rax
    jz .no_memory
    mov rbx, rax
    RDTSC64
    mov rcx, r12
    shl rcx, 40
    xor rcx, rax
    mov rdi, rbx
    mov esi, MT_CPU_SLOTS
    mov edx, MT_CPU_OPS
    mov r8d, 65536
    call mt_run
    lock add [mt_cpu_fail], eax
    mov rdi, rbx
    call kfree
    jmp .out
.no_memory:
    lock inc dword [mt_cpu_fail]
.out:
    pop r12
    pop rbx
    ret

; mt_run(RDI = a table of RSI slots of { qword object, dword size, dword tag },
; zeroed; RDX = operations; RCX = seed; R8 = largest size) -> RAX = failures.
; Each operation picks a slot: frees what is there, after checking it, or
; puts a new object there. All are freed at the end; the table stays zeroed.
mt_run:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    or r15, 1
    mov rbp, r8
    xor ebx, ebx
.op:
    test r14, r14
    jz .drain
    dec r14
    call .rand
    xor edx, edx
    div r13
    shl rdx, 4
    lea rsi, [r12 + rdx]
    cmp qword [rsi], 0
    je .alloc
    call .free
    jmp .op
.alloc:
    call .rand                          ; mostly small, some up to 16 KiB,
    movzx ecx, al                       ; a few up to the largest
    shr rax, 8
    xor edx, edx
    mov edi, 1024
    cmp ecx, 200
    jb .size
    mov edi, 16384
    cmp ecx, 250
    jb .size
    mov rdi, rbp
.size:
    div rdi
    lea rdi, [rdx + 1]
    mov [rsi + 8], edi
    call .rand
    mov [rsi + 12], eax
    call kmalloc
    test rax, rax
    jz .failed_alloc
    mov [rsi], rax
    test al, 15
    jz .aligned
    inc rbx
.aligned:
    mov rdi, rax                        ; zeroed?
    mov ecx, [rsi + 8]
    push rax
    xor eax, eax
    repe scasb
    pop rax
    je .zeroed
    inc rbx
.zeroed:
    mov ecx, [rsi + 8]                  ; then our pattern
    mov edx, [rsi + 12]
    xor edi, edi
.fill:
    lea r8d, [rdx + rdi]
    mov [rax + rdi], r8b
    inc edi
    cmp edi, ecx
    jb .fill
    jmp .op
.failed_alloc:
    inc rbx
    mov qword [rsi + 8], 0
    jmp .op
.drain:
    xor ecx, ecx
.drain_slot:
    cmp rcx, r13
    jae .done
    mov rsi, rcx
    shl rsi, 4
    add rsi, r12
    cmp qword [rsi], 0
    je .drain_next
    push rcx
    call .free
    pop rcx
.drain_next:
    inc rcx
    jmp .drain_slot
.done:
    mov rax, rbx
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

.free:                                  ; RSI = slot: check, free, clear
    mov rdi, [rsi]
    mov ecx, [rsi + 8]
    mov edx, [rsi + 12]
    xor eax, eax
.check:
    lea r8d, [rdx + rax]
    cmp [rdi + rax], r8b
    jne .broken
    inc eax
    cmp eax, ecx
    jb .check
    jmp .intact
.broken:
    inc rbx
.intact:
    call kfree
    mov qword [rsi], 0
    mov qword [rsi + 8], 0
    ret

.rand:                                  ; xorshift64 in R15 -> RAX
    mov rax, r15
    shl rax, 13
    xor r15, rax
    mov rax, r15
    shr rax, 7
    xor r15, rax
    mov rax, r15
    shl rax, 17
    xor r15, rax
    mov rax, r15
    ret

; -----------------------------------------------------------------------------
;  panic [null|code|const|nx|stack|guard|twice|after|page|vm]: the crash
;  screen, from an invalid opcode, or from the memory fault named
; -----------------------------------------------------------------------------
cmd_panic:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .opcode
    lea rbx, [mt_faults]
.find:
    mov rdi, [rbx]
    test rdi, rdi
    jz .usage
    call streq
    test eax, eax
    jnz .found
    add rbx, 16
    jmp .find
.found:
    KLOG "testing the panic screen: %s", rsi
    jmp [rbx + 8]
.usage:
    KLOG "usage: panic [null|code|const|nx|stack|guard|twice|after|page|vm]"
    ret
.opcode:
    KLOG "testing the panic screen"
    ud2

mt_null:
    xor eax, eax
    mov rax, [rax + 8]
    ret

mt_code:
    lea rax, [cmd_panic]
    mov byte [rax], 0xCC
    ret

mt_const:
    lea rax, [str_mt_test]
    mov byte [rax], 0
    ret

mt_nx:
    lea rax, [mt_ret]
    call rax
    ret

mt_stack:
    push rax
    call mt_stack
    ret

mt_guard:
    mov edi, 4096
    call vm_alloc
    mov byte [rax + 4096], 1            ; one past the end
    ret

mt_twice:
    mov edi, 48
    call kmalloc
    mov rdi, rax
    call kfree
    call kfree
    ret

mt_after:
    mov edi, 1000                       ; a class nothing else uses yet
    call kmalloc
    mov rdi, rax
    call kfree
    mov byte [rdi + 100], 1
    mov edi, 1000                       ; the same object again
    call kmalloc
    ret

mt_page:
    mov edi, 1
    call pmm_alloc
    mov rdi, rax
    mov esi, 1
    call pmm_free
    call pmm_free
    ret

mt_vm:
    mov edi, 8192
    call vm_alloc
    lea rdi, [rax + 4096]               ; its second page
    call vm_free
    ret

section .rodata
str_mt_test:    db 'test', 0
str_mt_rw:      db 'writable', 0
str_mt_ro:      db 'read-only', 0
str_mt_x:       db 'executable', 0
str_mt_nx:      db 'not executable', 0
str_mt_wb:      db 'write-back', 0
str_mt_wt:      db 'write-through', 0
str_mt_ucm:     db 'uncached (UC-)', 0
str_mt_uc:      db 'uncached', 0
str_mt_wc:      db 'write-combining', 0
str_mt_wp:      db 'write-protect', 0
align 8
mt_types:                               ; by PAT entry, as cpu_setup_local sets it
    dq str_mt_wb, str_mt_wt, str_mt_ucm, str_mt_uc
    dq str_mt_wc, str_mt_wp, str_mt_ucm, str_mt_uc

%macro MT_FAULT 2
    dq %%name, %2
    [section .rodata]
    %%name: db %1, 0
    __SECT__
%endmacro

section .data
align 8
mt_faults:
    MT_FAULT 'null',  mt_null
    MT_FAULT 'code',  mt_code
    MT_FAULT 'const', mt_const
    MT_FAULT 'nx',    mt_nx
    MT_FAULT 'stack', mt_stack
    MT_FAULT 'guard', mt_guard
    MT_FAULT 'twice', mt_twice
    MT_FAULT 'after', mt_after
    MT_FAULT 'page',  mt_page
    MT_FAULT 'vm',    mt_vm
    dq 0, 0

mt_ret:         db 0xC3                 ; a 'ret', in memory that is not code

section .bss
alignb 8
mt_fail:        resq 1
mt_cpu_fail:    resd 1
mt_text:        resb 256
