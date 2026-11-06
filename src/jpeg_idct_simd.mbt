// JPEG islow IDCT — wasm SIMD version (i32x4).
//
// Pass 1 runs the column butterfly on 4 columns at once and stores the
// workspace transposed; pass 2 then runs the row butterfly on 4 rows at
// once. libjpeg's zero-AC shortcuts are skipped: they give exactly the same
// values as the full butterfly, so the result is bit-identical to
// jpeg_idct_islow. The WAT is generated (all loops unrolled).

///|
fn jpeg_idct(
  coef : FixedArray[Int32],
  ws : FixedArray[Int32],
  out : FixedArray[Int32],
  off : Int32,
  stride : Int32,
) -> Unit {
  jpeg_idct_islow_v128(coef, ws, out, off, stride)
}

///|
/// Params: 0 = coef, 1 = ws (64 Ints, used transposed), 2 = out, 3 = off,
/// 4 = stride. Locals 5..8 = output row addresses; v128 locals = temporaries.
#borrow(coef, ws, out)
fn jpeg_idct_islow_v128(
  coef : FixedArray[Int32],
  ws : FixedArray[Int32],
  out : FixedArray[Int32],
  off : Int32,
  stride : Int32,
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) (local i32) (local
  #|i32) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128)
  #|(local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local
  #|v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128)
  #|(local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128) (local v128)
  #|local.get 0 i32.const 0 i32.add v128.load local.set 9 local.get 0 i32.const 32 i32.add v128.load local.set 10
  #|local.get 0 i32.const 64 i32.add v128.load local.set 11 local.get 0 i32.const 96 i32.add v128.load local.set
  #|12 local.get 0 i32.const 128 i32.add v128.load local.set 13 local.get 0 i32.const 160 i32.add v128.load
  #|local.set 14 local.get 0 i32.const 192 i32.add v128.load local.set 15 local.get 0 i32.const 224 i32.add
  #|v128.load local.set 16 local.get 11 local.get 15 i32x4.add i32.const 4433 i32x4.splat i32x4.mul local.set 17
  #|local.get 17 local.get 15 i32.const -15137 i32x4.splat i32x4.mul i32x4.add local.set 18 local.get 17 local.get
  #|11 i32.const 6270 i32x4.splat i32x4.mul i32x4.add local.set 19 local.get 9 local.get 13 i32x4.add i32.const 13
  #|i32x4.shl local.set 20 local.get 9 local.get 13 i32x4.sub i32.const 13 i32x4.shl local.set 21 local.get 20
  #|local.get 19 i32x4.add local.set 22 local.get 20 local.get 19 i32x4.sub local.set 23 local.get 21 local.get 18
  #|i32x4.add local.set 24 local.get 21 local.get 18 i32x4.sub local.set 25 local.get 16 local.get 12 i32x4.add
  #|local.get 14 local.get 10 i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 26 local.get 16
  #|local.get 10 i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 17 local.get 14 local.get 12 i32x4.add
  #|i32.const -20995 i32x4.splat i32x4.mul local.set 27 local.get 16 local.get 12 i32x4.add i32.const -16069
  #|i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 28 local.get 14 local.get 10 i32x4.add i32.const -3196
  #|i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 29 local.get 16 i32.const 2446 i32x4.splat i32x4.mul
  #|local.get 17 i32x4.add local.get 28 i32x4.add local.set 30 local.get 14 i32.const 16819 i32x4.splat i32x4.mul
  #|local.get 27 i32x4.add local.get 29 i32x4.add local.set 31 local.get 12 i32.const 25172 i32x4.splat i32x4.mul
  #|local.get 27 i32x4.add local.get 28 i32x4.add local.set 32 local.get 10 i32.const 12299 i32x4.splat i32x4.mul
  #|local.get 17 i32x4.add local.get 29 i32x4.add local.set 33 local.get 22 local.get 33 i32x4.add i32.const 1024
  #|i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 34 local.get 1 i32.const 0 i32.add local.get 34
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 32 i32.add local.get 34 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 64 i32.add local.get 34 i32x4.extract_lane 2 i32.store local.get 1 i32.const 96 i32.add
  #|local.get 34 i32x4.extract_lane 3 i32.store local.get 24 local.get 32 i32x4.add i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 35 local.get 1 i32.const 4 i32.add local.get 35
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 36 i32.add local.get 35 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 68 i32.add local.get 35 i32x4.extract_lane 2 i32.store local.get 1 i32.const 100 i32.add
  #|local.get 35 i32x4.extract_lane 3 i32.store local.get 25 local.get 31 i32x4.add i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 36 local.get 1 i32.const 8 i32.add local.get 36
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 40 i32.add local.get 36 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 72 i32.add local.get 36 i32x4.extract_lane 2 i32.store local.get 1 i32.const 104 i32.add
  #|local.get 36 i32x4.extract_lane 3 i32.store local.get 23 local.get 30 i32x4.add i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 37 local.get 1 i32.const 12 i32.add local.get 37
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 44 i32.add local.get 37 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 76 i32.add local.get 37 i32x4.extract_lane 2 i32.store local.get 1 i32.const 108 i32.add
  #|local.get 37 i32x4.extract_lane 3 i32.store local.get 23 local.get 30 i32x4.sub i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 38 local.get 1 i32.const 16 i32.add local.get 38
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 48 i32.add local.get 38 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 80 i32.add local.get 38 i32x4.extract_lane 2 i32.store local.get 1 i32.const 112 i32.add
  #|local.get 38 i32x4.extract_lane 3 i32.store local.get 25 local.get 31 i32x4.sub i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 39 local.get 1 i32.const 20 i32.add local.get 39
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 52 i32.add local.get 39 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 84 i32.add local.get 39 i32x4.extract_lane 2 i32.store local.get 1 i32.const 116 i32.add
  #|local.get 39 i32x4.extract_lane 3 i32.store local.get 24 local.get 32 i32x4.sub i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 40 local.get 1 i32.const 24 i32.add local.get 40
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 56 i32.add local.get 40 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 88 i32.add local.get 40 i32x4.extract_lane 2 i32.store local.get 1 i32.const 120 i32.add
  #|local.get 40 i32x4.extract_lane 3 i32.store local.get 22 local.get 33 i32x4.sub i32.const 1024 i32x4.splat
  #|i32x4.add i32.const 11 i32x4.shr_s local.set 41 local.get 1 i32.const 28 i32.add local.get 41
  #|i32x4.extract_lane 0 i32.store local.get 1 i32.const 60 i32.add local.get 41 i32x4.extract_lane 1 i32.store
  #|local.get 1 i32.const 92 i32.add local.get 41 i32x4.extract_lane 2 i32.store local.get 1 i32.const 124 i32.add
  #|local.get 41 i32x4.extract_lane 3 i32.store local.get 0 i32.const 16 i32.add v128.load local.set 9 local.get 0
  #|i32.const 48 i32.add v128.load local.set 10 local.get 0 i32.const 80 i32.add v128.load local.set 11 local.get
  #|0 i32.const 112 i32.add v128.load local.set 12 local.get 0 i32.const 144 i32.add v128.load local.set 13
  #|local.get 0 i32.const 176 i32.add v128.load local.set 14 local.get 0 i32.const 208 i32.add v128.load local.set
  #|15 local.get 0 i32.const 240 i32.add v128.load local.set 16 local.get 11 local.get 15 i32x4.add i32.const 4433
  #|i32x4.splat i32x4.mul local.set 17 local.get 17 local.get 15 i32.const -15137 i32x4.splat i32x4.mul i32x4.add
  #|local.set 18 local.get 17 local.get 11 i32.const 6270 i32x4.splat i32x4.mul i32x4.add local.set 19 local.get 9
  #|local.get 13 i32x4.add i32.const 13 i32x4.shl local.set 20 local.get 9 local.get 13 i32x4.sub i32.const 13
  #|i32x4.shl local.set 21 local.get 20 local.get 19 i32x4.add local.set 22 local.get 20 local.get 19 i32x4.sub
  #|local.set 23 local.get 21 local.get 18 i32x4.add local.set 24 local.get 21 local.get 18 i32x4.sub local.set 25
  #|local.get 16 local.get 12 i32x4.add local.get 14 local.get 10 i32x4.add i32x4.add i32.const 9633 i32x4.splat
  #|i32x4.mul local.set 26 local.get 16 local.get 10 i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 17
  #|local.get 14 local.get 12 i32x4.add i32.const -20995 i32x4.splat i32x4.mul local.set 27 local.get 16 local.get
  #|12 i32x4.add i32.const -16069 i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 28 local.get 14 local.get
  #|10 i32x4.add i32.const -3196 i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 29 local.get 16 i32.const
  #|2446 i32x4.splat i32x4.mul local.get 17 i32x4.add local.get 28 i32x4.add local.set 30 local.get 14 i32.const
  #|16819 i32x4.splat i32x4.mul local.get 27 i32x4.add local.get 29 i32x4.add local.set 31 local.get 12 i32.const
  #|25172 i32x4.splat i32x4.mul local.get 27 i32x4.add local.get 28 i32x4.add local.set 32 local.get 10 i32.const
  #|12299 i32x4.splat i32x4.mul local.get 17 i32x4.add local.get 29 i32x4.add local.set 33 local.get 22 local.get
  #|33 i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 34 local.get 1 i32.const
  #|128 i32.add local.get 34 i32x4.extract_lane 0 i32.store local.get 1 i32.const 160 i32.add local.get 34
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 192 i32.add local.get 34 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 224 i32.add local.get 34 i32x4.extract_lane 3 i32.store local.get 24 local.get 32
  #|i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 35 local.get 1 i32.const 132
  #|i32.add local.get 35 i32x4.extract_lane 0 i32.store local.get 1 i32.const 164 i32.add local.get 35
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 196 i32.add local.get 35 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 228 i32.add local.get 35 i32x4.extract_lane 3 i32.store local.get 25 local.get 31
  #|i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 36 local.get 1 i32.const 136
  #|i32.add local.get 36 i32x4.extract_lane 0 i32.store local.get 1 i32.const 168 i32.add local.get 36
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 200 i32.add local.get 36 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 232 i32.add local.get 36 i32x4.extract_lane 3 i32.store local.get 23 local.get 30
  #|i32x4.add i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 37 local.get 1 i32.const 140
  #|i32.add local.get 37 i32x4.extract_lane 0 i32.store local.get 1 i32.const 172 i32.add local.get 37
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 204 i32.add local.get 37 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 236 i32.add local.get 37 i32x4.extract_lane 3 i32.store local.get 23 local.get 30
  #|i32x4.sub i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 38 local.get 1 i32.const 144
  #|i32.add local.get 38 i32x4.extract_lane 0 i32.store local.get 1 i32.const 176 i32.add local.get 38
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 208 i32.add local.get 38 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 240 i32.add local.get 38 i32x4.extract_lane 3 i32.store local.get 25 local.get 31
  #|i32x4.sub i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 39 local.get 1 i32.const 148
  #|i32.add local.get 39 i32x4.extract_lane 0 i32.store local.get 1 i32.const 180 i32.add local.get 39
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 212 i32.add local.get 39 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 244 i32.add local.get 39 i32x4.extract_lane 3 i32.store local.get 24 local.get 32
  #|i32x4.sub i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 40 local.get 1 i32.const 152
  #|i32.add local.get 40 i32x4.extract_lane 0 i32.store local.get 1 i32.const 184 i32.add local.get 40
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 216 i32.add local.get 40 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 248 i32.add local.get 40 i32x4.extract_lane 3 i32.store local.get 22 local.get 33
  #|i32x4.sub i32.const 1024 i32x4.splat i32x4.add i32.const 11 i32x4.shr_s local.set 41 local.get 1 i32.const 156
  #|i32.add local.get 41 i32x4.extract_lane 0 i32.store local.get 1 i32.const 188 i32.add local.get 41
  #|i32x4.extract_lane 1 i32.store local.get 1 i32.const 220 i32.add local.get 41 i32x4.extract_lane 2 i32.store
  #|local.get 1 i32.const 252 i32.add local.get 41 i32x4.extract_lane 3 i32.store local.get 2 local.get 3
  #|i32.const 0 local.get 4 i32.mul i32.add i32.const 2 i32.shl i32.add local.set 5 local.get 2 local.get 3
  #|i32.const 1 local.get 4 i32.mul i32.add i32.const 2 i32.shl i32.add local.set 6 local.get 2 local.get 3
  #|i32.const 2 local.get 4 i32.mul i32.add i32.const 2 i32.shl i32.add local.set 7 local.get 2 local.get 3
  #|i32.const 3 local.get 4 i32.mul i32.add i32.const 2 i32.shl i32.add local.set 8 local.get 1 i32.const 0
  #|i32.add v128.load local.set 9 local.get 1 i32.const 32 i32.add v128.load local.set 10 local.get 1 i32.const 64
  #|i32.add v128.load local.set 11 local.get 1 i32.const 96 i32.add v128.load local.set 12 local.get 1 i32.const
  #|128 i32.add v128.load local.set 13 local.get 1 i32.const 160 i32.add v128.load local.set 14 local.get 1
  #|i32.const 192 i32.add v128.load local.set 15 local.get 1 i32.const 224 i32.add v128.load local.set 16
  #|local.get 11 local.get 15 i32x4.add i32.const 4433 i32x4.splat i32x4.mul local.set 17 local.get 17 local.get
  #|15 i32.const -15137 i32x4.splat i32x4.mul i32x4.add local.set 18 local.get 17 local.get 11 i32.const 6270
  #|i32x4.splat i32x4.mul i32x4.add local.set 19 local.get 9 local.get 13 i32x4.add i32.const 13 i32x4.shl
  #|local.set 20 local.get 9 local.get 13 i32x4.sub i32.const 13 i32x4.shl local.set 21 local.get 20 local.get 19
  #|i32x4.add local.set 22 local.get 20 local.get 19 i32x4.sub local.set 23 local.get 21 local.get 18 i32x4.add
  #|local.set 24 local.get 21 local.get 18 i32x4.sub local.set 25 local.get 16 local.get 12 i32x4.add local.get 14
  #|local.get 10 i32x4.add i32x4.add i32.const 9633 i32x4.splat i32x4.mul local.set 26 local.get 16 local.get 10
  #|i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 17 local.get 14 local.get 12 i32x4.add i32.const
  #|-20995 i32x4.splat i32x4.mul local.set 27 local.get 16 local.get 12 i32x4.add i32.const -16069 i32x4.splat
  #|i32x4.mul local.get 26 i32x4.add local.set 28 local.get 14 local.get 10 i32x4.add i32.const -3196 i32x4.splat
  #|i32x4.mul local.get 26 i32x4.add local.set 29 local.get 16 i32.const 2446 i32x4.splat i32x4.mul local.get 17
  #|i32x4.add local.get 28 i32x4.add local.set 30 local.get 14 i32.const 16819 i32x4.splat i32x4.mul local.get 27
  #|i32x4.add local.get 29 i32x4.add local.set 31 local.get 12 i32.const 25172 i32x4.splat i32x4.mul local.get 27
  #|i32x4.add local.get 28 i32x4.add local.set 32 local.get 10 i32.const 12299 i32x4.splat i32x4.mul local.get 17
  #|i32x4.add local.get 29 i32x4.add local.set 33 local.get 22 local.get 33 i32x4.add i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 34 local.get 5 i32.const 0 i32.add local.get 34
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 0 i32.add local.get 34 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 0 i32.add local.get 34 i32x4.extract_lane 2 i32.store local.get 8 i32.const 0 i32.add
  #|local.get 34 i32x4.extract_lane 3 i32.store local.get 24 local.get 32 i32x4.add i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 35 local.get 5 i32.const 4 i32.add local.get 35
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 4 i32.add local.get 35 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 4 i32.add local.get 35 i32x4.extract_lane 2 i32.store local.get 8 i32.const 4 i32.add
  #|local.get 35 i32x4.extract_lane 3 i32.store local.get 25 local.get 31 i32x4.add i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 36 local.get 5 i32.const 8 i32.add local.get 36
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 8 i32.add local.get 36 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 8 i32.add local.get 36 i32x4.extract_lane 2 i32.store local.get 8 i32.const 8 i32.add
  #|local.get 36 i32x4.extract_lane 3 i32.store local.get 23 local.get 30 i32x4.add i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 37 local.get 5 i32.const 12 i32.add local.get 37
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 12 i32.add local.get 37 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 12 i32.add local.get 37 i32x4.extract_lane 2 i32.store local.get 8 i32.const 12 i32.add
  #|local.get 37 i32x4.extract_lane 3 i32.store local.get 23 local.get 30 i32x4.sub i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 38 local.get 5 i32.const 16 i32.add local.get 38
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 16 i32.add local.get 38 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 16 i32.add local.get 38 i32x4.extract_lane 2 i32.store local.get 8 i32.const 16 i32.add
  #|local.get 38 i32x4.extract_lane 3 i32.store local.get 25 local.get 31 i32x4.sub i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 39 local.get 5 i32.const 20 i32.add local.get 39
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 20 i32.add local.get 39 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 20 i32.add local.get 39 i32x4.extract_lane 2 i32.store local.get 8 i32.const 20 i32.add
  #|local.get 39 i32x4.extract_lane 3 i32.store local.get 24 local.get 32 i32x4.sub i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 40 local.get 5 i32.const 24 i32.add local.get 40
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 24 i32.add local.get 40 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 24 i32.add local.get 40 i32x4.extract_lane 2 i32.store local.get 8 i32.const 24 i32.add
  #|local.get 40 i32x4.extract_lane 3 i32.store local.get 22 local.get 33 i32x4.sub i32.const 131072 i32x4.splat
  #|i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add i32.const 0 i32x4.splat i32x4.max_s
  #|i32.const 255 i32x4.splat i32x4.min_s local.set 41 local.get 5 i32.const 28 i32.add local.get 41
  #|i32x4.extract_lane 0 i32.store local.get 6 i32.const 28 i32.add local.get 41 i32x4.extract_lane 1 i32.store
  #|local.get 7 i32.const 28 i32.add local.get 41 i32x4.extract_lane 2 i32.store local.get 8 i32.const 28 i32.add
  #|local.get 41 i32x4.extract_lane 3 i32.store local.get 2 local.get 3 i32.const 4 local.get 4 i32.mul i32.add
  #|i32.const 2 i32.shl i32.add local.set 5 local.get 2 local.get 3 i32.const 5 local.get 4 i32.mul i32.add
  #|i32.const 2 i32.shl i32.add local.set 6 local.get 2 local.get 3 i32.const 6 local.get 4 i32.mul i32.add
  #|i32.const 2 i32.shl i32.add local.set 7 local.get 2 local.get 3 i32.const 7 local.get 4 i32.mul i32.add
  #|i32.const 2 i32.shl i32.add local.set 8 local.get 1 i32.const 16 i32.add v128.load local.set 9 local.get 1
  #|i32.const 48 i32.add v128.load local.set 10 local.get 1 i32.const 80 i32.add v128.load local.set 11 local.get
  #|1 i32.const 112 i32.add v128.load local.set 12 local.get 1 i32.const 144 i32.add v128.load local.set 13
  #|local.get 1 i32.const 176 i32.add v128.load local.set 14 local.get 1 i32.const 208 i32.add v128.load local.set
  #|15 local.get 1 i32.const 240 i32.add v128.load local.set 16 local.get 11 local.get 15 i32x4.add i32.const 4433
  #|i32x4.splat i32x4.mul local.set 17 local.get 17 local.get 15 i32.const -15137 i32x4.splat i32x4.mul i32x4.add
  #|local.set 18 local.get 17 local.get 11 i32.const 6270 i32x4.splat i32x4.mul i32x4.add local.set 19 local.get 9
  #|local.get 13 i32x4.add i32.const 13 i32x4.shl local.set 20 local.get 9 local.get 13 i32x4.sub i32.const 13
  #|i32x4.shl local.set 21 local.get 20 local.get 19 i32x4.add local.set 22 local.get 20 local.get 19 i32x4.sub
  #|local.set 23 local.get 21 local.get 18 i32x4.add local.set 24 local.get 21 local.get 18 i32x4.sub local.set 25
  #|local.get 16 local.get 12 i32x4.add local.get 14 local.get 10 i32x4.add i32x4.add i32.const 9633 i32x4.splat
  #|i32x4.mul local.set 26 local.get 16 local.get 10 i32x4.add i32.const -7373 i32x4.splat i32x4.mul local.set 17
  #|local.get 14 local.get 12 i32x4.add i32.const -20995 i32x4.splat i32x4.mul local.set 27 local.get 16 local.get
  #|12 i32x4.add i32.const -16069 i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 28 local.get 14 local.get
  #|10 i32x4.add i32.const -3196 i32x4.splat i32x4.mul local.get 26 i32x4.add local.set 29 local.get 16 i32.const
  #|2446 i32x4.splat i32x4.mul local.get 17 i32x4.add local.get 28 i32x4.add local.set 30 local.get 14 i32.const
  #|16819 i32x4.splat i32x4.mul local.get 27 i32x4.add local.get 29 i32x4.add local.set 31 local.get 12 i32.const
  #|25172 i32x4.splat i32x4.mul local.get 27 i32x4.add local.get 28 i32x4.add local.set 32 local.get 10 i32.const
  #|12299 i32x4.splat i32x4.mul local.get 17 i32x4.add local.get 29 i32x4.add local.set 33 local.get 22 local.get
  #|33 i32x4.add i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat
  #|i32x4.add i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 34 local.get 5
  #|i32.const 0 i32.add local.get 34 i32x4.extract_lane 0 i32.store local.get 6 i32.const 0 i32.add local.get 34
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 0 i32.add local.get 34 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 0 i32.add local.get 34 i32x4.extract_lane 3 i32.store local.get 24 local.get 32
  #|i32x4.add i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 35 local.get 5 i32.const 4
  #|i32.add local.get 35 i32x4.extract_lane 0 i32.store local.get 6 i32.const 4 i32.add local.get 35
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 4 i32.add local.get 35 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 4 i32.add local.get 35 i32x4.extract_lane 3 i32.store local.get 25 local.get 31
  #|i32x4.add i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 36 local.get 5 i32.const 8
  #|i32.add local.get 36 i32x4.extract_lane 0 i32.store local.get 6 i32.const 8 i32.add local.get 36
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 8 i32.add local.get 36 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 8 i32.add local.get 36 i32x4.extract_lane 3 i32.store local.get 23 local.get 30
  #|i32x4.add i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 37 local.get 5 i32.const
  #|12 i32.add local.get 37 i32x4.extract_lane 0 i32.store local.get 6 i32.const 12 i32.add local.get 37
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 12 i32.add local.get 37 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 12 i32.add local.get 37 i32x4.extract_lane 3 i32.store local.get 23 local.get 30
  #|i32x4.sub i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 38 local.get 5 i32.const
  #|16 i32.add local.get 38 i32x4.extract_lane 0 i32.store local.get 6 i32.const 16 i32.add local.get 38
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 16 i32.add local.get 38 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 16 i32.add local.get 38 i32x4.extract_lane 3 i32.store local.get 25 local.get 31
  #|i32x4.sub i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 39 local.get 5 i32.const
  #|20 i32.add local.get 39 i32x4.extract_lane 0 i32.store local.get 6 i32.const 20 i32.add local.get 39
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 20 i32.add local.get 39 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 20 i32.add local.get 39 i32x4.extract_lane 3 i32.store local.get 24 local.get 32
  #|i32x4.sub i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 40 local.get 5 i32.const
  #|24 i32.add local.get 40 i32x4.extract_lane 0 i32.store local.get 6 i32.const 24 i32.add local.get 40
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 24 i32.add local.get 40 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 24 i32.add local.get 40 i32x4.extract_lane 3 i32.store local.get 22 local.get 33
  #|i32x4.sub i32.const 131072 i32x4.splat i32x4.add i32.const 18 i32x4.shr_s i32.const 128 i32x4.splat i32x4.add
  #|i32.const 0 i32x4.splat i32x4.max_s i32.const 255 i32x4.splat i32x4.min_s local.set 41 local.get 5 i32.const
  #|28 i32.add local.get 41 i32x4.extract_lane 0 i32.store local.get 6 i32.const 28 i32.add local.get 41
  #|i32x4.extract_lane 1 i32.store local.get 7 i32.const 28 i32.add local.get 41 i32x4.extract_lane 2 i32.store
  #|local.get 8 i32.const 28 i32.add local.get 41 i32x4.extract_lane 3 i32.store)
