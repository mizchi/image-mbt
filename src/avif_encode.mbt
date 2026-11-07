// AVIF encoder: the image is converted to Y'CbCr (BT.601, full range,
// 4:2:0), coded as an AV1 still picture by the pure MoonBit encoder in
// av1_*.mbt, and wrapped in a HEIF / AVIF container. Non-opaque alpha is
// stored as a monochrome auxiliary image.

///|
fn avif_box(out : Array[Byte], typ : String, body : Array[Byte]) -> Unit {
  let n = body.length() + 8
  avif_u32(out, n)
  for ch in typ {
    out.push(ch.to_int().to_byte())
  }
  for b in body {
    out.push(b)
  }
}

///|
fn avif_full_box(
  out : Array[Byte],
  typ : String,
  version : Int,
  flags : Int,
  body : Array[Byte],
) -> Unit {
  let b : Array[Byte] = []
  b.push(version.to_byte())
  b.push((flags >> 16).to_byte())
  b.push((flags >> 8).to_byte())
  b.push(flags.to_byte())
  for x in body {
    b.push(x)
  }
  avif_box(out, typ, b)
}

///|
fn avif_u32(out : Array[Byte], v : Int) -> Unit {
  out.push((v >> 24).to_byte())
  out.push((v >> 16).to_byte())
  out.push((v >> 8).to_byte())
  out.push(v.to_byte())
}

///|
fn avif_u16(out : Array[Byte], v : Int) -> Unit {
  out.push((v >> 8).to_byte())
  out.push(v.to_byte())
}

///|
fn avif_str(out : Array[Byte], s : String) -> Unit {
  for ch in s {
    out.push(ch.to_int().to_byte())
  }
}

///|
/// av1C configuration box body for a still picture.
fn avif_av1c(seq_obu : Array[Byte], w : Int, h : Int, mono : Bool) -> Array[Byte] {
  let b : Array[Byte] = [b'\x81']
  b.push(av1_level_for(w, h).to_byte()) // seq_profile 0
  b.push(((if mono { 1 } else { 0 }) << 4 | 1 << 3 | 1 << 2).to_byte())
  b.push(b'\x00')
  for x in seq_obu {
    b.push(x)
  }
  b
}

///|
/// Map a 0..100 quality to an AV1 base_q_idx.
fn avif_quality_to_qidx(quality : Int) -> Int {
  let q = if quality < 0 {
    0
  } else if quality > 100 {
    100
  } else {
    quality
  }
  let v = ((100 - q) * 255 + 50) / 100
  if v < 1 {
    1
  } else {
    v
  }
}

///|
/// RGBA -> Y, Cb, Cr (BT.601, full range); chroma averaged over 2x2.
fn avif_rgb_to_yuv420(img : ImageData) -> Array[FixedArray[Int]] {
  let w = img.width
  let h = img.height
  let cw = (w + 1) >> 1
  let ch = (h + 1) >> 1
  let y = FixedArray::make(w * h, 0)
  let cbf = FixedArray::make(w * h, 0)
  let crf = FixedArray::make(w * h, 0)
  for i in 0..<(w * h) {
    let r = img.data[i * 4].to_int()
    let g = img.data[i * 4 + 1].to_int()
    let b = img.data[i * 4 + 2].to_int()
    // Fixed point (16 bits).
    y[i] = av1_clip_pixel((19595 * r + 38470 * g + 7471 * b + 32768) >> 16)
    cbf[i] = -11059 * r - 21709 * g + 32768 * b
    crf[i] = 32768 * r - 27439 * g - 5329 * b
  }
  let cb = FixedArray::make(cw * ch, 0)
  let cr = FixedArray::make(cw * ch, 0)
  for cy in 0..<ch {
    for cx in 0..<cw {
      let mut sb = 0
      let mut sr = 0
      let mut n = 0
      for dy in 0..<2 {
        for dx in 0..<2 {
          let xx = cx * 2 + dx
          let yy = cy * 2 + dy
          if xx < w && yy < h {
            sb += cbf[yy * w + xx]
            sr += crf[yy * w + xx]
            n += 1
          }
        }
      }
      let d = n * 65536
      cb[cy * cw + cx] = av1_clip_pixel(128 + avif_div_round(sb, d))
      cr[cy * cw + cx] = av1_clip_pixel(128 + avif_div_round(sr, d))
    }
  }
  [y, cb, cr]
}

