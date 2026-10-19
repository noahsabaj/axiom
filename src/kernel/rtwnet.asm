; =============================================================================
;  rtwnet.asm - the RTL8821CE as a network interface (net.asm's NI_* and
;  driver operations): Ethernet frames out as 802.11 data frames to the
;  access point and back (IEEE 802.11-2020 5.1.5.1: an LLC/SNAP header
;  carries the EtherType), protected with CCMP in software once the
;  4-way handshake's keys are in use. The link is up while they are; a
;  lost network is joined again. Part of the rtw88 port (rtw.asm).
; =============================================================================

RTW_REJOIN      equ 10                  ; seconds between tries to join again

section .text

; rtw_nic_add: the card as an interface, polled, its link down until
; rtw_start joins the network. Called from rtw_probe. Preserves all.
rtw_nic_add:
    push rax
    push rbx
    call nic_alloc
    jc .full
    mov [rtw_nic], rbx
    lea rax, [rtw_ops]
    mov [rbx + NI_OPS], rax
    mov rax, [rtw_mmio]
    mov [rbx + NI_MMIO], rax
    lea rax, [str_rtw_name]
    mov [rbx + NI_NAME], rax
    mov eax, [rtw_bdf]
    mov [rbx + NI_BDF], eax
    mov dword [rbx + NI_IDS], 0x10EC | (0xC821 << 16)
    mov eax, [rtw_mac]
    mov [rbx + NI_MAC], eax
    mov ax, [rtw_mac + 4]
    mov [rbx + NI_MAC + 4], ax
    call nic_commit
    jmp .out
.full:
    KLOG "net: no room for another interface"
.out:
    pop rbx
    pop rax
    ret

; the driver operations (RBX = the interface)
rtw_nic_poll:
    cmp byte [rtw_up], 0
    je .out
    push r12
    mov r12, [rtw_mmio]
    call rtw_rx_poll
    pop r12
.out:
    ret

rtw_nic_ack:
    ret

; link: up while the keys are in use; when they are not, the network
; joined again (every RTW_REJOIN seconds)
rtw_nic_link:
    cmp byte [rtw_up], 0
    je .speed
    cmp byte [rtw_keys], 0
    jne .speed
    mov rax, [net_now]
    cmp rax, [rtw_rejoin_at]
    jb .speed
    mov rcx, [net_second]
    imul rcx, rcx, RTW_REJOIN
    add rax, rcx
    mov [rtw_rejoin_at], rax
    push r12
    mov r12, [rtw_mmio]
    call rtw_connect
    pop r12
.speed:
    xor eax, eax
    cmp byte [rtw_keys], 0
    je .store
    mov eax, 54                         ; 802.11a/g's fastest
.store:
    mov [rbx + NI_SPEED], eax
    mov dword [rbx + NI_DUPLEX], 0
    ret

; send(RSI = an Ethernet frame, ECX = its length) -> CF if it could not go
rtw_nic_send:
    cmp byte [rtw_keys], 0
    je .no
    cmp ecx, ETH_HLEN
    jb .no
    push r12
    mov r12, [rtw_mmio]
    mov rdi, rsi                        ; to its destination,
    movzx edx, word [rsi + 12]          ; its EtherType,
    add rsi, ETH_HLEN                   ; what it carries
    sub ecx, ETH_HLEN
    call rtw_wifi_send
    pop r12
    ret
.no:
    stc
    ret

; rtw_wifi_send(R12, RSI = a payload, ECX = its length, DX = its EtherType
; as it travels, RDI = the 6-byte address it goes to) -> CF if not sent:
; a data frame to the access point, protected (CCMP, the pairwise key)
; when the keys are in use. Preserves all but RAX.
rtw_wifi_send:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    cmp ecx, 1500
    ja .no
    mov eax, 0x0108                     ; data, to the DS
    xor r9d, r9d                        ; (no CCMP header)
    cmp byte [rtw_keys], 0
    je .header
    or eax, 0x4000                      ; protected
    mov r9d, 8
.header:
    mov [rtw_txd], eax
    mov eax, [rtw_bss]                  ; to the access point,
    mov [rtw_txd + 4], eax
    mov ax, [rtw_bss + 4]
    mov [rtw_txd + 8], ax
    mov eax, [rtw_mac]                  ; from us,
    mov [rtw_txd + 10], eax
    mov ax, [rtw_mac + 4]
    mov [rtw_txd + 14], ax
    mov eax, [rdi]                      ; for its destination
    mov [rtw_txd + 16], eax
    mov ax, [rdi + 4]
    mov [rtw_txd + 20], ax
    mov word [rtw_txd + 22], 0          ; (the chip numbers it)
    lea rdi, [rtw_txd + 24 + r9]
    movzx eax, dx                       ; LLC/SNAP and the EtherType
    shl rax, 48
    mov rdx, 0x00000003AAAA
    or rax, rdx
    mov [rdi], rax
    add rdi, 8
    push rcx
    rep movsb
    pop rcx
    add ecx, 8                          ; the body
    test r9d, r9d
    jz .plain
    push rsi
    push rdi
    lea rsi, [rtw_tk]
    lea rdi, [rtw_txd]
    mov edx, ecx
    mov ecx, 24
    mov r8, [rtw_tx_pn]
    xor r9d, r9d                        ; key 0
    call ccmp_seal
    inc qword [rtw_tx_pn]
    pop rdi
    pop rsi
    lea ecx, [edx + 24 + 8 + 8]         ; header, CCMP header, body, MIC
    jmp .send
.plain:
    add ecx, 24
.send:
    lea rsi, [rtw_txd]
    call rtw_data_send
    jmp .out
.no:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_rx_eth(RSI = a data frame's decrypted body (its LLC/SNAP header
; first), ECX = its length, RDX = the frame's 802.11 header, from the
; DS): made an Ethernet frame in place (the destination is address 1, the
; source address 3; the EtherType is where it goes already) and handed to
; net_receive. Frames we sent, echoed by the access point to everyone,
; are dropped. Preserves all but RAX.
rtw_rx_eth:
    mov eax, [rdx + 16]
    cmp eax, [rtw_mac]
    jne .theirs
    mov ax, [rdx + 20]
    cmp ax, [rtw_mac + 4]
    je .ours
.theirs:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov eax, [rdx + 4]                  ; destination
    mov [rsi - 6], eax
    mov ax, [rdx + 8]
    mov [rsi - 2], ax
    mov eax, [rdx + 16]                 ; source
    mov [rsi], eax
    mov ax, [rdx + 20]
    mov [rsi + 4], ax
    sub rsi, 6
    add ecx, 6
    mov rbx, [rtw_nic]
    call net_receive
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
.ours:
    ret

section .rodata
rtw_ops:        dq rtw_nic_send, rtw_nic_poll, rtw_nic_link, rtw_nic_ack
str_rtw_name:   db 'Realtek RTL8821CE (Wi-Fi)', 0

section .bss
alignb 16
rtw_txd:        resb 24 + 8 + 8 + 1500 + 8 + 16     ; a data frame being made
alignb 8
rtw_nic:        resq 1
rtw_tx_pn:      resq 1                  ; the next CCMP packet number
rtw_rejoin_at:  resq 1                  ; TSC
rtw_up:         resb 1                  ; the radio is on, for a network
