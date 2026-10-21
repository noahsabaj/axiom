; =============================================================================
;  power.asm - reboot and power off. UEFI runtime ResetSystem first (we never
;  called SetVirtualAddressMap, so the runtime runs identity-mapped, on the
;  firmware tables), then the ACPI paths, then the legacy ones.
; =============================================================================

RT_RESET_SYSTEM equ 104
EFI_RESET_COLD  equ 0
EFI_RESET_SHUTDOWN equ 2

section .text

; efi_reset(EDI = reset type): returns only if the firmware refuses
efi_reset:
    push rbx
    push r12
    mov rax, [boot_info]
    mov rax, [rax + BI_RUNTIME]
    test rax, rax
    jz .out
    add rax, [phys_base]                ; its table, through the direct map
    mov r12, [rax + RT_RESET_SYSTEM]
    test r12, r12
    jz .out
    cli
    call fw_enter                       ; the firmware runs identity-mapped
    push rax
    mov ecx, edi                        ; MS x64: type, status, size, data
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov rbx, rsp
    and rsp, -16
    sub rsp, 32
    call r12
    mov rsp, rbx
    pop rdi
    call fw_leave
.out:
    pop r12
    pop rbx
    ret

power_reboot:
    call rtw_leave                      ; off the Wi-Fi network, first
    call battery_leave                  ; and normal charging again
    mov edi, EFI_RESET_COLD
    call efi_reset
    cli
    cmp byte [reset_ok], 0              ; ACPI reset register (I/O space)
    je .cf9
    cmp dword [reset_space], 1
    jne .cf9
    mov rdx, [reset_addr]
    mov eax, [reset_value]
    out dx, al
    mov edi, 50000
    call delay_us
.cf9:
    mov dx, 0xCF9                       ; chipset reset control: full reset
    mov al, 0x02
    out dx, al
    mov al, 0x0E
    out dx, al
    mov edi, 50000
    call delay_us
    mov al, 0xFE                        ; keyboard controller pulse
    out 0x64, al
    mov edi, 50000
    call delay_us
    lidt [null_idtr]                    ; last resort: triple fault
    int3
.hang:
    hlt
    jmp .hang

