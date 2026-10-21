; =============================================================================
;  ip6.asm - IPv6 beside IPv4, on the interface with the address: a
;  link-local address from the MAC (EUI-64), checked to be free (DAD); a
;  router asked for (RS) and its advertisements (RA) taken in: a global
;  address from the first /64 prefix offered for it (SLAAC, checked the
;  same way), the router, the prefix on the link, the hop limit, the MTU
;  and a DNS server (RDNSS). Neighbours are found and answered with NDP
;  (NS, NA), much as ARP does for IPv4; MLD reports say which group we
;  listen on, so switches that watch for them still pass us what NDP sends.
;  ICMPv6 echo is answered, and its replies and errors go to ping; UDP to
;  DNS, TCP to tcp.asm.
;
;  Above IP, an address is 16 bytes as it travels, for either family: an
;  IPv4 one as ::ffff:a.b.c.d (addr_is4, addr_set4), so that DNS, ping,
;  TCP, http and sockets keep one kind of address. Main loop only.
; =============================================================================

ETYPE_IP6       equ 0xDD86              ; 0x86DD as it travels
NET6_PAYLOAD    equ ETH_HLEN + 40       ; an IPv6 payload in net_frame
UDP6_PAYLOAD    equ NET6_PAYLOAD + 8
IP6_MAXDATA     equ 1460                ; what fits after the IPv6 header
TCP6_MSS        equ 1440

; an address of ours
A6_NONE         equ 0
A6_TENTATIVE    equ 1                   ; being checked: not used yet
A6_READY        equ 2

RS_TRIES        equ 3
RS_GAP_S        equ 4

; the neighbour cache
ND_SLOTS        equ 16
ND_IP           equ 0                   ; 16 bytes
ND_MAC          equ 16                  ; 6 bytes
ND_TIME         equ 24                  ; TSC when learned, 0 = free
ND_SIZE         equ 32

; frames waiting for a neighbour's answer
ND_WAITS        equ 4
NDW_IP           equ 0                   ; the next hop asked about
NDW_LEN          equ 16                  ; 0 = free
NDW_TRIES        equ 20
NDW_NEXT         equ 24                  ; TSC: ask again, or give up
NDW_FRAME        equ 32
NDW_SIZE         equ NDW_FRAME + NET_FRAME

section .text

; -----------------------------------------------------------------------------
;  Addresses
; -----------------------------------------------------------------------------

; addr_is4(RSI = address) -> ZF if it is IPv4 (::ffff:a.b.c.d). Preserves all.
addr_is4:
    cmp qword [rsi], 0
    jne .out
    cmp dword [rsi + 8], 0xFFFF0000
.out:
    ret

; addr_set4(RDI = address, EAX = IPv4 as it travels). Preserves all.
addr_set4:
    mov qword [rdi], 0
    mov dword [rdi + 8], 0xFFFF0000
    mov [rdi + 12], eax
    ret

; addr_copy(RDI = to, RSI = from). Preserves all.
addr_copy:
    push rax
    mov rax, [rsi]
    mov [rdi], rax
    mov rax, [rsi + 8]
    mov [rdi + 8], rax
    pop rax
    ret

; addr_eq(RSI, RDI) -> ZF if the same. Preserves all.
addr_eq:
    push rax
    mov rax, [rsi]
    cmp rax, [rdi]
    jne .out
    mov rax, [rsi + 8]
    cmp rax, [rdi + 8]
.out:
    pop rax
    ret

; addr_null(RSI) -> ZF if it is :: (none). Preserves all.
addr_null:
    push rax
    mov rax, [rsi]
    or rax, [rsi + 8]
    pop rax
    ret

; addr_parse(RSI = text, RDI = 16 bytes) -> CF unless the text is an
; address and nothing more: a.b.c.d, an IPv6 address, or one in brackets.
; Preserves all.
addr_parse:
    push rax
    push rsi
    call ip_parse
    jc .six
    cmp byte [rsi], 0
    jne .six
    call addr_set4
    jmp .ok
.six:
    mov rsi, [rsp]
    cmp byte [rsi], '['
    jne .bare
    inc rsi
    call ip6_parse
    jc .bad
    cmp byte [rsi], ']'
    jne .bad
    inc rsi
    jmp .end
.bare:
    call ip6_parse
    jc .bad
.end:
    cmp byte [rsi], 0
    jne .bad
.ok:
    clc
    pop rsi
    pop rax
    ret
.bad:
    stc
    pop rsi
    pop rax
    ret

; hex_value(AL = a character) -> EAX = its value, CF if not a hex digit.
; Preserves others.
hex_value:
    movzx eax, al
    sub eax, '0'
    cmp eax, 9
    jbe .ok
    add eax, '0'
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja .bad
    add eax, 10
.ok:
    clc
    ret
.bad:
    stc
    ret

; ip6_parse(RSI = text, RDI = 16 bytes) -> the address, RSI just past it;
; CF if the text does not start with one (RDI untouched). Groups of one to
; four hex digits, '::' once for a run of zeros. Preserves others.
ip6_parse:
    push rax
    push rbx
    push rcx
    push rdx
    push r8
    push r9
    push r10
    sub rsp, 16                         ; the groups, as parsed
    mov r10, rsi
    xor ecx, ecx                        ; groups
    mov r8d, -1                         ; where '::' was
    cmp word [rsi], 0x3A3A              ; '::'
    jne .first
    xor r8d, r8d
    add rsi, 2
    mov al, [rsi]
    call hex_value
    jc .end                             ; "::" alone
    jmp .group
.first:
    mov al, [rsi]
    call hex_value
    jc .bad
.group:
    xor edx, edx
    xor ebx, ebx                        ; digits
.digit:
    mov al, [rsi]
    call hex_value
    jc .group_end
    inc ebx
    cmp ebx, 4
    ja .bad
    shl edx, 4
    or edx, eax
    inc rsi
    jmp .digit
.group_end:
    cmp ecx, 8
    jae .bad
    mov [rsp + rcx * 2], dx
    inc ecx
    cmp byte [rsi], ':'
    jne .end
    cmp byte [rsi + 1], ':'
    je .double
    inc rsi
    mov al, [rsi]                       ; one ':' comes before a group
    call hex_value
    jc .bad
    jmp .group
.double:
    test r8d, r8d
    jns .bad                            ; '::' only once
    mov r8d, ecx
    add rsi, 2
    mov al, [rsi]
    call hex_value
    jc .end
    jmp .group
.end:
    mov r9d, ecx                        ; R9 = groups
    test r8d, r8d
    js .full
    cmp ecx, 7
    ja .bad
    jmp .write
