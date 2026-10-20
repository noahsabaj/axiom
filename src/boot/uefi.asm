; =============================================================================
;  Axiom UEFI loader - BOOTX64.EFI
;
;  A PE32+ image laid out byte by byte by NASM: no linker, no C, no libraries.
;  It asks the firmware for the display, the memory map and the ACPI/SMBIOS
;  tables, builds Axiom's page tables, leaves boot services and jumps into the
;  kernel at KERNEL_BASE: the one built into it, or an update from the volume
;  it came from (find_slot).
;
;  The firmware may load this image anywhere, so all code is RIP-relative.
;  Never write [label + reg] in this file: NASM would encode an absolute
;  address. Load the label with LEA first.
;
;  Register use: the MS x64 ABI applies to firmware calls. Every subroutine
;  here may clobber every register; state lives in the variables at the end.
; =============================================================================

bits 64
default rel

%include "efi.inc"
%include "bootinfo.inc"

%ifndef GOP_MAX_W
  %define GOP_MAX_W 0xFFFFFFFF              ; build-time cap on the display mode
%endif
%ifndef GOP_MAX_H
  %define GOP_MAX_H 0xFFFFFFFF
%endif

ALIGNMENT       equ 0x1000                  ; section and file alignment: file offset = RVA

; -----------------------------------------------------------------------------
;  PE32+ headers
; -----------------------------------------------------------------------------
mz_header:
    db 'MZ'
    times 0x3C - ($ - $$) db 0
    dd pe_header

pe_header:
    db 'PE', 0, 0
    dw 0x8664                               ; Machine: AMD64
    dw 2                                    ; NumberOfSections
    dd 0                                    ; TimeDateStamp
    dd 0                                    ; PointerToSymbolTable
    dd 0                                    ; NumberOfSymbols
    dw optional_header_end - optional_header
    dw 0x0206                               ; executable, no line numbers, no debug info

optional_header:
    dw 0x020B                               ; PE32+
    db 0, 0                                 ; linker version
    dd text_end - text_start                ; SizeOfCode
    dd reloc_end - reloc_start              ; SizeOfInitializedData
    dd 0                                    ; SizeOfUninitializedData
    dd entry                                ; AddressOfEntryPoint
    dd text_start                           ; BaseOfCode
    dq 0x400000                             ; ImageBase (preferred only)
    dd ALIGNMENT                            ; SectionAlignment
    dd ALIGNMENT                            ; FileAlignment
    dw 0, 0, 0, 0, 0, 0                     ; OS, image and subsystem versions
    dd 0                                    ; Win32VersionValue
    dd image_end                            ; SizeOfImage
    dd text_start                           ; SizeOfHeaders
    dd 0                                    ; CheckSum
    dw 10                                   ; Subsystem: EFI application
    dw 0                                    ; DllCharacteristics
    dq 0x10000, 0x10000                     ; stack reserve, commit
    dq 0, 0                                 ; heap reserve, commit
    dd 0                                    ; LoaderFlags
    dd 16                                   ; NumberOfRvaAndSizes
    dq 0, 0, 0, 0, 0                        ; export, import, resource, exception, security
    dd reloc_start, reloc_data_end - reloc_start
    dq 0, 0, 0, 0, 0, 0, 0, 0, 0, 0         ; debug .. reserved
optional_header_end:

section_headers:
    db '.text', 0, 0, 0
    dd text_end - text_start                ; VirtualSize
    dd text_start                           ; VirtualAddress
    dd text_end - text_start                ; SizeOfRawData
    dd text_start                           ; PointerToRawData
    dd 0, 0                                 ; relocations, line numbers
    dw 0, 0
    dd 0xE0000060                           ; code, data, execute, read, write

    db '.reloc', 0, 0
    dd reloc_data_end - reloc_start
    dd reloc_start
    dd reloc_end - reloc_start
    dd reloc_start
    dd 0, 0
    dw 0, 0
    dd 0x42000040                           ; data, discardable, read

    times ALIGNMENT - ($ - $$) db 0

; =============================================================================
text_start:

entry:                                      ; RCX = ImageHandle, RDX = SystemTable
    push rbx
    push rbp
    push rsi
    push rdi
    push r12
    push r13
    push r14
    push r15
    mov [entry_rsp], rsp
    sub rsp, 40                             ; shadow space; RSP is now 16-byte aligned
    mov [image_handle], rcx
    mov [system_table], rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [bootinfo + BI_TSC_ENTRY], rax

    mov rbx, [system_table]
    mov rax, [rbx + ST_BOOT]
    mov [boot_services], rax
    mov rax, [rbx + ST_CONOUT]
    mov [con_out], rax
    mov rax, [rbx + ST_RUNTIME]
    mov [runtime], rax
    mov [bootinfo + BI_RUNTIME], rax

    xor ecx, ecx                            ; SetWatchdogTimer(0, 0, 0, NULL)
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    mov rax, [boot_services]
    call [rax + BS_SET_WATCHDOG]

    lea rdx, [msg_banner]
    call print

    mov rax, cr4                            ; we build 4-level page tables
    bt rax, 12                              ; LA57
    jc .five_level

    call setup_display
    call find_config_tables
    call find_boot_volume
    call calibrate_tsc
    call find_test_run
    call find_slot
    call load_kernel
    call build_page_tables
    lea rdx, [msg_launch]
    call print
    call leave_boot_services
    jmp enter_kernel

.five_level:
    lea rdx, [msg_la57]
    jmp fatal

; -----------------------------------------------------------------------------
;  print - RDX = UTF-16 string
; -----------------------------------------------------------------------------
print:
    sub rsp, 40
    mov rcx, [con_out]
    call [rcx + CON_OUTPUT_STRING]
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  fatal - RDX = UTF-16 reason. Shows it, waits, returns to the boot manager.
;  Reached by JMP from code whose stack is aligned with shadow space.
; -----------------------------------------------------------------------------
fatal:
    mov [fatal_reason], rdx
    lea rdx, [msg_fatal]
    call print
    mov rdx, [fatal_reason]
    call print
    mov ecx, 8000000                        ; 8 s to read it
    mov rax, [boot_services]
    call [rax + BS_STALL]
    mov rsp, [entry_rsp]
    pop r15
    pop r14
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    mov rax, EFI_LOAD_ERROR
    ret

