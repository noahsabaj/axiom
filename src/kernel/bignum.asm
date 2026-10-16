; =============================================================================
;  bignum.asm - Montgomery arithmetic modulo an odd number of up to 4096
;  bits: RSA's modulus, and the prime field and group order of P-256 and
;  P-384. Numbers are arrays of 64-bit limbs, least significant first, as
;  many limbs as the modulus has (MC_L); a context holds the modulus with
;  what Montgomery multiplication needs. Values "in Montgomery form" are
;  x * R mod n, R = 2^(64 * MC_L).
;
;    mont_setup(RDI = ctx, RSI = modulus, big-endian, ECX = bytes) -> CF if
;        it is even, 1, or over 4096 bits
;    mont_mul(RDI = out, RSI = a, RDX = b, RCX = ctx)    a * b / R mod n
;    mont_in(RDI = out, RSI = a, RCX = ctx)              a * R mod n
;    mont_out(RDI = out, RSI = a, RCX = ctx)             a / R mod n
;    mont_add(RDI = out, RSI = a, RDX = b, RCX = ctx)    a + b mod n
;    mont_sub(RDI = out, RSI = a, RDX = b, RCX = ctx)    a - b mod n
;    mont_exp(RDI = out, RSI = a, RDX = exponent, R8 = its limbs, RCX =
;        ctx): a^exponent, both a and the answer in Montgomery form
;    bn_load(RDI = limbs, RSI = big-endian bytes, ECX = bytes, EDX = limbs)
;        -> CF if the number does not fit
;    bn_store(RDI = big-endian bytes, RSI = limbs, ECX = bytes)
;    bn_cmp(RSI = a, RDI = b, ECX = limbs) -> flags as for a - b: CF if a <
;        b, ZF if equal
;    bn_sub(RDI = out, RSI = a, RDX = b, ECX = limbs) -> CF on a borrow
;    bn_is_zero(RSI, ECX = limbs) -> ZF if zero
;
;  Inputs to the mont_* must be below n; out may be any of the inputs. All
;  preserve every register but RAX. Not constant-time: Axiom only verifies
;  signatures, where every number is public. Scratch in .bss: main loop only.
; =============================================================================

BN_LIMBS        equ 64                  ; 4096 bits

MC_L            equ 0                   ; limbs
MC_N0           equ 8                   ; -1/n mod 2^64
MC_BITS         equ 16                  ; bits of n
MC_N            equ 32
MC_RR           equ MC_N + BN_LIMBS * 8 ; R^2 mod n
MC_ONE          equ MC_RR + BN_LIMBS * 8 ; R mod n: 1 in Montgomery form
MONT_CTX        equ MC_ONE + BN_LIMBS * 8

section .text

mont_setup:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    mov rbx, rdi
.strip:                                 ; leading zero bytes off
    test ecx, ecx
    jz .bad
    cmp byte [rsi], 0
    jne .stripped
    inc rsi
    dec ecx
    jmp .strip
.stripped:
    cmp ecx, BN_LIMBS * 8
    ja .bad
    lea edx, [rcx + 7]
    shr edx, 3
    mov [rbx + MC_L], rdx
    lea rdi, [rbx + MC_N]
    call bn_load
    test byte [rbx + MC_N], 1
    jz .bad
    mov r8, rdx                         ; R8 = limbs
    cmp r8, 1
    jne .big
    cmp qword [rbx + MC_N], 1
    je .bad
.big:
    mov rax, [rbx + MC_N + r8 * 8 - 8]
    bsr rax, rax
    mov r9, r8
    shl r9, 6
    lea rax, [rax + r9 - 63]            ; 64 (L - 1) + top bit + 1
    mov [rbx + MC_BITS], rax
    mov r9, [rbx + MC_N]                ; -1/n0 by Newton: 3, 6, ... 96 bits
    mov rax, r9
%rep 5
    mov r10, r9
    imul r10, rax
    neg r10
    add r10, 2
    imul rax, r10
%endrep
    neg rax
    mov [rbx + MC_N0], rax
    lea rdi, [rbx + MC_ONE]             ; R mod n: 2^(bits - 1) doubled up to 2^(64 L)
    push rdi
    mov rcx, r8
    xor eax, eax
    rep stosq
    pop rdi
    mov rax, [rbx + MC_BITS]
    dec rax
    bts [rdi], rax
    mov rcx, r8
    shl rcx, 6
    sub rcx, [rbx + MC_BITS]
    inc rcx
    mov rsi, rdi
    mov rdx, rdi
    call .double
    lea rdi, [rbx + MC_RR]              ; R^2: R * 2^k by doubling, then squared
    lea rsi, [rbx + MC_ONE]             ; s times, where 64 L = k * 2^s
    mov rcx, r8
    rep movsq
    lea rdi, [rbx + MC_RR]
    mov r9, r8
    shl r9, 6
    bsf r10, r9                         ; R10 = s
    mov ecx, r10d
    shr r9, cl
    mov rcx, r9                         ; RCX = k
    mov rsi, rdi
    mov rdx, rdi
    call .double
    mov rcx, rbx
