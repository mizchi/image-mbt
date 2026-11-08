// AV1 transforms. The inverse transforms follow the spec exactly (the
// encoder's reconstruction must match the decoder's); the forward
// transforms are the (floating point) inverses of those matrices.

///|
fn av1_round2(x : Int32, n : Int32) -> Int32 {
  if n == 0 {
    x
  } else {
    (x + (1 << (n - 1))) >> n
  }
}

///|
fn av1_cos128(angle : Int32) -> Int32 {
  av1_cos_table[angle & 255]
}

///|
let av1_cos_table : FixedArray[Int32] = FixedArray::makei(256, fn(a) {
  av1_cos128_slow(a)
})

///|
fn av1_cos128_slow(angle : Int32) -> Int32 {
  let a = angle & 255
  if a <= 64 {
    av1_cos128_lut[a]
  } else if a <= 128 {
    -av1_cos128_lut[128 - a]
  } else if a <= 192 {
    -av1_cos128_lut[a - 128]
  } else {
    av1_cos128_lut[256 - a]
  }
}

///|
fn av1_brev(bits : Int32, x : Int32) -> Int32 {
  let mut t = 0
  for i in 0..<bits {
    t = t | (((x >> i) & 1) << (bits - 1 - i))
  }
  t
}

///|
/// Butterfly rotation B( a, b, angle, flip ).
fn av1_b(
  t : FixedArray[Int32],
  a : Int32,
  b : Int32,
  angle : Int32,
  flip : Bool,
) -> Unit {
  let c = av1_cos128(angle)
  let s = av1_cos128(angle - 64)
  let x = t[a] * c - t[b] * s
  let y = t[a] * s + t[b] * c
  let xa = av1_round2(x, 12)
  let yb = av1_round2(y, 12)
  if flip {
    t[a] = yb
    t[b] = xa
  } else {
    t[a] = xa
    t[b] = yb
  }
}

///|
/// Hadamard rotation H( a, b, flip, r ).
fn av1_h(
  t : FixedArray[Int32],
  a0 : Int32,
  b0 : Int32,
  flip : Bool,
  r : Int32,
) -> Unit {
  let (a, b) = if flip { (b0, a0) } else { (a0, b0) }
  let x = t[a]
  let y = t[b]
  let lo = -(1 << (r - 1))
  let hi = (1 << (r - 1)) - 1
  let s = x + y
  let d = x - y
  t[a] = if s < lo { lo } else if s > hi { hi } else { s }
  t[b] = if d < lo { lo } else if d > hi { hi } else { d }
}

