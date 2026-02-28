# PocketQuake Dataslot Deferload Notes

## Summary

Previous analysis identified a potential race where dataslot done could be reported before the final bridge-to-SDRAM write fully landed.

Current `core_top.v` already includes a mitigation for that exact timing window:

- `bridge_wr_drain_d1` is used to cover the `word_wr -> word_wr_queue -> word_busy` pipeline gap
  - `src/fpga/core/core_top.v:515`
  - `src/fpga/core/core_top.v:675`
  - `src/fpga/core/core_top.v:682`
- Dataslot done/allcomplete are still gated by `bridge_wr_idle`
  - `src/fpga/core/core_top.v:521`
  - `src/fpga/core/core_top.v:1082`
  - `src/fpga/core/core_top.v:1135`

Given the current code, the original "early done due to inflight clear" hypothesis appears already addressed.

## Evidence for the Original Race (Now Mitigated)

In `io_sdram`, a write request is queued first and `word_busy` asserts later when the queued command is consumed:

- write enqueue
  - `src/fpga/core/io_sdram.v:684`
- busy asserted on queue consumption
  - `src/fpga/core/io_sdram.v:376`

This was the gap that could allow transient false-idle if only `!ram1_word_busy` was tracked. The added delayed drain guard (`bridge_wr_drain_d1`) is intended to close this gap.

## Firmware Interaction

Firmware waits for dataslot completion before using DMA output:

- wait logic
  - `src/firmware/dataslot.c:29`
- read command issue
  - `src/firmware/dataslot.c:119`
- on-demand PAK reads
  - `src/firmware/quake/sys_pocket.c:279`
  - `src/firmware/libc/file.c:160`

This remains the correct usage model.

## Remaining Risk

Bridge writes are suppressed when FIFO is full:

- `src/fpga/core/core_top.v:479`

No retry/backpressure is visible in this block, so sustained pressure could still risk data loss.

## Build/Fitter Note (Corrected)

Current FIFO config uses block RAM:

- `use_eab = "ON"`
  - `src/fpga/core/core_top.v:508`

So older notes claiming `use_eab = "OFF"` are stale.

## Status

Updated after re-checking current sources in this workspace. No RTL/firmware edits were made as part of this documentation update.
