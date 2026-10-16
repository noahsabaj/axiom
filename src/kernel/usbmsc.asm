; =============================================================================
;  usbmsc.asm - USB mass storage: sticks, card readers and drives that speak
;  SCSI over Bulk-Only Transport. Each one becomes a disk (disk.asm), LUN 0.
;
;  Transfers are synchronous, like control transfers: the CBW, the data and
;  the CSW are each queued and waited for with interrupts off, through one
;  64 KiB bounce buffer (aligned to 64 KiB, so one TRB never crosses a
;  boundary xHCI forbids). The endpoints have no completion handler.
;
;  Registers by convention: R12 = stick, RBX = USB device, R14 = endpoint.
; =============================================================================

MAX_MSC         equ 4
MSC_BOUNCE      equ 64 * 1024
MSC_WAIT        equ 8                   ; seconds a transfer may take

MS_DEV          equ 0
MS_IN           equ 8                   ; bulk endpoints
MS_OUT          equ 16
MS_IFACE        equ 24
MS_STATE        equ 28                  ; 0 free, 1 claimed
MS_TAG          equ 32
MS_SHIFT        equ 36
MS_BLOCKS       equ 40
MS_DISK         equ 48
MS_SENSE        equ 56                  ; key << 16 | ASC << 8 | ASCQ
MS_NAME         equ 64                  ; vendor and product, 48 bytes
MS_SIZE         equ 128

section .text

; msc_probe(RBX = device, RSI = interface, RDI = end of the configuration)
; -> CF = 1 if not claimed. Preserves others.
msc_probe:
    cmp byte [rsi + 5], 0x08            ; mass storage,
    jne .no
    cmp byte [rsi + 6], 0x06            ; SCSI commands,
    jne .no
    cmp byte [rsi + 7], 0x50            ; bulk-only transport
    jne .no
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    push r12
    push r13
    push r14
    lea r12, [msc_sticks]
    xor ecx, ecx
.slot:
    cmp ecx, MAX_MSC
    jae .full
    cmp dword [r12 + MS_STATE], 0
    je .take
    add r12, MS_SIZE
    inc ecx
    jmp .slot
.take:
    push rdi
    push rcx
    mov rdi, r12
    mov ecx, MS_SIZE / 8
    xor eax, eax
    rep stosq
    pop rcx
    pop rdi
    mov dword [r12 + MS_STATE], 1
    mov [r12 + MS_DEV], rbx
    movzx eax, byte [rsi + 2]
    mov [r12 + MS_IFACE], eax
    xor r13d, r13d                      ; bulk IN descriptor
    xor r9d, r9d                        ; bulk OUT descriptor
    xor ecx, ecx
.ep:
    mov dl, 5
    call usb_find_desc
    jc .found_eps
    mov dl, [rax + 3]
    and dl, 3
    cmp dl, 2
    jne .ep_next
    test byte [rax + 2], 0x80
    jz .ep_out
    test r13, r13
    jnz .ep_next
    mov r13, rax
    jmp .ep_next
.ep_out:
    test r9, r9
    jnz .ep_next
    mov r9, rax
.ep_next:
    inc ecx
    jmp .ep
.found_eps:
    test r13, r13
    jz .fail
    test r9, r9
    jz .fail
    mov rsi, r13
    xor edx, edx                        ; no handler: waited for directly
    mov rcx, r12
    xor r8d, r8d
    call usb_ep_create
    jc .fail
    mov [r12 + MS_IN], r14
    mov rsi, r9
    call usb_ep_create
    jc .fail
    mov [r12 + MS_OUT], r14
    lea rsi, [msc_start]
    lea rdx, [msc_detach]
    mov rcx, r12
    call usb_bind
    lea rsi, [str_role_storage]
    call usb_add_role
    pop r14
    pop r13
    pop r12
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.fail:
    mov dword [r12 + MS_STATE], 0
.full:
    pop r14
    pop r13
    pop r12
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
.no:
    stc
    ret

; msc_detach(RSI = stick): unplugged
msc_detach:
    mov dword [rsi + MS_STATE], 0
    mov rax, [rsi + MS_DISK]
    test rax, rax
    jz .out
    push rbx
    mov rbx, rax
    call disk_gone
    pop rbx
