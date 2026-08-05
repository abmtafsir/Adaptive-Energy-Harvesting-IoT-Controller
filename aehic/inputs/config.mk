#===========================================================================
# config.mk - OpenROAD-flow-scripts (ORFS) design configuration
# Design : Adaptive Energy Harvesting IoT Controller (AEHIC)
# Top    : adaptive_energy_controller
# PDK    : IHP SG13G2 (130nm) Open PDK
#===========================================================================

export DESIGN_NICKNAME = aehic
export DESIGN_NAME     = adaptive_energy_controller
export PLATFORM        = ihp-sg13g2

# ---------------------------------------------------------------------
# RTL / Constraints sources
# ---------------------------------------------------------------------
export VERILOG_FILES = $(sort $(wildcard $(DESIGN_HOME)/src/$(DESIGN_NICKNAME)/adaptive_energy_controller.v))
export SDC_FILE       = $(DESIGN_HOME)/$(PLATFORM)/$(DESIGN_NICKNAME)/adaptive_energy_controller.sdc

# ---------------------------------------------------------------------
# Clock
# ---------------------------------------------------------------------
export CLOCK_PERIOD = 10.0
export CLOCK_PORT   = clk
export CLOCK_NET    = $(CLOCK_PORT)

# ---------------------------------------------------------------------
# Synthesis (Yosys) settings
# ---------------------------------------------------------------------
export SYNTH_HIERARCHICAL = 0
export FLATTEN            = 1
export ABC_AREA           = 1

# ---------------------------------------------------------------------
# Floorplanning
# ---------------------------------------------------------------------
# Utilization / aspect ratio are conservative starting points for a
# small mixed-control/datapath block; tune after first synth run.
export CORE_UTILIZATION = 40
export CORE_ASPECT_RATIO = 1.0
export CORE_MARGIN      = 20
export PLACE_DENSITY    = 0.55

# Die/core area left to be derived by utilization unless a hard
# floorplan is required; uncomment and set explicit values (in
# platform DB units) if a fixed die is needed for the MPW shuttle.
# export DIE_AREA  = 0 0 800 800
# export CORE_AREA = 10 10 790 790

# ---------------------------------------------------------------------
# Placement / CTS / Routing
# ---------------------------------------------------------------------
export TNS_END_PERCENT   = 100
export REMOVE_ABC_BUFFERS = 1

# ---------------------------------------------------------------------
# Power / IO
# ---------------------------------------------------------------------
# IHP SG13G2 default power/ground net names (verify against the
# platform's io/pdn config for the chosen pad frame / MPW harness).
export VDD_NET = VDD
export GND_NET = VSS

# ---------------------------------------------------------------------
# Signoff
# ---------------------------------------------------------------------
export SET_RC_METAL_LAYER = met2
export SET_RC_VIA_LAYER   = via2

