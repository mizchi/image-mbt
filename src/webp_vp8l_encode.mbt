// WebP lossless (VP8L) encoder: length-limited Huffman codes, LZ77 with
// 2-D distance codes, color cache, and the subtract-green, predictor and
// color-indexing (palette) transforms. Several configurations are written
// and the smallest is kept.

///|
/// Huffman code lengths for `freqs`, limited to `limit` bits (frequencies
/// are flattened until the tree fits, like libwebp). Unused symbols get 0.
fn vp8l_huffman_lengths(
  freqs : FixedArray[Int32],
  limit : Int32,
) -> FixedArray[Int32] {
  let n = freqs.length()
  let lengths = FixedArray::make(n, 0)
  let syms : Array[Int32] = []
  for s in 0..<n {
    if freqs[s] > 0 {
      syms.push(s)
    }
  }
  if syms.length() == 0 {
    return lengths
  }
  if syms.length() == 1 {
    lengths[syms[0]] = 1
    return lengths
  }
  let mut count_min = 1
  while true {
    let m = syms.length()
    // Nodes 0..m-1 are leaves; internal nodes follow. Two-queue merge.
    let weight = FixedArray::make(2 * m, 0)
    let parent = FixedArray::make(2 * m, -1)
    let order = syms.copy()
    for i in 0..<m {
      let f = freqs[order[i]]
      weight[i] = if f < count_min { count_min } else { f }
    }
    let idx = Array::makei(m, fn(i) { i })
    idx.sort_by(fn(a, b) {
      if weight[a] != weight[b] {
        weight[a] - weight[b]
      } else {
        order[a] - order[b]
      }
    })
    let mut li = 0
    let mut qi = m
    let mut next = m
    let pick = fn() {
      if li < m && (qi >= next || weight[idx[li]] <= weight[qi]) {
        li += 1
        idx[li - 1]
      } else {
        qi += 1
        qi - 1
      }
    }
    for _ in 0..<(m - 1) {
      let a = pick()
      let b = pick()
      weight[next] = weight[a] + weight[b]
      parent[a] = next
      parent[b] = next
      next += 1
    }
    let mut max_len = 0
    let depth = FixedArray::make(2 * m, 0)
    for i = next - 2; i >= 0; i = i - 1 {
      depth[i] = depth[parent[i]] + 1
    }
    for i in 0..<m {
      if depth[i] > max_len {
        max_len = depth[i]
      }
    }
    if max_len <= limit {
      for i in 0..<m {
        lengths[order[i]] = depth[i]
      }
      return lengths
    }
    count_min = count_min * 2
  }
  lengths
}

///|
/// Canonical (bit-reversed) codes for `lengths`.
fn vp8l_codes(lengths : FixedArray[Int32]) -> FixedArray[Int32] {
  let codes = FixedArray::make(lengths.length(), 0)
  let count = FixedArray::make(17, 0)
  for l in lengths {
    count[l] += 1
  }
  count[0] = 0
  let next = FixedArray::make(17, 0)
  let mut code = 0
  for l in 1..<=16 {
    code = (code + count[l - 1]) << 1
    next[l] = code
  }
  for s in 0..<lengths.length() {
    let l = lengths[s]
    if l > 0 {
      codes[s] = webp_reverse_bits(next[l], l)
      next[l] += 1
    }
  }
  codes
}

///|
/// Write the code lengths of a normal prefix code: run-length tokens
/// (16 = repeat previous, 17 / 18 = zero runs) coded with a 7-bit-limited
/// code-length code. The full alphabet is always described.
fn vp8l_write_code_lengths(
  bw : WebPBitWriter,
  lengths : FixedArray[Int32],
) -> Unit {
  let tokens : Array[Int32] = [] // token | extra << 8
  let n = lengths.length()
  let mut i = 0
  while i < n {
    let v = lengths[i]
    let mut run = 1
    while i + run < n && lengths[i + run] == v {
      run += 1
    }
    i += run
    if v == 0 {
      while run > 0 {
        if run >= 11 {
          let r = if run > 138 { 138 } else { run }
          tokens.push(18 | ((r - 11) << 8))
          run -= r
        } else if run >= 3 {
          tokens.push(17 | ((run - 3) << 8))
          run = 0
        } else {
          tokens.push(0)
          run -= 1
        }
      }
    } else {
      tokens.push(v)
      run -= 1
      while run > 0 {
        if run >= 3 {
          let r = if run > 6 { 6 } else { run }
          tokens.push(16 | ((r - 3) << 8))
          run -= r
        } else {
          tokens.push(v)
          run -= 1
        }
      }
    }
  }
  let tfreq = FixedArray::make(19, 0)
  for t in tokens {
    tfreq[t & 0xff] += 1
  }
  let tlen = vp8l_huffman_lengths(tfreq, 7)
  let tcode = vp8l_codes(tlen)
  let mut num = 4
  for k in 0..<19 {
    if tlen[vp8l_code_length_order[k]] > 0 && k + 1 > num {
      num = k + 1
    }
  }
  bw.put_bits(0, 1) // normal code
  bw.put_bits(num - 4, 4)
  for k in 0..<num {
    bw.put_bits(tlen[vp8l_code_length_order[k]], 3)
  }
  bw.put_bits(0, 1) // no max_symbol: all tokens follow
  let single = tfreq.iter().filter(fn(f) { f > 0 }).count() <= 1
  for t in tokens {
    let s = t & 0xff
    if !single {
      bw.put_bits(tcode[s], tlen[s])
    }
    match s {
      16 => bw.put_bits(t >> 8, 2)
      17 => bw.put_bits(t >> 8, 3)
      18 => bw.put_bits(t >> 8, 7)
      _ => ()
    }
  }
}

