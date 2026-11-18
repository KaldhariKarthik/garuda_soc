#!/usr/bin/env python3
"""styval_fix.py - HAL STYVAL: a declared range is written with named widths, not numbers.

    python3 tools/styval_fix.py <hal.log> [--root DIR] [--dry]

For every STYVAL finding ("Numeric value 'N' used for identifier 'X'") the range [N:L] on that
line becomes [C-1:L] (or [C:L] when N+1 is no constant's value but N is), where C is:
  1. a shared width of garuda_pkg (the table WIDTHS below), when the width matches and the
     identifier matches the entry's pattern; the module then imports garuda_pkg;
  2. else, for a declaration inside a module body, a module constant <NAME>_W declared at the
     top of the body (NAME from the identifier, HAL IDLENG: 4..16 characters, NUMSUF: no
     digit at the end);
  3. else (a port, whose width must come from a package or a header parameter) it is reported
     and left for a hand decision.
Constants added to garuda_pkg are only those used (HAL USEPAR). Each rewritten module is then
proven unchanged by tools/sec_rtl.py.
"""
import collections, os, re, sys

# name, value, identifier pattern (None: any identifier)
WIDTHS = [
    ("PADDR_W", 12, r"paddr|apb_addr|ip_addr|^addr|_addr_|ip_limit|limit"),
    ("CSR_ADDR_W", 12, r"csr"),
    ("HTRANS_W", 2, r"htrans"),
    ("HSIZE_W", 3, r"hsize"),
    ("HBURST_W", 3, r"hburst"),
    ("HPROT_W", 4, r"hprot"),
    ("REG_IDX_W", 5, r"(^|_)(rd|rs1|rs2|rd_idx|rs1_idx|rs2_idx|rd_addr|rs1_addr|rs2_addr|rd_q|rd_o|rd_i)(_|$)|_rd$|_rd_"),
    ("FUNCT3_W", 3, r"funct3"),
    ("FUNCT5_W", 5, r"funct5"),
    ("FUNCT7_W", 7, r"funct7"),
    ("OPCODE_W", 7, r"opcode|(^|_)opc(_|$)"),
    ("ALU_OP_W", 4, r"alu_op"),
    ("CSR_OP_W", 2, r"csr_op"),
    ("ACC_SEL_W", 2, r"acc_sel"),
    ("DMA_NCH", 6, r"dma_req|dma_ack|ch_req|ch_ack|_ch$|chan|eligible|grant_ch|beat_done|beat_err|inflight|m2m"),
    ("AHB_MID_W", 2, r"grant|dph_master"),
    ("APB_NWIN", 12, r"psel|pready|pslverr|prdata|ext_p"),
    ("APB_WIN_W", 4, r"win"),
    ("CLIC_ID_W", 5, r"irq_id|^id_o$|^id_i$"),
    ("CLIC_LVL_W", 8, r"level"),
    ("DIV_SEL_W", 2, r"div_sel|div_act"),
    ("DMACTL_W", 2, r"dmactl"),
    ("GCTL_W", 4, r"garudactl"),
    ("CSR_FN_W", 3, r"csr_op"),
    ("CSR_OP_W", 2, r"^op$"),
    ("IMM_SEL_W", 3, r"imm_sel"),
    ("FWD_SEL_W", 2, r"fwd_.*sel"),
    ("PFB_OCC_W", 3, r"occupancy"),
    ("BYTE_OFF_W", 2, r"addr_lsbs"),
    ("EXC_CAUSE_W", 4, r"exc.*cause|exception_cause"),
    ("JTAG_IR_W", 5, r"(^|_)ir(_|$)"),
    ("DMI_ADDR_W", 7, r"req_addr|^addr_i$"),
    ("DMI_OP_W", 2, r"req_op|^op_i$"),
    ("DMA_NCH", 6, r"wr_(cr|sar|dar|cnt|iclr)|dma_(complete|error)|^(cr|sar|dar|cnt|stat|size)(_i|_o)?$"),
    ("DMA_CH_W", 3, r"grant_ch"),
    ("DMA_SIZE_W", 2, r"^size_[io]$|^size$"),
    ("ERR_PHASE_W", 3, r"err_phase"),
    ("SHAMT_W", 6, r"shift_amt"),
    ("RES_SRC_W", 2, r"result_src"),
    ("NUM_ACC", 3, r"overflow|pending"),
    ("BE_W", 4, r"(^|_)be(_|$)|arr_be"),
    ("DUTY_W", 16, r"duty"),
    ("RST_CAUSE_W", 5, r"reason"),
    ("GPIO_W", 2, r"gpio"),
    ("PERIPH_IRQ_W", 7, r"periph_irq"),
    ("WORD_W", 32, None),
    ("BYTE_W", 8, None),
    ("HALF_W", 16, None),
    ("ACC_W", 48, None),
    ("DWORD_W", 64, None),
]
PKG = "rtl/common/garuda_pkg.sv"


def const_for(ident, width):
    for name, val, pat in WIDTHS:
        if val == width and (pat is None or re.search(pat, ident.lower())):
            return name
    return None


def local_name(ident, used):
    base = re.sub(r"_(q|r|d|o|i|n|reg|nxt)$", "", ident.lower())
    base = re.sub(r"\d+", "", base).strip("_")
    base = re.sub(r"_+", "_", base) or "bus"
    name = (base.upper()[:14] + "_W").replace("__", "_")
    while len(name) < 4:
        name = "X" + name
    k = 0
    cand = name
    while cand in used:
        k += 1
        cand = name[:-2] + "ABCDEFGHIJ"[k % 10] + "_W"
    used.add(cand)
    return cand


