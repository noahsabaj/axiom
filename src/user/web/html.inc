; =============================================================================
;  web/html.inc - HTML into a tree of nodes
;
;    html_parse(RSI = bytes, RCX = how many) -> RAX = the document's node.
;      doc_title (NUL-ended UTF-8) is its <title>; html_elements counts
;      its elements. latin1 = 1 takes the bytes as Windows-1252, else UTF-8.
;  A tokenizer (tags with their attributes, text, comments, doctypes; the
;  raw text of script and style; the text of title and textarea, its
;  character references undone) feeding a tree builder with the rules a
;  browser keeps most: elements that never have content (br, img, ...),
;  a p closed by a block that begins, li, dt, dd, tr, td, th, option and
;  table sections closed by the next of their kind, an end tag closing up
;  to its element (and ignored if it is not open).
;  Nodes (N_*) and attributes (AT_*) are in the arena. Element and
;  attribute names are lower case.
;    node_attr(RDI = an element, RSI = a lower-case name) -> RAX = its
;      value, RCX = bytes; RAX = 0 if it has none
;    utf8_put(EAX = a code point, RDI = to) -> RDI past it
; =============================================================================

NT_DOC          equ 0
NT_ELEM         equ 1
NT_TEXT         equ 2

N_TYPE          equ 0                   ; byte NT_*
N_TAG           equ 1                   ; byte T_*
N_FLAGS         equ 2                   ; word, the layout's
N_LEN           equ 4                   ; dword: the text's bytes, or the name's
N_PARENT        equ 8
N_FIRST         equ 16
N_LAST          equ 24
N_NEXT          equ 32
N_ATTRS         equ 40
N_TEXT          equ 48                  ; text (UTF-8), or the element's name
N_PREV          equ 56
N_SIZE          equ 64

AT_NEXT         equ 0
AT_NAME         equ 8
AT_NLEN         equ 16                  ; dword
AT_VLEN         equ 20                  ; dword
AT_VAL          equ 24
AT_SIZE         equ 32

STACK_MAX       equ 512
NAME_MAX        equ 32
TITLE_MAX       equ 256

; a tag's kind
TF_BLOCK        equ 1                   ; begins a block
TF_VOID         equ 2                   ; never has content
TF_HIDE         equ 4                   ; not shown, nor what is in it
TF_RAW          equ 8                   ; its text is raw, to its end tag
TF_RCDATA       equ 16                  ; likewise, but references undone
TF_CLOSEP       equ 32                  ; closes an open p
TF_SCOPE        equ 64                  ; what closing looks no further past

%macro TAG 2                            ; name, TF_*
    %defstr %%s %1
T_%1 equ ($ - tag_table) / 16
    db %%s
    times 12 - %strlen(%%s) db 0
    dd %2
%endmacro

