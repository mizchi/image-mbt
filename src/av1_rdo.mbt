// AV1 encoder decisions: intra modes (SATD pre-selection, then full
// rate-distortion), transform types (av1_encode.mbt) and the partition
// tree (none / split, searched recursively with state snapshots).

///|
/// Decided partition tree of a superblock.
priv enum Av1Tree {
  Empty
  Leaf(Av1BlockMode)
  Split(Array[Av1Tree])
}

///|
/// Luma modes kept after SATD pre-selection.
let av1_mode_candidates = 3

///|
/// Sum of 4x4 Hadamard transformed differences (source - reconstruction).
fn Av1Enc::satd(
  self : Av1Enc,
  plane : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  let st = self.stride[plane]
  let src = self.src[plane]
  let rec = self.rec[plane]
  let d = FixedArray::make(16, 0)
  let mut total = 0
  let mut by = 0
  while by < h {
    let mut bx = 0
    while bx < w {
      for i in 0..<4 {
        let o = (y0 + by + i) * st + x0 + bx
        let a0 = src[o] - rec[o]
        let a1 = src[o + 1] - rec[o + 1]
        let a2 = src[o + 2] - rec[o + 2]
        let a3 = src[o + 3] - rec[o + 3]
        let s01 = a0 + a1
        let d01 = a0 - a1
        let s23 = a2 + a3
        let d23 = a2 - a3
        d[i * 4] = s01 + s23
        d[i * 4 + 1] = d01 + d23
        d[i * 4 + 2] = s01 - s23
        d[i * 4 + 3] = d01 - d23
      }
      for j in 0..<4 {
        let s01 = d[j] + d[4 + j]
        let d01 = d[j] - d[4 + j]
        let s23 = d[8 + j] + d[12 + j]
        let d23 = d[8 + j] - d[12 + j]
        total += (s01 + s23).abs() +
          (d01 + d23).abs() +
          (s01 - s23).abs() +
          (d01 - d23).abs()
      }
      bx += 4
    }
    by += 4
  }
  total >> 1
}

///|
/// Distortion of the current block (luma + chroma, visible samples).
fn Av1Enc::block_sse(self : Av1Enc) -> Int32 {
  let bw = av1_bw4(self.bsize) * 4
  let bh = av1_bh4(self.bsize) * 4
  let mut d = self.sse(0, self.mi_col * 4, self.mi_row * 4, bw, bh)
  if self.has_chroma {
    let psz = self.plane_size(1)
    let cw = av1_bw4(psz) * 4
    let chh = av1_bh4(psz) * 4
    let cx = (self.mi_col >> self.ss) * 4
    let cy = (self.mi_row >> self.ss) * 4
    d += self.sse(1, cx, cy, cw, chh) + self.sse(2, cx, cy, cw, chh)
  }
  d
}

///|
/// Dry-run the current block with `m`; returns its rate-distortion cost.
fn Av1Enc::try_mode(
  self : Av1Enc,
  m : Av1BlockMode,
  search_tx : Bool,
) -> Double {
  self.mode = m
  self.search_tx = search_tx
  let c0 = self.cost
  self.any_nonzero = false
  self.code_block()
  self.search_tx = false
  self.block_sse().to_double() +
  self.lambda * (self.cost - c0).to_double() / 256.0
}

///|
fn av1_copy_mode(m : Av1BlockMode) -> Av1BlockMode {
  {
    ymode: m.ymode,
    uvmode: m.uvmode,
    angle_y: m.angle_y,
    angle_uv: m.angle_uv,
    skip: m.skip,
    tx_types: m.tx_types.copy(),
  }
}

