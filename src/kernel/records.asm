; =============================================================================
;  records.asm - what shell commands give: a table of typed records, the
;  stages of a pipeline (where, sort, pick, first, last, count, to), and the
;  end of one: the table shown, or written out as text or JSON.
;
;  There is one table (rec_tab), the main thread's, as the shell is. A
;  command builds it (rec_clear, COLUMN, rec_row, rec_set, rec_str), each
;  stage changes it in place, and the shell shows it or writes it out at the
;  end (rec_show, rec_write). rec_tmp is scratch as big: sorting, a file's
;  text, what a file is given.
; =============================================================================

TB_BYTES        equ 2 * 1024 * 1024     ; a table, and the scratch beside it
TB_MAX_COLS     equ 16
TB_MAX_ROWS     equ 8192

TB_NCOLS        equ 0                   ; dword: columns
TB_NROWS        equ 4                   ; dword: rows
TB_FLAGS        equ 8                   ; dword: TBF_*
TB_HEAP         equ 16                  ; the text heap's next free byte,
TB_END          equ 24                  ; and its end
TB_COLS         equ 32                  ; TB_MAX_COLS columns, each:
TCL_NAME         equ 0                   ;   16 bytes: its name
TCL_TYPE         equ 16                  ;   byte: FT_*
TCL_SCALE        equ 17                  ;   byte: decimals (FT_INT); all 16 digits (FT_HEX)
TCL_WIDTH        equ 20                  ;   dword: as it is shown
TCL_UNIT         equ 24                  ;   8 bytes: after a number (FT_INT)
TCL_SIZE         equ 32
TB_ROW          equ TB_MAX_COLS * 8     ; a row: a cell for each column
TB_ROWS         equ TB_COLS + TB_MAX_COLS * TCL_SIZE
TB_HEAP0        equ TB_ROWS + TB_MAX_ROWS * TB_ROW

TBF_RECORD      equ 1                   ; one record: shown as field and value
TBF_LINES       equ 2                   ; lines: shown as they are
TBF_CUT         equ 4                   ; rows or text did not all fit
TBF_TEXT        equ 8                   ; 'to text'
TBF_JSON        equ 16                  ; 'to json'

FT_TEXT         equ 0                   ; a pointer to text (0: none)
FT_INT          equ 1                   ; signed; TCL_SCALE decimals, then TCL_UNIT
FT_SIZE         equ 2                   ; bytes
FT_DUR          equ 3                   ; microseconds
FT_TIME         equ 4                   ; yyyymmddhhmm
FT_HEX          equ 5
FT_BOOL         equ 6

NOVAL           equ 0x8000000000000000  ; a cell with no value (not text)

REC_LINE_MAX    equ 1000                ; a line shown (print_buffer holds 1024)
REC_CELL_MAX    equ 255                 ; a cell, but in the last column
REC_CHUNK       equ 900                 ; text shown, at most, a line at a time

WOP_LT          equ 1                   ; where's comparisons: which of <, =, >
WOP_EQ          equ 2                   ; pass
WOP_GT          equ 4
WOP_NE          equ WOP_LT | WOP_GT
WOP_HAS         equ 8                   ; ~
WOP_NOT         equ 16                  ; !~

; COLUMN 'name', FT_* [, decimals [, unit]]: the next column of rec_tab.
; Preserves all but RAX (its index).
%macro COLUMN 2-4 0, 0
    [section .rodata]
    %%name: db %1, 0
    %%unit: db %4, 0
    __SECT__
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [%%name]
    mov esi, %2
    mov edx, %3
    lea rcx, [%%unit]
    call rec_col
    pop rdi
    pop rsi
    pop rdx
    pop rcx
%endmacro

; TOLOWER reg: A-Z to a-z
%macro TOLOWER 1
    cmp %1, 'A'
    jb %%kept
    cmp %1, 'Z'
    ja %%kept
    or %1, 0x20
%%kept:
%endmacro

section .text

; -----------------------------------------------------------------------------
;  Building a table
; -----------------------------------------------------------------------------

; rec_init -> CF (said so) if there is no memory for the table. Preserves all.
rec_init:
    push rax
    push rdi
    cmp qword [rec_tab], 0
    jne .tmp
    mov edi, TB_BYTES
    call vm_alloc
    test rax, rax
    jz .none
    mov [rec_tab], rax
    call rec_clear
.tmp:
    cmp qword [rec_tmp], 0
    jne .ok
    mov edi, TB_BYTES
    call vm_alloc
    test rax, rax
    jz .none
    mov [rec_tmp], rax
.ok:
    pop rdi
    pop rax
    clc
    ret
.none:
    KLOG "no memory for the shell's tables"
    pop rdi
    pop rax
    stc
    ret

; rec_clear: no columns, no rows. Preserves all.
rec_clear:
    push rax
    push rcx
    mov rax, [rec_tab]
    mov dword [rax + TB_NCOLS], 0
    mov dword [rax + TB_NROWS], 0
    mov dword [rax + TB_FLAGS], 0
    lea rcx, [rax + TB_HEAP0]
    mov [rax + TB_HEAP], rcx
    lea rcx, [rax + TB_BYTES]
    mov [rax + TB_END], rcx
    lea rax, [rec_dummy]
    mov [rec_at], rax
    pop rcx
    pop rax
    ret

; rec_flag(EDI = TBF_*): set on the table. Preserves all.
rec_flag:
    push rax
    mov rax, [rec_tab]
    or [rax + TB_FLAGS], edi
    pop rax
    ret

; rec_col(RDI = name, ESI = FT_*, EDX = decimals, RCX = unit, 0 for none)
; -> EAX = the new column (the last one, again, if there are 16 already).
; Preserves others.
rec_col:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, [rec_tab]
    mov eax, [rbx + TB_NCOLS]
    cmp eax, TB_MAX_COLS
    jb .room
    mov eax, TB_MAX_COLS - 1
    jmp .set
.room:
    inc dword [rbx + TB_NCOLS]
.set:
    push rax
    imul eax, eax, TCL_SIZE
    lea rbx, [rbx + TB_COLS + rax]
    mov [rbx + TCL_TYPE], sil
    mov [rbx + TCL_SCALE], dl
    mov dword [rbx + TCL_WIDTH], 0
    mov rsi, rdi
    lea rdi, [rbx + TCL_NAME]
    push rcx
    mov ecx, 16
    call rec_copyz
    pop rsi
    lea rdi, [rbx + TCL_UNIT]
    mov ecx, 8
    call rec_copyz
    pop rax
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rec_copyz(RDI = to, RSI = from or 0, ECX = room): at most room - 1 bytes,
; then a NUL. Preserves all.
rec_copyz:
    push rax
    push rcx
    push rsi
    push rdi
    dec ecx
    test rsi, rsi
    jz .end
.next:
    test ecx, ecx
    jz .end
    mov al, [rsi]
    test al, al
    jz .end
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .next
.end:
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; rec_row -> RAX = the new row's cells, zeroed, and the row rec_set fills;
; CF (and a row nobody sees) if the table is full. Preserves others.
rec_row:
    push rcx
    push rdi
    mov rax, [rec_tab]
    mov ecx, [rax + TB_NROWS]
    cmp ecx, TB_MAX_ROWS
    jae .full
    inc dword [rax + TB_NROWS]
    shl ecx, 7                          ; TB_ROW
    lea rdi, [rax + TB_ROWS + rcx]
    mov [rec_at], rdi
    push rdi
    xor eax, eax
    mov ecx, TB_ROW / 8
    rep stosq
    pop rax
    pop rdi
    pop rcx
    clc
    ret
.full:
    or dword [rax + TB_FLAGS], TBF_CUT
    lea rax, [rec_dummy]
    mov [rec_at], rax
    pop rdi
    pop rcx
    stc
    ret

; rec_set(EDI = column, RSI = value): into the row being filled. Preserves all.
rec_set:
    push rax
    push rdi
    mov edi, edi
    mov rax, [rec_at]
    mov [rax + rdi * 8], rsi
    pop rdi
    pop rax
    ret

