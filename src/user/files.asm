; =============================================================================
;  files.asm - Files: the volumes, their folders, and what is in them
;
;    files [folder]
;
;  A window of the desktop's, in its look, laid out as Finder's: the
;  volumes at the left; at the top the way back and forward, the folder's
;  name, icons or a list, and a search of the folder; its things as icons,
;  or in a list with when each was written, its size and its kind, sorted
;  by any of them; the path at the bottom. A folder opens in place. A file
;  opens in Notes, which is given a handle to that folder alone and one to
;  the desktop, and nothing else; space looks at a file without opening it.
;  Things are made, renamed, duplicated, copied, moved and deleted only on
;  a volume the user made writable ('vol <n> rw' in Terminal).
;
;  The keys are Finder's, with ctrl for cmd:
;    the arrows choose; ctrl+O or ctrl+down opens; ctrl+up, or backspace,
;    the folder above; ctrl+[ and ctrl+] (or alt+left and right) back and
;    forward; Enter renames; space looks; Esc lets go
;    ctrl+shift+N a new folder; ctrl+D duplicates; ctrl+C, ctrl+X and
;    ctrl+V copy, cut and paste; delete (or ctrl+backspace) deletes, once
;    asked
;    ctrl+F searches; ctrl+1 icons, ctrl+2 the list; ctrl+R reads it again;
;    ctrl+W closes
;    the first letters of a name choose it
;  The mouse: a click chooses, two open, a right click shows what can be
;  done there; the wheel scrolls; the list's headings sort it.
;
;  Closing the window while a Notes it opened is still open: the window
;  goes, and Files waits for those to close before it ends (they end with
;  it).
; =============================================================================

%include "axe.inc"
WANTS AW_DESK | AW_FILES
%include "kit.inc"

W_PT            equ 900                 ; the window, in points
H_PT            equ 560
BLINK_US        equ 530000              ; a field's caret blinks this long each way
TYPE_US         equ 1000000             ; letters typed within this choose together

N_SIDE          equ 1                   ; what is to be drawn again
N_TOOL          equ 2
N_MAIN          equ 4
N_PATH          equ 8
N_ALL           equ 15

%macro PX 2                             ; PX field, points: in pixels
    mov edi, %2
    call kit_pt
    mov [%1], eax
%endmacro

%macro LOWER 1                          ; an ASCII letter in lower case
    cmp %1, 'A'
    jb %%no
    cmp %1, 'Z'
    ja %%no
    or %1, 0x20
%%no:
%endmacro

%include "files/model.inc"
%include "files/icons.inc"
%include "files/view.inc"
%include "files/input.inc"
%include "files/ops.inc"

section .text

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    cmp dword [ax_files], 0
    je .no_files
    call fs_init
    call ls_init
    jc .no_mem
    lea rsi, [r12 + SB_ARGS]            ; the folder named, if one is
    lea rdi, [arg_buf]
    call arg_word
    cmp byte [arg_buf], 0
    je .home
    lea rsi, [arg_buf]
    lea rdi, [path_buf]
    call path_in
    lea rsi, [path_buf]
    call go_to
    jnc .opened
.home:
    call go_home
.opened:
    mov edi, W_PT
    mov esi, H_PT
    mov edx, WNF_RESIZE
    call kit_open
    jc .no_desk
    mov dword [focused], 1
    call measure
    call title_set
    mov dword [need], N_ALL
.loop:
    call paint
    xor ecx, ecx                        ; a field with the keys: its caret blinks
    cmp dword [kfocus], 0
    je .wait
    mov rcx, [blink_at]
.wait:
    call kit_next
    cmp eax, -1
    je .gone
    test eax, eax
    jz .blink
    cmp eax, WE_KEY
    je .key
    cmp eax, WE_PRESS
    je .press
    cmp eax, WE_WHEEL
    je .wheel
    cmp eax, WE_CLOSE
    je .quit
    cmp eax, WE_RESIZED
    je .relayout
    cmp eax, WE_LOOK
    je .relayout
    cmp eax, WE_FOCUS
    je .focus
    jmp .loop
.blink:
    xor dword [kit_caret], 1
    or dword [need], N_TOOL | N_MAIN
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
.wheel:
    call on_wheel
    jmp .loop
.relayout:
    call measure
    mov dword [need], N_ALL
    jmp .loop
.focus:
    mov eax, [kit_ev + WE_CODE]
    mov [focused], eax
    test eax, eax                       ; back: what changed meanwhile
    jz .unfocused
    cmp dword [kfocus], K_RENAME
    je .unfocused
    cmp dword [over], 0
    jne .unfocused
    call vols_read
    call remember
    call list_dir
    call clamp_scroll
.unfocused:
    mov dword [need], N_ALL
    jmp .loop
.after:
    cmp dword [quitting], 0
    je .loop
