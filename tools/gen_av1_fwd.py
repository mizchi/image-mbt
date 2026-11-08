"""Generate src/av1_fwd_gen.mbt: straight-line forward AV1 transforms.

The decoder's inverse DCT / ADST (spec 7.13.2) is a network of butterfly
rotations B, Hadamard steps H and permutations. Its matrix M has orthogonal
columns, so the forward transform is D^-1 M^T: the same network transposed
and run backwards (floating point, no rounding), then a per-output scale.

Usage: python3 tools/gen_av1_fwd.py src/av1_fwd_gen.mbt
"""
import math, sys

COS = [4096, 4095, 4091, 4085, 4076, 4065, 4052, 4036, 4017, 3996, 3973,
       3948, 3920, 3889, 3857, 3822, 3784, 3745, 3703, 3659, 3612, 3564,
       3513, 3461, 3406, 3349, 3290, 3229, 3166, 3102, 3035, 2967, 2896,
       2824, 2751, 2675, 2598, 2520, 2440, 2359, 2276, 2191, 2106, 2019,
       1931, 1842, 1751, 1660, 1567, 1474, 1380, 1285, 1189, 1092, 995, 897,
       799, 700, 601, 501, 401, 301, 201, 101, 0]

def cosf(a):
    """Exact cos(a * pi / 128): the integer tables round it to 1/4096."""
    return math.cos(a * math.pi / 128.0)

def cos128(a):
    a &= 255
    if a <= 64: return COS[a]
    if a <= 128: return -COS[128 - a]
    if a <= 192: return -COS[a - 128]
    return COS[256 - a]

def brev(bits, x):
    return sum(((x >> i) & 1) << (bits - 1 - i) for i in range(bits))

class Rec:
    def __init__(self): self.ops = []
    def B(self, a, b, angle, flip): self.ops.append(("B", a, b, angle, flip))
    def H(self, a, b, flip):
        if flip: a, b = b, a
        self.ops.append(("H", a, b))
    def P(self, idx, sign): self.ops.append(("P", idx, sign))

def inv_dct(r, n):
    L = 1 << n
    r.P([brev(n, i) for i in range(L)], [1] * L)
    if n == 6:
        for i in range(16): r.B(32 + i, 63 - i, 63 - 4 * brev(4, i), False)
    if n >= 5:
        for i in range(8): r.B(16 + i, 31 - i, 6 + (brev(3, 7 - i) << 3), False)
    if n == 6:
        for i in range(16): r.H(32 + i * 2, 33 + i * 2, i & 1)
    if n >= 4:
        for i in range(4): r.B(8 + i, 15 - i, 12 + (brev(2, 3 - i) << 4), False)
    if n >= 5:
        for i in range(8): r.H(16 + 2 * i, 17 + 2 * i, i & 1)
    if n == 6:
        for i in range(4):
            for j in range(2): r.B(62 - i * 4 - j, 33 + i * 4 + j, 60 - 16 * brev(2, i) + 64 * j, True)
    if n >= 3:
        for i in range(2): r.B(4 + i, 7 - i, 56 - 32 * i, False)
    if n >= 4:
        for i in range(4): r.H(8 + 2 * i, 9 + 2 * i, i & 1)
    if n >= 5:
        for i in range(2):
            for j in range(2): r.B(30 - 4 * i - j, 17 + 4 * i + j, 24 + (j << 6) + ((1 - i) << 5), True)
    if n == 6:
        for i in range(8):
            for j in range(2): r.H(32 + i * 4 + j, 35 + i * 4 - j, i & 1)
    for i in range(2): r.B(2 * i, 2 * i + 1, 32 + 16 * i, i == 0)
    if n >= 3:
        for i in range(2): r.H(4 + 2 * i, 5 + 2 * i, i == 1)
    if n >= 4:
        for i in range(2): r.B(14 - i, 9 + i, 48 + 64 * i, True)
    if n >= 5:
        for i in range(4):
            for j in range(2): r.H(16 + 4 * i + j, 19 + 4 * i - j, i & 1)
    if n == 6:
        for i in range(2):
            for j in range(4): r.B(61 - i * 8 - j, 34 + i * 8 + j, 56 - i * 32 + (j >> 1) * 64, True)
    for i in range(2): r.H(i, 3 - i, False)
    if n >= 3: r.B(6, 5, 32, True)
    if n >= 4:
        for i in range(2):
            for j in range(2): r.H(8 + 4 * i + j, 11 + 4 * i - j, i == 1)
    if n >= 5:
        for i in range(4): r.B(29 - i, 18 + i, 48 + (i >> 1) * 64, True)
    if n == 6:
        for i in range(4):
            for j in range(4): r.H(32 + 8 * i + j, 39 + 8 * i - j, i & 1)
    if n >= 3:
        for i in range(4): r.H(i, 7 - i, False)
    if n >= 4:
        for i in range(2): r.B(13 - i, 10 + i, 32, True)
    if n >= 5:
        for i in range(2):
            for j in range(4): r.H(16 + i * 8 + j, 23 + i * 8 - j, i == 1)
    if n == 6:
        for i in range(8): r.B(59 - i, 36 + i, 48 if i < 4 else 112, True)
    if n >= 4:
        for i in range(8): r.H(i, 15 - i, False)
    if n >= 5:
        for i in range(4): r.B(27 - i, 20 + i, 32, True)
    if n == 6:
        for i in range(8):
            r.H(32 + i, 47 - i, False)
            r.H(48 + i, 63 - i, True)
    if n >= 5:
        for i in range(16): r.H(i, 31 - i, False)
    if n == 6:
        for i in range(8): r.B(55 - i, 40 + i, 32, True)
    if n == 6:
        for i in range(32): r.H(i, 63 - i, False)

