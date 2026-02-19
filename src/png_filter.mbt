///|
fn paeth_predictor(a : Int, b : Int, c : Int) -> Int {
  let p = a + b - c
  let pa = if p > a { p - a } else { a - p }
  let pb = if p > b { p - b } else { b - p }
  let pc = if p > c { p - c } else { c - p }
  if pa <= pb && pa <= pc {
    a
  } else if pb <= pc {
    b
  } else {
    c
  }
}

///|
/// Reconstruct a filtered scanline (decode side).
/// `filter_type`: 0=None, 1=Sub, 2=Up, 3=Average, 4=Paeth
fn reconstruct_row(
  filter_type : Int,
  row : Bytes,
  prev : Bytes,
  bpp : Int,
) -> Bytes raise DecodeError {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  match filter_type {
    0 =>
      for i in 0..<len {
        buf[i] = row[i]
      }
    1 =>
      for i in 0..<len {
        let a = if i >= bpp { buf[i - bpp].to_int() } else { 0 }
        buf[i] = ((row[i].to_int() + a) % 256).to_byte()
      }
    2 =>
      for i in 0..<len {
        let b = prev[i].to_int()
        buf[i] = ((row[i].to_int() + b) % 256).to_byte()
      }
    3 =>
      for i in 0..<len {
        let a = if i >= bpp { buf[i - bpp].to_int() } else { 0 }
        let b = prev[i].to_int()
        buf[i] = ((row[i].to_int() + (a + b) / 2) % 256).to_byte()
      }
    4 =>
      for i in 0..<len {
        let a = if i >= bpp { buf[i - bpp].to_int() } else { 0 }
        let b = prev[i].to_int()
        let c = if i >= bpp { prev[i - bpp].to_int() } else { 0 }
        buf[i] = ((row[i].to_int() + paeth_predictor(a, b, c)) % 256).to_byte()
      }
    _ => raise CorruptData("unknown filter type: " + filter_type.to_string())
  }
  Bytes::from_array(buf)
}

///|
/// Apply filter to a row (encode side). Currently only None filter (type 0).
fn filter_row(row : Bytes, _prev : Bytes, _bpp : Int) -> Bytes {
  Bytes::from_array(FixedArray::makei(row.length(), fn(i) { row[i] }))
}

///|
test "paeth_predictor" {
  assert_eq(paeth_predictor(0, 0, 0), 0)
  assert_eq(paeth_predictor(10, 20, 15), 15)
  assert_eq(paeth_predictor(100, 100, 100), 100)
  assert_eq(paeth_predictor(7, 5, 6), 6)
}

///|
test "reconstruct_row filter none" {
  let row = b"\x0A\x14\x1E"
  let prev = Bytes::new(3)
  let result = reconstruct_row(0, row, prev, 1)
  assert_eq(result, b"\x0A\x14\x1E")
}

///|
test "reconstruct_row filter sub" {
  // bpp=1: each byte adds the previous reconstructed byte
  // filtered: [10, 20, 30]
  // reconstructed: [10, 10+20=30, 30+30=60]
  let row = b"\x0A\x14\x1E"
  let prev = Bytes::new(3)
  let result = reconstruct_row(1, row, prev, 1)
  assert_eq(result, b"\x0A\x1E\x3C")
}

///|
test "reconstruct_row filter up" {
  // filtered: [5, 10, 15], prev: [100, 100, 100]
  // reconstructed: [105, 110, 115]
  let row = b"\x05\x0A\x0F"
  let prev = b"\x64\x64\x64"
  let result = reconstruct_row(2, row, prev, 1)
  assert_eq(result, b"\x69\x6E\x73")
}

///|
test "reconstruct_row filter average" {
  // filtered: [10, 20, 30], prev: [0, 0, 0], bpp=1
  // [0]: a=0, b=0, avg=0, out=10
  // [1]: a=10, b=0, avg=5, out=25
  // [2]: a=25, b=0, avg=12, out=42
  let row = b"\x0A\x14\x1E"
  let prev = Bytes::new(3)
  let result = reconstruct_row(3, row, prev, 1)
  assert_eq(result[0].to_int(), 10)
  assert_eq(result[1].to_int(), 25)
  assert_eq(result[2].to_int(), 42)
}

///|
test "reconstruct_row filter paeth" {
  // Paeth with prev all zeros, bpp=1
  // Same as Sub when prev is zero
  let row = b"\x0A\x14\x1E"
  let prev = Bytes::new(3)
  let result = reconstruct_row(4, row, prev, 1)
  assert_eq(result, b"\x0A\x1E\x3C")
}

///|
test "filter_row none" {
  let row = b"\x0A\x14\x1E"
  let prev = Bytes::new(3)
  let result = filter_row(row, prev, 1)
  assert_eq(result, b"\x0A\x14\x1E")
}
