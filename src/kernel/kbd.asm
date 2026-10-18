; =============================================================================
;  kbd.asm - keyboard input: the i8042 PS/2 controller (QEMU, or firmware USB
;  legacy emulation) and the serial port, both feeding one ring of key codes.
;
;  Key codes: printable ASCII, 8 backspace, 9 tab, 10 enter, 27 escape,
;  ctrl+letter = 1..26 (and ctrl+[ \ ] ^ _ / as xterm has them), the keys
;  past ASCII below; alt+key is 27 first.
;
;  Keys going down and up are a second ring, for programs that ask (games,
;  WNF_KEYS): each key once each way, as its USB HID usage, from either
;  keyboard (key_event; the PS/2 one's scan codes through kbd_usage).
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
KEY_RING        equ 256                 ; keys down and up waiting (key_head wraps)
KBD_USAGES      equ 0x59                ; set-1 scan codes kbd_usage has

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
    cmp byte [kbd_skip], 0              ; the rest of pause's E1 1D 45 E1 9D C5
    je .take
    dec byte [kbd_skip]
    ret
.take:
    cmp al, 0xE1
    jne .not_e1
    mov byte [kbd_skip], 2
    ret
.not_e1:
    cmp al, 0xE0
    jne .not_prefix
    mov byte [kbd_e0], 1
    ret
.not_prefix:
    movzx edx, byte [kbd_e0]
    mov byte [kbd_e0], 0
    push rax
    push rdx
    call kbd_cook                       ; a key code
    pop rdx
    pop rax
    jmp kbd_raw                         ; and the key, down or up

; kbd_cook(AL = set-1 byte, EDX = 1 after E0): the modifiers kept, a key
; pressed made a key code (kbd_push)
kbd_cook:
    movzx ecx, al
    and ecx, 0x7F
    test edx, edx
    jz .plain
    test al, 0x80                       ; extended keys
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

; kbd_raw(AL = set-1 byte, EDX = 1 after E0): the key as a USB HID usage,
; down or up (key_event)
kbd_raw:
    movzx ecx, al
    and ecx, 0x7F
    test edx, edx
    jnz .ext
    cmp ecx, KBD_USAGES
    jae .out
    lea rdx, [kbd_usage]
    movzx ecx, byte [rdx + rcx]
    jmp .event
.ext:
    lea rdx, [kbd_e0_usage]
.find:
    cmp byte [rdx], 0
    je .out
    cmp [rdx], cl
    je .found
    add rdx, 2
    jmp .find
.found:
    movzx ecx, byte [rdx + 1]
.event:
    test ecx, ecx
    jz .out
    xor edx, edx                        ; the top bit: let go
    test al, 0x80
    setz dl
    mov eax, ecx
    jmp key_event
.out:
    ret

; key_event(EAX = a USB HID usage, EDX = 1 it went down, 0 up): queued for
; the window with the keys (key_next), once each way: a key held, repeating,
; goes down only once, and one never seen down does not come up. Any
; context. Preserves all.
key_event:
    push rax
    push rcx
    push rdx
    pushfq
    cli
    and eax, 0xFF
    test edx, edx
    jz .up
    bts [key_down], eax
    jc .out                             ; down already
    jmp .queue
.up:
    btr [key_down], eax
    jnc .out
.queue:
    shl edx, 8                          ; usage | down << 8 | WM_* << 16
    or edx, eax
    call kbd_mods
    shl eax, 16
    or edx, eax
    movzx ecx, byte [key_head]
    lea eax, [ecx + 1]
    cmp al, [key_tail]
    je .out                             ; full: dropped
    lea rax, [key_ring]
    mov [rax + rcx * 4], edx
    inc cl
    mov [key_head], cl
.out:
    popfq
    pop rdx
    pop rcx
    pop rax
    ret

; key_next -> EAX = the next key down or up (as key_event queued it: usage |
; 1 << 8 if down | WM_* << 16), CF if none. Main loop.
key_next:
    push rcx
    push rdx
    movzx ecx, byte [key_tail]
    cmp cl, [key_head]
    je .none
    lea rdx, [key_ring]
    mov eax, [rdx + rcx * 4]
    inc cl
    mov [key_tail], cl
    clc
    jmp .out
.none:
    stc
.out:
    pop rdx
    pop rcx
    ret

; kbd_push(AL = key code): append to the ring (dropped when full), with the
; modifiers held as it was pressed. Preserves all.
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
    push rax
    call kbd_mods
    lea rdx, [kbd_mring]
    mov [rdx + rcx], al
    pop rax
    pop rdx
    mov [kbd_head], dx
.full:
    pop rdx
    pop rcx
    ret

; kbd_mods -> AL = the modifiers held now, WM_* (either keyboard). Preserves
; others.
kbd_mods:
    push rcx
    xor eax, eax
    movzx ecx, byte [hid_mods]          ; USB: E0..E7, left then right
    mov ch, cl
    shr ch, 4
    or cl, ch                           ; ctrl 1, shift 2, alt 4, gui 8
    test cl, 2
    jz .ctrl
    or al, WM_SHIFT
.ctrl:
    test cl, 1
    jz .alt
    or al, WM_CTRL
.alt:
    test cl, 4
    jz .gui
    or al, WM_ALT
.gui:
    test cl, 8
    jz .ps2
    or al, WM_META
.ps2:
    cmp byte [kbd_shift], 0
    je .ps2_ctrl
    or al, WM_SHIFT
.ps2_ctrl:
    cmp byte [kbd_ctrl], 0
    je .ps2_alt
    or al, WM_CTRL
.ps2_alt:
    cmp byte [kbd_alt], 0
    je .out
    or al, WM_ALT
.out:
    pop rcx
    ret

; kbd_getc -> EAX = next key code, 0 if none; kbd_got = the modifiers held
; with it. Also polls the serial port.
kbd_getc:
    push rcx
    push rdx
    call serial_poll
    movzx ecx, word [kbd_tail]
    cmp cx, [kbd_head]
    je .empty
    lea rdx, [kbd_mring]
    movzx eax, byte [rdx + rcx]
    mov [kbd_got], al
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
kbd_usage:                              ; set-1 scan codes, as USB HID usages
    db 0, 0x29, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23 ; esc 1-6
    db 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A, 0x2B ; 7-0 - = backspace tab
    db 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C ; q w e r t y u i
    db 0x12, 0x13, 0x2F, 0x30, 0x28, 0xE0, 0x04, 0x16 ; o p [ ] enter ctrl a s
    db 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33 ; d f g h j k l ;
    db 0x34, 0x35, 0xE1, 0x31, 0x1D, 0x1B, 0x06, 0x19 ; ' ` shift \ z x c v
    db 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0xE5, 0x55 ; b n m , . / shift kp*
    db 0xE2, 0x2C, 0x39, 0x3A, 0x3B, 0x3C, 0x3D, 0x3E ; alt space caps F1-F5
    db 0x3F, 0x40, 0x41, 0x42, 0x43, 0x53, 0x47, 0x5F ; F6-F10 num scroll kp7
    db 0x60, 0x61, 0x56, 0x5C, 0x5D, 0x5E, 0x57, 0x59 ; kp8 kp9 kp- kp4-6 kp+ kp1
    db 0x5A, 0x5B, 0x62, 0x63, 0, 0, 0x64, 0x44 ; kp2 kp3 kp0 kp. - - 102nd F11
    db 0x45                             ; F12
kbd_e0_usage:                           ; after E0
    db 0x1C, 0x58, 0x1D, 0xE4, 0x35, 0x54, 0x37, 0x46 ; kp enter, ctrl, kp/, print
    db 0x38, 0xE6, 0x47, 0x4A, 0x48, 0x52, 0x49, 0x4B ; alt, home, up, page up
    db 0x4B, 0x50, 0x4D, 0x4F, 0x4F, 0x4D, 0x50, 0x51 ; left, right, end, down
    db 0x51, 0x4E, 0x52, 0x49, 0x53, 0x4C, 0x5B, 0xE3 ; page down, ins, del, gui
    db 0x5C, 0xE7, 0x5D, 0x65                         ; gui, menu
    db 0

section .data
kbd_present:    db 0
kbd_e0:         db 0
kbd_skip:       db 0                    ; bytes of a sequence to pass over
kbd_shift:      db 0
kbd_ctrl:       db 0
kbd_alt:        db 0
kbd_caps:       db 0
kbd_head:       dw 0
kbd_tail:       dw 0
kbd_got:        db 0                    ; the last key's modifiers, WM_*
key_head:       db 0
key_tail:       db 0

section .bss
kbd_ring:       resb KBD_RING
kbd_mring:      resb KBD_RING           ; each key's modifiers
alignb 4
key_ring:       resd KEY_RING           ; keys down and up (key_event)
key_down:       resb 32                 ; a bit for each usage down now
