; =============================================================================
;  nvme.asm - NVM Express SSDs. An admin queue pair, polled, for setting a
;  controller up; then an I/O queue pair per CPU (as many as it allows),
;  each with its own MSI-X entry aimed at its CPU. A thread's command goes
;  on the queue for the CPU it runs on, straight from or into its own
;  buffer (each page looked up for the PRP list), and the thread parks
;  until that CPU's interrupt says it is done; at boot, with interrupts
;  off, or without MSI-X, it polls. Each controller's first active
;  namespace becomes a disk.
;
;  Registers by convention: R15 = controller, RBX = queue.
; =============================================================================

MAX_NVME        equ 4
NV_QADMIN       equ 32                  ; admin queue entries
NV_QIO          equ 64                  ; I/O queue entries, at most
NV_QMAX         equ 32                  ; I/O queue pairs per controller, at most
NV_XFER         equ 64 * 1024           ; bytes per command, at most
NV_PRP_SLOT     equ 128                 ; PRP list bytes per command: 16 pages
NV_PARK_MS      equ 10                  ; a waiter looks for itself this often
NR_LOST         equ 1                   ; a slot whose command timed out

; controller
NV_MMIO         equ 0
NV_STRIDE       equ 8                   ; doorbell stride, bytes
NV_TIMEOUT      equ 12                  ; ms, from CAP.TO
NV_ASQ          equ 16                  ; admin queues: mapped, then physical
NV_ASQP         equ 24
NV_ACQ          equ 32
NV_ACQP         equ 40
NV_NQ           equ 48                  ; dword: I/O queue pairs
NV_MSIX         equ 52                  ; dword: 1 if they interrupt
NV_ASQT         equ 80                  ; admin SQ tail
NV_ACQH         equ 84                  ; admin CQ head
NV_APHASE       equ 88
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
NV_QUEUES       equ 256                 ; NV_QMAX queue pointers
NV_SIZE         equ 512

; an I/O queue pair (kmalloc)
NQ_SQ           equ 0                   ; mapped, then physical
NQ_SQP          equ 8
NQ_CQ           equ 16
NQ_CQP          equ 24
NQ_PRP          equ 32                  ; PRP lists, NV_PRP_SLOT per slot
NQ_PRPP         equ 40
NQ_SQDB         equ 48                  ; its doorbells, mapped
NQ_CQDB         equ 56
NQ_ID           equ 64                  ; dword: queue ID, from 1
NQ_ENTRIES      equ 68                  ; dword
NQ_TAIL         equ 72                  ; dword: SQ tail
NQ_HEAD         equ 76                  ; dword: CQ head
NQ_PHASE        equ 80                  ; dword
NQ_LOCK         equ 84                  ; dword: all of it
NQ_BUSY         equ 88                  ; dword: commands out
NQ_CPU          equ 92                  ; dword: where its interrupts go, -1 = polled
NQ_SUBMITTED    equ 96
NQ_COMPLETED    equ 104
NQ_IRQS         equ 112                 ; interrupts that found something
NQ_POLLS        equ 120                 ; polls that did
NQ_ERRORS       equ 128                 ; completions with a bad status
NQ_REQ          equ 136                 ; the request in each slot; CID = slot
NQ_SIZE         equ NQ_REQ + NV_QIO * 8

; a request, on its waiter's stack
NR_THREAD       equ 0                   ; to unpark, 0 if it polls
NR_DONE         equ 8                   ; dword: 1 being finished, 2 finished
NR_STATUS       equ 12                  ; dword
NR_SIZE         equ 16

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
    mov edi, VEC_NVME
    lea rsi, [nvme_irq]
    call irq_register
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
    mov eax, [r15 + NV_NQ]
    lea rcx, [str_nv_polled]
    cmp dword [r15 + NV_MSIX], 0
    je .say
    lea rcx, [str_nv_msix]
.say:
    lea rdx, [r15 + NV_MODEL]
    KLOG "nvme: %s, %u I/O queues, %s", rdx, rax, rcx
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
    cmp qword [nv_bounce], 0            ; a page for what Identify says
    jne .bounce_ok
    call nvme_alloc_page
    mov [nv_bounce_phys], rax
    mov [nv_bounce], rdx
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
    mov dword [r15 + NV_APHASE], 1
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

; nvme_submit(R15): send nv_cmd on the admin queue, poll for its completion
; -> EAX = status field (0 = success), CF on error or timeout; what the
; completion's dword 0 says in nv_result. Preserves others.
nvme_submit:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
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
    mov eax, [r15 + NV_ASQT]            ; copy into the slot at the tail
    shl eax, 6
    mov rdi, [r15 + NV_ASQ]
    add rdi, rax
    lea rsi, [nv_cmd]
    mov ecx, 8
    rep movsq
    mov eax, [r15 + NV_ASQT]
    inc eax
    cmp eax, NV_QADMIN
    jb .tail
    xor eax, eax
.tail:
    mov [r15 + NV_ASQT], eax
    mov [r12 + NVR_DOORBELL], eax       ; admin SQ doorbell
    mov edi, [r15 + NV_TIMEOUT]
    call usb_deadline
    mov rsi, rax
    mov r9, [r15 + NV_ACQ]
.poll:
    mov eax, [r15 + NV_ACQH]            ; the entry at the CQ head
    shl eax, 4
    mov edx, [r9 + rax + 12]
    shr edx, 16
    and edx, 1
    cmp edx, [r15 + NV_APHASE]
    je .done
    call usb_expired
    jc .timeout
    pause
    jmp .poll
.done:
    mov eax, [r15 + NV_ACQH]
    shl eax, 4
    mov edx, [r9 + rax + 12]
    mov ebx, [r9 + rax]
    mov eax, [r15 + NV_ACQH]            ; advance the head (and the phase)
    inc eax
    cmp eax, NV_QADMIN
    jb .head
    xor eax, eax
    xor dword [r15 + NV_APHASE], 1
.head:
    mov [r15 + NV_ACQH], eax
    mov ecx, [r15 + NV_STRIDE]          ; admin CQ doorbell: 1 * stride
    mov [r12 + NVR_DOORBELL + rcx], eax
    movzx eax, dx                       ; ours?
    cmp eax, r11d
    jne .poll
    mov [nv_result], ebx
    mov eax, edx
    shr eax, 17                         ; status code and type
    and eax, 0x7FF
    jz .ok
    stc
    jmp .out
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
    pop r9
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
    mov dword [r15 + NV_MAXXFER], NV_XFER
    movzx ecx, byte [rsi + 77]          ; MDTS: 2^n pages, 0 = no limit
    test ecx, ecx
    jz .ok
    cmp ecx, 4
    jae .ok                             ; 64 KiB or more: the PRP lists decide
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

; nvme_queues(R15) -> CF: an I/O queue pair per CPU, as many as the
; controller grants (Set Features, Number of Queues) and NV_QMAX allow,
; interrupting through MSI-X if it can; queue 1 at least
nvme_queues:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12d, [cpus_online]
    cmp r12d, NV_QMAX
    jbe .want
    mov r12d, NV_QMAX
.want:
    call nvme_cmd_clear
    mov byte [rdi], 0x09                ; Set Features
    mov byte [nv_cmd_op], 0x09
    mov dword [rdi + 40], 0x07          ; Number of Queues, each - 1
    lea eax, [r12d - 1]
    mov edx, eax
    shl edx, 16
    or eax, edx
    mov [rdi + 44], eax
    call nvme_submit
    jc .one
    mov eax, [nv_result]                ; granted: submission, completion - 1
    movzx edx, ax
    inc edx
    cmp r12d, edx
    jbe .sq
    mov r12d, edx
.sq:
    shr eax, 16
    inc eax
    cmp r12d, eax
    jbe .granted
    mov r12d, eax
    jmp .granted
.one:
    mov r12d, 1
.granted:
    call nvme_msix
    mov r13d, 1                         ; queue IDs from 1
.queue:
    cmp r13d, r12d
    ja .made
    call nvme_queue_new
    jc .short
    inc r13d
    jmp .queue
