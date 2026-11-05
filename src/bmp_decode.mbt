///|
fn read_u32le(data : Bytes, offset : Int32) -> UInt32 {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  (b3 << 24).lor(b2 << 16).lor(b1 << 8).lor(b0).reinterpret_as_uint()
}

///|
fn read_i32le(data : Bytes, offset : Int32) -> Int32 {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn read_u16le(data : Bytes, offset : Int32) -> Int32 {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  (b1 << 8) | b0
}

///|
const BI_RGB : Int32 = 0

///|
const BI_RLE8 : Int32 = 1

///|
const BI_RLE4 : Int32 = 2

///|
const BI_BITFIELDS : Int32 = 3

///|
const BI_ALPHABITFIELDS : Int32 = 6

///|
/// One channel of a BI_BITFIELDS mask, scaled to 8 bits with rounding.
priv struct BmpMask {
  mask : UInt32
  shift : Int32
  max : UInt64
}

///|
fn BmpMask::new(mask : UInt32) -> BmpMask {
  if mask == 0 {
    return { mask: 0, shift: 0, max: 0, }
  }
  let shift = mask.ctz()
  { mask, shift, max: (mask >> shift).to_uint64(), }
}

///|
fn BmpMask::extract(self : BmpMask, v : UInt32, default : Byte) -> Byte {
  if self.max == 0 {
    return default
  }
  let x = ((v & self.mask) >> self.shift).to_uint64()
  ((x * 255 + self.max / 2) / self.max).to_byte()
}

///|
priv struct BmpDecodeInfo {
  width : Int32
  height : Int32
  bpp : Int32
  compression : Int32
  pixel_offset : Int32
  padded_row_size : Int32
  top_down : Bool
  /// Palette as RGBA8 entries.
  palette : FixedArray[Byte]
  palette_len : Int32
  r_mask : BmpMask
  g_mask : BmpMask
  b_mask : BmpMask
  a_mask : BmpMask
}

///|
fn parse_bmp_info(raw : Bytes) -> BmpDecodeInfo raise DecodeError {
  if raw.length() < 26 {
    raise CorruptData("BMP file too short")
  }
  if raw[0] != b'\x42' || raw[1] != b'\x4D' {
    raise InvalidSignature("not a BMP file")
  }
  let pixel_offset = read_u32le(raw, 10).reinterpret_as_int()
  let dib_size = read_u32le(raw, 14).reinterpret_as_int()
  let core = dib_size == 12
  if !core && dib_size < 40 {
    raise UnsupportedFeature(
      "unsupported DIB header size: " + dib_size.to_string(),
    )
  }
  if raw.length() < 14 + dib_size {
    raise CorruptData("BMP file too short")
  }
  let (width, raw_height, bpp, compression, colors_used) = if core {
    // BITMAPCOREHEADER (OS/2): 16-bit dimensions, no compression.
    (read_u16le(raw, 18), read_u16le(raw, 20), read_u16le(raw, 24), BI_RGB, 0)
  } else {
    (
      read_i32le(raw, 18),
      read_i32le(raw, 22),
      read_u16le(raw, 28),
      read_u32le(raw, 30).reinterpret_as_int(),
      read_u32le(raw, 46).reinterpret_as_int(),
    )
  }
  let top_down = raw_height < 0
  let height = if top_down { -raw_height } else { raw_height }
  if width <= 0 || height <= 0 {
    raise CorruptData("invalid BMP dimensions")
  }
  match compression {
    BI_RGB =>
      if bpp != 1 &&
        bpp != 2 &&
        bpp != 4 &&
        bpp != 8 &&
        bpp != 16 &&
        bpp != 24 &&
        bpp != 32 {
        raise UnsupportedFeature(
          "unsupported BMP bits per pixel: " + bpp.to_string(),
        )
      }
    BI_RLE8 =>
      if bpp != 8 {
        raise CorruptData("RLE8 requires 8 bits per pixel")
      }
    BI_RLE4 =>
      if bpp != 4 {
        raise CorruptData("RLE4 requires 4 bits per pixel")
      }
    BI_BITFIELDS | BI_ALPHABITFIELDS =>
      if bpp != 16 && bpp != 32 {
        raise UnsupportedFeature(
          "BI_BITFIELDS with " + bpp.to_string() + " bits per pixel",
        )
      }
    _ =>
      raise UnsupportedFeature(
        "compressed BMP not supported (compression=" +
        compression.to_string() +
        ")",
      )
  }
  // Channel masks. V2+ headers (>= 52 bytes) carry them inline; a plain
  // BITMAPINFOHEADER is followed by 3 (or 4) masks for BITFIELDS.
  let mut masks_end = 14 + dib_size
  let (r_mask, g_mask, b_mask, a_mask) = if compression == BI_BITFIELDS ||
    compression == BI_ALPHABITFIELDS {
    let n = if compression == BI_ALPHABITFIELDS { 4 } else { 3 }
    // Masks start right after the 40-byte BITMAPINFOHEADER fields, both
    // for inline (V2+) and trailing masks.
    let base = 54
    if dib_size < 52 {
      masks_end = base + n * 4
    }
    if raw.length() < base + n * 4 {
      raise CorruptData("BMP bit masks truncated")
    }
    let a = if n == 4 || dib_size >= 56 {
      read_u32le(raw, base + 12)
    } else {
      0
    }
    (
      read_u32le(raw, base),
      read_u32le(raw, base + 4),
      read_u32le(raw, base + 8),
      a,
    )
  } else if bpp == 16 {
    (0x7C00U, 0x03E0U, 0x001FU, 0U)
  } else {
    (0xFF0000U, 0xFF00U, 0xFFU, 0xFF000000U)
  }
  // Palette
  let mut palette_len = 0
  let palette = FixedArray::make(256 * 4, b'\x00')
  if bpp <= 8 {
    let max_entries = 1 << bpp
    let entry_size = if core { 3 } else { 4 }
    let mut n = if colors_used > 0 && colors_used < max_entries {
      colors_used
    } else {
      max_entries
    }
    // Some files declare more entries than fit before the pixel data.
    let avail = (pixel_offset - masks_end) / entry_size
    if avail < n {
      n = if avail > 0 { avail } else { 0 }
    }
    if masks_end + n * entry_size > raw.length() {
      raise CorruptData("BMP palette truncated")
    }
    for i in 0..<n {
      let p = masks_end + i * entry_size
      palette[i * 4] = raw[p + 2]
      palette[i * 4 + 1] = raw[p + 1]
      palette[i * 4 + 2] = raw[p]
      palette[i * 4 + 3] = b'\xFF'
    }
    palette_len = n
  }
  let padded_row_size = (width * bpp + 31) / 32 * 4
  if compression != BI_RLE8 && compression != BI_RLE4 {
    let required_size = pixel_offset + padded_row_size * height
    if raw.length() < required_size {
      raise CorruptData("BMP file too short for pixel data")
    }
  } else if pixel_offset > raw.length() {
    raise CorruptData("BMP pixel offset beyond end of file")
  }
  {
    width,
    height,
    bpp,
    compression,
    pixel_offset,
    padded_row_size,
    top_down,
    palette,
    palette_len,
    r_mask: BmpMask::new(r_mask),
    g_mask: BmpMask::new(g_mask),
    b_mask: BmpMask::new(b_mask),
    a_mask: BmpMask::new(a_mask),
  }
}

///|
/// Write palette entry `idx` (black if out of range) to `out` at pixel `x`.
fn bmp_put_palette(
  info : BmpDecodeInfo,
  out : FixedArray[Byte],
  x : Int32,
  idx : Int32,
) -> Unit {
  let o = x * 4
  if idx < info.palette_len {
    out[o] = info.palette[idx * 4]
    out[o + 1] = info.palette[idx * 4 + 1]
    out[o + 2] = info.palette[idx * 4 + 2]
  } else {
    out[o] = b'\x00'
    out[o + 1] = b'\x00'
    out[o + 2] = b'\x00'
  }
  out[o + 3] = b'\xFF'
}

///|
/// For 32-bit BI_RGB, the 4th byte is alpha, except that files whose alpha
/// bytes are all zero (common: the byte is "reserved") are opaque.
fn bmp_rgb32_has_alpha(raw : Bytes, info : BmpDecodeInfo) -> Bool {
  for y in 0..<info.height {
    let row = info.pixel_offset + y * info.padded_row_size
    for x in 0..<info.width {
      if raw[row + x * 4 + 3] != b'\x00' {
        return true
      }
    }
  }
  false
}

///|
fn decode_bmp_rows(
  raw : Bytes,
  info : BmpDecodeInfo,
  on_row : (Int32, Bytes) -> Unit,
) -> Unit raise DecodeError {
  if info.compression == BI_RLE8 || info.compression == BI_RLE4 {
    decode_bmp_rle_rows(raw, info, on_row)
    return
  }
  let width = info.width
  let rgb32_alpha = info.bpp == 32 &&
    info.compression == BI_RGB &&
    bmp_rgb32_has_alpha(raw, info)
  for y in 0..<info.height {
    let src_y = if info.top_down { y } else { info.height - 1 - y }
    let src = info.pixel_offset + src_y * info.padded_row_size
    let out = FixedArray::make(width * 4, b'\x00')
    match info.bpp {
      24 =>
        for x in 0..<width {
          let s = src + x * 3
          out[x * 4] = raw[s + 2]
          out[x * 4 + 1] = raw[s + 1]
          out[x * 4 + 2] = raw[s]
          out[x * 4 + 3] = b'\xFF'
        }
      32 if info.compression == BI_RGB =>
        for x in 0..<width {
          let s = src + x * 4
          out[x * 4] = raw[s + 2]
          out[x * 4 + 1] = raw[s + 1]
          out[x * 4 + 2] = raw[s]
          out[x * 4 + 3] = if rgb32_alpha { raw[s + 3] } else { b'\xFF' }
        }
      16 | 32 => {
        let bytes = info.bpp / 8
        for x in 0..<width {
          let v = if bytes == 2 {
            read_u16le(raw, src + x * 2).reinterpret_as_uint()
          } else {
            read_u32le(raw, src + x * 4)
          }
          out[x * 4] = info.r_mask.extract(v, b'\x00')
          out[x * 4 + 1] = info.g_mask.extract(v, b'\x00')
          out[x * 4 + 2] = info.b_mask.extract(v, b'\x00')
          out[x * 4 + 3] = info.a_mask.extract(v, b'\xFF')
        }
      }
      _ => {
        // 1/2/4/8-bit palette indices, packed MSB-first.
        let bpp = info.bpp
        let mask = (1 << bpp) - 1
        for x in 0..<width {
          let bit = x * bpp
          let byte = raw[src + (bit >> 3)].to_int()
          let idx = (byte >> (8 - bpp - (bit & 7))) & mask
          bmp_put_palette(info, out, x, idx)
        }
      }
    }
    on_row(y, Bytes::from_array(out))
  }
}

///|
/// Decode RLE8 / RLE4 pixel data. Pixels skipped by delta / end-of-line /
/// end-of-bitmap escapes are left transparent black, as browsers do.
fn decode_bmp_rle_rows(
  raw : Bytes,
  info : BmpDecodeInfo,
  on_row : (Int32, Bytes) -> Unit,
) -> Unit raise DecodeError {
  let width = info.width
  let height = info.height
  let rle4 = info.compression == BI_RLE4
  // RGBA rows in file order (row 0 = first decoded line).
  let pixels = FixedArray::make(width * height * 4, b'\x00')
  let mut x = 0
  let mut line = 0
  let mut pos = info.pixel_offset
  let end = raw.length()
  let put = fn(idx : Int32) {
    if x < width && line < height {
      bmp_put_palette(info, pixels, line * width + x, idx)
    }
    x += 1
  }
  while pos + 1 < end && line < height {
    let count = raw[pos].to_int()
    let value = raw[pos + 1].to_int()
    pos += 2
    if count > 0 {
      // Encoded run
      for i in 0..<count {
        let idx = if rle4 {
          if i % 2 == 0 {
            value >> 4
          } else {
            value & 0x0F
          }
        } else {
          value
        }
        put(idx)
      }
    } else {
      match value {
        0 => {
          // End of line
          x = 0
          line += 1
        }
        1 => break // End of bitmap
        2 => {
          // Delta
          if pos + 1 >= end {
            raise CorruptData("BMP RLE delta truncated")
          }
          x += raw[pos].to_int()
          line += raw[pos + 1].to_int()
          pos += 2
        }
        n => {
          // Absolute run of n pixels, padded to a 16-bit boundary.
          let nbytes = if rle4 { (n + 1) / 2 } else { n }
          if pos + nbytes > end {
            raise CorruptData("BMP RLE absolute run truncated")
          }
          for i in 0..<n {
            let idx = if rle4 {
              let b = raw[pos + i / 2].to_int()
              if i % 2 == 0 {
                b >> 4
              } else {
                b & 0x0F
              }
            } else {
              raw[pos + i].to_int()
            }
            put(idx)
          }
          pos += nbytes + (nbytes & 1)
        }
      }
    }
  }
  let full = Bytes::from_array(pixels)
  for y in 0..<height {
    let src_y = if info.top_down { y } else { height - 1 - y }
    on_row(y, full[src_y * width * 4:(src_y + 1) * width * 4].to_owned())
  }
}

///|
pub fn decode_bmp_stream(
  raw : Bytes,
  on_row~ : (Int32, Bytes) -> Unit,
) -> (Int32, Int32) raise DecodeError {
  let info = parse_bmp_info(raw)
  decode_bmp_rows(raw, info, on_row)
  (info.width, info.height)
}

///|
pub fn decode_bmp(raw : Bytes) -> ImageData raise DecodeError {
  let info = parse_bmp_info(raw)
  let rgba_buf = FixedArray::make(info.width * info.height * 4, b'\x00')
  decode_bmp_rows(raw, info, fn(y, row) {
    let dst_offset = y * info.width * 4
    rgba_buf.blit_from_bytes(dst_offset, row, 0, info.width * 4)
  })
  { width: info.width, height: info.height, data: Bytes::from_array(rgba_buf), }
}
