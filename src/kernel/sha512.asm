; =============================================================================
;  sha512.asm - SHA-512 and SHA-384 (FIPS 180-4), in one call each, for the
;  signatures on certificates: plain x86-64 (the i7-14700F has no SHA-512
;  instructions).
;
;    sha512(RDI = digest[64], RSI = data, RDX = bytes)
;    sha384(RDI = digest[48], RSI = data, RDX = bytes)
;
;  Both preserve every register but RAX and touch no XMM register. Scratch
;  lives in .bss: main loop only.
; =============================================================================

section .text

sha512:
    push rcx
    push r8
    lea rcx, [s5_iv512]
    mov r8d, 64
    call s5_hash
    pop r8
    pop rcx
    ret

sha384:
    push rcx
    push r8
    lea rcx, [s5_iv384]
    mov r8d, 48
    call s5_hash
    pop r8
    pop rcx
    ret

; s5_hash(RDI = digest, RSI = data, RDX = bytes, RCX = first state, R8D =
; digest bytes). Preserves all but RAX.
s5_hash:
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
    mov [s5_out], rdi
    mov [s5_len], rdx
    mov [s5_dlen], r8
    push rsi
    mov rsi, rcx
    lea rdi, [s5_h]
    mov ecx, 64
    rep movsb
    pop rsi
.whole:
    cmp qword [s5_len], 128
    jb .tail
    push rsi
    call s5_block
    pop rsi
    add rsi, 128
    sub qword [s5_len], 128
    jmp .whole
.tail:
    lea rdi, [s5_buf]                   ; the rest, 0x80, zeros, the length
    push rdi
    xor eax, eax
    mov ecx, 256
    rep stosb
    pop rdi
    mov rcx, [s5_len]
    rep movsb
    mov byte [rdi], 0x80
    lea rdi, [s5_buf]
    mov ebp, 128                        ; RBP = bytes of padded tail
    cmp qword [s5_len], 112
    jb .one
    mov ebp, 256
.one:
    mov rcx, [rsp + 11 * 8]             ; the caller's RDX: all the bytes
    mov rax, rcx
    shl rcx, 3
    bswap rcx
    mov [rdi + rbp - 8], rcx
    shr rax, 61
    bswap rax
    mov [rdi + rbp - 16], rax
    mov rsi, rdi
    push rbp
    call s5_block
    pop rbp
    cmp ebp, 256
    jb .out
    lea rsi, [s5_buf + 128]
    call s5_block
.out:
    mov rdi, [s5_out]                   ; the digest, big-endian words
    mov r8, [s5_dlen]
    lea rsi, [s5_h]
    xor ecx, ecx
.word:
    mov rax, [rsi + rcx]
    bswap rax
    mov [rdi + rcx], rax
    add ecx, 8
    cmp ecx, r8d
    jb .word
    lea rdi, [s5_buf]                   ; nothing left behind
    xor eax, eax
    mov ecx, 256 + 640
    rep stosb
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

; s5_block(RSI = 128 bytes): s5_h updated. Changes RAX, RBX, RCX, RDX, RSI,
; RDI, RBP and R8-R15.
s5_block:
    lea rdi, [s5_w]
    xor ecx, ecx
.load:
    mov rax, [rsi + rcx * 8]
    bswap rax
    mov [rdi + rcx * 8], rax
    inc ecx
    cmp ecx, 16
    jb .load
.expand:                                ; W[t] = s1(W[t-2]) + W[t-7] + s0(W[t-15]) + W[t-16]
    mov rax, [rdi + rcx * 8 - 2 * 8]
    mov rdx, rax
    ror rdx, 19
    mov rbx, rax
    ror rbx, 61
    xor rdx, rbx
    shr rax, 6
    xor rdx, rax
    mov rax, [rdi + rcx * 8 - 15 * 8]
    mov rbx, rax
    ror rbx, 1
    mov rsi, rax
    ror rsi, 8
    xor rbx, rsi
    shr rax, 7
    xor rbx, rax
    add rdx, rbx
    add rdx, [rdi + rcx * 8 - 7 * 8]
    add rdx, [rdi + rcx * 8 - 16 * 8]
    mov [rdi + rcx * 8], rdx
    inc ecx
    cmp ecx, 80
    jb .expand
    lea rsi, [s5_h]
    mov r8, [rsi]
    mov r9, [rsi + 8]
    mov r10, [rsi + 16]
    mov r11, [rsi + 24]
    mov r12, [rsi + 32]
    mov r13, [rsi + 40]
    mov r14, [rsi + 48]
    mov r15, [rsi + 56]
    lea rsi, [s5_k]
    xor ebp, ebp
