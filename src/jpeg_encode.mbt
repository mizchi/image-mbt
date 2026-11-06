///|
priv struct JpegBitWriter {
  buf : Array[Byte]
  mut bit_buf : Int32
  mut bits_count : Int32
}

///|
fn JpegBitWriter::new() -> JpegBitWriter {
  { buf: [], bit_buf: 0, bits_count: 0, }
}

///|
fn JpegBitWriter::write_byte(self : JpegBitWriter, value : Int32) -> Unit {
  let b = value & 0xFF
  self.buf.push(b.to_byte())
  if b == 0xFF {
    self.buf.push(b'\x00')
  }
}

///|
fn JpegBitWriter::write_bits(
  self : JpegBitWriter,
  value : Int32,
  count : Int32,
) -> Unit {
  if count <= 0 {
    return
  }
  let masked = value & ((1 << count) - 1)
  self.bit_buf = (self.bit_buf << count) | masked
  self.bits_count += count
  while self.bits_count >= 8 {
    let shift = self.bits_count - 8
    let out = (self.bit_buf >> shift) & 0xFF
    self.write_byte(out)
    self.bits_count -= 8
    if self.bits_count == 0 {
      self.bit_buf = 0
    } else {
      self.bit_buf = self.bit_buf & ((1 << self.bits_count) - 1)
    }
  }
}

///|
fn JpegBitWriter::flush(self : JpegBitWriter) -> Unit {
  if self.bits_count > 0 {
    let pad_len = 8 - self.bits_count
    let padded = (self.bit_buf << pad_len) | ((1 << pad_len) - 1)
    self.write_byte(padded)
    self.bit_buf = 0
    self.bits_count = 0
  }
}

///|
fn JpegBitWriter::to_bytes(self : JpegBitWriter) -> Bytes {
  let out = FixedArray::make(self.buf.length(), b'\x00')
  for i in 0..<self.buf.length() {
    out[i] = self.buf[i]
  }
  Bytes::from_array(out)
}

///|
priv struct HuffmanEncodeTable {
  codes : FixedArray[Int32]
  lengths : FixedArray[Int32]
}

///|
fn build_huffman_encode_table(
  bits : FixedArray[Int32],
  vals : FixedArray[Int32],
) -> HuffmanEncodeTable {
  let codes = FixedArray::make(256, 0)
  let lengths = FixedArray::make(256, 0)
  let mut code = 0
  let mut vi = 0
  for length in 1..<=16 {
    let count = bits[length]
    for _ in 0..<count {
      let symbol = vals[vi]
      codes[symbol] = code
      lengths[symbol] = length
      code += 1
      vi += 1
    }
    code = code << 1
  }
  { codes, lengths, }
}

///|
/// Optimal Huffman table for symbol frequencies `freq` (256 entries), like
/// libjpeg's jpeg_gen_optimal_table: a pseudo-symbol 256 keeps any code
/// from being all ones, ties pick the larger symbol, and lengths are
/// limited to 16 bits. Returns (bits[0..16], values).
fn jpeg_gen_optimal_table(
  counts : FixedArray[Int32],
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let freq = FixedArray::make(257, 0)
  for i in 0..<256 {
    freq[i] = counts[i]
  }
  freq[256] = 1
  let codesize = FixedArray::make(257, 0)
  let others = FixedArray::make(257, -1)
  while true {
    let mut c1 = -1
    let mut v = 1000000000
    for i in 0..<=256 {
      if freq[i] != 0 && freq[i] <= v {
        v = freq[i]
        c1 = i
      }
    }
    let mut c2 = -1
    v = 1000000000
    for i in 0..<=256 {
      if freq[i] != 0 && freq[i] <= v && i != c1 {
        v = freq[i]
        c2 = i
      }
    }
    if c2 < 0 {
      break
    }
    freq[c1] += freq[c2]
    freq[c2] = 0
    codesize[c1] += 1
    while others[c1] >= 0 {
      c1 = others[c1]
      codesize[c1] += 1
    }
    others[c1] = c2
    codesize[c2] += 1
    while others[c2] >= 0 {
      c2 = others[c2]
      codesize[c2] += 1
    }
  }
  let bits = FixedArray::make(33, 0)
  for i in 0..<=256 {
    if codesize[i] > 0 {
      bits[codesize[i]] += 1
    }
  }
  // Limit code lengths to 16 bits (JPEG Annex K.3).
  for i = 32; i > 16; i = i - 1 {
    while bits[i] > 0 {
      let mut j = i - 2
      while bits[j] == 0 {
        j -= 1
      }
      bits[i] -= 2
      bits[i - 1] += 1
      bits[j + 1] += 2
      bits[j] -= 1
    }
  }
  // Remove the pseudo-symbol 256 from the longest codes.
  let mut i = 16
  while bits[i] == 0 {
    i -= 1
  }
  bits[i] -= 1
  let vals : Array[Int32] = []
  for len in 1..<=32 {
    for sym in 0..<256 {
      if codesize[sym] == len {
        vals.push(sym)
      }
    }
  }
  (FixedArray::makei(17, fn(k) { bits[k] }), FixedArray::from_array(vals))
}

