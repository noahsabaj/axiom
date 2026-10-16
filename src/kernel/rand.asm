; =============================================================================
;  rand.asm - random bytes for keys. A 32-byte pool, stirred on every call
;  with 32 bytes from RDSEED (else RDRAND) and the TSC through SHA-256; the
;  output is SHA-256 of the pool and a counter, and the pool moves on
;  afterwards, so what was handed out cannot be worked back from it.
;
;    rand_bytes(RDI = out, ECX = bytes) -> CF if the CPU has neither RDSEED
;        nor RDRAND (the bytes are then only as good as TSC jitter: not for
;        keys). Preserves all but RAX; clobbers XMM0-XMM10. Main loop only.
; =============================================================================

section .text

rand_bytes:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    cmp byte [rnd_hw], 0
    jne .known
    call rand_detect
.known:
    lea rbx, [rnd_buf + RND_HW]         ; 32 fresh bytes
    xor esi, esi
.word:
    call rand_word
    mov [rbx + rsi * 8], rax
    inc esi
    cmp esi, 4
    jb .word
    rdtsc
    mov [rnd_buf + RND_TSC], eax
    mov [rnd_buf + RND_TSC + 4], edx
    mov al, 's'                         ; pool = H(pool, fresh, tsc, n, 's')
    call rand_hash
    lea rdi, [rnd_buf + RND_POOL]
    lea rsi, [rnd_out]
    mov ecx, 32
    rep movsb
    mov rbx, [rsp + 32]                 ; the bytes wanted
    mov ebx, ebx
.block:
    test rbx, rbx
    jz .done
    mov al, 'o'                         ; out = H(pool, ..., n, 'o')
    call rand_hash
    mov ecx, 32
    cmp rbx, rcx
    cmovb ecx, ebx
    sub rbx, rcx
    lea rsi, [rnd_out]
    mov rdi, r8
    rep movsb
    mov r8, rdi
    jmp .block
.done:
    mov al, 'n'                         ; and the pool moves on
    call rand_hash
    lea rdi, [rnd_buf + RND_POOL]
    lea rsi, [rnd_out]
    mov ecx, 32
    rep movsb
    xor eax, eax
    lea rdi, [rnd_out]
    mov ecx, 32
    rep stosb
    lea rdi, [rnd_buf + RND_HW]
    mov ecx, 32
    rep stosb
    cmp byte [rnd_hw], 2                ; CF if TSC only
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; rand_hash(AL = tag): rnd_out = SHA-256 of the buffer, the counter after
rand_hash:
    push rdx
    push rsi
    push rdi
    inc qword [rnd_buf + RND_N]
    mov [rnd_buf + RND_TAG], al
    lea rdi, [rnd_out]
    lea rsi, [rnd_buf]
    mov edx, RND_SIZE
    call sha256
    pop rdi
    pop rsi
    pop rdx
    ret

; rand_detect: rnd_hw = 3 RDSEED, 2 RDRAND, 1 neither
rand_detect:
    push rbx
    push rcx
    push rdx
    mov byte [rnd_hw], 1
    mov eax, 1
    cpuid
    test ecx, 1 << 30
    jz .seed
    mov byte [rnd_hw], 2
.seed:
    xor eax, eax
    cpuid
    cmp eax, 7
    jb .out
    mov eax, 7
    xor ecx, ecx
    cpuid
    test ebx, 1 << 18
    jz .out
    mov byte [rnd_hw], 3
.out:
    pop rdx
    pop rcx
    pop rbx
    ret

; rand_word -> RAX = 64 bits from RDSEED, else RDRAND, else the TSC
rand_word:
    push rcx
    push rdx
    cmp byte [rnd_hw], 3
    jb .rdrand
    mov ecx, 100                        ; RDSEED may run dry for a moment
.seed:
    rdseed rax
    jc .out
    pause
    dec ecx
    jnz .seed
.rdrand:
    cmp byte [rnd_hw], 2
    jb .tsc
    mov ecx, 10
.rand:
    rdrand rax
    jc .out
    dec ecx
    jnz .rand
.tsc:
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov ecx, 1000                       ; and a little jitter
.spin:
    dec ecx
    jnz .spin
.out:
    pop rdx
    pop rcx
    ret

RND_POOL        equ 0
RND_HW          equ 32
RND_TSC         equ 64
RND_N           equ 72
RND_TAG         equ 80
RND_SIZE        equ 81

section .bss
alignb 8
rnd_buf:        resb 88
rnd_out:        resb 32
rnd_hw:         resb 1
