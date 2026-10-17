; =============================================================================
;  iommu.asm - Intel VT-d DMA remapping. Every device Axiom drives does its
;  DMA through page tables of its driver's own (a domain: USB, NVMe, the
;  network), which hold only the memory that driver handed it; a device no
;  driver has claimed reaches no memory at all, but for what the firmware
;  reserved for it (RMRR). Addresses are mapped one to one, so drivers still
;  hand devices physical addresses, and any outside the domain fault.
;  Interrupt remapping stays off: MSIs pass as they are.
;
;  Registers by convention: RBX = unit, R12 = domain.
; =============================================================================

MAX_IOMMU       equ 8
MAX_DOMAINS     equ 16
MAX_RMRR        equ 16
IOMMU_LOG       equ 16                  ; the last faults, kept for 'iommu'
IOMMU_SPIN_MS   equ 100                 ; an invalidation done by then, or never

; a remapping unit (DRHD)
IU_MMIO         equ 0
IU_PHYS         equ 8
IU_CAP          equ 16
IU_ECAP         equ 24
IU_ROOT         equ 32                  ; the root table, mapped, then physical
IU_ROOTP        equ 40
IU_SCOPE        equ 48                  ; its device scope entries in the DMAR, and their end
IU_SCOPE_END    equ 56
IU_IOTLB        equ 64                  ; dword: offset of IVA; the IOTLB register is 8 after
IU_FRO          equ 68                  ; dword: offset of the fault recording registers
IU_NFR          equ 72                  ; dword: how many
IU_LOCK         equ 76                  ; dword: its tables and registers
IU_FLAGS        equ 80                  ; dword: IUF_*
IU_VER          equ 84                  ; dword
IU_FAULTS       equ 88
IU_DEVICES      equ 96                  ; context entries made
IU_SIZE         equ 128

IUF_ALL         equ 1                   ; every device no other unit lists
IUF_COHERENT    equ 2                   ; it snoops the caches: no clflush
IUF_ON          equ 4                   ; translating
IUF_RWBF        equ 8                   ; wants its write buffer flushed
IUF_CM          equ 16                  ; caches entries not present

; a domain: the memory one driver's devices may reach
DM_NAME         equ 0
DM_DID          equ 8                   ; dword: domain ID, from 1
DM_LOCK         equ 12                  ; dword: its page tables
DM_TOP          equ 16                  ; the top table, mapped, then physical
DM_TOPP         equ 24
DM_PAGES        equ 32                  ; 4 KiB pages it maps
DM_TABLES       equ 40
DM_MAPS         equ 48
DM_UNMAPS       equ 56
DM_DEVICES      equ 64                  ; dword
DM_SIZE         equ 80

; a reserved region (RMRR): a device's, mapped wherever that device is put
RM_BASE         equ 0
RM_END          equ 8                   ; the last byte
RM_SCOPE        equ 16
RM_SCOPE_END    equ 24
RM_SIZE         equ 32

; a fault, as 'iommu' shows it
FL_ADDR         equ 0
FL_SID          equ 8                   ; word: bus, device, function
FL_REASON       equ 10                  ; byte
FL_READ         equ 11                  ; byte: 1 = a read, 0 = a write
FL_UNIT         equ 12                  ; dword
FL_SIZE         equ 16

; registers
VTR_VER         equ 0x00
VTR_CAP         equ 0x08
VTR_ECAP        equ 0x10
VTR_GCMD        equ 0x18
VTR_GSTS        equ 0x1C
VTR_RTADDR      equ 0x20
VTR_CCMD        equ 0x28
VTR_FSTS        equ 0x34
VTR_FECTL       equ 0x38
VTR_FEDATA      equ 0x3C
VTR_FEADDR      equ 0x40
VTR_FEUADDR     equ 0x44
VTR_PMEN        equ 0x64
GC_TE           equ 1 << 31             ; GCMD and GSTS
GC_SRTP         equ 1 << 30
GC_WBF          equ 1 << 27
GC_KEEP         equ 0x96FFFFFF          ; GSTS bits that are not one-shot

; second-level page table entries
VT_R            equ 1
VT_W            equ 2
VT_RW           equ 3
VT_ADDR         equ 0x000FFFFFFFFFF000
VT_COUNT        equ 1 << 52             ; bits 52-61, ignored by the unit: how
VT_COUNT_MAX    equ 0x3FF               ; many maps hold the page (stuck at max)

section .text

; iommu_init: every unit the DMAR lists, translating, with nothing mapped
; but reserved regions. Before any driver starts.
iommu_init:
    push rbx
    push r12
    push r13
    push r14
    mov edi, VEC_IOMMU
    lea rsi, [iommu_irq]
    call irq_register
    xor ecx, ecx                        ; the DMAR among the tables ACPI found
.find:
    cmp ecx, [acpi_table_count]
    jae .none
    lea rax, [acpi_table_sigs]
    cmp dword [rax + rcx * 4], 'DMAR'
    je .found
    inc ecx
    jmp .find
.found:
    lea rax, [acpi_table_ptrs]
    mov r12, [rax + rcx * 8]
    mov eax, [r12 + 4]
    lea r13, [r12 + rax]                ; R13 = its end
    add r12, 48                         ; R12 = the first structure
