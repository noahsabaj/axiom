; =============================================================================
;  update.asm - a new kernel tried once, then kept or given up on its own:
;  how a machine no one is at (hp-1, as axiom-1) takes a new Axiom.
;
;  Besides the kernel built into the loader, two files on the volume Axiom
;  started from may hold one: /EFI/AXIOM/KERNEL.A and KERNEL.B, the slots.
;  'update try <file>' copies a kernel.bin into the slot not kept and names
;  it in the UEFI variable AxiomTry: the next start is its trial. The
;  loader (uefi.asm) marks the variable tried before it starts that kernel,
;  so a trial happens once, and starts the chipset's TCO watchdog. On
;  trial, 'update keep' makes it the kernel every start uses (the variable
;  AxiomSlot). A trial not kept in time (AxiomTry says how long: 10 minutes
;  unless said) ends in a restart, as a panic does, and a hang in the
;  watchdog's reset; the loader then starts the kept kernel again. Each
;  variable holds its file's size and FNV-1a hash: a slot whose file is
;  missing or damaged is passed over, for the kept one, then the built-in
;  one.
;
;  The slots are the only files written here, and only on the volume the
;  loader came from (boot_volume: the serial number it read).
; =============================================================================

UPDATE_TRIAL    equ 600                 ; seconds to keep a trial, unless said
UPDATE_MIN      equ 30                  ; the least a trial may be given
UPDATE_MAX      equ 3600                ; and the most
UPDATE_GRACE    equ 30                  ; past its end, before the timer panics
UPD_LETTER      equ 18                  ; where in upd_path the slot's letter is

section .text

; update_init: early in boot, after harness_init. On a trial, its end set,
; and the watchdog the loader started reloaded until then (update_tick).
update_init:
    push rbx
    mov rbx, [boot_info]
    cmp byte [rbx + BI_TRIAL], 0
    je .out
    mov byte [upd_trial], 1
    mov ax, [rbx + BI_TCO]
    mov [tco_base], ax
    movzx edi, word [rbx + BI_TRIAL_S]
    test edi, edi
    jnz .said
    mov edi, UPDATE_TRIAL
.said:
    cmp edi, UPDATE_MIN
    jae .seconds
    mov edi, UPDATE_MIN
.seconds:
    mov [upd_seconds], rdi
    RDTSC64
    mov ecx, edi
    imul rcx, rcx, 1000
    imul rcx, [tsc_per_ms]
    add rax, rcx
    mov [upd_end], rax
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, UPDATE_GRACE * 1000
    add rax, rcx
    mov [upd_stuck_at], rax
    mov byte [upd_watch], 1
.out:
    pop rbx
    ret

; update_tick: from the timer interrupt, on any CPU, while a trial's
; watchdog runs. Reloaded once a second until the trial's end and the
; grace after it; past that the main loop has not ended the trial, so it
; panics, and the panic restarts the machine. Preserves all.
update_tick:
    push rax
    push rcx
    push rdx
    RDTSC64
    cmp rax, [upd_pet_at]
    jb .out
    cmp rax, [upd_stuck_at]
    jae .stuck
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 1000
    add rcx, rax
    mov [upd_pet_at], rcx
    call tco_pet
.out:
    pop rdx
    pop rcx
    pop rax
    ret
.stuck:
    xor edi, edi
    lea rsi, [str_upd_stuck]
    jmp panic

; update_start: before the main loop. What kernel this is, and what became
; of a trial: this one's, or the last one's.
update_start:
    push rbx
    mov rbx, [boot_info]
    call upd_read
    movzx eax, byte [rbx + BI_SLOT_TRY]
    test eax, eax
    jz .kept_err
    cmp byte [rbx + BI_TRIAL], 0
    jne .kept_err
    call upd_name                       ; a trial named, not started
    movzx ecx, byte [rbx + BI_SLOT_ERR]
    and ecx, 15
    call upd_reason
    KLOG "update: %s, to be tried, was not started: %s", rsi, rcx
    call upd_forget_try
.kept_err:
    movzx ecx, byte [rbx + BI_SLOT_ERR]
    shr ecx, 4
    jz .this
    movzx eax, byte [upd_kept]
    call upd_name
    call upd_reason
    KLOG "update: %s, the one kept, was not started: %s", rsi, rcx
.this:
    movzx eax, byte [rbx + BI_SLOT]
    call upd_name
    cmp byte [rbx + BI_TRIAL], 0
    jne .trial
    KLOG "update: this is %s", rsi
    cmp byte [upd_try_ok], 0            ; a trial before this start, not kept
    je .out
    mov al, [upd_try + UV_SLOT]
    cmp al, 'a'
    jb .out                             ; (one still to come)
    and eax, ~0x20
    call upd_name
    KLOG "update: %s was tried and not kept (its time ran out, it stopped, or it never started)", rsi
    call upd_forget_try
    jmp .out
.trial:
    mov rdx, rsi
    movzx eax, byte [upd_kept]
    call upd_name
    KLOG "update: this is %s, on trial: 'update keep' keeps it; otherwise in %u s the machine restarts, into %s", rdx, qword [upd_seconds], rsi
    movzx eax, word [tco_base]
    test eax, eax
    jz .no_tco
    KLOG "update: the TCO watchdog (I/O %x) restarts the machine should Axiom stop", rax
    jmp .out
.no_tco:
    KLOG "update: no watchdog Axiom can start here: a hang on trial stays hung"
.out:
    pop rbx
    ret

; update_service: from the main loop. A restart a program asked for, to
; start a trial (upd_restart). A trial not kept by its end: the end of the
; log kept (AxiomLog: 'harness log' shows it), and the machine restarted,
; into the kept kernel.
update_service:
    cmp qword [upd_restart_at], 0
    jne .asked
    cmp byte [upd_trial], 0
    jne .on
    ret
.asked:
    RDTSC64
    cmp rax, [upd_restart_at]
    jb .out
    KLOG "update: restarting, for the trial"
    cmp byte [harness_on], 0
    je .final
    call harness_save                   ; a test run's log, as at its end
.final:
    call log_final
    jmp power_reboot
.on:
    RDTSC64
    cmp rax, [upd_end]
    jb .out
    mov byte [upd_trial], 0
    mov rax, [boot_info]
    movzx eax, byte [rax + BI_SLOT]
    call upd_name
    mov rdx, rsi
    movzx eax, byte [upd_kept]
    call upd_name
    KLOG "update: %s was not kept within %u s; the machine restarts, into %s", rdx, qword [upd_seconds], rsi
    call harness_save                   ; the end of the log, for the kept kernel
    call log_final
    jmp power_reboot
.out:
    ret

; update_crashed: on trial, after a panic's report: the end of the log kept
; (AxiomLog), and the machine restarted, into the kept kernel. Never
; returns.
update_crashed:
    call harness_save
    jmp power_reboot

; update: what kernel this is, the one kept, and a trial to come
update_show:
    push rbx
    mov rbx, [boot_info]
    call upd_read
    movzx eax, byte [rbx + BI_SLOT]
    call upd_name
    cmp byte [upd_trial], 0
    jne .trial
    KLOG "update: this is %s", rsi
    jmp .kept
.trial:
    RDTSC64
    mov rcx, [upd_end]
    sub rcx, rax
    jae .left
    xor ecx, ecx
.left:
    mov rax, rcx
    xor edx, edx
    mov rcx, [tsc_per_ms]
    imul rcx, rcx, 1000
    div rcx
    KLOG "update: this is %s, on trial: 'update keep' keeps it; otherwise in %u s the machine restarts", rsi, rax
.kept:
    movzx eax, byte [upd_kept]
    test eax, eax
    jz .none_kept
    call upd_name
    mov ecx, [upd_kept_var + UV_SIZE]
    KLOG "update: kept: %s, %b (AxiomSlot)", rsi, rcx
    jmp .try
.none_kept:
    KLOG "update: none kept (AxiomSlot): every start uses the kernel built into the loader"
.try:
    cmp byte [upd_try_ok], 0
    je .out
    movzx eax, byte [upd_try + UV_SLOT]
    cmp al, 'a'
    jae .out                            ; tried already: this trial, or one gone
    call upd_name
    mov ecx, [upd_try + UV_SIZE]
    movzx edx, word [upd_try + UV_TRIAL]
    KLOG "update: the next start tries %s, %b, for %u s (AxiomTry)", rsi, rcx, rdx
.out:
    pop rbx
    clc
    ret

; update try <file> [<seconds>]: the file, a kernel.bin, into the slot not
; kept, and named in AxiomTry: the next start tries it, and 'update keep'
; there keeps it within the seconds (600 unless said)
update_try:
    push r12
    push r14
    cmp edi, 1
    jb .usage
    cmp edi, 2
    ja .usage
    mov r12, rsi
    xor edx, edx                        ; (600)
    cmp edi, 2
    jne .file
    mov rsi, [r12 + 8]
    call arg_uint
    jc .usage
    mov edx, eax
    cmp edx, UPDATE_MIN
    jb .usage
    cmp edx, UPDATE_MAX
    ja .usage
.file:
    mov rsi, [r12]
    call fat_vol
    jc .out
    call upd_try_file
    test rax, rax
    jz .out                             ; (CF clear)
    stc
    jmp .out
.usage:
    KLOG "usage: update try <file> [<seconds to keep it in: 30 to 3600>]"
    stc
.out:
    pop r14
    pop r12
    ret

; update keep: on trial, this kernel kept: every start uses it (AxiomSlot),
; and the watchdog stopped
update_keep:
    call upd_keep_now
    test rax, rax
    jz .out
    stc
.out:
    ret

; upd_try_file(R14 = a volume, RSI = a kernel.bin's path on it, EDX =
; seconds to keep it in, 0 for 600) -> RAX = 0: it is in the slot not kept,
; read back, and named in AxiomTry; else E_* (said why). For the shell, and
; for programs (RO_FS_UPDATE). The main thread's.
upd_try_file:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r13
    push r14
    push r15
    xor ebx, ebx                        ; no pages yet
    test edx, edx
    jnz .said
    mov edx, UPDATE_TRIAL
.said:
    cmp edx, UPDATE_MIN
    jb .seconds
    cmp edx, UPDATE_MAX
    ja .seconds
    mov [upd_new + UV_TRIAL], dx
    xor ecx, ecx                        ; its size first
    lea rdi, [upd_new]
    call fat_read_file
    jc .missing
    cmp rdx, 32
    jb .not_kernel
    cmp rdx, SLOT_MAX
    ja .too_big
    mov r13, rdx                        ; its bytes
    lea rdi, [rdx + 0xFFF]
    shr rdi, 12
    mov r15, rdi                        ; pages for it
    call pmm_alloc
    test rax, rax
    jz .no_memory
    mov rbx, rax
    mov rdi, rax
    add rdi, [phys_base]
    mov rcx, r13
    call fat_read_file
    jc .missing
    cmp rax, r13
    jne .short
    mov rsi, rdi                        ; a kernel?
    mov rax, [rsi + KH_MAGIC]
    mov rdx, 'AXIOMKRN'
    cmp rax, rdx
    jne .not_kernel
    cmp [rsi + KH_FILE_SIZE], r13
    jne .not_kernel
    mov rax, [rsi + KH_MEM_SIZE]
    cmp rax, r13
    jb .not_kernel
    cmp rax, SLOT_MEM_MAX
    ja .not_kernel
    mov rdx, [rsi + KH_ENTRY]
    mov rcx, KERNEL_BASE
    sub rdx, rcx
    jb .not_kernel
    cmp rdx, rax
    jae .not_kernel
    mov rcx, r13
    call upd_hash
    mov [upd_new + UV_HASH], rax
    mov [upd_new + UV_SIZE], r13d
    call upd_read                       ; the slot not kept
    mov al, 'A'
    cmp byte [upd_kept], 'A'
    jne .slot
    mov al, 'B'
