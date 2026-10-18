; =============================================================================
;  idt.asm - interrupt descriptor table, entry stubs, exceptions and panic
; =============================================================================

section .text

; idt_build: point all 256 vectors at their stubs (run once, on the BSP)
idt_build:
    push rbx
    lea rsi, [isr_stubs]
    lea rdi, [idt]
    xor ecx, ecx
.entry:
    mov rax, rsi
    mov [rdi], ax                       ; offset 15:0
    mov word [rdi + 2], SEL_KCODE
    mov word [rdi + 4], 0x8E00          ; IST 0, present, DPL 0, interrupt gate
    shr rax, 16
    mov [rdi + 6], ax                   ; offset 31:16
    shr rax, 16
    mov [rdi + 8], eax                  ; offset 63:32
    mov dword [rdi + 12], 0
    add rsi, 16
    add rdi, 16
    inc ecx
    cmp ecx, 256
    jb .entry
    pop rbx
    ret

; idt_use_ist: once a TSS is loaded, run NMI, #DF and #MC on their own stacks
idt_use_ist:
    mov byte [idt + 2 * 16 + 4], 2
    mov byte [idt + 8 * 16 + 4], 1
    mov byte [idt + 18 * 16 + 4], 3
    ret

idt_load:
    lidt [idtr]
    ret

; irq_register(EDI = vector, RSI = handler). Handlers get RDI = frame.
irq_register:
    mov eax, edi
    mov [irq_handlers + rax * 8], rsi
    ret

; -----------------------------------------------------------------------------
;  Entry stubs: 16 bytes apart, so vector n lives at isr_stubs + 16 * n
; -----------------------------------------------------------------------------
%macro ISR_STUB 1
    align 16
  %if (%1 = 8) || (%1 >= 10 && %1 <= 14) || (%1 = 17) || (%1 = 21) || (%1 = 29) || (%1 = 30)
    push qword %1                       ; the CPU already pushed an error code
  %else
    push qword 0
    push qword %1
  %endif
    jmp isr_common
%endmacro

align 16
isr_stubs:
%assign vec 0
%rep 256
    ISR_STUB vec
%assign vec vec + 1
%endrep

isr_common:
    test byte [rsp + 24], 3             ; from ring 3: the kernel's GS
    jz .kernel_gs
    swapgs
.kernel_gs:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    cld
    cmp dword [gs:PC_TLB_LAZY], 0       ; woken from the idle HLT: a shootdown
    jne .lazy                           ; that let it sleep is answered first
.awake:
    mov rbp, rsp                        ; RBP = frame
    and rsp, -16
    mov rdi, rbp
    mov rax, [rbp + FR_VECTOR]
    cmp eax, 32
    jb .exception
    cmp eax, VEC_SPURIOUS
    je .return
    mov rax, [irq_handlers + rax * 8]
    test rax, rax
    jz .eoi
    call rax
    mov eax, [rbp + FR_VECTOR]          ; a device's: the main loop has work
    sub eax, 0x20
    cmp eax, 0x10
    jae .eoi
    call sched_irq_main
.eoi:
    call lapic_eoi
    cmp byte [gs:PC_RESCHED], 0         ; another thread should run now
    je .return
    call sched_preempt
    jmp .return
.exception:
    call exception_dispatch
    jmp .return
.lazy:
    call tlb_wake
    jmp .awake
.return:
    test byte [rbp + FR_CS], 3
    jz .restore
    call user_leave                     ; a task being killed goes no further
.restore:
    mov rsp, rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 16                         ; vector and error code
    test byte [rsp + 8], 3
    jz .iret
    swapgs
.iret:
    iretq

; -----------------------------------------------------------------------------
;  exception_dispatch(RDI = frame): recoverable cases return, the rest panic
; -----------------------------------------------------------------------------
exception_dispatch:
    mov rax, [rdi + FR_VECTOR]
    test byte [rdi + FR_CS], 3
    jz .kernel
    cmp eax, 2                          ; from ring 3: an NMI is as ever,
    je .not_gp
    cmp eax, 18                         ; a machine check is the machine's,
    je .fatal
    jmp user_fault                      ; and the rest end the task
