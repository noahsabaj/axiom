; =============================================================================
;  x25519.asm - X25519 Diffie-Hellman (RFC 7748): TLS 1.3's key exchange.
;  Field elements mod p = 2^255 - 19 are four 64-bit limbs, little-endian,
;  kept below 2^256 and only fully reduced at the end; products fold their
;  upper half back in times 38 (2^256 = 38 mod p). The Montgomery ladder runs
;  all 255 steps with masked swaps, and nothing branches or indexes memory on
;  the secret scalar.
;
;    x25519(RDI = out[32], RSI = scalar[32], RDX = u[32])
;    x25519_base(RDI = out[32], RSI = scalar[32])     u = 9: a public key
;
;  Both preserve all general registers but RAX. Scratch, the scalar
;  included, lives in .bss (cleared afterwards): main loop only.
; =============================================================================

A24             equ 121665              ; (486662 - 2) / 4

section .text

x25519_base:
    push rdx
    lea rdx, [x_nine]
    call x25519
    pop rdx
    ret

; FE op, r, a[, b]: the field operations on the scratch elements
%macro FE 3-4
    lea rdi, [%2]
    lea rsi, [%3]
    %if %0 == 4
        lea rdx, [%4]
    %endif
    call %1
%endmacro

x25519:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push rdi                            ; the output, for the end
    lea rdi, [xk]                       ; the scalar, clamped
    mov ecx, 32
    rep movsb
    and byte [xk], 248
    and byte [xk + 31], 127
    or byte [xk + 31], 64
    mov rsi, rdx                        ; u, its top bit ignored
    lea rdi, [fx1]
    mov ecx, 32
    rep movsb
    and byte [fx1 + 31], 127
    lea rsi, [fx1]
    lea rdi, [fx3]
    mov ecx, 32
    rep movsb
    xor eax, eax
    lea rdi, [fz2]
    mov ecx, 32
    rep stosb
    lea rdi, [fx2]
    mov ecx, 32
    rep stosb
    lea rdi, [fz3]
    mov ecx, 32
    rep stosb
    mov byte [fx2], 1
    mov byte [fz3], 1
    xor r12d, r12d                      ; the pending swap
    mov ebx, 254
.step:
    mov ecx, ebx                        ; k_t
    shr ecx, 3
    lea rsi, [xk]
    movzx eax, byte [rsi + rcx]
    mov ecx, ebx
    and ecx, 7
    shr eax, cl
    and eax, 1
    xor r12d, eax
    xchg r12d, eax                      ; swap ^ k_t now, k_t for next time
    call x_swaps
    FE fe_add, fA, fx2, fz2
    FE fe_mul, fAA, fA, fA
    FE fe_sub, fB, fx2, fz2
    FE fe_mul, fBB, fB, fB
    FE fe_sub, fE, fAA, fBB
    FE fe_add, fC, fx3, fz3
    FE fe_sub, fD, fx3, fz3
    FE fe_mul, fDA, fD, fA
    FE fe_mul, fCB, fC, fB
    FE fe_add, fx3, fDA, fCB
    FE fe_mul, fx3, fx3, fx3
    FE fe_sub, fz3, fDA, fCB
    FE fe_mul, fz3, fz3, fz3
    FE fe_mul, fz3, fx1, fz3
    FE fe_mul, fx2, fAA, fBB
    FE fe_a24, fz2, fE
    FE fe_add, fz2, fAA, fz2
    FE fe_mul, fz2, fE, fz2
    dec ebx
    jns .step
    mov eax, r12d
    call x_swaps
    FE fe_inv, fz2, fz2
    FE fe_mul, fx2, fx2, fz2
    lea rdi, [fx2]
    call fe_freeze
    pop rdi
    lea rsi, [fx2]
    mov ecx, 32
    rep movsb
    lea rdi, [xk]                       ; no secrets left behind
    xor eax, eax
    mov ecx, x_scratch_end - xk
    rep stosb
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; x_swaps(EAX = 1 to swap): (x2, z2) with (x3, z3), without branching
x_swaps:
    lea rdi, [fx2]
    lea rsi, [fx3]
    call fe_cswap
    lea rdi, [fz2]
    lea rsi, [fz3]
    jmp fe_cswap

