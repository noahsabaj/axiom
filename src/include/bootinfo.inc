; =============================================================================
;  bootinfo.inc - the contract between the UEFI loader and the kernel
; =============================================================================

KERNEL_BASE     equ 0xFFFFFFFF80000000  ; kernel image (top 2 GiB: disp32-addressable)
PHYS_BASE       equ 0xFFFF800000000000  ; direct map of physical memory
FB_VIRT         equ 0xFFFFFFFF00000000  ; framebuffer, write-combining

BOOT_STACK_SIZE equ 0x10000             ; BSP stack the loader hands over
MSR_PAT         equ 0x277
PAT_VALUE_LO    equ 0x00070406          ; PA0..PA3 = WB, WT, UC-, UC (reset values)
PAT_VALUE_HI    equ 0x00070501          ; PA4..PA7 = WC, WP, UC-, UC

; kernel image header: the first 32 bytes of kernel.bin
KH_MAGIC        equ 0                   ; 'AXIOMKRN'
KH_ENTRY        equ 8                   ; virtual address of kernel_main
KH_FILE_SIZE    equ 16                  ; bytes stored in kernel.bin
KH_MEM_SIZE     equ 24                  ; bytes including .bss, page multiple

; boot information block, filled by the loader
BI_MAGIC        equ 0                   ; 'AXIOMBI1'
BI_FB_PHYS      equ 8                   ; framebuffer physical base
BI_FB_SIZE      equ 16                  ; framebuffer bytes
BI_FB_WIDTH     equ 24                  ; dword, pixels
BI_FB_HEIGHT    equ 28                  ; dword, pixels
BI_FB_PITCH     equ 32                  ; dword, pixels per scanline
BI_FB_FORMAT    equ 36                  ; dword: 0 = R,G,B,x bytes  1 = B,G,R,x bytes
BI_MMAP         equ 40                  ; physical address of the final UEFI memory map
BI_MMAP_SIZE    equ 48                  ; bytes
BI_MMAP_DSIZE   equ 56                  ; bytes per descriptor
BI_RSDP         equ 64                  ; ACPI RSDP physical address
BI_SMBIOS3      equ 72                  ; SMBIOS 3.x entry point, 0 if none
BI_SMBIOS2      equ 80                  ; SMBIOS 2.x entry point, 0 if none
BI_TSC_HZ       equ 88                  ; TSC frequency, calibrated against Stall()
BI_TSC_ENTRY    equ 96                  ; TSC when the loader started
BI_TSC_EXIT     equ 104                 ; TSC just before ExitBootServices
BI_PML4         equ 112                 ; physical address of the PML4 (below 4 GiB)
BI_PHYS_TOP     equ 120                 ; bytes covered by the direct map
BI_RUNTIME      equ 128                 ; EFI_RUNTIME_SERVICES (identity-mapped)
BI_FW_REV       equ 136                 ; dword firmware revision
BI_UEFI_REV     equ 140                 ; dword UEFI specification revision
BI_GOP_MODES    equ 144                 ; dword number of GOP modes
BI_GOP_MODE     equ 148                 ; dword mode in use
BI_RESV_COUNT   equ 152                 ; loader allocations the kernel must keep
BI_RESV         equ 160                 ; BI_RESV_MAX x { qword phys, qword bytes }
BI_RESV_MAX     equ 16
BI_FW_VENDOR    equ 416                 ; 64-byte ASCII firmware vendor
BI_BOOT_SERIAL  equ 480                 ; dword FAT volume serial of the boot volume
BI_BOOT_FS      equ 484                 ; dword: 32 FAT32, 16 FAT16, 0 unknown
BI_RUN          equ 488                 ; a test run's script (AxiomRun), physical; 0 if none or unread
BI_RUN_SIZE     equ 496                 ; dword: its bytes; 0 if this is no test run
BI_TCO          equ 500                 ; word: I/O base of the TCO watchdog the loader started, or 0
BI_TCO_STS      equ 502                 ; word: TCO2_STS as found (bit 1: the watchdog reset the
                                        ; machine); bit 15: its NO_REBOOT is locked on
BI_SLOT         equ 504                 ; byte: the kernel started, from a slot ('A', 'B'), or 0:
                                        ; the one built into the loader
BI_TRIAL        equ 505                 ; byte: 1 if it is on trial (AxiomTry named it)
BI_SLOT_TRY     equ 506                 ; byte: the slot AxiomTry named for a trial, or 0
BI_SLOT_ERR     equ 507                 ; byte: why a slot was passed over (SLOT_*): bits 3:0
                                        ; AxiomTry's, bits 7:4 AxiomSlot's
BI_TRIAL_S      equ 508                 ; word: the seconds AxiomTry gives the trial (0: unsaid)
BI_EXT          equ 510                 ; word: the block's bytes as the loader filled it (its
                                        ; BI_SIZE); 0 from a loader whose block was 512 bytes
BI_SETTINGS     equ 512                 ; SETTINGS.TXT from that volume (physical), 0 if none
BI_SETTINGS_LEN equ 520                 ; its bytes (at most 8 KiB)
BI_TSC_DISPLAY  equ 528                 ; TSC: the display's mode set
BI_TSC_CALIB    equ 536                 ; TSC: the config tables, the boot volume, the TSC
BI_TSC_TABLES   equ 544                 ; TSC: the kernel copied, its page tables built
BI_SIZE         equ 552

; A/B updates (src/kernel/update.asm): kernels in /EFI/AXIOM/KERNEL.A and
; KERNEL.B on the boot volume. The UEFI variables AxiomTry (a trial, once)
; and AxiomSlot (the kept one) name one each, in UV_BYTES:
UV_SLOT         equ 0                   ; byte: 'A' or 'B'; AxiomTry's made small once tried
UV_TRIAL        equ 2                   ; word: seconds the trial has to be kept (AxiomTry)
UV_SIZE         equ 4                   ; dword: the file's bytes
UV_HASH         equ 8                   ; qword: its FNV-1a hash (64-bit)
UV_BYTES        equ 16
SLOT_MAX        equ 32 * 1024 * 1024    ; the most a slot's file may hold
SLOT_MEM_MAX    equ 1024 * 1024 * 1024  ; and the most memory its kernel may ask for
SLOT_OK         equ 0
SLOT_MISSING    equ 1                   ; no file, or it could not be read
SLOT_DAMAGED    equ 2                   ; not a kernel, or not the size or hash the variable says
SLOT_UNMARKED   equ 3                   ; AxiomTry could not be marked tried, so no trial
FNV_BASIS       equ 0xCBF29CE484222325
FNV_PRIME       equ 0x100000001B3

; Axiom's UEFI variables (AxiomRun, AxiomLog, AxiomTry, AxiomSlot) are under this vendor GUID:
; 8b367f3b-9403-4cf2-81cd-bda84a771936 (tools/hw/hp1.py)
%macro AXIOM_VENDOR_GUID 0
    dd 0x8B367F3B
    dw 0x9403, 0x4CF2
    db 0x81, 0xCD, 0xBD, 0xA8, 0x4A, 0x77, 0x19, 0x36
%endmacro
RUN_MAX         equ 8192                ; the most a test run's script may hold, its NUL too
