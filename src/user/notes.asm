; =============================================================================
;  notes.asm - Notes: text, and code, in tabs
;
;    notes [file ...]
;
;  Opens each file named in a tab of its own (a new, empty one if none is),
;  in a window of the desktop's, in its look: its colours, its scale, its
;  fonts. A name without "vol<n>:" is on the stick Axiom started from. What
;  a name ends in says what the file holds, and that is coloured as Xcode
;  colours it: assembly, C and the languages written like it, Python,
;  shell and settings, JSON, Markdown.
;
;  The keys are the ones a Mac's text editors have, with ctrl for cmd:
;    ctrl+N a new tab, ctrl+O open, ctrl+S save (shift: save as), ctrl+W
;    close the tab, ctrl+tab and ctrl+PgUp/PgDn the next and the last tab
;    ctrl+Z undo, ctrl+shift+Z or ctrl+Y redo; ctrl+X, C, V; ctrl+A all
;    ctrl+F find, ctrl+H replace, F3 and shift+F3 the next and the last
;    found, ctrl+G go to a line; Esc closes the bar
;    ctrl+D the line again below, alt+up and down move it, ctrl+/ a
;    comment on or off, tab and shift+tab indent what is chosen
;    ctrl+= and ctrl+- the text larger and smaller
;    the arrows, with shift to choose, with ctrl or alt by words; home goes
;    to where the line's text begins, then to its start
;  The mouse: a click puts the caret there, two choose a word, three (or
;  one in the line numbers) the line; dragging chooses; the wheel scrolls.
;
;  A file is read whole (RO_FS_READ) and written whole (RO_FS_WRITE); CR LF
;  is read as LF and written as CR LF again. A volume is written only after
;  'vol <n> rw' in the shell: until then, saving says the volume is
;  read-only.
; =============================================================================

%include "axe.inc"
WANTS AW_DESK | AW_FILES
%include "kit.inc"

W_PT            equ 820                 ; the window, in points
H_PT            equ 560
BLINK_US        equ 530000              ; the caret's blink, each way

N_TABS          equ 1                   ; what is to be drawn again
N_TEXT          equ 2
N_STATUS        equ 4
N_FIND          equ 8
N_TITLE         equ 16
N_CARET         equ 32                  ; the caret's line alone
N_ALL           equ 63

%macro PX 2                             ; PX field, points: in pixels
    mov edi, %2
    call kit_pt
    mov [%1], eax
%endmacro

%include "notes/doc.inc"
%include "notes/lex.inc"
%include "notes/view.inc"
%include "notes/edit.inc"
%include "notes/find.inc"
%include "notes/panel.inc"

section .text

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    call files_init
    lea rsi, [r12 + SB_ARGS]            ; a tab for each file named
.arg:
    lodsb
    cmp al, ' '
    je .arg
    test al, al
    jz .args
    dec rsi
    lea rdi, [arg_path]
    call path_in                        ; RSI past it
    push rsi
    call doc_new
    jc .full
    lea rsi, [arg_path]
    call doc_load
    test rax, rax
    jns .loaded
    cmp rax, E_NOFILE                   ; not there yet: saving makes it
    je .loaded
    lea rsi, [s_cannot]
    call ax_add
    lea rsi, [arg_path]
    call ax_add
    call ax_flush
    call doc_close
.loaded:
    pop rsi
    jmp .arg
.full:
    pop rsi
.args:
    cmp dword [ndocs], 0
    jne .opened
    call doc_new
.opened:
    mov dword [cur], 0
    mov edi, W_PT
    mov esi, H_PT
    mov edx, WNF_RESIZE
    call kit_open
    jc .no_desk
    mov dword [focused], 1
    call measure
    call caret_reset
    mov dword [need], N_ALL
.loop:
    call paint
    mov rcx, [blink_at]
    call kit_next
    cmp eax, -1
    je .gone
    test eax, eax
    jz .blink
    cmp eax, WE_KEY
    je .key
    cmp eax, WE_PRESS
    je .press
    cmp eax, WE_MOVE
    je .move
    cmp eax, WE_RELEASE
    je .release
    cmp eax, WE_WHEEL
    je .wheel
    cmp eax, WE_CLOSE
    je .close
    cmp eax, WE_RESIZED
    je .relayout
    cmp eax, WE_LOOK
    je .relayout
    cmp eax, WE_FOCUS
    je .focus
    jmp .loop
.blink:
    xor dword [caret_on], 1
    or dword [need], N_CARET
    call blink_next
    jmp .loop
.key:
    call caret_reset
    mov eax, [kit_ev + WE_CODE]
    mov edx, [kit_ev + WE_X]
    call on_key
    jmp .after
.press:
    call caret_reset
    call on_press
    jmp .after
.move:
    call on_move
    jmp .after
.release:
    mov dword [dragging], 0
    jmp .loop
.wheel:
    call on_wheel
    jmp .loop
.close:
    call ask_quit
    jmp .after
.relayout:
    call measure
    mov dword [need], N_ALL
    jmp .loop
.focus:
    mov eax, [kit_ev + WE_CODE]
    mov [focused], eax
    call caret_reset
    or dword [need], N_TEXT | N_TABS | N_FIND
    jmp .loop
