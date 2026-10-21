; tools/test/text/reference.asm - src/kernel/text.asm as it was in assembly,
; before it moved to Rust (src/rust/src/text.rs): what tools/test/text/run.py
; holds the Rust to, case for case.

; =============================================================================
;  text.asm - Unicode text for a console with one byte per character: UTF-8
;  decoded a byte at a time, and each code point drawn as the console font
;  has it (ASCII, or one of its extra symbols), as a look-alike ('é' as e,
;  '—' as -), or as '?'.
;
;    utf8_step(AL = the next byte, RDI = 8 bytes of state, zero to begin)
;        -> CF while a character is unfinished; else EAX = its code point
;        (U+FFFD for a malformed sequence). Preserves all but RAX.
;    glyph_of(EAX = code point) -> EAX = the byte to draw, or 0 for nothing
;        (joiners, variation selectors, other control characters; 10 stays
;        10, a tab becomes a space). Preserves all but RAX.
; =============================================================================

section .text

utf8_step:
    movzx eax, al
    cmp dword [rdi + 4], 0              ; bytes still to come
    jne .continuation
    cmp eax, 0x80
    jb .done
    cmp eax, 0xC2
    jb .bad                             ; a stray continuation, or overlong
    cmp eax, 0xE0
    jb .two
    cmp eax, 0xF0
    jb .three
    cmp eax, 0xF5
    jae .bad
    and eax, 0x07
    mov dword [rdi + 4], 3
    jmp .begun
.three:
    and eax, 0x0F
    mov dword [rdi + 4], 2
    jmp .begun
.two:
    and eax, 0x1F
    mov dword [rdi + 4], 1
.begun:
    mov [rdi], eax
    stc
    ret
.continuation:
    push rcx
    mov ecx, eax
    and ecx, 0xC0
    cmp ecx, 0x80
    pop rcx
    jne .bad                            ; cut short (and this byte is lost)
    and eax, 0x3F
    shl dword [rdi], 6
    or [rdi], eax
    dec dword [rdi + 4]
    jz .whole
    stc
    ret
.whole:
    mov eax, [rdi]
.done:
    clc
    ret
.bad:
    mov dword [rdi + 4], 0
    mov eax, 0xFFFD
    clc
    ret

glyph_of:
    cmp eax, 0x80
    jae .wide
    cmp eax, 10
    je .out
    cmp eax, 9
    je .space
    cmp eax, ' '
    jb .none
    cmp eax, 0x7F
    je .none
.out:
    ret
.space:
    mov eax, ' '
    ret
.none:
    xor eax, eax
    ret
.wide:
    cmp eax, 0xC0                       ; Latin-1 letters: without accents
    jb .table
    cmp eax, 0xFF
    ja .table
    push rcx
    lea rcx, [txt_latin1]
    movzx eax, byte [rcx + rax - 0xC0]
    pop rcx
    ret
.table:
    cmp eax, 0x2000                     ; the many spaces
    jb .find
    cmp eax, 0x200A
    jbe .space
.find:
    push rcx
    push rdx
    lea rcx, [txt_map]
.next:
    mov edx, [rcx]
    test edx, edx
    jz .unknown
    add rcx, 4
    and edx, 0xFFFFFF
    cmp edx, eax
    jne .next
    movzx eax, byte [rcx - 1]
    jmp .found
.unknown:
    mov eax, '?'
.found:
    pop rdx
    pop rcx
    ret

section .rodata

; U+00C0 to U+00FF
txt_latin1:     db 'AAAAAAACEEEEIIII', 'DNOOOOO', G_TIMES, 'OUUUUYTs'
                db 'aaaaaaaceeeeiiii', 'dnooooo/ouuuuyty'

%macro TXT 2                            ; code point, the byte drawn for it
    dd (%1) | ((%2) << 24)
%endmacro

