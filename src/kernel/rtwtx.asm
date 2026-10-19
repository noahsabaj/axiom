; =============================================================================
;  rtwtx.asm - frames out through the RTL8821CE: the station's port (its
;  address, rtw_ops_add_interface) and management frames on the MGMT ring
;  (tx.c's rtw_tx_fill_tx_desc for a frame mac80211 sends without a
;  station: the lowest rate of the band, the chip's sequence numbers).
;  Part of the rtw88 port (rtw.asm: the license, R12 = the chip's
;  registers).
; =============================================================================

REG_MACID       equ 0x610               ; port 0: its address,
REG_BSSID       equ 0x618               ;   its network's
RTW_QSEL_MGMT   equ 18

section .text

; rtw_port_init(R12): port 0 as a station not yet on a network: its
; address from the efuse, no BSSID (byte writes: the registers are not
; aligned to their size)
rtw_port_init:
    push rcx
    xor ecx, ecx
.byte:
    mov al, [rtw_mac + rcx]
    mov [r12 + REG_MACID + rcx], al
    mov byte [r12 + REG_BSSID + rcx], 0
    inc ecx
    cmp ecx, 6
    jb .byte
    and byte [r12 + REG_CR + 2], ~3     ; net type: no link
    pop rcx
    ret

; rtw_mgmt_send(R12, RSI = an 802.11 management frame, no FCS (the chip
; adds it), ECX = its length) -> CF if the MGMT ring is full: at the
; band's lowest rate, no fallback, sequence numbered by the chip.
; Preserves all but RAX.
rtw_mgmt_send:
    push rcx
    push rdx
    push rsi
    push rdi
    cmp ecx, RTW_TXF - 48
    ja .full
    lea rdi, [rtw_txf]
    push rcx
    push rdi
    xor eax, eax
    mov ecx, 48 / 8
    rep stosq
    pop rdi
    pop rcx
    mov eax, ecx                        ; w0: size, the frame at 48, last
    or eax, (48 << 16) | (1 << 26) | (1 << 31)  ; segment, queue's own sequence off
    test byte [rsi + 4], 1              ; to a group address
    jz .unicast
    or eax, 1 << 24
.unicast:
    mov [rdi], eax
    mov edx, RTW_QSEL_MGMT << 8
    cmp byte [rtw_band], 1
    jne .ofdm
    or edx, 8 << 16                     ; 2.4 GHz: 1 Mb/s (rate ID B_20M, rate 0)
    jmp .w1
.ofdm:
    or edx, 7 << 16                     ; 5 GHz: 6 Mb/s (rate ID G, rate 4)
    mov dword [rdi + 16], 4
.w1:
    mov [rdi + 4], edx
    mov dword [rdi + 12], (1 << 8) | (1 << 10)  ; w3: this rate, no fallback
    mov dword [rdi + 32], 1 << 15       ; w8: the chip numbers it
    add rdi, 48
    push rcx
    rep movsb
    pop rcx
    add ecx, 48
    lea rsi, [rtw_txf]
    mov edx, RQ_MGMT
    call rtw_tx_put
    jmp .out
.full:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_probe_req(R12, ECX = the channel tuned, RDX = 0, or an SSID: its
; length byte, then it) -> CF if not sent: a probe request to every
; network (the wildcard SSID) or to one, with the band's rates
rtw_probe_req:
    push rcx
    push rsi
    push rdi
    lea rdi, [rtw_txf + RTW_TXF]        ; built past the descriptor's buffer
    mov dword [rdi], 0x00000040         ; probe request, no duration
    mov dword [rdi + 4], 0xFFFFFFFF     ; to everyone
    mov word [rdi + 8], 0xFFFF
    mov eax, [rtw_mac]                  ; from us
    mov [rdi + 10], eax
    mov ax, [rtw_mac + 4]
    mov [rdi + 14], ax
    mov dword [rdi + 16], 0xFFFFFFFF    ; any network
    mov word [rdi + 20], 0xFFFF
    mov word [rdi + 22], 0              ; (the chip numbers it)
    mov word [rdi + 24], 0x0000         ; SSID: any
    add rdi, 26
    test rdx, rdx
    jz .any
    push rcx
    movzx ecx, byte [rdx]               ; this one
    mov [rdi - 1], cl
    lea rsi, [rdx + 1]
    rep movsb
    pop rcx
.any:
    call rtw_rates_ie
    cmp byte [rtw_band], 1
    jne .send
    mov byte [rdi], 3                   ; 2.4 GHz: the channel (DS parameter set)
    mov byte [rdi + 1], 1
    mov [rdi + 2], cl
    add rdi, 3
.send:
    lea rsi, [rtw_txf + RTW_TXF]
    mov rcx, rdi
    sub rcx, rsi
    call rtw_mgmt_send
    pop rdi
    pop rsi
    pop rcx
    ret

; rtw_rates_ie(RDI) -> RDI past them: the band's supported rates (and
; extended rates), as information elements
rtw_rates_ie:
    push rcx
    push rsi
    lea rsi, [rtw_rates5]
    cmp byte [rtw_band], 1
    jne .rates
    lea rsi, [rtw_rates2]
.rates:
    movzx eax, byte [rsi]
    inc rsi
    push rcx
    mov ecx, eax
    rep movsb
    pop rcx
    pop rsi
    pop rcx
    ret

section .rodata
; supported rates (and extended rates), as information elements; 2.4 GHz
; with CCK as basic, 5 GHz with 6, 12 and 24 Mb/s
rtw_rates2:     db 16, 1, 8, 0x82, 0x84, 0x8B, 0x96, 0x0C, 0x12, 0x18, 0x24
                db 50, 4, 0x30, 0x48, 0x60, 0x6C
rtw_rates5:     db 10, 1, 8, 0x8C, 0x12, 0x98, 0x24, 0xB0, 0x48, 0x60, 0x6C

RTW_TXF         equ 2048

section .bss
alignb 8
rtw_txf:        resb RTW_TXF + 256      ; a frame with its descriptor; one being built
