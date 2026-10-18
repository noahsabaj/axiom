; =============================================================================
;  look.asm - how the desktop looks, shared with programs
;
;  One block of memory (look_mem), made once: the theme's colors, the
;  accent, the scale and the screen's size (LK_*), then the fonts the
;  desktop draws in, Noto Sans (UFB_*) and Cascadia Mono (MFB_*), with the
;  tables that find a glyph. A program asks for it with RO_DESK_LOOK (a
;  handle to the desktop) and maps it, read only; when the theme changes,
;  look_update writes it again, counts LK_SERIAL up, and every program's
;  window is sent WE_LOOK.
; =============================================================================

; where things are: the desktop's font from LK_HEAD, the monospaced one
; after its coverage
LKU_UNI         equ (UFB_FONTS + UF_WEIGHTS * UF_SIZES * UFT_SIZE + 15) & ~15
LKU_DATA        equ (LKU_UNI + UF_UNI * 8 + 15) & ~15
LKM_UNI         equ (MFB_FONTS + FONT_SIZES * 16 + 15) & ~15
LKM_DATA        equ (LKM_UNI + FONT_UNICODE * 8 + 15) & ~15

section .text

; look_make: the look, made (at boot, once the kernel's task is). Nothing if there
; is no memory for it: programs then draw without it.
look_make:
    push rbx
    push r12
    push r13
    push r14
    mov r12, uifont_end - uifont_data   ; R12: the desktop font's coverage
    lea r13, [r12 + LK_HEAD + LKU_DATA + 15]
    and r13, ~15                        ; R13: where the monospaced font goes
    lea rdi, [r13 + LKM_DATA]
    add rdi, font_end - font_data
    lea rsi, [str_look]
    call mem_new
    test rax, rax
    jz .out
    mov [look_mem], rax
    mov rbx, [rax + MO_BASE]            ; RBX: the look
    lea r14, [rbx + LK_HEAD]            ; the desktop's font
    mov dword [rbx + LK_UF], LK_HEAD
    mov dword [r14 + UFB_WEIGHTS], UF_WEIGHTS
    mov dword [r14 + UFB_SIZES], UF_SIZES
    mov dword [r14 + UFB_UNIS], UF_UNI
    mov dword [r14 + UFB_UNI], LKU_UNI
    mov dword [r14 + UFB_DATA], LKU_DATA
    lea rsi, [uf_size_px]
    lea rdi, [r14 + UFB_PX]
    mov ecx, UF_SIZES
    rep movsb
    lea rsi, [uf_fonts]
    lea rdi, [r14 + UFB_FONTS]
    mov ecx, UF_WEIGHTS * UF_SIZES * UFT_SIZE
    rep movsb
    lea rsi, [uf_uni]
    lea rdi, [r14 + LKU_UNI]
    mov ecx, UF_UNI * 8
    rep movsb
    lea rsi, [uifont_data]
    lea rdi, [r14 + LKU_DATA]
    mov rcx, r12
    rep movsb
    lea r14, [rbx + r13]                ; the monospaced one
    mov [rbx + LK_MONO], r13d
    mov dword [r14 + MFB_SIZES], FONT_SIZES
    mov dword [r14 + MFB_UNIS], FONT_UNICODE
    mov dword [r14 + MFB_UNI], LKM_UNI
    mov dword [r14 + MFB_DATA], LKM_DATA
    lea rsi, [font_sizes]
    lea rdi, [r14 + MFB_FONTS]
    mov ecx, FONT_SIZES * 16
    rep movsb
    lea rsi, [font_unicode]
    lea rdi, [r14 + LKM_UNI]
    mov ecx, FONT_UNICODE * 8
    rep movsb
    lea rsi, [font_data]
    lea rdi, [r14 + LKM_DATA]
    mov rcx, font_end - font_data
    rep movsb
    call look_update
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; look_update: the look as the theme has it now, and programs' windows told
; (WE_LOOK). The main thread's. Preserves all.
look_update:
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
    mov rax, [look_mem]
    test rax, rax
    jz .out
    mov rdi, [rax + MO_BASE]
    mov eax, [ui_s4]
    mov [rdi + LK_S4], eax
    movzx eax, byte [th_mode]
    mov [rdi + LK_MODE], eax
    mov eax, [th_accent]
    mov [rdi + LK_ACCENT], eax
    mov rax, [scr_w]
    mov [rdi + LK_SCR_W], eax
    mov rax, [scr_h]
    mov [rdi + LK_SCR_H], eax
    mov rbx, rdi
    lea rsi, [th_c]
    lea rdi, [rbx + LK_C]
    mov ecx, TC_COUNT
    rep movsb
    lock inc dword [rbx + LK_SERIAL]
    xor r12d, r12d                      ; each program's window
.window:
    cmp r12d, DESK_MAX
    jae .out
    lea rax, [desk_wins]
    mov rbx, [rax + r12 * 8]
    inc r12d
    test rbx, rbx
    jz .window
    test dword [rbx + WN_FLAGS], WF_PROGRAM
    jz .window
    cmp qword [rbx + WN_DATA], 0
    je .window
    mov edi, WE_LOOK
    xor esi, esi
    xor edx, edx
    xor ecx, ecx
    call wo_post
    jmp .window
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
    pop rax
    ret

; h_desk_look(EDI = the desktop) -> RAX = a handle to the look, to read and
; map (needs RT_DESK_WINDOW)
h_desk_look:
    mov esi, OT_DESK
    mov edx, RT_DESK_WINDOW
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call obj_put
    mov rax, E_NOMEM
    mov rdi, [look_mem]
    test rdi, rdi
    jz .out
    call obj_get                        ; the handle's reference
    mov esi, RT_MEM_READ | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .out
    push rax
    mov rdi, [look_mem]
    call obj_put
    pop rax
.out:
    call op_done
    ret

section .rodata
str_look:       db 'look', 0

section .bss
alignb 8
look_mem:       resq 1                  ; the look's memory, a reference
