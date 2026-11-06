// JPEG encode front end matching libjpeg / libjpeg-turbo:
// - fixed-point RGB -> YCbCr (jccolor.c)
// - h2v1 / h2v2 chroma downsampling with alternating rounding bias
//   (jcsample.c)
// - "islow" accurate integer forward DCT (jfdctint.c) and rounding
//   quantization (jcdctmgr.c)

///|
/// libjpeg's RGB -> YCbCr tables (jccolor.c rgb_ycc_start), SCALEBITS = 16.
priv struct JpegRgbYccTables {
  r_y : FixedArray[Int32]
  g_y : FixedArray[Int32]
  b_y : FixedArray[Int32]
  r_cb : FixedArray[Int32]
  g_cb : FixedArray[Int32]
  b_cb : FixedArray[Int32] // also R_CR
  g_cr : FixedArray[Int32]
  b_cr : FixedArray[Int32]
}

///|
let jpeg_rgb_ycc_tables : JpegRgbYccTables = {
  let fix = fn(x : Double) { (x * 65536.0 + 0.5).to_int() }
  let one_half = 1 << 15
  let cbcr_offset = 128 << 16
  {
    r_y: FixedArray::makei(256, fn(i) { fix(0.29900) * i }),
    g_y: FixedArray::makei(256, fn(i) { fix(0.58700) * i }),
    b_y: FixedArray::makei(256, fn(i) { fix(0.11400) * i + one_half }),
    r_cb: FixedArray::makei(256, fn(i) { -fix(0.16874) * i }),
    g_cb: FixedArray::makei(256, fn(i) { -fix(0.33126) * i }),
    // B => Cb and R => Cr use the same table; ONE_HALF - 1 keeps the
    // maximum at 255.
    b_cb: FixedArray::makei(256, fn(i) {
      fix(0.5) * i + cbcr_offset + one_half - 1
    }),
    g_cr: FixedArray::makei(256, fn(i) { -fix(0.41869) * i }),
    b_cr: FixedArray::makei(256, fn(i) { -fix(0.08131) * i }),
  }
}

///|
/// Convert RGBA8 pixels to full-resolution Y, Cb, Cr planes.
fn jpeg_rgb_to_ycc(
  data : Bytes,
  count : Int32,
) -> (FixedArray[Int32], FixedArray[Int32], FixedArray[Int32]) {
  let t = jpeg_rgb_ycc_tables
  let y = FixedArray::make(count, 0)
  let cb = FixedArray::make(count, 0)
  let cr = FixedArray::make(count, 0)
  for i in 0..<count {
    let r = data[i * 4].to_int()
    let g = data[i * 4 + 1].to_int()
    let b = data[i * 4 + 2].to_int()
    y[i] = (t.r_y[r] + t.g_y[g] + t.b_y[b]) >> 16
    cb[i] = (t.r_cb[r] + t.g_cb[g] + t.b_cb[b]) >> 16
    cr[i] = (t.b_cb[r] + t.g_cr[g] + t.b_cr[b]) >> 16
  }
  (y, cb, cr)
}

///|
/// Downsample a full-resolution `width` x `height` plane by `hr` x `vr`
/// (1 or 2 each) into `out_w` x `out_h` samples. Like libjpeg, the source is
/// extended by replicating its last column / row (expand_right_edge /
/// expand_bottom_edge), and 2:1 averages use a bias that alternates per
/// output column (h2v1: 0, 1, ...; h2v2: 1, 2, ...).
fn jpeg_downsample(
  src : FixedArray[Int32],
  width : Int32,
  height : Int32,
  hr : Int32,
  vr : Int32,
  out_w : Int32,
  out_h : Int32,
) -> FixedArray[Int32] {
  let out = FixedArray::make(out_w * out_h, 0)
  let col = fn(x : Int32) { if x < width { x } else { width - 1 } }
  let row = fn(y : Int32) {
    if y < height {
      y * width
    } else {
      (height - 1) * width
    }
  }
  for oy in 0..<out_h {
    let o = oy * out_w
    if hr == 1 && vr == 1 {
      let r = row(oy)
      for ox in 0..<out_w {
        out[o + ox] = src[r + col(ox)]
      }
    } else if vr == 1 {
      // h2v1
      let r = row(oy)
      for ox in 0..<out_w {
        let bias = ox & 1
        out[o + ox] = (src[r + col(ox * 2)] + src[r + col(ox * 2 + 1)] + bias) >>
          1
      }
    } else {
      // h2v2
      let r0 = row(oy * 2)
      let r1 = row(oy * 2 + 1)
      for ox in 0..<out_w {
        let c0 = col(ox * 2)
        let c1 = col(ox * 2 + 1)
        let bias = 1 + (ox & 1)
        out[o + ox] = (
            src[r0 + c0] + src[r0 + c1] + src[r1 + c0] + src[r1 + c1] + bias
          ) >>
          2
      }
    }
  }
  out
}

///|
/// Forward DCT of one 8x8 block of level-shifted samples (natural order), in
/// place. The output is scaled up by 8 (jfdctint.c). (On wasm,
/// jpeg_fdct_simd.mbt is used instead; this stays the reference for its
/// differential test.)
#warnings("-unused_value")
fn jpeg_fdct_islow(data : FixedArray[Int32]) -> Unit {
  // Pass 1: rows, results scaled up by 2^PASS1_BITS.
  for r in 0..<8 {
    let p = r * 8
    let tmp0 = data[p] + data[p + 7]
    let tmp7 = data[p] - data[p + 7]
    let tmp1 = data[p + 1] + data[p + 6]
    let tmp6 = data[p + 1] - data[p + 6]
    let tmp2 = data[p + 2] + data[p + 5]
    let tmp5 = data[p + 2] - data[p + 5]
    let tmp3 = data[p + 3] + data[p + 4]
    let tmp4 = data[p + 3] - data[p + 4]
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    data[p] = (tmp10 + tmp11) << IDCT_PASS1_BITS
    data[p + 4] = (tmp10 - tmp11) << IDCT_PASS1_BITS
    let n = IDCT_CONST_BITS - IDCT_PASS1_BITS
    let z1 = (tmp12 + tmp13) * FIX_0_541196100
    data[p + 2] = idct_descale(z1 + tmp13 * FIX_0_765366865, n)
    data[p + 6] = idct_descale(z1 + tmp12 * -FIX_1_847759065, n)
    let z1 = tmp4 + tmp7
    let z2 = tmp5 + tmp6
    let z3 = tmp4 + tmp6
    let z4 = tmp5 + tmp7
    let z5 = (z3 + z4) * FIX_1_175875602
    let z1 = z1 * -FIX_0_899976223
    let z2 = z2 * -FIX_2_562915447
    let z3 = z3 * -FIX_1_961570560 + z5
    let z4 = z4 * -FIX_0_390180644 + z5
    data[p + 7] = idct_descale(tmp4 * FIX_0_298631336 + z1 + z3, n)
    data[p + 5] = idct_descale(tmp5 * FIX_2_053119869 + z2 + z4, n)
    data[p + 3] = idct_descale(tmp6 * FIX_3_072711026 + z2 + z3, n)
    data[p + 1] = idct_descale(tmp7 * FIX_1_501321110 + z1 + z4, n)
  }
  // Pass 2: columns, remove the PASS1_BITS scaling (output stays x8).
  for c in 0..<8 {
    let tmp0 = data[c] + data[56 + c]
    let tmp7 = data[c] - data[56 + c]
    let tmp1 = data[8 + c] + data[48 + c]
    let tmp6 = data[8 + c] - data[48 + c]
    let tmp2 = data[16 + c] + data[40 + c]
    let tmp5 = data[16 + c] - data[40 + c]
    let tmp3 = data[24 + c] + data[32 + c]
    let tmp4 = data[24 + c] - data[32 + c]
    let tmp10 = tmp0 + tmp3
    let tmp13 = tmp0 - tmp3
    let tmp11 = tmp1 + tmp2
    let tmp12 = tmp1 - tmp2
    data[c] = idct_descale(tmp10 + tmp11, IDCT_PASS1_BITS)
    data[32 + c] = idct_descale(tmp10 - tmp11, IDCT_PASS1_BITS)
    let n = IDCT_CONST_BITS + IDCT_PASS1_BITS
    let z1 = (tmp12 + tmp13) * FIX_0_541196100
    data[16 + c] = idct_descale(z1 + tmp13 * FIX_0_765366865, n)
    data[48 + c] = idct_descale(z1 + tmp12 * -FIX_1_847759065, n)
    let z1 = tmp4 + tmp7
    let z2 = tmp5 + tmp6
    let z3 = tmp4 + tmp6
    let z4 = tmp5 + tmp7
    let z5 = (z3 + z4) * FIX_1_175875602
    let z1 = z1 * -FIX_0_899976223
    let z2 = z2 * -FIX_2_562915447
    let z3 = z3 * -FIX_1_961570560 + z5
    let z4 = z4 * -FIX_0_390180644 + z5
    data[56 + c] = idct_descale(tmp4 * FIX_0_298631336 + z1 + z3, n)
    data[40 + c] = idct_descale(tmp5 * FIX_2_053119869 + z2 + z4, n)
    data[24 + c] = idct_descale(tmp6 * FIX_3_072711026 + z2 + z3, n)
    data[8 + c] = idct_descale(tmp7 * FIX_1_501321110 + z1 + z4, n)
  }
}

///|
/// Quantization divisors for one table, in zigzag order: the islow FDCT
/// output is scaled by 8, so the divisor is `quant << 3`.
priv struct JpegQuantDivisors {
  /// Natural-order index of each zigzag position.
  natural : FixedArray[Int32]
  divisor : FixedArray[Int32]
}

///|
fn JpegQuantDivisors::new(quant : FixedArray[Int32]) -> JpegQuantDivisors {
  {
    natural: FixedArray::makei(64, fn(k) { jpeg_zigzag[k] }),
    divisor: FixedArray::makei(64, fn(k) { quant[jpeg_zigzag[k]] << 3 }),
  }
}

///|
/// Quantize DCT output (natural order, scaled by 8) into `out` in zigzag
/// order, rounding half away from zero like libjpeg's jcdctmgr.c:
/// `(|v| + d/2) / d` with the sign restored.
fn jpeg_quantize(
  data : FixedArray[Int32],
  div : JpegQuantDivisors,
  out : FixedArray[Int32],
) -> Unit {
  for k in 0..<64 {
    let v = data[div.natural[k]]
    let d = div.divisor[k]
    out[k] = if v < 0 { -((-v + (d >> 1)) / d) } else { (v + (d >> 1)) / d }
  }
}
