# IFV: the pipe_ctrl properties (CORE [N-11.3]) in the context of the whole core.
#   ifv +64bit -f flow/2_static/fv_pipe_ctrl/files.f +top+garuda_core_top \
#       +tcl+flow/2_static/fv_pipe_ctrl/prove.tcl -l sim/fv_pipe_ctrl/ifv.log
# Bus inputs and interrupt inputs are left free: every AHB response and every
# interrupt arrival time is explored.

clock -add clk_i

# reset: hold both core resets low for four cycles, then release for good
force core_rst_n_i 0
force hartreset_n_i 0
run 4
init -load -current
constraint -add -pin core_rst_n_i 1 -reset
constraint -add -pin hartreset_n_i 1 -reset

# inputs change only on the clock
constraint -add -change * -clock clk_i -edge posedge

prove
assertion -summary
assertion -show -all