///|
/// Write a prefix code for `lengths` (simple code when possible). Returns
/// the bit-reversed codes to emit symbols with (lengths 0 = zero bits).
fn vp8l_write_prefix_code(
  bw : WebPBitWriter,
  lengths : FixedArray[Int32],
) -> FixedArray[Int32] {
  let used : Array[Int32] = []
  for s in 0..<lengths.length() {
    if lengths[s] > 0 {
      used.push(s)
    }
  }
  if used.length() == 0 {
    // Unused alphabet: a one-symbol code.
    bw.put_bits(1, 1)
    bw.put_bits(0, 1)
    bw.put_bits(0, 1)
    bw.put_bits(0, 1)
    lengths.fill(0)
    return FixedArray::make(lengths.length(), 0)
  }
  if used.length() <= 2 && used.iter().all(fn(s) { s < 256 }) {
    bw.put_bits(1, 1)
    bw.put_bits(used.length() - 1, 1)
    if used[0] < 2 {
      bw.put_bits(0, 1)
      bw.put_bits(used[0], 1)
    } else {
      bw.put_bits(1, 1)
      bw.put_bits(used[0], 8)
    }
    if used.length() == 2 {
      bw.put_bits(used[1], 8)
    } else {
      lengths[used[0]] = 0 // one symbol: zero bits
    }
    return vp8l_codes(lengths)
  }
  vp8l_write_code_lengths(bw, lengths)
  if used.length() == 1 {
    lengths[used[0]] = 0
  }
  vp8l_codes(lengths)
}

///|
/// Prefix code and extra bits for a length / distance value >= 1:
/// (symbol, extra bit count, extra value).
fn vp8l_prefix_encode(v : Int32) -> (Int32, Int32, Int32) {
  let d = v - 1
  if d < 4 {
    return (d, 0, 0)
  }
  let mut h = 0
  while d >> (h + 1) != 0 {
    h += 1
  }
  let second = (d >> (h - 1)) & 1
  (2 * h + second, h - 1, d & ((1 << (h - 1)) - 1))
}

///|
/// LZ77 parse of `px`: kinds (0 literal, 2 copy), with copy length /
/// distance in `a` / `b`. Literals keep the pixel index in `a`.
fn vp8l_lz77(
  px : FixedArray[Int32],
  xsize : Int32,
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let n = px.length()
  let kinds : Array[Int32] = []
  let aa : Array[Int32] = []
  let bb : Array[Int32] = []
  let hash_bits = 16
  let head = FixedArray::make(1 << hash_bits, -1)
  let prev = FixedArray::make(n, -1)
  let max_dist = (1 << 20) - 121
  let hash = fn(i : Int32) -> Int32 {
    let h = (px[i].reinterpret_as_uint() * 0x1E35A7BDU) ^
      (px[i + 1].reinterpret_as_uint() * 0x9E3779B1U)
    (h >> (32 - hash_bits)).reinterpret_as_int()
  }
  let insert = fn(i : Int32) {
    if i + 1 < n {
      let h = hash(i)
      prev[i] = head[h]
      head[h] = i
    }
  }
  let match_len = fn(i : Int32, j : Int32) -> Int32 {
    let max = if n - i > 4096 { 4096 } else { n - i }
    let mut l = 0
    while l < max && px[i + l] == px[j + l] {
      l += 1
    }
    l
  }
  let mut i = 0
  while i < n {
    let mut best_len = 0
    let mut best_dist = 0
    // Cheap candidates first: the previous pixel and the pixel above.
    if i >= 1 {
      best_len = match_len(i, i - 1)
      best_dist = 1
    }
    if xsize > 1 && i >= xsize {
      let l = match_len(i, i - xsize)
      if l > best_len {
        best_len = l
        best_dist = xsize
      }
    }
    if i + 1 < n {
      let mut cand = head[hash(i)]
      let mut tries = 32
      while cand >= 0 && tries > 0 && i - cand <= max_dist {
        let l = match_len(i, cand)
        if l > best_len {
          best_len = l
          best_dist = i - cand
        }
        cand = prev[cand]
        tries -= 1
      }
    }
    if best_len >= 3 {
      kinds.push(2)
      aa.push(best_len)
      bb.push(best_dist)
      for k in 0..<best_len {
        insert(i + k)
      }
      i += best_len
    } else {
      kinds.push(0)
      aa.push(i)
      bb.push(0)
      insert(i)
      i += 1
    }
  }
  (kinds, aa, bb)
}

