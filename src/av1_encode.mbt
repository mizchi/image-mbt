// AV1 intra frame encoder (one key frame, 8-bit, 4:2:0 or monochrome):
// partition / mode info / residual coding as in the spec's decoding
// process, with the decoder's reconstruction mirrored exactly.

///|
let av1_block_8x8 = 3

///|
let av1_block_64x64 = 12

///|
fn av1_bw4(bs : Int32) -> Int32 {
  1 << av1_mi_width_log2[bs]
}

///|
fn av1_bh4(bs : Int32) -> Int32 {
  1 << av1_mi_height_log2[bs]
}

///|
/// Partition_Subsize for square sizes (8x8 .. 64x64): NONE, HORZ, VERT,
/// SPLIT.
fn av1_subsize(partition : Int32, bs : Int32) -> Int32 {
  match (partition, bs) {
    (0, _) => bs
    (1, 3) => 2
    (1, 6) => 5
    (1, 9) => 8
    (1, _) => 11
    (2, 3) => 1
    (2, 6) => 4
    (2, 9) => 7
    (2, _) => 10
    (_, 3) => 0
    (_, 6) => 3
    (_, 9) => 6
    _ => 9
  }
}

///|
fn av1_scan_for(tx_size : Int32) -> FixedArray[Int32] {
  match tx_size {
    0 => av1_scan_4x4
    1 => av1_scan_8x8
    2 => av1_scan_16x16
    3 | 4 | 11 | 12 => av1_scan_32x32
    5 => av1_scan_4x8
    6 => av1_scan_8x4
    7 => av1_scan_8x16
    8 => av1_scan_16x8
    9 | 17 => av1_scan_16x32
    10 | 18 => av1_scan_32x16
    13 => av1_scan_4x16
    14 => av1_scan_16x4
    15 => av1_scan_8x32
    _ => av1_scan_32x8
  }
}

///|
/// Intra transform set with reduced_tx_set = 1: 0 DCT only, 2 INTRA_2.
fn av1_tx_set(tx_size : Int32) -> Int32 {
  if av1_tx_size_sqr_up[tx_size] >= 3 {
    0
  } else {
    2
  }
}

///|
/// Index of a transform type in Tx_Type_Intra_Inv_Set2 (IDTX, DCT_DCT,
/// ADST_ADST, ADST_DCT, DCT_ADST).
fn av1_itx2_index(tx_type : Int32) -> Int32 {
  match tx_type {
    9 => 0
    0 => 1
    3 => 2
    1 => 3
    _ => 4
  }
}

///|
/// Mode decisions of one block.
priv struct Av1BlockMode {
  mut ymode : Int32
  mut uvmode : Int32
  mut angle_y : Int32
  mut angle_uv : Int32
  mut skip : Bool
  // Luma transform type of each transform block, raster order.
  tx_types : Array[Int32]
}

///|
fn Av1BlockMode::new() -> Av1BlockMode {
  { ymode: 0, uvmode: 0, angle_y: 0, angle_uv: 0, skip: false, tx_types: [], }
}

///|
priv struct Av1Enc {
  width : Int32
  height : Int32
  mi_cols : Int32
  mi_rows : Int32
  num_planes : Int32
  ss : Int32
  stride : FixedArray[Int32]
  src : Array[FixedArray[Int32]]
  rec : Array[FixedArray[Int32]]
  qidx : Int32
  dcq : Int32
  acq : Int32
  // Mode info grid (mi units, frame).
  mi_size : FixedArray[Int32]
  mi_ymode : FixedArray[Int32]
  mi_uvmode : FixedArray[Int32]
  mi_skip : FixedArray[Int32]
  // Luma transform type per 4x4.
  tx_types : FixedArray[Int32]
  above_level : Array[FixedArray[Int32]]
  above_dc : Array[FixedArray[Int32]]
  left_level : Array[FixedArray[Int32]]
  left_dc : Array[FixedArray[Int32]]
  // BlockDecoded: 3 planes x 18 x 18, offset 1.
  decoded : FixedArray[Bool]
  cdf : Av1Cdfs
  sw : Av1SymWriter
  edges : Av1Edges
  mut dry : Bool
  mut search_tx : Bool
  mut ready_eob : Int32
  lambda : Double
  mut cost : Int32
  mut any_nonzero : Bool
  // Current block.
  mut mi_row : Int32
  mut mi_col : Int32
  mut bsize : Int32
  mut avail_u : Bool
  mut avail_l : Bool
  mut avail_uc : Bool
  mut avail_lc : Bool
  mut has_chroma : Bool
  mut tx_size : Int32
  mut mode : Av1BlockMode
  mut tx_index : Int32
  // Scratch.
  res : FixedArray[Int32]
  coef : FixedArray[Double]
  levels : FixedArray[Int32]
  dq : FixedArray[Int32]
  quant_ctx : FixedArray[Int32]
}

