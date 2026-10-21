; =============================================================================
;  fat.asm - FAT32. Reads long names; writes them too, with an 8.3 alias
;  that no other entry in the directory has. One cached FAT sector (written
;  to every copy of the FAT) and one cached directory sector, both flushed
;  at the end of each operation, after which the drive is told to flush.
;  File data goes straight to its clusters: those that follow one another on
;  the disk in one command, up to FAT_RUN bytes.
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
VF_FREE         equ VO_FAT + 324        ; free clusters, once counted
VF_FREE_OK      equ VO_FAT + 328        ; byte: they were (fat_free_count)

FAT_EOC         equ 0x0FFFFFFF
FAT_FILE_MAX    equ 64 * 1024           ; what cat and the shell move at once
FAT_RUN         equ 1024 * 1024         ; file data read or written at once, at most
FC_SCAN         equ 64 * 1024           ; the FAT read at once, to count what is free

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
    mov byte [r14 + VF_FREE_OK], 0
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
    and esi, 0x0FFFFFFF
    cmp byte [r14 + VF_FREE_OK], 0      ; free clusters, as they change
    je .kept
    test eax, 0x0FFFFFFF
    jnz .was_used
    test esi, esi
    jz .kept
    dec dword [r14 + VF_FREE]
    jmp .kept
.was_used:
    test esi, esi
    jnz .kept
    inc dword [r14 + VF_FREE]
.kept:
    and eax, 0xF0000000                 ; the top four bits are not ours
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

; clus_run(R14, EAX = a cluster, EDX = how many are wanted, 1 or more) ->
; ECX = how many from it follow one another both in its chain and on the
; disk (1 to EDX), EAX = the cluster after them in the chain; CF on a disk
; error. Preserves others.
clus_run:
    push rsi
    mov esi, eax
    xor ecx, ecx
.grow:
    inc ecx
    call fat_get                        ; the next in the chain
    jc .out
    cmp ecx, edx
    jae .end
    cmp eax, [r14 + VF_MAXCL]
    ja .end
    push rcx
    add ecx, esi                        ; and the next on the disk
    cmp eax, ecx
    pop rcx
    je .grow
.end:
    clc
.out:
    pop rsi
    ret

; run_write(R14, ESI = a run's first cluster, ECX = its clusters, 0 for
; none, R10 = the data just past it) -> CF: the run, whole clusters that
; follow one another on the disk, written at once. Preserves all.
run_write:
    test ecx, ecx
    jz .none
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov eax, esi
    call clus_block
    mov rsi, rax                        ; its first block
    mov edx, ecx
    mov ecx, [r14 + VF_CSHIFT]
    shl edx, cl                         ; its blocks
    mov ecx, [r14 + VF_SSHIFT]
    mov rdi, rdx
    shl rdi, cl
    neg rdi
    add rdi, r10                        ; its data
    call vol_write
    jc .out
    mov byte [fat_dirtied], 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.none:
    clc
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

; fat_free_count(R14) -> EAX = its free clusters; CF on a disk error. The
; FAT is read through once, the first time, FC_SCAN bytes at a time;
; fat_set keeps the count after. Preserves others.
fat_free_count:
    cmp byte [r14 + VF_FREE_OK], 0
    jne .known
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    call fat_flush_cache                ; what is cached, on the disk first
    jc .failed
    xor r8d, r8d                        ; free clusters
    xor ebx, ebx                        ; the FAT's sector,
    xor r9d, r9d                        ; the entry its first
.piece:
    cmp r9d, [r14 + VF_MAXCL]
    ja .counted
    mov eax, [r14 + VF_FATSZ]
    sub eax, ebx
    jbe .counted                        ; (the FAT ends sooner)
    mov ecx, [r14 + VF_SSHIFT]
    mov edx, FC_SCAN
    shr edx, cl                         ; sectors at once
    cmp edx, eax
    jbe .sized
    mov edx, eax
.sized:
    mov esi, [r14 + VF_FAT]
    add esi, ebx
    lea rdi, [fc_scan]
    call vol_read
    jc .failed
    add ebx, edx
    shl edx, cl
    shr edx, 2                          ; its entries
    lea rsi, [fc_scan]
.entry:
    cmp r9d, 2                          ; (0 and 1 are not clusters)
    jb .next
    cmp r9d, [r14 + VF_MAXCL]
    ja .counted
    test dword [rsi], 0x0FFFFFFF
    jnz .next
    inc r8d
.next:
    add rsi, 4
    inc r9d
    dec edx
    jnz .entry
    jmp .piece
.counted:
    mov [r14 + VF_FREE], r8d
    mov byte [r14 + VF_FREE_OK], 1
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
.known:
    mov eax, [r14 + VF_FREE]
    clc
    ret
.failed:
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    stc
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
    KLOG "no folder '%s'", rax
