// JPEG islow IDCT dispatch — non-wasm targets use the scalar version.

///|
fn jpeg_idct(
  coef : FixedArray[Int32],
  ws : FixedArray[Int32],
  out : FixedArray[Int32],
  off : Int32,
  stride : Int32,
) -> Unit {
  jpeg_idct_islow(coef, ws, out, off, stride)
}
