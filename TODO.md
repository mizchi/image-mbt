# TODO (image-mbt)

## Done

- [x] PNG decode (all color types and bit depths, tRNS, Adam7) / encode (RGBA8)
- [x] APNG decode (frame compositing)
- [x] JPEG decode (baseline / extended / progressive, restart markers, CMYK / YCCK / RGB; libjpeg-exact)
- [x] JPEG encode (4:4:4 / 4:2:2 / 4:2:0, optimized Huffman tables; libjpeg-exact entropy data)
- [x] GIF decode (animated, frame compositing) / encode (single frame)
- [x] BMP decode (palette, RLE, 16/24/32-bit, bit fields) / encode
- [x] ICO / CUR decode, ICO encode
- [x] TIFF decode (all pages, strips / tiles, LZW / Deflate / PackBits / JPEG) / encode
- [x] WebP lossless encode (predictor / cross-color / palette / subtract-green,
  cost-based LZ77, color cache, meta prefix codes)
- [x] AVIF encode (pure AV1 intra encoder, alpha, all targets)
- [x] Resize (Nearest / fixed-point Bilinear / Bicubic)
- [x] Format auto-detect (`decode_image`), stream decode (PNG / BMP)
- [x] Mutation fuzz test; malformed input raises `DecodeError`
- [x] wasm SIMD fast paths (PNG, JPEG, resize, VP8 loop filter)
- [x] EXIF orientation (read + apply)
- [x] Animated GIF / APNG encode; real GIF LZW
- [x] PNG encode color modes and compression levels
- [x] zlib output-size limits on decode
- [x] WebP decode (lossy, lossless, alpha, animation; libwebp-exact)
- [x] Animated WebP encode (lossless frames)
- [x] WebP lossy encode (VP8)

## Next

- [ ] WebP lossy encode: perceptual tuning. Segments with SNS-style
  quantizer offsets (either direction) and chroma quantizer deltas were
  tried and lowered PSNR and luma SSIM against a uniform quantizer, so they
  are not used; a perceptual metric beyond PSNR / SSIM would be needed
- [ ] WebP lossless encoder: per-image predictor / meta tile sizes, and a
  faster parse (encoding is ~3x slower than 0.18 for ~8% smaller files)
- [ ] AVIF encoder: multiple tiles (> 4096 wide), palette / intra block copy for
  screen content, CfL, CDEF, rectangular partitions and 4x4 blocks, transform
  size selection, the full intra transform set (V_DCT / H_DCT), speed (64x64:
  10 ms native / 34 ms js; 512x512: 0.55 s native / 2.1 s js)
- [ ] Metadata handling policy (gamma / sRGB / ICC)

## Packaging

- [x] Unify `GifAnimation` with `Animation`
- [x] Add JPEG / GIF / ICO / TIFF to `ImageFormat`
- [ ] Split reusable codec core from engine-specific adapters
- [ ] Stabilize public API and add compatibility tests
