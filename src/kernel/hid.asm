; =============================================================================
;  hid.asm - Human Interface Devices: keyboards and mice over USB (and, through
;  the same parser, over Bluetooth LE).
;
;  The report descriptor is parsed into a short list of fields Axiom cares
;  about: key arrays, key bitmaps (6-key and N-key rollover), buttons, X/Y
;  (relative or absolute), wheel and horizontal pan, each with its report ID.
;  Devices whose descriptor says nothing useful but claim the boot subclass
;  are switched to boot protocol and read with the fixed boot layouts.
; =============================================================================

MAX_HID         equ 16
HID_FIELDS      equ 40
HID_KEYS        equ 30                  ; pressed keys remembered per report

; HID record (R12 points at one)
HD_STATE        equ 0
HD_FLAGS        equ 4
HD_NFIELDS      equ 8
HD_IFACE        equ 12
HD_DEV          equ 16                  ; USB device, or 0
HD_EP           equ 24                  ; its interrupt-IN endpoint
HD_PREV         equ 32                  ; 4 slots: id + 1, count, 30 usages
HD_FIELDS       equ 160                 ; HID_FIELDS * 16
HD_BUTTONS      equ 800
HD_SUBCLASS     equ 804
HD_PROTOCOL     equ 808
HD_SIZE         equ 1024

HF_IDS          equ 1                   ; reports start with an ID byte
HF_KBD          equ 2
HF_MOUSE        equ 4
HF_BOOT         equ 8

; field (16 bytes)
F_ID            equ 0                   ; byte
F_KIND          equ 1                   ; byte
F_SIZE          equ 2                   ; byte, bits per element
F_COUNT         equ 3                   ; byte
F_OFF           equ 4                   ; word, bit offset after the ID byte
F_UMIN          equ 6                   ; word
F_LMIN          equ 8                   ; dword, signed
F_LMAX          equ 12                  ; dword, signed

K_KEYARRAY      equ 1
K_KEYBITS       equ 2
K_BUTTONS       equ 3
K_X             equ 4
K_Y             equ 5
K_WHEEL         equ 6
K_PAN           equ 7
K_XABS          equ 8
K_YABS          equ 9

section .text

; hid_alloc -> R12 = a zeroed HID record, CF if none left
hid_alloc:
    push rax
    push rcx
    push rdi
    lea r12, [hid_devs]
    xor ecx, ecx
.find:
    cmp ecx, MAX_HID
    jae .full
    cmp dword [r12 + HD_STATE], 0
    je .found
    add r12, HD_SIZE
    inc ecx
    jmp .find
.found:
    mov rdi, r12
    mov ecx, HD_SIZE / 8
    xor eax, eax
    rep stosq
    mov dword [r12 + HD_STATE], 1
    pop rdi
    pop rcx
    pop rax
    clc
    ret
.full:
    pop rdi
    pop rcx
    pop rax
    stc
    ret

; -----------------------------------------------------------------------------
;  USB binding
; -----------------------------------------------------------------------------

; hid_probe(RBX = device, RSI = interface, RDI = end) -> CF = 1 if not taken
hid_probe:
    cmp byte [rsi + 5], 3
    jne .no
    push rcx
    push rdx
    push rsi
    push r12
    push r13
    push r14
    call hid_alloc
    jc .fail_noalloc
    mov [r12 + HD_DEV], rbx
    movzx eax, byte [rsi + 2]
    mov [r12 + HD_IFACE], eax
    movzx eax, byte [rsi + 6]
    mov [r12 + HD_SUBCLASS], eax
    movzx eax, byte [rsi + 7]
    mov [r12 + HD_PROTOCOL], eax
    xor r13d, r13d                      ; report descriptor length
    mov dl, 0x21                        ; HID descriptor
    xor ecx, ecx
    call usb_find_desc
    jc .endpoint
    movzx r13d, word [rax + 7]
.endpoint:
    xor ecx, ecx                        ; first interrupt-IN endpoint
.ep:
    mov dl, 5
    call usb_find_desc
    jc .fail
    test byte [rax + 2], 0x80
    jz .ep_next
    mov dl, [rax + 3]
    and dl, 3
    cmp dl, 3
    je .ep_found
.ep_next:
    inc ecx
    jmp .ep
