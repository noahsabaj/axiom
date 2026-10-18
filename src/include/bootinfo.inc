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
BI_TSC_DISPLAY  equ 488                 ; TSC: the display's mode set
BI_TSC_CALIB    equ 496                 ; TSC: the config tables, the boot volume, the TSC
BI_TSC_TABLES   equ 504                 ; TSC: the kernel copied, its page tables built
BI_SIZE         equ 512
