// AV1 frame driver: superblock / partition recursion, block snapshots
// for dry runs, the sequence and frame headers and the OBUs of a still
// picture.

///|
/// Saved encoder state of a block region (for dry runs).
priv struct Av1Snap {
  rec : Array[FixedArray[Int32]]
  rect : FixedArray[Int32] // per plane: x0, y0, x1, y1
  above_level : Array[FixedArray[Int32]]
  above_dc : Array[FixedArray[Int32]]
  left_level : Array[FixedArray[Int32]]
  left_dc : Array[FixedArray[Int32]]
  ctx_rect : FixedArray[Int32] // per plane: ax0, ax1, ly0, ly1
  decoded : FixedArray[Bool]
  dec_rect : FixedArray[Int32] // per plane: x0, y0, w, h (superblock 4x4 units)
  mi : Array[FixedArray[Int32]] // size, ymode, uvmode, skip, tx_types
  mi_rect : FixedArray[Int32] // r0, c0, r1, c1
}

///|
fn Av1Enc::snapshot(self : Av1Enc, r : Int32, c : Int32, bs : Int32) -> Av1Snap {
  let bw4 = av1_bw4(bs)
  let bh4 = av1_bh4(bs)
  let rect = FixedArray::make(12, 0)
  let ctx_rect = FixedArray::make(12, 0)
  let dec_rect = FixedArray::make(12, 0)
  let dec : Array[Bool] = []
  let rec : Array[FixedArray[Int32]] = []
  let al : Array[FixedArray[Int32]] = []
  let ad : Array[FixedArray[Int32]] = []
  let ll : Array[FixedArray[Int32]] = []
  let ld : Array[FixedArray[Int32]] = []
  for p in 0..<self.num_planes {
    let sub = if p > 0 { self.ss } else { 0 }
    // Mode info units covered by this plane's samples (chroma 4x4 blocks
    // cover a 2x2 mode info area).
    let c0 = c >> sub << sub
    let r0 = r >> sub << sub
    let c1 = (c + bw4 + sub) >> sub << sub
    let r1 = (r + bh4 + sub) >> sub << sub
    // BlockDecoded flags the block can set.
    let dx0 = (c0 & 15) >> sub
    let dy0 = (r0 & 15) >> sub
    let dw = (c1 - c0) >> sub
    let dh = (r1 - r0) >> sub
    dec_rect[p * 4] = dx0
    dec_rect[p * 4 + 1] = dy0
    dec_rect[p * 4 + 2] = dw
    dec_rect[p * 4 + 3] = dh
    for y in 0..<dh {
      for x in 0..<dw {
        dec.push(self.decoded[Av1Enc::dec_idx(p, dy0 + y, dx0 + x)])
      }
    }
    let x0 = (c0 * 4) >> sub
    let y0 = (r0 * 4) >> sub
    let x1 = (c1 * 4) >> sub
    let y1 = (r1 * 4) >> sub
    rect[p * 4] = x0
    rect[p * 4 + 1] = y0
    rect[p * 4 + 2] = x1
    rect[p * 4 + 3] = y1
    let st = self.stride[p]
    let buf = FixedArray::make((x1 - x0) * (y1 - y0), 0)
    let src = self.rec[p]
    for y in y0..<y1 {
      for x in x0..<x1 {
        buf[(y - y0) * (x1 - x0) + x - x0] = src[y * st + x]
      }
    }
    rec.push(buf)
    let ax0 = c0 >> sub
    let ax1 = c1 >> sub
    let ly0 = r0 >> sub
    let ly1 = r1 >> sub
    ctx_rect[p * 4] = ax0
    ctx_rect[p * 4 + 1] = ax1
    ctx_rect[p * 4 + 2] = ly0
    ctx_rect[p * 4 + 3] = ly1
    al.push(
      FixedArray::makei(ax1 - ax0, fn(i) { self.above_level[p][ax0 + i] }),
    )
    ad.push(FixedArray::makei(ax1 - ax0, fn(i) { self.above_dc[p][ax0 + i] }))
    ll.push(FixedArray::makei(ly1 - ly0, fn(i) { self.left_level[p][ly0 + i] }))
    ld.push(FixedArray::makei(ly1 - ly0, fn(i) { self.left_dc[p][ly0 + i] }))
  }
  let r0 = r & -2
  let c0 = c & -2
  let r1 = {
    let v = (r + bh4 + 1) & -2
    if v < self.mi_rows {
      v
    } else {
      self.mi_rows
    }
  }
  let c1 = {
    let v = (c + bw4 + 1) & -2
    if v < self.mi_cols {
      v
    } else {
      self.mi_cols
    }
  }
  let mi : Array[FixedArray[Int32]] = []
  for
    a in [
      self.mi_size,
      self.mi_ymode,
      self.mi_uvmode,
      self.mi_skip,
      self.tx_types,
    ] {
    let b = FixedArray::make(
      (if r1 > r0 { r1 - r0 } else { 0 }) * (if c1 > c0 { c1 - c0 } else { 0 }),
      0,
    )
    for y in r0..<r1 {
      for x in c0..<c1 {
        b[(y - r0) * (c1 - c0) + x - c0] = a[y * self.mi_cols + x]
      }
    }
    mi.push(b)
  }
  {
    rec,
    rect,
    above_level: al,
    above_dc: ad,
    left_level: ll,
    left_dc: ld,
    ctx_rect,
    decoded: FixedArray::makei(dec.length(), fn(i) { dec[i] }),
    dec_rect,
    mi,
    mi_rect: [r0, c0, r1, c1],
  }
}

