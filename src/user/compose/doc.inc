; =============================================================================
;  compose/doc.inc - the document: one list of blocks
;
;  A block (BL_*, in blocks, nblocks of them) is a paragraph, a heading (1 to
;  3), a list item (bulleted or numbered), a grid (a table, a spreadsheet:
;  GR_*), an image (IM_*) or a slide frame. Each has text: UTF-8 with an
;  attribute byte for each byte of it (A_*), BL_CAP of each in one block of
;  the arena; a grid's text is its name, an image's its caption, a slide
;  frame's its title. A slide frame holds the BL_KIDS blocks after it: the
;  same blocks, laid out on a 16:9 frame; frames are not nested.
;
;  Memory is the document arena (da_*): taken, never given back one piece at
;  a time; loading a document (and so undo, which loads what was saved
;  before) starts it again.
;    da_alloc(RDI = bytes) -> RAX, 16-aligned; da_zalloc likewise, zeroed;
;      0 when it is full. Preserve all but RAX.
;    blk_at(EDI = index) -> RAX = its BL_*. Preserves all but RAX.
;    blk_texty(EDI) -> ZF clear if its text is what the cursor edits (not
;      a grid or an image). Preserves all.
;    blk_reserve(RDI = a block, ESI = bytes) -> CF if there is no memory:
;      room for that much text. Preserves RBX, RBP, R12-R15.
;    text_insert(EDI = index, ESI = offset, RDX = bytes, ECX = how many,
;      R8D = their attributes) -> CF if no room
;    text_insert_a(EDI, ESI, RDX = bytes, RCX = attributes, R8D = how many)
;    text_delete(EDI = index, ESI = offset, EDX = how many)
;    blk_insert(EDI = index, ESI = BK_*, EDX = 1 if it joins the frame
;      whose last block is just before it) -> RAX = the new block, empty, or
;      0 if there is no room
;    blk_delete(EDI = index): gone, the frame holding it one smaller (a
;      frame deleted leaves what it held)
;    blk_frame(EDI = index) -> EAX = the frame holding it, or -1
;    blk_end(EDI = index) -> EAX = the index after it and, for a frame,
;      after what it holds
;    grid_new -> RAX = a grid, 3 by 3, a header row; 0 if no memory
;    cell_at(RDI = a grid, ESI = row, EDX = column) -> RAX = its CE_*.
;      Preserves all but RAX.
;    doc_clear: no blocks, the arena empty
;    utf8_prev(RSI = text, EDX = offset) -> EAX = where the character
;      before it starts. Preserves all but RAX.
;    utf8_len_at(RSI = text, EDX = offset, ECX = length) -> EAX = where the
;      next character starts. Preserves all but RAX.
; =============================================================================

BL_KIND         equ 0                   ; byte BK_*
BL_ALIGN        equ 1                   ; byte AL_*
BL_KIDS         equ 2                   ; word: a frame's blocks
BL_LEN          equ 4                   ; dword: the text's bytes
BL_CAP          equ 8                   ; dword: room for
BL_AUX          equ 12                  ; dword
BL_TEXT         equ 16                  ; qword: text, then its attributes
BL_DATA         equ 24                  ; qword: a grid's, an image's
BL_SIZE         equ 32

BK_PARA         equ 0
BK_H1           equ 1
BK_H2           equ 2
BK_H3           equ 3
BK_BULLET       equ 4
BK_NUMBER       equ 5
BK_GRID         equ 6
BK_IMAGE        equ 7
BK_SLIDE        equ 8
BK_COUNT        equ 9

AL_LEFT         equ 0
AL_CENTER       equ 1
AL_RIGHT        equ 2

A_BOLD          equ 1                   ; = WF_BOLD, and with A_ITALIC the face
A_ITALIC        equ 2
A_UNDER         equ 4
A_STRIKE        equ 8
A_MASK          equ 15

MAX_BLOCKS      equ 8192
DA_BYTES        equ 64 << 20

