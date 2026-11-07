// WebP lossless (VP8L) encoder: length-limited Huffman codes, a cost-based
// (shortest path) LZ77 parse with 2-D distance codes and the color cache,
// meta prefix codes from clustered tile histograms, and the subtract-green,
// predictor, cross-color and color-indexing (palette) transforms. Several
// configurations are written and the smallest is kept.

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
/// LZ77 match candidates of every position of `px`: for position i the
/// entries `offs[i] ..< offs[i + 1]` of (distance code, length), in
/// increasing code and length order (each longer than the cheaper ones).
priv struct VP8LCands {
  offs : FixedArray[Int32]
  code : Array[Int32]
  len : Array[Int32]
  dsym : FixedArray[Int32] // distance prefix symbol | extra bits << 8
}

///|
/// Distance -> plane code (1..120) for the short 2-D distances of an image
/// `xsize` wide (0: no plane code).
fn vp8l_dist_codes(xsize : Int32) -> FixedArray[Int32] {
  let t = FixedArray::make(xsize * 8 + 16, 0)
  for c = 120; c >= 1; c = c - 1 {
    let d = vp8l_plane_distance(xsize, c)
    if d < t.length() {
      t[d] = c
    }
  }
  t
}

///|
fn vp8l_dist_to_code(codes : FixedArray[Int32], d : Int32) -> Int32 {
  if d < codes.length() && codes[d] > 0 {
    codes[d]
  } else {
    d + 120
  }
}

///|
/// LZ77 search: the nearest plane codes always tried, and the depth of the
/// hash chain.
let vp8l_near_codes = 24

///|
let vp8l_chain_tries = 32

///|
/// Near-match length beyond which the hash chain is not searched.
let vp8l_long_match = 256

///|
fn vp8l_match_candidates(px : FixedArray[Int32], xsize : Int32) -> VP8LCands {
  let n = px.length()
  let offs = FixedArray::make(n + 1, 0)
  let code : Array[Int32] = []
  let len : Array[Int32] = []
  let hash_bits = 16
  let head = FixedArray::make(1 << hash_bits, -1)
  let prev = FixedArray::make(n, -1)
  let max_dist = (1 << 20) - 121
  let codes = vp8l_dist_codes(xsize)
  let hash = fn(i : Int32) -> Int32 {
    let h = (px[i].reinterpret_as_uint() * 0x1E35A7BDU) ^
      (px[i + 1].reinterpret_as_uint() * 0x9E3779B1U)
    (h >> (32 - hash_bits)).reinterpret_as_int()
  }
  let match_len = fn(i : Int32, j : Int32) -> Int32 {
    let max = if n - i > 4096 { 4096 } else { n - i }
    let mut l = 0
    while l < max && px[i + l] == px[j + l] {
      l += 1
    }
    l
  }
  // Short 2-D distances (the cheapest plane codes) in code order.
  let near : Array[Int32] = []
  let near_code : Array[Int32] = []
  for c in 1..<=vp8l_near_codes {
    let d = vp8l_plane_distance(xsize, c)
    if !near.contains(d) {
      near.push(d)
      near_code.push(c)
    }
  }
  // A match of length l at i - 1 continues with length l - 1 at i, which
  // keeps long runs linear.
  let near_run = FixedArray::make(near.length(), 0)
  let mut prev_chain_len = 0
  let mut prev_chain_dist = 0
  for i in 0..<n {
    offs[i] = code.length()
    let mut best_len = 0
    for k, d in near {
      if d <= i {
        let l = if near_run[k] > 1 {
          near_run[k] - 1
        } else {
          match_len(i, i - d)
        }
        near_run[k] = l
        if l > best_len {
          best_len = l
          code.push(near_code[k])
          len.push(l)
        }
      }
    }
    if i + 1 < n {
      let h = hash(i)
      let mut cand = head[h]
      let mut tries = vp8l_chain_tries
      let mut chain_len = best_len
      let mut chain_dist = 0
      if prev_chain_len - 1 > best_len && prev_chain_len > vp8l_dp_len_cap {
        chain_len = prev_chain_len - 1
        chain_dist = prev_chain_dist
        tries = 0
      }
      let max_len = if n - i > 4096 { 4096 } else { n - i }
      if best_len >= vp8l_long_match {
        tries = 0 // a long 2-D match is good enough
      }
      while cand >= 0 && tries > 0 && i - cand <= max_dist {
        // Quick reject: a longer match must also match at `chain_len`.
        if chain_len >= max_len || px[cand + chain_len] != px[i + chain_len] {
          cand = prev[cand]
          tries -= 1
          continue
        }
        let l = match_len(i, cand)
        if l > chain_len {
          chain_len = l
          chain_dist = i - cand
        }
        cand = prev[cand]
        tries -= 1
      }
      prev_chain_len = if chain_dist > 0 { chain_len } else { 0 }
      prev_chain_dist = chain_dist
      if chain_dist > 0 {
        let c = vp8l_dist_to_code(codes, chain_dist)
        // Keep the list ordered by code: drop cheaper-looking entries
        // with a larger code (a far distance can map to a small code).
        while code.length() > offs[i] && code[code.length() - 1] >= c {
          ignore(code.pop())
          ignore(len.pop())
        }
        code.push(c)
        len.push(chain_len)
      }
      prev[i] = head[h]
      head[h] = i
    }
  }
  offs[n] = code.length()
  let dsym = FixedArray::makei(code.length(), fn(k) {
    let (ds, de, _) = vp8l_prefix_encode(code[k])
    ds | (de << 8)
  })
  { offs, code, len, dsym, }
}

