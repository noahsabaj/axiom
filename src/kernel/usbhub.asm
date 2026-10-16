; =============================================================================
;  usbhub.asm - USB 2 and USB 3 hubs: power the ports, watch the status
;  change endpoint, reset ports and enumerate what is behind them (with the
;  route string and transaction-translator fields xHCI needs).
; =============================================================================

HUB_PORT_RESET  equ 4
HUB_PORT_POWER  equ 8
HUB_MAX_PORTS   equ 15                  ; one route-string nibble per tier

section .text

; hub_probe(RBX = device, RSI = interface, RDI = end) -> CF = 1 if not a hub
hub_probe:
    cmp byte [rsi + 5], 9
    jne .no
    cmp dword [rbx + DV_DEPTH], 4       ; five tiers is the most a route holds
    jae .no
    push rcx
    push rdx
    push rsi
    push r14
    cmp dword [rbx + DV_SPEED], SPEED_SS
    jb .usb2
    mov esi, [rbx + DV_DEPTH]           ; SET_HUB_DEPTH, then the SS descriptor
    shl rsi, 16
    or rsi, 0x0C20
    xor edx, edx
    xor ecx, ecx
    call usb_control
    mov rsi, 0x000C00002A0006A0
    mov ecx, 12
    jmp .get
.usb2:
    mov rsi, 0x00090000290006A0
    mov ecx, 9
.get:
    mov rdx, [rbx + DV_BUFP]
    call usb_control
    jc .fail
    mov rdx, [rbx + DV_BUF]
    movzx eax, byte [rdx + 2]           ; ports
    cmp eax, HUB_MAX_PORTS
    jbe .ports
    mov eax, HUB_MAX_PORTS
.ports:
    mov [rbx + DV_HUBPORTS], eax
    mov ecx, HUB_IS
    cmp dword [rbx + DV_SPEED], SPEED_HS
    jne .flags
    movzx eax, word [rdx + 3]           ; TT think time, bits 6:5
    shr eax, 5
    and eax, 3
    shl eax, 2
    or ecx, eax
.flags:
    mov [rbx + DV_HUBFLAGS], ecx
    movzx eax, byte [rdx + 5]           ; power-on to power-good, 2 ms units
    shl eax, 1
    mov [rbx + DV_HUBPWR], eax
    mov rsi, [rsp + 8]                  ; the interface
    mov dl, 5                           ; its status change endpoint
    xor ecx, ecx
    call usb_find_desc
    jc .fail
    mov rsi, rax
    lea rdx, [hub_status_done]
    mov rcx, rbx
    mov r8d, 8
    call usb_ep_create
    jc .fail
    mov dword [r14 + EP_AUTO], 1
    mov eax, [r14 + EP_MPS]             ; never ask for more than one packet
    cmp eax, 8
    jbe .len
    mov eax, 8
.len:
    mov [r14 + EP_LEN], eax
    mov [rbx + DV_HUBEP], r14
    lea rsi, [hub_start]
    xor edx, edx
    mov rcx, rbx
    call usb_bind
    lea rsi, [str_role_hub]
    call usb_add_role
    pop r14
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.fail:
    mov dword [rbx + DV_HUBFLAGS], 0
    pop r14
    pop rsi
    pop rdx
    pop rcx
.no:
    stc
    ret

; hub_start(RBX = hub): power every port, then look at all of them
hub_start:
    push rsi
    push rdi
    push r14
    mov edi, 1
.power:
    cmp edi, [rbx + DV_HUBPORTS]
    ja .powered
    mov esi, HUB_PORT_POWER
    mov edx, 3                          ; SET_FEATURE
    call hub_feature
    inc edi
    jmp .power
.powered:
    mov edi, [rbx + DV_HUBPWR]
    add edi, 100                        ; and let devices connect
    call delay_ms_usb
    mov ecx, [rbx + DV_HUBPORTS]
    mov eax, 2
    shl eax, cl
    sub eax, 2                          ; bits 1..ports
    or [rbx + DV_HUBCHG], eax
    mov byte [usb_pending], 1
    mov r14, [rbx + DV_HUBEP]
    call usb_ep_queue
    pop r14
    pop rdi
    pop rsi
    ret

; hub_status_done: the status change endpoint completed (interrupts off)
hub_status_done:
    mov rax, [r14 + EP_BUF]
    movzx ecx, word [rax]
    mov eax, [r14 + EP_LEN]
    sub eax, edx
    cmp eax, 1
    ja .both
    movzx ecx, cl
.both:
    and ecx, ~1                         ; bit 0 is the hub itself
    or [rbx + DV_HUBCHG], ecx
    mov byte [usb_pending], 1
    jmp usb_ep_queue

; hub_feature(RBX = hub, EDI = port, ESI = feature, EDX = 3 set / 1 clear)
hub_feature:
    push rcx
    push rdx
    push rsi
    shl rdx, 8
    or rdx, 0x23
    shl rsi, 16
    or rsi, rdx
    mov rax, rdi
    shl rax, 32
    or rsi, rax
    xor edx, edx
    xor ecx, ecx
    call usb_control
    pop rsi
    pop rdx
    pop rcx
    ret

