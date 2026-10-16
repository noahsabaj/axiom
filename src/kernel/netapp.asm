; =============================================================================
;  netapp.asm - what runs over the network stack: a DHCP client, a DNS
;  resolver for IPv4 addresses, ping, and the shell's network commands. Each
;  runs in the background on net_service's timers, so the prompt comes back
;  at once and answers arrive as log lines; ctrl+C stops a ping or a lookup.
; =============================================================================

DH_OFF          equ 0
DH_SELECTING    equ 1                   ; DISCOVER sent, waiting for an offer
DH_REQUESTING   equ 2                   ; REQUEST sent for the offer
DH_BOUND        equ 3
DH_RENEWING     equ 4                   ; half the lease gone: asking again

DHCP_DISCOVER   equ 1
DHCP_OFFER      equ 2
DHCP_REQUEST    equ 3
DHCP_ACK        equ 5
DHCP_NAK        equ 6
DHCP_COOKIE     equ 0x63538263          ; 99.130.83.99 as it travels
DHCP_MIN        equ 300                 ; what old BOOTP servers expect
DHCP_TRIES      equ 5
DHCP_MAX_LEASE  equ 30 * 86400          ; longer leases are renewed sooner

DNS_TRIES       equ 3
PING_DATA       equ 56                  ; bytes after the ICMP header

section .text

; net_link_up: the interface with the address has a link
net_link_up:
    cmp byte [net_static], 0
    jne .out
    jmp dhcp_start
.out:
    ret

; net_cancel: ctrl+C at the prompt. Preserves all.
net_cancel:
    cmp dword [dns_state], 0
    je .ping
    mov dword [dns_state], 0
    mov qword [dns_next], 0
    KLOG "host: stopped"
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    call dns_failed
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.ping:
    call http_cancel
    jmp ping_end

; dns_failed: the lookup ended without an address (said why); whoever was
; waiting for it hears so
dns_failed:
    cmp dword [dns_then], 2
    jne .out
    mov dword [dns_then], 0
    jmp http_dns_failed
.out:
    ret

; -----------------------------------------------------------------------------
;  DHCP
; -----------------------------------------------------------------------------

; dhcp_start: forget the address and ask for one. Preserves all.
dhcp_start:
    cmp qword [net_nic], 0
    je .out
    push rax
    xor eax, eax
    mov [net_ip], eax
    mov [net_mask], eax
    mov [net_gw], eax
    mov [net_dns], eax
    mov byte [net_static], 0
    call arp_flush
    call net_random
    mov [dh_xid], eax
    mov dword [dh_state], DH_SELECTING
    mov dword [dh_tries], 0
    KLOG "dhcp: asking for an address"
    call dhcp_discover
    call dhcp_arm
    pop rax
.out:
    ret

; dhcp_arm: the next try in 2, 4, 8, 8... seconds. Preserves all.
dhcp_arm:
    push rax
    push rcx
    push rdx
    mov ecx, [dh_tries]
    mov eax, 2
    shl eax, cl
    cmp eax, 8
    jbe .wait
    mov eax, 8
.wait:
    imul rax, [net_second]
    mov rdx, rax
    call net_clock
    add rax, rdx
    mov [dhcp_next], rax
    pop rdx
    pop rcx
    pop rax
    ret

; dhcp_begin(EAX = message type) -> RDI = where the next option goes; the
; fixed part and the type are in net_frame. Preserves others.
dhcp_begin:
    push rax
    push rcx
    push rdx
    mov edx, eax
    lea rdi, [net_frame + UDP_PAYLOAD]
    push rdi
    mov ecx, DHCP_MIN
    xor eax, eax
    rep stosb
    pop rdi
    mov dword [rdi], 0x00060101         ; a request, Ethernet, 6-byte addresses
    mov eax, [dh_xid]
    mov [rdi + 4], eax
    mov word [rdi + 10], 0x0080         ; answer by broadcast
    cmp dword [dh_state], DH_RENEWING
    jne .mac
    mov eax, [net_ip]                   ; the address we hold
    mov [rdi + 12], eax
.mac:
    mov rax, [net_nic]
    mov ecx, [rax + NI_MAC]
    mov [rdi + 28], ecx
    mov cx, [rax + NI_MAC + 4]
    mov [rdi + 32], cx
    mov dword [rdi + 236], DHCP_COOKIE
    add rdi, 240
    mov byte [rdi], 53
    mov byte [rdi + 1], 1
    mov [rdi + 2], dl
    add rdi, 3
    pop rdx
    pop rcx
    pop rax
    ret

