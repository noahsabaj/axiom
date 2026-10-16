; =============================================================================
;  sbc.asm - the SBC encoder (low-complexity subband codec), the one codec
;  every A2DP sink must decode: 16-bit PCM in, Bluetooth audio frames out.
;
;  A frame is `blocks` blocks of M = 4 or 8 subband samples per channel.
;  Each frame goes through the steps of A2DP spec 12.8, in this order:
;    analysis   the 10M-tap polyphase filterbank: window by the prototype,
;               fold into 2M partial sums, cosine-matrix into M subbands
;    scale      per subband, the power of two that bounds its samples; in
;               joint stereo, mid/side instead of left/right per subband
;               where that needs less (never the top subband)
;    allocate   the spec's bit allocation from the scale factors alone (the
;               decoder repeats it, so it has to match bit for bit)
;    pack       mid-rise quantisation, MSB first behind the 4-byte header,
;               the CRC-8 over header, join bits and scale factors last
;
;  The filterbank runs in double precision, four lanes per AVX op with FMA
;  (callers gate on cpu_has_avx2_fma, like the Mandelbrot). Each channel
;  keeps one buffer in time order: the last 9M samples of the frame before,
;  then this frame. Every block's 10M-sample window is then a plain slice of
;  it, so the spec's shift register X (newest first) becomes a pointer step,
;  and the window table is stored reversed to match.
;
;  One encoder, its state (about 8 KiB) in .bss: not reentrant.
; =============================================================================

SBC_SYNC        equ 0x9C
SBC_MONO        equ 0                   ; channel modes, as in the header
SBC_DUAL        equ 1
SBC_STEREO      equ 2
SBC_JOINT       equ 3
SBC_SNR         equ 1                   ; allocation method 1; 0 is loudness
SBC_BUF         equ 9 * 8 + 16 * 8      ; doubles per channel: history + frame
SBC_BLOCK       equ 2 * 8 * 8           ; bytes per block in sbc_sb

section .text

; -----------------------------------------------------------------------------
;  sbc_setup(EDI = sampling frequency 0 16k, 1 32k, 2 44.1k, 3 48k,
;            ESI = channel mode 0 mono, 1 dual, 2 stereo, 3 joint stereo,
;            EDX = blocks 4/8/12/16, ECX = subbands 4/8,
;            R8D = allocation 0 loudness, 1 SNR, R9D = bitpool)
;  -> EAX = frame length in bytes, or 0 if the parameters are invalid (the
;  encoder is then unconfigured and sbc_encode writes nothing). Resets the
;  filter history. Preserves everything but RAX.
; -----------------------------------------------------------------------------
sbc_setup:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    mov dword [sbc_len], 0
    cmp edi, 3
    ja .bad
    cmp esi, 3
    ja .bad
    cmp r8d, 1
    ja .bad
    lea eax, [rdx - 4]                  ; blocks: 4, 8, 12 or 16
    cmp eax, 12
    ja .bad
    test edx, 3
    jnz .bad
    cmp ecx, 4
    je .bands
    cmp ecx, 8
    jne .bad
.bands:
    cmp r9d, 2
    jb .bad
    cmp r9d, 250
    ja .bad
    mov eax, ecx                        ; at most 16 bits per subband...
    shl eax, 4
    cmp esi, SBC_STEREO
    jb .pool
    add eax, eax                        ; ...and channel, sharing one pool
.pool:
    cmp r9d, eax
    ja .bad

    mov [sbc_freq], edi
    mov [sbc_mode], esi
    mov [sbc_nblk], edx
    mov [sbc_nsb], ecx
    mov [sbc_method], r8d
    mov [sbc_pool], r9d
    xor eax, eax
    test esi, esi
    setnz al
    inc eax
    mov [sbc_nch], eax
    mov r10d, eax                       ; channels
    mov eax, edi                        ; header byte 1: frequency, blocks,
    shl eax, 2                          ; mode, allocation, subbands
    mov ebx, edx
    shr ebx, 2
    dec ebx
    or eax, ebx
    shl eax, 2
    or eax, esi
    shl eax, 1
    or eax, r8d
    shl eax, 1
    cmp ecx, 8
    jne .header
    or eax, 1
.header:
    mov [sbc_hdr], eax

    ; the window, oldest sample first: the spec's C[10M - 1] down to C[0]
    lea rsi, [sbc_proto8]
    cmp ecx, 8
    je .proto
    lea rsi, [sbc_proto4]
.proto:
    imul ebx, ecx, 10
    lea rsi, [rsi + rbx * 8 - 8]
    lea rdi, [sbc_win]
