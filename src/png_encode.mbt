///|
fn write_u32be(buf : FixedArray[Byte], offset : Int32, value : UInt32) -> Unit {
  buf[offset] = (value >> 24).land(0xFFU).to_byte()
  buf[offset + 1] = (value >> 16).land(0xFFU).to_byte()
  buf[offset + 2] = (value >> 8).land(0xFFU).to_byte()
  buf[offset + 3] = value.land(0xFFU).to_byte()
}

///|
fn encode_chunk(chunk_type : FixedArray[Byte], data : Bytes) -> Bytes {
  let len = data.length()
  let total = 12 + len
  let buf = FixedArray::make(total, b'\x00')
  // Length
  write_u32be(buf, 0, len.reinterpret_as_uint())
  // Type
  buf[4] = chunk_type[0]
  buf[5] = chunk_type[1]
  buf[6] = chunk_type[2]
  buf[7] = chunk_type[3]
  // Data
  buf.blit_from_bytes(8, data, 0, len)
  // CRC over type + data
  let crc_input = FixedArray::make(4 + len, b'\x00')
  chunk_type.blit_to(crc_input, len=4)
  crc_input.blit_from_bytes(4, data, 0, len)
  let crc = @zlib.crc32_fixed(crc_input)
  write_u32be(buf, 8 + len, crc)
  Bytes::from_array(buf)
}

///|
/// Color type written by `encode_png`.
pub(all) enum PngColorMode {
  /// RGBA, 8 bits per channel (default).
  Rgba
  /// RGB, 8 bits; every pixel must be opaque.
  Rgb
  /// Grayscale, 8 bits; every pixel must be opaque with R = G = B.
  Gray
  /// Grayscale + alpha, 8 bits; every pixel must have R = G = B.
  GrayAlpha
  /// Palette (PLTE + tRNS) at 1, 2, 4 or 8 bits; at most 256 distinct
  /// RGBA colors.
  Palette
  /// The smallest of the modes above that represents the image exactly.
  Auto
}

///|
/// zlib compression effort for `encode_png`.
pub(all) enum PngCompression {
  /// No compression (stored blocks).
  Stored
  /// Fixed Huffman codes (fast).
  Fast
  /// Dynamic Huffman codes (default).
  Default
  /// Slowest, smallest output.
  Best
}

///|
fn png_zlib(data : Bytes, level : PngCompression) -> Bytes {
  match level {
    Stored => @zlib.zlib_compress_stored(data)
    Default => @zlib.zlib_compress(data)
    Fast | Best => {
      // zlib wrapper around a raw deflate stream.
      let body = match level {
        Fast => @zlib.deflate_compress_fixed(data)
        _ => @zlib.deflate_compress_best(data)
      }
      let adler = @zlib.adler32(data)
      let out = Buffer()
      out.write_byte(b'\x78')
      out.write_byte(if level is Fast { b'\x01' } else { b'\xDA' })
      out.write_bytes(body)
      out.write_byte((adler >> 24).to_byte())
      out.write_byte((adler >> 16).to_byte())
      out.write_byte((adler >> 8).to_byte())
      out.write_byte(adler.to_byte())
      out.to_bytes()
    }
  }
}

///|
/// Prefix each `row_bytes`-byte row of `rows` with a filter byte (adaptive
/// per row, or always None) and compress.
fn png_filter_and_compress(
  rows : Bytes,
  row_bytes : Int32,
  height : Int32,
  bpp : Int32,
  adaptive : Bool,
  level : PngCompression,
) -> Bytes {
  let raw = FixedArray::make(height * (1 + row_bytes), b'\x00')
  let mut prev_row = Bytes::new(row_bytes)
  for y in 0..<height {
    let raw_offset = y * (1 + row_bytes)
    let row = rows[y * row_bytes:(y + 1) * row_bytes].to_owned()
    if adaptive {
      let (filter_type, filtered) = select_best_filter(row, prev_row, bpp)
      raw[raw_offset] = filter_type.to_byte()
      filtered.blit_to(raw, len=row_bytes, dst_offset=raw_offset + 1)
    } else {
      raw.blit_from_bytes(raw_offset + 1, row, 0, row_bytes)
    }
    prev_row = row
  }
  png_zlib(Bytes::from_array(raw), level)
}

