; =============================================================================
;  usb.asm - xHCI host controllers: ownership, reset, rings, commands, events
;  and interrupts. Devices, hubs and drivers live in usbdev.asm, usbhub.asm,
;  hid.asm and bt.asm.
;
;  Each controller signals the BSP with MSI-X or MSI, whose handler drains
;  the event ring; the main loop drains it too (with interrupts off), so a
;  controller without either still works, at the loop's pace.
; =============================================================================

MAX_XHCI        equ 4
MAX_DEV         equ 32
MAX_EP          equ 64
MAX_BIND        equ 4
DEV_PAGES       equ 12

; controller state (R15 points at one)
XC_MMIO         equ 0                   ; capability registers
XC_OP           equ 8                   ; operational registers
XC_RT           equ 16                  ; runtime registers
XC_DB           equ 24                  ; doorbells
XC_CTXSZ        equ 32                  ; 32 or 64-byte contexts
XC_SLOTS        equ 36
XC_PORTS        equ 40
XC_AC64         equ 44
XC_DCBAA        equ 48                  ; mapped address of the DCBAA
XC_CMD          equ 64                  ; command ring (ring struct)
XC_EVT          equ 96                  ; event ring (ring struct)
XC_EVENT        equ 128                 ; the event just taken off the ring
XC_BDF          equ 144
XC_MSI          equ 148                 ; 0 polled, 1 MSI, 2 MSI-X
XC_PORTCHG      equ 160                 ; 256 bits: root ports with news
XC_ROOTDEV      equ 192                 ; device index + 1 on each root port
XC_SLOTDEV      equ 448                 ; device index + 1 for each slot
XC_SIZE         equ 704

; ring struct
R_VIRT          equ 0
R_PHYS          equ 8
R_IDX           equ 16
R_CYCLE         equ 20
R_SIZE          equ 32

; device (RBX points at one)
DV_XC           equ 0
DV_SLOT         equ 8
DV_SPEED        equ 12
DV_ROOTPORT     equ 16
DV_ROUTE        equ 20
DV_DEPTH        equ 24                  ; hubs between it and the root port
DV_PARENT       equ 28                  ; hub's device index + 1, 0 on a root port
DV_PPORT        equ 32                  ; port on that hub
DV_TTSLOT       equ 36                  ; transaction translator, for LS/FS behind HS
DV_TTPORT       equ 40
DV_MPS0         equ 44
DV_EP0          equ 48                  ; control ring
DV_BUF          equ 80                  ; one page for small control transfers
DV_BUFP         equ 88
DV_IN           equ 96                  ; input context
DV_INP          equ 104
DV_OUT          equ 112                 ; output device context
DV_CFG          equ 120                 ; configuration descriptor, whole
DV_CFGP         equ 128
DV_CFGLEN       equ 136
DV_STATE        equ 140
DV_VID          equ 144                 ; word
DV_PID          equ 146                 ; word
DV_CLASS        equ 148                 ; class | subclass << 8 | protocol << 16
DV_HUBPORTS     equ 152
DV_HUBFLAGS     equ 156
DV_EPMAP        equ 160                 ; endpoint index + 1 for each DCI
DV_BINDS        equ 192                 ; MAX_BIND driver bindings
DV_PAGES        equ 288                 ; pages to free when it goes
DV_NPAGES       equ 384
DV_INDEX        equ 388
DV_HUBCHG       equ 392                 ; hub ports with news (bitmap)
DV_HUBPWR       equ 396                 ; hub: ms from power to good
DV_NAME         equ 400
DV_NAME_LEN     equ 48
DV_ROLE         equ 448                 ; "keyboard mouse" for listings
DV_ROLE_LEN     equ 32
DV_HUBEP        equ 480                 ; hub: its status change endpoint
DV_SIZE         equ 512

DS_FREE         equ 0
DS_ADDRESSING   equ 1
DS_CONFIGURING  equ 2
DS_RUNNING      equ 3

HUB_IS          equ 1                   ; DV_HUBFLAGS; bits 2-3: TT think time

BIND_START      equ 0
BIND_DETACH     equ 8
BIND_CTX        equ 16
BIND_SIZE       equ 24

