///|
/// Deterministic test frames: a moving square over a gradient. `alpha`
/// makes the background transparent; `colors` limits the palette.
fn anim_test_frames(
  w : Int32,
  h : Int32,
  n : Int32,
  alpha : Bool,
  many_colors : Bool,
) -> @image.Animation {
  let frames : Array[@image.AnimationFrame] = []
  for i in 0..<n {
    let buf = FixedArray::make(w * h * 4, b'\x00')
    for y in 0..<h {
      for x in 0..<w {
        let o = (y * w + x) * 4
        let inside = x >= i * 2 && x < i * 2 + 4 && y >= i && y < i + 3
        if inside {
          buf[o] = b'\xF0'
          buf[o + 1] = (40 * i).to_byte()
          buf[o + 2] = b'\x20'
          buf[o + 3] = b'\xFF'
        } else if alpha && (x + y) % 3 == 0 {
          () // fully transparent
        } else {
          let k = if many_colors {
            (x * 7 + y * 13 + i * 31) % 256
          } else {
            (x + y) % 6 * 40
          }
          buf[o] = k.to_byte()
          buf[o + 1] = (if many_colors {
            (x * y + i * 50) % 256
          } else {
            k / 2
          }).to_byte()
          buf[o + 2] = (255 - k).to_byte()
          buf[o + 3] = b'\xFF'
        }
      }
    }
    frames.push({
      image: { width: w, height: h, data: Bytes::from_array(buf), },
      delay_ms: 30 + i * 20,
    })
  }
  { width: w, height: h, frames, plays: 3, }
}

///|
test "encode_apng round-trips through decode_png_frames" {
  for alpha in [false, true] {
    let anim = anim_test_frames(17, 11, 5, alpha, true)
    // An unchanged frame in the middle.
    anim.frames.insert(2, anim.frames[1])
    let png = @image.encode_apng(anim)
    let back = @image.decode_png_frames(png)
    assert_eq(back.width, 17)
    assert_eq(back.height, 11)
    assert_eq(back.plays, 3)
    assert_eq(back.frames.length(), anim.frames.length())
    for i, f in anim.frames {
      assert_eq(back.frames[i].image, f.image)
      assert_eq(back.frames[i].delay_ms, f.delay_ms)
    }
    // decode_png sees the first frame as the default image.
    assert_eq(@image.decode_png(png), anim.frames[0].image)
  }
}

///|
test "encode_gif_animation round-trips through decode_gif_frames" {
  // (alpha, many colors): global palette, transparency, local palettes.
  for case_ in [(false, false), (true, false), (false, true), (true, true)] {
    let (alpha, many) = case_
    let anim = anim_test_frames(19, 13, 4, alpha, many)
    anim.frames.insert(1, anim.frames[0])
    let gif = @image.encode_gif_animation(anim)
    let back = @image.decode_gif_frames(gif)
    assert_eq(back.width, 19)
    assert_eq(back.height, 13)
    assert_eq(back.plays, 3) // written as NETSCAPE loop 2
    assert_eq(back.frames.length(), anim.frames.length())
    for i, f in anim.frames {
      assert_eq(back.frames[i].image, f.image)
      assert_eq(back.frames[i].delay_ms, (f.delay_ms + 5) / 10 * 10)
    }
  }
}

///|
test "encode_gif_animation loop count mapping and validation" {
  let anim = anim_test_frames(4, 3, 2, false, false)
  let forever = @image.decode_gif_frames(
    @image.encode_gif_animation({ ..anim, plays: 0, }),
  )
  assert_eq(forever.plays, 0)
  let once = @image.decode_gif_frames(
    @image.encode_gif_animation({ ..anim, plays: 1, }),
  )
  assert_eq(once.plays, 1)
  // Mismatched frame size and partial alpha are rejected.
  let bad_size : @image.Animation = {
    ..anim,
    frames: [
      {
        image: { width: 1, height: 1, data: b"\x00\x00\x00\xFF", },
        delay_ms: 0,
      },
    ],
  }
  let r = Ok(@image.encode_gif_animation(bad_size)) catch { e => Err(e) }
  assert_true(r is Err(@image.InvalidDimensions(_)))
  let semi : @image.Animation = {
    ..anim,
    frames: [
      {
        image: { width: 4, height: 3, data: Bytes::make(48, b'\x80'), },
        delay_ms: 0,
      },
    ],
  }
  let r2 = Ok(@image.encode_gif_animation(semi)) catch { e => Err(e) }
  assert_true(r2 is Err(@image.InvalidData(_)))
  let empty : @image.Animation = { ..anim, frames: [], }
  let r3 = Ok(@image.encode_apng(empty)) catch { e => Err(e) }
  assert_true(r3 is Err(@image.InvalidData(_)))
}

///|
test "encode_gif LZW: large 256-color image round-trips and compresses" {
  let w = 200
  let h = 150
  let buf = FixedArray::make(w * h * 4, b'\xFF')
  let mut seed = 5
  for i in 0..<(w * h) {
    seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
    // 256 distinct colors; runs make the dictionary grow past 4096 codes.
    let c = if i % 7 < 3 { (seed >> 16) & 0xFF } else { i / 9 % 256 }
    buf[i * 4] = c.to_byte()
    buf[i * 4 + 1] = (255 - c).to_byte()
    buf[i * 4 + 2] = (c * 3).to_byte()
  }
  let img : @image.ImageData = {
    width: w,
    height: h,
    data: Bytes::from_array(buf),
  }
  let gif = @image.encode_gif(img)
  assert_eq(@image.decode_gif(gif), img)
  // A flat image compresses far below one code per pixel.
  let flat : @image.ImageData = {
    width: w,
    height: h,
    data: Bytes::make(w * h * 4, b'\xFF'),
  }
  assert_true(@image.encode_gif(flat).length() < 1000)
}
