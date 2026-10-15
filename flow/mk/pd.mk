# =============================================================================
# flow/mk/pd.mk -- the ASAP7 physical-design steps (EXPLORATORY, D-27).
#
# Wrappers around flow/pd/asap7/scripts/. Every target takes the ORFS run name
# as V=<variant> (FLOW_VARIANT): results and logs live under
# $(PD_WORK)/{results,logs}/asap7/garuda/<variant>, analyses under
# $(PD_WORK)/analysis, never in the repo. ORFS and its tools come from
# ORFS_HOME (default ~/tools/OpenROAD-flow-scripts, flow/pd/TOOLS.md).
#
#   make pd_pnr V=pnr_r8 [PD_FROM=pnr_r7] [PD_CORES=8]   a whole run, synth to GDS
#   make pd_mmhold V=...      multi-mode hold repair after CTS (PD-9)
#   make pd_sta V=... [PD_STAGE=route|cts]   STA of all four DIVSEL scenarios
#   make pd_skew V=...        clock-tree latency and skew after CTS
#   make pd_phase V=...       launch/capture edges of every clock crossing
#   make pd_shot V=... [PD_VIEW=all|routing|30,40]   PNG of the final GDS
#   make pd_qor V=...         one page: outcome, timing per mode, area, power, DRC, stages
#   make pd_runs              every run side by side (the run-history table)
#   make pd_check             syntax of every PD script, no tools needed
# =============================================================================

PD_SCRIPTS := flow/pd/asap7/scripts
PD_STAGE   ?= route
PD_VIEW    ?= all
PD_CORES   ?= 8
PD_FALLBACK_CORES ?= 6
PD_FROM    ?=

.PHONY: help_pd pd_need_v pd_pnr pd_pnr_dry pd_mmhold pd_sta pd_skew pd_phase pd_shot pd_qor pd_runs pd_check

help_pd:
	@echo "  ---- physical design, ASAP7 (exploratory; V=<ORFS variant>) ----"
	@echo "  make pd_pnr V=r      -- synth..GDS: ORFS to CTS, multi-mode hold repair, route, STA"
	@echo "                          (PD_FROM=<run> starts from that run's CTS; pd_pnr_dry prints the steps)"
	@echo "  make pd_mmhold V=r   -- multi-mode (DIV2/4/8/16) hold repair on 4_cts.odb"
	@echo "  make pd_sta V=r      -- STA of every DIVSEL scenario (PD_STAGE=route or cts)"
	@echo "  make pd_skew V=r     -- clock latency and skew after CTS"
	@echo "  make pd_phase V=r    -- STA launch/capture edges of every clock crossing"
	@echo "  make pd_shot V=r     -- PNG of the GDS (PD_VIEW=all, routing or GDS layers)"
	@echo "  make pd_qor V=r      -- one-page summary of a run (also written to analysis/)"
	@echo "  make pd_runs         -- every run side by side: outcome, slack, DRC, cells, time, memory"
	@echo "  make pd_check        -- syntax check of the PD scripts"

pd_need_v:
	@test -n "$(V)" || { echo "set V=<ORFS variant>, e.g. make $(MAKECMDGOALS) V=pnr_r7"; exit 2; }

pd_pnr: pd_need_v
	@$(PD_SCRIPTS)/run_pnr.sh $(V) --cores $(PD_CORES) --fallback-cores $(PD_FALLBACK_CORES) \
	    $(if $(PD_FROM),--from $(PD_FROM))

pd_pnr_dry: pd_need_v
	@$(PD_SCRIPTS)/run_pnr.sh $(V) --dry-run --cores $(PD_CORES) --fallback-cores $(PD_FALLBACK_CORES) \
	    $(if $(PD_FROM),--from $(PD_FROM))

pd_mmhold: pd_need_v
	@$(PD_SCRIPTS)/run_mm_hold.sh $(V)

pd_sta: pd_need_v
	@$(PD_SCRIPTS)/run_sta.sh $(V) $(PD_STAGE)

pd_skew: pd_need_v
	@$(PD_SCRIPTS)/run_skew.sh $(V)

pd_phase: pd_need_v
	@$(PD_SCRIPTS)/run_phase.sh $(V)

pd_shot: pd_need_v
	@$(PD_SCRIPTS)/run_gds_shot.sh $(V) $(PD_VIEW)

pd_qor: pd_need_v
	@python3 $(PD_SCRIPTS)/qor.py $(V)

pd_runs:
	@python3 $(PD_SCRIPTS)/qor.py --all

# No ORFS needed: bash -n on the drivers, a Tcl parse of the step scripts when
# tclsh is installed, and a Python parse of the KLayout script.
pd_check:
	@set -e; n=0; \
	 for f in $(PD_SCRIPTS)/*.sh; do bash -n "$$f"; n=$$((n+1)); done; \
	 for f in $(PD_SCRIPTS)/*.sh; do [ -x "$$f" ] || [ "$${f##*/}" = pd_env.sh ] || { echo "not executable: $$f"; exit 1; }; done; \
	 if command -v tclsh > /dev/null; then \
	   for f in $(PD_SCRIPTS)/*.tcl; do echo 'puts [info complete [read [open [lindex $$argv 0]]]]' \
	     | tclsh /dev/stdin "$$f" | grep -qx 1 || { echo "Tcl incomplete: $$f"; exit 1; }; n=$$((n+1)); done; fi; \
	 for f in $(PD_SCRIPTS)/*.py; do python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$$f"; n=$$((n+1)); done; \
	 echo "pd_check: $$n PD scripts parse"
