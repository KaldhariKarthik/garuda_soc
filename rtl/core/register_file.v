// ============================================================================
// GARUDA SoC — Block I: Processor Core
// register_file.v — 32×32-bit GPR File (§5.3, §7.4)
// Document: AERO-GARUDA-DS-001 Rev 1.0
//
// Key properties per spec:
//   - 32 registers x0–x31, all 32 bits wide
//   - x0 hardwired to zero (reads always 0, writes discarded)
//   - Two combinational read ports (rs1, rs2) — no clock needed
//   - One synchronous write port (WB stage, posedge clk)
//   - Write-first bypass (§7.4):
//       if WB is writing the same register being read this cycle,
//       the NEW value is returned — not the stale stored value
//       This removes the structural hazard on back-to-back dependent ops
//       without needing a dedicated forwarding path for WB→ID
// ============================================================================

module register_file (
    input  wire        clk,

    // ── Read port 1 (rs1) — combinational ───────────────────────────────
    input  wire [4:0]  rs1_idx,
    output wire [31:0] rs1_data,

    // ── Read port 2 (rs2) — combinational ───────────────────────────────
    input  wire [4:0]  rs2_idx,
    output wire [31:0] rs2_data,

    // ── Write port (WB stage) — synchronous ─────────────────────────────
    input  wire        we,             // write enable
    input  wire [4:0]  rd_idx,         // destination register
    input  wire [31:0] rd_data         // value to write
);

    // ====================================================================
    // Storage: x1–x31 only (x0 is always zero, not stored)
    // ====================================================================
    reg [31:0] regs [1:31];

    // ====================================================================
    // Read port 1 — rs1 (§7.4)
    //
    // Priority:
    //   1. x0              → always 0
    //   2. WB forwarding   → if WB is writing rs1 this cycle, return new
    //   3. Register array  → stored value
    // ====================================================================
    assign rs1_data = (rs1_idx == 5'd0)
                        ? 32'd0
                        : (we && rd_idx == rs1_idx && rd_idx != 5'd0)
                            ? rd_data           // WB→ID bypass
                            : regs[rs1_idx];    // stored value

    // ====================================================================
    // Read port 2 — rs2 (§7.4)
    // Same priority as rs1
    // ====================================================================
    assign rs2_data = (rs2_idx == 5'd0)
                        ? 32'd0
                        : (we && rd_idx == rs2_idx && rd_idx != 5'd0)
                            ? rd_data           // WB→ID bypass
                            : regs[rs2_idx];    // stored value

    // ====================================================================
    // Write port — synchronous, x0 writes discarded (§5.3)
    // ====================================================================
    always @(posedge clk) begin
        if (we && rd_idx != 5'd0) begin
            regs[rd_idx] <= rd_data;
        end
    end

endmodule