; endpoint (R14 points at one)
EP_DEV          equ 0
EP_DCI          equ 8
EP_TYPE         equ 12                  ; xHCI type: 2/6 bulk, 3/7 interrupt
EP_MPS          equ 16
EP_INTERVAL     equ 20
EP_RING         equ 24
EP_HANDLER      equ 56
EP_CTX          equ 64
EP_BUF          equ 72
EP_BUFP         equ 80
EP_LEN          equ 88
EP_STATE        equ 92
EP_PENDING      equ 96                  ; transfers queued
EP_HALTED       equ 100
EP_AUTO         equ 104                 ; requeue after recovery
EP_BURST        equ 108
EP_ADDR         equ 112
EP_INDEX        equ 116
EP_SIZE         equ 128

SPEED_FS        equ 1
SPEED_LS        equ 2
SPEED_HS        equ 3
SPEED_SS        equ 4

CC_SUCCESS      equ 1
CC_STALL        equ 6
CC_SHORT        equ 13

; TRB types
TRB_NORMAL      equ 1
TRB_SETUP       equ 2
TRB_DATA        equ 3
TRB_STATUS      equ 4
TRB_LINK        equ 6
TRB_ENABLE_SLOT equ 9
TRB_DISABLE_SLOT equ 10
TRB_ADDRESS     equ 11
TRB_CONFIG_EP   equ 12
TRB_EVALUATE    equ 13
TRB_RESET_EP    equ 14
TRB_STOP_EP     equ 15
TRB_SET_DEQ     equ 16
TRB_EV_TRANSFER equ 32
TRB_EV_COMMAND  equ 33
TRB_EV_PORT     equ 34

PORTSC_KEEP     equ (1 << 9) | (3 << 14) | (7 << 25)   ; bits safe to write back

section .text

; usb_alloc_page -> RAX = physical, RDX = mapped; zeroed, and in the USB
; controllers' DMA domain. Panics if out of memory.
usb_alloc_page:
    push rdi
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    push rcx
    push rsi
    mov rdi, [usb_domain]
    mov rsi, rax
    mov edx, 4096
    mov ecx, VT_RW
    call iommu_map
    pop rsi
    pop rcx
    mov rdx, rax
    add rdx, [phys_base]
    pop rdi
    ret
.oom:
    xor edi, edi
    lea rsi, [str_usb_oom]
    jmp panic

; usb_deadline(EDI = ms) -> RAX = TSC deadline
usb_deadline:
    push rdx
    RDTSC64
    mov rdx, [tsc_per_ms]
    imul rdx, rdi
    add rax, rdx
    pop rdx
    ret

; usb_expired(RSI = deadline) -> CF = 1 once the deadline has passed. Clobbers RAX, RDX.
usb_expired:
    RDTSC64
    cmp rsi, rax                        ; deadline < now -> CF
    ret

; -----------------------------------------------------------------------------
;  Rings
; -----------------------------------------------------------------------------

; ring_init(RDI = ring struct): one page, 255 TRBs and a link back to the start
ring_init:
    call usb_alloc_page
    mov [rdi + R_PHYS], rax
    mov [rdi + R_VIRT], rdx
    mov dword [rdi + R_IDX], 0
    mov dword [rdi + R_CYCLE], 1
    mov [rdx + 255 * 16], rax           ; link TRB, toggle cycle
    mov dword [rdx + 255 * 16 + 12], (TRB_LINK << 10) | 2
    ret

; ring_push(RDI = ring, RSI = parameter qword, EDX = status, ECX = control
; without the cycle bit) -> RAX = physical address of the TRB
ring_push:
    push rbx
    push r8
    mov r8d, [rdi + R_IDX]
    mov rbx, r8
    shl rbx, 4
    add rbx, [rdi + R_VIRT]
    mov [rbx], rsi
    mov [rbx + 8], edx
    or ecx, [rdi + R_CYCLE]
    mov [rbx + 12], ecx                 ; control dword last: hands it over
    mov rax, r8
    shl rax, 4
    add rax, [rdi + R_PHYS]
    inc r8d
    cmp r8d, 255
    jb .store
    mov rbx, [rdi + R_VIRT]             ; follow the link, flip the cycle
    mov ecx, (TRB_LINK << 10) | 2
    or ecx, [rdi + R_CYCLE]
    mov [rbx + 255 * 16 + 12], ecx
    xor dword [rdi + R_CYCLE], 1
    xor r8d, r8d
.store:
    mov [rdi + R_IDX], r8d
    sfence
    pop r8
    pop rbx
    ret

