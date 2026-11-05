///|
/// Number of samples per pixel for a PNG color type.
fn png_channels(ct : ColorType) -> Int32 {
  match ct {
    Grayscale => 1
    Rgb => 3
    Indexed => 1
    GrayscaleAlpha => 2
    Rgba => 4
  }
}

///|
/// Validate the IHDR bit depth / color type combination (PNG spec 11.2.2).
fn validate_png_bit_depth(
  ct : ColorType,
  bit_depth : Int32,
) -> Unit raise DecodeError {
  let ok = match ct {
    Grayscale =>
      bit_depth == 1 ||
      bit_depth == 2 ||
      bit_depth == 4 ||
      bit_depth == 8 ||
      bit_depth == 16
    Indexed =>
      bit_depth == 1 || bit_depth == 2 || bit_depth == 4 || bit_depth == 8
    Rgb | GrayscaleAlpha | Rgba => bit_depth == 8 || bit_depth == 16
  }
  if !ok {
    raise CorruptData(
      "invalid bit depth " +
      bit_depth.to_string() +
      " for color type " +
      ct.to_string(),
    )
  }
}

///|
/// Bytes in one (unfiltered) scanline, excluding the filter-type byte.
/// Sub-byte depths are packed MSB-first and padded to a byte boundary.
fn png_row_bytes(width : Int32, ct : ColorType, bit_depth : Int32) -> Int32 {
  (width * png_channels(ct) * bit_depth + 7) / 8
}

///|
/// Read the `i`-th packed sample of `bit_depth` bits (1, 2, 4 or 8).
fn packed_sample(row : Bytes, i : Int32, bit_depth : Int32) -> Int32 {
  let bit = i * bit_depth
  let shift = 8 - bit_depth - (bit & 7)
  (row[bit >> 3].to_int() >> shift) & ((1 << bit_depth) - 1)
}

///|
/// Per-image state for converting defiltered PNG scanlines to RGBA8.
/// Built once per image so that palette / tRNS handling is not repeated
/// for every row.
priv struct PngRowConverter {
  width : Int32
  color_type : ColorType
  bit_depth : Int32
  /// Indexed: RGBA8 lookup table for 256 entries (alpha from tRNS).
  lut : FixedArray[Byte]
  /// Indexed: number of valid PLTE entries.
  lut_entries : Int32
  /// Grayscale / Rgb: tRNS color key as raw samples (-1 = none).
  key_r : Int32
  key_g : Int32
  key_b : Int32
}

///|
fn PngRowConverter::new(
  width : Int32,
  color_type : ColorType,
  bit_depth : Int32,
  palette : Bytes?,
  trns : Bytes?,
) -> PngRowConverter raise DecodeError {
  validate_png_bit_depth(color_type, bit_depth)
  let mut lut = FixedArray::make(0, b'\x00')
  let mut lut_entries = 0
  let mut key_r = -1
  let mut key_g = -1
  let mut key_b = -1
  match color_type {
    Indexed => {
      let plte = match palette {
        Some(p) => p
        None => raise MissingChunk("PLTE")
      }
      lut_entries = plte.length() / 3
      if lut_entries > 256 {
        lut_entries = 256
      }
      lut = FixedArray::make(256 * 4, b'\x00')
      let alpha = match trns {
        Some(t) => t
        None => Bytes::new(0)
      }
      for i in 0..<lut_entries {
        lut[i * 4] = plte[i * 3]
        lut[i * 4 + 1] = plte[i * 3 + 1]
        lut[i * 4 + 2] = plte[i * 3 + 2]
        lut[i * 4 + 3] = if i < alpha.length() { alpha[i] } else { b'\xFF' }
      }
    }
    Grayscale =>
      match trns {
        Some(t) if t.length() >= 2 => key_r = read_u16be_at(t, 0)
        _ => ()
      }
    Rgb =>
      match trns {
        Some(t) if t.length() >= 6 => {
          key_r = read_u16be_at(t, 0)
          key_g = read_u16be_at(t, 2)
          key_b = read_u16be_at(t, 4)
        }
        _ => ()
      }
    // tRNS is not allowed for color types with an alpha channel.
    GrayscaleAlpha | Rgba => ()
  }
  { width, color_type, bit_depth, lut, lut_entries, key_r, key_g, key_b, }
}

