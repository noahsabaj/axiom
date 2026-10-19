; =============================================================================
;  ui.asm - the first windows on the desk (desk.asm): the first shell, the
;  system's facts, one tile per logical processor, the demo; the bar's
;  telemetry; and the panic screen. Everything is laid out in font cells
;  so it scales from 1280x800 to 4K.
; =============================================================================

SYS_LINES       equ 13
INFO_LEN        equ 160

; measures, in points
UI_PAD          equ 12                  ; a window's content from its edges
CARD_IN         equ 10                  ; text from a card's edges
CARD_R          equ 8                   ; a card's corners
SYS_ROW         equ 19                  ; a row of System's card
LABEL_W         equ 84                  ; its labels' column
TILE_W          equ 150                 ; a processor's tile
TILE_H          equ 46
TILE_GAP        equ 8

section .text

; -----------------------------------------------------------------------------
;  Text helpers. They keep RBX, RBP and R12-R15; everything else is scratch.
; -----------------------------------------------------------------------------

; ui_text(RDI x, RSI y, RDX str, ECX fg, R8D bg) -> RAX = x after the text
ui_text:
    mov r9, -1
; ui_text_max(..., R9 = most characters to draw)
ui_text_max:
    push rbx
    push r12
    push r13
    push r14
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov rbx, r9
    mov edi, ecx
    mov esi, r8d
    call gfx_color
.next:
    test rbx, rbx
    jz .done
    movzx edx, byte [r14]
    test edx, edx
    jz .done
    mov rdi, r12
    mov rsi, r13
    call gfx_glyph
    add r12, [font_cw]
    inc r14
    dec rbx
    jmp .next
.done:
    mov rax, r12
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ui_text_right(RDI right edge, RSI y, RDX str, ECX fg, R8D bg) -> RAX = left x
ui_text_right:
    push rdi
    push rdx
    push rcx
    mov rdi, rdx
    call strlen
    imul rax, [font_cw]
    pop rcx
    pop rdx
    pop rdi
    sub rdi, rax
    push rdi
    call ui_text
    pop rax
    ret

; ui_panel(RDI x, RSI y, RDX w, RCX h, R8 title or 0)
ui_panel:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12, rdi
    mov r13, rsi
    mov r14, rdx
    mov r15, rcx
    mov rbx, r8
    mov r8d, COL_LINE                   ; border
    call gfx_fill
    mov rax, [ui_line]
    lea rdi, [r12 + rax]
    lea rsi, [r13 + rax]
    mov rdx, r14
    sub rdx, rax
    sub rdx, rax
    mov rcx, r15
    sub rcx, rax
    sub rcx, rax
    mov r8d, COL_PANEL
    call gfx_fill
    test rbx, rbx
    jz .done
    mov rdi, r12                        ; accent mark, then the title
    mov rsi, [font_ch]
    shr rsi, 2
    add rsi, r13
    mov rdx, [ui_line]
    imul rdx, rdx, 3
    mov rcx, [font_ch]
    mov r8d, COL_ACCENT
    call gfx_fill
    mov rdi, [font_cw]
    add rdi, r12
    mov rsi, [font_ch]
    shr rsi, 2
    add rsi, r13
    mov rdx, rbx
    mov ecx, COL_DIM
    mov r8d, COL_PANEL
    call ui_text
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  ui_init: header, system and console panels, then the console itself
; -----------------------------------------------------------------------------
ui_init:
    push rbx
    mov rax, [font_ch]                  ; line width: 1 px per 20 px of text
    xor edx, edx
    mov ecx, 20
    div rcx
    test rax, rax
    jnz .line_ok
    inc eax
.line_ok:
    mov [ui_line], rax
    call theme_init                     ; the scale, the look
    call desk_metrics                   ; the bar, the title bars, the dock
    mov rax, [m_bar_h]                  ; the windows: between the bar and
    add rax, [m_gap]                    ; the dock
    mov [body_y], rax
    mov rax, [m_work_y1]
    sub rax, [m_gap]
    mov [body_bottom], rax

    mov rax, [scr_w]                    ; left column: 36%
    mov rcx, [m_gap]
    imul rcx, rcx, 3
    sub rax, rcx
    imul rax, rax, 36
    xor edx, edx
    mov ecx, 100
    div rcx
    mov [left_w], rax
    mov rcx, [m_gap]
    mov [sys_x], rcx
    lea rdx, [rcx * 2 + rax]
    mov [right_x], rdx
    mov rax, [scr_w]
    sub rax, rdx
    sub rax, rcx
    mov [right_w], rax

    mov rax, [body_y]
    mov [sys_y], rax
    call ui_measures
    mov rax, [ui_row]                   ; System: its card, padded
    imul rax, rax, SYS_LINES
    mov rcx, [ui_pad]
    lea rax, [rax + rcx * 2]
    add rax, [title_h]
    mov [sys_h], rax
    add rax, [sys_y]
    add rax, [m_gap]
    mov [conp_y], rax
    mov rdx, [body_bottom]
    sub rdx, rax
    mov [conp_h], rdx

    call desk_init                      ; the desk, and the first shell
    mov rdi, [sys_x]                    ; where the console was
    mov rsi, [conp_y]
    mov rdx, [left_w]
    sub rdx, [fr_b]
    sub rdx, [fr_b]
    mov rcx, [conp_h]
    sub rcx, [fr_t]
    sub rcx, [fr_b]
    sub rcx, [fr_b]
    call term_open
    mov [con_first], rax
    pop rbx
    ret