.short:
    cmp r13d, 1
    je .fail
.made:
    dec r13d
    mov [r15 + NV_NQ], r13d
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
    ret

; nvme_msix(R15, R12D = queues wanted) -> R12D = no more than its MSI-X table
; holds; NV_MSIX = 1 once entry i is aimed at CPU i (the BSP if that one is
; not online) with VEC_NVME. Left at 0 (polled) without MSI-X, or if a CPU
; it would aim at has an APIC ID above 255. Preserves others.
nvme_msix:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov dword [r15 + NV_MSIX], 0
    mov edi, [r15 + NV_BDF]
    mov esi, 0x11
    call pci_find_cap
    jc .out
    mov ebx, esi
    call pci_read32
    mov r8d, eax                        ; message control in the top half
    shr eax, 16
    and eax, 0x7FF
    inc eax                             ; table entries
    cmp r12d, eax
    jbe .fits
    mov r12d, eax
.fits:
    xor ecx, ecx
.check:
    cmp ecx, r12d
    jae .checked
    call nvme_cpu_for
    PERCPU rdx, rax
    cmp qword [rdx + PC_APIC_ID], 255
    ja .out
    inc ecx
    jmp .check
.checked:
    lea esi, [ebx + 4]
    call pci_read32                     ; table offset | BAR index
    mov edx, eax
    and edx, 7
    and eax, ~7
    mov r9d, eax
    lea esi, [edx * 4 + 0x10]           ; that BAR, maybe 64-bit
    call pci_read32
    mov edx, eax
    and edx, ~0xF
    and eax, 6
    cmp eax, 4
    jne .bar32
    add esi, 4
    call pci_read32
    shl rax, 32
    or rdx, rax
.bar32:
    push rdi
    lea rdi, [rdx + r9]
    mov esi, r12d
    shl esi, 4
    call mmio_map
    pop rdi
    test rax, rax
    jz .out
    mov r9, rax                         ; the table
    mov esi, ebx                        ; on, but masked while it is written
    mov edx, r8d
    or edx, (1 << 31) | (1 << 30)
    call pci_write32
    xor ecx, ecx
.entry:
    cmp ecx, r12d
    jae .entries
    call nvme_cpu_for
    PERCPU rdx, rax
    mov eax, [rdx + PC_APIC_ID]
    shl eax, 12
    or eax, 0xFEE00000                  ; fixed, edge, to that CPU
    mov edx, ecx
    shl edx, 4
    mov [r9 + rdx], eax
    mov dword [r9 + rdx + 4], 0
    mov dword [r9 + rdx + 8], VEC_NVME
    mov dword [r9 + rdx + 12], 0        ; unmasked
    inc ecx
    jmp .entry
.entries:
    mov esi, ebx
    mov edx, r8d
    and edx, ~(1 << 30)
    or edx, 1 << 31
    call pci_write32
    mov dword [r15 + NV_MSIX], 1
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; nvme_cpu_for(ECX = MSI-X entry) -> RAX = the CPU it goes to: that one, if
; it is online, else the BSP. Preserves others.
nvme_cpu_for:
    push rdx
    mov eax, ecx
    PERCPU rdx, rax
    cmp qword [rdx + PC_ONLINE], 0
    jne .out
    xor eax, eax
.out:
    pop rdx
    ret

; nvme_queue_new(R15, R13D = queue ID) -> CF: its completion queue, then its
; submission queue; NV_QUEUES[ID - 1]
nvme_queue_new:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    mov edi, NQ_SIZE
    call kmalloc
    test rax, rax
    jz .fail
    mov rbx, rax
    call nvme_alloc_page
    mov [rbx + NQ_SQ], rdx
    mov [rbx + NQ_SQP], rax
    call nvme_alloc_page
    mov [rbx + NQ_CQ], rdx
    mov [rbx + NQ_CQP], rax
    mov edi, NV_QIO * NV_PRP_SLOT / 4096
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    mov [rbx + NQ_PRPP], rax
    add rax, [phys_base]
    mov [rbx + NQ_PRP], rax
    mov [rbx + NQ_ID], r13d
    mov eax, [r15 + NV_ISIZE]
    mov [rbx + NQ_ENTRIES], eax
    mov dword [rbx + NQ_PHASE], 1
    mov dword [rbx + NQ_CPU], -1
    cmp dword [r15 + NV_MSIX], 0
    je .doorbells
    lea ecx, [r13d - 1]
    call nvme_cpu_for
    mov [rbx + NQ_CPU], eax
