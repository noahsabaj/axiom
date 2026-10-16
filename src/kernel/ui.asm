; =============================================================================
;  ui.asm - the dashboard: header, system panel, console, one tile per
;  logical processor, the demo view; and the panic screen.
;  Everything is laid out in font cells so it scales from 1280x800 to 4K.
; =============================================================================

SYS_LINES       equ 13
INFO_LEN        equ 160

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
    mov rax, [font_ch]
    lea rcx, [rax + rax]
    mov [hdr_h], rcx
    mov rdx, rax
    shr rdx, 1
    add rdx, rax
    mov [title_h], rdx                  ; 1.5 rows
    shr rax, 1
    add rcx, rax
    mov [body_y], rcx
    mov rcx, [scr_h]
    sub rcx, rax
    mov [body_bottom], rcx

    mov rax, [scr_w]                    ; left column: 36% in whole cells
    mov rcx, [font_cw]
    imul rcx, rcx, 3
    sub rax, rcx
    imul rax, rax, 36
    xor edx, edx
    mov ecx, 100
    div rcx
    xor edx, edx
    div qword [font_cw]
    imul rax, [font_cw]
    mov [left_w], rax
    mov rcx, [font_cw]
    mov [sys_x], rcx
    lea rdx, [rcx * 2 + rax]
    mov [right_x], rdx
    mov rax, [scr_w]
    sub rax, rdx
    sub rax, rcx
    mov [right_w], rax

    mov rax, [body_y]
    mov [sys_y], rax
    mov rax, [font_ch]
    imul rax, rax, SYS_LINES
    add rax, [title_h]
    mov rcx, [font_ch]
    shr rcx, 1
    add rax, rcx
    mov [sys_h], rax
    add rax, [sys_y]
    add rax, rcx
    mov [conp_y], rax
    mov rdx, [body_bottom]
    sub rdx, rax
    mov [conp_h], rdx

    xor edi, edi                        ; background and header
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [scr_h]
    mov r8d, COL_BG
    call gfx_fill
    call ui_draw_header

    mov rdi, [sys_x]
    mov rsi, [sys_y]
    mov rdx, [left_w]
    mov rcx, [sys_h]
    lea r8, [str_t_system]
    call ui_panel
    mov rdi, [sys_x]
    mov rsi, [conp_y]
    mov rdx, [left_w]
    mov rcx, [conp_h]
    lea r8, [str_t_console]
    call ui_panel
    mov rdi, [right_x]                  ; the right column waits for the CPUs
    mov rsi, [body_y]
    mov rdx, [right_w]
    mov rcx, [body_bottom]
    sub rcx, rsi
    lea r8, [str_t_processors]
    call ui_panel

    mov dword [con_bg], COL_PANEL       ; the console lives inside its panel
    mov rdi, [sys_x]
    add rdi, [font_cw]
    mov rsi, [conp_y]
    add rsi, [title_h]
    mov rdx, [left_w]
    mov rax, [font_cw]
    sub rdx, rax
    sub rdx, rax
    mov rcx, [conp_h]
    sub rcx, [title_h]
    mov rax, [font_ch]
    shr rax, 2
    sub rcx, rax
    call con_init
    call gfx_blit_all
    pop rbx
    ret

ui_draw_header:
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [hdr_h]
    mov r8d, COL_PANEL
    call gfx_fill
    xor edi, edi
    mov rsi, [hdr_h]
    sub rsi, [ui_line]
    mov rdx, [scr_w]
    mov rcx, [ui_line]
    mov r8d, COL_LINE
    call gfx_fill
    mov rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 1
    lea rdx, [str_brand]
    mov ecx, COL_ACCENT
    mov r8d, COL_PANEL
    call ui_text
    mov rdi, rax
    mov rsi, [font_ch]
    shr rsi, 1
    lea rdx, [str_tagline]
    mov ecx, COL_DIM
    mov r8d, COL_PANEL
    call ui_text
    ret

