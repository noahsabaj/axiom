; =============================================================================
;  compose/edit.inc - the cursor, what is chosen, and every change
;
;  The cursor is a block and an offset in its text (cur_blk, cur_off); on a
;  grid the offset is a cell (row * MAXC + column), on an image 0. What is
;  chosen runs from the anchor (anc_blk, anc_off) to the cursor; a grid or
;  an image inside it is chosen whole. A cell being typed into has its text
;  in ed_blk (a block outside the document) until it is committed.
;
;  Undo keeps the document as saved (ser_doc, with the cursor) before each
;  change, typing in one block counted as one change; undoing reads it back.
;  The clipboard is a piece of document in the same format.
;    ed_init(RDI = memory, 16 KiB): ed_blk's text there
;    cur_fix: the cursor (and anchor) inside the document again
;    insert_char(EAX), do_enter, do_backspace, do_delete
;    move_*: left, right, up, down, home, end, by the line table
;    set_kind(EAX = BK_*), toggle_attr(EAX = A_*)
;    insert_grid, insert_frame, insert_image
;    cell_begin(EAX = 1 to keep what is there), cell_commit, cell_cancel,
;      cell_move(EAX = rows, EDX = columns, signed)
;    undo_push(EAX = UK_*), undo, redo
;    copy, cut, paste
;    sel_any -> ZF if nothing is chosen; sel_range -> EAX, EDX = from, ECX,
;      R8D = to (in order)
; =============================================================================

UK_TYPE         equ 1                   ; typing: one change while it goes on
UK_OTHER        equ 2
UNDO_MAX        equ 100                 ; changes kept, each way
UNDO_BYTES      equ 16 << 20
CLIP_BYTES      equ 2 << 20
ED_CAP          equ 4096

section .text

ed_init:
    mov [ed_blk + BL_TEXT], rdi
    mov dword [ed_blk + BL_CAP], ED_CAP
    mov dword [ed_blk + BL_LEN], 0
    mov byte [ed_blk + BL_KIND], BK_PARA
    ret

; cur_ptr -> RAX = the cursor's block. Preserves all but RAX.
cur_ptr:
    push rdi
    mov edi, [cur_blk]
    call blk_at
    pop rdi
    ret

; cur_kind -> EAX = the cursor's block's kind. Preserves all but RAX.
cur_kind:
    call cur_ptr
    movzx eax, byte [rax + BL_KIND]
    ret

; off_fix(EDI = a block, ESI = an offset) -> ESI inside it. Preserves all
; but RSI, RAX.
off_fix:
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    je .grid
    cmp byte [rax + BL_KIND], BK_IMAGE
    je .image
    cmp esi, [rax + BL_LEN]
    jbe .char
    mov esi, [rax + BL_LEN]
.char:                                  ; not inside a character
    test esi, esi
    jz .out
    cmp esi, [rax + BL_LEN]
    je .out
    push rcx
    mov rcx, [rax + BL_TEXT]
    movzx ecx, byte [rcx + rsi]
    and ecx, 0xC0
    cmp ecx, 0x80
    pop rcx
    jne .out
    dec esi
    jmp .char
.grid:
    cmp esi, MAXR * MAXC
    jb .out
    xor esi, esi
    ret
.image:
    xor esi, esi
.out:
    ret

cur_fix:
    mov eax, [nblocks]
    dec eax
    cmp [cur_blk], eax
    jbe .cur_in
    mov [cur_blk], eax
.cur_in:
    cmp [anc_blk], eax
    jbe .anc_in
    mov [anc_blk], eax
.anc_in:
    mov edi, [cur_blk]
    mov esi, [cur_off]
    call off_fix
    mov [cur_off], esi
    mov edi, [anc_blk]
    mov esi, [anc_off]
    call off_fix
    mov [anc_off], esi
    ret

; sel_none: the anchor at the cursor, and the typing attributes from there
sel_none:
    mov eax, [cur_blk]
    mov [anc_blk], eax
    mov eax, [cur_off]
    mov [anc_off], eax
    jmp attr_here

; attr_here: typing_attr from the character before the cursor (or after
; it, at the start)
attr_here:
    mov edi, [cur_blk]
    call blk_texty
    jz .out
    call cur_ptr
    mov ecx, [rax + BL_LEN]
    test ecx, ecx
    jz .plain
    mov rdx, [rax + BL_TEXT]
    mov esi, [rax + BL_CAP]
    add rdx, rsi
    mov esi, [cur_off]
    test esi, esi
    jz .first
    dec esi
.first:
    cmp esi, ecx
    jb .take
    lea esi, [rcx - 1]
.take:
    movzx eax, byte [rdx + rsi]
    mov [typing_attr], eax
.out:
    ret
.plain:
    mov dword [typing_attr], 0
    ret

sel_any:
    mov eax, [cur_blk]
    cmp eax, [anc_blk]
    jne .out
    mov eax, [cur_off]
    cmp eax, [anc_off]
.out:
    ret

sel_range:
    mov eax, [anc_blk]
    mov edx, [anc_off]
    mov ecx, [cur_blk]
    mov r8d, [cur_off]
    cmp eax, ecx
    jb .out
    ja .swap
    cmp edx, r8d
    jbe .out
.swap:
    xchg eax, ecx
    xchg edx, r8d
.out:
    ret

; sel_delete: what is chosen gone, the cursor where it began. CF clear if
; there was nothing chosen (ZF then too).
sel_delete:
    call sel_any
    je .none
    push rbx
    push r12
    push r13
    push r14
    push r15
    call sel_range
    mov r12d, eax                       ; R12D, R13D: from; R14D, R15D: to
    mov r13d, edx
    mov r14d, ecx
    mov r15d, r8d
    cmp r12d, r14d
    jne .blocks
    mov edi, r12d                       ; within one block
    call blk_texty
    jz .whole_one
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    sub edx, r13d
    call text_delete
    jmp .placed
.whole_one:
    mov edi, r12d
    call blk_drop
    mov r13d, 0
    jmp .placed
.blocks:
    lea ebx, [r14 - 1]                  ; those between, last first
.between:
    cmp ebx, r12d
    jbe .ends
    mov edi, ebx
    call blk_delete
    dec r14d
    dec ebx
    jmp .between
.ends:
    mov edi, r14d                       ; the last: its start, or all of it
    call blk_texty
    jz .last_whole
    mov edi, r14d
    xor esi, esi
    mov edx, r15d
    call text_delete
    jmp .first
.last_whole:
    mov edi, r14d
    call blk_drop
    dec r14d
.first:
    mov edi, r12d                       ; the first: its end, or all of it
    call blk_texty
    jz .first_whole
    mov edi, r12d
    mov esi, r13d
    mov edx, 0x7FFFFFFF
    call text_delete
    cmp r14d, r12d                      ; the two halves joined
    je .placed
    mov edi, r14d
    call blk_texty
    jz .placed
    mov edi, r12d
    call blk_merge_next
    jmp .placed
.first_whole:
    mov edi, r12d
    call blk_drop
    mov r13d, 0
    cmp r12d, [nblocks]
    jb .placed
    mov r12d, [nblocks]
    dec r12d
