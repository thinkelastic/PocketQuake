# PocketQuake Performance Optimization Review

**Date:** March 2026
**FPGA:** Cyclone V (5CEBA4F23C8) @ 100MHz
**CPU:** VexiiRiscv RISC-V @ 100 MHz (rv32imafc)
**Resolution:** 320x240 @ 60 Hz

---

## Executive Summary

This codebase implements a hardware-accelerated Quake engine on the Analogue Pocket FPGA with impressive architectural choices including:
- Hardware span rasterizer with texture mapping + z-buffer
- 256KB external SRAM z-buffer with parallel access
- PSRAM code execution (16MB CellularRAM)
- DMA engines for framebuffer operations
- Fixed-point perspective correction in hardware

However, several critical bottlenecks prevent the design from reaching its full potential. The most impactful issue is **PSRAM synchronous burst mode is not enabled**, causing code execution to run 6-8x slower than capable.

---

## Priority 1: Critical Bottlenecks (High Impact)

### 1. PSRAM Sync Burst Not Utilized
**File:** `src/fpga/core/psram_controller.v`
**Impact:** 7x slower code execution from PSRAM

**Current Behavior:**
```verilog
// Lines 84-86 in psram_controller.v:
.sync_burst_en(1'b0),     // Disabled!
.sync_burst_len(6'b0),    // No burst length
```
The PSRAM hardware supports synchronous burst mode (sync burst = CellularRAM/CRAM synchronous mode), but it's hardcoded to disabled. Each 32-bit word access requires two separate 16-bit async operations (30-40 cycles each = 60-80 cycles/word).

The README states "37 cycles per 64-byte cache line" but this assumes sync burst mode which isn't enabled.

**Optimization:**
```verilog
// In psram_controller.v, line 84-86:
.sync_burst_en(1'b1),      // Enable sync burst
.sync_burst_len(6'd3),     // 4-word burst (64 bytes)
```

**Expected Impact:**
- 64-byte cache line fill: ~80 cycles → ~37 cycles (7x speedup)
- Code execution from PSRAM: 5-7x faster hot loops
- Estimated FPS improvement: 20-40% in CPU-bound scenes

---

### 2. Span Rasterizer Queue Depth
**File:** `src/fpga/core/span_rasterizer.v`
**Impact:** Marginal — likely 1-3% at best

**Current Behavior:**
```verilog
reg [1:0]  fifo_count;    // 2-entry FIFO (depth=3 total: 1 active + 2 pending)
wire can_accept = (fifo_count < 2'd2);
```

The 3-command queue lets the CPU stay ~2 commands ahead of the hardware.

**Why deeper FIFO has limited value:**
- Each span command requires ~9 MMIO register writes of setup data (texture base, lighting, s/t coords, etc.). The CPU can't fire commands much faster than the hardware consumes them.
- Increasing depth requires duplicating **all** parameter storage registers per entry (not just `fifo_count`) — the existing FIFO already stores `fifo_count_f`, and deeper entries would need full copies of control, texture, lighting, and coordinate registers.
- `span_can_accept()` is a non-blocking MMIO read that returns immediately; the CPU only spins when the FIFO is actually full, meaning the hardware is saturated.

**If pursued:** Profile how often `can_accept` returns false (add a perf counter for FIFO-full stalls). If stalls are rare, the current depth is adequate. If frequent, a 4-entry FIFO (1 active + 3 pending) would be a modest improvement without excessive register duplication.

**Expected Impact:**
- Likely 1-3% in span-heavy scenes
- Not worth the register cost unless profiling shows frequent FIFO-full stalls

---

### 3. Fixed-Priority SDRAM Arbiter May Delay CPU D-Cache Fills
**File:** `src/fpga/core/axi_sdram_arbiter.v`
**Impact:** Likely small (1-5%), needs measurement

**Current Behavior:**
```verilog
// Fixed priority: M0 (Span) > M1 (DMA) > M2 (CPU) > M3 (Bridge)
// Single outstanding transaction — one burst blocks for ~16-20 cycles
```

CPU code runs from PSRAM (I-cache), but **heap, BSP data, entities, and pak data live in SDRAM** (0x10000000 region). CPU D-cache misses contend with span rasterizer texture reads and framebuffer writes through the same arbiter.

