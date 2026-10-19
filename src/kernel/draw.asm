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

BLUR_W          equ 4096                ; widest a frosted area may be, at half size

; a pane of frosted glass (glass_make, glass_paint): its blur, kept
GL_X            equ 0                   ; the rectangle it covers
GL_Y            equ 8
GL_W            equ 16                  ; (0: none)
GL_H            equ 24
GL_B            equ 32                  ; the blur's radius, 1..64
GL_M            equ 40                  ; how far around it a change reaches it
GL_STALE        equ 48                  ; byte: what is behind it changed,
GL_FRESH        equ 49                  ; byte: to be made as it is composed
GL_TAKEN        equ 50                  ; byte: GL_STALE, as desk_update took it
GL_SF           equ 56                  ; SF_SIZE: its pixels, blurred
GL_SIZE         equ GL_SF + SF_SIZE

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
;  Frosted glass: what is behind a rounded rectangle, blurred. A pane (GL_*)
;  keeps its blur until what is behind it changes, so drawing it again is a
;  copy. The blur is made at half the size: each 2x2 block of what is behind
;  (and three blurs' reach around it) averaged, three box blurs across and
;  down there, then back to full size between the half size's pixels.
; -----------------------------------------------------------------------------

; glass_make(RDI = a pane): what the target holds behind its rectangle,
; blurred into its pixels (GL_SF). What is within GL_B * 3 of it must be
; drawn already. Preserves all.
glass_make:
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
    mov rbx, rdi
    mov rax, [rbx + GL_X]               ; the pane within the target
    test rax, rax
    jns .px0
    add [rbx + GL_W], rax
    mov qword [rbx + GL_X], 0
.px0:
    mov rax, [rbx + GL_Y]
    test rax, rax
    jns .py0
    add [rbx + GL_H], rax
    mov qword [rbx + GL_Y], 0
.py0:
    mov rax, [tg_w]
    sub rax, [rbx + GL_X]
    cmp [rbx + GL_W], rax
    jle .px1
    mov [rbx + GL_W], rax
.px1:
    mov rax, [tg_h]
    sub rax, [rbx + GL_Y]
    cmp [rbx + GL_H], rax
    jle .py1
    mov [rbx + GL_H], rax
.py1:
    cmp qword [rbx + GL_W], 0
    jle .out
    cmp qword [rbx + GL_H], 0
    jle .out
    mov rax, [rbx + GL_B]               ; the area read: three blurs' reach
    lea rax, [rax + rax * 2]            ; around, within the target
    mov r12, [rbx + GL_X]
    sub r12, rax
    jns .x0
    xor r12d, r12d
.x0:
    mov r13, [rbx + GL_Y]
    sub r13, rax
    jns .y0
    xor r13d, r13d
.y0:
    mov r14, [rbx + GL_X]
    add r14, [rbx + GL_W]
    add r14, rax
    cmp r14, [tg_w]
    jle .x1
    mov r14, [tg_w]
.x1:
    mov r15, [rbx + GL_Y]
    add r15, [rbx + GL_H]
    add r15, rax
    cmp r15, [tg_h]
    jle .y1
    mov r15, [tg_h]
.y1:
    sub r14, r12
    jle .out
    sub r15, r13
    jle .out
    mov [gl_ax], r12
    mov [gl_ay], r13
    mov [gl_aw], r14
    mov [gl_ah], r15
    lea rax, [r14 + 1]                  ; half the size, rounded up; rows
    shr rax, 1                          ; padded to four pixels
    cmp rax, BLUR_W
    ja .out
    mov [gl_hw], rax
    lea rcx, [r15 + 1]
    shr rcx, 1
    mov [gl_hh], rcx
    lea rsi, [rax + 3]
    and rsi, -4
    mov rdx, rcx
    lea rdi, [frost_a]
    call sf_size
    jc .out
    lea rdi, [frost_b_sf]
    call sf_size
    jc .out
    mov rax, [gl_hw]                    ; blurred: the pixels that are
    mov [frost_a + SF_W], rax           ; there (the pitch keeps the rest)
    mov [frost_b_sf + SF_W], rax
    lea rdi, [rbx + GL_SF]              ; and the result, its size
    mov rsi, [rbx + GL_W]
    mov rdx, [rbx + GL_H]
    call sf_size
    jc .out
    call gl_down
    mov r12, [rbx + GL_B]               ; half the radius, at half the size
    shr r12, 1
    jnz .radius
    inc r12d
.radius:
    mov r13d, 3
.pass:
    lea rdi, [frost_a]
    mov rsi, r12
    call blur_rows
    lea rdi, [frost_a]
    lea rsi, [frost_b_sf]
    mov rdx, r12
    call blur_cols
    lea rdi, [frost_b_sf]               ; the result back into a
    lea rsi, [frost_a]
    call sf_swap
    dec r13d
    jnz .pass
    mov rdi, rbx
    call gl_up
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

; gl_down: the target's area (gl_ax, gl_ay, gl_aw, gl_ah) at half its size
; into frost_a, each pixel the mean of a 2x2 block (at the right and the
; bottom, of what is there). Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
gl_down:
    xor r8d, r8d                        ; its rows
.row:
    cmp r8, [gl_hh]
    jae .done
    lea rax, [r8 + r8]                  ; the two rows it is made of
    lea rcx, [rax + 1]
    cmp rcx, [gl_ah]
    jb .two
    mov rcx, rax
.two:
    add rax, [gl_ay]
    imul rax, [tg_pitch]
    mov r9, [gl_ax]
    lea r9, [rax + r9 * 4]
    add r9, [tg_ptr]
    add rcx, [gl_ay]
    imul rcx, [tg_pitch]
    mov r10, [gl_ax]
    lea r10, [rcx + r10 * 4]
    add r10, [tg_ptr]
    mov r11, r8
    imul r11, [frost_a + SF_PITCH]
    add r11, [frost_a + SF_PTR]
    mov rdx, [gl_aw]                    ; whole blocks
    shr rdx, 1
    jz .last
.block:
    movq xmm0, [r9]
    movq xmm1, [r10]
    pavgb xmm0, xmm1                    ; down,
    pshuflw xmm1, xmm0, 0xEE
    pavgb xmm0, xmm1                    ; and across
    movd [r11], xmm0
    add r9, 8
    add r10, 8
    add r11, 4
    dec rdx
    jnz .block
.last:
    test byte [gl_aw], 1                ; a column left alone
    jz .next
    movd xmm0, [r9]
    movd xmm1, [r10]
    pavgb xmm0, xmm1
    movd [r11], xmm0
.next:
    inc r8
    jmp .row
.done:
    ret

; gl_up(RDI = a pane): frost_a, the area blurred at half its size, back at
; full size into the pane's pixels: each between the half size's two
; nearest pixels, down and across (a quarter of one, three of the other).
; Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
gl_up:
    push rbx
    push r12
    push r13
    mov rbx, rdi
    mov r12, [gl_hw]                    ; groups of four, across
    add r12, 3
    shr r12, 2
    xor r8d, r8d                        ; its rows
.row:
    cmp r8, [rbx + GL_H]
    jae .done
    mov rax, [rbx + GL_Y]               ; where in the half size: row k, and
    add rax, r8                         ; above (even) or below (odd)
    sub rax, [gl_ay]
    mov rcx, rax
    shr rcx, 1
    mov rdx, rcx
    test al, 1
    jnz .below
    dec rdx
    jns .rows
    xor edx, edx
    jmp .rows
.below:
    inc rdx
    cmp rdx, [gl_hh]
    jb .rows
    dec rdx
.rows:
    imul rcx, [frost_a + SF_PITCH]
    add rcx, [frost_a + SF_PTR]
    imul rdx, [frost_a + SF_PITCH]
    add rdx, [frost_a + SF_PTR]
    lea rdi, [gl_line + 4]              ; the row between them, a pixel to
    mov r9, r12                         ; spare at either end
.down:
    movdqu xmm0, [rcx]
    movdqu xmm1, [rdx]
    pavgb xmm1, xmm0
    pavgb xmm1, xmm0
    movdqu [rdi], xmm1
    add rcx, 16
    add rdx, 16
    add rdi, 16
    dec r9
    jnz .down
    lea rsi, [gl_line + 4]
    mov eax, [rsi]                      ; the spares: the end pixels again
    mov [rsi - 4], eax
    mov rax, [gl_hw]
    mov ecx, [rsi + rax * 4 - 4]
    mov [rsi + rax * 4], ecx
    mov rdi, r8                         ; then across, into the pane's row
    imul rdi, [rbx + GL_SF + SF_PITCH]
    add rdi, [rbx + GL_SF + SF_PTR]
    mov r10, [rbx + GL_X]               ; R10: where in the half size, doubled
    sub r10, [gl_ax]
    mov rcx, [rbx + GL_W]
    test r10b, 1                        ; odd first: its own
    jz .pairs
    mov rax, r10
    shr rax, 1
    movd xmm0, [rsi + rax * 4]
    movd xmm1, [rsi + rax * 4 + 4]
    pavgb xmm1, xmm0
    pavgb xmm1, xmm0
    movd [rdi], xmm1
    add rdi, 4
    inc r10
    dec rcx
.pairs:
    cmp rcx, 2
    jb .single
    mov rax, r10                        ; even then odd: from k - 1, k, k + 1
    shr rax, 1
    movd xmm0, [rsi + rax * 4]
    movd xmm1, [rsi + rax * 4 - 4]
    movd xmm2, [rsi + rax * 4 + 4]
    pavgb xmm1, xmm0
    pavgb xmm1, xmm0
    pavgb xmm2, xmm0
    pavgb xmm2, xmm0
    punpckldq xmm1, xmm2
    movq [rdi], xmm1
    add rdi, 8
    add r10, 2
    sub rcx, 2
    jmp .pairs
.single:
    test rcx, rcx                       ; an even one left
    jz .next
    mov rax, r10
    shr rax, 1
    movd xmm0, [rsi + rax * 4]
    movd xmm1, [rsi + rax * 4 - 4]
    pavgb xmm1, xmm0
    pavgb xmm1, xmm0
    movd [rdi], xmm1
.next:
    inc r8
    jmp .row
.done:
    pop r13
    pop r12
    pop rbx
    ret

; glass_draw(RAX = a pane, RDI x, RSI y, RDX w, RCX h, R10 = corner
; radius): that rounded rectangle, within the pane's, of its pixels
glass_draw:
    push rbx
    push rdi
    push rsi
    push rdx
    push rcx
    push r11
    cmp qword [rax + GL_SF + SF_PTR], 0
    je .out
    mov [gl_cur], rax
    mov rbx, [rax + GL_X]               ; within the pane's pixels
    cmp rdi, rbx
    jge .left
    add rdx, rdi
    sub rdx, rbx
    mov rdi, rbx
.left:
    mov rbx, [rax + GL_Y]
    cmp rsi, rbx
    jge .top
    add rcx, rsi
    sub rcx, rbx
    mov rsi, rbx
.top:
    mov rbx, [rax + GL_X]
    add rbx, [rax + GL_SF + SF_W]
    sub rbx, rdi
    cmp rdx, rbx
    jle .right
    mov rdx, rbx
.right:
    mov rbx, [rax + GL_Y]
    add rbx, [rax + GL_SF + SF_H]
    sub rbx, rsi
    cmp rcx, rbx
    jle .bottom
    mov rcx, rbx
.bottom:
    test rdx, rdx
    jle .out
    test rcx, rcx
    jle .out
    mov r11d, RC_ALL
    lea rbx, [span_glass]
    call rr_walk
.out:
    pop r11
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    pop rbx
    ret

; span_glass: rr_walk's span: the pane gl_cur's pixels at R12, R13
span_glass:
    push rbx
    push r8
    push r9
    push r14
    mov r8, [gl_cur]
    mov rax, r13                        ; the source pixel
    sub rax, [r8 + GL_Y]
    imul rax, [r8 + GL_SF + SF_PITCH]
    mov rbx, r12
    sub rbx, [r8 + GL_X]
    lea rbx, [rax + rbx * 4]
    add rbx, [r8 + GL_SF + SF_PTR]
    test rsi, rsi
    jnz .px
    mov rsi, rbx                        ; all of each: a copy
    rep movsd
    jmp .out
.px:
    mov r8d, [rbx]
    add rbx, 4
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
.out:
    pop r14
    pop r9
    pop r8
    pop rbx
    ret

; gl_touch(RAX = a pane, RDI x, RSI y, RDX w, RCX h): if the rectangle
; meets what the pane's blur reads (GL_M around it), what is behind it
; changed (GL_STALE, until desk_update takes it). Under dmg_lock. Preserves
; all but the flags.
gl_touch:
    cmp qword [rax + GL_W], 0
    jle .none
    push r8
    push r9
    mov r8, [rax + GL_X]                ; what it reads: its left, against
    sub r8, [rax + GL_M]                ; the rectangle's right
    lea r9, [rdi + rdx]
    cmp r9, r8
    jle .out
    add r8, [rax + GL_W]                ; its right
    add r8, [rax + GL_M]
    add r8, [rax + GL_M]
    cmp rdi, r8
    jge .out
    mov r8, [rax + GL_Y]                ; its top
    sub r8, [rax + GL_M]
    lea r9, [rsi + rcx]
    cmp r9, r8
    jle .out
    add r8, [rax + GL_H]                ; its bottom
    add r8, [rax + GL_M]
    add r8, [rax + GL_M]
    cmp rsi, r8
    jge .out
    mov byte [rax + GL_STALE], 1
.out:
    pop r9
    pop r8
.none:
    ret

; gl_grow(RAX = a pane, RDI x, RSI y, RDX w, RCX h) -> the rectangle grown
; to all the pane reads, if what is behind it changed (GL_TAKEN) and the
; rectangle meets that (then GL_FRESH: it is made again as this is
; composed). Preserves others.
gl_grow:
    cmp byte [rax + GL_TAKEN], 0
    je .out
    cmp qword [rax + GL_W], 0
    jle .out
    push r8
    push r9
    push r10
    push r11
    mov r8, [rax + GL_X]                ; all it reads: R8..R10, R9..R11
    sub r8, [rax + GL_M]
    mov r9, [rax + GL_Y]
    sub r9, [rax + GL_M]
    mov r10, [rax + GL_X]
    add r10, [rax + GL_W]
    add r10, [rax + GL_M]
    mov r11, [rax + GL_Y]
    add r11, [rax + GL_H]
    add r11, [rax + GL_M]
    add rdx, rdi                        ; does it meet it?
    add rcx, rsi
    cmp rdx, r8
    jle .apart
    cmp rdi, r10
    jge .apart
    cmp rcx, r9
    jle .apart
    cmp rsi, r11
    jge .apart
    cmp rdi, r8                         ; the union
    jle .x0
    mov rdi, r8
.x0:
    cmp rsi, r9
    jle .y0
    mov rsi, r9
.y0:
    cmp rdx, r10
    jge .x1
    mov rdx, r10
.x1:
    cmp rcx, r11
    jge .y1
    mov rcx, r11
.y1:
    mov byte [rax + GL_TAKEN], 0        ; made again as this is composed
    mov byte [rax + GL_FRESH], 1
.apart:
    sub rdx, rdi
    sub rcx, rsi
    push rax
    call gfx_clip_screen_signed
    pop rax
    pop r11
    pop r10
    pop r9
    pop r8
.out:
    ret

; glass_paint(RAX = a pane, RDI x, RSI y, RDX w, RCX h, R10 = corner
; radius): the rounded rectangle, of the pane's blur: made again first if
; the back buffer behind it is new (GL_FRESH)
glass_paint:
    cmp byte [rax + GL_FRESH], 0
    je glass_draw
    mov byte [rax + GL_FRESH], 0
    push rdi
    mov rdi, rax
    call glass_make
    pop rdi
    jmp glass_draw

; gfx_frost(RDI x, RSI y, RDX w, RCX h, R8 = corner radius, R9 = blur radius
; 1..64): the target behind it blurred, once (what is within 3 R9 of it must
; be drawn already)
gfx_frost:
    push rax
    push r10
    lea rax, [frost_gl]
    mov [rax + GL_X], rdi
    mov [rax + GL_Y], rsi
    mov [rax + GL_W], rdx
    mov [rax + GL_H], rcx
    mov [rax + GL_B], r9
    push rdi
    mov rdi, rax
    call glass_make
    pop rdi
    mov r10, r8
    call glass_draw
    pop r10
    pop rax
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

; blur_rows(RDI = a surface, RSI = radius): each row's first SF_W pixels,
; a box blur across, in place, the four bytes of a pixel at once.
; Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
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
    lea rcx, [rsi * 2 + 1]              ; 1 / (2b + 1), 0.16; and half of
    mov eax, 65536                      ; 2b + 1, to round
    xor edx, edx
    div ecx
    movd xmm7, eax
    pshuflw xmm7, xmm7, 0
    mov eax, ecx
    shr eax, 1
    movd xmm5, eax
    pshuflw xmm5, xmm5, 0
    pxor xmm6, xmm6
.row:
    ; the row into blur_line with b copies of each end beside it (and one
    ; more, read past the last)
    lea rdi, [blur_line]
    mov eax, [r12]
    mov rcx, rbp
    rep stosd
    mov rsi, r12
    mov rcx, r14
    rep movsd
    mov eax, [rsi - 4]
    lea rcx, [rbp + 1]
    rep stosd
    pxor xmm0, xmm0                     ; the sums of the first window
    lea rsi, [blur_line]
    lea rcx, [rbp * 2 + 1]
.sum:
    movd xmm1, [rsi]
    punpcklbw xmm1, xmm6
    paddw xmm0, xmm1
    add rsi, 4
    dec rcx
    jnz .sum
    lea rsi, [blur_line]                ; leaving the window
    lea r8, [rsi + rbp * 8 + 4]         ; coming in: 2b + 1 on
    mov rdi, r12
    mov rcx, r14
.px:
    movdqa xmm2, xmm0                   ; the pixel: the sums / (2b + 1)
    paddw xmm2, xmm5
    pmulhuw xmm2, xmm7
    packuswb xmm2, xmm2
    movd [rdi], xmm2
    movd xmm1, [r8]
    punpcklbw xmm1, xmm6
    paddw xmm0, xmm1
    movd xmm1, [rsi]
    punpcklbw xmm1, xmm6
    psubw xmm0, xmm1
    add rdi, 4
    add rsi, 4
    add r8, 4
    dec rcx
    jnz .px
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
; blur down each column, four columns at a time (SF_W rounded up to four:
; the pitch holds them). Clobbers RAX, RCX, RDX, RSI, RDI, R8-R11.
blur_cols:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12, [rdi + SF_PTR]             ; from
    mov r13, [rsi + SF_PTR]             ; to
    mov r14, [rdi + SF_W]               ; groups of four columns
    add r14, 3
    shr r14, 2
    mov r15, [rdi + SF_PITCH]
    mov rbx, [rdi + SF_H]
    mov rbp, rdx                        ; b
    lea rcx, [rdx * 2 + 1]
    mov eax, 65536
    xor edx, edx
    div ecx
    movd xmm7, eax
    pshuflw xmm7, xmm7, 0
    punpcklqdq xmm7, xmm7
    mov eax, ecx
    shr eax, 1
    movd xmm5, eax
    pshuflw xmm5, xmm5, 0
    punpcklqdq xmm5, xmm5
    pxor xmm6, xmm6
    ; the sums for row 0: row 0 counted b + 1 times, rows 1..b once
    lea rdi, [blur_sums]
    xor eax, eax
    mov rcx, r14
    shl rcx, 2
    rep stosq
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
    movdqu xmm0, [rax]
    movdqa xmm1, xmm0
    punpcklbw xmm0, xmm6
    punpckhbw xmm1, xmm6
    paddw xmm0, [rdi]
    paddw xmm1, [rdi + 16]
    movdqa [rdi], xmm0
    movdqa [rdi + 16], xmm1
    add rax, 16
    add rdi, 32
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
.px:
    movdqa xmm0, [rsi]                  ; out: the sums / (2b + 1)
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, xmm0
    movdqa xmm3, xmm1
    paddw xmm2, xmm5
    paddw xmm3, xmm5
    pmulhuw xmm2, xmm7
    pmulhuw xmm3, xmm7
    packuswb xmm2, xmm3
    movdqu [rdi], xmm2
    movdqu xmm2, [r9]                   ; then the next window
    movdqa xmm3, xmm2
    punpcklbw xmm2, xmm6
    punpckhbw xmm3, xmm6
    paddw xmm0, xmm2
    paddw xmm1, xmm3
    movdqu xmm2, [r10]
    movdqa xmm3, xmm2
    punpcklbw xmm2, xmm6
    punpckhbw xmm3, xmm6
    psubw xmm0, xmm2
    psubw xmm1, xmm3
    movdqa [rsi], xmm0
    movdqa [rsi + 16], xmm1
    add rsi, 32
    add rdi, 16
    add r9, 16
    add r10, 16
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
frost_a:        resb SF_SIZE            ; an area at half size, blurred
frost_b_sf:     resb SF_SIZE            ; and the other half of each pass
frost_gl:       resb GL_SIZE            ; gfx_frost's pane
gl_cur:         resq 1                  ; the pane span_glass draws
gl_ax:          resq 1                  ; the area glass_make reads
gl_ay:          resq 1
gl_aw:          resq 1
gl_ah:          resq 1
gl_hw:          resq 1                  ; at half size
gl_hh:          resq 1
alignb 16
blur_sums:      resd BLUR_W * 4
blur_line:      resd BLUR_W + 2 * 64 + 4
gl_line:        resd BLUR_W + 8
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
