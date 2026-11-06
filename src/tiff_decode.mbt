// TIFF decoder (first image / IFD0).
//
// Supported: little / big endian, strips and tiles, chunky and planar
// samples, compression None (1), LZW (5), Deflate (8, 32946) and PackBits
// (32773) with horizontal-differencing predictor (2) for 8/16-bit samples,
// photometric WhiteIsZero / BlackIsZero / RGB / Palette / CMYK, 1/2/4/8/16
// bits per sample, and an extra alpha sample (associated alpha is
// un-premultiplied). Other compressions (JPEG, CCITT, ...), BigTIFF and
// non-integer samples raise UnsupportedFeature.

///|
priv struct TiffReader {
  data : Bytes
  little : Bool
}

///|
fn TiffReader::u8(self : TiffReader, off : Int32) -> Int32 raise DecodeError {
  if off < 0 || off >= self.data.length() {
    raise CorruptData("TIFF offset out of range")
  }
  self.data[off].to_int()
}

///|
fn TiffReader::u16(self : TiffReader, off : Int32) -> Int32 raise DecodeError {
  let a = self.u8(off)
  let b = self.u8(off + 1)
  if self.little {
    a | (b << 8)
  } else {
    (a << 8) | b
  }
}

///|
fn TiffReader::u32(self : TiffReader, off : Int32) -> Int32 raise DecodeError {
  let a = self.u16(off)
  let b = self.u16(off + 2)
  let v = if self.little { a | (b << 16) } else { (a << 16) | b }
  if v < 0 {
    raise CorruptData("TIFF value out of range")
  }
  v
}

///|
/// Integer values of an IFD entry (BYTE / SHORT / LONG and signed variants).
fn TiffReader::values(
  self : TiffReader,
  entry : Int32,
) -> Array[Int32] raise DecodeError {
  let typ = self.u16(entry + 2)
  let count = self.u32(entry + 4)
  let size = match typ {
    1 | 6 | 7 => 1
    3 | 8 => 2
    4 | 9 => 4
    _ => return []
  }
  if count > self.data.length() {
    raise CorruptData("TIFF tag count out of range")
  }
  let base = if size * count <= 4 { entry + 8 } else { self.u32(entry + 8) }
  if base > self.data.length() - size * count {
    raise CorruptData("TIFF tag data out of range")
  }
  Array::makei(count, fn(i) {
    let o = base + i * size
    // Bounds were checked above.
    match size {
      1 => self.data[o].to_int()
      2 =>
        if self.little {
          self.data[o].to_int() | (self.data[o + 1].to_int() << 8)
        } else {
          (self.data[o].to_int() << 8) | self.data[o + 1].to_int()
        }
      _ => {
        let b = FixedArray::makei(4, fn(k) { self.data[o + k].to_int() })
        if self.little {
          b[0] | (b[1] << 8) | (b[2] << 16) | (b[3] << 24)
        } else {
          (b[0] << 24) | (b[1] << 16) | (b[2] << 8) | b[3]
        }
      }
    }
  })
}

///|
fn tiff_min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn tiff_signature_ok(data : Bytes) -> Bool {
  data.length() >= 8 &&
  (
    (
      data[0] == b'I' &&
      data[1] == b'I' &&
      data[2] == b'\x2A' &&
      data[3] == b'\x00'
    ) ||
    (
      data[0] == b'M' &&
      data[1] == b'M' &&
      data[2] == b'\x00' &&
      data[3] == b'\x2A'
    )
  )
}

