///|
test "apng: OVER blending of semi-transparent pixels" {
  // dst = (200, 100, 0, 128), src = (0, 0, 255, 64)
  let dst : FixedArray[Byte] = [b'\xC8', b'\x64', b'\x00', b'\x80']
  apng_blend_over(dst, 0, b"\x00\x00\xFF\x40", 0)
  // a255 = 64*255 + 128*191 = 40768; out alpha = round(40768 / 255) = 160
  // r = round(200*128*191 / 40768) = 120, g = 60,
  // b = round(255*64*255 / 40768) = 102
  assert_eq(dst, [b'\x78', b'\x3C', b'\x66', b'\xA0'])
  // Opaque source replaces, transparent source keeps.
  apng_blend_over(dst, 0, b"\x01\x02\x03\x00", 0)
  assert_eq(dst, [b'\x78', b'\x3C', b'\x66', b'\xA0'])
  apng_blend_over(dst, 0, b"\x01\x02\x03\xFF", 0)
  assert_eq(dst, [b'\x01', b'\x02', b'\x03', b'\xFF'])
}

///|
test "apng: a plain PNG is a single frame" {
  let img : ImageData = { width: 3, height: 2, data: Bytes::make(24, b'\x7F'), }
  let png = encode_png(img)
  let anim = decode_png_frames(png)
  assert_eq(anim.frames.length(), 1)
  assert_eq(anim.frames[0].image, img)
  assert_eq(anim.plays, 0)
}

///|
/// Build a PNG from chunks (type, data).
fn apng_test_file(chunks : Array[(Bytes, Bytes)]) -> Bytes {
  let buf = Buffer()
  buf.write_bytes(b"\x89PNG\r\n\x1A\n")
  for c in chunks {
    let (t, d) = c
    let n = d.length()
    buf.write_byte((n >> 24).to_byte())
    buf.write_byte((n >> 16).to_byte())
    buf.write_byte((n >> 8).to_byte())
    buf.write_byte(n.to_byte())
    buf.write_bytes(t)
    buf.write_bytes(d)
    let crc = @zlib.crc32_fixed((t + d).to_fixedarray())
    buf.write_byte((crc >> 24).to_byte())
    buf.write_byte((crc >> 16).to_byte())
    buf.write_byte((crc >> 8).to_byte())
    buf.write_byte(crc.to_byte())
  }
  buf.to_bytes()
}

///|
fn apng_test_u32(v : Int32) -> Bytes {
  Bytes::from_array([
    (v >> 24).to_byte(),
    (v >> 16).to_byte(),
    (v >> 8).to_byte(),
    v.to_byte(),
  ])
}

///|
fn apng_test_fctl(
  seq : Int32,
  w : Int32,
  h : Int32,
  x : Int32,
  y : Int32,
) -> Bytes {
  apng_test_u32(seq) +
  apng_test_u32(w) +
  apng_test_u32(h) +
  apng_test_u32(x) +
  apng_test_u32(y) +
  b"\x00\x01\x00\x0A\x00\x00" // delay 1/10 s, dispose 0, blend 0
}

///|
test "apng: decode_png returns the default image; frame bounds are checked" {
  // 2x1 RGB: default image (frame 0) red/green, frame 1 (1x1 at 1,0) blue.
  let ihdr = apng_test_u32(2) + apng_test_u32(1) + b"\x08\x02\x00\x00\x00"
  let idat = @zlib.zlib_compress(b"\x00\xFF\x00\x00\x00\xFF\x00")
  let fdat = apng_test_u32(2) + @zlib.zlib_compress(b"\x00\x00\x00\xFF")
  let png = apng_test_file([
    (b"IHDR", ihdr),
    (b"acTL", apng_test_u32(2) + apng_test_u32(0)),
    (b"fcTL", apng_test_fctl(0, 2, 1, 0, 0)),
    (b"IDAT", idat),
    (b"fcTL", apng_test_fctl(1, 1, 1, 1, 0)),
    (b"fdAT", fdat),
    (b"IEND", b""),
  ])
  assert_eq(decode_png(png).data, b"\xFF\x00\x00\xFF\x00\xFF\x00\xFF")
  let anim = decode_png_frames(png)
  assert_eq(anim.frames.length(), 2)
  assert_eq(anim.frames[0].delay_ms, 100)
  assert_eq(anim.frames[1].image.data, b"\xFF\x00\x00\xFF\x00\x00\xFF\xFF")
  // A frame that does not fit in the canvas.
  let bad = apng_test_file([
    (b"IHDR", ihdr),
    (b"acTL", apng_test_u32(2) + apng_test_u32(0)),
    (b"fcTL", apng_test_fctl(0, 2, 1, 0, 0)),
    (b"IDAT", idat),
    (b"fcTL", apng_test_fctl(1, 2, 1, 1, 0)),
    (b"fdAT", fdat),
    (b"IEND", b""),
  ])
  let r = Ok(decode_png_frames(bad)) catch { e => Err(e) }
  assert_true(r is Err(CorruptData(_)))
  // A frame control without data.
  let missing = apng_test_file([
    (b"IHDR", ihdr),
    (b"acTL", apng_test_u32(2) + apng_test_u32(0)),
    (b"fcTL", apng_test_fctl(0, 2, 1, 0, 0)),
    (b"IDAT", idat),
    (b"fcTL", apng_test_fctl(1, 1, 1, 1, 0)),
    (b"IEND", b""),
  ])
  let r2 = Ok(decode_png_frames(missing)) catch { e => Err(e) }
  assert_true(r2 is Err(MissingChunk(_)))
}
