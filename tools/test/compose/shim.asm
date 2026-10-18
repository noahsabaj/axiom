; =============================================================================
;  shim.asm - compose on the host (nasm -f win64): its document, formulas,
;  file format, layout and drawing (src/user/compose/*.inc, with kit.inc and
;  web/draw.inc) included unchanged, linked into a DLL that
;  tools/test/compose/host.py drives with ctypes. Linked at a fixed base
;  under 2 GiB, as browse's is. The desktop's look is made here as the
;  kernel makes it (look.asm), from the kernel's own fonts.
;    t_init(RCX = memory, RDX = its bytes): the arena, the blocks, the
;      calculation stack, all from it
;    t_grid_new -> RAX = a grid
;    t_cell_set(RCX = a grid, RDX = row, R8 = column, R9 = text, [5] =
;      bytes) -> RAX = how many cells were recalculated
;    t_cell_show(RCX = a grid, RDX = row, R8 = column, R9 = 32 bytes) ->
;      RAX = bytes | 1 << 32 if it is a number
;    t_num(RCX = text, RDX = bytes, R8 = 32 bytes) -> RAX = the bytes of the
;      number formatted again, or -1 if it is not one
;  The whole program, but for its window and store (compose/app.inc):
;    t_hooks(RCX = log, RDX = save, R8 = load, R9 = present): the host's
;      functions (Win64) behind plat_log(text, bytes), plat_save(name,
;      bytes), plat_load(name) and plat_present(on)
;    t_look(RCX = memory for it, RDX = TH_*, R8 = the theme's colours,
;      TC_COUNT bytes, R9 = the accent, [5] = the scale, quarters): the look
;      (made the first time, written again after), kit.inc reading it
;    t_app(RCX = memory, RDX = its bytes, R8 = save_buf): app_init,
;      plat_mem taking from that memory
;    t_size(RCX = the window's pixels, RDX = width, R8 = height, pixels):
;      the window that size, at the look's scale (compose.asm's win_size)
;    t_open(RCX = a NUL-ended name): app_open
;    t_event(RCX = WE_*, RDX = code, R8 = x, R9 = y, [5] = 1 for the
;      presenter's) -> RAX = AE_*
;    t_paint: paint_all
;    t_pres(RCX = pixels, RDX = width, R8 = height): pres_paint
;    t_theme(RCX = 1 if the desktop's theme is dark) -> RAX = AE_*: app_theme
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=4096

%include "defs.inc"

global t_init, t_grid_new, t_cell_set, t_cell_show, t_num
global t_hooks, t_app, t_open, t_event, t_paint, t_pres, t_theme, t_app_bytes
global t_look, t_size, t_look_bytes
global calc_count, nblocks, da_top, da_base, view, cur_blk, cur_off, anc_blk
global anc_off, ed_on, pres_on, pres_slide, sl_n, modified, doc_name, st_msg
global blocks, scroll_y

; what kit.inc asks of the AXE runtime (axe.inc): a desktop, and nothing
; it is asked for here
section .data
ax_desk:        dd 1
ax_io:          dd 0
ax_io_va:       dq 0
section .text
ax_entry:
    ret
ax_do:
ax_recv:
    mov rax, -1
    ret
ax_now:
    rdtsc
    shl rdx, 32
    or rax, rdx
    ret
ax_us:
    mov rax, rdi
    ret

%include "kit.inc"
section .text

%include "web/util.inc"
%include "compose/draw.inc"
%include "compose/doc.inc"
%include "compose/calc.inc"
%include "compose/file.inc"
%include "compose/ui.inc"
%include "compose/layout.inc"
%include "compose/edit.inc"
%include "compose/view.inc"
%include "compose/app.inc"

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
    sub rsp, 8 + 160                    ; aligned, XMM6-15 kept
    movdqu [rsp], xmm6
    movdqu [rsp + 16], xmm7
    movdqu [rsp + 32], xmm8
    movdqu [rsp + 48], xmm9
    movdqu [rsp + 64], xmm10
    movdqu [rsp + 80], xmm11
    movdqu [rsp + 96], xmm12
    movdqu [rsp + 112], xmm13
    movdqu [rsp + 128], xmm14
    movdqu [rsp + 144], xmm15
%endmacro

%macro WIN_RESTORE 0
    movdqu xmm6, [rsp]
    movdqu xmm7, [rsp + 16]
    movdqu xmm8, [rsp + 32]
    movdqu xmm9, [rsp + 48]
    movdqu xmm10, [rsp + 64]
    movdqu xmm11, [rsp + 80]
    movdqu xmm12, [rsp + 96]
    movdqu xmm13, [rsp + 112]
    movdqu xmm14, [rsp + 128]
    movdqu xmm15, [rsp + 144]
    add rsp, 8 + 160
    pop r15
    pop r14
    pop r13
    pop r12
    pop rsi
    pop rdi
    pop rbp
    pop rbx
%endmacro

ARG             equ 8 * 8 + 8 + 168     ; past what WIN_SAVE pushed, and the return
                                        ; ([ARG + 32] is the fifth argument)

t_init:
    WIN_SAVE
    mov [blocks], rcx                   ; the blocks first, then the stack, then the arena
    lea rax, [rcx + MAX_BLOCKS * BL_SIZE + CALC_STACK]
    mov [calc_stack_top], rax
    mov [da_base], rax
    mov [da_top], rax
    add rcx, rdx
    mov [da_end], rcx
    mov dword [nblocks], 0
    WIN_RESTORE
    ret

t_grid_new:
    WIN_SAVE
    call grid_new
    WIN_RESTORE
    ret

t_cell_set:
    WIN_SAVE
    mov rdi, rcx
    mov esi, edx
    mov edx, r8d
    mov rcx, r9
    mov r8d, [rsp + ARG + 32]
    call cell_set
    mov eax, [calc_count]
    WIN_RESTORE
    ret

t_cell_show:
    WIN_SAVE
    mov r12, r9
    mov rdi, rcx
    mov esi, edx
    mov edx, r8d
    call cell_at
    mov rdi, rax
    mov rsi, r12
    call cell_show
    mov rdi, r12                        ; the text into the buffer, if it is elsewhere
    cmp rsi, rdi
    je .there
    push rcx
    rep movsb
    pop rcx
.there:
    shl rax, 32
    or rax, rcx
    WIN_RESTORE
    ret

t_num:
    WIN_SAVE
    mov r12, r8
    mov rsi, rcx
    mov ecx, edx
    call num_parse
    mov rax, -1
    jc .out
    mov rdi, r12
    call num_format
.out:
    WIN_RESTORE
    ret

; --- the program ------------------------------------------------------------

section .rodata
t_app_bytes:    dq APP_BYTES

section .bss
alignb 8
h_log:          resq 1
h_save:         resq 1
h_load:         resq 1
h_present:      resq 1
h_mem:          resq 1
h_mem_end:      resq 1

section .text

; HOST_CALL hook: the host's Win64 function, the arguments in RCX, RDX, R8;
; RSI, RDI and the rest kept as SysV wants
%macro HOST_CALL 1
    push rbp
    mov rbp, rsp
    push rsi
    push rdi
    and rsp, -16
    sub rsp, 32
    call [%1]
    lea rsp, [rbp - 16]
    pop rdi
    pop rsi
    pop rbp
%endmacro

plat_log:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    mov rdx, rcx
    mov rcx, rsi
    HOST_CALL h_log
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

plat_title:
    ret

plat_save:
    mov rcx, rsi
    HOST_CALL h_save
    ret

plat_load:
    mov rcx, rsi
    HOST_CALL h_load
    ret

plat_mem:                               ; from t_app's memory, in turn
    mov rax, [h_mem]
    add rdi, rax
    cmp rdi, [h_mem_end]
    ja .none
    add rdi, 4095
    and rdi, -4096
    mov [h_mem], rdi
    ret
.none:
    mov rax, -7
    ret

plat_present:
    mov ecx, edi
    HOST_CALL h_present
    ret

t_hooks:
    mov [h_log], rcx
    mov [h_save], rdx
    mov [h_load], r8
    mov [h_present], r9
    ret

t_app:
    WIN_SAVE
    mov [save_buf], r8
    mov [h_mem], rcx
    add rcx, rdx
    mov [h_mem_end], rcx
    call app_init
    WIN_RESTORE
    ret

t_open:
    WIN_SAVE
    mov rsi, rcx
    call app_open
    WIN_RESTORE
    ret

t_event:
    WIN_SAVE
    mov edi, ecx
    mov esi, edx
    mov edx, r8d
    mov ecx, r9d
    mov r8d, [rsp + ARG + 32]
    call app_event
    WIN_RESTORE
    ret

t_paint:
    WIN_SAVE
    call paint_all
    WIN_RESTORE
    ret

t_size:
    WIN_SAVE
    mov [kit_px], rcx
    lea eax, [rdx * 4]
    mov [kit_pitch], eax
    mov [kit_w], edx
    mov [kit_h], r8d
    call kit_unclip
    mov ecx, [kit_s4]                   ; as compose.asm's win_size
    mov eax, [kit_w]
    shl eax, 2
    xor edx, edx
    div ecx
    mov edi, eax
    mov eax, [kit_h]
    shl eax, 2
    xor edx, edx
    div ecx
    mov esi, eax
    mov edx, ecx
    mov rcx, [kit_px]
    mov r8d, [kit_w]
    mov r9d, r8d
    mov r10d, [kit_h]
    call view_size
    WIN_RESTORE
    ret

t_theme:
    WIN_SAVE
    mov edi, ecx
    call app_theme
    WIN_RESTORE
    ret

t_pres:
    WIN_SAVE
    mov rdi, rcx
    mov esi, edx
    mov edx, r8d
    call pres_paint
    WIN_RESTORE
    ret

; --- the desktop's look, as look.asm makes it ----------------------------------

LKU_UNI         equ (UFB_FONTS + UF_WEIGHTS * UF_SIZES * UFT_SIZE + 15) & ~15
LKU_DATA        equ (LKU_UNI + UF_UNI * 8 + 15) & ~15
LKM_UNI         equ (MFB_FONTS + FONT_SIZES * 16 + 15) & ~15
LKM_DATA        equ (LKM_UNI + FONT_UNICODE * 8 + 15) & ~15

section .rodata
%include "gen/uifont.inc"
uifont_data:    incbin "gen/uifont.bin"
uifont_end:
%include "gen/font.inc"
font_data:      incbin "gen/font.bin"
font_end:
align 8
t_look_bytes:   dq LK_HEAD + LKU_DATA + (uifont_end - uifont_data) + 16 + LKM_DATA + (font_end - font_data)

section .text

t_look:
    WIN_SAVE
    mov rbx, rcx                        ; RBX: the look
    mov r12d, edx
    mov r13, r8
    mov r14d, r9d
    cmp dword [rbx + LK_UF], 0
    jne .fonts
    mov dword [rbx + LK_UF], LK_HEAD    ; the desktop's font
    lea r15, [rbx + LK_HEAD]
    mov dword [r15 + UFB_WEIGHTS], UF_WEIGHTS
    mov dword [r15 + UFB_SIZES], UF_SIZES
    mov dword [r15 + UFB_UNIS], UF_UNI
    mov dword [r15 + UFB_UNI], LKU_UNI
    mov dword [r15 + UFB_DATA], LKU_DATA
    lea rsi, [uf_size_px]
    lea rdi, [r15 + UFB_PX]
    mov ecx, UF_SIZES
    rep movsb
    lea rsi, [uf_fonts]
    lea rdi, [r15 + UFB_FONTS]
    mov ecx, UF_WEIGHTS * UF_SIZES * UFT_SIZE
    rep movsb
    lea rsi, [uf_uni]
    lea rdi, [r15 + LKU_UNI]
    mov ecx, UF_UNI * 8
    rep movsb
    lea rsi, [uifont_data]
    lea rdi, [r15 + LKU_DATA]
    mov rcx, uifont_end - uifont_data
    rep movsb
    mov rax, uifont_end - uifont_data + LK_HEAD + LKU_DATA + 15
    and rax, ~15
    mov [rbx + LK_MONO], eax            ; the monospaced one
    lea r15, [rbx + rax]
    mov dword [r15 + MFB_SIZES], FONT_SIZES
    mov dword [r15 + MFB_UNIS], FONT_UNICODE
    mov dword [r15 + MFB_UNI], LKM_UNI
    mov dword [r15 + MFB_DATA], LKM_DATA
    lea rsi, [font_sizes]
    lea rdi, [r15 + MFB_FONTS]
    mov ecx, FONT_SIZES * 16
    rep movsb
    lea rsi, [font_unicode]
    lea rdi, [r15 + LKM_UNI]
    mov ecx, FONT_UNICODE * 8
    rep movsb
    lea rsi, [font_data]
    lea rdi, [r15 + LKM_DATA]
    mov rcx, font_end - font_data
    rep movsb
.fonts:
    mov eax, [rsp + ARG + 32]
    mov [rbx + LK_S4], eax
    mov [rbx + LK_MODE], r12d
    mov [rbx + LK_ACCENT], r14d
    mov dword [rbx + LK_SCR_W], 2560
    mov dword [rbx + LK_SCR_H], 1600
    mov rsi, r13
    lea rdi, [rbx + LK_C]
    mov ecx, TC_COUNT
    rep movsb
    inc dword [rbx + LK_SERIAL]
    mov [kit_lk], rbx                   ; as kit_look finds it
    mov ecx, [rbx + LK_UF]
    add rcx, rbx
    mov [kit_uf], rcx
    mov edx, [rcx + UFB_DATA]
    add rdx, rcx
    mov [kit_ufd], rdx
    mov edx, [rcx + UFB_UNI]
    add rdx, rcx
    mov [kit_ufu], rdx
    mov ecx, [rbx + LK_MONO]
    add rcx, rbx
    mov [kit_mf], rcx
    mov edx, [rcx + MFB_DATA]
    add rdx, rcx
    mov [kit_mfd], rdx
    mov edx, [rcx + MFB_UNI]
    add rdx, rcx
    mov [kit_mfu], rdx
    call kit_relook
    mov edi, 20
    call kit_mono
    WIN_RESTORE
    ret
