///|
/// IHDR (color type, bit depth) of a PNG.
fn png_opt_ihdr(png : Bytes) -> (Int32, Int32) {
  (png[25].to_int(), png[24].to_int())
}

///|
fn png_opt_image(
  w : Int32,
  h : Int32,
  f : (Int32, Int32) -> (Int32, Int32, Int32, Int32),
) -> @image.ImageData {
  let buf = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let (r, g, b, a) = f(x, y)
      let o = (y * w + x) * 4
      buf[o] = r.to_byte()
      buf[o + 1] = g.to_byte()
      buf[o + 2] = b.to_byte()
      buf[o + 3] = a.to_byte()
    }
  }
  { width: w, height: h, data: Bytes::from_array(buf), }
}

///|
test "encode_png color modes round-trip and set IHDR" {
  // 300 distinct colors, so Auto cannot use a palette.
  let rgba = png_opt_image(20, 15, fn(x, y) {
    (x * 12, y * 17, x * y, (x + y) * 7)
  })
  let rgb = png_opt_image(20, 15, fn(x, y) { (x * 12, y * 17, x * y, 255) })
  let gray = png_opt_image(13, 9, fn(x, y) {
    let v = x * 17 + y
    (v, v, v, 255)
  })
  let gray_alpha = png_opt_image(13, 9, fn(x, y) {
    let v = x * 17
    (v, v, v, y * 28)
  })
  let few = png_opt_image(13, 9, fn(x, y) {
    match (x + y) % 3 {
      0 => (255, 0, 0, 255)
      1 => (0, 0, 255, 128)
      _ => (0, 0, 0, 0)
    }
  })
  let many = png_opt_image(16, 16, fn(x, y) {
    if x == 0 {
      (0, 0, 0, 0)
    } else {
      (x * 15, y * 16, 7, 255)
    }
  })
  let cases : Array[(@image.ImageData, @image.PngColorMode, Int32, Int32)] = [
    (rgba, @image.Rgba, 6, 8),
    (rgb, @image.Rgb, 2, 8),
    (gray, @image.Gray, 0, 8),
    (gray_alpha, @image.GrayAlpha, 4, 8),
    (few, @image.Palette, 3, 2),
    (many, @image.Palette, 3, 8),
    // Auto
    (rgba, @image.Auto, 6, 8),
    (rgb, @image.Auto, 2, 8),
    (gray, @image.Auto, 0, 8),
    (gray_alpha, @image.Auto, 4, 8),
    (few, @image.Auto, 3, 2),
  ]
  for c in cases {
    let (img, mode, ct, depth) = c
    let png = @image.encode_png(img, color=mode)
    assert_eq(png_opt_ihdr(png), (ct, depth))
    assert_eq(@image.decode_png(png), img)
  }
}

///|
test "encode_png explicit modes reject images they cannot represent" {
  let rgba = png_opt_image(4, 4, fn(x, y) { (x * 60, y * 60, 9, 100) })
  let colorful = png_opt_image(20, 20, fn(x, y) { (x * 12, y * 12, x + y, 255) })
  for mode in [@image.Rgb, @image.Gray, @image.GrayAlpha] {
    let r = Ok(@image.encode_png(rgba, color=mode)) catch { e => Err(e) }
    assert_true(r is Err(@image.InvalidData(_)))
  }
  let r = Ok(@image.encode_png(colorful, color=@image.Palette)) catch {
    e => Err(e)
  }
  assert_true(r is Err(@image.InvalidData(_)))
}

///|
test "encode_png compression levels round-trip; Best is smallest" {
  let img = png_opt_image(64, 48, fn(x, y) { (x * 4, y * 5, (x ^ y) * 3, 255) })
  let sizes = []
  for level in [@image.Stored, @image.Fast, @image.Default, @image.Best] {
    let png = @image.encode_png(img, compression=level)
    assert_eq(@image.decode_png(png), img)
    sizes.push(png.length())
  }
  // Stored > Default >= Best
  assert_true(sizes[0] > sizes[2])
  assert_true(sizes[3] <= sizes[2])
}
