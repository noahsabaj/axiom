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
; the scheduler's part (sched.asm)
PC_CURRENT      equ 256                 ; the thread running here
PC_IDLE_TH      equ 264                 ; this CPU's idle thread
PC_RQ           equ 272                 ; threads ready to run, least run first
PC_SLEEPQ       equ 280                 ; parked with a deadline, soonest first
PC_RQ_LOCK      equ 288                 ; dword: both queues
PC_RQ_LEN       equ 292                 ; dword: threads on the run queue
PC_BUSY         equ 296                 ; dword: 1 while a thread other than idle runs
PC_RESCHED      equ 300                 ; byte: switch on the way out of the interrupt
PC_SCHED_ON     equ 301                 ; byte: this CPU takes threads
PC_SKIND        equ 304                 ; the kind the scheduler goes by (CPU_KIND_*)
PC_SIBLING      equ 312                 ; its SMT sibling's index, or -1
PC_MIN_VR       equ 320                 ; the least virtual runtime here, never falls
PC_SLICE_END    equ 328                 ; TSC: the running thread's slice ends
PC_TIMER_AT     equ 336                 ; TSC: what the timer is set for, 0 = off
PC_LAST_TSC     equ 344                 ; TSC: time counted up to here
PC_BUSY_CYC     equ 352                 ; TSC cycles running threads
PC_IDLE_CYC     equ 360                 ; and idle
PC_SWITCHES     equ 368
PC_STEALS       equ 376                 ; threads taken from other queues
PC_PUSHES       equ 384                 ; threads handed to other CPUs
PC_PUSH_TO      equ 392                 ; -1, or where the running thread should go
PC_WORKER       equ 400                 ; the job worker thread (APs)
PC_BALANCE_AT   equ 408                 ; TSC: look for a better core, 0 = no need
PC_PUSH_WHO     equ 416                 ; the thread PC_PUSH_TO is for
PC_WANTS        equ 424                 ; the kind of core the running thread wants, if not this
PC_CUR_VR       equ 432                 ; the running thread's vruntime when last counted
PC_SIZE         equ 512

CPU_KIND_UNKNOWN equ 0
CPU_KIND_P       equ 1                  ; performance core
CPU_KIND_E       equ 2                  ; efficient core

; a thread (sched.asm)
TH_RSP          equ 0                   ; saved stack pointer, while not running
TH_STATE        equ 8                   ; dword TS_*
TH_ONCPU        equ 12                  ; dword: a CPU is on its stack
TH_CPU          equ 16                  ; the CPU it runs or waits on
TH_PIN          equ 24                  ; -1, or the only CPU it may run on
TH_CLASS        equ 32                  ; THC_*: the kind of core it wants
TH_NEXT         equ 40                  ; run queue, sleep queue or zombie link
TH_VR           equ 48                  ; virtual runtime (relative while parked)
TH_WAKE_AT      equ 56                  ; TSC deadline while parked with one
TH_TOKEN        equ 64                  ; dword: an unpark came while not parked
TH_WOKEN        equ 68                  ; dword: the last park ended by unpark
TH_ID           equ 72
TH_STACK        equ 80                  ; its stack's vm mapping, 0 if borrowed
TH_STACK_TOP    equ 88
TH_XSAVE        equ 96                  ; its SIMD state, 64-byte aligned
TH_ALL_NEXT     equ 104                 ; every thread, for listings
TH_ALL_PREV     equ 112
TH_RUN_TSC      equ 120                 ; when it last started running
TH_CYC_P        equ 128                 ; TSC cycles run on P-cores
TH_CYC_E        equ 136                 ; on E-cores
TH_CYC_O        equ 144                 ; on cores of no known kind
TH_SWITCHES     equ 152                 ; times it was switched to
TH_MIGRATIONS   equ 160                 ; times it ran on a different CPU
TH_FLAGS        equ 168                 ; TF_*
TH_REFS         equ 176                 ; dword: its own, and its handle's
TH_EXIT         equ 184                 ; what it returned
TH_JOINER       equ 192                 ; the thread waiting in thread_join
TH_HINT         equ 200                 ; -1, or the CPU to start on (tests)
TH_LAST         equ 208                 ; the CPU it last ran on, -1 if none
TH_NAME         equ 216
TH_NAME_LEN     equ 24
TH_SIZE         equ 256

TS_NEW          equ 0
TS_READY        equ 1
TS_RUNNING      equ 2
TS_PARKED       equ 3
TS_DEAD         equ 4

THC_ANY         equ 0                   ; any core, P-cores a little sooner
THC_PERF        equ 1                   ; wants a P-core
THC_EFF         equ 2                   ; wants an E-core

TF_IDLE         equ 1
TF_MAIN         equ 2
TF_WORKER       equ 4

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
VEC_RESCHED     equ 0x42
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
MSR_TSC_DEADLINE equ 0x6E0
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
