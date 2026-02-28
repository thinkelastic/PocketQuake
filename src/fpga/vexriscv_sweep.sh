#!/bin/bash
# VexRiscv configuration sweep for Fmax optimization
#
# Iterates over VexRiscv plugin configurations, regenerates Verilog via sbt,
# runs Quartus synthesis+fit+STA, and logs timing results.
#
# Usage:
#   ./vexriscv_sweep.sh phase1                          Run all Phase 1 configs
#   ./vexriscv_sweep.sh run <config> [seed]             Run a single config
#   ./vexriscv_sweep.sh combined <name> <cfg1> <cfg2>.. Combine multiple configs
#   ./vexriscv_sweep.sh freq <mhz>                      Set PLL frequency
#   ./vexriscv_sweep.sh seeds <start> <end>             Seed sweep (current Verilog)
#   ./vexriscv_sweep.sh list                            List available configs
#
# Prerequisites: java, sbt, Quartus tools in PATH

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
FPGA_DIR="$SCRIPT_DIR"
VEXRISCV_DIR="$SCRIPT_DIR/vexriscv"
TEMPLATE="$VEXRISCV_DIR/GenPocketQuake_template.scala"
CONFIGS_DIR="$VEXRISCV_DIR/configs"
RESULTS_FILE="$FPGA_DIR/vexriscv_sweep_results.csv"

QUARTUS_DIR=/home/alberto/altera_lite/25.1std/quartus/bin
export PATH="$QUARTUS_DIR:$PATH"

PROJECT=ap_core
QSF="${PROJECT}.qsf"
DEFAULT_SEED=15

# ============================================================
# Configuration definitions
# ============================================================

# Reset all config variables to baseline values
reset_config() {
    PREDICTION="STATIC"
    DCACHE_SIZE="65536"
    DCACHE_WAYS="2"
    EARLY_DATA_MUX="false"
    DBUS_SLAVE_PIPE="false"
    SEP_ADDSUB="false"
    MUL_LINE="new MulPlugin"
    CSR_LINE='new CsrPlugin(CsrPluginConfig.small(mtvecInit = 0x80000020l))'
    FPU_PARAMS="withDouble = false"
}

# Phase 1: single-parameter configs (one change from baseline each)
PHASE1_CONFIGS="baseline csrPipeRead noCsrAlu csrBoth dcache1way earlyDataMux mulBuf mulBufBoth fpuPipe predNone sepAddSub dbusSlave"

config_baseline()     { : ; }

config_csrPipeRead()  {
    CSR_LINE='new CsrPlugin(CsrPluginConfig.small(mtvecInit = 0x80000020l).copy(pipelineCsrRead = true))'
}

config_noCsrAlu()     {
    CSR_LINE='new CsrPlugin(CsrPluginConfig.small(mtvecInit = 0x80000020l).copy(noCsrAlu = true))'
}

config_csrBoth()      {
    CSR_LINE='new CsrPlugin(CsrPluginConfig.small(mtvecInit = 0x80000020l).copy(pipelineCsrRead = true, noCsrAlu = true))'
}

config_dcache1way()   { DCACHE_WAYS="1"; }

config_earlyDataMux() { EARLY_DATA_MUX="true"; }

config_mulBuf()       { MUL_LINE="new MulPlugin(inputBuffer = true)"; }

config_mulBufBoth()   { MUL_LINE="new MulPlugin(inputBuffer = true, outputBuffer = true)"; }

config_fpuPipe()      { FPU_PARAMS="withDouble = false, schedulerM2sPipe = true"; }

config_predNone()     { PREDICTION="NONE"; }

config_sepAddSub()    { SEP_ADDSUB="true"; }

config_dbusSlave()    { DBUS_SLAVE_PIPE="true"; }

# ============================================================
# Scala generation from template
# ============================================================

generate_scala() {
    local output_file="$1"

    sed -e "s|@@PREDICTION@@|$PREDICTION|g" \
        -e "s|@@DCACHE_SIZE@@|$DCACHE_SIZE|g" \
        -e "s|@@DCACHE_WAYS@@|$DCACHE_WAYS|g" \
        -e "s|@@EARLY_DATA_MUX@@|$EARLY_DATA_MUX|g" \
        -e "s|@@DBUS_SLAVE_PIPE@@|$DBUS_SLAVE_PIPE|g" \
        -e "s|@@SEP_ADDSUB@@|$SEP_ADDSUB|g" \
        -e "s|@@MUL_LINE@@|$MUL_LINE|g" \
        -e "s|@@CSR_LINE@@|$CSR_LINE|g" \
        -e "s|@@FPU_PARAMS@@|$FPU_PARAMS|g" \
        "$TEMPLATE" > "$output_file"
}