///|
/// Greedy parse (longest match of at least 3) from the candidates: kinds
/// (0 literal, 1 cache hit, 2 copy), copy length / distance code in `a` /
/// `b`; literals and cache hits keep the pixel index in `a` (and the cache
/// key in `b`).
fn vp8l_greedy_parse(
  cands : VP8LCands,
  hits : FixedArray[Int32],
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let kinds : Array[Int32] = []
  let aa : Array[Int32] = []
  let bb : Array[Int32] = []
  let n = hits.length()
  let mut i = 0
  while i < n {
    let e = cands.offs[i + 1]
    if e > cands.offs[i] && cands.len[e - 1] >= 3 {
      kinds.push(2)
      aa.push(cands.len[e - 1])
      bb.push(cands.code[e - 1])
      i += cands.len[e - 1]
    } else if hits[i] >= 0 {
      kinds.push(1)
      aa.push(i)
      bb.push(hits[i])
      i += 1
    } else {
      kinds.push(0)
      aa.push(i)
      bb.push(0)
      i += 1
    }
  }
  (kinds, aa, bb)
}

///|
/// Color cache hits of `px` (the cache state at a pixel does not depend on
/// the parse: every pixel is inserted in order).
fn vp8l_cache_hits(
  px : FixedArray[Int32],
  cache_bits : Int32,
) -> FixedArray[Int32] {
  let n = px.length()
  let hits = FixedArray::make(n, -1)
  if cache_bits == 0 {
    return hits
  }
  let size = 1 << cache_bits
  let cache = FixedArray::make(size, 0)
  let valid = FixedArray::make(size, false)
  for i in 0..<n {
    let c = px[i]
    let key = vp8l_cache_key(c, cache_bits)
    if valid[key] && cache[key] == c {
      hits[i] = key
    }
    cache[key] = c
    valid[key] = true
  }
  hits
}

///|
/// Symbol histograms of a parse: green / length / cache, red, blue, alpha,
/// distance.
fn vp8l_parse_histograms(
  px : FixedArray[Int32],
  cache_bits : Int32,
  parse : (Array[Int32], Array[Int32], Array[Int32]),
) -> (
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
  FixedArray[Int32],
) {
  let (kinds, aa, bb) = parse
  let cache_size = if cache_bits > 0 { 1 << cache_bits } else { 0 }
  let gf = FixedArray::make(280 + cache_size, 0)
  let rf = FixedArray::make(256, 0)
  let bf = FixedArray::make(256, 0)
  let af = FixedArray::make(256, 0)
  let df = FixedArray::make(40, 0)
  for t in 0..<kinds.length() {
    if kinds[t] == 0 {
      let c = px[aa[t]]
      gf[(c >> 8) & 0xff] += 1
      rf[(c >> 16) & 0xff] += 1
      bf[c & 0xff] += 1
      af[(c >> 24) & 0xff] += 1
    } else if kinds[t] == 1 {
      gf[280 + bb[t]] += 1
    } else {
      gf[256 + vp8l_prefix_encode(aa[t]).0] += 1
      df[vp8l_prefix_encode(bb[t]).0] += 1
    }
  }
  (gf, rf, bf, af, df)
}

///|
/// Estimated bits of each symbol of a histogram (unused symbols get a
/// penalty, as they would need a code of their own).
fn vp8l_symbol_costs(h : FixedArray[Int32]) -> FixedArray[Double] {
  let mut total = 0
  for c in h {
    total += c
  }
  let lt = vp8l_log2_fix(total + 1).to_double() / 256.0
  FixedArray::makei(h.length(), fn(s) {
    if h[s] > 0 {
      lt - vp8l_log2_fix(h[s]).to_double() / 256.0
    } else {
      lt + 2.0
    }
  })
}

///|
/// Number of DP refinement passes of the cost-based LZ77 parse.
let vp8l_lz77_passes = 2

///|
/// Longest copy lengths tried exhaustively by the DP parse (longer
/// matches are also tried at their full length).
let vp8l_dp_len_cap = 16

///|
/// Transform candidates fully coded besides subtract green alone (the
/// others are dropped after a quick estimate), and the predictor tile
/// size.
let vp8l_full_candidates = 2

///|
let vp8l_pred_bits = 4

///|
/// Tile size (log2) of the meta prefix code image, raised on large images
/// to keep at most `vp8l_meta_max_tiles` tiles.
let vp8l_meta_bits = 4

///|
let vp8l_meta_max_tiles = 1024

///|
/// Quick estimate of the bits of an image (no LZ77): the better of
/// literals only and literals with an 8-bit color cache.
fn vp8l_quick_bits(px : FixedArray[Int32]) -> Double {
  let hits = vp8l_cache_hits(px, 8)
  // Literal histograms of all pixels / of the cache misses, and the green
  // alphabet with the cache symbols.
  let lit = FixedArray::make(4 * 256, 0)
  let miss = FixedArray::make(4 * 256, 0)
  let gc = FixedArray::make(256 + 256, 0)
  for i in 0..<px.length() {
    let c = px[i]
    let a = (c >> 24) & 0xff
    let r = (c >> 16) & 0xff
    let g = (c >> 8) & 0xff
    let b = c & 0xff
    lit[a] += 1
    lit[256 + r] += 1
    lit[512 + g] += 1
    lit[768 + b] += 1
    if hits[i] >= 0 {
      gc[256 + hits[i]] += 1
    } else {
      miss[a] += 1
      miss[256 + r] += 1
      gc[g] += 1
      miss[768 + b] += 1
    }
  }
  let plain = vp8l_hist_bits(lit, 0, 256) +
    vp8l_hist_bits(lit, 256, 256) +
    vp8l_hist_bits(lit, 512, 256) +
    vp8l_hist_bits(lit, 768, 256)
  let cached = vp8l_hist_bits(miss, 0, 256) +
    vp8l_hist_bits(miss, 256, 256) +
    vp8l_hist_bits(gc, 0, 512) +
    vp8l_hist_bits(miss, 768, 256)
  if plain < cached {
    plain
  } else {
    cached
  }
}

