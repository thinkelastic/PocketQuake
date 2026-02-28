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
#define QUAKE_SLOT_ID   1           /* data.json slot id for quake.bin */

/* External symbols from linker */
extern char _qbss_start[], _qbss_end[];
extern char _runtime_stack_top[];
extern char _quake_copy_src[];   /* Source address (SDRAM LMA) */
extern char _quake_copy_dst[];   /* Destination address (PSRAM VMA) */
extern char _quake_copy_size[];  /* Size of .text + .data to copy */
/* Quake entry point (in sys_pocket.c, linked in PSRAM) */
extern void quake_main(void);
extern void switch_to_runtime_stack_and_call(void (*entry)(void), void *stack_top);
extern volatile unsigned int pq_dbg_stage;
extern volatile unsigned int pq_dbg_info;

/* Note: Trap handling moved to misaligned.c for misaligned access emulation */

/* Read 32-bit value from potentially misaligned SDRAM address using only
 * word-aligned accesses.  Uncached SDRAM may not support byte/half reads,
 * and the misaligned-trap handler uses byte reads that can hang on the
 * uncached alias. With RVC enabled, quake_main can be 2-byte aligned. */
__attribute__((section(".text.boot")))
static unsigned int sdram_read32_unaligned(unsigned int addr) {
    unsigned int aligned = addr & ~3u;
    unsigned int shift   = (addr & 3u) * 8;
    volatile unsigned int *p = (volatile unsigned int *)aligned;
    if (shift == 0) return p[0];
    return (p[0] >> shift) | (p[1] << (32 - shift));
}

/* CRC32 (bitwise, no table — small code for BRAM) */
__attribute__((section(".text.boot")))
static unsigned int crc32(const volatile unsigned char *data, unsigned int len) {
    unsigned int crc = 0xFFFFFFFF;
    for (unsigned int i = 0; i < len; i++) {
        crc ^= data[i];
        for (int bit = 0; bit < 8; bit++)
            crc = (crc >> 1) ^ (0xEDB88320 & -(crc & 1));
    }
    return ~crc;
}

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
    /* Read from uncached SDRAM alias so bridge-loaded bytes cannot be
     * shadowed by stale D-cache lines across warm boots. */
    volatile unsigned int *src =
        (volatile unsigned int *)SDRAM_UNCACHED((uint32_t)_quake_copy_src);
    volatile unsigned int *dst = (volatile unsigned int *)_quake_copy_dst;
    unsigned int words = (unsigned int)_quake_copy_size / 4;
    unsigned int i;

    BOOT_LOG("Copy SDRAM 0x%x (UC 0x%x) -> PSRAM 0x%x (%d bytes)\n",
             (unsigned int)_quake_copy_src, (unsigned int)src,
             (unsigned int)dst, (unsigned int)_quake_copy_size);

    for (i = 0; i < words; i++)
        dst[i] = src[i];

    /* Fence: flush D-cache dirty lines to PSRAM, then invalidate I-cache
     * so instruction fetches see the freshly-copied code.
     * fence.i = 0x0000100f (raw encoding avoids needing zifencei in -march) */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    BOOT_LOG("Copy done, fence.i issued\n");
}

/* Reload quake.bin directly from data slot 1 into SDRAM LMA.
 * This avoids relying solely on APF preload timing and gives deterministic
 * chunked completion at boot before the PSRAM copy. */