.out:
    ret

; msc_start(RBX = device, RSI = stick): what is it, is it ready, how big;
; then it is a disk
msc_start:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    push r13
    mov r12, rsi
    call msc_buffers
    jc .no_memory
    call msc_cdb_clear                  ; INQUIRY
    mov byte [msc_cdb], 0x12
    mov byte [msc_cdb + 4], 36
    mov ecx, 6
    mov edx, 36
    mov r8d, 1
    call msc_command
    jc .failed
    mov rsi, [msc_buf]
    mov al, [rsi]
    and al, 0x1F
    jnz .not_disk                       ; 0: direct-access block device
    lea rdi, [r12 + MS_NAME]            ; "vendor product"
    add rsi, 8
    mov ecx, 8
    call nvme_copy_text
    cmp byte [r12 + MS_NAME], 0
    je .product
    mov byte [rdi], ' '
    inc rdi
.product:
    mov rsi, [msc_buf]
    add rsi, 16
    mov ecx, 16
    call nvme_copy_text
    mov r13d, 30                        ; up to 3 s for it to be ready
.unit:
    call msc_cdb_clear                  ; TEST UNIT READY
    mov ecx, 6
    xor edx, edx
    xor r8d, r8d
    call msc_command
    jnc .ready
    cmp eax, 1
    jne .failed
    call msc_sense
    mov edi, 100
    call delay_ms_usb
    dec r13d
    jnz .unit
    lea rax, [r12 + MS_NAME]
    KLOG "usb storage: %s has no medium (or never got ready)", rax
    jmp .out
.ready:
    mov r13d, 2
.capacity:
    call msc_cdb_clear                  ; READ CAPACITY (10)
    mov byte [msc_cdb], 0x25
    mov ecx, 10
    mov edx, 8
    mov r8d, 1
    call msc_command
    jnc .capacity10
    cmp eax, 1
    jne .failed
    call msc_sense                      ; a unit attention, once
    dec r13d
    jnz .capacity
    jmp .failed
.capacity10:
    mov rsi, [msc_buf]
    mov eax, [rsi]
    bswap eax                           ; last block
    mov ecx, [rsi + 4]
    bswap ecx                           ; block size
    cmp eax, 0xFFFFFFFF
    jne .sized
    call msc_cdb_clear                  ; READ CAPACITY (16)
    mov byte [msc_cdb], 0x9E
    mov byte [msc_cdb + 1], 0x10
    mov byte [msc_cdb + 13], 32
    mov ecx, 16
    mov edx, 32
    mov r8d, 1
    call msc_command
    jc .failed
    mov rsi, [msc_buf]
    mov rax, [rsi]
    bswap rax
    mov ecx, [rsi + 8]
    bswap ecx
.sized:
    inc rax
    mov [r12 + MS_BLOCKS], rax
    bsf edx, ecx                        ; 512, 1024, 2048 or 4096 bytes
    jz .odd_size
    mov eax, 1
    push rcx
    mov ecx, edx
    shl eax, cl
    pop rcx
    cmp eax, ecx
    jne .odd_size
    cmp edx, 9
    jb .odd_size
    cmp edx, 12
    ja .odd_size
    mov [r12 + MS_SHIFT], edx
    lea rdi, [str_msc_kind]
    mov rsi, [r12 + MS_BLOCKS]
    mov ecx, edx
    mov rdx, r12
    lea r8, [msc_disk_ops]
    mov r9d, DKF_REMOVABLE
    call disk_add
    mov [r12 + MS_DISK], rax
    jmp .out
.odd_size:
    lea rax, [r12 + MS_NAME]
    KLOG "usb storage: %s has %u-byte blocks, which Axiom does not take", rax, rcx
    jmp .out
.not_disk:
    movzx eax, al
    KLOG "usb storage: device type %u is not a disk", rax
    jmp .out
.no_memory:
    KLOG "usb storage: no memory for buffers"
    jmp .out
.failed:
    KLOG "usb storage: the device did not answer"