; -----------------------------------------------------------------------------
;  setup_display - pick the widest (then tallest) 32-bit GOP mode
; -----------------------------------------------------------------------------
setup_display:
    sub rsp, 40
    lea rcx, [gop_guid]                     ; LocateProtocol(&GOP, NULL, &gop)
    xor edx, edx
    lea r8, [gop]
    mov rax, [boot_services]
    call [rax + BS_LOCATE_PROTOCOL]
    test rax, rax
    jnz .no_gop

    mov rax, [gop]
    mov rax, [rax + GOP_MODE]
    mov ecx, [rax + GM_MAX_MODE]
    mov [gop_max_mode], ecx
    mov ecx, [rax + GM_MODE]
    mov [best_mode], ecx
    mov rdx, [rax + GM_INFO]                ; the current mode is the fallback
    xor ecx, ecx
    mov [best_w], ecx
    mov [best_h], ecx
    cmp dword [rdx + GI_FORMAT], 1
    ja .scan                                ; current mode is not 32-bit RGB/BGR
    mov ecx, [rdx + GI_WIDTH]
    cmp ecx, GOP_MAX_W
    ja .scan
    mov [best_w], ecx
    mov ecx, [rdx + GI_HEIGHT]
    cmp ecx, GOP_MAX_H
    ja .scan_reset
    mov [best_h], ecx
    jmp .scan
.scan_reset:
    mov dword [best_w], 0
.scan:
    mov dword [mode_iter], 0
.mode_loop:
    mov ecx, [mode_iter]
    cmp ecx, [gop_max_mode]
    jae .mode_done
    mov rcx, [gop]                          ; QueryMode(gop, n, &size, &info)
    mov edx, [mode_iter]
    lea r8, [info_size]
    lea r9, [info_ptr]
    mov rax, [gop]
    call [rax + GOP_QUERY_MODE]
    test rax, rax
    jnz .mode_next
    mov rdx, [info_ptr]
    cmp dword [rdx + GI_FORMAT], 1
    ja .mode_free
    mov eax, [rdx + GI_WIDTH]
    mov ecx, [rdx + GI_HEIGHT]
    cmp eax, GOP_MAX_W
    ja .mode_free
    cmp ecx, GOP_MAX_H
    ja .mode_free
    cmp eax, [best_w]
    jb .mode_free
    ja .mode_take
    cmp ecx, [best_h]
    jbe .mode_free
.mode_take:
    mov [best_w], eax
    mov [best_h], ecx
    mov eax, [mode_iter]
    mov [best_mode], eax
.mode_free:
    mov rcx, [info_ptr]
    mov rax, [boot_services]
    call [rax + BS_FREE_POOL]
.mode_next:
    inc dword [mode_iter]
    jmp .mode_loop

.mode_done:
    mov rax, [gop]
    mov rax, [rax + GOP_MODE]
    mov ecx, [rax + GM_MODE]
    cmp ecx, [best_mode]
    je .read_mode
    mov rcx, [gop]                          ; SetMode(gop, best); keep the old mode on failure
    mov edx, [best_mode]
    mov rax, [gop]
    call [rax + GOP_SET_MODE]

.read_mode:
    mov rax, [gop]
    mov rax, [rax + GOP_MODE]
    mov rcx, [rax + GM_FB_BASE]
    mov [bootinfo + BI_FB_PHYS], rcx
    mov rcx, [rax + GM_FB_SIZE]
    mov [bootinfo + BI_FB_SIZE], rcx
    mov ecx, [rax + GM_MAX_MODE]
    mov [bootinfo + BI_GOP_MODES], ecx
    mov ecx, [rax + GM_MODE]
    mov [bootinfo + BI_GOP_MODE], ecx
    mov rdx, [rax + GM_INFO]
    mov ecx, [rdx + GI_WIDTH]
    mov [bootinfo + BI_FB_WIDTH], ecx
    mov ecx, [rdx + GI_HEIGHT]
    mov [bootinfo + BI_FB_HEIGHT], ecx
    mov ecx, [rdx + GI_PITCH]
    mov [bootinfo + BI_FB_PITCH], ecx
    mov ecx, [rdx + GI_FORMAT]
    mov [bootinfo + BI_FB_FORMAT], ecx
    cmp ecx, 1
    ja .bad_format
    mov rax, [bootinfo + BI_FB_SIZE]        ; mapped with one page directory
    mov rcx, 0x3FF00000
    cmp rax, rcx
    ja .bad_format
    add rsp, 40
    ret
.no_gop:
    lea rdx, [msg_no_gop]
    jmp fatal
.bad_format:
    lea rdx, [msg_fb_format]
    jmp fatal

; -----------------------------------------------------------------------------
;  find_config_tables - ACPI RSDP, SMBIOS entry points, firmware identity
; -----------------------------------------------------------------------------
find_config_tables:
    mov rbx, [system_table]
    mov rcx, [rbx + ST_CONFIG_COUNT]
    mov rsi, [rbx + ST_CONFIG_TABLE]
.next:
    test rcx, rcx
    jz .identity
    mov rax, [rsi]
    mov rdx, [rsi + 8]
    mov rdi, [rsi + 16]

    cmp rax, [acpi20_guid]
    jne .not_acpi20
    cmp rdx, [acpi20_guid + 8]
    jne .not_acpi20
    mov [bootinfo + BI_RSDP], rdi           ; ACPI 2.0+ always wins
    jmp .advance
.not_acpi20:
    cmp rax, [acpi10_guid]
    jne .not_acpi10
    cmp rdx, [acpi10_guid + 8]
    jne .not_acpi10
    cmp qword [bootinfo + BI_RSDP], 0
    jne .advance
    mov [bootinfo + BI_RSDP], rdi
    jmp .advance
.not_acpi10:
    cmp rax, [smbios3_guid]
    jne .not_smbios3
    cmp rdx, [smbios3_guid + 8]
    jne .not_smbios3
    mov [bootinfo + BI_SMBIOS3], rdi
    jmp .advance
.not_smbios3:
    cmp rax, [smbios2_guid]
    jne .advance
    cmp rdx, [smbios2_guid + 8]
    jne .advance
    mov [bootinfo + BI_SMBIOS2], rdi
.advance:
    add rsi, CONFIG_ENTRY_SIZE
    dec rcx
    jmp .next

