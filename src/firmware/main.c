/*
 * PocketQuake Bootloader
 * Runs from BRAM, initializes system, waits for data slot loading, then jumps to Quake
 * Copies quake.bin from SDRAM to PSRAM (CRAM0) for execution
 */

#include "terminal.h"
#include "dataslot.h"

#define BOOT_VERBOSE 1
#if BOOT_VERBOSE
#define BOOT_LOG(...) term_printf(__VA_ARGS__)
#else
#define BOOT_LOG(...) do {} while (0)
#endif

/* System registers */
#define SYS_STATUS      (*(volatile unsigned int *)0x40000000)
#define SYS_CYCLE_LO    (*(volatile unsigned int *)0x40000004)
#define SYS_CYCLE_HI    (*(volatile unsigned int *)0x40000008)

/* Load addresses */
#define QUAKE_BIN_ADDR  0x10200000  /* SDRAM LMA (bridge loads here, copied to PSRAM) */

/* External symbols from linker */
extern char _qbss_start[], _qbss_end[];
extern char _runtime_stack_top[];
extern char _quake_copy_src[];   /* Source address (SDRAM LMA) */
extern char _quake_copy_dst[];   /* Destination address (PSRAM VMA) */
extern char _quake_copy_size[];  /* Size of .text + .data to copy */
/* Quake entry point (in sys_pocket.c, linked in PSRAM) */
extern void quake_main(void);
extern void switch_to_runtime_stack_and_call(void (*entry)(void), void *stack_top);

/* Note: Trap handling moved to misaligned.c for misaligned access emulation */

/* Clear BSS section with progress reporting */
__attribute__((section(".text.boot")))
static void clear_qbss(void) {
    unsigned int *p = (unsigned int *)_qbss_start;
    unsigned int *end = (unsigned int *)_qbss_end;
    unsigned int *next_report = p + (64 * 1024 / 4);  /* Report every 64KB */
    int count = 0;

    BOOT_LOG("loop @%x\n", (unsigned int)p);
    while (p < end) {
        *p++ = 0;
        if (p >= next_report) {
            BOOT_LOG("@%x\n", (unsigned int)p);
            next_report += (64 * 1024 / 4);
            count++;
        }
    }
    BOOT_LOG("Done(%d)\n", count);
}

/* Copy Quake binary from SDRAM (LMA) to PSRAM (VMA) for execution */
__attribute__((section(".text.boot")))
static void copy_to_psram(void) {
    volatile unsigned int *src = (volatile unsigned int *)_quake_copy_src;
    volatile unsigned int *dst = (volatile unsigned int *)_quake_copy_dst;
    unsigned int words = (unsigned int)_quake_copy_size / 4;
    unsigned int i;

    BOOT_LOG("Copy SDRAM 0x%x -> PSRAM 0x%x (%d bytes)\n",
             (unsigned int)src, (unsigned int)dst, (unsigned int)_quake_copy_size);

    for (i = 0; i < words; i++)
        dst[i] = src[i];

    /* Fence: flush D-cache dirty lines to PSRAM, then invalidate I-cache
     * so instruction fetches see the freshly-copied code.
     * fence.i = 0x0000100f (raw encoding avoids needing zifencei in -march) */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    BOOT_LOG("Copy done, fence.i issued\n");
}

