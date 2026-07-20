`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block I: Processor Core
// csr_file.v - Machine-mode CSR register file + RMW + legality (Sec. 13)
// Document: AERO-GARUDA-DS-001 Rev 1.1
//
// EX seam (Sec. 8.4): csr_rw.v presents {addr, wdata, op, en}; this file
// returns csr_rdata combinationally and applies the write on the clock edge.
//   op: CSR_RW=01 (write), CSR_RS=10 (set), CSR_RC=11 (clear), 00=none.
// Unimplemented CSR or write to a read-only CSR -> illegal_csr_o (CONTROL turns
// it into an illegal-instruction trap, cause 2). RS/RC with wdata==0 perform no
// write (csr_rw already zeroes wdata when rs1/uimm==0).
//
// Trap port (trap_ctrl, Sec. 14.4): trap_enter_i pushes mstatus (MPIE<=MIE,
// MIE<=0, MPP<=11) and latches mepc/mcause/mtval; mret_i pops (MIE<=MPIE,
// MPIE<=1). Architectural fields are exported for trap_ctrl / clic_ctrl.
//
// Counters (Sec. 13.2): mcycle increments every cycle; minstret increments on
// instret_i (one retired instruction). dsu_ovf (0xBC0) reads dsu_overflow_i and
// pulses csr_clear_overflow_o on read.
// =============================================================================
`include "core_ex_defs.vh"

