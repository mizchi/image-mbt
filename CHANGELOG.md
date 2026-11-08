# Changelog

## 0.20.1

- `encode_avif` is ~25-40% faster with the same compression (64x64: 17 ->
  9.9 ms native, 51 -> 39 ms js; 512x512: 1.12 -> 0.71 s native, 3.7 -> 2.8 s
  js): transform types are scored in the transform domain and only the
  chosen one is reconstructed, row transforms are shared between transform
  types, zero coefficient rows skip the inverse row transform, and block
  snapshots cover only the block's decoded-flag region

## 0.20.0

- `encode_avif(img, quality~ : Int = 75)` is a pure MoonBit AV1 encoder
  on every target (no browser canvas or `ffmpeg`), with alpha:
  - AV1 still picture (reduced still-picture header, one key frame,
    8-bit 4:2:0, BT.601 full range), one tile, default CDFs with adaptation
  - partitions from 64x64 to 8x8 and intra modes chosen by rate-distortion
    (SATD pre-selection, then full coding of the best candidates); DCT /
    ADST / identity transform types (reduced set) per transform block
  - deblocking filter level from the quantizer
  - non-opaque alpha as a monochrome auxiliary image (`auxl` / `auxC`)
  - the encoder's reconstruction is checked to equal dav1d's output, and
    files are ~5% larger than libavif's (libaom, speed 6) at the same luma
    PSNR on our test set (screen content more: no palette mode)
  - limits: 4096 pixels wide, 4096x2304 pixels
  - speed: 64x64 in 17 ms native / 51 ms js; 512x512 in 1.2 s / 3.5 s
- `tools/gen_av1_tables.py` extracts the AV1 tables from the spec text

## 0.19.0

- WebP lossless encoder:
  - cost-based LZ77: a shortest-path parse over literals, cache hits and
    copies, with symbol costs from the previous parse (2 passes; the
    cache may also start from a cache-only parse)
  - meta prefix codes: tile histograms clustered greedily by estimated bits
  - cross-color transform (per-tile multipliers chosen by residual bits)
  - transform candidates ranked by a quick estimate before the full parse
  Files are ~8% smaller (vs libwebp's default lossless mode: x1.019 ->
  x0.941 on our test set; vs `-m 6`: x1.077 -> x0.995); encoding is ~2.3-3.5x
  slower (64x64: 5.1 ms native, 20.6 ms js, 16.6 ms wasm)

## 0.18.0

