; =============================================================================
;  iommutest.asm - 'iommu': each VT-d unit, each domain and the last faults.
;  'iommu test': the NVMe controller told to read into a page its domain
;  does not hold, refused and the page untouched; the page mapped, read; the
;  page unmapped again, refused again (so the IOTLB forgot it).
; =============================================================================

section .text

cmd_iommu:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je iommu_list
    call arg_split
    lea rdi, [str_ob_test]
    call streq
    test eax, eax
    jnz iommu_test
    KLOG "usage: iommu [test]"
    ret

; -----------------------------------------------------------------------------
;  iommu: units, domains, faults
; -----------------------------------------------------------------------------
iommu_list:
    push rbx
    push r12
    push r13
    call iommu_faults                   ; whatever came in meanwhile
    cmp byte [iommu_on], 0
    jne .on
    KLOG "iommu: off: no VT-d unit found, so DMA is not confined"
    jmp .out
.on:
    mov eax, [iommu_count]
    mov ecx, [iommu_levels]
    mov edx, [domain_count]
    KLOG "iommu: %u unit(s), %u-level tables, %u domain(s), %u fault(s) so far", rax, rcx, rdx, qword [iommu_fault_count]
    xor r12d, r12d
.unit:
    cmp r12d, [iommu_count]
    jae .domains
    imul rbx, r12, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    mov eax, [rbx + IU_VER]
    mov ecx, eax
    shr eax, 4
    and eax, 0xF
    and ecx, 0xF
    lea rdx, [str_it_snoops]
    test dword [rbx + IU_FLAGS], IUF_COHERENT
    jnz .coherent
    lea rdx, [str_it_flushed]
.coherent:
    lea rsi, [str_it_listed]
    test dword [rbx + IU_FLAGS], IUF_ALL
    jz .scope
    lea rsi, [str_it_all]
.scope:
    lea rdi, [str_it_on]
    test dword [rbx + IU_FLAGS], IUF_ON
    jnz .state
    lea rdi, [str_it_off]
.state:
    KLOG "  unit %u at %p: VT-d %u.%u, %s, %s, %s; %u device(s), %u fault(s)", r12, qword [rbx + IU_PHYS], rax, rcx, rdi, rdx, rsi, qword [rbx + IU_DEVICES], qword [rbx + IU_FAULTS]
    inc r12d
    jmp .unit
.domains:
    KLOG "  domain    devices  pages  tables      maps    unmaps"
    xor r12d, r12d
.domain:
    cmp r12d, [domain_count]
    jae .faults
    imul rbx, r12, DM_SIZE
    lea rax, [iommu_domains]
    add rbx, rax
    mov eax, [rbx + DM_DEVICES]
    KLOG "  %-8s  %7u  %5u  %6u  %8u  %8u", qword [rbx + DM_NAME], rax, qword [rbx + DM_PAGES], qword [rbx + DM_TABLES], qword [rbx + DM_MAPS], qword [rbx + DM_UNMAPS]
    inc r12d
    jmp .domain
.faults:
    mov r13, [iommu_fault_count]        ; the last ones, oldest first
    cmp r13, IOMMU_LOG
    jbe .from
    mov r13d, IOMMU_LOG
.from:
    mov r12d, [iommu_fault_next]
    sub r12d, r13d
.fault:
    test r13d, r13d
    jz .out
    mov eax, r12d
    and eax, IOMMU_LOG - 1
    shl eax, 4
    lea rbx, [iommu_fault_log]
    add rbx, rax
    lea rdi, [str_it_fault]
    call iommu_fault_say
    inc r12d
    dec r13d
    jmp .fault
.out:
    mov rax, [iommu_fault_count]        ; said, all of them
    mov [iommu_fault_said], rax
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  iommu test, with the first NVMe controller
; -----------------------------------------------------------------------------
iommu_test:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov byte [it_fails], 0
    xor r13d, r13d
    xor ebx, ebx
    cmp byte [iommu_on], 0
    jne .on
    KLOG "iommu test: no VT-d unit is translating"
    call it_fail
    jmp .verdict
.on:
    cmp dword [nvme_count], 0
    je .no_nvme
    cmp qword [nvme_domain], 0
    jne .nvme
.no_nvme:
    KLOG "iommu test: no NVMe controller to test with"
    call it_fail
    jmp .verdict
.nvme:
    lea r15, [nvme_ctrl]
    call iommu_faults
    mov rax, [iommu_fault_count]
    mov [it_faults_before], rax
    mov ecx, [r15 + NV_SHIFT]           ; R14D = blocks in a page
    mov r14d, 4096
    shr r14d, cl
    mov edi, 4096                       ; R13 = what the first page of the drive says
    call vm_alloc
    test rax, rax
    jz .oom
    mov r13, rax
    mov edi, 0x02
    xor esi, esi
    mov edx, r14d
    mov r8, r13
    call nvme_io
    jnc .page
    KLOG "iommu test: an ordinary read failed"
    call it_fail
    jmp .free
.page:
    mov edi, 1                          ; RBX = a page no domain holds, RBP mapped
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    mov rbx, rax
    lea rbp, [rax]
    add rbp, [phys_base]

    lea rsi, [str_it_outside]           ; 1. not in the NVMe domain
    call it_refused
    mov rdi, [nvme_domain]              ; 2. mapped into it
    mov rsi, rbx
    mov edx, 4096
    mov ecx, VT_RW
    call iommu_map
    mov rdi, rbp
    mov al, 0x5A
    mov ecx, 4096
    rep stosb
    mov edi, 0x02
    xor esi, esi
    mov edx, r14d
    mov r8, rbp
    call nvme_io_raw
    jc .mapped_failed
    mov rsi, r13
    mov rdi, rbp
    mov ecx, 4096
    repe cmpsb
    jne .mapped_wrong
    KLOG "iommu test: the page mapped into the NVMe domain: read into, as the drive says"
    jmp .unmap
