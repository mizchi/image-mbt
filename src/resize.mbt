///|
fn clamp_int(v : Int32, lo : Int32, hi : Int32) -> Int32 {
  if v < lo {
    lo
  } else if v > hi {
    hi
  } else {
    v
  }
}

///|
fn cubic_weight(t : Double) -> Double {
  let a = -0.5
  let abs_t = if t < 0.0 { -t } else { t }
  if abs_t <= 1.0 {
    (a + 2.0) * abs_t * abs_t * abs_t - (a + 3.0) * abs_t * abs_t + 1.0
  } else if abs_t <= 2.0 {
    a * abs_t * abs_t * abs_t -
    5.0 * a * abs_t * abs_t +
    8.0 * a * abs_t -
    4.0 * a
  } else {
    0.0
  }
}

///|
fn resize_nearest(
  img : ImageData,
  new_width : Int32,
  new_height : Int32,
) -> ImageData {
  let src = img.data.to_fixedarray()
  let src_w = img.width
  let src_h = img.height
  let buf = FixedArray::make(new_width * new_height * 4, b'\x00')
  for dy in 0..<new_height {
    // (dy * 2 + 1) * src_h / (new_height * 2) = center-to-center mapping
    let sy = clamp_int((dy * 2 + 1) * src_h / (new_height * 2), 0, src_h - 1)
    let src_row = sy * src_w * 4
    for dx in 0..<new_width {
      let sx = clamp_int((dx * 2 + 1) * src_w / (new_width * 2), 0, src_w - 1)
      let si = src_row + sx * 4
      let di = (dy * new_width + dx) * 4
      buf[di] = src[si]
      buf[di + 1] = src[si + 1]
      buf[di + 2] = src[si + 2]
      buf[di + 3] = src[si + 3]
    }
  }
  { width: new_width, height: new_height, data: Bytes::from_array(buf), }
}

///|
/// Fixed-point 1.0 for resampling weights (14 bits per axis).
const RESAMPLE_ONE : Int32 = 16384

///|
/// Precomputed filter taps for one axis.
///
/// For output coordinate `d`, taps `d * n ..< d * n + n` hold the source
/// offsets (already clamped to the image edge and multiplied by `stride`)
/// and the fixed-point weights, which sum to exactly `RESAMPLE_ONE` so that
/// flat regions are reproduced exactly.
priv struct ResampleTaps {
  n : Int32
  offsets : FixedArray[Int32]
  weights : FixedArray[Int32]
}

///|
fn ResampleTaps::new(
  src_len : Int32,
  dst_len : Int32,
  kind : ResizeMethod,
  stride : Int32,
) -> ResampleTaps {
  if src_len == dst_len {
    // Identity: a single tap of weight 1.0.
    return {
      n: 1,
      offsets: FixedArray::makei(dst_len, fn(d) { d * stride }),
      weights: FixedArray::make(dst_len, RESAMPLE_ONE),
    }
  }
  let n = match kind {
    Bicubic => 4
    _ => 2
  }
  let offsets = FixedArray::make(dst_len * n, 0)
  let weights = FixedArray::make(dst_len * n, 0)
  let wf = FixedArray::make(n, 0.0)
  let scale = src_len.to_double() / dst_len.to_double()
  for d in 0..<dst_len {
    let s = (d.to_double() + 0.5) * scale - 0.5
    let i0 = s.floor().to_int()
    let f = s - i0.to_double()
    let first = match kind {
      Bicubic => {
        wf[0] = cubic_weight(f + 1.0)
        wf[1] = cubic_weight(f)
        wf[2] = cubic_weight(1.0 - f)
        wf[3] = cubic_weight(2.0 - f)
        i0 - 1
      }
      _ => {
        wf[0] = 1.0 - f
        wf[1] = f
        i0
      }
    }
    let mut sum = 0
    let mut best = 0
    for k in 0..<n {
      let w = (wf[k] * RESAMPLE_ONE.to_double()).round().to_int()
      weights[d * n + k] = w
      sum += w
      let bw = weights[d * n + best]
      if w.abs() > bw.abs() {
        best = k
      }
      offsets[d * n + k] = clamp_int(first + k, 0, src_len - 1) * stride
    }
    // Normalize the rounded weights so that they sum to exactly 1.0.
    weights[d * n + best] += RESAMPLE_ONE - sum
  }
  { n, offsets, weights, }
}

///|
/// Separable two-pass resampling with 14-bit fixed-point weights.
///
/// The horizontal pass writes RGBA samples as `Int` with
/// 6 fractional bits (unclamped); the vertical pass
/// rounds and clamps to 8 bits. An axis whose size does not change uses an
/// identity tap, so the passes stay uniform.
fn resize_separable(
  img : ImageData,
  new_width : Int32,
  new_height : Int32,
  kind : ResizeMethod,
) -> ImageData {
  let src_w = img.width
  let src_h = img.height
  // Horizontal pass: src_w x src_h -> new_width x src_h
  let h_taps = ResampleTaps::new(src_w, new_width, kind, 4)
  let row_len = new_width * 4
  let inter = FixedArray::make(row_len * src_h, 0)
  for y in 0..<src_h {
    resample_row_h(
      img.data,
      y * src_w * 4,
      inter,
      y * row_len,
      h_taps.offsets,
      h_taps.weights,
      h_taps.n,
      new_width,
    )
  }
  // Vertical pass: new_width x src_h -> new_width x new_height
  let v_taps = ResampleTaps::new(src_h, new_height, kind, row_len)
  let out = FixedArray::make(row_len * new_height, b'\x00')
  for y in 0..<new_height {
    resample_row_v(
      inter,
      out,
      y * row_len,
      v_taps.offsets,
      v_taps.weights,
      y * v_taps.n,
      v_taps.n,
      new_width,
    )
  }
  { width: new_width, height: new_height, data: Bytes::from_array(out), }
}

///|
pub fn resize(
  img : ImageData,
  new_width : Int32,
  new_height : Int32,
  resize_method : ResizeMethod,
) -> ImageData raise EncodeError {
  if new_width <= 0 || new_height <= 0 {
    raise InvalidDimensions(
      "width and height must be positive, got " +
      new_width.to_string() +
      "x" +
      new_height.to_string(),
    )
  }
  if new_width == img.width && new_height == img.height {
    let arr = img.data.to_fixedarray()
    return {
      width: img.width,
      height: img.height,
      data: Bytes::from_array(arr),
    }
  }
  match resize_method {
    Nearest => resize_nearest(img, new_width, new_height)
    Bilinear | Bicubic =>
      resize_separable(img, new_width, new_height, resize_method)
  }
}
