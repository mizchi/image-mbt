///|
// JPEG Huffman decoder: SOF0 baseline, SOF1 extended sequential and SOF2
// progressive (8-bit). Supports grayscale and YCbCr, any h/v sampling,
// multiple scans and restart intervals (DRI/RST).

///|
/// Entropy-coded data reader with a 32-bit lookahead buffer.
///
/// Bytes are unstuffed (0xFF 0x00 -> 0xFF) as they are loaded. At a marker
/// or the end of the data the buffer is padded with zero bytes without
/// consuming anything, so `pos` never moves past a marker; consuming any of
/// those padding bits means the data is truncated or corrupt.
priv struct JpegBitReader {
  data : Bytes
  mut pos : Int32
  mut bit_buf : UInt32
  /// Valid bits in `bit_buf` (the low `bits_left` bits, MSB first).
  mut bits_left : Int32
  /// How many of the low bits of the buffer are zero padding.
  mut pad_bits : Int32
}

///|
fn JpegBitReader::new(data : Bytes, pos : Int32) -> JpegBitReader {
  { data, pos, bit_buf: 0, bits_left: 0, pad_bits: 0, }
}

///|
/// Top up the buffer to at least 25 bits.
fn JpegBitReader::fill(self : JpegBitReader) -> Unit {
  let data = self.data
  while self.bits_left <= 24 {
    let mut b = 0
    if self.pad_bits > 0 || self.pos >= data.length() {
      self.pad_bits += 8
    } else {
      b = data[self.pos].to_int()
      if b == 0xFF {
        if self.pos + 1 < data.length() && data[self.pos + 1].to_int() == 0 {
          self.pos += 2
        } else {
          // A marker: stop here and pad.
          b = 0
          self.pad_bits += 8
        }
      } else {
        self.pos += 1
      }
    }
    self.bit_buf = (self.bit_buf << 8) | b.reinterpret_as_uint()
    self.bits_left += 8
  }
}

///|
/// The next `count` (<= 16) bits without consuming them.
fn JpegBitReader::peek(self : JpegBitReader, count : Int32) -> Int32 {
  if self.bits_left < count {
    self.fill()
  }
  ((self.bit_buf >> (self.bits_left - count)) & ((1U << count) - 1)).reinterpret_as_int()
}

///|
fn JpegBitReader::skip(
  self : JpegBitReader,
  count : Int32,
) -> Unit raise DecodeError {
  if self.bits_left - count < self.pad_bits {
    raise CorruptData("unexpected end of JPEG data")
  }
  self.bits_left -= count
}

///|
fn JpegBitReader::read_bits(
  self : JpegBitReader,
  count : Int32,
) -> Int32 raise DecodeError {
  if count == 0 {
    return 0
  }
  let v = self.peek(count)
  self.skip(count)
  v
}

///|
/// Handle a restart marker: drop the remaining (padding) bits of the
/// current byte and consume the next `RSTn` marker. Fill bytes (0xFF) before
/// the marker are skipped.
fn JpegBitReader::restart(self : JpegBitReader) -> Unit raise DecodeError {
  self.bit_buf = 0
  self.bits_left = 0
  self.pad_bits = 0
  let data = self.data
  while self.pos + 1 < data.length() &&
        data[self.pos].to_int() == 0xFF &&
        data[self.pos + 1].to_int() == 0xFF {
    self.pos += 1
  }
  if self.pos + 1 >= data.length() ||
    data[self.pos].to_int() != 0xFF ||
    data[self.pos + 1].to_int() < 0xD0 ||
    data[self.pos + 1].to_int() > 0xD7 {
    raise CorruptData("expected RST marker at byte " + self.pos.to_string())
  }
  self.pos += 2
}

///|
fn JpegBitReader::read_bit(self : JpegBitReader) -> Int32 raise DecodeError {
  self.read_bits(1)
}

///|
/// Bits resolved by the Huffman lookup table.
const HUFF_LOOKUP_BITS : Int32 = 9

