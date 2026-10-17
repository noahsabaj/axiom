; =============================================================================
;  rtl8168.asm - Realtek gigabit Ethernet: the RTL8111/8168 family on PCI
;  Express (the "Gaming GbE" of many boards), and the RTL8139C+ that QEMU
;  emulates, whose C+ mode has the same descriptor rings and registers but
;  for the TX poll and the link. One receive ring and one transmit ring of
;  16-byte descriptors, a 2 KiB buffer per descriptor; frames are copied in
;  and out. The main loop polls; an MSI wakes it.
;
;  Registers by convention: RBX = interface, R12 = its registers.
; =============================================================================

RT_RXN          equ 128                 ; receive descriptors: 2 KiB, the most the page has
RT_TXN          equ 32                  ; transmit descriptors (QEMU takes 64 at most)
RT_BUF          equ 2048                ; bytes per buffer
RT_BUF_SHIFT    equ 11

; registers
RT_IDR          equ 0x00                ; the MAC address
RT_MAR          equ 0x08                ; multicast filter
RT_TNPDS        equ 0x20                ; transmit ring, 64-bit
RT_CR           equ 0x37                ; command: reset, receive, transmit
RT_TPPOLL       equ 0x38                ; 8168: "look at the transmit ring"
RT_IMR          equ 0x3C
RT_ISR          equ 0x3E
RT_TCR          equ 0x40
RT_RCR          equ 0x44
RT_9346         equ 0x50                ; configuration lock
RT_PHYAR        equ 0x60                ; 8168 before the G: PHY registers
RT_BMSR         equ 0x64                ; 8139: MII status
RT_PHYSTATUS    equ 0x6C                ; 8168: link, speed, duplex
RT_ERIDR        equ 0x70                ; 8168: extended registers
RT_ERIAR        equ 0x74
RT_MAC_OCP      equ 0xB0                ; 8168G and later: MAC registers
RT_GPHY_OCP     equ 0xB8                ; 8168G and later: PHY registers
RT_MCU          equ 0xD3
RT_TPPOLL_C     equ 0xD9                ; 8139C+: the transmit poll
RT_RMS          equ 0xDA                ; largest frame received
RT_CPCR         equ 0xE0                ; C+ command
RT_INTRMIT      equ 0xE2                ; interrupt moderation
RT_RDSAR        equ 0xE4                ; receive ring, 64-bit
RT_MTPS         equ 0xEC                ; largest frame sent
RT_MISC         equ 0xF0

RT_IRQS         equ 0x0073              ; RX ok and error, no descriptors, link, FIFO

; descriptor, first dword
DESC_OWN        equ 1 << 31             ; the chip's
DESC_EOR        equ 1 << 30             ; the last: wrap
DESC_FS         equ 1 << 29             ; first and last piece of a frame
DESC_LS         equ 1 << 28
DESC_LEN        equ 0x1FFF

; chip families (NI_KIND)
RTK_8168        equ 0                   ; 8168B to 8168F
RTK_8168G       equ 1                   ; 8168G and later: OCP access, RXDV gate
RTK_8139C       equ 2                   ; 8139C+ (QEMU)

section .text

; rtl_probe(RDI = PCI entry) -> EAX = 0 not a Realtek chip this driver
; knows, 1 started, 2 known but it did not start
rtl_probe:
    cmp word [rdi + PE_VENDOR], 0x10EC
    jne .not
    movzx eax, word [rdi + PE_DEVICE]
    mov edx, RTK_8168
    cmp eax, 0x8168
    je .ours
    cmp eax, 0x8161
    je .ours
    mov edx, RTK_8139C
    cmp eax, 0x8139
    jne .not
    cmp byte [rdi + PE_REV], 0x20       ; C+ mode from revision 0x20
    jae .ours
.not:
    xor eax, eax
    ret
