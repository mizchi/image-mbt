///|
/// Smooth test image (gradients plus mild noise); `alpha` adds a ramp.
fn lossy_test_image(
  w : Int32,
  h : Int32,
  seed : Int32,
  alpha : Bool,
) -> @image.ImageData {
  let px = FixedArray::make(w * h * 4, b'\xFF')
  let mut s = seed
  for y in 0..<h {
    for x in 0..<w {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF
      let n = (s >> 16) % 5
      let o = (y * w + x) * 4
      px[o] = (40 + x * 150 / w + n).to_byte()
      px[o + 1] = (60 + y * 120 / h + n).to_byte()
      px[o + 2] = (200 - (x + y) * 100 / (w + h) + n).to_byte()
      if alpha {
        px[o + 3] = ((x + y) * 6).to_byte()
      }
    }
  }
  { width: w, height: h, data: Bytes::from_array(px), }
}

///|
/// Mean squared error of the RGB channels (PSNR 30 dB = MSE 65).
fn lossy_mse(a : Bytes, b : Bytes) -> Double {
  let mut se = 0.0
  let mut n = 0
  for i in 0..<a.length() {
    if i % 4 != 3 {
      let d = (a[i].to_int() - b[i].to_int()).to_double()
      se += d * d
      n += 1
    }
  }
  se / n.to_double()
}

///|
fn lossy_crc(px : Bytes) -> Int32 {
  @zlib.crc32_fixed(px.to_fixedarray()).reinterpret_as_int()
}

///|
test "encode_webp_lossy: quality, sizes and dimensions" {
  for size in [(1, 1), (16, 16), (37, 23), (64, 48), (130, 97)] {
    let img = lossy_test_image(size.0, size.1, size.0 + size.1, false)
    let mut prev_len = 1 << 30
    for q in [95, 80, 50, 10] {
      let webp = @image.encode_webp_lossy(img, quality=q)
      assert_eq(@image.detect_image_format(webp), Some(@image.WebP))
      let back = @image.decode_webp(webp)
      assert_eq((back.width, back.height), size)
      let mse = lossy_mse(img.data, back.data)
      let limit = if q >= 80 { 20.0 } else if q >= 50 { 40.0 } else { 250.0 }
      if mse > limit {
        fail("MSE \{mse} > \{limit} for \{size.0}x\{size.1} q\{q}")
      }
      // Lower quality never makes a bigger file (allow tiny header noise).
      assert_true(webp.length() <= prev_len + 4)
      prev_len = webp.length()
    }
  }
}

///|
test "encode_webp_lossy: alpha is stored losslessly" {
  let img = lossy_test_image(45, 29, 3, true)
  let webp = @image.encode_webp_lossy(img, quality=60)
  let back = @image.decode_webp(webp)
  for i in 0..<(45 * 29) {
    assert_eq(back.data[i * 4 + 3], img.data[i * 4 + 3])
  }
  // Opaque images have no VP8X / ALPH chunks.
  let opaque_img = lossy_test_image(8, 8, 1, false)
  let simple = @image.encode_webp_lossy(opaque_img)
  assert_eq(simple[12:16].to_owned(), b"VP8 ")
}

///|
test "encode_webp_lossy: output decodes like libwebp (Pillow CRCs)" {
  // CRC-32 of Pillow's RGBA decode of these encoder outputs; our decoder
  // is libwebp-exact, so it must produce the same pixels.
  let cases = [
    (lossy_test_image(64, 48, 7, false), 75, 0x26BB811D),
    (lossy_test_image(37, 23, 8, true), 40, 0x817B9876),
    (lossy_test_image(130, 97, 9, false), 95, 0xE7EBFFA9),
  ]
  for c in cases {
    let (img, q, crc) = c
    let back = @image.decode_webp(@image.encode_webp_lossy(img, quality=q))
    assert_eq(lossy_crc(back.data), crc)
  }
}