.doorbells:
    lea eax, [r13d * 2]                 ; SQ: 2 * ID, CQ: 2 * ID + 1
    imul eax, [r15 + NV_STRIDE]
    add rax, [r15 + NV_MMIO]
    add rax, NVR_DOORBELL
    mov [rbx + NQ_SQDB], rax
    mov ecx, [r15 + NV_STRIDE]
    add rax, rcx
    mov [rbx + NQ_CQDB], rax
    call nvme_cmd_clear
    mov byte [rdi], 0x05                ; Create I/O Completion Queue
    mov byte [nv_cmd_op], 0x05
    mov rax, [rbx + NQ_CQP]
    mov [rdi + 24], rax
    mov eax, [rbx + NQ_ENTRIES]
    dec eax
    shl eax, 16
    or eax, r13d
    mov [rdi + 40], eax
    mov eax, 1                          ; physically contiguous
    cmp dword [r15 + NV_MSIX], 0
    je .cq
    lea ecx, [r13d - 1]                 ; interrupts, through entry ID - 1
    shl ecx, 16
    or eax, ecx
    or eax, 2
.cq:
    mov [rdi + 44], eax
    call nvme_submit
    jc .fail
    call nvme_cmd_clear
    mov byte [rdi], 0x01                ; Create I/O Submission Queue
    mov byte [nv_cmd_op], 0x01
    mov rax, [rbx + NQ_SQP]
    mov [rdi + 24], rax
    mov eax, [rbx + NQ_ENTRIES]
    dec eax
    shl eax, 16
    or eax, r13d
    mov [rdi + 40], eax
    mov eax, r13d                       ; completions to its own CQ, contiguous
    shl eax, 16
    or eax, 1
    mov [rdi + 44], eax
    call nvme_submit
    jc .fail
    lea eax, [r13d - 1]
    mov [r15 + rax * 8 + NV_QUEUES], rbx
    clc
    jmp .out
.fail:
    stc                                 ; what it had stays; this is boot
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
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
;  I/O
; -----------------------------------------------------------------------------

; nvme_io(R15 = controller, EDI = opcode, RSI = first block, EDX = blocks, 0
; for none (a flush), R8 = buffer: dword-aligned, at most NV_MAXXFER bytes,
; mapped) -> EAX = status (0 = success, -1 = timed out, -2 = not mapped),
; CF on failure. Preserves others. From any thread; not from interrupt
; handlers, nor with a spinlock held.
nvme_io:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    sub rsp, 64 + NR_SIZE               ; the command, then the request
    mov rbp, rsp
    mov r9d, edi
    mov r11d, edx
    mov rdi, rbp
    xor eax, eax
    mov ecx, (64 + NR_SIZE) / 8
    rep stosq
    mov [rbp], r9b                      ; opcode
    mov eax, [r15 + NV_NSID]
    mov [rbp + 4], eax
    test r11d, r11d
    jz .nolba
    mov [rbp + 40], rsi                 ; starting block
    lea eax, [r11d - 1]
    mov [rbp + 48], eax                 ; blocks - 1
.nolba:
    lea r12, [rbp + 64]                 ; the request
    xor r14d, r14d                      ; 0: poll for it
    pushfq
    pop rax
    test eax, 0x200
    jz .who
    cmp dword [r15 + NV_MSIX], 0
    je .who
    mov r14, [gs:PC_CURRENT]            ; else park, to be unparked
.who:
    mov [r12 + NR_THREAD], r14
    mov rax, [gs:PC_INDEX]              ; the queue for this CPU
    xor edx, edx
    mov ecx, [r15 + NV_NQ]
    div rcx
    mov rbx, [r15 + rdx * 8 + NV_QUEUES]

