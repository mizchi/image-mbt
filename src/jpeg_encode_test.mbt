///|
fn make_solid_image(
  width : Int32,
  height : Int32,
  r : Int32,
  g : Int32,
  b : Int32,
) -> @image.ImageData {
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for i in 0..<(width * height) {
    let idx = i * 4
    buf[idx] = r.to_byte()
    buf[idx + 1] = g.to_byte()
    buf[idx + 2] = b.to_byte()
    buf[idx + 3] = b'\xFF'
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
fn make_gradient_image(width : Int32, height : Int32) -> @image.ImageData {
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      let r = x * 255 / (width - 1)
      let g = y * 255 / (height - 1)
      let b = (x + y) * 255 / (width + height - 2)
      buf[idx] = r.to_byte()
      buf[idx + 1] = g.to_byte()
      buf[idx + 2] = b.to_byte()
      buf[idx + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
fn assert_image_rgb_close(
  actual : @image.ImageData,
  expected : @image.ImageData,
  tol : Int32,
) -> Unit raise {
  assert_eq(actual.width, expected.width)
  assert_eq(actual.height, expected.height)
  assert_eq(actual.data.length(), expected.data.length())
  for i in 0..<(actual.width * actual.height) {
    let idx = i * 4
    let dr = (actual.data[idx].to_int() - expected.data[idx].to_int()).abs()
    let dg = (actual.data[idx + 1].to_int() - expected.data[idx + 1].to_int()).abs()
    let db = (actual.data[idx + 2].to_int() - expected.data[idx + 2].to_int()).abs()
    assert_true(dr <= tol)
    assert_true(dg <= tol)
    assert_true(db <= tol)
    assert_eq(actual.data[idx + 3].to_int(), 255)
  }
}

///|
test "jpeg_encode 8x8 solid roundtrip" {
  let original = make_solid_image(8, 8, 220, 40, 90)
  let jpeg = @image.encode_jpeg(original, quality=95)
  let decoded = @image.decode_jpeg(jpeg)
  assert_image_rgb_close(decoded, original, 3)
}

///|
test "jpeg_encode 16x16 gradient roundtrip" {
  let original = make_gradient_image(16, 16)
  let jpeg = @image.encode_jpeg(original, quality=90)
  let decoded = @image.decode_jpeg(jpeg)
  assert_image_rgb_close(decoded, original, 20)
}

///|
test "jpeg_encode non 8 multiple roundtrip" {
  let original = make_gradient_image(10, 10)
  let jpeg = @image.encode_jpeg(original, quality=90)
  let decoded = @image.decode_jpeg(jpeg)
  assert_image_rgb_close(decoded, original, 20)
}

///|
test "jpeg_encode invalid dimensions and data length" {
  let img_invalid_dim : @image.ImageData = {
    width: 0,
    height: 1,
    data: Bytes::new(0),
  }
  try @image.encode_jpeg(img_invalid_dim) catch {
    _ => ()
  } noraise {
    _ => fail("expected encode_jpeg to raise for invalid dimensions")
  }

  let img_invalid_data : @image.ImageData = {
    width: 2,
    height: 2,
    data: Bytes::new(4),
  }
  try @image.encode_jpeg(img_invalid_data) catch {
    _ => ()
  } noraise {
    _ => fail("expected encode_jpeg to raise for invalid data length")
  }
}

///|
test "jpeg_encode quality affects file size" {
  let img = make_gradient_image(32, 32)
  let jpeg_q10 = @image.encode_jpeg(img, quality=10)
  let jpeg_q95 = @image.encode_jpeg(img, quality=95)
  assert_true(jpeg_q10.length() < jpeg_q95.length())
}

///|
test "jpeg optimize: same pixels as standard tables, smaller file" {
  let w = 40
  let h = 30
  let px = FixedArray::make(w * h * 4, b'\xFF')
  for i in 0..<(w * h) {
    px[i * 4] = (i * 7).to_byte()
    px[i * 4 + 1] = (i / 3).to_byte()
    px[i * 4 + 2] = (i % 50 * 5).to_byte()
  }
  let img : @image.ImageData = {
    width: w,
    height: h,
    data: Bytes::from_array(px),
  }
  for sub in [@image.Yuv444, @image.Yuv422, @image.Yuv420] {
    let std = @image.encode_jpeg(img, subsampling=sub)
    let opt = @image.encode_jpeg(img, subsampling=sub, optimize=true)
    assert_true(opt.length() < std.length())
    assert_eq(@image.decode_jpeg(opt).data, @image.decode_jpeg(std).data)
  }
}
