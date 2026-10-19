; =============================================================================
;  rtwfw.asm - the RTL8821CE's firmware: read from the boot volume, copied
;  into the chip through its beacon queue and its DMA engine, started; and
;  the commands it takes through its mailboxes (H2C). Part of the rtw88 port
;  (rtw.asm has the license and the conventions: R12 = the chip's
;  registers): mac.c 417-1003, fw.c 447-518 and 1469-1538, util.c 9-79.
;
;  The file is Realtek's rtw88/rtw8821c_fw.bin from linux-firmware, put on
;  the boot volume as /EFI/AXIOM/RTW8821C.BIN; it is not in this tree.
; =============================================================================

REG_SYS_CLK     equ 0x008
REG_PQ_MAP      equ 0x10C               ; byte 0x10D [7:6]: the high queue's DMA
REG_C2HEVT      equ 0x1A0
REG_HMETFR      equ 0x1CC               ; bit n: mailbox n busy
REG_HMEBOX      equ 0x1D0               ; mailboxes 0-3, a dword each
REG_HMEBOX_EX   equ 0x1F0               ;   and their second dwords
REG_FIFOPAGE2   equ 0x204               ; [11:0] beacon head page, bit 15 valid
REG_TXDMA_STAT  equ 0x210
REG_RQPN2       equ 0x22C
REG_FIFOPAGE1   equ 0x230
REG_FWHW_TXQ    equ 0x420
REG_BCN_CTRL    equ 0x550
REG_FW_DBG7     equ 0x10FC
REG_DDMA_SA     equ 0x1200
REG_DDMA_DA     equ 0x1204
REG_DDMA_CTRL   equ 0x1208
REG_LTE_CTRL    equ 0x1700              ; the LTE coexistence registers, indirect
REG_LTE_WDATA   equ 0x1704
REG_LTE_RDATA   equ 0x1708
REG_BCN_WORK    equ 0x383               ; bit 4: send what the beacon ring holds

RTW_FW_PAGES    equ 64                  ; the largest file taken: 256 KiB
RTW_OCP_TXBUF   equ 0x18780000          ; the TX FIFO, as the chip's CPU sees it
RTW_OCP_DMEM    equ 0x00200000

; the file's 64-byte header (fw.h 316-343)
FWH_VERSION     equ 0x04
FWH_SUBVER      equ 0x06
FWH_SUBIDX      equ 0x07
FWH_FEATURE     equ 0x0C
FWH_MEM         equ 0x18                ; bit 4: there is an EMEM part
FWH_DMEM_ADDR   equ 0x20
FWH_DMEM_SIZE   equ 0x24
FWH_IMEM_SIZE   equ 0x30
FWH_EMEM_SIZE   equ 0x34
FWH_EMEM_ADDR   equ 0x38
FWH_IMEM_ADDR   equ 0x3C
FWH_SIZE        equ 64

; RTW_POLL32 offset, mask, value -> CF if (R32 & mask) did not come to
; value within 10 ms. Preserves all but RAX.
%macro RTW_POLL32 3
    push rsi
    push rdx
    push rcx
    mov esi, %1
    mov edx, %2
    mov ecx, %3
    call rtw_poll32
    pop rcx
    pop rdx
    pop rsi
%endmacro

section .text

; rtw_start: the firmware, now that volumes are mounted: read, put into
; the chip, started, and the chip off again (what comes next is not here
; yet). Nothing if there is no card.
rtw_start:
    cmp byte [rtw_found], 0
    jne .card
    ret
.card:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r14
    mov r12, [rtw_mmio]
    call boot_volume
    jc .no_volume
    mov edi, RTW_FW_PAGES
    call pmm_alloc_zero
    test rax, rax
    jz .no_memory
    mov rbx, rax
    add rax, [phys_base]
    mov rdi, rax
    lea rsi, [str_rtw_fw_path]
    mov ecx, RTW_FW_PAGES * 4096
    call fat_read_file
    jc .free                            ; (it said why)
    cmp rax, rdx
    jne .too_big
    mov r14, rax
    call rtw_hci_setup
    call rtw_power_on
    jc .no_power
    mov byte [r12 + REG_C2HEVT], 0xFD   ; asks the firmware for its feature report
    mov rsi, rbx
    add rsi, [phys_base]
    mov ecx, r14d
    call rtw_fw_download
    jc .off
    call rtw_fw_report
