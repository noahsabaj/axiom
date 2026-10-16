; =============================================================================
;  apic.asm - local APIC (x2APIC when the CPU has it, xAPIC MMIO otherwise)
;  and the I/O APIC. The 8259 PIC is masked and never used.
; =============================================================================

LAPIC_ID        equ 0x020
LAPIC_TPR       equ 0x080
LAPIC_EOI       equ 0x0B0
LAPIC_SVR       equ 0x0F0
LAPIC_ESR       equ 0x280
LAPIC_ICR_LO    equ 0x300
LAPIC_ICR_HI    equ 0x310
LAPIC_LVT_TIMER equ 0x320
LAPIC_LVT_LINT0 equ 0x350
LAPIC_LVT_LINT1 equ 0x360
LAPIC_LVT_ERROR equ 0x370

ICR_FIXED       equ 0x00004000          ; level assert, fixed delivery
ICR_INIT        equ 0x00004500
ICR_STARTUP     equ 0x00004600
ICR_NMI_OTHERS  equ 0x000C4400          ; NMI to all excluding self

section .text

; lapic_init_bsp: choose the mode for the whole machine, enable on the BSP
lapic_init_bsp:
    mov ecx, 0x21                       ; mask both 8259 PICs
    mov al, 0xFF
    out 0x21, al
    out 0xA1, al
    mov ecx, MSR_APIC_BASE
    rdmsr
    test dword [cpu_f1_ecx], 1 << 21
    jz .xapic
    mov byte [lapic_x2], 1
    jmp lapic_enable_local
.xapic:
    and eax, 0xFFFFF000                 ; MMIO base
    shl rdx, 32
    or rax, rdx
    mov rcx, 0x000FFFFFFFFFF000
    and rax, rcx
    test rax, rax
    jnz .have_base
    mov rax, [lapic_phys]
.have_base:
    add rax, [phys_base]
    mov [lapic_mmio], rax
    ; fall through

; lapic_enable_local: enable this CPU's local APIC in the chosen mode. Preserves all.
lapic_enable_local:
    push rax
    push rcx
    push rdx
    mov ecx, MSR_APIC_BASE
    rdmsr
    or eax, 1 << 11                     ; global enable
    cmp byte [lapic_x2], 0
    je .write_base
    or eax, 1 << 10                     ; x2APIC mode
.write_base:
    wrmsr
    mov ecx, LAPIC_TPR
    xor eax, eax
    call lapic_write
    mov ecx, LAPIC_LVT_ERROR
    mov eax, 0x10000                    ; masked
    call lapic_write
    mov ecx, LAPIC_SVR
    mov eax, 0x100 | VEC_SPURIOUS       ; software enable
    call lapic_write
    pop rdx
    pop rcx
    pop rax
    ret

; lapic_read(ECX = register offset) -> EAX. Preserves others.
lapic_read:
    cmp byte [lapic_x2], 0
    je .mmio
    push rdx
    push rcx
    shr ecx, 4
    add ecx, 0x800
    rdmsr
    pop rcx
    pop rdx
    ret
.mmio:
    push rdx
    mov rdx, [lapic_mmio]
    mov eax, [rdx + rcx]
    pop rdx
    ret

; lapic_write(ECX = register offset, EAX = value). Preserves all.
lapic_write:
    cmp byte [lapic_x2], 0
    je .mmio
    push rcx
    push rdx
    shr ecx, 4
    add ecx, 0x800
    xor edx, edx
    wrmsr
    pop rdx
    pop rcx
    ret
.mmio:
    push rdx
    mov rdx, [lapic_mmio]
    mov [rdx + rcx], eax
    pop rdx
    ret

; lapic_eoi. Preserves all.
lapic_eoi:
    push rax
    push rcx
    mov ecx, LAPIC_EOI
    xor eax, eax
    call lapic_write
    pop rcx
    pop rax
    ret

; lapic_send_ipi(EDI = destination APIC id, ESI = ICR low dword). Preserves all.
lapic_send_ipi:
    push rax
    push rcx
    push rdx
    mfence                              ; prior stores visible before the IPI
    cmp byte [lapic_x2], 0
    je .mmio
    mov ecx, 0x830
    mov eax, esi
    mov edx, edi
    wrmsr
    jmp .out
.mmio:
    mov rdx, [lapic_mmio]