///|
/// Convert a defiltered scanline to `width` RGBA8 pixels.
fn PngRowConverter::convert(
  self : PngRowConverter,
  row : Bytes,
) -> Bytes raise DecodeError {
  let width = self.width
  let bit_depth = self.bit_depth
  match (self.color_type, bit_depth) {
    // Already RGBA8 — return as-is (zero-copy)
    (Rgba, 8) => return row
    _ => ()
  }
  let out = FixedArray::make(width * 4, b'\x00')
  match self.color_type {
    Indexed => {
      let lut = self.lut
      let entries = self.lut_entries
      for i in 0..<width {
        let idx = if bit_depth == 8 {
          row[i].to_int()
        } else {
          packed_sample(row, i, bit_depth)
        }
        if idx >= entries {
          raise CorruptData("palette index out of range: " + idx.to_string())
        }
        let o = i * 4
        let l = idx * 4
        out[o] = lut[l]
        out[o + 1] = lut[l + 1]
        out[o + 2] = lut[l + 2]
        out[o + 3] = lut[l + 3]
      }
    }
    Grayscale => {
      let key = self.key_r
      if bit_depth == 16 {
        for i in 0..<width {
          let v = row[i * 2]
          let a = if key >= 0 && read_u16be_at(row, i * 2) == key {
            b'\x00'
          } else {
            b'\xFF'
          }
          let o = i * 4
          out[o] = v
          out[o + 1] = v
          out[o + 2] = v
          out[o + 3] = a
        }
      } else if bit_depth == 8 && key < 0 {
        gray8_to_rgba(row, out, width)
      } else {
        // 1/2/4/8-bit: scale sample to 0..255 (255 / (2^bd - 1) is exact).
        let scale = 255 / ((1 << bit_depth) - 1)
        for i in 0..<width {
          let s = if bit_depth == 8 {
            row[i].to_int()
          } else {
            packed_sample(row, i, bit_depth)
          }
          let v = (s * scale).to_byte()
          let o = i * 4
          out[o] = v
          out[o + 1] = v
          out[o + 2] = v
          out[o + 3] = if s == key { b'\x00' } else { b'\xFF' }
        }
      }
    }
    GrayscaleAlpha =>
      if bit_depth == 8 {
        gray_alpha8_to_rgba(row, out, width)
      } else {
        for i in 0..<width {
          let v = row[i * 4]
          let o = i * 4
          out[o] = v
          out[o + 1] = v
          out[o + 2] = v
          out[o + 3] = row[i * 4 + 2]
        }
      }
    Rgb => {
      let has_key = self.key_r >= 0
      if bit_depth == 8 {
        rgb8_to_rgba(row, out, width)
        if has_key {
          for i in 0..<width {
            if row[i * 3].to_int() == self.key_r &&
              row[i * 3 + 1].to_int() == self.key_g &&
              row[i * 3 + 2].to_int() == self.key_b {
              out[i * 4 + 3] = b'\x00'
            }
          }
        }
      } else {
        for i in 0..<width {
          let s = i * 6
          let o = i * 4
          out[o] = row[s]
          out[o + 1] = row[s + 2]
          out[o + 2] = row[s + 4]
          out[o + 3] = if has_key &&
            read_u16be_at(row, s) == self.key_r &&
            read_u16be_at(row, s + 2) == self.key_g &&
            read_u16be_at(row, s + 4) == self.key_b {
            b'\x00'
          } else {
            b'\xFF'
          }
        }
      }
    }
    Rgba =>
      // 16-bit RGBA: keep the high byte of each sample.
      for i in 0..<width {
        let s = i * 8
        let o = i * 4
        out[o] = row[s]
        out[o + 1] = row[s + 2]
        out[o + 2] = row[s + 4]
        out[o + 3] = row[s + 6]
      }
  }
  Bytes::from_array(out)
}

///|
/// Convert a single defiltered scanline to RGBA8 pixels.
/// Returns RGBA bytes (4 bytes per pixel).
fn scanline_to_rgba(
  row : Bytes,
  width : Int32,
  color_type : ColorType,
  bit_depth : Int32,
  palette : Bytes?,
  trns : Bytes?,
) -> Bytes raise DecodeError {
  PngRowConverter::new(width, color_type, bit_depth, palette, trns).convert(row)
}

///|
test "scanline_to_rgba: rgba passthrough" {
  let row = b"\xFF\x00\x80\xC0"
  let result = scanline_to_rgba(row, 1, Rgba, 8, None, None)
  assert_eq(result, b"\xFF\x00\x80\xC0")
}

///|
test "scanline_to_rgba: rgb to rgba" {
  let row = b"\xFF\x00\x80"
  let result = scanline_to_rgba(row, 1, Rgb, 8, None, None)
  assert_eq(result, b"\xFF\x00\x80\xFF")
}

///|
test "scanline_to_rgba: rgb to rgba wide row" {
  // 7 pixels: exercises SIMD body + scalar tail on wasm.
  let row = b"\x01\x02\x03\x04\x05\x06\x07\x08\x09\x0A\x0B\x0C\x0D\x0E\x0F\x10\x11\x12\x13\x14\x15"
  let result = scanline_to_rgba(row, 7, Rgb, 8, None, None)
  assert_eq(
    result, b"\x01\x02\x03\xFF\x04\x05\x06\xFF\x07\x08\x09\xFF\x0A\x0B\x0C\xFF\x0D\x0E\x0F\xFF\x10\x11\x12\xFF\x13\x14\x15\xFF",
  )
}

///|
test "scanline_to_rgba: grayscale to rgba" {
  let row = b"\x80\xFF"
  let result = scanline_to_rgba(row, 2, Grayscale, 8, None, None)
  assert_eq(result, b"\x80\x80\x80\xFF\xFF\xFF\xFF\xFF")
}

