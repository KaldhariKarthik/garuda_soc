`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 16: CLIC
// clic_apb_regs.v - APB configuration register file (pclk domain)
//
// Spec reference: GARUDA-CLIC-SPEC-001 Rev 2.0, Sec. 5.1.1, Sec. 5.3, Sec. 6,
//                 Sec. 11
//
// Holds clicintie, clicintattr and clicintctl. It does NOT hold clicintip:
// pending is generated and cleared in the core clock domain by
// clic_source_cond, and is only read through (and W1C-written from) here.
//
// =============================================================================
// THIS BLOCK SPANS TWO CLOCKS AND INSTANTIATES NO SYNCHRONISERS (Sec. 5.1.1)
// =============================================================================
// The configuration state is written in pclk (100 MHz) and read every cycle by
// the arbiter in clk (200 MHz). That boundary is DEFINED, not assumed: Block 22
// derives pclk by dividing clk by two with a single flop from the same source,
// so the two are edge-aligned with a fixed integer ratio, every clk edge is in
// a known phase relationship to every pclk edge, and no metastability is
// possible on a path between them. The arbiter therefore reads these registers
// over ordinary synchronous timing paths.
//
// TWO CONSEQUENCES, BOTH REQUIREMENTS:
//
//   STA MUST MODEL THE RELATIONSHIP. pclk is constrained as a generated ÷2 of
//   clk with the correct source. The paths from these pclk-launched flops to
//   the clk-capturing arbiter are REAL, ANALYSABLE SETUP PATHS and must be
//   timed as such. They must NOT be declared false paths or asynchronous clock
//   groups - doing so leaves a genuine setup path unchecked, and the failure
//   appears only in silicon.
//
//   UPDATE ATOMICITY IS PER-REGISTER AND BENIGN. All bits of a given register
//   launch on the same pclk edge, so a clk sample sees either the complete old
//   value or the complete new one, never a mixture. A configuration change
//   landing between two clk edges simply takes effect on the next evaluation -
//   one clk cycle of skew between "firmware wrote the enable" and "the arbiter
//   honoured it", which is architecturally invisible: an interrupt presented
//   one cycle later is indistinguishable from one that became pending one cycle
//   later.
//
// IMPORTANT: the AHB-to-APB bridge does NOT solve this boundary. The bridge
// synchronises the transfer across its own 200/100 crossing and delivers the
// write INTO the pclk domain - it delivers nothing into clk. The pclk-to-clk
// boundary is internal to this block and is this block's responsibility.
//
// If the clock relationship ever changes - pclk from an independent source
// rather than a ÷2 - this assumption is void and every configuration bit needs
// a two-flop synchroniser. That is a specification change, not an RTL decision.
//
// =============================================================================
// RESET POSTURE (Sec. 11)
// =============================================================================
// Everything resets to zero: every enable low and every level 0, so no source
// is active and no interrupt is presented until firmware programmes the map.
// That is the correct boot posture - the bootloader runs with interrupts
// effectively masked and opts sources in as it initialises each peripheral.
// =============================================================================

`include "clic_defs.vh"