section .rodata
align 16
tag_table:
    TAG unknown,    0
    TAG html,       TF_BLOCK | TF_SCOPE
    TAG head,       TF_HIDE
    TAG body,       TF_BLOCK | TF_SCOPE
    TAG title,      TF_HIDE | TF_RCDATA
    TAG meta,       TF_HIDE | TF_VOID
    TAG link,       TF_HIDE | TF_VOID
    TAG style,      TF_HIDE | TF_RAW
    TAG script,     TF_HIDE | TF_RAW
    TAG noscript,   0
    TAG base,       TF_HIDE | TF_VOID
    TAG template,   TF_HIDE
    TAG p,          TF_BLOCK | TF_CLOSEP
    TAG div,        TF_BLOCK | TF_CLOSEP
    TAG span,       0
    TAG a,          0
    TAG br,         TF_VOID
    TAG hr,         TF_BLOCK | TF_VOID | TF_CLOSEP
    TAG img,        TF_VOID
    TAG h1,         TF_BLOCK | TF_CLOSEP
    TAG h2,         TF_BLOCK | TF_CLOSEP
    TAG h3,         TF_BLOCK | TF_CLOSEP
    TAG h4,         TF_BLOCK | TF_CLOSEP
    TAG h5,         TF_BLOCK | TF_CLOSEP
    TAG h6,         TF_BLOCK | TF_CLOSEP
    TAG ul,         TF_BLOCK | TF_CLOSEP
    TAG ol,         TF_BLOCK | TF_CLOSEP
    TAG menu,       TF_BLOCK | TF_CLOSEP
    TAG li,         TF_BLOCK
    TAG dl,         TF_BLOCK | TF_CLOSEP
    TAG dt,         TF_BLOCK
    TAG dd,         TF_BLOCK
    TAG pre,        TF_BLOCK | TF_CLOSEP
    TAG listing,    TF_BLOCK | TF_CLOSEP
    TAG xmp,        TF_BLOCK | TF_CLOSEP | TF_RAW
    TAG plaintext,  TF_BLOCK | TF_CLOSEP | TF_RAW
    TAG code,       0
    TAG tt,         0
    TAG kbd,        0
    TAG samp,       0
    TAG b,          0
    TAG strong,     0
    TAG i,          0
    TAG em,         0
    TAG cite,       0
    TAG var,        0
    TAG dfn,        0
    TAG u,          0
    TAG ins,        0
    TAG s,          0
    TAG strike,     0
    TAG del,        0
    TAG small,      0
    TAG big,        0
    TAG sub,        0
    TAG sup,        0
    TAG mark,       0
    TAG q,          0
    TAG abbr,       0
    TAG font,       0
    TAG nobr,       0
    TAG center,     TF_BLOCK | TF_CLOSEP
    TAG blockquote, TF_BLOCK | TF_CLOSEP
    TAG address,    TF_BLOCK | TF_CLOSEP
    TAG table,      TF_BLOCK | TF_CLOSEP | TF_SCOPE
    TAG caption,    TF_BLOCK | TF_SCOPE
    TAG thead,      TF_BLOCK
    TAG tbody,      TF_BLOCK
    TAG tfoot,      TF_BLOCK
    TAG tr,         TF_BLOCK
    TAG td,         TF_SCOPE
    TAG th,         TF_SCOPE
    TAG col,        TF_VOID | TF_HIDE
    TAG colgroup,   TF_HIDE
    TAG form,       TF_BLOCK | TF_CLOSEP
    TAG fieldset,   TF_BLOCK | TF_CLOSEP
    TAG legend,     TF_BLOCK
    TAG label,      0
    TAG input,      TF_VOID
    TAG button,     TF_SCOPE
    TAG select,     0
    TAG option,     TF_HIDE
    TAG optgroup,   TF_HIDE
    TAG textarea,   TF_RCDATA
    TAG header,     TF_BLOCK | TF_CLOSEP
    TAG footer,     TF_BLOCK | TF_CLOSEP
    TAG nav,        TF_BLOCK | TF_CLOSEP
    TAG section,    TF_BLOCK | TF_CLOSEP
    TAG article,    TF_BLOCK | TF_CLOSEP
    TAG main,       TF_BLOCK | TF_CLOSEP
    TAG aside,      TF_BLOCK | TF_CLOSEP
    TAG hgroup,     TF_BLOCK | TF_CLOSEP
    TAG figure,     TF_BLOCK | TF_CLOSEP
    TAG figcaption, TF_BLOCK | TF_CLOSEP
    TAG details,    TF_BLOCK | TF_CLOSEP
    TAG summary,    TF_BLOCK | TF_CLOSEP
    TAG dialog,     TF_HIDE
    TAG iframe,     TF_HIDE
    TAG frameset,   TF_HIDE
    TAG frame,      TF_HIDE | TF_VOID
    TAG noframes,   0
    TAG svg,        TF_HIDE
    TAG math,       TF_HIDE
    TAG canvas,     TF_HIDE
    TAG video,      TF_HIDE
    TAG audio,      TF_HIDE
    TAG object,     TF_HIDE
    TAG embed,      TF_HIDE | TF_VOID
    TAG param,      TF_HIDE | TF_VOID
    TAG source,     TF_HIDE | TF_VOID
    TAG track,      TF_HIDE | TF_VOID
    TAG picture,    0
    TAG map,        0
    TAG area,       TF_HIDE | TF_VOID
    TAG wbr,        TF_VOID
    TAG time,       0
    TAG data,       0
    TAG output,     0
    TAG progress,   0
    TAG meter,      0
tag_table_end:
TAGS            equ (tag_table_end - tag_table) / 16

section .text

; tag_flags(EAX = T_*) -> EAX = its TF_*. Preserves others.
tag_flags:
    shl eax, 4
    lea rax, [tag_table + rax + 12]
    mov eax, [rax]
    ret

; tag_lookup(RSI = a lower-case name, ECX = bytes) -> EAX = T_*, T_unknown
; if it is none of ours
tag_lookup:
    push rbx
    push rdi
    mov ebx, 1
    cmp ecx, 11
    ja .none
.next:
    cmp ebx, TAGS
    jae .none
    mov edi, ebx
    shl edi, 4
    lea rdi, [tag_table + rdi]
    cmp byte [rdi + rcx], 0             ; the same length
    jne .skip
    push rcx
    push rsi
    repe cmpsb
    pop rsi
    pop rcx
    je .found
.skip:
    inc ebx
    jmp .next
.found:
    mov eax, ebx
    jmp .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rbx
    ret

; new_node(EDI = NT_*) -> RAX, or 0 if the arena is full
new_node:
    push rdi
    mov edi, N_SIZE
    call ar_alloc
    pop rdi
    test rax, rax
    jz .out
    mov [rax + N_TYPE], dil
.out:
    ret

; append(RDI = parent, RSI = child)
append:
    mov [rsi + N_PARENT], rdi
    mov rax, [rdi + N_LAST]
    mov [rsi + N_PREV], rax
    test rax, rax
    jz .first
    mov [rax + N_NEXT], rsi
    jmp .last
.first:
    mov [rdi + N_FIRST], rsi
.last:
    mov [rdi + N_LAST], rsi
    ret

; -----------------------------------------------------------------------------
;  The parser. R12: where it reads; R13: the end of the bytes.
; -----------------------------------------------------------------------------

