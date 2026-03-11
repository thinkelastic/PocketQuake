#
# user core constraints
#
# put your clock groups in here as well as any net assignments
#

set_clock_groups -asynchronous \
 -group { bridge_spiclk } \
 -group { clk_74a } \
 -group { clk_74b } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp1|mf_pllbase_inst|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp_ram|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk \
          ic|mp_ram|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk } \
 -group { ic|mp_ram|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk }

# ============================================
# CRAM0 sync burst timing constraints
# ============================================
# Generated clock on CRAM0 CLK pin (PLL outclk_2, 105 MHz, 5714ps phase shift)
create_generated_clock -name cram0_clk_out \
    -source [get_pins {ic|mp_ram|altera_pll_i|general[2].gpll~PLL_OUTPUT_COUNTER|divclk}] \
    [get_ports {cram0_clk}]

# CRAM0 output delay: tCO from FPGA IOB register to CRAM setup time
# AS1C8M16PL-70BIN: tSU=2ns (address/data setup before CLK rising edge)
# Output delay = max board trace + tSU = ~1ns + 2ns = 3ns
set_output_delay -clock cram0_clk_out -max 3.0 -add_delay [get_ports {cram0_a[*] cram0_dq[*] cram0_adv_n cram0_cre cram0_ce0_n cram0_ce1_n cram0_oe_n cram0_we_n cram0_ub_n cram0_lb_n}]
set_output_delay -clock cram0_clk_out -min -0.5 -add_delay [get_ports {cram0_a[*] cram0_dq[*] cram0_adv_n cram0_cre cram0_ce0_n cram0_ce1_n cram0_oe_n cram0_we_n cram0_ub_n cram0_lb_n}]

# CRAM0 input delay: tCO from CRAM CLK edge to valid data on DQ
# AS1C8M16PL-70BIN: tCKD=5.5ns max (data valid after CLK edge)
# Input delay = max board trace + tCKD = ~1ns + 5.5ns = 6.5ns
set_input_delay -clock cram0_clk_out -max 6.5 -add_delay [get_ports {cram0_dq[*] cram0_wait}]
set_input_delay -clock cram0_clk_out -min 1.0 -add_delay [get_ports {cram0_dq[*] cram0_wait}]

# Multicycle path for posedge IOB capture registers (cram_dq_r, cram_wait_r).
# With φ=7619ps phase shift + 6.5ns tCKD, the round-trip from cram0_clk pad to
# data at IOB register spans multiple outclk_0 cycles.
# Multicycle=3 gives comfortable slack.  SYNC_LATENCY=5 matches the pipeline.
set_multicycle_path -setup 3 \
    -from [get_clocks cram0_clk_out] \
    -to [get_registers {ic|psram0|psram_inst|cram_dq_r[*] ic|psram0|psram_inst|cram_wait_r}]
set_multicycle_path -hold 2 \
    -from [get_clocks cram0_clk_out] \
    -to [get_registers {ic|psram0|psram_inst|cram_dq_r[*] ic|psram0|psram_inst|cram_wait_r}]