; ui_client(R8 x, R9 y, RDX w, RCX h of a frame) -> RDX, RCX: its client's
; size. Preserves others.
ui_client:
    sub rdx, [fr_b]
    sub rdx, [fr_b]
    sub rcx, [fr_t]
    sub rcx, [fr_b]
    sub rcx, [fr_b]
    ret

; -----------------------------------------------------------------------------
;  ui_ready: once every CPU is up - processor tiles, demo view, system facts
; -----------------------------------------------------------------------------
ui_ready:
    push rbx
    push r12
    call ui_measures                    ; tile geometry
    mov rax, [right_w]                  ; columns that fit
    sub rax, [ui_pad]
    sub rax, [ui_pad]
    add rax, [tile_gap_x]
    mov rcx, [tile_w]
    add rcx, [tile_gap_x]
    xor edx, edx
    div rcx
    test rax, rax
    jnz .cols_ok
    inc eax
.cols_ok:
    mov [tile_cols], rax
    mov rcx, rax
    mov eax, [cpu_count]                ; rows needed
    add rax, rcx
    dec rax
    xor edx, edx
    div rcx
    mov rcx, [tile_h]
    add rcx, [tile_gap_y]
    imul rax, rcx
    sub rax, [tile_gap_y]
    mov rcx, [ui_pad]
    lea rax, [rax + rcx * 2]
    add rax, [title_h]
    mov [cores_h], rax
    mov rcx, [body_y]
    add rcx, rax
    add rcx, [m_gap]
    mov [demo_y], rcx
    mov rax, [body_bottom]
    sub rax, rcx
    mov [demo_h], rax

    call ui_system_info
    lea rdi, [sys_ops]                  ; the windows, where the panels were
    lea rsi, [str_t_system]
    mov r8, [sys_x]
    mov r9, [sys_y]
    mov rdx, [left_w]
    mov rcx, [sys_h]
    call ui_client
    mov r10d, WF_RESIZE
    lea r11, [str_app_system]
    call win_new
    mov [sys_win], rax
    lea rdi, [cpu_ops]
    lea rsi, [str_t_processors]
    mov r8, [right_x]
    mov r9, [body_y]
    mov rdx, [right_w]
    mov rcx, [cores_h]
    call ui_client
    mov r10d, WF_RESIZE
    lea r11, [str_app_system]
    call win_new
    mov [cpu_win], rax
    lea rdi, [demo_base]                ; the demo's title
    cmp byte [mandel_ok], 0
    je .no_avx
    mov eax, [cpus_online]
    SPRINTF rdi, {"Mandelbrot ", G_MIDDOT, " AVX2 + FMA ", G_MIDDOT, " %u threads"}, rax
    jmp .demo
.no_avx:
    SPRINTF rdi, "Mandelbrot (needs AVX2 + FMA)"
.demo:
    lea rdi, [demo_ops]
    lea rsi, [demo_base]
    mov r8, [right_x]
    mov r9, [demo_y]
    mov rdx, [right_w]
    mov rcx, [demo_h]
    call ui_client
    mov r10d, WF_RESIZE
    lea r11, [str_app_mandel]
    call win_new
    mov [demo_win], rax
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The demo's window
; -----------------------------------------------------------------------------

; demo_paint (OP_PAINT, RBX = window): black, and the view that size
demo_paint:
    lea rdi, [rbx + WN_SF]
    call gfx_target
    xor edi, edi
    xor esi, esi
    mov rdx, [rbx + WN_W]
    mov rcx, [rbx + WN_H]
    mov r8d, MANDEL_INSIDE
    call gfx_fill
    call gfx_target_back
    mov rdi, [rbx + WN_SF + SF_PTR]
    mov rsi, [rbx + WN_SF + SF_PITCH]
    mov rdx, [rbx + WN_W]
    mov rcx, [rbx + WN_H]
    call mandel_set_view
    mov byte [mandel_dirty], 1
    ret