.full:
    cmp ecx, 8
    jne .bad
    mov r8d, ecx                        ; all before the (absent) '::'
.write:
    xor eax, eax
    mov [rdi], rax
    mov [rdi + 8], rax
    xor edx, edx
.head:
    cmp edx, r8d
    jae .tail
    mov ax, [rsp + rdx * 2]
    xchg al, ah
    mov [rdi + rdx * 2], ax
    inc edx
    jmp .head
.tail:                                  ; groups [R8, R9) end the address
    mov ebx, 8
    sub ebx, r9d
.tail_group:
    cmp edx, r9d
    jae .ok
    mov ax, [rsp + rdx * 2]
    xchg al, ah
    lea ecx, [ebx + edx]
    mov [rdi + rcx * 2], ax
    inc edx
    jmp .tail_group
.ok:
    add rsp, 16
    clc
    jmp .out
.bad:
    mov rsi, r10
    add rsp, 16
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ip6_text(RSI = address, RDI = 48 bytes) -> RAX = the length of its text,
; NUL-ended: RFC 5952's form (lower case, no leading zeros, the longest run
; of two or more zero groups as '::'), or a.b.c.d for IPv4. Preserves others.
ip6_text:
    call addr_is4
    jne .six
    mov eax, [rsi + 12]
    SPRINTF rdi, "%I", rax
    ret
.six:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11
    push rdi                            ; where it starts
    mov r8d, 8                          ; the longest run: where (8 = none)
    xor r9d, r9d                        ; and how long
    xor ecx, ecx
.scan:
    cmp ecx, 8
    jae .scanned
    cmp word [rsi + rcx * 2], 0
    je .run
    inc ecx
    jmp .scan
.run:
    mov edx, ecx
.run_more:
    inc ecx
    cmp ecx, 8
    jae .run_end
    cmp word [rsi + rcx * 2], 0
    je .run_more
.run_end:
    mov eax, ecx
    sub eax, edx
    cmp eax, r9d
    jbe .scan
    mov r9d, eax
    mov r8d, edx
    jmp .scan
.scanned:
    cmp r9d, 2
    jae .write
    mov r8d, 8
.write:
    xor r10d, r10d                      ; the group
    xor ebx, ebx                        ; 1: a ':' before the next
    lea r11, [hex_digits]
.group:
    cmp r10d, 8
    jae .end
    cmp r10d, r8d
    jne .digits
    mov word [rdi], 0x3A3A
    add rdi, 2
    add r10d, r9d
    xor ebx, ebx
    jmp .group
.digits:
    test ebx, ebx
    jz .value
    mov byte [rdi], ':'
    inc rdi
.value:
    movzx edx, word [rsi + r10 * 2]
    xchg dl, dh
    mov ecx, 12
.lead:                                  ; no leading zeros, one digit at least
    test ecx, ecx
    jz .nibble
    mov eax, edx
    shr eax, cl
    jnz .nibble
    sub ecx, 4
    jmp .lead
.nibble:
    mov eax, edx
    shr eax, cl
    and eax, 15
    mov al, [r11 + rax]
    mov [rdi], al
    inc rdi
    sub ecx, 4
    jns .nibble
    mov ebx, 1
    inc r10d
    jmp .group
.end:
    mov byte [rdi], 0
    mov rax, rdi
    pop rdx
    sub rax, rdx
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; ip6_or_none(RSI = address, RDI = 48 bytes): its text, or "none" for ::.
; Preserves all.
ip6_or_none:
    push rax
    call addr_null
    jz .none
    call ip6_text
    pop rax
    ret
.none:
    mov dword [rdi], 'none'
    mov byte [rdi + 4], 0
    pop rax
    ret

; ip6_linklocal(RSI = address) -> ZF if it is fe80::/10. Preserves all.
ip6_linklocal:
    push rax
    movzx eax, word [rsi]
    and eax, 0xC0FF
    cmp eax, 0x80FE
    pop rax
    ret

; ip6_solicited(RSI = address, RDI = 16 bytes): its solicited-node group,
; ff02::1:ffXX:XXXX. Preserves all.
ip6_solicited:
    push rax
    mov rax, 0x02FF
    mov [rdi], rax
    mov dword [rdi + 8], 0x01000000
    mov eax, [rsi + 12]
    mov al, 0xFF
    mov [rdi + 12], eax
    pop rax
    ret

; ip6_mine(RSI = address) -> RDX = which of ours it is, EAX = its state;
; ZF (EAX = 0) if it is not ours. Preserves others.
ip6_mine:
    push rdi
    lea rdi, [ip6_ll]
    movzx eax, byte [ip6_ll_state]
    test eax, eax
    jz .gua
    call addr_eq
    je .found
.gua:
    lea rdi, [ip6_gua]
    movzx eax, byte [ip6_gua_state]
    test eax, eax
    jz .none
    call addr_eq
    je .found
.none:
    xor eax, eax
    pop rdi
    ret
.found:
    mov rdx, rdi
    test eax, eax
    pop rdi
    ret

; ip6_ours(RSI = a destination) -> ZF if it is for us: one of our
; addresses, all nodes, or our solicited-node group. Preserves all.
ip6_ours:
    push rax
    push rdi
    lea rdi, [ip6_all_nodes]
    call addr_eq
    je .out
    mov rax, 0x02FF
    cmp [rsi], rax
    jne .unicast
    cmp dword [rsi + 8], 0x01000000
    jne .unicast
    cmp byte [rsi + 12], 0xFF
    jne .unicast
    mov eax, [rsi + 12]                 ; the last three bytes, ours?
    xor eax, [ip6_ll + 12]
    shr eax, 8
    jz .out
    mov eax, [rsi + 12]
    xor eax, [ip6_gua + 12]
    shr eax, 8
    jz .out
    jmp .no
.unicast:
    cmp byte [ip6_ll_state], A6_NONE
    je .gua
    lea rdi, [ip6_ll]
    call addr_eq
    je .out
.gua:
    cmp byte [ip6_gua_state], A6_NONE
    je .no
    lea rdi, [ip6_gua]
    call addr_eq
    jmp .out
.no:
    or eax, 1                           ; ZF clear
.out:
    pop rdi
    pop rax
    ret

; ip6_source(RDI = destination) -> R9 = the address of ours to send from,
; CF if there is none ready: link-local for link-local and multicast
; destinations, else the global one. Preserves others.
ip6_source:
    push rsi
    lea r9, [ip6_ll]
    cmp byte [rdi], 0xFF
    je .ll
    mov rsi, rdi
    call ip6_linklocal
    je .ll
    lea r9, [ip6_gua]
    cmp byte [ip6_gua_state], A6_READY
    jne .none
    clc
    pop rsi
    ret