///|
fn Av1Enc::new(
  planes : Array[FixedArray[Int32]],
  width : Int32,
  height : Int32,
  qidx : Int32,
) -> Av1Enc {
  let num_planes = planes.length()
  let mi_cols = 2 * ((width + 7) >> 3)
  let mi_rows = 2 * ((height + 7) >> 3)
  // Planes are allocated in whole superblocks (blocks may extend past the
  // mode info area) and padded by edge replication.
  let aw = (mi_cols * 4 + 63) / 64 * 64
  let ah = (mi_rows * 4 + 63) / 64 * 64
  let ss = if num_planes > 1 { 1 } else { 0 }
  let stride = FixedArray::makei(num_planes, fn(p) {
    if p == 0 {
      aw
    } else {
      aw >> ss
    }
  })
  let src : Array[FixedArray[Int32]] = []
  let rec : Array[FixedArray[Int32]] = []
  for p in 0..<num_planes {
    let pw = if p == 0 { width } else { (width + ss) >> ss }
    let ph = if p == 0 { height } else { (height + ss) >> ss }
    let sw = stride[p]
    let sh = if p == 0 { ah } else { ah >> ss }
    let s = FixedArray::make(sw * sh, 0)
    for y in 0..<sh {
      let yy = if y < ph { y } else { ph - 1 }
      for x in 0..<sw {
        let xx = if x < pw { x } else { pw - 1 }
        s[y * sw + x] = planes[p][yy * pw + xx]
      }
    }
    src.push(s)
    rec.push(FixedArray::make(sw * sh, 0))
  }
  let ctx_w = aw / 4 + 32
  let ctx_h = ah / 4 + 32
  {
    width,
    height,
    mi_cols,
    mi_rows,
    num_planes,
    ss,
    stride,
    src,
    rec,
    qidx,
    dcq: av1_dc_qlookup[qidx],
    acq: av1_ac_qlookup[qidx],
    mi_size: FixedArray::make(mi_cols * mi_rows, 0),
    mi_ymode: FixedArray::make(mi_cols * mi_rows, 0),
    mi_uvmode: FixedArray::make(mi_cols * mi_rows, 0),
    mi_skip: FixedArray::make(mi_cols * mi_rows, 0),
    tx_types: FixedArray::make(mi_cols * mi_rows, 0),
    above_level: Array::makei(3, fn(_) { FixedArray::make(ctx_w, 0) }),
    above_dc: Array::makei(3, fn(_) { FixedArray::make(ctx_w, 0) }),
    left_level: Array::makei(3, fn(_) { FixedArray::make(ctx_h, 0) }),
    left_dc: Array::makei(3, fn(_) { FixedArray::make(ctx_h, 0) }),
    decoded: FixedArray::make(3 * 18 * 18, false),
    cdf: Av1Cdfs::new(qidx),
    sw: Av1SymWriter::new(),
    edges: Av1Edges::new(),
    dry: false,
    search_tx: false,
    ready_eob: -1,
    lambda: av1_lambda(qidx),
    cost: 0,
    any_nonzero: false,
    mi_row: 0,
    mi_col: 0,
    bsize: 0,
    avail_u: false,
    avail_l: false,
    avail_uc: false,
    avail_lc: false,
    has_chroma: false,
    tx_size: 0,
    mode: Av1BlockMode::new(),
    tx_index: 0,
    res: FixedArray::make(64 * 64, 0),
    coef: FixedArray::make(64 * 64, 0.0),
    levels: FixedArray::make(32 * 32, 0),
    dq: FixedArray::make(64 * 64, 0),
    quant_ctx: FixedArray::make(32 * 32, 0),
  }
}

///|
/// Code a symbol (or, in a dry run, add its cost).
fn Av1Enc::sym(self : Av1Enc, off : Int32, n : Int32, s : Int32) -> Unit {
  if self.dry {
    self.cost += av1_symbol_cost(self.cdf.data, off, s)
  } else {
    self.sw.symbol(self.cdf.data, off, n, s)
  }
}

///|
fn Av1Enc::literal(self : Av1Enc, v : Int32, n : Int32) -> Unit {
  if self.dry {
    self.cost += 256 * n
  } else {
    self.sw.literal(v, n)
  }
}

///|
fn Av1Enc::inside(self : Av1Enc, r : Int32, c : Int32) -> Bool {
  r >= 0 && c >= 0 && r < self.mi_rows && c < self.mi_cols
}

///|
fn Av1Enc::dec_idx(plane : Int32, y : Int32, x : Int32) -> Int32 {
  plane * 324 + (y + 1) * 18 + (x + 1)
}

///|
/// clear_block_decoded_flags for the superblock at (r, c).
fn Av1Enc::clear_decoded(self : Av1Enc, r : Int32, c : Int32) -> Unit {
  let sb4 = 16
  for plane in 0..<self.num_planes {
    let sub = if plane > 0 { self.ss } else { 0 }
    let sbw4 = (self.mi_cols - c) >> sub
    let sbh4 = (self.mi_rows - r) >> sub
    for y = -1; y <= sb4 >> sub; y = y + 1 {
      for x = -1; x <= sb4 >> sub; x = x + 1 {
        self.decoded[Av1Enc::dec_idx(plane, y, x)] = if y < 0 && x < sbw4 {
          true
        } else if x < 0 && y < sbh4 {
          true
        } else {
          false
        }
      }
    }
    self.decoded[Av1Enc::dec_idx(plane, sb4 >> sub, -1)] = false
  }
}

///|
/// Partition symbol context for a square block at (r, c).
fn Av1Enc::partition_ctx(
  self : Av1Enc,
  r : Int32,
  c : Int32,
  bs : Int32,
) -> Int32 {
  let bsl = av1_mi_width_log2[bs]
  let above = self.inside(r - 1, c) &&
    av1_mi_width_log2[self.mi_size[(r - 1) * self.mi_cols + c]] < bsl
  let left = self.inside(r, c - 1) &&
    av1_mi_height_log2[self.mi_size[r * self.mi_cols + c - 1]] < bsl
  (if left { 2 } else { 0 }) + (if above { 1 } else { 0 })
}

///|
/// (offset, symbols) of the partition CDF for a square block size.
fn Av1Enc::partition_cdf(
  self : Av1Enc,
  bs : Int32,
  ctx : Int32,
) -> (Int32, Int32) {
  match av1_mi_width_log2[bs] {
    1 => (self.cdf.part8 + ctx * 5, 4)
    2 => (self.cdf.part16 + ctx * 11, 10)
    3 => (self.cdf.part32 + ctx * 11, 10)
    4 => (self.cdf.part64 + ctx * 11, 10)
    _ => (self.cdf.part128 + ctx * 9, 8)
  }
}