///|
/// In-place inverse DCT of length 2^n.
fn av1_inv_dct(t : FixedArray[Int32], n : Int32, r : Int32) -> Unit {
  let len = 1 << n
  let copy = av1_perm_scratch
  for i in 0..<len {
    copy[i] = t[i]
  }
  let perm = av1_brev_table(n)
  for i in 0..<len {
    t[i] = copy[perm[i]]
  }
  if n == 6 {
    for i in 0..<16 {
      av1_b(t, 32 + i, 63 - i, 63 - 4 * av1_brev(4, i), false)
    }
  }
  if n >= 5 {
    for i in 0..<8 {
      av1_b(t, 16 + i, 31 - i, 6 + (av1_brev(3, 7 - i) << 3), false)
    }
  }
  if n == 6 {
    for i in 0..<16 {
      av1_h(t, 32 + i * 2, 33 + i * 2, (i & 1) == 1, r)
    }
  }
  if n >= 4 {
    for i in 0..<4 {
      av1_b(t, 8 + i, 15 - i, 12 + (av1_brev(2, 3 - i) << 4), false)
    }
  }
  if n >= 5 {
    for i in 0..<8 {
      av1_h(t, 16 + 2 * i, 17 + 2 * i, (i & 1) == 1, r)
    }
  }
  if n == 6 {
    for i in 0..<4 {
      for j in 0..<2 {
        av1_b(
          t,
          62 - i * 4 - j,
          33 + i * 4 + j,
          60 - 16 * av1_brev(2, i) + 64 * j,
          true,
        )
      }
    }
  }
  if n >= 3 {
    for i in 0..<2 {
      av1_b(t, 4 + i, 7 - i, 56 - 32 * i, false)
    }
  }
  if n >= 4 {
    for i in 0..<4 {
      av1_h(t, 8 + 2 * i, 9 + 2 * i, (i & 1) == 1, r)
    }
  }
  if n >= 5 {
    for i in 0..<2 {
      for j in 0..<2 {
        av1_b(
          t,
          30 - 4 * i - j,
          17 + 4 * i + j,
          24 + (j << 6) + ((1 - i) << 5),
          true,
        )
      }
    }
  }
  if n == 6 {
    for i in 0..<8 {
      for j in 0..<2 {
        av1_h(t, 32 + i * 4 + j, 35 + i * 4 - j, (i & 1) == 1, r)
      }
    }
  }
  for i in 0..<2 {
    av1_b(t, 2 * i, 2 * i + 1, 32 + 16 * i, i == 0)
  }
  if n >= 3 {
    for i in 0..<2 {
      av1_h(t, 4 + 2 * i, 5 + 2 * i, i == 1, r)
    }
  }
  if n >= 4 {
    for i in 0..<2 {
      av1_b(t, 14 - i, 9 + i, 48 + 64 * i, true)
    }
  }
  if n >= 5 {
    for i in 0..<4 {
      for j in 0..<2 {
        av1_h(t, 16 + 4 * i + j, 19 + 4 * i - j, (i & 1) == 1, r)
      }
    }
  }
  if n == 6 {
    for i in 0..<2 {
      for j in 0..<4 {
        av1_b(
          t,
          61 - i * 8 - j,
          34 + i * 8 + j,
          56 - i * 32 + (j >> 1) * 64,
          true,
        )
      }
    }
  }
  for i in 0..<2 {
    av1_h(t, i, 3 - i, false, r)
  }
  if n >= 3 {
    av1_b(t, 6, 5, 32, true)
  }
  if n >= 4 {
    for i in 0..<2 {
      for j in 0..<2 {
        av1_h(t, 8 + 4 * i + j, 11 + 4 * i - j, i == 1, r)
      }
    }
  }
  if n >= 5 {
    for i in 0..<4 {
      av1_b(t, 29 - i, 18 + i, 48 + (i >> 1) * 64, true)
    }
  }
  if n == 6 {
    for i in 0..<4 {
      for j in 0..<4 {
        av1_h(t, 32 + 8 * i + j, 39 + 8 * i - j, (i & 1) == 1, r)
      }
    }
  }
  if n >= 3 {
    for i in 0..<4 {
      av1_h(t, i, 7 - i, false, r)
    }
  }
  if n >= 4 {
    for i in 0..<2 {
      av1_b(t, 13 - i, 10 + i, 32, true)
    }
  }
  if n >= 5 {
    for i in 0..<2 {
      for j in 0..<4 {
        av1_h(t, 16 + i * 8 + j, 23 + i * 8 - j, i == 1, r)
      }
    }
  }
  if n == 6 {
    for i in 0..<8 {
      av1_b(t, 59 - i, 36 + i, if i < 4 { 48 } else { 112 }, true)
    }
  }
  if n >= 4 {
    for i in 0..<8 {
      av1_h(t, i, 15 - i, false, r)
    }
  }
  if n >= 5 {
    for i in 0..<4 {
      av1_b(t, 27 - i, 20 + i, 32, true)
    }
  }
  if n == 6 {
    for i in 0..<8 {
      av1_h(t, 32 + i, 47 - i, false, r)
      av1_h(t, 48 + i, 63 - i, true, r)
    }
  }
  if n >= 5 {
    for i in 0..<16 {
      av1_h(t, i, 31 - i, false, r)
    }
  }
  if n == 6 {
    for i in 0..<8 {
      av1_b(t, 55 - i, 40 + i, 32, true)
    }
  }
  if n == 6 {
    for i in 0..<32 {
      av1_h(t, i, 63 - i, false, r)
    }
  }
}

