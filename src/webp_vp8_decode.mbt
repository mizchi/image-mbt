// WebP lossy (VP8 key frame) decoder, bit-exact with libwebp: boolean
// entropy decoder, intra prediction, inverse WHT / DCT, normal and simple
// loop filters, "fancy" chroma upsampling and fixed-point YUV -> RGB, plus
// the ALPH chunk (raw or lossless-compressed, with spatial unfiltering).

///|
priv struct VP8BoolReader {
  data : Bytes
  end : Int32
  mut pos : Int32
  mut value : Int32
  mut range : Int32 // range - 1
  mut bits : Int32 // number of look-ahead bits in `value`
  mut eof : Bool
}

///|
fn VP8BoolReader::new(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> VP8BoolReader {
  let br : VP8BoolReader = {
    data,
    end,
    pos: start,
    value: 0,
    range: 254,
    bits: -8,
    eof: false,
  }
  br.load()
  br
}

///|
fn VP8BoolReader::load(self : VP8BoolReader) -> Unit {
  if self.pos < self.end {
    self.value = (self.value << 8) | self.data[self.pos].to_int()
    self.pos += 1
    self.bits += 8
  } else if !self.eof {
    self.value = self.value << 8
    self.bits += 8
    self.eof = true
  } else {
    self.bits = 0
  }
}

///|
fn VP8BoolReader::get_bit(self : VP8BoolReader, prob : Int32) -> Int32 {
  if self.bits < 0 {
    self.load()
  }
  let mut range = self.range
  let split = (range * prob) >> 8
  let pos = self.bits
  let bit = if self.value >> pos > split {
    range -= split
    self.value -= (split + 1) << pos
    1
  } else {
    range = split + 1
    0
  }
  let shift = range.clz() - 24
  self.bits -= shift
  self.range = (range << shift) - 1
  bit
}

///|
fn VP8BoolReader::get_value(self : VP8BoolReader, n : Int32) -> Int32 {
  let mut v = 0
  for i = n - 1; i >= 0; i = i - 1 {
    v = v | (self.get_bit(0x80) << i)
  }
  v
}

///|
fn VP8BoolReader::get_signed_value(self : VP8BoolReader, n : Int32) -> Int32 {
  let v = self.get_value(n)
  if self.get_bit(0x80) == 1 {
    -v
  } else {
    v
  }
}

///|
let vp8_bands : FixedArray[Int32] = [
  0, 1, 2, 3, 6, 4, 5, 6, 6, 6, 6, 6, 6, 6, 6, 7, 0,
]

///|
let vp8_zigzag : FixedArray[Int32] = [
  0, 1, 4, 8, 5, 2, 3, 6, 9, 12, 13, 10, 7, 11, 14, 15,
]

///|
let vp8_cat3456 : FixedArray[FixedArray[Int32]] = [
  [173, 148, 140],
  [176, 155, 140, 135],
  [180, 157, 141, 134, 130],
  [254, 254, 243, 230, 196, 177, 153, 140, 133, 130, 129],
]

///|
/// Tree for 4x4 intra modes: entries > 0 index the next pair, entries
/// <= 0 are -mode.
let vp8_ymodes_intra4 : FixedArray[Int32] = [
  0, 1, -1, 2, -2, 3, 4, 6, -3, 5, -4, -5, -6, 7, -7, 8, -8, -9,
]

///|
priv struct VP8Decoder {
  mb_w : Int32
  mb_h : Int32
  // probabilities: proba[t][b][c][p], flattened (t * 8 + b) * 33 + c * 11 + p
  proba : FixedArray[Int32]
  segment_probs : FixedArray[Int32]
  mut use_skip : Bool
  mut skip_p : Int32
  mut update_map : Bool
  // dequantization per segment: y1 dc/ac, y2 dc/ac, uv dc/ac
  dq : FixedArray[Int32]
  // filter info per segment and i4x4: limit, ilevel, hev_thresh
  fstrength : FixedArray[Int32]
  mut filter_type : Int32
}

///|
fn vp8_clip(v : Int32, m : Int32) -> Int32 {
  if v < 0 {
    0
  } else if v > m {
    m
  } else {
    v
  }
}

///|
fn vp8_clip8(v : Int32) -> Int32 {
  if (v & -256) == 0 {
    v
  } else if v < 0 {
    0
  } else {
    255
  }
}

///|
/// Read a probability-coded token list starting at coefficient `n`.
/// Returns the index of the last non-zero coefficient plus one.
fn vp8_get_coeffs(
  br : VP8BoolReader,
  proba : FixedArray[Int32],
  t : Int32,
  ctx0 : Int32,
  dc_q : Int32,
  ac_q : Int32,
  first : Int32,
  out : FixedArray[Int32],
  out_off : Int32,
) -> Int32 {
  let base = t * 8 * 33
  let mut n = first
  let mut p = base + vp8_bands[n] * 33 + ctx0 * 11
  while n < 16 {
    if br.get_bit(proba[p]) == 0 {
      return n
    }
    while br.get_bit(proba[p + 1]) == 0 {
      n += 1
      if n == 16 {
        return 16
      }
      p = base + vp8_bands[n] * 33
    }
    let next = base + vp8_bands[n + 1] * 33
    let v = if br.get_bit(proba[p + 2]) == 0 {
      p = next + 11
      1
    } else {
      let v = vp8_large_value(br, proba, p)
      p = next + 22
      v
    }
    let s = if br.get_bit(0x80) == 1 { -v } else { v }
    out[out_off + vp8_zigzag[n]] = s * (if n > 0 { ac_q } else { dc_q })
    n += 1
  }
  16
}

///|
fn vp8_large_value(
  br : VP8BoolReader,
  proba : FixedArray[Int32],
  p : Int32,
) -> Int32 {
  if br.get_bit(proba[p + 3]) == 0 {
    if br.get_bit(proba[p + 4]) == 0 {
      2
    } else {
      3 + br.get_bit(proba[p + 5])
    }
  } else if br.get_bit(proba[p + 6]) == 0 {
    if br.get_bit(proba[p + 7]) == 0 {
      5 + br.get_bit(159)
    } else {
      let v = 7 + 2 * br.get_bit(165)
      v + br.get_bit(145)
    }
  } else {
    let bit1 = br.get_bit(proba[p + 8])
    let bit0 = br.get_bit(proba[p + 9 + bit1])
    let cat = 2 * bit1 + bit0
    let mut v = 0
    for prob in vp8_cat3456[cat] {
      v = v + v + br.get_bit(prob)
    }
    v + 3 + (8 << cat)
  }
}

///|
fn vp8_transform_wht(
  input : FixedArray[Int32],
  out : FixedArray[Int32],
) -> Unit {
  let tmp = FixedArray::make(16, 0)
  for i in 0..<4 {
    let a0 = input[0 + i] + input[12 + i]
    let a1 = input[4 + i] + input[8 + i]
    let a2 = input[4 + i] - input[8 + i]
    let a3 = input[0 + i] - input[12 + i]
    tmp[0 + i] = a0 + a1
    tmp[8 + i] = a0 - a1
    tmp[4 + i] = a3 + a2
    tmp[12 + i] = a3 - a2
  }
  for i in 0..<4 {
    let dc = tmp[0 + i * 4] + 3
    let a0 = dc + tmp[3 + i * 4]
    let a1 = tmp[1 + i * 4] + tmp[2 + i * 4]
    let a2 = tmp[1 + i * 4] - tmp[2 + i * 4]
    let a3 = dc - tmp[3 + i * 4]
    let o = i * 64
    out[o] = (a0 + a1) >> 3
    out[o + 16] = (a3 + a2) >> 3
    out[o + 32] = (a0 - a1) >> 3
    out[o + 48] = (a3 - a2) >> 3
  }
}

///|
/// Scratch for `vp8_transform` (decoding is single-threaded).
let vp8_idct_tmp : FixedArray[Int32] = FixedArray::make(16, 0)

///|
fn vp8_mul1(a : Int32) -> Int32 {
  ((a * 20091) >> 16) + a
}

///|
fn vp8_mul2(a : Int32) -> Int32 {
  (a * 35468) >> 16
}

///|
/// Inverse DCT of the 16 coefficients at `input[off:]`, added to the 4x4
/// block at `dst[d:]` (stride 32).
fn vp8_transform(
  input : FixedArray[Int32],
  off : Int32,
  dst : FixedArray[Int32],
  d : Int32,
) -> Unit {
  let tmp = vp8_idct_tmp
  for i in 0..<4 {
    let x = off + i
    let a = input[x] + input[x + 8]
    let b = input[x] - input[x + 8]
    let c = vp8_mul2(input[x + 4]) - vp8_mul1(input[x + 12])
    let dd = vp8_mul1(input[x + 4]) + vp8_mul2(input[x + 12])
    tmp[i * 4] = a + dd
    tmp[i * 4 + 1] = b + c
    tmp[i * 4 + 2] = b - c
    tmp[i * 4 + 3] = a - dd
  }
  for i in 0..<4 {
    let dc = tmp[i] + 4
    let a = dc + tmp[8 + i]
    let b = dc - tmp[8 + i]
    let c = vp8_mul2(tmp[4 + i]) - vp8_mul1(tmp[12 + i])
    let dd = vp8_mul1(tmp[4 + i]) + vp8_mul2(tmp[12 + i])
    let o = d + i * 32
    dst[o] = vp8_clip8(dst[o] + ((a + dd) >> 3))
    dst[o + 1] = vp8_clip8(dst[o + 1] + ((b + c) >> 3))
    dst[o + 2] = vp8_clip8(dst[o + 2] + ((b - c) >> 3))
    dst[o + 3] = vp8_clip8(dst[o + 3] + ((a - dd) >> 3))
  }
}

// ---------------------------------------------------------------------------
// Intra prediction on the 32-stride work buffer.

///|
fn vp8_avg3(a : Int32, b : Int32, c : Int32) -> Int32 {
  (a + 2 * b + c + 2) >> 2
}

///|
fn vp8_avg2(a : Int32, b : Int32) -> Int32 {
  (a + b + 1) >> 1
}

///|
fn vp8_fill(
  buf : FixedArray[Int32],
  d : Int32,
  size : Int32,
  v : Int32,
) -> Unit {
  for y in 0..<size {
    for x in 0..<size {
      buf[d + y * 32 + x] = v
    }
  }
}

///|
fn vp8_true_motion(buf : FixedArray[Int32], d : Int32, size : Int32) -> Unit {
  let tl = buf[d - 33]
  for y in 0..<size {
    let l = buf[d + y * 32 - 1]
    for x in 0..<size {
      buf[d + y * 32 + x] = vp8_clip8(buf[d - 32 + x] + l - tl)
    }
  }
}

///|
/// 16x16 luma (size 16) or 8x8 chroma (size 8) prediction. `mode` is
/// 0 DC, 1 TM, 2 V, 3 H, 4 DC without top, 5 DC without left, 6 DC with
/// neither.
fn vp8_predict_block(
  buf : FixedArray[Int32],
  d : Int32,
  size : Int32,
  mode : Int32,
) -> Unit {
  let shift = if size == 16 { 5 } else { 4 }
  match mode {
    0 => {
      let mut dc = size
      for j in 0..<size {
        dc += buf[d - 1 + j * 32] + buf[d + j - 32]
      }
      vp8_fill(buf, d, size, dc >> shift)
    }
    1 => vp8_true_motion(buf, d, size)
    2 =>
      for y in 0..<size {
        for x in 0..<size {
          buf[d + y * 32 + x] = buf[d - 32 + x]
        }
      }
    3 =>
      for y in 0..<size {
        let l = buf[d + y * 32 - 1]
        for x in 0..<size {
          buf[d + y * 32 + x] = l
        }
      }
    4 => {
      let mut dc = size >> 1
      for j in 0..<size {
        dc += buf[d - 1 + j * 32]
      }
      vp8_fill(buf, d, size, dc >> (shift - 1))
    }
    5 => {
      let mut dc = size >> 1
      for i in 0..<size {
        dc += buf[d + i - 32]
      }
      vp8_fill(buf, d, size, dc >> (shift - 1))
    }
    _ => vp8_fill(buf, d, size, 0x80)
  }
}

///|
fn vp8_set4(
  buf : FixedArray[Int32],
  d : Int32,
  x : Int32,
  y : Int32,
  v : Int32,
) -> Unit {
  buf[d + x + y * 32] = v
}

///|
fn vp8_predict4(buf : FixedArray[Int32], d : Int32, mode : Int32) -> Unit {
  let top = d - 32
  match mode {
    0 => {
      let mut dc = 4
      for i in 0..<4 {
        dc += buf[top + i] + buf[d - 1 + i * 32]
      }
      vp8_fill(buf, d, 4, dc >> 3)
    }
    1 => vp8_true_motion(buf, d, 4)
    2 =>
      for x in 0..<4 {
        let v = vp8_avg3(buf[top + x - 1], buf[top + x], buf[top + x + 1])
        for y in 0..<4 {
          vp8_set4(buf, d, x, y, v)
        }
      }
    3 => {
      let a = buf[d - 33]
      let b = buf[d - 1]
      let c = buf[d - 1 + 32]
      let dd = buf[d - 1 + 64]
      let e = buf[d - 1 + 96]
      let rows = [
        vp8_avg3(a, b, c),
        vp8_avg3(b, c, dd),
        vp8_avg3(c, dd, e),
        vp8_avg3(dd, e, e),
      ]
      for y in 0..<4 {
        for x in 0..<4 {
          vp8_set4(buf, d, x, y, rows[y])
        }
      }
    }
    4 => {
      // down-right
      let i = buf[d - 1]
      let j = buf[d - 1 + 32]
      let k = buf[d - 1 + 64]
      let l = buf[d - 1 + 96]
      let x = buf[d - 33]
      let a = buf[top]
      let b = buf[top + 1]
      let c = buf[top + 2]
      let dd = buf[top + 3]
      vp8_set4(buf, d, 0, 3, vp8_avg3(j, k, l))
      let v1 = vp8_avg3(i, j, k)
      vp8_set4(buf, d, 1, 3, v1)
      vp8_set4(buf, d, 0, 2, v1)
      let v2 = vp8_avg3(x, i, j)
      vp8_set4(buf, d, 2, 3, v2)
      vp8_set4(buf, d, 1, 2, v2)
      vp8_set4(buf, d, 0, 1, v2)
      let v3 = vp8_avg3(a, x, i)
      vp8_set4(buf, d, 3, 3, v3)
      vp8_set4(buf, d, 2, 2, v3)
      vp8_set4(buf, d, 1, 1, v3)
      vp8_set4(buf, d, 0, 0, v3)
      let v4 = vp8_avg3(b, a, x)
      vp8_set4(buf, d, 3, 2, v4)
      vp8_set4(buf, d, 2, 1, v4)
      vp8_set4(buf, d, 1, 0, v4)
      let v5 = vp8_avg3(c, b, a)
      vp8_set4(buf, d, 3, 1, v5)
      vp8_set4(buf, d, 2, 0, v5)
      vp8_set4(buf, d, 3, 0, vp8_avg3(dd, c, b))
    }
    5 => {
      // vertical-right
      let i = buf[d - 1]
      let j = buf[d - 1 + 32]
      let k = buf[d - 1 + 64]
      let x = buf[d - 33]
      let a = buf[top]
      let b = buf[top + 1]
      let c = buf[top + 2]
      let dd = buf[top + 3]
      let v = vp8_avg2(x, a)
      vp8_set4(buf, d, 0, 0, v)
      vp8_set4(buf, d, 1, 2, v)
      let v = vp8_avg2(a, b)
      vp8_set4(buf, d, 1, 0, v)
      vp8_set4(buf, d, 2, 2, v)
      let v = vp8_avg2(b, c)
      vp8_set4(buf, d, 2, 0, v)
      vp8_set4(buf, d, 3, 2, v)
      vp8_set4(buf, d, 3, 0, vp8_avg2(c, dd))
      vp8_set4(buf, d, 0, 3, vp8_avg3(k, j, i))
      vp8_set4(buf, d, 0, 2, vp8_avg3(j, i, x))
      let v = vp8_avg3(i, x, a)
      vp8_set4(buf, d, 0, 1, v)
      vp8_set4(buf, d, 1, 3, v)
      let v = vp8_avg3(x, a, b)
      vp8_set4(buf, d, 1, 1, v)
      vp8_set4(buf, d, 2, 3, v)
      let v = vp8_avg3(a, b, c)
      vp8_set4(buf, d, 2, 1, v)
      vp8_set4(buf, d, 3, 3, v)
      vp8_set4(buf, d, 3, 1, vp8_avg3(b, c, dd))
    }
    6 => {
      // down-left
      let t = FixedArray::make(8, 0)
      for n in 0..<8 {
        t[n] = buf[top + n]
      }
      vp8_set4(buf, d, 0, 0, vp8_avg3(t[0], t[1], t[2]))
      let v = vp8_avg3(t[1], t[2], t[3])
      vp8_set4(buf, d, 1, 0, v)
      vp8_set4(buf, d, 0, 1, v)
      let v = vp8_avg3(t[2], t[3], t[4])
      vp8_set4(buf, d, 2, 0, v)
      vp8_set4(buf, d, 1, 1, v)
      vp8_set4(buf, d, 0, 2, v)
      let v = vp8_avg3(t[3], t[4], t[5])
      vp8_set4(buf, d, 3, 0, v)
      vp8_set4(buf, d, 2, 1, v)
      vp8_set4(buf, d, 1, 2, v)
      vp8_set4(buf, d, 0, 3, v)
      let v = vp8_avg3(t[4], t[5], t[6])
      vp8_set4(buf, d, 3, 1, v)
      vp8_set4(buf, d, 2, 2, v)
      vp8_set4(buf, d, 1, 3, v)
      let v = vp8_avg3(t[5], t[6], t[7])
      vp8_set4(buf, d, 3, 2, v)
      vp8_set4(buf, d, 2, 3, v)
      vp8_set4(buf, d, 3, 3, vp8_avg3(t[6], t[7], t[7]))
    }
    7 => {
      // vertical-left
      let t = FixedArray::make(8, 0)
      for n in 0..<8 {
        t[n] = buf[top + n]
      }
      vp8_set4(buf, d, 0, 0, vp8_avg2(t[0], t[1]))
      let v = vp8_avg2(t[1], t[2])
      vp8_set4(buf, d, 1, 0, v)
      vp8_set4(buf, d, 0, 2, v)
      let v = vp8_avg2(t[2], t[3])
      vp8_set4(buf, d, 2, 0, v)
      vp8_set4(buf, d, 1, 2, v)
      let v = vp8_avg2(t[3], t[4])
      vp8_set4(buf, d, 3, 0, v)
      vp8_set4(buf, d, 2, 2, v)
      vp8_set4(buf, d, 0, 1, vp8_avg3(t[0], t[1], t[2]))
      let v = vp8_avg3(t[1], t[2], t[3])
      vp8_set4(buf, d, 1, 1, v)
      vp8_set4(buf, d, 0, 3, v)
      let v = vp8_avg3(t[2], t[3], t[4])
      vp8_set4(buf, d, 2, 1, v)
      vp8_set4(buf, d, 1, 3, v)
      let v = vp8_avg3(t[3], t[4], t[5])
      vp8_set4(buf, d, 3, 1, v)
      vp8_set4(buf, d, 2, 3, v)
      vp8_set4(buf, d, 3, 2, vp8_avg3(t[4], t[5], t[6]))
      vp8_set4(buf, d, 3, 3, vp8_avg3(t[5], t[6], t[7]))
    }
    8 => {
      // horizontal-down
      let i = buf[d - 1]
      let j = buf[d - 1 + 32]
      let k = buf[d - 1 + 64]
      let l = buf[d - 1 + 96]
      let x = buf[d - 33]
      let a = buf[top]
      let b = buf[top + 1]
      let c = buf[top + 2]
      let v = vp8_avg2(i, x)
      vp8_set4(buf, d, 0, 0, v)
      vp8_set4(buf, d, 2, 1, v)
      let v = vp8_avg2(j, i)
      vp8_set4(buf, d, 0, 1, v)
      vp8_set4(buf, d, 2, 2, v)
      let v = vp8_avg2(k, j)
      vp8_set4(buf, d, 0, 2, v)
      vp8_set4(buf, d, 2, 3, v)
      vp8_set4(buf, d, 0, 3, vp8_avg2(l, k))
      vp8_set4(buf, d, 3, 0, vp8_avg3(a, b, c))
      vp8_set4(buf, d, 2, 0, vp8_avg3(x, a, b))
      let v = vp8_avg3(i, x, a)
      vp8_set4(buf, d, 1, 0, v)
      vp8_set4(buf, d, 3, 1, v)
      let v = vp8_avg3(j, i, x)
      vp8_set4(buf, d, 1, 1, v)
      vp8_set4(buf, d, 3, 2, v)
      let v = vp8_avg3(k, j, i)
      vp8_set4(buf, d, 1, 2, v)
      vp8_set4(buf, d, 3, 3, v)
      vp8_set4(buf, d, 1, 3, vp8_avg3(l, k, j))
    }
    _ => {
      // horizontal-up
      let i = buf[d - 1]
      let j = buf[d - 1 + 32]
      let k = buf[d - 1 + 64]
      let l = buf[d - 1 + 96]
      vp8_set4(buf, d, 0, 0, vp8_avg2(i, j))
      let v = vp8_avg2(j, k)
      vp8_set4(buf, d, 2, 0, v)
      vp8_set4(buf, d, 0, 1, v)
      let v = vp8_avg2(k, l)
      vp8_set4(buf, d, 2, 1, v)
      vp8_set4(buf, d, 0, 2, v)
      vp8_set4(buf, d, 1, 0, vp8_avg3(i, j, k))
      let v = vp8_avg3(j, k, l)
      vp8_set4(buf, d, 3, 0, v)
      vp8_set4(buf, d, 1, 1, v)
      let v = vp8_avg3(k, l, l)
      vp8_set4(buf, d, 3, 1, v)
      vp8_set4(buf, d, 1, 2, v)
      vp8_set4(buf, d, 3, 2, l)
      vp8_set4(buf, d, 2, 2, l)
      vp8_set4(buf, d, 0, 3, l)
      vp8_set4(buf, d, 1, 3, l)
      vp8_set4(buf, d, 2, 3, l)
      vp8_set4(buf, d, 3, 3, l)
    }
  }
}

///|
fn vp8_check_mode(mb_x : Int32, mb_y : Int32, mode : Int32) -> Int32 {
  if mode == 0 {
    if mb_x == 0 {
      if mb_y == 0 {
        6
      } else {
        5
      }
    } else if mb_y == 0 {
      4
    } else {
      0
    }
  } else {
    mode
  }
}

// ---------------------------------------------------------------------------
// Loop filter (on the full-frame planes).

///|
fn vp8_sclip1(v : Int32) -> Int32 {
  if v < -128 {
    -128
  } else if v > 127 {
    127
  } else {
    v
  }
}

///|
fn vp8_sclip2(v : Int32) -> Int32 {
  if v < -16 {
    -16
  } else if v > 15 {
    15
  } else {
    v
  }
}

///|
fn vp8_do_filter2(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let a = 3 * (q0 - p0) + vp8_sclip1(p1 - q1)
  let a1 = vp8_sclip2((a + 4) >> 3)
  let a2 = vp8_sclip2((a + 3) >> 3)
  p[i - step] = vp8_clip8(p0 + a2).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
}

///|
fn vp8_do_filter4(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let a = 3 * (q0 - p0)
  let a1 = vp8_sclip2((a + 4) >> 3)
  let a2 = vp8_sclip2((a + 3) >> 3)
  let a3 = (a1 + 1) >> 1
  p[i - 2 * step] = vp8_clip8(p1 + a3).to_byte()
  p[i - step] = vp8_clip8(p0 + a2).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
  p[i + step] = vp8_clip8(q1 - a3).to_byte()
}

///|
fn vp8_do_filter6(p : FixedArray[Byte], i : Int32, step : Int32) -> Unit {
  let p2 = p[i - 3 * step].to_int()
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let q2 = p[i + 2 * step].to_int()
  let a = vp8_sclip1(3 * (q0 - p0) + vp8_sclip1(p1 - q1))
  let a1 = (27 * a + 63) >> 7
  let a2 = (18 * a + 63) >> 7
  let a3 = (9 * a + 63) >> 7
  p[i - 3 * step] = vp8_clip8(p2 + a3).to_byte()
  p[i - 2 * step] = vp8_clip8(p1 + a2).to_byte()
  p[i - step] = vp8_clip8(p0 + a1).to_byte()
  p[i] = vp8_clip8(q0 - a1).to_byte()
  p[i + step] = vp8_clip8(q1 - a2).to_byte()
  p[i + 2 * step] = vp8_clip8(q2 - a3).to_byte()
}

///|
fn vp8_hev(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  thresh : Int32,
) -> Bool {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  (p1 - p0).abs() > thresh || (q1 - q0).abs() > thresh
}

///|
fn vp8_needs_filter(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  t : Int32,
) -> Bool {
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  4 * (p0 - q0).abs() + (p1 - q1).abs() <= t
}

///|
fn vp8_needs_filter2(
  p : FixedArray[Byte],
  i : Int32,
  step : Int32,
  t : Int32,
  it : Int32,
) -> Bool {
  let p3 = p[i - 4 * step].to_int()
  let p2 = p[i - 3 * step].to_int()
  let p1 = p[i - 2 * step].to_int()
  let p0 = p[i - step].to_int()
  let q0 = p[i].to_int()
  let q1 = p[i + step].to_int()
  let q2 = p[i + 2 * step].to_int()
  let q3 = p[i + 3 * step].to_int()
  if 4 * (p0 - q0).abs() + (p1 - q1).abs() > t {
    return false
  }
  (p3 - p2).abs() <= it &&
  (p2 - p1).abs() <= it &&
  (p1 - p0).abs() <= it &&
  (q3 - q2).abs() <= it &&
  (q2 - q1).abs() <= it &&
  (q1 - q0).abs() <= it
}

///|
fn vp8_simple_filter(
  p : FixedArray[Byte],
  i : Int32,
  hstride : Int32,
  vstride : Int32,
  thresh : Int32,
) -> Unit {
  let t2 = 2 * thresh + 1
  for k in 0..<16 {
    let o = i + k * vstride
    if vp8_needs_filter(p, o, hstride, t2) {
      vp8_do_filter2(p, o, hstride)
    }
  }
}

///|
fn vp8_filter_loop(
  p : FixedArray[Byte],
  i : Int32,
  hstride : Int32,
  vstride : Int32,
  size : Int32,
  thresh : Int32,
  ithresh : Int32,
  hev_thresh : Int32,
  edge : Bool,
) -> Unit {
  let t2 = 2 * thresh + 1
  for k in 0..<size {
    let o = i + k * vstride
    if vp8_needs_filter2(p, o, hstride, t2, ithresh) {
      if vp8_hev(p, o, hstride, hev_thresh) {
        vp8_do_filter2(p, o, hstride)
      } else if edge {
        vp8_do_filter6(p, o, hstride)
      } else {
        vp8_do_filter4(p, o, hstride)
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Frame decoding.

///|
fn vp8_parse_header(
  dec : VP8Decoder,
  br : VP8BoolReader,
) -> (Bool, Bool, FixedArray[Int32]) {
  ignore(br.get_bit(0x80)) // color space
  ignore(br.get_bit(0x80)) // clamping type
  // Segment header
  let use_segment = br.get_bit(0x80) == 1
  let mut absolute = true
  let quantizer = FixedArray::make(4, 0)
  let filter_strength = FixedArray::make(4, 0)
  if use_segment {
    dec.update_map = br.get_bit(0x80) == 1
    if br.get_bit(0x80) == 1 {
      absolute = br.get_bit(0x80) == 1
      for s in 0..<4 {
        quantizer[s] = if br.get_bit(0x80) == 1 {
          br.get_signed_value(7)
        } else {
          0
        }
      }
      for s in 0..<4 {
        filter_strength[s] = if br.get_bit(0x80) == 1 {
          br.get_signed_value(6)
        } else {
          0
        }
      }
    }
    if dec.update_map {
      for s in 0..<3 {
        dec.segment_probs[s] = if br.get_bit(0x80) == 1 {
          br.get_value(8)
        } else {
          255
        }
      }
    }
  }
  // Filter header
  let simple = br.get_bit(0x80) == 1
  let level = br.get_value(6)
  let sharpness = br.get_value(3)
  let use_lf_delta = br.get_bit(0x80) == 1
  let ref_lf_delta = FixedArray::make(4, 0)
  let mode_lf_delta = FixedArray::make(4, 0)
  if use_lf_delta && br.get_bit(0x80) == 1 {
    for i in 0..<4 {
      if br.get_bit(0x80) == 1 {
        ref_lf_delta[i] = br.get_signed_value(6)
      }
    }
    for i in 0..<4 {
      if br.get_bit(0x80) == 1 {
        mode_lf_delta[i] = br.get_signed_value(6)
      }
    }
  }
  dec.filter_type = if level == 0 { 0 } else if simple { 1 } else { 2 }
  // Filter strengths per segment and i4x4.
  if dec.filter_type > 0 {
    for s in 0..<4 {
      let mut base_level = level
      if use_segment {
        base_level = filter_strength[s]
        if !absolute {
          base_level += level
        }
      }
      for i4x4 in 0..<2 {
        let mut lvl = base_level
        if use_lf_delta {
          lvl += ref_lf_delta[0]
          if i4x4 == 1 {
            lvl += mode_lf_delta[0]
          }
        }
        lvl = vp8_clip(lvl, 63)
        let o = (s * 2 + i4x4) * 3
        if lvl > 0 {
          let mut ilevel = lvl
          if sharpness > 0 {
            if sharpness > 4 {
              ilevel = ilevel >> 2
            } else {
              ilevel = ilevel >> 1
            }
            if ilevel > 9 - sharpness {
              ilevel = 9 - sharpness
            }
          }
          if ilevel < 1 {
            ilevel = 1
          }
          dec.fstrength[o] = 2 * lvl + ilevel
          dec.fstrength[o + 1] = ilevel
          dec.fstrength[o + 2] = if lvl >= 40 {
            2
          } else if lvl >= 15 {
            1
          } else {
            0
          }
        } else {
          dec.fstrength[o] = 0
        }
      }
    }
  }
  (use_segment, absolute, quantizer)
}

///|
fn vp8_parse_quant(
  dec : VP8Decoder,
  br : VP8BoolReader,
  use_segment : Bool,
  absolute : Bool,
  quantizer : FixedArray[Int32],
) -> Unit {
  let base_q0 = br.get_value(7)
  let delta = fn() {
    if br.get_bit(0x80) == 1 {
      br.get_signed_value(4)
    } else {
      0
    }
  }
  let dqy1_dc = delta()
  let dqy2_dc = delta()
  let dqy2_ac = delta()
  let dquv_dc = delta()
  let dquv_ac = delta()
  for i in 0..<4 {
    let q = if use_segment {
      if absolute {
        quantizer[i]
      } else {
        quantizer[i] + base_q0
      }
    } else {
      base_q0
    }
    let o = i * 6
    dec.dq[o] = vp8_dc_table[vp8_clip(q + dqy1_dc, 127)]
    dec.dq[o + 1] = vp8_ac_table[vp8_clip(q, 127)]
    dec.dq[o + 2] = vp8_dc_table[vp8_clip(q + dqy2_dc, 127)] * 2
    let y2ac = (vp8_ac_table[vp8_clip(q + dqy2_ac, 127)] * 101581) >> 16
    dec.dq[o + 3] = if y2ac < 8 { 8 } else { y2ac }
    dec.dq[o + 4] = vp8_dc_table[vp8_clip(q + dquv_dc, 117)]
    dec.dq[o + 5] = vp8_ac_table[vp8_clip(q + dquv_ac, 127)]
  }
}

///|
fn vp8_parse_proba(dec : VP8Decoder, br : VP8BoolReader) -> Unit {
  for i in 0..<(4 * 8 * 33) {
    dec.proba[i] = if br.get_bit(vp8_coeffs_update_proba[i]) == 1 {
      br.get_value(8)
    } else {
      vp8_coeffs_proba0[i]
    }
  }
  dec.use_skip = br.get_bit(0x80) == 1
  if dec.use_skip {
    dec.skip_p = br.get_value(8)
  }
}

///|
/// Decode a VP8 key frame into Y / U / V planes (macroblock-padded).
/// Returns (width, height, y, u, v, y_stride, uv_stride).
fn vp8_decode_yuv(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> (
  Int32,
  Int32,
  FixedArray[Byte],
  FixedArray[Byte],
  FixedArray[Byte],
  Int32,
  Int32,
) raise DecodeError {
  if end - start < 10 {
    raise CorruptData("truncated WebP lossy header")
  }
  let bits = data[start].to_int() |
    (data[start + 1].to_int() << 8) |
    (data[start + 2].to_int() << 16)
  if (bits & 1) != 0 {
    raise UnsupportedFeature("WebP lossy frame is not a key frame")
  }
  if ((bits >> 1) & 7) > 3 {
    raise CorruptData("invalid VP8 profile")
  }
  if ((bits >> 4) & 1) == 0 {
    raise UnsupportedFeature("VP8 frame not displayable")
  }
  let partition_length = bits >> 5
  if data[start + 3] != b'\x9d' ||
    data[start + 4] != b'\x01' ||
    data[start + 5] != b'\x2a' {
    raise CorruptData("invalid VP8 start code")
  }
  let width = (data[start + 6].to_int() | (data[start + 7].to_int() << 8)) &
    0x3fff
  let height = (data[start + 8].to_int() | (data[start + 9].to_int() << 8)) &
    0x3fff
  check_decode_size(width, height)
  let mb_w = (width + 15) >> 4
  let mb_h = (height + 15) >> 4
  let p0 = start + 10
  if partition_length > end - p0 {
    raise CorruptData("VP8 partition 0 exceeds the data")
  }
  let dec : VP8Decoder = {
    mb_w,
    mb_h,
    proba: FixedArray::make(4 * 8 * 33, 0),
    segment_probs: FixedArray::make(3, 255),
    use_skip: false,
    skip_p: 0,
    update_map: false,
    dq: FixedArray::make(24, 0),
    fstrength: FixedArray::make(24, 0),
    filter_type: 0,
  }
  let br = VP8BoolReader::new(data, p0, p0 + partition_length)
  let (use_segment, absolute, quantizer) = vp8_parse_header(dec, br)
  if br.eof {
    raise CorruptData("truncated VP8 frame header")
  }
  // Token partitions.
  let num_parts = 1 << br.get_value(2)
  let sizes_at = p0 + partition_length
  let mut part_start = sizes_at + 3 * (num_parts - 1)
  if part_start > end {
    raise CorruptData("VP8 partition sizes truncated")
  }
  let parts : Array[VP8BoolReader] = []
  for p in 0..<(num_parts - 1) {
    let o = sizes_at + 3 * p
    let mut psize = data[o].to_int() |
      (data[o + 1].to_int() << 8) |
      (data[o + 2].to_int() << 16)
    if psize > end - part_start {
      psize = end - part_start
    }
    parts.push(VP8BoolReader::new(data, part_start, part_start + psize))
    part_start += psize
  }
  if part_start >= end {
    raise CorruptData("VP8 token partition truncated")
  }
  parts.push(VP8BoolReader::new(data, part_start, end))
  vp8_parse_quant(dec, br, use_segment, absolute, quantizer)
  ignore(br.get_bit(0x80)) // refresh entropy probabilities (ignored)
  vp8_parse_proba(dec, br)
  let y_stride = mb_w * 16
  let uv_stride = mb_w * 8
  let yp = FixedArray::make(y_stride * mb_h * 16, b'\x00')
  let up = FixedArray::make(uv_stride * mb_h * 8, b'\x00')
  let vp = FixedArray::make(uv_stride * mb_h * 8, b'\x00')
  vp8_decode_frame(dec, br, parts, yp, up, vp)
  (width, height, yp, up, vp, y_stride, uv_stride)
}

///|
fn vp8_nz_code(nz_coeffs : Int32, nz : Int32, dc_nz : Bool) -> Int32 {
  (nz_coeffs << 2) |
  (if nz > 3 { 3 } else if nz > 1 { 2 } else if dc_nz { 1 } else { 0 })
}

///|
let vp8_y_off = 40

///|
let vp8_u_off = 584

///|
let vp8_v_off = 600

///|
fn vp8_decode_frame(
  dec : VP8Decoder,
  br : VP8BoolReader,
  parts : Array[VP8BoolReader],
  yp : FixedArray[Byte],
  up : FixedArray[Byte],
  vp : FixedArray[Byte],
) -> Unit raise DecodeError {
  let mb_w = dec.mb_w
  let mb_h = dec.mb_h
  let y_stride = mb_w * 16
  let uv_stride = mb_w * 8
  let proba = dec.proba
  // Per-macroblock contexts.
  let intra_t = FixedArray::make(4 * mb_w, 0)
  let intra_l = FixedArray::make(4, 0)
  let mb_nz = FixedArray::make(mb_w, 0)
  let mb_nz_dc = FixedArray::make(mb_w, 0)
  // Row data.
  let is_i4x4 = FixedArray::make(mb_w, false)
  let imodes = FixedArray::make(mb_w * 16, 0)
  let uvmode = FixedArray::make(mb_w, 0)
  let segment = FixedArray::make(mb_w, 0)
  let skip = FixedArray::make(mb_w, false)
  let coeffs = FixedArray::make(mb_w * 384, 0)
  let nzy = FixedArray::make(mb_w, 0)
  let nzuv = FixedArray::make(mb_w, 0)
  // Loop filter parameters for every macroblock: limit, ilevel, hev, inner.
  let finfo = FixedArray::make(mb_w * mb_h * 4, 0)
  // Unfiltered top samples (16 Y + 8 U + 8 V per macroblock).
  let top = FixedArray::make(mb_w * 32, 0)
  let yuv = FixedArray::make(32 * 17 + 32 * 9, 0)
  let dc = FixedArray::make(16, 0)
  let num_parts_mask = parts.length() - 1
  for mb_y in 0..<mb_h {
    // Intra modes for the whole row (partition 0).
    for mb_x in 0..<mb_w {
      segment[mb_x] = if dec.update_map {
        if br.get_bit(dec.segment_probs[0]) == 0 {
          br.get_bit(dec.segment_probs[1])
        } else {
          br.get_bit(dec.segment_probs[2]) + 2
        }
      } else {
        0
      }
      skip[mb_x] = dec.use_skip && br.get_bit(dec.skip_p) == 1
      let i4 = br.get_bit(145) == 0
      is_i4x4[mb_x] = i4
      if !i4 {
        let ymode = if br.get_bit(156) == 1 {
          if br.get_bit(128) == 1 {
            1
          } else {
            3
          }
        } else if br.get_bit(163) == 1 {
          2
        } else {
          0
        }
        imodes[mb_x * 16] = ymode
        for k in 0..<4 {
          intra_t[mb_x * 4 + k] = ymode
          intra_l[k] = ymode
        }
      } else {
        for y in 0..<4 {
          let mut ymode = intra_l[y]
          for x in 0..<4 {
            let prob = (intra_t[mb_x * 4 + x] * 10 + ymode) * 9
            let mut i = vp8_ymodes_intra4[br.get_bit(vp8_bmodes_proba[prob])]
            while i > 0 {
              i = vp8_ymodes_intra4[2 * i +
                br.get_bit(vp8_bmodes_proba[prob + i])]
            }
            ymode = -i
            intra_t[mb_x * 4 + x] = ymode
            imodes[mb_x * 16 + y * 4 + x] = ymode
          }
          intra_l[y] = ymode
        }
      }
      uvmode[mb_x] = if br.get_bit(142) == 0 {
        0
      } else if br.get_bit(114) == 0 {
        2
      } else if br.get_bit(183) == 1 {
        1
      } else {
        3
      }
    }
    if br.eof {
      raise CorruptData("premature end of VP8 partition 0")
    }
    // Residuals.
    let tbr = parts[mb_y & num_parts_mask]
    let mut left_nz = 0
    let mut left_nz_dc = 0
    for mb_x in 0..<mb_w {
      let cbase = mb_x * 384
      let mut all_zero = true
      if !skip[mb_x] {
        coeffs.fill(0, start=cbase, end=cbase + 384)
        let q = segment[mb_x] * 6
        let mut first = 0
        let mut ac_type = 3
        if !is_i4x4[mb_x] {
          dc.fill(0)
          let ctx = mb_nz_dc[mb_x] + left_nz_dc
          let nz = vp8_get_coeffs(
            tbr,
            proba,
            1,
            ctx,
            dec.dq[q + 2],
            dec.dq[q + 3],
            0,
            dc,
            0,
          )
          let has_dc = if nz > 0 { 1 } else { 0 }
          mb_nz_dc[mb_x] = has_dc
          left_nz_dc = has_dc
          if nz > 1 {
            let out = FixedArray::make(256, 0)
            vp8_transform_wht(dc, out)
            for n in 0..<16 {
              coeffs[cbase + n * 16] = out[n * 16]
            }
          } else {
            let dc0 = (dc[0] + 3) >> 3
            for n in 0..<16 {
              coeffs[cbase + n * 16] = dc0
            }
          }
          first = 1
          ac_type = 0
        }
        let mut tnz = mb_nz[mb_x] & 0x0f
        let mut lnz = left_nz & 0x0f
        let mut non_zero_y = 0
        for y in 0..<4 {
          let mut l = lnz & 1
          let mut nz_coeffs = 0
          for x in 0..<4 {
            let ctx = l + (tnz & 1)
            let off = cbase + (y * 4 + x) * 16
            let nz = vp8_get_coeffs(
              tbr,
              proba,
              ac_type,
              ctx,
              dec.dq[q],
              dec.dq[q + 1],
              first,
              coeffs,
              off,
            )
            l = if nz > first { 1 } else { 0 }
            tnz = ((tnz >> 1) | (l << 7)) & 0xff
            nz_coeffs = vp8_nz_code(nz_coeffs, nz, coeffs[off] != 0)
          }
          tnz = tnz >> 4
          lnz = ((lnz >> 1) | (l << 7)) & 0xff
          non_zero_y = (non_zero_y << 8) | nz_coeffs
        }
        let mut out_t_nz = tnz
        let mut out_l_nz = lnz >> 4
        let mut non_zero_uv = 0
        for ch in [0, 2] {
          let mut nz_coeffs = 0
          tnz = mb_nz[mb_x] >> (4 + ch)
          lnz = left_nz >> (4 + ch)
          for y in 0..<2 {
            let mut l = lnz & 1
            for x in 0..<2 {
              let ctx = l + (tnz & 1)
              let off = cbase + (16 + ch * 2 + y * 2 + x) * 16
              let nz = vp8_get_coeffs(
                tbr,
                proba,
                2,
                ctx,
                dec.dq[q + 4],
                dec.dq[q + 5],
                0,
                coeffs,
                off,
              )
              l = if nz > 0 { 1 } else { 0 }
              tnz = ((tnz >> 1) | (l << 3)) & 0xff
              nz_coeffs = vp8_nz_code(nz_coeffs, nz, coeffs[off] != 0)
            }
            tnz = tnz >> 2
            lnz = ((lnz >> 1) | (l << 5)) & 0xff
          }
          non_zero_uv = non_zero_uv | (nz_coeffs << (4 * ch))
          out_t_nz = out_t_nz | (tnz << 4 << ch)
          out_l_nz = out_l_nz | ((lnz & 0xf0) << ch)
        }
        mb_nz[mb_x] = out_t_nz & 0xff
        left_nz = out_l_nz & 0xff
        nzy[mb_x] = non_zero_y
        nzuv[mb_x] = non_zero_uv
        all_zero = (non_zero_y | non_zero_uv) == 0
      } else {
        left_nz = 0
        mb_nz[mb_x] = 0
        if !is_i4x4[mb_x] {
          left_nz_dc = 0
          mb_nz_dc[mb_x] = 0
        }
        nzy[mb_x] = 0
        nzuv[mb_x] = 0
      }
      if dec.filter_type > 0 {
        let fs = (segment[mb_x] * 2 + (if is_i4x4[mb_x] { 1 } else { 0 })) * 3
        let o = (mb_y * mb_w + mb_x) * 4
        finfo[o] = dec.fstrength[fs]
        finfo[o + 1] = dec.fstrength[fs + 1]
        finfo[o + 2] = dec.fstrength[fs + 2]
        finfo[o + 3] = if is_i4x4[mb_x] || !all_zero { 1 } else { 0 }
      }
      if tbr.eof {
        raise CorruptData("premature end of VP8 token partition")
      }
    }
    // Next scanline.
    intra_l.fill(0)
    // Reconstruct the row.
    let yd = vp8_y_off
    let ud = vp8_u_off
    let vd = vp8_v_off
    for j in 0..<16 {
      yuv[yd + j * 32 - 1] = 129
    }
    for j in 0..<8 {
      yuv[ud + j * 32 - 1] = 129
      yuv[vd + j * 32 - 1] = 129
    }
    if mb_y > 0 {
      yuv[yd - 33] = 129
      yuv[ud - 33] = 129
      yuv[vd - 33] = 129
    } else {
      for i in 0..<21 {
        yuv[yd - 33 + i] = 127
      }
      for i in 0..<9 {
        yuv[ud - 33 + i] = 127
        yuv[vd - 33 + i] = 127
      }
    }
    for mb_x in 0..<mb_w {
      if mb_x > 0 {
        for j in -1..<16 {
          for i in 0..<4 {
            yuv[yd + j * 32 - 4 + i] = yuv[yd + j * 32 + 12 + i]
          }
        }
        for j in -1..<8 {
          for i in 0..<4 {
            yuv[ud + j * 32 - 4 + i] = yuv[ud + j * 32 + 4 + i]
            yuv[vd + j * 32 - 4 + i] = yuv[vd + j * 32 + 4 + i]
          }
        }
      }
      let tb = mb_x * 32
      if mb_y > 0 {
        for i in 0..<16 {
          yuv[yd - 32 + i] = top[tb + i]
        }
        for i in 0..<8 {
          yuv[ud - 32 + i] = top[tb + 16 + i]
          yuv[vd - 32 + i] = top[tb + 24 + i]
        }
      }
      let cbase = mb_x * 384
      let bits = nzy[mb_x]
      if is_i4x4[mb_x] {
        let tr = yd - 32 + 16
        if mb_y > 0 {
          if mb_x >= mb_w - 1 {
            for i in 0..<4 {
              yuv[tr + i] = top[tb + 15]
            }
          } else {
            for i in 0..<4 {
              yuv[tr + i] = top[tb + 32 + i]
            }
          }
        }
        for k in 1..<4 {
          for i in 0..<4 {
            yuv[tr + k * 128 + i] = yuv[tr + i]
          }
        }
        for n in 0..<16 {
          let d = yd + (n & 3) * 4 + (n >> 2) * 128
          vp8_predict4(yuv, d, imodes[mb_x * 16 + n])
          if ((bits >> (30 - 2 * n)) & 3) != 0 {
            vp8_transform(coeffs, cbase + n * 16, yuv, d)
          }
        }
      } else {
        vp8_predict_block(
          yuv,
          yd,
          16,
          vp8_check_mode(mb_x, mb_y, imodes[mb_x * 16]),
        )
        if bits != 0 {
          for n in 0..<16 {
            if ((bits >> (30 - 2 * n)) & 3) != 0 {
              let d = yd + (n & 3) * 4 + (n >> 2) * 128
              vp8_transform(coeffs, cbase + n * 16, yuv, d)
            }
          }
        }
      }
      let bits_uv = nzuv[mb_x]
      let mode = vp8_check_mode(mb_x, mb_y, uvmode[mb_x])
      vp8_predict_block(yuv, ud, 8, mode)
      vp8_predict_block(yuv, vd, 8, mode)
      if (bits_uv & 0xff) != 0 {
        for k in 0..<4 {
          vp8_transform(
            coeffs,
            cbase + (16 + k) * 16,
            yuv,
            ud + (k & 1) * 4 + (k >> 1) * 128,
          )
        }
      }
      if ((bits_uv >> 8) & 0xff) != 0 {
        for k in 0..<4 {
          vp8_transform(
            coeffs,
            cbase + (20 + k) * 16,
            yuv,
            vd + (k & 1) * 4 + (k >> 1) * 128,
          )
        }
      }
      if mb_y < mb_h - 1 {
        for i in 0..<16 {
          top[tb + i] = yuv[yd + 15 * 32 + i]
        }
        for i in 0..<8 {
          top[tb + 16 + i] = yuv[ud + 7 * 32 + i]
          top[tb + 24 + i] = yuv[vd + 7 * 32 + i]
        }
      }
      for j in 0..<16 {
        let o = (mb_y * 16 + j) * y_stride + mb_x * 16
        for i in 0..<16 {
          yp[o + i] = yuv[yd + j * 32 + i].to_byte()
        }
      }
      for j in 0..<8 {
        let o = (mb_y * 8 + j) * uv_stride + mb_x * 8
        for i in 0..<8 {
          up[o + i] = yuv[ud + j * 32 + i].to_byte()
          vp[o + i] = yuv[vd + j * 32 + i].to_byte()
        }
      }
    }
  }
  // In-loop filter, in macroblock order.
  if dec.filter_type > 0 {
    for mb_y in 0..<mb_h {
      for mb_x in 0..<mb_w {
        let o = (mb_y * mb_w + mb_x) * 4
        let limit = finfo[o]
        if limit == 0 {
          continue
        }
        let ilevel = finfo[o + 1]
        let hev = finfo[o + 2]
        let inner = finfo[o + 3] == 1
        let y0 = mb_y * 16 * y_stride + mb_x * 16
        if dec.filter_type == 1 {
          if mb_x > 0 {
            vp8_simple_filter(yp, y0, 1, y_stride, limit + 4)
          }
          if inner {
            for k in 1..<4 {
              vp8_simple_filter(yp, y0 + 4 * k, 1, y_stride, limit)
            }
          }
          if mb_y > 0 {
            vp8_simple_filter(yp, y0, y_stride, 1, limit + 4)
          }
          if inner {
            for k in 1..<4 {
              vp8_simple_filter(yp, y0 + 4 * k * y_stride, y_stride, 1, limit)
            }
          }
        } else {
          let c0 = mb_y * 8 * uv_stride + mb_x * 8
          if mb_x > 0 {
            vp8_filter_loop(
              yp,
              y0,
              1,
              y_stride,
              16,
              limit + 4,
              ilevel,
              hev,
              true,
            )
            vp8_filter_loop(
              up,
              c0,
              1,
              uv_stride,
              8,
              limit + 4,
              ilevel,
              hev,
              true,
            )
            vp8_filter_loop(
              vp,
              c0,
              1,
              uv_stride,
              8,
              limit + 4,
              ilevel,
              hev,
              true,
            )
          }
          if inner {
            for k in 1..<4 {
              vp8_filter_loop(
                yp,
                y0 + 4 * k,
                1,
                y_stride,
                16,
                limit,
                ilevel,
                hev,
                false,
              )
            }
            vp8_filter_loop(
              up,
              c0 + 4,
              1,
              uv_stride,
              8,
              limit,
              ilevel,
              hev,
              false,
            )
            vp8_filter_loop(
              vp,
              c0 + 4,
              1,
              uv_stride,
              8,
              limit,
              ilevel,
              hev,
              false,
            )
          }
          if mb_y > 0 {
            vp8_filter_loop(
              yp,
              y0,
              y_stride,
              1,
              16,
              limit + 4,
              ilevel,
              hev,
              true,
            )
            vp8_filter_loop(
              up,
              c0,
              uv_stride,
              1,
              8,
              limit + 4,
              ilevel,
              hev,
              true,
            )
            vp8_filter_loop(
              vp,
              c0,
              uv_stride,
              1,
              8,
              limit + 4,
              ilevel,
              hev,
              true,
            )
          }
          if inner {
            for k in 1..<4 {
              vp8_filter_loop(
                yp,
                y0 + 4 * k * y_stride,
                y_stride,
                1,
                16,
                limit,
                ilevel,
                hev,
                false,
              )
            }
            vp8_filter_loop(
              up,
              c0 + 4 * uv_stride,
              uv_stride,
              1,
              8,
              limit,
              ilevel,
              hev,
              false,
            )
            vp8_filter_loop(
              vp,
              c0 + 4 * uv_stride,
              uv_stride,
              1,
              8,
              limit,
              ilevel,
              hev,
              false,
            )
          }
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// YUV -> RGBA with libwebp's "fancy" upsampling.

///|
fn vp8_mult_hi(v : Int32, coeff : Int32) -> Int32 {
  (v * coeff) >> 8
}

///|
fn vp8_yuv_clip(v : Int32) -> Int32 {
  if (v & -16384) == 0 {
    v >> 6
  } else if v < 0 {
    0
  } else {
    255
  }
}

///|
fn vp8_put_rgb(
  out : FixedArray[Byte],
  o : Int32,
  y : Int32,
  u : Int32,
  v : Int32,
) -> Unit {
  let yy = vp8_mult_hi(y, 19077)
  out[o] = vp8_yuv_clip(yy + vp8_mult_hi(v, 26149) - 14234).to_byte()
  out[o + 1] = vp8_yuv_clip(
    yy - vp8_mult_hi(u, 6419) - vp8_mult_hi(v, 13320) + 8708,
  ).to_byte()
  out[o + 2] = vp8_yuv_clip(yy + vp8_mult_hi(u, 33050) - 17685).to_byte()
  out[o + 3] = b'\xFF'
}

///|
/// Upsample one pair of output rows (`bottom_row` < 0: only the top row)
/// from chroma rows `top_uv` (nearest to the top row) and `cur_uv`.
fn vp8_upsample_pair(
  yp : FixedArray[Byte],
  up : FixedArray[Byte],
  vp : FixedArray[Byte],
  y_stride : Int32,
  uv_stride : Int32,
  width : Int32,
  top_row : Int32,
  bottom_row : Int32,
  top_uv : Int32,
  cur_uv : Int32,
  out : FixedArray[Byte],
) -> Unit {
  let ty = top_row * y_stride
  let by = bottom_row * y_stride
  let tu = top_uv * uv_stride
  let cu = cur_uv * uv_stride
  let to = top_row * width * 4
  let bo = bottom_row * width * 4
  let has_bottom = bottom_row >= 0
  let mut tl_u = up[tu].to_int()
  let mut tl_v = vp[tu].to_int()
  let mut l_u = up[cu].to_int()
  let mut l_v = vp[cu].to_int()
  vp8_put_rgb(
    out,
    to,
    yp[ty].to_int(),
    (3 * tl_u + l_u + 2) >> 2,
    (3 * tl_v + l_v + 2) >> 2,
  )
  if has_bottom {
    vp8_put_rgb(
      out,
      bo,
      yp[by].to_int(),
      (3 * l_u + tl_u + 2) >> 2,
      (3 * l_v + tl_v + 2) >> 2,
    )
  }
  let last_pair = (width - 1) >> 1
  for x in 1..<=last_pair {
    let t_u = up[tu + x].to_int()
    let t_v = vp[tu + x].to_int()
    let c_u = up[cu + x].to_int()
    let c_v = vp[cu + x].to_int()
    let avg_u = tl_u + t_u + l_u + c_u + 8
    let avg_v = tl_v + t_v + l_v + c_v + 8
    let d12_u = (avg_u + 2 * (t_u + l_u)) >> 3
    let d12_v = (avg_v + 2 * (t_v + l_v)) >> 3
    let d03_u = (avg_u + 2 * (tl_u + c_u)) >> 3
    let d03_v = (avg_v + 2 * (tl_v + c_v)) >> 3
    vp8_put_rgb(
      out,
      to + (2 * x - 1) * 4,
      yp[ty + 2 * x - 1].to_int(),
      (d12_u + tl_u) >> 1,
      (d12_v + tl_v) >> 1,
    )
    vp8_put_rgb(
      out,
      to + 2 * x * 4,
      yp[ty + 2 * x].to_int(),
      (d03_u + t_u) >> 1,
      (d03_v + t_v) >> 1,
    )
    if has_bottom {
      vp8_put_rgb(
        out,
        bo + (2 * x - 1) * 4,
        yp[by + 2 * x - 1].to_int(),
        (d03_u + l_u) >> 1,
        (d03_v + l_v) >> 1,
      )
      vp8_put_rgb(
        out,
        bo + 2 * x * 4,
        yp[by + 2 * x].to_int(),
        (d12_u + c_u) >> 1,
        (d12_v + c_v) >> 1,
      )
    }
    tl_u = t_u
    tl_v = t_v
    l_u = c_u
    l_v = c_v
  }
  if (width & 1) == 0 {
    vp8_put_rgb(
      out,
      to + (width - 1) * 4,
      yp[ty + width - 1].to_int(),
      (3 * tl_u + l_u + 2) >> 2,
      (3 * tl_v + l_v + 2) >> 2,
    )
    if has_bottom {
      vp8_put_rgb(
        out,
        bo + (width - 1) * 4,
        yp[by + width - 1].to_int(),
        (3 * l_u + tl_u + 2) >> 2,
        (3 * l_v + tl_v + 2) >> 2,
      )
    }
  }
}

///|
/// Decode an ALPH chunk into a width x height alpha plane.
fn webp_decode_alpha(
  data : Bytes,
  c : WebPChunk,
  width : Int32,
  height : Int32,
) -> FixedArray[Byte] raise DecodeError {
  if c.end - c.start <= 1 {
    raise CorruptData("WebP ALPH chunk too short")
  }
  let hdr = data[c.start].to_int()
  let comp = hdr & 3
  let filter = (hdr >> 2) & 3
  let pre = (hdr >> 4) & 3
  if comp > 1 || pre > 1 || hdr >> 6 != 0 {
    raise CorruptData("invalid WebP ALPH header")
  }
  let n = width * height
  let deltas = FixedArray::make(n, b'\x00')
  if comp == 0 {
    if c.end - c.start - 1 < n {
      raise CorruptData("WebP ALPH data truncated")
    }
    deltas.blit_from_bytes(0, data, c.start + 1, n)
  } else {
    let br = VP8LReader::new(data, c.start + 1, c.end)
    let px = vp8l_decode_stream(br, width, height)
    for i in 0..<n {
      deltas[i] = (px[i] >> 8).to_byte()
    }
  }
  if filter == 0 {
    return deltas
  }
  let out = FixedArray::make(n, b'\x00')
  for y in 0..<height {
    let row = y * width
    if y == 0 || filter == 1 {
      // Horizontal (also the first row of every filter).
      let mut pred = if y == 0 { 0 } else { out[row - width].to_int() }
      for x in 0..<width {
        pred = (pred + deltas[row + x].to_int()) & 0xff
        out[row + x] = pred.to_byte()
      }
    } else if filter == 2 {
      for x in 0..<width {
        out[row + x] = (out[row - width + x].to_int() + deltas[row + x].to_int()).to_byte()
      }
    } else {
      let mut left = out[row - width].to_int()
      let mut top_left = left
      for x in 0..<width {
        let t = out[row - width + x].to_int()
        let g = vp8_clip8(left + t - top_left)
        left = (deltas[row + x].to_int() + g) & 0xff
        top_left = t
        out[row + x] = left.to_byte()
      }
    }
  }
  out
}

///|
/// Decode a VP8 bitstream (with an optional ALPH chunk) to RGBA.
fn vp8_decode_rgba(
  data : Bytes,
  start : Int32,
  end : Int32,
  alpha : WebPChunk?,
) -> FixedArray[Byte] raise DecodeError {
  let (w, h, yp, up, vp, ys, uvs) = vp8_decode_yuv(data, start, end)
  let out = FixedArray::make(w * h * 4, b'\x00')
  vp8_upsample_pair(yp, up, vp, ys, uvs, w, 0, -1, 0, 0, out)
  let mut y = 1
  while y + 1 < h {
    let uv = (y + 1) >> 1
    vp8_upsample_pair(yp, up, vp, ys, uvs, w, y, y + 1, uv - 1, uv, out)
    y += 2
  }
  if (h & 1) == 0 && h > 1 {
    let uv = (h >> 1) - 1
    vp8_upsample_pair(yp, up, vp, ys, uvs, w, h - 1, -1, uv, uv, out)
  }
  match alpha {
    Some(c) => {
      let a = webp_decode_alpha(data, c, w, h)
      for i in 0..<(w * h) {
        out[i * 4 + 3] = a[i]
      }
    }
    None => ()
  }
  out
}
