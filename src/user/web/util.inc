; =============================================================================
;  web/util.inc - the browser's memory and strings
;
;    mem_new(RDI = bytes) -> RAX = where they are mapped, zeroed, or E_*
;    ar_init(RDI = bytes): the page's arena; ar_reset: all of it free again
;    ar_alloc(RDI = bytes) -> RAX = zeroed, 8-aligned, or 0 when it is full
;    ar_raw(RDI = bytes) -> RAX = likewise, not zeroed
;    ci_eq(RSI = bytes, ECX = how many, RDI = a lower-case NUL-ended word)
;      -> ZF if they are that word, whatever their case
;    ci_starts(RSI = NUL-ended, RDI = a lower-case NUL-ended word) -> ZF if
;      it begins with the word, RAX = the word's length
;    ci_find(RSI = bytes, RCX = how many, RDI = lower-case NUL-ended) ->
;      RAX = where the word is in them, or 0
;    to_lower(AL) -> AL
;    dec_parse(RSI = bytes, ECX = how many) -> RAX = the decimal number they
;      begin with (spaces first skipped), RSI past it; CF if none
;    str_copy(RDI = to, RSI = NUL-ended, ECX = room) -> RDI at its NUL
;    put_str(RSI = NUL-ended): onto out_ptr; put_n(RSI, ECX); put_u(RDI)
;  All preserve RBX, RBP, R12-R15; ar_* and to_lower preserve all but RAX.
; =============================================================================

section .text

mem_new:
    push rdi
    mov eax, SYS_MEM_NEW
    syscall
    pop rdi
    test rax, rax
    js .out
    mov edi, eax
    mov eax, SYS_MAP
    syscall
.out:
    ret

ar_init:
    push rdi
    call mem_new
    pop rdi
    test rax, rax
    js .out
    mov [ar_base], rax
    mov [ar_top], rax
    add rax, rdi
    mov [ar_end], rax
.out:
    ret

ar_reset:
    push rax
    mov rax, [ar_base]
    mov [ar_top], rax
    pop rax
    ret

ar_raw:
    push rcx
    mov rax, [ar_top]
    lea rcx, [rax + rdi + 7]
    and rcx, -8
    cmp rcx, [ar_end]
    ja .full
    mov [ar_top], rcx
    pop rcx
    ret
.full:
    xor eax, eax
    pop rcx
    ret

ar_alloc:
    call ar_raw
    test rax, rax
    jz .out
    push rdi
    push rcx
    push rax
    mov rcx, rdi
    mov rdi, rax
    xor eax, eax
    rep stosb
    pop rax
    pop rcx
    pop rdi
.out:
    ret

to_lower:
    cmp al, 'A'
    jb .out
    cmp al, 'Z'
    ja .out
    add al, 32
.out:
    ret

ci_eq:
    push rcx
    push rsi
    push rdi
.char:
    test ecx, ecx
    jz .end
    mov al, [rsi]
    call to_lower
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.end:
    cmp byte [rdi], 0
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

ci_starts:
    push rsi
    push rdi
    push rdx
    mov rdx, rdi
.char:
    cmp byte [rdi], 0
    je .yes
    mov al, [rsi]
    call to_lower
    cmp al, [rdi]
    jne .out
    inc rsi
    inc rdi
    jmp .char
.yes:
    mov rax, rdi
    sub rax, rdx
    cmp eax, eax
.out:
    pop rdx
    pop rdi
    pop rsi
    ret

ci_find:
    push rbx
    push r12
    mov rbx, rsi
    lea r12, [rsi + rcx]
.at:
    xor eax, eax
    cmp rbx, r12
    jae .out
    mov rsi, rbx
    xor ecx, ecx
.char:
    mov al, [rdi + rcx]
    test al, al
    jz .found
    lea rax, [rsi + rcx]
    cmp rax, r12
    jae .none
    mov al, [rsi + rcx]
    call to_lower
    cmp al, [rdi + rcx]
    jne .next
    inc ecx
    jmp .char
.next:
    inc rbx
    jmp .at
.found:
    mov rax, rbx
    jmp .out
.none:
    xor eax, eax
.out:
    pop r12
    pop rbx
    ret

dec_parse:
    push rdx
.space:
    test ecx, ecx
    jz .none
    cmp byte [rsi], ' '
    je .skip
    cmp byte [rsi], 9
    jne .digits
.skip:
    inc rsi
    dec ecx
    jmp .space
.digits:
    movzx eax, byte [rsi]
    sub eax, '0'
    cmp eax, 9
    ja .none
    xor eax, eax
.digit:
    test ecx, ecx
    jz .done
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .done
    imul rax, rax, 10
    add rax, rdx
    inc rsi
    dec ecx
    jmp .digit
.done:
    pop rdx
    clc
    ret
.none:
    pop rdx
    stc
    ret

str_copy:
    test ecx, ecx
    jz .end
.char:
    dec ecx
    jz .end
    mov al, [rsi]
    test al, al
    jz .end
    mov [rdi], al
    inc rsi
    inc rdi
    jmp .char
.end:
    mov byte [rdi], 0
    ret

; out_ptr .. out_end: where put_* write; each keeps a NUL after what it put
put_n:
    push rdi
    mov rdi, [out_ptr]
.char:
    test ecx, ecx
    jz .end
    cmp rdi, [out_end]
    jae .end
    mov al, [rsi]
    mov [rdi], al
    inc rsi
    inc rdi
    dec ecx
    jmp .char
.end:
    mov byte [rdi], 0
    mov [out_ptr], rdi
    pop rdi
    ret

put_str:
    push rcx
    mov rcx, rsi
.len:
    cmp byte [rcx], 0
    je .counted
    inc rcx
    jmp .len
.counted:
    sub rcx, rsi
    call put_n
    pop rcx
    ret

put_u:
    push rsi
    sub rsp, 24
    lea rsi, [rsp + 23]
    mov rax, rdi
    mov ecx, 10
.digit:
    xor edx, edx
    div rcx
    add dl, '0'
    dec rsi
    mov [rsi], dl
    test rax, rax
    jnz .digit
    lea rcx, [rsp + 23]
    sub rcx, rsi
    call put_n
    add rsp, 24
    pop rsi
    ret

section .bss
alignb 8
ar_base:        resq 1
ar_top:         resq 1
ar_end:         resq 1
out_ptr:        resq 1
out_end:        resq 1

section .text