.off:
    call rtw_power_off
    jmp .free
.no_power:
    KLOG "wifi: the RTL8821CE did not power on for its firmware"
    jmp .free
.too_big:
    KLOG "wifi: RTW8821C.BIN is larger than 256 KiB: not the firmware"
.free:
    mov rdi, rbx
    mov esi, RTW_FW_PAGES
    call pmm_free
    jmp .out
.no_volume:
    KLOG "wifi: no boot volume to read the firmware from"
    jmp .out
.no_memory:
    KLOG "wifi: no memory for the firmware"
.out:
    pop r14
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_fw_report(R12, RSI = the file): what the running firmware says of
; itself, logged
rtw_fw_report:
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    mov ecx, 100                        ; its feature report: up to 10 ms
.wait:
    cmp byte [r12 + REG_C2HEVT], 0x19
    je .report
    mov edi, 100
    call delay_us
    dec ecx
    jnz .wait
    xor r9d, r9d
    jmp .say
.report:
    movzx r9d, byte [r12 + REG_C2HEVT + 9]  ; its second word (streams,
    shl r9d, 8                          ; antennas), a byte at a time: it is
    mov r9b, [r12 + REG_C2HEVT + 8]     ; not aligned
    shl r9d, 8
    mov r9b, [r12 + REG_C2HEVT + 7]
    shl r9d, 8
    mov r9b, [r12 + REG_C2HEVT + 6]
    mov byte [r12 + REG_C2HEVT], 0
.say:
    movzx eax, word [rsi + FWH_VERSION]
    movzx ecx, byte [rsi + FWH_SUBVER]
    movzx edx, byte [rsi + FWH_SUBIDX]
    mov r8d, [rsi + FWH_FEATURE]
    KLOG "wifi: firmware %u.%u.%u running (features %x, hardware report %08x)", rax, rcx, rdx, r8, r9
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

; rtw_fw_download(R12, RSI = the file, ECX = its size) -> CF (said why) if
; the firmware is not running: __rtw_download_firmware for the 3081 CPU,
; then the command that brings back the Bluetooth half (8821CE).
rtw_fw_download:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r13
    push r14
    mov r13, rsi
    mov eax, [r13 + FWH_DMEM_SIZE]      ; each part with its 8 bytes of checksum
    lea r8d, [eax + 8]
    mov eax, [r13 + FWH_IMEM_SIZE]
    lea r9d, [eax + 8]
    xor r10d, r10d
    test byte [r13 + FWH_MEM], 0x10
    jz .sized
    mov eax, [r13 + FWH_EMEM_SIZE]
    lea r10d, [eax + 8]
.sized:
    lea rax, [r8 + r9 + FWH_SIZE]
    add rax, r10
    cmp rax, rcx
    jne .bad_size
    mov esi, 0x38                       ; the LTE coexistence setting, kept
    call rtw_lte_read
    jc .lte_busy
    mov r14d, eax
    and byte [r12 + REG_SYS_FUNC_EN + 1], ~0x04 ; the chip's CPU off
    and byte [r12 + REG_RSV_CTRL + 1], ~0x01
    mov al, [r12 + REG_PQ_MAP + 1]      ; only the high queue, all of the FIFO
    mov [rtw_fw_bk], al
    mov byte [r12 + REG_PQ_MAP + 1], 0xC0
    mov al, [r12 + REG_CR]
    mov [rtw_fw_bk + 1], al
    mov byte [r12 + REG_CR], 0x05       ; host TX DMA, TX DMA
    mov dword [r12 + REG_H2CQ_CSR], 0x80000000
    mov ax, [r12 + REG_FIFOPAGE1]
    mov [rtw_fw_bk + 2], ax
    mov eax, [r12 + REG_RQPN2]
    or eax, 0x80000000
    mov [rtw_fw_bk + 4], eax
    mov word [r12 + REG_FIFOPAGE1], 0x200
    mov [r12 + REG_RQPN2], eax
    mov al, [r12 + REG_BCN_CTRL]        ; no beacons
    mov [rtw_fw_bk + 8], al
    and al, ~0x08
    or al, 0x10
    mov [r12 + REG_BCN_CTRL], al
    and byte [r12 + REG_CPU_DMEM + 2], ~0x01    ; the platform reset
    and byte [r12 + REG_SYS_CLK + 1], ~0x40
    or byte [r12 + REG_CPU_DMEM + 2], 0x01
    or byte [r12 + REG_SYS_CLK + 1], 0x40
    movzx eax, word [r12 + REG_MCUFW_CTRL]
    and eax, 0x3800
    or eax, 1                           ; download on, its status bits clear
    mov [r12 + REG_MCUFW_CTRL], ax
    lea rsi, [r13 + FWH_SIZE]           ; DMEM, IMEM, EMEM
    mov edx, [r13 + FWH_DMEM_ADDR]
    btr edx, 31
    mov ecx, r8d
    call rtw_fw_part
    jc .fail
    add rsi, r8
    mov edx, [r13 + FWH_IMEM_ADDR]
    btr edx, 31
    mov ecx, r9d
    call rtw_fw_part
    jc .fail
    test r10d, r10d
    jz .loaded
    add rsi, r9
    mov edx, [r13 + FWH_EMEM_ADDR]
    btr edx, 31
    mov ecx, r10d
    call rtw_fw_part
    jc .fail
