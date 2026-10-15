`timescale 1ns/1ps
`default_nettype none
// -----------------------------------------------------------------------------
// Track A P0.8 changes (behaviour of every existing plusarg unchanged):
//  * exit status: a failing verdict (TOHOST fail, TIMEOUT, AHB violation) ends
//    with $fatal(1), so the simulator's exit code tells the truth (TOOL-13);
//  * $shm_open/$shm_probe compiled only for Cadence (no shim needed elsewhere);
//  * TEST DEVICE: software-driven interrupt and timer events, so interrupt
//    tests are deterministic and need no per-test plusargs. Completed D-port
//    word writes to (all inside the scratch area next to TOHOST):
//      0x1000_F200 IRQ_SET   [4:0] id, [15:8] level: raise a CLIC request, held
//                            until software clears it (a real peripheral)
//      0x1000_F204 IRQ_CLR   drop the request
//      0x1000_F208 MTIP      [0]: machine-timer interrupt pending (set/clear)
//      0x1000_F20C IRQ_ARM   N: raise the STAGED request after N more retired
//                            instructions (deterministic timing)
//      0x1000_F210 IRQ_STAGE [4:0] id, [15:8] level of the staged request
//      0x1000_F214 IRQ_ARMC  N: raise the STAGED request N cycles from now
//                            (for wake-from-WFI tests: nothing retires while asleep)
//    The device ORs with the plusarg-driven sources (+IRQ_AT, +MTIP_AT ...).
// -----------------------------------------------------------------------------
// =============================================================================
// GARUDA SoC - tb_boot.sv  (SystemVerilog since 2026-10-11, Track A P0.8; was tb_boot.v)
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
//   +NO_AHBCHK_FATAL   demote AHB-Lite protocol violations to advisory.
//                      Violations FAIL the test by default (BUS-A/B/C/D are
//                      fixed). The checkers ALWAYS run and always report;
//                      this only controls the verdict. See finish_sim.
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
//
// STORE, CSR AND TRAP RECORDS (commit log version 2)
// -------------------------------------------------
// Besides one line per retired instruction, the log carries three kinds of
// record, each written when the event happens:
//   MEM  <addr> <bytes> <data>   a data-port write that completed with OKAY
//   CSR  <addr> <value>          a CSR instruction left EX; value is what the
//                                CSR holds afterwards ("--------" if this
//                                bench has no view of that CSR)
//   TRAP <cause> <epc> <tval>    a trap was taken
// A store completes one cycle before its instruction retires and a CSR
// instruction acts two cycles before, so these records come BEFORE their
// instruction's own line. tools/lockstep.py compares each kind as an ordered
// stream against what Spike logs for the same program.
// =============================================================================

module tb_boot;

    // ---------------- parameters / plusargs ----------------
    localparam [31:0] BASE_ADDR  = 32'h1000_0000;
`ifdef GARUDA_TB_MEM2M
    localparam integer SIZE_B    = 32'h0020_0000;   // 2 MiB: riscv-arch-test (jal-01 alone is 1.7 MiB)
`else
    localparam integer SIZE_B    = 32'h0004_0000;   // 256 KB