.window:
    mov rax, [rsi]
    mov [rdi], rax
    sub rsi, 8
    add rdi, 8
    dec ebx
    jnz .window

    ; the cosine matrix, one column of 8 per partial sum u (zero past M):
    ; mat[u][k] = cos((k + 1/2)(3M/2 - 1 - u) pi / M), the spec's
    ; M[k][2M - 1 - u] since our sums run oldest first. (2k + 1)(3M/2 - 1 - u)
    ; counts in steps of pi/2M; sbc_cos steps in pi/16, so scale by 8/M and
    ; wrap at a full turn
    lea rdi, [sbc_mat]
    lea r11, [sbc_cos]
    xor r8d, r8d                        ; u
.row:
    xor r9d, r9d                        ; k
.col:
    vxorpd xmm0, xmm0, xmm0
    cmp r9d, ecx
    jae .entry
    lea eax, [rcx + rcx * 2]
    shr eax, 1
    dec eax
    sub eax, r8d
    lea ebx, [r9 * 2 + 1]
    imul eax, ebx
    cmp ecx, 8
    je .turn
    add eax, eax                        ; pi/8 is two steps of pi/16
.turn:
    and eax, 31
    vmovsd xmm0, [r11 + rax * 8]
.entry:
    vmovsd [rdi], xmm0
    add rdi, 8
    inc r9d
    cmp r9d, 8
    jb .col
    inc r8d
    lea eax, [rcx * 2]
    cmp r8d, eax
    jb .row

    lea rdi, [sbc_x]                    ; silence before the first frame
    vxorpd ymm0, ymm0, ymm0
    mov eax, SBC_BUF * 2 / 4
.clear:
    vmovapd [rdi], ymm0
    add rdi, 32
    dec eax
    jnz .clear
    vzeroupper

    ; frame length: header, join bits (joint), 4-bit scale factors, samples
    ;   mono, dual  4 + 4 M nch / 8 + ceil(blocks nch bitpool / 8)
    ;   stereo      4 + 4 M 2 / 8   + ceil(blocks bitpool / 8)
    ;   joint       4 + 4 M 2 / 8   + ceil((M + blocks bitpool) / 8)
    mov eax, [sbc_nblk]
    imul eax, [sbc_pool]
    cmp dword [sbc_mode], SBC_STEREO
    jae .stereo
    imul eax, r10d
    jmp .bytes
.stereo:
    cmp dword [sbc_mode], SBC_JOINT
    jne .bytes
    add eax, ecx
.bytes:
    add eax, 7
    shr eax, 3
    imul ebx, ecx, 4
    imul ebx, r10d
    shr ebx, 3
    lea eax, [rax + rbx + 4]
    mov [sbc_len], eax
    jmp .out
.bad:
    xor eax, eax
.out:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; sbc_samples -> EAX = PCM samples per channel per frame (blocks * subbands),
; 0 before a valid sbc_setup
sbc_samples:
    xor eax, eax
    cmp dword [sbc_len], 0
    je .out
    mov eax, [sbc_nblk]
    imul eax, [sbc_nsb]
.out:
    ret

; -----------------------------------------------------------------------------
;  sbc_encode(RSI = PCM: blocks * subbands samples per channel, signed 16-bit,
;             interleaved L, R with two channels; RDI = output)
;  -> EAX = bytes written: one frame, the length sbc_setup returned (0 if not
;  set up). Preserves every general register but RAX; clobbers XMM/YMM.
; -----------------------------------------------------------------------------
sbc_encode:
    xor eax, eax
    cmp dword [sbc_len], 0
    je .none
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
    push rdi                            ; the output, for sbc_pack
    call sbc_load
    call sbc_analyse
    call sbc_scale
    call sbc_bitalloc
    pop rdi
    call sbc_pack
    vzeroupper
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
.none:
    ret

; The steps of sbc_encode. Inputs as stated; each clobbers any general
; register it likes (sbc_encode saves them all).

; sbc_load(RSI = PCM): the frame as doubles, behind each channel's history
sbc_load:
    mov ecx, [sbc_nblk]
    imul ecx, [sbc_nsb]                 ; samples per channel
    mov r8d, [sbc_nch]
    lea rbx, [r8 + r8]                  ; bytes from one sample to the next
    imul eax, [sbc_nsb], 9 * 8          ; past the 9M samples of history
    lea rdi, [sbc_x]
    add rdi, rax
    xor r9d, r9d                        ; channel
.chan:
    lea rdx, [rsi + r9 * 2]
    mov r10, rdi
    mov r11d, ecx
