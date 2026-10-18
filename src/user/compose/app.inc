; =============================================================================
;  compose/app.inc - compose itself: what each key and click does
;
;  The program around it (compose.asm in Axiom, the test shim on the host)
;  gives it memory and a window's pixels, passes on what the window says,
;  paints when it is asked to, and provides:
;    plat_log(RSI = text, ECX = bytes): a line on the console
;    plat_title(RSI, ECX): the window's title
;    plat_save(RSI = a NUL-ended name, RDX = bytes in save_buf) -> RAX =
;      0 or more if it was kept, < 0 if not
;    plat_load(RSI = a NUL-ended name) -> RAX = the bytes put in save_buf,
;      < 0 if there is no such thing
;    plat_present(EDI = 1 to show the presenter's window, 0 to close it) ->
;      EAX = 1 if it is open
;    plat_mem(EDI = bytes, 64 MiB at most) -> RAX = zeroed memory, < 0 if
;      there is none
;  All preserve RBX, RBP, R12-R15.
;
;    app_init -> RAX < 0 if there was not the memory (APP_BYTES in all):
;      an empty document; win_px and save_buf (SAVE_MAX) set first
;    app_open(RSI = a NUL-ended name): that document read (NAME.axd, or a
;      .txt or .csv imported), or a new one of that name
;    app_event(EDI = WE_*, ESI = its code, EDX = x, ECX = y, R8D = 1 if it
;      is the presenter's window's) -> EAX = AE_* to do
;    app_theme(EDI = 1 if the system's theme is dark, 0 if light) -> EAX =
;      AE_* to do: compose follows it, unless it was set light or dark
; =============================================================================

; keys, as kbd.asm sends them
KEY_UP          equ 0x80
KEY_DOWN        equ 0x81
KEY_LEFT        equ 0x82
KEY_RIGHT       equ 0x83
KEY_HOME        equ 0x84
KEY_END         equ 0x85
KEY_PGUP        equ 0x86
KEY_PGDN        equ 0x87
KEY_DEL         equ 0x89
KEY_BTAB        equ 0x8A
KEY_F1          equ 0x90

AE_PAINT        equ 1                   ; the window painted again
AE_PRESENT      equ 2                   ; the presenter's
AE_QUIT         equ 4

SAVE_MAX        equ 1 << 20             ; the most the store keeps in one
NAME_MAX        equ 48

MEM_A           equ MAX_BLOCKS * BL_SIZE + CALC_STACK + DL_BYTES + LN_MAX * LN_SIZE \
                    + LT_BYTES + SL_MAX * SL_SIZE + CLIP_BYTES + ED_CAP + 4096 \
                    + SL_W * SL_H * 4 + TH_MAX * TH_BYTES
APP_BYTES       equ MEM_A + 2 * UNDO_BYTES + DA_BYTES

; what a button does
ACT_BOLD        equ 1
ACT_ITALIC      equ 2
ACT_UNDER       equ 3
ACT_H1          equ 4
ACT_H2          equ 5
ACT_TEXT        equ 6
ACT_BULLET      equ 7
ACT_NUMBER      equ 8
ACT_TABLE       equ 9
ACT_SLIDE       equ 10
ACT_IMAGE       equ 11
ACT_PRESENT     equ 12
ACT_SAVE        equ 13
ACT_ROW         equ 14
ACT_COL         equ 15
ACT_THEME       equ 16

THEME_AUTO      equ 0                   ; as the system's theme is
THEME_LIGHT     equ 1
THEME_DARK      equ 2

SEG_X           equ 16                  ; the views' control
SEG_Y           equ 10
SEG_W           equ 84
SEG_H           equ 32

VP              equ 1 << V_PAGES
VS              equ 1 << V_SLIDES
VG              equ 1 << V_GRID

%macro BUTTON 8                         ; x, w, action, views, style, font, label
    dw %1, SEG_Y, %2, SEG_H
    db %3, %4, %5, %6, 0, 0, 0, 0
    dq %7
%endmacro

section .text

app_init:
    mov edi, MEM_A                      ; the memory, in three pieces
    call plat_mem
    test rax, rax
    js .out
    mov rdi, rax
    mov [blocks], rdi
    add rdi, MAX_BLOCKS * BL_SIZE + CALC_STACK
    mov [calc_stack_top], rdi
    mov [dl_base], rdi
    mov [dl_top], rdi
    add rdi, DL_BYTES
    mov [dl_end], rdi
    mov [ln_base], rdi
    add rdi, LN_MAX * LN_SIZE
    mov [lt_base], rdi
    mov [lt_top], rdi
    add rdi, LT_BYTES
    mov [lt_end], rdi
    mov [sl_base], rdi
    add rdi, SL_MAX * SL_SIZE
    mov [clip_base], rdi
    add rdi, CLIP_BYTES
    push rdi
    call ed_init
    pop rdi
    add rdi, ED_CAP
    mov [csv_buf], rdi
    add rdi, 4096
    mov [off_px], rdi
    add rdi, SL_W * SL_H * 4
    mov [th_px], rdi
    mov edi, 2 * UNDO_BYTES
    call plat_mem
    test rax, rax
    js .out
    mov [undo_stack + US_BASE], rax
    mov [undo_stack + US_TOP], rax
    add rax, UNDO_BYTES
    mov [redo_stack + US_BASE], rax
    mov [redo_stack + US_TOP], rax
    mov edi, DA_BYTES
    call plat_mem
    test rax, rax
    js .out
    mov [da_base], rax
    mov [da_top], rax
    add rax, DA_BYTES
    mov [da_end], rax
    mov dword [view], V_PAGES
    mov dword [goal_x], -1
    mov dword [thumb_gen], -1
    lea rdi, [doc_name]
    lea rsi, [s_untitled]
    mov ecx, NAME_MAX
    call str_copy
    call doc_new
    call theme_load
    xor eax, eax
.out:
    ret

; doc_new: an empty document, nothing to undo
doc_new:
    call doc_clear
    call doc_fixup
    call doc_reset
    ret

; doc_reset: the cursor at the start, nothing to undo, nothing changed
doc_reset:
    mov dword [cur_blk], 0
    mov dword [cur_off], 0
    call sel_none
    mov byte [ed_on], 0
    mov dword [undo_stack + US_N], 0
    mov rax, [undo_stack + US_BASE]
    mov [undo_stack + US_TOP], rax
    mov dword [redo_stack + US_N], 0
    mov rax, [redo_stack + US_BASE]
    mov [redo_stack + US_TOP], rax
    mov byte [modified], 0
    mov byte [undo_open], 0
    mov dword [scroll_y], 0
    mov byte [thumbs_all], 1
    inc dword [doc_gen]
    call set_title
    ret

; --- names -----------------------------------------------------------------------

; set_name(RSI = NUL-ended): doc_name, without a directory, NAME_MAX at most
set_name:
    mov rdx, rsi                        ; past the last '/'
.find:
    mov al, [rsi]
    test al, al
    jz .found
    inc rsi
    cmp al, '/'
    jne .find
    mov rdx, rsi
    jmp .find
.found:
    mov rsi, rdx
    lea rdi, [doc_name]
    mov ecx, NAME_MAX
    call str_copy
    ret

; name_ext -> RAX = where doc_name's extension begins (its '.'), or its
; end if it has none. Preserves all but RAX, RCX.
name_ext:
    lea rax, [doc_name]
    xor ecx, ecx                        ; RCX: the last '.'
.char:
    cmp byte [rax], 0
    je .end
    cmp byte [rax], '.'
    jne .next
    mov rcx, rax
.next:
    inc rax
    jmp .char
.end:
    test rcx, rcx
    jz .out
    mov rax, rcx
.out:
    ret

; store_name(RSI = an extension with its dot, NUL-ended, or 0 for
; doc_name's own) -> RSI = the name in the store, in st_name (under
; "compose/", as the store's capability has it)
store_name:
    push rbx
    mov rbx, rsi
    lea rdi, [st_name]
    lea rsi, [s_dir]
    mov ecx, 64
    call str_copy
    test rbx, rbx
    jnz .base
    lea rsi, [doc_name]
    mov ecx, NAME_MAX + 1
    call str_copy
    jmp .out
.base:
    push rdi
    call name_ext                       ; the name up to its extension
    pop rdi
    lea rsi, [doc_name]
.copy:
    cmp rsi, rax
    jae .ext
    mov cl, [rsi]
    mov [rdi], cl
    inc rsi
    inc rdi
    jmp .copy
.ext:
    mov rsi, rbx
    mov ecx, 8
    call str_copy
.out:
    lea rsi, [st_name]
    pop rbx
    ret

; set_title: "name - Compose"
set_title:
    call sb_reset
    lea rsi, [doc_name]
    call sb_str
    lea rsi, [s_title]
    call sb_str
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    jmp plat_title

; status_msg(RSI = NUL-ended): in the status line until the next key
status_msg:
    lea rdi, [st_msg]
    mov ecx, 95
    jmp str_copy

; log_sb: the string built, after "compose: ", on the console
log_sb:
    lea rsi, [sb_buf]
    mov ecx, [sb_len]
    jmp plat_log

; log_start: "compose: " begun
log_start:
    call sb_reset
    lea rsi, [s_log]
    jmp sb_str

; --- opening and saving -----------------------------------------------------------

app_open:
    push rbx
    call set_name
    call name_ext
    mov rbx, rax                        ; RBX: its extension
    lea rdi, [s_txt]
    call ext_is
    je .text
    lea rdi, [s_csv]
    call ext_is
    je .csv
    cmp byte [rbx], 0                   ; no extension: .axd
    jne .axd
    lea rdi, [rbx]
    lea rsi, [s_axd]
    mov ecx, 5
    call str_copy
.axd:
    xor esi, esi
    call store_name
    call plat_load
    test rax, rax
    js .new
    push rax
    call doc_clear
    pop rcx
    mov rsi, [save_buf]
    xor edi, edi
    call des_doc
    mov ebx, eax
    call doc_fixup
    call doc_reset
    test ebx, ebx
    js .bad
    cmp byte [des_view], 0              ; where it was left
    je .opened
    movzx eax, byte [des_v_view]
    cmp eax, V_GRID
    ja .cursor
    mov [view], eax
.cursor:
    mov eax, [des_v_block]
    mov [cur_blk], eax
    mov eax, [des_v_off]
    mov [cur_off], eax
    call cur_fix
    call sel_none
.opened:
    call log_start
    lea rsi, [s_opened]
    call sb_str
    lea rsi, [doc_name]
    call sb_str
    lea rsi, [s_comma]
    call sb_str
    mov eax, [nblocks]
    call sb_num
    lea rsi, [s_blocks]
    call sb_str
    call log_sb
    jmp .out
.bad:
    call log_start
    lea rsi, [s_bad_file]
    call sb_str
    call log_sb
    lea rsi, [s_bad_file]
    call status_msg
    jmp .out
.new:
    call doc_new
    call log_start
    lea rsi, [s_new]
    call sb_str
    lea rsi, [doc_name]
    call sb_str
    call log_sb
    jmp .out
.text:
    xor esi, esi
    call store_name
    call plat_load
    test rax, rax
    js .missing
    push rax
    call doc_clear
    pop rcx
    mov rsi, [save_buf]
    call text_import
    jmp .imported
.csv:
    xor esi, esi
    call store_name
    call plat_load
    test rax, rax
    js .missing
    push rax
    call doc_clear
    pop rcx
    mov rsi, [save_buf]
    call csv_import
.imported:
    call doc_fixup
    call name_grids
    mov rdi, rbx                        ; saved, from now on, as NAME.axd
    lea rsi, [s_axd]
    mov ecx, 5
    call str_copy
    call doc_reset
    mov byte [modified], 1
    call log_start
    lea rsi, [s_imported]
    call sb_str
    lea rsi, [st_name]
    call sb_str
    lea rsi, [s_comma]
    call sb_str
    mov eax, [nblocks]
    call sb_num
    lea rsi, [s_blocks]
    call sb_str
    call log_sb
    jmp .out
.missing:
    mov rdi, rbx
    lea rsi, [s_axd]
    mov ecx, 5
    call str_copy
    jmp .new
.out:
    pop rbx
    ret

; ext_is(RBX = an extension, RDI = one, lower-case, NUL-ended) -> ZF if it
; is that one
ext_is:
    mov rsi, rbx
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .cmp
    inc ecx
    jmp .len
.cmp:
    jmp ci_eq

; save: the document into the store, as doc_name
save:
    push rbx
    call cell_commit
    mov eax, [view]
    mov [ser_v_view], al
    mov eax, [cur_blk]
    mov [ser_v_block], eax
    mov eax, [cur_off]
    mov [ser_v_off], eax
    mov byte [ser_view], 1
    mov rdi, [save_buf]
    mov esi, SAVE_MAX
    xor edx, edx
    xor ecx, ecx
    mov r8d, [nblocks]
    dec r8d
    mov r9d, 0x7FFFFFFF
    call ser_doc
    mov byte [ser_view], 0
    cmp rax, -1
    je .big
    mov rbx, rax
    xor esi, esi
    call store_name
    mov rdx, rbx
    call plat_save
    test rax, rax
    js .failed
    mov byte [modified], 0
    call sb_reset
    lea rsi, [s_saved_as]
    call sb_str
    lea rsi, [doc_name]
    call sb_str
    lea rsi, [sb_buf]
    mov eax, [sb_len]
    mov byte [rsi + rax], 0
    call status_msg
    call log_start
    lea rsi, [s_saved_log]
    call sb_str
    lea rsi, [doc_name]
    call sb_str
    lea rsi, [s_comma]
    call sb_str
    mov eax, ebx
    call sb_num
    lea rsi, [s_bytes]
    call sb_str
    mov eax, [nblocks]
    call sb_num
    lea rsi, [s_blocks]
    call sb_str
    call log_sb
    jmp .out
.big:
    lea rsi, [s_too_big]
    call status_msg
    jmp .log_fail
.failed:
    lea rsi, [s_not_saved]
    call status_msg
.log_fail:
    call log_start
    lea rsi, [s_not_saved]
    call sb_str
    call log_sb
.out:
    pop rbx
    ret

; export_text, export_csv: NAME.txt, NAME.csv (the cursor's grid, or the
; first)
export_text:
    push rbx
    mov rdi, [save_buf]
    mov esi, SAVE_MAX
    call text_export
    cmp rax, -1
    je .big
    mov rbx, rax
    lea rsi, [s_txt]
    call store_name
    mov rdx, rbx
    call plat_save
    test rax, rax
    js .failed
    call exported
    jmp .out
.big:
.failed:
    lea rsi, [s_not_saved]
    call status_msg
.out:
    pop rbx
    ret

export_csv:
    push rbx
    call cur_kind
    mov edx, [cur_blk]
    cmp eax, BK_GRID
    je .grid
    xor edx, edx
.find:
    cmp edx, [nblocks]
    jae .none
    mov edi, edx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    je .grid
    inc edx
    jmp .find
.grid:
    mov rdi, [save_buf]
    mov esi, SAVE_MAX
    call csv_export
    cmp rax, -1
    je .none
    mov rbx, rax
    lea rsi, [s_csv]
    call store_name
    mov rdx, rbx
    call plat_save
    test rax, rax
    js .none
    call exported
    jmp .out
.none:
    lea rsi, [s_not_saved]
    call status_msg
.out:
    pop rbx
    ret

; exported: "Saved compose/NAME.ext" (st_name), here and on the console
exported:
    call log_start
    lea rsi, [s_exported]
    call sb_str
    lea rsi, [st_name]
    call sb_str
    call log_sb
    lea rsi, [sb_buf + 9]
    mov eax, [sb_len]
    mov byte [sb_buf + rax], 0
    jmp status_msg

; --- the views -------------------------------------------------------------------------

; set_view(EAX = V_*)
set_view:
    push rbx
    mov ebx, eax
    call cell_commit
    mov [view], ebx
    cmp ebx, V_GRID
    jne .logged
    call cur_kind                       ; onto a grid: the cursor's, or the first
    cmp eax, BK_GRID
    je .logged
    xor ecx, ecx
.find:
    cmp ecx, [nblocks]
    jae .logged
    mov edi, ecx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    je .found
    inc ecx
    jmp .find
.found:
    mov [cur_blk], ecx
    mov dword [cur_off], 0
    call sel_none
    mov dword [gv_row0], 0
    mov dword [gv_col0], 0
.logged:
    mov byte [vw_follow], 1
    call log_start
    lea rsi, [s_view]
    call sb_str
    lea rax, [view_names]
    mov rsi, [rax + rbx * 8]
    call sb_str
    call log_sb
    pop rbx
    ret

; go_slide(EAX = a slide): the cursor onto its title (or first block)
go_slide:
    cmp eax, [sl_n]
    jae .out
    test eax, eax
    js .out
    shl eax, 4
    add rax, [sl_base]
    mov ecx, [rax + SL_TITLE]
    cmp ecx, -1
    jne .there
    mov ecx, [rax + SL_FIRST]
.there:
    mov [cur_blk], ecx
    mov dword [cur_off], 0
    call cur_fix
    call sel_none
    mov byte [vw_follow], 1
.out:
    ret

; --- presenting -------------------------------------------------------------------------

present_start:
    push rbx
    call cell_commit
    call slides_build
    cmp dword [sl_n], 0
    je .none
    xor ebx, ebx                        ; from the slide shown, on slides
    cmp dword [view], V_SLIDES
    jne .from
    mov edi, [cur_blk]
    call slide_of
    mov ebx, eax
    test ebx, ebx
    jns .from
    xor ebx, ebx
.from:
    mov [pres_slide], ebx
    mov byte [pres_on], 1
    mov edi, 1
    call plat_present
    test eax, eax
    jz .refused
    call log_slide
    pop rbx
    ret
.none:
    lea rsi, [s_no_present]
    call status_msg
    pop rbx
    ret
.refused:
    mov byte [pres_on], 0
    lea rsi, [s_no_window]
    call status_msg
    pop rbx
    ret

present_stop:
    cmp byte [pres_on], 0
    je .out
    mov byte [pres_on], 0
    xor edi, edi
    call plat_present
    call log_start
    lea rsi, [s_pres_end]
    call sb_str
    call log_sb
.out:
    ret

; log_slide: "compose: presenting slide N of M"
log_slide:
    call log_start
    lea rsi, [s_presenting]
    call sb_str
    mov eax, [pres_slide]
    inc eax
    call sb_num
    lea rsi, [s_of]
    call sb_str
    mov eax, [sl_n]
    call sb_num
    jmp log_sb

; pres_key(EAX = a key) -> EAX = AE_*
pres_key:
    cmp eax, 27
    je .stop
    cmp eax, 'q'
    je .stop
    cmp eax, KEY_RIGHT
    je .next
    cmp eax, KEY_DOWN
    je .next
    cmp eax, KEY_PGDN
    je .next
    cmp eax, ' '
    je .next
    cmp eax, 10
    je .next
    cmp eax, 'n'
    je .next
    cmp eax, KEY_LEFT
    je .prev
    cmp eax, KEY_UP
    je .prev
    cmp eax, KEY_PGUP
    je .prev
    cmp eax, 8
    je .prev
    cmp eax, 'p'
    je .prev
    cmp eax, KEY_HOME
    je .first
    cmp eax, KEY_END
    je .last
    xor eax, eax
    ret
.stop:
    call present_stop
    mov eax, AE_PAINT
    ret
.next:
    mov eax, [pres_slide]
    inc eax
    cmp eax, [sl_n]
    jae .stay
    jmp .show
.prev:
    mov eax, [pres_slide]
    test eax, eax
    jz .stay
    dec eax
    jmp .show
.first:
    xor eax, eax
    jmp .show
.last:
    mov eax, [sl_n]
    dec eax
.show:
    mov [pres_slide], eax
    call log_slide
    mov eax, AE_PRESENT
    ret
.stay:
    xor eax, eax
    ret

; --- events -----------------------------------------------------------------------------

app_event:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov ebx, edi                        ; EBX: what; R12D: its code
    mov r12d, esi
    mov r13d, edx                       ; R13D, R14D: where
    mov r14d, ecx
    mov r15d, r8d                       ; R15D: from the presenter's window
    cmp ebx, WE_CLOSE
    je .close
    cmp byte [pres_on], 0
    je .main
    cmp ebx, WE_KEY                     ; presenting: keys move it on
    jne .pres_mouse
    mov eax, r12d
    call pres_key
    jmp .out
.pres_mouse:
    test r15d, r15d
    jz .main
    cmp ebx, WE_PRESS                   ; a click on it: the next slide
    jne .nothing
    mov eax, KEY_RIGHT
    cmp r12d, 1
    je .pres_click
    mov eax, KEY_LEFT
.pres_click:
    call pres_key
    jmp .out
.main:
    test r15d, r15d
    jnz .nothing
    cmp ebx, WE_KEY
    je .key
    cmp ebx, WE_PRESS
    je .press
    cmp ebx, WE_MOVE
    je .move
    cmp ebx, WE_RELEASE
    je .release
    cmp ebx, WE_WHEEL
    je .wheel
.nothing:
    xor eax, eax
    jmp .out
.close:
    test r15d, r15d
    jz .quit
    call present_stop
    mov eax, AE_PAINT
    jmp .out
.quit:
    mov eax, AE_QUIT
    jmp .out
.key:
    mov byte [st_msg], 0
    mov eax, r12d
    call on_key
    cmp byte [quitting], 0
    je .out
    mov eax, AE_QUIT
    jmp .out
.press:
    mov byte [st_msg], 0
    mov byte [dragging], 0
    cmp r12d, 1
    jne .nothing
    mov edi, r13d
    mov esi, r14d
    call on_press
    jmp .out
.move:
    cmp byte [dragging], 0
    je .nothing
    mov edi, r13d
    mov esi, r14d
    call on_drag
    jmp .out
.release:
    mov byte [dragging], 0
    xor eax, eax
    jmp .out
.wheel:
    mov edi, r13d
    mov esi, r14d
    mov edx, r12d
    call on_wheel
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; on_key(EAX = a key) -> EAX = AE_*
on_key:
    push rbx
    mov ebx, eax
    mov byte [vw_follow], 1
    cmp ebx, KEY_UP                     ; all but up and down forget the column
    je .goal_kept
    cmp ebx, KEY_DOWN
    je .goal_kept
    mov dword [goal_x], -1
.goal_kept:
    cmp byte [ed_on], 0                 ; typing into a cell: these stay in it
    je .not_editing
    cmp ebx, 27
    je .cancel
    cmp ebx, ' '
    jb .commit
    cmp ebx, 0x7F
    jb .dispatch
    cmp ebx, KEY_LEFT
    je .dispatch
    cmp ebx, KEY_RIGHT
    je .dispatch
    cmp ebx, KEY_HOME
    je .dispatch
    cmp ebx, KEY_END
    je .dispatch
    cmp ebx, KEY_DEL
    je .dispatch
    cmp ebx, 0x80
    jb .dispatch
.commit:
    cmp ebx, 8                          ; (backspace edits; enter and tab commit
    je .dispatch                        ; and then move, themselves)
    cmp ebx, 10
    je .dispatch
    cmp ebx, 9
    je .dispatch
    call cell_commit
    jmp .dispatch
.cancel:
    call cell_cancel
    jmp .paint
.not_editing:
.dispatch:
    cmp ebx, ' '
    jb .control
    cmp ebx, 0x7F
    je .paint
    jb .char
    cmp ebx, 0xA0                       ; Latin-1 from the keyboard map: as UTF-8
    jae .latin
    jmp .special
.char:
    mov eax, ebx
    call insert_char
    jmp .paint
.latin:
    mov eax, ebx
    shr eax, 6
    or eax, 0xC0
    call insert_char
    mov eax, ebx
    and eax, 0x3F
    or eax, 0x80
    call insert_char
    jmp .paint
.control:
    cmp ebx, 8
    je .backspace
    cmp ebx, 9
    je .tab
    cmp ebx, 10
    je .enter
    cmp ebx, 13
    je .enter
    cmp ebx, 27
    je .escape
    lea rax, [ctrl_keys]
    mov rax, [rax + rbx * 8]
    test rax, rax
    jz .none
    call rax
    jmp .paint
.backspace:
    call do_backspace
    jmp .paint
.enter:
    cmp dword [view], V_GRID
    jne .enter_text
    cmp byte [ed_on], 0
    je .enter_text
    call cell_commit
    mov eax, 1
    xor edx, edx
    call cell_move
    jmp .paint
.enter_text:
    call do_enter
    jmp .paint
.tab:
    call cur_kind
    cmp eax, BK_GRID
    jne .tab_text
    call cell_commit
    call cell_tab
    jmp .paint
.tab_text:
    mov eax, ' '
    call insert_char
    mov eax, ' '
    call insert_char
    mov eax, ' '
    call insert_char
    mov eax, ' '
    call insert_char
    jmp .paint
.escape:
    call sel_none
    jmp .paint
.special:
    cmp ebx, KEY_LEFT
    je .left
    cmp ebx, KEY_RIGHT
    je .right
    cmp ebx, KEY_UP
    je .up
    cmp ebx, KEY_DOWN
    je .down
    cmp ebx, KEY_HOME
    je .home
    cmp ebx, KEY_END
    je .end
    cmp ebx, KEY_PGUP
    je .pgup
    cmp ebx, KEY_PGDN
    je .pgdn
    cmp ebx, KEY_DEL
    je .delete
    cmp ebx, KEY_BTAB
    je .btab
    cmp ebx, KEY_F1
    je .f1
    cmp ebx, KEY_F1 + 1
    je .f2
    cmp ebx, KEY_F1 + 2
    je .f3
    cmp ebx, KEY_F1 + 4
    je .f5
    cmp ebx, KEY_F1 + 6
    je .f7
    cmp ebx, KEY_F1 + 8
    je .f9
    cmp ebx, KEY_F1 + 9
    je .f10
    cmp ebx, KEY_F1 + 11
    je .f12
.none:
    xor eax, eax
    pop rbx
    ret
.left:
    cmp dword [view], V_GRID
    jne .left_text
    cmp byte [ed_on], 0
    jne .left_text
    xor eax, eax
    mov edx, -1
    call cell_move
    jmp .paint
.left_text:
    call sel_any                        ; something chosen: to its start
    je .left_move
    cmp byte [ed_on], 0
    jne .left_move
    call sel_range
    mov [cur_blk], eax
    mov [cur_off], edx
    call sel_none
    jmp .paint
.left_move:
    call move_left
    call sel_none
    jmp .paint
.right:
    cmp dword [view], V_GRID
    jne .right_text
    cmp byte [ed_on], 0
    jne .right_text
    xor eax, eax
    mov edx, 1
    call cell_move
    jmp .paint
.right_text:
    call sel_any
    je .right_move
    cmp byte [ed_on], 0
    jne .right_move
    call sel_range
    mov [cur_blk], ecx
    mov [cur_off], r8d
    call sel_none
    jmp .paint
.right_move:
    call move_right
    call sel_none
    jmp .paint
.up:
    mov ecx, -1
    jmp .vertical
.down:
    mov ecx, 1
.vertical:
    cmp dword [view], V_GRID
    je .vertical_grid
    push rcx
    call view_layout
    pop rcx
    push rcx
    call move_vert
    pop rcx
    jnc .moved
    cmp dword [view], V_SLIDES          ; off a slide: onto the next one
    jne .moved
    mov eax, [vw_slide]
    add eax, ecx
    call go_slide
.moved:
    call sel_none
    jmp .paint
.vertical_grid:
    mov eax, ecx
    xor edx, edx
    call cell_move
    jmp .paint
.home:
    cmp dword [view], V_GRID
    jne .home_text
    cmp byte [ed_on], 0
    jne .home_text
    mov eax, [cur_off]                  ; the row's first cell
    xor edx, edx
    mov ecx, MAXC
    div ecx
    imul eax, eax, MAXC
    mov [cur_off], eax
    jmp .paint
.home_text:
    call view_layout
    call move_home
    call sel_none
    jmp .paint
.end:
    cmp dword [view], V_GRID
    je .paint
    call view_layout
    call move_end
    call sel_none
    jmp .paint
.pgup:
    mov ecx, -1
    jmp .page
.pgdn:
    mov ecx, 1
.page:
    mov eax, [view]
    cmp eax, V_SLIDES
    je .page_slide
    cmp eax, V_GRID
    je .page_grid
    imul ecx, ecx, VIEW_H - 80          ; pages: the view scrolled, the cursor
    add [scroll_y], ecx                 ; to the same place in it
    mov byte [vw_follow], 0
    call view_layout
    mov eax, VIEW_H / 2
    call cursor_at_view
    jmp .paint
.page_slide:
    push rcx
    call view_layout
    pop rcx
    mov eax, [vw_slide]
    add eax, ecx
    call go_slide
    jmp .paint
.page_grid:
    imul eax, ecx, GV_ROWS - 2
    xor edx, edx
    call cell_move
    jmp .paint
.delete:
    call do_delete
    jmp .paint
.btab:
    call cur_kind
    cmp eax, BK_GRID
    jne .paint
    call cell_commit
    xor eax, eax
    mov edx, -1
    call cell_move
    jmp .paint
.f1:
    mov eax, V_PAGES
    call set_view
    jmp .paint
.f2:
    mov eax, V_SLIDES
    call set_view
    jmp .paint
.f3:
    mov eax, V_GRID
    call set_view
    jmp .paint
.f5:
    call present_start
    mov eax, AE_PAINT | AE_PRESENT
    pop rbx
    ret
.f7:
    call k_theme
    jmp .paint
.f9:
    call export_text
    jmp .paint
.f10:
    call export_csv
    jmp .paint
.f12:
    call dump
    xor eax, eax
    pop rbx
    ret
.paint:
    mov eax, AE_PAINT
    pop rbx
    ret

; cursor_at_view(EAX = y in the view): the cursor onto the line there
cursor_at_view:
    mov edx, eax
    add edx, [scroll_y]
    mov eax, PG_X + PG_M
    call hit_line
    test rax, rax
    jz .out
    mov edx, PG_X + PG_M
    call cursor_to
    call sel_none
.out:
    ret

; the keys with ctrl
k_all:
    cmp dword [view], V_GRID
    je .out
    call cell_commit
    mov dword [anc_blk], 0
    mov dword [anc_off], 0
    mov eax, [nblocks]
    dec eax
    mov [cur_blk], eax
    mov edi, eax
    call blk_at
    mov ecx, [rax + BL_LEN]
    cmp byte [rax + BL_KIND], BK_GRID
    je .whole
    cmp byte [rax + BL_KIND], BK_IMAGE
    jne .end
.whole:
    mov ecx, 1                          ; (a grid or an image last: all of it)
.end:
    mov [cur_off], ecx
    mov byte [vw_follow], 0
.out:
    ret

k_bold:
    mov eax, A_BOLD
    jmp toggle_attr
k_italic:
    mov eax, A_ITALIC
    jmp toggle_attr
k_under:
    mov eax, A_UNDER
    jmp toggle_attr
k_strike:
    mov eax, A_STRIKE
    jmp toggle_attr
k_copy:
    jmp copy
k_cut:
    jmp cut
k_paste:
    jmp paste
k_undo:
    call undo
    jnc .done
    lea rsi, [s_no_undo]
    jmp status_msg
.done:
    mov byte [thumbs_all], 1
    ret
k_redo:
    call redo
    jnc .done
    lea rsi, [s_no_redo]
    jmp status_msg
.done:
    mov byte [thumbs_all], 1
    ret
k_save:
    jmp save
k_table:
    cmp dword [view], V_GRID
    jne .page
    call grid_at_end
    ret
.page:
    jmp insert_grid
k_slide:
    jmp insert_frame
k_image:
    jmp insert_image
k_present:
    jmp present_start
k_heading:                              ; text, heading 1, 2, 3, text
    call cur_kind
    mov ecx, BK_H1
    cmp eax, BK_H1
    jb .set
    cmp eax, BK_H3
    ja .set
    lea ecx, [rax + 1]
    cmp ecx, BK_H3
    jbe .set
    mov ecx, BK_PARA
.set:
    mov eax, ecx
    jmp set_kind_to
k_list:                                 ; text, bulleted, numbered, text
    call cur_kind
    mov ecx, BK_BULLET
    cmp eax, BK_BULLET
    jne .set
    mov ecx, BK_NUMBER
.set:
    cmp eax, BK_NUMBER
    jne .go
    mov ecx, BK_PARA
.go:
    mov eax, ecx
    jmp set_kind_to
k_row:
    mov eax, 1
    jmp grid_add
k_col:
    xor eax, eax
    jmp grid_add
k_quit:
    mov byte [quitting], 1
    ret

; set_kind_to(EAX = BK_*): set_kind, but a kind already there kept (not
; turned back to text)
set_kind_to:
    push rax
    call cur_kind
    pop rcx
    cmp eax, ecx
    je .same
    mov eax, ecx
    jmp set_kind
.same:
    cmp ecx, BK_PARA                    ; (text from text: nothing)
    je .out
    mov eax, BK_PARA
    jmp set_kind
.out:
    ret

; grid_at_end: a new grid after the document's last block, the cursor on it
grid_at_end:
    mov eax, [nblocks]
    dec eax
    mov [cur_blk], eax
    mov dword [cur_off], 0
    call cur_fix
    call insert_grid
    mov dword [gv_row0], 0
    mov dword [gv_col0], 0
    ret

; act(EDI = ACT_*)
act:
    cmp edi, ACT_THEME
    ja .out
    lea rax, [act_calls]
    mov rax, [rax + rdi * 8]
    test rax, rax
    jz .out
    jmp rax
.out:
    ret

a_h1:
    mov eax, BK_H1
    jmp set_kind
a_h2:
    mov eax, BK_H2
    jmp set_kind
a_text:
    mov eax, BK_PARA
    jmp set_kind_to
a_bullet:
    mov eax, BK_BULLET
    jmp set_kind
a_number:
    mov eax, BK_NUMBER
    jmp set_kind

; act_on(EDI = ACT_*) -> EAX = 1 if its button shows lit
act_on:
    xor eax, eax
    cmp edi, ACT_BOLD
    je .bold
    cmp edi, ACT_ITALIC
    je .italic
    cmp edi, ACT_UNDER
    je .under
    mov ecx, BK_H1
    cmp edi, ACT_H1
    je .kind
    mov ecx, BK_H2
    cmp edi, ACT_H2
    je .kind
    mov ecx, BK_PARA
    cmp edi, ACT_TEXT
    je .kind
    mov ecx, BK_BULLET
    cmp edi, ACT_BULLET
    je .kind
    mov ecx, BK_NUMBER
    cmp edi, ACT_NUMBER
    je .kind
    ret
.bold:
    mov ecx, A_BOLD
    jmp .attr
.italic:
    mov ecx, A_ITALIC
    jmp .attr
.under:
    mov ecx, A_UNDER
.attr:
    test [typing_attr], ecx
    setnz al
    ret
.kind:
    push rcx
    call cur_kind
    pop rcx
    cmp eax, ecx
    sete al
    movzx eax, al
    ret

; on_press(EDI = x, ESI = y) -> EAX = AE_*
on_press:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    cmp r13d, TB_H
    jge .view
    mov eax, r12d                       ; the views' control
    sub eax, SEG_X + 2
    js .buttons
    cmp eax, SEG_W * 3
    jae .buttons
    cmp r13d, SEG_Y
    jl .none
    cmp r13d, SEG_Y + SEG_H
    jge .none
    xor edx, edx
    mov ecx, SEG_W
    div ecx
    call set_view
    jmp .paint
.buttons:
    lea rbx, [buttons]
.button:
    cmp byte [rbx + BT_ACT], 0
    je .none
    mov ecx, [view]
    mov eax, 1
    shl eax, cl
    test [rbx + BT_VIEWS], al
    jz .next
    movzx eax, word [rbx + BT_X]
    cmp r12d, eax
    jl .next
    movzx ecx, word [rbx + BT_W]
    add eax, ecx
    cmp r12d, eax
    jge .next
    movzx eax, word [rbx + BT_Y]
    cmp r13d, eax
    jl .next
    movzx ecx, word [rbx + BT_H]
    add eax, ecx
    cmp r13d, eax
    jge .next
    movzx edi, byte [rbx + BT_ACT]
    cmp edi, ACT_PRESENT
    je .present
    call cell_commit
    movzx edi, byte [rbx + BT_ACT]
    call act
    mov byte [vw_follow], 1
    jmp .paint
.present:
    call present_start
    mov eax, AE_PAINT | AE_PRESENT
    jmp .out
.next:
    add rbx, BT_SIZE
    jmp .button
.view:
    cmp r13d, WIN_H - ST_H
    jge .none
    mov eax, [view]
    cmp eax, V_GRID
    je .grid
    cmp eax, V_SLIDES
    jne .text
    cmp r12d, SIDE_W                    ; the sidebar: a slide
    jge .text
    call cell_commit
    mov eax, r13d
    sub eax, VIEW_Y + 10
    add eax, [side_scroll]
    js .none
    xor edx, edx
    mov ecx, TH_ITEM
    div ecx
    call go_slide
    jmp .paint
.text:
    call cell_commit
    call view_layout
    mov eax, r12d
    sub eax, [vw_ox]
    mov edx, r13d
    sub edx, [vw_oy]
    call hit_line
    test rax, rax
    jz .paint
    mov edx, r12d
    sub edx, [vw_ox]
    call cursor_to
    call sel_none
    mov byte [dragging], 1
    jmp .paint
.grid:
    call grid_press
    jmp .paint
.none:
    xor eax, eax
    jmp .out
.paint:
    mov eax, AE_PAINT
.out:
    pop r13
    pop r12
    pop rbx
    ret

; grid_press(R12D = x, R13D = y): on the grid view
grid_press:
    cmp r13d, GV_BOTTOM                 ; a tab: that grid
    jge .tab
    cmp r13d, GV_TOP
    jl .bar
    cmp r13d, GV_CELLS_Y
    jl .out
    cmp r12d, GV_HEAD_W
    jl .out
    call cur_kind
    cmp eax, BK_GRID
    jne .out
    call cell_commit
    mov eax, r13d
    sub eax, GV_CELLS_Y
    xor edx, edx
    mov ecx, GV_ROW_H
    div ecx
    add eax, [gv_row0]
    cmp eax, MAXR
    jae .out
    push rax
    mov eax, r12d
    sub eax, GV_HEAD_W
    xor edx, edx
    mov ecx, GV_COL_W
    div ecx
    add eax, [gv_col0]
    pop rcx
    cmp eax, MAXC
    jae .out
    imul ecx, ecx, MAXC
    add ecx, eax
    mov [cur_off], ecx
    call sel_none
    ret
.bar:
    cmp r12d, 124                       ; the formula bar: what is there, to change
    jl .out
    cmp byte [ed_on], 0
    jne .out
    call cur_kind
    cmp eax, BK_GRID
    jne .out
    mov eax, 1
    jmp cell_begin
.tab:
    xor ecx, ecx
.each:
    cmp ecx, [gv_ntabs]
    jae .out
    cmp r12d, [gv_tabs + rcx * 8]
    jl .next
    cmp r12d, [gv_tabs + rcx * 8 + 8]
    jge .next
    call cell_commit
    mov eax, [gv_tabs + rcx * 8 + 4]
    mov [cur_blk], eax
    mov dword [cur_off], 0
    call sel_none
    mov dword [gv_row0], 0
    mov dword [gv_col0], 0
    ret
.next:
    inc ecx
    jmp .each
.out:
    ret

; on_drag(EDI = x, ESI = y) -> EAX = AE_*: the cursor there, the anchor
; where it was pressed
on_drag:
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    call view_layout
    mov eax, r12d
    sub eax, [vw_ox]
    mov edx, r13d
    sub edx, [vw_oy]
    call hit_line
    test rax, rax
    jz .out
    cmp dword [rax + LN_KIND], LK_TEXT  ; (text only)
    jne .out
    mov edx, r12d
    sub edx, [vw_ox]
    call cursor_to
.out:
    mov eax, AE_PAINT
    pop r13
    pop r12
    ret

; on_wheel(EDI = x, ESI = y, EDX = notches, up positive) -> EAX = AE_*
on_wheel:
    mov eax, [view]
    cmp eax, V_PAGES
    je .pages
    cmp eax, V_GRID
    je .grid
    cmp edi, SIDE_W
    jge .none
    imul edx, edx, -60
    add [side_scroll], edx
    jmp .paint
.pages:
    imul edx, edx, -80
    add [scroll_y], edx
    call scroll_clamp
    jmp .paint
.grid:
    imul edx, edx, -3
    add [gv_row0], edx
    jns .grid_max
    mov dword [gv_row0], 0
.grid_max:
    cmp dword [gv_row0], MAXR - GV_ROWS + 1
    jle .paint
    mov dword [gv_row0], MAXR - GV_ROWS + 1
.paint:
    mov eax, AE_PAINT
    ret
.none:
    xor eax, eax
    ret

; hit_line(EAX = x, EDX = y, laid-out coordinates) -> RAX = the line there,
; or else the nearest; 0 if there are none. A frame's box is never one.
hit_line:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax
    mov r13d, edx
    xor r14d, r14d                      ; R14: the nearest; R15: how far
    mov r15, -1
    mov rbx, [ln_base]
    mov ebp, [ln_n]
.line:
    test ebp, ebp
    jz .done
    cmp dword [rbx + LN_KIND], LK_BOX
    jne .measure
    mov edi, [rbx + LN_BLK]
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    je .next
.measure:
    xor ecx, ecx                        ; ECX: how far up or down
    mov eax, [rbx + LN_Y]
    sub eax, r13d
    jg .dy
    mov eax, r13d
    sub eax, [rbx + LN_Y]
    sub eax, [rbx + LN_H]
    inc eax
    jle .dx
.dy:
    mov ecx, eax
.dx:
    xor edx, edx                        ; EDX: across
    mov eax, [rbx + LN_X0]
    sub eax, r12d
    jg .dxs
    mov eax, r12d
    sub eax, [rbx + LN_X0]
    sub eax, [rbx + LN_W]
    inc eax
    jle .score
.dxs:
    mov edx, eax
.score:
    imul rcx, rcx, 8
    add rcx, rdx
    cmp rcx, r15
    jae .next
    mov r15, rcx
    mov r14, rbx
.next:
    add rbx, LN_SIZE
    dec ebp
    jmp .line
.done:
    mov rax, r14
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; --- the document, on the console --------------------------------------------------

; dump: each block on the console, a grid's cells with their values
dump:
    push rbx
    push r12
    push r13
    push r14
    call log_start
    lea rsi, [s_dump]
    call sb_str
    mov eax, [nblocks]
    call sb_num
    lea rsi, [s_blocks]
    call sb_str
    lea rsi, [s_view_is]
    call sb_str
    mov eax, [view]
    lea rcx, [view_names]
    mov rsi, [rcx + rax * 8]
    call sb_str
    lea rsi, [s_cursor]
    call sb_str
    mov eax, [cur_blk]
    call sb_num
    mov al, ':'
    call sb_char
    mov eax, [cur_off]
    call sb_num
    call log_sb
    xor ebx, ebx
.block:
    cmp ebx, [nblocks]
    jae .out
    mov edi, ebx
    call blk_at
    mov r12, rax
    call log_start
    mov eax, ebx
    call sb_num
    mov al, ' '
    call sb_char
    movzx eax, byte [r12 + BL_KIND]
    lea rcx, [kind_names]
    mov rsi, [rcx + rax * 8]
    call sb_str
    cmp byte [r12 + BL_KIND], BK_SLIDE
    jne .text
    mov al, ' '
    call sb_char
    movzx eax, word [r12 + BL_KIDS]
    call sb_num
.text:
    lea rsi, [s_quote]
    call sb_str
    mov rsi, [r12 + BL_TEXT]
    mov ecx, [r12 + BL_LEN]
    cmp ecx, 160
    jbe .whole
    mov ecx, 160
.whole:
    call sb_mem
    mov al, '"'
    call sb_char
    cmp byte [r12 + BL_KIND], BK_GRID
    jne .logged
    mov r13, [r12 + BL_DATA]
    mov al, ' '
    call sb_char
    mov eax, [r13 + GR_ROWS]
    call sb_num
    mov al, 'x'
    call sb_char
    mov eax, [r13 + GR_COLS]
    call sb_num
    call log_sb
    xor r14d, r14d                      ; each cell that holds anything
.cell:
    cmp r14d, MAXR * MAXC
    jae .next
    mov eax, r14d
    xor edx, edx
    mov ecx, MAXC
    div ecx
    mov rdi, r13
    mov esi, eax
    call cell_at
    cmp dword [rax + CE_LEN], 0
    je .cell_next
    push rax
    call log_start
    lea rsi, [s_cell_in]
    call sb_str
    mov eax, r14d
    call sb_cell
    lea rsi, [s_eq]
    call sb_str
    mov rax, [rsp]
    mov rsi, [rax + CE_TEXT]
    mov ecx, [rax + CE_LEN]
    cmp ecx, 120
    jbe .typed
    mov ecx, 120
.typed:
    call sb_mem
    lea rsi, [s_arrow]
    call sb_str
    pop rdi
    lea rsi, [gv_buf]
    call cell_show
    call sb_mem
    call log_sb
.cell_next:
    inc r14d
    jmp .cell
.logged:
    call log_sb
.next:
    inc ebx
    jmp .block
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; --- the theme ----------------------------------------------------------------

; app_theme(EDI = 1 if the system's theme is dark) -> EAX = AE_* to do
app_theme:
    xor eax, eax
    cmp dil, [sys_dark]
    je .out
    mov [sys_dark], dil
    cmp byte [theme_mode], THEME_AUTO
    jne .out                            ; set light or dark here: kept
    call theme_apply
    call theme_log
    mov eax, AE_PAINT
    cmp byte [pres_on], 0
    je .out
    or eax, AE_PRESENT
.out:
    ret

; k_theme: auto, then light, then dark, then auto again; kept in the store
k_theme:
    movzx eax, byte [theme_mode]
    inc eax
    cmp eax, THEME_DARK
    jbe .set
    xor eax, eax
.set:
    mov [theme_mode], al
    call theme_apply
    call theme_log
    jmp theme_save

; theme_apply: the colours as theme_mode and sys_dark have them; the
; thumbnails drawn again in them
theme_apply:
    movzx eax, byte [theme_mode]
    lea rcx, [theme_labels]
    mov rcx, [rcx + rax * 8]
    mov [theme_label], rcx
    xor edi, edi
    cmp eax, THEME_LIGHT
    je .set
    inc edi
    cmp eax, THEME_DARK
    je .set
    movzx edi, byte [sys_dark]
.set:
    mov [dark], dil
    call ui_theme
    mov dword [thumb_gen], -1
    mov byte [thumbs_all], 1
    ret

; theme_log: "compose: theme auto, dark"
theme_log:
    call log_start
    lea rsi, [s_theme_is]
    call sb_str
    movzx eax, byte [theme_mode]
    lea rsi, [theme_names]
    mov rsi, [rsi + rax * 8]
    call sb_str
    lea rsi, [s_comma_light]
    cmp byte [dark], 0
    je .shown
    lea rsi, [s_comma_dark]
.shown:
    call sb_str
    jmp log_sb

; theme_save: theme_mode into the store, as "auto", "light" or "dark"
theme_save:
    movzx eax, byte [theme_mode]
    lea rsi, [theme_names]
    mov rsi, [rsi + rax * 8]
    mov rdi, [save_buf]
    xor edx, edx
.copy:
    mov al, [rsi + rdx]
    test al, al
    jz .copied
    mov [rdi + rdx], al
    inc edx
    jmp .copy
.copied:
    mov byte [rdi + rdx], 10
    inc edx
    lea rsi, [s_theme_file]
    jmp plat_save

; theme_load: theme_mode from the store (auto if it has none), and applied
theme_load:
    mov byte [theme_mode], THEME_AUTO
    lea rsi, [s_theme_file]
    call plat_load
    test rax, rax
    jle .apply
    mov rsi, [save_buf]
    mov al, [rsi]
    cmp al, 'l'
    jne .dark
    mov byte [theme_mode], THEME_LIGHT
.dark:
    cmp al, 'd'
    jne .apply
    mov byte [theme_mode], THEME_DARK
.apply:
    jmp theme_apply

section .rodata
s_untitled:     db 'untitled.axd', 0
s_dir:          db 0                    ; (the store's names are compose's own)
s_title:        db ' ', 0xE2, 0x80, 0x94, ' Compose', 0
s_log:          db 'compose: ', 0
s_txt:          db '.txt', 0
s_csv:          db '.csv', 0
s_axd:          db '.axd', 0
s_opened:       db 'opened ', 0
s_new:          db 'new ', 0
s_imported:     db 'imported ', 0
s_bad_file:     db 'That is not a document this can read', 0
s_comma:        db ', ', 0
s_blocks:       db ' blocks', 0
s_bytes:        db ' bytes, ', 0
s_saved_as:     db 'Saved ', 0
s_saved_log:    db 'saved ', 0
s_exported:     db 'exported ', 0
s_too_big:      db 'Too big to save (1 MiB at most)', 0
s_not_saved:    db 'Not saved: is there a store? (store format)', 0
s_view:         db 'view ', 0
s_no_present:   db 'No slides to present', 0
s_no_window:    db 'No window to present in', 0
s_presenting:   db 'presenting slide ', 0
s_pres_end:     db 'presenting ended', 0
s_no_undo:      db 'Nothing to undo', 0
s_no_redo:      db 'Nothing to redo', 0
s_dump:         db 'document, ', 0
s_view_is:      db ', view ', 0
s_cursor:       db ', cursor ', 0
s_quote:        db ' "', 0
s_cell_in:      db '  ', 0
s_eq:           db ' = ', 0
s_arrow:        db ' -> ', 0
s_v_pages:      db 'pages', 0
s_v_slides:     db 'slides', 0
s_v_grid:       db 'grid', 0
s_k_para:       db 'text', 0
s_k_h1:         db 'h1', 0
s_k_h2:         db 'h2', 0
s_k_h3:         db 'h3', 0
s_k_bullet:     db 'bullet', 0
s_k_number:     db 'number', 0
s_k_grid:       db 'grid', 0
s_k_image:      db 'image', 0
s_k_slide:      db 'slide', 0
s_b_bold:       db 'B', 0
s_b_italic:     db 'I', 0
s_b_under:      db 'U', 0
s_b_h1:         db 'H1', 0
s_b_h2:         db 'H2', 0
s_b_text:       db 'Text', 0
s_b_bullet:     db 0xE2, 0x80, 0xA2, 0
s_b_number:     db '1.', 0
s_b_table:      db '+ Table', 0
s_b_slide:      db '+ Slide', 0
s_b_image:      db '+ Image', 0
s_b_present:    db 'Present', 0
s_b_save:       db 'Save', 0
s_th_auto:      db 'Auto', 0
s_th_light:     db 'Light', 0
s_th_dark:      db 'Dark', 0
s_theme_auto:   db 'auto', 0
s_theme_light:  db 'light', 0
s_theme_dark:   db 'dark', 0
s_theme_is:     db 'theme ', 0
s_comma_light:  db ', light', 0
s_comma_dark:   db ', dark', 0
s_theme_file:   db 'theme', 0
s_b_row:        db '+ Row', 0
s_b_col:        db '+ Column', 0
s_b_grid:       db '+ Grid', 0

section .data
align 8
view_names:     dq s_v_pages, s_v_slides, s_v_grid
seg_labels:     dq s_seg_pages, s_seg_slides, s_seg_grid
kind_names:     dq s_k_para, s_k_h1, s_k_h2, s_k_h3, s_k_bullet, s_k_number
                dq s_k_grid, s_k_image, s_k_slide
ctrl_keys:      dq 0, k_all, k_bold, k_copy, k_strike, k_italic, 0, k_image ; 0-7
                dq 0, 0, 0, k_slide, k_list, 0, k_heading, 0          ; 8-15
                dq k_present, k_quit, k_row, k_save, k_table, k_under, k_paste, k_quit ; 16-23
                dq k_cut, k_redo, k_undo, 0, 0, 0, 0, k_col           ; 24-31
act_calls:      dq 0, k_bold, k_italic, k_under, a_h1, a_h2, a_text, a_bullet
                dq a_number, k_table, k_slide, k_image, k_present, k_save, k_row, k_col
                dq k_theme
theme_labels:   dq s_th_auto, s_th_light, s_th_dark
theme_names:    dq s_theme_auto, s_theme_light, s_theme_dark

BT_RIGHT        equ WIN_W - 16
buttons:
    BUTTON 290, 34, ACT_BOLD, VP | VS, BS_GHOST, UI_BOLD, s_b_bold, 0
    BUTTON 326, 34, ACT_ITALIC, VP | VS, BS_GHOST, WF_ITALIC * WF_SIZES + WF_PX16, s_b_italic, 0
    BUTTON 362, 34, ACT_UNDER, VP | VS, BS_GHOST, UI_FONT, s_b_under, 0
    BUTTON 412, 42, ACT_H1, VP | VS, BS_GHOST, UI_BOLD, s_b_h1, 0
    BUTTON 456, 42, ACT_H2, VP | VS, BS_GHOST, UI_BOLD, s_b_h2, 0
    BUTTON 500, 52, ACT_TEXT, VP | VS, BS_GHOST, UI_FONT, s_b_text, 0
    BUTTON 554, 36, ACT_BULLET, VP | VS, BS_GHOST, UI_BOLD, s_b_bullet, 0
    BUTTON 592, 36, ACT_NUMBER, VP | VS, BS_GHOST, UI_FONT, s_b_number, 0
    BUTTON 652, 88, ACT_TABLE, VP | VS, BS_PLAIN, UI_FONT, s_b_table, 0
    BUTTON 746, 84, ACT_SLIDE, VP | VS, BS_PLAIN, UI_FONT, s_b_slide, 0
    BUTTON 836, 88, ACT_IMAGE, VP | VS, BS_PLAIN, UI_FONT, s_b_image, 0
    BUTTON 290, 80, ACT_ROW, VG, BS_PLAIN, UI_FONT, s_b_row, 0
    BUTTON 376, 104, ACT_COL, VG, BS_PLAIN, UI_FONT, s_b_col, 0
    BUTTON 490, 84, ACT_TABLE, VG, BS_PLAIN, UI_FONT, s_b_grid, 0
    BUTTON BT_RIGHT - 80 - 10 - 104 - 10 - 76, 76, ACT_THEME, VP | VS | VG, BS_PLAIN, UI_FONT, 0, 0
    BUTTON BT_RIGHT - 80 - 10 - 104, 104, ACT_PRESENT, VP | VS | VG, BS_PRIMARY, UI_BOLD, s_b_present, 0
    BUTTON BT_RIGHT - 80, 80, ACT_SAVE, VP | VS | VG, BS_PLAIN, UI_FONT, s_b_save, 0
    times BT_SIZE db 0

section .rodata
s_seg_pages:    db 'Pages', 0
s_seg_slides:   db 'Slides', 0
s_seg_grid:     db 'Grid', 0

section .bss
alignb 8
save_buf:       resq 1
view:           resd 1
pressed_act:    resd 1
doc_name:       resb NAME_MAX + 8
st_name:        resb 80
st_msg:         resb 96
pres_on:        resb 1
dragging:       resb 1
quitting:       resb 1
theme_mode:     resb 1                  ; THEME_*
sys_dark:       resb 1                  ; the system's theme: 1 dark
dark:           resb 1                  ; what is shown
alignb 8
theme_label:    resq 1                  ; the theme button's (theme_labels)

section .text