.out:
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; msc_buffers -> CF if there is no memory: the bounce buffer and the page for
; command and status blocks, shared by every stick (transfers are one at a time)
msc_buffers:
    cmp qword [msc_buf], 0
    jne .ok
    push rdi
    push rdx
    mov edi, MSC_BOUNCE / 4096 * 2 - 1  ; enough to hold an aligned 64 KiB
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    add rax, MSC_BOUNCE - 1
    and rax, ~(MSC_BOUNCE - 1)
    mov [msc_buf_phys], rax
    add rax, [phys_base]
    mov [msc_buf], rax
    call usb_alloc_page
    mov [msc_io_phys], rax
    mov [msc_io], rdx
    pop rdx
    pop rdi
.ok:
    clc
    ret
.fail:
    pop rdx
    pop rdi
    stc
    ret

; msc_cdb_clear: a zeroed command block. Preserves all.
msc_cdb_clear:
    mov qword [msc_cdb], 0
    mov qword [msc_cdb + 8], 0
    ret

; msc_sense(R12): REQUEST SENSE into MS_SENSE. Preserves all.
msc_sense:
    push rax
    push rcx
    push rdx
    push rsi
    push r8
    call msc_cdb_clear
    mov byte [msc_cdb], 0x03
    mov byte [msc_cdb + 4], 18
    mov ecx, 6
    mov edx, 18
    mov r8d, 1
    call msc_command
    jc .out
    mov rsi, [msc_buf]
    movzx eax, byte [rsi + 2]
    and eax, 0x0F
    shl eax, 8
    mov al, [rsi + 12]
    shl eax, 8
    mov al, [rsi + 13]
    mov [r12 + MS_SENSE], eax
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  msc_command(R12 = stick, msc_cdb = the command, ECX = its length,
;  EDX = data bytes (in msc_buf), R8D = 1 if the data comes in)
;  -> EAX = 0 done; 1 the device refused it (msc_sense says why); -1 the
;  transport failed and the device was reset. CF unless EAX = 0.
;  msc_residue = bytes the device did not move. Preserves others.
; -----------------------------------------------------------------------------
msc_command:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r14
    push r15
    pushfq
    cli
    mov rbx, [r12 + MS_DEV]
    mov r15, [rbx + DV_XC]
    mov r9d, edx
    mov rdi, [msc_io]                   ; the command block wrapper
    mov dword [rdi], 0x43425355         ; "USBC"
    inc dword [r12 + MS_TAG]
    mov eax, [r12 + MS_TAG]
    mov [rdi + 4], eax
    mov [rdi + 8], r9d
    xor eax, eax
    test r8d, r8d
    jz .direction
    mov eax, 0x80
.direction:
    mov [rdi + 12], al
    mov byte [rdi + 13], 0              ; LUN 0
    mov [rdi + 14], cl
    mov rax, [msc_cdb]
    mov [rdi + 15], rax
    mov rax, [msc_cdb + 8]
    mov [rdi + 23], rax
    mov r14, [r12 + MS_OUT]
    mov rsi, [msc_io_phys]
    mov edx, 31
    call msc_bulk
    jc .reset
    cmp eax, CC_SUCCESS
    jne .reset
    test r9d, r9d                       ; data
    jz .status
    mov r14, [r12 + MS_OUT]
    test r8d, r8d
    jz .data
    mov r14, [r12 + MS_IN]
.data:
    mov rsi, [msc_buf_phys]
    mov edx, r9d
    call msc_bulk
    jc .reset
    cmp eax, CC_SUCCESS
    je .status
    cmp eax, CC_SHORT
    je .status
    cmp eax, CC_STALL                   ; the device gave up on the data
    jne .reset
    call msc_unstall
.status:
    mov r14, [r12 + MS_IN]              ; the command status wrapper
    mov rsi, [msc_io_phys]
    add rsi, 64
    mov edx, 13
    call msc_bulk
    jc .reset
    cmp eax, CC_STALL
    jne .csw
    call msc_unstall                    ; once more, after a stall
    mov rsi, [msc_io_phys]
    add rsi, 64
    mov edx, 13
    call msc_bulk
    jc .reset