///|
fn av1_inv_adst4(t : FixedArray[Int32]) -> Unit {
  let sinpi1 = 1321
  let sinpi2 = 2482
  let sinpi3 = 3344
  let sinpi4 = 3803
  let mut s0 = sinpi1 * t[0]
  let mut s1 = sinpi2 * t[0]
  let mut s2 = sinpi3 * t[1]
  let mut s3 = sinpi4 * t[2]
  let s4 = sinpi1 * t[2]
  let s5 = sinpi2 * t[3]
  let s6 = sinpi4 * t[3]
  let a7 = t[0] - t[2]
  let b7 = a7 + t[3]
  s0 = s0 + s3
  s1 = s1 - s4
  s3 = s2
  s2 = sinpi3 * b7
  s0 = s0 + s5
  s1 = s1 - s6
  let x0 = s0 + s3
  let x1 = s1 + s3
  let x2 = s2
  let x3 = s0 + s1 - s3
  t[0] = av1_round2(x0, 12)
  t[1] = av1_round2(x1, 12)
  t[2] = av1_round2(x2, 12)
  t[3] = av1_round2(x3, 12)
}

///|
fn av1_adst_in_perm(t : FixedArray[Int32], n : Int32) -> Unit {
  let n0 = 1 << n
  let copy = av1_perm_scratch
  for i in 0..<n0 {
    copy[i] = t[i]
  }
  for i in 0..<n0 {
    let idx = if (i & 1) == 1 { i - 1 } else { n0 - i - 1 }
    t[i] = copy[idx]
  }
}

///|
fn av1_adst_out_perm(t : FixedArray[Int32], n : Int32) -> Unit {
  let n0 = 1 << n
  let copy = av1_perm_scratch
  for i in 0..<n0 {
    copy[i] = t[i]
  }
  for i in 0..<n0 {
    let a = (i >> 3) & 1
    let b = ((i >> 2) & 1) ^ ((i >> 3) & 1)
    let c = ((i >> 1) & 1) ^ ((i >> 2) & 1)
    let d = (i & 1) ^ ((i >> 1) & 1)
    let idx = ((d << 3) | (c << 2) | (b << 1) | a) >> (4 - n)
    t[i] = if (i & 1) == 1 { -copy[idx] } else { copy[idx] }
  }
}

///|
fn av1_inv_adst8(t : FixedArray[Int32], r : Int32) -> Unit {
  av1_adst_in_perm(t, 3)
  for i in 0..<4 {
    av1_b(t, 2 * i, 2 * i + 1, 60 - 16 * i, true)
  }
  for i in 0..<4 {
    av1_h(t, i, 4 + i, false, r)
  }
  for i in 0..<2 {
    av1_b(t, 4 + 3 * i, 5 + i, 48 - 32 * i, true)
  }
  for i in 0..<2 {
    for j in 0..<2 {
      av1_h(t, 4 * j + i, 2 + 4 * j + i, false, r)
    }
  }
  for i in 0..<2 {
    av1_b(t, 2 + 4 * i, 3 + 4 * i, 32, true)
  }
  av1_adst_out_perm(t, 3)
}

