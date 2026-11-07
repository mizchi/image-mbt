// The adaptive CDF context of one AV1 tile: copies of the default tables
// (coefficient tables for the frame's quantizer context) in one array.

///|
priv struct Av1Cdfs {
  data : FixedArray[Int32]
  kf_y : Int32
  uv_no_cfl : Int32
  uv_cfl : Int32
  angle : Int32
  part8 : Int32
  part16 : Int32
  part32 : Int32
  part64 : Int32
  part128 : Int32
  skip : Int32
  itx2 : Int32
  txb_skip : Int32
  eob16 : Int32
  eob32 : Int32
  eob64 : Int32
  eob128 : Int32
  eob256 : Int32
  eob512 : Int32
  eob1024 : Int32
  eob_extra : Int32
  dc_sign : Int32
  base_eob : Int32
  base : Int32
  br : Int32
}

///|
fn Av1Cdfs::new(qidx : Int32) -> Av1Cdfs {
  let q = if qidx <= 20 {
    0
  } else if qidx <= 60 {
    1
  } else if qidx <= 120 {
    2
  } else {
    3
  }
  let parts : Array[(FixedArray[Int32], Int32, Int32)] = []
  let mut total = 0
  // Adds the slice [start, start + len) of `t`; returns its offset.
  let add = fn(t : FixedArray[Int32], start : Int32, len : Int32) -> Int32 {
    let off = total
    parts.push((t, start, len))
    total += len
    off
  }
  let whole = fn(t : FixedArray[Int32]) { add(t, 0, t.length()) }
  // Coefficient tables: slice for the q context.
  let qslice = fn(t : FixedArray[Int32]) {
    let len = t.length() / 4
    add(t, q * len, len)
  }
  let kf_y = whole(av1_cdf_kf_y_mode)
  let uv_no_cfl = whole(av1_cdf_uv_mode_cfl_not_allowed)
  let uv_cfl = whole(av1_cdf_uv_mode_cfl_allowed)
  let angle = whole(av1_cdf_angle_delta)
  let part8 = whole(av1_cdf_partition_w8)
  let part16 = whole(av1_cdf_partition_w16)
  let part32 = whole(av1_cdf_partition_w32)
  let part64 = whole(av1_cdf_partition_w64)
  let part128 = whole(av1_cdf_partition_w128)
  let skip = whole(av1_cdf_skip)
  let itx2 = whole(av1_cdf_intra_tx_type_set2)
  let txb_skip = qslice(av1_cdf_txb_skip)
  let eob16 = qslice(av1_cdf_eob_pt_16)
  let eob32 = qslice(av1_cdf_eob_pt_32)
  let eob64 = qslice(av1_cdf_eob_pt_64)
  let eob128 = qslice(av1_cdf_eob_pt_128)
  let eob256 = qslice(av1_cdf_eob_pt_256)
  let eob512 = qslice(av1_cdf_eob_pt_512)
  let eob1024 = qslice(av1_cdf_eob_pt_1024)
  let eob_extra = qslice(av1_cdf_eob_extra)
  let dc_sign = qslice(av1_cdf_dc_sign)
  let base_eob = qslice(av1_cdf_coeff_base_eob)
  let base = qslice(av1_cdf_coeff_base)
  let br = qslice(av1_cdf_coeff_br)
  let data = FixedArray::make(total, 0)
  let mut o = 0
  for p in parts {
    let (t, start, len) = p
    for i in 0..<len {
      data[o + i] = t[start + i]
    }
    o += len
  }
  {
    data,
    kf_y,
    uv_no_cfl,
    uv_cfl,
    angle,
    part8,
    part16,
    part32,
    part64,
    part128,
    skip,
    itx2,
    txb_skip,
    eob16,
    eob32,
    eob64,
    eob128,
    eob256,
    eob512,
    eob1024,
    eob_extra,
    dc_sign,
    base_eob,
    base,
    br,
  }
}
