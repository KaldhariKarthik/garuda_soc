# =============================================================================
# timers_exclusions.tcl - coverage waivers for block 11, timers and watchdog.
#
# Applied in IMC after loading the merged timers run:
#     imc -exec flow/cov/timers_report.tcl
# or typed at the IMC prompt. Every line has its reason. Sign-off criterion 3
# (flow/0_signoff_criteria.md): code coverage 100% after the waivers below.
#
# Two reasons cover everything here:
#   WDTCTL bits 31:2 are reserved and read 0 (TIMERS section 6, WDTCTL); the
#   32-bit read bus for that register carries 30 constant zeros. Checked on
#   every WDTCTL read by the scoreboard and by the register bit-bash test.
#   PREADY is tied high: the block never inserts a wait state (TIMERS
#   [N-7.11]); checked by property a_pready and scoreboard check sb_pready.
# =============================================================================
# 2026-11-20 (D-40): 90 exclusions removed that IMC reported as matching nothing (*W,NOMATCH):
# the code they named was renamed or removed in F4 / D-39. cov_chart now fails on any such line.
exclude -inst timers_top -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
exclude -inst timers_top.u_apb -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
exclude -inst timers_top.u_timers_sva -toggle pready_o -comment "PREADY is tied high, no wait states: checked by a_pready and sb_pready"