.ll:
    cmp byte [ip6_ll_state], A6_READY
    jne .none
    clc
    pop rsi
    ret
.none:
    stc
    pop rsi
    ret

; ip6_up -> CF unless IPv6 can be used: the link-local address is ready.
; Preserves all.
ip6_up:
    cmp byte [ip6_ll_state], A6_READY
    je .yes
    stc
    ret
.yes:
    clc
    ret

; -----------------------------------------------------------------------------
;  Out
; -----------------------------------------------------------------------------

; ip6_pseudo(RDI = IPv6 header, its addresses filled in; ECX = bytes of the
; upper layer; EAX = its protocol) -> EAX = the pseudo-header's sum,
; unfolded. Preserves others.
ip6_pseudo:
    push rcx
    push rdx
    push rsi
    mov edx, eax
    shl edx, 8
    mov eax, ecx
    xchg al, ah
    movzx eax, ax
    add eax, edx
    lea rsi, [rdi + 8]
    mov ecx, 32
    call net_sum
    pop rsi
    pop rdx
    pop rcx
    ret

; ip6_send(RDI = destination, ESI = protocol, ECX = bytes of payload at
; net_frame + NET6_PAYLOAD, EDX = where in it the checksum goes, or -1) ->
; CF if there is no address to send from or no route. A frame for a
; neighbour not yet known waits for NDP. Preserves all but RAX.
ip6_send:
    push r9
    push r10
    call ip6_source
    jc .out
    lea r10, [net_frame]
    call ip6_emit
.out:
    pop r10
    pop r9
    ret

; ip6_emit(R10 = frame, RDI = destination, R9 = source, ESI = protocol,
; ECX = bytes of payload at R10 + NET6_PAYLOAD, EDX = the checksum's offset
; in it or -1) -> CF if there is no route. The hop limit is 255 for NDP, 1
; for MLD (behind its hop-by-hop header, protocol 0), else the router's.
; Preserves all but RAX.
ip6_emit:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea r8, [r10 + ETH_HLEN]
    mov dword [r8], 0x60                ; version 6, no class, no flow
    mov eax, ecx
    xchg al, ah
    mov [r8 + 4], ax
    mov [r8 + 6], sil
    mov eax, [ip6_hops]
    test esi, esi
    jnz .not_mld
    mov eax, 1
    jmp .hops
.not_mld:
    cmp esi, 58
    jne .hops
    movzx ebx, byte [r8 + 40]
    sub ebx, 133
    cmp ebx, 4
    ja .hops
    mov eax, 255
.hops:
    mov [r8 + 7], al
    mov rax, [r9]
    mov [r8 + 8], rax
    mov rax, [r9 + 8]
    mov [r8 + 16], rax
    mov rax, [rdi]
    mov [r8 + 24], rax
    mov rax, [rdi + 8]
    mov [r8 + 32], rax
    test edx, edx
    js .summed
    lea rbx, [r8 + 40]
    mov word [rbx + rdx], 0
    push rdi
    mov rdi, r8
    movzx eax, sil
    call ip6_pseudo
    pop rdi
    push rsi
    mov rsi, rbx
    call net_sum
    pop rsi
    call net_fold
    test eax, eax
    jnz .sum
    mov eax, 0xFFFF                     ; the same in ones' complement; never 0
.sum:
    mov [rbx + rdx], ax
.summed:
    add ecx, ETH_HLEN + 40              ; the frame's bytes
    cmp byte [rdi], 0xFF
    je .multicast
    mov rsi, rdi                        ; the next hop: the destination if
    call ip6_linklocal                  ; it is on the link, else the router
    je .resolve
    cmp byte [ip6_prefix_on], 0
    je .router
    mov rax, [rdi]
    cmp rax, [ip6_prefix]
    je .resolve
.router:
    lea rsi, [ip6_router]
    call addr_null
    jz .no_route
.resolve:
    call nd_find
    jc .ask
    lea rdi, [rdx + ND_MAC]
    jmp .send
.ask:
    call nd_queue
    clc
    jmp .out
.multicast:
    lea rdi, [ip6_mmac]                 ; 33:33 and the group's last 4 bytes
    mov word [rdi], 0x3333
    mov eax, [r8 + 36]
    mov [rdi + 2], eax
.send:
    mov rdx, r10
    mov esi, ETYPE_IP6
    call eth_send
    clc
    jmp .out
.no_route:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; udp6_send(RDI = destination, ESI = source port, EDX = destination port,
; ECX = bytes of payload at net_frame + UDP6_PAYLOAD) -> CF if there is no
; route. Preserves all but RAX.
udp6_send:
    push rcx
    push rdx
    push rsi
    push r8
    lea r8, [net_frame + NET6_PAYLOAD]
    mov eax, esi
    xchg al, ah
    mov [r8], ax
    mov eax, edx
    xchg al, ah
    mov [r8 + 2], ax
    add ecx, 8
    mov eax, ecx
    xchg al, ah
    mov [r8 + 4], ax
    mov esi, 17
    mov edx, 6
    call ip6_send
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  In
; -----------------------------------------------------------------------------

; ip6_input(RBX, RSI = frame, ECX = bytes): from net_receive. The handlers
; get RDI = the IPv6 header, RSI = their part, ECX = its bytes.
ip6_input:
    sub ecx, ETH_HLEN
    lea rdi, [rsi + ETH_HLEN]
    cmp ecx, 40
    jb .out
    mov al, [rdi]
    shr al, 4
    cmp al, 6
    jne .out
    movzx eax, word [rdi + 4]
    xchg al, ah
    lea edx, [eax + 40]
    cmp edx, ecx
    ja .out
    mov ecx, eax                        ; the rest is padding
    lea rsi, [rdi + 24]
    call ip6_ours
    jne .out
    movzx eax, byte [rdi + 6]
    lea rsi, [rdi + 40]
.header:
    cmp eax, 58
    je icmp6_input
    cmp eax, 6
    je tcp6_input
    cmp eax, 17
    je udp6_input
    test eax, eax                       ; hop-by-hop options
    je .skip
    cmp eax, 43                         ; routing
    je .skip
    cmp eax, 60                         ; destination options
    jne .out                            ; fragments (44) and others: dropped
.skip:
    cmp ecx, 8
    jb .out
    movzx edx, byte [rsi + 1]
    lea edx, [edx * 8 + 8]
    cmp edx, ecx
    ja .out
    movzx eax, byte [rsi]
    add rsi, rdx
    sub ecx, edx
    jmp .header
.out:
    ret

