; =============================================================================
;  web/layout.inc - the document laid out at a width: a display list
;
;    layout(RDI = the document's node, ESI = the width) -> doc_height. The
;      display list is dl_base to dl_top, DI_SIZE bytes an item, in the
;      document's pixels: text runs (DK_TEXT: a font, a colour, UTF-8 to
;      draw from the pen at DI_X on the baseline DI_Y, DI_W wide in 1/64
;      pixels, maybe a link's) and rects (DK_RECT). The links are lk_table
;      (lk_count of LK_SIZE: each href as written), the anchors an_table
;      (an_count of AN_SIZE: an id or a's name, and where it is).
;  dl_base and dl_end are the caller's: DL_BYTES of memory.
;
;  The styles are the tags': block or inline (TF_BLOCK), hidden (TF_HIDE,
;  the hidden attribute, style="display:none"); h1-h6 in sizes, bold; b,
;  strong, th bold; i, em, cite, var, dfn, address italic; code, tt, kbd,
;  samp, pre in the monospaced face, a size smaller; u, ins under, s, strike,
;  del through; small, big; a link blue and underlined; font's color and
;  size; align and center. Whitespace collapses, but in pre; words wrap at
;  the right edge; a line is as tall as its tallest font; margins collapse,
;  the larger kept. ul and ol indent, li has a bullet or its number; dd and
;  blockquote indent; hr is a rule, br a break, img its [alt]. A table is
;  its rows, each as tall as its tallest cell, its columns as wide as their
;  text wants when they fit, else the narrow ones so and the rest sharing
;  what is left.
;  The walk is by the nodes' own links, a style (STE_SIZE bytes) pushed for
;  each element entered and popped as it is left; the line being made is
;  the items from line_first to dl_top, given their baseline at its end.
; =============================================================================

DI_KIND         equ 0                   ; byte DK_*
DI_FONT         equ 1                   ; byte
DI_FLAGS        equ 2                   ; word DF_*
DI_LEN          equ 4                   ; dword: the text's bytes
DI_X            equ 8                   ; dword
DI_Y            equ 12                  ; dword: text: the baseline; rect: its top
DI_W            equ 16                  ; dword: text: 1/64 pixels; rect: pixels
DI_COLOR        equ 20                  ; dword
DI_TEXT         equ 24
DI_LINK         equ 32                  ; dword: a link's index + 1, or 0
DI_H            equ 36                  ; dword: a rect's height
DI_SIZE         equ 40
DK_TEXT         equ 1
DK_RECT         equ 2
DF_UNDER        equ 1
DF_PRE          equ 2
DF_STRIKE       equ 4
DF_MASK         equ 7

LK_HREF         equ 0
LK_LEN          equ 8                   ; dword
LK_SIZE         equ 16
LK_MAX          equ 16384
AN_NAME         equ 0
AN_LEN          equ 8                   ; dword
AN_Y            equ 12                  ; dword
AN_SIZE         equ 16
AN_MAX          equ 8192
DL_BYTES        equ 16 << 20

; a style: the element's, from its parent's
ST_FACE         equ 0                   ; byte SB_*
ST_PX           equ 1                   ; byte: the size, WF_PX*
ST_FLAGS        equ 2                   ; word DF_* | SF_*
ST_COLOR        equ 4
ST_LINK         equ 8                   ; the link's index + 1
ST_KIND         equ 12                  ; byte SK_*: what leaving it does
ST_LDEPTH       equ 13                  ; byte: lists it is in
ST_LISTK        equ 14                  ; byte, a list's: 1 bullets, 2 numbers
ST_LEFT         equ 16                  ; its content's edges
ST_RIGHT        equ 20
ST_MB           equ 24                  ; its bottom margin
ST_COUNT        equ 28                  ; a list's: the next number
ST_LIST         equ 32                  ; the list it is in: its style
ST_ROW          equ 40                  ; the row it is in
ST_TABLE        equ 48                  ; the table it is in
ST_ROWTOP       equ 56                  ; a row's: its top, its cells' bottom
ST_ROWBOT       equ 60
ST_COL          equ 64                  ; a row's: the next column
ST_COLS         equ 68                  ; a table's: its columns,
ST_COLW         equ 72                  ; their widths (dwords),
ST_TLEFT        equ 80                  ; its left edge
STE_SIZE        equ 96
STYLES_MAX      equ STACK_MAX + 8       ; the tree is no deeper than that

SB_BOLD         equ 1
SB_ITALIC       equ 2
SB_MONO         equ 4
SF_CENTER       equ 0x100
SF_RIGHT        equ 0x200
SK_NONE         equ 0
SK_BLOCK        equ 1
SK_LI           equ 2
SK_TABLE        equ 3
SK_ROW          equ 4
SK_CELL         equ 5

PX_BASE         equ WF_PX20
BODY_MARGIN     equ 16
INDENT          equ 40
CELL_PAD        equ 4
COLS_MAX        equ 32
TEXT_COLOUR     equ 0x202124
LINK_COLOUR     equ 0x0645AD
FAINT_COLOUR    equ 0x5F6368
RULE_COLOUR     equ 0xC4C7CC

section .text

layout:
    push rbx
    push r12
    mov rbx, rdi                        ; RBX: the document
    mov [lay_width], esi
    mov rax, [dl_base]
    mov [dl_top], rax
    mov [line_first], rax
    xor eax, eax
    mov [lk_count], eax
    mov [an_count], eax
    mov [lay_y], eax
    mov [line_x64], eax
    mov [line_space], al
    mov [marker_on], al
    mov [pre_start], al
    mov [last_node], rax
    mov [cur_node], rax
    mov dword [lay_margin], BODY_MARGIN
    lea rdi, [styles]                   ; the root's style
    mov [st], rdi
    mov ecx, STE_SIZE / 8
    rep stosq
    mov rdi, [st]
    mov byte [rdi + ST_PX], PX_BASE
    mov dword [rdi + ST_COLOR], TEXT_COLOUR
    mov dword [rdi + ST_LEFT], BODY_MARGIN
    mov eax, [lay_width]
    sub eax, BODY_MARGIN
    mov [rdi + ST_RIGHT], eax
    mov r12, [rbx + N_FIRST]            ; R12: the node
    test r12, r12
    jz .done
.visit:
    mov rdi, r12
    call enter
    jc .leave
    mov rax, [r12 + N_FIRST]
    test rax, rax
    jz .leave
    mov r12, rax
    jmp .visit
.leave:
    mov rdi, r12
    call leave
    mov rax, [r12 + N_NEXT]
    test rax, rax
    jz .up
    mov r12, rax
    jmp .visit
.up:
    mov r12, [r12 + N_PARENT]
    test r12, r12
    jz .done
    cmp r12, rbx
    jne .leave
.done:
    call line_end
    mov eax, [lay_y]
    add eax, BODY_MARGIN
    mov [doc_height], eax
    pop r12
    pop rbx
    ret

; style_push: a copy of the style on top, on top
style_push:
    mov rsi, [st]
    lea rdi, [rsi + STE_SIZE]
    lea rax, [styles + (STYLES_MAX - 1) * STE_SIZE]
    cmp rdi, rax
    ja .full
    mov [st], rdi
    mov ecx, STE_SIZE / 8
    rep movsq
    mov rax, [st]
    mov byte [rax + ST_KIND], SK_NONE
    ret
.full:                                  ; (it cannot be: the tree is not so deep)
    ud2

; cur_font -> EDX = the font of the style on top. Preserves all but RDX.
cur_font:
    push rax
    mov rax, [st]
    movzx edx, byte [rax + ST_FACE]
    movzx eax, byte [rax + ST_PX]
    test edx, SB_MONO
    jz .face
    and edx, SB_BOLD                    ; mono, a size smaller
    add edx, WF_MONO
    sub eax, 1
    adc eax, 0
.face:
    and edx, 7
    imul edx, edx, WF_SIZES
    add edx, eax
    pop rax
    ret

; enter(RDI = a node) -> CF if what is in it is not to be walked
enter:
    push rbx
    push r12
    mov rbx, rdi
    cmp byte [rbx + N_TYPE], NT_TEXT
    jne .element
    mov [cur_node], rbx
    mov rsi, [rbx + N_TEXT]
    mov ecx, [rbx + N_LEN]
    call text_run
    stc
    jmp .out
.element:
    call style_push
    movzx r12d, byte [rbx + N_TAG]      ; R12D: T_*
    mov eax, r12d
    call tag_flags
    test eax, TF_HIDE
    jnz .skip
    mov rdi, rbx
    lea rsi, [a_hidden]
    call node_attr
    test rax, rax
    jnz .skip
    mov rdi, rbx
    lea rsi, [a_style]
    call node_attr
    test rax, rax
    jz .shown
    mov rsi, rax
    lea rdi, [s_display_none]
    call ci_find
    test rax, rax
    jnz .skip
    mov rdi, rbx
    lea rsi, [a_style]
    call node_attr
    mov rsi, rax
    lea rdi, [s_display_none2]
    call ci_find
    test rax, rax
    jnz .skip
.shown:
    mov rdi, rbx                        ; an anchor, by its id
    lea rsi, [a_id]
    call node_attr
    test rax, rax
    jz .tag
    call anchor_add
.tag:
    lea rcx, [tag_handlers]             ; its own, if it has one
.find:
    movzx eax, byte [rcx]
    cmp eax, 0xFF
    je .default
    cmp eax, r12d
    je .handler
    add rcx, 16
    jmp .find
.handler:
    mov rax, [rcx + 8]
    mov rdi, rbx
    call rax
    jmp .out                            ; CF as it says
.default:
    mov eax, r12d
    call tag_flags
    test eax, TF_BLOCK
    jz .walk
    xor edi, edi
    xor esi, esi
    call block_begin
.walk:
    clc
    jmp .out
.skip:
    stc
.out:
    pop r12
    pop rbx
    ret

; leave(RDI = a node): what its element's end does, and its style popped
leave:
    cmp byte [rdi + N_TYPE], NT_ELEM
    jne .out
    mov rax, [st]
    movzx ecx, byte [rax + ST_KIND]
    cmp ecx, SK_BLOCK
    je .block
    cmp ecx, SK_LI
    je .li
    cmp ecx, SK_ROW
    je .row
    cmp ecx, SK_CELL
    je .cell
    cmp ecx, SK_TABLE
    je .table
    jmp .pop
.li:
    cmp byte [marker_on], 0             ; an empty item: its marker alone
    je .block
    call line_start
.block:
    call line_end
    mov rax, [st]
    mov eax, [rax + ST_MB]
    cmp eax, [lay_margin]
    jle .pop
    mov [lay_margin], eax
    jmp .pop
.cell:
    call line_end
    mov rax, [st]
    mov rcx, [rax + ST_ROW]
    mov eax, [lay_y]
    add eax, CELL_PAD
    cmp eax, [rcx + ST_ROWBOT]
    jle .cell_done
    mov [rcx + ST_ROWBOT], eax
.cell_done:
    mov dword [lay_margin], 0
    jmp .pop
.row:
    call line_end
    mov rax, [st]
    mov eax, [rax + ST_ROWBOT]
    cmp eax, [lay_y]
    jle .row_done
    mov [lay_y], eax
.row_done:
    mov dword [lay_margin], 0
    jmp .pop
.table:
    call line_end
    cmp dword [lay_margin], CELL_PAD
    jge .pop
    mov dword [lay_margin], CELL_PAD
.pop:
    sub qword [st], STE_SIZE
.out:
    ret

; block_begin(EDI = its top margin, ESI = its bottom margin): the line
; before it ends, the margins collapse
block_begin:
    push rdi
    push rsi
    call line_end
    pop rsi
    pop rdi
    mov rax, [st]
    mov byte [rax + ST_KIND], SK_BLOCK
    mov [rax + ST_MB], esi
    cmp edi, [lay_margin]
    jle .out
    mov [lay_margin], edi
.out:
    ret

; commit_margin: the margin pending, given
commit_margin:
    mov eax, [lay_margin]
    add [lay_y], eax
    mov dword [lay_margin], 0
    ret

; align_attr(RDI = an element): its align, into the style on top
align_attr:
    push rbx
    lea rsi, [a_align]
    call node_attr
    test rax, rax
    jz .out
    mov rbx, [st]
    mov rsi, rax
    lea rdi, [s_center]
    call ci_eq
    jne .not_center
    and word [rbx + ST_FLAGS], ~(SF_CENTER | SF_RIGHT)
    or word [rbx + ST_FLAGS], SF_CENTER
    jmp .out
.not_center:
    lea rdi, [s_middle]
    call ci_eq
    jne .not_middle
    and word [rbx + ST_FLAGS], ~(SF_CENTER | SF_RIGHT)
    or word [rbx + ST_FLAGS], SF_CENTER
    jmp .out
.not_middle:
    lea rdi, [s_right]
    call ci_eq
    jne .not_right
    and word [rbx + ST_FLAGS], ~(SF_CENTER | SF_RIGHT)
    or word [rbx + ST_FLAGS], SF_RIGHT
    jmp .out
.not_right:
    lea rdi, [s_left]
    call ci_eq
    jne .out
    and word [rbx + ST_FLAGS], ~(SF_CENTER | SF_RIGHT)
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Lines
; -----------------------------------------------------------------------------

; line_start: before the first thing on a line, the margin pending given,
; and a list item's marker put there
line_start:
    mov rax, [dl_top]
    cmp rax, [line_first]
    jne .out
    cmp dword [line_x64], 0
    jne .out
    call commit_margin
    cmp byte [marker_on], 0
    je .out
    mov byte [marker_on], 0
    push rbx
    call item_new
    jc .no_room
    mov rbx, rax
    mov byte [rbx + DI_KIND], DK_TEXT
    mov al, [marker_font]
    mov [rbx + DI_FONT], al
    mov eax, [marker_len]
    mov [rbx + DI_LEN], eax
    mov eax, [marker_x]
    mov [rbx + DI_X], eax
    mov eax, [marker_w64]
    mov [rbx + DI_W], eax
    mov eax, [marker_colour]
    mov [rbx + DI_COLOR], eax
    mov rax, [marker_text]
    mov [rbx + DI_TEXT], rax
    mov qword [last_node], 0
.no_room:
    pop rbx
.out:
    ret

; item_new -> RAX = a zeroed item at the display list's end; CF if it is full
item_new:
    mov rax, [dl_top]
    lea rcx, [rax + DI_SIZE]
    cmp rcx, [dl_end]
    ja .full
    mov [dl_top], rcx
    xor ecx, ecx
    mov [rax], rcx
    mov [rax + 8], rcx
    mov [rax + 16], rcx
    mov [rax + 24], rcx
    mov [rax + 32], rcx
    clc
    ret
.full:
    stc
    ret

; line_end: the line made, if any: its items given its baseline (and moved
; for its alignment), and the next line's top below it
line_end:
    push rbx
    push r12
    push r13
    mov byte [line_space], 0
    mov rbx, [line_first]
    cmp rbx, [dl_top]
    je .empty
    xor r12d, r12d                      ; R12D, R13D: the most above and below
    xor r13d, r13d
.measure:
    movzx edx, byte [rbx + DI_FONT]
    call font_entry
    mov eax, [r11 + WFT_ASCENT]
    cmp eax, r12d
    cmovg r12d, eax
    mov eax, [r11 + WFT_DESCENT]
    cmp eax, r13d
    cmovg r13d, eax
    add rbx, DI_SIZE
    cmp rbx, [dl_top]
    jb .measure
    xor ecx, ecx                        ; ECX: how far it moves
    mov rax, [st]
    movzx edx, word [rax + ST_FLAGS]
    test edx, SF_CENTER | SF_RIGHT
    jz .moved
    mov ecx, [rax + ST_RIGHT]
    sub ecx, [rax + ST_LEFT]
    mov eax, [line_x64]
    add eax, 63
    shr eax, 6
    sub ecx, eax
    jge .room
    xor ecx, ecx
.room:
    test edx, SF_CENTER
    jz .moved
    shr ecx, 1
.moved:
    mov eax, [lay_y]
    add eax, r12d
    mov rbx, [line_first]
.place:
    mov [rbx + DI_Y], eax
    add [rbx + DI_X], ecx
    add rbx, DI_SIZE
    cmp rbx, [dl_top]
    jb .place
    add r12d, r13d
    add [lay_y], r12d
    mov [line_first], rbx
.empty:
    mov dword [line_x64], 0
    mov qword [last_node], 0
    pop r13
    pop r12
    pop rbx
    ret

; force_break: the line ends, and if nothing was on it, it is a line still
force_break:
    call line_start
    mov rax, [dl_top]
    cmp rax, [line_first]
    jne line_end
    call cur_font
    call font_entry
    mov eax, [r11 + WFT_LINE]
    add [lay_y], eax
    jmp line_end

; text_run(RSI = text, ECX = bytes; cur_node = whose): onto the lines, as
; the style on top says
text_run:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rsi                        ; R12: at; R13: the end
    lea r13, [rsi + rcx]
    mov rax, [st]
    test word [rax + ST_FLAGS], DF_PRE
    jnz .pre
.space:
    cmp r12, r13
    jae .out
    movzx eax, byte [r12]
    call is_space
    jne .word
    mov byte [line_space], 1
    inc r12
    jmp .space
.word:
    mov r14, r12
.word_end:
    inc r12
    cmp r12, r13
    jae .word_got
    movzx eax, byte [r12]
    call is_space
    jne .word_end
.word_got:
    mov rsi, r14
    mov rcx, r12
    sub rcx, r14
    xor edx, edx
    call add_run
    jmp .space
.pre:                                   ; lines as they are; a tab to the next
    cmp byte [pre_start], 0             ; eighth space; the first newline of a
    je .segment                         ; pre dropped
    mov byte [pre_start], 0
    cmp r12, r13
    jae .out
    cmp byte [r12], 13
    jne .lf
    inc r12
    cmp r12, r13
    jae .out
.lf:
    cmp byte [r12], 10
    jne .segment
    inc r12
.segment:
    mov r14, r12
.scan:
    cmp r12, r13
    jae .segment_got
    movzx eax, byte [r12]
    cmp eax, 10
    je .segment_got
    cmp eax, 13
    je .segment_got
    cmp eax, 9
    je .segment_got
    inc r12
    jmp .scan
.segment_got:
    mov rcx, r12
    sub rcx, r14
    jz .control
    mov rsi, r14
    mov edx, 1
    call add_run
.control:
    cmp r12, r13
    jae .out
    movzx eax, byte [r12]
    inc r12
    cmp eax, 10
    je .newline
    cmp eax, 9
    jne .segment
    call line_start                     ; a tab
    call cur_font
    call font_entry
    mov ecx, [r11 + WFT_SPACE]
    shl ecx, 3
    mov eax, [line_x64]
    xor edx, edx
    div ecx
    inc eax
    imul eax, ecx
    mov [line_x64], eax
    jmp .segment
.newline:
    call force_break
    jmp .segment
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; add_run(RSI = text, ECX = bytes, EDX = 1 if it is not to wrap): a word, or
; a pre's piece of a line, in the style on top, onto the line, after a
; space if one is pending; the line ends first if it would not fit
add_run:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rsi                        ; R12, R13D: the text
    mov r13d, ecx
    mov r15d, edx                       ; R15D: not to wrap
    call cur_font
    mov r14d, edx                       ; R14D: the font
    call text_w64
    mov ebx, eax                        ; EBX: its width, 1/64 pixels
    xor ecx, ecx                        ; ECX: the space before it
    cmp byte [line_space], 0
    je .spaced
    cmp dword [line_x64], 0
    je .spaced
    mov edx, r14d
    call font_entry
    mov ecx, [r11 + WFT_SPACE]
.spaced:
    test r15d, r15d
    jnz .place
    cmp dword [line_x64], 0
    je .place
    mov rax, [st]
    mov edx, [rax + ST_RIGHT]
    sub edx, [rax + ST_LEFT]
    shl edx, 6
    mov eax, [line_x64]
    add eax, ecx
    add eax, ebx
    cmp eax, edx
    jle .place
    call line_end
    xor ecx, ecx
.place:
    mov byte [line_space], 0
    push rcx
    call line_start
    pop rcx
    mov rax, [dl_top]                   ; the last item, of this node, alike:
    cmp rax, [line_first]               ; it takes this word too
    je .new
    sub rax, DI_SIZE
    mov rdx, [cur_node]
    test rdx, rdx
    jz .new
    cmp rdx, [last_node]
    jne .new
    test r15d, r15d
    jnz .new
    cmp [rax + DI_FONT], r14b
    jne .new
    mov r8, [st]
    mov edx, [r8 + ST_COLOR]
    cmp [rax + DI_COLOR], edx
    jne .new
    mov edx, [r8 + ST_LINK]
    cmp [rax + DI_LINK], edx
    jne .new
    movzx edx, word [r8 + ST_FLAGS]
    and edx, DF_MASK
    cmp [rax + DI_FLAGS], dx
    jne .new
    lea rdx, [r12 + r13]
    sub rdx, [rax + DI_TEXT]
    mov [rax + DI_LEN], edx
    add ecx, ebx
    add [rax + DI_W], ecx
    add [line_x64], ecx
    jmp .out
.new:
    add [line_x64], ecx
    call item_new
    jc .out
    mov byte [rax + DI_KIND], DK_TEXT
    mov [rax + DI_FONT], r14b
    mov r8, [st]
    movzx edx, word [r8 + ST_FLAGS]
    and edx, DF_MASK
    mov [rax + DI_FLAGS], dx
    mov [rax + DI_LEN], r13d
    mov edx, [line_x64]
    shr edx, 6
    add edx, [r8 + ST_LEFT]
    mov [rax + DI_X], edx
    mov [rax + DI_W], ebx
    mov edx, [r8 + ST_COLOR]
    mov [rax + DI_COLOR], edx
    mov edx, [r8 + ST_LINK]
    mov [rax + DI_LINK], edx
    mov [rax + DI_TEXT], r12
    add [line_x64], ebx
    mov rax, [cur_node]
    mov [last_node], rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; rect_add(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour)
rect_add:
    push rcx
    call item_new
    pop rcx
    jc .out
    mov byte [rax + DI_KIND], DK_RECT
    mov [rax + DI_X], edi
    mov [rax + DI_Y], esi
    mov [rax + DI_W], edx
    mov [rax + DI_H], ecx
    mov [rax + DI_COLOR], r8d
    mov rcx, [dl_top]
    mov [line_first], rcx
.out:
    ret

; anchor_add(RAX = a name, ECX = bytes): here
anchor_add:
    mov edx, [an_count]
    cmp edx, AN_MAX
    jae .out
    test ecx, ecx
    jz .out
    inc dword [an_count]
    shl edx, 4
    lea rdx, [an_table + rdx]
    mov [rdx + AN_NAME], rax
    mov [rdx + AN_LEN], ecx
    mov eax, [lay_y]
    mov rcx, [dl_top]
    cmp rcx, [line_first]
    jne .y
    cmp dword [line_x64], 0
    jne .y
    add eax, [lay_margin]
.y:
    mov [rdx + AN_Y], eax
.out:
    ret

; -----------------------------------------------------------------------------
;  The tags' own (RDI = the element, its style pushed) -> CF if what is in
;  it is not to be walked
; -----------------------------------------------------------------------------

; px_set(EAX = a size, clamped): the style on top's
px_set:
    test eax, eax
    jns .low
    xor eax, eax
.low:
    cmp eax, WF_SIZES - 1
    jle .high
    mov eax, WF_SIZES - 1
.high:
    mov rcx, [st]
    mov [rcx + ST_PX], al
    ret

h_para:
    push rdi
    mov edi, 20
    mov esi, 20
    call block_begin
    pop rdi
    call align_attr
    clc
    ret

h_div:
    push rdi
    xor edi, edi
    xor esi, esi
    call block_begin
    pop rdi
    call align_attr
    clc
    ret

h_heading:                              ; h1 .. h6
    push rbx
    mov rbx, rdi
    movzx eax, byte [rbx + N_TAG]
    sub eax, T_h1
    lea rcx, [heading_margins]
    movzx edi, byte [rcx + rax]
    mov esi, edi
    push rax
    call block_begin
    pop rax
    lea rcx, [heading_px]
    movzx eax, byte [rcx + rax]
    call px_set
    mov rax, [st]
    or byte [rax + ST_FACE], SB_BOLD
    mov rdi, rbx
    call align_attr
    pop rbx
    clc
    ret

h_list:                                 ; ul, ol, menu
    push rbx
    mov rbx, rdi
    mov edi, 20
    mov rax, [st]
    cmp byte [rax + ST_LDEPTH], 0       ; a list in a list: no margins
    je .margins
    xor edi, edi
.margins:
    mov esi, edi
    call block_begin
    mov rax, [st]
    add dword [rax + ST_LEFT], INDENT
    inc byte [rax + ST_LDEPTH]
    mov [rax + ST_LIST], rax
    mov byte [rax + ST_LISTK], 1
    mov dword [rax + ST_COUNT], 1
    cmp byte [rbx + N_TAG], T_ol
    jne .out
    mov byte [rax + ST_LISTK], 2
    mov rdi, rbx
    lea rsi, [a_start]
    call node_attr
    test rax, rax
    jz .out
    mov rsi, rax
    call dec_parse
    jc .out
    mov rcx, [st]
    mov [rcx + ST_COUNT], eax
.out:
    pop rbx
    clc
    ret

h_li:
    push rbx
    push r12
    xor edi, edi
    xor esi, esi
    call block_begin
    mov rbx, [st]
    mov byte [rbx + ST_KIND], SK_LI
    mov r12, [rbx + ST_LIST]            ; R12: the list's style, or 0
    test r12, r12
    jz .bullet
    cmp byte [r12 + ST_LISTK], 2
    jne .bullet
    mov edi, 16                         ; "N."
    call ar_raw
    test rax, rax
    jz .none
    mov [marker_text], rax
    mov [out_ptr], rax
    add rax, 15
    mov [out_end], rax
    mov edi, [r12 + ST_COUNT]
    inc dword [r12 + ST_COUNT]
    call put_u
    lea rsi, [s_dot]
    call put_str
    mov rax, [out_ptr]
    sub rax, [marker_text]
    mov [marker_len], eax
    mov r12d, 8                         ; R12D: the gap after it
    jmp .measure
.bullet:
    movzx eax, byte [rbx + ST_LDEPTH]
    cmp eax, 3
    jbe .depth
    mov eax, 3
.depth:
    lea rcx, [bullets]
    mov rax, [rcx + rax * 8]
    mov [marker_text], rax
    mov dword [marker_len], 3
    mov r12d, 10
.measure:
    call cur_font
    mov [marker_font], dl
    mov rsi, [marker_text]
    mov ecx, [marker_len]
    call text_w64
    mov [marker_w64], eax
    add eax, 63
    shr eax, 6
    mov ecx, [rbx + ST_LEFT]
    sub ecx, eax
    sub ecx, r12d
    mov [marker_x], ecx
    mov eax, [rbx + ST_COLOR]
    mov [marker_colour], eax
    mov byte [marker_on], 1
.none:
    pop r12
    pop rbx
    clc
    ret

h_dl:
    mov edi, 20
    mov esi, 20
    call block_begin
    clc
    ret

h_dd:
    xor edi, edi
    xor esi, esi
    call block_begin
    mov rax, [st]
    add dword [rax + ST_LEFT], INDENT
    clc
    ret

h_pre:                                  ; pre, listing, xmp, plaintext
    mov edi, 20
    mov esi, 20
    call block_begin
    mov rax, [st]
    or byte [rax + ST_FACE], SB_MONO
    or word [rax + ST_FLAGS], DF_PRE
    mov byte [pre_start], 1
    clc
    ret

h_quote:                                ; blockquote, figure
    mov edi, 20
    mov esi, 20
    call block_begin
    mov rax, [st]
    add dword [rax + ST_LEFT], INDENT
    sub dword [rax + ST_RIGHT], INDENT
    clc
    ret

h_center:                               ; center, caption
    xor edi, edi
    xor esi, esi
    call block_begin
    mov rax, [st]
    and word [rax + ST_FLAGS], ~SF_RIGHT
    or word [rax + ST_FLAGS], SF_CENTER
    clc
    ret

h_address:
    xor edi, edi
    xor esi, esi
    call block_begin
    mov rax, [st]
    or byte [rax + ST_FACE], SB_ITALIC
    clc
    ret

h_hr:
    mov edi, 10
    mov esi, 10
    call block_begin
    call commit_margin
    mov rax, [st]
    mov edi, [rax + ST_LEFT]
    mov edx, [rax + ST_RIGHT]
    sub edx, edi
    mov esi, [lay_y]
    mov ecx, 2
    mov r8d, RULE_COLOUR
    call rect_add
    add dword [lay_y], 2
    stc
    ret

h_br:
    call force_break
    stc
    ret

h_img:                                  ; "[alt]", or "[image]" if it has none
    push rbx
    mov rbx, rdi
    lea rsi, [a_alt]
    call node_attr
    test rax, rax
    jnz .alt
    lea rax, [s_image]
    mov ecx, 5
.alt:
    test ecx, ecx
    jz .out                             ; alt="": nothing to show
    push rax
    push rcx
    lea edi, [ecx + 2]
    call ar_raw
    pop rcx
    pop rsi
    test rax, rax
    jz .out
    mov rdi, rax
    mov byte [rdi], '['
    inc rdi
    push rcx
    rep movsb
    pop rcx
    mov byte [rdi], ']'
    mov [cur_node], rbx
    mov rdx, [st]
    mov dword [rdx + ST_COLOR], FAINT_COLOUR
    mov rsi, rax
    add ecx, 2
    call text_run
.out:
    pop rbx
    stc
    ret

h_bold:                                 ; b, strong
    mov rax, [st]
    or byte [rax + ST_FACE], SB_BOLD
    clc
    ret

h_italic:                               ; i, em, cite, var, dfn
    mov rax, [st]
    or byte [rax + ST_FACE], SB_ITALIC
    clc
    ret

h_mono:                                 ; code, tt, kbd, samp
    mov rax, [st]
    or byte [rax + ST_FACE], SB_MONO
    clc
    ret

h_under:                                ; u, ins
    mov rax, [st]
    or word [rax + ST_FLAGS], DF_UNDER
    clc
    ret

h_strike:                               ; s, strike, del
    mov rax, [st]
    or word [rax + ST_FLAGS], DF_STRIKE
    clc
    ret

h_small:                                ; small, sub, sup
    mov rax, [st]
    movzx eax, byte [rax + ST_PX]
    dec eax
    call px_set
    clc
    ret

h_big:
    mov rax, [st]
    movzx eax, byte [rax + ST_PX]
    inc eax
    call px_set
    clc
    ret

h_textarea:
    mov rax, [st]
    or byte [rax + ST_FACE], SB_MONO
    or word [rax + ST_FLAGS], DF_PRE
    clc
    ret

h_link:                                 ; a: an anchor by its name, a link by
    push rbx                            ; its href
    mov rbx, rdi
    lea rsi, [a_name]
    call node_attr
    test rax, rax
    jz .href
    call anchor_add
.href:
    mov rdi, rbx
    lea rsi, [a_href]
    call node_attr
    test rax, rax
    jz .out
    mov edx, [lk_count]
    cmp edx, LK_MAX
    jae .out
    inc dword [lk_count]
    mov r8, rdx
    shl r8, 4
    lea r8, [lk_table + r8]
    mov [r8 + LK_HREF], rax
    mov [r8 + LK_LEN], ecx
    mov rax, [st]
    inc edx
    mov [rax + ST_LINK], edx
    mov dword [rax + ST_COLOR], LINK_COLOUR
    or word [rax + ST_FLAGS], DF_UNDER
.out:
    pop rbx
    clc
    ret

h_font:                                 ; its color and size
    push rbx
    mov rbx, rdi
    lea rsi, [a_color]
    call node_attr
    test rax, rax
    jz .size
    mov rsi, rax
    call colour_parse
    jc .size
    mov rcx, [st]
    mov [rcx + ST_COLOR], eax
.size:
    mov rdi, rbx
    lea rsi, [a_size]
    call node_attr
    test rax, rax
    jz .out
    test ecx, ecx
    jz .out
    mov rsi, rax
    movzx edx, byte [rsi]               ; "+n", "-n", or n of 1 to 7
    cmp edx, '+'
    je .relative
    cmp edx, '-'
    je .relative
    call dec_parse
    jc .out
    lea rcx, [font_px]
    cmp eax, 7
    jbe .table
    mov eax, 7
.table:
    movzx eax, byte [rcx + rax]
    call px_set
    jmp .out
.relative:
    inc rsi
    dec ecx
    push rdx
    call dec_parse
    pop rdx
    jc .out
    cmp edx, '-'
    jne .plus
    neg eax
.plus:
    mov rcx, [st]
    movzx ecx, byte [rcx + ST_PX]
    add eax, ecx
    call px_set
.out:
    pop rbx
    clc
    ret

h_none:                                 ; thead, tbody, tfoot: their rows
    clc
    ret

h_table:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    xor edi, edi
    xor esi, esi
    call block_begin
    call commit_margin
    mov r12, [st]                       ; R12: its style
    mov byte [r12 + ST_KIND], SK_TABLE
    mov [r12 + ST_TABLE], r12
    mov qword [r12 + ST_ROW], 0
    and word [r12 + ST_FLAGS], ~(SF_CENTER | SF_RIGHT)
    mov rdi, rbx
    call table_measure
    mov r13d, eax                       ; R13D: its columns
    mov [r12 + ST_COLS], eax
    mov edi, COLS_MAX * 4
    call ar_alloc
    test rax, rax
    jz .none
    mov [r12 + ST_COLW], rax
    mov r14, rax                        ; R14: their widths
    test r13d, r13d
    jz .done
    mov r15d, [r12 + ST_RIGHT]          ; R15D: the room
    sub r15d, [r12 + ST_LEFT]
    xor ecx, ecx                        ; each as it wants, plus its padding;
    xor edx, edx                        ; EDX: all of them
.want:
    mov eax, [col_want + rcx * 4]
    add eax, 2 * CELL_PAD + 1
    mov [r14 + rcx * 4], eax
    add edx, eax
    inc ecx
    cmp ecx, r13d
    jb .want
    cmp edx, r15d
    jle .placed
    mov eax, r15d                       ; too wide: those under a fair share
    xor edx, edx                        ; keep theirs, the others share what
    div r13d                            ; is left by what they want
    mov r8d, eax                        ; R8D: a fair share
    mov r9d, r15d                       ; R9D: what is left; R10D: what the
    xor r10d, r10d                      ; others want
    xor ecx, ecx
.shares:
    mov eax, [r14 + rcx * 4]
    cmp eax, r8d
    jg .wide
    sub r9d, eax
    jmp .shared
.wide:
    add r10d, eax
.shared:
    inc ecx
    cmp ecx, r13d
    jb .shares
    test r10d, r10d
    jz .placed
    xor ecx, ecx
.share:
    mov eax, [r14 + rcx * 4]
    cmp eax, r8d
    jle .kept
    imul rax, r9
    xor edx, edx
    div r10
    cmp eax, 2 * CELL_PAD + 16
    jge .width
    mov eax, 2 * CELL_PAD + 16
.width:
    mov [r14 + rcx * 4], eax
.kept:
    inc ecx
    cmp ecx, r13d
    jb .share
.placed:
    mov eax, [r12 + ST_LEFT]            ; its left edge: centred if it says so
    mov [r12 + ST_TLEFT], eax
    mov rdi, rbx
    lea rsi, [a_align]
    call node_attr
    test rax, rax
    jz .done
    mov rsi, rax
    lea rdi, [s_center]
    call ci_eq
    jne .done
    xor ecx, ecx
    xor edx, edx
.total:
    add edx, [r14 + rcx * 4]
    inc ecx
    cmp ecx, r13d
    jb .total
    mov eax, r15d
    sub eax, edx
    jle .done
    shr eax, 1
    add [r12 + ST_TLEFT], eax
    jmp .done
.none:
    mov dword [r12 + ST_COLS], 0
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    clc
    ret

h_row:                                  ; tr
    mov rax, [st]
    cmp qword [rax + ST_TABLE], 0
    je h_div                            ; not in a table: a block
    push rdi
    xor edi, edi
    xor esi, esi
    call block_begin
    call commit_margin
    pop rdi
    mov rax, [st]
    mov byte [rax + ST_KIND], SK_ROW
    mov [rax + ST_ROW], rax
    mov ecx, [lay_y]
    mov [rax + ST_ROWTOP], ecx
    mov [rax + ST_ROWBOT], ecx
    mov dword [rax + ST_COL], 0
    call align_attr
    clc
    ret

h_cell:                                 ; td, th
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [st]                       ; R12: its style
    mov r13, [r12 + ST_TABLE]           ; R13: the table's
    cmp qword [r12 + ST_ROW], 0
    je .block
    cmp dword [r13 + ST_COLS], 0
    je .block
    cmp qword [r13 + ST_COLW], 0
    je .block
    call line_end
    mov byte [r12 + ST_KIND], SK_CELL
    mov rdi, rbx                        ; the columns it takes
    call colspan
    mov r8d, eax                        ; R8D: how many
    mov rcx, [r12 + ST_ROW]
    mov r9d, [rcx + ST_COL]             ; R9D: the first
    add [rcx + ST_COL], eax
    mov eax, [r13 + ST_COLS]
    cmp r9d, eax
    jb .first
    lea r9d, [rax - 1]
.first:
    sub eax, r9d
    cmp r8d, eax
    jbe .count
    mov r8d, eax
.count:
    mov r10, [r13 + ST_COLW]
    mov edi, [r13 + ST_TLEFT]           ; EDI: its left edge
    xor ecx, ecx
.before:
    cmp ecx, r9d
    jae .span
    add edi, [r10 + rcx * 4]
    inc ecx
    jmp .before
.span:
    mov esi, edi                        ; ESI: its right
.across:
    add esi, [r10 + rcx * 4]
    inc ecx
    dec r8d
    jnz .across
    add edi, CELL_PAD
    sub esi, CELL_PAD
    cmp esi, edi
    jge .edges
    mov esi, edi
.edges:
    mov [r12 + ST_LEFT], edi
    mov [r12 + ST_RIGHT], esi
    mov rcx, [r12 + ST_ROW]
    mov eax, [rcx + ST_ROWTOP]
    add eax, CELL_PAD
    mov [lay_y], eax
    mov dword [lay_margin], 0
    cmp byte [rbx + N_TAG], T_th
    jne .align
    or byte [r12 + ST_FACE], SB_BOLD
    and word [r12 + ST_FLAGS], ~SF_RIGHT
    or word [r12 + ST_FLAGS], SF_CENTER
.align:
    mov rdi, rbx
    call align_attr
    jmp .out
.block:
    mov rdi, rbx
    call h_div
.out:
    pop r13
    pop r12
    pop rbx
    clc
    ret

; colspan(RDI = a cell) -> EAX = its colspan, 1 to COLS_MAX
colspan:
    lea rsi, [a_colspan]
    call node_attr
    mov edx, 1
    test rax, rax
    jz .one
    mov rsi, rax
    call dec_parse
    jc .one
    mov edx, eax
    test edx, edx
    jnz .most
    mov edx, 1
.most:
    cmp edx, COLS_MAX
    jbe .one
    mov edx, COLS_MAX
.one:
    mov eax, edx
    ret

; table_measure(RDI = a table) -> EAX = its columns; col_want[] what each
; wants: the widest of its one-column cells' text, in pixels
table_measure:
    push rbx
    push r12
    push r13
    push r14
    mov rbx, rdi
    lea rdi, [col_want]
    xor eax, eax
    mov ecx, COLS_MAX
    rep stosd
    xor r14d, r14d                      ; R14D: the columns
    mov r12, [rbx + N_FIRST]            ; R12: a row, or a section of rows
.child:
    test r12, r12
    jz .done
    cmp byte [r12 + N_TYPE], NT_ELEM
    jne .next_child
    movzx eax, byte [r12 + N_TAG]
    cmp eax, T_tr
    je .row_here
    cmp eax, T_thead
    jb .next_child
    cmp eax, T_tfoot
    ja .next_child
    mov r13, [r12 + N_FIRST]            ; a section: its rows
.section:
    test r13, r13
    jz .next_child
    cmp byte [r13 + N_TYPE], NT_ELEM
    jne .next_row
    cmp byte [r13 + N_TAG], T_tr
    jne .next_row
    mov rdi, r13
    call row_measure
    cmp eax, r14d
    cmova r14d, eax
.next_row:
    mov r13, [r13 + N_NEXT]
    jmp .section
.row_here:
    mov rdi, r12
    call row_measure
    cmp eax, r14d
    cmova r14d, eax
.next_child:
    mov r12, [r12 + N_NEXT]
    jmp .child
.done:
    mov eax, r14d
    cmp eax, COLS_MAX
    jbe .out
    mov eax, COLS_MAX
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; row_measure(RDI = a tr) -> EAX = its columns, col_want[] widened
row_measure:
    push rbx
    push r12
    mov rbx, [rdi + N_FIRST]
    xor r12d, r12d                      ; R12D: the next column
.cell:
    test rbx, rbx
    jz .done
    cmp byte [rbx + N_TYPE], NT_ELEM
    jne .next
    movzx eax, byte [rbx + N_TAG]
    cmp eax, T_td
    je .measure
    cmp eax, T_th
    jne .next
.measure:
    mov rdi, rbx
    call colspan
    cmp eax, 1
    jne .spans
    cmp r12d, COLS_MAX
    jae .spans
    mov rdi, rbx
    call cell_want
    cmp eax, [col_want + r12 * 4]
    jbe .one
    mov [col_want + r12 * 4], eax
.one:
    mov eax, 1
.spans:
    add r12d, eax
.next:
    mov rbx, [rbx + N_NEXT]
    jmp .cell
.done:
    mov eax, r12d
    pop r12
    pop rbx
    ret

; cell_want(RDI = a cell) -> EAX = the width of its widest line of text
; and images' [alt], unwrapped, in its row's font made bold (so that what
; is bold in it fits too), in pixels
cell_want:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi                        ; R12: the cell
    call cur_font
    mov eax, edx                        ; its bold face
    xor edx, edx
    mov ecx, WF_SIZES
    div ecx
    or eax, SB_BOLD
    imul eax, eax, WF_SIZES
    add eax, edx
    mov edx, eax
    mov r15d, edx                       ; R15D: the font
    call font_entry
    mov r14d, [r11 + WFT_SPACE]         ; R14D: a space
    xor r13d, r13d                      ; R13D: this line; EBP: the widest
    push rbp
    xor ebp, ebp
    mov rbx, [r12 + N_FIRST]
.node:
    test rbx, rbx
    jz .done
    cmp byte [rbx + N_TYPE], NT_TEXT
    je .text
    movzx eax, byte [rbx + N_TAG]
    cmp eax, T_br
    jne .element
    cmp r13d, ebp
    cmova ebp, r13d
    xor r13d, r13d
    jmp .past
.element:
    cmp eax, T_img
    je .img
    call tag_flags
    test eax, TF_HIDE
    jnz .past
    mov rax, [rbx + N_FIRST]            ; into it
    test rax, rax
    jz .past
    mov rbx, rax
    jmp .node
.text:
    mov rsi, [rbx + N_TEXT]
    mov ecx, [rbx + N_LEN]
    lea rdi, [rsi + rcx]
.space:
    cmp rsi, rdi
    jae .past
    movzx eax, byte [rsi]
    call is_space
    jne .word
    inc rsi
    jmp .space
.word:
    mov rdx, rsi
.word_end:
    inc rsi
    cmp rsi, rdi
    jae .word_got
    movzx eax, byte [rsi]
    call is_space
    jne .word_end
.word_got:
    push rsi
    push rdi
    mov rcx, rsi
    sub rcx, rdx
    mov rsi, rdx
    mov edx, r15d
    call text_w64
    pop rdi
    pop rsi
    test r13d, r13d
    jz .first
    add r13d, r14d
.first:
    add r13d, eax
    jmp .space
.img:                                   ; "[alt]", as h_img shows it
    mov rdi, rbx
    lea rsi, [a_alt]
    call node_attr
    test rax, rax
    jnz .alt
    lea rax, [s_image]
    mov ecx, 5
.alt:
    test ecx, ecx
    jz .past
    mov rsi, rax
    mov edx, r15d
    call text_w64
    add r13d, eax
    lea rsi, [s_brackets]
    mov ecx, 2
    call text_w64
    add r13d, eax
    jmp .past
.past:                                  ; the next node in the cell, in order
    mov rax, [rbx + N_NEXT]
    test rax, rax
    jnz .sibling
    mov rbx, [rbx + N_PARENT]
    test rbx, rbx
    jz .done
    cmp rbx, r12
    je .done
    jmp .past
.sibling:
    mov rbx, rax
    jmp .node
.done:
    cmp r13d, ebp
    cmova ebp, r13d
    lea eax, [rbp + 63]
    shr eax, 6
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; colour_parse(RSI = a value, ECX = bytes) -> EAX = 0xRRGGBB; CF if it is
; not one: "#rgb", "#rrggbb", or a name of the basic sixteen and a few
colour_parse:
    push rbx
    test ecx, ecx
    jz .no
    cmp byte [rsi], '#'
    jne .name
    inc rsi
    dec ecx
    cmp ecx, 3
    je .short
    cmp ecx, 6
    jne .no
    xor ebx, ebx
.long:
    call hex_digit
    jc .no
    shl ebx, 4
    or ebx, eax
    inc rsi
    dec ecx
    jnz .long
    mov eax, ebx
    clc
    jmp .out
.short:
    xor ebx, ebx
.short_digit:
    call hex_digit
    jc .no
    shl ebx, 8
    imul eax, eax, 0x11
    or ebx, eax
    inc rsi
    dec ecx
    jnz .short_digit
    mov eax, ebx
    clc
    jmp .out
.name:
    lea rbx, [colour_names]
.try:
    cmp byte [rbx], 0
    je .no
    mov rdi, rbx
    call ci_eq
    je .found
.skip:
    inc rbx
    cmp byte [rbx - 1], 0
    jne .skip
    add rbx, 4
    jmp .try
.found:
    inc rbx
    cmp byte [rbx - 1], 0
    jne .found
    mov eax, [rbx]
    clc
    jmp .out
.no:
    stc
.out:
    pop rbx
    ret

; hex_digit(RSI = at) -> EAX = its value; CF if it is not one
hex_digit:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    jbe .yes
    movzx eax, byte [rsi]
    or eax, 0x20
    sub eax, 'a'
    cmp eax, 5
    ja .no
    add eax, 10
.yes:
    clc
    ret
.no:
    stc
    ret

section .rodata
align 8
%macro HANDLER 2                        ; T_*, its handler
    db %1
    times 7 db 0
    dq %2
%endmacro
tag_handlers:
    HANDLER T_p, h_para
    HANDLER T_div, h_div
    HANDLER T_h1, h_heading
    HANDLER T_h2, h_heading
    HANDLER T_h3, h_heading
    HANDLER T_h4, h_heading
    HANDLER T_h5, h_heading
    HANDLER T_h6, h_heading
    HANDLER T_ul, h_list
    HANDLER T_ol, h_list
    HANDLER T_menu, h_list
    HANDLER T_li, h_li
    HANDLER T_dl, h_dl
    HANDLER T_dd, h_dd
    HANDLER T_pre, h_pre
    HANDLER T_listing, h_pre
    HANDLER T_xmp, h_pre
    HANDLER T_plaintext, h_pre
    HANDLER T_blockquote, h_quote
    HANDLER T_figure, h_quote
    HANDLER T_center, h_center
    HANDLER T_caption, h_center
    HANDLER T_address, h_address
    HANDLER T_hr, h_hr
    HANDLER T_br, h_br
    HANDLER T_img, h_img
    HANDLER T_a, h_link
    HANDLER T_b, h_bold
    HANDLER T_strong, h_bold
    HANDLER T_i, h_italic
    HANDLER T_em, h_italic
    HANDLER T_cite, h_italic
    HANDLER T_var, h_italic
    HANDLER T_dfn, h_italic
    HANDLER T_code, h_mono
    HANDLER T_tt, h_mono
    HANDLER T_kbd, h_mono
    HANDLER T_samp, h_mono
    HANDLER T_u, h_under
    HANDLER T_ins, h_under
    HANDLER T_s, h_strike
    HANDLER T_strike, h_strike
    HANDLER T_del, h_strike
    HANDLER T_small, h_small
    HANDLER T_sub, h_small
    HANDLER T_sup, h_small
    HANDLER T_big, h_big
    HANDLER T_font, h_font
    HANDLER T_textarea, h_textarea
    HANDLER T_table, h_table
    HANDLER T_thead, h_none
    HANDLER T_tbody, h_none
    HANDLER T_tfoot, h_none
    HANDLER T_tr, h_row
    HANDLER T_td, h_cell
    HANDLER T_th, h_cell
    db 0xFF
    align 8

heading_px:     db WF_PX36, WF_PX28, WF_PX24, WF_PX20, WF_PX16, WF_PX13
heading_margins: db 24, 22, 20, 26, 26, 30
font_px:        db WF_PX20, WF_PX13, WF_PX16, WF_PX20, WF_PX24, WF_PX28, WF_PX36, WF_PX36
s_bullet1:      db 0xE2, 0x80, 0xA2     ; U+2022, U+25CB, U+25A0
s_bullet2:      db 0xE2, 0x97, 0x8B
s_bullet3:      db 0xE2, 0x96, 0xA0
align 8
bullets:        dq s_bullet1, s_bullet1, s_bullet2, s_bullet3
s_dot:          db '.', 0
s_image:        db 'image', 0
s_brackets:     db '[]'
a_hidden:       db 'hidden', 0
a_style:        db 'style', 0
a_id:           db 'id', 0
a_name:         db 'name', 0
a_href:         db 'href', 0
a_align:        db 'align', 0
a_alt:          db 'alt', 0
a_start:        db 'start', 0
a_color:        db 'color', 0
a_size:         db 'size', 0
a_colspan:      db 'colspan', 0
s_display_none: db 'display:none', 0
s_display_none2: db 'display: none', 0
s_center:       db 'center', 0
s_middle:       db 'middle', 0
s_right:        db 'right', 0
s_left:         db 'left', 0
%macro COLOUR 2
    db %1, 0
    dd %2
%endmacro
colour_names:
    COLOUR 'black', 0x000000
    COLOUR 'white', 0xFFFFFF
    COLOUR 'red', 0xFF0000
    COLOUR 'green', 0x008000
    COLOUR 'blue', 0x0000FF
    COLOUR 'gray', 0x808080
    COLOUR 'grey', 0x808080
    COLOUR 'silver', 0xC0C0C0
    COLOUR 'maroon', 0x800000
    COLOUR 'purple', 0x800080
    COLOUR 'fuchsia', 0xFF00FF
    COLOUR 'lime', 0x00FF00
    COLOUR 'olive', 0x808000
    COLOUR 'yellow', 0xFFFF00
    COLOUR 'navy', 0x000080
    COLOUR 'teal', 0x008080
    COLOUR 'aqua', 0x00FFFF
    COLOUR 'orange', 0xFFA500
    COLOUR 'brown', 0xA52A2A
    db 0

section .bss
alignb 8
dl_base:        resq 1
dl_top:         resq 1
dl_end:         resq 1
line_first:     resq 1
last_node:      resq 1
cur_node:       resq 1
st:             resq 1
marker_text:    resq 1
lk_count:       resd 1
an_count:       resd 1
doc_height:     resd 1
lay_width:      resd 1
lay_y:          resd 1
lay_margin:     resd 1
line_x64:       resd 1
marker_len:     resd 1
marker_x:       resd 1
marker_w64:     resd 1
marker_colour:  resd 1
marker_font:    resb 1
marker_on:      resb 1
line_space:     resb 1
pre_start:      resb 1
alignb 8
col_want:       resd COLS_MAX
lk_table:       resb LK_MAX * LK_SIZE
an_table:       resb AN_MAX * AN_SIZE
styles:         resb STYLES_MAX * STE_SIZE

section .text
