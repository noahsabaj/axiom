; =============================================================================
;  macros.inc
;
;  Kernel calling convention (System V style):
;    arguments  RDI, RSI, RDX, RCX, R8, R9      result  RAX
;    preserved  RBX, RBP, R12-R15               scratch everything else
;  Functions documented "preserves all" keep every register except flags.
;  Interrupt handlers use general-purpose registers only, never SIMD.
; =============================================================================

; KLOG "format", args... -> formatted line to the serial log and the console.
; Arguments are pushed as qwords: 64-bit registers, immediates, or qword [mem].
; Do not pass RSP-relative operands. Preserves all registers.
%macro KLOG 1-*
    [section .rodata]
    %%fmt: db %1, 10, 0
    __SECT__
    %assign %%n %0 - 1
    %rep %%n
        %rotate -1
        push %1
    %endrep
    push rsi
    push rdx
    lea rsi, [%%fmt]
    lea rdx, [rsp + 16]
    call kprint
    pop rdx
    pop rsi
    %if %%n > 0
        lea rsp, [rsp + %%n * 8]
    %endif
%endmacro

; SPRINTF buffer, "format", args... -> RAX = length. Preserves other registers.
%macro SPRINTF 2-*
    [section .rodata]
    %%fmt: db %2, 0
    __SECT__
    %assign %%n %0 - 2
    %rep %%n
        %rotate -1
        push %1
    %endrep
    %rotate -2
    push rdi
    push rsi
    push rdx
    lea rdi, [%1]
    lea rsi, [%%fmt]
    lea rdx, [rsp + 24]
    call format
    pop rdx
    pop rsi
    pop rdi
    %if %%n > 0
        lea rsp, [rsp + %%n * 8]
    %endif
%endmacro

; CSTR label, "text" -> NUL-terminated string in .rodata
%macro CSTR 2
    [section .rodata]
    %1: db %2, 0
    __SECT__
%endmacro

%macro RDTSC64 0                        ; RAX = TSC, clobbers RDX
    rdtsc
    shl rdx, 32
    or rax, rdx
%endmacro
