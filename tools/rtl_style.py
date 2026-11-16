#!/usr/bin/env python3
"""rtl_style.py - rewrite an RTL file in the HAL-clean style (zero-waiver F4, 2026-11-16).

    python3 tools/rtl_style.py FILE [FILE ...]        rewrite in place
    python3 tools/rtl_style.py --check FILE           print the result, change nothing

What it does (the mechanical HAL rules; everything else stays hand work):
  OLDALW  always @(posedge/negedge ..) -> always_ff @(..); always @(*) / @(a or b) -> always_comb;
          a block marked "// rtl_style: latch" -> always_latch
  NOBLKN  every always body is `begin : <label>`; the label is the block's own label when it had
          one, else p_<first register> / c_<first variable>, 4 to 16 lower-case characters, no
          numeric suffix, unique in the module
  NBGEND  every if / else / for body inside an always block is begin ... end
  SEPLIN  one statement per line;  DECLIN  one declaration per line
  MAXLEN  no line over 80 characters: comments re-wrapped, a trailing comment that does not fit
          moved above its line, code broken after a comma or before an operator at the outermost
          level that makes it fit
  BITUNS  a sized hex/binary/octal literal is written with every digit (24'h0 -> 24'h000000)
  PRMBSE / PRMVAL  a bare decimal in a parameter value becomes 32'dN; `parameter integer` ->
          `parameter int unsigned` (all such parameters in this code base are non-negative)
  CDNOTE / CDWARN  `timescale -> timeunit / timeprecision inside each module; `default_nettype
          lines removed (implicit nets are caught by HAL IMPDTC and Verilator)

Every rewritten module must then be proven equal to its old self (tools/sec_rtl.py).
"""
import re, sys

MAXLEN = 80


def blen(x):
    """line length as HAL counts it: bytes"""
    return len(x.encode("utf-8", "surrogateescape"))
IND = "    "

# ------------------------------------------------------------------------------------------------
# tokens
# ------------------------------------------------------------------------------------------------
TOK = re.compile(r"""
 (?P<nl>\n)
|(?P<ws>[ \t\r]+)
|(?P<lc>//[^\n]*)
|(?P<bc>/\*.*?\*/)
|(?P<dir>`[A-Za-z_]\w*)
|(?P<str>"(?:\\.|[^"\\])*")
|(?P<num>(?:\d[\d_]*)?\s*'[sS]?[bBoOdDhH]\s*[0-9a-fA-FxXzZ?_]+|\d[\d_]*\.\d+|\d[\d_]*|'[01xXzZ])
|(?P<id>[A-Za-z_]\w*|\$[A-Za-z_]\w*|\\\S+)
|(?P<op><<<=|>>>=|<<<|>>>|===|!==|==\?|!=\?|\+:|-:|::|->|<=|>=|==|!=|&&|\|\||<<|>>|\*\*|\+\+|--|\+=|-=|\|=|&=|\^=|~&|~\||~\^|\^~|\S)
""", re.S | re.X)


class T:
    __slots__ = ("k", "s")

    def __init__(self, k, s):
        self.k, self.s = k, s

    def __repr__(self):
        return "%s:%r" % (self.k, self.s)


def lex(text):
    out, i = [], 0
    while i < len(text):
        m = TOK.match(text, i)
        if not m:
            raise SystemExit("rtl_style: cannot read at offset %d: %r" % (i, text[i:i + 30]))
        out.append(T(m.lastgroup, m.group()))
        i = m.end()
    return out


def code(toks):
    """the tokens that are code (no whitespace, newlines or comments)"""
    return [t for t in toks if t.k not in ("ws", "nl", "lc", "bc")]


def inner_comments(toks):
    """comments inside a statement's tokens (they are printed above it)"""
    return [t.s for t in toks if t.k in ("lc", "bc")]


UNARY_PREV = {"(", "[", "{", ",", "=", "<=", "?", ":", "&&", "||", "!", "~", "&", "|", "^", "+", "-",
              "*", "/", "%", "==", "!=", "<", ">", ">=", "===", "!==", "<<", ">>", "return"}


