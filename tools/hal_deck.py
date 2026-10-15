#!/usr/bin/env python3
"""
hal_deck.py - writes flow/2_static/hal.f and the class table of hal_waivers.txt
from one place, so the list of switched-off rules and its reasons cannot drift.

    python3 tools/hal_deck.py            (rewrites both, from sim/hal_default/hal.log counts)

Edit the tables below, never the generated parts of the two files.
"""
import re, sys, collections

STYLE = "STYLE: layout, naming and portability. No functional meaning on this code base."
INFO = "INFORMATION: states a fact about the design; no defect is implied."
REVIEWED = "REVIEWED: not style; judged not to matter yet, with the task that revisits it."

OFF = {  # rule: (group, reason)
 "STYVAL": (STYLE, "numeric literal where a named constant is preferred"),
 "MAXLEN": (STYLE, "line longer than 80 characters"),
 "SEPLIN": (STYLE, "several statements on one line"),
 "CTLCHR": (STYLE, "control characters in a line (CRLF files); .gitattributes now stores LF"),
 "NBGEND": (STYLE, "begin/end missing around a one-statement block"),
 "NOBLKN": (STYLE, "unnamed begin/end block"),
 "UCCONN": (STYLE, "lower-case constant or parameter name"),
 "LCVARN": (STYLE, "upper-case letters in a net name"),
 "NUMSUF": (STYLE, "numeric suffix in a name"),
 "IDLENG": (STYLE, "identifier length outside 4 to 16 characters"),
 "DECLIN": (STYLE, "several declarations on one line"),
 "ALOWID": (STYLE, "active-low name not ending in the suffix HAL expects; ours end in _n_i and _n_o"),
 "KEYWOD": (STYLE, "a VHDL reserved word used as a name; the code base is Verilog only"),
 "PRMBSE": (STYLE, "parameter written without a base"),
 "PRMVAL": (STYLE, "parameter written without a width"),
 "CNSTLT": (STYLE, "a literal that could be a named constant"),
 "EMPSTM": (STYLE, "empty statement"),
 "EMPBLK": (STYLE, "empty begin/end block"),
 "MPCMPE": (STYLE, "long expression without parentheses"),
 "OLDALW": (STYLE, "always @(a or b) written the old way"),
 "BITUNS": (STYLE, "constant such as 'h0 without every bit written out"),
 "PRTCNT": (STYLE, "module has more ports than the recommended number"),
 "CDNOTE": (STYLE, "a compiler directive is used (`ifdef SYNTHESIS, `include)"),
 "CDWARN": (STYLE, "a compiler directive is used (`timescale, `default_nettype)"),
 "FFASRT": (INFO, "a flop has an asynchronous reset: every flop of this design that has a reset does, by design"),
 "INFNOT": (INFO, "a wire with no fanout is ignored: the deliberate _unused sinks"),
 "NUMDFF": (INFO, "a count of single-bit flops"),
 "FSMIDN": (INFO, "a state machine was recognised"),
 "CLKINF": (INFO, "a signal was inferred to be a clock"),
 "DIFCLK": (INFO, "a clock keeps its function under another name across a port"),
 "DALIAS": (INFO, "two wires with the same driver: renaming across a hierarchy"),
 "ONPNSG": (INFO, "a one-bit bus: the shim's single-event cases"),
 "FDTHRU": (INFO, "an input is a direct feedthrough to an output: readback and decode muxes"),
 "TPOUNR": (INFO, "an output of the chip top is not a register: the pad drivers; budgets are in the constraints"),
 "USEPRT": (INFO, "an input port the module does not use: interfaces are kept uniform (shim, wrappers, vendored)"),
 "USEPAR": (INFO, "a parameter that is not used"),
 "IPRTEX": (INFO, "a constant in a port connection"),
 "EXPIPC": (INFO, "an expression in a port connection"),
 "PRMEXP": (INFO, "a parameter in a port connection"),
 "CBPAHI": (REVIEWED, "combinational path crossing several modules (the pad logic and the shim); matters only for synthesis by block. Revisit: task 3.6"),
 "SYNPRT": (REVIEWED, "an output port assigned from combinational logic; matters for hierarchical timing budgets. Revisit: task 3.6"),
 "LRGOPR": (REVIEWED, "arithmetic or comparison on wide operands; a timing question. Revisit: task 3.6, trial synthesis"),
 "SYNASN": (REVIEWED, "a module with both synchronous and asynchronous logic: expected with asynchronous-reset flops"),
 "IGNDLY": (REVIEWED, "a lumped delay is ignored by synthesis; all 60 are in vendored i2c_master_byte_ctrl.sv, not modified (D-22)"),
 "TRNMBT": (REVIEWED, "a state changes more than one bit on a transition (binary encoding); a power note. Revisit: task 3.6 power"),
 "BADFSM": (REVIEWED, "state machine not in HAL's modelling style, in vendored controllers; affects state extraction only"),
 "EXTFSM": (REVIEWED, "extra logic mixed into a state-machine process, in vendored controllers; affects state extraction only"),
 "POIASG": (REVIEWED, "possible overflow in an addition; decided formally by Superlint ASG_AR_OVFL (flow/2_static/superlint/RESULTS.md)"),
 "TRUNCZ": (REVIEWED, "constant truncation without loss of bits; the width rules of Verilator stay on"),
 "TROPCZ": (REVIEWED, "constant expression truncation without loss; the width rules of Verilator stay on"),
 "PADMSB": (REVIEWED, "a constant padded with zeros on the left; the width rules of Verilator stay on"),
 "SHFTNC": (REVIEWED, "shift by a non-constant: the barrel shifters and the ALU, intended; Superlint SHF_IS_OVFL decides it"),
 "INDXOP": (REVIEWED, "an operator inside an array index (DMA channel select); index range is POOBID, kept"),
 "LOOPTM": (REVIEWED, "the same operation repeated in a loop; elaboration time only"),
 "REDOPR": (REVIEWED, "a reduction operator on a short vector"),
 "RDOPND": (REVIEWED, "a redundant operand in a reduction"),
 "MICAWS": (REVIEWED, "several if or case statements in one always block"),
 "IFSMCD": (REVIEWED, "a condition shared by every branch of an if, in the DMA engine and the CSR file"),
 "MEMSIZ": (REVIEWED, "a memory with a one-bit word in the prefetch buffer; it is a flag array, not an error"),
 "VLGMEM": (REVIEWED, "Verilog memories in a vendored FIFO; processing time only"),
 "MXFNOT": (REVIEWED, "fanout above HAL's recommendation (MAC cluster, I2C); buffering is a physical-design step. Revisit: task 3.6"),
 "SLNOTP": (REVIEWED, "tri-state enable not controllable from a primary input (the pad drivers); a DFT question. Revisit: task 3.7, 3.9"),
 "TSETGV": (REVIEWED, "a task assigns a global variable; in id_ex.v and debug_module.v, simulation of register pairs"),
 "TUSEGV": (REVIEWED, "a task uses a global variable; debug_module.v"),
 "REVROP": (REVIEWED, "a register read or written outside its process; pclk_q is the accepted case (SIM-1), the rest vendored"),
}

