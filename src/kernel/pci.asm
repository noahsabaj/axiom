; =============================================================================
;  pci.asm - enumerate PCI Express functions through ECAM (legacy CF8/CFC
;  ports when the firmware gives no MCFG) and name what we find
; =============================================================================

MAX_PCI         equ 128
PCI_ENTRY       equ 16                  ; bytes per recorded function
; entry layout
PE_BUS          equ 0
PE_DEV          equ 1
PE_FN           equ 2
PE_HDR          equ 3
PE_VENDOR       equ 4                   ; word
PE_DEVICE       equ 6                   ; word
PE_CLASS        equ 8
PE_SUBCLASS     equ 9
PE_PROGIF       equ 10
PE_REV          equ 11
PE_SEG          equ 12                  ; 1: behind a VMD (vmd.asm)

section .text

; pci_read32(EDI = bus << 8 | dev << 3 | fn, ESI = register offset) -> EAX
; Preserves others.
pci_read32:
    push rcx
    push rdx
    test edi, VMD_SEG
    jnz .vmd
    cmp byte [pci_use_ecam], 0
    je .legacy
    mov eax, edi
    shl eax, 12
    or eax, esi
    add rax, [pci_ecam_virt]
    mov eax, [rax]
    jmp .out
.legacy:
    mov eax, edi
    shl eax, 8
    mov ecx, esi
    and ecx, 0xFC
    or eax, ecx
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    in eax, dx
    jmp .out
.vmd:
    call vmd_cfg
    jc .nothing
    mov eax, [rax]
    jmp .out
.nothing:
    mov eax, -1                         ; as an absent function answers
.out:
    pop rdx
    pop rcx
    ret

; pci_write32(EDI = bdf, ESI = offset, EDX = value). Preserves all.
pci_write32:
    push rax
    push rcx
    push rdx
    test edi, VMD_SEG
    jnz .vmd
    cmp byte [pci_use_ecam], 0
    je .legacy
    mov eax, edi
    shl eax, 12
    or eax, esi
    add rax, [pci_ecam_virt]
    mov [rax], edx
    jmp .out
.legacy:
    mov ecx, edx
    mov eax, edi
    shl eax, 8
    mov edx, esi
    and edx, 0xFC
    or eax, edx
    or eax, 0x80000000
    mov dx, 0xCF8
    out dx, eax
    mov dx, 0xCFC
    mov eax, ecx
    out dx, eax
    jmp .out
.vmd:
    call vmd_cfg
    jc .out
    mov [rax], edx
.out:
    pop rdx
    pop rcx
    pop rax
    ret

pci_init:
    push rbx
    push r12
    push r13
    push r14
    cmp dword [ecam_count], 0           ; segment 0 ECAM, if it is mapped
    je .scan
    mov rax, [ecam_base]
    mov rcx, rax
    add rcx, 256 << 20
    mov rdx, [boot_info]
    cmp rcx, [rdx + BI_PHYS_TOP]
    ja .scan
    add rax, [phys_base]
    mov [pci_ecam_virt], rax
    mov byte [pci_use_ecam], 1
    movzx eax, byte [ecam_bus_end]
    mov [pci_last_bus], eax
.scan:
    xor r12d, r12d                      ; bus
.bus:
    cmp r12d, [pci_last_bus]
    ja .done
    xor r13d, r13d                      ; device
.device:
    cmp r13d, 32
    jae .next_bus
    xor r14d, r14d                      ; function
.function:
    mov edi, r12d
    shl edi, 8
    mov eax, r13d
    shl eax, 3
    or edi, eax
    or edi, r14d
    xor esi, esi
    call pci_read32
    cmp ax, 0xFFFF
    je .absent
    mov ebx, eax                        ; vendor | device << 16
    mov esi, 0x0C
    call pci_read32
    shr eax, 16                         ; header type
    mov r8d, eax
    mov esi, 0x08
    call pci_read32                     ; class, subclass, prog-if, revision
    mov ecx, [pci_count]
    cmp ecx, MAX_PCI
    jae .recorded
    shl ecx, 4
    lea rdx, [pci_devices]
    add rdx, rcx
    mov [rdx + PE_BUS], r12b
    mov [rdx + PE_DEV], r13b
    mov [rdx + PE_FN], r14b
    mov [rdx + PE_HDR], r8b
    mov [rdx + PE_VENDOR], ebx          ; vendor and device
    mov [rdx + PE_REV], al
    shr eax, 8
    mov [rdx + PE_PROGIF], al
    shr eax, 8
    mov [rdx + PE_SUBCLASS], al
    shr eax, 8
    mov [rdx + PE_CLASS], al
    inc dword [pci_count]
.recorded:
    test r14d, r14d                     ; function 0 says whether 1-7 exist
    jnz .next_function
    test r8b, 0x80
    jz .next_device
.next_function:
    inc r14d
    cmp r14d, 8
    jb .function
.next_device:
    inc r13d
    jmp .device
.absent:
    test r14d, r14d
    jz .next_device
    jmp .next_function
.next_bus:
    inc r12d
    jmp .bus
.done:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; pci_find_class(EDI = class, ESI = subclass or -1) -> RAX = entry or 0
pci_find_class:
    xor ecx, ecx
    lea rdx, [pci_devices]
.next:
    cmp ecx, [pci_count]
    jae .none
    cmp [rdx + PE_CLASS], dil
    jne .skip
    cmp esi, -1
    je .found
    cmp [rdx + PE_SUBCLASS], sil
    je .found
.skip:
    add rdx, PCI_ENTRY
    inc ecx
    jmp .next
.found:
    mov rax, rdx
    ret
.none:
    xor eax, eax
    ret

; pci_bdf(RDI = entry) -> EAX = bus << 8 | dev << 3 | fn, and VMD_SEG for
; a function behind a VMD. Preserves others.
pci_bdf:
    movzx eax, byte [rdi + PE_SEG]
    shl eax, 8
    or al, [rdi + PE_BUS]
    shl eax, 5
    or al, [rdi + PE_DEV]
    shl eax, 3
    or al, [rdi + PE_FN]
    ret

; pci_mem_bar(EDI = bdf) -> RAX = the first memory BAR's address (64-bit
; BARs included), CF if there is none. Preserves others.
pci_mem_bar:
    push rcx
    push rsi
    mov esi, 0x10
.bar:
    call pci_read32
    test eax, 1                         ; I/O space
    jnz .next
    mov ecx, eax
    and eax, ~0xF
    and ecx, 6
    cmp ecx, 4                          ; 64-bit: the next dword is the top
    jne .low
    add esi, 4
    mov ecx, eax
    call pci_read32
    shl rax, 32
    or rax, rcx
.low:
    test rax, rax
    jnz .found
.next:
    add esi, 4
    cmp esi, 0x24
    jbe .bar
    stc
    jmp .out
.found:
    clc
.out:
    pop rsi
    pop rcx
    ret

; pci_power_on(EDI = bdf): out of D1-D3 into D0, if the function has the
; power-management capability and is not there yet. Preserves all.
pci_power_on:
    push rax
    push rdx
    push rsi
    mov esi, 0x01
    call pci_find_cap
    jc .out
    add esi, 4                          ; PMCSR
    call pci_read32
    test eax, 3
    jz .out
    mov edx, eax
    and edx, ~3
    call pci_write32
    push rdi
    mov edi, 10000                      ; D3hot -> D0 takes 10 ms
    call delay_us
    pop rdi
.out:
    pop rsi
    pop rdx
    pop rax
    ret

; pci_power_d3hot(EDI = bdf): bus mastering off, then D3hot, as Linux
; leaves a function before a restart (a driver's shutdown), if it has the
; power-management capability. Preserves all.
pci_power_d3hot:
    push rax
    push rdx
    push rsi
    mov esi, 0x04
    call pci_read32
    mov edx, eax
    and edx, 0xFFFF & ~(1 << 2)         ; the command, without Bus Master
    call pci_write32                    ;   (the status half written as 0)
    mov esi, 0x01
    call pci_find_cap
    jc .out
    add esi, 4                          ; PMCSR
    call pci_read32
    mov edx, eax
    and edx, ~(3 | (1 << 15))           ; (PME status kept)
    or edx, 3                           ; D3hot
    call pci_write32
.out:
    pop rsi
    pop rdx
    pop rax
    ret

; pci_find_cap(EDI = bdf, ESI = capability ID) -> ESI = its offset, CF if
; the function does not have it. Preserves others.
pci_find_cap:
    push rax
    push rcx
    mov ecx, esi
    mov esi, 0x04
    call pci_read32
    test eax, 1 << 20                   ; a capability list at all?
    jz .none
    mov esi, 0x34
    call pci_read32
    movzx esi, al
.cap:
    and esi, 0xFC
    jz .none
    call pci_read32
    cmp al, cl
    je .found
    movzx esi, ah
    jmp .cap
.found:
    clc
    jmp .out
.none:
    stc
.out:
    pop rcx
    pop rax
    ret

; pci_msi(EDI = bdf, ESI = vector) -> EAX = 2 MSI-X, 1 MSI, 0 neither (or the
; BSP's APIC ID needs interrupt remapping). One message, fixed and edge, to
; the BSP; MSI-X is preferred. Preserves others.
pci_msi:
    push rbx
    push rcx
    push rdx
    push rsi
    push r12
    push r13
    mov r12d, esi                       ; vector
    lea rax, [percpu]
    mov r13d, [rax + PC_APIC_ID]
    cmp r13d, 255
    ja .none
    shl r13d, 12
    or r13d, 0xFEE00000                 ; message address
    mov esi, 0x11                       ; MSI-X
    call pci_find_cap
    jnc .msix
    mov esi, 0x05                       ; MSI
    call pci_find_cap
    jc .none
    mov ebx, esi
    call pci_read32
    mov ecx, eax                        ; message control in the top half
    lea esi, [ebx + 4]
    mov edx, r13d
    call pci_write32
    lea esi, [ebx + 8]
    test ecx, 1 << 23                   ; 64-bit address?
    jz .data
    xor edx, edx
    call pci_write32
    lea esi, [ebx + 12]
.data:
    mov edx, r12d
    call pci_write32
    mov esi, ebx
    mov edx, ecx
    and edx, ~(7 << 20)                 ; one message
    or edx, 1 << 16                     ; enable
    call pci_write32
    mov eax, 1
    jmp .out

.msix:
    mov ebx, esi
    call pci_read32
    mov ecx, eax                        ; message control in the top half
    lea esi, [ebx + 4]
    call pci_read32                     ; table offset | BAR index
    mov edx, eax
    and edx, 7
    and eax, ~7
    push rax
    lea esi, [edx * 4 + 0x10]           ; that BAR, maybe 64-bit
    call pci_read32
    mov edx, eax
    and edx, ~0xF
    and eax, 6
    cmp eax, 4
    jne .bar32
    add esi, 4
    call pci_read32
    shl rax, 32
    or rdx, rax
.bar32:
    pop rax
    push rdi
    lea rdi, [rdx + rax]                ; entry 0 of the table
    mov esi, 16
    call mmio_map
    pop rdi
    test rax, rax
    jz .none
    mov [rax], r13d                     ; address
    mov dword [rax + 4], 0
    mov [rax + 8], r12d                 ; data
    mov dword [rax + 12], 0             ; unmasked
    mov esi, ebx
    mov edx, ecx
    and edx, ~(1 << 30)                 ; function mask off
    or edx, 1 << 31                     ; enable
    call pci_write32
    mov eax, 2
    jmp .out
.none:
    xor eax, eax
.out:
    pop r13
    pop r12
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; pci_describe(RDI = entry, RSI = 128-byte buffer): "Vendor device-name" or
; "Vendor class-name". Preserves RBX, R12-R15.
pci_describe:
    push rbx
    push r12
    mov rbx, rdi
    mov r12, rsi
    movzx eax, word [rbx + PE_VENDOR]
    call pci_vendor_name
    mov r8, rax
    movzx eax, word [rbx + PE_VENDOR]
    movzx ecx, word [rbx + PE_DEVICE]
    call pci_device_name
    test rax, rax
    jnz .named
    mov rdi, rbx
    call pci_class_name
.named:
    SPRINTF r12, "%s %s", r8, rax
    pop r12
    pop rbx
    ret

; pci_vendor_name(AX = vendor) -> RAX = name
pci_vendor_name:
    lea rdx, [pci_vendors]
.next:
    movzx ecx, word [rdx]
    test ecx, ecx
    jz .unknown
    cmp ecx, eax
    je .found
    add rdx, 10
    jmp .next
.found:
    mov rax, [rdx + 2]
    ret
.unknown:
    lea rax, [str_vendor_unknown]
    ret

; pci_device_name(EAX = vendor, ECX = device) -> RAX = name or 0
pci_device_name:
    lea rdx, [pci_known_devices]
    shl ecx, 16
    or eax, ecx
.next:
    mov ecx, [rdx]
    test ecx, ecx
    jz .unknown
    cmp ecx, eax
    je .found
    add rdx, 12
    jmp .next
.found:
    mov rax, [rdx + 4]
    ret
.unknown:
    xor eax, eax
    ret

; pci_class_name(RDI = entry) -> RAX = name
pci_class_name:
    movzx eax, byte [rdi + PE_CLASS]
    shl eax, 16
    mov ah, [rdi + PE_SUBCLASS]
    mov al, [rdi + PE_PROGIF]
    lea rdx, [pci_classes]
.next:
    mov ecx, [rdx]                      ; class << 16 | subclass << 8 | prog-if
    cmp ecx, -1
    je .found
    mov r9d, [rdx + 4]                  ; mask
    mov r10d, eax
    and r10d, r9d
    cmp r10d, ecx
    je .found
    add rdx, 16
    jmp .next
.found:
    mov rax, [rdx + 8]
    ret

section .rodata
str_vendor_unknown: db 'Unknown', 0
str_pci_other:  db 'device', 0

; the tables live in .data so the macros can put their names in .rodata
section .data
%macro VENDOR 2
    dw %1
    dq %%name
    [section .rodata]
    %%name: db %2, 0
    __SECT__
%endmacro
; vendor table entries are { word id, qword name }, 10 bytes
pci_vendors:
    VENDOR 0x8086, 'Intel'
    VENDOR 0x10DE, 'NVIDIA'
    VENDOR 0x10EC, 'Realtek'
    VENDOR 0x144D, 'Samsung'
    VENDOR 0x1022, 'AMD'
    VENDOR 0x1002, 'AMD'
    VENDOR 0x1B36, 'Red Hat'
    VENDOR 0x1234, 'QEMU'
    VENDOR 0x1AF4, 'virtio'
    VENDOR 0x15B7, 'WD'
    VENDOR 0x1987, 'Phison'
    VENDOR 0x1C5C, 'SK hynix'
    VENDOR 0x1E0F, 'KIOXIA'
    VENDOR 0x2646, 'Kingston'
    VENDOR 0x126F, 'Silicon Motion'
    VENDOR 0x14E4, 'Broadcom'
    VENDOR 0x168C, 'Qualcomm Atheros'
    VENDOR 0x17CB, 'Qualcomm'
    VENDOR 0x1B21, 'ASMedia'
    VENDOR 0x1D6A, 'Aquantia'
    dw 0

%macro DEVICE 3
    dw %1, %2
    dq %%name
    [section .rodata]
    %%name: db %3, 0
    __SECT__
%endmacro
; known devices: { word vendor, word device, qword name }, 12 bytes
pci_known_devices:
    DEVICE 0x10DE, 0x2803, 'GeForce RTX 4060 Ti'
    DEVICE 0x10DE, 0x2805, 'GeForce RTX 4060 Ti 16 GB'
    DEVICE 0x10DE, 0x2882, 'GeForce RTX 4060'
    DEVICE 0x10DE, 0x2786, 'GeForce RTX 4070'
    DEVICE 0x10DE, 0x22BD, 'AD106 HD Audio'
    DEVICE 0x10EC, 0x8168, 'RTL8111/8168 Gigabit Ethernet'
    DEVICE 0x10EC, 0x8125, 'RTL8125 2.5G Ethernet'
    DEVICE 0x10EC, 0xB852, 'RTL8852BE Wi-Fi 6'
    DEVICE 0x10EC, 0xC852, 'RTL8852CE Wi-Fi 6E'
    DEVICE 0x1234, 0x1111, 'standard VGA'
    DEVICE 0x1B36, 0x000D, 'xHCI USB controller'
    DEVICE 0x1B36, 0x0010, 'NVMe controller'
    DEVICE 0x8086, 0x29C0, 'Q35 host bridge'
    DEVICE 0x8086, 0x2918, 'ICH9 LPC bridge'
    DEVICE 0x8086, 0x2922, 'ICH9 SATA (AHCI)'
    DEVICE 0x8086, 0x2930, 'ICH9 SMBus'
    DEVICE 0x8086, 0x10D3, '82574L Gigabit Ethernet'
    DEVICE 0x8086, 0x100E, '82540EM Gigabit Ethernet'
    dd 0

%macro CLASS 3                          ; value, mask, name
    dd %1, %2
    dq %%name
    [section .rodata]
    %%name: db %3, 0
    __SECT__
%endmacro
; class table: { dword value, dword mask, qword name }, first match wins
pci_classes:
    CLASS 0x010802, 0xFFFF00, 'NVMe SSD controller'
    CLASS 0x010601, 0xFFFF00, 'SATA controller (AHCI)'
    CLASS 0x010000, 0xFF0000, 'storage controller'
    CLASS 0x020000, 0xFFFF00, 'Ethernet controller'
    CLASS 0x028000, 0xFFFF00, 'wireless network controller'
    CLASS 0x020000, 0xFF0000, 'network controller'
    CLASS 0x030000, 0xFFFF00, 'VGA display controller'
    CLASS 0x030200, 0xFFFF00, '3D controller'
    CLASS 0x030000, 0xFF0000, 'display controller'
    CLASS 0x040300, 0xFFFF00, 'HD audio'
    CLASS 0x040000, 0xFF0000, 'multimedia controller'
    CLASS 0x050000, 0xFF0000, 'memory controller'
    CLASS 0x060000, 0xFFFF00, 'host bridge'
    CLASS 0x060100, 0xFFFF00, 'ISA bridge'
    CLASS 0x060400, 0xFFFF00, 'PCI bridge'
    CLASS 0x060000, 0xFF0000, 'bridge'
    CLASS 0x070000, 0xFF0000, 'communication controller'
    CLASS 0x080000, 0xFF0000, 'system peripheral'
    CLASS 0x090000, 0xFF0000, 'input controller'
    CLASS 0x0C0330, 0xFFFFFF, 'USB 3 controller (xHCI)'
    CLASS 0x0C0320, 0xFFFFFF, 'USB 2 controller (EHCI)'
    CLASS 0x0C0500, 0xFFFF00, 'SMBus controller'
    CLASS 0x0C8000, 0xFFFF00, 'serial bus controller'
    CLASS 0x0C0000, 0xFF0000, 'serial bus controller'
    CLASS 0x0D0000, 0xFF0000, 'wireless controller'
    CLASS 0x100000, 0xFF0000, 'encryption controller'
    CLASS 0x110000, 0xFF0000, 'signal processing controller'
    CLASS 0x120000, 0xFF0000, 'processing accelerator'
    dd -1, 0
    dq str_pci_other

pci_use_ecam:   db 0
align 4
pci_last_bus:   dd 255

section .bss
alignb 8
pci_ecam_virt:  resq 1
pci_count:      resd 1
alignb 16
pci_devices:    resb MAX_PCI * PCI_ENTRY
