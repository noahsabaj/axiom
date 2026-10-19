; =============================================================================
;  rtw.asm - the Realtek RTL8821CE, the Wi-Fi card of hp-1 (PCI 10ec:c821):
;  a port of Linux's rtw88 driver (drivers/net/wireless/realtek/rtw88, its
;  pci.c, mac.c, fw.c, efuse.c, phy.c and rtw8821c.c), Realtek's code under
;  the BSD-3-Clause license (it is GPL-2.0 OR BSD-3-Clause; the notice is
;  in src/kernel/gen/rtw8821c.inc, with the chip's register tables).
;
;  This part: the PCI function, its rings, and the MAC's power. The chip
;  sees memory through 32-bit addresses only, so every ring and buffer must
;  lie below 4 GiB; the allocator hands out low pages first, and anything
;  above is refused.
;
;  Registers by convention: R12 = the chip's registers (BAR2).
; =============================================================================

; the rings: TX queues, as rtw88 numbers them, and the RX queue
RQ_BK           equ 0
RQ_BE           equ 1
RQ_VI           equ 2
RQ_VO           equ 3
RQ_MGMT         equ 4
RQ_HI0          equ 5
RQ_H2C          equ 6
RQ_COUNT        equ 7

; a TX ring (RTR_*), one per queue
RTR_BD          equ 0                   ; its buffer descriptors, mapped
RTR_BUF         equ 8                   ; a buffer per descriptor, mapped (0: none)
RTR_LEN         equ 16                  ; entries
RTR_BUFSZ       equ 20                  ; bytes per buffer
RTR_WP          equ 24                  ; next to fill
RTR_RP          equ 28                  ; the chip's read index, as last seen
RTR_DESA        equ 32                  ; its registers: ring address (32)
RTR_NUM         equ 36                  ;   entries (16)
RTR_IDX         equ 40                  ;   indexes (32: host [11:0], chip [27:16])
RTR_SIZE        equ 48

RTW_RXN         equ 128                 ; RX buffers (Linux posts 512)
RTW_RXBUF       equ 11478               ; what the chip may write into each
RTW_RXSTRIDE    equ 12288               ; three pages apiece
RTW_BCNBUF      equ 65536               ; the reserved page / firmware queue's buffer

; registers
REG_SYS_FUNC_EN equ 0x002
REG_SYS_PW_CTRL equ 0x004
REG_RSV_CTRL    equ 0x01C
REG_RF_CTRL     equ 0x01F
REG_GPIO_MUXCFG equ 0x040
REG_LED_CFG     equ 0x04C
REG_PAD_CTRL1   equ 0x064
REG_HCI_OPT     equ 0x074
REG_MCUFW_CTRL  equ 0x080
REG_HIMR0       equ 0x0B0
REG_HISR0       equ 0x0B4
REG_HIMR1       equ 0x0B8
REG_HISR1       equ 0x0BC
REG_WLRF1       equ 0x0EC
REG_SYS_CFG1    equ 0x0F0
REG_CR          equ 0x100
REG_CR_EXT      equ 0x1100
REG_CPU_DMEM    equ 0x1080
REG_HIMR3       equ 0x10B8
REG_HISR3       equ 0x10BC
REG_PCI_CTRL    equ 0x300
REG_BCN_DESA    equ 0x308
REG_RX_DESA     equ 0x338
REG_RX_NUM      equ 0x382
REG_RX_IDX      equ 0x3B4
REG_RWPTR_CLR   equ 0x39C
REG_H2CQ_CSR    equ 0x1330
REG_RPWM        equ 0x3D9
REG_DBI_WDATA   equ 0x3E8
REG_DBI_RDATA   equ 0x3EC
REG_DBI_FLAG    equ 0x3F0
REG_MDIO        equ 0x3F4
REG_MIX_CFG     equ 0x3F8

RTW_FW_READY    equ 0xC078              ; REG_MCUFW_CTRL: the firmware runs
REG_EFUSE_CTRL  equ 0x030
REG_LDO_EFUSE   equ 0x034

; efuse: 512 bytes, the last 96 protected; the logical map is 512 bytes
RTW_EF_PHYS     equ 512
RTW_EF_PROTECT  equ 96
RTW_EF_LOG      equ 512
; offsets in the logical map (struct rtw8821c_efuse)
EF_TXPWR        equ 0x10                ; four paths' power indexes, 42 bytes each
EF_CHAN_PLAN    equ 0xB8
EF_XTAL         equ 0xB9
EF_THERMAL      equ 0xBA
EF_PA_TYPE      equ 0xBC
EF_LNA_2G       equ 0xBD
EF_LNA_5G       equ 0xBF
EF_BOARD        equ 0xC1
EF_BT           equ 0xC3
EF_SWING_2G     equ 0xC6
EF_SWING_5G     equ 0xC7
EF_RFE          equ 0xCA
EF_COUNTRY      equ 0xCB
EF_MAC          equ 0xD0                ; PCI Express cards: the MAC address

; power sequence commands (rtw_pwr_seq_parser)
PS_WRITE        equ 1                   ; masked byte write
PS_POLL         equ 2                   ; wait until (byte & mask) == value
PS_END          equ 4

section .text

; rtw_probe(RDI = PCI entry) -> EAX = 0 not this card, 1 taken, 2 known
; but it did not start
rtw_probe:
    cmp dword [rdi + PE_VENDOR], 0xC82110EC
    je .ours
    xor eax, eax
    ret
.ours:
    push rbx
    push r12
    push r13
    mov r13, rdi
    call pci_bdf
    mov [rtw_bdf], eax
    call rtw_pci_up
    jc .failed
    mov r12, [rtw_mmio]
    call rtw_rings
    jc .no_memory
    mov eax, [r12 + REG_SYS_CFG1]       ; the chip's version, read before power
    mov [rtw_version], eax
    shr eax, 12
    and eax, 15
    mov [rtw_cut], eax
    call rtw_hci_setup
    call rtw_power_on
    jc .no_power
    call rtw_efuse
    jc .no_efuse
    mov eax, [rtw_cut]
    lea rcx, [rtw_mac]
    movzx edx, byte [rtw_rfe]
    movzx r8d, byte [rtw_ef + EF_XTAL]
    movzx r9d, byte [rtw_ef + EF_BT]
    KLOG "wifi: Realtek RTL8821CE, cut %u, MAC %M, RFE type %u, crystal %u, BT setting %02x", rax, rcx, rdx, r8, r9
    call rtw_power_off                  ; until its firmware can be read (rtw_start)
    mov byte [rtw_found], 1
    call rtw_nic_add
    mov eax, 1
    jmp .out
.failed:
    KLOG "wifi: the RTL8821CE's PCI function did not come up"
    mov eax, 2
    jmp .out
.no_memory:
    KLOG "wifi: no memory below 4 GiB for the RTL8821CE's rings"
    mov eax, 2
    jmp .out
.no_efuse:
    KLOG "wifi: the RTL8821CE's efuse did not read"
    call rtw_power_off
    mov eax, 2
    jmp .out
.no_power:
    movzx eax, byte [r12 + REG_CR]
    movzx ecx, word [r12 + REG_SYS_PW_CTRL + 0]
    KLOG "wifi: the RTL8821CE did not power on (CR %02x, power control %04x)", rax, rcx
    mov eax, 2
.out:
    pop r13
    pop r12
    pop rbx
    ret

; rtw_pci_up -> CF if the function is unusable: in D0, its memory decoded,
; bus mastering on, INTx off (polled), completion timeouts off as rtw88
; sets them for this chip, its registers mapped into rtw_mmio
rtw_pci_up:
    push rsi
    push rdi
    push rdx
    cmp qword [net_domain], 0           ; its DMA, through the network's domain
    jne .domain
    lea rdi, [str_net_domain]
    call iommu_domain_new
    mov [net_domain], rax
.domain:
    mov rdi, [net_domain]
    mov esi, [rtw_bdf]
    call iommu_attach
    mov edi, [rtw_bdf]
    call pci_power_on
    call pci_mem_bar                    ; BAR2: BAR0 is I/O ports
    jc .fail
    mov [rtw_bar], rax
    mov esi, 0x04
    call pci_read32
    or eax, 6 | (1 << 10)
    mov edx, eax
    call pci_write32
    mov esi, 0x10                       ; PCI Express: Device Control 2
    call pci_find_cap
    jc .mapped
    add esi, 0x28
    mov edx, esi
    and esi, ~3
    call pci_read32
    and edx, 3
    lea ecx, [edx * 8]
    mov edx, 1 << 4                     ; Completion Timeout Disable
    shl edx, cl
    or edx, eax
    call pci_write32
.mapped:
    mov rdi, [rtw_bar]
    mov esi, 0x10000
    call mmio_map
    test rax, rax
    jz .fail
    mov [rtw_mmio], rax
    clc
    jmp .out
.fail:
    stc
.out:
    pop rdx
    pop rdi
    pop rsi
    ret

; rtw_low(EDI = pages) -> RAX = mapped address of zeroed pages below 4 GiB,
; within the card's reach; CF if there are none. Preserves others.
rtw_low:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdx, rdi
    shl rdx, 12
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    lea rcx, [rax + rdx]
    mov rsi, 1 << 32
    cmp rcx, rsi
    ja .high
    mov rsi, rax
    mov rdi, [net_domain]
    mov ecx, VT_RW
    call iommu_map
    jc .fail
    add rax, [phys_base]
    clc
    jmp .out
.high:
    mov rdi, rax
    shr rdx, 12
    mov rsi, rdx
    call pmm_free
.fail:
    xor eax, eax
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rtw_phys(RAX = mapped) -> EAX = its 32-bit bus address
%macro RTW_PHYS 0
    sub rax, [phys_base]
%endmacro

; rtw_rings -> CF if out of low memory: every TX ring with its buffers, the
; RX ring with its buffers posted, the reserved page's buffer
rtw_rings:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [rtw_ring_spec]
    lea rbx, [rtw_tx]
    xor ecx, ecx
.ring:
    movzx eax, word [rsi]               ; entries
    mov [rbx + RTR_LEN], eax
    movzx eax, word [rsi + 2]           ; bytes per buffer
    mov [rbx + RTR_BUFSZ], eax
    movzx eax, word [rsi + 4]
    mov [rbx + RTR_DESA], eax
    movzx eax, word [rsi + 6]
    mov [rbx + RTR_NUM], eax
    movzx eax, word [rsi + 8]
    mov [rbx + RTR_IDX], eax
    mov edi, 1                          ; 16 bytes an entry: 256 to a page
    cmp dword [rbx + RTR_LEN], 256
    jbe .bd
    mov edi, 2
.bd:
    call rtw_low
    jc .fail
    mov [rbx + RTR_BD], rax
    mov eax, [rbx + RTR_BUFSZ]
    test eax, eax
    jz .next
    imul eax, [rbx + RTR_LEN]
    add eax, 4095
    shr eax, 12
    mov edi, eax
    call rtw_low
    jc .fail
    mov [rbx + RTR_BUF], rax
.next:
    add rsi, 10
    add rbx, RTR_SIZE
    inc ecx
    cmp ecx, RQ_COUNT
    jb .ring
    mov edi, 1                          ; RX: 8-byte descriptors
    call rtw_low
    jc .fail
    mov [rtw_rx_bd], rax
    mov edi, RTW_RXN * RTW_RXSTRIDE / 4096
    call rtw_low
    jc .fail
    mov [rtw_rx_buf], rax
    xor ecx, ecx
.rx:
    call rtw_rx_post
    inc ecx
    cmp ecx, RTW_RXN
    jb .rx
    mov edi, RTW_BCNBUF / 4096 + 1      ; and a page for its descriptor
    call rtw_low
    jc .fail
    mov [rtw_bcn_bd], rax
    add rax, 4096
    mov [rtw_bcn_buf], rax
    clc
    jmp .out
.fail:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_rx_post(ECX = index): the buffer handed to the chip again. Preserves
; all but RAX.
rtw_rx_post:
    push rdx
    mov rdx, [rtw_rx_bd]
    lea rdx, [rdx + rcx * 8]
    imul eax, ecx, RTW_RXSTRIDE
    add rax, [rtw_rx_buf]
    RTW_PHYS
    mov [rdx + 4], eax
    mov dword [rdx], RTW_RXBUF          ; size; the chip's tag in the high half
    pop rdx
    ret

; rtw_hci_setup(R12): rtw_pci_setup: every ring's address and length, the
; pointers reset, DMA reset, the RX tag on
rtw_hci_setup:
    push rbx
    push rcx
    push rdx
    or byte [r12 + REG_PCI_CTRL + 3], 0xF7
    mov rax, [rtw_bcn_bd]
    RTW_PHYS
    mov [r12 + REG_BCN_DESA], eax
    lea rbx, [rtw_tx]
    xor ecx, ecx
.ring:
    mov dword [rbx + RTR_WP], 0
    mov dword [rbx + RTR_RP], 0
    mov edx, [rbx + RTR_NUM]
    mov eax, [rbx + RTR_LEN]
    mov [r12 + rdx], ax
    mov edx, [rbx + RTR_DESA]
    mov rax, [rbx + RTR_BD]
    RTW_PHYS
    mov [r12 + rdx], eax
    add rbx, RTR_SIZE
    inc ecx
    cmp ecx, RQ_COUNT
    jb .ring
    mov dword [rtw_rx_rp], 0
    mov word [r12 + REG_RX_NUM], RTW_RXN
    mov rax, [rtw_rx_bd]
    RTW_PHYS
    mov [r12 + REG_RX_DESA], eax
    mov dword [r12 + REG_RWPTR_CLR], 0xFFFFFFFF
    or dword [r12 + REG_H2CQ_CSR], (1 << 16) | (1 << 8)
    or dword [r12 + REG_PCI_CTRL], (1 << 20) | (1 << 15)   ; TRX DMA reset, RX tag
    mov dword [rtw_rx_tag], 0
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_irq_off(R12): no interrupt from the chip (it is polled)
rtw_irq_off:
    mov dword [r12 + REG_HIMR0], 0
    mov dword [r12 + REG_HIMR1], 0
    mov dword [r12 + REG_HIMR3], 0
    ret

; -----------------------------------------------------------------------------
;  The efuse: read only, never written (a write is for ever)
; -----------------------------------------------------------------------------

; rtw_efuse(R12) -> CF if a read timed out: the physical map read byte by
; byte (rtw_dump_physical_efuse_map), decoded into the logical one in
; rtw_ef (rtw_dump_logical_efuse_map), and what the driver needs from it
rtw_efuse:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    and dword [r12 + REG_LDO_EFUSE], ~(3 << 8)  ; bank 0: Wi-Fi
    and byte [r12 + REG_LDO_EFUSE + 3], 0x7F    ; the 2.5 V LDO off
    mov ebx, [r12 + REG_EFUSE_CTRL]
    lea rsi, [rtw_ef_phys]
    xor ecx, ecx
.byte:
    and ebx, ~(0x3FF << 8 | 0xFF)
    mov eax, ecx
    shl eax, 8
    or ebx, eax
    and ebx, 0x7FFFFFFF                 ; flag clear: read
    mov [r12 + REG_EFUSE_CTRL], ebx
    mov edx, 1000000
.wait:
    mov edi, 1
    call delay_us
    mov ebx, [r12 + REG_EFUSE_CTRL]
    test ebx, ebx                       ; the flag: done
    js .got
    dec edx
    jnz .wait
    stc
    jmp .out
.got:
    mov [rsi + rcx], bl
    inc ecx
    cmp ecx, RTW_EF_PHYS
    jb .byte
    lea rdi, [rtw_ef]                   ; the logical map: unwritten bytes 0xFF
    mov ecx, RTW_EF_LOG
    mov al, 0xFF
    rep stosb
    lea rdi, [rtw_ef]
    xor ecx, ecx                        ; physical index
.header:
    cmp ecx, RTW_EF_PHYS - RTW_EF_PROTECT
    jae .decoded
    movzx eax, byte [rsi + rcx]         ; hdr1
    movzx edx, byte [rsi + rcx + 1]     ; hdr2
    cmp eax, 0xFF
    je .decoded
    mov ebx, eax
    and ebx, 0x1F
    cmp ebx, 0x0F
    jne .short
    cmp edx, 0xFF
    je .decoded
    mov ebx, edx                        ; two bytes: block = hdr2[7:4] << 3 | hdr1[7:5]
    and ebx, 0xF0
    shr ebx, 1
    shr eax, 5
    or ebx, eax
    and edx, 0x0F                       ; word enables
    add ecx, 2
    jmp .words
.short:
    mov ebx, eax                        ; one byte: block = hdr1[7:4]
    shr ebx, 4
    mov edx, eax
    and edx, 0x0F
    inc ecx
.words:
    shl ebx, 3                          ; the block's logical offset
    push r8
    xor r8d, r8d
.word:
    bt edx, r8d                         ; a 1: that word not written
    jc .skip
    lea eax, [ecx + 1]
    cmp eax, RTW_EF_PHYS - RTW_EF_PROTECT
    jae .bad
    lea eax, [ebx + r8d * 2 + 1]
    cmp eax, RTW_EF_LOG
    jae .bad
    mov ax, [rsi + rcx]
    lea r9, [rbx + r8 * 2]
    mov [rdi + r9], ax
    add ecx, 2
.skip:
    inc r8d
    cmp r8d, 4
    jb .word
    pop r8
    jmp .header
.bad:
    pop r8
    stc
    jmp .out
.decoded:
    mov eax, [rdi + EF_MAC]
    mov [rtw_mac], eax
    mov ax, [rdi + EF_MAC + 4]
    mov [rtw_mac + 4], ax
    movzx eax, byte [rdi + EF_RFE]
    mov edx, eax
    and eax, 0x1F
    mov [rtw_rfe], al
    shr edx, 5
    and edx, 1
    mov [rtw_pkg], dl
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Power
; -----------------------------------------------------------------------------

; rtw_power_on(R12) -> CF if the MAC did not come on: rtw_mac_power_on. A
; chip left on (by the firmware, or Linux before a restart) is turned off
; first.
rtw_power_on:
    call rtw_irq_off
    call rtw_pre_system
    call rtw_is_on
    jnc .enable
    lea rsi, [rtw_card_disable]
    call rtw_pwrseq                     ; (whatever it says)
    call rtw_pre_system
    call rtw_is_on
    jc .fail
.enable:
    lea rsi, [rtw_card_enable]
    call rtw_pwrseq
    jc .fail
    or dword [r12 + REG_CPU_DMEM], 0x00010100   ; platform reset off, DDMA on
    or byte [r12 + REG_SYS_FUNC_EN + 1], 0xD8
    mov al, [r12 + REG_CR_EXT + 3]
    and al, 0xF0
    or al, 0x0C
    mov [r12 + REG_CR_EXT + 3], al
    mov eax, [r12 + REG_MCUFW_CTRL]
    test eax, 1 << 20                   ; boot from flash: off
    jz .on
    and eax, ~(1 << 20)
    mov [r12 + REG_MCUFW_CTRL], eax
    and dword [r12 + REG_GPIO_MUXCFG], ~(1 << 19)
.on:
    mov byte [rtw_powered], 1
    clc
    ret
.fail:
    stc
    ret

; rtw_power_off(R12): card disable, if it is on
rtw_power_off:
    call rtw_is_on
    jnc .out
    lea rsi, [rtw_card_disable]
    call rtw_pwrseq
    mov byte [rtw_powered], 0
.out:
    ret

; rtw_is_on(R12) -> CF if the MAC is on (REG_CR is 0xEA while it is off);
; wakes the firmware first if it runs, as rtw_mac_power_switch does
rtw_is_on:
    movzx eax, byte [r12 + REG_RPWM]
    cmp word [r12 + REG_MCUFW_CTRL], RTW_FW_READY
    jne .look
    xor al, 0x80
    and al, 0x80
    mov [r12 + REG_RPWM], al
.look:
    cmp byte [r12 + REG_CR], 0xEA
    je .off
    stc
    ret
.off:
    clc
    ret

; rtw_pre_system(R12): rtw_mac_pre_system_cfg for PCI Express
rtw_pre_system:
    mov byte [r12 + REG_RSV_CTRL], 0
    or dword [r12 + REG_HCI_OPT], 1 << 8
    or dword [r12 + REG_PAD_CTRL1], (1 << 29) | (1 << 28)
    and dword [r12 + REG_LED_CFG], ~((1 << 26) | (1 << 25))
    or dword [r12 + REG_GPIO_MUXCFG], 1 << 2
    and byte [r12 + REG_SYS_FUNC_EN], ~3        ; baseband held in reset
    and byte [r12 + REG_RF_CTRL], ~7            ; and the RF off
    and dword [r12 + REG_WLRF1], ~0x07000000
    ret

; rtw_pwrseq(R12, RSI = steps) -> CF if a poll timed out: the PCI Express
; steps of one of rtw88's power flows (each 8 bytes: offset, command, mask,
; value). A poll waits up to a second, toggles REG_SYS_PW_CTRL bit 3 as
; rtw88 does, and waits another.
rtw_pwrseq:
    push rcx
    push rdx
    push rdi
