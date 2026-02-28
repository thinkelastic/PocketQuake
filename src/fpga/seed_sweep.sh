#!/bin/bash
# Seed sweep script for timing closure
# Runs Quartus fitter + STA for each seed, reports worst slack

SEEDS="1 2 5 7 10 15 20 25 30"
PROJECT="ap_core"
RESULTS_FILE="/tmp/seed_sweep_results.txt"

echo "Seed sweep starting at $(date)" > "$RESULTS_FILE"
echo "---" >> "$RESULTS_FILE"

for SEED in $SEEDS; do
    echo "=== Seed $SEED ===" | tee -a "$RESULTS_FILE"

    # Update seed in QSF
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $SEED/" ap_core.qsf

    # Run fitter only (synthesis already done)
    quartus_fit --read_settings_files=on --write_settings_files=off $PROJECT -c $PROJECT 2>&1 | tail -3

    # Run STA
    quartus_sta $PROJECT -c $PROJECT 2>&1 | tail -3

    # Extract worst slack for RAM clock (setup)
    SLACK_85C=$(grep -A1 "Slow 1100mV 85C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')
    SLACK_0C=$(grep -A1 "Slow 1100mV 0C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')
    SLACK_FAST=$(grep -A1 "Fast 1100mV 85C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')

    echo "  Slow 85C: $SLACK_85C  Slow 0C: $SLACK_0C  Fast 85C: $SLACK_FAST" | tee -a "$RESULTS_FILE"
done

# Restore seed 3
sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED 3/" ap_core.qsf

echo "---" >> "$RESULTS_FILE"
echo "Sweep complete at $(date)" >> "$RESULTS_FILE"
echo ""
echo "=== SUMMARY ==="
cat "$RESULTS_FILE"