.after:
    cmp dword [quitting], 2             ; all said and done
    jne .loop
.gone:
    xor eax, eax
    jmp .out
.no_desk:
    lea rsi, [s_no_desk]
    call ax_puts
    mov eax, 1
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; caret_reset: the caret shown, and its blink from now
caret_reset:
    mov dword [caret_on], 1
    or dword [need], N_CARET
blink_next:
    call ax_now
    push rax
    mov edi, BLINK_US
    call ax_us
    pop rcx
    add rax, rcx
    mov [blink_at], rax
    ret

; cur_doc -> RBX = the document shown. Preserves all but RBX.
cur_doc:
    push rax
    mov eax, [cur]
    imul eax, eax, D_SIZE
    lea rbx, [docs + rax]
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Files: where names are
; -----------------------------------------------------------------------------

; files_init: whether the files given reach every volume or one folder, and
; which volume Axiom started from
files_init:
    mov dword [boot_vol], 0
    mov dword [confined], 0
    cmp dword [ax_files], 0
    je .out
    mov rdi, [ax_io_va]                 ; "": a folder's own, if it is one
    mov byte [rdi], 0
    mov eax, RO_FS_LIST
    mov edi, [ax_io]
    xor esi, esi
    mov edx, 512
    xor ecx, ecx
    call fsq
    test rax, rax
    js .every
    mov dword [confined], 1
    ret
.every:
    mov eax, RO_FS_VOLUMES
    mov edi, [ax_io]
    xor esi, esi
    mov edx, 4096
    xor ecx, ecx
    call fsq
    test rax, rax
    jle .out
    mov rsi, [ax_io_va]
    mov ecx, eax
    cmp ecx, 4096 / FV_SIZE
    jbe .each
    mov ecx, 4096 / FV_SIZE
.each:
    test dword [rsi + FV_FLAGS], FVF_BOOT
    jz .next
    mov eax, [rsi + FV_INDEX]
    mov [boot_vol], eax
    jmp .out
.next:
    add rsi, FV_SIZE
    dec ecx
    jnz .each
.out:
    ret

; fsq(EAX = RO_FS_*, EDI = memory, RSI = a0, RDX = a1, RCX = a2) -> RAX:
; asked of the files given
fsq:
    push rbx
    mov rbx, rcx
    sub rsp, SQ_SIZE + 8
    push rdi
    push rax
    push rdx
    mov r8, rsi
    lea rdi, [rsp + 24]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdx
    pop rax
    pop rdi
    mov [rsp + SQ_OP], al
    mov eax, [ax_files]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_HANDLE2], edi
    mov [rsp + SQ_A0], r8
    mov [rsp + SQ_A1], rdx
    mov [rsp + SQ_A2], rbx
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    pop rbx
    ret

; path_in(RSI = a name, to a blank or the end, RDI = FS_PATH bytes) -> the
; path to it, RSI past it: with "vol<boot>:/" before it if it has no volume
; and the files reach every one
path_in:
    push rbx
    mov rbx, rdi
    xor ecx, ecx                        ; does it name its volume?
.scan:
    mov al, [rsi + rcx]
    test al, al
    jz .plain
    cmp al, ' '
    je .plain
    cmp al, ':'
    je .named
    inc ecx
    jmp .scan
.plain:
    cmp dword [confined], 0
    jne .named
    mov rdi, rbx
    mov dword [rdi], 'vol'
    add rdi, 3
    push rsi
    mov eax, [boot_vol]
    call put_dec
    pop rsi
    mov word [rdi], ':/'
    add rdi, 2
    cmp byte [rsi], '/'
    jne .copy
    inc rsi
    jmp .copy
.named:
    mov rdi, rbx
.copy:
    lea rcx, [rbx + FS_PATH - 1]
.byte:
    mov al, [rsi]
    test al, al
    jz .done
    cmp al, ' '
    je .done
    cmp rdi, rcx
    jae .skip
    mov [rdi], al
    inc rdi
.skip:
    inc rsi
    jmp .byte
.done:
    mov byte [rdi], 0
    pop rbx
    ret

; put_dec(EAX, RDI) -> its digits there, RDI past them. Preserves others
; but RAX, RDX.
put_dec:
    push rcx
    push rbx
    mov ebx, 10
    xor ecx, ecx
.div:
    xor edx, edx
    div ebx
    add dl, '0'
    push rdx
    inc ecx
    test eax, eax
    jnz .div
.put:
    pop rax
    stosb
    dec ecx
    jnz .put
    pop rbx
    pop rcx
    ret

section .rodata
s_no_desk:      db 'notes: no desktop to open a window on (run it there, or with +desk)', 0
s_cannot:       db 'notes: cannot open ', 0

section .bss
alignb 8
blink_at:       resq 1
need:           resd 1
focused:        resd 1
caret_on:       resd 1
dragging:       resd 1
quitting:       resd 1                  ; 1: closing tabs to quit; 2: done
confined:       resd 1                  ; 1: the files reach one folder alone
boot_vol:       resd 1
arg_path:       resb FS_PATH

AXE_END