///|
priv struct HuffmanTable {
  // For each code length 1..16, store the symbols
  min_code : FixedArray[Int32] // min code value at each length
  max_code : FixedArray[Int32] // max code value at each length (-1 if none)
  val_ptr : FixedArray[Int32] // index into values for each length
  values : Array[Int32]
  /// Indexed by the next HUFF_LOOKUP_BITS bits: (length << 8) | symbol for
  /// codes of at most that length, 0 otherwise.
  lookup : FixedArray[Int32]
}

///|
fn build_huffman_table(
  bits : FixedArray[Int32],
  values : Array[Int32],
) -> HuffmanTable {
  let min_code = FixedArray::make(17, 0)
  let max_code = FixedArray::make(17, -1)
  let val_ptr = FixedArray::make(17, 0)
  let lookup = FixedArray::make(1 << HUFF_LOOKUP_BITS, 0)
  let mut code = 0
  let mut vi = 0
  for length in 1..<=16 {
    val_ptr[length] = vi
    if bits[length] > 0 {
      min_code[length] = code
      if length <= HUFF_LOOKUP_BITS {
        let shift = HUFF_LOOKUP_BITS - length
        for i in 0..<bits[length] {
          let start = (code + i) << shift
          let end = start + (1 << shift)
          // Over-subscribed (invalid) tables may run past the table.
          if end <= lookup.length() && vi + i < values.length() {
            for j in start..<end {
              lookup[j] = (length << 8) | values[vi + i]
            }
          }
        }
      }
      code += bits[length]
      max_code[length] = code - 1
      vi += bits[length]
    }
    code = code << 1
  }
  { min_code, max_code, val_ptr, values, lookup, }
}

///|
fn decode_huffman(
  br : JpegBitReader,
  table : HuffmanTable,
) -> Int32 raise DecodeError {
  let e = table.lookup[br.peek(HUFF_LOOKUP_BITS)]
  if e != 0 {
    br.skip(e >> 8)
    return e & 0xFF
  }
  // Longer codes: compare against the canonical code ranges.
  let bits16 = br.peek(16)
  for length in (HUFF_LOOKUP_BITS + 1)..<=16 {
    let code = bits16 >> (16 - length)
    if table.max_code[length] >= 0 && code <= table.max_code[length] {
      br.skip(length)
      return table.values[table.val_ptr[length] + code - table.min_code[length]]
    }
  }
  raise CorruptData("invalid Huffman code")
}

///|
fn receive_extend(br : JpegBitReader, nbits : Int32) -> Int32 raise DecodeError {
  if nbits == 0 {
    return 0
  }
  if nbits > 16 {
    raise CorruptData("invalid JPEG coefficient size: " + nbits.to_string())
  }
  let value = br.read_bits(nbits)
  if value < 1 << (nbits - 1) {
    // negative
    value - (1 << nbits) + 1
  } else {
    value
  }
}

///|
/// Name of a SOF marker this decoder does not handle, if `marker` is one.
fn jpeg_unsupported_sof(marker : Int32) -> String? {
  match marker {
    0xC3 => Some("lossless")
    0xC5 | 0xC6 | 0xC7 => Some("hierarchical")
    0xC9 | 0xCA | 0xCB | 0xCD | 0xCE | 0xCF => Some("arithmetic-coded")
    _ => None
  }
}

///|
// Pre-computed IDCT cosine table: cos((2*n+1)*k*PI/16) for n,k in 0..7
// idct_cos_table[n * 8 + k] = cos((2*n+1)*k*PI/16)
let idct_cos_table : FixedArray[Double] = {
  let t = FixedArray::make(64, 0.0)
  for n in 0..<8 {
    for k in 0..<8 {
      t[n * 8 + k] = @math.cos(
        (2.0 * n.to_double() + 1.0) * k.to_double() * @math.PI / 16.0,
      )
    }
  }
  t
}