# ============================================================
# VexRiscv Verilog generation via sbt
# ============================================================

generate_verilog() {
    local config_name="$1"
    local scala_file="$2"
    local log_file="$FPGA_DIR/output_files/vex_${config_name}.log"

    # Ensure VexRiscv is cloned
    if [ ! -d "$VEXRISCV_DIR/VexRiscv" ]; then
        echo "Cloning VexRiscv..."
        git clone https://github.com/SpinalHDL/VexRiscv.git "$VEXRISCV_DIR/VexRiscv"
    fi

    # Copy config into VexRiscv project
    cp "$scala_file" "$VEXRISCV_DIR/VexRiscv/src/main/scala/vexriscv/demo/GenPocketQuake.scala"

    # Generate Verilog
    local orig_dir="$PWD"
    cd "$VEXRISCV_DIR/VexRiscv"
    if ! sbt "runMain vexriscv.demo.GenPocketQuake" > "$log_file" 2>&1; then
        cd "$orig_dir"
        echo "FAILED: sbt generation (see output_files/vex_${config_name}.log)"
        return 1
    fi
    cd "$orig_dir"

    # Copy generated Verilog
    cp "$VEXRISCV_DIR/VexRiscv/VexRiscv.v" "$VEXRISCV_DIR/VexRiscv_Full.v"
    return 0
}

# ============================================================
# Extract timing from STA summary
# ============================================================