///|
fn av1_inv_adst16(t : FixedArray[Int32], r : Int32) -> Unit {
  av1_adst_in_perm(t, 4)
  for i in 0..<8 {
    av1_b(t, 2 * i, 2 * i + 1, 62 - 8 * i, true)
  }
  for i in 0..<8 {
    av1_h(t, i, 8 + i, false, r)
  }
  for i in 0..<2 {
    av1_b(t, 8 + 2 * i, 9 + 2 * i, 56 - 32 * i, true)
    av1_b(t, 13 + 2 * i, 12 + 2 * i, 8 + 32 * i, true)
  }
  for i in 0..<4 {
    for j in 0..<2 {
      av1_h(t, 8 * j + i, 4 + 8 * j + i, false, r)
    }
  }
  for i in 0..<2 {
    for j in 0..<2 {
      av1_b(t, 4 + 8 * j + 3 * i, 5 + 8 * j + i, 48 - 32 * i, true)
    }
  }
  for i in 0..<2 {
    for j in 0..<4 {
      av1_h(t, 4 * j + i, 2 + 4 * j + i, false, r)
    }
  }
  for i in 0..<4 {
    av1_b(t, 2 + 4 * i, 3 + 4 * i, 32, true)
  }
  av1_adst_out_perm(t, 4)
}

///|
fn av1_inv_identity(t : FixedArray[Int32], n : Int32) -> Unit {
  let len = 1 << n
  for i in 0..<len {
    t[i] = match n {
      2 => av1_round2(t[i] * 5793, 12)
      3 => t[i] * 2
      4 => av1_round2(t[i] * 11586, 12)
      _ => t[i] * 4
    }
  }
}

///|
/// 1-D transform kinds: 0 DCT, 1 ADST, 2 identity (flips are not used).
fn av1_inv_1d(
  t : FixedArray[Int32],
  kind : Int32,
  n : Int32,
  r : Int32,
) -> Unit {
  match kind {
    0 => av1_inv_dct(t, n, r)
    1 =>
      if n == 2 {
        av1_inv_adst4(t)
      } else if n == 3 {
        av1_inv_adst8(t, r)
      } else {
        av1_inv_adst16(t, r)
      }
    _ => av1_inv_identity(t, n)
  }
}

///|
/// Row (horizontal) and column (vertical) 1-D kinds of a transform type.
fn av1_tx_row_kind(tx_type : Int32) -> Int32 {
  match tx_type {
    0 | 1 | 4 | 11 => 0 // DCT_DCT, ADST_DCT, FLIPADST_DCT, H_DCT
    2 | 3 | 5 | 6 | 7 | 8 | 13 | 15 => 1
    _ => 2
  }
}

///|
fn av1_tx_col_kind(tx_type : Int32) -> Int32 {
  match tx_type {
    0 | 2 | 5 | 10 => 0 // DCT_DCT, DCT_ADST, DCT_FLIPADST, V_DCT
    1 | 3 | 4 | 6 | 7 | 8 | 12 | 14 => 1
    _ => 2
  }
}

///|
/// 2-D inverse transform (8-bit, not lossless): `dq` holds the dequantized
/// coefficients (h x w, row-major); the residual goes to `res` (h x w).
fn av1_inverse_2d(
  dq : FixedArray[Int32],
  tx_size : Int32,
  tx_type : Int32,
  res : FixedArray[Int32],
  rows~ : Int32 = 64,
) -> Unit {
  let log2w = av1_tx_width_log2[tx_size]
  let log2h = av1_tx_height_log2[tx_size]
  let w = 1 << log2w
  let h = 1 << log2h
  let row_shift = av1_transform_row_shift[tx_size]
  let rk = av1_tx_row_kind(tx_type)
  let ck = av1_tx_col_kind(tx_type)
  let rect = log2w - log2h == 1 || log2h - log2w == 1
  let t = av1_inv_line
  let lo = -(1 << 15)
  let hi = (1 << 15) - 1
  for i in 0..<h {
    if i >= 32 || i >= rows {
      // Rows past the last non-zero one (and past 32) are zero, and a zero
      // row transforms to zero for every kind.
      for j in 0..<w {
        res[i * w + j] = 0
      }
      continue
    }
    for j in 0..<w {
      t[j] = if j < 32 { dq[i * w + j] } else { 0 }
    }
    if rect {
      for j in 0..<w {
        t[j] = av1_round2(t[j] * 2896, 12)
      }
    }
    av1_inv_1d(t, rk, log2w, 16)
    for j in 0..<w {
      let v = av1_round2(t[j], row_shift)
      res[i * w + j] = if v < lo { lo } else if v > hi { hi } else { v }
    }
  }
  for j in 0..<w {
    for i in 0..<h {
      t[i] = res[i * w + j]
    }
    av1_inv_1d(t, ck, log2h, 16)
    for i in 0..<h {
      res[i * w + j] = av1_round2(t[i], 4)
    }
  }
}

