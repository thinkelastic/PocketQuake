#!/bin/bash
# Seed sweep: surfcache fence.i removal + perf optimizations
SEEDS="1 2 3 4 5 6 7 8 9 10 11 12 13 14 15"
PROJECT="ap_core"
RESULTS_FILE="/tmp/seed_sweep_results4.txt"

echo "Seed sweep (surfcache fence.i removal) starting at $(date)" > "$RESULTS_FILE"
echo "---" >> "$RESULTS_FILE"

for SEED in $SEEDS; do
    echo "=== Seed $SEED ===" | tee -a "$RESULTS_FILE"
    sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED $SEED/" ap_core.qsf
    quartus_fit --read_settings_files=on --write_settings_files=off $PROJECT -c $PROJECT 2>&1 | tail -1
    quartus_sta $PROJECT -c $PROJECT 2>&1 | tail -1

    SLACK_85C=$(grep -A1 "Slow 1100mV 85C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')
    SLACK_0C=$(grep -A1 "Slow 1100mV 0C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')
    SLACK_FAST=$(grep -A1 "Fast 1100mV 85C Model Setup.*mp_ram" output_files/ap_core.sta.summary | grep "Slack" | awk '{print $3}')

    echo "  Slow 85C: $SLACK_85C  Slow 0C: $SLACK_0C  Fast 85C: $SLACK_FAST" | tee -a "$RESULTS_FILE"
done

# Restore seed 13
sed -i "s/^set_global_assignment -name SEED .*/set_global_assignment -name SEED 13/" ap_core.qsf
echo "---" >> "$RESULTS_FILE"
echo "Sweep complete at $(date)" >> "$RESULTS_FILE"
cat "$RESULTS_FILE"
