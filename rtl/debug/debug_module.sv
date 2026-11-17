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
    parameter integer HALT_TIMEOUT = 32'd1024
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

    localparam [6:0] A_DMCONTROL = 7'h10, A_DMSTATUS = 7'h11, A_ABSTRACTCS
        = 7'h16,
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
    reg [ACC_W-1:0] hold_fx;
    reg [ACC_W-1:0] hold_fy;
    reg [ACC_W-1:0] hold_mag;
    reg        pending_write;  // the running SBA transfer is a write

    // ERRATUM DBG-2: sba_done_i is high one cycle AFTER sba_busy_i falls, and
    // sbdata/sbaddr/sberror only take the result at the end of that cycle. With
    // the done cycle counted as idle, an sbdata0 read landing in it returned
    // the previous word with sbbusyerror clear, and an sbdata0 write started a
    // new transfer past an sberror being set in the same cycle. The transfer is
    // busy until its result is in the registers.
    wire sbbusy = sba_busy_i | sba_start_o | sba_done_i;

    // ---- RDC-1 halt drain: request -> drain -> grant ------------------------
    reg        grant_q;  // the core is (being) held in hartreset
    reg        haltforced;  // sticky: a grant came from the timeout
    reg [HALF_W-1:0] halt_cnt;
    localparam integer HALT_LAST_I = HALT_TIMEOUT - 1;
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
    wire [WORD_W-1:0] sbcs = {3'd1, 6'd0, sbbusyerror, sbbusy, sbreadonaddr, sbaccess,
                             sbautoinc, sbreadondata, sberror, 7'd32, 5'b00100};

    wire rd = req_i && op_i == 2'd1;
    wire wr = req_i && op_i == 2'd2;

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_grant
        if (!dm_rst_n) begin
            grant_q <= 1'b0;
            haltforced <= 1'b0;
            halt_cnt <= 16'd0;
        end else begin
            if (wr && addr_i == A_HALTINFO && wdata_i[0]) begin
                haltforced <= 1'b0;  // W1C (a new forced grant below wins)
            end
            if (!halt_requested) begin
                grant_q <= 1'b0;  // resume: request and grant drop together
                halt_cnt <= 16'd0;
            end else if (!grant_q) begin
                if (halt_safe_i) begin
                    grant_q <= 1'b1;  // the core reached a safe point
                end else if (halt_cnt == HALT_LAST) begin
                    grant_q <= 1'b1;  // bounded: never wait forever
                    haltforced <= 1'b1;
                end else begin
                    halt_cnt <= halt_cnt + 16'd1;
                end
            end
        end
    end
    // Held through the grant (2026-11-16): the core samples the grant into its
    // reset flop one clock after it rises, and must not start fetching in that
    // clock.
    assign halt_req_o = halt_requested;

    // An SBA access starts only if nothing is wrong ([N-7.6]): sbaccess must be
    // 2 (32-bit), else sberror = 3; the address must be word-aligned, else
    // sberror = 2. The check is written out at each of its three places
    // (SBADDR0 write, SBDATA0 write, SBDATA0 read) rather than as a task:
    // Xcelium switches X-propagation off for a block that calls a task writing
    // registers outside it (flow/2_static/xprop/README.md, ruling 2026-11-10).

    always_ff @(posedge hclk or negedge dm_rst_n) begin : p_dmactive
        if (!dm_rst_n) begin
            dmactive <= 1'b0;
            ndmreset <= 1'b0;
            hartreset <= 1'b0;
            sbbusyerror <= 1'b0;
            sbreadonaddr <= 1'b0;
            sbautoinc <= 1'b0;
            sbreadondata <= 1'b0;
            sbaccess <= 3'd2;
            sberror <= 3'd0;
            sbaddr <= 32'd0;
            sbdata <= 32'd0;
            hold_fx <= 48'd0;
            hold_fy <= 48'd0;
            hold_mag <= 48'd0;
            sba_start_o <= 1'b0;
            sba_write_o <= 1'b0;
            pending_write <= 1'b0;
            rdata_o <= 32'd0;
            done_o <= 1'b0;
        end else begin
            done_o <= req_i;
            sba_start_o <= 1'b0;
            // ---- SBA completion ---------------------------------------------
            if (sba_done_i && dmactive) begin
                if (sba_err_i) begin
                    sberror <= 3'd4;
                end else begin
                    if (!pending_write) begin
                        sbdata <= sba_rdata_i;
                    end
                    if (sbautoinc) begin
                        sbaddr <= sbaddr + 32'd4;
                    end
                end
            end
            // ---- DMI writes -------------------------------------------------
            // ERRATUM DBG-3: dmactive = 0 "holds the DM in reset" (spec 6.5).
            // It only cleared ndmreset/hartreset: sbcs, sberror, sbbusyerror
            // and sbaddress0 survived the debugger's dmactive 0 -> 1 reset, and
            // SBA ran with the DM inactive. Writing dmactive = 0 now returns
            // the SBA registers to their reset values, and while dmactive is 0
            // only dmcontrol is writable and no transfer can start.
            if (wr && (dmactive || addr_i == A_DMCONTROL)) begin
                case (addr_i)
                    A_DMCONTROL: begin
                        dmactive <= wdata_i[0];
                        if (!wdata_i[0]) begin  // DM reset
                            ndmreset <= 1'b0;
                            hartreset <= 1'b0;
                            sbbusyerror <= 1'b0;
                            sbreadonaddr <= 1'b0;
                            sbautoinc <= 1'b0;
                            sbreadondata <= 1'b0;
                            sbaccess <= 3'd2;
                            sberror <= 3'd0;
                            sbaddr <= 32'd0;
                            sbdata <= 32'd0;
                        end else begin
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
                    A_SBCS: begin
                        if (wdata_i[22]) begin
                            sbbusyerror <= 1'b0;
                        end
                        // ERRATUM DBG-4 (ruling D-32, 2026-11-03): an SBA error
                        // completing in this cycle wins over the debugger's
                        // write-1-to-clear, as the DMA's set-beats-clear rule
                        // ([N-7.19]); before, the later assignment cleared the
                        // 4 just set and the error was lost.
                        if (wdata_i[14:12] != 0
                            && !(sba_done_i && dmactive && sba_err_i)) begin
                            sberror <= sberror & ~wdata_i[14:12];
                        end
                        sbreadonaddr <= wdata_i[20];
                        sbaccess <= wdata_i[19:17];
                        sbautoinc <= wdata_i[16];
                        sbreadondata <= wdata_i[15];
                    end
                    A_SBADDR0: begin
                        if (sbbusy) begin
                            sbbusyerror <= 1'b1;
                        end else begin
                            sbaddr <= wdata_i;
                            if (sbreadonaddr && sberror == 0
                                && !sbbusyerror) begin
                                // the check uses the NEW address
                                if (sbaccess != 3'd2) begin
                                    sberror <= 3'd3;
                                end else if (wdata_i[1:0] != 0) begin
                                    sberror <= 3'd2;
                                end else begin
                                    sba_start_o <= 1'b1;
                                    sba_write_o <= 1'b0;
                                    pending_write <= 1'b0;
                                end
                            end
                        end
                    end
                    A_SBDATA0: begin
                        if (sbbusy) begin
                            sbbusyerror <= 1'b1;
                        end else begin
                            sbdata <= wdata_i;
                            if (sberror == 0 && !sbbusyerror) begin
                                if (sbaccess != 3'd2) begin
                                    sberror <= 3'd3;
                                end else if (sbaddr[1:0] != 2'b00) begin
                                    sberror <= 3'd2;
                                end else begin
                                    sba_start_o <= 1'b1;
                                    sba_write_o <= 1'b1;
                                    pending_write <= 1'b1;
                                end
                            end
                        end
                    end
                    default: begin
                    end
                endcase
            end
            // ---- DMI reads --------------------------------------------------
            if (rd) begin
                case (addr_i)
                    A_DMCONTROL: rdata_o <= dmcontrol;
                    A_DMSTATUS: rdata_o <= dmstatus;
                    A_SBCS: rdata_o <= sbcs;
                    A_SBADDR0: rdata_o <= sbaddr;
                    A_SBDATA0: begin
                        rdata_o <= sbdata;
                        if (!dmactive) begin
                        end else if (sbbusy) begin
                            sbbusyerror <= 1'b1;
                        end else if (sbreadondata && sberror == 0
                            && !sbbusyerror) begin
                            if (sbaccess != 3'd2) begin
                                sberror <= 3'd3;
                            end else if (sbaddr[1:0] != 2'b00) begin
                                sberror <= 3'd2;
                            end else begin
                                sba_start_o <= 1'b1;
                                sba_write_o <= 1'b0;
                                pending_write <= 1'b0;
                            end
                        end
                    end
                    A_ACC0L: begin
                        rdata_o <= dsu_acc0_i[31:0];
                        hold_fx <= dsu_acc0_i;
                    end
                    A_ACC0H: rdata_o <= {16'd0, hold_fx[47:32]};
                    A_ACC1L: begin
                        rdata_o <= dsu_acc1_i[31:0];
                        hold_fy <= dsu_acc1_i;
                    end
                    A_ACC1H: rdata_o <= {16'd0, hold_fy[47:32]};
                    A_ACC2L: begin
                        rdata_o <= dsu_acc2_i[31:0];
                        hold_mag <= dsu_acc2_i;
                    end
                    A_ACC2H: rdata_o <= {16'd0, hold_mag[47:32]};
                    A_OVF: rdata_o <= {31'd0, dsu_ovf_i};
                    A_HALTINFO: rdata_o <= {31'd0, haltforced};  // RDC-1
                    // abstractcs, data0, progbuf ...
                    default: rdata_o <= 32'd0;
                endcase
            end
        end
    end

    assign ndmreset_o  = dmactive & ndmreset;
    // RDC-1: the grant, never the raw request
    assign hartreset_o = dmactive & grant_q;
    assign sba_addr_o  = sbaddr;
    assign sba_wdata_o = sbdata;

endmodule