; dhcp_end(RDI = where the next option goes) -> ECX = the message's bytes:
; client ID, host name, the options we want, end. Preserves others.
dhcp_end:
    push rax
    push rsi
    mov byte [rdi], 61                  ; client ID: Ethernet, our MAC
    mov byte [rdi + 1], 7
    mov byte [rdi + 2], 1
    mov rax, [net_nic]
    mov esi, [rax + NI_MAC]
    mov [rdi + 3], esi
    mov si, [rax + NI_MAC + 4]
    mov [rdi + 7], si
    add rdi, 9
    lea rsi, [dhcp_tail]
    mov ecx, DHCP_TAIL
    rep movsb
    lea rax, [net_frame + UDP_PAYLOAD]
    sub rdi, rax
    mov ecx, edi
    cmp ecx, DHCP_MIN
    jae .out
    mov ecx, DHCP_MIN
.out:
    pop rsi
    pop rax
    ret

; dhcp_send(ECX = bytes): from port 68 to every server's 67. Preserves all
; but RAX.
dhcp_send:
    push rdx
    push rsi
    push rdi
    mov edi, -1
    mov esi, 68
    mov edx, 67
    call udp_send
    pop rdi
    pop rsi
    pop rdx
    ret

; dhcp_discover. Preserves all but RAX.
dhcp_discover:
    push rcx
    push rdi
    mov eax, DHCP_DISCOVER
    call dhcp_begin
    call dhcp_end
    call dhcp_send
    pop rdi
    pop rcx
    ret

; dhcp_request: for the offer, or (renewing) for the address we hold.
; Preserves all but RAX.
dhcp_request:
    push rcx
    push rdi
    mov eax, DHCP_REQUEST
    call dhcp_begin
    cmp dword [dh_state], DH_RENEWING
    je .end
    mov byte [rdi], 50                  ; the address offered
    mov byte [rdi + 1], 4
    mov eax, [dh_offer]
    mov [rdi + 2], eax
    mov byte [rdi + 6], 54              ; by this server
    mov byte [rdi + 7], 4
    mov eax, [dh_server]
    mov [rdi + 8], eax
    add rdi, 12
.end:
    call dhcp_end
    call dhcp_send
    pop rdi
    pop rcx
    ret

; dhcp_input(RBX, RSI = message, ECX = bytes, EDX = sender): from udp_input
dhcp_input:
    mov eax, [dh_state]
    cmp eax, DH_SELECTING
    je .take
    cmp eax, DH_REQUESTING
    je .take
    cmp eax, DH_RENEWING
    jne .out
.take:
    cmp ecx, 240
    jb .out
    cmp byte [rsi], 2                   ; a reply
    jne .out
    mov eax, [dh_xid]
    cmp [rsi + 4], eax
    jne .out
    mov rax, [net_nic]                  ; to us
    mov r8d, [rax + NI_MAC]
    cmp [rsi + 28], r8d
    jne .out
    mov r8w, [rax + NI_MAC + 4]
    cmp [rsi + 32], r8w
    jne .out
    cmp dword [rsi + 236], DHCP_COOKIE
    jne .out
    call dhcp_options
    mov eax, [dh_type]
    cmp dword [dh_state], DH_SELECTING
    jne .answer
    cmp eax, DHCP_OFFER
    jne .out
    mov eax, [rsi + 16]                 ; the address offered
    test eax, eax
    jz .out
    mov [dh_offer], eax
    mov eax, [dh_o_server]
    test eax, eax
    jnz .server
    mov eax, edx                        ; no server ID: whoever sent it
.server:
    mov [dh_server], eax
    mov dword [dh_state], DH_REQUESTING
    mov dword [dh_tries], 0
    call dhcp_request
    jmp dhcp_arm
.answer:
    cmp eax, DHCP_NAK
    je .nak
    cmp eax, DHCP_ACK
    jne .out
    mov eax, [rsi + 16]
    test eax, eax
    jz .out
    jmp dhcp_bind
.nak:
    KLOG "dhcp: the server said no; asking again"
    jmp dhcp_start
.out:
    ret

; dhcp_options(RSI = message, ECX = bytes): the options Axiom uses, 0 for
; any missing. Preserves all but RAX.
dhcp_options:
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    xor eax, eax
    mov [dh_type], eax
    mov [dh_o_mask], eax
    mov [dh_o_router], eax
    mov [dh_o_dns], eax
    mov [dh_o_lease], eax
    mov [dh_o_server], eax
    lea rdi, [rsi + 240]
    lea r8, [rsi + rcx]                 ; the end
.option:
    cmp rdi, r8
    jae .done
    movzx eax, byte [rdi]
    cmp eax, 255
    je .done
    test eax, eax
    jnz .sized
    inc rdi                             ; padding
    jmp .option
