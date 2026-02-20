# PocketQuake Firmware Makefile
# Builds bootloader (BRAM) + Quake engine (SDRAM)

# Toolchain
CROSS = riscv64-elf-
CC = $(CROSS)gcc
AS = $(CROSS)gcc
LD = $(CROSS)gcc
OBJCOPY = $(CROSS)objcopy
OBJDUMP = $(CROSS)objdump
SIZE = $(CROSS)size

# Target
TARGET = firmware

# Directories
FPGA_CORE_DIR = ../fpga/core
LIBC_DIR = libc
QUAKE_DIR = quake

# Source files - Bootloader (goes in BRAM)
BOOT_SRCS_C = main.c terminal.c dataslot.c misaligned.c

# Source files - libc (linked into PSRAM with Quake)
LIBC_SRCS = $(LIBC_DIR)/memory.c \
            $(LIBC_DIR)/string.c \
            $(LIBC_DIR)/ctype.c \
            $(LIBC_DIR)/stdlib.c \
            $(LIBC_DIR)/qsort.c \
            $(LIBC_DIR)/time.c \
            $(LIBC_DIR)/math.c \
            $(LIBC_DIR)/file.c

LIBC_ASM_SRCS = $(LIBC_DIR)/setjmp.S

# Source files - Quake engine (linked into PSRAM)
QUAKE_SRCS = $(QUAKE_DIR)/sys_pocket.c \
             $(QUAKE_DIR)/vid_pocket.c \
             $(QUAKE_DIR)/in_pocket.c \
             $(QUAKE_DIR)/chase.c \
             $(QUAKE_DIR)/cl_demo.c \
             $(QUAKE_DIR)/cl_input.c \
             $(QUAKE_DIR)/cl_main.c \
             $(QUAKE_DIR)/cl_parse.c \
             $(QUAKE_DIR)/cl_tent.c \
             $(QUAKE_DIR)/cmd.c \
             $(QUAKE_DIR)/common.c \
             $(QUAKE_DIR)/console.c \
             $(QUAKE_DIR)/crc.c \
             $(QUAKE_DIR)/cvar.c \
             $(QUAKE_DIR)/d_edge.c \
             $(QUAKE_DIR)/d_fill.c \
             $(QUAKE_DIR)/d_init.c \
             $(QUAKE_DIR)/d_modech.c \
             $(QUAKE_DIR)/d_part.c \
             $(QUAKE_DIR)/d_polyse.c \
             $(QUAKE_DIR)/draw.c \
             $(QUAKE_DIR)/d_scan.c \
             $(QUAKE_DIR)/d_sky.c \
             $(QUAKE_DIR)/d_sprite.c \
             $(QUAKE_DIR)/d_surf.c \
             $(QUAKE_DIR)/d_vars.c \
             $(QUAKE_DIR)/d_zpoint.c \
             $(QUAKE_DIR)/host.c \
             $(QUAKE_DIR)/host_cmd.c \
             $(QUAKE_DIR)/keys.c \
             $(QUAKE_DIR)/mathlib.c \
             $(QUAKE_DIR)/menu.c \
             $(QUAKE_DIR)/model.c \
             $(QUAKE_DIR)/net_link.c \
             $(QUAKE_DIR)/net_loop.c \
             $(QUAKE_DIR)/net_main.c \
             $(QUAKE_DIR)/net_none.c \
             $(QUAKE_DIR)/net_vcr.c \
             $(QUAKE_DIR)/nonintel.c \
             $(QUAKE_DIR)/pr_cmds.c \
             $(QUAKE_DIR)/pr_edict.c \
             $(QUAKE_DIR)/pr_exec.c \
             $(QUAKE_DIR)/r_aclip.c \
             $(QUAKE_DIR)/r_alias.c \
             $(QUAKE_DIR)/r_bsp.c \
             $(QUAKE_DIR)/r_draw.c \
             $(QUAKE_DIR)/r_edge.c \
             $(QUAKE_DIR)/r_efrag.c \
             $(QUAKE_DIR)/r_light.c \
             $(QUAKE_DIR)/r_main.c \
             $(QUAKE_DIR)/r_misc.c \
             $(QUAKE_DIR)/r_part.c \
             $(QUAKE_DIR)/r_sky.c \
             $(QUAKE_DIR)/r_sprite.c \
             $(QUAKE_DIR)/r_surf.c \
             $(QUAKE_DIR)/r_vars.c \
             $(QUAKE_DIR)/sbar.c \
             $(QUAKE_DIR)/screen.c \
             \
             $(QUAKE_DIR)/sv_main.c \
             $(QUAKE_DIR)/sv_move.c \
             $(QUAKE_DIR)/sv_phys.c \
             $(QUAKE_DIR)/sv_user.c \
             $(QUAKE_DIR)/view.c \
             $(QUAKE_DIR)/wad.c \
             $(QUAKE_DIR)/world.c \
             $(QUAKE_DIR)/zone.c \
             $(QUAKE_DIR)/cd_null.c \
             $(QUAKE_DIR)/snd_dma.c \
             $(QUAKE_DIR)/snd_mix.c \
             $(QUAKE_DIR)/snd_mem.c \
             $(QUAKE_DIR)/snd_pocket.c \
             $(QUAKE_DIR)/printf_pocket.c

