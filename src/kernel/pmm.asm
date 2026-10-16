; =============================================================================
;  pmm.asm - physical page allocator: one bit per 4 KiB page, 1 = in use
;
;  Pages below 1 MiB are never handed out (the AP trampoline lives there).
;  Boot-services memory stays reserved until pmm_release_boot_services,
;  after the firmware tables it may hold have been read.
; =============================================================================

LOW_PAGES       equ 256                 ; pages below 1 MiB

section .text

; mmap_walk: R12 = first descriptor, R13 = end, R14 = descriptor size
mmap_setup:
    mov rax, [boot_info]
    mov r12, [rax + BI_MMAP]
    add r12, [phys_base]
    mov r13, [rax + BI_MMAP_SIZE]
    add r13, r12
    mov r14, [rax + BI_MMAP_DSIZE]
    ret

; pmm_usable(EAX = type) -> CF = 1 for memory that is free once we own the machine
pmm_usable:
    cmp eax, MT_CONVENTIONAL
    je .yes
    cmp eax, MT_LOADER_CODE
    jb .no
    cmp eax, MT_BS_DATA
    ja .no
.yes:
    stc
    ret
.no:
    clc
    ret

pmm_init:
    push rbx
    push r12
    push r13
    push r14
    push r15
    call mmap_setup

    xor r15d, r15d                      ; pass 1: extent and per-type totals
    mov rsi, r12
.extent:
    cmp rsi, r13
    jae .extent_done
    mov eax, [rsi]
    mov rcx, [rsi + 24]
    shl rcx, 12
    mov edx, eax
    cmp edx, 15
    jbe .count_type
    mov edx, 15
.count_type:
    lea rdi, [mem_by_type]
    add [rdi + rdx * 8], rcx
    call pmm_usable
    jnc .extent_next
    add [pmm_usable_bytes], rcx
    add rcx, [rsi + 8]
    cmp rcx, r15
    cmova r15, rcx
.extent_next:
    add rsi, r14
    jmp .extent
.extent_done:
    mov [pmm_top], r15
    shr r15, 12
    mov [pmm_pages], r15
    add r15, 63
    shr r15, 6
    mov [pmm_qwords], r15
    shl r15, 3
    add r15, 0xFFF
    shr r15, 12
    mov [pmm_bitmap_pages], r15

    mov rsi, r12                        ; pass 2: a home for the bitmap
.home:
    cmp rsi, r13
    jae .no_home
    cmp dword [rsi], MT_CONVENTIONAL
    jne .home_next
    cmp qword [rsi + 8], 0x100000
    jb .home_next
    cmp [rsi + 24], r15
    jb .home_next
    mov rax, [rsi + 8]
    mov [pmm_bitmap_phys], rax
    jmp .home_found
.home_next:
    add rsi, r14
    jmp .home
.no_home:
    xor edi, edi
    lea rsi, [str_pmm_nohome]
    jmp panic
.home_found:
    add rax, [phys_base]
    mov [pmm_bitmap], rax
    mov rdi, rax
    mov rcx, [pmm_qwords]
    mov rax, -1
    rep stosq                           ; everything starts in use

    mov rsi, r12                        ; pass 3: free loader and conventional memory
.free:
    cmp rsi, r13
    jae .free_done
    mov eax, [rsi]
    cmp eax, MT_CONVENTIONAL
    je .free_it
    cmp eax, MT_LOADER_CODE
    je .free_it
    cmp eax, MT_LOADER_DATA
    jne .free_next
.free_it:
    mov rax, [rsi + 8]
    mov rcx, [rsi + 24]
    call pmm_mark_free
.free_next:
    add rsi, r14
    jmp .free
.free_done:

    mov rbx, [boot_info]                ; keep what the loader handed us
    lea rsi, [rbx + BI_RESV]
    mov r15, [rbx + BI_RESV_COUNT]