.slot:
    mov [upd_new + UV_SLOT], al
    mov byte [upd_new + 1], 0
    mov [upd_path + UPD_LETTER], al
    call boot_volume
    jc .no_volume
    mov byte [fat_writing], 0
    mov al, [r14 + VO_WRITABLE]
    mov byte [r14 + VO_WRITABLE], 1     ; for this one file
    push rax
    lea rsi, [upd_path]
    mov rdi, rbx
    add rdi, [phys_base]
    mov rcx, r13
    call fat_write_file
    pop rax
    mov [r14 + VO_WRITABLE], al
    jc .io
    mov rcx, r13                        ; read back: what the loader will read
    call fat_read_file
    jc .io
    cmp rax, r13
    jne .unlike
    mov rsi, rdi
    call upd_hash
    cmp rax, [upd_new + UV_HASH]
    jne .unlike
    lea rsi, [name_axiom_try]
    lea rdx, [axiom_guid]
    lea rdi, [upd_new]
    mov ecx, UV_BYTES
    call efi_set_variable
    jc .var_failed
    movzx eax, byte [upd_new + UV_SLOT]
    call upd_name
    movzx eax, byte [r14 + VO_INDEX]
    lea rdx, [upd_path]
    movzx ecx, word [upd_new + UV_TRIAL]
    KLOG "update: %b into %s (vol%u:%s); the next start tries it, and 'update keep' there keeps it, within %u s", r13, rsi, rax, rdx, rcx
    xor eax, eax
    jmp .free
.seconds:
    KLOG "update: a trial is given 30 to 3600 s"
    mov rax, E_ARG
    jmp .free
.missing:
    KLOG "update: that file could not be read"
    mov rax, E_NOFILE
    jmp .free
.too_big:
    KLOG "update: a kernel holds 32 MiB at most"
    mov rax, E_ARG
    jmp .free
.no_memory:
    KLOG "update: no memory to read it into"
    mov rax, E_NOMEM
    jmp .free
.short:
    KLOG "update: only %b of %b could be read", rax, r13
    mov rax, E_IO
    jmp .free
.not_kernel:
    KLOG "update: that is not a kernel.bin (its header is not Axiom's, or not its size)"
    mov rax, E_ARG
    jmp .free
.no_volume:
    KLOG "update: the volume Axiom started from is not here, or two have its serial number"
    mov rax, E_NOFILE
    jmp .free
.io:
    KLOG "update: the slot could not be written; nothing is tried"
    mov rax, E_IO
    jmp .free
.unlike:
    KLOG "update: what was written does not read back the same; nothing is tried"
    mov rax, E_IO
    jmp .free
.var_failed:
    KLOG "update: AxiomTry was not written (EFI status %x); nothing is tried", rax
    mov rax, E_IO
.free:
    test rbx, rbx
    jz .out
    push rax
    mov rdi, rbx
    mov rsi, r15
    call pmm_free
    pop rax
.out:
    pop r15
    pop r14
    pop r13
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; upd_keep_now -> RAX = 0: on trial, this kernel kept: every start uses it
; (AxiomSlot), and the watchdog stopped; else E_ARG or E_IO (said why). For
; the shell, and for programs. The main thread's.
upd_keep_now:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov rbx, [boot_info]
    cmp byte [upd_trial], 0
    je .not_trial
    call upd_read
    cmp byte [upd_try_ok], 0            ; AxiomTry still names it, tried
    je .lost
    movzx eax, byte [upd_try + UV_SLOT]
    sub eax, 0x20
    cmp al, [rbx + BI_SLOT]
    jne .lost
    lea rsi, [upd_try]
    lea rdi, [upd_new]
    mov rcx, [rsi]
    mov [rdi], rcx
    mov rcx, [rsi + 8]
    mov [rdi + 8], rcx
    mov [rdi + UV_SLOT], al
    mov word [rdi + UV_TRIAL], 0
    lea rsi, [name_axiom_slot]
    lea rdx, [axiom_guid]
    mov ecx, UV_BYTES
    call efi_set_variable
    jc .failed
    call upd_forget_try
    mov byte [upd_trial], 0             ; no restart at its end
    movzx eax, byte [rbx + BI_SLOT]
    call upd_name
    KLOG "update: %s is kept: every start uses it now (AxiomSlot)", rsi
    cmp byte [harness_on], 0
    jne .run                            ; a test run's watchdog, still
    cmp word [tco_base], 0
    je .run                             ; (none)
    cmp byte [watch_on], 0
    jne .kept                           ; 'watchdog on': it stays on
    call tco_stop
    jc .running
    mov byte [upd_watch], 0
    KLOG "update: the watchdog is stopped"
    jmp .done