.ours:
    push rbx
    push r12
    push r13
    push r14
    mov r13, rdi
    mov r14d, edx
    call nic_alloc
    jc .full
    mov [rbx + NI_KIND], r14d
    mov eax, [r13 + PE_VENDOR]          ; vendor and device
    mov [rbx + NI_IDS], eax
    lea rax, [rtl_ops]
    mov [rbx + NI_OPS], rax
    call pci_bdf
    mov [rbx + NI_BDF], eax
    call rtl_start
    jc .failed
    call nic_commit
    mov ecx, [rbx + NI_INDEX]
    mov rdx, [rbx + NI_NAME]
    mov r8d, [rbx + NI_XID]
    lea r9, [rbx + NI_MAC]
    mov eax, [rbx + NI_MSI]
    lea rsi, [usb_irq_names]
    mov rsi, [rsi + rax * 8]
    KLOG "net%u: %s (chip %03x), MAC %M, %s", rcx, rdx, r8, r9, rsi
    mov eax, 1
    jmp .out
.full:
    KLOG "net: no room for another interface"
    mov eax, 2
    jmp .out
.failed:
    movzx eax, word [r13 + PE_DEVICE]
    KLOG "net: Realtek 10ec:%04x did not start", rax
    mov eax, 2
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rtl_start(RBX) -> CF if unusable
rtl_start:
    push r12
    mov edi, [rbx + NI_BDF]
    call pci_power_on
    call pci_mem_bar
    jc .fail
    mov r12, rax
    mov esi, 0x04                       ; memory decode, bus master, no INTx
    call pci_read32
    or eax, 6 | (1 << 10)
    mov edx, eax
    call pci_write32
    mov rdi, r12
    mov esi, 0x1000
    call mmio_map
    test rax, rax
    jz .fail
    mov [rbx + NI_MMIO], rax
    mov r12, rax
    mov eax, [r12 + RT_TCR]             ; the chip's version, as Linux reads it
    shr eax, 20
    and eax, 0xFCF
    mov [rbx + NI_XID], eax
    lea rdx, [str_rtl8139]
    cmp dword [rbx + NI_KIND], RTK_8139C
    cmove rax, rdx
    je .named
    and eax, 0x7C0
    cmp eax, 0x4C0                      ; 8168G (XID 4c0) and later
    jb .older
    mov dword [rbx + NI_KIND], RTK_8168G
    call rtl_quiesce
.older:
    lea rax, [str_rtl8168]
.named:
    mov [rbx + NI_NAME], rax
    mov byte [r12 + RT_CR], 0x10        ; reset
    mov ecx, 1000
.reset:
    mov edi, 10
    call delay_us
    test byte [r12 + RT_CR], 0x10
    jz .reset_done
    dec ecx
    jnz .reset
    jmp .fail
.reset_done:
    call rtl_mac
    jc .fail
    call rtl_rings
    jc .fail
    call rtl_setup
    cmp dword [rbx + NI_KIND], RTK_8139C
    je .irq
    call rtl_phy_wake
.irq:
    mov edi, [rbx + NI_BDF]
    mov esi, VEC_NET
    call pci_msi
    mov [rbx + NI_MSI], eax
    test eax, eax
    jz .ok
    mov word [r12 + RT_IMR], RT_IRQS
.ok:
    clc
    pop r12
    ret
.fail:
    stc
    pop r12
    ret

; rtl_quiesce(RBX, R12): 8168G and later. Hold received frames back, let the
; FIFOs drain, take the chip from its out-of-band firmware (wake-on-LAN and
; remote management run there while no driver does), as Linux does before
; its first reset. Failures here are not fatal.
rtl_quiesce:
    or dword [r12 + RT_MISC], 1 << 19   ; RXDV gate closed
    mov ecx, 42
.tx_empty:
    test dword [r12 + RT_TCR], 1 << 11
    jnz .tx_done
    mov edi, 100
    call delay_us
    dec ecx
    jnz .tx_empty
.tx_done:
    mov ecx, 42
.rxtx_empty:
    mov al, [r12 + RT_MCU]
    and al, 0x30
    cmp al, 0x30
    je .rxtx_done
    mov edi, 100
    call delay_us
    dec ecx
    jnz .rxtx_empty
