// Scalar implementations of PNG encoder filters Up + Sub — non-wasm.

///|
fn apply_filter_up_impl(row : Bytes, prev : Bytes) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    let raw_val = row[i].to_int()
    let b = prev[i].to_int()
    buf[i] = ((raw_val - b + 256) % 256).to_byte()
  }
  buf
}

///|
fn apply_filter_sub_impl(row : Bytes, bpp : Int) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    let raw_val = row[i].to_int()
    let a = if i >= bpp { row[i - bpp].to_int() } else { 0 }
    buf[i] = ((raw_val - a + 256) % 256).to_byte()
  }
  buf
}
