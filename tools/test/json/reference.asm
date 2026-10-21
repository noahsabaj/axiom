; tools/test/json/reference.asm - src/kernel/json.asm as it was in assembly,
; before it moved to Rust (src/rust/src/json.rs): what tools/test/json/run.py
; holds the Rust to, case for case.

; =============================================================================
;  json.asm - just enough JSON (RFC 8259) to talk to a web API: find a key
;  in an object, read a string (escapes and \u surrogate pairs to UTF-8) or
;  a number, skip any value; and write text as the inside of a string.
;
;  The readers take the text at RSI, which ends at R11, and move RSI:
;    json_ws                  past white space
;    json_skip                past one value; CF if there is none, or it
;                             runs off the end
;    json_get(RDI = key)      RSI at an object -> RSI at that key's value;
;                             CF if it is not an object or has no such key
;    json_is(RDI = text)      RSI at a value -> ZF if it is that string;
;                             RSI stays
;    json_str(RDI = out, RCX = room)  RSI at a string -> RAX = bytes out,
;                             UTF-8, cut short (on a character boundary) to
;                             the room; RSI past it; CF if it is not one
;    json_num                 RSI at a number -> RAX, its unsigned integer
;                             part; CF if it is not one
;  Each preserves every register but RAX and RSI.
;
;    json_escape(RSI = text, RCX = bytes, RDI = out, RDX = room) -> RAX =
;        bytes written; CF if they did not all fit. Preserves all but RAX.
; =============================================================================

section .text

json_ws:
.next:
    cmp rsi, r11
    jae .out
    cmp byte [rsi], ' '
    je .skip
    cmp byte [rsi], 9
    je .skip
    cmp byte [rsi], 10
    je .skip
    cmp byte [rsi], 13
    jne .out
.skip:
    inc rsi
    jmp .next
.out:
    ret

; json_skip_str: RSI at a string -> RSI past its closing quote; CF if none
json_skip_str:
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], '"'
    jne .bad
    inc rsi
.next:
    cmp rsi, r11
    jae .bad
    mov al, [rsi]
    inc rsi
    cmp al, '"'
    je .done
    cmp al, '\'
    jne .next
    inc rsi                             ; whatever is escaped
    jmp .next
.done:
    clc
    ret
.bad:
    stc
    ret

json_skip:
    push rcx
    push rdx
    call json_ws
    xor ecx, ecx                        ; ECX = how deep
.next:
    cmp rsi, r11
    jae .bad
    mov al, [rsi]
    cmp al, '"'
    je .string
    cmp al, '{'
    je .open
    cmp al, '['
    je .open
    cmp al, '}'
    je .close
    cmp al, ']'
    je .close
    test ecx, ecx
    jz .atom
    inc rsi                             ; inside: commas, colons, atoms
    jmp .next
.open:
    inc ecx
    inc rsi
    jmp .next
.close:
    test ecx, ecx
    jz .bad                             ; a close with nothing open
    inc rsi
    dec ecx
    jz .done
    jmp .next
.string:
    call json_skip_str
    jc .bad
    test ecx, ecx
    jz .done
    jmp .next
.atom:                                  ; a number, true, false or null
    mov rdx, rsi
.atom_char:
    cmp rsi, r11
    jae .atom_end
    mov al, [rsi]
    cmp al, ','
    je .atom_end
    cmp al, '}'
    je .atom_end
    cmp al, ']'
    je .atom_end
    cmp al, ' '
    jbe .atom_end
    inc rsi
    jmp .atom_char
.atom_end:
    cmp rsi, rdx
    je .bad
.done:
    clc
    pop rdx
    pop rcx
    ret
.bad:
    stc
    pop rdx
    pop rcx
    ret

json_get:
    push rcx
    push rdx
    call json_ws
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], '{'
    jne .bad
    inc rsi
.member:
    call json_ws
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], '"'                 ; ('}': an empty object, so no key)
    jne .bad
    lea rdx, [rsi + 1]                  ; RDX = the key's first byte
    call json_skip_str
    jc .bad
    lea rcx, [rsi - 1]                  ; RCX = its closing quote
    push rdi