; udp6_input(RBX, RDI = IPv6 header, RSI = datagram, ECX = bytes): DNS
; answers, to the ports questions go from
udp6_input:
    cmp ecx, 8
    jb .out
    movzx eax, word [rsi + 4]
    xchg al, ah
    cmp eax, 8
    jb .out
    cmp eax, ecx
    ja .out
    mov ecx, eax
    cmp word [rsi + 6], 0               ; IPv6 has no "no checksum"
    je .out
    mov eax, 17
    call ip6_pseudo
    call net_sum
    call net_fold
    test eax, eax
    jnz .out
    cmp byte [rdi + 24], 0xFF           ; to us alone
    je .out
    movzx eax, word [rsi + 2]
    xchg al, ah
    lea rdx, [rdi + 8]                  ; from whom
    add rsi, 8
    sub ecx, 8
    call lx_udp_input                   ; a Linux program's port?
    jc .out
    cmp eax, 49152
    jae dns_input
.out:
    ret

; icmp6_input(RBX, RDI = IPv6 header, RSI = message, ECX = bytes)
icmp6_input:
    cmp ecx, 8
    jb .out
    mov eax, 58
    call ip6_pseudo
    call net_sum
    call net_fold
    test eax, eax
    jnz .out
    movzx eax, byte [rsi]
    cmp eax, 128
    je .echo
    cmp eax, 129
    je .reply
    cmp eax, 1                          ; unreachable
    je ping_error6
    cmp eax, 3                          ; hop limit reached
    je ping_error6
    cmp eax, 130                        ; a listener query: report again
    je mld_report
    cmp eax, 134
    je ra_input
    cmp eax, 135
    je ns_input
    cmp eax, 136
    je na_input
.out:
    ret
.echo:                                  ; asked: the same message back
    cmp byte [rdi + 24], 0xFF           ; to us, not to a group
    je .out
    cmp ecx, IP6_MAXDATA
    ja .out
    push rsi
    lea rsi, [rdi + 8]
    lea rdi, [ip6_peer]
    call addr_copy
    pop rsi
    lea rdi, [net_frame + NET6_PAYLOAD]
    push rcx
    rep movsb
    pop rcx
    mov byte [net_frame + NET6_PAYLOAD], 129
    lea rdi, [ip6_peer]
    mov esi, 58
    mov edx, 2
    jmp ip6_send
.reply:
    lea rdx, [rdi + 8]
    movzx r8d, byte [rdi + 7]
    jmp ping_reply

; -----------------------------------------------------------------------------
;  NDP
; -----------------------------------------------------------------------------

; nd_lla(RSI = an NDP message, ECX = its bytes, EDX = where its options
; start, AL = the option: 1 source, 2 target link-layer address) -> RCX =
; the MAC in it, CF if it has none. Preserves others.
nd_lla:
    push rax
    push rdx
    push r8
    push r9
    mov r9d, eax
.next:
    lea eax, [edx + 2]
    cmp eax, ecx
    ja .none
    movzx eax, byte [rsi + rdx + 1]
    test eax, eax
    jz .none
    shl eax, 3
    lea r8d, [edx + eax]
    cmp r8d, ecx
    ja .none
    cmp [rsi + rdx], r9b
    jne .skip
    cmp eax, 8
    jne .skip
    lea rcx, [rsi + rdx + 2]
    clc
    jmp .out
.skip:
    mov edx, r8d
    jmp .next
.none:
    stc
.out:
    pop r9
    pop r8
    pop rdx
    pop rax
    ret

; ns_input(RBX, RDI = IPv6 header, RSI = message, ECX = bytes): a neighbour
; solicitation. For an address of ours that is ready: an advertisement
; back; from :: (someone checking it is free), to all nodes. Someone
; checking an address we are still checking: it is theirs.
ns_input:
    cmp byte [rdi + 7], 255
    jne .out
    cmp ecx, 24
    jb .out
    cmp byte [rsi + 1], 0
    jne .out
    push rsi
    add rsi, 8                          ; the target
    call ip6_mine
    pop rsi
    jz .out
    push rsi
    lea rsi, [rdi + 8]
    call addr_null
    pop rsi
    jz .dad
    cmp eax, A6_READY
    jne .out
    push rdx
    mov al, 1
    mov edx, 24
    call nd_lla
    pop rdx
    jc .answer
    push rsi
    lea rsi, [rdi + 8]
    call nd_learn
    pop rsi
.answer:
    lea rsi, [rdi + 8]
    lea rdi, [ip6_peer]
    call addr_copy
    mov eax, 0x60                       ; solicited, override
    jmp nd_advertise
.dad:
    cmp eax, A6_TENTATIVE
    je ip6_conflict
    lea rdi, [ip6_all_nodes]
    mov eax, 0x20                       ; override
    jmp nd_advertise
.out:
    ret

; na_input(RBX, RDI = IPv6 header, RSI = message, ECX = bytes): a neighbour
; advertisement: its MAC learned; for an address we are checking, it is
; taken
na_input:
    cmp byte [rdi + 7], 255
    jne .out
    cmp ecx, 24
    jb .out
    push rsi
    add rsi, 8
    call ip6_mine
    pop rsi
    jz .learn
    cmp eax, A6_TENTATIVE
    je ip6_conflict
    ret
.learn:
    mov al, 2
    mov edx, 24
    call nd_lla
    jc .out
    add rsi, 8
    call nd_learn
.out:
    ret

; ip6_conflict(RDX = an address of ours, still being checked): another node
; has it. Given up.
ip6_conflict:
    KLOG "ip6: %A is in use by another node; not using it", rdx
    lea rax, [ip6_ll]
    cmp rdx, rax
    jne .gua
    mov byte [ip6_ll_state], A6_NONE
    ret
.gua:
    mov byte [ip6_gua_state], A6_NONE
    ret

; nd_advertise(RDX = an address of ours, RDI = where to, EAX = flags: 0x20
; override, 0x40 solicited): a neighbour advertisement with our MAC.
; Preserves all but RAX.
nd_advertise:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea r10, [nd_frame]
    lea r8, [r10 + NET6_PAYLOAD]
    mov dword [r8], 136
    mov [r8 + 4], eax
    mov r9, rdx                         ; from that address
    push rdi
    mov rsi, rdx
    lea rdi, [r8 + 8]
    call addr_copy
    pop rdi
    mov word [r8 + 24], 0x0102          ; target link-layer address, 8 bytes
    mov rdx, [net_nic]
    mov eax, [rdx + NI_MAC]
    mov [r8 + 26], eax
    mov ax, [rdx + NI_MAC + 4]
    mov [r8 + 30], ax
    mov esi, 58
    mov ecx, 32
    mov edx, 2
    call ip6_emit
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nd_solicit(RSI = target, R9 = source): a neighbour solicitation, to the
; target's solicited-node group; with our MAC unless the source is ::
; (checking an address is free). Preserves all but RAX.
nd_solicit:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r10
    lea r10, [nd_frame]
    lea r8, [r10 + NET6_PAYLOAD]
    mov dword [r8], 135
    mov dword [r8 + 4], 0
    lea rdi, [r8 + 8]
    call addr_copy
    lea rdi, [ip6_snm]
    call ip6_solicited
    mov ecx, 24
    push rsi
    mov rsi, r9
    call addr_null
    pop rsi
    jz .bare
    mov word [r8 + 24], 0x0101          ; source link-layer address
    mov rdx, [net_nic]
    mov eax, [rdx + NI_MAC]
    mov [r8 + 26], eax
    mov ax, [rdx + NI_MAC + 4]
    mov [r8 + 30], ax
    mov ecx, 32