.sized:
    lea r9, [rdi + 2]
    cmp r9, r8
    ja .done
    movzx edx, byte [rdi + 1]
    add r9, rdx                         ; the next option
    cmp r9, r8
    ja .done
    cmp eax, 53
    jne .four
    test edx, edx
    jz .next
    movzx eax, byte [rdi + 2]
    mov [dh_type], eax
    jmp .next
.four:
    cmp edx, 4
    jb .next
    mov ecx, [rdi + 2]                  ; an address (the first), or a number
    cmp eax, 1
    jne .router
    mov [dh_o_mask], ecx
    jmp .next
.router:
    cmp eax, 3
    jne .dns
    mov [dh_o_router], ecx
    jmp .next
.dns:
    cmp eax, 6
    jne .lease
    mov [dh_o_dns], ecx
    jmp .next
.lease:
    cmp eax, 51
    jne .server
    bswap ecx
    mov [dh_o_lease], ecx
    jmp .next
.server:
    cmp eax, 54
    jne .next
    mov [dh_o_server], ecx
.next:
    mov rdi, r9
    jmp .option
.done:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

; dhcp_bind(EAX = the address acknowledged): take it and its options
dhcp_bind:
    push r12
    mov r12d, [dh_state]                ; before
    mov [net_ip], eax
    mov eax, [dh_o_mask]
    test eax, eax
    jnz .mask
    mov eax, 0x00FFFFFF                 ; none given: a /24
.mask:
    mov [net_mask], eax
    mov eax, [dh_o_router]
    mov [net_gw], eax
    mov eax, [dh_o_dns]
    mov [net_dns], eax
    mov eax, [dh_o_lease]
    test eax, eax
    jnz .lease
    mov eax, 3600                       ; none given: an hour
.lease:
    mov [dh_lease], eax
    mov dword [dh_state], DH_BOUND
    cmp eax, DHCP_MAX_LEASE
    jbe .ticks
    mov eax, DHCP_MAX_LEASE
.ticks:
    imul rax, [net_second]
    mov rcx, rax
    call net_clock
    lea rdx, [rax + rcx]
    mov [dh_expire], rdx
    shr rcx, 1                          ; renew half way
    add rax, rcx
    mov [dhcp_next], rax
    mov eax, [dh_lease]
    call lease_text
    cmp r12d, DH_RENEWING
    je .renewed
    call net_peers
    popcnt ecx, [net_mask]
    KLOG "dhcp: address %I/%u, gateway %s, DNS %s, lease %s (server %I)", qword [net_ip], rcx, rdx, rsi, rax, qword [dh_server]
    jmp .out
.renewed:
    KLOG "dhcp: lease on %I renewed for %s", qword [net_ip], rax
.out:
    pop r12
    ret