///|
/// Map distances to plane codes for an image of width `xsize`.
fn vp8l_plane_codes(xsize : Int32) -> Map[Int32, Int32] {
  let m : Map[Int32, Int32] = Map([])
  for c in 1..<=120 {
    let d = vp8l_plane_distance(xsize, c)
    if !m.contains(d) {
      m[d] = c
    }
  }
  m
}

///|
/// Write one entropy-coded image (`main`: the level-0 image, which also
/// carries the meta prefix bit). `lz` is an LZ77 parse of `px` or None
/// for literals only.
fn vp8l_write_image(
  bw : WebPBitWriter,
  px : FixedArray[Int32],
  xsize : Int32,
  cache_bits : Int32,
  lz : (Array[Int32], Array[Int32], Array[Int32])?,
  main : Bool,
) -> Unit {
  let n = px.length()
  let (kinds, aa, bb) = match lz {
    Some(t) => t
    None => {
      let k = Array::make(n, 0)
      let a = Array::makei(n, fn(i) { i })
      (k, a, Array::make(n, 0))
    }
  }
  // Resolve the color cache and the distance codes into final tokens.
  let cache_size = if cache_bits > 0 { 1 << cache_bits } else { 0 }
  let cache = FixedArray::make(cache_size, 0)
  let valid = FixedArray::make(cache_size, false)
  let planes = vp8l_plane_codes(xsize)
  let tk : Array[Int32] = [] // 0 literal (argb in ta), 1 cache (idx), 2 copy
  let ta : Array[Int32] = []
  let tb : Array[Int32] = []
  let mut pos = 0
  for t in 0..<kinds.length() {
    if kinds[t] == 0 {
      let argb = px[aa[t]]
      if cache_bits > 0 {
        let key = vp8l_cache_key(argb, cache_bits)
        if valid[key] && cache[key] == argb {
          tk.push(1)
          ta.push(key)
          tb.push(0)
        } else {
          tk.push(0)
          ta.push(argb)
          tb.push(0)
        }
        cache[key] = argb
        valid[key] = true
      } else {
        tk.push(0)
        ta.push(argb)
        tb.push(0)
      }
      pos += 1
    } else {
      let len = aa[t]
      let dist = bb[t]
      tk.push(2)
      ta.push(len)
      tb.push(
        match planes.get(dist) {
          Some(c) => c
          None => dist + 120
        },
      )
      if cache_bits > 0 {
        for k in 0..<len {
          let c = px[pos + k]
          let key = vp8l_cache_key(c, cache_bits)
          cache[key] = c
          valid[key] = true
        }
      }
      pos += len
    }
  }
  // Histograms.
  let gf = FixedArray::make(280 + cache_size, 0)
  let rf = FixedArray::make(256, 0)
  let bf = FixedArray::make(256, 0)
  let af = FixedArray::make(256, 0)
  let df = FixedArray::make(40, 0)
  for t in 0..<tk.length() {
    match tk[t] {
      0 => {
        let c = ta[t]
        gf[(c >> 8) & 0xff] += 1
        rf[(c >> 16) & 0xff] += 1
        bf[c & 0xff] += 1
        af[(c >> 24) & 0xff] += 1
      }
      1 => gf[280 + ta[t]] += 1
      _ => {
        gf[256 + vp8l_prefix_encode(ta[t]).0] += 1
        df[vp8l_prefix_encode(tb[t]).0] += 1
      }
    }
  }
  if cache_bits > 0 {
    bw.put_bits(1, 1)
    bw.put_bits(cache_bits, 4)
  } else {
    bw.put_bits(0, 1)
  }
  if main {
    bw.put_bits(0, 1) // no meta prefix codes
  }
  let gl = vp8l_huffman_lengths(gf, 15)
  let rl = vp8l_huffman_lengths(rf, 15)
  let bl = vp8l_huffman_lengths(bf, 15)
  let al = vp8l_huffman_lengths(af, 15)
  let dl = vp8l_huffman_lengths(df, 15)
  let gc = vp8l_write_prefix_code(bw, gl)
  let rc = vp8l_write_prefix_code(bw, rl)
  let bc = vp8l_write_prefix_code(bw, bl)
  let ac = vp8l_write_prefix_code(bw, al)
  let dc = vp8l_write_prefix_code(bw, dl)
  for t in 0..<tk.length() {
    match tk[t] {
      0 => {
        let c = ta[t]
        let g = (c >> 8) & 0xff
        let r = (c >> 16) & 0xff
        let b = c & 0xff
        let a = (c >> 24) & 0xff
        bw.put_bits(gc[g], gl[g])
        bw.put_bits(rc[r], rl[r])
        bw.put_bits(bc[b], bl[b])
        bw.put_bits(ac[a], al[a])
      }
      1 => {
        let s = 280 + ta[t]
        bw.put_bits(gc[s], gl[s])
      }
      _ => {
        let (ls, le, lv) = vp8l_prefix_encode(ta[t])
        bw.put_bits(gc[256 + ls], gl[256 + ls])
        bw.put_bits(lv, le)
        let (ds, de, dv) = vp8l_prefix_encode(tb[t])
        bw.put_bits(dc[ds], dl[ds])
        bw.put_bits(dv, de)
      }
    }
  }
}

