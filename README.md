# PocketQuake

Quake (1996) running natively on the [Analogue Pocket](https://www.analogue.co/pocket) via a VexRiscv RISC-V soft CPU on the Cyclone V FPGA. No emulation — the id Software Quake engine runs as bare-metal firmware on a hardware CPU synthesized in the FPGA fabric.

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
- **VexRiscv RISC-V CPU** — rv32imaf (integer, multiply/divide, atomics, single-precision FPU) at 100 MHz
- **Hardware span rasterizer** — FPGA accelerator offloads textured span drawing, z-buffer operations, and surface block rendering from the CPU
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
|  +-----------------------+    +-----------------------------------+   |
|  |    VexRiscv CPU       |    |        Memory Subsystem            |   |
|  |  rv32imaf @ 100 MHz   |    |                                   |   |
|  |                       |    |  +--------+  +--------+  +------+ |   |
|  |  I$ 32KB  (2-way)     |    |  | BRAM   |  | SDRAM  |  | PSRAM| |   |
|  |  D$ 128KB (2-way)     |    |  | 64KB   |  | 64MB   |  | 16MB | |   |
|  +-----------+-----------+    |  +--------+  +--------+  +------+ |   |
|              |                |              +--------+            |   |
|              |                |              | SRAM   |            |   |
|              |                |              | 256KB  |            |   |
|              |                +---+----------+--------+-----------++   |
|              |                    |                                    |
|  +-----------+--------------------+----------------------------+      |
|  |                    VexRiscv AXI Bus                         |      |
|  +----+--------+----------+---------+---------+--------+------++      |
|       |        |          |         |         |        |       |      |
|  +----+--+ +---+----+ +--+---+ +---+---+ +---+--+ +---+--+ +-+----+ |
|  | Video | | Audio  | | Span | | Link  | | Sys  | | SRAM | | Cmap | |
|  |Scanout| | Output | | Rast | | MMIO  | | Regs | | Fill | | BRAM | |
|  +-------+ +--------+ +------+ +-------+ +------+ +------+ +------+ |
|                                                                       |
+-----------------------------------------------------------------------+
```

## Memory Map

| Address Range             | Size   | Description                                          |
|---------------------------|--------|------------------------------------------------------|
| `0x00000000 - 0x0000FFFF` | 64 KB  | BRAM — bootloader, hot code (.fasttext), sin tables   |
| `0x10000000 - 0x10012BFF` | 75 KB  | Framebuffer 0 (320x240, 8-bit indexed)               |
| `0x10100000 - 0x10112BFF` | 75 KB  | Framebuffer 1 (double buffer)                        |
| `0x10200000`              | ~2 MB  | quake.bin load address (LMA, copied to PSRAM)        |
| `0x11000000`              | ~18 MB | pak0.pak game data (memory-mapped)                   |
| `0x12400000`              | ~28 MB | BSS + heap                                           |
| `0x20000000`              | 1.2 KB | Terminal VRAM (40x30 characters)                     |
| `0x30000000 - 0x30FFFFFF` | 16 MB  | PSRAM/CRAM0 — Quake code + rodata + data (VMA)       |
| `0x38000000 - 0x3803FFFF` | 256 KB | SRAM — Z-buffer (153 KB used)                        |
| `0x40000000`              | 256 B  | System registers                                     |
| `0x48000000`              | 256 B  | Span rasterizer registers                            |
| `0x4C000000`              | 8 B    | Audio FIFO (write samples / read status)             |
| `0x50000000`              | 256 B  | Link cable MMIO registers                            |
| `0x54000000`              | 16 KB  | Colormap BRAM                                        |
| `0x5C000000`              | 16 B   | SRAM fill engine registers                           |

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
| 0x40   | PAL_INDEX      | Palette write index (auto-increment)           |
| 0x44   | PAL_DATA       | Palette entry (RGB888, triggers write)         |

## Hardware Accelerators

### Span Rasterizer

The span rasterizer is an FPGA state machine that offloads the inner loops of Quake's software renderer. It handles:

- **Textured span drawing** — Replaces `D_DrawSpans8`, fetching texels from SDRAM and writing 8-bit pixels to the framebuffer
- **Z-span writing** — Writes z-buffer values to SRAM (`D_DrawZSpans`)
- **Surface block rendering** — Processes entire surface vblocks with hardware bilinear light interpolation (replaces `R_DrawSurfaceBlock8_mip0-3`)
- **Colormap lookup** — 16 KB BRAM stores the Quake colormap for light-level application
- **Turbulence** — 128-entry sine LUT for water/lava/teleporter warping

The rasterizer has a 3-deep command queue (1 active + 2-entry FIFO), a 16-entry direct-mapped texture cache backed by M10K block RAM, and non-blocking prefetch that predicts the next cache line during idle cycles.

### SRAM Fill Engine

Autonomously clears the z-buffer in SRAM while the CPU performs frame setup work, eliminating a ~153 KB memset per frame.

### SRAM Arbitration

Three-way priority mux for SRAM access: CPU > span rasterizer > fill engine.

## Video Pipeline

- **Resolution:** 320x240 @ 60 Hz (12.288 MHz pixel clock)
- **Color depth:** 8-bit indexed with 256-entry RGB888 hardware palette
- **Scanout:** Burst reads from SDRAM (80 bursts x BL=2 = 320 pixels/line)
- **Double buffered:** CPU draws to back buffer, `FB_SWAP` swaps on vsync
- **Clock domain crossing:** Dual-clock FIFO between pixel clock (12.288 MHz) and SDRAM clock (100 MHz)

## Audio Pipeline

- **Sample rate:** 48 kHz stereo, 16-bit signed
- **I2S output:** MCLK 12.288 MHz, SCLK 3.072 MHz, LRCK 48 kHz
- **FIFO:** 4096-entry dual-clock FIFO (CPU clock to audio clock)
- **Mixing:** Quake mixes at 11,025 Hz, firmware upsamples to 48 kHz via Bresenham resampling
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
| **16-pixel spans** | `D_DrawSpans8` processes 16 pixels per perspective-correct step (was 8) |
| **HW span accel** | Textured spans offloaded to FPGA rasterizer |
| **HW z-span accel** | Z-buffer writes offloaded to FPGA via SRAM port |
| **HW z-clear** | SRAM fill engine clears z-buffer while CPU does frame setup |
| **HW surface blocks** | Surface vblock rendering offloaded to FPGA (9 MMIO writes vs 80 per-row) |
| **Write-behind** | Rasterizer overlaps SDRAM writes with next pixel computation |
| **Texture prefetch** | Non-blocking background SDRAM reads predict next cache line |
| **M10K cache** | Texture cache data in M10K block RAM eliminates 16:1 combinational mux |

## FPGA Resource Usage

| Resource | Used | Available | Utilization |
|----------|------|-----------|-------------|
| ALMs     | ~9,875 | 18,480 | ~53% |
| Registers | ~15,466 | — | — |
| M10K blocks | 306 | 308 | 99% |
| PLLs | 2 | 4 | 50% |

## Building

### Prerequisites

- **RISC-V toolchain:** `riscv64-elf-gcc` with rv32imaf support
- **Intel Quartus Prime:** 25.1 or later (Lite edition sufficient)
- **Analogue Pocket:** Firmware 2.2 or later

```bash
# Arch Linux
sudo pacman -S riscv64-elf-gcc riscv64-elf-newlib

# The firmware uses -march=rv32imaf -mabi=ilp32f
# A custom libgcc without RVC is included (libgcc_norvc.a)
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
make                  # From project root — packages release/ directory
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
|   |   |   +-- ...
|   |   +-- libc/                  # Minimal C library
|   |   +-- linker.ld              # Linker script (BRAM/PSRAM/SDRAM layout)
|   |   +-- Makefile
|   |
|   +-- fpga/                      # FPGA design (Verilog)
|   |   +-- core/
|   |   |   +-- core_top.v         # Top-level: CPU + bus + peripherals
|   |   |   +-- io_sdram.v         # SDRAM controller
|   |   |   +-- span_rasterizer.v  # Hardware span/texture rasterizer
|   |   |   +-- video_scanout_indexed.v  # 8-bit indexed video scanout
|   |   |   +-- audio_output.v     # I2S audio output with FIFO
|   |   |   +-- link_mmio.v        # Link cable serial transceiver
|   |   |   +-- sram_fill.v        # Z-buffer clear engine
|   |   |   +-- text_terminal.v    # Debug text overlay
|   |   +-- vexriscv/
|   |   |   +-- VexRiscv_Full.v    # Generated RISC-V CPU core
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
- **RVC is disabled** for timing closure at 100 MHz. The firmware links against a custom `libgcc_norvc.a`.

## License

- **Quake engine:** GPL-2.0 (id Software)
- **VexRiscv:** MIT (SpinalHDL)
- **PocketQuake (FPGA/firmware):** MIT

## Acknowledgments

- [id Software](https://github.com/id-Software/Quake) — Original Quake source release
- [SpinalHDL/VexRiscv](https://github.com/SpinalHDL/VexRiscv) — RISC-V CPU core
- [Analogue](https://www.analogue.co/developer) — Pocket openFPGA development framework
