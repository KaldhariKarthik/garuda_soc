`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 12 : RISC-V Debug Module (0.13 subset), hclk
// debug_module.v
//
// Spec: GARUDA-DEBUG-SPEC-001 Rev 2.0 §6.4-§6.8, §7.2-§7.4; ADR-0012
//
// SBA-only Debug Module: no abstract commands, no program buffer, no hart
// state access - the core is unchanged ([N-5.3]). Halt = hold the core in
// hartreset; resume = release it and the core restarts at the reset vector
// ([N-7.8], [N-7.9]).
//
//   0x10 dmcontrol  [0] dmactive [1] ndmreset [29] hartreset
//                   [30] resumereq (W1: clear hartreset) [31] haltreq (W1: set)
//   0x11 dmstatus   version 2, authenticated, any/allhalted = hartreset,
//                   any/allrunning = !hartreset, impebreak 0
//   0x16 abstractcs reads 0 -> datacount 0, progbufsize 0 ([N-6.3])
//   0x38 sbcs  0x39 sbaddress0  0x3C sbdata0          ([N-6.5], [N-6.6])
//   0x60..0x65 DSU accumulator taps, coherent lo/hi   ([N-6.8])
//   0x66 dsuovf  [0] the core's sticky DSU overflow (D-18)
//   everything else reads 0
//
// Reset: dm_rst_n (external, watchdog, SWRST) - NOT ndmreset or hartreset, so
// a debug-initiated reset never ends the session that issued it ([N-7.12],
// D-9). While dmactive is 0 the DM holds its outputs inactive.
// =============================================================================

module debug_module (
    input  wire        hclk_i,
    input  wire        dm_rst_n_i,

    // ---- DMI (from dmi_cdc) ---------------------------------------------------------
    input  wire        req_i,             // one-cycle pulse
    input  wire [6:0]  addr_i,
    input  wire [31:0] wdata_i,
    input  wire [1:0]  op_i,              // 1 read, 2 write
    output reg  [31:0] rdata_o,
    output reg         done_o,            // pulse: toggles the CDC ack

    // ---- to reset_ctrl -------------------------------------------------------------------
    output wire        ndmreset_o,
    output wire        hartreset_o,

    // ---- DSU taps --------------------------------------------------------------------------
    input  wire [47:0] dsu_acc0_i,
    input  wire [47:0] dsu_acc1_i,
    input  wire [47:0] dsu_acc2_i,
    input  wire        dsu_ovf_i,

    // ---- SBA master --------------------------------------------------------------------------
    output reg         sba_start_o,
    output reg         sba_write_o,
    output wire [31:0] sba_addr_o,
    output wire [31:0] sba_wdata_o,
    input  wire        sba_done_i,
    input  wire        sba_err_i,
    input  wire [31:0] sba_rdata_i,
    input  wire        sba_busy_i
);

    localparam [6:0] A_DMCONTROL = 7'h10, A_DMSTATUS = 7'h11, A_ABSTRACTCS = 7'h16,
                     A_SBCS = 7'h38, A_SBADDR0 = 7'h39, A_SBDATA0 = 7'h3C,
                     A_ACC0L = 7'h60, A_ACC0H = 7'h61, A_ACC1L = 7'h62,
                     A_ACC1H = 7'h63, A_ACC2L = 7'h64, A_ACC2H = 7'h65, A_OVF = 7'h66;

    reg        dmactive, ndmreset, hartreset;
    reg        sbbusyerror, sbreadonaddr, sbautoinc, sbreadondata;
    reg [2:0]  sbaccess, sberror;
    reg [31:0] sbaddr, sbdata;
    reg [47:0] hold0, hold1, hold2;
    reg        pending_write;             // the running SBA transfer is a write

    wire sbbusy = sba_busy_i | sba_start_o;

    wire [31:0] dmcontrol = {2'b00, hartreset, 27'd0, ndmreset, dmactive};
    wire [31:0] dmstatus  = {12'd0, 1'b0 /*impebreak*/, 2'b00, 1'b0, 1'b0, 2'b00,
                             ~hartreset, ~hartreset, hartreset, hartreset,
                             1'b1 /*authenticated*/, 3'b000, 4'd2};
    wire [31:0] sbcs      = {3'd1, 6'd0, sbbusyerror, sbbusy, sbreadonaddr, sbaccess,
                             sbautoinc, sbreadondata, sberror, 7'd32, 5'b00100};

    wire rd = req_i && op_i == 2'd1;
    wire wr = req_i && op_i == 2'd2;

    // start an SBA access if nothing is wrong ([N-7.6])
    task automatic kick(input w);
        begin
            if (sbaccess != 3'd2)       sberror <= 3'd3;
            else if (sbaddr[1:0] != 0)  sberror <= 3'd2;
            else begin
                sba_start_o   <= 1'b1;
                sba_write_o   <= w;
                pending_write <= w;
            end
        end
    endtask

    always @(posedge hclk_i or negedge dm_rst_n_i) begin
        if (!dm_rst_n_i) begin
            dmactive <= 1'b0; ndmreset <= 1'b0; hartreset <= 1'b0;
            sbbusyerror <= 1'b0; sbreadonaddr <= 1'b0; sbautoinc <= 1'b0;
            sbreadondata <= 1'b0; sbaccess <= 3'd2; sberror <= 3'd0;
            sbaddr <= 32'd0; sbdata <= 32'd0;
            hold0 <= 48'd0; hold1 <= 48'd0; hold2 <= 48'd0;
            sba_start_o <= 1'b0; sba_write_o <= 1'b0; pending_write <= 1'b0;
            rdata_o <= 32'd0; done_o <= 1'b0;
        end else begin
            done_o      <= req_i;
            sba_start_o <= 1'b0;

            // ---- SBA completion ----------------------------------------------------------
            if (sba_done_i) begin
                if (sba_err_i) sberror <= 3'd4;
                else begin
                    if (!pending_write) sbdata <= sba_rdata_i;
                    if (sbautoinc)      sbaddr <= sbaddr + 32'd4;
                end
            end

            // ---- DMI writes -----------------------------------------------------------------
            if (wr) begin
                case (addr_i)
                    A_DMCONTROL: begin
                        dmactive <= wdata_i[0];
                        if (!wdata_i[0]) begin            // DM reset
                            ndmreset <= 1'b0; hartreset <= 1'b0;
                        end else begin
                            ndmreset <= wdata_i[1];
                            if      (wdata_i[31]) hartreset <= 1'b1;   // haltreq
                            else if (wdata_i[30]) hartreset <= 1'b0;   // resumereq
                            else                  hartreset <= wdata_i[29];
                        end
                    end
                    A_SBCS: begin
                        if (wdata_i[22]) sbbusyerror <= 1'b0;
                        if (wdata_i[14:12] != 0) sberror <= sberror & ~wdata_i[14:12];
                        sbreadonaddr <= wdata_i[20];
                        sbaccess     <= wdata_i[19:17];
                        sbautoinc    <= wdata_i[16];
                        sbreadondata <= wdata_i[15];
                    end
                    A_SBADDR0: begin
                        if (sbbusy) sbbusyerror <= 1'b1;
                        else begin
                            sbaddr <= wdata_i;
                            if (sbreadonaddr && sberror == 0 && !sbbusyerror) begin
                                // kick() checks the NEW address
                                if (sbaccess != 3'd2)     sberror <= 3'd3;
                                else if (wdata_i[1:0] != 0) sberror <= 3'd2;
                                else begin sba_start_o <= 1'b1; sba_write_o <= 1'b0; pending_write <= 1'b0; end
                            end
                        end
                    end
                    A_SBDATA0: begin
                        if (sbbusy) sbbusyerror <= 1'b1;
                        else begin
                            sbdata <= wdata_i;
                            if (sberror == 0 && !sbbusyerror) kick(1'b1);
                        end
                    end
                    default: ;
                endcase
            end

            // ---- DMI reads --------------------------------------------------------------------
            if (rd) begin
                case (addr_i)
                    A_DMCONTROL:  rdata_o <= dmcontrol;
                    A_DMSTATUS:   rdata_o <= dmstatus;
                    A_SBCS:       rdata_o <= sbcs;
                    A_SBADDR0:    rdata_o <= sbaddr;
                    A_SBDATA0: begin
                        rdata_o <= sbdata;
                        if (sbbusy) sbbusyerror <= 1'b1;
                        else if (sbreadondata && sberror == 0 && !sbbusyerror) kick(1'b0);
                    end
                    A_ACC0L: begin rdata_o <= dsu_acc0_i[31:0]; hold0 <= dsu_acc0_i; end
                    A_ACC0H:       rdata_o <= {16'd0, hold0[47:32]};
                    A_ACC1L: begin rdata_o <= dsu_acc1_i[31:0]; hold1 <= dsu_acc1_i; end
                    A_ACC1H:       rdata_o <= {16'd0, hold1[47:32]};
                    A_ACC2L: begin rdata_o <= dsu_acc2_i[31:0]; hold2 <= dsu_acc2_i; end
                    A_ACC2H:       rdata_o <= {16'd0, hold2[47:32]};
                    A_OVF:         rdata_o <= {31'd0, dsu_ovf_i};
                    default:       rdata_o <= 32'd0;          // abstractcs, data0, progbuf ...
                endcase
            end
        end
    end

    assign ndmreset_o  = dmactive & ndmreset;
    assign hartreset_o = dmactive & hartreset;
    assign sba_addr_o  = sbaddr;
    assign sba_wdata_o = sbdata;

endmodule

`default_nettype wire