///|
fn vp8l_sub_pixels(a : Int32, b : Int32) -> Int32 {
  // libwebp's VP8LSubPixels: per-channel a - b (mod 256).
  let ag = 0x00ff00ff + (a & 0xff00ff00) - (b & 0xff00ff00)
  let rb = 0xff00ff00 + (a & 0x00ff00ff) - (b & 0x00ff00ff)
  (ag & 0xff00ff00) | (rb & 0x00ff00ff)
}

///|
/// Choose a predictor mode per tile and return (residuals, mode image).
fn vp8l_predict_image(
  px : FixedArray[Int32],
  w : Int32,
  h : Int32,
  bits : Int32,
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let tw = vp8l_subsample(w, bits)
  let th = vp8l_subsample(h, bits)
  let modes = FixedArray::make(tw * th, 0)
  let res = FixedArray::make(w * h, 0)
  let size = 1 << bits
  for ty in 0..<th {
    for tx in 0..<tw {
      let x0 = tx * size
      let y0 = ty * size
      let x1 = if x0 + size > w { w } else { x0 + size }
      let y1 = if y0 + size > h { h } else { y0 + size }
      let mut best = 0
      let mut best_cost = 0x7fffffff
      for mode in 0..<14 {
        let mut cost = 0
        for y in y0..<y1 {
          for x in x0..<x1 {
            if x == 0 || y == 0 {
              continue // fixed predictors on the first row / column
            }
            let pos = y * w + x
            let r = vp8l_sub_pixels(px[pos], vp8l_predict(mode, px, pos, w))
            for k in 0..<4 {
              let c = (r >> (k * 8)) & 0xff
              cost += if c >= 128 { 256 - c } else { c }
            }
          }
        }
        if cost < best_cost {
          best_cost = cost
          best = mode
        }
      }
      modes[ty * tw + tx] = 0xff000000 | (best << 8)
    }
  }
  for y in 0..<h {
    for x in 0..<w {
      let pos = y * w + x
      let pred = if x == 0 && y == 0 {
        0xff000000
      } else if y == 0 {
        px[pos - 1]
      } else if x == 0 {
        px[pos - w]
      } else {
        vp8l_predict(
          (modes[(y >> bits) * tw + (x >> bits)] >> 8) & 0xf,
          px,
          pos,
          w,
        )
      }
      res[pos] = vp8l_sub_pixels(px[pos], pred)
    }
  }
  (res, modes)
}

///|
/// Encode `img` as a VP8L bitstream (the payload of a `VP8L` chunk).
fn vp8l_encode(img : ImageData) -> Bytes {
  let w = img.width
  let h = img.height
  let n = w * h
  let argb = FixedArray::make(n, 0)
  let mut has_alpha = false
  for i in 0..<n {
    let r = img.data[i * 4].to_int()
    let g = img.data[i * 4 + 1].to_int()
    let b = img.data[i * 4 + 2].to_int()
    let a = img.data[i * 4 + 3].to_int()
    if a != 255 {
      has_alpha = true
    }
    argb[i] = (a << 24) | (r << 16) | (g << 8) | b
  }
  vp8l_encode_argb(argb, w, h, has_alpha, true)
}

