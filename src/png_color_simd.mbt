// SIMD color expansion helpers for PNG decode — wasm target only.
//
// Each helper runs a v128 body via inline WAT (`i8x16.shuffle` against a
// splatted 0xFF vector supplies the alpha lane) and returns the number of
// pixels it converted; the remaining tail pixels are handled in MoonBit.

///|
/// RGB8 -> RGBA8 (alpha = 0xFF) for `width` pixels.
fn rgb8_to_rgba(row : Bytes, out : FixedArray[Byte], width : Int32) -> Unit {
  let done = if width >= 6 { rgb8_to_rgba_v128(row, out, width) } else { 0 }
  for i in done..<width {
    out[i * 4] = row[i * 3]
    out[i * 4 + 1] = row[i * 3 + 1]
    out[i * 4 + 2] = row[i * 3 + 2]
    out[i * 4 + 3] = b'\xFF'
  }
}

///|
/// 4 pixels per step: one 16-byte load (12 bytes used), one shuffle, one
/// store. The load reads 4 bytes past the 4th pixel, so the loop runs only
/// while `src + 16 <= width * 3`.
///
/// Params: 0 = row, 1 = out, 2 = width.
/// Locals: 3 = src offset, 4 = dst offset, 5 = width * 3, 6 = 0xFF vector.
#borrow(row, out)
fn rgb8_to_rgba_v128(
  row : Bytes,
  out : FixedArray[Byte],
  width : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (result i32) (local i32) (local i32) (local i32) (local v128) local.get 2 i32.const 3 i32.mul local.set 5 i32.const -1 i32x4.splat local.set 6 block loop local.get 3 i32.const 16 i32.add local.get 5 i32.gt_s br_if 1 local.get 1 local.get 4 i32.add local.get 0 local.get 3 i32.add v128.load local.get 6 i8x16.shuffle 0 1 2 16 3 4 5 16 6 7 8 16 9 10 11 16 v128.store local.get 3 i32.const 12 i32.add local.set 3 local.get 4 i32.const 16 i32.add local.set 4 br 0 end end local.get 4 i32.const 2 i32.shr_s)

///|
/// Gray8 -> RGBA8 (alpha = 0xFF) for `width` pixels.
fn gray8_to_rgba(row : Bytes, out : FixedArray[Byte], width : Int32) -> Unit {
  let done = if width >= 16 { gray8_to_rgba_v128(row, out, width) } else { 0 }
  for i in done..<width {
    let v = row[i]
    out[i * 4] = v
    out[i * 4 + 1] = v
    out[i * 4 + 2] = v
    out[i * 4 + 3] = b'\xFF'
  }
}

///|
/// 16 pixels per step: one load, four shuffles + stores.
///
/// Params: 0 = row, 1 = out, 2 = width.
/// Locals: 3 = i (pixel), 4 = dst ptr, 5 = src vector, 6 = 0xFF vector.
#borrow(row, out)
fn gray8_to_rgba_v128(
  row : Bytes,
  out : FixedArray[Byte],
  width : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (result i32) (local i32) (local i32) (local v128) (local v128) i32.const -1 i32x4.splat local.set 6 local.get 1 local.set 4 block loop local.get 3 i32.const 16 i32.add local.get 2 i32.gt_s br_if 1 local.get 0 local.get 3 i32.add v128.load local.set 5 local.get 4 local.get 5 local.get 6 i8x16.shuffle 0 0 0 16 1 1 1 16 2 2 2 16 3 3 3 16 v128.store local.get 4 i32.const 16 i32.add local.get 5 local.get 6 i8x16.shuffle 4 4 4 16 5 5 5 16 6 6 6 16 7 7 7 16 v128.store local.get 4 i32.const 32 i32.add local.get 5 local.get 6 i8x16.shuffle 8 8 8 16 9 9 9 16 10 10 10 16 11 11 11 16 v128.store local.get 4 i32.const 48 i32.add local.get 5 local.get 6 i8x16.shuffle 12 12 12 16 13 13 13 16 14 14 14 16 15 15 15 16 v128.store local.get 3 i32.const 16 i32.add local.set 3 local.get 4 i32.const 64 i32.add local.set 4 br 0 end end local.get 3)

///|
/// GrayAlpha8 -> RGBA8 for `width` pixels.
fn gray_alpha8_to_rgba(
  row : Bytes,
  out : FixedArray[Byte],
  width : Int32,
) -> Unit {
  let done = if width >= 8 {
    gray_alpha8_to_rgba_v128(row, out, width)
  } else {
    0
  }
  for i in done..<width {
    let v = row[i * 2]
    out[i * 4] = v
    out[i * 4 + 1] = v
    out[i * 4 + 2] = v
    out[i * 4 + 3] = row[i * 2 + 1]
  }
}

///|
/// 8 pixels per step: one load, two shuffles + stores.
///
/// Params: 0 = row, 1 = out, 2 = width.
/// Locals: 3 = i (pixel), 4 = dst ptr, 5 = src vector.
#borrow(row, out)
fn gray_alpha8_to_rgba_v128(
  row : Bytes,
  out : FixedArray[Byte],
  width : Int32,
) -> Int32 =
  #|(func (param i32) (param i32) (param i32) (result i32) (local i32) (local i32) (local v128) local.get 1 local.set 4 block loop local.get 3 i32.const 8 i32.add local.get 2 i32.gt_s br_if 1 local.get 0 local.get 3 i32.const 1 i32.shl i32.add v128.load local.set 5 local.get 4 local.get 5 local.get 5 i8x16.shuffle 0 0 0 1 2 2 2 3 4 4 4 5 6 6 6 7 v128.store local.get 4 i32.const 16 i32.add local.get 5 local.get 5 i8x16.shuffle 8 8 8 9 10 10 10 11 12 12 12 13 14 14 14 15 v128.store local.get 3 i32.const 8 i32.add local.set 3 local.get 4 i32.const 32 i32.add local.set 4 br 0 end end local.get 3)