.struct:
    lea rax, [r12 + 4]
    cmp rax, r13
    ja .parsed
    movzx r14d, word [r12 + 2]          ; length
    cmp r14d, 4
    jb .parsed
    movzx eax, word [r12]
    test eax, eax
    jz .drhd
    cmp eax, 1
    je .rmrr
    jmp .next
.drhd:
    cmp word [r12 + 6], 0               ; segment 0 alone: PCI here has no other
    jne .next
    mov eax, [iommu_count]
    cmp eax, MAX_IOMMU
    jae .next
    imul rbx, rax, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    mov rax, [r12 + 8]
    mov [rbx + IU_PHYS], rax
    lea rax, [r12 + 16]
    mov [rbx + IU_SCOPE], rax
    lea rax, [r12 + r14]
    mov [rbx + IU_SCOPE_END], rax
    test byte [r12 + 4], 1              ; INCLUDE_PCI_ALL
    jz .unit
    or dword [rbx + IU_FLAGS], IUF_ALL
.unit:
    call iu_start
    jc .next
    inc dword [iommu_count]
    jmp .next
.rmrr:
    cmp word [r12 + 6], 0
    jne .next
    mov eax, [rmrr_count]
    cmp eax, MAX_RMRR
    jae .next
    imul rcx, rax, RM_SIZE
    lea rax, [rmrr_list]
    add rcx, rax
    mov rax, [r12 + 8]
    mov [rcx + RM_BASE], rax
    mov rax, [r12 + 16]
    mov [rcx + RM_END], rax
    lea rax, [r12 + 24]
    mov [rcx + RM_SCOPE], rax
    lea rax, [r12 + r14]
    mov [rcx + RM_SCOPE_END], rax
    inc dword [rmrr_count]
.next:
    add r12, r14
    jmp .struct
.parsed:
    cmp dword [iommu_count], 0
    je .none
    call iommu_levels_pick
    call iommu_firmware                 ; reserved regions for their devices
    xor r12d, r12d
.enable:
    cmp r12d, [iommu_count]
    jae .enabled
    imul rbx, r12, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    call iu_enable
    inc r12d
    jmp .enable
.enabled:
    mov byte [iommu_on], 1
    mov eax, [iommu_count]
    mov ecx, [iommu_levels]
    mov edx, [rmrr_count]
    KLOG "iommu: %u VT-d unit(s), %u-level tables, %u reserved region(s); a device reaches only what its driver maps", rax, rcx, rdx
    jmp .out
.none:
    KLOG "iommu: no VT-d (no DMAR table): DMA is not confined"
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; iu_start(RBX = unit, IU_PHYS set) -> CF if unusable: its registers, what
; it can do, a root table
iu_start:
    push rcx
    push rdx
    push rdi
    push rsi
    mov rdi, [rbx + IU_PHYS]
    mov esi, 0x4000
    call mmio_map
    test rax, rax
    jz .fail
    mov [rbx + IU_MMIO], rax
    mov rdi, rax
    mov eax, [rdi + VTR_VER]
    mov [rbx + IU_VER], eax
    mov rax, [rdi + VTR_CAP]
    mov [rbx + IU_CAP], rax
    mov rcx, rax
    shr rcx, 24                         ; FRO, in 16-byte units
    and ecx, 0x3FF
    shl ecx, 4
    mov [rbx + IU_FRO], ecx
    mov rcx, rax
    shr rcx, 40                         ; NFR - 1
    and ecx, 0xFF
    inc ecx
    mov [rbx + IU_NFR], ecx
    test eax, 1 << 4
    jz .no_rwbf
    or dword [rbx + IU_FLAGS], IUF_RWBF
.no_rwbf:
    test eax, 1 << 7
    jz .no_cm
    or dword [rbx + IU_FLAGS], IUF_CM
    mov byte [iommu_cm], 1
.no_cm:
    mov rax, [rdi + VTR_ECAP]
    mov [rbx + IU_ECAP], rax
    mov rcx, rax
    shr rcx, 8                          ; IRO, in 16-byte units
    and ecx, 0x3FF
    shl ecx, 4
    mov [rbx + IU_IOTLB], ecx
    test eax, 1
    jz .not_coherent
    or dword [rbx + IU_FLAGS], IUF_COHERENT
    jmp .root
.not_coherent:
    mov byte [iommu_flush_needed], 1
.root:
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .fail
    mov [rbx + IU_ROOTP], rax
    add rax, [phys_base]
    mov [rbx + IU_ROOT], rax
    mov rdi, rax
    mov esi, 4096
    call iommu_flush
    clc
    jmp .out
.fail:
    stc
.out:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    ret

; iommu_levels_pick: 4-level tables (48 bits) if every unit takes them, else 3
iommu_levels_pick:
    push rbx
    push rcx
    mov dword [iommu_levels], 4
    xor ecx, ecx
.unit:
    cmp ecx, [iommu_count]
    jae .out
    imul rbx, rcx, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    mov rax, [rbx + IU_CAP]             ; SAGAW: bit 2 = 48-bit, bit 1 = 39-bit
    test eax, 1 << 10
    jnz .ok
    mov dword [iommu_levels], 3
.ok:
    inc ecx
    jmp .unit