; dhcp_tick: try again, give up, or renew
dhcp_tick:
    mov rax, [dhcp_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    mov eax, [dh_state]
    cmp eax, DH_SELECTING
    je .selecting
    cmp eax, DH_REQUESTING
    je .requesting
    cmp eax, DH_BOUND
    je .renew
    cmp eax, DH_RENEWING
    je .renewing
    mov qword [dhcp_next], 0
.out:
    ret
.selecting:
    inc dword [dh_tries]
    cmp dword [dh_tries], DHCP_TRIES
    jae .give_up
    call dhcp_discover
    jmp dhcp_arm
.give_up:
    mov dword [dh_state], DH_OFF
    mov qword [dhcp_next], 0
    KLOG "dhcp: no server answered; 'dhcp' asks again, 'ip' sets an address by hand"
    ret
.requesting:
    inc dword [dh_tries]
    cmp dword [dh_tries], DHCP_TRIES - 1
    jae dhcp_start                      ; the offer went stale: start over
    call dhcp_request
    jmp dhcp_arm
.renew:
    mov dword [dh_state], DH_RENEWING
    call net_random
    mov [dh_xid], eax
.renewing:
    mov rax, [net_now]
    cmp rax, [dh_expire]
    jae .expired
    call dhcp_request
    mov rax, [net_second]               ; again in a minute, within the lease
    imul rax, rax, 60
    add rax, [net_now]
    cmp rax, [dh_expire]
    jbe .again
    mov rax, [dh_expire]
.again:
    mov [dhcp_next], rax
    ret
.expired:
    KLOG "dhcp: the lease on %I ran out", qword [net_ip]
    jmp dhcp_start

; -----------------------------------------------------------------------------
;  DNS: one A lookup at a time
; -----------------------------------------------------------------------------

; dns_lookup(RSI = name, EDX = 0 print the address, 1 ping it, 2 fetch from
; it over HTTP). Says why if it cannot start.
dns_lookup:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rsi
    mov eax, [net_dns]
    test eax, eax
    jz .no_server
    mov [dns_server], eax
    mov [dns_then], edx
    lea rdi, [dns_name]                 ; letters, digits, '-' and '_' in
    xor ecx, ecx                        ; labels of 63 at most, 253 in all
    xor edx, edx
.char:
    lodsb
    test al, al
    jz .end
    cmp al, '.'
    je .dot
    cmp al, '-'
    je .label
    cmp al, '_'
    je .label
    cmp al, '0'
    jb .bad
    cmp al, '9'
    jbe .label
    mov ah, al
    or ah, 0x20
    cmp ah, 'a'
    jb .bad
    cmp ah, 'z'
    ja .bad
.label:
    inc edx
    cmp edx, 63
    ja .bad
    jmp .store
.dot:
    test edx, edx                       ; no empty labels
    jz .bad
    xor edx, edx
.store:
    stosb
    inc ecx
    cmp ecx, 253
    ja .bad
    jmp .char
.end:
    test ecx, ecx
    jz .bad
    mov byte [rdi], 0
    call net_random
    mov [dns_id], ax
    shr eax, 16
    and eax, 0x3FFF
    add eax, 49152                      ; a port of our own
    mov [dns_port], eax
    mov dword [dns_tries], 1
    mov dword [dns_state], 1
    call dns_send
    call net_clock
    add rax, [net_second]
    add rax, [net_second]
    mov [dns_next], rax
    clc
    jmp .out
.no_server:
    KLOG "host: no DNS server (DHCP named none; 'ip' can set one)"
    stc
    jmp .out
.bad:
    KLOG "host: '%s' is not a host name", r8
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; dns_send: the question, to the server. Preserves all but RAX.
dns_send:
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [net_frame + UDP_PAYLOAD]
    mov ax, [dns_id]
    mov [rdi], ax
    mov word [rdi + 2], 0x0001          ; recursion desired
    mov word [rdi + 4], 0x0100          ; one question
    xor eax, eax
    mov [rdi + 6], eax                  ; no answers, authorities, additions
    mov [rdi + 10], ax
    add rdi, 12
    lea rsi, [dns_name]
.label:
    mov rdx, rdi                        ; its length goes here
    inc rdi
    xor ecx, ecx
.char:
    lodsb
    test al, al
    jz .last
    cmp al, '.'
    je .dot
    stosb
    inc ecx
    jmp .char
.dot:
    mov [rdx], cl
    cmp byte [rsi], 0                   ; a trailing dot ends the name
    jne .label
    jmp .root
.last:
    mov [rdx], cl
.root:
    mov byte [rdi], 0
    mov dword [rdi + 1], 0x01000100     ; type A, class IN
    add rdi, 5
    lea rax, [net_frame + UDP_PAYLOAD]
    sub rdi, rax
    mov ecx, edi
    mov edi, [dns_server]
    mov esi, [dns_port]
    mov edx, 53
    call udp_send
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; dns_input(RBX, RSI = message, ECX = bytes, EDX = sender): from udp_input
dns_input:
    cmp dword [dns_state], 0
    je .out
    cmp ecx, 12
    jb .out
    mov ax, [rsi]
    cmp ax, [dns_id]
    jne .out
    test byte [rsi + 2], 0x80           ; an answer
    jz .out
    push r12
    push r13
    lea r12, [rsi + rcx]                ; the end
    mov r13, rsi
    mov dword [dns_state], 0
    mov qword [dns_next], 0
    movzx eax, byte [rsi + 3]
    and eax, 15
    cmp eax, 3
    je .nxdomain
    test eax, eax
    jnz .failed
    movzx ecx, word [rsi + 4]           ; the questions, repeated
    xchg cl, ch
    lea rdi, [rsi + 12]
.question:
    test ecx, ecx
    jz .answers
    call dns_skip_name
    jc .none
    add rdi, 4
    dec ecx
    jmp .question
.answers:
    movzx ecx, word [r13 + 6]
    xchg cl, ch
.answer:
    test ecx, ecx
    jz .none
    call dns_skip_name
    jc .none
    lea rax, [rdi + 10]
    cmp rax, r12
    ja .none
    movzx edx, word [rdi + 8]           ; its data's length
    xchg dl, dh
    lea rax, [rdi + rdx + 10]
    cmp rax, r12
    ja .none
    cmp dword [rdi], 0x01000100         ; type A, class IN, an address
    jne .skip
    cmp edx, 4
    jne .skip
    mov eax, [rdi + 10]
    pop r13
    pop r12
    jmp dns_done
.skip:
    lea rdi, [rdi + rdx + 10]
    dec ecx
    jmp .answer
.nxdomain:
    lea rax, [dns_name]
    KLOG "host: %s does not exist", rax
    jmp .end
.failed:
    KLOG "host: the DNS server could not answer (code %u)", rax
    jmp .end
.none:
    lea rax, [dns_name]
    KLOG "host: %s has no IPv4 address", rax
.end:
    pop r13
    pop r12
    jmp dns_failed
.out:
    ret

; dns_skip_name(RDI = a name in a message, R12 = the message's end) ->
; RDI past it, CF if it runs off the end. Preserves others.
dns_skip_name:
    push rax
.label:
    cmp rdi, r12
    jae .bad
    movzx eax, byte [rdi]
    test eax, eax
    jz .end
    cmp eax, 0xC0                       ; a pointer ends it
    jae .pointer
    test eax, 0xC0
    jnz .bad
    lea rdi, [rdi + rax + 1]
    jmp .label
.end:
    inc rdi
    clc
    pop rax
    ret
.pointer:
    add rdi, 2
    cmp rdi, r12
    ja .bad
    clc
    pop rax
    ret
.bad:
    stc
    pop rax
    ret

; dns_done(EAX = the address found)
dns_done:
    cmp dword [dns_then], 1
    je ping_begin
    cmp dword [dns_then], 2
    je http_begin
    lea rdx, [dns_name]
    KLOG "%s is %I", rdx, rax
    ret

; dns_tick: ask again every 2 s, three times
dns_tick:
    mov rax, [dns_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    cmp dword [dns_tries], DNS_TRIES
    jae .give_up
    inc dword [dns_tries]
    call dns_send
    mov rax, [net_second]
    add rax, rax
    add rax, [net_now]
    mov [dns_next], rax
    ret
.give_up:
    mov dword [dns_state], 0
    mov qword [dns_next], 0
    KLOG "host: no answer from the DNS server %I", qword [dns_server]
    jmp dns_failed
.out:
    ret

; -----------------------------------------------------------------------------
;  Ping
; -----------------------------------------------------------------------------

; ping_begin(EAX = address); ping_count is set
ping_begin:
    push rcx
    mov [ping_ip], eax
    mov ecx, [ping_count]
    cmp ecx, 1
    je .once
    KLOG "ping %I, %u times (ctrl+C stops it)", rax, rcx
    jmp .start
.once:
    KLOG "ping %I, once", rax
.start:
    call net_random
    mov [ping_id], ax
    xor eax, eax
    mov [ping_seq], eax
    mov [ping_got], eax
    mov [ping_waiting], eax
    mov [ping_sum], rax
    mov [ping_max], rax
    mov qword [ping_min], -1
    mov dword [ping_active], 1
    call ping_send
    pop rcx
    ret

; ping_send: the next echo request, stamped with the TSC. Preserves all but
; RAX.
ping_send:
    push rcx
    push rdx
    push rsi
    push rdi
    inc dword [ping_seq]
    mov dword [ping_waiting], 1
    lea rdi, [net_frame + NET_PAYLOAD]
    mov word [rdi], 0x0008              ; echo request, code 0
    mov word [rdi + 2], 0
    mov ax, [ping_id]
    mov [rdi + 4], ax
    mov eax, [ping_seq]
    xchg al, ah
    mov [rdi + 6], ax
    RDTSC64
    mov [rdi + 8], rax                  ; when it left
    mov ecx, 16
.fill:
    mov [rdi + rcx], cl
    inc ecx
    cmp ecx, 8 + PING_DATA
    jb .fill
    mov rsi, rdi
    mov ecx, 8 + PING_DATA
    xor eax, eax
    call net_sum
    call net_fold
    mov [rsi + 2], ax
    mov edi, [ping_ip]
    mov esi, 1
    call ip_send
    jc .no_route
    call net_clock
    add rax, [net_second]
    mov [ping_next], rax
    jmp .out
.no_route:
    KLOG "ping: no route to %I (no gateway)", qword [ping_ip]
    call ping_end
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ping_tick: a second after each request, the next (or the end)
ping_tick:
    mov rax, [ping_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    cmp dword [ping_waiting], 0
    je .next
    mov eax, [ping_seq]
    KLOG "%I: no reply to %u", qword [ping_ip], rax
    mov dword [ping_waiting], 0
.next:
    mov eax, [ping_seq]
    cmp eax, [ping_count]
    jae ping_end
    jmp ping_send
.out:
    ret

; ping_reply(RBX, RSI = message, ECX = bytes, RDI = IP header): an echo reply
ping_reply:
    cmp dword [ping_active], 0
    je .out
    cmp ecx, 16
    jb .out
    mov ax, [rsi + 4]
    cmp ax, [ping_id]
    jne .out
    push r12
    RDTSC64
    sub rax, [rsi + 8]                  ; there and back
    call ticks_to_us
    mov r12, rax
    add [ping_sum], rax
    cmp rax, [ping_min]
    jae .min
    mov [ping_min], rax
.min:
    cmp rax, [ping_max]
    jbe .max
    mov [ping_max], rax
.max:
    inc dword [ping_got]
    movzx ecx, word [rsi + 6]
    xchg cl, ch
    cmp ecx, [ping_seq]
    jne .late
    mov dword [ping_waiting], 0
.late:
    mov rax, r12                        ; hundredths of a millisecond
    xor edx, edx
    mov r8d, 10
    div r8
    mov r8, rax
    mov eax, [rdi + 12]
    movzx edx, byte [rdi + 8]
    KLOG "reply from %I: seq %u, ttl %u, %h ms", rax, rcx, rdx, r8
    pop r12
    mov eax, [ping_seq]                 ; the last one answered: done
    cmp eax, [ping_count]
    jb .out
    cmp dword [ping_waiting], 0
    je ping_end
.out:
    ret

; ping_error(RBX, RSI = message, ECX = bytes, RDI = IP header): unreachable,
; or the time to live ran out, about one of our requests?
ping_error:
    cmp dword [ping_active], 0
    je .out
    cmp ecx, 8 + 20 + 8
    jb .out
    lea rdx, [rsi + 8]                  ; the packet it is about
    cmp byte [rdx + 9], 1
    jne .out
    movzx eax, byte [rdx]
    and eax, 15
    shl eax, 2
    lea r8d, [eax + 16]
    cmp r8d, ecx
    ja .out
    add rdx, rax
    cmp byte [rdx], 8
    jne .out
    mov ax, [rdx + 4]
    cmp ax, [ping_id]
    jne .out
    mov dword [ping_waiting], 0
    mov eax, [rdi + 12]
    lea rdx, [str_unreachable]
    cmp byte [rsi], 3
    je .say
    lea rdx, [str_ttl_out]
.say:
    KLOG "%I: %s", rax, rdx
.out:
    ret

; ping_end: the summary. Preserves all.
ping_end:
    cmp dword [ping_active], 0
    je .out
    push rax
    push rcx
    push rdx
    push r8
    push r9
    mov dword [ping_active], 0
    mov qword [ping_next], 0
    mov eax, [ping_seq]
    mov ecx, [ping_got]
    test ecx, ecx
    jnz .answered
    KLOG "%u sent, none answered", rax
    jmp .done
.answered:
    push rax
    mov rax, [ping_sum]
    xor edx, edx
    div rcx
    xor edx, edx
    mov r8d, 10
    div r8
    mov r9, rax                         ; average
    mov rax, [ping_min]
    xor edx, edx
    div r8
    mov rdx, rax
    mov rax, [ping_max]
    push rdx
    xor edx, edx
    div r8
    pop rdx
    mov r8, rax
    pop rax
    KLOG "%u sent, %u answered; round trip min %h, average %h, max %h ms", rax, rcx, rdx, r9, r8
.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; -----------------------------------------------------------------------------
;  Shell
; -----------------------------------------------------------------------------

; ip_parse(RSI = text) -> EAX = a dotted-quad address, RSI just past it;
; CF if the text does not start with one. Preserves others.
ip_parse:
    push rcx
    push rdx
    push r8
    xor r8d, r8d
    xor ecx, ecx                        ; bits done
.octet:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .bad
    xor edx, edx
.digit:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .octet_done
    imul edx, edx, 10
    add edx, eax
    cmp edx, 255
    ja .bad
    inc rsi
    jmp .digit
.octet_done:
    shl edx, cl
    or r8d, edx
    add ecx, 8
    cmp ecx, 32
    je .done
    cmp byte [rsi], '.'
    jne .bad
    inc rsi
    jmp .octet
.done:
    mov eax, r8d
    clc
    jmp .out
.bad:
    stc
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; net_ready -> CF (having said why) if there is no interface or no address
net_ready:
    cmp dword [nic_count], 0
    je .no_nic
    cmp dword [net_ip], 0
    je .no_address
    clc
    ret
.no_nic:
    KLOG "no network interface ('net' lists what Axiom drives)"
    stc
    ret
.no_address:
    KLOG "no address yet ('net' says why)"
    stc
    ret

; net_show_address: the address line(s) of 'net' and 'ip'
net_show_address:
    mov eax, [net_ip]
    test eax, eax
    jnz .have
    cmp dword [dh_state], DH_OFF
    je .none
    KLOG "address: none yet, DHCP is asking"
    ret
.none:
    KLOG "address: none ('dhcp' asks for one, 'ip' sets one)"
    ret
.have:
    call net_peers
    popcnt ecx, [net_mask]
    KLOG "address %I/%u, gateway %s, DNS %s", rax, rcx, rdx, rsi
    cmp byte [net_static], 0
    je .dhcp
    KLOG "        set by hand"
    ret
.dhcp:
    call net_clock
    mov rcx, [dh_expire]
    sub rcx, rax
    jbe .out
    mov rax, rcx
    xor edx, edx
    div qword [net_second]              ; seconds
    xor edx, edx
    mov ecx, 60
    div rcx                             ; minutes
    xor edx, edx
    div rcx                             ; hours, and minutes left over
    KLOG "        from DHCP server %I, lease ends in %u h %u min", qword [dh_server], rax, rdx
.out:
    ret

; net_peers -> RDX = the gateway, RSI = the DNS server, as text ("none" if
; unset). Preserves others.
net_peers:
    push rax
    push rdi
    lea rdi, [gw_text]
    mov eax, [net_gw]
    call ip_or_none
    lea rdi, [dns_text]
    mov eax, [net_dns]
    call ip_or_none
    lea rdx, [gw_text]
    lea rsi, [dns_text]
    pop rdi
    pop rax
    ret

; ip_or_none(EAX = address, RDI = 16-byte buffer): "a.b.c.d", or "none" for
; 0. Preserves all.
ip_or_none:
    push rax
    test eax, eax
    jz .none
    SPRINTF rdi, "%I", rax
    pop rax
    ret
.none:
    mov dword [rdi], 'none'
    mov byte [rdi + 4], 0
    pop rax
    ret

cmd_net:
    push rbx
    push r12
    cmp dword [nic_count], 0
    jne .list
    KLOG "no network interface (Axiom drives Realtek RTL8111/8168 Ethernet)"
    jmp .out
.list:
    xor r12d, r12d
.nic:
    imul rbx, r12, NI_SIZE
    lea rax, [nics]
    add rbx, rax
    mov rdx, [rbx + NI_NAME]
    movzx eax, word [rbx + NI_IDS]
    movzx ecx, word [rbx + NI_IDS + 2]
    mov esi, [rbx + NI_MSI]
    lea rdi, [usb_irq_names]
    mov rsi, [rdi + rsi * 8]
    KLOG "net%u  %s (%04x:%04x), %s", r12, rdx, rax, rcx, rsi
    lea rax, [rbx + NI_MAC]
    mov ecx, [rbx + NI_SPEED]
    test ecx, ecx
    jg .up
    KLOG "      MAC %M, no link", rax
    jmp .counts
.up:
    lea rdx, [str_half]
    cmp dword [rbx + NI_DUPLEX], 0
    je .duplex
    lea rdx, [str_full]
.duplex:
    KLOG "      MAC %M, link %u Mbit/s %s duplex", rax, rcx, rdx
.counts:
    KLOG "      in %u frames (%b), out %u (%b), %u dropped", qword [rbx + NI_RXPK], qword [rbx + NI_RXBY], qword [rbx + NI_TXPK], qword [rbx + NI_TXBY], qword [rbx + NI_DROP]
    inc r12d
    cmp r12d, [nic_count]
    jb .nic
    call net_show_address
.out:
    pop r12
    pop rbx
    ret

; ip [a.b.c.d/n [gateway [dns]]]
cmd_ip:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp dword [nic_count], 0
    jne .args
    KLOG "no network interface ('net' lists what Axiom drives)"
    jmp .out
.args:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    jne .set
    call net_show_address
    jmp .out
.set:
    call arg_split
    mov r12, rdi                        ; the rest
    call ip_parse
    jc .usage
    test eax, eax
    jz .usage
    mov r13d, eax                       ; the address
    cmp byte [rsi], '/'
    jne .usage
    inc rsi
    call arg_uint
    jc .usage
    test eax, eax
    jz .usage
    cmp eax, 32
    ja .usage
    mov ecx, 32
    sub ecx, eax
    mov r14d, -1
    shl r14d, cl
    bswap r14d                          ; the mask, as it travels
    xor ebx, ebx                        ; no gateway
    mov rsi, r12
    cmp byte [rsi], 0
    je .dns
    call arg_split
    mov r12, rdi
    call ip_parse
    jc .usage
    cmp byte [rsi], 0
    jne .usage
    mov ebx, eax
.dns:
    mov r15d, ebx                       ; the DNS server: the gateway, unless named
    mov rsi, r12
    cmp byte [rsi], 0
    je .apply
    call arg_split
    call ip_parse
    jc .usage
    cmp byte [rsi], 0
    jne .usage
    mov r15d, eax
.apply:
    mov dword [dh_state], DH_OFF
    mov qword [dhcp_next], 0
    mov byte [net_static], 1
    mov [net_ip], r13d
    mov [net_mask], r14d
    mov [net_gw], ebx
    mov [net_dns], r15d
    call arp_flush
    call net_show_address
    jmp .out
.usage:
    KLOG "usage: ip <address>/<prefix> [gateway] [dns], e.g. ip 192.168.1.50/24 192.168.1.1"
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

cmd_dhcp:
    cmp dword [nic_count], 0
    jne .have
    KLOG "no network interface ('net' lists what Axiom drives)"
    ret
.have:
    mov rax, [net_nic]
    cmp dword [rax + NI_SPEED], 0
    jg dhcp_start
    mov byte [net_static], 0
    KLOG "dhcp: no link yet; it asks once the cable is in"
    ret

; ping <address or name> [count]
cmd_ping:
    push r12
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call arg_split
    mov r12, rsi                        ; the host
    mov dword [ping_count], 4
    cmp byte [rdi], 0
    je .go
    mov rsi, rdi
    call arg_uint
    jc .usage
    test eax, eax
    jz .usage
    cmp eax, 1000
    ja .usage
    mov [ping_count], eax
.go:
    call net_ready
    jc .out
    call ping_end                       ; one at a time
    mov rsi, r12
    call ip_parse
    jc .name
    cmp byte [rsi], 0
    jne .name
    call ping_begin
    jmp .out
.name:
    mov rsi, r12
    mov edx, 1
    call dns_lookup
    jmp .out
.usage:
    KLOG "usage: ping <address or name> [count]"
.out:
    pop r12
    ret

; host <name>
cmd_host:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call arg_split
    call net_ready
    jc .out
    xor edx, edx
    jmp dns_lookup
.usage:
    KLOG "usage: host <name>, e.g. host example.com"
.out:
    ret

cmd_arp:
    push rbx
    push r12
    push r13
    lea rbx, [arp_cache]
    xor r12d, r12d
    xor r13d, r13d                      ; how many
.slot:
    cmp dword [rbx + AR_IP], 0
    je .next
    inc r13d
    call net_clock
    sub rax, [rbx + AR_TIME]
    xor edx, edx
    div qword [net_second]
    mov ecx, [rbx + AR_IP]
    lea rdx, [rbx + AR_MAC]
    KLOG "  %-15I  %M  learned %u s ago", rcx, rdx, rax
.next:
    add rbx, AR_SIZE
    inc r12d
    cmp r12d, ARP_SLOTS
    jb .slot
    test r13d, r13d
    jnz .out
    KLOG "no neighbours known yet"
.out:
    pop r13
    pop r12
    pop rbx
    ret

; lease_text(EAX = seconds) -> RAX = "N h" or "N min", in lease_buf.
; Preserves others.
lease_text:
    push rcx
    push rdx
    xor edx, edx
    mov ecx, 3600
    div ecx
    test eax, eax
    jz .minutes
    SPRINTF lease_buf, "%u h", rax
    jmp .out
.minutes:
    mov eax, edx
    xor edx, edx
    mov ecx, 60
    div ecx
    SPRINTF lease_buf, "%u min", rax
.out:
    lea rax, [lease_buf]
    pop rdx
    pop rcx
    ret

section .rodata
dhcp_tail:      db 12, 5, 'axiom'               ; host name
                db 55, 4, 1, 3, 6, 51           ; mask, router, DNS, lease
                db 255
DHCP_TAIL       equ $ - dhcp_tail
str_unreachable: db 'destination unreachable', 0
str_ttl_out:    db 'time to live ran out on the way', 0

section .bss
alignb 8
dh_expire:      resq 1                  ; TSC
ping_sum:       resq 1                  ; microseconds
ping_min:       resq 1
ping_max:       resq 1
dh_state:       resd 1
dh_tries:       resd 1
dh_xid:         resd 1
dh_offer:       resd 1
dh_server:      resd 1
dh_lease:       resd 1                  ; seconds
dh_type:        resd 1                  ; from the last message's options
dh_o_mask:      resd 1
dh_o_router:    resd 1
dh_o_dns:       resd 1
dh_o_lease:     resd 1
dh_o_server:    resd 1
dns_state:      resd 1                  ; 1 while a question is out
dns_tries:      resd 1
dns_then:       resd 1                  ; 0 print the answer, 1 ping it, 2 http
dns_server:     resd 1
dns_port:       resd 1
ping_active:    resd 1
ping_count:     resd 1
ping_seq:       resd 1                  ; requests sent
ping_got:       resd 1                  ; replies
ping_waiting:   resd 1                  ; the last request is unanswered
ping_ip:        resd 1
dns_id:         resw 1
ping_id:        resw 1
net_static:     resb 1                  ; the address was set by hand
lease_buf:      resb 32
gw_text:        resb 16
dns_text:       resb 16
dns_name:       resb 256