///|
fn avif_div_round(a : Int, d : Int) -> Int {
  if a >= 0 {
    (a + d / 2) / d
  } else {
    -((-a + d / 2) / d)
  }
}

///|
/// Encode `img` as AVIF (lossy AV1, 4:2:0). `quality` is 0..100 (higher is
/// better); images with non-opaque pixels get an alpha auxiliary image.
pub fn encode_avif(
  img : ImageData,
  quality~ : Int = 75,
) -> Bytes raise EncodeError {
  validate_rgba8_image(img)
  let w = img.width
  let h = img.height
  if w > 4096 || w * h > 4096 * 2304 {
    raise InvalidDimensions(
      "AVIF encoder supports up to 4096 pixels wide and 4096x2304 pixels: " +
      w.to_string() +
      "x" +
      h.to_string(),
    )
  }
  let qidx = avif_quality_to_qidx(quality)
  let (seq, frame, _) = av1_encode_still(avif_rgb_to_yuv420(img), w, h, qidx)
  let alpha = if image_has_non_opaque_alpha(img) {
    let a = FixedArray::makei(w * h, fn(i) { img.data[i * 4 + 3].to_int() })
    // Alpha edges are visible: code it at a finer quantizer.
    let aq = if qidx > 32 { qidx / 2 } else { qidx }
    let (aseq, aframe, _) = av1_encode_still([a], w, h, aq)
    Some((aseq, aframe))
  } else {
    None
  }
  avif_container(w, h, seq, frame, alpha)
}

///|
fn image_has_non_opaque_alpha(img : ImageData) -> Bool {
  for i in 0..<(img.width * img.height) {
    if img.data[i * 4 + 3].to_int() != 255 {
      return true
    }
  }
  false
}

