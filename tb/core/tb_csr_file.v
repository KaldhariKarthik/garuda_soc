`timescale 1ns/1ps
`include "core_ex_defs.vh"
module tb_csr_file;
  integer errors=0; reg [31:0] prev_ir;
  reg clk=0; always #5 clk=~clk;
  reg rst_n, csr_en; reg [11:0] addr; reg [31:0] wdata; reg [1:0] op;
  reg instret, dsu_ovf, trap_enter, mret; reg [31:0] tpc,tcause,ttval; reg clic_mip;
  wire [31:0] rdata; wire illegal, clr_ovf; wire [31:0] mtvec,mtvt,mepc; wire mie; wire [7:0] ithr;
  csr_file dut(.clk_i(clk),.rst_n_i(rst_n),.csr_en_i(csr_en),.csr_addr_i(addr),
    .csr_wdata_i(wdata),.csr_op_i(op),.csr_rdata_o(rdata),.illegal_csr_o(illegal),
    .instret_i(instret),.dsu_overflow_i(dsu_ovf),.csr_clear_overflow_o(clr_ovf),
    .trap_enter_i(trap_enter),.mret_i(mret),.trap_pc_i(tpc),.trap_cause_i(tcause),
    .trap_tval_i(ttval),.clic_mip_i(clic_mip),.mstatus_mie_o(mie),.mtvec_o(mtvec),
    .mtvt_o(mtvt),.mepc_o(mepc),.mintthresh_o(ithr));
  task c32(input [127:0] n,input [31:0] g,input [31:0] e);
    begin if(g!==e)begin $display("FAIL %0s got %h exp %h",n,g,e);errors=errors+1;end end endtask
  task c1(input [127:0] n,input g,input e);
    begin if(g!==e)begin $display("FAIL %0s got %b exp %b",n,g,e);errors=errors+1;end end endtask
  task wr(input [11:0] a,input [31:0] d,input [1:0] o);
    begin @(negedge clk); csr_en=1;addr=a;wdata=d;op=o; @(negedge clk); csr_en=0;op=0; end endtask
  initial begin
    {rst_n,csr_en,instret,dsu_ovf,trap_enter,mret,clic_mip}=0; addr=0;wdata=0;op=0;
    tpc=0;tcause=0;ttval=0;
    @(negedge clk) rst_n=1;
    // write mtvec then read back
    wr(12'h305,32'h1000_0100,`CSR_RW); #1; c32("mtvec_wr",mtvec,32'h1000_0100);
    addr=12'h305;csr_en=1;op=`CSR_RS;wdata=0; #1; c32("mtvec_rd",rdata,32'h1000_0100); csr_en=0;op=0;
    // mscratch RS/RC
    wr(12'h340,32'hF0F0_F0F0,`CSR_RW);
    wr(12'h340,32'h0000_00FF,`CSR_RS); addr=12'h340;csr_en=1;op=`CSR_RS;wdata=0;#1;
      c32("mscratch_set",rdata,32'hF0F0_F0FF); csr_en=0;op=0;
    wr(12'h340,32'hF000_0000,`CSR_RC); addr=12'h340;csr_en=1;op=`CSR_RS;wdata=0;#1;
      c32("mscratch_clr",rdata,32'h00F0_F0FF); csr_en=0;op=0;
    // RO write illegal
    @(negedge clk) csr_en=1;addr=12'hF14;op=`CSR_RW;wdata=32'h5;#1; c1("ro_write_illegal",illegal,1'b1);csr_en=0;op=0;
    // unimplemented illegal
    @(negedge clk) csr_en=1;addr=12'h7FF;op=`CSR_RS;wdata=32'h1;#1; c1("unimpl_illegal",illegal,1'b1);csr_en=0;op=0;
    // legal read not illegal
    @(negedge clk) csr_en=1;addr=12'h305;op=`CSR_RS;wdata=0;#1; c1("legal_not_illegal",illegal,1'b0);csr_en=0;op=0;
    // dsu_ovf read pulses clear + returns overflow
    dsu_ovf=1; @(negedge clk) csr_en=1;addr=12'hBC0;op=`CSR_RS;wdata=0;#1;
      c1("dsu_ovf_rd",rdata[0],1'b1); c1("clr_ovf_pulse",clr_ovf,1'b1); csr_en=0;op=0; dsu_ovf=0;
    // trap entry: mepc/mcause/mtval + mstatus push (MIE was set first)
    wr(12'h300,32'h8,`CSR_RW); // set mstatus.MIE=1 (bit3)
    c1("mie_set",mie,1'b1);
    @(negedge clk) trap_enter=1;tpc=32'hAAAA_0000;tcause=32'd5;ttval=32'hBBBB; @(negedge clk) trap_enter=0;
    #1; c32("mepc",mepc,32'hAAAA_0000); c1("mie_cleared_on_trap",mie,1'b0);
    // mret pops MIE back
    @(negedge clk) mret=1; @(negedge clk) mret=0; #1; c1("mie_restored_on_mret",mie,1'b1);
    // minstret counts
    @(negedge clk); addr=12'hB02;csr_en=1;op=`CSR_RS;wdata=0;#1; prev_ir=rdata; csr_en=0;op=0;
    @(negedge clk) instret=1; @(negedge clk) instret=0;
    addr=12'hB02;csr_en=1;op=`CSR_RS;wdata=0;#1;
    if(rdata<=prev_ir) begin $display("FAIL minstret no advance %0d->%0d",prev_ir,rdata);errors=errors+1;end
    csr_en=0;op=0;
    if(errors==0)$display("CSR_FILE SMOKE: ALL CHECKS PASSED");
    else $display("CSR_FILE SMOKE: %0d FAILURE(S)",errors);
    $finish;
  end
endmodule
