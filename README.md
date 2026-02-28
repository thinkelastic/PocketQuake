# PocketQuake

Quake (1996) running natively on the [Analogue Pocket](https://www.analogue.co/pocket) via a VexiiRiscv RISC-V soft CPU on the Cyclone V FPGA. No emulation — the id Software Quake engine runs as bare-metal firmware on a hardware CPU synthesized in the FPGA fabric.

## Installation

1. Copy the contents of the `release/` directory to your Analogue Pocket SD card root
2. Copy `pak0.pak` from your Quake installation (`id1/` directory) to `Assets/pocketquake/common/` on the SD card
3. For link cable multiplayer, you **must** use a **GBC link cable** — GBA cables will NOT work

See [Installation Layout](#installation-layout) below for the full SD card directory structure.

### Controls

| Button | Action |
|--------|--------|
| D-pad left/right | Look left/right |
| D-pad up/down | Look up/down |
| L1 | Change weapon |
| R1 | Fire |
| Y (left face) | Strafe left |
| A (right face) | Strafe right |
| B (bottom face) | Walk forward |
| X (top face) | Jump |
| Left stick | Move (forward/back/strafe) |
| L2/R2 | Strafe left/right |
| Start | Menu |
| Select | Show scores |

In menus, A and B act as confirm and D-pad up/down navigates.

## Features

- **Full Quake engine** — Software-rendered Quake at 320x240, 8-bit indexed color with hardware palette lookup
- **VexiiRiscv RISC-V CPU** — rv32imafc (integer, multiply/divide, atomics, single-precision FPU, compressed instructions) at 100 MHz with branch prediction (BTB, GShare, RAS)
- **16 KB I-cache + 128 KB D-cache** — Direct-mapped I-cache with next-line prefetch, 2-way set-associative D-cache with 32-entry store buffer, 64-byte cache lines
- **PSRAM code execution** — Quake code runs from 16 MB CellularRAM in synchronous burst mode (37 cycles per 64-byte cache line fill)
- **Hardware span rasterizer** — FPGA accelerator offloads textured span drawing, z-buffer writes (to dedicated SRAM), and surface block rendering from the CPU
- **Dedicated SRAM z-buffer** — 256 KB external SRAM for z-buffer with parallel access alongside SDRAM texture/framebuffer operations
- **DMA blit engine** — Hardware-accelerated framebuffer clears and block copies
- **Alias transform MAC** — Fixed-function matrix-multiply accumulator for alias model vertex transformation
- **48 kHz stereo audio** — I2S output with 11,025 Hz mix rate upsampled via Bresenham
- **2-player link cable multiplayer** — GBC link cable at 256 kHz, full-duplex serial protocol
- **Dock support** — HDMI output when docked

## Architecture

```
+-----------------------------------------------------------------------+
|                       Analogue Pocket FPGA                            |
|                     (Cyclone V 5CEBA4F23C8)                           |
+-----------------------------------------------------------------------+
|                                                                       |
|  +------------------------+   +-----------------------------------+   |
|  |    VexiiRiscv CPU      |   |         Memory Subsystem          |   |
|  |  rv32imafc @ 100 MHz   |   |                                   |   |
|  |  BTB+GShare+RAS        |   | +------+ +------+ +-----+ +----+ |   |
|  |  I$ 16KB (direct-map)  |   | | BRAM | | SDRAM| |PSRAM| |SRAM| |   |
|  |  D$ 128KB (2-way)      |   | | 64KB | | 64MB | |16MB | |256K| |   |
|  +------------+-----------+   | +------+ +------+ +-----+ +----+ |   |
|               |               +---+--------+---------+-------+----+   |
|               |                   |        |         |       |        |
|  +------------+-------------------+--------+---------+--+    |        |
|  |                 AXI4 Bus Fabric (cpu_system.v)       |    |        |
|  |  iBus/dBus arbiter -> 3-way decode {SDRAM,PSRAM,Lcl} |    |        |
|  +----+-----------+-------------------+-----------------+    |        |
|       |           |                   |                      |        |
|       v           v                   v                      |        |
|  +---------+ +---------+  +------------------------------+   |        |
|  | SDRAM   | | PSRAM   |  |  AXI Peripheral Slave        |   |        |
|  | Arbiter | | Slave   |  |  (axi_periph_slave.v)        |   |        |
|  | 3-port  | |         |  |                              |   |        |
|  +---------+ +---------+  |  BRAM, Colormap, Sys Regs,   |   |        |
|   M0 M1 M2               |  Terminal, CDC, Periph Mux    |   |        |
|   |  |  |                 +-+---+---+---+---+---+---+----+   |        |
|   |  |  |                   |   |   |   |   |   |   |        |        |
|  +--++--++--+           +---+-+-+-+-+-+-+-+-+-+-+-+-+-+--+   |        |
|  |Span|DMA|CPU|         |Span|DMA|ATM|Audio|Link|Cmap|  |   |        |
|  |Rast|Blt|   |         |Regs|Reg|Reg|FIFO |MMIO|BRAM|  |   |        |
|  +--+-+---+---+         +----+---+---+-----+----+----+  |   |        |
|     |                                                    |   |        |
|     |  +---------------------------------------------+   |   |        |
|     |  |     SRAM 3-Way Mux (CPU > Span > Fill)      |<--+---+        |
|     |  +---------+-----------+-----------+-----------+                |
|     |            |           |           |                            |
|     +------------+    +------+----+ +----+------+                     |
|      (z-writes)       | sram_fill | | sram_ctrl | --> SRAM pins       |
|                       | (z-clear) | | (async)   |                     |
|                       +-----------+ +-----------+                     |
|                                                                       |
+-----------------------------------------------------------------------+
```

### CPU

VexiiRiscv is a RISC-V CPU generated with SpinalHDL. The PocketQuake configuration uses:

- **ISA:** rv32imafc — integer, hardware multiply/divide, atomics, single-precision FPU, compressed (RVC)
- **Pipeline:** Multi-stage, in-order, single-issue
- **Branch prediction:** BTB (512 sets, relaxed), GShare (4 KB), RAS (depth 4)
- **I-cache:** 16 KB, 1-way, 256 sets, 64-byte lines, next-line hardware prefetch
- **D-cache:** 128 KB, 2-way set-associative, 1024 sets, 64-byte lines, 32-entry store buffer
- **Bus:** 3 AXI4 interfaces — FetchL1 (I-cache reads), LsuL1 (D-cache reads/writes), IO (uncached MMIO)

### AXI4 Bus Fabric

The CPU's AXI4 buses are arbitrated and routed through a 3-way address decoder in `cpu_system.v`:

- **SDRAM** (`0x10-0x13`, `0x50-0x53`) — Through a 3-port AXI4 arbiter shared with the span rasterizer and DMA engine
- **PSRAM** (`0x30`) — Direct AXI4 slave, muxed with APF bridge writes
- **Local** (everything else) — AXI4 peripheral slave handling BRAM, system registers, terminal, SRAM z-buffer, and all peripheral register dispatch

## Memory Map

| Address Range             | Size   | Description                                          |
|---------------------------|--------|------------------------------------------------------|
| `0x00000000 - 0x0000FFFF` | 64 KB  | BRAM -- bootloader, hot code (.fasttext), sin tables  |
| `0x10000000 - 0x10012BFF` | 75 KB  | Framebuffer 0 (320x240, 8-bit indexed)               |
| `0x10100000 - 0x10112BFF` | 75 KB  | Framebuffer 1 (double buffer)                        |
| `0x10200000`              | ~2 MB  | quake.bin load address (LMA, copied to PSRAM)        |
| `0x11000000`              | ~18 MB | pak0.pak game data (memory-mapped)                   |
| `0x12400000`              | ~28 MB | BSS + heap                                           |
| `0x20000000`              | 1.2 KB | Terminal VRAM (40x30 characters)                     |
| `0x30000000 - 0x30FFFFFF` | 16 MB  | PSRAM/CRAM0 -- Quake code + rodata + data (VMA)      |
| `0x38000000 - 0x3803FFFF` | 256 KB | SRAM -- Z-buffer (153 KB used for 320x240)           |
| `0x40000000`              | 256 B  | System registers                                     |
| `0x44000000`              | 256 B  | DMA Clear/Blit registers                             |
| `0x48000000`              | 256 B  | Span rasterizer registers                            |
| `0x4C000000`              | 8 B    | Audio FIFO (write samples / read status)             |
| `0x4D000000`              | 256 B  | Link cable MMIO registers                            |
| `0x50000000 - 0x53FFFFFF` | 64 MB  | SDRAM uncached alias (bypasses D-cache)              |
| `0x54000000`              | 16 KB  | Colormap BRAM                                        |
| `0x58000000`              | 8 KB   | Alias Transform MAC (registers + normal table)       |
| `0x5C000000`              | 32 B   | SRAM fill engine registers (async z-buffer clear)    |

## System Registers (0x40000000)

| Offset | Register       | Description                                    |
|--------|----------------|------------------------------------------------|
| 0x00   | SYS_STATUS     | [0] sdram_ready, [1] allcomplete               |
| 0x04   | CYCLE_LO       | Cycle counter (low 32 bits)                    |
| 0x08   | CYCLE_HI       | Cycle counter (high 32 bits)                   |
| 0x0C   | DISPLAY_MODE   | 0 = terminal overlay, 1 = framebuffer          |
| 0x10   | FB_DISPLAY     | Display framebuffer address (25-bit word addr) |
| 0x14   | FB_DRAW        | Draw framebuffer address (25-bit word addr)    |
| 0x18   | FB_SWAP        | Write 1 to swap on next vsync                 |
| 0x20   | DS_SLOT_ID     | Target dataslot ID (16-bit)                    |
| 0x24   | DS_SLOT_OFFSET | Target dataslot offset                         |
| 0x28   | DS_BRIDGE_ADDR | Bridge destination/source address               |
| 0x2C   | DS_LENGTH      | Transfer length in bytes                       |
| 0x30   | DS_PARAM_ADDR  | Parameter struct address (for openfile)         |
| 0x34   | DS_RESP_ADDR   | Response struct address                        |
| 0x38   | DS_COMMAND     | Write to trigger: 1=read, 2=write, 3=openfile |
| 0x3C   | DS_STATUS      | [0] ack, [1] done, [4:2] err                  |
| 0x40   | PAL_INDEX      | Palette write index (auto-increment)           |
| 0x44   | PAL_DATA       | Palette entry (RGB888, triggers write)         |
| 0x50   | CONT1_KEY      | Controller 1 key bitmap (read-only)            |
| 0x54   | CONT1_JOY      | Controller 1 joystick axes (read-only)         |
| 0x58   | CONT1_TRIG     | Controller 1 triggers (read-only)              |
| 0x5C   | CONT2_KEY      | Controller 2 key bitmap (read-only)            |
| 0x60   | CONT2_JOY      | Controller 2 joystick axes (read-only)         |
| 0x64   | CONT2_TRIG     | Controller 2 triggers (read-only)              |

## Hardware Accelerators

### Span Rasterizer

The span rasterizer is an FPGA state machine that offloads the inner loops of Quake's software renderer. It handles:

- **Textured span drawing** -- Replaces `D_DrawSpans8`, fetching texels from SDRAM and writing 8-bit pixels to the framebuffer
- **Combined texture + z-buffer writes** -- Fire-and-forget SRAM z-writes alongside pixel processing, eliminating the separate `D_DrawZSpans` pass (~13 ms/frame savings)
- **Surface block rendering** -- Processes entire surface vblocks with hardware bilinear light interpolation (replaces `R_DrawSurfaceBlock8_mip0-3`)
- **Colormap lookup** -- 16 KB BRAM stores the Quake colormap for light-level application
- **Turbulence** -- 128-entry sine LUT for water/lava/teleporter warping

The rasterizer has a 3-deep command queue (1 active + 2-entry FIFO), a 16-entry direct-mapped texture cache backed by M10K block RAM, write-behind buffering that overlaps SDRAM writes with next-pixel computation, and non-blocking prefetch that predicts the next cache line during idle cycles.

### SRAM Z-Buffer

The z-buffer lives in a dedicated 256 KB external SRAM chip, separate from SDRAM. This provides true parallel access: the span rasterizer writes z-values to SRAM while simultaneously reading textures and writing pixels via SDRAM. A 3-way combinational priority mux (CPU > Span rasterizer > sram_fill) arbitrates access to the SRAM controller.

The **sram_fill engine** autonomously clears the z-buffer at the start of each frame, overlapping with CPU frame setup work.

### DMA Clear/Blit Engine

Hardware DMA for framebuffer clears and memory block copies, with its own AXI4 master port to SDRAM. Frees the CPU from large memset/memcpy operations.

### Alias Transform MAC

Fixed-function matrix-multiply-accumulate unit for transforming alias model vertices. Includes a 512-entry normal vector lookup table in block RAM.

## Video Pipeline

- **Resolution:** 320x240 @ 60 Hz (12.288 MHz pixel clock)
- **Color depth:** 8-bit indexed with 256-entry RGB888 hardware palette
- **Scanout:** Burst reads from SDRAM (80 bursts x BL=2 = 320 pixels/line)
- **Double buffered:** CPU draws to back buffer, `FB_SWAP` swaps on vsync
- **Clock domain crossing:** Dual-clock FIFO between pixel clock (12.288 MHz) and SDRAM clock (100 MHz)

## Audio Pipeline

- **Output:** 48 kHz stereo, 16-bit signed, I2S
- **I2S clocks:** MCLK 12.288 MHz, SCLK 3.072 MHz, LRCK 48 kHz
- **FIFO:** 2048-entry dual-clock FIFO (CPU clock to audio clock)
- **Mixing:** 11,025 Hz mono (native Quake sample rate), upsampled to 48 kHz via Bresenham resampling, duplicated to both L/R channels
- **Interface:** CPU writes 32-bit stereo samples `{L16, R16}` to MMIO 0x4C000000

## Link Cable Multiplayer

2-player multiplayer over the Analogue Pocket's GBC link cable.

- **Physical:** GBC cable (crosses SO/SI), GBA cables do NOT work
- **Protocol:** Full-duplex serial, 33-bit transfers `{valid, data[31:0]}`, MSB-first
- **Speed:** 256 kHz SCK (GBC mode)
- **Hardware:** TX/RX FIFOs (256 entries each), 3-stage SCK synchronizer for slave mode
- **Firmware:** `net_link.c` implements Quake's `net_driver_t` interface

## Boot Flow

1. FPGA configures, BRAM bootloader runs from address 0x00000000
2. APF bridge loads `quake.bin` into SDRAM at 0x10200000
3. APF bridge loads `pak0.pak` into SDRAM at 0x11000000
4. Bootloader copies `quake.bin` from SDRAM to PSRAM (0x30000000)
5. `fence` + `fence.i` (flush D-cache, invalidate I-cache)
6. Jump to `quake_main` in PSRAM

## Firmware Optimizations

| Optimization | Description |
|---|---|
| **PQ_FASTTEXT** | ~40 hot rendering functions pinned to 64 KB BRAM for single-cycle access |
| **LTO** | Link-time optimization across all Quake source files (saves ~12 KB code) |
| **HW span accel** | Textured spans offloaded to FPGA rasterizer with write-behind buffering |
| **Combined z-writes** | Z-buffer writes interleaved with texture spans, eliminating separate D_DrawZSpans pass |
| **Async z-clear** | sram_fill engine clears z-buffer autonomously while CPU does frame setup |
| **HW surface blocks** | Surface vblock rendering offloaded to FPGA (9 MMIO writes vs 80 per-row) |
| **Texture prefetch** | Non-blocking background SDRAM reads predict next cache line |
| **M10K cache** | Texture cache data in M10K block RAM eliminates 16:1 combinational mux |
| **PSRAM sync burst** | CellularRAM synchronous burst mode: 37 cycles per 64B line (vs 256 async) |
| **Size culling** | BSP subtrees culled when projected bounding box smaller than `r_cullsize` pixels |
| **Surface cache 2 MB** | Large surface cache reduces texture re-rasterization thrashing |
| **Scanline alias models** | Alias models use faster scanline path instead of recursive subdivision |

## FPGA Resource Usage

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| ALMs     | ~16,000 | 18,480 | ~86% |
| M10K blocks | ~301 | 308 | ~98% |
| DSP blocks | ~15 | 66 | ~23% |
| PLLs | 2 | 4 | 50% |

## Building

### Prerequisites

- **RISC-V toolchain:** `riscv64-elf-gcc` with rv32imafc support
- **Intel Quartus Prime:** 25.1 or later (Lite edition sufficient)
- **Analogue Pocket:** Firmware 2.2 or later

```bash
# Arch Linux
sudo pacman -S riscv64-elf-gcc riscv64-elf-newlib

# The firmware uses -march=rv32imafc -mabi=ilp32f
```

### Build Firmware

```bash
cd src/firmware
make                  # Builds quake.bin + firmware.mif
make install          # Copies MIF to FPGA directory
```

### Build FPGA

```bash
cd src/fpga
make                  # Full Quartus synthesis (~15 min)
make mif              # Update MIF only, no resynthesis (~1 min)
make program          # Program via JTAG (USB Blaster)
```

### Package Release

```bash
make                  # From project root -- packages release/ directory
```

### Quick Development Cycle

```bash
cd src/fpga
make quick            # Build firmware + update MIF + program via JTAG
```

## Installation Layout

```
SD Card Root/
+-- Assets/
|   +-- pocketquake/
|       +-- common/
|           +-- quake.bin
|           +-- pak0.pak        (from your Quake installation)
+-- Cores/
|   +-- ThinkElastic.PocketQuake/
|       +-- bitstream.rbf_r
|       +-- core.json
|       +-- (other .json files)
+-- Platforms/
    +-- _images/
    |   +-- pocketquake.bin
    +-- pocketquake.json
```

## Project Structure

```
.
+-- src/
|   +-- firmware/                  # Quake firmware (C, bare-metal)
|   |   +-- main.c                 # Bootloader
|   |   +-- quake/                 # Quake engine source (~100 files)
|   |   |   +-- sys_pocket.c       # Platform layer (file I/O, timing)
|   |   |   +-- vid_pocket.c       # Video driver (palette, framebuffer)
|   |   |   +-- snd_pocket.c       # Audio driver (I2S FIFO)
|   |   |   +-- in_pocket.c        # Input driver (gamepad)
|   |   |   +-- net_link.c         # Link cable network driver
|   |   |   +-- d_scan.c           # Span drawing (HW accelerated)
|   |   |   +-- r_surf.c           # Surface rendering (HW accelerated)
|   |   |   +-- r_edge.c           # Edge/span processing
|   |   |   +-- span_accel.h       # Span rasterizer MMIO definitions
|   |   |   +-- dma_accel.h        # DMA blit engine MMIO definitions
|   |   |   +-- sram_fill_accel.h  # SRAM fill engine MMIO definitions
|   |   |   +-- ...
|   |   +-- libc/                  # Minimal C library
|   |   +-- linker.ld              # Linker script (BRAM/PSRAM/SDRAM layout)
|   |   +-- Makefile
|   |
|   +-- fpga/                      # FPGA design (Verilog)
|   |   +-- core/
|   |   |   +-- core_top.v         # Top-level wiring and clock generation
|   |   |   +-- cpu_system.v       # VexiiRiscv + AXI4 bus router
|   |   |   +-- axi_periph_slave.v # AXI4 peripheral slave (BRAM, sysreg, etc.)
|   |   |   +-- axi_sdram_arbiter.v # 3-port SDRAM AXI4 arbiter
|   |   |   +-- axi_sdram_slave.v  # AXI4-to-SDRAM word protocol bridge
|   |   |   +-- axi_psram_slave.v  # AXI4-to-PSRAM word protocol bridge
|   |   |   +-- io_sdram.v         # SDRAM controller
|   |   |   +-- psram_controller.v # PSRAM controller (sync burst + async)
|   |   |   +-- sram_controller.v  # Async SRAM controller (32-bit word interface)
|   |   |   +-- sram_fill.v        # SRAM fill engine (autonomous z-buffer clear)
|   |   |   +-- span_rasterizer.v  # Hardware span/texture rasterizer
|   |   |   +-- dma_clear_blit.v   # DMA framebuffer clear/blit engine
|   |   |   +-- alias_transform_mac.v # Alias model vertex transform MAC
|   |   |   +-- video_scanout_indexed.v # 8-bit indexed video scanout
|   |   |   +-- audio_output.v     # I2S audio output with FIFO
|   |   |   +-- link_mmio.v        # Link cable serial transceiver
|   |   |   +-- text_terminal.v    # Debug text overlay
|   |   +-- vexriscv/
|   |   |   +-- VexiiRiscv_Full.v  # Generated RISC-V CPU core
|   |   |   +-- generate.sh        # SpinalHDL generation script
|   |   +-- apf/                   # Analogue Pocket framework (bridge, I/O)
|   |   +-- Makefile
|   |
|   +-- firmware_test/             # Hardware test firmware (SDRAM/PSRAM/CPU tests)
|
+-- dist/                          # Platform images and icons
+-- release/                       # Packaged release for SD card
+-- tools/
|   +-- capture_ocr.sh             # HDMI capture + OCR testing tool
+-- Makefile                       # Top-level build/package
+-- deploy.sh                      # Quick deploy to SD card
+-- *.json                         # APF configuration files
```

## Important Notes

- **JTAG programming loses SDRAM data.** After JTAG programming, the Pocket must reload `quake.bin` and `pak0.pak` from the SD card. Always deploy both firmware and bitstream to the SD card for testing.
- **Firmware and FPGA must match.** The BRAM initialization (MIF) is compiled into the bitstream. If `quake.bin` on the SD card doesn't match the MIF in the FPGA, `.fasttext` function calls will jump to wrong addresses and crash.

## License

- **Quake engine:** GPL-2.0 (id Software)
- **VexiiRiscv:** MIT (SpinalHDL)
- **PocketQuake (FPGA/firmware):** MIT

## Acknowledgments

- [id Software](https://github.com/id-Software/Quake) -- Original Quake source release
- [SpinalHDL/VexiiRiscv](https://github.com/SpinalHDL/VexiiRiscv) -- RISC-V CPU core
- [Analogue](https://www.analogue.co/developer) -- Pocket openFPGA development framework
