// Self-checks of the AV1 encoder components (all targets).

///|
/// The spec's symbol decoder (8.2.6), used to check the range encoder.
priv struct Av1TestDecoder {
  data : Array[Byte]
  mut pos : Int32 // bit position
  mut value : Int32
  mut range : Int32
  mut max_bits : Int32
}

///|
fn Av1TestDecoder::bits(self : Av1TestDecoder, n : Int32) -> Int32 {
  let mut x = 0
  for _ in 0..<n {
    let byte = self.pos >> 3
    let bit = if byte < self.data.length() {
      (self.data[byte].to_int() >> (7 - (self.pos & 7))) & 1
    } else {
      0
    }
    x = (x << 1) | bit
    self.pos += 1
  }
  x
}

///|
fn Av1TestDecoder::new(data : Array[Byte]) -> Av1TestDecoder {
  let d = { data, pos: 0, value: 0, range: 1 << 15, max_bits: 0, }
  let sz = data.length()
  let num = if sz * 8 < 15 { sz * 8 } else { 15 }
  let buf = d.bits(num)
  let padded = buf << (15 - num)
  d.value = ((1 << 15) - 1) ^ padded
  d.max_bits = 8 * sz - 15
  d
}

///|
fn Av1TestDecoder::symbol(
  self : Av1TestDecoder,
  cdf : FixedArray[Int32],
  off : Int32,
  n : Int32,
  adapt : Bool,
) -> Int32 {
  let mut cur = self.range
  let mut symbol = -1
  let mut prev = 0
  while true {
    symbol += 1
    prev = cur
    let f = (1 << 15) - cdf[off + symbol]
    cur = ((self.range >> 8) * (f >> 6)) >> 1
    cur += 4 * (n - symbol - 1)
    if self.value >= cur {
      break
    }
  }
  self.range = prev - cur
  self.value = self.value - cur
  let bits = 15 - av1_floor_log2(self.range)
  self.range = self.range << bits
  let avail = if self.max_bits > 0 { self.max_bits } else { 0 }
  let num = if bits < avail { bits } else { avail }
  let new_data = self.bits(num)
  let padded = new_data << (bits - num)
  self.value = padded ^ (((self.value + 1) << bits) - 1)
  self.max_bits = self.max_bits - bits
  if adapt {
    av1_update_cdf(cdf, off, n, symbol)
  }
  symbol
}

///|
test "AV1 range coder round trip" {
  // Random symbols over CDFs of 2..16 symbols, mixed with raw bits.
  let enc_cdf = FixedArray::make(17 * 15, 0)
  for n in 2..<=16 {
    for k in 0..<n {
      enc_cdf[(n - 2) * 17 + k] = 32768 * (k + 1) / n
    }
  }
  let dec_cdf = FixedArray::makei(enc_cdf.length(), fn(i) { enc_cdf[i] })
  let w = Av1SymWriter::new()
  let syms : Array[(Int32, Int32)] = []
  let mut seed = 12345U
  for _ in 0..<5000 {
    seed = seed * 1103515245U + 12345U
    let r = (seed >> 8).reinterpret_as_int()
    let n = 2 + r % 15
    // Skewed symbol choice so the CDFs adapt.
    let s = if (r >> 4) % 3 == 0 { (r >> 8) % n } else { 0 }
    if (r >> 12) % 7 == 0 {
      w.bool(s & 1)
      syms.push((0, s & 1))
    } else {
      w.symbol(enc_cdf, (n - 2) * 17, n, s)
      syms.push((n, s))
    }
  }
  let bytes = w.finish()
  let d = Av1TestDecoder::new(bytes)
  let bool_cdf : FixedArray[Int32] = [16384, 32768, 0]
  for e in syms {
    let (n, s) = e
    let got = if n == 0 {
      d.symbol(bool_cdf, 0, 2, false)
    } else {
      d.symbol(dec_cdf, (n - 2) * 17, n, true)
    }
    assert_eq(got, s)
  }
}

///|
test "AV1 forward transforms invert the decoder's" {
  let mut seed = 99U
  // 64-point sizes keep only the lowest 32 frequencies: not invertible.
  for tx in [0, 1, 2, 3, 5, 6, 7, 8, 9, 10, 13, 14, 15, 16] {
    let w = 1 << av1_tx_width_log2[tx]
    let h = 1 << av1_tx_height_log2[tx]
    let types = if av1_tx_size_sqr_up[tx] >= 3 { [0] } else { [0, 1, 2, 3, 9] }
    for t in types {
      let res = FixedArray::make(w * h, 0)
      for i in 0..<(w * h) {
        seed = seed * 1103515245U + 12345U
        res[i] = ((seed >> 16) % 64U).reinterpret_as_int() - 32
      }
      let coef = FixedArray::make(w * h, 0.0)
      av1_forward_2d(res, tx, t, coef)
      let dq = FixedArray::makei(w * h, fn(i) { coef[i].round().to_int() })
      let back = FixedArray::make(w * h, 0)
      av1_inverse_2d(dq, tx, t, back)
      let mut err = 0
      for i in 0..<(w * h) {
        let e = (back[i] - res[i]).abs()
        if e > err {
          err = e
        }
      }
      // Coefficients are rounded to integers: small errors only.
      assert_true(err <= 2)
    }
  }
}

///|
test "AV1 fast DCT matches the matrix inverse" {
  for n in 2..<=6 {
    let len = 1 << n
    let x = FixedArray::makei(64, fn(i) { (i * 37 % 23 - 11).to_double() })
    let y = FixedArray::make(64, 0.0)
    av1_fwd_1d(0, n, x, y)
    let m = av1_fwd_matrix(0, n)
    for k in 0..<len {
      let mut s = 0.0
      for j in 0..<len {
        s = s + m[k * len + j] * x[j]
      }
      assert_true((s - y[k]).abs() < 0.01 * (1.0 + s.abs()))
    }
  }
}
