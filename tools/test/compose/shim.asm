; =============================================================================
;  shim.asm - compose on the host (nasm -f win64): its document, formulas,
;  file format, layout and drawing (src/user/compose/*.inc, web/draw.inc)
;  included unchanged, linked into a DLL that tools/test/compose/host.py
;  drives with ctypes. Linked at a fixed base under 2 GiB, as browse's is.
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
;    t_app(RCX = memory, RDX = its bytes, R8 = the window's pixels, R9 =
;      save_buf): app_init, plat_mem taking from that memory
;    t_open(RCX = a NUL-ended name): app_open
;    t_event(RCX = WE_*, RDX = code, R8 = x, R9 = y, [5] = 1 for the
;      presenter's) -> RAX = AE_*
;    t_paint: paint_all
;    t_pres(RCX = pixels, RDX = width, R8 = height): pres_paint
; =============================================================================

bits 64
default rel

section .text code align=16
section .rodata rdata align=64
section .data data align=64
section .bss bss align=4096

%include "defs.inc"

global t_init, t_grid_new, t_cell_set, t_cell_show, t_num
global t_hooks, t_app, t_open, t_event, t_paint, t_pres, t_app_bytes
global calc_count, nblocks, da_top, da_base, view, cur_blk, cur_off, anc_blk
global anc_off, ed_on, pres_on, pres_slide, sl_n, modified, doc_name, st_msg
global blocks, scroll_y

%include "web/util.inc"
%include "web/draw.inc"
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
    mov [win_px], r8
    mov [save_buf], r9
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

t_pres:
    WIN_SAVE
    mov rdi, rcx
    mov esi, edx
    mov edx, r8d
    call pres_paint
    WIN_RESTORE
    ret
