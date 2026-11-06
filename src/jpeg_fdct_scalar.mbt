// JPEG islow FDCT dispatch — non-wasm targets use the scalar version.

///|
fn jpeg_fdct(data : FixedArray[Int32]) -> Unit {
  jpeg_fdct_islow(data)
}