.missing_hushed:
    stc
    jmp .out
.not_dir:
    cmp byte [fat_hush], 0
    jne .not_dir_hushed
    lea rax, [fat_comp]
    KLOG "'%s' is not a folder", rax
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
    KLOG "that folder is full"
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
    push r10
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
.cluster:
    cmp rbx, r9
    jae .done
    call clus_ok
    jc .done                            ; the chain is shorter than the size
    mov ecx, [r14 + VF_CSHIFT]
    add ecx, [r14 + VF_SSHIFT]
    mov rdx, r9
    sub rdx, rbx
    shr rdx, cl                         ; the whole clusters still wanted
    jz .part
    mov r10d, FAT_RUN
    shr r10d, cl                        ; at most this many at once
    cmp rdx, r10
    jbe .run
    mov rdx, r10
.run:
    mov r10d, eax                       ; a run from this cluster: ECX of
    call clus_run                       ; them, EAX the one after
    jc .io
    push rax
    mov eax, r10d
    call clus_block
    mov rsi, rax
    mov edx, ecx
    mov ecx, [r14 + VF_CSHIFT]
    shl edx, cl                         ; its blocks
    lea rdi, [r8 + rbx]                 ; straight into the buffer
    call vol_read
    pop rax
    jc .io
    mov ecx, [r14 + VF_SSHIFT]
    shl rdx, cl
    add rbx, rdx
    jmp .cluster
.part:
    push rax                            ; a part of the last, through fat_buf
    call clus_block
    mov rsi, rax
    mov edx, [r14 + VF_SPC]
    lea rdi, [fat_buf]
    call vol_read
    pop rax
    jc .io
    mov rcx, r9
    sub rcx, rbx
    lea rsi, [fat_buf]
    lea rdi, [r8 + rbx]
    add rbx, rcx
    rep movsb
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
    KLOG "that is a folder"
    stc
.out:
    pop r10
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
    push r11
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
    mov r10, r12                        ; the data not yet given a cluster
    mov r9, r13
    mov ecx, [r14 + VF_CSHIFT]
    add ecx, [r14 + VF_SSHIFT]
    mov r11d, FAT_RUN
    shr r11d, cl                        ; clusters written at once, at most
    xor ecx, ecx                        ; given, not yet written: from ESI
.cluster:
    test r9, r9
    jz .written
    call fat_alloc
    jc .undo
    test r8d, r8d
    jnz .linked
    mov r8d, eax
.linked:
    mov edx, eax
    mov edi, [r14 + VF_CBYTES]
    cmp r9, rdi
    jb .last                            ; a part of one is left
    test ecx, ecx
    jz .run
    cmp ecx, r11d
    jae .flush
    lea edi, [esi + ecx]
    cmp eax, edi                        ; the next on the disk: onto the run
    jne .flush
    inc ecx
    jmp .advance
.flush:
    call run_write
    jc .undo
.run:
    mov esi, eax
    mov ecx, 1
.advance:
    mov edi, [r14 + VF_CBYTES]
    add r10, rdi
    sub r9, rdi
    jmp .cluster
.last:
    call run_write
    jc .undo
    xor ecx, ecx
    call clus_write                     ; through fat_buf, with zeros after
    jc .undo
.written:
    call run_write
    jc .undo
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
    KLOG "that is a folder"
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
    KLOG "that is the current folder ('go ..' first)"
    jmp .fail
.not_empty:
    KLOG "that folder is not empty"
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
RN_ENTRIES      equ 32                  ; a name's entries, at most (20 long, 1 short)

; fat_rename(R14, RSI = path, RDI = its new path) -> CF and RAX = E_* (said
; why): a file or a folder renamed where it is, or moved to another folder
; of the volume. Its entries are written again; what it holds stays where it
; is on the disk. Preserves others but RAX.
fat_rename:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push rbp
    push r12
    push r13
    push r15
    mov [rn_new], rdi
    call fat_need_rw
    mov eax, E_READONLY
    jc .err
    call fat_parent                     ; the old: the folder it is in
    jc .missing_part
    call comp_here
    jc .refuse
    cmp word [fat_comp], '..'
    jne .look
    cmp byte [fat_comp + 2], 0
    je .refuse
.look:
    mov r15d, edi                       ; R15D: the folder it is in
    lea rsi, [fat_comp]
    call fat_lookup
    jc .missing
    mov r12d, eax                       ; R12D: its cluster
    mov ebx, [ent_idx]                  ; EBX: its own entry, R13D: its first
    mov r13d, [ent_first]
    mov eax, ebx
    sub eax, r13d
    cmp eax, RN_ENTRIES
    jae .refuse
    lea rsi, [fat_ent]
    lea rdi, [rn_ent]
    mov ecx, 4
    rep movsq
    test byte [rn_ent + 11], 0x10
    jz .new
    cmp r12d, [r14 + VF_ROOT]
    je .refuse
    mov eax, [r14 + VF_CWD]             ; not the shell's folder, nor one it is in
    mov edx, r12d
    call dir_within
    jc .busy