.identity:                                  ; firmware vendor: UTF-16 -> ASCII
    mov rsi, [rbx + ST_FW_VENDOR]
    lea rdi, [bootinfo + BI_FW_VENDOR]
    mov ecx, 63
    test rsi, rsi
    jz .vendor_done
.vendor_char:
    movzx eax, word [rsi]
    test eax, eax
    jz .vendor_done
    cmp eax, 0x7E
    jbe .vendor_store
    mov eax, '?'
.vendor_store:
    mov [rdi], al
    inc rdi
    add rsi, 2
    dec ecx
    jnz .vendor_char
.vendor_done:
    mov byte [rdi], 0
    mov eax, [rbx + ST_FW_REVISION]
    mov [bootinfo + BI_FW_REV], eax
    mov eax, [rbx + HDR_REVISION]
    mov [bootinfo + BI_UEFI_REV], eax
    ret

; -----------------------------------------------------------------------------
;  find_boot_volume - the FAT serial number of the volume this loader came
;  from, so the kernel can find it again and keep its log there. Never fatal.
; -----------------------------------------------------------------------------
find_boot_volume:
    sub rsp, 40                             ; shadow space + a fifth argument
    mov rcx, [image_handle]
    lea rdx, [loaded_image_guid]
    lea r8, [boot_proto]
    mov rax, [boot_services]
    call [rax + BS_HANDLE_PROTOCOL]
    test rax, rax
    jnz .out
    mov rax, [boot_proto]
    mov rcx, [rax + LI_DEVICE_HANDLE]
    mov [boot_device], rcx                  ; (find_slot reads files from it)
    lea rdx, [block_io_guid]
    lea r8, [boot_proto]
    mov rax, [boot_services]
    call [rax + BS_HANDLE_PROTOCOL]
    test rax, rax
    jnz .out
    mov rax, [boot_proto]
    mov rax, [rax + BIO_MEDIA]
    mov ecx, [rax + BM_BLOCK_SIZE]
    cmp ecx, 512
    jb .out
    cmp ecx, 4096
    ja .out
    mov [boot_block], ecx
    mov ecx, ALLOCATE_ANY_PAGES             ; one page, page-aligned for any IoAlign
    mov edx, EFI_LOADER_DATA
    mov r8d, 1
    lea r9, [boot_sector]
    mov rax, [boot_services]
    call [rax + BS_ALLOCATE_PAGES]
    test rax, rax
    jnz .out
    mov rcx, [boot_proto]                   ; ReadBlocks(This, MediaId, LBA 0, size, buffer)
    mov rax, [rcx + BIO_MEDIA]
    mov edx, [rax + BM_MEDIA_ID]
    xor r8d, r8d
    mov r9d, [boot_block]
    mov rax, [boot_sector]
    mov [rsp + 32], rax
    call [rcx + BIO_READ_BLOCKS]
    test rax, rax
    jnz .free
    mov rsi, [boot_sector]
    cmp word [rsi + 510], 0xAA55
    jne .free
    mov rax, 'FAT32   '
    cmp [rsi + 82], rax
    jne .fat16
    mov eax, [rsi + 67]
    mov ecx, 32
    jmp .found
.fat16:
    mov rax, 'FAT16   '
    cmp [rsi + 54], rax
    jne .free
    mov eax, [rsi + 39]
    mov ecx, 16
.found:
    mov [bootinfo + BI_BOOT_SERIAL], eax
    mov [bootinfo + BI_BOOT_FS], ecx
.free:
    mov rcx, [boot_sector]
    mov edx, 1
    mov rax, [boot_services]
    call [rax + BS_FREE_PAGES]
.out:
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  calibrate_tsc - let the firmware's own timer measure our TSC
; -----------------------------------------------------------------------------
calibrate_tsc:
    sub rsp, 40
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [tsc_mark], rax
    mov ecx, 50000                          ; Stall(50 ms)
    mov rax, [boot_services]
    call [rax + BS_STALL]
    rdtsc
    shl rdx, 32
    or rax, rdx
    sub rax, [tsc_mark]
    imul rax, rax, 20
    mov [bootinfo + BI_TSC_HZ], rax
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  find_test_run - a test run, as tools/hw/hp1.py asks for one: its script in
;  the UEFI variable AxiomRun, read into pages of its own for the kernel and
;  deleted, so that it runs once; and the chipset's TCO watchdog started, so
;  that a run that hangs ends in a reset all the same. Never fatal.
; -----------------------------------------------------------------------------
find_test_run:
    sub rsp, 40                             ; shadow space + a fifth argument
    mov qword [run_size], 0                ; GetVariable(name, guid, NULL, &0, buf):
    lea rcx, [name_axiom_run]               ; how big, if it is there
    lea rdx, [axiom_guid]
    xor r8d, r8d
    lea r9, [run_size]
    lea rax, [run_probe]
    mov [rsp + 32], rax
    mov rax, [runtime]
    call [rax + RT_GET_VARIABLE]
    mov rcx, EFI_BUFFER_TOO_SMALL
    cmp rax, rcx
    jne .out                                ; no test run
    mov rax, [run_size]
    mov ecx, RUN_MAX
    cmp rax, rcx
    cmova eax, ecx                          ; (too big: still a run, of nothing)
    mov [bootinfo + BI_RUN_SIZE], eax
    cmp qword [run_size], RUN_MAX - 1
    ja .delete
    mov ecx, RUN_MAX / 4096
    xor edx, edx
    call alloc_pages                        ; zeroed, and kept for the kernel
    mov [run_buf], rax
    mov qword [run_size], RUN_MAX - 1       ; (a NUL after it)
    lea rcx, [name_axiom_run]
    lea rdx, [axiom_guid]
    xor r8d, r8d
    lea r9, [run_size]
    mov rax, [run_buf]
    mov [rsp + 32], rax
    mov rax, [runtime]
    call [rax + RT_GET_VARIABLE]
    test rax, rax
    jnz .delete
    mov rax, [run_buf]
    mov [bootinfo + BI_RUN], rax
    mov eax, [run_size]
    mov [bootinfo + BI_RUN_SIZE], eax
.delete:
    lea rcx, [name_axiom_run]               ; SetVariable(name, guid, 0, 0, NULL): gone
    lea rdx, [axiom_guid]
    xor r8d, r8d
    xor r9d, r9d
    mov qword [rsp + 32], 0
    mov rax, [runtime]
    call [rax + RT_SET_VARIABLE]
    call tco_start
