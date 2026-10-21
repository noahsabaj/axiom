; =============================================================================
;  notes/lex.inc - what kind of text a file holds, by its name, and the
;  colour of each part of a line of it
;
;    lang_of(RSI = a name, NUL-ended) -> EAX = L_*, EDX = its kind (kinds:
;      the name the status bar gives it)
;    lex(RSI = a line, ECX = its bytes, EAX = the state it begins in, RDI =
;      a byte for each of its bytes, its T_*; lex_lang = L_*) -> EAX = the
;      state the next line begins in: inside a comment, a string, a fence
;  Each preserves RBX, RBP, R12-R15.
; =============================================================================

L_PLAIN         equ 0
L_ASM           equ 1
L_C             equ 2                   ; and the languages written like it
L_PY            equ 3
L_SH            equ 4                   ; and settings: # comments
L_JSON          equ 5
L_MD            equ 6

T_PLAIN         equ 0
T_COMMENT       equ 1
T_KEYWORD       equ 2
T_STRING        equ 3
T_NUMBER        equ 4
T_PREPROC       equ 5                   ; #include, %define, section, @decorator
T_TYPE          equ 6                   ; a type, a register, a variable
T_FUNC          equ 7                   ; a function, a label, a key
T_HEAD          equ 8                   ; a heading
T_COUNT         equ 9

LS_BLOCK        equ 1                   ; inside /* */
LS_TRIPLE1      equ 2                   ; inside ''' '''
LS_TRIPLE2      equ 3                   ; inside """ """
LS_FENCE        equ 4                   ; inside ``` ```

LF_SEEN         equ 1                   ; ebp: something not blank before
LF_WORD         equ 2                   ; asm: the instruction is behind
LF_NAME         equ 4                   ; python: def or class, the name next
LF_PRE          equ 8                   ; c: a # line

KD_EXT          equ 0                   ; kinds: the extension, lowercase
KD_NAME         equ 8                   ; what it is called
KD_LANG         equ 16
KD_SIZE         equ 24

section .text

lang_of:
    push rbx
    push rcx
    push rsi
    push rdi
    mov rbx, rsi
    xor edx, edx                        ; EDX: past its last dot, or 0
    xor ecx, ecx
.scan:
    mov al, [rbx + rcx]
    test al, al
    jz .scanned
    inc ecx
    cmp al, '.'
    jne .scan
    mov edx, ecx
    jmp .scan
.scanned:
    test edx, edx
    jz .whole
    lea rsi, [rbx + rdx]
    jmp .find
.whole:
    mov rsi, rbx                        ; Makefile, and such: no dot
.find:
    lea rdi, [kinds + KD_SIZE]
    mov edx, 1
.each:
    cmp edx, KINDS
    jae .plain
    push rsi
    mov rcx, [rdi + KD_EXT]
.cmp:
    mov al, [rsi]
    cmp al, 'A'
    jb .folded
    cmp al, 'Z'
    ja .folded
    or al, 0x20
.folded:
    cmp al, [rcx]
    jne .differ
    test al, al
    jz .same
    inc rsi
    inc rcx
    jmp .cmp
.differ:
    pop rsi
    add rdi, KD_SIZE
    inc edx
    jmp .each
.same:
    pop rsi
    mov eax, [rdi + KD_LANG]
    jmp .out
.plain:
    xor eax, eax
    xor edx, edx
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

lex:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi
    mov r12d, ecx
    mov r13, rdi
    mov r15d, eax
    xor r14d, r14d
    xor ebp, ebp
    xor eax, eax                        ; plain, until it is found otherwise
    rep stosb
    mov eax, [lex_lang]
    cmp eax, L_MD
    ja lx_done
    lea rcx, [lx_langs]
    jmp [rcx + rax * 8]

lx_done:
    mov eax, r15d
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

lx_plain:
    xor r15d, r15d
    jmp lx_done

; lx_mark(EAX = from, ECX = to, DL = T_*). Preserves all but RAX.
lx_mark:
    push rdi
    push rcx
    lea rdi, [r13 + rax]
    sub ecx, eax
    jle .out
    mov al, dl
    rep stosb
.out:
    pop rcx
    pop rdi
    ret

; lx_rest(DL = T_*): to the end of the line
lx_rest:
    mov eax, r14d
    mov ecx, r12d
    call lx_mark
    mov r14d, r12d
    ret

; lx_at(ECX = where) -> EAX = the byte there, 0 past the end. Preserves
; others.
lx_at:
    xor eax, eax
    cmp ecx, r12d
    jae .out
    movzx eax, byte [rbx + rcx]
.out:
    ret

; lx_idch(AL) -> ZF clear if it may be in a word: a letter, a digit, _, not
; ASCII; for assembly also . $ @ ?. Preserves all.
lx_idch:
    push rax
    cmp al, 0x80
    jae .yes
    cmp al, '_'
    je .yes
    cmp al, '0'
    jb .extra
    cmp al, '9'
    jbe .yes
    or al, 0x20
    cmp al, 'a'
    jb .extra
    cmp al, 'z'
    jbe .yes
