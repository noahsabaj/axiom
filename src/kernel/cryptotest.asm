; =============================================================================
;  cryptotest.asm - the TLS crypto checked against published vectors on the
;  machine itself (at boot, and by the 'crypto' command, which also times it).
;  The host tests in tools/test/tls cover far more; this proves the
;  instructions behave on this CPU.
;
;    crypto_check -> CF if anything failed (each failure logged)
;    cmd_crypto    the check, then speeds
; =============================================================================

section .text

; ct_expect(RSI = got, RDI = want, ECX = bytes, RDX = what): log a mismatch
ct_expect:
    push rcx
    push rsi
    push rdi
    repe cmpsb
    je .same
    mov byte [ct_bad], 1
    KLOG "crypto: %s gives the wrong answer", rdx
.same:
    pop rdi
    pop rsi
    pop rcx
    ret

; ct_sha: the SHA-256 vectors in the current mode
ct_sha:
    lea rdi, [ct_out]
    lea rsi, [ct_abc]
    mov edx, 3
    call sha256
    lea rsi, [ct_out]
    lea rdi, [ct_abc_sha]
    mov ecx, 32
    lea rdx, [str_ct_sha]
    call ct_expect
    lea rdi, [ct_out]
    lea rsi, [ct_448]
    mov edx, 56                         ; two blocks once padded
    call sha256
    lea rsi, [ct_out]
    lea rdi, [ct_448_sha]
    mov ecx, 32
    lea rdx, [str_ct_sha]
    jmp ct_expect

crypto_check:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    mov byte [ct_bad], 0
    movzx eax, byte [sha256_mode]       ; both ways when SHA-NI is there
    push rax
    mov byte [sha256_mode], 1
    call ct_sha
    call sha256_detect
    cmp byte [sha256_mode], 2
    jne .sha_done
    call ct_sha
.sha_done:
    pop rax
    test al, al
    jz .hmac
    mov [sha256_mode], al

.hmac:                                  ; RFC 4231 test case 2
    lea rdi, [ct_out]
    lea rsi, [ct_jefe]
    mov edx, 4
    lea rcx, [ct_jefe_msg]
    mov r8d, ct_jefe_msg_len
    call hmac_sha256
    lea rsi, [ct_out]
    lea rdi, [ct_jefe_mac]
    mov ecx, 32
    lea rdx, [str_ct_hmac]
    call ct_expect

    lea rdi, [ct_prk]                   ; RFC 5869 test case 1
    lea rsi, [ct_hk_salt]
    mov edx, 13
    lea rcx, [ct_hk_ikm]
    mov r8d, 22
    call hkdf_extract
    lea rdi, [ct_out]
    lea rsi, [ct_prk]
    lea rdx, [ct_hk_info]
    mov ecx, 10
    mov r8d, 42
    call hkdf_expand
    lea rsi, [ct_out]
    lea rdi, [ct_hk_okm]
    mov ecx, 42
    lea rdx, [str_ct_hkdf]
    call ct_expect

    lea rdi, [ct_prk]                   ; RFC 8448: the early secret, then
    xor esi, esi                        ; Derive-Secret(., "derived", "")
    xor edx, edx
    lea rcx, [ct_zero32]
    mov r8d, 32
    call hkdf_extract
    lea rdi, [ct_ctx]
    lea rsi, [ct_zero32]
    xor edx, edx
    call sha256
    lea rdi, [ct_out]
    lea rsi, [ct_prk]
    lea rdx, [str_ct_derived]
    lea rcx, [ct_ctx]
    mov r8d, 32
    mov r9d, 32
    call tls13_expand_label
    lea rsi, [ct_out]
    lea rdi, [ct_derived]
    mov ecx, 32
    lea rdx, [str_ct_label]
    call ct_expect

    call gcm_supported                  ; GCM's test case 4
    jc .x25519
    lea rdi, [ct_gcm]
    lea rsi, [ct_gk]
    call gcm_init
    lea rdi, [ct_out]
    lea rsi, [ct_gp]
    mov ecx, 60
    rep movsb
    call ct_gcm_args
    call gcm_seal
    lea rsi, [ct_out]
    lea rdi, [ct_gc]
    mov ecx, 76
    lea rdx, [str_ct_seal]
    call ct_expect
    xor byte [ct_out + 70], 4           ; a tag one bit off: refused
    call ct_gcm_args
    call gcm_open
    jc .refused
    mov byte [ct_bad], 1
    KLOG "crypto: AES-128-GCM accepts a forged tag"
