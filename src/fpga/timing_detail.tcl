project_open ap_core
create_timing_netlist
read_sdc
update_timing_netlist
report_timing -setup -npaths 3 -detail full_path -from_clock {ic|mp_ram|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk} -to_clock {ic|mp_ram|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}
project_close