///|
// C(k) scaling factor: 1/sqrt(2) for k=0, 1.0 otherwise
let idct_c : FixedArray[Double] = {
  let c = FixedArray::make(8, 1.0)
  c[0] = 1.0 / 2.0.sqrt()
  c
}

///|
priv struct JpegComponent {
  id : Int32
  h_sample : Int32
  v_sample : Int32
  quant_id : Int32
}

///|
priv struct JpegFrameInfo {
  width : Int32
  height : Int32
  components : Array[JpegComponent]
  max_h : Int32
  max_v : Int32
}

///|
priv struct JpegScanComponent {
  comp_idx : Int32
  dc_table_id : Int32
  ac_table_id : Int32
}

///|
fn read_u16be_at(data : Bytes, pos : Int32) -> Int32 {
  ((data[pos].to_int() & 0xFF) << 8) | (data[pos + 1].to_int() & 0xFF)
}

///|
priv struct JpegScan {
  components : Array[JpegScanComponent]
  // Spectral selection and successive approximation (progressive only;
  // sequential scans use ss = 0, se = 63, ah = al = 0).
  ss : Int32
  se : Int32
  ah : Int32
  al : Int32
}

///|
/// Decoder state shared by all scans of a frame.
priv struct JpegState {
  fi : JpegFrameInfo
  progressive : Bool
  mcu_cols : Int32
  mcu_rows : Int32
  /// Decoded samples per component (stride = blocks_w * 8).
  comp_bufs : Array[FixedArray[Int32]]
  /// Progressive only: quantized coefficients per component, 64 per block
  /// in zigzag order, accumulated over all scans.
  coefs : Array[FixedArray[Int32]]
  /// Blocks per row of each component buffer (mcu_cols * h).
  blocks_w : FixedArray[Int32]
  prev_dc : FixedArray[Int32]
  mut eobrun : Int32
  /// Scratch buffers for sequential decoding.
  block : FixedArray[Int32]
  idct_out : FixedArray[Int32]
}

///|
fn JpegState::new(fi : JpegFrameInfo, progressive : Bool) -> JpegState {
  let mcu_cols = (fi.width + fi.max_h * 8 - 1) / (fi.max_h * 8)
  let mcu_rows = (fi.height + fi.max_v * 8 - 1) / (fi.max_v * 8)
  let ncomp = fi.components.length()
  let blocks_w = FixedArray::makei(ncomp, fn(i) {
    mcu_cols * fi.components[i].h_sample
  })
  let comp_bufs = Array::makei(ncomp, fn(i) {
    let c = fi.components[i]
    FixedArray::make(blocks_w[i] * 8 * mcu_rows * c.v_sample * 8, 128)
  })
  let coefs = if progressive {
    Array::makei(ncomp, fn(i) {
      FixedArray::make(
        blocks_w[i] * mcu_rows * fi.components[i].v_sample * 64,
        0,
      )
    })
  } else {
    []
  }
  {
    fi,
    progressive,
    mcu_cols,
    mcu_rows,
    comp_bufs,
    coefs,
    blocks_w,
    prev_dc: FixedArray::make(ncomp, 0),
    eobrun: 0,
    block: FixedArray::make(64, 0),
    idct_out: FixedArray::make(64, 0),
  }
}

///|
/// Dequantize + IDCT `block` (natural order, already dequantized) into the
/// sample buffer of component `ci` at block (bx, by).
fn JpegState::write_block(
  self : JpegState,
  ci : Int32,
  bx : Int32,
  by : Int32,
) -> Unit {
  let stride = self.blocks_w[ci] * 8
  jpeg_idct(
    self.block,
    self.idct_out,
    self.comp_bufs[ci],
    by * 8 * stride + bx * 8,
    stride,
  )
}

