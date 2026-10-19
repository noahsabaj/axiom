; =============================================================================
;  rtwjoin.asm - the RTL8821CE as a station: the network it is to join
;  (EFI/AXIOM/WIFI.KEY, which tools/hw/hp1.py's `wifi` makes: its SSID and
;  WPA2 key), found on the air, then Open System authentication and
;  association (IEEE 802.11-2020 11.3), as a non-QoS, non-HT station, the
;  RSN element asking for CCMP and a pre-shared key (9.4.2.24). Part of the
;  rtw88 port (rtw.asm: R12 = the chip's registers).
;
;  Nothing here logs the network's name or address, or the key.
; =============================================================================

JS_IDLE         equ 0                   ; rtw_js: what received frames are for
JS_SCAN         equ 1                   ;   the network's access points
JS_AUTH         equ 2                   ;   an authentication answer
JS_ASSOC        equ 3                   ;   an association answer
JS_LINKED       equ 4                   ;   on the network

RSN_CCMP        equ 0x04AC0F00          ; suite 00-0F-AC:4, as a dword
RSN_PSK         equ 0x02AC0F00          ; AKM 00-0F-AC:2

WK_SIZE         equ 73                  ; WIFI.KEY: "AXWIFI01", SSID length,
WK_SSID         equ 8                   ;   SSID (32), PMK (32)
WK_PMK          equ 41

REG_AID         equ 0x6A8

section .text

; rtw_join(R12) -> CF (said why) if there is no network to join (no good
; WIFI.KEY): its key read, then the network joined (rtw_connect; if that
; fails, the link tries again later).
rtw_join:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r14
    call boot_volume
    jc .no_key
    lea rsi, [str_rtw_key_path]
    lea rdi, [rtw_wk]
    mov ecx, WK_SIZE + 1
    call fat_read_file
    jc .no_key                          ; (it said why)
    cmp rax, WK_SIZE
    jne .bad_key
    mov rax, 'AXWIFI01'
    cmp [rtw_wk], rax
    jne .bad_key
    movzx eax, byte [rtw_wk + WK_SSID]
    dec eax
    cmp eax, 32
    jae .bad_key
    call rtw_connect
    clc
    jmp .out
.bad_key:
    KLOG "wifi: WIFI.KEY is not a network's key (tools/hw/hp1.py wifi makes it)"
.no_key:
    stc
.out:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rtw_connect(R12) -> CF (said why) if not on the network with keys in
; use: found, authenticated, associated, and the 4-way handshake done
; within 3 seconds. A handshake that fails counts in rtw_hs_fails (a
; wrong key, likely: the link stops trying after two). Preserves all but
; RAX.
rtw_connect:
    push rcx
    call rtw_find
    jc .fail
    call rtw_auth
    jc .fail
    call rtw_assoc
    jc .fail
    xor eax, eax
    mov [rtw_eapol_n], eax
    mov [rtw_data_n], eax
    mov [rtw_rx_dec], eax
    mov [rtw_rx_undec], eax
    mov [rtw_rx_locked], eax
    mov byte [rtw_js_got], 0
    mov ecx, 3000                       ; the 4-way handshake
    call rtw_listen
    cmp byte [rtw_keys], 0
    jne .keys
    mov eax, [rtw_eapol_n]
    KLOG "wifi: no keys agreed in 3 s (%u EAPOL frames from the access point)", rax
    call rtw_deauth
    inc byte [rtw_hs_fails]
.fail:
    mov byte [rtw_js], JS_IDLE
    stc
    jmp .out
.keys:
    mov byte [rtw_hs_fails], 0
    clc
.out:
    pop rcx
    ret

; rtw_find(R12) -> CF (said why) if not found: each survey channel tuned,
; the network asked for by name, its beacons and answers heard; the access
; point kept (5 GHz before 2.4), then tuned
rtw_find:
    push rbx
    push rcx
    push rdx
    mov byte [rtw_bss_found], 0
    mov dword [rtw_bss_heard], 0
    mov byte [rtw_js], JS_SCAN
    lea rbx, [rtw_sv_channels]
.channel:
    movzx ecx, byte [rbx]
    test ecx, ecx
    jz .done
    call rtw_set_channel
    call rtw_rx_poll
    lea rdx, [rtw_wk + WK_SSID]
    call rtw_probe_req
    push rcx
    mov ecx, 120
    call rtw_listen
    pop rcx
    inc rbx
    jmp .channel
.done:
    mov byte [rtw_js], JS_IDLE
    cmp byte [rtw_bss_found], 0
    je .none
    movzx ecx, byte [rtw_bss_ch]
    movzx edx, byte [rtw_bss_rsn]
    mov eax, [rtw_bss_heard]
    KLOG "wifi: your network: heard %u times; joining on channel %u (security %02x)", rax, rcx, rdx
    test dl, RB_HT_ONLY
    jnz .ht_only
    and dl, RB_CCMP | RB_PSK | RB_GCCMP | RB_MFPR
    cmp dl, RB_CCMP | RB_PSK | RB_GCCMP
    jne .security
    call rtw_set_channel
    clc
    jmp .out
.none:
    KLOG "wifi: your network was not heard on any channel"
    stc
    jmp .out
.ht_only:
    KLOG "wifi: your network takes only 802.11n stations, and this one is not yet"
    stc
    jmp .out
.security:
    KLOG "wifi: your network wants other security than WPA2-Personal with CCMP"
    stc
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_auth(R12) -> CF (said why) if refused or unanswered: Open System
; authentication with the access point, tried three times
rtw_auth:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, 3
.try:
    lea rdi, [rtw_txf + RTW_TXF]
    mov eax, 0x00B0                     ; authentication
    call rtw_mgmt_hdr
    mov dword [rdi + 24], 0x00010000    ; algorithm 0 (open), transaction 1
    mov word [rdi + 28], 0              ; status
    mov ecx, 30
    mov byte [rtw_js_got], 0
    mov byte [rtw_js], JS_AUTH
    lea rsi, [rtw_txf + RTW_TXF]
    call rtw_mgmt_send
    mov ecx, 100
    call rtw_listen
    cmp byte [rtw_js_got], 0
    jne .answer
    dec edx
    jnz .try
    KLOG "wifi: no answer to authentication"
    stc
    jmp .out
.answer:
    movzx eax, word [rtw_js_status]
    test eax, eax
    jnz .refused
    KLOG "wifi: authenticated"
    clc
    jmp .out
.refused:
    KLOG "wifi: authentication refused (status %u)", rax
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_assoc(R12) -> CF (said why) if refused or unanswered: association,
; tried three times; then the port as on the network (its BSSID, AID)
rtw_assoc:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, 3
.try:
    lea rdi, [rtw_txf + RTW_TXF]
    xor eax, eax                        ; association request
    call rtw_mgmt_hdr
    movzx eax, word [rtw_bss_cap]       ; capability: an ESS, privacy as the
    and eax, 0x0010                     ; network has it, and on 2.4 GHz its
    cmp byte [rtw_band], 1              ; short preamble and slot time
    jne .cap
    movzx ecx, word [rtw_bss_cap]
    and ecx, 0x0420
    or eax, ecx
.cap:
    or eax, 0x0001
    mov [rdi + 24], ax
    mov word [rdi + 26], 10             ; listen interval (beacons)
    add rdi, 28
    push rsi
    lea rsi, [rtw_wk + WK_SSID]
    movzx ecx, byte [rsi]
    mov byte [rdi], 0                   ; SSID
    inc rdi
    inc ecx
    rep movsb
    call rtw_rates_ie
    lea rsi, [rtw_rsn_ie]               ; RSN: CCMP, a pre-shared key
    mov ecx, RTW_RSN_IE
    rep movsb
    pop rsi
    lea rsi, [rtw_txf + RTW_TXF]
    mov rcx, rdi
    sub rcx, rsi
    mov byte [rtw_js_got], 0
    mov byte [rtw_js], JS_ASSOC
    call rtw_mgmt_send
    mov ecx, 100
    call rtw_listen
    cmp byte [rtw_js_got], 0
    jne .answer
    dec edx
    jnz .try
    KLOG "wifi: no answer to association"
    stc
    jmp .out
.answer:
    movzx eax, word [rtw_js_status]
    test eax, eax
    jnz .refused
    xor ecx, ecx
.bssid:
    mov al, [rtw_bss + rcx]
    mov [r12 + REG_BSSID + rcx], al
    inc ecx
    cmp ecx, 6
    jb .bssid
    mov eax, [r12 + REG_AID]
    and eax, ~0x7FF
    movzx ecx, word [rtw_aid]
    and ecx, 0x7FF
    or eax, ecx
    mov [r12 + REG_AID], eax
    mov al, [r12 + REG_CR + 2]          ; net type: linked
    and al, ~3
    or al, 2
    mov [r12 + REG_CR + 2], al
    mov byte [rtw_js], JS_LINKED
    call rtw_wpa_reset
    movzx eax, word [rtw_aid]
    KLOG "wifi: associated (AID %u)", rax
    clc
    jmp .out
.refused:
    KLOG "wifi: association refused (status %u)", rax
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_deauth(R12): deauthentication sent (reason 3, leaving), given 20 ms
; to go out; the port off the network
rtw_deauth:
    push rcx
    push rsi
    push rdi
    lea rdi, [rtw_txf + RTW_TXF]
    mov eax, 0x00C0
    call rtw_mgmt_hdr
    mov word [rdi + 24], 3
    lea rsi, [rtw_txf + RTW_TXF]
    mov ecx, 26
    call rtw_mgmt_send
    mov byte [rtw_js], JS_IDLE
    mov ecx, 20
.wait:
    mov edi, 1000
    call delay_us
    dec ecx
    jnz .wait
    and byte [r12 + REG_CR + 2], ~3     ; net type: no link
    KLOG "wifi: left the network"
    pop rdi
    pop rsi
    pop rcx
    ret

; rtw_mgmt_hdr(RDI, AX = frame control): a management frame's header to
; the access point, from us
rtw_mgmt_hdr:
    mov [rdi], eax                      ; frame control; duration 0 (the chip's)
    mov eax, [rtw_bss]
    mov [rdi + 4], eax
    mov [rdi + 16], eax
    mov ax, [rtw_bss + 4]
    mov [rdi + 8], ax
    mov [rdi + 20], ax
    mov eax, [rtw_mac]
    mov [rdi + 10], eax
    mov ax, [rtw_mac + 4]
    mov [rdi + 14], ax
    mov word [rdi + 22], 0
    ret

; rtw_listen(R12, ECX = ms): the RX ring polled each millisecond, until an
; answer the join waits for came (rtw_js_got) or the time is up
rtw_listen:
    push rcx
    push rdi
.again:
    call rtw_rx_poll
    cmp byte [rtw_js_got], 0
    jne .out
    mov edi, 1000
    call delay_us
    dec ecx
    jnz .again
.out:
    pop rdi
    pop rcx
    ret

; rtw_join_frame(RSI = an 802.11 frame, its FCS on the end, ECX = its
; length): whatever the join waits for, taken. Preserves all but RAX.
rtw_join_frame:
    cmp byte [rtw_js], JS_IDLE
    jne .busy
    ret
.busy:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    sub ecx, 4
    cmp ecx, 24
    jl .out
    cmp byte [rtw_js], JS_SCAN
    je .scan
    mov eax, [rsi + 10]                 ; from our access point only
    cmp eax, [rtw_bss]
    jne .out
    mov ax, [rsi + 14]
    cmp ax, [rtw_bss + 4]
    jne .out
    movzx eax, byte [rtw_js]
    cmp eax, JS_AUTH
    je .auth
    cmp eax, JS_ASSOC
    je .assoc
    cmp word [rsi], 0x00C0              ; on the network: deauthenticated,
    je .dropped
    cmp word [rsi], 0x00A0              ;   or disassociated,
    je .dropped
    mov al, [rsi]                       ;   or data, from it
    and al, 0x0C
    cmp al, 0x08
    jne .out
    mov al, [rsi + 1]
    and al, 3
    cmp al, 2
    jne .out
    mov ebx, 24
    test byte [rsi], 0x80               ; QoS data: two bytes more
    jz .data
    add ebx, 2
.data:
    cmp ecx, ebx
    jb .out
    call rtw_rx_data
    jmp .out
.dropped:
    cmp ecx, 26
    jb .out
    mov byte [rtw_js], JS_IDLE
    mov byte [rtw_keys], 0
    and byte [r12 + REG_CR + 2], ~3     ; net type: no link
    movzx eax, word [rsi + 24]
    KLOG "wifi: the access point let us go (reason %u)", rax
    jmp .out
.auth:
    cmp word [rsi], 0x00B0
    jne .out
    cmp ecx, 30
    jb .out
    cmp dword [rsi + 24], 0x00020000    ; open, transaction 2
    jne .out
    mov ax, [rsi + 28]
    jmp .got
.assoc:
    cmp word [rsi], 0x0010
    jne .out
    cmp ecx, 30
    jb .out
    mov ax, [rsi + 28]
    and ax, 0x3FFF
    mov [rtw_aid], ax
    mov ax, [rsi + 26]
.got:
    mov [rtw_js_status], ax
    mov byte [rtw_js_got], 1
    jmp .out
.scan:
    cmp word [rsi], 0x0080              ; a beacon
    je .bss
    cmp word [rsi], 0x0050              ; a probe response
    jne .out
.bss:
    cmp ecx, 36
    jb .out
    xor r8d, r8d                        ; what its elements say (RB_*)
    movzx r9d, byte [rtw_channel]       ; its channel, unless they say
    mov ebx, 36
.element:
    lea eax, [ebx + 2]
    cmp eax, ecx
    ja .elements
    movzx edx, byte [rsi + rbx + 1]
    add eax, edx
    cmp eax, ecx
    ja .elements
    movzx eax, byte [rsi + rbx]
    lea rdi, [rsi + rbx + 2]
    cmp eax, 0
    je .ssid
    cmp eax, 3
    je .ds
    cmp eax, 61
    je .ht_op
    cmp eax, 48
    je .rsn
    cmp eax, 1
    je .rates
    cmp eax, 50
    je .rates
.next:
    lea ebx, [ebx + edx + 2]
    jmp .element
.ssid:
    cmp dl, [rtw_wk + WK_SSID]
    jne .next
    push rcx
    push rsi
    mov ecx, edx
    mov rsi, rdi
    lea rdi, [rtw_wk + WK_SSID + 1]
    repe cmpsb
    pop rsi
    pop rcx
    jne .next
    or r8d, RB_NAME
    jmp .next
.ds:
    test edx, edx
    jz .next
    movzx r9d, byte [rdi]
    or r8d, RB_CHANNEL
    jmp .next
.ht_op:
    test r8d, RB_CHANNEL
    jnz .next
    test edx, edx
    jz .next
    movzx r9d, byte [rdi]
    jmp .next
.rates:
    push rcx
    mov ecx, edx
.rate:
    test ecx, ecx
    jz .rates_done
    cmp byte [rdi], 0xFF                ; membership selector: HT PHY only
    jne .rate_next
    or r8d, RB_HT_ONLY
.rate_next:
    inc rdi
    dec ecx
    jmp .rate
.rates_done:
    pop rcx
    jmp .next
.rsn:
    call rtw_rsn_parse
    or r8d, eax
    jmp .next
.elements:
    test r8d, RB_NAME
    jz .out
    inc dword [rtw_bss_heard]
    cmp byte [rtw_bss_found], 0         ; the first, or 5 GHz after 2.4
    je .keep
    cmp byte [rtw_bss_ch], 14
    ja .out
    cmp r9d, 14
    jbe .out
.keep:
    mov eax, [rsi + 16]
    mov [rtw_bss], eax
    mov ax, [rsi + 20]
    mov [rtw_bss + 4], ax
    mov [rtw_bss_ch], r9b
    mov ax, [rsi + 34]
    mov [rtw_bss_cap], ax
    mov [rtw_bss_rsn], r8b
    mov byte [rtw_bss_found], 1
.out:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_rsn_parse(RDI = an RSN element's body, EDX = its length) -> EAX =
; RB_* of what it offers. Preserves all but RAX.
rtw_rsn_parse:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    xor eax, eax
    cmp edx, 8
    jb .out
    cmp word [rdi], 1                   ; version
    jne .out
    cmp dword [rdi + 2], RSN_CCMP       ; the group cipher
    jne .pairwise
    or eax, RB_GCCMP
.pairwise:
    movzx ecx, word [rdi + 6]
    add rdi, 8
    sub edx, 8
    mov ebx, RSN_CCMP
    mov r8d, RB_CCMP
    call .suites
    jc .out
    cmp edx, 2
    jb .out
    movzx ecx, word [rdi]
    add rdi, 2
    sub edx, 2
    mov ebx, RSN_PSK
    mov r8d, RB_PSK
    call .suites
    jc .out
    cmp edx, 2
    jb .out
    test byte [rdi], 0x40               ; capabilities: management frame
    jz .mfpc                            ; protection required,
    or eax, RB_MFPR
.mfpc:
    test byte [rdi], 0x80               ;   or offered
    jz .out
    or eax, RB_MFPC
.out:
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret
; ECX suites at RDI (EDX bytes left): R8D into EAX if one is EBX; RDI and
; EDX past them; CF if they run past the element
.suites:
.suite:
    test ecx, ecx
    jz .suites_done
    cmp edx, 4
    jb .suites_short
    cmp [rdi], ebx
    jne .suite_next
    or eax, r8d
.suite_next:
    add rdi, 4
    sub edx, 4
    dec ecx
    jmp .suite
.suites_done:
    clc
    ret
.suites_short:
    stc
    ret

RB_NAME         equ 0x01                ; (rtw_join_frame's own)
RB_CHANNEL      equ 0x02                ; (its channel from a DS element)
RB_CCMP         equ 0x04                ; pairwise CCMP offered
RB_PSK          equ 0x08                ; a pre-shared key offered
RB_GCCMP        equ 0x10                ; the group cipher is CCMP
RB_MFPR         equ 0x20                ; management frame protection required
RB_MFPC         equ 0x40                ;   or offered
RB_HT_ONLY      equ 0x80                ; stations must do 802.11n

section .rodata
str_rtw_key_path: db '/EFI/AXIOM/WIFI.KEY', 0
; our RSN element: version 1, group CCMP, pairwise CCMP, a pre-shared key,
; no capabilities
rtw_rsn_ie:     db 48, 20, 1, 0, 0x00, 0x0F, 0xAC, 4, 1, 0, 0x00, 0x0F, 0xAC, 4
                db 1, 0, 0x00, 0x0F, 0xAC, 2, 0, 0
RTW_RSN_IE      equ $ - rtw_rsn_ie

section .bss
alignb 8
rtw_wk:         resb WK_SIZE + 7        ; WIFI.KEY
rtw_bss:        resb 8                  ; the access point's address
rtw_bss_heard:  resd 1
rtw_eapol_n:    resd 1
rtw_data_n:     resd 1
rtw_bss_cap:    resw 1
rtw_js_status:  resw 1
rtw_aid:        resw 1
rtw_bss_ch:     resb 1
rtw_bss_rsn:    resb 1                  ; RB_*
rtw_bss_found:  resb 1
rtw_js:         resb 1                  ; JS_*
rtw_js_got:     resb 1
rtw_hs_fails:   resb 1                  ; handshakes failed in a row