def join(toks):
    """tokens -> one line of code with canonical spacing (comments dropped: see inner_comments)"""
    c = [t for t in toks if t.k not in ("ws", "nl", "lc", "bc")]
    s = ""
    br = 0
    for k, t in enumerate(c):
        if k:
            a = c[k - 1]
            if br > 0 and (t.s in (":", "+:", "-:") or a.s in (":", "+:", "-:")):
                s += t.s
                br += (t.s == "[") - (t.s == "]")
                continue
            unary_a = a.s in ("-", "+", "~", "!", "&", "|", "^", "~&", "~|", "~^") and (k == 1 or c[k - 2].s in UNARY_PREV)
            if not (unary_a or no_space(a, t)):
                s += " "
        s += t.s
        br += (t.s == "[") - (t.s == "]")
    return s


def no_space(a, b):
    if b.s in (",", ";", ")", "]", "}", ".", "::") or a.s in ("(", "[", "{", ".", "::", "'", "#", "@", "~", "!"):
        return True
    if b.s == "'" :
        return True
    if b.s == "[" and ((a.k == "id" and a.s not in KEYWORDS) or a.k == "num" or a.s in ("]", ")")):
        return True
    if b.s == "(" and a.k == "id" and (a.s.startswith("$") or a.s not in KEYWORDS):
        return True
    if b.s == "{" and a.k == "num":
        return True
    if a.s == "}" and b.s == "}":
        return True
    return False


KEYWORDS = set("""always always_ff always_comb always_latch assign begin end if else case casez casex
endcase default for while repeat forever posedge negedge or and not module endmodule input output
inout wire reg logic integer parameter localparam generate endgenerate genvar function endfunction
task endtask initial signed unsigned unique priority return int automatic""".split())


# ------------------------------------------------------------------------------------------------
# statement tree of an always body
# ------------------------------------------------------------------------------------------------
class Stmt:
    def __init__(self, kind, **kw):
        self.kind = kind
        self.lead = []      # comments before it (strings)
        self.trail = None   # comment after it on its line
        self.__dict__.update(kw)


class Parser:
    def __init__(self, toks):
        self.t = toks
        self.i = 0

    # -- low level ------------------------------------------------------------------------------
    def peek(self, skip_comments=True):
        j = self.i
        while j < len(self.t) and self.t[j].k in (("ws", "nl", "lc", "bc") if skip_comments else ("ws", "nl")):
            j += 1
        return self.t[j] if j < len(self.t) else None

    def comments(self):
        """collect comments up to the next code token"""
        out = []
        while self.i < len(self.t) and self.t[self.i].k in ("ws", "nl", "lc", "bc"):
            if self.t[self.i].k in ("lc", "bc"):
                out.append(self.t[self.i].s)
            self.i += 1
        return out

    def trailing(self):
        """a comment on the same line right after the last token"""
        j = self.i
        while j < len(self.t) and self.t[j].k == "ws":
            j += 1
        if j < len(self.t) and self.t[j].k in ("lc", "bc") and "\n" not in self.t[j].s:
            self.i = j + 1
            return self.t[j].s
        return None

    def next(self):
        self.comments_inline = self.comments()
        tok = self.t[self.i]
        self.i += 1
        return tok

    def expect(self, s):
        tok = self.next()
        if tok.s != s:
            raise SyntaxError("expected %r, got %r" % (s, tok.s))
        return tok

    def balanced(self, open_, close):
        """from an opening token (already consumed) to its partner; returns inner tokens"""
        depth, out = 1, []
        while True:
            tok = self.t[self.i]
            self.i += 1
            if tok.s == open_:
                depth += 1
            elif tok.s == close:
                depth -= 1
                if depth == 0:
                    return out
            out.append(tok)

    def until_semicolon(self):
        out, depth = [], 0
        while True:
            tok = self.t[self.i]
            self.i += 1
            if tok.s in ("(", "[", "{"):
                depth += 1
            elif tok.s in (")", "]", "}"):
                depth -= 1
            elif tok.s == ";" and depth == 0:
                return out
            out.append(tok)

    # -- statements -----------------------------------------------------------------------------
    def stmt(self):
        lead = self.comments()
        tok = self.peek()
        if tok is None:
            raise SyntaxError("end of text inside a statement")
        if tok.s == "begin":
            self.next()
            label = None
            if self.peek().s == ":":
                self.next()
                label = self.next().s
            tr = self.trailing()
            body = []
            while self.peek().s != "end":
                body.append(self.stmt())
            endc = self.comments()
            self.next()  # end
            if self.peek(False) is not None and self.peek(False).s == ":":
                self.next()
                self.next()
            st = Stmt("block", label=label, body=body, tail=endc)
            st.trail = tr
            st.trail_end = self.trailing()
        elif tok.s == "if":
            self.next()
            self.expect("(")
            cond = self.balanced("(", ")")
            tr = self.trailing()
            then = self.stmt()
            els = None
            save = self.i
            pre = self.comments()
            if self.peek() is not None and self.peek().s == "else":
                self.next()
                tre = self.trailing()
                els = self.stmt()
                els.lead = pre + els.lead
                if tre:
                    els.lead.append(tre)
            else:
                self.i = save
            st = Stmt("if", cond=cond, then=then, els=els)
            st.trail = tr
        elif tok.s in ("case", "casez", "casex", "unique", "priority"):
            pre = []
            while self.peek().s in ("unique", "priority"):
                pre.append(self.next().s)
            kw = self.next().s
            self.expect("(")
            sel = self.balanced("(", ")")
            tr = self.trailing()
            items = []
            while self.peek().s != "endcase":
                ilead = self.comments()
                if self.peek().s == "default":
                    self.next()
                    if self.peek().s == ":":
                        self.next()
                    labels = None
                else:
                    labels, depth = [], 0
                    while True:
                        t2 = self.t[self.i]
                        self.i += 1
                        if t2.s in ("(", "[", "{"):
                            depth += 1
                        elif t2.s in (")", "]", "}"):
                            depth -= 1
                        elif t2.s == ":" and depth == 0:
                            break
                        labels.append(t2)
                body = self.stmt()
                body.lead = ilead + body.lead
                items.append((labels, body))
            endc = self.comments()
            self.next()
            st = Stmt("case", pre=pre, kw=kw, sel=sel, items=items, tail=endc)
            st.trail = tr
            st.trail_end = self.trailing()
        elif tok.s == "for":
            self.next()
            self.expect("(")
            hdr = self.balanced("(", ")")
            tr = self.trailing()
            body = self.stmt()
            st = Stmt("for", hdr=hdr, body=body)
            st.trail = tr
        elif tok.s == ";":
            self.next()
            st = Stmt("null")
            st.trail = self.trailing()
        else:
            toks = self.until_semicolon()
            st = Stmt("simple", toks=toks)
            st.trail = self.trailing()
        st.lead = lead + st.lead
        return st


