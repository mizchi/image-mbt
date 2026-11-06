// WebP lossless (VP8L) decoder: prefix codes, LZ77 backward references,
// color cache, meta prefix codes, and the four inverse transforms
// (predictor, cross-color, subtract-green, color indexing).
// Pixels are kept as packed ARGB in Int (0xAARRGGBB).

///|
/// LSB-first bit reader over `data[start:end]`. Reading past the end
/// yields zero bits; consuming any of them raises CorruptData.
priv struct VP8LReader {
  data : Bytes
  end : Int32
  mut pos : Int32
  mut val : UInt64
  mut nbits : Int32
  mut pad : Int32 // zero bits appended past the end, at the top of `val`
}

///|
fn VP8LReader::new(data : Bytes, start : Int32, end : Int32) -> VP8LReader {
  { data, end, pos: start, val: 0, nbits: 0, pad: 0, }
}

///|
fn VP8LReader::fill(self : VP8LReader) -> Unit {
  while self.nbits <= 56 {
    if self.pos < self.end {
      self.val = self.val | (self.data[self.pos].to_uint64() << self.nbits)
      self.pos += 1
    } else {
      self.pad += 8
    }
    self.nbits += 8
  }
}

///|
fn VP8LReader::peek(self : VP8LReader, n : Int32) -> Int32 {
  if self.nbits < n {
    self.fill()
  }
  (self.val & ((1UL << n) - 1)).to_int()
}

///|
fn VP8LReader::skip(self : VP8LReader, n : Int32) -> Unit raise DecodeError {
  self.val = self.val >> n
  self.nbits -= n
  if self.nbits < self.pad {
    raise CorruptData("truncated WebP lossless data")
  }
}

///|
fn VP8LReader::read(self : VP8LReader, n : Int32) -> Int32 raise DecodeError {
  if n == 0 {
    return 0
  }
  let v = self.peek(n)
  self.skip(n)
  v
}

///|
/// Canonical prefix code. `single >= 0` is a zero-bit code. Codes up to
/// `lut_bits` (<= 8) bits are looked up in `lut` (entry = symbol << 4 |
/// length); longer
/// ones are decoded bit by bit from `counts` / `sorted`.
priv struct VP8LHuff {
  single : Int32
  lut_bits : Int32
  lut : FixedArray[Int32]
  counts : FixedArray[Int32]
  sorted : FixedArray[Int32]
}

///|
fn vp8l_build_huff(lengths : FixedArray[Int32]) -> VP8LHuff raise DecodeError {
  let counts = FixedArray::make(16, 0)
  let mut used = 0
  let mut last = 0
  for s in 0..<lengths.length() {
    let l = lengths[s]
    if l > 15 {
      raise CorruptData("invalid WebP code length")
    }
    if l > 0 {
      counts[l] += 1
      used += 1
      last = s
    }
  }
  if used == 0 {
    raise CorruptData("empty WebP prefix code")
  }
  if used == 1 {
    return { single: last, lut_bits: 0, lut: [], counts, sorted: [], }
  }
  // The code must be complete (Kraft sum exactly 1).
  let mut left = 1
  for l in 1..<16 {
    left = (left << 1) - counts[l]
    if left < 0 {
      raise CorruptData("over-subscribed WebP prefix code")
    }
  }
  if left != 0 {
    raise CorruptData("incomplete WebP prefix code")
  }
  let offsets = FixedArray::make(16, 0)
  for l in 1..<15 {
    offsets[l + 1] = offsets[l] + counts[l]
  }
  let sorted = FixedArray::make(used, 0)
  let next = offsets.copy()
  for s in 0..<lengths.length() {
    let l = lengths[s]
    if l > 0 {
      sorted[next[l]] = s
      next[l] += 1
    }
  }
  let mut max_len = 0
  for l in 1..<16 {
    if counts[l] > 0 {
      max_len = l
    }
  }
  let lut_bits = if max_len < 8 { max_len } else { 8 }
  let lut_size = 1 << lut_bits
  let lut = FixedArray::make(lut_size, -1)
  let mut code = 0
  let mut idx = 0
  for l in 1..<16 {
    for _ in 0..<counts[l] {
      if l <= lut_bits {
        // Reverse the code: the stream carries its first bit lowest.
        let mut rev = 0
        for b in 0..<l {
          rev = rev | (((code >> b) & 1) << (l - 1 - b))
        }
        let entry = (sorted[idx] << 4) | l
        let mut j = rev
        while j < lut_size {
          lut[j] = entry
          j += 1 << l
        }
      }
      code += 1
      idx += 1
    }
    code = code << 1
  }
  { single: -1, lut_bits, lut, counts, sorted, }
}

