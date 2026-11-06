// Mutation fuzz test: every decoder must either succeed or raise
// DecodeError on corrupted input, never panic (out-of-bounds access,
// negative allocation sizes, ...). Mutations are deterministic.

///|
priv struct FuzzRng {
  mut state : UInt64
}

///|
fn FuzzRng::next(self : FuzzRng) -> Int32 {
  // xorshift64*
  let mut x = self.state
  x = x ^ (x >> 12)
  x = x ^ (x << 25)
  x = x ^ (x >> 27)
  self.state = x
  ((x * 0x2545F4914F6CDD1DUL) >> 33).to_int()
}

///|
fn FuzzRng::below(self : FuzzRng, n : Int32) -> Int32 {
  if n <= 0 {
    0
  } else {
    self.next() % n
  }
}

///|
/// Apply 1-4 random mutations to `src`.
fn fuzz_mutate(src : Bytes, rng : FuzzRng) -> Bytes {
  let buf : Array[Byte] = src.to_array()
  let rounds = 1 + rng.below(4)
  for _ in 0..<rounds {
    let len = buf.length()
    if len == 0 {
      buf.push(rng.below(256).to_byte())
      continue
    }
    let p = rng.below(len)
    match rng.below(8) {
      0 => buf[p] = (buf[p].to_int() ^ (1 << rng.below(8))).to_byte() // bit flip
      1 => buf[p] = rng.below(256).to_byte() // random byte
      2 => buf[p] = if rng.below(2) == 0 { b'\x00' } else { b'\xFF' }
      3 => {
        // truncate
        let keep = rng.below(len)
        while buf.length() > keep {
          ignore(buf.pop())
        }
      }
      4 => buf.insert(p, rng.below(256).to_byte()) // insert
      5 => ignore(buf.remove(p)) // delete
      6 => {
        // extreme 16-bit / 32-bit value (lengths, dimensions, counts)
        let n = if rng.below(2) == 0 { 2 } else { 4 }
        let v = match rng.below(4) {
          0 => 0
          1 => -1
          2 => 0x7FFFFFFF
          _ => 0x8000
        }
        for i in 0..<n {
          if p + i < buf.length() {
            buf[p + i] = (v >> (i * 8)).to_byte()
          }
        }
      }
      _ => {
        // duplicate a chunk of bytes (repeats markers / chunks)
        let n = 1 + rng.below(16)
        let end = if p + n < len { p + n } else { len }
        let chunk = buf[p:end].to_owned()
        for i, b in chunk {
          buf.insert(p + i, b)
        }
      }
    }
  }
  Bytes::from_array(buf)
}

///|
/// Run every decoder on `data`; only DecodeError is acceptable.
fn fuzz_decode_all(data : Bytes) -> Unit {
  let sink = fn(_ : Int32) { () }
  sink(decode_png(data).width) catch {
    _ => ()
  }
  sink(decode_png_stream(data, on_row=fn(_, _) { () }).width) catch {
    _ => ()
  }
  sink(decode_jpeg(data).width) catch {
    _ => ()
  }
  sink(decode_bmp(data).width) catch {
    _ => ()
  }
  sink(decode_bmp_stream(data, on_row=fn(_, _) { () }).0) catch {
    _ => ()
  }
  sink(decode_gif_frames(data).frames.length()) catch {
    _ => ()
  }
  sink(decode_ico_all(data).length()) catch {
    _ => ()
  }
  sink(decode_tiff(data).width) catch {
    _ => ()
  }
  sink(decode_tiff_pages(data).length()) catch {
    _ => ()
  }
  sink(decode_webp_frames(data).frames.length()) catch {
    _ => ()
  }
  sink(decode_png_frames(data).frames.length()) catch {
    _ => ()
  }
  sink(decode_image(data).width) catch {
    _ => ()
  }
  sink(decode_image_stream(data, on_row=fn(_, _) { () }).width) catch {
    _ => ()
  }
}

///|
/// Mutations per corpus file for the regular test run.
const FUZZ_ITERATIONS : Int32 = 300

///|
/// Set to true locally to print each case (the last line before a crash
/// identifies the failing input).
const FUZZ_TRACE : Bool = false

///|
fn fuzz_run(iterations : Int32, seed : UInt64) -> Unit {
  for ci, entry in fuzz_corpus {
    let (name, src) = entry
    // The unmodified file must decode cleanly through decode_image.
    ignore(name)
    let rng : FuzzRng = { state: seed + ci.to_uint64() * 0x9E3779B97F4A7C15UL, }
    for it in 0..<iterations {
      if FUZZ_TRACE {
        println("fuzz \{ci} \{name} \{it}")
      }
      fuzz_decode_all(fuzz_mutate(src, rng))
    }
  }
}

///|
test "fuzz: decoders never panic on mutated input" {
  fuzz_run(FUZZ_ITERATIONS, 0x1234_5678UL)
}
