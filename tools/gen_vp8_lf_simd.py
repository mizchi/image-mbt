#!/usr/bin/env python3
"""Generate wasm SIMD (inline WAT) VP8 loop-filter kernels for MoonBit.

Each kernel filters 16 lanes at once with exactly the scalar arithmetic
(widened to i16x8). Lanes are 16 contiguous pixels (horizontal edges), or
16 rows gathered with a byte transpose (vertical edges); chroma kernels pack
8 lanes of U and 8 of V.
"""
import sys


class Fn:
    def __init__(self, nparams):
        self.np = nparams
        self.i32 = {}
        self.v = {}
        self.code = []

    def li(self, name):
        if name not in self.i32:
            self.i32[name] = None
        return name

    def lv(self, name):
        if name not in self.v:
            self.v[name] = None
        return name

    def emit(self, s):
        self.code.append(s)

    def finish(self, params):
        idx = {}
        for i, p in enumerate(params):
            idx[p] = i
        n = len(params)
        decl = []
        for k in self.i32:
            idx[k] = n
            n += 1
            decl.append("(local i32)")
        for k in self.v:
            idx[k] = n
            n += 1
            decl.append("(local v128)")
        body = []
        for c in self.code:
            out = []
            for tok in c.split():
                if tok.startswith("$"):
                    out.append(str(idx[tok[1:]]))
                else:
                    out.append(tok)
            body.append(" ".join(out))
        head = "(func " + " ".join("(param i32)" for _ in params)
        return head + " " + " ".join(decl) + " " + " ".join(body) + ")"


def get(n):
    return "local.get $" + n


def setl(n):
    return "local.set $" + n


def shuffle(a, b, idx):
    return "%s %s i8x16.shuffle %s" % (get(a), get(b), " ".join(map(str, idx)))


# ---------------------------------------------------------------------------
# Byte transposes, checked by symbolic simulation.

def sim_shuffle(va, vb, idx):
    both = va + vb
    return [both[i] for i in idx]


def interleave_idx(unit, hi):
    """Interleave `unit`-byte elements of a (low/high half) with b."""
    per = 8 // unit
    base = 8 if hi else 0
    out = []
    for e in range(per):
        for src in (0, 16):
            for k in range(unit):
                out.append(src + base + e * unit + k)
    return out


def pair_up(cur, by_rows):
    """Pair vectors holding the same column set (or row set) whose row (or
    column) ranges are adjacent, in order."""
    groups = {}
    for name, t in cur:
        valid = [x for x in t if x[0] is not None]
        key = frozenset(x[1] if not by_rows else x[0] for x in valid)
        order = min(x[0] if not by_rows else x[1] for x in valid)
        groups.setdefault(key, []).append((order, name, t))
    pairs = []
    for key in sorted(groups, key=lambda k: min(k)):
        g = sorted(groups[key])
        assert len(g) % 2 == 0, g
        for k in range(0, len(g), 2):
            pairs.append(((g[k][1], g[k][2]), (g[k + 1][1], g[k + 1][2])))
    return pairs


def run_stages(f, cur, stages, by_rows, prefix):
    for stage, (unit, halves) in enumerate(stages):
        out = []
        for j, ((a, ta), (b, tb)) in enumerate(pair_up(cur, by_rows)):
            for hi in halves:
                idx = interleave_idx(unit, hi)
                name = f.lv("%s%d_%d_%d" % (prefix, stage, j, int(hi)))
                f.emit(shuffle(a, b, idx) + " " + setl(name))
                out.append((name, sim_shuffle(ta, tb, idx)))
        cur = out
    return cur


def transpose_rows_to_cols(f, rows, tags):
    """rows: 16 v128 locals, row r valid in bytes 0..7 (tags[r][c]).
    Returns 8 column locals, column c holding rows 0..15 in lanes 0..15."""
    cur = list(zip(rows, tags))
    cur = run_stages(f, cur, [(1, (False,)), (2, (False, True)), (4, (False, True)), (8, (False, True))], False, "t")
    cols = [None] * 8
    for name, t in cur:
        cs = set(c for (r, c) in t)
        assert len(cs) == 1, t
        c = cs.pop()
        assert [r for (r, cc) in t] == list(range(16)), t
        cols[c] = name
    assert all(cols)
    return cols


