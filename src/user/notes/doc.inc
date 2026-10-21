; =============================================================================
;  notes/doc.inc - a document: its text, its lines, what undo puts back, and
;  its file
;
;  A document (D_*) keeps its text in memory of its own (D_BUFH), after a
;  path's field: the files calls take the path and the bytes from the same
;  memory. Lines end in LF; a file with CR LF is read so, and written so
;  again (D_CRLF). D_LINES has where each line starts, made again after
;  each change. Every change goes through ed_insert and ed_delete, which
;  keep a record for undo (U_*): a group of them is one undo.
;    doc_new -> RBX = a new, empty document, the current one; CF if there
;      are as many as there can be
;    doc_load(RBX, RSI = a path) -> RAX = 0, or E_*: the file read into it
;    doc_save(RBX) -> RAX = 0, or E_*
;    doc_close(RBX): its memory given back, the rest moved down
;    ed_insert(RBX, ESI = where, RDX = bytes, ECX = how many) -> CF if
;      there is no room
;    ed_delete(RBX, ESI = where, ECX = how many)
;    ed_begin(RBX): what follows is one undo, with the caret as it is now
;    ed_undo(RBX), ed_redo(RBX)
;    line_of(RBX, EAX = a place) -> EAX = its line; line_at(RBX, EAX = a
;      line) -> EAX = where it starts, EDX = where it ends (its LF, or the
;      end)
;    col_of(RBX, EAX = a place) -> EAX = its column, tabs spread out;
;      at_col(RBX, EAX = a line, ECX = a column) -> EAX = the place there,
;      or the nearest before
; =============================================================================

MAX_DOCS        equ 16
TABW            equ 4                   ; a tab's columns
PATHW           equ FS_PATH             ; before the text, in its memory

