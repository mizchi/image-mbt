// AV1 entropy coding: the MSB-first bit writer used by OBU headers and the
// multi-symbol range encoder (the encoder side of the spec's symbol
// decoder, after libaom / rav1e), with the spec's CDF adaptation.

///|
/// MSB-first bit writer (the spec's f(n) descriptors).
priv struct Av1BitWriter {
  buf : Array[Byte]
  mut acc : Int
  mut nbits : Int
}

///|
fn Av1BitWriter::new() -> Av1BitWriter {
  { buf: [], acc: 0, nbits: 0 }
}

///|
fn Av1BitWriter::put(self : Av1BitWriter, v : Int, n : Int) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.acc = (self.acc << 1) | ((v >> i) & 1)
    self.nbits += 1
    if self.nbits == 8 {
      self.buf.push(self.acc.to_byte())
      self.acc = 0
      self.nbits = 0
    }
  }
}

///|
/// trailing_bits: a one bit, then zeros up to the byte boundary.
fn Av1BitWriter::trailing(self : Av1BitWriter) -> Unit {
  self.put(1, 1)
  while self.nbits != 0 {
    self.put(0, 1)
  }
}

///|
fn Av1BitWriter::byte_align(self : Av1BitWriter) -> Unit {
  while self.nbits != 0 {
    self.put(0, 1)
  }
}

///|
fn Av1BitWriter::bytes(self : Av1BitWriter) -> Array[Byte] {
  self.buf
}

///|
/// leb128 encoding of `v` (OBU sizes).
fn av1_leb128(out : Array[Byte], v : Int) -> Unit {
  let mut x = v
  while true {
    let b = x & 0x7f
    x = x >> 7
    if x != 0 {
      out.push((b | 0x80).to_byte())
    } else {
      out.push(b.to_byte())
      break
    }
  }
}

///|
/// Range encoder state.
priv struct Av1SymWriter {
  precarry : Array[Int]
  mut low : UInt
  mut rng : Int
  mut cnt : Int
}

///|
fn Av1SymWriter::new() -> Av1SymWriter {
  { precarry: [], low: 0U, rng: 0x8000, cnt: -9 }
}

///|
/// Leading zeros of a 16-bit value.
fn av1_clz16(v : Int) -> Int {
  let mut n = 0
  let mut x = v
  while n < 16 && (x & 0x8000) == 0 {
    x = x << 1
    n += 1
  }
  n
}

///|
/// Encode the interval [fl, fh) of an inverse CDF (32768 - cdf) with
/// `nms` symbols at or above the coded one.
fn Av1SymWriter::store(self : Av1SymWriter, fl : Int, fh : Int, nms : Int) -> Unit {
  let r = self.rng
  let u = if fl >= 32768 {
    r
  } else {
    (((r >> 8) * (fl >> 6)) >> 1) + 4 * nms
  }
  let v = (((r >> 8) * (fh >> 6)) >> 1) + 4 * (nms - 1)
  let mut low = (r - u).reinterpret_as_uint() + self.low
  let rr = u - v
  let mut c = self.cnt
  let d = av1_clz16(rr)
  let mut s = c + d
  if s >= 0 {
    c += 16
    let mut m = (1U << c) - 1U
    if s >= 8 {
      self.precarry.push((low >> c).reinterpret_as_int())
      low = low & m
      c -= 8
      m = m >> 8
    }
    self.precarry.push((low >> c).reinterpret_as_int())
    s = c + d - 24
    low = low & m
  }
  self.low = low << d
  self.rng = rr << d
  self.cnt = s
}

///|
/// Encode symbol `s` with the CDF `cdf[off ..< off + n]` (spec layout:
/// increasing, last 32768) and adapt it (count at `cdf[off + n]`).
fn Av1SymWriter::symbol(
  self : Av1SymWriter,
  cdf : FixedArray[Int],
  off : Int,
  n : Int,
  s : Int,
) -> Unit {
  let fl = if s > 0 { 32768 - cdf[off + s - 1] } else { 32768 }
  let fh = 32768 - cdf[off + s]
  self.store(fl, fh, n - s)
  av1_update_cdf(cdf, off, n, s)
}

///|
/// One equiprobable bit (read_bool).
fn Av1SymWriter::bool(self : Av1SymWriter, b : Int) -> Unit {
  // cdf = { 16384, 32768 }
  if b == 0 {
    self.store(32768, 16384, 2)
  } else {
    self.store(16384, 0, 1)
  }
}

///|
/// `n` raw bits, MSB first (read_literal).
fn Av1SymWriter::literal(self : Av1SymWriter, v : Int, n : Int) -> Unit {
  for i = n - 1; i >= 0; i = i - 1 {
    self.bool((v >> i) & 1)
  }
}

///|
/// Flush and return the coded bytes (the decoder's exit_symbol padding
/// rules hold: a final one bit followed by zeros).
fn Av1SymWriter::finish(self : Av1SymWriter) -> Array[Byte] {
  let l = self.low
  let mut c = self.cnt
  let mut s = 10
  let m = 0x3FFFU
  let mut e = ((l + m) & m.lnot()) | (m + 1U)
  s += c
  if s > 0 {
    let mut n = (1U << (c + 16)) - 1U
    while true {
      self.precarry.push((e >> (c + 16)).reinterpret_as_int())
      e = e & n
      s -= 8
      c -= 8
      n = n >> 8
      if s <= 0 {
        break
      }
    }
  }
  let len = self.precarry.length()
  let out = Array::make(len, b'\x00')
  let mut carry = 0
  for i = len - 1; i >= 0; i = i - 1 {
    carry += self.precarry[i]
    out[i] = (carry & 0xff).to_byte()
    carry = carry >> 8
  }
  out
}

///|
/// The spec's CDF adaptation after coding `s` (disable_cdf_update = 0).
fn av1_update_cdf(cdf : FixedArray[Int], off : Int, n : Int, s : Int) -> Unit {
  let cnt = cdf[off + n]
  let rate = 3 +
    (if cnt > 15 { 1 } else { 0 }) +
    (if cnt > 31 { 1 } else { 0 }) +
    (if n >= 4 { 2 } else if n >= 2 { 1 } else { 0 })
  for i in 0..<(n - 1) {
    if i < s {
      cdf[off + i] = cdf[off + i] - (cdf[off + i] >> rate)
    } else {
      cdf[off + i] = cdf[off + i] + ((32768 - cdf[off + i]) >> rate)
    }
  }
  if cnt < 32 {
    cdf[off + n] = cnt + 1
  }
}

///|
/// Cost in 1/256 bit of coding `s` with the CDF at `off` (no update).
fn av1_symbol_cost(cdf : FixedArray[Int], off : Int, s : Int) -> Int {
  let lo = if s > 0 { cdf[off + s - 1] } else { 0 }
  let p = cdf[off + s] - lo
  av1_cost_q15(p)
}

///|
/// -log2(p / 32768) * 256 for p in 1..32768.
fn av1_cost_q15(p : Int) -> Int {
  let pp = if p < 1 { 1 } else { p }
  // 15 * 256 - log2(p) * 256
  3840 - vp8l_log2_fix(pp)
}
