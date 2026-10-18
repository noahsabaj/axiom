; =============================================================================
;  files/icons.inc - what a thing is (its kind, by what its name ends in)
;  and the icons that show it: folders and pages as Finder draws them, a
;  badge on a page in the colour of what it holds, a tile for a program;
;  and the small glyphs of the window (drives, a lock, chevrons, a lens)
;
;  Each icon is drawn in a square of S pixels at x, y.
; =============================================================================

KD_EXT          equ 0                   ; a kind: 8 bytes, what a name ends in, upper case
KD_NAME         equ 8                   ; qword: what it is called
KD_FLAGS        equ 16                  ; dword KK_*
KD_COLOUR       equ 20                  ; dword: its badge's, 0 for none
KD_SIZE         equ 24
KK_TEXT         equ 1                   ; text: Notes opens it
KK_PROG         equ 2                   ; a program: a tile
KK_LINES        equ 4                   ; lines of text on its page
KIND_FOLDER     equ 0
KIND_DOC        equ 1

%macro KIND 4                           ; 'EXT', its name, KK_*, badge colour
%if %strlen(%1) > 0
    db %1
%endif
    times 8 - %strlen(%1) db 0
    dq %2
    dd %3, %4
%endmacro

; FR reg, hundredths: reg = icon_s * them / 100 (EAX and ECX lost)
%macro FR 2
    mov eax, [icon_s]
    mov ecx, %2
    call frac
    mov %1, eax
%endmacro

section .text

; kind_of(RSI = a record) -> EAX = its kind. Preserves others.
kind_of:
    push rcx
    push rsi
    push rdi
    test dword [rsi + FE_ATTR], FEA_DIR
    jz .file
    xor eax, eax
    jmp .out
.file:
    add rsi, FE_NAME
    call ext_of
    jc .doc
    mov qword [k_ext], 0
    xor ecx, ecx
.upper:
    mov al, [rsi + rcx]
    test al, al
    jz .look
    cmp ecx, 7
    jae .doc
    cmp al, 'a'
    jb .put
    cmp al, 'z'
    ja .put
    sub al, 0x20
.put:
    mov [k_ext + rcx], al
    inc ecx
    jmp .upper
.look:
    mov rax, [k_ext]
    lea rdi, [kinds + 2 * KD_SIZE]
    mov ecx, 2
.each:
    cmp ecx, KINDS_N
    jae .doc
    cmp rax, [rdi + KD_EXT]
    je .found
    add rdi, KD_SIZE
    inc ecx
    jmp .each
.found:
    mov eax, ecx
    jmp .out
.doc:
    mov eax, KIND_DOC
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; ext_of(RSI = a name) -> RSI = what follows its last '.'; CF if it has
; none (or the '.' is its first or last byte). Preserves others but RAX.
ext_of:
    push rcx
    xor eax, eax
    xor ecx, ecx
.each:
    cmp byte [rsi + rcx], 0
    je .end
    cmp byte [rsi + rcx], '.'
    jne .next
    lea eax, [rcx + 1]
.next:
    inc ecx
    jmp .each
.end:
    cmp eax, 1                          ; none, or ".name"
    jbe .none
    cmp eax, ecx                        ; "name."
    jae .none
    add rsi, rax
    pop rcx
    clc
    ret
.none:
    pop rcx
    stc
    ret

; kind_rec(EAX = a kind) -> RSI = its record. Preserves others.
kind_rec:
    push rax
    imul eax, eax, KD_SIZE
    lea rsi, [kinds + rax]
    pop rax
    ret

; frac(EAX = S, ECX = hundredths) -> EAX = S * them / 100. Preserves others.
frac:
    push rdx
    push rcx
    imul eax, ecx
    add eax, 50
    xor edx, edx
    mov ecx, 100
    div ecx
    pop rcx
    pop rdx
    ret

; icon_at(RBX = a record, EDI = x, ESI = y, EDX = S): its icon
icon_at:
    mov [icon_x], edi
    mov [icon_y], esi
    mov [icon_s], edx
    mov rsi, rbx
    call kind_of
    test eax, eax
    jz folder_icon
    mov [icon_kind], eax
    call kind_rec
    test dword [rsi + KD_FLAGS], KK_PROG
    jnz prog_icon
    jmp page_icon