html_parse:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi
    lea r13, [rsi + rcx]
    mov byte [doc_title], 0
    mov byte [title_done], 0
    mov qword [html_elements], 0
    mov edi, NT_DOC
    call new_node
    test rax, rax
    jz .out
    mov [doc_root], rax
    mov [open_stack], rax
    mov dword [depth], 1
.token:
    cmp r12, r13
    jae .done
    cmp byte [r12], '<'
    jne .text
    lea rax, [r12 + 1]
    cmp rax, r13
    jae .text
    movzx eax, byte [r12 + 1]
    call is_alpha
    jc .start_tag
    cmp al, '/'
    je .maybe_end
    cmp al, '!'
    je .bang
    cmp al, '?'
    je .to_gt
    jmp .text
.maybe_end:
    lea rax, [r12 + 2]
    cmp rax, r13
    jae .text
    movzx eax, byte [r12 + 2]
    call is_alpha
    jnc .to_gt                          ; "</ ..." or "</>": ignored
    call end_tag
    jmp .token
.start_tag:
    call start_tag
    jmp .token
.bang:
    mov rax, r13
    sub rax, r12
    cmp rax, 4
    jb .to_gt
    cmp word [r12 + 2], '--'
    jne .to_gt
    add r12, 4                          ; a comment, to "-->"
.comment:
    lea rax, [r12 + 3]
    cmp rax, r13
    ja .done
    cmp word [r12], '--'
    jne .comment_next
    cmp byte [r12 + 2], '>'
    je .comment_end
.comment_next:
    inc r12
    jmp .comment
.comment_end:
    add r12, 3
    jmp .token
.to_gt:
    cmp r12, r13
    jae .done
    cmp byte [r12], '>'
    je .past_gt
    inc r12
    jmp .to_gt
.past_gt:
    inc r12
    jmp .token
.text:                                  ; to the next '<' (past this one)
    mov rsi, r12
    inc r12
.text_end:
    cmp r12, r13
    jae .text_got
    cmp byte [r12], '<'
    je .text_got
    inc r12
    jmp .text_end
.text_got:
    mov rcx, r12
    sub rcx, rsi
    mov edx, 1
    call add_text
    jmp .token
.done:
    mov rax, [doc_root]
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; is_alpha(AL) -> CF if a letter. Preserves all.
is_alpha:
    push rax
    or al, 0x20
    cmp al, 'a'
    jb .no
    cmp al, 'z'
    ja .no
    pop rax
    stc
    ret
.no:
    pop rax
    clc
    ret

; is_space(AL) -> ZF if HTML's whitespace. Preserves all.
is_space:
    cmp al, ' '
    je .out
    cmp al, 10
    je .out
    cmp al, 9
    je .out
    cmp al, 13
    je .out
    cmp al, 12
.out:
    ret

; read_name: the name at R12 (to a space, '/', '>' or '='), lower case, into
; name_buf (NAME_MAX at most kept) -> ECX = its bytes; R12 past it
read_name:
    xor ecx, ecx
.char:
    cmp r12, r13
    jae .out
    mov al, [r12]
    call is_space
    je .out
    cmp al, '>'
    je .out
    cmp al, '/'
    je .out
    cmp al, '='
    jne .keep
    test ecx, ecx                       ; "=" first: part of the name
    jnz .out
.keep:
    call to_lower
    cmp ecx, NAME_MAX - 1
    jae .over
    mov [name_buf + rcx], al
    inc ecx
.over:
    inc r12
    jmp .char
.out:
    mov byte [name_buf + rcx], 0
    ret

; skip_space: R12 past whitespace
skip_space:
    cmp r12, r13
    jae .out
    mov al, [r12]
    call is_space
    jne .out
    inc r12
    jmp skip_space
.out:
    ret

; copy_name(ECX = bytes in name_buf) -> RAX = a copy in the arena
copy_name:
    push rcx
    lea edi, [ecx + 1]
    call ar_raw
    pop rcx
    test rax, rax
    jz .out
    push rcx
    lea rsi, [name_buf]
    mov rdi, rax
    rep movsb
    mov byte [rdi], 0
    pop rcx
.out:
    ret

; start_tag: at '<' and a letter
start_tag:
    push rbx
    push r14
    push r15
    inc r12
    call read_name
    lea rsi, [name_buf]
    push rcx
    call tag_lookup
    pop rcx
    mov r14d, eax                       ; R14D: T_*
    mov edi, NT_ELEM
    call new_node
    test rax, rax
    jz .skip_tag
    mov rbx, rax                        ; RBX: the element
    mov [rbx + N_TAG], r14b
    mov [rbx + N_LEN], ecx
    call copy_name
    mov [rbx + N_TEXT], rax
    xor r15d, r15d                      ; R15: its last attribute
    mov byte [self_closing], 0
.attr:
    call skip_space
    cmp r12, r13
    jae .attrs_done
    mov al, [r12]
    cmp al, '>'
    je .close_gt
    cmp al, '/'
    jne .attr_name
    inc r12
    cmp r12, r13
    jae .attrs_done
    cmp byte [r12], '>'
    jne .attr
    mov byte [self_closing], 1
    jmp .close_gt
.attr_name:
    call read_name
    test ecx, ecx
    jnz .named
    inc r12                             ; a stray quote, or such
    jmp .attr