///|
fn VP8LHuff::decode(
  self : VP8LHuff,
  br : VP8LReader,
) -> Int32 raise DecodeError {
  if self.single >= 0 {
    return self.single
  }
  let e = self.lut[br.peek(self.lut_bits)]
  if e >= 0 {
    br.skip(e & 15)
    return e >> 4
  }
  let mut code = 0
  let mut first = 0
  let mut index = 0
  for l in 1..<16 {
    code = code | br.read(1)
    let count = self.counts[l]
    if code - first < count {
      return self.sorted[index + code - first]
    }
    index += count
    first = (first + count) << 1
    code = code << 1
  }
  raise CorruptData("invalid WebP prefix code")
}

///|
let vp8l_code_length_order : FixedArray[Int32] = [
  17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
]

///|
fn vp8l_read_huff(
  br : VP8LReader,
  alphabet : Int32,
) -> VP8LHuff raise DecodeError {
  let lengths = FixedArray::make(alphabet, 0)
  if br.read(1) == 1 {
    // Simple code: one or two symbols.
    let num = br.read(1) + 1
    let first_bits = if br.read(1) == 0 { 1 } else { 8 }
    let s0 = br.read(first_bits)
    if s0 >= alphabet {
      raise CorruptData("WebP prefix symbol out of range")
    }
    lengths[s0] = 1
    if num == 2 {
      let s1 = br.read(8)
      if s1 >= alphabet {
        raise CorruptData("WebP prefix symbol out of range")
      }
      lengths[s1] = 1
    }
  } else {
    let cl_lengths = FixedArray::make(19, 0)
    let num_codes = br.read(4) + 4
    for i in 0..<num_codes {
      cl_lengths[vp8l_code_length_order[i]] = br.read(3)
    }
    let cl = vp8l_build_huff(cl_lengths)
    let max_symbol = if br.read(1) == 1 {
      let nbits = 2 + 2 * br.read(3)
      let m = 2 + br.read(nbits)
      if m > alphabet {
        raise CorruptData("WebP code length count too large")
      }
      m
    } else {
      alphabet
    }
    let mut remaining = max_symbol
    let mut symbol = 0
    let mut prev = 8
    while symbol < alphabet {
      if remaining == 0 {
        break
      }
      remaining -= 1
      let c = cl.decode(br)
      if c < 16 {
        lengths[symbol] = c
        symbol += 1
        if c != 0 {
          prev = c
        }
      } else {
        let (extra, offset, value) = match c {
          16 => (2, 3, prev)
          17 => (3, 3, 0)
          _ => (7, 11, 0)
        }
        let repeat = br.read(extra) + offset
        if symbol + repeat > alphabet {
          raise CorruptData("WebP code length repeat overflows")
        }
        for _ in 0..<repeat {
          lengths[symbol] = value
          symbol += 1
        }
      }
    }
  }
  vp8l_build_huff(lengths)
}

///|
/// The five codes of one prefix-code group: green / length / cache,
/// red, blue, alpha, distance.
priv struct VP8LGroup {
  green : VP8LHuff
  red : VP8LHuff
  blue : VP8LHuff
  alpha : VP8LHuff
  dist : VP8LHuff
}

///|
fn vp8l_read_group(
  br : VP8LReader,
  cache_size : Int32,
) -> VP8LGroup raise DecodeError {
  let green = vp8l_read_huff(br, 256 + 24 + cache_size)
  let red = vp8l_read_huff(br, 256)
  let blue = vp8l_read_huff(br, 256)
  let alpha = vp8l_read_huff(br, 256)
  let dist = vp8l_read_huff(br, 40)
  { green, red, blue, alpha, dist, }
}