.out:
    pop rcx
    pop rbx
    ret

; iommu_firmware: every device a reserved region names, in a domain of the
; firmware's that maps those regions, until a driver claims it
iommu_firmware:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    xor r13d, r13d
.region:
    cmp r13d, [rmrr_count]
    jae .out
    imul rbx, r13, RM_SIZE
    lea rax, [rmrr_list]
    add rbx, rax
    mov rsi, [rbx + RM_SCOPE]
.scope:
    lea rax, [rsi + 6]
    cmp rax, [rbx + RM_SCOPE_END]
    ja .next_region
    movzx ecx, byte [rsi + 1]
    cmp ecx, 6
    jb .next_region
    cmp byte [rsi], 1                   ; an endpoint
    jne .next_scope
    call iommu_scope_bdf
    jc .next_scope
    mov edx, eax
    mov r12, [iommu_fw_domain]
    test r12, r12
    jnz .have
    push rsi
    lea rdi, [str_iommu_fw]
    call iommu_domain_new
    pop rsi
    mov [iommu_fw_domain], rax
    mov r12, rax
    test r12, r12
    jz .out
.have:
    push rsi
    mov rdi, r12
    mov esi, edx
    call iommu_attach                   ; maps that device's regions
    pop rsi
.next_scope:
    movzx ecx, byte [rsi + 1]
    add rsi, rcx
    jmp .scope
.next_region:
    inc r13d
    jmp .region
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; iommu_scope_bdf(RSI = a device scope entry) -> EAX = the bus, device and
; function its path leads to; CF if a bridge on the way has no bus yet.
; Preserves others.
iommu_scope_bdf:
    push rcx
    push rdx
    push rsi
    push rdi
    movzx ecx, byte [rsi + 1]
    lea rdx, [rsi + rcx]                ; its end
    movzx eax, byte [rsi + 5]           ; start bus
    add rsi, 6
.step:
    movzx edi, byte [rsi]               ; device
    shl edi, 3
    movzx ecx, byte [rsi + 1]           ; function
    or edi, ecx
    shl eax, 8
    or edi, eax                         ; EDI = bus:device.function
    add rsi, 2
    lea rcx, [rsi + 1]
    cmp rcx, rdx
    jae .last
    push rsi                            ; a bridge: on to its secondary bus
    mov esi, 0x18
    call pci_read32
    pop rsi
    shr eax, 8
    and eax, 0xFF
    jz .fail
    jmp .step
.last:
    mov eax, edi
    clc
    jmp .out
.fail:
    stc
.out:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; iommu_scope_has(RSI = scope entries, RDX = their end, EDI = bdf) -> CF if
; one of them is that device, or a bridge it is behind. Preserves others.
iommu_scope_has:
    push rax
    push rcx
    push rsi
    push r8
.entry:
    lea rax, [rsi + 6]
    cmp rax, rdx
    ja .no
    movzx ecx, byte [rsi + 1]
    cmp ecx, 6
    jb .no
    mov al, [rsi]
    cmp al, 1                           ; an endpoint
    je .endpoint
    cmp al, 2                           ; a bridge and all behind it
    jne .next
    push rax
    call iommu_scope_bdf
    jc .bridge_no
    cmp eax, edi
    je .bridge_yes
    push rdi
    push rsi
    mov edi, eax
    mov esi, 0x18
    call pci_read32                     ; its secondary and subordinate buses
    pop rsi
    pop rdi
    mov ecx, edi
    shr ecx, 8
    mov r8d, eax                        ; secondary
    shr r8d, 8
    and r8d, 0xFF
    cmp ecx, r8d
    jb .bridge_no
    shr eax, 16
    and eax, 0xFF                       ; subordinate
    cmp ecx, eax
    ja .bridge_no
.bridge_yes:
    pop rax
    jmp .yes
.bridge_no:
    pop rax
    jmp .next
.endpoint:
    call iommu_scope_bdf
    jc .next
    cmp eax, edi
    je .yes
.next:
    movzx ecx, byte [rsi + 1]
    add rsi, rcx
    jmp .entry
.yes:
    stc
    jmp .out
.no:
    clc
.out:
    pop r8
    pop rsi
    pop rcx
    pop rax
    ret

; iommu_unit_for(EDI = bdf) -> RAX = the unit that remaps it, 0 if none.
; Preserves others.
iommu_unit_for:
    push rbx
    push rcx
    push rdx
    push rsi
    push r8
    xor ecx, ecx
.listed:
    cmp ecx, [iommu_count]
    jae .all
    imul rbx, rcx, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    inc ecx
    test dword [rbx + IU_FLAGS], IUF_ALL
    jnz .listed
    mov rsi, [rbx + IU_SCOPE]
    mov rdx, [rbx + IU_SCOPE_END]
    call iommu_scope_has
    jnc .listed
    mov rax, rbx
    jmp .out
.all:
    xor ecx, ecx
.any:
    cmp ecx, [iommu_count]
    jae .nothing
    imul rbx, rcx, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    inc ecx
    test dword [rbx + IU_FLAGS], IUF_ALL
    jz .any
    mov rax, rbx
    jmp .out
.nothing:
    xor eax, eax
.out:
    pop r8
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret

; iommu_flush(RDI = mapped address, ESI = bytes): out of the caches to
; memory, when a unit does not snoop them. Preserves all.
iommu_flush:
    cmp byte [iommu_flush_needed], 0
    je .out
    push rax
    push rcx
    mov rax, rdi
    and rax, -64
    lea rcx, [rdi + rsi]
.line:
    clflush [rax]
    add rax, 64
    cmp rax, rcx
    jb .line
    sfence
    pop rcx
    pop rax
.out:
    ret

; iu_gcmd(RBX = unit, EAX = a GCMD bit, EDX = 1 to set it, 0 to clear) ->
; CF if the status never followed. Preserves others.
iu_gcmd:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, [rbx + IU_MMIO]
    mov ecx, [r8 + VTR_GSTS]
    and ecx, GC_KEEP
    or ecx, eax
    test edx, edx
    jnz .write
    not eax
    and ecx, eax
    not eax
.write:
    mov [r8 + VTR_GCMD], ecx
    neg edx                             ; EDX = the bit when set, 0 when clear
    and edx, eax
    push rax
    push rdx
    mov edi, IOMMU_SPIN_MS
    call usb_deadline
    mov rsi, rax
    pop rdx
    pop rax
.wait:
    mov ecx, [r8 + VTR_GSTS]
    and ecx, eax
    cmp ecx, edx
    je .done
    push rax
    push rdx
    call usb_expired
    pop rdx
    pop rax
    jc .late
    pause
    jmp .wait
.done:
    clc
    jmp .out
.late:
    stc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; iu_spin(RCX = a mapped 64-bit register, RDX = the bit that clears when
; done) -> CF if it never did. Preserves others.
iu_spin:
    push rax
    push rsi
    push rdi
    push rdx
    mov edi, IOMMU_SPIN_MS
    call usb_deadline
    mov rsi, rax
    pop rdx
.wait:
    test [rcx], rdx
    jz .done
    push rdx
    call usb_expired
    pop rdx
    jc .late
    pause
    jmp .wait
.done:
    clc
    jmp .out
.late:
    stc
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; iu_context_all(RBX = unit, its lock held): every context entry it cached
; forgotten. Preserves all.
iu_context_all:
    push rax
    push rcx
    push rdx
    mov rcx, [rbx + IU_MMIO]
    add rcx, VTR_CCMD
    mov rax, (1 << 63) | (1 << 61)      ; ICC, global
    mov [rcx], rax
    mov rdx, 1 << 63
    call iu_spin
    pop rdx
    pop rcx
    pop rax
    ret

