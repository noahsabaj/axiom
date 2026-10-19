; =============================================================================
;  batterytest.asm - 'battery test': ec.asm and battery.asm against a
;  simulated embedded controller, put behind the same four port accesses
;  (ec_fake), with a battery that charges, holds or runs down a minute at a
;  time, and a clock of its own. The real EC is not touched, and the hold's
;  state is set aside and given back.
;
;  The simulation: 256 registers; a command or a byte taken leaves IBF set
;  for two status reads; HP's charge register (0x76) takes mode | 0x40 and
;  acknowledges it at the fourth read after; the charge left and when full
;  at 0xA0 and 0xA2 (words), the charger at 0xA4 bit 0, which reads 0 while
;  it runs the laptop from the battery, as HP's does; and a smart battery
;  behind an SMBus host at 0x40, done at the third status read.
; =============================================================================

FK_CHARGE       equ 0x76
FK_REM          equ 0xA0
FK_FULL         equ 0xA2
FK_AC           equ 0xA4
FK_SMB          equ 0x40
FK_STEP         equ 40                  ; a minute's charging: 1% of 4000
FK_IBF          equ 2                   ; status reads with IBF set, per byte

FS_IDLE         equ 0                   ; what the simulated EC waits for
FS_RADDR        equ 1
FS_WADDR        equ 2
FS_WVAL         equ 3

; BT cc, "what": a check, passed if the condition holds
%macro BT 2
    [section .rodata]
    %%t: db %2, 0
    __SECT__
    set%1 al
    movzx eax, al
    lea rsi, [%%t]
    call bt_result
%endmacro

section .text

; battery test: every check said; CF if one failed
battery_test:
    push rbx
    push r12
    push r13
    push r14
    lea rsi, [bat_state]                ; the real state aside
    lea rdi, [bt_saved]
    mov ecx, bat_state_end - bat_state
    rep movsb
    mov ax, [ec_cmd]
    mov [bt_ec_cmd], ax
    mov ax, [ec_data]
    mov [bt_ec_data], ax
    mov al, [ec_from]
    mov [bt_ec_from], al
    lea rdi, [bat_state]
    mov ecx, bat_state_end - bat_state
    xor eax, eax
    rep stosb
    call fake_reset
    mov byte [ec_fake], 1
    mov byte [ec_from], EC_FROM_BOARD
    lea rax, [bat_test_fields]
    mov [bat_board], rax
    mov dword [bt_count], 0
    mov dword [bt_passed], 0

    mov edi, 0x10                       ; the protocol
    mov esi, 0x5A
    call ec_write
    mov byte [fk_out], 0x33
    mov byte [fk_obf], 1
    mov edi, 0x10
    call ec_read
    cmp eax, 0x5A
    BT e, "a register written and read back, past a stale byte"
    xor ebx, ebx
    xor r12d, r12d
.all:
    mov edi, ebx
    call ec_read
    adc r12d, 0
    inc ebx
    cmp ebx, 256
    jb .all
    test r12d, r12d
    BT z, "all 256 registers read"

    mov edi, BM_INHIBIT                 ; HP's charge modes
    call bat_mode_set
    setnc bl
    cmp byte [fk_ram + FK_CHARGE], HP_ACK | BM_INHIBIT
    sete al
    and al, bl
    test al, al
    BT nz, "inhibit asked for and acknowledged (0xC5)"
    mov byte [fk_refuse], 1
    mov edi, BM_DISCHARGE
    call bat_mode_set
    setc bl
    mov byte [fk_refuse], 0
    lea rax, [str_bat_refused]
    cmp rsi, rax
    sete al
    and al, bl
    test al, al
    BT nz, "a mode the EC refuses: not taken, and said why"

    call bat_read                       ; readings
    setnc bl
    cmp dword [bat_percent], 90
    sete al
    and bl, al
    cmp byte [bat_ac], 1
    sete al
    and al, bl
    test al, al
    BT nz, "3600 of 4000 read as 90%, on its charger"

    mov edi, BM_NORMAL                  ; the hold: 40 minutes from 90%
    call bat_mode_set
    mov dword [bt_seq_n], 0
    mov dword [bt_min], 100
    mov dword [bt_max], 0
    mov r12d, 40
.hold:
    movzx r13d, byte [fk_mode]
    call bat_tick
    mov eax, [bat_percent]
    cmp eax, [bt_min]
    jae .not_min
    mov [bt_min], eax
.not_min:
    cmp eax, [bt_max]
    jbe .not_max
    mov [bt_max], eax