.out:
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  find_slot - which kernel starts (A/B updates, src/kernel/update.asm). The
;  one the UEFI variable AxiomTry names, on trial: the variable is marked
;  tried first (its letter made small), so that the trial happens once, and
;  the TCO watchdog is started for it. Else, or if its file cannot be used,
;  the one AxiomSlot names, kept after a trial. Else the kernel built into
;  this loader (load_kernel). A slot is the file \EFI\AXIOM\KERNEL.A or .B
;  on the volume this loader came from; its variable holds the file's size
;  and hash. BI_SLOT and those after it say what happened. Never fatal.
; -----------------------------------------------------------------------------
find_slot:
    sub rsp, 40                             ; shadow space + a fifth argument
    lea rcx, [name_axiom_try]
    lea rdi, [slot_try]
    call slot_variable
    jc .kept
    cmp al, 'A'
    je .trial
    cmp al, 'B'
    jne .kept                               ; tried already (small), or not ours
.trial:
    mov [bootinfo + BI_SLOT_TRY], al
    or byte [slot_try + UV_SLOT], 0x20      ; marked tried, before it starts
    lea rcx, [name_axiom_try]
    lea rdx, [axiom_guid]
    mov r8d, EFI_VAR_NV_BS_RT
    mov r9d, UV_BYTES
    lea rax, [slot_try]
    mov [rsp + 32], rax
    mov rax, [runtime]
    call [rax + RT_SET_VARIABLE]
    test rax, rax
    jz .marked
    mov byte [bootinfo + BI_SLOT_ERR], SLOT_UNMARKED
    jmp .kept                               ; (no trial that might happen again)
.marked:
    lea rbx, [slot_try]
    call load_slot
    jc .try_failed
    mov byte [bootinfo + BI_TRIAL], 1
    mov ax, [slot_try + UV_TRIAL]
    mov [bootinfo + BI_TRIAL_S], ax
    call tco_start                          ; a hang ends in a restart all the same
    jmp .out
.try_failed:
    mov [bootinfo + BI_SLOT_ERR], al
.kept:
    lea rcx, [name_axiom_slot]
    lea rdi, [slot_kept]
    call slot_variable
    jc .out
    cmp al, 'A'
    je .load_kept
    cmp al, 'B'
    jne .out
.load_kept:
    lea rbx, [slot_kept]
    call load_slot
    jnc .out
    shl al, 4
    or [bootinfo + BI_SLOT_ERR], al
.out:
    add rsp, 40
    ret

; slot_variable(RCX = UTF-16 name, RDI = UV_BYTES for it) -> AL = the slot
; it names; CF if it is not there, or not UV_BYTES
slot_variable:
    sub rsp, 40
    mov [slot_buf], rdi
    mov qword [slot_n], UV_BYTES
    lea rdx, [axiom_guid]                   ; GetVariable(name, guid, NULL, &size, buf)
    xor r8d, r8d
    lea r9, [slot_n]
    mov [rsp + 32], rdi
    mov rax, [runtime]
    call [rax + RT_GET_VARIABLE]
    test rax, rax
    jnz .none
    cmp qword [slot_n], UV_BYTES
    jne .none
    mov rdi, [slot_buf]
    mov al, [rdi + UV_SLOT]
    clc
    jmp .out
.none:
    stc
.out:
    lea rsp, [rsp + 40]                     ; (the flags kept)
    ret