.ep_found:
    mov r14, rax
    test r13d, r13d
    jz .boot
    cmp r13d, 4000
    ja .boot
    mov eax, [r12 + HD_IFACE]           ; GET_DESCRIPTOR(report)
    shl rax, 32
    mov rsi, r13
    shl rsi, 48
    or rsi, rax
    mov rax, 0x0000000022000681
    or rsi, rax
    mov rdx, [rbx + DV_BUFP]
    mov ecx, r13d
    call usb_control
    jc .boot
    mov rsi, [rbx + DV_BUF]
    mov ecx, r13d
    call hid_parse
    test dword [r12 + HD_FLAGS], HF_KBD | HF_MOUSE
    jnz .usable
.boot:
    cmp dword [r12 + HD_SUBCLASS], 1
    jne .fail
    mov dword [r12 + HD_FLAGS], 0       ; nothing from the parse survives
    mov dword [r12 + HD_NFIELDS], 0
    call hid_boot_fields
    test dword [r12 + HD_FLAGS], HF_KBD | HF_MOUSE
    jz .fail
.usable:
    push r14                            ; the endpoint descriptor
    mov rsi, r14
    lea rdx, [hid_usb_done]
    mov rcx, r12
    movzx r8d, word [rsi + 4]
    and r8d, 0x7FF
    cmp r8d, 8
    jae .len
    mov r8d, 8
.len:
    call usb_ep_create
    pop rax
    jc .fail
    mov dword [r14 + EP_AUTO], 1
    mov [r12 + HD_EP], r14
    lea rsi, [hid_usb_start]
    lea rdx, [hid_detach]
    mov rcx, r12
    call usb_bind
    test dword [r12 + HD_FLAGS], HF_KBD
    jz .role_mouse
    lea rsi, [str_role_kbd]
    call usb_add_role
.role_mouse:
    test dword [r12 + HD_FLAGS], HF_MOUSE
    jz .claimed
    lea rsi, [str_role_mouse]
    call usb_add_role
.claimed:
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.fail:
    mov dword [r12 + HD_STATE], 0
.fail_noalloc:
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
.no:
    stc
    ret

; hid_usb_start(RBX = device, RSI = HID record): idle off, protocol, listen
hid_usb_start:
    push r12
    push r14
    mov r12, rsi
    mov esi, [r12 + HD_IFACE]           ; SET_IDLE(0): reports only on change
    shl rsi, 32
    or rsi, 0x0A21
    xor edx, edx
    xor ecx, ecx
    call usb_control
    test dword [r12 + HD_FLAGS], HF_BOOT
    jz .listen
    mov esi, [r12 + HD_IFACE]           ; SET_PROTOCOL(boot)
    shl rsi, 32
    or rsi, 0x0B21
    xor edx, edx
    xor ecx, ecx
    call usb_control
.listen:
    mov r14, [r12 + HD_EP]
    call usb_ep_queue
    call hid_log
    pop r14
    pop r12
    ret

; hid_log(R12 = HID record)
hid_log:
    push rax
    push rcx
    lea rax, [str_hid_kbd]
    test dword [r12 + HD_FLAGS], HF_KBD
    jnz .kind
    lea rax, [str_hid_mouse]
.kind:
    lea rcx, [str_hid_report]
    test dword [r12 + HD_FLAGS], HF_BOOT
    jz .proto
    lea rcx, [str_hid_bootp]
.proto:
    KLOG "  hid: %s, %s protocol", rax, rcx
    pop rcx
    pop rax
    ret

; hid_usb_done: a report arrived (interrupts off)
hid_usb_done:
    push r12
    mov r12, [r14 + EP_CTX]
    mov rsi, [r14 + EP_BUF]
    mov ecx, [r14 + EP_LEN]
    sub ecx, edx
    jle .requeue
    mov edx, -1
    call hid_input
.requeue:
    pop r12
    jmp usb_ep_queue

; hid_detach(RBX = device, RSI = HID record)
hid_detach:
    mov dword [rsi + HD_STATE], 0
    mov dword [hid_repeat_key], 0
    ret

; hid_boot_fields(R12): the fixed boot-protocol layouts
hid_boot_fields:
    push rsi
    push rdi
    push rcx
    cmp dword [r12 + HD_PROTOCOL], 1
    je .keyboard
    cmp dword [r12 + HD_PROTOCOL], 2
    jne .out
    lea rsi, [hid_boot_mouse]
    mov ecx, 3
    or dword [r12 + HD_FLAGS], HF_MOUSE | HF_BOOT
    jmp .copy
