; =============================================================================
;  rtwwpa.asm - WPA2-Personal for the RTL8821CE's station: the 4-way
;  handshake and the group key handshake (IEEE 802.11-2020 12.7.6 and
;  12.7.7; EAPOL-Key frames, 12.7.2, descriptor version 2: HMAC-SHA1 MICs,
;  AES key wrap) with the PMK of WIFI.KEY, and CCMP on received data
;  frames. The crypto is wpa.asm's. Part of the rtw88 port (rtw.asm).
;
;  Nothing here logs a key, a nonce or a MIC.
; =============================================================================

EK_VERSION      equ 0                   ; an EAPOL-Key frame: the EAPOL header,
EK_TYPE         equ 1                   ;   (3: key)
EK_LEN          equ 2                   ;   body length (big-endian)
EK_DESC         equ 4                   ; the key descriptor (2: RSN)
EK_INFO         equ 5                   ;   key information (big-endian)
EK_KEYLEN       equ 7
EK_REPLAY       equ 9                   ;   replay counter (8, big-endian)
EK_NONCE        equ 17                  ;   (32)
EK_RSC          equ 65                  ;   the group key's receive counter
EK_MIC          equ 81                  ;   (16)
EK_DATALEN      equ 97                  ;   key data length (big-endian)
EK_DATA         equ 99
EK_MAX          equ 512                 ; the largest one taken

KI_VERSION      equ 0x0007              ; key information bits
KI_PAIRWISE     equ 0x0008
KI_INSTALL      equ 0x0040
KI_ACK          equ 0x0080
KI_MIC          equ 0x0100
KI_SECURE       equ 0x0200
KI_ENCDATA      equ 0x1000

KDE_GTK         equ 0x01AC0F00          ; 00-0F-AC, type 1, as a dword

section .text

; rtw_wpa_reset: a new association: no keys yet, a fresh SNonce
rtw_wpa_reset:
    push rcx
    push rdi
    mov byte [rtw_hs], 0
    mov byte [rtw_keys], 0
    lea rdi, [rtw_snonce]
    mov ecx, 32
    call rand_bytes
    pop rdi
    pop rcx
    ret

; rtw_rx_data(RSI = a data frame from the access point, no FCS, ECX = its
; length, EBX = its header's): decrypted if protected (the pairwise key,
; or the group key for a group address), then by its LLC/SNAP header:
; EAPOL to rtw_eapol_rx, the rest to the network (rtw_rx_eth).
; Unprotected frames are taken only for EAPOL. Preserves all but RAX.
rtw_rx_data:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9, rsi                         ; the header
    xor r8d, r8d                        ; protected?
    test byte [rsi + 1], 0x40
    jz .plain
    cmp byte [rtw_keys], 0
    je .locked
    lea eax, [ebx + 8 + 8]              ; a CCMP header and a MIC at least
    cmp ecx, eax
    jb .out
    lea rdx, [rtw_tk]
    test byte [rsi + 4], 1              ; to a group address
    jz .key
    mov al, [rsi + rbx + 3]             ; the CCMP header's key ID
    shr al, 6
    cmp al, [rtw_gtk_id]
    jne .failed
    lea rdx, [rtw_gtk]
.key:
    mov rdi, rsi
    mov rsi, rdx
    mov edx, ecx
    mov ecx, ebx
    call ccmp_open
    jc .failed
    inc dword [rtw_rx_dec]
    lea rsi, [rdi + rbx + 8]
    mov ecx, eax
    inc r8d
    jmp .payload
.plain:
    add rsi, rbx
    sub ecx, ebx
.payload:
    cmp ecx, 8
    jb .out
    mov rax, 0x0000FFFFFFFFFFFF
    and rax, [rsi]
    mov rdx, 0x00000003AAAA
    cmp rax, rdx                        ; LLC/SNAP, an EtherType
    jne .out
    cmp word [rsi + 6], 0x8E88          ; EAPOL
    jne .data
    add rsi, 8
    sub ecx, 8
    call rtw_eapol_rx
    jmp .out
