; =============================================================================
;  defs.inc - kernel-wide constants and structure layouts
; =============================================================================

AXIOM_VERSION   equ 1                   ; 0.1

MAX_CPUS        equ 256
KSTACK_SIZE     equ 0x10000             ; 64 KiB kernel stack per CPU
IST_SIZE        equ 0x4000              ; 16 KiB per interrupt stack

; per-CPU block: one per logical processor, reached through GS
PC_SELF         equ 0
PC_INDEX        equ 8
PC_APIC_ID      equ 16
PC_KIND         equ 24                  ; CPU_KIND_*
PC_STACK_TOP    equ 32
PC_ONLINE       equ 40
PC_JOB_GEN      equ 48                  ; last job generation this CPU ran
PC_JOB_ITEMS    equ 56                  ; work items done in the last job
PC_JOB_CYCLES   equ 64                  ; TSC cycles spent working in the last job
PC_ITERS        equ 72                  ; escape-time iterations in the last job
PC_MHZ          equ 80                  ; effective MHz from APERF/MPERF, 0 = unknown
PC_TEMP         equ 88                  ; degrees C from the digital sensor, 0 = unknown
PC_APERF        equ 96
PC_MPERF        equ 104
PC_CORE         equ 112                 ; core number within its kind
PC_THREAD       equ 120                 ; SMT thread within the core
PC_TSS          equ 128                 ; 104-byte TSS
PC_TLB_GEN      equ 232                 ; last TLB shootdown this CPU answered
PC_SIZE         equ 256

CPU_KIND_UNKNOWN equ 0
CPU_KIND_P       equ 1                  ; performance core
CPU_KIND_E       equ 2                  ; efficient core

; 64-bit TSS
TSS_RSP0        equ 4
TSS_IST1        equ 36
TSS_IST2        equ 44
TSS_IST3        equ 52
TSS_IOPB        equ 102
TSS_LIMIT       equ 103

; GDT selectors
SEL_KCODE       equ 0x08
SEL_KDATA       equ 0x10
SEL_TSS0        equ 0x28                ; CPU n uses SEL_TSS0 + 16 * n

; interrupt vectors
VEC_KBD         equ 0x21
VEC_USB         equ 0x22
VEC_NET         equ 0x23
VEC_TIMER       equ 0x30
VEC_WAKE        equ 0x40
VEC_TLB         equ 0x41
VEC_SPURIOUS    equ 0xFF

; interrupt frame built by isr_common (offsets from the frame pointer)
FR_R15          equ 0
FR_R14          equ 8
FR_R13          equ 16
FR_R12          equ 24
FR_R11          equ 32
FR_R10          equ 40
FR_R9           equ 48
FR_R8           equ 56
FR_RBP          equ 64
FR_RDI          equ 72
FR_RSI          equ 80
FR_RDX          equ 88
FR_RCX          equ 96
FR_RBX          equ 104
FR_RAX          equ 112
FR_VECTOR       equ 120
FR_ERROR        equ 128
FR_RIP          equ 136
FR_CS           equ 144
FR_RFLAGS       equ 152
FR_RSP          equ 160
FR_SS           equ 168

; model-specific registers
MSR_APIC_BASE   equ 0x1B
MSR_MPERF       equ 0xE7
MSR_APERF       equ 0xE8
MSR_THERM_STATUS equ 0x19C
MSR_TEMP_TARGET equ 0x1A2
MSR_RAPL_UNIT   equ 0x606
MSR_PKG_ENERGY  equ 0x611
MSR_PM_ENABLE   equ 0x770
MSR_HWP_CAPS    equ 0x771
MSR_HWP_REQUEST equ 0x774
MSR_EFER        equ 0xC0000080
MSR_GS_BASE     equ 0xC0000101
MSR_KGS_BASE    equ 0xC0000102

; UEFI memory types
MT_RESERVED     equ 0
MT_LOADER_CODE  equ 1
MT_LOADER_DATA  equ 2
MT_BS_CODE      equ 3
MT_BS_DATA      equ 4
MT_RT_CODE      equ 5
MT_RT_DATA      equ 6
MT_CONVENTIONAL equ 7
MT_ACPI_RECLAIM equ 9
MT_ACPI_NVS     equ 10
MT_MMIO         equ 11

; palette (0xRRGGBB; the framebuffer stores B,G,R,x)
COL_BG          equ 0x0A0D13
COL_PANEL       equ 0x10151F
COL_PANEL2      equ 0x161C29
COL_LINE        equ 0x232B3B
COL_TEXT        equ 0xE6EDF3
COL_DIM         equ 0x7D8796
COL_FAINT       equ 0x4A5262
COL_ACCENT      equ 0x5EEAD4
COL_BLUE        equ 0x7AA2F7
COL_PCORE       equ 0xF5A524
COL_ECORE       equ 0x38BDF8
COL_GOOD        equ 0x3FB950
COL_WARN        equ 0xE3B341
COL_BAD         equ 0xF85149
COL_PANIC_BG    equ 0x2A0A10