.reserved:
    test r15, r15
    jz .reserved_done
    mov rax, [rsi]
    mov rcx, [rsi + 8]
    add rcx, 0xFFF
    shr rcx, 12
    call pmm_mark_used
    add rsi, 16
    dec r15
    jmp .reserved
.reserved_done:
    mov rax, [pmm_bitmap_phys]
    mov rcx, [pmm_bitmap_pages]
    call pmm_mark_used
    call pmm_count_free
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pmm_release_boot_services: firmware boot-services memory becomes ours
pmm_release_boot_services:
    push r12
    push r13
    push r14
    call mmap_setup
    mov rsi, r12
.next:
    cmp rsi, r13
    jae .done
    mov eax, [rsi]
    cmp eax, MT_BS_CODE
    je .free
    cmp eax, MT_BS_DATA
    jne .skip
.free:
    mov rax, [rsi + 8]
    mov rcx, [rsi + 24]
    call pmm_mark_free
.skip:
    add rsi, r14
    jmp .next
.done:
    call pmm_count_free
    pop r14
    pop r13
    pop r12
    ret

; pmm_mark_free(RAX phys, RCX pages) / pmm_mark_used(RAX phys, RCX pages)
pmm_mark_free:
    push rax
    push rcx
    push rdx
    shr rax, 12
    cmp rax, LOW_PAGES                  ; never free low memory
    jae .clip_top
    mov rdx, LOW_PAGES
    sub rdx, rax
    cmp rcx, rdx
    jbe .nothing
    sub rcx, rdx
    mov rax, LOW_PAGES
.clip_top:
    xor edx, edx
    call bitmap_range
.nothing:
    pop rdx
    pop rcx
    pop rax
    ret

pmm_mark_used:
    push rax
    push rcx
    push rdx
    shr rax, 12
    mov edx, 1
    call bitmap_range
    pop rdx
    pop rcx
    pop rax
    ret

; bitmap_range(RAX first page, RCX count, DL value). Clips to pmm_pages.
bitmap_range:
    push rax
    push rcx
    push rsi
    push rdi
    cmp rax, [pmm_pages]
    jae .done
    mov rsi, [pmm_pages]
    sub rsi, rax
    cmp rcx, rsi
    cmova rcx, rsi
    mov rdi, [pmm_bitmap]
.head:
    test rcx, rcx
    jz .done
    test eax, 63
    jz .body
    call .one
    inc rax
    dec rcx
    jmp .head
.body:
    cmp rcx, 64
    jb .tail
    mov rsi, rax
    shr rsi, 6
    mov qword [rdi + rsi * 8], 0
    test dl, dl
    jz .body_next
    mov qword [rdi + rsi * 8], -1
.body_next:
    add rax, 64
    sub rcx, 64
    jmp .body
.tail:
    test rcx, rcx
    jz .done
    call .one
    inc rax
    dec rcx
    jmp .tail
.one:
    test dl, dl
    jz .clear
    bts [rdi], rax
    ret
.clear:
    btr [rdi], rax
    ret
.done:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

pmm_count_free:
    push rax
    push rcx
    push rdx
    push rsi
    mov rsi, [pmm_bitmap]
    mov rcx, [pmm_qwords]
    xor edx, edx
.next:
    mov rax, [rsi]
    not rax
    popcnt rax, rax
    add rdx, rax
    add rsi, 8
    dec rcx
    jnz .next
    mov [pmm_free_pages], rdx
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  pmm_alloc(RDI = pages) -> RAX = physical address, 0 if none. Preserves others.
;  Pages are not zeroed.
; -----------------------------------------------------------------------------
pmm_alloc:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    pushfq
    cli
    push rdi
    lea rdi, [pmm_lock]
    call spin_lock
    pop rdi
    mov rsi, [pmm_bitmap]
    cmp rdi, 1
    jne .multi

    mov rcx, [pmm_hint]                 ; single page: first qword with a hole
    mov rdx, [pmm_qwords]
    xor r8d, r8d                        ; wrapped once?
.scan:
    cmp rcx, rdx
    jae .wrap
    mov rax, [rsi + rcx * 8]
    not rax
    test rax, rax
    jnz .found
    inc rcx
    jmp .scan