.placed:
    mov [cur_blk], r12d
    mov [cur_off], r13d
    call cur_fix
    call sel_none
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    stc
    ret
.none:
    clc
    ret

; blk_drop(EDI = a block): gone, but never the last one (that becomes an
; empty paragraph)
blk_drop:
    cmp dword [nblocks], 1
    ja .delete
    call blk_at
    mov byte [rax + BL_KIND], BK_PARA
    mov dword [rax + BL_LEN], 0
    mov qword [rax + BL_DATA], 0
    mov word [rax + BL_KIDS], 0
    ret
.delete:
    jmp blk_delete

; blk_merge_next(EDI = a texty block): the one after it (texty) appended to
; it, then gone
blk_merge_next:
    push rbx
    push r12
    mov ebx, edi
    lea edi, [rbx + 1]
    call blk_at
    mov r12, rax
    mov edi, ebx
    call blk_at
    mov esi, [rax + BL_LEN]
    mov rdx, [r12 + BL_TEXT]
    mov rcx, rdx
    mov r8d, [r12 + BL_CAP]
    add rcx, r8
    mov r8d, [r12 + BL_LEN]
    mov edi, ebx
    call text_insert_a
    lea edi, [rbx + 1]
    call blk_delete
    pop r12
    pop rbx
    ret

insert_char:
    push rbx
    mov [ic_char], al
    cmp byte [ed_on], 0
    je .doc
    mov eax, UK_TYPE
    lea rdi, [ed_blk]
    mov esi, [ed_off]
    mov rdx, rdi
    cmp dword [rdi + BL_LEN], ED_CAP - 1
    jae .out
    mov eax, [ed_off]                   ; into the cell's text
    mov rbx, [ed_blk + BL_TEXT]
    mov ecx, [ed_blk + BL_LEN]
    sub ecx, eax
    lea rsi, [rbx + rax]
    call ed_gap
    mov al, [ic_char]
    mov [rsi], al
    inc dword [ed_off]
    jmp .out
.doc:
    call cur_kind
    cmp eax, BK_GRID
    jne .not_grid
    call sel_any
    jne .not_grid
    xor eax, eax                        ; a cell: typing replaces what is there
    call cell_begin
    pop rbx
    mov al, [ic_char]
    jmp insert_char
.not_grid:
    mov eax, UK_TYPE
    call undo_push
    call sel_delete
    call cur_kind
    cmp eax, BK_GRID
    je .after
    cmp eax, BK_IMAGE
    jne .text
.after:
    call para_after                     ; on a grid or an image: a paragraph after it
.text:
    mov edi, [cur_blk]
    mov esi, [cur_off]
    lea rdx, [ic_char]
    mov ecx, 1
    mov r8d, [typing_attr]
    call text_insert
    jc .out
    inc dword [cur_off]
    mov eax, [cur_blk]
    mov [anc_blk], eax
    mov eax, [cur_off]
    mov [anc_off], eax
    mov byte [modified], 1
.out:
    pop rbx
    ret

; ed_gap(RSI = where in ed_blk's text, ECX = bytes after it): one byte of
; room there. Preserves RSI.
ed_gap:
    push rsi
    lea rdi, [rsi + rcx]
    lea rsi, [rdi - 1]
    std
    rep movsb
    cld
    inc dword [ed_blk + BL_LEN]
    pop rsi
    ret

; para_after: an empty paragraph after the cursor's block (in its frame,
; if it is in one), the cursor in it
para_after:
    mov edi, [cur_blk]
    inc edi
    mov esi, BK_PARA
    mov edx, 1
    call blk_insert
    test rax, rax
    jz .out
    inc dword [cur_blk]
    mov dword [cur_off], 0
    call sel_none
.out:
    ret

do_enter:
    push rbx
    push r12
    push r13
    cmp byte [ed_on], 0
    je .doc
    call cell_commit
    mov eax, 1
    xor edx, edx
    call cell_move
    jmp .out
.doc:
    call cur_kind
    cmp eax, BK_GRID
    jne .not_grid
    call sel_any
    jne .not_grid
    mov eax, 1
    call cell_begin
    jmp .out
.not_grid:
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call sel_delete
    call cur_kind
    cmp eax, BK_GRID
    je .para
    cmp eax, BK_IMAGE
    jne .text
.para:
    call para_after
    jmp .out
.text:
    call cur_ptr
    mov rbx, rax                        ; RBX: the block
    movzx r12d, byte [rbx + BL_KIND]    ; R12D: its kind
    cmp dword [rbx + BL_LEN], 0
    jne .split
    cmp r12d, BK_BULLET                 ; an empty list item: the list ends
    je .unlist
    cmp r12d, BK_NUMBER
    je .unlist
    cmp r12d, BK_PARA                   ; an empty last paragraph in a frame:
    jne .split                          ; out of the frame
    mov edi, [cur_blk]
    call blk_frame
    cmp eax, -1
    je .split
    mov edi, eax
    call blk_end
    dec eax
    cmp eax, [cur_blk]
    jne .split
    mov edi, [cur_blk]
    call blk_frame
    mov edi, eax
    call blk_at
    dec word [rax + BL_KIDS]
    jmp .out
.unlist:
    mov byte [rbx + BL_KIND], BK_PARA
    jmp .out
.split:
    mov r13d, BK_PARA                   ; R13D: the new block's kind
    cmp r12d, BK_BULLET
    je .same
    cmp r12d, BK_NUMBER
    jne .new
.same:
    mov r13d, r12d
.new:
    mov edi, [cur_blk]
    inc edi
    mov esi, r13d
    mov edx, 1
    call blk_insert
    test rax, rax
    jz .out
    mov edi, [cur_blk]                  ; the text after the cursor, into it
    call blk_at
    mov rbx, rax
    mov esi, [cur_off]
    mov ecx, [rbx + BL_LEN]
    sub ecx, esi
    jz .moved
    mov rdx, [rbx + BL_TEXT]
    add rdx, rsi
    mov rcx, [rbx + BL_TEXT]
    mov r8d, [rbx + BL_CAP]
    add rcx, r8
    add rcx, rsi
    mov r8d, [rbx + BL_LEN]
    sub r8d, esi
    mov edi, [cur_blk]
    inc edi
    xor esi, esi
    call text_insert_a
    mov edi, [cur_blk]
    call blk_at
    mov ecx, [cur_off]
    mov [rax + BL_LEN], ecx
.moved:
    inc dword [cur_blk]
    mov dword [cur_off], 0
    mov eax, [cur_blk]
    mov [anc_blk], eax
    mov dword [anc_off], 0
.out:
    pop r13
    pop r12
    pop rbx
    ret

do_backspace:
    push rbx
    cmp byte [ed_on], 0
    je .doc
    mov esi, [ed_off]                   ; in a cell's text
    test esi, esi
    jz .out
    mov rsi, [ed_blk + BL_TEXT]
    mov edx, [ed_off]
    call utf8_prev
    mov ecx, [ed_off]
    mov [ed_off], eax
    call ed_cut
    jmp .out
.doc:
    call sel_any
    je .no_sel
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call sel_delete
    jmp .out
