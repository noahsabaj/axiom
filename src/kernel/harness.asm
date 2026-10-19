; =============================================================================
;  harness.asm - test runs on a real machine with no one at it (hp-1).
;
;  tools/hw/hp1.py, on the machine's other system, writes a script into the
;  UEFI variable AxiomRun and boots Axiom once (BootNext). The loader reads
;  the script, deletes the variable and starts the chipset's TCO watchdog
;  (uefi.asm). Here the script's lines are typed into the first terminal,
;  each once the one before is done. When the script ends, or its time is
;  up, or after a panic, the end of the log goes into the UEFI variable
;  AxiomLog and the machine restarts, into the other system, which reads it.
;
;  A line is a shell line, or one of these:
;    # ...           a comment
;    sleep <s>       wait that long
;    until <text>    wait for the text in the log after the last line typed,
;                    'timeout' seconds at most (60 unless said)
;    timeout <s>     how long an 'until' waits
;    limit <s>       the run ends that long from now (300 s from boot unless
;                    said)
;    watchdog <s>    the reset that long after Axiom stops (2 minutes unless
;                    said)
;    end             the run ends here
;
;  Should Axiom stop: the timer interrupt reloads the watchdog only while
;  the run is within its limit and half a minute more; past that it
;  panics, and the panic saves the log. A hang with interrupts off is the
;  watchdog's to end.
; =============================================================================

HARNESS_LIMIT   equ 300                 ; seconds, unless 'limit' says
HARNESS_GRACE   equ 30                  ; past the limit, before the panic
HARNESS_UNTIL   equ 60                  ; an 'until', unless 'timeout' says
HARNESS_KEEP    equ 32768               ; the least left free in the variable store
HARNESS_BUF     equ 32768

section .text

; harness_init: early in boot. A test run, if the loader found one.
harness_init:
    push rbx
    mov rbx, [boot_info]
    cmp dword [rbx + BI_RUN_SIZE], 0
    je .out
    mov byte [harness_on], 1
    mov ax, [rbx + BI_TCO]
    mov [tco_base], ax
    RDTSC64
    mov [harness_t0], rax
    mov edi, HARNESS_LIMIT
    call harness_limit
    mov qword [harness_timeout], HARNESS_UNTIL
    call tco_pet
    mov ecx, [rbx + BI_RUN_SIZE]
    mov rsi, [rbx + BI_RUN]
    test rsi, rsi
    jz .unread
    cmp ecx, RUN_MAX - 1
    ja .unread
    add rsi, [phys_base]
    lea rdi, [harness_script]
    mov [harness_len], rcx
    rep movsb
    mov byte [rdi], 0
    KLOG "harness: a test run, %u bytes of script from the UEFI variable AxiomRun", qword [harness_len]
    jmp .reset
.unread:
    KLOG "harness: a test run, but its script (%u bytes) could not be read, or is over 8 KiB", rcx
.reset:
    test word [rbx + BI_TCO_STS], 2     ; SECOND_TO_STS, as the loader found it
    jz .tco
    KLOG "harness: the watchdog has reset this machine since the last run"
.tco:
    movzx eax, word [tco_base]
    test eax, eax
    jz .no_tco
    KLOG "harness: the TCO watchdog (I/O %x) resets the machine 2 minutes after Axiom stops", rax
    jmp .out
.no_tco:
    test word [rbx + BI_TCO_STS], 0x8000
    jnz .locked
    KLOG "harness: no watchdog Axiom can start here; a hang stays hung"
    jmp .out
.locked:
    KLOG "harness: the watchdog's NO_REBOOT is locked on; a hang stays hung"
.out:
    pop rbx
    ret

; harness_limit(EDI = seconds): the run ends that long from now. Preserves
; all.
harness_limit:
    push rax
    push rcx
    push rdx
    RDTSC64
    mov rcx, rax
    mov eax, edi
    imul rax, rax, 1000
    imul rax, [tsc_per_ms]
    add rax, rcx
    mov [harness_deadline], rax
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, HARNESS_GRACE * 1000
    add rax, rcx
    mov [harness_stuck_at], rax
    pop rdx
    pop rcx
    pop rax
    ret

; tco_pet: the watchdog's count starts again. Preserves all.
tco_pet:
    push rax
    push rdx
    movzx edx, word [tco_base]
    test edx, edx
    jz .out
    mov eax, 1
    out dx, ax                          ; TCO_RLD
.out:
    pop rdx
    pop rax
    ret

; tco_set(EDI = seconds): the reset that long after the last reload: ticks
; of 0.6 s, counted twice. Preserves all.
tco_set:
    push rax
    push rcx
    push rdx
    movzx ecx, word [tco_base]
    test ecx, ecx
    jz .out
    mov eax, edi
    imul eax, eax, 10
    xor edx, edx
    push rcx
    mov ecx, 12
    div ecx
    pop rcx
    cmp eax, 4                          ; what the chipset takes
    jae .low
    mov eax, 4
.low:
    cmp eax, 1023
    jbe .high
    mov eax, 1023
.high:
    push rax
    lea edx, [ecx + 0x12]               ; TCO_TMR
    in ax, dx
    and eax, 0xFC00
    or eax, [rsp]
    out dx, ax
    pop rax
    mov edx, ecx
    mov eax, 1
    out dx, ax                          ; and counted from it
.out:
    pop rdx
    pop rcx
    pop rax
    ret

; harness_tick: from the timer interrupt, on any CPU. The watchdog reloaded
; once a second while the run is within its limit and the grace after it;
; past that the main loop has not ended the run, so it panics, and the
; panic saves the log. Preserves all.
harness_tick:
    push rax
    push rcx
    push rdx
    RDTSC64
    cmp rax, [harness_pet_at]
    jb .out
    cmp rax, [harness_stuck_at]
    jae .stuck
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 1000
    add rcx, rax
    mov [harness_pet_at], rcx
    call tco_pet
.out:
    pop rdx
    pop rcx
    pop rax
    ret
.stuck:
    xor edi, edi
    lea rsi, [str_harness_stuck]
    jmp panic

; harness_service: from the main loop. The script's next line, once the
; first terminal is ready for it and no wait holds it back.
harness_service:
    cmp byte [harness_on], 0
    jne .on
    ret
.on:
    push rbx
    push r12
    mov byte [harness_ready], 0
.again:
    RDTSC64
    mov r12, rax
    cmp r12, [harness_deadline]
    jae .time_up
    cmp r12, [harness_wake]
    jb .out
    cmp byte [harness_until], 0
    je .ready
    call harness_seen
    jc .seen
    cmp r12, [harness_until_end]
    jb .out
    lea rax, [harness_until]
    KLOG "harness: no '%s' in %u s", rax, qword [harness_timeout]
.seen:
    mov byte [harness_until], 0
.ready:
    mov rbx, [term_list]                ; the first terminal: the last in the list
    test rbx, rbx
    jz .out
.first:
    mov rax, [rbx + TW_NEXT]
    test rax, rax
    jz .found
    mov rbx, rax
    jmp .first
.found:
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out                            ; its command runs on
    call harness_next
    jc .over
    lea rsi, [harness_line]
    call harness_directive
    jnc .again
    mov r11, rbx
    lea rax, [harness_type]
    call con_call
    mov byte [harness_ready], 1         ; (the main loop comes back at once)
.out:
    pop r12
    pop rbx
    ret
.time_up:
    KLOG "harness: the run's time is up"
.over:
    jmp harness_end

; harness_end: the run is over: its log saved, and the machine restarted.
; Never returns.
harness_end:
    call uptime_ms
    xor edx, edx
    mov ecx, 10
    div rcx
    KLOG "harness: the run is over, %h s after power-on; the machine restarts", rax
    call harness_save
    call log_final
    jmp power_reboot

; harness_crashed: in a test run, after a panic's report: the log saved,
; and the machine restarted. Never returns.
harness_crashed:
    call harness_save
    jmp power_reboot

; harness_next -> harness_line = the script's next line, its blanks at either
; end gone; CF at the end of the script
harness_next:
    push rcx
    push rsi
    push rdi
    mov rsi, [harness_pos]
    cmp rsi, [harness_len]
    jae .end
    lea rax, [harness_script]
    add rsi, rax
    lea rdi, [harness_line]
    xor ecx, ecx
.lead:
    cmp byte [rsi], ' '
    je .blank
    cmp byte [rsi], 9
    jne .copy
.blank:
    inc rsi
    jmp .lead
.copy:
    lodsb
    test al, al
    jz .nul
    cmp al, 10
    je .trim
    cmp al, 13
    je .copy
    cmp ecx, LINE_MAX
    jae .copy                           ; (the rest of a long line is lost)
    mov [rdi + rcx], al
    inc ecx
    jmp .copy
.nul:
    lea rsi, [harness_script]           ; a NUL ends the script
    add rsi, [harness_len]
.trim:
    test ecx, ecx
    jz .cut
    cmp byte [rdi + rcx - 1], ' '
    je .less
    cmp byte [rdi + rcx - 1], 9
    jne .cut
