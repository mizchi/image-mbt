///|
let png_signature : FixedArray[Byte] = [
  b'\x89', b'\x50', b'\x4E', b'\x47', b'\x0D', b'\x0A', b'\x1A', b'\x0A',
]

///|
fn read_u32be(data : Bytes, offset : Int32) -> UInt32 {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  (b0 << 24).lor(b1 << 16).lor(b2 << 8).lor(b3).reinterpret_as_uint()
}

///|
fn read_i32be(data : Bytes, offset : Int32) -> Int32 {
  let b0 = data[offset].to_int() & 0xFF
  let b1 = data[offset + 1].to_int() & 0xFF
  let b2 = data[offset + 2].to_int() & 0xFF
  let b3 = data[offset + 3].to_int() & 0xFF
  (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
}

///|
fn chunk_type_str(data : Bytes, offset : Int32) -> String {
  String::from_array([
    data[offset].to_int().unsafe_to_char(),
    data[offset + 1].to_int().unsafe_to_char(),
    data[offset + 2].to_int().unsafe_to_char(),
    data[offset + 3].to_int().unsafe_to_char(),
  ])
}

///|
fn parse_ihdr(data : Bytes) -> IhdrData raise DecodeError {
  if data.length() < 13 {
    raise CorruptData("IHDR too short")
  }
  let width = read_i32be(data, 0)
  let height = read_i32be(data, 4)
  let bit_depth = data[8].to_int()
  let ct = color_type_from_png(data[9].to_int())
  let compression = data[10].to_int()
  let filter = data[11].to_int()
  let interlace = data[12].to_int()
  if width <= 0 || height <= 0 {
    raise CorruptData("invalid dimensions")
  }
  validate_png_bit_depth(ct, bit_depth)
  if interlace != 0 && interlace != 1 {
    raise CorruptData("invalid interlace method: " + interlace.to_string())
  }
  { width, height, bit_depth, color_type: ct, compression, filter, interlace, }
}

///|
priv struct PngChunk {
  chunk_type : String
  data : Bytes
}

///|
fn parse_chunks(raw : Bytes) -> Array[PngChunk] raise DecodeError {
  if raw.length() < 8 {
    raise InvalidSignature("not a PNG file")
  }
  // Verify signature
  for i in 0..<8 {
    if raw[i] != png_signature[i] {
      raise InvalidSignature("not a PNG file")
    }
  }
  let chunks : Array[PngChunk] = []
  let mut pos = 8
  while pos + 12 <= raw.length() {
    let length = read_u32be(raw, pos).reinterpret_as_int()
    let ct = chunk_type_str(raw, pos + 4)
    if pos + 12 + length > raw.length() {
      raise CorruptData("chunk extends beyond file")
    }
    // CRC covers chunk type + data
    let crc_data_len = 4 + length
    let crc_buf = FixedArray::make(crc_data_len, b'\x00')
    crc_buf.blit_from_bytes(0, raw, pos + 4, crc_data_len)
    let computed_crc = @zlib.crc32_fixed(crc_buf)
    let stored_crc = read_u32be(raw, pos + 8 + length)
    if computed_crc != stored_crc {
      raise InvalidChunkCrc(ct)
    }
    // Extract chunk data
    let chunk_data = if length > 0 {
      let buf = FixedArray::make(length, b'\x00')
      buf.blit_from_bytes(0, raw, pos + 8, length)
      Bytes::from_array(buf)
    } else {
      Bytes::new(0)
    }
    chunks.push({ chunk_type: ct, data: chunk_data, })
    pos = pos + 12 + length
    if ct == "IEND" {
      break
    }
  }
  chunks
}

///|
fn parse_png_ihdr(chunks : Array[PngChunk]) -> IhdrData raise DecodeError {
  if chunks.is_empty() {
    raise MissingChunk("IHDR")
  }
  match chunks[0] {
    { chunk_type: "IHDR", data, } => parse_ihdr(data)
    _ => raise MissingChunk("IHDR must be first chunk")
  }
}

///|
fn collect_png_image_data(
  chunks : Array[PngChunk],
) -> (Array[Bytes], Bytes?, Bytes?) raise DecodeError {
  let idat_parts : Array[Bytes] = []
  let mut palette : Bytes? = None
  let mut trns : Bytes? = None
  for chunk in chunks {
    match chunk.chunk_type {
      "IDAT" => idat_parts.push(chunk.data)
      "PLTE" => palette = Some(chunk.data)
      "tRNS" => trns = Some(chunk.data)
      _ => ()
    }
  }
  if idat_parts.is_empty() {
    raise MissingChunk("IDAT")
  }
  (idat_parts, palette, trns)
}

///|
fn decode_png_scanlines(
  ihdr : IhdrData,
  idat_parts : Array[Bytes],
  palette : Bytes?,
  trns : Bytes?,
  on_row : (Int32, Bytes) -> Unit,
) -> Unit raise DecodeError {
  // Concatenate IDAT data
  let total_idat_len = idat_parts.fold(init=0, fn(acc, b) { acc + b.length() })
  let idat_buf = FixedArray::make(total_idat_len, b'\x00')
  let mut offset = 0
  for part in idat_parts {
    idat_buf.blit_from_bytes(offset, part, 0, part.length())
    offset += part.length()
  }
  let compressed = Bytes::from_array(idat_buf)
  // Decompress
  let decompressed = @zlib.zlib_decompress(compressed) catch {
    _ => raise CorruptData("zlib decompression failed")
  }
  if ihdr.interlace == 1 {
    decode_png_adam7(ihdr, decompressed, palette, trns, on_row)
    return
  }
  // Reconstruct image
  let stride = png_row_bytes(ihdr.width, ihdr.color_type, ihdr.bit_depth)
  let expected_len = ihdr.height * (1 + stride)
  if decompressed.length() != expected_len {
    raise CorruptData(
      "decompressed size mismatch: expected " +
      expected_len.to_string() +
      " got " +
      decompressed.length().to_string(),
    )
  }
  ignore(
    decode_png_pass(
      ihdr,
      decompressed,
      0,
      ihdr.width,
      ihdr.height,
      palette,
      trns,
      on_row,
    ),
  )
}

///|
/// Defilter and convert `rows` scanlines of `width` pixels starting at byte
/// `offset` of the decompressed stream. Returns the offset after the pass.
fn decode_png_pass(
  ihdr : IhdrData,
  decompressed : Bytes,
  offset : Int32,
  width : Int32,
  rows : Int32,
  palette : Bytes?,
  trns : Bytes?,
  on_row : (Int32, Bytes) -> Unit,
) -> Int32 raise DecodeError {
  let bpp = bytes_per_pixel(ihdr.color_type, ihdr.bit_depth)
  let stride = png_row_bytes(width, ihdr.color_type, ihdr.bit_depth)
  let converter = PngRowConverter::new(
    width,
    ihdr.color_type,
    ihdr.bit_depth,
    palette,
    trns,
  )
  let mut prev_row = Bytes::new(stride)
  for y in 0..<rows {
    let row_offset = offset + y * (1 + stride)
    let filter_type = decompressed[row_offset].to_int()
    // Extract filtered row data
    let filtered = FixedArray::make(stride, b'\x00')
    filtered.blit_from_bytes(0, decompressed, row_offset + 1, stride)
    let reconstructed = reconstruct_row(
      filter_type,
      Bytes::from_array(filtered),
      prev_row,
      bpp,
    )
    on_row(y, converter.convert(reconstructed))
    prev_row = reconstructed
  }
  offset + rows * (1 + stride)
}

///|
/// Adam7 passes: (x0, y0, dx, dy).
let adam7_passes : FixedArray[(Int32, Int32, Int32, Int32)] = [
  (0, 0, 8, 8),
  (4, 0, 8, 8),
  (0, 4, 4, 8),
  (2, 0, 4, 4),
  (0, 2, 2, 4),
  (1, 0, 2, 2),
  (0, 1, 1, 2),
]

///|
/// Decode an Adam7-interlaced image. Each pass is a small sub-image that is
/// defiltered on its own (empty passes have no scanlines), then scattered
/// into the full RGBA image, which is emitted row by row at the end.
fn decode_png_adam7(
  ihdr : IhdrData,
  decompressed : Bytes,
  palette : Bytes?,
  trns : Bytes?,
  on_row : (Int32, Bytes) -> Unit,
) -> Unit raise DecodeError {
  let width = ihdr.width
  let height = ihdr.height
  let pass_size = fn(
    x0 : Int32,
    y0 : Int32,
    dx : Int32,
    dy : Int32,
  ) -> (Int32, Int32) {
    let pw = if width > x0 { (width - x0 + dx - 1) / dx } else { 0 }
    let ph = if height > y0 { (height - y0 + dy - 1) / dy } else { 0 }
    if pw == 0 || ph == 0 {
      (0, 0)
    } else {
      (pw, ph)
    }
  }
  let mut expected_len = 0
  for p in adam7_passes {
    let (pw, ph) = pass_size(p.0, p.1, p.2, p.3)
    expected_len += ph *
      (1 + png_row_bytes(pw, ihdr.color_type, ihdr.bit_depth))
  }
  if decompressed.length() != expected_len {
    raise CorruptData(
      "decompressed size mismatch: expected " +
      expected_len.to_string() +
      " got " +
      decompressed.length().to_string(),
    )
  }
  let rgba = FixedArray::make(width * height * 4, b'\x00')
  let mut offset = 0
  for p in adam7_passes {
    let (x0, y0, dx, dy) = p
    let (pw, ph) = pass_size(x0, y0, dx, dy)
    if pw == 0 {
      continue
    }
    offset = decode_png_pass(
      ihdr,
      decompressed,
      offset,
      pw,
      ph,
      palette,
      trns,
      fn(r, row) {
        let base = (y0 + r * dy) * width
        for i in 0..<pw {
          let dst = (base + x0 + i * dx) * 4
          rgba.blit_from_bytes(dst, row, i * 4, 4)
        }
      },
    )
  }
  let full = Bytes::from_array(rgba)
  for y in 0..<height {
    on_row(y, full[y * width * 4:(y + 1) * width * 4].to_owned())
  }
}

///|
pub fn decode_png_stream(
  raw : Bytes,
  on_row~ : (Int32, Bytes) -> Unit,
) -> IhdrData raise DecodeError {
  let chunks = parse_chunks(raw)
  let ihdr = parse_png_ihdr(chunks)
  let (idat_parts, palette, trns) = collect_png_image_data(chunks)
  decode_png_scanlines(ihdr, idat_parts, palette, trns, on_row)
  ihdr
}

///|
pub fn decode_png(raw : Bytes) -> ImageData raise DecodeError {
  let chunks = parse_chunks(raw)
  let ihdr = parse_png_ihdr(chunks)
  let (idat_parts, palette, trns) = collect_png_image_data(chunks)
  let rgba_buf = FixedArray::make(ihdr.width * ihdr.height * 4, b'\x00')
  decode_png_scanlines(ihdr, idat_parts, palette, trns, fn(y, row) {
    let dst_offset = y * ihdr.width * 4
    rgba_buf.blit_from_bytes(dst_offset, row, 0, ihdr.width * 4)
  })
  { width: ihdr.width, height: ihdr.height, data: Bytes::from_array(rgba_buf), }
}

///|
test "read_u32be" {
  let data = b"\x00\x00\x00\x0D"
  assert_eq(read_u32be(data, 0), 13U)
}

///|
test "read_i32be" {
  let data = b"\x00\x00\x00\x01"
  assert_eq(read_i32be(data, 0), 1)
}