.keyboard:
    lea rsi, [hid_boot_kbd]
    mov ecx, 2
    or dword [r12 + HD_FLAGS], HF_KBD | HF_BOOT
.copy:
    mov [r12 + HD_NFIELDS], ecx
    lea rdi, [r12 + HD_FIELDS]
    shl ecx, 1                          ; 16 bytes each, as qwords
    rep movsq
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

; -----------------------------------------------------------------------------
;  hid_parse(R12 = HID record, RSI = report descriptor, ECX = length)
; -----------------------------------------------------------------------------
hid_parse:
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
    push r13
    push rcx                            ; zero the parser state
    lea rdi, [hp_state]
    mov ecx, HP_STATE_SIZE / 8
    xor eax, eax
    rep stosq
    pop rcx
    lea r13, [rsi + rcx]                ; end
.item:
    cmp rsi, r13
    jae .done
    movzx eax, byte [rsi]
    cmp eax, 0xFE                       ; long item: skip it
    jne .short
    movzx ecx, byte [rsi + 1]
    lea rsi, [rsi + rcx + 3]
    jmp .item
.short:
    mov ecx, eax
    and ecx, 3                          ; data bytes: 0, 1, 2, 4
    cmp ecx, 3
    jne .size
    mov ecx, 4
.size:
    lea rdx, [rsi + rcx + 1]
    cmp rdx, r13
    ja .done
    xor edx, edx                        ; unsigned data
    xor r8d, r8d                        ; signed data
    test ecx, ecx
    jz .decoded
    cmp ecx, 1
    jne .two
    movzx edx, byte [rsi + 1]
    movsx r8d, byte [rsi + 1]
    jmp .decoded
.two:
    cmp ecx, 2
    jne .four
    movzx edx, word [rsi + 1]
    movsx r8d, word [rsi + 1]
    jmp .decoded
.four:
    mov edx, [rsi + 1]
    mov r8d, edx
.decoded:
    mov r9d, ecx                        ; data size, for extended usages
    lea rsi, [rsi + rcx + 1]
    mov ecx, eax
    shr ecx, 2
    and ecx, 3                          ; type
    shr eax, 4                          ; tag
    cmp ecx, 1
    je .global
    cmp ecx, 2
    je .local
    test ecx, ecx
    jnz .item
    cmp eax, 8                          ; main items
    jne .clear_locals
    call hid_parse_input
.clear_locals:
    mov dword [hp_nusages], 0
    mov dword [hp_range], 0
    jmp .item

.global:
    cmp eax, 0
    jne .g1
    mov [hp_page], edx
    jmp .item
.g1:
    cmp eax, 1
    jne .g2
    mov [hp_lmin], r8d
    jmp .item
.g2:
    cmp eax, 2
    jne .g7
    mov [hp_lmax], r8d
    cmp dword [hp_lmin], 0              ; 0..255 written as one byte
    jl .item
    test r8d, r8d
    jns .item
    mov [hp_lmax], edx
    jmp .item
.g7:
    cmp eax, 7
    jne .g8
    mov [hp_size], edx
    jmp .item
.g8:
    cmp eax, 8
    jne .g9
    and edx, 0xFF
    mov [hp_id], edx
    or dword [r12 + HD_FLAGS], HF_IDS
    jmp .item
.g9:
    cmp eax, 9
    jne .g10
    mov [hp_count], edx
    jmp .item
.g10:
    cmp eax, 10                         ; push
    jne .g11
    mov eax, [hp_sp]
    cmp eax, 4
    jae .item
    imul eax, eax, 24
    lea rdi, [hp_stack + rax]
    push rsi
    lea rsi, [hp_page]
    mov ecx, 24 / 4
    rep movsd
    pop rsi
    inc dword [hp_sp]
    jmp .item
.g11:
    cmp eax, 11                         ; pop
    jne .item
    mov eax, [hp_sp]
    test eax, eax
    jz .item
    dec eax
    mov [hp_sp], eax
    imul eax, eax, 24
    push rsi
    lea rsi, [hp_stack + rax]
    lea rdi, [hp_page]
    mov ecx, 24 / 4
    rep movsd
    pop rsi
    jmp .item

.local:
    cmp r9d, 4                          ; extended usage: page in the high word
    je .local_full
    mov ecx, [hp_page]
    shl ecx, 16
    or edx, ecx
