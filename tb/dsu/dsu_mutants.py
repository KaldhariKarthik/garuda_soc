# dsu_mutants.py - planted defects for tb_dsu_top (tools/mutate.py spec).
#
#   python3 tools/gen/DSU_gen.py --outdir sim/dsu                  # per-test vectors
#   python3 tools/gen/DSU_gen.py --stream --outdir sim/dsu_stream  # back-to-back vectors
#   SIM=icarus python3 tools/mutate.py tb/dsu/dsu_mutants.py                    # per-test protocol
#   SIM=icarus DSU_STREAM=1 python3 tools/mutate.py tb/dsu/dsu_mutants.py       # +STREAM
#
# The first three are the survivors BUGS TB-42 names: with an idle cycle after every
# instruction the bench never sees one instruction meet the next. The others are
# controls that both protocols must catch.
import os

STREAM = os.environ.get("DSU_STREAM") == "1"
NAME = "dsu_stream" if STREAM else "dsu"
FILES = [
    "rtl/dsu/csa_3to2.v", "rtl/dsu/kogge_stone_49.v", "rtl/dsu/mult_16x16.v",
    "rtl/dsu/operand_router.v", "rtl/dsu/mac_unit.v", "rtl/dsu/mac_cluster.v",
    "rtl/dsu/barrel_shifter.v", "rtl/dsu/saturation_unit.v", "rtl/dsu/readback_mux.v",
    "rtl/dsu/result_selector.v", "rtl/dsu/overflow_flag.v", "rtl/dsu/dsu_stall.v",
    "rtl/dsu/dsu_decoder.v", "rtl/dsu/dsu_top.v", "rtl/dsu/dsu_sva.sv", "rtl/dsu/dsu_arith_sva.sv",
]
INCDIRS = ["rtl/dsu"]
BENCH = "tb/dsu/filelist_dsu_top.f"
# The block of tb/dsu/filelist_dsu_top.f that names the RTL, replaced by the mutant copies.
FL_LINE = "\n".join(["-incdir rtl/dsu", ""] + FILES)
TOP = "tb_dsu_top"
ARGS = ("+STREAM +STIM=sim/dsu_stream/dsu_stim.mem +EXP=sim/dsu_stream/dsu_expected.mem"
        if STREAM else "+STIM=sim/dsu/dsu_stim.mem +EXP=sim/dsu/dsu_expected.mem")

MUTANTS = [
    # TB-42 survivors
    ("no_interlock (dsu_busy tied low)", "rtl/dsu/dsu_stall.v",
     "assign dsu_busy = stall_now;", "assign dsu_busy = 1'b0;"),
    ("ovf_not_sticky (flag follows this cycle)", "rtl/dsu/overflow_flag.v",
     "else if (any_ovf)            dsu_overflow <= 1'b1;",
     "else                         dsu_overflow <= any_ovf;"),
    ("ovf_clear_drops_set (clear beats a same-cycle overflow)", "rtl/dsu/overflow_flag.v",
     "else if (csr_clear_overflow) dsu_overflow <= any_ovf;",
     "else if (csr_clear_overflow) dsu_overflow <= 1'b0;"),
    # the RTL fixes the golden model had not followed (BUGS TB-49)
    ("sat_in_held_cycle (DSU-12 undone)", "rtl/dsu/dsu_top.v",
     ".sat_op (sat_op & ~dsu_busy_w),", ".sat_op (sat_op),"),
    ("load_any_unit (DSU-11 undone)", "rtl/dsu/mac_unit.v",
     "wire my_load  = load  & en & ~flush;", "wire my_load  = load  & ~flush;"),
    # EQUIVALENT, so it survives both protocols: with ~clear removed a MACCLEAR latches its
    # product, but pend_clr (clear | load | sat) has priority over prod_en in the sum_reg
    # block, so the latched product is zero and the fold that follows adds nothing.
    ("clear_latches_product (DSU-2 undone)", "rtl/dsu/mac_unit.v",
     "wire prod_en  =  en & ~clear & ~load & ~sat_writeback_en & ~flush;",
     "wire prod_en  =  en & ~load & ~sat_writeback_en & ~flush;"),
]