///|
/// Write the partition of a square block (or its split_or_horz /
/// split_or_vert form at the frame edges).
fn Av1Enc::write_partition(
  self : Av1Enc,
  r : Int32,
  c : Int32,
  bs : Int32,
  partition : Int32,
  has_rows : Bool,
  has_cols : Bool,
) -> Unit {
  let ctx = self.partition_ctx(r, c, bs)
  let (off, n) = self.partition_cdf(bs, ctx)
  let cdf = self.cdf.data
  if has_rows && has_cols {
    self.sym(off, n, partition)
  } else if has_cols || has_rows {
    // The probability of "split" gathers the partitions that also split
    // in the missing direction.
    let p = fn(k : Int32) { cdf[off + k] - cdf[off + k - 1] }
    let mut psum = if has_cols {
      // split_or_horz: VERT, SPLIT, HORZ_A, VERT_A, VERT_B, VERT_4
      p(2) + p(3) + p(4) + p(6) + p(7)
    } else {
      // split_or_vert: HORZ, SPLIT, HORZ_A, HORZ_B, VERT_A, HORZ_4
      p(1) + p(3) + p(4) + p(5) + p(6)
    }
    if bs != 15 {
      psum += if has_cols { p(9) } else { p(8) }
    }
    let bit = if partition == 3 { 1 } else { 0 }
    let f0 = 32768 - psum
    if self.dry {
      self.cost += av1_cost_q15(if bit == 1 { psum } else { f0 })
    } else if bit == 0 {
      self.sw.store(32768, 32768 - f0, 2)
    } else {
      self.sw.store(32768 - f0, 0, 1)
    }
  }
}

///|
/// Set up the current block's position variables.
fn Av1Enc::begin_block(self : Av1Enc, r : Int32, c : Int32, bs : Int32) -> Unit {
  self.mi_row = r
  self.mi_col = c
  self.bsize = bs
  let bw4 = av1_bw4(bs)
  let bh4 = av1_bh4(bs)
  let ss = self.ss
  self.has_chroma = if self.num_planes == 1 {
    false
  } else if bh4 == 1 && ss == 1 && (r & 1) == 0 {
    false
  } else if bw4 == 1 && ss == 1 && (c & 1) == 0 {
    false
  } else {
    true
  }
  self.avail_u = self.inside(r - 1, c)
  self.avail_l = self.inside(r, c - 1)
  self.avail_uc = self.avail_u
  self.avail_lc = self.avail_l
  if self.has_chroma {
    if ss == 1 && bh4 == 1 {
      self.avail_uc = self.inside(r - 2, c)
    }
    if ss == 1 && bw4 == 1 {
      self.avail_lc = self.inside(r, c - 2)
    }
  } else {
    self.avail_uc = false
    self.avail_lc = false
  }
  self.tx_size = av1_max_tx_size_rect[bs]
}

///|
/// Plane residual size of the current block.
fn Av1Enc::plane_size(self : Av1Enc, plane : Int32) -> Int32 {
  let sub = if plane > 0 { self.ss } else { 0 }
  av1_subsampled_size[self.bsize * 4 + sub * 2 + sub]
}

///|
fn Av1Enc::plane_tx_size(self : Av1Enc, plane : Int32) -> Int32 {
  if plane == 0 {
    return self.tx_size
  }
  let uv = av1_max_tx_size_rect[self.plane_size(plane)]
  let w = 1 << av1_tx_width_log2[uv]
  let h = 1 << av1_tx_height_log2[uv]
  if w == 64 || h == 64 {
    if w == 16 {
      9 // TX_16X32
    } else if h == 16 {
      10 // TX_32X16
    } else {
      3 // TX_32X32
    }
  } else {
    uv
  }
}

///|
/// Encode the mode info and residual of the current block (set up by
/// begin_block) with the decisions in self.mode.
fn Av1Enc::code_block(self : Av1Enc) -> Unit {
  let r = self.mi_row
  let c = self.mi_col
  let bs = self.bsize
  let cols = self.mi_cols
  let m = self.mode
  let bw4 = av1_bw4(bs)
  let bh4 = av1_bh4(bs)
  // skip
  let sctx = (if self.avail_u { self.mi_skip[(r - 1) * cols + c] } else { 0 }) +
    (if self.avail_l { self.mi_skip[r * cols + c - 1] } else { 0 })
  self.sym(self.cdf.skip + sctx * 3, 2, if m.skip { 1 } else { 0 })
  // intra_frame_y_mode
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
  self.sym(self.cdf.kf_y + (am * 5 + lm) * 14, 13, m.ymode)
  if bs >= av1_block_8x8 && m.ymode >= 1 && m.ymode <= 8 {
    self.sym(self.cdf.angle + (m.ymode - 1) * 8, 7, m.angle_y + 3)
  }
  if self.has_chroma {
    let bw = bw4 * 4
    let bh = bh4 * 4
    if (if bw > bh { bw } else { bh }) <= 32 {
      self.sym(self.cdf.uv_cfl + m.ymode * 15, 14, m.uvmode)
    } else {
      self.sym(self.cdf.uv_no_cfl + m.ymode * 14, 13, m.uvmode)
    }
    if bs >= av1_block_8x8 && m.uvmode >= 1 && m.uvmode <= 8 {
      self.sym(self.cdf.angle + (m.uvmode - 1) * 8, 7, m.angle_uv + 3)
    }
  }
  if m.skip {
    // reset_block_context
    for plane in 0..<(if self.has_chroma { 3 } else { 1 }) {
      let sub = if plane > 0 { self.ss } else { 0 }
      for i = c >> sub; i < (c + bw4) >> sub; i = i + 1 {
        self.above_level[plane][i] = 0
        self.above_dc[plane][i] = 0
      }
      for i = r >> sub; i < (r + bh4) >> sub; i = i + 1 {
        self.left_level[plane][i] = 0
        self.left_dc[plane][i] = 0
      }
    }
  }
  for y in 0..<bh4 {
    for x in 0..<bw4 {
      if r + y < self.mi_rows && c + x < cols {
        self.mi_ymode[(r + y) * cols + c + x] = m.ymode
        if self.has_chroma {
          self.mi_uvmode[(r + y) * cols + c + x] = m.uvmode
        }
      }
    }
  }
  // residual
  self.tx_index = 0
  for plane in 0..<(if self.has_chroma { 3 } else { 1 }) {
    let tx = self.plane_tx_size(plane)
    let step_x = 1 << av1_tx_width_log2[tx] >> 2
    let step_y = 1 << av1_tx_height_log2[tx] >> 2
    let psz = self.plane_size(plane)
    let n4w = av1_bw4(psz)
    let n4h = av1_bh4(psz)
    let sub = if plane > 0 { self.ss } else { 0 }
    let base_x = (c >> sub) * 4
    let base_y = (r >> sub) * 4
    for y = 0; y < n4h; y = y + step_y {
      for x = 0; x < n4w; x = x + step_x {
        self.transform_block(plane, base_x, base_y, tx, x, y)
      }
    }
  }
  for y in 0..<bh4 {
    for x in 0..<bw4 {
      if r + y < self.mi_rows && c + x < cols {
        self.mi_skip[(r + y) * cols + c + x] = if m.skip { 1 } else { 0 }
        self.mi_size[(r + y) * cols + c + x] = bs
      }
    }
  }
}