.not_max:
    movzx eax, byte [fk_mode]
    cmp eax, r13d
    je .same
    mov ecx, [bt_seq_n]
    cmp ecx, 8
    jae .same
    lea rdx, [bt_seq]
    mov [rdx + rcx], al
    inc dword [bt_seq_n]
.same:
    call fake_advance
    dec r12d
    jnz .hold
    cmp dword [bt_seq_n], 4
    jne .seq
    cmp dword [bt_seq], (BM_INHIBIT << 24) | (BM_NORMAL << 16) | (BM_INHIBIT << 8) | BM_DISCHARGE
.seq:
    BT e, "held: run down from 90%, stopped at 80%, charged at 75%, stopped at 80% again"
    cmp dword [bt_min], BAT_LOW
    setae bl
    cmp dword [bt_max], 90
    setbe al
    and al, bl
    test al, al
    BT nz, "never below 75% nor above where it began"

    mov byte [fk_ac], 0                 ; off its charger
    call bat_tick
    cmp byte [fk_mode], BM_NORMAL
    BT e, "off its charger: normal charging"
    call fake_advance
    mov byte [fk_ac], 1

    mov dword [fk_rem], 3300            ; no reading
    call bat_tick
    cmp byte [fk_mode], BM_INHIBIT
    sete bl
    mov dword [fk_full], 0
    call bat_tick
    mov dword [fk_full], 4000
    cmp byte [fk_mode], BM_NORMAL
    sete al
    and al, bl
    cmp qword [bat_fail], 0
    setne bl
    and al, bl
    test al, al
    BT nz, "a reading that makes no sense: normal charging, from inhibit at 82%"

    mov dword [fk_rem], 3600            ; a run-down that lowers nothing
    mov byte [fk_stuck], 1
    mov r12d, 13
.stuck:
    call bat_tick
    call fake_advance
    dec r12d
    jnz .stuck
    mov byte [fk_stuck], 0
    cmp byte [fk_mode], BM_INHIBIT
    sete bl
    cmp byte [bat_no_down], 1
    sete al
    and al, bl
    test al, al
    BT nz, "a run-down that lowers nothing in 10 minutes: given up, held where it is"

    call battery_leave                  ; a restart
    mov r12d, 5
.leave:
    call bat_mode_get
    dec r12d
    jnz .leave
    cmp byte [fk_mode], BM_NORMAL
    sete bl
    cmp byte [bat_changed], 0
    sete al
    and al, bl
    test al, al
    BT nz, "a restart: normal charging again"

    lea rax, [bat_test_smbus]           ; the smart battery
    mov [bat_board], rax
    mov dword [fk_rem], 3000
    call bat_read
    setnc bl
    cmp dword [bat_percent], 75
    sete al
    and al, bl
    test al, al
    BT nz, "through the SMBus host: 3000 of 4000 read as 75%"
    mov byte [fk_smb_fail], 1
    call bat_read
    mov byte [fk_smb_fail], 0
    BT c, "a smart battery that does not answer: no reading"

    mov byte [fk_dead], 1               ; an EC that answers nothing
    mov edi, FK_CHARGE
    call ec_read
    setc bl
    call bat_read
    setc al
    and al, bl
    lea rcx, [str_bat_silent]
    cmp rsi, rcx
    sete bl
    and al, bl
    test al, al
    BT nz, "an EC that does not answer: no reading, and said so"

    mov byte [ec_fake], 0               ; the real state again
    mov dword [ec_busy], 0
    mov ax, [bt_ec_cmd]
    mov [ec_cmd], ax
    mov ax, [bt_ec_data]
    mov [ec_data], ax
    mov al, [bt_ec_from]
    mov [ec_from], al
    lea rsi, [bt_saved]
    lea rdi, [bat_state]
    mov ecx, bat_state_end - bat_state
    rep movsb
    mov eax, [bt_passed]
    mov ecx, [bt_count]
    KLOG "battery test: %u of %u passed", rax, rcx
    cmp eax, ecx
    je .out                             ; (CF clear)
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; bt_result(EAX = passed, RSI = what). Preserves others.
bt_result:
    inc dword [bt_count]
    test eax, eax
    jz .failed
    inc dword [bt_passed]
    KLOG "battery test: ok: %s", rsi
    ret
.failed:
    KLOG "battery test: FAILED: %s", rsi
    ret

