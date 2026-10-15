`timescale 1ns/1ps
// =============================================================================
// tb_dsu_mac_unit_spec.sv -- one mac_unit against the sequential reference
// (tb_dsu_mac_spec_pkg) (Track A wrap-up 2026-10-12; for sign-off next to the
// ported tb_dsu_mac_unit, which models a single-stage accumulate: TB-43).
// Bursts of 1..4 back-to-back ops (with the dsu_top protocol: a saturate, clear or load of
// an accumulator straight behind an accumulate of it waits one cycle; see DSU-12, DSU-18) (any mix, including the DSU-12 / DSU-13 cases:
// an accumulate followed at once by a clear, a load or a saturate write-back),
// some cycles flushed (the flushed op has no effect; an older pending fold still
// lands), then two idle cycles; after every burst mac_out must equal the
// reference accumulator and the overflow output must have pulsed iff the
// reference left the 48-bit range. Operands: random and the Q1.15 corners.
// =============================================================================
module tb_dsu_mac_unit_spec;
    import tb_dsu_mac_spec_pkg::*;
    logic clk = 0, rst_n = 0;
    logic [31:0] rs1 = 0, rs2 = 0;
    logic en = 0, add_sub = 0, clear = 0, load = 0, abs_en = 0, dot_en = 0, flush = 0, sat_en = 0;
    logic [47:0] satv = 0;
    wire  [47:0] mac_out;
    wire  ovf;
    mac_unit dut (.clk(clk), .rst_n(rst_n), .rs1(rs1), .rs2(rs2), .en(en), .add_sub(add_sub), .clear(clear),
                  .load(load), .abs_en(abs_en), .dot_en(dot_en), .flush(flush), .sat_writeback(satv),
                  .sat_writeback_en(sat_en), .mac_out(mac_out), .overflow(ovf));
    always #5 clk = ~clk;
    int checks = 0, fails = 0, n_ovf = 0;
    logic [47:0] ref_acc = 0;
    bit ovf_seen, ref_ovf;
    always @(posedge clk) if (ovf) ovf_seen = 1;
    function automatic logic [31:0] opnd();
        logic [15:0] c [6] = '{16'h0000, 16'h0001, 16'h7FFF, 16'h8000, 16'hFFFF, 16'h4000};
        return {($urandom_range(3, 0) == 0) ? c[$urandom_range(5, 0)] : 16'($urandom()),
                ($urandom_range(3, 0) == 0) ? c[$urandom_range(5, 0)] : 16'($urandom())};
    endfunction
    task automatic drive(input op_t op, input logic [31:0] a, input logic [31:0] b, input logic [47:0] sv, input bit fl);
        bit o;
        rs1 = a; rs2 = b; satv = sv; flush = fl;
        en = op inside {OP_MAC, OP_SUB, OP_ABS, OP_DOT, OP_LOAD, OP_CLEAR};
        add_sub = op == OP_SUB; abs_en = op == OP_ABS; dot_en = op == OP_DOT;
        load = op == OP_LOAD; clear = op == OP_CLEAR; sat_en = op == OP_SAT;
        @(posedge clk); #1;
        if (!fl) begin ref_acc = apply(op, ref_acc, a, b, sv, o); ref_ovf |= o; end
        {en, add_sub, abs_en, dot_en, load, clear, sat_en, flush} = '0;
    endtask
    initial begin
        repeat (2) @(posedge clk); #1; rst_n = 1;
        for (int burst = 0; burst < 6000; burst++) begin
            automatic int n = $urandom_range(4, 1);
            ovf_seen = 0; ref_ovf = 0;
            // now and then start near the edge of the range, so the accumulates overflow
            if (burst % 7 == 0) begin
                drive(OP_SAT, 0, 0, ($urandom_range(1, 0)) ? 48'h7FFF_FFFF_0000 + $urandom_range(65535, 0)
                                                            : 48'h8000_0000_FFFF - $urandom_range(65535, 0), 0);
                repeat (2) @(posedge clk); #1;
                ovf_seen = 0; ref_ovf = 0;
            end
            begin
                op_t prev = OP_IDLE;
                for (int k = 0; k < n; k++) begin
                    automatic op_t op = op_t'($urandom_range(6, 0));
                    automatic bit fl = $urandom_range(9, 0) == 0;
                    // the dsu_top protocol: the interlock holds a saturate one cycle behind an accumulate
                    // (DSU-12); a clear / load straight after an accumulate is DSU-18 (open, own reproducer)
                    if (prev inside {OP_MAC, OP_SUB, OP_ABS, OP_DOT} && op inside {OP_SAT, OP_CLEAR, OP_LOAD}) begin
                        @(posedge clk); #1;
                    end
                    drive(op, opnd(), opnd(), {$urandom(), $urandom()}, fl);
                    prev = fl ? OP_IDLE : op;
                end
            end
            repeat (2) @(posedge clk); #1;
            checks++;
            if (mac_out !== ref_acc || ovf_seen != ref_ovf) begin
                fails++;
                if (fails <= 10) $display("[FAIL] burst %0d: mac_out=%012h expected %012h, overflow seen %0d expected %0d", burst, mac_out, ref_acc, ovf_seen, ref_ovf);
            end
            n_ovf += ref_ovf;
        end
        $display("tb_dsu_mac_unit_spec: checks=%0d FAIL=%0d (bursts with an overflow: %0d)", checks, fails, n_ovf);
        $display("RESULT: %s", (fails == 0 && checks > 0 && n_ovf > 0) ? "PASSED" : "FAILED");
        $finish;
    end
endmodule