.sample:
    movsx eax, word [rdx]
    vcvtsi2sd xmm0, xmm0, eax
    vmovsd [r10], xmm0
    add rdx, rbx
    add r10, 8
    dec r11d
    jnz .sample
    add rdi, SBC_BUF * 8
    inc r9d
    cmp r9d, r8d
    jb .chan
    ret

; sbc_analyse: every block of every channel through the filterbank into
; sbc_sb, then the frame's last 9M samples become the next one's history
sbc_analyse:
    mov r12d, [sbc_nsb]
    lea r13, [r12 * 8]                  ; bytes per block of input
    mov r14d, [sbc_nch]
    lea rbx, [sbc_x]
    lea rbp, [sbc_sb]
.chan:
    mov rsi, rbx                        ; block 0's window: history + M new
    mov rdi, rbp
    mov r15d, [sbc_nblk]
.block:
    call sbc_filter
    add rsi, r13
    add rdi, SBC_BLOCK
    dec r15d
    jnz .block
    mov rdi, rbx                        ; RSI is at the frame's last 9M
    imul ecx, r12d, 9                   ; samples: the next history. Four at
    shr ecx, 2                          ; a time, forward (the source is
.keep:                                  ; ahead of the destination)
    vmovupd ymm0, [rsi]
    vmovupd [rdi], ymm0
    add rsi, 32
    add rdi, 32
    dec ecx
    jnz .keep
    add rbx, SBC_BUF * 8
    add rbp, 8 * 8                      ; the next channel's slots
    dec r14d
    jnz .chan
    ret

; sbc_filter(RSI = 10M samples, oldest first; RDI = out): one block's M
; subband samples (8 doubles written, zero past M). Preserves RSI, RDI and
; everything else but RAX, RCX, RDX, R8-R11.
sbc_filter:
    ; windowing and partial sums: y[u] = sum over j < 5 of
    ; win[u + 2Mj] * x[u + 2Mj], four u per vector
    lea r8, [sbc_win]
    lea r9, [sbc_y]
    mov r10d, [sbc_nsb]
    shl r10d, 4                         ; 2M doubles, in bytes
    xor ecx, ecx
.group:
    vxorpd ymm0, ymm0, ymm0
    lea rax, [rsi + rcx]
    lea rdx, [r8 + rcx]
    mov r11d, 5
.tap:
    vmovupd ymm1, [rax]
    vfmadd231pd ymm0, ymm1, [rdx]
    add rax, r10
    add rdx, r10
    dec r11d
    jnz .tap
    vmovapd [r9 + rcx], ymm0
    add ecx, 32
    cmp ecx, r10d
    jb .group
    ; matrixing: s = sum over u of y[u] * mat[u], a column of 8 per u
    lea r8, [sbc_mat]
    shr r10d, 3                         ; 2M columns
    vxorpd ymm0, ymm0, ymm0
    vxorpd ymm1, ymm1, ymm1
.column:
    vbroadcastsd ymm2, [r9]
    vfmadd231pd ymm0, ymm2, [r8]
    vfmadd231pd ymm1, ymm2, [r8 + 32]
    add r9, 8
    add r8, 64
    dec r10d
    jnz .column
    vmovapd [rdi], ymm0
    vmovapd [rdi + 32], ymm1
    ret

; sbc_scale: scale factors from the peak of each subband over the frame, and
; in joint stereo the mid/side choice, rewriting those subbands' samples
sbc_scale:
    lea rsi, [sbc_sb]
    mov ecx, [sbc_nblk]
    vbroadcastsd ymm15, [sbc_abs]
    vbroadcastsd ymm14, [sbc_half]
    vxorpd ymm0, ymm0, ymm0             ; peaks of L (or mono), R, mid, side,
    vxorpd ymm1, ymm1, ymm1             ; subbands 0-3 and 4-7 each
    vxorpd ymm2, ymm2, ymm2
    vxorpd ymm3, ymm3, ymm3
    vxorpd ymm4, ymm4, ymm4
    vxorpd ymm5, ymm5, ymm5
    vxorpd ymm6, ymm6, ymm6
    vxorpd ymm7, ymm7, ymm7