.refused:
    xor byte [ct_out + 70], 4
    call ct_gcm_args
    call gcm_open
    jnc .opened
    mov byte [ct_bad], 1
.opened:
    lea rsi, [ct_out]
    lea rdi, [ct_gp]
    mov ecx, 60
    lea rdx, [str_ct_open]
    call ct_expect

.x25519:                                ; RFC 7748 6.1
    lea rdi, [ct_out]
    lea rsi, [ct_alice]
    call x25519_base
    lea rsi, [ct_out]
    lea rdi, [ct_alice_pub]
    mov ecx, 32
    lea rdx, [str_ct_x25519]
    call ct_expect
    lea rdi, [ct_out]
    lea rsi, [ct_alice]
    lea rdx, [ct_bob_pub]
    call x25519
    lea rsi, [ct_out]
    lea rdi, [ct_shared]
    mov ecx, 32
    lea rdx, [str_ct_x25519]
    call ct_expect

    cmp byte [ct_bad], 1                ; CF = failed
    cmc
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ct_gcm_args: GCM test case 4's arguments, the record in ct_out
ct_gcm_args:
    lea rdi, [ct_gcm]
    lea rsi, [ct_giv]
    lea rdx, [ct_gaad]
    mov ecx, 20
    lea r8, [ct_out]
    mov r9d, 60
    ret

; crypto_boot: the check, one line in the log
crypto_boot:
    push rcx
    call crypto_check
    jc .out
    call ct_names
    KLOG "crypto: SHA-256 (%s), HMAC, HKDF, AES-128-GCM (%s) and X25519 pass their test vectors", rax, rcx
.out:
    pop rcx
    ret

; ct_names -> RAX = how SHA-256 runs, RCX = how AES-GCM runs
ct_names:
    lea rax, [str_ct_x86]
    cmp byte [sha256_mode], 2
    jne .gcm
    lea rax, [str_ct_shani]
.gcm:
    lea rcx, [str_ct_aesni]
    push rax
    call gcm_supported
    pop rax
    jnc .out
    lea rcx, [str_ct_none]
.out:
    ret

; ct_rate(RAX = TSC ticks for ct_bench_bytes) -> RAX = MB/s
ct_rate:
    push rcx
    push rdx
    mov rcx, rax
    mov eax, ct_bench_bytes
    mul qword [tsc_per_us]
    test rcx, rcx
    jz .out
    div rcx
.out:
    pop rdx
    pop rcx
    ret

cmd_crypto:
    push rbx
    push r12
    push r13
    call crypto_check
    jc .speed
    call ct_names
    KLOG "crypto: SHA-256 (%s), HMAC, HKDF, AES-128-GCM (%s) and X25519 pass their test vectors", rax, rcx
.speed:
    movzx r13d, byte [sha256_mode]
.sha:                                   ; 1 MiB through SHA-256, each way
    RDTSC64
    mov rbx, rax
    mov r12d, ct_bench_bytes / ct_buf_size
.sha_loop:
    lea rdi, [ct_out]
    lea rsi, [ct_buf]
    mov edx, ct_buf_size
    call sha256
    dec r12d
    jnz .sha_loop
    RDTSC64
    sub rax, rbx
    call ct_rate
    lea rcx, [str_ct_x86]
    cmp byte [sha256_mode], 2
    jne .sha_say
    lea rcx, [str_ct_shani]
.sha_say:
    KLOG "crypto: SHA-256 (%s) %u MB/s", rcx, rax
    cmp byte [sha256_mode], 2
    jne .gcm
    mov byte [sha256_mode], 1
    jmp .sha
.gcm:
    mov [sha256_mode], r13b
    call gcm_supported
    jc .ladder
    lea rdi, [ct_gcm]
    lea rsi, [ct_gk]
    call gcm_init
    RDTSC64
    mov rbx, rax
    mov r12d, ct_bench_bytes / ct_buf_size
.gcm_loop:
    lea rdi, [ct_gcm]
    lea rsi, [ct_giv]
    xor edx, edx
    xor ecx, ecx
    lea r8, [ct_buf]
    mov r9d, ct_buf_size - 16
    call gcm_seal
    dec r12d
    jnz .gcm_loop
    RDTSC64
    sub rax, rbx
    call ct_rate
    KLOG "crypto: AES-128-GCM %u MB/s", rax
.ladder:
    RDTSC64
    mov rbx, rax
    mov r12d, 16