; xhci_next_event(R15 = controller) -> CF = 0 and the TRB copied to
; XC_EVENT if one was waiting; CF = 1 if the ring is empty
xhci_next_event:
    push rax
    push rcx
    push rdx
    mov ecx, [r15 + XC_EVT + R_IDX]
    mov rax, rcx
    shl rax, 4
    add rax, [r15 + XC_EVT + R_VIRT]
    mov edx, [rax + 12]
    and edx, 1
    cmp edx, [r15 + XC_EVT + R_CYCLE]
    jne .empty
    mov rdx, [rax]
    mov [r15 + XC_EVENT], rdx
    mov rdx, [rax + 8]
    mov [r15 + XC_EVENT + 8], rdx
    inc ecx
    cmp ecx, 256
    jb .advance
    xor ecx, ecx
    xor dword [r15 + XC_EVT + R_CYCLE], 1
.advance:
    mov [r15 + XC_EVT + R_IDX], ecx
    mov rax, rcx                        ; tell the controller how far we got
    shl rax, 4
    add rax, [r15 + XC_EVT + R_PHYS]
    or rax, 8                           ; clear Event Handler Busy
    mov rdx, [r15 + XC_RT]
    mov [rdx + 0x38], eax
    shr rax, 32
    mov [rdx + 0x3C], eax
    clc
    jmp .out
.empty:
    stc
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; xhci_wait(EDI = event type, ESI = slot or 0, EDX = endpoint DCI or 0)
; -> EAX = completion code; CF = 1 on timeout. Other events that arrive
; meanwhile are dispatched. Interrupts must be off.
xhci_wait:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov edi, 1000
    call usb_deadline
    mov rbx, rax
.poll:
    call xhci_next_event
    jc .idle
    mov eax, [r15 + XC_EVENT + 12]
    shr eax, 10
    and eax, 0x3F
    cmp eax, r12d
    jne .other
    test r13d, r13d
    jz .slot_ok
    mov eax, [r15 + XC_EVENT + 12]
    shr eax, 24
    cmp eax, r13d
    jne .other
.slot_ok:
    test r14d, r14d
    jz .match
    mov eax, [r15 + XC_EVENT + 12]
    shr eax, 16
    and eax, 0x1F
    cmp eax, r14d
    jne .other
.match:
    mov eax, [r15 + XC_EVENT + 8]
    shr eax, 24
    clc
    jmp .out
.other:
    call usb_dispatch
    jmp .poll
.idle:
    pause
    mov rsi, rbx
    call usb_expired
    jnc .poll
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; xhci_command(RSI = parameter, EDX = status, ECX = control) -> EAX = slot id
; from the completion; CF = 1 on failure. Preserves others.
xhci_command:
    push rcx
    push rdx
    push rsi
    push rdi
    pushfq
    cli
    lea rdi, [r15 + XC_CMD]
    call ring_push
    mov rax, [r15 + XC_DB]
    mov dword [rax], 0                  ; doorbell 0: the command ring
    mov edi, TRB_EV_COMMAND
    xor esi, esi
    xor edx, edx
    call xhci_wait
    jc .fail
    cmp eax, CC_SUCCESS
    jne .fail
    mov eax, [r15 + XC_EVENT + 12]
    shr eax, 24
    popfq
    clc
    jmp .out
.fail:
    popfq
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  usb_init: every xHCI controller PCI reported, then whatever is plugged in
; -----------------------------------------------------------------------------
usb_init:
    push rbx
    push r12
    push r15
    xor r12d, r12d
    lea rbx, [pci_devices]
.next:
    cmp r12d, [pci_count]
    jae .enumerate
    cmp byte [rbx + PE_CLASS], 0x0C
    jne .skip
    cmp byte [rbx + PE_SUBCLASS], 0x03
    jne .skip
    cmp byte [rbx + PE_PROGIF], 0x30
    jne .skip
    mov eax, [xhci_count]
    cmp eax, MAX_XHCI
    jae .enumerate
    imul r15, rax, XC_SIZE
    lea rax, [xhci_ctrl]
    add r15, rax
    mov rdi, rbx
    call xhci_init
    jc .bad
    inc dword [xhci_count]
    cmp dword [r15 + XC_MSI], 0
    jne .interrupts
    mov byte [usb_poll_needed], 1
.interrupts:
    movzx eax, word [rbx + PE_VENDOR]
    movzx ecx, word [rbx + PE_DEVICE]
    mov edx, [r15 + XC_PORTS]
    mov esi, [r15 + XC_MSI]
    lea rdi, [usb_irq_names]
    mov rsi, [rdi + rsi * 8]
    KLOG "usb: xHCI %04x:%04x, %u ports, %s", rax, rcx, rdx, rsi
    mov ecx, 1                          ; look at every port