///|
/// TIFF LZW (MSB-first codes, 9-12 bits, "early change"). `expected` bounds
/// the output size.
fn tiff_lzw_decode(src : Bytes, expected : Int32) -> Bytes raise DecodeError {
  if src.length() >= 2 && src[0] == b'\x00' && (src[1].to_int() & 1) == 1 {
    raise UnsupportedFeature("old-style (LSB-first) TIFF LZW")
  }
  let out = Buffer()
  let prefix = FixedArray::make(4096, 0)
  let suffix = FixedArray::make(4096, b'\x00')
  let length = FixedArray::make(4096, 0)
  for i in 0..<256 {
    suffix[i] = i.to_byte()
    length[i] = 1
  }
  let stack = FixedArray::make(4096, b'\x00')
  let mut next = 258
  let mut width = 9
  let mut prev = -1
  let mut bit_buf = 0
  let mut bit_count = 0
  let mut pos = 0
  let mut written = 0
  // Write the string for `code`; return its first byte.
  let emit = fn(code : Int32) -> Byte {
    let len = length[code]
    let mut c = code
    for i in 0..<len {
      stack[len - 1 - i] = suffix[c]
      c = prefix[c]
    }
    for i in 0..<len {
      out.write_byte(stack[i])
    }
    written += len
    stack[0]
  }
  while written < expected {
    while bit_count < width && pos < src.length() {
      bit_buf = (bit_buf << 8) | src[pos].to_int()
      bit_count += 8
      pos += 1
    }
    if bit_count < width {
      break
    }
    let code = (bit_buf >> (bit_count - width)) & ((1 << width) - 1)
    bit_count -= width
    bit_buf = bit_buf & ((1 << bit_count) - 1)
    if code == 256 {
      next = 258
      width = 9
      prev = -1
      continue
    }
    if code == 257 {
      break
    }
    if prev < 0 {
      if code > 255 {
        raise CorruptData("invalid TIFF LZW code")
      }
      ignore(emit(code))
      prev = code
      continue
    }
    let first = if code < next {
      emit(code)
    } else if code == next {
      let f = emit(prev)
      out.write_byte(f)
      written += 1
      f
    } else {
      raise CorruptData("invalid TIFF LZW code")
    }
    if next < 4096 {
      prefix[next] = prev
      suffix[next] = first
      length[next] = length[prev] + 1
      next += 1
      // Early change: widen one code before the table fills the width.
      if next + 1 >= 1 << width && width < 12 {
        width += 1
      }
    }
    prev = code
  }
  out.to_bytes()
}

///|
fn tiff_packbits_decode(src : Bytes, expected : Int32) -> Bytes {
  let out = Buffer()
  let mut pos = 0
  let mut written = 0
  while pos < src.length() && written < expected {
    let n = src[pos].to_int()
    pos += 1
    if n < 128 {
      // Literal run of n + 1 bytes
      let len = tiff_min(n + 1, src.length() - pos)
      for i in 0..<len {
        out.write_byte(src[pos + i])
      }
      pos += len
      written += len
    } else if n > 128 {
      // Repeat the next byte 257 - n times
      if pos < src.length() {
        let b = src[pos]
        pos += 1
        for _ in 0..<(257 - n) {
          out.write_byte(b)
        }
        written += 257 - n
      }
    }
    // n == 128 is a no-op
  }
  out.to_bytes()
}

///|
priv struct TiffImage {
  width : Int32
  height : Int32
  bps : Int32
  spp : Int32
  planar : Bool
  photometric : Int32
  colormap : Array[Int32]
  /// Index of the alpha sample, or -1.
  alpha_index : Int32
  associated_alpha : Bool
}