///|
fn Av1Enc::restore(self : Av1Enc, s : Av1Snap) -> Unit {
  for p in 0..<self.num_planes {
    let x0 = s.rect[p * 4]
    let y0 = s.rect[p * 4 + 1]
    let x1 = s.rect[p * 4 + 2]
    let y1 = s.rect[p * 4 + 3]
    let st = self.stride[p]
    let dst = self.rec[p]
    let buf = s.rec[p]
    for y in y0..<y1 {
      for x in x0..<x1 {
        dst[y * st + x] = buf[(y - y0) * (x1 - x0) + x - x0]
      }
    }
    let ax0 = s.ctx_rect[p * 4]
    let ax1 = s.ctx_rect[p * 4 + 1]
    let ly0 = s.ctx_rect[p * 4 + 2]
    let ly1 = s.ctx_rect[p * 4 + 3]
    for i in ax0..<ax1 {
      self.above_level[p][i] = s.above_level[p][i - ax0]
      self.above_dc[p][i] = s.above_dc[p][i - ax0]
    }
    for i in ly0..<ly1 {
      self.left_level[p][i] = s.left_level[p][i - ly0]
      self.left_dc[p][i] = s.left_dc[p][i - ly0]
    }
  }
  let mut k = 0
  for p in 0..<self.num_planes {
    let dx0 = s.dec_rect[p * 4]
    let dy0 = s.dec_rect[p * 4 + 1]
    for y in 0..<s.dec_rect[p * 4 + 3] {
      for x in 0..<s.dec_rect[p * 4 + 2] {
        self.decoded[Av1Enc::dec_idx(p, dy0 + y, dx0 + x)] = s.decoded[k]
        k += 1
      }
    }
  }
  let r0 = s.mi_rect[0]
  let c0 = s.mi_rect[1]
  let r1 = s.mi_rect[2]
  let c1 = s.mi_rect[3]
  let arrays = [
    self.mi_size,
    self.mi_ymode,
    self.mi_uvmode,
    self.mi_skip,
    self.tx_types,
  ]
  for k, a in arrays {
    let b = s.mi[k]
    for y in r0..<r1 {
      for x in c0..<c1 {
        a[y * self.mi_cols + x] = b[(y - r0) * (c1 - c0) + x - c0]
      }
    }
  }
}

///|
/// Encode the frame as one tile; returns the tile data.
fn Av1Enc::encode_tile(self : Av1Enc) -> Array[Byte] {
  let mut r = 0
  while r < self.mi_rows {
    for p in 0..<3 {
      self.left_level[p].fill(0)
      self.left_dc[p].fill(0)
    }
    let mut c = 0
    while c < self.mi_cols {
      self.clear_decoded(r, c)
      // Decide the superblock with dry runs, then write it.
      let snap = self.snapshot(r, c, av1_block_64x64)
      self.dry = true
      let (_, tree) = self.search(r, c, av1_block_64x64)
      self.restore(snap)
      self.dry = false
      self.write_tree(r, c, av1_block_64x64, tree)
      c += 16
    }
    r += 16
  }
  self.sw.finish()
}

///|
fn av1_bits_for(v : Int32) -> Int32 {
  let mut n = 1
  while v >> n != 0 {
    n += 1
  }
  n
}

///|
fn av1_tile_log2(blk : Int32, target : Int32) -> Int32 {
  let mut k = 0
  while blk << k < target {
    k += 1
  }
  k
}

///|
/// seq_level_idx for a picture size (spec Annex A limits).
fn av1_level_for(w : Int32, h : Int32) -> Int32 {
  let area = w * h
  let limits = [
    (0, 147456, 2048, 1152),
    (1, 278784, 2816, 1584),
    (4, 665856, 4352, 2448),
    (5, 1065024, 5504, 3096),
    (8, 2359296, 6144, 3456),
    (12, 8912896, 8192, 4352),
    (16, 35651584, 16384, 8704),
  ]
  for l in limits {
    let (idx, pic, mw, mh) = l
    if area <= pic && w <= mw && h <= mh {
      return idx
    }
  }
  31
}

///|
/// OBU with obu_has_size_field set.
fn av1_obu(out : Array[Byte], obu_type : Int32, payload : Array[Byte]) -> Unit {
  out.push(((obu_type << 3) | 2).to_byte())
  av1_leb128(out, payload.length())
  for b in payload {
    out.push(b)
  }
}