; load_slot(RBX = a slot's variable) -> the kernel in its file, in pages of
; its own (kernel_phys, kernel_pages, kernel_entry) and BI_SLOT; CF and
; AL = SLOT_MISSING or SLOT_DAMAGED if not
load_slot:
    sub rsp, 40                             ; shadow space + a fifth argument
    mov [slot_var], rbx
    movzx eax, byte [rbx + UV_SLOT]
    and eax, ~0x20                          ; (a trial's is small by now)
    lea rdi, [slot_path]
    mov [rdi + SLOT_LETTER], ax
    mov qword [slot_root], 0
    mov qword [slot_file], 0
    mov byte [slot_err], SLOT_MISSING
    mov rcx, [boot_device]                  ; HandleProtocol(device, &SFS, &sfs)
    test rcx, rcx
    jz .close
    lea rdx, [sfs_guid]
    lea r8, [slot_sfs]
    mov rax, [boot_services]
    call [rax + BS_HANDLE_PROTOCOL]
    test rax, rax
    jnz .close
    mov rcx, [slot_sfs]                     ; OpenVolume(sfs, &root)
    lea rdx, [slot_root]
    call [rcx + SFS_OPEN_VOLUME]
    test rax, rax
    jnz .no_root
    mov rcx, [slot_root]                    ; Open(root, &file, path, read, 0)
    lea rdx, [slot_file]
    lea r8, [slot_path]
    mov r9d, EFI_FILE_MODE_READ
    mov qword [rsp + 32], 0
    call [rcx + FILE_OPEN]
    test rax, rax
    jnz .no_file
    mov byte [slot_err], SLOT_DAMAGED
    mov qword [slot_n], 32                  ; its header
    mov rcx, [slot_file]
    lea rdx, [slot_n]
    lea r8, [slot_head]
    call [rcx + FILE_READ]
    test rax, rax
    jnz .close
    cmp qword [slot_n], 32
    jne .close
    mov rax, [slot_head + KH_MAGIC]
    mov rdx, 'AXIOMKRN'
    cmp rax, rdx
    jne .close
    mov rbx, [slot_var]
    mov eax, [rbx + UV_SIZE]                ; the size the variable says,
    cmp rax, [slot_head + KH_FILE_SIZE]     ; the header's
    jne .close
    cmp rax, 32
    jb .close
    cmp rax, SLOT_MAX
    ja .close
    mov rcx, [slot_head + KH_MEM_SIZE]
    cmp rcx, rax
    jb .close
    cmp rcx, SLOT_MEM_MAX
    ja .close
    mov rdx, [slot_head + KH_ENTRY]         ; its entry within it
    mov r8, KERNEL_BASE
    sub rdx, r8
    jb .close
    cmp rdx, rcx
    jae .close
    add rcx, 0xFFF
    shr rcx, 12
    mov [kernel_pages], rcx
    xor edx, edx
    call alloc_pages
    mov [kernel_phys], rax
    mov rcx, [slot_file]                    ; SetPosition(file, 0)
    xor edx, edx
    call [rcx + FILE_SET_POSITION]
    test rax, rax
    jnz .unload
    mov rbx, [slot_var]
    mov eax, [rbx + UV_SIZE]
    mov [slot_n], rax
    mov rcx, [slot_file]                    ; Read(file, &size, its pages)
    lea rdx, [slot_n]
    mov r8, [kernel_phys]
    call [rcx + FILE_READ]
    test rax, rax
    jnz .unload
    mov rbx, [slot_var]
    mov ecx, [rbx + UV_SIZE]
    cmp [slot_n], rcx
    jne .unload
    mov rsi, [kernel_phys]
    call fnv64
    mov rbx, [slot_var]
    cmp rax, [rbx + UV_HASH]
    jne .unload
    mov rax, [slot_head + KH_ENTRY]
    mov [kernel_entry], rax
    movzx eax, byte [rbx + UV_SLOT]
    and eax, ~0x20
    mov [bootinfo + BI_SLOT], al
    mov byte [slot_err], SLOT_OK
    jmp .close
.unload:
    mov rcx, [kernel_phys]                  ; given back, and not kept for the kernel
    mov rdx, [kernel_pages]
    mov rax, [boot_services]
    call [rax + BS_FREE_PAGES]
    dec dword [bootinfo + BI_RESV_COUNT]    ; (alloc_pages recorded it last)
    mov qword [kernel_phys], 0
    jmp .close
.no_file:
    mov qword [slot_file], 0
    jmp .close
.no_root:
    mov qword [slot_root], 0
.close:
    mov rcx, [slot_file]
    test rcx, rcx
    jz .root
    call [rcx + FILE_CLOSE]
.root:
    mov rcx, [slot_root]
    test rcx, rcx
    jz .done
    call [rcx + FILE_CLOSE]
.done:
    movzx eax, byte [slot_err]
    cmp al, 1
    cmc                                     ; CF unless SLOT_OK
    lea rsp, [rsp + 40]
    ret

; fnv64(RSI = bytes, RCX = how many) -> RAX = their FNV-1a hash (64-bit)
fnv64:
    mov rax, FNV_BASIS
    mov rdx, FNV_PRIME
    test rcx, rcx
    jz .out
.byte:
    xor al, [rsi]
    imul rax, rdx
    inc rsi
    dec rcx
    jnz .byte
.out:
    ret

; -----------------------------------------------------------------------------
;  tco_start -the chipset's TCO watchdog, counting: it resets the machine
;  unless the kernel reloads it (harness.asm) in time. Two chipsets so far:
;  Tiger Lake's (and later ones, where NO_REBOOT is in TCO1_CNT, Linux's
;  iTCO version 6), and QEMU's ICH9 (version 2: NO_REBOOT in the chipset
;  registers at RCBA). Anything else has none. BI_TCO says where it is.
; -----------------------------------------------------------------------------
TCO_RLD         equ 0x00                    ; written: the count starts again
TCO1_STS        equ 0x04
TCO2_STS        equ 0x06
TCO1_CNT        equ 0x08
TCO_TMR         equ 0x12                    ; the count: ticks of 0.6 s
TCO_TICKS       equ 100                     ; counted twice: a reset 2 minutes on
TCO_TMR_HLT     equ 0x0800
TCO_NO_REBOOT   equ 0x0001                  ; TCO1_CNT's, on version 6
PWRM_ACPI_TMR_CTL equ 0xFE0018FC            ; Tiger Lake's PMC (PWRMBASE 0xFE000000)

tco_start:
    cmp byte [tco_tried], 0                 ; once: for a test run, a trial, or both
    jne .none
    mov byte [tco_tried], 1
    mov byte [tco_v6], 0
    mov eax, 0x8000FC00                     ; 0:31.4, the SMBus controller
    call cfg_read
    lea rsi, [tco_v6_ids]
.v6_next:
    mov ecx, [rsi]
    test ecx, ecx
    jz .ich9
    add rsi, 4
    cmp eax, ecx
    jne .v6_next
    mov eax, 0x8000FC54                     ; TCOCTL: TCO_BASE_EN
    call cfg_read
    test eax, 0x100
    jz .none
    mov eax, 0x8000FC50                     ; TCOBASE
    call cfg_read
    and eax, 0xFFE0
    jz .none
    mov [tco_base], ax
    mov byte [tco_v6], 1
    mov edx, PWRM_ACPI_TMR_CTL              ; Tiger Lake counts the TCO's ticks
    mov eax, [rdx]                          ; only while its ACPI timer runs,
    cmp eax, -1                             ; and hp-1's firmware turns that
    je .found                               ; off (ACPI_TIM_DIS): on
    and eax, ~2
    mov [rdx], eax
    jmp .found
.ich9:
    mov eax, 0x8000F800                     ; 0:31.0, the LPC bridge
    call cfg_read
    cmp eax, 0x29188086                     ; ICH9
    jne .none
    mov eax, 0x8000F840                     ; PMBASE; the TCO's 0x60 above it
    call cfg_read
    and eax, 0xFF80
    jz .none
    add eax, 0x60
    mov [tco_base], ax
    mov eax, 0x8000F8F0                     ; RCBA, where GCS is
    call cfg_read
    test eax, 1
    jnz .rcba
    mov eax, 0x8000F8F0                     ; not there yet: where firmware puts it
    mov ecx, 0xFED1C001
    call cfg_write
    mov eax, 0xFED1C001
.rcba:
    and eax, 0xFFFFC000
    mov ecx, [rax + 0x3410]                 ; GCS: NO_REBOOT is bit 5
    and ecx, ~0x20
    mov [rax + 0x3410], ecx
    mov ecx, [rax + 0x3410]
    test ecx, 0x20
    jnz .locked                             ; strapped on
.found:
    movzx edx, word [tco_base]              ; what it says of the last reset,
    add edx, TCO2_STS
    in ax, dx
    or [bootinfo + BI_TCO_STS], ax
    mov ax, 0x0006                          ; then cleared: SECOND_TO_STS, BOOT_STS
    out dx, ax
    sub edx, TCO2_STS - TCO1_STS
    mov ax, 0x0008                          ; TIMEOUT
    out dx, ax
    add edx, TCO_TMR - TCO1_STS
    in ax, dx
    and ax, 0xFC00
    or ax, TCO_TICKS
    out dx, ax
    sub edx, TCO_TMR - TCO_RLD
    mov ax, 1
    out dx, ax                              ; from the top
    add edx, TCO1_CNT - TCO_RLD
    in ax, dx
    and ax, ~TCO_TMR_HLT                    ; counting,
    cmp byte [tco_v6], 0
    je .count
    and ax, ~TCO_NO_REBOOT                  ; and allowed to reset the machine
