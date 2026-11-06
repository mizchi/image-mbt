///|
test "jpeg_encode rgb to ycc matches libjpeg" {
  // white, black, red, (12, 200, 99)
  let px = b"\xFF\xFF\xFF\xFF\x00\x00\x00\xFF\xFF\x00\x00\xFF\x0C\xC8\x63\xFF"
  let (y, cb, cr) = jpeg_rgb_to_ycc(px, 4)
  assert_eq(y, [255, 0, 76, 132])
  assert_eq(cb, [128, 128, 85, 109])
  assert_eq(cr, [128, 128, 255, 42])
}

///|
test "jpeg_encode jpeg_scale_quant_table quality 1 50 100" {
  let q1 = jpeg_scale_quant_table(jpeg_std_lum_quant, 1)
  let q50 = jpeg_scale_quant_table(jpeg_std_lum_quant, 50)
  let q100 = jpeg_scale_quant_table(jpeg_std_lum_quant, 100)

  assert_eq(q50[0], jpeg_std_lum_quant[0])
  assert_eq(q50[63], jpeg_std_lum_quant[63])
  assert_eq(q1[0], 255)
  assert_eq(q1[63], 255)
  assert_eq(q100[0], 1)
  assert_eq(q100[63], 1)
}

///|
test "jpeg_encode jpeg_bit_category basic" {
  assert_eq(jpeg_bit_category(0), 0)
  assert_eq(jpeg_bit_category(1), 1)
  assert_eq(jpeg_bit_category(-1), 1)
  assert_eq(jpeg_bit_category(127), 7)
  assert_eq(jpeg_bit_category(-127), 7)
}

///|
test "jpeg_encode islow fdct of a constant block has dc only" {
  // 150 - 128 = 22; the islow FDCT output is scaled by 8: DC = 22 * 8 * 8.
  let data = FixedArray::make(64, 22)
  jpeg_fdct_islow(data)
  assert_eq(data[0], 1408)
  for i in 1..<64 {
    assert_eq(data[i], 0)
  }
}
