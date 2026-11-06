// Regression tests for malformed headers found by the fuzz test (and the
// related boundary cases): every one must raise DecodeError, never panic
// or try to allocate a huge buffer.

///|
fn robustness_png_chunk(chunk_type : Bytes, data : Bytes) -> Bytes {
  let buf = Buffer()
  let len = data.length()
  buf.write_byte((len >> 24).to_byte())
  buf.write_byte((len >> 16).to_byte())
  buf.write_byte((len >> 8).to_byte())
  buf.write_byte(len.to_byte())
  buf.write_bytes(chunk_type)
  buf.write_bytes(data)
  let crc = @zlib.crc32_fixed((chunk_type + data).to_fixedarray())
  buf.write_byte((crc >> 24).to_byte())
  buf.write_byte((crc >> 16).to_byte())
  buf.write_byte((crc >> 8).to_byte())
  buf.write_byte(crc.to_byte())
  buf.to_bytes()
}

///|
fn robustness_png(width : Bytes, height : Bytes, idat : Bytes) -> Bytes {
  b"\x89PNG\r\n\x1A\n" +
  robustness_png_chunk(b"IHDR", width + height + b"\x08\x06\x00\x00\x00") +
  robustness_png_chunk(b"IDAT", idat) +
  robustness_png_chunk(b"IEND", b"")
}

///|
fn expect_decode_error(
  name : String,
  f : () -> Unit raise @image.DecodeError,
) -> Unit raise {
  let ok = try {
    f()
    true
  } catch {
    _ => false
  }
  if ok {
    fail(name + ": expected DecodeError")
  }
}

///|
test "robustness: PNG chunk length >= 2^31" {
  // IHDR chunk whose length field is 0xFFFFFFF0 (-16 as Int).
  let png = b"\x89PNG\r\n\x1A\n\xFF\xFF\xFF\xF0IHDR\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x00\x00\x00\x00"
  expect_decode_error("png", fn() raise @image.DecodeError {
    ignore(@image.decode_png(png))
  })
}

///|
test "robustness: PNG huge dimensions" {
  let idat = @zlib.zlib_compress(b"\x00\x00\x00\x00\x00")
  let huge = robustness_png(b"\x7F\xFF\xFF\xFF", b"\x7F\xFF\xFF\xFF", idat)
  let r = Ok(@image.decode_png(huge)) catch { e => Err(e) }
  assert_true(r is Err(@image.UnsupportedFeature(_)))
  // Large but allowed (10000 x 10000): rejected by the IDAT size check,
  // before the 400 MB output buffer is allocated.
  let big = robustness_png(b"\x00\x00\x27\x10", b"\x00\x00\x27\x10", idat)
  let r2 = Ok(@image.decode_png(big)) catch { e => Err(e) }
  assert_true(r2 is Err(@image.CorruptData(_)))
}

///|
test "robustness: BMP header overflows" {
  let base = @image.encode_bmp({
    width: 2,
    height: 2,
    data: b"\x00\x00\x00\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF\x00\x00\x00\xFF",
  }).to_fixedarray()
  let patch = fn(offset : Int32, value : Int32) -> Bytes {
    let b = base.copy()
    for i in 0..<4 {
      b[offset + i] = (value >> (i * 8)).to_byte()
    }
    Bytes::from_array(b)
  }
  expect_decode_error("dib size", fn() raise @image.DecodeError {
    ignore(@image.decode_bmp(patch(14, 0x7FFFFFF0)))
  })
  expect_decode_error("pixel offset", fn() raise @image.DecodeError {
    ignore(@image.decode_bmp(patch(10, -1)))
  })
  expect_decode_error("width", fn() raise @image.DecodeError {
    ignore(@image.decode_bmp(patch(18, 0x7FFFFFFF)))
  })
  expect_decode_error("height", fn() raise @image.DecodeError {
    ignore(@image.decode_bmp(patch(22, 0x80000000)))
  })
  expect_decode_error("large", fn() raise @image.DecodeError {
    ignore(@image.decode_bmp(patch(18, 0x10000)))
  })
}

///|
test "robustness: GIF huge frame" {
  // 1x1 screen, frame descriptor claiming 65535 x 65535.
  let gif = b"GIF89a\x01\x00\x01\x00\x80\x00\x00\x00\x00\x00\xFF\xFF\xFF,\x00\x00\x00\x00\xFF\xFF\xFF\xFF\x00\x02\x02\x44\x01\x00;"
  let r = Ok(@image.decode_gif(gif)) catch { e => Err(e) }
  assert_true(r is Err(@image.UnsupportedFeature(_)))
}

