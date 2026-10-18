/* axiom.ld - an Axiom program's layout, as the kernel loads an .AXE: flat
   at USER_IMAGE, its header first, then its code, its constants and its
   data, each part from a page of its own, and the zeroes after them. The
   header is made here; tools/mkaxe.py writes the file from 0x400000 to
   __axe_data_end. */

ENTRY(_start)

SECTIONS
{
    . = 0x400000;                       /* USER_IMAGE */
    .axe : {
        QUAD(0x3258454D4F495841)        /* AXE_MAGIC: "AXIOMEX2" */
        QUAD(_start)                    /* AXE_ENTRY */
        QUAD(__axe_text_end)
        QUAD(__axe_rodata_end)
        QUAD(__axe_data_end)            /* the end of the file */
        QUAD(__axe_bss_end)
        KEEP(*(.axe.wants))             /* AXE_WANTS: axiom::entry!'s */
    }
    ASSERT(SIZEOF(.axe) == 56, "the AXE header is 56 bytes: one axiom::entry! in the program")
    .text : {
        *(.text._start)
        *(.text .text.*)
    }
    . = ALIGN(4096);
    __axe_text_end = .;

    .rodata : {
        *(.rodata .rodata.*)
        *(.data.rel.ro .data.rel.ro.*)  /* written at link time, read-only after */
        *(.got .got.plt)
    }
    . = ALIGN(4096);
    __axe_rodata_end = .;

    .data : {
        *(.data .data.*)
    }

    /* thread-local storage (axiom::tls): the template each thread's block
       is made from, its data in the file, its zeroes after (in no space:
       .bss follows .tdata) */
    .tdata : {
        __axe_tls_start = .;
        *(.tdata .tdata.*)
        __axe_tls_data_end = .;
    }
    __axe_data_end = .;
    .tbss : {
        *(.tbss .tbss.* .tcommon)
        __axe_tls_end = .;
    }
    __axe_tls_align = MAX(ALIGNOF(.tdata), ALIGNOF(.tbss));

    .bss (NOLOAD) : {
        *(.bss .bss.*)
        *(COMMON)
    }
    __axe_bss_end = .;

    /DISCARD/ : {
        *(.eh_frame .eh_frame.* .eh_frame_hdr .gcc_except_table .gcc_except_table.*)
        *(.note .note.* .comment)
    }
}
