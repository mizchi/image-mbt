// JPEG DCT dispatch — non-wasm targets use the scalar reference.

///|
fn fdct_block(input : FixedArray[Int32], output : FixedArray[Double]) -> Unit {
  fdct_block_ref(input, output)
}

///|
fn idct_block(coeff : FixedArray[Int32], output : FixedArray[Int32]) -> Unit {
  idct_block_ref(coeff, output)
}
