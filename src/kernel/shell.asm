; =============================================================================
;  shell.asm - a small command line in the console panel
; =============================================================================

LINE_MAX        equ 1000

section .text

shell_init:
    KLOG "Type 'help' for commands."
    jmp shell_prompt

shell_prompt:
    push rdi
    mov edi, COL_ACCENT
    call con_set_color
    lea rdi, [str_prompt]
    call kputs
    mov edi, COL_TEXT
    call con_set_color
    call sh_flush
    pop rdi
    ret

; sh_echo(AL): one character to the console, shown at once. Preserves all.
sh_echo:
    push rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    call con_putc
    call con_flush
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    ret

sh_flush:
    push rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    call con_flush
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    ret

; shell_wait: the command runs on (a fetch); the prompt waits for
; shell_resume, and keys but ctrl+C are ignored meanwhile. Preserves all.
shell_wait:
    mov byte [sh_wait], 1
    ret

; shell_resume: what the prompt waited for is over. Preserves all.
shell_resume:
    cmp byte [sh_wait], 0
    je .out
    mov byte [sh_wait], 0
    call shell_prompt
.out:
    ret

; sh_secret(RDI = line) -> CF if it sets a secret ('claude key <key>'):
; then it is shown as stars, and neither logged nor kept for KEY_UP.
; Preserves all.
sh_secret:
    push rsi
    push rdi
    mov rsi, rdi
.lead:
    cmp byte [rsi], ' '
    jne .word
    inc rsi
    jmp .lead
.word:
    lea rdi, [str_sh_claude]
    call http_prefix
    jc .no
    cmp byte [rsi], ' '
    jne .no
.gap:
    inc rsi
    cmp byte [rsi], ' '
    je .gap
    lea rdi, [str_sh_key]
    call http_prefix
    jc .no
    cmp byte [rsi], ' '
    jne .no
.key:
    inc rsi                             ; and something after it
    cmp byte [rsi], ' '
    je .key
    cmp byte [rsi], 0
    je .no
    stc
    jmp .out
.no:
    clc
.out:
    pop rdi
    pop rsi
    ret

; shell_key(EAX = key code)
shell_key:
    push rbx
    cmp eax, 3                          ; ctrl+C, always
    je .cancel
    cmp byte [sh_wait], 0
    jne .out
    cmp eax, 10
    je .enter
    cmp eax, 8
    je .backspace
    cmp eax, KEY_UP
    je .history
    cmp eax, 12                         ; ctrl+L
    je .clear
    cmp eax, 32
    jb .out
    cmp eax, 126
    ja .out
    mov ecx, [sh_len]
    cmp ecx, LINE_MAX
    jae .out
    lea rdx, [sh_line]
    mov [rdx + rcx], al
    mov byte [rdx + rcx + 1], 0
    inc dword [sh_len]
    lea rdi, [sh_line]
    call sh_secret                      ; the key itself is not shown
    jnc .echo
    mov al, '*'
.echo:
    call sh_echo
    jmp .out
.backspace:
    cmp dword [sh_len], 0
    je .out
    dec dword [sh_len]
    mov al, 8
    call sh_echo
    jmp .out
.history:
    call sh_erase_line
    lea rdi, [sh_line]
    lea rsi, [sh_history]
    mov ecx, LINE_MAX
    rep movsb
    xor ebx, ebx
.retype:
    lea rdx, [sh_line]
    mov al, [rdx + rbx]
    test al, al
    jz .retyped
    call sh_echo
    inc ebx
    jmp .retype
.retyped:
    mov [sh_len], ebx
    jmp .out
.clear:
    call con_clear
    mov dword [sh_len], 0
    call shell_prompt
    jmp .out
.cancel:
    mov byte [sh_wait], 0               ; (the prompt comes back below)
    call net_cancel                     ; a ping, a lookup or a fetch stops
    mov dword [sh_len], 0
    lea rdi, [str_ctrl_c]
    call kputs
    call shell_prompt
    jmp .out
.enter:
    mov al, 10
    call sh_echo
    mov ecx, [sh_len]
    lea rdx, [sh_line]
    mov byte [rdx + rcx], 0
    test ecx, ecx
    jz .empty
    lea rdi, [sh_line]
    call sh_secret
    jc .secret
    lea rdi, [sh_history]
    lea rsi, [sh_line]
    mov ecx, LINE_MAX + 1
    rep movsb
    lea rdi, [sh_line]
    call log_command
    jmp .exec
.secret:
    lea rdi, [str_sh_secret]
    call log_command
.exec:
    call shell_exec
    mov dword [sh_len], 0
    cmp byte [sh_wait], 0
    jne .out
    call shell_prompt
    jmp .out