.named:
    push rcx
    mov edi, AT_SIZE
    call ar_alloc
    pop rcx
    test rax, rax
    jz .attr
    push rax
    mov [rax + AT_NLEN], ecx
    call copy_name
    mov rdx, rax
    pop rax
    mov [rax + AT_NAME], rdx
    test r15, r15                       ; kept in order
    jz .first_attr
    mov [r15 + AT_NEXT], rax
    jmp .linked
.first_attr:
    mov [rbx + N_ATTRS], rax
.linked:
    mov r15, rax
    call skip_space
    cmp r12, r13
    jae .attrs_done
    cmp byte [r12], '='
    jne .attr                           ; no value: ""
    inc r12
    call skip_space
    cmp r12, r13
    jae .attrs_done
    mov al, [r12]
    cmp al, '"'
    je .quoted
    cmp al, "'"
    je .quoted
    mov rsi, r12                        ; unquoted: to a space or '>'
.unquoted:
    cmp r12, r13
    jae .value
    mov al, [r12]
    call is_space
    je .value
    cmp al, '>'
    je .value
    inc r12
    jmp .unquoted
.quoted:
    inc r12
    mov rsi, r12
.to_quote:
    cmp r12, r13
    jae .value
    cmp [r12], al
    je .value_q
    inc r12
    jmp .to_quote
.value_q:
    mov rcx, r12
    sub rcx, rsi
    inc r12
    jmp .decode
.value:
    mov rcx, r12
    sub rcx, rsi
.decode:
    mov edx, 1
    call decode
    mov [r15 + AT_VAL], rax
    mov [r15 + AT_VLEN], edx
    jmp .attr
.close_gt:
    inc r12
.attrs_done:
    inc qword [html_elements]
    mov rdi, rbx
    call insert
    jmp .out
.skip_tag:
    cmp r12, r13
    jae .out
    cmp byte [r12], '>'
    je .skipped
    inc r12
    jmp .skip_tag
.skipped:
    inc r12
.out:
    pop r15
    pop r14
    pop rbx
    ret

; insert(RDI = a new element, R12 past its tag): into the tree by the rules
insert:
    push rbx
    push r14
    mov rbx, rdi
    movzx r14d, byte [rbx + N_TAG]
    cmp r14d, T_html                    ; html, head, body: their content goes
    je .ignored                         ; where it is, they are not made again
    cmp r14d, T_body
    je .ignored
    cmp r14d, T_head
    je .ignored
    mov eax, r14d
    call tag_flags
    test eax, TF_CLOSEP
    jz .not_p
    mov edi, T_p
    mov esi, T_p
    call close_open
.not_p:
    cmp r14d, T_li
    jne .not_li
    mov edi, T_li
    mov esi, T_li
    mov edx, T_ul
    mov ecx, T_ol
    call close_until
    jmp .rules_done
.not_li:
    cmp r14d, T_dt
    je .dt_dd
    cmp r14d, T_dd
    jne .not_dt
.dt_dd:
    mov edi, T_dt
    mov esi, T_dd
    mov edx, T_dl
    mov ecx, T_dl
    call close_until
    jmp .rules_done
.not_dt:
    cmp r14d, T_tr
    jne .not_tr
    call close_cell                     ; a row: the cell and row open end
    call close_row
    jmp .rules_done
.not_tr:
    cmp r14d, T_td
    je .cell
    cmp r14d, T_th
    jne .not_cell
.cell:
    call close_cell
    jmp .rules_done
.not_cell:
    cmp r14d, T_thead
    jb .not_section
    cmp r14d, T_tfoot
    ja .not_section
    call close_cell                     ; thead, tbody, tfoot: and any row
    call close_row
    mov edi, T_thead
    mov esi, T_tbody
    mov edx, T_table
    mov ecx, T_table
    call close_until
    mov edi, T_tfoot
    mov esi, T_tfoot
    mov edx, T_table
    mov ecx, T_table
    call close_until
    jmp .rules_done
.not_section:
    cmp r14d, T_option
    jne .not_option
    mov eax, [depth]
    mov rax, [open_stack + rax * 8 - 8]
    cmp byte [rax + N_TAG], T_option
    jne .rules_done
    dec dword [depth]
    jmp .rules_done
.not_option:
    cmp r14d, T_a
    jne .not_a
    mov edi, T_a
    mov esi, T_a
    call close_open
    jmp .rules_done
.not_a:
    cmp r14d, T_h1
    jb .rules_done
    cmp r14d, T_h6
    ja .rules_done
    mov eax, [depth]                    ; a heading in a heading: that one ends
    mov rax, [open_stack + rax * 8 - 8]
    movzx eax, byte [rax + N_TAG]
    cmp eax, T_h1
    jb .rules_done
    cmp eax, T_h6
    ja .rules_done
    dec dword [depth]
.rules_done:
    mov eax, [depth]
    mov rdi, [open_stack + rax * 8 - 8]
    mov rsi, rbx
    call append
    mov eax, r14d
    call tag_flags
    test eax, TF_RAW | TF_RCDATA
    jnz .raw
    test eax, TF_VOID
    jnz .out
    cmp byte [self_closing], 0          ; "<x/>" only for what may be empty
    jne .out
    mov eax, [depth]
    cmp eax, STACK_MAX
    jae .out
    mov [open_stack + rax * 8], rbx
    inc dword [depth]
    jmp .out
