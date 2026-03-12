#!/bin/bash
# VexiiRiscv overclocking sweep for Fmax optimization
#
# Generates VexiiRiscv CPU variants with different generation knobs,
# runs Quartus synthesis+fit+STA, and logs timing + resource results.
#
# Usage:
#   ./vexii_sweep.sh phase1                Run all Phase 1 configs
#   ./vexii_sweep.sh run <config> [seed]   Run a single config
#   ./vexii_sweep.sh gen <config>          Generate Verilog only (no Quartus)
#   ./vexii_sweep.sh build [seed]          Build current VexiiRiscv_Full.v (no sbt)
#   ./vexii_sweep.sh seeds <start> <end>   Seed sweep (current Verilog, fit+sta only)
#   ./vexii_sweep.sh freq <mhz>           Set PLL frequency + update timings
#   ./vexii_sweep.sh list                  List available configs
#   ./vexii_sweep.sh summary              Show results CSV

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_DIR="$SCRIPT_DIR"
VEXII_REPO="/home/alberto/Repos/VexiiRiscv"
VEXII_DEST="$FPGA_DIR/vexriscv/VexiiRiscv_Full.v"
RESULTS_FILE="$FPGA_DIR/vexii_sweep_results.csv"

QUARTUS_DIR=/home/alberto/altera_lite/25.1std/quartus/bin
export PATH="$QUARTUS_DIR:$PATH"

PROJECT=ap_core
QSF="${PROJECT}.qsf"
DEFAULT_SEED=13

# ============================================================
# Base VexiiRiscv generation flags (current working config)
# ============================================================

BASE_FLAGS=(
    --with-rvm --with-rva --with-rvf --with-rvc
    --with-fetch-l1 --fetch-l1-sets=512 --fetch-l1-ways=1 --fetch-l1-refill-count=2
    --fetch-l1-hardware-prefetch=nl --fetch-axi4
    --with-lsu-l1 --lsu-l1-sets=1024 --lsu-l1-ways=2
    --lsu-l1-refill-count=2 --lsu-l1-writeback-count=2 --lsu-l1-store-buffer-slots=2 --lsu-l1-store-buffer-ops=32
    --lsu-l1-axi4
    --with-btb --btb-sets=512 --relaxed-btb --relaxed-btb-hit
    --with-gshare --with-ras
    --regfile-async --allow-bypass-from=0
    --relaxed-src
    --reset-vector=0
    --region base=0,size=8000,main=0,exe=1
    --region base=10000000,size=4000000,main=1,exe=1
    --region base=20000000,size=10000000,main=0,exe=0
    --region base=30000000,size=8000000,main=1,exe=1
    --region base=38000000,size=8000000,main=0,exe=0
    --region base=40000000,size=40000000,main=0,exe=0
)

# ============================================================
# Config definitions (modifications to BASE_FLAGS)
# ============================================================
# Each config function echoes the FULL flags list to stdout.
# It starts from BASE_FLAGS and applies modifications.

config_baseline() {
    echo "${BASE_FLAGS[@]}"
}