# Assembly sources
SRCS_S = start.S

# All sources
ALL_C_SRCS = $(BOOT_SRCS_C) $(LIBC_SRCS) $(QUAKE_SRCS)
OBJS = $(ALL_C_SRCS:.c=.o) $(SRCS_S:.S=.o) $(LIBC_ASM_SRCS:.S=.o)

# Compiler flags for RV32IMAFC (hardware single-precision FPU + compressed ISA)
ARCH = rv32imafc
ABI = ilp32f
CFLAGS = -march=$(ARCH) -mabi=$(ABI) -Os -Wall -Wextra
CFLAGS += -ffreestanding -nostdlib -nostartfiles
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -fno-builtin
CFLAGS += -fsingle-precision-constant
CFLAGS += -I. -I$(LIBC_DIR)

# Quake-specific flags
# Build Quake engine for speed while keeping boot/libc at size-optimized defaults.
QUAKE_CFLAGS = $(filter-out -Os,$(CFLAGS)) -O3 -flto -std=gnu11 -fcommon -I$(QUAKE_DIR) -Wno-unused-parameter -Wno-unused-variable
QUAKE_CFLAGS += -Wno-missing-field-initializers -Wno-sign-compare
QUAKE_CFLAGS += -Wno-implicit-function-declaration -Wno-pointer-sign
QUAKE_CFLAGS += -Wno-discarded-qualifiers -Wno-parentheses
QUAKE_CFLAGS += -DPOCKET_QUAKE

# Link-cable network toggle (0=disabled, 1=enable net_link MMIO transport)
POCKET_LINK_ENABLE ?= 1
QUAKE_CFLAGS += -DPOCKET_LINK_ENABLE=$(POCKET_LINK_ENABLE)

# Optional renderer-only fast-math for raster hot paths.
# Set RENDERER_FAST_MATH=0 to disable.
RENDERER_FAST_MATH ?= 1
QUAKE_RENDER_CFLAGS =
ifeq ($(RENDERER_FAST_MATH),1)
QUAKE_RENDER_CFLAGS += -ffast-math -fno-math-errno -fno-trapping-math
endif

# Assembler flags
ASFLAGS = -march=$(ARCH)_zicsr -mabi=$(ABI)

# Linker flags
LDFLAGS = -march=$(ARCH) -mabi=$(ABI)
LDFLAGS += -T linker.ld -nostdlib -nostartfiles
LDFLAGS += -Wl,--gc-sections
LDFLAGS += -Wl,-Map=$(TARGET).map
LDFLAGS += -flto

# Standard libgcc for rv32imafc/ilp32f (includes compressed instructions)
LIBGCC = $(shell $(CC) -march=$(ARCH) -mabi=$(ABI) -print-libgcc-file-name)
LIBS = $(LIBGCC)

# RAM size for MIF generation (64KB = 16384 words)
# Only the bootloader goes into MIF (BRAM)
RAM_WORDS = 16384