; -----------------------------------------------------------------------------
;  The field. Each takes RDI = result, RSI = a, RDX = b; results may alias
;  the inputs. Preserve all but RAX.
; -----------------------------------------------------------------------------

; T0..T7 of a product in R8..R15; RBP carries
%macro MUL_STEP 2                       ; product limb, j
    mov rax, [rbx + %2 * 8]
    mul rcx
    add rax, rbp
    adc rdx, 0
    add %1, rax
    adc rdx, 0
    mov rbp, rdx
%endmacro

%macro MUL_ROW 6                        ; i, then t[i] .. t[i+4]
    mov rcx, [rsi + %1 * 8]
    xor ebp, ebp
    MUL_STEP %2, 0
    MUL_STEP %3, 1
    MUL_STEP %4, 2
    MUL_STEP %5, 3
    mov %6, rbp
%endmacro

%macro FOLD_STEP 2                      ; low limb, high limb: low += 38 * high
    mov rax, %2
    mul rcx
    add rax, rbp
    adc rdx, 0
    add %1, rax
    adc rdx, 0
    mov rbp, rdx
%endmacro

fe_mul:
    push rbx
    push rcx
    push rdx
    push rbp
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdx
    xor r8d, r8d
    xor r9d, r9d
    xor r10d, r10d
    xor r11d, r11d
    MUL_ROW 0, r8, r9, r10, r11, r12
    MUL_ROW 1, r9, r10, r11, r12, r13
    MUL_ROW 2, r10, r11, r12, r13, r14
    MUL_ROW 3, r11, r12, r13, r14, r15
    mov ecx, 38
    xor ebp, ebp
    FOLD_STEP r8, r12
    FOLD_STEP r9, r13
    FOLD_STEP r10, r14
    FOLD_STEP r11, r15
    imul rax, rbp, 38                   ; what carried past 2^256
    add r8, rax
    adc r9, 0
    adc r10, 0
    adc r11, 0
    sbb rax, rax                        ; and once more, which cannot carry
    and eax, 38
    add r8, rax
    mov [rdi], r8
    mov [rdi + 8], r9
    mov [rdi + 16], r10
    mov [rdi + 24], r11
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdx
    pop rcx
    pop rbx
    ret

fe_add:
    push r8
    push r9
    push r10
    push r11
    mov r8, [rsi]
    add r8, [rdx]
    mov r9, [rsi + 8]
    adc r9, [rdx + 8]
    mov r10, [rsi + 16]
    adc r10, [rdx + 16]
    mov r11, [rsi + 24]
    adc r11, [rdx + 24]
    sbb rax, rax                        ; past 2^256: add 38 instead
    and eax, 38
    add r8, rax
    adc r9, 0
    adc r10, 0
    adc r11, 0
    sbb rax, rax
    and eax, 38
    add r8, rax
    jmp fe_store

fe_sub:
    push r8
    push r9
    push r10
    push r11
    mov r8, [rsi]
    sub r8, [rdx]
    mov r9, [rsi + 8]
    sbb r9, [rdx + 8]
    mov r10, [rsi + 16]
    sbb r10, [rdx + 16]
    mov r11, [rsi + 24]
    sbb r11, [rdx + 24]
    sbb rax, rax                        ; below 0: it wrapped by 2^256 = 38
    and eax, 38
    sub r8, rax
    sbb r9, 0
    sbb r10, 0
    sbb r11, 0
    sbb rax, rax
    and eax, 38
    sub r8, rax
    ; fall through

fe_store:                               ; R8..R11 to [RDI], then the pops
    mov [rdi], r8
    mov [rdi + 8], r9
    mov [rdi + 16], r10
    mov [rdi + 24], r11
    pop r11
    pop r10
    pop r9
    pop r8
    ret

