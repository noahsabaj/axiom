; =============================================================================
;  tone.asm - a sine through a stream of sound, as a program plays. It
;  opens a stream on the speakers and maps its memory, writes frames while
;  there is room, waits on the stream (RO_WAIT) for more room, and once all
;  are written waits for them to be played.
;
;    tone [hz [ms]]      1000 Hz for a second unless said
; =============================================================================

%include "axe.inc"
WANTS AW_SOUND

TONE_AMP        equ 16384 << 12         ; its peak, -6 dB, << 12
TONE_FRAMES     equ 4096                ; the stream's ring

main:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov rbx, rdi
    lea rsi, [rbx + SB_ARGS]
    mov r12d, 1000                      ; R12D = hertz
    call number
    jc .ms
    mov r12d, eax
.ms:
    mov r13d, 1000                      ; R13D = milliseconds
    call number
    jc .args
    mov r13d, eax
.args:
    lea eax, [r12 - 20]
    cmp eax, 20000 - 20
    ja .usage
    lea eax, [r13 - 1]
    cmp eax, 60000
    jae .usage
    mov edi, [ax_sound]
    lea rsi, [s_none]
    test edi, edi
    jz .say
    mov esi, TONE_FRAMES
    mov eax, SYS_SOUND_NEW
    syscall
    lea rsi, [s_refused]
    test rax, rax
    js .say
    mov [stream], eax
    mov edi, edx
    mov eax, SYS_MAP
    syscall
    lea rsi, [s_refused]
    test rax, rax
    js .say
    mov r14, rax                        ; R14 = the stream's header, its frames after
    lea rsi, [s_open]
    call ax_add
    mov edi, [r14 + SN_FRAMES]
    call ax_addu
    lea rsi, [s_frames_of]
    call ax_add
    call ax_flush
    imul r15d, r13d, 48                 ; R15D = frames to write
    mov [frames], r15d
    imul rax, r12, 562210               ; e = 2 pi f / 48000, << 16
    shr rax, 16
    mov [e], rax
    mov qword [x], TONE_AMP
.fill:
    test r15d, r15d
    jz .written
    mov eax, [r14 + SN_WRITE]           ; room: what is not waiting
    sub eax, [r14 + SN_READ]
    mov ecx, [r14 + SN_FRAMES]
    sub ecx, eax
    jnz .room
    call wait_stream                    ; until no more than SN_LOW wait
    jc .stopped
    jmp .fill
.room:
    cmp ecx, r15d
    cmova ecx, r15d
    sub r15d, ecx
    mov edx, [r14 + SN_WRITE]
    mov r8, [x]
    mov r9, [y]
    mov r10, [e]
.frame:
    mov rax, r9                         ; x -= e * y, y += e * x
    imul rax, r10
    sar rax, 16
    sub r8, rax
    mov rax, r8
    imul rax, r10
    sar rax, 16
    add r9, rax
    mov rax, r9
    sar rax, 12
    mov edi, [r14 + SN_FRAMES]
    dec edi
    and edi, edx
    mov [r14 + SN_DATA + rdi * 4], ax   ; left and right
    mov [r14 + SN_DATA + rdi * 4 + 2], ax
    inc edx
    dec ecx
    jnz .frame
    mov [x], r8
    mov [y], r9
    mov [r14 + SN_WRITE], edx           ; the frames, then that they are there
    jmp .fill
.written:
    mov eax, [r14 + SN_SHORT]           ; dry while it played
    mov [dry], eax
    mov dword [r14 + SN_LOW], 0         ; until every one is taken
.drain:
    mov eax, [r14 + SN_WRITE]
    cmp eax, [r14 + SN_READ]
    je .played
    call wait_stream
    jc .stopped
    jmp .drain
.played:
    lea rsi, [s_played]
    call ax_add
    mov edi, r12d
    call ax_addu
    lea rsi, [s_hz]
    call ax_add
    mov edi, r13d
    call ax_addu
    lea rsi, [s_ms]
    call ax_add
    mov edi, [frames]
    call ax_addu
    lea rsi, [s_frames]
    call ax_add
    mov edi, [dry]
    call ax_addu
    lea rsi, [s_short]
    call ax_add
    call ax_flush
    xor eax, eax
    jmp .out
.stopped:
    lea rsi, [s_stopped]
    jmp .say
.usage:
    lea rsi, [s_usage]
.say:
    call ax_puts
    mov eax, 1
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; wait_stream -> CF if the stream did not move within two seconds
wait_stream:
    sub rsp, SQ_SIZE
    mov rdi, rsp
    xor eax, eax
    mov ecx, SQ_SIZE / 8
    rep stosq
    mov byte [rsp + SQ_OP], RO_WAIT
    mov eax, [stream]
    mov [rsp + SQ_HANDLE], eax
    mov edi, 2000000
    call ax_us
    push rax
    call ax_now
    pop rcx
    add rax, rcx
    mov [rsp + SQ_DEADLINE], rax
    mov rdi, rsp
    call ax_do
    add rsp, SQ_SIZE
    test rax, rax
    jz .out
    stc
.out:
    ret

; number(RSI = text) -> EAX = the decimal number next in it, RSI past it;
; CF if there is none
number:
.space:
    cmp byte [rsi], ' '
    jne .digits
    inc rsi
    jmp .space
.digits:
    xor eax, eax
    xor ecx, ecx
.digit:
    movzx edx, byte [rsi]
    sub edx, '0'
    cmp edx, 9
    ja .end
    imul eax, eax, 10
    add eax, edx
    inc rsi
    inc ecx
    cmp ecx, 9
    jb .digit
.end:
    test ecx, ecx
    jnz .out
    stc
.out:
    ret

section .rodata
s_played:       db 'tone: ', 0
s_open:         db 'tone: a stream of ', 0
s_frames_of:    db ' frames, playing', 0
s_hz:           db ' Hz for ', 0
s_ms:           db ' ms, ', 0
s_frames:       db ' frames played, ', 0
s_short:        db ' short', 0
s_none:         db 'tone: no speakers to play to (+sound gives them)', 0
s_refused:      db 'tone: no stream of sound', 0
s_stopped:      db 'tone: the stream stopped playing', 0
s_usage:        db 'usage: tone [20..20000 Hz [1..60000 ms]]', 0

section .bss
alignb 8
x:              resq 1
y:              resq 1
e:              resq 1
stream:         resd 1
frames:         resd 1
dry:            resd 1

AXE_END