# Default target
all: $(TARGET).bin $(TARGET).mif $(TARGET).lst quake.bin
	$(SIZE) $(TARGET).elf

# Link everything together
$(TARGET).elf: $(OBJS) linker.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS) $(LIBS)

# Full binary output (bootloader + SDRAM sections)
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# Extract BRAM image (bootloader + BRAM hot sections) for MIF
$(TARGET).mif: $(TARGET).elf
	$(OBJCOPY) -O binary \
		--only-section=.boot \
		--only-section=.boot_data \
		--only-section=.boot_bss \
		--only-section=.fasttext \
		--only-section=.fastdata \
		$< boot.bin
	@echo "-- Firmware RAM initialization - $(RAM_WORDS) x 32-bit words" > $@
	@echo "-- Auto-generated from boot sections" >> $@
	@echo "" >> $@
	@echo "WIDTH=32;" >> $@
	@echo "DEPTH=$(RAM_WORDS);" >> $@
	@echo "" >> $@
	@echo "ADDRESS_RADIX=DEC;" >> $@
	@echo "DATA_RADIX=HEX;" >> $@
	@echo "" >> $@
	@echo "CONTENT BEGIN" >> $@
	@hexdump -v -e '1/4 "%08X\n"' boot.bin | awk '{printf "%d : %s;\n", NR-1, $$1}' >> $@
	@LAST=$$(hexdump -v -e '1/4 "%08X\n"' boot.bin | wc -l); \
	if [ $$LAST -lt $(RAM_WORDS) ]; then \
		echo "[$$LAST..$$(($(RAM_WORDS)-1))] : 00000013;" >> $@; \
	fi
	@echo "END;" >> $@
	@echo "Generated $@ with $$(hexdump -v -e '1/4 "%08X\n"' boot.bin | wc -l) words of BRAM image"

# Extract Quake binary (loaded by APF bridge to SDRAM, copied to PSRAM by bootloader)
quake.bin: $(TARGET).elf
	$(OBJCOPY) -O binary --only-section=.text --only-section=.data $< $@
	@echo "Generated $@ ($$(wc -c < $@) bytes)"

# Disassembly listing
$(TARGET).lst: $(TARGET).elf
	$(OBJDUMP) -d -S $< > $@

# Compile boot C sources
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Compile libc sources
$(LIBC_DIR)/%.o: $(LIBC_DIR)/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Assemble libc assembly
$(LIBC_DIR)/%.o: $(LIBC_DIR)/%.S
	$(AS) $(ASFLAGS) -c -o $@ $<

# Compile Quake sources with relaxed warnings
$(QUAKE_DIR)/%.o: $(QUAKE_DIR)/%.c
	@EXTRA_FLAGS=""; \
	case "$<" in \
		$(QUAKE_DIR)/d_*.c|$(QUAKE_DIR)/r_*.c) EXTRA_FLAGS="$(QUAKE_RENDER_CFLAGS)" ;; \
	esac; \
	$(CC) $(QUAKE_CFLAGS) $$EXTRA_FLAGS -c -o $@ $<

# Assemble assembly sources
%.o: %.S
	$(AS) $(ASFLAGS) -c -o $@ $<

# Install MIF to FPGA core directory
install: $(TARGET).mif
	cp $(TARGET).mif $(FPGA_CORE_DIR)/firmware.mif
	@echo "MIF installed to $(FPGA_CORE_DIR)/firmware.mif"

# Copy quake.bin to release assets
release: quake.bin
	mkdir -p ../../release/Assets/pocketquake/common
	cp quake.bin ../../release/Assets/pocketquake/common/
	@echo "quake.bin copied to release/Assets/pocketquake/common/"

# Clean build artifacts
clean:
	rm -f $(OBJS) $(TARGET).elf $(TARGET).bin $(TARGET).mif $(TARGET).map $(TARGET).lst
	rm -f boot.bin quake.bin

# Rebuild everything
rebuild: clean all

# Show memory usage
mem: $(TARGET).elf
	$(SIZE) -A -x $(TARGET).elf

.PHONY: all clean rebuild install release mem
