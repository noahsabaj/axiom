; =============================================================================
;  nvme.asm - NVM Express SSDs. One admin queue pair and one I/O queue pair
;  per controller, polled: the main loop asks and waits, which an SSD
;  answers in microseconds. Transfers go through one physically contiguous
;  bounce buffer with a prebuilt PRP list, so callers may use any kernel
;  buffer. Each controller's first active namespace becomes a disk.
;
;  Registers by convention: R15 = controller.
; =============================================================================

MAX_NVME        equ 4
NV_QADMIN       equ 32                  ; admin queue entries
NV_QIO          equ 64                  ; I/O queue entries
NV_BOUNCE       equ 64 * 1024           ; bytes per transfer at most

; controller
NV_MMIO         equ 0
NV_STRIDE       equ 8                   ; doorbell stride, bytes
NV_TIMEOUT      equ 12                  ; ms, from CAP.TO
NV_ASQ          equ 16                  ; queues: mapped, then physical
NV_ASQP         equ 24
NV_ACQ          equ 32
NV_ACQP         equ 40
NV_ISQ          equ 48
NV_ISQP         equ 56
NV_ICQ          equ 64
NV_ICQP         equ 72
NV_ASQT         equ 80                  ; admin SQ tail
NV_ACQH         equ 84                  ; admin CQ head
NV_APHASE       equ 88
NV_ISQT         equ 92
NV_ICQH         equ 96
NV_IPHASE       equ 100
NV_CID          equ 104
NV_MAXXFER      equ 108                 ; bytes per command
NV_NSID         equ 112
NV_SHIFT        equ 116                 ; log2 of the block size
NV_BLOCKS       equ 120
NV_BDF          equ 128
NV_ISIZE        equ 132                 ; I/O queue entries actually used
NV_MODEL        equ 136                 ; 40 + NUL
NV_SERIAL       equ 184                 ; 20 + NUL
NV_FW           equ 208                 ; 8 + NUL
NV_SIZE         equ 256

; registers
NVR_CAP         equ 0x00
NVR_VS          equ 0x08
NVR_CC          equ 0x14
NVR_CSTS        equ 0x1C
NVR_AQA         equ 0x24
NVR_ASQ         equ 0x28
NVR_ACQ         equ 0x30
NVR_DOORBELL    equ 0x1000

section .text

; nvme_init: every NVMe controller PCI reported
nvme_init:
    push rbx
    push r12
    push r15
    lea rbx, [pci_devices]
    xor r12d, r12d
.next:
    cmp r12d, [pci_count]
    jae .out
    cmp byte [rbx + PE_CLASS], 0x01     ; mass storage,
    jne .skip
    cmp byte [rbx + PE_SUBCLASS], 0x08  ; non-volatile memory,
    jne .skip
    cmp byte [rbx + PE_PROGIF], 0x02    ; NVM Express
    jne .skip
    mov eax, [nvme_count]
    cmp eax, MAX_NVME
    jae .out
    imul r15, rax, NV_SIZE
    lea rax, [nvme_ctrl]
    add r15, rax
    mov rdi, rbx
    call nvme_start
    jc .failed
    inc dword [nvme_count]
    call nvme_add_disk
    jmp .skip
.failed:
    movzx eax, word [rbx + PE_VENDOR]
    movzx ecx, word [rbx + PE_DEVICE]
    KLOG "nvme: controller %04x:%04x did not start", rax, rcx
.skip:
    add rbx, PCI_ENTRY
    inc r12d
    jmp .next
.out:
    pop r15
    pop r12
    pop rbx
    ret

; nvme_start(RDI = PCI entry, R15 = controller) -> CF if unusable
nvme_start:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov rbx, rdi
    mov rdi, r15
    mov ecx, NV_SIZE
    xor eax, eax
    rep stosb
    cmp qword [nv_bounce], 0            ; one bounce buffer for every drive
    jne .bounce_ok
    mov edi, NV_BOUNCE / 4096 + 1       ; data, then its PRP list
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    mov [nv_bounce_phys], rax
    mov rdx, rax
    add rax, [phys_base]
    mov [nv_bounce], rax
    lea rdi, [rax + NV_BOUNCE]          ; PRP list: pages 1.. of the buffer
    mov ecx, NV_BOUNCE / 4096 - 1
.prp:
    add rdx, 4096
    mov [rdi], rdx
    add rdi, 8
    dec ecx
    jnz .prp
