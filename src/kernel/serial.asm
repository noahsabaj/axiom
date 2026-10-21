; =============================================================================
;  serial.asm - COM1 debug log at 115200 8N1. Machines without a UART skip it.
;  What comes in is typed (serial_poll); its interrupt wakes the main loop,
;  so it is read at once, in order with the keyboard's keys.
; =============================================================================

COM1            equ 0x3F8

section .text

serial_init:
    push rax
    push rdx
    mov dx, COM1 + 7                    ; scratch register: is a UART there?
    mov al, 0x5A
    out dx, al
    in al, dx
    cmp al, 0x5A
    jne .absent
    mov dx, COM1 + 1
    xor al, al
    out dx, al                          ; no UART interrupts (yet)
    mov dx, COM1 + 3
    mov al, 0x80
    out dx, al                          ; divisor latch
    mov dx, COM1
    mov al, 1
    out dx, al                          ; 115200 baud
    mov dx, COM1 + 1
    xor al, al
    out dx, al
    mov dx, COM1 + 3
    mov al, 0x03
    out dx, al                          ; 8N1
    mov dx, COM1 + 2
    mov al, 0xC7
    out dx, al                          ; FIFOs on
    mov dx, COM1 + 4
    mov al, 0x03
    out dx, al                          ; DTR, RTS
    mov byte [serial_present], 1
.absent:
    pop rdx
    pop rax
    ret

; serial_irq_init: once the I/O APIC is set up, a byte in interrupts (IRQ 4).
serial_irq_init:
    cmp byte [serial_present], 0
    je .out
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, VEC_SERIAL
    lea rsi, [serial_irq]
    call irq_register
    mov edi, 4
    mov esi, VEC_SERIAL
    lea rax, [percpu]
    mov edx, [rax + PC_APIC_ID]         ; to the BSP
    call ioapic_route_isa
    mov dx, COM1 + 4
    mov al, 0x0B                        ; DTR, RTS, OUT2 (lets it reach the APIC)
    out dx, al
    mov dx, COM1 + 1
    mov al, 0x01                        ; a byte received
    out dx, al
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; IRQ 4: what came in, into the keyboard's ring (the main loop wakes after)
serial_irq:
    mov dx, COM1 + 2
    in al, dx
    test al, 1                          ; nothing from the UART
    jnz .out
    call serial_poll
.out:
    ret

; serial_putc(AL). Preserves all.
serial_putc:
    cmp byte [serial_present], 0
    je .out
    push rax
    push rcx
    push rdx
    mov ah, al
    mov ecx, 200000
    mov dx, COM1 + 5
.wait:
    in al, dx
    test al, 0x20                       ; transmit holding register empty
    jnz .send
    pause
    dec ecx
    jnz .wait
.send:
    mov al, ah
    mov dx, COM1
    out dx, al
    pop rdx
    pop rcx
    pop rax
.out:
    ret

; serial_write(RDI string), LF -> CRLF. Preserves all.
serial_write:
    push rax
    push rdi
.next:
    mov al, [rdi]
    test al, al
    jz .done
    cmp al, 10
    jne .plain
    mov al, 13
    call serial_putc
    mov al, 10
.plain:
    cmp al, 128                         ; the font's extra glyphs leave as UTF-8
    jb .ascii
    call serial_extra
    inc rdi
    jmp .next
.ascii:
    call serial_putc
    inc rdi
    jmp .next
.done:
    pop rdi
    pop rax
    ret

; serial_text(RDI string): as serial_write, but bytes over 127 go out as
; they are (the string is UTF-8, not the console's glyph codes). Preserves all.
serial_text:
    push rax
    push rdi
.next:
    mov al, [rdi]
    test al, al
    jz .done
    cmp al, 10
    jne .plain
    mov al, 13
    call serial_putc
    mov al, 10
.plain:
    call serial_putc
    inc rdi
    jmp .next
.done:
    pop rdi
    pop rax
    ret

; serial_extra(AL = glyph code >= 128): a UTF-8 equivalent, or '?'
serial_extra:
    push rax
    push rsi
    lea rsi, [serial_utf8]
.find:
    cmp byte [rsi], 0
    je .unknown
    cmp [rsi], al
    je .found
    add rsi, 4
    jmp .find
.found:
    mov al, [rsi + 1]
    call serial_putc
    mov al, [rsi + 2]
    call serial_putc
    cmp byte [rsi + 3], 0
    je .out
    mov al, [rsi + 3]
    call serial_putc
    jmp .out
.unknown:
    mov al, '?'
    call serial_putc
.out:
    pop rsi
    pop rax
    ret

section .rodata
serial_utf8:                            ; glyph, UTF-8 bytes (2 or 3, 0-padded)
    db G_MIDDOT, 0xC2, 0xB7, 0
    db G_TIMES, 0xC3, 0x97, 0
    db G_DEGREE, 0xC2, 0xB0, 0
    db G_ARROW_R, 0xE2, 0x86, 0x92
    db G_BULLET, 0xE2, 0x80, 0xA2
    db G_CHECK, 0xE2, 0x9C, 0x93
    db G_ELLIPSIS, 0xE2, 0x80, 0xA6
    db G_MICRO, 0xC2, 0xB5, 0
    db 0

section .data
serial_present: db 0
