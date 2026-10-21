; =============================================================================
;  net.asm - network interfaces and what travels between them: Ethernet,
;  ARP, IPv4, ICMP and UDP. A driver registers an interface with a table of
;  operations and hands every frame it receives to net_receive; the first
;  interface carries the address. Everything runs on the BSP from the main
;  loop: net_service polls the drivers, watches the link and runs the timers,
;  and an MSI only wakes the loop.
;
;  An IPv4 address is kept as it travels: a dword whose low byte is the first
;  octet. Ports, lengths and types are swapped where they are read or written.
;  IPv6 is in ip6.asm.
; =============================================================================

MAX_NIC         equ 2

; an interface
NI_OPS          equ 0                   ; the driver's operations, below
NI_MMIO         equ 8
NI_NAME         equ 16                  ; the model, a string
NI_BDF          equ 24
NI_MSI          equ 28                  ; 0 polled, 1 MSI, 2 MSI-X
NI_MAC          equ 32                  ; 6 bytes
NI_KIND         equ 40                  ; the driver's: chip family
NI_XID          equ 44                  ; the driver's: chip version
NI_SPEED        equ 48                  ; Mbit/s; 0 no link, -1 not looked yet
NI_DUPLEX       equ 52                  ; 1 full
NI_IDS          equ 56                  ; PCI vendor | device << 16
NI_INDEX        equ 60
NI_RX           equ 64                  ; descriptor rings, mapped
NI_TX           equ 72
NI_RXBUF        equ 80                  ; their buffers, mapped
NI_TXBUF        equ 88
NI_RXI          equ 96                  ; next descriptor to look at
NI_TXI          equ 100                 ; next one to fill
NI_RXPK         equ 104                 ; counters
NI_RXBY         equ 112
NI_TXPK         equ 120
NI_TXBY         equ 128
NI_DROP         equ 136
NI_SIZE         equ 256

; driver operations, each with RBX = interface; they may clobber RAX, RCX,
; RDX, RSI, RDI and R8-R11:
;   send(RSI = frame, ECX = bytes) -> CF if the ring is full
;   poll: hand each frame received to net_receive
;   link: refresh NI_SPEED and NI_DUPLEX
;   ack: acknowledge the interrupt (called from the MSI handler)
NOP_SEND        equ 0
NOP_POLL        equ 8
NOP_LINK        equ 16
NOP_ACK         equ 24

ETH_HLEN        equ 14
ETH_MIN         equ 60                  ; shorter frames are padded
NET_FRAME       equ 1536
NET_PAYLOAD     equ ETH_HLEN + 20       ; an IP payload in net_frame
UDP_PAYLOAD     equ NET_PAYLOAD + 8     ; a UDP payload in net_frame
IP_MAXDATA      equ 1480                ; what fits after the IP header

ETYPE_IP        equ 0x0008              ; 0x0800 as it travels
ETYPE_ARP       equ 0x0608              ; 0x0806

; the ARP cache
ARP_SLOTS       equ 16
AR_IP           equ 0
AR_MAC          equ 4                   ; 6 bytes
AR_TIME         equ 16                  ; TSC when learned
AR_SIZE         equ 24
ARP_LIFE        equ 300                 ; seconds before asking again

; frames waiting for an ARP answer
ARP_WAITS       equ 4
AW_IP           equ 0                   ; the next hop asked about
AW_LEN          equ 4                   ; 0 = free
AW_TRIES        equ 8
AW_NEXT         equ 16                  ; TSC: ask again, or give up
AW_FRAME        equ 32
AW_SIZE         equ AW_FRAME + NET_FRAME

section .text

; -----------------------------------------------------------------------------
;  net_init: every network controller PCI reported, offered to the drivers
; -----------------------------------------------------------------------------
net_init:
    push rbx
    push r12
    push r13
    mov rax, [tsc_per_ms]
    imul rcx, rax, 4
    mov [net_poll_ticks], rcx
    imul rcx, rax, 50
    mov [net_busy_ticks], rcx
    shr rax, 2
    mov [net_fast_ticks], rax           ; a quarter of a millisecond
    mov rax, [tsc_per_ms]
    imul rcx, rax, 500
    mov [net_link_ticks], rcx
    imul rcx, rax, 1000
    mov [net_second], rcx
    imul rcx, rcx, ARP_LIFE
    mov [arp_life], rcx
    lea r12, [pci_devices]
    xor r13d, r13d
