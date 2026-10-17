; =============================================================================
;  lib.asm - memory, strings, formatting, logging, locks and time
; =============================================================================

section .text

; memcpy(RDI dst, RSI src, RDX bytes). Clobbers RCX, RSI, RDI.
memcpy:
    mov rcx, rdx
    rep movsb
    ret

; memset32(RDI dst, ESI value, RDX dwords). Clobbers RAX, RCX, RDI.
memset32:
    mov eax, esi
    mov rcx, rdx
    rep stosd
    ret

; strlen(RDI) -> RAX
strlen:
    mov rax, rdi
.scan:
    cmp byte [rax], 0
    je .done
    inc rax
    jmp .scan
.done:
    sub rax, rdi
    ret

; streq(RDI a, RSI b) -> EAX = 1 if equal. Preserves RDI, RSI.
streq:
    push rdi
    push rsi
.loop:
    mov al, [rdi]
    cmp al, [rsi]
    jne .differ
    test al, al
    jz .same
    inc rdi
    inc rsi
    jmp .loop
.same:
    mov eax, 1
    jmp .out
.differ:
    xor eax, eax
.out:
    pop rsi
    pop rdi
    ret

; strcpy_trim(RDI dst, RSI src, RDX capacity) - copies printable ASCII,
; collapses runs of spaces and trims both ends. Preserves all.
strcpy_trim:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi                         ; start of output
    dec rdx                             ; room for the NUL
    jle .finish
    xor ecx, ecx                        ; 1 = previous output was a space
.next:
    test rdx, rdx
    jz .finish
    lodsb
    test al, al
    jz .finish
    cmp al, ' '
    jbe .space
    cmp al, 0x7E
    ja .next
    stosb
    dec rdx
    xor ecx, ecx
    jmp .next
.space:
    cmp rdi, r8                         ; no leading spaces
    je .next
    test ecx, ecx
    jnz .next
    mov al, ' '
    stosb
    dec rdx
    mov ecx, 1
    jmp .next
.finish:
    cmp rdi, r8                         ; drop a trailing space
    je .terminate
    cmp byte [rdi - 1], ' '
    jne .terminate
    dec rdi
.terminate:
    mov byte [rdi], 0
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  format(RDI dst, RSI fmt, RDX args) -> RAX = length. Preserves all others.
;    %s string  %c char  %u unsigned  %d signed  %x hex  %p 0x + 16 hex digits
;    %b bytes as B/KiB/MiB/GiB/TiB  %t tenths (123 -> 12.3)
;    %h hundredths (1234 -> 12.34)  %I IPv4 address (first octet in the low
;    byte, as loaded from a packet)  %A an address at a pointer, 16 bytes,
;    IPv6 or IPv4-mapped (ip6.asm)  %M MAC address at a pointer  %% literal
;    Flags: '-' left-align, '0' zero-pad, then a width: %-12s %08x %5u
; -----------------------------------------------------------------------------
format:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    sub rsp, 96                         ; [0,64) text scratch, [64,96) nested args
    mov r12, rdi
    mov rbx, rdx
.next:
    lodsb
    test al, al
    jz .finish
    cmp al, '%'
    je .spec
    stosb
    jmp .next
.spec:
    xor r8d, r8d                        ; width
    xor r9d, r9d                        ; bit 0 left-align, bit 1 zero-pad
    lodsb
    cmp al, '-'
    jne .zero
    or r9d, 1
    lodsb
.zero:
    cmp al, '0'
    jne .width
    or r9d, 2
    lodsb
.width:
    cmp al, '0'
    jb .conv
    cmp al, '9'
    ja .conv
    imul r8d, r8d, 10
    movzx ecx, al
    sub ecx, '0'
    add r8d, ecx
    lodsb
    jmp .width
.conv:
    lea r13, [rsp + 63]                 ; numbers are built backwards from here
    cmp al, 's'
    je .c_str
    cmp al, 'u'
    je .c_uns
    cmp al, 'd'
    je .c_sig
    cmp al, 'x'
    je .c_hex
    cmp al, 'p'
    je .c_ptr
    cmp al, 'c'
    je .c_chr
    cmp al, 'b'
    je .c_bytes
    cmp al, 't'
    je .c_tenths
    cmp al, 'h'
    je .c_hundredths
    cmp al, 'I'
    je .c_ip
    cmp al, 'M'
    je .c_mac
    cmp al, 'A'
    je .c_addr
    test al, al
    jz .finish
    stosb                               ; %% or unknown: literal
    jmp .next

.finish:
    mov byte [rdi], 0
    mov rax, rdi
    sub rax, r12
    add rsp, 96
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

.c_str:
    mov r10, [rbx]
    add rbx, 8
    test r10, r10
    jnz .c_str_len
    lea r10, [str_null]
