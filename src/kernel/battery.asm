; =============================================================================
;  battery.asm - a laptop that lives on its charger, its battery kept between
;  75% and 80% ('battery hold'): a battery kept full and warm wears fast and
;  can swell. As fleet's battery-hold does under Linux on hp-1
;  (fleet: src/fleet/recipes/battery-hold.py), the charging is stopped and
;  started with HP's charge modes in the embedded controller (ec.asm): the
;  register the firmware's own charge-mode method writes (SBCO, HP WMI
;  command 0x2B), mode | 0x40, which the EC acknowledges by setting 0x80;
;  0x10 or 0x20 there, it refused. 0 is normal charging, 5 stops it (0xC5),
;  2 runs the laptop from its battery with the charger in (0xC2, about
;  2.4 A on hp-1). From 85% it runs down to 80%; at 80% charging stops; at
;  75% it charges again.
;
;  No AML runs here, so what the firmware's _BST and _PSR would read (the
;  charge left, the charge when full, the charger) comes from the board
;  table: the EC registers its DSDT names for them, or the smart battery
;  through the EC's SMBus host (ACPI 6.5, 13.9). tools/hw/ecmap.py finds
;  them in a DSDT. A board not in the table is left alone.
;
;  The hold is a tick each minute (each 20 s while it runs down) from the
;  main loop. No reading, a reading that makes no sense, or a run-down that
;  lowers nothing in 10 minutes puts it back to normal charging (or holds it
;  where it is, for the last), as every restart and power-off does
;  (battery_leave): with Axiom gone, the firmware charges as it likes.
; =============================================================================

BAT_LOW         equ 75                  ; at or below: charge
BAT_HIGH        equ 80                  ; at or above: stop; from 85, run down
BAT_TICK_S      equ 60
BAT_DOWN_S      equ 20                  ; the tick while it runs down
BAT_STUCK_S     equ 600                 ; a run-down lowering nothing this long

BM_NORMAL       equ 0                   ; HP's charge modes
BM_DISCHARGE    equ 2
BM_INHIBIT      equ 5
BM_ASKED        equ 0xFE                ; asked for, not yet acknowledged
BM_ODD          equ 0xFF                ; none of them

HP_ASK          equ 0x40                ; the charge register
HP_ACK          equ 0x80
HP_REFUSED      equ 0x30

BR_UNKNOWN      equ 0                   ; BB_READ: how the charge is read
BR_FIELDS       equ 1                   ; EC registers, as its _BST reads them
BR_SMBUS        equ 2                   ; the smart battery, by the EC's SMBus

SBS_ADDR        equ 0x16                ; the smart battery (0x0B), shifted
SBS_REMAINING   equ 0x0F                ; its commands (Smart Battery Data 1.1)
SBS_FULL        equ 0x10
SMB_PRTCL       equ 0                   ; the EC's SMBus host, from its base
SMB_STS         equ 1
SMB_ADDR        equ 2
SMB_CMD         equ 3
SMB_DATA        equ 4
SMB_READ_WORD   equ 0x09
SMB_DONE        equ 0x80

BB_VENDOR       equ 0                   ; a board: its SMBIOS maker (type 2)
BB_BOARD        equ 8                   ; its name
BB_MODEL        equ 16                  ; what it is, for people
BB_CMD          equ 24                  ; word: the EC's ports, without an ECDT
BB_DATA         equ 26
BB_CHARGE       equ 28                  ; byte: HP's charge register
BB_READ         equ 29                  ; BR_*
BB_AC           equ 30                  ; the register saying "on its charger"
BB_AC_BIT       equ 31                  ; and its bit
BB_REM          equ 32                  ; BR_FIELDS: the charge left, low byte
BB_REM_HI       equ 33                  ; and high
BB_FULL         equ 34                  ; the charge when full
BB_FULL_HI      equ 35
BB_SMB          equ 36                  ; BR_SMBUS: the SMBus host's base
BB_SIZE         equ 40