.empty:
    mov dword [sh_len], 0
    call shell_prompt
.out:
    pop rbx
    ret

sh_erase_line:
.next:
    cmp dword [sh_len], 0
    je .done
    dec dword [sh_len]
    mov al, 8
    call sh_echo
    jmp .next
.done:
    ret

; shell_exec: run sh_line
shell_exec:
    push rbx
    push r12
    mov byte [fat_writing], 0           ; nothing is half-written between commands
    lea rsi, [sh_line]
.skip_lead:
    cmp byte [rsi], ' '
    jne .word
    inc rsi
    jmp .skip_lead
.word:
    lea rdi, [sh_word]                  ; first word -> sh_word, rest -> sh_args
    xor ecx, ecx
.copy:
    mov al, [rsi]
    test al, al
    jz .copied
    cmp al, ' '
    je .copied
    cmp ecx, 31
    jae .skip_char
    cmp al, 'A'                         ; commands are case-insensitive
    jb .lower_ok
    cmp al, 'Z'
    ja .lower_ok
    or al, 0x20
.lower_ok:
    mov [rdi + rcx], al
    inc ecx
.skip_char:
    inc rsi
    jmp .copy
.copied:
    mov byte [rdi + rcx], 0
.skip_args:
    cmp byte [rsi], ' '
    jne .args
    inc rsi
    jmp .skip_args
.args:
    mov [sh_args], rsi
    test ecx, ecx
    jz .done
    lea rbx, [commands]
.find:
    mov rsi, [rbx]
    test rsi, rsi
    jz .unknown
    lea rdi, [sh_word]
    call streq
    test eax, eax
    jnz .run
    add rbx, 24
    jmp .find
.run:
    call [rbx + 8]
    jmp .done
.unknown:
    lea rax, [sh_word]
    KLOG "unknown command '%s' - try 'help'", rax
.done:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Commands
; -----------------------------------------------------------------------------
cmd_help:
    push rbx
    lea rbx, [commands]
.next:
    mov rax, [rbx]
    test rax, rax
    jz .done
    KLOG "  %-10s %s", rax, qword [rbx + 16]
    add rbx, 24
    jmp .next
.done:
    pop rbx
    ret

cmd_info:
    push rbx
    xor ebx, ebx
.next:
    lea rax, [info_labels]
    mov rax, [rax + rbx * 8]
    imul rdx, rbx, INFO_LEN
    lea rcx, [info_lines]
    add rdx, rcx
    KLOG "%-10s %s", rax, rdx
    inc ebx
    cmp ebx, SYS_LINES
    jb .next
    pop rbx
    ret

cmd_cpus:
    push rbx
    push r12
    KLOG "  cpu   apic  core.thr  clock      temp  rows  Mcycles"
    xor r12d, r12d
.next:
    cmp r12d, [cpu_count]
    jae .done
    lea rax, [cpu_order]
    mov eax, [rax + r12 * 4]
    PERCPU rbx, rax
    call ui_tile_label
    lea rdi, [sh_clock]                 ; "--" where the hardware has no reading
    mov word [rdi], '--'
    mov byte [rdi + 2], 0
    cmp qword [rbx + PC_MHZ], 0
    je .no_clock
    SPRINTF rdi, "%u MHz", qword [rbx + PC_MHZ]
.no_clock:
    lea rdi, [sh_temp]
    mov word [rdi], '--'
    mov byte [rdi + 2], 0
    cmp qword [rbx + PC_TEMP], 0
    je .no_temp
    SPRINTF rdi, {"%u", G_DEGREE}, qword [rbx + PC_TEMP]
.no_temp:
    lea rax, [ui_buf]
    lea rdx, [sh_clock]
    lea rsi, [sh_temp]
    mov rcx, [rbx + PC_JOB_CYCLES]
    shr rcx, 20
    KLOG "  %-5s %4u  %4u.%u  %9s  %4s  %4u  %u", rax, qword [rbx + PC_APIC_ID], qword [rbx + PC_CORE], qword [rbx + PC_THREAD], rdx, rsi, qword [rbx + PC_JOB_ITEMS], rcx
    inc r12d
    jmp .next
.done:
    pop r12
    pop rbx
    ret

cmd_mem:
    push rbx
    xor ebx, ebx
.next:
    lea rax, [mem_by_type]
    mov rcx, [rax + rbx * 8]
    test rcx, rcx
    jz .skip
    lea rax, [mem_type_names]
    mov rax, [rax + rbx * 8]
    KLOG "  %-14s %b", rax, rcx