.csw:
    cmp eax, CC_SUCCESS
    je .check
    cmp eax, CC_SHORT
    jne .reset
.check:
    mov rdi, [msc_io]
    cmp dword [rdi + 64], 0x53425355    ; "USBS"
    jne .reset
    mov eax, [r12 + MS_TAG]
    cmp [rdi + 68], eax
    jne .reset
    mov eax, [rdi + 72]
    mov [msc_residue], eax
    movzx eax, byte [rdi + 76]
    test eax, eax
    jz .out
    cmp eax, 1
    je .out                             ; failed: the caller asks for sense
.reset:
    call msc_reset                      ; phase error or a broken transport
    mov eax, -1
.out:
    popfq
    pop r15
    pop r14
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    test eax, eax
    jz .ok
    stc
    ret
.ok:
    clc
    ret

; msc_bulk(R14 = endpoint, RSI = physical buffer, EDX = bytes; RBX = device,
; R15 = controller; interrupts off) -> EAX = completion code, EDX = bytes
; not moved; CF if nothing came back (the transfer is then abandoned).
; Preserves others.
msc_bulk:
    push rcx
    push rsi
    push rdi
    push r8
    lea rdi, [r14 + EP_RING]
    mov ecx, (TRB_NORMAL << 10) | (1 << 5) | (1 << 2)   ; IOC, ISP
    call ring_push
    mov rax, [r15 + XC_DB]
    mov ecx, [rbx + DV_SLOT]
    mov edi, [r14 + EP_DCI]
    mov [rax + rcx * 4], edi
    mov r8d, MSC_WAIT
.wait:
    mov edi, TRB_EV_TRANSFER
    mov esi, [rbx + DV_SLOT]
    mov edx, [r14 + EP_DCI]
    call xhci_wait
    jnc .done
    dec r8d
    jnz .wait
    mov edi, [r14 + EP_DCI]             ; stop it, step past the transfer
    lea rsi, [r14 + EP_RING]
    call usb_reset_ep
    stc
    jmp .out
.done:
    mov edx, [r15 + XC_EVENT + 8]
    and edx, 0xFFFFFF
    clc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    ret

; msc_unstall(R14 = endpoint, RBX = device): reset the endpoint in the
; controller and clear the halt in the device. Preserves all.
msc_unstall:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, [r14 + EP_DCI]
    lea rsi, [r14 + EP_RING]
    call usb_reset_ep
    mov esi, [r14 + EP_ADDR]            ; CLEAR_FEATURE(ENDPOINT_HALT)
    shl rsi, 32
    or rsi, 0x0102
    xor edx, edx
    xor ecx, ecx
    call usb_control
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; msc_reset(R12, RBX): Bulk-Only Mass Storage Reset, then both endpoints.
; Preserves all.
msc_reset:
    push rax
    push rcx
    push rdx
    push rsi
    push r14
    mov esi, [r12 + MS_IFACE]
    shl rsi, 32
    or rsi, 0xFF21
    xor edx, edx
    xor ecx, ecx
    call usb_control
    mov r14, [r12 + MS_IN]
    call msc_unstall
    mov r14, [r12 + MS_OUT]
    call msc_unstall
    pop r14
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Disk operations: RBX = disk, RSI = first block, EDX = blocks, RDI = buffer
;  -> CF on failure. Preserve all but RAX.
; -----------------------------------------------------------------------------
msc_read:
    push rcx
    xor ecx, ecx
    jmp msc_rw
msc_write:
    push rcx
    mov ecx, 1
msc_rw:
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    mov r12, [rbx + DK_CTX]
    mov r11d, ecx                       ; write?
    mov r9d, edx                        ; blocks left
.chunk:
    test r9d, r9d
    jz .ok
    mov ecx, [r12 + MS_SHIFT]
    mov eax, MSC_BOUNCE
    shr eax, cl
    mov r10d, r9d
    cmp r10d, eax
    jbe .sized
    mov r10d, eax
