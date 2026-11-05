///|
/// Deterministic pseudo-random bytes.
fn filter_test_bytes(len : Int32, seed : Int32) -> Bytes {
  let buf = FixedArray::make(len, b'\x00')
  let mut s = seed
  for i in 0..<len {
    s = (s * 1103515245 + 12345) & 0x7FFFFFFF
    buf[i] = (s >> 16).to_byte()
  }
  Bytes::from_array(buf)
}

///|
// On wasm, `*_impl` run the SIMD kernels; compare them against the scalar
// `*_range` references for every bpp and many row lengths (heads, tails
// and the bpp = 3 lane spill).
test "png filters: SIMD/impl matches scalar reference" {
  for bpp in 1..<=8 {
    for len in 0..<80 {
      let row = filter_test_bytes(len, bpp * 1000 + len)
      let prev = filter_test_bytes(len, bpp * 7777 + len)
      // encode side
      let avg_ref = FixedArray::make(len, b'\x00')
      apply_average_range(row, prev, avg_ref, bpp, 0, len)
      assert_eq(apply_filter_average_impl(row, prev, bpp), avg_ref)
      let paeth_ref = FixedArray::make(len, b'\x00')
      apply_paeth_range(row, prev, paeth_ref, bpp, 0, len)
      assert_eq(apply_filter_paeth_impl(row, prev, bpp), paeth_ref)
      assert_eq(filter_sum_impl(paeth_ref), filter_sum_range(paeth_ref, 0, len))
      // decode side
      let sub_ref = FixedArray::make(len, b'\x00')
      reconstruct_sub_range(row, sub_ref, bpp, 0, len)
      let sub_got = FixedArray::make(len, b'\x00')
      reconstruct_filter_sub_impl(row, sub_got, bpp)
      assert_eq(sub_got, sub_ref)
      let ravg_ref = FixedArray::make(len, b'\x00')
      reconstruct_average_range(row, prev, ravg_ref, bpp, 0, len)
      let ravg_got = FixedArray::make(len, b'\x00')
      reconstruct_filter_average_impl(row, prev, ravg_got, bpp)
      assert_eq(ravg_got, ravg_ref)
      let rpaeth_ref = FixedArray::make(len, b'\x00')
      reconstruct_paeth_range(row, prev, rpaeth_ref, bpp, 0, len)
      let rpaeth_got = FixedArray::make(len, b'\x00')
      reconstruct_filter_paeth_impl(row, prev, rpaeth_got, bpp)
      assert_eq(rpaeth_got, rpaeth_ref)
    }
  }
}

///|
test "png filters: filter then reconstruct roundtrips" {
  let filters = [
    apply_filter_none, apply_filter_sub, apply_filter_up, apply_filter_average, apply_filter_paeth,
  ]
  for bpp in 1..<=8 {
    for len in [0, 1, 3, 4, 7, 16, 17, 19, 33, 64, 67] {
      let row = filter_test_bytes(len, bpp * 31 + len)
      let prev = filter_test_bytes(len, bpp * 57 + len)
      for ft, f in filters {
        let filtered = Bytes::from_array(f(row, prev, bpp))
        assert_eq(reconstruct_row(ft, filtered, prev, bpp), row)
      }
    }
  }
}

///|
test "png filters: SIMD color expansion matches scalar" {
  for width in 0..<40 {
    let rgb = filter_test_bytes(width * 3, width + 1)
    let out = FixedArray::make(width * 4, b'\x00')
    rgb8_to_rgba(rgb, out, width)
    for i in 0..<width {
      assert_eq(out[i * 4], rgb[i * 3])
      assert_eq(out[i * 4 + 1], rgb[i * 3 + 1])
      assert_eq(out[i * 4 + 2], rgb[i * 3 + 2])
      assert_eq(out[i * 4 + 3], b'\xFF')
    }
    let gray = filter_test_bytes(width, width + 2)
    gray8_to_rgba(gray, out, width)
    for i in 0..<width {
      assert_eq(out[i * 4], gray[i])
      assert_eq(out[i * 4 + 1], gray[i])
      assert_eq(out[i * 4 + 2], gray[i])
      assert_eq(out[i * 4 + 3], b'\xFF')
    }
    let ga = filter_test_bytes(width * 2, width + 3)
    gray_alpha8_to_rgba(ga, out, width)
    for i in 0..<width {
      assert_eq(out[i * 4], ga[i * 2])
      assert_eq(out[i * 4 + 1], ga[i * 2])
      assert_eq(out[i * 4 + 2], ga[i * 2])
      assert_eq(out[i * 4 + 3], ga[i * 2 + 1])
    }
  }
}