///|
/// Entropy (bits) of the counts `h[off ..< off + len]`.
fn vp8l_hist_bits(h : FixedArray[Int32], off : Int32, len : Int32) -> Double {
  let mut total = 0
  for i in off..<(off + len) {
    total += h[i]
  }
  let lt = vp8l_log2_fix(total)
  let mut bits = 0
  for i in off..<(off + len) {
    let c = h[i]
    if c > 0 {
      bits += c * (lt - vp8l_log2_fix(c)) // fits: counts * 2^13 at most
    }
  }
  bits.to_double() / 256.0
}

///|
/// Prefix symbol | extra bits << 8 of each copy length.
let vp8l_len_prefix : FixedArray[Int32] = FixedArray::makei(4097, fn(l) {
  if l == 0 {
    0
  } else {
    let (s, e, _) = vp8l_prefix_encode(l)
    s | (e << 8)
  }
})

///|
/// Cost-based LZ77 parse: a shortest path over literals / cache hits and
/// the candidate copies, with symbol costs taken from the previous parse.
fn vp8l_lz77(
  px : FixedArray[Int32],
  cands : VP8LCands,
  cache_bits : Int32,
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let n = px.length()
  let hits = vp8l_cache_hits(px, cache_bits)
  let greedy = vp8l_greedy_parse(cands, hits)
  if cache_bits == 0 {
    return vp8l_lz77_refine(px, cands, cache_bits, hits, greedy)
  }
  // With a cache, literals and cache hits only can be the better start
  // (noisy images with few distinct residual colors): refine whichever
  // starting parse is estimated cheaper.
  let k = Array::make(n, 0)
  let a = Array::make(n, 0)
  let b = Array::make(n, 0)
  for i in 0..<n {
    a[i] = i
    if hits[i] >= 0 {
      k[i] = 1
      b[i] = hits[i]
    }
  }
  let cached = (k, a, b)
  let init = if vp8l_parse_bits(px, cache_bits, cached) <
    vp8l_parse_bits(px, cache_bits, greedy) {
    cached
  } else {
    greedy
  }
  vp8l_lz77_refine(px, cands, cache_bits, hits, init)
}

///|
/// Estimated bits of a parse: the entropy of its symbols plus extra bits.
fn vp8l_parse_bits(
  px : FixedArray[Int32],
  cache_bits : Int32,
  parse : (Array[Int32], Array[Int32], Array[Int32]),
) -> Double {
  let (gf, rf, bf, af, df) = vp8l_parse_histograms(px, cache_bits, parse)
  let mut bits = 0.0
  for h in [gf, rf, bf, af, df] {
    let mut total = 0
    for c in h {
      total += c
    }
    let lt = vp8l_log2_fix(total)
    for c in h {
      if c > 0 {
        bits += c.to_double() * (lt - vp8l_log2_fix(c)).to_double() / 256.0
      }
    }
  }
  let (kinds, aa, bb) = parse
  for t in 0..<kinds.length() {
    if kinds[t] == 2 {
      bits += (vp8l_prefix_encode(aa[t]).1 + vp8l_prefix_encode(bb[t]).1).to_double()
    }
  }
  bits
}