.new:
    mov rsi, [rn_new]                   ; the new: its folder
    call fat_parent
    jc .missing_part
    call comp_here
    jc .refuse
    mov ebp, edi                        ; EBP: the folder it goes to
    lea rsi, [fat_comp]
    call fat_lookup
    jc .free
    cmp ebp, r15d                       ; itself, its case changed: fine
    jne .exists
    cmp [ent_idx], ebx
    jne .exists
    jmp .named
.free:
    cmp byte [fat_ioerr], 0
    jne .io
.named:
    push r12
    lea r12, [fat_comp]
    call fat_name_ok
    pop r12
    mov eax, E_ARG
    jc .err
    test byte [rn_ent + 11], 0x10       ; a folder: not into itself
    jz .unmark
    cmp ebp, r15d
    je .unmark
    mov eax, ebp
    mov edx, r12d
    call dir_within
    jc .inside
.unmark:
    mov edi, r15d                       ; its entries let go, their first
    mov esi, r13d                       ; bytes kept, to put back
    xor ecx, ecx
.mark:
    call dir_entry
    jc .io
    mov dl, [rax]
    mov [rn_first + rcx], dl
    mov byte [rax], 0xE5
    call sec_mark
    inc ecx
    inc esi
    cmp esi, ebx
    jbe .mark
    mov [rn_count], ecx
    lea rsi, [fat_comp]                 ; its new ones
    mov edi, ebp
    mov dl, [rn_ent + 11]
    call fat_create
    jc .restore
    call dir_entry
    jc .io
    push rsi
    push rdi
    lea rsi, [rn_ent + 13]              ; its times, its cluster, its size
    lea rdi, [rax + 13]
    mov ecx, 32 - 13
    rep movsb
    pop rdi
    pop rsi
    call sec_mark
    test byte [rn_ent + 11], 0x10       ; a folder moved: its ".." too
    jz .synced
    cmp ebp, r15d
    je .synced
    mov edi, r12d
    mov esi, 1
    call dir_entry
    jc .io
    mov edx, ebp
    cmp edx, [r14 + VF_ROOT]
    jne .up
    xor edx, edx                        ; the root is cluster 0 here
.up:
    mov [rax + 26], dx
    shr edx, 16
    mov [rax + 20], dx
    call sec_mark
.synced:
    call fat_sync
    jc .io
    xor eax, eax
    clc
    jmp .out
.restore:
    mov edi, r15d
    mov esi, r13d
    xor ecx, ecx
.back:
    cmp ecx, [rn_count]
    jae .restored
    call dir_entry
    jc .io
    mov dl, [rn_first + rcx]
    mov [rax], dl
    call sec_mark
    inc ecx
    inc esi
    jmp .back
.restored:
    call fat_sync
    mov eax, E_ARG
    cmp byte [fat_ioerr], 0
    je .err
    mov eax, E_IO
    jmp .err
.missing_part:
    mov eax, E_NOFILE
    cmp byte [fat_ioerr], 0
    je .err
    mov eax, E_IO
    jmp .err
.missing:
    cmp byte [fat_ioerr], 0
    jne .io
    lea rax, [fat_comp]
    KLOG "nothing called '%s' there", rax
    mov eax, E_NOFILE
    jmp .err
.exists:
    lea rax, [fat_comp]
    KLOG "'%s' is already there", rax
    mov eax, E_EXISTS
    jmp .err
.refuse:
    KLOG "that cannot be renamed"
    mov eax, E_ARG
    jmp .err
.busy:
    KLOG "that is the current folder, or holds it ('go' elsewhere first)"
    mov eax, E_ARG
    jmp .err
.inside:
    KLOG "a folder cannot go inside itself"
    mov eax, E_ARG
    jmp .err
.io:
    call fat_io_failed
    call fat_sync
    mov eax, E_IO
.err:
    movsx rax, eax
    stc
.out:
    pop r15
    pop r13
    pop r12
    pop rbp
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; dir_within(R14, EAX = a directory, EDX = another) -> CF if the other is it,
; or a folder it is in (or the disk failed finding out). Preserves others but
; RAX.
dir_within:
    push rcx
    push rsi
    push rdi
    mov ecx, 256                        ; deeper than a path goes