.step:
    movzx edx, word [rsi]
    movzx eax, byte [rsi + 2]
    cmp eax, PS_END
    je .done
    cmp eax, PS_POLL
    je .poll
    mov al, [rsi + 3]                   ; write: (old & ~mask) | (value & mask)
    mov cl, al
    not cl
    and cl, [r12 + rdx]
    and al, [rsi + 4]
    or al, cl
    mov [r12 + rdx], al
    jmp .next
.poll:
    call rtw_poll8
    jnc .next
    mov al, [r12 + REG_SYS_PW_CTRL]
    or al, 8
    mov [r12 + REG_SYS_PW_CTRL], al
    and al, ~8
    mov [r12 + REG_SYS_PW_CTRL], al
    call rtw_poll8
    jc .fail
.next:
    add rsi, 8
    jmp .step
.done:
    clc
    jmp .out
.fail:
    movzx eax, word [rsi]
    KLOG "wifi: power step at %03x timed out", rax
    stc
.out:
    pop rdi
    pop rdx
    pop rcx
    ret

; rtw_poll8(R12, RDX = offset, RSI = step) -> CF if the byte did not come
; to the value within a second
rtw_poll8:
    mov ecx, 20000
.again:
    mov al, [r12 + rdx]
    xor al, [rsi + 4]
    test al, [rsi + 3]
    jz .ok
    mov edi, 50
    call delay_us
    dec ecx
    jnz .again
    stc
    ret