.local_full:
    cmp eax, 0
    jne .l1
    mov eax, [hp_nusages]
    cmp eax, 16
    jae .item
    mov [hp_usages + rax * 4], edx
    inc dword [hp_nusages]
    jmp .item
.l1:
    cmp eax, 1
    jne .l2
    mov [hp_umin], edx
    mov dword [hp_range], 1
    jmp .item
.l2:
    cmp eax, 2
    jne .item
    mov [hp_umax], edx
    jmp .item
.done:
    pop r13
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

; hid_usage(ECX = element) -> EAX = page << 16 | usage for that element
hid_usage:
    cmp dword [hp_range], 0
    je .list
    mov eax, [hp_umin]
    add eax, ecx
    cmp eax, [hp_umax]
    jbe .out
    mov eax, [hp_umax]
    ret
.list:
    mov eax, [hp_nusages]
    test eax, eax
    jz .none
    dec eax
    cmp ecx, eax
    cmovb eax, ecx
    mov eax, [hp_usages + rax * 4]
.out:
    ret
.none:
    mov eax, [hp_page]
    shl eax, 16
    ret

; hid_parse_input(EDX = Input item flags): turn it into fields, advance offsets
hid_parse_input:
    push rbx
    push rcx
    push r10
    push r11
    mov r10d, edx                       ; flags
    mov eax, [hp_id]
    movzx r11d, word [hp_off + rax * 2] ; where this item starts
    test r10d, 1                        ; constant: padding
    jnz .advance
    cmp dword [hp_size], 32
    ja .advance
    xor ecx, ecx
    call hid_usage
    mov ebx, eax
    shr ebx, 16                         ; page of the first element
    test r10d, 2
    jz .array
    cmp ebx, 7                          ; keyboard bitmap
    jne .not_keybits
    cmp dword [hp_size], 1
    jne .advance
    mov dl, K_KEYBITS
    call hid_add_field
    or dword [r12 + HD_FLAGS], HF_KBD
    jmp .advance
.not_keybits:
    cmp ebx, 9                          ; buttons
    jne .elements
    cmp dword [hp_size], 1
    jne .advance
    mov dl, K_BUTTONS
    call hid_add_field
    jmp .advance
.elements:                              ; one field per element
    xor ecx, ecx
.element:
    cmp ecx, [hp_count]
    jae .advance
    call hid_usage
    mov dl, 0
    cmp eax, 0x00010030
    jne .y
    mov dl, K_X
    test r10d, 4
    jnz .one
    mov dl, K_XABS
    jmp .one
.y:
    cmp eax, 0x00010031
    jne .wheel
    mov dl, K_Y
    test r10d, 4
    jnz .one
    mov dl, K_YABS
    jmp .one
.wheel:
    cmp eax, 0x00010038
    jne .pan
    mov dl, K_WHEEL
    jmp .one
.pan:
    cmp eax, 0x000C0238
    jne .next_element
    mov dl, K_PAN
.one:
    push r11
    mov eax, [hp_size]
    imul eax, ecx
    add r11d, eax
    push qword [hp_count]
    mov dword [hp_count], 1
    call hid_add_field
    pop qword [hp_count]
    pop r11
    cmp dl, K_WHEEL                     ; a wheel alone is not a mouse
    je .next_element
    cmp dl, K_PAN
    je .next_element
    or dword [r12 + HD_FLAGS], HF_MOUSE
.next_element:
    inc ecx
    jmp .element
.array:
    cmp ebx, 7
    jne .advance
    mov dl, K_KEYARRAY
    call hid_add_field
    or dword [r12 + HD_FLAGS], HF_KBD
.advance:
    mov eax, [hp_size]
    imul eax, [hp_count]
    mov ecx, [hp_id]
    add [hp_off + rcx * 2], ax
    pop r11
    pop r10
    pop rcx
    pop rbx
    ret

; hid_add_field(DL = kind, R11D = bit offset, ECX = first element): from the
; parser's current size, count, limits and usages
hid_add_field:
    push rax
    push rbx
    push rcx
    mov eax, [r12 + HD_NFIELDS]
    cmp eax, HID_FIELDS
    jae .full
    inc dword [r12 + HD_NFIELDS]
    shl eax, 4
    lea rbx, [r12 + HD_FIELDS + rax]
    mov eax, [hp_id]
    mov [rbx + F_ID], al
    mov [rbx + F_KIND], dl
    mov eax, [hp_size]
    mov [rbx + F_SIZE], al
    mov eax, [hp_count]
    cmp eax, 255
    jbe .count
    mov eax, 255
