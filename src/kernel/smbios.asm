; =============================================================================
;  smbios.asm - what the firmware says this machine is: maker, model, BIOS,
;  memory modules. Strings are copied out because the tables may live in
;  memory we reclaim later.
; =============================================================================

section .text

smbios_init:
    push rbx
    push r12
    push r13
    mov rax, [boot_info]
    mov rsi, [rax + BI_SMBIOS3]
    test rsi, rsi
    jz .try_v2
    add rsi, [phys_base]
    cmp dword [rsi], '_SM3'
    jne .try_v2
    movzx eax, byte [rsi + 7]
    mov [smbios_major], eax
    movzx eax, byte [rsi + 8]
    mov [smbios_minor], eax
    mov r12, [rsi + 0x10]               ; structure table
    mov r13d, [rsi + 0x0C]              ; maximum size
    jmp .walk
.try_v2:
    mov rax, [boot_info]
    mov rsi, [rax + BI_SMBIOS2]
    test rsi, rsi
    jz .done
    add rsi, [phys_base]
    cmp dword [rsi], '_SM_'
    jne .done
    movzx eax, byte [rsi + 6]
    mov [smbios_major], eax
    movzx eax, byte [rsi + 7]
    mov [smbios_minor], eax
    mov r12d, [rsi + 0x18]
    movzx r13d, word [rsi + 0x16]
.walk:
    add r12, [phys_base]
    add r13, r12                        ; end
.structure:
    lea rax, [r12 + 4]
    cmp rax, r13
    ja .done
    movzx eax, byte [r12]               ; type
    cmp eax, 127
    je .done
    movzx ecx, byte [r12 + 1]           ; formatted length
    cmp ecx, 4
    jb .done
    lea rbx, [r12 + rcx]                ; strings follow the formatted area
    cmp eax, 0
    je .bios
    cmp eax, 1
    je .system
    cmp eax, 2
    je .board
    cmp eax, 17
    je .memory
    cmp eax, 11
    je .oem
.skip:
    mov rsi, rbx                        ; find the double NUL
.skip_scan:
    lea rax, [rsi + 1]
    cmp rax, r13
    jae .done
    cmp word [rsi], 0
    je .skip_found
    inc rsi
    jmp .skip_scan
.skip_found:
    lea r12, [rsi + 2]
    jmp .structure

.bios:
    mov al, [r12 + 4]
    lea rdi, [sm_bios_vendor]
    call smbios_copy_string
    mov al, [r12 + 5]
    lea rdi, [sm_bios_version]
    call smbios_copy_string
    mov al, [r12 + 8]
    lea rdi, [sm_bios_date]
    call smbios_copy_string
    jmp .skip
.system:
    mov al, [r12 + 4]
    lea rdi, [sm_sys_vendor]
    call smbios_copy_string
    mov al, [r12 + 5]
    lea rdi, [sm_sys_product]
    call smbios_copy_string
    jmp .skip
.board:
    mov al, [r12 + 4]
    lea rdi, [sm_board_vendor]
    call smbios_copy_string
    mov al, [r12 + 5]
    lea rdi, [sm_board_product]
    call smbios_copy_string
    jmp .skip
.memory:
    cmp ecx, 0x15
    jb .skip
    movzx eax, word [r12 + 0x0C]        ; size
    test eax, eax
    jz .skip                            ; empty slot
    cmp eax, 0xFFFF
    je .skip
    cmp eax, 0x7FFF
    jne .mem_small
    cmp ecx, 0x20
    jb .skip
    mov eax, [r12 + 0x1C]               ; extended size, MiB
    jmp .mem_add
.mem_small:
    test eax, 0x8000                    ; KiB granularity
    jz .mem_add
    and eax, 0x7FFF
    shr eax, 10