__attribute__((section(".text.boot")))
int main(void) {
    /* Initialize terminal early for debug output (safe: uses terminal BRAM) */
    term_init();
    BOOT_LOG("Boot @ 100MHz\n\n");
    BOOT_LOG("Waiting for dataslot_allcomplete (SYS_STATUS bit1)...\n");

    /* CRITICAL: Wait for APF dataslot loading BEFORE touching SDRAM */
    unsigned int last_report = SYS_CYCLE_LO;
    unsigned int start_wait = last_report;
    while (!(SYS_STATUS & (1 << 1))) {
        unsigned int now = SYS_CYCLE_LO;
        if ((now - last_report) > 6600000) {  /* ~0.1s at 66MHz */
            BOOT_LOG("SYS_STATUS=0x%x\n", SYS_STATUS);
            last_report = now;
        }
        if ((now - start_wait) > 240000000) { /* ~5s timeout */
            BOOT_LOG("Timeout waiting for dataslot; continuing anyway.\n");
            break;
        }
    }

    /* Keep boot checks lightweight to avoid triggering timing-sensitive failures. */
    BOOT_LOG("=== SDRAM SMOKE TEST ===\n");
    volatile unsigned int *test = (volatile unsigned int *)0x13000000;
    unsigned int rb;
    int pass_count = 0, fail_count = 0;

    BOOT_LOG("[Test 1: 32-bit W/R]\n");
    test[0] = 0xAABBCCDD;
    rb = test[0];
    BOOT_LOG("W:AABBCCDD R:%x %s\n", rb, rb == 0xAABBCCDD ? "OK" : "FAIL");
    if (rb == 0xAABBCCDD) pass_count++; else fail_count++;

    test[0] = 0x12345678;
    rb = test[0];
    BOOT_LOG("W:12345678 R:%x %s\n", rb, rb == 0x12345678 ? "OK" : "FAIL");
    if (rb == 0x12345678) pass_count++; else fail_count++;

    BOOT_LOG("Pass:%d Fail:%d\n", pass_count, fail_count);

    /* Show BSS region for debugging */
    BOOT_LOG("BSS: 0x%x - 0x%x\n", (unsigned int)_qbss_start, (unsigned int)_qbss_end);
    BOOT_LOG("BSS size: %d bytes\n", (int)(_qbss_end - _qbss_start));

    /* === DATASLOT READ DIAGNOSTIC (deferload) ===
     * Slot 0 (pak0.pak) has deferload:true — read on demand.
     * DMA to SDRAM, verify via uncacheable alias (0x50000000+). */
    {
        term_printf("\n=== DS READ TEST ===\n");

        /* Fill DMA buffer with sentinel pattern to detect dropped writes */
        volatile unsigned int *buf = (volatile unsigned int *)0x13F00000;
        for (int i = 0; i < 16; i++)
            buf[i] = 0xDEAD0000 | i;
        term_printf("Pre-fill: w0=%x w1=%x w2=%x w3=%x\n",
                     buf[0], buf[1], buf[2], buf[3]);

        int rc = dataslot_read(0, 0, (void *)0x13F00000, 64);
        volatile unsigned int *uc = (volatile unsigned int *)SDRAM_UNCACHED(0x13F00000);
        term_printf("S0/64B: rc=%d\n", rc);
        term_printf("  w0=%x w1=%x w2=%x w3=%x\n", uc[0], uc[1], uc[2], uc[3]);
        term_printf("  w4=%x w5=%x w6=%x w7=%x\n", uc[4], uc[5], uc[6], uc[7]);
        term_printf("  w8=%x w9=%x wA=%x wB=%x\n", uc[8], uc[9], uc[10], uc[11]);
        term_printf("  wC=%x wD=%x wE=%x wF=%x\n", uc[12], uc[13], uc[14], uc[15]);
        term_printf("  %s\n",
                     (rc == 0 && uc[0] == 0x4B434150) ? "PACK OK!" : "FAIL");

        term_printf("=== END DS TEST ===\n\n");
    }

    /* Copy Quake code+data from SDRAM to PSRAM */
    BOOT_LOG("\n=== COPY TO PSRAM ===\n");
    copy_to_psram();

    /* PAK read on demand from SD card via dataslot_read(). */
    BOOT_LOG("PAK: on-demand via deferload\n");

    /* Clear BSS section before running Quake */
    BOOT_LOG("\nClearing BSS 0x%x-0x%x...\n", (unsigned int)_qbss_start, (unsigned int)_qbss_end);

    /* Test first BSS write before full clear */
    volatile unsigned int *bss_test = (volatile unsigned int *)_qbss_start;
    BOOT_LOG("BSS test write @0x%x...\n", (unsigned int)bss_test);
    *bss_test = 0;
    BOOT_LOG("BSS test write OK\n");

    BOOT_LOG("Calling clear_qbss...\n");
    clear_qbss();
    BOOT_LOG("BSS cleared.\n");

    /* Jump to Quake! */
    BOOT_LOG("\nStarting Quake...\n");
    BOOT_LOG("quake_main @ 0x%x\n", (unsigned int)quake_main);
    BOOT_LOG("runtime stack top @ 0x%x\n", (unsigned int)_runtime_stack_top);

    BOOT_LOG("Jumping now...\n");
    switch_to_runtime_stack_and_call(quake_main, _runtime_stack_top);

    /* Test: if we get here, instruction fetch from PSRAM worked! */
    BOOT_LOG("SUCCESS: quake_main returned!\n");
    BOOT_LOG("PSRAM instruction fetch works!\n");
    while (1) {}

    return 0;
}