///|
test "robustness: JPEG huge SOF and truncated DHT" {
  let jpg = @image.encode_jpeg({
    width: 8,
    height: 8,
    data: Bytes::make(8 * 8 * 4, b'\x80'),
  }).to_fixedarray()
  let find = fn(marker : Byte) -> Int32 {
    for i in 0..<(jpg.length() - 1) {
      if jpg[i] == b'\xFF' && jpg[i + 1] == marker {
        return i
      }
    }
    -1
  }
  // SOF0: FF C0 len(2) P(1) Y(2) X(2)
  let sof = find(b'\xC0')
  let huge = jpg.copy()
  for i in 5..<9 {
    huge[sof + i] = b'\xFF'
  }
  let r = Ok(@image.decode_jpeg(Bytes::from_array(huge))) catch { e => Err(e) }
  assert_true(r is Err(@image.UnsupportedFeature(_)))
  // DHT whose code counts promise more symbols than the segment holds.
  let dht = find(b'\xC4')
  let bad = jpg.copy()
  for i in 0..<16 {
    bad[dht + 5 + i] = b'\xFF'
  }
  expect_decode_error("dht", fn() raise @image.DecodeError {
    ignore(@image.decode_jpeg(Bytes::from_array(bad)))
  })
}

///|
test "robustness: ICO directory offset + size overflow" {
  // One entry: size 0x7FFFFFFF at offset 0x7FFFFFFF. offset + size wraps
  // around; the entry must be rejected by the directory bounds check.
  let ico = b"\x00\x00\x01\x00\x01\x00\x10\x10\x00\x00\x01\x00\x20\x00\xFF\xFF\xFF\x7F\xFF\xFF\xFF\x7F"
  let r = Ok(@image.decode_ico(ico)) catch { e => Err(e) }
  match r {
    Err(@image.CorruptData(msg)) => assert_true(msg.contains("out of bounds"))
    _ => fail("expected CorruptData(out of bounds)")
  }
}

///|
test "robustness: PNG decompression bomb is rejected before inflating" {
  // A 1x1 RGBA image whose IDAT inflates to 1 MiB of zeros.
  let bomb = @zlib.zlib_compress(Bytes::make(1 << 20, b'\x00'))
  let png = robustness_png(b"\x00\x00\x00\x01", b"\x00\x00\x00\x01", bomb)
  let r = Ok(@image.decode_png(png)) catch { e => Err(e) }
  assert_true(r is Err(@image.CorruptData(_)))
}

///|
fn robustness_webp(chunk_tag : Bytes, payload : Bytes) -> Bytes {
  let pad = if (payload.length() & 1) == 1 { b"\x00" } else { b"" }
  let le32 = fn(v : Int32) -> Bytes {
    Bytes::from_array([
      v.to_byte(),
      (v >> 8).to_byte(),
      (v >> 16).to_byte(),
      (v >> 24).to_byte(),
    ])
  }
  let body = b"WEBP" + chunk_tag + le32(payload.length()) + payload + pad
  b"RIFF" + le32(body.length()) + body
}

///|
test "robustness: WebP truncated at every length" {
  let img : @image.ImageData = {
    width: 5,
    height: 4,
    data: Bytes::make(5 * 4 * 4, b'\x99'),
  }
  let webp = @image.encode_webp(img)
  for n in 0..<webp.length() {
    expect_decode_error("prefix " + n.to_string(), fn() raise @image.DecodeError {
      ignore(@image.decode_webp(webp[0:n].to_owned()))
    })
  }
  // RIFF size larger than the file.
  let bad = webp.to_fixedarray()
  bad[4] = b'\xFF'
  bad[5] = b'\xFF'
  expect_decode_error("riff size", fn() raise @image.DecodeError {
    ignore(@image.decode_webp(Bytes::from_array(bad)))
  })
}

///|
test "robustness: WebP huge dimensions" {
  // VP8L header claiming 16384 x 16384.
  let vp8l = robustness_webp(b"VP8L", b"\x2F\xFF\xFF\xFF\x0F\x00\x00\x00")
  let r = Ok(@image.decode_webp(vp8l)) catch { e => Err(e) }
  assert_true(r is Err(@image.UnsupportedFeature(_)))
  // VP8 key frame header claiming 16383 x 16383.
  let vp8 = robustness_webp(
    b"VP8 ", b"\x10\x00\x00\x9D\x01\x2A\xFF\x3F\xFF\x3F\x00\x00\x00\x00",
  )
  let r2 = Ok(@image.decode_webp(vp8)) catch { e => Err(e) }
  assert_true(r2 is Err(@image.UnsupportedFeature(_)))
  // VP8X canvas of 2^24 x 2^24.
  let vp8x = robustness_webp(
    b"VP8X", b"\x00\x00\x00\x00\xFF\xFF\xFF\xFF\xFF\xFF",
  )
  let r3 = Ok(@image.decode_webp(vp8x)) catch { e => Err(e) }
  assert_true(r3 is Err(@image.UnsupportedFeature(_)))
}

///|
test "robustness: WebP lossless stream with garbage after the header" {
  // 4 x 4 image whose entropy data is random bits: must fail cleanly.
  let payload = b"\x2F\x03\xC0\x00\x00" + Bytes::make(64, b'\xA5')
  expect_decode_error("garbage", fn() raise @image.DecodeError {
    ignore(@image.decode_webp(robustness_webp(b"VP8L", payload)))
  })
}