.skip:
    inc ebx
    cmp ebx, 16
    jb .next
    mov rax, [pmm_free_pages]
    shl rax, 12
    KLOG "  usable %b, free %b, bitmap at %p", qword [pmm_usable_bytes], rax, qword [pmm_bitmap_phys]
    pop rbx
    ret

cmd_pci:
    push rbx
    push r12
    xor r12d, r12d
    lea rbx, [pci_devices]
.next:
    cmp r12d, [pci_count]
    jae .done
    mov rdi, rbx
    lea rsi, [ui_buf2]
    call pci_describe
    movzx eax, byte [rbx + PE_BUS]
    movzx ecx, byte [rbx + PE_DEV]
    movzx edx, byte [rbx + PE_FN]
    movzx r8d, word [rbx + PE_VENDOR]
    movzx r9d, word [rbx + PE_DEVICE]
    lea r10, [ui_buf2]
    KLOG "  %02x:%02x.%u  %04x:%04x  %s", rax, rcx, rdx, r8, r9, r10
    add rbx, PCI_ENTRY
    inc r12d
    jmp .next
.done:
    pop r12
    pop rbx
    ret

cmd_acpi:
    push rbx
    xor ebx, ebx
.next:
    cmp ebx, [acpi_table_count]
    jae .done
    lea rax, [acpi_table_sigs]
    mov eax, [rax + rbx * 4]
    mov [ui_buf], eax
    mov byte [ui_buf + 4], 0
    lea rax, [acpi_table_ptrs]
    mov rdx, [rax + rbx * 8]            ; mapped address
    mov rcx, rdx
    sub rcx, [phys_base]                ; physical address
    mov edx, [rdx + 4]                  ; length
    lea rax, [ui_buf]
    KLOG "  %s  at %p  %u bytes", rax, rcx, rdx
    inc ebx
    jmp .next
.done:
    pop rbx
    ret

cmd_demo:
    cmp byte [mandel_ok], 0
    je .unsupported
    xor byte [demo_on], 1
    cmp byte [demo_on], 0
    je .off
    KLOG "demo on"
    ret
.off:
    KLOG "demo paused (the cores go back to sleep)"
    ret
.unsupported:
    KLOG "this CPU has no AVX2 + FMA"
    ret

cmd_bench:
    cmp byte [mandel_ok], 0
    je cmd_demo.unsupported
    mov eax, [cpus_online]
    KLOG "rendering one frame on 1 core, then on %u threads...", rax
    call mandel_bench
    mov rax, [bench_one_cycles]
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_per_ms]
    mov r8, rax                         ; tenths of a ms
    mov rax, [bench_all_cycles]
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_per_ms]
    mov r9, rax
    mov rax, [bench_one_cycles]
    imul rax, rax, 10
    xor edx, edx
    mov rcx, [bench_all_cycles]
    test rcx, rcx
    jz .no_speedup
    div rcx
.no_speedup:
    mov r10, rax                        ; speedup in tenths
    mov rax, [bench_iters]              ; tenths of G iter/s, all cores
    mov rcx, [bench_all_cycles]
    xor r11d, r11d
    test rcx, rcx
    jz .report
    mul qword [tsc_hz]
    div rcx
    mov r11, rax                        ; iterations a second
.report:
    KLOG "  1 core   %t ms", r8
    cmp r11, 1000000000
    jb .mega
    mov rax, r11
    xor edx, edx
    mov ecx, 100000000
    div rcx
    KLOG {"  all      %t ms   ", G_MIDDOT, " speedup %t", G_TIMES, "   ", G_MIDDOT, " %t G iter/s"}, r9, r10, rax
    ret
.mega:
    mov rax, r11
    xor edx, edx
    mov ecx, 1000000
    div rcx
    KLOG {"  all      %t ms   ", G_MIDDOT, " speedup %t", G_TIMES, "   ", G_MIDDOT, " %u M iter/s"}, r9, r10, rax
    ret

cmd_clear:
    call con_clear
    ret

cmd_uptime:
    call uptime_ms
    KLOG "up %u ms since power-on", rax
    ret

cmd_echo:
    KLOG "%s", qword [sh_args]
    ret

cmd_reboot:
    KLOG "rebooting..."
    call log_final
    jmp power_reboot

cmd_poweroff:
    KLOG "powering off..."
    call log_final
    jmp power_off

cmd_panic:
    KLOG "testing the panic screen"
    ud2

section .rodata
str_prompt:     db 'axiom> ', 0
str_ctrl_c:     db '^C', 10, 0
str_sh_claude:  db 'claude', 0
str_sh_key:     db 'key', 0
str_sh_secret:  db 'claude key (not logged)', 0

