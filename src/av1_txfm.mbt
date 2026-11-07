// AV1 transforms. The inverse transforms follow the spec exactly (the
// encoder's reconstruction must match the decoder's); the forward
// transforms are the (floating point) inverses of those matrices.

///|
fn av1_round2(x : Int, n : Int) -> Int {
  if n == 0 {
    x
  } else {
    (x + (1 << (n - 1))) >> n
  }
}

///|
fn av1_cos128(angle : Int) -> Int {
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
fn av1_brev(bits : Int, x : Int) -> Int {
  let mut t = 0
  for i in 0..<bits {
    t = t | (((x >> i) & 1) << (bits - 1 - i))
  }
  t
}

///|
/// Butterfly rotation B( a, b, angle, flip ).
fn av1_b(t : FixedArray[Int], a : Int, b : Int, angle : Int, flip : Bool) -> Unit {
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
fn av1_h(t : FixedArray[Int], a0 : Int, b0 : Int, flip : Bool, r : Int) -> Unit {
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
fn av1_inv_dct(t : FixedArray[Int], n : Int, r : Int) -> Unit {
  let len = 1 << n
  let copy = FixedArray::makei(len, fn(i) { t[i] })
  for i in 0..<len {
    t[i] = copy[av1_brev(n, i)]
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
fn av1_inv_adst4(t : FixedArray[Int]) -> Unit {
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
fn av1_adst_in_perm(t : FixedArray[Int], n : Int) -> Unit {
  let n0 = 1 << n
  let copy = FixedArray::makei(n0, fn(i) { t[i] })
  for i in 0..<n0 {
    let idx = if (i & 1) == 1 { i - 1 } else { n0 - i - 1 }
    t[i] = copy[idx]
  }
}

///|
fn av1_adst_out_perm(t : FixedArray[Int], n : Int) -> Unit {
  let n0 = 1 << n
  let copy = FixedArray::makei(n0, fn(i) { t[i] })
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
fn av1_inv_adst8(t : FixedArray[Int], r : Int) -> Unit {
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
fn av1_inv_adst16(t : FixedArray[Int], r : Int) -> Unit {
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
fn av1_inv_identity(t : FixedArray[Int], n : Int) -> Unit {
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
fn av1_inv_1d(t : FixedArray[Int], kind : Int, n : Int, r : Int) -> Unit {
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
fn av1_tx_row_kind(tx_type : Int) -> Int {
  match tx_type {
    0 | 1 | 4 | 11 => 0 // DCT_DCT, ADST_DCT, FLIPADST_DCT, H_DCT
    2 | 3 | 5 | 6 | 7 | 8 | 13 | 15 => 1
    _ => 2
  }
}

///|
fn av1_tx_col_kind(tx_type : Int) -> Int {
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
  dq : FixedArray[Int],
  tx_size : Int,
  tx_type : Int,
  res : FixedArray[Int],
) -> Unit {
  let log2w = av1_tx_width_log2[tx_size]
  let log2h = av1_tx_height_log2[tx_size]
  let w = 1 << log2w
  let h = 1 << log2h
  let row_shift = av1_transform_row_shift[tx_size]
  let rk = av1_tx_row_kind(tx_type)
  let ck = av1_tx_col_kind(tx_type)
  let rect = log2w - log2h == 1 || log2h - log2w == 1
  let t = FixedArray::make(64, 0)
  let lo = -(1 << 15)
  let hi = (1 << 15) - 1
  for i in 0..<h {
    if i >= 32 {
      for j in 0..<w {
        res[i * w + j] = 0
      }
      // A zero row transforms to zero for every kind.
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
fn av1_fwd_matrix(kind : Int, n : Int) -> FixedArray[Double] {
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
fn av1_mat_inverse(a : FixedArray[Double], len : Int) -> FixedArray[Double] {
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
  res : FixedArray[Int],
  tx_size : Int,
  tx_type : Int,
  out : FixedArray[Double],
) -> Unit {
  let log2w = av1_tx_width_log2[tx_size]
  let log2h = av1_tx_height_log2[tx_size]
  let w = 1 << log2w
  let h = 1 << log2h
  let fr = av1_fwd_matrix(av1_tx_row_kind(tx_type), log2w)
  let fc = av1_fwd_matrix(av1_tx_col_kind(tx_type), log2h)
  let rect = log2w - log2h == 1 || log2h - log2w == 1
  // Undo the shifts and the rectangular scaling of the inverse.
  let mut scale = (1 << (av1_transform_row_shift[tx_size] + 4)).to_double()
  if rect {
    scale = scale * 4096.0 / 2896.0
  }
  let ow = if w > 32 { 32 } else { w }
  let oh = if h > 32 { 32 } else { h }
  // tmp = res * fr^T (rows), then out = fc * tmp (columns).
  let tmp = FixedArray::make(h * ow, 0.0)
  for i in 0..<h {
    for k in 0..<ow {
      let mut s = 0.0
      for j in 0..<w {
        s = s + fr[k * w + j] * res[i * w + j].to_double()
      }
      tmp[i * ow + k] = s
    }
  }
  for i in 0..<(h * w) {
    out[i] = 0.0
  }
  for k in 0..<oh {
    for j in 0..<ow {
      let mut s = 0.0
      for i in 0..<h {
        s = s + fc[k * h + i] * tmp[i * ow + j]
      }
      out[k * w + j] = s * scale
    }
  }
}