; -----------------------------------------------------------------------------
;  ui_ready: once every CPU is up - processor tiles, demo view, system facts
; -----------------------------------------------------------------------------
ui_ready:
    push rbx
    push r12
    mov rax, [font_cw]                  ; tile geometry
    imul rcx, rax, 22
    mov [tile_w], rcx
    shr rax, 1
    mov [tile_gap_x], rax
    mov rax, [font_ch]
    lea rcx, [rax * 2]
    mov rdx, rax
    shr rdx, 1
    add rcx, rdx
    mov [tile_h], rcx
    xor edx, edx
    mov ecx, 3
    div rcx
    mov [tile_gap_y], rax
    mov rax, [right_w]                  ; columns that fit
    mov rcx, [font_cw]
    sub rax, rcx
    sub rax, rcx
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
    add rax, [title_h]
    mov rcx, [font_ch]
    shr rcx, 2
    add rax, rcx
    mov [cores_h], rax
    mov rcx, [body_y]
    add rcx, rax
    mov rax, [font_ch]
    shr rax, 1
    add rcx, rax
    mov [demo_y], rcx
    mov rax, [body_bottom]
    sub rax, rcx
    mov [demo_h], rax

    mov rdi, [right_x]                  ; repaint the right column
    mov rsi, [body_y]
    mov rdx, [right_w]
    mov rcx, [body_bottom]
    sub rcx, rsi
    mov r8d, COL_BG
    call gfx_fill
    mov rdi, [right_x]
    mov rsi, [body_y]
    mov rdx, [right_w]
    mov rcx, [cores_h]
    lea r8, [str_t_processors]
    call ui_panel
    lea rdi, [ui_buf]                   ; demo panel title
    cmp byte [mandel_ok], 0
    je .no_avx
    mov eax, [cpus_online]
    SPRINTF rdi, {"MANDELBROT ", G_MIDDOT, " AVX2 + FMA ", G_MIDDOT, " %u threads"}, rax
    jmp .demo_panel
.no_avx:
    SPRINTF rdi, "MANDELBROT (needs AVX2 + FMA)"
.demo_panel:
    mov rdi, [right_x]
    mov rsi, [demo_y]
    mov rdx, [right_w]
    mov rcx, [demo_h]
    lea r8, [ui_buf]
    call ui_panel
    mov rdi, [right_x]                  ; the fractal fills the panel
    add rdi, [font_cw]
    mov rsi, [demo_y]
    add rsi, [title_h]
    mov rdx, [right_w]
    mov rax, [font_cw]
    sub rdx, rax
    sub rdx, rax
    mov rcx, [demo_h]
    sub rcx, [title_h]
    mov rax, [font_ch]
    shr rax, 1
    sub rcx, rax
    jns .view_ok
    xor ecx, ecx
.view_ok:
    call mandel_set_view

    call ui_system_info
    call ui_draw_tiles
    call gfx_blit_all
    pop r12
    pop rbx
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
    lea rax, [str_off]
    cmp byte [cpu_hwp_on], 0
    je .hwp_done
    lea rax, [str_hwp_on]
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

    xor r12d, r12d                      ; draw them
.draw:
    mov rax, [font_ch]
    imul rax, r12
    add rax, [title_h]
    add rax, [sys_y]
    mov r13, rax
    mov rdi, [sys_x]
    add rdi, [font_cw]
    mov rsi, r13
    lea rdx, [info_labels]
    mov rdx, [rdx + r12 * 8]
    mov ecx, COL_DIM
    mov r8d, COL_PANEL
    call ui_text
    mov rdi, [font_cw]                  ; values start at column 11
    imul rdi, rdi, 11
    add rdi, [sys_x]
    mov rsi, r13
    imul rdx, r12, INFO_LEN
    lea rax, [info_lines]
    add rdx, rax
    mov rax, [left_w]                   ; clip to the panel
    xor ecx, ecx
    push rdx
    xor edx, edx
    div qword [font_cw]
    pop rdx
    sub rax, 12
    jg .clip_ok
    mov eax, 1
.clip_ok:
    mov r9, rax
    mov ecx, COL_TEXT
    mov r8d, COL_PANEL
    call ui_text_max
    inc r12
    cmp r12, SYS_LINES
    jb .draw
    pop r13
    pop r12
    pop rbx
    ret

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
    add rax, [title_h]
    add rax, [body_y]
    mov r14, rax                        ; tile y
    mov rax, [tile_w]
    add rax, [tile_gap_x]
    imul rax, rdx
    add rax, [font_cw]
    add rax, [right_x]
    mov r13, rax                        ; tile x

    mov r15d, COL_BLUE                  ; kind color
    mov rax, [rbx + PC_KIND]
    cmp rax, CPU_KIND_P
    jne .not_p
    mov r15d, COL_PCORE
.not_p:
    cmp rax, CPU_KIND_E
    jne .colored
    mov r15d, COL_ECORE
.colored:
    cmp qword [rbx + PC_ONLINE], 0
    jne .lit
    mov r15d, COL_FAINT
.lit:
    mov rdi, r13
    mov rsi, r14
    mov rdx, [tile_w]
    mov rcx, [tile_h]
    mov r8d, COL_PANEL2
    call gfx_fill
    mov rdi, r13
    mov rsi, r14
    mov rdx, [ui_line]
    imul rdx, rdx, 3
    mov rcx, [tile_h]
    mov r8d, r15d
    call gfx_fill

    call ui_tile_label                  ; line 1: name and clock
    mov rdi, r13
    add rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 3
    add rsi, r14
    lea rdx, [ui_buf]
    mov ecx, r15d
    mov r8d, COL_PANEL2
    call ui_text
    lea rdi, [ui_buf]
    mov rax, [rbx + PC_MHZ]
    test rax, rax
    jz .no_mhz
    SPRINTF rdi, "%u MHz", rax
    jmp .mhz_text
.no_mhz:
    SPRINTF rdi, "-- MHz"
.mhz_text:
    mov rdi, r13
    add rdi, [tile_w]
    sub rdi, [tile_gap_x]
    mov rsi, [font_ch]
    shr rsi, 3
    add rsi, r14
    lea rdx, [ui_buf]
    mov ecx, COL_TEXT
    cmp qword [rbx + PC_MHZ], 0
    jne .mhz_color
    mov ecx, COL_FAINT
.mhz_color:
    mov r8d, COL_PANEL2
    call ui_text_right

    lea rdi, [ui_buf]                   ; line 2: temperature, right
    mov rax, [rbx + PC_TEMP]
    test rax, rax
    jz .no_temp
    SPRINTF rdi, {"%u", G_DEGREE, "C"}, rax
    jmp .temp_text
.no_temp:
    SPRINTF rdi, {"--", G_DEGREE, "C"}
.temp_text:
    mov rdi, r13
    add rdi, [tile_w]
    sub rdi, [tile_gap_x]
    mov rsi, [font_ch]
    mov rax, rsi
    shr rax, 3
    add rsi, rax
    add rsi, r14
    lea rdx, [ui_buf]
    mov ecx, COL_FAINT
    mov rax, [rbx + PC_TEMP]
    test rax, rax
    jz .temp_color
    mov ecx, COL_GOOD
    cmp rax, 70
    jb .temp_color
    mov ecx, COL_WARN
    cmp rax, 90
    jb .temp_color
    mov ecx, COL_BAD
