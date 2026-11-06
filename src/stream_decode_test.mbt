///|
fn make_stream_dispatch_image(
  width : Int32,
  height : Int32,
) -> @image.ImageData {
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      buf[idx] = (x * 255 / (width - 1)).to_byte()
      buf[idx + 1] = (y * 255 / (height - 1)).to_byte()
      buf[idx + 2] = ((x + y) * 255 / (width + height - 2)).to_byte()
      buf[idx + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
fn concat_stream_rows(
  rows : Array[Bytes],
  width : Int32,
  height : Int32,
) -> Bytes raise {
  let total = width * height * 4
  let buf = FixedArray::make(total, b'\x00')
  let mut offset = 0
  for row in rows {
    let row_len = width * 4
    assert_eq(row.length(), row_len)
    buf.blit_from_bytes(offset, row, 0, row_len)
    offset += row_len
  }
  assert_eq(offset, total)
  Bytes::from_array(buf)
}

///|
test "decode_image_stream PNG dispatch" {
  let original = make_stream_dispatch_image(8, 6)
  let png = @image.encode_png(original)
  let rows : Array[Bytes] = []
  let info = @image.decode_image_stream(png, on_row=fn(_y, row) {
    rows.push(row)
  })
  assert_eq(info.format, Png)
  assert_eq(info.width, 8)
  assert_eq(info.height, 6)
  assert_eq(rows.length(), 6)
  let stream_data = concat_stream_rows(rows, 8, 6)
  let decoded = @image.decode_png(png)
  assert_eq(stream_data, decoded.data)
}

///|
test "decode_image_stream BMP dispatch" {
  let original = make_stream_dispatch_image(8, 6)
  let bmp = @image.encode_bmp(original)
  let rows : Array[Bytes] = []
  let info = @image.decode_image_stream(bmp, on_row=fn(_y, row) {
    rows.push(row)
  })
  assert_eq(info.format, Bmp)
  assert_eq(info.width, 8)
  assert_eq(info.height, 6)
  assert_eq(rows.length(), 6)
  let stream_data = concat_stream_rows(rows, 8, 6)
  let decoded = @image.decode_bmp(bmp)
  assert_eq(stream_data, decoded.data)
}

///|
test "decode_image_stream invalid signature" {
  try
    @image.decode_image_stream(b"\x00\x11\x22\x33", on_row=fn(_, _) {  })
  catch {
    _ => ()
  } noraise {
    _ => fail("expected decode_image_stream to raise for invalid signature")
  }
}

///|
test "detect_image_format and decode_image_stream for every format" {
  let data = FixedArray::make(6 * 4 * 4, b'\x00')
  for i in 0..<24 {
    data[i * 4] = (i * 10).to_byte()
    data[i * 4 + 1] = (200 - i * 5).to_byte()
    data[i * 4 + 2] = (i * 3).to_byte()
    data[i * 4 + 3] = b'\xFF'
  }
  let img : @image.ImageData = {
    width: 6,
    height: 4,
    data: Bytes::from_array(data),
  }
  let files : Array[(Bytes, @image.ImageFormat)] = [
    (@image.encode_png(img), @image.Png),
    (@image.encode_bmp(img), @image.Bmp),
    (@image.encode_jpeg(img), @image.Jpeg),
    (@image.encode_gif(img), @image.Gif),
    (@image.encode_ico(img), @image.Ico),
    (@image.encode_webp(img), @image.WebP),
  ]
  for f in files {
    let (bytes, format) = f
    assert_eq(@image.detect_image_format(bytes), Some(format))
    let buf = FixedArray::make(6 * 4 * 4, b'\x00')
    let info = @image.decode_image_stream(bytes, on_row=fn(y, row) {
      buf.blit_from_bytes(y * 24, row, 0, 24)
    })
    assert_eq(info.format, format)
    assert_eq(info.width, 6)
    assert_eq(info.height, 4)
    assert_eq(Bytes::from_array(buf), @image.decode_image(bytes).data)
  }
  assert_eq(
    @image.detect_image_format(b"II\x2A\x00\x08\x00\x00\x00"),
    Some(@image.Tiff),
  )
  assert_eq(@image.detect_image_format(b"nope"), None)
}