///|
/// Choose the modes of the block at (r, c); leaves the encoder state as
/// after coding the best choice (dry). Returns (cost, modes).
fn Av1Enc::block_rd(
  self : Av1Enc,
  r : Int32,
  c : Int32,
  bs : Int32,
) -> (Double, Av1BlockMode) {
  self.begin_block(r, c, bs)
  let snap = self.snapshot(r, c, bs)
  let cols = self.mi_cols
  let tx = self.tx_size
  let x0 = c * 4
  let y0 = r * 4
  let bw = av1_bw4(bs) * 4
  let bh = av1_bh4(bs) * 4
  let sqrt_l = self.lambda.sqrt()
  let am = av1_intra_mode_context[if self.avail_u {
      self.mi_ymode[(r - 1) * cols + c]
    } else {
      0
    }]
  let lm = av1_intra_mode_context[if self.avail_l {
      self.mi_ymode[r * cols + c - 1]
    } else {
      0
    }]
  let ycdf = self.cdf.kf_y + (am * 5 + lm) * 14
  // Luma pre-selection by SATD + mode bits.
  let cands : Array[(Double, Int32, Int32)] = []
  for mode in 0..<13 {
    let directional = mode >= 1 && mode <= 8
    let angles = if directional && bs >= av1_block_8x8 {
      av1_angle_candidates
    } else {
      [0]
    }
    for a in angles {
      self.predict_tx(0, x0, y0, tx, 0, 0, mode, a)
      let mut bits = av1_symbol_cost(self.cdf.data, ycdf, mode)
      if directional && bs >= av1_block_8x8 {
        bits += av1_symbol_cost(
          self.cdf.data,
          self.cdf.angle + (mode - 1) * 8,
          a + 3,
        )
      }
      let score = self.satd(0, x0, y0, bw, bh).to_double() +
        sqrt_l * bits.to_double() / 256.0
      cands.push((score, mode, a))
    }
  }
  cands.sort_by(fn(p, q) { p.0.compare(q.0) })
  // Chroma mode by SATD (with the best luma mode's CDF).
  let mut uv_best = 0
  let mut uv_angle = 0
  if self.has_chroma {
    let ctx_mode = cands[0].1
    let psz = self.plane_size(1)
    let ctx_tx = self.plane_tx_size(1)
    let cw = av1_bw4(psz) * 4
    let chh = av1_bh4(psz) * 4
    let cx = (c >> self.ss) * 4
    let cy = (r >> self.ss) * 4
    let cfl_ok = (if bw > bh { bw } else { bh }) <= 32
    let mut best_s = 1.0e300
    for mode in 0..<13 {
      let directional = mode >= 1 && mode <= 8
      self.predict_tx(1, cx, cy, ctx_tx, 0, 0, mode, 0)
      self.predict_tx(2, cx, cy, ctx_tx, 0, 0, mode, 0)
      let mut bits = if cfl_ok {
        av1_symbol_cost(self.cdf.data, self.cdf.uv_cfl + ctx_mode * 15, mode)
      } else {
        av1_symbol_cost(self.cdf.data, self.cdf.uv_no_cfl + ctx_mode * 14, mode)
      }
      if directional && bs >= av1_block_8x8 {
        bits += av1_symbol_cost(
          self.cdf.data,
          self.cdf.angle + (mode - 1) * 8,
          3,
        )
      }
      let s = (self.satd(1, cx, cy, cw, chh) + self.satd(2, cx, cy, cw, chh)).to_double() +
        sqrt_l * bits.to_double() / 256.0
      if s < best_s {
        best_s = s
        uv_best = mode
        uv_angle = 0
      }
    }
  }
  // Full rate-distortion for the best luma candidates.
  let mut best_j = 1.0e300
  let mut best = Av1BlockMode::new()
  // State after the best trial (so it need not be coded again).
  let mut best_state : Av1Snap? = None
  let kmax = av1_mode_candidates
  let k = if cands.length() < kmax { cands.length() } else { kmax }
  for i in 0..<k {
    let (_, mode, a) = cands[i]
    self.restore(snap)
    self.begin_block(r, c, bs)
    let m = Av1BlockMode::new()
    m.ymode = mode
    m.angle_y = a
    m.uvmode = uv_best
    m.angle_uv = uv_angle
    let j = self.try_mode(m, true)
    if !self.any_nonzero {
      m.skip = true
    }
    if j < best_j {
      best_j = j
      best = av1_copy_mode(m)
      best_state = if m.skip { None } else { Some(self.snapshot(r, c, bs)) }
    }
  }
  // Skip the residual if that is cheaper.
  if !best.skip {
    self.restore(snap)
    self.begin_block(r, c, bs)
    let m = av1_copy_mode(best)
    m.skip = true
    let j = self.try_mode(m, false)
    if j < best_j {
      best_j = j
      best = av1_copy_mode(m)
      best_state = None
    } else {
      match best_state {
        Some(st) => {
          // Leave the state as after the best choice.
          self.restore(st)
          self.begin_block(r, c, bs)
          self.mode = best
          return (best_j, best)
        }
        None => ()
      }
    }
  }
  // Leave the state as after the best choice.
  self.restore(snap)
  self.begin_block(r, c, bs)
  let fin = av1_copy_mode(best)
  if best.skip {
    // A skipped block re-derives its (DCT) transform types.
    fin.tx_types.clear()
  }
  let j = self.try_mode(fin, false)
  (j, fin)
}

