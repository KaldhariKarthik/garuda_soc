module tb2;
  localparam [17:0] P = {3'd0, 3'd4, 3'd2, 3'd1, 3'd3, 3'd5};
  logic [5:0] e; logic v; logic [2:0] b, c; integer n;
  always @(*) begin v = 0; b = 0; c = 0; for (n = 0; n < 6; n = n + 1) begin if (e[n] && (!v || P[3*n +: 3] > b)) begin v = 1; c = n[2:0]; b = P[3*n +: 3]; end end end
  initial begin for (int i = 0; i < 64; i++) begin e = 6'(i); #1; end $finish; end
endmodule