.count:
    out dx, ax
    in ax, dx
    test ax, TCO_TMR_HLT
    jnz .none                               ; locked halted
    cmp byte [tco_v6], 0
    je .armed
    test ax, TCO_NO_REBOOT
    jz .armed
    or ax, TCO_TMR_HLT                      ; it would count for nothing: stopped
    out dx, ax
.locked:
    or word [bootinfo + BI_TCO_STS], 0x8000
    jmp .none
.armed:
    mov ax, [tco_base]
    mov [bootinfo + BI_TCO], ax
.none:
    ret

; cfg_read(EAX = 0x80000000 | bus << 16 | device << 11 | function << 8 |
; register) -> EAX = that dword of PCI configuration space
cfg_read:
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    ret

; cfg_write(EAX = the same address, ECX = the dword)
cfg_write:
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    ret

; -----------------------------------------------------------------------------
;  alloc_pages - RCX = pages, RDX = highest acceptable address (0 = anywhere)
;  Returns RAX = physical address of zeroed pages, recorded as reserved.
; -----------------------------------------------------------------------------
alloc_pages:
    sub rsp, 40
    mov [alloc_count], rcx
    mov [alloc_addr], rdx
    mov ecx, ALLOCATE_ANY_PAGES
    test rdx, rdx
    jz .call
    mov ecx, ALLOCATE_MAX_ADDRESS
.call:
    mov edx, EFI_LOADER_DATA
    mov r8, [alloc_count]
    lea r9, [alloc_addr]
    mov rax, [boot_services]
    call [rax + BS_ALLOCATE_PAGES]
    test rax, rax
    jnz .fail
    mov rdi, [alloc_addr]
    mov rcx, [alloc_count]
    shl rcx, 9
    xor eax, eax
    rep stosq
    mov eax, [bootinfo + BI_RESV_COUNT]     ; record { phys, bytes }
    cmp eax, BI_RESV_MAX
    jae .fail
    shl eax, 4
    lea rdi, [bootinfo + BI_RESV]
    add rdi, rax
    mov rax, [alloc_addr]
    mov [rdi], rax
    mov rax, [alloc_count]
    shl rax, 12
    mov [rdi + 8], rax
    inc dword [bootinfo + BI_RESV_COUNT]
    mov rax, [alloc_addr]
    add rsp, 40
    ret
.fail:
    lea rdx, [msg_no_memory]
    jmp fatal

; -----------------------------------------------------------------------------
;  load_kernel - copy the embedded kernel image into its own pages, unless
;  find_slot loaded one from a slot
; -----------------------------------------------------------------------------
load_kernel:
    sub rsp, 40
    cmp qword [kernel_phys], 0
    jne .stack
    lea rsi, [kernel_image]
    mov rax, [rsi + KH_MAGIC]
    mov rdx, 'AXIOMKRN'
    cmp rax, rdx
    jne .bad
    mov rax, [rsi + KH_ENTRY]
    mov [kernel_entry], rax
    mov rcx, [rsi + KH_MEM_SIZE]
    add rcx, 0xFFF
    shr rcx, 12
    mov [kernel_pages], rcx
    xor edx, edx
    call alloc_pages
    mov [kernel_phys], rax
    mov rdi, rax
    lea rsi, [kernel_image]
    mov rcx, [rsi + KH_FILE_SIZE]
    rep movsb

.stack:
    mov ecx, BOOT_STACK_SIZE / 4096
    xor edx, edx
    call alloc_pages
    mov [stack_phys], rax

    mov ecx, 1
    xor edx, edx
    call alloc_pages
    mov [bootinfo_page], rax
    add rsp, 40
    ret
.bad:
    lea rdx, [msg_bad_kernel]
    jmp fatal

; -----------------------------------------------------------------------------
;  get_memory_map - into mmap_buffer, allocating it (with slack) the first time
; -----------------------------------------------------------------------------
get_memory_map:
    sub rsp, 56
    cmp qword [mmap_buffer], 0
    jne .fetch
    mov qword [mmap_size], 0                ; ask for the size
    lea rcx, [mmap_size]
    xor edx, edx
    lea r8, [mmap_key]
    lea r9, [mmap_desc_size]
    lea rax, [mmap_desc_version]
    mov [rsp + 32], rax
    mov rax, [boot_services]
    call [rax + BS_GET_MEMORY_MAP]
    mov rcx, [mmap_size]
    add rcx, 0x4000 + 0xFFF                 ; room for descriptors our allocations add
    shr rcx, 12
    mov [mmap_capacity], rcx
    xor edx, edx
    call alloc_pages
    mov [mmap_buffer], rax
    shl qword [mmap_capacity], 12
.fetch:
    mov rax, [mmap_capacity]
    mov [mmap_size], rax
    lea rcx, [mmap_size]
    mov rdx, [mmap_buffer]
    lea r8, [mmap_key]
    lea r9, [mmap_desc_size]
    lea rax, [mmap_desc_version]
    mov [rsp + 32], rax
    mov rax, [boot_services]
    call [rax + BS_GET_MEMORY_MAP]
    test rax, rax
    jnz .fail
    add rsp, 56
    ret
.fail:
    lea rdx, [msg_mmap]
    jmp fatal

; -----------------------------------------------------------------------------
;  build_page_tables
;    PML4[0]   -> identity map of [0, phys_top) in 2 MiB pages (shared PDPT)
;    PML4[256] -> the same PDPT: the direct map at PHYS_BASE
;    PML4[511] -> PDPT[510]: kernel image in 4 KiB pages at KERNEL_BASE
;              -> PDPT[508]: framebuffer in 4 KiB write-combining pages at FB_VIRT
; -----------------------------------------------------------------------------
build_page_tables:
    sub rsp, 40
    call get_memory_map

    mov rsi, [mmap_buffer]                  ; phys_top = highest non-MMIO address
    mov rcx, [mmap_size]
    xor edx, edx
