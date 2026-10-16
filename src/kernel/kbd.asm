; =============================================================================
;  kbd.asm - keyboard input: the i8042 PS/2 controller (QEMU, or firmware USB
;  legacy emulation) and the serial port, both feeding one ring of key codes.
;
;  Key codes: printable ASCII, 8 backspace, 9 tab, 10 enter, 27 escape,
;  ctrl+letter = 1..26, KEY_UP/DOWN/LEFT/RIGHT below.
; =============================================================================

KEY_UP          equ 0x11
KEY_DOWN        equ 0x12
KEY_LEFT        equ 0x13
KEY_RIGHT       equ 0x14

section .text

kbd_init:
    push rbx
    in al, 0x64
    cmp al, 0xFF                        ; nothing decodes the port
    je .absent
    mov ecx, 32                         ; drain stale bytes
.drain:
    in al, 0x64
    test al, 1
    jz .drained
    in al, 0x60
    dec ecx
    jnz .drain
.drained:
    call kbd_wait_write                 ; read the controller configuration
    jc .absent
    mov al, 0x20
    out 0x64, al
    call kbd_wait_read
    jc .absent
    in al, 0x60
    or al, 0x41                         ; port 1 interrupt, set-1 translation
    and al, ~0x10                       ; port 1 clock on
    mov bl, al
    call kbd_wait_write
    jc .absent
    mov al, 0x60
    out 0x64, al
    call kbd_wait_write
    jc .absent
    mov al, bl
    out 0x60, al
    call kbd_wait_write
    jc .absent
    mov al, 0xAE                        ; enable port 1
    out 0x64, al

    mov edi, VEC_KBD
    lea rsi, [kbd_irq]
    call irq_register
    mov edi, 1
    mov esi, VEC_KBD
    lea rax, [percpu]
    mov edx, [rax + PC_APIC_ID]         ; deliver to the BSP
    call ioapic_route_isa
    mov byte [kbd_present], 1
.absent:
    pop rbx
    ret

; wait until the controller accepts a byte; CF = 1 on timeout
kbd_wait_write:
    push rcx
    mov ecx, 100000
.poll:
    in al, 0x64
    test al, 2
    jz .ready
    pause
    dec ecx
    jnz .poll
    pop rcx
    stc
    ret
.ready:
    pop rcx
    clc
    ret

; wait until the controller has a byte for us; CF = 1 on timeout
kbd_wait_read:
    push rcx
    mov ecx, 100000
.poll:
    in al, 0x64
    test al, 1
    jnz .ready
    pause
    dec ecx
    jnz .poll
    pop rcx
    stc
    ret
.ready:
    pop rcx
    clc
    ret

; IRQ 1
kbd_irq:
    in al, 0x64
    test al, 1
    jz .out
    test al, 0x20                       ; mouse byte: discard
    jnz .discard
    in al, 0x60
    jmp kbd_scancode
.discard:
    in al, 0x60
.out:
    ret

; kbd_scancode(AL = set-1 byte)
kbd_scancode:
    cmp al, 0xE0
    jne .not_prefix
    mov byte [kbd_e0], 1
    ret
.not_prefix:
    movzx ecx, al
    and ecx, 0x7F
    cmp byte [kbd_e0], 0
    je .plain
    mov byte [kbd_e0], 0                ; extended keys
    test al, 0x80
    jnz .ext_release
    cmp ecx, 0x1D
    je .ctrl_down
    mov dl, KEY_UP
    cmp ecx, 0x48
    je .emit
    mov dl, KEY_DOWN
    cmp ecx, 0x50
    je .emit
    mov dl, KEY_LEFT
    cmp ecx, 0x4B
    je .emit
    mov dl, KEY_RIGHT
    cmp ecx, 0x4D
    je .emit
    mov dl, 10
    cmp ecx, 0x1C                       ; keypad enter
    je .emit
    mov dl, '/'
    cmp ecx, 0x35
    je .emit
    ret
.ext_release:
    cmp ecx, 0x1D
    je .ctrl_up
    ret