.peak:
    vmovapd ymm8, [rsi]
    vmovapd ymm9, [rsi + 32]
    vmovapd ymm10, [rsi + 64]
    vmovapd ymm11, [rsi + 96]
    vandpd ymm12, ymm8, ymm15
    vmaxpd ymm0, ymm0, ymm12
    vandpd ymm12, ymm9, ymm15
    vmaxpd ymm1, ymm1, ymm12
    vandpd ymm12, ymm10, ymm15
    vmaxpd ymm2, ymm2, ymm12
    vandpd ymm12, ymm11, ymm15
    vmaxpd ymm3, ymm3, ymm12
    vaddpd ymm12, ymm8, ymm10           ; mid = (L + R) / 2
    vmulpd ymm12, ymm12, ymm14
    vandpd ymm12, ymm12, ymm15
    vmaxpd ymm4, ymm4, ymm12
    vaddpd ymm12, ymm9, ymm11
    vmulpd ymm12, ymm12, ymm14
    vandpd ymm12, ymm12, ymm15
    vmaxpd ymm5, ymm5, ymm12
    vsubpd ymm12, ymm8, ymm10           ; side = (L - R) / 2
    vmulpd ymm12, ymm12, ymm14
    vandpd ymm12, ymm12, ymm15
    vmaxpd ymm6, ymm6, ymm12
    vsubpd ymm12, ymm9, ymm11
    vmulpd ymm12, ymm12, ymm14
    vandpd ymm12, ymm12, ymm15
    vmaxpd ymm7, ymm7, ymm12
    add rsi, SBC_BLOCK
    dec ecx
    jnz .peak
    lea rsi, [sbc_peak]
    vmovapd [rsi], ymm0
    vmovapd [rsi + 32], ymm1
    vmovapd [rsi + 64], ymm2
    vmovapd [rsi + 96], ymm3
    vmovapd [rsi + 128], ymm4
    vmovapd [rsi + 160], ymm5
    vmovapd [rsi + 192], ymm6
    vmovapd [rsi + 224], ymm7

    lea rdi, [sbc_sf]
    mov r8d, [sbc_nsb]
    xor ecx, ecx
.factor:
    mov rax, [rsi + rcx * 8]
    call sbc_expo
    mov [rdi + rcx * 8], eax
    mov rax, [rsi + rcx * 8 + 64]
    call sbc_expo
    mov [rdi + rcx * 8 + 4], eax
    inc ecx
    cmp ecx, r8d
    jb .factor

    ; joint stereo: mid and side where their scale factors add up to less
    xor r9d, r9d                        ; join field, subband 0 in its top bit
    lea r10, [sbc_jmask]
    vxorpd ymm0, ymm0, ymm0
    vmovapd [r10], ymm0
    vmovapd [r10 + 32], ymm0
    cmp dword [sbc_mode], SBC_JOINT
    jne .done
    xor ecx, ecx
.join:
    lea eax, [r8 - 1]                   ; the top subband stays left/right
    cmp ecx, eax
    jae .joined
    mov rax, [rsi + rcx * 8 + 128]
    call sbc_expo
    mov r11d, eax                       ; mid
    mov rax, [rsi + rcx * 8 + 192]
    call sbc_expo
    mov edx, eax                        ; side
    mov ebx, [rdi + rcx * 8]
    add ebx, [rdi + rcx * 8 + 4]
    lea eax, [r11 + rdx]
    cmp eax, ebx
    jge .next
    mov [rdi + rcx * 8], r11d
    mov [rdi + rcx * 8 + 4], edx
    mov qword [r10 + rcx * 8], -1
    mov eax, r8d
    sub eax, ecx
    dec eax
    bts r9d, eax
.next:
    inc ecx
    jmp .join
.joined:
    test r9d, r9d
    jz .done
    vmovapd ymm12, [r10]
    vmovapd ymm13, [r10 + 32]
    lea rsi, [sbc_sb]
    mov ecx, [sbc_nblk]
.mix:                                   ; the same arithmetic as the peaks
    vmovapd ymm8, [rsi]
    vmovapd ymm9, [rsi + 32]
    vmovapd ymm10, [rsi + 64]
    vmovapd ymm11, [rsi + 96]
    vaddpd ymm0, ymm8, ymm10
    vmulpd ymm0, ymm0, ymm14
    vsubpd ymm1, ymm8, ymm10
    vmulpd ymm1, ymm1, ymm14
    vaddpd ymm2, ymm9, ymm11
    vmulpd ymm2, ymm2, ymm14
    vsubpd ymm3, ymm9, ymm11
    vmulpd ymm3, ymm3, ymm14
    vblendvpd ymm8, ymm8, ymm0, ymm12
    vblendvpd ymm10, ymm10, ymm1, ymm12
    vblendvpd ymm9, ymm9, ymm2, ymm13
    vblendvpd ymm11, ymm11, ymm3, ymm13
    vmovapd [rsi], ymm8
    vmovapd [rsi + 32], ymm9
    vmovapd [rsi + 64], ymm10
    vmovapd [rsi + 96], ymm11
    add rsi, SBC_BLOCK
    dec ecx
    jnz .mix
.done:
    mov [sbc_join], r9d
    ret