.each:
    cmp eax, edx
    je .yes
    cmp eax, [r14 + VF_ROOT]
    je .no
    test eax, eax
    jz .no
    dec ecx
    jz .no
    mov edi, eax                        ; up, by its ".."
    mov esi, 1
    call dir_entry
    jc .yes
    movzx edi, word [rax + 20]
    shl edi, 16
    mov di, [rax + 26]
    mov eax, edi
    test eax, eax
    jnz .each
    mov eax, [r14 + VF_ROOT]
    jmp .each
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; -----------------------------------------------------------------------------
;  Shell: the files thing, go and here. Each action takes its words (EDI =
;  how many, RSI = them) and gives records (records.asm); CF if it failed.
;  Paths may have wildcards in their last part (copy, move, remove).
; -----------------------------------------------------------------------------

FX_PATHS        equ 64 * 1024           ; the paths an action works through

; fx_columns: name (or path), kind, size, changed
fx_columns:
    COLUMN 'name', FT_TEXT
    COLUMN 'kind', FT_TEXT
    COLUMN 'size', FT_SIZE
    COLUMN 'changed', FT_TIME
    ret

; fx_row(RSI = its name or path): a row for fat_ent. Preserves all.
fx_row:
    push rax
    push rsi
    push rdi
    call rec_row
    xor edi, edi
    call rec_str
    mov edi, 1
    lea rsi, [str_fx_file]
    test byte [fat_ent + 11], 0x10
    jz .kind
    lea rsi, [str_fx_folder]
.kind:
    call rec_set
    mov edi, 2
    test byte [fat_ent + 11], 0x10
    jz .size
    call rec_none
    jmp .time
.size:
    mov esi, [fat_ent + 28]
    call rec_set
.time:
    mov edi, 3
    movzx eax, word [fat_ent + 24]      ; the date,
    test eax, eax
    jnz .dated
    call rec_none
    jmp .out
.dated:
    shl eax, 16
    mov ax, [fat_ent + 22]              ; and the time
    call rec_fat_time
    mov rsi, rax
    call rec_set
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; fx_skip -> ZF if fat_name is . or ..
fx_skip:
    cmp word [fat_name], '.'
    je .out
    cmp word [fat_name], '..'
    jne .out
    cmp byte [fat_name + 2], 0
.out:
    ret

; fx_split(RSI = a path) -> fx_dir = the folder part ("" if there is none),
; RAX = what follows the last /. Preserves others.
fx_split:
    push rcx
    push rdx
    push rdi
    xor ecx, ecx
    xor edx, edx                        ; just after the last /
.scan:
    mov al, [rsi + rcx]
    test al, al
    jz .found
    inc ecx
    cmp al, '/'
    jne .scan
    mov edx, ecx
    jmp .scan
.found:
    lea rdi, [fx_dir]
    xor ecx, ecx
.copy:
    cmp ecx, edx
    jae .copied
    cmp ecx, 255
    jae .copied
    mov al, [rsi + rcx]
    mov [rdi + rcx], al
    inc ecx
    jmp .copy
.copied:
    cmp ecx, 1                          ; "a/": "a"; "/" stays
    jbe .end
    cmp byte [rdi + rcx - 1], '/'
    jne .end
    dec ecx
.end:
    mov byte [rdi + rcx], 0
    lea rax, [rsi + rdx]
    pop rdi
    pop rdx
    pop rcx
    ret