D_BUF           equ 0                   ; qword: its text
D_LINES         equ 8                   ; qword: where each line starts (dwords)
D_UNDO          equ 16                  ; qword: undo's records
D_UTEXT         equ 24                  ; qword: the bytes they put back
D_MEM           equ 32                  ; qword: the text's memory, mapped
D_BUFH          equ 40                  ; dword handles
D_LINESH        equ 44
D_UNDOH         equ 48
D_UTEXTH        equ 52
D_CAP           equ 56                  ; dword: room for text
D_LEN           equ 60
D_NLINES        equ 64
D_LCAP          equ 68                  ; room in D_LINES
D_CARET         equ 72
D_ANCHOR        equ 76                  ; the other end of what is chosen
D_TOP           equ 80                  ; the first line shown
D_LEFT          equ 84                  ; columns scrolled out, at the left
D_WANT          equ 88                  ; the column up and down keep to, -1 none
D_CRLF          equ 92
D_LANG          equ 96                  ; L_*
D_UN            equ 100                 ; undo records (redo's above D_UPOS)
D_UPOS          equ 104                 ; undone back to here
D_UCAP          equ 108
D_ULEN          equ 112                 ; undo's bytes used
D_UTCAP         equ 116
D_SAVED         equ 120                 ; D_UPOS when it was saved (-1: none)
D_GROUP         equ 124                 ; the group records join
D_TYPING        equ 128                 ; 1: typing on, records merge
D_NEW           equ 132                 ; 1: no file yet
D_NAME          equ 136                 ; dword: where its name begins in D_PATH
D_KIND          equ 140                 ; what its name says it is (lex.inc: kinds)
D_EDITS         equ 144                 ; changes made: what was worked out before
D_PATH          equ 152                 ; FS_PATH bytes
D_SIZE          equ D_PATH + FS_PATH

U_KIND          equ 0                   ; an undo record: UK_*
U_POS           equ 4
U_LEN           equ 8
U_TEXT          equ 12                  ; where its bytes are, in D_UTEXT
U_GROUP         equ 16
U_CARET         equ 20                  ; the caret before its group
U_ANCHOR        equ 24
U_SIZE          equ 32
UK_INSERT       equ 1
UK_DELETE       equ 2

section .text

; d_grow(RBX, ECX = bytes of text it must have room for) -> CF if it cannot
d_grow:
    cmp ecx, [rbx + D_CAP]
    jbe .ok
    push r12
    push r13
    mov r12d, ecx                       ; half as much again to spare
    shr r12d, 1
    add r12d, ecx
    add r12d, 4096
    lea edi, [r12 + PATHW + 4095]
    and edi, -4096
    mov r12d, edi
    sub r12d, PATHW
    call kit_alloc
    jc .no
    mov r13, rax
    mov rdi, rax                        ; the path and the text, moved
    mov rsi, [rbx + D_MEM]
    test rsi, rsi
    jz .fresh
    mov ecx, [rbx + D_LEN]
    add ecx, PATHW
    rep movsb
    push rdx
    mov edi, [rbx + D_BUFH]
    call kit_free
    pop rdx
.fresh:
    mov [rbx + D_MEM], r13
    lea rax, [r13 + PATHW]
    mov [rbx + D_BUF], rax
    mov [rbx + D_BUFH], edx
    mov [rbx + D_CAP], r12d
    pop r13
    pop r12
.ok:
    clc
    ret
.no:
    pop r13
    pop r12
    stc
    ret

; d_more(RBX, RDI = the field's offset in D_*: D_LINES, D_UNDO or D_UTEXT,
; ECX = bytes it must hold) -> CF if it cannot. Its room is the dword at
; D_LCAP, D_UCAP or D_UTCAP, in bytes.
d_more:
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r14d, ecx
    lea rax, [d_rooms]                  ; which room, which handle
    xor edx, edx
.find:
    cmp [rax + rdx * 4], r12d
    je .found
    add edx, 3
    jmp .find
.found:
    mov r13d, [rax + rdx * 4 + 4]       ; R13: the room's offset
    mov eax, [rax + rdx * 4 + 8]
    mov [d_hoff], eax                   ; and the handle's
    cmp r14d, [rbx + r13]
    jbe .ok
    lea edi, [r14 + r14 + 4095]
    and edi, -4096
    push rdi
    call kit_alloc
    pop rdi
    jc .no
    push rdi
    push rdx
    mov rsi, [rbx + r12]                ; what it held, moved
    mov rcx, rdi
    mov rdi, rax
    push rax
    test rsi, rsi
    jz .empty
    mov ecx, [rbx + r13]
    rep movsb
    mov ecx, [d_hoff]
    mov edi, [rbx + rcx]
    call kit_free
.empty:
    pop rax
    pop rdx
    pop rdi
    mov [rbx + r12], rax
    mov ecx, [d_hoff]
    mov [rbx + rcx], edx
    mov [rbx + r13], edi
.ok:
    clc
    jmp .out
.no:
    stc
.out:
    pop r14
    pop r13
    pop r12
    ret

doc_new:
    mov eax, [ndocs]
    cmp eax, MAX_DOCS
    jae .full
    imul eax, eax, D_SIZE
    lea rbx, [docs + rax]
    mov rdi, rbx
    mov ecx, D_SIZE
    xor eax, eax
    rep stosb
    mov dword [rbx + D_WANT], -1
    mov dword [rbx + D_NEW], 1
    mov dword [rbx + D_SAVED], 0
    mov ecx, 4096
    call d_grow
    jc .full
    call d_lines
    jc .full
    mov eax, [ndocs]
    mov [cur], eax
    inc dword [ndocs]
    clc
    ret
.full:
    stc
    ret

; doc_close(RBX): its memory given back; the documents after it move down
doc_close:
    push r12
    mov edi, [rbx + D_BUFH]
    call kit_free
    lea r12, [d_handles]
.free:
    mov eax, [r12]
    test eax, eax
    jz .moved
    mov edi, [rbx + rax]
    test edi, edi
    jz .next
    call kit_free
.next:
    add r12, 4
    jmp .free
.moved:
    mov rdi, rbx                        ; the rest, down one
    lea rsi, [rbx + D_SIZE]
    mov eax, [ndocs]
    imul eax, eax, D_SIZE
    lea rcx, [docs + rax]
    sub rcx, rsi
    rep movsb
    dec dword [ndocs]
    mov qword [st_doc], 0               ; what was worked out, of another
    pop r12
    ret

; d_lines(RBX): D_LINES made again -> CF if there is no room
d_lines:
    push r12
    push r13
    mov rsi, [rbx + D_BUF]
    mov ecx, [rbx + D_LEN]
    mov edx, 1                          ; how many: one more than its LFs
    test ecx, ecx
    jz .counted
    mov rdi, rsi
    mov al, 10
.count:
    repne scasb
    jne .counted
    inc edx
    test ecx, ecx
    jnz .count
.counted:
    mov r12d, edx
    lea ecx, [rdx * 4]
    mov edi, D_LINES
    call d_more
    jc .out
    mov rdi, [rbx + D_LINES]
    mov rsi, [rbx + D_BUF]
    mov ecx, [rbx + D_LEN]
    xor eax, eax
    mov [rdi], eax                      ; the first starts at 0
    mov r13d, 1
    xor edx, edx
.each:
    cmp edx, ecx
    jae .done
    cmp byte [rsi + rdx], 10
    jne .next
    lea eax, [rdx + 1]
    mov [rdi + r13 * 4], eax
    inc r13d
.next:
    inc edx
    jmp .each
.done:
    mov [rbx + D_NLINES], r13d
    clc
.out:
    pop r13
    pop r12
    ret

line_of:
    push rcx
    push rdx
    push rsi
    mov rsi, [rbx + D_LINES]
    xor ecx, ecx                        ; the line is in ECX..EDX
    mov edx, [rbx + D_NLINES]
.halve:
    push rax
    lea eax, [rcx + rdx]
    shr eax, 1
    cmp eax, ecx
    pop rax
    je .found
    push rdi
    lea edi, [rcx + rdx]
    shr edi, 1
    cmp eax, [rsi + rdi * 4]
    jb .lower
    mov ecx, edi
    pop rdi
    jmp .halve
.lower:
    mov edx, edi
    pop rdi
    jmp .halve
.found:
    mov eax, ecx
    pop rsi
    pop rdx
    pop rcx
    ret

line_at:
    push rcx
    mov rcx, [rbx + D_LINES]
    lea edx, [rax + 1]
    cmp edx, [rbx + D_NLINES]
    jae .last
    mov edx, [rcx + rdx * 4]
    dec edx                             ; its LF
    jmp .start
.last:
    mov edx, [rbx + D_LEN]
.start:
    mov eax, [rcx + rax * 4]
    pop rcx
    ret

col_of:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, eax
    call line_of
    call line_at                        ; EAX: its start
    mov rsi, [rbx + D_BUF]
    xor ecx, ecx
.each:
    cmp eax, edi
    jae .done
    movzx edx, byte [rsi + rax]
    inc eax
    cmp dl, 9
    je .tab
    and dl, 0xC0                        ; a character's first byte
    cmp dl, 0x80
    je .each
    inc ecx
    jmp .each
.tab:
    add ecx, TABW
    and ecx, -TABW
    jmp .each
.done:
    mov eax, ecx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

at_col:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8d, ecx
    call line_at
    mov rsi, [rbx + D_BUF]
    xor ecx, ecx                        ; the column at EAX
.each:
    cmp eax, edx
    jae .done
    cmp ecx, r8d
    jae .done
    movzx edi, byte [rsi + rax]
    cmp edi, 9
    jne .char
    mov edi, ecx
    add edi, TABW
    and edi, -TABW
    cmp edi, r8d                        ; past it: here, or after, nearer
    ja .done
    mov ecx, edi
    inc eax
    jmp .each
.char:
    inc eax
.rest:                                  ; the rest of its bytes
    cmp eax, edx
    jae .counted
    movzx edi, byte [rsi + rax]
    and edi, 0xC0
    cmp edi, 0x80
    jne .counted
    inc eax
    jmp .rest
.counted:
    inc ecx
    jmp .each
.done:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Changes, and undoing them
; -----------------------------------------------------------------------------

ed_begin:
    mov dword [rbx + D_TYPING], 0
    inc dword [group_next]
    mov eax, [group_next]
    mov [rbx + D_GROUP], eax
    mov eax, [rbx + D_CARET]
    mov [ed_caret0], eax
    mov eax, [rbx + D_ANCHOR]
    mov [ed_anchor0], eax
    ret

; u_add(RBX, EAX = UK_*, ESI = where, RDX = bytes, ECX = how many) -> CF if
; there is no room. Redo's records go.
u_add:
    push r12
    push r13
    push r14
    push r15
    mov r12d, eax
    mov r13d, esi
    mov r14, rdx
    mov r15d, ecx
    mov eax, [rbx + D_UPOS]             ; what was undone can no longer be redone
    mov [rbx + D_UN], eax
    cmp [rbx + D_SAVED], eax            ; nor reach the state saved
    jbe .saved
    mov dword [rbx + D_SAVED], -1
.saved:
    cmp dword [rbx + D_TYPING], 0       ; typing on: one record
    je .new
    test eax, eax
    jz .new
    mov rdi, [rbx + D_UNDO]
    dec eax
    shl eax, 5
    add rdi, rax
    mov eax, [rbx + D_GROUP]
    cmp [rdi + U_GROUP], eax
    jne .new
    cmp r12d, UK_INSERT
    jne .delete
    cmp dword [rdi + U_KIND], UK_INSERT
    jne .new
    mov eax, [rdi + U_POS]              ; just after it
    add eax, [rdi + U_LEN]
    cmp eax, r13d
    jne .new
    mov eax, [rdi + U_TEXT]             ; its bytes last in undo's
    add eax, [rdi + U_LEN]
    cmp eax, [rbx + D_ULEN]
    jne .new
    push rdi
    call u_bytes
    pop rdi
    jc .out
    add [rdi + U_LEN], r15d
    jmp .done
.delete:
    cmp dword [rdi + U_KIND], UK_DELETE
    jne .new
    mov eax, [rdi + U_TEXT]
    add eax, [rdi + U_LEN]
    cmp eax, [rbx + D_ULEN]
    jne .new
    lea eax, [r13 + r15]                ; just before it (backspace)
    cmp eax, [rdi + U_POS]
    je .before
    cmp r13d, [rdi + U_POS]             ; at it (delete)
    jne .new
    push rdi
    call u_bytes
    pop rdi
    jc .out
    add [rdi + U_LEN], r15d
    jmp .done
.before:
    push rdi
    call u_bytes                        ; after, then turned round
    pop rdi
    jc .out
    push rdi
    mov rsi, [rbx + D_UTEXT]            ; its bytes, then these: these first
    mov eax, [rdi + U_TEXT]
    add rsi, rax
    mov ecx, [rdi + U_LEN]
    mov edx, r15d
    call u_rotate
    pop rdi
    add [rdi + U_LEN], r15d
    mov [rdi + U_POS], r13d
    jmp .done
.new:
    mov eax, [rbx + D_UN]
    inc eax
    mov ecx, eax
    shl ecx, 5                          ; U_SIZE each
    mov edi, D_UNDO
    call d_more
    jc .out
    mov eax, [rbx + D_UN]
    shl eax, 5
    mov rdi, [rbx + D_UNDO]
    add rdi, rax
    mov [rdi + U_KIND], r12d
    mov [rdi + U_POS], r13d
    mov [rdi + U_LEN], r15d
    mov eax, [rbx + D_ULEN]
    mov [rdi + U_TEXT], eax
    mov eax, [rbx + D_GROUP]
    mov [rdi + U_GROUP], eax
    mov eax, [ed_caret0]
    mov [rdi + U_CARET], eax
    mov eax, [ed_anchor0]
    mov [rdi + U_ANCHOR], eax
    push rdi
    call u_bytes
    pop rdi
    jc .out
    inc dword [rbx + D_UN]
    mov eax, [rbx + D_UN]
    mov [rbx + D_UPOS], eax
.done:
    clc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; u_bytes(RBX, R14 = bytes, R15D = how many): onto the end of undo's ->
; CF if there is no room
u_bytes:
    mov ecx, [rbx + D_ULEN]
    add ecx, r15d
    mov edi, D_UTEXT
    call d_more
    jc .out
    mov rdi, [rbx + D_UTEXT]
    mov eax, [rbx + D_ULEN]
    add rdi, rax
    mov rsi, r14
    mov ecx, r15d
    rep movsb
    add [rbx + D_ULEN], r15d
    clc
.out:
    ret

; u_rotate(RSI = ECX bytes, then EDX more after them): the EDX first
u_rotate:
    test edx, edx
    jz .out
    push rcx
    push rdx
    mov rdi, rsi
    call u_reverse
    pop rdx
    pop rcx
    push rcx
    push rdx
    lea rdi, [rsi + rcx]
    mov ecx, edx
    call u_reverse
    pop rdx
    pop rcx
    mov rdi, rsi
    add ecx, edx
    call u_reverse
.out:
    ret

; u_reverse(RDI = ECX bytes): turned round
u_reverse:
    test ecx, ecx
    jz .out
    lea r8, [rdi + rcx - 1]
.each:
    cmp rdi, r8
    jae .out
    mov al, [rdi]
    mov dl, [r8]
    mov [rdi], dl
    mov [r8], al
    inc rdi
    dec r8
    jmp .each
.out:
    ret

ed_insert:
    push r12
    push r13
    push r14
    mov r12d, esi
    mov r13, rdx
    mov r14d, ecx
    test ecx, ecx
    jz .ok
    mov ecx, [rbx + D_LEN]
    add ecx, r14d
    call d_grow
    jc .out
    mov eax, UK_INSERT
    mov esi, r12d
    mov rdx, r13
    mov ecx, r14d
    call u_add
    jc .out
    call ed_put
    call d_changed
.ok:
    clc
.out:
    pop r14
    pop r13
    pop r12
    ret

; ed_put(RBX, R12D = where, R13 = bytes, R14D = how many): in, with no
; record
ed_put:
    mov rsi, [rbx + D_BUF]
    mov ecx, [rbx + D_LEN]
    sub ecx, r12d
    mov eax, [rbx + D_LEN]
    lea rsi, [rsi + rax - 1]
    lea rdi, [rsi + r14]
    std
    rep movsb
    cld
    mov rdi, [rbx + D_BUF]
    add rdi, r12
    mov rsi, r13
    mov ecx, r14d
    rep movsb
    add [rbx + D_LEN], r14d
    mov eax, r12d                       ; what was chosen, and the caret, past it
    add eax, r14d
    mov [rbx + D_CARET], eax
    mov [rbx + D_ANCHOR], eax
    ret

ed_delete:
    push r12
    push r13
    push r14
    mov r12d, esi
    mov r14d, ecx
    test ecx, ecx
    jz .ok
    mov eax, UK_DELETE
    mov rdx, [rbx + D_BUF]
    add rdx, rsi
    call u_add
    jc .out
    call ed_cut
    call d_changed
.ok:
    clc
.out:
    pop r14
    pop r13
    pop r12
    ret

; ed_cut(RBX, R12D = where, R14D = how many): out, with no record
ed_cut:
    mov rdi, [rbx + D_BUF]
    add rdi, r12
    lea rsi, [rdi + r14]
    mov ecx, [rbx + D_LEN]
    sub ecx, r12d
    sub ecx, r14d
    rep movsb
    sub [rbx + D_LEN], r14d
    mov [rbx + D_CARET], r12d
    mov [rbx + D_ANCHOR], r12d
    ret

; d_changed(RBX): its lines again, and it is to be drawn
d_changed:
    inc dword [rbx + D_EDITS]
    call d_lines
    mov dword [rbx + D_WANT], -1
    or dword [need], N_TEXT | N_STATUS | N_TABS
    ret

ed_undo:
    push r12
    push r13
    push r14
    push r15
    mov dword [rbx + D_TYPING], 0
    mov r15d, [rbx + D_UPOS]
    test r15d, r15d
    jz .out
    mov rdi, [rbx + D_UNDO]
    lea eax, [r15 - 1]
    shl eax, 5
    mov eax, [rdi + rax + U_GROUP]
    mov [u_group], eax
.each:
    test r15d, r15d
    jz .done
    mov rdi, [rbx + D_UNDO]
    lea eax, [r15 - 1]
    shl eax, 5
    add rdi, rax
    mov eax, [u_group]
    cmp [rdi + U_GROUP], eax
    jne .done
    dec r15d
    mov r12d, [rdi + U_POS]
    mov r14d, [rdi + U_LEN]
    mov eax, [rdi + U_CARET]
    mov [u_caret], eax
    mov eax, [rdi + U_ANCHOR]
    mov [u_anchor], eax
    cmp dword [rdi + U_KIND], UK_INSERT
    jne .put_back
    call ed_cut
    jmp .each
.put_back:
    mov r13, [rbx + D_UTEXT]
    mov eax, [rdi + U_TEXT]
    add r13, rax
    mov ecx, [rbx + D_LEN]
    add ecx, r14d
    call d_grow
    jc .done
    call ed_put
    jmp .each
.done:
    mov [rbx + D_UPOS], r15d
    mov eax, [u_caret]
    mov [rbx + D_CARET], eax
    mov eax, [u_anchor]
    mov [rbx + D_ANCHOR], eax
    call d_changed
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

ed_redo:
    push r12
    push r13
    push r14
    push r15
    mov dword [rbx + D_TYPING], 0
    mov r15d, [rbx + D_UPOS]
    cmp r15d, [rbx + D_UN]
    jae .out
    mov rdi, [rbx + D_UNDO]
    mov eax, r15d
    shl eax, 5
    mov eax, [rdi + rax + U_GROUP]
    mov [u_group], eax
.each:
    cmp r15d, [rbx + D_UN]
    jae .done
    mov rdi, [rbx + D_UNDO]
    mov eax, r15d
    shl eax, 5
    add rdi, rax
    mov eax, [u_group]
    cmp [rdi + U_GROUP], eax
    jne .done
    inc r15d
    mov r12d, [rdi + U_POS]
    mov r14d, [rdi + U_LEN]
    cmp dword [rdi + U_KIND], UK_INSERT
    jne .cut
    mov r13, [rbx + D_UTEXT]
    mov eax, [rdi + U_TEXT]
    add r13, rax
    mov ecx, [rbx + D_LEN]
    add ecx, r14d
    call d_grow
    jc .done
    call ed_put
    jmp .each
.cut:
    call ed_cut
    jmp .each
.done:
    mov [rbx + D_UPOS], r15d
    call d_changed
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; d_dirty(RBX) -> ZF clear if it has changed since it was saved
d_dirty:
    push rax
    mov eax, [rbx + D_UPOS]
    cmp eax, [rbx + D_SAVED]
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Its file
; -----------------------------------------------------------------------------

; d_path(RBX, RSI = a path): its path and name, and the language its name
; says
d_path:
    lea rdi, [rbx + D_PATH]
    xor ecx, ecx
    xor edx, edx                        ; EDX: after its last / or :
.copy:
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    test al, al
    jz .copied
    inc ecx
    cmp al, '/'
    je .part
    cmp al, ':'
    jne .next
.part:
    mov edx, ecx
.next:
    cmp ecx, FS_PATH - 1
    jb .copy
    mov byte [rdi + rcx], 0
.copied:
    mov [rbx + D_NAME], edx
    mov dword [rbx + D_NEW], 0
    lea rsi, [rbx + D_PATH + rdx]
    call lang_of
    mov [rbx + D_LANG], eax
    mov [rbx + D_KIND], edx
    ret

doc_load:
    push r12
    push r13
    call d_path
    mov r12d, 64 * 1024                 ; a guess, then its size
.read:
    mov ecx, r12d
    call d_grow
    mov rax, E_NOMEM
    jc .out
    mov rdi, [rbx + D_MEM]              ; the path, before the text
    lea rsi, [rbx + D_PATH]
    mov ecx, FS_PATH
    rep movsb
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_FS_READ
    mov eax, [ax_files]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [rbx + D_BUFH]
    mov [rsp + SQ_HANDLE2], eax
    mov qword [rsp + SQ_A1], PATHW
    mov eax, [rbx + D_CAP]
    mov [rsp + SQ_A2], rax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    test rax, rax
    js .out
    cmp eax, [rbx + D_CAP]              ; all of it?
    jbe .whole
    lea r12d, [rax + 4096]
    jmp .read
.whole:
    mov [rbx + D_LEN], eax
    mov rsi, [rbx + D_BUF]              ; CR LF: LF, and said so
    mov rdi, rsi
    mov ecx, eax
    xor edx, edx
.each:
    test ecx, ecx
    jz .converted
    lodsb
    dec ecx
    cmp al, 13
    jne .keep
    test ecx, ecx
    jz .keep
    cmp byte [rsi], 10
    jne .keep
    inc edx
    jmp .each
.keep:
    stosb
    jmp .each
.converted:
    sub rdi, [rbx + D_BUF]
    mov [rbx + D_LEN], edi
    xor eax, eax
    test edx, edx
    setnz al
    mov [rbx + D_CRLF], eax
    mov dword [rbx + D_CARET], 0
    mov dword [rbx + D_ANCHOR], 0
    mov dword [rbx + D_TOP], 0
    mov dword [rbx + D_UN], 0
    mov dword [rbx + D_UPOS], 0
    mov dword [rbx + D_SAVED], 0
    mov dword [rbx + D_ULEN], 0
    inc dword [rbx + D_EDITS]
    mov qword [st_doc], 0
    call d_lines
    or dword [need], N_ALL
    xor eax, eax
.out:
    pop r13
    pop r12
    ret

doc_save:
    push r12
    push r13
    push r14
    mov r12d, [rbx + D_BUFH]            ; R12D: the memory written from
    mov r13, [rbx + D_MEM]
    mov r14d, [rbx + D_LEN]             ; R14D: its bytes
    xor edx, edx                        ; EDX: a copy's handle, to free
    cmp dword [rbx + D_CRLF], 0
    je .write
    mov eax, [rbx + D_NLINES]           ; CR LF again: a copy
    lea edi, [r14 + rax + PATHW + 4095]
    and edi, -4096
    call kit_alloc
    jc .nomem
    mov r12d, edx
    mov r13, rax
    mov rsi, [rbx + D_BUF]
    lea rdi, [rax + PATHW]
    mov ecx, r14d
.crlf:
    test ecx, ecx
    jz .copied
    lodsb
    dec ecx
    cmp al, 10
    jne .byte
    mov byte [rdi], 13
    inc rdi
.byte:
    stosb
    jmp .crlf
.copied:
    sub rdi, r13
    sub edi, PATHW
    mov r14d, edi
    mov edx, r12d
.write:
    push rdx
    mov rdi, r13                        ; the path, before the text
    lea rsi, [rbx + D_PATH]
    mov ecx, FS_PATH
    rep movsb
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_FS_WRITE
    mov eax, [ax_files]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_HANDLE2], r12d
    mov qword [rsp + SQ_A1], PATHW
    mov [rsp + SQ_A2], r14
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    pop rdi
    push rax
    test edi, edi
    jz .freed
    call kit_free
.freed:
    pop rax
    test rax, rax
    jnz .out
    mov ecx, [rbx + D_UPOS]             ; as it is now is what was saved
    mov [rbx + D_SAVED], ecx
    mov dword [rbx + D_TYPING], 0
    or dword [need], N_TABS | N_STATUS
    jmp .out
.nomem:
    mov rax, E_NOMEM
.out:
    pop r14
    pop r13
    pop r12
    ret

section .rodata
align 4
d_rooms:        dd D_LINES, D_LCAP, D_LINESH, D_UNDO, D_UCAP, D_UNDOH
                dd D_UTEXT, D_UTCAP, D_UTEXTH
d_handles:      dd D_LINESH, D_UNDOH, D_UTEXTH, 0

section .bss
alignb 8
docs:           resb MAX_DOCS * D_SIZE
ndocs:          resd 1
cur:            resd 1                  ; the document shown
group_next:     resd 1
ed_caret0:      resd 1                  ; the caret as the group began
ed_anchor0:     resd 1
u_group:        resd 1
u_caret:        resd 1
u_anchor:       resd 1
d_hoff:         resd 1
