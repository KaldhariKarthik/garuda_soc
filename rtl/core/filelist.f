// =============================================================================
// GARUDA SoC - Block I: Processor Core - compile filelist (xrun/Genus)
// EX + CONTROL are added here once implemented.
// =============================================================================
-incdir rtl/common
-incdir rtl/core

// --- IF stage ---
rtl/core/garuda_pc_gen.v
rtl/core/garuda_iport_ahb_master.v
rtl/core/garuda_prefetch_buffer.v
rtl/core/garuda_if_stage_top.v

// --- ID stage ---
rtl/core/decode_control.v
rtl/core/imm_gen.v
rtl/core/regfile.v
rtl/core/branch_predict.v
rtl/core/hazard_forward_unit.v
rtl/core/id_stage.v

// --- MEM stage ---
rtl/core/load_store_unit.v
rtl/core/d_port_ahb_master.v
rtl/core/load_formatter.v
rtl/core/mem_stage.v

// --- MEM/WB + WB ---
rtl/core/mem_wb_reg.v
rtl/core/wb_stage.v
