; =============================================================================
;  boot.asm - kernel_main: bring the machine up in order, then run the loop
; =============================================================================

section .text

; The loader jumps here with RDI = boot information (direct-mapped),
; RSP = the top of a 64 KiB stack (direct-mapped), interrupts off, the
; loader's page tables live.
kernel_main:
    cli
    cld
    mov [boot_info], rdi
    mov [boot_rsp], rsp
    mov rax, 'AXIOMBI1'
    cmp [rdi + BI_MAGIC], rax
    jne boot_stop

    call gdt_load                       ; our segments, BSP per-CPU block in GS
    lea rbx, [percpu]
    mov [rbx + PC_SELF], rbx
    mov ecx, MSR_GS_BASE
    mov rax, rbx
    mov rdx, rbx
    shr rdx, 32
    wrmsr
    call idt_build
    call idt_load
    call serial_init
    mov rax, [boot_info]
    mov rax, [rax + BI_TSC_HZ]
    mov [tsc_hz], rax
    call time_init

    call cpu_detect
    call cpu_setup_local
    call cpu_telemetry_init
    KLOG "Axiom 0.1 - first light"
    call rtc_read
    KLOG "clock: %04u-%02u-%02u %02u:%02u:%02u", qword [rtc_year], qword [rtc_mon], qword [rtc_day], qword [rtc_hour], qword [rtc_min], qword [rtc_sec]
    call log_init
    lea rax, [cpu_brand]
    KLOG "cpu: %s, TSC %u MHz", rax, qword [tsc_mhz]

    call pmm_init
    mov rax, [pmm_free_pages]
    shl rax, 12
    KLOG "memory: %b usable, %b free", qword [pmm_usable_bytes], rax
    call vmm_init
    call heap_init
    call tlb_init
    lea rax, [kernel_rodata]
    mov rcx, KERNEL_BASE
    sub rax, rcx
    lea rdx, [kernel_data]
    lea rcx, [kernel_rodata]
    sub rdx, rcx
    lea r8, [kernel_end]
    lea rcx, [kernel_data]
    sub r8, rcx
    KLOG "memory: our own page tables; code %b read-only, constants %b, data %b not executable; no identity map", rax, rdx, r8
    call gfx_init
    call ui_init
    mov byte [log_to_screen], 1
    KLOG "Axiom 0.1 - first light. Written in assembly, nothing else underneath."
    mov rax, [boot_info]
    mov ecx, [rax + BI_FB_WIDTH]
    mov edx, [rax + BI_FB_HEIGHT]
    KLOG "display %ux%u, font %ux%u", rcx, rdx, qword [font_cw], qword [font_ch]

    lea rbx, [percpu]                   ; BSP: interrupt stacks and TSS
    call smp_alloc_stacks
    mov rsp, [rbx + PC_STACK_TOP]       ; onto a stack with a guard page
    mov rdi, [boot_rsp]                 ; and the loader's goes back
    sub rdi, [phys_base]
    sub rdi, BOOT_STACK_SIZE
    mov esi, BOOT_STACK_SIZE / 4096
    call pmm_free
    call tss_install
    call idt_use_ist

    call acpi_init
    mov eax, [cpu_count]
    mov ecx, [acpi_table_count]
    mov edx, [ioapic_count]
    KLOG "acpi: %u tables, %u processors in the MADT, %u I/O APIC(s)", rcx, rax, rdx
    call smbios_init
    call pmm_release_boot_services
    mov rax, [pmm_free_pages]
    shl rax, 12
    KLOG "memory: boot services reclaimed, %b free", rax

    call smp_init_bsp
    call lapic_init_bsp
    call ioapic_init
    lea rbx, [percpu]
    call cpu_identify_local
    call obj_boot                       ; the task 'kernel'
    call sched_init                     ; from here on, this is the thread 'main'
    call async_boot                     ; the thread 'async': timers, rings
    call smp_start
    call sched_topology
    mov eax, [cpus_online]
    mov ecx, [cpu_count]
    KLOG "smp: %u of %u threads online in %u us", rax, rcx, qword [smp_us]
    call pci_init
    mov eax, [pci_count]
    KLOG "pci: %u functions", rax
    call kbd_init
    call usb_init
    call disk_init
    call crypto_boot
    call net_init
    call mandel_init
    mov al, [mandel_ok]
    mov [demo_on], al
    call ui_ready
    call shell_init
    sti

    RDTSC64
    mov [next_refresh], rax
    mov [next_frame], rax
    mov rax, [tsc_per_ms]
    imul rcx, rax, 500
    mov [refresh_ticks], rcx
    imul rcx, rax, 16
    mov [frame_ticks], rcx              ; at most ~60 frames a second
    imul rcx, rax, 4
    mov [usb_poll_ticks], rcx           ; controllers without interrupts

; -----------------------------------------------------------------------------
;  main_loop: input, telemetry twice a second, demo frames; in between, the
;  thread 'main' parks until the next of them, or until a device interrupts
; -----------------------------------------------------------------------------
main_loop:
    call usb_poll
    call usb_service
    call net_service
    call log_service
    call pointer_service
.input:
    call kbd_getc
    test eax, eax
    jz .refresh
    call shell_key
    jmp .input
.refresh:
    RDTSC64
    cmp rax, [next_refresh]
    jb .demo
    add rax, [refresh_ticks]
    mov [next_refresh], rax
    call ui_refresh
.demo:
    cmp byte [mandel_dirty], 0          ; the mouse moved the view
    jne .render
    cmp byte [demo_on], 0
    je .sleep
    cmp byte [m_hold], 0
    jne .sleep
    RDTSC64
    cmp rax, [next_frame]
    jb .sleep
    add rax, [frame_ticks]
    mov [next_frame], rax
.render:
    call mandel_frame
    call ui_demo_stats
    jmp main_loop
.sleep:
    cli
    call kbd_pending
    jnz .awake
    call pointer_pending
    jnz .awake
    cmp byte [usb_pending], 0
    jne .awake
    cmp byte [net_pending], 0
    jne .awake
    mov rax, [next_refresh]             ; the next thing we have to do
    cmp byte [demo_on], 0
    je .arm
    cmp byte [m_hold], 0
    jne .arm
    mov rcx, [next_frame]
    cmp rcx, rax
    cmovb rax, rcx
.arm:
    cmp dword [hid_repeat_key], 0       ; a held key repeats
    je .poll
    mov rcx, [hid_repeat_at]
    cmp rcx, rax
    cmovb rax, rcx
.poll:
    cmp byte [usb_poll_needed], 0       ; controllers without interrupts
    je .armed
    mov rcx, rax
    RDTSC64
    add rax, [usb_poll_ticks]
    cmp rcx, rax
    cmovb rax, rcx
.armed:
    call net_deadline                   ; DHCP, ARP, ping, polling
    mov rdi, rax
    call thread_park_until
.awake:
    sti
    pause
    jmp main_loop

boot_stop:
    cli
    hlt
    jmp boot_stop

section .bss
alignb 8
next_refresh:   resq 1
next_frame:     resq 1
refresh_ticks:  resq 1
frame_ticks:    resq 1
usb_poll_ticks: resq 1
