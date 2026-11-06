# TODO (image-mbt)

## Done

- [x] PNG decode (all color types and bit depths, tRNS, Adam7) / encode (RGBA8)
- [x] APNG decode (frame compositing)
- [x] JPEG decode (baseline / extended / progressive, restart markers; libjpeg-exact)
- [x] JPEG encode (4:4:4 / 4:2:2 / 4:2:0; libjpeg-exact entropy data)
- [x] GIF decode (animated, frame compositing) / encode (single frame)
- [x] BMP decode (palette, RLE, 16/24/32-bit, bit fields) / encode
- [x] ICO / CUR decode, ICO encode
- [x] TIFF decode (strips / tiles, LZW / Deflate / PackBits)
- [x] WebP lossless encode
- [x] AVIF encode (js-target MVP, opaque images)
- [x] Resize (Nearest / fixed-point Bilinear / Bicubic)
- [x] Format auto-detect (`decode_image`), stream decode (PNG / BMP)
- [x] Mutation fuzz test; malformed input raises `DecodeError`
- [x] wasm SIMD fast paths
- [x] EXIF orientation (read + apply)
- [x] Animated GIF / APNG encode; real GIF LZW
- [x] PNG encode color modes and compression levels
- [x] zlib output-size limits on decode

## Next

- [ ] WebP decode (lossless VP8L, then lossy VP8)
- [ ] TIFF: more pages, JPEG-in-TIFF; TIFF encode
- [ ] JPEG: CMYK / Adobe files, optimized Huffman tables on encode
- [ ] WebP encoder optimization (transforms / LZ77 / color cache)
- [ ] AVIF full encoder (alpha, non-js targets, no external runtime dependency)
- [ ] Metadata handling policy (gamma / sRGB / ICC)

## Packaging

- [ ] Unify `GifAnimation` with `Animation`
- [ ] Add JPEG / GIF / ICO / TIFF to `ImageFormat` (breaking change)
- [ ] Split reusable codec core from engine-specific adapters
- [ ] Stabilize public API and add compatibility tests
