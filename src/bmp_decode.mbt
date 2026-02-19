///|
fn read_u32le(data : Bytes, offset : Int) -> UInt {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  (b3 << 24).lor(b2 << 16).lor(b1 << 8).lor(b0).reinterpret_as_uint()
}

///|
fn read_i32le(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
}

///|
fn read_u16le(data : Bytes, offset : Int) -> Int {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  (b1 << 8) | b0
}

///|
pub fn decode_bmp(raw : Bytes) -> ImageData raise DecodeError {
  if raw.length() < 54 {
    raise CorruptData("BMP file too short")
  }
  if raw[0] != b'\x42' || raw[1] != b'\x4D' {
    raise InvalidSignature("not a BMP file")
  }
  let pixel_offset = read_u32le(raw, 10).reinterpret_as_int()
  let dib_size = read_u32le(raw, 14).reinterpret_as_int()
  if dib_size < 40 {
    raise UnsupportedFeature(
      "unsupported DIB header size: " + dib_size.to_string(),
    )
  }
  let width = read_i32le(raw, 18)
  let raw_height = read_i32le(raw, 22)
  let top_down = raw_height < 0
  let height = if top_down { 0 - raw_height } else { raw_height }
  if width <= 0 || height <= 0 {
    raise CorruptData("invalid BMP dimensions")
  }
  let bpp = read_u16le(raw, 28)
  let compression = read_u32le(raw, 30).reinterpret_as_int()
  if compression != 0 {
    raise UnsupportedFeature(
      "compressed BMP not supported (compression=" +
      compression.to_string() +
      ")",
    )
  }
  if bpp != 24 && bpp != 32 {
    raise UnsupportedFeature(
      "unsupported BMP bits per pixel: " + bpp.to_string(),
    )
  }
  let bytes_per_px = bpp / 8
  let row_size = width * bytes_per_px
  let padded_row_size = (row_size + 3) / 4 * 4
  let required_size = pixel_offset + padded_row_size * height
  if raw.length() < required_size {
    raise CorruptData("BMP file too short for pixel data")
  }
  let rgba_buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    let src_y = if top_down { y } else { height - 1 - y }
    let src_row_offset = pixel_offset + src_y * padded_row_size
    for x in 0..<width {
      let dst_idx = (y * width + x) * 4
      let src_idx = src_row_offset + x * bytes_per_px
      let b_val = raw[src_idx]
      let g_val = raw[src_idx + 1]
      let r_val = raw[src_idx + 2]
      let a_val : Byte = if bpp == 32 { raw[src_idx + 3] } else { b'\xFF' }
      rgba_buf[dst_idx] = r_val
      rgba_buf[dst_idx + 1] = g_val
      rgba_buf[dst_idx + 2] = b_val
      rgba_buf[dst_idx + 3] = a_val
    }
  }
  { width, height, data: Bytes::from_array(rgba_buf) }
}
