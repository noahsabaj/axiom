; =============================================================================
;  usbdev.asm - USB devices on any xHCI controller: enumeration (root ports
;  and hubs), control transfers, endpoints, hot-plug, and binding interfaces
;  to class drivers (usbhub.asm, hid.asm, usbmsc.asm, bt.asm).
;
;  Enumeration and hot-plug run in usb_service, from the main loop with
;  interrupts off, using synchronous control transfers: one control transfer
;  per device at a time, so the first EP0 event for a slot is always ours.
;  Endpoint completions run in usb_dispatch, from the MSI handler (or the
;  main loop's poll), also with interrupts off.
;
;  Registers by convention: R15 = controller, RBX = device, R14 = endpoint.
; =============================================================================

section .text

; -----------------------------------------------------------------------------
;  Small helpers
; -----------------------------------------------------------------------------

; dev_alloc_page(RBX = device) -> RAX = physical, RDX = mapped, zeroed.
; The page is freed when the device goes away. Preserves others.
dev_alloc_page:
    call usb_alloc_page
    push rcx
    mov ecx, [rbx + DV_NPAGES]
    cmp ecx, DEV_PAGES
    jae .untracked
    mov [rbx + DV_PAGES + rcx * 8], rax
    inc dword [rbx + DV_NPAGES]
.untracked:
    pop rcx
    ret

; dev_ring_init(RDI = ring, RBX = device): a transfer ring in a device page
dev_ring_init:
    push rax
    push rdx
    call dev_alloc_page
    mov [rdi + R_PHYS], rax
    mov [rdi + R_VIRT], rdx
    mov dword [rdi + R_IDX], 0
    mov dword [rdi + R_CYCLE], 1
    mov [rdx + 255 * 16], rax           ; link TRB back to the start
    mov dword [rdx + 255 * 16 + 12], (TRB_LINK << 10) | 2
    pop rdx
    pop rax
    ret

; usb_dev_ptr(EAX = device index + 1) -> RAX = device record (0 if none)
usb_dev_ptr:
    test eax, eax
    jz .out
    dec eax
    imul eax, eax, DV_SIZE
    push rdx
    lea rdx, [usb_devs]
    add rax, rdx
    pop rdx
.out:
    ret

; -----------------------------------------------------------------------------
;  usb_control(RBX = device, RSI = setup packet, RDX = buffer physical,
;  ECX = length) -> CF = 1 on failure (EP0 is recovered), EAX = completion
;  Synchronous. Interrupts are off while it runs. Preserves others.
; -----------------------------------------------------------------------------
usb_control:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r15
    pushfq
    cli
    mov r15, [rbx + DV_XC]
    mov r12, rdx
    mov r13d, ecx
    mov eax, 0                          ; transfer type: no data / OUT / IN
    test r13d, r13d
    jz .trt
    mov eax, 2 << 16
    test sil, 0x80
    jz .trt
    mov eax, 3 << 16
.trt:
    lea rdi, [rbx + DV_EP0]
    mov ecx, (TRB_SETUP << 10) | (1 << 6)   ; immediate data
    or ecx, eax
    mov edx, 8
    push rsi
    call ring_push
    pop rsi
    test r13d, r13d
    jz .status
    push rsi
    mov ecx, TRB_DATA << 10
    test sil, 0x80
    jz .data_out
    or ecx, 1 << 16                     ; IN
.data_out:
    mov rsi, r12
    mov edx, r13d
    call ring_push
    pop rsi
.status:
    mov ecx, (TRB_STATUS << 10) | (1 << 5) | (1 << 16)  ; IN status, interrupt
    test r13d, r13d
    jz .push_status
    test sil, 0x80
    jz .push_status
    and ecx, ~(1 << 16)                 ; OUT status after IN data
.push_status:
    xor esi, esi
    xor edx, edx
    call ring_push
    mov rax, [r15 + XC_DB]
    mov ecx, [rbx + DV_SLOT]
    mov dword [rax + rcx * 4], 1        ; EP0
    mov edi, TRB_EV_TRANSFER
    mov esi, [rbx + DV_SLOT]
    mov edx, 1
    call xhci_wait
    jc .recover
    cmp eax, CC_SUCCESS
    je .ok
    cmp eax, CC_SHORT
    je .ok
.recover:
    push rax
    mov edi, 1
    lea rsi, [rbx + DV_EP0]
    call usb_reset_ep
    pop rax
    popfq
    stc
    jmp .out
.ok:
    popfq
    clc
.out:
    pop r15
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; usb_get_desc(RBX = device, ESI = type << 8 | index, EDX = length) into
; DV_BUF -> CF on failure. Preserves others.
usb_get_desc:
    push rcx
    push rdx
    push rsi
    mov ecx, edx
    mov rax, rcx
    shl rax, 48
    shl rsi, 16
    or rsi, rax
    or rsi, 0x0680                      ; GET_DESCRIPTOR, device to host
    mov rdx, [rbx + DV_BUFP]
    call usb_control
    pop rsi
    pop rdx
    pop rcx
    ret

; usb_reset_ep(RBX = device, EDI = DCI, RSI = its ring): recover a halted
; (or stuck) endpoint and point it at the ring's enqueue position
usb_reset_ep:
    push rcx
    push rdx
    push rsi
    push r12
    push r15
    mov r15, [rbx + DV_XC]
    mov r12, rsi
    mov ecx, [rbx + DV_SLOT]
    shl ecx, 24
    mov eax, edi
    shl eax, 16
    or ecx, eax
    push rcx
    or ecx, TRB_RESET_EP << 10
    xor esi, esi
    xor edx, edx
    call xhci_command                   ; fails unless halted
    pop rcx
    jnc .dequeue
    push rcx
    or ecx, TRB_STOP_EP << 10
    xor esi, esi
    xor edx, edx
    call xhci_command
    pop rcx
.dequeue:
    mov eax, [r12 + R_IDX]
    shl rax, 4
    add rax, [r12 + R_PHYS]
    or eax, [r12 + R_CYCLE]
    mov rsi, rax
    or ecx, TRB_SET_DEQ << 10
    xor edx, edx
    call xhci_command
    pop r15
    pop r12
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Contexts
; -----------------------------------------------------------------------------

; usb_fill_slot(RBX = device, RDI = slot context, ECX = context entries)
usb_fill_slot:
    mov eax, [rbx + DV_SPEED]
    shl eax, 20
    or eax, [rbx + DV_ROUTE]
    shl ecx, 27
    or eax, ecx
    test dword [rbx + DV_HUBFLAGS], HUB_IS
    jz .dw0
    or eax, 1 << 26
.dw0:
    mov [rdi], eax
    mov eax, [rbx + DV_ROOTPORT]
    shl eax, 16
    test dword [rbx + DV_HUBFLAGS], HUB_IS
    jz .dw1
    mov ecx, [rbx + DV_HUBPORTS]
    shl ecx, 24
    or eax, ecx
.dw1:
    mov [rdi + 4], eax
    mov eax, [rbx + DV_TTPORT]
    shl eax, 8
    or eax, [rbx + DV_TTSLOT]
    mov ecx, [rbx + DV_HUBFLAGS]
    shr ecx, 2
    and ecx, 3
    shl ecx, 16                         ; TT think time
    or eax, ecx
    mov [rdi + 8], eax
    mov dword [rdi + 12], 0
    ret

; usb_fill_ep0(RBX = device, RDI = endpoint context)
usb_fill_ep0:
    mov eax, [rbx + DV_MPS0]
    shl eax, 16
    or eax, (3 << 1) | (4 << 3)         ; 3 retries, control
    mov [rdi + 4], eax
    mov rax, [rbx + DV_EP0 + R_PHYS]
    or rax, 1
    mov [rdi + 8], rax
    mov dword [rdi + 16], 8
    ret

; usb_clear_input(RBX = device) -> RDI = input context, zeroed
usb_clear_input:
    push rax
    push rcx
    mov rdi, [rbx + DV_IN]
    push rdi
    mov ecx, 4096 / 8
    xor eax, eax
    rep stosq
    pop rdi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  usb_attach(R15 = controller, EDI = root port, ESI = speed, EDX = route,
;  ECX = depth, R8D = parent device index + 1 (0 on a root port), R9D = port
;  on the parent, R10D = TT hub slot, R11D = TT port)
;  -> RBX = device, CF = 1 if it could not be set up
; -----------------------------------------------------------------------------
usb_attach:
    push r12
    push r13
    push r14
    lea rbx, [usb_devs]
    xor eax, eax
.find:
    cmp eax, MAX_DEV
    jae .full
    cmp dword [rbx + DV_STATE], 0
    je .found
    add rbx, DV_SIZE
    inc eax
    jmp .find
.full:
    KLOG "usb: too many devices"
    stc
    jmp .out
.found:
    push rdi
    push rcx
    push rax
    mov rdi, rbx
    mov ecx, DV_SIZE
    xor eax, eax
    rep stosb
    pop rax
    pop rcx
    pop rdi
    mov [rbx + DV_INDEX], eax
    mov [rbx + DV_XC], r15
    mov [rbx + DV_ROOTPORT], edi
    mov [rbx + DV_SPEED], esi
    mov [rbx + DV_ROUTE], edx
    mov [rbx + DV_DEPTH], ecx
    mov [rbx + DV_PARENT], r8d
    mov [rbx + DV_PPORT], r9d
    mov [rbx + DV_TTSLOT], r10d
    mov [rbx + DV_TTPORT], r11d
    mov dword [rbx + DV_STATE], DS_ADDRESSING
    mov eax, 8                          ; first guess at the control packet size
    cmp esi, SPEED_HS
    jne .not_hs
    mov eax, 64
.not_hs:
    cmp esi, SPEED_SS
    jb .mps
    mov eax, 512
.mps:
    mov [rbx + DV_MPS0], eax

    xor esi, esi                        ; Enable Slot
    xor edx, edx
    mov ecx, TRB_ENABLE_SLOT << 10
    call xhci_command
    jc .no_slot
    mov [rbx + DV_SLOT], eax
    mov ecx, [rbx + DV_INDEX]
    inc ecx
    mov [r15 + XC_SLOTDEV + rax], cl
    call dev_alloc_page                 ; output context, in the DCBAA
    mov [rbx + DV_OUT], rdx
    mov rcx, [r15 + XC_DCBAA]
    mov edx, [rbx + DV_SLOT]
    mov [rcx + rdx * 8], rax
    call dev_alloc_page
    mov [rbx + DV_INP], rax
    mov [rbx + DV_IN], rdx
    call dev_alloc_page
    mov [rbx + DV_BUFP], rax
    mov [rbx + DV_BUF], rdx
    call dev_alloc_page
    mov [rbx + DV_CFGP], rax
    mov [rbx + DV_CFG], rdx
    lea rdi, [rbx + DV_EP0]
    call dev_ring_init

    call usb_clear_input                ; Address Device
    mov dword [rdi + 4], 3              ; add slot + EP0
    mov r12d, [r15 + XC_CTXSZ]
    add rdi, r12
    mov ecx, 1
    call usb_fill_slot
    add rdi, r12
    call usb_fill_ep0
    mov rsi, [rbx + DV_INP]
    xor edx, edx
    mov ecx, [rbx + DV_SLOT]
    shl ecx, 24
    or ecx, TRB_ADDRESS << 10
    call xhci_command
    jc .failed
    mov edi, 3
    call delay_ms_usb

    mov esi, 0x0100                     ; device descriptor, first 8 bytes
    mov edx, 8
    call usb_get_desc
    jc .failed
    mov rdi, [rbx + DV_BUF]
    movzx eax, byte [rdi + 7]           ; real control packet size
    cmp dword [rbx + DV_SPEED], SPEED_SS
    jb .mps_bytes
    mov ecx, eax
    mov eax, 1
    shl eax, cl
.mps_bytes:
    test eax, eax
    jz .full_desc
    cmp eax, [rbx + DV_MPS0]
    je .full_desc
    mov [rbx + DV_MPS0], eax            ; Evaluate Context with the right size
    call usb_clear_input
    mov dword [rdi + 4], 2
    mov r12d, [r15 + XC_CTXSZ]
    lea rdi, [rdi + r12 * 2]
    call usb_fill_ep0
    mov rsi, [rbx + DV_INP]
    xor edx, edx
    mov ecx, [rbx + DV_SLOT]
    shl ecx, 24
    or ecx, TRB_EVALUATE << 10
    call xhci_command
    jc .failed
.full_desc:
    mov esi, 0x0100
    mov edx, 18
    call usb_get_desc
    jc .failed
    mov rdi, [rbx + DV_BUF]
    mov eax, [rdi + 8]                  ; vendor, product
    mov [rbx + DV_VID], eax
    mov eax, [rdi + 4]                  ; class, subclass, protocol
    and eax, 0xFFFFFF
    mov [rbx + DV_CLASS], eax
    movzx eax, byte [rdi + 15]          ; product string
    movzx r13d, byte [rdi + 14]         ; maker string
    push rax
    mov esi, 0x0200                     ; configuration descriptor
    mov edx, 9
    call usb_get_desc
    pop rax
    jc .failed
    mov rdi, [rbx + DV_BUF]
    movzx ecx, word [rdi + 2]
    cmp ecx, 4096
    jbe .cfg_len
    mov ecx, 4096
.cfg_len:
    mov [rbx + DV_CFGLEN], ecx
    movzx r14d, byte [rdi + 5]          ; its value, for SET_CONFIGURATION
    push rax
    mov rsi, 0x0000000002000680
    mov rdx, rcx
    shl rdx, 48
    or rsi, rdx
    mov rdx, [rbx + DV_CFGP]
    call usb_control
    pop rax
    jc .failed
    test eax, eax                       ; name from the product string
    jnz .name
    mov eax, r13d
.name:
    call usb_read_name
    mov rsi, r14                        ; SET_CONFIGURATION
    shl rsi, 16
    or rsi, 0x0900
    xor edx, edx
    xor ecx, ecx
    call usb_control
    jc .failed
    mov dword [rbx + DV_STATE], DS_CONFIGURING
    call usb_log_device

    call usb_bind_all                   ; drivers claim interfaces, add endpoints
    call usb_configure
    jc .failed
    mov dword [rbx + DV_STATE], DS_RUNNING
    call usb_start_binds
    clc
    jmp .out
.failed:
    mov eax, [rbx + DV_ROOTPORT]
    KLOG "usb: device on port %u did not set up", rax
    call usb_teardown
    stc
    jmp .out
.no_slot:
    mov dword [rbx + DV_STATE], DS_FREE
    stc
.out:
    pop r14
    pop r13
    pop r12
    ret

; usb_read_name(RBX = device, EAX = string index): ASCII name into DV_NAME
usb_read_name:
    push rcx
    push rdx
    push rsi
    push rdi
    mov byte [rbx + DV_NAME], 0
    test eax, eax
    jz .out
    mov esi, 0x0300
    or esi, eax
    mov rcx, 0x0409                     ; US English
    shl rcx, 32
    mov rdx, 255
    shl rdx, 48
    or rcx, rdx
    shl rsi, 16
    or rsi, rcx
    or rsi, 0x0680
    mov rdx, [rbx + DV_BUFP]
    mov ecx, 255
    call usb_control
    jc .out
    mov rsi, [rbx + DV_BUF]
    movzx ecx, byte [rsi]
    shr ecx, 1
    dec ecx                             ; UTF-16 units after the header
    jle .out
    cmp ecx, DV_NAME_LEN - 1
    jbe .copy_len
    mov ecx, DV_NAME_LEN - 1
.copy_len:
    lea rdi, [rbx + DV_NAME]
    add rsi, 2
.copy:
    mov ax, [rsi]
    cmp ax, 32
    jb .bad
    cmp ax, 127
    jb .ascii
.bad:
    mov ax, '?'
.ascii:
    mov [rdi], al
    inc rdi
    add rsi, 2
    dec ecx
    jnz .copy
    mov byte [rdi], 0
.trim:                                  ; drop trailing spaces
    lea rax, [rbx + DV_NAME]
    cmp rdi, rax
    je .out
    cmp byte [rdi - 1], ' '
    jne .out
    dec rdi
    mov byte [rdi], 0
    jmp .trim
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; usb_path(RBX = device, RDI = buffer): "10" or "10.3.1"
usb_path:
    push rbx
    push rcx
    push rdx
    push r12
    mov r12, rdi
    mov eax, [rbx + DV_ROOTPORT]
    SPRINTF r12, "%u", rax
    add r12, rax
    mov edx, [rbx + DV_ROUTE]
    mov ecx, [rbx + DV_DEPTH]
.tier:
    test ecx, ecx
    jz .done
    mov eax, edx
    and eax, 0xF
    shr edx, 4
    push rcx
    push rdx
    SPRINTF r12, ".%u", rax
    pop rdx
    pop rcx
    add r12, rax
    dec ecx
    jmp .tier
.done:
    mov rax, r12
    sub rax, rdi
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; usb_log_device(RBX = device)
usb_log_device:
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [usb_path_buf]
    call usb_path
    mov eax, [rbx + DV_SPEED]
    lea rcx, [usb_speed_names]
    mov rcx, [rcx + rax * 8]
    lea rsi, [rbx + DV_NAME]
    cmp byte [rsi], 0
    jne .named
    lea rsi, [str_usb_unnamed]
.named:
    movzx eax, word [rbx + DV_VID]
    movzx edx, word [rbx + DV_PID]
    lea rdi, [usb_path_buf]
    KLOG "usb: %s (%04x:%04x) on port %s, %s", rsi, rax, rdx, rdi, rcx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Driver binding
; -----------------------------------------------------------------------------

; usb_bind_all(RBX = device): offer every interface (alternate setting 0) to
; the class drivers
usb_bind_all:
    push rsi
    push rdi
    push r12
    mov rsi, [rbx + DV_CFG]
    mov edi, [rbx + DV_CFGLEN]
    add rdi, rsi                        ; end
.next:
    lea rax, [rsi + 2]
    cmp rax, rdi
    ja .done
    movzx eax, byte [rsi]
    cmp eax, 2
    jb .done
    cmp byte [rsi + 1], 4               ; interface
    jne .advance
    cmp byte [rsi + 3], 0               ; alternate setting 0 only
    jne .advance
    push rsi
    push rdi
    call hub_probe
    jnc .claimed
    mov rsi, [rsp + 8]
    mov rdi, [rsp]
    call hid_probe
    jnc .claimed
    mov rsi, [rsp + 8]
    mov rdi, [rsp]
    call msc_probe
    jnc .claimed
    mov rsi, [rsp + 8]
    mov rdi, [rsp]
    call bt_probe
.claimed:
    pop rdi
    pop rsi
.advance:
    movzx eax, byte [rsi]
    add rsi, rax
    jmp .next
.done:
    pop r12
    pop rdi
    pop rsi
    ret

; usb_find_desc(RSI = interface descriptor, RDI = end of the configuration,
; DL = descriptor type, ECX = which one (0 = first)) -> RAX = descriptor;
; CF = 1 if the interface has no such descriptor. Preserves others.
usb_find_desc:
    push rsi
    push rcx
.walk:
    movzx eax, byte [rsi]
    test eax, eax
    jz .none
    add rsi, rax
    lea rax, [rsi + 2]
    cmp rax, rdi
    ja .none
    cmp byte [rsi], 2
    jb .none
    cmp byte [rsi + 1], 4               ; the next interface: stop
    je .none
    cmp [rsi + 1], dl
    jne .walk
    test ecx, ecx
    jz .found
    dec ecx
    jmp .walk
.found:
    mov rax, rsi
    pop rcx
    pop rsi
    clc
    ret
.none:
    pop rcx
    pop rsi
    stc
    ret

; usb_bind(RBX = device, RSI = start function, RDX = detach function,
; RCX = driver context). Start runs once the endpoints are configured.
usb_bind:
    push rdi
    xor eax, eax
.slot:
    cmp eax, MAX_BIND
    jae .full
    imul edi, eax, BIND_SIZE
    cmp qword [rbx + DV_BINDS + rdi + BIND_CTX], 0
    jne .used
    cmp qword [rbx + DV_BINDS + rdi + BIND_START], 0
    je .take
.used:
    inc eax
    jmp .slot
.take:
    mov [rbx + DV_BINDS + rdi + BIND_START], rsi
    mov [rbx + DV_BINDS + rdi + BIND_DETACH], rdx
    mov [rbx + DV_BINDS + rdi + BIND_CTX], rcx
.full:
    pop rdi
    ret

; usb_start_binds(RBX = device): call each driver's start function
usb_start_binds:
    push r12
    xor r12d, r12d
.next:
    cmp r12d, MAX_BIND
    jae .done
    imul eax, r12d, BIND_SIZE
    mov rcx, [rbx + DV_BINDS + rax + BIND_START]
    test rcx, rcx
    jz .skip
    mov rsi, [rbx + DV_BINDS + rax + BIND_CTX]
    call rcx
.skip:
    inc r12d
    jmp .next
.done:
    pop r12
    ret

; -----------------------------------------------------------------------------
;  Endpoints
; -----------------------------------------------------------------------------

; usb_ep_create(RBX = device, RSI = endpoint descriptor, RDX = completion
; handler, RCX = driver context, R8D = buffer bytes (0: no buffer))
; -> R14 = endpoint, CF = 1 on failure. Preserves others.
;
; Handlers run with interrupts off: RBX = device, R14 = endpoint,
; EAX = completion code, EDX = bytes not transferred. They may requeue.
usb_ep_create:
    push rax
    push rcx
    push rdx
    push rdi
    lea r14, [usb_eps]
    xor eax, eax
.find:
    cmp eax, MAX_EP
    jae .fail
    cmp dword [r14 + EP_STATE], 0
    je .found
    add r14, EP_SIZE
    inc eax
    jmp .find
.found:
    push rax
    push rcx
    mov rdi, r14
    mov ecx, EP_SIZE
    xor eax, eax
    rep stosb
    pop rcx
    pop rax
    mov [r14 + EP_INDEX], eax
    mov [r14 + EP_DEV], rbx
    mov [r14 + EP_HANDLER], rdx
    mov [r14 + EP_CTX], rcx
    movzx eax, byte [rsi + 2]           ; address
    mov [r14 + EP_ADDR], eax
    mov ecx, eax
    and ecx, 0x0F
    shl ecx, 1
    test al, 0x80
    jz .out_dir
    inc ecx
.out_dir:
    mov [r14 + EP_DCI], ecx
    movzx ecx, byte [rsi + 3]           ; transfer type -> xHCI endpoint type
    and ecx, 3                          ; 0 control, 1 isochronous, 2 bulk, 3 interrupt
    cmp ecx, 2
    jb .fail                            ; control and isochronous: not here
    mov edx, 2                          ; bulk OUT
    cmp ecx, 3
    jne .bulk
    mov edx, 3                          ; interrupt OUT
.bulk:
    test al, 0x80
    jz .type
    add edx, 4                          ; IN
.type:
    mov [r14 + EP_TYPE], edx
    movzx eax, word [rsi + 4]
    mov ecx, eax
    and eax, 0x7FF
    mov [r14 + EP_MPS], eax
    shr ecx, 11                         ; high-speed periodic: extra transactions
    and ecx, 3
    cmp dword [rbx + DV_SPEED], SPEED_HS
    jne .no_burst
    test edx, 1                         ; interrupt types are 3 and 7
    jnz .burst
.no_burst:
    xor ecx, ecx
.burst:
    mov [r14 + EP_BURST], ecx
    movzx eax, byte [rsi + 6]
    test edx, 1
    jz .bulk_interval
    call usb_interval
    jmp .interval
.bulk_interval:
    xor eax, eax
.interval:
    mov [r14 + EP_INTERVAL], eax
    lea rdi, [r14 + EP_RING]
    call dev_ring_init
    test r8d, r8d
    jz .no_buf
    mov [r14 + EP_LEN], r8d
    push rdx
    call dev_alloc_page
    mov [r14 + EP_BUFP], rax
    mov [r14 + EP_BUF], rdx
    pop rdx
.no_buf:
    mov ecx, [r14 + EP_DCI]
    mov eax, [r14 + EP_INDEX]
    inc eax
    mov [rbx + DV_EPMAP + rcx], al
    mov dword [r14 + EP_STATE], 1
    pop rdi
    pop rdx
    pop rcx
    pop rax
    clc
    ret
.fail:
    pop rdi
    pop rdx
    pop rcx
    pop rax
    stc
    ret

; usb_interval(EAX = bInterval, RBX = device) -> EAX = xHCI interval exponent
usb_interval:
    cmp dword [rbx + DV_SPEED], SPEED_HS
    jae .high
    test eax, eax                       ; full/low speed: frames -> log2(8 * n)
    jnz .fs
    inc eax
.fs:
    bsr eax, eax
    add eax, 3
    cmp eax, 10
    jbe .out
    mov eax, 10
    ret
.high:
    dec eax                             ; high/super speed: 2^(n-1) microframes
    jns .clamp
    xor eax, eax
.clamp:
    cmp eax, 15
    jbe .out
    mov eax, 15
.out:
    ret

; usb_configure(RBX = device): Configure Endpoint with every endpoint the
; drivers created (and the hub fields, for hubs). CF on failure.
usb_configure:
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    xor r13d, r13d                      ; highest DCI
    xor edx, edx                        ; add flags
    mov ecx, 2
.scan:
    cmp ecx, 32
    jae .scanned
    cmp byte [rbx + DV_EPMAP + rcx], 0
    je .scan_next
    bts edx, ecx
    mov r13d, ecx
.scan_next:
    inc ecx
    jmp .scan
.scanned:
    test edx, edx
    jnz .build
    test dword [rbx + DV_HUBFLAGS], HUB_IS
    jz .nothing
.build:
    call usb_clear_input
    or edx, 1                           ; the slot context too
    mov [rdi + 4], edx
    mov r12d, [r15 + XC_CTXSZ]
    push rdi
    add rdi, r12
    mov ecx, r13d
    test ecx, ecx
    jnz .entries
    mov ecx, 1
.entries:
    call usb_fill_slot
    pop rdi
    mov ecx, 2
.fill:
    cmp ecx, 32
    jae .filled
    movzx eax, byte [rbx + DV_EPMAP + rcx]
    test eax, eax
    jz .fill_next
    dec eax
    imul r14, rax, EP_SIZE
    lea rax, [usb_eps]
    add r14, rax
    lea eax, [ecx + 1]
    imul eax, r12d
    push rdi
    add rdi, rax
    call usb_fill_ep
    pop rdi
.fill_next:
    inc ecx
    jmp .fill
.filled:
    mov rsi, [rbx + DV_INP]
    xor edx, edx
    mov ecx, [rbx + DV_SLOT]
    shl ecx, 24
    or ecx, TRB_CONFIG_EP << 10
    call xhci_command
    jmp .out
.nothing:
    clc
.out:
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; usb_fill_ep(R14 = endpoint, RDI = endpoint context). Preserves RCX.
usb_fill_ep:
    push rcx
    push rdx
    mov eax, [r14 + EP_INTERVAL]
    shl eax, 16
    mov [rdi], eax
    mov eax, [r14 + EP_MPS]
    shl eax, 16
    mov ecx, [r14 + EP_BURST]
    shl ecx, 8
    or eax, ecx
    mov ecx, [r14 + EP_TYPE]
    shl ecx, 3
    or eax, ecx
    or eax, 3 << 1                      ; 3 retries
    mov [rdi + 4], eax
    mov rax, [r14 + EP_RING + R_PHYS]
    or rax, 1
    mov [rdi + 8], rax
    mov eax, [r14 + EP_MPS]             ; max ESIT payload = mps * (burst + 1)
    mov ecx, [r14 + EP_BURST]
    inc ecx
    imul eax, ecx
    mov edx, eax
    shl edx, 16
    mov ecx, [r14 + EP_TYPE]
    and ecx, 3
    cmp ecx, 3                          ; interrupt
    je .periodic
    xor edx, edx
    mov eax, 1024                       ; bulk: average TRB length guess
.periodic:
    movzx eax, ax
    or eax, edx
    mov [rdi + 16], eax
    pop rdx
    pop rcx
    ret

; usb_ep_queue(R14 = endpoint): one transfer of EP_LEN bytes into its buffer
usb_ep_queue:
    push rcx
    push rdx
    push rsi
    push rdi
    mov rsi, [r14 + EP_BUFP]
    mov edx, [r14 + EP_LEN]
    jmp usb_ep_post

; usb_ep_send(R14 = endpoint, RSI = physical buffer, EDX = bytes): an OUT
; transfer; the buffer must stay put until the completion
usb_ep_send:
    push rcx
    push rdx
    push rsi
    push rdi
usb_ep_post:
    push rbx
    pushfq
    cli
    mov rbx, [r14 + EP_DEV]
    lea rdi, [r14 + EP_RING]
    mov ecx, (TRB_NORMAL << 10) | (1 << 5) | (1 << 2)   ; IOC, ISP
    call ring_push
    inc dword [r14 + EP_PENDING]
    mov rax, [rbx + DV_XC]
    mov rax, [rax + XC_DB]
    mov ecx, [rbx + DV_SLOT]
    mov edx, [r14 + EP_DCI]
    mov [rax + rcx * 4], edx
    popfq
    pop rbx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  usb_dispatch(R15 = controller, XC_EVENT): one event off the ring
; -----------------------------------------------------------------------------
usb_dispatch:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r14
    mov eax, [r15 + XC_EVENT + 12]
    shr eax, 10
    and eax, 0x3F
    cmp eax, TRB_EV_PORT
    je .port
    cmp eax, TRB_EV_TRANSFER
    jne .out
    mov ecx, [r15 + XC_EVENT + 12]
    mov eax, ecx
    shr eax, 24                         ; slot
    shr ecx, 16
    and ecx, 0x1F                       ; endpoint
    cmp ecx, 1
    jbe .out                            ; EP0 belongs to usb_control
    movzx eax, byte [r15 + XC_SLOTDEV + rax]
    call usb_dev_ptr
    test rax, rax
    jz .out
    mov rbx, rax
    movzx eax, byte [rbx + DV_EPMAP + rcx]
    test eax, eax
    jz .out
    dec eax
    imul r14, rax, EP_SIZE
    lea rax, [usb_eps]
    add r14, rax
    cmp dword [r14 + EP_PENDING], 0
    je .counted
    dec dword [r14 + EP_PENDING]
.counted:
    mov edx, [r15 + XC_EVENT + 8]
    mov eax, edx
    shr eax, 24                         ; completion code
    and edx, 0xFFFFFF                   ; bytes not transferred
    cmp eax, CC_SUCCESS
    je .handler
    cmp eax, CC_SHORT
    je .handler
    cmp dword [rbx + DV_STATE], DS_RUNNING
    jne .out
    mov dword [r14 + EP_HALTED], 1      ; usb_service recovers it
    mov byte [usb_pending], 1
    jmp .out
.handler:
    mov rcx, [r14 + EP_HANDLER]
    test rcx, rcx
    jz .out
    push r15
    call rcx
    pop r15
    jmp .out
.port:
    mov eax, [r15 + XC_EVENT]
    shr eax, 24                         ; port ID
    bts [r15 + XC_PORTCHG], eax
    mov byte [usb_pending], 1
.out:
    pop r14
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  usb_service: hot-plug, hub port changes and endpoint recovery. Main loop.
; -----------------------------------------------------------------------------
usb_service:
    cmp byte [usb_pending], 0
    jne .work
    ret
.work:
    push rbx
    push r12
    push r13
    push r14
    push r15
    pushfq
    cli
.again:
    mov byte [usb_pending], 0
    xor r12d, r12d
.controller:
    cmp r12d, [xhci_count]
    jae .devices
    imul r15, r12, XC_SIZE
    lea rax, [xhci_ctrl]
    add r15, rax
    mov r13d, 1
.port:
    cmp r13d, [r15 + XC_PORTS]
    ja .next_controller
    btr [r15 + XC_PORTCHG], r13d
    jnc .next_port
    mov edi, r13d
    call usb_root_change
.next_port:
    inc r13d
    jmp .port
.next_controller:
    inc r12d
    jmp .controller

.devices:
    lea rbx, [usb_devs]
    xor r12d, r12d
.device:
    cmp r12d, MAX_DEV
    jae .endpoints
    cmp dword [rbx + DV_STATE], DS_RUNNING
    jne .next_device
    xor eax, eax
    xchg eax, [rbx + DV_HUBCHG]
    test eax, eax
    jz .next_device
    mov r13d, eax
    mov r15, [rbx + DV_XC]
.hub_port:
    bsf edi, r13d
    jz .next_device
    btr r13d, edi
    call hub_port_change
    cmp dword [rbx + DV_STATE], DS_RUNNING
    je .hub_port
.next_device:
    add rbx, DV_SIZE
    inc r12d
    jmp .device

.endpoints:
    lea r14, [usb_eps]
    xor r12d, r12d
.endpoint:
    cmp r12d, MAX_EP
    jae .check
    cmp dword [r14 + EP_STATE], 0
    je .next_endpoint
    cmp dword [r14 + EP_HALTED], 0
    je .next_endpoint
    mov dword [r14 + EP_HALTED], 0
    mov rbx, [r14 + EP_DEV]
    cmp dword [rbx + DV_STATE], DS_RUNNING
    jne .next_endpoint
    mov edi, [r14 + EP_DCI]
    lea rsi, [r14 + EP_RING]
    call usb_reset_ep
    mov dword [r14 + EP_PENDING], 0
    cmp dword [r14 + EP_AUTO], 0
    je .next_endpoint
    call usb_ep_queue
.next_endpoint:
    add r14, EP_SIZE
    inc r12d
    jmp .endpoint

.check:
    cmp byte [usb_pending], 0
    jne .again
    popfq
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; usb_root_change(R15 = controller, EDI = root port): connect or disconnect
usb_root_change:
    push rbx
    push r12
    push r13
    mov r13d, edi
    lea r12, [r13 - 1]
    shl r12, 4
    add r12, [r15 + XC_OP]
    add r12, 0x400                      ; PORTSC
    mov eax, [r12]
    mov ecx, eax                        ; acknowledge the change bits
    and ecx, PORTSC_KEEP
    mov edx, eax
    and edx, 0x7F << 17
    or ecx, edx
    mov [r12], ecx
    movzx ecx, byte [r15 + XC_ROOTDEV + r13]
    test ecx, ecx
    jz .attach
    test eax, 1                         ; gone, or replaced?
    jz .detach
    test eax, 1 << 17
    jz .out
.detach:
    push rax
    mov eax, ecx
    call usb_dev_ptr
    mov rbx, rax
    call usb_detach
    pop rax
.attach:
    test eax, 1
    jz .out
    cmp byte [usb_hotplug], 0
    je .settled
    mov edi, 100                        ; let the contacts settle
    call delay_ms_usb
.settled:
    mov eax, [r12]
    test eax, 1
    jz .out
    test eax, 2                         ; enabled already (USB 3)?
    jnz .enabled
    and eax, PORTSC_KEEP                ; USB 2: reset to enable
    or eax, 1 << 4
    mov [r12], eax
    mov edi, 500
    call usb_deadline
    mov rsi, rax
.resetting:
    test dword [r12], 1 << 21           ; reset change
    jnz .reset_done
    call usb_expired
    jc .out
    pause
    jmp .resetting
.reset_done:
    mov eax, [r12]
    and eax, PORTSC_KEEP
    or eax, 1 << 21
    mov [r12], eax
    mov edi, 20                         ; reset recovery
    call delay_ms_usb
    mov eax, [r12]
    test eax, 2
    jz .out
.enabled:
    shr eax, 10
    and eax, 0xF
    mov esi, eax
    mov edi, r13d
    xor edx, edx
    xor ecx, ecx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    call usb_attach
    jc .out
    mov eax, [rbx + DV_INDEX]
    inc eax
    mov [r15 + XC_ROOTDEV + r13], al
.out:
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  usb_detach(RBX = device): unplugged. Children first, then the drivers.
; -----------------------------------------------------------------------------
usb_detach:
    push rbx
    push r12
    push r13
    push r15
    mov r15, [rbx + DV_XC]
    mov r13d, [rbx + DV_INDEX]
    inc r13d
    lea r12, [usb_devs]                 ; children of a hub
    xor ecx, ecx
.child:
    cmp ecx, MAX_DEV
    jae .drivers
    cmp dword [r12 + DV_STATE], DS_FREE
    je .next_child
    cmp [r12 + DV_PARENT], r13d
    jne .next_child
    push rcx
    push rbx
    mov rbx, r12
    call usb_detach
    pop rbx
    pop rcx
.next_child:
    add r12, DV_SIZE
    inc ecx
    jmp .child
.drivers:
    lea rdi, [usb_path_buf]
    call usb_path
    lea rsi, [rbx + DV_NAME]
    cmp byte [rsi], 0
    jne .named
    lea rsi, [str_usb_unnamed]
.named:
    KLOG "usb: %s on port %s removed", rsi, rdi
    xor r12d, r12d
.bind:
    cmp r12d, MAX_BIND
    jae .teardown
    imul eax, r12d, BIND_SIZE
    mov rcx, [rbx + DV_BINDS + rax + BIND_DETACH]
    test rcx, rcx
    jz .next_bind
    mov rsi, [rbx + DV_BINDS + rax + BIND_CTX]
    call rcx
.next_bind:
    inc r12d
    jmp .bind
.teardown:
    call usb_teardown
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; usb_teardown(RBX = device, R15 = controller): release the slot, the
; endpoints and the memory
usb_teardown:
    push r12
    mov ecx, [rbx + DV_SLOT]
    test ecx, ecx
    jz .no_slot
    push rcx
    shl ecx, 24
    or ecx, TRB_DISABLE_SLOT << 10
    xor esi, esi
    xor edx, edx
    call xhci_command
    pop rcx
    mov byte [r15 + XC_SLOTDEV + rcx], 0
    mov rax, [r15 + XC_DCBAA]
    mov qword [rax + rcx * 8], 0
.no_slot:
    mov eax, [rbx + DV_PARENT]
    test eax, eax
    jnz .endpoints
    mov eax, [rbx + DV_ROOTPORT]
    mov ecx, [rbx + DV_INDEX]
    inc ecx
    cmp [r15 + XC_ROOTDEV + rax], cl
    jne .endpoints
    mov byte [r15 + XC_ROOTDEV + rax], 0
.endpoints:
    mov ecx, 2
.ep:
    cmp ecx, 32
    jae .pages
    movzx eax, byte [rbx + DV_EPMAP + rcx]
    test eax, eax
    jz .next_ep
    dec eax
    imul eax, eax, EP_SIZE
    lea rdx, [usb_eps]
    mov dword [rdx + rax + EP_STATE], 0
.next_ep:
    inc ecx
    jmp .ep
.pages:
    xor r12d, r12d
.page:
    cmp r12d, [rbx + DV_NPAGES]
    jae .done
    mov rdi, [rbx + DV_PAGES + r12 * 8]
    mov esi, 1
    call pmm_free
    inc r12d
    jmp .page
.done:
    mov dword [rbx + DV_STATE], DS_FREE
    pop r12
    ret

; -----------------------------------------------------------------------------
;  cmd_usb (shell): every device
; -----------------------------------------------------------------------------
usb_list:
    push rbx
    push r12
    lea rbx, [usb_devs]
    xor r12d, r12d
.next:
    cmp r12d, MAX_DEV
    jae .done
    cmp dword [rbx + DV_STATE], DS_RUNNING
    jne .skip
    lea rdi, [usb_path_buf]
    call usb_path
    mov eax, [rbx + DV_SPEED]
    lea rcx, [usb_speed_names]
    mov rcx, [rcx + rax * 8]
    lea rsi, [rbx + DV_NAME]
    cmp byte [rsi], 0
    jne .named
    lea rsi, [str_usb_unnamed]
.named:
    movzx eax, word [rbx + DV_VID]
    movzx edx, word [rbx + DV_PID]
    lea r8, [rbx + DV_ROLE]
    cmp byte [r8], 0
    jne .role
    lea r8, [str_usb_no_driver]
.role:
    KLOG "  %-6s %04x:%04x %-20s %s, %s", rdi, rax, rdx, rsi, r8, rcx
.skip:
    add rbx, DV_SIZE
    inc r12d
    jmp .next
.done:
    pop r12
    pop rbx
    ret

; usb_add_role(RBX = device, RSI = word like "keyboard"): for the listing
usb_add_role:
    push rcx
    push rdi
    push rsi
    lea rdi, [rbx + DV_ROLE]
    xor ecx, ecx
.end:
    cmp byte [rdi + rcx], 0
    je .at_end
    inc ecx
    jmp .end
.at_end:
    test ecx, ecx
    jz .copy
    cmp ecx, DV_ROLE_LEN - 2
    jae .out
    mov byte [rdi + rcx], ' '
    inc ecx
.copy:
    cmp ecx, DV_ROLE_LEN - 1
    jae .term
    mov al, [rsi]
    test al, al
    jz .term
    mov [rdi + rcx], al
    inc rsi
    inc ecx
    jmp .copy
.term:
    mov byte [rdi + rcx], 0
.out:
    pop rsi
    pop rdi
    pop rcx
    ret

section .rodata
str_usb_no_driver: db 'no driver', 0
str_usb_unnamed: db 'USB device', 0

section .data
usb_pending:    db 0                    ; usb_service has work
usb_hotplug:    db 0                    ; set once boot enumeration is done

section .bss
alignb 64
usb_devs:       resb MAX_DEV * DV_SIZE
usb_eps:        resb MAX_EP * EP_SIZE
usb_path_buf:   resb 64