.next:
    cmp r13d, [pci_count]
    jae .done
    cmp byte [r12 + PE_CLASS], 0x02     ; network
    jne .skip
    mov rdi, r12
    call rtl_probe
    test eax, eax
    jnz .skip
    mov rdi, r12
    call rtw_probe                      ; the Wi-Fi card
    test eax, eax
    jnz .skip
    cmp byte [r12 + PE_SUBCLASS], 0x00  ; Ethernet that no driver took
    jne .skip
    mov rdi, r12
    lea rsi, [net_text]
    call pci_describe
    movzx eax, word [r12 + PE_VENDOR]
    movzx ecx, word [r12 + PE_DEVICE]
    lea rdx, [net_text]
    KLOG "net: no driver yet for %04x:%04x, %s", rax, rcx, rdx
.skip:
    add r12, PCI_ENTRY
    inc r13d
    jmp .next
.done:
    cmp dword [nic_count], 0
    jne .have
    KLOG "net: no network interface Axiom drives"
    jmp .out
.have:
    lea rax, [nics]
    mov [net_nic], rax
    call net_clock
    mov [net_link_at], rax              ; look at the link at once
.out:
    pop r13
    pop r12
    pop rbx
    ret

; nic_alloc -> RBX = a zeroed interface, CF if every slot is taken.
; Preserves others.
nic_alloc:
    push rax
    push rcx
    push rdi
    mov eax, [nic_count]
    cmp eax, MAX_NIC
    jae .full
    imul rbx, rax, NI_SIZE
    lea rcx, [nics]
    add rbx, rcx
    mov rdi, rbx
    mov ecx, NI_SIZE
    push rax
    xor eax, eax
    rep stosb
    pop rax
    mov [rbx + NI_INDEX], eax
    mov dword [rbx + NI_SPEED], -1
    clc
    jmp .out
.full:
    stc
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; nic_commit(RBX): the driver started it. Preserves all.
nic_commit:
    inc dword [nic_count]
    cmp dword [rbx + NI_MSI], 0
    jne .irq
    mov byte [net_polled], 1
    ret
.irq:
    cmp byte [net_irq_on], 0
    jne .out
    mov byte [net_irq_on], 1
    push rax
    push rdi
    push rsi
    mov edi, VEC_NET
    lea rsi, [net_irq]
    call irq_register
    pop rsi
    pop rdi
    pop rax
.out:
    ret

; net_irq: an interface's MSI. Acknowledge it; the main loop does the rest.
net_irq:
    push rbx
    push r12
    xor r12d, r12d
.nic:
    cmp r12d, [nic_count]
    jae .done
    imul rbx, r12, NI_SIZE
    lea rax, [nics]
    add rbx, rax
    cmp dword [rbx + NI_MSI], 0
    je .next
    mov rax, [rbx + NI_OPS]
    call [rax + NOP_ACK]
.next:
    inc r12d
    jmp .nic
.done:
    mov byte [net_pending], 1
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The main loop's part: frames in, link changes, timers
; -----------------------------------------------------------------------------
net_service:
    cmp dword [nic_count], 0
    je .out
    push rbx
    push r12
    mov byte [net_pending], 0
    xor r12d, r12d
.poll:
    imul rbx, r12, NI_SIZE
    lea rax, [nics]
    add rbx, rax
    mov rax, [rbx + NI_OPS]
    call [rax + NOP_POLL]
    inc r12d
    cmp r12d, [nic_count]
    jb .poll
    call net_clock
    cmp byte [net_active], 0            ; frames came or went: poll fast
    je .link
    mov byte [net_active], 0
    mov rcx, rax
    add rcx, [net_busy_ticks]
    mov [net_busy_until], rcx
.link:
    cmp rax, [net_link_at]
    jb .timers
    add rax, [net_link_ticks]
    mov [net_link_at], rax
    call net_links
