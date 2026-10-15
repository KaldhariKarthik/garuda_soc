# =============================================================================
# spim_fpv.tcl - formal proof of the garuda_spim_top wrapper's properties, with the
# vendored engine inside it (not edited, D-22) and the shim.
#
#   /home/install/JASPER/bin/jg -allow_unsupported_OS -fpv -batch -no_jges \
#       -proj sim/formal_spim/jgproject flow/formal/spim/spim_fpv.tcl
#
# One clock, pclk. The APB master, the pins and the DMA acknowledge are free, except
# that the APB master makes legal transfers. FL = another file list, PROPS = output.
# =============================================================================
set FL rtl/spi_master/filelist.f
if {[info exists ::env(FL)]} { set FL $::env(FL) }
set FILES [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL]] "\n"]
set INCS {}
foreach d [split [string trim [exec env -u LD_LIBRARY_PATH python3 scripts/expand_filelist.py $FL --incdirs]] " "] {
    if {$d ne ""} { lappend INCS +incdir+[string range $d 2 end] }
}
analyze -sv09 +define+FORMAL +incdir+rtl/include +incdir+rtl/common {*}$INCS {*}$FILES
elaborate -top garuda_spim_top
clock pclk_i
reset -expression {!preset_n_i}
assume -name assume_apb_legal {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && !penable_i) |=> (psel_i && penable_i && $stable(paddr_i) && $stable(pwrite_i) && $stable(pwdata_i))}
assume -name assume_apb_ends {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && penable_i) |=> !penable_i}
assume -name assume_apb_starts {@(posedge pclk_i) disable iff (!preset_n_i) ($rose(psel_i)) |-> !penable_i}
# firmware rules the spec states (the free APB master must keep them, or it proves nothing about GARUDA):
#   [N-6.1] STATUS[11:10] are written 0
#   [N-6.3] the chip-select field is not changed while a transfer runs (STATUS[0] reads 0)
#   SPIM-5  no STATUS write at all while a transfer is in flight (assume_fw_no_status_write_in_flight, in the sva)
assume -name assume_fw_cs_unused {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && pwrite_i && paddr_i == 12'h000) |-> pwdata_i[11:10] == 2'b00}
assume -name assume_fw_cs_stable {@(posedge pclk_i) disable iff (!preset_n_i) (psel_i && pwrite_i && paddr_i == 12'h000 && !u_spi.spi_ctrl_status[0]) |-> pwdata_i[11:8] == u_spi.spi_csreg[3:0]}
prove -all -time_limit 900s
report -summary
source flow/formal/common.tcl
set PROPS sim/formal_spim/props.txt
if {[info exists ::env(PROPS)]} { set PROPS $::env(PROPS) }
file mkdir [file dirname $PROPS]
list_props $PROPS
exit
