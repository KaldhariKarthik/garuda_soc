module tb2;
  logic [5:0] e; logic v; logic [2:0] c; integer n;
  initial v = 0;
  always @(*) begin c = 0; for (n = 0; n < 6; n = n + 1) begin if (e[n] && !v) c = n[2:0]; end end
  initial begin for (int i = 0; i < 64; i++) begin e = 6'(i); #1; end $finish; end
endmodule