///|
/// Refine a parse by DP passes, each using the symbol costs of the last.
fn vp8l_lz77_refine(
  px : FixedArray[Int32],
  cands : VP8LCands,
  cache_bits : Int32,
  hits : FixedArray[Int32],
  init : (Array[Int32], Array[Int32], Array[Int32]),
) -> (Array[Int32], Array[Int32], Array[Int32]) {
  let n = px.length()
  let mut parse = init
  let cost = FixedArray::make(n + 1, 0.0)
  let from_len = FixedArray::make(n + 1, 0)
  let from_code = FixedArray::make(n + 1, 0)
  let from_cache = FixedArray::make(n + 1, false)
  let len_cost = FixedArray::make(4097, 0.0)
  let mut max_cands = 0
  for i in 0..<n {
    let c = cands.offs[i + 1] - cands.offs[i]
    if c > max_cands {
      max_cands = c
    }
  }
  let sfx_cost = FixedArray::make(max_cands, 0.0)
  let sfx_k = FixedArray::make(max_cands, 0)
  for _ in 0..<vp8l_lz77_passes {
    let (gf, rf, bf, af, df) = vp8l_parse_histograms(px, cache_bits, parse)
    let gc = vp8l_symbol_costs(gf)
    let rc = vp8l_symbol_costs(rf)
    let bc = vp8l_symbol_costs(bf)
    let ac = vp8l_symbol_costs(af)
    let dc = vp8l_symbol_costs(df)
    for l in 1..<=4096 {
      let p = vp8l_len_prefix[l]
      len_cost[l] = gc[256 + (p & 0xff)] + (p >> 8).to_double()
    }
    cost.fill(1.0e300)
    cost[0] = 0.0
    for i in 0..<n {
      let c0 = cost[i]
      let c = px[i]
      let lit = gc[(c >> 8) & 0xff] +
        rc[(c >> 16) & 0xff] +
        bc[c & 0xff] +
        ac[(c >> 24) & 0xff]
      let use_cache = hits[i] >= 0 && gc[280 + hits[i]] < lit
      let lit = if use_cache { gc[280 + hits[i]] } else { lit }
      if c0 + lit < cost[i + 1] {
        cost[i + 1] = c0 + lit
        from_len[i + 1] = 0
        from_cache[i + 1] = use_cache
      }
      let s = cands.offs[i]
      let e = cands.offs[i + 1]
      // Candidates come in increasing code / length order; a copy of
      // length l uses the cheapest candidate at least l long.
      // Suffix minimum of the distance costs.
      let mut run_cost = 1.0e300
      let mut run_k = e
      for k = e - 1; k >= s; k = k - 1 {
        let d = cands.dsym[k]
        let c = dc[d & 0xff] + (d >> 8).to_double()
        if c < run_cost {
          run_cost = c
          run_k = k
        }
        sfx_cost[k - s] = run_cost
        sfx_k[k - s] = run_k
      }
      let mut lo = 1
      for k in s..<e {
        let hi = cands.len[k]
        let base = c0 + sfx_cost[k - s]
        let code = cands.code[sfx_k[k - s]]
        let top = if hi > vp8l_dp_len_cap { vp8l_dp_len_cap } else { hi }
        for l in lo..<=top {
          let c = base + len_cost[l]
          if c < cost[i + l] {
            cost[i + l] = c
            from_len[i + l] = l
            from_code[i + l] = code
          }
        }
        if hi > top && hi >= lo {
          let c = base + len_cost[hi]
          if c < cost[i + hi] {
            cost[i + hi] = c
            from_len[i + hi] = hi
            from_code[i + hi] = code
          }
        }
        lo = hi + 1
      }
    }
    // Trace back.
    let kinds : Array[Int32] = []
    let aa : Array[Int32] = []
    let bb : Array[Int32] = []
    let mut p = n
    while p > 0 {
      let l = from_len[p]
      if l == 0 {
        kinds.push(if from_cache[p] { 1 } else { 0 })
        aa.push(p - 1)
        bb.push(if from_cache[p] { hits[p - 1] } else { 0 })
        p -= 1
      } else {
        kinds.push(2)
        aa.push(l)
        bb.push(from_code[p])
        p -= l
      }
    }
    kinds.rev_in_place()
    aa.rev_in_place()
    bb.rev_in_place()
    parse = (kinds, aa, bb)
  }
  parse
}