.square:
    test r10, r10
    jz .done
    call mont_mul
    dec r10
    jmp .square
.done:
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
; RDI = RSI = RDX doubled RCX times mod n (RBX = ctx)
.double:
    test rcx, rcx
    jz .doubled
    push rcx
    mov rcx, rbx
    call mont_add
    pop rcx
    dec rcx
    jmp .double
.doubled:
    ret

; mont_mul: CIOS (Koc, Acar and Kaliski), into bn_t, then n off if needed
mont_mul:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r8, rdx                         ; R8 = b
    mov r9, rcx                         ; R9 = ctx
    mov r10, [r9 + MC_L]                ; R10 = L
    lea r11, [r9 + MC_N]                ; R11 = n
    lea rbx, [bn_t]                     ; RBX = t, L + 2 limbs
    lea rcx, [r10 + 2]
    xor eax, eax
.zero:
    mov [rbx + rcx * 8 - 8], rax
    dec rcx
    jnz .zero
    xor r12d, r12d                      ; R12 = i
.outer:
    mov r13, [r8 + r12 * 8]             ; t += a * b[i]
    xor r14d, r14d
    xor r15d, r15d
.mul:
    mov rax, [rsi + r15 * 8]
    mul r13
    add rax, r14
    adc rdx, 0
    add rax, [rbx + r15 * 8]
    adc rdx, 0
    mov [rbx + r15 * 8], rax
    mov r14, rdx
    inc r15
    cmp r15, r10
    jb .mul
    xor eax, eax
    add [rbx + r10 * 8], r14
    adc rax, 0
    mov [rbx + r10 * 8 + 8], rax
    mov r13, [r9 + MC_N0]               ; t = (t + m * n) / 2^64
    imul r13, [rbx]
    mov rax, [r11]
    mul r13
    add rax, [rbx]
    adc rdx, 0
    mov r14, rdx
    mov r15d, 1
.reduce:
    cmp r15, r10
    jae .reduced
    mov rax, [r11 + r15 * 8]
    mul r13
    add rax, r14
    adc rdx, 0
    add rax, [rbx + r15 * 8]
    adc rdx, 0
    mov [rbx + r15 * 8 - 8], rax
    mov r14, rdx
    inc r15
    jmp .reduce
.reduced:
    mov rax, [rbx + r10 * 8]
    add rax, r14
    mov [rbx + r10 * 8 - 8], rax
    mov rax, [rbx + r10 * 8 + 8]
    adc rax, 0
    mov [rbx + r10 * 8], rax
    inc r12
    cmp r12, r10
    jb .outer
    mov rcx, r10                        ; out = t - n, unless that borrows
    xor r15d, r15d
.sub:
    mov rax, [rbx + r15 * 8]
    sbb rax, [r11 + r15 * 8]
    mov [rdi + r15 * 8], rax
    inc r15
    dec rcx
    jnz .sub
    mov rax, [rbx + r10 * 8]
    sbb rax, 0
    jnc .out
    mov rcx, r10
    mov rsi, rbx
    rep movsq
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

mont_in:
    push rdx
    lea rdx, [rcx + MC_RR]
    call mont_mul
    pop rdx
    ret

mont_out:
    push rdx
    lea rdx, [bn_one]
    call mont_mul
    pop rdx
    ret

mont_add:
    push rbx
    push rcx
    push rbp
    push r8
    push r9
    push r10
    push r11
    mov r8, [rcx + MC_L]
    lea r9, [rcx + MC_N]
    lea rbp, [bn_s]
    mov r11, r8
    xor r10d, r10d                      ; (and CF clear)
.add:
    mov rax, [rsi + r10 * 8]
    adc rax, [rdx + r10 * 8]
    mov [rdi + r10 * 8], rax
    inc r10
    dec r11
    jnz .add
    setc bl
    mov r11, r8
    xor r10d, r10d
.sub:
    mov rax, [rdi + r10 * 8]
    sbb rax, [r9 + r10 * 8]
    mov [rbp + r10 * 8], rax
    inc r10
    dec r11
    jnz .sub
    setc bh
    test bl, bl                         ; a carry: over 2^64L, so over n
    jnz .take
    test bh, bh                         ; no borrow: at least n
    jnz .out
.take:
    xor r10d, r10d