.bare:
    mov esi, 58
    mov edx, 2
    call ip6_emit
    pop r10
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nd_ask(RSI = address): who has it? Preserves all but RAX.
nd_ask:
    cmp byte [ip6_ll_state], A6_READY
    jne .out
    push r9
    lea r9, [ip6_ll]
    call nd_solicit
    pop r9
.out:
    ret

; ip6_dad(RSI = an address of ours, tentative): is anyone else using it?
; A second later it is ours. Preserves all but RAX.
ip6_dad:
    push r9
    lea r9, [ip6_unspec]
    call nd_solicit
    pop r9
    call net_clock
    add rax, [net_second]
    mov [ip6_dad_at], rax
    jmp ip6_arm

; ip6_rs: a router solicitation, to all routers. Preserves all but RAX.
ip6_rs:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea r10, [nd_frame]
    lea r8, [r10 + NET6_PAYLOAD]
    mov dword [r8], 133
    mov dword [r8 + 4], 0
    mov word [r8 + 8], 0x0101           ; source link-layer address
    mov rdx, [net_nic]
    mov eax, [rdx + NI_MAC]
    mov [r8 + 10], eax
    mov ax, [rdx + NI_MAC + 4]
    mov [r8 + 14], ax
    lea rdi, [ip6_all_routers]
    lea r9, [ip6_ll]
    mov esi, 58
    mov ecx, 16
    mov edx, 2
    call ip6_emit
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; mld_report: MLDv2: we listen to our solicited-node group (all nodes is
; never reported). Preserves all but RAX.
mld_report:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    lea r10, [nd_frame]
    lea r8, [r10 + NET6_PAYLOAD]
    mov rax, 0x000100000205003A         ; hop-by-hop: ICMPv6 next; router
    mov [r8], rax                       ; alert (MLD), 2 bytes of padding
    mov dword [r8 + 8], 143             ; a report, its checksum below
    mov dword [r8 + 12], 0x01000000     ; one record
    mov dword [r8 + 16], 4              ; CHANGE_TO_EXCLUDE: listening, no sources
    lea rsi, [ip6_ll]
    lea rdi, [r8 + 20]
    call ip6_solicited
    lea r9, [ip6_ll]                    ; from the link-local address, or
    cmp byte [ip6_ll_state], A6_READY   ; :: while that is being checked
    je .from
    lea r9, [ip6_unspec]
.from:
    lea rdi, [r10 + ETH_HLEN]           ; the addresses, for the checksum
    mov rax, [r9]
    mov [rdi + 8], rax
    mov rax, [r9 + 8]
    mov [rdi + 16], rax
    mov rax, [ip6_mld_all]
    mov [rdi + 24], rax
    mov rax, [ip6_mld_all + 8]
    mov [rdi + 32], rax
    mov ecx, 28
    mov eax, 58
    call ip6_pseudo
    lea rsi, [r8 + 8]
    call net_sum
    call net_fold
    mov [r8 + 10], ax
    lea rdi, [ip6_mld_all]
    xor esi, esi
    mov ecx, 36
    mov edx, -1
    call ip6_emit
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ra_input(RBX, RDI = IPv6 header, RSI = message, ECX = bytes): a router
; advertisement
ra_input:
    cmp byte [rdi + 7], 255
    jne .out
    cmp ecx, 16
    jb .out
    push rsi
    lea rsi, [rdi + 8]
    call ip6_linklocal
    pop rsi
    jne .out
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; the message
    mov r13d, ecx
    lea r14, [rdi + 8]                  ; the router
    xor r15d, r15d                      ; 1: something to say
    mov qword [ip6_rs_at], 0            ; asked and answered
    mov al, 1
    mov edx, 16
    call nd_lla
    jc .no_lla
    mov rsi, r14
    call nd_learn
.no_lla:
    cmp byte [ip6_static], 0
    jne .done
    movzx eax, byte [r12 + 4]
    test eax, eax
    jz .lifetime
    mov [ip6_hops], eax
.lifetime:
    movzx eax, word [r12 + 6]
    xchg al, ah
    mov rsi, r14
    lea rdi, [ip6_router]
    test eax, eax
    jz .not_router
    call addr_eq
    je .same_router
    call addr_copy
    mov r15d, 1
.same_router:
    imul rax, [net_second]
    add rax, [net_now]
    mov [ip6_router_until], rax
    jmp .options
.not_router:                            ; no longer a router: if ours, gone
    call addr_eq
    jne .options
    xor eax, eax
    mov [ip6_router], rax
    mov [ip6_router + 8], rax
    mov [ip6_router_until], rax
    mov r15d, 1
.options:
    mov edx, 16
.option:
    lea eax, [edx + 2]
    cmp eax, r13d
    ja .options_done
    movzx ecx, byte [r12 + rdx + 1]
    test ecx, ecx
    jz .options_done
    shl ecx, 3
    lea eax, [edx + ecx]
    cmp eax, r13d
    ja .options_done
    lea rsi, [r12 + rdx]
    movzx eax, byte [rsi]
    cmp eax, 3
    je .prefix
    cmp eax, 5
    je .mtu
    cmp eax, 25
    je .rdnss
.next_option:
    add edx, ecx
    jmp .option
.prefix:
    cmp ecx, 32
    jne .next_option
    cmp byte [rsi + 2], 64
    jne .next_option
    mov eax, [rsi + 4]                  ; valid lifetime
    bswap eax
    test byte [rsi + 3], 0x80           ; on the link
    jz .auto
    mov r8, [rsi + 16]
    mov [ip6_prefix], r8
    test eax, eax
    setnz byte [ip6_prefix_on]
.auto:
    test byte [rsi + 3], 0x40           ; for addresses
    jz .next_option
    test eax, eax
    jz .next_option
    push rsi
    add rsi, 16
    call ip6_linklocal
    pop rsi
    je .next_option
    cmp byte [ip6_gua_state], A6_NONE
    je .form
    mov r8, [rsi + 16]                  ; one global address: the first
    cmp r8, [ip6_gua]                   ; prefix's; that one renewed
    jne .next_option
    call ip6_valid
    jmp .next_option