.kernel:
    cmp eax, 13
    jne .not_gp
    mov rdx, [rdi + FR_RIP]             ; #GP from a probing MSR access?
    lea rcx, [rdmsr_safe_insn]
    cmp rdx, rcx
    jne .not_rdmsr
    lea rcx, [rdmsr_safe_fault]
    mov [rdi + FR_RIP], rcx
    ret
.not_rdmsr:
    lea rcx, [wrmsr_safe_insn]
    cmp rdx, rcx
    jne .not_gp
    lea rcx, [wrmsr_safe_fault]
    mov [rdi + FR_RIP], rcx
    ret
.not_gp:
    cmp eax, 2
    jne .fatal
    cmp dword [panic_active], 0         ; NMI: another CPU panicked, stop here
    je .spurious_nmi
.stop:
    cli
    hlt
    jmp .stop
.spurious_nmi:
    ret
.fatal:
    xor esi, esi
    jmp panic

; -----------------------------------------------------------------------------
;  panic(RDI = interrupt frame or 0, RSI = message or 0). Never returns.
;  Stops every other CPU, then paints the report and sends it to serial.
; -----------------------------------------------------------------------------
panic:
    cli
    mov eax, 1
    xchg eax, [panic_active]
    test eax, eax
    jnz .halt                           ; someone else is already reporting
    mov [panic_frame], rdi
    mov [panic_message], rsi
    mov rax, [gs:PC_CURRENT]
    mov [panic_thread], rax
    lea rsp, [panic_stack_top]          ; a known-good stack
    call smp_stop_others
    mov dword [print_lock], 0           ; locks held by stopped CPUs are void

    ; headline: the message, or the exception's name
    mov rdx, [panic_message]
    test rdx, rdx
    jnz .have_message
    mov rax, [panic_frame]
    lea rdx, [str_unknown]
    test rax, rax
    jz .have_message
    mov rax, [rax + FR_VECTOR]
    cmp eax, 32
    jae .have_message
    mov rdx, [exception_names + rax * 8]
.have_message:
    mov [panic_headline], rdx

    mov rax, [gs:PC_INDEX]
    mov [panic_cpu], rax
    mov rax, [gs:PC_APIC_ID]
    mov [panic_apic], rax
    call uptime_ms
    mov [panic_uptime], rax
    xor edx, edx
    mov ecx, 10
    div rcx
    mov [panic_uptime_cs], rax          ; centiseconds, printed with %h
    mov rax, cr2
    mov [panic_cr2], rax
    mov rax, cr3
    mov [panic_cr3], rax

    call panic_compose
    lea rdi, [panic_text]
    call serial_write
    call panic_paint
    lea rdi, [panic_text]
    call log_panic                      ; onto the boot stick, if that is safe
.halt:
    cli
    hlt
    jmp .halt

; panic_compose: the whole report as text in panic_text
panic_compose:
    push rbx
    lea rdi, [panic_text]
    mov rbx, [panic_frame]
    SPRINTF rdi, `\n*** AXIOM PANIC ***\n%s\nCPU %u (APIC %u), uptime %h s\n`, qword [panic_headline], qword [panic_cpu], qword [panic_apic], qword [panic_uptime_cs]
    add rdi, rax
    mov rax, [panic_thread]
    test rax, rax
    jz .no_thread
    lea rcx, [rax + TH_NAME]
    SPRINTF rdi, `thread %u, %s\n`, qword [rax + TH_ID], rcx
    add rdi, rax
