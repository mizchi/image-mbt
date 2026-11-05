///|
fn is_png_signature(raw : Bytes) -> Bool {
  if raw.length() < 8 {
    return false
  }
  for i in 0..<8 {
    if raw[i] != png_signature[i] {
      return false
    }
  }
  true
}

///|
fn is_bmp_signature(raw : Bytes) -> Bool {
  raw.length() >= 2 && raw[0] == b'\x42' && raw[1] == b'\x4D'
}

///|
pub fn decode_image_stream(
  raw : Bytes,
  on_row~ : (Int32, Bytes) -> Unit,
) -> StreamImageInfo raise DecodeError {
  if is_png_signature(raw) {
    let ihdr = decode_png_stream(raw, on_row~)
    return { format: Png, width: ihdr.width, height: ihdr.height, }
  }
  if is_bmp_signature(raw) {
    let (width, height) = decode_bmp_stream(raw, on_row~)
    return { format: Bmp, width, height, }
  }
  raise InvalidSignature("unknown image format")
}

///|
fn is_jpeg_signature(raw : Bytes) -> Bool {
  raw.length() >= 3 &&
  raw[0] == b'\xFF' &&
  raw[1] == b'\xD8' &&
  raw[2] == b'\xFF'
}

///|
fn is_ico_signature(raw : Bytes) -> Bool {
  raw.length() >= 6 &&
  raw[0] == b'\x00' &&
  raw[1] == b'\x00' &&
  (raw[2] == b'\x01' || raw[2] == b'\x02') &&
  raw[3] == b'\x00' &&
  (raw[4] != b'\x00' || raw[5] != b'\x00')
}

///|
/// Decode a PNG, JPEG, BMP or ICO/CUR image, detected from its signature.
pub fn decode_image(raw : Bytes) -> ImageData raise DecodeError {
  if is_png_signature(raw) {
    decode_png(raw)
  } else if is_jpeg_signature(raw) {
    decode_jpeg(raw)
  } else if is_bmp_signature(raw) {
    decode_bmp(raw)
  } else if is_ico_signature(raw) {
    decode_ico(raw)
  } else {
    raise InvalidSignature("unknown image format")
  }
}
