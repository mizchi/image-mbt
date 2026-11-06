// Animation encoders: APNG and animated GIF from an `Animation`
// (every frame is a full RGBA8 canvas, as returned by the decoders).

///|
fn anim_min(a : Int32, b : Int32) -> Int32 {
  if a < b {
    a
  } else {
    b
  }
}

///|
fn anim_max(a : Int32, b : Int32) -> Int32 {
  if a > b {
    a
  } else {
    b
  }
}

///|
fn validate_animation(anim : Animation) -> Unit raise EncodeError {
  if anim.frames.is_empty() {
    raise InvalidData("animation has no frames")
  }
  if anim.width <= 0 || anim.height <= 0 {
    raise InvalidDimensions(
      "width and height must be positive: " +
      anim.width.to_string() +
      "x" +
      anim.height.to_string(),
    )
  }
  for f in anim.frames {
    if f.image.width != anim.width || f.image.height != anim.height {
      raise InvalidDimensions("every frame must be the size of the animation")
    }
    validate_rgba8_image(f.image)
  }
}

///|
/// Bounding box (x, y, w, h) of the pixels that differ between two
/// canvases, or None when they are identical.
fn anim_changed_rect(
  prev : Bytes,
  cur : Bytes,
  width : Int32,
  height : Int32,
) -> (Int32, Int32, Int32, Int32)? {
  let mut x0 = width
  let mut y0 = height
  let mut x1 = -1
  let mut y1 = -1
  for y in 0..<height {
    for x in 0..<width {
      let o = (y * width + x) * 4
      if prev[o] != cur[o] ||
        prev[o + 1] != cur[o + 1] ||
        prev[o + 2] != cur[o + 2] ||
        prev[o + 3] != cur[o + 3] {
        if x < x0 {
          x0 = x
        }
        if x > x1 {
          x1 = x
        }
        if y < y0 {
          y0 = y
        }
        y1 = y
      }
    }
  }
  if x1 < 0 {
    None
  } else {
    Some((x0, y0, x1 - x0 + 1, y1 - y0 + 1))
  }
}

///|
fn be32(v : Int32) -> Bytes {
  Bytes::from_array([
    (v >> 24).to_byte(),
    (v >> 16).to_byte(),
    (v >> 8).to_byte(),
    v.to_byte(),
  ])
}

///|
fn be16(v : Int32) -> Bytes {
  Bytes::from_array([(v >> 8).to_byte(), v.to_byte()])
}

///|
/// Encode an APNG (RGBA8). Frame 0 is the default image; later frames are
/// cropped to the region that changed from the previous frame and drawn with
/// blend_op SOURCE / dispose_op NONE, which reproduces each full canvas.
/// `plays` is written to acTL (0 = forever).
pub fn encode_apng(anim : Animation) -> Bytes raise EncodeError {
  validate_animation(anim)
  let width = anim.width
  let height = anim.height
  let parts : Array[Bytes] = [
    b"\x89PNG\r\n\x1A\n",
    encode_chunk(
      [b'I', b'H', b'D', b'R'],
      be32(width) + be32(height) + b"\x08\x06\x00\x00\x00",
    ),
    encode_chunk(
      [b'a', b'c', b'T', b'L'],
      be32(anim.frames.length()) +
      be32(if anim.plays < 0 { 0 } else { anim.plays }),
    ),
  ]
  let mut seq = 0
  let mut prev : Bytes? = None
  for f in anim.frames {
    let data = f.image.data
    let (x, y, w, h) = match prev {
      None => (0, 0, width, height)
      Some(p) =>
        match anim_changed_rect(p, data, width, height) {
          Some(r) => r
          // Unchanged frame: a 1x1 region that rewrites the same pixel.
          None => (0, 0, 1, 1)
        }
    }
    // Delay as a fraction; fall back to 1/100 s units above 65535 ms.
    let delay = if f.delay_ms < 0 { 0 } else { f.delay_ms }
    let (num, den) = if delay <= 65535 {
      (delay, 1000)
    } else {
      (anim_min((delay + 5) / 10, 65535), 100)
    }
    parts.push(
      encode_chunk(
        [b'f', b'c', b'T', b'L'],
        be32(seq) +
        be32(w) +
        be32(h) +
        be32(x) +
        be32(y) +
        be16(num) +
        be16(den) +
        b"\x00\x00",
      ),
    )
    seq += 1
    let compressed = png_compress_rgba_rect(data, width, x, y, w, h)
    match prev {
      None => parts.push(encode_chunk([b'I', b'D', b'A', b'T'], compressed))
      Some(_) => {
        parts.push(
          encode_chunk([b'f', b'd', b'A', b'T'], be32(seq) + compressed),
        )
        seq += 1
      }
    }
    prev = Some(data)
  }
  parts.push(encode_chunk([b'I', b'E', b'N', b'D'], Bytes::new(0)))
  concat_bytes(parts)
}

