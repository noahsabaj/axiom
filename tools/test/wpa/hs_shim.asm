; =============================================================================
;  hs_shim.asm - host test shim for the RTL8821CE station's handshakes:
;  src/kernel/rtwwpa.asm over shim.asm (wpa.asm, crypto.asm and kc), with
;  what it calls outside them played here:
;    rand_bytes      bytes from rand_src
;    rtw_wifi_send   the payload kept in sent_buf (sent_len, sent_type,
;                    sent_da, sent_keys: rtw_keys then), sent_n counted
;    rtw_rx_eth      eth_n counted, eth_off (RSI - RDX) and eth_len kept
;    KLOG            klog_n counted
;  and hs_rx_data: rtw_rx_data with EBX = EDX (the header's length), as kc
;  cannot set RBX. tools/test/wpa/handshake.py plays the access point.
; =============================================================================

%include "shim.asm"

%macro KLOG 1-*
    inc dword [klog_n]
%endmacro

WK_PMK          equ 41
RTW_RSN_IE      equ 22

global rtw_wpa_reset, rtw_eapol_rx, hs_rx_data
global rtw_bss, rtw_mac, rtw_wk, rtw_ptk, rtw_tk, rtw_gtk, rtw_gtk_id, rtw_keys
global rtw_hs, rtw_snonce, rtw_tx_pn, rtw_js_got, rtw_rx_undec
global sent_buf, sent_len, sent_type, sent_da, sent_keys, sent_n, rand_src
global klog_n, eth_n, eth_off, eth_len

%include "rtwwpa.asm"

section .text

rand_bytes:
    push rcx
    push rsi
    push rdi
    lea rsi, [rand_src]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    clc
    ret

rtw_wifi_send:
    push rcx
    push rsi
    push rdi
    mov [sent_len], ecx
    mov [sent_type], dx
    mov eax, [rdi]
    mov [sent_da], eax
    mov ax, [rdi + 4]
    mov [sent_da + 4], ax
    mov al, [rtw_keys]
    mov [sent_keys], al
    inc dword [sent_n]
    lea rdi, [sent_buf]
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    clc
    ret

rtw_rx_eth:
    inc dword [eth_n]
    mov rax, rsi
    sub rax, rdx
    mov [eth_off], eax
    mov [eth_len], ecx
    ret

hs_rx_data:
    push rbx
    mov ebx, edx
    call rtw_rx_data
    pop rbx
    ret

section .rodata
rtw_rsn_ie:     db 48, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4
                db 1, 0, 0x00, 0x0F, 0xAC, 2, 0, 0

section .bss
alignb 16
sent_buf:       resb 2048
rand_src:       resb 64
rtw_wk:         resb 80
rtw_bss:        resb 8
rtw_mac:        resb 8
sent_da:        resb 8
alignb 8
rtw_tx_pn:      resq 1
sent_len:       resd 1
sent_n:         resd 1
klog_n:         resd 1
eth_n:          resd 1
eth_off:        resd 1
eth_len:        resd 1
rtw_eapol_n:    resd 1
rtw_data_n:     resd 1
sent_type:      resw 1
sent_keys:      resb 1
rtw_js_got:     resb 1
