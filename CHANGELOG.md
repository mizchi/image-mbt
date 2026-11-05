# Changelog

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