.extra:
    cmp dword [lex_lang], L_ASM
    jne .no
    mov al, [rsp]
    cmp al, '.'
    je .yes
    cmp al, '$'
    je .yes
    cmp al, '@'
    je .yes
    cmp al, '?'
    je .yes
.no:
    pop rax
    cmp al, al                          ; ZF set
    ret
.yes:
    pop rax
    test esp, esp                       ; ZF clear (RSP is never 0)
    ret

; lx_start(AL) -> ZF clear if a word may begin with it: as lx_idch, not a
; digit
lx_start:
    cmp al, '0'
    jb lx_idch
    cmp al, '9'
    ja lx_idch
    cmp al, al
    ret

; lx_word -> ECX = where the word at R14D ends
lx_word:
    mov ecx, r14d
.each:
    cmp ecx, r12d
    jae .out
    mov al, [rbx + rcx]
    call lx_idch
    jz .out
    inc ecx
    jmp .each
.out:
    ret

; lx_number -> ECX = where the number at R14D ends: its digits, letters,
; dots and _
lx_number:
    mov ecx, r14d
.each:
    cmp ecx, r12d
    jae .out
    mov al, [rbx + rcx]
    cmp al, '.'
    je .more
    cmp al, 0x80
    jae .out
    call lx_idch
    jz .out
.more:
    inc ecx
    jmp .each
.out:
    ret

