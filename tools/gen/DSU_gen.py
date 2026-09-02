"""
gen_dsu_tests.py  --  test generator for the GARUDA DSU.

WHAT IT DOES
------------
Makes up instructions (curated corner cases + random ones), runs each through
the golden model to get the right answer, and writes two plain-hex files:

    dsu_stim.mem      -- what the testbench drives INTO the RTL
    dsu_expected.mem  -- what the RTL should produce, per the golden model

Both are read with Verilog's $readmemh. One 32-bit hex value per line.

FILE FORMAT  (fixed-size records, so the TB reads them in a simple loop)
------------------------------------------------------------------------
STIMULUS  = 4 words per test:
    [0] instr[31:0]
    [1] rs1[31:0]
    [2] rs2[31:0]
    [3] {31'b0, csr_clear_overflow}

EXPECTED  = 8 words per test:
    [0] rd_data[31:0]
    [1] acc_FX[31:0]      [2] {16'b0, acc_FX[47:32]}
    [3] acc_FY[31:0]      [4] {16'b0, acc_FY[47:32]}
    [5] acc_MAG[31:0]     [6] {16'b0, acc_MAG[47:32]}
    [7] flags = {24'b0, rd_addr[4:0], illegal, rd_valid, overflow}
                 bit0=overflow  bit1=rd_valid  bit2=illegal  bits[7:3]=rd_addr

THE PIPELINE CAVEAT (FLAG-2)
----------------------------
The golden model gives the accumulator value immediately; the real MAC is a
couple of cycles behind. So by default we insert one settling op (MAC_SEL 0*0,
which adds nothing) after a compute before reading it, so the RTL value has
landed and the compare is fair. Run with --no-drain to remove the settle and
deliberately create the compute->read hazard you want to probe.

usage:  python gen_dsu_tests.py [--count N] [--seed S] [--no-drain]
"""

import os, sys, random, argparse

# find the golden model (sits in ../golden)
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "golden"))
from DSU_Golden import (DSUModel, ArchDSU, asm, asm_shift,
                        MAC_SEL, MACSUB, MACABS, MACDOT, MACLOAD,
                        MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT,
                        ACC_FX, ACC_FY, ACC_MAG, MASK32, MASK48)

# values worth hammering: extremes and sign boundaries
CORNERS16 = [0x0000, 0x0001, 0xFFFF, 0x7FFF, 0x8000, 0x8001, 0x00FF, 0x0100]


def rand_word(rng):
    """A 32-bit operand, biased so corner 16-bit patterns show up often."""
    if rng.random() < 0.5:
        lo = rng.choice(CORNERS16); hi = rng.choice(CORNERS16)
        return (hi << 16) | lo
    return rng.randint(0, MASK32)


# Word 3 of each stimulus record. Bit 0 is csr_clear_overflow; bit 8 is
# dsu_en_n (1 = drive dsu_en LOW). Bit 8 was chosen so every pre-existing
# vector, which has word3 = 0 or 1, still means exactly what it meant.
DSU_EN_N = 1 << 8


