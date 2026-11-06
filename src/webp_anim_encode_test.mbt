///|
fn webp_anim_test_frame(
  w : Int32,
  h : Int32,
  seed : Int32,
  alpha : Bool,
) -> @image.ImageData {
  let px = FixedArray::make(w * h * 4, b'\x00')
  for y in 0..<h {
    for x in 0..<w {
      let o = (y * w + x) * 4
      px[o] = (x * 13 + seed * 7).to_byte()
      px[o + 1] = (y * 29 + seed).to_byte()
      px[o + 2] = (x * y + seed * 3).to_byte()
      px[o + 3] = if alpha { ((x + y + seed) * 37).to_byte() } else { b'\xFF' }
    }
  }
  { width: w, height: h, data: Bytes::from_array(px), }
}

///|
/// A copy of `base` with a small square changed at an odd offset.
fn webp_anim_test_patch(
  base : @image.ImageData,
  x0 : Int32,
  y0 : Int32,
  v : Int32,
  alpha~ : Bool = true,
) -> @image.ImageData {
  let px = base.data.to_fixedarray()
  for y in y0..<(y0 + 3) {
    for x in x0..<(x0 + 4) {
      let o = (y * base.width + x) * 4
      px[o] = v.to_byte()
      px[o + 1] = (255 - v).to_byte()
      px[o + 2] = b'\x10'
      px[o + 3] = if alpha { (v / 2).to_byte() } else { b'\xFF' }
    }
  }
  { width: base.width, height: base.height, data: Bytes::from_array(px), }
}

///|
test "encode_webp_animation round trip (alpha, partial and unchanged frames)" {
  let a = webp_anim_test_frame(21, 15, 1, true)
  let b = webp_anim_test_patch(a, 5, 3, 200)
  let c = webp_anim_test_patch(b, 14, 10, 9)
  let anim : @image.Animation = {
    width: 21,
    height: 15,
    frames: [
      { image: a, delay_ms: 100, },
      { image: b, delay_ms: 40, },
      { image: b, delay_ms: 70, },
      { image: c, delay_ms: 0, },
      { image: webp_anim_test_frame(21, 15, 9, true), delay_ms: 1234, },
    ],
    plays: 3,
  }
  let webp = @image.encode_webp_animation(anim)
  let back = @image.decode_webp_frames(webp)
  assert_eq(back.width, 21)
  assert_eq(back.height, 15)
  assert_eq(back.plays, 3)
  assert_eq(back.frames.length(), 5)
  for i, f in anim.frames {
    assert_eq(back.frames[i].delay_ms, f.delay_ms)
    assert_eq(back.frames[i].image.data, f.image.data)
  }
  assert_eq(@image.decode_webp(webp).data, a.data)
  assert_eq(@image.detect_image_format(webp), Some(@image.WebP))
}

///|
test "encode_webp_animation opaque frames loop forever" {
  let a = webp_anim_test_frame(8, 6, 2, false)
  let b = webp_anim_test_patch(a, 1, 1, 77, alpha=false)
  let anim : @image.Animation = {
    width: 8,
    height: 6,
    frames: [{ image: a, delay_ms: 10, }, { image: b, delay_ms: 20, }],
    plays: 0,
  }
  let webp = @image.encode_webp_animation(anim)
  // VP8X flags: animation only (no alpha bit) for opaque frames.
  assert_eq(webp[20], b'\x02')
  let back = @image.decode_webp_frames(webp)
  assert_eq(back.plays, 0)
  assert_eq(back.frames[1].image.data, b.data)
}

///|
test "encode_webp_animation validation" {
  let a = webp_anim_test_frame(4, 4, 0, false)
  let bad = [
    ({ width: 4, height: 4, frames: [], plays: 0, } : @image.Animation),
    { width: 5, height: 4, frames: [{ image: a, delay_ms: 0, }], plays: 0, },
    { width: 4, height: 4, frames: [{ image: a, delay_ms: 0, }], plays: 70000, },
  ]
  for anim in bad {
    let ok = try {
      ignore(@image.encode_webp_animation(anim))
      true
    } catch {
      _ => false
    }
    assert_false(ok)
  }
}
