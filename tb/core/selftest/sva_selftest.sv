// sva_selftest.sv -- proves the local simulators really evaluate SVA written the
// way the GARUDA repo writes it, before any "0 assertion failures" is trusted.
//
// Every construct the repo uses (|->, |=>, ##1, $past, $rose, $stable, $onehot,
// $isunknown, disable iff, bind, `else $error`) appears in one property that is
// violated EXACTLY ONCE, at a known cycle. Three properties must stay silent:
//   p_disable_guard  violated only while rst_n is low -> disable iff must mask it
//   p_never_fails    trivially true
//   p_isunknown      X driven on purpose: a 2-state simulator CANNOT see it, so it
//                    is expected silent under Verilator. Recorded as a limitation.
`timescale 1ns/1ps

module st_dut (input logic clk, input logic rst_n, input logic set_q);
    logic q;
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 1'b0; else q <= set_q;
endmodule

module st_chk (input logic clk, input logic rst_n, input logic q);
    p_bind: assert property (@(posedge clk) disable iff (!rst_n) !q)
        else $error("SELFTEST-FIRE p_bind");
endmodule

bind st_dut st_chk u_chk (.clk(clk), .rst_n(rst_n), .q(q));

module sva_selftest;
    logic clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    logic a = 0, b = 0, c = 0, d = 0, e = 0, f = 0, g = 0, h = 0, z = 0, set_q = 0;
    logic [3:0] v = 0, oh = 4'b0001;
    logic       xsig = 0;
    logic       ka = 0, kc = 0;

    st_dut u_dut (.clk(clk), .rst_n(rst_n), .set_q(set_q));

    p_impl_noaction: assert property (@(posedge clk) disable iff (!rst_n) a |-> b);
    p_next_error:    assert property (@(posedge clk) disable iff (!rst_n) c |=> d)
        else $error("SELFTEST-FIRE p_next_error");
    p_past:          assert property (@(posedge clk) disable iff (!rst_n) e |-> ($past(v) == 4'd3))
        else $error("SELFTEST-FIRE p_past");
    p_rose:          assert property (@(posedge clk) disable iff (!rst_n) $rose(f) |-> g)
        else $error("SELFTEST-FIRE p_rose");
    p_stable:        assert property (@(posedge clk) disable iff (!rst_n) h |-> ##1 $stable(v))
        else $error("SELFTEST-FIRE p_stable");
    p_onehot:        assert property (@(posedge clk) disable iff (!rst_n) $onehot(oh))
        else $error("SELFTEST-FIRE p_onehot");
    p_isunknown:     assert property (@(posedge clk) disable iff (!rst_n) !$isunknown(xsig))
        else $error("SELFTEST-FIRE p_isunknown");
    p_disable_guard: assert property (@(posedge clk) disable iff (!rst_n) !z)
        else $error("SELFTEST-FIRE p_disable_guard");
    p_never_fails:   assert property (@(posedge clk) disable iff (!rst_n) 1'b1)
        else $error("SELFTEST-FIRE p_never_fails");
    // IEEE 1800-2017 16.12: the disable condition is evaluated asynchronously --
    // if it is true at ANY time during an attempt, that attempt is disabled.
    // Reset pulses low strictly between the two rising edges of this |=> attempt,
    // so a compliant simulator must stay silent. (Pattern used by tb_garuda_pc_gen
    // and tb_mem_wb_reg for their mid-stream reset.)
    p_async_disable: assert property (@(posedge clk) disable iff (!rst_n) ka |=> kc)
        else $error("SELFTEST-FIRE p_async_disable");

    // drive on the falling edge so every value is settled at the sampling edge
    task automatic at(input int n); repeat (n) @(negedge clk); endtask

    initial begin
        z = 1;                    // violates p_disable_guard, but only in reset
        at(3);  z = 0; rst_n = 1;
        at(5);  a = 1;            // b = 0          -> p_impl_noaction fires once
        at(1);  a = 0;
        at(2);  c = 1;            // d stays 0      -> p_next_error fires next cycle
        at(1);  c = 0;
        at(2);  v = 4'd5;
        at(1);  e = 1;            // $past(v)=5     -> p_past fires once
        at(1);  e = 0;
        at(2);  f = 1;            // g = 0          -> p_rose fires once
        at(3);  f = 0;
        at(2);  h = 1;            // v changes next -> p_stable fires once
        at(1);  h = 0; v = 4'd9;
        at(2);  oh = 4'b0011;     //                -> p_onehot fires once
        at(1);  oh = 4'b0100;
        at(2);  xsig = 1'bx;      // invisible to a 2-state simulator
        at(1);  xsig = 0;
        at(2);  set_q = 1;        // q rises        -> p_bind fires once
        at(1);  set_q = 0;
        at(3);  ka = 1;           // a p_async_disable attempt starts at the next rising edge
        @(posedge clk); #1 rst_n = 0;   // reset pulse strictly between two rising edges
        #2 rst_n = 1; ka = 0;           // released before the next rising edge (kc stays 0)
        at(4);
        $display("SELFTEST DONE");
        $finish;
    end
endmodule