%macro COMMAND 3                        ; name, handler, help
    dq %%name, %2, %%help
    [section .rodata]
    %%name: db %1, 0
    %%help: db %3, 0
    __SECT__
%endmacro

%macro MEMNAME 1
    dq %%s
    [section .rodata]
    %%s: db %1, 0
    __SECT__
%endmacro

section .data
align 8
commands:
    COMMAND 'help',     cmd_help,     'this list'
    COMMAND 'info',     cmd_info,     'what this machine is'
    COMMAND 'cpus',     cmd_cpus,     'each logical CPU: kind, clock, heat, work'
    COMMAND 'mem',      cmd_mem,      'physical memory by type'
    COMMAND 'pci',      cmd_pci,      'PCI Express functions'
    COMMAND 'acpi',     cmd_acpi,     'firmware ACPI tables'
    COMMAND 'usb',      usb_list,     'USB devices, hubs and what drives them'
    COMMAND 'disks',    cmd_disks,    'drives and their volumes'
    COMMAND 'vol',      cmd_vol,      'vol <n> [rw|ro]: pick a volume, allow writes'
    COMMAND 'ls',       cmd_ls,       'list a directory'
    COMMAND 'cd',       cmd_cd,       'change directory'
    COMMAND 'cat',      cmd_cat,      'print a file'
    COMMAND 'cp',       cmd_cp,       'cp <from> <to>: copy a file (up to 64 KiB)'
    COMMAND 'write',    cmd_write,    'write <file> <text>: create or replace a file'
    COMMAND 'mkdir',    cmd_mkdir,    'make a directory'
    COMMAND 'rm',       cmd_rm,       'remove a file or an empty directory'
    COMMAND 'date',     cmd_date,     'the clock'
    COMMAND 'net',      cmd_net,      'network interfaces, link and address'
    COMMAND 'ip',       cmd_ip,       'ip <a.b.c.d/n> [gateway] [dns]: set the address by hand'
    COMMAND 'dhcp',     cmd_dhcp,     'ask the network for an address'
    COMMAND 'ping',     cmd_ping,     'ping <address or name> [count]'
    COMMAND 'host',     cmd_host,     'host <name>: look up its address'
    COMMAND 'arp',      cmd_arp,      'the neighbours Axiom knows'
    COMMAND 'http',     cmd_http,     'http [-k] <[https://]host[:port][/path]> [file]: fetch a page; -k: no certificate check'
    COMMAND 'ask',      cmd_ask,      'ask <question>: ask Claude; the conversation goes on'
    COMMAND 'claude',   cmd_claude,   'claude [key <key>|model <name>|server <url> [-k]|new]: settings for ask'
    COMMAND 'tcp',      cmd_tcp,      'TCP connections'
    COMMAND 'crypto',   cmd_crypto,   'check the TLS crypto against its test vectors, and time it'
    COMMAND 'log',      cmd_log,      'log [save|on|off]: AXIOM.LOG on the boot stick'
    COMMAND 'demo',     cmd_demo,     'pause or resume the Mandelbrot zoom'
    COMMAND 'bench',    cmd_bench,    'one core against all of them'
    COMMAND 'uptime',   cmd_uptime,   'time since power-on'
    COMMAND 'echo',     cmd_echo,     'print the arguments'
    COMMAND 'clear',    cmd_clear,    'clear the console (also ctrl+L)'
    COMMAND 'panic',    cmd_panic,    'test the crash screen'
    COMMAND 'reboot',   cmd_reboot,   'restart the machine'
    COMMAND 'poweroff', cmd_poweroff, 'turn the machine off'
    dq 0, 0, 0

mem_type_names:
    MEMNAME 'reserved'
    MEMNAME 'loader code'
    MEMNAME 'loader data'
    MEMNAME 'boot code'
    MEMNAME 'boot data'
    MEMNAME 'runtime code'
    MEMNAME 'runtime data'
    MEMNAME 'conventional'
    MEMNAME 'unusable'
    MEMNAME 'ACPI reclaim'
    MEMNAME 'ACPI NVS'
    MEMNAME 'MMIO'
    MEMNAME 'MMIO ports'
    MEMNAME 'PAL code'
    MEMNAME 'persistent'
    MEMNAME 'other'

demo_on:        db 0

section .bss
sh_len:         resd 1
sh_wait:        resb 1
alignb 8
sh_args:        resq 1
sh_word:        resb 32
sh_line:        resb LINE_MAX + 8
sh_history:     resb LINE_MAX + 8

section .bss
sh_clock:       resb 16
sh_temp:        resb 16