///|
/// Sequential: decode one complete block, dequantize, IDCT and store it.
fn JpegState::decode_block_sequential(
  self : JpegState,
  br : JpegBitReader,
  ci : Int32,
  bx : Int32,
  by : Int32,
  dc_tab : HuffmanTable,
  ac_tab : HuffmanTable,
  qt : FixedArray[Int32],
) -> Unit raise DecodeError {
  let block = self.block
  let dc_cat = decode_huffman(br, dc_tab)
  self.prev_dc[ci] += receive_extend(br, dc_cat)
  block.fill(0)
  block[0] = self.prev_dc[ci] * qt[0]
  let mut k = 1
  while k < 64 {
    let rs = decode_huffman(br, ac_tab)
    let run = rs >> 4
    let size = rs & 0x0F
    if size == 0 {
      if run == 0x0F {
        k += 16
        continue
      }
      break // EOB
    }
    k += run
    if k >= 64 {
      break
    }
    block[jpeg_zigzag[k]] = receive_extend(br, size) * qt[jpeg_zigzag[k]]
    k += 1
  }
  self.write_block(ci, bx, by)
}

///|
/// Progressive DC scan for one block (first pass or refinement).
fn JpegState::decode_dc_progressive(
  self : JpegState,
  br : JpegBitReader,
  ci : Int32,
  off : Int32,
  scan : JpegScan,
  dc_tab : HuffmanTable?,
) -> Unit raise DecodeError {
  let coef = self.coefs[ci]
  if scan.ah == 0 {
    let tab = match dc_tab {
      Some(t) => t
      None => raise MissingChunk("DC Huffman table")
    }
    let t = decode_huffman(br, tab)
    self.prev_dc[ci] += receive_extend(br, t)
    coef[off] = self.prev_dc[ci] * (1 << scan.al)
  } else if br.read_bit() == 1 {
    coef[off] = coef[off] | (1 << scan.al)
  }
}

///|
/// Progressive AC first pass (spectral band ss..se) for one block.
fn JpegState::decode_ac_first(
  self : JpegState,
  br : JpegBitReader,
  coef : FixedArray[Int32],
  off : Int32,
  scan : JpegScan,
  ac_tab : HuffmanTable,
) -> Unit raise DecodeError {
  if self.eobrun > 0 {
    self.eobrun -= 1
    return
  }
  let mut k = scan.ss
  while k <= scan.se {
    let rs = decode_huffman(br, ac_tab)
    let r = rs >> 4
    let s = rs & 0x0F
    if s == 0 {
      if r < 15 {
        // EOBn: this block and the next 2^r + bits - 1 blocks end here.
        self.eobrun = (1 << r) - 1
        if r > 0 {
          self.eobrun += br.read_bits(r)
        }
        break
      }
      k += 16 // ZRL
      continue
    }
    k += r
    if k > 63 {
      raise CorruptData("JPEG AC coefficient index out of range")
    }
    coef[off + k] = receive_extend(br, s) * (1 << scan.al)
    k += 1
  }
}

///|
/// Progressive AC refinement pass for one block (ITU T.81 G.1.2.3; same
/// structure as libjpeg's decode_mcu_AC_refine).
fn JpegState::decode_ac_refine(
  self : JpegState,
  br : JpegBitReader,
  coef : FixedArray[Int32],
  off : Int32,
  scan : JpegScan,
  ac_tab : HuffmanTable,
) -> Unit raise DecodeError {
  let p1 = 1 << scan.al
  let m1 = -1 << scan.al
  let se = scan.se
  // Append a correction bit to an already-nonzero coefficient.
  let refine = fn(i : Int32) raise DecodeError {
    if br.read_bit() == 1 && (coef[i] & p1) == 0 {
      coef[i] = coef[i] + (if coef[i] >= 0 { p1 } else { m1 })
    }
  }
  let mut k = scan.ss
  if self.eobrun == 0 {
    while k <= se {
      let rs = decode_huffman(br, ac_tab)
      let mut r = rs >> 4
      let s = rs & 0x0F
      let mut value = 0
      if s != 0 {
        if s != 1 {
          raise CorruptData("JPEG AC refinement with magnitude > 1")
        }
        value = if br.read_bit() == 1 { p1 } else { m1 }
      } else if r != 15 {
        self.eobrun = 1 << r
        if r > 0 {
          self.eobrun += br.read_bits(r)
        }
        break // the rest of the block is handled by the EOB run below
      }
      // Skip r zero coefficients (refining nonzero ones on the way), then
      // place `value` at the next zero coefficient.
      while k <= se {
        if coef[off + k] != 0 {
          refine(off + k)
        } else {
          if r == 0 {
            if value != 0 {
              coef[off + k] = value
            }
            break
          }
          r -= 1
        }
        k += 1
      }
      k += 1
    }
  }
  if self.eobrun > 0 {
    while k <= se {
      if coef[off + k] != 0 {
        refine(off + k)
      }
      k += 1
    }
    self.eobrun -= 1
  }
}

