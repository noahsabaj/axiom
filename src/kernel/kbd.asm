; =============================================================================
;  kbd.asm - keyboard input: the i8042 PS/2 controller (QEMU, or firmware USB
;  legacy emulation) and the serial port, both feeding one ring of key codes.
;
;  Key codes: printable ASCII, 8 backspace, 9 tab, 10 enter, 27 escape,
;  ctrl+letter = 1..26 (and ctrl+[ \ ] ^ _ / as xterm has them), the keys
;  past ASCII below; alt+key is 27 first.
; =============================================================================

KEY_UP          equ 0x80                ; (lxtty.asm's lt_key_seqs, in order)
KEY_DOWN        equ 0x81
KEY_LEFT        equ 0x82
KEY_RIGHT       equ 0x83
KEY_HOME        equ 0x84
KEY_END         equ 0x85
KEY_PGUP        equ 0x86
KEY_PGDN        equ 0x87
KEY_INS         equ 0x88
KEY_DEL         equ 0x89
KEY_BTAB        equ 0x8A                ; shift+tab
KEY_F1          equ 0x90                ; to F12, KEY_F1 + 11
KBD_RING        equ 4096                ; key codes waiting (a line pasted, typed down COM1)

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
    cmp ecx, 0x38                       ; right alt
    je .alt_down
    lea rdx, [kbd_e0_map]
.e0_find:
    cmp byte [rdx], 0
    je .ignore
    cmp [rdx], cl
    je .e0_found
    add rdx, 2
    jmp .e0_find
.e0_found:
    mov dl, [rdx + 1]
    jmp .emit
.ext_release:
    cmp ecx, 0x1D
    je .ctrl_up
    cmp ecx, 0x38
    je .alt_up
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
    cmp ecx, 0x38
    je .alt_down
    cmp ecx, 0x3A
    je .caps
    ja .fkeys
    lea rdx, [kbd_map]
    cmp byte [kbd_shift], 0
    je .lookup
    lea rdx, [kbd_map_shift]
.lookup:
    movzx edx, byte [rdx + rcx]
    test edx, edx
    jz .ignore
    call cfg_key                        ; keyboard.layout
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
    cmp edx, 9                          ; shift+tab
    jne .no_btab
    cmp byte [kbd_shift], 0
    je .emit
    mov dl, KEY_BTAB
    jmp .emit
.no_btab:
    cmp byte [kbd_ctrl], 0
    je .emit
    cmp edx, '/'                        ; ctrl+/ is ctrl+_
    jne .ctrl_punct
    mov dl, '_'
.ctrl_punct:
    cmp edx, '['                        ; ctrl+[ \ ] ^ _
    jb .emit
    cmp edx, '_'
    ja .emit
    and edx, 0x1F
.emit:
    cmp byte [kbd_alt], 0               ; alt+key: ESC first
    je .push
    mov al, 27
    call kbd_push
.push:
    mov al, dl
    jmp kbd_push
.fkeys:
    lea edx, [ecx - 0x3B + KEY_F1]      ; F1..F10
    cmp ecx, 0x44
    jbe .emit
    mov dl, KEY_F1 + 10
    cmp ecx, 0x57
    je .emit
    mov dl, KEY_F1 + 11
    cmp ecx, 0x58
    je .emit
    ret
.release:
    cmp ecx, 0x2A
    je .shift_up
    cmp ecx, 0x36
    je .shift_up
    cmp ecx, 0x1D
    je .ctrl_up
    cmp ecx, 0x38
    je .alt_up
.ignore:
    ret
.alt_down:
    mov byte [kbd_alt], 1
    ret
.alt_up:
    mov byte [kbd_alt], 0
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
    movzx ecx, word [kbd_head]
    lea edx, [ecx + 1]
    and edx, KBD_RING - 1
    cmp dx, [kbd_tail]
    je .full
    push rdx
    lea rdx, [kbd_ring]
    mov [rdx + rcx], al
    pop rdx
    mov [kbd_head], dx
.full:
    pop rdx
    pop rcx
    ret

; kbd_getc -> EAX = next key code, 0 if none. Also polls the serial port.
kbd_getc:
    push rcx
    push rdx
    call serial_poll
    movzx ecx, word [kbd_tail]
    cmp cx, [kbd_head]
    je .empty
    lea rdx, [kbd_ring]
    movzx eax, byte [rdx + rcx]
    inc ecx
    and ecx, KBD_RING - 1
    mov [kbd_tail], cx
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
    mov ax, [kbd_tail]
    cmp ax, [kbd_head]
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
kbd_e0_map:                             ; E0 scan codes, and their keys
    db 0x48, KEY_UP, 0x50, KEY_DOWN, 0x4B, KEY_LEFT, 0x4D, KEY_RIGHT
    db 0x47, KEY_HOME, 0x4F, KEY_END, 0x49, KEY_PGUP, 0x51, KEY_PGDN
    db 0x52, KEY_INS, 0x53, KEY_DEL, 0x1C, 10, 0x35, '/'
    db 0
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
kbd_alt:        db 0
kbd_caps:       db 0
kbd_head:       dw 0
kbd_tail:       dw 0

section .bss
kbd_ring:       resb KBD_RING