///|
fn vp8l_subsample(size : Int32, bits : Int32) -> Int32 {
  (size + (1 << bits) - 1) >> bits
}

///|
fn vp8l_prefix_value(
  prefix : Int32,
  br : VP8LReader,
) -> Int32 raise DecodeError {
  if prefix < 4 {
    return prefix + 1
  }
  let extra = (prefix - 2) >> 1
  let offset = (2 + (prefix & 1)) << extra
  offset + br.read(extra) + 1
}

///|
let vp8l_code_to_plane : FixedArray[Int32] = [
  0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1a, 0x26, 0x2a, 0x38, 0x05,
  0x37, 0x39, 0x15, 0x1b, 0x36, 0x3a, 0x25, 0x2b, 0x48, 0x04, 0x47, 0x49, 0x14, 0x1c,
  0x35, 0x3b, 0x46, 0x4a, 0x24, 0x2c, 0x58, 0x45, 0x4b, 0x34, 0x3c, 0x03, 0x57, 0x59,
  0x13, 0x1d, 0x56, 0x5a, 0x23, 0x2d, 0x44, 0x4c, 0x55, 0x5b, 0x33, 0x3d, 0x68, 0x02,
  0x67, 0x69, 0x12, 0x1e, 0x66, 0x6a, 0x22, 0x2e, 0x54, 0x5c, 0x43, 0x4d, 0x65, 0x6b,
  0x32, 0x3e, 0x78, 0x01, 0x77, 0x79, 0x53, 0x5d, 0x11, 0x1f, 0x64, 0x6c, 0x42, 0x4e,
  0x76, 0x7a, 0x21, 0x2f, 0x75, 0x7b, 0x31, 0x3f, 0x63, 0x6d, 0x52, 0x5e, 0x00, 0x74,
  0x7c, 0x41, 0x4f, 0x10, 0x20, 0x62, 0x6e, 0x30, 0x73, 0x7d, 0x51, 0x5f, 0x40, 0x72,
  0x7e, 0x61, 0x6f, 0x50, 0x71, 0x7f, 0x60, 0x70,
]

///|
fn vp8l_plane_distance(xsize : Int32, code : Int32) -> Int32 {
  if code > 120 {
    code - 120
  } else {
    let d = vp8l_code_to_plane[code - 1]
    let dist = (d >> 4) * xsize + (8 - (d & 0xf))
    if dist >= 1 {
      dist
    } else {
      1
    }
  }
}

///|
fn vp8l_cache_key(argb : Int32, bits : Int32) -> Int32 {
  ((argb.reinterpret_as_uint() * 0x1e35a7bdU) >> (32 - bits)).reinterpret_as_int()
}

