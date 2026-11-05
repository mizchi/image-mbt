// GIF decoder (GIF87a / GIF89a): LZW, global / local color tables,
// interlaced frames, transparency, and animation with frame disposal.

///|
/// One fully composited animation frame.
pub(all) struct GifFrame {
  /// The whole logical screen after drawing this frame (RGBA8).
  image : ImageData
  /// Display time in milliseconds (Graphics Control Extension delay * 10).
  delay_ms : Int32
}

///|
/// A decoded GIF animation.
pub(all) struct GifAnimation {
  width : Int32
  height : Int32
  frames : Array[GifFrame]
  /// NETSCAPE2.0 loop count: 0 = loop forever, n = repeat n times,
  /// None = no looping extension (play once).
  loop_count : Int32?
}

///|
priv struct GifReader {
  data : Bytes
  mut pos : Int32
}

///|
fn GifReader::u8(self : GifReader) -> Int32 raise DecodeError {
  if self.pos >= self.data.length() {
    raise CorruptData("unexpected end of GIF data")
  }
  let v = self.data[self.pos].to_int()
  self.pos += 1
  v
}

///|
fn GifReader::u16(self : GifReader) -> Int32 raise DecodeError {
  let lo = self.u8()
  lo | (self.u8() << 8)
}

///|
fn GifReader::color_table(
  self : GifReader,
  size : Int32,
) -> FixedArray[Byte] raise DecodeError {
  if self.pos + size * 3 > self.data.length() {
    raise CorruptData("GIF color table truncated")
  }
  let table = FixedArray::make(size * 3, b'\x00')
  table.blit_from_bytes(0, self.data, self.pos, size * 3)
  self.pos += size * 3
  table
}

///|
/// Concatenate data sub-blocks up to (and including) the block terminator.
fn GifReader::sub_blocks(self : GifReader) -> Bytes raise DecodeError {
  let buf = Buffer()
  while true {
    let n = self.u8()
    if n == 0 {
      break
    }
    if self.pos + n > self.data.length() {
      raise CorruptData("GIF data sub-block truncated")
    }
    buf.write_bytesview(self.data[self.pos:self.pos + n])
    self.pos += n
  }
  buf.to_bytes()
}

///|
fn GifReader::skip_sub_blocks(self : GifReader) -> Unit raise DecodeError {
  while true {
    let n = self.u8()
    if n == 0 {
      break
    }
    self.pos += n
  }
}

///|
/// Decode GIF LZW data into exactly `count` color indices. Missing data
/// (truncated streams are common) leaves the remaining indices at 0.
fn gif_lzw_decode(
  data : Bytes,
  min_code_size : Int32,
  count : Int32,
) -> FixedArray[Byte] raise DecodeError {
  if min_code_size < 1 || min_code_size > 11 {
    raise CorruptData("invalid GIF LZW minimum code size")
  }
  let out = FixedArray::make(count, b'\x00')
  let clear = 1 << min_code_size
  let eoi = clear + 1
  let prefix = FixedArray::make(4096, 0)
  let suffix = FixedArray::make(4096, b'\x00')
  let length = FixedArray::make(4096, 0)
  for i in 0..<clear {
    suffix[i] = i.to_byte()
    length[i] = 1
  }
  let mut code_size = min_code_size + 1
  let mut next_code = eoi + 1
  let mut prev = -1
  let mut bit_buf = 0
  let mut bit_count = 0
  let mut pos = 0
  let mut written = 0
  // Write the string for `code` at `written` (strings are stored backwards
  // through `prefix`, so fill from the end).
  let emit = fn(code : Int32) -> Byte {
    let len = length[code]
    let mut c = code
    let mut i = len - 1
    while i >= 0 {
      if written + i < count {
        out[written + i] = suffix[c]
      }
      if i > 0 {
        c = prefix[c]
      }
      i -= 1
    }
    written += len
    suffix[c] // first byte of the string
  }
  while written < count {
    while bit_count < code_size && pos < data.length() {
      bit_buf = bit_buf | (data[pos].to_int() << bit_count)
      bit_count += 8
      pos += 1
    }
    if bit_count < code_size {
      break // truncated
    }
    let code = bit_buf & ((1 << code_size) - 1)
    bit_buf = bit_buf >> code_size
    bit_count -= code_size
    if code == clear {
      code_size = min_code_size + 1
      next_code = eoi + 1
      prev = -1
      continue
    }
    if code == eoi {
      break
    }
    if prev < 0 {
      if code >= clear {
        raise CorruptData("invalid first GIF LZW code")
      }
      ignore(emit(code))
      prev = code
      continue
    }
    let first = if code < next_code {
      emit(code)
    } else if code == next_code {
      // KwKwK: the new string is prev + first byte of prev.
      let f = emit(prev)
      if written < count {
        out[written] = f
      }
      written += 1
      f
    } else {
      raise CorruptData("invalid GIF LZW code")
    }
    if next_code < 4096 {
      prefix[next_code] = prev
      suffix[next_code] = first
      length[next_code] = length[prev] + 1
      next_code += 1
      if next_code == 1 << code_size && code_size < 12 {
        code_size += 1
      }
    }
    prev = code
  }
  out
}

///|
fn gif_signature_ok(data : Bytes) -> Bool {
  data.length() >= 6 &&
  data[0] == b'G' &&
  data[1] == b'I' &&
  data[2] == b'F' &&
  data[3] == b'8' &&
  (data[4] == b'7' || data[4] == b'9') &&
  data[5] == b'a'
}