.count:
    mov [rbx + F_COUNT], al
    mov [rbx + F_OFF], r11w
    call hid_usage                      ; usage of element ECX
    cmp dl, K_KEYARRAY                  ; arrays index from the usage minimum
    jne .umin
    xor eax, eax
    cmp dword [hp_range], 0
    je .umin
    mov eax, [hp_umin]
.umin:
    mov [rbx + F_UMIN], ax
    mov eax, [hp_lmin]
    mov [rbx + F_LMIN], eax
    mov eax, [hp_lmax]
    mov [rbx + F_LMAX], eax
.full:
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  hid_input(R12 = HID record, RSI = report, ECX = length, EDX = report ID,
;  or -1 to take it from the first byte when the device numbers its reports)
; -----------------------------------------------------------------------------
hid_input:
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
    push r13
    push r14
    push r15
    cmp edx, -1
    jne .have_id
    xor edx, edx
    test dword [r12 + HD_FLAGS], HF_IDS
    jz .have_id
    test ecx, ecx
    jz .out
    movzx edx, byte [rsi]
    inc rsi
    dec ecx
.have_id:
    mov r13d, edx                       ; report ID
    mov [hi_len], ecx
    mov [hi_data], rsi
    mov dword [hid_ncur], 0
    xor r9d, r9d                        ; dx
    xor r10d, r10d                      ; dy
    xor r11d, r11d                      ; wheel | pan << 16
    xor r14d, r14d                      ; buttons
    xor r15d, r15d                      ; bit 0 keys seen, 1 mouse, 2 absolute
    lea rbx, [r12 + HD_FIELDS]
    mov edi, [r12 + HD_NFIELDS]
.field:
    test edi, edi
    jz .fields_done
    movzx eax, byte [rbx + F_ID]
    cmp eax, r13d
    jne .next_field
    movzx eax, byte [rbx + F_KIND]
    cmp eax, K_KEYARRAY
    je .keyarray
    cmp eax, K_KEYBITS
    je .keybits
    cmp eax, K_BUTTONS
    je .buttons
    or r15d, 2
    movzx edx, word [rbx + F_OFF]
    call hid_field_value                ; one value, signed if the limits are
    jc .next_field
    movzx ecx, byte [rbx + F_KIND]
    cmp ecx, K_X
    jne .f_y
    add r9d, eax
    jmp .next_field
.f_y:
    cmp ecx, K_Y
    jne .f_wheel
    add r10d, eax
    jmp .next_field
.f_wheel:
    cmp ecx, K_WHEEL
    jne .f_pan
    add r11w, ax
    jmp .next_field
.f_pan:
    cmp ecx, K_PAN
    jne .f_abs
    shl eax, 16
    add r11d, eax
    jmp .next_field
.f_abs:
    call hid_scale_abs                  ; 0..65535 across the field's range
    or r15d, 4
    cmp ecx, K_XABS
    jne .f_yabs
    mov r9d, eax
    jmp .next_field
.f_yabs:
    mov r10d, eax
    jmp .next_field

.buttons:
    or r15d, 2
    movzx ecx, byte [rbx + F_COUNT]
    cmp ecx, 16
    jbe .bcount
    mov ecx, 16
.bcount:
    movzx edx, word [rbx + F_OFF]
    mov r8d, ecx
    call hid_bits
    jc .next_field
    movzx ecx, word [rbx + F_UMIN]       ; button 1 is bit 0
    dec ecx
    jns .bshift
    xor ecx, ecx
.bshift:
    shl eax, cl
    or r14d, eax
    jmp .next_field

.keybits:
    or r15d, 1
    movzx ecx, byte [rbx + F_COUNT]
    xor r8d, r8d
.bit:
    cmp r8d, ecx
    jae .next_field
    movzx edx, word [rbx + F_OFF]
    add edx, r8d
    push rcx
    push r8
    mov r8d, 1
    call hid_bits
    pop r8
    pop rcx
    jc .next_field
    test eax, eax
    jz .bit_next
    movzx eax, word [rbx + F_UMIN]
    add eax, r8d
    call hid_add_key
.bit_next:
    inc r8d
    jmp .bit

.keyarray:
    or r15d, 1
    movzx ecx, byte [rbx + F_COUNT]
    xor r8d, r8d