///|
/// Decode one entropy-coded image of `xsize` x `ysize` pixels. Only the
/// main image (`level0`) may use meta prefix codes.
fn vp8l_decode_entropy_image(
  br : VP8LReader,
  xsize : Int32,
  ysize : Int32,
  level0 : Bool,
) -> FixedArray[Int32] raise DecodeError {
  let cache_bits = if br.read(1) == 1 {
    let b = br.read(4)
    if b < 1 || b > 11 {
      raise CorruptData("invalid WebP color cache size")
    }
    b
  } else {
    0
  }
  let cache_size = if cache_bits > 0 { 1 << cache_bits } else { 0 }
  let mut meta_bits = 0
  let mut meta_w = 0
  let mut meta : FixedArray[Int32] = []
  let mut num_groups = 1
  if level0 && br.read(1) == 1 {
    meta_bits = br.read(3) + 2
    meta_w = vp8l_subsample(xsize, meta_bits)
    let mh = vp8l_subsample(ysize, meta_bits)
    meta = vp8l_decode_entropy_image(br, meta_w, mh, false)
    for i in 0..<meta.length() {
      let g = (meta[i] >> 8) & 0xffff
      meta[i] = g
      if g >= num_groups {
        num_groups = g + 1
      }
    }
  }
  let groups : Array[VP8LGroup] = []
  for _ in 0..<num_groups {
    groups.push(vp8l_read_group(br, cache_size))
  }
  let total = xsize * ysize
  let data = FixedArray::make(total, 0)
  let cache = FixedArray::make(cache_size, 0)
  let mut pos = 0
  let mut x = 0
  let mut y = 0
  let mut last_cached = 0
  let has_meta = meta.length() > 0
  while pos < total {
    let g = if has_meta {
      groups[meta[(y >> meta_bits) * meta_w + (x >> meta_bits)]]
    } else {
      groups[0]
    }
    let s = g.green.decode(br)
    if s < 256 {
      let r = g.red.decode(br)
      let b = g.blue.decode(br)
      let a = g.alpha.decode(br)
      data[pos] = (a << 24) | (r << 16) | (s << 8) | b
      pos += 1
      x += 1
      if x == xsize {
        x = 0
        y += 1
      }
    } else if s < 280 {
      let length = vp8l_prefix_value(s - 256, br)
      let dsym = g.dist.decode(br)
      let dist = vp8l_plane_distance(xsize, vp8l_prefix_value(dsym, br))
      if dist > pos || total - pos < length {
        raise CorruptData("invalid WebP backward reference")
      }
      for i in 0..<length {
        data[pos + i] = data[pos + i - dist]
      }
      pos += length
      x += length
      while x >= xsize {
        x -= xsize
        y += 1
      }
    } else {
      let idx = s - 280
      if idx >= cache_size {
        raise CorruptData("invalid WebP color cache index")
      }
      data[pos] = cache[idx]
      pos += 1
      x += 1
      if x == xsize {
        x = 0
        y += 1
      }
    }
    if cache_bits > 0 {
      while last_cached < pos {
        let c = data[last_cached]
        cache[vp8l_cache_key(c, cache_bits)] = c
        last_cached += 1
      }
    }
  }
  data
}

///|
priv enum VP8LTransform {
  Predictor(Int32, Int32, FixedArray[Int32]) // xsize, bits, sub-image
  CrossColor(Int32, Int32, FixedArray[Int32])
  SubtractGreen
  ColorIndexing(Int32, Int32, FixedArray[Int32]) // xsize, bits, palette
}

///|
fn vp8l_add_pixels(a : Int32, b : Int32) -> Int32 {
  let ag = (a & 0xff00ff00) + (b & 0xff00ff00)
  let rb = (a & 0x00ff00ff) + (b & 0x00ff00ff)
  (ag & 0xff00ff00) | (rb & 0x00ff00ff)
}

///|
fn vp8l_average2(a : Int32, b : Int32) -> Int32 {
  (((a ^ b) & 0xfefefefe).reinterpret_as_uint() >> 1).reinterpret_as_int() +
  (a & b)
}

///|
fn vp8l_clip255(v : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}

///|
fn vp8l_select(t : Int32, l : Int32, tl : Int32) -> Int32 {
  let mut diff = 0
  for k in 0..<4 {
    let sh = k * 8
    let tc = (t >> sh) & 0xff
    let lc = (l >> sh) & 0xff
    let tlc = (tl >> sh) & 0xff
    let pb = lc - tlc
    let pa = tc - tlc
    diff += pb.abs() - pa.abs()
  }
  if diff <= 0 {
    t
  } else {
    l
  }
}

///|
fn vp8l_clamp_full(a : Int32, b : Int32, c : Int32) -> Int32 {
  let mut out = 0
  for k in 0..<4 {
    let sh = k * 8
    let v = ((a >> sh) & 0xff) + ((b >> sh) & 0xff) - ((c >> sh) & 0xff)
    out = out | (vp8l_clip255(v) << sh)
  }
  out
}

///|
fn vp8l_clamp_half(a : Int32, b : Int32, c : Int32) -> Int32 {
  let ave = vp8l_average2(a, b)
  let mut out = 0
  for k in 0..<4 {
    let sh = k * 8
    let x = (ave >> sh) & 0xff
    let y = (c >> sh) & 0xff
    out = out | (vp8l_clip255(x + (x - y) / 2) << sh)
  }
  out
}