`endif

    reg [4095:0] hexfile;
    reg [4095:0] commitfile;
    reg [4095:0] covtag;
    integer      maxcyc, maxinstr, iwait, dwait;
    integer      dbgfrom, dbgto;
    integer      irq_at, irq_id, irq_lvl, irq_shv, irq_every, seed;
    integer      irq_sweep;
    integer      irand, drand;
    integer      err_en; reg [31:0] err_base, err_size;
    reg [31:0]   tohost_addr;
    reg          quiet;
    reg          ahbchk_fatal;   // protocol violations fail the test (default 1)

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

    // ---------------- CLIC interrupt injection (Core Sanity rows 18/20) -----
    // The interrupt is asserted at +IRQ_AT and HELD until the core acknowledges
    // it, which is what the CLIC handshake requires - a one-cycle pulse would
    // be legal to drop and the test would silently prove nothing. +IRQ_EVERY
    // re-arms it periodically so a single run can hit many different offsets
    // into a loop rather than one fixed point in the instruction stream.
    // Rev 4.0: the CLIC interface is level-triggered with no acknowledge. The
    // testbench models a source that its handler clears by retiring the take:
    // it drops the request on the core's own take strobe (whitebox), which is
    // what a peripheral cleared by the ISR looks like from the core's side.
    reg  irq_req;
    wire irq_ack = dut.clic_take;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) irq_req <= 1'b0;
        else if (irq_ack) irq_req <= 1'b0;
        else if (irq_at  > 0 && cyc == irq_at) irq_req <= 1'b1;
        else if (irq_every > 0 && (cyc % irq_every) == 0 && cyc > 0) irq_req <= 1'b1;
    end

    // ---- +IRQ_SWEEP: vary id / level / shv on every interrupt --------------
    // clic_ctrl reads 12-bit id, 8-bit level and two 32-bit vector bases. With
    // one fixed interrupt configuration those buses never change, so toggle
    // coverage sat at 15/269 bins even though the take/ack logic was exercised.
    // The patterns are complementary pairs (0x000/0xFFF, 0x55/0xAA ...) so every
    // bit toggles in BOTH directions within a couple of interrupts rather than
    // needing 4096 of them.
    reg [3:0] sweep_ix;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)            sweep_ix <= 4'd0;
        else if (irq_ack)      sweep_ix <= sweep_ix + 4'd1;
    end

    wire [4:0]  sweep_id  = (sweep_ix == 4'd0) ? 5'h01 :
                            (sweep_ix == 4'd1) ? 5'h1F :
                            (sweep_ix == 4'd2) ? 5'h15 :
                            (sweep_ix == 4'd3) ? 5'h0A :
                            (sweep_ix == 4'd4) ? 5'h01 :
                            (sweep_ix == 4'd5) ? 5'h1E :
                            (sweep_ix == 4'd6) ? 5'h10 : 5'h0F;
    // Levels stay high enough to beat mintthresh/mil most of the time, but the
    // low ones deliberately fail the take condition so both arms of each
    // comparison are covered.
    wire [7:0]  sweep_lvl = (sweep_ix == 4'd0) ? 8'hFF :
                            (sweep_ix == 4'd1) ? 8'h55 :
                            (sweep_ix == 4'd2) ? 8'hAA :
                            (sweep_ix == 4'd3) ? 8'h01 :
                            (sweep_ix == 4'd4) ? 8'hFE :
                            (sweep_ix == 4'd5) ? 8'h80 :
                            (sweep_ix == 4'd6) ? 8'h7F : 8'hFF;

    wire [4:0]  irq_id_eff  = irq_sweep[0] ? sweep_id  : irq_id[4:0];
    wire [7:0]  irq_lvl_eff = irq_sweep[0] ? sweep_lvl : irq_lvl[7:0];
    // shv alternates with the sweep. It was briefly disabled here while SHV
    // interrupts appeared to corrupt mepc - that turned out to be ERRATUM T-4
    // (an interrupt taken on a pipeline bubble latched mepc = 0), not the SHV
    // memory model. SHV arrives at arbitrary points in the instruction stream
    // so it hit that window far more often than the fixed-offset t_irq ever
    // did. With T-4 fixed, SHV vectoring through a jump table works, which
    // also settles clic_ctrl.v's open question in favour of the
    // jump-instruction interpretation: that is what the RTL implements and it
    // is now demonstrated end to end.
    // (SHV vectoring was removed in Rev 4.0 - every trap enters at mtvec.)

    // ---- machine timer stand-in: +MTIP_AT=<cyc> raises mtip until the core
    // takes the timer trap (cause 0x8000_0007). Tied low otherwise.
    integer mtip_at;
    reg     mtip;
    wire    core_sleep;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) mtip <= 1'b0;
        else if (dut.tr_enter && dut.tr_cause == 32'h8000_0007) mtip <= 1'b0;
        // software "advances mtimecmp": a store to 0x1000_F100 drops mtip
        else if (d_htrans[1] && d_hwrite && d_hready && d_haddr == 32'h1000_F100) mtip <= 1'b0;
        else if (mtip_at > 0 && cyc == mtip_at) mtip <= 1'b1;
    end
    // ---- TEST DEVICE (P0.8): see the header -----------------------------------
    localparam [31:0] DEV_IRQ_SET = 32'h1000_F200, DEV_IRQ_CLR = 32'h1000_F204,
                      DEV_MTIP    = 32'h1000_F208, DEV_IRQ_ARM = 32'h1000_F20C,
                      DEV_IRQ_STG = 32'h1000_F210, DEV_IRQ_ARMC = 32'h1000_F214;
    reg        dev_irq_req, dev_mtip, dev_armed, dev_armed_c;
    integer    dev_arm_cyc;
    reg [4:0]  dev_irq_id, dev_stg_id;
    reg [7:0]  dev_irq_lvl, dev_stg_lvl;
    integer    dev_arm_at;
    wire       dev_wr = rst_n && u_mem.b_dv && u_mem.b_dw && u_mem.d_hready_o;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dev_irq_req <= 1'b0; dev_mtip <= 1'b0; dev_armed <= 1'b0; dev_armed_c <= 1'b0; dev_arm_cyc <= 0;
            dev_irq_id <= 5'd0; dev_irq_lvl <= 8'd0; dev_stg_id <= 5'd0; dev_stg_lvl <= 8'd0;
            dev_arm_at <= 0;
        end else begin
            if (dev_armed && ninstr >= dev_arm_at) begin
                dev_irq_req <= 1'b1; dev_irq_id <= dev_stg_id; dev_irq_lvl <= dev_stg_lvl;
                dev_armed   <= 1'b0;
            end
            // IRQ_ARMC: the same, counted in CYCLES (retirement stops while the
            // core sleeps in WFI, so a wake-up test cannot use IRQ_ARM)
            if (dev_armed_c && cyc >= dev_arm_cyc) begin
                dev_irq_req <= 1'b1; dev_irq_id <= dev_stg_id; dev_irq_lvl <= dev_stg_lvl;
                dev_armed_c <= 1'b0;
            end
            if (dev_wr) begin
                case (u_mem.b_da)
                    DEV_IRQ_SET: begin dev_irq_req <= 1'b1; dev_irq_id <= d_hwdata[4:0]; dev_irq_lvl <= d_hwdata[15:8]; end
                    DEV_IRQ_CLR: dev_irq_req <= 1'b0;
                    DEV_MTIP:    dev_mtip    <= d_hwdata[0];
                    DEV_IRQ_STG: begin dev_stg_id <= d_hwdata[4:0]; dev_stg_lvl <= d_hwdata[15:8]; end
                    DEV_IRQ_ARM: begin dev_armed <= 1'b1; dev_arm_at <= ninstr + d_hwdata; end
                    DEV_IRQ_ARMC: begin dev_armed_c <= 1'b1; dev_arm_cyc <= cyc + d_hwdata; end
                    default: ;
                endcase
            end
        end
    end

    integer sleep_cycles;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) sleep_cycles <= 0; else if (core_sleep) sleep_cycles <= sleep_cycles + 1;

    garuda_core_top #(.RESET_VECTOR(BASE_ADDR)) dut (
        .clk_i(clk), .core_rst_n_i(rst_n), .hartreset_n_i(1'b1),
        .halt_req_i(1'b0), .halt_safe_o(),             // no debugger here (RDC-1 ports)
        .i_haddr_o(i_haddr), .i_htrans_o(i_htrans), .i_hsize_o(i_hsize),
        .i_hburst_o(i_hburst), .i_hprot_o(i_hprot), .i_hwrite_o(i_hwrite),
        .i_hwdata_o(i_hwdata), .i_hrdata_i(i_hrdata), .i_hready_i(i_hready),
        .i_hresp_i(i_hresp),
        .d_haddr_o(d_haddr), .d_htrans_o(d_htrans), .d_hsize_o(d_hsize),
        .d_hburst_o(d_hburst), .d_hprot_o(d_hprot), .d_hwrite_o(d_hwrite),
        .d_hwdata_o(d_hwdata), .d_hrdata_i(d_hrdata), .d_hready_i(d_hready),
        .d_hresp_i(d_hresp),
        .clic_irq_valid_i(irq_req | dev_irq_req),
        .clic_irq_id_i(dev_irq_req ? dev_irq_id : irq_id_eff),
        .clic_irq_level_i(dev_irq_req ? dev_irq_lvl : irq_lvl_eff),
        .mtip_i(mtip | dev_mtip),
        .dbg_acc_0_o(dbg_acc0), .dbg_acc_1_o(dbg_acc1), .dbg_acc_2_o(dbg_acc2),
        .dsu_ovf_o(), .core_sleep_o(core_sleep)
    );

    ahb_mem_slave #(
        .BASE_ADDR(BASE_ADDR), .SIZE_BYTES(SIZE_B)
    ) u_mem (
        .clk_i(clk), .rst_n_i(rst_n),
        .i_waits_i(iwait[7:0]), .d_waits_i(dwait[7:0]),
        .i_rand_i(irand[0]), .d_rand_i(drand[0]),
        .err_en_i(err_en[0]), .err_base_i(err_base), .err_size_i(err_size),
        .i_haddr_i(i_haddr), .i_htrans_i(i_htrans), .i_hsize_i(i_hsize),
        .i_hwrite_i(i_hwrite), .i_hwdata_i(i_hwdata),
        .i_hrdata_o(i_hrdata), .i_hready_o(i_hready), .i_hresp_o(i_hresp),
        .d_haddr_i(d_haddr), .d_htrans_i(d_htrans), .d_hsize_i(d_hsize),
        .d_hwrite_i(d_hwrite), .d_hwdata_i(d_hwdata),
        .d_hrdata_o(d_hrdata), .d_hready_o(d_hready), .d_hresp_o(d_hresp)
    );

    // =========================================================================
    // AHB-Lite protocol checkers -- one per master port, passive
    //
    // These exist because u_mem is a FUNCTIONAL model, not a protocol model:
    // it services every transfer as an independent SINGLE and does not even
    // have an HBURST port.  That means burst-protocol violations were
    // invisible to every test in the suite, indefinitely, while all of them
    // passed.  The checker is a separate passive observer for exactly that
    // reason -- it cannot be satisfied by the model it sits next to.
    //
    // Wired into the PLAIN filelist, so every existing test checks protocol
    // from now on at no extra stimulus cost.
    // =========================================================================
    wire [31:0] i_viol, d_viol;

    ahb_lite_checker u_ichk (
        .clk_i(clk), .rst_n_i(rst_n),
        .haddr_i(i_haddr), .htrans_i(i_htrans), .hsize_i(i_hsize),
        .hburst_i(i_hburst), .hwrite_i(i_hwrite), .hwdata_i(i_hwdata),
        .hready_i(i_hready), .hresp_i(i_hresp), .viol_count_o(i_viol)
    );

    ahb_lite_checker u_dchk (
        .clk_i(clk), .rst_n_i(rst_n),
        .haddr_i(d_haddr), .htrans_i(d_htrans), .hsize_i(d_hsize),
        .hburst_i(d_hburst), .hwrite_i(d_hwrite), .hwdata_i(d_hwdata),
        .hready_i(d_hready), .hresp_i(d_hresp), .viol_count_o(d_viol)
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

`ifdef GARUDA_COSIM
    // =========================================================================
    // Spike co-simulation (plan 5.2 / 5.3, tools/cosim/garuda_cosim.cc): one
    // DPI step per RVFI record; interrupts the RTL takes are queued and applied
    // to Spike from the spec when the handler's first instruction arrives.
    // =========================================================================
    import "DPI-C" function int  garuda_cosim_init(input string hexfile, input int base, input int size,
                                                    input int err_en, input int err_base, input int err_size);
    import "DPI-C" function void garuda_cosim_reset();
    import "DPI-C" function void garuda_cosim_interrupt(input int cause, input int level, input int thresh);
    import "DPI-C" function int  garuda_cosim_step(input int pc, input int insn, input int trap, input int intr,
                                                    input int npc, input int rd, input int rd_wdata,
                                                    input int mem_addr, input int mem_wmask, input int mem_wdata);
    import "DPI-C" function void garuda_cosim_report();
    import "DPI-C" function int  garuda_cosim_mismatches();
    // +COSIM_NEGCTL=<kind>: negative controls (plan: the co-simulation must
    // catch each of these): rd, store, pc, trap, irq_drop, irq_extra. One
    // corruption, on the first record / event it applies to.
    reg [8*16-1:0] negctl;
    reg            neg_done;
    initial begin
        if (!$value$plusargs("COSIM_NEGCTL=%s", negctl)) negctl = "";
        neg_done = 1'b0;
    end
    reg [31:0] cs_rdw, cs_wd, cs_pc;
    reg        cs_trap;
    always @(posedge clk)
        if (rst_n && dut.tr_enter && dut.tr_is_int) begin
            if (negctl == "irq_drop" && !neg_done) neg_done = 1'b1;              // the RTL's interrupt is lost
            else begin
                garuda_cosim_interrupt(dut.tr_cause, {24'd0, dut.tr_level}, {24'd0, dut.csr_mintthresh});
                if (negctl == "irq_extra" && !neg_done) begin                 // a spurious second one
                    garuda_cosim_interrupt(dut.tr_cause, {24'd0, dut.tr_level}, {24'd0, dut.csr_mintthresh});
                    neg_done = 1'b1;
                end
            end
        end
    always @(posedge clk)
        if (rst_n && dut.rvfi_valid) begin
            cs_rdw = dut.rvfi_rd_wdata; cs_wd = dut.rvfi_mem_wdata; cs_pc = dut.rvfi_pc_rdata;
            cs_trap = dut.rvfi_trap;
            if (!neg_done) begin
                if (negctl == "rd" && dut.rvfi_rd_addr != 5'd0) begin cs_rdw = cs_rdw ^ 32'h1; neg_done = 1'b1; end
                if (negctl == "store" && dut.rvfi_mem_wmask != 4'd0) begin cs_wd = cs_wd ^ 32'h0101_0101; neg_done = 1'b1; end
                if (negctl == "pc" && dut.rvfi_order > 64'd20) begin cs_pc = cs_pc + 32'd4; neg_done = 1'b1; end
                if (negctl == "trap" && dut.rvfi_order > 64'd20 && !dut.rvfi_trap) begin cs_trap = 1'b1; neg_done = 1'b1; end
            end
            void'(garuda_cosim_step(cs_pc, dut.rvfi_insn, {31'd0, cs_trap},
                                    {31'd0, dut.rvfi_intr}, dut.rvfi_pc_wdata, {27'd0, dut.rvfi_rd_addr},
                                    cs_rdw, dut.rvfi_mem_addr, {28'd0, dut.rvfi_mem_wmask}, cs_wd));
        end
`endif

`ifdef GARUDA_RVFI
    // =========================================================================
    // RVFI log (plan 5.1): the same commit-log format, written from the core's
    // RVFI port instead of the probe above. tools/rvfi_check.py requires the
    // two logs to agree line for line (retirements and stores) and the trap
    // records to match the TRAP lines.
    // =========================================================================
    integer    fh_rvfi;
    reg [1023:0] rvfifile;
    initial begin
        if (!$value$plusargs("RVFI_LOG=%s", rvfifile)) rvfifile = "rvfi.log";
        fh_rvfi = $fopen(rvfifile, "w");
        $fwrite(fh_rvfi, "# garuda-rvfi-log 1\n");
    end
    integer    rv_b, rv_n;
    reg [31:0] rv_a, rv_d;
    always @(posedge clk)
        if (rst_n && dut.rvfi_valid) begin
            if (dut.rvfi_trap)
                $fwrite(fh_rvfi, "TRAPREC %08x %08x\n", dut.rvfi_pc_rdata, dut.rvfi_insn);
            else begin
                if (dut.rvfi_mem_wmask != 4'd0) begin
                    rv_b = dut.rvfi_mem_wmask[0] ? 0 : dut.rvfi_mem_wmask[1] ? 1 : dut.rvfi_mem_wmask[2] ? 2 : 3;
                    rv_n = dut.rvfi_mem_wmask[0] + dut.rvfi_mem_wmask[1] + dut.rvfi_mem_wmask[2] + dut.rvfi_mem_wmask[3];
                    rv_a = dut.rvfi_mem_addr + rv_b;
                    rv_d = dut.rvfi_mem_wdata >> (rv_b * 8);
                    $fwrite(fh_rvfi, "MEM %08x %0d %08x\n", rv_a, rv_n, rv_d);
                end
                $fwrite(fh_rvfi, "%08x %02d %08x\n", dut.rvfi_pc_rdata, dut.rvfi_rd_addr, dut.rvfi_rd_wdata);
            end
        end
`endif

    // =========================================================================
    // Store, CSR and trap records (see the header)
    // =========================================================================
    // data-port address phase, held for its data phase
    reg        dp_v, dp_w;
    reg [31:0] dp_a;
    reg [2:0]  dp_s;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) dp_v <= 1'b0;
        else if (d_hready) begin
            dp_v <= d_htrans[1]; dp_w <= d_hwrite; dp_a <= d_haddr; dp_s <= d_hsize;
        end
    // the bytes the store wrote, taken from their byte lanes
    wire [31:0] dp_lane = d_hwdata >> {dp_a[1:0], 3'b000};
    wire [31:0] dp_data = (dp_s == 3'd0) ? {24'd0, dp_lane[7:0]} :
                          (dp_s == 3'd1) ? {16'd0, dp_lane[15:0]} : dp_lane;
    always @(posedge clk)
        if (rst_n && dp_v && dp_w && d_hready && !d_hresp)
            $fwrite(fh_commit, "MEM %08x %0d %08x\n", dp_a, 1 << dp_s, dp_data);

    always @(posedge clk)
        if (rst_n && dut.tr_enter)
            $fwrite(fh_commit, "TRAP %08x %08x %08x\n", dut.tr_cause, dut.tr_pc, dut.tr_tval);

    // A CSR instruction acts in the cycle it leaves EX. Its CSR is read half a
    // cycle later, straight from the registers, so the record holds the value
    // after the instruction whether or not it wrote.
    reg        csr_pend;
    reg [11:0] csr_pa;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) csr_pend <= 1'b0;
        else begin
            csr_pend <= dut.ex_csr_en_out && dut.ex_commit && (dut.ex_csr_op_out != 2'b00) && !dut.csr_illegal;
            csr_pa   <= dut.ex_csr_addr_w;
        end
    reg [31:0] csr_v; reg csr_known;
    always @(negedge clk)
        if (rst_n && csr_pend) begin
            csr_known = 1'b1;
            case (csr_pa)
                12'h300: csr_v = dut.u_csr.mstatus_val;
                12'h301: csr_v = dut.u_csr.misa_val;
                12'h304: csr_v = dut.u_csr.mie_r;
                12'h305: csr_v = {dut.u_csr.mtvec_r[31:2], 2'b11};
                12'h340: csr_v = dut.u_csr.mscratch_r;
                12'h341: csr_v = dut.u_csr.mepc_r;
                12'h342: csr_v = dut.u_csr.mcause_r;
                12'h343: csr_v = dut.u_csr.mtval_r;
                12'h347: csr_v = {24'd0, dut.u_csr.mintthresh_r};
                default: begin csr_v = 32'd0; csr_known = 1'b0; end
            endcase
            if (csr_known) $fwrite(fh_commit, "CSR %03x %08x\n", csr_pa, csr_v);
            else           $fwrite(fh_commit, "CSR %03x --------\n", csr_pa);
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
                $display("\n*** TOHOST=1 -> PASSED (%0d instructions retired, %0d cycles clock-gated) ***", ninstr, sleep_cycles);
                $display("RUN-STATS: retired=%0d cycles=%0d", ninstr, cyc);   // throughput (P0.11)
                finish_sim(0);
            end else begin
                $display("\n*** TOHOST=%08x -> FAILED (test %0d, %0d retired) ***",
                         tohost_val, tohost_val >> 1, ninstr);
                finish_sim(1);
            end
        end
    end

    reg [4095:0] sigfile;
    reg [31:0]   sig_b, sig_e, sig_a;
    integer      fh_sig;
    task finish_sim;
        input integer code;
        begin
            // ---- AHB-Lite protocol verdict ---------------------------------
            // Always reported, on every run, pass or fail. It is deliberately
            // NOT possible to turn this off: the whole reason BUS-A/B/C
            // survived 63 passing ISA tests is that nobody was looking.
            //
            // A violation now FAILS the test. This default was advisory while
            // BUS-A/B/C were open, because a fatal default would have turned
            // the whole regression red and made a new functional regression
            // indistinguishable from the known protocol noise. BUS-A/B/C/D
            // are fixed and the I- and D-ports are clean across the ISA
            // regression, the wait-state and randomised-wait variants, the
            // sanity suite and a 20-configuration stall/redirect sweep, so
            // the reason to be advisory is gone -- and a checker whose
            // failures are permanently advisory decays back into decoration,
            // which is how BUS-A survived 63 passing tests in the first
            // place. +NO_AHBCHK_FATAL demotes it again if a future bring-up
            // genuinely needs to run against a known-dirty bus.
            u_ichk.report_result;
            u_dchk.report_result;
            $display("AHB-PROTOCOL: iport=%0d dport=%0d violations", i_viol, d_viol);
            if (((i_viol != 0) || (d_viol != 0)) && ahbchk_fatal && (code == 0)) begin
                $display("\n*** AHB PROTOCOL VIOLATIONS -> FAILED (use +NO_AHBCHK_FATAL to demote) ***");
                code = 3;
            end
`ifdef GARUDA_COSIM
            // ---- Spike co-simulation verdict (plan 5.2 / 5.3) -----------------
            garuda_cosim_report();
            if ((garuda_cosim_mismatches() != 0) && (code == 0)) begin
                $display("[FAIL] COSIM: %0d mismatch(es) against Spike", garuda_cosim_mismatches());
                $display("\n*** COSIM MISMATCH -> FAILED ***");
                code = 5;
            end
`endif

            // Functional coverage self-report, if the covergroups are bound in
            // (filelist_boot_cov.f). Guarded so the plain filelist still runs.
`ifdef GARUDA_COV
            dut.u_cov.report_coverage(covtag);
`endif
            $fflush(fh_commit);
            $fclose(fh_commit);
            // +SIGFILE / +SIGBEGIN / +SIGEND: riscv-arch-test signature (plan 5.4),
            // one 32-bit word per line, the format of spike +signature-granularity=4
            if ($value$plusargs("SIGFILE=%s", sigfile) && $value$plusargs("SIGBEGIN=%h", sig_b) &&
                $value$plusargs("SIGEND=%h", sig_e)) begin
                fh_sig = $fopen(sigfile, "w");
                for (sig_a = sig_b; sig_a < sig_e; sig_a = sig_a + 4)
                    $fwrite(fh_sig, "%08x\n", u_mem.mem[(sig_a - BASE_ADDR) >> 2]);
                $fclose(fh_sig);
            end
`ifdef GARUDA_RVFI
            $fflush(fh_rvfi);
            $fclose(fh_rvfi);
`endif
            exit_code = code;
            // P0.8 / TOOL-13: the exit status carries the verdict
            if (code != 0) $fatal(1, "tb_boot: FAILED (code %0d)", code);
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
        if (!$value$plusargs("IRQ_AT=%d",  irq_at))    irq_at    = 0;
        if (!$value$plusargs("IRQ_ID=%d",  irq_id))    irq_id    = 1;
        if (!$value$plusargs("IRQ_LVL=%d", irq_lvl))   irq_lvl   = 8'hFF;
        if (!$value$plusargs("IRQ_SHV=%d", irq_shv))   irq_shv   = 0;
        if (!$value$plusargs("IRQ_EVERY=%d", irq_every)) irq_every = 0;
        if (!$value$plusargs("IRQ_SWEEP=%d", irq_sweep))  irq_sweep = 0;
        if (!$value$plusargs("MTIP_AT=%d", mtip_at))      mtip_at   = 0;
        if (!$value$plusargs("IRAND=%d", irand))       irand     = 0;
        if (!$value$plusargs("DRAND=%d", drand))       drand     = 0;
        if (!$value$plusargs("ERR_EN=%d", err_en))     err_en    = 0;
        if (!$value$plusargs("ERR_BASE=%h", err_base)) err_base  = 32'h1002_0000;
        if (!$value$plusargs("ERR_SIZE=%h", err_size)) err_size  = 32'h0000_1000;
        if (!$value$plusargs("SEED=%d", seed))         seed      = 1;
        begin : seed_rng
            integer dummy;
            dummy = $random(seed);      // seed the wait-state RNG reproducibly
        end
        if (!$value$plusargs("DBGFROM=%d", dbgfrom))   dbgfrom  = 0;
        if (!$value$plusargs("DBGTO=%d", dbgto))       dbgto    = 60;
        if (!$value$plusargs("IWAIT=%d", iwait))       iwait    = 0;
        if (!$value$plusargs("DWAIT=%d", dwait))       dwait    = 0;
        if (!$value$plusargs("TOHOST=%h", tohost_addr))tohost_addr = 32'h1000_F000;
        quiet = $test$plusargs("QUIET");
        ahbchk_fatal = !$test$plusargs("NO_AHBCHK_FATAL");

        if (!$value$plusargs("COVTAG=%s", covtag)) covtag = "run";
        if (!$value$plusargs("COMMIT=%s", commitfile)) commitfile = "commit.log";
        fh_commit = $fopen(commitfile, "w");
        if (fh_commit == 0) begin
            $fatal(1, "tb_boot: cannot open commit log");
        end
        $fwrite(fh_commit, "# garuda-commit-log 2\n");

        if (!$value$plusargs("HEX=%s", hexfile)) begin
            $fatal(1, "tb_boot: requires +HEX=<image>");
        end
        $readmemh(hexfile, u_mem.mem);
        $display("tb_boot: image=%0s  reset=%08x  tohost=%08x", hexfile, BASE_ADDR, tohost_addr);
`ifdef GARUDA_COSIM
        if (garuda_cosim_init($sformatf("%0s", hexfile), BASE_ADDR, SIZE_B, err_en, err_base, err_size) != 0)
            $fatal(1, "tb_boot: cosim init failed");
`endif

        rst_n = 1'b0;
        repeat (5) @(posedge clk);
        rst_n = 1'b1;
        $display("tb_boot: reset released, fetching from %08x", BASE_ADDR);
    end

    // +RERESET_AT=<cycle>: a warm system reset in the middle of the run (core,
    // bus logic, test device and checkers together, 5 cycles; the memory
    // CONTENTS survive, as an SRAM's do). The program sees a second boot from
    // the reset vector. Track A coverage closure: core_rst_n_i never fell after
    // power-up in any suite, so no reset-during-operation path was exercised.
    integer rereset_at;
    initial begin
        if ($value$plusargs("RERESET_AT=%d", rereset_at)) begin
            wait (cyc >= rereset_at);
            @(negedge clk);
            rst_n = 1'b0;
            $display("tb_boot: warm reset at cycle %0d (%0d retired so far)", cyc, ninstr);
`ifdef GARUDA_COSIM
            garuda_cosim_reset();
`endif
            repeat (5) @(posedge clk);
            rst_n = 1'b1;
        end
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
        if (rst_n && $test$plusargs("DBGBUS") && cyc >= dbgfrom && cyc < dbgto) begin
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
        if (rst_n && $test$plusargs("DBGACC") && cyc >= dbgfrom && cyc < dbgto) begin
            $display("c%0d ACC: acc0=%012x acc1=%012x | xe_pc=%08x dsu_en=%b dsu_busy=%b idex_s=%b",
                     cyc, dbg_acc0, dbg_acc1, dut.xe_pc, dut.xe_dsu_en,
                     dut.ex_dsu_busy, dut.pc_idex_s);
        end
        if (rst_n && $test$plusargs("DBGEX") && cyc >= dbgfrom && cyc < dbgto) begin
            $display("c%0d EX: xe_pc=%08x xe_v=%b br=%b | loaduse=%b idex_s=%b idex_f=%b | exredir=%b tgt=%08x | fwd_a=%b rs1=%08x memstall=%b",
                     cyc, dut.xe_pc, dut.xe_valid, dut.xe_branch,
                     dut.id_load_use, dut.pc_idex_s, dut.pc_idex_f,
                     dut.ex_redirect, dut.ex_redirect_target,
                     dut.fwd_a_sel, dut.xe_rs1, dut.mem_stall);
        end
        if (rst_n && $test$plusargs("DBGM") && cyc >= dbgfrom && cyc < dbgto) begin
            $display("c%0d MEM: em_pc=%08x em_v=%b memrd=%b memwr=%b | dstate=%d start=%b hready=%b memstall=%b | mwb_f=%b mw_ret=%b mw_rd=%02d mw_data=%08x",
                     cyc, dut.em_pc, dut.em_valid, dut.em_mem_read, dut.em_mem_write,
                     dut.u_mem.u_d_port_ahb_master.state, dut.u_mem.u_d_port_ahb_master.start_i, d_hready,
                     dut.mem_stall, dut.pc_mwb_f, dut.mw_retire, dut.mw_rd, dut.mw_data);
        end
        if (rst_n && $test$plusargs("DBGTRAP") && cyc >= dbgfrom && cyc < dbgto) begin
            $display("c%0d TRAP: enter=%b cause=%08x tpc=%08x redir=%b tgt=%08x | id_ill=%b xe_ill=%b dsu_ill=%b dsu_busy=%b lmis=%b smis=%b memexc=%b | exredir=%b extgt=%08x",
                     cyc, dut.tr_enter, dut.tr_cause, dut.tr_pc, dut.tr_redir_v, dut.tr_redir_t,
                     dut.id_illegal, dut.xe_illegal, dut.ex_dsu_illegal, dut.ex_dsu_busy,
                     dut.ex_load_mis, dut.ex_store_mis, dut.mem_exc_v,
                     dut.ex_redirect, dut.ex_redirect_target);
        end
    end

    // $shm_open and $shm_probe are Cadence system tasks; other simulators do
    // not have them, so they are compiled for Cadence only; Verilator dumps VCD.
    initial begin
        if ($test$plusargs("WAVES")) begin
`ifndef VERILATOR
`ifndef __ICARUS__
            $shm_open("waves.shm");          // Cadence SimVision database
            $shm_probe(tb_boot, "AS");
`endif
`endif
`ifdef VERILATOR
            $dumpfile("waves.vcd");          // open tools: VCD (needs --trace)
            $dumpvars(0, tb_boot);
`endif
        end
    end

endmodule

`default_nettype wire
