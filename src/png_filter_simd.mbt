// SIMD implementation of PNG filter Up — wasm target only.
//
// Filter Up: buf[i] = (row[i] - prev[i]) mod 256
//
// `i8x16.sub` does exactly this on 16 bytes at a time (modular byte
// subtraction). Inline-WAT can take `Bytes` as input on wasm (not on
// wasm-gc, which receives a GC ref — that target falls through to scalar
// via png_filter_scalar.mbt).

///|
/// Decode-side Up reconstruction: buf[i] = (row[i] + prev[i]) mod 256.
/// Pure `i8x16.add` (modular byte add) on 16-byte chunks.
fn reconstruct_filter_up_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
) -> Unit {
  let len = row.length()
  if len == 0 {
    return
  }
  reconstruct_filter_up_v128(row, prev, buf, len)
}

///|
/// Inline-WAT for filter Up reconstruction. Same shape as the encoder
/// `apply_filter_up_v128`, but using `i8x16.add` (decode) instead of sub.
///
/// Locals: 4 = vec_end, 5 = i.
#borrow(row, prev, buf)
fn reconstruct_filter_up_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  len : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) local.get 3 i32.const 4 i32.shr_s i32.const 4 i32.shl local.set 4 block loop local.get 5 local.get 4 i32.ge_s br_if 1 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add v128.load local.get 1 local.get 5 i32.add v128.load i8x16.add v128.store local.get 5 i32.const 16 i32.add local.set 5 br 0 end end block loop local.get 5 local.get 3 i32.ge_s br_if 1 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add i32.load8_u local.get 1 local.get 5 i32.add i32.load8_u i32.add i32.store8 local.get 5 i32.const 1 i32.add local.set 5 br 0 end end)

///|
fn apply_filter_up_impl(row : Bytes, prev : Bytes) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  if len == 0 {
    return buf
  }
  apply_filter_up_v128(row, prev, buf, len)
  buf
}

///|
/// Inline-WAT: walks `row` and `prev` 16 bytes at a time via `v128.load`
/// + `i8x16.sub` + `v128.store` into `buf`. Tail bytes scalar.
///
/// Locals: 4 = vec_end (= len & ~15), 5 = i.
#borrow(row, prev, buf)
fn apply_filter_up_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  len : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) local.get 3 i32.const 4 i32.shr_s i32.const 4 i32.shl local.set 4 block loop local.get 5 local.get 4 i32.ge_s br_if 1 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add v128.load local.get 1 local.get 5 i32.add v128.load i8x16.sub v128.store local.get 5 i32.const 16 i32.add local.set 5 br 0 end end block loop local.get 5 local.get 3 i32.ge_s br_if 1 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add i32.load8_u local.get 1 local.get 5 i32.add i32.load8_u i32.sub i32.store8 local.get 5 i32.const 1 i32.add local.set 5 br 0 end end)

///|
/// Filter Sub: buf[i] = row[i] - (i >= bpp ? row[i-bpp] : 0).
///
/// Head (i < bpp) is scalar; then SIMD as long as `i + 16 <= len`, then
/// scalar tail. The SIMD load `row + i - bpp` is safe because i >= bpp.
fn apply_filter_sub_impl(row : Bytes, bpp : Int32) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  if len == 0 {
    return buf
  }
  // Scalar head: i = 0..bpp-1, buf[i] = row[i] (a = 0).
  let head_end = if bpp > len { len } else { bpp }
  for i in 0..<head_end {
    buf[i] = row[i]
  }
  if len > bpp {
    apply_filter_sub_v128(row, buf, bpp, len)
  }
  buf
}

///|
/// Inline-WAT: SIMD body + scalar tail for filter Sub.
/// Params: 0 = row, 1 = buf, 2 = bpp, 3 = len.
/// Locals: 4 = vec_end (= ((len - bpp) & ~15) + bpp), 5 = i.
#borrow(row, buf)
fn apply_filter_sub_v128(
  row : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) local.get 3 local.get 2 i32.sub i32.const 4 i32.shr_s i32.const 4 i32.shl local.get 2 i32.add local.set 4 local.get 2 local.set 5 block loop local.get 5 local.get 4 i32.ge_s br_if 1 local.get 1 local.get 5 i32.add local.get 0 local.get 5 i32.add v128.load local.get 0 local.get 5 i32.add local.get 2 i32.sub v128.load i8x16.sub v128.store local.get 5 i32.const 16 i32.add local.set 5 br 0 end end block loop local.get 5 local.get 3 i32.ge_s br_if 1 local.get 1 local.get 5 i32.add local.get 0 local.get 5 i32.add i32.load8_u local.get 0 local.get 5 i32.add local.get 2 i32.sub i32.load8_u i32.sub i32.store8 local.get 5 i32.const 1 i32.add local.set 5 br 0 end end)