.ok:
    clc
    ret

section .rodata
; TX rings: entries, bytes per buffer (0: never used), and the queue's
; registers (DESA, NUM, IDX), in RQ_* order
rtw_ring_spec:
    dw 128, 0,    0x330, 0x38A, 0x3AC   ; BK
    dw 64,  2048, 0x328, 0x388, 0x3A8   ; BE: data
    dw 128, 0,    0x320, 0x386, 0x3A4   ; VI
    dw 128, 0,    0x318, 0x384, 0x3A0   ; VO
    dw 32,  2048, 0x310, 0x380, 0x3B0   ; MGMT
    dw 32,  2048, 0x340, 0x38C, 0x3B8   ; HI0: broadcast and multicast
    dw 32,  128,  0x1320, 0x1328, 0x132C ; H2C: firmware commands

%macro PWR 4                            ; offset, command, mask, value
    dw %1
    db %2, %3, %4, 0, 0, 0
%endmacro

; card_enable_flow_8821c for PCI Express (rtw8821c.c 1238-1378)
rtw_card_enable:
    PWR 0x005, PS_WRITE, 0x98, 0x00
    PWR 0x300, PS_WRITE, 0xFF, 0x00
    PWR 0x301, PS_WRITE, 0xFF, 0x00
    PWR 0x005, PS_WRITE, 0x1C, 0x00
    PWR 0x075, PS_WRITE, 0x01, 0x01
    PWR 0x006, PS_POLL,  0x02, 0x02
    PWR 0x075, PS_WRITE, 0x01, 0x00
    PWR 0x006, PS_WRITE, 0x01, 0x01
    PWR 0x005, PS_WRITE, 0x80, 0x00
    PWR 0x005, PS_WRITE, 0x18, 0x00
    PWR 0x005, PS_WRITE, 0x01, 0x01
    PWR 0x005, PS_POLL,  0x01, 0x00
    PWR 0x020, PS_WRITE, 0x08, 0x08
    PWR 0x074, PS_WRITE, 0x20, 0x20
    PWR 0x022, PS_WRITE, 0x02, 0x00
    PWR 0x062, PS_WRITE, 0xE0, 0xE0
    PWR 0x061, PS_WRITE, 0xE0, 0x00
    PWR 0x07C, PS_WRITE, 0x02, 0x00
    PWR 0, PS_END, 0, 0