.raw:                                   ; its text, to "</name"
    push rax
    mov rsi, r12
    mov rdi, rsi
.find_end:
    lea rax, [rdi + 2]
    cmp rax, r13
    jae .raw_all
    cmp word [rdi], '</'
    jne .raw_next
    push rsi
    lea rsi, [rdi + 2]
    mov ecx, [rbx + N_LEN]
    mov rax, r13
    sub rax, rsi
    cmp rax, rcx
    jb .raw_no
    push rdi
    mov rdi, [rbx + N_TEXT]
    call ci_eq_n
    pop rdi
    jne .raw_no
    cmp rax, rcx                        ; "</scripts": not its end
    je .raw_match
    movzx eax, byte [rsi + rcx]
    call is_alpha
    jnc .raw_match
    test esp, esp                       ; ZF clear
    jmp .raw_no
.raw_match:
    cmp eax, eax
.raw_no:
    pop rsi
    je .raw_found
.raw_next:
    inc rdi
    jmp .find_end
.raw_all:
    mov rdi, r13
.raw_found:
    mov rcx, rdi
    sub rcx, rsi
    mov r12, rdi                        ; then past its end tag
.past:
    cmp r12, r13
    jae .past_done
    cmp byte [r12], '>'
    je .past_gt
    inc r12
    jmp .past
.past_gt:
    inc r12
.past_done:
    pop rax
    xor edx, edx
    test eax, TF_RCDATA
    setnz dl
    test rcx, rcx
    jz .raw_empty
    call decode
    push rax
    push rdx
    mov edi, NT_TEXT
    call new_node
    pop rdx
    pop rcx
    test rax, rax
    jz .raw_empty
    mov [rax + N_TEXT], rcx
    mov [rax + N_LEN], edx
    mov rdi, rbx
    mov rsi, rax
    call append
    cmp r14d, T_title
    jne .raw_empty
    cmp byte [title_done], 0
    jne .raw_empty
    mov byte [title_done], 1
    mov rsi, [rbx + N_FIRST]
    mov ecx, [rsi + N_LEN]
    mov rsi, [rsi + N_TEXT]
    cmp ecx, TITLE_MAX - 1
    jb .title_len
    mov ecx, TITLE_MAX - 1
.title_len:
    lea rdi, [doc_title]
    rep movsb
    mov byte [rdi], 0
.raw_empty:
    jmp .out
.ignored:
.out:
    pop r14
    pop rbx
    ret

; ci_eq_n(RSI = bytes, ECX = how many, RDI = lower-case) -> ZF if the
; bytes are the first ECX of RDI's, whatever their case. Preserves all.
ci_eq_n:
    push rax
    push rcx
    push rsi
    push rdi
.char:
    test ecx, ecx
    jz .yes
    mov al, [rsi]
    call to_lower
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.yes:
    cmp eax, eax
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; close_cell: a td or th open in this row ends; close_row: a tr open in
; this table
close_cell:
    mov edi, T_td
    mov esi, T_th
    mov edx, T_tr
    mov ecx, T_table
    jmp close_until

close_row:
    mov edi, T_tr
    mov esi, T_tr
    mov edx, T_table
    mov ecx, T_table
    jmp close_until

; close_open(EDI, ESI = T_* either of which is closed, if one is open,
; looking no further than an element of TF_SCOPE)
close_open:
    mov edx, -1
    mov ecx, -1
    ; fall through
; close_until(EDI, ESI = T_* to close, EDX, ECX = T_* to look no further
; than, as well as TF_SCOPE): the nearest open one, and all above it
close_until:
    push rbx
    push r12
    mov r8d, edx
    mov r9d, ecx
    mov ebx, [depth]
.look:
    dec ebx
    jz .out                             ; the document itself
    mov rax, [open_stack + rbx * 8]
    movzx eax, byte [rax + N_TAG]
    cmp eax, edi
    je .close
    cmp eax, esi
    je .close
    cmp eax, r8d
    je .out
    cmp eax, r9d
    je .out
    call tag_flags
    test eax, TF_SCOPE
    jnz .out
    jmp .look
.close:
    mov [depth], ebx
.out:
    pop r12
    pop rbx
    ret

; end_tag: at "</" and a letter
end_tag:
    push rbx
    add r12, 2
    call read_name
.to_gt:
    cmp r12, r13
    jae .named
    cmp byte [r12], '>'
    je .gt
    inc r12
    jmp .to_gt
.gt:
    inc r12
.named:
    lea rsi, [name_buf]
    push rcx
    call tag_lookup
    pop rcx
    cmp eax, T_br                       ; "</br>" is a br
    jne .not_br
    mov edi, NT_ELEM
    call new_node
    test rax, rax
    jz .out
    mov byte [rax + N_TAG], T_br
    mov rbx, rax
    mov eax, [depth]
    mov rdi, [open_stack + rax * 8 - 8]
    mov rsi, rbx
    call append
    jmp .out