.quit:
    call kids_wait
.gone:
    xor eax, eax
    jmp .out
.no_files:
    lea rsi, [s_no_files]
    jmp .say
.no_mem:
    lea rsi, [s_no_mem]
    jmp .say
.no_desk:
    lea rsi, [s_no_desk]
.say:
    call ax_puts
    mov eax, 1
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; caret_reset: a field's caret shown, and its blink from now
caret_reset:
    mov dword [kit_caret], 1
blink_next:
    call ax_now
    push rax
    mov edi, BLINK_US
    call ax_us
    pop rcx
    add rax, rcx
    mov [blink_at], rax
    ret

; kids_wait: the window gone; then each Notes this opened, waited for
kids_wait:
    cmp dword [kids_n], 0
    je .out
    call kit_close
    push rbx
    xor ebx, ebx
.each:
    cmp ebx, [kids_n]
    jae .done
    mov edi, [kids + rbx * 4]
    mov eax, RO_JOIN
    xor esi, esi
    xor edx, edx
    call ring_op
    mov edi, [kids + rbx * 4]
    call k_close
    inc ebx
    jmp .each
.done:
    pop rbx
.out:
    ret

; ring_op(EAX = RO_*, EDI = handle, ESI = handle2, RDX = a0, RCX = a1, R8
; = a2; ring_deadline) -> RAX: one entry on the ring, waited for
ring_op:
    sub rsp, SQ_SIZE + 8
    push rdi
    push rax
    push rcx
    push rdx
    lea rdi, [rsp + 32]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdx
    pop rcx
    pop rax
    pop rdi
    mov [rsp + SQ_OP], al
    mov [rsp + SQ_HANDLE], edi
    mov [rsp + SQ_HANDLE2], esi
    mov [rsp + SQ_A0], rdx
    mov [rsp + SQ_A1], rcx
    mov [rsp + SQ_A2], r8
    mov r8, [ring_deadline]
    mov [rsp + SQ_DEADLINE], r8
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    ret

; fsq(EAX = RO_FS_*, EDI = memory, RSI = a0, RDX = a1, RCX = a2) -> RAX:
; asked of the files given
fsq:
    mov r8, rcx
    mov rcx, rdx
    mov rdx, rsi
    mov esi, edi
    mov edi, [ax_files]
    jmp ring_op

; arg_word(RSI = arguments, RDI = FS_PATH bytes) -> the first word there
; (in quotes, it may hold blanks), NUL-ended; RSI past it
arg_word:
    lea rcx, [rdi + FS_PATH - 1]
.blank:
    cmp byte [rsi], ' '
    jne .start
    inc rsi
    jmp .blank
.start:
    mov dl, ' '                         ; DL: what ends it
    cmp byte [rsi], '"'
    jne .each
    mov dl, '"'
    inc rsi
.each:
    mov al, [rsi]
    test al, al
    jz .done
    inc rsi
    cmp al, dl
    je .done
    cmp rdi, rcx
    jae .each
    stosb
    jmp .each
.done:
    mov byte [rdi], 0
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

; str_cat(RSI = NUL-ended, RDI) -> copied there, RDI at its end (not ended)
str_cat:
    lodsb
    test al, al
    jz .out
    stosb
    jmp str_cat
.out:
    ret

; str_copy(RSI = NUL-ended, RDI): copied, with its NUL. Preserves others but
; RAX.
str_copy:
    push rsi
    push rdi
.each:
    lodsb
    stosb
    test al, al
    jnz .each
    pop rdi
    pop rsi
    ret

; k_slen(RSI = NUL-ended) -> ECX = its bytes. Preserves others.
k_slen:
    push rdi
    push rax
    mov rdi, rsi
    call k_strlen
    mov ecx, eax
    pop rax
    pop rdi
    ret

; same_name(RSI, RDI = NUL-ended) -> ZF if the same, but for case (as FAT
; has them). Preserves others but RAX.
same_name:
    push rsi
    push rdi
    push rcx
.each:
    mov al, [rsi]
    mov cl, [rdi]
    LOWER al
    LOWER cl
    cmp al, cl
    jne .out
    test al, al
    jz .out
    inc rsi
    inc rdi
    jmp .each
.out:
    pop rcx
    pop rdi
    pop rsi
    ret

section .rodata
s_no_desk:      db 'files: no desktop to open a window on (run it there, or with +desk)', 0
s_no_files:     db 'files: it was given no files (run it with +files)', 0
s_no_mem:       db 'files: there was not enough memory', 0

section .bss
alignb 8
blink_at:       resq 1
type_at:        resq 1                  ; when a letter was last typed
need:           resd 1
focused:        resd 1
quitting:       resd 1
kids_n:         resd 1                  ; the Notes opened, their first threads
kids:           resd 32
arg_buf:        resb FS_PATH

AXE_END