.cmp:
    mov al, [rdi]
    test al, al
    jz .key_end
    cmp rdx, rcx
    jae .differ
    cmp al, [rdx]
    jne .differ
    inc rdi
    inc rdx
    jmp .cmp
.key_end:
    cmp rdx, rcx
    jne .differ
    pop rdi
    mov al, 1                           ; AL = 1: this is the one
    jmp .colon
.differ:
    pop rdi
    xor eax, eax
.colon:
    call json_ws
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], ':'
    jne .bad
    inc rsi
    call json_ws
    test al, al
    jnz .found
    call json_skip
    jc .bad
    call json_ws
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], ','
    jne .bad                            ; '}': not there
    inc rsi
    jmp .member
.found:
    clc
    pop rdx
    pop rcx
    ret
.bad:
    stc
    pop rdx
    pop rcx
    ret

json_is:
    push rsi
    push rdi
    cmp rsi, r11
    jae .no
    cmp byte [rsi], '"'
    jne .no
    inc rsi
.next:
    cmp rsi, r11
    jae .no
    mov al, [rdi]
    test al, al
    jz .end
    cmp al, [rsi]
    jne .no
    inc rsi
    inc rdi
    jmp .next
.end:
    cmp byte [rsi], '"'                 ; ZF: the same
    jmp .out
.no:
    or eax, 1                           ; ZF clear
.out:
    pop rdi
    pop rsi
    ret

json_num:
    push rdx
    xor eax, eax
    cmp rsi, r11
    jae .bad
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .bad
.digit:
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    cmp rsi, r11
    jae .done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    jbe .digit
.done:
    clc
    pop rdx
    ret
.bad:
    stc
    pop rdx
    ret

json_str:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    mov r8, rdi                         ; R8 = where the output starts
    lea rbx, [rdi + rcx]                ; RBX = where the room ends
    cmp rsi, r11
    jae .bad
    cmp byte [rsi], '"'
    jne .bad
    inc rsi
.next:
    cmp rsi, r11
    jae .bad
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '"'
    je .done
    cmp al, '\'
    je .escape
    call .put
    jmp .next
.escape:
    cmp rsi, r11
    jae .bad
    movzx eax, byte [rsi]
    inc rsi
    cmp al, 'u'
    je .unicode
    mov ecx, 10
    cmp al, 'n'
    cmove eax, ecx
    mov ecx, 9
    cmp al, 't'
    cmove eax, ecx
    mov ecx, 13
    cmp al, 'r'
    cmove eax, ecx
    mov ecx, 8
    cmp al, 'b'
    cmove eax, ecx
    mov ecx, 12
    cmp al, 'f'
    cmove eax, ecx
    call .put                           ; and '"', '\' and '/' as they are
    jmp .next
.unicode:
    call .hex4
    jc .bad
    cmp eax, 0xD800
    jb .encode
    cmp eax, 0xDBFF
    ja .encode                          ; a low surrogate alone: U+FFFD below
    mov edx, eax                        ; a high one: its low one must follow
    lea rcx, [rsi + 6]
    cmp rcx, r11
    ja .lone
    cmp word [rsi], '\u'
    jne .lone
    add rsi, 2
    push rdx
    call .hex4
    pop rdx
    jc .bad
    cmp eax, 0xDC00
    jb .unpaired
    cmp eax, 0xDFFF
    ja .unpaired
    sub edx, 0xD800
    shl edx, 10
    sub eax, 0xDC00
    add eax, edx
    add eax, 0x10000
    jmp .encode
.unpaired:                              ; U+FFFD for the high one, then this
    push rax
    mov eax, 0xFFFD
    call .utf8
    pop rax
    jmp .encode
.lone:
    mov eax, 0xFFFD
.encode:
    call .utf8
    jmp .next
.done:
    mov rax, rdi
    sub rax, r8
    clc
    jmp .out
.bad:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; .put: AL out, if there is room; a raw multi-byte character cut by the
; end of the room is taken back
.put:
    cmp rdi, rbx
    jae .cut
    mov [rdi], al
    inc rdi
    ret
.cut:
    mov rcx, rdi                        ; back over continuation bytes
