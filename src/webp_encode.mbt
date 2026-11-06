///|
priv struct WebPBitWriter {
  buf : Array[Byte]
  mut bit_buf : Int32
  mut bits_count : Int32
}

///|
fn WebPBitWriter::new() -> WebPBitWriter {
  { buf: [], bit_buf: 0, bits_count: 0, }
}

///|
fn WebPBitWriter::put_bits(
  self : WebPBitWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  if count <= 0 {
    return
  }
  self.bit_buf = self.bit_buf |
    ((value & ((1 << count) - 1)) << self.bits_count)
  self.bits_count += count
  while self.bits_count >= 8 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = self.bit_buf >> 8
    self.bits_count -= 8
  }
}

///|
fn WebPBitWriter::flush(self : WebPBitWriter) -> Unit {
  if self.bits_count > 0 {
    self.buf.push((self.bit_buf & 0xFF).to_byte())
    self.bit_buf = 0
    self.bits_count = 0
  }
}

///|
fn WebPBitWriter::to_bytes(self : WebPBitWriter) -> Bytes {
  let out = FixedArray::make(self.buf.length(), b'\x00')
  for i in 0..<self.buf.length() {
    out[i] = self.buf[i]
  }
  Bytes::from_array(out)
}

///|
fn webp_reverse_bits(value : Int32, count : Int32) -> Int32 {
  let mut out = 0
  let mut v = value
  for _ in 0..<count {
    out = (out << 1) | (v & 1)
    v = v >> 1
  }
  out
}

///|
fn encode_webp_lossless_payload(img : ImageData) -> Bytes {
  vp8l_encode(img)
}

///|
pub fn encode_webp(img : ImageData) -> Bytes raise EncodeError {
  let width = img.width
  let height = img.height
  if width <= 0 || height <= 0 {
    raise InvalidDimensions(
      "width and height must be positive: " +
      width.to_string() +
      "x" +
      height.to_string(),
    )
  }
  if width > 16384 || height > 16384 {
    raise InvalidDimensions(
      "WebP lossless dimensions must be <= 16384: " +
      width.to_string() +
      "x" +
      height.to_string(),
    )
  }
  let expected_len = width * height * 4
  if img.data.length() != expected_len {
    raise InvalidData(
      "expected " +
      expected_len.to_string() +
      " bytes, got " +
      img.data.length().to_string(),
    )
  }

  let payload = encode_webp_lossless_payload(img)
  let pad_len = if payload.length() % 2 == 1 { 1 } else { 0 }
  let file_size = 4 + 8 + payload.length() + pad_len
  let out = FixedArray::make(8 + file_size, b'\x00')

  out[0] = b'\x52'
  out[1] = b'\x49'
  out[2] = b'\x46'
  out[3] = b'\x46'
  write_u32le(out, 4, file_size.reinterpret_as_uint())
  out[8] = b'\x57'
  out[9] = b'\x45'
  out[10] = b'\x42'
  out[11] = b'\x50'
  out[12] = b'\x56'
  out[13] = b'\x50'
  out[14] = b'\x38'
  out[15] = b'\x4C'
  write_u32le(out, 16, payload.length().reinterpret_as_uint())
  out.blit_from_bytes(20, payload, 0, payload.length())
  Bytes::from_array(out)
}
