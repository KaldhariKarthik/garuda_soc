# =============================================================================
# ahb2apb_exclusions.tcl - coverage waivers for the AHB2APB (GENERATED, do not edit:
#     python3 tools/cov/gen_imc_exclusions.py ahb2apb
# from tb/ahb2apb/cov/ahb2apb_waivers.toml, whose entries carry the evidence: PROVEN
# properties, literal RTL lines; see tools/cov/cov_report.py and handbook H5).
#
# Applied in IMC after loading the merged AHB2APB run, e.g.
#     imc -load <cov_work>/scope/all -init flow/cov/ahb2apb_exclusions.tcl
# Instances are written from the DUT top (ahb2apb_bridge);
# flow/cov/ahb2apb_report.tcl maps that top onto the simulation's instance path.
# Commented lines need IMC's
# block / expression / bin identifiers and are completed in IMC.
# =============================================================================
# CL-HSTATE (unreachable, line) TO COMPLETE IN IMC: rtl/ahb2apb/ahb2apb_bridge.v ^line:172 case
#   reason  : The hclk FSM's 3-bit state uses six codes (H_IDLE..H_ERR2); the `default:` arm recovers the two unused codes, which no transition produces.
#   evidence: PROVEN fv_apb apb_prove + fv_apb_div div_prove a_hstate_legal (hstate <= 5), abc pdr, 2026-10-14
# exclude -inst ahb2apb_bridge -block <IMC block id of that line> -comment "The hclk FSM's 3-bit state uses six codes (H_IDLE..H_ERR2); the `default:` arm recovers the two unused codes, which no transition produces."
# CB-WIN12 (unreachable, branch) TO COMPLETE IN IMC: rtl/ahb2apb/ahb2apb_apb_fsm.v ^line:53 cond_else
#   reason  : win_i is the bridge's captured window, which only takes a present window 0..11; the guard (win_i < 12) protects the APB_DIV part-select and is never false.
#   evidence: PROVEN fv_apb apb_prove + fv_apb_div div_prove a_win_cap_legal (win_cap < 12 always), 2026-10-14
# exclude -inst ahb2apb_bridge.u_fsm -block <IMC block id> -comment "win_i is the bridge's captured window, which only takes a present window 0..11; the guard (win_i < 12) protects the APB_DIV part-select and is never false."
# CE-WIN12 (unreachable, expr) TO COMPLETE IN IMC: rtl/ahb2apb/ahb2apb_apb_fsm.v ^line:53 \(\(win_i < 4'hc\)==0\)
#   reason  : Same guard as CB-WIN12: (win_i < 12) is never false.
#   evidence: PROVEN a_win_cap_legal, as CB-WIN12
# exclude -inst ahb2apb_bridge.u_fsm -expression <IMC id> -comment "Same guard as CB-WIN12: (win_i < 12) is never false."
# CT-SIZE2-ahb2apb_bridge (constant): literal rtl/core/garuda_iport_ahb_master.v:89, rtl/core/load_store_unit.v:32, rtl/debug/sba_master.v:42, rtl/dma/dma_engine.v {1'b0, size}
exclude -inst ahb2apb_bridge -toggle hsize_i\[2\] -comment "The AHB is 32 bits wide: HSIZE <= word, so HSIZE[2] is 0 on the shared bus."
# CT-TOCNT-ahb2apb_apb_fsm (constant): PROVEN fv_apb / fv_apb_div a_to_cnt_max (rtl/ahb2apb/ahb2apb_sva.sv)
exclude -inst ahb2apb_bridge.u_fsm -toggle to_cnt\[4\] -comment "The 5-bit timeout counter stops at TIMEOUT-1 = 15, so bit 4 is never set."
# CT-WORDALIGN-ahb2apb_bridge (constant): PROVEN fv_apb a_subword_no_apb; AHB-Lite alignment rule checked by ahb_lite_checker on every master port; GARUDA masters: BUS-E (a_iport_pc_aligned PROVEN), the LSU traps misaligned accesses
exclude -inst ahb2apb_bridge -toggle addr_cap\[0\] -comment "Only word transfers reach APB (sub-word is rejected, a_subword_no_apb PROVEN) and an AHB-Lite word transfer is word-aligned, so the captured address and PADDR bits [1:0] are 0."
exclude -inst ahb2apb_bridge -toggle addr_cap\[1\] -comment "Only word transfers reach APB (sub-word is rejected, a_subword_no_apb PROVEN) and an AHB-Lite word transfer is word-aligned, so the captured address and PADDR bits [1:0] are 0."
exclude -inst ahb2apb_bridge -toggle paddr_o\[0\] -comment "Only word transfers reach APB (sub-word is rejected, a_subword_no_apb PROVEN) and an AHB-Lite word transfer is word-aligned, so the captured address and PADDR bits [1:0] are 0."
exclude -inst ahb2apb_bridge -toggle paddr_o\[1\] -comment "Only word transfers reach APB (sub-word is rejected, a_subword_no_apb PROVEN) and an AHB-Lite word transfer is word-aligned, so the captured address and PADDR bits [1:0] are 0."