; hub_port_status(RBX = hub, EDI = port) -> EAX = status | change << 16; CF on failure
hub_port_status:
    push rcx
    push rdx
    push rsi
    mov rsi, rdi
    shl rsi, 32
    mov rax, 4 << 48
    or rsi, rax
    or rsi, 0x00A3                      ; GET_STATUS, other recipient
    mov rdx, [rbx + DV_BUFP]
    mov ecx, 4
    call usb_control
    jc .out
    mov rax, [rbx + DV_BUF]
    mov eax, [rax]
    clc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; hub_ack(RBX = hub, EDI = port, EAX = status | change << 16): clear each
; change bit that is set
hub_ack:
    push rcx
    push rdx
    push rsi
    push r8
    shr eax, 16
    mov r8d, eax
    xor ecx, ecx
.bit:
    cmp ecx, 8
    jae .done
    bt r8d, ecx
    jnc .next
    lea rax, [hub_change_usb2]
    cmp dword [rbx + DV_SPEED], SPEED_SS
    jb .table
    lea rax, [hub_change_usb3]
.table:
    movzx esi, byte [rax + rcx]
    test esi, esi
    jz .next
    mov edx, 1                          ; CLEAR_FEATURE
    call hub_feature
.next:
    inc ecx
    jmp .bit
.done:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; hub_child(RBX = hub, EDI = port) -> RAX = device there, or 0
hub_child:
    push rcx
    push rdx
    mov edx, [rbx + DV_INDEX]
    inc edx
    lea rax, [usb_devs]
    xor ecx, ecx
.next:
    cmp ecx, MAX_DEV
    jae .none
    cmp dword [rax + DV_STATE], DS_FREE
    je .skip
    cmp [rax + DV_PARENT], edx
    jne .skip
    cmp [rax + DV_PPORT], edi
    je .out
.skip:
    add rax, DV_SIZE
    inc ecx
    jmp .next
.none:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  hub_port_change(RBX = hub, EDI = port, R15 = controller): something
;  happened on a port (usb_service, interrupts off)
; -----------------------------------------------------------------------------
hub_port_change:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    call hub_port_status
    jc .out
    mov r13d, eax
    call hub_ack
    call hub_child
    test rax, rax
    jz .attach
    test r13d, 1                        ; gone, or replaced?
    jz .detach
    test r13d, 1 << 16
    jz .out
.detach:
    push rbx
    mov rbx, rax
    call usb_detach
    pop rbx
.attach:
    test r13d, 1
    jz .out
    cmp byte [usb_hotplug], 0
    je .reset
    mov edi, 100                        ; let the contacts settle
    call delay_ms_usb
.reset:
    mov edi, r12d
    mov esi, HUB_PORT_RESET
    mov edx, 3
    call hub_feature
    mov r14d, 50                        ; up to 500 ms
.wait:
    mov edi, 10
    call delay_ms_usb
    mov edi, r12d
    call hub_port_status
    jc .out
    test eax, 1 << 20                   ; C_PORT_RESET
    jnz .reset_done
    dec r14d
    jnz .wait
    jmp .out
.reset_done:
    mov r13d, eax
    call hub_ack
    mov edi, 20                         ; reset recovery
    call delay_ms_usb
    test r13d, 2                        ; enabled?
    jz .out
    mov esi, SPEED_SS                   ; speed of the new device
    cmp dword [rbx + DV_SPEED], SPEED_SS
    jae .speed
    mov esi, SPEED_LS
    test r13d, 1 << 9
    jnz .speed
    mov esi, SPEED_HS
    test r13d, 1 << 10
    jnz .speed
    mov esi, SPEED_FS
.speed:
    mov ecx, [rbx + DV_DEPTH]           ; route: this port in the hub's tier
    mov edx, r12d
    shl ecx, 2
    shl edx, cl
    or edx, [rbx + DV_ROUTE]
    mov r10d, [rbx + DV_TTSLOT]         ; transaction translator
    mov r11d, [rbx + DV_TTPORT]
    cmp dword [rbx + DV_SPEED], SPEED_HS
    jne .tt
    cmp esi, SPEED_HS
    jae .tt_none
    mov r10d, [rbx + DV_SLOT]           ; LS/FS behind this HS hub
    mov r11d, r12d
    jmp .tt
.tt_none:
    xor r10d, r10d
    xor r11d, r11d
.tt:
    mov edi, [rbx + DV_ROOTPORT]
    mov ecx, [rbx + DV_DEPTH]
    inc ecx
    mov r8d, [rbx + DV_INDEX]
    inc r8d
    mov r9d, r12d
    call usb_attach
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
str_role_hub:   db 'hub', 0
; CLEAR_FEATURE selectors for change bits 0-7 of wPortChange
hub_change_usb2: db 16, 17, 18, 19, 20, 0, 0, 0
hub_change_usb3: db 16, 0, 0, 19, 20, 29, 25, 26
