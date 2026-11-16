`timescale 1ns/1ps
// =============================================================================
// tb_dsu_top_ovf_b2b.sv -- DSU-18 reproducer on dsu_top (Track A wrap-up
// 2026-10-12). An accumulate that overflows, followed IMMEDIATELY by a MACCLEAR or
// a MACLOAD of the same accumulator (no interlock: neither reads it), must still set
// the sticky overflow flag ([N-6.7], [N-6.9]: the MAC retired and overflowed; the
// younger op only replaces the value). Control cases: the overflowing MAC followed
// by an idle cycle, and by another MAC, set the flag.
// Each case: MACCLEAR, ramp the accumulator to just below 2^47 with maximal MACDOTs,
// clear the flag, then the case. The four cases run on each of ACC_FX, ACC_FY and
// ACC_MAG (2026-11-16), so every accumulator's c_fold_replaced_ovf cover is reached.
// DSU-18 fixed (D-32): every check passes.
// =============================================================================
module tb_dsu_top_ovf_b2b;
    logic clk = 0, rst_n = 0, flush = 0, dsu_en = 0, clr = 0;
    logic [31:0] instr = 0, rs1 = 0, rs2 = 0;
    wire dsu_busy, rd_valid, ovf, illegal;
    wire [31:0] rd_data; wire [4:0] rd_addr; wire [47:0] a0, a1, a2;
    dsu_top dut (.gclk(clk), .core_rst_n(rst_n), .flush(flush), .dsu_en(dsu_en), .instr(instr), .rs1_val(rs1), .rs2_val(rs2),
                 .csr_clear_overflow(clr), .dsu_busy(dsu_busy), .dsu_rd_data(rd_data), .dsu_rd_valid(rd_valid),
                 .dsu_rd_addr(rd_addr), .dsu_overflow(ovf), .illegal_instr(illegal),
                 .dbg_acc_fx(a0), .dbg_acc_fy(a1), .dbg_acc_mag(a2));
    always #5 clk = ~clk;
    logic [1:0] acc = 2'd0;                                   // the accumulator under test
    function automatic [31:0] r(input [4:0] f5);              // R-type DSU on acc, rd = x5
        return {f5, acc, 5'd2, 5'd1, 3'b000, 5'd5, 7'b0001011};
    endfunction
    task automatic op(input [4:0] f5, input [31:0] a, input [31:0] b);
        instr = r(f5); rs1 = a; rs2 = b; dsu_en = 1;
        @(posedge clk); #1;
        while (dsu_busy) begin @(posedge clk); #1; end
        dsu_en = 0;
    endtask
    task automatic idle(); dsu_en = 0; @(posedge clk); #1; endtask
    int fails = 0;
    initial begin
        repeat (2) @(posedge clk); #1; rst_n = 1;
        for (int k = 0; k < 12; k++) begin
            automatic int c = k % 4;
            acc = k / 4;
            op(5'd5, 0, 0); idle(); idle();                            // MACCLEAR
            for (int i = 0; i < 65535; i++) begin                      // +2^31 per MACDOT
                instr = r(5'd3); rs1 = 32'h80008000; rs2 = 32'h80008000; dsu_en = 1; @(posedge clk); #1;
            end
            dsu_en = 0; idle(); idle();
            clr = 1; idle(); clr = 0; idle();
            op(5'd3, 32'h80008000, 32'h80008000);                      // MACDOT: 2^47 - 2^31 + 2^31 crosses
            case (c)
                0: idle();                                             // control: nothing after
                1: op(5'd0, 1, 1);                                     // control: another MAC
                2: op(5'd5, 0, 0);                                     // MACCLEAR at once
                3: op(5'd4, 5, 0);                                     // MACLOAD at once
            endcase
            idle(); idle(); idle();
            $display("[%s] %s case %0d (%s): overflow flag %0d, accumulator %012h",
                     ovf ? "PASS" : "FAIL", acc == 0 ? "ACC_FX" : acc == 1 ? "ACC_FY" : "ACC_MAG", c,
                     c == 0 ? "MAC overflow, idle" : c == 1 ? "MAC overflow, MAC" : c == 2 ? "MAC overflow, MACCLEAR at once" : "MAC overflow, MACLOAD at once",
                     ovf, acc == 0 ? a0 : acc == 1 ? a1 : a2);
            if (!ovf) fails++;
        end
        $display("tb_dsu_top_ovf_b2b: checks=12 FAIL=%0d", fails);
        $display("RESULT: %s", fails ? "FAILED" : "PASSED");
        $finish;
    end
endmodule