.top_loop:
    cmp rcx, [mmap_desc_size]
    jb .top_done
    mov eax, [rsi + MD_TYPE]
    cmp eax, MT_MMIO
    je .top_next
    cmp eax, MT_MMIO_PORT
    je .top_next
    mov rax, [rsi + MD_PAGES]
    shl rax, 12
    add rax, [rsi + MD_PHYS]
    cmp rax, rdx
    cmova rdx, rax
.top_next:
    add rsi, [mmap_desc_size]
    sub rcx, [mmap_desc_size]
    jmp .top_loop
.top_done:
    mov rax, 0x100000000                    ; always cover the 4 GiB MMIO hole
    cmp rdx, rax
    cmovb rdx, rax
    add rdx, 0x3FFFFFFF                     ; whole GiB
    and rdx, ~0x3FFFFFFF
    mov rax, 512 << 30                      ; one PDPT: 512 GiB
    cmp rdx, rax
    cmova rdx, rax
    mov [phys_top], rdx

    shr rdx, 30
    mov [direct_pds], rdx
    mov rax, [kernel_pages]
    add rax, 511
    shr rax, 9
    mov [kernel_pts], rax
    mov rax, [bootinfo + BI_FB_PHYS]
    and eax, 0xFFF
    add rax, [bootinfo + BI_FB_SIZE]
    add rax, 0xFFF
    shr rax, 12
    mov [fb_pages], rax
    add rax, 511
    shr rax, 9
    mov [fb_pts], rax

    mov rcx, 5                              ; PML4, 2 PDPTs, kernel PD, fb PD
    add rcx, [direct_pds]
    add rcx, [kernel_pts]
    add rcx, [fb_pts]
    mov edx, 0xFFFFFFFF                     ; APs load CR3 from 32-bit code
    call alloc_pages
    mov [pml4], rax
    lea rbx, [rax + 0x1000]
    mov [pdpt_low], rbx
    lea rbx, [rax + 0x2000]
    mov [pdpt_high], rbx
    lea rbx, [rax + 0x3000]
    mov [pd_kernel], rbx
    lea rbx, [rax + 0x4000]
    mov [pd_fb], rbx
    lea rbx, [rax + 0x5000]
    mov [pd_direct], rbx
    mov rcx, [direct_pds]
    shl rcx, 12
    add rbx, rcx
    mov [pt_kernel], rbx
    mov rcx, [kernel_pts]
    shl rcx, 12
    add rbx, rcx
    mov [pt_fb], rbx

    mov rdi, [pml4]
    mov rax, [pdpt_low]
    or rax, 3                               ; present, writable
    mov [rdi], rax
    mov [rdi + 256 * 8], rax
    mov rax, [pdpt_high]
    or rax, 3
    mov [rdi + 511 * 8], rax

    mov rdi, [pdpt_low]                     ; PDPT -> one PD per GiB
    mov rax, [pd_direct]
    or rax, 3
    mov rcx, [direct_pds]
.pdpt_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x1000
    dec rcx
    jnz .pdpt_fill

    mov rdi, [pd_direct]                    ; 2 MiB pages, write-back
    mov rcx, [direct_pds]
    shl rcx, 9
    mov eax, 0x83                           ; present, writable, large
.pd_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x200000
    dec rcx
    jnz .pd_fill

    mov rdi, [pdpt_high]
    mov rax, [pd_kernel]
    or rax, 3
    mov [rdi + 510 * 8], rax
    mov rax, [pd_fb]
    or rax, 3
    mov [rdi + 508 * 8], rax

    mov rdi, [pd_kernel]
    mov rax, [pt_kernel]
    or rax, 3
    mov rcx, [kernel_pts]
.kpd_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x1000
    dec rcx
    jnz .kpd_fill

    mov rdi, [pt_kernel]
    mov rax, [kernel_phys]
    or rax, 3
    mov rcx, [kernel_pages]
.kpt_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x1000
    dec rcx
    jnz .kpt_fill

    mov rdi, [pd_fb]
    mov rax, [pt_fb]
    or rax, 3
    mov rcx, [fb_pts]
.fpd_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x1000
    dec rcx
    jnz .fpd_fill

    mov rdi, [pt_fb]
    mov rax, [bootinfo + BI_FB_PHYS]
    and rax, ~0xFFF
    or rax, 0x83                            ; present, writable, PAT bit -> PA4 = WC
    mov rcx, [fb_pages]
.fpt_fill:
    mov [rdi], rax
    add rdi, 8
    add rax, 0x1000
    dec rcx
    jnz .fpt_fill

    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  leave_boot_services - final memory map, then ExitBootServices (with retries)
; -----------------------------------------------------------------------------
leave_boot_services:
    sub rsp, 40
    mov dword [exit_tries], 0
.again:
    call get_memory_map
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [bootinfo + BI_TSC_EXIT], rax
    mov rcx, [image_handle]
    mov rdx, [mmap_key]
    mov rax, [boot_services]
    call [rax + BS_EXIT_BOOT_SERVICES]
    test rax, rax
    jz .done
    inc dword [exit_tries]                  ; the map changed under us: fetch and retry
    cmp dword [exit_tries], 8
    jb .again
    lea rdx, [msg_exit]
    jmp fatal
.done:
    add rsp, 40
    ret

; -----------------------------------------------------------------------------
;  enter_kernel - no firmware from here on
; -----------------------------------------------------------------------------
enter_kernel:
    cli
    mov rax, [mmap_buffer]
    mov [bootinfo + BI_MMAP], rax
    mov rax, [mmap_size]
    mov [bootinfo + BI_MMAP_SIZE], rax
    mov rax, [mmap_desc_size]
    mov [bootinfo + BI_MMAP_DSIZE], rax
    mov rax, [pml4]
    mov [bootinfo + BI_PML4], rax
    mov rax, [phys_top]
    mov [bootinfo + BI_PHYS_TOP], rax
    mov rax, 'AXIOMBI1'
    mov [bootinfo + BI_MAGIC], rax

    mov rdi, [bootinfo_page]                ; the loader image becomes free memory
    lea rsi, [bootinfo]
    mov ecx, BI_SIZE
    rep movsb

    mov ecx, MSR_PAT                        ; PA4 = write-combining for the framebuffer
    mov eax, PAT_VALUE_LO
    mov edx, PAT_VALUE_HI
    wrmsr

    mov rax, [pml4]
    mov cr3, rax                            ; identity map keeps this code alive

    mov rbx, PHYS_BASE
    mov rsp, [stack_phys]
    add rsp, BOOT_STACK_SIZE
    add rsp, rbx
    mov rdi, [bootinfo_page]
    add rdi, rbx
    mov rax, [kernel_entry]
    xor ebp, ebp
    jmp rax

