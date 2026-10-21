; =============================================================================
;  rtwphy.asm - the RTL8821CE's radio: the baseband and RF register tables
;  (src/kernel/gen/rtw8821c.inc, with the conditions rtw88 parses), RF
;  register access, the channel (20 MHz, 2.4 and 5 GHz), TX power, and the
;  Bluetooth coexistence settings that give Wi-Fi the antenna. Part of the
;  rtw88 port (rtw.asm: the license, R12 = the chip's registers): phy.c,
;  rtw8821c.c 158-205, 278-383, 445-586, 684-722, coex.c.
; =============================================================================

; RTW_SETF offset, mask, value already in place: (R32 & ~mask) | value
%macro RTW_SETF 3
    mov eax, [r12 + %1]
    and eax, ~(%2)
    or eax, (%3) & (%2)
    mov [r12 + %1], eax
%endmacro

; RTW_SETR offset, mask, register: the same, the value in a register
%macro RTW_SETR 3
    mov eax, [r12 + %1]
    and eax, ~(%2)
    or eax, %3
    mov [r12 + %1], eax
%endmacro

; the internal RF switch (switch_rf_set)
RTW_SW_BTG      equ 0                   ; 2.4 GHz through the Bluetooth path
RTW_SW_WLG      equ 1                   ; 2.4 GHz, Wi-Fi's own
RTW_SW_WLA      equ 2                   ; 5 GHz

section .text

%include "gen/rtw8821c.inc"

section .text

; rtw_rf_read(R12, ESI = RF register) -> EAX = its 20 bits: path A, read
; through the baseband's window. Preserves all but RAX.
rtw_rf_read:
    push rsi
    and esi, 0xFF
    mov eax, [r12 + 0x2800 + rsi * 4]
    and eax, 0xFFFFF
    pop rsi
    ret

; rtw_rf_write(R12, ESI = RF register, EDX = mask (0xFFFFF: all of it),
; ECX = value, put in at the mask's lowest bit): path A, through its
; serial port; 13 us. Preserves all but RAX.
rtw_rf_write:
    push rcx
    push rdx
    push rdi
    mov edi, ecx
    and edx, 0xFFFFF
    cmp edx, 0xFFFFF
    je .whole
    bsf ecx, edx
    shl edi, cl
    and edi, edx
    call rtw_rf_read
    not edx
    and eax, edx
    or edi, eax
.whole:
    mov eax, esi
    and eax, 0xFF
    shl eax, 20
    and edi, 0xFFFFF
    or eax, edi
    mov [r12 + 0xC90], eax
    mov edi, 13
    call delay_us
    pop rdi
    pop rdx
    pop rcx
    ret

; rtw_table(R12, RSI = a register table, RDI = its end, EDX = what its
; pairs are: 0 MAC bytes, 1 baseband dwords, 2 RF registers) -> EAX =
; registers written: rtw_parse_tbl_phy_cond, its IF/ELIF/ELSE/ENDIF blocks
; taken for this board (rtw_cond)
rtw_table:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    push r11
    mov r11d, edx
    mov r8d, 1                          ; what follows is taken
    xor r9d, r9d                        ; a branch was taken already
    xor r10d, r10d                      ; the condition last named
    mov dword [rtw_tbl_n], 0
.pair:
    cmp rsi, rdi
    jae .done
    mov eax, [rsi]
    mov ebx, [rsi + 4]
    add rsi, 8
    test eax, eax
    jns .not_header
    mov ecx, eax
    shr ecx, 28
    and ecx, 3
    cmp ecx, 3
    je .endif
    cmp ecx, 2
    je .else
    mov r10d, eax                       ; IF, ELIF: named; checked next
    jmp .pair
.endif:
    mov r8d, 1
    xor r9d, r9d
    jmp .pair
.else:
    mov r8d, 1
    sub r8d, r9d
    jmp .pair
.not_header:
    test eax, 0x40000000
    jz .config
    test r9d, r9d
    jnz .passed
    call rtw_cond
    jnc .fails
    mov r8d, 1
    mov r9d, 1
    jmp .pair
.fails:
    xor r8d, r8d
    jmp .pair
.passed:
    xor r8d, r8d
    jmp .pair
.config:
    test r8d, r8d
    jz .pair
    inc dword [rtw_tbl_n]
    cmp r11d, 1
    jb .mac
    ja .rf
    lea ecx, [eax - 0xF9]               ; baseband: 0xF9-0xFE are waits
    cmp ecx, 5
    ja .bb
    push rdi
    lea rdx, [rtw_bb_waits]
    mov edi, [rdx + rcx * 4]
    call delay_us
    pop rdi
    jmp .pair
.bb:
    mov [r12 + rax], ebx
    jmp .pair
.mac:
    mov [r12 + rax], bl
    jmp .pair
.rf:
    push rdi
    cmp eax, 0xFFE
    je .rf_long
    cmp eax, 0xFE
    je .rf_short
    push rsi
    mov esi, eax
    mov edx, 0xFFFFF
    mov ecx, ebx
    call rtw_rf_write
    pop rsi
    mov edi, 1
    jmp .rf_wait
.rf_long:
    mov edi, 50000
    jmp .rf_wait
.rf_short:
    mov edi, 110
.rf_wait:
    call delay_us
    pop rdi
    jmp .pair
.done:
    mov eax, [rtw_tbl_n]
    pop r11
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_cond(R10D = a table's condition) -> CF if it holds for this board:
; check_positive. A cut, package or bus of 0 means any; the RF front end
; must match.
rtw_cond:
    push rcx
    mov eax, r10d
    shr eax, 24
    and eax, 0xF
    jz .pkg
    mov ecx, [rtw_cut]
    test ecx, ecx
    jnz .cut
    mov ecx, 15
.cut:
    cmp eax, ecx
    jne .no
.pkg:
    mov eax, r10d
    shr eax, 12
    and eax, 0xF
    jz .bus
    movzx ecx, byte [rtw_pkg]
    test ecx, ecx
    jnz .pkg_known
    mov ecx, 15
.pkg_known:
    cmp eax, ecx
    jne .no
.bus:
    mov eax, r10d
    shr eax, 8
    and eax, 0xF
    jz .rfe
    cmp eax, 1                          ; PCI Express
    jne .no
.rfe:
    mov al, r10b
    cmp al, [rtw_rfe]
    jne .no
    stc
    jmp .out
.no:
    clc
.out:
    pop rcx
    ret

; rtw_phy_init(R12): rtw8821c_phy_set_param: the baseband and RF powered
; and reset, every table in, the crystal's trim, the beamforming defaults
rtw_phy_init:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov al, [r12 + REG_SYS_FUNC_EN]
    or al, 0x40
    mov [r12 + REG_SYS_FUNC_EN], al
    or al, 0x03
    mov [r12 + REG_SYS_FUNC_EN], al
    and al, ~0x03
    mov [r12 + REG_SYS_FUNC_EN], al     ; the baseband reset,
    or al, 0x03
    mov [r12 + REG_SYS_FUNC_EN], al     ;   and out of it
    mov byte [r12 + REG_RF_CTRL], 0x07
    mov edi, 10
    call delay_us
    mov byte [r12 + REG_WLRF1 + 3], 0x07
    call delay_us
    and dword [r12 + 0x808], ~0x30000000
    lea rsi, [rtwt_mac]
    lea rdi, [rtwt_mac_end]
    xor edx, edx
    call rtw_table
    mov ebx, eax
    lea rsi, [rtwt_bb]
    lea rdi, [rtwt_bb_end]
    mov edx, 1
    call rtw_table
    mov ecx, eax
    lea rsi, [rtwt_agc]
    lea rdi, [rtwt_agc_end]
    call rtw_table
    mov r8d, eax
    mov al, [rtw_rfe]
    cmp al, 2
    je .btg
    cmp al, 4
    jne .rf
.btg:
    lea rsi, [rtwt_agc_btg2]            ; 2.4 GHz through the Bluetooth path
    lea rdi, [rtwt_agc_btg2_end]
    call rtw_table
    add r8d, eax
.rf:
    lea rsi, [rtwt_rf_a]                ; with its calibrations: ~0.4 s
    lea rdi, [rtwt_rf_a_end]
    mov edx, 2
    call rtw_table
    mov r9d, eax
    KLOG "wifi: register tables: MAC %u, baseband %u, AGC %u, RF %u", rbx, rcx, r8, r9
    movzx ecx, byte [rtw_ef + EF_XTAL]  ; the crystal's trim
    cmp ecx, 0xFF
    jne .cap
    xor ecx, ecx
.cap:
    and ecx, 0x3F
    mov edx, ecx
    shl edx, 25
    RTW_SETR 0x24, 0x7E000000, edx
    mov edx, ecx
    shl edx, 1
    RTW_SETR 0x28, 0x7E, edx
    and dword [r12 + 0xA2C], ~0x00440000
    or dword [r12 + 0x808], 0x30000000
    mov eax, [r12 + 0xA24]              ; the CCK filters 2.4 GHz channels go back to
    mov [rtw_ch_param], eax
    mov eax, [r12 + 0xA28]
    mov [rtw_ch_param + 4], eax
    mov eax, [r12 + 0xAAC]
    mov [rtw_ch_param + 8], eax
    mov eax, [r12 + 0x14C0]             ; beamforming defaults (it stays off)
    or eax, 0x10000
    and eax, ~0xF000
    or eax, 0xA000
    and eax, ~0xBF
    mov [r12 + 0x14C0], eax
    mov byte [r12 + 0x167C], 0x70
    mov word [r12 + 0x1680], 0
    or dword [r12 + 0x42C], 0x40000000
    mov byte [r12 + 0x45F], 0x10
    RTW_SETF 0x6DC, 0x3F000000, 4 << 24
    mov dword [r12 + 0x1C94], 0xAFFFAFFF
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_coex_init(R12): Bluetooth coexistence with Wi-Fi owning the antenna
; for good: the grants forced in software, no time-sharing, the antenna
; switch held by the baseband (coex.md's recipe; rtw_coex_power_on_setting
; and init_hw_config as Linux runs them with Bluetooth idle)
rtw_coex_init:
    push rcx
    push rdx
    push rsi
    push rdi
    or byte [r12 + REG_SYS_FUNC_EN], 0x03
    mov eax, 0xFFFFFFFF
    test byte [rtw_ef + EF_BT], 1       ; one antenna, shared
    jz .table
    mov eax, 0x55555555
.table:
    mov [r12 + 0x6C0], eax
    mov [r12 + 0x6C4], eax
    mov dword [r12 + 0x6C8], 0xF0FFFFFF
    mov byte [r12 + 0xFF1A], 0
    and dword [r12 + 0x64], ~((1 << 20) | (1 << 24) | (1 << 15))
    and dword [r12 + 0x40], ~(1 << 19)
    and dword [r12 + 0x70], ~((1 << 18) | (1 << 27))
    mov eax, 0x00010C69                 ; no slot extension
    xor edx, edx
    call rtw_h2c
    or byte [r12 + REG_BCN_CTRL], 0x08
    mov al, [r12 + 0x790]
    and al, ~0x3F
    or al, 0x05
    mov [r12 + 0x790], al
    mov byte [r12 + 0x778], 0x01
    or dword [r12 + 0x40], (1 << 5) | (1 << 9)
    or byte [r12 + 0x4C6], 0x10
    and byte [r12 + 0x4C6], ~0x20
    or word [r12 + 0x762], 0x1000
    or byte [r12 + 0x6CF], 0x08
    or byte [r12 + 0x6CC], 0x18
    call rtw_btg
    jnc .grants
    mov ecx, 60                         ; Bluetooth's own calibration done
.rfk:
    test word [r12 + 0xAA], 0x0020
    jnz .rfk_wait
    test byte [r12 + 0x49C], 0x01
    jz .grants
.rfk_wait:
    mov edi, 10000
    call delay_us
    dec ecx
    jnz .rfk
.grants:
    mov esi, 0x38                       ; Bluetooth's grant low, Wi-Fi's high
    call rtw_lte_read
    jc .owner
    and eax, ~0xFF00
    or eax, 0x7700
    mov edx, eax
    call rtw_lte_write
.owner:
    or byte [r12 + 0x73], 0x04          ; Wi-Fi owns the coexistence path
    cmp byte [rtw_rfe], 6
    je .board                           ; (no antenna switch)
    and dword [r12 + 0x4C], ~(1 << 23)
    or dword [r12 + 0x4C], 1 << 24
    mov byte [r12 + 0xCB4], 0x77
    RTW_SETF 0xCB4, 0xF0000000, 2 << 28 ; the 2.4 GHz position
    or byte [r12 + 0x67], 0x30
.board:
    mov word [r12 + 0xAA], 0x8003       ; to Bluetooth: Wi-Fi active, on
    xor edx, edx
    test byte [rtw_ef + EF_BT], 1
    jnz .tdma
    mov edx, 0x40
.tdma:
    mov eax, 0x00000060                 ; no time-sharing
    call rtw_h2c
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_btg -> CF if 2.4 GHz goes through the Bluetooth path (RFE 2, 4)
rtw_btg:
    cmp byte [rtw_rfe], 2
    je .yes
    cmp byte [rtw_rfe], 4
    je .yes
    clc
    ret
.yes:
    stc
    ret

; rtw_set_channel(R12, ECX = channel: 1-13, or 36-165): 20 MHz there;
; rtw_set_channel and rtw8821c_set_channel; then its TX power
rtw_set_channel:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, ecx
    cmp ebx, 14
    ja .bb5
    or dword [r12 + 0x808], 0x10000000  ; CCK on
    and dword [r12 + 0x454], ~0x80
    and dword [r12 + 0xA80], ~0x40000
    RTW_SETF 0x814, 0xFC00, 15 << 10
    RTW_SETF 0xC1C, 0xF00, 0
    RTW_SETF 0x860, 0x1FFE0000, 0x96A << 17
    mov eax, [rtw_ch_param]
    mov [r12 + 0xA24], eax
    mov edx, [rtw_ch_param + 4]
    and edx, 0xFFFF
    RTW_SETR 0xA28, 0xFFFF, edx
    mov eax, [rtw_ch_param + 8]
    mov [r12 + 0xAAC], eax
    mov byte [rtw_band], 1
    jmp .bw
.bb5:
    or dword [r12 + 0xA80], 0x40000     ; CCK off
    or dword [r12 + 0x454], 0x80
    and dword [r12 + 0x808], ~0x10000000
    RTW_SETF 0x814, 0xFC00, 15 << 10
    mov edx, 1 << 8                     ; 36-64
    mov ecx, 0x494 << 17
    cmp ebx, 48
    jbe .agc5
    mov ecx, 0x453 << 17
    cmp ebx, 64
    jbe .agc5
    mov edx, 2 << 8                     ; 100-144
    mov ecx, 0x452 << 17
    cmp ebx, 116
    jbe .agc5
    mov ecx, 0x412 << 17
    cmp ebx, 144
    jbe .agc5
    mov edx, 3 << 8                     ; 149-
.agc5:
    RTW_SETR 0xC1C, 0xF00, edx
    RTW_SETR 0x860, 0x1FFE0000, ecx
    mov byte [rtw_band], 2
.bw:
    mov eax, [r12 + 0x8AC]              ; 20 MHz, no sub-channel
    and eax, 0xFFCFFC00
    or eax, 0x10010000
    mov [r12 + 0x8AC], eax
    or dword [r12 + 0x8C4], 0x40000000
    movzx eax, byte [rtw_ef + EF_SWING_2G]  ; the baseband's TX swing
    cmp ebx, 14
    jbe .swing
    movzx eax, byte [rtw_ef + EF_SWING_5G]
.swing:
    cmp eax, 9
    jbe .swing_ok
    xor eax, eax
.swing_ok:
    xor edx, edx
    mov ecx, 3
    div ecx
    lea rdx, [rtw_swing]
    movzx edx, word [rdx + rax * 2]
    shl edx, 21
    RTW_SETR 0xC1C, 0xFFE00000, edx
    mov byte [r12 + 0x483], 0           ; MAC: 20 MHz
    and dword [r12 + 0x668], ~0x180
    and dword [r12 + 0x24], ~0x00300000
    mov byte [r12 + 0x55C], 0x50
    mov byte [r12 + 0x638], 0x50
    mov al, [r12 + 0x454]
    and al, ~0x80
    cmp ebx, 14
    jbe .cck_check
    or al, 0x80
.cck_check:
    mov [r12 + 0x454], al
    mov esi, 0x18                       ; RF: band, channel, sub-band, 20 MHz
    call rtw_rf_read
    mov edi, eax
    and edi, ~0x70FFF
    or edi, ebx
    or edi, 0x0C00
    cmp ebx, 14
    jbe .rf2
    or edi, 0x10100
    cmp ebx, 100
    jb .rf5
    or edi, 0x20000
    cmp ebx, 140
    jbe .rf5
    xor edi, 0x60000                    ; above 140: the other sub-band bit
.rf5:
    mov ecx, RTW_SW_WLA
    call rtw_rf_switch
    mov esi, 0xDF
    mov edx, 0x40
    xor ecx, ecx
    call rtw_rf_write
    jmp .rf18
.rf2:
    mov ecx, RTW_SW_WLG
    call rtw_btg
    jnc .rf2_switch
    mov ecx, RTW_SW_BTG
.rf2_switch:
    call rtw_rf_switch
    mov esi, 0xDF
    mov edx, 0x40
    mov ecx, 1
    call rtw_rf_write
    mov esi, 0x64
    mov edx, 0x0F
    mov ecx, 0x0F
    call rtw_rf_write
.rf18:
    mov esi, 0x18
    mov edx, 0xFFFFF
    mov ecx, edi
    call rtw_rf_write
    mov esi, 0xB8                       ; the crystal doubler, toggled
    mov edx, 0x80000
    xor ecx, ecx
    call rtw_rf_write
    mov ecx, 1
    call rtw_rf_write
    RTW_SETF 0x948, 0x30000000, 2 << 28 ; RX filters for 20 MHz
    RTW_SETF 0x94C, 0x30000000, 2 << 28
    or dword [r12 + 0xC20], 0x80000000
    and dword [r12 + 0x8F0], ~0x80000000
    cmp byte [rtw_rfe], 0               ; the antenna switch's band position:
    jne .power                          ; only RFE 0's differs by band
    mov edx, 2 << 28
    cmp ebx, 14
    jbe .pos
    mov edx, 1 << 28
.pos:
    RTW_SETR 0xCB4, 0xF0000000, edx
.power:
    mov [rtw_channel], bl
    mov ecx, ebx
    call rtw_tx_power
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_rf_switch(R12, ECX = RTW_SW_*): switch_rf_set, the internal RF
; switch for the band
rtw_rf_switch:
    push rdx
    or dword [r12 + REG_CPU_DMEM], 0x10000
    or dword [r12 + 0], 0x04000000
    mov edx, [r12 + 0xCB8]
    cmp ecx, RTW_SW_WLG
    je .wlg
    ja .wla
    or edx, 0x010000                    ; BTG
    and edx, ~0xF40000
    RTW_SETF 0xA84, 0xFF0000, 0x0E << 16
    RTW_SETF 0xA80, 0xFFFF, 0xFC84
    jmp .set
.wlg:
    or edx, 0x700000
    and edx, ~0x850000
    RTW_SETF 0xA84, 0xFF0000, 0x12 << 16
    RTW_SETF 0xA80, 0xFFFF, 0x7532
    jmp .set
.wla:
    or edx, 0xD00000
    and edx, ~0x250000
.set:
    mov [r12 + 0xCB8], edx
    pop rdx
    ret

; rtw_tx_power(R12, ECX = channel): each rate's power index on path A:
; the efuse's base for the channel's group, plus rtw88's step for the rate
; or the worldwide limit if that is lower, 0-63. A blank efuse byte gives
; a middling 0x20 (Linux would send at full power).
rtw_tx_power:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea rdi, [rtw_pwr]
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [rdi + 16], rax
    mov [rdi + 24], rax
    mov [rdi + 32], rax
    mov [rdi + 40], rax
    mov [rdi + 48], rax
    mov ebx, ecx
    cmp ebx, 14
    ja .five
    lea rax, [rtw_grp2g]
    movzx r8d, byte [rax + rbx]         ; the channel's group
    mov r9d, EF_TXPWR                   ; path A's 2.4 GHz block,
    call rtw_btg
    jnc .block
    mov r9d, EF_TXPWR + 42              ; or path B's (RFE 2, 4)
.block:
    lea r10, [rtw_ef]
    add r10, r9
    movzx eax, byte [r10 + r8]          ; CCK
    call rtw_pwr_base
    lea rsi, [rtw_d_cck]
    lea rdx, [rtw_lim2g_cck]
    movsx edx, byte [rdx + rbx]
    mov ecx, 4
    lea rdi, [rtw_pwr]
    call rtw_pwr_rates
    movzx eax, byte [r10 + 6 + r8]      ; the 40 MHz base, and the steps from it
    call rtw_pwr_base
    mov r9d, eax
    movsx eax, byte [r10 + 11]
    shl eax, 28
    sar eax, 28
    add eax, r9d                        ; OFDM
    lea rsi, [rtw_d_ofdm]
    lea rdx, [rtw_lim2g_ofdm]
    movsx edx, byte [rdx + rbx]
    mov ecx, 8
    lea rdi, [rtw_pwr + 4]
    call rtw_pwr_rates
    movsx eax, byte [r10 + 11]
    sar eax, 4
    add eax, r9d                        ; HT, VHT at 20 MHz
    lea rsi, [rtw_d_ht]
    lea rdx, [rtw_lim2g_ht]
    movsx edx, byte [rdx + rbx]
    mov ecx, 8
    lea rdi, [rtw_pwr + 12]
    call rtw_pwr_rates
    mov edx, 63                         ; VHT: no 2.4 GHz limit
    lea rsi, [rtw_d_vht]
    mov ecx, 10
    lea rdi, [rtw_pwr + 44]
    call rtw_pwr_rates
    jmp .write
.five:
    lea rsi, [rtw_grp5g]
.find:
    movzx eax, byte [rsi]
    cmp eax, 0
    je .write                           ; not a channel we know
    cmp ebx, eax
    jbe .found
    add rsi, 2
    jmp .find
.found:
    movzx r8d, byte [rsi + 1]
    lea r10, [rtw_ef + EF_TXPWR + 0x12]
    movzx eax, byte [r10 + r8]          ; the 40 MHz base
    call rtw_pwr_base
    mov r9d, eax
    mov ecx, ebx                        ; the worldwide limits
    call rtw_lim5g
    movsx eax, byte [r10 + 14]
    shl eax, 28
    sar eax, 28
    add eax, r9d
    push rdx
    mov edx, ecx                        ; OFDM's limit
    lea rsi, [rtw_d_ofdm]
    mov ecx, 8
    lea rdi, [rtw_pwr + 4]
    call rtw_pwr_rates
    pop rdx                             ; HT's
    movsx eax, byte [r10 + 14]
    sar eax, 4
    add eax, r9d
    mov r8d, eax
    lea rsi, [rtw_d_ht]
    mov ecx, 8
    lea rdi, [rtw_pwr + 12]
    call rtw_pwr_rates
    mov eax, r8d
    lea rsi, [rtw_d_vht]
    mov ecx, 10
    lea rdi, [rtw_pwr + 44]
    call rtw_pwr_rates
.write:
    lea rsi, [rtw_pwr]
    mov eax, [rsi]
    mov [r12 + 0x1D00], eax
    mov eax, [rsi + 4]
    mov [r12 + 0x1D04], eax
    mov eax, [rsi + 8]
    mov [r12 + 0x1D08], eax
    mov eax, [rsi + 12]
    mov [r12 + 0x1D0C], eax
    mov eax, [rsi + 16]
    mov [r12 + 0x1D10], eax
    mov eax, [rsi + 44]
    mov [r12 + 0x1D2C], eax
    mov eax, [rsi + 48]
    mov [r12 + 0x1D30], eax
    mov eax, [rsi + 52]
    mov [r12 + 0x1D34], eax
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_pwr_base(EAX = an efuse power byte) -> EAX: it, or 0x20 if blank
rtw_pwr_base:
    cmp eax, 0xFF
    jne .ok
    mov eax, 0x20
    mov byte [rtw_pwr_blank], 1
.ok:
    ret

; rtw_pwr_rates(EAX = the section's base, RSI = its steps (signed bytes),
; EDX = its limit, ECX = rates, RDI = where their indexes go): each base +
; min(step, limit), within 0-63. Preserves all.
rtw_pwr_rates:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    mov r8d, eax
.rate:
    movsx ebx, byte [rsi]
    cmp ebx, edx
    jle .lower
    mov ebx, edx
.lower:
    add ebx, r8d
    jns .floor
    xor ebx, ebx
.floor:
    cmp ebx, 63
    jbe .put
    mov ebx, 63
.put:
    mov [rdi], bl
    inc rsi
    inc rdi
    dec ecx
    jnz .rate
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rtw_lim5g(ECX = a 5 GHz channel) -> ECX = OFDM's worldwide limit, EDX =
; HT's and VHT's, each relative to the section's base (phy.md 3.6)
rtw_lim5g:
    mov edx, 3
    cmp ecx, 48
    jne .not48
    mov edx, 2
.not48:
    cmp ecx, 52
    jne .not52
    mov ecx, -10
    mov edx, -17
    ret
.not52:
    cmp ecx, 144
    jne .not144
    mov ecx, 4
    ret
.not144:
    cmp ecx, 149
    jb .default
    mov ecx, -12
    mov edx, -10
    ret
.default:
    mov ecx, 1
    ret

section .rodata
rtw_bb_waits:   dd 1, 5, 50, 1000, 5000, 50000      ; table addresses 0xF9-0xFE
rtw_swing:      dw 0x200, 0x16A, 0x101, 0x0B6       ; TX scale by the efuse's swing / 3
; 2.4 GHz channel groups, by channel (0-14)
rtw_grp2g:      db 0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3, 4, 4, 4
; 5 GHz: the last channel of each group, and the group
rtw_grp5g:      db 42, 0, 50, 1, 58, 2, 64, 3, 106, 4, 114, 5, 122, 6, 130, 7
                db 138, 8, 144, 9, 155, 10, 161, 11, 171, 12, 177, 13, 0, 0
; each rate's step from its section's base rate (bb_pg_type0)
rtw_d_cck:      db 6, 4, 2, 0
rtw_d_ofdm:     db 8, 8, 8, 8, 6, 4, 2, 0
rtw_d_ht:       db 10, 10, 10, 8, 6, 4, 2, 0
rtw_d_vht:      db 10, 10, 10, 8, 6, 4, 2, 0, -2, -4
; worldwide limits at 2.4 GHz, by channel (0-14), from the section's base
rtw_lim2g_cck:  db 0, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -4, -8, -16, -16
rtw_lim2g_ofdm: db 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, -2, -6, -10, -26, -26
rtw_lim2g_ht:   db 0, 0, 4, 4, 4, 4, 4, 4, 4, 4, -2, -6, -10, -26, -26

section .bss
rtw_ch_param:   resd 3                  ; 0xA24, 0xA28, 0xAAC as the tables left them
rtw_pwr:        resb 56                 ; power index by rate (DESC_RATE order)
rtw_tbl_n:      resd 1
rtw_channel:    resb 1
rtw_pwr_blank:  resb 1                  ; an efuse power byte was blank