However, contention is likely **intermittent, not continuous**:
- Span rasterizer texture cache (16 entries × 16 bytes) avoids SDRAM on hits
- Write-behind buffer overlaps framebuffer writes with pixel processing
- CPU D-cache is 128KB 2-way — good hit rate on heap/BSP working set
- Typical Quake scenes reuse few textures per frame, keeping texture cache warm

**Step 1: Measure before changing.** The arbiter already exposes `perf_grant_span/dma/cpu` taps. Add a contention counter:
```verilog
reg [31:0] perf_cpu_stalled;
always @(posedge clk)
    if (m2_arvalid && !grant_m2 && active)
        perf_cpu_stalled <= perf_cpu_stalled + 1;
```
Expose as a system register and read per-frame to quantify actual CPU stall time.

**Step 2 (only if data warrants):** Add a starvation guard — if CPU has been waiting >32 cycles, boost it above M0 for one transaction. ~10 lines, no latency cost in the uncontended case, caps worst-case D-cache miss penalty.

**Expected Impact:**
- Worst case (heavy texture misses + large CPU working set): 5-15%
- Typical scenes: 1-5% — contention is intermittent
- Significantly less impactful than fixing PSRAM sync burst (#1)

---

### 4. Surface Block: One Command Per Lightmap Cell
**File:** `src/firmware/quake/r_surf.c`
**Impact:** Moderate — reduces MMIO overhead per surface

**Current Behavior:**
```c
// r_surf.c lines 367-382:
for (int v = 0; v < r_numvblocks; v++) {
    while (!span_can_accept()) ;
    span_draw_surface_block(
        prowdest, psource,
        r_lightptr[0], r_lightptr[1],              // TL, TR
        r_lightptr[r_lightwidth], r_lightptr[...],  // BL, BR
        sourcetstep, surfrowbytes, blockdivshift);
    r_lightptr += r_lightwidth;   // Advance to next lightmap row
    prowdest += blocksize * surfrowbytes;
    psource  += blocksize * sourcetstep;
    if (psource >= r_sourcemax) psource -= r_stepback;  // Texture wrap
}
```

The hardware already processes all **pixel rows within a block** autonomously (bilinear light interpolation from 4 corners). But the firmware loops over **lightmap grid cells** (vblocks), issuing a separate command per cell with new light corners. For a typical surface with 4-8 vblocks, that's 36-72 MMIO writes + polling.

**Optimization:** Upload lightmap metadata once, let hardware iterate vblocks:
- Add registers: `SURF_LIGHT_PTR`, `SURF_LIGHT_WIDTH`, `SURF_VBLOCK_COUNT`
- Add registers: `SURF_SOURCE_MAX`, `SURF_STEPBACK` (texture wrap)
- Hardware auto-advances lightmap pointer and source/dest addresses per vblock
- Single command replaces the entire loop: ~12 MMIO writes instead of 9×N

**Complexity:** Moderate hardware change — needs lightmap read port (lightmap is in SDRAM), pointer arithmetic, and wrap logic in the span rasterizer FSM.

**Expected Impact:**
- Eliminates (r_numvblocks - 1) command submissions per surface
- MMIO savings: ~0.22ms/frame (32K → 10K cycles, ~100 surfaces × 4 vblocks avg)
- However, hardware is almost certainly the bottleneck — bilinear interpolation + SDRAM
  texture reads + framebuffer writes per vblock is far slower than ~80 CPU cycles to submit.
  The CPU mostly sits in `span_can_accept()`/`span_wait()` anyway, so saved MMIO time
  just becomes more idle waiting.
- **Realistic: ~1% or less.** The CPU can't do useful work during `span_wait()` because
  of a fundamental serialization constraint in Quake's renderer:
  ```
  D_DrawSurfaces loop (per surface):
    D_CacheSurface → R_DrawSurface → span_wait()  // build surface cache (HW)
    D_CalcGradients                                // needs cache complete
    d_drawspans()                                  // reads from cache
    D_DrawZSpans
  ```
  The surface cache must be fully written before `d_drawspans()` can read from it.
  The only overlap window is `D_CalcGradients` (~50-100 cycles) — not worth the complexity.
  Breaking this dependency would require splitting the renderer into separate cache-build
  and span-draw passes, which is a major architectural rewrite of Quake's rendering pipeline.

---

## Priority 2: FPGA Architecture Changes

### 6. Texture Cache Direct-Mapped Aliasing
**File:** `src/fpga/core/span_rasterizer.v`
**Impact:** Potentially significant on certain texture sizes, but mitigated by prefetch

**Current Cache Structure:**
```
16 entries, direct-mapped, 4-word (16-texel) lines
Index = tex_word_addr[5:2]  (bits 4-7 of word address → 16 sets)
Tag   = tex_word_addr[23:6] (18 bits)
Data  = 4 × M10K arrays (data0-data3), 16 bytes per line
Total capacity: 256 texels
```

**Aliasing pattern:** Texels 256 bytes apart map to the same cache index.
Quake textures are typically 64-128px wide. A 64-wide texture has rows 64 bytes apart,
so row 0 and row 4 are 256 bytes apart → same index. The surface block hardware iterates
up to 16 rows per block, so multiple rows can alias and thrash the same cache set.

**Existing mitigation:** Non-blocking sequential prefetch (lines 290-298) predicts the next
cache line and fills it in the background during pixel processing. This helps with linear
access patterns but doesn't prevent aliasing between rows.

**2-way set-associative option:** Would allow two aliasing addresses to coexist. However:
- Data arrays would double from 4 to 8 M10K blocks
- Current M10K usage is 301/308 (98%) — **may not fit**
- Tag arrays (registers) and LRU logic would fit in ALMs
- Halving sets to 8 reduces capacity if aliasing isn't the dominant miss cause

**Alternative: larger direct-mapped cache.** Going to 32 entries (512 texels) would push
the aliasing distance to 512 bytes, avoiding the common 64/128-wide texture conflict. Costs
4 more M10K blocks (same as 2-way) but simpler logic. Still constrained by M10K budget.

**Recommendation:** Add a cache miss rate counter first (count misses per frame via perf
register). If miss rate is low (prefetch is effective), this isn't worth the M10K cost.
If high, evaluate whether M10K budget allows 2-way or 32-entry expansion.

---

## Implementation Roadmap

### Phase 1: Enable Sync Burst
- [ ] Port PSRAM sync burst (BCR init FSM, PLL phase shift, IOB constraints) to this branch
- [ ] Verify timing closure
- [ ] Profile FPS improvement — this is expected to dominate all other gains

### Phase 2: Instrumentation
- [ ] Add SDRAM arbiter contention counter (CPU arvalid && !granted cycles)
- [ ] Add texture cache miss rate counter
- [ ] Add span FIFO-full stall counter
- [ ] Profile per-frame to identify actual bottlenecks before further changes

### Phase 3: Targeted Fixes (based on Phase 2 data)
- [ ] If arbiter contention is significant: add starvation guard
- [ ] If texture cache miss rate is high: evaluate 2-way or 32-entry (M10K budget permitting)
- [ ] If FIFO stalls are frequent: increase to 4-entry

---

## Expected Results

- **PSRAM sync burst (#1): 10-30% FPS improvement.** I-cache is 16KB but Quake's code is
  hundreds of KB — working set doesn't fit, so I-cache misses are frequent even in steady
  state. Cache line fill drops from ~224 cycles (async) to ~37 cycles (sync burst), ~6x
  faster. D-cache (128KB) also accesses .data/.rodata in PSRAM but working set likely fits,
  so fewer misses there. Impact is higher in CPU-heavy frames (BSP traversal, entity logic),
  lower in hardware-bound frames (dense spans).
- **Arbiter/cache/FIFO (#2, #3, #6):** Each likely 1-5%, depends on profiling data.
  Could be near 0% if the current design isn't actually bottlenecked there.
- **Surface block single-command (#4):** ~1% or less (hardware processing dominates, not MMIO)
- **Total realistic: 15-35%**, almost entirely from PSRAM sync burst. Remaining items
  combined might add 3-10% in the best case.

---

## Testing Methodology

1. Use existing `tools/capture_ocr.sh` frame rate measurement
2. Cycle counters already available: `SYS_CYCLE_LO` / `SYS_CYCLE_HI`
3. Add hardware perf counters: arbiter contention, cache miss rate, FIFO stalls
4. Profile before and after each change to validate impact
5. Consider FPGA timing closure impact (add pipelining if needed)