; demo_click (OP_CLICK): a button pressed acts on the view
demo_click:
    test ecx, ecx
    jz .out
    jmp mandel_click
.out:
    ret

; demo_wheel (OP_WHEEL)
demo_wheel:
    jmp mandel_wheel

; mandel_show: a frame was drawn into the window
mandel_show:
    mov rdi, [demo_win]
    test rdi, rdi
    jz .out
    jmp win_damage_all
.out:
    ret

; ui_demo_shown -> ZF clear if the demo's window is on the screen
ui_demo_shown:
    mov rax, [demo_win]
    test rax, rax
    jz .out
    test dword [rax + WN_FLAGS], WF_SHOWN
.out:
    ret
; -----------------------------------------------------------------------------
;  System facts: composed once into info_lines, drawn into the system panel
; -----------------------------------------------------------------------------
%macro INFO 1                           ; INFO n: RDI = buffer of line n
    lea rdi, [info_lines + %1 * INFO_LEN]
%endmacro

ui_system_info:
    push rbx
    push r12
    push r13

    INFO 0                              ; machine
    cmp byte [sm_sys_product], 0
    je .no_smbios
    lea rax, [sm_sys_vendor]
    lea rdx, [sm_sys_product]
    SPRINTF rdi, "%s %s", rax, rdx
    jmp .firmware
.no_smbios:
    SPRINTF rdi, "unknown (no SMBIOS)"
.firmware:
    INFO 1
    mov rbx, [boot_info]
    mov eax, [rbx + BI_UEFI_REV]
    mov edx, eax
    shr eax, 16
    and edx, 0xFFFF
    lea rcx, [sm_bios_vendor]
    cmp byte [rcx], 0
    jne .have_bios
    lea rcx, [rbx + BI_FW_VENDOR]
.have_bios:
    lea r8, [sm_bios_version]
    lea r9, [sm_bios_date]
    SPRINTF rdi, {"%s %s %s ", G_MIDDOT, " UEFI %u.%u"}, rcx, r8, r9, rax, rdx

    INFO 2                              ; processor
    lea rax, [cpu_brand]
    SPRINTF rdi, "%s", rax

    INFO 3                              ; cores
    mov rax, [smp_us]
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r8, rax                         ; bring-up, tenths of a ms
    mov eax, [cpus_online]
    mov ecx, [cpu_count]
    mov rdx, [count_p]
    or rdx, [count_e]
    jz .plain_cores
    SPRINTF rdi, {"%u P-cores + %u E-cores ", G_MIDDOT, " %u of %u threads up in %t ms"}, qword [count_p], qword [count_e], rax, rcx, r8
    jmp .clocks
.plain_cores:
    SPRINTF rdi, {"%u cores ", G_MIDDOT, " %u of %u threads up in %t ms"}, qword [count_other], rax, rcx, r8

.clocks:
    INFO 4
    call power_bias_name                ; 0 without HWP
    test rax, rax
    jnz .hwp_done
    lea rax, [str_off]
.hwp_done:
    lea rdx, [str_xapic]
    cmp byte [lapic_x2], 0
    je .apic_done
    lea rdx, [str_x2apic]
.apic_done:
    SPRINTF rdi, {"TSC %u MHz ", G_MIDDOT, " HWP %s ", G_MIDDOT, " %s"}, qword [tsc_mhz], rax, rdx

    INFO 5                              ; memory
    mov rax, [pmm_free_pages]
    shl rax, 12
    mov rcx, [sm_mem_total_mb]
    test rcx, rcx
    jz .mem_plain
    shl rcx, 20
    push rax
    call smbios_mem_type_name
    mov rdx, rax
    pop rax
    mov r8d, [sm_mem_speed]
    mov r9d, [sm_mem_modules]
    lea r10, [str_plural_s]             ; "1 module", "4 modules"
    cmp r9d, 1
    jne .plural
    lea r10, [str_plural_s + 1]
.plural:
    test r8d, r8d
    jz .mem_nospeed
    SPRINTF rdi, {"%b %s-%u ", G_MIDDOT, " %u module%s ", G_MIDDOT, " %b free"}, rcx, rdx, r8, r9, r10, rax
    jmp .display
.mem_nospeed:
    SPRINTF rdi, {"%b %s ", G_MIDDOT, " %u module%s ", G_MIDDOT, " %b free"}, rcx, rdx, r9, r10, rax
    jmp .display
.mem_plain:
    SPRINTF rdi, {"%b usable ", G_MIDDOT, " %b free"}, qword [pmm_usable_bytes], rax