///|
/// Predict, code and reconstruct one transform block.
fn Av1Enc::transform_block(
  self : Av1Enc,
  plane : Int32,
  base_x : Int32,
  base_y : Int32,
  tx : Int32,
  x : Int32,
  y : Int32,
) -> Unit {
  let start_x = base_x + 4 * x
  let start_y = base_y + 4 * y
  let sub = if plane > 0 { self.ss } else { 0 }
  let row = start_y << sub >> 2
  let col = start_x << sub >> 2
  let sb_row = row & 15
  let sb_col = col & 15
  let log2w = av1_tx_width_log2[tx]
  let log2h = av1_tx_height_log2[tx]
  let step_x = 1 << log2w >> 2
  let step_y = 1 << log2h >> 2
  let max_x = (self.mi_cols * 4) >> sub
  let max_y = (self.mi_rows * 4) >> sub
  if start_x >= max_x || start_y >= max_y {
    return
  }
  let m = self.mode
  let mode = if plane == 0 { m.ymode } else { m.uvmode }
  let angle = if plane == 0 { m.angle_y } else { m.angle_uv }
  self.predict_tx(plane, start_x, start_y, tx, x, y, mode, angle)
  // Transform type.
  let tx_type = if plane == 0 {
    if self.search_tx {
      let t = if av1_tx_set(tx) == 0 || m.skip {
        0
      } else {
        self.choose_tx_type(start_x, start_y, tx)
      }
      m.tx_types.push(t)
      t
    } else {
      let t = if self.tx_index < m.tx_types.length() {
        m.tx_types[self.tx_index]
      } else {
        0
      }
      self.tx_index += 1
      if av1_tx_set(tx) == 0 {
        0
      } else {
        t
      }
    }
  } else {
    let t = av1_mode_to_txfm[m.uvmode]
    if av1_tx_set(tx) == 0 {
      0
    } else {
      t
    }
  }
  self.code_residual(plane, start_x, start_y, tx, tx_type)
  for i in 0..<step_y {
    for j in 0..<step_x {
      self.decoded[Av1Enc::dec_idx(
        plane,
        (sb_row >> sub) + i,
        (sb_col >> sub) + j,
      )] = true
    }
  }
}

///|
/// Intra prediction of one transform block (spec transform_block
/// availability rules) into the reconstruction.
fn Av1Enc::predict_tx(
  self : Av1Enc,
  plane : Int32,
  start_x : Int32,
  start_y : Int32,
  tx : Int32,
  x : Int32,
  y : Int32,
  mode : Int32,
  angle : Int32,
) -> Unit {
  let sub = if plane > 0 { self.ss } else { 0 }
  let row = start_y << sub >> 2
  let col = start_x << sub >> 2
  let sb_row = row & 15
  let sb_col = col & 15
  let log2w = av1_tx_width_log2[tx]
  let log2h = av1_tx_height_log2[tx]
  let step_x = 1 << log2w >> 2
  let step_y = 1 << log2h >> 2
  let max_x = (self.mi_cols * 4) >> sub
  let max_y = (self.mi_rows * 4) >> sub
  let have_left = (if plane == 0 { self.avail_l } else { self.avail_lc }) ||
    x > 0
  let have_above = (if plane == 0 { self.avail_u } else { self.avail_uc }) ||
    y > 0
  let have_ar = self.decoded[Av1Enc::dec_idx(
      plane,
      (sb_row >> sub) - 1,
      (sb_col >> sub) + step_x,
    )]
  let have_bl = self.decoded[Av1Enc::dec_idx(
      plane,
      (sb_row >> sub) + step_y,
      (sb_col >> sub) - 1,
    )]
  av1_predict_intra(
    self.rec[plane],
    self.stride[plane],
    start_x,
    start_y,
    have_left,
    have_above,
    have_ar,
    have_bl,
    mode,
    angle,
    log2w,
    log2h,
    max_x - 1,
    max_y - 1,
    self.edges,
  )
}

