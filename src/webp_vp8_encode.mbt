// Lossy WebP (VP8 key frame) encoder. Each macroblock picks a 16x16 or
// 4x4 intra prediction and a chroma mode by prediction error; residuals go
// through the forward DCT / WHT and a dead-zone quantizer, and are coded
// with the default token probabilities. The reconstruction uses the
// decoder's own prediction and inverse transforms (on unfiltered pixels,
// like the decoder), so encoder and decoder stay in sync.

///|
/// VP8 boolean encoder (libwebp's VP8BitWriter).
priv struct VP8BoolWriter {
  mut range : Int32 // range - 1
  mut value : Int32
  mut run : Int32 // pending 0xFF bytes (carry propagation)
  mut nb_bits : Int32
  bytes : Array[Byte]
}

///|
fn VP8BoolWriter::new() -> VP8BoolWriter {
  { range: 254, value: 0, run: 0, nb_bits: -8, bytes: [], }
}

///|
fn VP8BoolWriter::flush(self : VP8BoolWriter) -> Unit {
  let s = 8 + self.nb_bits
  let bits = self.value >> s
  self.value -= bits << s
  self.nb_bits -= 8
  if (bits & 0xff) != 0xff {
    if (bits & 0x100) != 0 && self.bytes.length() > 0 {
      let i = self.bytes.length() - 1
      self.bytes[i] = (self.bytes[i].to_int() + 1).to_byte()
    }
    let fill = if (bits & 0x100) != 0 { b'\x00' } else { b'\xFF' }
    while self.run > 0 {
      self.bytes.push(fill)
      self.run -= 1
    }
    self.bytes.push((bits & 0xff).to_byte())
  } else {
    self.run += 1
  }
}

///|
fn VP8BoolWriter::put_bit(
  self : VP8BoolWriter,
  bit : Bool,
  prob : Int32,
) -> Bool {
  let split = (self.range * prob) >> 8
  if bit {
    self.value += split + 1
    self.range -= split + 1
  } else {
    self.range = split
  }
  if self.range < 127 {
    // Renormalize: shift so that range >= 127 again.
    let shift = (self.range + 1).clz() - 24
    self.range = ((self.range + 1) << shift) - 1
    self.value = self.value << shift
    self.nb_bits += shift
    if self.nb_bits > 0 {
      self.flush()
    }
  }
  bit
}

///|
fn VP8BoolWriter::put_bits(
  self : VP8BoolWriter,
  value : Int32,
  n : Int32,
) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    ignore(self.put_bit(((value >> i) & 1) == 1, 0x80))
  }
}

///|
/// Optional signed header value: presence flag, magnitude, sign.
fn VP8BoolWriter::put_signed(
  self : VP8BoolWriter,
  value : Int32,
  n : Int32,
) -> Unit {
  if !self.put_bit(value != 0, 0x80) {
    return
  }
  let m = if value < 0 { -value } else { value }
  self.put_bits(m, n)
  ignore(self.put_bit(value < 0, 0x80))
}

///|
fn VP8BoolWriter::finish(self : VP8BoolWriter) -> Bytes {
  self.put_bits(0, 9 - self.nb_bits)
  self.nb_bits = 0
  self.flush()
  Bytes::from_array(FixedArray::from_array(self.bytes))
}

///|
/// Scratch for `vp8_fdct` / `vp8_fwht` (encoding is single-threaded).
let vp8_fdct_tmp : FixedArray[Int32] = FixedArray::make(16, 0)

///|
/// Forward 4x4 DCT of `src - ref` (both 32-stride) into `out` (libwebp's
/// FTransform).
fn vp8_fdct(
  src : FixedArray[Int32],
  s : Int32,
  pred : FixedArray[Int32],
  p : Int32,
  out : FixedArray[Int32],
  o : Int32,
) -> Unit {
  let tmp = vp8_fdct_tmp
  for i in 0..<4 {
    let d0 = src[s + i * 32] - pred[p + i * 32]
    let d1 = src[s + i * 32 + 1] - pred[p + i * 32 + 1]
    let d2 = src[s + i * 32 + 2] - pred[p + i * 32 + 2]
    let d3 = src[s + i * 32 + 3] - pred[p + i * 32 + 3]
    let a0 = d0 + d3
    let a1 = d1 + d2
    let a2 = d1 - d2
    let a3 = d0 - d3
    tmp[i * 4] = (a0 + a1) * 8
    tmp[i * 4 + 1] = (a2 * 2217 + a3 * 5352 + 1812) >> 9
    tmp[i * 4 + 2] = (a0 - a1) * 8
    tmp[i * 4 + 3] = (a3 * 2217 - a2 * 5352 + 937) >> 9
  }
  for i in 0..<4 {
    let a0 = tmp[i] + tmp[12 + i]
    let a1 = tmp[4 + i] + tmp[8 + i]
    let a2 = tmp[4 + i] - tmp[8 + i]
    let a3 = tmp[i] - tmp[12 + i]
    out[o + i] = (a0 + a1 + 7) >> 4
    out[o + 4 + i] = ((a2 * 2217 + a3 * 5352 + 12000) >> 16) +
      (if a3 != 0 { 1 } else { 0 })
    out[o + 8 + i] = (a0 - a1 + 7) >> 4
    out[o + 12 + i] = (a3 * 2217 - a2 * 5352 + 51000) >> 16
  }
}

///|
/// Forward WHT of the 16 DC coefficients (at `coeffs[n * 16]`).
fn vp8_fwht(coeffs : FixedArray[Int32], out : FixedArray[Int32]) -> Unit {
  let tmp = vp8_fdct_tmp
  for i in 0..<4 {
    let a0 = coeffs[(i * 4 + 0) * 16] + coeffs[(i * 4 + 2) * 16]
    let a1 = coeffs[(i * 4 + 1) * 16] + coeffs[(i * 4 + 3) * 16]
    let a2 = coeffs[(i * 4 + 1) * 16] - coeffs[(i * 4 + 3) * 16]
    let a3 = coeffs[(i * 4 + 0) * 16] - coeffs[(i * 4 + 2) * 16]
    tmp[i * 4] = a0 + a1
    tmp[i * 4 + 1] = a3 + a2
    tmp[i * 4 + 2] = a3 - a2
    tmp[i * 4 + 3] = a0 - a1
  }
  for i in 0..<4 {
    let a0 = tmp[i] + tmp[8 + i]
    let a1 = tmp[4 + i] + tmp[12 + i]
    let a2 = tmp[4 + i] - tmp[12 + i]
    let a3 = tmp[i] - tmp[8 + i]
    out[i] = (a0 + a1) >> 1
    out[4 + i] = (a3 + a2) >> 1
    out[8 + i] = (a3 - a2) >> 1
    out[12 + i] = (a0 - a1) >> 1
  }
}