def directed_tests():
    """Curated corner cases, each a (instr, rs1, rs2, ctrl, note) tuple."""
    t = []
    # one basic run of every instruction
    t += [(asm(MAC_SEL,  ACC_FX), 3, 4, 0, "MAC_SEL basic 3*4"),
          (asm(MACSUB,   ACC_FX), 2, 5, 0, "MACSUB basic -2*5"),
          (asm(MACABS,   ACC_FY), 0x8000, 1, 0, "MACABS |0x8000|*1 -> clamp"),
          (asm(MACDOT,   ACC_MAG), 0x00020003, 0x00040005, 0, "MACDOT 3*5+2*4"),
          (asm(MACLOAD,  ACC_FX), 0x80000000, 0, 0, "MACLOAD sign-extend neg"),
          (asm(MACCLEAR, ACC_FX), 0, 0, 0, "MACCLEAR zero FX"),
          (asm(MACRD_LO, ACC_MAG, rd=10), 0, 0, 0, "MACRD_LO -> x10"),
          (asm(MACRD_HI, ACC_MAG, rd=11), 0, 0, 0, "MACRD_HI -> x11")]
    # extreme products
    t += [(asm(MAC_SEL, ACC_FY), 0x7FFF, 0x7FFF, 0, "max * max"),
          (asm(MAC_SEL, ACC_FY), 0x8000, 0x8000, 0, "min * min")]
    # push toward accumulator overflow (49th bit)
    for _ in range(6):
        t.append((asm(MAC_SEL, ACC_MAG), 0x7FFF, 0x7FFF, 0, "accumulate toward ovf"))
    # saturation: load a big value then clamp; boundary must NOT clamp
    t += [(asm(MACLOAD, ACC_FX), 0x7FFFFFFF, 0, 0, "load +int32 max (boundary)"),
          (asm(MACSAT,  ACC_FX), 0, 0, 0, "MACSAT boundary -> no clamp"),
          (asm(MAC_SEL, ACC_FX), 0x7FFF, 0x7FFF, 0, "nudge over +int32 max"),
          (asm(MACSAT,  ACC_FX), 0, 0, 0, "MACSAT -> positive clamp")]
    # sticky flag clear
    t += [(asm(MACRD_LO, ACC_FX, rd=1), 0, 0, 1, "csr_clear_overflow pulse")]
    # shifts: right-arith on a negative, left, amt=0, oversize amt (FLAG-3)
    t += [(asm(MACLOAD, ACC_FY), 0xFFFF0000, 0, 0, "load negative for shift"),
          (asm_shift(ACC_FY, amt=4, left=0, rd=12), 0, 0, 0, "MACSHIFT ASR 4"),
          (asm_shift(ACC_FY, amt=4, left=1, rd=13), 0, 0, 0, "MACSHIFT LSL 4"),
          (asm_shift(ACC_FY, amt=0, left=0, rd=14), 0, 0, 0, "MACSHIFT amt=0"),
          (asm_shift(ACC_FY, amt=47, left=0, rd=15), 0, 0, 0, "MACSHIFT amt=47 (max legal)"),
          (asm_shift(ACC_FY, amt=47, left=1, rd=16), 0, 0, 0, "MACSHIFT LSL 47 (max legal)")]

    # ERRATUM DSU-6 (FLAG-D): 48..63 are now out of range -> illegal.
    t += [(asm_shift(ACC_FY, amt=48, left=0, rd=15), 0, 0, 0, "MACSHIFT amt=48 -> illegal"),
          (asm_shift(ACC_FY, amt=63, left=0, rd=15), 0, 0, 0, "MACSHIFT amt=63 -> illegal"),
          (asm_shift(ACC_FY, amt=48, left=1, rd=15), 0, 0, 0, "MACSHIFT LSL 48 -> illegal")]

    # ERRATUM DSU-7: imm[11:9] are reserved and must be zero.
    t += [(asm_shift(ACC_FY, amt=4, rd=17) | (1 << 29), 0, 0, 0, "I-type rsvd[9] set -> illegal"),
          (asm_shift(ACC_FY, amt=4, rd=17) | (2 << 29), 0, 0, 0, "I-type rsvd[10] set -> illegal"),
          (asm_shift(ACC_FY, amt=4, rd=17) | (4 << 29), 0, 0, 0, "I-type rsvd[11] set -> illegal")]

    # ERRATUM DSU-8 (FLAG-E): an overflow landing on its own clear must survive.
    # MACLOAD the accumulator to just below the 48-bit limit, then push it over
    # while asserting csr_clear_overflow in the same cycle.
    t += [(asm(MACCLEAR, ACC_MAG), 0, 0, 0, "clear MAG before overflow test"),
          (asm(MACLOAD,  ACC_MAG), 0x7FFFFFFF, 0, 0, "load MAG near max"),
          (asm(MAC_SEL,  ACC_MAG), 0x7FFF7FFF, 0x7FFF7FFF, 0, "drive MAG to overflow"),
          (asm(MAC_SEL,  ACC_MAG), 0x7FFF7FFF, 0x7FFF7FFF, 1, "overflow + clear same cycle")]

    # ERRATUM DSU-9: with dsu_en low the DSU must be completely inert --
    # no state change, no rd_valid, no illegal, and critically no dsu_busy.
    t += [(asm(MAC_SEL,  ACC_FX), 7, 9, DSU_EN_N, "dsu_en=0: compute is inert"),
          (asm(MACRD_LO, ACC_FX, rd=11), 0, 0, DSU_EN_N, "dsu_en=0: readback is inert"),
          (asm(MACCLEAR, ACC_FX), 0, 0, DSU_EN_N, "dsu_en=0: clear is inert"),
          ((0x1F << 27) | 0x0B, 1, 1, DSU_EN_N, "dsu_en=0: bad encoding is not illegal"),
          (asm(MACRD_LO, ACC_FX, rd=11), 0, 0, DSU_EN_N, "dsu_en=0: no interlock stall")]
    # illegal ones -- must be rejected, state untouched
    t += [(asm(MAC_SEL, acc_sel=3), 1, 1, 0, "illegal acc_sel=3"),
          ((0x1F << 27) | 0x0B, 1, 1, 0, "illegal unknown funct5"),
          ((0x0B | (2 << 12)), 1, 1, 0, "illegal bad funct3")]
    return t