.bounce_ok:
    movzx edi, byte [rbx + PE_BUS]
    shl edi, 8
    movzx eax, byte [rbx + PE_DEV]
    shl eax, 3
    or edi, eax
    movzx eax, byte [rbx + PE_FN]
    or edi, eax
    mov [r15 + NV_BDF], edi
    mov r13d, edi
    mov esi, 0x10                       ; BAR0, 64-bit
    call pci_read32
    mov r12d, eax
    and r12d, ~0xF
    mov ecx, eax
    and ecx, 6
    cmp ecx, 4
    jne .bar
    mov edi, r13d
    mov esi, 0x14
    call pci_read32
    shl rax, 32
    or r12, rax
.bar:
    test r12, r12
    jz .fail
    mov edi, r13d                       ; memory decode, bus master, no INTx
    mov esi, 0x04
    call pci_read32
    or eax, 6 | (1 << 10)
    mov edx, eax
    mov edi, r13d
    mov esi, 0x04
    call pci_write32
    mov rdi, r12
    mov esi, 0x4000
    call mmio_map
    test rax, rax
    jz .fail
    mov [r15 + NV_MMIO], rax
    mov r12, rax
    mov eax, [r12 + NVR_CAP + 4]        ; 32-bit halves: some drives want that
    shl rax, 32
    mov ecx, [r12 + NVR_CAP]
    or rax, rcx
    mov rcx, rax                        ; doorbell stride 4 << DSTRD
    shr rcx, 32
    and ecx, 0xF
    mov edx, 4
    shl edx, cl
    mov [r15 + NV_STRIDE], edx
    mov rcx, rax                        ; timeout in 500 ms units
    shr rcx, 24
    and ecx, 0xFF
    imul ecx, ecx, 500
    add ecx, 500
    mov [r15 + NV_TIMEOUT], ecx
    mov rcx, rax                        ; 4 KiB pages must be allowed
    shr rcx, 48
    test ecx, 0xF
    jnz .fail
    movzx ecx, ax                       ; entries the controller allows - 1
    inc ecx
    cmp ecx, NV_QIO
    jbe .qsize
    mov ecx, NV_QIO
.qsize:
    mov [r15 + NV_ISIZE], ecx
    mov eax, [r12 + NVR_CC]             ; stop it, if the firmware left it on
    test eax, 1
    jz .stopped
    and eax, ~1
    mov [r12 + NVR_CC], eax
.stopped:
    xor edx, edx                        ; wait for RDY = 0
    call nvme_wait_ready
    jc .fail
    call nvme_alloc_page                ; admin queues
    mov [r15 + NV_ASQ], rdx
    mov [r15 + NV_ASQP], rax
    call nvme_alloc_page
    mov [r15 + NV_ACQ], rdx
    mov [r15 + NV_ACQP], rax
    call nvme_alloc_page                ; I/O queues
    mov [r15 + NV_ISQ], rdx
    mov [r15 + NV_ISQP], rax
    call nvme_alloc_page
    mov [r15 + NV_ICQ], rdx
    mov [r15 + NV_ICQP], rax
    mov dword [r15 + NV_APHASE], 1
    mov dword [r15 + NV_IPHASE], 1
    mov dword [r12 + NVR_AQA], ((NV_QADMIN - 1) << 16) | (NV_QADMIN - 1)
    mov rax, [r15 + NV_ASQP]
    mov [r12 + NVR_ASQ], eax
    shr rax, 32
    mov [r12 + NVR_ASQ + 4], eax
    mov rax, [r15 + NV_ACQP]
    mov [r12 + NVR_ACQ], eax
    shr rax, 32
    mov [r12 + NVR_ACQ + 4], eax
    mov dword [r12 + NVR_CC], 0x00460001    ; 64-byte SQEs, 16-byte CQEs, 4 KiB, on
    mov edx, 1
    call nvme_wait_ready
    jc .fail
    call nvme_identify
    jc .fail
    call nvme_queues
    jc .fail
    call nvme_namespace
    jc .fail
    clc
    jmp .out
.fail:
    stc
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; nvme_alloc_page -> RAX = physical, RDX = mapped, zeroed (panics if none)
nvme_alloc_page:
    jmp usb_alloc_page

; nvme_wait_ready(R15, EDX = the RDY value wanted) -> CF on timeout or fatal status
nvme_wait_ready:
    push rcx
    push rsi
    push rdi
    push r12
    mov r12, [r15 + NV_MMIO]
    mov edi, [r15 + NV_TIMEOUT]
    push rdx
    call usb_deadline
    pop rdx
    mov rsi, rax
.poll:
    mov eax, [r12 + NVR_CSTS]
    cmp eax, -1                         ; gone from the bus
    je .fail
    test eax, 2                         ; controller fatal status
    jnz .fail
    and eax, 1
    cmp eax, edx
    je .ok
    push rdx
    call usb_expired
    pop rdx
    jc .fail
    pause
    jmp .poll
