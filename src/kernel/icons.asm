; =============================================================================
;  icons.asm - the pictures the desktop draws: the dock's apps, each made
;  from a few shapes at the dock's size (an icon program); one for a program
;  that has none, from its name; and the pointer.
;
;  An icon is a rounded square, its body, with a soft shadow under it. Its
;  program draws the body (top left 0, 0, bottom right 1000, 1000) with:
;    IP_GRAD top, bottom                      the whole body, top to bottom
;    IP_RRECT x, y, w, h, radius, color, alpha
;    IP_CIRCLE x, y, diameter, color, alpha   (x, y: the top left of its box)
;    IP_POLY n, color, alpha, x, y, ...       n points
;    IP_END
;  Alphas are 0..256.
; =============================================================================

IP_END          equ 0
IP_GRAD         equ 1
IP_RRECT        equ 2
IP_CIRCLE       equ 3
IP_POLY         equ 4
IP_LETTER       equ 5                   ; char: white, in the middle (icon_for)

ICON_INSET      equ 80                  ; the body, thousandths of the icon in
ICON_RADIUS     equ 225                 ; its corners, thousandths of the body

section .text

; icons_make: each dock app's icon at the dock's size, and their shadow
icons_make:
    push rbx
    push r12
    mov rax, [m_icon]                   ; the shadow: the body's corners
    imul rax, rax, 1000 - 2 * ICON_INSET
    xor edx, edx
    mov ecx, 1000
    div rcx
    imul rax, rax, ICON_RADIUS
    xor edx, edx
    div rcx
    mov [sh_icon + SH_R], rax
    mov edi, 3
    call pt
    mov [sh_icon + SH_M], rax
    mov edi, 1
    call pt
    mov [sh_icon + SH_OY], rax
    mov dword [sh_icon + SH_A], 110
    lea rdi, [sh_icon]
    call shadow_build
    xor ebx, ebx
.each:
    cmp ebx, DOCK_APPS
    jae .out
    imul rdi, rbx, SF_SIZE
    lea rax, [app_icons]
    add rdi, rax
    imul rax, rbx, DA_SIZE
    lea rsi, [dock_apps]
    mov rsi, [rsi + rax + DA_ICON]
    call icon_render
    inc ebx
    jmp .each
.out:
    pop r12
    pop rbx
    ret

; icon_for(RDI = window): its WN_ICON, from its app's name: a color its
; name picks, its first letter. Preserves all.
icon_for:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea rsi, [rdi + WN_APP]             ; the color: by the name's bytes
    xor eax, eax
    xor ecx, ecx
.sum:
    movzx edx, byte [rsi + rcx]
    test edx, edx
    jz .summed
    imul eax, eax, 31
    add eax, edx
    inc ecx
    jmp .sum
.summed:
    xor edx, edx
    mov ecx, ACCENTS - 1                ; not graphite
    div ecx
    lea rax, [accent_colors]
    mov r8d, [rax + rdx * 8]            ; its dark shade
    mov r9d, r8d                        ; the top: a quarter white
    mov r10d, 0xFFFFFF
    MIX r9d, r10d, 64, 192, eax, ecx
    mov r10d, r8d                       ; the bottom: darker
    SCALE r10d, 200, eax
    lea rax, [icon_prog]
    mov dword [rax], IP_GRAD
    mov [rax + 4], r9d
    mov [rax + 8], r10d
    mov dword [rax + 12], IP_LETTER
    movzx ecx, byte [rsi]
    cmp ecx, 'a'                        ; a capital
    jb .letter
    cmp ecx, 'z'
    ja .letter
    sub ecx, 32
.letter:
    mov [rax + 16], ecx
    mov dword [rax + 20], IP_END
    lea rdi, [rdi + WN_ICON]
    mov rsi, rax
    call icon_render
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; icon_render(RDI = a surface, RSI = an icon program): the icon, at the
; dock's size, into the surface. Preserves RBX, RBP, R12-R15.
icon_render:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov rsi, [m_icon]
    mov rdx, rsi
    call img_new
    jc .out
    mov rax, [m_icon]                   ; the body: its side and place
    imul rax, rax, ICON_INSET
    add rax, 500
    xor edx, edx
    mov ecx, 1000
    div rcx
    mov r15, rax                        ; inset
    mov r14, [m_icon]
    sub r14, r15
    sub r14, r15                        ; side
    lea rdi, [icon_tmp]
    mov rsi, r14
    mov rdx, r14
    call img_new
    jc .out
    lea rdi, [icon_tmp]
    call gfx_target
    call icon_run                       ; R13 = program, R14 = side
    ; all of the body opaque (a gradient leaves its fourth byte 0)
    mov rdi, [icon_tmp + SF_PTR]
    mov rcx, [icon_tmp + SF_W]
    imul rcx, [icon_tmp + SF_H]
.opaque:
    or byte [rdi + 3], 0xFF
    add rdi, 4
    dec rcx
    jnz .opaque
    ; onto the icon: its shadow, then the body with round corners
    mov rdi, r12
    call gfx_target
    mov rdi, r15
    mov rsi, r15
    mov rax, [sh_icon + SH_OY]          ; a little above the middle: room
    shr rax, 1                          ; for the shadow under it
    sub rsi, rax
    mov rdx, r14
    mov rcx, r14
    push rdi
    push rsi
    lea r8, [sh_icon]
    call gfx_shadow
    pop rsi
    pop rdi
    lea rax, [icon_tmp]
    mov [span_sf], rax
    mov [span_x], rdi
    mov [span_y], rsi
    mov r10, [sh_icon + SH_R]
    mov r11d, RC_ALL
    push rbx
    lea rbx, [span_copy]
    call rr_walk
    pop rbx
    call gfx_target_back
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ipx(EAX = thousandths of the body) -> RAX = pixels, R14 = the side.
; Clobbers RDX.
ipx:
    movsxd rax, eax
    imul rax, r14
    add rax, 500
    cqo
    push rcx
    mov ecx, 1000
    idiv rcx
    pop rcx
    ret

; ipx256: the same, in 1/256 pixels
ipx256:
    movsxd rax, eax
    imul rax, r14
    shl rax, 8
    cqo
    push rcx
    mov ecx, 1000
    idiv rcx
    pop rcx
    ret

; icon_run(R13 = program, R14 = the body's side): its shapes into the target
icon_run:
    push rbx
    push r12
    push r13
.op:
    mov eax, [r13]
    cmp eax, IP_GRAD
    je .grad
    cmp eax, IP_RRECT
    je .rrect
    cmp eax, IP_CIRCLE
    je .circle
    cmp eax, IP_POLY
    je .poly
    cmp eax, IP_LETTER
    je .letter
    pop r13
    pop r12
    pop rbx
    ret
.grad:
    xor edi, edi
    xor esi, esi
    mov rdx, r14
    mov rcx, r14
    mov r8d, [r13 + 4]
    mov r9d, [r13 + 8]
    call gfx_vgrad
    add r13, 12
    jmp .op
.rrect:
    mov eax, [r13 + 4]
    call ipx
    mov rdi, rax
    mov eax, [r13 + 8]
    call ipx
    mov rsi, rax
    mov eax, [r13 + 12]
    call ipx
    mov rbx, rax
    mov eax, [r13 + 16]
    call ipx
    mov rcx, rax
    mov eax, [r13 + 20]
    call ipx
    mov r10, rax
    mov rdx, rbx
    mov r8d, [r13 + 24]
    mov r9d, [r13 + 28]
    mov r11d, RC_ALL
    call gfx_rrect
    add r13, 32
    jmp .op
.circle:
    mov eax, [r13 + 4]
    call ipx
    mov rdi, rax
    mov eax, [r13 + 8]
    call ipx
    mov rsi, rax
    mov eax, [r13 + 12]
    call ipx
    mov rdx, rax
    mov r8d, [r13 + 16]
    mov r9d, [r13 + 20]
    call gfx_circle
    add r13, 24
    jmp .op
.poly:
    mov r12d, [r13 + 4]                 ; n
    lea rbx, [r13 + 16]
    lea rdi, [icon_pts]
    xor ecx, ecx
.pt:
    mov eax, [rbx + rcx * 4]
    call ipx256
    mov [rdi + rcx * 4], eax
    inc ecx
    lea eax, [r12d * 2]
    cmp ecx, eax
    jb .pt
    mov esi, r12d
    mov edx, [r13 + 8]
    mov ecx, [r13 + 12]
    call gfx_poly
    lea r13, [rbx + r12 * 8]
    jmp .op
.letter:
    mov eax, [r13 + 4]
    mov [icon_text], al
    mov byte [icon_text + 1], 0
    mov rdi, r14                        ; the font: half the body high
    shr rdi, 1
    mov esi, UF_SEMIBOLD
    call uf_size
    mov r12d, eax
    lea rdi, [icon_text]
    mov esi, r12d
    call uf_width
    mov rdi, r14                        ; centred
    sub rdi, rax
    sar rdi, 1
    push rdi
    mov edi, r12d
    call uf_metrics
    mov eax, [rax + UFT_CAP]
    pop rdi
    mov rsi, r14
    add rsi, rax
    shr rsi, 1
    lea rdx, [icon_text]
    mov ecx, 0xFFFFFFFF
    mov r8d, r12d
    call uf_text
    add r13, 8
    jmp .op

; -----------------------------------------------------------------------------
;  The pointer: an arrow, black with a white edge and a soft shadow, at the
;  desktop's scale. Its points are hundredths of a point from its tip.
; -----------------------------------------------------------------------------
CUR_PAD         equ 300                 ; the image starts this far up and left
CUR_W           equ 2000                ; and is this big
CUR_H           equ 2700
CUR_EDGE_N      equ 9
CUR_FILL_N      equ 7

cursor_make:
    push rbx
    push r12
    push r13
    mov edi, CUR_W / 100
    call pt
    mov rsi, rax
    mov edi, CUR_H / 100
    call pt
    mov rdx, rax
    lea rdi, [cursor_sf]
    call img_new
    jc .out
    call gfx_target
    ; the shadow: the edge's shape, nine times a little apart, faint
    lea r12, [cur_shadow_at]
.shadow:
    mov ebx, [r12]
    cmp ebx, 0x7FFFFFFF
    je .shape
    mov r13d, [r12 + 4]
    lea rsi, [cursor_edge]
    mov ecx, CUR_EDGE_N
    call cur_points
    mov esi, CUR_EDGE_N
    mov edx, 0xFF000000
    mov ecx, 16
    call gfx_poly
    add r12, 8
    jmp .shadow
.shape:
    xor ebx, ebx
    xor r13d, r13d
    lea rsi, [cursor_edge]
    mov ecx, CUR_EDGE_N
    call cur_points
    mov esi, CUR_EDGE_N
    mov edx, 0xFFFFFFFF
    mov ecx, 256
    call gfx_poly
    lea rsi, [cursor_fill]
    mov ecx, CUR_FILL_N
    call cur_points
    mov esi, CUR_FILL_N
    mov edx, 0xFF000000
    mov ecx, 256
    call gfx_poly
    mov edi, CUR_PAD                    ; the tip, in the image
    mov eax, edi
    imul eax, [ui_s4]
    add eax, 200
    xor edx, edx
    mov ecx, 400
    div ecx
    mov [cursor_hot_x], rax
    mov [cursor_hot_y], rax
    call gfx_target_back
.out:
    pop r13
    pop r12
    pop rbx
    ret

; cur_points(RSI = points, ECX = how many, EBX, R13D = moved by, in
; hundredths of a point) -> RDI = cur_pts, in 1/256 pixels of the image
cur_points:
    lea rdi, [cur_pts]
    push rdi
    push r8
    mov r8d, [ui_s4]
.each:
    mov eax, [rsi]
    add eax, ebx
    add eax, CUR_PAD
    imul eax, r8d
    imul eax, eax, 16
    cdq
    push rcx
    mov ecx, 25
    idiv ecx
    pop rcx
    mov [rdi], eax
    mov eax, [rsi + 4]
    add eax, r13d
    add eax, CUR_PAD
    imul eax, r8d
    imul eax, eax, 16
    cdq
    push rcx
    mov ecx, 25
    idiv ecx
    pop rcx
    mov [rdi + 4], eax
    add rsi, 8
    add rdi, 8
    dec ecx
    jnz .each
    pop r8
    pop rdi
    ret

section .rodata
align 4
; the dock's apps
icon_terminal:
    dd IP_GRAD, 0xFF3A3A3E, 0xFF1C1C1F
    dd IP_RRECT, 0, 0, 1000, 120, 0, 0xFF4A4A50, 256
    dd IP_POLY, 6, 0xFFF2F2F7, 256, 200, 300, 400, 420, 200, 540, 200, 460, 290, 420, 200, 380
    dd IP_RRECT, 440, 500, 190, 52, 10, 0xFFF2F2F7, 256
    dd IP_END
icon_files:
    dd IP_GRAD, 0xFFF7F7FA, 0xFFDCDCE2
    dd IP_RRECT, 150, 250, 300, 160, 50, 0xFF2D86E8, 256
    dd IP_RRECT, 150, 300, 700, 470, 60, 0xFF2D86E8, 256
    dd IP_RRECT, 150, 380, 700, 390, 60, 0xFF5AB2FF, 256
    dd IP_RRECT, 150, 380, 700, 30, 0, 0xFF7CC4FF, 256
    dd IP_END
icon_notes:
    dd IP_GRAD, 0xFFFFFFFF, 0xFFF1F1F4
    dd IP_RRECT, 0, 0, 1000, 270, 0, 0xFFFFD43B, 256
    dd IP_RRECT, 0, 250, 1000, 20, 0, 0xFFE5B800, 256
    dd IP_RRECT, 130, 420, 740, 22, 11, 0xFFD1D1D6, 256
    dd IP_RRECT, 130, 560, 740, 22, 11, 0xFFD1D1D6, 256
    dd IP_RRECT, 130, 700, 520, 22, 11, 0xFFD1D1D6, 256
    dd IP_END
icon_browse:
    dd IP_GRAD, 0xFFFFFFFF, 0xFFE9E9EE
    dd IP_CIRCLE, 110, 110, 780, 0xFF1A7FF0, 256
    dd IP_CIRCLE, 150, 150, 700, 0xFF3FA4FF, 256
    dd IP_RRECT, 494, 160, 12, 70, 6, 0xFFFFFFFF, 200
    dd IP_RRECT, 494, 770, 12, 70, 6, 0xFFFFFFFF, 200
    dd IP_RRECT, 160, 494, 70, 12, 6, 0xFFFFFFFF, 200
    dd IP_RRECT, 770, 494, 70, 12, 6, 0xFFFFFFFF, 200
    dd IP_POLY, 3, 0xFFFF3B30, 256, 712, 288, 549, 549, 451, 451
    dd IP_POLY, 3, 0xFFF2F2F7, 256, 288, 712, 549, 549, 451, 451
    dd IP_END
icon_paint:
    dd IP_GRAD, 0xFFFFF4E6, 0xFFF6DEC0
    dd IP_CIRCLE, 130, 150, 740, 0xFFE9C79A, 256
    dd IP_CIRCLE, 560, 560, 150, 0xFFF9E9D5, 256
    dd IP_CIRCLE, 250, 260, 150, 0xFFFF453A, 256
    dd IP_CIRCLE, 450, 220, 150, 0xFFFF9F0A, 256
    dd IP_CIRCLE, 630, 330, 150, 0xFF30D158, 256
    dd IP_CIRCLE, 230, 460, 150, 0xFF0A84FF, 256
    dd IP_CIRCLE, 360, 630, 150, 0xFFBF5AF2, 256
    dd IP_END
GEAR            equ 0xFFE8E8ED
icon_settings:
    dd IP_GRAD, 0xFF9A9AA0, 0xFF5E5E64
    dd IP_CIRCLE, 220, 220, 560, GEAR, 256
    dd IP_POLY, 4, GEAR, 256, 690, 646, 818, 699, 865, 584, 738, 531
    dd IP_POLY, 4, GEAR, 256, 531, 738, 584, 865, 699, 818, 646, 690
    dd IP_POLY, 4, GEAR, 256, 354, 690, 301, 818, 416, 865, 469, 738
    dd IP_POLY, 4, GEAR, 256, 262, 531, 135, 584, 182, 699, 310, 646
    dd IP_POLY, 4, GEAR, 256, 310, 354, 182, 301, 135, 416, 262, 469
    dd IP_POLY, 4, GEAR, 256, 469, 262, 416, 135, 301, 182, 354, 310
    dd IP_POLY, 4, GEAR, 256, 646, 310, 699, 182, 584, 135, 531, 262
    dd IP_POLY, 4, GEAR, 256, 738, 469, 865, 416, 818, 301, 690, 354
    dd IP_CIRCLE, 330, 330, 340, 0xFFB8B8C0, 256
    dd IP_CIRCLE, 400, 400, 200, 0xFF707078, 256
    dd IP_END
icon_system:
    dd IP_GRAD, 0xFF2E2E32, 0xFF141416
    dd IP_RRECT, 120, 800, 760, 14, 7, 0xFF48484E, 256
    dd IP_RRECT, 160, 520, 100, 260, 24, 0xFF30D158, 256
    dd IP_RRECT, 300, 330, 100, 450, 24, 0xFF30D158, 256
    dd IP_RRECT, 440, 440, 100, 340, 24, 0xFF64D2FF, 256
    dd IP_RRECT, 580, 230, 100, 550, 24, 0xFF64D2FF, 256
    dd IP_RRECT, 720, 400, 100, 380, 24, 0xFF30D158, 256
    dd IP_END
icon_mandel:
    dd IP_GRAD, 0xFF2456C8, 0xFF0B1A4A
    dd IP_CIRCLE, 90, 140, 760, 0xFF5AB8FF, 60
    dd IP_CIRCLE, 150, 200, 640, 0xFF8FD3FF, 70
    dd IP_RRECT, 60, 494, 160, 12, 6, 0xFF8FD3FF, 220
    dd IP_CIRCLE, 140, 465, 70, 0xFF050510, 256
    dd IP_CIRCLE, 200, 390, 220, 0xFF050510, 256
    dd IP_CIRCLE, 370, 250, 500, 0xFF050510, 256
    dd IP_CIRCLE, 520, 160, 130, 0xFF050510, 256
    dd IP_CIRCLE, 520, 710, 130, 0xFF050510, 256
    dd IP_CIRCLE, 760, 330, 90, 0xFF050510, 256
    dd IP_CIRCLE, 760, 580, 90, 0xFF050510, 256
    dd IP_POLY, 3, 0xFF2A5BC0, 256, 880, 440, 880, 560, 800, 500
    dd IP_END

; the pointer: its edge and its fill, hundredths of a point from the tip
cursor_edge:
    dd 90, -87, -47, -116, -125, 0, -125, 1845, 326, 1431
    dd 545, 1934, 1005, 1734, 792, 1255, 1396, 1255
cursor_fill:
    dd 0, 0, 0, 1560, 370, 1220, 610, 1770, 840, 1670, 600, 1130, 1100, 1130
; where its shadow falls, nine times: around a point below it
cur_shadow_at:
    dd -70, 20, 0, 20, 70, 20
    dd -70, 90, 0, 90, 70, 90
    dd -70, 160, 0, 160, 70, 160
    dd 0x7FFFFFFF, 0

section .bss
alignb 8
sh_icon:        resb SH_SIZE            ; an icon's shadow
icon_tmp:       resb SF_SIZE            ; its body, being drawn
cursor_sf:      resb SF_SIZE            ; the pointer's picture
cursor_hot_x:   resq 1                  ; its tip, in it
cursor_hot_y:   resq 1
icon_prog:      resd 8
icon_pts:       resd 2 * POLY_MAX
cur_pts:        resd 2 * 16
icon_text:      resb 2
