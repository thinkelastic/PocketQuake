#!/bin/bash
# Fitter seed sweep - tries multiple seeds and reports timing for each
# Synthesis runs once; only fit+STA are repeated per seed.
# Usage: ./seed_sweep.sh [start_seed] [end_seed]
# Default: seeds 1 through 10

QUARTUS_DIR=/home/alberto/altera_lite/25.1std/quartus/bin
export PATH="$QUARTUS_DIR:$PATH"

START=${1:-1}
END=${2:-10}
PROJECT=ap_core
QSF="${PROJECT}.qsf"
RESULTS_FILE="seed_sweep_results.txt"

echo "Seed sweep: $START to $END" | tee "$RESULTS_FILE"
echo "========================================" | tee -a "$RESULTS_FILE"

# Run synthesis once (seed-independent)
echo ">>> Running synthesis (quartus_map)..."
quartus_map "$PROJECT" > "output_files/seed_map.log" 2>&1
map_status=$?
if [ $map_status -ne 0 ]; then
    echo "SYNTHESIS FAILED (exit code $map_status)" | tee -a "$RESULTS_FILE"
    exit 1
fi
echo "Synthesis complete."
echo ""

printf "%-6s  %-12s %-12s %-12s %-12s\n" "Seed" "Warm Setup" "Cold Setup" "Warm Hold" "Cold Hold" | tee -a "$RESULTS_FILE"
printf "%-6s  %-12s %-12s %-12s %-12s\n" "----" "----------" "----------" "---------" "---------" | tee -a "$RESULTS_FILE"

for seed in $(seq $START $END); do
    # Update seed in QSF
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $seed/" "$QSF"

    # Run fit + STA only
    quartus_fit "$PROJECT" > "output_files/seed_${seed}_fit.log" 2>&1
    fit_status=$?
    if [ $fit_status -ne 0 ]; then
        printf "%-6d  FAILED\n" "$seed" | tee -a "$RESULTS_FILE"
        continue
    fi

    quartus_sta "$PROJECT" > "output_files/seed_${seed}_sta.log" 2>&1

    # Extract slack from all 4 corners (first match = main PLL clock)
    STA="output_files/${PROJECT}.sta.summary"
    warm_setup=$(grep -A1 "Slow 1100mV 85C Model Setup" "$STA" | grep "Slack" | head -1 | awk '{print $NF}')
    cold_setup=$(grep -A1 "Slow 1100mV 0C Model Setup" "$STA" | grep "Slack" | head -1 | awk '{print $NF}')
    warm_hold=$(grep -A1 "Fast 1100mV 85C Model Hold" "$STA" | grep "Slack" | head -1 | awk '{print $NF}')
    cold_hold=$(grep -A1 "Fast 1100mV 0C Model Hold" "$STA" | grep "Slack" | head -1 | awk '{print $NF}')

    printf "%-6d  %-12s %-12s %-12s %-12s\n" "$seed" "$warm_setup" "$cold_setup" "$warm_hold" "$cold_hold" | tee -a "$RESULTS_FILE"

    # Save STA summary for this seed
    cp "$STA" "output_files/sta_seed_${seed}.summary"

    # If both setup corners pass, save the SOF
    warm_pass=$(python3 -c "print(1 if float('${warm_setup:-0}') >= 0 else 0)" 2>/dev/null)
    cold_pass=$(python3 -c "print(1 if float('${cold_setup:-0}') >= 0 else 0)" 2>/dev/null)
    if [ "$warm_pass" = "1" ] && [ "$cold_pass" = "1" ]; then
        cp "output_files/${PROJECT}.sof" "output_files/${PROJECT}_seed${seed}.sof"
        quartus_asm "$PROJECT" > /dev/null 2>&1
        echo "  ^ PASSES — SOF saved" | tee -a "$RESULTS_FILE"
    fi
done

echo ""
echo "========================================" | tee -a "$RESULTS_FILE"
echo "Sweep complete. Results in $RESULTS_FILE" | tee -a "$RESULTS_FILE"