.less:
    dec ecx
    jmp .trim
.cut:
    mov byte [rdi + rcx], 0
    lea rax, [harness_script]
    sub rsi, rax
    mov [harness_pos], rsi
    clc
    jmp .out
.end:
    stc
.out:
    pop rdi
    pop rsi
    pop rcx
    ret

; harness_word(RBX = line, RDI = word) -> CF clear and RSI = what follows the
; word and its blanks, if the line is that word, alone or before a blank.
; Preserves others but RAX.
harness_word:
    push rdi
    mov rsi, rbx
.cmp:
    mov al, [rdi]
    test al, al
    jz .ended
    cmp al, [rsi]
    jne .no
    inc rdi
    inc rsi
    jmp .cmp
.ended:
    mov al, [rsi]
    test al, al
    jz .yes
    cmp al, ' '
    jne .no
.blanks:
    cmp byte [rsi], ' '
    jne .yes
    inc rsi
    jmp .blanks
.yes:
    clc
    jmp .out
.no:
    stc
.out:
    pop rdi
    ret

; harness_directive(RSI = line) -> CF if it is a shell line; otherwise it
; was the harness's own, and is done
harness_directive:
    push rbx
    mov rbx, rsi
    cmp byte [rbx], 0
    je .done                            ; a blank line
    cmp byte [rbx], '#'
    je .done
    lea rdi, [str_hs_sleep]
    call harness_word
    jnc .sleep
    lea rdi, [str_hs_until]
    call harness_word
    jnc .until
    lea rdi, [str_hs_timeout]
    call harness_word
    jnc .timeout
    lea rdi, [str_hs_limit]
    call harness_word
    jnc .limit
    lea rdi, [str_hs_watchdog]
    call harness_word
    jnc .watchdog
    lea rdi, [str_hs_end]
    call harness_word
    jnc .end
    stc                                 ; a shell line
    jmp .out
.sleep:
    call arg_uint
    jc .bad
    KLOG "harness: sleep %u s", rax
    imul rax, rax, 1000
    imul rax, [tsc_per_ms]
    mov rcx, rax
    RDTSC64
    add rax, rcx
    mov [harness_wake], rax
    jmp .done
.until:
    cmp byte [rsi], 0                   ; (not logged: it would be found)
    je .bad
    lea rdi, [harness_until]
    mov ecx, LINE_MAX
.copy:
    lodsb
    stosb
    test al, al
    jz .copied
    dec ecx
    jnz .copy
    mov byte [rdi], 0
.copied:
    mov rax, [harness_timeout]
    imul rax, rax, 1000
    imul rax, [tsc_per_ms]
    mov rcx, rax
    RDTSC64
    add rax, rcx
    mov [harness_until_end], rax
    jmp .done
.timeout:
    call arg_uint
    jc .bad
    mov [harness_timeout], rax
    KLOG "harness: timeout %u s", rax
    jmp .done
.limit:
    call arg_uint
    jc .bad
    mov edi, eax
    call harness_limit
    KLOG "harness: limit %u s", rax
    jmp .done
.watchdog:
    call arg_uint
    jc .bad
    mov edi, eax
    call tco_set
    KLOG "harness: watchdog %u s", rax
    jmp .done
.end:
    KLOG "harness: end"
    jmp harness_end
.bad:
    KLOG "harness: '%s'? Skipped", rbx
.done:
    clc
.out:
    pop rbx
    ret

; harness_seen -> CF if harness_until is in the log after harness_mark; if
; not, the mark moves on past where it could have begun
harness_seen:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    lea rdi, [harness_until]
    call strlen
    mov rdx, rax                        ; its length
    mov rcx, [log_len]
    sub rcx, rdx                        ; the last place it could begin
    jb .no
    mov rbx, [harness_mark]
.next:
    cmp rbx, rcx
    ja .moved
    lea rsi, [log_buf]
    add rsi, rbx
    lea rdi, [harness_until]
    push rcx
    mov rcx, rdx
    repe cmpsb
    pop rcx
    je .yes
    inc rbx
    jmp .next
.moved:
    mov [harness_mark], rbx
.no:
    clc
    jmp .out