///|
/// Decode the first image of a TIFF file.
pub fn decode_tiff(raw : Bytes) -> ImageData raise DecodeError {
  if raw.length() >= 4 &&
    (
      (raw[0] == b'I' && raw[2] == b'\x2B') ||
      (raw[0] == b'M' && raw[3] == b'\x2B')
    ) {
    raise UnsupportedFeature("BigTIFF")
  }
  if !tiff_signature_ok(raw) {
    raise InvalidSignature("not a TIFF file")
  }
  let r : TiffReader = { data: raw, little: raw[0] == b'I', }
  let ifd = r.u32(4)
  let n = r.u16(ifd)
  // Tag values, with defaults.
  let tags : Map[Int32, Array[Int32]] = Map([])
  for i in 0..<n {
    let e = ifd + 2 + i * 12
    tags[r.u16(e)] = r.values(e)
  }
  let first = fn(tag : Int32, default : Int32) -> Int32 {
    match tags.get(tag) {
      Some(v) if v.length() > 0 => v[0]
      _ => default
    }
  }
  let width = first(256, 0)
  let height = first(257, 0)
  check_decode_size(width, height)
  let spp = first(277, 1)
  let bps_all = tags.get(258).unwrap_or([1])
  let bps = if bps_all.is_empty() { 1 } else { bps_all[0] }
  for b in bps_all {
    if b != bps {
      raise UnsupportedFeature("TIFF with different bits per sample")
    }
  }
  if bps != 1 && bps != 2 && bps != 4 && bps != 8 && bps != 16 {
    raise UnsupportedFeature("TIFF bits per sample: " + bps.to_string())
  }
  if spp < 1 || spp > 8 {
    raise UnsupportedFeature("TIFF samples per pixel: " + spp.to_string())
  }
  if first(339, 1) != 1 {
    raise UnsupportedFeature("TIFF sample format other than unsigned int")
  }
  if first(266, 1) != 1 {
    raise UnsupportedFeature("TIFF FillOrder 2")
  }
  let compression = first(259, 1)
  match compression {
    1 | 5 | 8 | 32946 | 32773 => ()
    7 | 6 => raise UnsupportedFeature("JPEG-compressed TIFF")
    2 | 3 | 4 => raise UnsupportedFeature("CCITT-compressed TIFF")
    c => raise UnsupportedFeature("TIFF compression " + c.to_string())
  }
  let photometric = first(262, if spp >= 3 { 2 } else { 1 })
  let base_channels = match photometric {
    0 | 1 | 3 => 1
    2 => 3
    5 => 4
    p => raise UnsupportedFeature("TIFF photometric " + p.to_string())
  }
  if spp < base_channels {
    raise CorruptData("TIFF has too few samples for its photometric")
  }
  let extra = tags.get(338).unwrap_or([])
  let (alpha_index, associated_alpha) = if spp > base_channels &&
    extra.length() > 0 &&
    (extra[0] == 1 || extra[0] == 2) {
    (base_channels, extra[0] == 1)
  } else {
    (-1, false)
  }
  let predictor = first(317, 1)
  if predictor != 1 && (predictor != 2 || (bps != 8 && bps != 16)) {
    raise UnsupportedFeature("TIFF predictor " + predictor.to_string())
  }
  let colormap = tags.get(320).unwrap_or([])
  if photometric == 3 && colormap.length() < 3 * (1 << bps) {
    raise CorruptData("TIFF palette image without a complete ColorMap")
  }
  let planar = first(284, 1) == 2 && spp > 1
  let img : TiffImage = {
    width,
    height,
    bps,
    spp,
    planar,
    photometric,
    colormap,
    alpha_index,
    associated_alpha,
  }
  // Raw sample planes: one per sample when planar, otherwise one chunky.
  let plane_spp = if planar { 1 } else { spp }
  let nplanes = if planar { spp } else { 1 }
  let row_bytes = (width * plane_spp * bps + 7) / 8
  if row_bytes.to_int64() * height.to_int64() * nplanes.to_int64() >
    MAX_DECODE_PIXELS * 8L {
    raise UnsupportedFeature("TIFF image too large")
  }
  let planes = Array::makei(nplanes, fn(_) {
    FixedArray::make(row_bytes * height, b'\x00')
  })
  let tiled = tags.contains(322)
  let (cw, ch, offsets, counts) = if tiled {
    (
      first(322, 0),
      first(323, 0),
      tags.get(324).unwrap_or([]),
      tags.get(325).unwrap_or([]),
    )
  } else {
    let rps = first(278, height)
    (
      width,
      if rps <= 0 || rps > height {
        height
      } else {
        rps
      },
      tags.get(273).unwrap_or([]),
      tags.get(279).unwrap_or([]),
    )
  }
  if cw <= 0 || ch <= 0 {
    raise CorruptData("invalid TIFF strip / tile size")
  }
  check_decode_size(cw, ch)
  let across = (width + cw - 1) / cw
  let down = (height + ch - 1) / ch
  let per_plane = across * down
  if offsets.length() < per_plane * nplanes {
    raise CorruptData("TIFF is missing strip / tile offsets")
  }
  let chunk_row_bytes = (cw * plane_spp * bps + 7) / 8
  for p in 0..<nplanes {
    for c in 0..<per_plane {
      let idx = p * per_plane + c
      let off = offsets[idx]
      let len = if idx < counts.length() {
        counts[idx]
      } else {
        raw.length() - off
      }
      if off < 0 || len < 0 || off > raw.length() || len > raw.length() - off {
        raise CorruptData("TIFF strip / tile out of range")
      }
      let src = raw[off:off + len].to_owned()
      let expected = chunk_row_bytes * ch
      let data = match compression {
        1 => src
        5 => tiff_lzw_decode(src, expected)
        8 | 32946 =>
          // Bounded by the chunk size (decompression bombs).
          @zlib.zlib_decompress(src, max_size=expected) catch {
            _ => raise CorruptData("TIFF deflate data is corrupt or too large")
          }
        _ => tiff_packbits_decode(src, expected)
      }
      // Copy rows of this chunk into the plane (missing data stays zero).
      let x0 = c % across * cw
      let y0 = c / across * ch
      let copy_bytes = tiff_min(
        chunk_row_bytes,
        ((width - x0) * plane_spp * bps + 7) / 8,
      )
      let x0_byte = x0 * plane_spp * bps / 8
      let row = FixedArray::make(chunk_row_bytes, b'\x00')
      for yy in 0..<ch {
        let y = y0 + yy
        if y >= height {
          break
        }
        let s = yy * chunk_row_bytes
        row.fill(b'\x00')
        if s < data.length() {
          row.blit_from_bytes(
            0,
            data,
            s,
            tiff_min(chunk_row_bytes, data.length() - s),
          )
        }
        if predictor == 2 {
          tiff_undo_predictor(row, cw, plane_spp, bps, r.little)
        }
        row.blit_to(
          planes[p],
          len=copy_bytes,
          dst_offset=y * row_bytes + x0_byte,
        )
      }
    }
  }
  tiff_to_rgba(img, planes, row_bytes, r.little)
}

///|
/// Undo horizontal differencing on one row of `width` pixels.
fn tiff_undo_predictor(
  row : FixedArray[Byte],
  width : Int32,
  spp : Int32,
  bps : Int32,
  little : Bool,
) -> Unit {
  if bps == 8 {
    for i in spp..<(width * spp) {
      row[i] = (row[i].to_int() + row[i - spp].to_int()).to_byte()
    }
  } else {
    let get = fn(i : Int32) {
      if little {
        row[i * 2].to_int() | (row[i * 2 + 1].to_int() << 8)
      } else {
        (row[i * 2].to_int() << 8) | row[i * 2 + 1].to_int()
      }
    }
    for i in spp..<(width * spp) {
      let v = (get(i) + get(i - spp)) & 0xFFFF
      if little {
        row[i * 2] = v.to_byte()
        row[i * 2 + 1] = (v >> 8).to_byte()
      } else {
        row[i * 2] = (v >> 8).to_byte()
        row[i * 2 + 1] = v.to_byte()
      }
    }
  }
}

///|
fn tiff_to_rgba(
  img : TiffImage,
  planes : Array[FixedArray[Byte]],
  row_bytes : Int32,
  little : Bool,
) -> ImageData {
  let width = img.width
  let height = img.height
  let bps = img.bps
  let spp = img.spp
  let max = (1 << bps) - 1
  // Sample `s` of pixel (x, y), raw (0..2^bps-1).
  let raw_sample = fn(x : Int32, y : Int32, s : Int32) -> Int32 {
    let (plane, idx) = if img.planar {
      (planes[s], x)
    } else {
      (planes[0], x * spp + s)
    }
    let base = y * row_bytes
    match bps {
      8 => plane[base + idx].to_int()
      16 =>
        if little {
          plane[base + idx * 2].to_int() |
          (plane[base + idx * 2 + 1].to_int() << 8)
        } else {
          (plane[base + idx * 2].to_int() << 8) |
          plane[base + idx * 2 + 1].to_int()
        }
      _ => {
        let bit = idx * bps
        (plane[base + (bit >> 3)].to_int() >> (8 - bps - (bit & 7))) & max
      }
    }
  }
  // Scaled to 8 bits.
  let sample8 = fn(x : Int32, y : Int32, s : Int32) -> Int32 {
    let v = raw_sample(x, y, s)
    match bps {
      8 => v
      16 => v >> 8
      _ => v * 255 / max
    }
  }
  let out = FixedArray::make(width * height * 4, b'\xFF')
  for y in 0..<height {
    for x in 0..<width {
      let o = (y * width + x) * 4
      let (r, g, b) = match img.photometric {
        0 => {
          let v = 255 - sample8(x, y, 0)
          (v, v, v)
        }
        1 => {
          let v = sample8(x, y, 0)
          (v, v, v)
        }
        3 => {
          let i = raw_sample(x, y, 0)
          let n = 1 << bps
          (
            img.colormap[i] >> 8,
            img.colormap[n + i] >> 8,
            img.colormap[2 * n + i] >> 8,
          )
        }
        5 => {
          // Like Pillow: (255 - c) * (255 - k) / 255, computed as
          // nk - c * nk / 255 with MULDIV255 rounding.
          let nk = 255 - sample8(x, y, 3)
          let muldiv255 = fn(a : Int32, b : Int32) {
            let t = a * b + 128
            ((t >> 8) + t) >> 8
          }
          (
            nk - muldiv255(sample8(x, y, 0), nk),
            nk - muldiv255(sample8(x, y, 1), nk),
            nk - muldiv255(sample8(x, y, 2), nk),
          )
        }
        _ => (sample8(x, y, 0), sample8(x, y, 1), sample8(x, y, 2))
      }
      if img.alpha_index >= 0 {
        let a = sample8(x, y, img.alpha_index)
        if img.associated_alpha && a != 0 && a != 255 {
          // Un-premultiply like Pillow's RGBa -> RGBA.
          out[o] = idct_clamp(255 * r / a).to_byte()
          out[o + 1] = idct_clamp(255 * g / a).to_byte()
          out[o + 2] = idct_clamp(255 * b / a).to_byte()
        } else {
          out[o] = r.to_byte()
          out[o + 1] = g.to_byte()
          out[o + 2] = b.to_byte()
        }
        out[o + 3] = a.to_byte()
      } else {
        out[o] = r.to_byte()
        out[o + 1] = g.to_byte()
        out[o + 2] = b.to_byte()
      }
    }
  }
  { width, height, data: Bytes::from_array(out), }
}