# ------------------------------------------------------------------------------------------------
# printing
# ------------------------------------------------------------------------------------------------
def put_comments(out, ind, comments):
    for c in comments:
        for ln in c.splitlines():
            out.append(ind + ln.strip())


def block_lines(st, ind, out):
    """the statements of a block body (st may be a block or a single statement)"""
    if st.kind == "block":
        for s in st.body:
            emit(s, ind, out)
        put_comments(out, ind, st.tail)
    elif st.kind == "null":
        put_comments(out, ind, st.lead)
    else:
        emit(st, ind, out)


def with_trail(line, trail):
    return line + ("  " + trail.strip() if trail else "")


def emit(st, ind, out):
    put_comments(out, ind, st.lead)
    if st.kind == "simple":
        put_comments(out, ind, inner_comments(st.toks))
        out.append(with_trail(ind + join(st.toks) + ";", st.trail))
    elif st.kind == "null":
        if st.trail:
            out.append(ind + st.trail.strip())
    elif st.kind == "block":
        lab = (" : " + st.label) if st.label else ""
        out.append(with_trail(ind + "begin" + lab, st.trail))
        block_lines(st, ind + IND, out)
        out.append(with_trail(ind + "end", getattr(st, "trail_end", None)))
    elif st.kind == "if":
        emit_if(st, ind, out, ind + "if")
    elif st.kind == "case":
        pre = " ".join(st.pre + [st.kw])
        out.append(with_trail(ind + "%s (%s)" % (pre, join(st.sel)), st.trail))
        for labels, body in st.items:
            put_comments(out, ind + IND, body.lead)
            body.lead = []
            head = ind + IND + ("default" if labels is None else join(labels)) + ":"
            put_comments(out, ind + IND, inner_comments(labels or []))
            if body.kind == "simple":
                put_comments(out, ind + IND, inner_comments(body.toks))
                line = with_trail(head + " " + join(body.toks) + ";", body.trail)
                out.append(line)
            elif body.kind == "null":
                out.append(with_trail(head + " begin", body.trail))
                out.append(ind + IND + "end")
            else:
                trail = body.trail if body.kind == "block" else None
                out.append(with_trail(head + " begin", trail))
                if body.kind == "block":
                    body.trail = None
                block_lines(body, ind + IND + IND, out)
                out.append(ind + IND + "end")
        put_comments(out, ind + IND, st.tail)
        out.append(with_trail(ind + "endcase", getattr(st, "trail_end", None)))
    elif st.kind == "for":
        out.append(with_trail(ind + "for (%s) begin" % join(st.hdr), st.trail))
        block_lines(st.body, ind + IND, out)
        out.append(ind + "end")


