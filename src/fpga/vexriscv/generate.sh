#!/bin/bash
# Generate VexRiscv with custom cache sizes for PocketQuake
# Usage: ./generate.sh [path/to/GenPocketQuake.scala]
#
# If no argument is given, uses GenPocketQuake.scala from this directory.
# Prerequisites: java, sbt

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VEXRISCV_DIR="$SCRIPT_DIR/VexRiscv"
SCALA_FILE="${1:-$SCRIPT_DIR/GenPocketQuake.scala}"

if [ ! -f "$SCALA_FILE" ]; then
    echo "ERROR: Scala file not found: $SCALA_FILE"
    exit 1
fi

# Clone VexRiscv if not already present
if [ ! -d "$VEXRISCV_DIR" ]; then
    echo "Cloning VexRiscv..."
    git clone https://github.com/SpinalHDL/VexRiscv.git "$VEXRISCV_DIR"
fi

# Copy generation script into VexRiscv project
echo "Using: $SCALA_FILE"
cp "$SCALA_FILE" "$VEXRISCV_DIR/src/main/scala/vexriscv/demo/GenPocketQuake.scala"

# Generate
echo "Generating VexRiscv..."
cd "$VEXRISCV_DIR"
sbt "runMain vexriscv.demo.GenPocketQuake"

# Copy output
if [ -f "$VEXRISCV_DIR/VexRiscv.v" ]; then
    # Back up old version
    if [ -f "$SCRIPT_DIR/VexRiscv_Full.v" ]; then
        cp "$SCRIPT_DIR/VexRiscv_Full.v" "$SCRIPT_DIR/VexRiscv_Full.v.bak"
        echo "Backed up old VexRiscv_Full.v -> VexRiscv_Full.v.bak"
    fi
    cp "$VEXRISCV_DIR/VexRiscv.v" "$SCRIPT_DIR/VexRiscv_Full.v"
    echo "Copied generated VexRiscv.v -> VexRiscv_Full.v"
    echo ""
    echo "Cacheable: 0x3X (PSRAM+SRAM)"
    echo "Uncacheable: 0x0X (BRAM), 0x1X (SDRAM — DMA coherency), all IO"
else
    echo "ERROR: VexRiscv.v not found after generation"
    exit 1
fi