; rec_none(EDI = column): no value there. Preserves all.
rec_none:
    push rsi
    mov rsi, NOVAL
    call rec_set
    pop rsi
    ret

; rec_strn(EDI = column, RSI = text, RDX = bytes): a copy of the text, into
; the row being filled. Preserves all.
rec_strn:
    push rax
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, [rec_tab]
    mov rax, [rbx + TB_HEAP]
    lea rcx, [rax + rdx + 1]
    cmp rcx, [rbx + TB_END]
    ja .full
    mov [rbx + TB_HEAP], rcx
    push rdi
    mov rdi, rax
    mov rcx, rdx
    rep movsb
    mov byte [rdi], 0
    pop rdi
    jmp .set
.full:
    or dword [rbx + TB_FLAGS], TBF_CUT
    lea rax, [rec_empty]
.set:
    mov edi, edi
    mov rcx, [rec_at]
    mov [rcx + rdi * 8], rax
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    pop rax
    ret

; rec_str(EDI = column, RSI = text, NUL-terminated). Preserves all.
rec_str:
    push rax
    push rdx
    push rdi
    mov rdi, rsi
    call strlen
    mov rdx, rax
    pop rdi
    call rec_strn
    pop rdx
    pop rax
    ret

; rec_capture_start: what the main thread prints becomes rows of a table of
; lines, until rec_capture_stop. Preserves all.
rec_capture_start:
    push rax
    call rec_clear
    COLUMN 'text', FT_TEXT
    push rdi
    mov edi, TBF_LINES
    call rec_flag
    pop rdi
    mov byte [rec_capturing], 1
    pop rax
    ret

rec_capture_stop:
    mov byte [rec_capturing], 0
    ret

; rec_capture(RDI = text kprint made): a row for each line of it. Under
; print_lock, with interrupts off. Preserves all.
rec_capture:
    push rax
    push rdx
    push rsi
    push rdi
    mov rsi, rdi
.line:
    cmp byte [rsi], 0
    je .out
    xor edx, edx
.scan:
    mov al, [rsi + rdx]
    test al, al
    jz .cut
    cmp al, 10
    je .cut
    inc edx
    jmp .scan
.cut:
    call rec_row
    jc .out
    xor edi, edi
    call rec_strn
    add rsi, rdx
    cmp byte [rsi], 10
    jne .line
    inc rsi
    jmp .line
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  A cell as text
; -----------------------------------------------------------------------------

; rec_column(EDI = column) -> RAX = its TC_* entry. Preserves others.
rec_column:
    push rdi
    mov edi, edi
    imul rdi, rdi, TCL_SIZE
    mov rax, [rec_tab]
    lea rax, [rax + TB_COLS + rdi]
    pop rdi
    ret

; rec_cell(EDI = column, RSI = value) -> RAX = it as text, RDX = its length:
; text as it is, the rest written into rec_cellbuf. Preserves others.
rec_cell:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    call rec_column
    mov rbx, rax
    movzx ecx, byte [rbx + TCL_TYPE]
    test ecx, ecx                       ; FT_TEXT
    jnz .value
    mov rax, rsi
    test rax, rax
    jnz .text
    lea rax, [rec_empty]
.text:
    mov r8, rax
    mov rdi, rax
    call strlen
    mov rdx, rax
    mov rax, r8
    jmp .out
.value:
    lea rdi, [rec_cellbuf]
    mov r8, NOVAL
    cmp rsi, r8
    je .none
    cmp ecx, FT_INT
    je .int
    cmp ecx, FT_SIZE
    je .size
    cmp ecx, FT_DUR
    je .dur
    cmp ecx, FT_TIME
    je .time
    cmp ecx, FT_HEX
    je .hex
    lea rax, [str_rec_yes]              ; FT_BOOL
    test rsi, rsi
    jnz .word
    lea rax, [str_rec_no]
.word:
    SPRINTF rdi, "%s", rax
    jmp .made
.none:
    SPRINTF rdi, "--"
    jmp .made
.int:
    movzx edx, byte [rbx + TCL_SCALE]
    call rec_fmt_int
    mov r8, rax
    lea rsi, [rbx + TCL_UNIT]
.unit:
    mov al, [rsi]
    mov [rdi + r8], al
    test al, al
    jz .unit_end
    inc rsi
    inc r8
    jmp .unit
.unit_end:
    mov rax, r8
    jmp .made
.size:
    SPRINTF rdi, "%b", rsi
    jmp .made
.dur:
    call rec_fmt_dur
    jmp .made
.time:
    mov ecx, ' '
    call rec_fmt_time
    jmp .made
.hex:
    cmp byte [rbx + TCL_SCALE], 0
    jne .hex_long
    SPRINTF rdi, "0x%x", rsi
    jmp .made
.hex_long:
    SPRINTF rdi, "%p", rsi
.made:
    mov rdx, rax
    lea rax, [rec_cellbuf]
.out:
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; rec_fmt_int(RDI = out, RSI = value, EDX = decimals, 0 to 3) -> RAX =
; length. Preserves others.
rec_fmt_int:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    sub rsp, 16
    mov ebx, edx
    cmp ebx, 3
    jbe .scaled
    mov ebx, 3
.scaled:
    test rsi, rsi
    jns .positive
    mov byte [rdi], '-'
    inc rdi
    neg rsi
.positive:
    mov rax, rsi
    xor edx, edx
    mov rcx, [rec_pow10 + rbx * 8]
    div rcx
    mov [rsp], rax
    mov [rsp + 8], rdx
    mov rsi, [rec_int_fmts + rbx * 8]
    mov rdx, rsp
    call format
    add rax, rdi
    sub rax, [rsp + 16]                 ; from where it began, the sign too
    add rsp, 16
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rec_fmt_dur(RDI = out, RSI = microseconds) -> RAX = length. Preserves
; others.
rec_fmt_dur:
    push rcx
    push rdx
    mov rax, rsi
    cmp rax, 1000
    jae .ms
    SPRINTF rdi, {"%u ", G_MICRO, "s"}, rax
    jmp .out
.ms:
    cmp rax, 1000000
    jae .s
    xor edx, edx
    mov ecx, 100
    div rcx
    SPRINTF rdi, "%t ms", rax
    jmp .out
.s:
    mov ecx, 60000000
    cmp rax, rcx
    jae .min
    xor edx, edx
    mov ecx, 100000
    div rcx
    SPRINTF rdi, "%t s", rax
    jmp .out
.min:
    mov ecx, 3600000000
    cmp rax, rcx
    jae .hours
    xor edx, edx
    mov ecx, 1000000
    div rcx
    xor edx, edx
    mov ecx, 60
    div rcx
    SPRINTF rdi, "%um %02us", rax, rdx
    jmp .out
.hours:
    xor edx, edx
    mov ecx, 60000000
    div rcx
    xor edx, edx
    mov ecx, 60
    div rcx
    SPRINTF rdi, "%uh %02um", rax, rdx
.out:
    pop rdx
    pop rcx
    ret

; rec_fmt_time(RDI = out, RSI = yyyymmddhhmm, ECX = what goes between the
; day and the hour) -> RAX = length. Preserves others.
rec_fmt_time:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    mov r11d, ecx
    mov rax, rsi
    mov ecx, 100
    xor edx, edx
    div rcx
    mov r10, rdx                        ; minute
    xor edx, edx
    div rcx
    mov r9, rdx                         ; hour
    xor edx, edx
    div rcx
    mov r8, rdx                         ; day
    xor edx, edx
    div rcx                             ; month in RDX, the year in RAX
    SPRINTF rdi, "%04u-%02u-%02u%c%02u:%02u", rax, rdx, r8, r11, r9, r10
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; rec_fat_time(EAX = a FAT date << 16 | time) -> RAX = yyyymmddhhmm.
; Preserves others.
rec_fat_time:
    push rcx
    push rdx
    push r8
    mov r8d, eax
    shr eax, 16                         ; the date
    mov ecx, eax
    shr ecx, 9
    add ecx, 1980
    imul rcx, rcx, 100
    mov edx, eax
    shr edx, 5
    and edx, 15
    add rcx, rdx
    imul rcx, rcx, 100
    and eax, 31
    add rcx, rax
    mov eax, r8d                        ; the time
    shr eax, 11
    and eax, 31
    imul rcx, rcx, 100
    add rcx, rax
    mov eax, r8d
    shr eax, 5
    and eax, 63
    imul rcx, rcx, 100
    add rcx, rax
    mov rax, rcx
    pop r8
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Lines: the table laid out
; -----------------------------------------------------------------------------