; a grid: a header, then MAXR rows of MAXC cells; GR_ROWS by GR_COLS of them
; are the table a page shows, every one the spreadsheet
GR_ROWS         equ 0
GR_COLS         equ 4
GR_FLAGS        equ 8                   ; GF_*
GR_CELLS        equ 16
MAXR            equ 200
MAXC            equ 26
GR_SIZE         equ GR_CELLS + MAXR * MAXC * CE_SIZE
GF_HEADER       equ 1                   ; its first row a header

CE_TEXT         equ 0                   ; qword: what was typed
CE_LEN          equ 8                   ; dword
CE_KIND         equ 12                  ; byte VK_*: its value's
CE_FLAGS        equ 13                  ; byte CF_*
CE_ERR          equ 14                  ; byte ER_*, with VK_ERR
CE_VAL          equ 16                  ; a double, or (VK_TEXT) where its text is
CE_VLEN         equ 24                  ; dword: (VK_TEXT) how long
CE_SIZE         equ 32
CF_FORMULA      equ 1
CF_DIRTY        equ 2
CF_BUSY         equ 4

IM_W            equ 0                   ; an image: its size, then its pixels
IM_H            equ 4                   ; (B,G,R,x)
IM_PX           equ 16
IM_MAX          equ 1024                ; a side, at most

section .text

da_alloc:
    push rcx
    mov rax, [da_top]
    lea rcx, [rax + rdi + 15]
    and rcx, -16
    cmp rcx, [da_end]
    ja .full
    mov [da_top], rcx
    pop rcx
    ret
.full:
    xor eax, eax
    pop rcx
    ret

da_zalloc:
    call da_alloc
    test rax, rax
    jz .out
    push rdi
    push rcx
    push rax
    mov rcx, rdi
    mov rdi, rax
    xor eax, eax
    rep stosb
    pop rax
    pop rcx
    pop rdi
.out:
    ret

blk_at:
    mov eax, edi
    shl rax, 5
    add rax, [blocks]
    ret

blk_texty:
    push rax
    call blk_at
    cmp byte [rax + BL_KIND], BK_GRID
    je .no
    cmp byte [rax + BL_KIND], BK_IMAGE
    je .no
    pop rax
    or eax, 1                           ; ZF clear
    ret
.no:
    pop rax
    cmp eax, eax                        ; ZF set
    ret

blk_reserve:
    cmp esi, [rdi + BL_CAP]
    jbe .fits
    push rbx
    push r12
    push r13
    mov rbx, rdi
    lea r12d, [rsi + rsi]               ; R12D: room for twice as much
    cmp r12d, 32
    jae .room
    mov r12d, 32
.room:
    lea rdi, [r12 + r12]
    call da_alloc
    test rax, rax
    jz .none
    mov r13, rax
    mov rsi, [rbx + BL_TEXT]            ; the text
    mov rdi, r13
    mov ecx, [rbx + BL_LEN]
    rep movsb
    mov rsi, [rbx + BL_TEXT]            ; its attributes
    mov eax, [rbx + BL_CAP]
    add rsi, rax
    lea rdi, [r13 + r12]
    mov ecx, [rbx + BL_LEN]
    rep movsb
    mov [rbx + BL_TEXT], r13
    mov [rbx + BL_CAP], r12d
    pop r13
    pop r12
    pop rbx
.fits:
    clc
    ret
.none:
    pop r13
    pop r12
    pop rbx
    stc
    ret

; text_insert: each byte with the same attribute
text_insert:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14, rdx
    mov r15d, ecx
    mov ebx, r8d
    call blk_at
    mov rdi, rax
    mov esi, [rax + BL_LEN]
    add esi, r15d
    call blk_reserve
    jc .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    call text_gap                       ; RAX: the text at the gap, RDX: attributes
    mov rdi, rax
    mov rsi, r14
    mov ecx, r15d
    rep movsb
    mov rdi, rdx
    mov eax, ebx
    mov ecx, r15d
    rep stosb
    clc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

