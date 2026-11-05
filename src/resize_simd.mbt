// SIMD resampling kernels — wasm target only.
//
// One RGBA pixel is processed as an i32x4 vector (one lane per channel):
// 4 bytes are widened with `i16x8.extend_low_i8x16_u` +
// `i32x4.extend_low_i16x8_u`, multiplied by a splatted tap weight and
// accumulated. The vertical pass narrows back with saturating
// `i16x8.narrow_i32x4_s` + `i8x16.narrow_i16x8_u`, which is exactly the
// clamp to 0..255 done by resize_scalar.mbt. Results are bit-identical.

///|
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
  resample_row_h_v128(src, src_off, dst, dst_off, offsets, weights, n, dst_w)
}

///|
/// Params: 0 = src, 1 = src_off, 2 = dst, 3 = dst_off (in Ints),
///         4 = offsets, 5 = weights, 6 = n, 7 = dst_w.
/// Locals: 8 = x, 9 = k, 10 = tap byte offset (4 * (x * n + k)),
///         11 = dst ptr, 12 = acc, 13 = rounding bias (1 << 7).
/// Shift 8 = RESAMPLE_H_SHIFT.
#borrow(src, dst, offsets, weights)
fn resample_row_h_v128(
  src : Bytes,
  src_off : Int32,
  dst : FixedArray[Int32],
  dst_off : Int32,
  offsets : FixedArray[Int32],
  weights : FixedArray[Int32],
  n : Int32,
  dst_w : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) (local i32) (local i32) (local v128) (local v128) i32.const 128 i32x4.splat local.set 13 local.get 2 local.get 3 i32.const 2 i32.shl i32.add local.set 11 local.get 0 local.get 1 i32.add local.set 0 block loop local.get 8 local.get 7 i32.ge_s br_if 1 local.get 13 local.set 12 i32.const 0 local.set 9 block loop local.get 9 local.get 6 i32.ge_s br_if 1 local.get 12 local.get 0 local.get 4 local.get 10 i32.add i32.load i32.add i32.load i32x4.splat i16x8.extend_low_i8x16_u i32x4.extend_low_i16x8_u local.get 5 local.get 10 i32.add i32.load i32x4.splat i32x4.mul i32x4.add local.set 12 local.get 10 i32.const 4 i32.add local.set 10 local.get 9 i32.const 1 i32.add local.set 9 br 0 end end local.get 11 local.get 12 i32.const 8 i32x4.shr_s v128.store local.get 11 i32.const 16 i32.add local.set 11 local.get 8 i32.const 1 i32.add local.set 8 br 0 end end)

///|
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
  resample_row_v_v128(src, dst, dst_off, offsets, weights, tap, n, width)
}

///|
/// Params: 0 = src, 1 = dst, 2 = dst_off, 3 = offsets, 4 = weights,
///         5 = tap, 6 = n, 7 = width.
/// Locals: 8 = x, 9 = k, 10 = tap byte offset (4 * k), 11 = dst ptr,
///         12 = src pixel byte offset (16 * x), 13 = acc,
///         14 = rounding bias (1 << 19).
/// Shift 20 = RESAMPLE_V_SHIFT.
#borrow(src, dst, offsets, weights)
fn resample_row_v_v128(
  src : FixedArray[Int32],
  dst : FixedArray[Byte],
  dst_off : Int32,
  offsets : FixedArray[Int32],
  weights : FixedArray[Int32],
  tap : Int32,
  n : Int32,
  width : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) (local i32) (local i32) (local i32) (local v128) (local v128) i32.const 524288 i32x4.splat local.set 14 local.get 1 local.get 2 i32.add local.set 11 local.get 3 local.get 5 i32.const 2 i32.shl i32.add local.set 3 local.get 4 local.get 5 i32.const 2 i32.shl i32.add local.set 4 block loop local.get 8 local.get 7 i32.ge_s br_if 1 local.get 14 local.set 13 i32.const 0 local.set 9 i32.const 0 local.set 10 block loop local.get 9 local.get 6 i32.ge_s br_if 1 local.get 13 local.get 0 local.get 3 local.get 10 i32.add i32.load i32.const 2 i32.shl i32.add local.get 12 i32.add v128.load local.get 4 local.get 10 i32.add i32.load i32x4.splat i32x4.mul i32x4.add local.set 13 local.get 10 i32.const 4 i32.add local.set 10 local.get 9 i32.const 1 i32.add local.set 9 br 0 end end local.get 11 local.get 13 i32.const 20 i32x4.shr_s local.tee 13 local.get 13 i16x8.narrow_i32x4_s local.tee 13 local.get 13 i8x16.narrow_i16x8_u i32x4.extract_lane 0 i32.store local.get 11 i32.const 4 i32.add local.set 11 local.get 12 i32.const 16 i32.add local.set 12 local.get 8 i32.const 1 i32.add local.set 8 br 0 end end)
