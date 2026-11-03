// G0 hello-world: one flop and a check. Used by every tool of items 0.1 and 0.2.
module hello (input logic clk, input logic rst_n, input logic d, output logic q);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 1'b0; else q <= d;
endmodule

`ifndef SYNTHESIS
module tb_hello;
    logic clk = 0, rst_n = 0, d = 0, q;
    hello dut (.*);
    always #5 clk = ~clk;
    initial begin
        #12 rst_n = 1; d = 1; @(posedge clk); #1;
        if (q !== 1'b1) begin $display("HELLO FAIL q=%b", q); $finish; end
        $display("HELLO PASS");
        $finish;
    end
endmodule
`endif
