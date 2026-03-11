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
extern char _quake_copy_size[];  /* Size of .text to copy to PSRAM */
extern char _quake_load_size[];  /* Total quake.bin image size (.text + .data) */
extern char _data_copy_src[];    /* .data LMA in SDRAM (within quake.bin) */
extern char _data_copy_dst[];    /* .data VMA in SDRAM */
extern char _data_copy_size[];   /* .data section size */
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

/* Copy Quake .text from SDRAM (LMA) to PSRAM (VMA) for execution */
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

/* Copy Quake .data from SDRAM LMA (within quake.bin) to SDRAM VMA.
 * .data lives in SDRAM so PSRAM stays read-only (no D-cache writebacks). */
__attribute__((section(".text.boot")))
static void copy_data_section(void) {
    unsigned int *src = (unsigned int *)(uint32_t)_data_copy_src;
    unsigned int *dst = (unsigned int *)(uint32_t)_data_copy_dst;
    unsigned int words = (unsigned int)_data_copy_size / 4;

    for (unsigned int i = 0; i < words; i++)
        dst[i] = src[i];
}

/* Load quake.bin from data slot into SDRAM LMA via deferload */
__attribute__((section(".text.boot")))
static int load_quake_bin_from_slot(void) {
    uint32_t total = (uint32_t)_quake_load_size;
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
 * PSRAM sync burst diagnostic — multi-pattern test with position histogram
 * and hardware WAIT debug register readout.
 *
 * Debug registers (from psram.sv):
 *   0x400000B0: [31] wait_seen, [15:0] burst_count
 *   0x400000B4: [15:0] wait_cycles (total WAIT HIGH during STATE_SYNC_DATA)
 *
 * Test region: 0x30100000 (1MB into PSRAM, well past quake.bin ~342KB)
 */
#define PSRAM_DBG0 (*(volatile unsigned int *)0x400000B0)
#define PSRAM_DBG1 (*(volatile unsigned int *)0x400000B4)
#define PSRAM_DBG2 (*(volatile unsigned int *)0x400000B8)

/* Pure burst-read diagnostic: no CPU writes to PSRAM.
 * Compares PSRAM data (burst-read via D-cache) against SDRAM reference.
 * copy_to_psram() must have already run: SDRAM 0x10200000 → PSRAM 0x30000000.
 * SDRAM reads go through uncached alias (0x50xx) to bypass D-cache.
 *
 * 1. Evict D-cache to force burst fills from PSRAM
 * 2. Read PSRAM (burst) and SDRAM (uncached) word-by-word, compare
 * 3. Print failing cache line indices + full dump of first failure
 */
__attribute__((section(".text.boot")))
static int psram_data_test(void) {
    /* Read from 64KB into quake.bin (past any headers, safely within data) */
    volatile unsigned int *psram = (volatile unsigned int *)0x30010000;
    volatile unsigned int *sdram = (volatile unsigned int *)0x50210000;  /* uncached SDRAM alias */
    const int words = 16384;  /* 64KB = 1024 cache lines */
    int pos_hist[16];
    int fail_lines[20];
    int fail_count = 0;
    int total_errors = 0;
    int first_fail_line = -1;
    int last_fail_line = -1;

    for (int i = 0; i < 16; i++) pos_hist[i] = 0;

    term_printf("=== PSRAM Burst Diag ===\n");

    /* Evict all PSRAM lines from D-cache.
     * Use 0x10180000 (not 0x10140000 which sdram_data_test cached).
     * Read 256KB (2x D-cache 128KB) to guarantee full eviction regardless
     * of prior cache state.  fence.i to also invalidate I-cache. */
    volatile unsigned int *evict = (volatile unsigned int *)0x10180000;
    unsigned int sink = 0;
    for (int i = 0; i < 65536; i++)   /* 256KB */
        sink += evict[i];
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */
    (void)sink;

    /* Read burst count BEFORE the test to compute delta */
    unsigned int bursts_before = PSRAM_DBG0 & 0xFFFF;

    /* Compare PSRAM (burst-read) vs SDRAM (uncached reference) */
    for (int i = 0; i < words; i++) {
        unsigned int got = psram[i];      /* D-cache miss → sync burst fill */
        unsigned int exp = sdram[i];      /* uncached SDRAM read → reference */
        if (got != exp) {
            int pos = i & 15;
            pos_hist[pos]++;
            total_errors++;
            int line = i >> 4;
            if (line != last_fail_line) {
                last_fail_line = line;
                if (first_fail_line < 0) first_fail_line = line;
                if (fail_count < 20)
                    fail_lines[fail_count] = line;
                fail_count++;
            }
        }
    }

    term_printf("Errors: %d in %d lines\n", total_errors, fail_count);

    /* Print first 20 failing cache line indices */
    if (fail_count > 0) {
        int show = fail_count < 20 ? fail_count : 20;
        term_printf("Fail lines:");
        for (int i = 0; i < show; i++)
            term_printf(" %d", fail_lines[i]);
        if (fail_count > 20) term_printf(" ...");
        term_printf("\n");
    }

    /* Dump all 16 words of the first failing cache line */
    if (first_fail_line >= 0) {
        int base = first_fail_line << 4;
        term_printf("Line %d dump (got/exp):\n", first_fail_line);
        for (int w = 0; w < 16; w += 2) {
            unsigned int g0 = psram[base + w];
            unsigned int e0 = sdram[base + w];
            unsigned int g1 = psram[base + w + 1];
            unsigned int e1 = sdram[base + w + 1];
            char m0 = (g0 != e0) ? '*' : ' ';
            char m1 = (g1 != e1) ? '*' : ' ';
            term_printf(" %c%08X/%08X %c%08X/%08X\n", m0, g0, e0, m1, g1, e1);
        }
    }

    /* Position histogram */
    if (total_errors > 0) {
        term_printf("Pos:");
        for (int p = 0; p < 16; p++) {
            if (pos_hist[p] > 0)
                term_printf(" w%d=%d", p, pos_hist[p]);
        }
        term_printf("\n");
    }

    /* Hardware debug: burst count delta shows actual PSRAM bursts during test */
    unsigned int dbg0 = PSRAM_DBG0;
    unsigned int dbg1 = PSRAM_DBG1;
    unsigned int dbg2 = PSRAM_DBG2;
    unsigned int bursts_during = (dbg0 & 0xFFFF) - bursts_before;
    term_printf("Bursts=%d errs=%d stale=%d\n",
        bursts_during, total_errors, dbg2 & 0xFFFF);

    if (total_errors)
        term_printf("TOTAL: %d errors\n", total_errors);
    else
        term_printf("ALL PASS\n");

    return total_errors;
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

    /* SDRAM data integrity test (uses 0x10140000, doesn't touch quake.bin) */
    if (sdram_data_test()) {
        term_printf("HALTED - SDRAM errors\n");
        while (1) {}
    }

    /* Copy quake.bin from SDRAM to PSRAM (async writes via D-cache writeback) */
    copy_to_psram();

    /* PSRAM burst-read diagnostic: compare PSRAM data (burst reads via D-cache)
     * against SDRAM reference (uncached reads). Pure reads — no CPU writes to PSRAM.
     * Must run AFTER copy_to_psram so PSRAM has valid data to verify. */
    if (psram_data_test()) {
        term_printf("HALTED - PSRAM errors\n");
        while (1) {}
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

    /* Copy .data from quake.bin LMA to SDRAM VMA */
    copy_data_section();

    /* Clear BSS (starts after .data in SDRAM) */
    clear_qbss();

    /* Final fence.i before jump */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Jump to Quake */
    switch_to_runtime_stack_and_call(quake_main, _runtime_stack_top);

    while (1) {}
    return 0;
}