; folder_icon: at icon_x, icon_y, icon_s
folder_icon:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, 0x4A9BE6                   ; EBX: its back, R12D: its front
    mov r12d, 0x74BAF4
    call kit_dark
    jne .colours
    mov ebx, 0x3786D6
    mov r12d, 0x5AA9EE
.colours:
    FR r13d, 4                          ; R13D: its left
    add r13d, [icon_x]
    FR r14d, 14                         ; R14D: the top of its tab
    add r14d, [icon_y]
    FR eax, 40                          ; the tab
    mov [g_w], eax
    FR eax, 18
    mov [g_h], eax
    FR r8d, 5
    mov edi, r13d
    mov esi, r14d
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, ebx
    call kit_round
    FR eax, 92                          ; the back
    mov [g_w], eax
    FR eax, 64
    mov [g_h], eax
    FR eax, 6
    add eax, r14d
    mov [g_y], eax
    FR r8d, 6
    mov edi, r13d
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, ebx
    call kit_round
    FR eax, 56                          ; the front
    mov [g_h], eax
    FR eax, 16
    add eax, r14d
    mov [g_y], eax
    FR eax, 6
    mov [g_r], eax
    mov r8d, eax
    mov edi, r13d
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, r12d
    call kit_round
    mov eax, [icon_s]                   ; light along its top edge
    shr eax, 6
    jnz .thick
    mov eax, 1
.thick:
    mov ecx, eax
    mov edi, r13d
    add edi, [g_r]
    mov esi, [g_y]
    mov edx, [g_w]
    sub edx, [g_r]
    sub edx, [g_r]
    mov r8d, KA(0x90) | 0xFFFFFF
    call kit_fill
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; page_icon: a page, its corner folded; lines, or a badge, by icon_kind
page_icon:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    FR r14d, 70                         ; R14D: its width, R15D: its height
    FR r15d, 88
    mov r12d, [icon_s]                  ; R12D: its left, R13D: its top
    sub r12d, r14d
    shr r12d, 1
    add r12d, [icon_x]
    FR r13d, 6
    add r13d, [icon_y]
    mov eax, r14d                       ; EBP: the fold
    mov ecx, 30
    call frac
    mov ebp, eax
    FR eax, 5
    mov [g_r], eax
    mov ebx, 0xFFFFFF                   ; EBX: the page
    call kit_dark
    jne .light
    mov ebx, 0xEDEDF0
.light:
    mov edi, r12d                       ; below the fold, all of it
    lea esi, [r13 + rbp]
    mov edx, r14d
    mov ecx, r15d
    sub ecx, ebp
    mov r8d, [g_r]
    mov r9d, ebx
    call kit_round
    mov edi, r12d                       ; beside it, its top left round
    mov esi, r13d
    mov edx, r14d
    sub edx, ebp
    mov ecx, [g_r]
    lea ecx, [rbp + rcx * 2]
    mov r8d, [g_r]
    mov r9d, ebx
    call kit_round
    xor ebx, ebx                        ; the fold, under the corner cut
.fold:
    cmp ebx, ebp
    jae .folded
    mov edi, r12d
    add edi, r14d
    sub edi, ebp
    lea esi, [r13 + rbx]
    lea edx, [rbx + 1]
    mov ecx, 1
    mov r8d, 0xC9C9CE
    call kit_fill
    inc ebx
    jmp .fold
.folded:
    mov eax, [icon_s]                   ; its edges, faint
    shr eax, 2
    cmp eax, 12
    jae .edge
    mov eax, 12
