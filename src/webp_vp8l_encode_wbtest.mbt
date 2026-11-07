///|
fn vp8l_wb_image(w : Int32, h : Int32, seed0 : UInt32) -> FixedArray[Int32] {
  let px = FixedArray::make(w * h, 0)
  let mut seed = seed0
  for y in 0..<h {
    for x in 0..<w {
      seed = seed * 1103515245U + 12345U
      let noise = ((seed >> 16) & 15U).reinterpret_as_int()
      let r = (x * 3 + noise) & 0xff
      let g = (y * 5 + (noise >> 1)) & 0xff
      let b = (x + y + noise * 2) & 0xff
      // Runs and repeated rows give the LZ77 parse copies to find.
      let v = if x % 17 < 6 { (r << 16) | (g << 8) | b } else { 0x203040 }
      px[y * w + x] = 0xff000000 | v
    }
  }
  px
}

///|
test "VP8L cross color inverts exactly" {
  let w = 37
  let h = 29
  let px = vp8l_wb_image(w, h, 7U)
  for bits in [2, 3, 4] {
    let (out, mult) = vp8l_cross_color_image(px, w, h, bits)
    vp8l_inverse_cross_color(out, w, h, bits, mult)
    assert_eq(out == px, true)
  }
}

///|
test "VP8L cost-based parse reproduces the pixels" {
  let w = 45
  let h = 31
  let px = vp8l_wb_image(w, h, 99U)
  let n = w * h
  let cands = vp8l_match_candidates(px, w)
  for cache_bits in [0, 4, 8] {
    let (kinds, aa, bb) = vp8l_lz77(px, cands, cache_bits)
    // Replay the parse like the decoder.
    let out = FixedArray::make(n, 0)
    let size = if cache_bits > 0 { 1 << cache_bits } else { 0 }
    let cache = FixedArray::make(size, 0)
    let mut pos = 0
    for t in 0..<kinds.length() {
      match kinds[t] {
        0 => {
          out[pos] = px[aa[t]]
          pos += 1
        }
        1 => {
          out[pos] = cache[bb[t]]
          pos += 1
        }
        _ => {
          let d = vp8l_plane_distance(w, bb[t])
          assert_eq(d >= 1 && d <= pos, true)
          for k in 0..<aa[t] {
            out[pos + k] = out[pos + k - d]
          }
          pos += aa[t]
        }
      }
      if cache_bits > 0 {
        // Every decoded pixel enters the cache.
        let start = if kinds[t] == 2 { pos - aa[t] } else { pos - 1 }
        for k in start..<pos {
          cache[vp8l_cache_key(out[k], cache_bits)] = out[k]
        }
      }
    }
    assert_eq(pos, n)
    assert_eq(out == px, true)
  }
}

///|
test "VP8L meta prefix codes round trip" {
  // Two halves with very different statistics, so the clustering keeps
  // more than one group.
  let w = 96
  let h = 64
  let data = FixedArray::make(w * h * 4, b'\x00')
  let mut seed = 5U
  for y in 0..<h {
    for x in 0..<w {
      seed = seed * 1103515245U + 12345U
      let i = (y * w + x) * 4
      if x < w / 2 {
        data[i] = ((seed >> 16) & 0xffU).reinterpret_as_int().to_byte()
        data[i + 1] = ((seed >> 8) & 0xffU).reinterpret_as_int().to_byte()
        data[i + 2] = ((seed >> 24) & 0xffU).reinterpret_as_int().to_byte()
      } else {
        data[i] = (x * 2).to_byte()
        data[i + 1] = ((seed >> 16) & 3U).reinterpret_as_int().to_byte()
        data[i + 2] = (y * 3).to_byte()
      }
      data[i + 3] = b'\xFF'
    }
  }
  let argb = FixedArray::makei(w * h, fn(i) {
    (0xff << 24) |
    (data[i * 4].to_int() << 16) |
    (data[i * 4 + 1].to_int() << 8) |
    data[i * 4 + 2].to_int()
  })
  let cands = vp8l_match_candidates(argb, w)
  let lz = vp8l_lz77(argb, cands, 0)
  let bw = WebPBitWriter::new()
  bw.put_bits(0x2F, 8)
  bw.put_bits(w - 1, 14)
  bw.put_bits(h - 1, 14)
  bw.put_bits(0, 1)
  bw.put_bits(0, 3)
  bw.put_bits(0, 1) // no transforms
  vp8l_write_image(bw, argb, 0, Some(lz), true, Some((w, 3)))
  bw.flush()
  let payload = bw.to_bytes()
  let br = VP8LReader::new(payload, 5, payload.length())
  let out = vp8l_decode_stream(br, w, h)
  assert_eq(out == argb, true)
  // Several groups were used.
  let tiles = vp8l_subsample(w, 3) * vp8l_subsample(h, 3)
  let tk = Array::makei(lz.0.length(), fn(t) { lz.0[t] })
  let ta = Array::makei(lz.0.length(), fn(t) {
    if lz.0[t] == 0 {
      argb[lz.1[t]]
    } else {
      lz.1[t]
    }
  })
  let tile = FixedArray::make(tk.length(), 0)
  let mut pos = 0
  for t in 0..<tk.length() {
    tile[t] = ((pos / w) >> 3) * vp8l_subsample(w, 3) + ((pos % w) >> 3)
    pos += if tk[t] == 2 { ta[t] } else { 1 }
  }
  let th = vp8l_tile_histograms(tk, ta, lz.2, tile, tiles, 280)
  let assign = vp8l_cluster_tiles(th, tiles, 280)
  let mut groups = 0
  for g in assign {
    if g + 1 > groups {
      groups = g + 1
    }
  }
  assert_eq(groups > 1, true)
}
