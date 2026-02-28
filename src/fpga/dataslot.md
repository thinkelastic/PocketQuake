# Dataslot Handshake Analysis & Hang Root Cause

## Problem Statement

Quake hangs at random places during initialization (COM_Init, V_Init, or earlier).
The deferload-pak branch performs many rapid CPU-triggered `dataslot_read()` calls
(32KB chunks) to load PAK file entries on demand. The hang is non-deterministic.

---

## Architecture Overview

### Clock Domains

| Domain | Frequency | Components |
|--------|-----------|------------|
| `clk_ram_controller` | 100 MHz | VexRiscv CPU, cpu_system.v, io_sdram.v, SDRAM arbiter (core_top.v) |
| `clk_74a` | 74.25 MHz | APF bridge bus, core_bridge_cmd.v, bridge CDC logic |

### Data Path for a `dataslot_read()`

```
Firmware (CPU @ 100 MHz)
  |
  | DS_COMMAND = DS_CMD_READ (write to sysreg 0x40000038)
  v
cpu_system.v (clk_ram_controller)
  |
  | target_dataslot_read = 1 (level-held until ACK)
  | cpu_ds_start fires in core_top.v:
  |   - bridge_dma_active = 1  (blocks CPU from SDRAM)
  |   - ds_done_ram_sync = 3'b000 (reset done tracking)
  |   - ds_done_seen_low = 0
  v
synch_3 CDC (clk_ram_controller -> clk_74a)  ~4 clk_74a cycles
  |
  v
core_bridge_cmd.v (clk_74a)
  |
  | Edge detection: target_dataslot_read_queue = 1
  | TARG_ST_IDLE:
  |   target_0 <= {16'h0000, 16'h0180}   // command code + clear status
  |   target_20-2C <= parameters
  | TARG_ST_DATASLOTOP:
  |   target_0[31:16] <= 16'h636D        // "cm" = command ready
  |   target_dataslot_done <= 0
  | TARG_ST_WAITRESULT_DSO:
  |   waits for APF bridge response
  v
APF Bridge (external, Pocket's own FPGA)
  |
  | Polls target_0 via bridge bus (SPI-like)
  | Sees [31:16] = 0x636D ("cm") -> starts processing
  | Reads target_20-2C for parameters (slot, offset, bridge_addr, length)
  | Writes target_0 = 0x6275_xxxx ("bu" = busy/ack)
  | Performs DMA: reads from SD card, writes to SDRAM via bridge bus
  | Writes target_0 = 0x6F6B_xxxx ("ok" = done)
  v
core_bridge_cmd.v
  |
  | TARG_ST_WAITRESULT_DSO:
  |   sees "bu" -> target_dataslot_ack = 1
  |   sees "ok" -> target_dataslot_done = 1, target_dataslot_err = result
  |   -> TARG_ST_IDLE, target_dataslot_ack = 0
  v
core_top.v done tracking (clk_ram_controller)
  |
  | ds_done_ram_sync syncs target_dataslot_done from clk_74a
  | ds_done_seen_low arms when ds_done_ram_sync[2] seen low
  | Quiet window: 1023 consecutive cycles with:
  |   - ds_done_ram_sync[2] = 1
  |   - ds_done_seen_low = 1
  |   - bridge_wr_idle = 1 (skid empty + dcfifo empty + no inflight)
  | -> ds_done_quiet_reached = 1
  | -> target_dataslot_done_safe = 1
  | -> bridge_dma_active = 0
  v
cpu_system.v
  |
  | target_done_sync syncs target_dataslot_done_safe (3-cycle delay, same domain)
  | DS_STATUS bit 1 (DONE) = target_done_s = target_done_sync[2]
  | Firmware sees DONE, returns from dataslot_wait_complete()
```

---

## SDRAM Refresh During Bridge DMA

### Refresh Generator (io_sdram.v:701-709)

A free-running 9-bit counter at `controller_clk` (100 MHz). Wraps at 512 cycles
(~5.12 us), sets `issue_autorefresh = 1`. Well within SDRAM's 7.8125 us max interval.

### Refresh Priority (io_sdram.v:329-348)

Refresh is the **highest priority** check in `ST_IDLE`:

```verilog
ST_IDLE:
  if (issue_autorefresh)          // FIRST — always wins
    if (row_open) -> precharge -> refresh
    else          -> refresh directly
  else if (word_rd_queue) -> ...  // CPU/periph reads
  else if (word_wr_queue) -> ...  // CPU/periph/bridge writes
  else if (burst_rd_queue) -> ...
  else if (burstwr_queue) -> ...
```

### How Refresh Interleaves with Bridge DMA Writes