.form:
    mov r8, [rsi + 16]
    mov [ip6_gua], r8
    mov r8, [ip6_ll + 8]
    mov [ip6_gua + 8], r8
    mov byte [ip6_gua_state], A6_TENTATIVE
    call ip6_valid
    push rsi
    lea rsi, [ip6_gua]
    call ip6_dad
    pop rsi
    jmp .next_option
.mtu:
    cmp ecx, 8
    jne .next_option
    mov eax, [rsi + 4]
    bswap eax
    cmp eax, 1280
    jb .next_option
    cmp eax, 1500
    ja .next_option
    mov [ip6_mtu], eax
    jmp .next_option
.rdnss:
    cmp ecx, 24
    jb .next_option
    cmp dword [rsi + 4], 0              ; its lifetime
    je .next_option
    add rsi, 8
    lea rdi, [ip6_dns]
    call addr_eq
    je .next_option
    call addr_copy
    mov r15d, 1
    jmp .next_option
.options_done:
    test r15d, r15d
    jz .done
    cmp byte [ip6_gua_state], A6_READY
    jne .done
    call ip6_say
.done:
    call ip6_arm
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
.out:
    ret

; ip6_valid(EAX = the prefix's valid lifetime, seconds): when the global
; address lapses (0xFFFFFFFF: never). Preserves all.
ip6_valid:
    push rax
    cmp eax, -1
    je .forever
    mov eax, eax
    imul rax, [net_second]
    add rax, [net_now]
    jmp .set
.forever:
    xor eax, eax
.set:
    mov [ip6_gua_until], rax
    pop rax
    ret

; -----------------------------------------------------------------------------
;  The neighbour cache
; -----------------------------------------------------------------------------

; nd_slot(RSI = address) -> RDX = its entry, else a free one, else the
; oldest. Preserves others.
nd_slot:
    push rax
    push rcx
    push rdi
    push r8
    lea rdx, [nd_cache]
    mov ecx, ND_SLOTS
.same:
    cmp qword [rdx + ND_TIME], 0
    je .same_next
    mov rdi, rdx
    call addr_eq
    je .out
.same_next:
    add rdx, ND_SIZE
    dec ecx
    jnz .same
    lea rdx, [nd_cache]
    mov r8, rdx
    mov ecx, ND_SLOTS
.other:
    cmp qword [rdx + ND_TIME], 0
    je .out
    mov rax, [rdx + ND_TIME]
    cmp rax, [r8 + ND_TIME]
    jae .older
    mov r8, rdx
.older:
    add rdx, ND_SIZE
    dec ecx
    jnz .other
    mov rdx, r8
.out:
    pop r8
    pop rdi
    pop rcx
    pop rax
    ret

; nd_find(RSI = address) -> RDX = its entry, CF if unknown or too old.
; Preserves others.
nd_find:
    push rax
    push rdi
    call nd_slot
    cmp qword [rdx + ND_TIME], 0
    je .none
    mov rdi, rdx
    call addr_eq
    jne .none
    mov rax, [net_now]
    sub rax, [rdx + ND_TIME]
    cmp rax, [arp_life]
    jae .none
    clc
    jmp .out
.none:
    stc
.out:
    pop rdi
    pop rax
    ret

; nd_learn(RSI = address, RCX = its MAC): remember it, and send what was
; waiting for it. Preserves all but RAX.
nd_learn:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov r10, rsi
    call nd_slot
    mov rdi, rdx
    call addr_copy
    mov eax, [rcx]
    mov [rdx + ND_MAC], eax
    mov ax, [rcx + 4]
    mov [rdx + ND_MAC + 4], ax
    call net_clock
    mov [rdx + ND_TIME], rax
    lea rdi, [rdx + ND_MAC]
    lea r8, [nd_waits]
    mov r9d, ND_WAITS
.wait:
    cmp dword [r8 + NDW_LEN], 0
    je .next
    push rdi
    mov rsi, r10
    mov rdi, r8
    call addr_eq
    pop rdi
    jne .next
    lea rdx, [r8 + NDW_FRAME]
    mov ecx, [r8 + NDW_LEN]
    mov esi, ETYPE_IP6
    call eth_send
    mov dword [r8 + NDW_LEN], 0
.next:
    add r8, NDW_SIZE
    dec r9d
    jnz .wait
    call nd_arm
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nd_queue(RSI = next hop, R10 = frame, ECX = its bytes): kept until the
; neighbour answers, and asked. Preserves all but RAX.
nd_queue:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    lea r8, [nd_waits]
    mov edx, ND_WAITS
.find:
    cmp dword [r8 + NDW_LEN], 0
    je .slot
    add r8, NDW_SIZE
    dec edx
    jnz .find
    lea r8, [nd_waits]                  ; all taken: the first gives way
    mov rdx, [net_nic]
    inc qword [rdx + NI_DROP]
.slot:
    mov rdi, r8
    call addr_copy
    mov [r8 + NDW_LEN], ecx
    mov dword [r8 + NDW_TRIES], 1
    push rsi
    lea rdi, [r8 + NDW_FRAME]
    mov rsi, r10
    rep movsb
    pop rsi
    call net_clock
    add rax, [net_second]
    mov [r8 + NDW_NEXT], rax
    call nd_ask
    call nd_arm
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; nd_tick: ask again, three times a second apart, then give up
nd_tick:
    mov rax, [nd_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    push rsi
    push rdi
    push r8
    push r12
    lea r8, [nd_waits]
    mov r12d, ND_WAITS
.wait:
    cmp dword [r8 + NDW_LEN], 0
    je .next
    mov rax, [r8 + NDW_NEXT]
    cmp rax, [net_now]
    ja .next
    cmp dword [r8 + NDW_TRIES], 3
    jae .give_up
    inc dword [r8 + NDW_TRIES]
    mov rax, [net_now]
    add rax, [net_second]
    mov [r8 + NDW_NEXT], rax
    mov rsi, r8
    call nd_ask
    jmp .next
.give_up:
    mov dword [r8 + NDW_LEN], 0
    mov rax, [net_nic]
    inc qword [rax + NI_DROP]
    mov rsi, r8
    lea rdi, [nd_failed]                ; say so once per address
    call addr_eq
    je .next
    call addr_copy
    KLOG "net: nobody answers NDP for %A", rsi
.next:
    add r8, NDW_SIZE
    dec r12d
    jnz .wait
    pop r12
    pop r8
    pop rdi
    pop rsi
    call nd_arm
.out:
    ret

; nd_arm: nd_next = the earliest deadline of a waiting frame, 0 if none.
; Preserves all.
nd_arm:
    push rax
    push rcx
    push rdx
    xor eax, eax
    lea rdx, [nd_waits]
    mov ecx, ND_WAITS
.wait:
    cmp dword [rdx + NDW_LEN], 0
    je .next
    test rax, rax
    jz .take
    cmp rax, [rdx + NDW_NEXT]
    jbe .next
.take:
    mov rax, [rdx + NDW_NEXT]
.next:
    add rdx, NDW_SIZE
    dec ecx
    jnz .wait
    mov [nd_next], rax
    pop rdx
    pop rcx
    pop rax
    ret

; nd_flush: forget every neighbour and what waits for one. Preserves all.
nd_flush:
    push rax
    push rcx
    push rdi
    xor eax, eax
    lea rdi, [nd_cache]
    mov ecx, ND_SLOTS * ND_SIZE
    rep stosb
    lea rdi, [nd_failed]
    mov ecx, 16
    rep stosb
    lea rdi, [nd_waits]
    mov ecx, ND_WAITS
.wait:
    mov dword [rdi + NDW_LEN], 0
    add rdi, NDW_SIZE
    dec ecx
    jnz .wait
    mov [nd_next], rax
    pop rdi
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Configuration, and its timers
; -----------------------------------------------------------------------------

; ip6_start: the link is up: a link-local address from the MAC, checked;
; the router asked for once it is ours. What the last network gave is
; forgotten, unless it was set by hand. Preserves all.
ip6_start:
    cmp dword [nic_count], 0
    je .none
    push rax
    push rdx
    push rsi
    push rdi
    call nd_flush
    cmp byte [ip6_static], 0
    jne .ll
    xor eax, eax
    lea rdi, [ip6_gua]
    mov [rdi], rax
    mov [rdi + 8], rax
    mov [ip6_gua_state], al
    mov [ip6_router], rax
    mov [ip6_router + 8], rax
    mov [ip6_dns], rax
    mov [ip6_dns + 8], rax
    mov [ip6_router_until], rax
    mov [ip6_gua_until], rax
    mov [ip6_prefix_on], al
    mov dword [ip6_hops], 64
    mov dword [ip6_mtu], 1500
.ll:
    mov rdx, [net_nic]                  ; fe80:: and the MAC, ff:fe in the
    lea rdi, [ip6_ll]                   ; middle, the universal bit flipped
    mov qword [rdi], 0x80FE
    mov al, [rdx + NI_MAC]
    xor al, 2
    mov [rdi + 8], al
    mov ax, [rdx + NI_MAC + 1]
    mov [rdi + 9], ax
    mov word [rdi + 11], 0xFEFF
    mov al, [rdx + NI_MAC + 3]
    mov [rdi + 13], al
    mov ax, [rdx + NI_MAC + 4]
    mov [rdi + 14], ax
    mov byte [ip6_ll_state], A6_TENTATIVE
    mov qword [ip6_rs_at], 0
    mov dword [ip6_rs_tries], 0
    call mld_report
    lea rsi, [ip6_ll]
    call ip6_dad
    pop rdi
    pop rsi
    pop rdx
    pop rax
.none:
    ret

; ip6_tick: the addresses checked; routers asked for; lifetimes that end
ip6_tick:
    mov rax, [ip6_next]
    test rax, rax
    jz .out
    cmp rax, [net_now]
    ja .out
    mov rax, [ip6_dad_at]
    test rax, rax
    jz .rs
    cmp rax, [net_now]
    ja .rs
    mov qword [ip6_dad_at], 0
    cmp byte [ip6_ll_state], A6_TENTATIVE
    jne .gua
    mov byte [ip6_ll_state], A6_READY
    lea rax, [ip6_ll]
    KLOG "ip6: link-local address %A", rax
    call mld_report                     ; again, from it
    cmp byte [ip6_static], 0
    jne .gua
    mov rax, [net_now]
    mov [ip6_rs_at], rax
.gua:
    cmp byte [ip6_gua_state], A6_TENTATIVE
    jne .rs
    mov byte [ip6_gua_state], A6_READY
    call ip6_say
.rs:
    mov rax, [ip6_rs_at]
    test rax, rax
    jz .router
    cmp rax, [net_now]
    ja .router
    cmp dword [ip6_rs_tries], RS_TRIES
    jae .rs_done
    inc dword [ip6_rs_tries]
    call ip6_rs
    mov rax, [net_second]
    imul rax, rax, RS_GAP_S
    add rax, [net_now]
    mov [ip6_rs_at], rax
    jmp .router
.rs_done:
    mov qword [ip6_rs_at], 0
    KLOG "ip6: no router answers; link-local only"
.router:
    mov rax, [ip6_router_until]
    test rax, rax
    jz .address
    cmp rax, [net_now]
    ja .address
    xor eax, eax
    mov [ip6_router], rax
    mov [ip6_router + 8], rax
    mov [ip6_router_until], rax
    KLOG "ip6: the router's lifetime ran out"
.address:
    mov rax, [ip6_gua_until]
    test rax, rax
    jz .arm
    cmp rax, [net_now]
    ja .arm
    mov qword [ip6_gua_until], 0
    mov byte [ip6_gua_state], A6_NONE
    lea rax, [ip6_gua]
    KLOG "ip6: %A: its prefix's lifetime ran out", rax
.arm:
    call ip6_arm
.out:
    ret

; ip6_arm: ip6_next, the soonest of what ip6_tick waits for. Preserves all.
ip6_arm:
    push rax
    push rcx
    push rdx
    push r8
    lea rdx, [ip6_dad_at]
    xor eax, eax
    mov ecx, 4
.deadline:
    mov r8, [rdx]
    test r8, r8
    jz .next
    test rax, rax
    jz .take
    cmp r8, rax
    jae .next
.take:
    mov rax, r8
.next:
    add rdx, 8
    dec ecx
    jnz .deadline
    mov [ip6_next], rax
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ip6_say: the global address is ours; with what came with it
ip6_say:
    push rax
    push rsi
    push rdi
    lea rsi, [ip6_router]
    lea rdi, [ip6_rtext]
    call ip6_or_none
    lea rsi, [ip6_dns]
    lea rdi, [ip6_dtext]
    call ip6_or_none
    lea rax, [ip6_gua]
    lea rsi, [ip6_rtext]
    lea rdi, [ip6_dtext]
    KLOG "ip6: address %A/64, router %s, DNS %s", rax, rsi, rdi
    pop rdi
    pop rsi
    pop rax
    ret

; ip6_show: the IPv6 lines of 'net' and 'ip6'
ip6_show:
    push rax
    push rsi
    push rdi
    movzx eax, byte [ip6_ll_state]
    test eax, eax
    jnz .ll
    KLOG "ipv6: none (no link yet, or its address is taken)"
    jmp .out
.ll:
    lea rsi, [ip6_ll]
    lea rdi, [str_a6_checking]
    cmp eax, A6_READY
    jne .say_ll
    lea rdi, [str_empty6]
.say_ll:
    KLOG "ipv6 link-local %A%s", rsi, rdi
    movzx eax, byte [ip6_gua_state]
    test eax, eax
    jnz .gua
    KLOG "ipv6: no global address (no router has offered a prefix)"
    jmp .out
.gua:
    lea rsi, [ip6_router]
    lea rdi, [ip6_rtext]
    call ip6_or_none
    lea rsi, [ip6_dns]
    lea rdi, [ip6_dtext]
    call ip6_or_none
    lea rax, [ip6_gua]
    lea rsi, [ip6_rtext]
    lea rdi, [ip6_dtext]
    KLOG "ipv6 address %A/64, router %s, DNS %s", rax, rsi, rdi
    cmp byte [ip6_gua_state], A6_READY
    je .static
    KLOG "        being checked (DAD)"
.static:
    cmp byte [ip6_static], 0
    je .prefer
    KLOG "        set by hand"
.prefer:
    cmp byte [ip6_prefer], 0
    je .out
    KLOG "        preferred to IPv4 for names that have both"
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; ip6 [<address>/64 [router] [dns] | auto | prefer [off]]
cmd_ip6:
    push rbx
    push r12
    push r13
    cmp dword [nic_count], 0
    jne .args
    KLOG "no network interface ('net' lists what Axiom drives)"
    jmp .out
.args:
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    jne .word
    call ip6_show
    call nd_list
    jmp .out
.word:
    call arg_split
    mov r12, rdi                        ; the rest
    lea rdi, [str_ip6_auto]
    call streq
    test eax, eax
    jz .prefer
    mov byte [ip6_static], 0
    call ip6_start
    KLOG "ip6: from the router again"
    jmp .out
.prefer:
    lea rdi, [str_ip6_prefer]
    call streq
    test eax, eax
    jz .set
    mov byte [ip6_prefer], 1
    mov rsi, r12
    lea rdi, [str_ip6_off]
    call streq
    test eax, eax
    jz .said
    mov byte [ip6_prefer], 0
.said:
    call ip6_show
    jmp .out
.set:
    lea rdi, [ip6_tmp]
    call ip6_parse
    jc .usage
    cmp word [rsi], '/6'
    jne .usage
    cmp word [rsi + 2], '4'             ; and the NUL
    jne .usage
    lea rsi, [ip6_tmp]
    call ip6_linklocal
    je .usage
    xor eax, eax
    mov [ip6_tmp + 16], rax             ; no router, no DNS
    mov [ip6_tmp + 24], rax
    mov [ip6_tmp + 32], rax
    mov [ip6_tmp + 40], rax
    mov rsi, r12
    cmp byte [rsi], 0
    je .apply
    call arg_split
    mov r12, rdi
    lea rdi, [ip6_tmp + 16]
    call addr_parse
    jc .usage
    mov rsi, r12
    cmp byte [rsi], 0
    je .apply
    call arg_split
    lea rdi, [ip6_tmp + 32]
    call addr_parse
    jc .usage
.apply:
    mov byte [ip6_static], 1
    lea rsi, [ip6_tmp]
    lea rdi, [ip6_gua]
    call addr_copy
    mov rax, [ip6_tmp]
    mov [ip6_prefix], rax
    mov byte [ip6_prefix_on], 1
    lea rsi, [ip6_tmp + 16]
    lea rdi, [ip6_router]
    call addr_copy
    lea rsi, [ip6_tmp + 32]
    lea rdi, [ip6_dns]
    call addr_copy
    xor eax, eax
    mov [ip6_router_until], rax
    mov [ip6_gua_until], rax
    mov qword [ip6_rs_at], 0
    mov byte [ip6_gua_state], A6_READY
    call nd_flush
    call ip6_show
    jmp .out
.usage:
    KLOG "usage: ip6 <address>/64 [router] [dns], ip6 auto, ip6 prefer [off]"
.out:
    pop r13
    pop r12
    pop rbx
    ret

; nd_list: the neighbour cache, for 'ip6'
nd_list:
    push rbx
    push r12
    lea rbx, [nd_cache]
    xor r12d, r12d
.slot:
    cmp qword [rbx + ND_TIME], 0
    je .next
    call net_clock
    sub rax, [rbx + ND_TIME]
    xor edx, edx
    div qword [net_second]
    lea rdx, [rbx + ND_MAC]
    KLOG "  %-25A  %M  learned %u s ago", rbx, rdx, rax
.next:
    add rbx, ND_SIZE
    inc r12d
    cmp r12d, ND_SLOTS
    jb .slot
    pop r12
    pop rbx
    ret

section .rodata
alignb 8
ip6_unspec:     times 16 db 0
ip6_all_nodes:  db 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1
ip6_all_routers: db 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2
ip6_mld_all:    db 0xFF, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16
str_a6_checking: db ' (being checked)', 0
str_empty6:     db 0
str_ip6_auto:       db 'auto', 0
str_ip6_prefer:     db 'prefer', 0
str_ip6_off:        db 'off', 0

section .bss
alignb 16
ip6_ll:         resb 16                 ; ours, link-local
ip6_gua:        resb 16                 ; ours, global
ip6_router:     resb 16                 ; :: if none
ip6_dns:        resb 16
ip6_peer:       resb 16
ip6_snm:        resb 16
nd_failed:      resb 16
ip6_tmp:        resb 48
ip6_prefix:     resq 1                  ; the /64 on the link
ip6_dad_at:     resq 1                  ; ip6_arm's four deadlines, in this order
ip6_rs_at:      resq 1
ip6_router_until: resq 1
ip6_gua_until:  resq 1
ip6_hops:       resd 1
ip6_mtu:        resd 1
ip6_rs_tries:   resd 1
ip6_ll_state:   resb 1
ip6_gua_state:  resb 1
ip6_prefix_on:  resb 1
ip6_static:     resb 1                  ; set by hand
ip6_prefer:     resb 1                  ; AAAA before A
ip6_mmac:       resb 6
ip6_rtext:      resb 48
ip6_dtext:      resb 48
alignb 16
nd_cache:       resb ND_SLOTS * ND_SIZE
nd_frame:       resb NET_FRAME
nd_waits:       resb ND_WAITS * NDW_SIZE
