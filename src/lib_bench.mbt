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
test "bench: AVIF encode 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(encode_avif(img)) catch { _ => () } })
}

///|
test "bench: WebP lossy encode 64x64" (b : @bench.T) {
  let img = make_bench_image()
  b.bench(fn() { b.keep(encode_webp_lossy(img)) catch { _ => () } })
}

///|
test "bench: WebP lossless decode 64x64" (b : @bench.T) {
  let webp = encode_webp(make_bench_image()) catch { _ => panic() }
  b.bench(fn() { b.keep(decode_webp(webp)) catch { _ => () } })
}

///|
test "bench: WebP lossy decode 64x64" (b : @bench.T) {
  b.bench(fn() { b.keep(decode_webp(webp_bench_lossy)) catch { _ => () } })
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

///|
/// The bench image saved by Pillow as lossy WebP (quality 80).
let webp_bench_lossy : Bytes = b"\x52\x49\x46\x46\xEA\x00\x00\x00\x57\x45\x42\x50\x56\x50\x38\x20\xDE\x00\x00\x00\x90\x08\x00\x9D\x01\x2A\x40\x00\x40\x00\x3E\x6D\x30\x92\x46\xB2\x23\x21\xA1\x2C\x08\x02\x40\x0D\x89\x62\x33\x8D\x7A\x04\x80\x00\x52\xD3\x67\xEA\x9F\xE6\x7E\xC0\x00\x92\x7F\xC1\xA0\xC2\xA3\x89\x1D\xE0\x6D\xE6\x43\x87\xED\xC7\xFF\xFF\x53\xA9\xC2\x80\x8A\x65\xFF\xFF\x7D\xC5\x01\x31\x4D\xBC\x79\x37\xDD\x9F\x30\x00\xFE\xFF\xA0\xD4\xEA\x60\x95\x8E\x47\xCE\x86\x2D\x08\xF2\xE3\x54\x2A\x3D\x83\x74\x99\xEA\xFE\xB0\x0F\xAE\x45\x45\xDB\x8D\xD2\xEC\xC3\xCC\xAC\x6B\xBC\x52\x5F\x34\xAB\x28\x95\x7C\x1F\x31\xF0\x79\xEE\x9E\x9F\x0E\x3F\x9A\xD6\xC4\xB9\x6E\xAB\x88\xDF\x40\x0C\xF8\xF5\xCE\xFC\x3F\xDB\x7D\x3F\xDE\x2C\xA2\xDB\x24\xE9\xA6\x5C\xF6\x0E\xA6\x47\x80\x96\xA7\x1E\xAD\xAD\x36\x5C\xA4\x96\x1F\x09\xFC\xED\x3B\xB8\xF6\xAE\x0B\xE2\x46\x6B\x9D\x21\xE2\x5A\x7A\xFB\x69\x9C\x02\xA9\xE1\x12\xFE\xAC\xE6\x16\x0F\x57\x9A\x4C\x67\x31\x59\x70\x6D\x54\x18\xAD\x04\xDE\x11\x14\x3E\x1B\x22\x08\x98\xC0\x00"

///|
fn make_bench_lossy_256() -> Bytes {
  let w = 256
  let h = 256
  let px = FixedArray::make(w * h * 4, b'\xFF')
  let mut s = 1
  for y in 0..<h {
    for x in 0..<w {
      s = (s * 1103515245 + 12345) & 0x7FFFFFFF
      let o = (y * w + x) * 4
      px[o] = (x + (s >> 16) % 16).to_byte()
      px[o + 1] = (y * 2 + (x ^ y) % 7).to_byte()
      px[o + 2] = ((x * y) >> 6).to_byte()
    }
  }
  encode_webp_lossy(
    { width: w, height: h, data: Bytes::from_array(px), },
    quality=75,
  ) catch {
    _ => panic()
  }
}

///|
test "bench: WebP lossy decode 256x256" (b : @bench.T) {
  let webp = make_bench_lossy_256()
  b.bench(fn() { b.keep(decode_webp(webp)) catch { _ => () } })
}

///|
test "bench: WebP lossy decode 256x256 (YUV only)" (b : @bench.T) {
  let webp = make_bench_lossy_256()
  let c = webp_parse(webp) catch { _ => panic() }
  let f = c.frames[0]
  b.bench(fn() {
    b.keep(vp8_decode_yuv(webp, f.image.start, f.image.end)) catch {
      _ => ()
    }
  })
}