///|
/// Filter (adaptive per row) and zlib-compress the `w` x `h` RGBA8
/// rectangle at (`x0`, `y0`) of an image `src_w` pixels wide.
fn png_compress_rgba_rect(
  src : Bytes,
  src_w : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
) -> Bytes {
  let rows = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    rows.blit_from_bytes(y * w * 4, src, ((y0 + y) * src_w + x0) * 4, w * 4)
  }
  png_filter_and_compress(Bytes::from_array(rows), w * 4, h, 4, true, Default)
}

///|
/// What an image needs: (all opaque, all gray, distinct RGBA colors in
/// first-seen order or None if more than 256).
fn png_analyze(img : ImageData) -> (Bool, Bool, Array[Int32]?) {
  let mut all_opaque = true
  let mut gray = true
  let seen : Map[Int32, Int32] = Map([])
  let colors : Array[Int32] = []
  let mut too_many = false
  for i in 0..<(img.width * img.height) {
    let r = img.data[i * 4].to_int()
    let g = img.data[i * 4 + 1].to_int()
    let b = img.data[i * 4 + 2].to_int()
    let a = img.data[i * 4 + 3].to_int()
    if a != 255 {
      all_opaque = false
    }
    if r != g || g != b {
      gray = false
    }
    if !too_many {
      let key = (r << 24) | (g << 16) | (b << 8) | a
      if !seen.contains(key) {
        if colors.length() == 256 {
          too_many = true
        } else {
          seen.set(key, colors.length())
          colors.push(key)
        }
      }
    }
  }
  (all_opaque, gray, if too_many { None } else { Some(colors) })
}

///|
/// Encode a PNG. `color` selects the color type (default RGBA8; `Auto`
/// picks the smallest exact one) and `compression` the zlib effort.
/// Explicit modes that cannot represent the image raise InvalidData.
pub fn encode_png(
  img : ImageData,
  color~ : PngColorMode = Rgba,
  compression~ : PngCompression = Default,
) -> Bytes raise EncodeError {
  validate_rgba8_image(img)
  let width = img.width
  let height = img.height
  let (all_opaque, gray, palette) = match color {
    Rgba => (false, false, None)
    _ => png_analyze(img)
  }
  let mode = match color {
    Auto =>
      if gray && all_opaque {
        Gray
      } else if palette is Some(p) && p.length() <= 16 {
        // Small palettes beat every 8-bit truecolor / gray mode.
        Palette
      } else if gray {
        GrayAlpha
      } else if palette is Some(_) {
        Palette
      } else if all_opaque {
        Rgb
      } else {
        Rgba
      }
    m => m
  }
  match mode {
    Rgb if !all_opaque =>
      raise InvalidData("PNG RGB output needs an opaque image")
    Gray if !(all_opaque && gray) =>
      raise InvalidData("PNG gray output needs an opaque grayscale image")
    GrayAlpha if !gray =>
      raise InvalidData("PNG gray+alpha output needs a grayscale image")
    Palette if palette is None =>
      raise InvalidData("PNG palette output needs at most 256 colors")
    _ => ()
  }
  let count = width * height
  let chunks : Array[Bytes] = []
  let (color_type, bit_depth, rows, row_bytes, bpp) = match mode {
    Rgb | Gray | GrayAlpha => {
      let ch = match mode {
        Rgb => 3
        Gray => 1
        _ => 2
      }
      let out = FixedArray::make(count * ch, b'\x00')
      for i in 0..<count {
        match mode {
          Rgb => out.blit_from_bytes(i * 3, img.data, i * 4, 3)
          Gray => out[i] = img.data[i * 4]
          _ => {
            out[i * 2] = img.data[i * 4]
            out[i * 2 + 1] = img.data[i * 4 + 3]
          }
        }
      }
      let ct = match mode {
        Rgb => 2
        Gray => 0
        _ => 4
      }
      (ct, 8, Bytes::from_array(out), width * ch, ch)
    }
    Palette => {
      // Entries with alpha < 255 first, so tRNS stays short.
      let colors = palette.unwrap_or([])
      let ordered = colors.filter(fn(c) { (c & 0xFF) != 255 }) +
        colors.filter(fn(c) { (c & 0xFF) == 255 })
      let index : Map[Int32, Int32] = Map([])
      for i, c in ordered {
        index.set(c, i)
      }
      let n = ordered.length()
      let depth = if n <= 2 {
        1
      } else if n <= 4 {
        2
      } else if n <= 16 {
        4
      } else {
        8
      }
      let plte = FixedArray::make(n * 3, b'\x00')
      let mut trns_len = 0
      for i, c in ordered {
        plte[i * 3] = (c >> 24).to_byte()
        plte[i * 3 + 1] = (c >> 16).to_byte()
        plte[i * 3 + 2] = (c >> 8).to_byte()
        if (c & 0xFF) != 255 {
          trns_len = i + 1
        }
      }
      chunks.push(
        encode_chunk([b'P', b'L', b'T', b'E'], Bytes::from_array(plte)),
      )
      if trns_len > 0 {
        let trns = FixedArray::makei(trns_len, fn(i) {
          (ordered[i] & 0xFF).to_byte()
        })
        chunks.push(
          encode_chunk([b't', b'R', b'N', b'S'], Bytes::from_array(trns)),
        )
      }
      let rb = (width * depth + 7) / 8
      let out = FixedArray::make(rb * height, b'\x00')
      for y in 0..<height {
        for x in 0..<width {
          let o = (y * width + x) * 4
          let key = (img.data[o].to_int() << 24) |
            (img.data[o + 1].to_int() << 16) |
            (img.data[o + 2].to_int() << 8) |
            img.data[o + 3].to_int()
          let idx = index.get(key).unwrap_or(0)
          let bit = x * depth
          let p = y * rb + (bit >> 3)
          out[p] = (out[p].to_int() | (idx << (8 - depth - (bit & 7)))).to_byte()
        }
      }
      (3, depth, Bytes::from_array(out), rb, 1)
    }
    _ => (6, 8, img.data, width * 4, 4)
  }
  let ihdr = FixedArray::make(13, b'\x00')
  write_u32be(ihdr, 0, width.reinterpret_as_uint())
  write_u32be(ihdr, 4, height.reinterpret_as_uint())
  ihdr[8] = bit_depth.to_byte()
  ihdr[9] = color_type.to_byte()
  // Like libpng: no filtering for palette images.
  let compressed = png_filter_and_compress(
    rows,
    row_bytes,
    height,
    bpp,
    color_type != 3,
    compression,
  )
  let parts : Array[Bytes] = [
    b"\x89PNG\r\n\x1A\n",
    encode_chunk([b'I', b'H', b'D', b'R'], Bytes::from_array(ihdr)),
  ]
  for c in chunks {
    parts.push(c)
  }
  parts.push(encode_chunk([b'I', b'D', b'A', b'T'], compressed))
  parts.push(encode_chunk([b'I', b'E', b'N', b'D'], Bytes::new(0)))
  concat_bytes(parts)
}