; sbc_expo(RAX = a non-negative double, as bits) -> EAX = its scale factor:
; floor(log2), at least 0, so the subband's samples are all below 2^(sf + 1).
; 16-bit input keeps every subband below 52,400 (the sum of |window *
; cosine|, times 32767), so the cap at 15 is only a guard. Changes only RAX.
sbc_expo:
    shr rax, 52
    sub eax, 1023
    jns .low
    xor eax, eax
.low:
    cmp eax, 15
    jbe .out
    mov eax, 15
.out:
    ret

; sbc_bitalloc: bits per subband from the scale factors. The decoder runs
; the same allocation on the scale factors it reads, so every rule here is
; the spec's to the letter
sbc_bitalloc:
    lea rsi, [sbc_sf]
    lea rdi, [sbc_need]
    mov r8d, [sbc_nsb]
    lea rbx, [sbc_off8]
    cmp r8d, 8
    je .offsets
    lea rbx, [sbc_off4]
.offsets:
    mov eax, [sbc_freq]
    imul eax, r8d
    add rbx, rax                        ; this frequency's row
    lea r9d, [r8 + r8]
    xor ecx, ecx
.need:
    mov eax, [rsi + rcx * 4]            ; SNR: the scale factor itself
    cmp dword [sbc_method], SBC_SNR
    je .put
    test eax, eax                       ; loudness: silent subbands -5, the
    jz .silent                          ; rest less their offset, halved
    mov edx, ecx                        ; when positive
    shr edx, 1
    movsx edx, byte [rbx + rdx]
    sub eax, edx
    jle .put
    shr eax, 1
    jmp .put
.silent:
    mov eax, -5
.put:
    mov [rdi + rcx * 4], eax
    inc ecx
    cmp ecx, r9d
    jb .need

    lea rsi, [sbc_need]
    lea rdi, [sbc_bits]
    mov r8d, [sbc_pool]
    cmp dword [sbc_mode], SBC_STEREO
    jae .shared
    mov edx, 8                          ; mono, dual: each channel spends the
    mov ecx, [sbc_nsb]                  ; whole pool on its own subbands
    call sbc_slices
    cmp dword [sbc_mode], SBC_DUAL
    jne .out
    add rsi, 4
    add rdi, 4
    mov ecx, [sbc_nsb]
    jmp sbc_slices
.shared:
    mov edx, 4                          ; stereo, joint: one pool, handed out
    mov ecx, [sbc_nsb]                  ; channel 0 then 1 in each subband
    add ecx, ecx
    jmp sbc_slices
.out:
    ret

; sbc_slices(RSI = bitneed, RDI = bits, RDX = byte stride, ECX = entries,
; R8D = bitpool): the bitslice allocation over one list of subbands, in the
; order the leftover bits go out. Preserves RCX, RDX, RSI, RDI, R8.
sbc_slices:
    xor r9d, r9d                        ; the largest need, at least 0
    mov rbx, rsi
    mov r12d, ecx
.max:
    mov eax, [rbx]
    cmp eax, r9d
    cmovg r9d, eax
    add rbx, rdx
    dec r12d
    jnz .max
    inc r9d                             ; bitslice
    xor r10d, r10d                      ; bitcount
    xor r11d, r11d                      ; slicecount
.slice:                                 ; lower the slice until the pool fills
    dec r9d
    add r10d, r11d
    xor r11d, r11d
    mov rbx, rsi
    mov r12d, ecx
.count:
    mov eax, [rbx]
    sub eax, r9d                        ; need - bitslice
    cmp eax, 1
    jl .count_next
    je .count_two                       ; just reached: starts at 2 bits
    cmp eax, 16
    jge .count_next                     ; already at 16
    inc r11d
    jmp .count_next
.count_two:
    add r11d, 2
.count_next:
    add rbx, rdx
    dec r12d
    jnz .count
    lea eax, [r10 + r11]
    cmp eax, r8d
    jl .slice
    jne .assign
    mov r10d, eax                       ; exactly full: that slice fits too
    dec r9d
.assign:
    mov rbx, rsi
    mov r13, rdi
    mov r12d, ecx
.set:
    mov eax, [rbx]
    sub eax, r9d
    cmp eax, 2
    jge .cap
    xor eax, eax
.cap:
    cmp eax, 16
    jle .store
    mov eax, 16
.store:
    mov [r13], eax
    add rbx, rdx
    add r13, rdx
    dec r12d
    jnz .set
    ; leftover, first pass: a bit more for coded subbands below 16, or 2
    ; bits for one that just missed the slice, if two are left
    mov rbx, rsi
    mov r13, rdi
    mov r12d, ecx
