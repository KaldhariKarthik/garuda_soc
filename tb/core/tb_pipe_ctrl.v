`timescale 1ns/1ps
module tb_pipe_ctrl;
  integer errors=0;
  reg mem_stall, dsu_busy, load_use, wfi_hold;
  reg idv, exr, trv, sq_ide, sq_exm, sq_mwb;
  reg [31:0] idt, ext, trt;
  wire if_stall, if_redir; wire [31:0] if_rpc;
  wire ifid_s, ifid_f, idex_s, idex_f, exmem_s, exmem_f, memwb_f;
  pipe_ctrl u(.mem_stall_i(mem_stall),.dsu_busy_i(dsu_busy),.load_use_stall_i(load_use),.wfi_hold_i(wfi_hold),
    .id_redirect_valid_i(idv),.id_redirect_target_i(idt),
    .ex_redirect_i(exr),.ex_redirect_target_i(ext),
    .trap_redirect_valid_i(trv),.trap_redirect_target_i(trt),
    .trap_squash_id_ex_i(sq_ide),.trap_squash_ex_mem_i(sq_exm),.trap_squash_mem_wb_i(sq_mwb),
    .if_stall_o(if_stall),.if_redirect_o(if_redir),.if_redirect_pc_o(if_rpc),
    .if_id_stall_o(ifid_s),.if_id_flush_o(ifid_f),
    .id_ex_stall_o(idex_s),.id_ex_flush_o(idex_f),
    .ex_mem_stall_o(exmem_s),.ex_mem_flush_o(exmem_f),.mem_wb_flush_o(memwb_f));

  // packed order: {if_stall,if_redir, ifid_s,ifid_f, idex_s,idex_f, exmem_s,exmem_f, memwb_f}
  wire [8:0] obs = {if_stall,if_redir,ifid_s,ifid_f,idex_s,idex_f,exmem_s,exmem_f,memwb_f};
  task chk(input [255:0] name, input [8:0] exp);
    begin
      if (obs !== exp) begin
        $display("FAIL %0s: obs=%b exp=%b",name,obs,exp); errors=errors+1;
      end
    end
  endtask
  task chkpc(input [255:0] name, input [31:0] exp);
    begin if (if_rpc!==exp) begin $display("FAIL %0s pc: got %h exp %h",name,if_rpc,exp); errors=errors+1; end end
  endtask

  initial begin
    {mem_stall,dsu_busy,load_use,wfi_hold,idv,exr,trv,sq_ide,sq_exm,sq_mwb}=0;
    idt=32'h1111; ext=32'h2222; trt=32'h3333;
    //                                     ifS ifR ifidS ifidF idexS idexF exmS exmF mwbF
    #1 chk("idle",                    9'b0_0_0_0_0_0_0_0_0);
    load_use=1; #1 chk("load_use",    9'b1_0_1_0_0_1_0_0_0); load_use=0;
    dsu_busy=1; #1 chk("dsu_busy",    9'b1_0_1_0_1_0_0_0_0); dsu_busy=0;
    // WFI (Sec.14.5) is drain-precise: holds PC, IF/ID AND ID/EX so the WFI
    // parks in EX and the younger instr stays in ID, while EX/MEM stays free
    // to let everything older than the WFI drain out.
    wfi_hold=1; #1 chk("wfi_hold",    9'b1_0_1_0_1_0_0_0_0); wfi_hold=0;
    mem_stall=1;#1 chk("dport_wait",  9'b1_0_1_0_1_0_1_0_1); mem_stall=0;
    idv=1;      #1 chk("id_redir_1b", 9'b0_1_0_1_0_0_0_0_0); chkpc("id_redir",32'h1111); idv=0;
    exr=1;      #1 chk("ex_redir_2b", 9'b0_1_0_1_0_1_0_0_0); chkpc("ex_redir",32'h2222);
    idv=1;      #1 chk("ex_over_id",  9'b0_1_0_1_0_1_0_0_0); chkpc("ex>id",32'h2222);
    trv=1;      #1 chk("trap_over_ex",9'b0_1_0_1_0_1_0_0_0); chkpc("trap>ex",32'h3333);
    idv=0; exr=0; trv=0;
    mem_stall=1; exr=1; #1 chk("redir_gated_wait", 9'b1_0_1_0_1_0_1_0_1);
    mem_stall=0;        #1 chk("redir_after_wait", 9'b0_1_0_1_0_1_0_0_0); exr=0;
    sq_mwb=1; #1 chk("squash_memwb", 9'b0_0_0_0_0_0_0_0_1); sq_mwb=0;
    sq_exm=1; #1 chk("squash_exmem", 9'b0_0_0_0_0_0_0_1_0); sq_exm=0;
    sq_ide=1; #1 chk("squash_idex",  9'b0_0_0_0_0_1_0_0_0); sq_ide=0;

    if(errors==0) $display("PIPE_CTRL SMOKE: ALL CHECKS PASSED");
    else $display("PIPE_CTRL SMOKE: %0d FAILURE(S)",errors);
    $finish;
  end
endmodule