def transpose_cols_to_rows(f, cols):
    """cols: 8 locals (column c, lanes = rows 0..15). Returns (local, lane,
    row) for the 64-bit lane holding each row's 8 bytes (cols 0..7)."""
    cur = [(cols[c], [(r, c) for r in range(16)]) for c in range(8)]
    cur = run_stages(f, cur, [(1, (False, True)), (2, (False, True)), (4, (False, True))], True, "u")
    where = []
    for name, t in cur:
        for lane in (0, 1):
            part = t[lane * 8:(lane + 1) * 8]
            rs = set(r for (r, c) in part)
            assert len(rs) == 1, part
            assert [c for (r, c) in part] == list(range(8)), part
            where.append((name, lane, rs.pop()))
    assert sorted(w[2] for w in where) == list(range(16))
    return where


# ---------------------------------------------------------------------------
# The filter itself on 8 u8x16 vectors.

def filter_core(f, P, consts):
    """P: names of p3,p2,p1,p0,q0,q1,q2,q3 (u8x16). Writes new vectors into
    names np2, np1, np0, nq0, nq1, nq2 (u8x16)."""
    T2, IT, HEV, EDGE = consts
    halves = {}
    for half in ("lo", "hi"):
        ext = "i16x8.extend_low_i8x16_u" if half == "lo" else "i16x8.extend_high_i8x16_u"
        w = {}
        for nm in ("p3", "p2", "p1", "p0", "q0", "q1", "q2", "q3"):
            w[nm] = f.lv(nm + "_" + half)
        for nm, src in zip(("p3", "p2", "p1", "p0", "q0", "q1", "q2", "q3"), P):
            f.emit("%s %s %s" % (get(src), ext, setl(w[nm])))
        def t(name, half=half):
            return f.lv(name + "_" + half)
        def absdiff(a, b, out):
            f.emit("%s %s i16x8.sub i16x8.abs %s" % (get(a), get(b), setl(out)))
        absdiff(w["p0"], w["q0"], t("d_p0q0"))
        absdiff(w["p1"], w["q1"], t("d_p1q1"))
        # m1: 4 * |p0 - q0| + |p1 - q1| <= t2
        f.emit("%s i32.const 2 i16x8.shl %s i16x8.add %s i16x8.le_s %s" % (
            get(t("d_p0q0")), get(t("d_p1q1")), get(T2), setl(t("mask"))))
        absdiff(w["p3"], w["p2"], t("d0"))
        absdiff(w["p2"], w["p1"], t("d1"))
        absdiff(w["p1"], w["p0"], t("d2"))
        absdiff(w["q3"], w["q2"], t("d3"))
        absdiff(w["q2"], w["q1"], t("d4"))
        absdiff(w["q1"], w["q0"], t("d5"))
        # hev: max(|p1 - p0|, |q1 - q0|) > hev
        f.emit("%s %s i16x8.max_s %s i16x8.gt_s %s" % (
            get(t("d2")), get(t("d5")), get(HEV), setl(t("hev"))))
        # interior: all six <= it
        f.emit("%s %s i16x8.max_s %s i16x8.max_s %s i16x8.max_s %s i16x8.max_s %s i16x8.max_s %s i16x8.le_s %s v128.and %s" % (
            get(t("d0")), get(t("d1")), get(t("d2")), get(t("d3")), get(t("d4")), get(t("d5")),
            get(IT), get(t("mask")), setl(t("mask"))))
        # q0 - p0, p1 - q1 (signed-clipped)
        f.emit("%s %s i16x8.sub %s" % (get(w["q0"]), get(w["p0"]), setl(t("qp"))))
        f.emit("%s %s i16x8.sub i32.const -128 i16x8.splat i16x8.max_s i32.const 127 i16x8.splat i16x8.min_s %s" % (
            get(w["p1"]), get(w["q1"]), setl(t("pq"))))
        # 3 * (q0 - p0)
        f.emit("%s %s i16x8.add %s i16x8.add %s" % (get(t("qp")), get(t("qp")), get(t("qp")), setl(t("a3x"))))
        def sc2(expr_name, add, out):
            f.emit("%s i32.const %d i16x8.splat i16x8.add i32.const 3 i16x8.shr_s i32.const -16 i16x8.splat i16x8.max_s i32.const 15 i16x8.splat i16x8.min_s %s" % (
                get(expr_name), add, setl(out)))
        def clip(expr, out):
            f.emit("%s i32.const 0 i16x8.splat i16x8.max_s i32.const 255 i16x8.splat i16x8.min_s %s" % (expr, setl(out)))
        # filter2 (hev): a = 3 (q0 - p0) + sclip1(p1 - q1)
        f.emit("%s %s i16x8.add %s" % (get(t("a3x")), get(t("pq")), setl(t("a2f"))))
        sc2(t("a2f"), 4, t("f2a1"))
        sc2(t("a2f"), 3, t("f2a2"))
        clip("%s %s i16x8.add" % (get(w["p0"]), get(t("f2a2"))), t("f2p0"))
        clip("%s %s i16x8.sub" % (get(w["q0"]), get(t("f2a1"))), t("f2q0"))
        # filter4 (inner, !hev): a = 3 (q0 - p0)
        sc2(t("a3x"), 4, t("f4a1"))
        sc2(t("a3x"), 3, t("f4a2"))
        f.emit("%s i32.const 1 i16x8.splat i16x8.add i32.const 1 i16x8.shr_s %s" % (get(t("f4a1")), setl(t("f4a3"))))
        clip("%s %s i16x8.add" % (get(w["p1"]), get(t("f4a3"))), t("f4p1"))
        clip("%s %s i16x8.add" % (get(w["p0"]), get(t("f4a2"))), t("f4p0"))
        clip("%s %s i16x8.sub" % (get(w["q0"]), get(t("f4a1"))), t("f4q0"))
        clip("%s %s i16x8.sub" % (get(w["q1"]), get(t("f4a3"))), t("f4q1"))
        # filter6 (edge, !hev): a = sclip1(3 (q0 - p0) + sclip1(p1 - q1))
        f.emit("%s i32.const -128 i16x8.splat i16x8.max_s i32.const 127 i16x8.splat i16x8.min_s %s" % (
            get(t("a2f")), setl(t("f6a"))))
        for k, nm in ((27, "f6a1"), (18, "f6a2"), (9, "f6a3")):
            f.emit("%s i32.const %d i16x8.splat i16x8.mul i32.const 63 i16x8.splat i16x8.add i32.const 7 i16x8.shr_s %s" % (
                get(t("f6a")), k, setl(t(nm))))
        clip("%s %s i16x8.add" % (get(w["p2"]), get(t("f6a3"))), t("f6p2"))
        clip("%s %s i16x8.add" % (get(w["p1"]), get(t("f6a2"))), t("f6p1"))
        clip("%s %s i16x8.add" % (get(w["p0"]), get(t("f6a1"))), t("f6p0"))
        clip("%s %s i16x8.sub" % (get(w["q0"]), get(t("f6a1"))), t("f6q0"))
        clip("%s %s i16x8.sub" % (get(w["q1"]), get(t("f6a2"))), t("f6q1"))
        clip("%s %s i16x8.sub" % (get(w["q2"]), get(t("f6a3"))), t("f6q2"))
        # Lane masks: hm = mask & hev, nh = mask & !hev, ne = nh & edge.
        f.emit("%s %s v128.and %s" % (get(t("mask")), get(t("hev")), setl(t("hm"))))
        f.emit("%s %s v128.andnot %s" % (get(t("mask")), get(t("hev")), setl(t("nh"))))
        f.emit("%s %s v128.and %s" % (get(t("nh")), get(EDGE), setl(t("ne"))))
        # Select per lane.
        def sel(a, b, c):  # c ? a : b
            return "%s %s %s v128.bitselect" % (a, b, c)
        res = {}
        # p2 / q2: only filter6
        res["p2"] = sel(get(t("f6p2")), get(w["p2"]), get(t("ne")))
        res["q2"] = sel(get(t("f6q2")), get(w["q2"]), get(t("ne")))
        # p1 / q1: filter6 or filter4 when !hev
        res["p1"] = sel(sel(get(t("f6p1")), get(t("f4p1")), get(EDGE)), get(w["p1"]), get(t("nh")))
        res["q1"] = sel(sel(get(t("f6q1")), get(t("f4q1")), get(EDGE)), get(w["q1"]), get(t("nh")))
        # p0 / q0: filter2 when hev, else filter6 / filter4
        res["p0"] = sel(get(t("f2p0")),
                        sel(sel(get(t("f6p0")), get(t("f4p0")), get(EDGE)), get(w["p0"]), get(t("nh"))),
                        get(t("hm")))
        res["q0"] = sel(get(t("f2q0")),
                        sel(sel(get(t("f6q0")), get(t("f4q0")), get(EDGE)), get(w["q0"]), get(t("nh"))),
                        get(t("hm")))
        for nm, e in res.items():
            f.emit(e + " " + setl(t("r" + nm)))
        halves[half] = t
    outs = {}
    for nm in ("p2", "p1", "p0", "q0", "q1", "q2"):
        o = f.lv("n" + nm)
        f.emit("%s %s i8x16.narrow_i16x8_u %s" % (
            get(halves["lo"]("r" + nm)), get(halves["hi"]("r" + nm)), setl(o)))
        outs[nm] = o
    return outs