__attribute__((section(".text.boot")))
static int load_quake_bin_from_slot(void) {
    uint32_t total = (uint32_t)_quake_copy_size;
    uint32_t base = (uint32_t)_quake_copy_src;
    uint32_t done = 0;

    BOOT_LOG("Reload slot %d -> SDRAM 0x%x (%u bytes)\n",
             QUAKE_SLOT_ID, base, total);

    while (done < total) {
        uint32_t chunk = total - done;
        if (chunk > DMA_CHUNK_SIZE)
            chunk = DMA_CHUNK_SIZE;

        int rc = dataslot_read(QUAKE_SLOT_ID, done, (void *)(base + done), chunk);
        if (rc < 0) {
            BOOT_LOG("quake.bin read failed off=0x%x len=0x%x rc=%d\n", done, chunk, rc);
            return rc;
        }

        done += chunk;
    }

    /* Read head words via uncached alias to confirm fresh SDRAM content. */
    {
        volatile unsigned int *uc = (volatile unsigned int *)SDRAM_UNCACHED(base);
        BOOT_LOG("quake.bin head UC: %08x %08x %08x %08x\n",
                 uc[0], uc[1], uc[2], uc[3]);
    }

    return 0;
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

    unsigned int sdram_crc = 0;

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

    /* === QUAKE.BIN SDRAM VERIFICATION (BRIDGE PRELOAD) === */
    {
        unsigned int qm_offset = (unsigned int)quake_main - (unsigned int)_quake_copy_dst;
        volatile unsigned int *qb_uc =
            (volatile unsigned int *)SDRAM_UNCACHED((uint32_t)_quake_copy_src);
        /* Use word-aligned helper — quake_main may be 2-byte aligned with RVC */
        unsigned int qm_sdram_addr =
            (unsigned int)SDRAM_UNCACHED((uint32_t)_quake_copy_src + qm_offset);
        unsigned int qm_val = sdram_read32_unaligned(qm_sdram_addr);
        BOOT_LOG("\n=== SDRAM quake.bin (bridge preload) ===\n");
        BOOT_LOG("  head: %08x %08x %08x %08x\n",
                 qb_uc[0], qb_uc[1], qb_uc[2], qb_uc[3]);
        BOOT_LOG("  @qm+%x: %08x\n", qm_offset, qm_val);

        /* Targeted dataslot_read at quake_main offset to verify SD card data */
        int rc = dataslot_read(QUAKE_SLOT_ID, qm_offset, (void *)DMA_BUFFER, 64);
        volatile unsigned int *ds_uc =
            (volatile unsigned int *)SDRAM_UNCACHED(DMA_BUFFER);
        BOOT_LOG("  DS slot1 @%x: rc=%d val=%08x\n",
                 qm_offset, rc, ds_uc[0]);
        BOOT_LOG("  bridge=%08x slot=%08x %s\n",
                 qm_val, ds_uc[0],
                 qm_val == ds_uc[0] ? "MATCH" : "DIFFER");
    }

    /* Reload quake.bin from data slot (bypass broken bridge preload) */
    BOOT_LOG("\n=== RELOAD quake.bin from slot ===\n");
    {
        int rc = load_quake_bin_from_slot();
        if (rc < 0) {
            BOOT_LOG("HALT: reload failed rc=%d\n", rc);
            while (1) {}
        }
        unsigned int qm_offset = (unsigned int)quake_main - (unsigned int)_quake_copy_dst;
        unsigned int qm_addr =
            (unsigned int)SDRAM_UNCACHED((uint32_t)_quake_copy_src + qm_offset);
        unsigned int qm_val = sdram_read32_unaligned(qm_addr);
        BOOT_LOG("  After reload @qm: %08x\n", qm_val);

        /* CRC32 of SDRAM after reload (uncached read = true SDRAM content) */
        sdram_crc = crc32(
            (const volatile unsigned char *)SDRAM_UNCACHED((uint32_t)_quake_copy_src),
            (unsigned int)_quake_copy_size);
        BOOT_LOG("  SDRAM CRC32: %08x (%u bytes)\n",
                 sdram_crc, (unsigned int)_quake_copy_size);
    }

    /* === PSRAM QUICK TEST === */
    {
        volatile unsigned int *psram = (volatile unsigned int *)0x30000000;
        BOOT_LOG("\n=== PSRAM TEST ===\n");
        psram[0] = 0xCAFEBABE;
        psram[1] = 0x12345678;
        __asm__ volatile("fence");
        BOOT_LOG("  W/R: %08x %08x %s\n", psram[0], psram[1],
                 (psram[0] == 0xCAFEBABE && psram[1] == 0x12345678) ? "OK" : "FAIL");
    }

    /* === DATASLOT READ DIAGNOSTIC (deferload) ===
     * Slot 0 (pak0.pak) has deferload:true — read on demand.
     * DMA to SDRAM, verify via uncacheable alias (0x50000000+). */
#define DS_READ_TEST_ENABLE 1
#if DS_READ_TEST_ENABLE
    {
        term_printf("\n=== DS READ TEST ===\n");

        /* Fill DMA buffer with sentinel pattern via UNCACHED alias to avoid
         * creating dirty D-cache lines that could be evicted later and
         * overwrite DMA'd data in SDRAM. */
        volatile unsigned int *buf = (volatile unsigned int *)SDRAM_UNCACHED(0x13F00000);
        for (int i = 0; i < 16; i++)
            buf[i] = 0xDEAD0000 | i;
        term_printf("Pre-fill: w0=%x w1=%x w2=%x w3=%x\n",
                     buf[0], buf[1], buf[2], buf[3]);

        int rc = dataslot_read(0, 0, (void *)0x13F00000, 64);
        volatile unsigned int *uc = (volatile unsigned int *)SDRAM_UNCACHED(0x13F00000);
        term_printf("S0/64B: rc=%d\n", rc);
        term_printf("  w0=%x w1=%x w2=%x w3=%x\n", uc[0], uc[1], uc[2], uc[3]);
        term_printf("  %s\n",
                     (rc == 0 && uc[0] == 0x4B434150) ? "PACK OK!" : "FAIL");

        term_printf("=== END DS TEST ===\n\n");
    }
#endif

    /* Post-DS: quick sanity check that reload data survived DS test */
    {
        unsigned int qm_offset = (unsigned int)quake_main - (unsigned int)_quake_copy_dst;
        unsigned int qm_addr =
            (unsigned int)SDRAM_UNCACHED((uint32_t)_quake_copy_src + qm_offset);
        unsigned int qm_val = sdram_read32_unaligned(qm_addr);
        BOOT_LOG("Post-DS @qm: %08x (sdram_crc=%08x)\n", qm_val, sdram_crc);
    }

    /* Copy Quake code+data from SDRAM to PSRAM */
    BOOT_LOG("\n=== COPY TO PSRAM ===\n");
    copy_to_psram();

    /* === PSRAM VERIFICATION (AFTER COPY) === */
    {
        volatile unsigned int *psram = (volatile unsigned int *)0x30000000;
        volatile unsigned int *qb_uc =
            (volatile unsigned int *)SDRAM_UNCACHED((uint32_t)_quake_copy_src);
        unsigned int total_words = (unsigned int)_quake_copy_size / 4;

        /* Full scan: compare every PSRAM word against SDRAM uncached source */
        BOOT_LOG("=== VERIFY COPY (%u words) ===\n", total_words);
        unsigned int first_bad = 0xFFFFFFFF;
        unsigned int bad_count = 0;
        unsigned int i;
        for (i = 0; i < total_words; i++) {
            unsigned int p = psram[i];
            unsigned int s = qb_uc[i];
            if (p != s) {
                if (bad_count < 4) {
                    BOOT_LOG("  MISMATCH @%05x: P=%08x S=%08x\n",
                             i * 4, p, s);
                }
                if (first_bad == 0xFFFFFFFF) first_bad = i;
                bad_count++;
            }
        }
        if (bad_count == 0) {
            BOOT_LOG("  ALL %u words OK\n", total_words);
        } else {
            BOOT_LOG("  %u mismatches, first @%05x\n",
                     bad_count, first_bad * 4);
            BOOT_LOG("HALT: copy verification failed!\n");
            while (1) {}
        }
    }

    /* === PSRAM SOAK TEST ===
     * Evict D-cache by reading 160KB of SDRAM (fills 128KB D-cache),
     * then re-read PSRAM (forced cache miss = actual PSRAM read).
     * This tests true PSRAM data integrity, not D-cache. */
    {
        volatile unsigned int *psram = (volatile unsigned int *)0x30000000;
        volatile unsigned int *qb_uc =
            (volatile unsigned int *)SDRAM_UNCACHED((uint32_t)_quake_copy_src);
        unsigned int total_words = (unsigned int)_quake_copy_size / 4;
        volatile unsigned int sink = 0;

        BOOT_LOG("=== PSRAM SOAK (evict D$) ===\n");

        /* Read 160KB of SDRAM to thrash D-cache, evicting PSRAM lines */
        volatile unsigned int *sdram_thrash = (volatile unsigned int *)0x13000000;
        for (unsigned int i = 0; i < 40960; i++)
            sink += sdram_thrash[i];
        (void)sink;

        /* Now PSRAM reads will be cache misses = real PSRAM reads */
        unsigned int soak_bad = 0;
        unsigned int i;
        for (i = 0; i < total_words; i++) {
            unsigned int p = psram[i];
            unsigned int s = qb_uc[i];
            if (p != s) {
                if (soak_bad < 8)
                    BOOT_LOG("  @%05x: P=%08x S=%08x XOR=%08x\n",
                             i * 4, p, s, p ^ s);
                soak_bad++;
            }
        }
        if (soak_bad == 0) {
            BOOT_LOG("  %u words verified from PSRAM (D$ evicted) OK\n", total_words);
        } else {
            BOOT_LOG("  %u/%u words CORRUPT in PSRAM!\n", soak_bad, total_words);
            BOOT_LOG("HALT: PSRAM data integrity failure!\n");
            while (1) {}
        }

        /* CRC32 of PSRAM after copy + D-cache eviction (true PSRAM content) */
        unsigned int psram_crc = crc32(
            (const volatile unsigned char *)0x30000000,
            (unsigned int)_quake_copy_size);
        BOOT_LOG("  PSRAM CRC32: %08x\n", psram_crc);

        if (psram_crc != sdram_crc) {
            BOOT_LOG("HALT: CRC MISMATCH! SDRAM=%08x PSRAM=%08x\n",
                     sdram_crc, psram_crc);
            while (1) {}
        }
        BOOT_LOG("  CRC MATCH: SDRAM==PSRAM OK\n");
    }

    /* === PSRAM INSTRUCTION EXECUTION TEST ===
     * Write a test function to end of PSRAM that uses the stack,
     * then call it with both BRAM stack and SDRAM runtime stack. */
    {
        volatile unsigned int *test_fn = (volatile unsigned int *)0x30FFF000;
        /* Function that saves ra to stack, loads 0x42, restores ra, returns */
        test_fn[0] = 0xFF010113;  /* addi sp, sp, -16  */
        test_fn[1] = 0x00112623;  /* sw   ra, 12(sp)   */
        test_fn[2] = 0x04200513;  /* li   a0, 0x42     */
        test_fn[3] = 0x00C12083;  /* lw   ra, 12(sp)   */
        test_fn[4] = 0x01010113;  /* addi sp, sp, 16   */
        test_fn[5] = 0x00008067;  /* ret               */
        __asm__ volatile("fence");
        __asm__ volatile(".word 0x0000100f");  /* fence.i */
        typedef int (*test_func_t)(void);

        /* Test 1: PSRAM exec with BRAM stack (current stack) */
        int result1 = ((test_func_t)0x30FFF000)();
        BOOT_LOG("\n=== PSRAM EXEC TEST ===\n");
        BOOT_LOG("  BRAM stack: got 0x%x %s\n", result1,
                 result1 == 0x42 ? "OK" : "FAIL");

        /* Test 2: PSRAM exec with SDRAM runtime stack */
        BOOT_LOG("  Switching to SDRAM stack @0x%x...\n",
                 (unsigned int)_runtime_stack_top);
        unsigned int saved_sp;
        int result2;
        __asm__ volatile(
            "mv %[save], sp\n"
            "mv sp, %[newsp]\n"
            "jalr ra, %[func]\n"
            "mv %[ret], a0\n"
            "mv sp, %[save]\n"
            : [save] "+r"(saved_sp), [ret] "=r"(result2)
            : [newsp] "r"(_runtime_stack_top), [func] "r"(0x30FFF000)
            : "ra", "a0", "memory"
        );
        BOOT_LOG("  SDRAM stack: got 0x%x %s\n", result2,
                 result2 == 0x42 ? "OK" : "FAIL");
        if (result1 != 0x42 || result2 != 0x42) {
            BOOT_LOG("HALT: PSRAM exec test failed!\n");
            while (1) {}
        }
    }

    /* PAK read on demand from SD card via dataslot_read(). */
    BOOT_LOG("PAK: on-demand via deferload\n");

    /* Clear BSS section before running Quake */
    clear_qbss();
    BOOT_LOG("BSS cleared.\n");

    /* Jump to Quake! */
    BOOT_LOG("\nStarting Quake...\n");
    BOOT_LOG("quake_main @ 0x%x\n", (unsigned int)quake_main);
    BOOT_LOG("runtime stack top @ 0x%x\n", (unsigned int)_runtime_stack_top);

    /* Write sentinel before jump; quake_main overwrites with 0xAA55AA55 */
    *(volatile unsigned int *)0x13E00000 = 0xDEADDEAD;
    __asm__ volatile("fence");

    /* Verify first PSRAM instruction matches SDRAM source.
     * With RVC, quake_main may be 2-byte aligned — use word-aligned reads. */
    {
        unsigned int qm_offset = (unsigned int)quake_main - (unsigned int)_quake_copy_dst;
        unsigned int psram_val = sdram_read32_unaligned((unsigned int)quake_main);
        unsigned int sdram_val = sdram_read32_unaligned(
            (unsigned int)SDRAM_UNCACHED((uint32_t)_quake_copy_src + qm_offset));
        BOOT_LOG("Entry insn PSRAM:%08x SDRAM:%08x %s\n",
                 psram_val, sdram_val,
                 psram_val == sdram_val ? "OK" : "MISMATCH");
        if (psram_val == 0 || psram_val != sdram_val) {
            BOOT_LOG("HALT: quake_main code mismatch!\n");
            while (1) {}
        }
    }

    /* === STACK STORE TEST ===
     * The quake_main prologue stores 8 callee-saves to the runtime stack.
     * Test that sw to the exact stack region works. */
    {
        volatile unsigned int *stk = (volatile unsigned int *)
            ((unsigned int)_runtime_stack_top - 256);
        stk[0] = 0xCAFE0001;
        stk[62] = 0xCAFE0002;  /* offset 248 = s0 save location */
        __asm__ volatile("fence");
        volatile unsigned int *stk_uc = (volatile unsigned int *)
            SDRAM_UNCACHED((unsigned int)stk);
        BOOT_LOG("Stack region @%08x: [0]=%08x [62]=%08x %s\n",
                 (unsigned int)stk, stk_uc[0], stk_uc[62],
                 (stk_uc[0] == 0xCAFE0001 && stk_uc[62] == 0xCAFE0002)
                 ? "OK" : "FAIL");
    }

    BOOT_LOG("Jumping now...\n");

    /* Defensive fence.i: invalidate I-cache completely */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* I-bus re-test at 0x30FFF000 */
    {
        typedef int (*testfn)(void);
        int r = ((testfn)0x30FFF000)();
        ((volatile char *)0x20000000)[29 * 40 + 2] = (r == 0x42) ? 'I' : 'X';
    }

    /* Final fence.i right before the jump */
    __asm__ volatile("fence");
    __asm__ volatile(".word 0x0000100f");  /* fence.i */

    /* Debug markers: row 29
     * After jump, switch_to_runtime_stack_and_call writes 'S' at col 3
     * and hex-dumps a0 (target addr) at cols 5-12, target insn at cols 14-21 */
    ((volatile char *)0x20000000)[29 * 40 + 0] = 'J';
    ((volatile char *)0x20000000)[29 * 40 + 1] = '>';

    switch_to_runtime_stack_and_call(quake_main, _runtime_stack_top);

    /* Test: if we get here, instruction fetch from PSRAM worked! */
    BOOT_LOG("SUCCESS: quake_main returned!\n");
    BOOT_LOG("pq_dbg_stage=0x%x pq_dbg_info=0x%x\n", pq_dbg_stage, pq_dbg_info);
    BOOT_LOG("PSRAM instruction fetch works!\n");
    while (1) {}

    return 0;
}