.edge:
    mov [icon_t], eax
    mov edi, r12d                       ; the cut
    add edi, r14d
    sub edi, ebp
    shl edi, 4
    mov esi, r13d
    shl esi, 4
    mov edx, r12d
    add edx, r14d
    shl edx, 4
    lea ecx, [r13 + rbp]
    shl ecx, 4
    mov r8d, [icon_t]
    mov r9d, KA(0x40) | 0x000000
    call kit_stroke
    mov edi, r12d                       ; the top
    shl edi, 4
    add edi, 32
    mov esi, r13d
    shl esi, 4
    add esi, 8
    mov edx, r12d
    add edx, r14d
    sub edx, ebp
    shl edx, 4
    mov ecx, esi
    mov r8d, [icon_t]
    mov r9d, KA(0x30) | 0x000000
    call kit_stroke
    mov edi, r12d                       ; the right, below the fold
    add edi, r14d
    shl edi, 4
    sub edi, 8
    lea esi, [r13 + rbp]
    shl esi, 4
    mov edx, edi
    lea ecx, [r13 + r15]
    shl ecx, 4
    sub ecx, 48
    mov r8d, [icon_t]
    mov r9d, KA(0x30) | 0x000000
    call kit_stroke
    mov edi, r12d                       ; the left
    shl edi, 4
    add edi, 8
    mov esi, r13d
    shl esi, 4
    add esi, 48
    mov edx, edi
    lea ecx, [r13 + r15]
    shl ecx, 4
    sub ecx, 48
    mov r8d, [icon_t]
    mov r9d, KA(0x30) | 0x000000
    call kit_stroke
    mov edi, r12d                       ; the bottom
    shl edi, 4
    add edi, 48
    lea esi, [r13 + r15]
    shl esi, 4
    sub esi, 8
    mov edx, r12d
    add edx, r14d
    shl edx, 4
    sub edx, 48
    mov ecx, esi
    mov r8d, [icon_t]
    mov r9d, KA(0x30) | 0x000000
    call kit_stroke
    mov eax, [icon_kind]                ; what it holds
    call kind_rec
    test dword [rsi + KD_FLAGS], KK_LINES
    jnz .lines
    cmp dword [rsi + KD_COLOUR], 0
    jne .badge
    jmp .out
.lines:
    xor ebx, ebx                        ; EBX: which line
.line:
    cmp ebx, 5
    jae .out
    mov eax, r15d
    imul eax, ebx
    imul eax, eax, 11
    xor edx, edx
    mov ecx, 100
    div ecx
    mov esi, eax
    mov eax, r15d
    mov ecx, 26
    call frac
    add esi, eax
    add esi, r13d
    mov eax, r14d
    mov ecx, 16
    call frac
    lea edi, [r12 + rax]
    mov eax, r14d
    mov ecx, 64
    cmp ebx, 4
    jne .long
    mov ecx, 38
.long:
    call frac
    mov edx, eax
    mov eax, [icon_s]
    shr eax, 5
    jnz .lh
    mov eax, 1
.lh:
    mov ecx, eax
    mov r8d, KA(0x70) | 0x8E8E93
    call kit_fill
    inc ebx
    jmp .line
.badge:
    mov eax, [icon_s]                   ; small: no room for one
    cmp eax, [badge_min]
    jb .out
    mov ebx, [rsi + KD_COLOUR]
    lea rax, [rsi + KD_EXT]
    mov [icon_ext], rax
    mov eax, r14d                       ; its box, low on the page
    mov ecx, 12
    call frac
    add eax, r12d
    mov [g_x], eax
    mov eax, r14d
    mov ecx, 76
    call frac
    mov [g_w], eax
    mov eax, r15d
    mov ecx, 24
    call frac
    mov [g_h], eax
    mov eax, r15d
    mov ecx, 18
    call frac
    lea esi, [r13 + r15]
    sub esi, eax
    sub esi, [g_h]
    mov [g_y], esi
    FR r8d, 4
    mov edi, [g_x]
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, ebx
    call kit_round
    mov rsi, [icon_ext]                 ; what its name ends in, on it
    call k_slen
    mov edx, [f_badge]
    call kit_text_w
    mov edi, [g_w]
    sub edi, eax
    sar edi, 1
    add edi, [g_x]
    push rdi
    mov edx, [f_badge]
    mov esi, [g_y]
    mov ecx, [g_h]
    call kit_base
    mov edx, eax
    pop rdi
    mov rsi, [icon_ext]
    call k_slen
    mov r8d, [f_badge]
    mov r9d, 0xFFFFFF
    call kit_text
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; prog_icon: a program's tile, ">_" on it
prog_icon:
    push rbx
    push r12
    push r13
    push r14
    FR r14d, 82                         ; R14D: its side
    mov r12d, [icon_s]
    sub r12d, r14d
    shr r12d, 1
    mov r13d, r12d
    add r12d, [icon_x]                  ; R12D, R13D: where
    add r13d, [icon_y]
    mov eax, [icon_kind]
    call kind_rec
    mov ebx, 0x3A3A3E                   ; EBX: its colour
    cmp byte [rsi + KD_EXT], 'A'
    jne .tile
    call kit_accent
    and eax, 0xFFFFFF
    mov ebx, eax