///|
/// Quantize, code and reconstruct the residual of a predicted transform
/// block.
fn Av1Enc::code_residual(
  self : Av1Enc,
  plane : Int32,
  start_x : Int32,
  start_y : Int32,
  tx : Int32,
  tx_type : Int32,
) -> Unit {
  if !self.mode.skip {
    // The transform type search leaves the chosen levels ready.
    let eob = if self.ready_eob >= 0 {
      let e = self.ready_eob
      self.ready_eob = -1
      e
    } else {
      self.quantize(plane, start_x, start_y, tx, tx_type)
    }
    if eob > 0 {
      self.any_nonzero = true
    }
    self.coeffs(plane, start_x, start_y, tx, tx_type, eob)
    if eob > 0 {
      self.reconstruct(plane, start_x, start_y, tx, tx_type)
    }
  } else if plane == 0 {
    self.set_tx_types(start_x >> 2, start_y >> 2, tx, 0)
  }
}

///|
/// Sum of squared differences between source and reconstruction over the
/// visible part of a plane rectangle.
fn Av1Enc::sse(
  self : Av1Enc,
  plane : Int32,
  x0 : Int32,
  y0 : Int32,
  w : Int32,
  h : Int32,
) -> Int32 {
  let sub = if plane > 0 { self.ss } else { 0 }
  let pw = (self.width + sub) >> sub
  let ph = (self.height + sub) >> sub
  let x1 = if x0 + w < pw { x0 + w } else { pw }
  let y1 = if y0 + h < ph { y0 + h } else { ph }
  let st = self.stride[plane]
  let src = self.src[plane]
  let rec = self.rec[plane]
  let mut s = 0
  for y in y0..<y1 {
    for x in x0..<x1 {
      let d = src[y * st + x] - rec[y * st + x]
      s += d * d
    }
  }
  s
}

///|
/// Pick the luma transform type of a (predicted) transform block by
/// rate-distortion over the INTRA_2 set; leaves the block unchanged.
fn Av1Enc::choose_tx_type(
  self : Av1Enc,
  start_x : Int32,
  start_y : Int32,
  tx : Int32,
) -> Int32 {
  let w = 1 << av1_tx_width_log2[tx]
  let h = 1 << av1_tx_height_log2[tx]
  let w4 = w >> 2
  let h4 = h >> 2
  let x4 = start_x >> 2
  let y4 = start_y >> 2
  let tw = if w > 32 { 32 } else { w }
  let th = if h > 32 { 32 } else { h }
  let al = FixedArray::makei(w4, fn(i) { self.above_level[0][x4 + i] })
  let ad = FixedArray::makei(w4, fn(i) { self.above_dc[0][x4 + i] })
  let ll = FixedArray::makei(h4, fn(i) { self.left_level[0][y4 + i] })
  let ld = FixedArray::makei(h4, fn(i) { self.left_dc[0][y4 + i] })
  let best_levels = FixedArray::make(tw * th, 0)
  let mut best = 0
  let mut best_eob = 0
  let mut best_j = 1.0e300
  // Each type is scored without reconstructing: the distortion comes from
  // the quantization error in the transform domain, the rate from the
  // coefficient coder.
  av1_row_cache_on()
  for t in [0, 3, 1, 2, 9] {
    let c0 = self.cost
    let eob = self.quantize(0, start_x, start_y, tx, t)
    let d = self.coef_distortion(tx, t)
    self.coeffs(0, start_x, start_y, tx, t, eob)
    let j = d + self.lambda * (self.cost - c0).to_double() / 256.0
    if j < best_j {
      best_j = j
      best = t
      best_eob = eob
      for i in 0..<(tw * th) {
        best_levels[i] = self.levels[i]
      }
    }
    // Undo the coder state.
    self.cost = c0
    for i in 0..<w4 {
      self.above_level[0][x4 + i] = al[i]
      self.above_dc[0][x4 + i] = ad[i]
    }
    for i in 0..<h4 {
      self.left_level[0][y4 + i] = ll[i]
      self.left_dc[0][y4 + i] = ld[i]
    }
    // A residual that quantizes to zero with the DCT is not worth other
    // transforms.
    if t == 0 && eob == 0 {
      break
    }
  }
  av1_row_cache_off()
  for i in 0..<(tw * th) {
    self.levels[i] = best_levels[i]
  }
  self.ready_eob = best_eob
  best
}

///|
/// Squared error (in pixels) of the quantized coefficients, estimated in
/// the transform domain.
fn Av1Enc::coef_distortion(
  self : Av1Enc,
  tx : Int32,
  tx_type : Int32,
) -> Double {
  let w = 1 << av1_tx_width_log2[tx]
  let h = 1 << av1_tx_height_log2[tx]
  let tw = if w > 32 { 32 } else { w }
  let th = if h > 32 { 32 } else { h }
  let denom = av1_dq_denom(tx)
  let mut s = 0.0
  for i in 0..<th {
    for j in 0..<tw {
      let l = self.levels[i * tw + j]
      let q = if i == 0 && j == 0 { self.dcq } else { self.acq }
      let mag = ((l * q).abs() & 0xFFFFFF) / denom
      let dq = if l < 0 { -mag } else { mag }
      let e = self.coef[i * w + j] - dq.to_double()
      s = s + e * e
    }
  }
  s * av1_coef_gain(tx, tx_type)
}

///|
let av1_coef_gains : FixedArray[Double] = FixedArray::make(19 * 16, -1.0)

///|
/// Pixel energy per coefficient energy of a transform (measured once on a
/// pseudo-random residual).
fn av1_coef_gain(tx : Int32, tx_type : Int32) -> Double {
  let k = tx * 16 + tx_type
  if av1_coef_gains[k] >= 0.0 {
    return av1_coef_gains[k]
  }
  let w = 1 << av1_tx_width_log2[tx]
  let h = 1 << av1_tx_height_log2[tx]
  let res = FixedArray::make(w * h, 0)
  let mut seed = 1U
  let mut pe = 0.0
  for i in 0..<(w * h) {
    seed = seed * 1103515245U + 12345U
    res[i] = ((seed >> 16) % 201U).reinterpret_as_int() - 100
    pe = pe + (res[i] * res[i]).to_double()
  }
  let coef = FixedArray::make(w * h, 0.0)
  // Measured outside any row cache (the cache holds the block's residual).
  let cached = av1_row_cache.enabled
  av1_row_cache.enabled = false
  av1_forward_2d(res, tx, tx_type, coef)
  av1_row_cache.enabled = cached
  let mut ce = 0.0
  for i in 0..<(w * h) {
    ce = ce + coef[i] * coef[i]
  }
  let g = pe / ce
  av1_coef_gains[k] = g
  g
}