KEPT = {  # rule: (class, reason)
 "TIELOG": ("idiom", "output tied to a constant: reserved register bits read 0, PREADY tied high (a peripheral never stalls), unused vendored ports"),
 "ULCMPE": ("idiom", "comparison against an unsized literal or a parameter; widths checked in the 3-tool lint, overflow decided by Superlint"),
 "UELOPR": ("idiom", "increment by 1'b1 on a wider counter; wrap is decided by Superlint ASG_AR_OVFL"),
 "ULRELE": ("idiom", "relational operator against a parameter; projected_occ is 4 bits against FIFO_DEPTH 4"),
 "UEASPD": ("vendored", "assignment of a narrower value in a vendored SPI controller"),
 "IMPDTC": ("idiom", "implicit signed/unsigned conversion of a literal or a signed shift; ALU and DSU, covered by the ISA tests and the DSU model"),
 "IMPTYP": ("vendored", "implicit type conversion in vendored IP"),
 "IPSFOU": ("idiom", "implicit signedness in the DSU MAC; checked against the Python model"),
 "IPUFSE": ("idiom", "33-bit signed operands of the multiplier; checked by the ISA multiply tests"),
 "MXUANS": ("idiom", "signed and unsigned mixed on purpose in the ALU and DSU"),
 "SGNUSG": ("idiom", "saturation constants written signed into unsigned wires; checked by the DSU model"),
 "CONSBS": ("idiom", "a constant without a base inside an address expression"),
 "MULNBA": ("idiom", "default-then-override: a register assigned a default and again later in the same block; the last assignment wins, intended"),
 "MULBAS": ("idiom", "the same pattern with blocking assignments in combinational logic"),
 "FFWNSR": ("idiom", "flop without a reset: the register file and datapath stages; each is written before it is read; the X-propagation run covers it"),
 "URDWIR": ("idiom", "wire assigned and never read: the deliberate _unused sinks and spare outputs"),
 "URDREG": ("idiom", "register assigned and never read: unread status bits of vendored registers"),
 "UNCONO": ("idiom", "an output of a block is driven inside it and left open at the instance: vendored PSLVERR and status outputs, spare SoC outputs"),
 "UNCONN": ("idiom", "an output port left open at an instance: reviewed one by one, none is a missing connection"),
 "DIFRST": ("idiom", "a reset keeps its function under another port name"),
 "VARUAW": ("vendored", "a vendored output declared as a register and used as a wire"),
 "DFDRVS": ("idiom", "parts of one vector driven by different kinds of driver (a register and an assign)"),
 "POOBID": ("idiom", "index range: the register file write is guarded by rd != 0; DMA channel indices are checked against 6"),
 "LOGAND": ("idiom", "bit-wise AND of single-bit operands in a condition: equal to the logical operator"),
 "LOGORP": ("idiom", "bit-wise OR of single-bit operands in a condition: equal to the logical operator"),
 "LOGNEG": ("idiom", "bit-wise NOT of a single bit in a condition: equal to the logical operator"),
 "RSTDAT": ("structure", "a synchronised reset level sampled as data on purpose: release sequencing in reset_ctrl, the I2C core reset (CRG-1, CRG-3)"),
 "FRSTDF": ("structure", "a reset driven by a flop: the reset synchronisers and stretch of reset_ctrl, by design"),
 "ASNRST": ("structure", "active-high asynchronous set/reset from the request flops of reset_ctrl"),
 "FFCSTD": ("structure", "a synchroniser stage with a constant data input, the release chain"),
 "RSTINP": ("structure", "a reset that is a flop output and not an input: the same synchroniser chain"),
 "RSTGNP": ("structure", "reset generation sits in a module with other logic: reset_ctrl, the I2C core reset, the core"),
 "RSTUCL": ("structure", "the I2C core reset also gates a command in logic: documented at garuda_i2c_top.v, [N-6.2b]"),
 "EXTSEQ": ("vendored", "extra logic in a vendored FSM"),
 "TERMST": ("open", "vendored SPI master FSM state MODE has no exit: SPIM-2, open"),
 "UNRCHS": ("open", "vendored SPI master FSM state MODE is never entered: SPIM-2, open"),
 "TSBINF": ("idiom", "pad tri-states of the chip top (tdo, i2c, gpio)"),
 "MULWIR": ("idiom", "pad nets driven by the chip and from outside"),
 "IOPNTA": ("idiom", "inout ports: the pads"),
 "TSMHOL": ("idiom", "the tri-state pin wrapper holds other logic"),
 "AMSKWD": ("idiom", "'access' and 'branch' are Verilog-AMS words; AMS is not used"),
 "CONSTC": ("idiom", "a condition constant by parameter (ADDR_SHIFT, ROM) or case (1'b1) priority select"),
 "CSTEXP": ("idiom", "case (1'b1) with expressions as items: the priority select of the slave mux"),
 "CDEFCV": ("idiom", "a default clause on a case that already covers every value, in decode_control"),
 "CNSTCN": ("idiom", "a condition false by parameter"),
 "WIDSEL": ("vendored", "a vendored case too wide to check for completeness"),
 "CDEFNC": ("vendored", "case without default in clocked logic of vendored IP: registers hold, no latch"),
 "MCKDMN": ("structure", "clocks of different domains meet at the divider, the reset controller and the debug CDC; the crossings are in stage 1b"),
 "MULMCK": ("structure", "a clock derived from the master input in the divider"),
 "CLKUCL": ("structure", "the clock drives a few gates: the select mux of clk_div and the core gate"),
 "CLKINP": ("structure", "a clock that is a flop or mux output: the divided clocks"),
 "CLKGNP": ("structure", "clock generation in a module with other logic: clk_div and core_clk_gate"),
 "GTDCLK": ("structure", "clock gating: the pclk toggle flop and the core clock gate"),
 "CDFDAT": ("structure", "a clock used as data: the toggle flop and the pclk phase"),
 "EDGMIX": ("structure", "both edges: the glitch-free select of clk_div and the TDO of the JTAG TAP (IEEE 1149.1)"),
 "NEFLOP": ("structure", "falling-edge flops: sel_act_q in clk_div, TDO in jtag_tap"),
 "BLKSQB": ("structure", "pclk_q is written with a blocking assignment on purpose (SIM-1)"),
 "RDBFAS": ("structure", "pclk_q read before assigned: the same toggle flop"),
 "LATBAS": ("structure", "core_clk_gate: the behavioural ICG latch, replaced by the library cell in the physical flow"),
 "LATINF": ("structure", "core_clk_gate: the same latch; the only one in the chip (make local_synth gates it)"),
 "LENCPI": ("structure", "the ICG enable is not a primary input: the same latch"),
 "BSINTT": ("idiom", "a bit select of a loop integer in the PWM duty decode"),
 "RPTVAR": ("idiom", "a variable repeated in a loop body"),
 "LMULOP": ("idiom", "the 33x33 multiply of mul32, 66-bit product by design (task 3.6 decides its timing)"),
 "NAUTOF": ("idiom", "a function without automatic in the DSU and the CSR file: no recursion, no re-entry"),
 "BOUINC": ("idiom", "register file array starts at 1: x0 is not stored, reads as 0 by construction"),
 "SHFTOF": ("idiom", "csa_3to2 carry shift drops the top bit by design; the adder tree is modulo 2^WIDTH"),
 "DNGLEL": ("vendored", "ambiguous else in vendored IP"),
 "DIFFMN": ("idiom", "garuda_chip_core lives in garuda_chip_top.v after the pin-wrapper split (P2)"),
 "MULTMF": ("idiom", "two modules in garuda_chip_top.v (core and pin wrapper)"),
 "MULTMS": ("idiom", "vendored files carry their own timescale; timescale.f sets the project's"),
 "TPRUSD": ("vendored", "tool pragma inside vendored IP"),
 "DUPMCR": ("vendored", "a macro defined twice with the same definition, vendored"),
 "UNMGEN": ("vendored", "an unnamed generate block in vendored IP"),
 "ATLGLC": ("idiom", "glue logic in the chip top: the pad tri-states"),
 "BBXSIG": ("idiom", "a signal wider than HAL's black-box size option: the 66-bit product"),
 "GLTASR": ("idiom", "core_rst_n_i & hartreset_n_i: both from synchroniser flops, required by CORE [N-7.33]"),
 "DLNBLK": ("vendored", "a delay in a non-blocking assignment of vendored IP (ignored by synthesis)"),
}

