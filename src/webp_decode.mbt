// WebP decoder: RIFF container (simple VP8 / VP8L files and the extended
// VP8X format with ALPH and animation), compositing animated frames like
// libwebp's WebPAnimDecoder.

///|
fn webp_le24(data : Bytes, pos : Int32) -> Int32 {
  data[pos].to_int() |
  (data[pos + 1].to_int() << 8) |
  (data[pos + 2].to_int() << 16)
}

///|
fn webp_le32(data : Bytes, pos : Int32) -> Int32 {
  webp_le24(data, pos) | (data[pos + 3].to_int() << 24)
}

///|
fn webp_signature_ok(data : Bytes) -> Bool {
  data.length() >= 12 &&
  data[0] == b'R' &&
  data[1] == b'I' &&
  data[2] == b'F' &&
  data[3] == b'F' &&
  data[8] == b'W' &&
  data[9] == b'E' &&
  data[10] == b'B' &&
  data[11] == b'P'
}

///|
priv struct WebPChunk {
  tag : String
  start : Int32
  end : Int32
}

///|
/// Split `data[start:end]` into chunks (payloads are padded to even size).
fn webp_chunks(
  data : Bytes,
  start : Int32,
  end : Int32,
) -> Array[WebPChunk] raise DecodeError {
  let chunks : Array[WebPChunk] = []
  let mut pos = start
  while pos + 8 <= end {
    let size = webp_le32(data, pos + 4)
    if size < 0 || size > end - pos - 8 {
      raise CorruptData("WebP chunk exceeds its container")
    }
    let tag = String::from_array([
      data[pos].to_char(),
      data[pos + 1].to_char(),
      data[pos + 2].to_char(),
      data[pos + 3].to_char(),
    ])
    chunks.push({ tag, start: pos + 8, end: pos + 8 + size, })
    pos = pos + 8 + size + (size & 1)
  }
  chunks
}

///|
priv struct WebPFrame {
  x : Int32
  y : Int32
  width : Int32
  height : Int32
  duration : Int32
  dispose_background : Bool
  blend : Bool
  // Bitstream: (VP8 or VP8L chunk, optional ALPH chunk)
  image : WebPChunk
  alpha : WebPChunk?
}

///|
priv struct WebPContainer {
  width : Int32
  height : Int32
  animated : Bool
  loop_count : Int32
  frames : Array[WebPFrame]
}

///|
fn webp_frame_from_chunks(
  chunks : Array[WebPChunk],
) -> (WebPChunk, WebPChunk?) raise DecodeError {
  let mut alpha : WebPChunk? = None
  for c in chunks {
    match c.tag {
      "ALPH" => if alpha is None { alpha = Some(c) }
      "VP8 " => return (c, alpha)
      "VP8L" => return (c, None)
      _ => ()
    }
  }
  raise MissingChunk("WebP image data (VP8 / VP8L)")
}