.loaded:
    mov al, [rtw_fw_bk]                 ; back as they were
    mov [r12 + REG_PQ_MAP + 1], al
    mov al, [rtw_fw_bk + 1]
    mov [r12 + REG_CR], al
    mov dword [r12 + REG_H2CQ_CSR], 0x80000000
    mov ax, [rtw_fw_bk + 2]
    mov [r12 + REG_FIFOPAGE1], ax
    mov eax, [rtw_fw_bk + 4]
    mov [r12 + REG_RQPN2], eax
    mov al, [rtw_fw_bk + 8]
    mov [r12 + REG_BCN_CTRL], al
    mov dword [r12 + REG_TXDMA_STAT], 4 ; a page overflow, cleared
    movzx eax, word [r12 + REG_MCUFW_CTRL]
    mov ecx, eax
    and ecx, 0x50
    cmp ecx, 0x50                       ; both checksums good:
    jne .cpu_on
    or eax, 0x4000                      ;   downloaded, download off
    and eax, ~1
    mov [r12 + REG_MCUFW_CTRL], ax
.cpu_on:
    or byte [r12 + REG_RSV_CTRL + 1], 0x01
    or byte [r12 + REG_SYS_FUNC_EN + 1], 0x04
    mov esi, 0x38
    mov edx, r14d
    call rtw_lte_write
    jc .lte_lost
    RTW_POLL32 REG_MCUFW_CTRL, 0xCFFF, RTW_FW_READY
    jc .not_ready
    call rtw_hci_setup                  ; the rings from the start again
    mov byte [rtw_h2c_box], 0
    mov word [rtw_h2c_seq], 0
    mov eax, 0x000001D1                 ; RECOVER_BT_DEV, on
    xor edx, edx
    call rtw_h2c
    clc
    jmp .out
.bad_size:
    KLOG "wifi: RTW8821C.BIN's size does not match its header"
    stc
    jmp .out
.lte_busy:
    KLOG "wifi: the LTE coexistence registers stayed busy"
    stc
    jmp .out
.lte_lost:
    KLOG "wifi: the LTE coexistence setting could not be put back"
    jmp .fail
.not_ready:
    movzx eax, word [r12 + REG_MCUFW_CTRL]
    mov ecx, [r12 + REG_FW_DBG7]
    KLOG "wifi: the firmware did not start (MCU control %04x, debug %08x)", rax, rcx
.fail:
    and byte [r12 + REG_MCUFW_CTRL], ~1
    or byte [r12 + REG_SYS_FUNC_EN + 1], 0x04
    stc
.out:
    pop r14
    pop r13
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_fw_part(R12, RSI = bytes, EDX = where in the chip, ECX = how many)
; -> CF (said why): download_firmware_to_mem: 4 KiB at a time into the TX
; FIFO's first page, and the DMA engine copies each on, adding to a
; checksum that the part's last 8 bytes must match. Preserves all but RAX.
rtw_fw_part:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r10
    mov r8d, ecx                        ; left
    mov r9d, edx                        ; the next chunk's place
    mov r10d, edx
    or dword [r12 + REG_DDMA_CTRL], 1 << 25 ; checksum status reset
    mov ebx, (1 << 31) | (1 << 29)      ; go, with the checksum