///|
/// Decode one scan whose entropy-coded data starts at `start`. Returns the
/// position where the bit reader stopped.
fn JpegState::decode_scan(
  self : JpegState,
  data : Bytes,
  start : Int32,
  scan : JpegScan,
  dc_tables : FixedArray[HuffmanTable?],
  ac_tables : FixedArray[HuffmanTable?],
  quant_tables : FixedArray[FixedArray[Int32]?],
  restart_interval : Int32,
) -> Int32 raise DecodeError {
  let fi = self.fi
  let br = JpegBitReader::new(data, start)
  let comps = scan.components
  let ns = comps.length()
  let need_dc = !self.progressive || (scan.ss == 0 && scan.ah == 0)
  let need_ac = !self.progressive || scan.ss > 0
  let dc_tabs : Array[HuffmanTable?] = []
  let ac_tabs : Array[HuffmanTable?] = []
  for sc in comps {
    let dc = dc_tables[sc.dc_table_id]
    let ac = ac_tables[sc.ac_table_id]
    if need_dc && dc is None {
      raise MissingChunk("DC Huffman table " + sc.dc_table_id.to_string())
    }
    if need_ac && ac is None {
      raise MissingChunk("AC Huffman table " + sc.ac_table_id.to_string())
    }
    dc_tabs.push(dc)
    ac_tabs.push(ac)
  }
  let qts : Array[FixedArray[Int32]] = []
  if !self.progressive {
    for sc in comps {
      let qid = fi.components[sc.comp_idx].quant_id
      match quant_tables[qid] {
        Some(t) => qts.push(t)
        None => raise MissingChunk("quantization table " + qid.to_string())
      }
    }
  }
  let unwrap = fn(t : HuffmanTable?) -> HuffmanTable {
    match t {
      Some(t) => t
      None => panic()
    }
  }
  // One block of scan component `si` at block coords (bx, by).
  let do_block = fn(si : Int32, bx : Int32, by : Int32) raise DecodeError {
    let ci = comps[si].comp_idx
    if !self.progressive {
      self.decode_block_sequential(
        br,
        ci,
        bx,
        by,
        unwrap(dc_tabs[si]),
        unwrap(ac_tabs[si]),
        qts[si],
      )
      return
    }
    let off = (by * self.blocks_w[ci] + bx) * 64
    if scan.ss == 0 {
      self.decode_dc_progressive(br, ci, off, scan, dc_tabs[si])
    } else if scan.ah == 0 {
      self.decode_ac_first(br, self.coefs[ci], off, scan, unwrap(ac_tabs[si]))
    } else {
      self.decode_ac_refine(br, self.coefs[ci], off, scan, unwrap(ac_tabs[si]))
    }
  }
  // A scan with one component is non-interleaved: its MCU is a single
  // block, and it covers ceil(component size / 8) blocks (JPEG A.2.2).
  // Otherwise each MCU holds h x v blocks of every component (A.2.3).
  let (units_x, units_y) = if ns == 1 {
    let c = fi.components[comps[0].comp_idx]
    let comp_w = (fi.width * c.h_sample + fi.max_h - 1) / fi.max_h
    let comp_h = (fi.height * c.v_sample + fi.max_v - 1) / fi.max_v
    ((comp_w + 7) / 8, (comp_h + 7) / 8)
  } else {
    (self.mcu_cols, self.mcu_rows)
  }
  self.prev_dc.fill(0)
  self.eobrun = 0
  for unit in 0..<(units_x * units_y) {
    if restart_interval > 0 && unit > 0 && unit % restart_interval == 0 {
      br.restart()
      self.prev_dc.fill(0)
      self.eobrun = 0
    }
    let ux = unit % units_x
    let uy = unit / units_x
    if ns == 1 {
      do_block(0, ux, uy)
    } else {
      for si in 0..<ns {
        let c = fi.components[comps[si].comp_idx]
        for bv in 0..<c.v_sample {
          for bh in 0..<c.h_sample {
            do_block(si, ux * c.h_sample + bh, uy * c.v_sample + bv)
          }
        }
      }
    }
  }
  br.pos
}