.ladder_loop:
    lea rdi, [ct_out]
    lea rsi, [ct_alice]
    lea rdx, [ct_bob_pub]
    call x25519
    dec r12d
    jnz .ladder_loop
    RDTSC64
    sub rax, rbx
    shr rax, 4
    xor edx, edx
    div qword [tsc_per_us]
    KLOG "crypto: X25519 %u us", rax
    pop r13
    pop r12
    pop rbx
    ret

ct_buf_size     equ 65536
ct_bench_bytes  equ 1 << 20

section .rodata
str_ct_sha:     db 'SHA-256', 0
str_ct_hmac:    db 'HMAC-SHA256', 0
str_ct_hkdf:    db 'HKDF', 0
str_ct_label:   db 'HKDF-Expand-Label', 0
str_ct_derived: db 'derived', 0
str_ct_seal:    db 'AES-128-GCM sealing', 0
str_ct_open:    db 'AES-128-GCM opening', 0
str_ct_x25519:  db 'X25519', 0
str_ct_x86:     db 'plain x86', 0
str_ct_shani:   db 'SHA-NI', 0
str_ct_aesni:   db 'AES-NI', 0
str_ct_none:    db 'skipped: no AES-NI here', 0

ct_abc:         db 'abc'
ct_abc_sha:     db 0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea, 0x41, 0x41, 0x40, 0xde
                db 0x5d, 0xae, 0x22, 0x23, 0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c
                db 0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad
ct_448:         db 'abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'
ct_448_sha:     db 0x24, 0x8d, 0x6a, 0x61, 0xd2, 0x06, 0x38, 0xb8, 0xe5, 0xc0, 0x26, 0x93
                db 0x0c, 0x3e, 0x60, 0x39, 0xa3, 0x3c, 0xe4, 0x59, 0x64, 0xff, 0x21, 0x67
                db 0xf6, 0xec, 0xed, 0xd4, 0x19, 0xdb, 0x06, 0xc1
ct_jefe:        db 'Jefe'
ct_jefe_msg:    db 'what do ya want for nothing?'
ct_jefe_msg_len equ $ - ct_jefe_msg
ct_jefe_mac:    db 0x5b, 0xdc, 0xc1, 0x46, 0xbf, 0x60, 0x75, 0x4e, 0x6a, 0x04, 0x24, 0x26
                db 0x08, 0x95, 0x75, 0xc7, 0x5a, 0x00, 0x3f, 0x08, 0x9d, 0x27, 0x39, 0x83
                db 0x9d, 0xec, 0x58, 0xb9, 0x64, 0xec, 0x38, 0x43
ct_hk_salt:     db 0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0a, 0x0b
                db 0x0c
ct_hk_ikm:      times 22 db 0x0b
ct_hk_info:     db 0xf0, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8, 0xf9
ct_hk_okm:      db 0x3c, 0xb2, 0x5f, 0x25, 0xfa, 0xac, 0xd5, 0x7a, 0x90, 0x43, 0x4f, 0x64
                db 0xd0, 0x36, 0x2f, 0x2a, 0x2d, 0x2d, 0x0a, 0x90, 0xcf, 0x1a, 0x5a, 0x4c
                db 0x5d, 0xb0, 0x2d, 0x56, 0xec, 0xc4, 0xc5, 0xbf, 0x34, 0x00, 0x72, 0x08
                db 0xd5, 0xb8, 0x87, 0x18, 0x58, 0x65
ct_zero32:      times 32 db 0
ct_derived:     db 0x6f, 0x26, 0x15, 0xa1, 0x08, 0xc7, 0x02, 0xc5, 0x67, 0x8f, 0x54, 0xfc
                db 0x9d, 0xba, 0xb6, 0x97, 0x16, 0xc0, 0x76, 0x18, 0x9c, 0x48, 0x25, 0x0c
                db 0xeb, 0xea, 0xc3, 0x57, 0x6c, 0x36, 0x11, 0xba
ct_gk:          db 0xfe, 0xff, 0xe9, 0x92, 0x86, 0x65, 0x73, 0x1c, 0x6d, 0x6a, 0x8f, 0x94
                db 0x67, 0x30, 0x83, 0x08
ct_giv:         db 0xca, 0xfe, 0xba, 0xbe, 0xfa, 0xce, 0xdb, 0xad, 0xde, 0xca, 0xf8, 0x88
ct_gaad:        db 0xfe, 0xed, 0xfa, 0xce, 0xde, 0xad, 0xbe, 0xef, 0xfe, 0xed, 0xfa, 0xce
                db 0xde, 0xad, 0xbe, 0xef, 0xab, 0xad, 0xda, 0xd2