.tile:
    mov eax, r14d
    mov ecx, 22
    call frac
    mov [g_r], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, eax
    mov r9d, ebx
    call kit_round
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r14d
    mov r8d, [g_r]
    mov r9d, KA(0x30) | 0x000000
    mov r10d, 1
    call kit_frame
    mov eax, r14d                       ; ">": two strokes
    mov ecx, 9
    call frac
    shl eax, 4
    cmp eax, 16
    jae .thick
    mov eax, 16
.thick:
    mov [icon_t], eax
    mov eax, r14d
    mov ecx, 26
    call frac
    lea edi, [r12 + rax]
    shl edi, 4                          ; EDI: its left, in 16ths
    mov eax, r14d
    mov ecx, 30
    call frac
    lea esi, [r13 + rax]
    shl esi, 4                          ; ESI: its top
    mov eax, r14d
    mov ecx, 20
    call frac
    shl eax, 4
    mov ebx, eax                        ; EBX: half its height, its depth
    push rdi
    push rsi
    lea edx, [rdi + rbx]
    lea ecx, [rsi + rbx]
    mov r8d, [icon_t]
    mov r9d, 0xFFFFFF
    call kit_stroke
    mov edi, [rsp + 8]
    mov esi, [rsp]
    lea esi, [rsi + rbx * 2]
    lea edx, [rdi + rbx]
    mov ecx, esi
    sub ecx, ebx
    mov r8d, [icon_t]
    mov r9d, 0xFFFFFF
    call kit_stroke
    pop rsi
    pop rdi
    shr ebx, 1                          ; "_"
    lea edi, [rdi + rbx * 2]
    add edi, ebx
    lea esi, [rsi + rbx * 4]
    lea edx, [rdi + rbx * 2]
    mov ecx, esi
    mov r8d, [icon_t]
    mov r9d, 0xFFFFFF
    call kit_stroke
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; drive_icon(EDI = x, ESI = y, EDX = S, ECX = 1 if removable, R9D =
; colour): a drive's outline, a light on it
drive_icon:
    push rbx
    push r12
    push r13
    push r15
    mov r12d, edi
    mov r13d, esi
    mov [icon_s], edx
    mov ebx, ecx
    mov r15d, r9d
    FR eax, 8
    cmp eax, 1
    jae .t
    mov eax, 1
.t:
    mov [g_t], eax
    FR eax, 22
    add eax, r13d
    mov [g_y], eax
    FR eax, 56
    mov [g_h], eax
    FR eax, 16
    mov [g_r], eax
    FR eax, 96
    test ebx, ebx
    jz .w
    FR eax, 72
.w:
    mov [g_w], eax
    mov edi, r12d                       ; its body
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r8d, [g_r]
    mov r9d, r15d
    mov r10d, [g_t]
    call kit_frame
    test ebx, ebx                       ; a stick: its plug
    jz .light
    FR eax, 14
    add eax, [g_y]
    mov esi, eax
    FR eax, 22
    mov edx, eax
    FR eax, 28
    mov ecx, eax
    mov edi, r12d
    add edi, [g_w]
    mov r8d, r15d
    call kit_fill
.light:
    FR eax, 14                          ; the light
    mov [g_d], eax
    FR eax, 16
    mov edi, r12d
    add edi, [g_w]
    sub edi, eax
    sub edi, [g_d]
    mov esi, [g_y]
    add esi, [g_h]
    sub esi, eax
    sub esi, [g_d]
    mov edx, [g_d]
    mov ecx, edx
    mov r8d, edx
    shr r8d, 1
    mov r9d, r15d
    call kit_round
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; lock_icon(EDI = x, ESI = y, EDX = S, R9D = colour)
lock_icon:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13d, esi
    mov [icon_s], edx
    mov r14d, r9d
    FR eax, 11
    cmp eax, 1
    jae .t
    mov eax, 1