.timers:
    call arp_tick
    call nd_tick
    call ip6_tick
    call dhcp_tick
    call dns_tick
    call ping_tick
    call tcp_tick
    call tcp_echo_tick
    call hd_tick
    pop r12
    pop rbx
.out:
    jmp sk_tick                         ; programs' sockets, interface or not

; net_deadline(RAX = a TSC deadline) -> RAX = the earlier of it and the next
; thing the network has to do. Called with interrupts off. Preserves others.
net_deadline:
    cmp dword [nic_count], 0
    je .out
    push rcx
    push rdx
    push rsi
    lea rsi, [net_timers]
    mov ecx, NET_TIMERS
.timer:
    mov rdx, [rsi]
    test rdx, rdx
    jz .next
    cmp rdx, rax
    cmovb rax, rdx
.next:
    add rsi, 8
    dec ecx
    jnz .timer
    cmp byte [net_polled], 0            ; an interface without an interrupt
    je .done
    mov rsi, rax
    RDTSC64
    mov rcx, [net_poll_ticks]           ; every 4 ms, or while frames flow
    cmp rax, [net_busy_until]           ; every quarter of one
    cmovb rcx, [net_fast_ticks]
    add rax, rcx
    cmp rsi, rax
    cmovb rax, rsi
.done:
    pop rsi
    pop rdx
    pop rcx
.out:
    ret

; net_links: ask each driver about its link; report changes, and start DHCP
; when the interface with the address comes up
net_links:
    push rbx
    push r12
    push r13
    push r14
    xor r12d, r12d
.nic:
    cmp r12d, [nic_count]
    jae .out
    imul rbx, r12, NI_SIZE
    lea rax, [nics]
    add rbx, rax
    mov r13d, [rbx + NI_SPEED]          ; before
    mov r14d, [rbx + NI_DUPLEX]
    mov rax, [rbx + NI_OPS]
    call [rax + NOP_LINK]
    mov eax, [rbx + NI_SPEED]
    cmp eax, r13d
    jne .changed
    cmp r14d, [rbx + NI_DUPLEX]
    je .next
.changed:
    mov ecx, r12d
    test eax, eax
    jnz .up
    cmp r13d, -1
    je .never
    KLOG "net%u: link down", rcx
    jmp .next
.never:
    KLOG "net%u: no link (is the cable in?)", rcx
    jmp .next
.up:
    lea rdx, [str_half]
    cmp dword [rbx + NI_DUPLEX], 0
    je .say
    lea rdx, [str_full]
.say:
    KLOG "net%u: link up, %u Mbit/s, %s duplex", rcx, rax, rdx
    cmp r13d, 0
    jg .next                            ; only the speed changed
    cmp rbx, [net_nic]
    jne .next
    call net_link_up
.next:
    inc r12d
    jmp .nic
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; net_clock -> RAX = the TSC, also kept in net_now. Preserves others.
net_clock:
    push rdx
    RDTSC64
    mov [net_now], rax
    pop rdx
    ret

; net_random -> EAX = 32 random bits (RDRAND, else the TSC stirred).
; Preserves others.
net_random:
    push rcx
    push rdx
    test dword [cpu_f1_ecx], 1 << 30
    jz .tsc
    mov ecx, 10
.try:
    rdrand eax
    jc .out
    dec ecx
    jnz .try
.tsc:
    rdtsc
    xor eax, edx
    imul eax, eax, 0x2545F491
    rol eax, 13
.out:
    pop rdx
    pop rcx
    ret

; net_sum(RSI = data, ECX = bytes, EAX = a sum to go on from) -> EAX = the
; ones-complement sum of the 16-bit words as they lie in memory, unfolded.
; Preserves others.
net_sum:
    push rcx
    push rdx
    push rsi
    mov edx, eax
.words:
    cmp ecx, 2
    jb .odd
    movzx eax, word [rsi]
    add rdx, rax
    add rsi, 2
    sub ecx, 2
    jmp .words
.odd:
    test ecx, ecx
    jz .fold
    movzx eax, byte [rsi]               ; the last byte, padded with a zero
    add rdx, rax
.fold:
    mov rax, rdx
    shr rax, 32
    add edx, eax
    adc edx, 0
    mov eax, edx
    pop rsi
    pop rdx
    pop rcx
    ret

