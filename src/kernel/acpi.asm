; =============================================================================
;  acpi.asm - read the firmware's ACPI tables: CPUs, interrupt controllers,
;  PCIe configuration space, reset register. No AML interpreter (yet).
; =============================================================================

MAX_IOAPICS     equ 8
MAX_OVERRIDES   equ 24
MAX_ECAM        equ 8
MAX_ACPI_TABLES equ 48

section .text

acpi_init:
    push rbx
    push r12
    push r13
    push r14
    mov rax, [boot_info]
    mov rsi, [rax + BI_RSDP]
    test rsi, rsi
    jz .none
    add rsi, [phys_base]
    mov rax, 'RSD PTR '
    cmp [rsi], rax
    jne .none
    movzx eax, byte [rsi + 15]
    mov [acpi_revision], eax
    cmp eax, 2
    jb .use_rsdt
    mov r12, [rsi + 24]                 ; XSDT: 64-bit pointers
    test r12, r12
    jz .use_rsdt
    mov r14d, 8
    jmp .walk
.use_rsdt:
    mov r12d, [rsi + 16]                ; RSDT: 32-bit pointers
    mov r14d, 4
.walk:
    add r12, [phys_base]
    mov ecx, [r12 + 4]                  ; length
    lea r13, [r12 + rcx]                ; end
    add r12, 36                         ; first entry
.entry:
    cmp r12, r13
    jae .walked
    mov rbx, [r12]
    cmp r14d, 8
    je .have_ptr
    mov ebx, ebx
.have_ptr:
    add r12, r14
    test rbx, rbx
    jz .entry
    add rbx, [phys_base]
    mov eax, [rbx]                      ; signature
    mov ecx, [acpi_table_count]         ; remember it for 'acpi'
    cmp ecx, MAX_ACPI_TABLES
    jae .classify
    lea rdx, [acpi_table_sigs]
    mov [rdx + rcx * 4], eax
    lea rdx, [acpi_table_ptrs]
    mov [rdx + rcx * 8], rbx
    inc dword [acpi_table_count]
.classify:
    cmp eax, 'APIC'
    jne .not_madt
    mov rsi, rbx
    call acpi_parse_madt
    jmp .entry
.not_madt:
    cmp eax, 'FACP'
    jne .not_fadt
    mov rsi, rbx
    call acpi_parse_fadt
    jmp .entry
.not_fadt:
    cmp eax, 'MCFG'
    jne .not_mcfg
    mov rsi, rbx
    call acpi_parse_mcfg
    jmp .entry
.not_mcfg:
    cmp eax, 'HPET'
    jne .entry
    mov rax, [rbx + 44]
    mov [hpet_phys], rax
    jmp .entry
.walked:
    mov byte [acpi_ok], 1
.none:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; acpi_parse_madt(RSI = MADT)
acpi_parse_madt:
    push rbx
    push r12
    mov eax, [rsi + 36]
    mov [lapic_phys], rax
    mov ecx, [rsi + 4]
    lea r12, [rsi + rcx]                ; end
    lea rbx, [rsi + 44]
.next:
    lea rax, [rbx + 2]
    cmp rax, r12
    ja .done
    movzx eax, byte [rbx]               ; type
    movzx ecx, byte [rbx + 1]           ; length
    cmp ecx, 2
    jb .done
    cmp eax, 0
    je .lapic
    cmp eax, 9
    je .x2apic
    cmp eax, 1
    je .ioapic
    cmp eax, 2
    je .override
    cmp eax, 5
    je .lapic_address
.advance:
    movzx ecx, byte [rbx + 1]
    add rbx, rcx
    jmp .next
.lapic:
    test byte [rbx + 4], 1              ; enabled
    jz .advance
    movzx eax, byte [rbx + 3]
    call acpi_add_cpu
    jmp .advance
.x2apic:
    test byte [rbx + 8], 1
    jz .advance
    mov eax, [rbx + 4]
    cmp eax, 0xFFFFFFFF
    je .advance
    call acpi_add_cpu
    jmp .advance
.ioapic:
    mov ecx, [ioapic_count]
    cmp ecx, MAX_IOAPICS
    jae .advance
    mov eax, [rbx + 4]
    lea rdx, [ioapic_phys]
    mov [rdx + rcx * 8], rax
    mov eax, [rbx + 8]
    lea rdx, [ioapic_gsi_base]
    mov [rdx + rcx * 4], eax
    inc dword [ioapic_count]
    jmp .advance
