// TIFF encoder: 8-bit RGB (opaque images) or RGBA (unassociated alpha),
// little endian, strips of about 8 KiB, with None / LZW / Deflate /
// PackBits compression (horizontal predictor for LZW and Deflate).

///|
/// Compression for `encode_tiff`.
pub(all) enum TiffCompression {
  /// No compression.
  NoCompression
  /// LZW with the horizontal predictor (the default).
  Lzw
  /// zlib / Deflate (Adobe, code 8) with the horizontal predictor.
  Deflate
  /// PackBits run-length encoding.
  PackBits
}

///|
priv struct TiffBitWriter {
  buf : Buffer
  mut acc : Int32
  mut nbits : Int32
}

///|
fn TiffBitWriter::put(
  self : TiffBitWriter,
  code : Int32,
  width : Int32,
) -> Unit {
  self.acc = (self.acc << width) | code
  self.nbits += width
  while self.nbits >= 8 {
    self.buf.write_byte((self.acc >> (self.nbits - 8)).to_byte())
    self.nbits -= 8
    self.acc = self.acc & ((1 << self.nbits) - 1)
  }
}

///|
/// TIFF LZW (MSB-first, 9-12 bit codes, early change), following libtiff's
/// encoder: a clear code first, a new clear code when the table is full.
fn tiff_lzw_encode(src : FixedArray[Byte]) -> Bytes {
  let bw : TiffBitWriter = { buf: Buffer(), acc: 0, nbits: 0, }
  let table : Map[Int32, Int32] = Map([])
  let mut width = 9
  let mut next = 258
  bw.put(256, width)
  if src.length() > 0 {
    let mut prefix = src[0].to_int()
    for i in 1..<src.length() {
      let c = src[i].to_int()
      let key = (prefix << 8) | c
      match table.get(key) {
        Some(code) => prefix = code
        None => {
          bw.put(prefix, width)
          table[key] = next
          next += 1
          if next == 4094 {
            bw.put(256, width)
            table.clear()
            width = 9
            next = 258
          } else if next > (1 << width) - 1 {
            width += 1
          }
          prefix = c
        }
      }
    }
    bw.put(prefix, width)
    next += 1
    if next == 4094 {
      bw.put(256, width)
      width = 9
    } else if next > (1 << width) - 1 {
      width += 1
    }
  }
  bw.put(257, width)
  if bw.nbits > 0 {
    bw.buf.write_byte((bw.acc << (8 - bw.nbits)).to_byte())
  }
  bw.buf.to_bytes()
}

///|
/// PackBits: runs of 2-128 equal bytes as (1 - n, byte), other bytes as
/// literal groups of up to 128.
fn tiff_packbits_encode(src : FixedArray[Byte]) -> Bytes {
  let out = Buffer()
  let n = src.length()
  let mut i = 0
  while i < n {
    let mut run = 1
    while i + run < n && run < 128 && src[i + run] == src[i] {
      run += 1
    }
    if run >= 2 {
      out.write_byte((257 - run).to_byte())
      out.write_byte(src[i])
      i += run
    } else {
      let start = i
      i += 1
      while i < n && i - start < 128 {
        if i + 1 < n && src[i] == src[i + 1] {
          break
        }
        i += 1
      }
      out.write_byte((i - start - 1).to_byte())
      for k in start..<i {
        out.write_byte(src[k])
      }
    }
  }
  out.to_bytes()
}

///|
fn tiff_put16(buf : Buffer, v : Int32) -> Unit {
  buf.write_byte(v.to_byte())
  buf.write_byte((v >> 8).to_byte())
}

///|
fn tiff_put32(buf : Buffer, v : Int32) -> Unit {
  tiff_put16(buf, v & 0xFFFF)
  tiff_put16(buf, (v >> 16) & 0xFFFF)
}