; the rest, as code point | byte << 24; 0 draws nothing
txt_map:
    TXT 0x00A0, ' '
    TXT 0x00A1, '!'
    TXT 0x00A2, 'c'
    TXT 0x00A3, 'L'
    TXT 0x00A5, 'Y'
    TXT 0x00A7, 'S'
    TXT 0x00A9, 'C'
    TXT 0x00AB, '"'
    TXT 0x00AD, 0
    TXT 0x00AE, 'R'
    TXT 0x00B0, G_DEGREE
    TXT 0x00B1, '+'
    TXT 0x00B2, '2'
    TXT 0x00B3, '3'
    TXT 0x00B4, "'"
    TXT 0x00B5, G_MICRO
    TXT 0x00B7, G_MIDDOT
    TXT 0x00B9, '1'
    TXT 0x00BB, '"'
    TXT 0x00BF, '?'
    TXT 0x03BC, G_MICRO
    TXT 0x200B, 0                       ; zero-width space, joiners, marks
    TXT 0x200C, 0
    TXT 0x200D, 0
    TXT 0x200E, 0
    TXT 0x200F, 0
    TXT 0x2060, 0
    TXT 0xFEFF, 0
    TXT 0xFE0E, 0                       ; variation selectors
    TXT 0xFE0F, 0
    TXT 0x2010, '-'                     ; hyphens and dashes
    TXT 0x2011, '-'
    TXT 0x2012, '-'
    TXT 0x2013, '-'
    TXT 0x2014, '-'
    TXT 0x2015, '-'
    TXT 0x2212, '-'
    TXT 0x2043, '-'
    TXT 0x2018, "'"                     ; quotes
    TXT 0x2019, "'"
    TXT 0x201A, ','
    TXT 0x201B, "'"
    TXT 0x2032, "'"
    TXT 0x201C, '"'
    TXT 0x201D, '"'
    TXT 0x201E, '"'
    TXT 0x2033, '"'
    TXT 0x2039, '<'
    TXT 0x203A, '>'
    TXT 0x2044, '/'
    TXT 0x2215, '/'
    TXT 0x202F, ' '
    TXT 0x205F, ' '
    TXT 0x3000, ' '
    TXT 0x2022, G_BULLET
    TXT 0x2023, G_TRI_R
    TXT 0x25AA, G_BULLET
    TXT 0x25E6, G_CIRCLE
    TXT 0x2219, G_MIDDOT
    TXT 0x22C5, G_MIDDOT
    TXT 0x2026, G_ELLIPSIS
    TXT 0x2192, G_ARROW_R
    TXT 0x21D2, G_ARROW_R
    TXT 0x27F6, G_ARROW_R
    TXT 0x2794, G_ARROW_R
    TXT 0x2190, G_ARROW_L
    TXT 0x21D0, G_ARROW_L
    TXT 0x2191, G_ARROW_U
    TXT 0x2193, G_ARROW_D
    TXT 0x2713, G_CHECK
    TXT 0x2714, G_CHECK
    TXT 0x2705, G_CHECK
    TXT 0x2717, G_CROSSMARK
    TXT 0x2718, G_CROSSMARK
    TXT 0x274C, G_CROSSMARK
    TXT 0x25CF, G_DOT
    TXT 0x25CB, G_CIRCLE
    TXT 0x25C6, G_DIAMOND
    TXT 0x25B6, G_TRI_R
    TXT 0x25BA, G_TRI_R
    TXT 0x00D7, G_TIMES
    TXT 0x2248, G_APPROX
    TXT 0x2264, G_LE
    TXT 0x2265, G_GE
    TXT 0x2588, G_BLOCK                 ; blocks and shades
    TXT 0x2593, G_SHADE3
    TXT 0x2592, G_SHADE2
    TXT 0x2591, G_SHADE1
    TXT 0x258C, G_HALF_L
    TXT 0x2590, G_HALF_R
    TXT 0x2580, G_HALF_T
    TXT 0x2584, G_HALF_B
    TXT 0x2587, G_BAR8
    TXT 0x2500, G_HLINE                 ; box drawing, light, heavy, double
    TXT 0x2501, G_HLINE
    TXT 0x2550, G_HLINE
    TXT 0x2502, G_VLINE
    TXT 0x2503, G_VLINE
    TXT 0x2551, G_VLINE
    TXT 0x250C, G_TL
    TXT 0x250F, G_TL
    TXT 0x2554, G_TL
    TXT 0x256D, G_TL
    TXT 0x2510, G_TR
    TXT 0x2513, G_TR
    TXT 0x2557, G_TR
    TXT 0x256E, G_TR
    TXT 0x2514, G_BL
    TXT 0x2517, G_BL
    TXT 0x255A, G_BL
    TXT 0x2570, G_BL
    TXT 0x2518, G_BR
    TXT 0x251B, G_BR
    TXT 0x255D, G_BR
    TXT 0x256F, G_BR
    TXT 0x251C, G_TEE_L
    TXT 0x2523, G_TEE_L
    TXT 0x2560, G_TEE_L
    TXT 0x2524, G_TEE_R
    TXT 0x252B, G_TEE_R
    TXT 0x2563, G_TEE_R
    TXT 0x252C, G_TEE_T
    TXT 0x2533, G_TEE_T
    TXT 0x2566, G_TEE_T
    TXT 0x2534, G_TEE_B
    TXT 0x253B, G_TEE_B
    TXT 0x2569, G_TEE_B
    TXT 0x253C, G_CROSS
    TXT 0x254B, G_CROSS
    TXT 0x256C, G_CROSS
    TXT 0xFFFD, '?'
    dd 0
