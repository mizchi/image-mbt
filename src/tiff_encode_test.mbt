///|
fn tiff_enc_image(
  w : Int32,
  h : Int32,
  seed : Int32,
  alpha : Bool,
  noise : Int32,
) -> @image.ImageData {
  let px = FixedArray::make(w * h * 4, b'\xFF')
  let mut s = seed
  for y in 0..<h {
    for x in 0..<w {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF
      let n = if noise > 0 { (s >> 16) % noise } else { 0 }
      let o = (y * w + x) * 4
      px[o] = (x * 5 + n).to_byte()
      px[o + 1] = (y * 3 + n).to_byte()
      px[o + 2] = ((x ^ y) + n).to_byte()
      if alpha {
        px[o + 3] = ((x + y) * 9).to_byte()
      }
    }
  }
  { width: w, height: h, data: Bytes::from_array(px), }
}

///|
test "encode_tiff round trips every compression" {
  let comps = [
    @image.NoCompression,
    @image.Lzw,
    @image.Deflate,
    @image.PackBits,
  ]
  let imgs = [
    tiff_enc_image(1, 1, 1, false, 0),
    tiff_enc_image(37, 23, 2, false, 0),
    tiff_enc_image(37, 23, 3, true, 7),
    // Noisy, larger than one strip and than one LZW table.
    tiff_enc_image(300, 120, 4, true, 256),
    tiff_enc_image(5000, 3, 5, false, 3),
  ]
  for c in comps {
    for img in imgs {
      let tif = @image.encode_tiff(img, compression=c)
      assert_eq(@image.detect_image_format(tif), Some(@image.Tiff))
      let back = @image.decode_tiff(tif)
      assert_eq((back.width, back.height), (img.width, img.height))
      assert_eq(back.data, img.data)
      assert_eq(@image.decode_tiff_pages(tif).length(), 1)
    }
  }
}

///|
test "encode_tiff compression actually compresses" {
  let img = tiff_enc_image(200, 100, 6, false, 0)
  let raw = @image.encode_tiff(img, compression=@image.NoCompression).length()
  assert_true(@image.encode_tiff(img).length() * 4 < raw)
  assert_true(
    @image.encode_tiff(img, compression=@image.Deflate).length() * 4 < raw,
  )
}

///|
test "decode_tiff_pages rejects a looping IFD chain" {
  let tif = @image.encode_tiff(tiff_enc_image(4, 4, 7, false, 0)).to_fixedarray()
  // The next-IFD pointer is the last 4 bytes of the IFD; point it back.
  let ifd = tif[4].to_int() | (tif[5].to_int() << 8) | (tif[6].to_int() << 16)
  let n = tif[ifd].to_int() | (tif[ifd + 1].to_int() << 8)
  let p = ifd + 2 + n * 12
  for i in 0..<4 {
    tif[p + i] = tif[4 + i]
  }
  let r = Ok(@image.decode_tiff_pages(Bytes::from_array(tif))) catch {
    e => Err(e)
  }
  assert_true(r is Err(@image.CorruptData(_)))
}
