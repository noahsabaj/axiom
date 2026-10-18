; =============================================================================
;  shim.asm - browse's pages on the host (nasm -f win64): web/util.inc,
;  url.inc, html.inc, draw.inc and layout.inc included unchanged, linked
;  into a DLL that tools/test/browse/render.py drives with ctypes. Their
;  absolute addresses need the DLL low in memory (it is linked at a fixed
;  base under 2 GiB).
;    t_render(RCX = HTML, RDX = bytes, R8 = the arena, R9 = its bytes,
;      [5] = the display list (DL_BYTES), [6] = pixels, [7] = width,
;      [8] = height, [9] = scroll, [10] = latin1) -> RAX = the page's
;      height: parsed, laid out at that width and drawn from that scroll
;      on white. Its counts are the includes' own globals, exported.
;    t_resolve(RCX = an href, RDX = bytes, R8 = a base URL, NUL-ended,
;      R9 = U_TEXT_MAX bytes) -> RAX = 0, or -1 if the link goes nowhere
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=4096

%include "defs.inc"

global t_render, t_resolve
global html_elements, lk_count, an_count, doc_title, doc_height, dl_base, dl_top
global lk_table, an_table, ar_top, ar_base

%include "web/util.inc"
%include "web/url.inc"
%include "web/html.inc"
%include "web/draw.inc"
%include "web/layout.inc"

section .text

%macro WIN_SAVE 0
    push rbx
    push rbp
    push rdi
    push rsi
    push r12
    push r13
    push r14
    push r15
%endmacro

%macro WIN_RESTORE 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
%endmacro

ARG             equ 8 * 8 + 8           ; past what WIN_SAVE pushed, and the return

t_render:
    WIN_SAVE
    mov [ar_base], r8
    mov [ar_top], r8
    lea rax, [r8 + r9]
    mov [ar_end], rax
    mov rax, [rsp + ARG + 32]
    mov [dl_base], rax
    add rax, DL_BYTES
    mov [dl_end], rax
    mov rax, [rsp + ARG + 40]
    mov [px_base], rax
    mov eax, [rsp + ARG + 48]
    mov [px_stride], eax
    mov eax, [rsp + ARG + 72]
    mov [latin1], al
    mov rsi, rcx
    mov rcx, rdx
    call html_parse
    mov rdi, rax
    mov esi, [rsp + ARG + 48]
    call layout
    xor eax, eax
    mov [clip_x0], eax
    mov [clip_y0], eax
    mov eax, [rsp + ARG + 48]
    mov [clip_x1], eax
    mov eax, [rsp + ARG + 56]
    mov [clip_y1], eax
    xor edi, edi
    xor esi, esi
    mov edx, [rsp + ARG + 48]
    mov ecx, [rsp + ARG + 56]
    mov r8d, 0xFFFFFF
    call fill_rect
    xor edi, edi
    xor esi, esi
    sub esi, [rsp + ARG + 64]
    call draw_list
    mov eax, [doc_height]
    WIN_RESTORE
    ret

t_resolve:
    WIN_SAVE
    sub rsp, U_SIZE + 8
    mov r12, rcx
    mov r13, rdx
    mov r14, r9
    mov rsi, r8
    mov rdi, rsp
    call url_parse
    jc .no
    mov rsi, r12
    mov rcx, r13
    mov rdx, rsp
    mov rdi, r14
    call url_resolve
    jc .no
    mov rsi, r14                        ; and made whole: parsed again
    mov rdi, rsp
    call url_parse
    jc .no
    mov [out_ptr], r14
    lea rax, [r14 + U_TEXT_MAX - 1]
    mov [out_end], rax
    lea rsi, [rsp + U_TEXT]
    call put_str
    cmp byte [rsp + U_FRAG], 0
    je .whole
    lea rsi, [s_shim_hash]
    call put_str
    lea rsi, [rsp + U_FRAG]
    call put_str
.whole:
    xor eax, eax
    jmp .out
.no:
    mov rax, -1
.out:
    add rsp, U_SIZE + 8
    WIN_RESTORE
    ret

section .rodata
s_shim_hash:    db '#', 0