.slot:
    pushfq
    cli
    lea rdi, [rbx + NQ_LOCK]
    call spin_lock
    mov ecx, [rbx + NQ_ENTRIES]
    dec ecx                             ; one entry always stays empty
    xor r13d, r13d
.find:
    cmp qword [rbx + r13 * 8 + NQ_REQ], 0
    je .found
    inc r13d
    cmp r13d, ecx
    jb .find
    xor edx, edx
    call nvme_drain                     ; full: anything finished?
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
    popfq
    test r14, r14
    jz .spin
    call nvme_yield
    jmp .slot
.spin:
    pause
    jmp .slot

.found:
    mov [rbx + r13 * 8 + NQ_REQ], r12
    inc dword [rbx + NQ_BUSY]
    test r11d, r11d
    jz .prp_done
    mov ecx, [r15 + NV_SHIFT]           ; R10D = bytes
    mov r10d, r11d
    shl r10d, cl
    mov rdi, r8
    call vmm_translate
    jc .unmapped
    mov [rbp + 24], rax                 ; PRP1: where it starts
    mov eax, r8d
    and eax, 0xFFF
    mov ecx, 4096
    sub ecx, eax                        ; bytes in its first page
    sub r10d, ecx
    jbe .prp_done
    lea rdi, [r8 + rcx]                 ; the next page
    cmp r10d, 4096
    ja .list
    call vmm_translate                  ; PRP2: the second and last page ..
    jc .unmapped
    mov [rbp + 32], rax
    jmp .prp_done
.list:
    mov eax, r13d                       ; .. or the slot's list of the rest
    shl eax, 7
    mov rsi, [rbx + NQ_PRPP]
    add rsi, rax
    mov [rbp + 32], rsi
    mov rsi, [rbx + NQ_PRP]
    add rsi, rax
.page:
    call vmm_translate
    jc .unmapped
    mov [rsi], rax
    add rsi, 8
    add rdi, 4096
    sub r10d, 4096
    ja .page
.prp_done:
    mov eax, r13d                       ; CID = slot
    shl eax, 16
    or [rbp], eax
    mov eax, [rbx + NQ_TAIL]
    shl eax, 6
    mov rdi, [rbx + NQ_SQ]
    add rdi, rax
    mov rsi, rbp
    mov ecx, 8
    rep movsq
    mov eax, [rbx + NQ_TAIL]
    inc eax
    cmp eax, [rbx + NQ_ENTRIES]
    jb .tail
    xor eax, eax
.tail:
    mov [rbx + NQ_TAIL], eax
    mov rdx, [rbx + NQ_SQDB]
    mov [rdx], eax
    inc qword [rbx + NQ_SUBMITTED]
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
    popfq

    mov edi, [r15 + NV_TIMEOUT]
    call usb_deadline
    mov r10, rax                        ; R10 = when to give up
.wait:
    cmp dword [r12 + NR_DONE], 0
    jne .finish
    test r14, r14
    jz .poll
    mov edi, NV_PARK_MS
    call usb_deadline
    mov rdi, rax
    call nvme_park
    cmp dword [r12 + NR_DONE], 0
    jne .finish
.poll:
    pushfq
    cli
    lea rdi, [rbx + NQ_LOCK]
    call spin_lock
    mov rdx, r12                        ; ours needs no unpark
    call nvme_drain
    test eax, eax
    jz .polled
    inc qword [rbx + NQ_POLLS]
.polled:
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
    popfq
    cmp dword [r12 + NR_DONE], 0
    jne .finish
    mov rsi, r10
    call usb_expired
    jc .timeout
    pause
    jmp .wait

.finish:
    cmp dword [r12 + NR_DONE], 2        ; until whoever finished it lets go
    je .status
    pause
    jmp .finish
.status:
    mov eax, [r12 + NR_STATUS]
    test eax, eax
    jz .ok
    stc
    jmp .out