///|
// Annex K.3
let jpeg_huff_bits_dc_luma : FixedArray[Int32] = [
  0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
]

///|
// Annex K.4
let jpeg_huff_bits_dc_chroma : FixedArray[Int32] = [
  0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0,
]

///|
// Annex K.5
let jpeg_huff_bits_ac_luma : FixedArray[Int32] = [
  0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7D,
]

///|
// Annex K.6
let jpeg_huff_bits_ac_chroma : FixedArray[Int32] = [
  0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77,
]

///|
let jpeg_huff_vals_dc_luma : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
]

///|
let jpeg_huff_vals_dc_chroma : FixedArray[Int32] = [
  0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11,
]

///|
let jpeg_huff_vals_ac_luma : FixedArray[Int32] = [
  0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51,
  0x61, 0x07, 0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xA1, 0x08, 0x23, 0x42, 0xB1, 0xC1,
  0x15, 0x52, 0xD1, 0xF0, 0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0A, 0x16, 0x17, 0x18,
  0x19, 0x1A, 0x25, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
  0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56, 0x57,
  0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74, 0x75,
  0x76, 0x77, 0x78, 0x79, 0x7A, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89, 0x8A, 0x92,
  0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5, 0xA6, 0xA7,
  0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xC2, 0xC3,
  0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6, 0xD7, 0xD8,
  0xD9, 0xDA, 0xE1, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF1, 0xF2,
  0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
]

///|
let jpeg_huff_vals_ac_chroma : FixedArray[Int32] = [
  0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07,
  0x61, 0x71, 0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xA1, 0xB1, 0xC1, 0x09,
  0x23, 0x33, 0x52, 0xF0, 0x15, 0x62, 0x72, 0xD1, 0x0A, 0x16, 0x24, 0x34, 0xE1, 0x25,
  0xF1, 0x17, 0x18, 0x19, 0x1A, 0x26, 0x27, 0x28, 0x29, 0x2A, 0x35, 0x36, 0x37, 0x38,
  0x39, 0x3A, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49, 0x4A, 0x53, 0x54, 0x55, 0x56,
  0x57, 0x58, 0x59, 0x5A, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69, 0x6A, 0x73, 0x74,
  0x75, 0x76, 0x77, 0x78, 0x79, 0x7A, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
  0x8A, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9A, 0xA2, 0xA3, 0xA4, 0xA5,
  0xA6, 0xA7, 0xA8, 0xA9, 0xAA, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA,
  0xC2, 0xC3, 0xC4, 0xC5, 0xC6, 0xC7, 0xC8, 0xC9, 0xCA, 0xD2, 0xD3, 0xD4, 0xD5, 0xD6,
  0xD7, 0xD8, 0xD9, 0xDA, 0xE2, 0xE3, 0xE4, 0xE5, 0xE6, 0xE7, 0xE8, 0xE9, 0xEA, 0xF2,
  0xF3, 0xF4, 0xF5, 0xF6, 0xF7, 0xF8, 0xF9, 0xFA,
]

///|
fn write_u16be(buf : FixedArray[Byte], offset : Int32, value : Int32) -> Unit {
  buf[offset] = ((value >> 8) & 0xFF).to_byte()
  buf[offset + 1] = (value & 0xFF).to_byte()
}

///|
fn jpeg_scale_quant_table(
  base : FixedArray[Int32],
  quality : Int32,
) -> FixedArray[Int32] {
  let q = quality.clamp(min=1, max=100)
  let scale = if q < 50 { 5000 / q } else { 200 - 2 * q }
  let out = FixedArray::make(64, 0)
  for i in 0..<64 {
    let v = (base[i] * scale + 50) / 100
    out[i] = v.clamp(min=1, max=255)
  }
  out
}

///|
fn jpeg_bit_category(value : Int32) -> Int32 {
  if value == 0 {
    return 0
  }
  let mut v = if value < 0 { -value } else { value }
  let mut cat = 0
  while v > 0 {
    cat += 1
    v = v >> 1
  }
  cat
}