- WebP lossless encoder: LZ77 also tries the 24 nearest 2-D distance
  codes and uses lazy matching; predictor modes are chosen by the bits of
  their residuals under the statistics accumulated so far (with a prior
  at 0); more color-cache sizes are tried. Files are ~5% smaller (vs
  libwebp's default lossless mode: x1.070 -> x1.019 on our test set);
  encoding is ~2x slower (64x64: 2.2 ms native, 5.9 ms js)

## 0.17.1

- `encode_webp_lossy` is ~35% faster with identical output (no full-buffer
  clears per 4x4 trial, a zero-level fast path in the quantizer, table-
  driven probability-update costs). 64x64: 0.86 -> 0.54 ms native,
  2.6 -> 1.9 ms js

## 0.17.0

- `encode_webp_lossy`: rate-distortion optimized mode decisions (each
  candidate is quantized and reconstructed, scored as SSE + lambda * token
  bits); ALPH chunks pick the best spatial filter (none / horizontal /
  vertical / gradient); `quality` now follows libwebp's scale (similar file
  sizes for the same setting). Files are ~9% smaller at equal PSNR than in
  0.16 (now ~3% smaller than libwebp's on the test set); encoding is ~3x
  slower (64x64: 0.86 ms native, 2.6 ms js)

## 0.16.1

- wasm: SIMD VP8 loop filter (16 lanes, identical output); lossy WebP
  decode is ~30% faster on the `wasm` target

## 0.16.0

- `encode_webp_lossy(img, quality~ : Int = 75)`: lossy WebP (VP8 key frame)
  with per-macroblock 16x16 / 4x4 intra mode decisions, adaptive token
  probabilities, skip flags and the normal loop filter; alpha goes into a
  lossless ALPH chunk
- VP8L encoder: predictor candidates without subtract-green (smaller
  single-channel images such as alpha planes)

## 0.15.0

- TIFF: `decode_tiff_pages` (every image in the IFD chain), JPEG-compressed
  TIFF (compression 7 with `JPEGTables`; RGB / YCbCr / gray / CMYK), and
  `encode_tiff` (RGB or RGBA, None / LZW / Deflate / PackBits, horizontal
  predictor for LZW and Deflate)

## 0.14.0

- `encode_webp_animation`: animated WebP from an `Animation` (lossless
  frames cropped to the changed region; delays in ms, loop count = `plays`)
- JPEG decode: CMYK, YCCK and RGB (Adobe transform 0 / component IDs)
  files; color space inferred like libjpeg-turbo, CMYK -> RGB like Pillow
- `encode_jpeg(optimize~)`: per-image optimal Huffman tables (two passes),
  identical to libjpeg's optimize_coding; DHT segments are written in
  libjpeg's order (DC0, AC0, DC1, AC1)
- `encode_webp` rewritten: real length-limited Huffman codes, LZ77 with
  2-D distance codes, color cache, subtract-green + predictor or palette
  transforms; files are 2-15x smaller than before (within 5-30% of
  libwebp's lossless mode)
- WebP lossless decode is ~3x faster on the js target (32-bit bit reader)
- CI: cached static ffmpeg / ffprobe for the js AVIF tests; actions v5

## 0.13.0

- WebP decode: `decode_webp` and `decode_webp_frames` (lossy VP8,
  lossless VP8L, `ALPH` alpha, animation). Output is identical to libwebp
- `ImageFormat` gains `WebP` (breaking for exhaustive matches);
  `decode_image`, `detect_image_format`, `decode_image_stream` and
  `read_exif_orientation` (`EXIF` chunk) accept WebP

## 0.12.0

Breaking changes:

- `decode_gif_frames` returns `Animation` (like `decode_png_frames`);
  `GifAnimation` / `GifFrame` are removed. `loop_count` becomes `plays`:
  no NETSCAPE loop extension = 1, loop 0 = 0 (forever), loop n = n + 1
- `ImageFormat` gains `Jpeg`, `Gif`, `Ico` and `Tiff`

Other changes:

- New `detect_image_format`
- `decode_image_stream` accepts every format (PNG and BMP are streamed,
  others are decoded and then emitted row by row)

## 0.11.0

- EXIF orientation: `read_exif_orientation` (JPEG / PNG / TIFF),
  `apply_orientation` (same mapping as Pillow's `exif_transpose`) and
  `decode_image_upright`
- Animation encoders: `encode_apng` and `encode_gif_animation` (from an
  `Animation`; changed-region cropping, global / local GIF palettes)
- `encode_gif` now uses real LZW compression (it previously emitted a clear
  code before every pixel)
- `encode_png` options: `color~ : PngColorMode` (Rgba default, Rgb, Gray,
  GrayAlpha, Palette at 1-8 bits, Auto) and `compression~ : PngCompression`
  (Stored, Fast, Default, Best)
- Decompression bombs: PNG IDAT and TIFF Deflate inflation are capped at
  the size the header implies
- CI: timeouts for the ffmpeg install step and the job

## 0.10.0

- APNG decode: `decode_png_frames` returns an `Animation` (composited RGBA
  frames with delays, and the play count) using acTL / fcTL / fdAT, frame
  disposal (none / background / previous) and blending (source / over).
  `decode_png` keeps returning the default image
- TIFF decode: `decode_tiff` (first image). Little / big endian, strips and
  tiles, chunky and planar samples, None / LZW / Deflate / PackBits with
  horizontal predictor, WhiteIsZero / BlackIsZero / RGB / palette / CMYK,
  1-16 bits per sample, extra alpha (associated alpha un-premultiplied).
  JPEG / CCITT compression and BigTIFF raise `UnsupportedFeature`
- `decode_image` also detects TIFF
- New generic `Animation` / `AnimationFrame` types

## 0.9.0

- `encode_jpeg` follows libjpeg's compression pipeline: fixed-point
  RGB -> YCbCr, libjpeg's chroma downsampling, the islow integer FDCT with
  libjpeg's rounding quantization, edge "dummy" blocks, and deferred ZRL
  (trailing zero runs are a single EOB). For the same quality and
  subsampling, the entropy-coded data is byte-identical to libjpeg's
  (Pillow with `optimize=False`)
- New `subsampling~ : JpegSubsampling` option (`Yuv444` default, `Yuv422`,
  `Yuv420`)
- JPEG encode is 1.4-2.6x faster (256x256: native 5.9 -> 2.3 ms, js
  11.7 -> 8.1 ms, wasm 8.2 -> 5.6 ms with a new i32x4 SIMD FDCT); the
  Double DCT code is removed

## 0.8.0

- JPEG decode output is now identical to libjpeg / libjpeg-turbo (e.g.
  Pillow): islow integer IDCT, "fancy" triangle-filter chroma upsampling
  for 4:2:0 / 4:2:2 / 4:4:0, and libjpeg's fixed-point YCbCr -> RGB.
  Previously chroma was upsampled nearest-neighbor (differences up to 157
  on 4:2:0 images)
- JPEG decode is 2.4-3.7x faster: 9-bit Huffman lookup table with a
  32-bit bit buffer, the integer IDCT (about 80 multiplies per block
  instead of ~2000 Double operations) and, on wasm, an i32x4 SIMD IDCT
  (256x256: native 6.3 -> 1.7 ms, js 15.9 -> 6.7 ms, wasm 7.2 -> 2.4 ms)

## 0.7.1

- Decoders no longer panic on malformed input; they raise `DecodeError`.
  Found with a new mutation fuzz test (`src/fuzz_wbtest.mbt`) and fixed:
  - PNG: chunk lengths >= 2^31 (negative after conversion)
  - JPEG: marker segments whose counts run past the segment (DQT / DHT /
    SOF / SOS reads are now bounds-checked); DC/AC sizes > 16 rejected
  - BMP: DIB header size / pixel offset >= 2^31, size arithmetic overflow
  - ICO: directory `offset + size` overflow, oversized color counts
- All decoders reject images larger than 2^27 pixels (134M px, e.g. 100 MP
  photos still decode) with `UnsupportedFeature("image too large")`
  instead of overflowing `width * height * 4`
- PNG: the output buffer is allocated only after the IDAT size has been
  validated, so a corrupt header cannot trigger a huge allocation

## 0.7.0

- JPEG decode: progressive (SOF2) images, including spectral selection
  and successive approximation (DC/AC first and refinement scans) and
  restart markers
- JPEG decode: decode every scan of sequential files, so baseline images
  with one scan per component now decode (previously only the first scan
  was read)
- GIF decode: `decode_gif` (first frame) and `decode_gif_frames`
  (`GifAnimation` with composited RGBA frames, per-frame delays and the
  NETSCAPE loop count). Supports GIF87a/89a, global / local color tables,
  interlaced frames, transparency and disposal methods 1-3; the canvas
  starts transparent, as in browsers
- `decode_image` also detects GIF

## 0.6.0

- JPEG decode: restart intervals (DRI/RST), SOF1 extended sequential,
  non-interleaved single-component scans; progressive / lossless /
  arithmetic files report `UnsupportedFeature`
- PNG decode: Adam7 interlaced images
- BMP decode: 1/2/4/8-bit palettes, RLE8/RLE4, 16-bit, BI_BITFIELDS /
  BI_ALPHABITFIELDS, V2-V5 and OS/2 headers; 32-bit BI_RGB with all-zero
  alpha is opaque
- New `decode_ico` / `decode_ico_all` (ICO/CUR, PNG or BMP payloads with
  AND mask) and `decode_image` (PNG / JPEG / BMP / ICO auto-detect)

## 0.5.0

- Support the latest MoonBit toolchain (0.10.19+): `#derive`, explicit
  `pub extend` method promotion, `@image.`-qualified black-box tests
- Bump `mizchi/zlib` to `0.4.10` (older versions pull a `moonbitlang/x`
  that the new `moon` rejects)
- PNG decode: support every color type / bit depth combination (1/2/4-bit
  indexed and grayscale, 16-bit), fix the scanline stride for sub-byte
  depths, and apply `tRNS` for indexed (per-entry alpha), grayscale and
  RGB (color key) images (#1)
- Resize: bilinear / bicubic rewritten as a fixed-point separable
  resampler (results within 1 of the previous implementation)
- wasm SIMD: PNG Sub/Average/Paeth reconstruction and Average/Paeth/score
  filtering, RGB/Gray/GrayAlpha -> RGBA expansion, JPEG FDCT/IDCT
  (bit-identical f64x2) and resize kernels

## 0.4.0

- Preserve `tRNS` alpha for indexed PNG decode
- Bump `mizchi/zlib` to `0.4.4`

## 0.3.0

- Add ICO encoder (single-image, PNG payload)
- Add AVIF encoder js-target MVP
- Document AVIF target/runtime constraints

## 0.2.0

- Add GIF encoder
- Add WebP lossless encoder MVP
- Replace deprecated `derive(Show)` with manual `Show` impls

## 0.1.0

- Bootstrap project boilerplate