def emit_if(st, ind, out, head):
    put_comments(out, ind, inner_comments(st.cond))
    trail = st.trail
    if st.then.kind == "block" and st.then.trail and not trail:
        trail = st.then.trail
    out.append(with_trail(head + " (%s) begin" % join(st.cond), trail))
    if st.then.kind == "block":
        put_comments(out, ind + IND, st.then.lead)
    block_lines(st.then, ind + IND, out)
    e = st.els
    if e is None:
        out.append(ind + "end")
        return
    lead = e.lead
    e.lead = []
    if e.kind == "if":
        put_comments(out, ind, lead) if lead else None
        if lead:
            out.append(ind + "end")
            emit_if(e, ind, out, ind + "else if")
        else:
            emit_if(e, ind, out, ind + "end else if")
        return
    out.append(ind + "end else begin" + ("  " + e.trail.strip() if e.kind == "block" and e.trail else ""))
    put_comments(out, ind + IND, lead)
    if e.kind == "block":
        e.trail = None
    block_lines(e, ind + IND, out)
    out.append(ind + "end")


# ------------------------------------------------------------------------------------------------
# always blocks
# ------------------------------------------------------------------------------------------------
def first_target(st):
    """the first variable assigned in a statement tree"""
    if st.kind == "simple":
        c = code(st.toks)
        for k, t in enumerate(c):
            if t.s in ("<=", "=") and k > 0:
                return c[0].s if c[0].k == "id" else None
        return None
    for sub in ([st.then, st.els] if st.kind == "if" else st.body if st.kind == "block"
                else [b for _, b in st.items] if st.kind == "case" else [st.body] if st.kind == "for" else []):
        if sub is not None:
            r = first_target(sub)
            if r:
                return r
    return None