config_btb256() {
    local flags=("${BASE_FLAGS[@]}")
    # Replace --btb-sets=512 with --btb-sets=256
    echo "${flags[@]}" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_btb128() {
    local flags=("${BASE_FLAGS[@]}")
    echo "${flags[@]}" | sed 's/--btb-sets=512/--btb-sets=128/'
}

config_gshare2k() {
    # Add --gshare-bytes=2048 (default is 4096)
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048"
}

config_gshare1k() {
    echo "${BASE_FLAGS[@]} --gshare-bytes=1024"
}

config_noRas() {
    local flags=("${BASE_FLAGS[@]}")
    # Remove --with-ras
    echo "${flags[@]}" | sed 's/--with-ras//'
}

config_relaxedBranch() {
    echo "${BASE_FLAGS[@]} --relaxed-branch"
}

config_relaxedDiv() {
    echo "${BASE_FLAGS[@]} --relaxed-div"
}

config_relaxedMulInputs() {
    echo "${BASE_FLAGS[@]} --relaxed-mul-inputs"
}

config_btb256_gsh2k() {
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_btb256_gsh2k_rlxBr() {
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048 --relaxed-branch" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_rlxBr_rlxDiv() {
    echo "${BASE_FLAGS[@]} --relaxed-branch --relaxed-div"
}

config_rlxBr_rlxMul() {
    echo "${BASE_FLAGS[@]} --relaxed-branch --relaxed-mul-inputs"
}

config_rlxBr_rlxDiv_rlxMul() {
    echo "${BASE_FLAGS[@]} --relaxed-branch --relaxed-div --relaxed-mul-inputs"
}

config_btb128_gsh1k_rlxBr() {
    echo "${BASE_FLAGS[@]} --gshare-bytes=1024 --relaxed-branch" | sed 's/--btb-sets=512/--btb-sets=128/'
}

config_btb256_rlxBr() {
    echo "${BASE_FLAGS[@]} --relaxed-branch" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_btb256_rlxBr_lsuBypass() {
    echo "${BASE_FLAGS[@]} --relaxed-branch --with-lsu-bypass" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_btb256_rlxBr_rlxDiv() {
    echo "${BASE_FLAGS[@]} --relaxed-branch --relaxed-div" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_rlxBr_noRas() {
    echo "${BASE_FLAGS[@]} --relaxed-branch" | sed 's/--with-ras//'
}

config_btb256_rlxBr_noRas() {
    echo "${BASE_FLAGS[@]} --relaxed-branch" | sed 's/--btb-sets=512/--btb-sets=256/' | sed 's/--with-ras//'
}

config_lateAlu() {
    # Late ALU: breaks D-cache bypass critical path, needs reduced BTB+GShare to fit
    echo "${BASE_FLAGS[@]} --with-late-alu --gshare-bytes=2048" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_lateAlu_lsu1way() {
    # Late ALU + 1-way D-cache: maximum ALM savings to fit late ALU
    echo "${BASE_FLAGS[@]} --with-late-alu --gshare-bytes=2048" | sed 's/--btb-sets=512/--btb-sets=256/' | sed 's/--lsu-l1-ways=2/--lsu-l1-ways=1/'
}

config_lsu1way() {
    # 1-way D-cache (64KB): halves M10K bank count, simpler WE decode
    echo "${BASE_FLAGS[@]}" | sed 's/--lsu-l1-ways=2/--lsu-l1-ways=1/'
}

config_lsu1way_rlxBr() {
    # 1-way D-cache + relaxed-branch
    echo "${BASE_FLAGS[@]} --relaxed-branch" | sed 's/--lsu-l1-ways=2/--lsu-l1-ways=1/'
}

config_noRlxSrc() {
    # Remove --relaxed-src
    echo "${BASE_FLAGS[@]}" | sed 's/ --relaxed-src//'
}

# --- GShare readAt=1 variants (require Param.scala source edit) ---

config_readAt1() {
    # GShare readAt=1: push PHT read to fetch stage 1, breaks PC→GShare RAM critical path
    # REQUIRES: PATCH_GSHARE_READAT=1
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]}"
}

config_readAt1_rlxBr() {
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]} --relaxed-branch"
}

config_readAt1_btb256() {
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]}" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_readAt1_gsh2k() {
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048"
}

