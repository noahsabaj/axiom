; =============================================================================
;  rusthost.inc - for a host test shim (nasm -f win64) that assembles kernel
;  files calling the kernel's Rust: FORWARD name makes name a jump through
;  name_at, exported (through .drectve, so a DLL whose C code names its own
;  exports has it too), which the test points at the Rust's own name in the
;  Rust built for the host (tools/test/rusthost.py).
; =============================================================================

%macro FORWARD 1
global %1_at
[section .text]
%1:
    jmp [%1_at]
[section .bss]
%1_at:          resq 1
[section .drectve info]                 ; exported even beside C's dllexports
    db " -export:", %str(%1), "_at,data"
__?SECT?__
%endmacro