///|
/// Encode ARGB pixels as a VP8L stream; without `with_header` the 5-byte
/// image header is left out (the form used inside ALPH chunks).
fn vp8l_encode_argb(
  argb : FixedArray[Int32],
  w : Int32,
  h : Int32,
  has_alpha : Bool,
  with_header : Bool,
) -> Bytes {
  let n = w * h
  let header = fn(bw : WebPBitWriter) {
    if !with_header {
      return
    }
    bw.put_bits(0x2F, 8)
    bw.put_bits(w - 1, 14)
    bw.put_bits(h - 1, 14)
    bw.put_bits(if has_alpha { 1 } else { 0 }, 1)
    bw.put_bits(0, 3)
  }
  let mut best : Bytes? = None
  let consider = fn(bw : WebPBitWriter) {
    bw.flush()
    let out = bw.to_bytes()
    match best {
      Some(b) if b.length() <= out.length() => ()
      _ => best = Some(out)
    }
  }
  // Candidate 1: palette (color indexing) for <= 256 colors.
  let colors : Map[Int32, Int32] = Map([])
  for i in 0..<n {
    if !colors.contains(argb[i]) {
      if colors.length() > 256 {
        break
      }
      colors[argb[i]] = 0
    }
  }
  if colors.length() <= 256 {
    let palette = colors.keys().collect()
    palette.sort_by(fn(a, b) {
      let ua = a.reinterpret_as_uint()
      let ub = b.reinterpret_as_uint()
      if ua < ub {
        -1
      } else if ua > ub {
        1
      } else {
        0
      }
    })
    for i, c in palette {
      colors[c] = i
    }
    let num = palette.length()
    let bits = if num > 16 {
      0
    } else if num > 4 {
      1
    } else if num > 2 {
      2
    } else {
      3
    }
    let pw = vp8l_subsample(w, bits)
    let packed = FixedArray::make(pw * h, 0xff000000)
    let bpp = 8 >> bits
    for y in 0..<h {
      for x in 0..<w {
        let idx = colors.get(argb[y * w + x]).unwrap()
        let o = y * pw + (x >> bits)
        packed[o] = packed[o] | (idx << (8 + (x & ((1 << bits) - 1)) * bpp))
      }
    }
    let deltas = FixedArray::make(num, 0)
    for i in 0..<num {
      deltas[i] = if i == 0 {
        palette[0]
      } else {
        vp8l_sub_pixels(palette[i], palette[i - 1])
      }
    }
    let lz = vp8l_lz77(packed, pw)
    for cache_bits in [0, 8] {
      let bw = WebPBitWriter::new()
      header(bw)
      bw.put_bits(1, 1)
      bw.put_bits(3, 2)
      bw.put_bits(num - 1, 8)
      vp8l_write_image(bw, deltas, num, 0, None, false)
      bw.put_bits(0, 1)
      vp8l_write_image(bw, packed, pw, cache_bits, Some(lz), true)
      consider(bw)
    }
  }
  // Other candidates: predictor and / or subtract green (subtract green
  // hurts images whose color lives in one channel, e.g. alpha planes).
  let sg = FixedArray::make(n, 0)
  for i in 0..<n {
    let c = argb[i]
    let g = (c >> 8) & 0xff
    sg[i] = (c & 0xff00ff00) |
      ((((c >> 16) - g) & 0xff) << 16) |
      ((c - g) & 0xff)
  }
  let pbits = if w * h >= 64 * 64 { 4 } else { 3 }
  for use_sg in [true, false] {
    let base = if use_sg { sg } else { argb }
    let (res, modes) = vp8l_predict_image(base, w, h, pbits)
    for use_pred in [true, false] {
      if !use_sg && !use_pred {
        continue // the palette or the other candidates cover this
      }
      let main = if use_pred { res } else { base }
      let lz = vp8l_lz77(main, w)
      for cache_bits in [0, 10] {
        let bw = WebPBitWriter::new()
        header(bw)
        if use_sg {
          bw.put_bits(1, 1)
          bw.put_bits(2, 2) // subtract green
        }
        if use_pred {
          bw.put_bits(1, 1)
          bw.put_bits(0, 2) // predictor
          bw.put_bits(pbits - 2, 3)
          vp8l_write_image(bw, modes, vp8l_subsample(w, pbits), 0, None, false)
        }
        bw.put_bits(0, 1)
        vp8l_write_image(bw, main, w, cache_bits, Some(lz), true)
        consider(bw)
      }
    }
  }
  best.unwrap()
}
