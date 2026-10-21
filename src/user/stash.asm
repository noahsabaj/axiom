; =============================================================================
;  stash.asm - a program with names in the store: what its capability
;  (ax_store, the names under "stash/") lets it do, and what it does not
;
;    stash                  checks itself: staging, reading back, committing,
;                           a read-only copy of its handle refused writes, a
;                           narrower one ("inner/") seeing only its own names,
;                           bad names refused, a rollback, two transactions on
;                           one name, abort; says "stash: all N checks passed"
;                           and returns 0, or which check failed
;    stash put <name> <text>   the name holds the text, committed
;    stash get <name>          what it holds
;    stash ls                  its names
;  Every name it gives is under its prefix: "greeting" is "stash/greeting"
;  in the store.
; =============================================================================

%include "axe.inc"
WANTS AW_STORE

CHECKS          equ 30
IO_NAME         equ 0                   ; the page: a name's field (64 bytes)
IO_DATA         equ 256                 ; bytes to put, or read
IO_ROOM         equ 2048 - IO_DATA
IO_WHY          equ 2048                ; why, for a commit

main:
    push rbx
    lea rsi, [rdi + SB_ARGS]            ; the start block is read-only: a copy to cut up
    lea rdi, [args]
    mov ecx, [rsi - SB_ARGS + SB_ARGS_LEN]
    rep movsb
    mov byte [rdi], 0
    lea rbx, [args]
    lea rsi, [s_put]
    call word_is
    jz m_put
    lea rsi, [s_get]
    call word_is
    jz m_get
    lea rsi, [s_ls]
    call word_is
    jz m_ls
    cmp byte [rbx], 0
    je m_test
    lea rsi, [s_usage]
    call ax_puts
    mov eax, 99
    pop rbx
    ret

; word_is(RBX = the arguments, RSI = a word) -> ZF if they begin with it;
; RDI = what follows it
word_is:
    mov rdi, rbx
.same:
    mov al, [rsi]
    test al, al
    jz .end
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    jmp .same
.end:
    mov al, [rdi]
    test al, al
    jz .out
    cmp al, ' '
    jne .out
    inc rdi
    xor eax, eax
.out:
    ret

; next_word(RDI = text) -> RDI = the word, NUL-ended there now, RSI = what
; follows it
next_word:
    mov rsi, rdi
.scan:
    mov al, [rsi]
    test al, al
    jz .out
    cmp al, ' '
    je .cut
    inc rsi
    jmp .scan
.cut:
    mov byte [rsi], 0
    inc rsi
.out:
    ret

; -----------------------------------------------------------------------------
;  The store, through the ring
; -----------------------------------------------------------------------------

; name_at(RSI = a NUL-ended name): into the page's name field, zeros after
name_at:
    push rdi
    mov rdi, [ax_io_va]
    push rdi
    xor eax, eax
    mov ecx, 64 / 8
    rep stosq
    pop rdi
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    pop rdi
    ret

; st_entry(EDI = a store, AL = RO_*) -> RSP + 8: the entry, its handles set.
; The caller made room (SQ_SIZE + 8 bytes) and calls st_go after.
%macro ENTRY 1                          ; RO_*: an entry on the stack, for EBX's store
    sub rsp, SQ_SIZE + 8
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], %1
    mov [rsp + SQ_HANDLE], edi
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
%endmacro

%macro GO 0                             ; submitted, waited for: RAX = its result
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
%endmacro

; put(EDI = a store, RSI = a name, RDX = bytes, RCX = how many) -> RAX
put:
    push rcx
    push rdx
    call name_at
    pop rsi
    pop rcx
    push rdi
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    mov rdx, rcx
    rep movsb
    pop rdi
    ENTRY RO_ST_PUT
    mov qword [rsp + SQ_A0], IO_NAME
    mov qword [rsp + SQ_A1], IO_DATA
    mov [rsp + SQ_A2], rdx
    GO
    ret

