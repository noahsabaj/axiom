; =============================================================================
;  mandel.asm - the first-light demo: a deep Mandelbrot zoom in AVX2 + FMA,
;  eight pixels per step (two interleaved vectors to hide FMA latency), rows
;  handed out to every core through the job system.
; =============================================================================

MANDEL_INSIDE   equ 0x000000
MANDEL_START    equ 0                   ; frame counter at the start of a zoom
MANDEL_MAXITER  equ 4096
MANDEL_WHEEL_FRAMES equ 6               ; 0.965^6 is about one wheel step

section .text

; mandel_init: palette, and whether this CPU can run the vector kernel
mandel_init:
    push rbx
    push r12
    push r13
    call cpu_has_avx2_fma
    setnz byte [mandel_ok]
    xor ebx, ebx                        ; palette entry
.entry:
    lea rsi, [mandel_keys]              ; find the segment holding entry RBX
.segment:
    cmp byte [rsi + 1], 0               ; last key: its segment wraps to key 0
    je .last
    movzx eax, byte [rsi + 8]           ; where the next key starts
    cmp ebx, eax
    jb .inner
    add rsi, 8
    jmp .segment
.inner:
    mov r10d, [rsi + 12]                ; blend toward the next key
    movzx r13d, byte [rsi + 8]
    jmp .blend
.last:
    mov r10d, [mandel_keys + 4]         ; blend back toward the first key
    mov r13d, 256
.blend:
    movzx r12d, byte [rsi]              ; segment start
    mov r9d, [rsi + 4]                  ; its color
    mov eax, ebx                        ; t = (i - start) * 256 / (end - start)
    sub eax, r12d
    shl eax, 8
    mov ecx, r13d
    sub ecx, r12d
    xor edx, edx
    div ecx
    mov r8d, eax
    xor r11d, r11d
    mov ecx, 16
.channel:
    mov eax, r9d
    shr eax, cl
    and eax, 0xFF
    mov edx, r10d
    shr edx, cl
    and edx, 0xFF
    sub edx, eax                        ; a + (b - a) * t / 256
    imul edx, r8d
    sar edx, 8
    add eax, edx
    shl eax, cl
    or r11d, eax
    sub ecx, 8
    jns .channel
    lea rax, [mandel_palette]
    mov [rax + rbx * 4], r11d
    inc ebx
    cmp ebx, 256
    jb .entry
    call mandel_reset
    pop r13
    pop r12
    pop rbx
    ret

mandel_reset:
    movsd xmm0, [m_start_scale]
    movsd [m_scale], xmm0
    mov qword [m_frame], MANDEL_START
    ret