.busy1:
    test dword [rdx + LAPIC_ICR_LO], 1 << 12
    jz .send
    pause
    jmp .busy1
.send:
    mov eax, edi
    shl eax, 24
    mov [rdx + LAPIC_ICR_HI], eax
    mov [rdx + LAPIC_ICR_LO], esi
.busy2:
    test dword [rdx + LAPIC_ICR_LO], 1 << 12
    jz .out
    pause
    jmp .busy2
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; lapic_self_id -> EAX = this CPU's APIC id (CPUID, valid before the APIC is on)
lapic_self_id:
    push rbx
    push rcx
    push rdx
    mov eax, 1
    cpuid
    shr ebx, 24
    mov eax, ebx
    cmp dword [cpu_max_leaf], 0x0B
    jb .out
    mov eax, 0x0B
    xor ecx, ecx
    cpuid
    mov eax, edx
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  I/O APIC
; -----------------------------------------------------------------------------

; ioapic_init: mask every redirection entry on every I/O APIC
ioapic_init:
    push rbx
    push r12
    xor r12d, r12d
.chip:
    cmp r12d, [ioapic_count]
    jae .done
    lea rax, [ioapic_phys]
    mov rbx, [rax + r12 * 8]
    add rbx, [phys_base]
    mov dword [rbx], 1                  ; IOAPICVER
    mov eax, [rbx + 0x10]
    shr eax, 16
    and eax, 0xFF
    lea rcx, [ioapic_max_entry]
    mov [rcx + r12 * 4], eax
    xor ecx, ecx
.entry:
    cmp ecx, eax
    ja .chip_done
    lea edx, [ecx * 2 + 0x10]
    mov [rbx], edx
    mov dword [rbx + 0x10], 0x10000     ; masked
    inc edx
    mov [rbx], edx
    mov dword [rbx + 0x10], 0
    inc ecx
    jmp .entry
.chip_done:
    inc r12d
    jmp .chip
.done:
    pop r12
    pop rbx
    ret

; ioapic_route_isa(EDI = ISA IRQ, ESI = vector, EDX = destination APIC id)
ioapic_route_isa:
    push rbx
    push r12
    push r13
    mov r12d, edi                       ; GSI, identity unless overridden
    xor r13d, r13d                      ; flags: 0 = ISA default (high, edge)
    xor ecx, ecx
.override:
    cmp ecx, [override_count]
    jae .resolved
    lea rax, [override_irq]
    cmp [rax + rcx], dil
    jne .next_override
    lea rax, [override_gsi]
    mov r12d, [rax + rcx * 4]
    lea rax, [override_flags]
    movzx r13d, word [rax + rcx * 2]
    jmp .resolved
.next_override:
    inc ecx
    jmp .override
.resolved:
    mov eax, esi                        ; low dword: vector, physical destination
    mov ecx, r13d
    and ecx, 3
    cmp ecx, 3                          ; active low
    jne .polarity_done
    or eax, 1 << 13
.polarity_done:
    mov ecx, r13d
    shr ecx, 2
    and ecx, 3
    cmp ecx, 3                          ; level triggered
    jne .trigger_done
    or eax, 1 << 15
.trigger_done:
    mov r13d, eax
    xor ecx, ecx                        ; which I/O APIC serves this GSI?
.find_chip:
    cmp ecx, [ioapic_count]
    jae .out
    lea rax, [ioapic_gsi_base]
    mov ebx, r12d
    sub ebx, [rax + rcx * 4]
    jb .next_chip
    lea rax, [ioapic_max_entry]
    cmp ebx, [rax + rcx * 4]
    ja .next_chip
    lea rax, [ioapic_phys]
    mov rax, [rax + rcx * 8]
    add rax, [phys_base]
    lea ecx, [ebx * 2 + 0x10]
    inc ecx
    mov [rax], ecx                      ; high dword: destination
    shl edx, 24
    mov [rax + 0x10], edx
    dec ecx
    mov [rax], ecx                      ; low dword last: unmasks
    mov [rax + 0x10], r13d
    jmp .out
.next_chip:
    inc ecx
    jmp .find_chip
.out:
    pop r13
    pop r12
    pop rbx
    ret

section .data
lapic_x2:       db 0

section .bss
alignb 8
lapic_mmio:     resq 1
