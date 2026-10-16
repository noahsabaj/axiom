; =============================================================================
;  cpu.asm - CPUID inventory, per-core setup, hybrid topology and telemetry
; =============================================================================

section .text

; -----------------------------------------------------------------------------
;  cpu_detect - run once on the BSP
; -----------------------------------------------------------------------------
cpu_detect:
    push rbx
    xor eax, eax
    cpuid
    mov [cpu_max_leaf], eax
    mov [cpu_vendor], ebx
    mov [cpu_vendor + 4], edx
    mov [cpu_vendor + 8], ecx
    mov eax, 0x80000000
    cpuid
    mov [cpu_max_ext], eax

    mov eax, 1
    cpuid
    mov [cpu_signature], eax
    mov [cpu_f1_ecx], ecx
    mov [cpu_f1_edx], edx
    mov ecx, eax                        ; family / model / stepping
    and ecx, 0xF
    mov [cpu_stepping], ecx
    mov ecx, eax
    shr ecx, 8
    and ecx, 0xF
    mov edx, eax
    shr edx, 4
    and edx, 0xF
    cmp ecx, 0xF
    jne .not_ext_family
    mov ebx, eax
    shr ebx, 20
    and ebx, 0xFF
    add ecx, ebx
.not_ext_family:
    cmp ecx, 6
    je .ext_model
    cmp ecx, 0xF
    jb .model_done
.ext_model:
    mov ebx, eax
    shr ebx, 12
    and ebx, 0xF0
    or edx, ebx
.model_done:
    mov [cpu_family], ecx
    mov [cpu_model], edx

    cmp dword [cpu_max_leaf], 6
    jb .no_leaf6
    mov eax, 6
    cpuid
    mov [cpu_f6_eax], eax
    mov [cpu_f6_ecx], ecx
.no_leaf6:
    cmp dword [cpu_max_leaf], 7
    jb .no_leaf7
    mov eax, 7
    xor ecx, ecx
    cpuid
    mov [cpu_f7_ebx], ebx
    mov [cpu_f7_ecx], ecx
    mov [cpu_f7_edx], edx
.no_leaf7:
    cmp dword [cpu_max_leaf], 0x0D
    jb .no_leafd
    mov eax, 0x0D
    xor ecx, ecx
    cpuid
    mov [cpu_xcr0_mask], eax
.no_leafd:
    cmp dword [cpu_max_ext], 0x80000001
    jb .no_ext1
    mov eax, 0x80000001
    cpuid
    mov [cpu_e1_ecx], ecx
    mov [cpu_e1_edx], edx
.no_ext1:
    cmp dword [cpu_max_ext], 0x80000007
    jb .no_ext7
    mov eax, 0x80000007
    cpuid
    mov [cpu_e7_edx], edx
.no_ext7:
    cmp dword [cpu_max_ext], 0x80000004
    jb .no_brand
    lea rdi, [cpu_brand_raw]
    mov esi, 0x80000002
.brand_leaf:
    mov eax, esi
    cpuid
    mov [rdi], eax
    mov [rdi + 4], ebx
    mov [rdi + 8], ecx
    mov [rdi + 12], edx
    add rdi, 16
    inc esi
    cmp esi, 0x80000004
    jbe .brand_leaf
.no_brand:
    call cpu_clean_brand
    call cpu_build_feature_string
    pop rbx
    ret

; cpu_clean_brand: "Intel(R) Core(TM) i7-14700F" -> "Intel Core i7-14700F"
cpu_clean_brand:
    push rbx
    lea rsi, [cpu_brand_raw]
    lea rdi, [cpu_scratch]
.copy:
    mov al, [rsi]
    test al, al
    jz .copied
    cmp dword [rsi], '(TM)'
    jne .not_tm
    add rsi, 4
    jmp .copy
.not_tm:
    cmp al, '('
    jne .keep
    cmp word [rsi + 1], 'R)'
    jne .keep
    add rsi, 3
    jmp .copy
.keep:
    mov [rdi], al
    inc rdi
    inc rsi
    jmp .copy
.copied:
    mov byte [rdi], 0
    lea rdi, [cpu_brand]
    lea rsi, [cpu_scratch]
    mov edx, 64
    call strcpy_trim
    cmp byte [cpu_brand], 0
    jne .done
    lea rdi, [cpu_brand]                ; no brand string: use the vendor
    lea rsi, [cpu_vendor]
    mov edx, 13
    call strcpy_trim
.done:
    pop rbx
    ret

