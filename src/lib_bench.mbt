///|
test "package name benchmark" (b : @bench.T) {
  b.bench(fn() { ignore(package_name()) })
}

///|
// Generate a test PNG for benchmarking (64x64 RGBA)
fn make_bench_png() -> Bytes {
  let width = 64
  let height = 64
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      buf[idx] = (x * 4).to_byte()
      buf[idx + 1] = (y * 4).to_byte()
      buf[idx + 2] = ((x + y) * 2).to_byte()
      buf[idx + 3] = b'\xFF'
    }
  }
  let img : ImageData = { width, height, data: Bytes::from_array(buf), }
  encode_png(img) catch {
    _ => panic()
  }
}

///|
fn make_bench_image() -> ImageData {
  let width = 64
  let height = 64
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      buf[idx] = (x * 4).to_byte()
      buf[idx + 1] = (y * 4).to_byte()
      buf[idx + 2] = ((x + y) * 2).to_byte()
      buf[idx + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
fn make_webp_cache_bench_image() -> ImageData {
  let width = 64
  let height = 64
  let buf = FixedArray::make(width * height * 4, b'\x00')
  for y in 0..<height {
    for x in 0..<width {
      let idx = (y * width + x) * 4
      let tile = x % 2 + y % 2 * 2
      match tile {
        0 => {
          buf[idx] = b'\x10'
          buf[idx + 1] = b'\x20'
          buf[idx + 2] = b'\x30'
        }
        1 => {
          buf[idx] = b'\x90'
          buf[idx + 1] = b'\x10'
          buf[idx + 2] = b'\xB0'
        }
        2 => {
          buf[idx] = b'\x12'
          buf[idx + 1] = b'\x34'
          buf[idx + 2] = b'\xF0'
        }
        _ => {
          buf[idx] = b'\xBA'
          buf[idx + 1] = b'\xDA'
          buf[idx + 2] = b'\x55'
        }
      }
      buf[idx + 3] = b'\xFF'
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
test "bench: PNG decode 64x64" (b : @bench.T) {
  let png = make_bench_png()
  b.bench(fn() { b.keep(decode_png(png)) catch { _ => () } })
}

///|
test "bench: PNG encode 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(encode_png(img)) catch { _ => () } })
}

///|
test "bench: JPEG encode 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(encode_jpeg(img)) catch { _ => () } })
}

///|
test "bench: WebP encode 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(encode_webp(img)) catch { _ => () } })
}

///|
test "bench: WebP encode cache-friendly 64x64" (b : @bench.T) {
  let img = make_webp_cache_bench_image()
  b.bench(fn() { b.keep(encode_webp(img)) catch { _ => () } })
}

///|
test "bench: PNG roundtrip 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() {
    try {
      let png = encode_png(img)
      b.keep(decode_png(png))
    } catch {
      _ => ()
    }
  })
}

///|
test "bench: resize nearest 64x64 -> 128x128" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 128, 128, Nearest)) catch { _ => () } })
}

///|
test "bench: resize bilinear 64x64 -> 128x128" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 128, 128, Bilinear)) catch { _ => () } })
}

///|
test "bench: resize bicubic 64x64 -> 128x128" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 128, 128, Bicubic)) catch { _ => () } })
}

///|
test "bench: resize nearest 64x64 -> 32x32" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 32, 32, Nearest)) catch { _ => () } })
}

///|
test "bench: resize bilinear 64x64 -> 32x32" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 32, 32, Bilinear)) catch { _ => () } })
}

///|
test "bench: resize bicubic 64x64 -> 32x32" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(resize(img, 32, 32, Bicubic)) catch { _ => () } })
}

///|
/// 256x256 RGBA "photo-like" image: smooth gradients plus a little noise,
/// so that the adaptive filter selection picks a mix of filter types.
fn make_bench_image_256() -> ImageData {
  let width = 256
  let height = 256
  let buf = FixedArray::make(width * height * 4, b'\x00')
  let mut seed = 1
  for y in 0..<height {
    for x in 0..<width {
      seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
      let noise = (seed >> 16) & 7
      let idx = (y * width + x) * 4
      buf[idx] = (x + noise).to_byte()
      buf[idx + 1] = (y + noise).to_byte()
      buf[idx + 2] = ((x + y) / 2 + noise).to_byte()
      buf[idx + 3] = (255 - noise).to_byte()
    }
  }
  { width, height, data: Bytes::from_array(buf), }
}

