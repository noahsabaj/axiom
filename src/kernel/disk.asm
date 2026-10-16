; =============================================================================
;  disk.asm - block devices and the volumes on them. A driver registers a disk
;  with a table of operations; its partition table (GPT, else MBR, else a
;  filesystem on the bare disk) becomes volumes. Every volume starts
;  read-only and stays that way until 'vol <n> rw': the drive in this machine
;  holds Windows, and nothing Axiom does should surprise it.
; =============================================================================

MAX_DISK        equ 8
DK_BLOCKS       equ 0                   ; size in blocks
DK_SHIFT        equ 8                   ; log2 of the block size
DK_CTX          equ 16                  ; the driver's own
DK_OPS          equ 24
DK_KIND         equ 32                  ; "NVMe"
DK_INDEX        equ 40                  ; qword
DK_FLAGS        equ 48
DK_SIZE         equ 64

DKF_GONE        equ 1                   ; unplugged: its slot may be reused
DKF_REMOVABLE   equ 2

; operations: RBX = disk; read and write take RSI = block, EDX = blocks,
; RDI = buffer; describe takes RDI = text buffer. CF on failure.
DOP_READ        equ 0
DOP_WRITE       equ 8
DOP_FLUSH       equ 16
DOP_DESCRIBE    equ 24

MAX_VOL         equ 16
VO_DISK         equ 0
VO_START        equ 8                   ; first block on the disk
VO_COUNT        equ 16                  ; blocks
VO_TYPE         equ 24                  ; partition type, as text
VO_FS           equ 32
VO_WRITABLE     equ 36                  ; byte: 'vol <n> rw'
VO_PART         equ 37                  ; byte: partition number, 0 = whole disk
VO_DISKNO       equ 38                  ; byte
VO_INDEX        equ 39                  ; byte
VO_LABEL        equ 40                  ; 40 bytes
VO_GONE         equ 120                 ; byte: its disk was unplugged
VO_FAT          equ 128                 ; fat.asm's state
VO_SIZE         equ 512

FS_NONE         equ 0
FS_FAT32        equ 1
FS_NTFS         equ 2
FS_EXFAT        equ 3
FS_FAT16        equ 4

section .text

; disk_init: the NVMe drives, their partitions, a current volume. USB
; sticks found by usb_init are already registered; later ones arrive
; through hot-plug.
disk_init:
    call nvme_init
    call vol_pick
    cmp dword [disk_count], 0
    jne .out
    KLOG "disk: no drives"
.out:
    ret

; vol_pick: choose the current volume when there is none, or when it is on a
; fixed disk and a removable one has FAT32 (unless 'vol <n>' chose it).
; Removable first: on this machine the fixed drive is Windows'. Preserves all.
vol_pick:
    push rax
    push rcx
    push r8
    push r14
    mov r14, [vol_current]
    test r14, r14
    jz .look
    cmp byte [vol_chosen], 0
    jne .out
    mov rax, [r14 + VO_DISK]
    test dword [rax + DK_FLAGS], DKF_REMOVABLE
    jnz .out
.look:
    xor r8d, r8d                        ; the first usable one on a fixed disk
    xor ecx, ecx
.next:
    cmp ecx, [vol_count]
    jae .end
    imul r14, rcx, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    inc ecx
    cmp byte [r14 + VO_GONE], 0
    jne .next
    cmp dword [r14 + VO_FS], FS_FAT32
    jne .next
    cmp byte [r14 + VF_MOUNTED], 0
    je .next
    mov rax, [r14 + VO_DISK]
    test dword [rax + DK_FLAGS], DKF_REMOVABLE
    jnz .take
    test r8, r8
    jnz .next
    mov r8, r14
    jmp .next
.end:
    cmp qword [vol_current], 0
    jne .out                            ; nothing removable: keep it
    mov r14, r8
    test r14, r14
    jz .out
.take:
    cmp r14, [vol_current]
    je .out
    mov [vol_current], r14
    movzx eax, byte [r14 + VO_INDEX]
    lea rcx, [r14 + VO_LABEL]
    KLOG "vol%u (%s) is the current volume", rax, rcx
.out:
    pop r14
    pop r8
    pop rcx
    pop rax
    ret