; net_fold(EAX = a sum from net_sum) -> EAX = the checksum to store as a
; word; 0 when checking a header whose checksum is right. Preserves others.
net_fold:
    push rcx
    mov ecx, eax
    shr ecx, 16
    and eax, 0xFFFF
    add eax, ecx
    mov ecx, eax
    shr ecx, 16
    add eax, ecx
    not eax
    and eax, 0xFFFF
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Ethernet
; -----------------------------------------------------------------------------

; net_receive(RBX = interface, RSI = frame, ECX = bytes): from a driver
net_receive:
    mov ecx, ecx
    mov byte [net_active], 1
    inc qword [rbx + NI_RXPK]
    add [rbx + NI_RXBY], rcx
    cmp rbx, [net_nic]                  ; only that one has an address
    jne .out
    cmp ecx, ETH_HLEN
    jb .out
    movzx eax, word [rsi + 12]
    cmp eax, ETYPE_ARP
    je arp_input
    cmp eax, ETYPE_IP
    je ip_input
    cmp eax, ETYPE_IP6
    je ip6_input
.out:
    ret

; eth_send(RDX = frame, RDI = destination MAC, ESI = type as it travels,
; ECX = bytes): fill in the header, send it. CF if it could not go.
; Preserves all but RAX.
eth_send:
    push rbx
    mov rbx, [net_nic]
    test rbx, rbx
    jz .fail
    mov eax, [rdi]
    mov [rdx], eax
    mov ax, [rdi + 4]
    mov [rdx + 4], ax
    mov eax, [rbx + NI_MAC]
    mov [rdx + 6], eax
    mov ax, [rbx + NI_MAC + 4]
    mov [rdx + 10], ax
    mov [rdx + 12], si
    pop rbx
    jmp nic_send
.fail:
    pop rbx
    stc
    ret

; nic_send(RDX = frame, ECX = bytes): out through the interface with the
; address, padded to the Ethernet minimum (the buffer must have room for
; that). CF if it could not go. Preserves all but RAX.
nic_send:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov ecx, ecx
    mov rbx, [net_nic]
    test rbx, rbx
    jz .fail
    cmp dword [rbx + NI_SPEED], 0
    jle .fail                           ; no link: nothing goes out
    cmp ecx, ETH_MIN
    jae .send
    lea rdi, [rdx + rcx]
    neg ecx
    add ecx, ETH_MIN
    xor eax, eax
    rep stosb
    mov ecx, ETH_MIN
.send:
    push rcx
    mov rsi, rdx
    mov rax, [rbx + NI_OPS]
    call [rax + NOP_SEND]
    pop rcx
    jc .full
    mov byte [net_active], 1            ; an answer may come soon
    inc qword [rbx + NI_TXPK]
    add [rbx + NI_TXBY], rcx
    clc
    jmp .out
.full:
    inc qword [rbx + NI_DROP]
.fail:
    stc
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  ARP
; -----------------------------------------------------------------------------

; arp_input(RBX, RSI = frame, ECX = bytes)
arp_input:
    cmp ecx, ETH_HLEN + 28
    jb .out
    lea rdi, [rsi + ETH_HLEN]
    cmp dword [rdi], 0x00080100         ; Ethernet, IPv4
    jne .out
    cmp word [rdi + 4], 0x0406          ; 6-byte and 4-byte addresses
    jne .out
    mov edx, [net_ip]
    test edx, edx
    jz .out
    mov eax, [rdi + 14]                 ; the sender's address
    test eax, eax
    jz .out                             ; a probe: nothing to learn
    lea rsi, [rdi + 8]                  ; the sender's MAC
    cmp [rdi + 24], edx                 ; about us?
    jne .update
    call arp_learn
    cmp word [rdi + 6], 0x0100          ; a request: answer it
    jne .out
    mov eax, [rdi + 14]
    lea rdi, [rdi + 8]
    mov esi, 0x0200
    jmp arp_send
.update:                                ; not about us: refresh what we know
    call arp_find
    jc .out
    jmp arp_learn
.out:
    ret