; put_text(EDI = a store, RSI = a name, RDX = NUL-ended text) -> RAX
put_text:
    xor ecx, ecx
.len:
    cmp byte [rdx + rcx], 0
    je put
    inc ecx
    jmp .len

; get(EDI = a store, RSI = a name) -> RAX = the bytes it holds, there at
; IO_DATA (as many as IO_ROOM)
get:
    call name_at
    ENTRY RO_ST_GET
    mov qword [rsp + SQ_A0], IO_NAME
    mov qword [rsp + SQ_A1], IO_DATA
    mov qword [rsp + SQ_A2], IO_ROOM
    GO
    ret

; get_is(EDI = a store, RSI = a name, RDX = NUL-ended text) -> ZF if the
; name holds exactly that
get_is:
    push rdx
    call get
    pop rsi
    test rax, rax
    js .no
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    xor ecx, ecx
.byte:
    cmp ecx, eax
    je .end
    mov dl, [rsi + rcx]
    test dl, dl
    jz .no
    cmp dl, [rdi + rcx]
    jne .no
    inc ecx
    jmp .byte
.end:
    cmp byte [rsi + rcx], 0
    ret
.no:
    test rsp, rsp                       ; ZF clear
    ret

; del(EDI = a store, RSI = a name) -> RAX
del:
    call name_at
    ENTRY RO_ST_DEL
    mov qword [rsp + SQ_A0], IO_NAME
    GO
    ret

; commit(EDI = a store, RSI = NUL-ended why) -> RAX = the commit's number
commit:
    push rdi
    mov rdi, [ax_io_va]
    add rdi, IO_WHY
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [rdi + rcx], al
    inc ecx
    jmp .copy
.copied:
    pop rdi
    mov edx, ecx
    ENTRY RO_ST_COMMIT
    mov qword [rsp + SQ_A0], IO_WHY
    mov [rsp + SQ_A1], rdx
    GO
    ret

; abort(EDI = a store) -> RAX = the changes dropped
abort:
    ENTRY RO_ST_ABORT
    GO
    ret

; sub(EDI = a store, RSI = a name, EDX = rights) -> RAX = a handle to the
; names under "name/"
sub:
    push rdx
    call name_at
    pop rdx
    ENTRY RO_ST_SUB
    mov qword [rsp + SQ_A0], IO_NAME
    mov [rsp + SQ_A1], rdx
    GO
    ret