; lx_string -> ECX = past the string at R14D, its quote's match, or the end
; of the line; \ escapes the byte after it but in assembly (bar `)
lx_string:
    mov dl, [rbx + r14]
    lea ecx, [r14 + 1]
.each:
    cmp ecx, r12d
    jae .out
    mov al, [rbx + rcx]
    inc ecx
    cmp al, dl
    je .out
    cmp al, '\'
    jne .each
    cmp dword [lex_lang], L_ASM
    jne .escape
    cmp dl, '`'
    jne .each
.escape:
    cmp ecx, r12d
    jae .out
    inc ecx
    jmp .each
.out:
    ret

; lx_blank -> ECX = past the blanks at ECX
lx_blank:
    cmp ecx, r12d
    jae .out
    cmp byte [rbx + rcx], ' '
    je .more
    cmp byte [rbx + rcx], 9
    jne .out
.more:
    inc ecx
    jmp lx_blank
.out:
    ret

; lx_kw(RDI = words, NUL-ended, an empty one last; ECX = where the word at
; R14D ends) -> ZF set if it is one. Assembly's are matched in any case.
; Preserves all but RAX.
lx_kw:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edx, ecx
    sub edx, r14d                       ; EDX: its length
.word:
    cmp byte [rdi], 0
    je .none
    lea rsi, [rbx + r14]
    xor ecx, ecx
.cmp:
    cmp ecx, edx
    je .end
    mov al, [rsi + rcx]
    cmp dword [lex_lang], L_ASM
    jne .exact
    cmp al, 'A'
    jb .exact
    cmp al, 'Z'
    ja .exact
    or al, 0x20
.exact:
    cmp al, [rdi + rcx]
    jne .skip
    inc ecx
    jmp .cmp
.end:
    cmp byte [rdi + rcx], 0             ; as long as it
    je .found
.skip:
    cmp byte [rdi], 0                   ; on to the next
    je .next
    inc rdi
    jmp .skip
.next:
    inc rdi
    jmp .word
.none:
    test esp, esp
    jmp .out
.found:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; lx_seen: something not blank is behind, from here on
%macro SEEN 0
    or ebp, LF_SEEN
%endmacro

; -----------------------------------------------------------------------------
;  C, and the languages written like it
; -----------------------------------------------------------------------------

lx_c:
    cmp r15d, LS_BLOCK
    je .comment
    xor r15d, r15d
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, ' '
    je .blank
    cmp al, 9
    je .blank
    cmp al, '/'
    jne .quote
    lea ecx, [r14 + 1]
    call lx_at
    cmp al, '/'
    jne .block
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.block:
    cmp al, '*'
    jne .other
    mov eax, r14d
    lea ecx, [r14 + 2]
    mov dl, T_COMMENT
    call lx_mark
    add r14d, 2
    mov r15d, LS_BLOCK
.comment:                               ; to its */
    mov ecx, r14d
.find:
    lea eax, [rcx + 1]
    cmp eax, r12d
    jae .open
    cmp word [rbx + rcx], '*/'
    je .closed
    inc ecx
    jmp .find
.open:
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.closed:
    add ecx, 2
    mov eax, r14d
    mov dl, T_COMMENT
    call lx_mark
    mov r14d, ecx
    xor r15d, r15d
    SEEN
    jmp .each
.quote:
    cmp al, '"'
    je .string
    cmp al, "'"
    je .string
    cmp al, '`'
    je .string
    cmp al, '<'
    jne .hash
    test ebp, LF_PRE                    ; #include <...>
    jz .other
    mov ecx, r14d
.angle:
    inc ecx
    cmp ecx, r12d
    jae .angled
    cmp byte [rbx + rcx - 1], '>'
    jne .angle
.angled:
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    jmp .each
.string:
    call lx_string
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    SEEN
    jmp .each
.hash:
    cmp al, '#'
    jne .digit
    test ebp, LF_SEEN
    jnz .other
    or ebp, LF_PRE | LF_SEEN
    mov edx, r14d                       ; EDX: the #
    lea ecx, [r14 + 1]
    call lx_blank
    mov r14d, ecx
    call lx_word
    mov eax, edx
    mov dl, T_PREPROC
    call lx_mark
    mov r14d, ecx
    jmp .each
.digit:
    cmp al, '.'
    jne .digits
    lea ecx, [r14 + 1]
    call lx_at
    sub al, '0'
    cmp al, 9
    ja .other
    jmp .number
.digits:
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    ja .word
.number:
    call lx_number
    mov eax, r14d
    mov dl, T_NUMBER
    call lx_mark
    mov r14d, ecx
    SEEN
    jmp .each
.word:
    call lx_start
    jz .other
    call lx_word
    SEEN
    lea rdi, [c_words]
    call lx_kw
    mov dl, T_KEYWORD
    jz .mark
    push rcx
    call lx_blank
    call lx_at
    pop rcx
    mov dl, T_FUNC
    cmp al, '('
    je .mark
    mov al, [rbx + r14]                 ; Capitalised: a type
    mov dl, T_TYPE
    cmp al, 'A'
    jb .plain
    cmp al, 'Z'
    jbe .mark
.plain:
    mov r14d, ecx
    jmp .each
.mark:
    mov eax, r14d
    call lx_mark
    mov r14d, ecx
    jmp .each
.other:
    SEEN
.blank:
    inc r14d
    jmp .each

; -----------------------------------------------------------------------------
;  Python
; -----------------------------------------------------------------------------

lx_py:
    cmp r15d, LS_TRIPLE1
    je .triple_in
    cmp r15d, LS_TRIPLE2
    je .triple_in
    xor r15d, r15d
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, ' '
    je .blank
    cmp al, 9
    je .blank
    cmp al, '#'
    jne .quote
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.quote:
    cmp al, '"'
    je .string
    cmp al, "'"
    jne .at
.string:
    SEEN
    mov edx, eax                        ; three of them?
    lea ecx, [r14 + 1]
    call lx_at
    cmp eax, edx
    jne .single
    lea ecx, [r14 + 2]
    call lx_at
    cmp eax, edx
    jne .single
    mov r15d, LS_TRIPLE1
    cmp dl, "'"
    je .opened
    mov r15d, LS_TRIPLE2
.opened:
    mov eax, r14d
    lea ecx, [r14 + 3]
    mov dl, T_STRING
    call lx_mark
    add r14d, 3
.triple_in:                             ; to its three again
    mov dl, "'"
    cmp r15d, LS_TRIPLE1
    je .find_from
    mov dl, '"'
.find_from:
    mov ecx, r14d
.find:
    lea eax, [rcx + 2]
    cmp eax, r12d
    jae .open
    cmp [rbx + rcx], dl
    jne .find_next
    cmp [rbx + rcx + 1], dl
    jne .find_next
    cmp [rbx + rcx + 2], dl
    je .closed
.find_next:
    cmp byte [rbx + rcx], '\'
    jne .find_one
    inc ecx
.find_one:
    inc ecx
    jmp .find
.open:
    mov dl, T_STRING
    call lx_rest
    jmp lx_done
.closed:
    add ecx, 3
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    xor r15d, r15d
    jmp .each
.single:
    call lx_string
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    jmp .each
.at:
    cmp al, '@'
    jne .digits
    test ebp, LF_SEEN
    jnz .other
    SEEN
    mov ecx, r14d
.decorator:
    inc ecx
    cmp ecx, r12d
    jae .decorated
    mov al, [rbx + rcx]
    cmp al, '.'
    je .decorator
    call lx_idch
    jnz .decorator
.decorated:
    mov eax, r14d
    mov dl, T_PREPROC
    call lx_mark
    mov r14d, ecx
    jmp .each
.digits:
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    ja .word
    call lx_number
    mov eax, r14d
    mov dl, T_NUMBER
    call lx_mark
    mov r14d, ecx
    SEEN
    jmp .each
.word:
    call lx_start
    jz .other
    call lx_word
    SEEN
    test ebp, LF_NAME                   ; after def or class
    jz .keyword
    and ebp, ~LF_NAME
    mov dl, T_FUNC
    jmp .mark
.keyword:
    lea rdi, [py_words]
    call lx_kw
    jnz .called
    mov eax, ecx                        ; def, class: a name next
    sub eax, r14d
    cmp eax, 3
    jne .class
    cmp word [rbx + r14], 'de'
    jne .kw
    cmp byte [rbx + r14 + 2], 'f'
    je .named
    jmp .kw
.class:
    cmp eax, 5
    jne .kw
    cmp dword [rbx + r14], 'clas'
    jne .kw
    cmp byte [rbx + r14 + 4], 's'
    jne .kw
.named:
    or ebp, LF_NAME
.kw:
    mov dl, T_KEYWORD
    jmp .mark
.called:
    push rcx
    call lx_blank
    call lx_at
    pop rcx
    mov dl, T_FUNC
    cmp al, '('
    je .mark
    mov al, [rbx + r14]
    mov dl, T_TYPE
    cmp al, 'A'
    jb .plain
    cmp al, 'Z'
    jbe .mark
.plain:
    mov r14d, ecx
    jmp .each
.mark:
    mov eax, r14d
    call lx_mark
    mov r14d, ecx
    jmp .each
.other:
    SEEN
.blank:
    inc r14d
    jmp .each

; -----------------------------------------------------------------------------
;  Shell, and settings with # comments
; -----------------------------------------------------------------------------

lx_sh:
    xor r15d, r15d
    xor ecx, ecx
    call lx_blank
    call lx_at
    cmp al, '['                         ; [a section], not [ a test ]
    jne .each
    inc ecx
    call lx_at
    cmp al, ' '
    je .each
    mov dl, T_FUNC
    call lx_rest
    jmp lx_done
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, ' '
    je .blank
    cmp al, 9
    je .blank
    cmp al, '#'
    jne .quote
    test r14d, r14d                     ; at a word's start
    jz .comment
    mov cl, [rbx + r14 - 1]
    cmp cl, ' '
    je .comment
    cmp cl, 9
    jne .other
.comment:
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.quote:
    cmp al, '"'
    je .string
    cmp al, "'"
    jne .dollar
.string:
    call lx_string
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    SEEN
    jmp .each
.dollar:
    cmp al, '$'
    jne .digits
    SEEN
    lea ecx, [r14 + 1]
    call lx_at
    cmp al, '{'
    jne .simple
.brace:
    inc ecx
    cmp ecx, r12d
    jae .var
    cmp byte [rbx + rcx - 1], '}'
    jne .brace
    jmp .var
.simple:
    call lx_idch
    jz .special
    push r14
    mov r14d, ecx
    call lx_word
    pop r14
    jmp .var
.special:
    inc ecx                             ; $? $1 $#: one more
    cmp ecx, r12d
    jbe .var
    mov ecx, r12d
.var:
    mov eax, r14d
    mov dl, T_TYPE
    call lx_mark
    mov r14d, ecx
    jmp .each
.digits:
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    ja .word
    test r14d, r14d                     ; a number alone, not in a word
    jz .number
    mov cl, [rbx + r14 - 1]
    call lx_space
    jne .other
.number:
    call lx_number
    mov eax, r14d
    mov dl, T_NUMBER
    call lx_mark
    mov r14d, ecx
    SEEN
    jmp .each
.word:
    call lx_start
    jz .other
    call lx_word
    test ebp, LF_SEEN                   ; name= at the start: a variable
    jnz .keyword
    push rcx
    call lx_blank
    call lx_at
    pop rcx
    cmp al, '='
    je .key
    cmp al, ':'
    jne .keyword
.key:
    SEEN
    mov dl, T_TYPE
    jmp .mark
.keyword:
    SEEN
    lea rdi, [sh_words]
    call lx_kw
    jnz .plain
    mov dl, T_KEYWORD
.mark:
    mov eax, r14d
    call lx_mark
.plain:
    mov r14d, ecx
    jmp .each
.other:
    SEEN
.blank:
    inc r14d
    jmp .each

; lx_space(CL) -> ZF if it is a blank, or a mark a word stops at
lx_space:
    cmp cl, ' '
    je .out
    cmp cl, 9
    je .out
    cmp cl, '='
    je .out
    cmp cl, '('
    je .out
    cmp cl, ','
    je .out
    cmp cl, '['
.out:
    ret

; -----------------------------------------------------------------------------
;  JSON
; -----------------------------------------------------------------------------

lx_json:
    xor r15d, r15d
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, '"'
    jne .digits
    call lx_string
    push rcx
    call lx_blank
    call lx_at
    pop rcx
    mov dl, T_STRING
    cmp al, ':'                         ; a key
    jne .mark
    mov dl, T_FUNC
    jmp .mark
.digits:
    cmp al, '-'
    jne .digit
    inc r14d                            ; its digits after
    call lx_number
    dec r14d
    mov dl, T_NUMBER
    jmp .mark
.digit:
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    ja .word
    call lx_number
    mov dl, T_NUMBER
    jmp .mark
.word:
    call lx_start
    jz .other
    call lx_word
    lea rdi, [json_words]
    call lx_kw
    jnz .plain
    mov dl, T_KEYWORD
.mark:
    mov eax, r14d
    call lx_mark
.plain:
    mov r14d, ecx
    jmp .each
.other:
    inc r14d
    jmp .each

; -----------------------------------------------------------------------------
;  Markdown
; -----------------------------------------------------------------------------

lx_md:
    xor ecx, ecx
    call lx_blank
    mov r14d, ecx
    lea eax, [rcx + 2]                  ; ``` or ~~~: in or out of code
    cmp eax, r12d
    jae .not_fence
    mov al, [rbx + rcx]
    cmp al, '`'
    je .fence_char
    cmp al, '~'
    jne .not_fence
.fence_char:
    cmp [rbx + rcx + 1], al
    jne .not_fence
    cmp [rbx + rcx + 2], al
    jne .not_fence
    xor r14d, r14d
    mov dl, T_COMMENT
    call lx_rest
    xor r15d, LS_FENCE
    and r15d, LS_FENCE
    jmp lx_done
.not_fence:
    cmp r15d, LS_FENCE
    jne .text
    xor r14d, r14d
    mov dl, T_STRING
    call lx_rest
    jmp lx_done
.text:
    xor r15d, r15d
    call lx_at
    cmp al, '#'
    jne .quote
    xor r14d, r14d
    mov dl, T_HEAD
    call lx_rest
    jmp lx_done
.quote:
    cmp al, '>'
    jne .bullet
    xor r14d, r14d
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.bullet:
    cmp al, '-'
    je .marker
    cmp al, '*'
    je .marker
    cmp al, '+'
    je .marker
    mov edx, ecx                        ; 1. or 1)