; arp_send(ESI = 0x0100 request or 0x0200 reply, as they travel; RDI = the
; MAC it goes to; EAX = the address it is about). Preserves all but RAX.
arp_send:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rbx, [net_nic]
    lea rdx, [arp_frame]
    lea r8, [rdx + ETH_HLEN]
    mov dword [r8], 0x00080100
    mov word [r8 + 4], 0x0406
    mov [r8 + 6], si
    mov ecx, [rbx + NI_MAC]
    mov [r8 + 8], ecx
    mov cx, [rbx + NI_MAC + 4]
    mov [r8 + 12], cx
    mov ecx, [net_ip]
    mov [r8 + 14], ecx
    xor ecx, ecx                        ; a request names no MAC
    mov [r8 + 18], ecx
    mov [r8 + 22], cx
    cmp si, 0x0100
    je .target
    mov ecx, [rdi]
    mov [r8 + 18], ecx
    mov cx, [rdi + 4]
    mov [r8 + 22], cx
.target:
    mov [r8 + 24], eax
    mov esi, ETYPE_ARP
    mov ecx, ETH_HLEN + 28
    call eth_send
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; arp_ask(EAX = address): who has it? Preserves all.
arp_ask:
    push rax
    push rsi
    push rdi
    lea rdi, [mac_broadcast]
    mov esi, 0x0100
    call arp_send
    pop rdi
    pop rsi
    pop rax
    ret

; arp_slot(EAX = address) -> RDX = its entry, else a free one, else the
; oldest. Preserves others.
arp_slot:
    push rcx
    push r8
    lea rdx, [arp_cache]
    mov ecx, ARP_SLOTS
.same:
    cmp [rdx + AR_IP], eax
    je .out
    add rdx, AR_SIZE
    dec ecx
    jnz .same
    lea rdx, [arp_cache]
    mov r8, rdx
    mov ecx, ARP_SLOTS
.other:
    cmp dword [rdx + AR_IP], 0
    je .out
    push rax
    mov rax, [rdx + AR_TIME]
    cmp rax, [r8 + AR_TIME]
    pop rax
    jae .older
    mov r8, rdx
.older:
    add rdx, AR_SIZE
    dec ecx
    jnz .other
    mov rdx, r8
.out:
    pop r8
    pop rcx
    ret

; arp_find(EAX = address) -> RDX = its entry, CF if unknown or too old.
; Preserves others.
arp_find:
    test eax, eax
    jz .none
    call arp_slot
    cmp [rdx + AR_IP], eax
    jne .none
    push rax
    mov rax, [net_now]
    sub rax, [rdx + AR_TIME]
    cmp rax, [arp_life]
    pop rax
    jae .none
    clc
    ret
.none:
    stc
    ret

; arp_learn(EAX = address, RSI = its MAC): remember it, and send what was
; waiting for it. Preserves all but RAX.
arp_learn:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call arp_slot
    mov [rdx + AR_IP], eax
    mov ecx, [rsi]
    mov [rdx + AR_MAC], ecx
    mov cx, [rsi + 4]
    mov [rdx + AR_MAC + 4], cx
    mov rcx, [net_now]
    mov [rdx + AR_TIME], rcx
    lea rdi, [rdx + AR_MAC]
    lea r8, [arp_waits]
    mov r9d, ARP_WAITS
.wait:
    cmp dword [r8 + AW_LEN], 0
    je .next
    cmp [r8 + AW_IP], eax
    jne .next
    push rax
    lea rdx, [r8 + AW_FRAME]
    mov ecx, [r8 + AW_LEN]
    mov esi, ETYPE_IP
    call eth_send
    pop rax
    mov dword [r8 + AW_LEN], 0
.next:
    add r8, AW_SIZE
    dec r9d
    jnz .wait
    call arp_arm
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; arp_queue(EAX = next hop, ECX = bytes of net_frame): keep the frame until
; the hop answers, and ask. Preserves all but RAX.
arp_queue:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea r8, [arp_waits]
    mov edx, ARP_WAITS
.find:
    cmp dword [r8 + AW_LEN], 0
    je .slot
    add r8, AW_SIZE
    dec edx
    jnz .find
    lea r8, [arp_waits]                 ; all taken: the first gives way
    mov rdx, [net_nic]
    inc qword [rdx + NI_DROP]