; BOARD maker, name, model, command port, data port, charge register, how
; it is read, charger register, its bit, left low, high, full low, high,
; SMBus base
%macro BOARD 14
    dq %%v, %%b, %%m
    dw %4, %5
    db %6, %7, %8, %9, %10, %11, %12, %13, %14, 0, 0, 0
    [section .rodata]
    %%v: db %1, 0
    %%b: db %2, 0
    %%m: db %3, 0
    __SECT__
%endmacro

section .text

; battery_init: after acpi_init and smbios_init. The EC's ports, and the
; board, if the table has it.
battery_init:
    push rbx
    call ec_init
    lea rbx, [bat_boards]
.next:
    mov rdi, [rbx + BB_VENDOR]
    test rdi, rdi
    jz .none
    lea rsi, [sm_board_vendor]
    call streq
    test eax, eax
    jz .skip
    mov rdi, [rbx + BB_BOARD]
    lea rsi, [sm_board_product]
    call streq
    test eax, eax
    jnz .found
.skip:
    add rbx, BB_SIZE
    jmp .next
.found:
    mov [bat_board], rbx
    movzx edi, word [rbx + BB_CMD]
    movzx esi, word [rbx + BB_DATA]
    call ec_use
    call bat_ports
    KLOG "battery: %s (%s %s), its EC at %x/%x (%s)", qword [rbx + BB_MODEL], qword [rbx + BB_VENDOR], qword [rbx + BB_BOARD], rax, rcx, rdx
.none:
    pop rbx
    ret

; bat_ports -> RAX, RCX = the EC's command and data ports, RDX = where they
; came from (text). Preserves others.
bat_ports:
    movzx eax, word [ec_cmd]
    movzx ecx, word [ec_data]
    lea rdx, [str_bat_ecdt]
    cmp byte [ec_from], EC_FROM_ECDT
    je .out
    lea rdx, [str_bat_table]
.out:
    ret

; battery_service: from the main loop. The hold's tick, when it is time.
battery_service:
    cmp byte [bat_hold], 0
    je .out
    RDTSC64
    cmp rax, [bat_next]
    jb .out
    call bat_tick
.out:
    ret

; battery_leave: from power_reboot and power_off, on any CPU, after a panic
; too: normal charging again if Axiom asked for another mode. Only tries
; (ec_busy). Preserves all.
battery_leave:
    cmp byte [bat_changed], 0
    je .out
    push rax
    push rdi
    push rsi
    mov rax, [bat_board]
    movzx edi, byte [rax + BB_CHARGE]
    mov esi, HP_ASK | BM_NORMAL
    call ec_write
    jc .done
    mov byte [bat_changed], 0
    KLOG "battery: normal charging, for the restart or power-off"
    mov edi, 100000                     ; a moment for the EC to take it
    call delay_us
.done:
    pop rsi
    pop rdi
    pop rax
.out:
    ret

