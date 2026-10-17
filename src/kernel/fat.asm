; =============================================================================
;  fat.asm - FAT32. Reads long names; writes them too, with an 8.3 alias
;  that no other entry in the directory has. One cached FAT sector (written
;  to every copy of the FAT) and one cached directory sector, both flushed
;  at the end of each operation, after which the drive is told to flush.
;  File data goes straight to its clusters.
;
;  Registers by convention: R14 = volume. Writes need 'vol <n> rw'.
; =============================================================================

VF_MOUNTED      equ VO_FAT + 0          ; byte
VF_SSHIFT       equ VO_FAT + 4          ; log2 of the sector (= block) size
VF_SPC          equ VO_FAT + 8          ; sectors per cluster
VF_CSHIFT       equ VO_FAT + 12         ; log2 of that
VF_CBYTES       equ VO_FAT + 16         ; bytes per cluster
VF_FAT          equ VO_FAT + 20         ; first sector of the first FAT
VF_FATSZ        equ VO_FAT + 24         ; sectors per FAT
VF_NFATS        equ VO_FAT + 28
VF_DATA         equ VO_FAT + 32         ; sector of cluster 2
VF_MAXCL        equ VO_FAT + 36         ; highest cluster number
VF_ROOT         equ VO_FAT + 40
VF_FSINFO       equ VO_FAT + 44         ; its sector, 0 = none
VF_HINT         equ VO_FAT + 48         ; where to look for a free cluster
VF_CWD          equ VO_FAT + 52         ; current directory's cluster
VF_PATH         equ VO_FAT + 64         ; and its path, 256 bytes
VF_SERIAL       equ VO_FAT + 320        ; the volume serial number

FAT_EOC         equ 0x0FFFFFFF
FAT_FILE_MAX    equ 64 * 1024           ; what cat and the shell move at once

section .text

; fat_mount(R14) -> CF if the volume is not FAT32 as Axiom reads it
fat_mount:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov byte [r14 + VF_MOUNTED], 0
    lea rdi, [fat_buf]
    xor esi, esi
    mov edx, 1
    call vol_read
    jc .fail
    lea rbx, [fat_buf]
    mov rsi, [r14 + VO_DISK]
    mov ecx, [rsi + DK_SHIFT]
    mov [r14 + VF_SSHIFT], ecx
    mov eax, 1
    shl eax, cl
    movzx edx, word [rbx + 11]          ; bytes per sector: the disk's block
    cmp edx, eax
    jne .bad
    movzx eax, byte [rbx + 13]          ; sectors per cluster: a power of two
    test eax, eax
    jz .bad
    lea edx, [eax - 1]
    test eax, edx
    jnz .bad
    mov [r14 + VF_SPC], eax
    bsf edx, eax
    mov [r14 + VF_CSHIFT], edx
    add ecx, edx
    cmp ecx, 16                         ; clusters up to 64 KiB
    ja .bad
    mov eax, 1
    shl eax, cl
    mov [r14 + VF_CBYTES], eax
    movzx eax, word [rbx + 14]          ; reserved sectors
    test eax, eax
    jz .bad
    mov [r14 + VF_FAT], eax
    movzx eax, byte [rbx + 16]
    test eax, eax
    jz .bad
    cmp eax, 4
    ja .bad
    mov [r14 + VF_NFATS], eax
    mov eax, [rbx + 67]
    mov [r14 + VF_SERIAL], eax
    cmp word [rbx + 17], 0              ; FAT32: no fixed root directory
    jne .bad
    cmp word [rbx + 22], 0              ; and the 32-bit FAT size
    jne .bad
    mov eax, [rbx + 36]
    test eax, eax
    jz .bad
    mov [r14 + VF_FATSZ], eax
    imul eax, [r14 + VF_NFATS]
    jc .bad
    add eax, [r14 + VF_FAT]
    jc .bad
    mov [r14 + VF_DATA], eax
    movzx edx, word [rbx + 19]          ; total sectors
    test edx, edx
    jnz .total
    mov edx, [rbx + 32]
.total:
    cmp rdx, [r14 + VO_COUNT]
    ja .bad
    sub edx, eax
    jbe .bad
    mov ecx, [r14 + VF_CSHIFT]
    shr edx, cl                         ; data clusters
    test edx, edx
    jz .bad
    inc edx                             ; highest cluster number
    mov eax, [r14 + VF_FATSZ]           ; no more than the FAT has room for
    mov ecx, [r14 + VF_SSHIFT]
    sub ecx, 2
    shl rax, cl
    dec rax
    cmp rdx, rax
    jbe .fits
    mov edx, eax
.fits:
    cmp edx, 0x0FFFFFF6
    jbe .max
    mov edx, 0x0FFFFFF6
.max:
    mov [r14 + VF_MAXCL], edx
    mov eax, [rbx + 44]                 ; root directory
    cmp eax, 2
    jb .bad
    cmp eax, edx
    ja .bad
    mov [r14 + VF_ROOT], eax
    mov [r14 + VF_CWD], eax
    mov dword [r14 + VF_HINT], 2
    mov dword [r14 + VF_FSINFO], 0
    movzx eax, word [rbx + 48]          ; FSInfo: where free clusters start
    test eax, eax
    jz .path
    cmp eax, [r14 + VF_FAT]
    jae .path
    mov esi, eax
    lea rdi, [fat_buf]
    mov edx, 1
    call vol_read
    jc .path
    cmp dword [fat_buf], 0x41615252
    jne .path
    cmp dword [fat_buf + 484], 0x61417272
    jne .path
    mov [r14 + VF_FSINFO], esi
    mov eax, [fat_buf + 492]
    cmp eax, 2
    jb .path
    cmp eax, [r14 + VF_MAXCL]
    ja .path
    mov [r14 + VF_HINT], eax
.path:
    mov word [r14 + VF_PATH], '/'
    mov byte [r14 + VF_MOUNTED], 1
    clc
    jmp .out
.bad:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u: a FAT32 layout Axiom does not follow", rax
.fail:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The FAT
; -----------------------------------------------------------------------------

; fat_cache(R14, EAX = sector within the FAT) -> CF. Preserves all but RAX.
fat_cache:
    cmp [fc_vol], r14
    jne .load
    cmp [fc_sec], eax
    jne .load
    clc
    ret
.load:
    push rsi
    push rdx
    push rdi
    mov esi, eax
    call fat_flush_cache
    jc .out
    mov [fc_sec], esi
    add esi, [r14 + VF_FAT]
    lea rdi, [fc_buf]
    mov edx, 1
    call vol_read
    jc .bad
    mov [fc_vol], r14
    jmp .out
.bad:
    mov qword [fc_vol], 0
    mov byte [fat_ioerr], 1
    stc
.out:
    pop rdi
    pop rdx
    pop rsi
    ret

; fat_flush_cache -> CF: the cached FAT sector, into every copy of the FAT.
; Preserves all but RAX.
fat_flush_cache:
    cmp byte [fc_dirty], 0
    jne .write
    clc
    ret
.write:
    push rcx
    push rdx
    push rsi
    push rdi
    push r14
    mov byte [fc_dirty], 0
    mov r14, [fc_vol]
    mov esi, [fc_sec]
    add esi, [r14 + VF_FAT]
    mov ecx, [r14 + VF_NFATS]
    lea rdi, [fc_buf]
    mov edx, 1
.copy:
    call vol_write
    jc .bad
    add esi, [r14 + VF_FATSZ]
    dec ecx
    jnz .copy
    clc
    jmp .out
.bad:
    mov qword [fc_vol], 0
    mov byte [fat_ioerr], 1
    stc
