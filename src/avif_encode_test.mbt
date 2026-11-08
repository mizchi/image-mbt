///|
fn avif_test_image(w : Int32, h : Int32, alpha : Bool) -> @image.ImageData {
  let data = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let i = (y * w + x) * 4
      data[i] = (x * 255 / w).to_byte()
      data[i + 1] = (y * 255 / h).to_byte()
      data[i + 2] = ((x ^ y) * 7).to_byte()
      data[i + 3] = if alpha && (x + y) % 5 == 0 { b'\x40' } else { b'\xff' }
    }
  }
  { width: w, height: h, data: Bytes::from_array(data), }
}

///|
fn avif_test_u32(b : Bytes, o : Int32) -> Int32 {
  (b[o].to_int() << 24) |
  (b[o + 1].to_int() << 16) |
  (b[o + 2].to_int() << 8) |
  b[o + 3].to_int()
}

///|
/// Top-level box types and the iloc extents (offset, length) of a file.
fn avif_test_boxes(b : Bytes) -> (Array[String], Array[(Int32, Int32)]) {
  let types : Array[String] = []
  let extents : Array[(Int32, Int32)] = []
  let mut o = 0
  while o + 8 <= b.length() {
    let size = avif_test_u32(b, o)
    let t = StringBuilder()
    for k in 4..<8 {
      t.write_char(b[o + k].to_int().unsafe_to_char())
    }
    let typ = t.to_string()
    types.push(typ)
    if typ == "meta" {
      // Children after the full box header.
      let mut c = o + 12
      while c + 8 <= o + size {
        let cs = avif_test_u32(b, c)
        if b[c + 4] == b'i' &&
          b[c + 5] == b'l' &&
          b[c + 6] == b'o' &&
          b[c + 7] == b'c' {
          let count = (b[c + 14].to_int() << 8) | b[c + 15].to_int()
          let mut p = c + 16
          for _ in 0..<count {
            extents.push((avif_test_u32(b, p + 6), avif_test_u32(b, p + 10)))
            p += 14
          }
        }
        c += cs
      }
    }
    o += size
  }
  (types, extents)
}

///|
test "encode_avif writes a well-formed AVIF" {
  let avif = @image.encode_avif(avif_test_image(37, 29, false))
  let (types, extents) = avif_test_boxes(avif)
  assert_eq(types, ["ftyp", "meta", "mdat"])
  assert_eq(avif[8:12], b"avif")
  assert_eq(extents.length(), 1)
  let (off, len) = extents[0]
  assert_true(off > 0 && off + len == avif.length())
  // The item starts with a sequence header OBU.
  assert_eq(avif[off].to_int(), 0x0a)
}

///|
test "encode_avif stores alpha as an auxiliary item" {
  let avif = @image.encode_avif(avif_test_image(40, 24, true))
  let (_, extents) = avif_test_boxes(avif)
  assert_eq(extents.length(), 2)
  let (off2, len2) = extents[1]
  assert_eq(off2 + len2, avif.length())
  assert_eq(avif[off2].to_int(), 0x0a)
}

///|
test "encode_avif quality controls the size" {
  let img = avif_test_image(64, 64, false)
  let small = @image.encode_avif(img, quality=20)
  let large = @image.encode_avif(img, quality=95)
  assert_true(small.length() < large.length())
  // Deterministic.
  assert_eq(@image.encode_avif(img, quality=20), small)
}

///|
test "encode_avif handles tiny and odd sizes" {
  for size in [(1, 1), (2, 3), (9, 1), (65, 66)] {
    let (w, h) = size
    let avif = @image.encode_avif(avif_test_image(w, h, false))
    let (types, _) = avif_test_boxes(avif)
    assert_eq(types, ["ftyp", "meta", "mdat"])
  }
}

///|
test "encode_avif rejects invalid images" {
  let bad : @image.ImageData = { width: 2, height: 2, data: b"\x00\x00", }
  let mut failed = false
  ignore(@image.encode_avif(bad)) catch {
    _ => failed = true
  }
  assert_true(failed)
}