.mem_add:
    add [sm_mem_total_mb], rax
    inc dword [sm_mem_modules]
    cmp dword [sm_mem_modules], 1
    jne .skip                           ; describe the first module only
    mov [sm_mem_module_mb], eax
    movzx eax, byte [r12 + 0x12]
    mov [sm_mem_type], eax
    cmp ecx, 0x17
    jb .skip
    movzx eax, word [r12 + 0x15]
    mov [sm_mem_speed], eax
    cmp ecx, 0x22
    jb .mem_strings
    movzx eax, word [r12 + 0x20]        ; configured speed
    test eax, eax
    jz .mem_strings
    mov [sm_mem_speed], eax
.mem_strings:
    cmp ecx, 0x1B
    jb .skip
    mov al, [r12 + 0x17]
    lea rdi, [sm_mem_vendor]
    call smbios_copy_string
    mov al, [r12 + 0x1A]
    lea rdi, [sm_mem_part]
    call smbios_copy_string
    jmp .skip
.oem:                                   ; OEM strings: what QEMU's -smbios type=11 says
    mov rsi, rbx
.oem_string:
    cmp rsi, r13
    jae .done
    cmp byte [rsi], 0                   ; the end of the set
    je .skip
    lea rdi, [str_sm_no_demo]
    call streq
    test eax, eax
    jz .oem_next
    mov byte [sm_no_demo], 1
.oem_next:
    cmp rsi, r13
    jae .done
    lodsb
    test al, al
    jnz .oem_next
    jmp .oem_string
.done:
    pop r13
    pop r12
    pop rbx
    ret

; smbios_copy_string(AL = string number, RBX = string set, RDI = 64-byte dest)
smbios_copy_string:
    push rcx
    push rdx
    push rsi
    movzx ecx, al
    test ecx, ecx
    jz .empty
    mov rsi, rbx
.find:
    dec ecx
    jz .found
.skip_one:
    cmp byte [rsi], 0
    je .skipped
    inc rsi
    jmp .skip_one
.skipped:
    inc rsi
    cmp byte [rsi], 0                   ; end of the set
    je .empty
    jmp .find
.found:
    mov edx, 64
    call strcpy_trim
    jmp .out
.empty:
    mov byte [rdi], 0
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; smbios_mem_type_name -> RAX = "DDR4" etc.
smbios_mem_type_name:
    mov eax, [sm_mem_type]
    lea rdx, [str_ddr4]
    cmp eax, 0x1A
    je .out
    lea rdx, [str_ddr5]
    cmp eax, 0x22
    je .out
    lea rdx, [str_lpddr5]
    cmp eax, 0x23
    je .out
    lea rdx, [str_lpddr4]
    cmp eax, 0x1E
    je .out
    lea rdx, [str_ddr3]
    cmp eax, 0x18
    je .out
    lea rdx, [str_ram]
.out:
    mov rax, rdx
    ret

section .rodata
str_ddr3:   db 'DDR3', 0
str_ddr4:   db 'DDR4', 0
str_ddr5:   db 'DDR5', 0
str_lpddr4: db 'LPDDR4', 0
str_lpddr5: db 'LPDDR5', 0
str_ram:    db 'RAM', 0
str_sm_no_demo: db 'axiom.demo=off', 0  ; tools/run.py --headless: no zoom at boot

section .bss
alignb 8
sm_mem_total_mb:  resq 1
sm_mem_modules:   resd 1
sm_mem_module_mb: resd 1
sm_mem_type:      resd 1
sm_mem_speed:     resd 1
smbios_major:     resd 1
sm_no_demo:       resb 1              ; 1: the demo is not started at boot
smbios_minor:     resd 1
sm_bios_vendor:   resb 64
sm_bios_version:  resb 64
sm_bios_date:     resb 64
sm_sys_vendor:    resb 64
sm_sys_product:   resb 64
sm_board_vendor:  resb 64
sm_board_product: resb 64
sm_mem_vendor:    resb 64
sm_mem_part:      resb 64