config_readAt1_btb256_gsh2k() {
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_readAt1_btb256_gsh2k_rlxBr() {
    PATCH_GSHARE_READAT=1
    echo "${BASE_FLAGS[@]} --gshare-bytes=2048 --relaxed-branch" | sed 's/--btb-sets=512/--btb-sets=256/'
}

config_readAt1_hist8() {
    # GShare readAt=1 + historyWidth=8 (shorter address path)
    PATCH_GSHARE_READAT=1
    PATCH_GSHARE_HISTWIDTH=8
    echo "${BASE_FLAGS[@]}"
}

config_readAt1_hist8_gsh1k() {
    PATCH_GSHARE_READAT=1
    PATCH_GSHARE_HISTWIDTH=8
    echo "${BASE_FLAGS[@]} --gshare-bytes=1024"
}

# --- No GShare variants ---

config_noGShare() {
    # Remove GShare entirely: eliminates 5/10 worst timing paths, 3-8% IPC cost
    echo "${BASE_FLAGS[@]}" | sed 's/--with-gshare//'
}

config_noGShare_rlxBr() {
    echo "${BASE_FLAGS[@]} --relaxed-branch" | sed 's/--with-gshare//'
}

config_noGShare_btb256() {
    echo "${BASE_FLAGS[@]}" | sed 's/--with-gshare//' | sed 's/--btb-sets=512/--btb-sets=256/'
}

PHASE1_CONFIGS="baseline btb256 btb128 gshare2k gshare1k noRas relaxedBranch relaxedDiv relaxedMulInputs btb256_gsh2k btb256_gsh2k_rlxBr rlxBr_rlxDiv rlxBr_rlxMul rlxBr_rlxDiv_rlxMul btb128_gsh1k_rlxBr btb256_rlxBr"

# Full sweep: readAt=1 variants first (most impactful), then noGShare, then combos
FULLSWEEP_CONFIGS="readAt1 readAt1_rlxBr readAt1_btb256 readAt1_gsh2k readAt1_btb256_gsh2k readAt1_btb256_gsh2k_rlxBr readAt1_hist8 readAt1_hist8_gsh1k noGShare noGShare_rlxBr noGShare_btb256 baseline relaxedBranch btb256_gsh2k_rlxBr"

# ============================================================
# VexiiRiscv Verilog generation via sbt
# ============================================================

generate_vexii() {
    local config_name="$1"
    local log_file="$FPGA_DIR/output_files/vexii_${config_name}.log"

    # Reset patch variables
    PATCH_GSHARE_READAT=""
    PATCH_GSHARE_HISTWIDTH=""

    # Get flags for this config
    local flags
    if declare -f "config_${config_name}" > /dev/null 2>&1; then
        # Call once in current shell to set PATCH_* variables
        config_${config_name} > /dev/null 2>&1
        # Call again in subshell to capture flags output
        flags=$(config_${config_name})
    else
        echo "ERROR: Unknown config '$config_name'"
        return 1
    fi

    echo ">>> Generating VexiiRiscv ($config_name)..."
    echo "    Flags: $flags"

    local orig_dir="$PWD"
    local param_file="$VEXII_REPO/src/main/scala/vexiiriscv/Param.scala"
    local patched=0

    # Apply source patches if needed (target GSharePlugin block specifically)
    if [ -n "$PATCH_GSHARE_READAT" ]; then
        echo "    Patching GShare readAt=0 → readAt=$PATCH_GSHARE_READAT"
        # Target the GSharePlugin constructor (unique context: "historyWidth = 12," on prev line)
        sed -i '/historyWidth = 12,/{n;s/readAt = 0,/readAt = '"$PATCH_GSHARE_READAT"',/}' "$param_file"
        patched=1
    fi
    if [ -n "$PATCH_GSHARE_HISTWIDTH" ]; then
        echo "    Patching GShare historyWidth=12 → historyWidth=$PATCH_GSHARE_HISTWIDTH"
        # Target the GSharePlugin constructor (unique context: "memBytes = gshareBytes," on prev line)
        sed -i '/memBytes = gshareBytes,/{n;s/historyWidth = 12,/historyWidth = '"$PATCH_GSHARE_HISTWIDTH"',/}' "$param_file"
        patched=1
    fi

    cd "$VEXII_REPO"

    local gen_ok=0
    if sbt "Test/runMain vexiiriscv.Generate $flags" > "$log_file" 2>&1; then
        gen_ok=1
    fi

    cd "$orig_dir"

    # Restore patches
    if [ "$patched" = "1" ]; then
        if [ -n "$PATCH_GSHARE_READAT" ]; then
            sed -i '/historyWidth = 1[0-9],\|historyWidth = [0-9],/{n;s/readAt = '"$PATCH_GSHARE_READAT"',/readAt = 0,/}' "$param_file"
        fi
        if [ -n "$PATCH_GSHARE_HISTWIDTH" ]; then
            sed -i '/memBytes = gshareBytes,/{n;s/historyWidth = '"$PATCH_GSHARE_HISTWIDTH"',/historyWidth = 12,/}' "$param_file"
        fi
        echo "    Param.scala patches restored"
    fi

    if [ "$gen_ok" != "1" ]; then
        echo "FAILED: sbt generation (see output_files/vexii_${config_name}.log)"
        tail -20 "$log_file"
        return 1
    fi

    # Copy generated Verilog
    cp "$VEXII_REPO/VexiiRiscv.v" "$VEXII_DEST"
    echo "    VexiiRiscv.v copied to $VEXII_DEST"
    return 0
}

# ============================================================
# Extract timing from STA summary
# ============================================================

extract_timing() {
    local sta_file="$1"
    warm_setup=$(grep -A1 "Slow 1100mV 85C Model Setup.*mp_ram" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
    cold_setup=$(grep -A1 "Slow 1100mV 0C Model Setup.*mp_ram" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
    fast_setup=$(grep -A1 "Fast 1100mV 85C Model Setup.*mp_ram" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
}

# ============================================================
# Extract resource utilization from fit summary
# ============================================================

extract_resources() {
    local fit_file="$1"
    alm_pct=$(grep "Logic utilization" "$fit_file" | grep -oP '\d+ %' | head -1)
    m10k_count=$(grep "Total RAM Blocks" "$fit_file" | grep -oP '\d+ / \d+' | head -1)
    m10k_pct=$(grep "Total RAM Blocks" "$fit_file" | grep -oP '\d+ %' | head -1)
}

# ============================================================
# Run Quartus build (map + fit + sta)
# ============================================================

run_quartus() {
    local config_name="$1"
    local seed="$2"

    # Set seed in QSF
    cd "$FPGA_DIR"
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" "$QSF"

    # Run Quartus synthesis
    echo ">>> Running quartus_map..."
    if ! quartus_map "$PROJECT" > "output_files/${config_name}_s${seed}_map.log" 2>&1; then
        echo "FAILED: quartus_map"
        return 1
    fi

    # Run Quartus fitter
    echo ">>> Running quartus_fit..."
    if ! quartus_fit "$PROJECT" > "output_files/${config_name}_s${seed}_fit.log" 2>&1; then
        echo "FAILED: quartus_fit"
        return 1
    fi

    # Run Quartus STA
    echo ">>> Running quartus_sta..."
    quartus_sta "$PROJECT" > "output_files/${config_name}_s${seed}_sta.log" 2>&1

    return 0
}

# ============================================================
# Run a single configuration build (generate + quartus)
# ============================================================

run_config() {
    local config_name="$1"
    local seed="${2:-$DEFAULT_SEED}"
    local start_time=$(date +%s)

    echo ""
    echo "========================================"
    echo "Config: $config_name  Seed: $seed  $(date '+%H:%M:%S')"
    echo "========================================"

    mkdir -p "$FPGA_DIR/output_files"

    # 1. Generate VexiiRiscv Verilog
    if ! generate_vexii "$config_name"; then
        echo "${config_name},${seed},SBT_FAIL,,,,," >> "$RESULTS_FILE"
        return 1
    fi

    # 2. Run Quartus
    if ! run_quartus "$config_name" "$seed"; then
        echo "${config_name},${seed},BUILD_FAIL,,,,," >> "$RESULTS_FILE"
        return 1
    fi

    # 3. Extract results
    local sta_file="output_files/${PROJECT}.sta.summary"
    local fit_file="output_files/${PROJECT}.fit.summary"
    extract_timing "$sta_file"
    extract_resources "$fit_file"

    # Save STA summary
    cp "$sta_file" "output_files/sta_${config_name}_s${seed}.summary"
    cp "$fit_file" "output_files/fit_${config_name}_s${seed}.summary"

    # 4. Log result
    echo "${config_name},${seed},${warm_setup},${cold_setup},${fast_setup},${alm_pct},${m10k_count},${m10k_pct}" >> "$RESULTS_FILE"

    local end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # Display result
    printf "  Slow 85C: %-8s  Slow 0C: %-8s  Fast 85C: %-8s  (%.0fs)\n" \
        "$warm_setup" "$cold_setup" "$fast_setup" "$elapsed"
    printf "  ALM: %-6s  M10K: %-10s (%s)\n" "$alm_pct" "$m10k_count" "$m10k_pct"

    # Pass/fail
    local warm_pass=$(python3 -c "print(1 if float('${warm_setup:-0}') >= 0 else 0)" 2>/dev/null)
    local cold_pass=$(python3 -c "print(1 if float('${cold_setup:-0}') >= 0 else 0)" 2>/dev/null)
    if [ "$warm_pass" = "1" ] && [ "$cold_pass" = "1" ]; then
        echo "  >>> PASSES timing"
    else
        echo "  >>> FAILS timing"
    fi
}

# ============================================================
# Build with current VexiiRiscv_Full.v (no sbt generation)
# ============================================================

run_build_only() {
    local seed="${1:-$DEFAULT_SEED}"
    local config_name="current_s${seed}"
    local start_time=$(date +%s)

    echo ""
    echo "========================================"
    echo "Build: current Verilog  Seed: $seed  $(date '+%H:%M:%S')"
    echo "========================================"

    mkdir -p "$FPGA_DIR/output_files"

    if ! run_quartus "$config_name" "$seed"; then
        echo "build,${seed},BUILD_FAIL,,,,," >> "$RESULTS_FILE"
        return 1
    fi

    local sta_file="output_files/${PROJECT}.sta.summary"
    local fit_file="output_files/${PROJECT}.fit.summary"
    extract_timing "$sta_file"
    extract_resources "$fit_file"

    cp "$sta_file" "output_files/sta_build_s${seed}.summary"

    echo "build,${seed},${warm_setup},${cold_setup},${fast_setup},${alm_pct},${m10k_count},${m10k_pct}" >> "$RESULTS_FILE"

    local end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    printf "  Slow 85C: %-8s  Slow 0C: %-8s  Fast 85C: %-8s  (%.0fs)\n" \
        "$warm_setup" "$cold_setup" "$fast_setup" "$elapsed"
    printf "  ALM: %-6s  M10K: %-10s (%s)\n" "$alm_pct" "$m10k_count" "$m10k_pct"
}

# ============================================================
# Seed sweep (fit + sta only, synthesis already done)
# ============================================================

run_seed_sweep() {
    local start="$1"
    local end="$2"
    local sweep_file="$FPGA_DIR/output_files/vexii_seed_sweep.txt"

    cd "$FPGA_DIR"

    echo "VexiiRiscv Seed Sweep ($start to $end) — $(date)" | tee "$sweep_file"
    echo "seed,warm_setup,cold_setup,fast_setup,alm,m10k,m10k_pct" | tee -a "$sweep_file"

    for seed in $(seq "$start" "$end"); do
        echo -n "Seed $seed: "
        sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" "$QSF"

        quartus_fit --read_settings_files=on --write_settings_files=off "$PROJECT" -c "$PROJECT" > "output_files/seed${seed}_fit.log" 2>&1
        quartus_sta "$PROJECT" -c "$PROJECT" > "output_files/seed${seed}_sta.log" 2>&1

        local sta_file="output_files/${PROJECT}.sta.summary"
        local fit_file="output_files/${PROJECT}.fit.summary"
        extract_timing "$sta_file"
        extract_resources "$fit_file"

        cp "$sta_file" "output_files/sta_seed${seed}.summary"

        printf "Slow85C=%-8s Slow0C=%-8s Fast85C=%-8s M10K=%s\n" \
            "$warm_setup" "$cold_setup" "$fast_setup" "$m10k_count"

        echo "${seed},${warm_setup},${cold_setup},${fast_setup},${alm_pct},${m10k_count},${m10k_pct}" >> "$sweep_file"
    done

    # Restore original seed
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $DEFAULT_SEED/" "$QSF"

    echo ""
    echo "=== SWEEP RESULTS ==="
    column -t -s, "$sweep_file"
}

# ============================================================
# Frequency adjustment
# ============================================================

set_frequency() {
    local freq_mhz="$1"

    # Calculate SDRAM phase shift: 75% of period
    local phase_ps=$(python3 -c "print(int(750000 / $freq_mhz))")
    local freq_hz=$(( freq_mhz * 1000000 ))
    local period_ns=$(python3 -c "print(round(1000 / $freq_mhz, 3))")

    # SDRAM timing calculations
    local trfc=$(python3 -c "import math; print(math.ceil(80 / (1000 / $freq_mhz)))")
    local trp=$(python3 -c "import math; print(max(2, math.ceil(15 / (1000 / $freq_mhz))))")
    local trc=$(python3 -c "import math; print(math.ceil(60 / (1000 / $freq_mhz)))")
    local trcd=$(python3 -c "import math; print(max(2, math.ceil(15 / (1000 / $freq_mhz))))")
    local tras=$(python3 -c "import math; print(math.ceil(42 / (1000 / $freq_mhz)))")

    # SRAM wait cycles: FSM adds 2 overhead cycles (setup + sample), so total = WAIT_CYCLES + 2
    # Need (WAIT_CYCLES + 2) * period >= 55ns → WAIT_CYCLES >= ceil(55/period) - 2
    local sram_wait=$(python3 -c "import math; print(max(4, math.ceil(55 / (1000 / $freq_mhz)) - 2))")

    echo "Frequency: ${freq_mhz} MHz (period: ${period_ns} ns)"
    echo ""
    echo "PLL updates:"
    echo "  outclk_0: ${freq_mhz}.000000 MHz (CPU)"
    echo "  outclk_1: ${freq_mhz}.000000 MHz, phase_shift=${phase_ps} ps (SDRAM)"
    echo ""
    echo "SDRAM timing (io_sdram.v):"
    echo "  TIMING_AUTOREFRESH (tRFC=80ns): ${trfc} cycles"
    echo "  TIMING_PRECHARGE   (tRP=15ns):  ${trp} cycles"
    echo "  TIMING_ACT_ACT     (tRC=60ns):  ${trc} cycles"
    echo "  TIMING_ACT_RW      (tRCD=15ns): ${trcd} cycles"
    echo "  TIMING_ACT_PRECHG  (tRAS=42ns): ${tras} cycles"
    echo ""
    echo "SRAM: WAIT_CYCLES=${sram_wait}"
    echo ""

    # PSRAM phase shift: 60% of period (scaled from 6000ps at 100MHz)
    local psram_phase_ps=$(python3 -c "print(int(600000 / $freq_mhz))")

    # Update PLL
    local pll_file="$FPGA_DIR/core/mf_pllram_133.v"
    sed -i "s|output_clock_frequency0(\"[^\"]*\")|output_clock_frequency0(\"${freq_mhz}.000000 MHz\")|" "$pll_file"
    sed -i "s|output_clock_frequency1(\"[^\"]*\")|output_clock_frequency1(\"${freq_mhz}.000000 MHz\")|" "$pll_file"
    sed -i "s|output_clock_frequency2(\"[^\"]*\")|output_clock_frequency2(\"${freq_mhz}.000000 MHz\")|" "$pll_file"
    sed -i "s|phase_shift1(\"[0-9]* ps\")|phase_shift1(\"${phase_ps} ps\")|" "$pll_file"
    sed -i "s|phase_shift2(\"[0-9]* ps\")|phase_shift2(\"${psram_phase_ps} ps\")|" "$pll_file"

    # Update core_top.v
    local core_file="$FPGA_DIR/core/core_top.v"
    sed -i "s|\.CLOCK_SPEED([0-9.]*)|.CLOCK_SPEED(${freq_mhz}.0)|" "$core_file"
    sed -i "s|\.CLK_HZ([0-9]*)|.CLK_HZ(${freq_hz})|" "$core_file"

    # Update io_sdram.v timing parameters
    local sdram_file="$FPGA_DIR/core/io_sdram.v"
    sed -i "s|TIMING_AUTOREFRESH  =   4'd[0-9]*;|TIMING_AUTOREFRESH  =   4'd${trfc};|" "$sdram_file"
    sed -i "s|TIMING_PRECHARGE    =   4'd[0-9]*;|TIMING_PRECHARGE    =   4'd${trp};|" "$sdram_file"
    sed -i "s|TIMING_ACT_ACT      =   4'd[0-9]*;|TIMING_ACT_ACT      =   4'd${trc};|" "$sdram_file"
    sed -i "s|TIMING_ACT_RW       =   4'd[0-9]*;|TIMING_ACT_RW       =   4'd${trcd};|" "$sdram_file"
    sed -i "s|TIMING_ACT_PRECHG   =   4'd[0-9]*;|TIMING_ACT_PRECHG   =   4'd${tras};|" "$sdram_file"

    # Update sram_controller.v WAIT_CYCLES (default parameter)
    local sram_file="$FPGA_DIR/core/sram_controller.v"
    sed -i "s|parameter WAIT_CYCLES = [0-9]*|parameter WAIT_CYCLES = ${sram_wait}|" "$sram_file"

    # Update core_top.v WAIT_CYCLES (instance override)
    sed -i "s|\.WAIT_CYCLES([0-9]*)|.WAIT_CYCLES(${sram_wait})|" "$core_file"

    echo "All files updated for ${freq_mhz} MHz."
    echo "Run './vexii_sweep.sh build [seed]' to build."
}

# Restore to 100 MHz
restore_100mhz() {
    set_frequency 100
    # Fix the comment that gets mangled
    local sdram_file="$FPGA_DIR/core/io_sdram.v"
    sed -i 's|// timings are for [0-9]*MHz|// timings are for 100MHz|' "$sdram_file"
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<'EOF'
VexiiRiscv Overclocking Sweep

Usage: ./vexii_sweep.sh <command> [args...]

Commands:
  phase1                Run all Phase 1 configs (sbt + quartus, ~15min each)
  run <config> [seed]   Run a single config (sbt + quartus)
  gen <config>          Generate Verilog only (sbt, no quartus)
  build [seed]          Build current VexiiRiscv_Full.v (no sbt)
  seeds <start> <end>   Seed sweep (fit+sta only, ~8min/seed)
  freq <mhz>           Set PLL frequency + update all timings
  restore              Restore to 100 MHz
  list                 List available configs
  summary              Show results CSV

Phase 1 configs:
  baseline           Current config (btb=512, gshare=4K, ras)
  btb256             BTB 256 sets (free ~4 M10K)
  btb128             BTB 128 sets (free ~6 M10K)
  gshare2k           GShare 2KB (free ~2 M10K)
  gshare1k           GShare 1KB (free ~3 M10K)
  noRas              Remove RAS
  relaxedBranch      Add --relaxed-branch
  relaxedDiv         Add --relaxed-div
  relaxedMulInputs   Add --relaxed-mul-inputs
  btb256_gsh2k       BTB 256 + GShare 2K combined
  btb256_gsh2k_rlxBr Above + relaxed-branch
EOF
}

cd "$FPGA_DIR"

case "${1:-help}" in
    phase1)
        echo "config,seed,warm_setup,cold_setup,fast_setup,alm,m10k,m10k_pct" > "$RESULTS_FILE"
        echo ""
        echo "VexiiRiscv Phase 1 Sweep — $(date)"
        echo "============================================"
        n=0
        total=$(echo $PHASE1_CONFIGS | wc -w)
        for cfg in $PHASE1_CONFIGS; do
            n=$((n + 1))
            echo ""
            echo "[$n / $total] $cfg"
            run_config "$cfg" "$DEFAULT_SEED" || true
        done
        echo ""
        echo "============================================"
        echo "Phase 1 complete. Results:"
        echo ""
        column -t -s, "$RESULTS_FILE"
        ;;

    fullsweep)
        echo "config,seed,warm_setup,cold_setup,fast_setup,alm,m10k,m10k_pct" > "$RESULTS_FILE"
        echo ""
        echo "VexiiRiscv Full Sweep — $(date)"
        echo "============================================"
        echo "Phase A: Build all configs at 105 MHz, seed 13"
        echo ""
        n=0
        total=$(echo $FULLSWEEP_CONFIGS | wc -w)
        for cfg in $FULLSWEEP_CONFIGS; do
            n=$((n + 1))
            echo ""
            echo "[$n / $total] $cfg"
            run_config "$cfg" "$DEFAULT_SEED" || true
        done

        echo ""
        echo "============================================"
        echo "Phase A complete. Results:"
        echo ""
        column -t -s, "$RESULTS_FILE"

        # Phase B: Find best config and do seed sweep
        echo ""
        echo "============================================"
        echo "Phase B: Seed sweep on best config"
        echo ""

        # Find best config (most positive warm_setup)
        local best_cfg=$(tail -n +2 "$RESULTS_FILE" | sort -t, -k3 -rn | head -1)
        local best_name=$(echo "$best_cfg" | cut -d, -f1)
        local best_slack=$(echo "$best_cfg" | cut -d, -f3)

        echo "Best config: $best_name (slack: $best_slack)"

        # Regenerate best config for seed sweep
        if ! generate_vexii "$best_name"; then
            echo "FAILED to regenerate best config"
            exit 1
        fi

        # Full synthesis first (needed for fit-only seed sweep)
        echo ">>> Running quartus_map for seed sweep base..."
        cd "$FPGA_DIR"
        quartus_map "$PROJECT" > "output_files/seedsweep_map.log" 2>&1

        echo ">>> Running seed sweep (1-30)..."
        run_seed_sweep 1 30

        echo ""
        echo "============================================"
        echo "Full Sweep complete!"
        echo ""
        echo "Phase A results:"
        column -t -s, "$RESULTS_FILE"
        echo ""
        echo "Phase B seed sweep:"
        column -t -s, "$FPGA_DIR/output_files/vexii_seed_sweep.txt"
        ;;

    run)
        config_name="${2:?ERROR: Missing config name. Use '$0 list' to see options.}"
        seed="${3:-$DEFAULT_SEED}"
        if [ ! -f "$RESULTS_FILE" ]; then
            echo "config,seed,warm_setup,cold_setup,fast_setup,alm,m10k,m10k_pct" > "$RESULTS_FILE"
        fi
        run_config "$config_name" "$seed"
        ;;

    gen)
        config_name="${2:?ERROR: Missing config name.}"
        mkdir -p "$FPGA_DIR/output_files"
        generate_vexii "$config_name"
        ;;

    build)
        seed="${2:-$DEFAULT_SEED}"
        if [ ! -f "$RESULTS_FILE" ]; then
            echo "config,seed,warm_setup,cold_setup,fast_setup,alm,m10k,m10k_pct" > "$RESULTS_FILE"
        fi
        run_build_only "$seed"
        ;;

    seeds)
        start="${2:-1}"
        end="${3:-30}"
        run_seed_sweep "$start" "$end"
        ;;

    freq)
        freq_mhz="${2:?ERROR: Missing frequency in MHz. Example: $0 freq 105}"
        set_frequency "$freq_mhz"
        ;;

    restore)
        restore_100mhz
        ;;

    list)
        echo "Phase 1 configs:"
        echo ""
        printf "  %-25s %s\n" "baseline"           "Current config (btb=512, gshare=4K, ras)"
        printf "  %-25s %s\n" "btb256"             "BTB 256 sets (free ~4 M10K)"
        printf "  %-25s %s\n" "btb128"             "BTB 128 sets (free ~6 M10K)"
        printf "  %-25s %s\n" "gshare2k"           "GShare 2KB (free ~2 M10K)"
        printf "  %-25s %s\n" "gshare1k"           "GShare 1KB (free ~3 M10K)"
        printf "  %-25s %s\n" "noRas"              "Remove RAS"
        printf "  %-25s %s\n" "relaxedBranch"      "Add --relaxed-branch"
        printf "  %-25s %s\n" "relaxedDiv"         "Add --relaxed-div"
        printf "  %-25s %s\n" "relaxedMulInputs"   "Add --relaxed-mul-inputs"
        printf "  %-25s %s\n" "btb256_gsh2k"       "BTB 256 + GShare 2K combined"
        printf "  %-25s %s\n" "btb256_gsh2k_rlxBr" "BTB 256 + GShare 2K + relaxed-branch"
        ;;

    summary)
        if [ -f "$RESULTS_FILE" ]; then
            column -t -s, "$RESULTS_FILE"
        else
            echo "No results yet. Run 'phase1' or 'run' first."
        fi
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        echo "Unknown command: $1"
        usage
        exit 1
        ;;
esac
