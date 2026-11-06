// EXIF orientation: read the Orientation tag (0x0112) from JPEG (APP1
// "Exif"), PNG (eXIf) or TIFF (IFD0) files, and apply it to an image.

///|
/// Orientation tag in an EXIF / TIFF structure starting at `data[0]`.
fn exif_tiff_orientation(data : Bytes) -> Int32? {
  if !tiff_signature_ok(data) {
    return None
  }
  let r : TiffReader = { data, little: data[0] == b'I', }
  let found = try {
    let ifd = r.u32(4)
    let n = r.u16(ifd)
    let mut v : Int32? = None
    for i in 0..<n {
      let e = ifd + 2 + i * 12
      if r.u16(e) == 0x0112 {
        let vals = r.values(e)
        if vals.length() > 0 && vals[0] >= 1 && vals[0] <= 8 {
          v = Some(vals[0])
        }
        break
      }
    }
    v
  } catch {
    _ => None
  }
  found
}

///|
/// Strip an optional "Exif\0\0" prefix.
fn exif_payload(data : Bytes) -> Bytes {
  if data.length() >= 6 &&
    data[0] == b'E' &&
    data[1] == b'x' &&
    data[2] == b'i' &&
    data[3] == b'f' &&
    data[4] == b'\x00' &&
    data[5] == b'\x00' {
    data[6:data.length()].to_owned()
  } else {
    data
  }
}

///|
/// The EXIF orientation (1-8) of a JPEG, PNG or TIFF file, if it has one.
/// Malformed metadata is treated as absent.
pub fn read_exif_orientation(raw : Bytes) -> Int32? {
  if is_jpeg_signature(raw) {
    // Walk the markers before the first scan, looking for APP1 "Exif".
    let mut pos = 2
    while pos + 4 <= raw.length() {
      if raw[pos] != b'\xFF' {
        return None
      }
      let marker = raw[pos + 1].to_int()
      if marker == 0xFF {
        pos += 1
        continue
      }
      if marker == 0xDA || marker == 0xD9 {
        return None
      }
      let len = (raw[pos + 2].to_int() << 8) | raw[pos + 3].to_int()
      if len < 2 || pos + 2 + len > raw.length() {
        return None
      }
      if marker == 0xE1 {
        let seg = raw[pos + 4:pos + 2 + len].to_owned()
        let payload = exif_payload(seg)
        if payload.length() != seg.length() {
          return exif_tiff_orientation(payload)
        }
      }
      pos += 2 + len
    }
    None
  } else if is_png_signature(raw) {
    let chunks = parse_chunks(raw) catch { _ => return None }
    for chunk in chunks {
      if chunk.chunk_type == "eXIf" {
        return exif_tiff_orientation(exif_payload(chunk.data))
      }
    }
    None
  } else if tiff_signature_ok(raw) {
    exif_tiff_orientation(raw)
  } else {
    None
  }
}

///|
/// Transform `img` so that it displays upright for EXIF `orientation`
/// (same mapping as Pillow's `ImageOps.exif_transpose`):
/// 1 as is, 2 mirror horizontally, 3 rotate 180, 4 mirror vertically,
/// 5 transpose, 6 rotate 90 clockwise, 7 transverse, 8 rotate 90
/// counter-clockwise. Other values return the image unchanged.
pub fn apply_orientation(img : ImageData, orientation : Int32) -> ImageData {
  let w = img.width
  let h = img.height
  if orientation < 2 || orientation > 8 {
    return img
  }
  let swap = orientation >= 5
  let ow = if swap { h } else { w }
  let oh = if swap { w } else { h }
  let out = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<oh {
    for x in 0..<ow {
      // Source pixel for output (x, y).
      let (sx, sy) = match orientation {
        2 => (w - 1 - x, y)
        3 => (w - 1 - x, h - 1 - y)
        4 => (x, h - 1 - y)
        5 => (y, x)
        6 => (y, h - 1 - x)
        7 => (w - 1 - y, h - 1 - x)
        _ => (w - 1 - y, x)
      }
      out.blit_from_bytes((y * ow + x) * 4, img.data, (sy * w + sx) * 4, 4)
    }
  }
  { width: ow, height: oh, data: Bytes::from_array(out), }
}

///|
/// `decode_image` followed by `apply_orientation` with the file's EXIF
/// orientation, so photos display upright.
pub fn decode_image_upright(raw : Bytes) -> ImageData raise DecodeError {
  let img = decode_image(raw)
  match read_exif_orientation(raw) {
    Some(o) => apply_orientation(img, o)
    None => img
  }
}
