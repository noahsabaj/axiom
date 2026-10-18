; =============================================================================
;  log.asm - the boot log, kept whole in memory and saved as AXIOM.LOG on the
;  stick Axiom booted from, so a test on real hardware leaves a record.
;
;  The stick is the removable FAT32 volume whose serial number the loader read
;  from the volume it was loaded from. No other volume is ever written: not
;  the NVMe drive, not another stick. Saved after boot, every ten seconds
;  while the log grows, before reboot and power-off, and after a panic.
; =============================================================================

LOG_MAX         equ 1024 * 1024
LOG_ROOM        equ 64                  ; kept for the note that it is full
LOG_EVERY_MS    equ 10000

section .text

; log_init: what the loader saw. Before the first KLOG that matters.
log_init:
    mov rax, [boot_info]
    mov ecx, [rax + BI_BOOT_SERIAL]
    mov [log_serial], ecx
    mov ecx, [rax + BI_BOOT_FS]
    mov [log_fs], ecx
    mov byte [log_auto], 1
    cmp dword [log_fs], 0
    je .unknown
    mov ecx, [log_serial]
    mov edx, ecx
    shr ecx, 16
    and edx, 0xFFFF
    mov eax, [log_fs]
    KLOG "boot volume: FAT%u, serial %04x-%04x", rax, rcx, rdx
    ret
.unknown:
    KLOG "boot volume: not a FAT volume Axiom recognizes; no AXIOM.LOG"
    ret

; log_append(RDI string): into the log. The caller holds print_lock.
; Preserves all.
log_append:
    push rax
    push rcx
    push rsi
    push rdi
    cmp byte [log_full], 0
    jne .out
    mov rsi, rdi
    mov rcx, [log_len]
    lea rdi, [log_buf]
.copy:
    mov al, [rsi]
    test al, al
    jz .done
    cmp rcx, LOG_MAX - LOG_ROOM
    jae .full
    mov [rdi + rcx], al
    inc rcx
    inc rsi
    jmp .copy
.full:
    lea rsi, [str_log_full]
.note:
    mov al, [rsi]
    test al, al
    jz .noted
    mov [rdi + rcx], al
    inc rcx
    inc rsi
    jmp .note
.noted:
    mov byte [log_full], 1
.done:
    mov [log_len], rcx
.out:
    pop rdi
    pop rsi
    pop rcx
    pop rax
    ret

; log_command(RDI line): a shell command line, into the log only. Preserves all.
log_command:
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [print_lock]
    call spin_lock
    lea rdi, [str_prompt]
    call log_append
    pop rdi
    call log_append
    lea rdi, [str_newline]
    call log_append
    lea rdi, [print_lock]
    call spin_unlock
    popfq
    pop rdi
    ret

; log_volume -> R14 = the boot stick's volume, CF if it is not here (yet).
; Removable, FAT32, mounted, and the serial the loader read; two such
; volumes and neither is used. Preserves all but RAX.
log_volume:
    push rcx
    push rdx
    push r8
    xor r8d, r8d
    cmp dword [log_fs], 32
    jne .none
    mov edx, [log_serial]
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
    cmp byte [r14 + VF_MOUNTED], 0
    je .next
    mov rax, [r14 + VO_DISK]
    test dword [rax + DK_FLAGS], DKF_REMOVABLE
    jz .next
    cmp [r14 + VF_SERIAL], edx
    jne .next
    test r8, r8
    jnz .none                           ; which one? neither
    mov r8, r14
    jmp .next
.end:
    mov r14, r8
    test r8, r8
    jz .none
    clc
    jmp .out
.none:
    stc
.out:
    pop r8
    pop rdx
    pop rcx
    ret

; log_save -> CF if not saved: the log, as it is now, to /AXIOM.LOG on the
; boot stick. The volume needs no 'vol <n> rw' for this one file; its own
; setting is put back afterwards. Preserves all but RAX.
log_save:
    push rbx
    push rcx
    push rsi
    push rdi
    push r14
    cmp byte [log_busy], 0
    jne .fail
    call log_volume
    jc .fail
    mov byte [log_busy], 1
    mov byte [fat_writing], 0
    cmp byte [log_found], 0
    jne .write
    mov byte [log_found], 1
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "log: kept in vol%u:/AXIOM.LOG ('log off' stops that)", rax
.write:
    mov rcx, [log_len]
    mov [log_saving], rcx
    mov bl, [r14 + VO_WRITABLE]
    mov byte [r14 + VO_WRITABLE], 1
    lea rsi, [str_log_name]
    lea rdi, [log_buf]
    call fat_write_file
    mov [r14 + VO_WRITABLE], bl
    mov byte [log_busy], 0
    jc .fail
    mov rcx, [log_saving]
    mov [log_saved], rcx
    clc
    jmp .out
.fail:
    stc
.out:
    pop r14
    pop rdi
    pop rsi
    pop rcx
    pop rbx
    ret

; log_service: from the main loop. Saves every ten seconds while the log
; grows; a failure stops the automatic saves ('log save' tries again).
log_service:
    cmp byte [log_auto], 0
    je .out
    RDTSC64
    cmp rax, [log_next]
    jb .out
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, LOG_EVERY_MS
    add rax, rcx
    mov [log_next], rax
    mov rax, [log_len]
    cmp rax, [log_saved]
    je .out
    call log_volume
    jc .out                             ; the stick may still be coming up
    call log_save
    jnc .out
    mov byte [log_auto], 0
    KLOG "log: AXIOM.LOG could not be saved; 'log save' tries again"
.out:
    ret

; log_final: before a reboot or power-off (the settings kept too).
; Preserves all.
log_final:
    call cfg_final
    push rax
    cmp byte [log_auto], 0
    je .out
    mov rax, [log_len]
    cmp rax, [log_saved]
    je .out
    call log_save
.out:
    pop rax
    ret

; log_panic(RDI report): after a panic, with every other CPU stopped and
; interrupts off. Saved unless the crash came in the middle of a write to a
; volume, when the FAT code's state can't be trusted.
log_panic:
    call log_append
    cmp byte [log_auto], 0
    je .out
    cmp byte [log_busy], 0
    jne .out
    cmp byte [fat_writing], 0
    jne .out
    call log_save
.out:
    ret

; log [save|on|off]
cmd_log:
    push r14
    mov rsi, [sh_args]
    cmp byte [rsi], 0
    je .status
    lea rdi, [str_arg_save]
    call streq
    test eax, eax
    jnz .save
    lea rdi, [str_arg_on]
    call streq
    test eax, eax
    jnz .on
    lea rdi, [str_arg_off]
    call streq
    test eax, eax
    jnz .off
    KLOG "usage: log [save|on|off]"
    jmp .done
.on:
    mov byte [log_auto], 1
    KLOG "log: saved to the boot stick every 10 s while it grows"
    jmp .done
.off:
    mov byte [log_auto], 0
    KLOG "log: no longer saved by itself ('log save' still saves it)"
    jmp .done
.save:
    call log_volume
    jc .absent
    call log_save
    jc .failed
    movzx eax, byte [r14 + VO_INDEX]
    KLOG "log: %b saved to vol%u:/AXIOM.LOG", qword [log_saved], rax
    jmp .done
.failed:
    KLOG "log: AXIOM.LOG could not be saved"
    jmp .done
.status:
    lea rcx, [str_on]
    lea rdx, [str_off]
    cmp byte [log_auto], 0
    cmove rcx, rdx
    KLOG "log: %b in memory, %b saved; automatic saving %s", qword [log_len], qword [log_saved], rcx
    cmp dword [log_fs], 0
    je .unknown
    call log_volume
    jc .absent
    movzx eax, byte [r14 + VO_INDEX]
    mov ecx, [log_serial]
    mov edx, ecx
    shr ecx, 16
    and edx, 0xFFFF
    KLOG "log: the boot stick is vol%u (serial %04x-%04x)", rax, rcx, rdx
    jmp .done
.absent:
    cmp dword [log_fs], 0
    je .unknown
    mov ecx, [log_serial]
    mov edx, ecx
    shr ecx, 16
    and edx, 0xFFFF
    KLOG "log: no one USB stick Axiom has mounted has the boot volume's serial (%04x-%04x)", rcx, rdx
    jmp .done
.unknown:
    KLOG "log: the firmware did not say which FAT32 volume Axiom came from"
.done:
    pop r14
    ret

section .rodata
str_log_name:   db '/AXIOM.LOG', 0
str_on:         db 'on', 0
str_log_full:   db 10, '[the log is full; later lines are not kept]', 10, 0
str_newline:    db 10, 0
str_arg_save:   db 'save', 0
str_arg_on:     db 'on', 0
str_arg_off:    db 'off', 0

section .data
log_auto:       db 0
log_busy:       db 0
log_full:       db 0
log_found:      db 0

section .bss
alignb 8
log_len:        resq 1
log_saved:      resq 1
log_saving:     resq 1
log_next:       resq 1
log_serial:     resd 1
log_fs:         resd 1
log_buf:        resb LOG_MAX