.override:
    mov ecx, [override_count]
    cmp ecx, MAX_OVERRIDES
    jae .advance
    movzx eax, byte [rbx + 3]           ; ISA IRQ
    lea rdx, [override_irq]
    mov [rdx + rcx], al
    mov eax, [rbx + 4]                  ; GSI
    lea rdx, [override_gsi]
    mov [rdx + rcx * 4], eax
    movzx eax, word [rbx + 8]           ; polarity / trigger flags
    lea rdx, [override_flags]
    mov [rdx + rcx * 2], ax
    inc dword [override_count]
    jmp .advance
.lapic_address:
    mov rax, [rbx + 4]
    mov [lapic_phys], rax
    jmp .advance
.done:
    pop r12
    pop rbx
    ret

; acpi_add_cpu(EAX = APIC id): append unless already listed
acpi_add_cpu:
    push rcx
    push rdx
    lea rdx, [cpu_apic_ids]
    xor ecx, ecx
.check:
    cmp ecx, [cpu_count]
    jae .append
    cmp [rdx + rcx * 4], eax
    je .out
    inc ecx
    jmp .check
.append:
    cmp ecx, MAX_CPUS
    jae .out
    mov [rdx + rcx * 4], eax
    inc dword [cpu_count]
.out:
    pop rdx
    pop rcx
    ret

; acpi_parse_fadt(RSI = FADT)
acpi_parse_fadt:
    mov [fadt_ptr], rsi
    mov eax, [rsi + 4]
    cmp eax, 116
    jb .done
    mov eax, [rsi + 112]
    mov [fadt_flags], eax
    movzx eax, word [rsi + 109]
    mov [fadt_boot_arch], eax
    cmp dword [rsi + 4], 129
    jb .done
    test dword [fadt_flags], 1 << 10    ; RESET_REG_SUP
    jz .done
    movzx eax, byte [rsi + 116]         ; address space
    mov [reset_space], eax
    mov rax, [rsi + 120]
    mov [reset_addr], rax
    movzx eax, byte [rsi + 128]
    mov [reset_value], eax
    mov byte [reset_ok], 1
.done:
    ret

; acpi_parse_mcfg(RSI = MCFG)
acpi_parse_mcfg:
    mov ecx, [rsi + 4]
    lea rdx, [rsi + rcx]
    lea rsi, [rsi + 44]
.next:
    lea rax, [rsi + 16]
    cmp rax, rdx
    ja .done
    mov ecx, [ecam_count]
    cmp ecx, MAX_ECAM
    jae .done
    mov rax, [rsi]
    lea rdi, [ecam_base]
    mov [rdi + rcx * 8], rax
    movzx eax, word [rsi + 8]
    lea rdi, [ecam_segment]
    mov [rdi + rcx * 2], ax
    movzx eax, byte [rsi + 10]
    lea rdi, [ecam_bus_start]
    mov [rdi + rcx], al
    movzx eax, byte [rsi + 11]
    lea rdi, [ecam_bus_end]
    mov [rdi + rcx], al
    inc dword [ecam_count]
    add rsi, 16
    jmp .next
.done:
    ret

section .data
acpi_ok:        db 0
reset_ok:       db 0

section .bss
alignb 8
lapic_phys:     resq 1
hpet_phys:      resq 1
fadt_ptr:       resq 1
reset_addr:     resq 1
reset_space:    resd 1
reset_value:    resd 1
fadt_flags:     resd 1
fadt_boot_arch: resd 1
acpi_revision:  resd 1
acpi_table_count: resd 1
cpu_count:      resd 1
ioapic_count:   resd 1
override_count: resd 1
ecam_count:     resd 1
alignb 8
acpi_table_ptrs: resq MAX_ACPI_TABLES
acpi_table_sigs: resd MAX_ACPI_TABLES
cpu_apic_ids:   resd MAX_CPUS
ioapic_phys:    resq MAX_IOAPICS
ioapic_gsi_base: resd MAX_IOAPICS
ioapic_max_entry: resd MAX_IOAPICS
override_gsi:   resd MAX_OVERRIDES
override_flags: resw MAX_OVERRIDES
override_irq:   resb MAX_OVERRIDES
alignb 8
ecam_base:      resq MAX_ECAM
ecam_segment:   resw MAX_ECAM
ecam_bus_start: resb MAX_ECAM
ecam_bus_end:   resb MAX_ECAM