.not_br:
    mov ebx, [depth]                    ; its element, the nearest open
.look:
    dec ebx
    jz .out
    mov rdx, [open_stack + rbx * 8]
    movzx edi, byte [rdx + N_TAG]
    cmp edi, eax
    jne .other
    test eax, eax                       ; one of ours: the same tag
    jnz .found
    cmp [rdx + N_LEN], ecx              ; unknown: the same name
    jne .next
    push rsi
    push rdi
    push rcx
    mov rdi, [rdx + N_TEXT]
    repe cmpsb
    pop rcx
    pop rdi
    pop rsi
    je .found
    jmp .next
.other:
    push rax                            ; not past a table, a cell, ...
    mov eax, edi
    call tag_flags
    test eax, TF_SCOPE
    pop rax
    jz .next
    cmp edi, T_td                       ; but a table's own end tags close
    je .in_cell                         ; the cell they are in
    cmp edi, T_th
    je .in_cell
    cmp edi, T_caption
    jne .out
.in_cell:
    cmp eax, T_table
    je .next
    cmp eax, T_tr
    je .next
    cmp eax, T_thead
    jb .out
    cmp eax, T_tfoot
    ja .out
.next:
    jmp .look
.found:
    mov [depth], ebx
.out:
    pop rbx
    ret

; add_text(RSI = bytes, RCX = how many, EDX = 1 to undo references): a text
; node, under the element open last
add_text:
    test rcx, rcx
    jz .out
    call decode
    test rax, rax
    jz .out
    push rax
    push rdx
    mov edi, NT_TEXT
    call new_node
    pop rdx
    pop rcx
    test rax, rax
    jz .out
    mov [rax + N_TEXT], rcx
    mov [rax + N_LEN], edx
    mov rsi, rax
    mov eax, [depth]
    mov rdi, [open_stack + rax * 8 - 8]
    call append
.out:
    ret

; decode(RSI = bytes, RCX = how many, EDX = 1 to undo character references)
; -> RAX = them as UTF-8 in the arena (0 if it is full), EDX = bytes
decode:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi
    lea r13, [rsi + rcx]
    mov r14d, edx
    lea rdi, [rcx * 3 + 8]
    call ar_raw
    test rax, rax
    jz .out
    mov rbx, rax
    mov rdi, rax
.char:
    cmp r12, r13
    jae .done
    movzx eax, byte [r12]
    cmp al, '&'
    jne .not_ref
    test r14d, r14d
    jz .not_ref
    call reference
    jc .not_ref
    call utf8_put
    jmp .char
.not_ref:
    movzx eax, byte [r12]
    inc r12
    cmp eax, 0x80
    jb .ascii
    cmp byte [latin1], 0
    je .ascii                           ; UTF-8 already
    cmp eax, 0xA0
    jae .cp
    lea rcx, [cp1252]
    movzx eax, word [rcx + rax * 2 - 0x100]
.cp:
    call utf8_put
    jmp .char
.ascii:
    test eax, eax
    jz .char                            ; NULs dropped
    mov [rdi], al
    inc rdi
    jmp .char
.done:
    mov rdx, rdi
    sub rdx, rbx
    mov rax, rbx
    mov rcx, rdx
    lea rdi, [rbx + rcx]                ; what was not used goes back
    mov rsi, [ar_top]
    lea rcx, [rdi + 7]
    and rcx, -8
    cmp rcx, rsi
    ja .out
    mov [ar_top], rcx
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; reference(R12 = at '&', R13 = the end) -> EAX = the code point, R12 past
; it; CF (R12 unmoved) if it is not one
reference:
    push rbx
    push rsi
    push rdi
    push rdx
    lea rsi, [r12 + 1]
    cmp rsi, r13
    jae .no
    cmp byte [rsi], '#'
    je .numeric
    lea rbx, [entities]                 ; named: the longest that matches
.entity:
    cmp byte [rbx], 0
    je .no
    mov rdi, rbx
    lea rsi, [r12 + 1]
.ent_char:
    mov al, [rdi]
    test al, al
    jz .ent_end
    cmp rsi, r13
    jae .ent_next
    cmp al, [rsi]
    jne .ent_next
    inc rdi
    inc rsi
    jmp .ent_char
.ent_end:                               ; the name, then ';' (or not, at worst)
    cmp rsi, r13
    jae .ent_hit
    cmp byte [rsi], ';'
    jne .ent_bare
    inc rsi
    jmp .ent_hit