def consts_setup(f, t2, it, hev, edge):
    T2 = f.lv("T2")
    IT = f.lv("IT")
    HEV = f.lv("HEV")
    EDGE = f.lv("EDGE")
    f.emit("%s i16x8.splat %s" % (get(t2), setl(T2)))
    f.emit("%s i16x8.splat %s" % (get(it), setl(IT)))
    f.emit("%s i16x8.splat %s" % (get(hev), setl(HEV)))
    f.emit("i32.const 0 %s i32.sub i16x8.splat %s" % (get(edge), setl(EDGE)))
    return (T2, IT, HEV, EDGE)


NAMES = ("p3", "p2", "p1", "p0", "q0", "q1", "q2", "q3")
OUTS = ("p2", "p1", "p0", "q0", "q1", "q2")


def kernel_v16():
    """Horizontal edge, 16 contiguous pixels. Params: p, q0, stride, t2,
    it, hev, edge."""
    params = ["p", "q0", "stride", "t2", "it", "hev", "edge"]
    f = Fn(len(params))
    consts = consts_setup(f, "t2", "it", "hev", "edge")
    base = f.li("base")
    f.emit("%s %s i32.add %s" % (get("p"), get("q0"), setl(base)))
    P = []
    for k, nm in zip(range(-4, 4), NAMES):
        v = f.lv("in_" + nm)
        f.emit("%s %s i32.const %d i32.mul i32.add v128.load %s" % (get(base), get("stride"), k, setl(v)))
        P.append(v)
    outs = filter_core(f, P, consts)
    for k, nm in zip(range(-3, 3), OUTS):
        f.emit("%s %s i32.const %d i32.mul i32.add %s v128.store" % (get(base), get("stride"), k, get(outs[nm])))
    return params, f


