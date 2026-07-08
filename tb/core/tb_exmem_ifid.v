`timescale 1ns/1ps
module tb_exmem_ifid;
  integer errors=0;
  task c32(input [127:0] n, input [31:0] g, input [31:0] e);
    begin if(g!==e) begin $display("FAIL %0s got %h exp %h",n,g,e); errors=errors+1; end end endtask
  task c1(input [127:0] n, input g, input e);
    begin if(g!==e) begin $display("FAIL %0s got %b exp %b",n,g,e); errors=errors+1; end end endtask

  reg clk=0; always #5 clk=~clk;
  reg rst_n, stall, flush;

  // ex_mem
  reg [31:0] xr,sd,pc; reg [2:0] f3; reg [4:0] rd; reg mr,mw,m2r,rw;
  wire [31:0] xr_o,sd_o,pc_o; wire [2:0] f3_o; wire [4:0] rd_o; wire mr_o,mw_o,m2r_o,rw_o;
  ex_mem xm(.clk_i(clk),.rst_n_i(rst_n),.stall_i(stall),.flush_i(flush),
    .ex_result_i(xr),.store_data_i(sd),.funct3_i(f3),.rd_i(rd),.pc_i(pc),
    .mem_read_i(mr),.mem_write_i(mw),.mem_to_reg_i(m2r),.reg_write_i(rw),
    .ex_result_o(xr_o),.store_data_o(sd_o),.funct3_o(f3_o),.rd_o(rd_o),.pc_o(pc_o),
    .mem_read_o(mr_o),.mem_write_o(mw_o),.mem_to_reg_o(m2r_o),.reg_write_o(rw_o));

  // if_id
  reg [31:0] ii,ipc; reg iv,iflt;
  wire [31:0] ii_o,ipc_o; wire iv_o,iflt_o;
  if_id fd(.clk_i(clk),.rst_n_i(rst_n),.stall_i(stall),.flush_i(flush),
    .instr_i(ii),.pc_i(ipc),.valid_i(iv),.fault_i(iflt),
    .instr_o(ii_o),.pc_o(ipc_o),.valid_o(iv_o),.fault_o(iflt_o));

  initial begin
    rst_n=0; stall=0; flush=0;
    xr=32'hCAFEBABE; sd=32'h1234; f3=3'b010; rd=5'd12; pc=32'h8000_0040; mr=1; mw=0; m2r=1; rw=1;
    ii=32'h00A05093; ipc=32'h1000_0000; iv=1; iflt=0;  // (some real-ish instr word)
    @(negedge clk) rst_n=1;
    // reset->bubble
    c1("xm_rst_rw",rw_o,0); c1("xm_rst_mr",mr_o,0);
    c1("fd_rst_valid",iv_o,0); c32("fd_rst_nop",ii_o,32'h13);
    @(negedge clk); // normal capture
    c32("xm_pc",pc_o,32'h8000_0040); c32("xm_result",xr_o,32'hCAFEBABE); c1("xm_rw",rw_o,1);
    c32("xm_f3",{29'd0,f3_o},32'd2);
    c32("fd_instr",ii_o,32'h00A05093); c32("fd_pc",ipc_o,32'h1000_0000); c1("fd_valid",iv_o,1);
    // stall holds
    xr=32'h0; pc=32'h0; ii=32'hFFFF; iv=0; stall=1; @(negedge clk);
    c32("xm_stall_hold",pc_o,32'h8000_0040); c32("fd_stall_hold",ii_o,32'h00A05093);
    // release
    stall=0; @(negedge clk); c32("xm_release",pc_o,32'h0); c32("fd_release",ii_o,32'hFFFF);
    // flush beats stall
    xr=32'hAAAA; rw=1; mr=1; ii=32'hBBBB; iv=1; flush=1; stall=1; @(negedge clk);
    c1("xm_flush_rw",rw_o,0); c1("xm_flush_mr",mr_o,0);
    c1("fd_flush_valid",iv_o,0); c32("fd_flush_nop",ii_o,32'h13);
    if(errors==0) $display("EXMEM + IFID SMOKE: ALL CHECKS PASSED");
    else $display("EXMEM + IFID SMOKE: %0d FAILURE(S)",errors);
    $finish;
  end
endmodule
