///|
/// 4x2 GIF89a with a 4-entry global table and the given LZW image data.
fn tiny_gif(lzw : Bytes, trailer : Bool) -> Bytes {
  let head = b"GIF89a\x04\x00\x02\x00\x81\x00\x00\x00\x00\x00\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF,\x00\x00\x00\x00\x04\x00\x02\x00\x00\x02"
  let buf = Buffer()
  buf.write_bytes(head)
  buf.write_byte(lzw.length().to_byte())
  buf.write_bytes(lzw)
  buf.write_byte(b'\x00')
  if trailer {
    buf.write_byte(b'\x3B')
  }
  buf.to_bytes()
}

///|
test "gif: LZW stream ending early leaves remaining pixels at index 0" {
  // Codes (3 bits, LSB-first): clear(4), 1, 2, EOI(5) -> pixels 1, 2 only.
  // bits: 100 001 010 101 -> bytes 0x8C 0x0A
  let img = @image.decode_gif(tiny_gif(b"\x8C\x0A", true))
  assert_eq(img.width, 4)
  assert_eq(img.height, 2)
  // pixel 0 = index 1 (red), pixel 1 = index 2 (green), rest = index 0 (black)
  assert_eq(img.data[0:4].to_owned(), b"\xFF\x00\x00\xFF")
  assert_eq(img.data[4:8].to_owned(), b"\x00\xFF\x00\xFF")
  for i in 2..<8 {
    assert_eq(img.data[i * 4:i * 4 + 4].to_owned(), b"\x00\x00\x00\xFF")
  }
}

///|
test "gif: missing trailer is accepted" {
  let img = @image.decode_gif(tiny_gif(b"\x8C\x0A", false))
  assert_eq(img.width, 4)
}

///|
test "gif: invalid and truncated input" {
  let bad = Ok(@image.decode_gif(b"GIF88a\x01\x00\x01\x00")) catch {
    e => Err(e)
  }
  assert_true(bad is Err(@image.InvalidSignature(_)))
  let full = tiny_gif(b"\x8C\x0A", true)
  let cut = full[0:full.length() - 4].to_owned()
  let truncated = Ok(@image.decode_gif(cut)) catch { e => Err(e) }
  assert_true(truncated is Err(@image.CorruptData(_)))
  let no_image = Ok(@image.decode_gif(full[0:25].to_owned() + b"\x3B")) catch {
    e => Err(e)
  }
  assert_true(no_image is Err(@image.MissingChunk(_)))
}

///|
test "gif: encode_gif roundtrip with transparency" {
  let data = FixedArray::make(5 * 3 * 4, b'\x00')
  for i in 0..<15 {
    let o = i * 4
    if i % 4 == 0 {
      // fully transparent
      continue
    }
    data[o] = (i * 40).to_byte()
    data[o + 1] = (255 - i * 10).to_byte()
    data[o + 2] = (i * 7).to_byte()
    data[o + 3] = b'\xFF'
  }
  let img : @image.ImageData = {
    width: 5,
    height: 3,
    data: Bytes::from_array(data),
  }
  let gif = @image.encode_gif(img)
  assert_eq(@image.decode_gif(gif), img)
  let anim = @image.decode_gif_frames(gif)
  assert_eq(anim.frames.length(), 1)
  assert_eq(anim.loop_count, None)
}
