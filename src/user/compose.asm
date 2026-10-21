; =============================================================================
;  compose.asm - documents, slides and spreadsheets: one document of blocks,
;  three views of it
;
;    run compose [name]
;
;  Opens a window (1240 by 760 points) on NAME.axd from the store (its names are
;  under "compose/"), or a new document of that name ("untitled.axd" if
;  there is none); NAME.txt or NAME.csv is read in as plain text or as a
;  grid. Pages (F1) are rich text flowed onto pages, Slides (F2) the same
;  blocks on 16:9 slides, Grid (F3) a spreadsheet of the grid the cursor is
;  on. F5 presents, in a window of its own. ctrl+S saves into the store and
;  commits; F9 and F10 export plain text and CSV; F12 logs the document.
;  The keys and the file format are in docs/COMPOSE.md.
;
;  What compose does is compose/app.inc and what it includes; this file is
;  its platform: memory, the windows, their events, the store. The window
;  is the desktop's kind (kit.inc), any size, at the desktop's scale and in
;  its look, which compose follows (WE_LOOK); its pixels are given to the
;  app as points (view_size). The presenter's is a second window, the whole
;  screen (WNF_SCREEN), its events looked for while compose waits. It says "compose:
;  ..." on the console as it opens, saves and presents.
; =============================================================================

%include "axe.inc"
WANTS AW_DESK | AW_STORE
%include "kit.inc"

W_PT            equ 1040                ; the window, to start with
H_PT            equ 600
IO_NAME         equ 0                   ; the store's page: a name (64 bytes),
IO_WHY          equ 64                  ; why it was saved,
IO_DATA         equ 4096                ; then the document (save_buf)
ST_BYTES        equ IO_DATA + SAVE_MAX
POLL_US         equ 15000               ; presenting: its window this often

section .text

main:
    push rbx
    push r12
    lea rsi, [rdi + SB_ARGS]            ; its name, the first word
    lea rdi, [arg_name]
.skip:
    cmp byte [rsi], ' '
    jne .word
    inc rsi
    jmp .skip
.word:
    mov ecx, NAME_MAX
.char:
    mov al, [rsi]
    cmp al, ' '
    jbe .named
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jnz .char
.named:
    mov byte [rdi], 0
    cmp dword [ax_desk], 0
    je .no_desk
    mov edi, ST_BYTES                   ; the store's page, and the document's bytes
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .refused
    mov [st_mem], eax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .refused
    mov [st_va], rax
    add rax, IO_DATA
    mov [save_buf], rax
    call app_init
    test rax, rax
    js .refused
    mov edi, W_PT                       ; the window
    mov esi, H_PT
    mov edx, WNF_RESIZE
    call kit_open
    jc .no_window
    call win_size
    call kit_dark                       ; in the desktop's look
    sete dil
    movzx edi, dil
    call app_theme
    lea rsi, [arg_name]
    cmp byte [rsi], 0
    jne .open
    lea rsi, [s_untitled]
.open:
    call app_open
    call paint_main
.event:
    xor ecx, ecx                        ; wait: for ever, or a while if presenting
    cmp byte [pres_on], 0
    je .wait
    mov edi, POLL_US
    call ax_us
    mov rbx, rax
    call ax_now
    lea rcx, [rax + rbx]
.wait:
    call kit_next
    cmp eax, -1
    je .done                            ; the window is gone
    test eax, eax
    jz .presenter                       ; the wait ran out
    call on_event
    mov ebx, eax                        ; EBX: what to do, from all that is waiting
.drain:
    test ebx, AE_QUIT
    jnz .act
    call ax_now
    mov rcx, rax
    call kit_next
    cmp eax, -1
    je .done
    test eax, eax
    jz .presenter_too
    call on_event
    or ebx, eax
    jmp .drain
.presenter:
    xor ebx, ebx
.presenter_too:
    cmp byte [pres_on], 0
    je .act
    cmp dword [pres + W_WIN], 0
    je .act
.pres_drain:
    call ax_now
    mov rcx, rax
    mov edi, [pres + W_END]
    mov r8d, 1
    push rbx
    call next_event
    pop rbx
    test rax, rax
    js .act
    or ebx, eax
    test ebx, AE_QUIT
    jz .pres_drain
.act:
    test ebx, AE_QUIT
    jnz .done
    test ebx, AE_PAINT
    jz .painted
    call paint_main
.painted:
    test ebx, AE_PRESENT
    jz .event
    call paint_pres
    jmp .event
.done:
    call log_start
    lea rsi, [s_closed]
    call sb_str
    call log_sb
    xor eax, eax                        ; and as it ends, its windows go
    jmp .out
.no_desk:
    lea rsi, [s_no_desk]
    call ax_puts
    mov eax, 2
    jmp .out
.no_window:
    lea rsi, [s_no_window_open]
    call ax_puts
    mov eax, 3
    jmp .out
.refused:
    mov rbx, rax
    lea rsi, [s_refused]
    call ax_add
    mov rdi, rbx
    call ax_addd
    call ax_flush
    mov eax, 3