; =============================================================================
;  data
; =============================================================================
align 8
image_handle:       dq 0
system_table:       dq 0
boot_services:      dq 0
con_out:            dq 0
entry_rsp:          dq 0
fatal_reason:       dq 0
gop:                dq 0
info_size:          dq 0
info_ptr:           dq 0
tsc_mark:           dq 0
alloc_count:        dq 0
alloc_addr:         dq 0
kernel_entry:       dq 0
boot_proto:         dq 0
boot_sector:        dq 0
kernel_phys:        dq 0
kernel_pages:       dq 0
stack_phys:         dq 0
bootinfo_page:      dq 0
mmap_buffer:        dq 0
mmap_capacity:      dq 0
mmap_size:          dq 0
mmap_key:           dq 0
mmap_desc_size:     dq 0
mmap_desc_version:  dq 0
phys_top:           dq 0
direct_pds:         dq 0
kernel_pts:         dq 0
fb_pages:           dq 0
fb_pts:             dq 0
pml4:               dq 0
pdpt_low:           dq 0
pdpt_high:          dq 0
pd_direct:          dq 0
pd_kernel:          dq 0
pd_fb:              dq 0
pt_kernel:          dq 0
pt_fb:              dq 0
runtime:            dq 0
run_size:           dq 0
run_buf:            dq 0
run_probe:          dq 0
gop_max_mode:       dd 0
mode_iter:          dd 0
best_mode:          dd 0
best_w:             dd 0
best_h:             dd 0
exit_tries:         dd 0
boot_block:         dd 0
tco_base:           dw 0
tco_v6:             db 0
tco_tried:          db 0
slot_err:           db 0
align 8
boot_device:        dq 0                ; the handle of the volume this loader came from
slot_var:           dq 0                ; find_slot's: the variable being loaded,
slot_buf:           dq 0
slot_n:             dq 0
slot_sfs:           dq 0                ; the volume's EFI_SIMPLE_FILE_SYSTEM_PROTOCOL,
slot_root:          dq 0                ; its root,
slot_file:          dq 0                ; the slot's file,
slot_head:          times 4 dq 0        ; its first 32 bytes
slot_try:           times 2 dq 0        ; AxiomTry
slot_kept:          times 2 dq 0        ; AxiomSlot

align 4
tco_v6_ids:     dd 0xA0A38086                   ; Tiger Lake-LP's SMBus controller
                dd 0x43A38086                   ; Tiger Lake-H's
                dd 0
name_axiom_run: dw __utf16__('AxiomRun'), 0     ; (aligned: UTF-16)
name_axiom_try: dw __utf16__('AxiomTry'), 0
name_axiom_slot: dw __utf16__('AxiomSlot'), 0
slot_path:      dw __utf16__('\EFI\AXIOM\KERNEL.A'), 0
SLOT_LETTER     equ 18 * 2                      ; where in slot_path the A is

align 8
axiom_guid:     AXIOM_VENDOR_GUID

align 8
gop_guid:       dd 0x9042A9DE
                dw 0x23DC, 0x4A38
                db 0x96, 0xFB, 0x7A, 0xDE, 0xD0, 0x80, 0x51, 0x6A
acpi20_guid:    dd 0x8868E871
                dw 0xE4F1, 0x11D3
                db 0xBC, 0x22, 0x00, 0x80, 0xC7, 0x3C, 0x88, 0x81
acpi10_guid:    dd 0xEB9D2D30
                dw 0x2D88, 0x11D3
                db 0x9A, 0x16, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D
smbios3_guid:   dd 0xF2FD1544
                dw 0x9794, 0x4A2C
                db 0x99, 0x2E, 0xE5, 0xBB, 0xCF, 0x20, 0xE3, 0x94
loaded_image_guid:
                dd 0x5B1B31A1
                dw 0x9562, 0x11D2
                db 0x8E, 0x3F, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
block_io_guid:  dd 0x964E5B21
                dw 0x6459, 0x11D2
                db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
sfs_guid:       dd 0x964E5B22
                dw 0x6459, 0x11D2
                db 0x8E, 0x39, 0x00, 0xA0, 0xC9, 0x69, 0x72, 0x3B
smbios2_guid:   dd 0xEB9D2D31
                dw 0x2D88, 0x11D3
                db 0x9A, 0x16, 0x00, 0x90, 0x27, 0x3F, 0xC1, 0x4D

msg_banner:     dw __utf16__(`Axiom loader\r\n`), 0
msg_launch:     dw __utf16__(`Entering the kernel.\r\n`), 0
msg_fatal:      dw __utf16__(`\r\nAxiom cannot start: `), 0
msg_no_gop:     dw __utf16__(`no graphics output protocol.\r\n`), 0
msg_fb_format:  dw __utf16__(`the display has no 32-bit linear framebuffer.\r\n`), 0
msg_no_memory:  dw __utf16__(`out of memory while loading.\r\n`), 0
msg_bad_kernel: dw __utf16__(`the embedded kernel image is damaged.\r\n`), 0
msg_mmap:       dw __utf16__(`GetMemoryMap failed.\r\n`), 0
msg_exit:       dw __utf16__(`ExitBootServices keeps failing.\r\n`), 0
msg_la57:       dw __utf16__(`firmware enabled 5-level paging; not supported yet.\r\n`), 0

align 16
bootinfo:       times BI_SIZE db 0

align 4096
kernel_image:   incbin "kernel.bin"

    align ALIGNMENT, db 0
text_end:

; =============================================================================
;  .reloc: one block of no-op entries. The image is position-independent, but
;  some firmware refuses to relocate an image without a relocation directory.
; =============================================================================
reloc_start:
    dd 0                                    ; page RVA
    dd 12                                   ; block size
    dw 0, 0                                 ; IMAGE_REL_BASED_ABSOLUTE padding
reloc_data_end:
    align ALIGNMENT, db 0
reloc_end:
image_end:
