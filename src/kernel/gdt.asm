; =============================================================================
;  gdt.asm - flat 64-bit segments and one TSS per CPU
; =============================================================================

section .text

; gdt_load: install the GDT and reload every segment register. Clobbers RAX.
; GS base is cleared by the reload, so set MSR_GS_BASE afterwards.
gdt_load:
    lgdt [gdtr]
    push SEL_KCODE
    lea rax, [.reload_cs]
    push rax
    o64 retf
.reload_cs:
    mov ax, SEL_KDATA
    mov ds, ax
    mov es, ax
    mov ss, ax
    xor eax, eax
    mov fs, ax
    mov gs, ax
    ret

; tss_install(RBX = per-CPU block): describe this CPU's TSS and load TR.
; The TSS stack fields must already be filled. Preserves all.
tss_install:
    push rax
    push rcx
    push rdx
    push rdi
    lea rdx, [rbx + PC_TSS]
    mov word [rdx + TSS_IOPB], TSS_LIMIT + 1    ; no I/O permission bitmap
    mov eax, TSS_LIMIT                  ; limit 15:0
    mov rcx, rdx
    and ecx, 0xFFFF
    shl rcx, 16
    or rax, rcx                         ; base 15:0
    mov rcx, rdx
    shr rcx, 16
    and ecx, 0xFF
    shl rcx, 32
    or rax, rcx                         ; base 23:16
    mov rcx, 0x89                       ; present, 64-bit TSS (available)
    shl rcx, 40
    or rax, rcx
    mov rcx, rdx
    shr rcx, 24
    and ecx, 0xFF
    shl rcx, 56
    or rax, rcx                         ; base 31:24
    shr rdx, 32                         ; base 63:32
    mov rcx, [rbx + PC_INDEX]
    shl rcx, 4
    lea rdi, [gdt_tss]
    mov [rdi + rcx], rax
    mov [rdi + rcx + 8], rdx
    lea eax, [ecx + SEL_TSS0]
    ltr ax
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

section .data
align 16
gdt:
    dq 0
    dq 0x00AF9A000000FFFF               ; 0x08 kernel code, 64-bit
    dq 0x00CF92000000FFFF               ; 0x10 kernel data
    dq 0x00CFF2000000FFFF               ; 0x18 user data
    dq 0x00AFFA000000FFFF               ; 0x20 user code, 64-bit
gdt_tss:
    times MAX_CPUS * 2 dq 0             ; one 16-byte TSS descriptor per CPU
gdt_end:

align 8
    dw 0, 0, 0
gdtr:
    dw gdt_end - gdt - 1
    dq gdt