// ---------------------------------------------------------------------------
// Decode side: Sub / Average / Paeth.
//
// These filters depend on the previously reconstructed pixel, so they are
// vectorized across the channels of one pixel (libpng-style) instead of
// across pixels: each step loads 4 bytes into the low lanes of a v128,
// computes one pixel and keeps it in a register as `a` for the next step.
// This is valid for bpp = 3 and 4. For bpp = 3 the 4th lane spills into the
// next pixel's first byte, which the next step (or the scalar tail)
// overwrites, so the SIMD loop only runs while `i + 4 <= len` and returns
// the first byte it did not process. The first pixel (a = c = 0) is done by
// the scalar helpers.
// ---------------------------------------------------------------------------

///|
fn simd_pixel_bpp(bpp : Int32, len : Int32) -> Bool {
  (bpp == 3 || bpp == 4) && len >= bpp + 4
}

///|
fn reconstruct_filter_sub_impl(
  row : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  let len = row.length()
  if !simd_pixel_bpp(bpp, len) {
    reconstruct_sub_range(row, buf, bpp, 0, len)
    return
  }
  reconstruct_sub_range(row, buf, bpp, 0, bpp)
  let done = reconstruct_sub_v128(row, buf, bpp, len)
  reconstruct_sub_range(row, buf, bpp, done, len)
}

///|
/// Params: 0 = row, 1 = buf, 2 = bpp, 3 = len. Returns first unprocessed i.
/// Locals: 4 = i, 5 = a (previous pixel, u8 lanes).
#borrow(row, buf)
fn reconstruct_sub_v128(
  row : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (param i32) (result i32) (local i32) (local v128) local.get 2 local.set 4 local.get 1 i32.load i32x4.splat local.set 5 block loop local.get 4 i32.const 4 i32.add local.get 3 i32.gt_s br_if 1 local.get 0 local.get 4 i32.add i32.load i32x4.splat local.get 5 i8x16.add local.set 5 local.get 1 local.get 4 i32.add local.get 5 i32x4.extract_lane 0 i32.store local.get 4 local.get 2 i32.add local.set 4 br 0 end end local.get 4)

///|
fn reconstruct_filter_average_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  let len = row.length()
  if !simd_pixel_bpp(bpp, len) {
    reconstruct_average_range(row, prev, buf, bpp, 0, len)
    return
  }
  reconstruct_average_range(row, prev, buf, bpp, 0, bpp)
  let done = reconstruct_average_v128(row, prev, buf, bpp, len)
  reconstruct_average_range(row, prev, buf, bpp, done, len)
}

///|
/// floor((a + b) / 2) = avgr_u(a, b) - ((a ^ b) & 1).
///
/// Params: 0 = row, 1 = prev, 2 = buf, 3 = bpp, 4 = len.
/// Locals: 5 = i, 6 = a, 7 = b, 8 = splat(1).
#borrow(row, prev, buf)
fn reconstruct_average_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (result i32) (local i32) (local v128) (local v128) (local v128) i32.const 1 i8x16.splat local.set 8 local.get 3 local.set 5 local.get 2 i32.load i32x4.splat local.set 6 block loop local.get 5 i32.const 4 i32.add local.get 4 i32.gt_s br_if 1 local.get 1 local.get 5 i32.add i32.load i32x4.splat local.set 7 local.get 0 local.get 5 i32.add i32.load i32x4.splat local.get 6 local.get 7 i8x16.avgr_u local.get 6 local.get 7 v128.xor local.get 8 v128.and i8x16.sub i8x16.add local.set 6 local.get 2 local.get 5 i32.add local.get 6 i32x4.extract_lane 0 i32.store local.get 5 local.get 3 i32.add local.set 5 br 0 end end local.get 5)