.t:
    mov [g_t], eax
    FR eax, 26                          ; its shackle
    add eax, r12d
    mov [g_x], eax
    FR eax, 6
    add eax, r13d
    mov [g_y], eax
    FR eax, 48
    mov [g_w], eax
    FR eax, 62
    mov [g_h], eax
    FR r8d, 24
    mov edi, [g_x]
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, r14d
    mov r10d, [g_t]
    call kit_frame
    FR eax, 14                          ; its body
    add eax, r12d
    mov [g_x], eax
    FR eax, 44
    add eax, r13d
    mov [g_y], eax
    FR eax, 72
    mov [g_w], eax
    FR eax, 52
    mov [g_h], eax
    FR r8d, 12
    mov edi, [g_x]
    mov esi, [g_y]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r9d, r14d
    call kit_round
    pop r14
    pop r13
    pop r12
    ret

; chevron(EDI = x, ESI = y, its middle, EDX = which way: 0 left, 1 right,
; 2 up, 3 down, ECX = half its size, R9D = colour)
chevron:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    shl r12d, 4
    add r12d, 8                         ; R12D, R13D: its middle, in 16ths
    mov r13d, esi
    shl r13d, 4
    add r13d, 8
    mov ebx, edx
    mov r14d, ecx
    shl r14d, 4                         ; R14D: half its size
    mov r15d, r9d
    mov edi, 6                          ; 1.5 points thick
    call kit_pt
    shl eax, 2
    mov [icon_t], eax
    mov eax, r14d
    shr eax, 1                          ; EAX: half its depth
    cmp ebx, 1
    je .right
    cmp ebx, 2
    je .up
    cmp ebx, 3
    je .down
    lea edx, [r12 + rax]                ; <: the ends at the right
    mov edi, r12d
    sub edi, eax                        ; the tip
    jmp .sideways
.right:
    mov edx, r12d                       ; >: the ends at the left
    sub edx, eax
    lea edi, [r12 + rax]
.sideways:
    mov [g_x], edx                      ; g_x: the ends' x; EDI: the tip's
    mov [g_y], edi
    mov esi, r13d                       ; the tip, to the top end
    mov edx, [g_x]
    mov ecx, r13d
    sub ecx, r14d
    mov edi, [g_y]
    mov r8d, [icon_t]
    mov r9d, r15d
    call kit_stroke
    mov edi, [g_y]                      ; and to the bottom one
    mov esi, r13d
    mov edx, [g_x]
    lea ecx, [r13 + r14]
    mov r8d, [icon_t]
    mov r9d, r15d
    call kit_stroke
    jmp .out
.up:
    lea edx, [r13 + rax]                ; ^: the ends below
    mov esi, r13d
    sub esi, eax
    jmp .upright
.down:
    mov edx, r13d                       ; v: the ends above
    sub edx, eax
    lea esi, [r13 + rax]
.upright:
    mov [g_x], edx                      ; g_x: the ends' y; ESI: the tip's
    mov [g_y], esi
    mov edi, r12d
    mov edx, r12d
    sub edx, r14d
    mov ecx, [g_x]
    mov r8d, [icon_t]
    mov r9d, r15d
    call kit_stroke
    mov edi, r12d
    mov esi, [g_y]
    lea edx, [r12 + r14]
    mov ecx, [g_x]
    mov r8d, [icon_t]
    mov r9d, r15d
    call kit_stroke
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; lens(EDI = x, ESI = y, its middle, EDX = S, R9D = colour): a magnifying
; glass
lens:
    push r12
    push r13
    push r15
    mov [icon_s], edx
    mov r15d, r9d
    mov eax, edx
    shr eax, 1
    sub edi, eax
    sub esi, eax
    mov r12d, edi                       ; R12D, R13D: its square's top left
    mov r13d, esi
    FR eax, 12
    cmp eax, 1
    jae .t
    mov eax, 1