///|
fn jpeg_bit_payload(value : Int32, category : Int32) -> Int32 {
  if category == 0 {
    0
  } else if value >= 0 {
    value
  } else {
    value - 1 + (1 << category)
  }
}

///|
fn encode_dc(
  bw : JpegBitWriter,
  diff : Int32,
  table : HuffmanEncodeTable,
) -> Unit {
  let cat = jpeg_bit_category(diff)
  bw.write_bits(table.codes[cat], table.lengths[cat])
  if cat > 0 {
    bw.write_bits(jpeg_bit_payload(diff, cat), cat)
  }
}

///|
/// Count the AC symbols `encode_ac` would emit for `coeffs`.
fn jpeg_count_ac(
  coeffs : FixedArray[Int32],
  counts : FixedArray[Int32],
) -> Unit {
  let mut run = 0
  for i in 1..<64 {
    let v = coeffs[i]
    if v == 0 {
      run += 1
    } else {
      while run > 15 {
        counts[0xF0] += 1
        run -= 16
      }
      counts[(run << 4) | jpeg_bit_category(v)] += 1
      run = 0
    }
  }
  if run > 0 {
    counts[0] += 1
  }
}

///|
fn encode_ac(
  bw : JpegBitWriter,
  coeffs : FixedArray[Int32],
  table : HuffmanEncodeTable,
) -> Unit {
  // Like libjpeg's encode_one_block: ZRL (16 zeros) is only emitted when a
  // nonzero coefficient follows; trailing zeros are a single EOB.
  let mut run = 0
  for i in 1..<64 {
    let v = coeffs[i]
    if v == 0 {
      run += 1
    } else {
      while run > 15 {
        bw.write_bits(table.codes[0xF0], table.lengths[0xF0])
        run -= 16
      }
      let cat = jpeg_bit_category(v)
      let symbol = (run << 4) | cat
      bw.write_bits(table.codes[symbol], table.lengths[symbol])
      bw.write_bits(jpeg_bit_payload(v, cat), cat)
      run = 0
    }
  }
  if run > 0 {
    // EOB
    bw.write_bits(table.codes[0], table.lengths[0])
  }
}

///|
fn jpeg_marker_soi() -> Bytes {
  Bytes::from_array([b'\xFF', b'\xD8'])
}

///|
fn jpeg_marker_app0() -> Bytes {
  let buf = FixedArray::make(18, b'\x00')
  buf[0] = b'\xFF'
  buf[1] = b'\xE0'
  write_u16be(buf, 2, 16)
  buf[4] = b'\x4A' // J
  buf[5] = b'\x46' // F
  buf[6] = b'\x49' // I
  buf[7] = b'\x46' // F
  buf[8] = b'\x00'
  buf[9] = b'\x01' // version major
  buf[10] = b'\x01' // version minor
  buf[11] = b'\x00' // units
  write_u16be(buf, 12, 1) // X density
  write_u16be(buf, 14, 1) // Y density
  buf[16] = b'\x00' // thumbnail width
  buf[17] = b'\x00' // thumbnail height
  Bytes::from_array(buf)
}

///|
fn jpeg_marker_dqt(id : Int32, quant : FixedArray[Int32]) -> Bytes {
  let buf = FixedArray::make(69, b'\x00')
  buf[0] = b'\xFF'
  buf[1] = b'\xDB'
  write_u16be(buf, 2, 67)
  buf[4] = id.to_byte() // 8-bit precision + table id
  for i in 0..<64 {
    buf[5 + i] = quant[jpeg_zigzag[i]].to_byte()
  }
  Bytes::from_array(buf)
}

///|
fn jpeg_marker_sof0(
  width : Int32,
  height : Int32,
  luma_sampling : Int32,
) -> Bytes {
  let buf = FixedArray::make(19, b'\x00')
  buf[0] = b'\xFF'
  buf[1] = b'\xC0'
  write_u16be(buf, 2, 17)
  buf[4] = b'\x08' // precision
  write_u16be(buf, 5, height)
  write_u16be(buf, 7, width)
  buf[9] = b'\x03' // components
  // Y
  buf[10] = b'\x01'
  buf[11] = luma_sampling.to_byte()
  buf[12] = b'\x00'
  // Cb
  buf[13] = b'\x02'
  buf[14] = b'\x11'
  buf[15] = b'\x01'
  // Cr
  buf[16] = b'\x03'
  buf[17] = b'\x11'
  buf[18] = b'\x01'
  Bytes::from_array(buf)
}