Bridge DMA writes flow: APF bridge -> skid buffer (clk_74a) -> dcfifo (CDC) ->
SDRAM arbiter drains one word at a time -> io_sdram `word_wr`.

Each bridge drain produces a single `word_wr` to io_sdram (one 32-bit write, BL=2).
After the write completes (~4-8 cycles), io_sdram returns to `ST_IDLE`. If
`issue_autorefresh` fired during the write, refresh runs BEFORE the next drain.

The arbiter only issues a new drain when `!ram1_word_busy`, naturally waiting for
refresh to finish. The dcfifo (512-deep) absorbs the burst while refresh runs.

### io_sdram Reset vs Core Reset

- `io_sdram.reset_n` is tied to `pll_core_locked`, NOT `reset_n_apf`
- SDRAM controller runs as soon as PLL locks, regardless of core reset
- During boot (CPU in reset), bridge DMA writes and refresh both work normally

**Conclusion: SDRAM refresh is correctly handled during all DMA operations.**

---

## SDRAM Arbiter Priority (core_top.v:763-836)

```
1. Bridge SDRAM read    (highest — rare, single-shot)
2. Peripheral read      (video scanout — time-critical)
3. Bridge write FIFO drain
4. Peripheral write     (span rasterizer)
5. CPU SDRAM access     (lowest)
```

All operations gated by `!bridge_rd_active` (except bridge read itself) to prevent
`word_q_valid` misattribution.

### CPU Blocked During DMA (core_top.v:842-844)

```verilog
assign cpu_sdram_busy = ram1_word_busy | bridge_rd_active |
                        bridge_wr_skid_nonempty | !bridge_wr_fifo_empty |
                        bridge_wr_inflight | periph_active | bridge_dma_active;
```

When `bridge_dma_active = 1`, CPU cannot access SDRAM AT ALL. This is by design:
prevents D-cache writebacks from overwriting DMA data, and prevents span rasterizer
from interleaving with bridge writes.

---

## The `ds_done_seen_low` Race Condition (Benign)

### The Race

When `cpu_ds_start` fires for a new command:

```
T=0:  ds_done_ram_sync forced to 3'b000, ds_done_seen_low = 0
      target_dataslot_done still = 1 (stale, from previous command)

T=1:  ds_done_ram_sync = {0, 0, 1_stale}
      ds_done_ram_sync[2] = 0 -> ds_done_seen_low = 1  (FALSELY ARMED!)

T=2:  ds_done_ram_sync = {0, 1, 1}
      ds_done_ram_sync[2] = 0 -> ds_done_seen_low stays 1

T=3:  ds_done_ram_sync = {1, 1, 1}  (stale DONE fully re-propagated)
      ds_done_ram_sync[2] = 1 AND ds_done_seen_low = 1
      -> quiet counter STARTS (if bridge_wr_idle = 1)

T=~8: core_bridge_cmd reaches TARG_ST_DATASLOTOP, clears target_dataslot_done = 0
      (synch_3 to clk_74a ~5 cycles + edge detect ~1 + FSM ~2 = ~8 total)

T=~11: ds_done_ram_sync[2] = 0 (cleared DONE propagated back)
       -> quiet counter STOPS and RESETS
```

The quiet counter runs for ~8 cycles (T=3 to T=11). It needs 1023 cycles to
complete. **This race is definitively benign.** The counter cannot reach completion
during the stale DONE window.

### Why ds_done_seen_low Gets Falsely Armed

The forced `3'b000` reset creates an artificial "low" at `ds_done_ram_sync[2]` for
2 cycles. The `ds_done_seen_low` logic interprets this as "DONE went low" and arms
itself. This is a design flaw in the guard logic, but it's harmless because the
quiet window (1023 cycles) provides sufficient protection.

### After the Race Resolves

When the real DMA completes:
1. Bridge sets DONE = 1 (genuine)
2. ds_done_ram_sync[2] = 1, ds_done_seen_low = 1 (still armed from T=1)
3. bridge_wr_idle = 1 (after all DMA writes drain)
4. Quiet counter runs for 1023 cycles -> ds_done_quiet_reached = 1
5. target_dataslot_done_safe = 1
6. bridge_dma_active = 0

This is correct behavior. The ds_done_seen_low being pre-armed is fine because the
quiet counter only completes when the genuine DONE is present.

---

## ROOT CAUSE: Stale "ok" in `target_0` (core_bridge_cmd.v)

### The Bug

When `TARG_ST_IDLE` picks up a new command, the original code wrote ONLY the low
16 bits of `target_0`:

```verilog
// TARG_ST_IDLE (cycle N):
target_0[15:0] <= 16'h0180;        // NEW command code
// target_0[31:16] is STILL 0x6F6B ("ok") from previous command!

// TARG_ST_DATASLOTOP (cycle N+1):
target_0[31:16] <= 16'h636D;       // "cm" = command ready
```

