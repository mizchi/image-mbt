// Scalar color expansion helpers for PNG decode — non-wasm targets.

///|
/// RGB8 -> RGBA8 (alpha = 0xFF) for `width` pixels.
fn rgb8_to_rgba(row : Bytes, out : FixedArray[Byte], width : Int32) -> Unit {
  for i in 0..<width {
    out[i * 4] = row[i * 3]
    out[i * 4 + 1] = row[i * 3 + 1]
    out[i * 4 + 2] = row[i * 3 + 2]
    out[i * 4 + 3] = b'\xFF'
  }
}

///|
/// Gray8 -> RGBA8 (alpha = 0xFF) for `width` pixels.
fn gray8_to_rgba(row : Bytes, out : FixedArray[Byte], width : Int32) -> Unit {
  for i in 0..<width {
    let v = row[i]
    out[i * 4] = v
    out[i * 4 + 1] = v
    out[i * 4 + 2] = v
    out[i * 4 + 3] = b'\xFF'
  }
}

///|
/// GrayAlpha8 -> RGBA8 for `width` pixels.
fn gray_alpha8_to_rgba(
  row : Bytes,
  out : FixedArray[Byte],
  width : Int32,
) -> Unit {
  for i in 0..<width {
    let v = row[i * 2]
    out[i * 4] = v
    out[i * 4 + 1] = v
    out[i * 4 + 2] = v
    out[i * 4 + 3] = row[i * 2 + 1]
  }
}