; cpu_build_feature_string: the ISA extensions this machine has, in one line
cpu_build_feature_string:
    push rbx
    lea rsi, [feature_table]
    lea rdi, [cpu_features]
.entry:
    movzx eax, byte [rsi]               ; register id
    cmp al, 0xFF
    je .done
    movzx ecx, byte [rsi + 1]           ; bit
    mov edx, [feature_regs + rax * 4]   ; offset of the register copy
    lea rbx, [cpu_f1_ecx]
    mov edx, [rbx + rdx]
    bt edx, ecx
    lea rsi, [rsi + 2]
    jnc .skip_name
.copy_name:
    lodsb
    test al, al
    jz .space
    stosb
    jmp .copy_name
.space:
    mov al, ' '
    stosb
    jmp .entry
.skip_name:
    lodsb
    test al, al
    jnz .skip_name
    jmp .entry
.done:
    lea rax, [cpu_features]
    cmp rdi, rax
    je .terminate
    dec rdi                             ; drop the trailing space
.terminate:
    mov byte [rdi], 0
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  cpu_setup_local - control registers, SIMD state, PAT, NX and HWP on the
;  calling CPU. Preserves all.
; -----------------------------------------------------------------------------
cpu_setup_local:
    push rax
    push rcx
    push rdx
    mov rax, cr0
    and rax, ~(1 << 2)                  ; EM: no x87 emulation
    or rax, (1 << 1) | (1 << 5) | (1 << 16) ; MP, NE, WP
    mov cr0, rax
    mov rax, cr4
    or rax, (1 << 9) | (1 << 10)        ; OSFXSR, OSXMMEXCPT
    test dword [cpu_f1_ecx], 1 << 26
    jz .no_osxsave
    or rax, 1 << 18                     ; OSXSAVE
.no_osxsave:
    test dword [cpu_f7_ebx], 1 << 0
    jz .no_fsgsbase
    or rax, 1 << 16                     ; FSGSBASE
.no_fsgsbase:
    mov cr4, rax

    test dword [cpu_f1_ecx], 1 << 26    ; XCR0: x87 | SSE | AVX | AVX-512
    jz .no_xsave
    mov eax, 3
    test dword [cpu_f1_ecx], 1 << 28
    jz .set_xcr0
    or eax, 4
    test dword [cpu_f7_ebx], 1 << 16
    jz .set_xcr0
    mov ecx, [cpu_xcr0_mask]
    and ecx, 0xE0
    cmp ecx, 0xE0
    jne .set_xcr0
    or eax, 0xE0
.set_xcr0:
    mov [cpu_xcr0], eax
    xor ecx, ecx
    xor edx, edx
    xsetbv
.no_xsave:
    fninit
    ldmxcsr [mxcsr_default]

    test dword [cpu_e1_edx], 1 << 20    ; NX
    jz .no_nx
    mov ecx, MSR_EFER
    rdmsr
    or eax, 1 << 11
    wrmsr
.no_nx:
    mov ecx, MSR_PAT                    ; same PAT as the loader: PA4 = WC
    mov eax, PAT_VALUE_LO
    mov edx, PAT_VALUE_HI
    wrmsr

    test dword [cpu_f6_eax], 1 << 7     ; HWP: hand frequency control to the cores
    jz .no_hwp
    mov ecx, MSR_PM_ENABLE
    mov eax, 1
    xor edx, edx
    call wrmsr_safe
    jc .no_hwp
    mov ecx, MSR_HWP_CAPS
    call rdmsr_safe
    jc .no_hwp
    mov edx, eax
    and eax, 0xFF                       ; highest performance -> maximum
    shl eax, 8
    shr edx, 24                         ; lowest performance -> minimum
    or eax, edx                         ; desired 0 (autonomous), EPP 0 (performance)
    xor edx, edx
    mov ecx, MSR_HWP_REQUEST
    call wrmsr_safe
    jc .no_hwp
    mov byte [cpu_hwp_on], 1
.no_hwp:
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  cpu_identify_local(RBX = per-CPU block) - core kind and SMT position
; -----------------------------------------------------------------------------
cpu_identify_local:
    push rax
    push rcx
    push rdx
    push rbx
    mov qword [rbx + PC_KIND], CPU_KIND_UNKNOWN
    test dword [cpu_f7_edx], 1 << 15    ; hybrid part?
    jz .topology
    cmp dword [cpu_max_leaf], 0x1A
    jb .topology
    mov eax, 0x1A
    xor ecx, ecx
    cpuid
    pop rbx
    push rbx
    shr eax, 24
    cmp eax, 0x40
    jne .not_p
    mov qword [rbx + PC_KIND], CPU_KIND_P
    jmp .topology