.grow:
    cmp r10d, r8d
    jge .done
    mov eax, [r13]
    cmp eax, 2
    jl .start
    cmp eax, 16
    jge .start
    inc dword [r13]
    inc r10d
    jmp .grow_next
.start:
    mov eax, [rbx]
    sub eax, r9d
    cmp eax, 1
    jne .grow_next
    lea eax, [r10 + 1]
    cmp r8d, eax
    jle .grow_next
    mov dword [r13], 2
    add r10d, 2
.grow_next:
    add rbx, rdx
    add r13, rdx
    dec r12d
    jnz .grow
    ; second pass: one bit each to any subband below 16, same order
    mov r13, rdi
    mov r12d, ecx
.fill:
    cmp r10d, r8d
    jge .done
    cmp dword [r13], 16
    jge .fill_next
    inc dword [r13]
    inc r10d
.fill_next:
    add r13, rdx
    dec r12d
    jnz .fill
.done:
    ret

; sbc_pack(RDI = out) -> EAX = frame length: header, join bits, scale
; factors, quantised samples, padding, then the CRC into byte 3
sbc_pack:
    mov r15, rdi
    mov byte [rdi], SBC_SYNC
    mov eax, [sbc_hdr]
    mov [rdi + 1], al
    mov eax, [sbc_pool]
    mov [rdi + 2], al
    mov byte [rdi + 3], 0
    add rdi, 4
    xor r8d, r8d                        ; bit accumulator for sbc_put
    xor r9d, r9d                        ; bits pending in it
    mov r12d, [sbc_nsb]
    cmp dword [sbc_mode], SBC_JOINT
    jne .factors
    mov eax, [sbc_join]
    mov ecx, r12d
    call sbc_put
.factors:
    lea rsi, [sbc_sf]
    xor r13d, r13d                      ; channel
.f_chan:
    xor r14d, r14d                      ; subband
.f_band:
    lea eax, [r14 * 2 + r13]
    mov eax, [rsi + rax * 4]
    mov ecx, 4
    call sbc_put
    inc r14d
    cmp r14d, r12d
    jb .f_band
    inc r13d
    cmp r13d, [sbc_nch]
    jb .f_chan

    ; the quantiser of each subband: q = floor((x / 2^(sf+1) + 1) L / 2),
    ; L = 2^bits - 1 levels, as x * L / 2^(sf+2) + L / 2 (both factors exact)
    ; and kept within 0..L-1; the decoder takes level q back to the middle of
    ; its step, 2^(sf+1) ((2q + 1) / L - 1)
    lea rsi, [sbc_bits]
    lea rbx, [sbc_sf]
    lea rdx, [sbc_quant]
    lea r10d, [r12 * 2]
    xor ecx, ecx
.level:
    mov eax, [rsi + rcx * 4]
    test eax, eax
    jz .level_next
    xor r11d, r11d
    bts r11d, eax
    dec r11d                            ; L
    lea eax, [r11 - 1]
    mov [rdx + 16], eax                 ; top level
    vcvtsi2sd xmm0, xmm0, r11d
    mov eax, 1023 - 2                   ; 2^-(sf + 2), built from its exponent
    sub eax, [rbx + rcx * 4]
    shl rax, 52
    vmovq xmm1, rax
    vmulsd xmm1, xmm1, xmm0
    vmovsd [rdx], xmm1
    vmulsd xmm0, xmm0, [sbc_half]
    vmovsd [rdx + 8], xmm0
.level_next:
    add rdx, 32
    inc ecx
    cmp ecx, r10d
    jb .level

    lea r10, [sbc_sb]
    mov r11d, [sbc_nblk]
.s_block:
    xor r13d, r13d                      ; channel
.s_chan:
    xor r14d, r14d                      ; subband
.s_band:
    lea ebx, [r14 * 2 + r13]
    mov ecx, [rsi + rbx * 4]
    test ecx, ecx
    jz .s_next
    lea eax, [r13 * 8 + r14]
    vmovsd xmm0, [r10 + rax * 8]
    mov eax, ebx
    shl eax, 5
    lea rdx, [sbc_quant]
    add rdx, rax
    vmovsd xmm1, [rdx + 8]
    vfmadd231sd xmm1, xmm0, [rdx]
    vcvttsd2si eax, xmm1                ; truncation is floor from 0 up
    test eax, eax
    jns .s_low
    xor eax, eax
.s_low:
    mov edx, [rdx + 16]
    cmp eax, edx
    cmovg eax, edx
    call sbc_put