.no_sel:
    call cur_kind
    cmp eax, BK_GRID
    je .clear_cell
    cmp eax, BK_IMAGE
    je .drop_image
    cmp dword [cur_off], 0
    je .at_start
    mov eax, UK_TYPE
    call undo_push
    mov byte [modified], 1
    call cur_ptr
    mov rsi, [rax + BL_TEXT]
    mov edx, [cur_off]
    call utf8_prev
    mov esi, eax
    mov edx, [cur_off]
    sub edx, eax
    mov [cur_off], eax
    mov edi, [cur_blk]
    call text_delete
    call sel_none
    jmp .out
.at_start:
    mov eax, UK_OTHER
    call undo_push
    call cur_ptr
    mov rbx, rax
    movzx eax, byte [rbx + BL_KIND]
    cmp eax, BK_PARA
    je .join
    mov byte [modified], 1
    cmp eax, BK_SLIDE                   ; a frame's title: the frame goes,
    jne .plain                          ; what it held stays
    mov byte [rbx + BL_KIND], BK_H1
    mov word [rbx + BL_KIDS], 0
    jmp .out
.plain:                                 ; a heading or an item: a paragraph
    mov byte [rbx + BL_KIND], BK_PARA
    jmp .out
.join:
    mov eax, [cur_blk]
    test eax, eax
    jz .out
    lea edi, [rax - 1]
    call blk_texty
    jnz .merge
    dec dword [cur_blk]                 ; a grid or an image before it: chosen
    mov dword [cur_off], 0
    call sel_none
    jmp .out
.merge:
    mov byte [modified], 1
    mov edi, [cur_blk]
    dec edi
    call blk_at
    mov ebx, [rax + BL_LEN]
    dec dword [cur_blk]
    mov edi, [cur_blk]
    call blk_merge_next
    mov [cur_off], ebx
    call sel_none
    jmp .out
.clear_cell:
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call cur_ptr
    mov rdi, [rax + BL_DATA]
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    mov esi, eax
    xor ecx, ecx
    xor r8d, r8d
    call cell_set
    jmp .out
.drop_image:
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    mov edi, [cur_blk]
    call blk_drop
    mov eax, [cur_blk]
    test eax, eax
    jz .fixed
    dec dword [cur_blk]
    mov edi, [cur_blk]
    call blk_at
    mov eax, [rax + BL_LEN]
    mov [cur_off], eax
.fixed:
    call cur_fix
    call sel_none
.out:
    pop rbx
    ret

; ed_cut(EAX = from, ECX = to): that part of the cell's text gone
ed_cut:
    mov rdi, [ed_blk + BL_TEXT]
    lea rsi, [rdi + rcx]
    add rdi, rax
    mov edx, ecx
    sub edx, eax
    mov ecx, [ed_blk + BL_LEN]
    sub ecx, [ed_off]
    sub ecx, edx
    rep movsb
    sub [ed_blk + BL_LEN], edx
    ret

do_delete:
    push rbx
    cmp byte [ed_on], 0
    je .doc
    mov eax, [ed_off]
    cmp eax, [ed_blk + BL_LEN]
    jae .out
    mov rsi, [ed_blk + BL_TEXT]
    mov edx, eax
    mov ecx, [ed_blk + BL_LEN]
    call utf8_len_at
    mov ecx, eax
    mov eax, [ed_off]
    call ed_cut
    jmp .out
.doc:
    call sel_any
    jne .backspace                      ; what is chosen: as backspace
    call cur_kind
    cmp eax, BK_GRID
    je .backspace
    cmp eax, BK_IMAGE
    je .backspace
    call cur_ptr
    mov ecx, [rax + BL_LEN]
    cmp [cur_off], ecx
    jb .char
    mov eax, [cur_blk]                  ; at the end: the next joined on
    inc eax
    cmp eax, [nblocks]
    jae .out
    mov edi, eax
    call blk_texty
    jz .out
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    mov edi, [cur_blk]
    call blk_merge_next
    jmp .out
.char:
    mov eax, UK_TYPE
    call undo_push
    mov byte [modified], 1
    call cur_ptr
    mov rsi, [rax + BL_TEXT]
    mov edx, [cur_off]
    call utf8_len_at
    mov edx, eax
    sub edx, [cur_off]
    mov esi, [cur_off]
    mov edi, [cur_blk]
    call text_delete
    jmp .out
.backspace:
    pop rbx
    jmp do_backspace
.out:
    pop rbx
    ret

; --- moving -----------------------------------------------------------------------

; move_left, move_right: a character, or into the block before or after
move_left:
    mov byte [undo_open], 0
    cmp byte [ed_on], 0
    je .doc
    mov rsi, [ed_blk + BL_TEXT]
    mov edx, [ed_off]
    call utf8_prev
    mov [ed_off], eax
    ret
.doc:
    call cur_kind
    cmp eax, BK_GRID
    jne .text
    mov eax, [cur_off]                  ; a cell to the left
    xor edx, edx
    mov ecx, MAXC
    div ecx
    test edx, edx
    jz .before
    dec dword [cur_off]
    ret
.text:
    cmp eax, BK_IMAGE
    je .before
    mov eax, [cur_off]
    test eax, eax
    jz .before
    call cur_ptr
    mov rsi, [rax + BL_TEXT]
    mov edx, [cur_off]
    call utf8_prev
    mov [cur_off], eax
    ret
.before:
    mov eax, [cur_blk]
    test eax, eax
    jz .out
    dec eax
    mov [cur_blk], eax
    mov edi, eax
    call blk_at
    mov ecx, [rax + BL_LEN]
    mov [cur_off], ecx
    cmp byte [rax + BL_KIND], BK_GRID   ; a grid: its last cell
    jne .fix
    mov rax, [rax + BL_DATA]
    mov ecx, [rax + GR_ROWS]
    dec ecx
    imul ecx, ecx, MAXC
    add ecx, [rax + GR_COLS]
    dec ecx
    mov [cur_off], ecx
.fix:
    call cur_fix
.out:
    ret

move_right:
    mov byte [undo_open], 0
    cmp byte [ed_on], 0
    je .doc
    mov rsi, [ed_blk + BL_TEXT]
    mov edx, [ed_off]
    mov ecx, [ed_blk + BL_LEN]
    call utf8_len_at
    mov [ed_off], eax
    ret
.doc:
    call cur_ptr
    movzx ecx, byte [rax + BL_KIND]
    cmp ecx, BK_GRID
    jne .text
    mov rcx, [rax + BL_DATA]            ; a cell to the right
    mov eax, [cur_off]
    xor edx, edx
    mov r8d, MAXC
    div r8d
    inc edx
    cmp edx, [rcx + GR_COLS]
    jae .after
    inc dword [cur_off]
    ret
.text:
    cmp ecx, BK_IMAGE
    je .after
    mov ecx, [rax + BL_LEN]
    cmp [cur_off], ecx
    jae .after
    mov rsi, [rax + BL_TEXT]
    mov edx, [cur_off]
    call utf8_len_at
    mov [cur_off], eax
    ret
.after:
    mov eax, [cur_blk]
    inc eax
    cmp eax, [nblocks]
    jae .out
    mov [cur_blk], eax
    mov dword [cur_off], 0
.out:
    ret

