# Memory Controller Test Firmware
# Builds into BRAM (64KB), uses terminal for output

# Toolchain
CROSS = riscv64-unknown-elf-
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
FW_DIR = ../firmware

# Source files
SRCS_S = crt0.S
SRCS_C = main.c $(FW_DIR)/terminal.c
OBJS = $(SRCS_S:.S=.o) $(patsubst $(FW_DIR)/%.c,%.o,$(filter $(FW_DIR)/%,$(SRCS_C))) $(patsubst %.c,%.o,$(filter-out $(FW_DIR)/%,$(SRCS_C)))

# Architecture flags for RV32IM
ARCH = rv32im
ABI = ilp32

# Common flags
ARCHFLAGS = -march=$(ARCH) -mabi=$(ABI)

# C compiler flags
CFLAGS = $(ARCHFLAGS)
CFLAGS += -O2 -g
CFLAGS += -ffreestanding -fno-builtin
CFLAGS += -Wall -Wextra
CFLAGS += -ffunction-sections -fdata-sections
CFLAGS += -I$(FW_DIR)

# Assembler flags
ASFLAGS = $(ARCHFLAGS)

# Linker flags
LDFLAGS = $(ARCHFLAGS)
LDFLAGS += -T linker.ld -nostdlib -nostartfiles
LDFLAGS += -Wl,--gc-sections
LDFLAGS += -Wl,-Map=$(TARGET).map

# RAM size for MIF generation (64KB = 16384 words)
RAM_WORDS = 16384

# Default target
all: $(TARGET).bin $(TARGET).mif
	$(SIZE) $(TARGET).elf

# Link
$(TARGET).elf: $(OBJS) linker.ld
	$(LD) $(LDFLAGS) -o $@ $(OBJS)

# Binary output
$(TARGET).bin: $(TARGET).elf
	$(OBJCOPY) -O binary $< $@

# Quartus MIF output (Memory Initialization File)
$(TARGET).mif: $(TARGET).bin
	@echo "-- Firmware RAM initialization - $(RAM_WORDS) x 32-bit words (64KB)" > $@
	@echo "-- Auto-generated from $(TARGET).bin" >> $@
	@echo "" >> $@
	@echo "WIDTH=32;" >> $@
	@echo "DEPTH=$(RAM_WORDS);" >> $@
	@echo "" >> $@
	@echo "ADDRESS_RADIX=DEC;" >> $@
	@echo "DATA_RADIX=HEX;" >> $@
	@echo "" >> $@
	@echo "CONTENT BEGIN" >> $@
	@hexdump -v -e '1/4 "%08X\n"' $< | awk '{printf "%d : %s;\n", NR-1, $$1}' >> $@
	@LAST=$$(hexdump -v -e '1/4 "%08X\n"' $< | wc -l); \
	if [ $$LAST -lt $(RAM_WORDS) ]; then \
		echo "[$$LAST..$$(($(RAM_WORDS)-1))] : 00000013;" >> $@; \
	fi
	@echo "END;" >> $@
	@echo "Generated $@ with $$(hexdump -v -e '1/4 "%08X\n"' $< | wc -l) words of firmware"

# Compile C sources (local)
%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Compile C sources (from firmware dir)
%.o: $(FW_DIR)/%.c
	$(CC) $(CFLAGS) -c -o $@ $<

# Assemble assembly sources
%.o: %.S
	$(AS) $(ASFLAGS) -c -o $@ $<

# Install MIF to FPGA core directory
install: $(TARGET).bin $(TARGET).mif
	cp $(TARGET).mif $(FPGA_CORE_DIR)/firmware.mif
	@echo "MIF installed to $(FPGA_CORE_DIR)/firmware.mif"

# Disassembly
disasm: $(TARGET).elf
	$(OBJDUMP) -d $<

# Clean build artifacts
clean:
	rm -f $(OBJS) $(TARGET).elf $(TARGET).bin $(TARGET).mif $(TARGET).map

# Rebuild everything
rebuild: clean all

.PHONY: all clean rebuild install disasm