///|
/// The HEIF / AVIF boxes around the coded image (and alpha) items.
fn avif_container(
  w : Int,
  h : Int,
  seq : Array[Byte],
  frame : Array[Byte],
  alpha : (Array[Byte], Array[Byte])?,
) -> Bytes {
  let color_len = seq.length() + frame.length()
  let alpha_len = match alpha {
    Some((s, f)) => s.length() + f.length()
    None => 0
  }
  let n_items = if alpha is Some(_) { 2 } else { 1 }
  // The meta box is built twice: first to learn its size (the iloc offsets
  // point into mdat, which follows it).
  let build = fn(mdat_data : Int) -> Array[Byte] {
    let out : Array[Byte] = []
    let ftyp : Array[Byte] = []
    avif_str(ftyp, "avif")
    avif_u32(ftyp, 0)
    avif_str(ftyp, "avifmif1miaf")
    avif_box(out, "ftyp", ftyp)
    let meta : Array[Byte] = []
    let hdlr : Array[Byte] = []
    avif_u32(hdlr, 0)
    avif_str(hdlr, "pict")
    for _ in 0..<12 {
      hdlr.push(b'\x00')
    }
    hdlr.push(b'\x00') // empty name
    avif_full_box(meta, "hdlr", 0, 0, hdlr)
    let pitm : Array[Byte] = []
    avif_u16(pitm, 1)
    avif_full_box(meta, "pitm", 0, 0, pitm)
    // iloc v0: offset_size 4, length_size 4, base_offset_size 0.
    let iloc : Array[Byte] = [b'\x44', b'\x00']
    avif_u16(iloc, n_items)
    avif_u16(iloc, 1)
    avif_u16(iloc, 0) // data_reference_index
    avif_u16(iloc, 1) // extent_count
    avif_u32(iloc, mdat_data)
    avif_u32(iloc, color_len)
    if alpha is Some(_) {
      avif_u16(iloc, 2)
      avif_u16(iloc, 0)
      avif_u16(iloc, 1)
      avif_u32(iloc, mdat_data + color_len)
      avif_u32(iloc, alpha_len)
    }
    avif_full_box(meta, "iloc", 0, 0, iloc)
    let iinf : Array[Byte] = []
    avif_u16(iinf, n_items)
    for id in 1..=n_items {
      let infe : Array[Byte] = []
      avif_u16(infe, id)
      avif_u16(infe, 0) // item_protection_index
      avif_str(infe, "av01")
      avif_str(infe, if id == 1 { "Color" } else { "Alpha" })
      infe.push(b'\x00')
      avif_full_box(iinf, "infe", 2, 0, infe)
    }
    avif_full_box(meta, "iinf", 0, 0, iinf)
    if alpha is Some(_) {
      let iref : Array[Byte] = []
      let auxl : Array[Byte] = []
      avif_u16(auxl, 2) // from item
      avif_u16(auxl, 1) // reference count
      avif_u16(auxl, 1) // to item
      avif_box(iref, "auxl", auxl)
      avif_full_box(meta, "iref", 0, 0, iref)
    }
    let ipco : Array[Byte] = []
    let ispe : Array[Byte] = []
    avif_u32(ispe, w)
    avif_u32(ispe, h)
    avif_full_box(ipco, "ispe", 0, 0, ispe) // 1
    avif_full_box(ipco, "pixi", 0, 0, [b'\x03', b'\x08', b'\x08', b'\x08']) // 2
    avif_box(ipco, "av1C", avif_av1c(seq, w, h, false)) // 3
    let colr : Array[Byte] = []
    avif_str(colr, "nclx")
    avif_u16(colr, 1) // BT.709 primaries
    avif_u16(colr, 13) // sRGB transfer
    avif_u16(colr, 6) // BT.601 matrix
    colr.push(b'\x80') // full range
    avif_box(ipco, "colr", colr) // 4
    match alpha {
      Some((aseq, _)) => {
        avif_full_box(ipco, "pixi", 0, 0, [b'\x01', b'\x08']) // 5
        avif_box(ipco, "av1C", avif_av1c(aseq, w, h, true)) // 6
        let auxc : Array[Byte] = []
        avif_str(auxc, "urn:mpeg:mpegB:cicp:systems:auxiliary:alpha")
        auxc.push(b'\x00')
        avif_full_box(ipco, "auxC", 0, 0, auxc) // 7
      }
      None => ()
    }
    let iprp : Array[Byte] = []
    avif_box(iprp, "ipco", ipco)
    let ipma : Array[Byte] = []
    avif_u32(ipma, n_items)
    avif_u16(ipma, 1)
    ipma.push(b'\x04')
    ipma.push(b'\x01') // ispe
    ipma.push(b'\x02') // pixi
    ipma.push(b'\x83') // av1C (essential)
    ipma.push(b'\x04') // colr
    if alpha is Some(_) {
      avif_u16(ipma, 2)
      ipma.push(b'\x04')
      ipma.push(b'\x01') // ispe
      ipma.push(b'\x05') // pixi
      ipma.push(b'\x86') // av1C (essential)
      ipma.push(b'\x07') // auxC
    }
    avif_full_box(iprp, "ipma", 0, 0, ipma)
    avif_box(meta, "iprp", iprp)
    avif_full_box(out, "meta", 0, 0, meta)
    out
  }
  let head = build(0)
  let data_off = head.length() + 8
  let out = build(data_off)
  let mdat : Array[Byte] = []
  for b in seq {
    mdat.push(b)
  }
  for b in frame {
    mdat.push(b)
  }
  match alpha {
    Some((s, f)) => {
      for b in s {
        mdat.push(b)
      }
      for b in f {
        mdat.push(b)
      }
    }
    None => ()
  }
  avif_box(out, "mdat", mdat)
  Bytes::from_array(out)
}
