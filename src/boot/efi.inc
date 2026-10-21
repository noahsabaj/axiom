; =============================================================================
;  efi.inc - the slice of the UEFI 2.x ABI the loader uses (x64 offsets)
; =============================================================================

EFI_SUCCESS             equ 0
EFI_LOAD_ERROR          equ 0x8000000000000001
EFI_BUFFER_TOO_SMALL    equ 0x8000000000000005

; EFI_TABLE_HEADER
HDR_REVISION            equ 8

; EFI_SYSTEM_TABLE
ST_FW_VENDOR            equ 24
ST_FW_REVISION          equ 32
ST_CONOUT               equ 64
ST_RUNTIME              equ 88
ST_BOOT                 equ 96
ST_CONFIG_COUNT         equ 104
ST_CONFIG_TABLE         equ 112
CONFIG_ENTRY_SIZE       equ 24          ; GUID + pointer

; EFI_BOOT_SERVICES
BS_ALLOCATE_PAGES       equ 40
BS_FREE_PAGES           equ 48
BS_GET_MEMORY_MAP       equ 56
BS_FREE_POOL            equ 72
BS_HANDLE_PROTOCOL      equ 152
BS_EXIT_BOOT_SERVICES   equ 232
BS_STALL                equ 248
BS_SET_WATCHDOG         equ 256
BS_LOCATE_PROTOCOL      equ 320

; EFI_RUNTIME_SERVICES
RT_GET_VARIABLE         equ 72
RT_SET_VARIABLE         equ 88
EFI_VAR_NV_BS_RT        equ 7           ; non-volatile, boot and runtime access

ALLOCATE_ANY_PAGES      equ 0
ALLOCATE_MAX_ADDRESS    equ 1
EFI_LOADER_DATA         equ 2

; EFI_LOADED_IMAGE_PROTOCOL
LI_DEVICE_HANDLE        equ 24
; EFI_BLOCK_IO_PROTOCOL and its EFI_BLOCK_IO_MEDIA
BIO_MEDIA               equ 8
BIO_READ_BLOCKS         equ 24
BM_MEDIA_ID             equ 0
BM_BLOCK_SIZE           equ 12
; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL, and EFI_FILE_PROTOCOL
SFS_OPEN_VOLUME         equ 8
FILE_OPEN               equ 8
FILE_CLOSE              equ 16
FILE_READ               equ 32
FILE_SET_POSITION       equ 56
EFI_FILE_MODE_READ      equ 1

; EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL
CON_OUTPUT_STRING       equ 8

; EFI_SIMPLE_FILE_SYSTEM_PROTOCOL and EFI_FILE_PROTOCOL
SFS_OPEN_VOLUME         equ 8
FP_OPEN                 equ 8
FP_CLOSE                equ 16
FP_READ                 equ 32
EFI_FILE_MODE_READ      equ 1

; EFI_GRAPHICS_OUTPUT_PROTOCOL
GOP_QUERY_MODE          equ 0
GOP_SET_MODE            equ 8
GOP_MODE                equ 24
; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE
GM_MAX_MODE             equ 0
GM_MODE                 equ 4
GM_INFO                 equ 8
GM_FB_BASE              equ 24
GM_FB_SIZE              equ 32
; EFI_GRAPHICS_OUTPUT_MODE_INFORMATION
GI_WIDTH                equ 4
GI_HEIGHT               equ 8
GI_FORMAT               equ 12          ; 0 RGBx, 1 BGRx, 2 bitmask, 3 blt-only
GI_PITCH                equ 32

; EFI_MEMORY_DESCRIPTOR
MD_TYPE                 equ 0
MD_PHYS                 equ 8
MD_PAGES                equ 24
MT_MMIO                 equ 11
MT_MMIO_PORT            equ 12
