/*
 * Linker script for PocketQuake on Analogue Pocket
 *
 * Two-stage boot:
 * - Bootloader: 32KB BRAM at 0x00000000 (initialized from firmware.mif)
 * - Quake binary: bridge loads to SDRAM at 0x10200000,
 *   bootloader copies to PSRAM at 0x30000000 for execution
 * - PAK data: read on demand from SD card via dataslot_read()
 *
 * Memory layout:
 * - BRAM:     0x00000000 (32KB)  - Bootloader code, stack
 * - SDRAM:    0x10000000 (64MB)  - BSS + Heap
 *   - 0x10200000: quake.bin LMA (bridge loads here, copied to PSRAM)
 *   - 0x10400000: BSS + Heap (~43.5MB, pak0.pak read on demand from SD)
 * - Terminal: 0x20000000 (8KB)   - Character VRAM
 * - PSRAM:    0x30000000 (16MB)  - Quake code (read-only, CRAM0)
 * - SRAM:     0x38000000 (256KB) - Z-buffer
 * - SysRegs:  0x40000000         - System control registers
 */

ENTRY(_start)

MEMORY {
    BRAM      (rwx) : ORIGIN = 0x00000000, LENGTH = 32K
    PSRAM     (rx)  : ORIGIN = 0x30000000, LENGTH = 16M     /* Quake code VMA (CRAM0, read-only) */
    SDRAM_BSS (rwx) : ORIGIN = 0x10400000, LENGTH = 44M     /* BSS + Heap in SDRAM after quake.bin LMA */
}

/* SDRAM layout symbols */
__sdram_base = 0x10000000;
__sdram_size = 64M;

/* Quake binary: VMA in PSRAM, LMA in SDRAM (bridge loads to SDRAM) */
__quake_entry = 0x30000000;
__quake_load_addr = 0x10200000;

SECTIONS {
    /* Bootloader code - in BRAM, runs at startup */
    .boot : {
        KEEP(*(.text.start))       /* Startup code first */
        *(.text.boot*)             /* Bootloader functions */
        terminal.o(.text*)         /* Terminal functions for boot diagnostics */
        terminal.o(.rodata*)
        terminal.o(.srodata*)
        dataslot.o(.text*)         /* Dataslot functions for loading */
        dataslot.o(.rodata*)
        dataslot.o(.srodata*)
        main.o(.rodata*)           /* Boot string literals + constants */
        main.o(.srodata*)          /* Boot test float constants */
        *(.rodata.boot*)
        . = ALIGN(4);
    } > BRAM

    /* Bootloader data */
    .boot_data : {
        *(.data.boot*)
        *(.sdata.boot*)
        . = ALIGN(4);
    } > BRAM

    /* Bootloader BSS */
    .boot_bss : {
        . = ALIGN(4);
        __bss_start = .;
        *(.bss.boot*)
        *(.sbss.boot*)
        . = ALIGN(4);
        __bss_end = .;
    } > BRAM

    .fastdata : {
        . = ALIGN(4);
        __fastdata_start = .;
        KEEP(*(.fastdata*))
        . = ALIGN(4);
        __fastdata_end = .;
    } > BRAM

    /* === PSRAM sections: Quake code VMA in PSRAM, LMA in SDRAM === */

    /* Quake code section - executes from PSRAM, loaded to SDRAM by bridge */
    .text __quake_entry : AT(__quake_load_addr) {
        __text_start = .;
        KEEP(*(.text*))        /* All code (except boot) - KEEP to prevent gc */
        KEEP(*(.rodata*))      /* Read-only data */
        KEEP(*(.srodata*))     /* Small read-only data (float constants) */
        . = ALIGN(4);
        __text_end = .;
    } > PSRAM

    /* Copy region symbols for bootloader (.text only → PSRAM) */
    __quake_copy_src = LOADADDR(.text);          /* SDRAM LMA */
    __quake_copy_dst = __text_start;             /* PSRAM VMA */
    __quake_copy_size = __text_end - __text_start;

    /* Total quake.bin image size (for deferload: .text + .data) */
    __quake_load_size = SIZEOF(.text) + SIZEOF(.data);

    /* Quake initialized data — in SDRAM (not PSRAM) so PSRAM stays read-only.
     * LMA is contiguous with .text in quake.bin image.  Bootloader copies
     * from LMA to VMA in SDRAM at startup. */
    .data : AT(__quake_load_addr + SIZEOF(.text)) {
        __data_start = .;
        KEEP(*(.data*))
        KEEP(*(.sdata*))
        . = ALIGN(4);
        __data_end = .;
    } > SDRAM_BSS

    /* .data copy symbols for bootloader (SDRAM LMA → SDRAM VMA) */
    __data_copy_src = LOADADDR(.data);
    __data_copy_dst = __data_start;
    __data_copy_size = __data_end - __data_start;

    /* Quake uninitialized data (BSS) - in SDRAM after .data */
    .qbss : {
        . = ALIGN(4);
        __qbss_start = .;
        *(.bss*)
        *(.sbss*)
        *(COMMON)
        . = ALIGN(4);
        __qbss_end = .;
    } > SDRAM_BSS

    /* Heap starts after BSS in SDRAM_BSS region.
     * Reserve a dedicated runtime stack at top of SDRAM to keep game stack
     * away from BRAM boot code. */
    __heap_start = __qbss_end;
    __runtime_stack_top = 0x13000000;          /* Conservative known-good SDRAM region */
    __runtime_stack_size = 512K;               /* 512 KB runtime stack */
    __runtime_stack_bottom = __runtime_stack_top - __runtime_stack_size;
    __heap_end = __runtime_stack_bottom;

    /* Stack at end of BRAM (grows downward) */
    __stack_top = ORIGIN(BRAM) + LENGTH(BRAM);

    /* Provide symbols for C code */
    PROVIDE(_start_addr = ORIGIN(BRAM));
    PROVIDE(_stack_top = __stack_top);
    /* Timer ISR uses a separate 256-byte stack below the main trap stack.
     * Main trap frame is 272 bytes, so timer stack starts 512 bytes below top. */
    PROVIDE(_timer_stack_top = __stack_top - 512);
    /* Single scratch word for trap handler to save t0 before reading mcause */
    PROVIDE(_trap_scratch = __stack_top - 516);
    PROVIDE(_bss_start = __bss_start);
    PROVIDE(_bss_end = __bss_end);
    PROVIDE(_qbss_start = __qbss_start);
    PROVIDE(_qbss_end = __qbss_end);
    PROVIDE(_heap_start = __heap_start);
    PROVIDE(_heap_end = __heap_end);
    PROVIDE(_runtime_stack_top = __runtime_stack_top);
    PROVIDE(_quake_entry = __quake_entry);
    PROVIDE(_quake_copy_src = __quake_copy_src);
    PROVIDE(_quake_copy_dst = __quake_copy_dst);
    PROVIDE(_quake_copy_size = __quake_copy_size);
    PROVIDE(_quake_load_size = __quake_load_size);
    PROVIDE(_data_copy_src = __data_copy_src);
    PROVIDE(_data_copy_dst = __data_copy_dst);
    PROVIDE(_data_copy_size = __data_copy_size);

    /* Keep at least 8 KB BRAM stack/trap headroom after fastdata. */
    ASSERT(__fastdata_end <= (__stack_top - 8192), "BRAM overflow: insufficient stack headroom")
}