module clic_apb_regs #(
    parameter integer CLIC_N = `CLIC_N_DEFAULT
)(
    input  wire        pclk_i,
    input  wire        preset_n_i,

    // ---- APB v3 slave (Sec. 5.3) -----------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output reg  [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- configuration out to the clk-domain fabric ----------------------
    output wire [CLIC_N-1:0]               ie_o,
    output wire [CLIC_N-1:0]               trig_o,
    output wire [CLIC_N-1:0]               shv_o,
    output wire [(CLIC_N*`CLIC_LVL_W)-1:0] lvl_flat_o,

    // ---- pending: read from, and W1C-cleared into, the clk domain ---------
    input  wire [CLIC_N-1:0]               ip_i,
    output wire [CLIC_N-1:0]               ip_w1c_o
);

    // -----------------------------------------------------------------------
    // Address decode. PADDR[11:10] picks the register group, PADDR[9:0] the
    // source index.
    //
    // An index beyond CLIC_N is unimplemented: writes are ignored and reads
    // return zero, and PSLVERR is raised so a stray access is visible rather
    // than silent. Aliasing index 40 onto index 8 - which a bare index mux
    // without a range check would do - would mean a stray pointer silently
    // reprogramming a live interrupt source.
    // -----------------------------------------------------------------------
    wire [1:0]  grp   = paddr_i[11:10];
    wire [9:0]  idx   = paddr_i[9:0];
    wire        idx_ok = (idx < CLIC_N[9:0]);

    wire        access = psel_i && penable_i;
    wire        wr     = access && pwrite_i && idx_ok;

    assign pready_o  = 1'b1;                    // single-cycle, Sec. 5.3
    assign pslverr_o = access && !idx_ok;       // undefined offset, Sec. 5.3

    // -----------------------------------------------------------------------
    // Register storage
    // -----------------------------------------------------------------------
    reg [CLIC_N-1:0]        ie_q;
    reg [CLIC_N-1:0]        trig_q;
    reg [CLIC_N-1:0]        shv_q;
    reg [`CLIC_LVL_W-1:0]   lvl_q [0:CLIC_N-1];

    // W1C strobe into the clk domain. One-hot on the addressed index, asserted
    // for the ACCESS phase only - see clic_source_cond.v on why a two-clk-wide
    // clear is harmless for a level source.
    reg [CLIC_N-1:0] ip_w1c_q;
    assign ip_w1c_o = ip_w1c_q;

    integer k;

    always @(posedge pclk_i or negedge preset_n_i) begin
        if (!preset_n_i) begin
            ie_q     <= {CLIC_N{1'b0}};
            trig_q   <= {CLIC_N{1'b0}};   // level-sensitive default, Sec. 13.4
            shv_q    <= {CLIC_N{1'b0}};
            ip_w1c_q <= {CLIC_N{1'b0}};
            for (k = 0; k < CLIC_N; k = k + 1)
                lvl_q[k] <= {`CLIC_LVL_W{1'b0}};   // level 0 = never interrupts
        end else begin
            ip_w1c_q <= {CLIC_N{1'b0}};

            if (wr) begin
                case (grp)
                    `CLIC_GRP_IP: begin
                        // W1C: writing 1 clears an edge-latched pending. A
                        // level source re-sets immediately while its line is
                        // high, which is intended (Sec. 6.3, Sec. 8.4).
                        if (pwdata_i[0]) ip_w1c_q[idx[9:0]] <= 1'b1;
                    end
                    `CLIC_GRP_IE:   ie_q[idx[9:0]]   <= pwdata_i[0];
                    `CLIC_GRP_ATTR: begin
                        trig_q[idx[9:0]] <= pwdata_i[`CLIC_ATTR_TRIG];
                        shv_q [idx[9:0]] <= pwdata_i[`CLIC_ATTR_SHV];
                    end
                    default:        lvl_q[idx[9:0]]  <=
                                      pwdata_i[`CLIC_CTL_LVL_HI:`CLIC_CTL_LVL_LO];
                endcase
            end
        end
    end

    // -----------------------------------------------------------------------
    // Read mux. Combinational, returning 0 for an unimplemented index so a
    // reserved read is a defined 0 rather than the last selected register.
    // Reserved bits read as 0 throughout (Sec. 6.3-6.5).
    // -----------------------------------------------------------------------
    always @(*) begin
        prdata_o = 32'h0000_0000;
        if (psel_i && !pwrite_i && idx_ok) begin
            case (grp)
                `CLIC_GRP_IP:   prdata_o = {31'b0, ip_i[idx[9:0]]};
                `CLIC_GRP_IE:   prdata_o = {31'b0, ie_q[idx[9:0]]};
                `CLIC_GRP_ATTR: prdata_o = {30'b0, shv_q[idx[9:0]],
                                                   trig_q[idx[9:0]]};
                default:        prdata_o = {24'b0,
                                            lvl_q[idx[9:0]],
                                            5'b0};   // LEVEL in [7:5]
            endcase
        end
    end

    // -----------------------------------------------------------------------
    // Fan-out to the fabric
    // -----------------------------------------------------------------------
    assign ie_o   = ie_q;
    assign trig_o = trig_q;
    assign shv_o  = shv_q;

    genvar g;
    generate
        for (g = 0; g < CLIC_N; g = g + 1) begin : g_lvl
            assign lvl_flat_o[(g*`CLIC_LVL_W) +: `CLIC_LVL_W] = lvl_q[g];
        end
    endgenerate

endmodule

`default_nettype wire
