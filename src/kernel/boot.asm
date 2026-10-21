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
    call harness_init                   ; a test run the loader found (hp-1)
    call update_init                    ; a new kernel on trial: its watchdog
    call cfg_init                       ; the settings: SETTINGS.TXT, or the defaults
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
    call battery_init                   ; the EC, and a board whose battery Axiom holds
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
    call vmd_init                       ; and what a VMD hides (hp-1's drive)
    call iommu_init                     ; before any driver lets a device do DMA
    mov eax, [pci_count]
    KLOG "pci: %u functions", rax
    call kbd_init
    call serial_irq_init                ; what COM1 types, as it comes
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
    call rtw_start                      ; the Wi-Fi card's firmware, from the boot volume
    call update_start                   ; what kernel this is; a trial's outcome

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

; the main loop's parts, each timed: 'win speed' says the slowest (ml_say)
ML_USB          equ 0
ML_NET          equ 1
ML_LOG          equ 2
ML_POINTER      equ 3
ML_PROGRAMS     equ 4
ML_IOMMU        equ 5
ML_SHELL        equ 6
ML_START        equ 7
ML_HARNESS      equ 8
ML_UPDATE       equ 9
ML_BATTERY      equ 10
ML_LOAD         equ 11
ML_KEYS         equ 12
ML_DESK         equ 13
ML_TERM         equ 14
ML_MOTION       equ 15
ML_COMPOSE      equ 16
ML_REFRESH      equ 17
ML_MANDEL       equ 18
ML_WATCH        equ 19
ML_CFG          equ 20
ML_PARTS        equ 21

; ML_TIMED function, part: called (what it is given kept), and the longest
; it took kept by its part
%macro ML_TIMED 2
    push rax
    push rdx
    RDTSC64
    mov [ml_began], rax
    pop rdx
    pop rax
    call %1
    RDTSC64
    sub rax, [ml_began]
    cmp rax, [ml_longest + %2 * 8]
    jbe %%kept
    mov [ml_longest + %2 * 8], rax
%%kept:
%endmacro

; -----------------------------------------------------------------------------
;  main_loop: input, telemetry twice a second, demo frames; in between, the
;  thread 'main' parks until the next of them, or until a device interrupts
; -----------------------------------------------------------------------------
main_loop:
    ML_TIMED usb_poll, ML_USB
    ML_TIMED usb_service, ML_USB
    ML_TIMED net_service, ML_NET
    ML_TIMED log_service, ML_LOG
    ML_TIMED cfg_service, ML_CFG        ; settings: the stick's, applied, kept
    ML_TIMED pointer_service, ML_POINTER
    ML_TIMED user_service, ML_PROGRAMS
    ML_TIMED iommu_service, ML_IOMMU
    ML_TIMED shell_service, ML_SHELL    ; the rest of a line, after a command
    ML_TIMED start_service, ML_START    ; START.TXT's lines, at each start
    ML_TIMED harness_service, ML_HARNESS ; a test run's next line
    ML_TIMED update_service, ML_UPDATE  ; a trial not kept in time: a restart
    ML_TIMED watch_service, ML_WATCH    ; the watchdog kept: reloaded
    ML_TIMED battery_service, ML_BATTERY ; the battery hold's minute
    ML_TIMED load_service, ML_LOAD      ; the load average's 5 s
.keys:
    call key_next                       ; keys down and up, until a key code's turn
    jc .input
    ML_TIMED win_key_event, ML_KEYS     ; to a program with the keys that asks
    jmp .keys
.input:
    call kbd_getc                       ; once the keys before it are out
    test eax, eax
    jz .typed
    ML_TIMED desk_key, ML_KEYS          ; to the window with the keys
    jmp .keys
.typed:
    call key_pending                    ; keys down and up since
    jnz .keys
.refresh:
    ML_TIMED desk_service, ML_DESK      ; windows closing go
    ML_TIMED term_service, ML_TERM      ; what was printed, drawn
    ML_TIMED motion_service, ML_MOTION  ; what moves, a step on
    ML_TIMED desk_update, ML_COMPOSE    ; and what changed, shown
    RDTSC64
    cmp rax, [next_refresh]
    jb .demo
    add rax, [refresh_ticks]
    mov [next_refresh], rax
    ML_TIMED ui_refresh, ML_REFRESH
    ML_TIMED desk_tick, ML_REFRESH      ; the bar's clock, each new minute
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
    ML_TIMED mandel_frame, ML_MANDEL
    ML_TIMED ui_demo_stats, ML_MANDEL
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
    cmp byte [harness_ready], 0         ; a test run's line done: the next
    jne .awake
    cmp qword [cfg_pending], 0          ; a program changed a setting
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
    call watch_deadline                 ; the watchdog's next reload
    call motion_deadline                ; the next step of what moves
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

; ml_say: the main loop's three slowest parts since it was last asked, each
; by the longest it took at once ('win speed'); then from 0
ml_say:
    push r12
    push r13
    sub rsp, 48                         ; three names, three times
    mov r12, rsp
    xor r13d, r13d
.pick:
    lea rdx, [ml_longest]               ; the slowest left
    xor ecx, ecx
    xor r8d, r8d
.find:
    mov rax, [rdx + rcx * 8]
    cmp rax, [rdx + r8 * 8]
    jbe .next
    mov r8d, ecx
.next:
    inc ecx
    cmp ecx, ML_PARTS
    jb .find
    mov rax, [rdx + r8 * 8]
    mov qword [rdx + r8 * 8], 0
    mov ecx, 100                        ; in hundredths of a ms
    mul rcx
    div qword [tsc_per_ms]
    mov [r12 + r13 + 8], rax
    lea rax, [ml_names]
    mov rax, [rax + r8 * 8]
    mov [r12 + r13], rax
    add r13d, 16
    cmp r13d, 48
    jb .pick
    KLOG "desk: the main loop's slowest: %s %h ms, %s %h ms, %s %h ms", qword [r12], qword [r12 + 8], qword [r12 + 16], qword [r12 + 24], qword [r12 + 32], qword [r12 + 40]
    lea rdi, [ml_longest]               ; from 0
    xor eax, eax
    mov ecx, ML_PARTS
    rep stosq
    add rsp, 48
    pop r13
    pop r12
    ret

section .rodata
align 8
ml_names:       dq str_ml_usb, str_ml_net, str_ml_log, str_ml_pointer
                dq str_ml_programs, str_ml_iommu, str_ml_shell, str_ml_start
                dq str_ml_harness, str_ml_update, str_ml_battery, str_ml_load
                dq str_ml_keys, str_ml_desk, str_ml_term, str_ml_motion
                dq str_ml_compose, str_ml_refresh, str_ml_mandel, str_ml_watch
                dq str_ml_cfg
str_ml_usb:     db 'usb', 0
str_ml_net:     db 'net', 0
str_ml_log:     db 'log', 0
str_ml_pointer: db 'pointer', 0
str_ml_programs: db 'programs', 0
str_ml_iommu:   db 'iommu', 0
str_ml_shell:   db 'shell', 0
str_ml_start:   db 'start', 0
str_ml_harness: db 'harness', 0
str_ml_update:  db 'update', 0
str_ml_battery: db 'battery', 0
str_ml_load:    db 'load', 0
str_ml_keys:    db 'keys', 0
str_ml_desk:    db 'desk', 0
str_ml_term:    db 'terminal', 0
str_ml_motion:  db 'motion', 0
str_ml_compose: db 'compose', 0
str_ml_watch:   db 'watchdog', 0
str_ml_cfg:     db 'settings', 0
str_ml_refresh: db 'refresh', 0
str_ml_mandel:  db 'mandelbrot', 0

section .text

section .bss
alignb 8
next_refresh:   resq 1
next_frame:     resq 1
refresh_ticks:  resq 1
frame_ticks:    resq 1
usb_poll_ticks: resq 1
ml_began:       resq 1
ml_longest:     resq ML_PARTS