; fx_list_dir(R14, EDI = a folder's cluster, RSI = a pattern or 0): a row
; for each thing in it that matches -> CF (said) if it could not be read
fx_list_dir:
    push rdi
    call dir_open
.next:
    call dir_next
    jc .done
    call fx_skip
    je .next
    test rsi, rsi
    jz .row
    push rsi
    mov rdi, rsi
    lea rsi, [fat_name]
    call glob_match
    pop rsi
    test eax, eax
    jz .next
.row:
    push rsi
    lea rsi, [fat_name]
    call fx_row
    pop rsi
    jmp .next
.done:
    pop rdi
    cmp byte [fat_ioerr], 0
    je .ok
    call fat_io_failed
    stc
    ret
.ok:
    clc
    ret

; fx_folder(R14, RSI = a path) -> EAX = the folder's cluster; CF (said) if
; it is not one
fx_folder:
    call fat_resolve
    jc .out
    test byte [fat_ent + 11], 0x10
    jnz .out
    KLOG "%s is a file, not a folder", rsi
    stc
.out:
    ret

; files [folder | pattern]: what is there
files_list:
    push r12
    push r13
    push r14
    mov r12d, edi
    mov r13, rsi
    cmp r12d, 1
    ja .usage
    call fat_vol
    jc .fail
    call fx_columns
    lea rsi, [rec_empty]                ; here
    test r12d, r12d
    jz .path
    mov rsi, [r13]
    mov rdi, rsi
    call rec_wild
    test eax, eax
    jnz .pattern
.path:
    call fat_resolve
    jc .fail
    test byte [fat_ent + 11], 0x10
    jnz .folder
    call fx_row                         ; one file
    clc
    jmp .out
.folder:
    mov edi, eax
    xor esi, esi
    call fx_list_dir
    jmp .out
.pattern:
    call fx_split
    mov r13, rax
    lea rsi, [fx_dir]
    call fx_folder
    jc .fail
    mov edi, eax
    mov rsi, r13
    call fx_list_dir
    jmp .out
.usage:
    KLOG "usage: files [folder | pattern]"
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    ret

; files show <file>: its lines, UTF-8 drawn as the console can, a long one
; in pieces
files_show:
    push rbx
    push r12
    push r13
    push r14
    push r15
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    call fat_vol
    jc .fail
    mov rdi, [rec_tmp]
    mov ecx, TB_BYTES
    call fat_read_file
    jc .fail
    mov r12, [rec_tmp]
    mov r13, rax                        ; bytes read
    mov r15, rdx                        ; its size
    COLUMN 'text', FT_TEXT
    mov edi, TBF_LINES
    call rec_flag
    cmp r15, r13
    jbe .whole
    mov edi, TBF_CUT
    call rec_flag
.whole:
    mov qword [fx_utf8], 0
    xor ebx, ebx                        ; the line so far
.byte:
    test r13, r13
    jz .last
    mov al, [r12]
    inc r12
    dec r13
    lea rdi, [fx_utf8]
    call utf8_step
    jc .byte
    cmp eax, 10
    je .line
    cmp eax, 13
    je .byte
    call glyph_of
    test eax, eax
    jz .byte
    cmp eax, ' '
    jae .put
    mov eax, '.'
.put:
    mov [fx_line + rbx], al
    inc ebx
    cmp ebx, REC_CHUNK
    jb .byte
.line:
    call rec_row
    jc .done
    xor edi, edi
    lea rsi, [fx_line]
    mov edx, ebx
    call rec_strn
    xor ebx, ebx
    jmp .byte
.last:
    test ebx, ebx
    jz .done
    call rec_row
    jc .done
    xor edi, edi
    lea rsi, [fx_line]
    mov edx, ebx
    call rec_strn
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: files show <file>"
.fail:
    stc
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; fx_add(RSI = a path) -> onto fx_paths; CF (said) if there is no room.
; Preserves all.
fx_add:
    push rax
    push rcx
    push rsi
    push rdi
    mov rdi, rsi
    call strlen
    mov rdi, [fx_end]
    lea rcx, [rdi + rax + 1]
    lea rax, [fx_paths + FX_PATHS]
    cmp rcx, rax
    ja .full
.copy:
    lodsb
    stosb
    test al, al
    jnz .copy
    mov [fx_end], rdi
    inc dword [fx_count]
    clc
    jmp .out
.full:
    KLOG "that is too many files at once"
    stc
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; fx_expand(R14, RSI = a path, with a pattern in its last part, or not) ->
; onto fx_paths, each thing it names; CF (said) if a pattern matches nothing
fx_expand:
    push rbx
    push r12
    push r13
    mov r12, rsi
    mov rdi, rsi
    call rec_wild
    test eax, eax
    jnz .pattern
    call fx_add
    jmp .out
.pattern:
    call fx_split
    mov r13, rax                        ; the pattern
    lea rsi, [fx_dir]
    call fx_folder
    jc .out
    mov ebx, [fx_count]
    mov edi, eax
    call dir_open
.next:
    call dir_next
    jc .looked
    call fx_skip
    je .next
    mov rdi, r13
    lea rsi, [fat_name]
    call glob_match
    test eax, eax
    jz .next
    call rec_begin                      ; the folder, then the name
    lea rsi, [fx_dir]
    call rec_puts
    cmp byte [fx_dir], 0
    je .name
    cmp word [fx_dir], '/'
    je .name
    lea rsi, [str_fx_slash]
    call rec_puts
.name:
    lea rsi, [fat_name]
    call rec_puts
    lea rsi, [rec_line]
    call fx_add
    jc .out
    jmp .next
.looked:
    cmp byte [fat_ioerr], 0
    je .counted
    call fat_io_failed
    stc
    jmp .out
.counted:
    cmp [fx_count], ebx
    jne .found
    KLOG "nothing matches %s", r12
    stc
    jmp .out
.found:
    clc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; fx_start: fx_paths empty
fx_start:
    lea rax, [fx_paths]
    mov [fx_end], rax
    mov dword [fx_count], 0
    ret

; fx_target(R14, RSI = from, RDI = to, EDX = 1 if <to> is a folder) ->
; fx_to = where the copy goes. Preserves all.
fx_target:
    push rax
    push rcx
    push rsi
    push rdi
    push rsi
    call rec_begin
    mov rsi, rdi
    call rec_puts
    pop rsi
    test edx, edx
    jz .copy
    mov eax, [rec_len]                  ; <to>/<its last part>
    test eax, eax
    jz .base
    cmp byte [rec_line + rax - 1], '/'
    je .base
    push rsi
    lea rsi, [str_fx_slash]
    call rec_puts
    pop rsi
.base:
    call fx_split
    mov rsi, rax
    call rec_puts
.copy:
    lea rdi, [fx_to]
    lea rsi, [rec_line]
    mov ecx, 256
    call rec_copyz
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; fx_same(R14, RSI = a path, RDI = another) -> CF if both name one file.
; Preserves all.
fx_same:
    push rax
    push rcx
    push rsi
    push rdi
    push rdi
    call path_join
    pop rdi
    jc .no
    push rdi
    lea rdi, [fx_from]
    lea rsi, [fat_path]
    mov ecx, 256
    call rec_copyz
    pop rsi
    call path_join
    jc .no
    lea rdi, [fx_from]
    lea rsi, [fat_path]
    call rec_icmp
    test eax, eax
    jnz .no
    stc
    jmp .out
.no:
    clc
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; fx_copy_one(R14, RSI = from, RDI = to) -> RAX = bytes; CF (said) if not
fx_copy_one:
    push rbx
    push rcx
    push rdx
    push r12
    push r13
    mov r12, rdi
    call fat_resolve
    jc .fail
    test byte [fat_ent + 11], 0x10
    jnz .folder
    mov r13d, [fat_ent + 28]
    lea rdi, [r13 + 1]
    call vm_alloc
    test rax, rax
    jz .no_memory
    mov rbx, rax
    mov rdi, rbx
    mov rcx, r13
    call fat_read_file
    jc .free
    cmp rax, r13
    jb .short
    push rsi
    mov rsi, r12
    mov rdi, rbx
    mov rcx, r13
    call fat_write_file
    pop rsi
    jc .free
    mov rdi, rbx
    call vm_free
    mov rax, r13
    clc
    jmp .out
.short:
    KLOG "%s: its data is shorter than its size", rsi
.free:
    mov rdi, rbx
    call vm_free
    jmp .fail
.folder:
    KLOG "%s is a folder: copy and move take files", rsi
    jmp .fail
.no_memory:
    KLOG "no memory for %s", rsi
.fail:
    stc
.out:
    pop r13
    pop r12
    pop rdx
    pop rcx
    pop rbx
    ret

; files copy <from>... <to>, and files move (EDX = 1): each into <to> if it
; is a folder, else <to> is the one copy
files_copy:
    xor edx, edx
    jmp fx_copy
files_move:
    mov edx, 1
fx_copy:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    mov ebp, edx                        ; moving
    cmp edi, 2
    jb .usage
    mov r12d, edi
    mov r13, rsi
    call fat_vol
    jc .fail
    call fx_start
    xor ebx, ebx
.expand:
    lea eax, [r12d - 1]
    cmp ebx, eax
    jae .expanded
    mov rsi, [r13 + rbx * 8]
    call fx_expand
    jc .fail
    inc ebx
    jmp .expand
.expanded:
    mov r15, [r13 + rbx * 8]            ; <to>
    mov byte [fx_into], 0               ; a folder?
    mov byte [fat_hush], 1
    mov rsi, r15
    call fat_resolve
    mov byte [fat_hush], 0
    jc .to_said
    test byte [fat_ent + 11], 0x10
    jz .to_said
    mov byte [fx_into], 1
.to_said:
    mov rdi, r15                        ; a name ending in / must be one
    call strlen
    test rax, rax
    jz .one
    cmp byte [r15 + rax - 1], '/'
    jne .one
    cmp byte [fx_into], 0
    jne .one
    KLOG "there is no folder %s", r15
    jmp .fail
.one:
    cmp byte [fx_into], 0
    jne .each_start
    mov eax, [fx_count]
    cmp eax, 1
    je .each_start
    KLOG "%s is not a folder, and there are %u to go into it", r15, rax
    jmp .fail
.each_start:
    xor r12d, r12d                      ; done
    xor ebx, ebx                        ; bytes
    lea r13, [fx_paths]
.each:
    cmp r13, [fx_end]
    jae .each_done
    mov rsi, r13
    mov rdi, r15
    movzx edx, byte [fx_into]
    call fx_target
    lea rdi, [fx_to]
    call fx_same
    jc .same
    call fx_copy_one
    jc .each_next
    add rbx, rax
    test ebp, ebp
    jz .copied
    call fat_remove
    jc .each_next
.copied:
    inc r12d
.each_next:
    mov rdi, r13
    call strlen
    lea r13, [r13 + rax + 1]
    jmp .each
.same:
    KLOG "%s and %s are the same file", rsi, rdi
    jmp .each_next
.each_done:
    mov eax, [fx_count]
    lea rsi, [str_fx_copied]
    test ebp, ebp
    jz .verb
    lea rsi, [str_fx_moved]
.verb:
    cmp eax, 1
    jne .many
    cmp r12d, 1
    jne .none
    lea rax, [fx_to]
    lea rdx, [fx_paths]
    KLOG "%s %s to %s (%b)", rsi, rdx, rax, rbx
    clc
    jmp .out
.many:
    KLOG "%s %u of %u (%b) to %s", rsi, r12, rax, rbx, r15
    cmp r12d, eax
    jne .fail
    clc
    jmp .out
.none:
    jmp .fail
.usage:
    KLOG "usage: files copy|move <from>... <to>"
.fail:
    stc
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; files new <name>[/]...: an empty file, or a folder
files_new:
    push rbx
    push r12
    push r13
    push r14
    test edi, edi
    jz .usage
    mov r12d, edi
    mov r13, rsi
    call fat_vol
    jc .fail
    xor ebx, ebx
.next:
    cmp ebx, r12d
    jae .done
    mov rsi, [r13 + rbx * 8]
    mov rdi, rsi
    call strlen
    test rax, rax
    jz .bad
    mov rcx, rax
    mov byte [fat_hush], 1
    call fat_resolve
    mov byte [fat_hush], 0
    jnc .there
    cmp byte [rsi + rcx - 1], '/'
    je .folder
    lea rdi, [fx_from]                  ; (no bytes)
    xor ecx, ecx
    call fat_write_file
    jc .fail
    KLOG "made %s", rsi
    jmp .made
.folder:
    call fat_mkdir
    jc .fail
    KLOG "made %s", rsi
.made:
    inc ebx
    jmp .next
.there:
    KLOG "%s is there already", rsi
    jmp .fail
.bad:
    KLOG "a name, please"
    jmp .fail
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: files new <name>... (a folder if it ends in /)"
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; files write <file> <text>...: the text and a newline become the file
files_write:
    push r12
    push r13
    push r14
    test edi, edi
    jz .usage
    mov r12d, edi
    mov r13, rsi
    call fat_vol
    jc .fail
    lea edi, [r12d - 1]
    lea rsi, [r13 + 8]
    call sh_join
    lea rsi, [sh_joined]
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
    mov rsi, [r13]
    call fat_write_file
    jc .fail
    KLOG "wrote %u bytes to %s", rcx, rsi
    clc
    jmp .out
.usage:
    KLOG "usage: files write <file> <text>..."
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    ret

; files remove <path or pattern>...: each file, or empty folder
files_remove:
    push rbx
    push r12
    push r13
    push r14
    test edi, edi
    jz .usage
    mov r12d, edi
    mov r13, rsi
    call fat_vol
    jc .fail
    call fx_start
    xor ebx, ebx
.expand:
    cmp ebx, r12d
    jae .expanded
    mov rsi, [r13 + rbx * 8]
    call fx_expand
    jc .fail
    inc ebx
    jmp .expand
.expanded:
    xor r12d, r12d                      ; removed
    lea r13, [fx_paths]
.each:
    cmp r13, [fx_end]
    jae .done
    mov rsi, r13
    call fat_remove
    jc .next
    inc r12d
.next:
    mov rdi, r13
    call strlen
    lea r13, [r13 + rax + 1]
    jmp .each
.done:
    mov eax, [fx_count]
    cmp eax, 1
    jne .many
    test r12d, r12d
    jz .fail
    lea rax, [fx_paths]
    KLOG "removed %s", rax
    clc
    jmp .out
.many:
    KLOG "removed %u of %u", r12, rax
    cmp r12d, eax
    jne .fail
    clc
    jmp .out
.usage:
    KLOG "usage: files remove <path or pattern>..."
.fail:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; files find [pattern]: everything below here that matches (everything if
; no pattern), a folder at a time, nearest first, each with its path from
; here. The folders still to look in queue in rec_tmp: a dword cluster,
; then the path.
files_find:
    push rbx
    push r12
    push r13
    push r14
    push r15
    push rbp
    cmp edi, 1
    ja .usage
    lea r12, [str_fx_all]
    test edi, edi
    jz .pattern
    mov r12, [rsi]
.pattern:
    call fat_vol
    jc .fail
    COLUMN 'path', FT_TEXT
    COLUMN 'kind', FT_TEXT
    COLUMN 'size', FT_SIZE
    COLUMN 'changed', FT_TIME
    mov r13, [rec_tmp]                  ; the next folder to look in
    mov r15, r13                        ; where the next one queued goes
    lea rbp, [r13 + TB_BYTES - 512]
    mov eax, [r14 + VF_CWD]
    mov [r15], eax
    mov byte [r15 + 4], 0               ; "" : here
    add r15, 5
.folder:
    cmp r13, r15
    jae .done
    mov edi, [r13]
    lea rbx, [r13 + 4]                  ; its path
    call dir_open
.entry:
    call dir_next
    jc .looked
    call fx_skip
    je .entry
    call rec_begin                      ; its path: the folder's, then its name
    mov rsi, rbx
    call rec_puts
    cmp byte [rbx], 0
    je .named
    lea rsi, [str_fx_slash]
    call rec_puts
.named:
    lea rsi, [fat_name]
    call rec_puts
    cmp dword [rec_len], 250
    jae .entry                          ; too deep to name
    mov rdi, r12
    lea rsi, [fat_name]
    call glob_match
    test eax, eax
    jz .queue
    lea rsi, [rec_line]
    call fx_row
.queue:
    test byte [fat_ent + 11], 0x10
    jz .entry
    cmp r15, rbp
    jae .full
    movzx eax, word [fat_ent + 20]      ; its cluster
    shl eax, 16
    mov ax, [fat_ent + 26]
    mov [r15], eax
    lea rdi, [r15 + 4]
    lea rsi, [rec_line]
    mov ecx, 256
    call rec_copyz
    mov rdi, rsi
    call strlen
    lea r15, [r15 + 4 + rax + 1]
    jmp .entry
.full:
    mov edi, TBF_CUT
    call rec_flag
    jmp .entry
.looked:
    cmp byte [fat_ioerr], 0
    jne .io
    mov rdi, rbx                        ; on to the next folder queued
    call strlen
    lea r13, [rbx + rax + 1]
    jmp .folder
.io:
    call fat_io_failed
    jmp .fail
.done:
    clc
    jmp .out
.usage:
    KLOG "usage: files find [pattern]"
.fail:
    stc
.out:
    pop rbp
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; go [folder]: there (to / alone)
cmd_go:
    push r12
    push r14
    cmp edi, 1
    ja .usage
    lea r12, [str_fx_root]
    test edi, edi
    jz .go
    mov r12, [rsi]
.go:
    call fat_vol
    jc .fail
    mov rsi, r12
    call path_join
    jc .long
    lea rsi, [fat_path]
    call fx_folder
    jc .fail
    mov [r14 + VF_CWD], eax
    lea rsi, [fat_path]
    lea rdi, [r14 + VF_PATH]
    mov ecx, 256 / 8
    rep movsq
    clc
    jmp .out
.long:
    KLOG "that path is too long"
    jmp .fail
.usage:
    KLOG "usage: go [folder]"
.fail:
    stc
.out:
    pop r14
    pop r12
    ret

; here: the folder you are in, as vol<n>:<path>
cmd_here:
    push r14
    call fat_vol
    jc .out
    COLUMN 'path', FT_TEXT
    push rdi
    mov edi, TBF_LINES
    call rec_flag
    pop rdi
    call rec_row
    movzx eax, byte [r14 + VO_INDEX]
    lea rcx, [r14 + VF_PATH]
    lea rdi, [fx_from]
    SPRINTF rdi, "vol%u:%s", rax, rcx
    xor edi, edi
    lea rsi, [fx_from]
    call rec_str
    clc
.out:
    pop r14
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

section .rodata
lfn_offsets:    db 1, 3, 5, 7, 9, 14, 16, 18, 20, 22, 24, 28, 30
fat_bad_chars:  db '"*/:<>?\|', 0
fat_short_specials: db '!#$%&', 0x27, '()-@^_`{}~', 0
str_fx_file:    db 'file', 0
str_fx_folder:  db 'folder', 0
str_fx_slash:   db '/', 0
str_fx_root:    db '/', 0
str_fx_all:     db '*', 0
str_fx_copied:  db 'copied', 0
str_fx_moved:   db 'moved', 0

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
rn_new:         resq 1                  ; fat_rename: the new path
rn_count:       resd 1
rn_ent:         resb 32                 ; its entry, as it was
rn_first:       resb RN_ENTRIES         ; its entries' first bytes, to put back
fat_basis:      resq 1
fat_tail:       resq 1
fat_sname:      resb 11
fat_scase:      resb 1
fat_ent:        resb 32
fat_short:      resb 16
fat_name:       resb 256
fat_comp:       resb 256
fat_path:       resb 256
cat_line:       resb 1024
alignb 8
fx_end:         resq 1                  ; fx_paths: where the next goes,
fx_utf8:        resq 1                  ; files show: utf8_step's state
fx_count:       resd 1                  ; and how many there are
fx_into:        resb 1                  ; copy, move: <to> is a folder
fx_dir:         resb 256                ; fx_split: the folder part
fx_to:          resb 256                ; fx_target: where a copy goes
fx_from:        resb 320
fx_line:        resb 1024               ; files show: a line
fx_paths:       resb FX_PATHS           ; the paths an action works through
alignb 4096
fc_buf:         resb 4096
sc_buf:         resb 4096
fat_buf:        resb 64 * 1024
fc_scan:        resb FC_SCAN
fat_file:       resb FAT_FILE_MAX