; fake_reset: the simulated EC, as it starts: normal charging, 3600 of
; 4000, on its charger
fake_reset:
    lea rdi, [fk_block]
    mov ecx, fk_block_end - fk_block
    xor eax, eax
    rep stosb
    mov byte [fk_pending], 0xFF
    mov byte [fk_ram + FK_CHARGE], HP_ACK | BM_NORMAL
    mov dword [fk_full], 4000
    mov dword [fk_rem], 3600
    mov byte [fk_ac], 1
    RDTSC64
    mov [fk_now], rax
    ret

; fake_advance: a minute: the charge as the mode and the charger make it
fake_advance:
    mov rax, [tsc_per_ms]
    imul rax, rax, 60000
    add [fk_now], rax
    cmp byte [fk_stuck], 0
    jne .out
    mov eax, [fk_rem]
    cmp byte [fk_ac], 0
    je .down
    cmp byte [fk_mode], BM_DISCHARGE
    je .down
    cmp byte [fk_mode], BM_INHIBIT
    je .idle
    add eax, FK_STEP                    ; charging
    cmp eax, [fk_full]
    jbe .set
    mov eax, [fk_full]
    jmp .set
.idle:
    sub eax, FK_STEP / 4                ; the laptop's own small draw
    jmp .set
.down:
    sub eax, FK_STEP
.set:
    mov [fk_rem], eax
.out:
    ret