///|
test "encode_png basic" {
  let img : ImageData = { width: 1, height: 1, data: b"\xFF\x00\x00\xFF", }
  let png = encode_png(img)
  // Should start with PNG signature
  assert_eq(png[0].to_int(), 0x89)
  assert_eq(png[1].to_int(), 0x50)
  assert_eq(png[2].to_int(), 0x4E)
  assert_eq(png[3].to_int(), 0x47)
}

///|
test "encode_png roundtrip 1x1" {
  let original : ImageData = { width: 1, height: 1, data: b"\xFF\x00\x80\xC0", }
  let png = encode_png(original)
  let decoded = decode_png(png) catch { _ => panic() }
  assert_eq(decoded.width, original.width)
  assert_eq(decoded.height, original.height)
  assert_eq(decoded.data, original.data)
}

///|
test "encode_png roundtrip 4x4" {
  let width = 4
  let height = 4
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      buf[idx] = (x * 64).to_byte() // R
      buf[idx + 1] = (y * 64).to_byte() // G
      buf[idx + 2] = ((x + y) * 32).to_byte() // B
      buf[idx + 3] = b'\xFF' // A
    }
  }
  let original : ImageData = { width, height, data: Bytes::from_array(buf), }
  let png = encode_png(original)
  let decoded = decode_png(png) catch { _ => panic() }
  assert_eq(decoded.width, original.width)
  assert_eq(decoded.height, original.height)
  assert_eq(decoded.data, original.data)
}

///|
test "encode_png invalid dimensions" {
  let img : ImageData = { width: 0, height: 1, data: Bytes::new(0), }
  let mut got_error = false
  try {
    let _ = encode_png(img)
  } catch {
    _ => got_error = true
  }
  assert_true(got_error)
}

///|
test "encode_png invalid data length" {
  let img : ImageData = { width: 2, height: 2, data: Bytes::new(4), }
  let mut got_error = false
  try {
    let _ = encode_png(img)
  } catch {
    _ => got_error = true
  }
  assert_true(got_error)
}
