// APNG (animated PNG) decoder: acTL / fcTL / fdAT on top of the PNG
// decoder, with frame disposal and blending composited onto an RGBA canvas.

///|
/// One fully composited animation frame.
pub(all) struct AnimationFrame {
  /// The whole canvas after drawing this frame (RGBA8).
  image : ImageData
  /// Display time in milliseconds.
  delay_ms : Int32
}

///|
/// A decoded animation.
pub(all) struct Animation {
  width : Int32
  height : Int32
  frames : Array[AnimationFrame]
  /// Number of times to play the animation; 0 = forever.
  plays : Int32
}

///|
priv struct ApngFrameControl {
  width : Int32
  height : Int32
  x : Int32
  y : Int32
  delay_ms : Int32
  dispose_op : Int32
  blend_op : Int32
}

///|
fn parse_fctl(data : Bytes) -> ApngFrameControl raise DecodeError {
  if data.length() < 26 {
    raise CorruptData("fcTL too short")
  }
  let num = (data[20].to_int() << 8) | data[21].to_int()
  let den0 = (data[22].to_int() << 8) | data[23].to_int()
  // A denominator of 0 means 1/100 s.
  let den = if den0 == 0 { 100 } else { den0 }
  {
    width: read_i32be(data, 4),
    height: read_i32be(data, 8),
    x: read_i32be(data, 12),
    y: read_i32be(data, 16),
    delay_ms: (num * 1000 + den / 2) / den,
    dispose_op: data[24].to_int(),
    blend_op: data[25].to_int(),
  }
}

///|
/// Blend `src` (straight-alpha RGBA) over `dst` in place at byte offset `o`,
/// with the Porter-Duff OVER operator and rounding to nearest.
fn apng_blend_over(
  dst : FixedArray[Byte],
  o : Int32,
  src : Bytes,
  s : Int32,
) -> Unit {
  let sa = src[s + 3].to_int()
  if sa == 255 {
    for c in 0..<4 {
      dst[o + c] = src[s + c]
    }
    return
  }
  if sa == 0 {
    return
  }
  let da = dst[o + 3].to_int()
  // 255 * out_alpha
  let a255 = sa * 255 + da * (255 - sa)
  for c in 0..<3 {
    let num = src[s + c].to_int() * sa * 255 +
      dst[o + c].to_int() * da * (255 - sa)
    dst[o + c] = ((num + a255 / 2) / a255).to_byte()
  }
  dst[o + 3] = ((a255 + 127) / 255).to_byte()
}

///|
/// Decode every frame of an APNG. Each frame is the whole canvas after
/// compositing (dispose_op: 0 none, 1 clear to transparent, 2 restore the
/// previous canvas; blend_op: 0 source, 1 over), with its delay.
///
/// A PNG without an `acTL` chunk is returned as a single frame. If the
/// default image (IDAT) is not part of the animation (no fcTL before it), it
/// is not included.
pub fn decode_png_frames(raw : Bytes) -> Animation raise DecodeError {
  let chunks = parse_chunks(raw)
  let ihdr = parse_png_ihdr(chunks)
  let width = ihdr.width
  let height = ihdr.height
  let mut palette : Bytes? = None
  let mut trns : Bytes? = None
  let mut actl : (Int32, Int32)? = None
  for chunk in chunks {
    match chunk.chunk_type {
      "PLTE" => palette = Some(chunk.data)
      "tRNS" => trns = Some(chunk.data)
      "acTL" =>
        if chunk.data.length() >= 8 && actl is None {
          actl = Some(
            (
              read_u32be(chunk.data, 0).reinterpret_as_int(),
              read_u32be(chunk.data, 4).reinterpret_as_int(),
            ),
          )
        }
      _ => ()
    }
  }
  let (num_frames, plays) = match actl {
    Some(a) => a
    None =>
      return {
        width,
        height,
        frames: [{ image: decode_png(raw), delay_ms: 0, }],
        plays: 0,
      }
  }
  // Group image data by frame control.
  let controls : Array[ApngFrameControl] = []
  let datas : Array[Array[Bytes]] = []
  for chunk in chunks {
    match chunk.chunk_type {
      "fcTL" => {
        let fc = parse_fctl(chunk.data)
        if fc.width <= 0 ||
          fc.height <= 0 ||
          fc.x < 0 ||
          fc.y < 0 ||
          fc.width > width - fc.x ||
          fc.height > height - fc.y {
          raise CorruptData("APNG frame outside the canvas")
        }
        controls.push(fc)
        datas.push([])
      }
      "IDAT" =>
        // The default image is frame 0 only if an fcTL came before it.
        if controls.length() == 1 {
          datas[0].push(chunk.data)
        }
      "fdAT" =>
        if !controls.is_empty() && chunk.data.length() > 4 {
          datas[datas.length() - 1].push(
            chunk.data[4:chunk.data.length()].to_owned(),
          )
        }
      _ => ()
    }
  }
  if controls.is_empty() {
    raise MissingChunk("fcTL")
  }
  let canvas = FixedArray::make(width * height * 4, b'\x00')
  let frames : Array[AnimationFrame] = []
  let count = if num_frames > 0 && num_frames < controls.length() {
    num_frames
  } else {
    controls.length()
  }
  for i in 0..<count {
    let fc = controls[i]
    if datas[i].is_empty() {
      raise MissingChunk("APNG frame data")
    }
    // dispose_op 2 on the first frame is treated as 1.
    let dispose = if i == 0 && fc.dispose_op == 2 { 1 } else { fc.dispose_op }
    let saved = if dispose == 2 { Some(canvas.copy()) } else { None }
    let frame_ihdr = { ..ihdr, width: fc.width, height: fc.height, }
    decode_png_scanlines(frame_ihdr, datas[i], palette, trns, fn(r, row) {
      let base = ((fc.y + r) * width + fc.x) * 4
      if fc.blend_op == 0 {
        canvas.blit_from_bytes(base, row, 0, fc.width * 4)
      } else {
        for c in 0..<fc.width {
          apng_blend_over(canvas, base + c * 4, row, c * 4)
        }
      }
    })
    frames.push({
      image: { width, height, data: Bytes::from_array(canvas.copy()), },
      delay_ms: fc.delay_ms,
    })
    match (dispose, saved) {
      (1, _) =>
        for r in 0..<fc.height {
          let base = ((fc.y + r) * width + fc.x) * 4
          for b in 0..<(fc.width * 4) {
            canvas[base + b] = b'\x00'
          }
        }
      (2, Some(prev)) => prev.blit_to(canvas, len=prev.length())
      _ => ()
    }
  }
  { width, height, frames, plays, }
}
