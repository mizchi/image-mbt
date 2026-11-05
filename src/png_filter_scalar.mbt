// Scalar implementations of PNG filters — non-wasm.

///|
/// Decode-side Up reconstruction: buf[i] = (row[i] + prev[i]) mod 256.
fn reconstruct_filter_up_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
) -> Unit {
  let len = row.length()
  for i in 0..<len {
    let b = prev[i].to_int()
    buf[i] = ((row[i].to_int() + b) % 256).to_byte()
  }
}

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
fn apply_filter_sub_impl(row : Bytes, bpp : Int32) -> FixedArray[Byte] {
  let len = row.length()
  let buf = FixedArray::make(len, b'\x00')
  for i in 0..<len {
    let raw_val = row[i].to_int()
    let a = if i >= bpp { row[i - bpp].to_int() } else { 0 }
    buf[i] = ((raw_val - a + 256) % 256).to_byte()
  }
  buf
}

///|
fn reconstruct_filter_sub_impl(
  row : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  reconstruct_sub_range(row, buf, bpp, 0, row.length())
}

///|
fn reconstruct_filter_average_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  reconstruct_average_range(row, prev, buf, bpp, 0, row.length())
}

///|
fn reconstruct_filter_paeth_impl(
  row : Bytes,
  prev : Bytes,
  buf : FixedArray[Byte],
  bpp : Int32,
) -> Unit {
  reconstruct_paeth_range(row, prev, buf, bpp, 0, row.length())
}

///|
fn apply_filter_average_impl(
  row : Bytes,
  prev : Bytes,
  bpp : Int32,
) -> FixedArray[Byte] {
  let buf = FixedArray::make(row.length(), b'\x00')
  apply_average_range(row, prev, buf, bpp, 0, row.length())
  buf
}

///|
fn apply_filter_paeth_impl(
  row : Bytes,
  prev : Bytes,
  bpp : Int32,
) -> FixedArray[Byte] {
  let buf = FixedArray::make(row.length(), b'\x00')
  apply_paeth_range(row, prev, buf, bpp, 0, row.length())
  buf
}

///|
fn filter_sum_impl(buf : FixedArray[Byte]) -> Int32 {
  filter_sum_range(buf, 0, buf.length())
}
