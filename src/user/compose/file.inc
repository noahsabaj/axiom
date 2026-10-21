; =============================================================================
;  compose/file.inc - the document as bytes: its own file format (AXDC,
;  docs/COMPOSE.md), plain text and CSV
;
;  "AXDC", a version (u16, 1) and flags (u16, 0), then records: a tag byte,
;  the payload's length (LEB128), the payload. A reader skips the tags it
;  does not know. Numbers in payloads are LEB128 too.
;    REC_TEXT  kind, align, kids, the text, its runs (length, attributes)
;    REC_GRID  flags, rows, columns, the name, the cells that hold anything
;              (row, column, what was typed)
;    REC_IMAGE width, height, encoding (0: R,G,B a pixel, a row at a time),
;              the caption, the pixels
;    REC_VIEW  where the cursor was: the view, the block, the offset
;    REC_END   last
;  Values are not saved: formulas are worked out again as it is read.
;
;    ser_doc(RDI = to, RSI = room, EDX = first block, ECX = its offset, R8D
;      = last block, R9D = the offset it ends at; ser_view: 1 for a
;      REC_VIEW) -> RAX = the bytes written, or -1 if they did not fit. The
;      first and last blocks' text only from and to those offsets; a frame's
;      blocks only those inside the range.
;    des_doc(RSI = bytes, RCX = how many, EDI = the index to insert at) ->
;      EAX = the blocks inserted, or DE_* (< 0). des_view: 1 if a REC_VIEW
;      was read (des_v_*). Inserted inside a frame, they join it, and a
;      frame among them is a heading.
;    doc_fixup: frames that reach past the end or over another cut short;
;      at least one block
;    text_import(RSI = bytes, RCX = how many) -> EAX = blocks: each line a
;      block ("# " a heading, "- " a bullet, "1. " numbered, a line of
;      tabs or a run of "|" a grid row), appended
;    csv_import(RSI, RCX) -> EAX = 1 (a grid) or DE_*: appended
;    text_export(RDI = to, RSI = room) -> RAX = bytes, or -1: the same
;      shapes text_import reads; a grid's cells as values, tab between
;    csv_export(RDI, RSI, EDX = a grid's block) -> RAX = bytes, or -1:
;      what was typed in each cell, quoted where it must be
; =============================================================================

REC_END         equ 0
REC_TEXT        equ 1
REC_GRID        equ 2
REC_IMAGE       equ 3
REC_VIEW        equ 0x10
AXDC_VERSION    equ 1

DE_FORMAT       equ -1                  ; not one, or cut short
DE_NEWER        equ -2                  ; a version this does not read
DE_MEMORY       equ -3

section .text

; --- writing -----------------------------------------------------------------

; sw_byte(AL): at sw_p, unless it is full (sw_over). Preserves all.
sw_byte:
    push rcx
    mov rcx, [sw_p]
    cmp rcx, [sw_end]
    jae .over
    mov [rcx], al
    inc rcx
    mov [sw_p], rcx
    pop rcx
    ret
.over:
    mov byte [sw_over], 1
    pop rcx
    ret

; sw_var(RAX): LEB128. Preserves all.
sw_var:
    push rax
    push rdx
    mov rdx, rax
.more:
    mov eax, edx
    and eax, 0x7F
    shr rdx, 7
    jz .last
    or eax, 0x80
    call sw_byte
    jmp .more
.last:
    call sw_byte
    pop rdx
    pop rax
    ret

; sw_bytes(RSI, ECX). Preserves all but RSI, RCX.
sw_bytes:
    push rax
.byte:
    test ecx, ecx
    jz .out
    mov al, [rsi]
    call sw_byte
    inc rsi
    dec ecx
    jmp .byte
.out:
    pop rax
    ret

; sw_open(AL = a tag) -> RAX = where its payload starts (5 bytes kept for
; its length); sw_close(RAX = that): the length written there, the payload
; moved down to it
sw_open:
    call sw_byte
    mov rax, [sw_p]
    push rax
    xor eax, eax
    call sw_byte
    call sw_byte
    call sw_byte
    call sw_byte
    call sw_byte
    pop rax
    ret

sw_close:
    push rbx
    push r12
    cmp byte [sw_over], 0
    jne .out
    mov rbx, rax                        ; RBX: the 5 bytes; R12: the payload's length
    mov r12, [sw_p]
    sub r12, rbx
    sub r12, 5
    mov rcx, rbx                        ; the length, LEB128, at RBX
    mov rax, r12
.digit:
    mov edx, eax
    and edx, 0x7F
    shr rax, 7
    jz .last
    or edx, 0x80
    mov [rcx], dl
    inc rcx
    jmp .digit
.last:
    mov [rcx], dl
    inc rcx
    lea rsi, [rbx + 5]                  ; the payload after it
    mov rdi, rcx
    mov rax, rcx
    mov rcx, r12
    rep movsb
    mov [sw_p], rdi
.out:
    pop r12
    pop rbx
    ret

ser_doc:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov [sw_p], rdi
    mov [sw_start], rdi
    add rsi, rdi
    mov [sw_end], rsi
    mov byte [sw_over], 0
    mov r12d, edx                       ; R12D, R13D: from
    mov r13d, ecx
    mov r14d, r8d                       ; R14D, R15D: to
    mov r15d, r9d
    mov al, 'A'
    call sw_byte
    mov al, 'X'
    call sw_byte
    mov al, 'D'
    call sw_byte
    mov al, 'C'
    call sw_byte
    mov al, AXDC_VERSION
    call sw_byte
    xor eax, eax
    call sw_byte
    call sw_byte
    call sw_byte
    mov ebx, r12d                       ; EBX: the block
.block:
    cmp ebx, r14d
    ja .view
    cmp ebx, [nblocks]
    jae .view
    mov edi, ebx
    call blk_at
    mov rbp, rax                        ; RBP: it
    xor ecx, ecx                        ; ECX, EDX: its text, from and to
    mov edx, [rbp + BL_LEN]
    cmp ebx, r12d
    jne .from_set
    mov ecx, r13d
.from_set:
    cmp ebx, r14d
    jne .to_set
    cmp edx, r15d
    jbe .to_set
    mov edx, r15d
.to_set:
    cmp ecx, edx
    jbe .range_ok
    mov ecx, edx
.range_ok:
    movzx eax, byte [rbp + BL_KIND]
    cmp eax, BK_GRID
    je .grid
    cmp eax, BK_IMAGE
    je .image
    push rcx
    push rdx
    mov al, REC_TEXT
    call sw_open
    push rax
    mov al, [rbp + BL_KIND]
    call sw_byte
    mov al, [rbp + BL_ALIGN]
    call sw_byte
    xor eax, eax                        ; a frame's blocks, those in the range
    cmp byte [rbp + BL_KIND], BK_SLIDE
    jne .kids
    movzx eax, word [rbp + BL_KIDS]
    mov ecx, r14d
    sub ecx, ebx
    cmp eax, ecx
    jbe .kids
    mov eax, ecx
.kids:
    call sw_var
    pop rax
    pop rdx
    pop rcx
    push rax
    call sw_text
    pop rax
    call sw_close
    jmp .next
.grid:
    mov rdi, rbp
    call sw_grid
    jmp .next
.image:
    mov rdi, rbp
    call sw_image
.next:
    inc ebx
    jmp .block
.view:
    cmp byte [ser_view], 0
    je .end
    mov al, REC_VIEW
    call sw_open
    push rax
    mov al, [ser_v_view]
    call sw_byte
    mov eax, [ser_v_block]
    call sw_var
    mov eax, [ser_v_off]
    call sw_var
    pop rax
    call sw_close
.end:
    mov al, REC_END
    call sw_byte
    xor eax, eax
    call sw_byte
    mov rax, -1
    cmp byte [sw_over], 0
    jne .out
    mov rax, [sw_p]
    sub rax, [sw_start]
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sw_text(RBP = a block, ECX = from, EDX = to): its text there, and its
; runs of attributes. Preserves RBX, RBP, R12-R15.
sw_text:
    push rbx
    push r12
    push r13
    mov r12d, ecx
    mov r13d, edx
    mov eax, edx
    sub eax, ecx
    call sw_var
    mov rsi, [rbp + BL_TEXT]
    add rsi, r12
    mov ecx, r13d
    sub ecx, r12d
    call sw_bytes
    mov rbx, [rbp + BL_TEXT]            ; RBX: the attributes
    mov eax, [rbp + BL_CAP]
    add rbx, rax
    xor eax, eax                        ; the runs: how many, first
    mov ecx, r12d
.count:
    cmp ecx, r13d
    jae .counted
    inc eax
    mov dl, [rbx + rcx]
.same:
    inc ecx
    cmp ecx, r13d
    jae .counted
    cmp dl, [rbx + rcx]
    je .same
    jmp .count
.counted:
    call sw_var
    mov ecx, r12d
.run:
    cmp ecx, r13d
    jae .out
    mov edx, ecx
    mov r8b, [rbx + rcx]
.run_same:
    inc ecx
    cmp ecx, r13d
    jae .run_end
    cmp r8b, [rbx + rcx]
    je .run_same
.run_end:
    mov eax, ecx
    sub eax, edx
    call sw_var
    mov al, r8b
    call sw_byte
    jmp .run
.out:
    pop r13
    pop r12
    pop rbx
    ret

; sw_grid(RDI = a grid's block). Preserves RBX, RBP, R12-R15.
sw_grid:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov rbp, rdi
    mov rbx, [rbp + BL_DATA]            ; RBX: the grid
    mov al, REC_GRID
    call sw_open
    push rax
    mov al, [rbx + GR_FLAGS]
    call sw_byte
    mov eax, [rbx + GR_ROWS]
    call sw_var
    mov eax, [rbx + GR_COLS]
    call sw_var
    mov eax, [rbp + BL_LEN]             ; its name
    call sw_var
    mov rsi, [rbp + BL_TEXT]
    mov ecx, [rbp + BL_LEN]
    call sw_bytes
    xor r14d, r14d                      ; R14D: cells holding anything
    lea rsi, [rbx + GR_CELLS]
    mov ecx, MAXR * MAXC
.count:
    cmp dword [rsi + CE_LEN], 0
    je .count_next
    inc r14d
.count_next:
    add rsi, CE_SIZE
    dec ecx
    jnz .count
    mov eax, r14d
    call sw_var
    xor r12d, r12d                      ; R12D: the row; R13D: the column
.row:
    xor r13d, r13d
.col:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call cell_at
    mov ecx, [rax + CE_LEN]
    test ecx, ecx
    jz .col_next
    push rax
    mov eax, r12d
    call sw_var
    mov eax, r13d
    call sw_var
    pop rax
    mov rsi, [rax + CE_TEXT]
    mov eax, ecx
    call sw_var
    call sw_bytes
.col_next:
    inc r13d
    cmp r13d, MAXC
    jb .col
    inc r12d
    cmp r12d, MAXR
    jb .row
    pop rax
    call sw_close
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sw_image(RDI = an image's block). Preserves RBX, RBP, R12-R15.
sw_image:
    push rbx
    push rbp
    push r12
    mov rbp, rdi
    mov rbx, [rbp + BL_DATA]
    mov al, REC_IMAGE
    call sw_open
    push rax
    mov eax, [rbx + IM_W]
    call sw_var
    mov eax, [rbx + IM_H]
    call sw_var
    xor eax, eax                        ; R,G,B
    call sw_byte
    mov eax, [rbp + BL_LEN]
    call sw_var
    mov rsi, [rbp + BL_TEXT]
    mov ecx, [rbp + BL_LEN]
    call sw_bytes
    mov r12d, [rbx + IM_W]
    imul r12d, [rbx + IM_H]
    lea rsi, [rbx + IM_PX]
.pixel:
    test r12d, r12d
    jz .done
    mov al, [rsi + 2]
    call sw_byte
    mov al, [rsi + 1]
    call sw_byte
    mov al, [rsi]
    call sw_byte
    add rsi, 4
    dec r12d
    jmp .pixel
.done:
    pop rax
    call sw_close
    pop r12
    pop rbp
    pop rbx
    ret

; --- reading -----------------------------------------------------------------

; sr_byte -> AL; CF past the end. Preserves all but RAX.
sr_byte:
    mov rax, [sr_p]
    cmp rax, [sr_end]
    jae .end
    inc qword [sr_p]
    movzx eax, byte [rax]
    clc
    ret
.end:
    stc
    ret

; sr_var -> RAX; CF past the end or longer than 5 bytes. Preserves all but
; RAX.
sr_var:
    push rcx
    push rdx
    xor edx, edx
    xor ecx, ecx
.byte:
    call sr_byte
    jc .out
    push rax
    and eax, 0x7F
    shl rax, cl
    or rdx, rax
    pop rax
    add ecx, 7
    test al, 0x80
    jz .done
    cmp ecx, 35
    jb .byte
    stc
    jmp .out
.done:
    mov rax, rdx
    clc
.out:
    pop rdx
    pop rcx
    ret

; sr_take(RCX = bytes) -> RSI = where they are; CF if there are not that
; many. Preserves all but RSI.
sr_take:
    push rax
    mov rsi, [sr_p]
    mov rax, [sr_end]
    sub rax, rsi
    cmp rcx, rax
    ja .short
    add [sr_p], rcx
    pop rax
    clc
    ret
.short:
    pop rax
    stc
    ret

des_doc:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 8
    mov [sr_p], rsi
    add rcx, rsi
    mov [sr_end], rcx
    mov r12d, edi                       ; R12D: where the next block goes
    mov r13d, edi                       ; R13D: where they began
    mov byte [des_view], 0
    mov ecx, 8
    call sr_take
    jc .format
    cmp dword [rsi], 'AXDC'
    jne .format
    cmp word [rsi + 4], AXDC_VERSION
    ja .newer
    mov edi, r13d                       ; inside a frame: [rsp] = it
    call blk_frame
    mov [rsp], eax
    cmp eax, -1
    jne .record
    lea edi, [r13 - 1]                  ; or just after one's last block
    test edi, edi
    js .record
    call blk_frame
    cmp eax, -1
    je .empty_frame
    mov [rsp], eax                      ; (the join's rule: blk_insert's)
    jmp .record
.empty_frame:
    lea edi, [r13 - 1]
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .record
    cmp word [rax + BL_KIDS], 0
    jne .record
    lea eax, [r13 - 1]
    mov [rsp], eax
.record:
    call sr_byte
    jc .format
    mov ebx, eax                        ; EBX: the tag
    call sr_var
    jc .format
    mov rcx, rax
    call sr_take
    jc .format
    mov rbp, [sr_end]                   ; read inside the payload alone
    mov r14, [sr_p]                     ; R14: what follows it
    lea rax, [rsi + rcx]
    mov [sr_end], rax
    mov [sr_p], rsi
    cmp ebx, REC_END
    je .end
    cmp ebx, REC_TEXT
    je .text
    cmp ebx, REC_GRID
    je .grid
    cmp ebx, REC_IMAGE
    je .image
    cmp ebx, REC_VIEW
    je .view
    jmp .next                           ; one it does not know
.text:
    call sr_byte
    jc .format_in
    mov r15d, eax                       ; R15D: the kind
    cmp r15d, BK_GRID
    je .format_in
    cmp r15d, BK_IMAGE
    je .format_in
    cmp r15d, BK_COUNT
    jae .format_in
    cmp dword [rsp], -1                 ; no frame in a frame: a heading
    je .text_kind
    cmp r15d, BK_SLIDE
    jne .text_kind
    mov r15d, BK_H1
.text_kind:
    mov edi, r12d
    mov esi, r15d
    call blk_insert_raw
    test rax, rax
    jz .memory_in
    mov r15, rax                        ; R15: the block
    call sr_byte
    jc .format_in
    cmp eax, AL_RIGHT
    jbe .align
    xor eax, eax
.align:
    mov [r15 + BL_ALIGN], al
    call sr_var
    jc .format_in
    cmp byte [r15 + BL_KIND], BK_SLIDE
    jne .no_kids
    cmp eax, 0xFFFF
    jbe .kids
    mov eax, 0xFFFF
.kids:
    mov [r15 + BL_KIDS], ax
.no_kids:
    mov rdi, r15
    call sr_text
    jc .format_in
    jmp .added
.grid:
    mov edi, r12d
    mov esi, BK_GRID
    call blk_insert_raw
    test rax, rax
    jz .memory_in
    mov r15, rax
    call grid_new
    test rax, rax
    jz .memory_in
    mov [r15 + BL_DATA], rax
    mov rdi, r15
    call sr_grid
    jc .format_in
    jmp .added
.image:
    mov edi, r12d
    mov esi, BK_IMAGE
    call blk_insert_raw
    test rax, rax
    jz .memory_in
    mov rdi, rax
    call sr_image
    jc .format_in
    test eax, eax
    js .memory_in
.added:
    inc r12d
    cmp dword [rsp], -1                 ; inside a frame: it holds this too
    je .next
    mov edi, [rsp]
    call blk_at
    inc word [rax + BL_KIDS]
    jmp .next
.view:
    call sr_byte
    jc .format_in
    mov [des_v_view], al
    call sr_var
    jc .format_in
    mov [des_v_block], eax
    call sr_var
    jc .format_in
    mov [des_v_off], eax
    mov byte [des_view], 1
.next:
    mov [sr_end], rbp
    mov [sr_p], r14
    jmp .record
.end:
    mov eax, r12d
    sub eax, r13d
    jmp .out
.format_in:
    mov [sr_end], rbp
.format:
    mov eax, DE_FORMAT
    jmp .out
.memory_in:
    mov [sr_end], rbp
    mov eax, DE_MEMORY
    jmp .out
.newer:
    mov eax, DE_NEWER
.out:
    add rsp, 8
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sr_text(RDI = a block, empty) -> CF if it cannot be read: its text, and
; its attributes from the runs. Preserves RBX, RBP, R12-R15.
sr_text:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call sr_var
    jc .out
    mov r12, rax                        ; R12: the text's bytes
    cmp rax, 1 << 20
    ja .bad
    mov rcx, rax
    call sr_take
    jc .out
    mov r13, rsi
    mov rdi, rbx
    mov esi, r12d
    call blk_reserve
    jc .out
    mov rdi, [rbx + BL_TEXT]
    mov rsi, r13
    mov rcx, r12
    rep movsb
    mov [rbx + BL_LEN], r12d
    call sr_var                         ; the runs
    jc .out
    mov r13, rax
    mov rdi, [rbx + BL_TEXT]            ; RDI: the attributes; R12: left
    mov eax, [rbx + BL_CAP]
    add rdi, rax
.run:
    test r13, r13
    jz .rest
    call sr_var
    jc .out
    mov rcx, rax
    call sr_byte
    jc .out
    and eax, A_MASK
    cmp rcx, r12
    jbe .fill
    mov rcx, r12
.fill:
    sub r12, rcx
    rep stosb
    dec r13
    jmp .run
.rest:
    mov rcx, r12                        ; any the runs left out: plain
    xor eax, eax
    rep stosb
    clc
    jmp .out
.bad:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; sr_grid(RDI = a grid's block, with its grid) -> CF if it cannot be read.
; Preserves RBX, RBP, R12-R15.
sr_grid:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    mov rbp, rdi
    mov rbx, [rbp + BL_DATA]
    call sr_byte
    jc .out
    and eax, GF_HEADER
    mov [rbx + GR_FLAGS], eax
    call sr_var
    jc .out
    call .clamp_rows
    mov [rbx + GR_ROWS], eax
    call sr_var
    jc .out
    call .clamp_cols
    mov [rbx + GR_COLS], eax
    call sr_var                         ; its name
    jc .out
    mov r12, rax
    cmp rax, 4096
    ja .bad
    mov rcx, rax
    call sr_take
    jc .out
    mov r13, rsi
    mov rdi, rbp
    mov esi, r12d
    call blk_reserve
    jc .out
    mov rdi, [rbp + BL_TEXT]
    mov rsi, r13
    mov rcx, r12
    rep movsb
    mov [rbp + BL_LEN], r12d
    mov rdi, [rbp + BL_TEXT]            ; the attributes follow at BL_CAP; a
                                        ; name has none worth keeping
    mov eax, [rbp + BL_CAP]
    add rdi, rax
    mov rcx, r12
    xor eax, eax
    rep stosb
    call sr_var                         ; its cells
    jc .out
    mov r14, rax
.cell:
    test r14, r14
    jz .done
    call sr_var
    jc .out
    mov r12d, eax                       ; R12D, R13D: where
    call sr_var
    jc .out
    mov r13d, eax
    call sr_var
    jc .out
    mov rcx, rax
    call sr_take
    jc .out
    cmp r12d, MAXR                      ; past the edge: dropped
    jae .cell_next
    cmp r13d, MAXC
    jae .cell_next
    mov r8d, ecx
    mov rcx, rsi
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call cell_put
    jc .out
.cell_next:
    dec r14
    jmp .cell
.done:
    mov rdi, rbx
    call grid_recalc
    clc
    jmp .out
.bad:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
.clamp_rows:
    test eax, eax
    jnz .rows_low
    inc eax
.rows_low:
    cmp eax, MAXR
    jbe .clamped
    mov eax, MAXR
.clamped:
    ret
.clamp_cols:
    test eax, eax
    jnz .cols_low
    inc eax
.cols_low:
    cmp eax, MAXC
    jbe .clamped
    mov eax, MAXC
    ret

; sr_image(RDI = an image's block, empty) -> CF if it cannot be read; EAX
; < 0 if there is no memory for it. Preserves RBX, RBP, R12-R15.
sr_image:
    push rbx
    push rbp
    push r12
    push r13
    mov rbp, rdi
    call sr_var
    jc .out
    mov r12d, eax                       ; R12D, R13D: its size
    call sr_var
    jc .out
    mov r13d, eax
    lea eax, [r12 - 1]
    cmp eax, IM_MAX
    jae .bad
    lea eax, [r13 - 1]
    cmp eax, IM_MAX
    jae .bad
    call sr_byte
    jc .out
    test eax, eax
    jnz .bad
    mov rdi, rbp
    call sr_text_plain
    jc .out
    mov edi, r12d
    imul edi, r13d
    shl edi, 2
    add edi, IM_PX
    call da_alloc
    test rax, rax
    jz .memory
    mov rbx, rax
    mov [rbp + BL_DATA], rbx
    mov [rbx + IM_W], r12d
    mov [rbx + IM_H], r13d
    mov ecx, r12d
    imul ecx, r13d
    imul ecx, ecx, 3
    call sr_take
    jc .out
    mov ecx, r12d
    imul ecx, r13d
    lea rdi, [rbx + IM_PX]
.pixel:
    mov al, [rsi + 2]
    mov [rdi], al
    mov al, [rsi + 1]
    mov [rdi + 1], al
    mov al, [rsi]
    mov [rdi + 2], al
    mov byte [rdi + 3], 0
    add rsi, 3
    add rdi, 4
    dec ecx
    jnz .pixel
    xor eax, eax
    clc
    jmp .out
.memory:
    mov eax, -1
    clc
    jmp .out
.bad:
    stc
.out:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sr_text_plain(RDI = a block, empty) -> CF: a length and that much text,
; with no attributes. Preserves RBX, RBP, R12-R15.
sr_text_plain:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    call sr_var
    jc .out
    mov r12, rax
    cmp rax, 4096
    ja .bad
    mov rcx, rax
    call sr_take
    jc .out
    mov r13, rsi
    mov rdi, rbx
    mov esi, r12d
    call blk_reserve
    jc .out
    mov rdi, [rbx + BL_TEXT]
    mov rsi, r13
    mov rcx, r12
    rep movsb
    mov [rbx + BL_LEN], r12d
    mov rdi, [rbx + BL_TEXT]
    mov eax, [rbx + BL_CAP]
    add rdi, rax
    mov rcx, r12
    xor eax, eax
    rep stosb
    clc
    jmp .out
.bad:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

doc_fixup:
    push rbx
    xor ebx, ebx
.block:
    cmp ebx, [nblocks]
    jae .any
    mov edi, ebx
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .next
    movzx ecx, word [rax + BL_KIDS]     ; not past the end
    mov edx, [nblocks]
    sub edx, ebx
    dec edx
    cmp ecx, edx
    jbe .inside
    mov ecx, edx
.inside:
    xor edx, edx                        ; nor over another frame
.kid:
    cmp edx, ecx
    jae .kids_ok
    lea edi, [rbx + rdx + 1]
    push rax
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    pop rax
    je .cut
    inc edx
    jmp .kid
.cut:
    mov ecx, edx
.kids_ok:
    mov [rax + BL_KIDS], cx
.next:
    inc ebx
    jmp .block
.any:
    cmp dword [nblocks], 0
    jne .out
    xor edi, edi
    mov esi, BK_PARA
    call blk_insert_raw
.out:
    pop rbx
    ret

; --- plain text and CSV ----------------------------------------------------------

text_import:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12: at; R13: the end
    lea r13, [rsi + rcx]
    xor ebp, ebp                        ; EBP: blocks
    xor r15d, r15d                      ; R15: the grid rows come into, or 0
.line:
    cmp r12, r13
    jae .done
    mov r14, r12                        ; R14: the line; RBX: its end
    mov rbx, r12
.find_end:
    cmp rbx, r13
    jae .found
    cmp byte [rbx], 10
    je .found
    inc rbx
    jmp .find_end
.found:
    lea r12, [rbx + 1]                  ; the next, past the newline
    cmp rbx, r14                        ; a CR before it: not the line's
    je .shape
    cmp byte [rbx - 1], 13
    jne .shape
    dec rbx
.shape:
    mov rsi, r14
    mov rcx, rbx
    sub rcx, rsi
    call line_cells                     ; a grid's row?
    test eax, eax
    jz .not_row
    test r15, r15
    jnz .row
    mov edi, [nblocks]
    mov esi, BK_GRID
    call blk_insert_raw
    test rax, rax
    jz .done
    mov r15, rax
    call grid_new
    test rax, rax
    jz .done
    mov [r15 + BL_DATA], rax
    mov dword [rax + GR_ROWS], 0
    mov dword [rax + GR_COLS], 1        ; (the rows widen it)
    inc ebp
.row:
    mov rdi, r15
    mov rsi, r14
    mov rdx, rbx
    call grid_row
    jmp .line
.not_row:
    test r15, r15
    jz .text_line
    mov rdi, [r15 + BL_DATA]
    call grid_recalc
    xor r15d, r15d
.text_line:
    mov esi, BK_PARA                    ; ESI: the kind; R14: past its mark
    mov rcx, rbx
    sub rcx, r14
    cmp rcx, 2
    jb .add
    cmp word [r14], '# '
    je .h1
    cmp word [r14], '- '
    je .bullet
    cmp word [r14], '* '
    je .bullet
    cmp rcx, 3
    jb .number
    cmp word [r14], '##'
    jne .number
    cmp byte [r14 + 2], ' '
    je .h2
    cmp rcx, 4
    jb .number
    cmp word [r14 + 2], '# '
    je .h3
.number:
    movzx eax, byte [r14]               ; digits, then ". "
    sub eax, '0'
    cmp eax, 9
    ja .add
    mov rdx, r14
.digits:
    inc rdx
    cmp rdx, rbx
    jae .add
    movzx eax, byte [rdx]
    sub eax, '0'
    cmp eax, 9
    jbe .digits
    lea rax, [rdx + 2]
    cmp rax, rbx
    ja .add
    cmp word [rdx], '. '
    jne .add
    mov esi, BK_NUMBER
    lea r14, [rdx + 2]
    jmp .add
.h1:
    mov esi, BK_H1
    add r14, 2
    jmp .add
.h2:
    mov esi, BK_H2
    add r14, 3
    jmp .add
.h3:
    mov esi, BK_H3
    add r14, 4
    jmp .add
.bullet:
    mov esi, BK_BULLET
    add r14, 2
.add:
    mov edi, [nblocks]
    call blk_insert_raw
    test rax, rax
    jz .done
    inc ebp
    mov edi, [nblocks]
    dec edi
    xor esi, esi
    mov rdx, r14
    mov rcx, rbx
    sub rcx, r14
    xor r8d, r8d
    call text_insert
    jmp .line
.done:
    test r15, r15
    jz .out
    mov rdi, [r15 + BL_DATA]
    call grid_recalc
.out:
    mov eax, ebp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; line_cells(RSI = a line, RCX = bytes) -> EAX = 1 if it is a grid's row: a
; tab in it, or "|" first. Preserves all but RAX.
line_cells:
    xor eax, eax
    test rcx, rcx
    jz .out
    cmp byte [rsi], '|'
    je .yes
    push rcx
    push rdi
    mov rdi, rsi
    mov al, 9
    repne scasb
    pop rdi
    pop rcx
    mov eax, 0
    jne .out
.yes:
    mov eax, 1
.out:
    ret

; grid_row(RDI = a grid's block, RSI = a line, RDX = its end): the next row,
; its cells between tabs (or "|"), spaces around each dropped
grid_row:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, [rdi + BL_DATA]
    mov r12, rsi
    mov r13, rdx
    mov ebp, [rbx + GR_ROWS]            ; EBP: the row
    cmp ebp, MAXR
    jae .out
    mov r15b, 9                         ; R15B: what is between cells
    cmp byte [r12], '|'
    jne .row
    mov r15b, '|'
    inc r12
    mov rsi, r12                        ; "|---|:--|": only a rule, not a row
.rule:
    cmp rsi, r13
    jae .out
    movzx eax, byte [rsi]
    inc rsi
    cmp al, '-'
    je .rule
    cmp al, ':'
    je .rule
    cmp al, '|'
    je .rule
    cmp al, ' '
    je .rule
.row:
    inc dword [rbx + GR_ROWS]
.cells:
    xor r14d, r14d                      ; R14D: the column
.cell:
    cmp r12, r13
    jae .out
    mov rsi, r12
.cell_end:
    cmp r12, r13
    jae .got
    cmp [r12], r15b
    je .got
    inc r12
    jmp .cell_end
.got:
    mov rcx, r12                        ; RSI .. RCX: it, spaces dropped
.trim_end:
    cmp rcx, rsi
    je .trim_start
    cmp byte [rcx - 1], ' '
    jne .trim_start
    dec rcx
    jmp .trim_end
.trim_start:
    cmp rsi, rcx
    je .put
    cmp byte [rsi], ' '
    jne .put
    inc rsi
    jmp .trim_start
.put:
    cmp r14d, MAXC
    jae .skip
    sub rcx, rsi
    mov r8d, ecx
    mov rcx, rsi
    mov rdi, rbx
    mov esi, ebp
    mov edx, r14d
    call cell_put
.skip:
    inc r14d
    cmp r12, r13
    jae .out
    inc r12                             ; past the separator
    cmp r15b, '|'                       ; a "|" at the end ends it
    jne .cell
    cmp r12, r13
    jae .out
    jmp .cell
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

csv_import:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12: at; R13: the end
    lea r13, [rsi + rcx]
    mov edi, [nblocks]
    mov esi, BK_GRID
    call blk_insert_raw
    test rax, rax
    jz .memory
    mov rbp, rax
    call grid_new
    test rax, rax
    jz .memory
    mov [rbp + BL_DATA], rax
    mov rbx, rax                        ; RBX: the grid
    mov dword [rbx + GR_ROWS], 1
    mov dword [rbx + GR_COLS], 1
    xor r14d, r14d                      ; R14D: the row; R15D: the column
    xor r15d, r15d
.field:
    mov rdi, [csv_buf]                  ; the field, unquoted, into csv_buf
    xor ecx, ecx
    cmp r12, r13
    jae .put
    cmp byte [r12], '"'
    jne .plain
    inc r12
.quoted:
    cmp r12, r13
    jae .put
    mov al, [r12]
    inc r12
    cmp al, '"'
    jne .q_char
    cmp r12, r13
    jae .put
    cmp byte [r12], '"'                 ; "" is one
    jne .q_end
    inc r12
.q_char:
    cmp ecx, 4096
    jae .quoted
    mov [rdi + rcx], al
    inc ecx
    jmp .quoted
.q_end:
    cmp r12, r13                        ; up to the next , or newline
    jae .put
    cmp byte [r12], ','
    je .put
    cmp byte [r12], 10
    je .put
    inc r12
    jmp .q_end
.plain:
    cmp r12, r13
    jae .put
    mov al, [r12]
    cmp al, ','
    je .put
    cmp al, 10
    je .put
    inc r12
    cmp al, 13
    je .plain
    cmp ecx, 4096
    jae .plain
    mov [rdi + rcx], al
    inc ecx
    jmp .plain
.put:
    cmp r14d, MAXR
    jae .after
    cmp r15d, MAXC
    jae .after
    test ecx, ecx
    jz .after
    mov r8d, ecx
    mov rcx, [csv_buf]
    mov rdi, rbx
    mov esi, r14d
    mov edx, r15d
    call cell_put
.after:
    cmp r12, r13
    jae .done
    mov al, [r12]
    inc r12
    cmp al, ','
    jne .newline
    inc r15d
    jmp .field
.newline:
    cmp r12, r13                        ; a last newline adds no row
    jae .done
    inc r14d
    xor r15d, r15d
    jmp .field
.done:
    mov rdi, rbx
    call grid_recalc
    mov eax, 1
    jmp .out
.memory:
    mov eax, DE_MEMORY
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

text_export:
    push rbx
    push rbp
    push r12
    push r13
    mov [sw_p], rdi
    mov [sw_start], rdi
    add rsi, rdi
    mov [sw_end], rsi
    mov byte [sw_over], 0
    xor ebx, ebx
    mov r13d, 1                         ; R13D: the next number of a list
.block:
    cmp ebx, [nblocks]
    jae .done
    mov edi, ebx
    call blk_at
    mov rbp, rax
    movzx eax, byte [rbp + BL_KIND]
    cmp eax, BK_NUMBER
    je .numbered
    mov r13d, 1
    cmp eax, BK_GRID
    je .grid
    cmp eax, BK_H1
    je .h1
    cmp eax, BK_SLIDE
    je .h1
    cmp eax, BK_H2
    je .h2
    cmp eax, BK_H3
    je .h3
    cmp eax, BK_BULLET
    je .bullet
    jmp .text
.numbered:
    mov eax, r13d
    inc r13d
    sub rsp, 16
    mov rdi, rsp
    push rbx
    mov rbx, rdi
    mov ecx, 10
    lea rdi, [rbx + 15]
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test eax, eax
    jnz .digit
    lea rsi, [rdi + 1]
    lea rcx, [rbx + 16]
    sub rcx, rsi
    pop rbx
    call sw_bytes
    add rsp, 16
    lea rsi, [s_dot_sp]
    mov ecx, 2
    call sw_bytes
    jmp .text
.h1:
    lea rsi, [s_h1_mark]
    mov ecx, 2
    jmp .mark
.h2:
    lea rsi, [s_h2_mark]
    mov ecx, 3
    jmp .mark
.h3:
    lea rsi, [s_h3_mark]
    mov ecx, 4
    jmp .mark
.bullet:
    lea rsi, [s_bullet_mark]
    mov ecx, 2
.mark:
    call sw_bytes
.text:
    mov rsi, [rbp + BL_TEXT]
    mov ecx, [rbp + BL_LEN]
    call sw_bytes
    mov al, 10
    call sw_byte
    jmp .next
.grid:
    mov rdi, [rbp + BL_DATA]
    call sw_grid_text
.next:
    inc ebx
    jmp .block
.done:
    mov rax, -1
    cmp byte [sw_over], 0
    jne .out
    mov rax, [sw_p]
    sub rax, [sw_start]
.out:
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; sw_grid_text(RDI = a grid): its table, a line a row, tabs between the
; cells' values. Preserves RBX, RBP, R12-R15.
sw_grid_text:
    push rbx
    push r12
    push r13
    sub rsp, 40
    mov rbx, rdi
    xor r12d, r12d
.row:
    cmp r12d, [rbx + GR_ROWS]
    jae .out
    xor r13d, r13d
.col:
    cmp r13d, [rbx + GR_COLS]
    jae .eol
    test r13d, r13d
    jz .value
    mov al, 9
    call sw_byte
.value:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call cell_at
    mov rdi, rax
    mov rsi, rsp
    call cell_show
    call sw_bytes
    inc r13d
    jmp .col
.eol:
    mov al, 10
    call sw_byte
    inc r12d
    jmp .row
.out:
    add rsp, 40
    pop r13
    pop r12
    pop rbx
    ret

csv_export:
    push rbx
    push r12
    push r13
    push r14
    mov [sw_p], rdi
    mov [sw_start], rdi
    add rsi, rdi
    mov [sw_end], rsi
    mov byte [sw_over], 0
    mov edi, edx
    call blk_at
    mov rbx, [rax + BL_DATA]
    xor r12d, r12d
.row:
    cmp r12d, [rbx + GR_ROWS]
    jae .done
    xor r13d, r13d
.col:
    cmp r13d, [rbx + GR_COLS]
    jae .eol
    test r13d, r13d
    jz .cell
    mov al, ','
    call sw_byte
.cell:
    mov rdi, rbx
    mov esi, r12d
    mov edx, r13d
    call cell_at
    mov rsi, [rax + CE_TEXT]
    mov ecx, [rax + CE_LEN]
    xor r14d, r14d                      ; quoted if a , " or newline is in it
    xor edx, edx
.scan:
    cmp edx, ecx
    jae .scanned
    mov al, [rsi + rdx]
    cmp al, ','
    je .quote
    cmp al, '"'
    je .quote
    cmp al, 10
    je .quote
    inc edx
    jmp .scan
.quote:
    mov r14d, 1
.scanned:
    test r14d, r14d
    jnz .quoted
    call sw_bytes
    jmp .next
.quoted:
    mov al, '"'
    call sw_byte
.q_char:
    test ecx, ecx
    jz .q_end
    mov al, [rsi]
    call sw_byte
    cmp al, '"'
    jne .q_next
    call sw_byte
.q_next:
    inc rsi
    dec ecx
    jmp .q_char
.q_end:
    mov al, '"'
    call sw_byte
.next:
    inc r13d
    jmp .col
.eol:
    mov al, 10
    call sw_byte
    inc r12d
    jmp .row
.done:
    mov rax, -1
    cmp byte [sw_over], 0
    jne .out
    mov rax, [sw_p]
    sub rax, [sw_start]
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
s_dot_sp:       db '. '
s_h1_mark:      db '# '
s_h2_mark:      db '## '
s_h3_mark:      db '### '
s_bullet_mark:  db '- '

section .bss
alignb 8
sw_p:           resq 1
sw_start:       resq 1
sw_end:         resq 1
sr_p:           resq 1
sr_end:         resq 1
csv_buf:        resq 1                  ; 4 KiB, the caller's
ser_v_block:    resd 1
ser_v_off:      resd 1
des_v_block:    resd 1
des_v_off:      resd 1
sw_over:        resb 1
ser_view:       resb 1
ser_v_view:     resb 1
des_view:       resb 1
des_v_view:     resb 1

section .text