///|
/// Forward 1-D matrices (inverse of the integer inverse transform's matrix),
/// cached per kind and size: index kind * 8 + n.
let av1_fwd_mats : Array[FixedArray[Double]?] = Array::make(24, None)

///|
fn av1_fwd_matrix(kind : Int32, n : Int32) -> FixedArray[Double] {
  match av1_fwd_mats[kind * 8 + n] {
    Some(m) => m
    None => {
      let len = 1 << n
      // Columns of the inverse matrix from scaled impulses.
      let amp = 1 << 10
      let inv = FixedArray::make(len * len, 0.0)
      let t = FixedArray::make(64, 0)
      for k in 0..<len {
        for i in 0..<len {
          t[i] = if i == k { amp } else { 0 }
        }
        av1_inv_1d(t, kind, n, 20)
        for i in 0..<len {
          inv[i * len + k] = t[i].to_double() / amp.to_double()
        }
      }
      let m = av1_mat_inverse(inv, len)
      av1_fwd_mats[kind * 8 + n] = Some(m)
      m
    }
  }
}

///|
/// Gauss-Jordan inverse of a len x len matrix.
fn av1_mat_inverse(a : FixedArray[Double], len : Int32) -> FixedArray[Double] {
  let m = FixedArray::makei(len * len, fn(i) { a[i] })
  let r = FixedArray::makei(len * len, fn(i) {
    if i / len == i % len {
      1.0
    } else {
      0.0
    }
  })
  for c in 0..<len {
    let mut p = c
    for i in (c + 1)..<len {
      if m[i * len + c].abs() > m[p * len + c].abs() {
        p = i
      }
    }
    if p != c {
      for j in 0..<len {
        let x = m[c * len + j]
        m[c * len + j] = m[p * len + j]
        m[p * len + j] = x
        let y = r[c * len + j]
        r[c * len + j] = r[p * len + j]
        r[p * len + j] = y
      }
    }
    let d = m[c * len + c]
    for j in 0..<len {
      m[c * len + j] = m[c * len + j] / d
      r[c * len + j] = r[c * len + j] / d
    }
    for i in 0..<len {
      if i != c {
        let f = m[i * len + c]
        if f != 0.0 {
          for j in 0..<len {
            m[i * len + j] = m[i * len + j] - f * m[c * len + j]
            r[i * len + j] = r[i * len + j] - f * r[c * len + j]
          }
        }
      }
    }
  }
  r
}

