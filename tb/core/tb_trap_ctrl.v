`timescale 1ns/1ps
module tb_trap_ctrl;
  integer errors=0;
  reg clk=0; always #5 clk=~clk;
  reg rst_n;
  reg [31:0] idpc,idinstr,exaddr,mtvec,mepc,mpc,mtval;
  reg idflt,idill,idsys,dsuill,csrill,ldm,stm,memv; reg [3:0] memc;
  reg tkcond,wkcond; reg [11:0] irqid; reg [7:0] irqlvl; reg [31:0] vectgt;
  wire tk_ack, trap_en, is_int, mret, tr_rv, sq_ide, sq_exm, sq_mwb, wfih, exsq;
  wire [7:0] clvl; wire [31:0] tpc,tcause,ttval,trtgt;
  trap_ctrl dut(.clk_i(clk),.rst_n_i(rst_n),
    .idex_pc_i(idpc),.idex_instr_i(idinstr),.idex_fault_i(idflt),
    .idex_illegal_dec_i(idill),.idex_is_system_i(idsys),.ex_dsu_illegal_i(dsuill),
    .ex_csr_illegal_i(csrill),.ex_load_misalign_i(ldm),.ex_store_misalign_i(stm),.ex_addr_i(exaddr),
    .mem_exc_valid_i(memv),.mem_exc_cause_i(memc),.mem_exc_pc_i(mpc),.mem_exc_tval_i(mtval),
    .clic_take_cond_i(tkcond),.clic_wake_cond_i(wkcond),.clic_irq_id_i(irqid),
    .clic_irq_lvl_i(irqlvl),.clic_vector_target_i(vectgt),.clic_take_o(tk_ack),
    .mtvec_i(mtvec),.mepc_i(mepc),
    .trap_enter_o(trap_en),.is_interrupt_o(is_int),.clic_level_o(clvl),.mret_o(mret),
    .trap_pc_o(tpc),.trap_cause_o(tcause),.trap_tval_o(ttval),
    .trap_redirect_valid_o(tr_rv),.trap_redirect_target_o(trtgt),
    .trap_squash_id_ex_o(sq_ide),.trap_squash_ex_mem_o(sq_exm),.trap_squash_mem_wb_o(sq_mwb),
    .wfi_hold_o(wfih),.ex_squash_o(exsq));
  task c(input [255:0] n,input g,input e);
    begin if(g!==e)begin $display("FAIL %0s got %b exp %b",n,g,e);errors=errors+1;end end endtask
  task c32(input [255:0] n,input [31:0] g,input [31:0] e);
    begin if(g!==e)begin $display("FAIL %0s got %h exp %h",n,g,e);errors=errors+1;end end endtask
  task clr; begin
    idpc=32'h1000;idinstr=32'h13;exaddr=0;mtvec=32'h8000_0000;mepc=32'h4444;mpc=0;mtval=0;
    idflt=0;idill=0;idsys=0;dsuill=0;csrill=0;ldm=0;stm=0;memv=0;memc=0;
    tkcond=0;wkcond=0;irqid=0;irqlvl=0;vectgt=32'h0;
  end endtask
  initial begin
    rst_n=0; clr; #12 rst_n=1;
    // illegal (cause2, mtval=instr)
    clr; idinstr=32'hDEADBEEF; idill=1; #1;
      c("illegal_valid",trap_en,1); c32("illegal_cause",tcause,32'd2); c32("illegal_mtval",ttval,32'hDEADBEEF);
      c32("illegal_target",trtgt,32'h8000_0000);
    // load misalign (cause4, mtval=addr)
    clr; ldm=1; exaddr=32'h2003; #1; c32("ldmis_cause",tcause,32'd4); c32("ldmis_mtval",ttval,32'h2003);
    // ecall (cause11, mtval=0)
    clr; idsys=1; idinstr=32'h00000073; #1; c32("ecall_cause",tcause,32'd11); c32("ecall_mtval",ttval,0);
    // ebreak (cause3, mtval=pc)
    clr; idsys=1; idinstr=32'h00100073; idpc=32'hABC0; #1; c32("ebreak_cause",tcause,32'd3); c32("ebreak_mtval",ttval,32'hABC0);
    // ifetch fault beats illegal (cause1)
    clr; idflt=1; idill=1; idpc=32'h1000_0004; #1; c32("ifetch_cause",tcause,32'd1); c32("ifetch_mtval",ttval,32'h1000_0004);
    // MEM access fault outranks EX illegal
    clr; idill=1; memv=1; memc=4'd5; mpc=32'h5000; mtval=32'h5004; #1;
      c32("mem_over_ex_cause",tcause,32'd5); c32("mem_over_ex_pc",tpc,32'h5000); c("mem_squash_mwb",sq_mwb,1);
    // interrupt taken (no exception): mcause[31]=1 + id, target=vector, tval=0
    clr; tkcond=1; irqid=12'h7; irqlvl=8'd5; vectgt=32'h9000_0000; #1;
      c("int_take_ack",tk_ack,1); c("int_is_int",is_int,1); c32("int_cause",tcause,{1'b1,19'd0,12'h7});
      c32("int_target",trtgt,32'h9000_0000); c32("int_tval",ttval,0);
    // exception beats interrupt
    clr; idill=1; tkcond=1; #1; c("exc_beats_int",is_int,0); c32("exc_beats_int_cause",tcause,32'd2);
    // MRET: redirect to mepc, mret pulse, no trap_enter
    clr; idsys=1; idinstr=32'h30200073; mepc=32'h4444; #1;
      c("mret_pulse",mret,1); c("mret_no_enter",trap_en,0); c32("mret_target",trtgt,32'h4444); c("mret_redir",tr_rv,1);
    if(errors==0)$display("TRAP_CTRL SMOKE: ALL CHECKS PASSED");
    else $display("TRAP_CTRL SMOKE: %0d FAILURE(S)",errors);
    $finish;
  end
endmodule
