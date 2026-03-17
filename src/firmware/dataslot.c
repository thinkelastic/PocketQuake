/*
 * Data Slot interface for Analogue Pocket
 *
 * Implements CPU-controlled data slot operations using APF target commands.
 */

#include "dataslot.h"
#include "libc/libc.h"
#include "terminal.h"

/* CD audio yield hook — NULL until cd_pocket.c sets it.
 * Must be in BRAM (.boot_data) so it's zero at power-on.
 * SDRAM BSS contains garbage during early boot when dataslot_read
 * is called to load quake.bin — a garbage pointer here = crash. */
__attribute__((section(".boot_data")))
void (*dataslot_yield_hook)(void) = (void *)0;

/* Set to 1 for verbose dataslot debug output (slow — prints on every read) */
#define DS_DEBUG 0
#if DS_DEBUG
#define DS_LOG(...) term_printf(__VA_ARGS__)
#else
#define DS_LOG(...) do {} while(0)
#endif

/* Parameter buffer in SDRAM (placed at a known location).
 * Must be OUTSIDE the heap (0x10738xxx–0x12F80000) so dataslot_open_file
 * can be called during gameplay without corrupting heap allocations.
 * Using the gap between runtime stack top (0x13000000) and DMA_BUFFER. */
#define PARAM_BUFFER_ADDR   0x13E00000  /* CPU address for param struct */
#define RESP_BUFFER_ADDR    0x13E01000  /* CPU address for response struct */

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
int dataslot_open_file(uint16_t slot_id, const char *filename, uint32_t flags, uint32_t size) {
    /* Build parameter struct through the uncached SDRAM alias so the bridge
     * reads correct data from physical SDRAM.  VexiiRiscv's fence instruction
     * only drains the store buffer — it does NOT writeback dirty D-cache lines.
     * During boot the D-cache is cold (fence.i flushed it), so cached writes
     * happen to work.  During gameplay the D-cache is warm and dirty lines for
     * the param buffer persist indefinitely, making the bridge see stale data
     * (wrong filename → open fails silently). */
    dataslot_open_param_t *param = (dataslot_open_param_t *)SDRAM_UNCACHED(PARAM_BUFFER_ADDR);

    /* Clear and fill the struct — each byte goes directly to physical SDRAM */
    memset(param, 0, sizeof(*param));
    strncpy(param->filename, filename, 255);
    param->filename[255] = '\0';
    param->flags = flags;
    param->size = size;

    /* Set up registers */
    DS_SLOT_ID = slot_id;
    DS_PARAM_ADDR = CPU_TO_BRIDGE_ADDR(PARAM_BUFFER_ADDR);
    DS_RESP_ADDR = CPU_TO_BRIDGE_ADDR(RESP_BUFFER_ADDR);

    /* Trigger openfile command */
    DS_COMMAND = DS_CMD_OPENFILE;

    /* Wait for completion */
    return dataslot_wait_complete();
}

/* After firing DS_COMMAND, we must wait for the bridge to clear stale DONE
 * from any previous command (~15 CPU cycles for CDC round-trip).
 * We record the start cycle and reject polls until enough time has passed. */
static uint32_t ds_async_start_cycle;

static inline uint32_t ds_read_cycles(void) {
    return *(volatile uint32_t *)(0x40000004);
}

void dataslot_read_start(uint32_t slot_id, uint32_t offset, void *dest, uint32_t length) {
    uint32_t dest_addr = (uint32_t)dest;
    /* CRAM1 (0x30xxxxxx) passes through directly; SDRAM subtracts base */
    uint32_t bridge_addr = (dest_addr >= 0x30000000 && dest_addr < 0x31000000)
                         ? dest_addr : CPU_TO_BRIDGE_ADDR(dest_addr);

    __asm__ volatile("fence");

    DS_SLOT_ID = slot_id;
    DS_SLOT_OFFSET = offset;
    DS_BRIDGE_ADDR = bridge_addr;
    DS_LENGTH = length;

    DS_COMMAND = DS_CMD_READ;

    ds_async_start_cycle = ds_read_cycles();
}

int dataslot_read_poll(void) {
    /* Don't check DONE until stale value has cleared.
     * Bridge clears DONE in ~15 CPU cycles after DS_COMMAND.
     * Use 200 cycles (~2us) for generous margin. */
    if (ds_read_cycles() - ds_async_start_cycle < 200)
        return 0;

    uint32_t status = DS_STATUS;

    if (status & DS_STATUS_DONE) {
        int err = (status & DS_STATUS_ERR_MASK) >> DS_STATUS_ERR_SHIFT;
        return err ? -err : 1;
    }

    return 0;  /* Still in flight */
}

__attribute__((section(".text.boot")))
int dataslot_read(uint32_t slot_id, uint32_t offset, void *dest, uint32_t length) {
    /* Validate destination is in SDRAM or CRAM1 (bridge DMA target).
     * SDRAM: 0x10000000-0x13FFFFFF (64MB)
     * CRAM1: 0x30000000-0x30FFFFFF (16MB, CD audio ring buffer) */
    uint32_t dest_addr = (uint32_t)dest;
    int dest_sdram = (dest_addr >= 0x10000000 && dest_addr < 0x14000000);
    int dest_cram1 = (dest_addr >= 0x30000000 && dest_addr < 0x31000000);
    if (!dest_sdram && !dest_cram1) {
        return -10;  /* Invalid destination address */
    }

    /* Yield async CD DMA if in flight — we're about to use the shared dataslot */
    if (dataslot_yield_hook)
        dataslot_yield_hook();

    /* CRAM1 addresses pass through directly to the bridge (no SDRAM offset).
     * SDRAM addresses subtract 0x10000000 to get the bridge-relative address. */
    uint32_t bridge_addr = dest_cram1 ? dest_addr : CPU_TO_BRIDGE_ADDR(dest_addr);

    /* Debug: print parameters */
    DS_LOG("DS: slot=%d off=%x br=%x len=%x\n",
                slot_id, offset, bridge_addr, length);

    /* Drain the CPU store buffer so all prior cached stores are committed
     * to D-cache before the bridge writes to SDRAM.  Note: fence does NOT
     * writeback dirty D-cache lines on VexiiRiscv — callers must read DMA'd
     * data through SDRAM_UNCACHED() to bypass stale D-cache entries. */
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

    /* Yield async CD DMA if in flight */
    if (dataslot_yield_hook)
        dataslot_yield_hook();

    /* Set up registers */
    DS_SLOT_ID = slot_id;
    DS_SLOT_OFFSET = offset;
    DS_BRIDGE_ADDR = CPU_TO_BRIDGE_ADDR(src_addr);
    DS_LENGTH = length;

    /* Trigger write command */
    DS_COMMAND = DS_CMD_WRITE;

    /* Wait for completion */
    int result = dataslot_wait_complete();

    return result;
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
     *   slot 0 = quake.bin (deferload)
     *   slot 1 = pak0.pak (deferload)
     *   slot 2 = pak1.pak (deferload, optional) */
    if (size_out == NULL) return -1;

    switch (slot_id) {
        case 0:  /* Quake binary */
            *size_out = 4 * 1024 * 1024;   /* 4 MB */
            break;
        case 1:  /* PAK0 data */
        case 2:  /* PAK1 data */
            *size_out = 48 * 1024 * 1024;  /* 48 MB */
            break;
        default:
            *size_out = 1 * 1024 * 1024;   /* 1 MB default */
            break;
    }
    return 0;
}