.slot:
    mov [r8 + AW_IP], eax
    mov [r8 + AW_LEN], ecx
    mov dword [r8 + AW_TRIES], 1
    lea rdi, [r8 + AW_FRAME]
    lea rsi, [net_frame]
    rep movsb
    push rax
    call net_clock
    add rax, [net_second]
    mov [r8 + AW_NEXT], rax
    pop rax
    call arp_ask
    call arp_arm
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; arp_tick: ask again, three times a second apart, then give up
arp_tick:
    mov rax, [arp_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    push r8
    push r12
    lea r8, [arp_waits]
    mov r12d, ARP_WAITS
.wait:
    cmp dword [r8 + AW_LEN], 0
    je .next
    mov rax, [r8 + AW_NEXT]
    cmp rax, [net_now]
    ja .next
    cmp dword [r8 + AW_TRIES], 3
    jae .give_up
    inc dword [r8 + AW_TRIES]
    mov rax, [net_now]
    add rax, [net_second]
    mov [r8 + AW_NEXT], rax
    mov eax, [r8 + AW_IP]
    call arp_ask
    jmp .next
.give_up:
    mov dword [r8 + AW_LEN], 0
    mov rax, [net_nic]
    inc qword [rax + NI_DROP]
    mov eax, [r8 + AW_IP]
    cmp eax, [arp_failed]               ; say so once per address
    je .next
    mov [arp_failed], eax
    KLOG "net: nobody answers ARP for %I", rax
.next:
    add r8, AW_SIZE
    dec r12d
    jnz .wait
    pop r12
    pop r8
    call arp_arm
.out:
    ret

; arp_arm: arp_next = the earliest deadline of a waiting frame, 0 if none.
; Preserves all.
arp_arm:
    push rax
    push rcx
    push rdx
    xor eax, eax
    lea rdx, [arp_waits]
    mov ecx, ARP_WAITS
.wait:
    cmp dword [rdx + AW_LEN], 0
    je .next
    test rax, rax
    jz .take
    cmp rax, [rdx + AW_NEXT]
    jbe .next
.take:
    mov rax, [rdx + AW_NEXT]
.next:
    add rdx, AW_SIZE
    dec ecx
    jnz .wait
    mov [arp_next], rax
    pop rdx
    pop rcx
    pop rax
    ret

; arp_flush: forget every address (a new network, a new address).
; Preserves all.
arp_flush:
    push rax
    push rcx
    push rdi
    lea rdi, [arp_cache]
    mov ecx, ARP_SLOTS * AR_SIZE
    xor eax, eax
    rep stosb
    mov [arp_failed], eax
    pop rdi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  IPv4
; -----------------------------------------------------------------------------

; ip_send(EDI = destination, ESI = protocol, ECX = bytes of payload, already
; at net_frame + NET_PAYLOAD) -> CF if there is no route. A frame for a
; neighbour nobody has named yet waits for ARP. Preserves all but RAX.
ip_send:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea r8, [net_frame + ETH_HLEN]
    lea ebx, [ecx + 20]                 ; total length
    mov eax, ebx
    xchg al, ah
    mov word [r8], 0x0045               ; version 4, 20-byte header, TOS 0
    mov [r8 + 2], ax
    inc dword [net_ipid]
    mov eax, [net_ipid]
    xchg al, ah
    mov [r8 + 4], ax
    mov word [r8 + 6], 0                ; not fragmented
    mov byte [r8 + 8], 64               ; time to live
    mov [r8 + 9], sil
    mov word [r8 + 10], 0
    mov eax, [net_ip]
    mov [r8 + 12], eax
    mov [r8 + 16], edi
    mov rsi, r8
    mov ecx, 20
    xor eax, eax
    call net_sum
    call net_fold
    mov [r8 + 10], ax
    lea ecx, [ebx + ETH_HLEN]           ; the frame's length from here on
    cmp edi, -1
    je .broadcast
    mov eax, [net_ip]
    test eax, eax
    jz .no_route
    mov edx, [net_mask]
    xor eax, edi
    test eax, edx
    jnz .remote
    mov eax, edx                        ; this network's broadcast?
    not eax
    or eax, [net_ip]
    cmp edi, eax
    je .broadcast
    mov eax, edi
    jmp .resolve
.remote:
    mov eax, [net_gw]
    test eax, eax
    jz .no_route
.resolve:
    call arp_find
    jc .ask
    lea rdi, [rdx + AR_MAC]
    jmp .send
.ask:
    call arp_queue
    clc
    jmp .out
.broadcast:
    lea rdi, [mac_broadcast]
.send:
    lea rdx, [net_frame]
    mov esi, ETYPE_IP
    call eth_send
    clc
    jmp .out
.no_route:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; ip_input(RBX, RSI = frame, ECX = bytes)
ip_input:
    sub ecx, ETH_HLEN
    lea rdi, [rsi + ETH_HLEN]
    cmp ecx, 20
    jb .out
    movzx edx, byte [rdi]
    mov eax, edx
    shr eax, 4
    cmp eax, 4
    jne .out
    and edx, 15                         ; EDX = header bytes
    shl edx, 2
    cmp edx, 20
    jb .out
    movzx eax, word [rdi + 2]           ; total length
    xchg al, ah
    cmp eax, ecx
    ja .out
    cmp eax, edx
    jb .out
    mov ecx, eax                        ; the rest is padding
    push rcx
    mov rsi, rdi
    mov ecx, edx
    xor eax, eax
    call net_sum
    call net_fold
    pop rcx
    test eax, eax
    jnz .out
    test word [rdi + 6], 0xFF3F         ; a fragment: not reassembled
    jnz .out
    mov eax, [rdi + 16]                 ; for us?
    mov r8d, [net_ip]
    test r8d, r8d
    jz .ours                            ; no address yet: DHCP answers come to it
    cmp eax, r8d
    je .ours
    cmp eax, -1
    je .ours
    mov r9d, [net_mask]
    not r9d
    or r9d, r8d
    cmp eax, r9d
    jne .out
.ours:
    mov al, [rdi + 9]
    cmp al, 1
    je icmp_input
    cmp al, 17
    je udp_input
    cmp al, 6
    je tcp_input
.out:
    ret

; -----------------------------------------------------------------------------
;  ICMP
; -----------------------------------------------------------------------------

; icmp_input(RBX, RDI = IP header, EDX = its bytes, ECX = the packet's bytes)
icmp_input:
    lea rsi, [rdi + rdx]
    sub ecx, edx
    cmp ecx, 8
    jb .out
    xor eax, eax
    call net_sum
    call net_fold
    test eax, eax
    jnz .out
    mov al, [rsi]
    cmp al, 8
    je .echo
    cmp al, 0
    je .reply
    cmp al, 3
    je ping_error
    cmp al, 11
    je ping_error
.out:
    ret
.echo:                                  ; asked: the same message back
    mov eax, [net_ip]
    test eax, eax
    jz .out
    cmp [rdi + 16], eax                 ; to us, not to everyone
    jne .out
    cmp ecx, IP_MAXDATA
    ja .out
    push rdi
    lea rdi, [net_frame + NET_PAYLOAD]
    push rcx
    rep movsb
    pop rcx
    pop rdi
    lea rsi, [net_frame + NET_PAYLOAD]
    mov byte [rsi], 0                   ; echo reply
    mov word [rsi + 2], 0
    xor eax, eax
    call net_sum
    call net_fold
    mov [rsi + 2], ax
    mov edi, [rdi + 12]
    mov esi, 1
    jmp ip_send
.reply:
    push rdi
    mov eax, [rdi + 12]
    lea rdi, [net_from]
    call addr_set4
    pop rdi
    lea rdx, [net_from]
    movzx r8d, byte [rdi + 8]
    jmp ping_reply

; -----------------------------------------------------------------------------
;  UDP
; -----------------------------------------------------------------------------

; udp_input(RBX, RDI = IP header, EDX = its bytes, ECX = the packet's bytes)
udp_input:
    lea rsi, [rdi + rdx]
    sub ecx, edx
    cmp ecx, 8
    jb .out
    movzx eax, word [rsi + 4]
    xchg al, ah
    cmp eax, 8
    jb .out
    cmp eax, ecx
    ja .out
    mov ecx, eax
    cmp word [rsi + 6], 0               ; a checksum to check?
    je .checked
    call udp_pseudo
    call net_sum
    call net_fold
    test eax, eax
    jnz .out
.checked:
    movzx eax, word [rsi + 2]           ; to which port
    xchg al, ah
    mov edx, [rdi + 12]                 ; from whom
    add rsi, 8
    sub ecx, 8
    cmp eax, 68
    je dhcp_input
    cmp eax, 49152                      ; where DNS questions go from
    jb .out
    push rax
    push rdi
    mov eax, edx
    lea rdi, [net_from]
    call addr_set4
    pop rdi
    pop rax
    lea rdx, [net_from]
    jmp dns_input
.out:
    ret

; udp_pseudo(RDI = IP header, ECX = UDP bytes) -> EAX = the pseudo-header's
; sum: both addresses, the protocol and the length. Preserves others.
udp_pseudo:
    push rcx
    push rsi
    mov eax, ecx
    xchg al, ah
    movzx eax, ax
    add eax, 0x1100                     ; a zero byte, then 17
    lea rsi, [rdi + 12]
    mov ecx, 8
    call net_sum
    pop rsi
    pop rcx
    ret

; udp_send(EDI = destination, ESI = source port, EDX = destination port,
; ECX = bytes of payload, already at net_frame + UDP_PAYLOAD) -> CF if there
; is no route. Preserves all but RAX.
udp_send:
    push rcx
    push rsi
    push rdi
    push r8
    lea r8, [net_frame + NET_PAYLOAD]
    mov eax, esi
    xchg al, ah
    mov [r8], ax
    mov eax, edx
    xchg al, ah
    mov [r8 + 2], ax
    add ecx, 8
    mov eax, ecx
    xchg al, ah
    mov [r8 + 4], ax
    mov word [r8 + 6], 0
    mov eax, [net_ip]                   ; the addresses ip_send will use
    mov [net_frame + ETH_HLEN + 12], eax
    mov [net_frame + ETH_HLEN + 16], edi
    push rdi
    lea rdi, [net_frame + ETH_HLEN]
    call udp_pseudo
    pop rdi
    mov rsi, r8
    call net_sum
    call net_fold
    test eax, eax
    jnz .sum
    mov eax, 0xFFFF                     ; 0 would mean "no checksum"
.sum:
    mov [r8 + 6], ax
    mov esi, 17
    call ip_send
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

section .rodata
mac_broadcast:  db 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF
str_full:       db 'full', 0
str_half:       db 'half', 0

section .bss
alignb 8
nics:           resb MAX_NIC * NI_SIZE
nic_count:      resd 1
net_ip:         resd 1                  ; ours: 0 until DHCP or 'ip' sets one
net_mask:       resd 1
net_gw:         resd 1
net_dns:        resd 1
net_ipid:       resd 1
arp_failed:     resd 1
net_polled:     resb 1                  ; an interface without an interrupt
net_pending:    resb 1                  ; the MSI fired
net_irq_on:     resb 1
net_active:     resb 1                  ; a frame came or went since the last look
alignb 8
net_nic:        resq 1                  ; the interface with the address
net_now:        resq 1                  ; TSC, as of the last net_clock
net_poll_ticks: resq 1
net_fast_ticks: resq 1                  ; polling while frames flow
net_busy_ticks: resq 1                  ; and for how long after the last
net_busy_until: resq 1
net_link_ticks: resq 1
net_second:     resq 1
arp_life:       resq 1
net_timers:                             ; TSC deadlines, 0 = none
net_link_at:    resq 1
arp_next:       resq 1
dhcp_next:      resq 1
dns_next:       resq 1
ping_next:      resq 1
tcp_next:       resq 1
ip6_next:       resq 1
nd_next:        resq 1
NET_TIMERS      equ 8
net_from:       resb 16                 ; a sender, as an address (ip6.asm)
net_text:       resb 128
arp_cache:      resb ARP_SLOTS * AR_SIZE
arp_frame:      resb 64
alignb 16
net_frame:      resb NET_FRAME
arp_waits:      resb ARP_WAITS * AW_SIZE