; power_cycle: a full reset straight from the chipset (CF9's FULL_RST: the
; platform's power off for a few seconds, then on), not the firmware's
; ResetSystem, which may keep the power on: devices that hold their state
; through a warm reset start afresh (watch.asm, a network missing). The
; usual ways if it did not happen. Never returns.
power_cycle:
    call rtw_leave
    call battery_leave
    call log_final
    cli
    mov dx, 0xCF9
    mov al, 0x02
    out dx, al
    mov al, 0x0E                        ; FULL_RST | RST_CPU | SYS_RST
    out dx, al
    mov edi, 50000
    call delay_us
    jmp power_reboot

power_off:
    call rtw_leave
    call battery_leave
    mov edi, EFI_RESET_SHUTDOWN
    call efi_reset
    cli
    call acpi_sleep_s5
    mov dx, 0x604                       ; QEMU's PM control, as a last guess
    mov ax, 0x2000
    out dx, ax
    KLOG "This machine refused to power off. It is safe to switch it off now."
.hang:
    cli
    hlt
    jmp .hang

; acpi_sleep_s5: SLP_TYP from the DSDT's \_S5 package into PM1a/PM1b control
acpi_sleep_s5:
    push rbx
    mov rbx, [fadt_ptr]
    test rbx, rbx
    jz .out
    mov eax, [rbx + 40]                 ; DSDT (32-bit)
    cmp dword [rbx + 4], 148
    jb .have_dsdt
    mov rcx, [rbx + 140]                ; X_DSDT wins when present
    test rcx, rcx
    jz .have_dsdt
    mov rax, rcx
.have_dsdt:
    test rax, rax
    jz .out
    add rax, [phys_base]
    mov rsi, rax
    mov ecx, [rsi + 4]
    lea rdi, [rsi + rcx - 8]            ; scan end
    add rsi, 36
.scan:
    cmp rsi, rdi
    jae .out
    cmp dword [rsi], '_S5_'
    je .found
    inc rsi
    jmp .scan
.found:
    cmp byte [rsi + 4], 0x12            ; PackageOp
    jne .out
    movzx eax, byte [rsi + 5]           ; PkgLength: skip its extra bytes
    shr eax, 6
    lea rsi, [rsi + rax + 7]            ; past op, length, element count
    call .element
    mov r8d, eax                        ; SLP_TYPa
    call .element
    mov r9d, eax                        ; SLP_TYPb
    mov edx, [rbx + 64]                 ; PM1a_CNT_BLK
    test edx, edx
    jz .out
    in ax, dx                           ; ACPI mode on? (SCI_EN)
    test ax, 1
    jnz .sleep
    mov ecx, [rbx + 48]                 ; SMI_CMD <- ACPI_ENABLE
    test ecx, ecx
    jz .sleep
    push rdx
    mov edx, ecx
    mov al, [rbx + 52]
    out dx, al
    mov edi, 100000
    call delay_us
    pop rdx
.sleep:
    mov eax, r8d
    shl eax, 10
    or eax, 1 << 13                     ; SLP_EN
    out dx, ax
    mov edx, [rbx + 68]                 ; PM1b_CNT_BLK
    test edx, edx
    jz .wait
    mov eax, r9d
    shl eax, 10
    or eax, 1 << 13
    out dx, ax
.wait:
    mov edi, 200000
    call delay_us
.out:
    pop rbx
    ret
.element:                               ; RSI -> AML integer, advances RSI
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, 0x0A                       ; BytePrefix
    jne .not_byte
    movzx eax, byte [rsi]
    inc rsi
    ret
.not_byte:
    cmp eax, 1                          ; ZeroOp / OneOp
    jbe .done
    xor eax, eax
.done:
    ret

; power_button_init: the ACPI fixed power button, when the firmware left the
; machine in ACPI mode and the button is not a control-method device: its
; event enabled (the SCI stays masked; power_button polls the status)
power_button_init:
    push rax
    push rbx
    push rdx
    mov rbx, [fadt_ptr]
    test rbx, rbx
    jz .out
    test dword [fadt_flags], 1 << 4     ; PWR_BUTTON: a control-method one
    jnz .out
    mov edx, [rbx + 64]                 ; PM1a_CNT_BLK: SCI_EN, ACPI mode
    test edx, edx
    jz .out
    in ax, dx
    test al, 1
    jz .out
    mov edx, [rbx + 56]                 ; PM1a_EVT_BLK: status, then enable
    test edx, edx
    jz .out
    movzx eax, byte [rbx + 88]          ; PM1_EVT_LEN
    shr eax, 1
    jz .out
    mov [pwr_sts_port], dx
    add edx, eax
    mov [pwr_en_port], dx
    in ax, dx
    or ax, 1 << 8                       ; PWRBTN_EN
    out dx, ax
    mov dx, [pwr_sts_port]
    mov ax, 1 << 8                      ; and no press from before
    out dx, ax
.out:
    pop rdx
    pop rbx
    pop rax
    ret

; power_button -> EAX = 1 if the power button was pressed since last asked
; (and not before). The main thread, after ACPI's tables are read. Preserves
; others.
power_button:
    push rdx
    cmp byte [pwr_tried], 0
    jne .ready
    mov byte [pwr_tried], 1
    call power_button_init
.ready:
    xor eax, eax
    movzx edx, word [pwr_sts_port]
    test edx, edx
    jz .out
    in ax, dx
    and eax, 1 << 8                     ; PWRBTN_STS
    jz .out
    out dx, ax                          ; written 1 to clear
    mov eax, 1
.out:
    pop rdx
    ret

section .data
align 8
    dw 0, 0, 0
null_idtr:
    dw 0
    dq 0

section .bss
alignb 2
pwr_sts_port:   resw 1                  ; PM1a status (0: no fixed button)
pwr_en_port:    resw 1
pwr_tried:      resb 1                  ; power_button_init done

section .text