.ok:
    clc
    jmp .out
.fail:
    stc
.out:
    pop r12
    pop rdi
    pop rsi
    pop rcx
    ret

; nvme_cmd_clear: a zeroed command in nv_cmd -> RDI = nv_cmd
nvme_cmd_clear:
    push rcx
    push rax
    lea rdi, [nv_cmd]
    mov ecx, 8
    xor eax, eax
    rep stosq
    pop rax
    pop rcx
    lea rdi, [nv_cmd]
    ret

; nvme_submit(R15, ESI = 0 admin / 1 I/O): send nv_cmd, wait for its
; completion -> EAX = status field (0 = success), CF on error or timeout.
; Preserves others.
nvme_submit:
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
    mov r12, [r15 + NV_MMIO]
    mov eax, [r15 + NV_CID]             ; command identifier
    inc dword [r15 + NV_CID]
    and eax, 0xFFFF
    mov r11d, eax
    mov ecx, [nv_cmd]
    and ecx, 0xFFFF
    shl eax, 16
    or ecx, eax
    mov [nv_cmd], ecx
    test esi, esi
    jnz .io
    mov rbx, [r15 + NV_ASQ]
    lea r8, [r15 + NV_ASQT]
    mov r9, [r15 + NV_ACQ]
    lea r10, [r15 + NV_ACQH]
    mov ecx, NV_QADMIN
    jmp .queue
.io:
    mov rbx, [r15 + NV_ISQ]
    lea r8, [r15 + NV_ISQT]
    mov r9, [r15 + NV_ICQ]
    lea r10, [r15 + NV_ICQH]
    mov ecx, [r15 + NV_ISIZE]
.queue:
    mov eax, [r8]                       ; copy into the slot at the tail
    shl eax, 6
    lea rdi, [rbx + rax]
    push rsi
    push rcx
    lea rsi, [nv_cmd]
    mov ecx, 8
    rep movsq
    pop rcx
    pop rsi
    mov eax, [r8]
    inc eax
    cmp eax, ecx
    jb .tail
    xor eax, eax
.tail:
    mov [r8], eax
    mov edx, esi                        ; SQ doorbell: 2 * queue
    shl edx, 1
    imul edx, [r15 + NV_STRIDE]
    mov [r12 + NVR_DOORBELL + rdx], eax
    push rcx
    mov edi, [r15 + NV_TIMEOUT]
    call usb_deadline
    pop rcx
    mov rdi, rax
.poll:
    mov eax, [r10]                      ; the entry at the CQ head
    shl eax, 4
    mov edx, [r9 + rax + 12]
    shr edx, 16
    and edx, 1
    lea rax, [r15 + NV_APHASE]
    test esi, esi
    jz .phase
    lea rax, [r15 + NV_IPHASE]
.phase:
    cmp edx, [rax]
    je .done
    push rsi
    push rdx
    mov rsi, rdi
    call usb_expired
    pop rdx
    pop rsi
    jc .timeout
    pause
    jmp .poll
.done:
    mov eax, [r10]
    shl eax, 4
    mov edx, [r9 + rax + 12]
    mov eax, [r10]                      ; advance the head (and the phase)
    inc eax
    cmp eax, ecx
    jb .head
    xor eax, eax
    lea rbx, [r15 + NV_APHASE]
    test esi, esi
    jz .flip
    lea rbx, [r15 + NV_IPHASE]
.flip:
    xor dword [rbx], 1
.head:
    mov [r10], eax
    lea ebx, [esi * 2 + 1]              ; CQ doorbell: 2 * queue + 1
    imul ebx, [r15 + NV_STRIDE]
    mov [r12 + NVR_DOORBELL + rbx], eax
    movzx eax, dx                       ; ours?
    cmp eax, r11d
    jne .poll_again
    mov eax, edx
    shr eax, 17                         ; status code and type
    and eax, 0x7FF
    jz .ok
    stc
    jmp .out
.poll_again:
    jmp .poll
.timeout:
    KLOG "nvme: command %02x timed out", qword [nv_cmd_op]
    mov eax, -1
    stc
    jmp .out
.ok:
    clc
.out:
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
    ret