.rxtx_done:
    and byte [r12 + RT_CR], ~0x0C       ; receive and transmit off
    mov edi, 1000
    call delay_us
    and byte [r12 + RT_MCU], ~0x80      ; NOW_IS_OOB: the host drives it now
    mov esi, 0xE8DE
    call rtl_ocp_read
    and eax, ~(1 << 14)
    mov edx, eax
    call rtl_ocp_write
    call rtl_fifo_ready
    mov esi, 0xE8DE
    call rtl_ocp_read
    or eax, 1 << 15
    mov edx, eax
    call rtl_ocp_write
    jmp rtl_fifo_ready

; rtl_fifo_ready(R12): wait up to 4 ms for the shared FIFO
rtl_fifo_ready:
    mov ecx, 42
.wait:
    mov esi, 0xE00E
    call rtl_ocp_read
    test eax, 1 << 13
    jnz .out
    mov edi, 100
    call delay_us
    dec ecx
    jnz .wait
.out:
    ret

; rtl_ocp_read(R12, ESI = MAC OCP address) -> EAX. Preserves others.
rtl_ocp_read:
    mov eax, esi
    shl eax, 15
    mov [r12 + RT_MAC_OCP], eax
    mov eax, [r12 + RT_MAC_OCP]
    and eax, 0xFFFF
    ret

; rtl_ocp_write(R12, ESI = MAC OCP address, EDX = value). Preserves all.
rtl_ocp_write:
    push rax
    mov eax, esi
    shl eax, 15
    or eax, edx
    or eax, 1 << 31
    mov [r12 + RT_MAC_OCP], eax
    pop rax
    ret

; rtl_mac(RBX, R12) -> CF if the chip has no usable MAC address. The ID
; registers hold it after a reset; a G-family chip also keeps it in its
; extended registers.
rtl_mac:
    mov eax, [r12 + RT_IDR]
    mov [rbx + NI_MAC], eax
    mov ax, [r12 + RT_IDR + 4]
    mov [rbx + NI_MAC + 4], ax
    call rtl_mac_ok
    jnc .out
    cmp dword [rbx + NI_KIND], RTK_8168G
    jne .bad
    mov esi, 0xE0
    call rtl_eri_read
    jc .bad
    mov [rbx + NI_MAC], eax
    mov esi, 0xE4
    call rtl_eri_read
    jc .bad
    mov [rbx + NI_MAC + 4], ax
    call rtl_mac_ok
    jc .bad
    mov eax, [rbx + NI_MAC]             ; and tell the receive filter
    mov byte [r12 + RT_9346], 0xC0
    mov [r12 + RT_IDR], eax
    mov ax, [rbx + NI_MAC + 4]
    mov [r12 + RT_IDR + 4], ax
    mov byte [r12 + RT_9346], 0
    clc
.out:
    ret
.bad:
    KLOG "net: the Realtek chip has no MAC address"
    stc
    ret

; rtl_mac_ok(RBX) -> CF if NI_MAC is all zeros or a group address
rtl_mac_ok:
    test byte [rbx + NI_MAC], 1
    jnz .bad
    mov eax, [rbx + NI_MAC]
    or ax, [rbx + NI_MAC + 4]
    test eax, eax
    jz .bad
    clc
    ret
.bad:
    stc
    ret

; rtl_eri_read(R12, ESI = extended register) -> EAX, CF on timeout
rtl_eri_read:
    push rcx
    mov eax, esi
    or eax, 0xF << 12                   ; all four bytes
    mov [r12 + RT_ERIAR], eax
    mov ecx, 100
.wait:
    mov edi, 100
    call delay_us
    test dword [r12 + RT_ERIAR], 1 << 31
    jnz .done
    dec ecx
    jnz .wait
    stc
    pop rcx
    ret
.done:
    mov eax, [r12 + RT_ERIDR]
    clc
    pop rcx
    ret

