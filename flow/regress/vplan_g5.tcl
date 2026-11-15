# vplan_g5.tcl -- the G5 core vPlan back-annotated in vManager (1-TOPS G5 5.8, 5.9, flow
# stage F8; flow/4_core/core_g5.md section 4; flow/COMMANDS.md R5.9).
#
#   vmanager -local sim/vm_db -batch -init flow/regress/vplan_g5.tcl
#
# Run after a session of flow/regress/garuda.vsif has ended and flow/cov/core_g5_merge.tcl
# has written sim/cov_g5/core_g5.vRefine. sim/vm_g5/session is a link to the session's
# chain_0/garuda directory (R5.9).
# On this host the runs of a launched session never report back to the vManager server
# (TOOL-A17): the session stays "in_progress" and every run "waiting", although each run
# finished and was scanned (its local_vsof.txt). So the coverage of the runs is collected
# here into a session of its own (each run appears twice: its simulator vsof and its
# coverage directory; the coverage is a union, so the numbers are not changed).
collect -vsof_only -follow -load sim/vm_g5/session
load -vplan flow/1_vplan/garuda_core_g5.csv
load -refinement sim/cov_g5/core_g5.vRefine
report_vplan -out sim/vm_g5/vplan -overwrite
exit