module csr_file (
    input  wire        clk_i,
    input  wire        rst_n_i,

    // ---- EX read/modify/write seam ----
    input  wire        csr_en_i,
    input  wire [11:0] csr_addr_i,
    input  wire [31:0] csr_wdata_i,
    input  wire [1:0]  csr_op_i,
    output reg  [31:0] csr_rdata_o,
    output wire        illegal_csr_o,

    // ---- retire / counters ----
    input  wire        instret_i,        // one retired instruction this cycle

    // ---- DSU overflow ----
    input  wire        dsu_overflow_i,
    output wire        csr_clear_overflow_o,

    // ---- trap interface (trap_ctrl) ----
    input  wire        trap_enter_i,     // pulse: take a trap
    input  wire        mret_i,           // pulse: MRET
    input  wire        is_interrupt_i,   // trap_enter is an interrupt -> push level (Sec.14.3)
    input  wire [7:0]  clic_level_i,     // taken interrupt level
    input  wire [31:0] trap_pc_i,        // -> mepc
    input  wire [31:0] trap_cause_i,     // -> mcause (bit31 = interrupt)
    input  wire [31:0] trap_tval_i,      // -> mtval
    input  wire        clic_mip_i,       // CLIC external pending summary -> mip.MEIP
    input  wire        mtip_i,           // machine timer pending, mtime >= mtimecmp (Sec.14.6)

    // ---- architectural exports (to trap_ctrl / clic_ctrl) ----
    output wire        mstatus_mie_o,
    output wire [31:0] mtvec_o,
    output wire [31:0] mtvt_o,
    output wire [31:0] mepc_o,
    output wire [7:0]  mintthresh_o,
    output wire [7:0]  mintstatus_mil_o, // current active interrupt level (Sec.14.3 take cond)

    // Machine-timer interrupt pending AND locally enabled (mie.MTIE). Deliberately
    // NOT gated by mstatus.MIE: trap_ctrl applies the global enable for taking the
    // trap, and uses this ungated form for the MIE-independent WFI wake (Sec.14.5),
    // mirroring the clic_ctrl take_cond / wake_cond split.
    output wire        mti_pending_o
);
    // ---------------- addresses (Sec. 13.2) ----------------
    localparam MISA=12'h301, MVENDORID=12'hF11, MARCHID=12'hF12, MIMPID=12'hF13,
               MHARTID=12'hF14, MSTATUS=12'h300, MTVEC=12'h305, MTVT=12'h307,
               MIE=12'h304, MIP=12'h344, MEPC=12'h341, MCAUSE=12'h342, MTVAL=12'h343,
               MSCRATCH=12'h340, MINTSTATUS=12'hFB1, MINTTHRESH=12'h347, MNXTI=12'h345,
               MCYCLE=12'hB00, MCYCLEH=12'hB80, MINSTRET=12'hB02, MINSTRETH=12'hB82,
               DSU_OVF=12'hBC0;

    // ---------------- state ----------------
    reg        mstatus_mie, mstatus_mpie;   // MPP fixed 2'b11 (M-only)
    reg [31:0] mtvec_r, mtvt_r, mie_r, mepc_r, mcause_r, mtval_r, mscratch_r;
    reg [7:0]  mintthresh_r;
    reg [7:0]  mil_r, mpil_r;            // mintstatus: current / previous interrupt level
    reg [63:0] mcycle_r, minstret_r;

    wire [31:0] mstatus_val = {19'd0, 2'b11 /*MPP*/, 3'd0, mstatus_mpie, 3'd0, mstatus_mie, 3'd0};
    wire [31:0] misa_val    = {2'b01 /*MXL=32*/, 4'd0, 26'h0001100 /*I+M*/} | (32'd1<<23 /*X*/);
    wire [31:0] mintstatus_val = {16'd0, mpil_r, mil_r};   // [15:8]=mpil [7:0]=mil

    // mip is read-only hardware state (Sec.13.2): MEIP[11] = CLIC pending summary,
    // MTIP[7] = machine timer. Both are driven by hardware, never by a CSR write.
    wire [31:0] mip_val = {20'd0, clic_mip_i, 3'd0, mtip_i, 7'd0};
    localparam MTIE_BIT = 7;
    assign mti_pending_o = mtip_i & mie_r[MTIE_BIT];

    // ---------------- read mux + implemented? ----------------
    reg [31:0] rdata;
    reg        implemented;
    always @(*) begin
        implemented = 1'b1;
        case (csr_addr_i)
            MISA:      rdata = misa_val;
            MVENDORID: rdata = 32'd0;
            MARCHID:   rdata = 32'd0;
            MIMPID:    rdata = 32'h0000_0110;      // Rev 1.1
            MHARTID:   rdata = 32'd0;
            MSTATUS:   rdata = mstatus_val;
            MTVEC:     rdata = mtvec_r;
            MTVT:      rdata = mtvt_r;
            MIE:       rdata = mie_r;
            MIP:       rdata = mip_val;
            MEPC:      rdata = mepc_r;
            MCAUSE:    rdata = mcause_r;
            MTVAL:     rdata = mtval_r;
            MSCRATCH:  rdata = mscratch_r;
            MINTSTATUS:rdata = mintstatus_val;
            MINTTHRESH:rdata = {24'd0, mintthresh_r};
            MCYCLE:    rdata = mcycle_r[31:0];
            MCYCLEH:   rdata = mcycle_r[63:32];
            MINSTRET:  rdata = minstret_r[31:0];
            MINSTRETH: rdata = minstret_r[63:32];
            DSU_OVF:   rdata = {31'd0, dsu_overflow_i};
            default:   begin rdata = 32'd0; implemented = 1'b0; end
        endcase
        csr_rdata_o = rdata;
    end

    // read-only addresses: writing them is illegal
    wire is_ro = (csr_addr_i==MVENDORID)||(csr_addr_i==MARCHID)||(csr_addr_i==MIMPID)||
                 (csr_addr_i==MHARTID)||(csr_addr_i==MISA)||(csr_addr_i==MINTSTATUS)||
                 (csr_addr_i==DSU_OVF)||(csr_addr_i==MIP);
    wire access      = csr_en_i && (csr_op_i != 2'b00);
    wire is_write    = access && (csr_op_i == `CSR_RW ||
                                  ((csr_op_i==`CSR_RS||csr_op_i==`CSR_RC) && (csr_wdata_i!=32'd0)));
    assign illegal_csr_o = access && (!implemented || (is_write && is_ro));

    // dsu_ovf read clears overflow (Sec. 13.2)
    assign csr_clear_overflow_o = csr_en_i && (csr_addr_i==DSU_OVF) && (csr_op_i!=2'b00);

    // next value of a written CSR under RW/RS/RC
    function [31:0] nextv; input [31:0] cur; input [31:0] w; input [1:0] op;
        begin
            case (op)
                `CSR_RW: nextv = w;
                `CSR_RS: nextv = cur |  w;
                `CSR_RC: nextv = cur & ~w;
                default: nextv = cur;
            endcase
        end
    endfunction
    wire wr_ok = is_write && !is_ro && implemented;
    wire [31:0] mstatus_next    = nextv(mstatus_val, csr_wdata_i, csr_op_i);
    wire [31:0] mintthresh_next = nextv({24'd0,mintthresh_r}, csr_wdata_i, csr_op_i);

    assign mstatus_mie_o = mstatus_mie;
    assign mtvec_o       = mtvec_r;
    assign mtvt_o        = mtvt_r;
    assign mepc_o        = mepc_r;
    assign mintthresh_o    = mintthresh_r;
    assign mintstatus_mil_o= mil_r;

    always @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            mstatus_mie<=1'b0; mstatus_mpie<=1'b0;
            mtvec_r<=32'd0; mtvt_r<=32'd0; mie_r<=32'd0; mepc_r<=32'd0;
            mcause_r<=32'd0; mtval_r<=32'd0; mscratch_r<=32'd0; mintthresh_r<=8'd0;
            mcycle_r<=64'd0; minstret_r<=64'd0;
            mil_r<=8'd0; mpil_r<=8'd0;
        end else begin
            mcycle_r   <= mcycle_r + 64'd1;
            if (instret_i) minstret_r <= minstret_r + 64'd1;

            // Trap entry/exit take precedence over CSR-instruction writes.
            if (trap_enter_i) begin
                mepc_r      <= trap_pc_i;
                mcause_r    <= trap_cause_i;
                mtval_r     <= trap_tval_i;
                mstatus_mpie<= mstatus_mie;
                mstatus_mie <= 1'b0;
                if (is_interrupt_i) begin        // push interrupt level (Sec.14.3/14.4)
                    mpil_r <= mil_r;
                    mil_r  <= clic_level_i;
                end
            end else if (mret_i) begin
                mstatus_mie <= mstatus_mpie;
                mstatus_mpie<= 1'b1;
                mil_r       <= mpil_r;           // restore interrupt level (Sec.14.4)
            end else if (wr_ok) begin
                case (csr_addr_i)
                    MSTATUS:  begin mstatus_mie <= mstatus_next[3];
                                    mstatus_mpie<= mstatus_next[7]; end
                    MTVEC:    mtvec_r    <= nextv(mtvec_r,    csr_wdata_i, csr_op_i);
                    MTVT:     mtvt_r     <= nextv(mtvt_r,     csr_wdata_i, csr_op_i);
                    MIE:      mie_r      <= nextv(mie_r,      csr_wdata_i, csr_op_i);
                    MEPC:     mepc_r     <= nextv(mepc_r,     csr_wdata_i, csr_op_i) & ~32'd1;
                    MCAUSE:   mcause_r   <= nextv(mcause_r,   csr_wdata_i, csr_op_i);
                    MTVAL:    mtval_r    <= nextv(mtval_r,    csr_wdata_i, csr_op_i);
                    MSCRATCH: mscratch_r <= nextv(mscratch_r, csr_wdata_i, csr_op_i);
                    MINTTHRESH: mintthresh_r <= mintthresh_next[7:0];
                    default: ; // counters/RO handled elsewhere or ignored
                endcase
            end
        end
    end
endmodule
`default_nettype wire
