; =============================================================================
;  compose/calc.inc - a grid's numbers and formulas
;
;  What is typed into a cell is kept as it was typed (CE_TEXT); its value
;  (CE_KIND, CE_VAL, CE_VLEN) is a number, text, an error, or nothing. A
;  formula begins with '=':
;    numbers, "text", A1 and $A$1, TRUE, FALSE; ( ); unary - and +;
;    * /; + - and & (text joined); = <> < > <= >=, each 1 or 0;
;    SUM, AVERAGE, MIN, MAX, COUNT (numbers, and ranges like A1:C4), IF(c,
;    a[, b]), ABS(x), ROUND(x[, digits]); names in any case.
;  Errors: #DIV/0!, #VALUE!, #REF!, #NAME?, #CYCLE!, #ERROR! (it cannot be
;  read), #NUM!.
;
;  Recalculation is by dependency: a cell set is marked dirty, then every
;  formula that refers to a dirty cell, until none is left to mark; then
;  each dirty formula is evaluated, and a reference to a dirty formula
;  evaluates that one first (depth first, so each is evaluated once, after
;  what it depends on; a cell met again on its own path is #CYCLE!). This
;  runs on a stack of its own, deep enough for a chain through every cell.
;    cell_set(RDI = a grid, ESI = row, EDX = column, RCX = text, R8D = its
;      bytes) -> CF if there is no memory: kept, its value worked out, and
;      what depends on it recalculated. calc_count: how many were.
;    grid_recalc(RDI = a grid): every formula in it, again
;    cell_show(RDI = a cell, RSI = 32 bytes) -> RSI = its value as text, ECX
;      its bytes, EAX = 1 if it is a number (shown at the right). Preserves
;      RBX, RBP, R12-R15.
;    num_parse(RSI = text, ECX = bytes) -> XMM0 = the number, CF if the text
;      is not one (spaces around it allowed; a % after it is a hundredth)
;    num_format(XMM0, RDI = 32 bytes) -> EAX = the bytes written: an integer
;      as one, else up to 10 significant digits, E notation past them
;    ref_name(ESI = row, EDX = column, RDI = to) -> EAX = bytes ("B3")
; =============================================================================

VK_EMPTY        equ 0
VK_NUM          equ 1
VK_TEXT         equ 2
VK_ERR          equ 3

ER_DIV0         equ 1
ER_VALUE        equ 2
ER_REF          equ 3
ER_NAME         equ 4
ER_CYCLE        equ 5
ER_SYNTAX       equ 6
ER_NUM          equ 7

CALC_STACK      equ 8 << 20

section .text

; --- numbers -----------------------------------------------------------------

num_parse:
    push rbx
    push r12
    lea r8, [rsi + rcx]                 ; R8: the end
.lead:
    cmp rsi, r8
    jae .no
    cmp byte [rsi], ' '
    jne .sign
    inc rsi
    jmp .lead
.sign:
    xor r12d, r12d                      ; R12D: 1 if negative
    cmp byte [rsi], '-'
    jne .plus
    mov r12d, 1
    inc rsi
    jmp .mant
.plus:
    cmp byte [rsi], '+'
    jne .mant
    inc rsi
.mant:
    xor eax, eax                        ; RAX: the digits; EBX: the exponent
    xor ebx, ebx                        ; R9D: digits seen; R10D: past the point
    xor r9d, r9d
    xor r10d, r10d
.digit:
    cmp rsi, r8
    jae .end_mant
    movzx ecx, byte [rsi]
    cmp ecx, '.'
    je .point
    sub ecx, '0'
    cmp ecx, 9
    ja .end_mant
    inc r9d
    mov rdx, 100000000000000000         ; past 18 digits, only the scale
    cmp rax, rdx
    jae .drop
    imul rax, rax, 10
    add rax, rcx
    sub ebx, r10d
    inc rsi
    jmp .digit
.drop:
    test r10d, r10d
    jnz .dropped
    inc ebx
.dropped:
    inc rsi
    jmp .digit
.point:
    test r10d, r10d
    jnz .no
    mov r10d, 1
    inc rsi
    jmp .digit
.end_mant:
    test r9d, r9d
    jz .no
    cmp rsi, r8                         ; an exponent?
    jae .scale
    movzx ecx, byte [rsi]
    or ecx, 0x20
    cmp ecx, 'e'
    jne .scale
    lea rdx, [rsi + 1]
    xor r11d, r11d                      ; R11D: 1 if it is negative
    cmp rdx, r8
    jae .no
    cmp byte [rdx], '-'
    jne .eplus
    mov r11d, 1
    inc rdx
    jmp .edigits
.eplus:
    cmp byte [rdx], '+'
    jne .edigits
    inc rdx
.edigits:
    xor r9d, r9d                        ; R9D: the exponent; R10D: digits
    xor r10d, r10d
.edigit:
    cmp rdx, r8
    jae .eend
    movzx ecx, byte [rdx]
    sub ecx, '0'
    cmp ecx, 9
    ja .eend
    imul r9d, r9d, 10
    add r9d, ecx
    inc r10d
    inc rdx
    cmp r9d, 10000
    jb .edigit
    jmp .no
.eend:
    test r10d, r10d
    jz .no
    test r11d, r11d
    jz .epos
    neg r9d
.epos:
    add ebx, r9d
    mov rsi, rdx
.scale:
    cvtsi2sd xmm0, rax
    mov edi, ebx
    call scale10
    cmp rsi, r8                         ; a percentage?
    jae .signed
    cmp byte [rsi], '%'
    jne .trail
    inc rsi
    mov edi, -2
    call scale10
.trail:
    cmp rsi, r8
    jae .signed
    cmp byte [rsi], ' '
    jne .no
    inc rsi
    jmp .trail
.signed:
    test r12d, r12d
    jz .yes
    call negate
.yes:
    pop r12
    pop rbx
    clc
    ret
.no:
    pop r12
    pop rbx
    stc
    ret

; scale10(XMM0, EDI = a power of ten) -> XMM0 * 10^EDI. Preserves all but
; RAX, RCX, RDI, XMM1.
scale10:
    test edi, edi
    jz .out
    js .down
.up:
    mov ecx, edi
    cmp ecx, 22
    jbe .up_one
    mov ecx, 22
.up_one:
    sub edi, ecx
    lea rax, [pow10]
    mulsd xmm0, [rax + rcx * 8]
    test edi, edi
    jnz .up
    ret
.down:
    neg edi
.down_more:
    mov ecx, edi
    cmp ecx, 22
    jbe .down_one
    mov ecx, 22
.down_one:
    sub edi, ecx
    lea rax, [pow10]
    divsd xmm0, [rax + rcx * 8]
    test edi, edi
    jnz .down_more
.out:
    ret

; negate: XMM0 = -XMM0. Preserves all but XMM1.
negate:
    xorpd xmm1, xmm1
    subsd xmm1, xmm0
    movapd xmm0, xmm1
    ret

num_format:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi                        ; R12: where it starts
    movq rax, xmm0
    mov rcx, rax                        ; NaN or infinity: #NUM!
    shr rcx, 52
    and ecx, 0x7FF
    cmp ecx, 0x7FF
    je .nan
    btr rax, 63                         ; negative, and not -0
    jnc .abs
    mov rcx, rax
    test rcx, rcx
    jz .abs
    mov byte [rdi], '-'
    inc rdi
.abs:
    mov [num_dst], rdi                  ; where the digits go
    movq xmm0, rax                      ; XMM0: |x|
    test rax, rax
    jz .zero
    movsd xmm1, [big15]                 ; an integer under 10^15: as one
    comisd xmm0, xmm1
    jae .sci
    cvttsd2si rax, xmm0
    cvtsi2sd xmm1, rax
    ucomisd xmm1, xmm0
    je .integer
    movsd xmm1, [tiny5]                 ; under 10^-5: E notation
    comisd xmm0, xmm1
    jb .sci
    xor ebx, ebx                        ; EBX: its exponent, 10^EBX <= |x|
    lea r8, [pow10]
.exp_up:
    lea ecx, [rbx + 1]
    movsd xmm1, [r8 + rcx * 8]
    comisd xmm0, xmm1
    jb .exp_found
    inc ebx
    jmp .exp_up
.exp_found:
    movsd xmm1, [one]
    comisd xmm0, xmm1
    jae .fixed
.exp_down:                              ; under 1: down from there
    dec ebx
    mov ecx, ebx
    neg ecx
    movsd xmm1, [one]
    divsd xmm1, [r8 + rcx * 8]
    comisd xmm0, xmm1
    jb .exp_down
.fixed:
    mov r13d, 9                         ; R13D: decimals, for 10 digits
    sub r13d, ebx
    jns .dec_low
    xor r13d, r13d
.dec_low:
    cmp r13d, 15
    jle .dec_ok
    mov r13d, 15
.dec_ok:
    mov edi, r13d                       ; the digits, rounded
    call scale10
    addsd xmm0, [half]
    cvttsd2si rax, xmm0
    mov r14, rax
    lea rdi, [num_tmp + 31]             ; written backwards: the decimals, then the rest
    xor ecx, ecx
    xor edx, edx                        ; EDX: 1 once a digit is kept
.dec_digit:
    cmp ecx, r13d
    jae .dec_done
    mov rax, r14
    xor edx, edx
    mov r9, 10
    div r9
    mov r14, rax
    cmp byte [num_keep], 0
    jne .keep
    test edx, edx
    jz .skip_zero
    mov byte [num_keep], 1
.keep:
    add dl, '0'
    mov [rdi], dl
    dec rdi
.skip_zero:
    inc ecx
    jmp .dec_digit
.dec_done:
    cmp byte [num_keep], 0
    je .int_part
    mov byte [rdi], '.'
    dec rdi
.int_part:
    mov byte [num_keep], 0
    mov rax, r14
.int_digit:
    xor edx, edx
    mov r9, 10
    div r9
    add dl, '0'
    mov [rdi], dl
    dec rdi
    test rax, rax
    jnz .int_digit
    inc rdi
    lea rsi, [rdi]
    lea rcx, [num_tmp + 32]
    sub rcx, rsi
    mov rdi, [num_dst]
    rep movsb
    mov rax, rdi
    sub rax, r12
    jmp .out
.zero:
    mov rdi, r12
    mov byte [rdi], '0'
    mov eax, 1
    jmp .out
.integer:
    lea rsi, [num_tmp + 32]
    mov r9, 10
.i_digit:
    xor edx, edx
    div r9
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .i_digit
    lea rcx, [num_tmp + 32]
    sub rcx, rsi
    rep movsb
    mov rax, rdi
    sub rax, r12
    jmp .out
.sci:                                   ; d.ddddddE+n
    xor ebx, ebx
    lea r8, [pow10]
    movsd xmm1, [one]
    comisd xmm0, xmm1
    jb .sci_small
.sci_big:
    movsd xmm1, [ten]
    comisd xmm0, xmm1
    jb .sci_m
    divsd xmm0, xmm1
    inc ebx
    jmp .sci_big
.sci_small:
    mulsd xmm0, [ten]
    dec ebx
    movsd xmm1, [one]
    comisd xmm0, xmm1
    jb .sci_small
.sci_m:
    mov r13, rdi                        ; R13: where the mantissa goes
    mov edi, 6
    call scale10
    addsd xmm0, [half]
    cvttsd2si rax, xmm0                 ; 7 digits: 1000000..9999999
    cmp rax, 10000000
    jb .sci_digits
    mov eax, 1000000
    inc ebx
.sci_digits:
    lea rsi, [num_tmp + 32]
    mov r9, 10
    mov ecx, 6
.sci_frac:
    xor edx, edx
    div r9
    add dl, '0'
    dec rsi
    mov [rsi], dl
    dec ecx
    jnz .sci_frac
    add al, '0'                         ; RAX: the first digit
    mov rdi, r13
    mov [rdi], al
    inc rdi
    lea rcx, [num_tmp + 32]             ; the fraction, its zeros at the end dropped
.trim:
    cmp rcx, rsi
    je .no_frac
    cmp byte [rcx - 1], '0'
    jne .frac
    dec rcx
    jmp .trim
.frac:
    mov byte [rdi], '.'
    inc rdi
    sub rcx, rsi
    rep movsb
.no_frac:
    mov byte [rdi], 'E'
    inc rdi
    mov al, '+'
    test ebx, ebx
    jns .esign
    mov al, '-'
    neg ebx
.esign:
    mov [rdi], al
    inc rdi
    cmp ebx, 100
    jb .e_two
    mov eax, ebx
    xor edx, edx
    mov r9d, 100
    div r9d
    mov ebx, edx
    add al, '0'
    mov [rdi], al
    inc rdi
    jmp .e_tens
.e_two:
    cmp ebx, 10
    jb .e_one
.e_tens:
    mov eax, ebx
    xor edx, edx
    mov r9d, 10
    div r9d
    mov ebx, edx
    add al, '0'
    mov [rdi], al
    inc rdi
.e_one:
    lea eax, [rbx + '0']
    mov [rdi], al
    inc rdi
    mov rax, rdi
    sub rax, r12
    jmp .out
.nan:
    mov rdi, r12
    lea rsi, [s_err_num]
    mov ecx, 5
    rep movsb
    mov eax, 5
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

ref_name:
    lea eax, [rdx + 'A']
    mov [rdi], al
    lea eax, [rsi + 1]
    push rdi
    inc rdi
    mov ecx, 10
    push rbx
    lea rbx, [num_tmp + 16]
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test eax, eax
    jnz .digit
.copy:
    mov al, [rbx]
    mov [rdi], al
    inc rdi
    inc rbx
    lea rax, [num_tmp + 16]
    cmp rbx, rax
    jb .copy
    pop rbx
    mov rax, rdi
    pop rdi
    sub rax, rdi
    ret

; --- cells ---------------------------------------------------------------------

cell_set:
    push rbx
    mov rbx, rdi
    mov dword [calc_count], 0
    call cell_put
    jc .out
    or byte [rax + CE_FLAGS], CF_DIRTY
    mov rdi, rbx
    call calc_spread
    mov rdi, rbx
    call calc_dirty
    clc
.out:
    pop rbx
    ret

; cell_put(RDI = a grid, ESI = row, EDX = column, RCX = text, R8D = bytes)
; -> RAX = the cell, its text kept and its kind known, nothing recalculated;
; CF if there is no memory
cell_put:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13d, esi
    mov r14d, edx
    mov r15, rcx
    mov ebx, r8d
    call cell_at
    push rax
    mov edi, ebx                        ; a copy of the text
    call da_alloc
    mov rdi, rax
    pop rax
    test rdi, rdi
    jnz .copy
    test ebx, ebx
    jnz .nomem
.copy:
    mov [rax + CE_TEXT], rdi
    mov [rax + CE_LEN], ebx
    mov rsi, r15
    mov ecx, ebx
    rep movsb
    mov rdi, rax
    call cell_classify
    lea ecx, [r13 + 1]                  ; the table grows to hold it
    test ebx, ebx
    jz .grown
    cmp ecx, [r12 + GR_ROWS]
    jbe .rows
    mov [r12 + GR_ROWS], ecx
.rows:
    lea ecx, [r14 + 1]
    cmp ecx, [r12 + GR_COLS]
    jbe .grown
    mov [r12 + GR_COLS], ecx
.grown:
    mov rax, rdi
    clc
    jmp .out
.nomem:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; cell_classify(RDI = a cell): a formula, a number, text or nothing, from
; what was typed. Preserves RBX, RBP, R12-R15, RDI.
cell_classify:
    and byte [rdi + CE_FLAGS], ~CF_FORMULA
    mov byte [rdi + CE_KIND], VK_EMPTY
    mov ecx, [rdi + CE_LEN]
    test ecx, ecx
    jz .out
    mov rsi, [rdi + CE_TEXT]
    cmp byte [rsi], '='
    jne .number
    cmp ecx, 1
    je .text
    or byte [rdi + CE_FLAGS], CF_FORMULA
    ret
.number:
    push rdi
    call num_parse
    pop rdi
    jc .text
    mov byte [rdi + CE_KIND], VK_NUM
    movsd [rdi + CE_VAL], xmm0
    ret
.text:
    mov byte [rdi + CE_KIND], VK_TEXT
    mov rax, [rdi + CE_TEXT]
    mov [rdi + CE_VAL], rax
    mov eax, [rdi + CE_LEN]
    mov [rdi + CE_VLEN], eax
.out:
    ret

grid_recalc:
    push rbx
    mov rbx, rdi
    mov dword [calc_count], 0
    lea rdi, [rbx + GR_CELLS]
    mov ecx, MAXR * MAXC
.cell:
    and byte [rdi + CE_FLAGS], ~(CF_DIRTY | CF_BUSY)
    test byte [rdi + CE_FLAGS], CF_FORMULA
    jz .next
    or byte [rdi + CE_FLAGS], CF_DIRTY
.next:
    add rdi, CE_SIZE
    dec ecx
    jnz .cell
    mov rdi, rbx
    call calc_dirty
    pop rbx
    ret

; calc_spread(RDI = a grid): every formula referring to a dirty cell marked
; dirty too, until there are no more
calc_spread:
    push rbx
    push r12
    push r13
    mov rbx, rdi
.again:
    xor r13d, r13d                      ; R13D: marked this time round
    lea r12, [rbx + GR_CELLS]
.cell:
    test byte [r12 + CE_FLAGS], CF_FORMULA
    jz .next
    test byte [r12 + CE_FLAGS], CF_DIRTY
    jnz .next
    mov rdi, rbx
    mov rsi, r12
    call refs_dirty
    jnc .next
    or byte [r12 + CE_FLAGS], CF_DIRTY
    inc r13d
.next:
    add r12, CE_SIZE
    lea rax, [rbx + GR_SIZE]
    cmp r12, rax
    jb .cell
    test r13d, r13d
    jnz .again
    pop r13
    pop r12
    pop rbx
    ret

; refs_dirty(RDI = a grid, RSI = a formula's cell) -> CF if it refers to a
; dirty cell, alone or in a range
refs_dirty:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov r12, [rsi + CE_TEXT]            ; R12: at; R13: the end
    mov r13d, [rsi + CE_LEN]
    add r13, r12
.scan:
    cmp r12, r13
    jae .clean
    movzx eax, byte [r12]
    cmp eax, '"'
    je .string
    call ref_start
    jnc .ref
    inc r12
    jmp .scan
.string:
    inc r12
.in_string:
    cmp r12, r13
    jae .clean
    cmp byte [r12], '"'
    je .string_end
    inc r12
    jmp .in_string
.string_end:
    inc r12
    jmp .scan
.ref:
    mov rsi, r12
    mov rdx, r13
    call ref_read
    jc .word                            ; a name, not a reference
    mov r12, rsi
    mov r14d, eax                       ; R14D, R15D: the first cell
    mov r15d, edx
    mov r8d, eax                        ; R8D, R9D: the last
    mov r9d, edx
    cmp r12, r13
    jae .check
    cmp byte [r12], ':'
    jne .check
    lea rsi, [r12 + 1]
    mov rdx, r13
    call ref_read
    jc .check
    mov r12, rsi
    mov r8d, eax
    mov r9d, edx
.check:
    call range_order
    cmp r8d, MAXR
    jb .rows_in
    mov r8d, MAXR - 1
.rows_in:
    cmp r9d, MAXC
    jb .cols_in
    mov r9d, MAXC - 1
.cols_in:
    mov ecx, r14d                       ; ECX: the row
.row:
    cmp ecx, r8d
    ja .scan
    mov edx, r15d                       ; EDX: the column
.col:
    cmp edx, r9d
    ja .next_row
    mov rdi, rbx
    mov esi, ecx
    call cell_at
    test byte [rax + CE_FLAGS], CF_DIRTY
    jnz .dirty
    inc edx
    jmp .col
.next_row:
    inc ecx
    jmp .row
.word:                                  ; past the letters of a name
    inc r12
.word_more:
    cmp r12, r13
    jae .clean
    movzx eax, byte [r12]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .scan
    inc r12
    jmp .word_more
.dirty:
    stc
    jmp .out
.clean:
    clc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; range_order: R14D, R15D to R8D, R9D (rows, columns) put in order.
; Preserves all.
range_order:
    cmp r14d, r8d
    jbe .rows
    xchg r14d, r8d
.rows:
    cmp r15d, r9d
    jbe .out
    xchg r15d, r9d
.out:
    ret

; ref_start(EAX = a byte) -> CF clear if a reference or a name could start
; with it. Preserves all.
ref_start:
    cmp eax, '$'
    je .yes
    push rax
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    pop rax
    ja .no
.yes:
    clc
    ret
.no:
    stc
    ret

; ref_read(RSI = at, RDX = the end) -> EAX = row, EDX = column, RSI past
; it; CF (RSI as it was) if no reference starts there. A reference is a
; column's letters and a row's digits, each maybe after a $, with neither a
; letter, a digit nor '(' after it. A column past Z, or row 0, is MAXR.
; Preserves all but RAX, RCX, RDX, RSI.
ref_read:
    push rbx
    push r8
    mov r8, rsi
    xor ebx, ebx                        ; EBX: the column, 1-based
    xor ecx, ecx                        ; ECX: its letters
    cmp rsi, rdx
    jae .no
    cmp byte [rsi], '$'
    jne .letters
    inc rsi
.letters:
    cmp rsi, rdx
    jae .no
    movzx eax, byte [rsi]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .end_letters
    imul ebx, ebx, 26
    lea ebx, [rbx + rax + 1]
    inc ecx
    inc rsi
    cmp ecx, 3
    ja .no
    jmp .letters
.end_letters:
    test ecx, ecx
    jz .no
    cmp byte [rsi], '$'
    jne .digits
    inc rsi
.digits:
    xor eax, eax                        ; EAX: the row, 1-based
    xor ecx, ecx
.digit:
    cmp rsi, rdx
    jae .end_digits
    push rbx
    movzx ebx, byte [rsi]
    sub ebx, '0'
    cmp ebx, 9
    ja .not_digit
    imul eax, eax, 10
    add eax, ebx
    pop rbx
    inc ecx
    inc rsi
    cmp eax, 100000
    jb .digit
    jmp .no
.not_digit:
    pop rbx
.end_digits:
    test ecx, ecx
    jz .no
    cmp rsi, rdx                        ; nothing after it that makes it a name
    jae .yes
    movzx ecx, byte [rsi]
    cmp ecx, '('
    je .no
    cmp ecx, '_'
    je .no
    push rcx
    or ecx, 0x20
    sub ecx, 'a'
    cmp ecx, 25
    pop rcx
    jbe .no
.yes:
    dec eax                             ; 0-based, past the edge as MAXR
    cmp eax, MAXR
    jb .row_ok
    mov eax, MAXR
.row_ok:
    lea edx, [rbx - 1]
    cmp edx, MAXC
    jb .col_ok
    mov eax, MAXR
.col_ok:
    pop r8
    pop rbx
    clc
    ret
.no:
    mov rsi, r8
    pop r8
    pop rbx
    stc
    ret

; calc_dirty(RDI = a grid): each dirty formula evaluated, on the calculation
; stack; what is dirty and not a formula is clean
calc_dirty:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    mov [calc_rsp], rsp
    mov rsp, [calc_stack_top]
    lea r12, [rbx + GR_CELLS]
.cell:
    test byte [r12 + CE_FLAGS], CF_DIRTY
    jz .next
    test byte [r12 + CE_FLAGS], CF_FORMULA
    jnz .formula
    and byte [r12 + CE_FLAGS], ~CF_DIRTY
    jmp .next
.formula:
    mov rdi, rbx
    mov rsi, r12
    call cell_eval
.next:
    add r12, CE_SIZE
    lea rax, [rbx + GR_SIZE]
    cmp r12, rax
    jb .cell
    mov rsp, [calc_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; cell_eval(RDI = a grid, RSI = a dirty formula's cell): evaluated, clean
cell_eval:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    inc dword [calc_count]
    or byte [r12 + CE_FLAGS], CF_BUSY
    push r12                            ; the cell, for after an unwind
    push qword [fx_p]                   ; what an outer evaluation was at
    push qword [fx_e]
    push qword [fx_grid]
    push qword [fx_rsp]
    push qword [fx_skip]
    mov [fx_grid], rdi
    mov rax, [r12 + CE_TEXT]
    lea rcx, [rax + 1]                  ; past the '='
    mov [fx_p], rcx
    mov ecx, [r12 + CE_LEN]
    add rax, rcx
    mov [fx_e], rax
    mov qword [fx_skip], 0
    mov [fx_rsp], rsp
    call fx_expr
    push rcx
    push rax
    call fx_ws
    mov rcx, [fx_p]                     ; anything left over: it cannot be read
    cmp rcx, [fx_e]
    pop rax
    pop rcx
    jb fx_syntax
.got:                                   ; (fx_syntax comes back here)
    mov r12, [rsp + 40]
    mov [r12 + CE_KIND], al
    cmp eax, VK_TEXT
    je .text
    cmp eax, VK_ERR
    je .err
    cmp eax, VK_EMPTY
    je .empty
    movsd [r12 + CE_VAL], xmm0
    jmp .done
.empty:                                 ; a formula's nothing is 0
    mov byte [r12 + CE_KIND], VK_NUM
    xorpd xmm0, xmm0
    movsd [r12 + CE_VAL], xmm0
    jmp .done
.text:
    mov [r12 + CE_VAL], rdx
    mov [r12 + CE_VLEN], ecx
    jmp .done
.err:
    mov [r12 + CE_ERR], dl
.done:
    pop qword [fx_skip]
    pop qword [fx_rsp]
    pop qword [fx_grid]
    pop qword [fx_e]
    pop qword [fx_p]
    pop r12
    and byte [r12 + CE_FLAGS], ~(CF_DIRTY | CF_BUSY)
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fx_syntax: the formula cannot be read; back to cell_eval with #ERROR!
fx_syntax:
    mov rsp, [fx_rsp]
    mov eax, VK_ERR
    mov edx, ER_SYNTAX
    jmp cell_eval.got

; --- the evaluator ---------------------------------------------------------------
; Each fx_* reads from fx_p and returns a value: EAX = VK_*, XMM0 = a
; number, RDX = text and ECX its bytes (VK_TEXT), EDX = ER_* (VK_ERR). While
; fx_skip is not 0 it only reads (an IF's other branch). They preserve RBX,
; RBP, R12-R15.

fx_ws:
    mov rcx, [fx_p]
.at:
    cmp rcx, [fx_e]
    jae .out
    cmp byte [rcx], ' '
    jne .out
    inc rcx
    jmp .at
.out:
    mov [fx_p], rcx
    ret

; fx_peek -> EAX = the next byte past spaces, or 0 at the end
fx_peek:
    call fx_ws
    xor eax, eax
    mov rcx, [fx_p]
    cmp rcx, [fx_e]
    jae .out
    movzx eax, byte [rcx]
.out:
    ret

; a value held across another's evaluation: [rsp] kind, +8 number, +16 text,
; +24 bytes
%macro FX_HOLD 0
    sub rsp, 32
    mov [rsp], rax
    movsd [rsp + 8], xmm0
    mov [rsp + 16], rdx
    mov [rsp + 24], rcx
%endmacro

fx_expr:
    call fx_add
    FX_HOLD
    call fx_peek
    xor r8d, r8d                        ; R8D: the comparison, 1-6
    cmp eax, '='
    je .eq
    cmp eax, '<'
    je .lt
    cmp eax, '>'
    je .gt
    mov rax, [rsp]                      ; none: the value held
    movsd xmm0, [rsp + 8]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    add rsp, 32
    ret
.eq:
    mov r8d, 1
    inc qword [fx_p]
    jmp .right
.lt:
    inc qword [fx_p]
    mov r8d, 2                          ; <
    mov rcx, [fx_p]
    cmp rcx, [fx_e]
    jae .right
    cmp byte [rcx], '='
    jne .lt_ne
    mov r8d, 3                          ; <=
    inc qword [fx_p]
    jmp .right
.lt_ne:
    cmp byte [rcx], '>'
    jne .right
    mov r8d, 6                          ; <>
    inc qword [fx_p]
    jmp .right
.gt:
    inc qword [fx_p]
    mov r8d, 4                          ; >
    mov rcx, [fx_p]
    cmp rcx, [fx_e]
    jae .right
    cmp byte [rcx], '='
    jne .right
    mov r8d, 5                          ; >=
    inc qword [fx_p]
.right:
    push r8
    sub rsp, 8
    call fx_add
    add rsp, 8
    pop r8
    cmp dword [rsp], VK_ERR
    je .left_err
    cmp eax, VK_ERR
    je .done
    call fx_compare                     ; EAX: -1, 0, 1
    xor ecx, ecx
    cmp r8d, 1
    je .is_eq
    cmp r8d, 2
    je .is_lt
    cmp r8d, 3
    je .is_le
    cmp r8d, 4
    je .is_gt
    cmp r8d, 5
    je .is_ge
    test eax, eax                       ; <>
    setnz cl
    jmp .bool
.is_eq:
    test eax, eax
    setz cl
    jmp .bool
.is_lt:
    cmp eax, 0
    setl cl
    jmp .bool
.is_le:
    cmp eax, 0
    setle cl
    jmp .bool
.is_gt:
    cmp eax, 0
    setg cl
    jmp .bool
.is_ge:
    cmp eax, 0
    setge cl
.bool:
    cvtsi2sd xmm0, ecx
    mov eax, VK_NUM
    jmp .done
.left_err:
    mov eax, VK_ERR
    mov rdx, [rsp + 16]
.done:
    add rsp, 32
    ret

; fx_compare: the value its caller holds at [RSP] (here [RSP + 8]) against
; EAX, XMM0, RDX, ECX -> EAX = -1, 0 or 1. Numbers (and nothing, as 0)
; before text; text by its letters, whatever their case.
fx_compare:
    mov r9d, [rsp + 8]                  ; R9D: the left's kind
    cmp r9d, VK_EMPTY                   ; nothing: "" beside text, else 0
    jne .left_kind
    mov r9d, VK_NUM
    xorpd xmm1, xmm1
    movsd [rsp + 16], xmm1
    cmp eax, VK_TEXT
    jne .left_kind
    mov r9d, VK_TEXT
    mov qword [rsp + 32], 0
.left_kind:
    cmp eax, VK_EMPTY
    jne .right_kind
    mov eax, VK_NUM
    xorpd xmm0, xmm0
    cmp r9d, VK_TEXT
    jne .right_kind
    mov eax, VK_TEXT
    xor ecx, ecx
.right_kind:
    cmp r9d, eax
    je .same
    mov eax, -1                         ; a number before text
    cmp r9d, VK_NUM
    je .out
    mov eax, 1
    ret
.same:
    cmp eax, VK_TEXT
    je .text
    movsd xmm1, [rsp + 16]
    xor eax, eax
    ucomisd xmm1, xmm0
    je .out
    mov eax, -1
    jb .out
    mov eax, 1
.out:
    ret
.text:
    push rbx
    mov rsi, [rsp + 32]                 ; RSI, R8D: the left; RDX, ECX: the right
    mov r8d, [rsp + 40]
    xor r9d, r9d
.char:
    cmp r9d, r8d
    jae .left_end
    cmp r9d, ecx
    jae .greater
    movzx eax, byte [rsi + r9]
    movzx ebx, byte [rdx + r9]
    call fx_lower
    xchg eax, ebx
    call fx_lower
    xchg eax, ebx
    cmp eax, ebx
    jb .less
    ja .greater
    inc r9d
    jmp .char
.left_end:
    xor eax, eax
    cmp r9d, ecx
    je .t_out
.less:
    mov eax, -1
    jmp .t_out
.greater:
    mov eax, 1
.t_out:
    pop rbx
    ret

; fx_lower(EAX) -> EAX, A-Z lowered. Preserves all else.
fx_lower:
    cmp eax, 'A'
    jb .out
    cmp eax, 'Z'
    ja .out
    add eax, 32
.out:
    ret

; fx_num: the value in EAX.. as a number -> EAX = VK_NUM, XMM0; or VK_ERR
; (an error, or #VALUE! for text). Nothing is 0. Preserves all else.
fx_num:
    cmp eax, VK_NUM
    je .out
    cmp eax, VK_ERR
    je .out
    cmp eax, VK_EMPTY
    je .zero
    mov eax, VK_ERR
    mov edx, ER_VALUE
    ret
.zero:
    mov eax, VK_NUM
    xorpd xmm0, xmm0
.out:
    ret

fx_add:
    call fx_mul
.more:
    FX_HOLD
    call fx_peek
    cmp eax, '+'
    je .op
    cmp eax, '-'
    je .op
    cmp eax, '&'
    je .join
    mov rax, [rsp]                      ; no more: the value held
    movsd xmm0, [rsp + 8]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    add rsp, 32
    ret
.op:
    inc qword [fx_p]
    push rax
    sub rsp, 8
    call fx_mul
    call fx_num
    add rsp, 8
    pop r8                              ; R8D: the operator
    movapd xmm1, xmm0                   ; XMM1: the right
    mov r9d, eax
    mov eax, [rsp]
    movsd xmm0, [rsp + 8]
    mov rcx, rdx
    mov rdx, [rsp + 16]
    call fx_num
    cmp eax, VK_ERR
    je .result
    mov eax, r9d
    mov rdx, rcx
    cmp eax, VK_ERR
    je .result
    cmp r8d, '+'
    jne .minus
    addsd xmm0, xmm1
    jmp .result
.minus:
    subsd xmm0, xmm1
.result:
    add rsp, 32
    jmp .more
.join:
    inc qword [fx_p]
    call fx_mul
    mov r9d, [rsp]                      ; an error on either side wins
    cmp r9d, VK_ERR
    jne .join_right
    mov eax, VK_ERR
    mov rdx, [rsp + 16]
    add rsp, 32
    jmp .more
.join_right:
    cmp eax, VK_ERR
    jne .join_both
    add rsp, 32
    jmp .more
.join_both:
    call fx_text                        ; RDX, ECX: the right as text
    push rdx
    push rcx
    mov eax, [rsp + 16]
    movsd xmm0, [rsp + 16 + 8]
    mov rdx, [rsp + 16 + 16]
    mov rcx, [rsp + 16 + 24]
    call fx_text
    mov r8, rdx                         ; R8, R9D: the left
    mov r9d, ecx
    pop r11                             ; R10, R11D: the right
    pop r10
    cmp qword [fx_skip], 0
    jne .joined_skip
    lea edi, [r9 + r11]
    call da_alloc
    test rax, rax
    jz .joined_skip
    mov rdi, rax
    mov rsi, r8
    mov ecx, r9d
    rep movsb
    mov rsi, r10
    mov ecx, r11d
    rep movsb
    mov rdx, rax
    lea ecx, [r9 + r11]
    mov eax, VK_TEXT
    add rsp, 32
    jmp .more
.joined_skip:
    mov eax, VK_EMPTY
    add rsp, 32
    jmp .more

; fx_text: the value in EAX.. as text -> RDX, ECX (a number formatted into
; memory of its own). Preserves RBX, RBP, R12-R15.
fx_text:
    cmp eax, VK_TEXT
    je .out
    xor ecx, ecx
    cmp eax, VK_NUM
    jne .out
    cmp qword [fx_skip], 0
    jne .out
    mov edi, 32
    call da_alloc
    test rax, rax
    jz .out
    push rax
    mov rdi, rax
    call num_format
    mov ecx, eax
    pop rdx
.out:
    ret

fx_mul:
    call fx_unary
.more:
    FX_HOLD
    call fx_peek
    cmp eax, '*'
    je .op
    cmp eax, '/'
    je .op
    mov rax, [rsp]
    movsd xmm0, [rsp + 8]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    add rsp, 32
    ret
.op:
    inc qword [fx_p]
    push rax
    sub rsp, 8
    call fx_unary
    call fx_num
    add rsp, 8
    pop r8
    movapd xmm1, xmm0
    mov r9d, eax
    mov eax, [rsp]
    movsd xmm0, [rsp + 8]
    mov rcx, rdx
    mov rdx, [rsp + 16]
    call fx_num
    cmp eax, VK_ERR
    je .result
    mov eax, r9d
    mov rdx, rcx
    cmp eax, VK_ERR
    je .result
    cmp r8d, '*'
    jne .divide
    mulsd xmm0, xmm1
    jmp .result
.divide:
    xorpd xmm2, xmm2
    ucomisd xmm1, xmm2
    jne .quotient
    cmp qword [fx_skip], 0
    jne .result
    mov eax, VK_ERR
    mov edx, ER_DIV0
    jmp .result
.quotient:
    divsd xmm0, xmm1
.result:
    add rsp, 32
    jmp .more

fx_unary:
    call fx_peek
    cmp eax, '-'
    je .minus
    cmp eax, '+'
    je .plus
    jmp fx_primary
.plus:
    inc qword [fx_p]
    call fx_unary
    jmp fx_num
.minus:
    inc qword [fx_p]
    call fx_unary
    call fx_num
    cmp eax, VK_NUM
    jne .out
    call negate
.out:
    ret

fx_primary:
    call fx_peek
    test eax, eax
    jz fx_syntax
    cmp eax, '('
    je .paren
    cmp eax, '"'
    je .string
    cmp eax, '.'
    je .number
    lea ecx, [rax - '0']
    cmp ecx, 9
    jbe .number
    call ref_start
    jnc .name
    jmp fx_syntax
.paren:
    inc qword [fx_p]
    call fx_expr
    jmp fx_close
.string:
    mov rdx, [fx_p]
    inc rdx
    mov rcx, rdx
.in_string:
    cmp rcx, [fx_e]
    jae fx_syntax
    cmp byte [rcx], '"'
    je .string_end
    inc rcx
    jmp .in_string
.string_end:
    lea rax, [rcx + 1]
    mov [fx_p], rax
    sub rcx, rdx
    mov eax, VK_TEXT
    ret
.number:
    mov rsi, [fx_p]                     ; as far as a number goes
    mov rcx, rsi
.num_end:
    cmp rcx, [fx_e]
    jae .num_got
    movzx eax, byte [rcx]
    cmp eax, '.'
    je .num_more
    sub eax, '0'
    cmp eax, 9
    jbe .num_more
    movzx eax, byte [rcx]               ; an exponent, with its sign
    or eax, 0x20
    cmp eax, 'e'
    jne .num_got
    lea rax, [rcx + 1]
    cmp rax, [fx_e]
    jae .num_got
    movzx eax, byte [rcx + 1]
    cmp eax, '-'
    je .num_sign
    cmp eax, '+'
    jne .num_more
.num_sign:
    inc rcx
.num_more:
    inc rcx
    jmp .num_end
.num_got:
    mov [fx_p], rcx
    sub rcx, rsi
    call num_parse
    jc fx_syntax
    mov eax, VK_NUM
    ret
.name:
    mov rsi, [fx_p]
    mov rdx, [fx_e]
    call ref_read
    jc .word
    mov [fx_p], rsi
    push rax
    push rdx
    call fx_peek                        ; a range alone is not a value
    pop rdx
    pop rcx
    cmp eax, ':'
    je .range_alone
    mov eax, ecx
    jmp fx_cell_ref
.range_alone:
    mov eax, VK_ERR
    mov edx, ER_VALUE
    inc qword [fx_p]
    mov rsi, [fx_p]
    mov rdx, [fx_e]
    call ref_read
    jc fx_syntax
    mov [fx_p], rsi
    mov eax, VK_ERR
    mov edx, ER_VALUE
    ret
.word:
    mov rsi, [fx_p]                     ; the name: letters
    mov rcx, rsi
.letter:
    cmp rcx, [fx_e]
    jae .named
    movzx eax, byte [rcx]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 25
    ja .named
    inc rcx
    jmp .letter
.named:
    mov [fx_p], rcx
    sub rcx, rsi                        ; RSI, ECX: the name
    lea rdi, [fx_names]
    xor r8d, r8d                        ; R8D: which
.find:
    cmp byte [rdi], 0
    je .unknown
    xor r9d, r9d
.cmp:
    cmp r9d, ecx
    je .cmp_end
    movzx eax, byte [rsi + r9]
    call fx_lower
    cmp al, [rdi + r9]
    jne .skip
    inc r9d
    jmp .cmp
.cmp_end:
    cmp byte [rdi + r9], 0
    je .found
.skip:
    cmp byte [rdi], 0
    je .skipped
    inc rdi
    jmp .skip
.skipped:
    inc rdi
    inc r8d
    jmp .find
.found:
    lea rax, [fx_funcs]
    jmp [rax + r8 * 8]
.unknown:
    call fx_peek                        ; a function unknown: its arguments read
    cmp eax, '('
    jne .no_name
    call fx_args_skip
.no_name:
    mov eax, VK_ERR
    mov edx, ER_NAME
    ret

; fx_cell_ref(EAX = row, EDX = column, of a reference just read): its value
fx_cell_ref:
    cmp qword [fx_skip], 0
    jne .skipped
    cmp eax, MAXR
    jae .ref
    push rbx
    mov rdi, [fx_grid]
    mov esi, eax
    call cell_at
    mov rbx, rax
    mov rsi, rax
    call fx_cell_value
    pop rbx
    ret
.ref:
    mov eax, VK_ERR
    mov edx, ER_REF
    ret
.skipped:
    mov eax, VK_EMPTY
    ret

; fx_cell_value(RSI = a cell) -> its value, evaluated first if it is a
; dirty formula; #CYCLE! if it is being evaluated
fx_cell_value:
    test byte [rsi + CE_FLAGS], CF_BUSY
    jnz .cycle
    test byte [rsi + CE_FLAGS], CF_DIRTY
    jz .value
    test byte [rsi + CE_FLAGS], CF_FORMULA
    jz .value
    push rsi
    mov rdi, [fx_grid]
    call cell_eval
    pop rsi
.value:
    movzx eax, byte [rsi + CE_KIND]
    movsd xmm0, [rsi + CE_VAL]
    mov rdx, [rsi + CE_VAL]
    mov ecx, [rsi + CE_VLEN]
    cmp eax, VK_ERR
    jne .out
    movzx edx, byte [rsi + CE_ERR]
.out:
    ret
.cycle:
    mov eax, VK_ERR
    mov edx, ER_CYCLE
    ret

; fx_open: a '(' next, or it cannot be read
fx_open:
    call fx_peek
    cmp eax, '('
    jne fx_syntax
    inc qword [fx_p]
    ret

; fx_close: a ')' next, or it cannot be read. Preserves the value in EAX,
; XMM0, RDX, ECX.
fx_close:
    push rcx
    call fx_ws
    mov rcx, [fx_p]
    cmp rcx, [fx_e]
    jae fx_syntax
    cmp byte [rcx], ')'
    jne fx_syntax
    inc rcx
    mov [fx_p], rcx
    pop rcx
    ret

; fx_args_skip: '(' and the arguments after it read, not evaluated
fx_args_skip:
    inc qword [fx_skip]
    call fx_open
    call fx_peek
    cmp eax, ')'
    je .close
.arg:
    call fx_arg_or_range
    call fx_peek
    cmp eax, ','
    jne .close
    inc qword [fx_p]
    jmp .arg
.close:
    call fx_close
    dec qword [fx_skip]
    ret

; fx_arg_or_range -> a value, or EAX = -1 and R8D, R9D to R10D, R11D a
; range's first and last rows and columns (in order)
fx_arg_or_range:
    call fx_ws
    mov rsi, [fx_p]
    mov rdx, [fx_e]
    call ref_read
    jc .expr
    mov rdi, rsi                        ; a reference: a range?
.colon:
    cmp rdi, [fx_e]
    jae .expr
    cmp byte [rdi], ' '
    jne .is_colon
    inc rdi
    jmp .colon
.is_colon:
    cmp byte [rdi], ':'
    jne .expr
    push rax
    push rdx
    lea rsi, [rdi + 1]
.ws:
    cmp rsi, [fx_e]
    jae .bad
    cmp byte [rsi], ' '
    jne .second
    inc rsi
    jmp .ws
.second:
    mov rdx, [fx_e]
    call ref_read
    jc .bad
    mov [fx_p], rsi
    mov r10d, eax
    mov r11d, edx
    pop r9
    pop r8
    cmp r8d, r10d
    jbe .rows
    xchg r8d, r10d
.rows:
    cmp r9d, r11d
    jbe .cols
    xchg r9d, r11d
.cols:
    mov eax, -1
    ret
.bad:
    jmp fx_syntax
.expr:
    jmp fx_expr

; the aggregates: SUM, AVERAGE, MIN, MAX, COUNT. Each argument a value or a
; range; numbers count, text and nothing in a range do not, an error wins.
AG_SUM          equ 0
AG_AVG          equ 1
AG_MIN          equ 2
AG_MAX          equ 3
AG_COUNT        equ 4

fn_sum:
    mov eax, AG_SUM
    jmp fx_aggregate
fn_average:
    mov eax, AG_AVG
    jmp fx_aggregate
fn_min:
    mov eax, AG_MIN
    jmp fx_aggregate
fn_max:
    mov eax, AG_MAX
    jmp fx_aggregate
fn_count:
    mov eax, AG_COUNT
    jmp fx_aggregate

; on the stack while it runs: [rsp] the sum, +8 the least, +16 the most,
; +24 how many, +32 the first error (0: none), +40 which
fx_aggregate:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 48
    mov [rsp + 40], rax
    xorpd xmm0, xmm0
    movsd [rsp], xmm0
    mov qword [rsp + 24], 0
    mov qword [rsp + 32], 0
    call fx_open
    call fx_peek
    cmp eax, ')'
    je .close
.arg:
    call fx_arg_or_range
    cmp eax, -1
    je .range
    cmp eax, VK_EMPTY                   ; a value: nothing does not count,
    je .next_arg                        ; text is #VALUE!
    cmp eax, VK_TEXT
    jne .value
    mov eax, VK_ERR
    mov edx, ER_VALUE
.value:
    call fx_num
    call .take
    jmp .next_arg
.range:
    cmp qword [fx_skip], 0
    jne .next_arg
    cmp r10d, MAXR
    jae .range_ref
    mov r12d, r8d                       ; R12D: the row; R13D: the column
    mov r14d, r10d                      ; R14D, R15D: the last
    mov r15d, r11d
    mov ebx, r9d                        ; EBX: the first column
.row:
    cmp r12d, r14d
    ja .next_arg
    mov r13d, ebx
.col:
    cmp r13d, r15d
    ja .next_row
    mov rdi, [fx_grid]
    mov esi, r12d
    mov edx, r13d
    call cell_at
    mov rsi, rax
    call fx_cell_value
    cmp eax, VK_NUM
    je .cell_take
    cmp eax, VK_ERR
    jne .cell_next
.cell_take:
    call .take
.cell_next:
    inc r13d
    jmp .col
.next_row:
    inc r12d
    jmp .row
.range_ref:
    mov eax, VK_ERR
    mov edx, ER_REF
    call .take
.next_arg:
    call fx_peek
    cmp eax, ','
    jne .close
    inc qword [fx_p]
    jmp .arg
.close:
    call fx_close
    mov rdx, [rsp + 32]                 ; an error
    test rdx, rdx
    jz .result
    mov eax, VK_ERR
    jmp .out
.result:
    mov rax, [rsp + 40]
    mov rcx, [rsp + 24]
    cmp eax, AG_COUNT
    je .count
    movsd xmm0, [rsp]
    cmp eax, AG_SUM
    je .number
    xorpd xmm0, xmm0
    test rcx, rcx
    jz .number
    movsd xmm0, [rsp + 8]
    cmp eax, AG_MIN
    je .number
    movsd xmm0, [rsp + 16]
    cmp eax, AG_MAX
    je .number
    movsd xmm0, [rsp]                   ; the average
    cvtsi2sd xmm1, rcx
    divsd xmm0, xmm1
    jmp .number
.count:
    cvtsi2sd xmm0, rcx
.number:
    mov eax, VK_NUM
.out:
    add rsp, 48
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; .take: a number (EAX = VK_NUM, XMM0) or an error (VK_ERR, EDX) into the
; totals; [rsp + 8] here is the caller's [rsp]
.take:
    cmp eax, VK_ERR
    je .take_err
    cmp qword [rsp + 8 + 24], 0
    jne .take_more
    movsd [rsp + 8 + 8], xmm0
    movsd [rsp + 8 + 16], xmm0
.take_more:
    inc qword [rsp + 8 + 24]
    movsd xmm1, [rsp + 8]
    addsd xmm1, xmm0
    movsd [rsp + 8], xmm1
    movsd xmm1, [rsp + 8 + 8]
    minsd xmm1, xmm0
    movsd [rsp + 8 + 8], xmm1
    movsd xmm1, [rsp + 8 + 16]
    maxsd xmm1, xmm0
    movsd [rsp + 8 + 16], xmm1
    ret
.take_err:
    cmp qword [rsp + 8 + 32], 0
    jne .took
    movzx edx, dl
    mov [rsp + 8 + 32], rdx
.took:
    ret

; IF(condition, then[, else]): only the branch taken is evaluated
fn_if:
    push rbx
    sub rsp, 16                         ; [rsp]: the condition's error
    call fx_open
    call fx_expr
    xor ebx, ebx                        ; EBX: 1 if true; 2 if an error
    cmp eax, VK_ERR
    jne .truth
    mov ebx, 2
    mov [rsp], rdx
    jmp .branches
.truth:
    cmp eax, VK_TEXT
    jne .num
    mov ebx, 2
    mov qword [rsp], ER_VALUE
    jmp .branches
.num:
    call fx_num
    xorpd xmm1, xmm1
    ucomisd xmm0, xmm1
    je .branches
    mov ebx, 1
.branches:
    call fx_peek
    cmp eax, ','
    jne fx_syntax
    inc qword [fx_p]
    cmp ebx, 1
    je .then
    inc qword [fx_skip]                 ; then, read
    call fx_expr
    dec qword [fx_skip]
    call fx_peek
    cmp eax, ','
    jne .no_else
    inc qword [fx_p]
    cmp ebx, 2
    je .else_skip
    call fx_expr                        ; else, evaluated
    jmp .close
.else_skip:
    inc qword [fx_skip]
    call fx_expr
    dec qword [fx_skip]
    jmp .close
.no_else:
    mov eax, VK_NUM                     ; FALSE
    xorpd xmm0, xmm0
    jmp .close
.then:
    call fx_expr
    FX_HOLD
    call fx_peek
    cmp eax, ','
    jne .then_done
    inc qword [fx_p]
    inc qword [fx_skip]
    call fx_expr
    dec qword [fx_skip]
.then_done:
    mov rax, [rsp]
    movsd xmm0, [rsp + 8]
    mov rdx, [rsp + 16]
    mov rcx, [rsp + 24]
    add rsp, 32
.close:
    call fx_close
    cmp ebx, 2
    jne .out
    mov eax, VK_ERR
    mov rdx, [rsp]
.out:
    add rsp, 16
    pop rbx
    ret

fn_abs:
    call fx_open
    call fx_expr
    call fx_num
    call fx_close
    cmp eax, VK_NUM
    jne .out
    movq rcx, xmm0
    btr rcx, 63
    movq xmm0, rcx
.out:
    ret

; ROUND(x[, digits]): half away from zero
fn_round:
    push rbx
    call fx_open
    call fx_expr
    call fx_num
    FX_HOLD
    xor ebx, ebx                        ; EBX: the digits
    call fx_peek
    cmp eax, ','
    jne .close
    inc qword [fx_p]
    call fx_expr
    call fx_num
    cmp eax, VK_ERR
    jne .digits
    mov [rsp], rax
    mov [rsp + 16], rdx
    jmp .close
.digits:
    cvttsd2si rbx, xmm0
    cmp rbx, -15
    jge .low_ok
    mov rbx, -15
.low_ok:
    cmp rbx, 15
    jle .close
    mov ebx, 15
.close:
    call fx_close
    mov rax, [rsp]
    movsd xmm0, [rsp + 8]
    mov rdx, [rsp + 16]
    add rsp, 32
    cmp eax, VK_NUM
    jne .out
    movq r8, xmm0                       ; R8D: 1 if negative
    btr r8, 63
    setc cl
    movq xmm0, r8
    movzx r8d, cl
    movsd xmm2, xmm0                    ; XMM2: |x|, kept if it is too big
    mov edi, ebx
    call scale10
    movsd xmm1, [big18]
    comisd xmm0, xmm1
    jae .big
    addsd xmm0, [half]
    cvttsd2si rax, xmm0
    cvtsi2sd xmm0, rax
    mov edi, ebx
    neg edi
    call scale10
    jmp .signed
.big:
    movsd xmm0, xmm2
.signed:
    test r8d, r8d
    jz .positive
    call negate
.positive:
    mov eax, VK_NUM
.out:
    pop rbx
    ret

fn_true:
    movsd xmm0, [one]
    mov eax, VK_NUM
    ret
fn_false:
    xorpd xmm0, xmm0
    mov eax, VK_NUM
    ret

cell_show:
    movzx eax, byte [rdi + CE_KIND]
    cmp eax, VK_NUM
    je .num
    cmp eax, VK_TEXT
    je .text
    cmp eax, VK_ERR
    je .err
    xor ecx, ecx
    xor eax, eax
    ret
.text:
    mov ecx, [rdi + CE_VLEN]
    mov rsi, [rdi + CE_VAL]
    xor eax, eax
    ret
.num:
    push rbx
    push rsi
    movsd xmm0, [rdi + CE_VAL]
    mov rdi, rsi
    call num_format
    mov ecx, eax
    pop rsi
    pop rbx
    mov eax, 1
    ret
.err:
    movzx eax, byte [rdi + CE_ERR]
    lea rcx, [err_names]
    mov rsi, [rcx + rax * 8]
    xor ecx, ecx
.len:
    cmp byte [rsi + rcx], 0
    je .len_done
    inc ecx
    jmp .len
.len_done:
    mov eax, 1
    ret

section .rodata
align 8
pow10:          dq 1e0, 1e1, 1e2, 1e3, 1e4, 1e5, 1e6, 1e7, 1e8, 1e9, 1e10, 1e11
                dq 1e12, 1e13, 1e14, 1e15, 1e16, 1e17, 1e18, 1e19, 1e20, 1e21, 1e22
one:            dq 1.0
ten:            dq 10.0
half:           dq 0.5
big15:          dq 1e15
big18:          dq 9e18
tiny5:          dq 1e-5
fx_names:       db 'sum', 0, 'average', 0, 'min', 0, 'max', 0, 'count', 0, 'if', 0
                db 'abs', 0, 'round', 0, 'true', 0, 'false', 0, 0
s_err_none:     db '#ERROR!', 0
s_err_div0:     db '#DIV/0!', 0
s_err_value:    db '#VALUE!', 0
s_err_ref:      db '#REF!', 0
s_err_name:     db '#NAME?', 0
s_err_cycle:    db '#CYCLE!', 0
s_err_num:      db '#NUM!', 0

section .data
align 8
fx_funcs:       dq fn_sum, fn_average, fn_min, fn_max, fn_count, fn_if
                dq fn_abs, fn_round, fn_true, fn_false
err_names:      dq s_err_none, s_err_div0, s_err_value, s_err_ref, s_err_name
                dq s_err_cycle, s_err_none, s_err_num

section .bss
alignb 8
fx_p:           resq 1
fx_e:           resq 1
fx_grid:        resq 1
fx_rsp:         resq 1
fx_skip:        resq 1
calc_rsp:       resq 1
calc_stack_top: resq 1
calc_count:     resd 1
num_dst:        resq 1
num_keep:       resb 1
num_tmp:        resb 32

section .text
