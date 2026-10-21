/* kernel.ld - the kernel's image: kernel.asm's object first in each
   section, then the Rust (src/rust) after it, each section on pages of its
   own for vmm_init's W^X: code, constants, data, then .bss, which is not in
   the file (the loader zeroes it, up to the header's memory size).
   kernel_file_end and kernel_end are the header's two sizes. */

KERNEL_BASE = 0xFFFFFFFF80000000;

SECTIONS
{
    . = KERNEL_BASE;
    .text : {
        KEEP(*kernel.o(.text))          /* its header first, at KERNEL_BASE */
        *(.text .text.*)
    }
    . = ALIGN(4096);
    .rodata : {
        KEEP(*kernel.o(.rodata))
        *(.rodata .rodata.*)
        *(.data.rel.ro .data.rel.ro.*)
        *(.got .got.plt)
    }
    . = ALIGN(4096);
    .data : {
        KEEP(*kernel.o(.data))
        *(.data .data.*)
    }
    kernel_file_end = .;
    . = ALIGN(4096);
    .bss (NOLOAD) : {
        KEEP(*kernel.o(.bss))
        *(.bss .bss.* COMMON)
    }
    . = ALIGN(4096);
    kernel_end = .;

    /DISCARD/ : {
        *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr)
    }
}
