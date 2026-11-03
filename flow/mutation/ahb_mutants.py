# Planted defects of the AHB interconnect (tools/mutate.py flow/mutation/ahb_mutants.py); random slave waits
NAME = "ahb"
FILES = ["rtl/ahb/ahb_decoder.v", "rtl/ahb/ahb_master_mux.v", "rtl/ahb/ahb_arbiter.v", "rtl/ahb/ahb_master_port.v",
         "rtl/ahb/ahb_slave_mux.v", "rtl/ahb/ahb_default_slave.v", "rtl/ahb/ahb_interconnect.v", "rtl/ahb/ahb_interconnect_sva.sv"]
INCDIRS = ["rtl/ahb"]
BENCH = "tb/ahb/filelist_ahb_ic.f"; FL_LINE = "-f rtl/ahb/filelist.f"; TOP = "tb_ahb_interconnect"; ARGS = "+GWAIT=3 +GRAND=1"
MUTANTS = [
 ("M1 SBA outranks the DMA", "rtl/ahb/ahb_arbiter.v", "wire [1:0] winner = req[`AHB_M_DMA]   ? `AHB_M_DMA   :\n                        req[`AHB_M_SBA]   ? `AHB_M_SBA   :", "wire [1:0] winner = req[`AHB_M_SBA]   ? `AHB_M_SBA   :\n                        req[`AHB_M_DMA]   ? `AHB_M_DMA   :"),
 ("M2 grant not held on a wait", "rtl/ahb/ahb_arbiter.v", "assign grant_o = hold_r ? grant_r : winner;", "assign grant_o = winner;"),
 ("M3 HWDATA follows the address owner (AHB-1)", "rtl/ahb/ahb_master_mux.v", "case (dph_master_i)\n            `AHB_M_DPORT: hwdata_o", "case (grant_i)\n            `AHB_M_DPORT: hwdata_o"),
 ("M4 orphan SEQ not broken (AHB-3)", "rtl/ahb/ahb_arbiter.v", "assign seq_break_o = ~last_owner_v || (last_owner_r != grant_o);", "assign seq_break_o = 1'b0;"),
 ("M5 bridge granule moved", "rtl/ahb/ahb_decoder.v", "`AHB_RGN_BRIDGE: hsel_o[`AHB_S_BRIDGE] = 1'b1;", "4'h5: hsel_o[`AHB_S_BRIDGE] = 1'b1;"),
 ("M6 default slave one-cycle ERROR", "rtl/ahb/ahb_default_slave.v", "S_ERR1:  begin hreadyout_o = 1'b0; hresp_o = `AHB_RESP_ERROR; end", "S_ERR1:  begin hreadyout_o = 1'b1; hresp_o = `AHB_RESP_ERROR; end"),
 ("M7 ungranted master sees HREADY", "rtl/ahb/ahb_master_port.v", "wire entitled = granted_i || (dph_own_i && !presenting);", "wire entitled = 1'b1;"),
 ("M8 hrdata leaks to a non-owner", "rtl/ahb/ahb_master_port.v", "dph_own_i  ? hrdata_shared_i : 32'h0000_0000;", "hrdata_shared_i;"),
]