///|
fn vp8l_predict(
  mode : Int32,
  px : FixedArray[Int32],
  pos : Int32,
  xsize : Int32,
) -> Int32 {
  let l = px[pos - 1]
  let t = px[pos - xsize]
  match mode {
    0 => 0xff000000
    1 => l
    2 => t
    3 => px[pos - xsize + 1]
    4 => px[pos - xsize - 1]
    5 => vp8l_average2(vp8l_average2(l, px[pos - xsize + 1]), t)
    6 => vp8l_average2(l, px[pos - xsize - 1])
    7 => vp8l_average2(l, t)
    8 => vp8l_average2(px[pos - xsize - 1], t)
    9 => vp8l_average2(t, px[pos - xsize + 1])
    10 =>
      vp8l_average2(
        vp8l_average2(l, px[pos - xsize - 1]),
        vp8l_average2(t, px[pos - xsize + 1]),
      )
    11 => vp8l_select(t, l, px[pos - xsize - 1])
    12 => vp8l_clamp_full(l, t, px[pos - xsize - 1])
    13 => vp8l_clamp_half(l, t, px[pos - xsize - 1])
    _ => 0xff000000
  }
}

///|
fn vp8l_inverse_predictor(
  px : FixedArray[Int32],
  xsize : Int32,
  ysize : Int32,
  bits : Int32,
  modes : FixedArray[Int32],
) -> Unit {
  if px.length() == 0 {
    return
  }
  px[0] = vp8l_add_pixels(px[0], 0xff000000)
  for x in 1..<xsize {
    px[x] = vp8l_add_pixels(px[x], px[x - 1])
  }
  let tiles_w = vp8l_subsample(xsize, bits)
  for y in 1..<ysize {
    let row = y * xsize
    px[row] = vp8l_add_pixels(px[row], px[row - xsize])
    let mrow = (y >> bits) * tiles_w
    for x in 1..<xsize {
      let mode = (modes[mrow + (x >> bits)] >> 8) & 0xf
      let pos = row + x
      px[pos] = vp8l_add_pixels(px[pos], vp8l_predict(mode, px, pos, xsize))
    }
  }
}

///|
fn vp8l_color_delta(t : Int32, c : Int32) -> Int32 {
  let ts = if t >= 128 { t - 256 } else { t }
  let cs = if c >= 128 { c - 256 } else { c }
  (ts * cs) >> 5
}

///|
fn vp8l_inverse_cross_color(
  px : FixedArray[Int32],
  xsize : Int32,
  ysize : Int32,
  bits : Int32,
  mult : FixedArray[Int32],
) -> Unit {
  let tiles_w = vp8l_subsample(xsize, bits)
  for y in 0..<ysize {
    let mrow = (y >> bits) * tiles_w
    for x in 0..<xsize {
      let m = mult[mrow + (x >> bits)]
      let g2r = m & 0xff
      let g2b = (m >> 8) & 0xff
      let r2b = (m >> 16) & 0xff
      let pos = y * xsize + x
      let argb = px[pos]
      let green = (argb >> 8) & 0xff
      let red = ((argb >> 16) & 0xff) + vp8l_color_delta(g2r, green)
      let red = red & 0xff
      let blue = (argb & 0xff) +
        vp8l_color_delta(g2b, green) +
        vp8l_color_delta(r2b, red)
      px[pos] = (argb & 0xff00ff00) | (red << 16) | (blue & 0xff)
    }
  }
}

///|
fn vp8l_inverse_subtract_green(px : FixedArray[Int32]) -> Unit {
  for i in 0..<px.length() {
    let argb = px[i]
    let g = (argb >> 8) & 0xff
    let rb = (argb & 0x00ff00ff) + ((g << 16) | g)
    px[i] = (argb & 0xff00ff00) | (rb & 0x00ff00ff)
  }
}

