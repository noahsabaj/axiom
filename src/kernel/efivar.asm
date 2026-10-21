; =============================================================================
;  efivar.asm - UEFI variables through the runtime services, which run on the
;  firmware tables, identity-mapped (fw_enter, see vmm.asm). A test run's
;  script comes in one and its log goes out in another (harness.asm). Main
;  loop only, or after a panic; the firmware is not re-entrant, so
;  interrupts are off for the duration of a call.
; =============================================================================

RT_GET_VARIABLE equ 0x48
RT_SET_VARIABLE equ 0x58
RT_QUERY_VARIABLE_INFO equ 0x80
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

; efi_var_room -> RAX = the variable store's bytes, RCX = how many are free,
; RDX = the most one variable may hold; CF = 1 if the firmware does not say
; (QueryVariableInfo is UEFI 2.0's). Preserves others.
efi_var_room:
    push rbx
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
    cmp dword [rax + 8], 0x00020000     ; the table's revision
    jb .fail
    cmp dword [rax + 12], RT_QUERY_VARIABLE_INFO + 8  ; and size
    jb .fail
    mov rax, [rax + RT_QUERY_VARIABLE_INFO]
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
    sub rsp, 32
    mov ecx, EFI_VAR_NV_BS_RT           ; Attributes
    lea rdx, [efi_room_all]             ; MaximumVariableStorageSize
    lea r8, [efi_room_free]             ; RemainingVariableStorageSize
    lea r9, [efi_room_one]              ; MaximumVariableSize
    call rax
    mov rsp, rbp
    mov rdi, rbx
    call fw_leave
    popfq
    test rax, rax
    jnz .fail
    mov rax, [efi_room_all]
    mov rcx, [efi_room_free]
    mov rdx, [efi_room_one]
    clc
    jmp .out
.fail:
    xor eax, eax
    xor ecx, ecx
    xor edx, edx
    stc
.out:
    pop rbp
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbx
    ret

section .bss
alignb 8
efi_var_size:   resq 1
efi_room_all:   resq 1
efi_room_free:  resq 1
efi_room_one:   resq 1
