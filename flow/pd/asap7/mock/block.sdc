# Mock-memory block constraints. EXPLORATORY. The memories are clocked by hclk;
# the block clock is hclk at DIV2 (4000 ps, ADR-0001). The rest is ORFS's generic
# ASAP7 macro template (platforms/asap7/constraints.sdc): set_max_delay
# optimisation targets (80 ps) for in->reg, reg->out and in->out, no I/O delays.
# The abstract's timing therefore reflects the MOCK logic only, not SRAM access time.
set clk_name clk
set clk_port_name clk
set clk_period 4000
source $env(PLATFORM_DIR)/constraints.sdc
