; =============================================================================
;  efivar.asm - UEFI variables through the runtime services, which run on the
;  firmware tables, identity-mapped (fw_enter, see vmm.asm). Used to keep
;  Bluetooth bonds across boots without a filesystem. Main loop only; the
;  firmware is not re-entrant, so interrupts are off for the duration of a
;  call.
; =============================================================================

RT_GET_VARIABLE equ 0x48
RT_SET_VARIABLE equ 0x58
EFI_VAR_NV_BS_RT equ 7                  ; non-volatile, boot and runtime access

section .text

; efi_get_variable(RSI = UTF-16 name, RDX = vendor GUID, RDI = buffer,
; ECX = buffer bytes) -> RAX = bytes read; CF = 1 if missing or too big.
; Preserves others.
efi_get_variable:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbp
    mov rax, [boot_info]
    mov rax, [rax + BI_RUNTIME]
    test rax, rax
    jz .fail
    add rax, [phys_base]
    mov rax, [rax + RT_GET_VARIABLE]
    test rax, rax
    jz .fail
    mov [efi_var_size], rcx
    pushfq
    cli
    mov r10, rax
    call fw_enter                       ; the identity map, for the firmware
    mov rbx, rax                        ; our CR3, for after
    mov rax, r10
    mov rbp, rsp
    and rsp, -16
    sub rsp, 48                         ; shadow space + the fifth argument
    mov [rsp + 32], rdi                 ; Data
    mov rcx, rsi                        ; VariableName
                                        ; RDX = VendorGuid
    xor r8d, r8d                        ; Attributes: not wanted
    lea r9, [efi_var_size]              ; DataSize, in and out
    call rax
    mov rsp, rbp
    mov rdi, rbx
    call fw_leave
    popfq
    test rax, rax                       ; EFI_SUCCESS
    jnz .fail
    mov rax, [efi_var_size]
    clc
    jmp .out
.fail:
    xor eax, eax
    stc
.out:
    pop rbp
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; efi_set_variable(RSI = UTF-16 name, RDX = vendor GUID, RDI = data,
; ECX = bytes; 0 deletes it) -> CF = 1 on failure, RAX = EFI status.
; Preserves others.
efi_set_variable:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rbp
    mov rax, [boot_info]
    mov rax, [rax + BI_RUNTIME]
    test rax, rax
    jz .fail
    add rax, [phys_base]
    mov rax, [rax + RT_SET_VARIABLE]
    test rax, rax
    jz .fail
    pushfq
    cli
    mov r10, rax
    call fw_enter
    mov rbx, rax
    mov rax, r10
    mov rbp, rsp
    and rsp, -16
    sub rsp, 48
    mov [rsp + 32], rdi                 ; Data
    mov r9d, ecx                        ; DataSize
    mov r8d, EFI_VAR_NV_BS_RT           ; Attributes
    mov rcx, rsi                        ; VariableName, RDX = VendorGuid
    call rax
    mov rsp, rbp
    mov rdi, rbx
    call fw_leave
    popfq
    test rax, rax
    jnz .failed
    clc
    jmp .out
.fail:
    mov rax, -1
.failed:
    stc
.out:
    pop rbp
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .bss
alignb 8
efi_var_size:   resq 1