; The four port accesses, simulated (ec.asm's contracts)
fake_status:
    cmp byte [fk_dead], 0
    jne .dead
    xor eax, eax
    cmp byte [fk_ibf], 0
    je .ibf
    dec byte [fk_ibf]
    mov eax, EC_IBF
.ibf:
    cmp byte [fk_obf], 0
    je .out
    or eax, EC_OBF
.out:
    ret
.dead:
    mov eax, 0xFF
    ret

fake_get:
    movzx eax, byte [fk_out]
    mov byte [fk_obf], 0
    ret

fake_command:
    cmp byte [fk_dead], 0
    jne .out
    mov byte [fk_ibf], FK_IBF
    mov byte [fk_state], FS_IDLE
    cmp al, EC_READ
    jne .not_read
    mov byte [fk_state], FS_RADDR
.not_read:
    cmp al, EC_WRITE
    jne .out
    mov byte [fk_state], FS_WADDR
.out:
    ret

fake_put:
    cmp byte [fk_dead], 0
    jne .out
    mov byte [fk_ibf], FK_IBF
    cmp byte [fk_state], FS_RADDR
    je .read_addr
    cmp byte [fk_state], FS_WADDR
    je .write_addr
    cmp byte [fk_state], FS_WVAL
    je .write_value
.out:
    ret
.read_addr:
    mov byte [fk_state], FS_IDLE
    push rax
    movzx eax, al
    call fake_reg_read
    mov [fk_out], al
    mov byte [fk_obf], 1
    pop rax
    ret
.write_addr:
    mov [fk_addr], al
    mov byte [fk_state], FS_WVAL
    ret
.write_value:
    mov byte [fk_state], FS_IDLE
    push rax
    push rdi
    movzx edi, byte [fk_addr]
    movzx eax, al
    call fake_reg_write
    pop rdi
    pop rax
    ret

; fake_reg_read(EAX = register) -> EAX = its byte. Preserves others.
fake_reg_read:
    push rcx
    cmp eax, FK_CHARGE
    je .charge
    cmp eax, FK_REM
    je .rem_lo
    cmp eax, FK_REM + 1
    je .rem_hi
    cmp eax, FK_FULL
    je .full_lo
    cmp eax, FK_FULL + 1
    je .full_hi
    cmp eax, FK_AC
    je .ac
    cmp eax, FK_SMB + SMB_STS
    je .smb_sts
    lea rcx, [fk_ram]
    movzx eax, byte [rcx + rax]
    jmp .out
.charge:
    cmp byte [fk_pending], 0xFF
    je .charge_now
    cmp byte [fk_ack], 0
    je .apply
    dec byte [fk_ack]
    jmp .charge_now
.apply:
    movzx eax, byte [fk_pending]
    mov byte [fk_pending], 0xFF
    cmp byte [fk_refuse], 0
    jne .refuse
    cmp eax, BM_NORMAL
    je .take
    cmp eax, BM_DISCHARGE
    je .take
    cmp eax, BM_INHIBIT
    jne .refuse
.take:
    mov [fk_mode], al
    or al, HP_ACK
    mov [fk_ram + FK_CHARGE], al
    jmp .charge_now
.refuse:
    movzx eax, byte [fk_mode]
    or al, HP_ACK | 0x10
    mov [fk_ram + FK_CHARGE], al
.charge_now:
    movzx eax, byte [fk_ram + FK_CHARGE]
    jmp .out
.rem_lo:
    movzx eax, byte [fk_rem]
    jmp .out
.rem_hi:
    movzx eax, byte [fk_rem + 1]
    jmp .out
.full_lo:
    movzx eax, byte [fk_full]
    jmp .out
.full_hi:
    movzx eax, byte [fk_full + 1]
    jmp .out
.ac:
    xor eax, eax
    cmp byte [fk_ac], 0
    je .out
    cmp byte [fk_mode], BM_DISCHARGE
    je .out                             ; run from the battery: the charger reads gone
    mov eax, 1
    jmp .out
.smb_sts:
    cmp byte [fk_smb_wait], 0
    je .sts_now
    dec byte [fk_smb_wait]
    jnz .sts_now
    mov al, [fk_smb_result]             ; done
    or al, SMB_DONE
    mov [fk_ram + FK_SMB + SMB_STS], al
    mov byte [fk_ram + FK_SMB + SMB_PRTCL], 0
.sts_now:
    movzx eax, byte [fk_ram + FK_SMB + SMB_STS]
.out:
    pop rcx
    ret

; fake_reg_write(EDI = register, EAX = its byte). Preserves all.
fake_reg_write:
    push rax
    push rcx
    lea rcx, [fk_ram]
    mov [rcx + rdi], al
    cmp edi, FK_CHARGE
    jne .smb
    test al, HP_ASK
    jz .out
    and al, 0x0F
    mov [fk_pending], al
    mov byte [fk_ack], 3
    jmp .out
.smb:
    cmp edi, FK_SMB + SMB_PRTCL
    jne .out
    cmp al, SMB_READ_WORD
    jne .out
    mov byte [fk_smb_wait], 3           ; a smart battery read, done soon
    mov byte [fk_smb_result], 0x10      ; (no device answered)
    cmp byte [fk_ram + FK_SMB + SMB_ADDR], SBS_ADDR
    jne .out
    cmp byte [fk_smb_fail], 0
    jne .out
    mov ax, [fk_rem]
    cmp byte [fk_ram + FK_SMB + SMB_CMD], SBS_REMAINING
    je .word
    mov ax, [fk_full]
    cmp byte [fk_ram + FK_SMB + SMB_CMD], SBS_FULL
    je .word
    mov byte [fk_smb_result], 0x12      ; (a command it does not have)
    jmp .out
.word:
    mov [fk_ram + FK_SMB + SMB_DATA], ax
    mov byte [fk_smb_result], 0
.out:
    pop rcx
    pop rax
    ret

align 8
bat_test_fields:
    BOARD 'test', 'fields', 'a simulated EC (registers)', 0x66, 0x62, FK_CHARGE, BR_FIELDS, FK_AC, 1, FK_REM, FK_REM + 1, FK_FULL, FK_FULL + 1, 0
bat_test_smbus:
    BOARD 'test', 'smbus', 'a simulated EC (smart battery)', 0x66, 0x62, FK_CHARGE, BR_SMBUS, FK_AC, 1, 0, 0, 0, 0, FK_SMB

section .bss
alignb 8
bt_saved:       resb 128                ; the hold's state, set aside
bt_count:       resd 1
bt_passed:      resd 1
bt_seq_n:       resd 1                  ; the modes the hold went through
bt_seq:         resb 8
bt_min:         resd 1                  ; and the charge's range
bt_max:         resd 1
bt_ec_cmd:      resw 1
bt_ec_data:     resw 1
bt_ec_from:     resb 1
alignb 8
fk_block:                               ; the simulated EC
fk_now:         resq 1                  ; its clock (TSC units)
fk_rem:         resd 1                  ; its battery
fk_full:        resd 1
fk_ram:         resb 256                ; its registers
fk_state:       resb 1                  ; FS_*
fk_addr:        resb 1
fk_out:         resb 1                  ; the byte in its data port
fk_obf:         resb 1
fk_ibf:         resb 1                  ; status reads left with IBF set
fk_dead:        resb 1                  ; 1: it answers nothing
fk_pending:     resb 1                  ; a mode asked for, or 0xFF
fk_ack:         resb 1                  ; reads of 0x76 before it answers
fk_mode:        resb 1                  ; the mode it runs
fk_refuse:      resb 1                  ; 1: it refuses the next mode
fk_ac:          resb 1                  ; 1: the charger is in
fk_stuck:       resb 1                  ; 1: the charge does not change
fk_smb_wait:    resb 1                  ; status reads before the SMBus is done
fk_smb_result:  resb 1
fk_smb_fail:    resb 1                  ; 1: the smart battery does not answer
fk_block_end:
