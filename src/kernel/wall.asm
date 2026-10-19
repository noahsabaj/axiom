; =============================================================================
;  wall.asm - the wallpaper: mountains over a lake, made when the desktop
;  starts and again when the look turns light or dark.
;
;  Nothing of it is stored but the numbers at the end of this file. Four
;  ranges of mountains, each a line of value noise (the far two ridged,
;  with snow on them); the light on their faces from the slope of that
;  line, looked up along spurs that wander down from it; mist in the
;  valleys; a lake that mirrors it all; pines at either side. The light
;  look has it by day, under a blue sky and the sun's glow; the dark one
;  at dusk, with stars and the moon.
;
;  Positions are fractions of the screen: u across, v down. Colors are
;  worked on as four floats in an XMM register (B, G, R, 0); each pixel is
;  dithered as it is stored. The rows above the shore are made first, then
;  the lake, which reads them back for its mirror, then the pines over both.
;  The rows are shared out over every CPU (job_run): each its own row at a
;  time, keeping its sums aside in a scratch of its own.
; =============================================================================

; a range of mountains
WLR_SEED         equ 0                   ; dword: its noise's
WLR_FREQ         equ 4                   ; floats from here: its peaks across the screen
WLR_SHIFT        equ 8                   ; where along its noise it starts
WLR_BASE         equ 12                  ; its foot above the shore, as v
WLR_HEIGHT       equ 16                  ; its tallest, as v
WLR_RIDGED       equ 20                  ; dword: sharp ridges, not rounded hills
WLR_OCTS         equ 24                  ; dword: octaves of its noise
WLR_SNOW         equ 28                  ; how much snow (0: none)
WLR_LINE         equ 32                  ; the snow line, as a fraction of the way down
WLR_RAGGED       equ 36                  ; how far the couloirs move that line
WLR_MIST         equ 40                  ; mist at its foot, at most
WLR_SIZE         equ 44
WL_RANGES          equ 4

; a look: day or dusk
WLM_MX           equ 0                   ; the sun or the moon, as u and v
WLM_MY           equ 4
WLM_GLOW_R       equ 8                   ; its glow's reach, as v
WLM_GLOW_A       equ 12                  ; and strength
WLM_DISC_R       equ 16                  ; the moon's radius (0: no disc)
WLM_STARS        equ 20                  ; dword: stars
WLM_STOPS        equ 24                  ; 4 floats: where each sky color is, 0 the top, 1 the shore
WLM_COLORS       equ 40                  ; WLC_COUNT dwords, 0xRRGGBB

WLC_SKY0          equ 0                   ; four
WLC_R0            equ 4                   ; four ranges, far to near
WLC_MIST          equ 8
WLC_SNOW          equ 9
WLC_SNOWSH        equ 10                  ; snow in shade
WLC_WFAR          equ 11                  ; water far, and near
WLC_WNEAR         equ 12
WLC_GLINT         equ 13
WLC_PINE          equ 14
WLC_GLOW          equ 15
WLC_DISC0         equ 16                  ; the moon, its middle and edge
WLC_DISC1         equ 17
WLC_WHITE         equ 18
WLC_COUNT       equ 19

; a pine
WLP_X            equ 0                   ; its middle, as u
WLP_BASE         equ 4                   ; its foot, as v (below the screen)
WLP_H            equ 8                   ; its height, as v
WLP_W            equ 12                  ; its width, as u
WLP_TIERS        equ 16                  ; dword: tiers of branches
WLP_SIZE         equ 20
WL_PINES           equ 8

; %1 += (%2 - %1) * %3: colors, %3 a float. Clobbers XMM6, XMM7.
%macro WL_MIX 3
    movaps xmm7, %2
    subps xmm7, %1
    movss xmm6, %3
    shufps xmm6, xmm6, 0
    mulps xmm7, xmm6
    addps %1, xmm7
%endmacro

; each CPU's scratch while it makes rows (wl_scratch; R15 points at its
; own): what a pixel's or a row's sums keep aside. The names below are
; that scratch's.
WS_WATER         equ 0                   ; this row's water, 4 floats
WS_X             equ 16                  ; the pixel's column
WS_MIRROR        equ 24                  ; the row this one mirrors
WS_T             equ 32                  ; floats from here
WS_F             equ 36
WS_D             equ 40
WS_DV            equ 44
WS_CV            equ 48
WS_DEP           equ 52
WS_BELOW         equ 56
WS_UW            equ 60
WS_LIT           equ 64
WS_FACE          equ 68
WS_MIXW          equ 72
WS_WOBK          equ 76
WS_WY            equ 80
WS_RY            equ 84
WS_GLK           equ 88
WS_SIZE          equ 128                 ; two cache lines: none shared
%define wl_water    r15 + WS_WATER
%define wl_x        r15 + WS_X
%define wl_mirror   r15 + WS_MIRROR
%define wl_t        r15 + WS_T
%define wl_f        r15 + WS_F
%define wl_d        r15 + WS_D
%define wl_dv       r15 + WS_DV
%define wl_cv       r15 + WS_CV
%define wl_dep      r15 + WS_DEP
%define wl_below    r15 + WS_BELOW
%define wl_uw       r15 + WS_UW
%define wl_lit      r15 + WS_LIT
%define wl_face     r15 + WS_FACE
%define wl_mixw     r15 + WS_MIXW
%define wl_wobk     r15 + WS_WOBK
%define wl_wy       r15 + WS_WY
%define wl_ry       r15 + WS_RY
%define wl_glk      r15 + WS_GLK

; a row's job, on whichever CPU took it: RBX, RBP, R12-R15 kept (job_worker
; keeps its own in some); R15 this CPU's scratch, RBP the look
%macro WL_JOB_IN 0
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rax, [gs:PC_INDEX]
    imul rax, rax, WS_SIZE
    lea r15, [wl_scratch]
    add r15, rax
    mov rbp, [wl_look]
%endmacro

%macro WL_JOB_OUT 0
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret
%endmacro

section .text

; -----------------------------------------------------------------------------
;  wall_make: the wallpaper, into wall_sf (the screen's size). Again only if
;  the screen or the look changed since it was made. From the thread 'main'
;  (the desktop's): it shares the rows out with job_run.
; -----------------------------------------------------------------------------
wall_make:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rax, [scr_h]                    ; what it is made for
    shl rax, 20
    or rax, [scr_w]
    movzx ecx, byte [th_mode]
    shl rcx, 40
    or rax, rcx
    mov [wl_want], rax
    cmp rax, [wl_made]
    jne .make
    cmp qword [wall_sf + SF_PTR], 0
    jne .out
.make:
    mov qword [wl_made], 0
    lea rdi, [wall_sf]
    mov rsi, [scr_w]
    mov rdx, [scr_h]
    call sf_size
    jc .out
    mov rax, [scr_w]
    mov [wl_w], rax
    mov rax, [scr_h]
    mov [wl_h], rax
    mov rdi, [wl_w]                     ; 12 floats a column, 4 a row
    imul rdi, rdi, 48
    mov rax, [wl_h]
    shl rax, 4
    add rdi, rax
    call vm_alloc
    test rax, rax
    jz .out
    mov [wl_cols], rax
    lea rbp, [wall_dusk]
    cmp byte [th_mode], TH_LIGHT
    jne .look
    lea rbp, [wall_day]
.look:
    mov [wl_look], rbp
    lea r15, [wl_scratch]               ; a scratch, for what is made here
    call wl_setup
    call wl_columns
    lea rdi, [wl_upper_row]             ; the rows above the shore, on every
    mov rsi, [wl_hz_y]                  ; CPU
    xor edx, edx
    call job_run
    lea rdi, [wl_lake_row]              ; then the lake's, which mirror them
    mov rsi, [wl_h]
    sub rsi, [wl_hz_y]
    xor edx, edx
    call job_run
    lea r15, [wl_scratch]
    call wl_pines                       ; and the pines, over both
    mov rdi, [wl_cols]
    call vm_free
    mov rax, [wl_want]
    mov [wl_made], rax
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; wl_setup: the measures, the palette as floats, each pine's color and the
; sky's color on each row. RBP = the look.
wl_setup:
    cvtsi2ss xmm0, qword [wl_w]
    movss [wl_wf], xmm0
    movss xmm1, [wf_one]
    divss xmm1, xmm0
    movss [wl_invw], xmm1
    cvtsi2ss xmm1, qword [wl_h]
    movss [wl_hf], xmm1
    movss xmm2, [wf_one]
    divss xmm2, xmm1
    movss [wl_invh], xmm2
    divss xmm0, xmm1
    movss [wl_aspect], xmm0             ; W / H: v units across
    movss xmm0, [wl_hf]                 ; a star in each cell of 1/250 the height, or none
    mulss xmm0, [wf_0_004]
    movss [wl_cell], xmm0
    movss xmm1, [wf_one]
    divss xmm1, xmm0
    movss [wl_inv_cell], xmm1
    movss xmm0, [wl_wf]                 ; the pines' ragged edges, in pixels
    mulss xmm0, [wf_0_004]
    movss [wl_jag], xmm0
    mulss xmm0, [wf_half]
    addss xmm0, [wf_one]
    movss [wl_jag_reach], xmm0
    movss xmm0, [wl_hf]                 ; the lake's first row
    mulss xmm0, [wf_hz]
    cvtss2si rax, xmm0
    mov [wl_hz_y], rax
    mov rax, [wl_h]                     ; the shore's line: a row an 800th of the height
    xor edx, edx
    mov ecx, 800
    div rcx
    test rax, rax
    jnz .shore
    inc eax
.shore:
    mov [wl_shore], rax
    mov rax, [wl_w]
    imul rax, rax, 48
    add rax, [wl_cols]
    mov [wl_skyrows], rax
    xor ecx, ecx                        ; the palette
    pxor xmm1, xmm1
    lea rdx, [wl_pal]
.pal:
    movd xmm0, [rbp + WLM_COLORS + rcx * 4]
    punpcklbw xmm0, xmm1
    punpcklwd xmm0, xmm1
    cvtdq2ps xmm0, xmm0
    mov rax, rcx
    shl rax, 4
    movaps [rdx + rax], xmm0
    inc ecx
    cmp ecx, WLC_COUNT
    jb .pal
    xor ecx, ecx                        ; each pine's: the pine color, some a
.shade:                                 ; little toward the mist
    mov eax, ecx
    and eax, 3
    cvtsi2ss xmm0, eax
    mulss xmm0, [wf_0_25]
    movss xmm1, [wf_one]
    subss xmm1, xmm0
    mulss xmm1, [wf_0_06]
    movaps xmm9, [wl_pal + WLC_PINE * 16]
    WL_MIX xmm9, [wl_pal + WLC_MIST * 16], xmm1
    mov rax, rcx
    shl rax, 4
    lea rdx, [wl_shades]
    movaps [rdx + rax], xmm9
    inc ecx
    cmp ecx, WL_PINES
    jb .shade
    xor r13d, r13d                      ; the sky, row by row: between the
.sky:                                   ; two stops around it, smoothly
    cmp r13, [wl_hz_y]
    jae .out
    cvtsi2ss xmm0, r13
    mulss xmm0, [wl_invh]
    divss xmm0, [wf_hz]
    xor ecx, ecx
.seg:
    cmp ecx, 2
    jae .seg_found
    comiss xmm0, [rbp + WLM_STOPS + rcx * 4 + 4]
    jbe .seg_found
    inc ecx
    jmp .seg
.seg_found:
    subss xmm0, [rbp + WLM_STOPS + rcx * 4]
    movss xmm1, [rbp + WLM_STOPS + rcx * 4 + 4]
    subss xmm1, [rbp + WLM_STOPS + rcx * 4]
    divss xmm0, xmm1
    call wl_smooth
    mov rax, rcx
    shl rax, 4
    lea rdx, [wl_pal + WLC_SKY0 * 16]
    add rdx, rax
    movaps xmm9, [rdx]
    WL_MIX xmm9, [rdx + 16], xmm0
    mov rax, r13
    shl rax, 4
    add rax, [wl_skyrows]
    movaps [rax], xmm9
    inc r13
    jmp .sky
.out:
    ret

; wl_columns: for each range and column, its top (as v), the light on the
; face below it, and how steep its edge is (for smooth edges)
wl_columns:
    xor r12d, r12d
.col:
    cmp r12, [wl_w]
    jae .edges
    cvtsi2ss xmm14, r12
    mulss xmm14, [wl_invw]
    xor ebx, ebx
.range:
    imul rsi, rbx, WLR_SIZE
    lea rax, [wall_ranges]
    add rsi, rax
    movss xmm0, xmm14                   ; its top
    mov edx, [rsi + WLR_OCTS]
    call wl_ridge
    mov rax, rbx
    call .at
    movss [rdx], xmm0
    movss xmm0, xmm14                   ; its slope, from the broad shape
    addss xmm0, [wf_0_004]              ; alone (3 octaves): faces turned
    mov edx, 3                          ; left are in the light
    call wl_ridge
    movss [wl_t], xmm0
    movss xmm0, xmm14
    subss xmm0, [wf_0_004]
    mov edx, 3
    call wl_ridge
    movss xmm1, [wl_t]
    subss xmm1, xmm0
    mulss xmm1, [wf_150]                ; 1.2 / (2 * 0.004)
    movss xmm0, [wf_half]
    subss xmm0, xmm1
    call wl_smooth
    lea rax, [rbx + 4]
    call .at
    movss [rdx], xmm0
    inc ebx
    cmp ebx, WL_RANGES
    jb .range
    inc r12
    jmp .col
.edges:                                 ; H / sqrt(1 + rise^2): (v - top) times
    xor ebx, ebx                        ; it is the distance from the edge, in
.e_range:                               ; pixels
    xor r12d, r12d
.e_col:
    cmp r12, [wl_w]
    jae .e_next
    mov rax, r12
    test rax, rax
    jz .e_left
    dec rax
.e_left:
    lea rcx, [r12 + 1]
    cmp rcx, [wl_w]
    jb .e_right
    dec rcx
.e_right:
    mov rdx, rbx
    imul rdx, [wl_w]
    mov rsi, [wl_cols]
    lea rsi, [rsi + rdx * 4]
    movss xmm0, [rsi + rcx * 4]
    subss xmm0, [rsi + rax * 4]
    mulss xmm0, [wf_half]
    mulss xmm0, [wl_hf]
    mulss xmm0, xmm0
    addss xmm0, [wf_one]
    sqrtss xmm0, xmm0
    movss xmm1, [wl_hf]
    divss xmm1, xmm0
    mov rdx, [wl_w]
    shl rdx, 5                          ; 8 arrays on
    add rdx, rsi
    movss [rdx + r12 * 4], xmm1
    inc r12
    jmp .e_col
.e_next:
    inc ebx
    cmp ebx, WL_RANGES
    jb .e_range
    ret
; RAX = which array -> RDX = its entry for column R12
.at:
    imul rax, [wl_w]
    add rax, r12
    mov rdx, [wl_cols]
    lea rdx, [rdx + rax * 4]
    ret

; wl_upper_row(RDI = a row above the shore): a job: the sky, the ranges
; over it
wl_upper_row:
    WL_JOB_IN
    mov r13, rdi
    cvtsi2ss xmm15, r13
    mulss xmm15, [wl_invh]
    mov r14, r13
    imul r14, [wall_sf + SF_PITCH]
    add r14, [wall_sf + SF_PTR]
    xor r12d, r12d
.px:
    cmp r12, [wl_w]
    jae .done
    mov [wl_x], r12
    cvtsi2ss xmm14, r12
    mulss xmm14, [wl_invw]
    mov esi, WL_RANGES - 1                 ; the nearest range over all of the
.whole:                                 ; pixel, or the sky
    call wl_cover
    comiss xmm0, [wf_one]
    jae .range
    dec esi
    jns .whole
    call wl_sky
    xor esi, esi
    jmp .edges
.range:
    call wl_shade
    movaps xmm8, xmm9
    inc esi
.edges:                                 ; and the edges of nearer ones over it
    cmp esi, WL_RANGES
    jae .store
    call wl_cover
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .edge_next
    minss xmm0, [wf_one]
    movss [wl_cv], xmm0
    call wl_shade
    WL_MIX xmm8, xmm9, [wl_cv]
.edge_next:
    inc esi
    jmp .edges
.store:
    call wl_store
    inc r12
    jmp .px
.done:
    WL_JOB_OUT

; wl_cover(ESI = a range) -> XMM0 = how much of the pixel it covers, before
; clamping to 0..1. Clobbers RAX, RDX.
wl_cover:
    mov rax, rsi
    imul rax, [wl_w]
    add rax, [wl_x]
    mov rdx, [wl_cols]
    lea rdx, [rdx + rax * 4]
    movss xmm0, xmm15
    subss xmm0, [rdx]
    mov rax, [wl_w]
    shl rax, 5
    mulss xmm0, [rdx + rax]
    addss xmm0, [wf_half]
    ret

; wl_sky -> XMM8 = the sky at the pixel: its row's color, a star, the glow
; of the sun or the moon, the moon
wl_sky:
    mov rax, r13
    shl rax, 4
    add rax, [wl_skyrows]
    movaps xmm8, [rax]
    cmp dword [rbp + WLM_STARS], 0
    je .glow
    comiss xmm15, [wf_0_45]
    jae .glow
    cvtsi2ss xmm0, r12                  ; its cell
    mulss xmm0, [wl_inv_cell]
    cvttss2si r8d, xmm0
    cvtsi2ss xmm0, r13
    mulss xmm0, [wl_inv_cell]
    cvttss2si r9d, xmm0
    imul eax, r8d, 57
    imul edx, r9d, 131071
    lea r10d, [rax + rdx]
    mov eax, r10d
    mov ecx, 7
    call wl_hash
    comiss xmm0, [wf_0_996]             ; one cell in 250 has a star
    jbe .glow
    subss xmm0, [wf_0_996]
    mulss xmm0, [wf_250]
    movss [wl_f], xmm0                  ; 0..1: its size and brightness
    mov eax, r10d                       ; where in the cell
    mov ecx, 8
    call wl_hash
    mulss xmm0, [wf_0_4]
    addss xmm0, [wf_0_3]
    cvtsi2ss xmm1, r8d
    addss xmm0, xmm1
    mulss xmm0, [wl_cell]
    cvtsi2ss xmm1, r12
    addss xmm1, [wf_half]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    movss [wl_t], xmm1
    mov eax, r10d
    mov ecx, 9
    call wl_hash
    mulss xmm0, [wf_0_4]
    addss xmm0, [wf_0_3]
    cvtsi2ss xmm1, r9d
    addss xmm0, xmm1
    mulss xmm0, [wl_cell]
    cvtsi2ss xmm1, r13
    addss xmm1, [wf_half]
    subss xmm1, xmm0
    mulss xmm1, xmm1
    addss xmm1, [wl_t]
    sqrtss xmm1, xmm1                   ; how far, in pixels
    movss xmm2, [wl_f]                  ; a disc of radius cell (0.12..0.22)
    mulss xmm2, [wf_0_10]
    addss xmm2, [wf_0_12]
    mulss xmm2, [wl_cell]
    addss xmm2, [wf_half]
    subss xmm2, xmm1
    maxss xmm2, [wf_zero]
    minss xmm2, [wf_one]
    movss xmm3, xmm15                   ; fainter lower down
    mulss xmm3, [wf_inv_0_45]
    movss xmm4, [wf_one]
    subss xmm4, xmm3
    mulss xmm4, [wl_f]
    mulss xmm4, [wf_1_5]
    minss xmm4, [wf_one]
    mulss xmm2, xmm4
    WL_MIX xmm8, [wl_pal + WLC_WHITE * 16], xmm2
.glow:
    movss xmm0, xmm14
    subss xmm0, [rbp + WLM_MX]
    mulss xmm0, [wl_aspect]
    mulss xmm0, xmm0
    movss xmm1, xmm15
    subss xmm1, [rbp + WLM_MY]
    mulss xmm1, xmm1
    addss xmm0, xmm1
    sqrtss xmm0, xmm0
    movss [wl_d], xmm0
    divss xmm0, [rbp + WLM_GLOW_R]       ; (1 - d / reach)^2 * strength
    movss xmm1, [wf_one]
    subss xmm1, xmm0
    maxss xmm1, [wf_zero]
    mulss xmm1, xmm1
    mulss xmm1, [rbp + WLM_GLOW_A]
    WL_MIX xmm8, [wl_pal + WLC_GLOW * 16], xmm1
    movss xmm0, [rbp + WLM_DISC_R]       ; the moon: inside its radius, its
    subss xmm0, [wl_d]                  ; edge a pixel soft
    mulss xmm0, [wl_hf]
    xorps xmm1, xmm1
    comiss xmm0, xmm1
    jbe .out
    minss xmm0, [wf_one]
    movss [wl_t], xmm0
    movss xmm0, [wl_d]
    divss xmm0, [rbp + WLM_DISC_R]
    mulss xmm0, xmm0
    movaps xmm9, [wl_pal + WLC_DISC0 * 16]
    WL_MIX xmm9, [wl_pal + WLC_DISC1 * 16], xmm0
    WL_MIX xmm8, xmm9, [wl_t]
.out:
    ret

; wl_shade(ESI = a range) -> XMM9 = its color at the pixel (wl_x, XMM14 = u,
; XMM15 = v). Preserves RSI, RBX, R12-R15, XMM8.
wl_shade:
    push rbx
    imul rbx, rsi, WLR_SIZE
    lea rax, [wall_ranges]
    add rbx, rax
    mov rax, rsi                        ; how far below its top, and the
    imul rax, [wl_w]                    ; fraction of the way to the shore
    add rax, [wl_x]
    mov rdx, [wl_cols]
    movss xmm1, [rdx + rax * 4]
    movss xmm0, xmm15
    subss xmm0, xmm1
    movss [wl_dep], xmm0
    movss xmm2, [wf_hz]
    subss xmm2, xmm1
    maxss xmm2, [wf_0_001]
    divss xmm0, xmm2
    movss [wl_below], xmm0
    movss xmm0, xmm14                   ; the spur it is on: the light is
    mulss xmm0, [wf_9]                  ; that of the ridge where the spur
    movss xmm1, xmm15                   ; leads up, so the shade's edges
    mulss xmm1, [wf_3]                  ; slant down the faces
    lea ecx, [rsi + 71]
    call wl_noise2
    subss xmm0, [wf_half]
    mulss xmm0, [wf_1_6]
    movss [wl_t], xmm0
    movss xmm0, xmm14
    mulss xmm0, [wf_40]
    movss xmm1, xmm15
    mulss xmm1, [wf_12]
    lea ecx, [rsi + 75]
    call wl_noise2
    subss xmm0, [wf_half]
    mulss xmm0, [wf_0_25]
    addss xmm0, [wl_t]
    mulss xmm0, [wl_dep]
    addss xmm0, xmm14
    movss [wl_uw], xmm0
    mulss xmm0, [wl_wf]
    cvtss2si rax, xmm0
    test rax, rax
    jns .left
    xor eax, eax
.left:
    mov rdx, [wl_w]
    dec rdx
    cmp rax, rdx
    jle .right
    mov rax, rdx
.right:
    lea rdx, [rsi + 4]
    imul rdx, [wl_w]
    add rax, rdx
    mov rdx, [wl_cols]
    movss xmm0, [rdx + rax * 4]
    movss [wl_lit], xmm0
    movss xmm0, [wl_uw]                 ; and the rock's own facets
    mulss xmm0, [wf_180]
    movss xmm1, xmm15
    mulss xmm1, [wf_60]
    lea ecx, [rsi + 13]
    call wl_noise2
    subss xmm0, [wf_half]
    mulss xmm0, [wf_0_3]
    addss xmm0, [wl_lit]
    maxss xmm0, [wf_zero]
    minss xmm0, [wf_one]
    movss [wl_lit], xmm0
    movss xmm0, [wl_below]              ; the light shows near the top,
    mulss xmm0, [wf_1_4]                ; less toward the foot
    movss xmm1, [wf_one]
    subss xmm1, xmm0
    maxss xmm1, [wf_zero]
    minss xmm1, [wf_one]
    movss [wl_face], xmm1
    mov rax, rsi
    shl rax, 4
    lea rdx, [wl_pal + WLC_R0 * 16]
    movaps xmm9, [rdx + rax]
    movaps xmm10, xmm9                  ; lit: brighter
    mulps xmm10, [wv_1_25]
    addps xmm10, [wv_12]
    movss xmm0, [wl_lit]
    mulss xmm0, [wl_face]
    mulss xmm0, [wf_0_8]
    WL_MIX xmm9, xmm10, xmm0
    movaps xmm10, xmm9                  ; in shade: darker
    mulps xmm10, [wv_0_78]
    movss xmm0, [wf_one]
    subss xmm0, [wl_lit]
    mulss xmm0, [wl_face]
    mulss xmm0, [wf_0_6]
    WL_MIX xmm9, xmm10, xmm0
    xorps xmm0, xmm0                    ; snow, down the couloirs: its line
    comiss xmm0, [rbx + WLR_SNOW]        ; moved by streaks along the spurs
    jae .mist
    movss xmm0, [wl_uw]
    mulss xmm0, [wf_140]
    movss xmm1, xmm15
    mulss xmm1, [wf_9]
    lea ecx, [rsi + 31]
    call wl_noise2
    mulss xmm0, [wf_0_6]
    movss [wl_t], xmm0
    movss xmm0, [wl_uw]
    mulss xmm0, [wf_45]
    movss xmm1, xmm15
    mulss xmm1, [wf_5]
    lea ecx, [rsi + 37]
    call wl_noise2
    mulss xmm0, [wf_0_4]
    addss xmm0, [wl_t]
    subss xmm0, [wf_half]
    mulss xmm0, [rbx + WLR_RAGGED]
    addss xmm0, [rbx + WLR_LINE]
    subss xmm0, [wl_below]
    mulss xmm0, [wf_35]
    call wl_smooth
    mulss xmm0, [rbx + WLR_SNOW]
    movss [wl_t], xmm0
    movaps xmm10, [wl_pal + WLC_SNOWSH * 16]
    WL_MIX xmm10, [wl_pal + WLC_SNOW * 16], [wl_lit]
    WL_MIX xmm9, xmm10, [wl_t]
.mist:
    movss xmm0, [wl_below]              ; mist in the valley at its foot
    subss xmm0, [wf_0_35]
    mulss xmm0, [wf_inv_0_65]
    call wl_smooth
    mulss xmm0, [rbx + WLR_MIST]
    WL_MIX xmm9, [wl_pal + WLC_MIST * 16], xmm0
    pop rbx
    ret

; wl_lake_row(RDI = a row of the lake, 0 at the shore): a job: the rows
; above, mirrored and wobbling, toward the water's color farther down, with
; ripples
wl_lake_row:
    WL_JOB_IN
    mov r13, rdi
    add r13, [wl_hz_y]
    cvtsi2ss xmm15, r13
    mulss xmm15, [wl_invh]
    movss xmm0, xmm15                   ; d: 0 at the far shore, 1 at the
    subss xmm0, [wf_hz]                 ; screen's foot
    movss [wl_dv], xmm0
    mulss xmm0, [wf_2_5]
    movss [wl_d], xmm0
    mulss xmm0, [wf_1_2]                ; the water's color here
    call wl_smooth
    movaps xmm9, [wl_pal + WLC_WFAR * 16]
    WL_MIX xmm9, [wl_pal + WLC_WNEAR * 16], xmm0
    movaps [wl_water], xmm9
    movss xmm0, [wl_d]                  ; and how much of it over the mirror
    mulss xmm0, [wf_1_1]
    call wl_smooth
    mulss xmm0, [wf_0_55]
    addss xmm0, [wf_0_3]
    movss [wl_mixw], xmm0
    movss xmm0, [wl_d]                  ; the wobble: wider nearer
    mulss xmm0, [wf_0_012]
    addss xmm0, [wf_0_002]
    movss [wl_wobk], xmm0
    movss xmm0, [wl_d]                  ; the wobble's and the ripples' rows,
    addss xmm0, [wf_0_08]               ; closer together far off
    movss xmm1, [wl_dv]
    mulss xmm1, [wf_260]
    divss xmm1, xmm0
    movss [wl_wy], xmm1
    movss xmm0, [wl_d]
    addss xmm0, [wf_0_1]
    movss xmm1, [wl_dv]
    mulss xmm1, [wf_700]
    divss xmm1, xmm0
    movss [wl_ry], xmm1
    movss xmm0, [wf_one]                ; glints, fading nearer
    subss xmm0, [wl_d]
    mulss xmm0, [wf_0_18]
    movss [wl_glk], xmm0
    movss xmm0, [wf_1_2]                ; the row it mirrors
    subss xmm0, xmm15
    mulss xmm0, [wl_hf]
    cvtss2si rax, xmm0
    test rax, rax
    jns .m_top
    xor eax, eax
.m_top:
    mov rdx, [wl_hz_y]
    dec rdx
    cmp rax, rdx
    jle .m_bottom
    mov rax, rdx
.m_bottom:
    imul rax, [wall_sf + SF_PITCH]
    add rax, [wall_sf + SF_PTR]
    mov [wl_mirror], rax
    mov r14, r13
    imul r14, [wall_sf + SF_PITCH]
    add r14, [wall_sf + SF_PTR]
    xor r12d, r12d
.px:
    cmp r12, [wl_w]
    jae .done
    cvtsi2ss xmm14, r12
    mulss xmm14, [wl_invw]
    movss xmm0, xmm14                   ; the mirror, wobbling
    mulss xmm0, [wf_8]
    movss xmm1, [wl_wy]
    mov ecx, 91
    call wl_noise2
    subss xmm0, [wf_half]
    mulss xmm0, [wl_wobk]
    addss xmm0, xmm14
    mulss xmm0, [wl_wf]
    cvtss2si rax, xmm0
    test rax, rax
    jns .x_left
    xor eax, eax
.x_left:
    mov rdx, [wl_w]
    dec rdx
    cmp rax, rdx
    jle .x_right
    mov rax, rdx
.x_right:
    mov rdx, [wl_mirror]
    movd xmm8, [rdx + rax * 4]
    pxor xmm1, xmm1
    punpcklbw xmm8, xmm1
    punpcklwd xmm8, xmm1
    cvtdq2ps xmm8, xmm8
    WL_MIX xmm8, [wl_water], [wl_mixw]
    movss xmm0, xmm14                   ; ripples: a glint on the high ones,
    mulss xmm0, [wf_18]                 ; each a little lighter or darker
    movss xmm1, [wl_ry]
    mov ecx, 81
    call wl_noise2
    movss [wl_t], xmm0
    subss xmm0, [wf_0_78]
    mulss xmm0, [wf_inv_0_15]
    call wl_smooth
    mulss xmm0, [wl_glk]
    WL_MIX xmm8, [wl_pal + WLC_GLINT * 16], xmm0
    movss xmm0, [wl_t]
    mulss xmm0, [wf_0_06]
    addss xmm0, [wf_0_96]
    shufps xmm0, xmm0, 0
    mulps xmm8, xmm0
    mov rax, r13                        ; a line of light along the far shore
    sub rax, [wl_hz_y]
    cmp rax, [wl_shore]
    jae .store
    WL_MIX xmm8, [wl_pal + WLC_MIST * 16], [wf_0_35]
.store:
    call wl_store
    inc r12
    jmp .px
.done:
    WL_JOB_OUT

; wl_pines: each pine over what is there: tiers of branches widening down
; to its foot, their edges ragged, and a trunk
wl_pines:
    xor ebx, ebx
.pine:
    cmp ebx, WL_PINES
    jae .done
    imul rsi, rbx, WLP_SIZE
    lea rax, [wall_pines]
    add rsi, rax
    mov [wl_pine], rsi
    movss xmm0, [rsi + WLP_X]            ; its middle and reach, in pixels
    mulss xmm0, [wl_wf]
    movss [wl_xc], xmm0
    movss xmm1, [rsi + WLP_W]
    mulss xmm1, [wf_0_75]
    mulss xmm1, [wl_wf]
    addss xmm1, [wl_jag_reach]
    addss xmm1, [wf_2]
    movss xmm2, xmm0
    subss xmm2, xmm1
    cvttss2si rax, xmm2
    test rax, rax
    jns .x0
    xor eax, eax
.x0:
    mov [wl_x0], rax
    addss xmm0, xmm1
    cvttss2si rax, xmm0
    inc rax
    cmp rax, [wl_w]
    jbe .x1
    mov rax, [wl_w]
.x1:
    mov [wl_x1], rax
    movss xmm0, [rsi + WLP_W]            ; the trunk's half width
    mulss xmm0, [wf_0_045]
    mulss xmm0, [wl_wf]
    movss [wl_trunk], xmm0
    movss xmm0, [rsi + WLP_BASE]         ; its tip
    subss xmm0, [rsi + WLP_H]
    movss [wl_tip], xmm0
    mulss xmm0, [wl_hf]
    cvttss2si r13, xmm0
    test r13, r13
    jns .row
    xor r13d, r13d
.row:
    cmp r13, [wl_h]
    jae .pine_next
    cvtsi2ss xmm15, r13
    mulss xmm15, [wl_invh]
    mov rsi, [wl_pine]
    movss xmm0, xmm15                   ; t: 0 at the tip, 1 at the foot
    subss xmm0, [wl_tip]
    divss xmm0, [rsi + WLP_H]
    movss [wl_t], xmm0
    cvtsi2ss xmm1, dword [rsi + WLP_TIERS]
    mulss xmm0, xmm1                    ; down its tier: each wider at its foot
    call wl_floor
    sqrtss xmm0, xmm0
    mulss xmm0, [wf_0_45]
    addss xmm0, [wf_0_55]
    movss xmm1, [wl_t]
    mulss xmm1, [wf_0_92]
    addss xmm1, [wf_0_08]
    mulss xmm0, xmm1
    mulss xmm0, [rsi + WLP_W]
    mulss xmm0, [wf_0_75]
    mulss xmm0, [wl_wf]
    movss [wl_half], xmm0               ; half its width here, in pixels
    maxss xmm0, [wl_trunk]
    addss xmm0, [wl_jag_reach]
    movss [wl_reach], xmm0
    mov r14, r13
    imul r14, [wall_sf + SF_PITCH]
    add r14, [wall_sf + SF_PTR]
    mov r12, [wl_x0]
.px:
    cmp r12, [wl_x1]
    jae .row_next
    cvtsi2ss xmm0, r12
    subss xmm0, [wl_xc]
    andps xmm0, [wv_abs]
    movss [wl_dx], xmm0
    comiss xmm0, [wl_reach]
    ja .px_next
    cvtsi2ss xmm14, r12                 ; the branches' ragged edge
    mulss xmm14, [wl_invw]
    movss xmm0, xmm14
    mulss xmm0, [wf_900]
    movss xmm1, xmm15
    mulss xmm1, [wf_300]
    lea ecx, [rbx + 111]
    call wl_noise2
    subss xmm0, [wf_half]
    mulss xmm0, [wl_jag]
    movss xmm1, [wl_half]               ; how much of the pixel it covers:
    subss xmm1, [wl_dx]                 ; the branches or the trunk
    subss xmm1, xmm0
    addss xmm1, [wf_half]
    movss xmm2, [wl_trunk]
    subss xmm2, [wl_dx]
    addss xmm2, [wf_half]
    maxss xmm1, xmm2
    minss xmm1, [wf_one]
    xorps xmm2, xmm2
    comiss xmm1, xmm2
    jbe .px_next
    movss [wl_cv], xmm1
    movd xmm8, [r14 + r12 * 4]
    pxor xmm2, xmm2
    punpcklbw xmm8, xmm2
    punpcklwd xmm8, xmm2
    cvtdq2ps xmm8, xmm8
    mov rax, rbx
    shl rax, 4
    lea rdx, [wl_shades]
    add rdx, rax
    WL_MIX xmm8, [rdx], [wl_cv]
    call wl_store
.px_next:
    inc r12
    jmp .px
.row_next:
    inc r13
    jmp .row
.pine_next:
    inc ebx
    jmp .pine
.done:
    ret

; wl_store: XMM8 -> the pixel (R12, R13) in the row at R14, dithered
wl_store:
    mov eax, r13d
    and eax, 3
    shl eax, 2
    mov edx, r12d
    and edx, 3
    add eax, edx
    lea rdx, [wl_bayer]
    movss xmm0, [rdx + rax * 4]
    shufps xmm0, xmm0, 0
    addps xmm0, xmm8
    cvttps2dq xmm0, xmm0
    packssdw xmm0, xmm0
    packuswb xmm0, xmm0
    movd eax, xmm0
    and eax, 0xFFFFFF
    mov [r14 + r12 * 4], eax
    ret

; -----------------------------------------------------------------------------
;  Noise: an integer hash, and value noise smoothed between its points
; -----------------------------------------------------------------------------

; wl_ridge(XMM0 = u, RSI = a range, EDX = octaves) -> XMM0 = its top there,
; as v. Clobbers RAX, RCX, RDX, R8-R11, XMM1-XMM7.
wl_ridge:
    mulss xmm0, [rsi + WLR_FREQ]
    addss xmm0, [rsi + WLR_SHIFT]
    mov ecx, [rsi + WLR_SEED]
    mov r11d, [rsi + WLR_RIDGED]
    call wl_fbm
    test r11d, r11d
    jz .height
    sqrtss xmm1, xmm0                   ; ridged: sharper, n^2.25
    sqrtss xmm1, xmm1
    mulss xmm1, xmm0
    mulss xmm0, xmm1
.height:
    mulss xmm0, [rsi + WLR_HEIGHT]
    movss xmm1, [wf_hz]
    subss xmm1, [rsi + WLR_BASE]
    subss xmm1, xmm0
    movss xmm0, xmm1
    ret

; wl_fbm(XMM0 = x, ECX = seed, EDX = octaves, R11D = 1 for ridges) ->
; XMM0 = 0..1: octaves of noise, each twice as fine and half as strong.
; Clobbers RAX, RDX, R8-R10, XMM1-XMM7.
wl_fbm:
    push rcx
    mov r9d, edx
    mov r10d, ecx
    movss xmm1, xmm0
    xorps xmm2, xmm2                    ; the sum
    movss xmm3, [wf_one]                ; this octave's strength
    xorps xmm4, xmm4                    ; the strengths' sum
.octave:
    movss xmm0, xmm1
    mov ecx, r10d
    call wl_noise1
    test r11d, r11d
    jz .add
    addss xmm0, xmm0                    ; ridges: 1 - |2n - 1|
    subss xmm0, [wf_one]
    andps xmm0, [wv_abs]
    movss xmm5, [wf_one]
    subss xmm5, xmm0
    movss xmm0, xmm5
.add:
    mulss xmm0, xmm3
    addss xmm2, xmm0
    addss xmm4, xmm3
    mulss xmm3, [wf_half]
    addss xmm1, xmm1
    inc r10d
    dec r9d
    jnz .octave
    movss xmm0, xmm2
    divss xmm0, xmm4
    pop rcx
    ret

; wl_noise1(XMM0 = x, ECX = seed) -> XMM0 = 0..1. Clobbers RAX, RDX, R8,
; XMM5-XMM7.
wl_noise1:
    call wl_floor
    mov r8d, eax
    call wl_smooth
    movss xmm6, xmm0
    mov eax, r8d
    call wl_hash
    movss xmm5, xmm0
    lea eax, [r8 + 1]
    call wl_hash
    subss xmm0, xmm5
    mulss xmm0, xmm6
    addss xmm0, xmm5
    ret

; wl_noise2(XMM0 = x, XMM1 = y, ECX = seed) -> XMM0 = 0..1. Clobbers RAX,
; RDX, R8-R10, XMM1-XMM7.
wl_noise2:
    call wl_floor
    mov r8d, eax
    call wl_smooth
    movss xmm2, xmm0
    movss xmm0, xmm1
    call wl_floor
    mov r9d, eax
    call wl_smooth
    movss xmm3, xmm0
    imul r8d, r8d, 57
    imul r9d, r9d, 131071
    lea r10d, [r8 + r9]
    mov eax, r10d
    call wl_hash
    movss xmm4, xmm0
    lea eax, [r10 + 57]
    call wl_hash
    subss xmm0, xmm4
    mulss xmm0, xmm2
    addss xmm4, xmm0                    ; the upper edge
    lea eax, [r10 + 131071]
    call wl_hash
    movss xmm5, xmm0
    lea eax, [r10 + 131071 + 57]
    call wl_hash
    subss xmm0, xmm5
    mulss xmm0, xmm2
    addss xmm0, xmm5                    ; the lower
    subss xmm0, xmm4
    mulss xmm0, xmm3
    addss xmm0, xmm4
    ret

; wl_hash(EAX = a point, ECX = seed) -> XMM0 = 0..1. Clobbers RAX, RDX.
wl_hash:
    imul eax, eax, 374761393
    imul edx, ecx, 668265263
    add eax, edx
    mov edx, eax
    shr edx, 13
    xor eax, edx
    imul eax, eax, 1274126177
    mov edx, eax
    shr edx, 16
    xor eax, edx
    and eax, 0xFFFFFF
    cvtsi2ss xmm0, eax
    mulss xmm0, [wf_2m24]
    ret

; wl_floor(XMM0 = x) -> EAX = floor(x), XMM0 = x - floor(x). Clobbers XMM7.
wl_floor:
    cvttss2si eax, xmm0
    cvtsi2ss xmm7, eax
    comiss xmm7, xmm0
    jbe .down
    dec eax
    subss xmm7, [wf_one]
.down:
    subss xmm0, xmm7
    ret

; wl_smooth(XMM0 = t) -> XMM0 = t clamped to 0..1, eased: t^2 (3 - 2t).
; Clobbers XMM7.
wl_smooth:
    maxss xmm0, [wf_zero]
    minss xmm0, [wf_one]
    movss xmm7, [wf_3]
    subss xmm7, xmm0
    subss xmm7, xmm0
    mulss xmm7, xmm0
    mulss xmm0, xmm7
    ret

section .rodata
align 16
wv_abs:         dd 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF, 0x7FFFFFFF
wv_1_25:        dd 1.25, 1.25, 1.25, 1.25
wv_12:          dd 12.0, 12.0, 12.0, 12.0
wv_0_78:        dd 0.78, 0.78, 0.78, 0.78
; the dither: a 4x4 Bayer matrix, as fractions of a step
wl_bayer:
    dd 0.03125, 0.53125, 0.15625, 0.65625
    dd 0.78125, 0.28125, 0.90625, 0.40625
    dd 0.21875, 0.71875, 0.09375, 0.59375
    dd 0.96875, 0.46875, 0.84375, 0.34375
wf_zero:        dd 0.0
wf_one:         dd 1.0
wf_half:        dd 0.5
wf_2m24:        dd 5.9604645e-8         ; 1 / 2^24
wf_hz:          dd 0.60                 ; the far shore, as v
wf_1_2:         dd 1.2
wf_2_5:         dd 2.5
wf_0_001:       dd 0.001
wf_0_002:       dd 0.002
wf_0_004:       dd 0.004
wf_0_012:       dd 0.012
wf_0_045:       dd 0.045
wf_0_06:        dd 0.06
wf_0_08:        dd 0.08
wf_0_1:         dd 0.1
wf_0_10:        dd 0.10
wf_0_12:        dd 0.12
wf_0_18:        dd 0.18
wf_0_25:        dd 0.25
wf_0_3:         dd 0.3
wf_0_35:        dd 0.35
wf_0_4:         dd 0.4
wf_0_45:        dd 0.45
wf_0_55:        dd 0.55
wf_0_6:         dd 0.6
wf_0_75:        dd 0.75
wf_0_78:        dd 0.78
wf_0_8:         dd 0.8
wf_0_92:        dd 0.92
wf_0_96:        dd 0.96
wf_0_996:       dd 0.996
wf_1_1:         dd 1.1
wf_1_4:         dd 1.4
wf_1_5:         dd 1.5
wf_1_6:         dd 1.6
wf_2:           dd 2.0
wf_3:           dd 3.0
wf_5:           dd 5.0
wf_8:           dd 8.0
wf_9:           dd 9.0
wf_12:          dd 12.0
wf_18:          dd 18.0
wf_35:          dd 35.0
wf_40:          dd 40.0
wf_45:          dd 45.0
wf_60:          dd 60.0
wf_140:         dd 140.0
wf_150:         dd 150.0
wf_180:         dd 180.0
wf_250:         dd 250.0
wf_260:         dd 260.0
wf_300:         dd 300.0
wf_700:         dd 700.0
wf_900:         dd 900.0
wf_inv_0_15:    dd 6.6666667
wf_inv_0_45:    dd 2.2222222
wf_inv_0_65:    dd 1.5384615

; the ranges, far to near: seed, peaks across, start, foot, height,
; ridged, octaves, snow, its line, how ragged, mist
wall_ranges:
    dd 11, 2.6, 4.07,  0.075, 0.270, 1, 7, 1.0,  0.34, 0.45, 0.55
    dd 23, 3.4, 8.51,  0.040, 0.150, 1, 6, 0.85, 0.16, 0.25, 0.45
    dd 37, 4.4, 13.69, 0.018, 0.085, 0, 6, 0.0,  0.0,  0.0,  0.35
    dd 51, 6.0, 18.87, 0.004, 0.045, 0, 6, 0.0,  0.0,  0.0,  0.25

; the pines: middle, foot, height, width, tiers
wall_pines:
    dd 0.040, 1.04, 0.66, 0.110, 7
    dd 0.105, 1.06, 0.50, 0.085, 8
    dd 0.000, 1.08, 0.80, 0.120, 9
    dd 0.160, 1.04, 0.30, 0.050, 7
    dd 0.905, 1.04, 0.60, 0.100, 8
    dd 0.975, 1.06, 0.76, 0.120, 9
    dd 0.845, 1.04, 0.34, 0.055, 7
    dd 1.020, 1.08, 0.56, 0.100, 8

; the light look: day, the sun high on the right
wall_day:
    dd 0.78, 0.08, 0.6, 0.30, 0.0, 0
    dd 0.0, 0.55, 0.80, 1.0
    dd 0x2A64C9, 0x6FA7E4, 0xB6D0EC, 0xE9EEF2      ; sky
    dd 0x7C93B8, 0x5A7598, 0x3E5975, 0x27404F      ; ranges
    dd 0xDCE7F2, 0xFAFCFF, 0xB9CBE4                ; mist, snow, in shade
    dd 0x2D5F8E, 0x123A55, 0xFFFFFF                ; water, glints
    dd 0x0E1F24, 0xFFFFFF, 0, 0, 0xFFFFFF          ; pines, glow, -, white
; the dark look: dusk, stars and the moon
wall_dusk:
    dd 0.70, 0.16, 0.30, 0.45, 0.03, 1
    dd 0.0, 0.5, 0.82, 1.0
    dd 0x0B1033, 0x3B2A6E, 0xA2507E, 0xF29A78
    dd 0x4C3F7A, 0x3A2F63, 0x271F48, 0x161230
    dd 0xC9789A, 0xE6D9F0, 0x8D7DB8
    dd 0x3D2C66, 0x0B0B22, 0xFFE2D6
    dd 0x07061A, 0xF6D2DE, 0xFFF8EC, 0xEADCCB, 0xFFFFFF

section .bss
alignb 16
wl_pal:         resb 16 * WLC_COUNT     ; this look's colors, as floats
wl_shades:      resb 16 * WL_PINES         ; each pine's
wl_scratch:     resb WS_SIZE * MAX_CPUS ; each CPU's, making rows
alignb 8
wall_sf:        resb SF_SIZE
wl_made:        resq 1                  ; the screen and look it was made for
wl_want:        resq 1
wl_cols:        resq 1                  ; tops, lights, edges; then the sky's rows
wl_skyrows:     resq 1
wl_w:           resq 1
wl_h:           resq 1
wl_hz_y:        resq 1                  ; the lake's first row
wl_shore:       resq 1                  ; the shore's line, rows
wl_look:        resq 1                  ; the look being made
wl_pine:        resq 1
wl_x0:          resq 1
wl_x1:          resq 1
wl_wf:          resd 1                  ; floats from here
wl_hf:          resd 1
wl_invw:        resd 1
wl_invh:        resd 1
wl_aspect:      resd 1
wl_cell:        resd 1
wl_inv_cell:    resd 1
wl_jag:         resd 1
wl_jag_reach:   resd 1
wl_xc:          resd 1
wl_dx:          resd 1
wl_half:        resd 1
wl_trunk:       resd 1
wl_reach:       resd 1
wl_tip:         resd 1

%undef wl_water
%undef wl_x
%undef wl_mirror
%undef wl_t
%undef wl_f
%undef wl_d
%undef wl_dv
%undef wl_cv
%undef wl_dep
%undef wl_below
%undef wl_uw
%undef wl_lit
%undef wl_face
%undef wl_mixw
%undef wl_wobk
%undef wl_wy
%undef wl_ry
%undef wl_glk
