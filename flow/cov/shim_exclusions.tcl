# =============================================================================
# shim_exclusions.tcl - coverage waivers for the APB shim (D-40, 2026-11-20), measured in the
# main merge (chip runs and every peripheral UVM environment). Per design type. Every line has
# its reason; cov_chart fails on a line that matches nothing (IMC *W,NOMATCH).
# =============================================================================
exclude -type garuda_apb_shim -toggle pready_o -comment "no peripheral inserts wait states (AHB2APB spec 7.5): PREADY is tied 1 in garuda_apb_shim.sv"