def kernel_v8x2():
    """Horizontal edge, 8 pixels of U (lanes 0-7) and V (8-15)."""
    params = ["u", "v", "q0", "stride", "t2", "it", "hev", "edge"]
    f = Fn(len(params))
    consts = consts_setup(f, "t2", "it", "hev", "edge")
    ub = f.li("ub")
    vb = f.li("vb")
    f.emit("%s %s i32.add %s" % (get("u"), get("q0"), setl(ub)))
    f.emit("%s %s i32.add %s" % (get("v"), get("q0"), setl(vb)))
    P = []
    for k, nm in zip(range(-4, 4), NAMES):
        v = f.lv("in_" + nm)
        f.emit("%s %s i32.const %d i32.mul i32.add v128.load64_zero %s" % (get(ub), get("stride"), k, setl(v)))
        f.emit("%s %s i32.const %d i32.mul i32.add %s v128.load64_lane 1 %s" % (get(vb), get("stride"), k, get(v), setl(v)))
        P.append(v)
    outs = filter_core(f, P, consts)
    for k, nm in zip(range(-3, 3), OUTS):
        f.emit("%s %s i32.const %d i32.mul i32.add %s v128.store64_lane 0" % (get(ub), get("stride"), k, get(outs[nm])))
        f.emit("%s %s i32.const %d i32.mul i32.add %s v128.store64_lane 1" % (get(vb), get("stride"), k, get(outs[nm])))
    return params, f


def kernel_h(chroma):
    """Vertical edge: 16 rows (luma) or 8 rows of U + 8 of V, 8 bytes each
    around the edge (q0 at column offset 0)."""
    params = (["u", "v"] if chroma else ["p"]) + ["q0", "stride", "t2", "it", "hev", "edge"]
    f = Fn(len(params))
    consts = consts_setup(f, "t2", "it", "hev", "edge")
    addrs = []
    for r in range(16):
        a = f.li("a%d" % r)
        if chroma:
            src = "u" if r < 8 else "v"
            rr = r % 8
        else:
            src = "p"
            rr = r
        f.emit("%s %s i32.add %s i32.const %d i32.mul i32.add i32.const 4 i32.sub %s" % (
            get(src), get("q0"), get("stride"), rr, setl(a)))
        addrs.append(a)
    rows = []
    tags = []
    for r in range(16):
        v = f.lv("row%d" % r)
        f.emit("%s v128.load64_zero %s" % (get(addrs[r]), setl(v)))
        rows.append(v)
        tags.append([(r, c) for c in range(8)] + [(None, None)] * 8)
    cols = transpose_rows_to_cols(f, rows, tags)
    outs = filter_core(f, cols, consts)
    newcols = [cols[0], outs["p2"], outs["p1"], outs["p0"], outs["q0"], outs["q1"], outs["q2"], cols[7]]
    where = transpose_cols_to_rows(f, newcols)
    for name, lane, row in where:
        f.emit("%s %s v128.store64_lane %d" % (get(addrs[row]), get(name), lane))
    return params, f