; rec_put(RSI = text, RCX = bytes): onto rec_line, as far as REC_LINE_MAX.
; Preserves all.
rec_put:
    push rax
    push rcx
    push rsi
    push rdi
    mov eax, [rec_len]
    lea rdi, [rec_line + rax]
.next:
    test rcx, rcx
    jz .out
    cmp eax, REC_LINE_MAX
    jae .out
    movsb
    inc eax
    dec rcx
    jmp .next
.out:
    mov [rec_len], eax
    mov byte [rdi], 0
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; rec_puts(RSI = text, NUL-terminated). Preserves all.
rec_puts:
    push rax
    push rcx
    push rdi
    mov rdi, rsi
    call strlen
    mov rcx, rax
    call rec_put
    pop rdi
    pop rcx
    pop rax
    ret

; rec_spaces(ECX = how many, none if not above 0). Preserves all.
rec_spaces:
    push rax
    push rcx
    mov eax, [rec_len]
.next:
    test ecx, ecx
    jle .out
    cmp eax, REC_LINE_MAX
    jae .out
    mov byte [rec_line + rax], ' '
    inc eax
    dec ecx
    jmp .next
.out:
    mov [rec_len], eax
    mov byte [rec_line + rax], 0
    pop rcx
    pop rax
    ret

; rec_begin: rec_line empty. Preserves all.
rec_begin:
    mov dword [rec_len], 0
    mov byte [rec_line], 0
    ret

; rec_cell_at(EDI = column, ESI = row) -> RSI = the cell's value. Preserves
; others.
rec_cell_at:
    push rax
    mov esi, esi
    shl rsi, 7
    mov rax, [rec_tab]
    lea rsi, [rax + TB_ROWS + rsi]
    mov eax, edi
    mov rsi, [rsi + rax * 8]
    pop rax
    ret

; rec_widths: each column's TCL_WIDTH, its name's or its widest cell's
rec_widths:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, [rec_tab]
    xor r12d, r12d
.col:
    cmp r12d, [rbx + TB_NCOLS]
    jae .out
    mov edi, r12d
    call rec_column
    mov r14, rax
    lea rdi, [r14 + TCL_NAME]
    call strlen
    mov [r14 + TCL_WIDTH], eax
    xor r13d, r13d
.row:
    cmp r13d, [rbx + TB_NROWS]
    jae .next
    mov edi, r12d
    mov esi, r13d
    call rec_cell_at
    call rec_cell
    cmp edx, REC_CELL_MAX
    jbe .fits
    mov edx, REC_CELL_MAX
.fits:
    cmp edx, [r14 + TCL_WIDTH]
    jbe .row_next
    mov [r14 + TCL_WIDTH], edx
.row_next:
    inc r13d
    jmp .row
.next:
    inc r12d
    jmp .col
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rec_build(EDI = row, -1 for the names; ESI = indent): rec_line, the
; columns at their widths, two spaces apart, numbers to the right
rec_build:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r15d, edi
    call rec_begin
    mov ecx, esi
    call rec_spaces
    mov rbx, [rec_tab]
    xor r12d, r12d
.col:
    cmp r12d, [rbx + TB_NCOLS]
    jae .out
    test r12d, r12d
    jz .first
    mov ecx, 2
    call rec_spaces
.first:
    mov edi, r12d
    call rec_column
    mov r14, rax
    cmp r15d, -1
    jne .cell
    lea rdi, [r14 + TCL_NAME]
    call strlen
    mov rdx, rax
    lea rax, [r14 + TCL_NAME]
    jmp .have
.cell:
    mov edi, r12d
    mov esi, r15d
    call rec_cell_at
    call rec_cell
.have:                                  ; RAX = the text, RDX = its length
    lea r13d, [r12d + 1]
    movzx edi, byte [r14 + TCL_TYPE]
    movzx edi, byte [rec_right + rdi]
    cmp r13d, [rbx + TB_NCOLS]
    je .last
    cmp edx, REC_CELL_MAX
    jbe .short
    mov edx, REC_CELL_MAX
.short:
    mov ecx, [r14 + TCL_WIDTH]
    sub ecx, edx                        ; the padding
    test edi, edi
    jz .left
    call rec_spaces
    mov rsi, rax
    push rcx
    mov rcx, rdx
    call rec_put
    pop rcx
    jmp .next
.left:
    mov rsi, rax
    push rcx
    mov rcx, rdx
    call rec_put
    pop rcx
    call rec_spaces
    jmp .next
.last:                                  ; nothing after it, but a number is
    test edi, edi                       ; still on the right
    jz .last_text
    mov ecx, [r14 + TCL_WIDTH]
    sub ecx, edx
    call rec_spaces
.last_text:
    mov rsi, rax
    mov rcx, rdx
    call rec_put
.next:
    inc r12d
    jmp .col
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rec_render(RDI = emit, ESI = indent): rec_tab, a line at a time, each one
; handed to emit(RDI = the line, ESI = what it is: 0 the names, 1 a row, 2 a
; note). emit keeps RBX, RBP and R12 to R15.
rec_render:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r15, rdi
    mov r14d, esi
    mov rbx, [rec_tab]
    cmp dword [rbx + TB_NCOLS], 0
    je .out
    test dword [rbx + TB_FLAGS], TBF_LINES
    jnz .lines
    cmp dword [rbx + TB_NROWS], 0
    je .none
    test dword [rbx + TB_FLAGS], TBF_RECORD
    jz .table
    cmp dword [rbx + TB_NROWS], 1
    je .record
.table:
    call rec_widths
    mov edi, -1
    mov esi, r14d
    call rec_build
    lea rdi, [rec_line]
    xor esi, esi
    call r15
    xor r12d, r12d
.row:
    cmp r12d, [rbx + TB_NROWS]
    jae .cut
    mov edi, r12d
    mov esi, r14d
    call rec_build
    lea rdi, [rec_line]
    mov esi, 1
    call r15
    inc r12d
    jmp .row
.lines:
    xor r12d, r12d
.line:
    cmp r12d, [rbx + TB_NROWS]
    jae .cut
    call rec_begin
    xor edi, edi
    mov esi, r12d
    call rec_cell_at
    call rec_cell
    mov rsi, rax
    mov rcx, rdx
    call rec_put
    lea rdi, [rec_line]
    mov esi, 1
    call r15
    inc r12d
    jmp .line
.record:
    xor r13d, r13d                      ; the longest name
    xor r12d, r12d
.measure:
    cmp r12d, [rbx + TB_NCOLS]
    jae .fields
    mov edi, r12d
    call rec_column
    lea rdi, [rax + TCL_NAME]
    call strlen
    cmp eax, r13d
    jbe .measured
    mov r13d, eax
.measured:
    inc r12d
    jmp .measure
.fields:
    xor r12d, r12d
.field:
    cmp r12d, [rbx + TB_NCOLS]
    jae .cut
    call rec_begin
    mov ecx, r14d
    call rec_spaces
    mov edi, r12d
    call rec_column
    lea rsi, [rax + TCL_NAME]
    call rec_puts
    mov rdi, rsi
    call strlen
    mov ecx, r13d
    sub ecx, eax
    add ecx, 2
    call rec_spaces
    mov edi, r12d
    xor esi, esi
    call rec_cell_at
    call rec_cell
    mov rsi, rax
    mov rcx, rdx
    call rec_put
    lea rdi, [rec_line]
    mov esi, 1
    call r15
    inc r12d
    jmp .field