text_insert_a:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14, rdx
    mov rbx, rcx
    mov r15d, r8d
    call blk_at
    mov rdi, rax
    mov esi, [rax + BL_LEN]
    add esi, r15d
    call blk_reserve
    jc .out
    mov edi, r12d
    mov esi, r13d
    mov edx, r15d
    call text_gap
    mov rdi, rax
    mov rsi, r14
    mov ecx, r15d
    rep movsb
    mov rdi, rdx
    mov rsi, rbx
    mov ecx, r15d
    rep movsb
    clc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; text_gap(EDI = index, ESI = offset, EDX = bytes; room there already) ->
; RAX = the text there, RDX = its attributes there: what was after the
; offset moved up that far, the length grown
text_gap:
    push rbx
    push r12
    push r13
    call blk_at
    mov rbx, rax
    mov r12d, esi
    mov r13d, edx
    mov ecx, [rbx + BL_LEN]             ; the text's tail, from the end down
    sub ecx, r12d
    mov rsi, [rbx + BL_TEXT]
    mov eax, [rbx + BL_LEN]
    lea rsi, [rsi + rax - 1]
    lea rdi, [rsi + r13]
    std
    rep movsb
    cld
    mov ecx, [rbx + BL_LEN]             ; and the attributes'
    sub ecx, r12d
    mov rsi, [rbx + BL_TEXT]
    mov eax, [rbx + BL_CAP]
    add rsi, rax
    mov eax, [rbx + BL_LEN]
    lea rsi, [rsi + rax - 1]
    lea rdi, [rsi + r13]
    std
    rep movsb
    cld
    add [rbx + BL_LEN], r13d
    mov rax, [rbx + BL_TEXT]
    mov edx, [rbx + BL_CAP]
    add rdx, rax
    add rax, r12
    add rdx, r12
    pop r13
    pop r12
    pop rbx
    ret

text_delete:
    push rbx
    call blk_at
    mov rbx, rax
    mov eax, [rbx + BL_LEN]
    cmp esi, eax
    jae .out
    sub eax, esi
    cmp edx, eax
    jbe .count
    mov edx, eax
.count:
    mov r8d, esi                        ; R8D: where; EDX: how many
    mov rdi, [rbx + BL_TEXT]
    add rdi, r8
    lea rsi, [rdi + rdx]
    mov ecx, [rbx + BL_LEN]
    sub ecx, r8d
    sub ecx, edx
    mov r9d, ecx
    rep movsb
    mov rdi, [rbx + BL_TEXT]
    mov eax, [rbx + BL_CAP]
    add rdi, rax
    add rdi, r8
    lea rsi, [rdi + rdx]
    mov ecx, r9d
    rep movsb
    sub [rbx + BL_LEN], edx
.out:
    pop rbx
    ret

blk_frame:
    push rcx
    push rdx
    mov ecx, edi
.back:
    dec ecx
    js .none
    mov eax, ecx
    shl rax, 5
    add rax, [blocks]
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .back
    movzx edx, word [rax + BL_KIDS]     ; the nearest frame before: does it reach?
    add edx, ecx
    cmp edi, edx
    ja .none
    mov eax, ecx
    pop rdx
    pop rcx
    ret
.none:
    mov eax, -1
    pop rdx
    pop rcx
    ret

blk_end:
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .one
    movzx eax, word [rax + BL_KIDS]
    lea eax, [rdi + rax + 1]
    ret
.one:
    lea eax, [rdi + 1]
    ret

blk_insert:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    cmp dword [nblocks], MAX_BLOCKS
    jae .none
    mov edi, 32                         ; its text, first
    call da_alloc
    test rax, rax
    jz .none
    mov rbx, rax
    mov edi, r12d                       ; the frame it goes into, if any
    call blk_frame
    cmp eax, -1
    jne .grow
    test r14d, r14d
    jz .place
    lea edi, [r12 - 1]                  ; just after a frame's last block
    test edi, edi
    js .place
    call blk_frame
    cmp eax, -1
    jne .grow
    lea edi, [r12 - 1]                  ; or the frame itself, empty
    call blk_at
    cmp byte [rax + BL_KIND], BK_SLIDE
    jne .place
    cmp word [rax + BL_KIDS], 0
    jne .place
    lea eax, [r12 - 1]