///|
fn reconstruct_filter_paeth_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  let len = row.length()
  if !simd_pixel_bpp(bpp, len) {
    reconstruct_paeth_range(row, prev, buf, bpp, 0, len)
    return
  }
  reconstruct_paeth_range(row, prev, buf, bpp, 0, bpp)
  let done = reconstruct_paeth_v128(row, prev, buf, bpp, len)
  reconstruct_paeth_range(row, prev, buf, bpp, done, len)
}

///|
/// Paeth in i16 lanes:
///   pa = |b - c|, pb = |a - c|, pc = |(b - c) + (a - c)|
///   t = pb <= pc ? b : c;  pred = pa <= min(pb, pc) ? a : t
/// which matches `paeth_predictor`'s tie-breaking order (a, then b, then c).
///
/// Params: 0 = row, 1 = prev, 2 = buf, 3 = bpp, 4 = len.
/// Locals: 5 = i, 6 = a (u8), 7 = c16, 8 = b16, 9 = a16,
///         10 = pa, 11 = pb, 12 = pc, 13 = tmp.
#borrow(row, prev, buf)
fn reconstruct_paeth_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (result i32) (local i32) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) local.get 3 local.set 5 local.get 2 i32.load i32x4.splat local.set 6 local.get 1 i32.load i32x4.splat i16x8.extend_low_i8x16_u local.set 7 block loop local.get 5 i32.const 4 i32.add local.get 4 i32.gt_s br_if 1 local.get 1 local.get 5 i32.add i32.load i32x4.splat i16x8.extend_low_i8x16_u local.set 8 local.get 6 i16x8.extend_low_i8x16_u local.set 9 local.get 8 local.get 7 i16x8.sub local.tee 10 local.get 9 local.get 7 i16x8.sub local.tee 11 i16x8.add i16x8.abs local.set 12 local.get 10 i16x8.abs local.set 10 local.get 11 i16x8.abs local.set 11 local.get 8 local.get 7 local.get 11 local.get 12 i16x8.le_s v128.bitselect local.set 13 local.get 9 local.get 13 local.get 10 local.get 11 local.get 12 i16x8.min_s i16x8.le_s v128.bitselect local.tee 13 local.get 13 i8x16.narrow_i16x8_u local.get 0 local.get 5 i32.add i32.load i32x4.splat i8x16.add local.set 6 local.get 2 local.get 5 i32.add local.get 6 i32x4.extract_lane 0 i32.store local.get 8 local.set 7 local.get 5 local.get 3 i32.add local.set 5 br 0 end end local.get 5)

// ---------------------------------------------------------------------------
// Encode side: Average / Paeth / filter-selection score.
//
// On the encode side `a` comes from the raw row, so 16 bytes are processed
// per step. Head bytes (i < bpp, where a = c = 0) and the tail are scalar.
// ---------------------------------------------------------------------------

///|
fn apply_filter_average_impl(
  row : Bytes,
  prev : Bytes,
  bpp : Int32,
) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  let head = if bpp > len { len } else { bpp }
  apply_average_range(row, prev, buf, bpp, 0, head)
  let done = if len - bpp >= 16 {
    apply_average_v128(row, prev, buf, bpp, len)
  } else {
    head
  }
  apply_average_range(row, prev, buf, bpp, done, len)
  buf
}

///|
/// Params: 0 = row, 1 = prev, 2 = buf, 3 = bpp, 4 = len.
/// Locals: 5 = i, 6 = a, 7 = b, 8 = splat(1).
#borrow(row, prev, buf)
fn apply_average_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (result i32) (local i32) (local v128) (local v128) (local v128) i32.const 1 i8x16.splat local.set 8 local.get 3 local.set 5 block loop local.get 5 i32.const 16 i32.add local.get 4 i32.gt_s br_if 1 local.get 0 local.get 5 i32.add local.get 3 i32.sub v128.load local.set 6 local.get 1 local.get 5 i32.add v128.load local.set 7 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add v128.load local.get 6 local.get 7 i8x16.avgr_u local.get 6 local.get 7 v128.xor local.get 8 v128.and i8x16.sub i8x16.sub v128.store local.get 5 i32.const 16 i32.add local.set 5 br 0 end end local.get 5)

///|
fn apply_filter_paeth_impl(
  row : Bytes,
  prev : Bytes,
  bpp : Int32,
) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  let head = if bpp > len { len } else { bpp }
  apply_paeth_range(row, prev, buf, bpp, 0, head)
  let done = if len - bpp >= 16 {
    apply_paeth_v128(row, prev, buf, bpp, len)
  } else {
    head
  }
  apply_paeth_range(row, prev, buf, bpp, done, len)
  buf
}

///|
/// 16 bytes per step, split into low/high i16x8 halves; the predictor is
/// computed by `paeth_pred16` (inlined twice) and narrowed back.
///
/// Params: 0 = row, 1 = prev, 2 = buf, 3 = bpp, 4 = len.
/// Locals: 5 = i, 6 = a8, 7 = b8, 8 = c8, 9 = a16, 10 = b16, 11 = c16,
///         12 = pa, 13 = pb, 14 = pc, 15 = tmp, 16 = pred_lo.
#borrow(row, prev, buf)
fn apply_paeth_v128(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
  len : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (result i32) (local i32) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) local.get 3 local.set 5 block loop local.get 5 i32.const 16 i32.add local.get 4 i32.gt_s br_if 1 local.get 0 local.get 5 i32.add local.get 3 i32.sub v128.load local.set 6 local.get 1 local.get 5 i32.add v128.load local.set 7 local.get 1 local.get 5 i32.add local.get 3 i32.sub v128.load local.set 8 local.get 6 i16x8.extend_low_i8x16_u local.set 9 local.get 7 i16x8.extend_low_i8x16_u local.set 10 local.get 8 i16x8.extend_low_i8x16_u local.set 11 local.get 10 local.get 11 i16x8.sub local.tee 12 local.get 9 local.get 11 i16x8.sub local.tee 13 i16x8.add i16x8.abs local.set 14 local.get 12 i16x8.abs local.set 12 local.get 13 i16x8.abs local.set 13 local.get 10 local.get 11 local.get 13 local.get 14 i16x8.le_s v128.bitselect local.set 15 local.get 9 local.get 15 local.get 12 local.get 13 local.get 14 i16x8.min_s i16x8.le_s v128.bitselect local.set 16 local.get 6 i16x8.extend_high_i8x16_u local.set 9 local.get 7 i16x8.extend_high_i8x16_u local.set 10 local.get 8 i16x8.extend_high_i8x16_u local.set 11 local.get 10 local.get 11 i16x8.sub local.tee 12 local.get 9 local.get 11 i16x8.sub local.tee 13 i16x8.add i16x8.abs local.set 14 local.get 12 i16x8.abs local.set 12 local.get 13 i16x8.abs local.set 13 local.get 10 local.get 11 local.get 13 local.get 14 i16x8.le_s v128.bitselect local.set 15 local.get 2 local.get 5 i32.add local.get 0 local.get 5 i32.add v128.load local.get 16 local.get 9 local.get 15 local.get 12 local.get 13 local.get 14 i16x8.min_s i16x8.le_s v128.bitselect i8x16.narrow_i16x8_u i8x16.sub v128.store local.get 5 i32.const 16 i32.add local.set 5 br 0 end end local.get 5)

///|
fn filter_sum_impl(buf : FixedArray[Byte]) -> Int32 {
  let len = buf.length()
  let vec_end = len & -16
  let sum = if vec_end > 0 { filter_sum_v128(buf, vec_end) } else { 0 }
  sum + filter_sum_range(buf, vec_end, len)
}

///|
/// sum(min(v, 256 - v)) == sum(|v as i8|) read as unsigned (|-128| = 0x80).
/// Widen with pairwise adds: u8 -> u16 -> u32 lanes.
///
/// Params: 0 = buf, 1 = vec_end (multiple of 16).
/// Locals: 2 = i, 3 = acc (i32x4).
#borrow(buf)
fn filter_sum_v128(buf : FixedArray[Byte], vec_end : Int32) -> Int32 =
  #|(func (param i32) (param i32) (result i32) (local i32) (local v128) block loop local.get 2 local.get 1 i32.ge_s br_if 1 local.get 3 local.get 0 local.get 2 i32.add v128.load i8x16.abs i16x8.extadd_pairwise_i8x16_u i32x4.extadd_pairwise_i16x8_u i32x4.add local.set 3 local.get 2 i32.const 16 i32.add local.set 2 br 0 end end local.get 3 i32x4.extract_lane 0 local.get 3 i32x4.extract_lane 1 i32.add local.get 3 i32x4.extract_lane 2 i32.add local.get 3 i32x4.extract_lane 3 i32.add)