.data:
    test r8d, r8d
    jz .out
    inc dword [rtw_data_n]
    mov rdx, r9
    call rtw_rx_eth
    jmp .out
.locked:
    inc dword [rtw_rx_locked]
    jmp .out
.failed:
    inc dword [rtw_rx_undec]
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_eapol_rx(RSI = an EAPOL frame, ECX = its length): the handshakes'
; messages from the access point, answered. Preserves all but RAX.
rtw_eapol_rx:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    inc dword [rtw_eapol_n]
    cmp ecx, EK_DATA
    jb .out
    cmp byte [rsi + EK_TYPE], 3
    jne .out
    cmp byte [rsi + EK_DESC], 2
    jne .out
    movzx eax, word [rsi + EK_LEN]
    xchg al, ah
    add eax, 4
    cmp eax, ecx
    ja .out
    mov ecx, eax                        ; its own length (no padding)
    cmp ecx, EK_MAX
    ja .out
    movzx ebx, word [rsi + EK_INFO]
    xchg bl, bh
    mov eax, ebx
    and eax, KI_VERSION
    cmp eax, 2
    jne .out
    test ebx, KI_ACK
    jz .out
    test ebx, KI_PAIRWISE
    jz .group
    test ebx, KI_MIC
    jz .m1
    test ebx, KI_INSTALL
    jnz .m3
    jmp .out
.m1:                                    ; message 1: the ANonce
    lea rdi, [rtw_anonce]
    push rsi
    add rsi, EK_NONCE
    mov ecx, 32
    rep movsb
    pop rsi
    mov rax, [rsi + EK_REPLAY]
    mov [rtw_replay], rax
    call rtw_ptk_derive
    call rtw_ek_start                   ; message 2: the SNonce, our RSN element
    mov word [rtw_ek + EK_INFO], 0x0A01 ; (0x010A: pairwise, MIC, version 2)
    push rsi
    lea rsi, [rtw_snonce]
    lea rdi, [rtw_ek + EK_NONCE]
    mov ecx, 32
    rep movsb
    mov byte [rtw_ek + EK_DATALEN + 1], RTW_RSN_IE
    lea rsi, [rtw_rsn_ie]
    lea rdi, [rtw_ek + EK_DATA]
    mov ecx, RTW_RSN_IE
    rep movsb
    pop rsi
    mov ecx, EK_DATA + RTW_RSN_IE
    call rtw_ek_send
    mov byte [rtw_hs], 1
    jmp .out
