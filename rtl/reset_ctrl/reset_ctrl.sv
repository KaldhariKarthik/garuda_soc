// =============================================================================
// GARUDA SoC - Block 22 : reset controller
// reset_ctrl.v
//
// Spec: GARUDA-CLKRST-SPEC-001 Rev 2.0 (Rev 4.0 set), Sec.5.2, Sec.6,
// Sec.7.2-Sec.7.5
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

module reset_ctrl
    import garuda_pkg::*;
#(
    parameter int unsigned STRETCH = 32'd1024  // GARUDA_RESET_STRETCH_CYCLES
)(
    // ---- clocks ------------------------------------------------------------
    input wire aon_clk,  // stretch + RSTREASON clock
    input wire hclk,
    input wire pclk,
    // ---- sources -----------------------------------------------------------
    input wire ext_rst_n,  // pin, async, active-low
    input wire wdt_rst_req_i,  // hclk, pulse
    input wire ndm_rst_req_i,  // hclk, level (dmcontrol.ndmreset)
    input wire hartreset_req_i,  // hclk, level (dmcontrol.hartreset/haltreq)
    input wire boot_sel_i,  // pin, async (read at CLKSTAT[8], D-19)
    // ---- APB slave, window 9 (pclk) ----------------------------------------
    input wire psel_i,
    input wire penable_i,
    input wire pwrite_i,
    input wire [PADDR_W-1:0] paddr_i,
    input wire [WORD_W-1:0] pwdata_i,
    output wire [WORD_W-1:0] prdata_o,
    output wire pready_o,
    output wire pslverr_o,
    // ---- clk_div interface -------------------------------------------------
    output wire [DIV_SEL_W-1:0] div_sel_o,
    input wire [DIV_SEL_W-1:0] div_act_i,
    input wire div_busy_i,
    // ---- MEMCTL ------------------------------------------------------------
    output wire ilock_o,  // to isram (hclk-domain consumer)
    // ---- distributed resets ------------------------------------------------
    output wire hreset_n,  // fabric, memories, DMA, CLIC, timers
    output wire preset_n,  // bridge pclk side, APB registers
    output wire core_rst_n,  // core + DSU
    output wire dm_rst_n,  // Debug Module (outside ndmreset)
    // ext-only, hclk (watchdog request flop)
    output wire ext_hrst_n
);
    timeunit 1ns;
    timeprecision 1ps;
    localparam int unsigned EXT_SYNC_W = 32'd2;
    localparam int unsigned REASON_W = 32'd4;
    localparam int unsigned HRST_W = 32'd2;
    localparam int unsigned DM_W = 32'd2;
    localparam int unsigned EXTH_W = 32'd2;
    localparam int unsigned PRST_W = 32'd2;
    localparam int unsigned EXTP_W = 32'd2;

    localparam int unsigned CNT_W = $clog2(STRETCH + 1);

    // =========================================================================
    // Strobes from the APB register block (pclk domain, one pclk cycle long)
    // =========================================================================
    wire       swrst_stb;
    wire [RST_CAUSE_W-1:0] reason_w1c;
    wire       bootfail_set;

    // =========================================================================
    // aon domain: ext synchroniser, stretch counter, request flops
    // =========================================================================
    reg [EXT_SYNC_W-1:0] ext_sync_q;
    always_ff @(posedge aon_clk or negedge ext_rst_n) begin : p_ext_sync
        if (!ext_rst_n) begin
            ext_sync_q <= 2'b00;
        end else begin
            ext_sync_q <= {ext_sync_q[0], 1'b1};
        end
    end
    wire ext_held = ~ext_sync_q[1];

    wire req_dm_scope = wdt_rst_req_i | swrst_stb;  // resets the DM too
    wire req_any      = ext_held | req_dm_scope | ndm_rst_req_i;

    reg [CNT_W-1:0] cnt_q;
    reg          dm_scope_q;
    wire [CNT_W-1:0] cnt_nxt = req_any       ? STRETCH[CNT_W-1:0] :
                            |cnt_q ? CNT_W'(cnt_q - 1'b1) : cnt_q;
    wire stretching   = |cnt_nxt;
    wire dm_scope_nxt = (ext_held || req_dm_scope) ? 1'b1 :
                        !stretching                ? 1'b0 : dm_scope_q;

    reg sys_req_q;
    reg dm_req_q;
    reg core_clr;
    always_ff @(posedge aon_clk or negedge ext_rst_n) begin : p_cnt
        if (!ext_rst_n) begin
            cnt_q <= STRETCH[CNT_W - 1:0];
            dm_scope_q <= 1'b1;
            sys_req_q <= 1'b1;
            dm_req_q <= 1'b1;
            core_clr <= 1'b1;
        end else begin
            cnt_q <= cnt_nxt;
            dm_scope_q <= dm_scope_nxt;
            sys_req_q <= stretching;
            dm_req_q <= stretching & dm_scope_nxt;
            core_clr <= stretching;
        end
    end

    // =========================================================================
    // RSTREASON (aon domain, cleared only by the pin - D-8, [N-6.1])
    // Exactly one of [3:0] per reset event ([N-6.2]); BOOTFAIL is orthogonal.
    //
    // ERRATUM CRG-3 (2026-10-14). A reset event lasts from its first request
    // until the stretch counter has run out: that is sys_req_q. The cause is
    // taken from the request that STARTS the event and is then held. It used
    // to be rewritten in every cycle a request was up, so of two requests that
    // overlapped the one that ended last was recorded: a watchdog expiry (a
    // request two or three cycles long) followed within those cycles by the
    // debugger's ndmreset (a level) read NDM, and the firmware's watchdog
    // recovery path was not taken although the watchdog had caused the reset.
    // A request that arrives while an event is in progress still extends the
    // reset ([N-7.8]); it no longer changes the cause. Two requests in the
    // event's first cycle: watchdog, then software, then debugger.
    // =========================================================================
    reg [REASON_W-1:0] reason_q;  // {SW, NDM, WDT, EXT}
    reg       bootfail_q;
    wire      cause_req = wdt_rst_req_i | swrst_stb | ndm_rst_req_i;
    always_ff @(posedge aon_clk or negedge ext_rst_n) begin : p_reason
        if (!ext_rst_n) begin
            reason_q <= 4'b0001;
            bootfail_q <= 1'b0;
        end else begin
            if (cause_req && !sys_req_q) begin
                reason_q <= wdt_rst_req_i ? 4'b0010 : swrst_stb ? 4'b1000
                    : 4'b0100;
            end else begin
                reason_q <= reason_q & ~reason_w1c[3:0];
            end
            if (bootfail_set) begin
                bootfail_q <= 1'b1;
            end else if (reason_w1c[4]) begin
                bootfail_q <= 1'b0;
            end
        end
    end

    // =========================================================================
    // Release synchronisers
    // =========================================================================
    reg [HRST_W-1:0] hrst_q;
    reg [DM_W-1:0] dm_q;
    reg [EXTH_W-1:0] exth_q;
    always_ff @(posedge hclk or posedge sys_req_q) begin : p_hrst
        if (sys_req_q) begin
            hrst_q <= 2'b00;
        end else begin
            hrst_q <= {hrst_q[0], 1'b1};
        end
    end
    // The core's reset (D-36, 2026-11-16) also falls for the Debug Module's
    // hartreset grant ([N-7.13]), sampled on hclk: core_rst_sync.v. Until then
    // the grant reached the core through the aon-clocked core_clr and, without
    // waiting, through an AND gate inside the core.
    core_rst_sync u_core_rst_sync (
        .hclk(hclk), .core_clr(core_clr), .hartreset_req_i(hartreset_req_i),
        .core_rst_n(core_rst_n));
    always_ff @(posedge hclk or posedge dm_req_q) begin : p_dm
        if (dm_req_q) begin
            dm_q <= 2'b00;
        end else begin
            dm_q <= {dm_q[0], 1'b1};
        end
    end
    always_ff @(posedge hclk or negedge ext_rst_n) begin : p_exth
        if (!ext_rst_n) begin
            exth_q <= 2'b00;
        end else begin
            exth_q <= {exth_q[0], 1'b1};
        end
    end

    reg [PRST_W-1:0] prst_q;
    reg [EXTP_W-1:0] extp_q;
    always_ff @(posedge pclk or posedge sys_req_q) begin : p_prst
        if (sys_req_q) begin
            prst_q <= 2'b00;
        end else begin
            prst_q <= {prst_q[0], hrst_q[1]};
        end
    end
    always_ff @(posedge pclk or negedge ext_rst_n) begin : p_extp
        if (!ext_rst_n) begin
            extp_q <= 2'b00;
        end else begin
            extp_q <= {extp_q[0], 1'b1};
        end
    end

    assign hreset_n   = hrst_q[1];
    assign dm_rst_n   = dm_q[1];
    assign ext_hrst_n = exth_q[1];
    assign preset_n   = prst_q[1];
    wire   ext_prst_n   = extp_q[1];

    // =========================================================================
    // APB registers (pclk)
    // =========================================================================
    // RSTREASON as the register holds it: {BOOTFAIL, SW, NDM, WDT, EXT}
    wire [RST_CAUSE_W-1:0] reason_all = {bootfail_q, reason_q};

    reset_ctrl_apb u_apb (
        .pclk        (pclk),
        .preset_n    (preset_n),
        .ext_prst_n  (ext_prst_n),
        .psel_i        (psel_i),
        .penable_i     (penable_i),
        .pwrite_i      (pwrite_i),
        .paddr_i       (paddr_i),
        .pwdata_i      (pwdata_i),
        .prdata_o      (prdata_o),
        .pready_o      (pready_o),
        .pslverr_o     (pslverr_o),
        .reason_i      (reason_all),
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
