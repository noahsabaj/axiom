; =============================================================================
;  json.asm - just enough JSON (RFC 8259) to talk to a web API: find a key
;  in an object, read a string (escapes and \u surrogate pairs to UTF-8) or
;  a number, skip any value; and write text as the inside of a string.
;  In Rust (src/rust/src/json.rs); these are its entry points, as they were.
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
;  Each preserves every register but RAX and RSI. Keys and texts are
;  NUL-terminated; what json_str writes is apart from the text it reads.
;
;    json_escape(RSI = text, RCX = bytes, RDI = out, RDX = room) -> RAX =
;        bytes written; CF if they did not all fit. Preserves all but RAX.
; =============================================================================

section .text

; JSON_READER name: name, as above, through the Rust rs_name(&cursor, RDI,
; RCX), the cursor RSI and R11 -> RAX; RDX = 0 if it failed: CF, and ZF if
; it did not (json_is). RSI where Rust left the cursor.
%macro JSON_READER 1
%1:
    RUST_ENTER
    push r11                            ; the cursor: where the text ends,
    push rsi                            ; and where the reader is
    mov rdx, rcx
    mov rsi, rdi
    mov rdi, rsp
    call rs_%1
    mov rsi, [rsp]
    cmp rdx, 1                          ; CF: it failed; ZF: it did not
    RUST_LEAVE
    ret
%endmacro

JSON_READER json_ws
JSON_READER json_skip
JSON_READER json_get
JSON_READER json_is
JSON_READER json_str
JSON_READER json_num

json_escape:
    push rsi
    RUST_ENTER
    mov r8, rdx                         ; rs_json_escape(text, bytes, out,
    mov rdx, rdi                        ; room)
    mov rdi, rsi
    mov rsi, rcx
    mov rcx, r8
    call rs_json_escape
    cmp rdx, 1                          ; CF: they did not all fit
    RUST_LEAVE
    pop rsi
    ret