; rtl_rings(RBX) -> CF if there is no memory. One page holds both rings
; (receive at 0, transmit at 2 KiB); the buffers follow in two blocks.
rtl_rings:
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    add rax, [phys_base]
    mov [rbx + NI_RX], rax
    add rax, 2048
    mov [rbx + NI_TX], rax
    mov edi, RT_RXN * RT_BUF / 4096
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    add rax, [phys_base]
    mov [rbx + NI_RXBUF], rax
    mov edi, RT_TXN * RT_BUF / 4096
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    add rax, [phys_base]
    mov [rbx + NI_TXBUF], rax
    mov rdi, [rbx + NI_RX]              ; receive: all the chip's
    mov rdx, [rbx + NI_RXBUF]
    sub rdx, [phys_base]
    xor ecx, ecx
.rx:
    mov eax, DESC_OWN | RT_BUF
    cmp ecx, RT_RXN - 1
    jne .rx_set
    or eax, DESC_EOR
.rx_set:
    mov dword [rdi + 4], 0
    mov [rdi + 8], rdx
    mov [rdi], eax
    add rdi, 16
    add rdx, RT_BUF
    inc ecx
    cmp ecx, RT_RXN
    jb .rx
    mov rdi, [rbx + NI_TX]              ; transmit: all ours
    mov rdx, [rbx + NI_TXBUF]
    sub rdx, [phys_base]
    xor ecx, ecx
.tx:
    xor eax, eax
    cmp ecx, RT_TXN - 1
    jne .tx_set
    mov eax, DESC_EOR
.tx_set:
    mov [rdi], eax
    mov dword [rdi + 4], 0
    mov [rdi + 8], rdx
    add rdi, 16
    add rdx, RT_BUF
    inc ecx
    cmp ecx, RT_TXN
    jb .tx
    mov dword [rbx + NI_RXI], 0
    mov dword [rbx + NI_TXI], 0
    clc
    ret
.fail:
    stc
    ret

; rtl_setup(RBX, R12): the registers after a reset, in the order Linux uses
rtl_setup:
    mov byte [r12 + RT_9346], 0xC0      ; unlock
    cmp dword [rbx + NI_KIND], RTK_8139C
    jne .gigabit
    mov word [r12 + RT_CPCR], 0x0003    ; C+ mode: receive and transmit
    jmp .rings
.gigabit:
    movzx eax, word [r12 + RT_CPCR]
    and eax, 0x2063                     ; keep: normal mode, VLAN, checksums, timer
    mov [r12 + RT_CPCR], ax
    mov word [r12 + RT_INTRMIT], 0
    mov word [r12 + RT_RMS], RT_BUF
    mov byte [r12 + RT_MTPS], 0x3F
    cmp dword [rbx + NI_KIND], RTK_8168G
    jne .rings
    mov byte [r12 + RT_MTPS], 0x27
    and dword [r12 + RT_MISC], ~(1 << 19)   ; RXDV gate open
.rings:
    mov rax, [rbx + NI_TX]              ; the high halves first
    sub rax, [phys_base]
    mov rdx, rax
    shr rdx, 32
    mov [r12 + RT_TNPDS + 4], edx
    mov [r12 + RT_TNPDS], eax
    mov rax, [rbx + NI_RX]
    sub rax, [phys_base]
    mov rdx, rax
    shr rdx, 32
    mov [r12 + RT_RDSAR + 4], edx
    mov [r12 + RT_RDSAR], eax
    mov byte [r12 + RT_9346], 0         ; lock
    mov byte [r12 + RT_CR], 0x0C        ; receive, transmit
    mov eax, 0x070E                     ; DMA bursts unlimited; broadcast,
    cmp dword [rbx + NI_KIND], RTK_8139C ; multicast, our address
    je .rcr
    mov eax, 0x870E                     ; and 128-byte interrupts
    cmp dword [rbx + NI_KIND], RTK_8168G
    jne .rcr
    mov eax, 0xCF0E                     ; and multiple fetches, no early RX
.rcr:
    mov [r12 + RT_RCR], eax
    mov eax, 0x03000700                 ; standard gap, DMA bursts unlimited
    cmp dword [rbx + NI_KIND], RTK_8168G
    jne .tcr
    or eax, 1 << 7                      ; FIFO sized by the chip