.back:
    cmp rcx, r8
    je .cut_done
    mov al, [rcx - 1]
    and al, 0xC0
    cmp al, 0x80
    jne .lead
    dec rcx
    jmp .back
.lead:
    movzx eax, byte [rcx - 1]
    cmp eax, 0xC0
    jb .cut_done                        ; ASCII: nothing was cut
    mov edx, 2
    cmp eax, 0xE0
    jb .need
    inc edx
    cmp eax, 0xF0
    jb .need
    inc edx
.need:
    mov rax, rdi
    sub rax, rcx
    inc rax                             ; the bytes of the last character
    cmp rax, rdx
    jae .cut_done
    lea rdi, [rcx - 1]
.cut_done:
    mov rbx, rdi                        ; nothing more goes out
    ret

; .utf8: EAX = a code point out, whole or not at all
.utf8:
    cmp eax, 0xD800
    jb .u_ok
    cmp eax, 0xDFFF
    ja .u_ok
    mov eax, 0xFFFD
.u_ok:
    cmp eax, 0x80
    jb .put
    mov edx, eax
    mov ecx, 2
    cmp eax, 0x800
    jb .u_room
    inc ecx
    cmp eax, 0x10000
    jb .u_room
    inc ecx
.u_room:
    add rcx, rdi
    cmp rcx, rbx
    ja .cut_done
    cmp eax, 0x800
    jae .u3
    shr eax, 6
    or al, 0xC0
    call .put
    jmp .u_last
.u3:
    cmp eax, 0x10000
    jae .u4
    shr eax, 12
    or al, 0xE0
    call .put
    jmp .u_mid
.u4:
    shr eax, 18
    or al, 0xF0
    call .put
    mov eax, edx
    shr eax, 12
    and al, 0x3F
    or al, 0x80
    call .put
.u_mid:
    mov eax, edx
    shr eax, 6
    and al, 0x3F
    or al, 0x80
    call .put
.u_last:
    mov eax, edx
    and al, 0x3F
    or al, 0x80
    jmp .put

; .hex4: four hex digits at RSI -> EAX, RSI past them; CF if not
.hex4:
    lea rax, [rsi + 4]
    cmp rax, r11
    ja .hbad
    xor eax, eax
    mov ecx, 4
.hdigit:
    movzx r9d, byte [rsi]
    inc rsi
    or r9d, 0x20                        ; lower case; digits stay digits
    sub r9d, '0'
    cmp r9d, 9
    jbe .hadd
    sub r9d, 'a' - '0'
    cmp r9d, 5
    ja .hbad
    add r9d, 10
.hadd:
    shl eax, 4
    or eax, r9d
    dec ecx
    jnz .hdigit
    clc
    ret
.hbad:
    stc
    ret

json_escape:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    lea rbx, [rdi + rdx]                ; RBX = where the room ends
.next:
    test rcx, rcx
    jz .done
    movzx eax, byte [rsi]
    inc rsi
    dec rcx
    cmp al, '"'
    je .pair
    cmp al, '\'
    je .pair
    cmp al, ' '
    jb .control
    cmp rdi, rbx
    jae .full
    mov [rdi], al
    inc rdi
    jmp .next
.control:
    mov dl, 'n'
    cmp al, 10
    je .letter
    mov dl, 't'
    cmp al, 9
    je .letter
    mov dl, 'r'
    cmp al, 13
    je .letter
    lea rdx, [rdi + 6]                  ; \u00XX
    cmp rdx, rbx
    ja .full
    mov dword [rdi], '\u00'
    mov edx, eax
    shr edx, 4
    add dl, '0'
    mov [rdi + 4], dl
    and eax, 15
    add al, '0'
    cmp al, '9'
    jbe .low
    add al, 'a' - '9' - 1
.low:
    mov [rdi + 5], al
    add rdi, 6
    jmp .next
.letter:
    mov al, dl
.pair:
    lea rdx, [rdi + 2]
    cmp rdx, rbx
    ja .full
    mov byte [rdi], '\'
    mov [rdi + 1], al
    add rdi, 2
    jmp .next
.done:
    mov rax, rdi
    sub rax, r8
    clc
    jmp .out
.full:
    mov rax, rdi
    sub rax, r8
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret
