; =============================================================================
;  rtc.asm - the CMOS clock: local time as the firmware (or Windows) set it.
;  Read on demand for file times and 'date'.
; =============================================================================

section .text

; rtc_read: the clock into rtc_year .. rtc_sec. Preserves all.
rtc_read:
    push rax
    push rbx
    push rcx
    pushfq
    cli
    mov ecx, 1000000                    ; not during an update
.busy:
    mov al, 0x0A
    out 0x70, al
    in al, 0x71
    test al, 0x80
    loopnz .busy
    mov al, 0x0B                        ; bit 2 binary, bit 1 24-hour
    out 0x70, al
    in al, 0x71
    mov bl, al
    mov al, 0x00
    call rtc_get
    mov [rtc_sec], eax
    mov al, 0x02
    call rtc_get
    mov [rtc_min], eax
    mov al, 0x04
    out 0x70, al
    in al, 0x71
    mov bh, al                          ; bit 7: PM, on a 12-hour clock
    and al, 0x7F
    call rtc_bcd
    test bl, 2
    jnz .hour
    cmp eax, 12
    jne .am
    xor eax, eax
.am:
    test bh, 0x80
    jz .hour
    add eax, 12
.hour:
    mov [rtc_hour], eax
    mov al, 0x07
    call rtc_get
    mov [rtc_day], eax
    mov al, 0x08
    call rtc_get
    mov [rtc_mon], eax
    mov al, 0x09
    call rtc_get
    add eax, 2000
    mov [rtc_year], eax
    popfq
    mov eax, [rtc_mon]                  ; nonsense becomes 1 January
    dec eax
    cmp eax, 11
    jbe .month
    mov dword [rtc_mon], 1
.month:
    mov eax, [rtc_day]
    dec eax
    cmp eax, 30
    jbe .out
    mov dword [rtc_day], 1
.out:
    pop rcx
    pop rbx
    pop rax
    ret

; rtc_epoch: rtc_epoch_us, from the clock as rtc_read left it (taken as UTC)
; less the TSC's microseconds now, so that the time is it plus the TSC's
; (SI_CLOCK). Days from the date by Hinnant's days_from_civil. Preserves all.
rtc_epoch:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov eax, [rtc_year]
    mov ecx, [rtc_mon]
    cmp ecx, 2                          ; the year from March
    ja .march
    dec eax
.march:
    xor edx, edx
    mov ebx, 400
    div ebx
    mov esi, eax                        ; ESI = the era, EDI = the year in it
    mov edi, edx
    lea eax, [rcx - 3]                  ; the month from March
    cmp ecx, 2
    ja .mp
    lea eax, [rcx + 9]
.mp:
    imul eax, eax, 153                  ; the day of the year
    add eax, 2
    xor edx, edx
    mov ebx, 5
    div ebx
    add eax, [rtc_day]
    dec eax
    mov ebx, eax
    imul eax, edi, 365                  ; the day of the era
    add ebx, eax
    mov eax, edi
    shr eax, 2
    add ebx, eax
    mov eax, edi
    xor edx, edx
    mov ecx, 100
    div ecx
    sub ebx, eax
    imul rax, rsi, 146097               ; days since 1970
    add rax, rbx
    sub rax, 719468
    imul rax, rax, 86400
    imul rcx, [rtc_hour], 3600
    add rax, rcx
    imul rcx, [rtc_min], 60
    add rax, rcx
    add rax, [rtc_sec]
    imul rbx, rax, 1000000
    RDTSC64
    xor edx, edx
    div qword [tsc_per_us]
    sub rbx, rax
    mov [rtc_epoch_us], rbx
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; rtc_get(AL = register, BL = status B) -> EAX
rtc_get:
    out 0x70, al
    in al, 0x71
; rtc_bcd(AL, BL = status B) -> EAX, from BCD unless the clock is binary
rtc_bcd:
    movzx eax, al
    test bl, 4
    jnz .out
    push rcx
    mov ecx, eax
    shr eax, 4
    imul eax, eax, 10
    and ecx, 15
    add eax, ecx
    pop rcx
.out:
    ret

; rtc_fat_time -> EAX = FAT date << 16 | FAT time. Preserves others.
rtc_fat_time:
    push rcx
    call rtc_read
    mov eax, [rtc_year]
    sub eax, 1980
    shl eax, 4
    or eax, [rtc_mon]
    shl eax, 5
    or eax, [rtc_day]
    shl eax, 5
    or eax, [rtc_hour]
    shl eax, 6
    or eax, [rtc_min]
    shl eax, 5
    mov ecx, [rtc_sec]
    shr ecx, 1
    or eax, ecx
    pop rcx
    ret

cmd_date:
    call rtc_read
    KLOG "%04u-%02u-%02u %02u:%02u:%02u", qword [rtc_year], qword [rtc_mon], qword [rtc_day], qword [rtc_hour], qword [rtc_min], qword [rtc_sec]
    ret

section .bss
alignb 8
rtc_year:       resq 1                  ; qwords, so KLOG can take them
rtc_mon:        resq 1
rtc_day:        resq 1
rtc_hour:       resq 1
rtc_min:        resq 1
rtc_sec:        resq 1
rtc_epoch_us:   resq 1                  ; 1970's microsecond less the TSC's (rtc_epoch)