///|
/// Decode frames, compositing them like browsers do: the canvas starts
/// transparent (the background color is ignored), each frame is drawn over
/// it with its transparent index skipped, and its disposal method is applied
/// before the next frame (2 = clear the frame rectangle, 3 = restore the
/// canvas from before the frame). `max_frames` stops early.
fn decode_gif_impl(
  data : Bytes,
  max_frames : Int32,
) -> GifAnimation raise DecodeError {
  if !gif_signature_ok(data) {
    raise InvalidSignature("not a GIF file")
  }
  let r : GifReader = { data, pos: 6, }
  let width = r.u16()
  let height = r.u16()
  let flags = r.u8()
  ignore(r.u8()) // background color index
  ignore(r.u8()) // pixel aspect ratio
  if width <= 0 || height <= 0 {
    raise CorruptData("invalid GIF dimensions")
  }
  let global_table = if (flags & 0x80) != 0 {
    Some(r.color_table(1 << ((flags & 7) + 1)))
  } else {
    None
  }
  let canvas = FixedArray::make(width * height * 4, b'\x00')
  let frames : Array[GifFrame] = []
  let mut loop_count : Int32? = None
  // Pending Graphics Control Extension for the next image.
  let mut delay = 0
  let mut disposal = 0
  let mut transparent = -1
  while r.pos < data.length() && frames.length() < max_frames {
    match r.u8() {
      0x3B => break // trailer
      0x21 => {
        let label = r.u8()
        if label == 0xF9 {
          // Graphics Control Extension
          let block = r.sub_blocks()
          if block.length() >= 4 {
            let packed = block[0].to_int()
            disposal = (packed >> 2) & 7
            delay = block[1].to_int() | (block[2].to_int() << 8)
            transparent = if (packed & 1) != 0 { block[3].to_int() } else { -1 }
          }
        } else if label == 0xFF {
          // Application extension (NETSCAPE2.0 / ANIMEXTS1.0 loop count)
          let block = r.sub_blocks()
          if block.length() >= 14 &&
            block[0:11].to_owned() == b"NETSCAPE2.0" &&
            block[11] == b'\x01' {
            loop_count = Some(block[12].to_int() | (block[13].to_int() << 8))
          }
        } else {
          r.skip_sub_blocks()
        }
      }
      0x2C => {
        // Image descriptor
        let fx = r.u16()
        let fy = r.u16()
        let fw = r.u16()
        let fh = r.u16()
        let fflags = r.u8()
        let local_table = if (fflags & 0x80) != 0 {
          Some(r.color_table(1 << ((fflags & 7) + 1)))
        } else {
          None
        }
        let interlaced = (fflags & 0x40) != 0
        let table = match local_table {
          Some(t) => t
          None =>
            match global_table {
              Some(t) => t
              None => raise CorruptData("GIF frame without a color table")
            }
        }
        let entries = table.length() / 3
        let min_code_size = r.u8()
        let lzw = r.sub_blocks()
        let indices = gif_lzw_decode(lzw, min_code_size, fw * fh)
        let saved = if disposal == 3 { Some(canvas.copy()) } else { None }
        // Draw
        for row in 0..<fh {
          let y = fy +
            (if interlaced { gif_interlaced_row(row, fh) } else { row })
          if y >= height {
            continue
          }
          for col in 0..<fw {
            let x = fx + col
            if x >= width {
              continue
            }
            let idx = indices[row * fw + col].to_int()
            if idx == transparent {
              continue
            }
            let o = (y * width + x) * 4
            if idx < entries {
              canvas[o] = table[idx * 3]
              canvas[o + 1] = table[idx * 3 + 1]
              canvas[o + 2] = table[idx * 3 + 2]
            } else {
              canvas[o] = b'\x00'
              canvas[o + 1] = b'\x00'
              canvas[o + 2] = b'\x00'
            }
            canvas[o + 3] = b'\xFF'
          }
        }
        frames.push({
          image: { width, height, data: Bytes::from_array(canvas.copy()), },
          delay_ms: delay * 10,
        })
        // Dispose
        match (disposal, saved) {
          (2, _) =>
            for y in fy..<(fy + fh) {
              if y >= height {
                break
              }
              for x in fx..<(fx + fw) {
                if x >= width {
                  break
                }
                let o = (y * width + x) * 4
                for c in 0..<4 {
                  canvas[o + c] = b'\x00'
                }
              }
            }
          (3, Some(prev)) => prev.blit_to(canvas, len=prev.length())
          _ => ()
        }
        delay = 0
        disposal = 0
        transparent = -1
      }
      b => raise CorruptData("unexpected GIF block 0x" + b.to_string(radix=16))
    }
  }
  if frames.is_empty() {
    raise MissingChunk("GIF image data")
  }
  { width, height, frames, loop_count, }
}

///|
/// Map the `row`-th stored row of an interlaced image to its y coordinate
/// (passes: every 8th row from 0, every 8th from 4, every 4th from 2,
/// every 2nd from 1).
fn gif_interlaced_row(row : Int32, height : Int32) -> Int32 {
  let p1 = (height + 7) / 8
  let p2 = (height + 3) / 8
  let p3 = (height + 1) / 4
  if row < p1 {
    row * 8
  } else if row < p1 + p2 {
    (row - p1) * 8 + 4
  } else if row < p1 + p2 + p3 {
    (row - p1 - p2) * 4 + 2
  } else {
    (row - p1 - p2 - p3) * 2 + 1
  }
}

///|
/// Decode the first frame of a GIF (composited on the logical screen).
pub fn decode_gif(data : Bytes) -> ImageData raise DecodeError {
  decode_gif_impl(data, 1).frames[0].image
}

///|
/// Decode every frame of a (possibly animated) GIF. Each frame is the full
/// logical screen after compositing, with its delay.
pub fn decode_gif_frames(data : Bytes) -> GifAnimation raise DecodeError {
  decode_gif_impl(data, 0x7FFFFFFF)
}