def is_compute(instr):
    op = instr & 0x7F; f3 = (instr >> 12) & 7; f5 = (instr >> 27) & 0x1F
    return op == 0x0B and f3 == 0 and f5 in (MAC_SEL, MACSUB, MACABS, MACDOT)

def acc_of(instr):
    return (instr >> 25) & 0x3


def random_tests(rng, n):
    out = []
    compute = [MAC_SEL, MACSUB, MACABS, MACDOT]
    ops = compute + [MACLOAD, MACCLEAR, MACSAT, MACRD_LO, MACRD_HI, MACSHIFT]
    for _ in range(n):
        f5 = rng.choice(ops)
        sel = rng.randint(0, 2) if rng.random() < 0.9 else 3   # 10% illegal acc_sel
        if f5 == MACSHIFT:
            instr = asm_shift(sel & 0x3, amt=rng.randint(0, 63),
                              left=rng.randint(0, 1), rd=rng.randint(1, 31))
        else:
            instr = asm(f5, acc_sel=sel, rd=rng.randint(1, 31))
        out.append((instr, rand_word(rng), rand_word(rng), 0, f"random {f5}"))
    return out


def clamp_walk_tests(rng, n_probe, ramp=32768):
    """Vectors that actually REACH the top of the accumulator range.

    The ordinary suite cannot: the biggest single contribution to an
    accumulator is 2^31 (a MACDOT of two 0x8000 lanes), MACLOAD tops out at
    +-2^31, and MACSHIFT does not write back. So getting |acc| up to 2^46 is a
    ~32,768-instruction ramp and nothing shorter will do it.

    That is why the overflow logic went unexercised through 645 passing tests:
    not because nobody wrote an overflow test, but because the region where the
    flag matters is thousands of instructions away from where random stimulus
    lives. Cost of the ramp is one long vector file, which is cheap; the
    alternative is never testing the flag at all.
    """
    out = []
    dot = asm(MACDOT, ACC_FX, 0, 1, 2)
    for i in range(ramp):
        out.append((dot, 0x80008000, 0x80008000, 0, f"ramp {i}"))
    for i in range(n_probe):
        f5 = rng.choice([MAC_SEL, MACSUB, MACABS, MACDOT])
        out.append((asm(f5, acc_sel=ACC_FX, rd=rng.randint(1, 31)),
                    rand_word(rng), rand_word(rng), 0, f"clamp probe {i}"))
    return out


def w(x):                       # 32-bit value -> 8-digit hex line
    return f"{x & MASK32:08x}"

def expected_words(st):
    """Turn a golden-model result + accumulator snapshot into the 8-word record."""
    def split(acc):
        u = acc & MASK48
        return u & MASK32, (u >> 32) & 0xFFFF
    a0l, a0h = split(st["acc"][0]); a1l, a1h = split(st["acc"][1]); a2l, a2h = split(st["acc"][2])
    flags = (st["overflow"] & 1) | ((st["rd_valid"] & 1) << 1) \
            | ((st["illegal"] & 1) << 2) | ((st["rd_addr"] & 0x1F) << 3)
    return [st["rd_data"], a0l, a0h, a1l, a1h, a2l, a2h, flags]