///|
/// Encode a TIFF: RGB when every pixel is opaque, otherwise RGBA with
/// unassociated alpha (ExtraSamples = 2).
pub fn encode_tiff(
  img : ImageData,
  compression~ : TiffCompression = Lzw,
) -> Bytes raise EncodeError {
  validate_rgba8_image(img)
  let w = img.width
  let h = img.height
  let mut all_opaque = true
  for i in 0..<(w * h) {
    if img.data[i * 4 + 3] != b'\xFF' {
      all_opaque = false
      break
    }
  }
  let spp = if all_opaque { 3 } else { 4 }
  let row_bytes = w * spp
  let rps = if row_bytes >= 8192 { 1 } else { 8192 / row_bytes }
  let rps = if rps > h { h } else { rps }
  let nstrips = (h + rps - 1) / rps
  let predictor = compression is (Lzw | Deflate)
  let (code, compress) = match compression {
    NoCompression => (1, fn(b : FixedArray[Byte]) { Bytes::from_array(b) })
    Lzw => (5, tiff_lzw_encode)
    Deflate =>
      (
        8,
        fn(b : FixedArray[Byte]) { @zlib.zlib_compress(Bytes::from_array(b)) },
      )
    PackBits => (32773, tiff_packbits_encode)
  }
  let strips : Array[Bytes] = []
  for s in 0..<nstrips {
    let y0 = s * rps
    let rows = if y0 + rps > h { h - y0 } else { rps }
    let raw = FixedArray::make(rows * row_bytes, b'\x00')
    for y in 0..<rows {
      let src = (y0 + y) * w * 4
      let dst = y * row_bytes
      for x in 0..<w {
        for c in 0..<spp {
          raw[dst + x * spp + c] = img.data[src + x * 4 + c]
        }
      }
      if predictor {
        for i = row_bytes - 1; i >= spp; i = i - 1 {
          raw[dst + i] = (raw[dst + i].to_int() - raw[dst + i - spp].to_int()).to_byte()
        }
      }
    }
    strips.push(compress(raw))
  }
  // Layout: header, strip data, IFD, out-of-line tag values.
  let out = Buffer()
  out.write_byte(b'I')
  out.write_byte(b'I')
  tiff_put16(out, 42)
  let mut data_len = 0
  for st in strips {
    data_len += st.length() + (st.length() & 1)
  }
  let ifd = 8 + data_len
  tiff_put32(out, ifd)
  let offsets : Array[Int32] = []
  let mut pos = 8
  for st in strips {
    offsets.push(pos)
    out.write_bytes(st)
    if (st.length() & 1) == 1 {
      out.write_byte(b'\x00')
    }
    pos += st.length() + (st.length() & 1)
  }
  // (tag, type, count, values)
  let entries : Array[(Int32, Int32, Int32, Array[Int32])] = [
    (256, 4, 1, [w]),
    (257, 4, 1, [h]),
    (258, 3, spp, Array::make(spp, 8)),
    (259, 3, 1, [code]),
    (262, 3, 1, [2]),
    (273, 4, nstrips, offsets),
    (277, 3, 1, [spp]),
    (278, 4, 1, [rps]),
    (279, 4, nstrips, strips.map(fn(st) { st.length() })),
    (282, 5, 1, [72, 1]),
    (283, 5, 1, [72, 1]),
    (284, 3, 1, [1]),
    (296, 3, 1, [2]),
  ]
  if predictor {
    entries.push((317, 3, 1, [2]))
  }
  if !all_opaque {
    entries.push((338, 3, 1, [2]))
  }
  let extra = Buffer()
  let extra_base = ifd + 2 + entries.length() * 12 + 4
  tiff_put16(out, entries.length())
  for e in entries {
    let (tag, typ, count, vals) = e
    tiff_put16(out, tag)
    tiff_put16(out, typ)
    tiff_put32(out, count)
    let size = match typ {
      3 => 2 * count
      5 => 8 * count
      _ => 4 * count
    }
    let target = if size <= 4 { Buffer() } else { extra }
    for v in vals {
      if typ == 3 {
        tiff_put16(target, v)
      } else {
        tiff_put32(target, v)
      }
    }
    if size <= 4 {
      let b = target.to_bytes()
      out.write_bytes(b)
      for _ in b.length()..<4 {
        out.write_byte(b'\x00')
      }
    } else {
      tiff_put32(out, extra_base + extra.length() - size)
    }
  }
  tiff_put32(out, 0) // no next IFD
  out.write_bytes(extra.to_bytes())
  out.to_bytes()
}