///|
/// Angle deltas tried for directional modes.
let av1_angle_candidates : Array[Int32] = [0]

///|
/// Search the partition tree of a square block (dry); leaves the state as
/// after coding the best tree. Returns (cost, tree).
fn Av1Enc::search(
  self : Av1Enc,
  r : Int32,
  c : Int32,
  bs : Int32,
) -> (Double, Av1Tree) {
  if r >= self.mi_rows || c >= self.mi_cols {
    return (0.0, Empty)
  }
  let half = av1_bw4(bs) >> 1
  let has_rows = r + half < self.mi_rows
  let has_cols = c + half < self.mi_cols
  let can_none = has_rows && has_cols
  let can_split = bs > av1_block_8x8
  let snap0 = self.snapshot(r, c, bs)
  let mut best_j = 1.0e300
  let mut best_tree = Empty
  let mut snap_none : Av1Snap? = None
  if can_none {
    let c0 = self.cost
    self.write_partition(r, c, bs, 0, has_rows, has_cols)
    let pc = self.cost - c0
    let (j, m) = self.block_rd(r, c, bs)
    best_j = j + self.lambda * pc.to_double() / 256.0
    best_tree = Leaf(m)
    if can_split {
      snap_none = Some(self.snapshot(r, c, bs))
      self.restore(snap0)
    }
  }
  if can_split {
    let c0 = self.cost
    self.write_partition(r, c, bs, 3, has_rows, has_cols)
    let pc = self.cost - c0
    let sub = av1_subsize(3, bs)
    let kids : Array[Av1Tree] = []
    let mut j = self.lambda * pc.to_double() / 256.0
    for k in 0..<4 {
      let rr = r + (k >> 1) * half
      let cc = c + (k & 1) * half
      let (jk, tk) = self.search(rr, cc, sub)
      j += jk
      kids.push(tk)
    }
    if j < best_j {
      best_j = j
      best_tree = Split(kids)
    } else {
      match snap_none {
        Some(s) => self.restore(s)
        None => ()
      }
    }
  }
  (best_j, best_tree)
}

///|
/// Write a decided partition tree.
fn Av1Enc::write_tree(
  self : Av1Enc,
  r : Int32,
  c : Int32,
  bs : Int32,
  tree : Av1Tree,
) -> Unit {
  if r >= self.mi_rows || c >= self.mi_cols {
    return
  }
  let half = av1_bw4(bs) >> 1
  let has_rows = r + half < self.mi_rows
  let has_cols = c + half < self.mi_cols
  match tree {
    Leaf(m) => {
      self.write_partition(r, c, bs, 0, has_rows, has_cols)
      self.begin_block(r, c, bs)
      self.mode = m
      self.search_tx = false
      self.code_block()
    }
    Split(kids) => {
      self.write_partition(r, c, bs, 3, has_rows, has_cols)
      let sub = av1_subsize(3, bs)
      for k in 0..<4 {
        self.write_tree(r + (k >> 1) * half, c + (k & 1) * half, sub, kids[k])
      }
    }
    Empty => ()
  }
}
