// JPEG DCT — wasm target only.
//
// Both passes of the separable 8x8 forward DCT (encoder) are vectorized
// over two adjacent outputs with f64x2. Every lane performs exactly the
// same sequence of f64 multiplies and adds as fdct_block_ref (wasm SIMD has
// no fused multiply-add), so the results are bit-identical. (Decoding uses
// the integer islow IDCT in jpeg_idct.mbt.)

///|
fn fdct_block(input : FixedArray[Int32], output : FixedArray[Double]) -> Unit {
  let tmp = FixedArray::make(64, 0.0)
  fdct_block_v128(input, output, tmp, idct_cos_table, idct_c)
}

///|
/// Pass 1: tmp[y*8+v]  = sum_x (in[y*8+x] - 128) * cos[x*8+v]
/// Pass 2: out[u*8+v]  = ((0.25 * c[u]) * c[v]) * sum_y tmp[y*8+v] * cos[y*8+u]
/// Vectorized over (v, v+1).
///
/// Params: 0 = input, 1 = output, 2 = tmp, 3 = cos, 4 = c.
/// Locals: 5 = y/u, 6 = v, 7 = x/y, 8 = acc.
#borrow(input, output, tmp, cos, c)
fn fdct_block_v128(
  input : FixedArray[Int32],
  output : FixedArray[Double],
  tmp : FixedArray[Double],
  cos : FixedArray[Double],
  c : FixedArray[Double],
) -> Unit =
  #|(func (param i32) (param i32) (param i32) (param i32) (param i32) (local i32) (local i32) (local i32) (local v128) block loop local.get 5 i32.const 8 i32.ge_s br_if 1 i32.const 0 local.set 6 block loop local.get 6 i32.const 8 i32.ge_s br_if 1 f64.const 0 f64x2.splat local.set 8 i32.const 0 local.set 7 block loop local.get 7 i32.const 8 i32.ge_s br_if 1 local.get 8 local.get 0 local.get 5 i32.const 3 i32.shl local.get 7 i32.add i32.const 2 i32.shl i32.add i32.load i32.const 128 i32.sub f64.convert_i32_s f64x2.splat local.get 3 local.get 7 i32.const 3 i32.shl local.get 6 i32.add i32.const 3 i32.shl i32.add v128.load f64x2.mul f64x2.add local.set 8 local.get 7 i32.const 1 i32.add local.set 7 br 0 end end local.get 2 local.get 5 i32.const 3 i32.shl local.get 6 i32.add i32.const 3 i32.shl i32.add local.get 8 v128.store local.get 6 i32.const 2 i32.add local.set 6 br 0 end end local.get 5 i32.const 1 i32.add local.set 5 br 0 end end i32.const 0 local.set 5 block loop local.get 5 i32.const 8 i32.ge_s br_if 1 i32.const 0 local.set 6 block loop local.get 6 i32.const 8 i32.ge_s br_if 1 f64.const 0 f64x2.splat local.set 8 i32.const 0 local.set 7 block loop local.get 7 i32.const 8 i32.ge_s br_if 1 local.get 8 local.get 2 local.get 7 i32.const 3 i32.shl local.get 6 i32.add i32.const 3 i32.shl i32.add v128.load local.get 3 local.get 7 i32.const 3 i32.shl local.get 5 i32.add i32.const 3 i32.shl i32.add f64.load f64x2.splat f64x2.mul f64x2.add local.set 8 local.get 7 i32.const 1 i32.add local.set 7 br 0 end end local.get 1 local.get 5 i32.const 3 i32.shl local.get 6 i32.add i32.const 3 i32.shl i32.add f64.const 0.25 local.get 4 local.get 5 i32.const 3 i32.shl i32.add f64.load f64.mul f64x2.splat local.get 4 local.get 6 i32.const 3 i32.shl i32.add v128.load f64x2.mul local.get 8 f64x2.mul v128.store local.get 6 i32.const 2 i32.add local.set 6 br 0 end end local.get 5 i32.const 1 i32.add local.set 5 br 0 end end)