///|
/// Rate-distortion multiplier (per bit, in squared-error units).
fn av1_lambda(qidx : Int32) -> Double {
  let q = av1_ac_qlookup[qidx].to_double() / 8.0
  av1_lambda_scale * q * q
}

///|
let av1_lambda_scale : Double = 0.14

///|
fn Av1Enc::set_tx_types(
  self : Av1Enc,
  x4 : Int32,
  y4 : Int32,
  tx : Int32,
  t : Int32,
) -> Unit {
  let w4 = 1 << av1_tx_width_log2[tx] >> 2
  let h4 = 1 << av1_tx_height_log2[tx] >> 2
  for j in 0..<h4 {
    for i in 0..<w4 {
      if y4 + j < self.mi_rows && x4 + i < self.mi_cols {
        self.tx_types[(y4 + j) * self.mi_cols + x4 + i] = t
      }
    }
  }
}

///|
/// Forward transform and quantize the residual (source - prediction) of a
/// transform block into self.levels (pos = row * tw + col); returns eob.
fn Av1Enc::quantize(
  self : Av1Enc,
  plane : Int32,
  x0 : Int32,
  y0 : Int32,
  tx : Int32,
  tx_type : Int32,
) -> Int32 {
  let w = 1 << av1_tx_width_log2[tx]
  let h = 1 << av1_tx_height_log2[tx]
  let stride = self.stride[plane]
  let src = self.src[plane]
  let rec = self.rec[plane]
  for i in 0..<h {
    for j in 0..<w {
      let o = (y0 + i) * stride + x0 + j
      self.res[i * w + j] = src[o] - rec[o]
    }
  }
  av1_forward_2d(self.res, tx, tx_type, self.coef)
  let tw = if w > 32 { 32 } else { w }
  let th = if h > 32 { 32 } else { h }
  let denom = av1_dq_denom(tx).to_double()
  let inv_dc = denom / self.dcq.to_double()
  let inv_ac = denom / self.acq.to_double()
  // |coefficient| * inv_ac below this quantizes to zero.
  let zero_ac = 1.0 - av1_round_ac
  let iscan = av1_iscan_for(tx)
  let mut eob = 0
  for i in 0..<th {
    for j in 0..<tw {
      let v = self.coef[i * w + j]
      let pos = i * tw + j
      let dc = i == 0 && j == 0
      let a = v.abs() * (if dc { inv_dc } else { inv_ac })
      if !dc && a < zero_ac {
        self.levels[pos] = 0
        continue
      }
      let l = (a + (if dc { 0.5 } else { av1_round_ac })).to_int()
      let l = if l > 0xFFFF { 0xFFFF } else { l }
      self.levels[pos] = if v < 0.0 { -l } else { l }
      if l != 0 && iscan[pos] >= eob {
        eob = iscan[pos] + 1
      }
    }
  }
  eob
}

///|
/// Rounding offset of the AC quantizer (0.5 is plain rounding).
let av1_round_ac : Double = 0.4

///|
/// Inverse scans (position -> scan index), per transform size.
let av1_iscans : FixedArray[FixedArray[Int32]] = FixedArray::makei(19, fn(tx) {
  let scan = av1_scan_for(tx)
  let inv = FixedArray::make(scan.length(), 0)
  for c in 0..<scan.length() {
    inv[scan[c]] = c
  }
  inv
})

///|
fn av1_iscan_for(tx : Int32) -> FixedArray[Int32] {
  av1_iscans[tx]
}

///|
fn av1_dq_denom(tx : Int32) -> Int32 {
  match tx {
    3 | 9 | 10 | 17 | 18 => 2
    4 | 11 | 12 => 4
    _ => 1
  }
}

///|
/// Dequantize self.levels and add the inverse transform to the
/// reconstruction (the spec's reconstruct process).
fn Av1Enc::reconstruct(
  self : Av1Enc,
  plane : Int32,
  x0 : Int32,
  y0 : Int32,
  tx : Int32,
  tx_type : Int32,
) -> Unit {
  let w = 1 << av1_tx_width_log2[tx]
  let h = 1 << av1_tx_height_log2[tx]
  let tw = if w > 32 { 32 } else { w }
  let th = if h > 32 { 32 } else { h }
  let denom = av1_dq_denom(tx)
  for i in 0..<th {
    for j in 0..<tw {
      self.dq[i * w + j] = 0
    }
  }
  for i in 0..<th {
    for j in 0..<tw {
      let l = self.levels[i * tw + j]
      if l != 0 {
        let q = if i == 0 && j == 0 { self.dcq } else { self.acq }
        let dq = l * q
        let mag = (dq.abs() & 0xFFFFFF) / denom
        let v = if dq < 0 { -mag } else { mag }
        let lim = 1 << 15
        self.dq[i * w + j] = if v < -lim {
          -lim
        } else if v > lim - 1 {
          lim - 1
        } else {
          v
        }
      }
    }
  }
  let mut rows = 0
  for i in 0..<th {
    for j in 0..<tw {
      if self.levels[i * tw + j] != 0 {
        rows = i + 1
      }
    }
  }
  av1_inverse_2d(self.dq, tx, tx_type, self.res, rows~)
  let stride = self.stride[plane]
  let rec = self.rec[plane]
  for i in 0..<h {
    for j in 0..<w {
      let o = (y0 + i) * stride + x0 + j
      rec[o] = av1_clip_pixel(rec[o] + self.res[i * w + j])
    }
  }
}

