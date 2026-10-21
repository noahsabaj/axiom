; =============================================================================
;  hda.asm - Intel High Definition Audio: the sound controller of every PC
;  since 2004 (Intel's, AMD's, and NVIDIA's for HDMI), and the codecs on
;  its link. Commands go to a codec through the CORB and its answers come
;  back in the RIRB, both polled. The codec's audio function is walked for
;  its output pins (line out, speakers, headphones) and a way from each to
;  a converter; all of them play one stream, the first output stream
;  descriptor's, 48 kHz 16-bit stereo, from the buffer sound.asm keeps
;  filled. No interrupts: the mixer reads where the DMA has got to.
;
;  Registers by convention: R12 = the controller's registers.
; =============================================================================

HDA_GCAP        equ 0x00                ; word: its streams
HDA_GCTL        equ 0x08                ; bit 0: out of reset
HDA_STATESTS    equ 0x0E                ; word: which codecs answered
HDA_INTCTL      equ 0x20
HDA_CORBLBASE   equ 0x40
HDA_CORBUBASE   equ 0x44
HDA_CORBWP      equ 0x48                ; word
HDA_CORBRP      equ 0x4A                ; word: bit 15 resets it
HDA_CORBCTL     equ 0x4C                ; byte: bit 1 runs it
HDA_CORBSIZE    equ 0x4E                ; byte: what it can be in 7:4, what it is in 1:0
HDA_RIRBLBASE   equ 0x50
HDA_RIRBUBASE   equ 0x54
HDA_RIRBWP      equ 0x58                ; word: bit 15 resets it
HDA_RINTCNT     equ 0x5A                ; word
HDA_RIRBCTL     equ 0x5C                ; byte: bit 1 runs it
HDA_RIRBSTS     equ 0x5D                ; byte: written with 1s to clear
HDA_RIRBSIZE    equ 0x5E
HDA_SD0         equ 0x80                ; stream descriptors, 0x20 each: input, output, both

; a stream descriptor
SD_CTL          equ 0x00                ; 3 bytes: bit 0 reset, bit 1 run, the tag in 23:20
SD_STS          equ 0x03                ; byte: written with 1s to clear
SD_LPIB         equ 0x04                ; where the DMA is in the buffer, in bytes
SD_CBL          equ 0x08                ; the buffer's bytes
SD_LVI          equ 0x0C                ; word: the last entry of its list
SD_FMT          equ 0x12                ; word
SD_BDPL         equ 0x18                ; the list
SD_BDPU         equ 0x1C

; the page the controller reads commands from and writes answers to
HDA_CORB        equ 0                   ; 256 commands, a dword each
HDA_RIRB        equ 1024                ; 256 answers, a qword each
HDA_BDL         equ 3072                ; the stream's buffer, in two pieces of 16 bytes

SND_TAG         equ 1                   ; the stream's tag, on the link
SND_FMT         equ 0x0011              ; 48 kHz, 16 bits, 2 channels

; verbs: the node goes in 27:20, the codec in 31:28
V_PARAM         equ 0xF0000             ; a parameter (P_*)
V_CONN          equ 0xF0200             ; four entries of its connection list (two long ones)
V_CFG           equ 0xF1C00             ; a pin's configuration, as the board was made
V_SELECT        equ 0x70100             ; the input it takes
V_POWER         equ 0x70500             ; D0
V_STREAM        equ 0x70600             ; a converter's stream and first channel
V_PINCTL        equ 0x70700
V_EAPD          equ 0x70C00             ; an external amplifier on
V_FORMAT        equ 0x20000
V_AMP           equ 0x30000
P_VENDOR        equ 0x00
P_NODES         equ 0x04                ; the first node under it in 23:16, how many in 7:0
P_FGTYPE        equ 0x05                ; 1: audio
P_WCAPS         equ 0x09
P_PINCAPS       equ 0x0C
P_INAMP         equ 0x0D
P_CONNLEN       equ 0x0E                ; entries in 6:0, long ones if bit 7
P_OUTAMP        equ 0x12                ; 0 dB in 6:0

; a widget's capabilities (P_WCAPS): its type in 23:20
WT_OUT          equ 0                   ; a converter to analog (a DAC)
WT_MIXER        equ 2
WT_SELECT       equ 3
WT_PIN          equ 4
WC_INAMP        equ 1 << 1
WC_OUTAMP       equ 1 << 2
WC_AMPOVR       equ 1 << 3              ; its amplifiers are its own, not the function's
WC_CONN         equ 1 << 8
WC_DIGITAL      equ 1 << 9
WC_POWER        equ 1 << 10

HDA_DEPTH       equ 6                   ; nodes from a pin to its converter, at most
HDA_CONN_MAX    equ 16                  ; inputs of a node looked at

section .text

; hda_init: the first HD Audio controller with a codec that plays to an
; output Axiom can drive; its stream started, silent. From snd_boot, with
; snd_buf made.
hda_init:
    push rbx
    push r12
    push r13
    lea r13, [pci_devices]
    xor ebx, ebx
.next:
    cmp ebx, [pci_count]
    jae .none
    cmp byte [r13 + PE_CLASS], 0x04     ; multimedia: HD Audio
    jne .skip
    cmp byte [r13 + PE_SUBCLASS], 0x03
    jne .skip
    inc dword [hda_seen]
    mov rdi, r13
    call hda_try
    jnc .out
.skip:
    add r13, PCI_ENTRY
    inc ebx
    jmp .next
.none:
    mov qword [hda_regs], 0
    cmp dword [hda_seen], 0
    jne .unused
    KLOG "sound: no HD Audio controller; sound plays to nothing"
    jmp .out
.unused:
    KLOG "sound: no codec with an output Axiom drives; sound plays to nothing"
.out:
    pop r13
    pop r12
    pop rbx
    ret

; hda_try(RDI = PCI entry) -> CF if it plays nothing (and is back in reset)
hda_try:
    push rbx
    push r12
    push r13
    mov r13, rdi
    call pci_bdf
    mov [hda_bdf], eax
    mov eax, [r13 + PE_VENDOR]          ; vendor and device
    mov [hda_ids], eax
    cmp qword [hda_domain], 0           ; its DMA, through a domain of its own
    jne .domain
    lea rdi, [str_hda_domain]
    call iommu_domain_new
    mov [hda_domain], rax
    test rax, rax
    jz .domain
    mov rdi, rax                        ; the commands, answers and list; the sound
    mov rsi, [hda_page]
    sub rsi, [phys_base]
    mov edx, 4096
    mov ecx, VT_RW
    call iommu_map
    jc .fail
    mov rsi, [snd_buf]
    sub rsi, [phys_base]
    mov edx, SND_BUF
    mov ecx, VT_R
    call iommu_map
    jc .fail
.domain:
    mov rdi, [hda_domain]
    mov esi, [hda_bdf]
    call iommu_attach
    jc .fail
    mov edi, [hda_bdf]
    call pci_power_on
    call pci_mem_bar
    jc .fail
    mov r12, rax
    mov esi, 0x04                       ; memory decode, bus master, no INTx
    call pci_read32
    or eax, 6 | (1 << 10)
    mov edx, eax
    call pci_write32
    cmp word [r13 + PE_VENDOR], 0x8086  ; Intel's: traffic class 0, as Linux
    jne .map                            ; sets it
    mov esi, 0x44
    call pci_read32
    and eax, ~7
    mov edx, eax
    call pci_write32
.map:
    mov rdi, r12
    mov esi, 0x4000
    call mmio_map
    test rax, rax
    jz .fail
    mov r12, rax
    mov [hda_regs], rax
    call hda_reset
    jc .off
    call hda_rings
    jc .off
    movzx ebx, word [r12 + HDA_STATESTS]
    mov [hda_codecs], ebx
    mov word [r12 + HDA_STATESTS], bx   ; seen
    xor r13d, r13d
.codec:
    cmp r13d, 15
    jae .off
    bt ebx, r13d
    jnc .next_codec
    mov esi, r13d
    call hda_codec
    test eax, eax
    jnz .found
.next_codec:
    inc r13d
    jmp .codec
.found:
    call hda_stream
    jc .off
    movzx eax, word [hda_ids]
    movzx ecx, word [hda_ids + 2]
    movzx edx, word [hda_vendor + 2]
    movzx esi, word [hda_vendor]
    mov r8d, [hda_outs]
    KLOG "sound: HD Audio %04x:%04x, codec %u (%04x:%04x), %u outputs", rax, rcx, r13, rdx, rsi, r8
    clc
    jmp .out
.off:
    mov dword [r12 + HDA_GCTL], 0       ; back into reset: its DMA stops
    movzx eax, word [hda_ids]
    movzx ecx, word [hda_ids + 2]
    KLOG "sound: HD Audio %04x:%04x plays nothing Axiom drives", rax, rcx
.fail:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; hda_reset(R12) -> CF if it would not come out of reset: in, then out,
; and the codecs given time to say they are there
hda_reset:
    mov byte [r12 + HDA_CORBCTL], 0     ; the rings stopped
    mov byte [r12 + HDA_RIRBCTL], 0
    and dword [r12 + HDA_GCTL], ~1
    mov ecx, 1000
.in:
    test dword [r12 + HDA_GCTL], 1
    jz .held
    mov edi, 10
    call delay_us
    dec ecx
    jnz .in
    jmp .fail
.held:
    mov edi, 100
    call delay_us
    or dword [r12 + HDA_GCTL], 1
    mov ecx, 10000
.out:
    test dword [r12 + HDA_GCTL], 1
    jnz .up
    mov edi, 10
    call delay_us
    dec ecx
    jnz .out
    jmp .fail
.up:
    mov edi, 1000                       ; codecs ask within 521 us
    call delay_us
    mov dword [r12 + HDA_INTCTL], 0
    clc
    ret
.fail:
    stc
    ret

; hda_rings(R12) -> CF on failure: the CORB and the RIRB, running
hda_rings:
    mov rax, [hda_page]
    sub rax, [phys_base]
    mov [r12 + HDA_CORBLBASE], eax
    shr rax, 32
    mov [r12 + HDA_CORBUBASE], eax
    mov al, [r12 + HDA_CORBSIZE]
    call hda_size
    mov [r12 + HDA_CORBSIZE], al
    mov [hda_corb_mask], ecx
    mov word [r12 + HDA_CORBRP], 0x8000 ; its read pointer reset
    mov ecx, 1000
.rp_set:                                ; (QEMU's never reads back as set)
    test word [r12 + HDA_CORBRP], 0x8000
    jnz .rp_clear
    mov edi, 1
    call delay_us
    dec ecx
    jnz .rp_set
.rp_clear:
    mov word [r12 + HDA_CORBRP], 0
    mov ecx, 1000
.rp_zero:
    test word [r12 + HDA_CORBRP], 0x8000
    jz .corb
    mov edi, 1
    call delay_us
    dec ecx
    jnz .rp_zero
    stc
    ret
.corb:
    mov word [r12 + HDA_CORBWP], 0
    mov dword [hda_corb_wp], 0
    mov byte [r12 + HDA_CORBCTL], 2
    mov rax, [hda_page]
    sub rax, [phys_base]
    add rax, HDA_RIRB
    mov [r12 + HDA_RIRBLBASE], eax
    shr rax, 32
    mov [r12 + HDA_RIRBUBASE], eax
    mov al, [r12 + HDA_RIRBSIZE]
    call hda_size
    mov [r12 + HDA_RIRBSIZE], al
    mov [hda_rirb_mask], ecx
    mov word [r12 + HDA_RIRBWP], 0x8000 ; its write pointer reset
    mov word [r12 + HDA_RINTCNT], 1
    mov dword [hda_rirb_rp], 0
    mov byte [r12 + HDA_RIRBSTS], 5
    mov byte [r12 + HDA_RIRBCTL], 3     ; with its status flag, which QEMU
    clc                                 ; waits to see cleared (interrupts
    ret                                 ; stay off in INTCTL)

; hda_size(AL = a ring's size register) -> AL = the largest it can be, as
; written there; ECX = its entries - 1
hda_size:
    test al, 0x40
    jnz .big
    test al, 0x20
    jnz .mid
    mov al, 0
    mov ecx, 1
    ret
.mid:
    mov al, 1
    mov ecx, 15
    ret
.big:
    mov al, 2
    mov ecx, 255
    ret

; hda_send(EDI = a node, ESI = a verb and what it takes) -> EAX = the
; codec's answer, CF if none came. Preserves others.
hda_send:
    push rdi
    shl edi, 20
    or edi, esi
    call hda_verb
    pop rdi
    ret

; hda_verb(EDI = a node << 20 | a verb, to the codec in hda_cad) -> EAX =
; its answer, CF if none came within 10 ms. Preserves others.
hda_verb:
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    mov rsi, [hda_regs]
    or edi, [hda_cad]
    mov eax, [hda_corb_wp]
    inc eax
    and eax, [hda_corb_mask]
    mov [hda_corb_wp], eax
    mov rdx, [hda_page]
    mov [rdx + HDA_CORB + rax * 4], edi
    mov [rsi + HDA_CORBWP], ax
    mov ecx, 2000
.wait:
    movzx eax, word [rsi + HDA_RIRBWP]
    and eax, [hda_rirb_mask]
    cmp eax, [hda_rirb_rp]
    jne .answer
    mov edi, 5
    call delay_us
    dec ecx
    jnz .wait
    xor eax, eax
    stc
    jmp .out
.answer:
    mov eax, [hda_rirb_rp]
    inc eax
    and eax, [hda_rirb_mask]
    mov [hda_rirb_rp], eax
    mov r8d, [rdx + HDA_RIRB + rax * 8 + 4]
    mov eax, [rdx + HDA_RIRB + rax * 8]
    mov byte [rsi + HDA_RIRBSTS], 5     ; more may come
    test r8d, 0x10                      ; unsolicited: not the answer
    jnz .wait
    clc
.out:
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    ret

; hda_codec(ESI = its address) -> EAX = the outputs it now plays to, with
; hda_cad, hda_afg and hda_vendor set: its audio function's widgets read,
; and a way from each output pin to a converter set up
hda_codec:
    push rbx
    push r12
    push r13
    push r14
    shl esi, 28
    mov [hda_cad], esi
    mov dword [hda_outs], 0
    xor edi, edi
    mov esi, V_PARAM | P_VENDOR
    call hda_send
    jc .none
    mov [hda_vendor], eax
    mov esi, V_PARAM | P_NODES
    call hda_send
    jc .none
    movzx r13d, al                      ; its function groups
    mov r12d, eax
    shr r12d, 16
    and r12d, 0xFF
.group:
    test r13d, r13d
    jz .none
    mov edi, r12d
    mov esi, V_PARAM | P_FGTYPE
    call hda_send
    jc .next_group
    and eax, 0xFF
    cmp eax, 1                          ; audio
    je .audio
.next_group:
    inc r12d
    dec r13d
    jmp .group
.audio:
    mov [hda_afg], r12d
    mov edi, r12d
    mov esi, V_POWER
    call hda_send
    mov edi, 1000
    call delay_us
    mov edi, r12d
    mov esi, V_PARAM | P_NODES
    call hda_send
    jc .none
    movzx r13d, al
    shr eax, 16
    and eax, 0xFF
    mov r12d, eax                       ; R12D = the first widget
    mov [hda_w0], eax
    add eax, r13d
    cmp eax, 256
    jbe .counted
    mov eax, 256
.counted:
    mov [hda_wend], eax
    lea rdi, [hda_caps]                 ; each widget's capabilities
    mov ecx, 256
    xor eax, eax
    rep stosd
    mov ebx, r12d
.caps:
    cmp ebx, [hda_wend]
    jae .pins
    mov edi, ebx
    mov esi, V_PARAM | P_WCAPS
    call hda_send
    jc .none
    lea rcx, [hda_caps]
    mov [rcx + rbx * 4], eax
    inc ebx
    jmp .caps
.pins:
    mov ebx, r12d
.pin:
    cmp ebx, [hda_wend]
    jae .done
    mov edi, ebx
    call hda_output
    jc .next_pin
    inc dword [hda_outs]
.next_pin:
    inc ebx
    jmp .pin
.done:
    mov eax, [hda_outs]
    jmp .out
.none:
    xor eax, eax
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; hda_output(EDI = a node) -> CF unless it is an output pin that now plays:
; line out, speakers or headphones, not digital, wired on this board, and
; a way found from it to a converter
hda_output:
    push rbx
    push r12
    push r13
    mov ebx, edi
    lea rax, [hda_caps]
    mov eax, [rax + rbx * 4]
    test eax, WC_DIGITAL
    jnz .no
    shr eax, 20
    and eax, 0xF
    cmp eax, WT_PIN
    jne .no
    mov esi, V_CFG
    call hda_send
    jc .no
    mov ecx, eax
    shr ecx, 30
    cmp ecx, 1                          ; connected to nothing
    je .no
    shr eax, 20
    and eax, 0xF                        ; 0 line out, 1 speakers, 2 headphones
    cmp eax, 2
    ja .no
    mov r12d, eax
    mov esi, V_PARAM | P_PINCAPS
    call hda_send
    jc .no
    test eax, 1 << 4                    ; it can be an output
    jz .no
    mov r13d, eax
    xor esi, esi
    call hda_find
    jc .no
    call hda_route
    mov esi, V_PINCTL | 0x40            ; out, and for headphones their amplifier
    cmp r12d, 2
    jne .pinctl
    or esi, 0x80
.pinctl:
    mov edi, ebx
    call hda_send
    test r13d, 1 << 16                  ; an external amplifier: on
    jz .said
    mov esi, V_EAPD | 2
    call hda_send
.said:
    lea rax, [hda_out_names]
    mov rsi, [rax + r12 * 8]
    mov eax, [hda_plen]
    lea rcx, [hda_path]
    mov ecx, [rcx + rax * 4 - 4]
    mov eax, [hda_plen]
    KLOG "sound: %s at node %x, through %u nodes from converter %x", rsi, rbx, rax, rcx
    clc
    jmp .out
.no:
    stc
.out:
    pop r13
    pop r12
    pop rbx
    ret

; hda_find(EDI = a node, ESI = how many came before it) -> CF clear if a
; converter is reached through it: the way there in hda_path, the input
; taken at each step in hda_pidx, how many nodes in hda_plen
hda_find:
    push rbx
    push r12
    push r13
    push r14
    mov ebx, edi
    mov r12d, esi
    lea rax, [hda_path]
    mov [rax + r12 * 4], ebx
    lea rax, [hda_caps]
    mov r13d, [rax + rbx * 4]
    mov eax, r13d
    shr eax, 20
    and eax, 0xF
    cmp eax, WT_OUT
    jne .through
    test r13d, WC_DIGITAL
    jnz .no
    lea eax, [r12 + 1]
    mov [hda_plen], eax
    clc
    jmp .out
.through:
    cmp r12d, HDA_DEPTH - 1
    jae .no
    cmp eax, WT_MIXER
    je .inputs
    cmp eax, WT_SELECT
    je .inputs
    cmp eax, WT_PIN                     ; a pin only to begin with
    jne .no
    test r12d, r12d
    jnz .no
.inputs:
    test r13d, WC_CONN
    jz .no
    mov edi, ebx
    call hda_conns
    mov r14d, eax
    xor r13d, r13d
.input:
    cmp r13d, r14d
    jae .no
    mov edi, ebx
    mov esi, r13d
    call hda_conn
    cmp eax, [hda_w0]                   ; one of the function's widgets
    jb .next
    cmp eax, [hda_wend]
    jae .next
    xor ecx, ecx                        ; and not on the way already
.seen:
    lea rdx, [hda_path]
    cmp eax, [rdx + rcx * 4]
    je .next
    inc ecx
    cmp ecx, r12d
    jbe .seen
    lea rdx, [hda_pidx]
    mov [rdx + r12 * 4], r13d
    mov edi, eax
    lea esi, [r12 + 1]
    call hda_find
    jnc .out
.next:
    inc r13d
    jmp .input
.no:
    stc
.out:
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; hda_conns(EDI = a node) -> EAX = the entries of its connection list, at
; most HDA_CONN_MAX. Preserves others.
hda_conns:
    push rsi
    mov esi, V_PARAM | P_CONNLEN
    call hda_send
    jnc .got
    xor eax, eax
.got:
    and eax, 0x7F
    cmp eax, HDA_CONN_MAX
    jbe .out
    mov eax, HDA_CONN_MAX
.out:
    pop rsi
    ret

; hda_conn(EDI = a node, ESI = an index) -> EAX = that entry of its
; connection list, 0 if there is none (a range's flag left out: a range
; reads as its last node). Preserves others.
hda_conn:
    push rcx
    push rsi
    mov ecx, esi
    mov esi, V_PARAM | P_CONNLEN
    call hda_send
    jc .none
    test al, 0x80
    jnz .long
    mov esi, ecx
    and esi, ~3
    or esi, V_CONN
    call hda_send
    jc .none
    and ecx, 3
    shl ecx, 3
    shr eax, cl
    and eax, 0x7F
    jmp .out
.long:
    mov esi, ecx
    and esi, ~1
    or esi, V_CONN
    call hda_send
    jc .none
    and ecx, 1
    shl ecx, 4
    shr eax, cl
    and eax, 0x7FFF
    jmp .out
.none:
    xor eax, eax
.out:
    pop rsi
    pop rcx
    ret

; hda_amp(EDI = a node, ESI = P_OUTAMP or P_INAMP) -> EAX = its 0 dB step,
; from its own amplifier's capabilities or else the function's. Preserves
; others.
hda_amp:
    push rdi
    push rcx
    lea rax, [hda_caps]
    test dword [rax + rdi * 4], WC_AMPOVR
    jnz .own
    mov edi, [hda_afg]
.own:
    or esi, V_PARAM
    call hda_send
    jnc .got
    xor eax, eax
.got:
    and eax, 0x7F
    pop rcx
    pop rdi
    ret

; hda_route: the way in hda_path set up. Each node powered and its output
; at 0 dB; at each step the input taken chosen (a pin, a selector) or
; heard alone (a mixer's other inputs muted); the converter on the stream.
hda_route:
    push rbx
    push r12
    push r13
    push r14
    push r15
    xor r12d, r12d
.node:
    cmp r12d, [hda_plen]
    jae .out
    lea rax, [hda_path]
    mov ebx, [rax + r12 * 4]
    lea rax, [hda_caps]
    mov r13d, [rax + rbx * 4]
    mov edi, ebx
    test r13d, WC_POWER
    jz .powered
    mov esi, V_POWER
    call hda_send
.powered:
    test r13d, WC_OUTAMP
    jz .no_out_amp
    mov esi, P_OUTAMP
    call hda_amp
    lea esi, [rax + V_AMP + 0xB000]     ; the output's, left and right
    call hda_send
.no_out_amp:
    lea eax, [r12 + 1]
    cmp eax, [hda_plen]
    jae .converter
    lea rax, [hda_pidx]
    mov r14d, [rax + r12 * 4]
    mov r15d, r13d
    shr r15d, 20
    and r15d, 0xF
    cmp r15d, WT_MIXER
    je .mixer
    mov esi, r14d                       ; a pin or a selector: that input
    or esi, V_SELECT
    call hda_send
    cmp r15d, WT_SELECT
    jne .next
.mixer:
    test r13d, WC_INAMP
    jz .next
    mov esi, P_INAMP
    call hda_amp
    mov r8d, eax
    call hda_conns
    mov ecx, eax
    xor edx, edx
.input:
    cmp edx, ecx
    jae .next
    mov esi, edx                        ; that input's, left and right
    shl esi, 8
    or esi, V_AMP + 0x7000
    cmp edx, r14d
    jne .mute
    or esi, r8d
    jmp .amp
.mute:
    or esi, 0x80
.amp:
    call hda_send
    inc edx
    jmp .input
.converter:
    mov esi, V_STREAM | (SND_TAG << 4)  ; channels 0 and 1
    call hda_send
    mov esi, V_FORMAT | SND_FMT
    call hda_send
.next:
    inc r12d
    jmp .node
.out:
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; hda_stream(R12) -> CF if it has no output stream: the first output
; stream descriptor reset, given snd_buf in two pieces, and run
hda_stream:
    push rbx
    movzx eax, word [r12 + HDA_GCAP]
    test eax, 0xF000                    ; output streams
    jz .fail
    shr eax, 8
    and eax, 0xF                        ; after the input streams
    shl eax, 5
    lea rbx, [r12 + HDA_SD0 + rax]
    mov byte [rbx + SD_CTL], 0
    or byte [rbx + SD_CTL], 1           ; reset
    mov ecx, 1000
.in:
    test byte [rbx + SD_CTL], 1
    jnz .held
    mov edi, 1
    call delay_us
    dec ecx
    jnz .in
.held:
    and byte [rbx + SD_CTL], ~1
    mov ecx, 1000
.out:
    test byte [rbx + SD_CTL], 1
    jz .reset
    mov edi, 1
    call delay_us
    dec ecx
    jnz .out
    jmp .fail
.reset:
    mov rdi, [hda_page]                 ; the buffer, in two halves
    mov rax, [snd_buf]
    sub rax, [phys_base]
    mov [rdi + HDA_BDL], rax
    mov dword [rdi + HDA_BDL + 8], SND_BUF / 2
    mov dword [rdi + HDA_BDL + 12], 0
    add rax, SND_BUF / 2
    mov [rdi + HDA_BDL + 16], rax
    mov dword [rdi + HDA_BDL + 24], SND_BUF / 2
    mov dword [rdi + HDA_BDL + 28], 0
    lea rax, [rdi + HDA_BDL]
    sub rax, [phys_base]
    mov [rbx + SD_BDPL], eax
    shr rax, 32
    mov [rbx + SD_BDPU], eax
    mov dword [rbx + SD_CBL], SND_BUF
    mov word [rbx + SD_LVI], 1
    mov word [rbx + SD_FMT], SND_FMT
    mov byte [rbx + SD_CTL + 2], SND_TAG << 4
    mov byte [rbx + SD_STS], 0x1C
    or byte [rbx + SD_CTL], 2           ; run
    mov [hda_sd], rbx
    clc
    pop rbx
    ret
.fail:
    stc
    pop rbx
    ret

section .rodata
str_hda_domain: db 'sound', 0
str_hda_line:   db 'line out', 0
str_hda_spk:    db 'speakers', 0
str_hda_hp:     db 'headphones', 0
align 8
hda_out_names:  dq str_hda_line, str_hda_spk, str_hda_hp

section .bss
alignb 8
hda_regs:       resq 1                  ; the controller in use, 0 if none
hda_sd:         resq 1                  ; its output stream's descriptor, once it runs
hda_domain:     resq 1
hda_page:       resq 1                  ; the CORB, the RIRB, the list (snd_boot makes it)
hda_bdf:        resd 1
hda_seen:       resd 1                  ; controllers found
hda_ids:        resd 1                  ; vendor, device
hda_codecs:     resd 1                  ; which answered (STATESTS)
hda_cad:        resd 1                  ; the codec in use, << 28
hda_vendor:     resd 1                  ; its vendor and device
hda_afg:        resd 1                  ; its audio function
hda_w0:         resd 1                  ; its widgets, from here
hda_wend:       resd 1                  ; to here
hda_outs:       resd 1                  ; the pins it plays to
hda_corb_wp:    resd 1
hda_corb_mask:  resd 1
hda_rirb_rp:    resd 1
hda_rirb_mask:  resd 1
hda_plen:       resd 1
hda_path:       resd HDA_DEPTH          ; a pin, ..., a converter
hda_pidx:       resd HDA_DEPTH          ; the input taken at each
hda_caps:       resd 256                ; each widget's P_WCAPS