///|
/// Sequence header OBU payload (reduced still picture header).
fn av1_sequence_header(w : Int32, h : Int32, mono : Bool) -> Array[Byte] {
  let bw = Av1BitWriter::new()
  bw.put(0, 3) // seq_profile
  bw.put(1, 1) // still_picture
  bw.put(1, 1) // reduced_still_picture_header
  bw.put(av1_level_for(w, h), 5)
  let wb = av1_bits_for(w - 1)
  let hb = av1_bits_for(h - 1)
  bw.put(wb - 1, 4)
  bw.put(hb - 1, 4)
  bw.put(w - 1, wb)
  bw.put(h - 1, hb)
  bw.put(0, 1) // use_128x128_superblock
  bw.put(0, 1) // enable_filter_intra
  bw.put(0, 1) // enable_intra_edge_filter
  bw.put(0, 1) // enable_superres
  bw.put(0, 1) // enable_cdef
  bw.put(0, 1) // enable_restoration
  // color_config
  bw.put(0, 1) // high_bitdepth
  bw.put(if mono { 1 } else { 0 }, 1) // mono_chrome
  if mono {
    bw.put(0, 1) // color_description_present_flag
    bw.put(1, 1) // color_range
  } else {
    bw.put(1, 1) // color_description_present_flag
    bw.put(1, 8) // BT.709 primaries
    bw.put(13, 8) // sRGB transfer
    bw.put(6, 8) // BT.601 matrix
    bw.put(1, 1) // color_range (full)
    bw.put(0, 2) // chroma_sample_position
    bw.put(0, 1) // separate_uv_delta_q
  }
  bw.put(0, 1) // film_grain_params_present
  bw.trailing()
  bw.bytes()
}

///|
/// Frame OBU payload: uncompressed header + one tile.
fn av1_frame_payload(enc : Av1Enc, lf : (Int32, Int32, Int32)) -> Array[Byte] {
  let bw = Av1BitWriter::new()
  bw.put(0, 1) // disable_cdf_update
  bw.put(0, 1) // allow_screen_content_tools
  bw.put(0, 1) // render_and_frame_size_different
  // tile_info: uniform spacing, as few tiles as allowed (one).
  let sb_cols = (enc.mi_cols + 15) >> 4
  let sb_rows = (enc.mi_rows + 15) >> 4
  let max_log2_cols = av1_tile_log2(1, if sb_cols < 64 { sb_cols } else { 64 })
  let max_log2_rows = av1_tile_log2(1, if sb_rows < 64 { sb_rows } else { 64 })
  bw.put(1, 1) // uniform_tile_spacing_flag
  if max_log2_cols > 0 {
    bw.put(0, 1) // increment_tile_cols_log2
  }
  if max_log2_rows > 0 {
    bw.put(0, 1) // increment_tile_rows_log2
  }
  // quantization_params
  bw.put(enc.qidx, 8)
  bw.put(0, 1) // DeltaQYDc
  if enc.num_planes > 1 {
    bw.put(0, 1) // DeltaQUDc
    bw.put(0, 1) // DeltaQUAc
  }
  bw.put(0, 1) // using_qmatrix
  bw.put(0, 1) // segmentation_enabled
  if enc.qidx > 0 {
    bw.put(0, 1) // delta_q_present
  }
  // loop_filter_params
  let (ly, lu, lv) = lf
  bw.put(ly, 6)
  bw.put(ly, 6)
  if enc.num_planes > 1 && ly > 0 {
    bw.put(lu, 6)
    bw.put(lv, 6)
  }
  bw.put(0, 3) // loop_filter_sharpness
  bw.put(0, 1) // loop_filter_delta_enabled
  bw.put(0, 1) // tx_mode_select (TX_MODE_LARGEST)
  bw.put(1, 1) // reduced_tx_set
  bw.byte_align()
  let out = bw.bytes()
  for b in enc.encode_tile() {
    out.push(b)
  }
  out
}

///|
/// Encode planes (Y or Y/U/V 4:2:0) as an AV1 still picture: returns the
/// sequence header OBU, the frame OBU and the encoder (whose
/// reconstruction equals the decoder's output without `loop_filter`).
fn av1_encode_still(
  planes : Array[FixedArray[Int32]],
  w : Int32,
  h : Int32,
  qidx : Int32,
  loop_filter~ : Bool = true,
) -> (Array[Byte], Array[Byte], Av1Enc) {
  let enc = Av1Enc::new(planes, w, h, qidx)
  let seq : Array[Byte] = []
  av1_obu(seq, 1, av1_sequence_header(w, h, planes.length() == 1))
  let frame : Array[Byte] = []
  let lf = if loop_filter { av1_filter_level(qidx) } else { 0 }
  av1_obu(frame, 6, av1_frame_payload(enc, (lf, lf, lf)))
  (seq, frame, enc)
}

///|
/// Deblocking filter level from the quantizer (libaom's
/// choose-from-quantizer formula for key frames).
fn av1_filter_level(qidx : Int32) -> Int32 {
  let q = av1_ac_qlookup[qidx]
  let f = (q * 20723 + 1015158 + (1 << 17)) >> 18
  if f < 0 {
    0
  } else if f > 63 {
    63
  } else {
    f
  }
}
