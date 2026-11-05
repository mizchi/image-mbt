///|
// On wasm, fdct_block / idct_block run the f64x2 kernels; they must be
// bit-identical to the scalar references.
test "jpeg dct: SIMD/dispatch matches scalar reference" {
  let mut seed = 99
  for round in 0..<64 {
    let pixels = FixedArray::make(64, 0)
    let coeffs = FixedArray::make(64, 0)
    for i in 0..<64 {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      pixels[i] = (seed >> 16) & 0xFF
      // Mix of large, small and zero coefficients.
      coeffs[i] = if round % 4 == 0 && i > 10 {
        0
      } else {
        ((seed >> 8) & 0x7FF) - 1024
      }
    }
    let f_ref = FixedArray::make(64, 0.0)
    let f_got = FixedArray::make(64, 0.0)
    fdct_block_ref(pixels, f_ref)
    fdct_block(pixels, f_got)
    for i in 0..<64 {
      assert_eq(
        f_got[i].reinterpret_as_int64(),
        f_ref[i].reinterpret_as_int64(),
      )
    }
    let i_ref = FixedArray::make(64, 0)
    let i_got = FixedArray::make(64, 0)
    idct_block_ref(coeffs, i_ref)
    idct_block(coeffs, i_got)
    assert_eq(i_got, i_ref)
  }
}
