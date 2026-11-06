///|
fn make_webp_test_image() -> @image.ImageData {
  let width = 3
  let height = 2
  let data = b"\xFF\x00\x00\xFF\x00\x80\xFF\xFF\x10\x20\x30\x40\x11\x22\x33\x44\xFE\xDC\xBA\x98\x01\x02\x03\x00"
  { width, height, data, }
}

///|
fn make_webp_solid_image(
  width : Int32,
  height : Int32,
  r : Int32,
  g : Int32,
  b : Int32,
  a : Int32,
) -> @image.ImageData {
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for i in 0..<(width * height) {
    let offset = i * 4
    buf[offset] = r.to_byte()
    buf[offset + 1] = g.to_byte()
    buf[offset + 2] = b.to_byte()
    buf[offset + 3] = a.to_byte()
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
fn make_webp_subtract_green_test_image() -> @image.ImageData {
  let width = 4
  let height = 1
  let data = b"\x0B\x0A\x0C\xFF\x15\x14\x16\xFF\x1F\x1E\x20\xFF\x29\x28\x2A\xFF"
  { width, height, data, }
}

///|
fn make_webp_color_cache_test_image() -> @image.ImageData {
  let width = 32
  let height = 32
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let offset = (y * width + x) * 4
      let tile = x % 2 + y % 2 * 2
      match tile {
        0 => {
          buf[offset] = b'\x10'
          buf[offset + 1] = b'\x20'
          buf[offset + 2] = b'\x30'
        }
        1 => {
          buf[offset] = b'\x90'
          buf[offset + 1] = b'\x10'
          buf[offset + 2] = b'\xB0'
        }
        2 => {
          buf[offset] = b'\x12'
          buf[offset + 1] = b'\x34'
          buf[offset + 2] = b'\xF0'
        }
        _ => {
          buf[offset] = b'\xBA'
          buf[offset + 1] = b'\xDA'
          buf[offset + 2] = b'\x55'
        }
      }
      buf[offset + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
test "webp_encode basic signature" {
  let img : @image.ImageData = {
    width: 1,
    height: 1,
    data: b"\xAA\xBB\xCC\xDD",
  }
  let webp = @image.encode_webp(img)
  assert_eq(webp[0].to_int(), 0x52)
  assert_eq(webp[1].to_int(), 0x49)
  assert_eq(webp[2].to_int(), 0x46)
  assert_eq(webp[3].to_int(), 0x46)
  assert_eq(webp[8].to_int(), 0x57)
  assert_eq(webp[9].to_int(), 0x45)
  assert_eq(webp[10].to_int(), 0x42)
  assert_eq(webp[11].to_int(), 0x50)
  assert_eq(webp[12].to_int(), 0x56)
  assert_eq(webp[13].to_int(), 0x50)
  assert_eq(webp[14].to_int(), 0x38)
  assert_eq(webp[15].to_int(), 0x4C)
}

///|
fn webp_enc_roundtrip(img : @image.ImageData) -> Bytes raise {
  let webp = @image.encode_webp(img)
  let back = @image.decode_webp(webp)
  assert_eq(back.width, img.width)
  assert_eq(back.height, img.height)
  assert_eq(back.data, img.data)
  webp
}

///|
/// Pseudo-random RGBA image: `colors` > 0 draws from a palette of that
/// many colors, otherwise a noisy gradient.
fn webp_enc_image(
  w : Int32,
  h : Int32,
  seed : Int32,
  colors : Int32,
) -> @image.ImageData {
  let px = FixedArray::make(w * h * 4, b'\x00')
  let mut s = seed
  for y in 0..<h {
    for x in 0..<w {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF
      let o = (y * w + x) * 4
      if colors > 0 {
        let c = (x / 3 + y / 2 + (s >> 20) % 2) % colors
        px[o] = (c * 53).to_byte()
        px[o + 1] = (c * 97 + 13).to_byte()
        px[o + 2] = (c * 31).to_byte()
        px[o + 3] = (if c % 3 == 0 { 255 } else { c * 40 }).to_byte()
      } else {
        let n = (s >> 16) % 9
        px[o] = (x * 4 + n).to_byte()
        px[o + 1] = (y * 3 + x + n).to_byte()
        px[o + 2] = (x * y / 8 + n).to_byte()
        px[o + 3] = (if (x + y) % 17 == 0 { 0 } else { 255 - y }).to_byte()
      }
    }
  }
  { width: w, height: h, data: Bytes::from_array(px), }
}

///|
test "webp_encode round trips (palettes, gradients, alpha, odd sizes)" {
  ignore(webp_enc_roundtrip(make_webp_test_image()))
  ignore(webp_enc_roundtrip(make_webp_subtract_green_test_image()))
  ignore(webp_enc_roundtrip(make_webp_color_cache_test_image()))
  for colors in [1, 2, 3, 4, 5, 16, 17, 200, 256, 0] {
    for size in [(1, 1), (7, 3), (33, 17), (64, 64)] {
      ignore(
        webp_enc_roundtrip(
          webp_enc_image(size.0, size.1, colors + size.0, colors),
        ),
      )
    }
  }
  // > 256 colors and long LZ77 runs.
  ignore(webp_enc_roundtrip(webp_enc_image(300, 40, 7, 0)))
  ignore(webp_enc_roundtrip(make_webp_solid_image(200, 100, 1, 2, 3, 4)))
}

///|
test "webp_encode compresses repetitive images well" {
  let solid = make_webp_solid_image(16, 16, 0x80, 0x80, 0x80, 0xFF)
  assert_true(webp_enc_roundtrip(solid).length() < 64)
  // 4-color 32x32 checker: palette + LZ77.
  assert_true(
    webp_enc_roundtrip(make_webp_color_cache_test_image()).length() < 100,
  )
  // A large solid image is a handful of LZ77 copies.
  let big = make_webp_solid_image(1000, 1000, 9, 8, 7, 255)
  assert_true(webp_enc_roundtrip(big).length() < 200)
}

///|
test "webp_encode preserves transparent rgb" {
  let img : @image.ImageData = {
    width: 2,
    height: 1,
    data: b"\x10\x20\x30\x00\xAA\xBB\xCC\xFF",
  }
  ignore(webp_enc_roundtrip(img))
}

///|
test "webp_encode invalid dimensions and data length" {
  let img_invalid_dim : @image.ImageData = {
    width: 0,
    height: 1,
    data: Bytes::new(0),
  }
  try @image.encode_webp(img_invalid_dim) catch {
    _ => ()
  } noraise {
    _ => fail("expected encode_webp to raise for invalid dimensions")
  }

  let img_invalid_data : @image.ImageData = {
    width: 2,
    height: 2,
    data: Bytes::new(4),
  }
  try @image.encode_webp(img_invalid_data) catch {
    _ => ()
  } noraise {
    _ => fail("expected encode_webp to raise for invalid data length")
  }
}