.out:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; fat_get(R14, EAX = cluster) -> EAX = its entry; CF on a disk error.
; Preserves others.
fat_get:
    push rcx
    push rdx
    mov edx, eax
    shl edx, 2
    mov ecx, [r14 + VF_SSHIFT]
    mov eax, edx
    shr eax, cl
    call fat_cache
    jc .out
    mov eax, 1
    shl eax, cl
    dec eax
    and edx, eax
    lea rax, [fc_buf]
    mov eax, [rax + rdx]
    and eax, 0x0FFFFFFF
    clc
.out:
    pop rdx
    pop rcx
    ret

; fat_set(R14, EAX = cluster, EDX = value) -> CF. Preserves all but RAX.
fat_set:
    push rcx
    push rdx
    push rsi
    mov esi, edx
    mov edx, eax
    shl edx, 2
    mov ecx, [r14 + VF_SSHIFT]
    mov eax, edx
    shr eax, cl
    call fat_cache
    jc .out
    mov eax, 1
    shl eax, cl
    dec eax
    and edx, eax
    lea rcx, [fc_buf]
    add rcx, rdx
    mov eax, [rcx]
    and eax, 0xF0000000                 ; the top four bits are not ours
    and esi, 0x0FFFFFFF
    or eax, esi
    mov [rcx], eax
    mov byte [fc_dirty], 1
    mov byte [fat_dirtied], 1
    clc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; clus_ok(R14, EAX = cluster) -> CF if it is not a data cluster. Preserves all.
clus_ok:
    cmp eax, 2
    jb .bad
    cmp eax, [r14 + VF_MAXCL]
    ja .bad
    clc
    ret
.bad:
    stc
    ret

; clus_block(R14, EAX = cluster) -> RAX = its first block in the volume.
; Preserves others.
clus_block:
    push rcx
    sub eax, 2
    mov ecx, [r14 + VF_CSHIFT]
    shl rax, cl
    mov ecx, [r14 + VF_DATA]
    add rax, rcx
    pop rcx
    ret

; fat_alloc(R14, EDX = cluster to chain it after, 0 = none) -> EAX = a free
; cluster, now the end of its chain; CF if the volume is full.
; Preserves others.
fat_alloc:
    push rcx
    push rsi
    mov esi, [r14 + VF_HINT]
    mov ecx, [r14 + VF_MAXCL]
    dec ecx
.scan:
    cmp esi, 2
    jb .wrap
    cmp esi, [r14 + VF_MAXCL]
    jbe .look
.wrap:
    mov esi, 2
.look:
    mov eax, esi
    call fat_get
    jc .fail
    test eax, eax
    jz .found
    inc esi
    dec ecx
    jnz .scan
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u is full", rax
    jmp .fail
.found:
    push rdx
    mov eax, esi
    mov edx, FAT_EOC
    call fat_set
    pop rdx
    jc .fail
    test edx, edx
    jz .linked
    push rdx
    mov eax, edx
    mov edx, esi
    call fat_set
    pop rdx
    jc .fail
.linked:
    lea eax, [esi + 1]
    mov [r14 + VF_HINT], eax
    mov eax, esi
    clc
    jmp .out
.fail:
    stc
.out:
    pop rsi
    pop rcx
    ret

; fat_free_chain(R14, EAX = first cluster) -> CF. Preserves all but RAX.
fat_free_chain:
    push rcx
    push rdx
    push rsi
    mov qword [de_vol], 0               ; chains are changing
    mov ecx, [r14 + VF_MAXCL]           ; no chain is longer than the volume
.next:
    call clus_ok
    jc .done
    mov esi, eax
    call fat_get
    jc .out
    xchg eax, esi
    xor edx, edx
    call fat_set
    jc .out
    mov eax, esi
    dec ecx
    jnz .next
.done:
    clc
.out:
    pop rsi
    pop rdx
    pop rcx
    ret

; clus_zero(R14, EAX = cluster) -> CF: zeros on disk. Preserves all but RAX.
clus_zero:
    push rcx
    push rdx
    push rsi
    push rdi
    push rax
    call sec_drop
    lea rdi, [fat_buf]
    mov ecx, [r14 + VF_CBYTES]
    shr ecx, 3
    xor eax, eax
    rep stosq
    pop rax
    call clus_block
    mov rsi, rax
    mov edx, [r14 + VF_SPC]
    lea rdi, [fat_buf]
    call vol_write
    mov byte [fat_dirtied], 1
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; clus_write(R14, EAX = cluster, R10 = data, R9 = bytes left) -> CF: one
; cluster's worth (the last one padded with zeros); R10 and R9 move on.
; Preserves others but RAX.
clus_write:
    push rcx
    push rdx
    push rsi
    push rdi
    call clus_block
    mov rsi, rax
    mov ecx, [r14 + VF_CBYTES]
    mov edx, [r14 + VF_SPC]
    cmp r9, rcx
    jb .partial
    mov rdi, r10
    call vol_write
    jc .out
    add r10, rcx
    sub r9, rcx
    jmp .done
.partial:
    push rcx
    push rsi
    lea rdi, [fat_buf]
    mov rsi, r10
    mov rcx, r9
    rep movsb
    pop rsi
    pop rcx
    sub rcx, r9
    xor eax, eax
    rep stosb
    lea rdi, [fat_buf]
    call vol_write
    jc .out
    add r10, r9
    xor r9d, r9d
.done:
    mov byte [fat_dirtied], 1
    clc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  The directory sector cache
; -----------------------------------------------------------------------------

; sec_get(R14, RAX = block in the volume) -> RAX = sc_buf, holding it; CF on a
; disk error. Preserves others.
sec_get:
    cmp [sc_vol], r14
    jne .load
    cmp [sc_sec], rax
    jne .load
    lea rax, [sc_buf]
    clc
    ret
.load:
    push rsi
    push rdx
    push rdi
    mov rsi, rax
    call sec_flush
    jc .out
    lea rdi, [sc_buf]
    mov edx, 1
    call vol_read
    jc .bad
    mov [sc_vol], r14
    mov [sc_sec], rsi
    lea rax, [sc_buf]
    jmp .out
.bad:
    mov qword [sc_vol], 0
    mov byte [fat_ioerr], 1
    stc
.out:
    pop rdi
    pop rdx
    pop rsi
    ret

; sec_mark: the cached sector changed. Preserves all.
sec_mark:
    mov byte [sc_dirty], 1
    mov byte [fat_dirtied], 1
    ret

; sec_flush -> CF: write the cached sector back if it changed.
; Preserves all but RAX.
sec_flush:
    cmp byte [sc_dirty], 0
    jne .write
    clc
    ret
.write:
    push rsi
    push rdx
    push rdi
    push r14
    mov byte [sc_dirty], 0
    mov r14, [sc_vol]
    mov rsi, [sc_sec]
    lea rdi, [sc_buf]
    mov edx, 1
    call vol_write
    jnc .out
    mov qword [sc_vol], 0
    mov byte [fat_ioerr], 1
    stc
.out:
    pop r14
    pop rdi
    pop rdx
    pop rsi
    ret

; sec_drop -> CF: flush it and forget it, before clusters are written
; directly. Preserves all but RAX.
sec_drop:
    call sec_flush
    mov qword [sc_vol], 0
    ret

; fat_sync(R14) -> CF if a disk error happened since fat_vol: caches out,
; FSInfo updated, the drive told to flush. Preserves all but RAX.
fat_sync:
    push rbx
    push rsi
    call sec_flush
    call fat_flush_cache
    cmp byte [fat_dirtied], 0
    je .out
    mov byte [fat_dirtied], 0
    mov eax, [r14 + VF_FSINFO]
    test eax, eax
    jz .flush
    call sec_get
    jc .flush
    cmp dword [rax], 0x41615252
    jne .flush
    mov dword [rax + 488], -1           ; free count: not kept
    mov esi, [r14 + VF_HINT]
    mov [rax + 492], esi
    call sec_mark
    call sec_flush
    mov byte [fat_dirtied], 0