.unmapped:
    mov qword [rbx + r13 * 8 + NQ_REQ], 0
    dec dword [rbx + NQ_BUSY]
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
    popfq
    KLOG "nvme: a buffer at %p is not mapped", r8
    mov eax, -2
    stc
    jmp .out

.timeout:
    pushfq
    cli
    lea rdi, [rbx + NQ_LOCK]
    call spin_lock
    cmp [rbx + r13 * 8 + NQ_REQ], r12
    jne .late
    mov qword [rbx + r13 * 8 + NQ_REQ], NR_LOST  ; not reused until it answers
.late:
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
    popfq
    cmp dword [r12 + NR_DONE], 0
    jne .finish                         ; it answered just now
    movzx eax, r9b
    mov ecx, [rbx + NQ_ID]
    KLOG "nvme: command %02x timed out on queue %u", rax, rcx
    mov eax, -1
    stc
    jmp .out
.ok:
    clc
.out:
    lea rsp, [rbp + 64 + NR_SIZE]
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; nvme_park(RDI = TSC deadline) / nvme_yield: thread_park_until and
; thread_yield, keeping R8-R11 (which nvme_io holds across them)
nvme_park:
    push r8
    push r9
    push r10
    push r11
    call thread_park_until
    jmp nvme_kept
nvme_yield:
    push r8
    push r9
    push r10
    push r11
    call thread_yield
nvme_kept:
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; nvme_drain(RBX = queue, its lock held, interrupts off; RDX = the caller's
; own request, or 0) -> EAX = completions taken: each one's request
; finished and its waiter unparked (but the caller); the CQ doorbell rung
; once. Preserves others.
nvme_drain:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r9, rdx
    xor r8d, r8d
.next:
    mov eax, [rbx + NQ_HEAD]
    shl eax, 4
    mov rsi, [rbx + NQ_CQ]
    mov edx, [rsi + rax + 12]           ; status, phase, CID
    mov eax, edx
    shr eax, 16
    and eax, 1
    cmp eax, [rbx + NQ_PHASE]
    jne .out
    inc r8d
    inc qword [rbx + NQ_COMPLETED]
    movzx ecx, dx                       ; CID = slot
    cmp ecx, [rbx + NQ_ENTRIES]
    jae .advance
    mov rsi, [rbx + rcx * 8 + NQ_REQ]
    test rsi, rsi
    jz .advance
    mov qword [rbx + rcx * 8 + NQ_REQ], 0
    dec dword [rbx + NQ_BUSY]
    cmp rsi, NR_LOST
    je .advance
    shr edx, 17
    and edx, 0x7FF
    jz .good
    inc qword [rbx + NQ_ERRORS]
.good:
    mov [rsi + NR_STATUS], edx
    mov dword [rsi + NR_DONE], 1
    mov rdi, [rsi + NR_THREAD]
    test rdi, rdi
    jz .done
    cmp rsi, r9
    je .done
    call thread_unpark
.done:
    mov dword [rsi + NR_DONE], 2        ; the waiter may go now
.advance:
    mov eax, [rbx + NQ_HEAD]
    inc eax
    cmp eax, [rbx + NQ_ENTRIES]
    jb .head
    xor eax, eax
    xor dword [rbx + NQ_PHASE], 1
.head:
    mov [rbx + NQ_HEAD], eax
    jmp .next
.out:
    test r8d, r8d
    jz .none
    mov eax, [rbx + NQ_HEAD]
    mov rdx, [rbx + NQ_CQDB]
    mov [rdx], eax
.none:
    mov eax, r8d
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nvme_irq: VEC_NVME, on the CPU an MSI-X entry names: every queue whose
; interrupts come here, drained
nvme_irq:
    push rbx
    push r12
    push r13
    push r15
    mov r13, [gs:PC_INDEX]
    lea r15, [nvme_ctrl]
    xor r12d, r12d
.ctrl:
    cmp r12d, [nvme_count]
    jae .out
    cmp dword [r15 + NV_MSIX], 0
    je .skip
    xor ecx, ecx