.s_next:
    inc r14d
    cmp r14d, r12d
    jb .s_band
    inc r13d
    cmp r13d, [sbc_nch]
    jb .s_chan
    add r10, SBC_BLOCK
    dec r11d
    jnz .s_block

    test r9d, r9d                       ; the last partial byte
    jz .flushed
    mov ecx, 8
    sub ecx, r9d
    xor eax, eax
    call sbc_put
.flushed:
    mov eax, [sbc_len]                  ; zeroes up to the frame length (the
    lea rdx, [r15 + rax]                ; allocation can leave a few bits)
.pad:
    cmp rdi, rdx
    jae .crc
    mov byte [rdi], 0
    inc rdi
    jmp .pad
.crc:
    ; CRC-8 over bytes 1-2, then from byte 4 the join bits and scale factors
    mov r10d, [sbc_nsb]
    imul r10d, [sbc_nch]
    shl r10d, 2
    cmp dword [sbc_mode], SBC_JOINT
    jne .crc_run
    add r10d, [sbc_nsb]
.crc_run:
    mov dl, 0x0F
    lea rsi, [r15 + 1]
    mov ecx, 16
    call sbc_crc
    lea rsi, [r15 + 4]
    mov ecx, r10d
    call sbc_crc
    mov [r15 + 3], dl
    mov eax, [sbc_len]
    ret

; sbc_put(EAX = value, ECX = 1..16 bits): append the low ECX bits of RAX
; (nothing above them may be set), MSB first. R8 = accumulator, R9D = bits
; pending in it, RDI = next byte. Clobbers RAX, RCX.
sbc_put:
    shl r8, cl
    or r8, rax
    add r9d, ecx
.byte:
    cmp r9d, 8
    jb .out
    sub r9d, 8
    mov ecx, r9d
    mov rax, r8
    shr rax, cl
    mov [rdi], al
    inc rdi
    jmp .byte
.out:
    ret

; sbc_crc(RSI = bytes, ECX = bits > 0, DL = CRC so far) -> DL: CRC-8 with
; x^8 + x^4 + x^3 + x^2 + 1, MSB first, a bit at a time (the run ends
; mid-byte). Clobbers RAX, RCX, RSI, R8, R11.
sbc_crc:
    movzx eax, byte [rsi]
    inc rsi
    mov r11d, 8
.bit:
    mov r8d, eax
    xor r8d, edx                        ; top bit: data bit ^ CRC bit 7
    add dl, dl
    add al, al
    test r8b, 0x80
    jz .next
    xor dl, 0x1D
.next:
    dec ecx
    jz .out
    dec r11d
    jnz .bit
    jmp sbc_crc
.out:
    ret

section .rodata
align 32
sbc_abs:        dq 0x7FFFFFFFFFFFFFFF
sbc_half:       dq 0.5

; cos(m pi / 16), m = 0..31: every entry of either cosine matrix is one
sbc_cos:
    dq  1.0,                     0.98078528040323044913,  0.92387953251128675613,  0.83146961230254523708
    dq  0.70710678118654752440,  0.55557023301960222474,  0.38268343236508977173,  0.19509032201612826785
    dq  0.0,                    -0.19509032201612826785, -0.38268343236508977173, -0.55557023301960222474
    dq -0.70710678118654752440, -0.83146961230254523708, -0.92387953251128675613, -0.98078528040323044913
    dq -1.0,                    -0.98078528040323044913, -0.92387953251128675613, -0.83146961230254523708
    dq -0.70710678118654752440, -0.55557023301960222474, -0.38268343236508977173, -0.19509032201612826785
    dq  0.0,                     0.19509032201612826785,  0.38268343236508977173,  0.55557023301960222474
    dq  0.70710678118654752440,  0.83146961230254523708,  0.92387953251128675613,  0.98078528040323044913

; The prototype windows C[0..10M-1] of A2DP spec 12.8 (Tables 12.23 and
; 12.24, the same numbers as BlueZ and FFmpeg use), C[0] multiplying the
; newest sample. They are the lowpass prototype with every other run of 2M
; taps negated, which folds the cosine modulation into 2M partial sums.
sbc_proto4:
    dq  0.00000000E+00,  5.36548976E-04,  1.49188357E-03,  2.73370904E-03
    dq  3.83720193E-03,  3.89205149E-03,  1.86581691E-03, -3.06012286E-03
    dq  1.09137620E-02,  2.04385087E-02,  2.88757392E-02,  3.21939290E-02
    dq  2.58767811E-02,  6.13245186E-03, -2.88217274E-02, -7.76463494E-02
    dq  1.35593274E-01,  1.94987841E-01,  2.46636662E-01,  2.81828203E-01
    dq  2.94315332E-01,  2.81828203E-01,  2.46636662E-01,  1.94987841E-01
    dq -1.35593274E-01, -7.76463494E-02, -2.88217274E-02,  6.13245186E-03
    dq  2.58767811E-02,  3.21939290E-02,  2.88757392E-02,  2.04385087E-02
    dq -1.09137620E-02, -3.06012286E-03,  1.86581691E-03,  3.89205149E-03
    dq  3.83720193E-03,  2.73370904E-03,  1.49188357E-03,  5.36548976E-04