ct_gp:          db 0xd9, 0x31, 0x32, 0x25, 0xf8, 0x84, 0x06, 0xe5, 0xa5, 0x59, 0x09, 0xc5
                db 0xaf, 0xf5, 0x26, 0x9a, 0x86, 0xa7, 0xa9, 0x53, 0x15, 0x34, 0xf7, 0xda
                db 0x2e, 0x4c, 0x30, 0x3d, 0x8a, 0x31, 0x8a, 0x72, 0x1c, 0x3c, 0x0c, 0x95
                db 0x95, 0x68, 0x09, 0x53, 0x2f, 0xcf, 0x0e, 0x24, 0x49, 0xa6, 0xb5, 0x25
                db 0xb1, 0x6a, 0xed, 0xf5, 0xaa, 0x0d, 0xe6, 0x57, 0xba, 0x63, 0x7b, 0x39
ct_gc:          db 0x42, 0x83, 0x1e, 0xc2, 0x21, 0x77, 0x74, 0x24, 0x4b, 0x72, 0x21, 0xb7
                db 0x84, 0xd0, 0xd4, 0x9c, 0xe3, 0xaa, 0x21, 0x2f, 0x2c, 0x02, 0xa4, 0xe0
                db 0x35, 0xc1, 0x7e, 0x23, 0x29, 0xac, 0xa1, 0x2e, 0x21, 0xd5, 0x14, 0xb2
                db 0x54, 0x66, 0x93, 0x1c, 0x7d, 0x8f, 0x6a, 0x5a, 0xac, 0x84, 0xaa, 0x05
                db 0x1b, 0xa3, 0x0b, 0x39, 0x6a, 0x0a, 0xac, 0x97, 0x3d, 0x58, 0xe0, 0x91
                db 0x5b, 0xc9, 0x4f, 0xbc, 0x32, 0x21, 0xa5, 0xdb, 0x94, 0xfa, 0xe9, 0x5a
                db 0xe7, 0x12, 0x1a, 0x47           ; the tag
ct_alice:       db 0x77, 0x07, 0x6d, 0x0a, 0x73, 0x18, 0xa5, 0x7d, 0x3c, 0x16, 0xc1, 0x72
                db 0x51, 0xb2, 0x66, 0x45, 0xdf, 0x4c, 0x2f, 0x87, 0xeb, 0xc0, 0x99, 0x2a
                db 0xb1, 0x77, 0xfb, 0xa5, 0x1d, 0xb9, 0x2c, 0x2a
ct_alice_pub:   db 0x85, 0x20, 0xf0, 0x09, 0x89, 0x30, 0xa7, 0x54, 0x74, 0x8b, 0x7d, 0xdc
                db 0xb4, 0x3e, 0xf7, 0x5a, 0x0d, 0xbf, 0x3a, 0x0d, 0x26, 0x38, 0x1a, 0xf4
                db 0xeb, 0xa4, 0xa9, 0x8e, 0xaa, 0x9b, 0x4e, 0x6a
ct_bob_pub:     db 0xde, 0x9e, 0xdb, 0x7d, 0x7b, 0x7d, 0xc1, 0xb4, 0xd3, 0x5b, 0x61, 0xc2
                db 0xec, 0xe4, 0x35, 0x37, 0x3f, 0x83, 0x43, 0xc8, 0x5b, 0x78, 0x67, 0x4d
                db 0xad, 0xfc, 0x7e, 0x14, 0x6f, 0x88, 0x2b, 0x4f
ct_shared:      db 0x4a, 0x5d, 0x9d, 0x5b, 0xa4, 0xce, 0x2d, 0xe1, 0x72, 0x8e, 0x3b, 0xf4
                db 0x80, 0x35, 0x0f, 0x25, 0xe0, 0x7e, 0x21, 0xc9, 0x47, 0xd1, 0x9e, 0x33
                db 0x76, 0xf0, 0x9b, 0x3c, 0x1e, 0x16, 0x17, 0x42

section .bss
alignb 16
ct_gcm:         resb GCM_CTX
ct_out:         resb 80
ct_prk:         resb 32
ct_ctx:         resb 32
ct_bad:         resb 1
alignb 16
ct_buf:         resb ct_buf_size