.none:
    call rec_begin
    mov ecx, r14d
    call rec_spaces
    lea rsi, [str_rec_none]
    call rec_puts
    lea rdi, [rec_line]
    mov esi, 2
    call r15
.cut:
    test dword [rbx + TB_FLAGS], TBF_CUT
    jz .out
    mov eax, [rbx + TB_NROWS]
    lea rdi, [rec_line]
    SPRINTF rdi, "(cut short: more than there was room for; %u rows kept)", rax
    mov esi, 2
    call r15
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; rec_show_line(RDI = line, ESI = what it is): to the terminal and the log,
; the names in the accent colour, notes dim
rec_show_line:
    cmp esi, 1
    je .plain
    push rdi
    mov edi, COL_ACCENT
    test esi, esi
    jz .colour
    mov edi, COL_DIM
.colour:
    call con_set_color
    pop rdi
    KLOG "%s", rdi
    push rdi
    mov edi, COL_TEXT
    call con_set_color
    pop rdi
    ret
.plain:
    KLOG "%s", rdi
    ret

; rec_plain_line(RDI = line): as it is ('to text' on the terminal)
rec_plain_line:
    KLOG "%s", rdi
    ret

; rec_file_line(RDI = line): onto rec_out, with a newline
rec_file_line:
    push rax
    push rsi
    mov rsi, rdi
    call rec_out_text
    mov al, 10
    call rec_out_byte
    pop rsi
    pop rax
    ret

; rec_show: the table as the end of a command line shows it
rec_show:
    push rbx
    mov rbx, [rec_tab]
    cmp dword [rbx + TB_NCOLS], 0
    je .out
    test dword [rbx + TB_FLAGS], TBF_JSON
    jnz .json
    lea rdi, [rec_plain_line]
    xor esi, esi
    test dword [rbx + TB_FLAGS], TBF_TEXT
    jnz .render
    lea rdi, [rec_show_line]
    mov esi, 2
.render:
    call rec_render
    jmp .out
.json:
    mov rdi, [rec_tmp]                  ; as glyphs, for the terminal
    mov esi, TB_BYTES
    xor edx, edx
    call rec_out_start
    call rec_json
    mov rsi, [rec_tmp]
    mov rcx, [rec_out]
    sub rcx, rsi
    call rec_print
.out:
    pop rbx
    ret

; rec_print(RSI = text, RCX = bytes): to the terminal a line at a time, a
; long one in pieces. Preserves all.
rec_print:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [rec_line]
    xor edx, edx
.next:
    test rcx, rcx
    jz .last
    lodsb
    dec rcx
    cmp al, 10
    je .line
    mov [rdi + rdx], al
    inc edx
    cmp edx, REC_CHUNK
    jb .next
.line:
    mov byte [rdi + rdx], 0
    KLOG "%s", rdi
    xor edx, edx
    jmp .next
.last:
    test edx, edx
    jz .out
    mov byte [rdi + rdx], 0
    KLOG "%s", rdi
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; rec_write(RDI = buffer, RSI = its size) -> RAX = bytes: the table as a
; file is given it, as text or JSON, in UTF-8; CF if it did not all fit
rec_write:
    push rbx
    push rdi
    mov edx, 1
    call rec_out_start
    mov rbx, [rec_tab]
    test dword [rbx + TB_FLAGS], TBF_JSON
    jnz .json
    lea rdi, [rec_file_line]
    xor esi, esi
    call rec_render
    jmp .done
.json:
    call rec_json
.done:
    pop rdi
    mov rax, [rec_out]
    sub rax, rdi
    cmp byte [rec_out_full], 0
    je .fits
    stc
    jmp .out
.fits:
    clc
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  rec_out: text being written into a buffer
; -----------------------------------------------------------------------------

; rec_out_start(RDI = buffer, RSI = its size, EDX = 1 for glyphs as UTF-8).
; Preserves all.
rec_out_start:
    push rax
    mov [rec_out], rdi
    lea rax, [rdi + rsi]
    mov [rec_out_end], rax
    mov [rec_out_utf8], dl
    mov byte [rec_out_full], 0
    pop rax
    ret

; rec_out_byte(AL). Preserves all.
rec_out_byte:
    push rdi
    mov rdi, [rec_out]
    cmp rdi, [rec_out_end]
    jae .full
    mov [rdi], al
    inc qword [rec_out]
    pop rdi
    ret
.full:
    mov byte [rec_out_full], 1
    pop rdi
    ret

; rec_out_char(AL): a byte, or a glyph as UTF-8 if rec_out_utf8 says so.
; Preserves all.
rec_out_char:
    cmp al, 128
    jb rec_out_byte
    cmp byte [rec_out_utf8], 0
    je rec_out_byte
    push rax
    push rsi
    lea rsi, [serial_utf8]
.find:
    cmp byte [rsi], 0
    je .unknown
    cmp [rsi], al
    je .found
    add rsi, 4
    jmp .find
.found:
    mov al, [rsi + 1]
    call rec_out_byte
    mov al, [rsi + 2]
    call rec_out_byte
    mov al, [rsi + 3]
    test al, al
    jz .out
    call rec_out_byte
    jmp .out
.unknown:
    mov al, '?'
    call rec_out_byte
.out:
    pop rsi
    pop rax
    ret

; rec_out_text(RSI = text, NUL-terminated). Preserves all.
rec_out_text:
    push rax
    push rsi
.next:
    mov al, [rsi]
    test al, al
    jz .out
    call rec_out_char
    inc rsi
    jmp .next
.out:
    pop rsi
    pop rax
    ret

; rec_json: rec_tab as a JSON array of objects, onto rec_out
rec_json:
    push rbx
    push r12
    push r13
    mov rbx, [rec_tab]
    mov al, '['
    call rec_out_byte
    xor r12d, r12d
.row:
    cmp r12d, [rbx + TB_NROWS]
    jae .end
    test r12d, r12d
    jz .first
    mov al, ','
    call rec_out_byte
.first:
    lea rsi, [str_rec_json_open]
    call rec_out_text
    xor r13d, r13d
.field:
    cmp r13d, [rbx + TB_NCOLS]
    jae .close
    test r13d, r13d
    jz .name
    lea rsi, [str_rec_json_sep]
    call rec_out_text
.name:
    mov edi, r13d
    call rec_column
    lea rsi, [rax + TCL_NAME]
    call rec_json_string
    lea rsi, [str_rec_json_colon]
    call rec_out_text
    mov edi, r13d
    mov esi, r12d
    call rec_cell_at
    call rec_json_value
    inc r13d
    jmp .field
.close:
    mov al, '}'
    call rec_out_byte
    inc r12d
    jmp .row
.end:
    test r12d, r12d
    jz .empty
    mov al, 10
    call rec_out_byte
.empty:
    mov al, ']'
    call rec_out_byte
    mov al, 10
    call rec_out_byte
    pop r13
    pop r12
    pop rbx
    ret

; rec_json_value(EDI = column, RSI = value): as JSON, onto rec_out. Sizes in
; bytes, durations in milliseconds, times as 2026-10-17T14:05, hex as a
; string, no value as null. Preserves all.
rec_json_value:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    call rec_column
    mov rbx, rax
    movzx ecx, byte [rbx + TCL_TYPE]
    test ecx, ecx
    jnz .value
    test rsi, rsi
    jnz .text
    lea rsi, [rec_empty]
.text:
    call rec_json_string
    jmp .out
.value:
    mov rax, NOVAL
    cmp rsi, rax
    je .null
    lea rdi, [rec_valbuf]
    cmp ecx, FT_INT
    je .int
    cmp ecx, FT_SIZE
    je .size
    cmp ecx, FT_DUR
    je .dur
    cmp ecx, FT_TIME
    je .time
    cmp ecx, FT_HEX
    je .hex
    lea rax, [str_rec_true]             ; FT_BOOL
    test rsi, rsi
    jnz .word
    lea rax, [str_rec_false]
