// AV1 intra prediction (spec 7.11.2) for 8-bit samples, with the intra
// edge filter disabled (enable_intra_edge_filter = 0 in our sequence
// header) and without filter intra / CfL / palette.

///|
fn av1_sm_weights(log2 : Int) -> FixedArray[Int] {
  match log2 {
    2 => av1_sm_weights_4
    3 => av1_sm_weights_8
    4 => av1_sm_weights_16
    5 => av1_sm_weights_32
    _ => av1_sm_weights_64
  }
}

///|
/// Scratch edge buffers: `above[i + 1]` is AboveRow[ i ] (i >= -1) and
/// `left[i + 1]` is LeftCol[ i ].
priv struct Av1Edges {
  above : FixedArray[Int]
  left : FixedArray[Int]
}

///|
fn Av1Edges::new() -> Av1Edges {
  { above: FixedArray::make(160, 0), left: FixedArray::make(160, 0) }
}

///|
/// Predict the w x h block at (x, y) of `buf` in place from its
/// reconstructed neighbours. `max_x` / `max_y` are the last valid sample
/// coordinates of the (mode-info aligned) plane.
fn av1_predict_intra(
  buf : FixedArray[Int],
  stride : Int,
  x : Int,
  y : Int,
  have_left : Bool,
  have_above : Bool,
  have_above_right : Bool,
  have_below_left : Bool,
  mode : Int,
  angle_delta : Int,
  log2w : Int,
  log2h : Int,
  max_x : Int,
  max_y : Int,
  e : Av1Edges,
) -> Unit {
  let w = 1 << log2w
  let h = 1 << log2h
  // Entries up to w + h + 16 (the spec's clamped reads define them).
  let n = w + h + 16
  let above = e.above
  let left = e.left
  if !have_above && have_left {
    let v = buf[y * stride + x - 1]
    for i in 0..<n {
      above[i + 1] = v
    }
  } else if !have_above && !have_left {
    for i in 0..<n {
      above[i + 1] = 127
    }
  } else {
    let lim = {
      let l = x + (if have_above_right { 2 * w } else { w }) - 1
      if l < max_x {
        l
      } else {
        max_x
      }
    }
    let row = (y - 1) * stride
    for i in 0..<n {
      let xx = if x + i < lim { x + i } else { lim }
      above[i + 1] = buf[row + xx]
    }
  }
  if !have_left && have_above {
    let v = buf[(y - 1) * stride + x]
    for i in 0..<n {
      left[i + 1] = v
    }
  } else if !have_left && !have_above {
    for i in 0..<n {
      left[i + 1] = 129
    }
  } else {
    let lim = {
      let l = y + (if have_below_left { 2 * h } else { h }) - 1
      if l < max_y {
        l
      } else {
        max_y
      }
    }
    for i in 0..<n {
      let yy = if y + i < lim { y + i } else { lim }
      left[i + 1] = buf[yy * stride + x - 1]
    }
  }
  let corner = if have_above && have_left {
    buf[(y - 1) * stride + x - 1]
  } else if have_above {
    buf[(y - 1) * stride + x]
  } else if have_left {
    buf[y * stride + x - 1]
  } else {
    128
  }
  above[0] = corner
  left[0] = corner
  let base_off = y * stride + x
  if mode >= 1 && mode <= 8 {
    // Directional.
    let p_angle = av1_mode_to_angle[mode] + angle_delta * 3
    if p_angle == 90 {
      for i in 0..<h {
        for j in 0..<w {
          buf[base_off + i * stride + j] = above[j + 1]
        }
      }
    } else if p_angle == 180 {
      for i in 0..<h {
        for j in 0..<w {
          buf[base_off + i * stride + j] = left[i + 1]
        }
      }
    } else if p_angle < 90 {
      let dx = av1_dr_intra_derivative[p_angle]
      let max_base_x = w + h - 1
      for i in 0..<h {
        let idx = (i + 1) * dx
        let shift = (idx >> 1) & 0x1f
        for j in 0..<w {
          let base = (idx >> 6) + j
          buf[base_off + i * stride + j] = if base < max_base_x {
            av1_round2(
              above[base + 1] * (32 - shift) + above[base + 2] * shift,
              5,
            )
          } else {
            above[max_base_x + 1]
          }
        }
      }
    } else if p_angle < 180 {
      let dx = av1_dr_intra_derivative[180 - p_angle]
      let dy = av1_dr_intra_derivative[p_angle - 90]
      for i in 0..<h {
        for j in 0..<w {
          let idx = (j << 6) - (i + 1) * dx
          let base = idx >> 6
          buf[base_off + i * stride + j] = if base >= -1 {
            let shift = (idx >> 1) & 0x1f
            av1_round2(
              above[base + 1] * (32 - shift) + above[base + 2] * shift,
              5,
            )
          } else {
            let idx2 = (i << 6) - (j + 1) * dy
            let base2 = idx2 >> 6
            let shift2 = (idx2 >> 1) & 0x1f
            av1_round2(
              left[base2 + 1] * (32 - shift2) + left[base2 + 2] * shift2,
              5,
            )
          }
        }
      }
    } else {
      let dy = av1_dr_intra_derivative[270 - p_angle]
      for j in 0..<w {
        let idx = (j + 1) * dy
        let shift = (idx >> 1) & 0x1f
        for i in 0..<h {
          let base = (idx >> 6) + i
          buf[base_off + i * stride + j] = av1_round2(
            left[base + 1] * (32 - shift) + left[base + 2] * shift,
            5,
          )
        }
      }
    }
  } else if mode == 9 {
    // SMOOTH
    let wx = av1_sm_weights(log2w)
    let wy = av1_sm_weights(log2h)
    let bl = left[h]
    let tr = above[w]
    for i in 0..<h {
      for j in 0..<w {
        let p = wy[i] * above[j + 1] +
          (256 - wy[i]) * bl +
          wx[j] * left[i + 1] +
          (256 - wx[j]) * tr
        buf[base_off + i * stride + j] = av1_round2(p, 9)
      }
    }
  } else if mode == 10 {
    // SMOOTH_V
    let wy = av1_sm_weights(log2h)
    let bl = left[h]
    for i in 0..<h {
      for j in 0..<w {
        let p = wy[i] * above[j + 1] + (256 - wy[i]) * bl
        buf[base_off + i * stride + j] = av1_round2(p, 8)
      }
    }
  } else if mode == 11 {
    // SMOOTH_H
    let wx = av1_sm_weights(log2w)
    let tr = above[w]
    for i in 0..<h {
      for j in 0..<w {
        let p = wx[j] * left[i + 1] + (256 - wx[j]) * tr
        buf[base_off + i * stride + j] = av1_round2(p, 8)
      }
    }
  } else if mode == 0 {
    // DC
    let v = if have_left && have_above {
      let mut sum = 0
      for k in 0..<h {
        sum += left[k + 1]
      }
      for k in 0..<w {
        sum += above[k + 1]
      }
      sum += (w + h) >> 1
      sum / (w + h)
    } else if have_left {
      let mut sum = 0
      for k in 0..<h {
        sum += left[k + 1]
      }
      av1_clip_pixel((sum + (h >> 1)) >> log2h)
    } else if have_above {
      let mut sum = 0
      for k in 0..<w {
        sum += above[k + 1]
      }
      av1_clip_pixel((sum + (w >> 1)) >> log2w)
    } else {
      128
    }
    for i in 0..<h {
      for j in 0..<w {
        buf[base_off + i * stride + j] = v
      }
    }
  } else {
    // PAETH
    let tl = above[0]
    for i in 0..<h {
      for j in 0..<w {
        let a = above[j + 1]
        let l = left[i + 1]
        let base = a + l - tl
        let p_left = (base - l).abs()
        let p_top = (base - a).abs()
        let p_tl = (base - tl).abs()
        buf[base_off + i * stride + j] = if p_left <= p_top && p_left <= p_tl {
          l
        } else if p_top <= p_tl {
          a
        } else {
          tl
        }
      }
    }
  }
}

///|
fn av1_clip_pixel(v : Int) -> Int {
  if v < 0 {
    0
  } else if v > 255 {
    255
  } else {
    v
  }
}