///|
/// Encode an animated GIF. Every frame must have at most 256 colors
/// (counting full transparency) and alpha 0 or 255. A global color table is
/// used when all frames fit in one; otherwise each frame gets a local table.
/// Delays are rounded to 1/100 s. `plays`: 0 = loop forever, n = play n
/// times (NETSCAPE loop count n - 1; no loop extension for 1).
///
/// Without transparency, frames after the first are cropped to the changed
/// region (dispose: none). With transparency, every frame is written whole
/// and disposed to background, so transparent pixels stay transparent.
pub fn encode_gif_animation(anim : Animation) -> Bytes raise EncodeError {
  validate_animation(anim)
  let width = anim.width
  let height = anim.height
  if width > 65535 || height > 65535 {
    raise InvalidDimensions("GIF dimensions must be <= 65535")
  }
  // Per-frame palettes (also validates colors / alpha).
  let palettes : Array[GifPaletteData] = []
  for f in anim.frames {
    palettes.push(collect_gif_palette(f.image))
  }
  let has_alpha = palettes.iter().any(fn(p) { p.transparent_index is Some(_) })
  // Try one global palette for every frame. Full transparency gets its
  // own entry (index 0) so it never collides with opaque black.
  let global_map : Map[Int32, Int32] = Map([])
  let global_colors : Array[GifPaletteEntry] = []
  let global_transparent = if has_alpha {
    global_colors.push({ r: 0, g: 0, b: 0, })
    Some(0)
  } else {
    None
  }
  for p in palettes {
    for ci, c in p.colors {
      if p.transparent_index == Some(ci) {
        continue
      }
      let key = gif_color_key(c.r, c.g, c.b)
      if !global_map.contains(key) {
        global_map.set(key, global_colors.length())
        global_colors.push(c)
      }
    }
  }
  let global_ok = global_colors.length() <= 256
  let parts : Array[Bytes] = []
  let gsize = if global_ok {
    gif_next_power_of_two(anim_max(global_colors.length(), 2))
  } else {
    2
  }
  parts.push(encode_gif_logical_screen_descriptor(width, height, gsize, 0))
  parts.push(
    encode_gif_global_color_table(
      if global_ok {
        global_colors
      } else {
        [{ r: 0, g: 0, b: 0, }]
      },
      gsize,
    ),
  )
  // NETSCAPE2.0 loop extension
  if anim.plays != 1 {
    let loops = if anim.plays <= 0 { 0 } else { anim.plays - 1 }
    parts.push(
      b"\x21\xFF\x0BNETSCAPE2.0\x03\x01" +
      Bytes::from_array([loops.to_byte(), (loops >> 8).to_byte()]) +
      b"\x00",
    )
  }
  let mut prev : Bytes? = None
  for i, f in anim.frames {
    let p = palettes[i]
    let data = f.image.data
    // Region to write.
    let (x, y, w, h) = match (has_alpha, prev) {
      (false, Some(pd)) =>
        match anim_changed_rect(pd, data, width, height) {
          Some(r) => r
          None => (0, 0, 1, 1)
        }
      _ => (0, 0, width, height)
    }
    // Indices of the region, in the frame's palette or the global one.
    let colors = if global_ok { global_colors } else { p.colors }
    let transparent = if global_ok {
      if p.transparent_index is Some(_) {
        global_transparent
      } else {
        None
      }
    } else {
      p.transparent_index
    }
    let indices : Array[Int32] = []
    for yy in y..<(y + h) {
      for xx in x..<(x + w) {
        let o = (yy * width + xx) * 4
        if data[o + 3] == b'\x00' {
          indices.push(transparent.unwrap_or(0))
        } else if global_ok {
          indices.push(
            global_map
            .get(
              gif_color_key(
                data[o].to_int(),
                data[o + 1].to_int(),
                data[o + 2].to_int(),
              ),
            )
            .unwrap_or(0),
          )
        } else {
          indices.push(p.indices[yy * width + xx])
        }
      }
    }
    // Graphics Control Extension: disposal, delay, transparency.
    let disposal = if has_alpha { 2 } else { 1 }
    let delay = anim_min((anim_max(f.delay_ms, 0) + 5) / 10, 65535)
    let packed = (disposal << 2) | (if transparent is Some(_) { 1 } else { 0 })
    parts.push(
      Bytes::from_array([
        b'\x21',
        b'\xF9',
        b'\x04',
        packed.to_byte(),
        delay.to_byte(),
        (delay >> 8).to_byte(),
        transparent.unwrap_or(0).to_byte(),
        b'\x00',
      ]),
    )
    // Image descriptor (+ local color table when needed).
    let lsize = gif_next_power_of_two(anim_max(colors.length(), 2))
    let desc = FixedArray::make(10, b'\x00')
    desc[0] = b'\x2C'
    write_u16le(desc, 1, x)
    write_u16le(desc, 3, y)
    write_u16le(desc, 5, w)
    write_u16le(desc, 7, h)
    if !global_ok {
      desc[9] = (0x80 | gif_color_table_size_field(lsize)).to_byte()
    }
    parts.push(Bytes::from_array(desc))
    if !global_ok {
      parts.push(encode_gif_global_color_table(colors, lsize))
    }
    let min_code_size = gif_min_code_size(colors.length())
    parts.push(Bytes::from_array([min_code_size.to_byte()]))
    parts.push(encode_gif_sub_blocks(encode_gif_lzw(indices, min_code_size)))
    prev = Some(data)
  }
  parts.push(b"\x3B")
  concat_bytes(parts)
}
