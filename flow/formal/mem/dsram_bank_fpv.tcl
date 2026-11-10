# =============================================================================
# dsram_bank_fpv.tcl - the D-SRAM read-bank register is equivalent under the
# planted defect M8 of flow/mutation/mem_mutants.py (1-TOPS G4 flow extra).
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_dsram_bank/jgproject flow/formal/mem/dsram_bank_fpv.tcl
#
# rtl/dsram/dsram_top.v loads rd_bank_q on a read access (ce && !we); M8 loads it
# on every access. rd_bank_q is used only to pick the bank whose data a read
# data phase returns. Proven here on the shipped RTL: every read data phase
# comes right after a read access, and in it rd_bank_q is that access's bank.
# A write access in between is impossible, so M8's extra loads are never seen.
# The four bank arrays are black boxes: only the control path matters. Without
# m_hready_own both assertions fail: a free HREADY can stretch a read data phase
# while a parked write commits, which no AHB interconnect does.
# =============================================================================
analyze -sv09 +define+SYNTHESIS +incdir+rtl/mem rtl/mem/ahb_mem_slave_if.v rtl/dsram/dsram_top.v
elaborate -top dsram_top -bbox_m sram_wrapper
clock hclk_i
reset -expression {!hreset_n_i}
# AHB: in this slave's own data phase the bus HREADY is this slave's HREADYOUT
# (it is the data-phase slave; the interconnect returns its ready)
assume -name m_hready_own {u_if.dp_valid |-> (hready_i == hreadyout_o)}
assert -name a_rd_dp_after_read {u_if.rd_dp |-> $past(ce && !we)}
assert -name a_rd_bank_is_last_read {u_if.rd_dp |-> (rd_bank_q == $past(bank))}
cover  -name c_rd_dp_after_write {u_if.rd_dp && $past(u_if.wr_dp)}
cover  -name c_bank_change {u_if.rd_dp && $past(u_if.rd_dp) && (rd_bank_q != $past(rd_bank_q))}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_dsram_bank/props.txt
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