.queue:
    cmp ecx, [r15 + NV_NQ]
    jae .skip
    mov rbx, [r15 + rcx * 8 + NV_QUEUES]
    cmp [rbx + NQ_CPU], r13d
    jne .other
    lea rdi, [rbx + NQ_LOCK]
    call spin_lock
    xor edx, edx
    call nvme_drain
    test eax, eax
    jz .nothing
    inc qword [rbx + NQ_IRQS]
.nothing:
    lea rdi, [rbx + NQ_LOCK]
    call spin_unlock
.other:
    inc ecx
    jmp .queue
.skip:
    add r15, NV_SIZE
    inc r12d
    jmp .ctrl
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Disk operations: RBX = disk, RSI = first block, EDX = blocks, RDI = buffer
;  -> CF on failure. Preserve all but RAX. A buffer that is not dword-aligned
;  goes through one of the heap's.
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
    push r11
    push r15
    mov r15, [rbx + DK_CTX]
    mov r9d, ecx                        ; write?
    mov r10d, edx                       ; blocks left
    xor r11d, r11d                      ; R11 = an aligned copy, if needed
    test edi, 3
    jz .chunk
    push rdi
    mov edi, [r15 + NV_MAXXFER]
    call kmalloc
    pop rdi
    test rax, rax
    jz .nomem
    mov r11, rax
.chunk:
    test r10d, r10d
    jz .ok
    mov ecx, [r15 + NV_SHIFT]
    mov eax, [r15 + NV_MAXXFER]         ; blocks per command
    shr eax, cl
    mov edx, r10d
    cmp edx, eax
    jbe .size
    mov edx, eax
.size:
    mov eax, edx                        ; RAX = bytes this time
    shl eax, cl
    mov r8, rdi
    test r11, r11
    jz .command
    mov r8, r11
    test r9d, r9d
    jz .command
    push rcx                            ; write: into the copy first
    push rsi
    push rdi
    mov ecx, eax
    mov rsi, rdi
    mov rdi, r11
    rep movsb
    pop rdi
    pop rsi
    pop rcx
.command:
    push rax
    push rdi
    mov edi, 0x02                       ; read
    test r9d, r9d
    jz .opcode
    mov edi, 0x01                       ; write
.opcode:
    call nvme_io
    pop rdi
    jc .failed
    pop rax
    test r11, r11
    jz .advance
    test r9d, r9d
    jnz .advance
    push rcx                            ; read: out of the copy
    push rsi
    push rdi
    mov ecx, eax
    mov rsi, r11
    rep movsb
    pop rdi
    pop rsi
    pop rcx
.advance:
    add rdi, rax
    add rsi, rdx
    sub r10d, edx
    jmp .chunk
.ok:
    xor eax, eax
    jmp .free
.failed:
    add rsp, 8
    lea rcx, [str_nv_read]
    test r9d, r9d
    jz .say
    lea rcx, [str_nv_write]
.say:
    KLOG "nvme: %s failed at block %u (status %x)", rcx, rsi, rax
    mov eax, 1
    jmp .free
.nomem:
    KLOG "nvme: no memory for an aligned copy"
    mov eax, 1
.free:
    test r11, r11
    jz .flag
    mov rdi, r11
    call kfree
.flag:
    bt eax, 0                           ; CF = failed
    pop r15
    pop r11
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
    push rdx
    push rdi
    push r8
    push r15
    mov r15, [rbx + DK_CTX]
    xor edi, edi                        ; Flush
    xor edx, edx
    xor r8d, r8d
    call nvme_io
    pop r15
    pop r8
    pop rdi
    pop rdx
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
str_nv_msix:    db 'each interrupting its own CPU', 0
str_nv_polled:  db 'polled', 0

section .bss
alignb 8
nv_bounce:      resq 1                  ; a page for admin commands
nv_bounce_phys: resq 1
nvme_count:     resd 1
nv_result:      resd 1                  ; dword 0 of the last admin completion
nv_cmd_op:      resq 1
alignb 64
nv_cmd:         resb 64
nvme_ctrl:      resb MAX_NVME * NV_SIZE