sbc_proto8:
    dq  0.00000000E+00,  1.56575398E-04,  3.43256425E-04,  5.54620202E-04
    dq  8.23919506E-04,  1.13992507E-03,  1.47640169E-03,  1.78371725E-03
    dq  2.01182542E-03,  2.10371989E-03,  1.99454554E-03,  1.61656283E-03
    dq  9.02154502E-04, -1.78805361E-04, -1.64973098E-03, -3.49717454E-03
    dq  5.65949473E-03,  8.02941163E-03,  1.04584443E-02,  1.27472335E-02
    dq  1.46525263E-02,  1.59045603E-02,  1.62208471E-02,  1.53184106E-02
    dq  1.29371806E-02,  8.85757540E-03,  2.92408442E-03, -4.91578024E-03
    dq -1.46404076E-02, -2.61098752E-02, -3.90751381E-02, -5.31873032E-02
    dq  6.79989431E-02,  8.29847578E-02,  9.75753918E-02,  1.11196689E-01
    dq  1.23264548E-01,  1.33264415E-01,  1.40753505E-01,  1.45389847E-01
    dq  1.46955068E-01,  1.45389847E-01,  1.40753505E-01,  1.33264415E-01
    dq  1.23264548E-01,  1.11196689E-01,  9.75753918E-02,  8.29847578E-02
    dq -6.79989431E-02, -5.31873032E-02, -3.90751381E-02, -2.61098752E-02
    dq -1.46404076E-02, -4.91578024E-03,  2.92408442E-03,  8.85757540E-03
    dq  1.29371806E-02,  1.53184106E-02,  1.62208471E-02,  1.59045603E-02
    dq  1.46525263E-02,  1.27472335E-02,  1.04584443E-02,  8.02941163E-03
    dq -5.65949473E-03, -3.49717454E-03, -1.64973098E-03, -1.78805361E-04
    dq  9.02154502E-04,  1.61656283E-03,  1.99454554E-03,  2.10371989E-03
    dq  2.01182542E-03,  1.78371725E-03,  1.47640169E-03,  1.13992507E-03
    dq  8.23919506E-04,  5.54620202E-04,  3.43256425E-04,  1.56575398E-04

; loudness offsets per sampling frequency (16k, 32k, 44.1k, 48k), the
; spec's offset4 and offset8 tables
sbc_off4:
    db -1, 0, 0, 0
    db -2, 0, 0, 1
    db -2, 0, 0, 1
    db -2, 0, 0, 1
sbc_off8:
    db -2, 0, 0, 0, 0, 0, 0, 1
    db -3, 0, 0, 0, 0, 0, 1, 2
    db -4, 0, 0, 0, 0, 0, 1, 2
    db -4, 0, 0, 0, 0, 0, 1, 2

section .bss
alignb 64
sbc_x:          resq SBC_BUF * 2        ; per channel: 9M history, then the frame
sbc_sb:         resq 16 * 2 * 8         ; subband samples [block][channel][band]
sbc_win:        resq 80                 ; prototype window, oldest sample first
sbc_mat:        resq 16 * 8             ; cosine matrix, a column per partial sum
sbc_y:          resq 16                 ; one block's partial sums
sbc_peak:       resq 4 * 8              ; per band: peak |L|, |R|, |mid|, |side|
sbc_jmask:      resq 8                  ; all ones for the joint subbands
sbc_quant:      resb 16 * 32            ; per entry: scale, offset, top level
; per (band, channel) lists, entry 2 * band + channel: the order the
; stereo allocation hands out bits
sbc_sf:         resd 16                 ; scale factors
sbc_need:       resd 16                 ; bitneed
sbc_bits:       resd 16                 ; bits per sample
sbc_freq:       resd 1
sbc_mode:       resd 1
sbc_nblk:       resd 1                  ; blocks
sbc_nsb:        resd 1                  ; subbands, M
sbc_method:     resd 1                  ; allocation
sbc_pool:       resd 1                  ; bitpool
sbc_nch:        resd 1
sbc_hdr:        resd 1                  ; header byte 1
sbc_join:       resd 1                  ; join field, subband 0 in bit M-1
sbc_len:        resd 1                  ; frame length; 0 = not set up