///|
/// Progressive: dequantize and IDCT every accumulated block.
fn JpegState::finish_progressive(
  self : JpegState,
  quant_tables : FixedArray[FixedArray[Int32]?],
) -> Unit raise DecodeError {
  let fi = self.fi
  for ci in 0..<fi.components.length() {
    let c = fi.components[ci]
    let qt = match quant_tables[c.quant_id] {
      Some(t) => t
      None => raise MissingChunk("quantization table " + c.quant_id.to_string())
    }
    let coef = self.coefs[ci]
    let bw = self.blocks_w[ci]
    let bh = self.mcu_rows * c.v_sample
    for by in 0..<bh {
      for bx in 0..<bw {
        let off = (by * bw + bx) * 64
        for k in 0..<64 {
          let nat = jpeg_zigzag[k]
          self.block[nat] = coef[off + k] * qt[nat]
        }
        self.write_block(ci, bx, by)
      }
    }
  }
}

///|
pub fn decode_jpeg(data : Bytes) -> ImageData raise DecodeError {
  if data.length() < 2 || data[0].to_int() != 0xFF || data[1].to_int() != 0xD8 {
    raise InvalidSignature("not a JPEG file")
  }
  let mut pos = 2
  let quant_tables : FixedArray[FixedArray[Int32]?] = FixedArray::make(4, None)
  let dc_tables : FixedArray[HuffmanTable?] = FixedArray::make(4, None)
  let ac_tables : FixedArray[HuffmanTable?] = FixedArray::make(4, None)
  let mut state : JpegState? = None
  let mut scans = 0
  let mut restart_interval = 0
  // Parse markers; each SOS is decoded as soon as it is seen.
  while pos + 1 < data.length() {
    if data[pos].to_int() != 0xFF {
      pos += 1
      continue
    }
    let marker = data[pos + 1].to_int()
    pos += 2
    if marker == 0xD9 {
      // EOI
      break
    }
    if marker == 0x00 || marker == 0xFF {
      continue
    }
    if marker >= 0xD0 && marker <= 0xD7 {
      // Stray RST marker
      continue
    }
    if pos + 1 >= data.length() {
      break
    }
    let seg_len = read_u16be_at(data, pos)
    let seg_end = pos + seg_len
    if seg_len < 2 || seg_end > data.length() {
      raise CorruptData("JPEG segment extends beyond end of data")
    }
    // Every read inside a marker segment is bounds-checked against it.
    let seg_byte = fn(i : Int32) -> Int32 raise DecodeError {
      if i < pos || i >= seg_end {
        raise CorruptData("JPEG marker segment too short")
      }
      data[i].to_int()
    }
    let seg_u16 = fn(i : Int32) -> Int32 raise DecodeError {
      (seg_byte(i) << 8) | seg_byte(i + 1)
    }
    if marker == 0xDB {
      // DQT - Define Quantization Table
      let mut qpos = pos + 2
      let qend = pos + seg_len
      while qpos < qend {
        let pq_tq = seg_byte(qpos)
        let tq = pq_tq & 0x03
        let pq = pq_tq >> 4
        qpos += 1
        let qt = FixedArray::make(64, 0)
        if pq == 0 {
          // 8-bit
          for i in 0..<64 {
            qt[jpeg_zigzag[i]] = seg_byte(qpos + i)
          }
          qpos += 64
        } else {
          // 16-bit
          for i in 0..<64 {
            qt[jpeg_zigzag[i]] = seg_u16(qpos + i * 2)
          }
          qpos += 128
        }
        quant_tables[tq] = Some(qt)
      }
    } else if marker == 0xC0 || marker == 0xC1 || marker == 0xC2 {
      // SOF0 (Baseline), SOF1 (Extended sequential), SOF2 (Progressive),
      // all Huffman-coded. With 8-bit samples SOF1 decodes like SOF0.
      if state is Some(_) {
        raise CorruptData("multiple SOF markers")
      }
      let precision = seg_byte(pos + 2)
      if precision != 8 {
        raise UnsupportedFeature(
          "unsupported bit depth: " + precision.to_string(),
        )
      }
      let height = seg_u16(pos + 3)
      let width = seg_u16(pos + 5)
      let ncomp = seg_byte(pos + 7)
      if ncomp != 3 && ncomp != 1 {
        raise UnsupportedFeature(
          "unsupported component count: " + ncomp.to_string(),
        )
      }
      if width <= 0 || height <= 0 {
        raise UnsupportedFeature("JPEG without dimensions in SOF (DNL)")
      }
      check_decode_size(width, height)
      let components : Array[JpegComponent] = []
      let mut max_h = 1
      let mut max_v = 1
      for i in 0..<ncomp {
        let coff = pos + 8 + i * 3
        let id = seg_byte(coff)
        let sampling = seg_byte(coff + 1)
        let h = sampling >> 4
        let v = sampling & 0x0F
        if h < 1 || h > 4 || v < 1 || v > 4 {
          raise CorruptData("invalid JPEG sampling factors")
        }
        let qid = seg_byte(coff + 2) & 0x03
        if h > max_h {
          max_h = h
        }
        if v > max_v {
          max_v = v
        }
        components.push({ id, h_sample: h, v_sample: v, quant_id: qid, })
      }
      state = Some(
        JpegState::new(
          { width, height, components, max_h, max_v, },
          marker == 0xC2,
        ),
      )
    } else if jpeg_unsupported_sof(marker) is Some(kind) {
      raise UnsupportedFeature(kind + " JPEG not supported")
    } else if marker == 0xDD {
      // DRI - Define Restart Interval (in MCUs, 0 = disabled)
      restart_interval = seg_u16(pos + 2)
    } else if marker == 0xC4 {
      // DHT - Define Huffman Table
      let mut hpos = pos + 2
      let hend = pos + seg_len
      while hpos < hend {
        let tc_th = seg_byte(hpos)
        let tc = tc_th >> 4 // 0=DC, 1=AC
        let th = tc_th & 0x03
        hpos += 1
        let bits = FixedArray::make(17, 0)
        let mut total = 0
        for i in 1..<=16 {
          bits[i] = seg_byte(hpos + i - 1)
          total += bits[i]
        }
        hpos += 16
        let values : Array[Int32] = []
        for i in 0..<total {
          values.push(seg_byte(hpos + i))
        }
        hpos += total
        let table = build_huffman_table(bits, values)
        if tc == 0 {
          dc_tables[th] = Some(table)
        } else {
          ac_tables[th] = Some(table)
        }
      }
    } else if marker == 0xDA {
      // SOS - Start Of Scan
      let st = match state {
        Some(st) => st
        None => raise MissingChunk("SOF must precede SOS")
      }
      let fi = st.fi
      let ns = seg_byte(pos + 2)
      if ns < 1 || ns > fi.components.length() {
        raise CorruptData("invalid JPEG scan component count")
      }
      let components : Array[JpegScanComponent] = []
      for i in 0..<ns {
        let soff = pos + 3 + i * 2
        let cs = seg_byte(soff)
        let td_ta = seg_byte(soff + 1)
        let mut comp_idx = -1
        for j in 0..<fi.components.length() {
          if fi.components[j].id == cs {
            comp_idx = j
          }
        }
        if comp_idx < 0 {
          raise CorruptData("JPEG scan references unknown component")
        }
        components.push({
          comp_idx,
          dc_table_id: (td_ta >> 4) & 0x03,
          ac_table_id: td_ta & 0x03,
        })
      }
      let p = pos + 3 + ns * 2
      let scan : JpegScan = if st.progressive {
        let ss = seg_byte(p)
        let se = seg_byte(p + 1)
        let ah = seg_byte(p + 2) >> 4
        let al = seg_byte(p + 2) & 0x0F
        if ss > se || se > 63 || (ss == 0 && se != 0) || (ss > 0 && ns != 1) {
          raise CorruptData("invalid progressive JPEG scan parameters")
        }
        { components, ss, se, ah, al, }
      } else {
        { components, ss: 0, se: 63, ah: 0, al: 0, }
      }
      pos = st.decode_scan(
        data,
        pos + seg_len,
        scan,
        dc_tables,
        ac_tables,
        quant_tables,
        restart_interval,
      )
      scans += 1
      continue
    }
    pos += seg_len
  }
  let st = match state {
    Some(st) => st
    None => raise MissingChunk("SOF0/SOF1/SOF2")
  }
  if scans == 0 {
    raise MissingChunk("SOS")
  }
  if st.progressive {
    st.finish_progressive(quant_tables)
  }
  let fi = st.fi
  let mcu_cols = st.mcu_cols
  let ncomp = fi.components.length()
  let comp_bufs = st.comp_bufs
  let width = fi.width
  let height = fi.height
  // Upsample every component to full resolution.
  let planes = Array::makei(ncomp, fn(ci) {
    let c = fi.components[ci]
    jpeg_upsample(
      comp_bufs[ci],
      mcu_cols * c.h_sample * 8,
      (width * c.h_sample + fi.max_h - 1) / fi.max_h,
      (height * c.v_sample + fi.max_v - 1) / fi.max_v,
      c.h_sample,
      c.v_sample,
      fi.max_h,
      fi.max_v,
      width,
      height,
    )
  })
  let out_buf = FixedArray::make(width * height * 4, b'\xFF')
  if ncomp == 1 {
    let p = planes[0]
    for i in 0..<(width * height) {
      let v = p[i].to_byte()
      out_buf[i * 4] = v
      out_buf[i * 4 + 1] = v
      out_buf[i * 4 + 2] = v
    }
  } else {
    // YCbCr -> RGB with libjpeg's fixed-point tables.
    let t = jpeg_ycc_tables
    let py = planes[0]
    let pcb = planes[1]
    let pcr = planes[2]
    for i in 0..<(width * height) {
      let y = py[i]
      let cb = pcb[i]
      let cr = pcr[i]
      out_buf[i * 4] = clamp_byte(y + t.cr_r[cr])
      out_buf[i * 4 + 1] = clamp_byte(y + ((t.cb_g[cb] + t.cr_g[cr]) >> 16))
      out_buf[i * 4 + 2] = clamp_byte(y + t.cb_b[cb])
    }
  }
  { width, height, data: Bytes::from_array(out_buf), }
}

///|
fn clamp_byte(v : Int32) -> Byte {
  if v < 0 {
    b'\x00'
  } else if v > 255 {
    b'\xFF'
  } else {
    v.to_byte()
  }
}