def adst_in(r, n):
    n0 = 1 << n
    r.P([(i - 1) if (i & 1) else (n0 - i - 1) for i in range(n0)], [1] * n0)

def adst_out(r, n):
    n0 = 1 << n
    idx = []; sign = []
    for i in range(n0):
        a = (i >> 3) & 1
        b = ((i >> 2) & 1) ^ ((i >> 3) & 1)
        c = ((i >> 1) & 1) ^ ((i >> 2) & 1)
        d = (i & 1) ^ ((i >> 1) & 1)
        idx.append(((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n))
        sign.append(-1 if (i & 1) else 1)
    r.P(idx, sign)

def inv_adst8(r):
    adst_in(r, 3)
    for i in range(4): r.B(2 * i, 2 * i + 1, 60 - 16 * i, True)
    for i in range(4): r.H(i, 4 + i, False)
    for i in range(2): r.B(4 + 3 * i, 5 + i, 48 - 32 * i, True)
    for i in range(2):
        for j in range(2): r.H(4 * j + i, 2 + 4 * j + i, False)
    for i in range(2): r.B(2 + 4 * i, 3 + 4 * i, 32, True)
    adst_out(r, 3)

def inv_adst16(r):
    adst_in(r, 4)
    for i in range(8): r.B(2 * i, 2 * i + 1, 62 - 8 * i, True)
    for i in range(8): r.H(i, 8 + i, False)
    for i in range(2):
        r.B(8 + 2 * i, 9 + 2 * i, 56 - 32 * i, True)
        r.B(13 + 2 * i, 12 + 2 * i, 8 + 32 * i, True)
    for i in range(4):
        for j in range(2): r.H(8 * j + i, 4 + 8 * j + i, False)
    for i in range(2):
        for j in range(2): r.B(4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, True)
    for i in range(2):
        for j in range(4): r.H(4 * j + i, 2 + 4 * j + i, False)
    for i in range(4): r.B(2 + 4 * i, 3 + 4 * i, 32, True)
    adst_out(r, 4)

def apply(ops, v):
    """Floating point inverse network (to measure column norms)."""
    v = list(v)
    for op in ops:
        if op[0] == "B":
            _, a, b, ang, flip = op
            c = cosf(ang); s = cosf(ang - 64)
            x = v[a] * c - v[b] * s; y = v[a] * s + v[b] * c
            v[a], v[b] = (y, x) if flip else (x, y)
        elif op[0] == "H":
            _, a, b = op
            v[a], v[b] = v[a] + v[b], v[a] - v[b]
        else:
            _, idx, sign = op
            v = [sign[k] * v[idx[k]] for k in range(len(v))]
    return v

def gen_fwd(name, ops, L, out):
    # Column norms of M -> output scales.
    cols = [apply(ops, [1.0 if i == k else 0.0 for i in range(L)]) for k in range(L)]
    for p in range(L):
        for q in range(p + 1, L):
            dot = sum(cols[p][i] * cols[q][i] for i in range(L))
            assert abs(dot) < 1e-9 * L, (name, p, q, dot)
    scale = [1.0 / sum(x * x for x in col) for col in cols]
    # Transposed network, backwards, as SSA on local variables.
    lines = []
    cnt = [0]
    def fresh():
        cnt[0] += 1
        return "v%d" % cnt[0]
    # cur[i]: (variable, sign) holding y[i]
    cur = []
    for i in range(L):
        v = fresh(); lines.append("  let %s = x[%d]" % (v, i)); cur.append((v, 1))
    def expr(e):
        v, s = e
        return v if s == 1 else "-" + v
    for op in reversed(ops):
        if op[0] == "B":
            _, a, b, ang, flip = op
            c = cosf(ang); s = cosf(ang - 64)
            p, q = (cur[b], cur[a]) if flip else (cur[a], cur[b])
            na, nb = fresh(), fresh()
            def term(coef, e):
                v, sg = e
                k = coef * sg
                if abs(k) < 1e-15: return None
                return "%r * %s" % (k, v)
            ta = [t for t in (term(c, p), term(s, q)) if t]
            tb = [t for t in (term(c, q), term(-s, p)) if t]
            lines.append("  let %s = %s" % (na, " + ".join(ta) if ta else "0.0"))
            lines.append("  let %s = %s" % (nb, " + ".join(tb) if tb else "0.0"))
            cur[a] = (na, 1); cur[b] = (nb, 1)
        elif op[0] == "H":
            _, a, b = op
            p, q = cur[a], cur[b]
            na, nb = fresh(), fresh()
            def lin(e1, s2, e2):
                v1, g1 = e1; v2, g2 = e2
                g2 *= s2
                a1 = v1 if g1 == 1 else "-" + v1
                return "%s %s %s" % (a1, "+" if g2 == 1 else "-", v2)
            lines.append("  let %s = %s" % (na, lin(p, 1, q)))
            lines.append("  let %s = %s" % (nb, lin(p, -1, q)))
            cur[a] = (na, 1); cur[b] = (nb, 1)
        else:
            _, idx, sign = op
            new = [None] * L
            for k in range(L):
                v, g = cur[k]
                new[idx[k]] = (v, g * sign[k])
            cur = new
    for k in range(L):
        v, g = cur[k]
        lines.append("  y[%d] = %s%s * %r" % (k, "" if g == 1 else "-", v, scale[k]))
    out.write("\n///|\nfn %s(x : FixedArray[Double], y : FixedArray[Double]) -> Unit {\n" % name)
    out.write("\n".join(lines) + "\n}\n")

with open(sys.argv[1], "w") as out:
    out.write("// Forward AV1 transforms: the decoder's inverse DCT / ADST networks\n")
    out.write("// transposed (floating point), with per-output scales.\n")
    out.write("// Generated by tools/gen_av1_fwd.py; do not edit.\n")
    for n in range(2, 7):
        r = Rec(); inv_dct(r, n)
        gen_fwd("av1_fdct%d" % (1 << n), r.ops, 1 << n, out)
    r = Rec(); inv_adst8(r); gen_fwd("av1_fadst8", r.ops, 8, out)
    r = Rec(); inv_adst16(r); gen_fwd("av1_fadst16", r.ops, 16, out)
print("ok")