.out:
    pop r12
    pop rbx
    ret

; on_event(EAX = WE_*, in kit_ev) -> EAX = AE_* to do: compose told of it,
; in points
on_event:
    cmp eax, WE_RESIZED
    je .sized
    cmp eax, WE_LOOK
    je .look
    cmp eax, WE_FOCUS
    je .nothing
    mov edi, eax
    mov esi, [kit_ev + WE_CODE]
    mov edx, [kit_ev + WE_X]
    mov ecx, [kit_ev + WE_Y]
    cmp edi, WE_KEY                     ; (a key's x: its modifiers)
    je .tell
    cmp edi, WE_CLOSE
    je .tell
    call pt_in
.tell:
    xor r8d, r8d
    jmp app_event
.sized:
    call win_size
    mov eax, AE_PAINT
    ret
.look:                                  ; the theme, the accent or the scale
    call win_size
    call kit_dark
    sete dil
    movzx edi, dil
    jmp app_theme
.nothing:
    xor eax, eax
    ret

; pt_in(EDX = x, ECX = y, pixels in the window) -> the same, points.
; Preserves all but RAX, RDX, RCX.
pt_in:
    push rbx
    mov ebx, ecx
    mov eax, edx
    shl eax, 2
    cdq
    idiv dword [kit_s4]
    push rax
    mov eax, ebx
    shl eax, 2
    cdq
    idiv dword [kit_s4]
    mov ecx, eax
    pop rdx
    pop rbx
    ret

; win_size: compose told the window's size, in points and pixels, and its
; scale (the desktop's, to twice at most)
win_size:
    mov edx, [kit_s4]
    cmp edx, S_MAX
    jbe .s
    mov edx, S_MAX
.s:
    cmp edx, 4
    jae .s_min
    mov edx, 4
.s_min:
    mov [kit_s4], edx
    mov eax, [kit_w]
    shl eax, 2
    push rdx
    xor edx, edx
    div dword [rsp]
    mov edi, eax
    mov eax, [kit_h]
    shl eax, 2
    xor edx, edx
    div dword [rsp]
    mov esi, eax
    pop rdx
    mov rcx, [kit_px]
    mov r8d, [kit_pitch]
    shr r8d, 2
    mov r9d, [kit_w]
    mov r10d, [kit_h]
    jmp view_size

; next_event(EDI = a window's channel end, RCX = deadline, R8D = 1 if it
; is the presenter's) -> RAX = AE_* for it, or E_* if there was none
next_event:
    push rbx
    mov ebx, r8d
    lea rsi, [ev]
    mov edx, WE_SIZE
    call ax_recv
    test rax, rax
    js .out
    mov edi, [ev + WE_KIND]
    mov esi, [ev + WE_CODE]
    mov edx, [ev + WE_X]
    mov ecx, [ev + WE_Y]
    mov r8d, ebx
    call app_event
.out:
    pop rbx
    ret

; --- windows -------------------------------------------------------------------

W_WIN           equ 0                   ; a window: its handle
W_END           equ 4                   ; the channel end its events come from
W_MEM           equ 8                   ; its pixels: the memory
W_W             equ 12
W_H             equ 16
W_PX            equ 24                  ; where they are mapped
W_SIZE          equ 32

; window_new(EDI = width, ESI = height, RDX = a W_* record, R8D = WNF_*)
; -> RAX < 0 if it could not be made
window_new:
    push rbx
    push r12
    mov rbx, rdx
    mov r12d, r8d
    mov [rbx + W_W], edi
    mov [rbx + W_H], esi
    mov eax, SYS_CHANNEL_NEW            ; what it says comes over this
    syscall
    test rax, rax
    js .out
    mov [rbx + W_END], edx              ; ours, to receive at
    mov edi, [ax_desk]
    mov esi, [rbx + W_W]
    mov edx, [rbx + W_H]
    mov r10d, eax                       ; the window's, to send from
    mov r8d, r12d
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js .out
    mov [rbx + W_WIN], eax
    mov [rbx + W_MEM], edx
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .out
    mov [rbx + W_PX], rax
    xor eax, eax
.out:
    pop r12
    pop rbx
    ret

; window_close(RDI = a W_* record): its pixels unmapped, its handles closed
window_close:
    push rbx
    mov rbx, rdi
    cmp dword [rbx + W_WIN], 0
    je .out
    mov edi, [rbx + W_MEM]
    mov eax, SYS_UNMAP
    syscall
    mov edi, [rbx + W_MEM]
    call close
    mov edi, [rbx + W_WIN]
    call close
    mov edi, [rbx + W_END]
    call close
    mov dword [rbx + W_WIN], 0
.out:
    pop rbx
    ret

; close(EDI = a handle)
close:
    sub rsp, SQ_SIZE
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_CLOSE
    mov [rsp + SQ_HANDLE], edi
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    ret

; show(RDI = a W_* record): all of it to the screen
show:
    sub rsp, SQ_SIZE
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_WIN_SHOW
    mov eax, [rdi + W_WIN]
    mov [rsp + SQ_HANDLE], eax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    ret

paint_main:
    call paint_all
    jmp kit_show_all

paint_pres:
    cmp dword [pres + W_WIN], 0
    je .out
    mov rdi, [pres + W_PX]
    mov esi, [pres + W_W]
    mov edx, [pres + W_H]
    call pres_paint
    call target_win
    lea rdi, [pres]
    jmp show
.out:
    ret

; --- what app.inc asks of its platform ---------------------------------------------

plat_log:
    push rbx
    mov ebx, ecx
    call ax_addn_safe
    call ax_flush
    pop rbx
    ret

; ax_addn_safe(RSI, EBX = bytes): onto the line, at most what fits
ax_addn_safe:
    mov ecx, ebx
    cmp ecx, 200
    jbe .add
    mov ecx, 200
.add:
    jmp ax_addn

plat_title:
    cmp ecx, 200
    jbe .copy
    mov ecx, 200
.copy:
    lea rdi, [title_buf]
    rep movsb
    mov byte [rdi], 0
    lea rsi, [title_buf]
    jmp kit_title

; st_op(AL = RO_ST_*, A0, A1, A2 in RSI, RDX, RCX) -> RAX: on the store,
; from st_mem
st_op:
    push rbx
    sub rsp, SQ_SIZE
    mov rbx, rdi
    push rax
    push rcx
    lea rdi, [rsp + 16]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rcx
    pop rax
    mov [rsp + SQ_OP], al
    mov eax, [ax_store]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [st_mem]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A0], rsi
    mov [rsp + SQ_A1], rdx
    mov [rsp + SQ_A2], rcx
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    pop rbx
    ret

; st_name_in(RSI = NUL-ended): into the page's name field
st_name_in:
    mov rdi, [st_va]
    push rdi
    xor eax, eax
    mov ecx, 64 / 8
    rep stosq
    pop rdi
    mov ecx, 63
    jmp str_copy

plat_save:
    push rbx
    push r12
    mov r12, rdx
    mov rax, E_NOSTORE
    cmp dword [ax_store], 0
    je .out
    mov rbx, rsi
    call st_name_in
    mov al, RO_ST_PUT
    mov esi, IO_NAME
    mov edx, IO_DATA
    mov rcx, r12
    call st_op
    test rax, rax
    js .out
    mov rdi, [st_va]                    ; why: "compose: NAME"
    add rdi, IO_WHY
    lea rsi, [s_why]
    mov ecx, 32
    call str_copy
    mov rsi, rbx
    mov ecx, 64
    call str_copy
    mov rdx, rdi
    sub rdx, [st_va]
    sub rdx, IO_WHY
    mov al, RO_ST_COMMIT
    mov esi, IO_WHY
    xor ecx, ecx
    call st_op
.out:
    pop r12
    pop rbx
    ret

plat_load:
    mov rax, E_NOSTORE
    cmp dword [ax_store], 0
    je .out
    call st_name_in
    mov al, RO_ST_GET
    mov esi, IO_NAME
    mov edx, IO_DATA
    mov ecx, SAVE_MAX
    call st_op
.out:
    ret

plat_mem:
    jmp mem_new

plat_present:
    test edi, edi
    jz .close
    cmp dword [pres + W_WIN], 0
    jne .open
    mov rax, [kit_lk]                   ; the whole screen
    mov edi, [rax + LK_SCR_W]
    mov esi, [rax + LK_SCR_H]
    lea rdx, [pres]
    mov r8d, WNF_SCREEN                 ; full screen: over the bar and the dock
    call window_new
    test rax, rax
    js .failed
    push rbx                            ; titled
    mov rdi, [ax_io_va]
    lea rsi, [s_pres_title]
    mov ecx, 64
    call str_copy
    mov rbx, rdi
    sub rbx, [ax_io_va]
    sub rsp, SQ_SIZE
    mov rdi, rsp
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    mov byte [rsp + SQ_OP], RO_WIN_TITLE
    mov eax, [pres + W_WIN]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], rbx
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    pop rbx
.open:
    mov eax, 1
    ret
.failed:
    lea rdi, [pres]
    call window_close
    xor eax, eax
    ret
.close:
    lea rdi, [pres]
    call window_close
    xor eax, eax
    ret

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

section .rodata
s_no_desk:      db 'compose: no desktop to open a window on', 0
s_refused:      db 'compose: refused, ', 0
s_closed:       db 'closed', 0
s_why:          db 'compose: ', 0
s_no_window_open: db 'compose: the desktop gave it no window', 0
s_pres_title:   db 'Presenting ', 0xE2, 0x80, 0x94, ' Compose', 0

section .bss
alignb 8
st_va:          resq 1
pres:           resb W_SIZE             ; the presenter's window
ev:             resb WE_SIZE
st_mem:         resd 1
arg_name:       resb NAME_MAX + 8
title_buf:      resb 208

AXE_END