.temp_color:
    mov r8d, COL_PANEL2
    call ui_text_right
    mov [tile_bar_end], rax

    mov rdi, r13                        ; line 2: share of the last job
    add rdi, [font_cw]
    mov rsi, [font_ch]
    mov rax, rsi
    shr rax, 1
    add rsi, rax
    add rsi, r14
    mov rdx, [tile_bar_end]
    sub rdx, rdi
    sub rdx, [font_cw]
    jle .next_tile
    mov rcx, [font_ch]
    shr rcx, 2
    mov r8d, COL_LINE
    call gfx_fill
    mov rax, [rbx + PC_JOB_ITEMS]
    imul rax, rdx
    xor edx, edx
    div qword [tile_max_items]
    mov rdx, rax
    test rdx, rdx
    jz .next_tile
    mov r8d, r15d
    call gfx_fill
.next_tile:
    inc r12d
    jmp .tile
.done:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
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

    mov rdi, [scr_w]                    ; repaint the right half of the header
    shr rdi, 1
    xor esi, esi
    mov rdx, [scr_w]
    shr rdx, 1
    mov rcx, [hdr_h]
    sub rcx, [ui_line]
    mov r8d, COL_PANEL
    call gfx_fill
    mov rdi, [scr_w]
    sub rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 1
    lea rdx, [ui_buf]
    mov ecx, COL_TEXT
    mov r8d, COL_PANEL
    call ui_text_right
    xor edi, edi
    xor esi, esi
    mov rdx, [scr_w]
    mov rcx, [hdr_h]
    call gfx_blit

    cmp qword [tile_cols], 0            ; tiles exist once ui_ready ran
    je .out
    call ui_draw_tiles
    mov rdi, [right_x]
    mov rsi, [body_y]
    mov rdx, [right_w]
    mov rcx, [cores_h]
    call gfx_blit
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
    mov rdi, [right_x]                  ; clear the right part of the title row
    mov rax, [right_w]
    shr rax, 1
    add rdi, rax
    mov rsi, [demo_y]
    add rsi, [ui_line]
    mov rdx, rax
    sub rdx, [ui_line]
    mov rcx, [title_h]
    sub rcx, [ui_line]
    mov r8d, COL_PANEL
    call gfx_fill
    mov rdi, [right_x]
    add rdi, [right_w]
    sub rdi, [font_cw]
    mov rsi, [font_ch]
    shr rsi, 2
    add rsi, [demo_y]
    lea rdx, [ui_buf]
    mov ecx, COL_DIM
    mov r8d, COL_PANEL
    call ui_text_right
    mov rdi, [right_x]
    mov rsi, [demo_y]
    mov rdx, [right_w]
    mov rcx, [title_h]
    call gfx_blit
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
str_tagline:        db '  0.1 ', G_MIDDOT, ' first light', 0
str_t_system:       db 'SYSTEM', 0
str_t_console:      db 'CONSOLE', 0
str_t_processors:   db 'PROCESSORS', 0
str_off:            db 'off', 0
str_hwp_on:         db 'on, EPP 0 (performance)', 0
str_x2apic:         db 'x2APIC', 0
str_xapic:          db 'xAPIC', 0
str_none:           db 'none found', 0
str_panic_title:    db 'AXIOM STOPPED', 0
str_panic_footer:   db 'Every CPU is halted. The same report went to the serial port. Power-cycle to restart.', 0
str_l_machine:      db 'machine', 0
str_l_firmware:     db 'firmware', 0
str_l_cpu:          db 'processor', 0
str_l_cores:        db 'cores', 0
str_l_clocks:       db 'clocks', 0
str_l_memory:       db 'memory', 0
str_l_display:      db 'display', 0
str_l_acpi:         db 'acpi', 0
str_l_pci:          db 'pci', 0
str_l_storage:      db 'storage', 0
str_l_network:      db 'network', 0
str_l_isa:          db 'isa', 0
str_l_boot:         db 'boot', 0
align 8
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
ui_buf:         resb 256
ui_buf2:        resb 256
info_lines:     resb SYS_LINES * INFO_LEN

section .rodata
str_plural_s:   db 's', 0
