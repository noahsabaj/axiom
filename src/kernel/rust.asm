; =============================================================================
;  rust.asm - the kernel's Rust (src/rust), linked in with it by kernel.ld:
;  what the Rust calls here, and what it offers.
;
;  Rust's entry points are extern "sysv64" (System V: arguments in RDI, RSI,
;  RDX, RCX, R8, R9; RAX out, and RDX for a second word; RBX, RBP and
;  R12-R15 kept). Each piece of assembly that moved to Rust keeps its name
;  and its contract, as a wrapper where it was (json.asm, text.asm, x509.asm): RUST_ENTER
;  (macros.inc) saves what Rust may change and aligns the stack, the
;  wrapper moves the arguments into place and calls, turns Rust's answer
;  into the flags its callers test, and RUST_LEAVE. Rust is soft-float
;  (src/rust/x86_64-axiom-kernel.json): it never touches the SSE registers,
;  which are not saved.
;
;    rust_panic(RDI = message)   Rust's panic handler: panic(0, RDI), the
;                                message NUL-terminated. Never returns.
; =============================================================================

section .text

global rust_panic

extern rs_json_ws, rs_json_skip, rs_json_get, rs_json_is, rs_json_str
extern rs_json_num, rs_json_escape
extern rs_utf8_step, rs_glyph_of
extern rs_x509_parse, rs_x509_unix, rs_x509_name

rust_panic:
    mov rsi, rdi
    xor edi, edi
    jmp panic