///|
/// Code the coefficients of a transform block (the spec's coeffs()):
/// self.levels holds the signed levels, `eob` the end of block.
fn Av1Enc::coeffs(
  self : Av1Enc,
  plane : Int32,
  start_x : Int32,
  start_y : Int32,
  tx : Int32,
  tx_type : Int32,
  eob : Int32,
) -> Unit {
  let x4 = start_x >> 2
  let y4 = start_y >> 2
  let log2w = av1_tx_width_log2[tx]
  let log2h = av1_tx_height_log2[tx]
  let w4 = 1 << log2w >> 2
  let h4 = 1 << log2h >> 2
  let tx_sz_ctx = (av1_tx_size_sqr[tx] + av1_tx_size_sqr_up[tx] + 1) >> 1
  let ptype = if plane > 0 { 1 } else { 0 }
  let sub = if plane > 0 { self.ss } else { 0 }
  let max_x4 = self.mi_cols >> sub
  let max_y4 = self.mi_rows >> sub
  let cdf = self.cdf
  // all_zero context.
  let w = 1 << log2w
  let h = 1 << log2h
  let psz = self.plane_size(plane)
  let bw = av1_bw4(psz) * 4
  let bh = av1_bh4(psz) * 4
  let az_ctx = if plane == 0 {
    let mut top = 0
    let mut left = 0
    for k in 0..<w4 {
      if x4 + k < max_x4 && self.above_level[0][x4 + k] > top {
        top = self.above_level[0][x4 + k]
      }
    }
    for k in 0..<h4 {
      if y4 + k < max_y4 && self.left_level[0][y4 + k] > left {
        left = self.left_level[0][y4 + k]
      }
    }
    let mx = if top > left { top } else { left }
    let mn = if top < left { top } else { left }
    if bw == w && bh == h {
      0
    } else if top == 0 && left == 0 {
      1
    } else if top == 0 || left == 0 {
      2 + (if mx > 3 { 1 } else { 0 })
    } else if mx <= 3 {
      4
    } else if mn <= 3 {
      5
    } else {
      6
    }
  } else {
    let mut above = 0
    let mut left = 0
    for i in 0..<w4 {
      if x4 + i < max_x4 {
        above = above |
          self.above_level[plane][x4 + i] |
          self.above_dc[plane][x4 + i]
      }
    }
    for i in 0..<h4 {
      if y4 + i < max_y4 {
        left = left |
          self.left_level[plane][y4 + i] |
          self.left_dc[plane][y4 + i]
      }
    }
    let base = 7 +
      (if above != 0 { 1 } else { 0 }) +
      (if left != 0 { 1 } else { 0 })
    if bw * bh > w * h {
      base + 3
    } else {
      base
    }
  }
  self.sym(
    cdf.txb_skip + (tx_sz_ctx * 13 + az_ctx) * 3,
    2,
    if eob == 0 {
      1
    } else {
      0
    },
  )
  let mut cul_level = 0
  let mut dc_category = 0
  if eob == 0 {
    if plane == 0 {
      self.set_tx_types(x4, y4, tx, 0)
    }
  } else {
    if plane == 0 {
      // transform_type
      if av1_tx_set(tx) > 0 && self.qidx > 0 {
        let sqr = av1_tx_size_sqr[tx]
        self.sym(
          cdf.itx2 + (sqr * 13 + self.mode.ymode) * 6,
          5,
          av1_itx2_index(tx_type),
        )
      }
      self.set_tx_types(x4, y4, tx, tx_type)
    }
    let scan = av1_scan_for(tx)
    // eob_pt
    let multisize = (if log2w < 5 { log2w } else { 5 }) +
      (if log2h < 5 { log2h } else { 5 }) -
      4
    let eob_pt = if eob <= 2 { eob } else { av1_floor_log2(eob - 1) + 2 }
    // Every transform type we use is in the 2-D class.
    let ectx = 0
    match multisize {
      0 => self.sym(cdf.eob16 + (ptype * 2 + ectx) * 6, 5, eob_pt - 1)
      1 => self.sym(cdf.eob32 + (ptype * 2 + ectx) * 7, 6, eob_pt - 1)
      2 => self.sym(cdf.eob64 + (ptype * 2 + ectx) * 8, 7, eob_pt - 1)
      3 => self.sym(cdf.eob128 + (ptype * 2 + ectx) * 9, 8, eob_pt - 1)
      4 => self.sym(cdf.eob256 + (ptype * 2 + ectx) * 10, 9, eob_pt - 1)
      5 => self.sym(cdf.eob512 + ptype * 11, 10, eob_pt - 1)
      _ => self.sym(cdf.eob1024 + ptype * 12, 11, eob_pt - 1)
    }
    if eob_pt >= 3 {
      let extra = eob - ((1 << (eob_pt - 2)) + 1)
      let shift = eob_pt - 3
      self.sym(
        cdf.eob_extra + ((tx_sz_ctx * 2 + ptype) * 9 + eob_pt - 3) * 3,
        2,
        (extra >> shift) & 1,
      )
      for i = 1; i < eob_pt - 2; i = i + 1 {
        let sh = eob_pt - 2 - 1 - i
        self.literal((extra >> sh) & 1, 1)
      }
    }
    // Base levels and ranges, in reverse scan order. `quant` holds the
    // levels decoded so far (capped at 15) for the contexts.
    let adj = av1_adjusted_tx_size[tx]
    let bwl = av1_tx_width_log2[adj]
    let width = 1 << bwl
    let height = 1 << av1_tx_height_log2[adj]
    let quant = self.quant_ctx
    for i in 0..<(width * height) {
      quant[i] = 0
    }
    for c = eob - 1; c >= 0; c = c - 1 {
      let pos = scan[c]
      let level = self.levels[pos].abs()
      if c == eob - 1 {
        let ctx = if c == 0 {
          0
        } else if c <= (height << bwl) / 8 {
          1
        } else if c <= (height << bwl) / 4 {
          2
        } else {
          3
        }
        let b = if level > 3 { 3 } else { level }
        self.sym(
          cdf.base_eob + ((tx_sz_ctx * 2 + ptype) * 4 + ctx) * 4,
          3,
          b - 1,
        )
      } else {
        let ctx = av1_coeff_base_ctx(quant, tx, bwl, width, height, pos)
        let b = if level > 3 { 3 } else { level }
        self.sym(cdf.base + ((tx_sz_ctx * 2 + ptype) * 42 + ctx) * 5, 4, b)
      }
      if level > 2 {
        let ctx = av1_coeff_br_ctx(quant, bwl, width, height, pos)
        let bsz = if tx_sz_ctx < 3 { tx_sz_ctx } else { 3 }
        let off = cdf.br + ((bsz * 2 + ptype) * 21 + ctx) * 5
        let mut rem = level - 3
        for _ in 0..<4 {
          let k = if rem > 3 { 3 } else { rem }
          self.sym(off, 4, k)
          rem -= k
          if k < 3 {
            break
          }
        }
      }
      quant[pos] = if level > 15 { 15 } else { level }
    }
    // Signs and Golomb remainders.
    for c in 0..<eob {
      let pos = scan[c]
      let v = self.levels[pos]
      let level = v.abs()
      if level != 0 {
        let sign = if v < 0 { 1 } else { 0 }
        if c == 0 {
          self.sym(
            cdf.dc_sign +
            (ptype * 3 + self.dc_sign_ctx(plane, x4, y4, w4, h4)) * 3,
            2,
            sign,
          )
        } else {
          self.literal(sign, 1)
        }
        if level > 14 {
          let x = level - 14
          let len = av1_floor_log2(x) + 1
          self.literal(0, len - 1)
          self.literal(x, len)
        }
        if pos == 0 {
          dc_category = if sign == 1 { 1 } else { 2 }
        }
        cul_level += level
      }
    }
    if cul_level > 63 {
      cul_level = 63
    }
  }
  for i in 0..<w4 {
    self.above_level[plane][x4 + i] = cul_level
    self.above_dc[plane][x4 + i] = dc_category
  }
  for i in 0..<h4 {
    self.left_level[plane][y4 + i] = cul_level
    self.left_dc[plane][y4 + i] = dc_category
  }
}

