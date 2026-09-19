`timescale 1ns/1ps
`default_nettype none
// =============================================================================
// GARUDA SoC - Block 22 : reset controller
// reset_ctrl.v
//
// Spec: GARUDA-CLKRST-SPEC-001 Rev 2.0 (Rev 4.0 set), §5.2, §6, §7.2-§7.5
//       Rulings: Docs/DECISIONS.md D-8 (RSTREASON), D-9 (stretch, DM domain),
//                D-14 (stretch clock)
//
// -----------------------------------------------------------------------------
// SOURCES AND DOMAINS ([N-7.11])
// -----------------------------------------------------------------------------
//   request         resets                               does NOT reset
//   ext_rst_n       everything                           RSTREASON (sets EXT)
//   wdt_rst_req     hreset/preset/core/dm                watchdog request flop,
//                                                        RSTREASON, DIVSEL
//   swrst (RSTCTL)  hreset/preset/core/dm                RSTREASON, DIVSEL
//   ndm_rst_req     hreset/preset/core                   DM + TAP (dm_rst_n_o),
//                                                        RSTREASON, DIVSEL
//   hartreset_req   core only (not stretched, [N-7.13])  everything else
//
// The watchdog's request flop sits on ext_hrst_n_o, which only the pin drives
// ([N-7.12]). DIVSEL sits on an ext-only pclk reset ([N-6.5]).
//
// -----------------------------------------------------------------------------
// STRETCH ([N-7.7]..[N-7.10])
// -----------------------------------------------------------------------------
// One 1024-cycle down counter on aon_clk (refclk/2, always running - D-14). Any
// request reloads it; the functional resets stay asserted until it expires.
// 1024 aon cycles = 2048 refclk cycles, which meets R-5's ">= 1024 reference
// cycles" while keeping the 500 MHz net confined to the divider flop (R-10).
//
// -----------------------------------------------------------------------------
// ASSERTION / RELEASE ([N-7.14], [N-7.15], [N-7.17])
// -----------------------------------------------------------------------------
// Every async clear in this file is driven by a FLOP output (or the raw pin),
// never by combinational logic, so no reset net can glitch. Each domain
// releases through its own 2-flop synchroniser. preset_n's synchroniser shifts
// in hreset_n rather than 1, so pclk can never leave reset before hclk.
//
// All request inputs come from hclk/pclk logic, whose rising edges are a subset
// of aon_clk's rising edges; sampling them on aon_clk is a synchronous path,
// and a one-hclk-cycle pulse lasts at least one aon cycle.
// =============================================================================

