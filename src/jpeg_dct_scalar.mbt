// JPEG forward DCT dispatch — non-wasm targets use the scalar reference.

///|
fn fdct_block(input : FixedArray[Int32], output : FixedArray[Double]) -> Unit {
  fdct_block_ref(input, output)
}
