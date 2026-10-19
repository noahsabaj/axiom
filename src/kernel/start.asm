; =============================================================================
;  start.asm - what a machine does at each start, with no one at it
;
;  The lines of /EFI/AXIOM/START.TXT, on the volume Axiom started from, are
;  typed into the first terminal, each once the one before is done, as a
;  test run's are (harness.asm): axiom-1's says 'fleet &'. Blank lines and
;  '#' comments are passed over. A test run's script waits until they are
;  done.
; =============================================================================

START_MAX       equ 4096                ; START.TXT's bytes, at most
START_WAIT      equ 20                  ; seconds the boot volume may take to come

section .text

; start_service: from the main loop, before harness_service. START.TXT read
; once the volume Axiom started from is here, then its lines, each once the
; first terminal is ready for it.
start_service:
    cmp byte [start_on], 0
    jne .on
    ret
.on:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r14
    cmp byte [start_read], 0
    jne .ready
    call boot_volume
    jc .not_yet
    lea rsi, [start_path]
    lea rdi, [start_text]
    mov ecx, START_MAX
    mov byte [fat_hush], 1              ; (none, most machines)
    call fat_read_file
    mov byte [fat_hush], 0
    jc .done
    cmp rdx, START_MAX
    ja .too_big
    mov [start_len], rax
    mov byte [start_text + rax], 0
    mov byte [start_read], 1
    movzx ecx, byte [r14 + VO_INDEX]
    KLOG "start: vol%u:/EFI/AXIOM/START.TXT, %b: its lines go to the first terminal", rcx, rax
.ready:
    call term_oldest
    jc .out
    cmp byte [rbx + TW_SH_WAIT], 0
    jne .out                            ; its command runs on
.next:
    lea rsi, [start_text]
    lea rdi, [start_pos]
    mov rdx, [start_len]
    call script_line
    jc .done
    cmp byte [harness_line], 0
    je .next
    cmp byte [harness_line], '#'
    je .next
    mov r11, rbx
    lea rax, [harness_type]
    call con_call
    jmp .out
.not_yet:
    call uptime_ms
    cmp rax, START_WAIT * 1000
    jb .out
    KLOG "start: the volume Axiom started from is not here; START.TXT is not read"
    jmp .done
.too_big:
    KLOG "start: START.TXT is %b, over 4 KiB; none of it is typed", rdx
.done:
    mov byte [start_on], 0
.out:
    pop r14
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

section .data
start_on:       db 1                    ; START.TXT not done
start_path:     db '/EFI/AXIOM/START.TXT', 0

section .bss
alignb 8
start_len:      resq 1                  ; START.TXT's bytes,
start_pos:      resq 1                  ; and its next line's
start_read:     resb 1                  ; it is read
start_text:     resb START_MAX + 8