def make_label(prefix, name, used):
    base = re.sub(r"_(q|r|reg|d|o|i|nxt|next)$", "", name or "blk").lower()
    base = re.sub(r"[^a-z_]", "", base.replace("0", "zero").replace("1", "one"))
    base = re.sub(r"_+", "_", base).strip("_") or "blk"
    lab = (prefix + "_" + base)[:16].rstrip("_")
    while len(lab) < 4:
        lab += "x"
    k = 0
    cand = lab
    while cand in used:
        k += 1
        suf = "_" + "abcdefghijklmnop"[k % 16] * (1 + k // 16)
        cand = lab[:16 - len(suf)] + suf
    used.add(cand)
    return cand


def rewrite_always(toks, start, used, latch):
    """toks[start] is `always`; returns (new lines, index after the block)"""
    p = Parser(toks)
    p.i = start + 1
    p.comments()
    sens = None
    if p.peek().s == "@":
        p.next()
        if p.peek().s == "*":
            p.next()
            sens = None
        else:
            p.expect("(")
            sens = p.balanced("(", ")")
    tr = p.trailing()
    body = p.stmt()
    seq = sens is not None and any(t.s in ("posedge", "negedge") for t in sens)
    if latch:
        kw, head = "always_latch", "always_latch"
    elif seq:
        kw, head = "always_ff", "always_ff @(%s)" % join(sens)
    else:
        kw, head = "always_comb", "always_comb"
    label = body.label if body.kind == "block" and body.label else None
    if label is None or len(label) < 4 or len(label) > 16 or re.search(r"\d$", label) or label != label.lower():
        label = make_label("p" if seq else ("l" if latch else "c"), first_target(body), used)
    else:
        used.add(label)
    lines = []
    trail = tr or (body.trail if body.kind == "block" else None)
    lines.append(with_trail(head + " begin : " + label, trail))
    if body.kind == "block":
        put_comments(lines, IND, body.lead)
        body.lead = []
    block_lines(body, IND, lines)
    lines.append("end")
    return lines, p.i, body


DECL_KW = ("input", "output", "inout", "reg", "integer", "logic", "int", "bit", "wire", "localparam")


def rewrite_function(toks, start):
    """`function ... ; decls; statements endfunction`: statements in the canonical style.
    Returns (text from `function` to `endfunction` inclusive, index after it), or None."""
    p = Parser(toks)
    p.i = start
    # header up to its ';'
    j = start
    while j < len(toks) and toks[j].s != ";":
        j += 1
    p.i = j + 1
    # declarations
    while True:
        save = p.i
        p.comments()
        nt = p.peek()
        if nt is not None and nt.s in DECL_KW:
            p.until_semicolon()
            continue
        p.i = save
        break
    body_start = p.i
    stmts = []
    try:
        while True:
            save = p.i
            p.comments()
            if p.peek().s == "endfunction":
                p.i = save
                break
            p.i = save
            stmts.append(p.stmt())
    except (SyntaxError, IndexError):
        return None
    tail = p.comments()
    end_i = p.i
    while toks[end_i].s != "endfunction":
        end_i += 1
    # indentation of the `function` line
    k = start - 1
    while k >= 0 and toks[k].k == "ws":
        k -= 1
    ind = toks[start - 1].s if start and toks[start - 1].k == "ws" else ""
    head = "".join(x.s for x in toks[start:body_start]).rstrip()
    head = re.sub(r"^function\s+(?!automatic\b)", "function automatic ", head)   # HAL NAUTOF
    out = []
    for st in stmts:
        emit(st, ind + IND, out)
    put_comments(out, ind + IND, tail)
    return head + "\n" + "\n".join(out) + "\n" + ind + "endfunction", end_i + 1


# ------------------------------------------------------------------------------------------------
# line-level passes
# ------------------------------------------------------------------------------------------------
def fix_literals(line):
    def pad(m):
        size, base, digits = int(m.group(1)), m.group(2).lower(), m.group(3)
        d = digits.replace("_", "")
        per = {"h": 4, "b": 1, "o": 3}[base]
        need = -(-size // per)
        if len(d) < need and re.fullmatch(r"[0-9a-fA-F]+" if base == "h" else r"[01]+" if base == "b" else r"[0-7]+", d):
            d = "0" * (need - len(d)) + d
            return "%d'%s%s" % (size, m.group(2), d)
        return m.group(0)
    return re.sub(r"\b(\d+)'([hHbBoO])([0-9a-fA-F_]+)\b", pad, line)


def split_code_comment(line):
    """(code, comment) of a line; strings and literals respected"""
    toks = lex(line)
    for k, t in enumerate(toks):
        if t.k in ("lc",):
            return "".join(x.s for x in toks[:k]).rstrip(), t.s
    return line.rstrip(), None


def wrap_comment(ind, text):
    """re-wrap // comment text to fit"""
    body = text[2:].strip() if text.startswith("//") else text
    lead = ind + "// "
    d = re.match(r"^(.*?)\s*([-=~*#]{3,})\s*$", body)
    if d and d.group(1) and blen(lead + d.group(1)) + 4 <= MAXLEN:
        return [(lead + d.group(1) + " " + d.group(2))[:MAXLEN].rstrip()]
    if re.fullmatch(r"[=\-~*#]{6,}.*", body):
        return [(ind + "// " + body)[:MAXLEN]]
    words = body.split()
    out, cur = [], ""
    for w in words:
        if blen(lead + (cur + " " + w if cur else w)) > MAXLEN and cur:
            out.append(lead + cur)
            cur = w
        else:
            cur = cur + " " + w if cur else w
    if cur or not out:
        out.append(lead + cur)
    return out


def break_code(line):
    """break a code line at its outermost level so every piece fits"""
    ind = re.match(r"\s*", line).group(0)
    toks = [t for t in lex(line.strip()) if t.k != "ws"]
    if blen(line) <= MAXLEN:
        return [line]
    # candidate break points: after ',' or before a binary operator, at the lowest paren depth
    pieces = [[]]
    depth, mind = 0, 99
    pts = []
    for k, t in enumerate(toks):
        if t.s in ("(", "[", "{"):
            depth += 1
        elif t.s in (")", "]", "}"):
            depth -= 1
        if t.s == "," or t.s in ("&&", "||", "?", ":", "|", "&", "^", "+", "-", "<=", "="):
            pts.append((depth, k, t.s))
    if not pts:
        return [line]
    best = min(d for d, _, _ in pts)
    cont = ind + IND
    out, cur = [], []
    first = True
    for depth_k in range(best, max(d for d, _, _ in pts) + 1):
        cut = {k for d, k, s in pts if d <= depth_k and not (s in ("<=", "=") and d > 0)}
        out, cur = [], []
        for k, t in enumerate(toks):
            if k in cut and t.s != "," and cur:
                out.append(cur)
                cur = []
            cur.append(t)
            if k in cut and t.s == ",":
                out.append(cur)
                cur = []
        if cur:
            out.append(cur)
        lines = [(ind if i == 0 else cont) + join(seg) for i, seg in enumerate(out)]
        # re-join greedily
        res = []
        for ln in lines:
            if res and blen(res[-1] + " " + ln.strip()) <= MAXLEN:
                res[-1] = res[-1] + " " + ln.strip()
            else:
                res.append(ln)
        if all(blen(x) <= MAXLEN for x in res):
            return res
    return res


DECOR = re.compile(r"^(\s*//.*?)\s*([-=~*#]{3,})\s*$")


def comment_only(ln):
    return re.match(r"^\s*//", ln) is not None


def para_text(ln):
    return re.sub(r"^\s*//\s?", "", ln).rstrip()


def tidy_lines(lines):
    lines = list(lines)
    out = []
    k = 0
    while k < len(lines):
        ln = lines[k].rstrip()
        k += 1
        if blen(ln) > MAXLEN and comment_only(ln):
            d = DECOR.match(ln)
            if d and blen(d.group(1)) + 4 <= MAXLEN:      # a rule: shorten its tail
                out.append((d.group(1) + " " + d.group(2))[:MAXLEN].rstrip())
                continue
            ind = re.match(r"\s*", ln).group(0)
            words = para_text(ln).split()
            # the rest of the paragraph: plain comment lines at the same indent
            while k < len(lines) and comment_only(lines[k]) and re.match(r"\s*", lines[k]).group(0) == ind:
                t = para_text(lines[k])
                if not t.strip() or re.match(r"^\s*([-*]|\d+[.)]|\[|[=\-~*#]{3,})", t) or t.startswith("  "):
                    break
                words += t.split()
                k += 1
            cur = ""
            for w in words:
                if cur and blen(ind + "// " + cur + " " + w) > MAXLEN:
                    out.append(ind + "// " + cur)
                    cur = w
                else:
                    cur = cur + " " + w if cur else w
            out.append(ind + "// " + cur)
            continue
        out.extend(tidy_one(ln))
    return out


def tidy_one(ln):
    out = []
    if True:
        ln = fix_literals(ln.rstrip())
        if blen(ln) <= MAXLEN:
            return [ln]
        ind = re.match(r"\s*", ln).group(0)
        c, com = split_code_comment(ln)
        if not c.strip():
            return wrap_comment(ind, com.strip())
        if com:
            out.extend(wrap_comment(ind, com.strip()))
            ln = c
            if blen(ln) <= MAXLEN:
                out.append(ln)
                return out
        out.extend(break_code(ln))
    return out


# ------------------------------------------------------------------------------------------------
# whole file
# ------------------------------------------------------------------------------------------------
def mask_text(t):
    """comments and strings blanked, same length, newlines kept"""
    out = list(t)
    for m in re.finditer(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"', t, re.S):
        for k in range(m.start(), m.end()):
            if out[k] != "\n":
                out[k] = " "
    return "".join(out)


def header_end(m, i):
    """index of the ';' that ends a module header, from just after `module NAME` (masked text)"""
    n = len(m)

    def skip_ws(j):
        while j < n and m[j] in " \t\r\n":
            j += 1
        return j

    def match(j):
        d = 0
        while j < n:
            if m[j] == "(":
                d += 1
            elif m[j] == ")":
                d -= 1
                if d == 0:
                    return j
            j += 1
        return -1
    j = skip_ws(i)
    while m.startswith("import", j):
        j = m.find(";", j) + 1
        j = skip_ws(j)
    if j < n and m[j] == "#":
        j = skip_ws(j + 1)
        j = match(j) + 1
        j = skip_ws(j)
    if j < n and m[j] == "(":
        j = match(j) + 1
        j = skip_ws(j)
    return j if j < n and m[j] == ";" else -1


DIRS = ("input", "output", "inout")


def normalise_ports(text):
    """ANSI port lists: one declaration per line (HAL DECLIN, SEPLIN)"""
    m_ = mask_text(text)
    out, pos = [], 0
    for mm in re.finditer(r"\bmodule\s+\w+", m_):
        e = header_end(m_, mm.end())
        if e < 0:
            continue
        # the port list: last '(' .. ')' before e at depth 0 after the optional #( )
        close = m_.rfind(")", mm.end(), e)
        d, k = 0, close
        while k > mm.end():
            if m_[k] == ")":
                d += 1
            elif m_[k] == "(":
                d -= 1
                if d == 0:
                    break
            k -= 1
        opn = k
        inner = text[opn + 1:close]
        if not re.search(r"\b(input|output|inout)\b", mask_text(inner)):
            continue
        toks = lex(inner)
        decls = []          # [code tokens, comments above, trailing comment]
        cur, above, depth, nl_seen = [], [], 0, True
        for t in toks:
            if t.k == "nl":
                nl_seen = True
                continue
            if t.k == "ws":
                continue
            if t.k in ("lc", "bc"):
                if not nl_seen and decls and not cur:
                    decls[-1][2] = (decls[-1][2] + " " if decls[-1][2] else "") + t.s.strip()
                elif not nl_seen and cur:
                    above.append(t.s)
                else:
                    above.append(t.s)
                continue
            if t.s in ("(", "[", "{"):
                depth += 1
            elif t.s in (")", "]", "}"):
                depth -= 1
            if t.s == "," and depth == 0:
                decls.append([cur, above, None])
                cur, above = [], []
                nl_seen = False
                continue
            cur.append(t)
            nl_seen = False
        if cur:
            decls.append([cur, above, None])
            above = []
        lines, last = [], None
        for n_, (c, ab, tr) in enumerate(decls):
            if c and c[0].s in DIRS:
                last = c[:-1]
                decl = join(c)
            else:
                decl = (join(last) + " " + join(c)) if last else join(c)
            for cm in ab:
                for ln in cm.strip().splitlines():
                    lines.append(IND + ln.strip())
            sep = "," if n_ < len(decls) - 1 else ""
            lines.append(IND + decl + sep + (("  " + tr) if tr else ""))
        for cm in above:
            lines.append(IND + cm.strip())
        out.append(text[pos:opn + 1] + "\n" + "\n".join(lines) + "\n")
        pos = close
    out.append(text[pos:])
    return "".join(out)


def module_level(text):
    """module-level passes on raw text: directives, parameters"""
    ts = re.search(r"^`timescale\s+(\S+)\s*/\s*(\S+)\s*$", text, re.M)
    text = re.sub(r"^`timescale[^\n]*\n", "", text, flags=re.M)
    text = re.sub(r"^`default_nettype[^\n]*\n", "", text, flags=re.M)
    unit, prec = (ts.group(1), ts.group(2)) if ts else ("1ns", "1ps")

    m_ = mask_text(text)
    out, pos = [], 0
    for mm in re.finditer(r"\bmodule\s+\w+", m_):
        e = header_end(m_, mm.end())
        if e < 0 or e < pos:
            continue
        out.append(text[pos:e + 1])
        out.append("\n" + IND + "timeunit %s;\n%stimeprecision %s;" % (unit, IND, prec))
        pos = e + 1
    out.append(text[pos:])
    text = "".join(out)

    def par(m):
        kw, typ, rest = m.group(1), m.group(2), m.group(3)
        if not typ.strip() and not re.match(r"\s*\[", rest) and re.match(r"\s*\w+\s*=\s*\d+\s*(?:[,;)/]|$)", rest):
            typ = " integer"              # PRMVAL: an untyped parameter with a bare number
        rest = re.sub(r"(=\s*)(\d+)(?=\s*(?:[,;)/]|$))", lambda q: q.group(1) + "32'd" + q.group(2), rest)
        return kw + typ + rest
    text = re.sub(r"\b(parameter|localparam)(\s+integer|)(\b[^;\n]*)", par, text)
    return text


ASCII = {"\u00a7": "Sec.", "\u2014": "-", "\u2500": "-", "\u25b6": ">", "\u00f7": "/", "\u2502": "|",
         "\u2514": "`", "\u2192": "->", "\u2190": "<-", "\u00b1": "+/-", "\u00d7": "x", "\u2264": "<=",
         "\u2265": ">=", "\u2248": "~", "\u2019": "'", "\u201c": '"', "\u201d": '"', "\u2026": "..."}


def process(text, path=""):
    text = text.replace("\r\n", "\n").replace("\t", IND)
    text = "".join(ASCII.get(ch, ch) for ch in text)
    text = normalise_ports(text)
    text = module_level(text)
    toks = lex(text)
    out_lines = []
    used = set(re.findall(r"begin\s*:\s*(\w+)", text))
    i = 0
    buf = []
    while i < len(toks):
        t = toks[i]
        if t.k == "id" and t.s == "function":
            j = rewrite_function(toks, i)
            if j is not None:
                lines, j2 = j
                prefix = "".join(x.s for x in buf)
                out_lines.append(prefix + lines)
                buf = []
                i = j2
                continue
        if t.k == "id" and t.s == "always":
            latch = "rtl_style: latch" in "".join(x.s for x in toks[max(0, i - 6):i])
            prefix = "".join(x.s for x in buf)
            ind = re.search(r"([ \t]*)$", prefix).group(1)
            prefix = prefix[:len(prefix) - len(ind)]
            lines, j, _ = rewrite_always(toks, i, used, latch)
            buf = [T("raw", prefix + "\n".join(ind + l if l else l for l in lines))]
            out_lines.append("".join(x.s for x in buf))
            buf = []
            i = j
            continue
        buf.append(t)
        i += 1
    out_lines.append("".join(x.s for x in buf))
    text = "".join(out_lines)
    # one statement / declaration per line at module level
    lines = []
    for ln in text.split("\n"):
        lines.extend(split_statements(ln))
    lines = tidy_lines(lines)
    text = "\n".join(lines)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.rstrip() + "\n"


DECL = re.compile(r"^(\s*)((?:input|output|inout)\s+)?(wire|reg|logic|integer|genvar)\b(\s+signed)?\s*(\[[^\]]*\])?\s*(.*)$")


def split_statements(ln):
    c, com = split_code_comment(ln)
    if not c.strip():
        return [ln]
    ind = re.match(r"\s*", c).group(0)
    toks = [t for t in lex(c.strip())]
    # split on ';' at depth 0 (not inside a for header)
    parts, cur, depth = [], [], 0
    for t in toks:
        if t.s in ("(", "[", "{"):
            depth += 1
        elif t.s in (")", "]", "}"):
            depth -= 1
        cur.append(t)
        if t.s == ";" and depth == 0:
            parts.append(cur)
            cur = []
    if cur and any(x.k != "ws" for x in cur):
        parts.append(cur)
    res = []
    for p in parts:
        s = "".join(x.s for x in p).strip()
        res.extend(split_decl(ind, s))
    if com:
        if len(res) == 1:
            res[0] = res[0] + "  " + com.strip()
        else:
            res.insert(0, ind + com.strip())
    return res if res else [ln]


def split_decl(ind, s):
    """`wire a, b;` -> one declaration per line (not port lists, not assignments with commas)"""
    m = DECL.match(ind + s)
    if not m or m.group(2) or not s.endswith(";"):
        return [ind + s]
    names = m.group(6)[:-1]
    parts, cur, depth = [], "", 0
    for ch in names:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += ch
    parts.append(cur.strip())
    if len(parts) == 1:
        return [ind + s]
    head = m.group(3) + (m.group(4) or "") + ((" " + m.group(5)) if m.group(5) else "")
    return [ind + head + " " + p + ";" for p in parts]


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    for f in args:
        text = open(f, errors="surrogateescape").read()
        new = process(text, f)
        if "--check" in sys.argv:
            sys.stdout.write(new)
        elif new != text:
            open(f, "w", errors="surrogateescape").write(new)
            print("rtl_style: rewrote %s" % f)
    return 0


if __name__ == "__main__":
    sys.exit(main())