; bat_clock -> RAX = now (TSC; the simulated EC's clock in 'battery test').
; Clobbers RDX.
bat_clock:
    cmp byte [ec_fake], 0
    jne .fake
    RDTSC64
    ret
.fake:
    mov rax, [fk_now]
    ret

; bat_tick: the hold's minute. The charge read, and the mode it calls for
; set; with no reading, normal charging. The main thread's.
bat_tick:
    push rbx
    push r12
    inc dword [bat_ticks]
    call bat_clock
    mov r12, rax
    call bat_read
    jc .no_reading
    mov qword [bat_fail], 0
    cmp byte [bat_mode], BM_DISCHARGE   ; a run-down: is it lowering the charge?
    jne .not_down
    cmp qword [bat_down_at], 0
    je .progress
    mov eax, [bat_percent]
    cmp eax, [bat_down_pct]
    jb .progress
    mov rax, r12
    sub rax, [bat_down_at]
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, BAT_STUCK_S * 1000
    cmp rax, rcx
    jb .decide
    cmp byte [bat_no_down], 0
    jne .decide
    mov byte [bat_no_down], 1
    mov eax, [bat_percent]
    KLOG "battery: %u%% after %u s running from the battery, no lower: held where it is instead, until the next start", rax, BAT_STUCK_S
    jmp .decide
.progress:
    mov [bat_down_at], r12
    mov eax, [bat_percent]
    mov [bat_down_pct], eax
    jmp .decide
.not_down:
    mov qword [bat_down_at], 0
.decide:
    mov edi, [bat_percent]
    movzx esi, byte [bat_ac]
    movzx edx, byte [bat_mode]
    call bat_wanted
    cmp eax, BM_DISCHARGE
    jne .want
    cmp byte [bat_no_down], 0
    je .want
    mov eax, BM_INHIBIT
.want:
    movzx ecx, byte [bat_mode]
    cmp eax, ecx
    je .next
    mov ebx, eax
    mov edi, eax
    call bat_mode_set
    jc .not_set
    mov eax, ebx
    call bat_mode_name
    mov eax, [bat_percent]
    KLOG "battery: %u%%: %s", rax, rsi
    jmp .next
.not_set:
    mov rdx, rsi
    mov eax, ebx
    call bat_mode_name
    mov eax, [bat_percent]
    KLOG "battery: %u%%: %s asked for, but %s", rax, rsi, rdx
    jmp .next
.no_reading:
    cmp rsi, [bat_fail]
    je .safe
    mov [bat_fail], rsi
    KLOG "battery: no reading (%s): normal charging until there is one", rsi
.safe:
    cmp byte [bat_changed], 0
    je .next
    mov edi, BM_NORMAL
    call bat_mode_set
    jc .next
    KLOG "battery: normal charging again"
.next:
    mov rax, [tsc_per_ms]
    imul rax, rax, BAT_TICK_S * 1000
    cmp byte [bat_mode], BM_DISCHARGE
    jne .later
    mov rax, [tsc_per_ms]
    imul rax, rax, BAT_DOWN_S * 1000
.later:
    add rax, r12
    mov [bat_next], rax
    pop r12
    pop rbx
    ret

; bat_wanted(EDI = percent, ESI = on its charger, EDX = mode) -> EAX = the
; mode it calls for: fleet's wanted(). Running down, the charger is not
; asked: HP's EC reports it gone while it runs the laptop from the battery.
bat_wanted:
    cmp edx, BM_DISCHARGE
    jne .not_down
    mov eax, BM_DISCHARGE
    cmp edi, BAT_HIGH
    ja .out
    mov eax, BM_INHIBIT
    ret
.not_down:
    mov eax, BM_NORMAL
    test esi, esi
    jz .out                             ; off its charger: as the firmware likes
    mov eax, BM_DISCHARGE
    cmp edi, BAT_HIGH + 5
    jae .out
    mov eax, BM_NORMAL
    cmp edi, BAT_LOW
    jbe .out
    mov eax, BM_INHIBIT
    cmp edi, BAT_HIGH
    jae .out
    cmp edx, BM_INHIBIT
    je .out                             ; between: as it was going
    mov eax, BM_NORMAL
.out:
    ret

; bat_read -> CF: no reading (RSI = why). Else bat_percent, bat_rem,
; bat_full, bat_ac, bat_mode and bat_reg. Clobbers RAX, RCX, RDX, RSI.
bat_read:
    push rbx
    push rdi
    push r12
    mov rbx, [bat_board]
    call bat_mode_get
    jc .silent
    movzx edi, byte [rbx + BB_AC]
    call ec_read
    jc .silent
    test al, [rbx + BB_AC_BIT]
    setnz byte [bat_ac]
    cmp byte [rbx + BB_READ], BR_FIELDS
    je .fields
    cmp byte [rbx + BB_READ], BR_SMBUS
    je .smbus
    lea rsi, [str_bat_unknown]
    jmp .fail
.fields:
    movzx edi, byte [rbx + BB_REM]
    movzx esi, byte [rbx + BB_REM_HI]
    call bat_word
    jc .silent
    mov r12d, eax
    movzx edi, byte [rbx + BB_FULL]
    movzx esi, byte [rbx + BB_FULL_HI]
    call bat_word
    jc .silent
    jmp .check
.smbus:
    mov edi, SBS_REMAINING
    call bat_smb_word
    jc .smb_fail
    mov r12d, eax
    mov edi, SBS_FULL
    call bat_smb_word
    jc .smb_fail
.check:
    mov [bat_rem], r12d
    mov [bat_full], eax
    test eax, eax
    jz .no_full
    cmp eax, 0xFFFF
    je .no_full
    mov ecx, eax
    shr ecx, 4
    add ecx, eax                        ; full, and a sixteenth more
    cmp r12d, ecx
    ja .too_much
    mov ecx, eax
    imul eax, r12d, 100
    xor edx, edx
    div ecx
    cmp eax, 100
    jbe .percent
    mov eax, 100
.percent:
    mov [bat_percent], eax
    clc
    jmp .out
.no_full:
    lea rsi, [str_bat_no_full]
    jmp .fail
.too_much:
    lea rsi, [str_bat_too_much]
    jmp .fail
.smb_fail:
    lea rsi, [str_bat_smb]
    jmp .fail
.silent:
    lea rsi, [str_bat_silent]
.fail:
    stc
.out:
    pop r12
    pop rdi
    pop rbx
    ret

; bat_word(EDI = low byte's register, ESI = high byte's) -> EAX; CF if the
; EC did not answer. Clobbers RDI.
bat_word:
    push rcx
    call ec_read
    jc .out
    mov ecx, eax
    mov edi, esi
    call ec_read
    jc .out
    shl eax, 8
    or eax, ecx
.out:
    pop rcx
    ret

; bat_smb_word(EDI = a smart battery command) -> EAX = its word; CF: none.
; Through the EC's SMBus host: address, command, then the protocol, which
; starts it; done when the status says so and the protocol is 0 again.
; Clobbers RDI.
bat_smb_word:
    push rcx
    push rsi
    push r12
    push r13
    mov r12d, edi
    mov rax, [bat_board]
    movzx r13d, byte [rax + BB_SMB]
    lea edi, [r13 + SMB_PRTCL]
    call ec_read
    jc .fail
    test eax, eax
    jnz .fail                           ; one under way, not ours
    lea edi, [r13 + SMB_STS]
    xor esi, esi                        ; the last one's status cleared
    call ec_write
    jc .fail
    lea edi, [r13 + SMB_ADDR]
    mov esi, SBS_ADDR
    call ec_write
    jc .fail
    lea edi, [r13 + SMB_CMD]
    mov esi, r12d
    call ec_write
    jc .fail
    lea edi, [r13 + SMB_PRTCL]
    mov esi, SMB_READ_WORD
    call ec_write
    jc .fail
    mov ecx, 100                        ; 200 ms
.poll:
    mov edi, 2000
    call delay_us
    lea edi, [r13 + SMB_STS]
    call ec_read
    jc .fail
    test al, SMB_DONE
    jz .again
    test al, 0x1F
    jnz .fail                           ; done, with an error
    lea edi, [r13 + SMB_PRTCL]
    call ec_read
    jc .fail
    test eax, eax
    jz .done
.again:
    dec ecx
    jnz .poll
.fail:
    stc
    jmp .out
.done:
    lea edi, [r13 + SMB_DATA]
    lea esi, [r13 + SMB_DATA + 1]
    call bat_word
.out:
    pop r13
    pop r12
    pop rsi
    pop rcx
    ret

; bat_mode_get -> EAX = BM_*, as bat_mode; bat_reg its register; CF if the
; EC did not answer. Preserves others.
bat_mode_get:
    push rdi
    mov rax, [bat_board]
    movzx edi, byte [rax + BB_CHARGE]
    call ec_read
    jc .out
    mov [bat_reg], al
    test al, HP_ACK
    jz .asked
    and eax, 0x0F
    cmp eax, BM_NORMAL
    je .ok
    cmp eax, BM_DISCHARGE
    je .ok
    cmp eax, BM_INHIBIT
    je .ok
    mov eax, BM_ODD
    jmp .ok
.asked:
    mov eax, BM_ASKED
.ok:
    mov [bat_mode], al
    clc
.out:
    pop rdi
    ret

; bat_mode_set(EDI = BM_NORMAL, _DISCHARGE or _INHIBIT) -> CF: not taken
; (RSI = why). Asked for, and its answer awaited, up to 2 s. The main
; thread's. Preserves others.
bat_mode_set:
    push rax
    push rbx
    push rcx
    push rdi
    push r12
    mov r12d, edi
    mov rbx, [bat_board]
    cmp r12d, BM_NORMAL
    je .ask
    mov byte [bat_changed], 1           ; undone by battery_leave
.ask:
    movzx edi, byte [rbx + BB_CHARGE]
    lea esi, [r12 + HP_ASK]
    call ec_write
    jc .silent
    mov ecx, 200
.poll:
    call bat_mode_get
    jc .silent
    cmp eax, BM_ASKED
    jne .answered
    mov edi, 10000
    call delay_us
    dec ecx
    jnz .poll
    lea rsi, [str_bat_no_answer]
    jmp .fail
.answered:
    test byte [bat_reg], HP_REFUSED
    jnz .refused
    cmp eax, r12d
    jne .other
    cmp r12d, BM_NORMAL
    jne .ok
    mov byte [bat_changed], 0
.ok:
    clc
    jmp .out
.silent:
    lea rsi, [str_bat_silent]
    jmp .fail
.refused:
    lea rsi, [str_bat_refused]
    jmp .fail
.other:
    lea rsi, [str_bat_other]
.fail:
    stc
.out:
    pop r12
    pop rdi
    pop rcx
    pop rbx
    pop rax
    ret

; bat_mode_name(EAX = BM_*) -> RSI = its name. Preserves others.
bat_mode_name:
    lea rsi, [str_bm_normal]
    cmp eax, BM_NORMAL
    je .out
    lea rsi, [str_bm_discharge]
    cmp eax, BM_DISCHARGE
    je .out
    lea rsi, [str_bm_inhibit]
    cmp eax, BM_INHIBIT
    je .out
    lea rsi, [str_bm_asked]
    cmp eax, BM_ASKED
    je .out
    lea rsi, [str_bm_odd]
.out:
    ret

; bat_usable(EDI = 1: its charge must be readable) -> CF: no (RSI = why).
; Preserves others.
bat_usable:
    push rax
    lea rsi, [str_bat_no_board]
    mov rax, [bat_board]
    test rax, rax
    jz .no
    lea rsi, [str_bat_no_ec]
    cmp byte [ec_from], 0
    je .no
    test edi, edi
    jz .yes
    lea rsi, [str_bat_unknown]
    cmp byte [rax + BB_READ], BR_UNKNOWN
    je .no
.yes:
    pop rax
    clc
    ret
.no:
    pop rax
    stc
    ret

; battery: the board, the charge, the charger, the mode; the hold
battery_show:
    push rbx
    mov rbx, [bat_board]
    test rbx, rbx
    jnz .board
    lea rax, [sm_board_vendor]
    lea rcx, [sm_board_product]
    cmp byte [rcx], 0
    je .nameless
    KLOG "battery: not a board Axiom holds the battery of (SMBIOS: %s %s)", rax, rcx
    jmp .ec
.nameless:
    KLOG "battery: not a board Axiom holds the battery of (SMBIOS names none)"
.ec:
    cmp byte [ec_from], 0
    je .out
    call bat_ports
    KLOG "battery: an embedded controller at %x/%x (%s)", rax, rcx, rdx
    jmp .out
.board:
    call bat_ports
    KLOG "battery: %s (%s %s), its EC at %x/%x (%s)", qword [rbx + BB_MODEL], qword [rbx + BB_VENDOR], qword [rbx + BB_BOARD], rax, rcx, rdx
    cmp byte [rbx + BB_READ], BR_UNKNOWN
    jne .read
    call bat_mode_get
    jc .silent
    call bat_mode_name
    movzx eax, byte [rbx + BB_CHARGE]
    movzx ecx, byte [bat_reg]
    KLOG "battery: charging: %s (EC register %x: %x); how to read its charge is not known yet", rsi, rax, rcx
    jmp .hold
.read:
    call bat_read
    jc .no_reading
    lea rdx, [str_bat_on]
    cmp byte [bat_ac], 0
    jne .charger
    lea rdx, [str_bat_off]
.charger:
    movzx eax, byte [bat_mode]
    call bat_mode_name
    mov eax, [bat_percent]
    mov ecx, [bat_rem]
    mov edi, [bat_full]
    movzx r8d, byte [rbx + BB_CHARGE]
    movzx r9d, byte [bat_reg]
    KLOG "battery: %u%% (%u of %u), %s; charging: %s (EC register %x: %x)", rax, rcx, rdi, rdx, rsi, r8, r9
    jmp .hold
.silent:
    lea rsi, [str_bat_silent]
.no_reading:
    KLOG "battery: no reading: %s", rsi
.hold:
    cmp byte [bat_hold], 0
    je .not_held
    KLOG "battery: held between %u%% and %u%% ('battery hold off' stops it), %u ticks so far", BAT_LOW, BAT_HIGH, qword [bat_ticks]
    jmp .out
.not_held:
    KLOG "battery: not held ('battery hold' keeps it between %u%% and %u%%)", BAT_LOW, BAT_HIGH
.out:
    pop rbx
    clc
    ret

; battery hold [off]: kept between 75% and 80%, a tick each minute; or not
battery_hold:
    cmp edi, 1
    ja .usage
    jb .on
    mov rdi, [rsi]
    lea rsi, [str_bat_word_off]
    call streq
    test eax, eax
    jz .usage
    mov byte [bat_hold], 0
    KLOG "battery: not held"
    cmp byte [bat_changed], 0
    je .ok
    mov edi, BM_NORMAL
    call bat_mode_set
    jc .not_normal
    KLOG "battery: normal charging again"
    jmp .ok
.not_normal:
    KLOG "battery: normal charging asked for, but %s", rsi
    stc
    ret
.on:
    mov edi, 1
    call bat_usable
    jc .cannot
    mov byte [bat_hold], 1
    mov byte [bat_no_down], 0
    mov qword [bat_fail], 0
    mov qword [bat_next], 0             ; the first tick now
    KLOG "battery: held between %u%% and %u%%, by stopping and starting its charging", BAT_LOW, BAT_HIGH
.ok:
    clc
    ret
.cannot:
    KLOG "battery: not held: %s", rsi
    stc
    ret
.usage:
    KLOG "usage: battery hold [off]"
    stc
    ret

; battery mode normal|inhibit|discharge: how it charges, by hand
battery_mode:
    cmp edi, 1
    jne .usage
    mov rdi, [rsi]
    lea rsi, [str_bm_normal]
    xor ecx, ecx
    call streq
    test eax, eax
    jnz .mode
    lea rsi, [str_bm_inhibit]
    mov ecx, BM_INHIBIT
    call streq
    test eax, eax
    jnz .mode
    lea rsi, [str_bm_discharge]
    mov ecx, BM_DISCHARGE
    call streq
    test eax, eax
    jz .usage
.mode:
    cmp byte [bat_hold], 0
    jne .held
    xor edi, edi
    call bat_usable
    jc .cannot
    mov edi, ecx
    call bat_mode_set
    jc .not_set
    mov eax, ecx
    call bat_mode_name
    KLOG "battery: charging: %s", rsi
    clc
    ret
.not_set:
    mov rdx, rsi
    mov eax, ecx
    call bat_mode_name
    KLOG "battery: %s asked for, but %s", rsi, rdx
    stc
    ret
.held:
    KLOG "battery: held: 'battery hold off' first"
    stc
    ret
.cannot:
    KLOG "battery: %s", rsi
    stc
    ret
.usage:
    KLOG "usage: battery mode normal|inhibit|discharge"
    stc
    ret

; battery ec: the embedded controller's 256 registers, read
battery_ec:
    push rbx
    push r12
    cmp byte [ec_from], 0
    je .none
    xor ebx, ebx
.row:
    xor r12d, r12d
.byte:
    lea edi, [rbx + r12]
    call ec_read
    jc .silent
    lea rcx, [bat_line]
    mov [rcx + r12 * 8], rax
    inc r12d
    cmp r12d, 16
    jb .byte
    KLOG "  %02x: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x", rbx, qword [bat_line], qword [bat_line + 8], qword [bat_line + 16], qword [bat_line + 24], qword [bat_line + 32], qword [bat_line + 40], qword [bat_line + 48], qword [bat_line + 56], qword [bat_line + 64], qword [bat_line + 72], qword [bat_line + 80], qword [bat_line + 88], qword [bat_line + 96], qword [bat_line + 104], qword [bat_line + 112], qword [bat_line + 120]
    add ebx, 16
    cmp ebx, 256
    jb .row
    clc
    jmp .out
.silent:
    lea eax, [rbx + r12]
    KLOG "battery: the EC did not answer, at register %x", rax
    stc
    jmp .out
.none:
    KLOG "battery: no embedded controller known here"
    stc
.out:
    pop r12
    pop rbx
    ret

align 8
bat_boards:
    ; hp-1. The charge register: tried under Linux (fleet, 2026-10-12).
    ; How its charge is read: from its DSDT, still to be read.
    BOARD 'HP', '87FE', 'HP Laptop 15-dy2xxx', 0x66, 0x62, 0x76, BR_UNKNOWN, 0, 0, 0, 0, 0, 0, 0
    dq 0

battery_actions:
    ACTION  '',      battery_show, '', 'the charge, the charger, how it charges; the hold', 0
    ACTION  'hold',  battery_hold, '[off]', 'kept between 75% and 80%, by stopping and starting its charging (a laptop that lives on its charger)', 0
    ACTION  'mode',  battery_mode, 'normal|inhibit|discharge', 'how it charges, set by hand (the hold off)', 0
    ACTION  'ec',    battery_ec,   '', "the embedded controller's 256 registers, read", 0
    ACTION  'test',  battery_test, '', 'a self-test, against a simulated EC', 0
    dq 0, 0, 0, 0, 0

section .rodata
str_bat_ecdt:       db 'ECDT', 0
str_bat_table:      db 'the board table', 0
str_bat_on:         db 'on its charger', 0
str_bat_off:        db 'off its charger', 0
str_bat_word_off:   db 'off', 0
str_bm_normal:      db 'normal', 0
str_bm_discharge:   db 'discharge', 0
str_bm_inhibit:     db 'inhibit', 0
str_bm_asked:       db 'asked for, not yet acknowledged', 0
str_bm_odd:         db 'none Axiom knows', 0
str_bat_silent:     db 'the EC does not answer', 0
str_bat_no_answer:  db 'the EC has not acknowledged it', 0
str_bat_refused:    db 'the EC refused it', 0
str_bat_other:      db 'the EC runs another mode', 0
str_bat_no_board:   db 'not a board Axiom holds the battery of', 0
str_bat_no_ec:      db 'no embedded controller known here', 0
str_bat_unknown:    db "how to read this board's charge is not known yet", 0
str_bat_no_full:    db 'no charge when full', 0
str_bat_too_much:   db 'more charge left than it holds when full', 0
str_bat_smb:        db 'the smart battery does not answer', 0

section .bss
alignb 8
bat_line:       resq 16                 ; battery ec: a row
bat_state:                              ; (battery test sets it aside)
bat_board:      resq 1                  ; the board's entry, or 0
bat_next:       resq 1                  ; TSC: the next tick
bat_down_at:    resq 1                  ; a run-down began, or last lowered it
bat_fail:       resq 1                  ; why the last tick had no reading
bat_rem:        resd 1                  ; the last reading
bat_full:       resd 1
bat_percent:    resd 1
bat_down_pct:   resd 1                  ; the charge, at bat_down_at
bat_ticks:      resd 1
bat_hold:       resb 1                  ; 1: held
bat_mode:       resb 1                  ; BM_*, as last read
bat_reg:        resb 1                  ; the charge register, as last read
bat_ac:         resb 1                  ; 1: on its charger
bat_changed:    resb 1                  ; a mode not normal asked for
bat_no_down:    resb 1                  ; run-downs given up, until a start
bat_state_end:
