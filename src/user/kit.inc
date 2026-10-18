; =============================================================================
;  kit.inc - what a program's window is made of: the desktop's look (its
;  colours, its scale and its fonts, RO_DESK_LOOK), drawing in it, and the
;  controls the desktop draws its own way
;
;  After axe.inc, by a program given the desktop (ax_desk). kit_open opens
;  its window; it draws into kit_px (kit_pitch bytes a row, B,G,R,x), then
;  shows what it drew. Sizes here are pixels: kit_pt turns points into them,
;  at the scale the user chose. A colour is 0xRRGGBB with an alpha in its top
;  byte to blend it by (0 = opaque): KA(a) | colour.
;
;    kit_open(EDI = width, ESI = height, in points, EDX = WNF_*) -> CF if
;      there is no desktop, or it said no
;    kit_next(RCX = a TSC deadline, 0 for none) -> EAX = the next WE_*, in
;      kit_ev; 0 at the deadline; -1 once the window has gone. For
;      WE_RESIZED, kit_w and kit_h are its size now; for WE_PRESS,
;      kit_clicks counts (2: a double click)
;    kit_show(EDI = x, ESI = y, EDX = w, ECX = h), kit_show_all: what was
;      drawn there goes to the screen
;    kit_title(RSI = UTF-8, NUL-ended)
;    kit_close: the window gone; the program goes on without it
;    kit_pt(EDI = points) -> EAX = pixels
;    kit_c(EDI = TC_*) -> EAX = the theme's colour; kit_accent -> EAX;
;      kit_dark -> ZF if the theme is dark
;  Drawing, inside the clip (kit_clip(EDI, ESI, EDX, ECX); kit_unclip):
;    kit_fill(EDI = x, ESI = y, EDX = w, ECX = h, R8D = colour)
;    kit_round(EDI, ESI, EDX, ECX, R8D = radius, R9D = colour): its corners
;      round and smooth
;    kit_frame(EDI, ESI, EDX, ECX, R8D = radius, R9D = colour, R10D =
;      thickness): its edge alone
;    kit_shadow(EDI, ESI, EDX, ECX, R8D = radius, R9D = how far): soft,
;      around something raised
;    kit_stroke(EDI = x0, ESI = y0, EDX = x1, ECX = y1, in sixteenths of a
;      pixel, R8D = thickness, the same, R9D = colour): a line, its ends
;      round, smooth
;    kit_font(EDI = points, ESI = KF_*) -> EAX = the desktop's font nearest
;    kit_text(RSI = UTF-8, ECX = bytes, EDI = x, EDX = baseline, R8D =
;      font, R9D = colour) -> EAX = the x after it
;    kit_text_w(RSI, ECX, EDX = font) -> EAX = its width
;    kit_base(EDX = font, ESI = y, ECX = h) -> EAX = the baseline that
;      centres a line there; kit_line(EDX) -> EAX = a line's height
;    kit_mono(EDI = a cell's height wanted) -> kit_mcw, kit_mch: the
;      monospaced font's cell, at the size nearest
;    kit_mchar(EAX = a code point, EDI = x, ESI = top, R9D = colour): one
;      cell; kit_mtext(RSI, ECX, EDI = x, EDX = top, R9D) -> EAX = the x
;      after
;    kit_utf8(RSI = at, RDX = the end) -> EAX = the code point, RSI past it
;  Controls:
;    kit_button(EDI, ESI, EDX, ECX, R8 = its label, NUL-ended, R9D = KB_*)
;    kit_field(EDI, ESI, EDX, ECX, R8D = 1 if it has the keys): a text
;      field's box, what is in it the program's to draw
;    kit_scroller(EDI = x, ESI = y, EDX = h, ECX = lines in all, R8D =
;      shown, R9D = the first shown): a thin bar, as macOS draws one
;  A line of text to edit, a field (KE_*, R8 = it; KE_BUF and KE_CAP the
;  program's, the rest zeroed):
;    kit_ekey(R8, EAX = a key, EDX = WM_*) -> CF if the key is not one it
;      takes (Enter, Esc, Tab, up and down are the program's)
;    kit_edraw(R8, EDI = x, ESI = y, EDX = w, ECX = h, R9D = font, R10D =
;      1 if it has the keys): its box, its text, what is chosen, the caret
;      (while kit_caret is 1: the program blinks it)
;    kit_eclick(R8, EDI = x in the window, ESI = 1 to stretch what is
;      chosen, R9D = font): the caret there, as it was last drawn
;    kit_eset(R8, RSI = text, ECX = bytes): all it holds, all chosen
;  And:
;    kit_alloc(EDI = bytes) -> RAX = memory mapped, EDX = its handle; CF
;      if refused. kit_free(EDI = the handle)
;    kit_cb_set(RSI, ECX = bytes): the clipboard (kit_cb, kit_cb_len)
;  Each preserves RBX, RBP, R12-R15.
; =============================================================================

KF_REGULAR      equ 0
KF_BOLD         equ 1                   ; semibold
KB_DEFAULT      equ 1                   ; in the accent: what Enter does
KB_DOWN         equ 2                   ; held down
KB_OFF          equ 4                   ; not to be pressed now
%define KA(a) ((a) << 24)
KIT_CLICK_US    equ 450000              ; a second click within this is a double
KIT_RMAX        equ 160                 ; a corner's radius, at most
K_UP            equ 0x80                ; the keys past ASCII
K_DOWN          equ 0x81
K_LEFT          equ 0x82
K_RIGHT         equ 0x83
K_HOME          equ 0x84
K_END           equ 0x85
K_PGUP          equ 0x86
K_PGDN          equ 0x87
K_INS           equ 0x88
K_DEL           equ 0x89
K_BTAB          equ 0x8A                ; shift+tab
K_F1            equ 0x90
K_ESC           equ 27
KE_BUF          equ 0                   ; a field: qword, its bytes (UTF-8)
KE_CAP          equ 8                   ; dword: room for them
KE_LEN          equ 12
KE_CARET        equ 16                  ; where the caret is, a byte
KE_ANCHOR       equ 20                  ; the other end of what is chosen
KE_SCROLL       equ 24                  ; pixels of it scrolled out, at the left
KE_X            equ 28                  ; where its text began, last drawn
KE_INDENT       equ 32                  ; dword: room at its left, pixels (an icon)
KE_SIZE         equ 40

section .text

; -----------------------------------------------------------------------------
;  The window, and what it says
; -----------------------------------------------------------------------------

kit_open:
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13d, esi
    mov ebx, edx
    cmp dword [ax_desk], 0
    je .no
    call kit_look
    jc .no
    mov edi, r12d
    call kit_pt
    mov r12d, eax
    mov edi, r13d
    call kit_pt
    mov r13d, eax
    mov rax, [kit_lk]                   ; no larger than the screen
    cmp r12d, [rax + LK_SCR_W]
    jbe .wide
    mov r12d, [rax + LK_SCR_W]
.wide:
    cmp r13d, [rax + LK_SCR_H]
    jbe .high
    mov r13d, [rax + LK_SCR_H]
.high:
    mov eax, SYS_CHANNEL_NEW            ; what the window says comes over this
    syscall
    test rax, rax
    js .no
    mov [kit_end], edx
    mov edi, [ax_desk]
    mov esi, r12d
    mov edx, r13d
    mov r10d, eax
    mov r8d, ebx
    mov eax, SYS_WINDOW_NEW
    syscall
    test rax, rax
    js .no
    mov [kit_win], eax
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .no
    mov [kit_px], rax
    lea eax, [r12 * 4]
    test ebx, WNF_RESIZE | WNF_FULL     ; room for it at any size
    jz .pitch
    mov rax, [kit_lk]
    mov eax, [rax + LK_SCR_W]
    shl eax, 2
.pitch:
    mov [kit_pitch], eax
    mov [kit_w], r12d
    mov [kit_h], r13d
    call kit_unclip
    clc
    jmp .out
.no:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; kit_look -> the look mapped, its fonts found; CF if refused
kit_look:
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_DESK_LOOK
    mov eax, [ax_desk]
    mov [rsp + SQ_HANDLE], eax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    test rax, rax
    js .no
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    test rax, rax
    js .no
    mov [kit_lk], rax
    mov ecx, [rax + LK_UF]              ; the desktop's font
    add rcx, rax
    mov [kit_uf], rcx
    mov edx, [rcx + UFB_DATA]
    add rdx, rcx
    mov [kit_ufd], rdx
    mov edx, [rcx + UFB_UNI]
    add rdx, rcx
    mov [kit_ufu], rdx
    mov ecx, [rax + LK_MONO]            ; the monospaced one
    add rcx, rax
    mov [kit_mf], rcx
    mov edx, [rcx + MFB_DATA]
    add rdx, rcx
    mov [kit_mfd], rdx
    mov edx, [rcx + MFB_UNI]
    add rdx, rcx
    mov [kit_mfu], rdx
    call kit_relook
    mov edi, 20                         ; a cell until the program picks one
    call kit_mono
    clc
    ret
.no:
    stc
    ret

; kit_relook: the scale, as the look says now. Preserves all but RCX.
kit_relook:
    mov rcx, [kit_lk]
    mov ecx, [rcx + LK_S4]
    mov [kit_s4], ecx
    mov rcx, [kit_lk]
    mov ecx, [rcx + LK_SERIAL]
    mov [kit_serial], ecx
    ret

kit_next:
    mov [k_deadline], rcx
.again:
    mov edi, [kit_end]
    lea rsi, [kit_ev]
    mov edx, WE_SIZE
    mov rcx, [k_deadline]
    call ax_recv
    test rax, rax
    jns .got
    cmp rax, E_TIMEOUT
    je .time
    cmp rax, E_CANCELED
    je .time
    mov eax, -1
    ret
.time:
    xor eax, eax
    ret
.got:
    mov eax, [kit_ev + WE_KIND]
    cmp eax, WE_KEY                     ; alt's escape before its key: not one
    jne .resized
    cmp dword [kit_ev + WE_CODE], K_ESC
    jne .resized
    test dword [kit_ev + WE_X], WM_ALT
    jz .resized
    jmp .again
.resized:
    cmp eax, WE_RESIZED
    jne .look
    mov ecx, [kit_ev + WE_X]
    mov [kit_w], ecx
    mov ecx, [kit_ev + WE_Y]
    mov [kit_h], ecx
    push rax
    call kit_unclip
    pop rax
    ret
.look:
    cmp eax, WE_LOOK
    jne .press
    call kit_relook
    ret
.press:
    cmp eax, WE_PRESS
    jne .out
    push rbx
    push r12
    call ax_now
    mov rbx, rax
    sub rax, [kit_click_t]
    mov r12, rax
    mov edi, KIT_CLICK_US
    call ax_us
    mov [kit_click_t], rbx
    cmp r12, rax
    ja .first
    mov eax, [kit_ev + WE_CODE]
    cmp eax, [kit_click_b]
    jne .first
    mov edi, 4
    call kit_pt
    mov ecx, [kit_ev + WE_X]
    sub ecx, [kit_click_x]
    jns .dx
    neg ecx
.dx:
    cmp ecx, eax
    ja .first
    mov ecx, [kit_ev + WE_Y]
    sub ecx, [kit_click_y]
    jns .dy
    neg ecx
.dy:
    cmp ecx, eax
    ja .first
    inc dword [kit_clicks]
    jmp .clicked
.first:
    mov dword [kit_clicks], 1
.clicked:
    mov eax, [kit_ev + WE_CODE]
    mov [kit_click_b], eax
    mov eax, [kit_ev + WE_X]
    mov [kit_click_x], eax
    mov eax, [kit_ev + WE_Y]
    mov [kit_click_y], eax
    pop r12
    pop rbx
    mov eax, WE_PRESS
.out:
    ret

kit_close:
    mov edi, [kit_win]
    call k_close
    mov edi, [kit_end]
    call k_close
    mov dword [kit_win], 0
    mov dword [kit_end], 0
    ret

; k_close(EDI = a handle, or 0): closed
k_close:
    test edi, edi
    jz .out
    sub rsp, SQ_SIZE
    push rdi
    lea rdi, [rsp + 8]
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    pop rdi
    mov byte [rsp + SQ_OP], RO_CLOSE
    mov [rsp + SQ_HANDLE], edi
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
.out:
    ret

kit_show_all:
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
kit_show:
    test edi, edi                       ; inside the window
    jns .x
    add edx, edi
    xor edi, edi
.x:
    test esi, esi
    jns .y
    add ecx, esi
    xor esi, esi
.y:
    test edx, edx
    js .out
    test ecx, ecx
    js .out
    mov r8d, edi
    mov r9d, esi
    mov r10d, edx
    mov r11d, ecx
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WIN_SHOW
    mov eax, [kit_win]
    mov [rsp + SQ_HANDLE], eax
    mov [rsp + SQ_A0], r8
    mov [rsp + SQ_A1], r9
    shl r11, 32
    or r10, r11
    mov [rsp + SQ_A2], r10
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
.out:
    ret

kit_title:
    mov rdi, [ax_io_va]
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 255
    jb .copy
.copied:
    mov r8d, ecx
    sub rsp, SQ_SIZE + 8
    call ax_entry
    mov byte [rsp + SQ_OP], RO_WIN_TITLE
    mov eax, [kit_win]
    mov [rsp + SQ_HANDLE], eax
    mov eax, [ax_io]
    mov [rsp + SQ_HANDLE2], eax
    mov [rsp + SQ_A1], r8
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    ret

; -----------------------------------------------------------------------------
;  The look
; -----------------------------------------------------------------------------

kit_pt:
    mov eax, edi
    imul eax, [kit_s4]
    add eax, 2
    sar eax, 2
    ret

kit_c:
    mov eax, edi
    mov rcx, [kit_lk]
    mov eax, [rcx + LK_C + rax]
    ret

kit_accent:
    mov rax, [kit_lk]
    mov eax, [rax + LK_ACCENT]
    ret

kit_dark:
    push rax
    mov rax, [kit_lk]
    cmp dword [rax + LK_MODE], TH_DARK
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Drawing
; -----------------------------------------------------------------------------

kit_unclip:
    mov dword [kit_cx0], 0
    mov dword [kit_cy0], 0
    mov eax, [kit_w]
    mov [kit_cx1], eax
    mov eax, [kit_h]
    mov [kit_cy1], eax
    ret

kit_clip:
    call kit_unclip
    call k_cliprect
    jnc .set
    xor edi, edi                        ; nothing then
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
.set:
    mov [kit_cx0], edi
    mov [kit_cy0], esi
    mov [kit_cx1], edx
    mov [kit_cy1], ecx
    ret

; k_cliprect(EDI = x, ESI = y, EDX = w, ECX = h) -> EDI, ESI = its top left
; inside the clip, EDX, ECX = its bottom right (exclusive); CF if none of it
; is. Preserves others.
k_cliprect:
    add edx, edi
    add ecx, esi
    cmp edi, [kit_cx0]
    jge .x0
    mov edi, [kit_cx0]
.x0:
    cmp esi, [kit_cy0]
    jge .y0
    mov esi, [kit_cy0]
.y0:
    cmp edx, [kit_cx1]
    jle .x1
    mov edx, [kit_cx1]
.x1:
    cmp ecx, [kit_cy1]
    jle .y1
    mov ecx, [kit_cy1]
.y1:
    cmp edi, edx
    jge .none
    cmp esi, ecx
    jge .none
    clc
    ret
.none:
    stc
    ret

; k_at(EDI = x, ESI = y, inside the window) -> RAX = its pixel. Preserves
; others.
k_at:
    push rdx
    movsxd rax, esi
    mov edx, [kit_pitch]
    imul rax, rdx
    add rax, [kit_px]
    movsxd rdx, edi
    lea rax, [rax + rdx * 4]
    pop rdx
    ret

; k_alpha(R8D = a colour) -> ECX = its alpha, 1..255. Preserves others.
k_alpha:
    mov ecx, r8d
    shr ecx, 24
    jnz .out
    mov ecx, 255
.out:
    ret

; k_px(RDI = a pixel, R8D = colour, EAX = alpha 0..255): blended there.
; Preserves all but RAX.
k_px:
    cmp eax, 255
    jae .solid
    test eax, eax
    jz .out
    push rcx
    push rdx
    push r10
    push r11
    mov ecx, eax
    shr ecx, 7
    add eax, ecx                        ; 0..256
    mov r10d, 256
    sub r10d, eax
    mov r11d, [rdi]
    mov ecx, r8d                        ; red and blue together
    and ecx, 0x00FF00FF
    imul ecx, eax
    mov edx, r11d
    and edx, 0x00FF00FF
    imul edx, r10d
    add ecx, edx
    shr ecx, 8
    and ecx, 0x00FF00FF
    mov edx, r8d                        ; green
    and edx, 0x0000FF00
    imul edx, eax
    and r11d, 0x0000FF00
    imul r11d, r10d
    add edx, r11d
    shr edx, 8
    and edx, 0x0000FF00
    or ecx, edx
    mov [rdi], ecx
    pop r11
    pop r10
    pop rdx
    pop rcx
.out:
    ret
.solid:
    mov eax, r8d
    and eax, 0x00FFFFFF
    mov [rdi], eax
    ret

; k_dot(EDI = x, ESI = y, EAX = coverage 0..255, R8D = colour): one
; pixel, if it is inside the clip. Preserves all but RAX.
k_dot:
    cmp edi, [kit_cx0]
    jl .out
    cmp edi, [kit_cx1]
    jge .out
    cmp esi, [kit_cy0]
    jl .out
    cmp esi, [kit_cy1]
    jge .out
    push rcx
    push rdi
    call k_alpha
    imul eax, ecx
    add eax, 127
    push rdx
    xor edx, edx
    mov ecx, 255
    div ecx
    pop rdx
    push rax
    call k_at
    mov rdi, rax
    pop rax
    call k_px
    pop rdi
    pop rcx
.out:
    ret

kit_fill:
    call k_cliprect
    jc .out
    sub edx, edi                        ; EDX: its width, ECX: its rows
    sub ecx, esi
    call k_at
    mov r9, rax
    mov r10d, [kit_pitch]
    mov r11d, ecx
    mov eax, r8d
    shr eax, 24
    jnz .blend
    mov eax, r8d
.row:
    mov rdi, r9
    mov ecx, edx
    rep stosd
    add r9, r10
    dec r11d
    jnz .row
.out:
    ret
.blend:
    mov esi, eax                        ; the alpha
.brow:
    mov rdi, r9
    mov ecx, edx
.bpx:
    mov eax, esi
    call k_px
    add rdi, 4
    dec ecx
    jnz .bpx
    add r9, r10
    dec r11d
    jnz .brow
    ret

; k_cover(EDI = 2r, ESI = 2(r - j) - 1, EDX = 2(r - i) - 1, all in half
; pixels) -> EAX = how much of the pixel at (i, j) of a corner a circle of
; radius r about (r, r) covers, 0..255. Preserves others.
k_cover:
    push rcx
    mov eax, esi
    imul eax, eax
    mov ecx, edx
    imul ecx, ecx
    add eax, ecx
    cvtsi2ss xmm0, eax
    sqrtss xmm0, xmm0                   ; how far, in half pixels
    lea eax, [rdi + 1]
    cvtsi2ss xmm1, eax
    subss xmm1, xmm0                    ; (2r + 1 - d) / 2 of a pixel, inside
    mulss xmm1, [k_half255]
    cvtss2si eax, xmm1
    test eax, eax
    jns .some
    xor eax, eax
.some:
    cmp eax, 255
    jbe .out
    mov eax, 255
.out:
    pop rcx
    ret

kit_round:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r9d                        ; EBP: the colour
    mov ebx, r8d                        ; EBX: the radius, no more than fits
    mov eax, r14d
    shr eax, 1
    cmp ebx, eax
    cmova ebx, eax
    mov eax, r15d
    shr eax, 1
    cmp ebx, eax
    cmova ebx, eax
    cmp ebx, KIT_RMAX
    jbe .r
    mov ebx, KIT_RMAX
.r:
    mov edi, r12d                       ; the middle, between the corners' rows
    lea esi, [r13 + rbx]
    mov edx, r14d
    lea ecx, [rbx * 2]
    neg ecx
    add ecx, r15d
    mov r8d, ebp
    call kit_fill
    test ebx, ebx
    jz .out
    xor r9d, r9d                        ; R9D: the row from the top, j
.row:
    cmp r9d, ebx
    jae .out
    lea edi, [r12 + rbx]                ; the straight part, top and bottom
    lea esi, [r13 + r9]
    lea edx, [rbx * 2]
    neg edx
    add edx, r14d
    mov ecx, 1
    mov r8d, ebp
    push r9
    call kit_fill
    pop r9
    lea edi, [r12 + rbx]
    mov esi, r13d
    add esi, r15d
    sub esi, r9d
    dec esi
    lea edx, [rbx * 2]
    neg edx
    add edx, r14d
    mov ecx, 1
    mov r8d, ebp
    push r9
    call kit_fill
    pop r9
    xor r10d, r10d                      ; R10D: the column, i
.col:
    cmp r10d, ebx
    jae .next
    lea edi, [rbx * 2]
    mov esi, ebx
    sub esi, r9d
    lea esi, [rsi * 2 - 1]
    mov edx, ebx
    sub edx, r10d
    lea edx, [rdx * 2 - 1]
    call k_cover
    test eax, eax
    jz .skip
    mov r11d, eax
    mov r8d, ebp
    lea edi, [r12 + r10]                ; top left
    lea esi, [r13 + r9]
    call k_dot
    mov edi, r12d                       ; top right
    add edi, r14d
    sub edi, r10d
    dec edi
    mov eax, r11d
    call k_dot
    mov esi, r13d                       ; bottom right
    add esi, r15d
    sub esi, r9d
    dec esi
    mov eax, r11d
    call k_dot
    lea edi, [r12 + r10]                ; bottom left
    mov eax, r11d
    call k_dot
.skip:
    inc r10d
    jmp .col
.next:
    inc r9d
    jmp .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

kit_frame:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r9d
    mov ebx, r8d
    mov eax, r14d
    shr eax, 1
    cmp ebx, eax
    cmova ebx, eax
    mov eax, r15d
    shr eax, 1
    cmp ebx, eax
    cmova ebx, eax
    cmp ebx, KIT_RMAX
    jbe .r
    mov ebx, KIT_RMAX
.r:
    test r10d, r10d
    jnz .t
    mov r10d, 1
.t:
    mov [k_thick], r10d
    lea edi, [r12 + rbx]                ; top
    mov esi, r13d
    lea edx, [rbx * 2]
    neg edx
    add edx, r14d
    mov ecx, [k_thick]
    mov r8d, ebp
    call kit_fill
    lea edi, [r12 + rbx]                ; bottom
    mov esi, r13d
    add esi, r15d
    sub esi, [k_thick]
    lea edx, [rbx * 2]
    neg edx
    add edx, r14d
    mov ecx, [k_thick]
    mov r8d, ebp
    call kit_fill
    mov edi, r12d                       ; left
    lea esi, [r13 + rbx]
    mov edx, [k_thick]
    lea ecx, [rbx * 2]
    neg ecx
    add ecx, r15d
    mov r8d, ebp
    call kit_fill
    mov edi, r12d                       ; right
    add edi, r14d
    sub edi, [k_thick]
    lea esi, [r13 + rbx]
    mov edx, [k_thick]
    lea ecx, [rbx * 2]
    neg ecx
    add ecx, r15d
    mov r8d, ebp
    call kit_fill
    test ebx, ebx
    jz .out
    xor r9d, r9d
.row:
    cmp r9d, ebx
    jae .out
    xor r10d, r10d
.col:
    cmp r10d, ebx
    jae .next
    lea edi, [rbx * 2]                  ; inside the outer edge
    mov esi, ebx
    sub esi, r9d
    lea esi, [rsi * 2 - 1]
    mov edx, ebx
    sub edx, r10d
    lea edx, [rdx * 2 - 1]
    call k_cover
    mov r11d, eax
    mov eax, ebx                        ; and not inside the inner edge, about
    sub eax, [k_thick]                  ; the same centre
    jle .ring
    lea edi, [rax * 2]
    call k_cover
    sub r11d, eax
.ring:
    test r11d, r11d
    jle .skip
    mov r8d, ebp
    lea edi, [r12 + r10]
    lea esi, [r13 + r9]
    mov eax, r11d
    call k_dot
    mov edi, r12d
    add edi, r14d
    sub edi, r10d
    dec edi
    mov eax, r11d
    call k_dot
    mov esi, r13d
    add esi, r15d
    sub esi, r9d
    dec esi
    mov eax, r11d
    call k_dot
    lea edi, [r12 + r10]
    mov eax, r11d
    call k_dot
.skip:
    inc r10d
    jmp .col
.next:
    inc r9d
    jmp .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

kit_shadow:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r8d                        ; EBP: the radius
    mov ebx, r9d                        ; EBX: how far, a ring a pixel
    test ebx, ebx
    jz .out
    mov [k_spread], ebx
    mov eax, 0x30                       ; how dark next to it
    call kit_dark
    jne .light
    mov eax, 0x60
.light:
    mov [k_dark], eax
.ring:
    mov eax, [k_spread]                 ; fading as (1 - k/s)^2
    sub eax, ebx
    inc eax
    imul eax, eax
    imul eax, [k_dark]
    mov ecx, [k_spread]
    imul ecx, ecx
    xor edx, edx
    div ecx
    test eax, eax
    jz .next
    shl eax, 24
    mov r9d, eax
    mov edi, r12d
    sub edi, ebx
    mov esi, ebx                        ; a little below: the light is above
    shr esi, 2
    add esi, r13d
    sub esi, ebx
    lea edx, [r14 + rbx * 2]
    lea ecx, [r15 + rbx * 2]
    lea r8d, [rbp + rbx]
    mov r10d, 1
    call kit_frame
.next:
    dec ebx
    jnz .ring
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

kit_stroke:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi                       ; the ends, in sixteenths
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    cvtsi2ss xmm8, edi                  ; XMM8, 9: the first end, in pixels
    mulss xmm8, [k_16th]
    cvtsi2ss xmm9, esi
    mulss xmm9, [k_16th]
    cvtsi2ss xmm10, edx                 ; XMM10, 11: to the other
    mulss xmm10, [k_16th]
    subss xmm10, xmm8
    cvtsi2ss xmm11, ecx
    mulss xmm11, [k_16th]
    subss xmm11, xmm9
    movss xmm12, xmm10                  ; XMM12: 1 / its length squared
    mulss xmm12, xmm12
    movss xmm0, xmm11
    mulss xmm0, xmm0
    addss xmm12, xmm0
    xorps xmm0, xmm0
    ucomiss xmm12, xmm0
    je .point
    movss xmm0, [k_one]
    divss xmm0, xmm12
.point:
    movss xmm12, xmm0
    cvtsi2ss xmm13, r8d                 ; XMM13: half its thickness, and half
    mulss xmm13, [k_16th]               ; a pixel
    mulss xmm13, [k_half]
    addss xmm13, [k_half]
    mov ebx, r8d                        ; what it covers, in pixels
    shr ebx, 1
    add ebx, 16
    mov eax, r12d
    cmp eax, r14d
    cmovg eax, r14d
    sub eax, ebx
    sar eax, 4
    mov [k_sx0], eax
    mov eax, r12d
    cmp eax, r14d
    cmovl eax, r14d
    add eax, ebx
    sar eax, 4
    inc eax
    mov [k_sx1], eax
    mov eax, r13d
    cmp eax, r15d
    cmovg eax, r15d
    sub eax, ebx
    sar eax, 4
    mov esi, eax
    mov eax, r13d
    cmp eax, r15d
    cmovl eax, r15d
    add eax, ebx
    sar eax, 4
    inc eax
    mov ebx, eax                        ; EBX: the row past it
    mov r8d, r9d
.row:
    cmp esi, ebx
    jge .out
    cvtsi2ss xmm1, esi
    addss xmm1, [k_half]
    subss xmm1, xmm9
    mov edi, [k_sx0]
.col:
    cmp edi, [k_sx1]
    jge .next
    cvtsi2ss xmm0, edi
    addss xmm0, [k_half]
    subss xmm0, xmm8
    movss xmm2, xmm0                    ; how far along, 0..1
    mulss xmm2, xmm10
    movss xmm3, xmm1
    mulss xmm3, xmm11
    addss xmm2, xmm3
    mulss xmm2, xmm12
    xorps xmm3, xmm3
    maxss xmm2, xmm3
    minss xmm2, [k_one]
    movss xmm3, xmm10                   ; and how far from there
    mulss xmm3, xmm2
    movss xmm4, xmm0
    subss xmm4, xmm3
    movss xmm3, xmm11
    mulss xmm3, xmm2
    movss xmm5, xmm1
    subss xmm5, xmm3
    mulss xmm4, xmm4
    mulss xmm5, xmm5
    addss xmm4, xmm5
    sqrtss xmm4, xmm4
    movss xmm5, xmm13
    subss xmm5, xmm4
    xorps xmm3, xmm3
    maxss xmm5, xmm3
    minss xmm5, [k_one]
    mulss xmm5, [k_255]
    cvtss2si eax, xmm5
    test eax, eax
    jz .skip
    call k_dot
.skip:
    inc edi
    jmp .col
.next:
    inc esi
    jmp .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Text
; -----------------------------------------------------------------------------

kit_utf8:
    movzx eax, byte [rsi]
    inc rsi
    cmp eax, 0x80
    jb .out
    push rcx
    push rdx
    push rbx
    mov rbx, rdx                        ; the end
    cmp eax, 0xC2
    jb .bad
    mov ecx, 1
    and eax, 0x1F
    cmp byte [rsi - 1], 0xE0
    jb .more
    mov ecx, 2
    and eax, 0x0F
    cmp byte [rsi - 1], 0xF0
    jb .more
    mov ecx, 3
    and eax, 0x07
    cmp byte [rsi - 1], 0xF5
    jae .bad
.more:
    cmp rsi, rbx
    jae .bad
    movzx edx, byte [rsi]
    mov dh, dl
    and dh, 0xC0
    cmp dh, 0x80
    jne .bad
    and edx, 0x3F
    shl eax, 6
    or eax, edx
    inc rsi
    dec ecx
    jnz .more
    jmp .done
.bad:
    mov eax, 0xFFFD                     ; not UTF-8
.done:
    pop rbx
    pop rdx
    pop rcx
.out:
    ret

kit_font:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    push r9
    mov r9d, esi                        ; R9D: the weight
    call kit_pt
    mov ebx, eax                        ; EBX: the pixels wanted
    mov rsi, [kit_uf]
    xor ecx, ecx
    xor eax, eax                        ; the nearest so far
    mov edx, 0x7FFFFFFF
.each:
    cmp ecx, [rsi + UFB_SIZES]
    jae .done
    movzx r8d, byte [rsi + UFB_PX + rcx]
    sub r8d, ebx
    jns .abs
    neg r8d
.abs:
    cmp r8d, edx
    jae .next
    mov edx, r8d
    mov eax, ecx
.next:
    inc ecx
    jmp .each
.done:
    imul r9d, [rsi + UFB_SIZES]         ; the weight, then the size
    add eax, r9d
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; k_fe(EDX = a font) -> R11 = its table (LKF_*). Preserves others.
k_fe:
    push rdx
    movzx edx, dl
    imul edx, edx, LKF_SIZE
    mov r11, [kit_uf]
    lea r11, [r11 + UFB_FONTS + rdx]
    pop rdx
    ret

; k_glyph(EAX = a code point, R11 = a font's table) -> RAX = its glyph
; (LG_*), a ? if it has none. Preserves others.
k_glyph:
    push rcx
    push rdx
    push rsi
    push rdi
    lea ecx, [rax - 0x20]               ; ASCII, in order
    cmp ecx, 0x7E - 0x20
    ja .search
    lea ecx, [rax - 31]
    jmp .found
.search:
    mov rsi, [kit_ufu]
    mov rdi, [kit_uf]
    mov edi, [rdi + UFB_UNIS]           ; EDX..EDI: where it may be
    xor edx, edx
.halve:
    cmp edx, edi
    jae .none
    lea ecx, [rdx + rdi]
    shr ecx, 1
    cmp eax, [rsi + rcx * 8]
    je .hit
    jb .lower
    lea edx, [rcx + 1]
    jmp .halve
.lower:
    mov edi, ecx
    jmp .halve
.hit:
    mov ecx, [rsi + rcx * 8 + 4]
    jmp .found
.none:
    mov ecx, '?' - 31
.found:
    imul ecx, ecx, LG_SIZE
    mov rax, [r11 + LKF_GLYPHS]
    add rax, [kit_ufd]
    add rax, rcx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

kit_line:
    push r11
    call k_fe
    mov eax, [r11 + LKF_LINE]
    pop r11
    ret

kit_base:
    push r11
    call k_fe
    mov eax, ecx
    add eax, [r11 + LKF_CAP]
    sar eax, 1
    add eax, esi
    pop r11
    ret

kit_text_w:
    push rbx
    push r11
    lea rbx, [rsi + rcx]                ; the end
    call k_fe
    xor edx, edx                        ; 1/64 pixels
.each:
    cmp rsi, rbx
    jae .done
    push rdx
    mov rdx, rbx
    call kit_utf8
    pop rdx
    call k_glyph
    movzx eax, word [rax + LG_ADV]
    add edx, eax
    jmp .each
.done:
    lea eax, [rdx + 63]
    shr eax, 6
    pop r11
    pop rbx
    ret

kit_text:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov rbx, rsi                        ; RBX: where in the text
    lea r14, [rsi + rcx]                ; R14: its end
    movsxd r12, edi                     ; R12: the pen, in 1/64 pixels
    shl r12, 6
    mov r13d, edx                       ; R13D: the baseline
    mov ebp, r9d                        ; EBP: the colour
    mov edx, r8d
    call k_fe
    mov r15, r11                        ; R15: the font
.each:
    cmp rbx, r14
    jae .done
    mov rsi, rbx
    mov rdx, r14
    call kit_utf8
    mov rbx, rsi
    mov r11, r15
    call k_glyph
    movzx edx, byte [rax + LG_W]
    movzx ecx, byte [rax + LG_H]
    test edx, edx
    jz .advance
    test ecx, ecx
    jz .advance
    lea rdi, [r12 + 32]
    sar rdi, 6
    movsx esi, byte [rax + LG_LEFT]
    add edi, esi
    movsx esi, byte [rax + LG_TOP]
    neg esi
    add esi, r13d
    mov r10d, [rax + LG_DATA]
    add r10, [kit_ufd]
    mov r8d, ebp
    push rax
    call k_cov
    pop rax
.advance:
    movzx eax, word [rax + LG_ADV]
    add r12, rax
    jmp .each
.done:
    lea rax, [r12 + 63]
    sar rax, 6
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; k_cov(R10 = coverage, a byte a pixel, EDX wide, ECX high, EDI = x, ESI =
; y, R8D = colour): blended there, inside the clip
k_cov:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx                       ; R14D: a row of it
    call k_cliprect
    jc .out
    mov r15d, ecx                       ; R15D: its rows inside
    sub r15d, esi
    call k_alpha
    mov ebp, ecx                        ; EBP: the colour's alpha
    mov eax, esi                        ; where in the coverage
    sub eax, r13d
    imul eax, r14d
    add r10, rax
    mov eax, edi
    sub eax, r12d
    add r10, rax
    sub edx, edi                        ; EDX: its width inside
    call k_at
    mov rbx, rax
.row:
    mov rdi, rbx
    xor ecx, ecx
.px:
    movzx eax, byte [r10 + rcx]
    test eax, eax
    jz .clear
    cmp ebp, 255
    je .blend
    imul eax, ebp                       ; / 255
    imul eax, eax, 257
    add eax, 32768
    shr eax, 16
.blend:
    call k_px
.clear:
    add rdi, 4
    inc ecx
    cmp ecx, edx
    jb .px
    add r10, r14
    mov eax, [kit_pitch]
    add rbx, rax
    dec r15d
    jnz .row
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

kit_mono:
    push rbx
    push rcx
    push rdx
    push rsi
    mov rsi, [kit_mf]
    xor ecx, ecx
    xor ebx, ebx                        ; the nearest so far
    mov edx, 0x7FFFFFFF
.each:
    cmp ecx, [rsi + MFB_SIZES]
    jae .done
    mov eax, ecx
    shl eax, 4
    mov eax, [rsi + MFB_FONTS + rax + 12]
    sub eax, edi
    jns .abs
    neg eax
.abs:
    cmp eax, edx
    jae .next
    mov edx, eax
    mov ebx, ecx
.next:
    inc ecx
    jmp .each
.done:
    shl ebx, 4
    mov eax, [rsi + MFB_FONTS + rbx + 8]
    mov [kit_mcw], eax
    mov eax, [rsi + MFB_FONTS + rbx + 12]
    mov [kit_mch], eax
    mov rax, [rsi + MFB_FONTS + rbx]
    add rax, [kit_mfd]
    mov [kit_mglyphs], rax
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; k_mglyph(EAX = a code point) -> RAX = its cell's coverage, in the size
; kit_mono picked. Preserves others.
k_mglyph:
    push rcx
    push rdx
    push rsi
    push rdi
    lea ecx, [rax - 32]
    cmp ecx, 126 - 32
    jbe .index
    mov rsi, [kit_mfu]
    mov rdi, [kit_mf]
    mov edi, [rdi + MFB_UNIS]
    xor edx, edx
.halve:
    cmp edx, edi
    jae .none
    lea ecx, [rdx + rdi]
    shr ecx, 1
    cmp eax, [rsi + rcx * 8]
    je .hit
    jb .lower
    lea edx, [rcx + 1]
    jmp .halve
.lower:
    mov edi, ecx
    jmp .halve
.hit:
    mov eax, [rsi + rcx * 8 + 4]        ; the console's code for it
    lea ecx, [rax - 32]
    cmp ecx, 126 - 32
    jbe .index
    lea ecx, [rax - 128 + 95]
    cmp eax, 128
    jae .index
.none:
    mov ecx, '?' - 32
.index:
    imul ecx, [kit_mcw]
    imul ecx, [kit_mch]
    mov rax, [kit_mglyphs]
    add rax, rcx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

kit_mchar:
    cmp eax, ' '
    je .out
    push r8
    push r10
    push rdx
    push rcx
    call k_mglyph
    mov r10, rax
    mov edx, [kit_mcw]
    mov ecx, [kit_mch]
    mov r8d, r9d
    call k_cov
    pop rcx
    pop rdx
    pop r10
    pop r8
.out:
    ret

kit_mtext:
    push rbx
    push r12
    push r13
    lea rbx, [rsi + rcx]
    mov r12d, edi
    mov r13d, edx
.each:
    cmp rsi, rbx
    jae .done
    mov rdx, rbx
    call kit_utf8
    push rsi
    mov edi, r12d
    mov esi, r13d
    call kit_mchar
    pop rsi
    add r12d, [kit_mcw]
    jmp .each
.done:
    mov eax, r12d
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Controls
; -----------------------------------------------------------------------------

kit_button:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov rbx, r8                         ; RBX: its label
    mov ebp, r9d                        ; EBP: KB_*
    mov edi, 6
    call kit_pt
    mov [k_r], eax
    test ebp, KB_DEFAULT
    jz .plain
    call kit_accent
    mov r9d, eax
    jmp .fill
.plain:
    mov r9d, 0xFFFFFF                   ; white, or a lighter grey over dark
    call kit_dark
    jne .fill
    mov r9d, KA(0x38) | 0xFFFFFF
.fill:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [k_r]
    call kit_round
    test ebp, KB_DEFAULT
    jnz .edged
    call kit_dark                       ; an edge, in the light
    je .edged
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [k_r]
    mov r9d, KA(0x30)
    mov r10d, 1
    call kit_frame
.edged:
    test ebp, KB_DOWN                   ; held: darker
    jz .label
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [k_r]
    mov r9d, KA(0x28)
    call kit_round
.label:
    test rbx, rbx
    jz .out
    mov edi, 13
    mov esi, KF_REGULAR
    call kit_font
    mov [k_font], eax
    mov rdi, rbx                        ; its bytes
    call k_strlen
    mov [k_len], eax
    mov rsi, rbx
    mov ecx, eax
    mov edx, [k_font]
    call kit_text_w
    mov edi, r14d                       ; centred
    sub edi, eax
    sar edi, 1
    add edi, r12d
    push rdi
    mov edx, [k_font]
    mov esi, r13d
    mov ecx, r15d
    call kit_base
    mov edx, eax
    pop rdi
    mov r9d, 0xFFFFFF
    test ebp, KB_DEFAULT
    jnz .write
    push rdx
    push rdi
    mov edi, TC_TEXT
    test ebp, KB_OFF
    jz .on
    mov edi, TC_TEXT3
.on:
    call kit_c
    mov r9d, eax
    pop rdi
    pop rdx
.write:
    mov rsi, rbx
    mov ecx, [k_len]
    mov r8d, [k_font]
    call kit_text
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

kit_field:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebx, r8d
    mov edi, 6
    call kit_pt
    mov [k_r], eax
    mov r9d, 0xFFFFFF
    call kit_dark
    jne .fill
    mov r9d, KA(0x14) | 0xFFFFFF
.fill:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [k_r]
    call kit_round
    mov r9d, KA(0x30)                   ; its edge
    call kit_dark
    jne .edge
    mov r9d, KA(0x30) | 0xFFFFFF
.edge:
    mov edi, r12d
    mov esi, r13d
    mov edx, r14d
    mov ecx, r15d
    mov r8d, [k_r]
    mov r10d, 1
    call kit_frame
    test ebx, ebx                       ; the keys: a ring in the accent
    jz .out
    mov edi, 3
    call kit_pt
    mov ebx, eax
    call kit_accent
    and eax, 0x00FFFFFF
    or eax, KA(0x90)
    mov r9d, eax
    mov edi, r12d
    sub edi, ebx
    mov esi, r13d
    sub esi, ebx
    lea edx, [r14 + rbx * 2]
    lea ecx, [r15 + rbx * 2]
    mov r8d, [k_r]
    add r8d, ebx
    mov r10d, ebx
    call kit_frame
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

kit_scroller:
    push rbx
    push r12
    push r13
    push r14
    cmp r8d, ecx                        ; all of it shown: none
    jae .out
    test ecx, ecx
    jz .out
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov ebx, ecx
    mov eax, r14d                       ; the thumb: as long as the share shown
    imul eax, r8d
    xor edx, edx
    div ebx
    push rax
    mov edi, 28
    call kit_pt
    mov ecx, eax
    pop rax
    cmp eax, ecx
    jae .long
    mov eax, ecx
.long:
    cmp eax, r14d
    jbe .fits
    mov eax, r14d
.fits:
    push rax                            ; [rsp]: its length
    mov ecx, ebx                        ; where: as far as the first is
    sub ecx, r8d
    mov edx, r14d
    sub edx, eax
    mov eax, r9d
    cmp eax, ecx
    cmova eax, ecx
    imul eax, edx
    xor edx, edx
    div ecx
    add r13d, eax
    mov edi, 7
    call kit_pt
    mov edx, eax
    mov r9d, KA(0x70)
    call kit_dark
    jne .light
    mov r9d, KA(0x70) | 0xFFFFFF
.light:
    pop rcx
    mov edi, r12d
    mov esi, r13d
    mov r8d, edx
    shr r8d, 1
    call kit_round
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Memory, the clipboard
; -----------------------------------------------------------------------------

kit_alloc:
    mov eax, SYS_MEM_NEW
    syscall
    test rax, rax
    js .no
    push rax
    mov edi, eax
    mov eax, SYS_MAP
    syscall
    pop rdx
    test rax, rax
    js .no
    clc
    ret
.no:
    stc
    ret

kit_free:
    push rdi
    mov eax, SYS_UNMAP
    syscall
    pop rdi
    sub rsp, SQ_SIZE + 8
    mov r8d, edi
    call ax_entry
    mov byte [rsp + SQ_OP], RO_CLOSE
    mov [rsp + SQ_HANDLE], r8d
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE + 8
    ret

kit_cb_set:
    push rbx
    push r12
    mov rbx, rsi
    mov r12d, ecx
    cmp ecx, [kit_cb_cap]
    jbe .room
    lea edi, [rcx + 4095]               ; more room: a new block
    and edi, -4096
    push rdi
    call kit_alloc
    pop rdi
    jc .out
    push rdi
    push rax
    push rdx
    mov edi, [kit_cb_h]
    test edi, edi
    jz .first
    call kit_free
.first:
    pop rdx
    pop rax
    pop rdi
    mov [kit_cb], rax
    mov [kit_cb_h], edx
    mov [kit_cb_cap], edi
.room:
    mov rdi, [kit_cb]
    mov rsi, rbx
    mov ecx, r12d
    rep movsb
    mov [kit_cb_len], r12d
    clc
.out:
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  A line of text to edit: a field (KE_*, at R8)
; -----------------------------------------------------------------------------

; k_wordch(AL) -> ZF clear if it is part of a word: a letter, a digit, _,
; or not ASCII. Preserves all.
k_wordch:
    push rax
    cmp al, 0x80
    jae .yes
    cmp al, '_'
    je .yes
    or al, 0x20
    cmp al, 'a'
    jb .digit
    cmp al, 'z'
    jbe .yes
.digit:
    mov al, [rsp]
    cmp al, '0'
    jb .no
    cmp al, '9'
    jbe .yes
.no:
    cmp al, al                          ; ZF
    pop rax
    ret
.yes:
    test rsp, rsp                       ; ZF clear
    pop rax
    ret

; k_eback(RBX = a field, ECX = a place) -> ECX = the character before it.
; Preserves others.
k_eback:
    test ecx, ecx
    jz .out
    push rax
    push rdx
    mov rdx, [rbx + KE_BUF]
.back:
    dec ecx
    jz .done
    mov al, [rdx + rcx]
    and al, 0xC0
    cmp al, 0x80                        ; the middle of a character
    je .back
.done:
    pop rdx
    pop rax
.out:
    ret

; k_eforth(RBX, ECX) -> ECX = the character after it. Preserves others.
k_eforth:
    cmp ecx, [rbx + KE_LEN]
    jae .out
    push rax
    push rdx
    mov rdx, [rbx + KE_BUF]
.forth:
    inc ecx
    cmp ecx, [rbx + KE_LEN]
    jae .done
    mov al, [rdx + rcx]
    and al, 0xC0
    cmp al, 0x80
    je .forth
.done:
    pop rdx
    pop rax
.out:
    ret

; k_eword_back, k_eword_forth(RBX, ECX) -> ECX = the start of the word
; before it, the end of the word after it. Preserves others.
k_eword_back:
    push rax
    push rdx
    mov rdx, [rbx + KE_BUF]
.spaces:
    test ecx, ecx
    jz .out
    mov al, [rdx + rcx - 1]
    call k_wordch
    jnz .word
    dec ecx
    jmp .spaces
.word:
    test ecx, ecx
    jz .out
    mov al, [rdx + rcx - 1]
    call k_wordch
    jz .out
    dec ecx
    jmp .word
.out:
    pop rdx
    pop rax
    ret

k_eword_forth:
    push rax
    push rdx
    mov rdx, [rbx + KE_BUF]
.spaces:
    cmp ecx, [rbx + KE_LEN]
    jae .out
    mov al, [rdx + rcx]
    call k_wordch
    jnz .word
    inc ecx
    jmp .spaces
.word:
    cmp ecx, [rbx + KE_LEN]
    jae .out
    mov al, [rdx + rcx]
    call k_wordch
    jz .out
    inc ecx
    jmp .word
.out:
    pop rdx
    pop rax
    ret

; k_ecut(RBX): what is chosen, gone; the caret where it was
k_ecut:
    mov eax, [rbx + KE_CARET]
    mov ecx, [rbx + KE_ANCHOR]
    cmp eax, ecx
    je .out
    jb .ordered
    xchg eax, ecx
.ordered:                               ; EAX..ECX goes
    mov rdi, [rbx + KE_BUF]
    lea rsi, [rdi + rcx]
    add rdi, rax
    mov edx, [rbx + KE_LEN]
    sub edx, ecx
    sub [rbx + KE_LEN], ecx
    add [rbx + KE_LEN], eax
    mov [rbx + KE_CARET], eax
    mov [rbx + KE_ANCHOR], eax
    mov ecx, edx
    rep movsb
.out:
    ret

; k_einsert(RBX, RSI = bytes, ECX = how many): in place of what is chosen,
; as many as there is room for
k_einsert:
    push r12
    push r13
    mov r12, rsi
    mov r13d, ecx
    call k_ecut
    mov eax, [rbx + KE_CAP]
    sub eax, [rbx + KE_LEN]
    cmp r13d, eax
    cmova r13d, eax
    test r13d, r13d
    jz .out
    mov rdi, [rbx + KE_BUF]             ; what follows moves along
    mov ecx, [rbx + KE_LEN]
    sub ecx, [rbx + KE_CARET]
    mov eax, [rbx + KE_LEN]
    lea rsi, [rdi + rax - 1]
    lea rdi, [rsi + r13]
    std
    rep movsb
    cld
    mov rdi, [rbx + KE_BUF]
    mov eax, [rbx + KE_CARET]
    add rdi, rax
    mov rsi, r12
    mov ecx, r13d
    rep movsb
    add [rbx + KE_LEN], r13d
    add [rbx + KE_CARET], r13d
    mov eax, [rbx + KE_CARET]
    mov [rbx + KE_ANCHOR], eax
.out:
    pop r13
    pop r12
    ret

kit_eset:
    push rbx
    mov rbx, r8
    cmp ecx, [rbx + KE_CAP]
    jbe .fits
    mov ecx, [rbx + KE_CAP]
.fits:
    mov [rbx + KE_LEN], ecx
    mov [rbx + KE_CARET], ecx
    mov dword [rbx + KE_ANCHOR], 0
    mov dword [rbx + KE_SCROLL], 0
    mov rdi, [rbx + KE_BUF]
    rep movsb
    pop rbx
    ret

kit_ekey:
    push rbx
    push r12
    push r13
    mov rbx, r8
    mov r12d, eax                       ; R12D: the key
    mov r13d, edx                       ; R13D: the modifiers
    test r13d, WM_CTRL | WM_META
    jz .plain
    cmp r12d, 1                         ; ctrl+A: all of it
    je .all
    cmp r12d, 3                         ; ctrl+C, X, V
    je .copy
    cmp r12d, 24
    je .cut
    cmp r12d, 22
    je .paste
.plain:
    cmp r12d, 8
    je .backspace
    cmp r12d, K_DEL
    je .delete
    cmp r12d, K_LEFT
    je .left
    cmp r12d, K_RIGHT
    je .right
    cmp r12d, K_HOME
    je .home
    cmp r12d, K_END
    je .end
    test r13d, WM_CTRL | WM_META | WM_ALT
    jnz .not_ours
    cmp r12d, ' '
    jb .not_ours
    cmp r12d, '~'
    ja .not_ours
    mov [k_char], r12b
    lea rsi, [k_char]
    mov ecx, 1
    call k_einsert
    jmp .ours
.all:
    mov dword [rbx + KE_ANCHOR], 0
    mov eax, [rbx + KE_LEN]
    mov [rbx + KE_CARET], eax
    jmp .ours
.copy:
    call k_echosen
    jz .ours
    call kit_cb_set
    jmp .ours
.cut:
    call k_echosen
    jz .ours
    call kit_cb_set
    call k_ecut
    jmp .ours
.paste:
    mov rsi, [kit_cb]
    mov ecx, [kit_cb_len]
    test ecx, ecx
    jz .ours
    xor edx, edx                        ; a line: up to its end
.line:
    cmp edx, ecx
    jae .pasted
    cmp byte [rsi + rdx], 10
    je .pasted
    cmp byte [rsi + rdx], 13
    je .pasted
    inc edx
    jmp .line
.pasted:
    mov ecx, edx
    call k_einsert
    jmp .ours
.backspace:
    mov eax, [rbx + KE_CARET]
    cmp eax, [rbx + KE_ANCHOR]
    jne .cut_chosen
    mov ecx, eax
    test r13d, WM_ALT | WM_CTRL
    jz .back_one
    call k_eword_back
    jmp .back_set
.back_one:
    call k_eback
.back_set:
    mov [rbx + KE_ANCHOR], ecx
.cut_chosen:
    call k_ecut
    jmp .ours
.delete:
    mov eax, [rbx + KE_CARET]
    cmp eax, [rbx + KE_ANCHOR]
    jne .cut_chosen
    mov ecx, eax
    test r13d, WM_ALT | WM_CTRL
    jz .del_one
    call k_eword_forth
    jmp .del_set
.del_one:
    call k_eforth
.del_set:
    mov [rbx + KE_ANCHOR], ecx
    jmp .cut_chosen
.left:
    mov ecx, [rbx + KE_CARET]
    test r13d, WM_SHIFT
    jnz .left_move
    cmp ecx, [rbx + KE_ANCHOR]          ; what was chosen: to its start
    je .left_move
    cmova ecx, [rbx + KE_ANCHOR]
    jmp .place
.left_move:
    test r13d, WM_META
    jnz .home
    test r13d, WM_ALT | WM_CTRL
    jz .left_one
    call k_eword_back
    jmp .moved
.left_one:
    call k_eback
    jmp .moved
.right:
    mov ecx, [rbx + KE_CARET]
    test r13d, WM_SHIFT
    jnz .right_move
    cmp ecx, [rbx + KE_ANCHOR]
    je .right_move
    cmovb ecx, [rbx + KE_ANCHOR]
    jmp .place
.right_move:
    test r13d, WM_META
    jnz .end
    test r13d, WM_ALT | WM_CTRL
    jz .right_one
    call k_eword_forth
    jmp .moved
.right_one:
    call k_eforth
    jmp .moved
.home:
    xor ecx, ecx
    jmp .moved
.end:
    mov ecx, [rbx + KE_LEN]
.moved:
    mov [rbx + KE_CARET], ecx
    test r13d, WM_SHIFT
    jnz .ours
.place:
    mov [rbx + KE_CARET], ecx
    mov [rbx + KE_ANCHOR], ecx
.ours:
    mov dword [kit_caret], 1            ; seen at once, as it moves
    clc
    jmp .out
.not_ours:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; k_echosen(RBX) -> RSI, ECX = what is chosen; ZF if nothing is
k_echosen:
    mov eax, [rbx + KE_CARET]
    mov ecx, [rbx + KE_ANCHOR]
    cmp eax, ecx
    jbe .ordered
    xchg eax, ecx
.ordered:
    sub ecx, eax
    mov rsi, [rbx + KE_BUF]
    add rsi, rax
    test ecx, ecx
    ret

kit_edraw:
    push rbx
    push rbp
    push r12
    push r13
    push r14
    push r15
    sub rsp, 32
    mov rbx, r8
    mov r12d, edi
    mov r13d, esi
    mov r14d, edx
    mov r15d, ecx
    mov ebp, r9d                        ; EBP: the font
    mov [rsp + 16], r10d                ; whether it has the keys
    mov r8d, r10d
    call kit_field
    mov edi, 7
    call kit_pt
    mov [rsp + 20], eax                 ; [rsp + 20]: its padding
    mov rsi, [rbx + KE_BUF]             ; the caret, from its start
    mov ecx, [rbx + KE_CARET]
    mov edx, ebp
    call kit_text_w
    mov [rsp + 24], eax
    mov ecx, r14d                       ; scrolled to keep the caret in it
    sub ecx, [rsp + 20]
    sub ecx, [rsp + 20]
    sub ecx, [rbx + KE_INDENT]
    sub ecx, 2
    mov edx, eax
    sub edx, [rbx + KE_SCROLL]
    cmp edx, ecx
    jle .not_past
    sub eax, ecx
    mov [rbx + KE_SCROLL], eax
.not_past:
    mov eax, [rsp + 24]
    cmp eax, [rbx + KE_SCROLL]
    jge .scrolled
    mov [rbx + KE_SCROLL], eax
.scrolled:
    mov eax, [kit_cx0]                  ; the clip, kept
    mov [rsp], eax
    mov eax, [kit_cy0]
    mov [rsp + 4], eax
    mov eax, [kit_cx1]
    mov [rsp + 8], eax
    mov eax, [kit_cy1]
    mov [rsp + 12], eax
    mov edi, r12d                       ; and narrowed to the text
    add edi, [rsp + 20]
    add edi, [rbx + KE_INDENT]
    mov esi, r13d
    mov edx, r14d
    sub edx, [rsp + 20]
    sub edx, [rsp + 20]
    sub edx, [rbx + KE_INDENT]
    mov ecx, r15d
    call k_narrow
    mov eax, r12d                       ; where the text begins
    add eax, [rsp + 20]
    add eax, [rbx + KE_INDENT]
    sub eax, [rbx + KE_SCROLL]
    mov [rbx + KE_X], eax
    mov rsi, rbx                        ; what is chosen, behind it
    push rbx
    mov rbx, rsi
    call k_echosen
    pop rbx
    jz .text
    mov [rsp + 28], ecx
    mov rdx, rsi                        ; its start, from the text's
    sub rdx, [rbx + KE_BUF]
    mov ecx, edx
    mov rsi, [rbx + KE_BUF]
    mov edx, ebp
    push rsi
    push rcx
    call kit_text_w
    pop rcx
    pop rsi
    mov r9d, eax                        ; R9D: where it begins
    add rsi, rcx
    mov ecx, [rsp + 28]
    mov edx, ebp
    push r9
    call kit_text_w
    pop r9
    mov edx, eax                        ; its width
    mov edi, [rbx + KE_X]
    add edi, r9d
    mov edx, eax
    push rdi
    push rdx
    mov edi, 3
    call kit_pt
    mov esi, r13d
    add esi, eax
    mov ecx, r15d
    sub ecx, eax
    sub ecx, eax
    pop rdx
    pop rdi
    push rdi
    push rsi
    push rdx
    push rcx
    call kit_accent
    and eax, 0x00FFFFFF
    or eax, KA(0x60)
    cmp dword [rsp + 32 + 16], 0
    jne .chosen
    mov eax, KA(0x30) | 0x808080        ; not with the keys: grey
.chosen:
    mov r8d, eax
    pop rcx
    pop rdx
    pop rsi
    pop rdi
    call kit_fill
.text:
    mov edx, ebp                        ; the text
    mov esi, r13d
    mov ecx, r15d
    call kit_base
    mov edx, eax
    mov edi, TC_TEXT
    call kit_c
    mov r9d, eax
    mov rsi, [rbx + KE_BUF]
    mov ecx, [rbx + KE_LEN]
    mov edi, [rbx + KE_X]
    mov r8d, ebp
    call kit_text
    cmp dword [rsp + 16], 0             ; the caret
    je .clip_back
    cmp dword [kit_caret], 0
    je .clip_back
    mov edx, ebp
    call kit_line
    mov ecx, eax
    mov esi, r15d
    sub esi, ecx
    sar esi, 1
    add esi, r13d
    mov edi, [rbx + KE_X]
    add edi, [rsp + 24]
    push rcx
    push rdi
    push rsi
    mov edi, 2
    call kit_pt
    mov edx, eax
    shr edx, 1
    jnz .wide
    mov edx, 1
.wide:
    call kit_accent
    mov r8d, eax
    pop rsi
    pop rdi
    pop rcx
    call kit_fill
.clip_back:
    mov eax, [rsp]
    mov [kit_cx0], eax
    mov eax, [rsp + 4]
    mov [kit_cy0], eax
    mov eax, [rsp + 8]
    mov [kit_cx1], eax
    mov eax, [rsp + 12]
    mov [kit_cy1], eax
    add rsp, 32
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbp
    pop rbx
    ret

; k_narrow(EDI, ESI, EDX, ECX): the clip, inside that too
k_narrow:
    call k_cliprect
    jnc .set
    xor edi, edi
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
.set:
    mov [kit_cx0], edi
    mov [kit_cy0], esi
    mov [kit_cx1], edx
    mov [kit_cy1], ecx
    ret

kit_eclick:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, r8
    mov r12d, edi
    sub r12d, [rbx + KE_X]              ; R12D: from where the text begins
    mov r13d, esi                       ; R13D: 1 to stretch what is chosen
    mov r15d, r9d
    xor r14d, r14d                      ; R14D: the place so far
.each:
    cmp r14d, [rbx + KE_LEN]
    jae .found
    mov ecx, r14d
    call k_eforth
    push rcx
    mov rsi, [rbx + KE_BUF]             ; the middle of the next character
    mov edx, r15d
    push rcx
    mov ecx, r14d
    call kit_text_w
    mov r8d, eax
    pop rcx
    mov rsi, [rbx + KE_BUF]
    mov edx, r15d
    push r8
    call kit_text_w
    pop r8
    add eax, r8d
    shr eax, 1
    pop rcx
    cmp r12d, eax
    jl .found
    mov r14d, ecx
    jmp .each
.found:
    mov [rbx + KE_CARET], r14d
    test r13d, r13d
    jnz .out
    mov [rbx + KE_ANCHOR], r14d
.out:
    mov dword [kit_caret], 1
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; k_strlen(RDI = NUL-ended) -> EAX = its bytes. Preserves others.
k_strlen:
    xor eax, eax
.each:
    cmp byte [rdi + rax], 0
    je .out
    inc eax
    jmp .each
.out:
    ret

section .rodata
align 4
k_half255:      dd 127.5                ; half pixels to 0..255
k_16th:         dd 0.0625
k_half:         dd 0.5
k_one:          dd 1.0
k_255:          dd 255.0

section .bss
alignb 8
kit_lk:         resq 1                  ; the look, mapped
kit_uf:         resq 1                  ; its desktop font (UFB_*)
kit_ufd:        resq 1                  ; that font's glyphs and coverage
kit_ufu:        resq 1                  ; its code points
kit_mf:         resq 1                  ; the monospaced font (MFB_*)
kit_mfd:        resq 1
kit_mfu:        resq 1
kit_mglyphs:    resq 1                  ; the cells of the size picked
kit_px:         resq 1                  ; the window's pixels
k_deadline:     resq 1
kit_click_t:    resq 1                  ; the last press: when, where, which
kit_click_x:    resd 1
kit_click_y:    resd 1
kit_click_b:    resd 1
kit_clicks:     resd 1                  ; presses in a row, close together
kit_pitch:      resd 1                  ; bytes a row
kit_w:          resd 1                  ; its size now
kit_h:          resd 1
kit_s4:         resd 1                  ; quarters of a pixel a point
kit_serial:     resd 1                  ; the look's, when last read
kit_win:        resd 1
kit_end:        resd 1                  ; the channel's, what the window says
kit_cx0:        resd 1                  ; the clip
kit_cy0:        resd 1
kit_cx1:        resd 1
kit_cy1:        resd 1
kit_mcw:        resd 1                  ; the monospaced cell
kit_mch:        resd 1
kit_ev:         resb WE_SIZE
k_thick:        resd 1
k_spread:       resd 1
k_dark:         resd 1
k_r:            resd 1
k_font:         resd 1
k_len:          resd 1
k_sx0:          resd 1
k_sx1:          resd 1
kit_caret:      resd 1                  ; 1 while the caret shows
kit_cb:         resq 1                  ; the clipboard: what was copied
kit_cb_len:     resd 1
kit_cb_cap:     resd 1
kit_cb_h:       resd 1
k_char:         resb 4
