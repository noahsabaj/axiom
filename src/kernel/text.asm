; =============================================================================
;  text.asm - Unicode text for a console with one byte per character: UTF-8
;  decoded a byte at a time, and each code point drawn as the console font
;  has it (ASCII, or one of its extra symbols), as a look-alike ('é' as e,
;  '—' as -), or as '?'. In Rust (src/rust/src/text.rs); these are its
;  entry points, as they were.
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
    push rsi
    RUST_ENTER
    movzx esi, al                       ; rs_utf8_step(state, byte)
    call rs_utf8_step
    cmp rdx, 1                          ; CF: unfinished
    RUST_LEAVE
    pop rsi
    ret

glyph_of:
    push rsi
    RUST_ENTER
    mov edi, eax                        ; rs_glyph_of(code point)
    call rs_glyph_of
    RUST_LEAVE
    pop rsi
    ret
