`timescale 1ns/1ps
// =============================================================================
// tb_dsu_mac_cluster_spec.sv -- mac_cluster (three accumulators, acc_sel steering)
// against the sequential reference (tb_dsu_mac_spec_pkg) (Track A wrap-up
// 2026-10-12; for sign-off next to the ported tb_dsu_mac_cluster, TB-43).
// Bursts of 1..4 back-to-back ops (with the dsu_top protocol: a saturate, clear or load of
// an accumulator straight behind an accumulate of it waits one cycle; see DSU-12, DSU-18) on random accumulators (so an op on one
// accumulator lands while another's product is still folding, t_dsu_b2b's cases),
// some flushed, then two idle cycles; after every burst all three accumulators
// (dbg_acc_*) and cluster_out (the selected one) must equal the reference, and
// each accumulator's overflow bit must have pulsed iff its reference left the range.
// =============================================================================
`include "dsu_defs.vh"
module tb_dsu_mac_cluster_spec;
    import tb_dsu_mac_spec_pkg::*;
    logic clk = 0, rst_n = 0;
    logic [31:0] rs1 = 0, rs2 = 0;
    logic [`MAC_CTRL_W-1:0] control = 0;
    logic [1:0] sel = 0;
    logic [47:0] satv = 0;
    logic sat_en = 0;
    wire [47:0] cout, a0, a1, a2;
    wire [2:0] ovf;
    mac_cluster dut (.clk(clk), .rst_n(rst_n), .rs1(rs1), .rs2(rs2), .control(control), .acc_sel(sel),
                     .sat_writeback(satv), .sat_writeback_en(sat_en), .cluster_out(cout), .overflow(ovf),
                     .dbg_acc_0(a0), .dbg_acc_1(a1), .dbg_acc_2(a2));
    always #5 clk = ~clk;
    int checks = 0, fails = 0, n_ovf = 0;
    logic [47:0] ref_acc [3] = '{0, 0, 0};
    bit [2:0] ovf_seen, ref_ovf;
    always @(posedge clk) ovf_seen |= ovf;
    task automatic drive(input op_t op, input logic [1:0] s, input logic [31:0] a, input logic [31:0] b,
                         input logic [47:0] sv, input bit fl);
        bit o;
        rs1 = a; rs2 = b; satv = sv; sel = s;
        control = '0;
        control[`MAC_CTRL_EN]     = op inside {OP_MAC, OP_SUB, OP_ABS, OP_DOT, OP_LOAD, OP_CLEAR};
        control[`MAC_CTRL_ADDSUB] = op == OP_SUB;
        control[`MAC_CTRL_ABS]    = op == OP_ABS;
        control[`MAC_CTRL_DOT]    = op == OP_DOT;
        control[`MAC_CTRL_LOAD]   = op == OP_LOAD;
        control[`MAC_CTRL_CLEAR]  = op == OP_CLEAR;
        control[`MAC_CTRL_FLUSH]  = fl;
        sat_en = (op == OP_SAT);
        @(posedge clk); #1;
        if (!fl) begin ref_acc[s] = apply(op, ref_acc[s], a, b, sv, o); ref_ovf[s] |= o; end
        control = '0; sat_en = 0;
    endtask
    initial begin
        repeat (2) @(posedge clk); #1; rst_n = 1;
        for (int burst = 0; burst < 6000; burst++) begin
            automatic int n = $urandom_range(4, 1);
            if (burst % 7 == 0) begin
                automatic logic [1:0] s = 2'($urandom_range(2, 0));
                drive(OP_SAT, s, 0, 0, ($urandom_range(1, 0)) ? 48'h7FFF_FFFF_0000 : 48'h8000_0000_FFFF, 0);
                repeat (2) @(posedge clk); #1;
            end
            ovf_seen = 0; ref_ovf = 0;
            begin
                op_t prev = OP_IDLE; logic [1:0] psel = 0;
                for (int k = 0; k < n; k++) begin
                    automatic op_t op = op_t'($urandom_range(6, 0));
                    automatic logic [1:0] s = 2'($urandom_range(2, 0));
                    automatic bit fl = $urandom_range(9, 0) == 0;
                    // the dsu_top protocol on the SAME accumulator: the interlock holds a saturate one cycle
                    // behind an accumulate (DSU-12); a clear / load straight after one is DSU-18 (open)
                    if (prev inside {OP_MAC, OP_SUB, OP_ABS, OP_DOT} && op inside {OP_SAT, OP_CLEAR, OP_LOAD} && s == psel) begin
                        @(posedge clk); #1;
                    end
                    drive(op, s, $urandom(), $urandom(), {$urandom(), $urandom()}, fl);
                    prev = fl ? OP_IDLE : op; psel = s;
                end
            end
            sel = 2'($urandom_range(2, 0));
            repeat (2) @(posedge clk); #1;
            checks++;
            if (a0 !== ref_acc[0] || a1 !== ref_acc[1] || a2 !== ref_acc[2] || cout !== ref_acc[sel] || ovf_seen != ref_ovf) begin
                fails++;
                if (fails <= 10) $display("[FAIL] burst %0d: acc %012h %012h %012h (expected %012h %012h %012h), cluster_out[%0d] %012h, ovf %b expected %b",
                                          burst, a0, a1, a2, ref_acc[0], ref_acc[1], ref_acc[2], sel, cout, ovf_seen, ref_ovf);
            end
            n_ovf += (ref_ovf != 0);
        end
        $display("tb_dsu_mac_cluster_spec: checks=%0d FAIL=%0d (bursts with an overflow: %0d)", checks, fails, n_ovf);
        $display("RESULT: %s", (fails == 0 && checks > 0 && n_ovf > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
