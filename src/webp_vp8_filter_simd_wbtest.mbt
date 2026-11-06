// wasm only: the SIMD loop filter kernels must match the scalar filters
// (a copy of webp_vp8_filter_scalar.mbt, renamed ref_*) bit for bit.

///|
fn ref_vp8_lf_luma(
  p : FixedArray[Byte],
  i : Int32,
  vertical : Bool,
  stride : Int32,
  thresh : Int32,
  ithresh : Int32,
  hev : Int32,
  edge : Bool,
) -> Unit {
  if vertical {
    ref_vp8_filter_loop(p, i, stride, 1, 16, thresh, ithresh, hev, edge)
  } else {
    ref_vp8_filter_loop(p, i, 1, stride, 16, thresh, ithresh, hev, edge)
  }
}

///|
fn ref_vp8_lf_chroma(
  u : FixedArray[Byte],
  v : FixedArray[Byte],
  i : Int32,
  vertical : Bool,
  stride : Int32,
  thresh : Int32,
  ithresh : Int32,
  hev : Int32,
  edge : Bool,
) -> Unit {
  let (hs, vs) = if vertical { (stride, 1) } else { (1, stride) }
  ref_vp8_filter_loop(u, i, hs, vs, 8, thresh, ithresh, hev, edge)
  ref_vp8_filter_loop(v, i, hs, vs, 8, thresh, ithresh, hev, edge)
}

///|
fn ref_vp8_lf_simple(
  p : FixedArray[Byte],
  i : Int32,
  vertical : Bool,
  stride : Int32,
  thresh : Int32,
) -> Unit {
  if vertical {
    ref_vp8_simple_filter(p, i, stride, 1, thresh)
  } else {
    ref_vp8_simple_filter(p, i, 1, stride, thresh)
  }
}

///|
fn ref_vp8_sclip1(v : Int32) -> Int32 {
  if v < -128 {
    -128
  } else if v > 127 {
    127
  } else {
    v
  }
}

///|
fn ref_vp8_sclip2(v : Int32) -> Int32 {
  if v < -16 {
    -16
  } else if v > 15 {
    15
  } else {
    v
  }
}

///|
fn ref_vp8_do_filter2(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let a = 3 * (q0 - p0) + ref_vp8_sclip1(p1 - q1)
  let a1 = ref_vp8_sclip2((a + 4) >> 3)
  let a2 = ref_vp8_sclip2((a + 3) >> 3)
  p[i - step] = vp8_clip8(p0 + a2).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
}

///|
fn ref_vp8_do_filter4(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let a = 3 * (q0 - p0)
  let a1 = ref_vp8_sclip2((a + 4) >> 3)
  let a2 = ref_vp8_sclip2((a + 3) >> 3)
  let a3 = (a1 + 1) >> 1
  p[i - 2 * step] = vp8_clip8(p1 + a3).to_byte()
  p[i - step] = vp8_clip8(p0 + a2).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
  p[i + step] = vp8_clip8(q1 - a3).to_byte()
}

///|
fn ref_vp8_do_filter6(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p2 = p[i - 3 * step].to_int()
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let q2 = p[i + 2 * step].to_int()
  let a = ref_vp8_sclip1(3 * (q0 - p0) + ref_vp8_sclip1(p1 - q1))
  let a1 = (27 * a + 63) >> 7
  let a2 = (18 * a + 63) >> 7
  let a3 = (9 * a + 63) >> 7
  p[i - 3 * step] = vp8_clip8(p2 + a3).to_byte()
  p[i - 2 * step] = vp8_clip8(p1 + a2).to_byte()
  p[i - step] = vp8_clip8(p0 + a1).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
  p[i + step] = vp8_clip8(q1 - a2).to_byte()
  p[i + 2 * step] = vp8_clip8(q2 - a3).to_byte()
}

///|
fn ref_vp8_hev(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  thresh : Int32,
) -> Bool {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  (p1 - p0).abs() > thresh || (q1 - q0).abs() > thresh
}

///|
fn ref_vp8_needs_filter(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  t : Int32,
) -> Bool {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  4 * (p0 - q0).abs() + (p1 - q1).abs() <= t
}

///|
fn ref_vp8_needs_filter2(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  t : Int32,
  it : Int32,
) -> Bool {
  let p3 = p[i - 4 * step].to_int()
  let p2 = p[i - 3 * step].to_int()
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let q2 = p[i + 2 * step].to_int()
  let q3 = p[i + 3 * step].to_int()
  if 4 * (p0 - q0).abs() + (p1 - q1).abs() > t {
    return false
  }
  (p3 - p2).abs() <= it &&
  (p2 - p1).abs() <= it &&
  (p1 - p0).abs() <= it &&
  (q3 - q2).abs() <= it &&
  (q2 - q1).abs() <= it &&
  (q1 - q0).abs() <= it
}

///|
fn ref_vp8_simple_filter(
  p : FixedArray[Byte],
  i : Int32,
  hstride : Int32,
  vstride : Int32,
  thresh : Int32,
) -> Unit {
  let t2 = 2 * thresh + 1
  for k in 0..<16 {
    let o = i + k * vstride
    if ref_vp8_needs_filter(p, o, hstride, t2) {
      ref_vp8_do_filter2(p, o, hstride)
    }
  }
}

///|
fn ref_vp8_filter_loop(
  p : FixedArray[Byte],
  i : Int32,
  hstride : Int32,
  vstride : Int32,
  size : Int32,
  thresh : Int32,
  ithresh : Int32,
  hev_thresh : Int32,
  edge : Bool,
) -> Unit {
  let t2 = 2 * thresh + 1
  for k in 0..<size {
    let o = i + k * vstride
    if ref_vp8_needs_filter2(p, o, hstride, t2, ithresh) {
      if ref_vp8_hev(p, o, hstride, hev_thresh) {
        ref_vp8_do_filter2(p, o, hstride)
      } else if edge {
        ref_vp8_do_filter6(p, o, hstride)
      } else {
        ref_vp8_do_filter4(p, o, hstride)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Frame decoding.

///|
test "vp8 SIMD loop filter matches the scalar filter" {
  let stride = 48
  let mut seed = 12345
  let rnd = fn() {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    (seed >> 16) & 0xff
  }
  for trial in 0..<300 {
    let a = FixedArray::make(stride * 40, b'\x00')
    // Noise with a growing amplitude, so every filter path triggers.
    let base = rnd()
    for i in 0..<a.length() {
      a[i] = (base + rnd() % (1 + trial % 60)).to_byte()
    }
    let a2 = a.copy()
    let b = a.copy()
    let b2 = a.copy()
    let thresh = rnd() % 64
    let it = rnd() % 24
    let hev = rnd() % 4
    let edge = trial % 2 == 0
    let i = 8 * stride + 16
    for vertical in [true, false] {
      vp8_lf_luma(a, i, vertical, stride, thresh, it, hev, edge)
      ref_vp8_lf_luma(b, i, vertical, stride, thresh, it, hev, edge)
      assert_true(a == b)
      vp8_lf_chroma(a, a2, i, vertical, stride, thresh, it, hev, edge)
      ref_vp8_lf_chroma(b, b2, i, vertical, stride, thresh, it, hev, edge)
      assert_true(a == b && a2 == b2)
      vp8_lf_simple(a, i, vertical, stride, thresh)
      ref_vp8_lf_simple(b, i, vertical, stride, thresh)
      assert_true(a == b)
    }
  }
  // With an impossible threshold nothing changes.
  let c = FixedArray::makei(stride * 40, fn(i) {
    (i * 7 + i / stride * 3).to_byte()
  })
  let d = c.copy()
  vp8_lf_v16_v128(c, 8 * stride + 16, stride, -1, 0, 0, 0)
  vp8_lf_h16_v128(c, 8 * stride + 16, stride, -1, 0, 0, 0)
  assert_true(c == d)
}