.c_str_len:
    mov r11, r10
.c_str_scan:
    cmp byte [r11], 0
    je .c_str_end
    inc r11
    jmp .c_str_scan
.c_str_end:
    sub r11, r10
    jmp .emit

.c_chr:
    mov al, [rbx]
    add rbx, 8
    mov [rsp], al
    mov r10, rsp
    mov r11d, 1
    jmp .emit

.c_uns:
    mov rax, [rbx]
    add rbx, 8
    call .dec
    jmp .emit

.c_sig:
    mov rax, [rbx]
    add rbx, 8
    test rax, rax
    jns .c_sig_pos
    neg rax
    call .dec
    dec r10
    mov byte [r10], '-'
    inc r11
    jmp .emit
.c_sig_pos:
    call .dec
    jmp .emit

.c_hex:
    mov rax, [rbx]
    add rbx, 8
    call .hex
    jmp .emit

.c_ptr:
    mov rax, [rbx]
    add rbx, 8
    call .hex
.c_ptr_pad:
    cmp r11, 16
    jae .c_ptr_prefix
    dec r10
    mov byte [r10], '0'
    inc r11
    jmp .c_ptr_pad
.c_ptr_prefix:
    sub r10, 2
    mov word [r10], '0x'
    add r11, 2
    jmp .emit

.c_tenths:
    mov rax, [rbx]
    add rbx, 8
    xor edx, edx
    mov ecx, 10
    div rcx
    mov [rsp + 64], rax
    mov [rsp + 72], rdx
    lea rcx, [fmt_tenths]
    jmp .nested

.c_hundredths:
    mov rax, [rbx]
    add rbx, 8
    xor edx, edx
    mov ecx, 100
    div rcx
    mov [rsp + 64], rax
    mov [rsp + 72], rdx
    lea rcx, [fmt_hundredths]
    jmp .nested

.c_ip:
    mov rax, [rbx]
    add rbx, 8
    lea rdx, [rsp + 64]
    mov ecx, 4
.c_ip_octet:
    movzx r10d, al
    mov [rdx], r10
    add rdx, 8
    shr eax, 8
    dec ecx
    jnz .c_ip_octet
    lea rcx, [fmt_ip]
    jmp .nested

.c_addr:
    mov rdx, [rbx]
    add rbx, 8
    push rsi
    push rdi
    mov rsi, rdx
    lea rdi, [rsp + 16]                 ; the text scratch
    call ip6_text
    pop rdi
    pop rsi
    mov r10, rsp
    mov r11, rax
    jmp .emit

.c_mac:
    mov rdx, [rbx]
    add rbx, 8
    mov r10, rsp
    xor ecx, ecx
.c_mac_byte:
    movzx eax, byte [rdx + rcx]
    mov r11d, eax
    shr eax, 4
    movzx eax, byte [hex_digits + rax]
    mov [r10], al
    and r11d, 15
    movzx eax, byte [hex_digits + r11]
    mov [r10 + 1], al
    mov byte [r10 + 2], ':'
    add r10, 3
    inc ecx
    cmp ecx, 6
    jb .c_mac_byte
    mov r10, rsp
    mov r11d, 17
    jmp .emit

.c_bytes:
    mov rax, [rbx]
    add rbx, 8
    xor ecx, ecx                        ; unit: 0 B, 1 KiB, 2 MiB, 3 GiB, 4 TiB
.c_bytes_unit:
    cmp ecx, 4
    jae .c_bytes_fmt
    push rcx
    lea ecx, [ecx * 4 + ecx]            ; 10 * (unit + 1)
    lea ecx, [ecx * 2 + 10]
    mov rdx, rax
    shr rdx, cl
    pop rcx
    test rdx, rdx
    jz .c_bytes_fmt
    inc ecx
    jmp .c_bytes_unit
.c_bytes_fmt:
    test ecx, ecx
    jnz .c_bytes_scaled
    mov [rsp + 64], rax
    lea rcx, [fmt_bytes]
    jmp .nested
.c_bytes_scaled:
    mov r10d, ecx
    imul ecx, ecx, 10
    mov rdx, rax
    shr rdx, cl
    mov [rsp + 64], rdx                 ; whole units
    mov rdx, 1
    shl rdx, cl
    dec rdx
    and rax, rdx
    imul rax, rax, 10
    shr rax, cl
    mov [rsp + 72], rax                 ; tenths
    mov rcx, [fmt_units + r10 * 8 - 8]
    jmp .nested

.nested:                                ; RCX = format, args at [rsp + 64]
    push rsi
    push rdi
    mov rsi, rcx
    lea rdi, [rsp + 16]
    lea rdx, [rsp + 16 + 64]
    call format
    pop rdi
    pop rsi
    mov r10, rsp
    mov r11, rax
    ; fall through