; disk_add(RDI = kind, RSI = blocks, ECX = log2 of the block size, RDX = the
; driver's context, R8 = operations, R9D = DKF_ flags) -> RAX = disk, 0 if
; the table is full. Reads its partitions. Preserves others.
disk_add:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r10
    xor r10d, r10d                      ; a slot an unplugged disk left?
.find:
    cmp r10d, [disk_count]
    jae .append
    imul rbx, r10, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .take
    inc r10d
    jmp .find
.append:
    cmp r10d, MAX_DISK
    jae .full
    imul rbx, r10, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    inc dword [disk_count]
.take:
    mov [rbx + DK_INDEX], r10
    mov [rbx + DK_KIND], rdi
    mov [rbx + DK_BLOCKS], rsi
    mov [rbx + DK_SHIFT], ecx
    mov [rbx + DK_CTX], rdx
    mov [rbx + DK_OPS], r8
    mov [rbx + DK_FLAGS], r9d
    lea rdi, [dk_text]
    call [r8 + DOP_DESCRIBE]
    mov rax, rsi
    shl rax, cl
    mov edx, 1
    shl edx, cl
    lea rcx, [dk_text]
    KLOG "disk%u: %s, %b in %u-byte blocks, %s", qword [rbx + DK_INDEX], qword [rbx + DK_KIND], rax, rdx, rcx
    call disk_scan
    call vol_pick
    mov rax, rbx
    jmp .out
.full:
    xor eax, eax
.out:
    pop r10
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; disk_gone(RBX = disk): unplugged. Its volumes go, and with them anything
; cached from them. Preserves all.
disk_gone:
    push rax
    push rcx
    push r14
    or dword [rbx + DK_FLAGS], DKF_GONE
    KLOG "disk%u removed", qword [rbx + DK_INDEX]
    xor ecx, ecx
.vol:
    cmp ecx, [vol_count]
    jae .done
    imul r14, rcx, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    inc ecx
    cmp [r14 + VO_DISK], rbx
    jne .vol
    cmp byte [r14 + VO_GONE], 0
    jne .vol
    mov byte [r14 + VO_GONE], 1
    mov byte [r14 + VO_WRITABLE], 0
    mov byte [r14 + VF_MOUNTED], 0
    mov dword [r14 + VO_FS], FS_NONE
    call fat_forget
    cmp r14, [vol_current]
    jne .vol
    mov qword [vol_current], 0
    mov byte [vol_chosen], 0
    jmp .vol
.done:
    call vol_pick
    pop r14
    pop rcx
    pop rax
    ret

; disk_read / disk_write(RBX = disk, RSI = block, EDX = blocks, RDI = buffer)
; -> CF on failure or out of range. Preserve all but RAX.
disk_read:
    push rcx
    mov ecx, DOP_READ
    jmp disk_io
disk_write:
    push rcx
    mov ecx, DOP_WRITE
disk_io:
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .gone
    test edx, edx
    jz .none
    mov eax, edx
    add rax, rsi
    jc .range
    cmp rax, [rbx + DK_BLOCKS]
    ja .range
    mov rax, [rbx + DK_OPS]
    call [rax + rcx]
    pop rcx
    ret
.none:
    clc
    pop rcx
    ret
.range:
    mov eax, edx
    KLOG "disk%u: blocks %u + %u are past the end", qword [rbx + DK_INDEX], rsi, rax
    stc
    pop rcx
    ret
.gone:
    KLOG "disk%u is gone", qword [rbx + DK_INDEX]
    stc
    pop rcx
    ret

; disk_flush(RBX = disk) -> CF. Preserves all but RAX.
disk_flush:
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .gone
    mov rax, [rbx + DK_OPS]
    jmp [rax + DOP_FLUSH]
.gone:
    stc
    ret

; -----------------------------------------------------------------------------
;  Partitions
; -----------------------------------------------------------------------------

; disk_scan(RBX = disk): its partitions become volumes
disk_scan:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r12
    push r13
    push r14
    lea rdi, [dk_sec]                   ; the GPT header, at block 1
    mov esi, 1
    mov edx, 1
    call disk_read
    jc .out
    mov rax, 'EFI PART'
    cmp [dk_sec], rax
    jne .mbr
    mov rax, [dk_sec + 72]              ; the entry array
    mov [gpt_lba], rax
    mov eax, [dk_sec + 80]
    cmp eax, 128
    jbe .count
    mov eax, 128
.count:
    mov [gpt_count], eax
    mov eax, [dk_sec + 84]              ; entry size: 128, 256, .. up to a block
    mov [gpt_esize], eax
    cmp eax, 128
    jb .mbr
    lea edx, [eax - 1]
    test eax, edx
    jnz .mbr
    mov ecx, [rbx + DK_SHIFT]
    mov edx, 1
    shl edx, cl
    cmp eax, edx
    ja .mbr
    xor r12d, r12d
.entry:
    cmp r12d, [gpt_count]
    jae .out
    mov eax, r12d
    imul eax, [gpt_esize]
    mov r13d, eax
    mov ecx, [rbx + DK_SHIFT]
    shr eax, cl
    mov rsi, [gpt_lba]
    add rsi, rax
    mov edx, 1
    lea rdi, [dk_sec]
    call disk_read
    jc .out
    mov eax, 1
    shl eax, cl
    dec eax
    and r13d, eax
    lea rax, [dk_sec]
    add r13, rax
    mov rax, [r13]                      ; unused entries have no type
    or rax, [r13 + 8]
    jz .next_entry
    mov rsi, r13
    call gpt_type_name
    mov rdi, rax
    mov rsi, [r13 + 32]                 ; first and last block
    mov rdx, [r13 + 40]
    sub rdx, rsi
    jb .next_entry
    inc rdx
    lea r8, [r13 + 56]
    lea ecx, [r12d + 1]
    call vol_add
.next_entry:
    inc r12d
    jmp .entry
.mbr:
    lea rdi, [dk_sec]
    xor esi, esi
    mov edx, 1
    call disk_read
    jc .out
    cmp word [dk_sec + 510], 0xAA55
    jne .out
    call fs_signature                   ; a filesystem on the bare disk?
    test eax, eax
    jz .table
    xor esi, esi
    mov rdx, [rbx + DK_BLOCKS]
    lea rdi, [str_vt_whole]
    xor r8d, r8d
    xor ecx, ecx
    call vol_add
    jmp .out
.table:
    xor r12d, r12d
.part:
    cmp r12d, 4
    jae .out
    mov eax, r12d
    shl eax, 4
    lea r13, [dk_sec + 446]
    add r13, rax
    movzx eax, byte [r13 + 4]
    test eax, eax
    jz .next_part
    cmp eax, 0xEE                       ; GPT's protective entry
    je .next_part
    cmp eax, 0x05                       ; extended partitions: not followed
    je .next_part
    cmp eax, 0x0F
    je .next_part
    call mbr_type_name
    mov rdi, rax
    mov esi, [r13 + 8]
    mov edx, [r13 + 12]
    xor r8d, r8d
    lea ecx, [r12d + 1]
    call vol_add
    lea rdi, [dk_sec]                   ; vol_add read the volume: back again
    xor esi, esi
    mov edx, 1
    call disk_read
    jc .out
.next_part:
    inc r12d
    jmp .part
.out:
    pop r14
    pop r13
    pop r12
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; fs_signature(dk_sec = a first block) -> EAX = FS_*. Preserves others.
fs_signature:
    push rcx
    xor eax, eax
    cmp word [dk_sec + 510], 0xAA55
    jne .out
    mov rcx, 'NTFS    '
    cmp [dk_sec + 3], rcx
    je .ntfs
    mov rcx, 'EXFAT   '
    cmp [dk_sec + 3], rcx
    je .exfat
    mov rcx, 'FAT32   '
    cmp [dk_sec + 82], rcx
    je .fat32
    mov ecx, [dk_sec + 54]
    and ecx, 0xFFFFFF
    cmp ecx, 'FAT'
    jne .out
    mov eax, FS_FAT16
    jmp .out
.ntfs:
    mov eax, FS_NTFS
    jmp .out
.exfat:
    mov eax, FS_EXFAT
    jmp .out
.fat32:
    mov eax, FS_FAT32
.out:
    pop rcx
    ret

; gpt_type_name(RSI = type GUID) -> RAX = its name. Preserves others.
gpt_type_name:
    push rcx
    push rdx
    lea rcx, [gpt_types]
.next:
    mov rax, [rcx + 16]
    test rax, rax
    jz .unknown
    mov rdx, [rcx]
    cmp rdx, [rsi]
    jne .skip
    mov rdx, [rcx + 8]
    cmp rdx, [rsi + 8]
    je .out
.skip:
    add rcx, 24
    jmp .next
.unknown:
    lea rax, [str_vt_other]
.out:
    pop rdx
    pop rcx
    ret

; mbr_type_name(EAX = MBR type byte) -> RAX = name. Preserves others.
mbr_type_name:
    push rcx
    lea rcx, [mbr_types]
.next:
    cmp byte [rcx], 0
    je .unknown
    cmp [rcx], al
    je .found
    add rcx, 16
    jmp .next
.found:
    mov rax, [rcx + 8]
    jmp .out
.unknown:
    lea rax, [str_vt_mbr]
.out:
    pop rcx
    ret

; vol_add(RBX = disk, RSI = first block, RDX = blocks, RDI = type name,
; R8 = UTF-16 name (36 characters) or 0, ECX = partition number)
; -> R14 = volume; CF if it does not fit the disk or the table is full.
; Finds its filesystem and mounts FAT32. Preserves others.
vol_add:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    test rdx, rdx
    jz .fail
    mov rax, rsi
    add rax, rdx
    jc .fail
    cmp rax, [rbx + DK_BLOCKS]
    ja .fail
    push rcx
    xor ecx, ecx                        ; a slot an unplugged disk left?
.find:
    cmp ecx, [vol_count]
    jae .append
    imul r14, rcx, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    cmp byte [r14 + VO_GONE], 0
    jne .reuse
    inc ecx
    jmp .find
.append:
    cmp ecx, MAX_VOL
    jae .full
    imul r14, rcx, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    inc dword [vol_count]
.reuse:
    push rdi
    push rcx
    mov rdi, r14
    mov ecx, VO_SIZE / 8
    xor eax, eax
    rep stosq
    pop rcx
    pop rdi
    mov [r14 + VO_INDEX], cl
    pop rcx
    mov [r14 + VO_DISK], rbx
    mov [r14 + VO_START], rsi
    mov [r14 + VO_COUNT], rdx
    mov [r14 + VO_TYPE], rdi
    mov [r14 + VO_PART], cl
    mov eax, [rbx + DK_INDEX]
    mov [r14 + VO_DISKNO], al
    test r8, r8
    jz .named
    lea rdi, [r14 + VO_LABEL]
    xor ecx, ecx
.char:
    movzx eax, word [r8 + rcx * 2]
    test eax, eax
    jz .named
    cmp eax, ' '
    jb .odd
    cmp eax, 0x7F
    jb .ascii
.odd:
    mov eax, '?'
.ascii:
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 36
    jb .char
.named:
    lea rdi, [dk_sec]                   ; what is on it
    xor esi, esi
    mov edx, 1
    call vol_read
    jc .done
    call fs_signature
    mov [r14 + VO_FS], eax
    cmp eax, FS_FAT32
    jne .done
    cmp byte [r14 + VO_LABEL], 0
    jne .mount
    lea rsi, [dk_sec + 71]              ; the FAT label, unless it is the default
    mov rax, 'NO NAME '
    cmp [rsi], rax
    je .mount
    lea rdi, [r14 + VO_LABEL]
    mov ecx, 11
    call nvme_copy_text
.mount:
    call fat_mount
.done:
    clc
    jmp .out
.full:
    pop rcx
.fail:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; vol_read / vol_write(R14 = volume, RSI = block within it, EDX = blocks,
; RDI = buffer) -> CF on failure. Writes need 'vol <n> rw'.
; Preserve all but RAX.
vol_read:
    push rcx
    xor ecx, ecx
    jmp vol_io
vol_write:
    push rcx
    mov ecx, 1
    cmp byte [r14 + VO_WRITABLE], 0
    jne vol_io
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u is read-only ('vol %u rw' allows writes)", rax, rax
    stc
    pop rcx
    ret
vol_io:
    push rbx
    push rsi
    mov eax, edx
    add rax, rsi
    jc .range
    cmp rax, [r14 + VO_COUNT]
    ja .range
    add rsi, [r14 + VO_START]
    mov rbx, [r14 + VO_DISK]
    test ecx, ecx
    jnz .write
    call disk_read
    jmp .out
.write:
    call disk_write
    jmp .out
.range:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u: block %u is past its end", rax, rsi
    stc
.out:
    pop rsi
    pop rbx
    pop rcx
    ret

; vol_describe(R14 = volume): one line about it
vol_describe:
    push rax
    push rcx
    push rdx
    push rsi
    mov eax, ' '
    cmp r14, [vol_current]
    jne .mark
    mov eax, '*'
.mark:
    mov rsi, [r14 + VO_DISK]
    mov rdx, [r14 + VO_COUNT]
    mov ecx, [rsi + DK_SHIFT]
    shl rdx, cl
    mov ecx, [r14 + VO_FS]
    lea rsi, [fs_names]
    mov rcx, [rsi + rcx * 8]
    lea rsi, [str_vol_ro]
    cmp byte [r14 + VO_WRITABLE], 0
    je .mode
    lea rsi, [str_vol_rw]
.mode:
    push rbx
    push r8
    push r9
    movzx ebx, byte [r14 + VO_INDEX]
    movzx r8d, byte [r14 + VO_PART]
    lea r9, [r14 + VO_LABEL]
    KLOG "  %c vol%-2u p%-3u %-20s %10b  %-6s %-10s %s", rax, rbx, r8, qword [r14 + VO_TYPE], rdx, rcx, rsi, r9
    pop r9
    pop r8
    pop rbx
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Shell: disks, vol
; -----------------------------------------------------------------------------
cmd_disks:
    push rbx
    push r12
    push r13
    push r14
    cmp dword [disk_count], 0
    jne .list
    KLOG "no drives (Axiom drives NVMe SSDs and USB sticks)"
    jmp .out
.list:
    xor r12d, r12d
.disk:
    cmp r12d, [disk_count]
    jae .out
    imul rbx, r12, DK_SIZE
    lea rax, [disks]
    add rbx, rax
    test dword [rbx + DK_FLAGS], DKF_GONE
    jnz .next_disk
    lea rdi, [dk_text]
    mov rax, [rbx + DK_OPS]
    call [rax + DOP_DESCRIBE]
    mov rax, [rbx + DK_BLOCKS]
    mov ecx, [rbx + DK_SHIFT]
    shl rax, cl
    lea rdx, [dk_text]
    KLOG "disk%u  %s, %b: %s", r12, qword [rbx + DK_KIND], rax, rdx
    xor r13d, r13d
.vol:
    cmp r13d, [vol_count]
    jae .next_disk
    imul r14, r13, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    cmp [r14 + VO_DISK], rbx
    jne .next_vol
    cmp byte [r14 + VO_GONE], 0
    jne .next_vol
    call vol_describe
.next_vol:
    inc r13d
    jmp .vol
.next_disk:
    inc r12d
    jmp .disk
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; vol             the current volume
; vol <n>         make it current
; vol <n> rw|ro   and allow or stop writes
cmd_vol:
    push rbx
    push r12
    push r14
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    jne .args
    mov r14, [vol_current]
    test r14, r14
    jz .none
    call vol_describe
    jmp .out
.none:
    KLOG "no volume chosen: 'disks' lists them, 'vol <n>' picks one"
    jmp .out
.args:
    call arg_split
    mov r12, rdi
    call arg_uint
    jc .usage
    cmp eax, [vol_count]
    jae .missing
    mov ebx, eax
    imul r14, rax, VO_SIZE
    lea rax, [volumes]
    add r14, rax
    mov eax, ebx
    cmp byte [r14 + VO_GONE], 0
    jne .missing
    mov rsi, r12
    cmp byte [rsi], 0
    je .select
    lea rdi, [str_vol_arg_rw]
    call streq
    test eax, eax
    jnz .rw
    lea rdi, [str_vol_arg_ro]
    call streq
    test eax, eax
    jnz .ro
    jmp .usage
.rw:
    mov byte [r14 + VO_WRITABLE], 1
    KLOG "vol%u is writable. The FAT32 writer is new: keep copies of anything on it that matters.", rbx
    jmp .select
.ro:
    call fat_sync
    mov byte [r14 + VO_WRITABLE], 0
.select:
    mov [vol_current], r14
    mov byte [vol_chosen], 1
    cmp dword [r14 + VO_FS], FS_FAT32
    jne .show
    cmp byte [r14 + VF_MOUNTED], 0
    jne .show
    call fat_mount
.show:
    call vol_describe
    jmp .out
.missing:
    KLOG "there is no vol%u ('disks' lists them)", rax
    jmp .out
.usage:
    KLOG "usage: vol [<n> [rw|ro]]"
.out:
    pop r14
    pop r12
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Arguments
; -----------------------------------------------------------------------------

; arg_split(RSI = text) -> RSI = its first word, ended in place; RDI = the
; rest, leading spaces skipped. Preserves others but RAX.
arg_split:
    mov rdi, rsi
.scan:
    mov al, [rdi]
    test al, al
    jz .out
    cmp al, ' '
    je .cut
    inc rdi
    jmp .scan
.cut:
    mov byte [rdi], 0
    inc rdi
.skip:
    cmp byte [rdi], ' '
    jne .out
    inc rdi
    jmp .skip
.out:
    ret

; arg_uint(RSI = text) -> EAX = its decimal value; CF if it is not one.
; Preserves others.
arg_uint:
    push rcx
    push rsi
    xor eax, eax
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .bad
.digit:
    movzx ecx, byte [rsi]
    sub ecx, '0'
    cmp ecx, 9
    ja .end
    imul eax, eax, 10
    add eax, ecx
    inc rsi
    jmp .digit
.end:
    cmp byte [rsi], 0
    jne .bad
    clc
    jmp .out
.bad:
    stc
.out:
    pop rsi
    pop rcx
    ret

section .rodata
str_vt_whole:   db 'whole disk', 0
str_vt_other:   db 'other', 0
str_vt_mbr:     db 'MBR partition', 0
str_vt_esp:     db 'EFI system', 0
str_vt_msr:     db 'Microsoft reserved', 0
str_vt_basic:   db 'basic data', 0
str_vt_recovery: db 'Windows recovery', 0
str_vt_linux:   db 'Linux filesystem', 0
str_vt_swap:    db 'Linux swap', 0
str_vt_fat32:   db 'FAT32', 0
str_vt_fat16:   db 'FAT16', 0
str_vt_ntfs:    db 'NTFS or exFAT', 0
str_fs_none:    db '-', 0
str_fs_fat32:   db 'FAT32', 0
str_fs_ntfs:    db 'NTFS', 0
str_fs_exfat:   db 'exFAT', 0
str_fs_fat16:   db 'FAT16', 0
str_vol_ro:     db 'read-only', 0
str_vol_rw:     db 'WRITABLE', 0
str_vol_arg_rw: db 'rw', 0
str_vol_arg_ro: db 'ro', 0

align 8
fs_names:       dq str_fs_none, str_fs_fat32, str_fs_ntfs, str_fs_exfat, str_fs_fat16

; GPT partition types as they sit on disk (mixed-endian GUIDs)
gpt_types:
    db 0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B
    dq str_vt_esp
    db 0x16, 0xE3, 0xC9, 0xE3, 0x5C, 0x0B, 0xB8, 0x4D, 0x81, 0x7D, 0xF9, 0x2D, 0xF0, 0x02, 0x15, 0xAE
    dq str_vt_msr
    db 0xA2, 0xA0, 0xD0, 0xEB, 0xE5, 0xB9, 0x33, 0x44, 0x87, 0xC0, 0x68, 0xB6, 0xB7, 0x26, 0x99, 0xC7
    dq str_vt_basic
    db 0xA4, 0xBB, 0x94, 0xDE, 0xD1, 0x06, 0x40, 0x4D, 0xA1, 0x6A, 0xBF, 0xD5, 0x01, 0x79, 0xD6, 0xAC
    dq str_vt_recovery
    db 0xAF, 0x3D, 0xC6, 0x0F, 0x83, 0x84, 0x72, 0x47, 0x8E, 0x79, 0x3D, 0x69, 0xD8, 0x47, 0x7D, 0xE4
    dq str_vt_linux
    db 0x6D, 0xFD, 0x57, 0x06, 0xAB, 0xA4, 0xC4, 0x43, 0x84, 0xE5, 0x09, 0x33, 0xC8, 0x4B, 0x4F, 0x4F
    dq str_vt_swap
    times 16 db 0
    dq 0

mbr_types:                              ; type byte, name
    dq 0x0B, str_vt_fat32
    dq 0x0C, str_vt_fat32
    dq 0x06, str_vt_fat16
    dq 0x0E, str_vt_fat16
    dq 0x07, str_vt_ntfs
    dq 0xEF, str_vt_esp
    dq 0x83, str_vt_linux
    dq 0x82, str_vt_swap
    dq 0, 0

section .bss
alignb 8
disk_count:     resd 1
vol_count:      resd 1
vol_current:    resq 1
vol_chosen:     resb 1                  ; by 'vol <n>', so plugging in a stick keeps it
alignb 8
gpt_lba:        resq 1
gpt_count:      resd 1
gpt_esize:      resd 1
dk_text:        resb 128
alignb 64
disks:          resb MAX_DISK * DK_SIZE
volumes:        resb MAX_VOL * VO_SIZE
alignb 4096
dk_sec:         resb 4096
