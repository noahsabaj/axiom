; =============================================================================
;  heat.asm - the CPU's temperature now, from Intel's digital thermal
;  sensors: the package's (IA32_PACKAGE_THERM_STATUS, where CPUID.06H:EAX
;  bit 6 says there is one), else the calling CPU's core's
;  (IA32_THERM_STATUS, with its "reading valid" bit). Both count down from
;  TjMax (MSR_TEMPERATURE_TARGET, read at boot: cpu_tjmax). The package's
;  is Linux's x86_pkg_temp, which fleet's sysinfo reads first for its
;  temp_c. Programs read it with SYS_INFO's SI_TEMP; FLEET.AXE reports it.
;
;  QEMU has no sensor: 'heat simulate' gives it one, read through the same
;  decoding: 53 below a TjMax of 100, 47 C.
; =============================================================================

HEAT_DTS        equ 1 << 0              ; CPUID.06H:EAX: the cores' sensors
HEAT_PTM        equ 1 << 6              ; the package's
HEAT_VALID      equ 1 << 31             ; IA32_THERM_STATUS: the reading valid
HEAT_SIM_BELOW  equ 53                  ; 'heat simulate': its readout
HEAT_SIM_TJMAX  equ 100                 ; and its TjMax

section .text

; cpu_heat -> RAX = degrees C now, or E_EMPTY (no sensor, or no reading
; that makes sense); RDX = the sensor (text). Any thread. Preserves others.
cpu_heat:
    push rcx
    push rsi
    cmp byte [heat_sim], 0
    jne .sim
    lea rsi, [str_heat_none]
    test dword [cpu_f6_eax], HEAT_DTS
    jz .none
    test dword [cpu_f6_eax], HEAT_PTM
    jz .core
    lea rsi, [str_heat_package]
    mov ecx, MSR_PKG_THERM_STATUS
    call rdmsr_safe
    jc .core                            ; (said to be there, and is not)
    mov ecx, [cpu_tjmax]
    jmp .decode
.core:
    lea rsi, [str_heat_core]
    mov ecx, MSR_THERM_STATUS
    call rdmsr_safe
    jc .none
    test eax, HEAT_VALID
    jz .none
    mov ecx, [cpu_tjmax]
    jmp .decode
.sim:
    lea rsi, [str_heat_sim]
    mov eax, HEAT_SIM_BELOW << 16
    mov ecx, HEAT_SIM_TJMAX
.decode:
    shr eax, 16
    and eax, 0x7F                       ; degrees below TjMax
    sub ecx, eax
    jle .none
    cmp ecx, 150
    jae .none
    mov eax, ecx
    jmp .out
.none:
    mov rax, E_EMPTY
.out:
    mov rdx, rsi
    pop rsi
    pop rcx
    ret

; heat: the CPU's temperature now, and the sensor it is from
heat_show:
    call cpu_heat
    test rax, rax
    js .none
    mov ecx, [cpu_tjmax]
    cmp byte [heat_sim], 0
    je .said
    mov ecx, HEAT_SIM_TJMAX
.said:
    KLOG "heat: %u C (%s; TjMax %u C)", rax, rdx, rcx
    clc
    ret
.none:
    KLOG "heat: no reading (%s)", rdx
    clc
    ret

; heat simulate: where there is no sensor (QEMU), a simulated one from now
; on, for what reads it (SYS_INFO's SI_TEMP, fleet's info). Until the next
; start.
heat_simulate:
    test dword [cpu_f6_eax], HEAT_DTS
    jnz .real
    mov byte [heat_sim], 1
    KLOG "heat: simulated from now on: %u below a TjMax of %u, %u C", HEAT_SIM_BELOW, HEAT_SIM_TJMAX, HEAT_SIM_TJMAX - HEAT_SIM_BELOW
    clc
    ret
.real:
    KLOG "heat: not simulated: this CPU has sensors of its own"
    stc
    ret

heat_actions:
    ACTION  '',         heat_show,     '', "the CPU's temperature now, and the sensor it is from", 0
    ACTION  'simulate', heat_simulate, '', 'where there is no sensor (QEMU): a simulated one from now on, at 47 C, for what reads it', 0
    dq 0, 0, 0, 0, 0

section .rodata
str_heat_none:      db 'no digital thermal sensor here', 0
str_heat_package:   db "the package's sensor", 0
str_heat_core:      db "this core's sensor", 0
str_heat_sim:       db "simulated, 'heat simulate'", 0

section .bss
heat_sim:       resb 1                  ; 1: 'heat simulate'