def counts(log):
    own=collections.Counter(); ven=collections.Counter(); sev={}
    for l in open(log, errors="replace"):
        m=re.match(r"^hal\w+: \*([EWN]),([A-Z0-9]+) \(\./([^,|]+),", l)
        if not m: continue
        s,r,f=m.groups(); sev[r]=s
        (ven if "third_party" in f else own)[r]+=1
    return own,ven,sev

def main():
    log="sim/hal_default/hal.log"
    deck=open("flow/2_static/hal.f").read()
    cur=set(re.findall(r"-nocheck ([A-Z0-9]+)", deck))
    if cur and cur != set(OFF):
        # first run: the table must equal the rules in the deck exactly
        miss=cur-set(OFF); extra=set(OFF)-cur
        if miss or extra: sys.exit("deck and table differ: only in deck %s, only in table %s" % (sorted(miss), sorted(extra)))
    own,ven,sev=counts(log)
    L=["// HAL options for GARUDA: rtl/soc/filelist_chip.f, top garuda_chip_top.",
       "//   irun -hal -64bit -f rtl/soc/filelist_chip.f -top garuda_chip_top -define SYNTHESIS \\",
       "//        -nclibdirname sim/static/INCA_libs -l sim/static/hal.log -f flow/2_static/hal.f",
       "//",
       "// GENERATED by tools/hal_deck.py from its table; edit the table, not this file.",
       "//",
       "// The starting point is Cadence's default rule set. %d rules are switched off below;" % len(OFF),
       "// on the chip they produced 91% of the default run's messages (7,528 of 8,274, 2026-10-15).",
       "// Each is in one of three groups, and every rule has its reason on its line:",
       "//   STYLE     layout, naming, portability: no functional meaning on this code base",
       "//   INFO      states a fact about the design, no defect implied",
       "//   REVIEWED  not style; judged not to matter yet, with the task that revisits it",
       "// Everything else stays on: widths, drivers, latches, resets, clocks, clock domains, FSM",
       "// reachability, synthesis and DFT rules. Their findings are held by hal_waivers.txt (errors,",
       "// by rule and file:line) and by hal_baseline.txt (a count per rule that may not rise)."]
    groups=[STYLE,INFO,REVIEWED]
    for g in groups:
        L.append("//"); L.append("// %s" % g)
        for r,(gg,why) in sorted(OFF.items(), key=lambda kv:(-(own[kv[0]]+ven[kv[0]]),kv[0])):
            if gg==g: L.append("//   %-7s %5d  %s" % (r, own[r]+ven[r], why))
    L.append('-halargs "')
    for g in groups:
        rs=sorted(r for r,(gg,_) in OFF.items() if gg==g)
        for i in range(0,len(rs),8):
            L.append(" "+" ".join("-nocheck %s" % r for r in rs[i:i+8]))
    L.append('"')
    open("flow/2_static/hal.f","w").write("\n".join(L)+"\n")

    W=open("flow/2_static/hal_waivers.txt").read()
    mark="CLASSES OF THE RULES WE KEEP"
    if mark in W: W=W[:W.index("="*79+"\n"+mark)] if ("="*79+"\n"+mark) in W else W[:W.index(mark)]
    out=["="*79, "%s (generated by tools/hal_deck.py, counts from the default-rule run of 2026-10-15)" % mark, "="*79,
         "Own RTL: %d findings in %d rules. Vendored IP: %d. Errors are matched by file and line above;" % (sum(own[r] for r in KEPT),
              len([r for r in KEPT if own[r]]), sum(ven[r] for r in KEPT)),
         "a warning is held by its class here and by the count in hal_baseline.txt.",
         "Class: idiom = a pattern the project uses on purpose; structure = clock, reset and pad structure;",
         "vendored = in third-party IP that is not edited (D-22); open = an open finding, named.", ""]
    for cls in ("open","structure","idiom","vendored"):
        out.append("--- %s" % cls)
        for r,(c,why) in sorted(KEPT.items(), key=lambda kv:(-(own[kv[0]]+ven[kv[0]]),kv[0])):
            if c==cls: out.append("  %-7s %s own %-3d vendored %-3d  %s" % (r, sev.get(r,"?"), own[r], ven[r], why))
        out.append("")
    unknown=[r for r in set(own)|set(ven) if r not in KEPT and r not in OFF]
    if unknown: out.append("NOT YET CLASSIFIED: %s" % " ".join(sorted(unknown)))
    open("flow/2_static/hal_waivers.txt","w").write(W.rstrip("\n")+"\n\n"+"\n".join(out)+"\n")
    print("deck: %d rules off (%d style, %d info, %d reviewed); classes: %d kept rules; unclassified: %s" % (
        len(OFF), *[sum(1 for g,_ in OFF.values() if g==x) for x in groups], len(KEPT), sorted(unknown) or "none"))
main()