.display:
    INFO 6
    mov eax, [rbx + BI_GOP_MODE]
    mov ecx, [rbx + BI_GOP_MODES]
    SPRINTF rdi, {"%u", G_TIMES, "%u ", G_MIDDOT, " GOP mode %u of %u ", G_MIDDOT, " write-combining"}, qword [scr_w], qword [scr_h], rax, rcx

    INFO 7                              ; ACPI: revision and table list
    lea r12, [ui_buf2]
    xor ecx, ecx
    lea rdx, [acpi_table_sigs]
.sig:
    cmp ecx, [acpi_table_count]
    jae .sigs_done
    mov eax, [rdx + rcx * 4]
    mov [r12], eax
    mov byte [r12 + 4], ' '
    add r12, 5
    inc ecx
    jmp .sig
.sigs_done:
    mov byte [r12], 0
    mov eax, [acpi_revision]
    mov ecx, [acpi_table_count]
    lea rdx, [ui_buf2]
    SPRINTF rdi, {"rev %u ", G_MIDDOT, " %u tables: %s"}, rax, rcx, rdx

    INFO 8                              ; PCI and the GPU
    mov edi, 3
    mov esi, -1
    call pci_find_class
    lea rsi, [ui_buf2]
    lea rdx, [str_none]
    test rax, rax
    jz .gpu_named
    mov rdi, rax
    call pci_describe
    lea rdx, [ui_buf2]
.gpu_named:
    mov eax, [pci_count]
    INFO 8
    SPRINTF rdi, {"%u functions ", G_MIDDOT, " %s"}, rax, rdx

    mov edi, 1                          ; storage
    mov r12d, 9
    call ui_device_line
    mov edi, 2                          ; network
    mov r12d, 10
    call ui_device_line

    INFO 11                             ; ISA extensions
    lea rax, [cpu_features]
    SPRINTF rdi, "%s", rax

    INFO 12                             ; boot timeline
    mov rax, [rbx + BI_TSC_ENTRY]       ; firmware: power-on to our loader
    imul rax, rax, 10
    xor edx, edx
    div qword [tsc_hz]
    mov r8, rax
    mov rax, [rbx + BI_TSC_EXIT]
    sub rax, [rbx + BI_TSC_ENTRY]
    xor edx, edx
    div qword [tsc_per_ms]
    mov r9, rax
    RDTSC64
    sub rax, [rbx + BI_TSC_EXIT]
    xor edx, edx
    div qword [tsc_per_ms]
    mov r10, rax
    SPRINTF rdi, {"firmware %t s ", G_MIDDOT, " loader %u ms ", G_MIDDOT, " kernel %u ms"}, r8, r9, r10

    pop r13
    pop r12
    pop rbx
    ret

; ui_measures: the measures above, in pixels at this scale. Preserves all
; but RAX.
ui_measures:
    push rdi
    mov edi, UI_PAD
    call pt
    mov [ui_pad], rax
    mov edi, CARD_IN
    call pt
    mov [ui_in], rax
    mov edi, CARD_R
    call pt
    mov [ui_card_r], rax
    mov edi, SYS_ROW
    call pt
    mov [ui_row], rax
    mov edi, LABEL_W
    call pt
    mov [ui_label_w], rax
    mov edi, TILE_W
    call pt
    mov [tile_w], rax
    mov edi, TILE_H
    call pt
    mov [tile_h], rax
    mov edi, TILE_GAP
    call pt
    mov [tile_gap_x], rax
    mov [tile_gap_y], rax
    pop rdi
    ret

; ui_back(RBX = window): its client, the window's color
ui_back:
    lea rdi, [rbx + WN_SF]
    call gfx_target
    xor edi, edi
    xor esi, esi
    mov rdx, [rbx + WN_W]
    mov rcx, [rbx + WN_H]
    mov r8d, [th_c + TC_WINDOW]
    jmp gfx_fill

; sys_paint (the System window's OP_PAINT, RBX = window): the facts, a row
; each on a card: its name at the left, what it is at the right
sys_paint:
    push r12
    push r13
    push r14
    push r15
    call ui_measures
    call ui_back
    mov rdi, [ui_pad]                   ; the card
    mov rsi, rdi
    mov rdx, [rbx + WN_W]
    sub rdx, rdi
    sub rdx, rdi
    jle .done
    mov rcx, [ui_row]
    imul rcx, rcx, SYS_LINES
    mov r8d, [th_c + TC_PANEL]
    mov r9d, 256
    mov r10, [ui_card_r]
    mov r11d, RC_ALL
    call gfx_rrect
    mov r14, rdx                        ; its width
    xor r12d, r12d
.line:
    mov r13, [ui_row]                   ; the row's top
    imul r13, r12
    add r13, [ui_pad]
    test r12, r12                       ; a line between rows
    jz .text
    mov rdi, [ui_pad]
    add rdi, [ui_in]
    mov rsi, r13
    mov rdx, r14
    sub rdx, [ui_in]
    mov ecx, 1
    mov r8d, [th_c + TC_LINE]
    mov r9d, 256
    call gfx_fill_a
.text:
    mov edi, [f_body]                   ; the baseline: the middle, and half
    call uf_metrics                     ; a capital below it
    mov eax, [rax + UFT_CAP]
    add rax, [ui_row]
    shr rax, 1
    lea r15, [r13 + rax]
    mov rdi, [ui_pad]
    add rdi, [ui_in]
    mov rsi, r15
    lea rdx, [info_labels]
    mov rdx, [rdx + r12 * 8]
    mov ecx, [th_c + TC_TEXT]
    mov r8d, [f_body]
    call uf_text
    mov r9, r14                         ; the value: right of the labels
    sub r9, [ui_in]
    sub r9, [ui_in]
    sub r9, [ui_label_w]
    jle .next
    imul rdx, r12, INFO_LEN
    lea rax, [info_lines]
    add rdx, rax
    mov rdi, rdx
    mov esi, [f_body]
    call uf_width
    cmp rax, r9
    jbe .fits
    mov rax, r9
.fits:
    mov rdi, [ui_pad]
    add rdi, r14
    sub rdi, [ui_in]
    sub rdi, rax
    mov rsi, r15
    mov ecx, [th_c + TC_TEXT2]
    mov r8d, [f_body]
    call uf_text_max
.next:
    inc r12
    cmp r12, SYS_LINES
    jb .line
.done:
    call gfx_target_back
    pop r15
    pop r14
    pop r13
    pop r12
    ret

; cpu_paint (the Processors window's OP_PAINT, RBX = window): the tiles,
; as many to a row as fit
cpu_paint:
    call ui_measures
    call ui_back
    mov rax, [rbx + WN_W]               ; columns that fit
    sub rax, [ui_pad]
    sub rax, [ui_pad]
    add rax, [tile_gap_x]
    jg .room
    xor eax, eax
.room:
    mov rcx, [tile_w]
    add rcx, [tile_gap_x]
    xor edx, edx
    div rcx
    test rax, rax
    jnz .cols_ok
    inc eax
.cols_ok:
    mov [tile_cols], rax
    call ui_draw_tiles
    jmp gfx_target_back

; ui_device_line(EDI = PCI class, R12D = info line)
ui_device_line:
    mov esi, -1
    call pci_find_class
    lea rdx, [str_none]
    test rax, rax
    jz .write
    mov rdi, rax
    lea rsi, [ui_buf2]
    call pci_describe
    lea rdx, [ui_buf2]
.write:
    imul rdi, r12, INFO_LEN
    lea rax, [info_lines]
    add rdi, rax
    SPRINTF rdi, "%s", rdx
    ret

; -----------------------------------------------------------------------------
;  Processor tiles
; -----------------------------------------------------------------------------
ui_draw_tiles:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    xor r12d, r12d                      ; the busiest CPU sets the bar scale
    mov qword [tile_max_items], 1
.scan:
    cmp r12d, [cpu_count]
    jae .scanned
    PERCPU rbx, r12
    mov rax, [rbx + PC_JOB_ITEMS]
    cmp rax, [tile_max_items]
    jbe .scan_next
    mov [tile_max_items], rax
.scan_next:
    inc r12d
    jmp .scan
.scanned:
    xor r12d, r12d                      ; display slot
.tile:
    cmp r12d, [cpu_count]
    jae .done
    lea rax, [cpu_order]
    mov eax, [rax + r12 * 4]
    PERCPU rbx, rax
    mov rax, r12                        ; slot -> column, row
    xor edx, edx
    div qword [tile_cols]
    mov rcx, [tile_h]
    add rcx, [tile_gap_y]
    imul rax, rcx
    add rax, [ui_pad]
    mov r14, rax                        ; tile y, in the window
    mov rax, [tile_w]
    add rax, [tile_gap_x]
    imul rax, rdx
    add rax, [ui_pad]
    mov r13, rax                        ; tile x

    mov eax, COL_BLUE                   ; kind color
    mov rcx, [rbx + PC_KIND]
    cmp rcx, CPU_KIND_P
    jne .not_p
    mov eax, COL_PCORE
.not_p:
    cmp rcx, CPU_KIND_E
    jne .colored
    mov eax, COL_ECORE
.colored:
    cmp qword [rbx + PC_ONLINE], 0
    jne .lit
    mov eax, COL_FAINT
.lit:
    call theme_color
    mov r15d, eax
    mov rdi, r13                        ; the card
    mov rsi, r14
    mov rdx, [tile_w]
    mov rcx, [tile_h]
    mov r8d, [th_c + TC_PANEL]
    mov r9d, 256
    mov r10, [ui_card_r]
    mov r11d, RC_ALL
    call gfx_rrect

    mov edi, 18                         ; line 1: its name, its clock
    call pt
    lea rbp, [r14 + rax]                ; the baseline
    call ui_tile_label
    mov rdi, r13
    add rdi, [ui_in]
    mov rsi, rbp
    lea rdx, [ui_buf]
    mov ecx, r15d
    mov r8d, [f_title]
    call uf_text
    lea rdi, [ui_buf]
    mov rax, [rbx + PC_MHZ]
    test rax, rax
    jz .no_mhz
    SPRINTF rdi, "%u MHz", rax
    jmp .mhz_text
.no_mhz:
    SPRINTF rdi, "-- MHz"
.mhz_text:
    mov ecx, [th_c + TC_TEXT]
    cmp qword [rbx + PC_MHZ], 0
    jne .mhz_color
    mov ecx, [th_c + TC_TEXT3]
.mhz_color:
    mov r8d, [f_body]
    call .right

    lea rdi, [ui_buf]                   ; line 2: its heat, at the right
    mov rax, [rbx + PC_TEMP]
    test rax, rax
    jz .no_temp
    SPRINTF rdi, {"%u", G_DEGREE, "C"}, rax
    jmp .temp_text
.no_temp:
    SPRINTF rdi, {"--", G_DEGREE, "C"}
.temp_text:
    mov edi, 36
    call pt
    lea rbp, [r14 + rax]
    mov eax, COL_FAINT
    mov rcx, [rbx + PC_TEMP]
    test rcx, rcx
    jz .temp_color
    mov eax, COL_GOOD
    cmp rcx, 70
    jb .temp_color
    mov eax, COL_WARN
    cmp rcx, 90
    jb .temp_color
    mov eax, COL_BAD
.temp_color:
    call theme_color
    mov ecx, eax
    mov r8d, [f_small]
    call .right
    mov [tile_bar_end], rax

    mov rdi, r13                        ; and its share of the last job
    add rdi, [ui_in]
    mov rdx, [tile_bar_end]
    sub rdx, rdi
    mov edi, 8
    call pt
    sub rdx, rax
    jle .next_tile
    mov edi, 5
    call pt
    mov rcx, rax                        ; the bar: a capsule
    mov r10, rax
    shr r10, 1
    mov edi, 31
    call pt
    lea rsi, [r14 + rax]
    mov rdi, r13
    add rdi, [ui_in]
    mov r8d, [th_c + TC_LINE]
    mov r9d, 256
    mov r11d, RC_ALL
    call gfx_rrect
    mov rax, [rbx + PC_JOB_ITEMS]
    imul rax, rdx
    xor edx, edx
    div qword [tile_max_items]
    test rax, rax
    jz .next_tile
    cmp rax, rcx                        ; no shorter than it is high
    jae .long
    mov rax, rcx
.long:
    mov rdx, rax
    mov r8d, r15d
    call gfx_rrect
.next_tile:
    inc r12d
    jmp .tile
.done:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret
; ui_buf at the right of the tile, on RBP, ECX = color, R8D = font -> RAX =
; where it starts
.right:
    push rcx
    lea rdi, [ui_buf]
    mov esi, r8d
    call uf_width
    mov rdi, r13
    add rdi, [tile_w]
    sub rdi, [ui_in]
    sub rdi, rax
    pop rcx
    push rdi
    mov rsi, rbp
    lea rdx, [ui_buf]
    call uf_text
    pop rax
    ret

; ui_tile_label(RBX = per-CPU block) -> ui_buf = "P3", "P3.1", "E7", "C2"
ui_tile_label:
    mov rax, [rbx + PC_KIND]
    mov ecx, 'C'
    cmp rax, CPU_KIND_P
    jne .not_p
    mov ecx, 'P'
.not_p:
    cmp rax, CPU_KIND_E
    jne .letter
    mov ecx, 'E'
.letter:
    mov rax, [count_p]                  ; SMT? more threads than cores
    add rax, [count_e]
    add rax, [count_other]
    mov edx, [cpus_online]
    lea rdi, [ui_buf]
    cmp rdx, rax
    jbe .single
    cmp ecx, 'E'
    je .single
    SPRINTF rdi, {"%c%u", G_MIDDOT, "%u"}, rcx, qword [rbx + PC_CORE], qword [rbx + PC_THREAD]
    ret
.single:
    SPRINTF rdi, "%c%u", rcx, qword [rbx + PC_CORE]
    ret

; -----------------------------------------------------------------------------
;  ui_refresh: fresh telemetry, the header summary and the tiles
; -----------------------------------------------------------------------------
ui_refresh:
    push rbx
    push r12
    push r13
    push r14
    call telemetry_sample_all
    call cpu_package_power
    xor r12d, r12d                      ; sum of MHz
    xor r13d, r13d                      ; CPUs reporting a clock
    xor r14d, r14d                      ; hottest
    xor ecx, ecx
.sum:
    cmp ecx, [cpu_count]
    jae .summed
    PERCPU rbx, rcx
    cmp qword [rbx + PC_ONLINE], 0
    je .sum_next
    mov rax, [rbx + PC_MHZ]
    test rax, rax
    jz .temp
    add r12, rax
    inc r13
.temp:
    mov rax, [rbx + PC_TEMP]
    cmp rax, r14
    cmova r14, rax
.sum_next:
    inc ecx
    jmp .sum
.summed:
    mov rax, r12
    test r13, r13
    jz .avg_done
    xor edx, edx
    div r13
.avg_done:
    mov r12, rax                        ; average MHz (0 = unknown)
    call uptime_ms
    xor edx, edx
    mov ecx, 1000
    div rcx
    xor edx, edx
    mov ecx, 60
    div rcx
    mov r8, rdx                         ; seconds
    xor edx, edx
    div rcx
    mov r9, rdx                         ; minutes
    mov r10, rax                        ; hours
    mov rax, [rapl_mw]
    xor edx, edx
    mov ecx, 100
    div rcx
    mov r11, rax                        ; tenths of a watt
    lea rdi, [ui_buf]
    mov eax, [cpus_online]
    SPRINTF rdi, {"%u threads ", G_MIDDOT, " "}, rax
    add rdi, rax
    test r12, r12
    jz .no_clock
    SPRINTF rdi, {"avg %u MHz ", G_MIDDOT, " "}, r12
    add rdi, rax
.no_clock:
    test r14, r14
    jz .no_heat
    SPRINTF rdi, {"max %u", G_DEGREE, "C ", G_MIDDOT, " "}, r14
    add rdi, rax
.no_heat:
    test r11, r11
    jz .no_power
    SPRINTF rdi, {"package %t W ", G_MIDDOT, " "}, r11
    add rdi, rax
.no_power:
    SPRINTF rdi, "up %u:%02u:%02u", r10, r9, r8

    lea rsi, [ui_buf]                   ; at the right of the bar
    call desk_status
    mov rbx, [cpu_win]                  ; the tiles, if they are seen
    test rbx, rbx
    jz .out
    test dword [rbx + WN_FLAGS], WF_SHOWN
    jz .out
    call cpu_paint
    mov rdi, rbx
    call win_damage_all
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ui_demo_stats: the demo's numbers in its panel title row
ui_demo_stats:
    push rbx
    mov rax, [m_last_cycles]            ; frame time in tenths of a ms
    imul rax, rax, 10000
    xor edx, edx
    div qword [tsc_hz]
    mov r8, rax
    mov rax, [m_last_iters]             ; tenths of G iterations per second
    mov rcx, [m_last_cycles]
    test rcx, rcx
    jz .no_rate
    mul qword [tsc_hz]
    div rcx
    jmp .rate
.no_rate:
    xor eax, eax
.rate:
    mov r9, rax                         ; iterations per second
    movsd xmm0, [m_start_scale]         ; zoom factor
    divsd xmm0, [m_last_scale]
    cvttsd2si r10, xmm0
    lea rdi, [ui_buf]
    SPRINTF rdi, {"frame %u ", G_MIDDOT, " %t ms ", G_MIDDOT, " "}, qword [m_last_frame], r8
    add rdi, rax
    mov rax, r9
    xor edx, edx
    mov ecx, 100000000
    div rcx
    cmp rax, 10
    jb .mega
    SPRINTF rdi, {"%t G iter/s ", G_MIDDOT, " "}, rax
    jmp .rate_done
.mega:
    mov rax, r9
    xor edx, edx
    mov ecx, 1000000
    div rcx
    SPRINTF rdi, {"%u M iter/s ", G_MIDDOT, " "}, rax
.rate_done:
    add rdi, rax
    SPRINTF rdi, {"zoom %u", G_TIMES, " ", G_MIDDOT, " %u iter max"}, r10, qword [m_last_maxiter]
    mov rdi, [demo_win]                 ; in the window's title
    test rdi, rdi
    jz .out
    lea rdi, [ui_buf2]
    lea rax, [demo_base]
    lea rdx, [ui_buf]
    SPRINTF rdi, {"%s ", G_MIDDOT, " %s"}, rax, rdx
    mov rdi, [demo_win]
    lea rsi, [ui_buf2]
    call win_title
.out:
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  panic_paint: the report from panic_text over the whole screen
; -----------------------------------------------------------------------------
panic_paint:
    cmp byte [gfx_ready], 0
    je .out
    push rbx
    push r12
    call gfx_target_back                ; over everything, whatever was drawing
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    mov r8d, COL_PANIC_BG
    call gfx_fill
    mov rdi, [font_cw]
    imul rdi, rdi, 4
    mov rsi, [font_ch]
    imul rsi, rsi, 2
    lea rdx, [str_panic_title]
    mov ecx, COL_BAD
    mov r8d, COL_PANIC_BG
    call ui_text
    mov r12, [font_ch]                  ; the report, line by line
    imul r12, r12, 4
    lea rbx, [panic_text]
.line:
    cmp byte [rbx], 0
    je .footer
    cmp byte [rbx], 10
    jne .draw
    inc rbx
    add r12, [font_ch]
    jmp .line
.draw:
    lea rdi, [ui_buf]                   ; copy one line
    xor ecx, ecx
.copy:
    mov al, [rbx]
    test al, al
    jz .copied
    cmp al, 10
    je .copied
    cmp ecx, 250
    jae .copied
    mov [rdi + rcx], al
    inc rbx
    inc ecx
    jmp .copy
.copied:
    mov byte [rdi + rcx], 0
    mov rdi, [font_cw]
    imul rdi, rdi, 4
    mov rsi, r12
    lea rdx, [ui_buf]
    mov ecx, COL_TEXT
    mov r8d, COL_PANIC_BG
    call ui_text
    jmp .line
.footer:
    add r12, [font_ch]
    add r12, [font_ch]
    mov rdi, [font_cw]
    imul rdi, rdi, 4
    mov rsi, r12
    lea rdx, [str_panic_footer]
    mov ecx, COL_DIM
    mov r8d, COL_PANIC_BG
    call ui_text
    call gfx_blit_all
    pop r12
    pop rbx
.out:
    ret

section .rodata
str_brand:          db 'AXIOM', 0
str_t_system:       db 'System', 0
str_t_processors:   db 'Processors', 0
str_app_mandel:     db 'Mandelbrot', 0
str_off:            db 'off', 0
str_x2apic:         db 'x2APIC', 0
str_xapic:          db 'xAPIC', 0
str_none:           db 'none found', 0
str_panic_title:    db 'AXIOM STOPPED', 0
str_panic_footer:   db 'Every CPU is halted. The same report went to the serial port. Power-cycle to restart.', 0
str_l_machine:      db 'Machine', 0
str_l_firmware:     db 'Firmware', 0
str_l_cpu:          db 'Processor', 0
str_l_cores:        db 'Cores', 0
str_l_clocks:       db 'Clocks', 0
str_l_memory:       db 'Memory', 0
str_l_display:      db 'Display', 0
str_l_acpi:         db 'ACPI', 0
str_l_pci:          db 'PCI', 0
str_l_storage:      db 'Storage', 0
str_l_network:      db 'Network', 0
str_l_isa:          db 'ISA', 0
str_l_boot:         db 'Boot', 0
align 8
sys_ops:        dq sys_paint, 0, 0, 0, 0, 0, 0
cpu_ops:        dq cpu_paint, 0, 0, 0, 0, 0, 0
demo_ops:       dq demo_paint, 0, demo_click, demo_wheel, 0, 0, 0
info_labels:
    dq str_l_machine, str_l_firmware, str_l_cpu, str_l_cores, str_l_clocks
    dq str_l_memory, str_l_display, str_l_acpi, str_l_pci, str_l_storage
    dq str_l_network, str_l_isa, str_l_boot

section .bss
alignb 8
ui_line:        resq 1
hdr_h:          resq 1
title_h:        resq 1
body_y:         resq 1
body_bottom:    resq 1
left_w:         resq 1
right_x:        resq 1
right_w:        resq 1
sys_x:          resq 1
sys_y:          resq 1
sys_h:          resq 1
conp_y:         resq 1
conp_h:         resq 1
cores_h:        resq 1
demo_y:         resq 1
demo_h:         resq 1
tile_w:         resq 1
tile_h:         resq 1
tile_gap_x:     resq 1
tile_gap_y:     resq 1
tile_cols:      resq 1
tile_max_items: resq 1
tile_bar_end:   resq 1
ui_pad:         resq 1
ui_in:          resq 1
ui_card_r:      resq 1
ui_row:         resq 1
ui_label_w:     resq 1
sys_win:        resq 1
cpu_win:        resq 1
demo_win:       resq 1
demo_base:      resb 96                 ; the demo's title, without its numbers
ui_buf:         resb 256
ui_buf2:        resb 256
info_lines:     resb SYS_LINES * INFO_LEN

section .rodata
str_plural_s:   db 's', 0