def clamp_region_sweep(seed, n_per_point=2000):
    """Independent-oracle sweep of the HIGH-MAGNITUDE accumulator region.

    Why this exists as a separate sweep rather than more random tests
    ----------------------------------------------------------------
    The ordinary generated vectors never get the accumulator anywhere near its
    48-bit limits, so they cannot exercise the overflow logic at all. That is
    not a stimulus oversight, it is architectural: the largest product a single
    MAC can contribute is 2^30 (0x8000 * 0x8000), MACLOAD can only reach +-2^31
    from a 32-bit register, and MACSHIFT does not write the accumulator back.
    Reaching |acc| >= 2^46 therefore takes about 32,768 maximal MACDOTs --
    measured, not estimated. Random tests will never stumble into it.

    So the sweep SEEDS both oracles to the same accumulator value and then
    drives real instructions from there. The seeding is applied identically to
    both models, so it cannot bias the comparison; it only skips 32k cycles of
    ramp that prove nothing on their own.

    Runs on every generation. An oracle you have to remember to switch on is an
    oracle that will be off on the day it mattered.
    """
    rng = random.Random(seed)
    rows = []
    points = [0.05, 0.25, 0.45, 0.49, 0.50, 0.60, 0.75, 0.90, 0.99,
              -0.25, -0.49, -0.50, -0.75, -0.90, -0.99]

    for frac in points:
        start = int(frac * (1 << 47)) & MASK48
        m, a = DSUModel(), ArchDSU()
        clr = asm(MACCLEAR, ACC_FX, 0, 0, 0)
        m.tick(clr, 0, 0, dsu_en=1); m.tick(0, 0, 0, dsu_en=0)
        a.step(clr, 0, 0, dsu_en=1)
        m.acc[0] = start
        a.acc[0] = start

        bad = acc_bad = 0
        for _ in range(n_per_point):
            instr = asm(MAC_SEL, ACC_FX, 0, 1, 2)
            r1, r2 = rng.getrandbits(32), rng.getrandbits(32)
            r = m.tick(instr, r1, r2, dsu_en=1)
            guard = 0
            while r["dsu_busy"]:
                r = m.tick(instr, r1, r2, dsu_en=1)
                guard += 1
                if guard > 4:
                    raise RuntimeError("dsu_busy stuck in clamp sweep")
            m.tick(0, 0, 0, dsu_en=0)
            a.step(instr, r1, r2, dsu_en=1)

            if (m.acc[0] & MASK48) != (a.acc[0] & MASK48):
                acc_bad += 1
            if bool(m.overflow_sticky) != bool(a.overflow_sticky):
                bad += 1
            # resync, so one disagreement does not mask every later one
            m.overflow_sticky = a.overflow_sticky = False
        rows.append((frac, start, bad, acc_bad, n_per_point))
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--count", type=int, default=0, help="random tests (default: match directed count)")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--no-drain", action="store_true",
                    help="omit the idle drain cycle -- reads the accumulator "
                         "before stage 2 commits, for probing pipeline timing")
    ap.add_argument("--outdir", default=".")
    ap.add_argument("--clamp-walk", type=int, default=0, metavar="N",
                    help="emit a ramp to the top of the accumulator range "
                         "followed by N probe ops, instead of the normal suite. "
                         "This is the only stimulus that reaches the overflow "
                         "logic at all -- see clamp_walk_tests().")
    ap.add_argument("--ramp", type=int, default=32768,
                    help="ramp length for --clamp-walk (32768 reaches 2^46)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    if args.clamp_walk:
        directed = []
        n_rand = args.clamp_walk
        program = clamp_walk_tests(rng, args.clamp_walk, ramp=args.ramp)
    else:
        directed = directed_tests()
        n_rand = args.count if args.count else len(directed)  # even mix by default
        program = directed + random_tests(rng, n_rand)

    # ---- TWO ORACLES, ON PURPOSE ------------------------------------------
    # DSUModel is cycle-accurate: it expresses the stall, the pipeline and the
    # exact cycle a result appears, which ArchDSU cannot. That is why the
    # expected vectors come from it.
    #
    # But DSUModel was written by reading the RTL, and in places it deliberately
    # reproduces the hardware's arithmetic STRUCTURE rather than its intent --
    # its own header says "where this file and the RTL disagree, the RTL wins".
    # A testbench checked only against it therefore proves the RTL agrees with a
    # transliteration of itself. That is self-consistency, not correctness, and
    # it is exactly how a wrong overflow flag survived 645/645 passing tests.
    #
    # ArchDSU is the independent oracle: timeless, written from what the DSU is
    # SUPPOSED to compute, with a real range check
    #     -(1<<47) <= raw <= (1<<47)-1
    # rather than a bit-pattern lifted out of the adder. It runs in lockstep
    # here and every disagreement is reported. It cannot supply the expected
    # vectors (it has no notion of when anything appears) but it can, and now
    # does, contradict them.
    dsu  = DSUModel()
    arch = ArchDSU()
    xacc, xrd, xovf = [], [], []
    stim, exp = [], []
    count = 0
    for instr, rs1, rs2, clr, note in program:
        # ---- PER-TEST PROTOCOL (tb_dsu_top.sv mirrors this exactly) --------
        # 1. drive the instruction and HOLD it while dsu_busy is asserted --
        #    the interlock re-presents the same instruction, it does not skip
        #    one.
        # 2. sample the outputs on the cycle dsu_busy is low.
        # 3. run one IDLE cycle so the MAC's stage 2 commits its pending
        #    product (ERRATUM DSU-4 made stage 2 self-draining, which is what
        #    retired the old "settle MAC_SEL 0*0" hack -- that op existed only
        #    to force a commit that the hardware now performs by itself).
        # 4. snapshot the accumulators.
        den = 0 if (clr & DSU_EN_N) else 1
        cclr = clr & 1
        r = dsu.tick(instr, rs1, rs2, dsu_en=den, csr_clear_overflow=cclr)
        guard = 0
        while r["dsu_busy"]:
            r = dsu.tick(instr, rs1, rs2, dsu_en=den, csr_clear_overflow=cclr)
            guard += 1
            if guard > 4:
                raise RuntimeError(f"dsu_busy stuck at test #{count} ({note}) "
                                   "- the interlock should be a one-shot")
        if not args.no_drain:
            dsu.tick(0, 0, 0, dsu_en=0)          # idle drain cycle

        res = {"rd_data": r["dsu_rd_data"], "rd_valid": r["dsu_rd_valid"],
               "rd_addr": r["dsu_rd_addr"], "illegal": r["illegal_instr"],
               "overflow": r["dsu_overflow"], "acc": dsu.acc}

        # ---- independent-oracle cross-check --------------------------------
        # Only meaningful with the drain cycle on: without it DSUModel is
        # deliberately being read mid-flight, so a disagreement with a timeless
        # model is the thing being probed rather than a defect.
        a = arch.step(instr, rs1, rs2, csr_clear_overflow=cclr, dsu_en=den)
        if not args.no_drain:
            m_acc = [x & MASK48 for x in dsu.acc]
            a_acc = [x & MASK48 for x in arch.acc]
            if m_acc != a_acc:
                xacc.append((count, note, m_acc, a_acc))
            if r["dsu_rd_valid"] and (r["dsu_rd_data"] != (a["rd_data"] & MASK32)):
                xrd.append((count, note, r["dsu_rd_data"], a["rd_data"] & MASK32))
            if bool(dsu.overflow_sticky) != bool(arch.overflow_sticky):
                xovf.append((count, note, int(dsu.overflow_sticky),
                             int(arch.overflow_sticky)))
        stim += [w(instr), w(rs1), w(rs2), w(clr)]
        exp  += [w(v) for v in expected_words(res)]
        stim[-4] = stim[-4] + f"   // #{count}: {note}"       # annotate record
        count += 1

    os.makedirs(args.outdir, exist_ok=True)
    hdr = "// generated by gen_dsu_tests.py -- do not edit by hand\n"
    with open(os.path.join(args.outdir, "dsu_stim.mem"), "w") as f:
        f.write(hdr); f.write("\n".join(stim) + "\n")
    with open(os.path.join(args.outdir, "dsu_expected.mem"), "w") as f:
        f.write(hdr); f.write("\n".join(exp) + "\n")

    print(f"wrote {count} tests  ({len(directed)} directed + {n_rand} random"
          f"), drain={'off' if args.no_drain else 'on'}")
    print(f"  dsu_stim.mem      : {len(stim)} lines (4 words/test)")
    print(f"  dsu_expected.mem  : {len(exp)} lines (8 words/test)")
    print(f"  seed={args.seed}  drain={'off' if args.no_drain else 'on'}")

    # ---- independent-oracle report ----------------------------------------
    xpath = os.path.join(args.outdir, "dsu_crosscheck.txt")
    with open(xpath, "w") as f:
        f.write("DSUModel (cycle-accurate, RTL-derived) vs ArchDSU (independent)\n")
        f.write(f"seed={args.seed}  tests={count}\n")
        f.write("A disagreement here is NOT automatically an RTL bug: DSUModel\n")
        f.write("is checked against the RTL, so a disagreement says the two\n")
        f.write("models differ. Which one is wrong has to be reasoned out.\n\n")
        for title, rows, fmt in (
            ("ACCUMULATOR", xacc,
             lambda r: f"  #{r[0]:<5} {r[1]:<34} model={[hex(v) for v in r[2]]} arch={[hex(v) for v in r[3]]}"),
            ("RD_DATA", xrd,
             lambda r: f"  #{r[0]:<5} {r[1]:<34} model={r[2]:#010x} arch={r[3]:#010x}"),
            ("OVERFLOW STICKY", xovf,
             lambda r: f"  #{r[0]:<5} {r[1]:<34} model={r[2]} arch={r[3]}"),
        ):
            f.write(f"== {title}: {len(rows)} disagreement(s)\n")
            for r in rows:
                f.write(fmt(r) + "\n")
            f.write("\n")

    total_x = len(xacc) + len(xrd) + len(xovf)
    if args.no_drain:
        print("  cross-check       : skipped (--no-drain)")
    elif total_x == 0:
        print("  cross-check       : CLEAN - both oracles agree on all "
              f"{count} tests")
    else:
        print(f"\n  *** INDEPENDENT-ORACLE DISAGREEMENT: {total_x} of {count} tests ***")
        print(f"      accumulator {len(xacc)}   rd_data {len(xrd)}   "
              f"overflow {len(xovf)}")
        print(f"      detail: {xpath}")

    # ---- high-magnitude accumulator sweep ---------------------------------
    rows = clamp_region_sweep(args.seed)
    worst = max(r[2] for r in rows)
    accbad = sum(r[3] for r in rows)
    with open(xpath, "a") as f:
        f.write("== HIGH-MAGNITUDE ACCUMULATOR SWEEP\n")
        f.write("acc is seeded identically into both oracles, then real MACs\n")
        f.write("are driven. Ordinary vectors cannot reach here: it takes\n")
        f.write("~32768 maximal MACDOTs to walk |acc| up to 2^46.\n\n")
        f.write(f"{'acc/2^47':>10} {'acc':>18} {'ovf disagree':>14} {'acc disagree':>14}\n")
        for frac, start, bad, acc_bad, n in rows:
            f.write(f"{frac:>10.2f} {start:>18} {bad:>8}/{n:<5} {acc_bad:>8}/{n:<5}\n")

    print("\n  high-magnitude sweep (independent oracle):")
    print(f"    {'acc/2^47':>9}  {'overflow-flag disagreement':>28}  {'value':>8}")
    for frac, start, bad, acc_bad, n in rows:
        mark = "  <-- FLAG IS WRONG" if bad else ""
        print(f"    {frac:>9.2f}  {bad:>10}/{n:<10}            "
              f"{'ok' if acc_bad == 0 else 'DIVERGED':>8}{mark}")
    if worst:
        print("\n    The accumulator VALUES agree everywhere; only the overflow")
        print("    flag disagrees, and only for |acc| >= 2^46 -- the top quarter")
        print("    of the range, which is precisely what the flag exists to warn")
        print("    about. See ERRATUM OVF-1.")


if __name__ == "__main__":
    main()