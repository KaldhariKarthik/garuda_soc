# =============================================================================
# mm_hold.tcl -- multi-mode hold repair after CTS (BUGS PD-9).
#
# env (pd_env.sh, run_mm_hold.sh): ODB_IN, ODB_OUT, PD_MODES, PD_SDC_DIR,
#      LIB_FILES, ADDITIONAL_LIBS, PLATFORM_DIR, DONT_USE_CELLS.
#
# ORFS repairs hold in the primary scenario only (SDC_FILE = DIV2). The
# ripple-divider latency differs per DIVSEL mode (PD-9), so a design clean at
# DIV2 holds can still miss at DIV4..16. This step defines one STA mode and
# scene per DIVSEL scenario, runs repair_timing -hold across all of them, and
# checks setup across all of them too. 4_cts.sdc (DIV2) is left as ORFS
# wrote it; the next ORFS stage reads the repaired database.
#
# pnr_r7: 15 hold endpoints across the four scenes, 175 buffers inserted,
# worst hold -261.88 -> +0.07 ps, setup unchanged (Docs/logs/pd/PD_LOG_2026-10-14.md).
# =============================================================================
source $::env(PD_SCRIPTS)/pd_common.tcl

pd_read_libs
read_db $::env(ODB_IN)
pd_define_scenes
pd_rc
set_dont_use $::env(DONT_USE_CELLS)
estimate_parasitics -placement

pd_scene_summary before
report_checks -path_delay min -group_path_count 3 -format end -sort_by_slack

repair_timing -hold -verbose
detailed_placement
check_placement -verbose
estimate_parasitics -placement

pd_scene_summary after
report_checks -path_delay min -group_path_count 3 -format end -sort_by_slack
report_checks -path_delay max -group_path_count 3 -format end -sort_by_slack

write_db $::env(ODB_OUT)
puts "=== MMHOLD DONE"
