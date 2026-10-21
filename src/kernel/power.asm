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

; -----------------------------------------------------------------------------
;  'power': what the processor draws and how it rests, measured over a
;  second (RAPL, the digital sensors, MPERF against the TSC, the package's
;  C-state residency counters); how idle CPUs sleep (cpu_idle); what the
;  cores trade for speed (HWP's energy-performance preference)
; -----------------------------------------------------------------------------
PW_WINDOW_US    equ 1000000
PW_STATES       equ 7                   ; package C2, C3, C6, C7, C8, C9, C10
PW_BIASES       equ 3

; power: a second's measure, then one record
power_show:
    push rbx
    push r12
    push r13
    push r14
    lea rdi, [pw_res0]
    call pw_read
    call telemetry_sample_all
    call cpu_package_power
    RDTSC64
    mov r12, rax                        ; the window's start
    mov edi, PW_WINDOW_US
    call thread_sleep_us
    call telemetry_sample_all
    call cpu_package_power
    mov r13, rax                        ; mW
    lea rdi, [pw_res1]
    call pw_read
    RDTSC64
    sub rax, r12
    mov r12, rax                        ; the window, in TSC ticks

    COLUMN 'watts', FT_INT, 2
    COLUMN 'heat', FT_INT, 0, {G_DEGREE, 'C'}
    COLUMN 'busy', FT_INT, 1, '%'
    COLUMN 'clock', FT_INT, 0, ' MHz'
    COLUMN 'idle', FT_TEXT
    COLUMN 'bias', FT_TEXT
    COLUMN 'pc2', FT_INT, 1, '%'
    COLUMN 'pc3', FT_INT, 1, '%'
    COLUMN 'pc6', FT_INT, 1, '%'
    COLUMN 'pc7', FT_INT, 1, '%'
    COLUMN 'pc8', FT_INT, 1, '%'
    COLUMN 'pc9', FT_INT, 1, '%'
    COLUMN 'pc10', FT_INT, 1, '%'
    mov edi, TBF_RECORD
    call rec_flag
    call rec_row

    xor edi, edi                        ; the package (none without RAPL)
    cmp byte [rapl_ok], 0
    je .no_watts
    mov rax, r13
    xor edx, edx
    mov ecx, 10
    div rcx
    mov rsi, rax
    call rec_set
    jmp .cpus
.no_watts:
    call rec_none

.cpus:
    xor r13d, r13d                      ; hottest
    xor r14d, r14d                      ; C0 thousandths, summed
    xor r8d, r8d                        ; MHz, summed
    xor r9d, r9d                        ; CPUs with a clock
    xor r10d, r10d                      ; CPUs online
    xor ecx, ecx
.cpu:
    cmp ecx, [cpu_count]
    jae .summed
    PERCPU rbx, rcx
    cmp qword [rbx + PC_ONLINE], 0
    je .cpu_next
    inc r10
    add r14, [rbx + PC_C0]
    mov rax, [rbx + PC_TEMP]
    cmp rax, r13
    cmova r13, rax
    mov rax, [rbx + PC_MHZ]
    test rax, rax
    jz .cpu_next
    add r8, rax
    inc r9
.cpu_next:
    inc ecx
    jmp .cpu
.summed:
    mov edi, 1
    mov rsi, r13
    call sh_set_reading
    mov edi, 2
    test dword [cpu_f6_ecx], 1          ; MPERF: no busy share without it
    jz .no_busy
    test r10, r10
    jz .no_busy
    mov rax, r14
    xor edx, edx
    div r10
    mov rsi, rax
    call rec_set
    jmp .clock
.no_busy:
    call rec_none
.clock:
    xor esi, esi
    test r9, r9
    jz .clock_set
    mov rax, r8
    xor edx, edx
    div r9
    mov rsi, rax
.clock_set:
    mov edi, 3
    call sh_set_reading

    mov edi, 4                          ; how idle CPUs sleep
    lea rsi, [str_pw_hlt]
    cmp byte [cpu_idle_deep], 0
    je .idle
    call power_cstate_name
    mov rsi, rax
.idle:
    call rec_str
    mov edi, 5
    call power_bias_name
    mov rsi, rax
    test rax, rax
    jz .no_bias
    call rec_str
    jmp .states
.no_bias:
    call rec_set                        ; text: 0 is none

.states:                                ; each package C-state's share
    xor ebx, ebx
.state:
    lea edi, [ebx + 6]
    lea rax, [pw_res0]
    mov rcx, [rax + rbx * 8]
    lea rax, [pw_res1]
    mov rax, [rax + rbx * 8]
    cmp rcx, -1
    je .state_none
    cmp rax, -1
    je .state_none
    sub rax, rcx
    imul rax, rax, 1000
    xor edx, edx
    div r12
    mov rsi, rax
    call rec_set
    jmp .state_next
.state_none:
    call rec_none
.state_next:
    inc ebx
    cmp ebx, PW_STATES
    jb .state
    clc
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pw_read(RDI = PW_STATES qwords): each package C-state residency counter,
; -1 where there is none. Preserves all.
pw_read:
    push rax
    push rcx
    push rdx
    push rbx
    xor ebx, ebx
.next:
    lea rax, [pw_msrs]
    mov ecx, [rax + rbx * 4]
    call rdmsr_safe
    jc .none
    shl rdx, 32
    or rax, rdx
    jmp .keep
.none:
    mov rax, -1
.keep:
    mov [rdi + rbx * 8], rax
    inc ebx
    cmp ebx, PW_STATES
    jb .next
    pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

; power_cstate_name -> RAX = the name of cpu_cstate (MWAIT's C-states 1-7
; are C1, C3, C6, C7, C8, C9 and C10). Preserves others.
power_cstate_name:
    movzx eax, byte [cpu_cstate]
    push rcx
    lea rcx, [pw_cstates]
    mov rax, [rcx + rax * 8]
    pop rcx
    ret

; power_bias_name -> RAX = the name of cpu_epp, 0 without HWP. Preserves
; others.
power_bias_name:
    xor eax, eax
    cmp byte [cpu_hwp_on], 0
    je .out
    push rcx
    push rdx
    movzx edx, byte [cpu_epp]
    xor ecx, ecx
.find:
    lea rax, [pw_bias_epp]
    cmp dl, [rax + rcx]
    je .found
    inc ecx
    cmp ecx, PW_BIASES
    jb .find
    lea rax, [str_pw_other]
    jmp .done
.found:
    lea rax, [pw_bias_names]
    mov rax, [rax + rcx * 8]
.done:
    pop rdx
    pop rcx
.out:
    ret

; power idle <deep|light>
power_idle:
    cmp edi, 1
    jne .usage
    mov rdi, [rsi]
    lea rsi, [str_pw_deep]
    call streq
    test eax, eax
    jnz .deep
    lea rsi, [str_pw_light]
    call streq
    test eax, eax
    jz .usage
    mov byte [cpu_idle_deep], 0
    jmp power_show
.deep:
    cmp byte [cpu_cstate], 0
    je .none
    mov byte [cpu_idle_deep], 1
    jmp power_show
.none:
    KLOG "power: no deep idle here (it needs MWAIT, and the APIC timer and the TSC running in every C-state)"
    stc
    ret
.usage:
    KLOG "usage: power idle <deep|light>: MWAIT in the deepest C-state, or HLT"
    stc
    ret

; power bias <performance|balanced|saving>
power_bias:
    cmp edi, 1
    jne .usage
    mov rdi, [rsi]
    xor ecx, ecx
.find:
    lea rax, [pw_bias_names]
    mov rsi, [rax + rcx * 8]
    call streq
    test eax, eax
    jnz .found
    inc ecx
    cmp ecx, PW_BIASES
    jb .find
.usage:
    KLOG "usage: power bias <performance|balanced|saving>"
    stc
    ret
.found:
    cmp byte [cpu_hwp_on], 0
    je .no_hwp
    lea rax, [pw_bias_epp]
    mov al, [rax + rcx]
    mov [cpu_epp], al
    lea rdi, [cpu_epp_local]            ; on every CPU
    xor esi, esi
    call job_run_each
    jmp power_show
.no_hwp:
    KLOG "power: this CPU's speed is not under HWP"
    stc
    ret

section .data
align 8
power_actions:
    ACTION  '',      power_show,  '', 'over a second: watts, heat, time busy, clock, and the package in each C-state'
    ACTION  'idle',  power_idle,  '<deep|light>', 'how idle CPUs sleep: MWAIT in the deepest C-state, or HLT'
    ACTION  'bias',  power_bias,  '<performance|balanced|saving>', 'what the cores trade for speed, under HWP'
    dq 0, 0, 0, 0, 0

section .rodata
align 8
pw_cstates:     dq str_pw_hlt, str_pw_c1, str_pw_c3, str_pw_c6, str_pw_c7
                dq str_pw_c8, str_pw_c9, str_pw_c10
pw_bias_names:  dq str_pw_perf, str_pw_balanced, str_pw_saving
pw_msrs:        dd MSR_PKG_C2_RES, MSR_PKG_C3_RES, MSR_PKG_C6_RES, MSR_PKG_C7_RES
                dd MSR_PKG_C8_RES, MSR_PKG_C9_RES, MSR_PKG_C10_RES
pw_bias_epp:    db EPP_PERFORMANCE, EPP_BALANCED, EPP_SAVING
str_pw_hlt:     db 'HLT', 0
str_pw_c1:      db 'C1', 0
str_pw_c3:      db 'C3', 0
str_pw_c6:      db 'C6', 0
str_pw_c7:      db 'C7', 0
str_pw_c8:      db 'C8', 0
str_pw_c9:      db 'C9', 0
str_pw_c10:     db 'C10', 0
str_pw_deep:    db 'deep', 0
str_pw_light:   db 'light', 0
str_pw_perf:    db 'performance', 0
str_pw_balanced: db 'balanced', 0
str_pw_saving:  db 'saving', 0
str_pw_other:   db 'set elsewhere', 0

section .bss
alignb 8
pw_res0:        resq PW_STATES
pw_res1:        resq PW_STATES

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