; iu_iotlb(RBX = unit, its lock held, RAX = the request without IVT, drains
; or DID; RDX = the address for a page's, else 0): IOTLB entries forgotten.
; Preserves all.
iu_iotlb:
    push rax
    push rcx
    push rdx
    mov ecx, [rbx + IU_IOTLB]           ; IVA, then IOTLB
    add rcx, [rbx + IU_MMIO]
    mov [rcx], rdx
    add rcx, 8
    mov rdx, [rbx + IU_CAP]             ; drain reads and writes first, if it can
    bt rdx, 55
    jnc .dw
    bts rax, 49
.dw:
    bt rdx, 54
    jnc .go
    bts rax, 48
.go:
    bts rax, 63
    mov [rcx], rax
    mov rdx, 1 << 63
    call iu_spin
    pop rdx
    pop rcx
    pop rax
    ret

; iu_wbf(RBX = unit): its write buffer flushed, if it wants that. Preserves all.
iu_wbf:
    test dword [rbx + IU_FLAGS], IUF_RWBF
    jz .out
    push rcx
    push rdx
    push rax
    mov rcx, [rbx + IU_MMIO]
    mov eax, [rcx + VTR_GSTS]
    and eax, GC_KEEP
    or eax, GC_WBF
    mov [rcx + VTR_GCMD], eax
    add rcx, VTR_GSTS                   ; WBFS clears when it is done
    mov edx, GC_WBF
    call iu_spin32
    pop rax
    pop rdx
    pop rcx
.out:
    ret

; iu_spin32(RCX = a mapped 32-bit register, EDX = the bit that clears) -> CF
iu_spin32:
    push rax
    push rsi
    push rdi
    push rdx
    mov edi, IOMMU_SPIN_MS
    call usb_deadline
    mov rsi, rax
    pop rdx
.wait:
    test [rcx], edx
    jz .done
    push rdx
    call usb_expired
    pop rdx
    jc .late
    pause
    jmp .wait
.done:
    clc
    jmp .out
.late:
    stc
.out:
    pop rdi
    pop rsi
    pop rax
    ret

; iu_enable(RBX = unit): the firmware's translation and protected regions
; off, our root table in, every cache emptied, faults to the BSP, on
iu_enable:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    pushfq
    cli
    lea rdi, [rbx + IU_LOCK]
    call spin_lock
    mov r8, [rbx + IU_MMIO]
    test dword [r8 + VTR_GSTS], GC_TE   ; the firmware left it translating
    jz .off
    mov eax, GC_TE
    xor edx, edx
    call iu_gcmd
.off:
    mov eax, [r8 + VTR_PMEN]            ; protected memory regions
    test eax, 1
    jz .unprotected
    mov dword [r8 + VTR_PMEN], 0
    lea rcx, [r8 + VTR_PMEN]
    mov edx, 1
    call iu_spin32
.unprotected:
    mov rax, [rbx + IU_ROOTP]           ; legacy root table
    mov [r8 + VTR_RTADDR], rax
    mov eax, GC_SRTP
    mov edx, 1
    call iu_gcmd
    jc .failed
    call iu_context_all
    mov rax, 1 << 60                    ; IOTLB: global
    xor edx, edx
    call iu_iotlb
    call iu_wbf
    lea rax, [percpu]                   ; faults: an MSI to the BSP
    mov eax, [rax + PC_APIC_ID]
    shl eax, 12
    or eax, 0xFEE00000
    mov dword [r8 + VTR_FECTL], 1 << 31 ; masked while it is written
    mov dword [r8 + VTR_FEDATA], VEC_IOMMU
    mov [r8 + VTR_FEADDR], eax
    mov dword [r8 + VTR_FEUADDR], 0
    mov eax, [r8 + VTR_FSTS]            ; anything recorded before is gone
    and eax, 0x7D
    mov [r8 + VTR_FSTS], eax
    mov dword [r8 + VTR_FECTL], 0
    mov eax, GC_TE
    mov edx, 1
    call iu_gcmd
    jc .failed
    or dword [rbx + IU_FLAGS], IUF_ON
    jmp .unlock
.failed:
    mov rax, [rbx + IU_PHYS]
    KLOG "iommu: the unit at %p did not do as told", rax
.unlock:
    lea rdi, [rbx + IU_LOCK]
    call spin_unlock
    popfq
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; -----------------------------------------------------------------------------
;  Domains
; -----------------------------------------------------------------------------

; iommu_domain_new(RDI = its name) -> RAX = a domain mapping nothing, 0 if
; there is no IOMMU (or no room). Preserves others.
iommu_domain_new:
    push rcx
    push rdx
    push rdi
    push r12
    xor eax, eax
    cmp dword [iommu_count], 0
    je .out
    mov ecx, [domain_count]
    cmp ecx, MAX_DOMAINS
    jae .full
    imul r12, rcx, DM_SIZE
    lea rax, [iommu_domains]
    add r12, rax
    mov [r12 + DM_NAME], rdi
    lea eax, [ecx + 1]
    mov [r12 + DM_DID], eax
    mov edi, 1
    call pmm_alloc_zero
    test rax, rax
    jz .full
    mov [r12 + DM_TOPP], rax
    add rax, [phys_base]
    mov [r12 + DM_TOP], rax
    mov rdi, rax
    push rsi
    mov esi, 4096
    call iommu_flush
    pop rsi
    mov qword [r12 + DM_TABLES], 1
    inc dword [domain_count]
    mov rax, r12
    jmp .out
.full:
    KLOG "iommu: no room for another domain"
    xor eax, eax
.out:
    pop r12
    pop rdi
    pop rdx
    pop rcx
    ret

; iommu_attach(RDI = domain, ESI = bdf) -> CF on failure: that device's DMA
; through that domain from now on, with any region the firmware reserved
; for it mapped. A domain of 0 (no IOMMU) does nothing. Preserves others.
iommu_attach:
    test rdi, rdi
    jz .nothing
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r12
    push r13
    mov r12, rdi
    mov r13d, esi
    mov edi, esi
    call iommu_unit_for
    test rax, rax
    jz .uncovered
    mov rbx, rax
    pushfq
    cli
    lea rdi, [rbx + IU_LOCK]
    call spin_lock
    mov eax, r13d                       ; the root entry for its bus
    shr eax, 8
    shl eax, 4
    mov rcx, [rbx + IU_ROOT]
    add rcx, rax
    test qword [rcx], 1
    jnz .table
    mov edi, 1                          ; a context table for that bus
    call pmm_alloc_zero
    test rax, rax
    jz .oom
    push rax
    add rax, [phys_base]
    mov rdi, rax
    mov esi, 4096
    call iommu_flush
    pop rax
    mov qword [rcx + 8], 0
    or rax, 1
    mov [rcx], rax
    mov rdi, rcx
    mov esi, 16
    call iommu_flush
.table:
    mov rax, [rcx]
    and rax, [vt_addr_mask]
    add rax, [phys_base]
    movzx ecx, r13b                     ; device and function
    shl ecx, 4
    add rcx, rax                        ; RCX = its context entry
    test qword [rcx], 1
    jz .fresh
    mov qword [rcx], 0                  ; in another domain: out of it first
    mov rdi, rcx
    mov esi, 16
    call iommu_flush
    test dword [rbx + IU_FLAGS], IUF_ON
    jz .fresh
    call iu_context_all
    mov rax, 1 << 60
    xor edx, edx
    call iu_iotlb
.fresh:
    mov eax, [iommu_levels]             ; AW: 1 = 3 levels, 2 = 4
    sub eax, 2
    mov edx, [r12 + DM_DID]
    shl edx, 8
    or eax, edx
    mov [rcx + 8], rax
    mov rax, [r12 + DM_TOPP]            ; present, translated requests only
    or rax, 1
    mov [rcx], rax
    mov rdi, rcx
    mov esi, 16
    call iommu_flush
    test dword [rbx + IU_FLAGS], IUF_ON
    jz .made
    call iu_context_all
    mov rax, 1 << 60
    xor edx, edx
    call iu_iotlb
    call iu_wbf
.made:
    inc qword [rbx + IU_DEVICES]
    lea rdi, [rbx + IU_LOCK]
    call spin_unlock
    popfq
    lock inc dword [r12 + DM_DEVICES]
    mov edi, r13d                       ; and what the firmware reserved for it
    call iommu_reserved
    clc
    jmp .out
.oom:
    lea rdi, [rbx + IU_LOCK]
    call spin_unlock
    popfq
    KLOG "iommu: out of memory"
    stc
    jmp .out
.uncovered:
    mov eax, r13d                       ; no unit remaps it: nothing to do
    shr eax, 8
    mov ecx, r13d
    shr ecx, 3
    and ecx, 31
    mov edx, r13d
    and edx, 7
    KLOG "iommu: no unit covers %02x:%02x.%u", rax, rcx, rdx
    clc
.out:
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret
.nothing:
    clc
    ret

; iommu_reserved(R12 = domain, EDI = bdf): each reserved region that names
; it, mapped. Preserves others.
iommu_reserved:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r13
    mov r13d, edi
    xor ecx, ecx
.region:
    cmp ecx, [rmrr_count]
    jae .out
    imul rbx, rcx, RM_SIZE
    lea rax, [rmrr_list]
    add rbx, rax
    inc ecx
    mov rsi, [rbx + RM_SCOPE]
    mov rdx, [rbx + RM_SCOPE_END]
    mov edi, r13d
    call iommu_scope_has
    jnc .region
    push rcx
    mov rdi, r12
    mov rsi, [rbx + RM_BASE]
    mov rdx, [rbx + RM_END]
    sub rdx, rsi
    inc rdx
    mov ecx, VT_RW
    call iommu_map
    pop rcx
    jmp .region
.out:
    pop r13
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; dm_walk(R12 = domain, its lock held; RSI = address; EDX = 1 to make the
; tables on the way) -> RAX = its leaf entry, mapped; 0 if there is none
; (or no memory). Preserves others.
dm_walk:
    push rcx
    push rdi
    push r8
    mov r8, [r12 + DM_TOP]
    mov ecx, [iommu_levels]             ; the top level's shift: 39 or 30
    imul ecx, ecx, 9
    add ecx, 3
.level:
    mov rax, rsi
    shr rax, cl
    and eax, 511
    lea rdi, [r8 + rax * 8]
    cmp ecx, 12
    je .leaf
    test qword [rdi], VT_RW
    jnz .down
    test edx, edx
    jz .none
    push rdi                            ; a table for the level below
    mov edi, 1
    call pmm_alloc_zero
    pop rdi
    test rax, rax
    jz .none
    inc qword [r12 + DM_TABLES]
    push rdi
    push rsi
    mov rdi, rax
    add rdi, [phys_base]
    mov esi, 4096
    call iommu_flush
    pop rsi
    pop rdi
    or rax, VT_RW
    mov [rdi], rax
    push rsi
    mov esi, 8
    call iommu_flush
    pop rsi
.down:
    mov r8, [rdi]
    and r8, [vt_addr_mask]
    add r8, [phys_base]
    sub ecx, 9
    jmp .level
.leaf:
    mov rax, rdi
    jmp .out
.none:
    xor eax, eax
.out:
    pop r8
    pop rdi
    pop rcx
    ret

; iommu_map(RDI = domain, RSI = physical, RDX = bytes, ECX = VT_R | VT_W)
; -> CF if out of memory: those pages reachable, one to one, by the
; domain's devices; a page mapped twice must be unmapped twice. A domain of
; 0 does nothing. Preserves others.
iommu_map:
    test rdi, rdi
    jz .nothing
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    mov r12, rdi
    lea r8, [rsi + rdx]                 ; R8 = the end
    and rsi, -4096
    mov r9d, ecx
    pushfq
    cli
    lea rdi, [r12 + DM_LOCK]
    call spin_lock
    inc qword [r12 + DM_MAPS]
.page:
    cmp rsi, r8
    jae .done
    mov edx, 1
    call dm_walk
    test rax, rax
    jz .oom
    mov rcx, [rax]
    test ecx, VT_RW
    jz .new
    mov rdx, rcx                        ; mapped already: one more holds it
    shr rdx, 52
    and edx, VT_COUNT_MAX
    cmp edx, VT_COUNT_MAX
    je .perms
    mov rdx, VT_COUNT
    add rcx, rdx
.perms:
    or rcx, r9
    jmp .store
.new:
    mov rcx, rsi
    or rcx, r9
    mov rdx, VT_COUNT
    or rcx, rdx
    inc qword [r12 + DM_PAGES]
.store:
    mov [rax], rcx
    push rsi
    mov rdi, rax
    mov esi, 8
    call iommu_flush
    pop rsi
    add rsi, 4096
    jmp .page
.done:
    lea rdi, [r12 + DM_LOCK]
    call spin_unlock
    popfq
    cmp byte [iommu_cm], 0              ; a unit that caches what is not there
    je .ok
    mov rdi, r12
    xor esi, esi
    call iommu_forget
.ok:
    clc
    jmp .out
.oom:
    lea rdi, [r12 + DM_LOCK]
    call spin_unlock
    popfq
    KLOG "iommu: out of memory for page tables"
    stc
.out:
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret
.nothing:
    clc
    ret

; iommu_unmap(RDI = domain, RSI = physical, RDX = bytes): those pages out of
; it (each once the last map holding it is undone), and out of every unit's
; IOTLB before this returns. Preserves all.
iommu_unmap:
    test rdi, rdi
    jz .nothing
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r12
    mov r12, rdi
    lea r8, [rsi + rdx]
    and rsi, -4096
    xor r9d, r9d                        ; R9 = pages cleared, RDX = the first
    xor edx, edx
    pushfq
    cli
    lea rdi, [r12 + DM_LOCK]
    call spin_lock
    inc qword [r12 + DM_UNMAPS]
.page:
    cmp rsi, r8
    jae .done
    push rdx
    xor edx, edx
    call dm_walk
    pop rdx
    test rax, rax
    jz .next
    mov rcx, [rax]
    test ecx, VT_RW
    jz .next
    mov rdi, rcx
    shr rdi, 52
    and edi, VT_COUNT_MAX
    cmp edi, VT_COUNT_MAX
    je .next                            ; held for good
    cmp edi, 1
    jbe .clear
    mov rdi, VT_COUNT
    sub rcx, rdi
    mov [rax], rcx
    jmp .flush
.clear:
    mov qword [rax], 0
    dec qword [r12 + DM_PAGES]
    test r9, r9
    jnz .counted
    mov rdx, rsi
.counted:
    inc r9
.flush:
    push rsi
    mov rdi, rax
    mov esi, 8
    call iommu_flush
    pop rsi
.next:
    add rsi, 4096
    jmp .page
.done:
    lea rdi, [r12 + DM_LOCK]
    call spin_unlock
    popfq
    test r9, r9
    jz .out
    mov rdi, r12                        ; one page: just it; more: the domain
    mov rsi, rdx
    cmp r9, 1
    je .forget
    xor esi, esi
.forget:
    call iommu_forget
.out:
    pop r12
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
.nothing:
    ret

; iommu_forget(RDI = domain, RSI = a page's address, or 0 for all of it):
; out of the IOTLB of every unit translating. Preserves all.
iommu_forget:
    push rax
    push rbx
    push rcx
    push rdx
    push rdi
    xor ecx, ecx
.unit:
    cmp ecx, [iommu_count]
    jae .out
    imul rbx, rcx, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    inc ecx
    test dword [rbx + IU_FLAGS], IUF_ON
    jz .unit
    push rdi
    pushfq
    cli
    push rdi
    lea rdi, [rbx + IU_LOCK]
    call spin_lock
    pop rdi
    mov eax, [rdi + DM_DID]
    shl rax, 32
    xor edx, edx
    test rsi, rsi
    jz .domain
    mov rdx, [rbx + IU_CAP]             ; a page, if it can (PSI)
    bt rdx, 39
    jnc .domain_only
    mov rdx, rsi                        ; IVA: the page, AM = 0
    bts rax, 61                         ; page-selective: 3 << 60
    bts rax, 60
    jmp .send
.domain_only:
    xor edx, edx
.domain:
    bts rax, 61                         ; domain-selective: 2 << 60
.send:
    call iu_iotlb
    call iu_wbf
    lea rdi, [rbx + IU_LOCK]
    call spin_unlock
    popfq
    pop rdi
    jmp .unit
.out:
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; iommu_map_va(RDI = domain, RSI = mapped address, RDX = bytes, ECX =
; VT_R | VT_W) -> CF if a page is not mapped or there is no memory: each
; page it covers, wherever it is. Preserves others.
iommu_map_va:
    test rdi, rdi
    jz .nothing
    push rax
    push rdx
    push rsi
    push r8
    push r9
    lea r8, [rsi + rdx]
    mov r9, rsi
    and r9, -4096
.page:
    cmp r9, r8
    jae .ok
    push rdi
    mov rdi, r9
    call vmm_translate
    pop rdi
    jc .fail
    mov rsi, rax
    mov edx, 4096
    call iommu_map
    jc .fail
    add r9, 4096
    jmp .page
.ok:
    clc
.fail:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rax
    ret
.nothing:
    clc
    ret

; iommu_unmap_va(RDI = domain, RSI = mapped address, RDX = bytes): what
; iommu_map_va did undone. Preserves all.
iommu_unmap_va:
    test rdi, rdi
    jz .nothing
    push rax
    push rdx
    push rsi
    push r8
    push r9
    lea r8, [rsi + rdx]
    mov r9, rsi
    and r9, -4096
.page:
    cmp r9, r8
    jae .out
    push rdi
    mov rdi, r9
    call vmm_translate
    pop rdi
    jc .next
    mov rsi, rax
    mov edx, 4096
    call iommu_unmap
.next:
    add r9, 4096
    jmp .page
.out:
    pop r9
    pop r8
    pop rsi
    pop rdx
    pop rax
.nothing:
    ret

; -----------------------------------------------------------------------------
;  Faults
; -----------------------------------------------------------------------------

; iommu_irq: VEC_IOMMU, on the BSP: recorded, and the main loop woken to say so
iommu_irq:
    call iommu_faults
    jmp sched_irq_main

; iommu_service (main loop): each fault not said yet, said
iommu_service:
    mov rax, [iommu_fault_count]
    cmp rax, [iommu_fault_said]
    je .out
    push rbx
    push rcx
    mov rcx, rax
    sub rcx, [iommu_fault_said]
    cmp rcx, IOMMU_LOG
    jbe .say
    sub rcx, IOMMU_LOG
    KLOG "iommu: %u more faults, not kept", rcx
    mov rax, [iommu_fault_count]
    sub rax, IOMMU_LOG
    mov [iommu_fault_said], rax
.say:
    mov rax, [iommu_fault_said]
    cmp rax, [iommu_fault_count]
    jae .said
    and eax, IOMMU_LOG - 1
    shl eax, 4
    lea rbx, [iommu_fault_log]
    add rbx, rax
    push rdi
    lea rdi, [str_iommu_fault]
    call iommu_fault_say
    pop rdi
    inc qword [iommu_fault_said]
    jmp .say
.said:
    pop rcx
    pop rbx
.out:
    ret

; iommu_fault_say(RBX = a fault log entry, RDI = what goes first): "00:02.0
; writing 0x..., reason 05". Preserves all.
iommu_fault_say:
    push rax
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov r8, rdi
    movzx eax, word [rbx + FL_SID]
    mov ecx, eax
    shr eax, 8
    mov edx, ecx
    shr ecx, 3
    and ecx, 31
    and edx, 7
    lea rsi, [str_iommu_writing]
    cmp byte [rbx + FL_READ], 0
    je .what
    lea rsi, [str_iommu_reading]
.what:
    movzx edi, byte [rbx + FL_REASON]
    KLOG "%s%02x:%02x.%u %s %p, reason %02x", r8, rax, rcx, rdx, rsi, qword [rbx + FL_ADDR], rdi
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rax
    ret

; iommu_faults: what every unit recorded, into iommu_fault_log and the
; counts, and cleared. From interrupts or not. Preserves all.
iommu_faults:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    pushfq
    cli
    lea rdi, [iommu_fault_lock]
    call spin_lock
    xor r9d, r9d
.unit:
    cmp r9d, [iommu_count]
    jae .done
    imul rbx, r9, IU_SIZE
    lea rax, [iommu_units]
    add rbx, rax
    test dword [rbx + IU_FLAGS], IUF_ON
    jz .next_unit
    mov r8, [rbx + IU_MMIO]
    mov eax, [r8 + VTR_FSTS]
    test eax, 2                         ; primary faults pending
    jz .clear_status
    xor ecx, ecx                        ; look at every record
.record:
    cmp ecx, [rbx + IU_NFR]
    jae .clear_status
    mov esi, ecx
    shl esi, 4
    add esi, [rbx + IU_FRO]
    mov rdx, [r8 + rsi + 8]
    bt rdx, 63
    jnc .next_record
    mov eax, [iommu_fault_next]         ; into the log
    and eax, IOMMU_LOG - 1
    shl eax, 4
    lea rdi, [iommu_fault_log]
    add rdi, rax
    mov rax, [r8 + rsi]
    and rax, -4096
    mov [rdi + FL_ADDR], rax
    mov [rdi + FL_SID], dx
    mov rax, rdx
    shr rax, 32
    mov [rdi + FL_REASON], al
    mov rax, rdx
    shr rax, 62
    and eax, 1
    mov [rdi + FL_READ], al
    mov [rdi + FL_UNIT], r9d
    inc dword [iommu_fault_next]
    inc qword [iommu_fault_count]
    inc qword [rbx + IU_FAULTS]
    mov dword [r8 + rsi + 12], 1 << 31  ; F: written 1, cleared
.next_record:
    inc ecx
    jmp .record
.clear_status:
    mov eax, [r8 + VTR_FSTS]
    and eax, 0x7D
    jz .next_unit
    mov [r8 + VTR_FSTS], eax
.next_unit:
    inc r9d
    jmp .unit
.done:
    lea rdi, [iommu_fault_lock]
    call spin_unlock
    popfq
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .rodata
align 8
vt_addr_mask:   dq VT_ADDR
str_iommu_fw:   db 'firmware', 0
str_iommu_fault: db 'iommu: fault: ', 0
str_iommu_writing: db 'writing', 0
str_iommu_reading: db 'reading', 0

section .bss
alignb 8
iommu_units:    resb MAX_IOMMU * IU_SIZE
iommu_domains:  resb MAX_DOMAINS * DM_SIZE
rmrr_list:      resb MAX_RMRR * RM_SIZE
iommu_fault_log: resb IOMMU_LOG * FL_SIZE
iommu_fault_count: resq 1
iommu_fault_said: resq 1                ; how many of them iommu_service said
iommu_fw_domain: resq 1
iommu_count:    resd 1
domain_count:   resd 1
rmrr_count:     resd 1
iommu_levels:   resd 1
iommu_fault_next: resd 1
iommu_fault_lock: resd 1
iommu_on:       resb 1
iommu_cm:       resb 1
iommu_flush_needed: resb 1