.no_thread:
    test rbx, rbx
    jz .done
    SPRINTF rdi, `vector %u  error %p\nRIP %p  RSP %p  RFLAGS %p\nCR2 %p  CR3 %p  CS 0x%x  SS 0x%x\n`, qword [rbx + FR_VECTOR], qword [rbx + FR_ERROR], qword [rbx + FR_RIP], qword [rbx + FR_RSP], qword [rbx + FR_RFLAGS], qword [panic_cr2], qword [panic_cr3], qword [rbx + FR_CS], qword [rbx + FR_SS]
    add rdi, rax
    SPRINTF rdi, `RAX %p  RBX %p  RCX %p  RDX %p\nRSI %p  RDI %p  RBP %p  R8  %p\n`, qword [rbx + FR_RAX], qword [rbx + FR_RBX], qword [rbx + FR_RCX], qword [rbx + FR_RDX], qword [rbx + FR_RSI], qword [rbx + FR_RDI], qword [rbx + FR_RBP], qword [rbx + FR_R8]
    add rdi, rax
    SPRINTF rdi, `R9  %p  R10 %p  R11 %p  R12 %p\nR13 %p  R14 %p  R15 %p\n`, qword [rbx + FR_R9], qword [rbx + FR_R10], qword [rbx + FR_R11], qword [rbx + FR_R12], qword [rbx + FR_R13], qword [rbx + FR_R14], qword [rbx + FR_R15]
    add rdi, rax
    mov rsi, rbx                        ; a page fault: what it ran into
    call vmm_fault_text
    add rdi, rax
.done:
    pop rbx
    ret

section .rodata
str_unknown:    db 'Unknown failure', 0
%macro EXC_NAME 2
    exc_name_%1: db %2, 0
%endmacro
EXC_NAME 0,  'Divide error'
EXC_NAME 1,  'Debug exception'
EXC_NAME 2,  'Non-maskable interrupt'
EXC_NAME 3,  'Breakpoint'
EXC_NAME 4,  'Overflow'
EXC_NAME 5,  'Bound range exceeded'
EXC_NAME 6,  'Invalid opcode'
EXC_NAME 7,  'Device not available'
EXC_NAME 8,  'Double fault'
EXC_NAME 9,  'Coprocessor segment overrun'
EXC_NAME 10, 'Invalid TSS'
EXC_NAME 11, 'Segment not present'
EXC_NAME 12, 'Stack-segment fault'
EXC_NAME 13, 'General protection fault'
EXC_NAME 14, 'Page fault'
EXC_NAME 15, 'Reserved exception 15'
EXC_NAME 16, 'x87 floating-point exception'
EXC_NAME 17, 'Alignment check'
EXC_NAME 18, 'Machine check'
EXC_NAME 19, 'SIMD floating-point exception'
EXC_NAME 20, 'Virtualization exception'
EXC_NAME 21, 'Control protection exception'
EXC_NAME 22, 'Reserved exception 22'
EXC_NAME 23, 'Reserved exception 23'
EXC_NAME 24, 'Reserved exception 24'
EXC_NAME 25, 'Reserved exception 25'
EXC_NAME 26, 'Reserved exception 26'
EXC_NAME 27, 'Reserved exception 27'
EXC_NAME 28, 'Hypervisor injection exception'
EXC_NAME 29, 'VMM communication exception'
EXC_NAME 30, 'Security exception'
EXC_NAME 31, 'Reserved exception 31'
align 8
exception_names:
%assign n 0
%rep 32
    dq exc_name_ %+ n
%assign n n + 1
%endrep

section .data
align 16
idtr_pad:   dw 0, 0, 0
idtr:
    dw 256 * 16 - 1
    dq idt
panic_active:   dd 0

section .bss
alignb 16
idt:            resb 256 * 16
irq_handlers:   resq 256
panic_frame:    resq 1
panic_message:  resq 1
panic_thread:   resq 1
panic_headline: resq 1
panic_cpu:      resq 1
panic_apic:     resq 1
panic_uptime:   resq 1
panic_uptime_cs: resq 1
panic_cr2:      resq 1
panic_cr3:      resq 1
panic_text:     resb 2048
alignb 16
panic_stack:    resb 16384
panic_stack_top:
