; =============================================================================
;  vmd.asm - Intel's Volume Management Device: a PCI domain of its own,
;  behind one function on bus 0, where firmware in "RAID" or "Optane" mode
;  hides the NVMe drives (hp-1's is there). Its configuration space is the
;  VMD's BAR 0, laid out as ECAM from its first bus (0, 128 or 224, as its
;  VMCONFIG says); the memory BARs of what is in it fall in its BARs 2 and
;  4, where the firmware put them.
;
;  vmd_init, after pci_init, adds each function in it to pci_devices with
;  PE_SEG = 1; its bdf (pci_bdf) has bit 16 set, so pci_read32 and
;  pci_write32 go to the VMD's space (vmd_cfg). Their DMA reaches the IOMMU
;  as the VMD's own requests (pci_dma_bdf). Their MSI and MSI-X would go
;  through the VMD's own MSI-X table, which is not set up here: drivers
;  poll them.
; =============================================================================

VMD_VMCAP       equ 0x40                ; bit 0: bus numbers restricted
VMD_VMCONFIG    equ 0x44                ; bits 9:8: the first bus, 0, 128 or 224
VMD_SEG         equ 0x10000             ; bdf bit 16: in the VMD's domain

section .text

; vmd_init: the VMD, if there is one, and what is behind it
vmd_init:
    push rbx
    push r12
    push r13
    push r14
    mov dword [vmd_bdf], -1
    lea rbx, [pci_devices]
    xor r12d, r12d
.next:
    cmp r12d, [pci_count]
    jae .out
    cmp word [rbx + PE_VENDOR], 0x8086
    jne .skip
    movzx eax, word [rbx + PE_DEVICE]
    lea rsi, [vmd_ids]
.id:
    movzx ecx, word [rsi]
    test ecx, ecx
    jz .skip
    add rsi, 2
    cmp eax, ecx
    jne .id
    jmp .found
.skip:
    add rbx, PCI_ENTRY
    inc r12d
    jmp .next
.found:
    mov rdi, rbx
    call pci_bdf
    mov r13d, eax
    mov [vmd_bdf], eax
    mov edi, r13d
    mov esi, 0x04                       ; memory decode and bus master, as the
    call pci_read32                     ; firmware left them
    mov r14d, eax
    call vmd_bar0                       ; -> RAX = address, RCX = bytes
    jc .no_bar
    mov [vmd_cfg_phys], rax
    shr rcx, 20                         ; a bus to a MiB
    mov [vmd_buses], ecx
    xor edx, edx                        ; the first bus
    mov edi, r13d
    mov esi, VMD_VMCAP
    call pci_read32
    test eax, 1
    jz .bus0
    mov esi, VMD_VMCONFIG
    call pci_read32
    shr eax, 8
    and eax, 3
    mov edx, 128
    cmp eax, 1
    je .bus0
    mov edx, 224
    cmp eax, 2
    je .bus0
    xor edx, edx
    test eax, eax
    jnz .bad_bus
.bus0:
    mov [vmd_bus0], edx
    mov eax, 256                        ; no further than bus 255
    sub eax, edx
    cmp [vmd_buses], eax
    jbe .mapped
    mov [vmd_buses], eax
.mapped:
    mov rdi, [vmd_cfg_phys]
    mov esi, [vmd_buses]
    shl rsi, 20
    call mmio_map
    test rax, rax
    jz .no_map
    mov [vmd_cfg_virt], rax
    test r14d, 2                        ; decoding memory: what is behind it
    jnz .on                             ; answers
    or r14d, 6
    mov edi, r13d
    mov esi, 0x04
    mov edx, r14d
    call pci_write32
.on:
    movzx eax, word [rbx + PE_DEVICE]
    movzx ecx, byte [rbx + PE_BUS]
    movzx edx, byte [rbx + PE_DEV]
    movzx r8d, byte [rbx + PE_FN]
    mov r9d, [vmd_bus0]
    mov r10d, r9d
    add r10d, [vmd_buses]
    dec r10d
    KLOG "vmd: Intel VMD %04x at %02x:%02x.%u: buses %02x-%02x, its configuration at %p", rax, rcx, rdx, r8, r9, r10, qword [vmd_cfg_phys]
    call vmd_shadow
    call vmd_scan
    jmp .out
.no_bar:
    KLOG "vmd: Intel VMD, but its BAR 0 is not there"
    jmp .out
.bad_bus:
    KLOG "vmd: Intel VMD, but its first bus is not one it may have (VMCONFIG %x)", rax
    jmp .out
.no_map:
    KLOG "vmd: Intel VMD, but its configuration space could not be mapped"
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; vmd_bar0(R13D = the VMD's bdf) -> RAX = BAR 0's address, RCX = its bytes;
; CF if it has none. Sized as the PCI specification says, with decoding off
; meanwhile, so that nothing answers at all ones.
vmd_bar0:
    push rbx
    push rdx
    push r8
    push r9
    push r10
    push r12
    mov edi, r13d
    mov esi, 0x10
    call pci_read32
    mov r8d, eax                        ; low,
    test eax, 1                         ; (I/O space: not the one)
    jnz .none
    xor r9d, r9d
    xor r10d, r10d                      ; 64-bit?
    and eax, 6
    cmp eax, 4
    jne .read
    inc r10d
    mov esi, 0x14
    call pci_read32
    mov r9d, eax                        ; and high
.read:
    mov esi, 0x04
    call pci_read32
    mov r12d, eax                       ; the command register, as it was
    mov edx, eax
    and edx, ~2
    call pci_write32
    mov esi, 0x10
    mov edx, -1
    call pci_write32
    call pci_read32
    mov ebx, eax                        ; what it lets be written, low
    mov rax, -1 << 32                   ; (a 32-bit BAR: nothing above)
    test r10d, r10d
    jz .sized
    mov esi, 0x14
    call pci_write32
    call pci_read32
    shl rax, 32
.sized:
    or rbx, rax
    mov esi, 0x10                       ; as they were
    mov edx, r8d
    call pci_write32
    test r10d, r10d
    jz .put
    mov esi, 0x14
    mov edx, r9d
    call pci_write32
.put:
    mov esi, 0x04
    mov edx, r12d
    call pci_write32
    and rbx, ~0xF
    jz .none
    mov rcx, rbx
    neg rcx                             ; its size: the lowest bit it keeps
    mov rax, r9
    shl rax, 32
    mov r8d, r8d
    or rax, r8
    and rax, ~0xF
    jz .none
    clc
    jmp .out
.none:
    stc
.out:
    pop r12
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rbx
    ret

; vmd_shadow(R13D): what the firmware says, in the VMD's vendor capability,
; the BARs of the devices behind it are taken against ("SHDW": BARs 2 and 4
; as the domain sees them). Equal on bare metal; said if they are not.
vmd_shadow:
    push rbx
    mov edi, r13d
    mov esi, 0x09                       ; vendor-specific
    call pci_find_cap
    jc .out
    mov ebx, esi
    lea esi, [rbx + 4]
    call pci_read32
    cmp eax, 0x53484457                 ; "SHDW"
    jne .out
    lea esi, [rbx + 8]
    call vmd_read64
    and rax, ~0xF
    mov rcx, rax
    mov esi, 0x18                       ; BAR 2
    call vmd_read64
    and rax, ~0xF
    cmp rax, rcx
    jne .shadowed
    lea esi, [rbx + 16]
    call vmd_read64
    and rax, ~0xF
    mov rcx, rax
    mov esi, 0x20                       ; BAR 4
    call vmd_read64
    and rax, ~0xF
    cmp rax, rcx
    je .out
.shadowed:
    KLOG "vmd: the BARs behind it are shadowed: %p seen for %p; they are used as they are", rcx, rax
.out:
    pop rbx
    ret

; vmd_read64(EDI = bdf, ESI = offset) -> RAX = two dwords. Preserves others.
vmd_read64:
    push rcx
    call pci_read32
    mov ecx, eax
    add esi, 4
    call pci_read32
    sub esi, 4
    shl rax, 32
    or rax, rcx
    pop rcx
    ret

; vmd_scan: every function on the VMD's buses, into pci_devices
vmd_scan:
    push rbx
    push r12
    push r13
    push r14
    push r15
    mov r12d, [vmd_bus0]                ; bus
    xor r15d, r15d                      ; found
.bus:
    mov eax, [vmd_bus0]
    add eax, [vmd_buses]
    cmp r12d, eax
    jae .done
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
    or edi, VMD_SEG
    xor esi, esi
    call pci_read32
    cmp ax, 0xFFFF
    je .absent
    test ax, ax
    jz .absent
    mov ebx, eax                        ; vendor | device << 16
    mov esi, 0x0C
    call pci_read32
    shr eax, 16
    mov r8d, eax                        ; header type
    mov esi, 0x08
    call pci_read32
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
    mov [rdx + PE_VENDOR], ebx
    mov [rdx + PE_REV], al
    shr eax, 8
    mov [rdx + PE_PROGIF], al
    shr eax, 8
    mov [rdx + PE_SUBCLASS], al
    shr eax, 8
    mov [rdx + PE_CLASS], al
    mov byte [rdx + PE_SEG], 1
    inc dword [pci_count]
    inc r15d
    push rdx
    push r8
    mov rdi, rdx
    lea rsi, [ui_buf2]
    call pci_describe
    pop r8
    pop rdx
    movzx eax, word [rdx + PE_VENDOR]
    movzx ecx, word [rdx + PE_DEVICE]
    lea r9, [ui_buf2]
    KLOG "vmd:   %02x:%02x.%u  %04x:%04x  %s", r12, r13, r14, rax, rcx, r9
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
    KLOG "vmd: %u functions behind it", r15
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; vmd_cfg(EDI = bdf with VMD_SEG, ESI = offset) -> RAX = where that register
; is mapped; CF if the bus is not the VMD's. Preserves others.
vmd_cfg:
    push rcx
    mov eax, edi
    shr eax, 8
    and eax, 0xFF
    sub eax, [vmd_bus0]
    jb .none
    cmp eax, [vmd_buses]
    jae .none
    cmp qword [vmd_cfg_virt], 0
    je .none
    shl rax, 20
    movzx ecx, dil                      ; device and function
    shl ecx, 12
    add rax, rcx
    mov ecx, esi
    and ecx, 0xFFC
    add rax, rcx
    add rax, [vmd_cfg_virt]
    clc
    pop rcx
    ret
.none:
    stc
    pop rcx
    ret

; pci_dma_bdf(EDI = bdf) -> EAX = the requester id its DMA carries to the
; IOMMU: its own, or the VMD's for what is behind one. Preserves others.
pci_dma_bdf:
    mov eax, edi
    test eax, VMD_SEG
    jz .out
    mov eax, [vmd_bdf]
.out:
    ret

section .rodata
vmd_ids:        dw 0x9A0B, 0x467F, 0xA77F, 0x7D0B, 0  ; Tiger, Alder, Raptor, Meteor Lake

section .data
vmd_bdf:        dd -1                   ; the VMD's own, -1 if none

section .bss
alignb 8
vmd_cfg_phys:   resq 1
vmd_cfg_virt:   resq 1
vmd_bus0:       resd 1
vmd_buses:      resd 1