.mark:
    cmp ecx, [r15 + XC_PORTS]
    ja .skip
    bts [r15 + XC_PORTCHG], ecx
    inc ecx
    jmp .mark
.bad:
    KLOG "usb: xHCI controller at %x did not start", qword [xhci_bar]
.skip:
    add rbx, PCI_ENTRY
    inc r12d
    jmp .next
.enumerate:
    mov byte [usb_pending], 1
    call usb_service
    mov byte [usb_hotplug], 1
    xor ecx, ecx
    lea rax, [usb_devs]
    xor edx, edx
.count:
    cmp edx, MAX_DEV
    jae .counted
    cmp dword [rax + DV_STATE], DS_RUNNING
    jne .count_next
    inc ecx
.count_next:
    add rax, DV_SIZE
    inc edx
    jmp .count
.counted:
    mov eax, [xhci_count]
    KLOG "usb: %u controller(s), %u device(s)", rax, rcx
    pop r15
    pop r12
    pop rbx
    ret

; xhci_init(RDI = PCI entry, R15 = controller struct) -> CF = 1 if unusable
xhci_init:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    movzx edi, byte [rbx + PE_BUS]      ; bdf for config access
    shl edi, 8
    movzx eax, byte [rbx + PE_DEV]
    shl eax, 3
    or edi, eax
    movzx eax, byte [rbx + PE_FN]
    or edi, eax
    mov r14d, edi
    mov [r15 + XC_BDF], edi
    mov dword [r15 + XC_MSI], 0
    cmp qword [usb_domain], 0           ; its DMA, through the USB domain
    jne .domain
    lea rdi, [str_usb_domain]
    call iommu_domain_new
    mov [usb_domain], rax
.domain:
    mov rdi, [usb_domain]
    mov esi, r14d
    call iommu_attach
    mov edi, r14d
    mov esi, 0x10                       ; BAR0, maybe 64-bit
    call pci_read32
    mov r12d, eax
    and r12d, ~0xF
    mov ecx, eax
    and ecx, 6
    cmp ecx, 4
    jne .bar_done
    mov esi, 0x14
    call pci_read32
    shl rax, 32
    or r12, rax
.bar_done:
    mov [xhci_bar], r12
    test r12, r12
    jz .unusable
    mov esi, 0x04                       ; memory decode + bus mastering
    call pci_read32
    or eax, 6 | (1 << 10)               ; legacy INTx stays off
    mov edx, eax
    mov esi, 0x04
    call pci_write32
    mov rdi, r12
    mov esi, 0x10000
    call mmio_map
    test rax, rax
    jz .unusable
    mov [r15 + XC_MMIO], rax
    mov r13, rax

    movzx ecx, byte [r13]               ; register blocks
    lea rax, [r13 + rcx]
    mov [r15 + XC_OP], rax
    mov eax, [r13 + 0x18]
    and eax, ~0x1F
    add rax, r13
    mov [r15 + XC_RT], rax
    mov eax, [r13 + 0x14]
    and eax, ~3
    add rax, r13
    mov [r15 + XC_DB], rax
    mov eax, [r13 + 0x04]               ; HCSPARAMS1
    movzx ecx, al
    cmp ecx, MAX_DEV                    ; we need few slots
    jbe .slots_ok
    mov ecx, MAX_DEV
.slots_ok:
    mov [r15 + XC_SLOTS], ecx
    shr eax, 24
    mov [r15 + XC_PORTS], eax
    mov eax, [r13 + 0x10]               ; HCCPARAMS1
    mov ecx, 32
    test eax, 4
    jz .ctx_ok
    mov ecx, 64
.ctx_ok:
    mov [r15 + XC_CTXSZ], ecx
    mov ecx, eax
    and ecx, 1
    mov [r15 + XC_AC64], ecx

    call xhci_take_ownership
    call xhci_reset
    jc .unusable
    call xhci_setup_rings
    call xhci_msi
    call xhci_start
    jc .unusable
    clc
    jmp .out
.unusable:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; xhci_take_ownership: the firmware lets go (USB legacy support capability)
xhci_take_ownership:
    push rbx
    mov rbx, [r15 + XC_MMIO]
    mov eax, [rbx + 0x10]
    shr eax, 16
    jz .done
    shl eax, 2
    add rbx, rax
.cap:
    mov eax, [rbx]
    cmp al, 1
    je .legacy
    shr eax, 8
    and eax, 0xFF
    jz .done
    shl eax, 2
    add rbx, rax
    jmp .cap
.legacy:
    or eax, 1 << 24                     ; OS owned
    mov [rbx], eax
    mov edi, 1000
    call usb_deadline
    mov rsi, rax
.wait:
    test dword [rbx], 1 << 16           ; BIOS still owns it?
    jz .owned
    call usb_expired
    jc .force
    pause
    jmp .wait
.force:
    and dword [rbx], ~(1 << 16)
.owned:
    mov eax, [rbx + 4]                  ; no more SMIs from this controller
    and eax, ~0xE011
    or eax, 0xE0000000
    mov [rbx + 4], eax
.done:
    pop rbx
    ret

; xhci_reset: stop, reset, wait until ready. CF = 1 on timeout.
xhci_reset:
    push rbx
    mov rbx, [r15 + XC_OP]
    and dword [rbx], ~1                 ; run/stop = 0
    mov edi, 100
    call usb_deadline
    mov rsi, rax
.halt:
    test dword [rbx + 4], 1             ; halted
    jnz .halted
    call usb_expired
    jc .halted                          ; reset anyway
    pause
    jmp .halt
.halted:
    or dword [rbx], 2                   ; host controller reset
    mov edi, 2
    call delay_ms_usb
    mov edi, 1000
    call usb_deadline
    mov rsi, rax
.reset:
    test dword [rbx], 2
    jnz .busy
    test dword [rbx + 4], 1 << 11       ; controller not ready
    jz .ready
.busy:
    call usb_expired
    jc .timeout
    pause
    jmp .reset
.ready:
    clc
    pop rbx
    ret
.timeout:
    stc
    pop rbx
    ret

delay_ms_usb:
    push rdi
    imul edi, edi, 1000
    call delay_us
    pop rdi
    ret

; xhci_setup_rings: device context array, scratchpads, command and event rings
xhci_setup_rings:
    push rbx
    push r12
    mov rbx, [r15 + XC_OP]
    mov eax, [r15 + XC_SLOTS]
    mov [rbx + 0x38], eax               ; CONFIG: slots enabled
    call usb_alloc_page                 ; DCBAA
    mov [r15 + XC_DCBAA], rdx
    mov r12, rax
    mov rcx, [r15 + XC_MMIO]            ; scratchpad buffers the controller wants
    mov eax, [rcx + 0x08]
    mov ecx, eax
    shr ecx, 27                         ; low 5 bits
    shr eax, 21
    and eax, 0x1F
    shl eax, 5
    or ecx, eax
    jz .no_scratch
    push rcx
    call usb_alloc_page                 ; the pointer array
    mov rdi, [r15 + XC_DCBAA]
    mov [rdi], rax
    mov rdi, rdx
    pop rcx
.scratch:
    push rdi
    call usb_alloc_page
    pop rdi
    mov [rdi], rax
    add rdi, 8
    dec ecx
    jnz .scratch
.no_scratch:
    mov eax, r12d                       ; DCBAAP
    mov [rbx + 0x30], eax
    mov rax, r12
    shr rax, 32
    mov [rbx + 0x34], eax

    lea rdi, [r15 + XC_CMD]             ; command ring
    call ring_init
    mov rax, [r15 + XC_CMD + R_PHYS]
    or rax, 1                           ; ring cycle state
    mov [rbx + 0x18], eax
    shr rax, 32
    mov [rbx + 0x1C], eax

    call usb_alloc_page                 ; event ring: one 256-TRB segment
    mov [r15 + XC_EVT + R_PHYS], rax
    mov [r15 + XC_EVT + R_VIRT], rdx
    mov dword [r15 + XC_EVT + R_IDX], 0
    mov dword [r15 + XC_EVT + R_CYCLE], 1
    mov r12, rax
    call usb_alloc_page                 ; its segment table
    mov [rdx], r12
    mov dword [rdx + 8], 256
    mov rcx, [r15 + XC_RT]
    mov dword [rcx + 0x20], 1           ; IMAN: interrupts off until MSI is set up
    mov dword [rcx + 0x28], 1           ; ERSTSZ
    mov edx, r12d                       ; ERDP
    mov [rcx + 0x38], edx
    mov rdx, r12
    shr rdx, 32
    mov [rcx + 0x3C], edx
    mov [rcx + 0x30], eax               ; ERSTBA last
    shr rax, 32
    mov [rcx + 0x34], eax
    pop r12
    pop rbx
    ret

