///|
fn webp_join(parts : Array[Bytes]) -> Bytes {
  let buf = Buffer()
  for p in parts {
    buf.write_bytes(p)
  }
  buf.to_bytes()
}

///|
fn webp_crc(px : Bytes) -> Int32 {
  @zlib.crc32_fixed(px.to_fixedarray()).reinterpret_as_int()
}

///|
test "webp: EXIF orientation chunk (Pillow)" {
  let webp = webp_join([
    b"\x52\x49\x46\x46\x70\x00\x00\x00\x57\x45\x42\x50\x56\x50\x38\x58\x0A\x00\x00\x00\x08\x00\x00\x00\x04\x00\x00\x02\x00\x00\x56\x50\x38\x4C\x2F\x00\x00\x00\x2F\x04\x80\x00\x00\x77\x40\x90\x6D\x33",
    b"\xC4\x22\xDC\x1F\xE4\x0C\x23\x33\x64\xF3\xDF\x83\x0C\xB0\xBC\x00\x06\x01\x20\x11\xA8\x58\x52\x48\x21\xB8\x14\x56\x18\x35\xA2\xFF\xE1\x21\xC7\xBE\x00\x00\x45\x58\x49\x46\x1A\x00\x00\x00\x4D\x4D",
    b"\x00\x2A\x00\x00\x00\x08\x00\x01\x01\x12\x00\x03\x00\x00\x00\x01\x00\x06\x00\x00\x00\x00\x00\x00",
  ])
  assert_eq(@image.read_exif_orientation(webp), Some(6))
  let up = @image.decode_image_upright(webp)
  assert_eq(up.width, 3)
  assert_eq(up.height, 5)
  assert_eq(@image.detect_image_format(webp), Some(@image.WebP))
}

///|
test "webp: encode_webp output decodes to the input" {
  let w = 37
  let h = 23
  let px = FixedArray::make(w * h * 4, b'\x00')
  for i in 0..<(w * h) {
    let x = i % w
    let y = i / w
    px[i * 4] = (x * 7 + y).to_byte()
    px[i * 4 + 1] = (y * 11).to_byte()
    px[i * 4 + 2] = (x * y).to_byte()
    px[i * 4 + 3] = (if (x + y) % 5 == 0 { 0 } else { 200 + x }).to_byte()
  }
  let img : @image.ImageData = {
    width: w,
    height: h,
    data: Bytes::from_array(px),
  }
  let back = @image.decode_webp(@image.encode_webp(img))
  assert_eq(back.width, w)
  assert_eq(back.height, h)
  assert_eq(back.data, img.data)
  let solid : @image.ImageData = {
    width: 3,
    height: 2,
    data: Bytes::make(3 * 2 * 4, b'\x7F'),
  }
  assert_eq(@image.decode_webp(@image.encode_webp(solid)).data, solid.data)
}