.m3:                                    ; message 3: the keys
    cmp byte [rtw_hs], 1
    jb .out
    push rcx
    push rsi
    add rsi, EK_NONCE
    lea rdi, [rtw_anonce]
    mov ecx, 32
    repe cmpsb
    pop rsi
    pop rcx
    jne .out                            ; (another handshake's)
    call rtw_replay_new
    jbe .out
    call rtw_ek_check
    jc .bad_mic
    test ebx, KI_ENCDATA
    jz .out
    call rtw_kd_gtk
    jc .no_gtk
    mov rax, [rsi + EK_REPLAY]
    mov [rtw_replay], rax
    call rtw_ek_start                   ; message 4
    mov word [rtw_ek + EK_INFO], 0x0A03 ; (0x030A: pairwise, MIC, secure, v2)
    mov ecx, EK_DATA
    call rtw_ek_send
    lea rsi, [rtw_ptk + 32]             ; then the pairwise key in use
    lea rdi, [rtw_tk]
    mov ecx, 16
    rep movsb
    mov qword [rtw_tx_pn], 1
    mov byte [rtw_keys], 1
    mov byte [rtw_hs], 2
    mov byte [rtw_js_got], 1
    movzx eax, byte [rtw_gtk_id]
    KLOG "wifi: WPA2 keys agreed (group key %u)", rax
    jmp .out
.group:                                 ; the group key handshake: a new one
    test ebx, KI_MIC
    jz .out
    cmp byte [rtw_keys], 0
    je .out
    call rtw_replay_new
    jbe .out
    call rtw_ek_check
    jc .bad_mic
    test ebx, KI_ENCDATA
    jz .out
    call rtw_kd_gtk
    jc .no_gtk
    mov rax, [rsi + EK_REPLAY]
    mov [rtw_replay], rax
    call rtw_ek_start                   ; its message 2
    mov word [rtw_ek + EK_INFO], 0x0203 ; (0x0302: MIC, secure, v2)
    mov ecx, EK_DATA
    call rtw_ek_send
    movzx eax, byte [rtw_gtk_id]
    KLOG "wifi: a new group key (%u)", rax
    jmp .out
.bad_mic:
    KLOG "wifi: an EAPOL-Key frame with a wrong MIC: ignored"
    jmp .out
.no_gtk:
    KLOG "wifi: no group key in an EAPOL-Key frame that should have one"
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_replay_new(RSI = an EAPOL-Key frame) -> above (CF and ZF clear) if
; its replay counter is past the last one taken. Preserves all but RAX.
rtw_replay_new:
    push rdx
    mov rax, [rsi + EK_REPLAY]
    bswap rax
    mov rdx, [rtw_replay]
    bswap rdx
    cmp rax, rdx
    pop rdx
    ret

; rtw_ptk_derive: the PTK (KCK, KEK, TK) from the PMK, both addresses and
; both nonces (12.7.1.3): PRF-384(PMK, "Pairwise key expansion",
; Min(AA, SPA) || Max(AA, SPA) || Min(ANonce, SNonce) || Max(...)).
; Preserves all but RAX.
rtw_ptk_derive:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea rsi, [rtw_bss]
    lea rdi, [rtw_mac]
    mov ecx, 6
    lea rdx, [rtw_ptkd]
    call rtw_minmax
    lea rsi, [rtw_anonce]
    lea rdi, [rtw_snonce]
    mov ecx, 32
    lea rdx, [rtw_ptkd + 12]
    call rtw_minmax
    lea rdi, [rtw_ptk]
    lea rsi, [rtw_wk + WK_PMK]
    mov edx, 32
    lea rcx, [str_rtw_ptk]
    lea r8, [rtw_ptkd]
    mov r9d, 12 + 64
    mov r10d, 48
    call prf_sha1
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_minmax(RSI = a, RDI = b, ECX = their length, RDX = out): the lesser
; (as bytes, first to last), then the other. Preserves all but RAX.
rtw_minmax:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, rsi
    mov rax, rdi
    push rcx
    repe cmpsb
    pop rcx
    jb .ordered
    xchg rbx, rax
.ordered:
    mov rdi, rdx
    mov rsi, rbx
    push rcx
    rep movsb
    pop rcx
    mov rsi, rax
    rep movsb
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rtw_ek_check(RSI = an EAPOL-Key frame, ECX = its length) -> CF if its
; MIC is not HMAC-SHA1(KCK) of it with the MIC zeroed. Preserves all but
; RAX.
rtw_ek_check:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push rsi
    push rcx
    lea rdi, [rtw_ek]
    rep movsb
    pop r8
    pop rsi
    xor eax, eax
    mov [rtw_ek + EK_MIC], rax
    mov [rtw_ek + EK_MIC + 8], rax
    lea rdi, [rtw_mic]
    push rsi
    lea rsi, [rtw_ptk]                  ; the KCK
    mov edx, 16
    lea rcx, [rtw_ek]
    call hmac_sha1
    pop rsi
    add rsi, EK_MIC
    lea rdi, [rtw_mic]
    mov ecx, 16
    repe cmpsb
    clc
    je .out
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_kd_gtk(RSI = an EAPOL-Key frame, its MIC checked) -> CF if its key
; data does not unwrap (the KEK) to a GTK element: the group key and its
; ID taken. Preserves all but RAX.
rtw_kd_gtk:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, word [rsi + EK_DATALEN]
    xchg cl, ch
    cmp ecx, 24
    jb .no
    cmp ecx, RTW_KD + 8
    ja .no
    test ecx, 7
    jnz .no
    lea rdx, [rsi + EK_DATA]
    lea rsi, [rtw_ptk + 16]             ; the KEK
    lea rdi, [rtw_kd]
    call aes_unwrap
    jc .out
    sub ecx, 8
    xor ebx, ebx
.element:
    lea eax, [ebx + 2]
    cmp eax, ecx
    ja .no
    movzx edx, byte [rdi + rbx + 1]
    add eax, edx
    cmp eax, ecx
    ja .no
    cmp byte [rdi + rbx], 0xDD
    jne .next
    cmp edx, 6 + 16
    jb .next
    cmp dword [rdi + rbx + 2], KDE_GTK
    jne .next
    mov al, [rdi + rbx + 6]
    and al, 3
    mov [rtw_gtk_id], al
    lea rsi, [rdi + rbx + 8]
    lea rdi, [rtw_gtk]
    mov ecx, 16
    rep movsb
    clc
    jmp .out
.next:
    lea ebx, [ebx + edx + 2]
    jmp .element
.no:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_ek_start(RSI = the access point's EAPOL-Key frame): our answer begun
; in rtw_ek, zeroed: its EAPOL version, type and descriptor, and the
; replay counter it answers. Preserves all but RAX.
rtw_ek_start:
    push rcx
    push rdi
    lea rdi, [rtw_ek]
    mov ecx, (EK_DATA + 64) / 8 + 1
    xor eax, eax
    rep stosq
    mov al, [rsi + EK_VERSION]
    mov [rtw_ek + EK_VERSION], al
    mov byte [rtw_ek + EK_TYPE], 3
    mov byte [rtw_ek + EK_DESC], 2
    mov rax, [rsi + EK_REPLAY]
    mov [rtw_ek + EK_REPLAY], rax
    pop rdi
    pop rcx
    ret

; rtw_ek_send(ECX = rtw_ek's length): its body length and MIC filled, then
; sent to the access point. Preserves all but RAX.
rtw_ek_send:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea eax, [ecx - 4]
    xchg al, ah
    mov [rtw_ek + EK_LEN], ax
    mov r8d, ecx
    lea rdi, [rtw_mic]
    lea rsi, [rtw_ptk]                  ; the KCK
    mov edx, 16
    lea rcx, [rtw_ek]
    call hmac_sha1
    mov rax, [rtw_mic]
    mov [rtw_ek + EK_MIC], rax
    mov rax, [rtw_mic + 8]
    mov [rtw_ek + EK_MIC + 8], rax
    lea rsi, [rtw_ek]
    mov ecx, r8d
    call rtw_eapol_send
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_eapol_send(RSI = an EAPOL frame, ECX = its length): to the access
; point, protected once the keys are in use (not the 4-way handshake's
; own messages, then). Preserves all but RAX.
rtw_eapol_send:
    push rdx
    push rdi
    lea rdi, [rtw_bss]
    mov edx, 0x8E88
    call rtw_wifi_send
    pop rdi
    pop rdx
    ret

section .rodata
str_rtw_ptk:    db 'Pairwise key expansion', 0

RTW_KD          equ 256

section .bss
alignb 16
rtw_ek:         resb EK_MAX + 16        ; an EAPOL-Key frame, ours or checked
rtw_kd:         resb RTW_KD + 16        ; key data, unwrapped
rtw_ptk:        resb 48                 ; KCK, KEK, TK
rtw_tk:         resb 16                 ; the pairwise key in use
rtw_gtk:        resb 16                 ; the group key
rtw_anonce:     resb 32
rtw_snonce:     resb 32
rtw_ptkd:       resb 12 + 64            ; the PRF's data
rtw_mic:        resb 20
alignb 8
rtw_replay:     resq 1                  ; the last replay counter taken (as sent)
rtw_rx_dec:     resd 1
rtw_rx_undec:   resd 1
rtw_rx_locked:  resd 1
rtw_hs:         resb 1                  ; 0, 1 message 2 sent, 2 done
rtw_keys:       resb 1                  ; the keys are in use
rtw_gtk_id:     resb 1