///|
/// 256x256 RGB8 PNG where every row uses `filter_type` (bpp = 3).
fn make_bench_rgb_png_256(filter_type : Int32) -> Bytes {
  let img = make_bench_image_256()
  let width = img.width
  let height = img.height
  let stride = width * 3
  let raw = FixedArray::make(height * (stride + 1), b'\x00')
  let mut prev = Bytes::new(stride)
  for y in 0..<height {
    let row_buf = FixedArray::make(stride, b'\x00')
    for x in 0..<width {
      for c in 0..<3 {
        row_buf[x * 3 + c] = img.data[(y * width + x) * 4 + c]
      }
    }
    let row = Bytes::from_array(row_buf)
    let filtered = match filter_type {
      1 => apply_filter_sub(row, prev, 3)
      2 => apply_filter_up(row, prev, 3)
      3 => apply_filter_average(row, prev, 3)
      4 => apply_filter_paeth(row, prev, 3)
      _ => apply_filter_none(row, prev, 3)
    }
    raw[y * (stride + 1)] = filter_type.to_byte()
    for i in 0..<stride {
      raw[y * (stride + 1) + 1 + i] = filtered[i]
    }
    prev = row
  }
  let ihdr = FixedArray::make(13, b'\x00')
  write_u32be(ihdr, 0, width.reinterpret_as_uint())
  write_u32be(ihdr, 4, height.reinterpret_as_uint())
  ihdr[8] = b'\x08'
  ihdr[9] = b'\x02'
  let parts = [
    Bytes::from_array(png_signature),
    encode_chunk([b'\x49', b'\x48', b'\x44', b'\x52'], Bytes::from_array(ihdr)),
    encode_chunk(
      [b'\x49', b'\x44', b'\x41', b'\x54'],
      @zlib.zlib_compress(Bytes::from_array(raw)),
    ),
    encode_chunk([b'\x49', b'\x45', b'\x4E', b'\x44'], Bytes::new(0)),
  ]
  let total = parts.fold(init=0, fn(acc, p) { acc + p.length() })
  let out = FixedArray::make(total, b'\x00')
  let mut pos = 0
  for p in parts {
    out.blit_from_bytes(pos, p, 0, p.length())
    pos += p.length()
  }
  Bytes::from_array(out)
}

///|
test "bench: PNG encode 256x256 RGBA" (b : @bench.T) {
  let img = make_bench_image_256()
  b.bench(fn() { b.keep(encode_png(img)) catch { _ => () } })
}

///|
test "bench: PNG decode 256x256 RGBA" (b : @bench.T) {
  let png = encode_png(make_bench_image_256()) catch { _ => panic() }
  b.bench(fn() { b.keep(decode_png(png)) catch { _ => () } })
}

///|
test "bench: PNG decode 256x256 RGB Sub" (b : @bench.T) {
  let png = make_bench_rgb_png_256(1)
  b.bench(fn() { b.keep(decode_png(png)) catch { _ => () } })
}

///|
test "bench: PNG decode 256x256 RGB Average" (b : @bench.T) {
  let png = make_bench_rgb_png_256(3)
  b.bench(fn() { b.keep(decode_png(png)) catch { _ => () } })
}

///|
test "bench: PNG decode 256x256 RGB Paeth" (b : @bench.T) {
  let png = make_bench_rgb_png_256(4)
  b.bench(fn() { b.keep(decode_png(png)) catch { _ => () } })
}

///|
test "bench: resize bilinear 256x256 -> 512x384" (b : @bench.T) {
  let img = make_bench_image_256()
  b.bench(fn() { b.keep(resize(img, 512, 384, Bilinear)) catch { _ => () } })
}

///|
test "bench: resize bicubic 256x256 -> 160x120" (b : @bench.T) {
  let img = make_bench_image_256()
  b.bench(fn() { b.keep(resize(img, 160, 120, Bicubic)) catch { _ => () } })
}

///|
test "bench: JPEG encode 256x256" (b : @bench.T) {
  let img = make_bench_image_256()
  b.bench(fn() { b.keep(encode_jpeg(img)) catch { _ => () } })
}

///|
test "bench: JPEG decode 256x256" (b : @bench.T) {
  let jpg = encode_jpeg(make_bench_image_256()) catch { _ => panic() }
  b.bench(fn() { b.keep(decode_jpeg(jpg)) catch { _ => () } })
}
