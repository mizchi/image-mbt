// JPEG islow FDCT — wasm SIMD version (i32x4).
//
// Pass 1 runs the row butterfly on 4 rows at once (lanes gathered with
// replace_lane) and scatters the results to `ws` in natural order; pass 2
// runs the column butterfly on 4 columns at once with contiguous loads and
// stores back into `data`. Bit-identical to jpeg_fdct_islow. The WAT is
// generated (all loops unrolled).

///|
fn jpeg_fdct(data : FixedArray[Int32]) -> Unit {
  jpeg_fdct_islow_v128(data, jpeg_fdct_ws)
}

///|
/// Scratch workspace for the SIMD FDCT (single-threaded).
let jpeg_fdct_ws : FixedArray[Int32] = FixedArray::make(64, 0)

///|
/// Params: 0 = data (64 Ints, in place), 1 = ws (64 Ints).
#borrow(data, ws)
fn jpeg_fdct_islow_v128(
  data : FixedArray[Int32],
  ws : FixedArray[Int32],
) -> Unit =
  #|(func (param i32) (param i32) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128)
  #|(local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local
  #|v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128)
  #|(local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local
  #|v128) (local v128) (local v128) local.get 0 i32.const 0 i32.add i32.load i32x4.splat local.get 0 i32.const 32
  #|i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 64 i32.add i32.load i32x4.replace_lane 2 local.get
  #|0 i32.const 96 i32.add i32.load i32x4.replace_lane 3 local.set 2 local.get 0 i32.const 4 i32.add i32.load
  #|i32x4.splat local.get 0 i32.const 36 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 68 i32.add
  #|i32.load i32x4.replace_lane 2 local.get 0 i32.const 100 i32.add i32.load i32x4.replace_lane 3 local.set 3
  #|local.get 0 i32.const 8 i32.add i32.load i32x4.splat local.get 0 i32.const 40 i32.add i32.load
  #|i32x4.replace_lane 1 local.get 0 i32.const 72 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 104
  #|i32.add i32.load i32x4.replace_lane 3 local.set 4 local.get 0 i32.const 12 i32.add i32.load i32x4.splat
  #|local.get 0 i32.const 44 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 76 i32.add i32.load
  #|i32x4.replace_lane 2 local.get 0 i32.const 108 i32.add i32.load i32x4.replace_lane 3 local.set 5 local.get 0
  #|i32.const 16 i32.add i32.load i32x4.splat local.get 0 i32.const 48 i32.add i32.load i32x4.replace_lane 1
  #|local.get 0 i32.const 80 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 112 i32.add i32.load
  #|i32x4.replace_lane 3 local.set 6 local.get 0 i32.const 20 i32.add i32.load i32x4.splat local.get 0 i32.const
  #|52 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 84 i32.add i32.load i32x4.replace_lane 2
  #|local.get 0 i32.const 116 i32.add i32.load i32x4.replace_lane 3 local.set 7 local.get 0 i32.const 24 i32.add
  #|i32.load i32x4.splat local.get 0 i32.const 56 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 88
  #|i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 120 i32.add i32.load i32x4.replace_lane 3
  #|local.set 8 local.get 0 i32.const 28 i32.add i32.load i32x4.splat local.get 0 i32.const 60 i32.add i32.load
  #|i32x4.replace_lane 1 local.get 0 i32.const 92 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 124
  #|i32.add i32.load i32x4.replace_lane 3 local.set 9 local.get 2 local.get 9 i32x4.add local.set 10 local.get 2
  #|local.get 9 i32x4.sub local.set 11 local.get 3 local.get 8 i32x4.add local.set 12 local.get 3 local.get 8
  #|i32x4.sub local.set 13 local.get 4 local.get 7 i32x4.add local.set 14 local.get 4 local.get 7 i32x4.sub
  #|local.set 15 local.get 5 local.get 6 i32x4.add local.set 16 local.get 5 local.get 6 i32x4.sub local.set 17
  #|local.get 10 local.get 16 i32x4.add local.set 18 local.get 10 local.get 16 i32x4.sub local.set 19 local.get 12
  #|local.get 14 i32x4.add local.set 20 local.get 12 local.get 14 i32x4.sub local.set 21 local.get 21 local.get 19
  #|i32x4.add i32.const 4433 i32x4.splat i32x4.mul local.set 22 local.get 17 local.get 13 i32x4.add local.get 15
  #|local.get 11 i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 23 local.get 17 local.get 11
  #|i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 24 local.get 15 local.get 13 i32x4.add i32.const
  #|-20995 i32x4.splat i32x4.mul local.set 25 local.get 17 local.get 13 i32x4.add i32.const -16069 i32x4.splat
  #|i32x4.mul local.get 23 i32x4.add local.set 26 local.get 15 local.get 11 i32x4.add i32.const -3196 i32x4.splat
  #|i32x4.mul local.get 23 i32x4.add local.set 27 local.get 18 local.get 20 i32x4.add i32.const 2 i32x4.shl
  #|local.set 28 local.get 1 i32.const 0 i32.add local.get 28 i32x4.extract_lane 0 i32.store local.get 1 i32.const
  #|32 i32.add local.get 28 i32x4.extract_lane 1 i32.store local.get 1 i32.const 64 i32.add local.get 28
  #|i32x4.extract_lane 2 i32.store local.get 1 i32.const 96 i32.add local.get 28 i32x4.extract_lane 3 i32.store
  #|local.get 11 i32.const 12299 i32x4.splat i32x4.mul local.get 24 i32x4.add local.get 27 i32x4.add i32.const
  #|1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 29 local.get 1 i32.const 4 i32.add local.get 29
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 36 i32.add local.get 29 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 68 i32.add local.get 29 i32x4.extract_lane 2 i32.store local.get 1 i32.const 100 i32.add
  #|local.get 29 i32x4.extract_lane 3 i32.store local.get 22 local.get 19 i32.const 6270 i32x4.splat i32x4.mul
  #|i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 30 local.get 1 i32.const 8
  #|i32.add local.get 30 i32x4.extract_lane 0 i32.store local.get 1 i32.const 40 i32.add local.get 30
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 72 i32.add local.get 30 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 104 i32.add local.get 30 i32x4.extract_lane 3 i32.store local.get 13 i32.const 25172
  #|i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 26 i32x4.add i32.const 1024 i32x4.splat i32x4.add
  #|i32.const 11 i32x4.shr_s local.set 31 local.get 1 i32.const 12 i32.add local.get 31 i32x4.extract_lane 0
  #|i32.store local.get 1 i32.const 44 i32.add local.get 31 i32x4.extract_lane 1 i32.store local.get 1 i32.const
  #|76 i32.add local.get 31 i32x4.extract_lane 2 i32.store local.get 1 i32.const 108 i32.add local.get 31
  #|i32x4.extract_lane 3 i32.store local.get 18 local.get 20 i32x4.sub i32.const 2 i32x4.shl local.set 32
  #|local.get 1 i32.const 16 i32.add local.get 32 i32x4.extract_lane 0 i32.store local.get 1 i32.const 48 i32.add
  #|local.get 32 i32x4.extract_lane 1 i32.store local.get 1 i32.const 80 i32.add local.get 32 i32x4.extract_lane 2
  #|i32.store local.get 1 i32.const 112 i32.add local.get 32 i32x4.extract_lane 3 i32.store local.get 15 i32.const
  #|16819 i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 27 i32x4.add i32.const 1024 i32x4.splat i32x4.add
  #|i32.const 11 i32x4.shr_s local.set 33 local.get 1 i32.const 20 i32.add local.get 33 i32x4.extract_lane 0
  #|i32.store local.get 1 i32.const 52 i32.add local.get 33 i32x4.extract_lane 1 i32.store local.get 1 i32.const
  #|84 i32.add local.get 33 i32x4.extract_lane 2 i32.store local.get 1 i32.const 116 i32.add local.get 33
  #|i32x4.extract_lane 3 i32.store local.get 22 local.get 21 i32.const -15137 i32x4.splat i32x4.mul i32x4.add
  #|i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 34 local.get 1 i32.const 24 i32.add
  #|local.get 34 i32x4.extract_lane 0 i32.store local.get 1 i32.const 56 i32.add local.get 34 i32x4.extract_lane 1
  #|i32.store local.get 1 i32.const 88 i32.add local.get 34 i32x4.extract_lane 2 i32.store local.get 1 i32.const
  #|120 i32.add local.get 34 i32x4.extract_lane 3 i32.store local.get 17 i32.const 2446 i32x4.splat i32x4.mul
  #|local.get 24 i32x4.add local.get 26 i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s
  #|local.set 35 local.get 1 i32.const 28 i32.add local.get 35 i32x4.extract_lane 0 i32.store local.get 1
  #|i32.const 60 i32.add local.get 35 i32x4.extract_lane 1 i32.store local.get 1 i32.const 92 i32.add local.get 35
  #|i32x4.extract_lane 2 i32.store local.get 1 i32.const 124 i32.add local.get 35 i32x4.extract_lane 3 i32.store
  #|local.get 0 i32.const 128 i32.add i32.load i32x4.splat local.get 0 i32.const 160 i32.add i32.load
  #|i32x4.replace_lane 1 local.get 0 i32.const 192 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 224
  #|i32.add i32.load i32x4.replace_lane 3 local.set 2 local.get 0 i32.const 132 i32.add i32.load i32x4.splat
  #|local.get 0 i32.const 164 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 196 i32.add i32.load
  #|i32x4.replace_lane 2 local.get 0 i32.const 228 i32.add i32.load i32x4.replace_lane 3 local.set 3 local.get 0
  #|i32.const 136 i32.add i32.load i32x4.splat local.get 0 i32.const 168 i32.add i32.load i32x4.replace_lane 1
  #|local.get 0 i32.const 200 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 232 i32.add i32.load
  #|i32x4.replace_lane 3 local.set 4 local.get 0 i32.const 140 i32.add i32.load i32x4.splat local.get 0 i32.const
  #|172 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 204 i32.add i32.load i32x4.replace_lane 2
  #|local.get 0 i32.const 236 i32.add i32.load i32x4.replace_lane 3 local.set 5 local.get 0 i32.const 144 i32.add
  #|i32.load i32x4.splat local.get 0 i32.const 176 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 208
  #|i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 240 i32.add i32.load i32x4.replace_lane 3
  #|local.set 6 local.get 0 i32.const 148 i32.add i32.load i32x4.splat local.get 0 i32.const 180 i32.add i32.load
  #|i32x4.replace_lane 1 local.get 0 i32.const 212 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 244
  #|i32.add i32.load i32x4.replace_lane 3 local.set 7 local.get 0 i32.const 152 i32.add i32.load i32x4.splat
  #|local.get 0 i32.const 184 i32.add i32.load i32x4.replace_lane 1 local.get 0 i32.const 216 i32.add i32.load
  #|i32x4.replace_lane 2 local.get 0 i32.const 248 i32.add i32.load i32x4.replace_lane 3 local.set 8 local.get 0
  #|i32.const 156 i32.add i32.load i32x4.splat local.get 0 i32.const 188 i32.add i32.load i32x4.replace_lane 1
  #|local.get 0 i32.const 220 i32.add i32.load i32x4.replace_lane 2 local.get 0 i32.const 252 i32.add i32.load
  #|i32x4.replace_lane 3 local.set 9 local.get 2 local.get 9 i32x4.add local.set 10 local.get 2 local.get 9
  #|i32x4.sub local.set 11 local.get 3 local.get 8 i32x4.add local.set 12 local.get 3 local.get 8 i32x4.sub
  #|local.set 13 local.get 4 local.get 7 i32x4.add local.set 14 local.get 4 local.get 7 i32x4.sub local.set 15
  #|local.get 5 local.get 6 i32x4.add local.set 16 local.get 5 local.get 6 i32x4.sub local.set 17 local.get 10
  #|local.get 16 i32x4.add local.set 18 local.get 10 local.get 16 i32x4.sub local.set 19 local.get 12 local.get 14
  #|i32x4.add local.set 20 local.get 12 local.get 14 i32x4.sub local.set 21 local.get 21 local.get 19 i32x4.add
  #|i32.const 4433 i32x4.splat i32x4.mul local.set 22 local.get 17 local.get 13 i32x4.add local.get 15 local.get
  #|11 i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 23 local.get 17 local.get 11 i32x4.add
  #|i32.const -7373 i32x4.splat i32x4.mul local.set 24 local.get 15 local.get 13 i32x4.add i32.const -20995
  #|i32x4.splat i32x4.mul local.set 25 local.get 17 local.get 13 i32x4.add i32.const -16069 i32x4.splat i32x4.mul
  #|local.get 23 i32x4.add local.set 26 local.get 15 local.get 11 i32x4.add i32.const -3196 i32x4.splat i32x4.mul
  #|local.get 23 i32x4.add local.set 27 local.get 18 local.get 20 i32x4.add i32.const 2 i32x4.shl local.set 28
  #|local.get 1 i32.const 128 i32.add local.get 28 i32x4.extract_lane 0 i32.store local.get 1 i32.const 160
  #|i32.add local.get 28 i32x4.extract_lane 1 i32.store local.get 1 i32.const 192 i32.add local.get 28
  #|i32x4.extract_lane 2 i32.store local.get 1 i32.const 224 i32.add local.get 28 i32x4.extract_lane 3 i32.store
  #|local.get 11 i32.const 12299 i32x4.splat i32x4.mul local.get 24 i32x4.add local.get 27 i32x4.add i32.const
  #|1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 29 local.get 1 i32.const 132 i32.add local.get
  #|29 i32x4.extract_lane 0 i32.store local.get 1 i32.const 164 i32.add local.get 29 i32x4.extract_lane 1
  #|i32.store local.get 1 i32.const 196 i32.add local.get 29 i32x4.extract_lane 2 i32.store local.get 1 i32.const
  #|228 i32.add local.get 29 i32x4.extract_lane 3 i32.store local.get 22 local.get 19 i32.const 6270 i32x4.splat
  #|i32x4.mul i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 30 local.get 1
  #|i32.const 136 i32.add local.get 30 i32x4.extract_lane 0 i32.store local.get 1 i32.const 168 i32.add local.get
  #|30 i32x4.extract_lane 1 i32.store local.get 1 i32.const 200 i32.add local.get 30 i32x4.extract_lane 2
  #|i32.store local.get 1 i32.const 232 i32.add local.get 30 i32x4.extract_lane 3 i32.store local.get 13 i32.const
  #|25172 i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 26 i32x4.add i32.const 1024 i32x4.splat i32x4.add
  #|i32.const 11 i32x4.shr_s local.set 31 local.get 1 i32.const 140 i32.add local.get 31 i32x4.extract_lane 0
  #|i32.store local.get 1 i32.const 172 i32.add local.get 31 i32x4.extract_lane 1 i32.store local.get 1 i32.const
  #|204 i32.add local.get 31 i32x4.extract_lane 2 i32.store local.get 1 i32.const 236 i32.add local.get 31
  #|i32x4.extract_lane 3 i32.store local.get 18 local.get 20 i32x4.sub i32.const 2 i32x4.shl local.set 32
  #|local.get 1 i32.const 144 i32.add local.get 32 i32x4.extract_lane 0 i32.store local.get 1 i32.const 176
  #|i32.add local.get 32 i32x4.extract_lane 1 i32.store local.get 1 i32.const 208 i32.add local.get 32
  #|i32x4.extract_lane 2 i32.store local.get 1 i32.const 240 i32.add local.get 32 i32x4.extract_lane 3 i32.store
  #|local.get 15 i32.const 16819 i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 27 i32x4.add i32.const
  #|1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 33 local.get 1 i32.const 148 i32.add local.get
  #|33 i32x4.extract_lane 0 i32.store local.get 1 i32.const 180 i32.add local.get 33 i32x4.extract_lane 1
  #|i32.store local.get 1 i32.const 212 i32.add local.get 33 i32x4.extract_lane 2 i32.store local.get 1 i32.const
  #|244 i32.add local.get 33 i32x4.extract_lane 3 i32.store local.get 22 local.get 21 i32.const -15137 i32x4.splat
  #|i32x4.mul i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 34 local.get 1
  #|i32.const 152 i32.add local.get 34 i32x4.extract_lane 0 i32.store local.get 1 i32.const 184 i32.add local.get
  #|34 i32x4.extract_lane 1 i32.store local.get 1 i32.const 216 i32.add local.get 34 i32x4.extract_lane 2
  #|i32.store local.get 1 i32.const 248 i32.add local.get 34 i32x4.extract_lane 3 i32.store local.get 17 i32.const
  #|2446 i32x4.splat i32x4.mul local.get 24 i32x4.add local.get 26 i32x4.add i32.const 1024 i32x4.splat i32x4.add
  #|i32.const 11 i32x4.shr_s local.set 35 local.get 1 i32.const 156 i32.add local.get 35 i32x4.extract_lane 0
  #|i32.store local.get 1 i32.const 188 i32.add local.get 35 i32x4.extract_lane 1 i32.store local.get 1 i32.const
  #|220 i32.add local.get 35 i32x4.extract_lane 2 i32.store local.get 1 i32.const 252 i32.add local.get 35
  #|i32x4.extract_lane 3 i32.store local.get 1 i32.const 0 i32.add v128.load local.set 2 local.get 1 i32.const 32
  #|i32.add v128.load local.set 3 local.get 1 i32.const 64 i32.add v128.load local.set 4 local.get 1 i32.const 96
  #|i32.add v128.load local.set 5 local.get 1 i32.const 128 i32.add v128.load local.set 6 local.get 1 i32.const
  #|160 i32.add v128.load local.set 7 local.get 1 i32.const 192 i32.add v128.load local.set 8 local.get 1
  #|i32.const 224 i32.add v128.load local.set 9 local.get 2 local.get 9 i32x4.add local.set 10 local.get 2
  #|local.get 9 i32x4.sub local.set 11 local.get 3 local.get 8 i32x4.add local.set 12 local.get 3 local.get 8
  #|i32x4.sub local.set 13 local.get 4 local.get 7 i32x4.add local.set 14 local.get 4 local.get 7 i32x4.sub
  #|local.set 15 local.get 5 local.get 6 i32x4.add local.set 16 local.get 5 local.get 6 i32x4.sub local.set 17
  #|local.get 10 local.get 16 i32x4.add local.set 18 local.get 10 local.get 16 i32x4.sub local.set 19 local.get 12
  #|local.get 14 i32x4.add local.set 20 local.get 12 local.get 14 i32x4.sub local.set 21 local.get 21 local.get 19
  #|i32x4.add i32.const 4433 i32x4.splat i32x4.mul local.set 22 local.get 17 local.get 13 i32x4.add local.get 15
  #|local.get 11 i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 23 local.get 17 local.get 11
  #|i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 24 local.get 15 local.get 13 i32x4.add i32.const
  #|-20995 i32x4.splat i32x4.mul local.set 25 local.get 17 local.get 13 i32x4.add i32.const -16069 i32x4.splat
  #|i32x4.mul local.get 23 i32x4.add local.set 26 local.get 15 local.get 11 i32x4.add i32.const -3196 i32x4.splat
  #|i32x4.mul local.get 23 i32x4.add local.set 27 local.get 0 i32.const 0 i32.add local.get 18 local.get 20
  #|i32x4.add i32.const 2 i32x4.splat i32x4.add i32.const 2 i32x4.shr_s v128.store local.get 0 i32.const 32
  #|i32.add local.get 11 i32.const 12299 i32x4.splat i32x4.mul local.get 24 i32x4.add local.get 27 i32x4.add
  #|i32.const 16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s v128.store local.get 0 i32.const 64 i32.add
  #|local.get 22 local.get 19 i32.const 6270 i32x4.splat i32x4.mul i32x4.add i32.const 16384 i32x4.splat i32x4.add
  #|i32.const 15 i32x4.shr_s v128.store local.get 0 i32.const 96 i32.add local.get 13 i32.const 25172 i32x4.splat
  #|i32x4.mul local.get 25 i32x4.add local.get 26 i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15
  #|i32x4.shr_s v128.store local.get 0 i32.const 128 i32.add local.get 18 local.get 20 i32x4.sub i32.const 2
  #|i32x4.splat i32x4.add i32.const 2 i32x4.shr_s v128.store local.get 0 i32.const 160 i32.add local.get 15
  #|i32.const 16819 i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 27 i32x4.add i32.const 16384
  #|i32x4.splat i32x4.add i32.const 15 i32x4.shr_s v128.store local.get 0 i32.const 192 i32.add local.get 22
  #|local.get 21 i32.const -15137 i32x4.splat i32x4.mul i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const
  #|15 i32x4.shr_s v128.store local.get 0 i32.const 224 i32.add local.get 17 i32.const 2446 i32x4.splat i32x4.mul
  #|local.get 24 i32x4.add local.get 26 i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s
  #|v128.store local.get 1 i32.const 16 i32.add v128.load local.set 2 local.get 1 i32.const 48 i32.add v128.load
  #|local.set 3 local.get 1 i32.const 80 i32.add v128.load local.set 4 local.get 1 i32.const 112 i32.add v128.load
  #|local.set 5 local.get 1 i32.const 144 i32.add v128.load local.set 6 local.get 1 i32.const 176 i32.add
  #|v128.load local.set 7 local.get 1 i32.const 208 i32.add v128.load local.set 8 local.get 1 i32.const 240
  #|i32.add v128.load local.set 9 local.get 2 local.get 9 i32x4.add local.set 10 local.get 2 local.get 9 i32x4.sub
  #|local.set 11 local.get 3 local.get 8 i32x4.add local.set 12 local.get 3 local.get 8 i32x4.sub local.set 13
  #|local.get 4 local.get 7 i32x4.add local.set 14 local.get 4 local.get 7 i32x4.sub local.set 15 local.get 5
  #|local.get 6 i32x4.add local.set 16 local.get 5 local.get 6 i32x4.sub local.set 17 local.get 10 local.get 16
  #|i32x4.add local.set 18 local.get 10 local.get 16 i32x4.sub local.set 19 local.get 12 local.get 14 i32x4.add
  #|local.set 20 local.get 12 local.get 14 i32x4.sub local.set 21 local.get 21 local.get 19 i32x4.add i32.const
  #|4433 i32x4.splat i32x4.mul local.set 22 local.get 17 local.get 13 i32x4.add local.get 15 local.get 11
  #|i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 23 local.get 17 local.get 11 i32x4.add
  #|i32.const -7373 i32x4.splat i32x4.mul local.set 24 local.get 15 local.get 13 i32x4.add i32.const -20995
  #|i32x4.splat i32x4.mul local.set 25 local.get 17 local.get 13 i32x4.add i32.const -16069 i32x4.splat i32x4.mul
  #|local.get 23 i32x4.add local.set 26 local.get 15 local.get 11 i32x4.add i32.const -3196 i32x4.splat i32x4.mul
  #|local.get 23 i32x4.add local.set 27 local.get 0 i32.const 16 i32.add local.get 18 local.get 20 i32x4.add
  #|i32.const 2 i32x4.splat i32x4.add i32.const 2 i32x4.shr_s v128.store local.get 0 i32.const 48 i32.add
  #|local.get 11 i32.const 12299 i32x4.splat i32x4.mul local.get 24 i32x4.add local.get 27 i32x4.add i32.const
  #|16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s v128.store local.get 0 i32.const 80 i32.add local.get 22
  #|local.get 19 i32.const 6270 i32x4.splat i32x4.mul i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15
  #|i32x4.shr_s v128.store local.get 0 i32.const 112 i32.add local.get 13 i32.const 25172 i32x4.splat i32x4.mul
  #|local.get 25 i32x4.add local.get 26 i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s
  #|v128.store local.get 0 i32.const 144 i32.add local.get 18 local.get 20 i32x4.sub i32.const 2 i32x4.splat
  #|i32x4.add i32.const 2 i32x4.shr_s v128.store local.get 0 i32.const 176 i32.add local.get 15 i32.const 16819
  #|i32x4.splat i32x4.mul local.get 25 i32x4.add local.get 27 i32x4.add i32.const 16384 i32x4.splat i32x4.add
  #|i32.const 15 i32x4.shr_s v128.store local.get 0 i32.const 208 i32.add local.get 22 local.get 21 i32.const
  #|-15137 i32x4.splat i32x4.mul i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s
  #|v128.store local.get 0 i32.const 240 i32.add local.get 17 i32.const 2446 i32x4.splat i32x4.mul local.get 24
  #|i32x4.add local.get 26 i32x4.add i32.const 16384 i32x4.splat i32x4.add i32.const 15 i32x4.shr_s v128.store)