; fe_a24(RDI = result, RSI = a): a * 121665
fe_a24:
    push rcx
    push rdx
    push rbp
    push r8
    push r9
    push r10
    push r11
    mov ecx, A24
    mov rax, [rsi]
    mul rcx
    mov r8, rax
    mov r9, rdx
    mov rax, [rsi + 8]
    mul rcx
    add r9, rax
    adc rdx, 0
    mov r10, rdx
    mov rax, [rsi + 16]
    mul rcx
    add r10, rax
    adc rdx, 0
    mov r11, rdx
    mov rax, [rsi + 24]
    mul rcx
    add r11, rax
    adc rdx, 0
    imul rax, rdx, 38                   ; the fifth limb, folded
    add r8, rax
    adc r9, 0
    adc r10, 0
    adc r11, 0
    sbb rax, rax
    and eax, 38
    add r8, rax
    mov [rdi], r8
    mov [rdi + 8], r9
    mov [rdi + 16], r10
    mov [rdi + 24], r11
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdx
    pop rcx
    ret

; fe_cswap(RDI = a, RSI = b, EAX = 1 to swap)
fe_cswap:
    push rcx
    push rdx
    push r8
    mov r8, rax                         ; 0 or all ones
    neg r8
    xor ecx, ecx
.limb:
    mov rdx, [rdi + rcx * 8]
    xor rdx, [rsi + rcx * 8]
    and rdx, r8
    xor [rdi + rcx * 8], rdx
    xor [rsi + rcx * 8], rdx
    inc ecx
    cmp ecx, 4
    jb .limb
    pop r8
    pop rdx
    pop rcx
    ret

; fe_freeze(RDI): reduced below p, by subtracting p while it fits (twice
; covers everything below 2^256)
fe_freeze:
    push rbx
    push rcx
    push rdx
    push rbp
    push r8
    push r9
    push r10
    push r11
    mov r8, [rdi]
    mov r9, [rdi + 8]
    mov r10, [rdi + 16]
    mov r11, [rdi + 24]
%rep 2
    mov rax, r8
    mov rcx, r9
    mov rdx, r10
    mov rbx, r11
    mov rbp, 0xFFFFFFFFFFFFFFED
    sub rax, rbp
    mov rbp, -1
    sbb rcx, rbp
    sbb rdx, rbp
    mov rbp, 0x7FFFFFFFFFFFFFFF
    sbb rbx, rbp
    cmovnc r8, rax
    cmovnc r9, rcx
    cmovnc r10, rdx
    cmovnc r11, rbx
%endrep
    mov [rdi], r8
    mov [rdi + 8], r9
    mov [rdi + 16], r10
    mov [rdi + 24], r11
    pop r11
    pop r10
    pop r9
    pop r8
    pop rbp
    pop rdx
    pop rcx
    pop rbx
    ret

; fe_inv(RDI = result, RSI = z): z^(p - 2). The exponent is public:
; bits 254..5 set, then 01011.
fe_inv:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rdi
    lea rdi, [fz_base]
    mov ecx, 32
    rep movsb
    lea rdi, [fz_acc]
    xor eax, eax
    mov ecx, 32
    rep stosb
    mov byte [fz_acc], 1
    mov ebx, 254
.bit:
    FE fe_mul, fz_acc, fz_acc, fz_acc
    cmp ebx, 5
    jae .one
    mov eax, 0x0B
    mov ecx, ebx
    shr eax, cl
    test eax, 1
    jz .next
.one:
    FE fe_mul, fz_acc, fz_acc, fz_base
.next:
    dec ebx
    jns .bit
    pop rdi
    lea rsi, [fz_acc]
    mov ecx, 32
    rep movsb
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .rodata
x_nine:         db 9
                times 31 db 0

section .bss
alignb 8
xk:             resb 32                 ; from here to x_scratch_end: cleared
fx1:            resb 32
fx2:            resb 32
fz2:            resb 32
fx3:            resb 32
fz3:            resb 32
fA:             resb 32
fAA:            resb 32
fB:             resb 32
fBB:            resb 32
fE:             resb 32
fC:             resb 32
fD:             resb 32
fDA:            resb 32
fCB:            resb 32
fz_base:        resb 32
fz_acc:         resb 32
x_scratch_end:
