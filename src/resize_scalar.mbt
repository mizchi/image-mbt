// Scalar resampling kernels — non-wasm targets.
// Must stay bit-identical to resize_simd.mbt.

///|
/// Right shift applied after the horizontal pass (14 - 6). The
/// intermediate buffer keeps 6 extra fractional bits, so that bicubic
/// overshoot is not clipped between the two passes.
const RESAMPLE_H_SHIFT : Int32 = 8

///|
/// Right shift applied after the vertical pass (14 + 6).
const RESAMPLE_V_SHIFT : Int32 = 20

///|
/// Horizontal pass for one row: `dst_w` RGBA pixels (4 Ints each) written
/// to `dst` at `dst_off`, with 6 fractional bits.
fn resample_row_h(
  src : Bytes,
  src_off : Int32,
  dst : FixedArray[Int32],
  dst_off : Int32,
  offsets : FixedArray[Int32],
  weights : FixedArray[Int32],
  n : Int32,
  dst_w : Int32,
) -> Unit {
  let half = 1 << (RESAMPLE_H_SHIFT - 1)
  for x in 0..<dst_w {
    let mut r = half
    let mut g = half
    let mut b = half
    let mut a = half
    for k in 0..<n {
      let p = src_off + offsets[x * n + k]
      let w = weights[x * n + k]
      r += src[p].to_int() * w
      g += src[p + 1].to_int() * w
      b += src[p + 2].to_int() * w
      a += src[p + 3].to_int() * w
    }
    let o = dst_off + x * 4
    dst[o] = r >> RESAMPLE_H_SHIFT
    dst[o + 1] = g >> RESAMPLE_H_SHIFT
    dst[o + 2] = b >> RESAMPLE_H_SHIFT
    dst[o + 3] = a >> RESAMPLE_H_SHIFT
  }
}

///|
/// Vertical pass for one output row of `width` RGBA pixels at `dst_off`,
/// using taps `tap ..< tap + n` (Int offsets of intermediate rows).
fn resample_row_v(
  src : FixedArray[Int32],
  dst : FixedArray[Byte],
  dst_off : Int32,
  offsets : FixedArray[Int32],
  weights : FixedArray[Int32],
  tap : Int32,
  n : Int32,
  width : Int32,
) -> Unit {
  let half = 1 << (RESAMPLE_V_SHIFT - 1)
  for i in 0..<(width * 4) {
    let mut acc = half
    for k in 0..<n {
      acc += src[offsets[tap + k] + i] * weights[tap + k]
    }
    let v = acc >> RESAMPLE_V_SHIFT
    dst[dst_off + i] = if v < 0 {
      b'\x00'
    } else if v > 255 {
      b'\xFF'
    } else {
      v.to_byte()
    }
  }
}
