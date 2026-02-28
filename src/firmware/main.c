/*
 * PocketQuake Bootloader
 * Runs from BRAM, loads quake.bin via deferload, copies to PSRAM, jumps to Quake
 */

#include "dataslot.h"
#include "terminal.h"

/* System registers */
#define SYS_STATUS      (*(volatile unsigned int *)0x40000000)
#define SYS_CYCLE_LO    (*(volatile unsigned int *)0x40000004)
#define SYS_DISPLAY_MODE (*(volatile unsigned int *)0x4000000C)

/* Load addresses */
#define QUAKE_SLOT_ID   0           /* data.json slot id for quake.bin */

/* External symbols from linker */
extern char _qbss_start[], _qbss_end[];
extern char _runtime_stack_top[];
extern char _quake_copy_src[];   /* Source address (SDRAM LMA) */
extern char _quake_copy_dst[];   /* Destination address (PSRAM VMA) */
extern char _quake_copy_size[];  /* Size of .text + .data to copy */
/* Quake entry point (in sys_pocket.c, linked in PSRAM) */
extern void quake_main(void);
extern void switch_to_runtime_stack_and_call(void (*entry)(void), void *stack_top);
/* Clear BSS section */
__attribute__((section(".text.boot")))
static void clear_qbss(void) {
    unsigned int *p = (unsigned int *)_qbss_start;
    unsigned int *end = (unsigned int *)_qbss_end;

    while (p < end)
        *p++ = 0;
}

/* Copy Quake binary from SDRAM (LMA) to PSRAM (VMA) for execution */
__attribute__((section(".text.boot")))
static void copy_to_psram(void) {
    volatile unsigned int *src =
        (volatile unsigned int *)SDRAM_UNCACHED((uint32_t)_quake_copy_src);
    volatile unsigned int *dst = (volatile unsigned int *)_quake_copy_dst;
    unsigned int words = (unsigned int)_quake_copy_size / 4;

    for (unsigned int i = 0; i < words; i++)
        dst[i] = src[i];

    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */
}

/* Load quake.bin from data slot into SDRAM LMA via deferload */
__attribute__((section(".text.boot")))
static int load_quake_bin_from_slot(void) {
    uint32_t total = (uint32_t)_quake_copy_size;
    uint32_t base = (uint32_t)_quake_copy_src;
    uint32_t done = 0;

    while (done < total) {
        uint32_t chunk = total - done;
        if (chunk > DMA_CHUNK_SIZE)
            chunk = DMA_CHUNK_SIZE;

        int rc = dataslot_read(QUAKE_SLOT_ID, done, (void *)(base + done), chunk);
        if (rc < 0)
            return rc;

        done += chunk;
    }

    return 0;
}

/*
 * SDRAM data integrity test
 *
 * Tests VexiiRiscv's D-cache write-back and read-fill paths through the
 * AXI4 bus fabric to physical SDRAM.
 *
 * Phase 1 (write-back): Write pattern through D-cache (0x10xx), fence.i
 *   to flush dirty lines, then read back through uncached alias (0x50xx).
 *   Catches corrupted D-cache eviction bursts (16-beat AXI4 writes).
 *
 * Phase 2 (read-fill): Write pattern through uncached path (direct to SDRAM),
 *   evict any stale D-cache lines, then read through cached path (D-cache
 *   refill via 16-beat AXI4 reads).
 *   Catches corrupted cache line fills.
 *
 * Test region: 0x10140000-0x1015FFFF (64KB, between FB1 and quake.bin LMA)
 */
__attribute__((section(".text.boot")))
static int sdram_data_test(void) {
    volatile unsigned int *cached   = (volatile unsigned int *)0x10140000;
    volatile unsigned int *uncached = (volatile unsigned int *)SDRAM_UNCACHED(0x10140000);
    const int words = 16384;  /* 64KB = full D-cache size */
    int errors = 0;
    int total_errors = 0;

    /* ---- Phase 1: D-cache write-back test ---- */
    term_printf("SDRAM WB test: 64KB...");

    /* Write address-as-data through cached path */
    for (int i = 0; i < words; i++)
        cached[i] = 0xA5000000 | (unsigned int)i;

    /* Flush D-cache to SDRAM */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Read back through uncached path (bypass D-cache, read physical SDRAM) */
    for (int i = 0; i < words; i++) {
        unsigned int exp = 0xA5000000 | (unsigned int)i;
        unsigned int got = uncached[i];
        if (got != exp) {
            if (errors < 4)
                term_printf("\n WB @%08X: %08X!=%08X",
                    0x10140000 + i * 4, exp, got);
            errors++;
        }
    }
    total_errors += errors;
    term_printf(errors ? " FAIL(%d)\n" : " OK\n", errors);

    /* ---- Phase 2: D-cache read-fill test ---- */
    errors = 0;
    term_printf("SDRAM RF test: 64KB...");

    /* Evict all D-cache lines for the test region by filling cache with
     * unrelated data (128KB = 2x cache, guarantees full eviction) */
    volatile unsigned int *evict = (volatile unsigned int *)0x10160000;
    for (int i = 0; i < 32768; i++)   /* 128KB */
        evict[i] = 0;
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Write test pattern directly to physical SDRAM (bypass D-cache) */
    for (int i = 0; i < words; i++)
        uncached[i] = 0x5A000000 | (unsigned int)i;

    /* Read back through cached path (D-cache miss → refill from SDRAM) */
    for (int i = 0; i < words; i++) {
        unsigned int exp = 0x5A000000 | (unsigned int)i;
        unsigned int got = cached[i];
        if (got != exp) {
            if (errors < 4)
                term_printf("\n RF @%08X: %08X!=%08X",
                    0x10140000 + i * 4, exp, got);
            errors++;
        }
    }
    total_errors += errors;
    term_printf(errors ? " FAIL(%d)\n" : " OK\n", errors);

    return total_errors;
}