.t:
    mov [g_t], eax
    FR eax, 66                          ; the glass
    mov [g_w], eax
    mov edi, r12d
    mov esi, r13d
    mov edx, eax
    mov ecx, eax
    mov r8d, eax
    shr r8d, 1
    mov r9d, r15d
    mov r10d, [g_t]
    call kit_frame
    FR eax, 58                          ; the handle
    mov [g_x], eax
    FR eax, 96
    mov [g_y], eax
    FR eax, 14
    shl eax, 4
    mov r8d, eax
    mov eax, [g_x]
    lea edi, [r12 + rax]
    shl edi, 4
    lea esi, [r13 + rax]
    shl esi, 4
    mov eax, [g_y]
    lea edx, [r12 + rax]
    shl edx, 4
    lea ecx, [r13 + rax]
    shl ecx, 4
    mov r9d, r15d
    call kit_stroke
    pop r15
    pop r13
    pop r12
    ret

; grid_glyph(EDI = x, ESI = y, its middle, EDX = S, R9D = colour): four
; squares, icons
grid_glyph:
    push rbx
    push r12
    push r13
    push r15
    mov [icon_s], edx
    mov r15d, r9d
    mov eax, edx
    shr eax, 1
    sub edi, eax
    sub esi, eax
    mov r12d, edi
    mov r13d, esi
    FR eax, 42                          ; a square's side
    mov [g_w], eax
    FR eax, 10
    mov [g_r], eax
    xor ebx, ebx
.each:
    cmp ebx, 4
    jae .out
    mov edi, r12d
    test ebx, 1
    jz .x
    mov eax, [icon_s]
    sub eax, [g_w]
    add edi, eax
.x:
    mov esi, r13d
    test ebx, 2
    jz .y
    mov eax, [icon_s]
    sub eax, [g_w]
    add esi, eax
.y:
    mov edx, [g_w]
    mov ecx, edx
    mov r8d, [g_r]
    mov r9d, r15d
    call kit_round
    inc ebx
    jmp .each
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

; list_glyph(EDI = x, ESI = y, its middle, EDX = S, R9D = colour): three
; lines with a dot before each
list_glyph:
    push rbx
    push r12
    push r13
    push r15
    mov [icon_s], edx
    mov r15d, r9d
    mov eax, edx
    shr eax, 1
    sub edi, eax
    sub esi, eax
    mov r12d, edi
    mov r13d, esi
    FR eax, 13                          ; a line's height
    cmp eax, 1
    jae .h
    mov eax, 1
.h:
    mov [g_h], eax
    FR eax, 40
    mov [g_d], eax                      ; between them
    FR eax, 12
    mov [g_y], eax                      ; the first's
    FR eax, 30
    mov [g_x], eax                      ; where a line starts
    FR eax, 70
    mov [g_w], eax
    xor ebx, ebx
.each:
    cmp ebx, 3
    jae .out
    mov esi, [g_d]
    imul esi, ebx
    add esi, [g_y]
    add esi, r13d
    push rsi
    mov edi, r12d                       ; the dot
    mov edx, [g_h]
    add edx, edx
    mov ecx, edx
    sub esi, [g_h]
    shr edx, 0
    mov r8d, [g_h]
    mov r9d, r15d
    call kit_round
    pop rsi
    mov edi, r12d                       ; the line
    add edi, [g_x]
    mov edx, [g_w]
    mov ecx, [g_h]
    mov r8d, r15d
    call kit_fill
    inc ebx
    jmp .each
.out:
    pop r15
    pop r13
    pop r12
    pop rbx
    ret