.plain:
    test al, 0x80
    jnz .release
    cmp ecx, 0x2A
    je .shift_down
    cmp ecx, 0x36
    je .shift_down
    cmp ecx, 0x1D
    je .ctrl_down
    cmp ecx, 0x3A
    je .caps
    ja .ignore                          ; function keys, keypad
    lea rdx, [kbd_map]
    cmp byte [kbd_shift], 0
    je .lookup
    lea rdx, [kbd_map_shift]
.lookup:
    movzx edx, byte [rdx + rcx]
    test edx, edx
    jz .ignore
    mov eax, edx                        ; caps lock flips letters
    or eax, 0x20
    cmp eax, 'a'
    jb .no_letter
    cmp eax, 'z'
    ja .no_letter
    cmp byte [kbd_caps], 0
    je .ctrl_check
    xor edx, 0x20
.ctrl_check:
    cmp byte [kbd_ctrl], 0
    je .emit
    and edx, 0x1F                       ; ctrl+letter
    jmp .emit
.no_letter:
.emit:
    mov al, dl
    jmp kbd_push
.release:
    cmp ecx, 0x2A
    je .shift_up
    cmp ecx, 0x36
    je .shift_up
    cmp ecx, 0x1D
    je .ctrl_up
.ignore:
    ret
.shift_down:
    mov byte [kbd_shift], 1
    ret
.shift_up:
    mov byte [kbd_shift], 0
    ret
.ctrl_down:
    mov byte [kbd_ctrl], 1
    ret
.ctrl_up:
    mov byte [kbd_ctrl], 0
    ret
.caps:
    xor byte [kbd_caps], 1
    ret

; kbd_push(AL = key code): append to the ring (dropped when full). Preserves all.
kbd_push:
    push rcx
    push rdx
    movzx ecx, byte [kbd_head]
    lea edx, [ecx + 1]
    and edx, 0xFF
    cmp dl, [kbd_tail]
    je .full
    lea rdx, [kbd_ring]
    mov [rdx + rcx], al
    inc cl
    mov [kbd_head], cl
.full:
    pop rdx
    pop rcx
    ret

; kbd_getc -> EAX = next key code, 0 if none. Also polls the serial port.
kbd_getc:
    push rcx
    push rdx
    call serial_poll
    movzx ecx, byte [kbd_tail]
    cmp cl, [kbd_head]
    je .empty
    lea rdx, [kbd_ring]
    movzx eax, byte [rdx + rcx]
    inc cl
    mov [kbd_tail], cl
    jmp .out
.empty:
    xor eax, eax
.out:
    pop rdx
    pop rcx
    ret

; kbd_pending -> ZF clear if a key is waiting
kbd_pending:
    push rax
    mov al, [kbd_tail]
    cmp al, [kbd_head]
    pop rax
    ret

; serial_poll: bytes from COM1 become key codes (CR -> enter, DEL -> backspace)
serial_poll:
    cmp byte [serial_present], 0
    je .out
    push rax
    push rdx
.next:
    mov dx, 0x3F8 + 5
    in al, dx
    test al, 1
    jz .done
    mov dx, 0x3F8
    in al, dx
    cmp al, 13
    jne .not_cr
    mov al, 10
.not_cr:
    cmp al, 127
    jne .not_del
    mov al, 8
.not_del:
    pushfq
    cli
    call kbd_push
    popfq
    jmp .next
.done:
    pop rdx
    pop rax
.out:
    ret

section .rodata
kbd_map:
    db 0, 27, '1234567890-=', 8, 9
    db 'qwertyuiop[]', 10, 0
    db "asdfghjkl;'`", 0, '\'
    db 'zxcvbnm,./', 0, '*', 0, ' '
kbd_map_shift:
    db 0, 27, '!@#$%^&*()_+', 8, 9
    db 'QWERTYUIOP{}', 10, 0
    db 'ASDFGHJKL:"~', 0, '|'
    db 'ZXCVBNM<>?', 0, '*', 0, ' '

section .data
kbd_present:    db 0
kbd_e0:         db 0
kbd_shift:      db 0
kbd_ctrl:       db 0
kbd_caps:       db 0
kbd_head:       db 0
kbd_tail:       db 0

section .bss
kbd_ring:       resb 256