; nvme_identify(R15) -> CF: model, serial, firmware, transfer limit
nvme_identify:
    push rcx
    push rsi
    push rdi
    call nvme_cmd_clear
    mov byte [rdi], 0x06                ; Identify
    mov rax, [nv_bounce_phys]
    mov [rdi + 24], rax
    mov dword [rdi + 40], 1             ; the controller
    mov byte [nv_cmd_op], 0x06
    xor esi, esi
    call nvme_submit
    jc .out
    mov rsi, [nv_bounce]
    push rsi
    lea rdi, [r15 + NV_SERIAL]
    add rsi, 4
    mov ecx, 20
    call nvme_copy_text
    mov rsi, [rsp]
    lea rdi, [r15 + NV_MODEL]
    add rsi, 24
    mov ecx, 40
    call nvme_copy_text
    mov rsi, [rsp]
    lea rdi, [r15 + NV_FW]
    add rsi, 64
    mov ecx, 8
    call nvme_copy_text
    pop rsi
    mov dword [r15 + NV_MAXXFER], NV_BOUNCE
    movzx ecx, byte [rsi + 77]          ; MDTS: 2^n pages, 0 = no limit
    test ecx, ecx
    jz .ok
    cmp ecx, 4
    jae .ok                             ; 64 KiB or more: the bounce buffer decides
    mov eax, 4096
    shl eax, cl
    mov [r15 + NV_MAXXFER], eax
.ok:
    clc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; nvme_copy_text(RSI = space-padded ASCII, ECX = bytes, RDI = out): trimmed,
; NUL-terminated
nvme_copy_text:
    push rax
    push rcx
    push rdx
    mov edx, ecx
.trim:
    test edx, edx
    jz .copy
    cmp byte [rsi + rdx - 1], ' '
    ja .copy
    dec edx
    jmp .trim
.copy:
    mov ecx, edx
    rep movsb
    mov byte [rdi], 0
    pop rdx
    pop rcx
    pop rax
    ret

; nvme_queues(R15) -> CF: create I/O completion queue 1, then submission queue 1
nvme_queues:
    push rsi
    push rdi
    call nvme_cmd_clear
    mov byte [rdi], 0x05                ; Create I/O Completion Queue
    mov byte [nv_cmd_op], 0x05
    mov rax, [r15 + NV_ICQP]
    mov [rdi + 24], rax
    mov eax, [r15 + NV_ISIZE]
    dec eax
    shl eax, 16
    or eax, 1                           ; queue 1
    mov [rdi + 40], eax
    mov dword [rdi + 44], 1             ; physically contiguous, no interrupts
    xor esi, esi
    call nvme_submit
    jc .out
    call nvme_cmd_clear
    mov byte [rdi], 0x01                ; Create I/O Submission Queue
    mov byte [nv_cmd_op], 0x01
    mov rax, [r15 + NV_ISQP]
    mov [rdi + 24], rax
    mov eax, [r15 + NV_ISIZE]
    dec eax
    shl eax, 16
    or eax, 1
    mov [rdi + 40], eax
    mov dword [rdi + 44], (1 << 16) | 1 ; completions to queue 1, contiguous
    xor esi, esi
    call nvme_submit
.out:
    pop rdi
    pop rsi
    ret

; nvme_namespace(R15) -> CF: the first active namespace, its size and blocks
nvme_namespace:
    push rcx
    push rsi
    push rdi
    call nvme_cmd_clear
    mov byte [rdi], 0x06                ; Identify: active namespace list
    mov byte [nv_cmd_op], 0x06
    mov rax, [nv_bounce_phys]
    mov [rdi + 24], rax
    mov dword [rdi + 40], 2
    xor esi, esi
    call nvme_submit
    mov eax, 1                          ; older controllers: assume namespace 1
    jc .nsid
    mov rsi, [nv_bounce]
    mov eax, [rsi]
    test eax, eax
    jz .fail
.nsid:
    mov [r15 + NV_NSID], eax
    call nvme_cmd_clear
    mov byte [rdi], 0x06                ; Identify the namespace
    mov eax, [r15 + NV_NSID]
    mov [rdi + 4], eax
    mov rax, [nv_bounce_phys]
    mov [rdi + 24], rax
    mov dword [rdi + 40], 0
    xor esi, esi
    call nvme_submit
    jc .fail
    mov rsi, [nv_bounce]
    mov rax, [rsi]                      ; size in blocks
    test rax, rax
    jz .fail
    mov [r15 + NV_BLOCKS], rax
    movzx ecx, byte [rsi + 26]          ; formatted LBA size
    and ecx, 0xF
    mov eax, [rsi + 128 + rcx * 4]
    shr eax, 16
    and eax, 0xFF                       ; log2 of the block size
    cmp eax, 9
    jb .fail
    cmp eax, 12
    ja .fail
    mov [r15 + NV_SHIFT], eax
    clc
    jmp .out
.fail:
    stc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; nvme_add_disk(R15): tell disk.asm about it