def wrap(name, params, f, doc, types):
    wat = f.finish(params)
    lines = []
    line = ""
    for tok in wat.split(" "):
        if len(line) + len(tok) + 1 > 110:
            lines.append(line)
            line = tok
        else:
            line = (line + " " + tok) if line else tok
    lines.append(line)
    borrow = [p for p, t in zip(params, types) if t == "FixedArray[Byte]"]
    sig = ",\n".join("  %s : %s" % (p, t) for p, t in zip(params, types))
    out = "///|\n" + "".join("/// %s\n" % d for d in doc)
    out += "#borrow(%s)\nfn %s(\n%s,\n) -> Unit =\n" % (", ".join(borrow), name, sig)
    out += "\n".join("  #|" + l for l in lines) + "\n"
    return out


def main(path):
    B = "FixedArray[Byte]"
    I = "Int"
    parts = []
    parts.append("""// VP8 loop filter — wasm SIMD version. Generated by
// `python3 tools/gen_vp8_lf_simd.py src/webp_vp8_filter_simd.mbt`.
//
// One kernel filters 16 lanes with the scalar arithmetic widened to i16x8,
// selecting the hev (2-tap), inner (4-tap) or edge (6-tap) result per lane,
// so the output is identical to the scalar filters. Horizontal edges load
// 16 contiguous pixels; vertical edges load 16 rows of 8 bytes and transpose
// them with shuffles. Chroma packs 8 lanes of U and 8 of V. The simple
// filter is the same kernel with the interior threshold at 255 and the hev
// threshold at -1 (every lane then takes the 2-tap filter).

///|
/// Normal filter on a luma edge: `vertical` filters across the horizontal
/// edge at row offset `i` (16 columns), otherwise across the vertical edge
/// at column offset `i` (16 rows).
fn vp8_lf_luma(
  p : FixedArray[Byte],
  i : Int,
  vertical : Bool,
  stride : Int,
  thresh : Int,
  ithresh : Int,
  hev : Int,
  edge : Bool,
) -> Unit {
  let e = if edge { 1 } else { 0 }
  if vertical {
    vp8_lf_v16_v128(p, i, stride, 2 * thresh + 1, ithresh, hev, e)
  } else {
    vp8_lf_h16_v128(p, i, stride, 2 * thresh + 1, ithresh, hev, e)
  }
}

///|
/// Normal filter on the U and V edges at offset `i` (8 pixels each).
fn vp8_lf_chroma(
  u : FixedArray[Byte],
  v : FixedArray[Byte],
  i : Int,
  vertical : Bool,
  stride : Int,
  thresh : Int,
  ithresh : Int,
  hev : Int,
  edge : Bool,
) -> Unit {
  let e = if edge { 1 } else { 0 }
  if vertical {
    vp8_lf_v8x2_v128(u, v, i, stride, 2 * thresh + 1, ithresh, hev, e)
  } else {
    vp8_lf_h8x2_v128(u, v, i, stride, 2 * thresh + 1, ithresh, hev, e)
  }
}

///|
/// Simple filter on a luma edge (2-tap where `NeedsFilter` holds).
fn vp8_lf_simple(
  p : FixedArray[Byte],
  i : Int,
  vertical : Bool,
  stride : Int,
  thresh : Int,
) -> Unit {
  if vertical {
    vp8_lf_v16_v128(p, i, stride, 2 * thresh + 1, 255, -1, 0)
  } else {
    vp8_lf_h16_v128(p, i, stride, 2 * thresh + 1, 255, -1, 0)
  }
}

""")
    params, f = kernel_v16()
    parts.append(wrap("vp8_lf_v16_v128", params, f, ["Params: p, q0 (offset of the q0 row), stride, t2, it, hev, edge."], [B, I, I, I, I, I, I]))
    params, f = kernel_v8x2()
    parts.append("\n" + wrap("vp8_lf_v8x2_v128", params, f, ["Params: u, v, q0, stride, t2, it, hev, edge."], [B, B, I, I, I, I, I, I]))
    params, f = kernel_h(False)
    parts.append("\n" + wrap("vp8_lf_h16_v128", params, f, ["Params: p, q0 (offset of the q0 column in row 0), stride, t2, it, hev, edge."], [B, I, I, I, I, I, I]))
    params, f = kernel_h(True)
    parts.append("\n" + wrap("vp8_lf_h8x2_v128", params, f, ["Params: u, v, q0, stride, t2, it, hev, edge."], [B, B, I, I, I, I, I, I]))
    open(path, "w").write("".join(parts))


if __name__ == "__main__":
    main(sys.argv[1])
