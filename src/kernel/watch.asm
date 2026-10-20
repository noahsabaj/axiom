; =============================================================================
;  watch.asm - the watchdog kept: a machine no one is at (hp-1, as fleet's
;  axiom-1) restarts itself when Axiom stops. 'watchdog on' (a line of its
;  START.TXT) starts the chipset's TCO watchdog, found as the loader finds
;  it (tco_find), and the main loop reloads it as it goes round: once a
;  second at most, and it wakes for it every 10 s at least. Should the main
;  loop stop going round (a hang, a deadlock, a panic, interrupts off for
;  good), the count runs out and the chipset resets the machine, at most 2
;  minutes after the last reload ('watchdog on <seconds>' for another
;  time). 'watchdog off' stops it; 'watchdog test' stops the main loop to
;  see it work.
;
;  Tiger Lake's TCO counts its 0.6 s ticks only while the PCH's ACPI timer
;  runs, and hp-1's firmware turns that timer off (PWRM's ACPI_TMR_CTL,
;  ACPI_TIM_DIS): tco_find turns it on, as the loader does. The count is
;  seen moving once, at the first reload; a count that does not move is
;  said, and the watchdog is off.
;
;  The network too: while the watchdog is on, 5 minutes with no network (no
;  address, or no link on the interface that has it; 'watchdog net' for
;  another time, or off) end in a full reset, the platform's power cycled
;  (power_cycle). A machine reached only over the network is no use without
;  it, and a card that kept its state through a warm reset comes back
;  (hp-1's RTL8821CE, after Linux restarted without stopping it). The log
;  goes into AxiomLog first, unless one is there that no one has read.
; =============================================================================

WATCH_SECONDS   equ 120                 ; unless 'watchdog on' says
WATCH_MIN       equ 10
WATCH_MAX       equ 600
WATCH_WAKE      equ 10                  ; the main loop round at least this often (s)
WATCH_NET       equ 300                 ; no network this long: a full reset (s)
WATCH_NET_MIN   equ 30
WATCH_NET_MAX   equ 3600
TCO_STS1        equ 0x04                ; TCO1_STS: bit 3 TIMEOUT, the first count out
TCO_STS2        equ 0x06                ; TCO2_STS: bit 1 SECOND_TO_STS, the reset
TCO_CNT1        equ 0x08                ; TCO1_CNT: bit 11 TMR_HLT; bit 0 NO_REBOOT (v6)
TCO_TMR_INIT    equ 0x12                ; TCO_TMR: the count from the top, in ticks
PWRM_BASE       equ 0xFE000000          ; Tiger Lake's PMC registers (PWRMBASE)
PWRM_ACPI_TMR   equ 0x18FC              ; ACPI_TMR_CTL: bit 1 ACPI_TIM_DIS

section .text

; tco_find -> CF if this machine has no TCO watchdog Axiom can start (Tiger
; Lake's, where NO_REBOOT is in TCO1_CNT, or QEMU's ICH9, where it is in
; GCS); else tco_base set, NO_REBOOT cleared on ICH9, Tiger Lake's ACPI
; timer on, and whether the watchdog reset the machine before this start
; noted (watch_reset), then cleared. Main thread. Preserves all but RAX.
tco_find:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, 31 << 3 | 4                ; 0:31.4, the SMBus controller
    xor esi, esi
    call pci_read32
    lea rcx, [watch_v6_ids]
.v6_next:
    mov edx, [rcx]
    test edx, edx
    jz .ich9
    add rcx, 4
    cmp eax, edx
    jne .v6_next
    mov esi, 0x54                       ; TCOCTL: TCO_BASE_EN
    call pci_read32
    test eax, 0x100
    jz .none
    mov esi, 0x50                       ; TCOBASE
    call pci_read32
    and eax, 0xFFE0
    jz .none
    mov [tco_base], ax
    mov byte [watch_v6], 1
    call watch_acpi_timer
    jmp .found
.ich9:
    mov edi, 31 << 3                    ; 0:31.0, the LPC bridge
    xor esi, esi
    call pci_read32
    cmp eax, 0x29188086                 ; ICH9
    jne .none
    mov esi, 0x40                       ; PMBASE; the TCO's 0x60 above it
    call pci_read32
    and eax, 0xFF80
    jz .none
    add eax, 0x60
    mov ecx, eax
    mov esi, 0xF0                       ; RCBA, where GCS is
    call pci_read32
    test eax, 1
    jnz .rcba
    mov edx, 0xFED1C001                 ; not there yet: where firmware puts it
    call pci_write32
    mov eax, edx
.rcba:
    and eax, 0xFFFFC000
    mov rdi, rax
    add rdi, 0x3000
    mov esi, 0x1000
    call mmio_map
    test rax, rax
    jz .none
    mov edx, [rax + 0x410]              ; GCS: NO_REBOOT is bit 5
    and edx, ~0x20
    mov [rax + 0x410], edx
    test dword [rax + 0x410], 0x20
    jnz .none                           ; strapped on
    mov [tco_base], cx
    mov byte [watch_v6], 0
.found:
    movzx edx, word [tco_base]
    add edx, TCO_STS2
    in ax, dx
    test ax, 2
    jz .clear
    mov byte [watch_reset], 1
.clear:
    mov ax, 0x0006                      ; SECOND_TO_STS, BOOT_STS
    out dx, ax
    clc
    jmp .out
.none:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; watch_acpi_timer: Tiger Lake's PCH counts the TCO's ticks only while its
; ACPI timer runs; on, if the firmware left it off. Preserves all.
watch_acpi_timer:
    push rax
    push rsi
    push rdi
    mov edi, PWRM_BASE + (PWRM_ACPI_TMR & ~0xFFF)
    mov esi, 0x1000
    call mmio_map
    test rax, rax
    jz .out
    mov esi, [rax + (PWRM_ACPI_TMR & 0xFFF)]
    cmp esi, -1
    je .out                             ; nothing there
    test esi, 2
    jz .out
    and esi, ~2
    mov [rax + (PWRM_ACPI_TMR & 0xFFF)], esi
    KLOG "watchdog: the ACPI timer was off, and the TCO's count with it: on"
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; watch_arm(EDI = seconds) -> CF if the firmware keeps it from counting
; or from resetting the machine. The count from the top, counting. Main
; thread. Preserves all.
watch_arm:
    push rax
    push rdx
    call tco_set
    movzx edx, word [tco_base]
    add edx, TCO_TMR_INIT
    in ax, dx
    and eax, 0x3FF
    mov [watch_ticks], rax
    sub edx, TCO_TMR_INIT - TCO_STS1
    mov ax, 0x0008                      ; TIMEOUT
    out dx, ax
    add edx, TCO_CNT1 - TCO_STS1
    in ax, dx
    and ax, ~0x0800                     ; TMR_HLT: counting,
    cmp byte [watch_v6], 0
    je .count
    and ax, ~0x0001                     ; and allowed to reset the machine
.count:
    out dx, ax
    in ax, dx
    test ax, 0x0800
    jnz .locked
    cmp byte [watch_v6], 0
    je .armed
    test ax, 0x0001
    jz .armed
    or ax, 0x0800                       ; it would count for nothing: stopped
    out dx, ax
.locked:
    stc
    jmp .out
.armed:
    clc
.out:
    pop rdx
    pop rax
    ret

; watch_service: from the main loop. The watchdog reloaded, once a second
; at most; the first time, its count seen moving.
watch_service:
    cmp byte [watch_on], 0
    jne .on
    ret
.on:
    push rax
    push rcx
    push rdx
    RDTSC64
    cmp rax, [watch_pet_at]
    jb .out
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 1000
    add rcx, rax
    mov [watch_pet_at], rcx
    movzx edx, word [tco_base]
    cmp byte [watch_checked], 0
    jne .reload
    in ax, dx                           ; TCO_RLD: the count now
    and eax, 0x3FF
    cmp rax, [watch_ticks]
    jae .still
    mov byte [watch_checked], 1
    KLOG "watchdog: counting (%u of %u ticks left a second on)", rax, qword [watch_ticks]
.reload:
    add edx, TCO_STS1
    mov ax, 0x0008                      ; TIMEOUT cleared: two counts again
    out dx, ax
    sub edx, TCO_STS1
    mov ax, 1
    out dx, ax                          ; TCO_RLD: from the top
    call watch_net_check
.out:
    pop rdx
    pop rcx
    pop rax
    ret
.still:
    mov byte [watch_on], 0
    call watch_halt
    KLOG "watchdog: its count does not move (its clock is off): no watchdog"
    jmp .out

; watch_net_check: from watch_service, once a second. The network seen, or
; missed for watch_net_secs: a full reset. Preserves all.
watch_net_check:
    cmp qword [watch_net_secs], 0
    jne .on
    ret
.on:
    push rax
    push rcx
    push rdx
    RDTSC64
    call watch_net_ok
    jc .down
    mov [watch_net_seen], rax
    jmp .out
.down:
    mov rcx, [tsc_per_ms]
    imul rcx, [watch_net_secs]
    imul rcx, rcx, 1000
    add rcx, [watch_net_seen]
    cmp rax, rcx
    jae watch_net_reset
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; watch_net_ok -> CF unless the network is there: an address, and a link
; on the interface that has it. Preserves all.
watch_net_ok:
    cmp dword [net_ip], 0
    je .down
    push rax
    mov rax, [net_nic]
    test rax, rax
    jz .gone
    cmp dword [rax + NI_SPEED], 0
    jle .gone
    pop rax
    clc
    ret
.gone:
    pop rax
.down:
    stc
    ret

; watch_net_reset: no network for watch_net_secs. The log into AxiomLog
; (unless one is there still, so a machine that stays off the network does
; not write the variable store's flash every few minutes), then a full
; reset. Never returns.
watch_net_reset:
    KLOG "watchdog: no network for %u s: a full reset, the machine's power cycled, so a network card stuck since the last start comes back", qword [watch_net_secs]
    cmp byte [harness_on], 0
    jne .save                           ; a test run's log, as harness_end would
    lea rsi, [name_axiom_log]
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, HARNESS_BUF
    call efi_get_variable
    jnc .kept
.save:
    call harness_save
    jmp power_cycle
.kept:
    KLOG "watchdog: AxiomLog has a log no one has read: kept, not written over"
    jmp power_cycle

; watch_deadline(RAX = when the main loop would wake next, TSC) -> RAX, no
; later than WATCH_WAKE s after the last reload. Preserves others.
watch_deadline:
    cmp byte [watch_on], 0
    jne .on
    ret
.on:
    push rcx
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, (WATCH_WAKE - 1) * 1000
    add rcx, [watch_pet_at]
    cmp rcx, rax
    cmovb rax, rcx
    pop rcx
    ret

; watch_halt: the count stopped, unless a test run or a trial still wants
; it (they reload it themselves). Preserves all.
watch_halt:
    cmp byte [harness_on], 0
    jne .out
    cmp byte [upd_watch], 0
    jne .out
    call tco_stop
.out:
    ret

; watchdog: whether it is on, and when it resets the machine
watch_show:
    cmp byte [watch_on], 0
    je .off
    movzx eax, word [tco_base]
    KLOG "watchdog: on: the machine resets at most %u s after Axiom's main loop stops (TCO at I/O %x)", qword [watch_secs], rax
    call watch_net_show
    jmp .reset
.off:
    KLOG "watchdog: off ('watchdog on' starts it)"
.reset:
    cmp byte [watch_reset], 0
    je .out
    KLOG "watchdog: it reset this machine before this start"
.out:
    clc
    ret

; watchdog on [<seconds>]
watch_cmd_on:
    push rbx
    mov ebx, WATCH_SECONDS
    cmp edi, 1
    ja .usage
    jb .start
    mov rsi, [rsi]
    call arg_uint
    jc .usage
    cmp eax, WATCH_MIN
    jb .usage
    cmp eax, WATCH_MAX
    ja .usage
    mov ebx, eax
.start:
    call tco_find
    jc .none
    mov edi, ebx
    call watch_arm
    jc .locked
    mov [watch_secs], rbx
    mov byte [watch_checked], 0
    cmp byte [watch_net_set], 0
    jne .net_said
    mov qword [watch_net_secs], WATCH_NET
.net_said:
    RDTSC64
    mov [watch_net_seen], rax           ; the network's time from now
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 1000
    add rax, rcx
    mov [watch_pet_at], rax             ; the first reload a second on: the count seen
    mov byte [watch_on], 1
    movzx eax, word [tco_base]
    KLOG "watchdog: on: the machine resets at most %u s after Axiom's main loop stops (TCO at I/O %x)", rbx, rax
    call watch_net_show
    cmp byte [watch_reset], 0
    je .ok
    KLOG "watchdog: it reset this machine before this start"
.ok:
    clc
    jmp .out
.none:
    KLOG "watchdog: none here that Axiom can start (Tiger Lake's TCO, or QEMU's ICH9)"
    stc
    jmp .out
.locked:
    KLOG "watchdog: the firmware keeps it from counting, or from resetting the machine"
    stc
    jmp .out
.usage:
    KLOG "usage: watchdog on [<seconds>]: %u to %u, %u unless said", WATCH_MIN, WATCH_MAX, WATCH_SECONDS
    stc
.out:
    pop rbx
    ret

; watch_net_show: what the watchdog does about the network. Preserves all.
watch_net_show:
    cmp qword [watch_net_secs], 0
    je .none
    KLOG "watchdog: and with no network for %u s, a full reset (its power cycled)", qword [watch_net_secs]
    ret
.none:
    KLOG "watchdog: the network is not watched ('watchdog net <seconds>' watches it)"
    ret

; watchdog net <seconds>|off: how long with no network before a full reset,
; while the watchdog is on (300 s unless said), or never
watch_cmd_net:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    cmp dword [rsi], 'off'              ; "off", and its terminating zero
    je .off
    call arg_uint
    jc .usage
    cmp eax, WATCH_NET_MIN
    jb .usage
    cmp eax, WATCH_NET_MAX
    ja .usage
    mov [watch_net_secs], rax
    mov byte [watch_net_set], 1
    RDTSC64
    mov [watch_net_seen], rax
    call watch_net_show
    clc
    ret
.off:
    mov qword [watch_net_secs], 0
    mov byte [watch_net_set], 1
    call watch_net_show
    clc
    ret
.usage:
    KLOG "usage: watchdog net <seconds>|off: %u to %u, %u unless said", WATCH_NET_MIN, WATCH_NET_MAX, WATCH_NET
    stc
    ret

; watchdog off
watch_cmd_off:
    cmp byte [watch_on], 0
    je .already
    mov byte [watch_on], 0
    call watch_halt
    KLOG "watchdog: off"
    clc
    ret
.already:
    KLOG "watchdog: off already"
    clc
    ret

; watchdog test: the main loop stopped here for good, interrupts on, for
; the watchdog's reset
watch_cmd_test:
    cmp byte [watch_on], 0
    je .off
    KLOG "watchdog test: the main loop stops here, interrupts on; the watchdog resets the machine at most %u s from now", qword [watch_secs]
.stop:
    sti
    hlt
    jmp .stop
.off:
    KLOG "watchdog test: only while the watchdog is on ('watchdog on')"
    stc
    ret

watch_actions:
    ACTION  '',     watch_show,     '', 'whether the watchdog is on: the chipset resets the machine when Axiom stops', 0
    ACTION  'on',   watch_cmd_on,   '[<seconds>]', "the TCO watchdog started, reloaded while Axiom's main loop goes round; a reset that long after it stops (120 s unless said)", 0
    ACTION  'net',  watch_cmd_net,  '<seconds>|off', 'while it is on: no network that long, a full reset, the power cycled (300 s unless said)', 0
    ACTION  'off',  watch_cmd_off,  '', 'the watchdog stopped', 0
    ACTION  'test', watch_cmd_test, '', 'with the watchdog on: the main loop stopped here for good, to see it reset the machine', 0
    dq 0, 0, 0, 0, 0

section .rodata
align 4
watch_v6_ids:   dd 0xA0A38086           ; Tiger Lake-LP's SMBus controller
                dd 0x43A38086           ; Tiger Lake-H's
                dd 0

section .bss
watch_on:       resb 1                  ; 'watchdog on': the main loop reloads it
watch_checked:  resb 1                  ; its count seen moving
watch_v6:       resb 1                  ; Tiger Lake's TCO: NO_REBOOT in TCO1_CNT
watch_reset:    resb 1                  ; it reset the machine before this start
watch_net_set:  resb 1                  ; 'watchdog net' said how long, or off
alignb 8
watch_net_secs: resq 1                  ; no network this long: a full reset; 0 never
watch_net_seen: resq 1                  ; TSC: the network last there (or the start)
watch_pet_at:   resq 1                  ; TSC: the next reload, at the soonest
watch_secs:     resq 1                  ; when it resets, after the last reload
watch_ticks:    resq 1                  ; its count from the top (TCO_TMR)
