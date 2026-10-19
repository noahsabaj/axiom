; =============================================================================
;  rtwrx.asm - frames from the RTL8821CE's RX ring (rtw_pci_rx_napi, polled;
;  rx.h's descriptor), and a survey: how much each channel carries. Part of
;  the rtw88 port (rtw.asm: the license, R12 = the chip's registers).
; =============================================================================

section .text

; rtw_rx_poll(R12) -> EAX = frames taken off the ring: each good frame to
; rtw_rx_frame, firmware reports (C2H) and bad frames counted, every
; buffer handed back to the chip. Preserves all but RAX.
rtw_rx_poll:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    xor r8d, r8d
    mov ecx, [rtw_rx_rp]
.next:
    mov eax, [r12 + REG_RX_IDX]         ; the chip's write index
    shr eax, 16
    and eax, 0xFFF
    cmp eax, ecx
    je .done
    imul eax, ecx, RTW_RXSTRIDE
    mov rsi, [rtw_rx_buf]
    add rsi, rax
    mov edx, [rsi]                      ; the descriptor's first word
    test dword [rsi + 8], 1 << 28
    jnz .c2h
    test edx, 1 << 14
    jnz .bad
    mov edi, edx                        ; the frame: past the descriptor, the
    shr edi, 16                         ; driver info (8-byte units) and the
    and edi, 0xF                        ; shift
    shl edi, 3
    add edi, 24
    mov eax, edx
    shr eax, 24
    and eax, 3
    add edi, eax
    mov eax, edx
    and eax, 0x3FFF
    lea ebx, [eax + edi]
    cmp ebx, RTW_RXBUF
    ja .bad
    push rcx
    push rsi
    mov rdx, rsi
    add rsi, rdi
    mov ecx, eax
    call rtw_rx_frame
    pop rsi
    pop rcx
    inc r8d
    jmp .used
.c2h:
    inc dword [rtw_rx_c2h]
    jmp .used
.bad:
    inc dword [rtw_rx_bad]
.used:
    call rtw_rx_post
    inc ecx
    cmp ecx, RTW_RXN
    jb .index
    xor ecx, ecx
.index:
    mov [rtw_rx_rp], ecx
    mov [r12 + REG_RX_IDX], cx          ; read this far
    jmp .next
.done:
    mov eax, r8d
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_rx_frame(RSI = an 802.11 frame, its FCS on the end, ECX = its
; length, RDX = its RX descriptor): counted for the survey; the BSSID of
; a beacon or probe response kept, so access points are counted once.
; Preserves all but RAX.
rtw_rx_frame:
    call rtw_join_frame
    push rcx
    push rdi
    inc dword [rtw_sv_frames]
    cmp ecx, 24 + 4
    jb .out
    cmp word [rsi], 0x0080              ; a beacon
    je .beacon
    cmp word [rsi], 0x0050              ; a probe response (to us: the
    jne .out                            ; chip takes only those unicast)
    inc dword [rtw_sv_probes]
    jmp .bss
.beacon:
    inc dword [rtw_sv_beacons]
.bss:
    mov eax, [rsi + 16]                 ; its BSSID
    movzx edi, word [rsi + 20]
    shl rdi, 32
    or rax, rdi
    mov ecx, [rtw_sv_bss_n]
    lea rdi, [rtw_sv_bss]
.seen:
    test ecx, ecx
    jz .new
    cmp [rdi], rax
    je .out
    add rdi, 8
    dec ecx
    jmp .seen
.new:
    cmp dword [rtw_sv_bss_n], 64
    jae .out
    mov [rdi], rax
    inc dword [rtw_sv_bss_n]
.out:
    pop rdi
    pop rcx
    ret

; rtw_survey(R12): a quarter second on each common channel (none that
; needs radar detection), asking twice who is there and listening; what
; each carried logged as counts (no network's name or address)
rtw_survey:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    lea rbx, [rtw_sv_channels]
    xor eax, eax
    mov [rtw_rx_bad], eax
    mov [rtw_sv_asked], eax
.channel:
    movzx ecx, byte [rbx]
    test ecx, ecx
    jz .out
    xor eax, eax
    mov [rtw_sv_frames], eax
    mov [rtw_sv_beacons], eax
    mov [rtw_sv_bss_n], eax
    call rtw_set_channel
    call rtw_rx_poll                    ; (what came in before the switch)
    xor eax, eax
    mov [rtw_sv_frames], eax
    mov [rtw_sv_beacons], eax
    mov [rtw_sv_probes], eax
    mov [rtw_sv_bss_n], eax
    mov r8d, 250
.listen:
    cmp r8d, 250
    je .ask
    cmp r8d, 125
    jne .poll
.ask:
    xor edx, edx
    call rtw_probe_req
    jc .poll
    inc dword [rtw_sv_asked]
.poll:
    call rtw_rx_poll
    mov edi, 1000
    call delay_us
    dec r8d
    jnz .listen
    mov esi, 0x18
    call rtw_rf_read
    mov r9d, eax
    mov eax, [rtw_sv_frames]
    mov edx, [rtw_sv_beacons]
    mov esi, [rtw_sv_probes]
    mov edi, [rtw_sv_bss_n]
    KLOG "wifi: channel %u (RF 18 %05x): %u frames, %u beacons, %u probe responses, %u access points", rcx, r9, rax, rdx, rsi, rdi
    inc rbx
    jmp .channel
.out:
    mov eax, [r12 + 0x3B0]              ; the MGMT ring: how far the chip read
    shr eax, 16
    and eax, 0xFFF
    mov edx, [rtw_tx + RQ_MGMT * RTR_SIZE + RTR_WP]
    mov esi, [rtw_sv_asked]
    mov edi, [rtw_rx_bad]
    KLOG "wifi: %u probe requests sent; the MGMT ring at %u of %u; %u bad frames", rsi, rax, rdx, rdi
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
rtw_sv_channels: db 1, 6, 11, 36, 40, 44, 48, 149, 153, 157, 161, 0

section .bss
alignb 8
rtw_sv_bss:     resq 64                 ; BSSIDs heard on this channel
rtw_sv_bss_n:   resd 1
rtw_sv_frames:  resd 1
rtw_sv_beacons: resd 1
rtw_sv_probes:  resd 1
rtw_sv_asked:   resd 1
rtw_rx_bad:     resd 1
rtw_rx_c2h:     resd 1