.chunk:
    mov ecx, r8d
    cmp ecx, 0x1000
    jbe .size
    mov ecx, 0x1000
.size:
    xor edx, edx
    call rtw_rsvd_write
    jc .fail
    RTW_POLL32 REG_DDMA_CTRL, 1 << 31, 0
    jc .busy
    mov dword [r12 + REG_DDMA_SA], RTW_OCP_TXBUF + 48   ; past the TX descriptor
    mov [r12 + REG_DDMA_DA], r9d
    mov eax, ecx
    or eax, ebx
    mov [r12 + REG_DDMA_CTRL], eax
    RTW_POLL32 REG_DDMA_CTRL, 1 << 31, 0
    jc .busy
    or ebx, 1 << 24                     ; the checksum goes on
    add rsi, rcx
    add r9d, ecx
    sub r8d, ecx
    jnz .chunk
    mov al, [r12 + REG_MCUFW_CTRL]
    test dword [r12 + REG_DDMA_CTRL], 1 << 27
    jnz .bad_sum
    cmp r10d, RTW_OCP_DMEM
    jb .imem
    or al, 0x60                         ; DMEM there, checksum good
    jmp .good
.imem:
    or al, 0x18                         ; IMEM (or EMEM) the same
.good:
    mov [r12 + REG_MCUFW_CTRL], al
    clc
    jmp .out
.bad_sum:
    cmp r10d, RTW_OCP_DMEM
    jb .imem_bad
    or al, 0x20
    and al, ~0x40
    jmp .said
.imem_bad:
    or al, 0x08
    and al, ~0x10
.said:
    mov [r12 + REG_MCUFW_CTRL], al
    KLOG "wifi: the firmware's checksum failed (the part at %x)", r10
    stc
    jmp .out
.busy:
    KLOG "wifi: the chip's DMA engine stayed busy (the part at %x)", r10
.fail:
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_rsvd_write(R12, RSI = bytes, ECX = how many, at most 64 KiB less 48,
; EDX = TX FIFO page) -> CF (said why): rtw_fw_write_data_rsvd_page: the
; bytes through the beacon ring into the FIFO at that page. Preserves all
; but RAX.
rtw_rsvd_write:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov al, [r12 + REG_BCN_CTRL]
    mov [rtw_rsvd_bk], al
    and edx, 0xFFF
    or edx, 0x8000
    mov [r12 + REG_FIFOPAGE2], dx       ; the beacon's head: that page
    mov al, [r12 + REG_CR + 1]
    mov [rtw_rsvd_bk + 1], al
    or al, 0x01                         ; software beacons
    mov [r12 + REG_CR + 1], al
    mov al, [rtw_rsvd_bk]
    and al, ~0x08
    or al, 0x10
    mov [r12 + REG_BCN_CTRL], al
    mov al, [r12 + REG_FWHW_TXQ + 2]
    mov [rtw_rsvd_bk + 2], al
    and al, ~0x40                       ; the beacon queue's own sending off
    mov [r12 + REG_FWHW_TXQ + 2], al
    mov rbx, [rtw_bcn_buf]              ; the packet: a TX descriptor, the bytes
    mov rdi, rbx
    push rcx
    mov ecx, 48 / 8
    xor eax, eax
    rep stosq
    pop rcx
    push rcx
    push rsi
    rep movsb
    pop rsi
    pop rcx
    movzx edx, byte [rsi + 4]           ; "broadcast" as rtw88 takes it, from
    and edx, 1                          ; byte 4 as if a frame's first address
    shl edx, 24
    mov eax, ecx
    or eax, (48 << 16) | (1 << 26) | (1 << 31)  ; offset 48, last segment, no QSEL sequence
    or eax, edx
    mov [rbx], eax
    cmp byte [rtw_band], 1
    jne .ofdm
    mov dword [rbx + 4], (16 << 8) | (8 << 16)  ; queue: beacon; 1M, its rate set
    mov dword [rbx + 16], 0
    jmp .rate
.ofdm:
    mov dword [rbx + 4], (16 << 8) | (7 << 16)  ; 6M
    mov dword [rbx + 16], 4