.ent_bare:
    movzx eax, byte [rsi]               ; "&ampx", "&copy=1": only before no
    call is_alpha                       ; letter, digit or '=' (a query's)
    jc .ent_next
    cmp al, '='
    je .ent_next
    sub al, '0'
    cmp al, 9
    jbe .ent_next
.ent_hit:
    mov r12, rsi
    mov eax, [rdi + 1]
    clc
    jmp .out
.ent_next:
    mov al, [rdi]                       ; past this one's name and code
    inc rdi
    test al, al
    jnz .ent_next
    lea rbx, [rdi + 4]
    jmp .entity
.numeric:
    inc rsi
    xor eax, eax
    xor ecx, ecx                        ; ECX: digits
    cmp rsi, r13
    jae .no
    mov dl, [rsi]
    or dl, 0x20
    cmp dl, 'x'
    je .hex
.dec:
    cmp rsi, r13
    jae .num_end
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .num_end
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    cmp eax, 0x10FFFF
    ja .no
    jmp .dec
.hex:
    inc rsi
.hex_digit:
    cmp rsi, r13
    jae .num_end
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    jbe .hex_add
    movzx edx, byte [rsi]
    or edx, 0x20
    sub edx, 'a'
    cmp edx, 5
    ja .num_end
    add edx, 10
.hex_add:
    shl eax, 4
    add eax, edx
    inc rsi
    inc ecx
    cmp eax, 0x10FFFF
    ja .no
    jmp .hex_digit
.num_end:
    test ecx, ecx
    jz .no
    cmp rsi, r13
    jae .num_done
    cmp byte [rsi], ';'
    jne .num_done
    inc rsi
.num_done:
    mov r12, rsi
    test eax, eax
    jz .replace
    mov edx, eax                        ; a surrogate is no character
    and edx, ~0x7FF
    cmp edx, 0xD800
    je .replace
    cmp eax, 0x80                       ; the C1 range, as Windows-1252
    jb .num_ok
    cmp eax, 0xA0
    jae .num_ok
    lea rdx, [cp1252]
    movzx eax, word [rdx + rax * 2 - 0x100]
.num_ok:
    clc
    jmp .out
.replace:
    mov eax, 0xFFFD
    clc
    jmp .out
.no:
    stc
.out:
    pop rdx
    pop rdi
    pop rsi
    pop rbx
    ret

utf8_put:
    cmp eax, 0x80
    jae .two
    mov [rdi], al
    inc rdi
    ret
.two:
    cmp eax, 0x800
    jae .three
    mov ecx, eax
    shr ecx, 6
    or cl, 0xC0
    mov [rdi], cl
    and al, 0x3F
    or al, 0x80
    mov [rdi + 1], al
    add rdi, 2
    ret
.three:
    cmp eax, 0x10000
    jae .four
    mov ecx, eax
    shr ecx, 12
    or cl, 0xE0
    mov [rdi], cl
    mov ecx, eax
    shr ecx, 6
    and cl, 0x3F
    or cl, 0x80
    mov [rdi + 1], cl
    and al, 0x3F
    or al, 0x80
    mov [rdi + 2], al
    add rdi, 3
    ret
.four:
    mov ecx, eax
    shr ecx, 18
    or cl, 0xF0
    mov [rdi], cl
    mov ecx, eax
    shr ecx, 12
    and cl, 0x3F
    or cl, 0x80
    mov [rdi + 1], cl
    mov ecx, eax
    shr ecx, 6
    and cl, 0x3F
    or cl, 0x80
    mov [rdi + 2], cl
    and al, 0x3F
    or al, 0x80
    mov [rdi + 3], al
    add rdi, 4
    ret

node_attr:
    push rbx
    push r12
    push rdi
    mov r12, rsi
    mov rbx, [rdi + N_ATTRS]
.next:
    test rbx, rbx
    jz .none
    mov rsi, [rbx + AT_NAME]
    mov ecx, [rbx + AT_NLEN]
    mov rdi, r12
    call ci_eq
    je .found
    mov rbx, [rbx + AT_NEXT]
    jmp .next
.found:
    mov rax, [rbx + AT_VAL]
    mov ecx, [rbx + AT_VLEN]
    test rax, rax
    jnz .out
    lea rax, [s_empty]                  ; there, with no value
    xor ecx, ecx
    jmp .out
.none:
    xor eax, eax
    xor ecx, ecx
.out:
    pop rdi
    mov rsi, r12
    pop r12
    pop rbx
    ret

section .rodata
s_empty:        db 0
; Windows-1252's 0x80..0x9F
cp1252:         dw 0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021
                dw 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8D, 0x017D, 0x8F
                dw 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014
                dw 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178

%macro ENT 2                            ; name, code point
    db %1, 0
    dd %2
%endmacro
entities:
    ENT 'amp', '&'
    ENT 'lt', '<'
    ENT 'gt', '>'
    ENT 'quot', '"'
    ENT 'apos', 39
    ENT 'nbsp', 0xA0
    ENT 'ndash', 0x2013
    ENT 'mdash', 0x2014
    ENT 'lsquo', 0x2018
    ENT 'rsquo', 0x2019
    ENT 'sbquo', 0x201A
    ENT 'ldquo', 0x201C
    ENT 'rdquo', 0x201D
    ENT 'bdquo', 0x201E
    ENT 'dagger', 0x2020
    ENT 'Dagger', 0x2021
    ENT 'bull', 0x2022
    ENT 'hellip', 0x2026
    ENT 'permil', 0x2030
    ENT 'prime', 0x2032
    ENT 'Prime', 0x2033
    ENT 'lsaquo', 0x2039
    ENT 'rsaquo', 0x203A
    ENT 'euro', 0x20AC
    ENT 'trade', 0x2122
    ENT 'larr', 0x2190
    ENT 'uarr', 0x2191
    ENT 'rarr', 0x2192
    ENT 'darr', 0x2193
    ENT 'harr', 0x2194
    ENT 'rArr', 0x21D2
    ENT 'minus', 0x2212
    ENT 'radic', 0x221A
    ENT 'infin', 0x221E
    ENT 'asymp', 0x2248
    ENT 'ne', 0x2260
    ENT 'le', 0x2264
    ENT 'ge', 0x2265
    ENT 'OElig', 0x0152
    ENT 'oelig', 0x0153
    ENT 'Scaron', 0x0160
    ENT 'scaron', 0x0161
    ENT 'Yuml', 0x0178
    ENT 'fnof', 0x0192
    ENT 'circ', 0x02C6
    ENT 'tilde', 0x02DC
    ENT 'ensp', 0x2002
    ENT 'emsp', 0x2003
    ENT 'thinsp', 0x2009
    ENT 'zwnj', 0x200C
    ENT 'zwj', 0x200D
    ENT 'lrm', 0x200E
    ENT 'rlm', 0x200F
    ENT 'iexcl', 0xA1
    ENT 'cent', 0xA2
    ENT 'pound', 0xA3
    ENT 'curren', 0xA4
    ENT 'yen', 0xA5
    ENT 'brvbar', 0xA6
    ENT 'sect', 0xA7
    ENT 'uml', 0xA8
    ENT 'copy', 0xA9
    ENT 'ordf', 0xAA
    ENT 'laquo', 0xAB
    ENT 'not', 0xAC
    ENT 'shy', 0xAD
    ENT 'reg', 0xAE
    ENT 'macr', 0xAF
    ENT 'deg', 0xB0
    ENT 'plusmn', 0xB1
    ENT 'sup2', 0xB2
    ENT 'sup3', 0xB3
    ENT 'acute', 0xB4
    ENT 'micro', 0xB5
    ENT 'para', 0xB6
    ENT 'middot', 0xB7
    ENT 'cedil', 0xB8
    ENT 'sup1', 0xB9
    ENT 'ordm', 0xBA
    ENT 'raquo', 0xBB
    ENT 'frac14', 0xBC
    ENT 'frac12', 0xBD
    ENT 'frac34', 0xBE
    ENT 'iquest', 0xBF
    ENT 'Agrave', 0xC0
    ENT 'Aacute', 0xC1
    ENT 'Acirc', 0xC2
    ENT 'Atilde', 0xC3
    ENT 'Auml', 0xC4
    ENT 'Aring', 0xC5
    ENT 'AElig', 0xC6
    ENT 'Ccedil', 0xC7
    ENT 'Egrave', 0xC8
    ENT 'Eacute', 0xC9
    ENT 'Ecirc', 0xCA
    ENT 'Euml', 0xCB
    ENT 'Igrave', 0xCC
    ENT 'Iacute', 0xCD
    ENT 'Icirc', 0xCE
    ENT 'Iuml', 0xCF
    ENT 'ETH', 0xD0
    ENT 'Ntilde', 0xD1
    ENT 'Ograve', 0xD2
    ENT 'Oacute', 0xD3
    ENT 'Ocirc', 0xD4
    ENT 'Otilde', 0xD5
    ENT 'Ouml', 0xD6
    ENT 'times', 0xD7
    ENT 'Oslash', 0xD8
    ENT 'Ugrave', 0xD9
    ENT 'Uacute', 0xDA
    ENT 'Ucirc', 0xDB
    ENT 'Uuml', 0xDC
    ENT 'Yacute', 0xDD
    ENT 'THORN', 0xDE
    ENT 'szlig', 0xDF
    ENT 'agrave', 0xE0
    ENT 'aacute', 0xE1
    ENT 'acirc', 0xE2
    ENT 'atilde', 0xE3
    ENT 'auml', 0xE4
    ENT 'aring', 0xE5
    ENT 'aelig', 0xE6
    ENT 'ccedil', 0xE7
    ENT 'egrave', 0xE8
    ENT 'eacute', 0xE9
    ENT 'ecirc', 0xEA
    ENT 'euml', 0xEB
    ENT 'igrave', 0xEC
    ENT 'iacute', 0xED
    ENT 'icirc', 0xEE
    ENT 'iuml', 0xEF
    ENT 'eth', 0xF0
    ENT 'ntilde', 0xF1
    ENT 'ograve', 0xF2
    ENT 'oacute', 0xF3
    ENT 'ocirc', 0xF4
    ENT 'otilde', 0xF5
    ENT 'ouml', 0xF6
    ENT 'divide', 0xF7
    ENT 'oslash', 0xF8
    ENT 'ugrave', 0xF9
    ENT 'uacute', 0xFA
    ENT 'ucirc', 0xFB
    ENT 'uuml', 0xFC
    ENT 'yacute', 0xFD
    ENT 'thorn', 0xFE
    ENT 'yuml', 0xFF
    db 0

section .bss
alignb 8
doc_root:       resq 1
html_elements:  resq 1
open_stack:     resq STACK_MAX
depth:          resd 1
latin1:         resb 1
self_closing:   resb 1
title_done:     resb 1
name_buf:       resb NAME_MAX
doc_title:      resb TITLE_MAX

section .text