.word:
    mov rsi, rax
    jmp .put
.null:
    lea rsi, [str_rec_null]
    jmp .put
.int:
    movzx edx, byte [rbx + TCL_SCALE]
    call rec_fmt_int
    jmp .made
.size:
    SPRINTF rdi, "%u", rsi
    jmp .made
.dur:
    mov edx, 3
    call rec_fmt_int
    jmp .made
.time:
    mov byte [rdi], '"'
    inc rdi
    mov ecx, 'T'
    call rec_fmt_time
    mov word [rdi + rax], '"'           ; and the NUL
    jmp .made
.hex:
    SPRINTF rdi, '"0x%x"', rsi
.made:
    lea rsi, [rec_valbuf]
.put:
    call rec_out_text
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; rec_json_string(RSI = text): quoted, escaped, onto rec_out. Preserves all.
rec_json_string:
    push rax
    push rsi
    mov al, '"'
    call rec_out_byte
.next:
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, '"'
    je .escape
    cmp al, '\'
    je .escape
    cmp al, ' '
    jb .control
    call rec_out_char
    jmp .step
.escape:
    push rax
    mov al, '\'
    call rec_out_byte
    pop rax
    call rec_out_byte
    jmp .step
.control:
    push rsi
    push rax
    lea rsi, [str_rec_json_u]
    call rec_out_text
    pop rax
    push rax
    shr al, 4
    movzx esi, al
    mov al, [hex_digits + rsi]
    call rec_out_byte
    pop rax
    push rax
    and al, 15
    movzx esi, al
    mov al, [hex_digits + rsi]
    call rec_out_byte
    pop rax
    pop rsi
.step:
    inc rsi
    jmp .next
.end:
    mov al, '"'
    call rec_out_byte
    pop rsi
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Text: comparing and matching, case aside
; -----------------------------------------------------------------------------

; rec_icmp(RDI = a, RSI = b; either may be 0 for none) -> EAX = -1, 0 or 1,
; case aside. Preserves others.
rec_icmp:
    push rcx
    push rdx
    push rsi
    push rdi
    test rdi, rdi
    jnz .a
    lea rdi, [rec_empty]
.a:
    test rsi, rsi
    jnz .next
    lea rsi, [rec_empty]
.next:
    movzx eax, byte [rdi]
    movzx edx, byte [rsi]
    TOLOWER eax
    TOLOWER edx
    cmp eax, edx
    jb .less
    ja .more
    test eax, eax
    jz .same
    inc rdi
    inc rsi
    jmp .next
.less:
    mov eax, -1
    jmp .out
.more:
    mov eax, 1
    jmp .out
.same:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rec_ieq(RDI, RSI) -> EAX = 1 if they are the same, case aside. Preserves
; others.
rec_ieq:
    call rec_icmp
    test eax, eax
    setz al
    movzx eax, al
    ret

; glob_match(RDI = pattern, RSI = text) -> EAX = 1 if the pattern matches
; all of the text, case aside: * any run of characters, ? any one.
; Preserves others.
glob_match:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    xor r8d, r8d                        ; just after the last *, in the pattern
    xor r9d, r9d                        ; and the text it was tried from
.next:
    movzx ecx, byte [rsi]
    test ecx, ecx
    jz .text_end
    movzx edx, byte [rdi]
    cmp edx, '*'
    je .star
    cmp edx, '?'
    je .one
    TOLOWER ecx
    TOLOWER edx
    cmp ecx, edx
    jne .back
.one:
    inc rdi
    inc rsi
    jmp .next
.star:
    inc rdi
    mov r8, rdi
    mov r9, rsi
    jmp .next
.back:
    test r8, r8
    jz .no
    mov rdi, r8
    inc r9
    mov rsi, r9
    jmp .next
.text_end:
    cmp byte [rdi], '*'
    jne .end
    inc rdi
    jmp .text_end
.end:
    cmp byte [rdi], 0
    jne .no
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; rec_wild(RDI = text) -> EAX = 1 if it has a * or a ?. Preserves others.
rec_wild:
    push rdi
.next:
    mov al, [rdi]
    test al, al
    jz .no
    cmp al, '*'
    je .yes
    cmp al, '?'
    je .yes
    inc rdi
    jmp .next
.yes:
    mov eax, 1
    pop rdi
    ret
.no:
    xor eax, eax
    pop rdi
    ret

; rec_contains(RDI = part, RSI = text) -> EAX = 1 if the text has the part
; in it, case aside. Preserves others.
rec_contains:
    push rcx
    push rdx
    push rsi
    push r8
    push r9
.start:
    mov r8, rdi
    mov r9, rsi
.compare:
    movzx ecx, byte [r8]
    test ecx, ecx
    jz .yes
    movzx edx, byte [r9]
    test edx, edx
    jz .no
    TOLOWER ecx
    TOLOWER edx
    cmp ecx, edx
    jne .shift
    inc r8
    inc r9
    jmp .compare
.shift:
    inc rsi
    jmp .start
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    ret

; rec_match(RDI = what was asked, RSI = text) -> EAX = 1 if it matches: as
; a pattern if it has * or ?, else if the text contains it. Preserves others.
rec_match:
    call rec_wild
    test eax, eax
    jnz glob_match
    jmp rec_contains

; -----------------------------------------------------------------------------
;  Values: compared, and read from what was typed
; -----------------------------------------------------------------------------

; rec_compare(EDI = FT_*, RSI = a, RDX = b) -> EAX = -1, 0 or 1; CF if
; either has no value. Preserves others.
rec_compare:
    push rdi
    push rsi
    push rdx
    test edi, edi
    jz .text
    mov rax, NOVAL
    cmp rsi, rax
    je .none
    cmp rdx, rax
    je .none
    cmp edi, FT_INT
    je .signed
    cmp rsi, rdx
    jb .less
    ja .more
    jmp .same
.signed:
    cmp rsi, rdx
    jl .less
    jg .more
.same:
    xor eax, eax
    jmp .out
.less:
    mov eax, -1
    clc
    jmp .out
.more:
    mov eax, 1
    clc
    jmp .out
.none:
    stc
    jmp .out
.text:
    mov rdi, rsi
    mov rsi, rdx
    call rec_icmp
    clc
.out:
    pop rdx
    pop rsi
    pop rdi
    ret

; rec_order(EDI = FT_*, RSI = a, RDX = b) -> EAX = -1, 0 or 1, no value
; first. Preserves others.
rec_order:
    call rec_compare
    jnc .out
    push rcx
    mov rax, NOVAL
    xor ecx, ecx
    cmp rsi, rax
    jne .a
    dec ecx
.a:
    cmp rdx, rax
    jne .b
    inc ecx
.b:
    mov eax, ecx                        ; both none: 0; a none: -1; b: 1
    pop rcx
.out:
    ret

; rec_uint(RSI = text) -> RAX = the decimal number there, RSI = after it;
; CF if there is none. Preserves others.
rec_uint:
    push rcx
    push rdx
    xor eax, eax
    xor edx, edx
.next:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .end
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    inc edx
    jmp .next
.end:
    test edx, edx
    jz .none
    clc
    jmp .out
.none:
    stc
.out:
    pop rdx
    pop rcx
    ret

; rec_decimal(RSI = text) -> RAX = the whole part, RDX = what follows the
; point, in millionths, RSI = after it; CF if there are no digits.
; Preserves others.
rec_decimal:
    push rcx
    push r8
    push r9
    xor eax, eax
    xor r9d, r9d                        ; digits
.whole:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .point
    imul rax, rax, 10
    add rax, rcx
    inc rsi
    inc r9d
    jmp .whole
.point:
    xor edx, edx
    mov r8d, 100000                     ; what the next digit is worth
    cmp byte [rsi], '.'
    jne .end
    inc rsi
.fraction:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .end
    imul ecx, r8d
    add edx, ecx
    push rax
    push rdx
    mov eax, r8d
    xor edx, edx
    mov ecx, 10
    div ecx
    mov r8d, eax
    pop rdx
    pop rax
    inc rsi
    inc r9d
    jmp .fraction