.tcr:
    mov [r12 + RT_TCR], eax
    mov dword [r12 + RT_MAR], -1
    mov dword [r12 + RT_MAR + 4], -1
    mov word [r12 + RT_IMR], 0
    mov word [r12 + RT_ISR], 0xFFFF
    ret

; rtl_phy_wake(RBX, R12): a PHY left powered down or isolated (a shutdown
; without wake-on-LAN does that) or not negotiating gets told to negotiate
rtl_phy_wake:
    xor esi, esi                        ; BMCR
    call rtl_phy_read
    jc .out
    test eax, (1 << 11) | (1 << 10)     ; power down, isolate
    jnz .wake
    test eax, 1 << 12                   ; autonegotiation on
    jnz .out
.wake:
    push rax
    xor esi, esi
    mov edx, 0x1200                     ; autonegotiate, restart
    call rtl_phy_write
    pop rax
    KLOG "net: woke the PHY (BMCR was %04x)", rax
.out:
    ret

; rtl_phy_read(RBX, R12, ESI = MII register) -> EAX, CF on timeout
rtl_phy_read:
    push rcx
    cmp dword [rbx + NI_KIND], RTK_8168G
    je .ocp
    mov eax, esi
    and eax, 0x1F
    shl eax, 16
    mov [r12 + RT_PHYAR], eax
    mov ecx, 20
.wait:
    mov edi, 25
    call delay_us
    test dword [r12 + RT_PHYAR], 1 << 31
    jnz .done
    dec ecx
    jnz .wait
    jmp .fail
.done:
    mov edi, 20
    call delay_us
    mov eax, [r12 + RT_PHYAR]
    jmp .ok
.ocp:
    lea eax, [esi * 2 + 0xA400]         ; the standard registers' OCP window
    shl eax, 15
    mov [r12 + RT_GPHY_OCP], eax
    mov ecx, 10
.ocp_wait:
    mov edi, 25
    call delay_us
    test dword [r12 + RT_GPHY_OCP], 1 << 31
    jnz .ocp_done
    dec ecx
    jnz .ocp_wait
    jmp .fail
.ocp_done:
    mov eax, [r12 + RT_GPHY_OCP]
.ok:
    and eax, 0xFFFF
    clc
    pop rcx
    ret
.fail:
    stc
    pop rcx
    ret

; rtl_phy_write(RBX, R12, ESI = MII register, EDX = value) -> CF on timeout
rtl_phy_write:
    push rcx
    cmp dword [rbx + NI_KIND], RTK_8168G
    je .ocp
    mov eax, esi
    and eax, 0x1F
    shl eax, 16
    or ax, dx
    or eax, 1 << 31
    mov [r12 + RT_PHYAR], eax
    mov ecx, 20
.wait:
    mov edi, 25
    call delay_us
    test dword [r12 + RT_PHYAR], 1 << 31
    jz .done
    dec ecx
    jnz .wait
    jmp .fail
.done:
    mov edi, 20
    call delay_us
    jmp .ok
.ocp:
    lea eax, [esi * 2 + 0xA400]
    shl eax, 15
    or ax, dx
    or eax, 1 << 31
    mov [r12 + RT_GPHY_OCP], eax
    mov ecx, 10
.ocp_wait:
    mov edi, 25
    call delay_us
    test dword [r12 + RT_GPHY_OCP], 1 << 31
    jz .ok
    dec ecx
    jnz .ocp_wait
.fail:
    stc
    pop rcx
    ret
.ok:
    clc
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Operations
; -----------------------------------------------------------------------------

; rtl_send(RBX, RSI = frame, ECX = bytes) -> CF if the ring is full
rtl_send:
    mov eax, [rbx + NI_TXI]
    mov rdx, rax
    shl rdx, 4
    add rdx, [rbx + NI_TX]
    test dword [rdx], DESC_OWN          ; still the chip's: the ring is full
    jnz .full
    mov rdi, rax
    shl rdi, RT_BUF_SHIFT
    add rdi, [rbx + NI_TXBUF]
    mov r8d, ecx
    rep movsb
    mov ecx, DESC_OWN | DESC_FS | DESC_LS
    or ecx, r8d
    cmp eax, RT_TXN - 1
    jne .give
    or ecx, DESC_EOR