///|
fn Av1Enc::dc_sign_ctx(
  self : Av1Enc,
  plane : Int32,
  x4 : Int32,
  y4 : Int32,
  w4 : Int32,
  h4 : Int32,
) -> Int32 {
  let sub = if plane > 0 { self.ss } else { 0 }
  let max_x4 = self.mi_cols >> sub
  let max_y4 = self.mi_rows >> sub
  let mut s = 0
  for k in 0..<w4 {
    if x4 + k < max_x4 {
      let v = self.above_dc[plane][x4 + k]
      if v == 1 {
        s -= 1
      } else if v == 2 {
        s += 1
      }
    }
  }
  for k in 0..<h4 {
    if y4 + k < max_y4 {
      let v = self.left_dc[plane][y4 + k]
      if v == 1 {
        s -= 1
      } else if v == 2 {
        s += 1
      }
    }
  }
  if s < 0 {
    1
  } else if s > 0 {
    2
  } else {
    0
  }
}

///|
fn av1_floor_log2(x : Int32) -> Int32 {
  let mut n = 0
  while x >> (n + 1) != 0 {
    n += 1
  }
  n
}

///|
/// get_coeff_base_ctx (2-D transform class, not the eob position).
fn av1_coeff_base_ctx(
  quant : FixedArray[Int32],
  tx : Int32,
  bwl : Int32,
  width : Int32,
  height : Int32,
  pos : Int32,
) -> Int32 {
  let row = pos >> bwl
  let col = pos - (row << bwl)
  let mut mag = 0
  for idx in 0..<5 {
    let rr = row + av1_sig_ref_diff_offset[idx * 2]
    let cc = col + av1_sig_ref_diff_offset[idx * 2 + 1]
    if rr >= 0 && cc >= 0 && rr < height && cc < width {
      let q = quant[(rr << bwl) + cc]
      mag += if q > 3 { 3 } else { q }
    }
  }
  let ctx = {
    let v = (mag + 1) >> 1
    if v > 4 {
      4
    } else {
      v
    }
  }
  if row == 0 && col == 0 {
    return 0
  }
  let r4 = if row < 4 { row } else { 4 }
  let c4 = if col < 4 { col } else { 4 }
  ctx + av1_coeff_base_ctx_offset[tx * 25 + r4 * 5 + c4]
}

///|
/// coeff_br context (2-D transform class).
fn av1_coeff_br_ctx(
  quant : FixedArray[Int32],
  bwl : Int32,
  width : Int32,
  height : Int32,
  pos : Int32,
) -> Int32 {
  let row = pos >> bwl
  let col = pos - (row << bwl)
  let mut mag = 0
  for idx in 0..<3 {
    let rr = row + av1_mag_ref_offset[idx * 2]
    let cc = col + av1_mag_ref_offset[idx * 2 + 1]
    if rr >= 0 && cc >= 0 && rr < height && cc < width {
      let q = quant[rr * width + cc]
      mag += if q > 15 { 15 } else { q }
    }
  }
  let m = {
    let v = (mag + 1) >> 1
    if v > 6 {
      6
    } else {
      v
    }
  }
  if pos == 0 {
    m
  } else if row < 2 && col < 2 {
    m + 7
  } else {
    m + 14
  }
}
