`timescale 1ns/1ps
// =============================================================================
// GARUDA SoC - Block 23 : properties for the reset controller
// reset_ctrl_sva.sv
//
// Spec: GARUDA-CLKRST-SPEC-001 sections 6 and 7.2 to 7.4. Plan:
// tb/clk_div/GARUDA_CLKRST_vplan.csv; each property names its feature. Bound to
// reset_ctrl, so the properties run in the block bench, in the UVM environment
// and in every chip simulation. Not compiled for synthesis or lint.
// =============================================================================
`ifndef SYNTHESIS
module reset_ctrl_sva #(
    parameter integer STRETCH = 1024
)(
    input wire       aon_clk_i, hclk_i, pclk_i,
    input wire       ext_rst_n_i,
    input wire       wdt_rst_req_i, ndm_rst_req_i, hartreset_req_i,
    input wire       psel_i, penable_i, pwrite_i,
    input wire [11:0] paddr_i,
    input wire       pready_o,
    input wire [1:0] div_sel_o,
    input wire       ilock_o,
    input wire       hreset_n_o, preset_n_o, core_rst_n_o, dm_rst_n_o, ext_hrst_n_o,
    input wire       swrst_stb,
    input wire [3:0] reason_q,
    input wire [4:0] reason_w1c,
    input wire       ext_held
);
    wire sys_req = ext_held | wdt_rst_req_i | swrst_stb | ndm_rst_req_i;
    wire dm_req  = ext_held | wdt_rst_req_i | swrst_stb;

    // ---- bookkeeping on the always-on clock ---------------------------------
    integer low_h = 0, low_p = 0, since_req = 0;
    reg     sys_cause = 1'b1, dm_cause = 1'b1;     // a request that explains the reset in force
    always @(posedge aon_clk_i or negedge ext_rst_n_i)
        if (!ext_rst_n_i) begin low_h <= 0; low_p <= 0; since_req <= 0; sys_cause <= 1'b1; dm_cause <= 1'b1; end
        else begin
            low_h     <= hreset_n_o ? 0 : low_h + 1;
            low_p     <= preset_n_o ? 0 : low_p + 1;
            since_req <= sys_req ? 0 : since_req + 1;
            sys_cause <= sys_req | (sys_cause & ~(hreset_n_o & preset_n_o));   // preset_n is released after hreset_n
            dm_cause  <= dm_req  | (dm_cause  & ~dm_rst_n_o);
        end

    // ---- F17: no reset of the system is shorter than the stretch -------------------
    a_reset_min_duration: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        $rose(hreset_n_o) |-> (low_h >= STRETCH))
        else $error("[SVA-FAIL] a_reset_min_duration: hreset_n was low for %0d always-on cycles", low_h);
    a_preset_min_duration: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        $rose(preset_n_o) |-> (low_p >= STRETCH))
        else $error("[SVA-FAIL] a_preset_min_duration: preset_n was low for %0d always-on cycles", low_p);
    // ---- F18: and it ends: the counter runs on the always-on clock whatever hclk does
    a_reset_ends: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        (!hreset_n_o) |-> (since_req <= STRETCH + 80))
        else $error("[SVA-FAIL] a_reset_ends: hreset_n still low %0d cycles after the last request", since_req);
    // ---- F21, F25: scope. hreset falls only for a system request; the Debug Module is
    //      reset only by the pin, the watchdog or software; hartreset touches the core alone
    a_hartreset_scope: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        (!hreset_n_o || !preset_n_o) |-> sys_cause)
        else $error("[SVA-FAIL] a_hartreset_scope: the system reset is low with no system request");
    a_reset_scope: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        !dm_rst_n_o |-> dm_cause)
        else $error("[SVA-FAIL] a_reset_scope: the Debug Module is in reset with no pin, watchdog or software request");
    // (the pin is asynchronous and may pulse between two clock edges, so this one is
    //  checked at the instant the output falls)
    always @(negedge ext_hrst_n_o) a_ext_only: assert (ext_rst_n_i === 1'b0)
        else $error("[SVA-FAIL] a_ext_only: ext_hrst_n fell with the pin high");
    a_core_follows_system: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        !hreset_n_o |-> !core_rst_n_o)
        else $error("[SVA-FAIL] a_core_follows_system: the core is out of reset while the bus is in reset");
    // ---- F24: preset_n never high while hreset_n is low ---------------------------------
    a_release_order: assert property (@(posedge aon_clk_i) !hreset_n_o |-> !preset_n_o)
        else $error("[SVA-FAIL] a_release_order");
    // ---- F22: the pin asserts every reset at once, with no clock --------------------------
    always @(negedge ext_rst_n_i) begin
        #0.001;
        a_async_assert: assert (!hreset_n_o && !preset_n_o && !core_rst_n_o && !dm_rst_n_o && !ext_hrst_n_o)
            else $error("[SVA-FAIL] a_async_assert: h=%b p=%b core=%b dm=%b ext_h=%b", hreset_n_o, preset_n_o, core_rst_n_o, dm_rst_n_o, ext_hrst_n_o);
    end
    // ---- F23: release is on a clock edge of the domain -------------------------------------
    realtime t_h = 0, t_p = 0;
    always @(posedge hclk_i) t_h = $realtime;
    always @(posedge pclk_i) t_p = $realtime;
    always @(posedge hreset_n_o)   a_sync_release_hclk: assert ($realtime == t_h)
        else $error("[SVA-FAIL] a_sync_release_hclk: hreset_n rose at %0t, last hclk rise %0t", $realtime, t_h);
    always @(posedge core_rst_n_o) a_sync_release_core: assert ($realtime == t_h)
        else $error("[SVA-FAIL] a_sync_release_core: core_rst_n rose at %0t, last hclk rise %0t", $realtime, t_h);
    always @(posedge dm_rst_n_o)   a_sync_release_dm: assert ($realtime == t_h)
        else $error("[SVA-FAIL] a_sync_release_dm");
    always @(posedge preset_n_o)   a_sync_release_pclk: assert ($realtime == t_p)
        else $error("[SVA-FAIL] a_sync_release_pclk: preset_n rose at %0t, last pclk rise %0t", $realtime, t_p);

    // ---- F01, F02: the cause register --------------------------------------------------------
    a_reason_ext: assert property (@(posedge aon_clk_i) !ext_rst_n_i |-> (reason_q == 4'b0001))
        else $error("[SVA-FAIL] a_reason_ext");
    a_reason_onehot: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        (ext_rst_n_i && (wdt_rst_req_i || swrst_stb || ndm_rst_req_i)) |=> $onehot(reason_q))
        else $error("[SVA-FAIL] a_reason_onehot: %04b", reason_q);
    a_reason_survives: assert property (@(posedge aon_clk_i) disable iff (!ext_rst_n_i)
        (ext_rst_n_i && !wdt_rst_req_i && !swrst_stb && !ndm_rst_req_i && reason_w1c[3:0] == 4'b0) |=> $stable(reason_q))
        else $error("[SVA-FAIL] a_reason_survives: the cause changed with no request and no clear");
    // ---- F05: DIVSEL is not touched by a reset other than the pin ---------------------------
    reg [1:0] ext_ok_p;                            // the pin has been high for two pclk edges
    always @(posedge pclk_i or negedge ext_rst_n_i)
        if (!ext_rst_n_i) ext_ok_p <= 2'b00; else ext_ok_p <= {ext_ok_p[0], 1'b1};
    a_divsel_survives_swrst: assert property (@(posedge pclk_i) disable iff (!ext_rst_n_i)
        (ext_ok_p == 2'b11 && $changed(div_sel_o)) |-> $past(psel_i && penable_i && pwrite_i && paddr_i == 12'h004))
        else $error("[SVA-FAIL] a_divsel_survives_swrst: DIVSEL changed with no write to RSTCTL");
    // ---- F07: the lock is sticky until a reset ----------------------------------------------------
    a_ilock_sticky: assert property (@(posedge pclk_i) disable iff (!preset_n_o)
        (preset_n_o && ilock_o) |=> ilock_o)
        else $error("[SVA-FAIL] a_ilock_sticky");
    // ---- F08 ---------------------------------------------------------------------------------------
    a_pready: assert property (@(posedge pclk_i) disable iff (preset_n_o !== 1'b1) pready_o)
        else $error("[SVA-FAIL] a_pready");

    c_wdt:   cover property (@(posedge aon_clk_i) ext_rst_n_i && wdt_rst_req_i);
    c_sw:    cover property (@(posedge aon_clk_i) ext_rst_n_i && swrst_stb);
    c_ndm:   cover property (@(posedge aon_clk_i) ext_rst_n_i && ndm_rst_req_i && dm_rst_n_o);
    c_hart:  cover property (@(posedge aon_clk_i) ext_rst_n_i && hartreset_req_i && hreset_n_o && !core_rst_n_o);
    c_again: cover property (@(posedge aon_clk_i) ext_rst_n_i && !hreset_n_o && $rose(wdt_rst_req_i | ndm_rst_req_i));
endmodule

bind reset_ctrl reset_ctrl_sva #(.STRETCH(STRETCH)) u_reset_ctrl_sva (
    .aon_clk_i(aon_clk_i), .hclk_i(hclk_i), .pclk_i(pclk_i), .ext_rst_n_i(ext_rst_n_i),
    .wdt_rst_req_i(wdt_rst_req_i), .ndm_rst_req_i(ndm_rst_req_i), .hartreset_req_i(hartreset_req_i),
    .psel_i(psel_i), .penable_i(penable_i), .pwrite_i(pwrite_i), .paddr_i(paddr_i), .pready_o(pready_o),
    .div_sel_o(div_sel_o), .ilock_o(ilock_o),
    .hreset_n_o(hreset_n_o), .preset_n_o(preset_n_o), .core_rst_n_o(core_rst_n_o),
    .dm_rst_n_o(dm_rst_n_o), .ext_hrst_n_o(ext_hrst_n_o),
    .swrst_stb(swrst_stb), .reason_q(reason_q), .reason_w1c(reason_w1c), .ext_held(ext_held));
`endif
