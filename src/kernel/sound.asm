; =============================================================================
;  sound.asm - sound for programs: streams of 48 kHz 16-bit stereo, mixed
;  by the thread 'sound' into the buffer the HD Audio controller plays
;  (hda.asm), or with no controller into nothing, at the same pace.
;
;  A program run with AW_SOUND gets a handle to the speakers (OT_SOUND,
;  SB_SOUND). SYS_SOUND_NEW opens a stream on them (OT_STREAM) and gives
;  its memory too: a header (SN_*), then a ring of frames, a left and a
;  right sample each. The program writes frames and adds to SN_WRITE; the
;  mixer takes them and adds to SN_READ. RO_WAIT on the stream completes
;  once no more than SN_LOW frames wait. A stream that runs dry plays
;  silence until more come; closing it ends it.
;
;  The mixer wakes every SND_TICK_MS and keeps the buffer filled snd_lead
;  frames ahead of where the controller reads: the streams summed in 32
;  bits, each by its SN_GAIN, then all by the volume, saturated to 16
;  bits. Should the controller catch up, it starts again where that is,
;  with silence written after what it mixed in case it is late again.
;
;  In the shell 'sound' is a thing: sound (how it is), sound volume <n>,
;  sound tone [hz [ms]], sound test.
; =============================================================================

SND_RATE        equ 48000
SND_BUF         equ 32768               ; the buffer the controller plays, bytes
SND_FRAMES      equ SND_BUF / 4         ; 170 ms of it
SND_FMASK       equ SND_FRAMES - 1
SND_LEAD        equ 1920                ; frames kept ahead of the controller: 40 ms
SND_PAD         equ 2048                ; silence after them
SND_TICK_MS     equ 5
SND_MIN         equ 1024                ; a stream's frames, at least
SND_MAX         equ 65536               ; and at most
SND_FADE        equ 480                 ; a tone's frames in and out: 10 ms
SND_TONE_AMP    equ 8192 << 12          ; its peak, -12 dB, << 12

; a stream (OT_STREAM)
SS_NEXT         equ OB_SIZE             ; snd_streams; its first reference is the list's
SS_MEM          equ OB_SIZE + 8         ; its memory, a reference
SS_HDR          equ OB_SIZE + 16        ; where that is in the kernel
SS_MASK         equ OB_SIZE + 24        ; dword: its frames - 1
SS_READ         equ OB_SIZE + 28        ; dword: frames taken, in all (SN_READ is the program's copy)
SS_READY        equ OB_SIZE + 32        ; dword: no more than SN_LOW wait (RO_WAIT's flag)
SS_LISTED       equ OB_SIZE + 36        ; dword: on snd_streams
SS_WQ           equ OB_SIZE + 40
SS_SIZE         equ SS_WQ + WQ_SIZE

%macro SND_LOCK 0
    pushfq
    cli
    push rdi
    lea rdi, [snd_lock]
    call spin_lock
    pop rdi
%endmacro

%macro SND_UNLOCK 0
    push rdi
    lea rdi, [snd_lock]
    call spin_unlock
    pop rdi
    popfq
%endmacro

section .text

; snd_boot: the buffer, the controller if there is one, and the thread
; 'sound'. Once the scheduler, PCI and the IOMMU are up.
snd_boot:
    mov rax, [tsc_per_ms]
    imul rax, rax, SND_TICK_MS
    mov [snd_tick], rax
    mov dword [snd_lead], SND_LEAD
    mov edi, 75
    call snd_volume_set
    mov edi, SND_BUF / 4096
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    add rax, [phys_base]
    mov [snd_buf], rax
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    add rax, [phys_base]
    mov [hda_page], rax
    call hda_init
    lea rdi, [snd_main]
    xor esi, esi
    lea rdx, [str_snd_thread]
    mov ecx, THC_ANY
    call thread_spawn
    test rax, rax
    jz .oom
    mov [snd_thread], rax
    ret
.oom:
    KLOG "sound: out of memory"
    ret

; the thread 'sound'
snd_main:
    RDTSC64
    mov [snd_t0], rax
    call snd_where                      ; from where the controller is
    mov [snd_w], eax
.loop:
    RDTSC64
    add rax, [snd_tick]
    mov rbx, rax
    call snd_fill
    mov rdi, rbx
    call thread_park_until
    jmp .loop

; snd_where -> EAX = the frame of the buffer the controller reads next (with
; none, where it would be by the clock)
snd_where:
    mov rax, [hda_sd]
    test rax, rax
    jz .clock
    mov eax, [rax + SD_LPIB]
    shr eax, 2
    and eax, SND_FMASK
    ret
.clock:
    push rcx
    push rdx
    RDTSC64
    sub rax, [snd_t0]
    mov ecx, SND_RATE / 1000
    mul rcx
    div qword [tsc_per_ms]
    and eax, SND_FMASK
    pop rdx
    pop rcx
    ret

; snd_fill: the buffer filled snd_lead frames ahead of the controller
snd_fill:
    push rbx
    push r12
    call snd_where
    mov ecx, [snd_w]
    sub ecx, eax
    and ecx, SND_FMASK                  ; ECX = how far ahead it is
    cmp ecx, SND_FRAMES / 2
    jb .ahead
    inc qword [snd_dry]                 ; caught up: again from where it is
    mov [snd_w], eax                    ; (counted, not said: it would land
    xor ecx, ecx                        ; in whatever the console shows)
.ahead:
    mov r12d, [snd_lead]
    sub r12d, ecx
    jbe .out
    call snd_mix
    mov eax, [snd_w]                    ; silence after it
    add eax, r12d
    and eax, SND_FMASK
    mov [snd_w], eax
    add [snd_played], r12
    mov rdi, [snd_buf]
    mov ecx, SND_PAD
.pad:
    mov dword [rdi + rax * 4], 0
    inc eax
    and eax, SND_FMASK
    dec ecx
    jnz .pad
.out:
    pop r12
    pop rbx
    ret

; snd_mix(R12D = frames): that many mixed into the buffer at snd_w
snd_mix:
    push rbx
    push r12
    lea rdi, [snd_acc]
    lea ecx, [r12 * 2]
    xor eax, eax
    rep stosd
    SND_LOCK
    mov rbx, [snd_streams]
.stream:
    test rbx, rbx
    jz .tone
    call snd_take
    mov rbx, [rbx + SS_NEXT]
    jmp .stream
.tone:
    cmp dword [snd_tone_n], 0
    je .mixed
    call snd_tone
.mixed:
    SND_UNLOCK
    lea rsi, [snd_acc]                  ; by the volume, saturated
    mov rdi, [snd_buf]
    mov r8d, [snd_gain]
    mov edx, [snd_w]
    shl edx, 1                          ; in samples
    lea ecx, [r12 * 2]
    mov r9, -32768
    mov r10d, 32767
.sample:
    movsxd rax, dword [rsi]
    imul rax, r8
    sar rax, 16
    cmp rax, r9
    cmovl rax, r9
    cmp rax, r10
    cmovg rax, r10
    mov [rdi + rdx * 2], ax
    add rsi, 4
    inc edx
    and edx, SND_FRAMES * 2 - 1
    dec ecx
    jnz .sample
    pop r12
    pop rbx
    ret

; snd_take(RBX = a stream, R12D = frames): what of them it has, into snd_acc
; by its gain; its waiters woken if no more than SN_LOW wait. snd_lock held.
snd_take:
    push r12
    push r13
    mov rsi, [rbx + SS_HDR]
    mov eax, [rsi + SN_WRITE]           ; written and not taken
    sub eax, [rbx + SS_READ]
    mov ecx, [rbx + SS_MASK]
    cmp eax, ecx
    jbe .waiting
    lea eax, [rcx + 1]                  ; more than it holds: all it holds
.waiting:
    mov r13d, eax
    cmp r13d, r12d
    jae .enough
    mov eax, [rbx + SS_READ]            ; dry, once it has begun
    or eax, r13d
    jz .short
    mov eax, r12d
    sub eax, r13d
    add [rsi + SN_SHORT], eax
.short:
    mov r12d, r13d
.enough:
    mov r10d, [rsi + SN_GAIN]
    cmp r10d, 65536
    jbe .gain
    mov r10d, 65536
.gain:
    lea rdi, [snd_acc]
    mov edx, [rbx + SS_READ]
    mov r11d, [rbx + SS_MASK]
    xor ecx, ecx
.frame:
    cmp ecx, r12d
    jae .taken
    mov eax, edx
    add eax, ecx
    and eax, r11d
    movsx r8, word [rsi + SN_DATA + rax * 4]
    movsx r9, word [rsi + SN_DATA + rax * 4 + 2]
    imul r8, r10
    imul r9, r10
    sar r8, 16
    sar r9, 16
    add [rdi + rcx * 8], r8d
    add [rdi + rcx * 8 + 4], r9d
    inc ecx
    jmp .frame
.taken:
    add [rbx + SS_READ], r12d
    mov eax, [rbx + SS_READ]
    mov [rsi + SN_READ], eax
    sub r13d, r12d                      ; what still waits
    cmp r13d, [rsi + SN_LOW]
    ja .out
    cmp dword [rbx + SS_READY], 0
    jne .out
    mov dword [rbx + SS_READY], 1
    lea rdi, [rbx + SS_WQ]
    call wq_wake
.out:
    pop r13
    pop r12
    ret

; snd_tone(R12D = frames): the tone, into snd_acc, as far as it goes: a
; sine by the magic circle, faded in and out. snd_lock held.
snd_tone:
    push rbx
    lea rdi, [snd_acc]
    mov r8, [snd_tone_x]
    mov r9, [snd_tone_y]
    mov r10, [snd_tone_e]
    xor ecx, ecx
.frame:
    cmp ecx, r12d
    jae .out
    cmp dword [snd_tone_n], 0
    je .out
    mov rax, r9                         ; x -= e * y, y += e * x
    imul rax, r10
    sar rax, 16
    sub r8, rax
    mov rax, r8
    imul rax, r10
    sar rax, 16
    add r9, rax
    mov eax, [snd_tone_t]               ; faded: the least of the frames
    mov edx, [snd_tone_n]               ; since it began, those left, and
    cmp eax, edx                        ; SND_FADE
    cmova eax, edx
    mov edx, SND_FADE
    cmp eax, edx
    cmova eax, edx
    mov rbx, r9
    sar rbx, 12
    imul rbx, rax
    mov rax, rbx
    cqo
    mov ebx, SND_FADE
    idiv rbx
    add [rdi + rcx * 8], eax
    add [rdi + rcx * 8 + 4], eax
    inc dword [snd_tone_t]
    dec dword [snd_tone_n]
    inc ecx
    jmp .frame
.out:
    mov [snd_tone_x], r8
    mov [snd_tone_y], r9
    pop rbx
    ret

; snd_tone_start(EDI = hertz, ESI = milliseconds)
snd_tone_start:
    imul rax, rdi, 562210               ; e = 2 pi f / 48000, << 16
    shr rax, 16
    imul esi, esi, SND_RATE / 1000
    SND_LOCK
    mov [snd_tone_e], rax
    mov qword [snd_tone_x], SND_TONE_AMP
    mov qword [snd_tone_y], 0
    mov dword [snd_tone_t], 0
    mov [snd_tone_n], esi
    SND_UNLOCK
    ret

; snd_volume_set(EDI = 0..100): the gain on all, by its square
snd_volume_set:
    mov [snd_volume], edi
    mov eax, edi
    imul eax, edi
    shl eax, 16
    xor edx, edx
    mov ecx, 10000
    div ecx
    mov [snd_gain], eax
    ret

; -----------------------------------------------------------------------------
;  Programs
; -----------------------------------------------------------------------------

; snd_program -> EAX = a handle to the speakers for the current task, 0 if
; out of memory. Preserves others but RAX.
snd_program:
    push rcx
    push rdx
    push rsi
    push rdi
    mov edi, OT_SOUND
    mov esi, OB_SIZE
    lea rdx, [str_ot_sound]
    call obj_new
    test rax, rax
    jz .none
    mov rdi, rax
    mov esi, RT_SOUND_PLAY | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jb .out
.none:
    xor eax, eax
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; sys_sound_new(EDI = the speakers, ESI = frames, made a power of two from
; SND_MIN to SND_MAX) -> RAX = a handle to a stream, RDX = to its memory
sys_sound_new:
    push rbx
    push r12
    push r13
    mov r12d, esi
    mov esi, OT_SOUND
    mov edx, RT_SOUND_PLAY
    call handle_get
    cmp rax, E_ANY
    jae .out
    mov rdi, rax
    call obj_put
    mov eax, SND_MIN
.size:
    cmp eax, r12d
    jae .sized
    cmp eax, SND_MAX
    jae .sized
    shl eax, 1
    jmp .size
.sized:
    mov r12d, eax
    mov edi, OT_STREAM
    mov esi, SS_SIZE
    lea rdx, [str_ot_stream]
    call obj_new
    test rax, rax
    jz .nomem
    mov rbx, rax
    lea edi, [r12 * 4 + SN_DATA]
    lea rsi, [str_snd_mem]
    call mem_new
    test rax, rax
    jz .no_memory
    mov [rbx + SS_MEM], rax
    mov rdi, [rax + MO_BASE]
    mov [rbx + SS_HDR], rdi
    mov [rdi + SN_FRAMES], r12d
    mov dword [rdi + SN_RATE], SND_RATE
    mov dword [rdi + SN_CHANNELS], 2
    mov eax, r12d
    shr eax, 1
    mov [rdi + SN_LOW], eax
    mov dword [rdi + SN_GAIN], 65536
    dec r12d
    mov [rbx + SS_MASK], r12d
    mov rdi, [rbx + SS_MEM]             ; the program's handles: its memory,
    call obj_get
    mov esi, RT_MEM_READ | RT_MEM_WRITE | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .no_handle
    mov r13, rax
    mov rdi, rbx                        ; and the stream
    call obj_get
    mov esi, RT_STREAM_PLAY | RT_DUP | RT_GIVE | RT_INFO
    call handle_new
    cmp rax, E_ANY
    jae .no_stream
    mov r12, rax
    SND_LOCK                            ; the first reference: the list's
    mov rax, [snd_streams]
    mov [rbx + SS_NEXT], rax
    mov [snd_streams], rbx
    mov dword [rbx + SS_LISTED], 1
    inc dword [snd_count]
    SND_UNLOCK
    mov rax, r12
    mov rdx, r13
    jmp .done
.no_stream:
    push rax
    mov edi, r13d
    call handle_close
    pop rax
.no_handle:
    mov rdi, rbx                        ; snd_destroy lets go of the memory
    call obj_put
    jmp .out
.no_memory:
    mov rdi, rbx
    call obj_free
.nomem:
    mov rax, E_NOMEM
.out:
    xor edx, edx
.done:
    call op_done
    pop r13
    pop r12
    pop rbx
    ret

; snd_ready(RDI = a stream): SS_READY as it is now, for RO_WAIT to wait on.
; Preserves others.
snd_ready:
    push rax
    push rsi
    mov rsi, [rdi + SS_HDR]
    mov eax, [rsi + SN_WRITE]
    sub eax, [rdi + SS_READ]
    cmp eax, [rsi + SN_LOW]
    setbe al
    movzx eax, al
    mov [rdi + SS_READY], eax
    pop rsi
    pop rax
    ret

; snd_orphan(RDI): its last handle went; off the mixer's list, its
; waiters woken, and the list's reference dropped
snd_orphan:
    push rbx
    mov rbx, rdi
    xor ecx, ecx
    SND_LOCK
    cmp dword [rbx + SS_LISTED], 0
    je .unlinked
    lea rax, [snd_streams]
.find:
    mov rdx, [rax]
    test rdx, rdx
    jz .unlinked
    cmp rdx, rbx
    je .found
    lea rax, [rdx + SS_NEXT]
    jmp .find
.found:
    mov rdx, [rbx + SS_NEXT]
    mov [rax], rdx
    mov dword [rbx + SS_LISTED], 0
    dec dword [snd_count]
    inc ecx
.unlinked:
    mov dword [rbx + SS_READY], 1
    SND_UNLOCK
    lea rdi, [rbx + SS_WQ]
    call wq_wake
    test ecx, ecx
    jz .out
    mov rdi, rbx
    call obj_put
.out:
    pop rbx
    ret

; snd_destroy(RDI): its last reference went
snd_destroy:
    push rbx
    mov rbx, rdi
    mov rdi, [rbx + SS_MEM]
    test rdi, rdi
    jz .free
    call obj_put
.free:
    mov rdi, rbx
    call obj_free
    pop rbx
    ret

; -----------------------------------------------------------------------------
;  The shell's 'sound'
; -----------------------------------------------------------------------------

snd_show:
    COLUMN 'device', FT_TEXT
    COLUMN 'outputs', FT_INT
    COLUMN 'volume', FT_INT, 0, '%'
    COLUMN 'streams', FT_INT
    COLUMN 'played', FT_DUR
    COLUMN 'caught up', FT_INT
    push rdi
    mov edi, TBF_RECORD
    call rec_flag
    pop rdi
    call rec_row
    lea rsi, [str_snd_none]
    cmp qword [hda_sd], 0
    je .device
    movzx eax, word [hda_ids]
    movzx ecx, word [hda_ids + 2]
    movzx edx, word [hda_vendor + 2]
    movzx r8d, word [hda_vendor]
    SPRINTF snd_text, "HD Audio %04x:%04x, codec %04x:%04x", rax, rcx, rdx, r8
    lea rsi, [snd_text]
.device:
    xor edi, edi
    call rec_str
    mov esi, [hda_outs]
    cmp qword [hda_sd], 0
    jne .outs
    xor esi, esi
.outs:
    mov edi, 1
    call rec_set
    mov esi, [snd_volume]
    mov edi, 2
    call rec_set
    mov esi, [snd_count]
    mov edi, 3
    call rec_set
    mov rax, [snd_played]               ; frames, as microseconds
    mov ecx, 1000
    mul rcx
    mov ecx, SND_RATE / 1000
    div rcx
    mov rsi, rax
    mov edi, 4
    call rec_set
    mov rsi, [snd_dry]
    mov edi, 5
    call rec_set
    clc
    ret

; sound volume <0..100>
snd_cmd_volume:
    cmp edi, 1
    jne .usage
    mov rsi, [rsi]
    call arg_uint
    jc .usage
    cmp eax, 100
    ja .usage
    mov edi, eax
    call snd_volume_set
    jmp snd_show
.usage:
    KLOG "usage: sound volume <0..100>"
    stc
    ret

; sound tone [hz [ms]]: 440 Hz for half a second, unless said
snd_cmd_tone:
    mov r8d, 440
    mov r9d, 500
    cmp edi, 2
    ja .usage
    test edi, edi
    jz .play
    push rsi
    mov rsi, [rsi]
    call arg_uint
    pop rsi
    jc .usage
    lea ecx, [rax - 20]                 ; 20 Hz to 20 kHz
    cmp ecx, 20000 - 20
    ja .usage
    mov r8d, eax
    cmp edi, 2
    jne .play
    mov rsi, [rsi + 8]
    call arg_uint
    jc .usage
    lea ecx, [rax - 1]                  ; up to a minute
    cmp ecx, 60000
    jae .usage
    mov r9d, eax
.play:
    mov edi, r8d
    mov esi, r9d
    call snd_tone_start
    KLOG "sound: a tone, %u Hz for %u ms", r8, r9
    clc
    ret
.usage:
    KLOG "usage: sound tone [20..20000 Hz [1..60000 ms]]"
    stc
    ret

; sound test: frames played in a fifth of a second, which at 48 kHz is 9600
snd_cmd_test:
    push rbx
    mov rbx, [snd_played]
    mov edi, 200000
    call thread_sleep_us
    mov rax, [snd_played]
    sub rax, rbx
    mov rcx, rax
    lea rsi, [str_snd_hda]
    cmp qword [hda_sd], 0
    jne .say
    lea rsi, [str_snd_clock]
.say:
    lea eax, [rcx - 9600 + 480]         ; within 5%
    cmp eax, 960
    jae .off
    KLOG "sound test: ok, %u frames in 200 ms, by %s", rcx, rsi
    clc
    pop rbx
    ret
.off:
    KLOG "sound test: FAILED, %u frames in 200 ms, by %s (9600 expected)", rcx, rsi
    clc
    pop rbx
    ret

section .data
align 8
snd_actions:
    ACTION  '',       snd_show,       '', 'the sound device, its volume, the streams playing'
    ACTION  'volume', snd_cmd_volume, '<0..100>', 'the volume of all sound'
    ACTION  'tone',   snd_cmd_tone,   '[hz [ms]]', 'a test tone: 440 Hz for half a second unless said', 0
    ACTION  'test',   snd_cmd_test,   '', 'frames played in a fifth of a second: 9600 at 48 kHz', 0
    dq 0, 0, 0, 0, 0

section .rodata
str_ot_sound:   db 'sound', 0
str_ot_stream:  db 'stream', 0
str_snd_thread: db 'sound', 0
str_snd_mem:    db 'sound stream', 0
str_snd_none:   db 'none: played to nothing', 0
str_snd_hda:    db 'the controller', 0
str_snd_clock:  db 'the clock', 0
str_rt_play:    db 'play', 0
align 8
rt_names_sound: dq str_rt_dup, str_rt_give, str_rt_info, 0, 0, 0, 0, 0
                dq str_rt_play, 0, 0, 0, 0, 0, 0, 0

section .bss
alignb 8
snd_buf:        resq 1                  ; what the controller plays, SND_BUF bytes
snd_thread:     resq 1
snd_streams:    resq 1                  ; open streams
snd_tick:       resq 1                  ; TSC ticks between fills
snd_t0:         resq 1                  ; when the thread began (for the clock)
snd_played:     resq 1                  ; frames mixed, in all
snd_dry:        resq 1                  ; times the controller caught up
snd_tone_x:     resq 1
snd_tone_y:     resq 1
snd_tone_e:     resq 1
snd_lock:       resd 1
snd_count:      resd 1
snd_w:          resd 1                  ; the frame mixed into next
snd_lead:       resd 1
snd_volume:     resd 1                  ; 0..100
snd_gain:       resd 1                  ; from it, 65536 = as written
snd_tone_n:     resd 1                  ; the tone's frames left
snd_tone_t:     resd 1                  ; and played
snd_text:       resb 64
alignb 16
snd_acc:        resd SND_LEAD * 2       ; a left and a right sum each frame