.not_p:
    cmp eax, 0x20
    jne .topology
    mov qword [rbx + PC_KIND], CPU_KIND_E
.topology:
    mov qword [rbx + PC_THREAD], 0
    mov rax, [rbx + PC_APIC_ID]
    mov [rbx + PC_CORE], rax
    cmp dword [cpu_max_leaf], 0x0B
    jb .done
    mov eax, 0x0B
    xor ecx, ecx
    cpuid
    pop rbx
    push rbx
    mov ecx, eax
    and ecx, 0x1F                       ; bits of APIC ID that select the thread
    mov eax, edx
    shr eax, cl
    mov [rbx + PC_CORE], rax            ; physical core id (renumbered later)
    mov eax, 1
    shl eax, cl
    dec eax
    and edx, eax
    mov [rbx + PC_THREAD], rdx
.done:
    pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Telemetry: effective frequency (APERF/MPERF) and temperature (DTS) for the
;  calling CPU, written to its per-CPU block. Preserves all.
; -----------------------------------------------------------------------------
cpu_sample_local:
    push rax
    push rcx
    push rdx
    push rbx
    push r8
    mov rbx, [gs:abs PC_SELF]
    test dword [cpu_f6_ecx], 1          ; APERF/MPERF
    jz .no_freq
    mov ecx, MSR_MPERF
    call rdmsr_safe
    jc .no_freq
    shl rdx, 32
    or rax, rdx
    mov r8, rax
    mov ecx, MSR_APERF
    call rdmsr_safe
    jc .no_freq
    shl rdx, 32
    or rax, rdx
    mov rcx, rax
    sub rax, [rbx + PC_APERF]           ; delta A
    mov [rbx + PC_APERF], rcx
    mov rcx, r8
    sub r8, [rbx + PC_MPERF]            ; delta M
    mov [rbx + PC_MPERF], rcx
    test r8, r8
    jz .no_freq
    mul qword [tsc_mhz]                 ; MHz = tsc_mhz * dA / dM
    div r8
    mov [rbx + PC_MHZ], rax
.no_freq:
    test dword [cpu_f6_eax], 1          ; digital thermal sensor
    jz .done
    mov ecx, MSR_THERM_STATUS
    call rdmsr_safe
    jc .done
    test eax, eax                       ; bit 31: reading valid
    jns .done
    shr eax, 16
    and eax, 0x7F                       ; degrees below TjMax
    mov ecx, [cpu_tjmax]
    sub ecx, eax
    mov [rbx + PC_TEMP], rcx
.done:
    pop r8
    pop rbx
    pop rdx
    pop rcx
    pop rax
    ret

; cpu_telemetry_init (BSP): TjMax and RAPL energy units
cpu_telemetry_init:
    mov rax, [tsc_hz]
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov [tsc_mhz], rax
    test dword [cpu_f6_eax], 1
    jz .no_dts
    mov ecx, MSR_TEMP_TARGET
    call rdmsr_safe
    jc .no_dts
    shr eax, 16
    and eax, 0xFF
    jz .no_dts
    mov [cpu_tjmax], eax
.no_dts:
    mov ecx, MSR_RAPL_UNIT
    call rdmsr_safe
    jc .no_rapl
    shr eax, 8
    and eax, 0x1F                       ; energy status unit: 1 / 2^ESU joules
    mov [rapl_esu], eax
    mov ecx, MSR_PKG_ENERGY
    call rdmsr_safe
    jc .no_rapl
    mov [rapl_last_energy], eax
    RDTSC64
    mov [rapl_last_tsc], rax
    mov byte [rapl_ok], 1
.no_rapl:
    ret

; cpu_package_power -> RAX = package power in milliwatts since the last call
; (0 if unknown). Run on the BSP.
cpu_package_power:
    push rcx
    push rdx
    push r8
    xor eax, eax
    cmp byte [rapl_ok], 0
    je .out
    mov ecx, MSR_PKG_ENERGY
    call rdmsr_safe
    jc .zero
    mov ecx, eax
    sub ecx, [rapl_last_energy]         ; 32-bit wrap-safe delta
    mov [rapl_last_energy], eax
    mov r8d, ecx
    RDTSC64
    mov rcx, rax
    sub rcx, [rapl_last_tsc]
    mov [rapl_last_tsc], rax
    test rcx, rcx
    jz .zero
    mov rax, r8                         ; mW = (dE * 1000 >> ESU) * tsc_hz / dT
    imul rax, rax, 1000
    push rcx
    mov ecx, [rapl_esu]
    shr rax, cl
    pop rcx
    mul qword [tsc_hz]
    div rcx
    mov [rapl_mw], rax
    jmp .out
