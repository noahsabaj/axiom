; =============================================================================
;  kernel.asm - the Axiom kernel: one flat image linked at KERNEL_BASE.
;  The loader copies the file, zeroes the rest up to the header's memory
;  size (.bss) and jumps to kernel_main.
; =============================================================================

bits 64
default rel

%include "bootinfo.inc"
%include "defs.inc"
%include "macros.inc"

org KERNEL_BASE

section .text progbits align=16
section .rodata progbits align=4096 follows=.text
section .data progbits align=4096 follows=.rodata
section .bss nobits align=4096

[map all build/kernel.map]

section .rodata                         ; each section starts on a page of
kernel_rodata:                          ; its own, for vmm_init's W^X
section .data
kernel_data:

section .text
kernel_header:
    db 'AXIOMKRN'
    dq kernel_main
    dq kernel_file_end - KERNEL_BASE
    dq kernel_end - KERNEL_BASE

section .rodata
%include "gen/font.inc"
align 64
font_data:      incbin "gen/font.bin"
font_end:

section .text
%include "lib.asm"
%include "records.asm"
%include "serial.asm"
%include "cpu.asm"
%include "gdt.asm"
%include "idt.asm"
%include "pmm.asm"
%include "gfx.asm"
%include "acpi.asm"
%include "smbios.asm"
%include "apic.asm"
%include "smp.asm"
%include "vmm.asm"
%include "heap.asm"
%include "object.asm"
%include "kobj.asm"
%include "ring.asm"
%include "sched.asm"
%include "user.asm"
%include "channel.asm"
%include "pci.asm"
%include "vmd.asm"
%include "iommu.asm"
%include "kbd.asm"
%include "usb.asm"
%include "usbdev.asm"
%include "usbhub.asm"
%include "hid.asm"
%include "usbmsc.asm"
%include "bt.asm"
%include "pointer.asm"
%include "nvme.asm"
%include "disk.asm"
%include "store.asm"
%include "fat.asm"
%include "rtc.asm"
%include "log.asm"
%include "net.asm"
%include "ip6.asm"
%include "rtl8168.asm"
%include "rtw.asm"
%include "rtwfw.asm"
%include "rtwmac.asm"
%include "rtwphy.asm"
%include "rtwrx.asm"
%include "rtwtx.asm"
%include "rtwjoin.asm"
%include "rtwwpa.asm"
%include "rtwnet.asm"
%include "tcp.asm"
%include "netapp.asm"
%include "sha256.asm"
%include "sha512.asm"
%include "aesgcm.asm"
%include "crypto.asm"                  ; AES-128 for wpa.asm
%include "wpa.asm"
%include "x25519.asm"
%include "rand.asm"
%include "bignum.asm"
%include "pubkey.asm"
%include "x509.asm"
%include "tls.asm"
%include "http.asm"
%include "httpd.asm"
%include "socket.asm"
%include "json.asm"
%include "text.asm"
%include "claude.asm"
%include "cryptotest.asm"
%include "memtest.asm"
%include "threads.asm"
%include "objtest.asm"
%include "ringtest.asm"
%include "nvmetest.asm"
%include "iommutest.asm"
%include "storetest.asm"
%include "mandel.asm"
%include "ui.asm"
%include "shell.asm"
%include "theme.asm"
%include "draw.asm"
%include "icons.asm"
%include "look.asm"
%include "fscap.asm"
%include "desk.asm"
%include "term.asm"
%include "vt.asm"
%include "window.asm"
%include "hda.asm"
%include "sound.asm"
%include "power.asm"
%include "efivar.asm"
%include "harness.asm"
%include "update.asm"
%include "lxmm.asm"
%include "lxfs.asm"
%include "linux.asm"
%include "lxsig.asm"
%include "lxtty.asm"
%include "lxproc.asm"
%include "lxpipe.asm"
%include "boot.asm"

section .data
align 8
boot_info:      dq 0
boot_rsp:       dq 0                    ; the loader's stack, until it goes back
phys_base:      dq PHYS_BASE
kernel_file_end:

section .bss
alignb 64
percpu:         resb MAX_CPUS * PC_SIZE
alignb 4096
kernel_end:
