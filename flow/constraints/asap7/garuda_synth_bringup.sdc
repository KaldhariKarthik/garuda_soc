# =============================================================================
# GARUDA / ASAP7: SYNTHESIS BRING-UP SDC. EXPLORATORY. Time unit = 1 ps.
#
# Purpose: enough constraint to synthesise GARUDA on ASAP7 and expose netlist
# object names. Defines only the two clocks that enter on ports. Derived clocks,
# DIVSEL scenarios, exceptions and I/O are applied afterwards, against the
# netlist, by the mode SDCs in this directory.
#
# NOT a timing sign-off constraint. ASAP7 is not the 28 nm target.
# =============================================================================
create_clock -name refclk -period 2000 [get_ports refclk]   ;# 500 MHz (ADR-0001, CLKRST R-1)
create_clock -name tck    -period 50000 [get_ports tck]     ;# <= 20 MHz (yaml clocks.tck)
