; =============================================================================
;  draw.asm - what the desktop is drawn with, beyond gfx.asm's rectangles:
;  colors mixed by coverage, rectangles with round corners and smooth edges,
;  their outlines, soft shadows, frosted glass (what is behind, blurred),
;  gradients without bands, polygons, images with alpha, and the
;  proportional font (gen/uifont.*). All of it draws into the target
;  (gfx_target) within its clip, and preserves every register unless it
;  says otherwise.
;
;  An alpha or a coverage is 0..256 (256: all of it). Mixing works on all
;  four bytes of a pixel, so the same calls paint an image with alpha (B,G,R,A,
;  premultiplied: painting an opaque color at coverage a is the same mix on
;  every byte) as well as the back buffer, whose fourth byte nobody reads.
; =============================================================================

; corners of a rounded rectangle (RC_*), or-ed
RC_TL           equ 1
RC_TR           equ 2
RC_BL           equ 4
RC_BR           equ 8
RC_ALL          equ 15
RC_TOP          equ RC_TL | RC_TR
RC_BOTTOM       equ RC_BL | RC_BR

RR_CACHE        equ 16                  ; corner masks kept, by radius
RR_MAX          equ 255                 ; the largest radius

; a shadow's style (SH_*): built once by shadow_build, drawn by gfx_shadow
SH_R            equ 0                   ; the corner radius of what casts it
SH_M            equ 8                   ; how far it reaches past the edge
SH_OY           equ 16                  ; how far down it falls
SH_A            equ 24                  ; dword: its darkest, 0..256
SH_CORNER       equ 32                  ; (M + R)^2 bytes: the top left block
SH_EDGE         equ 40                  ; M + L bytes: from the outer edge in
SH_L            equ 48                  ; how far inside the edge it still fades
SH_SIZE         equ 56

BLUR_W          equ 4096                ; widest a frosted area may be

; MIX and SCALE, the mixing of colors, are in macros.inc

section .text

; -----------------------------------------------------------------------------
;  Spans: a row of pixels, mixed. RDI = the first pixel, RCX = how many,
;  R8D = the color, R9D = its alpha 1..256. Clobber RAX, RCX, RDX, RSI, RDI,
;  R10, R11.
; -----------------------------------------------------------------------------

; span_fill: the color at its alpha
span_fill:
    test rcx, rcx
    jz .out
    cmp r9d, 256
    jb .mix
    mov eax, r8d
    rep stosd
.out:
    ret
.mix:
    mov edx, 256
    sub edx, r9d
.px:
    mov eax, [rdi]
    MIX eax, r8d, r9d, edx, r10d, r11d
    stosd
    dec rcx
    jnz .px
    ret

; span_mask: each pixel at its coverage too, RSI = the first coverage byte
; (0..255), RDX = the step to the next (+1 or -1)
span_mask:
    test rcx, rcx
    jz .out
    push rbx
    push r12
    push r13
.px:
    movzx eax, byte [rsi]
    add rsi, rdx
    test eax, eax
    jz .next
    mov ebx, eax
    shr ebx, 7
    add eax, ebx
    imul eax, r9d
    shr eax, 8
    jz .next
    mov r12d, eax
    mov r13d, 256
    sub r13d, eax
    mov eax, [rdi]
    MIX eax, r8d, r12d, r13d, r10d, r11d
    mov [rdi], eax
.next:
    add rdi, 4
    dec rcx
    jnz .px
    pop r13
    pop r12
    pop rbx
.out:
    ret

; -----------------------------------------------------------------------------
;  gfx_fill_a(RDI x, RSI y, RDX w, RCX h, R8D color, R9D alpha 0..256)
; -----------------------------------------------------------------------------
gfx_fill_a:
    test r9d, r9d
    jz .none
    cmp r9d, 256
    jae gfx_fill
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    push r13
    push r14
    call gfx_clip
    jz .out
    mov rax, rsi
    imul rax, [tg_pitch]
    lea r12, [rax + rdi * 4]
    add r12, [tg_ptr]
    mov r13, rcx
    mov r14, rdx
.row:
    mov rdi, r12
    mov rcx, r14
    call span_fill
    add r12, [tg_pitch]
    dec r13
    jnz .row
.out:
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.none:
    ret

; -----------------------------------------------------------------------------
;  Round corners. A corner's mask is r x r coverage bytes: the top left
;  corner of a rectangle whose corner is a quarter circle of radius r, each
;  pixel sampled 4 x 4 times.
; -----------------------------------------------------------------------------

; rr_mask(ECX = radius 1..RR_MAX) -> RAX = its mask, 0 if no memory.
; Preserves others.
rr_mask:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    lea rsi, [rr_cache_r]
    lea rdi, [rr_cache_p]
    xor ebx, ebx
.look:
    cmp ebx, RR_CACHE
    jae .make
    cmp [rsi + rbx * 4], ecx
    jne .look_next
    mov rax, [rdi + rbx * 8]
    test rax, rax
    jnz .out
.look_next:
    inc ebx
    jmp .look
.make:
    mov ebx, [rr_cache_next]            ; the oldest goes
    inc dword [rr_cache_next]
    and ebx, RR_CACHE - 1
    mov r12d, ecx
    push rdi
    mov rdi, [rdi + rbx * 8]
    call kfree
    pop rdi
    mov qword [rdi + rbx * 8], 0
    mov dword [rsi + rbx * 4], 0
    mov eax, r12d
    imul eax, eax
    push rdi
    mov edi, eax
    call kmalloc
    pop rdi
    test rax, rax
    jz .out
    mov [rdi + rbx * 8], rax
    mov [rsi + rbx * 4], r12d
    mov r11, rax                        ; the byte being made
    lea r10d, [r12d * 8]                ; the centre, in 1/8 pixels
    mov r9d, r10d
    imul r9d, r9d                       ; radius squared
    xor edx, edx                        ; j
.row:
    cmp edx, r12d
    jae .made
    xor ecx, ecx                        ; i
.col:
    cmp ecx, r12d
    jae .row_next
    xor r8d, r8d                        ; samples inside
    xor esi, esi                        ; t
.sy:
    lea eax, [edx * 8 + 1]
    lea eax, [eax + esi * 2]
    mov edi, r10d
    sub edi, eax
    imul edi, edi                       ; dy^2
    push rsi
    xor esi, esi                        ; s
.sx:
    lea eax, [ecx * 8 + 1]
    lea eax, [eax + esi * 2]
    neg eax
    add eax, r10d
    imul eax, eax
    add eax, edi
    cmp eax, r9d
    ja .sx_next
    inc r8d
.sx_next:
    inc esi
    cmp esi, 4
    jb .sx
    pop rsi
    inc esi
    cmp esi, 4
    jb .sy
    shl r8d, 4                          ; 0..256
    cmp r8d, 255
    jbe .store
    mov r8d, 255
.store:
    mov [r11], r8b
    inc r11
    inc ecx
    jmp .col
.row_next:
    inc edx
    jmp .row
.made:
    lea rdi, [rr_cache_p]
    mov rax, [rdi + rbx * 8]
.out:
    pop r12
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

; rr_walk(RDI x, RSI y, RDX w, RCX h, R10 = radius, R11D = corners, RBX = a
; span function): calls it for each part of each row of the rounded
; rectangle within the clip, with RDI = the first pixel, RCX = how many,
; RSI = their coverage (0: all), RDX = its step, R12 = x, R13 = y of the
; first. R8, R9, R14 and R15 reach it as they were. The span function may
; clobber RAX, RCX, RDX, RSI, RDI, R10, R11. Preserves all.
rr_walk:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    push r13
    push rbp
    sub rsp, 72
    mov [rsp], rdi                      ; x
    mov [rsp + 8], rsi                  ; y
    mov [rsp + 16], rdx                 ; w
    mov [rsp + 24], rcx                 ; h
    mov [rsp + 32], r11                 ; corners
    mov rax, rdx                        ; the radius: at most half of either side
    shr rax, 1
    cmp r10, rax
    jbe .r_w
    mov r10, rax
.r_w:
    mov rax, rcx
    shr rax, 1
    cmp r10, rax
    jbe .r_h
    mov r10, rax
.r_h:
    cmp r10, RR_MAX
    jbe .r_max
    mov r10d, RR_MAX
.r_max:
    mov [rsp + 40], r10                 ; r
    xor eax, eax
    test r10, r10
    jz .masked
    mov ecx, r10d
    call rr_mask
    test rax, rax
    jnz .masked
    mov qword [rsp + 40], 0             ; no memory: square corners
.masked:
    mov [rsp + 48], rax                 ; the mask
    mov r13, [rsp + 8]                  ; rows within the clip
    cmp r13, [tg_cy0]
    jge .y0
    mov r13, [tg_cy0]
.y0:
    mov rax, [rsp + 8]
    add rax, [rsp + 24]
    cmp rax, [tg_cy1]
    jle .y1
    mov rax, [tg_cy1]
.y1:
    mov [rsp + 56], rax                 ; the row after the last
.row:
    cmp r13, [rsp + 56]
    jge .done
    xor ebp, ebp                        ; this row's left mask row, right
    mov qword [rsp + 64], 0
    mov rcx, [rsp + 40]
    test rcx, rcx
    jz .parts
    mov rax, r13                        ; from the top
    sub rax, [rsp + 8]
    cmp rax, rcx
    jae .bottom
    imul rax, rcx
    add rax, [rsp + 48]
    test dword [rsp + 32], RC_TL
    jz .tr
    mov rbp, rax
.tr:
    test dword [rsp + 32], RC_TR
    jz .parts
    mov [rsp + 64], rax
    jmp .parts
.bottom:
    mov rax, [rsp + 8]                  ; from the bottom
    add rax, [rsp + 24]
    dec rax
    sub rax, r13
    cmp rax, rcx
    jae .parts
    imul rax, rcx
    add rax, [rsp + 48]
    test dword [rsp + 32], RC_BL
    jz .br
    mov rbp, rax
.br:
    test dword [rsp + 32], RC_BR
    jz .parts
    mov [rsp + 64], rax
.parts:
    ; left part: [x, x + r), the middle, then the right part [x + w - r, x + w)
    mov rdi, [rsp]
    mov rcx, [rsp + 40]
    mov rsi, rbp
    mov edx, 1
    call .part
    mov rdi, [rsp]
    add rdi, [rsp + 40]
    mov rcx, [rsp + 16]
    sub rcx, [rsp + 40]
    sub rcx, [rsp + 40]
    xor esi, esi
    mov edx, 1
    call .part
    mov rdi, [rsp]
    add rdi, [rsp + 16]
    mov rcx, [rsp + 40]
    sub rdi, rcx
    mov rsi, [rsp + 64]
    mov rdx, -1
    test rsi, rsi
    jz .right
    add rsi, rcx                        ; mirrored: its last byte first
    dec rsi
.right:
    call .part
    inc r13
    jmp .row
.done:
    add rsp, 72
    pop rbp
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
; RDI = x, RCX = pixels, RSI = coverage or 0, RDX = step: clipped, then
; the span function. (Inside: [rsp + 8] is rr_walk's frame.)
.part:
    test rcx, rcx
    jle .part_out
    lea rax, [rdi + rcx]                ; the end, clipped
    cmp rax, [tg_cx1]
    jle .part_end
    mov rax, [tg_cx1]
.part_end:
    mov r10, [tg_cx0]
    sub r10, rdi                        ; pixels left of the clip
    jle .part_start
    add rdi, r10
    test rsi, rsi
    jz .part_start
    imul r10, rdx
    add rsi, r10
.part_start:
    sub rax, rdi
    jle .part_out
    mov rcx, rax
    mov r12, rdi
    mov rax, r13
    imul rax, [tg_pitch]
    lea rdi, [rax + rdi * 4]
    add rdi, [tg_ptr]
    call rbx
.part_out:
    ret

; span_rr: rr_walk's span for a color: R8D color, R9D alpha
span_rr:
    test rsi, rsi
    jz span_fill
    jmp span_mask

; gfx_rrect(RDI x, RSI y, RDX w, RCX h, R8D color, R9D alpha 0..256,
; R10 = radius, R11D = corners RC_*)
gfx_rrect:
    test r9d, r9d
    jz .out
    push rbx
    lea rbx, [span_rr]
    call rr_walk
    pop rbx
.out:
    ret

; gfx_circle(RDI x, RSI y of its box, RDX diameter, R8D color, R9D alpha)
gfx_circle:
    push rcx
    push r10
    push r11
    mov rcx, rdx
    mov r10, rdx
    shr r10, 1
    mov r11d, RC_ALL
    call gfx_rrect
    pop r11
    pop r10
    pop rcx
    ret

; gfx_rring(RDI x, RSI y, RDX w, RCX h, R8D color, R9D alpha, R10 = radius):
; a line one pixel wide just inside the rounded rectangle's edge
gfx_rring:
    test r9d, r9d
    jz .none
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rax, r14                        ; the radius, as gfx_rrect has it
    shr rax, 1
    cmp r10, rax
    jbe .r_w
    mov r10, rax
.r_w:
    mov rax, r15
    shr rax, 1
    cmp r10, rax
    jbe .r_h
    mov r10, rax
.r_h:
    cmp r10, RR_MAX
    jbe .r_ok
    mov r10d, RR_MAX
.r_ok:
    mov rbx, r10
    ; the straight parts
    lea rdi, [r12 + rbx]                ; top
    mov rsi, r13
    mov rdx, r14
    sub rdx, rbx
    sub rdx, rbx
    mov ecx, 1
    call gfx_fill_a
    lea rsi, [r13 + r15 - 1]            ; bottom
    call gfx_fill_a
    mov rdi, r12                        ; left
    lea rsi, [r13 + rbx]
    mov edx, 1
    mov rcx, r15
    sub rcx, rbx
    sub rcx, rbx
    call gfx_fill_a
    lea rdi, [r12 + r14 - 1]            ; right
    call gfx_fill_a
    test rbx, rbx
    jz .out
    ; the corners: each pixel's coverage by radius r, less that by r - 1
    ; a pixel in (inside the line)
    mov ecx, ebx
    call rr_mask
    test rax, rax
    jz .out
    mov rsi, rax
    xor edi, edi
    cmp rbx, 1
    jbe .inner
    lea ecx, [ebx - 1]
    call rr_mask
    mov rdi, rax
.inner:
    mov rax, rbx                        ; build the ring's corner, r x r
    imul rax, rbx
    cmp rax, RING_MAX
    ja .out
    lea r11, [ring_corner]
    xor edx, edx                        ; j
.rj:
    cmp rdx, rbx
    jae .ring_made
    xor ecx, ecx                        ; i
.ri:
    cmp rcx, rbx
    jae .rj_next
    mov rax, rdx
    imul rax, rbx
    add rax, rcx
    movzx eax, byte [rsi + rax]
    test rdi, rdi
    jz .ri_store
    test rcx, rcx
    jz .ri_store
    test rdx, rdx
    jz .ri_store
    push rdx
    push rcx
    dec rdx
    dec rcx
    lea r10, [rbx - 1]
    imul rdx, r10
    add rdx, rcx
    movzx ecx, byte [rdi + rdx]
    sub eax, ecx
    jns .ri_pos
    xor eax, eax
.ri_pos:
    pop rcx
    pop rdx
.ri_store:
    mov [r11], al
    inc r11
    inc rcx
    jmp .ri
.rj_next:
    inc rdx
    jmp .rj
.ring_made:
    lea r10, [ring_corner]              ; the four corners, mirrored
    mov rdi, r12
    mov rsi, r13
    mov r11, 1
    mov rdx, rbx
    call .corner
    lea rdi, [r12 + r14]
    sub rdi, rbx
    mov rsi, r13
    mov r11, -1
    call .corner
    mov rdi, r12
    lea rsi, [r13 + r15]
    sub rsi, rbx
    mov r11, 1
    neg rdx
    call .corner
    lea rdi, [r12 + r14]
    sub rdi, rbx
    lea rsi, [r13 + r15]
    sub rsi, rbx
    mov r11, -1
    call .corner
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.none:
    ret
; RDI, RSI = the block's top left, RBX = r, R11 = x step (+1: as made, -1:
; mirrored), RDX = y step (+r or -r). R10 = the ring corner.
.corner:
    push rdx
    push r12
    push r13
    push r14
    push r15
    mov r14, rdx                        ; y step
    mov r15, r10                        ; this block's first row of coverage
    test r11, r11
    jns .c_x
    lea r15, [r15 + rbx - 1]
.c_x:
    test r14, r14
    jns .c_y
    mov rax, rbx
    dec rax
    imul rax, rbx
    add r15, rax
.c_y:
    xor r13d, r13d                      ; row
.c_row:
    cmp r13, rbx
    jae .c_done
    lea rax, [rsi + r13]
    cmp rax, [tg_cy0]
    jl .c_next
    cmp rax, [tg_cy1]
    jge .c_next
    push rsi
    push rdi
    xor r12d, r12d                      ; column
.c_col:
    cmp r12, rbx
    jae .c_cols
    lea rcx, [rdi + r12]
    cmp rcx, [tg_cx0]
    jl .c_col_next
    cmp rcx, [tg_cx1]
    jge .c_col_next
    mov rdx, r12
    imul rdx, r11
    add rdx, r15
    movzx edx, byte [rdx]
    test edx, edx
    jz .c_col_next
    push rdi
    push rsi
    push rbx
    push r10
    push r11
    mov rdi, rcx
    lea rsi, [rsi + r13]
    imul rsi, [tg_pitch]
    lea rdi, [rsi + rdi * 4]
    add rdi, [tg_ptr]
    mov eax, edx                        ; coverage times alpha
    shr edx, 7
    add eax, edx
    imul eax, r9d
    shr eax, 8
    jz .c_px_done
    mov ebx, 256
    sub ebx, eax
    mov edx, eax
    mov eax, [rdi]
    MIX eax, r8d, edx, ebx, r10d, r11d
    mov [rdi], eax
.c_px_done:
    pop r11
    pop r10
    pop rbx
    pop rsi
    pop rdi
.c_col_next:
    inc r12
    jmp .c_col
.c_cols:
    pop rdi
    pop rsi
.c_next:
    add r15, r14
    inc r13
    jmp .c_row
.c_done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdx
    ret

; -----------------------------------------------------------------------------
;  Shadows
; -----------------------------------------------------------------------------

; shadow_build(RDI = a style with SH_R, SH_M, SH_OY and SH_A set): its
; tables, made again. -> CF if there is no memory. Preserves all.
shadow_build:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    mov rbx, rdi
    mov rdi, [rbx + SH_CORNER]
    call kfree
    mov rdi, [rbx + SH_EDGE]
    call kfree
    mov qword [rbx + SH_CORNER], 0
    mov qword [rbx + SH_EDGE], 0
    mov rax, [rbx + SH_M]
    test rax, rax
    jz .fail
    imul rax, rax, 15                   ; l: past 0.15 m inside, it is all
    add rax, 99                         ; there
    xor edx, edx
    mov ecx, 100
    div rcx
    inc rax
    cmp rax, [rbx + SH_R]               ; (within the corners)
    jbe .l_ok
    mov rax, [rbx + SH_R]
.l_ok:
    mov [rbx + SH_L], rax
    mov rdi, [rbx + SH_M]
    add rdi, rax
    call kmalloc
    test rax, rax
    jz .fail
    mov [rbx + SH_EDGE], rax
    mov r12, [rbx + SH_M]               ; n = m + r
    add r12, [rbx + SH_R]
    mov rdi, r12
    imul rdi, r12
    call kmalloc
    test rax, rax
    jz .fail
    mov [rbx + SH_CORNER], rax
    ; the edge: pixel k from the outer edge is m - k - 0.5 outside (less
    ; than 0: inside)
    mov r9, [rbx + SH_M]
    add r9, [rbx + SH_L]
    xor ecx, ecx
.edge:
    cmp rcx, r9
    jae .corner
    mov rax, [rbx + SH_M]
    sub rax, rcx
    cvtsi2ss xmm0, rax
    subss xmm0, [f_half]
    call .falloff
    mov rdx, [rbx + SH_EDGE]
    mov [rdx + rcx], al
    inc rcx
    jmp .edge
.corner:
    ; the top left block: the corner's centre is at (n, n); a pixel's
    ; distance past the edge is its distance from there, less r
    mov r8, [rbx + SH_CORNER]
    xor edx, edx                        ; j
.cj:
    cmp rdx, r12
    jae .done
    xor ecx, ecx                        ; i
.ci:
    cmp rcx, r12
    jae .cj_next
    mov rax, r12
    sub rax, rcx
    cvtsi2ss xmm0, rax
    subss xmm0, [f_half]
    mulss xmm0, xmm0
    mov rax, r12
    sub rax, rdx
    cvtsi2ss xmm1, rax
    subss xmm1, [f_half]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    cvtsi2ss xmm1, qword [rbx + SH_R]
    subss xmm0, xmm1
    call .falloff
    mov [r8], al
    inc r8
    inc rcx
    jmp .ci
.cj_next:
    inc rdx
    jmp .cj
.done:
    clc
    jmp .out
.fail:
    stc
.out:
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; XMM0 = how far past the edge (pixels) -> AL = 0..255: the shadow there,
; (1 - t)^3 of its darkest, t going 0 to 1 from 0.15 m inside to m outside
.falloff:
    cvtsi2ss xmm1, qword [rbx + SH_M]
    movss xmm2, xmm1
    mulss xmm2, [f_0_15]
    addss xmm0, xmm2                    ; d + 0.15 m
    mulss xmm1, [f_1_15]
    divss xmm0, xmm1                    ; / 1.15 m
    xorps xmm1, xmm1
    maxss xmm0, xmm1
    minss xmm0, [f_one]
    movss xmm1, [f_one]
    subss xmm1, xmm0
    movss xmm0, xmm1
    mulss xmm0, xmm1
    mulss xmm0, xmm1
    mov eax, [rbx + SH_A]
    cvtsi2ss xmm1, eax
    mulss xmm0, xmm1
    mulss xmm0, [f_255_256]
    cvtss2si eax, xmm0
    cmp eax, 255
    jbe .f_ok
    mov eax, 255
.f_ok:
    ret

; gfx_shadow(RDI x, RSI y, RDX w, RCX h of what casts it, R8 = its style):
; the shadow around it (not under it: that is covered)
gfx_shadow:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbx, r8
    cmp qword [rbx + SH_CORNER], 0
    je .out
    mov r12, rdi                        ; the shape: x, y + oy, w, h
    mov r13, rsi
    add r13, [rbx + SH_OY]
    mov r14, rdx
    mov r15, rcx
    mov rax, [rbx + SH_R]
    add rax, rax
    cmp r14, rax
    jb .out
    cmp r15, rax
    jb .out
    mov r11, [rbx + SH_M]               ; m
    mov rax, r11
    add rax, [rbx + SH_R]
    mov [sh_n], rax                     ; n = m + r: a corner block's side
    dec rax
    mov [sh_n1], rax                    ; n - 1
    imul rax, [sh_n]
    mov [sh_last_row], rax              ; (n - 1) * n
    ; the corners: x, y, then the byte for that pixel and the steps
    mov rdi, r12                        ; top left
    sub rdi, r11
    mov rsi, r13
    sub rsi, r11
    mov r8, [rbx + SH_CORNER]
    mov r9, 1
    mov r10, [sh_n]
    call .corner
    mov rdi, r12                        ; top right
    add rdi, r14
    sub rdi, [rbx + SH_R]
    mov rsi, r13
    sub rsi, r11
    mov r8, [rbx + SH_CORNER]
    add r8, [sh_n1]
    mov r9, -1
    mov r10, [sh_n]
    call .corner
    mov rdi, r12                        ; bottom left
    sub rdi, r11
    mov rsi, r13
    add rsi, r15
    sub rsi, [rbx + SH_R]
    mov r8, [rbx + SH_CORNER]
    add r8, [sh_last_row]
    mov r9, 1
    mov r10, [sh_n]
    neg r10
    call .corner
    mov rdi, r12                        ; bottom right
    add rdi, r14
    sub rdi, [rbx + SH_R]
    mov rsi, r13
    add rsi, r15
    sub rsi, [rbx + SH_R]
    mov r8, [rbx + SH_CORNER]
    add r8, [sh_last_row]
    add r8, [sh_n1]
    mov r9, -1
    mov r10, [sh_n]
    neg r10
    call .corner
    ; the edges between them, from m outside to l inside
    mov r11, [rbx + SH_M]
    add r11, [rbx + SH_L]               ; m + l
    mov rdi, r12                        ; top
    add rdi, [rbx + SH_R]
    mov rsi, r13
    sub rsi, [rbx + SH_M]
    mov rdx, r14
    sub rdx, [rbx + SH_R]
    sub rdx, [rbx + SH_R]
    mov rcx, r11
    mov r8, [rbx + SH_EDGE]
    xor r9d, r9d
    mov r10d, 1
    call shade_table
    mov rdi, r12                        ; bottom
    add rdi, [rbx + SH_R]
    mov rsi, r13
    add rsi, r15
    sub rsi, [rbx + SH_L]
    mov rdx, r14
    sub rdx, [rbx + SH_R]
    sub rdx, [rbx + SH_R]
    mov rcx, r11
    mov r8, [rbx + SH_EDGE]
    lea r8, [r8 + r11 - 1]
    xor r9d, r9d
    mov r10, -1
    call shade_table
    mov rdi, r12                        ; left
    sub rdi, [rbx + SH_M]
    mov rsi, r13
    add rsi, [rbx + SH_R]
    mov rdx, r11
    mov rcx, r15
    sub rcx, [rbx + SH_R]
    sub rcx, [rbx + SH_R]
    mov r8, [rbx + SH_EDGE]
    mov r9d, 1
    xor r10d, r10d
    call shade_table
    mov rdi, r12                        ; right
    add rdi, r14
    sub rdi, [rbx + SH_L]
    mov rsi, r13
    add rsi, [rbx + SH_R]
    mov rdx, r11
    mov rcx, r15
    sub rcx, [rbx + SH_R]
    sub rcx, [rbx + SH_R]
    mov r8, [rbx + SH_EDGE]
    lea r8, [r8 + r11 - 1]
    mov r9, -1
    xor r10d, r10d
    call shade_table
    ; inside, l from the edges: all of the shadow, where the caster (opaque,
    ; round at its corners, drawn after) leaves it showing. Each row: the
    ; shadow's inside here is between the bands at the sides (wide), or
    ; between the corners; the caster covers none of the row (below it),
    ; between its corners, or all of it.
    mov r8d, 0xFF000000
    mov r9d, [rbx + SH_A]
    mov r10, [rbx + SH_R]
    mov r11, [rbx + SH_L]
    mov rsi, r13
    add rsi, r11
.in_row:
    lea rax, [r13 + r15]
    sub rax, r11
    cmp rsi, rax
    jge .out
    xor ecx, ecx                        ; ECX = 1: wide
    mov rax, rsi
    sub rax, r13
    cmp rax, r10
    jl .shape_mid
    lea rax, [r13 + r15]
    sub rax, rsi
    cmp rax, r10
    jle .shape_mid
    inc ecx
.shape_mid:
    mov rax, rsi                        ; the row in the caster
    sub rax, r13
    add rax, [rbx + SH_OY]
    cmp rax, r15
    jge .uncovered
    cmp rax, r10
    jl .covered_mid
    mov rdx, r15
    sub rdx, rax
    cmp rdx, r10
    jle .covered_mid
    mov rax, r15                        ; all covered down to its corners
    sub rax, r10
    sub rax, [rbx + SH_OY]
    add rax, r13
    cmp rax, rsi
    jle .in_next
    mov rsi, rax
    jmp .in_row
.covered_mid:
    test ecx, ecx                       ; beside its corners, if wide
    jz .in_next
    lea rdi, [r12 + r11]
    mov rdx, r10
    sub rdx, r11
    jle .in_next
    push rcx
    mov ecx, 1
    call gfx_fill_a
    lea rdi, [r12 + r14]
    sub rdi, r10
    call gfx_fill_a
    pop rcx
    jmp .in_next
.uncovered:
    lea rdi, [r12 + r11]                ; wide: from l in
    mov rdx, r14
    sub rdx, r11
    sub rdx, r11
    test ecx, ecx
    jnz .row_span
    lea rdi, [r12 + r10]                ; between the corners
    mov rdx, r14
    sub rdx, r10
    sub rdx, r10
.row_span:
    mov ecx, 1
    call gfx_fill_a
.in_next:
    inc rsi
    jmp .in_row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
; a corner block, n x n
.corner:
    mov rdx, [sh_n]
    mov rcx, rdx
    jmp shade_table

; shade_table(RDI x, RSI y, RDX w, RCX h, R8 = the byte for (x, y), R9 = the
; step to the next column's, R10 = to the next row's): black over each
; pixel at its byte (0..255). Clobbers RAX, RCX, RDX, RSI, RDI, R8.
shade_table:
    push rbx
    push r11
    push r12
    push r13
    push r14
    push r15
    test rdx, rdx
    jle .out
    test rcx, rcx
    jle .out
    mov rax, [tg_cx0]                   ; clip: skipped columns, rows
    sub rax, rdi
    jle .left
    add rdi, rax
    sub rdx, rax
    jle .out
    imul rax, r9
    add r8, rax
.left:
    mov rax, [tg_cy0]
    sub rax, rsi
    jle .top
    add rsi, rax
    sub rcx, rax
    jle .out
    imul rax, r10
    add r8, rax
.top:
    lea rax, [rdi + rdx]
    sub rax, [tg_cx1]
    jle .right
    sub rdx, rax
    jle .out
.right:
    lea rax, [rsi + rcx]
    sub rax, [tg_cy1]
    jle .bottom
    sub rcx, rax
    jle .out
.bottom:
    mov rax, rsi
    imul rax, [tg_pitch]
    lea r12, [rax + rdi * 4]
    add r12, [tg_ptr]
    mov r13, rcx                        ; rows
    mov r14, rdx                        ; columns
.row:
    mov rdi, r12
    mov r15, r8
    mov rcx, r14
.px:
    movzx eax, byte [r15]
    add r15, r9
    test eax, eax
    jz .next
    mov ebx, eax
    shr ebx, 7
    add ebx, eax
    imul esi, ebx, 255                  ; black over it: the alpha it adds
    shr esi, 8                          ; (an image's fourth byte)
    shl esi, 24
    neg ebx
    add ebx, 256                        ; what is left of the pixel
    mov eax, [rdi]
    SCALE eax, ebx, r11d
    add eax, esi
    mov [rdi], eax
.next:
    add rdi, 4
    dec rcx
    jnz .px
    add r12, [tg_pitch]
    add r8, r10
    dec r13
    jnz .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Frosted glass: what is behind a rounded rectangle, blurred
; -----------------------------------------------------------------------------

; gfx_frost(RDI x, RSI y, RDX w, RCX h, R8 = corner radius, R9 = blur radius
; 1..64): the target behind it blurred (three box blurs of that radius:
; what is within 3 R9 of it must be drawn already)
gfx_frost:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov [frost_r], r8
    mov [frost_b], r9
    lea rax, [r9 + r9 * 2]              ; the margin it reads
    mov rdi, r12                        ; the area copied: the target's, not
    sub rdi, rax                        ; the clip's
    mov rsi, r13
    sub rsi, rax
    lea rdx, [r14 + rax * 2]
    lea rcx, [r15 + rax * 2]
    test rdi, rdi
    jns .x0
    add rdx, rdi
    xor edi, edi
.x0:
    test rsi, rsi
    jns .y0
    add rcx, rsi
    xor esi, esi
.y0:
    lea rax, [rdi + rdx]
    sub rax, [tg_w]
    jle .x1
    sub rdx, rax
.x1:
    lea rax, [rsi + rcx]
    sub rax, [tg_h]
    jle .y1
    sub rcx, rax
.y1:
    test rdx, rdx
    jle .out
    test rcx, rcx
    jle .out
    cmp rdx, BLUR_W
    ja .out
    mov [frost_x], rdi
    mov [frost_y], rsi
    push rdi
    push rsi
    lea rdi, [frost_a]
    mov rsi, rdx
    mov rdx, rcx
    call sf_size
    jc .no_memory
    lea rdi, [frost_b_sf]
    mov rsi, [frost_a + SF_W]
    mov rdx, [frost_a + SF_H]
    call sf_size
.no_memory:
    pop rsi
    pop rdi
    jc .out
    ; copy it in
    mov rax, rsi
    imul rax, [tg_pitch]
    lea rsi, [rax + rdi * 4]
    add rsi, [tg_ptr]
    mov rdi, [frost_a + SF_PTR]
    mov rbx, [frost_a + SF_H]
.copy:
    push rsi
    push rdi
    mov rcx, [frost_a + SF_W]
    rep movsd
    pop rdi
    pop rsi
    add rsi, [tg_pitch]
    add rdi, [frost_a + SF_PITCH]
    dec rbx
    jnz .copy
    ; blur: across, then down into the other surface, three times
    mov rbx, 3
.pass:
    lea rdi, [frost_a]
    mov rsi, [frost_b]
    call blur_rows
    lea rdi, [frost_a]
    lea rsi, [frost_b_sf]
    mov rdx, [frost_b]
    call blur_cols
    lea rdi, [frost_b_sf]               ; the result back into a
    lea rsi, [frost_a]
    call sf_swap
    dec rbx
    jnz .pass
    ; and out, through the rounded rectangle
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov rcx, r15
    mov r10, [frost_r]
    mov r11d, RC_ALL
    lea rbx, [span_frost]
    call rr_walk
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; span_frost: rr_walk's span: frost_a's pixels at R12, R13
span_frost:
    push rbx
    push r8
    push r9
    push r12
    push r13
    push r14
    push r15
    mov rax, r13                        ; the source pixel
    sub rax, [frost_y]
    imul rax, [frost_a + SF_PITCH]
    mov rbx, r12
    sub rbx, [frost_x]
    lea rbx, [rax + rbx * 4]
    add rbx, [frost_a + SF_PTR]
.px:
    mov r8d, [rbx]
    add rbx, 4
    test rsi, rsi
    jz .all
    movzx eax, byte [rsi]
    add rsi, rdx
    test eax, eax
    jz .next
    mov r9d, eax
    shr r9d, 7
    add r9d, eax
    cmp r9d, 256
    jae .all
    mov r14d, 256
    sub r14d, r9d
    mov eax, [rdi]
    MIX eax, r8d, r9d, r14d, r10d, r11d
    mov [rdi], eax
    jmp .next
.all:
    mov [rdi], r8d
.next:
    add rdi, 4
    dec rcx
    jnz .px
    pop r15
    pop r14
    pop r13
    pop r12
    pop r9
    pop r8
    pop rbx
    ret

; sf_swap(RDI, RSI = two surfaces): they trade places. Preserves all.
sf_swap:
    push rax
    push rcx
    push rdx
    xor ecx, ecx
.each:
    mov rax, [rdi + rcx]
    mov rdx, [rsi + rcx]
    mov [rdi + rcx], rdx
    mov [rsi + rcx], rax
    add ecx, 8
    cmp ecx, SF_SIZE
    jb .each
    pop rdx
    pop rcx
    pop rax
    ret

; blur_rows(RDI = a surface, RSI = radius): each row, a box blur across, in
; place. Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
blur_rows:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, [rdi + SF_PTR]
    mov r13, [rdi + SF_H]
    mov r14, [rdi + SF_W]
    mov r15, [rdi + SF_PITCH]
    mov rbp, rsi                        ; b
    lea rcx, [rsi * 2 + 1]
    mov eax, 65536                      ; 1 / (2b + 1), 16.16
    xor edx, edx
    div ecx
    mov r11d, eax
.row:
    ; the row into blur_line with b copies of each end beside it
    lea rdi, [blur_line]
    mov eax, [r12]
    mov rcx, rbp
    rep stosd
    mov rsi, r12
    mov rcx, r14
    rep movsd
    mov eax, [rsi - 4]
    mov rcx, rbp
    rep stosd
    ; sums of the first window: 2b + 1 pixels
    xor r8d, r8d                        ; blue
    xor r9d, r9d                        ; green
    xor r10d, r10d                      ; red
    lea rsi, [blur_line]
    lea rcx, [rbp * 2 + 1]
.sum:
    lodsd
    movzx edx, al
    add r8d, edx
    movzx edx, ah
    add r9d, edx
    shr eax, 16
    movzx edx, al
    add r10d, edx
    dec rcx
    jnz .sum
    lea rsi, [blur_line]                ; leaving the window
    mov rdi, r12
    mov rbx, r14
.out_px:
    mov eax, r10d                       ; the pixel: the sums / (2b + 1)
    imul eax, r11d
    shr eax, 16
    shl eax, 16
    mov edx, r9d
    imul edx, r11d
    shr edx, 16
    shl edx, 8
    or eax, edx
    mov edx, r8d
    imul edx, r11d
    shr edx, 16
    or eax, edx
    stosd
    mov eax, [rsi + rbp * 8 + 4]        ; the pixel coming in: 2b + 1 on
    movzx edx, al
    add r8d, edx
    movzx edx, ah
    add r9d, edx
    shr eax, 16
    movzx edx, al
    add r10d, edx
    lodsd                               ; and the one going out
    movzx edx, al
    sub r8d, edx
    movzx edx, ah
    sub r9d, edx
    shr eax, 16
    movzx edx, al
    sub r10d, edx
    dec rbx
    jnz .out_px
    add r12, r15
    dec r13
    jnz .row
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; blur_cols(RDI = from, RSI = to (the same size), RDX = radius): a box
; blur down each column. Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
blur_cols:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, [rdi + SF_PTR]             ; from
    mov r13, [rsi + SF_PTR]             ; to
    mov r14, [rdi + SF_W]
    mov r15, [rdi + SF_PITCH]
    mov rbx, [rdi + SF_H]
    mov rbp, rdx                        ; b
    lea rcx, [rdx * 2 + 1]
    mov eax, 65536
    xor edx, edx
    div ecx
    mov [blur_inv], eax
    ; the sums for row 0: row 0 counted b + 1 times, rows 1..b once
    lea rdi, [blur_sums]
    xor eax, eax
    mov rcx, r14
    shl rcx, 2
    rep stosd
    mov r8, -1                          ; k: row -b..b, clamped
    sub r8, rbp
.init:
    inc r8
    cmp r8, rbp
    jg .rows
    mov rax, r8
    call .clamp
    imul rax, r15
    add rax, r12
    lea rdi, [blur_sums]
    mov rcx, r14
.init_px:
    mov edx, [rax]
    add rax, 4
    movzx esi, dl
    add [rdi], esi
    movzx esi, dh
    add [rdi + 4], esi
    shr edx, 16
    movzx esi, dl
    add [rdi + 8], esi
    add rdi, 16
    dec rcx
    jnz .init_px
    jmp .init
.rows:
    xor r8d, r8d                        ; y
.row:
    cmp r8, rbx
    jae .done
    mov rax, r8                         ; in: row y + b + 1; out: row y - b
    add rax, rbp
    inc rax
    call .clamp
    imul rax, r15
    lea r9, [r12 + rax]
    mov rax, r8
    sub rax, rbp
    call .clamp
    imul rax, r15
    lea r10, [r12 + rax]
    mov rdi, r8
    imul rdi, r15
    add rdi, r13
    lea rsi, [blur_sums]
    mov rcx, r14
    mov r11d, [blur_inv]
.px:
    mov eax, [rsi + 8]                  ; out: the sums / (2b + 1)
    imul eax, r11d
    shr eax, 16
    shl eax, 16
    mov edx, [rsi + 4]
    imul edx, r11d
    shr edx, 16
    shl edx, 8
    or eax, edx
    mov edx, [rsi]
    imul edx, r11d
    shr edx, 16
    or eax, edx
    mov [rdi], eax
    add rdi, 4
    mov eax, [r9]                       ; then the next window
    add r9, 4
    mov edx, [r10]
    add r10, 4
    push rcx
    movzx ecx, al
    add [rsi], ecx
    movzx ecx, dl
    sub [rsi], ecx
    movzx ecx, ah
    add [rsi + 4], ecx
    movzx ecx, dh
    sub [rsi + 4], ecx
    shr eax, 16
    shr edx, 16
    movzx ecx, al
    add [rsi + 8], ecx
    movzx ecx, dl
    sub [rsi + 8], ecx
    pop rcx
    add rsi, 16
    dec rcx
    jnz .px
    inc r8
    jmp .row
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
; RAX = a row -> clamped to 0..h-1
.clamp:
    test rax, rax
    jns .c_low
    xor eax, eax
.c_low:
    cmp rax, rbx
    jl .c_high
    lea rax, [rbx - 1]
.c_high:
    ret

; -----------------------------------------------------------------------------
;  Gradients
; -----------------------------------------------------------------------------

; gfx_vgrad(RDI x, RSI y, RDX w, RCX h, R8D top color, R9D bottom color):
; from one to the other, top to bottom, dithered so it shows no bands
gfx_vgrad:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r14, rsi                        ; the first row and how many there are
    mov r15, rcx
    call gfx_clip
    jz .out
    mov r12, rdi
    mov r13, rsi
    mov [grad_w], rdx
    mov [grad_h], rcx
.row:
    ; t = (row - top) / (rows - 1), 16.16
    mov rax, r13
    sub rax, r14
    shl rax, 16
    mov rcx, r15
    dec rcx
    jnz .t
    inc rcx
.t:
    xor edx, edx
    div rcx
    mov r10, rax
    ; each channel at t, 8.8: c0 * 256 + (c1 - c0) * t / 256
    lea rdi, [grad_c]
    mov ecx, 16
.channel:
    mov eax, r8d
    shr eax, cl
    and eax, 0xFF
    mov edx, r9d
    shr edx, cl
    and edx, 0xFF
    sub edx, eax
    movsxd rdx, edx
    imul rdx, r10
    sar rdx, 8
    shl eax, 8
    add rax, rdx
    mov [rdi], eax
    add rdi, 4
    sub ecx, 8
    jns .channel
    ; the row, each pixel with its dither
    mov rax, r13
    imul rax, [tg_pitch]
    lea rdi, [rax + r12 * 4]
    add rdi, [tg_ptr]
    mov rcx, [grad_w]
    mov rbx, r12
    mov r11, r13
    and r11, 3
    shl r11, 2
    lea r10, [bayer4]
    add r10, r11                        ; this row of the pattern
.px:
    mov r11, rbx
    and r11, 3
    movzx r11d, byte [r10 + r11]
    mov eax, [grad_c]                   ; red
    add eax, r11d
    shr eax, 8
    cmp eax, 255
    jbe .r
    mov eax, 255
.r:
    shl eax, 16
    mov edx, [grad_c + 4]               ; green
    add edx, r11d
    shr edx, 8
    cmp edx, 255
    jbe .g
    mov edx, 255
.g:
    shl edx, 8
    or eax, edx
    mov edx, [grad_c + 8]               ; blue
    add edx, r11d
    shr edx, 8
    cmp edx, 255
    jbe .b
    mov edx, 255
.b:
    or eax, edx
    stosd
    inc rbx
    dec rcx
    jnz .px
    inc r13
    dec qword [grad_h]
    jnz .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Polygons
; -----------------------------------------------------------------------------

; gfx_poly(RDI = points: dword x, dword y in 1/256 pixels, ESI = how many
; (3..POLY_MAX), EDX = color, ECX = alpha): filled, even-odd, each pixel
; sampled 4 x 4 times
POLY_MAX        equ 64
gfx_poly:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    cmp esi, 3
    jb .out
    cmp esi, POLY_MAX
    ja .out
    mov [poly_pts], rdi
    mov [poly_n], rsi
    mov [poly_color], edx
    mov [poly_alpha], ecx
    ; the box around it, in pixels, within the clip
    mov r8d, 0x7FFFFFFF                 ; min x, min y, max x, max y
    mov r9d, 0x7FFFFFFF
    mov r10d, 0x80000000
    mov r11d, 0x80000000
    xor ecx, ecx
.box:
    mov eax, [rdi + rcx * 8]
    cmp eax, r8d
    cmovl r8d, eax
    cmp eax, r10d
    cmovg r10d, eax
    mov eax, [rdi + rcx * 8 + 4]
    cmp eax, r9d
    cmovl r9d, eax
    cmp eax, r11d
    cmovg r11d, eax
    inc ecx
    cmp ecx, esi
    jb .box
    sar r8d, 8
    sar r9d, 8
    add r10d, 255
    sar r10d, 8
    add r11d, 255
    sar r11d, 8
    movsxd rdi, r8d
    movsxd rsi, r9d
    movsxd rdx, r10d
    sub rdx, rdi
    movsxd rcx, r11d
    sub rcx, rsi
    call gfx_clip
    jz .out
    cmp rdx, BLUR_W
    ja .out
    mov [poly_x0], rdi
    mov [poly_w], rdx
    mov r12, rsi                        ; the row
    lea r13, [rsi + rcx]                ; the row after the last
.row:
    cmp r12, r13
    jge .out
    lea rdi, [poly_cov]                 ; samples in each pixel of the row
    xor eax, eax
    mov rcx, [poly_w]
    rep stosw
    xor r14d, r14d                      ; sub-row 0..3
.sub:
    ; sample y, 1/256 pixels: row + (t + 0.5) / 4
    mov r15, r12
    shl r15, 8
    mov rax, r14
    shl rax, 6
    lea r15, [r15 + rax + 32]
    ; where each edge crosses it
    xor ebx, ebx                        ; crossings
    mov rsi, [poly_pts]
    mov rcx, [poly_n]
    xor r8d, r8d                        ; edge i: from point i to i + 1
.edge:
    mov r9, r8
    inc r9
    cmp r9, rcx
    jb .next_pt
    xor r9d, r9d
.next_pt:
    movsxd r10, dword [rsi + r8 * 8 + 4]      ; y0
    movsxd r11, dword [rsi + r9 * 8 + 4]      ; y1
    cmp r10, r11
    je .edge_next                       ; flat
    mov rax, r10                        ; y0 <= y < y1, either way round
    cmp rax, r11
    jl .ordered
    mov rax, r11
    mov rdx, r10
    jmp .range
.ordered:
    mov rdx, r11
.range:
    cmp r15, rax
    jl .edge_next
    cmp r15, rdx
    jge .edge_next
    ; x = x0 + (y - y0) * (x1 - x0) / (y1 - y0)
    movsxd rax, dword [rsi + r9 * 8]
    movsxd rdx, dword [rsi + r8 * 8]
    sub rax, rdx
    mov rdx, r15
    sub rdx, r10
    imul rax, rdx
    sub r11, r10
    cqo
    idiv r11
    movsxd rdx, dword [rsi + r8 * 8]
    add rax, rdx
    lea rdx, [poly_x]
    mov [rdx + rbx * 8], rax
    inc ebx
.edge_next:
    inc r8
    cmp r8, rcx
    jb .edge
    ; sorted, then each pair a span
    lea rsi, [poly_x]
    mov ecx, 1
.sort:
    cmp ecx, ebx
    jae .sorted
    mov rax, [rsi + rcx * 8]
    mov edx, ecx
.sort_in:
    test edx, edx
    jz .sort_put
    cmp [rsi + rdx * 8 - 8], rax
    jle .sort_put
    mov r8, [rsi + rdx * 8 - 8]
    mov [rsi + rdx * 8], r8
    dec edx
    jmp .sort_in
.sort_put:
    mov [rsi + rdx * 8], rax
    inc ecx
    jmp .sort
.sorted:
    xor ecx, ecx
.span:
    lea eax, [ecx + 1]
    cmp eax, ebx
    jae .sub_next
    mov r8, [rsi + rcx * 8]             ; xa, xb: 1/256 pixels
    mov r9, [rsi + rcx * 8 + 8]
    ; the samples in [xa, xb): sample k is at k * 64 + 32
    sub r8, 32 - 63                     ; first: ceil((xa - 32) / 64)
    sar r8, 6
    sub r9, 32 - 63
    sar r9, 6
    mov rax, [poly_x0]                  ; within the row's pixels
    shl rax, 2
    sub r8, rax
    sub r9, rax
    test r8, r8
    jns .sa
    xor r8d, r8d
.sa:
    mov rax, [poly_w]
    shl rax, 2
    cmp r9, rax
    jle .sb
    mov r9, rax
.sb:
    lea rdx, [poly_cov]
.sample:
    cmp r8, r9
    jge .span_next
    mov rax, r8
    shr rax, 2
    inc word [rdx + rax * 2]
    inc r8
    jmp .sample
.span_next:
    add ecx, 2
    jmp .span
.sub_next:
    inc r14
    cmp r14, 4
    jb .sub
    ; the row, at each pixel's coverage (samples * 16)
    mov rax, r12
    imul rax, [tg_pitch]
    mov rdi, [poly_x0]
    lea rdi, [rax + rdi * 4]
    add rdi, [tg_ptr]
    lea rsi, [poly_cov]
    mov rcx, [poly_w]
    mov r8d, [poly_color]
.px:
    movzx eax, word [rsi]
    add rsi, 2
    test eax, eax
    jz .px_next
    shl eax, 4
    imul eax, [poly_alpha]
    shr eax, 8
    jz .px_next
    mov ebx, 256
    sub ebx, eax
    mov edx, eax
    mov eax, [rdi]
    MIX eax, r8d, edx, ebx, r10d, r11d
    mov [rdi], eax
.px_next:
    add rdi, 4
    dec rcx
    jnz .px
    inc r12
    jmp .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Images with alpha: surfaces of B,G,R,A, premultiplied
; -----------------------------------------------------------------------------

; img_new(RDI = a surface, RSI = width, RDX = height) -> CF if no memory;
; else it is that size and clear. Preserves all but RAX.
img_new:
    call sf_size
    jc .out
    push rcx
    push rdi
    mov rcx, [rdi + SF_W]
    imul rcx, [rdi + SF_H]
    mov rdi, [rdi + SF_PTR]
    xor eax, eax
    rep stosd
    pop rdi
    pop rcx
    clc
.out:
    ret

; gfx_image(RDI x, RSI y, RDX = the image, R8D = alpha 0..256 for all of it)
gfx_image:
    test r8d, r8d
    jz .none
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdx
    mov r12, rdi
    mov r13, rsi
    mov rdx, [rbx + SF_W]
    mov rcx, [rbx + SF_H]
    call gfx_clip
    jz .out
    mov rax, rsi                        ; the image's first pixel
    sub rax, r13
    imul rax, [rbx + SF_PITCH]
    mov r9, rdi
    sub r9, r12
    lea r9, [rax + r9 * 4]
    add r9, [rbx + SF_PTR]
    mov rax, rsi                        ; the target's
    imul rax, [tg_pitch]
    lea r10, [rax + rdi * 4]
    add r10, [tg_ptr]
    mov r14, rcx                        ; rows
    mov r15, rdx                        ; columns
.row:
    mov rsi, r9
    mov rdi, r10
    mov rcx, r15
.px:
    lodsd
    test eax, eax
    jz .next
    cmp r8d, 256
    jae .scaled
    SCALE eax, r8d, edx
.scaled:
    mov edx, eax                        ; what is left of the pixel under it
    shr edx, 24
    mov r11d, edx
    shr r11d, 7
    add edx, r11d
    neg edx
    add edx, 256
    mov r11d, [rdi]
    push rax
    SCALE r11d, edx, eax
    pop rax
    add eax, r11d
    mov [rdi], eax
.next:
    add rdi, 4
    dec rcx
    jnz .px
    add r9, [rbx + SF_PITCH]
    add r10, [tg_pitch]
    dec r14
    jnz .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
.none:
    ret

; -----------------------------------------------------------------------------
;  The proportional font. A font is a weight and a size: UF_<WEIGHT> *
;  UF_SIZES + the size's index. Text is the kernel's: ASCII, and from 128
;  the console font's symbols.
; -----------------------------------------------------------------------------

; uf_size(EDI = pixels, ESI = weight) -> EAX = the font nearest that size.
; Preserves others.
uf_size:
    push rcx
    push rdx
    push r8
    push r9
    lea r8, [uf_size_px]
    xor ecx, ecx
    xor eax, eax                        ; best so far
    mov r9d, 0x7FFFFFFF
.each:
    cmp ecx, UF_SIZES
    jae .done
    movzx edx, byte [r8 + rcx]
    sub edx, edi
    jns .abs
    neg edx
.abs:
    cmp edx, r9d
    jae .next
    mov r9d, edx
    mov eax, ecx
.next:
    inc ecx
    jmp .each
.done:
    imul esi, esi, UF_SIZES
    add eax, esi
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; uf_metrics(EDI = font) -> RAX = its UFT_* entry. Preserves others.
uf_metrics:
    mov eax, edi
    imul eax, eax, UFT_SIZE
    push rdx
    lea rdx, [uf_fonts]
    add rax, rdx
    pop rdx
    ret

; uf_glyph(EAX = a byte, R10 = the font's glyph table) -> RAX = its entry.
; Clobbers RDX.
uf_glyph:
    movzx eax, al
    lea rdx, [uf_byte]
    movzx eax, word [rdx + rax * 2]
    imul eax, eax, UG_SIZE
    add rax, r10
    ret

; uf_width(RDI = text, ESI = font) -> RAX = its width in pixels. Preserves
; others.
uf_width:
    push rcx
    push rdx
    push rdi
    push r10
    push r11
    mov r10d, esi
    imul r10d, r10d, UFT_SIZE
    lea rax, [uf_fonts]
    mov r10, [rax + r10]
    lea rax, [uifont_data]
    add r10, rax
    xor r11d, r11d                      ; 1/64 pixels
.each:
    movzx eax, byte [rdi]
    test eax, eax
    jz .done
    inc rdi
    cmp eax, 32
    jb .each
    call uf_glyph
    movzx eax, word [rax + UG_ADV]
    add r11, rax
    jmp .each
.done:
    lea rax, [r11 + 63]
    shr rax, 6
    pop r11
    pop r10
    pop rdi
    pop rdx
    pop rcx
    ret

; uf_text(RDI x, RSI baseline, RDX text, ECX color, R8D font) -> RAX = x
; after it. Preserves others.
uf_text:
    push r9
    mov r9, 0x7FFFFFFF
    call uf_text_max
    pop r9
    ret

; uf_text_max(..., R9 = the widest it may be): what does not fit is cut, and
; an ellipsis says so
uf_text_max:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15d, ecx
    mov rdi, rdx                        ; does it fit?
    mov esi, r8d
    call uf_width
    mov rbx, -1                         ; bytes to draw: all
    cmp rax, r9
    jbe .fits
    mov al, G_ELLIPSIS                  ; no: as many as fit with "..."
    mov byte [uf_dots], al
    mov byte [uf_dots + 1], 0
    lea rdi, [uf_dots]
    call uf_width
    sub r9, rax
    jle .nothing
    mov r10d, r8d
    imul r10d, r10d, UFT_SIZE
    lea rax, [uf_fonts]
    mov r10, [rax + r10]
    lea rax, [uifont_data]
    add r10, rax
    xor ebx, ebx
    xor r11d, r11d
    shl r9, 6
.fit:
    movzx eax, byte [r14 + rbx]
    test eax, eax
    jz .fits
    call uf_glyph
    movzx eax, word [rax + UG_ADV]
    add r11, rax
    cmp r11, r9
    ja .cut
    inc rbx
    jmp .fit
.nothing:
    xor ebx, ebx
.cut:
    mov byte [uf_cut], 1
    jmp .draw
.fits:
    mov byte [uf_cut], 0
.draw:
    mov rdi, r12
    mov rsi, r13
    mov rdx, r14
    mov ecx, r15d
    mov r9, rbx
    call uf_draw
    cmp byte [uf_cut], 0
    je .out
    mov rdi, rax
    lea rdx, [uf_dots]
    mov r9, -1
    call uf_draw
.out:
    pop r15
    pop r14
    pop r13
    pop r12
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

; uf_draw(RDI x, RSI baseline, RDX text, ECX color, R8D font, R9 = most
; bytes) -> RAX = x after it. Clobbers RDX, R9-R11.
uf_draw:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov r10d, r8d
    imul r10d, r10d, UFT_SIZE
    lea rax, [uf_fonts]
    mov r10, [rax + r10]
    lea rax, [uifont_data]
    add r10, rax
    mov r12, rdi
    shl r12, 6                          ; the pen, 1/64 pixels
    mov r13, rsi
    mov r14, rdx
    mov r15, r9
    mov [uf_color], ecx
.each:
    test r15, r15
    jz .done
    dec r15
    movzx eax, byte [r14]
    test eax, eax
    jz .done
    inc r14
    cmp eax, 32
    jb .each
    call uf_glyph
    mov rbx, rax
    movzx ecx, byte [rbx + UG_W]
    test ecx, ecx
    jz .advance
    lea rdi, [r12 + 32]
    sar rdi, 6
    movsx rax, byte [rbx + UG_LEFT]
    add rdi, rax
    movsx rax, byte [rbx + UG_TOP]
    mov rsi, r13
    sub rsi, rax
    push r10
    call uf_blit
    pop r10
.advance:
    movzx eax, word [rbx + UG_ADV]
    add r12, rax
    jmp .each
.done:
    lea rax, [r12 + 32]
    sar rax, 6
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; uf_blit(RDI x, RSI y, RBX = a glyph): its coverage in uf_color. Clobbers
; RAX, RCX, RDX, RSI, RDI, R9-R11.
uf_blit:
    push r12
    push r13
    push r14
    push r15
    push rbp
    movzx r12d, byte [rbx + UG_W]
    movzx r13d, byte [rbx + UG_H]
    mov r14d, [rbx + UG_DATA]
    lea rax, [uifont_data]
    add r14, rax                        ; its coverage
    mov rdx, r12
    mov rcx, r13
    push rdi
    push rsi
    call gfx_clip
    pop r9                              ; the glyph's own top left
    pop r10
    jz .out
    mov rax, rsi                        ; skip what the clip took
    sub rax, r9
    imul rax, r12
    add r14, rax
    mov rax, rdi
    sub rax, r10
    add r14, rax
    mov rax, rsi
    imul rax, [tg_pitch]
    lea r15, [rax + rdi * 4]
    add r15, [tg_ptr]
    mov r13, rcx                        ; rows
    mov rbp, rdx                        ; columns
    mov r11d, [uf_color]
.row:
    mov rsi, r14
    mov rdi, r15
    mov rcx, rbp
.px:
    movzx eax, byte [rsi]
    inc rsi
    test eax, eax
    jz .next
    cmp eax, 255
    je .solid
    mov edx, eax
    shr edx, 7
    add eax, edx
    push rcx
    push rbx
    mov ecx, eax
    mov ebx, 256
    sub ebx, eax
    mov eax, [rdi]
    MIX eax, r11d, ecx, ebx, r9d, r10d
    mov [rdi], eax
    pop rbx
    pop rcx
    jmp .next
.solid:
    mov [rdi], r11d
.next:
    add rdi, 4
    dec rcx
    jnz .px
    add r14, r12
    add r15, [tg_pitch]
    dec r13
    jnz .row
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    ret

section .rodata
align 4
f_half:         dd 0.5
f_one:          dd 1.0
f_0_15:         dd 0.15
f_1_15:         dd 1.15
f_255_256:      dd 0.99609375           ; 255 / 256
bayer4:         db 8, 136, 40, 168, 200, 72, 232, 104, 56, 184, 24, 152, 248, 120, 216, 88
%include "gen/uifont.inc"
align 64
uifont_data:    incbin "gen/uifont.bin"
uifont_end:

section .bss
alignb 8
rr_cache_r:     resd RR_CACHE
rr_cache_next:  resd 1
rr_cache_p:     resq RR_CACHE
RING_MAX        equ 64 * 64
ring_corner:    resb RING_MAX
alignb 8
frost_r:        resq 1
frost_b:        resq 1
frost_x:        resq 1
frost_y:        resq 1
frost_a:        resb SF_SIZE            ; the area, then blurred
frost_b_sf:     resb SF_SIZE            ; and the other half of each pass
blur_inv:       resd 1
alignb 16
blur_sums:      resd BLUR_W * 4
blur_line:      resd BLUR_W + 2 * 64 + 4
grad_w:         resq 1
grad_h:         resq 1
grad_c:         resd 4
poly_pts:       resq 1
poly_n:         resq 1
poly_color:     resd 1
poly_alpha:     resd 1
poly_x0:        resq 1
poly_w:         resq 1
poly_x:         resq POLY_MAX
poly_cov:       resw BLUR_W
uf_color:       resd 1
sh_n:           resq 1
sh_n1:          resq 1
sh_last_row:    resq 1
uf_cut:         resb 1
uf_dots:        resb 2
