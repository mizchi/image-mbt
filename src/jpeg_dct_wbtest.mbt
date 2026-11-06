///|
// On wasm, fdct_block runs the f64x2 kernel; it must be bit-identical to
// the scalar reference.
test "jpeg fdct: SIMD/dispatch matches scalar reference" {
  let mut seed = 99
  for _ in 0..<64 {
    let pixels = FixedArray::make(64, 0)
    for i in 0..<64 {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      pixels[i] = (seed >> 16) & 0xFF
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
  }
}

///|
// On wasm, jpeg_idct runs the i32x4 kernel; it must be bit-identical to the
// scalar libjpeg port, including blocks that hit the zero-AC shortcuts.
test "jpeg idct: SIMD/dispatch matches scalar islow" {
  let mut seed = 7
  let ws = FixedArray::make(64, 0)
  for round in 0..<200 {
    let coef = FixedArray::make(64, 0)
    for i in 0..<64 {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let v = ((seed >> 8) & 0xFFF) - 2048
      coef[i] = match round % 4 {
        0 => if i == 0 { v } else { 0 } // DC only
        1 => if i % 8 == 0 { v } else { 0 } // first column only
        2 => if i < 8 { v } else { 0 } // first row only
        _ => v
      }
    }
    let stride = 11
    let expect = FixedArray::make(8 * stride + 3, -1)
    let got = FixedArray::make(8 * stride + 3, -1)
    jpeg_idct_islow(coef, ws, expect, 3, stride)
    jpeg_idct(coef, ws, got, 3, stride)
    assert_eq(got, expect)
  }
}

///|
test "jpeg upsample: h1v2 fancy (4:4:0) matches libjpeg's formula" {
  // 2 x 2 chroma samples (stride 8) -> 2 x 4 output.
  let src = FixedArray::make(16, 0)
  src[0] = 10
  src[1] = 200
  src[8] = 100
  src[9] = 0
  let out = jpeg_upsample(src, 8, 2, 2, 1, 1, 1, 2, 2, 4)
  // Row 0: (3*row0 + row0 (replicated above) + 1) >> 2
  // Row 1: (3*row0 + row1 + 2) >> 2, row 2: (3*row1 + row0 + 1) >> 2,
  // row 3: (3*row1 + row1 (replicated below) + 2) >> 2
  let expect : FixedArray[Int32] = [
    (40 + 1) >> 2,
    (800 + 1) >> 2,
    (30 + 100 + 2) >> 2,
    (600 + 0 + 2) >> 2,
    (300 + 10 + 1) >> 2,
    (0 + 200 + 1) >> 2,
    (400 + 2) >> 2,
    (0 + 2) >> 2,
  ]
  assert_eq(out, expect)
}