.end:
    test r9d, r9d
    jz .none
    clc
    jmp .out
.none:
    stc
.out:
    pop r9
    pop r8
    pop rcx
    ret

; rec_parse(EDI = FT_*, ESI = decimals, RDX = text) -> RAX = the value it
; reads as; CF if it is not one. Sizes take K, M, G, T (KB, KiB too);
; durations us, ms (the default), s, m, h; times yyyy-mm-dd[Thh:mm]; yes or
; no. Preserves others.
rec_parse:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov ebx, edi
    mov r8d, esi
    mov rsi, rdx
    cmp ebx, FT_HEX
    je .hex
    cmp ebx, FT_BOOL
    je .bool
    cmp ebx, FT_TIME
    je .time
    xor r10d, r10d                      ; negative
    cmp byte [rsi], '-'
    jne .number
    cmp ebx, FT_INT
    jne .bad
    inc rsi
    mov r10d, 1
.number:
    call rec_decimal
    jc .bad
    cmp ebx, FT_INT
    je .int
    lea r9, [rec_size_units]
    cmp ebx, FT_SIZE
    je .unit
    lea r9, [rec_dur_units]
.unit:
    mov rdi, [r9]
    test rdi, rdi
    jz .bad
    push rax
    call rec_ieq
    mov ecx, eax
    pop rax
    test ecx, ecx
    jnz .scale
    add r9, 16
    jmp .unit
.scale:
    mov rcx, [r9 + 8]                   ; what one is worth
    push rdx
    mul rcx
    mov rdi, rax
    pop rax                             ; the millionths
    mul rcx
    mov ecx, 1000000
    div rcx
    add rax, rdi
    jmp .ok
.int:
    cmp r8d, 3
    jbe .decimals
    mov r8d, 3
.decimals:
    push rdx
    mov rcx, [rec_pow10 + r8 * 8]
    mul rcx
    mov rdi, rax
    pop rax                             ; the millionths, to that many decimals
    mov ecx, 6
    sub ecx, r8d
    mov rcx, [rec_pow10 + rcx * 8]
    xor edx, edx
    div rcx
    add rax, rdi
    test r10d, r10d
    jz .ok
    neg rax
    jmp .ok
.hex:
    call arg_hex
    jc .bad
    jmp .ok
.bool:
    lea r9, [rec_bool_words]
.bool_next:
    mov rdi, [r9]
    test rdi, rdi
    jz .bad
    call rec_ieq
    test eax, eax
    jnz .bool_found
    add r9, 16
    jmp .bool_next
.bool_found:
    mov rax, [r9 + 8]
    jmp .ok
.time:
    call rec_uint                       ; the year
    jc .bad
    mov r9, rax
    cmp byte [rsi], '-'
    jne .bad
    inc rsi
    call rec_uint                       ; the month
    jc .bad
    imul r9, r9, 100
    add r9, rax
    cmp byte [rsi], '-'
    jne .bad
    inc rsi
    call rec_uint                       ; the day
    jc .bad
    imul r9, r9, 100
    add r9, rax
    imul r9, r9, 10000
    mov al, [rsi]
    test al, al
    jz .time_done
    cmp al, 'T'
    je .clock
    cmp al, 't'
    je .clock
    cmp al, ' '
    jne .bad
.clock:
    inc rsi
    call rec_uint                       ; the hour
    jc .bad
    imul rax, rax, 100
    add r9, rax
    cmp byte [rsi], ':'
    jne .bad
    inc rsi
    call rec_uint                       ; the minute
    jc .bad
    add r9, rax
    cmp byte [rsi], 0
    jne .bad
.time_done:
    mov rax, r9
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rec_field(RDI = a field's name) -> EAX = its column; CF (said so, with the
; fields there are) if there is none. Preserves others.
rec_field:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rsi, rdi
    mov rbx, [rec_tab]
    xor ecx, ecx
.next:
    cmp ecx, [rbx + TB_NCOLS]
    jae .none
    mov edi, ecx
    call rec_column
    lea rdi, [rax + TCL_NAME]
    call rec_ieq
    test eax, eax
    jnz .found
    inc ecx
    jmp .next
.found:
    mov eax, ecx
    clc
    jmp .out
.none:
    call rec_begin
    push rsi
    lea rsi, [str_rec_nofield]
    call rec_puts
    pop rsi
    call rec_puts
    lea rsi, [str_rec_fields]
    cmp dword [rbx + TB_NCOLS], 0
    jne .list
    lea rsi, [str_rec_nofields]
.list:
    call rec_puts
    xor ecx, ecx
.name:
    cmp ecx, [rbx + TB_NCOLS]
    jae .said
    test ecx, ecx
    jz .first
    lea rsi, [str_rec_comma]
    call rec_puts
.first:
    mov edi, ecx
    call rec_column
    lea rsi, [rax + TCL_NAME]
    call rec_puts
    inc ecx
    jmp .name
.said:
    lea rax, [rec_line]
    KLOG "%s", rax
    stc
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Stages: each takes the words after its name (EDI = how many, RSI = them)
;  and changes rec_tab; CF (said why) if it cannot
; -----------------------------------------------------------------------------

; rec_stage_of(RDI = a word) -> RAX = the stage of that name, 0 if none.
; Preserves others.
rec_stage_of:
    push rbx
    push rsi
    mov rsi, rdi
    lea rbx, [rec_stages]
.next:
    mov rdi, [rbx]
    test rdi, rdi
    jz .none
    call rec_ieq
    test eax, eax
    jnz .found
    add rbx, 16
    jmp .next
.found:
    mov rax, [rbx + 8]
    jmp .out
.none:
    xor eax, eax
.out:
    mov rdi, rsi
    pop rsi
    pop rbx
    ret