; xhci_msi: point the controller's MSI-X or MSI at the BSP, enable interrupter 0
xhci_msi:
    mov edi, [r15 + XC_BDF]
    mov esi, VEC_USB
    call pci_msi
    mov [r15 + XC_MSI], eax
    test eax, eax
    jz .out
    mov edi, VEC_USB
    lea rsi, [usb_irq]
    call irq_register
    mov rcx, [r15 + XC_RT]
    mov dword [rcx + 0x24], 160         ; moderate to 40 us
    mov dword [rcx + 0x20], 3           ; IMAN: clear pending, enable
    mov rcx, [r15 + XC_OP]
    or dword [rcx], 1 << 2              ; USBCMD: interrupter enable
.out:
    ret

; xhci_start: run, power the ports, let devices connect. CF = 1 on timeout.
xhci_start:
    push rbx
    mov rbx, [r15 + XC_OP]
    or dword [rbx], 1                   ; run
    mov edi, 100
    call usb_deadline
    mov rsi, rax
.run:
    test dword [rbx + 4], 1
    jz .running
    call usb_expired
    jc .fail
    pause
    jmp .run
.running:
    mov rcx, [r15 + XC_MMIO]            ; port power switching?
    test dword [rcx + 0x10], 1 << 3
    jz .settle
    xor ecx, ecx
.power:
    cmp ecx, [r15 + XC_PORTS]
    jae .powered
    mov rdx, rcx
    shl rdx, 4
    add rdx, rbx
    mov eax, [rdx + 0x400]
    and eax, PORTSC_KEEP
    or eax, 1 << 9
    mov [rdx + 0x400], eax
    inc ecx
    jmp .power
.powered:
    mov edi, 20
    call delay_ms_usb
.settle:
    mov edi, 250                        ; devices reconnect after the reset
    call delay_ms_usb
    clc
    pop rbx
    ret
.fail:
    stc
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Runtime: usb_poll from the main loop; usb_dispatch for each event
; -----------------------------------------------------------------------------
usb_poll:
    cmp dword [xhci_count], 0
    je .out
    pushfq
    cli
    call usb_drain
    popfq
    call hid_key_repeat
.out:
    ret

; usb_irq: the MSI. Acknowledge each interrupter, then take its events.
usb_irq:
    xor ecx, ecx
.ack:
    cmp ecx, [xhci_count]
    jae usb_drain
    imul rax, rcx, XC_SIZE
    lea rdx, [xhci_ctrl]
    add rax, rdx
    mov rdx, [rax + XC_OP]
    mov dword [rdx + 4], 1 << 3         ; USBSTS: event interrupt
    mov rdx, [rax + XC_RT]
    mov dword [rdx + 0x20], 3           ; IMAN: pending (RW1C), stay enabled
    inc ecx
    jmp .ack

; usb_drain: every controller's event ring. Interrupts off.
usb_drain:
    push r15
    push r12
    xor r12d, r12d
.controller:
    cmp r12d, [xhci_count]
    jae .repeat
    imul r15, r12, XC_SIZE
    lea rax, [xhci_ctrl]
    add r15, rax
.drain:
    call xhci_next_event
    jc .next
    call usb_dispatch
    jmp .drain
.next:
    inc r12d
    jmp .controller
.repeat:
    pop r12
    pop r15
    ret

section .rodata
str_usb_oom:    db 'Out of memory for USB structures', 0
str_ls:         db 'low speed', 0
str_fs:         db 'full speed', 0
str_hs:         db 'high speed', 0
str_ss:         db 'SuperSpeed', 0
str_unk_speed:  db 'unknown speed', 0
str_polled:     db 'polled', 0
str_msi:        db 'MSI', 0
str_msix:       db 'MSI-X', 0
align 8
usb_irq_names:  dq str_polled, str_msi, str_msix
usb_speed_names:
    dq str_unk_speed, str_fs, str_ls, str_hs, str_ss, str_ss, str_ss, str_ss
    dq str_unk_speed, str_unk_speed, str_unk_speed, str_unk_speed
    dq str_unk_speed, str_unk_speed, str_unk_speed, str_unk_speed
section .data
usb_poll_needed: db 0                   ; a controller without MSI: poll often

section .rodata
str_usb_domain: db 'usb', 0

section .bss
alignb 8
usb_domain:     resq 1                  ; every controller's DMA domain
alignb 8
xhci_count:     resd 1
alignb 8
xhci_bar:       resq 1
xhci_ctrl:      resb MAX_XHCI * XC_SIZE