.copy:
    mov rax, [rbp + r10 * 8]
    mov [rdi + r10 * 8], rax
    inc r10
    cmp r10, r8
    jb .copy
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rcx
    pop rbx
    ret

mont_sub:
    push rcx
    push r8
    push r9
    push r10
    push r11
    mov r8, [rcx + MC_L]
    lea r9, [rcx + MC_N]
    mov r11, r8
    xor r10d, r10d
.sub:
    mov rax, [rsi + r10 * 8]
    sbb rax, [rdx + r10 * 8]
    mov [rdi + r10 * 8], rax
    inc r10
    dec r11
    jnz .sub
    jnc .out                            ; a borrow: n back on
    mov r11, r8
    xor r10d, r10d
.add:
    mov rax, [r9 + r10 * 8]
    adc [rdi + r10 * 8], rax
    inc r10
    dec r11
    jnz .add
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rcx
    ret

; mont_exp: left to right, square and multiply, into bn_acc
mont_exp:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r9
    push r10
    push r11
    push r12
    mov r12, rdi                        ; R12 = out
    mov rbx, rsi                        ; RBX = a
    mov r9, rdx                         ; R9 = exponent
    xor ebp, ebp                        ; EBP = started
    lea rdi, [bn_acc]
    mov rdx, r8                         ; RDX = limb index + 1
.limb:
    test rdx, rdx
    jz .end
    mov r10, [r9 + rdx * 8 - 8]
    mov r11d, 64
.bit:
    test ebp, ebp
    jz .first
    push rdx
    mov rsi, rdi
    mov rdx, rdi
    call mont_mul
    pop rdx
.first:
    shl r10, 1
    jnc .next
    test ebp, ebp
    jz .start
    push rdx
    mov rsi, rdi
    mov rdx, rbx
    call mont_mul
    pop rdx
    jmp .next
.start:
    mov ebp, 1
    push rcx
    push rdi
    mov rsi, rbx
    mov rcx, [rcx + MC_L]
    rep movsq
    pop rdi
    pop rcx
.next:
    dec r11d
    jnz .bit
    dec rdx
    jmp .limb
.end:
    lea rsi, [bn_acc]
    test ebp, ebp
    jnz .copy
    lea rsi, [rcx + MC_ONE]             ; a^0 = 1
.copy:
    mov rdi, r12
    mov rcx, [rcx + MC_L]
    rep movsq
    pop r12
    pop r11
    pop r10
    pop r9
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

bn_load:
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push rcx
    push rdi
    mov ecx, edx
    xor eax, eax
    rep stosq
    pop rdi
    pop rcx
    mov ecx, ecx
    shl edx, 3                          ; EDX = room, in bytes
    xor r8d, r8d                        ; R8 = byte i of the number
.byte:
    cmp r8, rcx
    jae .ok
    mov r9, rcx
    sub r9, r8
    movzx eax, byte [rsi + r9 - 1]
    cmp r8d, edx
    jae .over
    mov [rdi + r8], al
    inc r8
    jmp .byte
.over:
    test al, al
    jnz .bad
    inc r8
    jmp .byte
.ok:
    clc
    jmp .out
.bad:
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    ret

bn_store:
    push rcx
    push r8
    mov ecx, ecx
    xor r8d, r8d
.byte:
    cmp r8, rcx
    jae .out
    mov al, [rsi + r8]
    push rcx
    sub rcx, r8
    mov [rdi + rcx - 1], al
    pop rcx
    inc r8
    jmp .byte
.out:
    pop r8
    pop rcx
    ret

bn_cmp:
    push rdx
    mov edx, ecx
.limb:
    test edx, edx                       ; all equal: ZF, no CF
    jz .out
    dec edx
    mov rax, [rsi + rdx * 8]
    cmp rax, [rdi + rdx * 8]
    je .limb
.out:
    pop rdx
    ret

bn_sub:
    push rcx
    push r8
    mov ecx, ecx
    xor r8d, r8d
    test ecx, ecx
    jz .out
.limb:
    mov rax, [rsi + r8 * 8]
    sbb rax, [rdx + r8 * 8]
    mov [rdi + r8 * 8], rax
    inc r8
    dec rcx
    jnz .limb
.out:
    pop r8
    pop rcx
    ret

bn_is_zero:
    push rcx
    xor eax, eax
    mov ecx, ecx
    test ecx, ecx
    jz .out
.limb:
    or rax, [rsi + rcx * 8 - 8]
    dec rcx
    jnz .limb
.out:
    test rax, rax
    pop rcx
    ret

section .rodata
align 8
bn_one:         dq 1
                times BN_LIMBS - 1 dq 0

section .bss
alignb 8
bn_t:           resq BN_LIMBS + 2
bn_s:           resq BN_LIMBS
bn_acc:         resq BN_LIMBS