.mapped_failed:
    KLOG "iommu test: the page mapped into the NVMe domain: the read failed (status %x)", rax
    call it_fail
    jmp .unmap
.mapped_wrong:
    KLOG "iommu test: the page mapped into the NVMe domain: read, but not what the drive says"
    call it_fail
.unmap:
    mov rdi, [nvme_domain]              ; 3. out of it again
    mov rsi, rbx
    mov edx, 4096
    call iommu_unmap
    lea rsi, [str_it_again]
    call it_refused

    call iommu_faults                   ; 4. faults for those two alone
    mov rax, [iommu_fault_count]
    sub rax, [it_faults_before]
    KLOG "iommu test: %u fault(s) recorded meanwhile, for the two reads refused", rax
    cmp rax, 2
    jae .devices
    call it_fail
.devices:
    mov rax, [nvme_domain]              ; 5. every driven device in its domain
    mov eax, [rax + DM_DEVICES]
    mov ecx, [nvme_count]
    KLOG "iommu test: the NVMe domain holds %u device(s), for %u controller(s)", rax, rcx
    cmp eax, ecx
    je .usb
    call it_fail
.usb:
    mov rax, [usb_domain]
    test rax, rax
    jz .free
    mov eax, [rax + DM_DEVICES]
    mov ecx, [xhci_count]
    KLOG "iommu test: the USB domain holds %u device(s), for %u controller(s)", rax, rcx
    cmp eax, ecx
    je .free
    call it_fail
    jmp .free
.oom:
    KLOG "iommu test: out of memory"
    call it_fail
.free:
    test rbx, rbx
    jz .no_page
    mov rdi, rbx
    mov esi, 1
    call pmm_free
.no_page:
    test r13, r13
    jz .verdict
    mov rdi, r13
    call vm_free
.verdict:
    mov rax, [iommu_fault_count]        ; its own faults, said already
    mov [iommu_fault_said], rax
    cmp byte [it_fails], 0
    jne .failed
    KLOG "iommu test: passed"
    jmp .out
.failed:
    KLOG "iommu test: FAILED"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; it_refused(RBX = the page, physical; RBP = mapped; R14D = blocks in it;
; R15 = controller; RSI = what this step is): the controller told to read
; into it, which it may not reach: a fault must name the controller writing
; that page, and the page must be as it was. (The command may fail or not:
; QEMU's controller says it went well, a drive may say otherwise.)
it_refused:
    push r12
    push r13
    mov r12, rsi
    call iommu_faults
    mov r13, [iommu_fault_count]
    mov rdi, rbp
    mov al, 0x5A
    mov ecx, 4096
    rep stosb
    mov edi, 0x02
    xor esi, esi
    mov edx, r14d
    mov r8, rbp
    call nvme_io_raw
    mov [it_status], rax
    mov ecx, 100                        ; the fault, within 100 ms
.wait:
    call iommu_faults
    cmp [iommu_fault_count], r13
    ja .faulted
    push rcx
    mov edi, 1000
    call thread_sleep_us
    pop rcx
    dec ecx
    jnz .wait
    KLOG "iommu test: %s: no fault was recorded (status %x)", r12, qword [it_status]
    call it_fail
    jmp .out
.faulted:
    mov eax, [iommu_fault_next]         ; the newest
    dec eax
    and eax, IOMMU_LOG - 1
    shl eax, 4
    lea rdx, [iommu_fault_log]
    add rdx, rax
    movzx eax, word [rdx + FL_SID]
    cmp eax, [r15 + NV_BDF]
    jne .whose
    cmp [rdx + FL_ADDR], rbx
    jne .whose
    cmp byte [rdx + FL_READ], 0
    jne .whose
    mov rdi, rbp                        ; untouched?
    mov al, 0x5A
    mov ecx, 4096
    repe scasb
    jne .touched
    KLOG "iommu test: %s: stopped, a fault from the controller writing %p, the page untouched (status %x)", r12, rbx, qword [it_status]
    jmp .out
.whose:
    push rbx
    mov rbx, rdx
    KLOG "iommu test: %s: a fault, but not the one expected:", r12
    lea rdi, [str_it_fault]
    call iommu_fault_say
    pop rbx
    call it_fail
    jmp .out
.touched:
    KLOG "iommu test: %s: a fault recorded, but the page changed", r12
    call it_fail
.out:
    pop r13
    pop r12
    ret

it_fail:
    mov byte [it_fails], 1
    ret

section .rodata
str_it_snoops:  db 'snooping the caches', 0
str_it_flushed: db 'its tables flushed to memory by hand', 0
str_it_all:     db 'for every device no other unit lists', 0
str_it_listed:  db 'for the devices it lists', 0
str_it_on:      db 'translating', 0
str_it_off:     db 'not translating', 0
str_it_fault:   db '  fault: ', 0
str_it_outside: db 'a read into a page outside the NVMe domain', 0
str_it_again:   db 'the page unmapped again', 0

section .bss
alignb 8
it_faults_before: resq 1
it_status:      resq 1
it_fails:       resb 1
