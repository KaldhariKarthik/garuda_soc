`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - tb_boot.v
// Minimal boot testbench: core + dual-ported AHB memory model.
//
// This is the first testbench in the project that runs REAL INSTRUCTIONS
// through the whole pipeline. Everything before it drove stage inputs by hand.
//
// Plusargs:
//   +HEX=<path>        memory image, $readmemh format, word-per-line,
//                      word 0 == BASE_ADDR (0x1000_0000, the reset vector)
//   +COMMIT=<path>     write the commit log here (default: commit.log)
//   +MAXCYC=<n>        cycle timeout (default 200000)
//   +MAXINSTR=<n>      stop after n retirements (default: run to tohost/timeout)
//   +TOHOST=<hex>      tohost byte address (default 0x1000F000)
//   +IWAIT=<n>/+DWAIT=<n>  inject AHB wait states on the I/D port
//   +QUIET             suppress per-instruction commit lines on stdout
//
// Exit protocol (riscv-tests convention):
//   write 1        to tohost -> PASS
//   write (n<<1)|1 to tohost -> FAIL, test number n
//
// COMMIT LOG PROBE
// ----------------
// The core carries no PC past EX/MEM, so WB has a retire tag (mw_retire) but
// no PC to attach it to. Rather than add a trace port to mem_wb_reg, the TB
// shadows it: mem_wb_reg has no hold path (see its header - bubble-on-wait,
// never hold), so a single register clocked with the identical flush term
// tracks em_pc through MEM/WB exactly. If mem_wb_reg ever gains a hold, this
// shadow silently desynchronises - the assertion below catches that.
// =============================================================================

module tb_boot;

    // ---------------- parameters / plusargs ----------------
    localparam [31:0] BASE_ADDR  = 32'h1000_0000;
    localparam integer SIZE_B    = 32'h0004_0000;   // 256 KB

    reg [1023:0] hexfile;
    reg [1023:0] commitfile;
    integer      maxcyc, maxinstr, iwait, dwait;
    reg [31:0]   tohost_addr;
    reg          quiet;

    integer      fh_commit;
    integer      cyc, ninstr;
    integer      exit_code;

    // ---------------- clock / reset ----------------
    reg clk, rst_n;
    initial clk = 1'b0;
    always #2.5 clk = ~clk;          // 200 MHz core domain

    // ---------------- DUT wiring ----------------
    wire [31:0] i_haddr, i_hwdata, i_hrdata;
    wire [1:0]  i_htrans;
    wire [2:0]  i_hsize, i_hburst;
    wire [3:0]  i_hprot;
    wire        i_hwrite, i_hready, i_hresp;

    wire [31:0] d_haddr, d_hwdata, d_hrdata;
    wire [1:0]  d_htrans;
    wire [2:0]  d_hsize, d_hburst;
    wire [3:0]  d_hprot;
    wire        d_hwrite, d_hready, d_hresp;

    wire [47:0] dbg_acc0, dbg_acc1, dbg_acc2;

    garuda_core_top #(.RESET_VECTOR(BASE_ADDR)) dut (
        .clk_i(clk), .rst_n_i(rst_n),
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
        .i_hburst_o(i_hburst), .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite),
        .i_hwdata_o(i_hwdata), .i_hrdata_i(i_hrdata), .i_hready_i(i_hready),
        .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
        .d_hburst_o(d_hburst), .d_hprot_o(d_hprot), .d_hwrite_o(d_hwrite),
        .d_hwdata_o(d_hwdata), .d_hrdata_i(d_hrdata), .d_hready_i(d_hready),
        .d_hresp_i(d_hresp),
        .clic_irq_i(1'b0), .clic_irq_id_i(12'd0), .clic_irq_lvl_i(8'd0),
        .clic_irq_shv_i(1'b0), .clic_irq_ack_o(), .clic_irq_id_ack_o(),
        .clic_mintthresh_o(),
        .mtime_i(64'd0), .mtimecmp_i(64'hFFFF_FFFF_FFFF_FFFF),
        .dbg_acc_0_o(dbg_acc0), .dbg_acc_1_o(dbg_acc1), .dbg_acc_2_o(dbg_acc2)
    );

    ahb_mem_slave #(
        .BASE_ADDR(BASE_ADDR), .SIZE_BYTES(SIZE_B)
    ) u_mem (
        .clk_i(clk), .rst_n_i(rst_n),
        .i_waits_i(iwait[7:0]), .d_waits_i(dwait[7:0]),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hsize_i(i_hsize),
        .i_hwrite_i(i_hwrite), .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hsize_i(d_hsize),
        .d_hwrite_i(d_hwrite), .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp)
    );

    // =========================================================================
    // Commit-log probe
    // =========================================================================
    reg [31:0] shadow_pc_wb;
    reg        shadow_v_wb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shadow_pc_wb <= 32'h0;
            shadow_v_wb  <= 1'b0;
        end else if (dut.pc_mwb_f) begin      // identical flush term to mem_wb_reg
            shadow_pc_wb <= 32'h0;
            shadow_v_wb  <= 1'b0;
        end else begin
            shadow_pc_wb <= dut.em_pc;
            shadow_v_wb  <= dut.em_valid;
        end
    end

    // If a retirement ever arrives without the shadow believing an instruction
    // was there, the shadow has desynchronised from mem_wb_reg - stop rather
    // than emit a commit log that silently lies about PCs.
    always @(posedge clk) begin
        if (rst_n && dut.mw_retire && !shadow_v_wb) begin
            $display("FATAL: commit-log shadow desync at cycle %0d - mem_wb_reg",
                     cyc, " gained a hold path? See tb_boot.v header.");
            $fclose(fh_commit);
            $finish;
        end
    end

    // Canonical commit line:  <pc> <rd> <wdata>
    // rd=00 / wdata=00000000 for instructions with no architectural GPR write.
    // The instruction word is deliberately absent: PC plus the memory image
    // determines it, and carrying it would need another trace port.
    always @(posedge clk) begin
        if (rst_n && dut.mw_retire) begin
            ninstr = ninstr + 1;
            if (dut.mw_reg_write && (dut.mw_rd != 5'd0)) begin
                $fwrite(fh_commit, "%08x %02d %08x\n",
                        shadow_pc_wb, dut.mw_rd, dut.mw_data);
                if (!quiet)
                    $display("[C] %08x x%0d=%08x", shadow_pc_wb, dut.mw_rd, dut.mw_data);
            end else begin
                $fwrite(fh_commit, "%08x %02d %08x\n", shadow_pc_wb, 0, 0);
                if (!quiet)
                    $display("[C] %08x", shadow_pc_wb);
            end

            if (maxinstr > 0 && ninstr >= maxinstr) begin
                $display("\ntb_boot: reached +MAXINSTR=%0d retirements", maxinstr);
                finish_sim(0);
            end
        end
    end

    // =========================================================================
    // tohost monitor - watches the D-port write as it completes on the bus
    // =========================================================================
    reg [31:0] tohost_val;
    always @(posedge clk) begin
        if (rst_n && u_mem.b_dv && u_mem.b_dw && u_mem.d_hready_o &&
            (u_mem.b_da == tohost_addr) && (d_hwdata != 32'h0)) begin
            tohost_val = d_hwdata;
            if (tohost_val == 32'h1) begin
                $display("\n*** TOHOST=1 -> PASSED (%0d instructions retired) ***", ninstr);
                finish_sim(0);
            end else begin
                $display("\n*** TOHOST=%08x -> FAILED (test %0d, %0d retired) ***",
                         tohost_val, tohost_val >> 1, ninstr);
                finish_sim(1);
            end
        end
    end

    task finish_sim;
        input integer code;
        begin
            $fflush(fh_commit);
            $fclose(fh_commit);
            exit_code = code;
            $finish;
        end
    endtask

    // =========================================================================
    // Main
    // =========================================================================
    initial begin
        cyc = 0; ninstr = 0; exit_code = 0;
        if (!$value$plusargs("MAXCYC=%d", maxcyc))     maxcyc   = 200000;
        if (!$value$plusargs("MAXINSTR=%d", maxinstr)) maxinstr = 0;
        if (!$value$plusargs("IWAIT=%d", iwait))       iwait    = 0;
        if (!$value$plusargs("DWAIT=%d", dwait))       dwait    = 0;
        if (!$value$plusargs("TOHOST=%h", tohost_addr))tohost_addr = 32'h1000_F000;
        quiet = $test$plusargs("QUIET");

        if (!$value$plusargs("COMMIT=%s", commitfile)) commitfile = "commit.log";
        fh_commit = $fopen(commitfile, "w");
        if (fh_commit == 0) begin
            $display("FATAL: cannot open commit log"); $finish;
        end

        if (!$value$plusargs("HEX=%s", hexfile)) begin
            $display("FATAL: tb_boot requires +HEX=<image>"); $finish;
        end
        $readmemh(hexfile, u_mem.mem);
        $display("tb_boot: image=%0s  reset=%08x  tohost=%08x", hexfile, BASE_ADDR, tohost_addr);

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("tb_boot: reset released, fetching from %08x", BASE_ADDR);
    end

    always @(posedge clk) begin
        cyc = cyc + 1;
        if (cyc > maxcyc) begin
            $display("\n*** TIMEOUT after %0d cycles (%0d retired) - FAILED ***",
                     maxcyc, ninstr);
            finish_sim(2);
        end
    end

    // Bring-up probe: +DBGBUS traces the fetch path cycle by cycle. Kept in
    // the TB (not deleted after first bring-up) because every future "core
    // fetches nothing" failure starts by looking at exactly these signals.
    always @(posedge clk) begin
        if (rst_n && $test$plusargs("DBGBUS") && cyc < 60) begin
            $display("c%0d ITRANS=%b IADDR=%08x IRD=%08x IRDY=%b | ifv=%b ifpc=%08x | fdv=%b fdpc=%08x | idv=%b xev=%b emv=%b ret=%b | ifstall=%b redir=%b",
                     cyc, i_htrans, i_haddr, i_hrdata, i_hready,
                     dut.if_valid, dut.if_pc, dut.fd_valid, dut.fd_pc,
                     dut.id_valid, dut.xe_valid, dut.em_valid, dut.mw_retire,
                     dut.pc_if_stall, dut.pc_if_redir);
            $display("     ifinstr=%08x fdinstr=%08x idinstr=%08x  op=%07b f3=%03b",
                     dut.if_instr, dut.fd_instr, dut.id_instr,
                     dut.fd_instr[6:0], dut.fd_instr[14:12]);
        end
        if (rst_n && $test$plusargs("DBGD")) begin
            if (d_htrans[1])
                $display("c%0d DADDR: addr=%08x wr=%b size=%b", cyc, d_haddr, d_hwrite, d_hsize);
            if (u_mem.b_dv && d_hready)
                $display("c%0d DDATA: addr=%08x wr=%b wdata=%08x rdata=%08x",
                         cyc, u_mem.b_da, u_mem.b_dw, d_hwdata, d_hrdata);
        end
        if (rst_n && $test$plusargs("DBGACC") && cyc < 45) begin
            $display("c%0d ACC: acc0=%012x acc1=%012x | xe_pc=%08x dsu_en=%b dsu_busy=%b idex_s=%b",
                     cyc, dbg_acc0, dbg_acc1, dut.xe_pc, dut.xe_dsu_en,
                     dut.ex_dsu_busy, dut.pc_idex_s);
        end
        if (rst_n && $test$plusargs("DBGM") && cyc < 40) begin
            $display("c%0d MEM: em_pc=%08x em_v=%b memrd=%b memwr=%b | dstate=%d start=%b hready=%b memstall=%b | mwb_f=%b mw_ret=%b mw_rd=%02d mw_data=%08x",
                     cyc, dut.em_pc, dut.em_valid, dut.em_mem_read, dut.em_mem_write,
                     dut.u_mem.u_d_port_ahb_master.state, dut.u_mem.u_d_port_ahb_master.start_i, d_hready,
                     dut.mem_stall, dut.pc_mwb_f, dut.mw_retire, dut.mw_rd, dut.mw_data);
        end
        if (rst_n && $test$plusargs("DBGTRAP") && cyc < 60) begin
            $display("c%0d TRAP: enter=%b cause=%08x tpc=%08x redir=%b tgt=%08x | id_ill=%b xe_ill=%b dsu_ill=%b dsu_busy=%b lmis=%b smis=%b memexc=%b | exredir=%b extgt=%08x",
                     cyc, dut.tr_enter, dut.tr_cause, dut.tr_pc, dut.tr_redir_v, dut.tr_redir_t,
                     dut.id_illegal, dut.xe_illegal, dut.ex_dsu_illegal, dut.ex_dsu_busy,
                     dut.ex_load_mis, dut.ex_store_mis, dut.mem_exc_v,
                     dut.ex_redirect, dut.ex_redirect_target);
        end
    end

    initial begin
        if ($test$plusargs("WAVES")) begin
            $shm_open("waves.shm");
            $shm_probe(tb_boot, "AS");
        end
    end

endmodule

`default_nettype wire