; card_disable_flow_8821c for PCI Express (rtw8821c.c 1380-1549)
rtw_card_disable:
    PWR 0x093, PS_WRITE, 0x08, 0x00
    PWR 0x01F, PS_WRITE, 0xFF, 0x00
    PWR 0x049, PS_WRITE, 0x02, 0x00
    PWR 0x006, PS_WRITE, 0x01, 0x01
    PWR 0x002, PS_WRITE, 0x02, 0x00
    PWR 0x005, PS_WRITE, 0x02, 0x02
    PWR 0x005, PS_POLL,  0x02, 0x00
    PWR 0x020, PS_WRITE, 0x08, 0x00
    PWR 0x067, PS_WRITE, 0x20, 0x00
    PWR 0x005, PS_WRITE, 0x04, 0x04
    PWR 0x081, PS_WRITE, 0xC0, 0x00
    PWR 0x090, PS_WRITE, 0x02, 0x00
    PWR 0, PS_END, 0, 0

section .bss
alignb 8
rtw_tx:         resb RQ_COUNT * RTR_SIZE
rtw_mmio:       resq 1
rtw_bar:        resq 1
rtw_rx_bd:      resq 1
rtw_rx_buf:     resq 1
rtw_bcn_bd:     resq 1
rtw_bcn_buf:    resq 1
rtw_bdf:        resd 1
rtw_version:    resd 1
rtw_cut:        resd 1
rtw_rx_rp:      resd 1
rtw_rx_tag:     resd 1
rtw_powered:    resb 1
rtw_rfe:        resb 1                  ; the board's RF front end (efuse)
rtw_pkg:        resb 1                  ; package type, for the tables
rtw_mac:        resb 6
rtw_ef_phys:    resb RTW_EF_PHYS
rtw_ef:         resb RTW_EF_LOG         ; the logical efuse map