///|
/// Forward 2-D transform of the residual `res` (h x w) into coefficients
/// `out` (h x w, row-major; only the top-left 32 x 32 is used for 64-point
/// sizes), in the domain of the decoder's dequantized coefficients.
fn av1_forward_2d(
  res : FixedArray[Int32],
  tx_size : Int32,
  tx_type : Int32,
  out : FixedArray[Double],
) -> Unit {
  let log2w = av1_tx_width_log2[tx_size]
  let log2h = av1_tx_height_log2[tx_size]
  let w = 1 << log2w
  let h = 1 << log2h
  let rk = av1_tx_row_kind(tx_type)
  let ck = av1_tx_col_kind(tx_type)
  let rect = log2w - log2h == 1 || log2h - log2w == 1
  // Undo the shifts and the rectangular scaling of the inverse.
  let mut scale = (1 << (av1_transform_row_shift[tx_size] + 4)).to_double()
  if rect {
    scale = scale * 4096.0 / 2896.0
  }
  let ow = if w > 32 { 32 } else { w }
  let oh = if h > 32 { 32 } else { h }
  let line = av1_fwd_line
  let lout = av1_fwd_lout
  // Rows into tmp (h x ow); while the row cache is on (the transform type
  // search of one block), each row kind is computed once.
  let cache = av1_row_cache
  let tmp = if cache.enabled { cache.bufs[rk] } else { av1_fwd_tmp }
  if !(cache.enabled && cache.valid[rk]) {
    for i in 0..<h {
      for j in 0..<w {
        line[j] = res[i * w + j].to_double()
      }
      av1_fwd_1d(rk, log2w, line, lout)
      for k in 0..<ow {
        tmp[i * ow + k] = lout[k]
      }
    }
    if cache.enabled {
      cache.valid[rk] = true
    }
  }
  for i in 0..<(h * w) {
    out[i] = 0.0
  }
  for j in 0..<ow {
    for i in 0..<h {
      line[i] = tmp[i * ow + j]
    }
    av1_fwd_1d(ck, log2h, line, lout)
    for k in 0..<oh {
      out[k * w + j] = lout[k] * scale
    }
  }
}

///|
let av1_fwd_line : FixedArray[Double] = FixedArray::make(64, 0.0)

///|
let av1_fwd_lout : FixedArray[Double] = FixedArray::make(64, 0.0)

///|
/// Forward 1-D transform (the inverse of the decoder's 1-D transform).
fn av1_fwd_1d(
  kind : Int32,
  n : Int32,
  x : FixedArray[Double],
  y : FixedArray[Double],
) -> Unit {
  let len = 1 << n
  if kind == 0 && n >= 4 {
    av1_dct2(x, 0, len, y, 0, av1_dct_scratch, 0)
    let sc = av1_dct_scale(n)
    for k in 0..<len {
      y[k] = y[k] * sc[k]
    }
  } else if kind == 2 {
    // Identity: invert the decoder's scaling.
    let f = match n {
      2 => 4096.0 / 5793.0
      3 => 0.5
      4 => 4096.0 / 11586.0
      _ => 0.25
    }
    for k in 0..<len {
      y[k] = x[k] * f
    }
  } else {
    let m = av1_fwd_matrix(kind, n)
    for k in 0..<len {
      let mut s = 0.0
      for j in 0..<len {
        s = s + m[k * len + j] * x[j]
      }
      y[k] = s
    }
  }
}

///|
let av1_dct_scratch : FixedArray[Double] = FixedArray::make(512, 0.0)

///|
/// Unnormalized DCT-II y[k] = sum x[n] cos(pi (2n + 1) k / 2N) of
/// x[off ..< off + len], by the even / odd decomposition.
fn av1_dct2(
  x : FixedArray[Double],
  off : Int32,
  len : Int32,
  y : FixedArray[Double],
  yoff : Int32,
  sc : FixedArray[Double],
  soff : Int32,
) -> Unit {
  if len == 1 {
    y[yoff] = x[off]
    return
  }
  let half = len >> 1
  for i in 0..<half {
    let a = x[off + i]
    let b = x[off + len - 1 - i]
    sc[soff + i] = a + b
    sc[soff + half + i] = a - b
  }
  // Even outputs: DCT of the sums (written after the odd values).
  av1_dct2(sc, soff, half, sc, soff + len, sc, soff + len + half)
  for k in 0..<half {
    y[yoff + 2 * k] = sc[soff + len + k]
  }
  // Odd outputs from the differences.
  let tab = av1_dct_odd(len)
  for k in 0..<half {
    let mut s = 0.0
    let to = k * half
    for i in 0..<half {
      s = s + tab[to + i] * sc[soff + half + i]
    }
    y[yoff + 2 * k + 1] = s
  }
}