; rec_stage(EDI = words, RSI = them, the first the stage's name) -> CF
rec_stage:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    mov rbx, [rec_tab]
    test dword [rbx + TB_FLAGS], TBF_TEXT | TBF_JSON
    jnz .after_to
    mov rdi, [r13]
    call rec_stage_of
    test rax, rax
    jz .unknown
    lea edi, [r12d - 1]
    lea rsi, [r13 + 8]
    call rax
    jmp .out
.after_to:
    KLOG "'to' comes last: nothing can come after it"
    stc
    jmp .out
.unknown:
    mov rax, [r13]
    KLOG "'%s' is not a stage; after a | come where, sort, pick, first, last, count and to", rax
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; where <field> <op> <value>
st_where:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    cmp edi, 3
    jne .usage
    mov r12, rsi
    mov rdi, [r12]
    call rec_field
    jc .fail
    mov r13d, eax                       ; the column
    mov rsi, [r12 + 8]
    lea rbx, [rec_ops]
.op:
    mov rdi, [rbx]
    test rdi, rdi
    jz .bad_op
    call streq
    test eax, eax
    jnz .op_found
    add rbx, 16
    jmp .op
.op_found:
    mov r14, [rbx + 8]                  ; WOP_*
    mov r15, [r12 + 16]                 ; the value: as typed,
    test r14d, WOP_HAS | WOP_NOT
    jnz .scan
    mov edi, r13d
    call rec_column
    mov rbp, rax
    movzx edi, byte [rbp + TCL_TYPE]
    test edi, edi
    jz .scan
    movzx esi, byte [rbp + TCL_SCALE]
    mov rdx, r15
    call rec_parse                      ; or read as the field's type
    jc .bad_value
    mov r15, rax
.scan:
    mov rbx, [rec_tab]
    xor r12d, r12d                      ; the row looked at
    xor ebp, ebp                        ; rows kept
.row:
    cmp r12d, [rbx + TB_NROWS]
    jae .done
    mov edi, r13d
    mov esi, r12d
    call rec_cell_at
    mov edx, r14d
    mov rcx, r15
    call rec_pass
    jnc .next
    cmp ebp, r12d
    je .kept
    mov eax, ebp
    shl eax, 7
    lea rdi, [rbx + TB_ROWS + rax]
    mov eax, r12d
    shl eax, 7
    lea rsi, [rbx + TB_ROWS + rax]
    mov ecx, TB_ROW / 8
    rep movsq
.kept:
    inc ebp
.next:
    inc r12d
    jmp .row
.done:
    mov [rbx + TB_NROWS], ebp
    clc
    jmp .out
.usage:
    KLOG "usage: where <field> <op> <value>; op is = != < > <= >= ~ (has, or matches * ?) !~"
    jmp .fail
.bad_op:
    mov rax, [r12 + 8]
    KLOG "where: '%s' is not a comparison; there are = != < > <= >= ~ !~", rax
    jmp .fail
.bad_value:
    movzx eax, byte [rbp + TCL_TYPE]
    mov rax, [rec_type_names + rax * 8]
    lea rcx, [rbp + TCL_NAME]
    KLOG "where: %s takes %s; '%s' is not one", rcx, rax, r15
.fail:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; rec_pass(EDI = column, RSI = a cell, EDX = WOP_*, RCX = the value) -> CF
; if the cell passes. Preserves all but RAX.
rec_pass:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov r8d, edx
    mov r9, rcx
    test r8d, WOP_HAS | WOP_NOT
    jnz .has
    call rec_column
    movzx edi, byte [rax + TCL_TYPE]
    mov rdx, r9
    call rec_compare
    jc .none
    inc eax                             ; 0, 1, 2: <, =, >
    bt r8d, eax
    jmp .out
.none:
    cmp r8d, WOP_NE
    je .yes
    jmp .no
.has:
    call rec_cell
    mov rsi, rax
    mov rdi, r9
    call rec_match
    test r8d, WOP_NOT
    jz .said
    xor eax, 1
.said:
    test eax, eax
    jnz .yes
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; sort <field> [down]: stable
st_sort:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    test edi, edi
    jz .usage
    cmp edi, 2
    ja .usage
    mov r12, rsi
    mov byte [rs_down], 0
    cmp edi, 2
    jne .field
    mov rdi, [r12 + 8]
    lea rsi, [str_rec_down]
    call rec_ieq
    test eax, eax
    jz .usage
    mov byte [rs_down], 1
.field:
    mov rdi, [r12]
    call rec_field
    jc .fail
    mov [rs_col], eax
    mov edi, eax
    call rec_column
    movzx eax, byte [rax + TCL_TYPE]
    mov [rs_type], eax
    mov rbx, [rec_tab]
    mov r10d, [rbx + TB_NROWS]          ; n
    cmp r10d, 2
    jb .done
    mov r8, [rec_tmp]                   ; the order so far,
    lea r9, [r8 + TB_MAX_ROWS * 4]      ; and the next
    xor eax, eax
.fill:
    mov [r8 + rax * 4], eax
    inc eax
    cmp eax, r10d
    jb .fill
    mov r11d, 1                         ; the width of the runs merged
.pass:
    cmp r11d, r10d
    jae .sorted
    xor r12d, r12d                      ; i
.pair:
    cmp r12d, r10d
    jae .passed
    lea r13d, [r12d + r11d]             ; mid
    cmp r13d, r10d
    jbe .mid
    mov r13d, r10d
.mid:
    lea r14d, [r13d + r11d]             ; hi
    cmp r14d, r10d
    jbe .hi
    mov r14d, r10d
.hi:
    mov r15d, r12d                      ; l
    mov ebp, r13d                       ; r
    mov ebx, r12d                       ; k
.merge:
    cmp ebx, r14d
    jae .merged
    cmp r15d, r13d
    jae .right
    cmp ebp, r14d
    jae .left
    mov eax, [r8 + r15 * 4]
    mov ecx, [r8 + rbp * 4]
    call rs_before                      ; does the right one go first?
    jc .right
.left:
    mov eax, [r8 + r15 * 4]
    mov [r9 + rbx * 4], eax
    inc r15d
    inc ebx
    jmp .merge
.right:
    mov eax, [r8 + rbp * 4]
    mov [r9 + rbx * 4], eax
    inc ebp
    inc ebx
    jmp .merge
.merged:
    lea r12d, [r12d + r11d * 2]
    jmp .pair
.passed:
    xchg r8, r9
    shl r11d, 1
    jmp .pass
.sorted:                                ; the rows, in that order
    mov rbx, [rec_tab]
    mov rdx, [rec_tmp]
    add rdx, TB_MAX_ROWS * 8
    xor r12d, r12d
.gather:
    cmp r12d, r10d
    jae .gathered
    mov eax, [r8 + r12 * 4]
    shl eax, 7
    lea rsi, [rbx + TB_ROWS + rax]
    mov eax, r12d
    shl eax, 7
    lea rdi, [rdx + rax]
    mov ecx, TB_ROW / 8
    rep movsq
    inc r12d
    jmp .gather
.gathered:
    mov rsi, rdx
    lea rdi, [rbx + TB_ROWS]
    mov ecx, r10d
    shl ecx, 4                          ; TB_ROW / 8 qwords a row
    rep movsq
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: sort <field> [down]"
.fail:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; rs_before(EAX = a row, ECX = a row after it) -> CF if the second goes
; first, as sort is asked. Preserves all.
rs_before:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, [rs_col]
    mov esi, ecx
    call rec_cell_at
    mov rdx, rsi                        ; b
    mov esi, eax
    call rec_cell_at                    ; a
    xchg rsi, rdx                       ; b against a
    mov edi, [rs_type]
    call rec_order
    cmp byte [rs_down], 0
    jne .down
    cmp eax, 0
    jl .yes
    jmp .no
.down:
    cmp eax, 0
    jg .yes
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; pick <field>...: those columns, in that order
st_pick:
    push rbx
    push r12
    push r13
    push r14
    test edi, edi
    jz .usage
    cmp edi, TB_MAX_COLS
    ja .usage
    mov r12, rsi
    mov r13d, edi
    xor r14d, r14d
.find:
    cmp r14d, r13d
    jae .found
    mov rdi, [r12 + r14 * 8]
    call rec_field
    jc .fail
    mov [rp_map + r14 * 4], eax
    inc r14d
    jmp .find
.found:
    mov rbx, [rec_tab]
    lea rsi, [rbx + TB_COLS]            ; the columns as they were
    lea rdi, [rp_cols]
    mov ecx, TB_MAX_COLS * TCL_SIZE / 8
    rep movsq
    xor r14d, r14d
.column:
    cmp r14d, r13d
    jae .columns
    mov eax, [rp_map + r14 * 4]
    imul eax, eax, TCL_SIZE
    lea rsi, [rp_cols + rax]
    imul eax, r14d, TCL_SIZE
    lea rdi, [rbx + TB_COLS + rax]
    mov ecx, TCL_SIZE / 8
    rep movsq
    inc r14d
    jmp .column
.columns:
    mov [rbx + TB_NCOLS], r13d
    xor r12d, r12d                      ; each row
.row:
    cmp r12d, [rbx + TB_NROWS]
    jae .done
    mov eax, r12d
    shl eax, 7
    lea rdx, [rbx + TB_ROWS + rax]
    mov rsi, rdx
    lea rdi, [rp_row]
    mov ecx, TB_ROW / 8
    rep movsq
    xor r14d, r14d
.cell:
    cmp r14d, r13d
    jae .row_next
    mov eax, [rp_map + r14 * 4]
    mov rax, [rp_row + rax * 8]
    mov [rdx + r14 * 8], rax
    inc r14d
    jmp .cell
.row_next:
    inc r12d
    jmp .row
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: pick <field>... (as many as 16)"
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; first <n>
st_first:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    call arg_uint
    jc .usage
    mov rcx, [rec_tab]
    cmp eax, [rcx + TB_NROWS]
    jae .out
    mov [rcx + TB_NROWS], eax
.out:
    clc
    ret
.usage:
    KLOG "usage: first <how many>"
    stc
    ret

; last <n>
st_last:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    call arg_uint
    jc .usage
    mov rdx, [rec_tab]
    mov ecx, [rdx + TB_NROWS]
    cmp eax, ecx
    jae .out
    sub ecx, eax                        ; the rows that go
    mov [rdx + TB_NROWS], eax
    shl ecx, 7
    lea rsi, [rdx + TB_ROWS + rcx]
    lea rdi, [rdx + TB_ROWS]
    mov ecx, eax
    shl ecx, 4
    rep movsq
.out:
    clc
    ret
.usage:
    KLOG "usage: last <how many>"
    stc
    ret

; count: how many rows
st_count:
    test edi, edi
    jnz .usage
    push rbx
    mov rbx, [rec_tab]
    mov esi, [rbx + TB_NROWS]
    mov eax, [rbx + TB_FLAGS]
    and eax, TBF_CUT
    or eax, TBF_LINES
    mov [rbx + TB_FLAGS], eax
    mov dword [rbx + TB_NCOLS], 0
    mov dword [rbx + TB_NROWS], 0
    COLUMN 'count', FT_INT
    call rec_row
    xor edi, edi
    call rec_set
    pop rbx
    clc
    ret
.usage:
    KLOG "usage: count (it takes nothing)"
    stc
    ret

; to text | to json: what a file is given, or the terminal shown, at the end
st_to:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    lea rdi, [str_rec_text]
    call rec_ieq
    test eax, eax
    jnz .text
    lea rdi, [str_rec_json]
    call rec_ieq
    test eax, eax
    jz .usage
    mov edi, TBF_JSON
    jmp .set
.text:
    mov edi, TBF_TEXT
.set:
    call rec_flag
    clc
    ret
.usage:
    KLOG "usage: to text | to json"
    stc
    ret

section .rodata
str_rec_yes:        db 'yes', 0
str_rec_no:         db 'no', 0
str_rec_true:       db 'true', 0
str_rec_false:      db 'false', 0
str_rec_null:       db 'null', 0
str_rec_none:       db '(none)', 0
str_rec_down:       db 'down', 0
str_rec_text:       db 'text', 0
str_rec_json:       db 'json', 0
str_rec_json_open:  db 10, '  {', 0
str_rec_json_sep:   db ', ', 0
str_rec_json_colon: db ': ', 0
str_rec_json_u:     db '\u00', 0
str_rec_nofield:    db 'no field ', 0x27, 0
str_rec_fields:     db 0x27, ' here; the fields are: ', 0
str_rec_nofields:   db 0x27, ' here: there are no fields', 0
str_rec_comma:      db ', ', 0
str_rec_t_text:     db 'text', 0
str_rec_t_int:      db 'a number', 0
str_rec_t_size:     db 'a size (4K, 2M, 1.5G)', 0
str_rec_t_dur:      db 'a duration (250us, 10ms, 2s, 5m)', 0
str_rec_t_time:     db 'a time (2026-10-17, 2026-10-17T14:05)', 0
str_rec_t_hex:      db 'hex', 0
str_rec_t_bool:     db 'yes or no', 0
ru_none:            db 0
ru_b:               db 'b', 0
ru_k:               db 'k', 0
ru_kb:              db 'kb', 0
ru_kib:             db 'kib', 0
ru_m:               db 'm', 0
ru_mb:              db 'mb', 0
ru_mib:             db 'mib', 0
ru_g:               db 'g', 0
ru_gb:              db 'gb', 0
ru_gib:             db 'gib', 0
ru_t:               db 't', 0
ru_tb:              db 'tb', 0
ru_tib:             db 'tib', 0
ru_us:              db 'us', 0
ru_micro:           db G_MICRO, 's', 0
ru_ms:              db 'ms', 0
ru_s:               db 's', 0
ru_min:             db 'min', 0
ru_h:               db 'h', 0
rb_yes:             db 'yes', 0
rb_no:              db 'no', 0
rb_on:              db 'on', 0
rb_off:             db 'off', 0
rb_1:               db '1', 0
rb_0:               db '0', 0
ro_eq:              db '=', 0
ro_eq2:             db '==', 0
ro_ne:              db '!=', 0
ro_lt:              db '<', 0
ro_gt:              db '>', 0
ro_le:              db '<=', 0
ro_ge:              db '>=', 0
ro_has:             db '~', 0
ro_not:             db '!~', 0
fmt_ri0:            db '%u', 0
fmt_ri1:            db '%u.%01u', 0
fmt_ri2:            db '%u.%02u', 0
fmt_ri3:            db '%u.%03u', 0
rec_right:          db 0, 1, 1, 1, 0, 1, 0  ; by FT_*: numbers to the right
rec_empty:          db 0
align 8
rec_pow10:          dq 1, 10, 100, 1000, 10000, 100000, 1000000
rec_int_fmts:       dq fmt_ri0, fmt_ri1, fmt_ri2, fmt_ri3
rec_type_names:     dq str_rec_t_text, str_rec_t_int, str_rec_t_size, str_rec_t_dur
                    dq str_rec_t_time, str_rec_t_hex, str_rec_t_bool
rec_size_units:     dq ru_none, 1, ru_b, 1
                    dq ru_k, 1 << 10, ru_kb, 1 << 10, ru_kib, 1 << 10
                    dq ru_m, 1 << 20, ru_mb, 1 << 20, ru_mib, 1 << 20
                    dq ru_g, 1 << 30, ru_gb, 1 << 30, ru_gib, 1 << 30
                    dq ru_t, 1 << 40, ru_tb, 1 << 40, ru_tib, 1 << 40
                    dq 0, 0
rec_dur_units:      dq ru_none, 1000, ru_ms, 1000, ru_us, 1, ru_micro, 1
                    dq ru_s, 1000000, ru_m, 60000000, ru_min, 60000000
                    dq ru_h, 3600000000
                    dq 0, 0
rec_bool_words:     dq rb_yes, 1, rb_no, 0, str_rec_true, 1, str_rec_false, 0
                    dq rb_on, 1, rb_off, 0, rb_1, 1, rb_0, 0
                    dq 0, 0
rec_ops:            dq ro_eq, WOP_EQ, ro_eq2, WOP_EQ, ro_ne, WOP_NE
                    dq ro_lt, WOP_LT, ro_gt, WOP_GT, ro_le, WOP_LT | WOP_EQ
                    dq ro_ge, WOP_GT | WOP_EQ, ro_has, WOP_HAS, ro_not, WOP_NOT
                    dq 0, 0

%macro STAGE 2                          ; name, handler
    dq %%name, %2
    [section .rodata]
    %%name: db %1, 0
    __SECT__
%endmacro

section .data                           ; (not .rodata: the names go there)
align 8
rec_stages:
    STAGE 'where', st_where
    STAGE 'sort', st_sort
    STAGE 'pick', st_pick
    STAGE 'first', st_first
    STAGE 'last', st_last
    STAGE 'count', st_count
    STAGE 'to', st_to
    dq 0, 0

section .bss
alignb 8
rec_tab:        resq 1                  ; the table
rec_tmp:        resq 1                  ; scratch as big
rec_at:         resq 1                  ; the row being filled
rec_out:        resq 1                  ; text being written: where next,
rec_out_end:    resq 1                  ; and where the room ends
rs_col:         resd 1                  ; sort: the column,
rs_type:        resd 1                  ; its type,
rec_len:        resd 1                  ; rec_line's length
rp_map:         resd TB_MAX_COLS        ; pick: the columns, as they were
rs_down:        resb 1                  ; and which way
rec_capturing:  resb 1                  ; kprint's lines go to rec_capture
rec_out_utf8:   resb 1
rec_out_full:   resb 1
alignb 8
rp_cols:        resb TB_MAX_COLS * TCL_SIZE
rp_row:         resb TB_ROW
rec_dummy:      resb TB_ROW             ; a row that did not fit goes here
rec_cellbuf:    resb 320
rec_valbuf:     resb 64
rec_line:       resb REC_LINE_MAX + 24