.ordinal:
    call lx_at
    sub al, '0'
    cmp al, 9
    ja .ordinal_end
    inc ecx
    jmp .ordinal
.ordinal_end:
    cmp ecx, edx
    je .each
    call lx_at
    cmp al, '.'
    je .marker
    cmp al, ')'
    jne .each
.marker:
    inc ecx
    push rcx
    call lx_at
    pop rcx
    cmp al, ' '
    jne .each
    mov eax, r14d
    mov dl, T_KEYWORD
    call lx_mark
    mov r14d, ecx
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, '`'
    jne .link
    mov ecx, r14d
.code:
    inc ecx
    cmp ecx, r12d
    jae .other                          ; one alone: plain
    cmp byte [rbx + rcx], '`'
    jne .code
    inc ecx
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    jmp .each
.link:
    cmp al, '['                         ; [its text](where)
    jne .other
    mov ecx, r14d
.text_end:
    inc ecx
    cmp ecx, r12d
    jae .other
    cmp byte [rbx + rcx], ']'
    jne .text_end
    inc ecx
    mov edx, ecx                        ; EDX: past the ]
    call lx_at
    cmp al, '('
    jne .other
.url_end:
    inc ecx
    cmp ecx, r12d
    jae .other
    cmp byte [rbx + rcx], ')'
    jne .url_end
    inc ecx
    push rcx
    mov eax, r14d
    mov ecx, edx
    mov dl, T_FUNC
    call lx_mark
    mov eax, ecx
    pop rcx
    mov dl, T_TYPE
    call lx_mark
    mov r14d, ecx
    jmp .each