section .rodata
kinds:
    KIND '', s_k_folder, 0, 0
    KIND '', s_k_doc, 0, 0
    KIND 'TXT', s_k_txt, KK_TEXT | KK_LINES, 0
    KIND 'LOG', s_k_log, KK_TEXT | KK_LINES, 0
    KIND 'MD', s_k_md, KK_TEXT, 0x6E6E78
    KIND 'ASM', s_k_asm, KK_TEXT, 0xE07B39
    KIND 'INC', s_k_asm, KK_TEXT, 0xE07B39
    KIND 'S', s_k_asm, KK_TEXT, 0xE07B39
    KIND 'C', s_k_c, KK_TEXT, 0x5A7FC6
    KIND 'H', s_k_h, KK_TEXT, 0x8F65C6
    KIND 'CPP', s_k_cpp, KK_TEXT, 0x3F6FB5
    KIND 'CC', s_k_cpp, KK_TEXT, 0x3F6FB5
    KIND 'HPP', s_k_hpp, KK_TEXT, 0x6A55B8
    KIND 'PY', s_k_py, KK_TEXT, 0x3572A5
    KIND 'SH', s_k_sh, KK_TEXT, 0x3E9A2D
    KIND 'JSON', s_k_json, KK_TEXT, 0xB8901A
    KIND 'TOML', s_k_conf, KK_TEXT, 0x85858C
    KIND 'INI', s_k_conf, KK_TEXT, 0x85858C
    KIND 'CFG', s_k_conf, KK_TEXT, 0x85858C
    KIND 'CONF', s_k_conf, KK_TEXT, 0x85858C
    KIND 'YAML', s_k_yaml, KK_TEXT, 0xC24848
    KIND 'YML', s_k_yaml, KK_TEXT, 0xC24848
    KIND 'HTML', s_k_html, KK_TEXT, 0xE0532A
    KIND 'HTM', s_k_html, KK_TEXT, 0xE0532A
    KIND 'CSS', s_k_css, KK_TEXT, 0x6A4A9C
    KIND 'JS', s_k_js, KK_TEXT, 0xC4A21C
    KIND 'RS', s_k_rs, KK_TEXT, 0xB7552A
    KIND 'GO', s_k_go, KK_TEXT, 0x1D9BC4
    KIND 'CSV', s_k_csv, KK_TEXT, 0x1F7F48
    KIND 'XML', s_k_xml, KK_TEXT, 0x2C6CB0
    KIND 'AXE', s_k_axe, KK_PROG, 0
    KIND 'EFI', s_k_efi, KK_PROG, 0
    KIND 'PNG', s_k_image, 0, 0x2E9E66
    KIND 'JPG', s_k_image, 0, 0x2E9E66
    KIND 'JPEG', s_k_image, 0, 0x2E9E66
    KIND 'BMP', s_k_image, 0, 0x2E9E66
    KIND 'GIF', s_k_image, 0, 0x2E9E66
    KIND 'PDF', s_k_pdf, 0, 0xD43F33
    KIND 'ZIP', s_k_zip, 0, 0x8A78C0
    KIND 'GZ', s_k_zip, 0, 0x8A78C0
    KIND 'TAR', s_k_zip, 0, 0x8A78C0
    KIND 'IMG', s_k_disk, 0, 0x6E6E76
    KIND 'ISO', s_k_disk, 0, 0x6E6E76
    KIND 'BIN', s_k_bin, 0, 0x6E6E76
KINDS_N         equ ($ - kinds) / KD_SIZE

s_k_folder:     db 'Folder', 0
s_k_doc:        db 'Document', 0
s_k_txt:        db 'Plain Text', 0
s_k_log:        db 'Log File', 0
s_k_md:         db 'Markdown', 0
s_k_asm:        db 'Assembly', 0
s_k_c:          db 'C Source', 0
s_k_h:          db 'C Header', 0
s_k_cpp:        db 'C++ Source', 0
s_k_hpp:        db 'C++ Header', 0
s_k_py:         db 'Python', 0
s_k_sh:         db 'Shell Script', 0
s_k_json:       db 'JSON', 0
s_k_conf:       db 'Settings', 0
s_k_yaml:       db 'YAML', 0
s_k_html:       db 'Web Page', 0
s_k_css:        db 'Style Sheet', 0
s_k_js:         db 'JavaScript', 0
s_k_rs:         db 'Rust', 0
s_k_go:         db 'Go', 0
s_k_csv:        db 'Spreadsheet', 0
s_k_xml:        db 'XML', 0
s_k_axe:        db 'Axiom Program', 0
s_k_efi:        db 'UEFI Program', 0
s_k_image:      db 'Image', 0
s_k_pdf:        db 'PDF Document', 0
s_k_zip:        db 'Archive', 0
s_k_disk:       db 'Disk Image', 0
s_k_bin:        db 'Binary', 0

section .bss
alignb 8
k_ext:          resq 1
icon_ext:       resq 1
icon_x:         resd 1
icon_y:         resd 1
icon_s:         resd 1
icon_t:         resd 1
icon_kind:      resd 1
g_x:            resd 1                  ; a glyph's measures
g_y:            resd 1
g_w:            resd 1
g_h:            resd 1
g_r:            resd 1
g_t:            resd 1
g_d:            resd 1
