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
/// The format of an image, detected from its signature.
pub fn detect_image_format(raw : Bytes) -> ImageFormat? {
  if is_png_signature(raw) {
    Some(Png)
  } else if is_jpeg_signature(raw) {
    Some(Jpeg)
  } else if gif_signature_ok(raw) {
    Some(Gif)
  } else if is_bmp_signature(raw) {
    Some(Bmp)
  } else if is_ico_signature(raw) {
    Some(Ico)
  } else if tiff_signature_ok(raw) {
    Some(Tiff)
  } else if webp_signature_ok(raw) {
    Some(WebP)
  } else {
    None
  }
}

///|
/// Decode any supported image row by row (`on_row(y, rgba_row)`). PNG and
/// BMP are streamed; other formats are decoded fully, then emitted by row.
pub fn decode_image_stream(
  raw : Bytes,
  on_row~ : (Int32, Bytes) -> Unit,
) -> StreamImageInfo raise DecodeError {
  let format = match detect_image_format(raw) {
    Some(f) => f
    None => raise InvalidSignature("unknown image format")
  }
  match format {
    Png => {
      let ihdr = decode_png_stream(raw, on_row~)
      { format, width: ihdr.width, height: ihdr.height, }
    }
    Bmp => {
      let (width, height) = decode_bmp_stream(raw, on_row~)
      { format, width, height, }
    }
    _ => {
      let img = decode_image(raw)
      let row = img.width * 4
      for y in 0..<img.height {
        on_row(y, img.data[y * row:(y + 1) * row].to_owned())
      }
      { format, width: img.width, height: img.height, }
    }
  }
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
/// Decode a PNG, JPEG, GIF (first frame), BMP, ICO/CUR, TIFF (first page)
/// or WebP (first frame) image, detected from its signature.
pub fn decode_image(raw : Bytes) -> ImageData raise DecodeError {
  if is_png_signature(raw) {
    decode_png(raw)
  } else if is_jpeg_signature(raw) {
    decode_jpeg(raw)
  } else if gif_signature_ok(raw) {
    decode_gif(raw)
  } else if is_bmp_signature(raw) {
    decode_bmp(raw)
  } else if is_ico_signature(raw) {
    decode_ico(raw)
  } else if tiff_signature_ok(raw) {
    decode_tiff(raw)
  } else if webp_signature_ok(raw) {
    decode_webp(raw)
  } else {
    raise InvalidSignature("unknown image format")
  }
}
