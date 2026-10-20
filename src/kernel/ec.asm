; =============================================================================
;  ec.asm - the ACPI embedded controller: a laptop's small second computer
;  (battery, charger, fans, lid), and its 256 byte registers, read and
;  written one at a time through two I/O ports (ACPI 6.5, 12.2-12.3).
;
;  Where the ports are: the firmware's ECDT, or a board battery.asm knows.
;  No AML runs here, so nothing else on the CPU side talks to the EC: one
;  transaction at a time, from the main thread, and power_reboot's last word
;  (battery_leave), which only tries (ec_busy). Events the EC raises
;  (SCI_EVT) are not asked for.
;
;  With ec_fake set, the four port accesses go to a simulated EC instead
;  (batterytest.asm), so 'battery test' runs this protocol unchanged.
; =============================================================================

EC_OBF          equ 0x01                ; status: a byte for us in the data port
EC_IBF          equ 0x02                ; status: the EC has not taken ours yet
EC_READ         equ 0x80                ; commands: RD_EC, WR_EC
EC_WRITE        equ 0x81
EC_STEP_MS      equ 50                  ; the most one step may take

EC_FROM_ECDT    equ 1                   ; ec_from: where the ports came from
EC_FROM_BOARD   equ 2

section .text

; ec_init: after acpi_init. The ports, if the firmware has an ECDT.
ec_init:
    xor ecx, ecx
.find:
    cmp ecx, [acpi_table_count]
    jae .out
    lea rax, [acpi_table_sigs]
    cmp dword [rax + rcx * 4], 'ECDT'
    je .found
    inc ecx
    jmp .find
.found:
    lea rax, [acpi_table_ptrs]
    mov rsi, [rax + rcx * 8]
    cmp dword [rsi + 4], 65
    jb .out
    cmp byte [rsi + 36], 1              ; EC_CONTROL, a register in I/O space
    jne .out
    cmp byte [rsi + 48], 1              ; EC_DATA
    jne .out
    mov rax, [rsi + 40]
    mov rdx, [rsi + 52]
    test rax, rax
    jz .out
    test rdx, rdx
    jz .out
    cmp rax, 0xFFFF
    ja .out
    cmp rdx, 0xFFFF
    ja .out
    mov [ec_cmd], ax
    mov [ec_data], dx
    mov byte [ec_from], EC_FROM_ECDT
.out:
    ret

; ec_use(EDI = command port, ESI = data port): a board's ports, unless the
; ECDT gave some. Preserves all.
ec_use:
    cmp byte [ec_from], 0
    jne .out
    mov [ec_cmd], di
    mov [ec_data], si
    mov byte [ec_from], EC_FROM_BOARD
.out:
    ret

; ec_status -> EAX = the status byte. Preserves others.
ec_status:
    cmp byte [ec_fake], 0
    jne fake_status
    push rdx
    movzx edx, word [ec_cmd]
    xor eax, eax
    in al, dx
    pop rdx
    ret

; ec_get -> EAX = the byte in the data port. Preserves others.
ec_get:
    cmp byte [ec_fake], 0
    jne fake_get
    push rdx
    movzx edx, word [ec_data]
    xor eax, eax
    in al, dx
    pop rdx
    ret

; ec_command(AL). Preserves all.
ec_command:
    cmp byte [ec_fake], 0
    jne fake_command
    push rdx
    movzx edx, word [ec_cmd]
    out dx, al
    pop rdx
    ret

; ec_put(AL), into the data port. Preserves all.
ec_put:
    cmp byte [ec_fake], 0
    jne fake_put
    push rdx
    movzx edx, word [ec_data]
    out dx, al
    pop rdx
    ret

; ec_wait(R9D = status bits, R10D = what they should be) -> CF if they were
; not, within EC_STEP_MS. Clobbers RAX, RDX, R8.
ec_wait:
    RDTSC64
    mov r8, [tsc_per_ms]
    imul r8, r8, EC_STEP_MS
    add r8, rax
.poll:
    call ec_status
    and eax, r9d
    cmp eax, r10d
    je .ok
    pause
    RDTSC64
    cmp rax, r8
    jb .poll
    call ec_status                      ; once more, after the time (a slow vCPU)
    and eax, r9d
    cmp eax, r10d
    je .ok
    stc
    ret
.ok:
    clc
    ret

; ec_begin(AL = command) -> CF: busy, or the EC took nothing. A stale byte
; in the data port read away first; the lock taken unless CF. Clobbers RAX,
; RCX, RDX, R8-R10.
ec_begin:
    mov r9d, eax
    cmp byte [ec_from], 0
    je .none
    lock bts dword [ec_busy], 0
    jc .none
    mov ecx, 4
.flush:
    call ec_status
    test al, EC_OBF
    jz .flushed
    call ec_get
    dec ecx
    jnz .flush
.flushed:
    mov eax, r9d
    push rax
    mov r9d, EC_IBF
    xor r10d, r10d
    call ec_wait
    pop rax
    jc .fail
    call ec_command
    call ec_wait                        ; taken
    jc .fail
    ret
.fail:
    mov dword [ec_busy], 0
.none:
    stc
    ret

; ec_read(EDI = register) -> EAX = its byte; CF if the EC did not answer.
; Preserves others.
ec_read:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    mov eax, EC_READ
    call ec_begin
    jc .fail
    mov eax, edi
    call ec_put
    mov r9d, EC_OBF
    mov r10d, EC_OBF
    call ec_wait
    jc .unlock
    call ec_get
    mov dword [ec_busy], 0
    clc
    jmp .out
.unlock:
    mov dword [ec_busy], 0
.fail:
    inc dword [ec_failures]
    xor eax, eax
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; ec_write(EDI = register, ESI = its new byte) -> CF if the EC did not take
; it, or is never written (ec_readonly: a board battery.asm's table says
; so). Preserves all.
ec_write:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    cmp byte [ec_readonly], 0
    je .write
    cmp byte [ec_fake], 0               ; (the simulated EC may be)
    je .refused
.write:
    mov eax, EC_WRITE
    call ec_begin
    jc .fail
    mov eax, edi
    call ec_put
    call ec_wait                        ; (R9D, R10D: IBF clear, from ec_begin)
    jc .unlock
    mov eax, esi
    call ec_put
    call ec_wait
    jc .unlock
    mov dword [ec_busy], 0
    clc
    jmp .out
.unlock:
    mov dword [ec_busy], 0
.fail:
    inc dword [ec_failures]
.refused:
    stc
.out:
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

section .data
ec_fake:        db 0                    ; 1: the simulated EC (batterytest.asm)

section .bss
alignb 4
ec_busy:        resd 1                  ; bit 0: a transaction under way
ec_failures:    resd 1                  ; transactions the EC did not finish
ec_cmd:         resw 1                  ; EC_SC: status in, commands out
ec_data:        resw 1                  ; EC_DATA
ec_from:        resb 1                  ; 0: no EC known; else EC_FROM_*
ec_readonly:    resb 1                  ; 1: never written (battery.asm's board)
