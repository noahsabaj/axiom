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
    call rtc_epoch                      ; the time programs are told (SI_CLOCK)
    KLOG "clock:%04u-%02u-%02u %02u:%02u:%02u", qword [rtc_year], qword [rtc_mon], qword [rtc_day], qword [rtc_hour], qword [rtc_min], qword [rtc_sec]
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
    call user_boot                      ; the console, for programs
    call look_make                      ; and the desktop's look (look.asm)
    call sched_init                     ; from here on, this is the thread 'main'
    call async_boot                     ; the thread 'async': timers, rings
    call smp_start
    call sched_topology
    mov eax, [cpus_online]
    mov ecx, [cpu_count]
    KLOG "smp: %u of %u threads online in %u us", rax, rcx, qword [smp_us]
    call pci_init
    call iommu_init                     ; before any driver lets a device do DMA
    mov eax, [pci_count]
    KLOG "pci: %u functions", rax
    call kbd_init
    call usb_init
    call disk_init
    call crypto_boot
    call net_init
    call snd_boot                       ; the sound controller, and the mixer
    call mandel_init
    mov al, [mandel_ok]
    cmp byte [sm_no_demo], 0            ; the firmware says not to (tests)
    je .demo_set
    xor eax, eax
.demo_set:
    mov [demo_on], al
    call ui_ready
    call shell_init
    sti
    mov byte [ints_on], 1
    call store_init                     ; interrupts on: the drive completes by them

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
    call user_service
    call iommu_service
    call shell_service                  ; the rest of a line, after a command
.keys:
    call key_next                       ; keys down and up, until a key code's turn
    jc .input
    call win_key_event                  ; to a program with the keys that asks
    jmp .keys
.input:
    call kbd_getc                       ; once the keys before it are out
    test eax, eax
    jz .typed
    call desk_key                       ; to the window with the keys
    jmp .keys
.typed:
    call key_pending                    ; keys down and up since
    jnz .keys
.refresh:
    call desk_service                   ; windows closing go
    call term_service                   ; what was printed, drawn
    call desk_update                    ; and what changed, shown
    RDTSC64
    cmp rax, [next_refresh]
    jb .demo
    add rax, [refresh_ticks]
    mov [next_refresh], rax
    call ui_refresh
    call desk_tick                      ; the bar's clock, each new minute
.demo:
    call ui_demo_shown                  ; minimised: nothing to draw
    jz .sleep
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
    call key_pending                    ; a key let go, which types nothing
    jnz .awake
    call pointer_pending
    jnz .awake
    cmp byte [usb_pending], 0
    jne .awake
    cmp byte [net_pending], 0
    jne .awake
    cmp byte [user_pending], 0
    jne .awake
    cmp byte [shell_pending], 0
    jne .awake
    cmp byte [lx_pending], 0            ; a Linux process ended
    jne .awake
    cmp qword [lx_load_list], 0         ; a file a Linux program waits for
    jne .awake
    cmp byte [term_dirty], 0            ; printed, from another CPU
    jne .awake
    call desk_pending                   ; drawn, by a program
    jnz .awake
    cmp byte [desk_reap], 0
    jne .awake
    cmp qword [spawn_list], 0           ; a program starting another
    jne .awake
    cmp qword [fs_list], 0              ; one asking for its files
    jne .awake
    mov rcx, [iommu_fault_count]        ; a device refused, not said yet
    cmp rcx, [iommu_fault_said]
    jne .awake
    mov rax, [next_refresh]             ; the next thing we have to do
    cmp byte [demo_on], 0
    je .arm
    cmp byte [m_hold], 0
    jne .arm
    push rax
    call ui_demo_shown
    pop rax
    jz .arm
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
