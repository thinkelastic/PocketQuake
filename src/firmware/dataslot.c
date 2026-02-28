/*
 * Data Slot interface for Analogue Pocket
 *
 * Implements CPU-controlled data slot operations using APF target commands.
 */

#include "dataslot.h"
#include "libc/libc.h"
#include "terminal.h"

/* Set to 1 for verbose dataslot debug output (slow — prints on every read) */
#define DS_DEBUG 0
#if DS_DEBUG
#define DS_LOG(...) term_printf(__VA_ARGS__)
#else
#define DS_LOG(...) do {} while(0)
#endif

/* Parameter buffer in SDRAM (placed at a known location) */
/* We use the end of SDRAM test region to avoid conflicts */
#define PARAM_BUFFER_ADDR   0x10F00000  /* CPU address for param struct */
#define RESP_BUFFER_ADDR    0x10F01000  /* CPU address for response struct */

/* Timeout in CPU cycles (~15 seconds at 100 MHz).
 * Uses hardware cycle counter (sysreg, not SDRAM) so the timeout works even
 * when bridge_dma_active blocks all SDRAM access. */
#define TIMEOUT_CYCLES      1500000000u

/* Wait for the current (already-issued) command to complete.
 *
 * Protocol: after DS_COMMAND is written, wait for ACK then DONE.
 *
 * Stale DONE from a previous command is harmless because:
 *   - The hardware guard does NOT check DONE, so the command is accepted.
 *   - Writing DS_COMMAND triggers cpu_ds_start in core_top, which resets
 *     ds_done_ram_sync → target_dataslot_done_safe goes low in ~3 clk cycles.
 *   - Bridge ACK takes ~11+ cycles (CDC + bridge latency + CDC back).
 *   - By the time we observe ACK, stale DONE is guaranteed to be 0 already.
 *   - Then we wait for the NEW DONE from this command's DMA completion.
 *
 * The old code tried to explicitly clear stale DONE/ACK, but this created
 * a race window where the new command's ACK could arrive during the
 * stale-clear phase, be mistaken for "stale", and be missed entirely. */
/* Read the hardware cycle counter (sysreg at 0x40000004).
 * This is NOT in SDRAM, so it works even when bridge_dma_active blocks SDRAM. */
static inline uint32_t read_cycles(void) {
    return *(volatile uint32_t *)(0x40000004);
}

__attribute__((section(".text.boot")))
int dataslot_wait_complete(void) {
    uint32_t start;

    DS_LOG("wait: status=%x\n", DS_STATUS);

    /* Wait for this command's ACK.
     * Any stale DONE from the previous command clears within ~3 CPU
     * cycles (ds_done_ram_sync reset by cpu_ds_start), well before
     * ACK arrives at ~11+ cycles. */
    start = read_cycles();
    while (!(DS_STATUS & DS_STATUS_ACK)) {
        if (read_cycles() - start > TIMEOUT_CYCLES) {
            DS_LOG("wait: timeout at ack, s=%x\n", DS_STATUS);
            return -1;
        }
    }
    DS_LOG("wait: got ACK\n");

    /* Wait for DONE (from the current command — stale DONE is gone). */
    start = read_cycles();
    while (!(DS_STATUS & DS_STATUS_DONE)) {
        if (read_cycles() - start > TIMEOUT_CYCLES) {
            DS_LOG("wait: timeout at done, s=%x\n", DS_STATUS);
            return -2;
        }
    }
    DS_LOG("wait: got DONE\n");

    /* Check error code */
    uint32_t final_status = DS_STATUS;
    int err = (final_status & DS_STATUS_ERR_MASK) >> DS_STATUS_ERR_SHIFT;
    DS_LOG("wait: final status=%x err=%d\n", final_status, err);
    return err ? -err : 0;
}

__attribute__((section(".text.boot")))
int dataslot_open_file(const char *filename, uint32_t flags, uint32_t size) {
    /* Build parameter struct in SDRAM */
    dataslot_open_param_t *param = (dataslot_open_param_t *)PARAM_BUFFER_ADDR;

    /* Clear and fill the struct */
    memset(param, 0, sizeof(*param));
    strncpy(param->filename, filename, 255);
    param->filename[255] = '\0';
    param->flags = flags;
    param->size = size;

    /* Set up registers */
    DS_SLOT_ID = 0;  /* Slot 0 for opened files */
    DS_PARAM_ADDR = CPU_TO_BRIDGE_ADDR(PARAM_BUFFER_ADDR);
    DS_RESP_ADDR = CPU_TO_BRIDGE_ADDR(RESP_BUFFER_ADDR);

    /* Trigger openfile command */
    DS_COMMAND = DS_CMD_OPENFILE;

    /* Wait for completion */
    return dataslot_wait_complete();
}

__attribute__((section(".text.boot")))
int dataslot_read(uint32_t slot_id, uint32_t offset, void *dest, uint32_t length) {
    /* Validate destination is in SDRAM */
    uint32_t dest_addr = (uint32_t)dest;
    if (dest_addr < 0x10000000 || dest_addr >= 0x14000000) {
        return -10;  /* Invalid destination address */
    }

    uint32_t bridge_addr = CPU_TO_BRIDGE_ADDR(dest_addr);

    /* Debug: print parameters */
    DS_LOG("DS: slot=%d off=%x br=%x len=%x\n",
                slot_id, offset, bridge_addr, length);

    /* Write back dirty D-cache lines before DMA so the bridge doesn't
     * read stale data if it ever needs to, and so dirty lines at the
     * dest address become clean (preventing later eviction writeback
     * from overwriting DMA'd data). */
    __asm__ volatile("fence");

    /* Set up registers */
    DS_SLOT_ID = slot_id;
    DS_SLOT_OFFSET = offset;
    DS_BRIDGE_ADDR = bridge_addr;
    DS_LENGTH = length;

    /* Trigger read command */
    DS_COMMAND = DS_CMD_READ;

    /* Wait for completion */
    int result = dataslot_wait_complete();

    /* DS_STATUS DONE is gated by bridge_wr_fifo_empty in hardware,
     * so when dataslot_wait_complete() returns, all writes have
     * landed in SDRAM. No spin-wait needed. */

    /* NOTE: After DMA, the D-cache may still hold stale data for dest.
     * Callers MUST read DMA'd data through the uncacheable SDRAM alias:
     *   SDRAM_UNCACHED(dest)  (0x50000000 + offset, same physical SDRAM)
     * This bypasses the D-cache entirely, reading fresh data from SDRAM. */

    return result;
}

__attribute__((section(".text.boot")))
int dataslot_write(uint16_t slot_id, uint32_t offset, const void *src, uint32_t length) {
    /* Validate source is in SDRAM */
    uint32_t src_addr = (uint32_t)src;
    if (src_addr < 0x10000000 || src_addr >= 0x14000000) {
        return -10;  /* Invalid source address */
    }

    /* Set up registers */
    DS_SLOT_ID = slot_id;
    DS_SLOT_OFFSET = offset;
    DS_BRIDGE_ADDR = CPU_TO_BRIDGE_ADDR(src_addr);
    DS_LENGTH = length;

    /* Trigger write command */
    DS_COMMAND = DS_CMD_WRITE;

    /* Wait for completion */
    return dataslot_wait_complete();
}

__attribute__((section(".text.boot")))
int32_t dataslot_load(uint16_t slot_id, void *dest, uint32_t max_length) {
    if (dest == NULL) {
        return -1;
    }

    /* Cache-safe slot load:
     * DMA into shared SDRAM bounce buffer, then copy from uncached alias. */
    uint8_t *dst = (uint8_t *)dest;
    uint32_t done = 0;
    while (done < max_length) {
        uint32_t chunk = max_length - done;
        if (chunk > DMA_CHUNK_SIZE) {
            chunk = DMA_CHUNK_SIZE;
        }

        int result = dataslot_read(slot_id, done, (void *)DMA_BUFFER, chunk);
        if (result < 0) {
            return result;
        }

        memcpy(dst + done, SDRAM_UNCACHED(DMA_BUFFER), chunk);
        done += chunk;
    }

    return (int32_t)done;
}

__attribute__((section(".text.boot")))
int dataslot_get_size(uint16_t slot_id, uint32_t *size_out) {
    /* TODO: Implement proper slot size query via APF protocol */
    /* For now, return a fixed size based on data.json slot IDs:
     *   slot 0 = pak0.pak (deferload)
     *   slot 1 = quake.bin */
    if (size_out == NULL) return -1;

    switch (slot_id) {
        case 0:  /* PAK data (deferload) */
            *size_out = 20 * 1024 * 1024;  /* 20 MB */
            break;
        case 1:  /* Quake binary */
            *size_out = 4 * 1024 * 1024;   /* 4 MB */
            break;
        default:
            *size_out = 1 * 1024 * 1024;   /* 1 MB default */
            break;
    }
    return 0;
}