; cursor_xy -> EAX = the cursor's x, EDX = its line (LN_*), 0 if it has
; none. Preserves RBX, RBP, R12-R15.
cursor_xy:
    push rbx
    mov edi, [cur_blk]
    mov esi, [cur_off]
    cmp byte [ed_on], 0
    je .find
    mov edi, EDIT_BLK
    mov esi, [ed_cell]
.find:
    call line_find
    test rax, rax
    jz .none
    mov rbx, rax
    cmp dword [rbx + LN_KIND], LK_TEXT
    jne .box
    mov edi, [cur_blk]
    call blk_at
    mov rdi, rax
    mov esi, [rbx + LN_START]
    mov edx, [cur_off]
    cmp edx, [rbx + LN_END]
    jbe .to
    mov edx, [rbx + LN_END]
.to:
    cmp edx, esi
    jae .measure
    mov edx, esi
.measure:
    mov ecx, [rbx + LN_FONT]
    call measure
    add eax, 32
    sar eax, 6
    add eax, [rbx + LN_X]
    mov rdx, rbx
    pop rbx
    ret
.box:                                   ; a cell, an image: its middle
    mov eax, [rbx + LN_W]
    shr eax, 1
    add eax, [rbx + LN_X0]
    mov rdx, rbx
    pop rbx
    ret
.none:
    xor eax, eax
    xor edx, edx
    pop rbx
    ret

; line_near(RDX = a line, EAX = x, ECX = -1 up or 1 down) -> RAX = the
; nearest line wholly above (or below) it, among those at x, else the
; nearest at all; 0 if there is none. A frame's box is never one.
line_near:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rdx                        ; R12: from
    mov r13d, eax                       ; R13D: x
    mov r14d, ecx                       ; R14D: which way
    xor r15d, r15d                      ; R15: the best so far
    mov rbx, [ln_base]
    mov ebp, [ln_n]
.line:
    test ebp, ebp
    jz .done
    cmp rbx, r12
    je .next
    cmp dword [rbx + LN_KIND], LK_BOX
    jne .candidate
    mov edi, [rbx + LN_BLK]             ; a frame's box: no
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    je .next
.candidate:
    test r14d, r14d
    js .above
    mov eax, [r12 + LN_Y]               ; below: its top under our bottom
    add eax, [r12 + LN_H]
    dec eax
    cmp [rbx + LN_Y], eax
    jl .next
    jmp .compare
.above:
    mov eax, [rbx + LN_Y]               ; above: its bottom over our top
    add eax, [rbx + LN_H]
    dec eax
    cmp eax, [r12 + LN_Y]
    jg .next
.compare:
    test r15, r15
    jz .take
    mov eax, [rbx + LN_Y]               ; nearer up or down wins
    cmp eax, [r15 + LN_Y]
    je .tie
    setl al                             ; AL: 1 if it is higher
    test r14d, r14d
    js .up_cmp
    test al, al                         ; going down: the higher wins
    jnz .take
    jmp .next
.up_cmp:
    test al, al                         ; going up: the lower wins
    jz .take
    jmp .next
.tie:                                   ; on the same row: the one at x
    mov eax, [rbx + LN_X0]
    cmp r13d, eax
    jl .next
    add eax, [rbx + LN_W]
    cmp r13d, eax
    jge .next
.take:
    mov r15, rbx
.next:
    add rbx, LN_SIZE
    dec ebp
    jmp .line
.done:
    mov rax, r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; line_offset(RBX = a text line, EAX = x) -> EAX = the offset nearest x.
; Preserves RBX, RBP, R12-R15.
line_offset:
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax                       ; R12D: x, in 1/64 from the line's start
    sub r12d, [rbx + LN_X]
    shl r12d, 6
    mov edi, [rbx + LN_BLK]
    cmp edi, EDIT_BLK
    jne .doc
    lea rax, [ed_blk]
    jmp .block
.doc:
    call blk_at
.block:
    mov r13, rax                        ; R13: the block
    mov r14d, [rbx + LN_START]          ; R14D: at; R15D: the pen
    xor r15d, r15d
.char:
    cmp r14d, [rbx + LN_END]
    jae .end
    mov rsi, [r13 + BL_TEXT]
    mov edx, r14d
    mov ecx, [rbx + LN_END]
    call utf8_len_at
    push rax
    mov rdi, r13
    mov esi, r14d
    mov edx, eax
    mov ecx, [rbx + LN_FONT]
    call measure                        ; this character's width
    pop rdx
    mov ecx, eax
    shr ecx, 1
    add ecx, r15d
    cmp r12d, ecx                       ; left of its middle: before it
    jl .end
    add r15d, eax
    mov r14d, edx
    jmp .char
.end:
    mov eax, r14d                       ; past the line's end, unless it is the
    cmp eax, [rbx + LN_END]             ; block's: before the space it wraps at
    jb .out
    mov rcx, [r13 + BL_LEN]
    cmp eax, ecx
    jae .out
    test eax, eax
    jz .out
    mov rcx, [r13 + BL_TEXT]
    cmp byte [rcx + rax - 1], ' '
    jne .out
    dec eax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; cursor_to(RAX = a line, EDX = x): the cursor onto that line, nearest x
cursor_to:
    push rbx
    mov rbx, rax
    cmp dword [rbx + LN_KIND], LK_TEXT
    jne .other
    mov eax, edx
    call line_offset
    mov [cur_off], eax
    mov eax, [rbx + LN_BLK]
    mov [cur_blk], eax
    jmp .out
.other:
    mov eax, [rbx + LN_BLK]
    cmp eax, EDIT_BLK
    je .out
    mov [cur_blk], eax
    mov dword [cur_off], 0
    cmp dword [rbx + LN_KIND], LK_CELL
    jne .out
    mov eax, [rbx + LN_CELL]
    mov [cur_off], eax
.out:
    pop rbx
    ret

; move_vert(ECX = -1 up, 1 down) -> CF if there is no line that way
move_vert:
    push rbx
    mov byte [undo_open], 0
    push rcx
    call cursor_xy
    pop rcx
    test rdx, rdx
    jz .none
    cmp dword [goal_x], -1
    jne .goal
    mov [goal_x], eax
.goal:
    mov eax, [goal_x]
    call line_near
    test rax, rax
    jz .none
    mov edx, [goal_x]
    call cursor_to
    clc
    pop rbx
    ret
.none:
    stc
    pop rbx
    ret

; move_home, move_end: the line's start or end
move_home:
    mov byte [undo_open], 0
    cmp byte [ed_on], 0
    je .doc
    mov dword [ed_off], 0
    ret
.doc:
    call cursor_xy
    test rdx, rdx
    jz .out
    cmp dword [rdx + LN_KIND], LK_TEXT
    jne .out
    mov eax, [rdx + LN_START]
    mov [cur_off], eax
.out:
    ret

move_end:
    mov byte [undo_open], 0
    cmp byte [ed_on], 0
    je .doc
    mov eax, [ed_blk + BL_LEN]
    mov [ed_off], eax
    ret
.doc:
    push rbx
    call cursor_xy
    test rdx, rdx
    jz .out
    cmp dword [rdx + LN_KIND], LK_TEXT
    jne .out
    mov rbx, rdx
    mov eax, [rbx + LN_X]               ; far right of it
    add eax, 1 << 20
    call line_offset
    mov [cur_off], eax
.out:
    pop rbx
    ret

; --- what kind, what attributes ----------------------------------------------------

; set_kind(EAX = BK_*): each text block chosen (or the cursor's) that kind;
; one already that kind and alone becomes a paragraph
set_kind:
    push rbx
    push r12
    push r13
    mov r13d, eax
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call sel_range
    mov ebx, eax                        ; EBX .. R12D: the blocks
    mov r12d, ecx
    cmp ebx, r12d                       ; one block already that kind: back to text
    jne .each
    mov edi, ebx
    call blk_at
    movzx ecx, byte [rax + BL_KIND]
    cmp ecx, r13d
    jne .each
    mov r13d, BK_PARA
.each:
    cmp ebx, r12d
    ja .out
    mov edi, ebx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    je .next
    cmp byte [rax + BL_KIND], BK_IMAGE
    je .next
    cmp byte [rax + BL_KIND], BK_SLIDE  ; a frame's title stays one
    je .next
    mov [rax + BL_KIND], r13b
.next:
    inc ebx
    jmp .each
.out:
    pop r13
    pop r12
    pop rbx
    ret

; toggle_attr(EAX = A_*): on what is chosen, on if any of it lacks it, else
; off; with nothing chosen, for what is typed next
toggle_attr:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, eax
    call sel_any
    jne .chosen
    xor [typing_attr], r15d
    jmp .out
.chosen:
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    xor r14d, r14d                      ; R14D: 1 to set it (anything lacks it)
    call .walk
    mov r14d, 2                         ; then set or clear
    call .walk
    xor [typing_attr], r15d
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; .walk: every attribute byte chosen: R14D 0 finds whether one lacks it
; (R14D 1 then); 2 sets (when it was 1) or clears (when it was 0... the
; mode is kept in R13D)
.walk:
    call sel_range
    mov ebx, eax                        ; EBX: the block; EDX, R8D: from and to
    mov r12d, ecx
    mov [tg_from], edx
    mov [tg_to], r8d
    cmp r14d, 2
    jne .blocks
    mov r13d, [tg_set]
.blocks:
    cmp ebx, r12d
    ja .walked
    mov edi, ebx
    call blk_texty
    jz .walk_next
    mov edi, ebx
    call blk_at
    xor ecx, ecx                        ; ECX .. EDX: this block's part
    mov edx, [rax + BL_LEN]
    cmp ebx, [cur_blk]
    je .ends
    cmp ebx, [anc_blk]
    jne .part
.ends:
    call sel_range
    mov r9d, eax
    mov r10d, ecx
    mov edi, ebx
    call blk_at
    xor ecx, ecx
    mov edx, [rax + BL_LEN]
    cmp ebx, r9d
    jne .end_part
    mov ecx, [tg_from]
.end_part:
    cmp ebx, r10d
    jne .part
    mov edx, [tg_to]
.part:
    mov rsi, [rax + BL_TEXT]
    mov edi, [rax + BL_CAP]
    add rsi, rdi
.byte:
    cmp ecx, edx
    jae .walk_next
    test r14d, r14d
    jnz .change
    test [rsi + rcx], r15b
    jnz .byte_next
    mov dword [tg_set], 1
    jmp .byte_next
.change:
    cmp r14d, 2
    jne .byte_next
    test r13d, r13d
    jz .clear
    or [rsi + rcx], r15b
    jmp .byte_next
.clear:
    mov al, r15b
    not al
    and [rsi + rcx], al
.byte_next:
    inc ecx
    jmp .byte
.walk_next:
    inc ebx
    jmp .blocks
.walked:
    test r14d, r14d
    jnz .walk_out
    mov r14d, 1
.walk_out:
    ret

; --- inserting ----------------------------------------------------------------------

; insert_at -> EDI = where a new block goes: after the cursor's block, or
; after the frame it is in when ESI = 1 (a frame cannot go in a frame).
; Preserves RBX, RBP, R12-R15.
insert_at:
    push rsi
    mov edi, [cur_blk]
    test esi, esi
    jz .after
    call blk_frame                      ; inside a frame: after it
    cmp eax, -1
    je .own
    mov edi, eax
    call blk_end
    mov edi, eax
    pop rsi
    ret
.own:
    mov edi, [cur_blk]
    call blk_end                        ; a frame itself: after what it holds
    mov edi, eax
    pop rsi
    ret
.after:
    inc edi
    pop rsi
    ret

; place_block(EAX = BK_*, ESI = 1 if it must be outside frames) -> RAX = the
; new block, the cursor on it; an empty paragraph replaced if the cursor is
; in one; 0 if there is no room
place_block:
    push rbx
    push r12
    mov ebx, eax
    mov r12d, esi
    call cur_ptr
    cmp byte [rax + BL_KIND], BK_PARA   ; an empty paragraph, not in a frame
    jne .insert                         ; (or anywhere, if frames are fine)
    cmp dword [rax + BL_LEN], 0
    jne .insert
    test r12d, r12d
    jz .replace
    mov edi, [cur_blk]
    call blk_frame
    cmp eax, -1
    jne .insert
.replace:
    call cur_ptr
    mov [rax + BL_KIND], bl
    jmp .out
.insert:
    mov esi, r12d
    call insert_at
    mov r12d, edi
    mov esi, ebx
    mov edx, 1
    cmp ebx, BK_SLIDE
    jne .join
    xor edx, edx
.join:
    call blk_insert
    test rax, rax
    jz .out
    mov [cur_blk], r12d
.out:
    mov dword [cur_off], 0
    pop r12
    pop rbx
    ret

; text_after: an empty paragraph after the cursor's block, if none follows
; to type into. Preserves the cursor.
text_after:
    mov edi, [cur_blk]
    call blk_end
    cmp eax, [nblocks]
    jae .add
    mov edi, eax
    call blk_texty
    jnz .out
.add:
    mov edi, [cur_blk]
    call blk_end
    mov edi, eax
    mov esi, BK_PARA
    xor edx, edx
    cmp edi, [cur_blk]                  ; in the cursor's frame, if it is in one
    je .insert
    push rdi
    mov edi, [cur_blk]
    call blk_frame
    pop rdi
    cmp eax, -1
    je .insert
    mov edx, 1
.insert:
    call blk_insert
.out:
    ret

insert_grid:
    push rbx
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call grid_new
    test rax, rax
    jz .out
    mov rbx, rax
    mov eax, BK_GRID
    xor esi, esi
    call place_block
    test rax, rax
    jz .out
    mov [rax + BL_DATA], rbx
    mov edi, [cur_blk]                  ; named "Grid N"
    call grid_name
    call text_after
    call sel_none
.out:
    pop rbx
    ret

; grid_name(EDI = a grid's block, unnamed): "Grid N", N the grids up to
; and with it
grid_name:
    push rbx
    push r12
    mov ebx, edi
    xor r12d, r12d                      ; R12D: grids up to it
    xor ecx, ecx
.count:
    cmp ecx, ebx
    ja .counted
    mov edi, ecx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    jne .count_next
    inc r12d
.count_next:
    inc ecx
    jmp .count
.counted:
    sub rsp, 24
    mov rdi, rsp
    lea rsi, [s_grid_n]
    mov ecx, 5
    rep movsb
    mov eax, r12d
    lea rsi, [rsp + 23]
    mov ecx, 10
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [rsi], dl
    dec rsi
    test eax, eax
    jnz .digit
    inc rsi
.copy:
    mov al, [rsi]
    mov [rdi], al
    inc rdi
    inc rsi
    lea rax, [rsp + 24]
    cmp rsi, rax
    jb .copy
    mov rcx, rdi
    sub rcx, rsp
    mov rdx, rsp
    mov edi, ebx
    xor esi, esi
    xor r8d, r8d
    call text_insert
    add rsp, 24
    pop r12
    pop rbx
    ret

; name_grids: each grid without a name, "Grid N"
name_grids:
    push rbx
    xor ebx, ebx
.block:
    cmp ebx, [nblocks]
    jae .out
    mov edi, ebx
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    jne .next
    cmp dword [rax + BL_LEN], 0
    jne .next
    mov edi, ebx
    call grid_name
.next:
    inc ebx
    jmp .block
.out:
    pop rbx
    ret

insert_frame:
    push rbx
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    cmp dword [view], V_SLIDES          ; on slides: after the slide shown
    jne .here
    call slides_build
    mov edi, [cur_blk]
    call slide_of
    cmp eax, -1
    je .here
    shl eax, 4
    add rax, [sl_base]
    mov edi, [rax + SL_END]
    mov esi, BK_SLIDE
    xor edx, edx
    mov ebx, edi
    call blk_insert
    test rax, rax
    jz .out
    mov [cur_blk], ebx
    mov dword [cur_off], 0
    jmp .placed
.here:
    mov eax, BK_SLIDE
    mov esi, 1
    call place_block
.placed:
    call sel_none
.out:
    pop rbx
    ret

insert_image:
    push rbx
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    mov edi, PIC_W
    mov esi, PIC_H
    call picture
    test rax, rax
    jz .out
    mov rbx, rax
    mov eax, BK_IMAGE
    xor esi, esi
    call place_block
    test rax, rax
    jz .out
    mov [rax + BL_DATA], rbx
    call text_after
    call sel_none
.out:
    pop rbx
    ret

; --- cells --------------------------------------------------------------------------

; cell_rc -> ESI = the cursor's cell's row, EDX = its column, RDI = its grid.
; Preserves RBX, RBP, R12-R15.
cell_rc:
    call cur_ptr
    mov rdi, [rax + BL_DATA]
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    mov esi, eax
    ret

cell_begin:
    push rbx
    mov ebx, eax
    mov eax, [cur_blk]
    mov [ed_blk_index], eax
    mov eax, [cur_off]
    mov [ed_cell], eax
    mov dword [ed_blk + BL_LEN], 0
    test ebx, ebx
    jz .on
    call cell_rc                        ; what is there, to change
    call cell_at
    mov ecx, [rax + CE_LEN]
    cmp ecx, ED_CAP - 1
    jbe .copy
    mov ecx, ED_CAP - 1
.copy:
    mov [ed_blk + BL_LEN], ecx
    mov rsi, [rax + CE_TEXT]
    mov rdi, [ed_blk + BL_TEXT]
    rep movsb
.on:
    mov eax, [ed_blk + BL_LEN]
    mov [ed_off], eax
    mov byte [ed_on], 1
    pop rbx
    ret

cell_commit:
    cmp byte [ed_on], 0
    je .out
    mov byte [ed_on], 0
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    mov edi, [ed_blk_index]
    call blk_at
    mov rdi, [rax + BL_DATA]
    mov eax, [ed_cell]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    mov esi, eax
    mov rcx, [ed_blk + BL_TEXT]
    mov r8d, [ed_blk + BL_LEN]
    call cell_set
.out:
    ret

cell_cancel:
    mov byte [ed_on], 0
    ret

; cell_move(EAX = rows, EDX = columns): the cell that far away; off the
; grid's table on a page or a slide, the block before or after it. In the
; grid view, anywhere in the grid.
cell_move:
    push rbx
    push r12
    push r13
    mov r12d, eax
    mov r13d, edx
    call cur_kind
    cmp eax, BK_GRID
    jne .out
    call cur_ptr
    mov rbx, [rax + BL_DATA]
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    add eax, r12d                       ; EAX, EDX: the row, the column
    add edx, r13d
    mov ecx, MAXR                       ; ECX, R8D: how far it may go
    mov r8d, MAXC
    cmp dword [view], V_GRID
    je .bounds
    mov ecx, [rbx + GR_ROWS]
    mov r8d, [rbx + GR_COLS]
.bounds:
    test edx, edx
    jns .col_low
    xor edx, edx
.col_low:
    cmp edx, r8d
    jb .col_ok
    lea edx, [r8 - 1]
.col_ok:
    test eax, eax
    js .up_out
    cmp eax, ecx
    jae .down_out
    imul eax, eax, MAXC
    add eax, edx
    mov [cur_off], eax
    jmp .out
.up_out:
    cmp dword [view], V_GRID
    je .out
    mov eax, [cur_blk]
    test eax, eax
    jz .out
    dec eax
    mov [cur_blk], eax
    mov edi, eax
    call blk_at
    mov ecx, [rax + BL_LEN]
    mov [cur_off], ecx
    call cur_fix
    jmp .out
.down_out:
    cmp dword [view], V_GRID
    je .out
    mov eax, [cur_blk]
    inc eax
    cmp eax, [nblocks]
    jae .out
    mov [cur_blk], eax
    mov dword [cur_off], 0
.out:
    call sel_none
    pop r13
    pop r12
    pop rbx
    ret

; cell_tab: the next cell to the right; past the last column, the next
; row's first; past the table's last cell on a page, a new row
cell_tab:
    push rbx
    call cur_ptr
    mov rbx, [rax + BL_DATA]
    mov eax, [cur_off]
    xor edx, edx
    mov ecx, MAXC
    div ecx
    inc edx
    mov ecx, MAXC
    cmp dword [view], V_GRID
    je .cols
    mov ecx, [rbx + GR_COLS]
.cols:
    cmp edx, ecx
    jb .there
    xor edx, edx
    inc eax
    cmp eax, MAXR
    jae .out
    cmp dword [view], V_GRID
    je .there
    cmp eax, [rbx + GR_ROWS]
    jb .there
    push rax
    push rdx
    mov eax, UK_OTHER
    call undo_push
    pop rdx
    pop rax
    inc dword [rbx + GR_ROWS]
    mov byte [modified], 1
.there:
    imul eax, eax, MAXC
    add eax, edx
    mov [cur_off], eax
.out:
    call sel_none
    pop rbx
    ret

; grid_add(EAX = 1 for a row, 0 for a column): the cursor's grid's table
; one larger
grid_add:
    push rbx
    mov ebx, eax
    call cur_kind
    cmp eax, BK_GRID
    jne .out
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call cur_ptr
    mov rax, [rax + BL_DATA]
    test ebx, ebx
    jz .col
    cmp dword [rax + GR_ROWS], MAXR
    jae .out
    inc dword [rax + GR_ROWS]
    jmp .out
.col:
    cmp dword [rax + GR_COLS], MAXC
    jae .out
    inc dword [rax + GR_COLS]
.out:
    pop rbx
    ret

; --- undo -----------------------------------------------------------------------------

; a stack of snapshots: US_BASE its memory, US_TOP the next free byte,
; US_N how many, US_OFF[UNDO_MAX] where each starts (and its length)
US_BASE         equ 0
US_TOP          equ 8
US_N            equ 16
US_ENT          equ 24                  ; UNDO_MAX of (offset, length) dwords
US_SIZE         equ US_ENT + UNDO_MAX * 8

; us_push(RDI = a stack): the document, as it is now, onto it; the oldest
; half dropped if there is no room
us_push:
    push rbx
    push r12
    mov rbx, rdi
.again:
    cmp dword [rbx + US_N], UNDO_MAX
    jae .drop
    mov rdi, [rbx + US_TOP]             ; written at the top
    mov rsi, [rbx + US_BASE]
    add rsi, UNDO_BYTES
    sub rsi, rdi
    call snapshot
    cmp rax, -1
    jne .kept
    cmp dword [rbx + US_N], 0           ; it does not fit even alone: not kept
    je .out
.drop:
    call us_halve
    jmp .again
.kept:
    mov ecx, [rbx + US_N]
    mov rdx, [rbx + US_TOP]
    sub rdx, [rbx + US_BASE]
    mov [rbx + US_ENT + rcx * 8], edx
    mov [rbx + US_ENT + rcx * 8 + 4], eax
    add [rbx + US_TOP], rax
    inc dword [rbx + US_N]
.out:
    pop r12
    pop rbx
    ret

; us_halve (RBX = a stack): its older half gone, the rest moved down
us_halve:
    push r12
    mov r12d, [rbx + US_N]
    shr r12d, 1                         ; R12D: how many go
    test r12d, r12d
    jnz .some
    inc r12d
.some:
    mov eax, [rbx + US_ENT + r12 * 8]   ; the first kept starts here
    cmp r12d, [rbx + US_N]
    jb .move
    mov rax, [rbx + US_TOP]             ; (all of them go)
    sub rax, [rbx + US_BASE]
.move:
    mov rsi, [rbx + US_BASE]
    add rsi, rax
    mov rdi, [rbx + US_BASE]
    mov rcx, [rbx + US_TOP]
    sub rcx, rsi
    rep movsb
    mov [rbx + US_TOP], rdi
    xor ecx, ecx                        ; and their entries
.ent:
    lea edx, [rcx + r12]
    cmp edx, [rbx + US_N]
    jae .ents
    mov r8d, [rbx + US_ENT + rdx * 8]
    sub r8d, eax
    mov [rbx + US_ENT + rcx * 8], r8d
    mov r8d, [rbx + US_ENT + rdx * 8 + 4]
    mov [rbx + US_ENT + rcx * 8 + 4], r8d
    inc ecx
    jmp .ent
.ents:
    sub [rbx + US_N], r12d
    pop r12
    ret

; us_pop(RDI = a stack) -> CF if it is empty; else the document read back
; from its newest
us_pop:
    cmp dword [rdi + US_N], 0
    je .empty
    push rbx
    mov rbx, rdi
    dec dword [rbx + US_N]
    mov ecx, [rbx + US_N]
    mov esi, [rbx + US_ENT + rcx * 8]
    add rsi, [rbx + US_BASE]
    mov [rbx + US_TOP], rsi
    mov ecx, [rbx + US_ENT + rcx * 8 + 4]
    call restore
    pop rbx
    clc
    ret
.empty:
    stc
    ret

; snapshot(RDI = to, RSI = room) -> RAX = bytes, or -1: the whole document,
; the cursor and the view with it
snapshot:
    push rdi
    push rsi
    mov eax, [view]
    mov [ser_v_view], al
    mov eax, [cur_blk]
    mov [ser_v_block], eax
    mov eax, [cur_off]
    mov [ser_v_off], eax
    mov byte [ser_view], 1
    pop rsi
    pop rdi
    xor edx, edx
    xor ecx, ecx
    mov r8d, [nblocks]
    dec r8d
    mov r9d, 0x7FFFFFFF
    call ser_doc
    mov byte [ser_view], 0
    ret

; restore(RSI = a snapshot, ECX = its bytes): the document it holds, the
; cursor where it was (the view left as it is)
restore:
    push rsi
    push rcx
    call doc_clear
    pop rcx
    pop rsi
    xor edi, edi
    call des_doc
    call doc_fixup
    cmp byte [des_view], 0
    je .fix
    mov eax, [des_v_block]
    mov [cur_blk], eax
    mov eax, [des_v_off]
    mov [cur_off], eax
.fix:
    call cur_fix
    call sel_none
    mov byte [ed_on], 0
    mov byte [thumbs_all], 1
    inc dword [doc_gen]
    ret

undo_push:
    cmp eax, UK_TYPE                    ; typing goes on: the change already kept
    jne .push
    cmp byte [undo_open], 0
    je .open
    mov ecx, [cur_blk]
    cmp ecx, [undo_blk]
    je .out
.open:
    mov byte [undo_open], 1
    mov ecx, [cur_blk]
    mov [undo_blk], ecx
    jmp .keep
.push:
    mov byte [undo_open], 0
    mov byte [thumbs_all], 1
.keep:
    inc dword [doc_gen]
    lea rdi, [undo_stack]
    call us_push
    mov dword [redo_stack + US_N], 0    ; nothing to redo after a change
    mov rax, [redo_stack + US_BASE]
    mov [redo_stack + US_TOP], rax
    ret
.out:
    inc dword [doc_gen]
    ret

undo:
    cmp byte [ed_on], 0
    je .doc
    mov byte [ed_on], 0                 ; typing into a cell: that, undone
    ret
.doc:
    mov byte [undo_open], 0
    cmp dword [undo_stack + US_N], 0
    je .none
    lea rdi, [redo_stack]
    call us_push
    lea rdi, [undo_stack]
    call us_pop
    mov byte [modified], 1
    clc
    ret
.none:
    stc
    ret

redo:
    mov byte [undo_open], 0
    cmp dword [redo_stack + US_N], 0
    je .none
    lea rdi, [undo_stack]
    call us_push
    lea rdi, [redo_stack]
    call us_pop
    mov byte [modified], 1
    clc
    ret
.none:
    stc
    ret

; --- the clipboard ------------------------------------------------------------------------

copy:
    cmp byte [ed_on], 0
    jne .out
    call sel_any
    jne .chosen
    call cur_kind
    cmp eax, BK_GRID
    je .cell
    cmp eax, BK_IMAGE
    jne .out
    mov edx, [cur_blk]                  ; an image: it
    xor ecx, ecx
    mov r8d, edx
    xor r9d, r9d
    jmp .write
.cell:                                  ; a cell: what was typed in it, as text
    call cell_rc
    call cell_at
    mov rbx, rax
    mov rdi, [clip_base]
    mov rsi, CLIP_BYTES
    mov rdx, [rbx + CE_TEXT]
    mov ecx, [rbx + CE_LEN]
    call clip_text_doc
    jmp .kept
.chosen:
    call sel_range
    xchg eax, edx                       ; EDX, ECX: from; R8D, R9D: to
    xchg eax, ecx
    mov r9d, r8d
    mov r8d, eax
.write:
    mov rdi, [clip_base]
    mov rsi, CLIP_BYTES
    call ser_doc
.kept:
    cmp rax, -1
    je .out
    mov [clip_len], rax
    lea rsi, [s_copied]
    call status_msg
.out:
    ret

; clip_text_doc(RDI = to, RSI = room, RDX = text, ECX = bytes) -> RAX =
; bytes: a piece of document of one paragraph holding that text
clip_text_doc:
    push rbx
    push r12
    mov [sw_p], rdi
    mov [sw_start], rdi
    add rsi, rdi
    mov [sw_end], rsi
    mov byte [sw_over], 0
    mov rbx, rdx
    mov r12d, ecx
    lea rsi, [axdc_head]
    mov ecx, 8
    call sw_bytes
    mov al, REC_TEXT
    call sw_open
    push rax
    xor eax, eax
    call sw_byte                        ; a paragraph,
    call sw_byte                        ; to the left,
    call sw_var                         ; holding nothing
    mov eax, r12d
    call sw_var
    mov rsi, rbx
    mov ecx, r12d
    call sw_bytes
    xor eax, eax                        ; no runs: plain
    call sw_var
    pop rax
    call sw_close
    mov al, REC_END
    call sw_byte
    xor eax, eax
    call sw_byte
    mov rax, [sw_p]
    sub rax, [sw_start]
    pop r12
    pop rbx
    ret

; clip_text -> RSI = the clipboard's first text, ECX = its bytes (0 if it
; has none)
clip_text:
    mov rsi, [clip_base]
    mov [sr_p], rsi
    add rsi, [clip_len]
    mov [sr_end], rsi
    xor ecx, ecx
    mov rcx, 8
    call sr_take
    jc .none
.record:
    call sr_byte
    jc .none
    test eax, eax
    jz .none
    push rax
    call sr_var
    pop rdx
    jc .none
    mov rcx, rax
    cmp edx, REC_TEXT
    je .text
    call sr_take
    jc .none
    jmp .record
.text:
    call sr_byte                        ; kind, align, kids, then the text
    call sr_byte
    call sr_var
    call sr_var
    jc .none
    mov rcx, rax
    call sr_take
    jc .none
    ret
.none:
    xor ecx, ecx
    ret

cut:
    call sel_any
    je .out
    call copy
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call sel_delete
.out:
    ret

paste:
    push rbx
    push r12
    push r13
    push r14
    cmp qword [clip_len], 0
    je .out
    cmp byte [ed_on], 0
    je .doc
    call clip_text                      ; into a cell's text
.ed_char:
    test ecx, ecx
    jz .out
    movzx eax, byte [rsi]
    push rsi
    push rcx
    call insert_char
    pop rcx
    pop rsi
    inc rsi
    dec ecx
    jmp .ed_char
.doc:
    call cur_kind
    cmp eax, BK_GRID
    jne .text
    call sel_any
    jne .text
    mov eax, UK_OTHER                   ; into a cell: its first text
    call undo_push
    mov byte [modified], 1
    call clip_text
    mov rbx, rsi
    mov r12d, ecx
    call cell_rc
    mov rcx, rbx
    mov r8d, r12d
    call cell_set
    jmp .out
.text:
    mov eax, UK_OTHER
    call undo_push
    mov byte [modified], 1
    call sel_delete
    call cur_kind
    cmp eax, BK_GRID
    je .para
    cmp eax, BK_IMAGE
    jne .split
.para:
    call para_after
.split:
    mov edi, [cur_blk]                  ; the block cut in two at the cursor
    call blk_at
    movzx esi, byte [rax + BL_KIND]
    cmp esi, BK_SLIDE
    jne .kind
    mov esi, BK_PARA
.kind:
    mov edi, [cur_blk]
    inc edi
    mov edx, 1
    call blk_insert
    test rax, rax
    jz .out
    mov edi, [cur_blk]
    call blk_at
    mov rbx, rax
    mov esi, [cur_off]
    mov r8d, [rbx + BL_LEN]
    sub r8d, esi
    jz .halves
    mov rdx, [rbx + BL_TEXT]
    add rdx, rsi
    mov rcx, [rbx + BL_TEXT]
    mov eax, [rbx + BL_CAP]
    add rcx, rax
    add rcx, rsi
    mov edi, [cur_blk]
    inc edi
    xor esi, esi
    call text_insert_a
    mov edi, [cur_blk]
    call blk_at
    mov ecx, [cur_off]
    mov [rax + BL_LEN], ecx
.halves:
    mov rsi, [clip_base]                ; the pieces between the halves
    mov rcx, [clip_len]
    mov edi, [cur_blk]
    inc edi
    call des_doc
    test eax, eax
    jle .rejoin_only
    mov r12d, eax                       ; R12D: how many
    mov r13d, [cur_blk]                 ; R13D: the first half
    lea edi, [r13 + 1]                  ; the first piece, text: onto the first half
    call blk_texty
    jz .last_piece
    lea edi, [r13 + 1]
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    je .last_piece
    mov edi, r13d                       ; the half empty: it takes the piece's kind
    call blk_at
    cmp dword [rax + BL_LEN], 0
    jne .merge_first
    mov rcx, rax
    lea edi, [r13 + 1]
    call blk_at
    mov dl, [rax + BL_KIND]
    mov [rcx + BL_KIND], dl
.merge_first:
    mov edi, r13d
    call blk_merge_next
    dec r12d
.last_piece:
    lea r14d, [r13 + r12 + 1]           ; R14D: the second half
    mov edi, r14d
    dec edi
    call blk_texty
    jz .after_last
    lea edi, [r14 - 1]
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    je .after_last
    mov ebx, [rax + BL_LEN]
    lea edi, [r14 - 1]
    mov [cur_blk], edi
    mov [cur_off], ebx
    call blk_merge_next
    jmp .done
.after_last:                            ; (a grid or an image last: the second
    mov [cur_blk], r14d                 ; half stays, the cursor at its start)
    mov dword [cur_off], 0
    jmp .done
.rejoin_only:
    mov edi, [cur_blk]
    call blk_at
    mov ebx, [rax + BL_LEN]
    mov edi, [cur_blk]
    call blk_merge_next
    mov [cur_off], ebx
.done:
    call cur_fix
    call sel_none
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
s_grid_n:       db 'Grid '
s_copied:       db 'Copied', 0
axdc_head:      db 'AXDC', AXDC_VERSION, 0, 0, 0

section .bss
alignb 8
undo_stack:     resb US_SIZE
redo_stack:     resb US_SIZE
clip_base:      resq 1
clip_len:       resq 1
ed_blk:         resb BL_SIZE
cur_blk:        resd 1
cur_off:        resd 1
anc_blk:        resd 1
anc_off:        resd 1
goal_x:         resd 1
typing_attr:    resd 1
ed_blk_index:   resd 1
ed_cell:        resd 1
ed_off:         resd 1
undo_blk:       resd 1
doc_gen:        resd 1
tg_from:        resd 1
tg_to:          resd 1
tg_set:         resd 1
ed_on:          resb 1
modified:       resb 1
undo_open:      resb 1
ic_char:        resb 1

section .text