/*
 * PSRAM data integrity test
 *
 * Tests D-cache write-back and read-fill through axi_psram_slave →
 * psram_controller → physical CRAM0.  Each 32-bit D-cache word becomes
 * 16 individual PSRAM word ops (16-beat burst decomposed to single words,
 * each word = 2 × 16-bit PSRAM accesses).
 *
 * 1. Write 64KB pattern through D-cache to PSRAM scratch region
 * 2. fence.i  (flush dirty lines → PSRAM)
 * 3. Evict all D-cache lines by writing 128KB to SDRAM
 * 4. Read back from PSRAM (D-cache miss → refill from PSRAM)
 * 5. Compare
 *
 * Test region: 0x30100000 (1MB into PSRAM, well past quake.bin ~342KB)
 */
__attribute__((section(".text.boot")))
static int psram_data_test(void) {
    volatile unsigned int *psram = (volatile unsigned int *)0x30100000;
    const int words = 16384;  /* 64KB */
    int errors = 0;

    term_printf("PSRAM test: 64KB...");

    /* Write address-as-data through D-cache → PSRAM */
    for (int i = 0; i < words; i++)
        psram[i] = 0xB4000000 | (unsigned int)i;

    /* Flush D-cache (dirty lines written back to PSRAM) */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Evict all PSRAM lines from D-cache by filling with SDRAM data.
     * 128KB = 2× cache size → both ways of all 512 sets replaced. */
    volatile unsigned int *evict = (volatile unsigned int *)0x10140000;
    for (int i = 0; i < 32768; i++)   /* 128KB */
        evict[i] = 0xDEAD0000 | (unsigned int)i;
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Read back from PSRAM (D-cache miss → 16-beat refill from PSRAM) */
    for (int i = 0; i < words; i++) {
        unsigned int exp = 0xB4000000 | (unsigned int)i;
        unsigned int got = psram[i];
        if (got != exp) {
            if (errors < 4)
                term_printf("\n @%08X: %08X!=%08X",
                    0x30100000 + i * 4, exp, got);
            errors++;
        }
    }

    term_printf(errors ? " FAIL(%d)\n" : " OK\n", errors);
    return errors;
}

__attribute__((section(".text.boot")))
int main(void) {
    /* Show loading message on terminal before switching to framebuffer */
    term_init();
    term_printf("Loading quake.bin...\n");

    /* Wait for APF bridge allcomplete before issuing dataslot commands */
    unsigned int start_wait = SYS_CYCLE_LO;
    while (!(SYS_STATUS & (1 << 1))) {
        if ((SYS_CYCLE_LO - start_wait) > 500000000)  /* 5s timeout */
            break;
    }

    /* Load quake.bin from SD card via deferload */
    int rc = load_quake_bin_from_slot();
    if (rc < 0)
        while (1) {}  /* Halt on load failure */

    /* Memory data integrity tests (while terminal is still visible) */
    if (sdram_data_test() | psram_data_test()) {
        term_printf("HALTED - errors above\n");
        while (1) {}  /* Halt so errors stay visible */
    }
    /* Re-run SDRAM test under contention: video scanout does continuous
     * burst reads from SDRAM every scanline (~26us apart at 320x240@60Hz).
     * This stresses the SDRAM arbiter with concurrent CPU + scanout access.
     * Terminal output goes to BRAM (still readable after switching back). */
    SYS_DISPLAY_MODE = 1;  /* Start video scanout → SDRAM contention */
    {
        unsigned int t = SYS_CYCLE_LO;
        while ((SYS_CYCLE_LO - t) < 5000000) {}  /* 50ms settle */
    }
    term_printf("--- Under scanout contention ---\n");
    {
        int cont_errors = 0;
        for (int pass = 0; pass < 5; pass++)
            cont_errors += sdram_data_test();
        SYS_DISPLAY_MODE = 0;  /* Back to terminal to show results */
        if (cont_errors) {
            term_printf("HALTED - contention errors\n");
            while (1) {}
        }
    }

    /* Brief pause so results are readable */
    {
        unsigned int t = SYS_CYCLE_LO;
        while ((SYS_CYCLE_LO - t) < 200000000) {}  /* ~2s @ 100MHz */
    }

    /* Switch to framebuffer display */
    SYS_DISPLAY_MODE = 1;

    /* Copy from SDRAM to PSRAM */
    copy_to_psram();

    /* Clear BSS */
    clear_qbss();

    /* Final fence.i before jump */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Jump to Quake */
    switch_to_runtime_stack_and_call(quake_main, _runtime_stack_top);

    while (1) {}
    return 0;
}