.yes:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; harness_type (RBX = the terminal; in its context): harness_line, as if
; typed there and entered (shell_key's enter)
harness_type:
    lea rsi, [harness_line]
.echo:
    lodsb
    test al, al
    jz .echoed
    call sh_echo
    jmp .echo
.echoed:
    mov al, 10
    call sh_echo
    lea rdi, [sh_line]
    lea rsi, [harness_line]
    mov ecx, LINE_MAX + 1
    rep movsb
    lea rdi, [sh_line]
    call sh_secret
    lea rdi, [sh_line]
    jnc .log
    lea rdi, [str_sh_secret]
.log:
    call log_command
    mov rax, [log_len]
    mov [harness_mark], rax             ; what it says, from here on
    mov dword [rbx + TW_SH_LEN], 0
    call shell_exec
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out
    call shell_prompt
.out:
    ret

; harness_save: as much of the end of the log as the firmware's variable
; store has room for, into the UEFI variable AxiomLog (tools/hw/hp1.py
; reads and deletes it). Room is left over: a store that fills up can keep
; a machine from starting. From the main loop, or after a panic.
harness_save:
    push rbx
    push r12
    push r13
    call efi_var_room                   ; RAX all, RCX free, RDX one at most
    jc .unknown
    mov r12, rax
    mov r13, rcx
    shr rax, 2                          ; left free: a quarter of it, 32 KiB at least
    cmp rax, HARNESS_KEEP
    jae .keep
    mov eax, HARNESS_KEEP
.keep:
    lea rsi, [harness_sizes]
.size:
    mov rbx, [rsi]
    test rbx, rbx
    jz .no_room
    add rsi, 8
    lea r8, [rbx + 512]                 ; with its name, and the store's header
    cmp r8, rdx
    ja .size                            ; more than one variable may hold
    add r8, rax
    cmp r8, rcx
    ja .size
    KLOG "harness: the end of the log, %b at most, goes into AxiomLog (the variable store has %b of %b free)", rbx, r13, r12
    jmp .write
.unknown:
    mov ebx, 2048
    KLOG "harness: the end of the log, %b at most, goes into AxiomLog (the firmware does not say how much room there is)", rbx
.write:
    mov rcx, [log_len]
    cmp rbx, rcx
    cmova rbx, rcx
    lea rdi, [log_buf]
    add rdi, rcx
    sub rdi, rbx
    mov ecx, ebx
    lea rsi, [name_axiom_log]
    lea rdx, [axiom_guid]
    call efi_set_variable
    jnc .out
    KLOG "harness: AxiomLog was not saved (EFI status %x)", rax
    jmp .out
.no_room:
    KLOG "harness: no room for the log in the variable store (%b of %b free)", r13, r12
.out:
    pop r13
    pop r12
    pop rbx
    ret

; harness: this boot's test run, and the UEFI variables for the next
harness_show:
    cmp byte [harness_on], 0
    je .none
    KLOG "harness: a test run, %u of its %u bytes of script done", qword [harness_pos], qword [harness_len]
    jmp .vars
.none:
    KLOG "harness: no test run this boot"
.vars:
    lea rsi, [name_axiom_run]
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, HARNESS_BUF
    call efi_get_variable
    jc .no_run
    KLOG "harness: the next boot runs %b of script (AxiomRun)", rax
.no_run:
    lea rsi, [name_axiom_log]
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, HARNESS_BUF
    call efi_get_variable
    jc .no_log
    KLOG "harness: the last run left %b of its log (AxiomLog; 'harness log' shows it)", rax
.no_log:
    call efi_var_room
    jc .out
    KLOG "harness: the variable store has %b of %b free; one variable holds %b at most", rcx, rax, rdx
.out:
    clc
    ret

; harness queue <line>...: the words, a blank apart, a line more of AxiomRun
harness_queue:
    test edi, edi
    jz .usage
    push rbx
    push r12
    push r13
    mov r12d, edi
    mov r13, rsi
    lea rsi, [name_axiom_run]           ; what it holds already
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, RUN_MAX
    call efi_get_variable
    jnc .have
    xor eax, eax
.have:
    mov rbx, rax
    lea rdi, [harness_buf]
    add rdi, rbx
.word:
    mov rsi, [r13]
    add r13, 8
.char:
    lodsb
    test al, al
    jz .word_end
    cmp rbx, RUN_MAX - 2
    jae .full
    stosb
    inc rbx
    jmp .char
.word_end:
    dec r12d
    jz .line_end
    cmp rbx, RUN_MAX - 2
    jae .full
    mov al, ' '
    stosb
    inc rbx
    jmp .word
.line_end:
    mov al, 10
    stosb
    inc rbx
    lea rsi, [name_axiom_run]
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, ebx
    call efi_set_variable
    jc .failed
    KLOG "harness: the next boot runs %b of script", rbx
    clc
    jmp .out
.full:
    KLOG "harness: a test run's script holds 8 KiB at most"
    stc
    jmp .out
.failed:
    KLOG "harness: AxiomRun was not written (EFI status %x)", rax
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret
.usage:
    KLOG "usage: harness queue <line>"
    stc
    ret

; harness log: what the last run left in AxiomLog, line by line
harness_log:
    lea rsi, [name_axiom_log]
    lea rdx, [axiom_guid]
    lea rdi, [harness_buf]
    mov ecx, HARNESS_BUF
    call efi_get_variable
    jc .none
    KLOG "harness: the last run's log, its last %b:", rax
    lea rsi, [harness_buf]
    lea rdx, [rsi + rax]                ; its end
.line:
    cmp rsi, rdx
    jae .done
    lea rdi, [harness_line]
    xor ecx, ecx
.char:
    cmp rsi, rdx
    jae .put
    lodsb
    cmp al, 10
    je .put
    cmp al, 13
    je .char
    mov [rdi + rcx], al
    inc ecx
    cmp ecx, 900
    jb .char
.put:
    mov byte [rdi + rcx], 0
    KLOG "%s", rdi
    jmp .line
.done:
    KLOG "harness: (the end of the last run's log)"
    clc
    ret
.none:
    KLOG "harness: no AxiomLog: no test run has ended since it was last deleted"
    clc
    ret

; harness clear: AxiomRun and AxiomLog deleted
harness_clear:
    lea rsi, [name_axiom_run]
    lea rdx, [axiom_guid]
    xor ecx, ecx
    call efi_set_variable
    lea rsi, [name_axiom_log]
    call efi_set_variable
    KLOG "harness: AxiomRun and AxiomLog are gone"
    clc
    ret

; harness hang: in a test run, the watchdog's test: no more reloads, and
; this CPU stops with interrupts off
harness_hang:
    cmp byte [harness_on], 0
    je .not
    mov rax, -1
    mov [harness_pet_at], rax           ; no one reloads it now,
    mov [harness_stuck_at], rax         ; and no one panics
    KLOG "harness: stopping here, interrupts off, for the watchdog to end"
    cli
.stop:
    hlt
    jmp .stop
.not:
    KLOG "harness hang: only in a test run, where the watchdog ends it"
    stc
    ret

section .data
align 8
harness_actions:
    ACTION  '',      harness_show,  '', "this boot's test run; AxiomRun and AxiomLog, the UEFI variables for them", 0
    ACTION  'queue', harness_queue, '<line>...', 'a line for the test run the next boot makes (AxiomRun)', 0
    ACTION  'log',   harness_log,   '', 'what the last test run left of its log (AxiomLog)', 0
    ACTION  'clear', harness_clear, '', 'AxiomRun and AxiomLog deleted', 0
    ACTION  'hang',  harness_hang,  '', "in a test run: stopped, interrupts off, for the watchdog's reset", 0
    dq 0, 0, 0, 0, 0

section .rodata
str_hs_sleep:       db 'sleep', 0
str_hs_until:       db 'until', 0
str_hs_timeout:     db 'timeout', 0
str_hs_limit:       db 'limit', 0
str_hs_watchdog:    db 'watchdog', 0
str_hs_end:         db 'end', 0
str_harness_stuck:  db 'harness: the run is past its time limit, and the main loop has not ended it', 0
align 2                                 ; (UTF-16: the firmware insists)
name_axiom_run:     dw __utf16__('AxiomRun'), 0
name_axiom_log:     dw __utf16__('AxiomLog'), 0
align 8
axiom_guid:         AXIOM_VENDOR_GUID
harness_sizes:      dq 24576, 8192, 2048, 0     ; AxiomLog's, the first that fits

section .bss
harness_on:         resb 1              ; a test run, this boot
harness_ready:      resb 1              ; a line typed: the main loop comes back
alignb 8
harness_t0:         resq 1              ; TSCs: when it began,
harness_deadline:   resq 1              ; when it ends,
harness_stuck_at:   resq 1              ; when the timer panics,
harness_pet_at:     resq 1              ; the watchdog's next reload,
harness_wake:       resq 1              ; the end of a 'sleep',
harness_until_end:  resq 1              ; and of an 'until'
harness_timeout:    resq 1              ; seconds, for an 'until'
harness_mark:       resq 1              ; log_len when the last line was typed
harness_pos:        resq 1              ; the script's next line,
harness_len:        resq 1              ; and its bytes
tco_base:           resw 1              ; the watchdog's I/O, 0 if none
harness_script:     resb RUN_MAX
harness_line:       resb LINE_MAX + 8
harness_until:      resb LINE_MAX + 8   ; the text an 'until' waits for, or ''
harness_buf:        resb HARNESS_BUF