///|
let av1_dct_odd_tabs : Array[FixedArray[Double]?] = Array::make(8, None)

///|
/// cos(pi (2i + 1)(2k + 1) / 2N) for k, i < N / 2.
fn av1_dct_odd(len : Int32) -> FixedArray[Double] {
  let n = av1_floor_log2(len)
  match av1_dct_odd_tabs[n] {
    Some(t) => t
    None => {
      let half = len >> 1
      let pi = 3.141592653589793
      let t = FixedArray::makei(half * half, fn(idx) {
        let k = idx / half
        let i = idx % half
        @math.cos(
          (2 * i + 1).to_double() *
          (2 * k + 1).to_double() *
          pi /
          (2 * len).to_double(),
        )
      })
      av1_dct_odd_tabs[n] = Some(t)
      t
    }
  }
}

///|
let av1_dct_scales : Array[FixedArray[Double]?] = Array::make(8, None)

///|
/// Per-output scale turning the unnormalized DCT-II into the inverse of the
/// decoder's DCT: the decoder computes x[n] = sum_k w[k] X[k] cos(..), with
/// w[k] measured from its integer implementation.
fn av1_dct_scale(n : Int32) -> FixedArray[Double] {
  match av1_dct_scales[n] {
    Some(s) => s
    None => {
      let len = 1 << n
      let pi = 3.141592653589793
      let amp = 1 << 10
      let t = FixedArray::make(64, 0)
      let sc = FixedArray::make(len, 0.0)
      for k in 0..<len {
        for i in 0..<len {
          t[i] = if i == k { amp } else { 0 }
        }
        av1_inv_dct(t, n, 20)
        // Least-squares fit of the column to cos(pi (2i + 1) k / 2N).
        let mut num = 0.0
        let mut den = 0.0
        for i in 0..<len {
          let c = @math.cos(
            (2 * i + 1).to_double() * k.to_double() * pi / (2 * len).to_double(),
          )
          num = num + t[i].to_double() / amp.to_double() * c
          den = den + c * c
        }
        let wk = num / den
        let e = if k == 0 { 0.5 } else { 1.0 }
        sc[k] = 2.0 / len.to_double() * e / wk
      }
      av1_dct_scales[n] = Some(sc)
      sc
    }
  }
}

///|
let av1_fwd_tmp : FixedArray[Double] = FixedArray::make(64 * 64, 0.0)

///|
let av1_perm_scratch : FixedArray[Int32] = FixedArray::make(64, 0)

///|
let av1_inv_line : FixedArray[Int32] = FixedArray::make(64, 0)

///|
/// Bit reversal permutations for n = 2..6.
let av1_brev_tables : FixedArray[FixedArray[Int32]] = FixedArray::makei(7, fn(
  n,
) {
  FixedArray::makei(1 << n, fn(i) { av1_brev(n, i) })
})

///|
fn av1_brev_table(n : Int32) -> FixedArray[Int32] {
  av1_brev_tables[n]
}

///|
/// Row transforms of the current residual, per 1-D kind.
priv struct Av1RowCache {
  mut enabled : Bool
  valid : FixedArray[Bool]
  bufs : FixedArray[FixedArray[Double]]
}

///|
let av1_row_cache : Av1RowCache = {
  enabled: false,
  valid: FixedArray::make(3, false),
  bufs: FixedArray::makei(3, fn(_) { FixedArray::make(64 * 32, 0.0) }),
}

///|
/// Reuse row transforms until av1_row_cache_off (the residual must not
/// change meanwhile).
fn av1_row_cache_on() -> Unit {
  av1_row_cache.enabled = true
  av1_row_cache.valid.fill(false)
}

///|
fn av1_row_cache_off() -> Unit {
  av1_row_cache.enabled = false
}
