// Animated WebP encoder: VP8X + ANIM + one ANMF per frame, each holding a
// lossless (VP8L) bitstream of the region that changed since the previous
// frame. Frames use "no blend" and "dispose none", so the decoded canvas
// reproduces every input frame exactly.

///|
fn webp_put_le(buf : Buffer, value : Int32, bytes : Int32) -> Unit {
  for i in 0..<bytes {
    buf.write_byte((value >> (8 * i)).to_byte())
  }
}

///|
fn webp_put_chunk(buf : Buffer, tag : String, payload : Bytes) -> Unit {
  for c in tag {
    buf.write_byte(c.to_int().to_byte())
  }
  webp_put_le(buf, payload.length(), 4)
  buf.write_bytes(payload)
  if (payload.length() & 1) == 1 {
    buf.write_byte(b'\x00')
  }
}

///|
fn webp_crop(
  img : ImageData,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
) -> ImageData {
  let out = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    out.blit_from_bytes(
      y * w * 4,
      img.data,
      ((y0 + y) * img.width + x0) * 4,
      w * 4,
    )
  }
  { width: w, height: h, data: Bytes::from_array(out), }
}

///|
/// Encode an animated WebP. Every frame is lossless; frames after the first
/// store only the region that changed. Delays are in milliseconds (up to
/// 2^24 - 1); `plays` is the loop count (0 = forever, at most 65535).
pub fn encode_webp_animation(anim : Animation) -> Bytes raise EncodeError {
  validate_animation(anim)
  let w = anim.width
  let h = anim.height
  if w > 16384 || h > 16384 {
    raise InvalidDimensions(
      "WebP animation dimensions must be <= 16384: " +
      w.to_string() +
      "x" +
      h.to_string(),
    )
  }
  if anim.plays < 0 || anim.plays > 65535 {
    raise InvalidData("WebP loop count must be in 0..65535")
  }
  let mut has_alpha = false
  for f in anim.frames {
    let d = f.image.data
    for i in 0..<(w * h) {
      if d[i * 4 + 3] != b'\xFF' {
        has_alpha = true
        break
      }
    }
  }
  let body = Buffer()
  for c in "WEBP" {
    body.write_byte(c.to_int().to_byte())
  }
  let vp8x = Buffer()
  vp8x.write_byte((if has_alpha { 0x12 } else { 0x02 }).to_byte())
  webp_put_le(vp8x, 0, 3)
  webp_put_le(vp8x, w - 1, 3)
  webp_put_le(vp8x, h - 1, 3)
  webp_put_chunk(body, "VP8X", vp8x.to_bytes())
  let anim_chunk = Buffer()
  webp_put_le(anim_chunk, 0, 4) // background color (ignored by decoders)
  webp_put_le(anim_chunk, anim.plays, 2)
  webp_put_chunk(body, "ANIM", anim_chunk.to_bytes())
  for i, f in anim.frames {
    let (x0, y0, fw, fh) = if i == 0 {
      (0, 0, w, h)
    } else {
      match
        anim_changed_rect(anim.frames[i - 1].image.data, f.image.data, w, h) {
        // Offsets are stored halved, so snap the origin to even values.
        Some((x, y, rw, rh)) => (x & -2, y & -2, rw + (x & 1), rh + (y & 1))
        // Nothing changed: rewrite one unchanged pixel.
        None => (0, 0, 1, 1)
      }
    }
    let payload = encode_webp_lossless_payload(
      webp_crop(f.image, x0, y0, fw, fh),
    )
    let delay = if f.delay_ms < 0 {
      0
    } else if f.delay_ms > 0xFFFFFF {
      0xFFFFFF
    } else {
      f.delay_ms
    }
    let anmf = Buffer()
    webp_put_le(anmf, x0 / 2, 3)
    webp_put_le(anmf, y0 / 2, 3)
    webp_put_le(anmf, fw - 1, 3)
    webp_put_le(anmf, fh - 1, 3)
    webp_put_le(anmf, delay, 3)
    anmf.write_byte(b'\x02') // no blending, dispose none
    webp_put_chunk(anmf, "VP8L", payload)
    webp_put_chunk(body, "ANMF", anmf.to_bytes())
  }
  let b = body.to_bytes()
  let out = Buffer()
  for c in "RIFF" {
    out.write_byte(c.to_int().to_byte())
  }
  webp_put_le(out, b.length(), 4)
  out.write_bytes(b)
  out.to_bytes()
}