.grow:
    cmp r13d, BK_SLIDE                  ; never a frame in a frame
    je .place
    mov edi, eax
    call blk_at
    inc word [rax + BL_KIDS]
.place:
    mov edi, r12d
    mov esi, r13d
    mov rdx, rbx
    call blk_place
    jmp .out
.none:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; blk_insert_raw(EDI = index, ESI = BK_*) -> RAX = the new block, or 0: as
; blk_insert, no frame told
blk_insert_raw:
    push rbx
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    cmp dword [nblocks], MAX_BLOCKS
    jae .none
    mov edi, 32
    call da_alloc
    test rax, rax
    jz .none
    mov edi, r12d
    mov esi, r13d
    mov rdx, rax
    call blk_place
    jmp .out
.none:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; blk_place(EDI = index, ESI = BK_*, RDX = 32 bytes for its text) -> RAX =
; the block, those from the index on moved up one
blk_place:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov rbx, rdx
    mov ecx, [nblocks]                  ; those after it, up one
    sub ecx, r12d
    shl ecx, 5
    mov edi, r12d
    call blk_at
    lea rsi, [rax + rcx - 1]
    lea rdi, [rsi + BL_SIZE]
    std
    rep movsb
    cld
    mov rdi, rax
    xor eax, eax
    mov ecx, BL_SIZE / 8
    rep stosq
    sub rdi, BL_SIZE
    mov rax, rdi
    mov [rax + BL_KIND], r13b
    mov [rax + BL_TEXT], rbx
    mov dword [rax + BL_CAP], 16
    inc dword [nblocks]
    pop r13
    pop r12
    pop rbx
    ret

blk_delete:
    push rbx
    mov ebx, edi
    call blk_frame
    cmp eax, -1
    je .free
    mov edi, eax
    call blk_at
    dec word [rax + BL_KIDS]
.free:
    mov edi, ebx                        ; those after it, down one
    call blk_at
    mov rdi, rax
    lea rsi, [rax + BL_SIZE]
    mov ecx, [nblocks]
    sub ecx, ebx
    dec ecx
    shl ecx, 5
    rep movsb
    dec dword [nblocks]
    pop rbx
    ret

grid_new:
    mov edi, GR_SIZE
    call da_zalloc
    test rax, rax
    jz .out
    mov dword [rax + GR_ROWS], 3
    mov dword [rax + GR_COLS], 3
    mov dword [rax + GR_FLAGS], GF_HEADER
.out:
    ret

cell_at:
    push rdx
    imul eax, esi, MAXC
    add eax, edx
    shl eax, 5
    lea rax, [rdi + rax + GR_CELLS]
    pop rdx
    ret

doc_clear:
    mov dword [nblocks], 0
    mov rax, [da_base]
    mov [da_top], rax
    ret

utf8_prev:
    mov eax, edx
.back:
    test eax, eax
    jz .out
    dec eax
    push rcx
    movzx ecx, byte [rsi + rax]
    and ecx, 0xC0
    cmp ecx, 0x80
    pop rcx
    je .back
.out:
    ret

utf8_len_at:
    mov eax, edx
    cmp eax, ecx
    jae .out
.fwd:
    inc eax
    cmp eax, ecx
    jae .out
    push rcx
    movzx ecx, byte [rsi + rax]
    and ecx, 0xC0
    cmp ecx, 0x80
    pop rcx
    je .fwd
.out:
    ret

section .bss
alignb 8
blocks:         resq 1
da_base:        resq 1
da_top:         resq 1
da_end:         resq 1
nblocks:        resd 1

section .text