///|
/// Expand packed palette indices of a `packed_w`-wide image into a
/// `xsize`-wide one.
fn vp8l_inverse_color_indexing(
  px : FixedArray[Int32],
  packed_w : Int32,
  xsize : Int32,
  ysize : Int32,
  bits : Int32,
  palette : FixedArray[Int32],
) -> FixedArray[Int32] {
  let out = FixedArray::make(xsize * ysize, 0)
  let bpp = 8 >> bits
  let per = (1 << bits) - 1
  let mask = (1 << bpp) - 1
  for y in 0..<ysize {
    for x in 0..<xsize {
      let packed = px[y * packed_w + (x >> bits)]
      let g = (packed >> 8) & 0xff
      let idx = (g >> ((x & per) * bpp)) & mask
      out[y * xsize + x] = palette[idx]
    }
  }
  out
}

///|
/// Decode a VP8L image stream (after the 5-byte header for full images;
/// ALPH chunks start here directly) into ARGB pixels.
fn vp8l_decode_stream(
  br : VP8LReader,
  width : Int32,
  height : Int32,
) -> FixedArray[Int32] raise DecodeError {
  let transforms : Array[VP8LTransform] = []
  let mut xsize = width
  let mut seen = 0
  while br.read(1) == 1 {
    let ty = br.read(2)
    if (seen & (1 << ty)) != 0 {
      raise CorruptData("repeated WebP transform")
    }
    seen = seen | (1 << ty)
    match ty {
      0 | 1 => {
        let bits = br.read(3) + 2
        let sub = vp8l_decode_entropy_image(
          br,
          vp8l_subsample(xsize, bits),
          vp8l_subsample(height, bits),
          false,
        )
        transforms.push(
          if ty == 0 {
            Predictor(xsize, bits, sub)
          } else {
            CrossColor(xsize, bits, sub)
          },
        )
      }
      2 => transforms.push(SubtractGreen)
      _ => {
        let num = br.read(8) + 1
        let bits = if num > 16 {
          0
        } else if num > 4 {
          1
        } else if num > 2 {
          2
        } else {
          3
        }
        let colors = vp8l_decode_entropy_image(br, num, 1, false)
        // Colors are delta-coded; entries past `num` are transparent black.
        let palette = FixedArray::make(1 << (8 >> bits), 0)
        palette[0] = colors[0]
        for i in 1..<num {
          palette[i] = vp8l_add_pixels(colors[i], palette[i - 1])
        }
        transforms.push(ColorIndexing(xsize, bits, palette))
        xsize = vp8l_subsample(xsize, bits)
      }
    }
  }
  let mut px = vp8l_decode_entropy_image(br, xsize, height, true)
  let mut cur_w = xsize
  for i = transforms.length() - 1; i >= 0; i = i - 1 {
    match transforms[i] {
      Predictor(w, bits, sub) =>
        vp8l_inverse_predictor(px, w, height, bits, sub)
      CrossColor(w, bits, sub) =>
        vp8l_inverse_cross_color(px, w, height, bits, sub)
      SubtractGreen => vp8l_inverse_subtract_green(px)
      ColorIndexing(w, bits, palette) => {
        px = vp8l_inverse_color_indexing(px, cur_w, w, height, bits, palette)
        cur_w = w
      }
    }
  }
  px
}

///|
/// Decode a complete VP8L bitstream (the payload of a `VP8L` chunk).
/// Returns (width, height, alpha_is_used, ARGB pixels).
fn vp8l_decode(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> (Int32, Int32, Bool, FixedArray[Int32]) raise DecodeError {
  if end - start < 5 || data[start] != b'\x2f' {
    raise InvalidSignature("not a WebP lossless bitstream")
  }
  let br = VP8LReader::new(data, start + 1, end)
  let width = br.read(14) + 1
  let height = br.read(14) + 1
  let has_alpha = br.read(1) == 1
  if br.read(3) != 0 {
    raise UnsupportedFeature("unknown WebP lossless version")
  }
  check_decode_size(width, height)
  let px = vp8l_decode_stream(br, width, height)
  (width, height, has_alpha, px)
}