**For 1 full clk_74a cycle**, `target_0 = {0x6F6B, 0x0180}`:
- High bits: stale "ok" from previous command
- Low bits: new command code

### Why This Causes the Hang

The APF bridge polls `target_0` asynchronously via the bridge bus. If a bridge
read lands during the 1-cycle window:

1. Bridge reads `target_0 = {0x6F6B, 0x0180}` — sees "ok", not "cm"
2. Bridge interprets this as "previous command still done" and does NOT start DMA
3. Next cycle: `target_0 = {0x636D, 0x0180}` ("cm") — but bridge may have already
   advanced its own state machine and won't re-poll immediately
4. Our FSM waits in `TARG_ST_WAITRESULT_DSO` forever for "bu"/"ok"
5. `target_dataslot_done` never asserts
6. `bridge_dma_active` stays HIGH forever
7. CPU is permanently frozen (cannot access SDRAM, cannot even timeout)

### Why It's Non-Deterministic

The bridge polls via SPI at its own rate. Whether the poll hits the 1-cycle window
depends on the exact phase relationship between the bridge's polling cycle and our
FSM transition. This varies with each boot and each command.

### Why It's Worse with Deferload-PAK

Each PAK file entry triggers a `dataslot_read()`. With hundreds of reads during
initialization, the probability of at least one poll hitting the 1-cycle window
is high (even if each individual probability is low).

### The Fix (Applied)

Clear `target_0[31:16]` explicitly at `TARG_ST_IDLE`:

```verilog
// Before (BUG):
target_0[15:0] <= 16'h0180;           // left stale "ok" in [31:16]

// After (FIXED):
target_0 <= {16'h0000, 16'h0180};     // clear status + set command code
```

Bridge now sees: `"ok"` -> `0x0000` -> `"cm"` (clean transition).
`0x0000` is none of "cm"/"bu"/"ok", so the bridge safely ignores it.

Applied to all four command types: read (0x0180), write (0x0184),
getfile (0x0190), openfile (0x0192).

---

## Why the Firmware Timeout Cannot Fire

`dataslot_wait_complete()` uses a `volatile int timeout` on the stack:

```c
volatile int timeout = TIMEOUT_LOOPS;  // 200,000,000
while (!(DS_STATUS & DS_STATUS_DONE)) {
    if (--timeout <= 0) return -2;     // NEVER REACHED
}
```

The `volatile` qualifier forces every read/write through memory (stack). If the
stack is in SDRAM (which it likely is — BSS/heap at 0x12400000), each `--timeout`
requires an SDRAM access. But `bridge_dma_active = 1` blocks all CPU SDRAM access.
The CPU stalls on the first stack access and **never executes the timeout check**.

### Potential Improvement

If hangs persist after the core_bridge_cmd fix, consider:
1. Moving the timeout to a register variable (remove `volatile`)
2. Using the hardware cycle counter (sysreg 0x40000004) for timeout instead
3. Adding a hardware watchdog timer that resets `bridge_dma_active` after N cycles

---

## Bridge DMA Write CDC Path (core_top.v:465-574)

### Write Flow

```
APF bridge (clk_74a)
  -> 4-deep skid buffer (clk_74a)
  -> 512-deep dcfifo (clk_74a -> clk_ram_controller)
  -> SDRAM arbiter drains one entry at a time
  -> io_sdram word_wr (one 32-bit write per drain)
```

### bridge_wr_inflight Tracking (core_top.v:556-587)

```verilog
// Set when arbiter issues a bridge drain write:
bridge_wr_inflight <= 1;

// Cleared when SDRAM write completes:
if (!ram1_word_busy && bridge_wr_inflight &&
    !bridge_wr_fifo_drain && !bridge_wr_drain_d1)
    bridge_wr_inflight <= 0;
```

`bridge_wr_drain_d1` (1-cycle delayed drain) covers the io_sdram pipeline gap
where `word_wr -> word_wr_queue -> word_busy` takes 2 cycles.

### bridge_wr_idle

```verilog
wire bridge_wr_idle = !bridge_wr_skid_nonempty && bridge_wr_fifo_empty &&
                      !bridge_wr_inflight;
```

All three conditions must be true: skid buffer empty (CDC-synced from clk_74a),
dcfifo empty, and no SDRAM write in flight. Only then does the quiet window
counter advance.

---

## bridge_dma_active Lifecycle (core_top.v:576-653)

### Set

```verilog
if (cpu_ds_start) begin
    if (cpu_ds_read_start || cpu_ds_write_start)
        bridge_dma_active <= 1'b1;    // NOT set for openfile
end
```

### Cleared