def main():
    log = sys.argv[1]
    root = sys.argv[sys.argv.index("--root") + 1] if "--root" in sys.argv else "."
    dry = "--dry" in sys.argv
    pat = re.compile(r"^hal[a-z]*: \*W,STYVAL \(\./([^,]*),(\d+)\|\d+\): Numeric value '(\d+)' used for identifier '([^']+)'")
    finds = collections.defaultdict(list)
    for ln in open(log, errors="replace"):
        m = pat.match(ln)
        if m and "third_party" not in m.group(1):
            finds[m.group(1)].append((int(m.group(2)), int(m.group(3)), m.group(4)))
    pkg_used = set()
    left = []
    for f, items in sorted(finds.items()):
        path = os.path.join(root, f)
        lines = open(path).read().split("\n")
        text = "\n".join(lines)
        used = set(re.findall(r"\b([A-Z][A-Z0-9_]*)\b", text)) | {w[0] for w in WIDTHS}
        locals_ = collections.defaultdict(collections.OrderedDict)   # module start line -> name -> value

        def module_of(k):
            j = k
            while j >= 0 and not re.match(r"^\s*module\b", lines[j]):
                j -= 1
            return j
        need_pkg = False
        for line_no, val, ident in items:
            k = line_no - 1
            ln = lines[k]
            is_port = re.match(r"^\s*(input|output|inout)\b", ln) is not None
            # the range with this number as one bound
            rm = re.search(r"\[\s*%d\s*:\s*(\d+)\s*\]" % val, ln) or re.search(r"\[\s*(\d+)\s*:\s*%d\s*\]" % val, ln)
            if not rm:
                # a range written as an expression: name each number in it
                bm = None
                for b in re.finditer(r"\[[^\[\]]*\]", ln):
                    if re.search(r"(?<![\w'])%d(?![\w'])" % val, b.group(0)):
                        bm = b
                        break
                if not bm:
                    left.append("%s:%d %s %d (no range found)" % (f, line_no, ident, val))
                    continue
                c = const_for(ident, val)
                if not c:
                    left.append("%s:%d %s %d in %s (name it by hand)" % (f, line_no, ident, val, bm.group(0)))
                    continue
                pkg_used.add(c)
                need_pkg = True
                newb = re.sub(r"(?<![\w'])%d(?![\w'])" % val, c, bm.group(0), count=1)
                for gname, gval, gpat in WIDTHS:          # the word width in the same product
                    if gpat is None and re.search(r"(?<![\w'])%d(?![\w'])" % gval, newb) and gval != val:
                        newb = re.sub(r"(?<![\w'])%d(?![\w'])" % gval, gname, newb)
                        pkg_used.add(gname)
                lines[k] = ln.replace(bm.group(0), newb, 1)
                continue
            whole = rm.group(0)
            lo = int(rm.group(1))
            ascending = whole.replace(" ", "").startswith("[%d:" % lo) and lo != val and lo < val and whole.replace(" ", "").startswith("[0:")
            if whole.replace(" ", "") == "[0:%d]" % val:          # an unpacked array [0:N-1]
                width, lsb = val + 1, None
            else:
                width, lsb = val - lo + 1, lo
            c = const_for(ident, width) if (lsb == 0 or lsb is None) else const_for(ident, val + 1)
            plus_one = False
            if not c and lsb == 0 and width == 49:          # the 49-bit sum of two accumulators
                c, plus_one = "ACC_W", True
            if c:
                need_pkg = True
                pkg_used.add(c)
            elif not is_port:
                c = local_name(ident, used)
                locals_[module_of(k)][c] = width if lsb in (0, None) else val + 1
            else:
                left.append("%s:%d %s [%d:%d] (a port: name its width by hand)" % (f, line_no, ident, val, lo))
                continue
            if lsb is None:
                new = "[0:%s-1]" % c
            elif lsb == 0 and plus_one:
                new = "[%s:0]" % c
            elif lsb == 0:
                new = "[%s-1:0]" % c
            else:
                new = "[%s-1:%d]" % (c, lsb)
            lines[k] = ln.replace(whole, new, 1)
        for mstart in sorted(locals_, reverse=True):
            # after that module's timeprecision line
            j = mstart
            while j < len(lines) and not re.match(r"^\s*timeprecision\b", lines[j]):
                j += 1
            lines[j + 1:j + 1] = ["    localparam int unsigned %s = 32'd%d;" % kv for kv in locals_[mstart].items()]
        text = "\n".join(lines)
        if need_pkg and not re.search(r"import\s+garuda_pkg::\*", text):
            text = re.sub(r"(^\s*module\s+\w+)[ \t]*\n?", lambda m: m.group(1) + "\n    import garuda_pkg::*;\n", text, flags=re.M)
        if not dry:
            open(path, "w").write(text)
        print("styval_fix: %s: %d ranges, %d module constants" % (f, len(items), sum(len(v) for v in locals_.values())))
    # the shared widths
    p = os.path.join(root, PKG)
    t = open(p).read()
    add, seen = [], set()
    for w in WIDTHS:                       # one declaration per name (some names have two patterns)
        if w[0] in pkg_used and w[0] not in seen and not re.search(r"\b%s\b" % w[0], t):
            add.append(w)
            seen.add(w[0])
    if add:
        decl = "".join("    localparam int unsigned %s = 32'd%d;\n" % (n, v) for n, v, _ in add)
        t = t.replace("endpackage", "    // ---- widths (HAL STYVAL: no bare numbers in declared ranges) ----\n" + decl + "endpackage")
        if not dry:
            open(p, "w").write(t)
    print("styval_fix: shared widths used: %s" % " ".join(sorted(pkg_used)))
    for x in left:
        print("LEFT " + x)
    return 0


if __name__ == "__main__":
    sys.exit(main())
