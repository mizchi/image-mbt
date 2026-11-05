///|
priv struct IcoEntry {
  width : Int32
  height : Int32
  bpp : Int32
  size : Int32
  offset : Int32
}

///|
fn parse_ico_dir(raw : Bytes) -> Array[IcoEntry] raise DecodeError {
  if raw.length() < 6 ||
    read_u16le(raw, 0) != 0 ||
    (read_u16le(raw, 2) != 1 && read_u16le(raw, 2) != 2) {
    raise InvalidSignature("not an ICO/CUR file")
  }
  let count = read_u16le(raw, 4)
  if count == 0 {
    raise CorruptData("ICO file has no images")
  }
  if raw.length() < 6 + count * 16 {
    raise CorruptData("ICO directory truncated")
  }
  let entries : Array[IcoEntry] = []
  for i in 0..<count {
    let e = 6 + i * 16
    let w = raw[e].to_int()
    let h = raw[e + 1].to_int()
    let size = read_u32le(raw, e + 8).reinterpret_as_int()
    let offset = read_u32le(raw, e + 12).reinterpret_as_int()
    if size <= 0 || offset < 0 || size > raw.length() - offset {
      raise CorruptData("ICO image " + i.to_string() + " out of bounds")
    }
    entries.push({
      width: if w == 0 {
        256
      } else {
        w
      },
      height: if h == 0 {
        256
      } else {
        h
      },
      bpp: read_u16le(raw, e + 6),
      size,
      offset,
    })
  }
  entries
}

///|
/// Decode one ICO payload: an embedded PNG, or a headerless DIB whose height
/// covers the XOR (color) bitmap followed by the 1-bit AND (transparency)
/// mask.
fn decode_ico_payload(data : Bytes) -> ImageData raise DecodeError {
  if is_png_signature(data) {
    return decode_png(data)
  }
  if data.length() < 40 {
    raise CorruptData("ICO bitmap too short")
  }
  let dib_size = read_u32le(data, 0).reinterpret_as_int()
  if dib_size < 40 || dib_size > data.length() {
    raise UnsupportedFeature(
      "unsupported ICO DIB header size: " + dib_size.to_string(),
    )
  }
  let width = read_i32le(data, 4)
  let height = read_i32le(data, 8).abs() / 2
  let bpp = read_u16le(data, 14)
  let compression = read_u32le(data, 16).reinterpret_as_int()
  let colors_used = read_u32le(data, 32).reinterpret_as_int()
  check_decode_size(width, height)
  let palette_len = if bpp <= 8 {
    let max_entries = 1 << bpp
    (if colors_used > 0 && colors_used < max_entries {
      colors_used
    } else {
      max_entries
    }) *
    4
  } else {
    0
  }
  let masks_len = if compression == BI_BITFIELDS && dib_size == 40 {
    12
  } else {
    0
  }
  let xor_offset = dib_size + masks_len + palette_len
  // Wrap the DIB in a BMP file header with the height halved.
  let bmp = FixedArray::make(14 + data.length(), b'\x00')
  bmp[0] = b'\x42'
  bmp[1] = b'\x4D'
  write_u32le(bmp, 2, (14 + data.length()).reinterpret_as_uint())
  write_u32le(bmp, 10, (14 + xor_offset).reinterpret_as_uint())
  bmp.blit_from_bytes(14, data, 0, data.length())
  write_u32le(bmp, 14 + 8, height.reinterpret_as_uint())
  let img = decode_bmp(Bytes::from_array(bmp))
  // decode_bmp validated bpp and that the XOR bitmap fits in `data`.
  let xor_row = (width * bpp + 31) / 32 * 4
  let and_offset = xor_offset + xor_row * height
  // 32-bit bitmaps carry real alpha; the AND mask only matters when there
  // is none (all alpha bytes zero, which decode_bmp treats as opaque).
  let use_mask = if bpp == 32 {
    let mut all_zero = true
    for y in 0..<height {
      for x in 0..<width {
        if data[xor_offset + y * xor_row + x * 4 + 3] != b'\x00' {
          all_zero = false
        }
      }
    }
    all_zero
  } else {
    true
  }
  let and_row = (width + 31) / 32 * 4
  if !use_mask ||
    and_offset.to_int64() + and_row.to_int64() * height.to_int64() >
    data.length().to_int64() {
    return img
  }
  let out = img.data.to_fixedarray()
  for y in 0..<height {
    // The mask is stored bottom-up like the color bitmap.
    let src = and_offset + (height - 1 - y) * and_row
    for x in 0..<width {
      if ((data[src + (x >> 3)].to_int() >> (7 - (x & 7))) & 1) == 1 {
        out[(y * width + x) * 4 + 3] = b'\x00'
      }
    }
  }
  { width, height, data: Bytes::from_array(out), }
}

///|
/// Decode every image of an ICO / CUR file, in directory order.
pub fn decode_ico_all(raw : Bytes) -> Array[ImageData] raise DecodeError {
  let images : Array[ImageData] = []
  for e in parse_ico_dir(raw) {
    images.push(decode_ico_payload(raw[e.offset:e.offset + e.size].to_owned()))
  }
  images
}

///|
/// Decode the best image of an ICO / CUR file: the largest one, preferring
/// higher bit depth among equal sizes.
pub fn decode_ico(raw : Bytes) -> ImageData raise DecodeError {
  let entries = parse_ico_dir(raw)
  let mut best = entries[0]
  for e in entries {
    let area = e.width * e.height
    let best_area = best.width * best.height
    if area > best_area || (area == best_area && e.bpp > best.bpp) {
      best = e
    }
  }
  decode_ico_payload(raw[best.offset:best.offset + best.size].to_owned())
}