extract_timing() {
    local sta_file="$1"
    warm_setup=$(grep -A1 "Slow 1100mV 85C Model Setup" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
    cold_setup=$(grep -A1 "Slow 1100mV 0C Model Setup" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
    warm_hold=$(grep -A1 "Fast 1100mV 85C Model Hold" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
    cold_hold=$(grep -A1 "Fast 1100mV 0C Model Hold" "$sta_file" | grep "Slack" | head -1 | awk '{print $NF}')
}

# ============================================================
# Run a single configuration build
# ============================================================

run_build() {
    local config_name="$1"
    local seed="${2:-$DEFAULT_SEED}"
    local start_time=$(date +%s)

    echo ""
    echo "========================================"
    echo "Config: $config_name  Seed: $seed  $(date '+%H:%M:%S')"
    echo "========================================"

    # Ensure output directory exists
    mkdir -p "$FPGA_DIR/output_files"

    # 1. Generate Scala variant from template
    reset_config
    if declare -f "config_${config_name}" > /dev/null 2>&1; then
        "config_${config_name}"
    else
        echo "ERROR: Unknown config '$config_name'"
        return 1
    fi

    mkdir -p "$CONFIGS_DIR"
    local scala_file="$CONFIGS_DIR/${config_name}.scala"
    generate_scala "$scala_file"

    # 2. Generate VexRiscv Verilog
    echo ">>> Generating VexRiscv Verilog..."
    if ! generate_verilog "$config_name" "$scala_file"; then
        echo "${config_name},${seed},SBT_FAIL,,,," >> "$RESULTS_FILE"
        return 1
    fi
    echo "    Verilog generated OK"

    # 3. Set seed in QSF
    cd "$FPGA_DIR"
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" "$QSF"

    # 4. Run Quartus synthesis
    echo ">>> Running quartus_map..."
    if ! quartus_map "$PROJECT" > "output_files/${config_name}_s${seed}_map.log" 2>&1; then
        echo "FAILED: quartus_map (see output_files/${config_name}_s${seed}_map.log)"
        echo "${config_name},${seed},MAP_FAIL,,,," >> "$RESULTS_FILE"
        return 1
    fi

    # 5. Run Quartus fitter
    echo ">>> Running quartus_fit..."
    if ! quartus_fit "$PROJECT" > "output_files/${config_name}_s${seed}_fit.log" 2>&1; then
        echo "FAILED: quartus_fit (see output_files/${config_name}_s${seed}_fit.log)"
        echo "${config_name},${seed},FIT_FAIL,,,," >> "$RESULTS_FILE"
        return 1
    fi

    # 6. Run Quartus STA
    echo ">>> Running quartus_sta..."
    quartus_sta "$PROJECT" > "output_files/${config_name}_s${seed}_sta.log" 2>&1

    # 7. Extract timing
    local sta_file="output_files/${PROJECT}.sta.summary"
    extract_timing "$sta_file"

    # Save STA summary
    cp "$sta_file" "output_files/sta_${config_name}_s${seed}.summary"

    # 8. Log result
    echo "${config_name},${seed},${warm_setup},${cold_setup},${warm_hold},${cold_hold}" >> "$RESULTS_FILE"

    local end_time=$(date +%s)
    local elapsed=$(( end_time - start_time ))

    # Display result
    printf "  Warm Setup: %-8s  Cold Setup: %-8s  (%.0fs)\n" \
        "$warm_setup" "$cold_setup" "$elapsed"
    printf "  Warm Hold:  %-8s  Cold Hold:  %-8s\n" \
        "$warm_hold" "$cold_hold"

    # Pass/fail check
    local warm_pass=$(python3 -c "print(1 if float('${warm_setup:-0}') >= 0 else 0)" 2>/dev/null)
    local cold_pass=$(python3 -c "print(1 if float('${cold_setup:-0}') >= 0 else 0)" 2>/dev/null)
    if [ "$warm_pass" = "1" ] && [ "$cold_pass" = "1" ]; then
        echo "  >>> PASSES"
    else
        echo "  >>> FAILS"
    fi
}

# ============================================================
# Frequency adjustment (Phase 3)
# ============================================================

set_frequency() {
    local freq_mhz="$1"

    # Calculate SDRAM phase shift: 75% of period
    local phase_ps=$(python3 -c "print(int(750000 / $freq_mhz))")
    local freq_hz=$(( freq_mhz * 1000000 ))
    local period_ns=$(python3 -c "print(round(1000 / $freq_mhz, 1))")

    # Update PLL
    local pll_file="$FPGA_DIR/core/mf_pllram_133.v"
    sed -i "s|output_clock_frequency0(\"[^\"]*\")|output_clock_frequency0(\"${freq_mhz}.000000 MHz\")|" "$pll_file"
    sed -i "s|output_clock_frequency1(\"[^\"]*\")|output_clock_frequency1(\"${freq_mhz}.000000 MHz\")|" "$pll_file"
    # Only update phase_shift1 (SDRAM clock), leave phase_shift0 at 0
    sed -i "s|phase_shift1(\"[0-9]* ps\")|phase_shift1(\"${phase_ps} ps\")|" "$pll_file"

    # Update core_top.v
    local core_file="$FPGA_DIR/core/core_top.v"
    sed -i "s|\.CLOCK_SPEED([0-9.]*)|.CLOCK_SPEED(${freq_mhz}.0)|" "$core_file"
    sed -i "s|\.CLK_HZ([0-9]*)|.CLK_HZ(${freq_hz})|" "$core_file"

    # Calculate SDRAM tRAS
    local tras_cycles=$(python3 -c "import math; print(math.ceil(42 / (1000 / $freq_mhz)))")

    echo "Frequency set to ${freq_mhz} MHz:"
    echo "  PLL outclk_0: ${freq_mhz}.000000 MHz (CPU)"
    echo "  PLL outclk_1: ${freq_mhz}.000000 MHz, phase_shift=${phase_ps} ps (SDRAM)"
    echo "  CLOCK_SPEED: ${freq_mhz}.0"
    echo "  CLK_HZ: ${freq_hz}"
    echo "  Period: ${period_ns} ns"
    echo "  tRAS (42ns): ${tras_cycles} cycles — check io_sdram.v if changed!"
}

# ============================================================
# Main
# ============================================================

usage() {
    cat <<EOF
VexRiscv Fmax Optimization Sweep

Usage: $0 <command> [args...]

Commands:
  phase1                          Run all Phase 1 single-parameter configs
  run <config> [seed]             Run a single named config (default seed: $DEFAULT_SEED)
  combined <name> <cfg1> <cfg2>.. Combine configs and run under <name>
  freq <mhz>                      Set PLL/core_top frequency (no build)
  seeds <start> <end>             Seed sweep with current VexRiscv_Full.v
  list                            List available config names

Phase 1 configs:
  $PHASE1_CONFIGS

Examples:
  $0 phase1                       # Full Phase 1 sweep
  $0 run csrBoth                  # Test a single config
  $0 run baseline 7               # Test baseline with seed 7
  $0 combined top3 csrBoth earlyDataMux fpuPipe   # Combine winners
  $0 freq 105                     # Set 105 MHz, then 'run baseline' to build
  $0 seeds 1 20                   # Seed sweep at current frequency
EOF
}

cd "$FPGA_DIR"

case "${1:-help}" in
    phase1)
        echo "config,seed,warm_setup,cold_setup,warm_hold,cold_hold" > "$RESULTS_FILE"
        echo ""
        echo "VexRiscv Phase 1 Sweep — $(date)"
        echo "============================================"
        total=${#PHASE1_CONFIGS}
        n=0
        for cfg in $PHASE1_CONFIGS; do
            n=$((n + 1))
            echo ""
            echo "[$n / $(echo $PHASE1_CONFIGS | wc -w)] $cfg"
            run_build "$cfg" "$DEFAULT_SEED" || true
        done
        echo ""
        echo "============================================"
        echo "Phase 1 complete. Results:"
        echo ""
        column -t -s, "$RESULTS_FILE"
        echo ""
        echo "Full CSV: $RESULTS_FILE"
        ;;

    run)
        config_name="${2:?ERROR: Missing config name. Use '$0 list' to see options.}"
        seed="${3:-$DEFAULT_SEED}"
        if [ ! -f "$RESULTS_FILE" ]; then
            echo "config,seed,warm_setup,cold_setup,warm_hold,cold_hold" > "$RESULTS_FILE"
        fi
        run_build "$config_name" "$seed"
        ;;

    combined)
        shift
        if [ $# -lt 3 ]; then
            echo "Usage: $0 combined <result_name> <config1> <config2> [config3...]"
            echo "Example: $0 combined top3 csrBoth earlyDataMux fpuPipe"
            exit 1
        fi
        combined_name="$1"
        shift

        # Create a combined config function dynamically
        reset_config
        echo "Combining configs: $@"
        for cfg in "$@"; do
            if ! declare -f "config_${cfg}" > /dev/null 2>&1; then
                echo "ERROR: Unknown config '$cfg'"
                exit 1
            fi
            "config_${cfg}"
            echo "  + $cfg"
        done

        # Save the combined state — define a temporary config function
        local_PREDICTION="$PREDICTION"
        local_DCACHE_SIZE="$DCACHE_SIZE"
        local_DCACHE_WAYS="$DCACHE_WAYS"
        local_EARLY_DATA_MUX="$EARLY_DATA_MUX"
        local_DBUS_SLAVE_PIPE="$DBUS_SLAVE_PIPE"
        local_SEP_ADDSUB="$SEP_ADDSUB"
        local_MUL_LINE="$MUL_LINE"
        local_CSR_LINE="$CSR_LINE"
        local_FPU_PARAMS="$FPU_PARAMS"

        eval "config_${combined_name}() {
            PREDICTION='$local_PREDICTION'
            DCACHE_SIZE='$local_DCACHE_SIZE'
            DCACHE_WAYS='$local_DCACHE_WAYS'
            EARLY_DATA_MUX='$local_EARLY_DATA_MUX'
            DBUS_SLAVE_PIPE='$local_DBUS_SLAVE_PIPE'
            SEP_ADDSUB='$local_SEP_ADDSUB'
            MUL_LINE='$local_MUL_LINE'
            CSR_LINE='$local_CSR_LINE'
            FPU_PARAMS='$local_FPU_PARAMS'
        }"

        if [ ! -f "$RESULTS_FILE" ]; then
            echo "config,seed,warm_setup,cold_setup,warm_hold,cold_hold" > "$RESULTS_FILE"
        fi
        run_build "$combined_name" "$DEFAULT_SEED"
        ;;

    freq)
        freq_mhz="${2:?ERROR: Missing frequency in MHz. Example: $0 freq 105}"
        set_frequency "$freq_mhz"
        echo ""
        echo "Run '$0 run <config>' to build at ${freq_mhz} MHz."
        ;;

    seeds)
        start="${2:-1}"
        end="${3:-20}"
        echo "Delegating to seed_sweep.sh ($start to $end)..."
        exec "$FPGA_DIR/seed_sweep.sh" "$start" "$end"
        ;;

    list)
        echo "Phase 1 configs (single-parameter changes from baseline):"
        echo ""
        printf "  %-15s %s\n" "baseline"     "(reference — no changes)"
        printf "  %-15s %s\n" "csrPipeRead"  "CsrPlugin pipelineCsrRead = true"
        printf "  %-15s %s\n" "noCsrAlu"     "CsrPlugin noCsrAlu = true"
        printf "  %-15s %s\n" "csrBoth"      "CsrPlugin pipelineCsrRead + noCsrAlu"
        printf "  %-15s %s\n" "dcache1way"   "D-cache wayCount = 1 (direct-mapped)"
        printf "  %-15s %s\n" "earlyDataMux" "D-cache earlyDataMux = true"
        printf "  %-15s %s\n" "mulBuf"       "MulPlugin inputBuffer = true"
        printf "  %-15s %s\n" "mulBufBoth"   "MulPlugin inputBuffer + outputBuffer"
        printf "  %-15s %s\n" "fpuPipe"      "FpuParameter schedulerM2sPipe = true"
        printf "  %-15s %s\n" "predNone"     "IBus prediction = NONE"
        printf "  %-15s %s\n" "sepAddSub"    "SrcPlugin separatedAddSub = true"
        printf "  %-15s %s\n" "dbusSlave"    "DBusCachedPlugin dBusCmdSlavePipe = true"
        echo ""
        echo "Use 'combined' to stack multiple configs for Phase 2."
        ;;

    help|--help|-h)
        usage
        ;;

    *)
        echo "Unknown command: $1"
        echo ""
        usage
        exit 1
        ;;
esac