///|
fn jpeg_marker_dht(
  class : Int32,
  id : Int32,
  bits : FixedArray[Int32],
  vals : FixedArray[Int32],
) -> Bytes {
  let payload_len = 1 + 16 + vals.length()
  let seg_len = payload_len + 2
  let buf = FixedArray::make(seg_len + 2, b'\x00')
  buf[0] = b'\xFF'
  buf[1] = b'\xC4'
  write_u16be(buf, 2, seg_len)
  buf[4] = ((class << 4) | id).to_byte()
  for i in 0..<16 {
    buf[5 + i] = bits[i + 1].to_byte()
  }
  for i in 0..<vals.length() {
    buf[21 + i] = vals[i].to_byte()
  }
  Bytes::from_array(buf)
}

///|
fn jpeg_marker_sos() -> Bytes {
  let buf = FixedArray::make(14, b'\x00')
  buf[0] = b'\xFF'
  buf[1] = b'\xDA'
  write_u16be(buf, 2, 12)
  buf[4] = b'\x03' // components
  // Y uses DC0 / AC0
  buf[5] = b'\x01'
  buf[6] = b'\x00'
  // Cb uses DC1 / AC1
  buf[7] = b'\x02'
  buf[8] = b'\x11'
  // Cr uses DC1 / AC1
  buf[9] = b'\x03'
  buf[10] = b'\x11'
  buf[11] = b'\x00' // Ss
  buf[12] = b'\x3F' // Se
  buf[13] = b'\x00' // Ah/Al
  Bytes::from_array(buf)
}

///|
fn jpeg_marker_eoi() -> Bytes {
  Bytes::from_array([b'\xFF', b'\xD9'])
}

///|
/// Chroma subsampling for `encode_jpeg`.
pub(all) enum JpegSubsampling {
  /// No subsampling (best quality).
  Yuv444
  /// Chroma halved horizontally.
  Yuv422
  /// Chroma halved horizontally and vertically (smallest files; libjpeg's
  /// default).
  Yuv420
}

