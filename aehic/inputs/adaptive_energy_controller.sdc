# =====================================================================
# SDC Constraints - Adaptive Energy Harvesting IoT Controller (AEHIC)
# Target: IHP SG13G2 (130nm), OpenROAD flow
# Target Frequency: 100 MHz (10.0 ns period)
# =====================================================================

# -----------------------------------------------------------------
# Clock definition
# -----------------------------------------------------------------
set CLK_PORT   clk
set CLK_PERIOD 10.0
set CLK_UNCERTAINTY 0.15
set CLK_LATENCY_SRC 0.3
set CLK_LATENCY_NET 0.2

create_clock -name clk -period $CLK_PERIOD [get_ports $CLK_PORT]

set_clock_uncertainty $CLK_UNCERTAINTY [get_clocks clk]
set_clock_latency -source $CLK_LATENCY_SRC [get_clocks clk]
set_clock_latency $CLK_LATENCY_NET [get_clocks clk]
set_clock_transition 0.15 [get_clocks clk]

# -----------------------------------------------------------------
# Input / Output delays (external I/O budget: 1 ns each, per spec)
# -----------------------------------------------------------------
set INPUT_DELAY  1.0
set OUTPUT_DELAY 1.0

set ALL_INPUTS [all_inputs -no_clocks]
set ALL_OUTPUTS [all_outputs]

set_input_delay  -clock clk $INPUT_DELAY  $ALL_INPUTS
set_output_delay -clock clk $OUTPUT_DELAY $ALL_OUTPUTS

# -----------------------------------------------------------------
# Reset - asynchronous, treated as false path for max delay analysis
# (still checked for recovery/removal by the tool via the clock def)
# -----------------------------------------------------------------
set_false_path -from [get_ports rst_n]

# -----------------------------------------------------------------
# Driving cell / load assumptions for top-level ports
# Using a representative SG13G2 inverter/buffer as driving cell.
# Replace sg13g2_inv_1 / sg13g2_buf_4 with actual liberty cell names
# from the target corner library if they differ.
# -----------------------------------------------------------------
set_driving_cell -lib_cell sg13g2_inv_1 -pin Y $ALL_INPUTS
set_load [expr {4 * 0.0015}] $ALL_OUTPUTS

# -----------------------------------------------------------------
# Design rule / signal integrity constraints
# -----------------------------------------------------------------
set_max_transition 0.5   [current_design]
set_max_capacitance 0.15 [current_design]
set_max_fanout 16        [current_design]

# Tighter transition constraint on the clock network itself
set_max_transition 0.25  [get_clocks clk]

# -----------------------------------------------------------------
# Case analysis (none required - single mode, no test/scan pins
# in this revision). Left here as a placeholder hook.
# -----------------------------------------------------------------
# set_case_analysis 0 [get_ports scan_enable]

# -----------------------------------------------------------------
# False paths
# -----------------------------------------------------------------
# uart_rx is an asynchronous external input that feeds a 2-flop
# synchronizer (used to detect a host start-bit / request-dump edge).
# It is not timing-related to the internal clock domain, so the
# first-stage capture is exempted from setup/hold analysis in the
# standard synchronizer false-path convention.
set_false_path -from [get_ports uart_rx]

# debug_bus is a diagnostics-only export; relax to a generous but
# still-checked output delay budget already covered above. No
# additional false-path needed since it is fully synchronous.

# -----------------------------------------------------------------
# End of SDC
# -----------------------------------------------------------------