///|
fn webp_parse(data : Bytes) -> WebPContainer raise DecodeError {
  if !webp_signature_ok(data) {
    raise InvalidSignature("not a WebP file")
  }
  let riff_size = webp_le32(data, 4)
  if riff_size < 4 || riff_size > data.length() - 8 {
    raise CorruptData("WebP RIFF size exceeds the file")
  }
  let chunks = webp_chunks(data, 12, 8 + riff_size)
  if chunks.is_empty() {
    raise MissingChunk("WebP image data")
  }
  let first = chunks[0]
  if first.tag != "VP8X" {
    let (image, alpha) = webp_frame_from_chunks(chunks)
    let (w, h) = webp_bitstream_size(data, image)
    check_decode_size(w, h)
    return {
      width: w,
      height: h,
      animated: false,
      loop_count: 0,
      frames: [
        {
          x: 0,
          y: 0,
          width: w,
          height: h,
          duration: 0,
          dispose_background: false,
          blend: false,
          image,
          alpha,
        },
      ],
    }
  }
  if first.end - first.start < 10 {
    raise CorruptData("WebP VP8X chunk too short")
  }
  let flags = data[first.start].to_int()
  let width = webp_le24(data, first.start + 4) + 1
  let height = webp_le24(data, first.start + 7) + 1
  check_decode_size(width, height)
  let rest = chunks[1:].to_owned()
  if (flags & 0x02) == 0 {
    let (image, alpha) = webp_frame_from_chunks(rest)
    let (w, h) = webp_bitstream_size(data, image)
    if w != width || h != height {
      raise CorruptData("WebP image size differs from the canvas")
    }
    return {
      width,
      height,
      animated: false,
      loop_count: 0,
      frames: [
        {
          x: 0,
          y: 0,
          width,
          height,
          duration: 0,
          dispose_background: false,
          blend: false,
          image,
          alpha,
        },
      ],
    }
  }
  let mut loop_count = 0
  let frames : Array[WebPFrame] = []
  for c in rest {
    match c.tag {
      "ANIM" =>
        if c.end - c.start >= 6 {
          loop_count = data[c.start + 4].to_int() |
            (data[c.start + 5].to_int() << 8)
        }
      "ANMF" => {
        if c.end - c.start < 16 {
          raise CorruptData("WebP ANMF chunk too short")
        }
        let p = c.start
        let fx = webp_le24(data, p) * 2
        let fy = webp_le24(data, p + 3) * 2
        let fw = webp_le24(data, p + 6) + 1
        let fh = webp_le24(data, p + 9) + 1
        let duration = webp_le24(data, p + 12)
        let fflags = data[p + 15].to_int()
        if fx + fw > width || fy + fh > height {
          raise CorruptData("WebP frame outside the canvas")
        }
        let (image, alpha) = webp_frame_from_chunks(
          webp_chunks(data, p + 16, c.end),
        )
        let (w, h) = webp_bitstream_size(data, image)
        if w != fw || h != fh {
          raise CorruptData("WebP frame size differs from its bitstream")
        }
        frames.push({
          x: fx,
          y: fy,
          width: fw,
          height: fh,
          duration,
          dispose_background: (fflags & 1) != 0,
          blend: (fflags & 2) == 0,
          image,
          alpha,
        })
      }
      _ => ()
    }
  }
  if frames.is_empty() {
    raise MissingChunk("WebP ANMF frame")
  }
  { width, height, animated: true, loop_count, frames, }
}

///|
/// Width and height from a VP8 / VP8L bitstream header.
fn webp_bitstream_size(
  data : Bytes,
  c : WebPChunk,
) -> (Int32, Int32) raise DecodeError {
  let p = c.start
  if c.tag == "VP8L" {
    if c.end - p < 5 || data[p] != b'\x2f' {
      raise CorruptData("invalid WebP lossless header")
    }
    let bits = webp_le32(data, p + 1)
    ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1)
  } else {
    if c.end - p < 10 ||
      data[p + 3] != b'\x9d' ||
      data[p + 4] != b'\x01' ||
      data[p + 5] != b'\x2a' {
      raise CorruptData("invalid WebP lossy header")
    }
    (
      (data[p + 6].to_int() | (data[p + 7].to_int() << 8)) & 0x3fff,
      (data[p + 8].to_int() | (data[p + 9].to_int() << 8)) & 0x3fff,
    )
  }
}

///|
/// Decode one frame's bitstream to RGBA. Returns (rgba, has_alpha).
fn webp_decode_frame(
  data : Bytes,
  f : WebPFrame,
) -> (FixedArray[Byte], Bool) raise DecodeError {
  if f.image.tag == "VP8L" {
    let (w, h, has_alpha, px) = vp8l_decode(data, f.image.start, f.image.end)
    let out = FixedArray::make(w * h * 4, b'\x00')
    for i in 0..<(w * h) {
      let argb = px[i]
      out[i * 4] = (argb >> 16).to_byte()
      out[i * 4 + 1] = (argb >> 8).to_byte()
      out[i * 4 + 2] = argb.to_byte()
      out[i * 4 + 3] = (argb >> 24).to_byte()
    }
    (out, has_alpha)
  } else {
    let out = vp8_decode_rgba(data, f.image.start, f.image.end, f.alpha)
    (out, f.alpha is Some(_))
  }
}

