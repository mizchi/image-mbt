// JPEG decode back end matching libjpeg / libjpeg-turbo:
// - "islow" accurate integer IDCT (jidctint.c, Loeffler-Ligtenberg-Moschytz)
// - "fancy" triangle-filter chroma upsampling (jdsample.c)
// - fixed-point YCbCr -> RGB conversion (jdcolor.c)
// With these, decoded pixels are identical to libjpeg's default output.

///|
const IDCT_CONST_BITS : Int32 = 13

///|
const IDCT_PASS1_BITS : Int32 = 2

///|
const FIX_0_298631336 : Int32 = 2446

///|
const FIX_0_390180644 : Int32 = 3196

///|
const FIX_0_541196100 : Int32 = 4433

///|
const FIX_0_765366865 : Int32 = 6270

///|
const FIX_0_899976223 : Int32 = 7373

///|
const FIX_1_175875602 : Int32 = 9633

///|
const FIX_1_501321110 : Int32 = 12299

///|
const FIX_1_847759065 : Int32 = 15137

///|
const FIX_1_961570560 : Int32 = 16069

///|
const FIX_2_053119869 : Int32 = 16819

///|
const FIX_2_562915447 : Int32 = 20995

///|
const FIX_3_072711026 : Int32 = 25172

///|
fn idct_descale(x : Int32, n : Int32) -> Int32 {
  (x + (1 << (n - 1))) >> n
}