///|
/// Write one entropy-coded image (`main`: the level-0 image, which also
/// carries the meta prefix bit). `lz` is an LZ77 parse of `px` (copy
/// distances as codes) or None
/// for literals only.
fn vp8l_write_image(
  bw : WebPBitWriter,
  px : FixedArray[Int32],
  cache_bits : Int32,
  lz : (Array[Int32], Array[Int32], Array[Int32])?,
  main : Bool,
  meta : (Int32, Int32)?,
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
  // Final tokens: 0 literal (argb in ta), 1 cache (key), 2 copy.
  let cache_size = if cache_bits > 0 { 1 << cache_bits } else { 0 }
  let tk : Array[Int32] = []
  let ta : Array[Int32] = []
  let tb : Array[Int32] = []
  for t in 0..<kinds.length() {
    match kinds[t] {
      0 => {
        tk.push(0)
        ta.push(px[aa[t]])
        tb.push(0)
      }
      1 => {
        tk.push(1)
        ta.push(bb[t])
        tb.push(0)
      }
      _ => {
        tk.push(2)
        ta.push(aa[t])
        tb.push(bb[t])
      }
    }
  }
  // Group of every token: with meta prefix codes, the cluster of the tile
  // its first pixel is in.
  let ntok = tk.length()
  let tgroup = FixedArray::make(ntok, 0)
  let gsize = 280 + cache_size
  let hs = gsize + 768 + 40
  let (num_groups, meta_img) = match meta {
    Some((xsize, bits)) => {
      // Larger tiles on large images bound the per-tile histograms.
      let mut mbits = bits
      while mbits < 9 &&
            vp8l_subsample(xsize, mbits) * vp8l_subsample(n / xsize, mbits) >
            vp8l_meta_max_tiles {
        mbits += 1
      }
      let tw = vp8l_subsample(xsize, mbits)
      let th = vp8l_subsample(n / xsize, mbits)
      let tile = FixedArray::make(ntok, 0)
      let mut pos = 0
      for t in 0..<ntok {
        tile[t] = ((pos / xsize) >> mbits) * tw + ((pos % xsize) >> mbits)
        pos += if tk[t] == 2 { ta[t] } else { 1 }
      }
      let th_ = vp8l_tile_histograms(tk, ta, tb, tile, tw * th, gsize)
      let assign = vp8l_cluster_tiles(th_, tw * th, gsize)
      let mut g = 0
      for v in assign {
        if v + 1 > g {
          g = v + 1
        }
      }
      for t in 0..<ntok {
        tgroup[t] = assign[tile[t]]
      }
      let img = FixedArray::makei(tw * th, fn(i) {
        let v = assign[i]
        0xff000000 | (v >> 8 << 16) | ((v & 0xff) << 8)
      })
      (g, Some((mbits, img)))
    }
    None => (1, None)
  }
  // Histograms per group.
  let hist = FixedArray::make(num_groups * hs, 0)
  for t in 0..<ntok {
    let o = tgroup[t] * hs
    match tk[t] {
      0 => {
        let c = ta[t]
        hist[o + ((c >> 8) & 0xff)] += 1
        hist[o + gsize + ((c >> 16) & 0xff)] += 1
        hist[o + gsize + 256 + (c & 0xff)] += 1
        hist[o + gsize + 512 + ((c >> 24) & 0xff)] += 1
      }
      1 => hist[o + 280 + ta[t]] += 1
      _ => {
        hist[o + 256 + vp8l_prefix_encode(ta[t]).0] += 1
        hist[o + gsize + 768 + vp8l_prefix_encode(tb[t]).0] += 1
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
    match meta_img {
      Some((mbits, img)) => {
        bw.put_bits(1, 1)
        bw.put_bits(mbits - 2, 3)
        vp8l_write_image(bw, img, 0, None, false, None)
      }
      None => bw.put_bits(0, 1) // no meta prefix codes
    }
  }
  // Codes of each group: green, red, blue, alpha, distance.
  let lens : Array[FixedArray[Int32]] = []
  let codes : Array[FixedArray[Int32]] = []
  let seg_off = [0, gsize, gsize + 256, gsize + 512, gsize + 768]
  let seg_len = [gsize, 256, 256, 256, 40]
  for g in 0..<num_groups {
    for k in 0..<5 {
      let f = FixedArray::makei(seg_len[k], fn(i) {
        hist[g * hs + seg_off[k] + i]
      })
      let l = vp8l_huffman_lengths(f, 15)
      codes.push(vp8l_write_prefix_code(bw, l))
      lens.push(l)
    }
  }
  for t in 0..<ntok {
    let g5 = tgroup[t] * 5
    let gl = lens[g5]
    let gc = codes[g5]
    match tk[t] {
      0 => {
        let c = ta[t]
        let g = (c >> 8) & 0xff
        let r = (c >> 16) & 0xff
        let b = c & 0xff
        let a = (c >> 24) & 0xff
        bw.put_bits(gc[g], gl[g])
        bw.put_bits(codes[g5 + 1][r], lens[g5 + 1][r])
        bw.put_bits(codes[g5 + 2][b], lens[g5 + 2][b])
        bw.put_bits(codes[g5 + 3][a], lens[g5 + 3][a])
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
        bw.put_bits(codes[g5 + 4][ds], lens[g5 + 4][ds])
        bw.put_bits(dv, de)
      }
    }
  }
}

///|
/// Token histograms of every tile (layout per tile: green / length /
/// cache, red, blue, alpha, distance).
fn vp8l_tile_histograms(
  tk : Array[Int32],
  ta : Array[Int32],
  tb : Array[Int32],
  tile : FixedArray[Int32],
  ntiles : Int32,
  gsize : Int32,
) -> FixedArray[Int32] {
  let hs = gsize + 768 + 40
  let h = FixedArray::make(ntiles * hs, 0)
  for t in 0..<tk.length() {
    let o = tile[t] * hs
    match tk[t] {
      0 => {
        let c = ta[t]
        h[o + ((c >> 8) & 0xff)] += 1
        h[o + gsize + ((c >> 16) & 0xff)] += 1
        h[o + gsize + 256 + (c & 0xff)] += 1
        h[o + gsize + 512 + ((c >> 24) & 0xff)] += 1
      }
      1 => h[o + 280 + ta[t]] += 1
      _ => {
        h[o + 256 + vp8l_prefix_encode(ta[t]).0] += 1
        h[o + gsize + 768 + vp8l_prefix_encode(tb[t]).0] += 1
      }
    }
  }
  h
}

///|
/// Estimated header bits of a prefix code with `used` symbols.
let vp8l_code_header_bits : Double = 40.0

///|
let vp8l_code_symbol_bits : Double = 3.0

///|
/// Estimated bits of one histogram set (5 codes): entropy plus headers.
fn vp8l_histo_cost(h : FixedArray[Int32], off : Int32, gsize : Int32) -> Double {
  let segs = [
    (0, gsize),
    (gsize, 256),
    (gsize + 256, 256),
    (gsize + 512, 256),
    (gsize + 768, 40),
  ]
  let mut bits = 0.0
  for seg in segs {
    let (so, sl) = seg
    let mut used = 0
    for i in 0..<sl {
      if h[off + so + i] > 0 {
        used += 1
      }
    }
    bits += vp8l_hist_bits(h, off + so, sl)
    if used > 1 {
      bits += vp8l_code_header_bits + used.to_double() * vp8l_code_symbol_bits
    } else {
      bits += 8.0
    }
  }
  bits
}

///|
/// Cluster tile histograms into prefix-code groups: tiles are first binned
/// by the entropy of their green / red / blue symbols, then clusters are
/// merged greedily while that lowers the estimated bits. Returns the group
/// of every tile.
fn vp8l_cluster_tiles(
  th : FixedArray[Int32],
  ntiles : Int32,
  gsize : Int32,
) -> FixedArray[Int32] {
  let hs = gsize + 768 + 40
  let assign = FixedArray::make(ntiles, 0)
  // Entropy signature (bits per token) of each non-empty tile.
  let sig = FixedArray::make(ntiles * 3, 0.0)
  let nonempty = FixedArray::make(ntiles, false)
  let lo = [1.0e300, 1.0e300, 1.0e300]
  let hi = [-1.0, -1.0, -1.0]
  for t in 0..<ntiles {
    let mut tot = 0
    for i in 0..<gsize {
      tot += th[t * hs + i]
    }
    if tot == 0 {
      continue
    }
    nonempty[t] = true
    let segs = [(0, gsize), (gsize, 256), (gsize + 256, 256)]
    for k in 0..<3 {
      let (so, sl) = segs[k]
      let e = vp8l_hist_bits(th, t * hs + so, sl) / tot.to_double()
      sig[t * 3 + k] = e
      if e < lo[k] {
        lo[k] = e
      }
      if e > hi[k] {
        hi[k] = e
      }
    }
  }
  // Initial clusters: bins of 4 x 4 x 4 signature levels.
  let bin_of = FixedArray::make(64, -1)
  let cl : Array[FixedArray[Int32]] = []
  let members : Array[Array[Int32]] = []
  for t in 0..<ntiles {
    if !nonempty[t] {
      continue
    }
    let mut key = 0
    for k in 0..<3 {
      let range = hi[k] - lo[k]
      let q = if range <= 0.0 {
        0
      } else {
        let v = ((sig[t * 3 + k] - lo[k]) / range * 4.0).to_int()
        if v > 3 {
          3
        } else {
          v
        }
      }
      key = key * 4 + q
    }
    if bin_of[key] < 0 {
      bin_of[key] = cl.length()
      cl.push(FixedArray::make(hs, 0))
      members.push([])
    }
    let c = bin_of[key]
    let h = cl[c]
    for i in 0..<hs {
      h[i] += th[t * hs + i]
    }
    members[c].push(t)
  }
  let m = cl.length()
  if m <= 1 {
    return assign
  }
  // Greedy merging with a cached gain matrix.
  let cost = FixedArray::makei(m, fn(c) { vp8l_histo_cost(cl[c], 0, gsize) })
  let alive = FixedArray::make(m, true)
  let tmp = FixedArray::make(hs, 0)
  let merged_cost = fn(a : Int32, b : Int32) -> Double {
    for i in 0..<hs {
      tmp[i] = cl[a][i] + cl[b][i]
    }
    vp8l_histo_cost(tmp, 0, gsize)
  }
  let gain = FixedArray::make(m * m, 0.0)
  for a in 0..<m {
    for b in (a + 1)..<m {
      gain[a * m + b] = cost[a] + cost[b] - merged_cost(a, b)
    }
  }
  while true {
    let mut best = 0.0
    let mut ba = -1
    let mut bb = -1
    for a in 0..<m {
      if !alive[a] {
        continue
      }
      for b in (a + 1)..<m {
        if alive[b] && gain[a * m + b] > best {
          best = gain[a * m + b]
          ba = a
          bb = b
        }
      }
    }
    if ba < 0 {
      break
    }
    for i in 0..<hs {
      cl[ba][i] += cl[bb][i]
    }
    for t in members[bb] {
      members[ba].push(t)
    }
    alive[bb] = false
    cost[ba] = vp8l_histo_cost(cl[ba], 0, gsize)
    for c in 0..<m {
      if alive[c] && c != ba {
        let (a, b) = if c < ba { (c, ba) } else { (ba, c) }
        gain[a * m + b] = cost[a] + cost[b] - merged_cost(a, b)
      }
    }
  }
  let mut g = 0
  for c in 0..<m {
    if alive[c] {
      for t in members[c] {
        assign[t] = g
      }
      g += 1
    }
  }
  assign
}

///|
fn vp8l_sub_pixels(a : Int32, b : Int32) -> Int32 {
  // libwebp's VP8LSubPixels: per-channel a - b (mod 256).
  let ag = 0x00ff00ff + (a & 0xff00ff00) - (b & 0xff00ff00)
  let rb = 0xff00ff00 + (a & 0x00ff00ff) - (b & 0x00ff00ff)
  (ag & 0xff00ff00) | (rb & 0x00ff00ff)
}

///|
/// Prior for the predictor statistics: counts (width - |v|) * scale.
let vp8l_pred_prior_width = 16

///|
let vp8l_pred_prior_scale = 4

///|
/// log2(x) * 256 (fixed point) for x >= 1, in 32-bit arithmetic (Int64 is
/// slow on the js target).
fn vp8l_log2_fix(x : Int32) -> Int32 {
  let mut ip = 0
  while ip < 30 && 2 << ip <= x {
    ip += 1
  }
  // Mantissa in [1, 2) with 15 fractional bits, refined by squaring.
  let mut m = (if ip <= 15 { x << (15 - ip) } else { x >> (ip - 15) }).reinterpret_as_uint()
  let mut frac = 0
  for k in 0..<8 {
    m = (m * m) >> 15
    if m >= 2U << 15 {
      m = m >> 1
      frac = frac | (1 << (7 - k))
    }
  }
  ip * 256 + frac
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
  // Residual histograms (A, R, G, B) of the tiles decided so far.
  // A prior peaked at residual 0 keeps the first tiles from locking the
  // statistics onto a bad mode.
  let acc = FixedArray::makei(4 * 256, fn(i) {
    let v = i & 0xff
    let d = if v >= 128 { 256 - v } else { v }
    if d < vp8l_pred_prior_width {
      (vp8l_pred_prior_width - d) * vp8l_pred_prior_scale
    } else {
      0
    }
  })
  let acc_total = FixedArray::make(4, 0)
  for k in 0..<4 {
    for v in 0..<256 {
      acc_total[k] += acc[k * 256 + v]
    }
  }
  let cost_tab = FixedArray::make(4 * 256, 0)
  for ty in 0..<th {
    for tx in 0..<tw {
      let x0 = tx * size
      let y0 = ty * size
      let x1 = if x0 + size > w { w } else { x0 + size }
      let y1 = if y0 + size > h { h } else { y0 + size }
      // Each mode is scored by the bits its residuals would take under
      // the residual statistics accumulated so far (libwebp-style), which
      // favors modes that keep the histograms peaked.
      for k in 0..<4 {
        let t = acc_total[k] + 256
        let lt = vp8l_log2_fix(t)
        for v in 0..<256 {
          cost_tab[k * 256 + v] = lt - vp8l_log2_fix(acc[k * 256 + v] + 1)
        }
      }
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
            cost += cost_tab[(r >> 24) & 0xff] +
              cost_tab[256 + ((r >> 16) & 0xff)] +
              cost_tab[512 + ((r >> 8) & 0xff)] +
              cost_tab[768 + (r & 0xff)]
          }
        }
        if cost < best_cost {
          best_cost = cost
          best = mode
        }
      }
      modes[ty * tw + tx] = 0xff000000 | (best << 8)
      for y in y0..<y1 {
        for x in x0..<x1 {
          if x == 0 || y == 0 {
            continue
          }
          let pos = y * w + x
          let r = vp8l_sub_pixels(px[pos], vp8l_predict(best, px, pos, w))
          acc[(r >> 24) & 0xff] += 1
          acc[256 + ((r >> 16) & 0xff)] += 1
          acc[512 + ((r >> 8) & 0xff)] += 1
          acc[768 + (r & 0xff)] += 1
          for k in 0..<4 {
            acc_total[k] += 1
          }
        }
      }
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
    match best {
      Some(b) if b.length() <= bw.buf.length() => ()
      _ => best = Some(bw.to_bytes())
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
    let cands = vp8l_match_candidates(packed, pw)
    for cache_bits in [0, 4, 6, 8] {
      let lz = vp8l_lz77(packed, cands, cache_bits)
      let bw = WebPBitWriter::new()
      header(bw)
      bw.put_bits(1, 1)
      bw.put_bits(3, 2)
      bw.put_bits(num - 1, 8)
      vp8l_write_image(bw, deltas, 0, None, false, None)
      bw.put_bits(0, 1)
      vp8l_write_image(bw, packed, cache_bits, Some(lz), true, None)
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
  // Candidates: subtract green alone, and the predictor with or without
  // subtract green, each with or without cross color. They are ranked by
  // the estimated bits of a quick parse; the best few are fully coded.
  let pending : Array[
    (
      Bool,
      (Int32, FixedArray[Int32])?,
      (Int32, FixedArray[Int32])?,
      FixedArray[Int32],
      Double,
    ),
  ] = []
  let add = fn(
    use_sg : Bool,
    pred : (Int32, FixedArray[Int32])?,
    cc : (Int32, FixedArray[Int32])?,
    main : FixedArray[Int32],
  ) {
    pending.push((use_sg, pred, cc, main, vp8l_quick_bits(main)))
  }
  add(true, None, None, sg)
  for use_sg in [true, false] {
    let base = if use_sg { sg } else { argb }
    let (res, modes) = vp8l_predict_image(base, w, h, vp8l_pred_bits)
    add(use_sg, Some((vp8l_pred_bits, modes)), None, res)
    for cbits in [4] {
      let (cres, mult) = vp8l_cross_color_image(res, w, h, cbits)
      add(use_sg, Some((vp8l_pred_bits, modes)), Some((cbits, mult)), cres)
    }
  }
  // Subtract green alone (the first candidate) is always coded: it gains
  // most from LZ77, which the estimate leaves out.
  let first = pending[0]
  let rest = pending[1:].to_owned()
  rest.sort_by(fn(x, y) { x.4.compare(y.4) })
  let chosen = [first]
  for t in 0..<rest.length() {
    if t < vp8l_full_candidates {
      chosen.push(rest[t])
    }
  }
  let write = fn(
    entry : (
      Bool,
      (Int32, FixedArray[Int32])?,
      (Int32, FixedArray[Int32])?,
      FixedArray[Int32],
      Double,
    ),
    cache_bits : Int32,
    lz : (Array[Int32], Array[Int32], Array[Int32]),
    meta : (Int32, Int32)?,
  ) -> Int32 {
    let (use_sg, pred, cc, main, _) = entry
    let bw = WebPBitWriter::new()
    header(bw)
    if use_sg {
      bw.put_bits(1, 1)
      bw.put_bits(2, 2) // subtract green
    }
    match pred {
      Some((pbits, modes)) => {
        bw.put_bits(1, 1)
        bw.put_bits(0, 2) // predictor
        bw.put_bits(pbits - 2, 3)
        vp8l_write_image(bw, modes, 0, None, false, None)
      }
      None => ()
    }
    match cc {
      Some((cbits, mult)) => {
        bw.put_bits(1, 1)
        bw.put_bits(1, 2) // cross color
        bw.put_bits(cbits - 2, 3)
        vp8l_write_image(bw, mult, 0, None, false, None)
      }
      None => ()
    }
    bw.put_bits(0, 1)
    vp8l_write_image(bw, main, cache_bits, Some(lz), true, meta)
    consider(bw)
    bw.buf.length()
  }
  // Single prefix code for every candidate and cache size; meta prefix
  // codes (clustered tile histograms) for the smallest one of each cache
  // size only.
  let caches = [0, 8]
  let top = Array::make(caches.length(), None)
  let top_size = Array::make(caches.length(), 0x7fffffff)
  for entry in chosen {
    let cands = vp8l_match_candidates(entry.3, w)
    for k, cache_bits in caches {
      let lz = vp8l_lz77(entry.3, cands, cache_bits)
      let size = write(entry, cache_bits, lz, None)
      if size < top_size[k] {
        top_size[k] = size
        top[k] = Some((entry, lz))
      }
    }
  }
  for k, cache_bits in caches {
    match top[k] {
      Some((entry, lz)) =>
        ignore(write(entry, cache_bits, lz, Some((w, vp8l_meta_bits))))
      None => ()
    }
  }
  best.unwrap()
}

///|
/// Cross-color transform of `px` (predictor residuals): per tile, the
/// green-to-red, green-to-blue and red-to-blue multipliers minimizing the
/// residual bits under the statistics accumulated so far. Returns
/// (transformed pixels, multiplier image).
fn vp8l_cross_color_image(
  px : FixedArray[Int32],
  w : Int32,
  h : Int32,
  bits : Int32,
) -> (FixedArray[Int32], FixedArray[Int32]) {
  let tw = vp8l_subsample(w, bits)
  let th = vp8l_subsample(h, bits)
  let mult = FixedArray::make(tw * th, 0xff000000)
  let out = FixedArray::make(w * h, 0)
  let size = 1 << bits
  // Red / blue histograms with a prior peaked at 0 (as for the predictor).
  let acc = FixedArray::makei(2 * 256, fn(i) {
    let v = i & 0xff
    let d = if v >= 128 { 256 - v } else { v }
    if d < vp8l_pred_prior_width {
      (vp8l_pred_prior_width - d) * vp8l_pred_prior_scale
    } else {
      0
    }
  })
  let acc_total = FixedArray::make(2, 0)
  for k in 0..<2 {
    for v in 0..<256 {
      acc_total[k] += acc[k * 256 + v]
    }
  }
  let cost_tab = FixedArray::make(2 * 256, 0)
  let tg = FixedArray::make(size * size, 0)
  let tr = FixedArray::make(size * size, 0)
  let tb = FixedArray::make(size * size, 0)
  let trs = FixedArray::make(size * size, 0)
  let signed = fn(v : Int32) { if v >= 128 { v - 256 } else { v } }
  let mut prev_g2r = 0
  let mut prev_g2b = 0
  let mut prev_r2b = 0
  for ty in 0..<th {
    for tx in 0..<tw {
      let x0 = tx * size
      let y0 = ty * size
      let x1 = if x0 + size > w { w } else { x0 + size }
      let y1 = if y0 + size > h { h } else { y0 + size }
      let mut cnt = 0
      for y in y0..<y1 {
        for x in x0..<x1 {
          let c = px[y * w + x]
          tg[cnt] = signed((c >> 8) & 0xff)
          tr[cnt] = (c >> 16) & 0xff
          tb[cnt] = c & 0xff
          cnt += 1
        }
      }
      for k in 0..<2 {
        let lt = vp8l_log2_fix(acc_total[k] + 256)
        for v in 0..<256 {
          cost_tab[k * 256 + v] = lt - vp8l_log2_fix(acc[k * 256 + v] + 1)
        }
      }
      // Bits of red for green-to-red multiplier t (plus a small bias
      // towards the previous tile's value, which codes cheaply).
      let pg2r = prev_g2r
      let pg2b = prev_g2b
      let pr2b = prev_r2b
      for i in 0..<cnt {
        trs[i] = signed(tr[i])
      }
      let red_cost = fn(t : Int32) -> Int32 {
        let mut c = 0
        for i in 0..<cnt {
          c += cost_tab[(tr[i] - ((t * tg[i]) >> 5)) & 0xff]
        }
        c + (if t == pg2r { 0 } else { 256 })
      }
      let blue_cost = fn(g2b : Int32, r2b : Int32) -> Int32 {
        let mut c = 0
        for i in 0..<cnt {
          let v = tb[i] - ((g2b * tg[i]) >> 5) - ((r2b * trs[i]) >> 5)
          c += cost_tab[256 + (v & 0xff)]
        }
        c +
        (if g2b == pg2b { 0 } else { 256 }) +
        (if r2b == pr2b { 0 } else { 256 })
      }
      // Coarse-to-fine search over the signed range.
      let search = fn(start : Int32, f : (Int32) -> Int32) -> Int32 {
        let mut best = start
        let mut best_c = f(start)
        for cand in [0, pg2r, pg2b, pr2b] {
          let c = f(cand)
          if c < best_c {
            best_c = c
            best = cand
          }
        }
        let mut step = 32
        while step >= 1 {
          let center = best
          for d in [-step, step] {
            let cand = center + d
            if cand >= -128 && cand <= 127 {
              let c = f(cand)
              if c < best_c {
                best_c = c
                best = cand
              }
            }
          }
          step = step >> 1
        }
        best
      }
      let g2r = search(pg2r, red_cost)
      let g2b0 = search(pg2b, fn(t) { blue_cost(t, pr2b) })
      let r2b = search(pr2b, fn(t) { blue_cost(g2b0, t) })
      let g2b = search(g2b0, fn(t) { blue_cost(t, r2b) })
      prev_g2r = g2r
      prev_g2b = g2b
      prev_r2b = r2b
      mult[ty * tw + tx] = 0xff000000 |
        ((r2b & 0xff) << 16) |
        ((g2b & 0xff) << 8) |
        (g2r & 0xff)
      let mut i = 0
      for y in y0..<y1 {
        for x in x0..<x1 {
          let pos = y * w + x
          let c = px[pos]
          let nr = (tr[i] - ((g2r * tg[i]) >> 5)) & 0xff
          let nb = (tb[i] - ((g2b * tg[i]) >> 5) - ((r2b * trs[i]) >> 5)) & 0xff
          out[pos] = (c & 0xff00ff00) | (nr << 16) | nb
          acc[nr] += 1
          acc[256 + nb] += 1
          acc_total[0] += 1
          acc_total[1] += 1
          i += 1
        }
      }
    }
  }
  (out, mult)
}