.sized:
    mov r13d, r10d
    shl r13d, cl                        ; bytes
    test r11d, r11d
    jz .command
    push rsi
    push rdi
    mov rsi, rdi
    mov rdi, [msc_buf]
    mov ecx, r13d
    rep movsb
    pop rdi
    pop rsi
.command:
    mov r8d, 2                          ; tries: a unit attention costs one
.try:
    call msc_cdb_rw
    mov edx, r13d
    push r8
    xor r8d, r8d
    test r11d, r11d
    jnz .out_dir
    inc r8d
.out_dir:
    call msc_command
    pop r8
    jnc .moved
    cmp eax, 1
    jne .fail
    call msc_sense
    mov eax, [r12 + MS_SENSE]
    shr eax, 16
    cmp eax, 6                          ; unit attention: try again
    jne .refused
    dec r8d
    jnz .try
    jmp .refused
.moved:
    cmp dword [msc_residue], 0
    jne .fail
    test r11d, r11d
    jnz .written
    push rsi
    mov rsi, [msc_buf]
    mov ecx, r13d
    rep movsb                           ; advances RDI
    pop rsi
    jmp .advance
.written:
    add rdi, r13
.advance:
    add rsi, r10
    sub r9d, r10d
    jmp .chunk
.ok:
    clc
    jmp .out
.refused:
    cmp eax, 7                          ; data protect
    jne .fail
    mov rax, [rbx + DK_INDEX]
    KLOG "disk%u is write-protected", rax
    stc
    jmp .out
.fail:
    mov eax, [r12 + MS_SENSE]
    KLOG "usb storage: block %u failed (sense %06x)", rsi, rax
    stc
.out:
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
    ret

; msc_cdb_rw(RSI = block, R10D = blocks, R11D = 1 to write) -> msc_cdb,
; ECX = its length: READ/WRITE (10), or (16) past 2^32 blocks. Preserves others.
msc_cdb_rw:
    push rax
    call msc_cdb_clear
    mov rax, rsi
    add rax, r10
    shr rax, 32
    jnz .long
    mov al, 0x28
    test r11d, r11d
    jz .op10
    mov al, 0x2A
.op10:
    mov [msc_cdb], al
    mov eax, esi
    bswap eax
    mov [msc_cdb + 2], eax
    mov eax, r10d
    rol ax, 8
    mov [msc_cdb + 7], ax
    mov ecx, 10
    pop rax
    ret
.long:
    mov al, 0x88
    test r11d, r11d
    jz .op16
    mov al, 0x8A
.op16:
    mov [msc_cdb], al
    mov rax, rsi
    bswap rax
    mov [msc_cdb + 2], rax
    mov eax, r10d
    bswap eax
    mov [msc_cdb + 10], eax
    mov ecx, 16
    pop rax
    ret

; msc_flush(RBX = disk) -> CF: SYNCHRONIZE CACHE. A stick that does not
; know the command has no cache to flush.
msc_flush:
    push rcx
    push rdx
    push r8
    push r12
    mov r12, [rbx + DK_CTX]
    call msc_cdb_clear
    mov byte [msc_cdb], 0x35
    mov ecx, 10
    xor edx, edx
    xor r8d, r8d
    call msc_command
    jnc .out
    cmp eax, 1
    jne .fail
    call msc_sense
    clc
    jmp .out
.fail:
    stc
.out:
    pop r12
    pop r8
    pop rdx
    pop rcx
    ret

; msc_describe(RBX = disk, RDI = buffer)
msc_describe:
    push rax
    mov rax, [rbx + DK_CTX]
    add rax, MS_NAME
    SPRINTF rdi, "%s", rax
    pop rax
    ret

section .rodata
align 8
msc_disk_ops:   dq msc_read, msc_write, msc_flush, msc_describe
str_msc_kind:   db 'USB', 0
str_role_storage: db 'storage', 0

section .bss
alignb 8
msc_buf:        resq 1                  ; bounce buffer, mapped and physical
msc_buf_phys:   resq 1
msc_io:         resq 1                  ; CBW at 0, CSW at 64
msc_io_phys:    resq 1
msc_residue:    resd 1
msc_cdb:        resb 16
alignb 8
msc_sticks:     resb MAX_MSC * MS_SIZE
