`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// mem_wb_reg.v - MEM/WB Pipeline Register (Sec. 5.2)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// CONTRACT (mux-in-MEM, Sec. 5.2 / Sec. 10.3):
//   mem_stage performs the mem_to_reg mux itself and emits a single,
//   already-final wb_data. MEM/WB therefore carries only:
//       wb_data  - final writeback value (load-formatted OR EX result)
//       rd       - destination register index
//       reg_write- writeback enable
//   It does NOT carry a separate load_data + result + select trio; that
//   earlier (mux-in-WB) reading of Sec. 5.2 is retired - it double-counted
//   a 32-bit field and put the mux in the wrong stage.
//
// CONTROL (Sec. 11.4):
//   flush_i - insert a bubble (no writeback). Driven by CONTROL for BOTH:
//               (a) trap flush, and
//               (b) each cycle of a MEM D-port wait state.
//   There is deliberately NO hold: WB is the terminal stage and can never
//   stall from below, so MEM/WB is only ever held back by inserting
//   bubbles. A hold here would replay the previous instruction's writeback
//   every wait-state cycle - correct only because GPR writes are idempotent,
//   but semantically wrong. Bubble-on-wait is the correct model.
// =============================================================================

module mem_wb_reg (
    input  wire        clk_i,
    input  wire        rst_n_i,

    // Pipeline control
    input  wire        flush_i,        // bubble: trap flush OR MEM wait state

    // From MEM stage (post mem_to_reg mux - already final, Sec. 10.3)
    input  wire [31:0] wb_data_i,      // load-formatted value OR EX result
    input  wire [4:0]  rd_i,
    input  wire        reg_write_i,

    // To WB stage
    output reg  [31:0] wb_data_o,
    output reg  [4:0]  rd_o,
    output reg         reg_write_o
);

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i || flush_i) begin
            // Reset / bubble -> no writeback
            wb_data_o   <= 32'd0;
            rd_o        <= 5'd0;
            reg_write_o <= 1'b0;    // write-enable LOW = no WB
        end else begin
            wb_data_o   <= wb_data_i;
            rd_o        <= rd_i;
            reg_write_o <= reg_write_i;
        end
    end

endmodule