.slot:
    cmp r8d, ecx
    jae .next_field
    movzx eax, byte [rbx + F_SIZE]
    imul eax, r8d
    movzx edx, word [rbx + F_OFF]
    add edx, eax
    push rcx
    push r8
    movzx r8d, byte [rbx + F_SIZE]
    call hid_bits
    pop r8
    pop rcx
    jc .next_field
    sub eax, [rbx + F_LMIN]             ; index into the usage range
    jl .slot_next
    mov edx, [rbx + F_LMAX]
    sub edx, [rbx + F_LMIN]
    cmp eax, edx
    ja .slot_next
    movzx edx, word [rbx + F_UMIN]
    add eax, edx
    call hid_add_key
.slot_next:
    inc r8d
    jmp .slot

.next_field:
    add rbx, 16
    dec edi
    jmp .field

.fields_done:
    test r15d, 1
    jz .mouse
    call hid_keys
.mouse:
    test r15d, 2
    jz .out
    mov edi, r9d
    mov esi, r10d
    mov edx, r11d
    mov ecx, r14d
    mov r8d, r15d
    shr r8d, 2                          ; 1 if absolute
    and r8d, 1
    call pointer_event
.out:
    pop r15
    pop r14
    pop r13
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

; hid_bits(EDX = bit offset, R8D = bits, 1..32) -> EAX, from hi_data/hi_len;
; CF if the report is too short. Preserves others.
hid_bits:
    push rcx
    push rdx
    push rsi
    push rdi
    lea eax, [edx + r8d]
    mov ecx, [hi_len]
    shl ecx, 3
    cmp eax, ecx
    ja .short
    mov rsi, [hi_data]
    mov edi, edx
    shr edi, 3                          ; first byte
    xor eax, eax
    mov ecx, 4                          ; gather bytes first+4 .. first, in range
.gather:
    shl rax, 8
    lea edx, [edi + ecx]
    cmp edx, [hi_len]
    jae .skip
    movzx edx, byte [rsi + rdx]
    or rax, rdx
.skip:
    dec ecx
    jns .gather
    mov ecx, [rsp + 16]                 ; the bit offset
    and ecx, 7
    shr rax, cl
    cmp r8d, 32
    jae .done
    mov ecx, r8d
    mov edx, 1
    shl rdx, cl
    dec rdx
    and rax, rdx
.done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    clc
    ret
.short:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    stc
    ret

; hid_field_value(RBX = field, EDX = bit offset) -> EAX, sign-extended when
; the logical minimum is negative; CF if missing
hid_field_value:
    push rcx
    push r8
    movzx r8d, byte [rbx + F_SIZE]
    call hid_bits
    jc .out
    cmp dword [rbx + F_LMIN], 0
    jge .ok
    mov ecx, 32
    sub ecx, r8d
    shl eax, cl
    sar eax, cl
.ok:
    clc
.out:
    pop r8
    pop rcx
    ret

; hid_scale_abs(EAX = value, RBX = field) -> EAX = 0..65535
hid_scale_abs:
    push rcx
    push rdx
    sub eax, [rbx + F_LMIN]
    jns .pos
    xor eax, eax
.pos:
    mov ecx, [rbx + F_LMAX]
    sub ecx, [rbx + F_LMIN]
    jle .zero
    inc ecx
    shl rax, 16
    xor edx, edx
    div rcx
    cmp eax, 65535
    jbe .out
    mov eax, 65535
    jmp .out
.zero:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; hid_add_key(EAX = usage): into this report's pressed list
hid_add_key:
    cmp eax, 4                          ; 0 none, 1-3 rollover errors
    jb .out
    push rcx
    mov ecx, [hid_ncur]
    cmp ecx, HID_KEYS
    jae .full
    mov [hid_cur + rcx * 2], ax
    inc dword [hid_ncur]
.full:
    pop rcx
.out:
    ret

; hid_keys(R12 = record, R13D = report ID): compare with the last report,
; new presses become key codes
hid_keys:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    xor eax, eax                        ; modifiers from E0..E7
    xor ecx, ecx
.mods:
    cmp ecx, [hid_ncur]
    jae .mods_done
    movzx edx, word [hid_cur + rcx * 2]
    sub edx, 0xE0
    cmp edx, 7
    ja .mods_next
    bts eax, edx
.mods_next:
    inc ecx
    jmp .mods
