; =============================================================================
;  rtwmac.asm - the RTL8821CE's MAC, set up once its firmware runs: which
;  DMA channel each TX queue uses, how the 64 KiB TX FIFO is shared out,
;  the firmware's command queue in it, and the 802.11 timings and filters;
;  the TX rings' sending, and the firmware's packet commands. Part of the
;  rtw88 port (rtw.asm: the license, R12 = the chip's registers): mac.c
;  1087-1411, rtw8821c.c 207-267, pci.c 800-915, fw.c 507-568.
; =============================================================================

REG_RXFF_BNDY   equ 0x11C
REG_TRXFF_BNDY  equ 0x114
REG_AUTO_LLT    equ 0x208
REG_TXDMA_OFF   equ 0x20C
REG_FIFOPAGE3   equ 0x234               ; low queue pages (2), normal (3),
REG_FIFOPAGE4   equ 0x238               ; extra (4), public (5)
REG_FIFOPAGE5   equ 0x23C
REG_FIFOPAGE6   equ 0x240
REG_H2C_HEAD    equ 0x244
REG_H2C_TAIL    equ 0x248
REG_H2C_READ    equ 0x24C
REG_H2C_INFO    equ 0x254
REG_BCNQ_BDNY   equ 0x424
REG_BCNQ1_BDNY  equ 0x456
REG_RCR         equ 0x608
REG_WMAC_OPT    equ 0x7D0
REG_H2C_PKT_RD  equ 0x10D0
REG_H2C_PKT_WR  equ 0x10D4

; the TX FIFO: 512 pages of 128 bytes; the last 52 reserved (rtw_set_trx_
; fifo_info): 8 for the driver, 24 H2C extra info, 8 H2C static info, 8
; the H2C queue, 4 the firmware's TX buffer
RTW_RSVD_BOUNDARY equ 460
RTW_H2CQ_PAGE   equ 500
RTW_H2CQ_BYTES  equ 8 * 128
RTW_PUBQ        equ RTW_RSVD_BOUNDARY - 16 - 16 - 16 - 14 - 1

section .text

; rtw_mac_init(R12) -> CF (said why): rtw_mac_init for the 8821CE on PCI
; Express
rtw_mac_init:
    push rcx
    push rdx
    ; txdma_queue_mapping, rqpn_table_8821c[1]: VO, VI normal; BE, BK low;
    ; management extra; high high
    mov word [r12 + REG_PQ_MAP], (3 << 14) | (0 << 12) | (1 << 10) | (1 << 8) | (2 << 6) | (2 << 4)
    mov byte [r12 + REG_CR], 0
    mov byte [r12 + REG_CR], 0xFF       ; every DMA, the protocol, the MAC
    mov dword [r12 + REG_H2CQ_CSR], 0x80000000
    ; priority_queue_cfg, page_table_8821c[1]: 16 high, 16 normal, 16 low,
    ; 14 extra, 1 gap; the rest public
    mov word [r12 + REG_FIFOPAGE1], 16
    mov word [r12 + REG_FIFOPAGE3], 16
    mov word [r12 + REG_FIFOPAGE4], 16
    mov word [r12 + REG_FIFOPAGE5], 14
    mov word [r12 + REG_FIFOPAGE6], RTW_PUBQ
    or dword [r12 + REG_RQPN2], 0x80000000
    mov word [r12 + REG_FIFOPAGE2], RTW_RSVD_BOUNDARY
    mov word [rtw_rsvd_boundary], RTW_RSVD_BOUNDARY
    or byte [r12 + REG_FWHW_TXQ + 2], 0x10
    mov word [r12 + REG_BCNQ_BDNY], RTW_RSVD_BOUNDARY
    mov word [r12 + REG_FIFOPAGE2 + 2], RTW_RSVD_BOUNDARY
    mov word [r12 + REG_BCNQ1_BDNY], RTW_RSVD_BOUNDARY
    mov dword [r12 + REG_RXFF_BNDY], 16384 - 256 - 1   ; RX FIFO less the C2H buffer
    or byte [r12 + REG_AUTO_LLT], 1
    RTW_POLL32 REG_AUTO_LLT, 1, 0
    jc .llt
    mov byte [r12 + REG_CR + 3], 0
    ; init_h2c: the firmware's command queue, pages 500-507
    mov eax, [r12 + REG_H2C_HEAD]
    and eax, 0xFFFC0000
    or eax, RTW_H2CQ_PAGE * 128
    mov [r12 + REG_H2C_HEAD], eax
    mov eax, [r12 + REG_H2C_READ]
    and eax, 0xFFFC0000
    or eax, RTW_H2CQ_PAGE * 128
    mov [r12 + REG_H2C_READ], eax
    mov eax, [r12 + REG_H2C_TAIL]
    and eax, 0xFFFC0000
    or eax, RTW_H2CQ_PAGE * 128 + RTW_H2CQ_BYTES
    mov [r12 + REG_H2C_TAIL], eax
    mov al, [r12 + REG_H2C_INFO]
    and al, 0xFC
    or al, 0x01
    mov [r12 + REG_H2C_INFO], al
    mov al, [r12 + REG_H2C_INFO]
    and al, 0xFB
    or al, 0x04
    mov [r12 + REG_H2C_INFO], al
    or byte [r12 + REG_TXDMA_OFF + 1], 0x80
    mov ecx, [r12 + REG_H2C_PKT_WR]     ; the queue must be empty
    and ecx, 0x3FFFF
    mov edx, [r12 + REG_H2C_PKT_RD]
    and edx, 0x3FFFF
    cmp ecx, edx
    jne .h2cq
    ; rtw8821c_mac_init: protocol
    mov byte [r12 + 0x455], 0x70        ; A-MPDU: longest time
    or byte [r12 + 0x45E], 0x04         ; TX hang: end of frame
    mov byte [r12 + 0x4E5], 0xE4        ; pre-TX count: 0x1E4, on (bytes:
    mov byte [r12 + 0x4E6], 0x09        ; the register is not aligned)
    mov dword [r12 + 0x4C8], 0xFF | (0x08 << 8) | (0x20 << 16) | (0x20 << 24)
    mov word [r12 + 0x4CE], 0x01 | (0x08 << 8)  ; BAR retries, RA tries
    mov byte [r12 + 0x1448], 6          ; fast EDCA thresholds
    mov byte [r12 + 0x144A], 6
    mov byte [r12 + 0x144C], 6
    mov byte [r12 + 0x144E], 6
    or byte [r12 + 0x480], 0x20
    ; EDCA
    and byte [r12 + 0x5B4], ~0x70       ; timer 0 from the TSF
    mov word [r12 + 0x522], 0           ; no queue paused
    mov byte [r12 + 0x51B], 9           ; slot
    mov byte [r12 + 0x512], 0x19        ; PIFS
    mov dword [r12 + 0x514], 0x0A | (0x0E << 8) | (0x10 << 16) | (0x10 << 24) ; SIFS
    mov word [r12 + 0x502], 0x186       ; VO TXOP
    mov word [r12 + 0x506], 0x3BC       ; VI TXOP
    mov dword [r12 + 0x544], 0x05 | (0x1B << 16)    ; NAV
    mov word [r12 + 0x55E], 0x30 | (0x30 << 8)      ; RX TSF offsets
    or byte [r12 + REG_BCN_CTRL], 0x08  ; the TSF on
    mov dword [r12 + 0x540], 0x04 | (0x64 << 8)     ; TBTT
    mov byte [r12 + 0x558], 0x04
    mov byte [r12 + 0x559], 0x02
    and byte [r12 + 0x521], ~0x10
    ; WMAC
    mov word [r12 + 0x6A0], 0xFFFF      ; RX filters: management,
    mov word [r12 + 0x6A2], 0x0FFF      ;   control,
    mov word [r12 + 0x6A4], 0xFFFF      ;   data
    mov dword [r12 + REG_RCR], 0xE400220E
    mov byte [r12 + 0x60C], 12288 >> 9  ; largest frame, in 512s
    mov byte [r12 + 0x606], 0x30
    mov byte [r12 + 0x605], 0x30
    mov byte [r12 + 0x639], 0x40        ; CCK ACK timeout
    or byte [r12 + 0x66C], 0x02
    or byte [r12 + 0x718], 0x40         ; no VHT-SIG-B CRC check
    mov dword [r12 + REG_WMAC_OPT + 8], 0xB0810041
    mov byte [r12 + REG_WMAC_OPT + 4], 0x98
    ; rtw_drv_info_cfg: a PHY status with each frame
    mov byte [r12 + 0x60F], 4
    mov al, [r12 + REG_TRXFF_BNDY + 1]
    and al, 0xF0
    or al, 0x0F
    mov [r12 + REG_TRXFF_BNDY + 1], al
    or dword [r12 + REG_RCR], 1 << 28
    and dword [r12 + REG_WMAC_OPT + 4], ~((1 << 8) | (1 << 9))
    clc
    jmp .out
.llt:
    KLOG "wifi: the TX FIFO's page list did not set up"
    stc
    jmp .out
.h2cq:
    KLOG "wifi: the firmware's command queue is not empty (%x, %x)", rcx, rdx
    stc
.out:
    pop rdx
    pop rcx
    ret

; rtw_tx_put(R12, EDX = queue (RQ_*), RSI = a packet: its 48-byte TX
; descriptor and what follows, ECX = its length) -> CF if the ring is full
; (or the packet too long for its buffers): copied into the ring's next
; buffer, its descriptor filled, the chip told. Preserves all but RAX.
rtw_tx_put:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    imul ebx, edx, RTR_SIZE
    lea rax, [rtw_tx]
    add rbx, rax
    cmp ecx, [rbx + RTR_BUFSZ]
    ja .full
    mov edx, [rbx + RTR_IDX]
    mov eax, [r12 + rdx]                ; the chip's read index
    shr eax, 16
    and eax, 0xFFF
    mov [rbx + RTR_RP], eax
    mov r8d, [rbx + RTR_WP]
    cmp eax, r8d                        ; free: rp - wp - 1, around the ring
    ja .ahead
    add eax, [rbx + RTR_LEN]
.ahead:
    sub eax, r8d
    cmp eax, 1
    jbe .full
    mov eax, r8d
    imul eax, [rbx + RTR_BUFSZ]
    mov rdi, [rbx + RTR_BUF]
    add rdi, rax
    push rdi
    push rcx
    rep movsb
    pop rcx
    pop rax
    RTW_PHYS
    mov rdi, r8
    shl rdi, 4
    add rdi, [rbx + RTR_BD]
    lea edx, [ecx - 1]                  ; 128-byte pages
    shr edx, 7
    inc edx
    shl edx, 16
    or edx, 48
    mov [rdi], edx                      ; the descriptor,
    mov [rdi + 4], eax
    lea edx, [ecx - 48]
    mov [rdi + 8], edx                  ;   then what follows it
    add eax, 48
    mov [rdi + 12], eax
    inc r8d
    cmp r8d, [rbx + RTR_LEN]
    jb .wp
    xor r8d, r8d
.wp:
    mov [rbx + RTR_WP], r8d
    mov edx, [rbx + RTR_IDX]
    mov [r12 + rdx], r8w                ; go
    clc
    jmp .out
.full:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_h2c_pkt(R12, RSI = a 32-byte packet command, its sequence number
; left to fill) -> CF (said why) if the H2C ring is full: on the H2C
; ring, as rtw_pci_write_data_h2c sends it. Preserves all but RAX.
rtw_h2c_pkt:
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [rtw_h2c_buf]
    mov ecx, (48 + 32) / 8
    xor eax, eax
    rep stosq
    lea rdi, [rtw_h2c_buf]
    mov dword [rdi], 32                 ; its length; no offset
    mov dword [rdi + 4], 19 << 8        ; queue: H2C
    add rdi, 48
    mov ecx, 32
    rep movsb
    mov ax, [rtw_h2c_seq]
    mov [rtw_h2c_buf + 48 + 6], ax
    inc word [rtw_h2c_seq]
    mov edx, RQ_H2C
    lea rsi, [rtw_h2c_buf]
    mov ecx, 48 + 32
    call rtw_tx_put
    jnc .out
    movzx eax, byte [rtw_h2c_buf + 48 + 2]
    KLOG "wifi: firmware packet command %02x dropped: the H2C ring is full", rax
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_fw_info(R12) -> CF (said why): the two packet commands sent once
; per power-on, after the MAC and the PHY are set up: GENERAL_INFO (where
; the firmware's TX buffer is) and PHYDM_INFO (the board), then a wait of
; up to 10 ms for the chip to take them off the ring
rtw_fw_info:
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [rtw_h2c_cmd]
    mov rdi, rsi
    mov ecx, 32 / 8
    xor eax, eax
    rep stosq
    mov dword [rsi], 0x000DFF01         ; category 1, packet, GENERAL_INFO
    mov word [rsi + 4], 8 + 4
    mov byte [rsi + 10], 508 - RTW_RSVD_BOUNDARY    ; the firmware's TX buffer, from the boundary
    call rtw_h2c_pkt
    jc .out
    mov rdi, rsi
    mov ecx, 32 / 8
    xor eax, eax
    rep stosq
    mov dword [rsi], 0x0011FF01         ; PHYDM_INFO
    mov word [rsi + 4], 8 + 8
    mov al, [rtw_rfe]
    mov [rsi + 8], al
    mov byte [rsi + 9], 4               ; one stream each way
    mov eax, [rtw_cut]
    mov [rsi + 10], al
    mov byte [rsi + 11], 0x11           ; antenna A, TX and RX
    call rtw_h2c_pkt
    jc .out
    mov edx, RQ_H2C
    imul edx, edx, RTR_SIZE
    lea rcx, [rtw_tx]
    mov edx, [rcx + rdx + RTR_WP]
    mov ecx, 1000
.wait:
    mov eax, [r12 + 0x132C]
    shr eax, 16
    and eax, 0xFFF
    cmp eax, edx
    je .taken
    mov edi, 10
    call delay_us
    dec ecx
    jnz .wait
    KLOG "wifi: the chip did not take the firmware's packet commands (read %u, written %u)", rax, rdx
    stc
    jmp .out
.taken:
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

section .bss
alignb 8
rtw_h2c_buf:    resb 48 + 32
rtw_h2c_cmd:    resb 32