; rollback(EDI = a store, RSI = a commit's number) -> RAX
rollback:
    ENTRY RO_ST_ROLLBACK
    mov [rsp + SQ_A0], rsi
    GO
    ret

; list(EDI = a store) -> RAX = its names, NUL-ended, at IO_DATA
list:
    ENTRY RO_ST_LIST
    mov qword [rsp + SQ_A0], IO_DATA
    mov qword [rsp + SQ_A1], IO_ROOM
    GO
    ret

; dup(EDI = a handle, ESI = rights to keep) -> RAX = a new handle
dup:
    ENTRY RO_DUP
    mov [rsp + SQ_A0], rsi
    GO
    ret

; close(EDI = a handle)
close:
    ENTRY RO_CLOSE
    GO
    ret

; listed(RAX = names at IO_DATA, RSI = a name) -> ZF if it is among them
listed:
    mov rdi, [ax_io_va]
    add rdi, IO_DATA
    mov ecx, eax
.name:
    test ecx, ecx
    jz .no
    push rsi
    push rdi
.same:
    mov al, [rsi]
    cmp al, [rdi]
    jne .differ
    test al, al
    jz .found
    inc rsi
    inc rdi
    jmp .same
.found:
    pop rdi
    pop rsi
    xor eax, eax
    ret
.differ:
    pop rdi
    pop rsi
.past:
    cmp byte [rdi], 0
    lea rdi, [rdi + 1]
    jne .past
    dec ecx
    jmp .name
.no:
    test rsp, rsp
    ret

; -----------------------------------------------------------------------------
;  put, get, ls
; -----------------------------------------------------------------------------

m_put:
    call next_word                      ; RDI = the name, RSI = the text
    push rdi
    mov rdx, rsi
    mov rsi, rdi
    mov edi, [ax_store]
    call put_text
    pop rsi
    test rax, rax
    jnz said
    lea rdi, [ax_why]
    lea rcx, [s_why_put]
.why:
    mov al, [rcx]
    test al, al
    jz .name
    mov [rdi], al
    inc rcx
    inc rdi
    jmp .why
.name:
    lodsb
    mov [rdi], al
    inc rdi
    test al, al
    jnz .name
    mov edi, [ax_store]
    lea rsi, [ax_why]
    call commit
    test rax, rax
    js said
    push rax
    lea rsi, [s_committed]
    call ax_add
    pop rdi
    call ax_addu
    call ax_flush
    xor eax, eax
    pop rbx
    ret

m_get:
    call next_word
    mov rsi, rdi
    mov edi, [ax_store]
    call get
    test rax, rax
    js said
    mov rdx, rax
    cmp rdx, IO_ROOM
    jbe .show
    mov edx, IO_ROOM
.show:
    mov rsi, [ax_io_va]
    add rsi, IO_DATA
    call ax_write
    xor eax, eax
    pop rbx
    ret

m_ls:
    mov edi, [ax_store]
    call list
    test rax, rax
    js said
    push rax
    lea rsi, [s_names]
    call ax_add
    mov rdi, [rsp]
    call ax_addu
    call ax_flush
    pop rcx
    mov rsi, [ax_io_va]
    add rsi, IO_DATA
.name:
    test ecx, ecx
    jz .done
    push rcx
    push rsi
    call ax_puts
    pop rsi
    pop rcx
.past:
    lodsb
    test al, al
    jnz .past
    dec ecx
    jmp .name
.done:
    xor eax, eax
    pop rbx
    ret

; said(RAX = E_*): "stash: refused, <n>"; returns it, negated
said:
    push rax
    lea rsi, [s_refused]
    call ax_add
    mov rdi, [rsp]
    call ax_addd
    call ax_flush
    pop rax
    neg rax
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The checks
; -----------------------------------------------------------------------------

m_test:
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r15d, 1                         ; it has names in the store
    mov r12d, [ax_store]
    test r12d, r12d
    jz fail

    mov r15d, 2                         ; a clean slate: what an earlier run left
    mov edi, r12d
    call list
    test rax, rax
    js fail
    mov ebp, eax
    mov rsi, [ax_io_va]
    add rsi, IO_DATA
    lea rdi, [names]
    mov ecx, IO_ROOM
    rep movsb
    lea r13, [names]
.clean:
    test ebp, ebp
    jz .cleaned
    mov edi, r12d
    mov rsi, r13
    call del
    test rax, rax
    jnz fail
.past:
    cmp byte [r13], 0
    lea r13, [r13 + 1]
    jne .past
    dec ebp
    jmp .clean
.cleaned:
    mov edi, r12d
    lea rsi, [s_why_clean]
    call commit
    test rax, rax
    jns .slate
    cmp rax, E_EMPTY
    jne fail

.slate:
    mov r15d, 3                         ; staged
    mov edi, r12d
    lea rsi, [s_greeting]
    lea rdx, [s_hello]
    call put_text
    test rax, rax
    jnz fail
    mov r15d, 4                         ; read back before it is committed
    mov edi, r12d
    lea rsi, [s_greeting]
    lea rdx, [s_hello]
    call get_is
    jnz fail
    mov r15d, 5                         ; committed
    mov edi, r12d
    lea rsi, [s_why_1]
    call commit
    test rax, rax
    jle fail
    mov rbx, rax                        ; its number
    mov r15d, 6                         ; read back after
    mov edi, r12d
    lea rsi, [s_greeting]
    lea rdx, [s_hello]
    call get_is
    jnz fail
    mov r15d, 7                         ; listed, without the prefix
    mov edi, r12d
    call list
    cmp rax, 1
    jne fail
    lea rsi, [s_greeting]
    call listed
    jnz fail

    mov r15d, 8                         ; a read-only copy of the handle
    mov edi, r12d
    mov esi, RT_ST_READ | RT_INFO
    call dup
    test rax, rax
    jle fail
    mov r13d, eax
    mov r15d, 9                         ; reads
    mov edi, r13d
    lea rsi, [s_greeting]
    lea rdx, [s_hello]
    call get_is
    jnz fail
    mov r15d, 10                        ; and may not write
    mov edi, r13d
    lea rsi, [s_greeting]
    lea rdx, [s_other]
    call put_text
    cmp rax, E_RIGHTS
    jne fail
    mov r15d, 11                        ; nor roll back
    mov edi, r13d
    mov rsi, rbx
    call rollback
    cmp rax, E_RIGHTS
    jne fail
    mov r15d, 12                        ; nor make a narrower one
    mov edi, r13d
    lea rsi, [s_inner]
    mov edx, RT_ALL
    call sub
    cmp rax, E_RIGHTS
    jne fail

    mov r15d, 13                        ; a narrower one: "inner/"
    mov edi, r12d
    lea rsi, [s_inner]
    mov edx, RT_ST_ALL | RT_INFO
    call sub
    test rax, rax
    jle fail
    mov r14d, eax
    mov r15d, 14                        ; sees only its own names
    mov edi, r14d
    lea rsi, [s_greeting]
    call get
    cmp rax, E_NONAME
    jne fail
    mov r15d, 15                        ; writes its own
    mov edi, r14d
    lea rsi, [s_note]
    lea rdx, [s_inside]
    call put_text
    test rax, rax
    jnz fail
    mov r15d, 16                        ; its transaction, not the wider one's
    mov edi, r12d
    lea rsi, [s_why_none]
    call commit
    cmp rax, E_EMPTY
    jne fail
    mov r15d, 17
    mov edi, r14d
    lea rsi, [s_why_2]
    call commit
    test rax, rax
    jle fail
    mov r15d, 18                        ; which the wider one sees, under "inner/"
    mov edi, r12d
    lea rsi, [s_inner_note]
    lea rdx, [s_inside]
    call get_is
    jnz fail
    mov r15d, 19                        ; with the rights it was given, no more:
    mov edi, r14d                       ; RT_DUP was not among them
    lea rsi, [s_inner]
    mov edx, RT_ALL
    call sub
    cmp rax, E_RIGHTS
    jne fail

    mov r15d, 20                        ; bad names
    mov edi, r12d
    lea rsi, [s_spaced]
    lea rdx, [s_hello]
    call put_text
    cmp rax, E_ARG
    jne fail
    mov r15d, 21                        ; a name's field with no end
    mov rdi, [ax_io_va]
    mov al, 'x'
    mov ecx, 64
    rep stosb
    mov edi, r12d
    ENTRY RO_ST_GET
    mov qword [rsp + SQ_A2], 16
    mov qword [rsp + SQ_A1], IO_DATA
    GO
    cmp rax, E_ARG
    jne fail
    mov r15d, 22                        ; more than a name may hold
    mov edi, r12d
    lea rsi, [s_greeting]
    call name_at
    ENTRY RO_ST_PUT
    mov qword [rsp + SQ_A1], IO_DATA
    mov qword [rsp + SQ_A2], (1 << 20) + 1
    GO
    cmp rax, E_ARG
    jne fail

    mov r15d, 23                        ; changed, then back
    mov edi, r12d
    lea rsi, [s_greeting]
    lea rdx, [s_other]
    call put_text
    test rax, rax
    jnz fail
    mov edi, r12d
    lea rsi, [s_why_3]
    call commit
    test rax, rax
    jle fail
    mov r15d, 24
    mov edi, r12d
    mov rsi, rbx
    call rollback
    test rax, rax
    jle fail
    mov r15d, 25                        ; as it was then
    mov edi, r12d
    lea rsi, [s_greeting]
    lea rdx, [s_hello]
    call get_is
    jnz fail
    mov r15d, 26                        ; inner/note, made since, is gone
    mov edi, r12d
    lea rsi, [s_inner_note]
    call get
    cmp rax, E_NONAME
    jne fail

    mov r15d, 27                        ; two transactions, one name
    mov edi, r12d
    lea rsi, [s_c]
    mov edx, RT_ST_ALL
    call sub
    test rax, rax
    jle fail
    mov r13d, eax
    mov edi, r12d
    lea rsi, [s_c]
    mov edx, RT_ST_ALL
    call sub
    test rax, rax
    jle fail
    mov r14d, eax
    mov edi, r13d
    lea rsi, [s_k]
    lea rdx, [s_hello]
    call put_text
    mov edi, r14d
    lea rsi, [s_k]
    lea rdx, [s_other]
    call put_text
    mov edi, r13d
    lea rsi, [s_why_4]
    call commit
    test rax, rax
    jle fail
    mov r15d, 28                        ; the second is refused
    mov edi, r14d
    lea rsi, [s_why_4]
    call commit
    cmp rax, E_CONFLICT
    jne fail
    mov r15d, 29                        ; and drops its change
    mov edi, r14d
    call abort
    cmp rax, 1
    jne fail
    mov r15d, 30                        ; staged, dropped, gone
    mov edi, r12d
    lea rsi, [s_temp]
    lea rdx, [s_hello]
    call put_text
    mov edi, r12d
    call abort
    cmp rax, 1
    jne fail
    mov edi, r12d
    lea rsi, [s_temp]
    call get
    cmp rax, E_NONAME
    jne fail

    lea rsi, [s_passed]
    call ax_add
    mov edi, CHECKS
    call ax_addu
    lea rsi, [s_passed_end]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp done
fail:
    lea rsi, [s_check]
    call ax_add
    mov edi, r15d
    call ax_addu
    lea rsi, [s_failed]
    call ax_add
    call ax_flush
    mov eax, r15d
done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

section .rodata
s_put:          db 'put', 0
s_get:          db 'get', 0
s_ls:           db 'ls', 0
s_usage:        db 'usage: stash [put <name> <text> | get <name> | ls]', 0
s_refused:      db 'stash: refused, ', 0
s_committed:    db 'stash: committed, #', 0
s_names:        db 'stash: names: ', 0
s_why_put:      db 'stash put ', 0
s_why_clean:    db 'stash: a clean slate', 0
s_why_1:        db 'stash: a greeting', 0
s_why_2:        db 'stash: a note, from inner/', 0
s_why_3:        db 'stash: the greeting changed', 0
s_why_4:        db 'stash: k, from the first of two', 0
s_why_none:     db 'stash: nothing', 0
s_greeting:     db 'greeting', 0
s_hello:        db 'hello from ring 3', 0
s_other:        db 'something else', 0
s_inner:        db 'inner', 0
s_note:         db 'note', 0
s_inner_note:   db 'inner/note', 0
s_inside:       db 'written through inner/', 0
s_spaced:       db 'a name', 0
s_c:            db 'c', 0
s_k:            db 'k', 0
s_temp:         db 'temp', 0
s_check:        db 'stash: check ', 0
s_failed:       db ' failed', 0
s_passed:       db 'stash: all ', 0
s_passed_end:   db ' checks passed', 0

section .bss
ax_why:         resb 512
names:          resb IO_ROOM
args:           resb 4096

AXE_END