module reset_ctrl #(
    parameter integer STRETCH = 1024          // GARUDA_RESET_STRETCH_CYCLES
)(
    // ---- clocks ------------------------------------------------------------
    input  wire        aon_clk_i,             // stretch + RSTREASON clock
    input  wire        hclk_i,
    input  wire        pclk_i,

    // ---- sources -----------------------------------------------------------
    input  wire        ext_rst_n_i,           // pin, async, active-low
    input  wire        wdt_rst_req_i,         // hclk, pulse
    input  wire        ndm_rst_req_i,         // hclk, level (dmcontrol.ndmreset)
    input  wire        hartreset_req_i,       // hclk, level (dmcontrol.hartreset/haltreq)
    input  wire        boot_sel_i,            // pin, async (read at CLKSTAT[8], D-19)

    // ---- APB slave, window 9 (pclk) ----------------------------------------
    input  wire        psel_i,
    input  wire        penable_i,
    input  wire        pwrite_i,
    input  wire [11:0] paddr_i,
    input  wire [31:0] pwdata_i,
    output wire [31:0] prdata_o,
    output wire        pready_o,
    output wire        pslverr_o,

    // ---- clk_div interface -------------------------------------------------
    output wire [1:0]  div_sel_o,
    input  wire [1:0]  div_act_i,
    input  wire        div_busy_i,

    // ---- MEMCTL ------------------------------------------------------------
    output wire        ilock_o,               // to isram (hclk-domain consumer)

    // ---- distributed resets ------------------------------------------------
    output wire        hreset_n_o,            // fabric, memories, DMA, CLIC, timers
    output wire        preset_n_o,            // bridge pclk side, APB registers
    output wire        core_rst_n_o,          // core + DSU
    output wire        dm_rst_n_o,            // Debug Module (outside ndmreset)
    output wire        ext_hrst_n_o           // ext-only, hclk (watchdog request flop)
);

    localparam integer CW = $clog2(STRETCH + 1);

    // =========================================================================
    // Strobes from the APB register block (pclk domain, one pclk cycle long)
    // =========================================================================
    wire       swrst_stb;
    wire [4:0] reason_w1c;
    wire       bootfail_set;

    // =========================================================================
    // aon domain: ext synchroniser, stretch counter, request flops
    // =========================================================================
    reg [1:0] ext_sync_q;
    always @(posedge aon_clk_i or negedge ext_rst_n_i)
        if (!ext_rst_n_i) ext_sync_q <= 2'b00;
        else              ext_sync_q <= {ext_sync_q[0], 1'b1};
    wire ext_held = ~ext_sync_q[1];

    wire req_dm_scope = wdt_rst_req_i | swrst_stb;      // resets the DM too
    wire req_any      = ext_held | req_dm_scope | ndm_rst_req_i;

    reg [CW-1:0] cnt_q;
    reg          dm_scope_q;
    wire [CW-1:0] cnt_nxt = req_any       ? STRETCH[CW-1:0] :
                            (cnt_q != 0)  ? cnt_q - 1'b1    : cnt_q;
    wire dm_scope_nxt = (ext_held | req_dm_scope) ? 1'b1 :
                        (cnt_nxt == 0)            ? 1'b0 : dm_scope_q;

    reg sys_req_q, dm_req_q, core_req_q;
    always @(posedge aon_clk_i or negedge ext_rst_n_i) begin
        if (!ext_rst_n_i) begin
            cnt_q      <= STRETCH[CW-1:0];
            dm_scope_q <= 1'b1;
            sys_req_q  <= 1'b1;
            dm_req_q   <= 1'b1;
            core_req_q <= 1'b1;
        end else begin
            cnt_q      <= cnt_nxt;
            dm_scope_q <= dm_scope_nxt;
            sys_req_q  <= (cnt_nxt != 0);
            dm_req_q   <= (cnt_nxt != 0) & dm_scope_nxt;
            core_req_q <= (cnt_nxt != 0) | hartreset_req_i;
        end
    end

    // =========================================================================
    // RSTREASON (aon domain, cleared only by the pin - D-8, [N-6.1])
    // Exactly one of [3:0] per reset event ([N-6.2]); BOOTFAIL is orthogonal.
    // =========================================================================
    reg [3:0] reason_q;       // {SW, NDM, WDT, EXT}
    reg       bootfail_q;
    always @(posedge aon_clk_i or negedge ext_rst_n_i) begin
        if (!ext_rst_n_i) begin
            reason_q   <= 4'b0001;
            bootfail_q <= 1'b0;
        end else begin
            if      (wdt_rst_req_i) reason_q <= 4'b0010;
            else if (swrst_stb)     reason_q <= 4'b1000;
            else if (ndm_rst_req_i) reason_q <= 4'b0100;
            else                    reason_q <= reason_q & ~reason_w1c[3:0];

            if      (bootfail_set)  bootfail_q <= 1'b1;
            else if (reason_w1c[4]) bootfail_q <= 1'b0;
        end
    end

    // =========================================================================
    // Release synchronisers
    // =========================================================================
    reg [1:0] hrst_q, core_q, dm_q, exth_q;
    always @(posedge hclk_i or posedge sys_req_q)
        if (sys_req_q) hrst_q <= 2'b00; else hrst_q <= {hrst_q[0], 1'b1};
    always @(posedge hclk_i or posedge core_req_q)
        if (core_req_q) core_q <= 2'b00; else core_q <= {core_q[0], 1'b1};
    always @(posedge hclk_i or posedge dm_req_q)
        if (dm_req_q) dm_q <= 2'b00; else dm_q <= {dm_q[0], 1'b1};
    always @(posedge hclk_i or negedge ext_rst_n_i)
        if (!ext_rst_n_i) exth_q <= 2'b00; else exth_q <= {exth_q[0], 1'b1};

    reg [1:0] prst_q, extp_q;
    always @(posedge pclk_i or posedge sys_req_q)
        if (sys_req_q) prst_q <= 2'b00; else prst_q <= {prst_q[0], hrst_q[1]};
    always @(posedge pclk_i or negedge ext_rst_n_i)
        if (!ext_rst_n_i) extp_q <= 2'b00; else extp_q <= {extp_q[0], 1'b1};

    assign hreset_n_o   = hrst_q[1];
    assign core_rst_n_o = core_q[1];
    assign dm_rst_n_o   = dm_q[1];
    assign ext_hrst_n_o = exth_q[1];
    assign preset_n_o   = prst_q[1];
    wire   ext_prst_n   = extp_q[1];

    // =========================================================================
    // APB registers (pclk)
    // =========================================================================
    reset_ctrl_apb u_apb (
        .pclk_i        (pclk_i),
        .preset_n_i    (prst_q[1]),
        .ext_prst_n_i  (ext_prst_n),
        .psel_i        (psel_i),
        .penable_i     (penable_i),
        .pwrite_i      (pwrite_i),
        .paddr_i       (paddr_i),
        .pwdata_i      (pwdata_i),
        .prdata_o      (prdata_o),
        .pready_o      (pready_o),
        .pslverr_o     (pslverr_o),
        .reason_i      ({bootfail_q, reason_q}),
        .reason_w1c_o  (reason_w1c),
        .bootfail_set_o(bootfail_set),
        .swrst_o       (swrst_stb),
        .div_sel_o     (div_sel_o),
        .div_act_i     (div_act_i),
        .div_busy_i    (div_busy_i),
        .boot_sel_i    (boot_sel_i),
        .ilock_o       (ilock_o)
    );

endmodule

`default_nettype wire
