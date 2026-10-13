// Formal properties for the mock memories (PD-only). For one arbitrary row
// (anyconst probe), a shadow copy is built from the inputs alone, following
// sram_wrapper's behavioural model, and the mock's rdata is checked against it:
//   P1 read:  after ce & !we on the probe row, every byte written since time 0
//             reads back as last written, with byte enables respected.
//   P2 hold:  without a read access (ce & !we), rdata does not change.
//   P3 ROM:   a read returns the row's constant; rdata is otherwise held.
module props_ram #(parameter AW = 14) (input clk);
    (* anyseq *) reg ce, we; (* anyseq *) reg [3:0] be;
    (* anyseq *) reg [AW-1:0] addr; (* anyseq *) reg [31:0] wdata;
    (* anyconst *) reg [1:0] probe;
    wire [31:0] rdata;
    generate if (AW == 14) begin : g16k
        garuda_sram_16384x32 dut (.clk(clk), .ce(ce), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata));
    end else begin : g4k
        garuda_sram_4096x32  dut (.clk(clk), .ce(ce), .we(we), .be(be), .addr(addr), .wdata(wdata), .rdata(rdata));
    end endgenerate
    wire [1:0] idx = {^addr[AW-1:AW/2], ^addr[AW/2-1:0]};
    reg [31:0] shadow; reg [3:0] valid = 4'b0; reg past_valid = 1'b0;
    reg rd_q = 1'b0, rd_probe_q = 1'b0; reg [31:0] rdata_q;
    integer i;
    always @(posedge clk) begin
        past_valid <= 1'b1;
        rd_q <= ce && !we; rd_probe_q <= ce && !we && idx == probe; rdata_q <= rdata;
        if (ce && we && idx == probe)
            for (i = 0; i < 4; i = i + 1)
                if (be[i]) begin shadow[8*i +: 8] <= wdata[8*i +: 8]; valid[i] <= 1'b1; end
    end
    always @(posedge clk) if (past_valid) begin
        if (rd_probe_q)
            for (i = 0; i < 4; i = i + 1)
                if (valid[i]) assert (rdata[8*i +: 8] == shadow[8*i +: 8]);   // P1
        if (!rd_q) assert (rdata == rdata_q);                                 // P2
    end
    // reachability: a byte-masked write followed by a read of the probe row
    always @(posedge clk) cover (past_valid && rd_probe_q && valid != 4'b0 && valid != 4'hF);
endmodule

module props_rom (input clk);
    (* anyseq *) reg ce; (* anyseq *) reg [9:0] addr;
    wire [31:0] rdata;
    garuda_rom_1024x32 dut (.clk(clk), .ce(ce), .addr(addr), .rdata(rdata));
    wire [1:0] idx = {^addr[9:5], ^addr[4:0]};
    reg past_valid = 1'b0, rd_q = 1'b0; reg [1:0] idx_q; reg [31:0] rdata_q;
    always @(posedge clk) begin past_valid <= 1'b1; rd_q <= ce; idx_q <= idx; rdata_q <= rdata; end
    always @(posedge clk) if (past_valid) begin
        if (rd_q) assert (rdata == (idx_q == 2'd0 ? 32'h0000_0013 : idx_q == 2'd1 ? 32'h1000_0537 :
                                    idx_q == 2'd2 ? 32'hA5A5_5A5A : 32'h0F0F_F0F0));   // P3
        else      assert (rdata == rdata_q);
    end
endmodule