nvme_add_disk:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor r9d, r9d                        ; fixed
    lea rdi, [str_nv_kind]
    mov rsi, [r15 + NV_BLOCKS]
    mov ecx, [r15 + NV_SHIFT]
    mov rdx, r15
    lea r8, [nvme_disk_ops]
    call disk_add
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Disk operations: RBX = disk, RSI = first block, EDX = blocks, RDI = buffer
;  -> CF on failure. Preserve all but RAX.
; -----------------------------------------------------------------------------
nvme_read:
    push rcx
    xor ecx, ecx
    jmp nvme_rw
nvme_write:
    push rcx
    mov ecx, 1
nvme_rw:
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r15
    mov r15, [rbx + DK_CTX]
    mov r8d, ecx                        ; write?
    mov r9d, edx                        ; blocks left
    mov ecx, [r15 + NV_SHIFT]
.chunk:
    test r9d, r9d
    jz .ok
    mov eax, [r15 + NV_MAXXFER]         ; blocks per command
    shr eax, cl
    mov r10d, r9d
    cmp r10d, eax
    jbe .size
    mov r10d, eax
.size:
    mov edx, r10d                       ; bytes this time
    shl edx, cl
    test r8d, r8d
    jz .command
    push rcx                            ; write: into the bounce buffer first
    push rsi
    push rdi
    mov rsi, rdi
    mov rdi, [nv_bounce]
    mov ecx, edx
    rep movsb
    pop rdi
    pop rsi
    pop rcx
.command:
    push rdi
    call nvme_cmd_clear
    mov eax, 0x02                       ; read
    test r8d, r8d
    jz .opcode
    mov eax, 0x01                       ; write
.opcode:
    mov [rdi], al
    mov [nv_cmd_op], al
    mov eax, [r15 + NV_NSID]
    mov [rdi + 4], eax
    mov rax, [nv_bounce_phys]
    mov [rdi + 24], rax                 ; PRP1
    cmp edx, 4096
    jbe .prp_done
    add rax, 4096                       ; PRP2: the second page ..
    cmp edx, 8192
    jbe .prp2
    mov rax, [nv_bounce_phys]           ; .. or the list of all the others
    add rax, NV_BOUNCE
.prp2:
    mov [rdi + 32], rax
.prp_done:
    mov [rdi + 40], rsi                 ; starting block
    lea eax, [r10d - 1]
    mov [rdi + 48], eax                 ; blocks - 1
    pop rdi
    push rsi
    mov esi, 1
    call nvme_submit
    pop rsi
    jc .fail
    test r8d, r8d
    jnz .next
    push rcx                            ; read: out of the bounce buffer
    push rsi
    mov rsi, [nv_bounce]
    mov ecx, edx
    rep movsb                           ; advances RDI
    pop rsi
    pop rcx
    jmp .advance
.next:
    add rdi, rdx
.advance:
    add rsi, r10
    sub r9d, r10d
    jmp .chunk
.ok:
    clc
    jmp .out
.fail:
    movzx edx, byte [nv_cmd_op]
    KLOG "nvme: %s failed at block %u (status %x)", qword [nv_op_name + rdx * 8 - 8], rsi, rax
    stc
.out:
    pop r15
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nvme_flush(RBX = disk) -> CF: make written data durable
nvme_flush:
    push rsi
    push rdi
    push r15
    mov r15, [rbx + DK_CTX]
    call nvme_cmd_clear
    mov byte [rdi], 0x00
    mov byte [nv_cmd_op], 0x00
    mov eax, [r15 + NV_NSID]
    mov [rdi + 4], eax
    mov esi, 1
    call nvme_submit
    pop r15
    pop rdi
    pop rsi
    ret

; nvme_describe(RBX = disk, RDI = buffer): "model, firmware x"
nvme_describe:
    push rax
    push rcx
    push r15
    mov r15, [rbx + DK_CTX]
    lea rax, [r15 + NV_MODEL]
    lea rcx, [r15 + NV_FW]
    SPRINTF rdi, "%s, firmware %s", rax, rcx
    pop r15
    pop rcx
    pop rax
    ret

section .rodata
align 8
nvme_disk_ops:  dq nvme_read, nvme_write, nvme_flush, nvme_describe
str_nv_kind:    db 'NVMe', 0
str_nv_write:   db 'write', 0
str_nv_read:    db 'read', 0
nv_op_name:     dq str_nv_write, str_nv_read

section .bss
alignb 8
nv_bounce:      resq 1
nv_bounce_phys: resq 1
nvme_count:     resd 1
nv_cmd_op:      resq 1
alignb 64
nv_cmd:         resb 64
nvme_ctrl:      resb MAX_NVME * NV_SIZE