.zero:
    xor eax, eax
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  rdmsr_safe(ECX) -> EDX:EAX, CF = 1 if the MSR does not exist
;  wrmsr_safe(ECX, EDX:EAX), CF = 1 on #GP
;  The #GP handler resumes at the matching *_fault label.
; -----------------------------------------------------------------------------
rdmsr_safe:
rdmsr_safe_insn:
    rdmsr
    clc
    ret
rdmsr_safe_fault:
    xor eax, eax
    xor edx, edx
    stc
    ret

wrmsr_safe:
wrmsr_safe_insn:
    wrmsr
    clc
    ret
wrmsr_safe_fault:
    stc
    ret

; cpu_has_avx2_fma -> ZF clear if AVX2 + FMA are usable
cpu_has_avx2_fma:
    push rax
    mov eax, [cpu_xcr0]
    and eax, 6
    cmp eax, 6                          ; SSE + AVX state enabled
    jne .no
    test dword [cpu_f7_ebx], 1 << 5     ; AVX2
    jz .no
    test dword [cpu_f1_ecx], 1 << 12    ; FMA
    jz .no
    or eax, 1                           ; clears ZF
    pop rax
    ret
.no:
    xor eax, eax                        ; sets ZF
    pop rax
    ret

section .rodata
align 4
mxcsr_default:  dd 0x1F80

; register ids used by feature_table -> offsets from cpu_f1_ecx
feature_regs:
    dd 0                                ; 0 cpu_f1_ecx
    dd 4                                ; 1 cpu_f1_edx
    dd 8                                ; 2 cpu_f7_ebx
    dd 12                               ; 3 cpu_f7_ecx
    dd 16                               ; 4 cpu_f7_edx
    dd 20                               ; 5 cpu_e1_ecx
    dd 24                               ; 6 cpu_e1_edx
    dd 28                               ; 7 cpu_f6_eax
    dd 32                               ; 8 cpu_e7_edx

feature_table:                          ; register id, bit, name
    db 2, 5,  'AVX2', 0
    db 0, 12, 'FMA', 0
    db 2, 16, 'AVX-512', 0
    db 0, 20, 'SSE4.2', 0
    db 2, 8,  'BMI2', 0
    db 2, 19, 'ADX', 0
    db 0, 25, 'AES-NI', 0
    db 3, 9,  'VAES', 0
    db 3, 10, 'VPCLMUL', 0
    db 2, 29, 'SHA', 0
    db 3, 8,  'GFNI', 0
    db 0, 30, 'RDRAND', 0
    db 2, 18, 'RDSEED', 0
    db 0, 21, 'x2APIC', 0
    db 0, 24, 'TSC-deadline', 0
    db 8, 8,  'invariant-TSC', 0
    db 7, 7,  'HWP', 0
    db 6, 26, '1G-pages', 0
    db 6, 20, 'NX', 0
    db 2, 7,  'SMEP', 0
    db 2, 20, 'SMAP', 0
    db 3, 3,  'PKU', 0
    db 3, 7,  'CET', 0
    db 4, 15, 'hybrid', 0
    db 0xFF

section .data
align 8
cpu_tjmax:      dd 100
cpu_xcr0:       dd 0
cpu_hwp_on:     db 0
rapl_ok:        db 0

section .bss
alignb 8
; keep these nine in this order: feature_regs indexes them
cpu_f1_ecx:     resd 1
cpu_f1_edx:     resd 1
cpu_f7_ebx:     resd 1
cpu_f7_ecx:     resd 1
cpu_f7_edx:     resd 1
cpu_e1_ecx:     resd 1
cpu_e1_edx:     resd 1
cpu_f6_eax:     resd 1
cpu_e7_edx:     resd 1
cpu_f6_ecx:     resd 1
cpu_max_leaf:   resd 1
cpu_max_ext:    resd 1
cpu_signature:  resd 1
cpu_family:     resd 1
cpu_model:      resd 1
cpu_stepping:   resd 1
cpu_xcr0_mask:  resd 1
rapl_esu:       resd 1
rapl_last_energy: resd 1
alignb 8
rapl_last_tsc:  resq 1
rapl_mw:        resq 1
tsc_mhz:        resq 1
cpu_vendor:     resb 16
cpu_brand_raw:  resb 52
cpu_scratch:    resb 64
cpu_brand:      resb 64
cpu_features:   resb 256
