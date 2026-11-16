#!/usr/bin/env python3
"""Formal negative controls (mutants), written from the current RTL.

Each mutant under tb/<block>/formal/mutants/ is its RTL source with the change named in
its header and nothing else (zero-waiver work, 2026-11-16: several had been copied
from an older RTL and had drifted, missing later fixes). This file holds every
mutant's recipe: the source, the header lines, and the exact text replaced. Each
replaced text must occur exactly once in the source.

  python3 tools/formal_mutants.py           check: every committed mutant equals its recipe
                                            applied to the current RTL (part of make check_tree)
  python3 tools/formal_mutants.py --write   rewrite the mutants from the current RTL

When an RTL file changes, --check fails until the mutants are rewritten; when a
replaced text no longer exists in the RTL, the recipe itself must be updated.
"""
import sys

MUTANTS = [{'path': 'tb/ahb/formal/mutants/ahb_arbiter_mut_ahb3.v',
  'src': 'rtl/ahb/ahb_arbiter.v',
  'header': ['MUTANT ahb3 (bus plan B1 A2 negative control): AHB-3 revert: a SEQ is never re-opened as '
             'NONSEQ'],
  'subs': [('    assign seq_break_o = ~last_owner_v || (last_owner_r != grant_o);\n',
            "    assign seq_break_o = 1'b0;\n")]},
 {'path': 'tb/ahb/formal/mutants/ahb_arbiter_mut_nofreeze.v',
  'src': 'rtl/ahb/ahb_arbiter.v',
  'header': ['MUTANT nofreeze (bus plan B1 A2 negative control): grant freeze removed: the grant may move '
             'under a waited address phase'],
  'subs': [('    assign grant_o = hold_r ? grant_r : winner;\n', '    assign grant_o = winner;\n')]},
 {'path': 'tb/ahb/formal/mutants/ahb_arbiter_mut_prio.v',
  'src': 'rtl/ahb/ahb_arbiter.v',
  'header': ['MUTANT prio (bus plan B1 A2 negative control): priority swap: SBA above DMA'],
  'subs': [('    wire [1:0] winner = req[`AHB_M_DMA]   ? `AHB_M_DMA   :\n'
            '                        req[`AHB_M_SBA]   ? `AHB_M_SBA   :\n',
            '    wire [1:0] winner = req[`AHB_M_SBA]   ? `AHB_M_SBA   :\n'
            '                        req[`AHB_M_DMA]   ? `AHB_M_DMA   :\n')]},
 {'path': 'tb/ahb/formal/mutants/ahb_decoder_mut_decode.v',
  'src': 'rtl/ahb/ahb_decoder.v',
  'header': ['MUTANT decode (bus plan B1 A2 negative control): decode slip: DSRAM decoded at nibble 3'],
  'subs': [("            `AHB_RGN_DSRAM : hsel_o[`AHB_S_DSRAM ] = 1'b1;\n",
            "            4'h3           : hsel_o[`AHB_S_DSRAM ] = 1'b1;\n")]},
 {'path': 'tb/ahb/formal/mutants/ahb_master_mux_mut_ahb1.v',
  'src': 'rtl/ahb/ahb_master_mux.v',
  'header': ['MUTANT ahb1 (bus plan B1 A2 negative control): AHB-1 revert: HWDATA selected by the '
             'address-phase grant'],
  'subs': [('        case (dph_master_i)\n', '        case (grant_i)\n')]},
 {'path': 'tb/ahb/formal/mutants/ahb_master_port_mut_ahb2.v',
  'src': 'rtl/ahb/ahb_master_port.v',
  'header': ['MUTANT ahb2 (bus plan B1 A2 negative control): AHB-2 revert: no response hold'],
  'subs': [('    wire capture = dph_own_i && !granted_i && presenting && hready_shared_i;\n',
            "    wire capture = 1'b0;\n")]},
 {'path': 'tb/ahb/formal/mutants/ahb_master_port_mut_ahb4.v',
  'src': 'rtl/ahb/ahb_master_port.v',
  'header': ['MUTANT ahb4 (bus plan B1 A2 negative control): AHB-4 revert: the hold rule applied to an idle '
             'master too'],
  'subs': [("    assign hready_o = pending ? (hready_shared_i && entitled) : 1'b1;\n",
            '    assign hready_o = hready_shared_i && entitled;\n')]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_apb_fsm_mut_nosetup.v',
  'src': 'rtl/ahb2apb/ahb2apb_apb_fsm.v',
  'header': ['MUTANT nosetup (bus plan B2 negative control): PENABLE raised with PSEL (no SETUP cycle)'],
  'subs': [("                        psel_o   <= 12'd1 << win_i;\n",
            "                        psel_o   <= 12'd1 << win_i;\n"
            "                        penable_o <= 1'b1;\n")]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_apb_fsm_mut_to15.v',
  'src': 'rtl/ahb2apb/ahb2apb_apb_fsm.v',
  'header': ['MUTANT to15 (bus plan B2 negative control): timeout one sample early (15)'],
  'subs': [('                    end else if (to_cnt == TIMEOUT - 1) begin\n',
            '                    end else if (to_cnt == TIMEOUT - 2) begin\n')]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_apb_fsm_mut_to17.v',
  'src': 'rtl/ahb2apb/ahb2apb_apb_fsm.v',
  'header': ['MUTANT to17 (bus plan B2 negative control): timeout one sample late (17)'],
  'subs': [('                    end else if (to_cnt == TIMEOUT - 1) begin\n',
            '                    end else if (to_cnt == TIMEOUT) begin\n')]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_apb_fsm_mut_win.v',
  'src': 'rtl/ahb2apb/ahb2apb_apb_fsm.v',
  'header': ['MUTANT win (bus plan B2 negative control): PSEL on the neighbouring window'],
  'subs': [("                        psel_o   <= 12'd1 << win_i;\n",
            "                        psel_o   <= 12'd1 << (win_i ^ 4'd1);\n")]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_bridge_mut_apb2.v',
  'src': 'rtl/ahb2apb/ahb2apb_bridge.v',
  'header': ['MUTANT apb2 (bus plan B2 negative control): rtl/ahb2apb/ahb2apb_bridge.v with ONE fix reverted '
             '(APB-2: no aperture check).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/ahb2apb/formal/apb.toml mut_apb2)'],
  'subs': [("    wire       win_ok  = WINDOW_MASK[win] && (haddr_i[27:16] == 12'h000);\n",
            '    wire       win_ok  = WINDOW_MASK[win];   // MUTANT: APB-2 reverted\n')]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_bridge_mut_brg1.v',
  'src': 'rtl/ahb2apb/ahb2apb_bridge.v',
  'header': ['MUTANT brg1 (bus plan B2 negative control): rtl/ahb2apb/ahb2apb_bridge.v with ONE fix reverted '
             '(BRG-1: a new transfer only from H_IDLE).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/ahb2apb/formal/apb.toml mut_brg1)'],
  'subs': [('                H_IDLE, H_OK, H_ERR2: begin\n',
            '                H_IDLE: begin   // MUTANT: BRG-1 reverted\n')]},
 {'path': 'tb/ahb2apb/formal/mutants/ahb2apb_bridge_mut_subword.v',
  'src': 'rtl/ahb2apb/ahb2apb_bridge.v',
  'header': ['MUTANT subword (bus plan B2 negative control): rtl/ahb2apb/ahb2apb_bridge.v with ONE change '
             '(sub-word accesses passed to APB).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/ahb2apb/formal/apb.toml mut_subword)'],
  'subs': [("    wire       word_ok = (hsize_i == 3'b010);\n",
            "    wire       word_ok = 1'b1;   // MUTANT: sub-word passed\n")]},
 {'path': 'tb/core/formal/mutants/branch_predict_no_bpdis.v',
  'src': 'rtl/core/branch_predict.v',
  'header': ['MUTANT branch_predict_no_bpdis: rtl/core/branch_predict.v with ONE change (BP_DIS ignored).',
             'Formal negative control in tb/core/formal/core_trap.toml: must FAIL.'],
  'subs': [('    assign predict_taken_o = branch_i & imm_b_i[31] & ~bp_dis_i;   // CORE-4: BP_DIS\n',
            '    assign predict_taken_o = branch_i & imm_b_i[31];   // MUTANT: BP_DIS ignored   // CORE-4: '
            'BP_DIS\n')]},
 {'path': 'tb/core/formal/mutants/branch_unit_no_t18.v',
  'src': 'rtl/core/branch_unit.v',
  'header': ["MUTANT (negative control for T-18): branch_unit.v BEFORE the fix -- a JAL's",
             'redirect_target follows the fake branch compare of its bit fields. Do not use.'],
  'subs': [('    assign redirect_target = jalr             ? jalr_target\n'
            '                           : (jal | taken_r)  ? branch_target\n'
            '                                              : fallthrough;\n',
            '    assign redirect_target = jalr    ? jalr_target\n'
            '                           : taken_r ? branch_target\n'
            '                                     : fallthrough;\n')]},
 {'path': 'tb/core/formal/mutants/clic_ctrl_no_preempt.v',
  'src': 'rtl/core/clic_ctrl.v',
  'header': ['MUTANT clic_ctrl_no_preempt: rtl/core/clic_ctrl.v with ONE change (PREEMPT_DIS ignored).',
             'Formal negative control in tb/core/formal/core_trap.toml: must FAIL.'],
  'subs': [("                         (~preempt_dis_i | (mintstatus_mil_i == 8'd0));        // CORE-4: "
            'PREEMPT_DIS\n',
            "                         1'b1;   // MUTANT: PREEMPT_DIS ignored        // CORE-4: "
            'PREEMPT_DIS\n')]},
 {'path': 'tb/core/formal/mutants/csr_file_no_c16.v',
  'src': 'rtl/core/csr_file.v',
  'header': ['MUTANT csr_file_no_c16: rtl/core/csr_file.v with ONE fix reverted (C-16: the read-zero CSRs '
             'trap again).',
             'Formal negative control: must FAIL. Regenerated 2026-11-16 from the current RTL; it differs '
             'from it by this change only. (tb/core/formal/csr_file.toml csr_prove_no_c16)'],
  'subs': [("            default:   begin rdata = 32'd0; implemented = is_readzero; end   // C-16\n",
            "            default:   begin rdata = 32'd0; implemented = 1'b0; end   // MUTANT: C-16 "
            'reverted\n')]},
 {'path': 'tb/core/formal/mutants/csr_file_no_t12.v',
  'src': 'rtl/core/csr_file.v',
  'header': ['MUTANT csr_file_no_t12: rtl/core/csr_file.v with ONE fix reverted (T-12: no mpil push, mret '
             'drops the level).',
             'Formal negative control: must FAIL. Regenerated 2026-11-16 from the current RTL; it differs '
             'from it by this change only. (tb/core/formal/csr_file.toml csr_prove_no_t12)'],
  'subs': [('                mcause_r    <= {trap_cause_i[31:24], mil_r, trap_cause_i[15:0]};\n',
            '                mcause_r    <= trap_cause_i;                       // MUTANT: no mpil push\n'),
           ('                mil_r       <= mcause_r[23:16];  // T-12: restore from mcause.mpil\n',
            "                mil_r       <= 8'd0;             // MUTANT: mret drops the level to 0\n")]},
 {'path': 'tb/core/formal/mutants/debug_module_rawgrant.v',
  'src': 'rtl/debug/debug_module.v',
  'header': ['MUTANT debug_module_rawgrant: rtl/debug/debug_module.v with ONE change: hartreset_o follows '
             'the RAW request',
             '(the pre-RDC-1 behaviour of b90b481). Formal negative control: must FAIL. Regenerated '
             '2026-11-16 from the current RTL; it differs from it by this change only. '
             '(tb/core/formal/rdc1.toml rdc1_prove_rawgrant)'],
  'subs': [('    assign hartreset_o = dmactive & grant_q;                 // RDC-1: the grant, never the raw '
            'request\n',
            '    assign hartreset_o = dmactive & hartreset;              // MUTANT: no drain (pre-fix '
            'behaviour)\n')]},
 {'path': 'tb/core/formal/mutants/garuda_core_top_no_cgdis.v',
  'src': 'rtl/core/garuda_core_top.v',
  'header': ['MUTANT garuda_core_top_no_cgdis: rtl/core/garuda_core_top.v with ONE change (CG_DIS ignored).',
             'Formal negative control in tb/core/formal/core_trap.toml: must FAIL.'],
  'subs': [('        .hclk(hclk), .en_i(~quiescent | (CLK_GATE == 0) | csr_ctl[3]),   // CORE-4: CG_DIS\n',
            '        .hclk(hclk), .en_i(~quiescent | (CLK_GATE == 0)),   // MUTANT: CG_DIS ignored   // '
            'CORE-4: CG_DIS\n')]},
 {'path': 'tb/core/formal/mutants/garuda_iport_ahb_master_no_buse.v',
  'src': 'rtl/core/iport_master.v',
  'header': ['MUTANT garuda_iport_ahb_master_no_buse: rtl/core/iport_master.v with ONE change. '
             'Formal negative control: must FAIL.'],
  'subs': [('                            room_for_new_fetch &\n'
            "                            (fetch_pc_i[1:0] == 2'b00);           // BUS-E\n",
            '                            room_for_new_fetch;\n')]},
 {'path': 'tb/core/formal/mutants/garuda_iport_ahb_master_no_pfdis.v',
  'src': 'rtl/core/iport_master.v',
  'header': ['MUTANT garuda_iport_ahb_master_no_pfdis: rtl/core/iport_master.v with ONE change '
             '(PF_DIS ignored).',
             'Formal negative control: must FAIL. Regenerated 2026-11-16 from the current RTL; it differs '
             'from it by this change only. (tb/core/formal/core_trap.toml ctl_no_pfdis)'],
  'subs': [("    wire room_for_new_fetch = (projected_occ < (pf_dis_i ? 4'd1 : FIFO_DEPTH));   // CORE-4: "
            'PF_DIS\n',
            '    wire room_for_new_fetch = (projected_occ < FIFO_DEPTH);   // MUTANT: PF_DIS ignored   // '
            'CORE-4: PF_DIS\n')]},
 {'path': 'tb/core/formal/mutants/trap_ctrl_no_t13.v',
  'src': 'rtl/core/trap_ctrl.v',
  'header': ['MUTANT trap_ctrl_no_t13: rtl/core/trap_ctrl.v with ONE fix reverted (T-13: an MRET in EX '
             'blocks the older MEM-point bus error,',
             'as at b90b481). Formal negative control: must FAIL. Regenerated 2026-11-16 from the current '
             'RTL; it differs from it by this change only. (tb/core/formal/core_trap.toml '
             'trap_prove_no_t13)'],
  'subs': [('    wire trap_now     = mem_exc_valid_i | ((ex_exc | any_int) & ~is_mret);\n'
            '    wire mret_take    = is_mret & ~h2 & ~mem_exc_valid_i;\n',
            '    wire trap_now     = (exception | any_int) & ~is_mret;   // MUTANT: T-13 reverted\n'
            '    wire mret_take    = is_mret & ~h2;                     // MUTANT: T-13 reverted\n')]},
 {'path': 'tb/core/formal/mutants/trap_ctrl_no_t14.v',
  'src': 'rtl/core/trap_ctrl.v',
  'header': ['MUTANT trap_ctrl_no_t14: rtl/core/trap_ctrl.v with ONE fix reverted (T-14: a WFI arms while an '
             'older fault is in H2,',
             'as at b90b481). Formal negative control: must FAIL. Regenerated 2026-11-16 from the current '
             'RTL; it differs from it by this change only. (tb/core/formal/core_trap.toml '
             'trap_prove_no_t14)'],
  'subs': [("        else if (is_wfi & ~wfi_active & ~wfi_squashed & ~h2) wfi_active <= 1'b1;\n",
            "        else if (is_wfi & ~wfi_active & ~wfi_squashed) wfi_active <= 1'b1;   // MUTANT: T-14 "
            'reverted\n')]},
 {'path': 'tb/core/formal/mutants/trap_ctrl_no_t17.v',
  'src': 'rtl/core/trap_ctrl.v',
  'header': ['MUTANT trap_ctrl_no_t17: rtl/core/trap_ctrl.v with ONE fix reverted (T-17: a fetch-fault bit '
             'on a bubble raises cause 1).',
             'Formal negative control: must FAIL. Regenerated 2026-11-16 from the current RTL; it differs '
             'from it by this change only. (tb/core/formal/core_trap.toml t17_no_fix)'],
  'subs': [('    wire e1  = idex_fault_i & idex_valid_i;\n',
            '    wire e1  = idex_fault_i;   // MUTANT: T-17 reverted\n')]},
 {'path': 'tb/dma/formal/mutants/dma_apb_slave_mut_aud13.v',
  'src': 'rtl/dma/dma_apb_slave.v',
  'header': ['MUTANT dma_apb_slave_mut_aud13: rtl/dma/dma_apb_slave.v with ONE change. Formal negative '
             'control: must FAIL.'],
  'subs': [('    assign pslverr_o = psel_i & penable_i & ~hit;\n',
            '    assign pslverr_o = psel_i & penable_i & (~hit | (pwrite_i & (gstat | (chan_rgn & reg_ == '
            "3'd4))));   // MUTANT: AUD-13 reverted\n")]},
 {'path': 'tb/dma/formal/mutants/dma_arbiter_mut_prio_inv.v',
  'src': 'rtl/dma/dma_arbiter.v',
  'header': ['MUTANT dma_arbiter_mut_prio_inv: rtl/dma/dma_arbiter.v with ONE change (DMA plan D7: the '
             'LOWEST priority wins).',
             'Formal negative control: must FAIL.'],
  'subs': [('            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best)) begin\n',
            '            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] < best)) begin\n')]},
 {'path': 'tb/dma/formal/mutants/dma_arbiter_mut_tie_high.v',
  'src': 'rtl/dma/dma_arbiter.v',
  'header': ['MUTANT dma_arbiter_mut_tie_high: rtl/dma/dma_arbiter.v with ONE change. Formal negative '
             'control: must FAIL.'],
  'subs': [('            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] > best)) begin\n',
            '            if (eligible_i[n] && (!grant_valid_o || PRIO[3*n +: 3] >= best)) begin\n')]},
 {'path': 'tb/dma/formal/mutants/dma_chan_mut_d2.v',
  'src': 'rtl/dma/dma_chan.v',
  'header': ['MUTANT mut_d2: rtl/dma/dma_chan.v with ONE fix reverted (D-2: a software CR write beats the '
             'hardware EN clear).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/dma/formal/dma.toml mut_d2, a_hw_wins_en)'],
  'subs': [("            if (hw_clr_en || (en_q && rem_q == 16'd0 && !wr_cr_i))\n"
            "                en_q <= 1'b0;\n"
            '            else if (wr_cr_i) begin\n'
            '                en_q <= wdata_i[0];\n'
            '                if (wdata_i[0] && !en_q) rem_q <= cnt_q;       // arm\n'
            '            end\n',
            '            if (wr_cr_i) begin                              // MUTANT: D-2 reverted (a '
            'software\n'
            '                en_q <= wdata_i[0];                         // write beats the hardware clear)\n'
            '                if (wdata_i[0] && !en_q) rem_q <= cnt_q;       // arm\n'
            "            end else if (hw_clr_en || (en_q && rem_q == 16'd0))\n"
            "                en_q <= 1'b0;\n")]},
 {'path': 'tb/dma/formal/mutants/dma_chan_mut_dma8.v',
  'src': 'rtl/dma/dma_chan.v',
  'header': ['MUTANT mut_dma8: rtl/dma/dma_chan.v with ONE fix reverted (DMA-8: a failed beat marks the '
             'request as taken).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/dma/formal/dma.toml mut_dma8, a_failed_beat_keeps_request)'],
  'subs': [("            else if (beat_done_i) taken_q <= 1'b1;\n",
            "            else if (beat_done_i || beat_err_i) taken_q <= 1'b1;   // MUTANT: DMA-8 "
            'reverted\n')]},
 {'path': 'tb/dma/formal/mutants/dma_chan_mut_iclr_wins.v',
  'src': 'rtl/dma/dma_chan.v',
  'header': ['MUTANT mut_iclr_wins: rtl/dma/dma_chan.v with ONE change (an ICLR in the cycle COMPLETE sets '
             'clears it).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/dma/formal/dma.toml mut_iclr_wins, '
             'a_set_beats_clear_complete)'],
  'subs': [("                if (wdata_i[0] && !(done && last)) comp_q <= 1'b0;\n",
            "                if (wdata_i[0]) comp_q <= 1'b0;             // MUTANT: clear beats set\n")]},
 {'path': 'tb/dma/formal/mutants/dma_engine_mut_eng1.v',
  'src': 'rtl/dma/dma_engine.v',
  'header': ['MUTANT mut_eng1: rtl/dma/dma_engine.v with ONE fix reverted (ENG-1: a beat is taken in the '
             'cycle a result is reported).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/dma/formal/dma.toml mut_eng1, a_no_grant_while_reporting)'],
  'subs': [('                    if (take) begin\n',
            '                    if (grant_valid_i) begin                 // MUTANT: ENG-1 guard '
            'removed\n')]},
 {'path': 'tb/dsu/formal/mutants/dsu_top_no_dsu9.v',
  'src': 'rtl/dsu/dsu_top.v',
  'header': ['MUTANT dsu_no_dsu9: rtl/dsu/dsu_top.v with ONE fix reverted (DSU-9: busy not gated by dsu_en).',
             'Regenerated 2026-11-16 from the current RTL; it differs from it by this change only. Formal '
             'negative control: must FAIL. (tb/dsu/formal/dsu.toml dsu_no_dsu9)'],
  'subs': [('        .is_custom0 (is_custom0_w & dsu_en),\n',
            '        .is_custom0 (is_custom0_w),                 // MUTANT: DSU-9 fix reverted\n')]}]


def build(mu):
    with open(mu['src']) as f:
        s = f.read()
    for old, new in mu['subs']:
        n = s.count(old)
        if n != 1:
            raise SystemExit('formal_mutants: %s: the replaced text occurs %d times in %s:\n%s'
                             % (mu['path'], n, mu['src'], old))
        s = s.replace(old, new)
    return ''.join('// ' + h + '\n' for h in mu['header']) + s


def main():
    write = '--write' in sys.argv[1:]
    bad = 0
    for mu in MUTANTS:
        text = build(mu)
        try:
            with open(mu['path']) as f:
                cur = f.read()
        except IOError:
            cur = None
        if cur == text:
            continue
        if write:
            with open(mu['path'], 'w') as f:
                f.write(text)
            print('formal_mutants: wrote ' + mu['path'])
        else:
            print('formal_mutants: STALE ' + mu['path'] + ' (not its recipe on the current '
                  + mu['src'] + '; run python3 tools/formal_mutants.py --write)')
            bad += 1
    if not write:
        print('formal_mutants: %d mutants, %s' % (len(MUTANTS), 'all current' if not bad else '%d stale' % bad))
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
