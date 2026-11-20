// MUTANT debug_module_rawgrant: rtl/debug/debug_module.sv with ONE change: hartreset_o follows the RAW request
// (the pre-RDC-1 behaviour of b90b481). Formal negative control: must FAIL. Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. (tb/core/formal/rdc1.toml rdc1_prove_rawgrant)
// =============================================================================
// GARUDA SoC - Block 12 : RISC-V Debug Module (0.13 subset), hclk
// debug_module.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 Sec.6.4-Sec.6.8, Sec.7.2-Sec.7.4;
// ADR-0012
//
// SBA-only Debug Module: no abstract commands, no program buffer, no hart
// state access - the core is unchanged ([N-5.3]). Halt = hold the core in
// hartreset; resume = release it and the core restarts at the reset vector
// ([N-7.8], [N-7.9]).
//
//   0x10 dmcontrol  [0] dmactive [1] ndmreset [29] hartreset
//                   [30] resumereq (W1: clear hartreset) [31] haltreq (W1: set)
//   0x11 dmstatus   version 2, authenticated, any/allhalted = halt granted,
//                   any/allrunning = !granted, impebreak 0  (RDC-1: the grant,
//                   not the request -- see "Halt drain" below)
//   0x16 abstractcs reads 0 -> datacount 0, progbufsize 0 ([N-6.3])
//   0x38 sbcs  0x39 sbaddress0  0x3C sbdata0          ([N-6.5], [N-6.6])
//   0x60..0x65 DSU accumulator taps, coherent lo/hi   ([N-6.8])
//   0x66 dsuovf  [0] the core's sticky DSU overflow (D-18)
//   0x70 haltinfo [0] haltforced: a halt was granted by the timeout, not by the
//                     core reporting a safe point (sticky; write 1 to clear)
//   everything else reads 0
//
// Halt drain (ERRATUM RDC-1, fixed 2026-10-11): dmcontrol.haltreq/hartreset is
// the REQUEST. It raises halt_req_o; the core stops fetching and drains, and
// reports halt_safe_i when neither bus port presents an address or owns a data
// phase. The grant -- hartreset_o, to the core and to reset_ctrl -- follows on
// halt_safe_i, or after HALT_TIMEOUT cycles if the core never gets there (a
// slave holding HREADY low), which sets haltinfo.haltforced. Before,
// hartreset_o followed the request directly and reset the core in the middle of
// a waited store on a live bus (HWDATA changed under the slave). resumereq
// drops the request and the grant together.
//
// Reset: dm_rst_n (external, watchdog, SWRST) - NOT ndmreset or hartreset, so
// a debug-initiated reset never ends the session that issued it ([N-7.12],
// D-9). While dmactive is 0 the DM holds its outputs inactive.
// =============================================================================

module debug_module
    import garuda_pkg::*;
