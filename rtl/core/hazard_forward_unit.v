`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core - ID Stage, Sub-block 5/5
// Hazard / Forwarding unit (ID-side: load-use detection)  (Verilog)
//
// Spec reference: AERO-GARUDA-DS-001 Rev 1.0, Sec. 11.1 - Sec. 11.2
//
// Sec. 11.2 Load-Use Hazard: the hazard unit detects the load-use case by
// comparing the ID-stage rs1_idx/rs2_idx against the EX-stage rd when
// mem_read is set for the instruction in EX. On a hit it stalls PC and
// IF/ID and flushes ID/EX (one bubble), so the value can be forwarded
// MEM->EX the following cycle. This is the only data-hazard stall in
// the core.
//
// Scope note: Sec. 11.1's EX/MEM and MEM/WB forward-select muxes (MUX_A/
// MUX_B) operate on values that only exist once an instruction is in
// EX/MEM and MEM/WB - that comparison and mux-select logic is physically
// part of the EX stage, not ID, even though the block diagram draws one
// "Hazard/Forwarding" box spanning both concerns. This sub-block owns
// only the ID-side half: load-use detection, which by definition must
// happen while the consumer is still in ID.
// =============================================================================

module hazard_forward_unit (
    input  wire [4:0] id_rs1_idx_i,
    input  wire [4:0] id_rs2_idx_i,

    input  wire        ex_mem_read_i,   // instruction currently in EX is a load
    input  wire [4:0] ex_rd_i,

    output wire         load_use_stall_o
);

    assign load_use_stall_o = ex_mem_read_i && (ex_rd_i != 5'd0) &&
                               ((ex_rd_i == id_rs1_idx_i) || (ex_rd_i == id_rs2_idx_i));

endmodule

`default_nettype wire