///|
fn idct_clamp(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
/// Inverse DCT of one dequantized 8x8 block (natural order) into
/// `out[off + y * stride + x]`, clamped to 0..255. `ws` is a 64-entry
/// workspace. (On wasm, jpeg_idct_simd.mbt is used instead; this stays the
/// reference for its differential test.)
#warnings("-unused_value")
fn jpeg_idct_islow(
  coef : FixedArray[Int32],
  ws : FixedArray[Int32],
  out : FixedArray[Int32],
  off : Int32,
  stride : Int32,
) -> Unit {
  // Pass 1: columns, results scaled up by 2^PASS1_BITS.
  for col in 0..<8 {
    if coef[8 + col] == 0 &&
      coef[16 + col] == 0 &&
      coef[24 + col] == 0 &&
      coef[32 + col] == 0 &&
      coef[40 + col] == 0 &&
      coef[48 + col] == 0 &&
      coef[56 + col] == 0 {
      let dc = coef[col] << IDCT_PASS1_BITS
      for r in 0..<8 {
        ws[r * 8 + col] = dc
      }
      continue
    }
    // Even part
    let z2 = coef[16 + col]
    let z3 = coef[48 + col]
    let z1 = (z2 + z3) * FIX_0_541196100
    let tmp2 = z1 + z3 * -FIX_1_847759065
    let tmp3 = z1 + z2 * FIX_0_765366865
    let z2 = coef[col]
    let z3 = coef[32 + col]
    let tmp0 = (z2 + z3) << IDCT_CONST_BITS
    let tmp1 = (z2 - z3) << IDCT_CONST_BITS
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    // Odd part
    let t0 = coef[56 + col]
    let t1 = coef[40 + col]
    let t2 = coef[24 + col]
    let t3 = coef[8 + col]
    let z1 = t0 + t3
    let z2 = t1 + t2
    let z3 = t0 + t2
    let z4 = t1 + t3
    let z5 = (z3 + z4) * FIX_1_175875602
    let z1 = z1 * -FIX_0_899976223
    let z2 = z2 * -FIX_2_562915447
    let z3 = z3 * -FIX_1_961570560 + z5
    let z4 = z4 * -FIX_0_390180644 + z5
    let t0 = t0 * FIX_0_298631336 + z1 + z3
    let t1 = t1 * FIX_2_053119869 + z2 + z4
    let t2 = t2 * FIX_3_072711026 + z2 + z3
    let t3 = t3 * FIX_1_501321110 + z1 + z4
    let n = IDCT_CONST_BITS - IDCT_PASS1_BITS
    ws[col] = idct_descale(tmp10 + t3, n)
    ws[56 + col] = idct_descale(tmp10 - t3, n)
    ws[8 + col] = idct_descale(tmp11 + t2, n)
    ws[48 + col] = idct_descale(tmp11 - t2, n)
    ws[16 + col] = idct_descale(tmp12 + t1, n)
    ws[40 + col] = idct_descale(tmp12 - t1, n)
    ws[24 + col] = idct_descale(tmp13 + t0, n)
    ws[32 + col] = idct_descale(tmp13 - t0, n)
  }
  // Pass 2: rows, descale by 2^(PASS1_BITS + 3) and add the 128 offset.
  let n = IDCT_CONST_BITS + IDCT_PASS1_BITS + 3
  for row in 0..<8 {
    let w = row * 8
    let o = off + row * stride
    if ws[w + 1] == 0 &&
      ws[w + 2] == 0 &&
      ws[w + 3] == 0 &&
      ws[w + 4] == 0 &&
      ws[w + 5] == 0 &&
      ws[w + 6] == 0 &&
      ws[w + 7] == 0 {
      let v = idct_clamp(idct_descale(ws[w], IDCT_PASS1_BITS + 3) + 128)
      for x in 0..<8 {
        out[o + x] = v
      }
      continue
    }
    // Even part
    let z2 = ws[w + 2]
    let z3 = ws[w + 6]
    let z1 = (z2 + z3) * FIX_0_541196100
    let tmp2 = z1 + z3 * -FIX_1_847759065
    let tmp3 = z1 + z2 * FIX_0_765366865
    let tmp0 = (ws[w] + ws[w + 4]) << IDCT_CONST_BITS
    let tmp1 = (ws[w] - ws[w + 4]) << IDCT_CONST_BITS
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    // Odd part
    let t0 = ws[w + 7]
    let t1 = ws[w + 5]
    let t2 = ws[w + 3]
    let t3 = ws[w + 1]
    let z1 = t0 + t3
    let z2 = t1 + t2
    let z3 = t0 + t2
    let z4 = t1 + t3
    let z5 = (z3 + z4) * FIX_1_175875602
    let z1 = z1 * -FIX_0_899976223
    let z2 = z2 * -FIX_2_562915447
    let z3 = z3 * -FIX_1_961570560 + z5
    let z4 = z4 * -FIX_0_390180644 + z5
    let t0 = t0 * FIX_0_298631336 + z1 + z3
    let t1 = t1 * FIX_2_053119869 + z2 + z4
    let t2 = t2 * FIX_3_072711026 + z2 + z3
    let t3 = t3 * FIX_1_501321110 + z1 + z4
    out[o] = idct_clamp(idct_descale(tmp10 + t3, n) + 128)
    out[o + 7] = idct_clamp(idct_descale(tmp10 - t3, n) + 128)
    out[o + 1] = idct_clamp(idct_descale(tmp11 + t2, n) + 128)
    out[o + 6] = idct_clamp(idct_descale(tmp11 - t2, n) + 128)
    out[o + 2] = idct_clamp(idct_descale(tmp12 + t1, n) + 128)
    out[o + 5] = idct_clamp(idct_descale(tmp12 - t1, n) + 128)
    out[o + 3] = idct_clamp(idct_descale(tmp13 + t0, n) + 128)
    out[o + 4] = idct_clamp(idct_descale(tmp13 - t0, n) + 128)
  }
}

///|
/// Upsample one component plane to `out_w` x `out_h` (row-major, stride
/// `out_w`). `src` holds `in_w` x `in_h` real samples with row stride
/// `stride` (the buffer may be wider, MCU-padded). The component has
/// sampling factors `h` x `v` out of `max_h` x `max_v`.
///
/// Like libjpeg-turbo's jinit_upsampler: 2x1 and 2x2 use the fancy filters
/// when the downsampled width is > 2, 1x2 always does, other integral
/// ratios use box replication. Non-integral ratios (rejected by libjpeg)
/// fall back to nearest-neighbor mapping.
fn jpeg_upsample(
  src : FixedArray[Int32],
  stride : Int32,
  in_w : Int32,
  in_h : Int32,
  h : Int32,
  v : Int32,
  max_h : Int32,
  max_v : Int32,
  out_w : Int32,
  out_h : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(out_w * out_h, 0)
  if max_h % h != 0 || max_v % v != 0 {
    for oy in 0..<out_h {
      let r = oy * v / max_v * stride
      for ox in 0..<out_w {
        out[oy * out_w + ox] = src[r + ox * h / max_h]
      }
    }
    return out
  }
  let hr = max_h / h
  let vr = max_v / v
  let fancy_h = hr == 2 && in_w > 2
  // Row of `src` clamped to the real rows (libjpeg replicates the first /
  // last sample row as context at the image edges).
  let src_row = fn(r : Int32) -> Int32 {
    let r = if r < 0 { 0 } else if r >= in_h { in_h - 1 } else { r }
    r * stride
  }
  // A full upsampled row (2 * in_w samples), cut to out_w.
  let row_buf = FixedArray::make(stride * hr + 2, 0)
  for oy in 0..<out_h {
    let iy = oy / vr
    if fancy_h && vr == 2 {
      // h2v2 fancy: vertical 3:1 blend with the nearer neighbor row, then
      // horizontal 3:1 blend (jdsample.c h2v2_fancy_upsample).
      let r0 = src_row(iy)
      let r1 = if oy % 2 == 0 { src_row(iy - 1) } else { src_row(iy + 1) }
      let colsum = fn(c : Int32) { src[r0 + c] * 3 + src[r1 + c] }
      let mut this = colsum(0)
      let mut next = colsum(1)
      row_buf[0] = (this * 4 + 8) >> 4
      row_buf[1] = (this * 3 + next + 7) >> 4
      let mut last = this
      this = next
      let mut o = 2
      for c in 2..<in_w {
        next = colsum(c)
        row_buf[o] = (this * 3 + last + 8) >> 4
        row_buf[o + 1] = (this * 3 + next + 7) >> 4
        o += 2
        last = this
        this = next
      }
      row_buf[o] = (this * 3 + last + 8) >> 4
      row_buf[o + 1] = (this * 4 + 7) >> 4
    } else if fancy_h && vr == 1 {
      // h2v1 fancy (jdsample.c h2v1_fancy_upsample)
      let r0 = src_row(iy)
      let mut v = src[r0]
      row_buf[0] = v
      row_buf[1] = (v * 3 + src[r0 + 1] + 2) >> 2
      let mut o = 2
      for c in 1..<(in_w - 1) {
        v = src[r0 + c] * 3
        row_buf[o] = (v + src[r0 + c - 1] + 1) >> 2
        row_buf[o + 1] = (v + src[r0 + c + 1] + 2) >> 2
        o += 2
      }
      if in_w > 1 {
        v = src[r0 + in_w - 1]
        row_buf[o] = (v * 3 + src[r0 + in_w - 2] + 1) >> 2
        row_buf[o + 1] = v
      }
    } else if hr == 1 && vr == 2 {
      // h1v2 fancy (jdsample.c h1v2_fancy_upsample)
      let r0 = src_row(iy)
      let (r1, bias) = if oy % 2 == 0 {
        (src_row(iy - 1), 1)
      } else {
        (src_row(iy + 1), 2)
      }
      for c in 0..<in_w {
        row_buf[c] = (src[r0 + c] * 3 + src[r1 + c] + bias) >> 2
      }
    } else {
      // Integral box replication (jdsample.c int_upsample), incl. 1:1.
      let r0 = src_row(iy)
      for x in 0..<out_w {
        row_buf[x] = src[r0 + x / hr]
      }
    }
    row_buf.blit_to(out, len=out_w, dst_offset=oy * out_w)
  }
  out
}

///|
/// libjpeg's YCbCr -> RGB tables (jdcolor.c build_ycc_rgb_table),
/// SCALEBITS = 16.
priv struct JpegYccTables {
  cr_r : FixedArray[Int32]
  cb_b : FixedArray[Int32]
  cr_g : FixedArray[Int32]
  cb_g : FixedArray[Int32]
}

///|
let jpeg_ycc_tables : JpegYccTables = {
  let fix = fn(x : Double) { (x * 65536.0 + 0.5).to_int() }
  let one_half = 1 << 15
  {
    cr_r: FixedArray::makei(256, fn(i) {
      (fix(1.40200) * (i - 128) + one_half) >> 16
    }),
    cb_b: FixedArray::makei(256, fn(i) {
      (fix(1.77200) * (i - 128) + one_half) >> 16
    }),
    cr_g: FixedArray::makei(256, fn(i) { -fix(0.71414) * (i - 128) }),
    cb_g: FixedArray::makei(256, fn(i) { -fix(0.34414) * (i - 128) + one_half }),
  }
}