; mandel_set_view(RDI = pixels, RSI = bytes per row, RDX w, RCX h): what
; to draw into (the demo's window)
mandel_set_view:
    and rdx, ~7                         ; eight pixels per step
    mov [m_dst], rdi
    mov [m_pitch], rsi
    mov [m_width], rdx
    mov [m_height], rcx
    ret

; mandel_prepare: pixel geometry for the current zoom (the scale is the
; height of the view in the complex plane)
mandel_prepare:
    cvtsi2sd xmm0, qword [m_height]
    movsd xmm1, [m_scale]
    divsd xmm1, xmm0                    ; dx: complex units per pixel
    movsd [m_dx], xmm1
    movsd xmm2, xmm1
    mulsd xmm2, [m_eight]
    movsd [m_dx8], xmm2
    xorpd xmm2, xmm2
    subsd xmm2, xmm1
    movsd [m_dy], xmm2                  ; rows go down, imaginary goes up
    cvtsi2sd xmm0, qword [m_width]
    mulsd xmm0, xmm1
    mulsd xmm0, [m_half]
    movsd xmm2, [m_cx]
    subsd xmm2, xmm0
    movsd [m_x0], xmm2                  ; left edge
    cvtsi2sd xmm0, qword [m_height]
    mulsd xmm0, xmm1
    mulsd xmm0, [m_half]
    movsd xmm2, [m_cy]
    addsd xmm2, xmm0
    movsd [m_y0], xmm2                  ; top edge
    mov rax, [m_frame]                  ; deeper zooms need more iterations
    imul rax, rax, 3
    add rax, 192
    cmp rax, MANDEL_MAXITER
    jbe .iter_ok
    mov eax, MANDEL_MAXITER
.iter_ok:
    mov [m_maxiter], rax
    mov rax, [m_frame]                  ; colors drift slowly
    shl rax, 1
    mov [m_phase], rax
    ret

; mandel_advance: next frame of the zoom; restart before doubles run out
mandel_advance:
    movsd xmm0, [m_scale]
    mulsd xmm0, [m_zoom_step]
    movsd [m_scale], xmm0
    inc qword [m_frame]
    comisd xmm0, [m_min_scale]
    jae .out
    call mandel_reset
.out:
    ret

; mandel_row_job(RDI = row): job entry
mandel_row_job:
    jmp mandel_row

; -----------------------------------------------------------------------------
;  mandel_row(RDI = row): render one row of the view into its window
; -----------------------------------------------------------------------------
mandel_row:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbp, rsp
    sub rsp, 64
    and rsp, -32

    vcvtsi2sd xmm0, xmm0, rdi           ; ci = y0 + row * dy, in every lane
    vmulsd xmm0, xmm0, [m_dy]
    vaddsd xmm0, xmm0, [m_y0]
    vbroadcastsd ymm14, xmm0
    vbroadcastsd ymm0, [m_dx]           ; cr for lanes 0-3 and 4-7
    vmulpd ymm12, ymm0, [m_lanes_lo]
    vmulpd ymm11, ymm0, [m_lanes_hi]
    vbroadcastsd ymm1, [m_x0]
    vaddpd ymm12, ymm12, ymm1
    vaddpd ymm11, ymm11, ymm1
    vbroadcastsd ymm15, [m_four]

    mov r12, rdi                        ; destination pixels
    imul r12, [m_pitch]
    add r12, [m_dst]
    mov r13, [m_width]
    shr r13, 3                          ; groups of eight
    jz .row_done
    mov r14, [m_maxiter]
    xor r15d, r15d                      ; iterations in this row
    lea rbx, [mandel_palette]
    mov r9, [m_phase]

.group:
    vxorpd ymm0, ymm0, ymm0             ; A: zr, zi, count
    vxorpd ymm1, ymm1, ymm1
    vpxor ymm2, ymm2, ymm2
    vxorpd ymm8, ymm8, ymm8             ; B: zr, zi, count
    vxorpd ymm9, ymm9, ymm9
    vpxor ymm10, ymm10, ymm10
    mov rcx, r14
.iter:
    vmulpd ymm3, ymm0, ymm0             ; zr^2
    vmulpd ymm6, ymm8, ymm8
    vmulpd ymm4, ymm1, ymm1             ; zi^2
    vmulpd ymm7, ymm9, ymm9
    vaddpd ymm5, ymm3, ymm4             ; |z|^2
    vaddpd ymm13, ymm6, ymm7
    vcmppd ymm5, ymm5, ymm15, 1         ; still inside the radius-2 circle?
    vcmppd ymm13, ymm13, ymm15, 1
    vpsubq ymm2, ymm2, ymm5             ; count the live lanes
    vpsubq ymm10, ymm10, ymm13
    vmulpd ymm1, ymm0, ymm1             ; zi = 2 zr zi + ci
    vmulpd ymm9, ymm8, ymm9
    vfmadd132pd ymm1, ymm14, [m_two]
    vfmadd132pd ymm9, ymm14, [m_two]
    vsubpd ymm0, ymm3, ymm4             ; zr = zr^2 - zi^2 + cr
    vsubpd ymm8, ymm6, ymm7
    vaddpd ymm0, ymm0, ymm12
    vaddpd ymm8, ymm8, ymm11
    vorpd ymm5, ymm5, ymm13
    vtestpd ymm5, ymm5                  ; any lane still iterating?
    jz .escaped
    dec rcx
    jnz .iter
.escaped:
    vmovdqa [rsp], ymm2
    vmovdqa [rsp + 32], ymm10
    xor ecx, ecx
.pixel:
    mov rax, [rsp + rcx * 8]
    add r15, rax
    cmp rax, r14
    jae .inside
    shl eax, 2                          ; a full palette cycle every 64 iterations
    add rax, r9
    movzx eax, al
    mov eax, [rbx + rax * 4]
    jmp .store
.inside:
    mov eax, MANDEL_INSIDE
.store:
    mov [r12 + rcx * 4], eax
    inc ecx
    cmp ecx, 8
    jb .pixel
    add r12, 32
    vbroadcastsd ymm0, [m_dx8]
    vaddpd ymm12, ymm12, ymm0
    vaddpd ymm11, ymm11, ymm0
    dec r13
    jnz .group

    add [gs:PC_ITERS], r15
    lock add [m_iters], r15
.row_done:
    vzeroupper
    mov rsp, rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  mandel_frame: render the next frame on every core and show it
; -----------------------------------------------------------------------------
mandel_frame:
    cmp byte [mandel_ok], 0
    je .out
    cmp qword [m_height], 0
    je .out
    call mandel_prepare
    mov qword [m_iters], 0
    lea rdi, [mandel_row_job]
    mov rsi, [m_height]
    xor edx, edx
    call job_run
    mov rax, [job_cycles]
    mov [m_last_cycles], rax
    mov rax, [m_iters]
    mov [m_last_iters], rax
    mov rax, [m_frame]
    mov [m_last_frame], rax
    mov rax, [m_maxiter]
    mov [m_last_maxiter], rax
    movsd xmm0, [m_scale]
    movsd [m_last_scale], xmm0
    call mandel_show
    mov byte [mandel_dirty], 0
    cmp byte [m_hold], 0                ; held or paused: stay on this frame
    jne .out
    cmp byte [demo_on], 0
    je .out
    call mandel_advance
.out:
    ret

; mandel_point(RDI, RSI = pixel in the view) -> XMM0, XMM1 = that point of the
; complex plane in the frame on screen
mandel_point:
    cvtsi2sd xmm0, rdi
    mulsd xmm0, [m_dx]
    addsd xmm0, [m_x0]
    cvtsi2sd xmm1, rsi
    mulsd xmm1, [m_dy]
    addsd xmm1, [m_y0]
    ret

; mandel_drawn -> CF = 1 if no frame has been drawn yet
mandel_drawn:
    cmp byte [mandel_ok], 0
    je .no
    xorpd xmm2, xmm2
    comisd xmm2, [m_dx]                 ; CF = 0 < dx
    cmc
    ret
.no:
    stc
    ret

; mandel_click(EDX = 1 left, 2 right, 3 middle; RDI, RSI = pixel in the view):
; left centres the zoom there, right holds or resumes it, middle starts over
mandel_click:
    call mandel_drawn
    jc .out
    cmp edx, 2
    je .hold
    cmp edx, 3
    je .home
    call mandel_point
    movsd [m_cx], xmm0
    movsd [m_cy], xmm1
    jmp .dirty
.hold:
    xor byte [m_hold], 1
    ret
.home:
    movsd xmm0, [m_home_cx]
    movsd [m_cx], xmm0
    movsd xmm0, [m_home_cy]
    movsd [m_cy], xmm0
    call mandel_reset
.dirty:
    mov byte [mandel_dirty], 1
.out:
    ret

; mandel_wheel(EDX = notches, up zooms in; RDI, RSI = pixel in the view):
; zoom keeping the point under the pointer where it is
mandel_wheel:
    call mandel_drawn
    jc .out
    push rcx
    call mandel_point
    mov ecx, edx
    movsd xmm4, [m_wheel_in]
    mov rax, MANDEL_WHEEL_FRAMES
    test ecx, ecx
    jns .count
    neg ecx
    movsd xmm4, [m_wheel_out]
    neg rax
.count:
    cmp ecx, 10
    jbe .step
    mov ecx, 10
.step:
    movsd xmm2, [m_scale]
    mulsd xmm2, xmm4
    comisd xmm2, [m_start_scale]        ; no further out than the start
    ja .done
    comisd xmm2, [m_min_scale]          ; nor deeper than doubles can go
    jb .done
    movsd [m_scale], xmm2
    movsd xmm2, [m_cx]                  ; c' = p + (c - p) * f
    subsd xmm2, xmm0
    mulsd xmm2, xmm4
    addsd xmm2, xmm0
    movsd [m_cx], xmm2
    movsd xmm2, [m_cy]
    subsd xmm2, xmm1
    mulsd xmm2, xmm4
    addsd xmm2, xmm1
    movsd [m_cy], xmm2
    add [m_frame], rax                  ; iterations and colors follow the depth
    jns .next
    mov qword [m_frame], 0
.next:
    dec ecx
    jnz .step
.done:
    mov byte [mandel_dirty], 1
    pop rcx
.out:
    ret

; mandel_bench: the same frame on one core, then on all of them
; -> results in bench_one_cycles, bench_all_cycles, bench_iters
mandel_bench:
    push rbx
    push r12
    cmp byte [mandel_ok], 0
    je .out
    movsd xmm0, [m_scale]               ; a fixed, demanding view
    movsd [m_saved_scale], xmm0
    mov rax, [m_frame]
    mov [m_saved_frame], rax
    movsd xmm0, [m_bench_scale]
    movsd [m_scale], xmm0
    mov qword [m_frame], 300
    call mandel_prepare

    mov qword [m_iters], 0              ; one core: the BSP alone
    RDTSC64
    mov rbx, rax
    xor r12d, r12d
.serial:
    cmp r12, [m_height]
    jae .serial_done
    mov rdi, r12
    call mandel_row
    inc r12
    jmp .serial
.serial_done:
    RDTSC64
    sub rax, rbx
    mov [bench_one_cycles], rax
    mov rax, [m_iters]
    mov [bench_iters], rax

    lea rdi, [mandel_row_job]           ; every core
    mov rsi, [m_height]
    xor edx, edx
    call job_run
    mov rax, [job_cycles]
    mov [bench_all_cycles], rax

    movsd xmm0, [m_saved_scale]
    movsd [m_scale], xmm0
    mov rax, [m_saved_frame]
    mov [m_frame], rax
    call mandel_show
.out:
    pop r12
    pop rbx
    ret

section .rodata
align 32
m_lanes_lo:     dq 0.0, 1.0, 2.0, 3.0
m_lanes_hi:     dq 4.0, 5.0, 6.0, 7.0
m_two:          dq 2.0, 2.0, 2.0, 2.0
m_four:         dq 4.0
m_eight:        dq 8.0
m_half:         dq 0.5
m_start_scale:  dq 2.6
m_min_scale:    dq 2.0e-11
m_zoom_step:    dq 0.965
m_bench_scale:  dq 0.0004
m_wheel_in:     dq 0.8
m_wheel_out:    dq 1.25
; the zoom target: deep in the seahorse valley
m_home_cx:      dq -0.743643887037158704752191506114774
m_home_cy:      dq 0.131825904205311970493132056385139

; palette keys: { byte position, byte another-key-follows, word pad, dword color }
; (the last segment wraps back to the first color)
align 4
mandel_keys:
    db 0, 1, 0, 0
    dd 0x0B1026                         ; deep navy
    db 40, 1, 0, 0
    dd 0x1D4ED8                         ; blue
    db 96, 1, 0, 0
    dd 0x5EEAD4                         ; teal
    db 136, 1, 0, 0
    dd 0xF8FAFC                         ; white
    db 176, 1, 0, 0
    dd 0xF5A524                         ; amber
    db 220, 0, 0, 0
    dd 0x7C2D12                         ; rust, then back to navy

section .data
mandel_ok:      db 0
mandel_dirty:   db 0                    ; draw a frame now (the mouse moved it)
m_hold:         db 0                    ; zoom held by a right click
align 8
m_cx:           dq -0.743643887037158704752191506114774
m_cy:           dq 0.131825904205311970493132056385139

section .bss
alignb 8
m_scale:        resq 1
m_frame:        resq 1
m_dx:           resq 1
m_dx8:          resq 1
m_dy:           resq 1
m_x0:           resq 1
m_y0:           resq 1
m_maxiter:      resq 1
m_phase:        resq 1
m_pitch:        resq 1                  ; bytes per row where it draws
m_width:        resq 1
m_height:       resq 1
m_dst:          resq 1
m_last_cycles:  resq 1
m_last_iters:   resq 1
m_last_frame:   resq 1
m_last_maxiter: resq 1
m_last_scale:   resq 1
m_saved_scale:  resq 1
m_saved_frame:  resq 1
bench_one_cycles: resq 1
bench_all_cycles: resq 1
bench_iters:    resq 1
alignb 64
m_iters:        resq 1                  ; shared counter, own cache line
alignb 64
mandel_palette: resd 256