///|
test "scanline_to_rgba: grayscale alpha to rgba" {
  let row = b"\x80\xC0"
  let result = scanline_to_rgba(row, 1, GrayscaleAlpha, 8, None, None)
  assert_eq(result, b"\x80\x80\x80\xC0")
}

///|
test "scanline_to_rgba: indexed to rgba" {
  // Palette: entry 0 = red, entry 1 = green
  let palette = b"\xFF\x00\x00\x00\xFF\x00"
  let row = b"\x00\x01"
  let result = scanline_to_rgba(row, 2, Indexed, 8, Some(palette), None)
  assert_eq(result, b"\xFF\x00\x00\xFF\x00\xFF\x00\xFF")
}

///|
test "scanline_to_rgba: indexed applies palette alpha" {
  let palette = b"\xFF\x00\x00\x00\xFF\x00"
  let palette_alpha = b"\x00\x80"
  let row = b"\x00\x01"
  let result = scanline_to_rgba(
    row,
    2,
    Indexed,
    8,
    Some(palette),
    Some(palette_alpha),
  )
  assert_eq(result, b"\xFF\x00\x00\x00\x00\xFF\x00\x80")
}

///|
test "scanline_to_rgba: 1-bit indexed applies palette alpha" {
  // 3 pixels packed MSB-first: 1,0,1 -> 0b1010_0000 (padding bits ignored)
  let palette = b"\x00\x00\x00\xFF\xFF\xFF"
  let palette_alpha = b"\x00"
  let row = b"\xA0"
  let result = scanline_to_rgba(
    row,
    3,
    Indexed,
    1,
    Some(palette),
    Some(palette_alpha),
  )
  assert_eq(result, b"\xFF\xFF\xFF\xFF\x00\x00\x00\x00\xFF\xFF\xFF\xFF")
}

///|
test "scanline_to_rgba: 4-bit indexed" {
  let palette = b"\x10\x20\x30\x40\x50\x60\x70\x80\x90"
  let palette_alpha = b"\xFF\x7F"
  // indices 1, 2, 0
  let row = b"\x12\x00"
  let result = scanline_to_rgba(
    row,
    3,
    Indexed,
    4,
    Some(palette),
    Some(palette_alpha),
  )
  assert_eq(result, b"\x40\x50\x60\x7F\x70\x80\x90\xFF\x10\x20\x30\xFF")
}

///|
test "scanline_to_rgba: indexed out of range index" {
  let palette = b"\x10\x20\x30"
  let row = b"\x40"
  let result = Ok(scanline_to_rgba(row, 2, Indexed, 2, Some(palette), None)) catch {
    e => Err(e)
  }
  assert_true(result is Err(CorruptData(_)))
}

///|
test "scanline_to_rgba: 2-bit grayscale scaled" {
  // samples 0,1,2,3 -> 0, 85, 170, 255
  let row = b"\x1B"
  let result = scanline_to_rgba(row, 4, Grayscale, 2, None, None)
  assert_eq(
    result, b"\x00\x00\x00\xFF\x55\x55\x55\xFF\xAA\xAA\xAA\xFF\xFF\xFF\xFF\xFF",
  )
}

///|
test "scanline_to_rgba: grayscale tRNS key" {
  let row = b"\x10\x20"
  let result = scanline_to_rgba(row, 2, Grayscale, 8, None, Some(b"\x00\x20"))
  assert_eq(result, b"\x10\x10\x10\xFF\x20\x20\x20\x00")
}

///|
test "scanline_to_rgba: rgb tRNS key" {
  let row = b"\x01\x02\x03\x04\x05\x06"
  let trns = b"\x00\x04\x00\x05\x00\x06"
  let result = scanline_to_rgba(row, 2, Rgb, 8, None, Some(trns))
  assert_eq(result, b"\x01\x02\x03\xFF\x04\x05\x06\x00")
}

///|
test "scanline_to_rgba: 16-bit rgba keeps high byte" {
  let row = b"\x12\x34\x56\x78\x9A\xBC\xDE\xF0"
  let result = scanline_to_rgba(row, 1, Rgba, 16, None, None)
  assert_eq(result, b"\x12\x56\x9A\xDE")
}

///|
test "scanline_to_rgba: 16-bit rgb tRNS compares full sample" {
  // Same high bytes, different low byte: only the exact match is transparent.
  let row = b"\x12\x34\x56\x78\x9A\xBC\x12\x35\x56\x78\x9A\xBC"
  let trns = b"\x12\x34\x56\x78\x9A\xBC"
  let result = scanline_to_rgba(row, 2, Rgb, 16, None, Some(trns))
  assert_eq(result, b"\x12\x56\x9A\x00\x12\x56\x9A\xFF")
}

///|
test "scanline_to_rgba: invalid bit depth" {
  let result = Ok(scanline_to_rgba(b"\x00", 1, Rgb, 4, None, None)) catch {
    e => Err(e)
  }
  assert_true(result is Err(CorruptData(_)))
}