///|
/// Blend non-premultiplied `src` over `dst` (libwebp's integer formula).
fn webp_blend_pixel(
  canvas : FixedArray[Byte],
  o : Int32,
  prev : FixedArray[Byte],
) -> Unit {
  let src_a = canvas[o + 3].to_int()
  if src_a == 255 {
    return
  }
  if src_a == 0 {
    for c in 0..<4 {
      canvas[o + c] = prev[o + c]
    }
    return
  }
  let dst_a = prev[o + 3].to_int()
  let dst_factor = (dst_a * (256 - src_a)) >> 8
  let blend_a = src_a + dst_factor
  let scale = (1 << 24) / blend_a
  for c in 0..<3 {
    let v = canvas[o + c].to_int() * src_a + prev[o + c].to_int() * dst_factor
    canvas[o + c] = ((v.to_uint64() * scale.to_uint64()) >> 24).to_byte()
  }
  canvas[o + 3] = blend_a.to_byte()
}

///|
fn webp_decode_impl(
  data : Bytes,
  max_frames : Int32,
) -> Animation raise DecodeError {
  let c = webp_parse(data)
  let w = c.width
  let h = c.height
  let size = w * h * 4
  let canvas = FixedArray::make(size, b'\x00')
  let disposed = FixedArray::make(size, b'\x00')
  let frames : Array[AnimationFrame] = []
  let mut prev : WebPFrame? = None
  let mut prev_key = false
  for i, f in c.frames {
    if i >= max_frames {
      break
    }
    let (rgba, has_alpha) = webp_decode_frame(data, f)
    let full = f.width == w && f.height == h
    let key = match prev {
      None => true
      Some(p) =>
        ((!has_alpha || !f.blend) && full) ||
        (p.dispose_background && ((p.width == w && p.height == h) || prev_key))
    }
    if key {
      canvas.fill(b'\x00')
    } else {
      disposed.blit_to(canvas, len=size)
    }
    for y in 0..<f.height {
      let src = y * f.width * 4
      let dst = ((f.y + y) * w + f.x) * 4
      rgba.blit_to(canvas, len=f.width * 4, src_offset=src, dst_offset=dst)
    }
    if i > 0 && f.blend && !key {
      let p = prev.unwrap()
      for y in 0..<f.height {
        let cy = f.y + y
        for x in f.x..<(f.x + f.width) {
          // After a background disposal, pixels of the previous rectangle
          // blend with transparency, which leaves them unchanged.
          if p.dispose_background &&
            cy >= p.y &&
            cy < p.y + p.height &&
            x >= p.x &&
            x < p.x + p.width {
            continue
          }
          webp_blend_pixel(canvas, (cy * w + x) * 4, disposed)
        }
      }
    }
    frames.push({
      image: { width: w, height: h, data: Bytes::from_array(canvas.copy()), },
      delay_ms: f.duration,
    })
    canvas.blit_to(disposed, len=size)
    if f.dispose_background {
      for y in f.y..<(f.y + f.height) {
        disposed.fill(
          b'\x00',
          start=(y * w + f.x) * 4,
          end=(y * w + f.x + f.width) * 4,
        )
      }
    }
    prev = Some(f)
    prev_key = key
  }
  let plays = if c.animated { c.loop_count } else { 1 }
  { width: w, height: h, frames, plays, }
}

///|
/// Decode a WebP image (lossy, lossless, with alpha; the first frame of an
/// animation, composited on the canvas).
pub fn decode_webp(data : Bytes) -> ImageData raise DecodeError {
  webp_decode_impl(data, 1).frames[0].image
}

///|
/// Decode every frame of a (possibly animated) WebP. Each frame is the full
/// canvas after compositing; `plays` is the loop count (0 = forever).
pub fn decode_webp_frames(data : Bytes) -> Animation raise DecodeError {
  webp_decode_impl(data, 0x7FFFFFFF)
}