///|
/// Encode a baseline JPEG (RGB from RGBA8; alpha is ignored).
///
/// The pipeline follows libjpeg (fixed-point color conversion, libjpeg's
/// downsampling, islow integer FDCT and quantization, standard Huffman
/// tables), so for the same quality and subsampling the entropy-coded data
/// is identical to libjpeg's (e.g. Pillow with `optimize=False`).
///
/// `optimize=true` builds Huffman tables from the image's own symbol
/// statistics (two passes), like libjpeg's `optimize_coding` / Pillow's
/// `optimize=True`; tables and entropy-coded data then match those too.
pub fn encode_jpeg(
  img : ImageData,
  quality~ : Int32 = 85,
  subsampling~ : JpegSubsampling = Yuv444,
  optimize~ : Bool = false,
) -> Bytes raise EncodeError {
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
  if width > 65535 || height > 65535 {
    raise InvalidDimensions(
      "JPEG dimensions must be <= 65535: " +
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
  let (hs, vs) = match subsampling {
    Yuv444 => (1, 1)
    Yuv422 => (2, 1)
    Yuv420 => (2, 2)
  }
  let q = quality.clamp(min=1, max=100)
  let quant_luma = jpeg_scale_quant_table(jpeg_std_lum_quant, q)
  let quant_chroma = jpeg_scale_quant_table(jpeg_std_chrom_quant, q)
  let div_luma = JpegQuantDivisors::new(quant_luma)
  let div_chroma = JpegQuantDivisors::new(quant_chroma)
  // Color conversion and downsampling. Luma covers ceil(W/8) x ceil(H/8)
  // blocks; chroma covers one block per MCU.
  let mcu_cols = (width + 8 * hs - 1) / (8 * hs)
  let mcu_rows = (height + 8 * vs - 1) / (8 * vs)
  let (yp, cbp, crp) = jpeg_rgb_to_ycc(img.data, width * height)
  let y_bw = (width + 7) / 8
  let y_bh = (height + 7) / 8
  let y_plane = jpeg_downsample(yp, width, height, 1, 1, y_bw * 8, y_bh * 8)
  let c_stride = mcu_cols * 8
  let cb_plane = jpeg_downsample(
    cbp,
    width,
    height,
    hs,
    vs,
    c_stride,
    mcu_rows * 8,
  )
  let cr_plane = jpeg_downsample(
    crp,
    width,
    height,
    hs,
    vs,
    c_stride,
    mcu_rows * 8,
  )
  let work = FixedArray::make(64, 0)
  let coefs = FixedArray::make(64, 0)
  // Run the block pipeline in MCU order, calling `emit(coefs, dc_diff,
  // table)` for each block (table 0 = luma, 1 = chroma). Blocks outside a
  // component are dummy blocks (zero AC, DC = previous DC), like jccoefct.c.
  let run_blocks = fn(emit : (FixedArray[Int32], Int32, Int32) -> Unit) {
    let prev_dc = FixedArray::make(3, 0)
    let block = fn(
      plane : FixedArray[Int32],
      stride : Int32,
      bx : Int32,
      by : Int32,
      real : Bool,
      quant : JpegQuantDivisors,
      ci : Int32,
    ) {
      if real {
        for yy in 0..<8 {
          let row = (by * 8 + yy) * stride + bx * 8
          for xx in 0..<8 {
            work[yy * 8 + xx] = plane[row + xx] - 128
          }
        }
        jpeg_fdct(work)
        jpeg_quantize(work, quant, coefs)
      } else {
        let dc = prev_dc[ci]
        coefs.fill(0)
        coefs[0] = dc
      }
      emit(coefs, coefs[0] - prev_dc[ci], if ci == 0 { 0 } else { 1 })
      prev_dc[ci] = coefs[0]
    }
    for my in 0..<mcu_rows {
      for mx in 0..<mcu_cols {
        for v in 0..<vs {
          for h in 0..<hs {
            let bx = mx * hs + h
            let by = my * vs + v
            block(
              y_plane,
              y_bw * 8,
              bx,
              by,
              bx < y_bw && by < y_bh,
              div_luma,
              0,
            )
          }
        }
        block(cb_plane, c_stride, mx, my, true, div_chroma, 1)
        block(cr_plane, c_stride, mx, my, true, div_chroma, 2)
      }
    }
  }
  // Huffman tables: the standard ones, or (optimize) tables built from the
  // symbol statistics of a first pass, like libjpeg's optimize_coding.
  let (dc_specs, ac_specs) = if optimize {
    let dc_counts = [FixedArray::make(256, 0), FixedArray::make(256, 0)]
    let ac_counts = [FixedArray::make(256, 0), FixedArray::make(256, 0)]
    run_blocks(fn(c, diff, t) {
      dc_counts[t][jpeg_bit_category(diff)] += 1
      jpeg_count_ac(c, ac_counts[t])
    })
    (
      [
        jpeg_gen_optimal_table(dc_counts[0]),
        jpeg_gen_optimal_table(dc_counts[1]),
      ],
      [
        jpeg_gen_optimal_table(ac_counts[0]),
        jpeg_gen_optimal_table(ac_counts[1]),
      ],
    )
  } else {
    (
      [
        (jpeg_huff_bits_dc_luma, jpeg_huff_vals_dc_luma),
        (jpeg_huff_bits_dc_chroma, jpeg_huff_vals_dc_chroma),
      ],
      [
        (jpeg_huff_bits_ac_luma, jpeg_huff_vals_ac_luma),
        (jpeg_huff_bits_ac_chroma, jpeg_huff_vals_ac_chroma),
      ],
    )
  }
  let dc_tables = dc_specs.map(fn(t) { build_huffman_encode_table(t.0, t.1) })
  let ac_tables = ac_specs.map(fn(t) { build_huffman_encode_table(t.0, t.1) })
  let parts : Array[Bytes] = []
  parts.push(jpeg_marker_soi())
  parts.push(jpeg_marker_app0())
  parts.push(jpeg_marker_dqt(0, quant_luma))
  parts.push(jpeg_marker_dqt(1, quant_chroma))
  parts.push(jpeg_marker_sof0(width, height, (hs << 4) | vs))
  // Same order as libjpeg's scan header: DC0, AC0, DC1, AC1.
  for t in 0..<2 {
    parts.push(jpeg_marker_dht(0, t, dc_specs[t].0, dc_specs[t].1))
    parts.push(jpeg_marker_dht(1, t, ac_specs[t].0, ac_specs[t].1))
  }
  parts.push(jpeg_marker_sos())
  let bw = JpegBitWriter::new()
  run_blocks(fn(c, diff, t) {
    encode_dc(bw, diff, dc_tables[t])
    encode_ac(bw, c, ac_tables[t])
  })
  bw.flush()
  parts.push(bw.to_bytes())
  parts.push(jpeg_marker_eoi())
  let mut total_len = 0
  for p in parts {
    total_len += p.length()
  }
  let out = FixedArray::make(total_len, b'\x00')
  let mut pos = 0
  for p in parts {
    out.blit_from_bytes(pos, p, 0, p.length())
    pos += p.length()
  }
  Bytes::from_array(out)
}