.running:
    mov qword [upd_stuck_at], -1        ; reloaded for as long as Axiom runs
    KLOG "update: the watchdog would not stop; it is reloaded for as long as Axiom runs"
    jmp .done
.kept:
    mov byte [upd_watch], 0
    KLOG "update: the watchdog stays on ('watchdog on' reloads it)"
    jmp .done
.run:
    mov byte [upd_watch], 0             ; the test run reloads it, and ends it
.done:
    xor eax, eax
    jmp .out
.not_trial:
    KLOG "update keep: only on trial, after 'update try' and a restart"
    mov rax, E_ARG
    jmp .out
.lost:
    KLOG "update keep: AxiomTry no longer names this kernel (another was tried since); nothing kept"
    mov rax, E_ARG
    jmp .out
.failed:
    KLOG "update keep: AxiomSlot was not written (EFI status %x); nothing kept", rax
    mov rax, E_IO
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; upd_state -> RAX = UPS_*: the kernel running, whether on trial, the one
; kept, and one the next start tries. Preserves others.
upd_state:
    push rcx
    call upd_read
    mov rax, [boot_info]
    movzx eax, byte [rax + BI_SLOT]
    cmp byte [upd_trial], 0
    je .kept
    or eax, UPS_TRIAL
.kept:
    movzx ecx, byte [upd_kept]
    shl ecx, UPS_KEPT_SHIFT
    or eax, ecx
    cmp byte [upd_try_ok], 0
    je .out
    movzx ecx, byte [upd_try + UV_SLOT]
    cmp ecx, 'a'
    jae .out                            ; tried already
    shl ecx, UPS_NEXT_SHIFT
    or eax, ecx
.out:
    pop rcx
    ret

; upd_restart(EDI = seconds, 1 to 60) -> RAX = 0: with a trial to come
; (AxiomTry), the machine restarts that long from now, into it
; (update_service); else E_ARG. For programs, which have no 'reboot'.
; Preserves others.
upd_restart:
    push rcx
    push rdx
    mov rax, E_ARG
    cmp edi, 1
    jb .out
    cmp edi, 60
    ja .out
    call upd_read
    cmp byte [upd_try_ok], 0
    je .none
    movzx ecx, byte [upd_try + UV_SLOT]
    cmp ecx, 'a'
    jae .none                           ; tried already
    RDTSC64
    mov ecx, edi
    imul rcx, rcx, 1000
    imul rcx, [tsc_per_ms]
    add rax, rcx
    mov [upd_restart_at], rax
    mov ecx, edi
    KLOG "update: the machine restarts in %u s, for the trial", rcx
    xor eax, eax
    jmp .out
.none:
    KLOG "update: no trial to come (AxiomTry): no restart"
    mov rax, E_ARG
.out:
    pop rdx
    pop rcx
    ret

; upd_read -> upd_kept = the slot AxiomSlot names (0 if none), upd_kept_var
; it; upd_try = AxiomTry, upd_try_ok = 1 if it is there. Preserves all.
upd_read:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    mov byte [upd_kept], 0
    lea rsi, [name_axiom_slot]
    lea rdx, [axiom_guid]
    lea rdi, [upd_kept_var]
    mov ecx, UV_BYTES
    call efi_get_variable
    jc .try
    cmp eax, UV_BYTES
    jne .try
    mov al, [upd_kept_var + UV_SLOT]
    cmp al, 'A'
    je .kept
    cmp al, 'B'
    jne .try
.kept:
    mov [upd_kept], al
.try:
    mov byte [upd_try_ok], 0
    lea rsi, [name_axiom_try]
    lea rdi, [upd_try]
    mov ecx, UV_BYTES
    call efi_get_variable
    jc .out
    cmp eax, UV_BYTES
    jne .out
    mov byte [upd_try_ok], 1
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; upd_forget_try: AxiomTry deleted. Preserves all.
upd_forget_try:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    lea rsi, [name_axiom_try]
    lea rdx, [axiom_guid]
    xor edi, edi
    xor ecx, ecx
    call efi_set_variable
    mov byte [upd_try_ok], 0
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; upd_name(AL = a slot, or 0) -> RSI = what to call that kernel. Preserves
; others.
upd_name:
    lea rsi, [str_upd_a]
    cmp al, 'A'
    je .out
    lea rsi, [str_upd_b]
    cmp al, 'B'
    je .out
    lea rsi, [str_upd_builtin]
.out:
    ret

; upd_reason(ECX = SLOT_*) -> RCX = why the loader passed a slot over.
; Preserves others.
upd_reason:
    cmp ecx, SLOT_UNMARKED
    jbe .known
    xor ecx, ecx
.known:
    push rax
    lea rax, [upd_reasons]
    mov rcx, [rax + rcx * 8]
    pop rax
    ret

; upd_hash(RSI = bytes, RCX = how many) -> RAX = their FNV-1a hash
; (64-bit), as the loader's fnv64. Preserves others.
upd_hash:
    push rcx
    push rdx
    push rsi
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
    pop rsi
    pop rdx
    pop rcx
    ret

section .data
align 8
update_actions:
    ACTION  '',     update_show, '', 'what kernel this is, the one kept, and a trial to come', 0
    ACTION  'try',  update_try,  '<file> [<seconds>]', "a kernel.bin, tried at the next start; given up unless kept in time (600 s unless said)", 0
    ACTION  'keep', update_keep, '', 'on trial: this kernel kept, for every start', 0
    dq 0, 0, 0, 0, 0
upd_path:       db '/EFI/AXIOM/KERNEL.A', 0

section .rodata
align 8
upd_reasons:    dq str_slot_ok, str_slot_missing, str_slot_damaged, str_slot_unmarked
str_slot_ok:        db 'no reason given', 0
str_slot_missing:   db 'its file is missing, or could not be read', 0
str_slot_damaged:   db 'its file is damaged: not a kernel, or not the size and hash its variable says', 0
str_slot_unmarked:  db 'AxiomTry could not be marked tried', 0
str_upd_a:          db 'kernel A', 0
str_upd_b:          db 'kernel B', 0
str_upd_builtin:    db 'the kernel built into the loader', 0
str_upd_stuck:      db 'update: the trial is past its end, and the main loop has not ended it', 0
align 2
name_axiom_try:     dw __utf16__('AxiomTry'), 0
name_axiom_slot:    dw __utf16__('AxiomSlot'), 0

section .bss
alignb 8
upd_seconds:    resq 1                  ; the trial's: how long,
upd_end:        resq 1                  ; its end (TSC),
upd_stuck_at:   resq 1                  ; when the timer panics,
upd_pet_at:     resq 1                  ; the watchdog's next reload
upd_restart_at: resq 1                  ; a restart a program asked for (TSC), or 0
upd_kept_var:   resb UV_BYTES           ; AxiomSlot
upd_try:        resb UV_BYTES           ; AxiomTry
upd_new:        resb UV_BYTES           ; one being written
upd_trial:      resb 1                  ; on trial, and not kept yet
upd_watch:      resb 1                  ; update_tick reloads the watchdog
upd_kept:       resb 1                  ; the slot AxiomSlot names, or 0
upd_try_ok:     resb 1                  ; AxiomTry is there