.rate:
    mov dword [rbx + 12], (1 << 8) | (1 << 10)  ; that rate, no fallback
    mov dword [rbx + 32], 1 << 15       ; the hardware's sequence numbers
    mov rdi, [rtw_bcn_bd]
    mov rax, rbx
    RTW_PHYS
    lea edx, [ecx + 48 - 1]             ; 128-byte pages, the chip's own
    shr edx, 7
    inc edx
    or edx, 0x8000                      ;   and its to send
    shl edx, 16
    or edx, 48
    mov [rdi], edx
    mov [rdi + 4], eax
    mov [rdi + 8], ecx
    add eax, 48
    mov [rdi + 12], eax
    or byte [r12 + REG_BCN_WORK], 0x10
    RTW_POLL32 REG_FIFOPAGE2, 1 << 15, 1 << 15  ; in the FIFO
    setc r8b
    movzx eax, word [rtw_rsvd_boundary]
    or eax, 0x8000
    mov [r12 + REG_FIFOPAGE2], ax
    mov al, [rtw_rsvd_bk]
    mov [r12 + REG_BCN_CTRL], al
    mov al, [rtw_rsvd_bk + 2]
    mov [r12 + REG_FWHW_TXQ + 2], al
    mov al, [rtw_rsvd_bk + 1]
    mov [r12 + REG_CR + 1], al
    test r8b, r8b
    jz .out                             ; (CF clear)
    KLOG "wifi: the beacon queue did not take a reserved page"
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rtw_h2c(R12, EAX = a command's bytes 0-3, EDX = bytes 4-7) -> CF (said
; why) if its mailbox stayed busy for 3 ms and the command was dropped:
; the mailboxes in turn, as rtw88 uses them. Preserves all but RAX.
rtw_h2c:
    push rbx
    push rcx
    push rsi
    push rdi
    mov ebx, eax
    movzx ecx, byte [rtw_h2c_box]
    mov esi, 30
.wait:
    movzx eax, byte [r12 + REG_HMETFR]
    bt eax, ecx
    jnc .free
    mov edi, 100
    call delay_us
    dec esi
    jnz .wait
    movzx eax, bl
    KLOG "wifi: firmware command %02x dropped: mailbox %u stayed busy", rax, rcx
    stc
    jmp .out
.free:
    lea rsi, [r12 + rcx * 4]
    mov [rsi + REG_HMEBOX_EX], edx
    mov [rsi + REG_HMEBOX], ebx         ; this hands it over
    inc ecx
    and ecx, 3
    mov [rtw_h2c_box], cl
    clc
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rtw_lte_read(R12, ESI = offset) -> EAX, CF if the interface stayed busy
rtw_lte_read:
    RTW_POLL32 REG_LTE_CTRL, 1 << 29, 1 << 29
    jc .out
    mov eax, esi
    or eax, 0x800F0000
    mov [r12 + REG_LTE_CTRL], eax
    mov eax, [r12 + REG_LTE_RDATA]
    clc
.out:
    ret

; rtw_lte_write(R12, ESI = offset, EDX = value) -> CF if the interface
; stayed busy. Preserves all but RAX.
rtw_lte_write:
    RTW_POLL32 REG_LTE_CTRL, 1 << 29, 1 << 29
    jc .out
    mov [r12 + REG_LTE_WDATA], edx
    mov eax, esi
    or eax, 0xC00F0000
    mov [r12 + REG_LTE_CTRL], eax
    clc
.out:
    ret

; rtw_poll32(R12, ESI = offset, EDX = mask, ECX = value) -> CF if (R32 &
; mask) did not come to value within 10 ms: check_hw_ready. Preserves all
; but RAX.
rtw_poll32:
    push rdi
    push r8
    mov r8d, 1000
.again:
    mov eax, [r12 + rsi]
    and eax, edx
    cmp eax, ecx
    je .ok
    mov edi, 10
    call delay_us
    dec r8d
    jnz .again
    stc
    jmp .out
.ok:
    clc
.out:
    pop r8
    pop rdi
    ret

section .rodata
str_rtw_fw_path: db '/EFI/AXIOM/RTW8821C.BIN', 0

section .bss
rtw_fw_bk:      resb 12                 ; what the download changes, kept
rtw_rsvd_bk:    resb 3
rtw_rsvd_boundary: resw 1               ; the reserved pages' first (0 before MAC init)
rtw_h2c_seq:    resw 1
rtw_h2c_box:    resb 1                  ; the next mailbox
rtw_band:       resb 1                  ; 0 none yet, 1 2.4 GHz, 2 5 GHz
rtw_found:      resb 1