.emit:                                  ; text [r10, r10 + r11), width r8, flags r9
    mov rcx, r8
    sub rcx, r11
    jbe .emit_copy
    test r9d, 1
    jnz .emit_left
    mov al, ' '
    test r9d, 2
    jz .emit_pad
    mov al, '0'
.emit_pad:
    rep stosb
.emit_copy:
    mov rcx, r11
    xchg rsi, r10
    rep movsb
    mov rsi, r10
    jmp .next
.emit_left:
    push rcx
    mov rcx, r11
    xchg rsi, r10
    rep movsb
    mov rsi, r10
    pop rcx
    mov al, ' '
    rep stosb
    jmp .next

.dec:                                   ; RAX -> decimal ending at r13
    mov r10, r13
    mov ecx, 10
.dec_loop:
    xor edx, edx
    div rcx
    add dl, '0'
    dec r10
    mov [r10], dl
    test rax, rax
    jnz .dec_loop
    mov r11, r13
    sub r11, r10
    ret

.hex:                                   ; RAX -> hex ending at r13
    mov r10, r13
.hex_loop:
    mov edx, eax
    and edx, 15
    movzx edx, byte [hex_digits + rdx]
    dec r10
    mov [r10], dl
    shr rax, 4
    jnz .hex_loop
    mov r11, r13
    sub r11, r10
    ret

; -----------------------------------------------------------------------------
;  kprint(RSI fmt, RDX args): format a log line, send it to the serial port and,
;  during boot, to the screen. Safe from any CPU. Preserves all.
; -----------------------------------------------------------------------------
kprint:
    push rax
    push rdi
    pushfq
    cli
    lea rdi, [print_lock]
    call spin_lock
    lea rdi, [print_buffer]
    call format
    call serial_write
    call log_append
    cmp byte [log_to_screen], 0
    je .unlock
    call con_write
    call con_flush
.unlock:
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rax
    ret

; kputs(RDI string): text to the console only (shell output). Preserves all.
kputs:
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [print_lock]
    call spin_lock
    pop rdi
    call con_write
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    ret

; -----------------------------------------------------------------------------
;  Spinlocks on a dword. Preserve all.
; -----------------------------------------------------------------------------
spin_lock:
    push rax
.try:
    mov eax, 1
    xchg eax, [rdi]
    test eax, eax
    jz .taken
.wait:
    pause
    cmp dword [rdi], 0
    jne .wait
    jmp .try
.taken:
    pop rax
    ret

spin_unlock:
    mov dword [rdi], 0
    ret

; -----------------------------------------------------------------------------
;  Time, from the invariant TSC
; -----------------------------------------------------------------------------
time_init:                              ; derive conversion factors from tsc_hz
    mov rax, [tsc_hz]
    xor edx, edx
    mov ecx, 1000000
    div rcx
    mov [tsc_per_us], rax
    mov rax, [tsc_hz]
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov [tsc_per_ms], rax
    ret

; delay_us(RDI microseconds). Preserves all.
delay_us:
    push rax
    push rcx
    push rdx
    RDTSC64
    mov rcx, rax
    mov rax, rdi
    imul rax, [tsc_per_us]
    add rcx, rax
.spin:
    pause
    RDTSC64
    cmp rax, rcx
    jb .spin
    pop rdx
    pop rcx
    pop rax
    ret

; ticks_to_us(RAX ticks) -> RAX microseconds. Clobbers RDX.
ticks_to_us:
    push rcx
    mov rcx, [tsc_per_us]
    xor edx, edx
    div rcx
    pop rcx
    ret

; uptime_ms -> RAX milliseconds since power-on (the TSC starts at reset)
uptime_ms:
    push rcx
    push rdx
    RDTSC64
    xor edx, edx
    div qword [tsc_per_ms]
    pop rdx
    pop rcx
    ret

section .rodata
hex_digits:     db '0123456789abcdef'
str_null:       db '(null)', 0
fmt_tenths:     db '%u.%u', 0
fmt_ip:         db '%u.%u.%u.%u', 0
fmt_hundredths: db '%u.%02u', 0
fmt_bytes:      db '%u B', 0
fmt_kib:        db '%u.%u KiB', 0
fmt_mib:        db '%u.%u MiB', 0
fmt_gib:        db '%u.%u GiB', 0
fmt_tib:        db '%u.%u TiB', 0
align 8
fmt_units:      dq fmt_kib, fmt_mib, fmt_gib, fmt_tib

section .data
align 8
tsc_hz:         dq 0
tsc_per_us:     dq 1
tsc_per_ms:     dq 1000
print_lock:     dd 0
log_to_screen:  db 0

section .bss
print_buffer:   resb 1024