///|
/// Quantize 16 coefficients (raster order) to zigzag-ordered levels with a
/// dead zone, and write the dequantized values back (raster order) for the
/// reconstruction. Returns the zigzag index of the last non-zero level.
fn vp8_quantize(
  coeffs : FixedArray[Int32],
  o : Int32,
  dc_q : Int32,
  ac_q : Int32,
  first : Int32,
  levels : FixedArray[Int32],
  lo : Int32,
) -> Int32 {
  let mut last = -1
  for n in 0..<16 {
    let pos = vp8_zigzag[n]
    let q = if n == 0 { dc_q } else { ac_q }
    let c = coeffs[o + pos]
    if n < first {
      levels[lo + n] = 0
      continue
    }
    let a = if c < 0 { -c } else { c }
    // Rounding bias: a bit under 1/2 (DC) or 1/3 (AC) of a step.
    let bias = if n == 0 { q * 7 / 16 } else { q * 11 / 32 }
    let mut l = (a + bias) / q
    if l > 2047 {
      l = 2047
    }
    let v = if c < 0 { -l } else { l }
    levels[lo + n] = v
    coeffs[o + pos] = v * q
    if l != 0 {
      last = n
    }
  }
  last
}

///|
/// Record one token bit: `code` < 1056 is an (updatable) coefficient
/// probability index, otherwise a fixed probability 1056 + p.
fn vp8_rec(ev : Array[Int32], bit : Bool, code : Int32) -> Bool {
  ev.push(code * 2 + (if bit { 1 } else { 0 }))
  bit
}

///|
/// log2(x) * 256 for 1 <= x <= 256 (fixed point).
fn vp8_log2_fix(x : Int32) -> Int32 {
  let mut ip = 0
  while 2 << ip <= x {
    ip += 1
  }
  // Mantissa in [1, 2) as 16.16, refined by squaring.
  let mut m = x << 16 >> ip
  let mut frac = 0
  for k in 0..<8 {
    m = ((m.to_int64() * m.to_int64()) >> 16).to_int()
    if m >= 2 << 16 {
      m = m >> 1
      frac = frac | (1 << (7 - k))
    }
  }
  ip * 256 + frac
}

///|
/// Cost (in 1/256 bit) of coding `bit` with probability `p` / 256 of 0.
fn vp8_bit_cost(bit : Bool, p : Int32) -> Int32 {
  if bit {
    2048 - vp8_log2_fix(256 - p)
  } else {
    2048 - vp8_log2_fix(p)
  }
}

///|
/// Record the tokens of one block (zigzag levels, from `first`). Returns
/// whether any coefficient was coded (the neighbor context).
fn vp8_put_coeffs(
  ev : Array[Int32],
  t : Int32,
  ctx : Int32,
  levels : FixedArray[Int32],
  lo : Int32,
  first : Int32,
  last : Int32,
) -> Bool {
  let base = t * 8 * 33
  let mut n = first
  let mut p = base + vp8_bands[n] * 33 + ctx * 11
  if !vp8_rec(ev, last >= 0, p) {
    return false
  }
  while n < 16 {
    let c = levels[lo + n]
    n += 1
    let v = if c < 0 { -c } else { c }
    if !vp8_rec(ev, v != 0, p + 1) {
      p = base + vp8_bands[n] * 33
      continue
    }
    if !vp8_rec(ev, v > 1, p + 2) {
      p = base + vp8_bands[n] * 33 + 11
    } else {
      if !vp8_rec(ev, v > 4, p + 3) {
        if vp8_rec(ev, v != 2, p + 4) {
          ignore(vp8_rec(ev, v == 4, p + 5))
        }
      } else if !vp8_rec(ev, v > 10, p + 6) {
        if !vp8_rec(ev, v > 6, p + 7) {
          ignore(vp8_rec(ev, v == 6, 1056 + 159))
        } else {
          ignore(vp8_rec(ev, v >= 9, 1056 + 165))
          ignore(vp8_rec(ev, (v & 1) == 0, 1056 + 145))
        }
      } else {
        let (cat, rest) = if v < 3 + (8 << 1) {
          ignore(vp8_rec(ev, false, p + 8))
          ignore(vp8_rec(ev, false, p + 9))
          (0, v - (3 + (8 << 0)))
        } else if v < 3 + (8 << 2) {
          ignore(vp8_rec(ev, false, p + 8))
          ignore(vp8_rec(ev, true, p + 9))
          (1, v - (3 + (8 << 1)))
        } else if v < 3 + (8 << 3) {
          ignore(vp8_rec(ev, true, p + 8))
          ignore(vp8_rec(ev, false, p + 10))
          (2, v - (3 + (8 << 2)))
        } else {
          ignore(vp8_rec(ev, true, p + 8))
          ignore(vp8_rec(ev, true, p + 10))
          (3, v - (3 + (8 << 3)))
        }
        let tab = vp8_cat3456[cat]
        for k in 0..<tab.length() {
          let bit = (rest >> (tab.length() - 1 - k)) & 1
          ignore(vp8_rec(ev, bit == 1, 1056 + tab[k]))
        }
      }
      p = base + vp8_bands[n] * 33 + 22
    }
    ignore(vp8_rec(ev, c < 0, 1056 + 0x80))
    if n == 16 || !vp8_rec(ev, n <= last, p) {
      return true
    }
  }
  true
}

///|
/// (probability index, bit) path of every 4x4 intra mode in the mode tree.
let vp8_bmode_paths : FixedArray[Array[(Int32, Int32)]] = {
  let paths = FixedArray::make(10, [])
  fn walk(node : Int32, path : Array[(Int32, Int32)]) -> Unit {
    for bit in 0..<2 {
      let v = vp8_ymodes_intra4[2 * node + bit]
      let p = path.copy()
      p.push((node, bit))
      if v <= 0 {
        paths[-v] = p
      } else {
        walk(v, p)
      }
    }
  }
  walk(0, [])
  paths
}

///|
fn vp8_sse(
  a : FixedArray[Int32],
  ao : Int32,
  b : FixedArray[Int32],
  bo : Int32,
  size : Int32,
) -> Int32 {
  let mut s = 0
  for y in 0..<size {
    for x in 0..<size {
      let d = a[ao + y * 32 + x] - b[bo + y * 32 + x]
      s += d * d
    }
  }
  s
}

///|
/// Base quantizer index for each quality 0-100, with libwebp's mapping:
/// q = 127 * (1 - c^(1/3)), c = quality * 2/3 below 75, 2 quality - 1 above
/// (quality as a fraction).
let vp8_quality_q : FixedArray[Int32] = [
  127, 103, 96, 92, 89, 86, 83, 81, 79, 77, 75, 73, 72, 70, 69, 68, 66, 65, 64, 63,
  62, 61, 60, 59, 58, 57, 56, 55, 54, 53, 52, 51, 51, 50, 49, 48, 48, 47, 46, 45,
  45, 44, 43, 43, 42, 41, 41, 40, 40, 39, 38, 38, 37, 37, 36, 36, 35, 35, 34, 33,
  33, 32, 32, 31, 31, 30, 30, 29, 29, 28, 28, 28, 27, 27, 26, 26, 24, 23, 22, 21,
  19, 18, 17, 16, 15, 14, 13, 12, 11, 10, 9, 8, 7, 6, 5, 4, 3, 2, 1, 0, 0,
]

///|
fn vp8_quality_to_q(quality : Int32) -> Int32 {
  vp8_quality_q[quality.clamp(min=0, max=100)]
}

///|
/// Encode a lossy WebP (VP8). `quality` is 0-100 (higher = better and
/// larger). Alpha, when present, is stored losslessly in an ALPH chunk.
pub fn encode_webp_lossy(
  img : ImageData,
  quality~ : Int32 = 75,
) -> Bytes raise EncodeError {
  validate_rgba8_image(img)
  let w = img.width
  let h = img.height
  if w > 16383 || h > 16383 {
    raise InvalidDimensions(
      "WebP lossy dimensions must be <= 16383: " +
      w.to_string() +
      "x" +
      h.to_string(),
    )
  }
  let vp8 = vp8_encode_frame(img, vp8_quality_to_q(quality))
  let mut has_alpha = false
  for i in 0..<(w * h) {
    if img.data[i * 4 + 3] != b'\xFF' {
      has_alpha = true
      break
    }
  }
  let body = Buffer()
  for c in "WEBP" {
    body.write_byte(c.to_int().to_byte())
  }
  if has_alpha {
    let vp8x = Buffer()
    vp8x.write_byte(b'\x10')
    webp_put_le(vp8x, 0, 3)
    webp_put_le(vp8x, w - 1, 3)
    webp_put_le(vp8x, h - 1, 3)
    webp_put_chunk(body, "VP8X", vp8x.to_bytes())
    webp_put_chunk(body, "ALPH", webp_encode_alpha(img))
  }
  webp_put_chunk(body, "VP8 ", vp8)
  let b = body.to_bytes()
  let out = Buffer()
  for c in "RIFF" {
    out.write_byte(c.to_int().to_byte())
  }
  webp_put_le(out, b.length(), 4)
  out.write_bytes(b)
  out.to_bytes()
}

///|
/// ALPH chunk payload: lossless (VP8L, alpha in the green channel) after
/// the spatial filter (none / horizontal / vertical / gradient) that gives
/// the smallest stream.
fn webp_encode_alpha(img : ImageData) -> Bytes {
  let w = img.width
  let h = img.height
  let a = FixedArray::makei(w * h, fn(i) { img.data[i * 4 + 3].to_int() })
  let mut best : Bytes? = None
  for filter in 0..<4 {
    let argb = FixedArray::make(w * h, 0)
    for y in 0..<h {
      for x in 0..<w {
        let i = y * w + x
        // Predictors exactly as the decoder's unfilters.
        let pred = if filter == 0 {
          0
        } else if y == 0 {
          if x == 0 {
            0
          } else {
            a[i - 1]
          }
        } else if filter == 1 {
          if x == 0 {
            a[i - w]
          } else {
            a[i - 1]
          }
        } else if filter == 2 {
          a[i - w]
        } else if x == 0 {
          a[i - w]
        } else {
          vp8_clip8(a[i - 1] + a[i - w] - a[i - w - 1])
        }
        argb[i] = 0xff000000 | (((a[i] - pred) & 0xff) << 8)
      }
    }
    let out = Buffer()
    out.write_byte((1 | (filter << 2)).to_byte())
    out.write_bytes(vp8l_encode_argb(argb, w, h, false, false))
    let b = out.to_bytes()
    match best {
      Some(prev) if prev.length() <= b.length() => ()
      _ => best = Some(b)
    }
  }
  best.unwrap()
}

///|
/// libwebp's RGB -> YUV (16-bit fixed point; U / V from 2x2 sums).
fn vp8_rgb_to_yuv(
  img : ImageData,
  mb_w : Int32,
  mb_h : Int32,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
  let w = img.width
  let h = img.height
  let ys = mb_w * 16
  let uvs = mb_w * 8
  let yp = FixedArray::make(ys * mb_h * 16, 0)
  let up = FixedArray::make(uvs * mb_h * 8, 0)
  let vp = FixedArray::make(uvs * mb_h * 8, 0)
  // Edge pixels are replicated into the macroblock padding.
  let px = fn(x : Int32, y : Int32, c : Int32) -> Int32 {
    let xx = if x < w { x } else { w - 1 }
    let yy = if y < h { y } else { h - 1 }
    img.data[(yy * w + xx) * 4 + c].to_int()
  }
  for y in 0..<(mb_h * 16) {
    for x in 0..<(mb_w * 16) {
      let r = px(x, y, 0)
      let g = px(x, y, 1)
      let b = px(x, y, 2)
      yp[y * ys + x] = (
          16839 * r + 33059 * g + 6420 * b + (1 << 15) + (16 << 16)
        ) >>
        16
    }
  }
  for y in 0..<(mb_h * 8) {
    for x in 0..<(mb_w * 8) {
      let mut r = 0
      let mut g = 0
      let mut b = 0
      for dy in 0..<2 {
        for dx in 0..<2 {
          r += px(x * 2 + dx, y * 2 + dy, 0)
          g += px(x * 2 + dx, y * 2 + dy, 1)
          b += px(x * 2 + dx, y * 2 + dy, 2)
        }
      }
      let clip_uv = fn(v : Int32) {
        vp8_clip((v + (1 << 17) + (128 << 18)) >> 18, 255)
      }
      up[y * uvs + x] = clip_uv(-9719 * r - 19081 * g + 28800 * b)
      vp[y * uvs + x] = clip_uv(28800 * r - 24116 * g - 4684 * b)
    }
  }
  (yp, up, vp)
}

///|
/// 16x16 / chroma modes (best by prediction error) that get the full RD
/// evaluation.
let vp8_mode_candidates = 4

///|
/// Modes 0..n-1 sorted by `err(mode)` (ascending).
fn vp8_rank_modes(n : Int32, err : (Int32) -> Int32) -> Array[Int32] {
  let e = FixedArray::makei(n, fn(m) { err(m) })
  let r = Array::makei(n, fn(i) { i })
  r.sort_by(fn(a, b) { e[a] - e[b] })
  r
}

///|
/// 4x4 modes (best by prediction error) that get the full RD evaluation.
let vp8_i4_candidates = 4

///|
/// Lambda scale for the rate-distortion mode decisions.
let vp8_lambda_scale = 4

///|
/// Approximate bits (1/256) of each 16x16 / chroma mode in its tree.
let vp8_i16_mode_bits : FixedArray[Int32] = [512, 512, 512, 512]

///|
let vp8_uv_mode_bits : FixedArray[Int32] = [256, 768, 512, 768]

///|
/// Cost tables (1/256 bit) of coding 0 / 1 with probability p / 256.
let vp8_cost0 : FixedArray[Int32] = FixedArray::makei(256, fn(p) {
  vp8_bit_cost(false, if p < 1 { 1 } else { p })
})

///|
let vp8_cost1 : FixedArray[Int32] = FixedArray::makei(256, fn(p) {
  vp8_bit_cost(true, if p < 1 { 1 } else { p })
})

///|
/// Bits (1/256) to code one block with the default probabilities: the
/// token tree of `vp8_put_coeffs`, summing costs instead of recording.
fn vp8_token_cost(
  levels : FixedArray[Int32],
  lo : Int32,
  t : Int32,
  ctx : Int32,
  first : Int32,
  last : Int32,
) -> Int32 {
  let proba = vp8_coeffs_proba0
  let c0 = vp8_cost0
  let c1 = vp8_cost1
  let base = t * 8 * 33
  let mut n = first
  let mut p = base + vp8_bands[n] * 33 + ctx * 11
  if last < 0 {
    return c0[proba[p]]
  }
  let mut cost = c1[proba[p]]
  while n < 16 {
    let c = levels[lo + n]
    n += 1
    let v = if c < 0 { -c } else { c }
    if v == 0 {
      cost += c0[proba[p + 1]]
      p = base + vp8_bands[n] * 33
      continue
    }
    cost += c1[proba[p + 1]]
    if v == 1 {
      cost += c0[proba[p + 2]]
      p = base + vp8_bands[n] * 33 + 11
    } else {
      cost += c1[proba[p + 2]]
      if v <= 4 {
        cost += c0[proba[p + 3]]
        if v == 2 {
          cost += c0[proba[p + 4]]
        } else {
          cost += c1[proba[p + 4]] +
            (if v == 4 { c1[proba[p + 5]] } else { c0[proba[p + 5]] })
        }
      } else if v <= 10 {
        cost += c1[proba[p + 3]] + c0[proba[p + 6]]
        if v <= 6 {
          cost += c0[proba[p + 7]] + (if v == 6 { c1[159] } else { c0[159] })
        } else {
          cost += c1[proba[p + 7]] +
            (if v >= 9 { c1[165] } else { c0[165] }) +
            (if (v & 1) == 0 { c1[145] } else { c0[145] })
        }
      } else {
        cost += c1[proba[p + 3]] + c1[proba[p + 6]]
        // Extra bits of the categories (about one bit each, plus the
        // category bits).
        let (cat_cost, nbits) = if v < 3 + (8 << 1) {
          (c0[proba[p + 8]] + c0[proba[p + 9]], 3)
        } else if v < 3 + (8 << 2) {
          (c0[proba[p + 8]] + c1[proba[p + 9]], 4)
        } else if v < 3 + (8 << 3) {
          (c1[proba[p + 8]] + c0[proba[p + 10]], 5)
        } else {
          (c1[proba[p + 8]] + c1[proba[p + 10]], 11)
        }
        cost += cat_cost + nbits * 256
      }
      p = base + vp8_bands[n] * 33 + 22
    }
    cost += 256 // sign
    if n == 16 {
      return cost
    }
    if n > last {
      return cost + c0[proba[p]]
    }
    cost += c1[proba[p]]
  }
  cost
}

///|
/// Token bits of an i16 macroblock (Y2 + 16 AC blocks), propagating the
/// non-zero contexts like the decoder. `ctx_y`: 4 top + 4 left flags.
fn vp8_cost_i16(
  levels : FixedArray[Int32],
  lasts : FixedArray[Int32],
  ctx_y : FixedArray[Int32],
  dc_ctx : Int32,
) -> Int32 {
  let mut c = vp8_token_cost(levels, 0, 1, dc_ctx, 0, lasts[0])
  let t = ctx_y.copy()
  for n in 0..<16 {
    let bx = n & 3
    let by = n >> 2
    let last = if lasts[n + 1] >= 1 { lasts[n + 1] } else { -1 }
    c += vp8_token_cost(levels, (n + 1) * 16, 0, t[bx] + t[4 + by], 1, last)
    let f = if last >= 1 { 1 } else { 0 }
    t[bx] = f
    t[4 + by] = f
  }
  c
}

///|
/// Token bits of the 8 chroma blocks.
fn vp8_cost_uv(
  levels : FixedArray[Int32],
  lasts : FixedArray[Int32],
  top_nz : FixedArray[Int32],
  left_nz : FixedArray[Int32],
  mb_x : Int32,
) -> Int32 {
  let t = FixedArray::make(8, 0)
  for k in 0..<4 {
    t[k] = top_nz[mb_x * 9 + 4 + k]
    t[4 + k] = left_nz[4 + k]
  }
  let mut c = 0
  for k in 0..<8 {
    let ch = k >> 2
    let kk = k & 3
    let ti = ch * 2 + (kk & 1)
    let li = 4 + ch * 2 + (kk >> 1)
    c += vp8_token_cost(
      levels,
      (17 + k) * 16,
      2,
      t[ti] + t[li],
      0,
      lasts[17 + k],
    )
    let f = if lasts[17 + k] >= 0 { 1 } else { 0 }
    t[ti] = f
    t[li] = f
  }
  c
}

///|
/// Work buffers for the residual coders, allocated once per frame.
priv struct VP8EncScratch {
  blk : FixedArray[Int32]
  tmp : FixedArray[Int32]
  wht : FixedArray[Int32]
  whtl : FixedArray[Int32]
  cb : FixedArray[Int32]
}

///|
fn VP8EncScratch::new() -> VP8EncScratch {
  {
    blk: FixedArray::make(256, 0),
    tmp: FixedArray::make(256, 0),
    wht: FixedArray::make(16, 0),
    whtl: FixedArray::make(256, 0),
    cb: FixedArray::make(128, 0),
  }
}

///|
/// Code the 16x16 luma residual of `buf` (holding the prediction): forward
/// DCT / WHT, quantization into `levels[0..17*16)` / `lasts[0..17)`, and the
/// decoder's reconstruction back into `buf`. `qm`: y1 dc / ac, y2 dc / ac,
/// uv dc / ac.
fn vp8_code_i16(
  src : FixedArray[Int32],
  buf : FixedArray[Int32],
  yd : Int32,
  qm : Array[Int32],
  levels : FixedArray[Int32],
  lasts : FixedArray[Int32],
  ws : VP8EncScratch,
) -> Unit {
  let blk = ws.blk
  for n in 0..<16 {
    let d = yd + (n & 3) * 4 + (n >> 2) * 128
    vp8_fdct(src, d, buf, d, blk, n * 16)
  }
  let tmp = ws.tmp
  for n in 0..<16 {
    tmp[n * 16] = blk[n * 16]
  }
  let wht = ws.wht
  vp8_fwht(tmp, wht)
  lasts[0] = vp8_quantize(wht, 0, qm[2], qm[3], 0, levels, 0)
  for n in 0..<16 {
    lasts[n + 1] = vp8_quantize(
      blk,
      n * 16,
      qm[0],
      qm[1],
      1,
      levels,
      (n + 1) * 16,
    )
  }
  // Reconstruct exactly like the decoder.
  if lasts[0] > 0 {
    let whtl = ws.whtl
    vp8_transform_wht(wht, whtl)
    for n in 0..<16 {
      blk[n * 16] = whtl[n * 16]
    }
  } else {
    let dc0 = (wht[0] + 3) >> 3
    for n in 0..<16 {
      blk[n * 16] = dc0
    }
  }
  for n in 0..<16 {
    let d = yd + (n & 3) * 4 + (n >> 2) * 128
    if lasts[n + 1] >= 1 || blk[n * 16] != 0 {
      vp8_transform(blk, n * 16, buf, d)
    }
  }
}

///|
/// Code the U / V residuals of `buf` (holding the predictions) into
/// `levels[17*16..)` / `lasts[17..25)` and reconstruct them.
fn vp8_code_uv(
  src : FixedArray[Int32],
  buf : FixedArray[Int32],
  qm : Array[Int32],
  levels : FixedArray[Int32],
  lasts : FixedArray[Int32],
  ws : VP8EncScratch,
) -> Unit {
  let cb = ws.cb
  for k in 0..<8 {
    let base = if k < 4 { vp8_u_off } else { vp8_v_off }
    let kk = k & 3
    let d = base + (kk & 1) * 4 + (kk >> 1) * 128
    vp8_fdct(src, d, buf, d, cb, k * 16)
    lasts[17 + k] = vp8_quantize(
      cb,
      k * 16,
      qm[4],
      qm[5],
      0,
      levels,
      (17 + k) * 16,
    )
  }
  let any_u = lasts[17] >= 0 ||
    lasts[18] >= 0 ||
    lasts[19] >= 0 ||
    lasts[20] >= 0
  let any_v = lasts[21] >= 0 ||
    lasts[22] >= 0 ||
    lasts[23] >= 0 ||
    lasts[24] >= 0
  for k in 0..<8 {
    let base = if k < 4 { vp8_u_off } else { vp8_v_off }
    let kk = k & 3
    let d = base + (kk & 1) * 4 + (kk >> 1) * 128
    if (k < 4 && any_u) || (k >= 4 && any_v) {
      vp8_transform(cb, k * 16, buf, d)
    }
  }
}

///|
fn vp8_encode_frame(img : ImageData, q : Int32) -> Bytes {
  let w = img.width
  let h = img.height
  let mb_w = (w + 15) >> 4
  let mb_h = (h + 15) >> 4
  let (sy, su, sv) = vp8_rgb_to_yuv(img, mb_w, mb_h)
  let ys = mb_w * 16
  let uvs = mb_w * 8
  // Dequantization steps, as the decoder computes them for base index q.
  let y1_dc = vp8_dc_table[q]
  let y1_ac = vp8_ac_table[q]
  let y2_dc = vp8_dc_table[q] * 2
  let y2_ac = {
    let v = (vp8_ac_table[q] * 101581) >> 16
    if v < 8 {
      8
    } else {
      v
    }
  }
  let uv_dc = vp8_dc_table[if q > 117 { 117 } else { q }]
  let uv_ac = vp8_ac_table[q]
  // Rate-distortion lambda (squared error per bit).
  let lambda = vp8_lambda_scale * y1_ac * y1_ac / 128 + 1
  let qm = [y1_dc, y1_ac, y2_dc, y2_ac, uv_dc, uv_ac]
  let tlevels = FixedArray::make(25 * 16, 0)
  let tlasts = FixedArray::make(25, -1)
  let ws = VP8EncScratch::new()
  let modes_bw = VP8BoolWriter::new()
  let events : Array[Int32] = []
  // Decoder-identical working state.
  let yuv = FixedArray::make(32 * 17 + 32 * 9, 0)
  let top = FixedArray::make(mb_w * 32, 0)
  let top_nz = FixedArray::make(mb_w * 9, 0) // 4 Y + 2 U + 2 V + DC
  let left_nz = FixedArray::make(9, 0)
  let src = FixedArray::make(32 * 17 + 32 * 9, 0)
  let pred = FixedArray::make(32 * 17 + 32 * 9, 0)
  let coeffs = FixedArray::make(384, 0)
  let levels = FixedArray::make(25 * 16, 0)
  let lasts = FixedArray::make(25, -1)
  let yd = vp8_y_off
  let ud = vp8_u_off
  let vd = vp8_v_off
  let imodes = FixedArray::make(16, 0)
  // Pass 1 collects per-macroblock decisions and tokens into two writers;
  // the frame header (with the skip probability) is written afterwards,
  // so record the mode data and replay it.
  let mb_info : Array[(Bool, Int32, FixedArray[Int32], Int32, Bool)] = []
  for mb_y in 0..<mb_h {
    for j in 0..<16 {
      yuv[yd + j * 32 - 1] = 129
    }
    for j in 0..<8 {
      yuv[ud + j * 32 - 1] = 129
      yuv[vd + j * 32 - 1] = 129
    }
    if mb_y > 0 {
      yuv[yd - 33] = 129
      yuv[ud - 33] = 129
      yuv[vd - 33] = 129
    } else {
      for i in 0..<21 {
        yuv[yd - 33 + i] = 127
      }
      for i in 0..<9 {
        yuv[ud - 33 + i] = 127
        yuv[vd - 33 + i] = 127
      }
    }
    left_nz.fill(0)
    for mb_x in 0..<mb_w {
      if mb_x > 0 {
        for j in -1..<16 {
          for i in 0..<4 {
            yuv[yd + j * 32 - 4 + i] = yuv[yd + j * 32 + 12 + i]
          }
        }
        for j in -1..<8 {
          for i in 0..<4 {
            yuv[ud + j * 32 - 4 + i] = yuv[ud + j * 32 + 4 + i]
            yuv[vd + j * 32 - 4 + i] = yuv[vd + j * 32 + 4 + i]
          }
        }
      }
      let tb = mb_x * 32
      if mb_y > 0 {
        for i in 0..<16 {
          yuv[yd - 32 + i] = top[tb + i]
        }
        for i in 0..<8 {
          yuv[ud - 32 + i] = top[tb + 16 + i]
          yuv[vd - 32 + i] = top[tb + 24 + i]
        }
        let tr = yd - 32 + 16
        if mb_x >= mb_w - 1 {
          for i in 0..<4 {
            yuv[tr + i] = top[tb + 15]
          }
        } else {
          for i in 0..<4 {
            yuv[tr + i] = top[tb + 32 + i]
          }
        }
      }
      let tr = yd - 32 + 16
      for k in 1..<4 {
        for i in 0..<4 {
          yuv[tr + k * 128 + i] = yuv[tr + i]
        }
      }
      // Source block in the same layout.
      for j in 0..<16 {
        for i in 0..<16 {
          src[yd + j * 32 + i] = sy[(mb_y * 16 + j) * ys + mb_x * 16 + i]
        }
      }
      for j in 0..<8 {
        for i in 0..<8 {
          src[ud + j * 32 + i] = su[(mb_y * 8 + j) * uvs + mb_x * 8 + i]
          src[vd + j * 32 + i] = sv[(mb_y * 8 + j) * uvs + mb_x * 8 + i]
        }
      }
      // Mode decisions are rate-distortion optimized: each candidate is
      // quantized and reconstructed (in `pred`, which shares the borders
      // with `yuv`) and scored as SSE * 256 + lambda * token bits (1/256).
      yuv.blit_to(pred, len=yuv.length())
      let ctx_y = FixedArray::make(8, 0) // 4 top + 4 left non-zero flags
      let load_ctx = fn() {
        for k in 0..<4 {
          ctx_y[k] = top_nz[mb_x * 9 + k]
          ctx_y[4 + k] = left_nz[k]
        }
      }
      // --- Luma 16x16.
      let r16 = vp8_rank_modes(4, fn(mode) {
        vp8_predict_block(pred, yd, 16, vp8_check_mode(mb_x, mb_y, mode))
        vp8_sse(src, yd, pred, yd, 16)
      })
      let mut best16 = 0
      let mut best16_cost = 0x7fffffffffffffffL
      for ri in 0..<vp8_mode_candidates {
        let mode = r16[ri]
        vp8_predict_block(pred, yd, 16, vp8_check_mode(mb_x, mb_y, mode))
        vp8_code_i16(src, pred, yd, qm, tlevels, tlasts, ws)
        load_ctx()
        let dc_ctx = top_nz[mb_x * 9 + 8] + left_nz[8]
        let r = vp8_cost_i16(tlevels, tlasts, ctx_y, dc_ctx) +
          vp8_i16_mode_bits[mode]
        let c = vp8_sse(src, yd, pred, yd, 16).to_int64() * 256L +
          lambda.to_int64() * r.to_int64()
        if c < best16_cost {
          best16_cost = c
          best16 = mode
        }
      }
      // --- Luma 4x4, reconstructing each subblock in turn.
      let save = yuv.copy()
      // The i4 flag and the extra mode bits (vs one i16 mode).
      let mut cost4 = lambda.to_int64() * (3L * 256L)
      let lv4 = FixedArray::make(16 * 16, 0)
      let last4 = FixedArray::make(16, -1)
      let tl = FixedArray::make(16, 0)
      let rank = Array::makei(10, fn(i) { i })
      let rank_cost = FixedArray::make(10, 0)
      load_ctx()
      for n in 0..<16 {
        let d = yd + (n & 3) * 4 + (n >> 2) * 128
        let bx = n & 3
        let by = n >> 2
        let ctx = ctx_y[bx] + ctx_y[4 + by]
        // Rank the modes by prediction error; the best few get the full
        // rate-distortion evaluation.
        for mode in 0..<10 {
          vp8_predict4(pred, d, mode)
          let e = vp8_sse(src, d, pred, d, 4) * 256 +
            lambda * vp8_bmode_paths[mode].length() * 256
          rank_cost[mode] = e
          rank[mode] = mode
        }
        rank.sort_by(fn(a, b) { rank_cost[a] - rank_cost[b] })
        let mut best = 0
        let mut best_cost = 0x7fffffffffffffffL
        for ri in 0..<vp8_i4_candidates {
          let mode = rank[ri]
          vp8_predict4(pred, d, mode)
          coeffs.fill(0)
          vp8_fdct(src, d, pred, d, coeffs, 0)
          let last = vp8_quantize(coeffs, 0, y1_dc, y1_ac, 0, tl, 0)
          if last >= 0 {
            vp8_transform(coeffs, 0, pred, d)
          }
          let r = vp8_token_cost(tl, 0, 3, ctx, 0, last) +
            vp8_bmode_paths[mode].length() * 256
          let c = vp8_sse(src, d, pred, d, 4).to_int64() * 256L +
            lambda.to_int64() * r.to_int64()
          if c < best_cost {
            best_cost = c
            best = mode
          }
        }
        imodes[n] = best
        cost4 += best_cost
        vp8_predict4(yuv, d, best)
        coeffs.fill(0)
        vp8_fdct(src, d, yuv, d, coeffs, 0)
        last4[n] = vp8_quantize(coeffs, 0, y1_dc, y1_ac, 0, lv4, n * 16)
        if last4[n] >= 0 {
          vp8_transform(coeffs, 0, yuv, d)
        }
        let f = if last4[n] >= 0 { 1 } else { 0 }
        ctx_y[bx] = f
        ctx_y[4 + by] = f
        // Later subblocks predict from this reconstruction.
        for yy in 0..<4 {
          for xx in 0..<4 {
            pred[d + yy * 32 + xx] = yuv[d + yy * 32 + xx]
          }
        }
        if cost4 >= best16_cost {
          break
        }
      }
      let use_i4 = cost4 < best16_cost
      if !use_i4 {
        save.blit_to(yuv, len=yuv.length())
      }
      levels.fill(0)
      lasts.fill(-1)
      if use_i4 {
        for n in 0..<16 {
          for k in 0..<16 {
            levels[(n + 1) * 16 + k] = lv4[n * 16 + k]
          }
          lasts[n + 1] = last4[n]
        }
      } else {
        vp8_predict_block(yuv, yd, 16, vp8_check_mode(mb_x, mb_y, best16))
        vp8_code_i16(src, yuv, yd, qm, levels, lasts, ws)
      }
      // --- Chroma (U and V share the mode).
      let ruv = vp8_rank_modes(4, fn(mode) {
        let m = vp8_check_mode(mb_x, mb_y, mode)
        vp8_predict_block(pred, ud, 8, m)
        vp8_predict_block(pred, vd, 8, m)
        vp8_sse(src, ud, pred, ud, 8) + vp8_sse(src, vd, pred, vd, 8)
      })
      let mut best_uv = 0
      let mut best_uv_cost = 0x7fffffffffffffffL
      for ri in 0..<vp8_mode_candidates {
        let mode = ruv[ri]
        let m = vp8_check_mode(mb_x, mb_y, mode)
        vp8_predict_block(pred, ud, 8, m)
        vp8_predict_block(pred, vd, 8, m)
        vp8_code_uv(src, pred, qm, tlevels, tlasts, ws)
        let r = vp8_cost_uv(tlevels, tlasts, top_nz, left_nz, mb_x) +
          vp8_uv_mode_bits[mode]
        let dist = vp8_sse(src, ud, pred, ud, 8) + vp8_sse(src, vd, pred, vd, 8)
        let c = dist.to_int64() * 256L + lambda.to_int64() * r.to_int64()
        if c < best_uv_cost {
          best_uv_cost = c
          best_uv = mode
        }
      }
      let muv = vp8_check_mode(mb_x, mb_y, best_uv)
      vp8_predict_block(yuv, ud, 8, muv)
      vp8_predict_block(yuv, vd, 8, muv)
      vp8_code_uv(src, yuv, qm, levels, lasts, ws)
      // --- Tokens (skip when nothing is coded).
      let first_y = if use_i4 { 0 } else { 1 }
      let mut coded = false
      for b in 0..<25 {
        if b == 0 && use_i4 {
          continue
        }
        if lasts[b] >= (if b >= 1 && b <= 16 { first_y } else { 0 }) {
          coded = true
        }
      }
      let skip = !coded
      if skip {
        // Decoder: skipped macroblocks reset the contexts.
        for k in 0..<8 {
          top_nz[mb_x * 9 + k] = 0
          left_nz[k] = 0
        }
        if !use_i4 {
          top_nz[mb_x * 9 + 8] = 0
          left_nz[8] = 0
        }
      } else {
        if !use_i4 {
          let ctx = top_nz[mb_x * 9 + 8] + left_nz[8]
          let nz = vp8_put_coeffs(events, 1, ctx, levels, 0, 0, lasts[0])
          let f = if nz { 1 } else { 0 }
          top_nz[mb_x * 9 + 8] = f
          left_nz[8] = f
        }
        let ty = if use_i4 { 3 } else { 0 }
        for n in 0..<16 {
          let bx = n & 3
          let by = n >> 2
          let ctx = top_nz[mb_x * 9 + bx] + left_nz[by]
          let last = if lasts[n + 1] >= first_y { lasts[n + 1] } else { -1 }
          let nz = vp8_put_coeffs(
            events,
            ty,
            ctx,
            levels,
            (n + 1) * 16,
            first_y,
            last,
          )
          let f = if nz { 1 } else { 0 }
          top_nz[mb_x * 9 + bx] = f
          left_nz[by] = f
        }
        for k in 0..<8 {
          let ch = k >> 2 // 0 = U, 1 = V
          let kk = k & 3
          let bx = kk & 1
          let by = kk >> 1
          let ti = mb_x * 9 + 4 + ch * 2 + bx
          let li = 4 + ch * 2 + by
          let ctx = top_nz[ti] + left_nz[li]
          let nz = vp8_put_coeffs(
            events,
            2,
            ctx,
            levels,
            (17 + k) * 16,
            0,
            lasts[17 + k],
          )
          let f = if nz { 1 } else { 0 }
          top_nz[ti] = f
          left_nz[li] = f
        }
      }
      // Mode data is written once the skip probability is known.
      mb_info.push((use_i4, best16, imodes.copy(), best_uv, skip))
      // Stash the unfiltered bottom row for the next macroblock row.
      if mb_y < mb_h - 1 {
        for i in 0..<16 {
          top[tb + i] = yuv[yd + 15 * 32 + i]
        }
        for i in 0..<8 {
          top[tb + 16 + i] = yuv[ud + 7 * 32 + i]
          top[tb + 24 + i] = yuv[vd + 7 * 32 + i]
        }
      }
    }
  }
  // Frame header + per-macroblock modes (partition 0).
  let mut skipped = 0
  for m in mb_info {
    if m.4 {
      skipped += 1
    }
  }
  let total = mb_info.length()
  let skip_p = vp8_clip(255 - skipped * 255 / total, 255)
  let skip_p = if skip_p < 1 { 1 } else { skip_p }
  let use_skip = skipped > 0
  let bw = modes_bw
  ignore(bw.put_bit(false, 0x80)) // color space
  ignore(bw.put_bit(false, 0x80)) // clamping
  ignore(bw.put_bit(false, 0x80)) // no segmentation
  ignore(bw.put_bit(false, 0x80)) // normal loop filter
  let level = vp8_clip(q * 2 / 5 + (if q > 0 { 2 } else { 0 }), 63)
  bw.put_bits(level, 6)
  bw.put_bits(0, 3) // sharpness
  ignore(bw.put_bit(false, 0x80)) // no loop filter deltas
  bw.put_bits(0, 2) // one token partition
  bw.put_bits(q, 7)
  for _ in 0..<5 {
    bw.put_signed(0, 4)
  }
  ignore(bw.put_bit(false, 0x80)) // refresh entropy probabilities
  // Token probabilities: update those whose savings beat the update cost.
  let n0 = FixedArray::make(1056, 0)
  let n1 = FixedArray::make(1056, 0)
  for e in events {
    let code = e >> 1
    if code < 1056 {
      if (e & 1) == 1 {
        n1[code] += 1
      } else {
        n0[code] += 1
      }
    }
  }
  let proba = vp8_coeffs_proba0.copy()
  for i in 0..<1056 {
    let total = n0[i] + n1[i]
    let up = vp8_coeffs_update_proba[i]
    let mut updated = false
    if total > 0 {
      let np = vp8_clip(255 - n1[i] * 255 / total, 255)
      let np = if np < 1 { 1 } else { np }
      let old = proba[i]
      let old_cost = n0[i] * vp8_bit_cost(false, old) +
        n1[i] * vp8_bit_cost(true, old) +
        vp8_bit_cost(false, up)
      let new_cost = n0[i] * vp8_bit_cost(false, np) +
        n1[i] * vp8_bit_cost(true, np) +
        vp8_bit_cost(true, up) +
        8 * 256
      if np != old && new_cost < old_cost {
        ignore(bw.put_bit(true, up))
        bw.put_bits(np, 8)
        proba[i] = np
        updated = true
      }
    }
    if !updated {
      ignore(bw.put_bit(false, up))
    }
  }
  ignore(bw.put_bit(use_skip, 0x80))
  if use_skip {
    bw.put_bits(skip_p, 8)
  }
  // Modes, replaying the decoder's 4x4 mode contexts.
  let it = FixedArray::make(4 * mb_w, 0)
  let il = FixedArray::make(4, 0)
  for i, m in mb_info {
    let mb_x = i % mb_w
    if mb_x == 0 {
      il.fill(0)
    }
    let (use_i4, m16, m4, muv, skip) = m
    if use_skip {
      ignore(bw.put_bit(skip, skip_p))
    }
    ignore(bw.put_bit(!use_i4, 145))
    if !use_i4 {
      match m16 {
        0 => {
          ignore(bw.put_bit(false, 156))
          ignore(bw.put_bit(false, 163))
        }
        2 => {
          ignore(bw.put_bit(false, 156))
          ignore(bw.put_bit(true, 163))
        }
        3 => {
          ignore(bw.put_bit(true, 156))
          ignore(bw.put_bit(false, 128))
        }
        _ => {
          ignore(bw.put_bit(true, 156))
          ignore(bw.put_bit(true, 128))
        }
      }
      for k in 0..<4 {
        it[mb_x * 4 + k] = m16
        il[k] = m16
      }
    } else {
      for y in 0..<4 {
        let mut left = il[y]
        for x in 0..<4 {
          let mode = m4[y * 4 + x]
          let prob = (it[mb_x * 4 + x] * 10 + left) * 9
          for step in vp8_bmode_paths[mode] {
            ignore(bw.put_bit(step.1 == 1, vp8_bmodes_proba[prob + step.0]))
          }
          it[mb_x * 4 + x] = mode
          left = mode
        }
        il[y] = left
      }
    }
    match muv {
      0 => ignore(bw.put_bit(false, 142))
      2 => {
        ignore(bw.put_bit(true, 142))
        ignore(bw.put_bit(false, 114))
      }
      1 => {
        ignore(bw.put_bit(true, 142))
        ignore(bw.put_bit(true, 114))
        ignore(bw.put_bit(true, 183))
      }
      _ => {
        ignore(bw.put_bit(true, 142))
        ignore(bw.put_bit(true, 114))
        ignore(bw.put_bit(false, 183))
      }
    }
  }
  let part0 = bw.finish()
  let tokens_bw = VP8BoolWriter::new()
  for e in events {
    let code = e >> 1
    let prob = if code < 1056 { proba[code] } else { code - 1056 }
    ignore(tokens_bw.put_bit((e & 1) == 1, prob))
  }
  let part1 = tokens_bw.finish()
  // Frame tag, start code, dimensions.
  let out = Buffer()
  let tag = (part0.length() << 5) | 0x10 // key frame, profile 0, shown
  out.write_byte(tag.to_byte())
  out.write_byte((tag >> 8).to_byte())
  out.write_byte((tag >> 16).to_byte())
  out.write_byte(b'\x9d')
  out.write_byte(b'\x01')
  out.write_byte(b'\x2a')
  out.write_byte(w.to_byte())
  out.write_byte((w >> 8).to_byte())
  out.write_byte(h.to_byte())
  out.write_byte((h >> 8).to_byte())
  out.write_bytes(part0)
  out.write_bytes(part1)
  out.to_bytes()
}