.mods_done:
    mov [hid_mods], al
    lea rbx, [r12 + HD_PREV]            ; this report's slot
    lea edx, [r13d + 1]
    xor ecx, ecx
.find:
    cmp ecx, 4
    jae .take
    cmp [rbx], dl
    je .slot
    add rbx, 32
    inc ecx
    jmp .find
.take:
    lea rbx, [r12 + HD_PREV]
    xor ecx, ecx
.free:
    cmp ecx, 4
    jae .slot_reuse
    cmp byte [rbx], 0
    je .claim
    add rbx, 32
    inc ecx
    jmp .free
.slot_reuse:
    lea rbx, [r12 + HD_PREV]
.claim:
    mov [rbx], dl
    mov byte [rbx + 1], 0
.slot:
    xor esi, esi                        ; each pressed key
.press:
    cmp esi, [hid_ncur]
    jae .released
    movzx eax, word [hid_cur + rsi * 2]
    cmp eax, 0xE0                       ; modifiers are not keys
    jae .press_next
    movzx ecx, byte [rbx + 1]           ; held before?
    xor edi, edi
.held:
    cmp edi, ecx
    jae .new
    cmp [rbx + 2 + rdi], al
    je .press_next
    inc edi
    jmp .held
.new:
    mov [hid_repeat_key], eax
    lea rdx, [r12 + r13]
    mov [hid_repeat_src], rdx
    push rax
    push rdi
    mov edi, 500
    call usb_deadline
    mov [hid_repeat_at], rax
    pop rdi
    pop rax
    call hid_press
.press_next:
    inc esi
    jmp .press
.released:
    lea rdx, [r12 + r13]                ; the repeating key let go?
    cmp [hid_repeat_src], rdx
    jne .remember
    mov eax, [hid_repeat_key]
    xor ecx, ecx
.still:
    cmp ecx, [hid_ncur]
    jae .stop
    cmp [hid_cur + rcx * 2], ax
    je .remember
    inc ecx
    jmp .still
.stop:
    mov dword [hid_repeat_key], 0
.remember:
    xor ecx, ecx                        ; this report becomes the last one
    xor edi, edi
.copy:
    cmp ecx, [hid_ncur]
    jae .copied
    movzx eax, word [hid_cur + rcx * 2]
    cmp eax, 0xFF
    ja .copy_next
    mov [rbx + 2 + rdi], al
    inc edi
.copy_next:
    inc ecx
    jmp .copy
.copied:
    mov [rbx + 1], dil
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; hid_key_repeat: from the main loop
hid_key_repeat:
    mov eax, [hid_repeat_key]
    test eax, eax
    jz .out
    cmp eax, 0x39                       ; never repeat caps lock
    je .out
    push rdx
    push rsi
    mov rsi, [hid_repeat_at]
    call usb_expired
    jnc .done
    push rdi
    mov edi, 33
    call usb_deadline
    mov [hid_repeat_at], rax
    pop rdi
    mov eax, [hid_repeat_key]
    pushfq
    cli
    call hid_press
    popfq
.done:
    pop rsi
    pop rdx
.out:
    ret

; hid_press(EAX = usage): translate with the current modifiers, queue it.
; Interrupts off.
hid_press:
    push rdx
    cmp eax, 0x39
    je .caps
    lea rdx, [hid_special]              ; arrows, home, end, F1..F12 and the like
.special:
    cmp byte [rdx], 0
    je .not_special
    cmp [rdx], al
    je .found
    add rdx, 2
    jmp .special
.found:
    movzx edx, byte [rdx + 1]
    jmp .emit
.not_special:
    cmp eax, 0x54                       ; keypad
    jb .main
    cmp eax, 0x63
    ja .out
    lea rdx, [hid_keypad]
    movzx edx, byte [rdx + rax - 0x54]
    jmp .emit
.main:
    cmp eax, 0x38
    ja .out
    lea rdx, [hid_map]
    test byte [hid_mods], 0x22          ; either shift
    jz .lookup
    lea rdx, [hid_map_shift]
.lookup:
    movzx edx, byte [rdx + rax - 4]
    cmp eax, 0x1D                       ; letters: caps lock and ctrl
    ja .other
    cmp byte [hid_caps], 0
    je .ctrl
    xor edx, 0x20
.ctrl:
    test byte [hid_mods], 0x11
    jz .emit
    and edx, 0x1F
    jmp .emit