.other:
    inc r14d
    jmp .each

; -----------------------------------------------------------------------------
;  Assembly (NASM's)
; -----------------------------------------------------------------------------

lx_asm:
    xor r15d, r15d
.each:
    cmp r14d, r12d
    jae lx_done
    movzx eax, byte [rbx + r14]
    cmp al, ' '
    je .blank
    cmp al, 9
    je .blank
    cmp al, ';'
    jne .quote
    mov dl, T_COMMENT
    call lx_rest
    jmp lx_done
.quote:
    cmp al, '"'
    je .string
    cmp al, "'"
    je .string
    cmp al, '`'
    jne .macro
.string:
    call lx_string
    mov eax, r14d
    mov dl, T_STRING
    call lx_mark
    mov r14d, ecx
    jmp .each
.macro:
    cmp al, '%'
    jne .digits
    mov ecx, r14d
.macro_name:
    inc ecx
    cmp ecx, r12d
    jae .macro_end
    mov al, [rbx + rcx]
    cmp al, '%'
    je .macro_name
    call lx_idch
    jnz .macro_name
.macro_end:
    lea eax, [r14 + 1]                  ; % alone: modulo
    cmp ecx, eax
    je .other
    mov eax, r14d
    mov dl, T_PREPROC
    call lx_mark
    mov r14d, ecx
    or ebp, LF_WORD
    jmp .each
.digits:
    mov ecx, eax
    sub ecx, '0'
    cmp ecx, 9
    ja .word
    call lx_number
    mov eax, r14d
    mov dl, T_NUMBER
    call lx_mark
    mov r14d, ecx
    jmp .each
.word:
    call lx_start
    jz .other
    call lx_word
    test ebp, LF_WORD
    jnz .operand
    call lx_at                          ; name: a label
    cmp al, ':'
    jne .equ
    inc ecx
    mov dl, T_FUNC
    jmp .mark
.equ:
    test ebp, LF_SEEN                   ; name equ ...: a name too
    jnz .instruction
    push rcx
    push r14
    call lx_blank
    mov r14d, ecx
    call lx_word
    lea rdi, [asm_equ]
    call lx_kw
    pop r14
    pop rcx
    jne .instruction
    SEEN
    mov dl, T_FUNC
    jmp .mark
.instruction:
    SEEN
    or ebp, LF_WORD
    lea rdi, [asm_dirs]
    call lx_kw
    mov dl, T_PREPROC
    je .mark
    mov dl, T_KEYWORD
    jmp .mark
.operand:
    call lx_reg
    mov dl, T_TYPE
    je .mark
    lea rdi, [asm_dirs]
    call lx_kw
    mov dl, T_PREPROC
    je .mark
    lea rdi, [asm_sizes]
    call lx_kw
    mov dl, T_KEYWORD
    je .mark
    mov r14d, ecx
    jmp .each
.mark:
    mov eax, r14d
    call lx_mark
    mov r14d, ecx
    jmp .each
.other:
    SEEN
.blank:
    inc r14d
    jmp .each

; lx_reg(ECX = where the word at R14D ends) -> ZF set if it is a register.
; Preserves all but RAX.
lx_reg:
    push rcx
    push rdx
    push rsi
    mov edx, ecx
    sub edx, r14d                       ; EDX: its length
    cmp edx, 2
    jb .no
    cmp edx, 5
    ja .no
    xor ecx, ecx                        ; lowercase, into lx_w
    lea rsi, [rbx + r14]
.fold:
    mov al, [rsi + rcx]
    cmp al, 'A'
    jb .folded
    cmp al, 'Z'
    ja .folded
    or al, 0x20
.folded:
    mov [lx_w + rcx], al
    inc ecx
    cmp ecx, edx
    jb .fold
    mov byte [lx_w + rcx], 0
    lea rsi, [lx_w]
    cmp byte [rsi], 'r'                 ; r8..r15, and d w b
    jne .simd
    movzx eax, byte [rsi + 1]
    sub eax, '0'
    cmp eax, 9
    ja .listed
    mov ecx, 2
    movzx edx, byte [rsi + 2]
    sub edx, '0'
    cmp edx, 9
    ja .one_digit
    imul eax, eax, 10
    add eax, edx
    inc ecx
.one_digit:
    cmp eax, 8
    jb .no
    cmp eax, 15
    ja .no
    mov al, [rsi + rcx]
    test al, al
    jz .yes
    cmp byte [rsi + rcx + 1], 0
    jne .no
    cmp al, 'd'
    je .yes
    cmp al, 'w'
    je .yes
    cmp al, 'b'
    je .yes
    jmp .no
.simd:
    mov eax, [rsi]                      ; xmm ymm zmm, and a number
    and eax, 0xFFFFFF
    cmp eax, 'xmm'
    je .numbered
    cmp eax, 'ymm'
    je .numbered
    cmp eax, 'zmm'
    jne .control
.numbered:
    add rsi, 3
    jmp .digits
.control:
    mov ax, [rsi]                       ; cr0, dr7
    cmp ax, 'cr'
    je .two
    cmp ax, 'dr'
    jne .listed
.two:
    add rsi, 2
.digits:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .no
    inc rsi
    cmp byte [rsi], 0
    je .yes
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .no
    cmp byte [rsi + 1], 0
    je .yes
    jmp .no
.listed:
    pop rsi
    pop rdx
    pop rcx
    lea rdi, [asm_regs]
    jmp lx_kw
.yes:
    xor eax, eax
    jmp .out
.no:
    test esp, esp
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

section .rodata
align 8
lx_langs:       dq lx_plain, lx_asm, lx_c, lx_py, lx_sh, lx_json, lx_md

kinds:          dq k_none, n_plain, L_PLAIN
                dq k_asm, n_asm, L_ASM
                dq k_inc, n_asm, L_ASM
                dq k_s, n_asm, L_ASM
                dq k_nasm, n_asm, L_ASM
                dq k_c, n_c, L_C
                dq k_h, n_c, L_C
                dq k_cpp, n_cpp, L_C
                dq k_cc, n_cpp, L_C
                dq k_cxx, n_cpp, L_C
                dq k_hpp, n_cpp, L_C
                dq k_js, n_js, L_C
                dq k_mjs, n_js, L_C
                dq k_ts, n_ts, L_C
                dq k_rs, n_rs, L_C
                dq k_go, n_go, L_C
                dq k_java, n_java, L_C
                dq k_cs, n_cs, L_C
                dq k_swift, n_swift, L_C
                dq k_kt, n_kt, L_C
                dq k_zig, n_zig, L_C
                dq k_css, n_css, L_C
                dq k_glsl, n_glsl, L_C
                dq k_wgsl, n_wgsl, L_C
                dq k_py, n_py, L_PY
                dq k_sh, n_sh, L_SH
                dq k_bash, n_sh, L_SH
                dq k_toml, n_toml, L_SH
                dq k_yaml, n_yaml, L_SH
                dq k_yml, n_yaml, L_SH
                dq k_ini, n_ini, L_SH
                dq k_cfg, n_ini, L_SH
                dq k_conf, n_ini, L_SH
                dq k_make, n_make, L_SH
                dq k_json, n_json, L_JSON
                dq k_md, n_md, L_MD
                dq k_markdown, n_md, L_MD
KINDS           equ ($ - kinds) / KD_SIZE

k_none:         db 0
k_asm:          db 'asm', 0
k_inc:          db 'inc', 0
k_s:            db 's', 0
k_nasm:         db 'nasm', 0
k_c:            db 'c', 0
k_h:            db 'h', 0
k_cpp:          db 'cpp', 0
k_cc:           db 'cc', 0
k_cxx:          db 'cxx', 0
k_hpp:          db 'hpp', 0
k_js:           db 'js', 0
k_mjs:          db 'mjs', 0
k_ts:           db 'ts', 0
k_rs:           db 'rs', 0
k_go:           db 'go', 0
k_java:         db 'java', 0
k_cs:           db 'cs', 0
k_swift:        db 'swift', 0
k_kt:           db 'kt', 0
k_zig:          db 'zig', 0
k_css:          db 'css', 0
k_glsl:         db 'glsl', 0
k_wgsl:         db 'wgsl', 0
k_py:           db 'py', 0
k_sh:           db 'sh', 0
k_bash:         db 'bash', 0
k_toml:         db 'toml', 0
k_yaml:         db 'yaml', 0
k_yml:          db 'yml', 0
k_ini:          db 'ini', 0
k_cfg:          db 'cfg', 0
k_conf:         db 'conf', 0
k_make:         db 'makefile', 0
k_json:         db 'json', 0
k_md:           db 'md', 0
k_markdown:     db 'markdown', 0

n_plain:        db 'Plain Text', 0
n_asm:          db 'Assembly', 0
n_c:            db 'C', 0
n_cpp:          db 'C++', 0
n_js:           db 'JavaScript', 0
n_ts:           db 'TypeScript', 0
n_rs:           db 'Rust', 0
n_go:           db 'Go', 0
n_java:         db 'Java', 0
n_cs:           db 'C#', 0
n_swift:        db 'Swift', 0
n_kt:           db 'Kotlin', 0
n_zig:          db 'Zig', 0
n_css:          db 'CSS', 0
n_glsl:         db 'GLSL', 0
n_wgsl:         db 'WGSL', 0
n_py:           db 'Python', 0
n_sh:           db 'Shell', 0
n_toml:         db 'TOML', 0
n_yaml:         db 'YAML', 0
n_ini:          db 'Settings', 0
n_make:         db 'Makefile', 0
n_json:         db 'JSON', 0
n_md:           db 'Markdown', 0

c_words:        db 'if', 0, 'else', 0, 'for', 0, 'while', 0, 'do', 0, 'return', 0
                db 'break', 0, 'continue', 0, 'switch', 0, 'case', 0, 'default', 0
                db 'goto', 0, 'struct', 0, 'union', 0, 'enum', 0, 'typedef', 0
                db 'static', 0, 'const', 0, 'extern', 0, 'volatile', 0, 'inline', 0
                db 'sizeof', 0, 'void', 0, 'char', 0, 'short', 0, 'int', 0, 'long', 0
                db 'float', 0, 'double', 0, 'signed', 0, 'unsigned', 0, 'bool', 0
                db 'true', 0, 'false', 0, 'NULL', 0, 'nullptr', 0, 'null', 0
                db 'class', 0, 'public', 0, 'private', 0, 'protected', 0
                db 'virtual', 0, 'override', 0, 'template', 0, 'typename', 0
                db 'namespace', 0, 'using', 0, 'new', 0, 'delete', 0, 'this', 0
                db 'let', 0, 'var', 0, 'function', 0, 'fn', 0, 'mut', 0, 'pub', 0
                db 'impl', 0, 'trait', 0, 'use', 0, 'mod', 0, 'match', 0, 'loop', 0
                db 'self', 0, 'Self', 0, 'super', 0, 'crate', 0, 'where', 0
                db 'import', 0, 'export', 0, 'from', 0, 'as', 0, 'async', 0
                db 'await', 0, 'yield', 0, 'try', 0, 'catch', 0, 'throw', 0
                db 'throws', 0, 'finally', 0, 'interface', 0, 'type', 0
                db 'package', 0, 'go', 0, 'defer', 0, 'func', 0, 'chan', 0
                db 'select', 0, 'range', 0, 'map', 0, 'extends', 0
                db 'implements', 0, 'final', 0, 'abstract', 0, 'instanceof', 0
                db 'typeof', 0, 'in', 0, 'of', 0, 'guard', 0, 'struct', 0
                db 'protocol', 0, 'extension', 0, 'some', 0, 'any', 0, 'is', 0
                db 'constexpr', 0, 'auto', 0, 'register', 0, 'restrict', 0
                db 'unsafe', 0, 'dyn', 0, 'ref', 0, 'move', 0, 'static_assert', 0
                db 'uniform', 0, 'layout', 0, 'out', 0, 'inout', 0, 'comptime', 0
                db 'u8', 0, 'u16', 0, 'u32', 0, 'u64', 0, 'usize', 0
                db 'i8', 0, 'i16', 0, 'i32', 0, 'i64', 0, 'isize', 0
                db 'f32', 0, 'f64', 0, 'str', 0, 0
py_words:       db 'False', 0, 'None', 0, 'True', 0, 'and', 0, 'as', 0
                db 'assert', 0, 'async', 0, 'await', 0, 'break', 0, 'class', 0
                db 'continue', 0, 'def', 0, 'del', 0, 'elif', 0, 'else', 0
                db 'except', 0, 'finally', 0, 'for', 0, 'from', 0, 'global', 0
                db 'if', 0, 'import', 0, 'in', 0, 'is', 0, 'lambda', 0
                db 'nonlocal', 0, 'not', 0, 'or', 0, 'pass', 0, 'raise', 0
                db 'return', 0, 'try', 0, 'while', 0, 'with', 0, 'yield', 0
                db 'match', 0, 'case', 0, 'self', 0, 'cls', 0, 0
sh_words:       db 'if', 0, 'then', 0, 'else', 0, 'elif', 0, 'fi', 0, 'for', 0
                db 'in', 0, 'do', 0, 'done', 0, 'while', 0, 'until', 0
                db 'case', 0, 'esac', 0, 'function', 0, 'return', 0
                db 'export', 0, 'local', 0, 'readonly', 0, 'echo', 0, 'cd', 0
                db 'exit', 0, 'set', 0, 'unset', 0, 'shift', 0, 'source', 0
                db 'true', 0, 'false', 0, 'yes', 0, 'no', 0, 'on', 0, 'off', 0
                db 'null', 0, 0
json_words:     db 'true', 0, 'false', 0, 'null', 0, 0
asm_equ:        db 'equ', 0, 0
asm_dirs:       db 'section', 0, 'segment', 0, 'global', 0, 'extern', 0
                db 'bits', 0, 'default', 0, 'org', 0, 'align', 0, 'alignb', 0
                db 'db', 0, 'dw', 0, 'dd', 0, 'dq', 0, 'dt', 0, 'do', 0, 'dy', 0
                db 'resb', 0, 'resw', 0, 'resd', 0, 'resq', 0, 'rest', 0
                db 'reso', 0, 'resy', 0, 'equ', 0, 'times', 0, 'incbin', 0
                db 'struc', 0, 'endstruc', 0, 'istruc', 0, 'iend', 0, 'at', 0
                db 'absolute', 0, 'common', 0, 'static', 0, 'cpu', 0, 0
asm_sizes:      db 'byte', 0, 'word', 0, 'dword', 0, 'qword', 0, 'tword', 0
                db 'oword', 0, 'yword', 0, 'zword', 0, 'ptr', 0, 'rel', 0
                db 'abs', 0, 'near', 0, 'far', 0, 'short', 0, 'strict', 0, 0
asm_regs:       db 'rax', 0, 'rbx', 0, 'rcx', 0, 'rdx', 0, 'rsi', 0, 'rdi', 0
                db 'rbp', 0, 'rsp', 0, 'eax', 0, 'ebx', 0, 'ecx', 0, 'edx', 0
                db 'esi', 0, 'edi', 0, 'ebp', 0, 'esp', 0, 'ax', 0, 'bx', 0
                db 'cx', 0, 'dx', 0, 'si', 0, 'di', 0, 'bp', 0, 'sp', 0
                db 'al', 0, 'bl', 0, 'cl', 0, 'dl', 0, 'ah', 0, 'bh', 0, 'ch', 0
                db 'dh', 0, 'sil', 0, 'dil', 0, 'bpl', 0, 'spl', 0, 'rip', 0
                db 'cs', 0, 'ds', 0, 'es', 0, 'fs', 0, 'gs', 0, 'ss', 0, 0

section .bss
lex_lang:       resd 1
lx_w:           resb 8