.round:                                 ; a..h = R8..R15
    mov rax, r12                        ; T1 = h + S1(e) + Ch(e, f, g) + K + W
    ror rax, 14
    mov rbx, r12
    ror rbx, 18
    xor rax, rbx
    ror rbx, 23
    xor rax, rbx
    mov rbx, r13
    xor rbx, r14
    and rbx, r12
    xor rbx, r14
    add rax, rbx
    add rax, r15
    add rax, [rsi + rbp * 8]
    add rax, [rdi + rbp * 8]
    mov rbx, r8                         ; T2 = S0(a) + Maj(a, b, c)
    ror rbx, 28
    mov rcx, r8
    ror rcx, 34
    xor rbx, rcx
    ror rcx, 5
    xor rbx, rcx
    mov rcx, r8
    or rcx, r9
    and rcx, r10
    mov rdx, r8
    and rdx, r9
    or rcx, rdx
    add rbx, rcx
    mov r15, r14
    mov r14, r13
    mov r13, r12
    lea r12, [r11 + rax]
    mov r11, r10
    mov r10, r9
    mov r9, r8
    lea r8, [rax + rbx]
    inc ebp
    cmp ebp, 80
    jb .round
    lea rsi, [s5_h]
    add [rsi], r8
    add [rsi + 8], r9
    add [rsi + 16], r10
    add [rsi + 24], r11
    add [rsi + 32], r12
    add [rsi + 40], r13
    add [rsi + 48], r14
    add [rsi + 56], r15
    ret

section .rodata
align 8
s5_iv512:       dq 0x6a09e667f3bcc908, 0xbb67ae8584caa73b, 0x3c6ef372fe94f82b, 0xa54ff53a5f1d36f1
                dq 0x510e527fade682d1, 0x9b05688c2b3e6c1f, 0x1f83d9abfb41bd6b, 0x5be0cd19137e2179
s5_iv384:       dq 0xcbbb9d5dc1059ed8, 0x629a292a367cd507, 0x9159015a3070dd17, 0x152fecd8f70e5939
                dq 0x67332667ffc00b31, 0x8eb44a8768581511, 0xdb0c2e0d64f98fa7, 0x47b5481dbefa4fa4
s5_k:           dq 0x428a2f98d728ae22, 0x7137449123ef65cd, 0xb5c0fbcfec4d3b2f, 0xe9b5dba58189dbbc
                dq 0x3956c25bf348b538, 0x59f111f1b605d019, 0x923f82a4af194f9b, 0xab1c5ed5da6d8118
                dq 0xd807aa98a3030242, 0x12835b0145706fbe, 0x243185be4ee4b28c, 0x550c7dc3d5ffb4e2
                dq 0x72be5d74f27b896f, 0x80deb1fe3b1696b1, 0x9bdc06a725c71235, 0xc19bf174cf692694
                dq 0xe49b69c19ef14ad2, 0xefbe4786384f25e3, 0x0fc19dc68b8cd5b5, 0x240ca1cc77ac9c65
                dq 0x2de92c6f592b0275, 0x4a7484aa6ea6e483, 0x5cb0a9dcbd41fbd4, 0x76f988da831153b5
                dq 0x983e5152ee66dfab, 0xa831c66d2db43210, 0xb00327c898fb213f, 0xbf597fc7beef0ee4
                dq 0xc6e00bf33da88fc2, 0xd5a79147930aa725, 0x06ca6351e003826f, 0x142929670a0e6e70
                dq 0x27b70a8546d22ffc, 0x2e1b21385c26c926, 0x4d2c6dfc5ac42aed, 0x53380d139d95b3df
                dq 0x650a73548baf63de, 0x766a0abb3c77b2a8, 0x81c2c92e47edaee6, 0x92722c851482353b
                dq 0xa2bfe8a14cf10364, 0xa81a664bbc423001, 0xc24b8b70d0f89791, 0xc76c51a30654be30
                dq 0xd192e819d6ef5218, 0xd69906245565a910, 0xf40e35855771202a, 0x106aa07032bbd1b8
                dq 0x19a4c116b8d2d0c8, 0x1e376c085141ab53, 0x2748774cdf8eeb99, 0x34b0bcb5e19b48a8
                dq 0x391c0cb3c5c95a63, 0x4ed8aa4ae3418acb, 0x5b9cca4f7763e373, 0x682e6ff3d6b2b8a3
                dq 0x748f82ee5defb2fc, 0x78a5636f43172f60, 0x84c87814a1f0ab72, 0x8cc702081a6439ec
                dq 0x90befffa23631e28, 0xa4506cebde82bde9, 0xbef9a3f7b2c67915, 0xc67178f2e372532b
                dq 0xca273eceea26619c, 0xd186b8c721c0c207, 0xeada7dd6cde0eb1e, 0xf57d4f7fee6ed178
                dq 0x06f067aa72176fba, 0x0a637dc5a2c898a6, 0x113f9804bef90dae, 0x1b710b35131c471b
                dq 0x28db77f523047d84, 0x32caab7b40c72493, 0x3c9ebe0a15c9bebc, 0x431d67c49c100d4c
                dq 0x4cc5d4becb3e42b6, 0x597f299cfc657e2a, 0x5fcb6fab3ad6faec, 0x6c44198c4a475817

section .bss
alignb 8
s5_h:           resq 8
s5_out:         resq 1
s5_len:         resq 1                  ; bytes not yet hashed
s5_dlen:        resq 1
s5_buf:         resb 256                ; the padded tail; then s5_w, wiped with it
s5_w:           resq 80