```verilog
wire target_dataslot_done_safe = ds_done_ram_sync[2] && ds_done_quiet_reached;

if (bridge_dma_active && target_dataslot_done_safe)
    bridge_dma_active <= 1'b0;
```

Requires:
1. Raw DONE propagated through 3-stage sync from clk_74a
2. ds_done_seen_low armed (DONE was seen low at some point)
3. bridge_wr_idle true for 1023 consecutive cycles (quiet window)

### Why the Quiet Window Exists

DONE from the APF bridge can lead the write-data tail by a variable amount.
The bridge signals "ok" when its DMA is complete, but writes may still be in
the dcfifo or SDRAM pipeline. The 1023-cycle (~10 us) quiet window ensures
all writes have committed to SDRAM before the CPU resumes and reads the data.

---

## DS_STATUS Signal Path

### ACK Path (clk_74a -> clk_ram_controller)

```
core_bridge_cmd.target_dataslot_ack (clk_74a)
  -> target_ack_sync[2:0] in cpu_system.v (3-stage CDC sync)
  -> target_ack_s = target_ack_sync[2]
  -> DS_STATUS bit 0
```

### DONE Path (clk_ram_controller -> clk_ram_controller, with latency)

```
core_bridge_cmd.target_dataslot_done (clk_74a)
  -> ds_done_ram_sync[2:0] in core_top.v (3-stage CDC sync)
  -> ds_done_quiet_reached (1023-cycle quiet window)
  -> target_dataslot_done_safe (same domain as cpu_system.v)
  -> target_done_sync[2:0] in cpu_system.v (3-stage delay, same domain)
  -> target_done_s = target_done_sync[2]
  -> DS_STATUS bit 1
```

Note: target_done_sync adds 3 cycles of latency but provides no CDC benefit
(both signals are already in clk_ram_controller domain).

### Stale DONE Clearing Guarantee

The firmware comment is correct:
> "By the time we observe ACK, stale DONE is guaranteed to be 0 already."

- `cpu_ds_start` resets `ds_done_ram_sync` to `000` -> `target_dataslot_done_safe = 0`
- `target_done_sync` propagates this in ~3 cycles (target_done_s = 0)
- ACK takes ~11+ cycles (CDC to bridge + bridge processing + CDC back)
- target_done_s is 0 well before ACK arrives

The firmware waits for ACK first, then DONE. By the time ACK is seen, stale DONE
has been flushed from the sync chain.

---

## Command Guard (cpu_system.v:609)

```verilog
if (!(target_dataslot_read || target_dataslot_write ||
      target_dataslot_openfile || target_ack_s)) begin
    // Accept new command
end
```

Prevents new commands when:
- A command signal is still asserted (level-held until ACK)
- ACK is still propagating (target_ack_s still high)

After a command completes:
- target_dataslot_read cleared by ACK (line 544-547)
- target_ack_s cleared when bridge FSM returns to IDLE (~3 sync cycles)
- The gap between DONE and next DS_COMMAND (firmware processing + memcpy + fence +
  sysreg writes) is >> 3 cycles, so target_ack_s is always 0 when the guard is checked

---

## Files Involved

| File | Role |
|------|------|
| `src/firmware/dataslot.c` | Firmware API: dataslot_read/write/open/wait |
| `src/firmware/dataslot.h` | Register defines, address macros, DMA buffer |
| `src/fpga/core/cpu_system.v:438-662` | Sysreg decode, command guard, CDC sync for ACK/DONE |
| `src/fpga/core/core_top.v:465-844` | Bridge CDC, SDRAM arbiter, bridge_dma_active tracking |
| `src/fpga/core/core_bridge_cmd.v:474-556` | Target FSM: command dispatch, APF handshake |
| `src/fpga/core/io_sdram.v` | SDRAM controller: refresh, read, write, open-page |

---

## Summary of Findings

1. **SDRAM refresh during DMA**: Correctly handled. io_sdram interleaves refresh
   between individual bridge drain writes. Refresh has highest priority at ST_IDLE.

2. **ds_done_seen_low race**: Exists but benign. The forced 3'b000 reset falsely
   arms ds_done_seen_low, but the 1023-cycle quiet window prevents premature
   bridge_dma_active clearing (counter only runs ~8 cycles during stale window).

3. **Root cause (fixed)**: Stale "ok" in target_0[31:16] during 1-cycle window at
   TARG_ST_IDLE. APF bridge could read stale "ok" + new command code, fail to
   recognize "cm", and never start DMA. Fixed by writing full 32-bit target_0 with
   cleared status at TARG_ST_IDLE.

4. **Firmware timeout broken**: volatile stack variable cannot be decremented when
   bridge_dma_active blocks SDRAM. If the fix doesn't resolve the hang, consider
   register-based or hardware timeout.