.other:
    cmp edx, 9                          ; shift+tab
    jne .punct
    test byte [hid_mods], 0x22
    jz .emit
    mov edx, KEY_BTAB
    jmp .emit
.punct:
    test byte [hid_mods], 0x11          ; ctrl+[ \ ] ^ _, and ctrl+/ as ctrl+_
    jz .emit
    cmp edx, '/'
    jne .ctrl_punct
    mov edx, '_'
.ctrl_punct:
    cmp edx, '['
    jb .emit
    cmp edx, '_'
    ja .emit
    and edx, 0x1F
.emit:
    test edx, edx
    jz .out
    push rax
    test byte [hid_mods], 0x44          ; alt+key: ESC first
    jz .push
    mov al, 27
    call kbd_push
.push:
    mov al, dl
    call kbd_push
    pop rax
.out:
    pop rdx
    ret
.caps:
    xor byte [hid_caps], 1
    pop rdx
    ret

section .rodata
str_role_kbd:   db 'keyboard', 0
str_role_mouse: db 'mouse', 0
str_hid_kbd:    db 'keyboard', 0
str_hid_mouse:  db 'mouse', 0
str_hid_report: db 'report', 0
str_hid_bootp:  db 'boot', 0
align 8
; boot protocol layouts, as fields
hid_boot_kbd:
    db 0, K_KEYBITS, 1, 8
    dw 0, 0xE0
    dd 0, 1
    db 0, K_KEYARRAY, 8, 6
    dw 16, 0
    dd 0, 255
hid_boot_mouse:
    db 0, K_BUTTONS, 1, 3
    dw 0, 1
    dd 0, 1
    db 0, K_X, 8, 1
    dw 8, 0x30
    dd -127, 127
    db 0, K_Y, 8, 1
    dw 16, 0x31
    dd -127, 127
; HID usages 0x04..0x38
hid_map:
    db 'abcdefghijklmnopqrstuvwxyz'
    db '1234567890'
    db 10, 27, 8, 9, ' '
    db '-=[]\#;', "'", '`,./'
hid_map_shift:
    db 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'
    db '!@#$%^&*()'
    db 10, 27, 8, 9, ' '
    db '_+{}|~:"~<>?'
; keypad usages 0x54..0x63
hid_keypad:
    db '/*-+', 10, '1234567890.'
; usages that are keys past ASCII, and their codes (kbd.asm)
hid_special:
    db 0x4F, KEY_RIGHT, 0x50, KEY_LEFT, 0x51, KEY_DOWN, 0x52, KEY_UP
    db 0x4A, KEY_HOME, 0x4D, KEY_END, 0x4B, KEY_PGUP, 0x4E, KEY_PGDN
    db 0x49, KEY_INS, 0x4C, KEY_DEL
    db 0x3A, KEY_F1, 0x3B, KEY_F1 + 1, 0x3C, KEY_F1 + 2, 0x3D, KEY_F1 + 3
    db 0x3E, KEY_F1 + 4, 0x3F, KEY_F1 + 5, 0x40, KEY_F1 + 6, 0x41, KEY_F1 + 7
    db 0x42, KEY_F1 + 8, 0x43, KEY_F1 + 9, 0x44, KEY_F1 + 10, 0x45, KEY_F1 + 11
    db 0

section .data
hid_caps:       db 0
hid_mods:       db 0

section .bss
alignb 8
hid_repeat_key: resd 1
hid_ncur:       resd 1
hid_repeat_at:  resq 1
hid_repeat_src: resq 1
hi_data:        resq 1
hi_len:         resd 1
alignb 8
hid_cur:        resw HID_KEYS
; parser state (zeroed per descriptor)
alignb 8
hp_state:
hp_page:        resd 1                  ; global items: page, lmin, lmax,
hp_lmin:        resd 1                  ; size, count, id (pushed together)
hp_lmax:        resd 1
hp_size:        resd 1
hp_count:       resd 1
hp_id:          resd 1
hp_sp:          resd 1
hp_nusages:     resd 1
hp_range:       resd 1
hp_umin:        resd 1
hp_umax:        resd 1
hp_usages:      resd 16
hp_stack:       resb 4 * 24
hp_off:         resw 256
alignb 8
HP_STATE_SIZE   equ ($ - hp_state + 7) & ~7
hid_devs:       resb MAX_HID * HD_SIZE