#(
    // hclk cycles from halt request to a forced grant
    parameter int unsigned HALT_TIMEOUT = 32'd1024
) (
    input wire hclk,
    input wire dm_rst_n,
    // ---- DMI (from dmi_cdc) -------------------------------------------------
    input wire req_i,  // one-cycle pulse
    input wire [DMI_ADDR_W-1:0] addr_i,
    input wire [WORD_W-1:0] wdata_i,
    input wire [DMI_OP_W-1:0] op_i,  // 1 read, 2 write
    output reg [WORD_W-1:0] rdata_o,
    output reg done_o,  // pulse: toggles the CDC ack
    // ---- to reset_ctrl ------------------------------------------------------
    output wire ndmreset_o,
    output wire hartreset_o,
    // ---- halt drain with the core (RDC-1) -----------------------------------
    output wire halt_req_o,  // a halt is requested (held through the grant)
    input wire halt_safe_i,  // the core breaks no bus transfer if reset now
    // ---- DSU taps -----------------------------------------------------------
    input wire [ACC_W-1:0] dsu_acc0_i,
    input wire [ACC_W-1:0] dsu_acc1_i,
    input wire [ACC_W-1:0] dsu_acc2_i,
    input wire dsu_ovf_i,
    // ---- SBA master ---------------------------------------------------------
    output reg sba_start_o,
    output reg sba_write_o,
    output wire [WORD_W-1:0] sba_addr_o,
    output wire [WORD_W-1:0] sba_wdata_o,
    input wire sba_done_i,
    input wire sba_err_i,
    input wire [WORD_W-1:0] sba_rdata_i,
    input wire sba_busy_i
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned SBACCESS_W = 32'd3;
    localparam int unsigned SBERROR_W = 32'd3;

    localparam [6:0] A_DMCONTROL = 7'h10, A_DMSTATUS = 7'h11,
                     A_SBCS = 7'h38, A_SBADDR0 = 7'h39, A_SBDATA0 = 7'h3C,
                     A_ACC0L = 7'h60, A_ACC0H = 7'h61, A_ACC1L = 7'h62,
                     A_ACC1H = 7'h63, A_ACC2L = 7'h64, A_ACC2H = 7'h65, A_OVF
                         = 7'h66,
                     A_HALTINFO = 7'h70;

    reg dmactive;
    reg ndmreset;
    reg hartreset;
    reg sbbusyerror;
    reg sbreadonaddr;
    reg sbautoinc;
    reg sbreadondata;
    reg [SBACCESS_W-1:0] sbaccess;
    reg [SBERROR_W-1:0] sberror;
    reg [WORD_W-1:0] sbaddr;
    reg [WORD_W-1:0] sbdata;
    // ACCnH reads the high part of the value ACCnL read (F4: only those 16
    // bits are held; the low 32 of the old 48-bit copies were never read)
    reg [HALF_W-1:0] hold_fx;
    reg [HALF_W-1:0] hold_fy;
    reg [HALF_W-1:0] hold_mag;

    wire sbbusy = sba_busy_i | sba_start_o | sba_done_i;

    reg        grant_q;  // the core is (being) held in hartreset
    reg        haltforced;  // sticky: a grant came from the timeout
    reg [HALF_W-1:0] halt_cnt;
    localparam int unsigned HALT_LAST_I = HALT_TIMEOUT - 32'd1;
    // the counter is 16 bits
    localparam [15:0]  HALT_LAST   = HALT_LAST_I[15:0];
    wire       halt_requested = dmactive & hartreset;

    wire [WORD_W-1:0] dmcontrol = {2'b00, hartreset, 27'd0, ndmreset, dmactive};
    // dmstatus, RISC-V External Debug Support 0.13 layout, 32 bits. The fields
    // above bit 11 are all 0; this used to be a 31-bit concatenation (impebreak
    // at bit 18), the same value, and a lint waiver.
    wire [WORD_W-1:0] dmstatus  = {9'd0, 1'b0 /*impebreak*/, 2'b00,
                             2'b00, 2'b00,
                             2'b00, 2'b00,
                             // RDC-1: halted = granted
                             ~grant_q, ~grant_q, grant_q, grant_q,
                             1'b1, 3'b000, 4'd2};
    wire [WORD_W-1:0] sbcs = {3'd1, 6'd0, sbbusyerror, sbbusy, sbreadonaddr,
                              sbaccess, sbautoinc, sbreadondata, sberror,
                              7'd32, 5'b00100};

    wire rd = req_i && op_i == 2'd1;
    wire wr = req_i && op_i == 2'd2;

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_grant
        if (!dm_rst_n) begin
            grant_q <= 1'b0;
            halt_cnt <= 16'd0;
        end else begin
            if (!halt_requested) begin
                grant_q <= 1'b0;  // resume: request and grant drop together
                halt_cnt <= 16'd0;
            end else if (!grant_q) begin
                if (halt_safe_i) begin
                    grant_q <= 1'b1;  // the core reached a safe point
                end else if (halt_cnt == HALT_LAST) begin
                    grant_q <= 1'b1;  // bounded: never wait forever
                end else begin
                    halt_cnt <= HALF_W'(halt_cnt + 16'd1);
                end
            end
        end
    end
    // HALTINFO.haltforced: set by a forced (timeout) grant, W1C by the debugger;
    // a forced grant in the same cycle as the W1C wins (F4 2026-11-20: its own
    // process, HAL MULNBA; the order of the two assignments before, written out)
    wire forced_grant = halt_requested && !grant_q && !halt_safe_i
        && (halt_cnt == HALT_LAST);
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_haltforced
        if (!dm_rst_n) begin
            haltforced <= 1'b0;
        end else if (forced_grant) begin
            haltforced <= 1'b1;
        end else if (wr && addr_i == A_HALTINFO && wdata_i[0]) begin
            haltforced <= 1'b0;
        end
    end

    // Held through the grant (2026-11-16): the core samples the grant into its
    // reset flop one clock after it rises, and must not start fetching in that
    // clock.
    assign halt_req_o = halt_requested;

    // ---- the DMI request this cycle -----------------------------------------
    // F4 (2026-11-17): one process per register; the single process before
    // gave several registers two assignments in one edge, the later winning
    // (HAL MULNBA). Each priority below is that order written out.
    wire dmc_wr    = wr && (addr_i == A_DMCONTROL);  // allowed while inactive
    wire wr_act    = wr && dmactive;
    wire dm_off    = dmc_wr && !wdata_i[0];          // DM reset
    wire dm_on     = dmc_wr && wdata_i[0];
    wire sbcs_wr   = wr_act && (addr_i == A_SBCS);
    wire sbaddr_wr = wr_act && (addr_i == A_SBADDR0);
    wire sbdata_wr = wr_act && (addr_i == A_SBDATA0);
    wire sbdata_rd = rd && (addr_i == A_SBDATA0) && dmactive;
    wire bus_done  = sba_done_i && dmactive;
    wire bus_err   = bus_done && sba_err_i;
    wire bus_ok    = bus_done && !sba_err_i;

    // a system-bus access may start: no error pending, the access size is the
    // one supported (word), the address word-aligned
    wire sb_clean  = (sberror == '0) && !sbbusyerror;
    wire word_size = (sbaccess == 3'd2);
    wire try_a = sbaddr_wr && !sbbusy && sbreadonaddr && sb_clean;
    wire try_w = sbdata_wr && !sbbusy && sb_clean;
    wire try_r = sbdata_rd && !sbbusy && sbreadondata && sb_clean;
    wire wadr_ok   = (wdata_i[1:0] == 2'b00);
    wire sadr_ok   = (sbaddr[1:0] == 2'b00);
    wire start_a = try_a && word_size && wadr_ok;
    wire start_w = try_w && word_size && sadr_ok;
    wire start_r = try_r && word_size && sadr_ok;
    // the error a refused start records: 3 bad size, 2 bad alignment
    wire refuse_a = try_a && !(word_size && wadr_ok);
    wire refuse_d = (try_w || try_r) && !(word_size && sadr_ok);
    wire [SBERROR_W-1:0] refuse_code = word_size ? 3'd2 : 3'd3;
    wire sbcs_clr = sbcs_wr && (wdata_i[14:12] != '0) && !bus_err;

    // ---- dmcontrol ----------------------------------------------------------
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_dmcontrol
        if (!dm_rst_n) begin
            dmactive <= 1'b0;
            ndmreset <= 1'b0;
            hartreset <= 1'b0;
        end else if (dm_off) begin
            dmactive <= 1'b0;
            ndmreset <= 1'b0;
            hartreset <= 1'b0;
        end else if (dm_on) begin
            dmactive <= 1'b1;
            ndmreset <= wdata_i[1];
            if (wdata_i[31]) begin
                hartreset <= 1'b1;  // haltreq
            end else if (wdata_i[30]) begin
                hartreset <= 1'b0;  // resumereq
            end else begin
                hartreset <= wdata_i[29];
            end
        end
    end

    // ---- sbcs fields --------------------------------------------------------
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sbcs
        if (!dm_rst_n) begin
            sbreadonaddr <= 1'b0;
            sbautoinc <= 1'b0;
            sbreadondata <= 1'b0;
            sbaccess <= 3'd2;
        end else if (dm_off) begin
            sbreadonaddr <= 1'b0;
            sbautoinc <= 1'b0;
            sbreadondata <= 1'b0;
            sbaccess <= 3'd2;
        end else if (sbcs_wr) begin
            sbreadonaddr <= wdata_i[20];
            sbaccess <= wdata_i[19:17];
            sbautoinc <= wdata_i[16];
            sbreadondata <= wdata_i[15];
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sbbusyerror
        if (!dm_rst_n) begin
            sbbusyerror <= 1'b0;
        end else if (dm_off || (sbcs_wr && wdata_i[22])) begin
            sbbusyerror <= 1'b0;
        end else if ((sbaddr_wr || sbdata_wr || sbdata_rd) && sbbusy) begin
            sbbusyerror <= 1'b1;
        end
    end

    // sberror: a refused start or a W1C clear on this access wins over a bus
    // error reported in the same cycle; a DM reset wins over everything
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sberror
        if (!dm_rst_n) begin
            sberror <= 3'd0;
        end else if (dm_off) begin
            sberror <= 3'd0;
        end else if (sbcs_clr) begin
            sberror <= sberror & ~wdata_i[14:12];
        end else if (refuse_a || refuse_d) begin
            sberror <= refuse_code;
        end else if (bus_err) begin
            sberror <= 3'd4;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sbaddr
        if (!dm_rst_n) begin
            sbaddr <= 32'd0;
        end else if (dm_off) begin
            sbaddr <= 32'd0;
        end else if (sbaddr_wr && !sbbusy) begin
            sbaddr <= wdata_i;
        end else if (bus_ok && sbautoinc) begin
            sbaddr <= sbaddr + 32'd4;
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sbdata
        if (!dm_rst_n) begin
            sbdata <= 32'd0;
        end else if (dm_off) begin
            sbdata <= 32'd0;
        end else if (sbdata_wr && !sbbusy) begin
            sbdata <= wdata_i;
        end else if (bus_ok && !sba_write_o) begin
            sbdata <= sba_rdata_i;
        end
    end

    // ---- the system-bus access ----------------------------------------------
    // sba_write_o is the running access's direction (it was kept twice, as
    // pending_write too)
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_sba
        if (!dm_rst_n) begin
            sba_start_o <= 1'b0;
            sba_write_o <= 1'b0;
        end else begin
            sba_start_o <= start_a || start_w || start_r;
            if (start_w) begin
                sba_write_o <= 1'b1;
            end else if (start_a || start_r) begin
                sba_write_o <= 1'b0;
            end
        end
    end

    // ---- DMI read data ------------------------------------------------------
    function automatic [WORD_W-1:0] hi_word(input [HALF_W-1:0] h);
        hi_word = {{(WORD_W - HALF_W){1'b0}}, h};
    endfunction

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_rdata
        if (!dm_rst_n) begin
            rdata_o <= 32'd0;
        end else if (rd) begin
            case (addr_i)
                A_DMCONTROL: rdata_o <= dmcontrol;
                A_DMSTATUS: rdata_o <= dmstatus;
                A_SBCS: rdata_o <= sbcs;
                A_SBADDR0: rdata_o <= sbaddr;
                A_SBDATA0: rdata_o <= sbdata;
                A_ACC0L: rdata_o <= dsu_acc0_i[31:0];
                A_ACC0H: rdata_o <= hi_word(hold_fx);
                A_ACC1L: rdata_o <= dsu_acc1_i[31:0];
                A_ACC1H: rdata_o <= hi_word(hold_fy);
                A_ACC2L: rdata_o <= dsu_acc2_i[31:0];
                A_ACC2H: rdata_o <= hi_word(hold_mag);
                A_OVF: rdata_o <= {31'd0, dsu_ovf_i};
                A_HALTINFO: rdata_o <= {31'd0, haltforced};  // RDC-1
                // abstractcs, data0, progbuf ...
                default: rdata_o <= 32'd0;
            endcase
        end
    end

    // reading ACCnL takes a snapshot of ACCn's high part for ACCnH
    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_hold
        if (!dm_rst_n) begin
            hold_fx <= 16'd0;
            hold_fy <= 16'd0;
            hold_mag <= 16'd0;
        end else if (rd) begin
            if (addr_i == A_ACC0L) begin
                hold_fx <= dsu_acc0_i[47:32];
            end
            if (addr_i == A_ACC1L) begin
                hold_fy <= dsu_acc1_i[47:32];
            end
            if (addr_i == A_ACC2L) begin
                hold_mag <= dsu_acc2_i[47:32];
            end
        end
    end

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_done
        if (!dm_rst_n) begin
            done_o <= 1'b0;
        end else begin
            done_o <= req_i;
        end
    end

    assign ndmreset_o  = dmactive & ndmreset;
    // RDC-1: the grant, never the raw request
    assign hartreset_o = dmactive & hartreset;              // MUTANT: no drain (pre-fix behaviour)
    assign sba_addr_o  = sbaddr;
    assign sba_wdata_o = sbdata;

endmodule