.flush:
    mov rbx, [r14 + VO_DISK]
    call disk_flush
    jnc .out
    mov byte [fat_ioerr], 1
.out:
    cmp byte [fat_ioerr], 1             ; CF = an error happened
    cmc
    pop rsi
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Directories
; -----------------------------------------------------------------------------

; dir_entry(R14, EDI = directory's first cluster, ESI = entry index)
; -> RAX = the 32-byte entry, inside sc_buf; CF past the end of the chain
; (or on a disk error, which sets fat_ioerr). Preserves others.
dir_entry:
    push rcx
    push rdx
    push r8
    push r9
    mov ecx, [r14 + VF_SSHIFT]
    sub ecx, 5
    add ecx, [r14 + VF_CSHIFT]          ; log2 of entries per cluster
    mov r8d, esi
    shr r8d, cl                         ; which cluster of the chain
    mov eax, edi
    xor r9d, r9d
    cmp [de_vol], r14                   ; start from where the last call was
    jne .walk
    cmp [de_dir], edi
    jne .walk
    cmp [de_idx], r8d
    ja .walk
    mov eax, [de_clus]
    mov r9d, [de_idx]
.walk:
    call clus_ok
    jc .end
    cmp r9d, r8d
    je .there
    call fat_get
    jc .end
    inc r9d
    jmp .walk
.there:
    mov [de_vol], r14
    mov [de_dir], edi
    mov [de_idx], r8d
    mov [de_clus], eax
    call clus_block
    mov ecx, [r14 + VF_SSHIFT]
    sub ecx, 5                          ; log2 of entries per sector
    mov edx, esi
    shr edx, cl
    mov r9d, [r14 + VF_SPC]
    dec r9d
    and edx, r9d                        ; sector within the cluster
    add rax, rdx
    call sec_get
    jc .end
    mov edx, 1
    shl edx, cl
    dec edx
    and edx, esi
    shl edx, 5
    add rax, rdx
    clc
    jmp .out
.end:
    stc
.out:
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; dir_open(R14, EDI = directory cluster). Preserves all.
dir_open:
    mov [it_dir], edi
    mov dword [it_idx], 0
    mov dword [lfn_state], 0
    ret

; dir_next(R14) -> the next file or directory: fat_ent (its entry), fat_name
; (the long name, else the short one), fat_short (8.3), ent_idx, ent_first
; (its first long-name entry); CF at the end. Preserves all but RAX.
dir_next:
    push rcx
    push rdx
    push rsi
    push rdi
.next:
    mov edi, [it_dir]
    mov esi, [it_idx]
    call dir_entry
    jc .end
    inc dword [it_idx]
    movzx ecx, byte [rax]
    test ecx, ecx
    jz .end_mark
    cmp ecx, 0xE5                       ; deleted
    je .forget
    movzx edx, byte [rax + 11]
    and edx, 0x3F
    cmp edx, 0x0F
    je .lfn
    test edx, 0x08                      ; the volume label
    jnz .forget
    mov [ent_idx], esi
    mov rsi, rax
    lea rdi, [fat_ent]
    mov ecx, 4
    rep movsq
    lea rsi, [fat_ent]
    lea rdi, [fat_short]
    call fat_format_short
    cmp dword [lfn_state], 1            ; a whole long name, for this entry?
    jne .short
    call fat_checksum
    cmp al, [lfn_sum]
    jne .short
    mov eax, [lfn_first]
    mov [ent_first], eax
    jmp .found
.short:
    mov eax, [ent_idx]
    mov [ent_first], eax
    lea rsi, [fat_short]
    lea rdi, [fat_name]
    mov ecx, 2
    rep movsq
.found:
    mov dword [lfn_state], 0
    clc
    jmp .out
.lfn:
    mov edx, ecx
    and edx, 0x1F                       ; piece number
    jz .forget
    test ecx, 0x40
    jz .middle
    mov [lfn_first], esi                ; the last piece comes first
    movzx ecx, byte [rax + 13]
    mov [lfn_sum], ecx
    push rax
    lea rdi, [fat_name]
    mov ecx, 256 / 8
    xor eax, eax
    rep stosq
    pop rax
    jmp .piece
.middle:
    mov ecx, [lfn_state]
    dec ecx
    cmp ecx, edx
    jne .forget
    movzx ecx, byte [rax + 13]
    cmp ecx, [lfn_sum]
    jne .forget
.piece:
    mov [lfn_state], edx
    lea ecx, [edx - 1]
    imul ecx, ecx, 13                   ; where its characters go
    xor edx, edx
.char:
    movzx edi, byte [lfn_offsets + rdx]
    movzx edi, word [rax + rdi]
    test edi, edi
    jz .next
    cmp edi, 0xFFFF
    je .next
    cmp edi, 0x7F
    jb .ascii
    mov edi, '?'
.ascii:
    cmp ecx, 255
    jae .next
    mov [fat_name + rcx], dil
    inc ecx
    inc edx
    cmp edx, 13
    jb .char
    jmp .next
.forget:
    mov dword [lfn_state], 0
    jmp .next
.end_mark:
    dec dword [it_idx]                  ; stay at the end
.end:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; fat_format_short(RSI = 32-byte entry, RDI = out): "NAME.EXT", lowercased
; where the entry says so. Preserves all.
fat_format_short:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    movzx r8d, byte [rsi + 12]
    mov ecx, 8
.trim_base:
    cmp byte [rsi + rcx - 1], ' '
    jne .base
    dec ecx
    jnz .trim_base
.base:
    xor edx, edx
.base_char:
    cmp edx, ecx
    jae .ext
    mov al, [rsi + rdx]
    test edx, edx
    jnz .not_first
    cmp al, 0x05                        ; stands for 0xE5
    jne .not_first
    mov al, 0xE5
.not_first:
    mov r9d, r8d
    and r9d, 0x08
    call fs_char
    stosb
    inc edx
    jmp .base_char
.ext:
    mov ecx, 3
.trim_ext:
    cmp byte [rsi + rcx + 7], ' '
    jne .dot
    dec ecx
    jnz .trim_ext
    jmp .end
.dot:
    mov al, '.'
    stosb
    xor edx, edx
.ext_char:
    mov al, [rsi + rdx + 8]
    mov r9d, r8d
    and r9d, 0x10
    call fs_char
    stosb
    inc edx
    cmp edx, ecx
    jb .ext_char
.end:
    mov byte [rdi], 0
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; fs_char(AL = 8.3 character, R9D = nonzero to lowercase) -> AL printable
fs_char:
    cmp al, 0x80
    jb .ascii
    mov al, '?'
    ret
.ascii:
    test r9d, r9d
    jz .out
    cmp al, 'A'
    jb .out
    cmp al, 'Z'
    ja .out
    or al, 0x20
.out:
    ret

; fat_checksum(RSI = 11-byte short name) -> AL, as long-name entries carry it.
; Preserves others.
fat_checksum:
    push rcx
    xor eax, eax
    xor ecx, ecx
.next:
    ror al, 1
    add al, [rsi + rcx]
    inc ecx
    cmp ecx, 11
    jb .next
    pop rcx
    ret

; name_eq(RSI, RDI) -> EAX = 1 if they match, ignoring ASCII case.
; Preserves others.
name_eq:
    push rcx
    push rdx
    push rsi
    push rdi
.next:
    movzx eax, byte [rsi]
    movzx ecx, byte [rdi]
    lea edx, [eax - 'A']
    cmp edx, 25
    ja .a
    or eax, 0x20
.a:
    lea edx, [ecx - 'A']
    cmp edx, 25
    ja .b
    or ecx, 0x20
.b:
    cmp eax, ecx
    jne .no
    test eax, eax
    jz .yes
    inc rsi
    inc rdi
    jmp .next
.yes:
    mov eax, 1
    jmp .out
.no:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; ent_cluster -> EAX = fat_ent's first cluster (a directory at 0 is the root).
; Preserves others.
ent_cluster:
    movzx eax, word [fat_ent + 20]
    shl eax, 16
    mov ax, [fat_ent + 26]
    test eax, eax
    jnz .out
    test byte [fat_ent + 11], 0x10
    jz .out
    mov eax, [r14 + VF_ROOT]
.out:
    ret

; fat_lookup(R14, EDI = directory, RSI = name) -> EAX = its first cluster,
; fat_ent and the rest describe it; CF if it is not there. Preserves others.
fat_lookup:
    push rbx
    push rdi
    mov rbx, rsi
    call dir_open
.next:
    call dir_next
    jc .out
    mov rsi, rbx
    lea rdi, [fat_name]
    call name_eq
    test eax, eax
    jnz .found
    lea rdi, [fat_short]
    call name_eq
    test eax, eax
    jz .next
.found:
    call ent_cluster
    clc
.out:
    mov rsi, rbx
    pop rdi
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Paths: '/' separates, a leading '/' starts at the root, '.' and '..' work
; -----------------------------------------------------------------------------

; comp_here(R14, EDI = directory) -> CF if fat_comp names that directory
; itself: "", ".", or ".." at the root. Preserves all.
comp_here:
    cmp byte [fat_comp], 0
    je .yes
    cmp word [fat_comp], '.'
    je .yes
    cmp word [fat_comp], '..'
    jne .no
    cmp byte [fat_comp + 2], 0
    jne .no
    cmp edi, [r14 + VF_ROOT]
    je .yes
.no:
    clc
    ret
.yes:
    stc
    ret

; fat_enter(R14, EDI = directory) -> EDI = the directory fat_comp names in
; it; CF (said so) if there is none. Preserves others but RAX.
fat_enter:
    push rsi
    call comp_here
    jc .stay
    lea rsi, [fat_comp]
    call fat_lookup
    jc .missing
    test byte [fat_ent + 11], 0x10
    jz .not_dir
    mov edi, eax
.stay:
    clc
    jmp .out
.missing:
    cmp byte [fat_hush], 0
    jne .missing_hushed
    lea rax, [fat_comp]
    KLOG "no directory '%s'", rax
.missing_hushed:
    stc
    jmp .out
.not_dir:
    cmp byte [fat_hush], 0
    jne .not_dir_hushed
    lea rax, [fat_comp]
    KLOG "'%s' is not a directory", rax
.not_dir_hushed:
    stc
.out:
    pop rsi
    ret

; fat_parent(R14, RSI = path) -> EDI = the directory holding its last part,
; fat_comp = that part ("" when the path ends at a directory); CF (said so)
; if a directory on the way is missing. Preserves others but RAX.
fat_parent:
    push rcx
    push rsi
    mov edi, [r14 + VF_CWD]
    cmp byte [rsi], '/'
    jne .copy
    mov edi, [r14 + VF_ROOT]
.lead:
    cmp byte [rsi], '/'
    jne .copy
    inc rsi
    jmp .lead
.copy:
    xor ecx, ecx
.char:
    mov al, [rsi]
    test al, al
    jz .ended
    cmp al, '/'
    je .ended
    cmp ecx, 255
    jae .long
    mov [fat_comp + rcx], al
    inc ecx
    inc rsi
    jmp .char
.ended:
    mov byte [fat_comp + rcx], 0
.slashes:
    cmp byte [rsi], '/'
    jne .last
    inc rsi
    jmp .slashes
.last:
    cmp byte [rsi], 0
    je .done
    call fat_enter                      ; a directory on the way
    jc .out
    jmp .copy
.done:
    clc
    jmp .out
.long:
    cmp byte [fat_hush], 0
    jne .long_hushed
    KLOG "a name in that path is too long"
.long_hushed:
    stc
.out:
    pop rsi
    pop rcx
    ret

; fat_resolve(R14, RSI = path) -> EAX = its first cluster, fat_ent describes
; it (made up for the root); CF (said so) if it is not there.
; Preserves others.
fat_resolve:
    push rcx
    push rdi
    push rsi
    call fat_parent
    jc .out
    call comp_here
    jc .itself
    lea rsi, [fat_comp]
    call fat_lookup
    jnc .out
    cmp byte [fat_ioerr], 0
    jne .io
    cmp byte [fat_hush], 0
    jne .hushed
    lea rax, [fat_comp]
    KLOG "nothing called '%s' there", rax
.hushed:
    stc
    jmp .out
.io:
    call fat_io_failed
    stc
    jmp .out
.itself:
    push rdi
    lea rdi, [fat_ent]
    xor eax, eax
    mov ecx, 4
    rep stosq
    pop rdi
    mov byte [fat_ent + 11], 0x10
    mov eax, edi
    mov [fat_ent + 26], ax
    shr eax, 16
    mov [fat_ent + 20], ax
    mov word [fat_name], '/'
    mov eax, edi
    clc
.out:
    pop rsi
    pop rdi
    pop rcx
    ret

; path_join(R14, RSI = path) -> fat_path = where it leads from the current
; directory, written out from the root, '.' and '..' gone; CF if too long.
; Preserves others but RAX.
path_join:
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [fat_path]
    xor ecx, ecx
    cmp byte [rsi], '/'
    je .parts
    push rsi
    lea rsi, [r14 + VF_PATH]
.current:
    mov al, [rsi + rcx]
    test al, al
    jz .have
    mov [rdi + rcx], al
    inc ecx
    jmp .current
.have:
    pop rsi
    cmp ecx, 1                          ; "/" alone: nothing yet
    jne .parts
    xor ecx, ecx
.parts:
    cmp byte [rsi], '/'
    jne .part
    inc rsi
    jmp .parts
.part:
    cmp byte [rsi], 0
    je .end
    xor edx, edx
.measure:
    mov al, [rsi + rdx]
    test al, al
    jz .measured
    cmp al, '/'
    je .measured
    inc edx
    jmp .measure
.measured:
    cmp edx, 1
    jne .not_dot
    cmp byte [rsi], '.'
    je .skip
.not_dot:
    cmp edx, 2
    jne .append
    cmp word [rsi], '..'
    jne .append
.up:
    test ecx, ecx
    jz .skip
    dec ecx
    cmp byte [rdi + rcx], '/'
    jne .up
    jmp .skip
.append:
    lea eax, [ecx + edx + 1]
    cmp eax, 250
    ja .long
    mov byte [rdi + rcx], '/'
    inc ecx
.copy:
    mov al, [rsi]
    mov [rdi + rcx], al
    inc rsi
    inc ecx
    dec edx
    jnz .copy
    jmp .parts
.skip:
    add rsi, rdx
    jmp .parts
.end:
    test ecx, ecx
    jnz .term
    mov byte [rdi], '/'
    inc ecx
.term:
    mov byte [rdi + rcx], 0
    clc
    jmp .out
.long:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  New entries
; -----------------------------------------------------------------------------

; fat_name_ok(R12 = name) -> CF (said so) if FAT32 cannot hold it.
; Preserves all.
fat_name_ok:
    push rax
    push rcx
    push rdi
    xor ecx, ecx
.char:
    movzx eax, byte [r12 + rcx]
    test eax, eax
    jz .end
    cmp eax, ' '
    jb .bad
    cmp eax, 0x7F
    jae .bad
    lea rdi, [fat_bad_chars]
.look:
    cmp byte [rdi], 0
    je .fine
    cmp [rdi], al
    je .bad
    inc rdi
    jmp .look
.fine:
    inc ecx
    cmp ecx, 255
    ja .bad
    jmp .char
.end:
    test ecx, ecx
    jz .bad
    mov al, [r12 + rcx - 1]             ; no trailing dot or space ("." and ".." too)
    cmp al, '.'
    je .bad
    cmp al, ' '
    je .bad
    clc
    jmp .out
.bad:
    KLOG "'%s' is not a name FAT32 can hold", r12
    stc
.out:
    pop rdi
    pop rcx
    pop rax
    ret

; case_note(AL): R10D |= 1 for an uppercase letter, 2 for a lowercase one.
; Preserves all.
case_note:
    cmp al, 'A'
    jb .out
    cmp al, 'Z'
    jbe .upper
    cmp al, 'a'
    jb .out
    cmp al, 'z'
    ja .out
    or r10d, 2
    ret
.upper:
    or r10d, 1
.out:
    ret

; short_char(AL) -> AL in uppercase; CF if an 8.3 name cannot hold it.
; Preserves others.
short_char:
    cmp al, 'a'
    jb .not_lower
    cmp al, 'z'
    ja .not_lower
    and al, 0xDF
    clc
    ret
.not_lower:
    cmp al, 'A'
    jb .digit
    cmp al, 'Z'
    jbe .ok
.digit:
    cmp al, '0'
    jb .special
    cmp al, '9'
    jbe .ok
.special:
    push rcx
    lea rcx, [fat_short_specials]
.look:
    cmp byte [rcx], 0
    je .bad
    cmp [rcx], al
    je .found
    inc rcx
    jmp .look
.found:
    pop rcx
.ok:
    clc
    ret
.bad:
    pop rcx
    stc
    ret

; fat_make_short(RSI = name) -> fat_sname (11 bytes) and fat_scase; EAX = 0
; if the name is an 8.3 name as it stands, 1 if it needs long-name entries
; (fat_sname is then the basis, still without its ~n). Preserves others.
fat_make_short:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    mov rax, '        '
    mov [fat_sname], rax
    mov word [fat_sname + 8], '  '
    mov byte [fat_sname + 10], ' '
    mov byte [fat_scase], 0
    xor ecx, ecx                        ; length
    mov r8d, -1                         ; the last dot
    xor r9d, r9d                        ; dots
.measure:
    mov al, [rsi + rcx]
    test al, al
    jz .measured
    cmp al, '.'
    jne .measure_next
    mov r8d, ecx
    inc r9d
.measure_next:
    inc ecx
    jmp .measure
.measured:
    cmp r9d, 1
    ja .long
    test r8d, r8d
    jz .long                            ; ".name"
    mov edx, ecx                        ; end of the base
    cmp r8d, -1
    je .base_size
    mov edx, r8d
.base_size:
    test edx, edx
    jz .long
    cmp edx, 8
    ja .long
    cmp r8d, -1
    je .fit_base
    mov eax, ecx
    sub eax, r8d
    dec eax                             ; extension length
    jz .long
    cmp eax, 3
    ja .long
.fit_base:
    xor ebx, ebx
    xor r10d, r10d
.fb:
    cmp ebx, edx
    jae .fb_done
    mov al, [rsi + rbx]
    call case_note
    call short_char
    jc .long
    mov [fat_sname + rbx], al
    inc ebx
    jmp .fb
.fb_done:
    cmp r10d, 3                         ; mixed case needs the long name
    je .long
    cmp r10d, 2
    jne .fit_ext
    or byte [fat_scase], 0x08
.fit_ext:
    cmp r8d, -1
    je .fits
    xor r10d, r10d
    lea ebx, [r8d + 1]
    xor edi, edi
.fe:
    cmp ebx, ecx
    jae .fe_done
    mov al, [rsi + rbx]
    call case_note
    call short_char
    jc .long
    mov [fat_sname + 8 + rdi], al
    inc ebx
    inc edi
    jmp .fe
.fe_done:
    cmp r10d, 3
    je .long
    cmp r10d, 2
    jne .fits
    or byte [fat_scase], 0x10
.fits:
    xor eax, eax
    jmp .out
.long:
    mov rax, '        '
    mov [fat_sname], rax
    mov word [fat_sname + 8], '  '
    mov byte [fat_sname + 10], ' '
    mov byte [fat_scase], 0
    mov edx, ecx                        ; the base ends at the last dot
    cmp r8d, 0
    jle .basis
    mov edx, r8d
.basis:
    xor ebx, ebx
    xor edi, edi
.lb:
    cmp ebx, edx
    jae .lb_done
    cmp edi, 8
    jae .lb_done
    mov al, [rsi + rbx]
    inc ebx
    cmp al, ' '
    je .lb
    cmp al, '.'
    je .lb
    call short_char
    jnc .lb_put
    mov al, '_'
.lb_put:
    mov [fat_sname + rdi], al
    inc edi
    jmp .lb
.lb_done:
    test edi, edi
    jnz .le
    mov byte [fat_sname], '_'
.le:
    cmp r8d, 0
    jle .made
    lea ebx, [r8d + 1]
    xor edi, edi
.le_char:
    cmp ebx, ecx
    jae .made
    cmp edi, 3
    jae .made
    mov al, [rsi + rbx]
    inc ebx
    cmp al, ' '
    je .le_char
    call short_char
    jnc .le_put
    mov al, '_'
.le_put:
    mov [fat_sname + 8 + rdi], al
    inc edi
    jmp .le_char
.made:
    mov eax, 1
.out:
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; dir_has_short(R14, EDI = directory) -> CF if an entry there already has
; fat_sname. Preserves others.
dir_has_short:
    push rcx
    push rsi
    xor esi, esi
.next:
    call dir_entry
    jc .no
    cmp byte [rax], 0
    je .no
    cmp byte [rax], 0xE5
    je .skip
    mov cl, [rax + 11]
    and cl, 0x3F
    cmp cl, 0x0F
    je .skip
    mov rcx, [rax]
    cmp rcx, [fat_sname]
    jne .skip
    mov ecx, [rax + 7]
    cmp ecx, [fat_sname + 7]
    je .yes
.skip:
    inc esi
    jmp .next
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop rsi
    pop rcx
    ret

; fat_unique(R14, EDI = directory): fat_sname becomes basis~n with the
; smallest n nothing there has. CF if there is none. Preserves others.
fat_unique:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    mov rax, [fat_sname]
    mov [fat_basis], rax
    mov ebx, 1
.try:
    mov eax, ebx                        ; "~n", built backwards
    lea rsi, [fat_tail + 7]
    mov ecx, 10
.digit:
    xor edx, edx
    div ecx
    add dl, '0'
    mov [rsi], dl
    dec rsi
    test eax, eax
    jnz .digit
    mov byte [rsi], '~'
    lea rcx, [fat_tail + 8]
    sub rcx, rsi                        ; its length
    mov edx, 8                          ; the basis, without its spaces
.basis_size:
    cmp byte [fat_basis + rdx - 1], ' '
    jne .sized
    dec edx
    jnz .basis_size
.sized:
    mov eax, 8
    sub eax, ecx
    cmp edx, eax
    jbe .keep
    mov edx, eax
.keep:
    mov rax, '        '
    mov [fat_sname], rax
    xor eax, eax
.copy_basis:
    cmp eax, edx
    jae .copy_tail
    mov r8b, [fat_basis + rax]
    mov [fat_sname + rax], r8b
    inc eax
    jmp .copy_basis
.copy_tail:
    mov r8b, [rsi]
    mov [fat_sname + rax], r8b
    inc rsi
    inc eax
    dec ecx
    jnz .copy_tail
    call dir_has_short
    jnc .out
    inc ebx
    cmp ebx, 999999
    jbe .try
    stc
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; lfn_fill(RAX = entry, ECX = piece number, R8D = pieces, R12 = name,
; fat_sum): one long-name entry. Preserves all.
lfn_fill:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rdi, rax
    mov ebx, ecx
    mov eax, ecx
    cmp ecx, r8d
    jne .order
    or eax, 0x40                        ; the last piece
.order:
    mov [rdi], al
    mov byte [rdi + 11], 0x0F
    mov byte [rdi + 12], 0
    mov al, [fat_sum]
    mov [rdi + 13], al
    mov word [rdi + 26], 0
    lea ecx, [ebx - 1]
    imul ecx, ecx, 13                   ; where in the name it starts
    xor edx, edx
    xor esi, esi                        ; 1 once past the end of the name
.char:
    movzx ebx, byte [lfn_offsets + rdx]
    test esi, esi
    jnz .pad
    movzx eax, byte [r12 + rcx]
    test eax, eax
    jnz .put
    mov esi, 1                          ; a NUL, then 0xFFFF
    jmp .put
.pad:
    mov eax, 0xFFFF
.put:
    mov [rdi + rbx], ax
    inc ecx
    inc edx
    cmp edx, 13
    jb .char
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; dir_grow(R14, EDI = directory) -> CF: one more zeroed cluster on its chain.
; Preserves all but RAX.
dir_grow:
    push rcx
    push rdx
    mov eax, edi
    mov ecx, [r14 + VF_MAXCL]
.walk:
    mov edx, eax
    call fat_get
    jc .out
    call clus_ok
    jc .last
    dec ecx
    jnz .walk
    stc
    jmp .out
.last:
    call fat_alloc                      ; after EDX
    jc .out
    call clus_zero
.out:
    pop rdx
    pop rcx
    ret

; fat_create(R14, EDI = directory, RSI = name, DL = attributes) -> ESI = the
; index of its new entry (cluster 0, size 0); CF (said why) on failure.
; Preserves others but RAX.
fat_create:
    push rbx
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r12
    push r13
    mov r12, rsi
    movzx r13d, dl
    call fat_name_ok
    jc .out
    call fat_make_short
    xor r8d, r8d                        ; long-name entries
    test eax, eax
    jz .counted
    call fat_unique
    jc .no_alias
    xor ecx, ecx
.measure:
    cmp byte [r12 + rcx], 0
    je .measured
    inc ecx
    jmp .measure
.measured:
    lea eax, [ecx + 12]
    xor edx, edx
    mov ecx, 13
    div ecx
    mov r8d, eax
.counted:
    lea r9d, [r8d + 1]                  ; entries in a row it needs
    xor esi, esi
    xor ebx, ebx                        ; free ones in a row so far
.scan:
    call dir_entry
    jc .grow
    mov cl, [rax]
    test cl, cl
    jz .free
    cmp cl, 0xE5
    je .free
    xor ebx, ebx
    jmp .scan_next
.free:
    inc ebx
    cmp ebx, r9d
    je .room
.scan_next:
    inc esi
    cmp esi, 65536                      ; the most a FAT directory holds
    jb .scan
    KLOG "that directory is full"
    jmp .fail
.grow:
    cmp byte [fat_ioerr], 0
    jne .io
    call dir_grow
    jc .fail
    jmp .scan                           ; the same index, which now exists
.room:
    sub esi, ebx
    inc esi                             ; the first of the run
    push rsi
    lea rsi, [fat_sname]
    call fat_checksum
    pop rsi
    mov [fat_sum], al
    mov ecx, r8d
.piece:
    test ecx, ecx
    jz .short
    call dir_entry
    jc .io
    call lfn_fill
    call sec_mark
    inc esi
    dec ecx
    jmp .piece
.short:
    call dir_entry
    jc .io
    push rdi
    mov rdi, rax
    xor eax, eax
    mov ecx, 4
    rep stosq
    sub rdi, 32
    mov rax, [fat_sname]
    mov [rdi], rax
    mov eax, [fat_sname + 7]
    mov [rdi + 7], eax
    mov [rdi + 11], r13b
    mov al, [fat_scase]
    mov [rdi + 12], al
    call rtc_fat_time
    mov [rdi + 14], ax                  ; created
    mov [rdi + 22], ax                  ; written
    shr eax, 16
    mov [rdi + 16], ax
    mov [rdi + 18], ax                  ; accessed
    mov [rdi + 24], ax
    pop rdi
    call sec_mark
    clc
    jmp .out
.no_alias:
    KLOG "no free short name for '%s'", r12
    jmp .fail
.io:
    call fat_io_failed
.fail:
    stc
.out:
    pop r13
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

; dot_entry(RAX = entry, EDX = cluster, ECX = 1 or 2): "." or "..". Preserves all.
dot_entry:
    push rax
    push rdx
    push rdi
    mov rdi, rax
    mov rax, '        '
    mov [rdi], rax
    mov dword [rdi + 7], '    '
    mov byte [rdi], '.'
    cmp ecx, 2
    jne .attributes
    mov byte [rdi + 1], '.'
.attributes:
    mov byte [rdi + 11], 0x10
    mov byte [rdi + 12], 0
    mov [rdi + 26], dx
    shr edx, 16
    mov [rdi + 20], dx
    mov dword [rdi + 28], 0
    call rtc_fat_time
    mov [rdi + 14], ax
    mov [rdi + 22], ax
    shr eax, 16
    mov [rdi + 16], ax
    mov [rdi + 18], ax
    mov [rdi + 24], ax
    pop rdi
    pop rdx
    pop rax
    ret

; fat_io_failed: say so. Preserves all.
fat_io_failed:
    push rax
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u: a disk error stopped this part way", rax
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Files: what the shell (and later the rest of Axiom) calls
; -----------------------------------------------------------------------------

; fat_forget(R14): drop anything cached from this volume (its disk is gone).
; Preserves all.
fat_forget:
    cmp [fc_vol], r14
    jne .sector
    mov qword [fc_vol], 0
    mov byte [fc_dirty], 0
.sector:
    cmp [sc_vol], r14
    jne .walk
    mov qword [sc_vol], 0
    mov byte [sc_dirty], 0
.walk:
    cmp [de_vol], r14
    jne .out
    mov qword [de_vol], 0
.out:
    ret

; fat_vol -> R14 = the current FAT32 volume; CF (said so) if there is none
fat_vol:
    mov r14, [vol_current]
    test r14, r14
    jz .none
    cmp dword [r14 + VO_FS], FS_FAT32
    jne .other
    cmp byte [r14 + VF_MOUNTED], 0
    je .other
    mov byte [fat_ioerr], 0
    clc
    ret
.none:
    KLOG "no volume chosen: 'disks' lists them, 'vol <n>' picks one"
    stc
    ret
.other:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u has no FAT32 filesystem Axiom can use", rax
    stc
    ret

; fat_need_rw(R14) -> CF (said so) if the volume is read-only
fat_need_rw:
    cmp byte [r14 + VO_WRITABLE], 0
    je .ro
    mov byte [fat_writing], 1           ; a write is under way (see log_panic)
    clc
    ret
.ro:
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "vol%u is read-only ('vol %u rw' allows writes)", rax, rax
    stc
    ret

; fat_read_file(R14, RSI = path, RDI = buffer, RCX = its size) -> RAX = bytes
; read (all of it, or as much as fits), RDX = the file's size; CF (said why)
; if it is missing, a directory, or unreadable.
fat_read_file:
    push rbx
    push rcx
    push rsi
    push rdi
    push r8
    push r9
    mov r8, rdi
    mov r9, rcx
    call fat_resolve
    jc .out
    test byte [fat_ent + 11], 0x10
    jnz .dir
    mov edx, [fat_ent + 28]
    cmp r9, rdx
    jbe .sized
    mov r9, rdx
.sized:
    push rdx
    xor ebx, ebx                        ; bytes so far
    mov ecx, [r14 + VF_MAXCL]
.cluster:
    cmp rbx, r9
    jae .done
    call clus_ok
    jc .done                            ; the chain is shorter than the size
    push rax
    call clus_block
    mov rsi, rax
    mov edx, [r14 + VF_SPC]
    lea rdi, [fat_buf]
    call vol_read
    pop rax
    jc .io
    push rcx
    mov ecx, [r14 + VF_CBYTES]
    mov rdx, r9
    sub rdx, rbx
    cmp rdx, rcx
    jae .whole
    mov ecx, edx
.whole:
    lea rsi, [fat_buf]
    lea rdi, [r8 + rbx]
    add rbx, rcx
    rep movsb
    pop rcx
    call fat_get
    jc .io
    dec ecx
    jnz .cluster
.done:
    pop rdx
    mov rax, rbx
    clc
    jmp .out
.io:
    pop rdx
    call fat_io_failed
    stc
    jmp .out
.dir:
    KLOG "that is a directory"
    stc
.out:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; fat_write_file(R14, RSI = path, RDI = data, RCX = bytes) -> CF (said why):
; the file is created, or what it held is replaced.
fat_write_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r12
    push r13
    push r15
    mov r12, rdi
    mov r13, rcx
    call fat_need_rw
    jc .out
    mov rax, r13
    shr rax, 32
    jnz .too_big
    call fat_parent
    jc .out
    call comp_here
    jc .is_dir
    mov r15d, edi
    lea rsi, [fat_comp]
    call fat_lookup
    jc .new
    test byte [fat_ent + 11], 0x10
    jnz .is_dir
    test byte [fat_ent + 11], 0x01
    jnz .locked
    mov ebx, [ent_idx]
    push rax                            ; empty the entry, then free the old data
    mov esi, ebx
    call dir_entry
    jc .io_pop
    mov word [rax + 20], 0
    mov word [rax + 26], 0
    mov dword [rax + 28], 0
    call sec_mark
    pop rax
    call fat_free_chain
    jc .io
    jmp .data
.io_pop:
    pop rax
    jmp .io
.new:
    cmp byte [fat_ioerr], 0
    jne .io
    lea rsi, [fat_comp]
    mov edi, r15d
    mov dl, 0x20                        ; archive
    call fat_create
    jc .out
    mov ebx, esi
.data:
    call sec_drop
    xor r8d, r8d                        ; first cluster
    xor edx, edx                        ; the one before
    mov r10, r12
    mov r9, r13
.cluster:
    test r9, r9
    jz .entry
    call fat_alloc
    jc .undo
    test r8d, r8d
    jnz .linked
    mov r8d, eax
.linked:
    mov edx, eax
    call clus_write
    jc .undo
    jmp .cluster
.entry:
    mov edi, r15d
    mov esi, ebx
    call dir_entry
    jc .io
    mov rdx, rax
    mov eax, r8d
    mov [rdx + 26], ax
    shr eax, 16
    mov [rdx + 20], ax
    mov [rdx + 28], r13d
    call rtc_fat_time
    mov [rdx + 22], ax
    shr eax, 16
    mov [rdx + 24], ax
    mov [rdx + 18], ax
    call sec_mark
    call fat_sync
    jc .io
    clc
    jmp .out
.undo:
    mov eax, r8d                        ; what was taken goes back
    call fat_free_chain
    call fat_sync
    stc
    jmp .out
.too_big:
    KLOG "FAT32 files stop short of 4 GiB"
    stc
    jmp .out
.is_dir:
    KLOG "that is a directory"
    stc
    jmp .out
.locked:
    KLOG "that file is marked read-only"
    stc
    jmp .out
.io:
    call fat_io_failed
    call fat_sync
    stc
.out:
    pop r15
    pop r13
    pop r12
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; fat_mkdir(R14, RSI = path) -> CF (said why)
fat_mkdir:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r15
    call fat_need_rw
    jc .out
    call fat_parent
    jc .out
    call comp_here
    jc .exists
    mov r15d, edi
    lea rsi, [fat_comp]
    call fat_lookup
    jnc .exists
    cmp byte [fat_ioerr], 0
    jne .io
    xor edx, edx                        ; its own cluster, zeroed
    call fat_alloc
    jc .fail
    mov r12d, eax
    call clus_zero
    jc .io
    lea rsi, [fat_comp]
    mov edi, r15d
    mov dl, 0x10
    call fat_create
    jc .undo
    call dir_entry
    jc .io
    mov edx, r12d
    mov [rax + 26], dx
    shr edx, 16
    mov [rax + 20], dx
    call sec_mark
    mov edi, r12d                       ; "." and ".."
    xor esi, esi
    call dir_entry
    jc .io
    mov edx, r12d
    mov ecx, 1
    call dot_entry
    call sec_mark
    mov esi, 1
    call dir_entry
    jc .io
    mov edx, r15d
    cmp edx, [r14 + VF_ROOT]
    jne .parent
    xor edx, edx                        ; the root is cluster 0 here
.parent:
    mov ecx, 2
    call dot_entry
    call sec_mark
    call fat_sync
    jc .io
    clc
    jmp .out
.undo:
    mov eax, r12d
    call fat_free_chain
    call fat_sync
    jmp .fail
.exists:
    lea rax, [fat_comp]
    KLOG "'%s' is already there", rax
    jmp .fail
.io:
    call fat_io_failed
    call fat_sync
.fail:
    stc
.out:
    pop r15
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; fat_remove(R14, RSI = path) -> CF (said why): a file, or an empty directory
fat_remove:
    push rbx
    push rcx
    push rsi
    push rdi
    push r12
    push r13
    push r15
    call fat_need_rw
    jc .out
    call fat_parent
    jc .out
    call comp_here
    jc .refuse
    cmp word [fat_comp], '..'
    jne .look
    cmp byte [fat_comp + 2], 0
    je .refuse
.look:
    mov r15d, edi
    lea rsi, [fat_comp]
    call fat_lookup
    jc .missing
    mov r12d, eax                       ; its cluster
    mov ebx, [ent_idx]
    mov r13d, [ent_first]
    test byte [fat_ent + 11], 0x10
    jz .delete
    cmp r12d, [r14 + VF_ROOT]
    je .refuse
    cmp r12d, [r14 + VF_CWD]
    je .busy
    mov edi, r12d                       ; only "." and ".." may be left in it
    call dir_open
.check:
    call dir_next
    jc .checked
    cmp word [fat_name], '.'
    je .check
    cmp word [fat_name], '..'
    jne .not_empty
    cmp byte [fat_name + 2], 0
    jne .not_empty
    jmp .check
.checked:
    cmp byte [fat_ioerr], 0
    jne .io
.delete:
    mov edi, r15d
    mov esi, r13d
.mark:
    call dir_entry
    jc .io
    mov byte [rax], 0xE5
    call sec_mark
    inc esi
    cmp esi, ebx
    jbe .mark
    mov eax, r12d
    call fat_free_chain
    jc .io
    call fat_sync
    jc .io
    clc
    jmp .out
.missing:
    cmp byte [fat_ioerr], 0
    jne .io
    lea rax, [fat_comp]
    KLOG "nothing called '%s' there", rax
    jmp .fail
.refuse:
    KLOG "that cannot be removed"
    jmp .fail
.busy:
    KLOG "that is the current directory ('cd ..' first)"
    jmp .fail
.not_empty:
    KLOG "that directory is not empty"
    jmp .fail
.io:
    call fat_io_failed
    call fat_sync
.fail:
    stc
.out:
    pop r15
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  Shell: ls, cd, cat, write, mkdir, rm
; -----------------------------------------------------------------------------

; ls_line: one line for fat_ent and fat_name. Preserves all.
ls_line:
    push rax
    push rcx
    push rdx
    push rdi
    push r8
    push r9
    push r10
    push r11
    lea r10, [str_ls_dir]
    lea r11, [str_ls_slash]
    test byte [fat_ent + 11], 0x10
    jnz .date
    mov eax, [fat_ent + 28]
    lea r10, [ls_size]
    SPRINTF r10, "%b", rax
    lea r11, [str_ls_none]
.date:
    movzx eax, word [fat_ent + 24]      ; date
    mov ecx, eax
    shr ecx, 9
    add ecx, 1980
    mov edx, eax
    shr edx, 5
    and edx, 15
    and eax, 31
    movzx r8d, word [fat_ent + 22]      ; time
    mov r9d, r8d
    shr r9d, 5
    and r9d, 63
    shr r8d, 11
    lea rdi, [fat_name]
    KLOG "  %04u-%02u-%02u %02u:%02u  %10s  %s%s", rcx, rdx, rax, r8, r9, r10, rdi, r11
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

cmd_ls:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    call fat_resolve
    jc .out
    test byte [fat_ent + 11], 0x10
    jnz .dir
    call ls_line
    jmp .out
.dir:
    mov edi, eax
    call dir_open
    xor r12d, r12d                      ; files
    xor r13d, r13d                      ; directories
    xor r15d, r15d                      ; bytes
.next:
    call dir_next
    jc .done
    cmp word [fat_name], '.'
    je .next
    cmp word [fat_name], '..'
    jne .show
    cmp byte [fat_name + 2], 0
    je .next
.show:
    call ls_line
    test byte [fat_ent + 11], 0x10
    jnz .count_dir
    inc r12d
    mov eax, [fat_ent + 28]
    add r15, rax
    jmp .next
.count_dir:
    inc r13d
    jmp .next
.done:
    cmp byte [fat_ioerr], 0
    je .total
    call fat_io_failed
.total:
    KLOG "  %u files (%b), %u directories", r12, r15, r13
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

cmd_cd:
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    jne .go
    lea rax, [r14 + VF_PATH]
    KLOG "%s", rax
    jmp .out
.go:
    call path_join
    jc .long
    lea rsi, [fat_path]
    call fat_resolve
    jc .out
    test byte [fat_ent + 11], 0x10
    jz .not_dir
    mov [r14 + VF_CWD], eax
    lea rsi, [fat_path]
    lea rdi, [r14 + VF_PATH]
    mov ecx, 256 / 8
    rep movsq
    jmp .out
.not_dir:
    KLOG "that is a file"
    jmp .out
.long:
    KLOG "that path is too long"
.out:
    pop r14
    ret

cmd_cat:
    push rbx
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    lea rdi, [fat_file]
    mov ecx, FAT_FILE_MAX
    call fat_read_file
    jc .out
    mov rbx, rdx
    lea rsi, [fat_file]
    mov rcx, rax
    call print_text
    cmp rbx, rax
    jbe .out
    KLOG "(the first %b of %b)", rax, rbx
    jmp .out
.usage:
    KLOG "usage: cat <file>"
.out:
    pop r14
    pop rbx
    ret

; print_text(RSI = text, RCX = bytes): line by line, control characters as
; dots. Preserves all.
print_text:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    xor edx, edx
    lea rdi, [cat_line]
.next:
    test rcx, rcx
    jz .last
    lodsb
    dec rcx
    cmp al, 10
    je .line
    cmp al, 13
    je .next
    cmp al, 9
    jne .char
    mov al, ' '
.char:
    cmp al, ' '
    jb .dot
    cmp al, 0x7F
    jb .put
.dot:
    mov al, '.'
.put:
    mov [rdi + rdx], al
    inc edx
    cmp edx, 900
    jb .next
.line:
    mov byte [rdi + rdx], 0
    KLOG "%s", rdi
    xor edx, edx
    jmp .next
.last:
    test edx, edx
    jz .out
    mov byte [rdi + rdx], 0
    KLOG "%s", rdi
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; write <file> <text>: the text and a newline become the file
cmd_write:
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call arg_split
    push rsi
    mov rsi, rdi
    lea rdi, [fat_file]
    xor ecx, ecx
.copy:
    mov al, [rsi + rcx]
    test al, al
    jz .copied
    mov [rdi + rcx], al
    inc ecx
    jmp .copy
.copied:
    test ecx, ecx
    jz .empty
    mov byte [rdi + rcx], 10
    inc ecx
.empty:
    pop rsi
    call fat_write_file
    jc .out
    KLOG "wrote %u bytes to %s", rcx, rsi
    jmp .out
.usage:
    KLOG "usage: write <file> <text>"
.out:
    pop r14
    ret

; cp <from> <to>: files up to FAT_FILE_MAX
cmd_cp:
    push r12
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    call arg_split
    cmp byte [rsi], 0
    je .usage
    cmp byte [rdi], 0
    je .usage
    mov r12, rdi
    lea rdi, [fat_file]
    mov ecx, FAT_FILE_MAX
    call fat_read_file
    jc .out
    cmp rdx, rax
    ja .too_big
    mov rcx, rax
    mov rsi, r12
    lea rdi, [fat_file]
    call fat_write_file
    jc .out
    KLOG "copied %u bytes to %s", rcx, r12
    jmp .out
.too_big:
    KLOG "cp moves files up to 64 KiB for now"
    jmp .out
.usage:
    KLOG "usage: cp <from> <to>"
.out:
    pop r14
    pop r12
    ret

cmd_mkdir:
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call fat_mkdir
    jmp .out
.usage:
    KLOG "usage: mkdir <directory>"
.out:
    pop r14
    ret

cmd_rm:
    push r14
    call fat_vol
    jc .out
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .usage
    call fat_remove
    jmp .out
.usage:
    KLOG "usage: rm <file or empty directory>"
.out:
    pop r14
    ret

section .rodata
lfn_offsets:    db 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
fat_bad_chars:  db '"*/:<>?\|', 0
fat_short_specials: db '!#$%&', 0x27, '()-@^_`{}~', 0
str_ls_dir:     db '<dir>', 0
str_ls_slash:   db '/', 0
str_ls_none:    db 0

section .bss
alignb 8
fat_writing:    resb 1                  ; set by fat_need_rw, cleared between commands
alignb 8
fc_vol:         resq 1                  ; FAT sector cache
fc_sec:         resd 1
fc_dirty:       resb 1
alignb 8
sc_vol:         resq 1                  ; directory sector cache
sc_sec:         resq 1
sc_dirty:       resb 1
fat_dirtied:    resb 1                  ; something was written since the last sync
fat_ioerr:      resb 1
fat_hush:       resb 1                  ; a path not there is not said (httpd)
fat_sum:        resb 1
alignb 8
de_vol:         resq 1                  ; dir_entry's last walk
de_dir:         resd 1
de_idx:         resd 1
de_clus:        resd 1
it_dir:         resd 1                  ; dir_next
it_idx:         resd 1
lfn_state:      resd 1
lfn_sum:        resd 1
lfn_first:      resd 1
ent_idx:        resd 1
ent_first:      resd 1
fat_basis:      resq 1
fat_tail:       resq 1
fat_sname:      resb 11
fat_scase:      resb 1
fat_ent:        resb 32
fat_short:      resb 16
ls_size:        resb 32
fat_name:       resb 256
fat_comp:       resb 256
fat_path:       resb 256
cat_line:       resb 1024
alignb 4096
fc_buf:         resb 4096
sc_buf:         resb 4096
fat_buf:        resb 64 * 1024
fat_file:       resb FAT_FILE_MAX