.give:
    mov dword [rdx + 4], 0
    mov [rdx], ecx                      ; the chip's from here on
    inc eax
    cmp eax, RT_TXN
    jb .next
    xor eax, eax
.next:
    mov [rbx + NI_TXI], eax
    mov rdx, [rbx + NI_MMIO]
    cmp dword [rbx + NI_KIND], RTK_8139C
    je .c_plus
    mov byte [rdx + RT_TPPOLL], 0x40    ; normal priority
    clc
    ret
.c_plus:
    mov byte [rdx + RT_TPPOLL_C], 0x40
    clc
    ret
.full:
    stc
    ret

; rtl_poll(RBX): acknowledge first, so that anything arriving later raises
; the interrupt again; then every frame the chip has finished
rtl_poll:
    push r12
    push r13
    push r14
    mov r12, [rbx + NI_MMIO]
    movzx eax, word [r12 + RT_ISR]
    test eax, eax
    jz .ring
    mov [r12 + RT_ISR], ax
.ring:
    mov r14d, RT_RXN                    ; one lap at most
.next:
    mov eax, [rbx + NI_RXI]
    mov r13, rax
    shl r13, 4
    add r13, [rbx + NI_RX]
    mov eax, [r13]
    test eax, DESC_OWN
    jnz .out
    mov edx, eax                        ; the whole frame in one buffer
    and edx, DESC_FS | DESC_LS
    cmp edx, DESC_FS | DESC_LS
    jne .bad
    mov edx, 1 << 21                    ; 8168: receive error summary
    cmp dword [rbx + NI_KIND], RTK_8139C
    jne .error
    mov edx, (1 << 19) | (1 << 18)      ; 8139C+: runt, CRC
.error:
    test eax, edx
    jnz .bad
    and eax, DESC_LEN
    sub eax, 4                          ; the CRC
    jbe .bad
    mov ecx, eax
    mov esi, [rbx + NI_RXI]
    shl rsi, RT_BUF_SHIFT
    add rsi, [rbx + NI_RXBUF]
    call net_receive
    jmp .give
.bad:
    inc qword [rbx + NI_DROP]
.give:
    mov ecx, [rbx + NI_RXI]
    mov eax, DESC_OWN | RT_BUF
    cmp ecx, RT_RXN - 1
    jne .own
    or eax, DESC_EOR
.own:
    mov dword [r13 + 4], 0
    mov [r13], eax
    inc ecx
    cmp ecx, RT_RXN
    jb .advance
    xor ecx, ecx
.advance:
    mov [rbx + NI_RXI], ecx
    dec r14d
    jnz .next
.out:
    pop r14
    pop r13
    pop r12
    ret

; rtl_link(RBX)
rtl_link:
    mov rdx, [rbx + NI_MMIO]
    xor ecx, ecx                        ; speed
    xor esi, esi                        ; duplex
    cmp dword [rbx + NI_KIND], RTK_8139C
    je .c_plus
    movzx eax, byte [rdx + RT_PHYSTATUS]
    test eax, 2
    jz .store
    mov esi, eax
    and esi, 1
    mov ecx, 10
    test eax, 8
    jz .gig
    mov ecx, 100
.gig:
    test eax, 16
    jz .store
    mov ecx, 1000
    jmp .store
.c_plus:                                ; QEMU: link or not, and 100 full
    test word [rdx + RT_BMSR], 4
    jz .store
    mov ecx, 100
    mov esi, 1
.store:
    mov [rbx + NI_SPEED], ecx
    mov [rbx + NI_DUPLEX], esi
    ret

; rtl_ack(RBX): from the MSI handler
rtl_ack:
    mov rdx, [rbx + NI_MMIO]
    movzx eax, word [rdx + RT_ISR]
    mov [rdx + RT_ISR], ax
    ret

section .rodata
str_rtl8168:    db 'Realtek RTL8111/8168', 0
str_rtl8139:    db 'Realtek RTL8139C+', 0

section .data
align 8
rtl_ops:        dq rtl_send, rtl_poll, rtl_link, rtl_ack