.wrap:
    test r8d, r8d
    jnz .fail
    inc r8d
    mov ecx, LOW_PAGES / 64
    jmp .scan
.found:
    bsf rax, rax
    mov rbx, rcx
    shl rbx, 6
    add rbx, rax
    cmp rbx, [pmm_pages]
    jae .fail
    bts [rsi], rbx
    mov [pmm_hint], rcx
    dec qword [pmm_free_pages]
    mov rax, rbx
    shl rax, 12
    jmp .unlock

.multi:                                 ; first fit for a run of RDI pages
    mov rbx, LOW_PAGES                  ; candidate page
    xor ecx, ecx                        ; run length
    xor r8d, r8d                        ; run start
.multi_next:
    cmp rbx, [pmm_pages]
    jae .fail
    test ebx, 63
    jnz .multi_bit
    mov rax, rbx
    shr rax, 6
    cmp qword [rsi + rax * 8], -1
    jne .multi_bit
    add rbx, 64                         ; whole qword in use
    xor ecx, ecx
    jmp .multi_next
.multi_bit:
    bt [rsi], rbx
    jc .multi_used
    test rcx, rcx
    jnz .multi_grow
    mov r8, rbx
.multi_grow:
    inc rcx
    inc rbx
    cmp rcx, rdi
    jb .multi_next
    mov rax, r8                         ; claim [r8, r8 + rdi)
    mov rcx, rdi
    mov edx, 1
    call bitmap_range
    sub [pmm_free_pages], rdi
    mov rax, r8
    shl rax, 12
    jmp .unlock
.multi_used:
    xor ecx, ecx
    inc rbx
    jmp .multi_next

.fail:
    xor eax, eax
.unlock:
    lea rdi, [pmm_lock]
    call spin_unlock
    popfq
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; pmm_alloc_zero(RDI = pages) -> RAX = physical address of zeroed pages (or 0)
pmm_alloc_zero:
    call pmm_alloc
    test rax, rax
    jz .out
    push rax
    push rcx
    push rdi
    mov rcx, rdi
    shl rcx, 9
    mov rdi, rax
    add rdi, [phys_base]
    xor eax, eax
    rep stosq
    pop rdi
    pop rcx
    pop rax
.out:
    ret

; pmm_free(RDI = physical address, RSI = pages). Panics if one of them is
; not in use: freed twice, or never ours. Preserves all.
pmm_free:
    push rax
    push rcx
    push rdx
    push rdi
    pushfq
    cli
    lea rdi, [pmm_lock]
    call spin_lock
    mov rax, [rsp + 8]
    shr rax, 12                         ; first page
    mov rcx, rsi
    mov rdx, [pmm_bitmap]
.page:
    test rcx, rcx
    jz .freed
    cmp rax, LOW_PAGES
    jb .bad
    cmp rax, [pmm_pages]
    jae .bad
    btr [rdx], rax
    jnc .bad
    inc qword [pmm_free_pages]
    inc rax
    dec rcx
    jmp .page
.freed:
    lea rdi, [pmm_lock]
    call spin_unlock
    popfq
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret
.bad:
    mov dword [pmm_lock], 0
    mov rdi, rax
    shl rdi, 12
    lea rsi, [str_pmm_bad]
    jmp mem_bad

section .rodata
str_pmm_nohome: db 'No conventional memory region can hold the page bitmap', 0
str_pmm_bad:    db 'pmm_free: a page that was not in use', 0

section .data
align 8
pmm_hint:       dq LOW_PAGES / 64
pmm_lock:       dd 0

section .bss
alignb 8
pmm_bitmap:     resq 1
pmm_bitmap_phys: resq 1
pmm_bitmap_pages: resq 1
pmm_pages:      resq 1
pmm_qwords:     resq 1
pmm_top:        resq 1
pmm_usable_bytes: resq 1
pmm_free_pages: resq 1
mem_by_type:    resq 16
