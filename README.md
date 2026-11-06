# mizchi/image

Image codec primitives for MoonBit: decode PNG / APNG / JPEG / GIF / BMP / ICO / TIFF / WebP, encode PNG / APNG / JPEG / GIF / BMP / TIFF / WebP (lossy / lossless, still and animated) / ICO / AVIF, resize, and EXIF orientation. Core codecs have no external dependencies except `mizchi/zlib`; the AVIF js-target MVP uses browser AVIF canvas support or local `ffmpeg`.

All decoded images are normalized to `ImageData` (RGBA8 buffer).

## Install

```bash
moon add mizchi/image
```

## Usage

```moonbit
// Auto-detect PNG / JPEG / GIF / BMP / ICO / TIFF / WebP
let img = @image.decode_image(image_bytes)

// Photos: apply the EXIF orientation so they display upright
let photo = @image.decode_image_upright(jpeg_bytes)

// Resize and re-encode
let resized = @image.resize(img, 128, 128, Bilinear)
let png = @image.encode_png(resized)
// Smallest exact PNG color type, best compression
let small_png = @image.encode_png(resized, color=Auto, compression=Best)

// JPEG encode (quality defaults to 85, subsampling to Yuv444)
let jpg = @image.encode_jpeg(resized)
let small = @image.encode_jpeg(resized, quality=75, subsampling=Yuv420)

// Other encoders
let gif = @image.encode_gif(resized) // <= 256 colors, alpha 0/255 only
let webp = @image.encode_webp(resized) // lossless
let ico = @image.encode_ico(resized) // single PNG-backed icon, <= 256x256
let avif = @image.encode_avif(resized) // js target only, opaque images

// Animations: every frame is the composited canvas, with its delay
let apng = @image.decode_png_frames(png_bytes)
for frame in apng.frames {
  ignore((frame.image, frame.delay_ms))
}
let gif_anim = @image.decode_gif_frames(gif_bytes)

// Encode animations (every frame is a full canvas)
let apng_out = @image.encode_apng(apng)
let gif_out = @image.encode_gif_animation(apng)

// Detect the format, or decode row by row (PNG / BMP are streamed)
let format = @image.detect_image_format(image_bytes)
let rows : Array[Bytes] = []
let info = @image.decode_image_stream(
  image_bytes,
  on_row=fn(_y, row) { rows.push(row) },
)
inspect((info.format, info.width, info.height))
```

## Support

| Format | Decode | Encode | Animation | Stream decode |
|---|---|---|---|---|
| PNG | yes | yes (RGBA / RGB / gray / gray+alpha / palette) | APNG decode / encode | yes (streamed) |
| JPEG | yes | yes | n/a | yes |
| GIF | yes | yes | decode / encode | yes |
| BMP | yes | yes (32-bit) | n/a | yes (streamed) |
| ICO / CUR | yes | yes (ICO, PNG payload) | n/a | yes |
| TIFF | yes (all pages) | yes (RGB / RGBA) | n/a | yes |
| WebP | yes (lossy / lossless / alpha) | yes (lossy / lossless) | decode / encode | yes |
| AVIF | no | yes (`js` only) | no | no |

All codecs except AVIF run on every target: `js`, `native`, `wasm` and `wasm-gc`. `decode_image_stream` reads rows as they are decoded for PNG and BMP; other formats are decoded first, then emitted row by row.

### Details

- **PNG** decode: grayscale / RGB / palette / gray+alpha / RGBA at 1, 2, 4, 8 and 16 bits (16-bit uses the high byte), `tRNS` transparency, Adam7 interlace. **APNG** (`decode_png_frames`): `fcTL` / `fdAT`, dispose none / background / previous, blend source / over; `decode_png` returns the default image. Encode: RGBA8 by default, or RGB / gray / gray+alpha / palette (1-8 bit, `tRNS`) / `Auto`, with adaptive row filtering and four compression levels. `encode_apng` writes APNG from an `Animation`, cropping each frame to the changed region.
- **JPEG** decode: baseline, extended sequential and progressive (8-bit, Huffman), any sampling factors, multiple scans, restart markers; grayscale, YCbCr, RGB, CMYK and YCCK (the color space is inferred from the JFIF / Adobe markers and component IDs like libjpeg-turbo; CMYK uses the Adobe inverted convention and is converted to RGB like Pillow, without ICC). Output is identical to libjpeg / libjpeg-turbo (islow IDCT, fancy upsampling, fixed-point color conversion). Encode: baseline with 4:4:4 / 4:2:2 / 4:2:0, standard or `optimize=true` (per-image) Huffman tables; the tables and entropy-coded data are identical to libjpeg's for the same quality, subsampling and `optimize` setting.
- **GIF** decode: GIF87a / 89a, global and local color tables, interlace, transparency, animation with disposal 1-3, delays and the NETSCAPE loop count (frames are composited onto a transparent canvas, like browsers). Encode: LZW-compressed; `encode_gif` for one image and `encode_gif_animation` for an `Animation` (global or local palettes, changed-region cropping). At most 256 colors per frame, alpha 0 or 255.
- **BMP** decode: 1 / 2 / 4 / 8-bit palette, RLE4 / RLE8, 16 / 24 / 32-bit, `BI_BITFIELDS` / `BI_ALPHABITFIELDS`, V2-V5 and OS/2 headers. Encode: 32-bit BGRA.
- **ICO / CUR** decode: PNG or BMP (DIB) payloads with the AND mask; `decode_ico` returns the largest image, `decode_ico_all` every image. Encode: one image up to 256x256 with a PNG payload.
- **TIFF** decode (`decode_tiff` for the first image, `decode_tiff_pages` for every page): little / big endian, strips and tiles, chunky and planar samples, None / LZW / Deflate / PackBits with the horizontal predictor, JPEG (compression 7, with `JPEGTables`; raw components like libtiff, YCbCr converted to RGB), WhiteIsZero / BlackIsZero / RGB / palette / CMYK, 1-16 bits per sample, extra alpha (associated alpha is un-premultiplied).
- **WebP** decode: lossy (VP8), lossless (VP8L, all transforms, color cache, meta prefix codes), alpha (`ALPH`, raw or lossless, with spatial filters), and animation (`decode_webp_frames`: `ANMF` frames composited like libwebp's `WebPAnimDecoder`, with blending, disposal and the loop count). Output is identical to libwebp (RGBA, fancy upsampling). Encode: lossless (VP8L) with length-limited Huffman codes, LZ77, color cache and the subtract-green / predictor / palette transforms (the smallest of several configurations is kept; typically within 5-30% of libwebp's size); `encode_webp_lossy(quality~)` writes VP8 (4x4 / 16x16 intra modes chosen per macroblock, adaptive token probabilities, loop filter; alpha as a lossless ALPH chunk) at sizes typically within 0-25% of libwebp's for the same PSNR. `encode_webp_animation` writes an animated WebP from an `Animation` (lossless frames cropped to the changed region, no blending).
- **AVIF** encode: `js` target MVP for opaque images; needs browser AVIF canvas support or a local `ffmpeg`.
- **Resize**: Nearest, and fixed-point separable Bilinear / Bicubic.
- **EXIF orientation**: `read_exif_orientation` reads the tag from JPEG, PNG (`eXIf`), TIFF and WebP (`EXIF`); `apply_orientation` applies it with the same mapping as Pillow's `exif_transpose`; `decode_image_upright` does both.

### Not supported

- JPEG: arithmetic coding, lossless and hierarchical modes, 12-bit samples. Decoders return stored pixels; use `decode_image_upright` / `apply_orientation` for EXIF orientation.
- TIFF: old-style JPEG (compression 6), CCITT and other compressions, BigTIFF, floating-point samples, uncompressed YCbCr.
- AVIF decode; lossy frames in animated WebP.
- Color management (ICC profiles, gamma) is not applied.

Unsupported inputs raise `DecodeError::UnsupportedFeature`.

## Robustness and compatibility

- Decoders raise `DecodeError` on malformed input instead of panicking. This is covered by a mutation fuzz test over every format.
- Images larger than 2^27 pixels (134M) are rejected with `UnsupportedFeature("image too large")`, and PNG / TIFF zlib data is never inflated beyond the size the header implies.
- Decoders are tested against Pillow (libjpeg-turbo, libtiff, libpng, libwebp) fixtures. JPEG decode and encode, and WebP decode, are checked for exact equality with libjpeg / libwebp.
- On the `wasm` (linear memory) target, hot loops use 128-bit SIMD through inline WAT: PNG filters and color expansion, JPEG IDCT / FDCT, the WebP (VP8) loop filter, and resize. Other targets run scalar code that gives identical output. A wasm runtime with SIMD support is required.

## API

```
// Auto-detect
pub fn decode_image(Bytes) -> ImageData raise DecodeError
pub fn decode_image_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> StreamImageInfo raise DecodeError
pub fn detect_image_format(Bytes) -> ImageFormat?

// PNG / APNG
pub fn decode_png(Bytes) -> ImageData raise DecodeError
pub fn decode_png_frames(Bytes) -> Animation raise DecodeError
pub fn decode_png_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> IhdrData raise DecodeError
pub fn encode_png(ImageData, color? : PngColorMode = Rgba, compression? : PngCompression = Default) -> Bytes raise EncodeError
pub fn encode_apng(Animation) -> Bytes raise EncodeError

// JPEG
pub fn decode_jpeg(Bytes) -> ImageData raise DecodeError
pub fn encode_jpeg(ImageData, quality? : Int = 85, subsampling? : JpegSubsampling = Yuv444, optimize? : Bool = false) -> Bytes raise EncodeError

// GIF
pub fn decode_gif(Bytes) -> ImageData raise DecodeError
pub fn decode_gif_frames(Bytes) -> Animation raise DecodeError
pub fn encode_gif(ImageData) -> Bytes raise EncodeError
pub fn encode_gif_animation(Animation) -> Bytes raise EncodeError

// BMP
pub fn decode_bmp(Bytes) -> ImageData raise DecodeError
pub fn decode_bmp_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> (Int, Int) raise DecodeError
pub fn encode_bmp(ImageData) -> Bytes raise EncodeError

// ICO / CUR
pub fn decode_ico(Bytes) -> ImageData raise DecodeError
pub fn decode_ico_all(Bytes) -> Array[ImageData] raise DecodeError
pub fn encode_ico(ImageData) -> Bytes raise EncodeError

// TIFF
pub fn decode_tiff(Bytes) -> ImageData raise DecodeError
pub fn decode_tiff_pages(Bytes) -> Array[ImageData] raise DecodeError
pub fn encode_tiff(ImageData, compression? : TiffCompression = Lzw) -> Bytes raise EncodeError

// WebP / AVIF
pub fn decode_webp(Bytes) -> ImageData raise DecodeError
pub fn decode_webp_frames(Bytes) -> Animation raise DecodeError
pub fn encode_webp(ImageData) -> Bytes raise EncodeError // lossless
pub fn encode_webp_lossy(ImageData, quality? : Int = 75) -> Bytes raise EncodeError
pub fn encode_webp_animation(Animation) -> Bytes raise EncodeError
pub fn encode_avif(ImageData) -> Bytes raise EncodeError

// Resize / orientation
pub fn resize(ImageData, Int, Int, ResizeMethod) -> ImageData raise EncodeError
pub fn read_exif_orientation(Bytes) -> Int?
pub fn apply_orientation(ImageData, Int) -> ImageData
pub fn decode_image_upright(Bytes) -> ImageData raise DecodeError
```

### Types

```
pub(all) struct ImageData { width : Int; height : Int; data : Bytes } // RGBA8
pub(all) enum ResizeMethod { Nearest; Bilinear; Bicubic }
pub(all) enum JpegSubsampling { Yuv444; Yuv422; Yuv420 }
pub(all) enum PngColorMode { Rgba; Rgb; Gray; GrayAlpha; Palette; Auto }
pub(all) enum PngCompression { Stored; Fast; Default; Best }
pub(all) enum TiffCompression { NoCompression; Lzw; Deflate; PackBits }
pub(all) struct Animation { width : Int; height : Int; frames : Array[AnimationFrame]; plays : Int } // plays: 0 = forever
pub(all) struct AnimationFrame { image : ImageData; delay_ms : Int }
pub(all) enum ImageFormat { Png; Bmp; Jpeg; Gif; Ico; Tiff; WebP }
pub(all) suberror DecodeError { InvalidSignature(String); InvalidChunkCrc(String); MissingChunk(String); UnsupportedFeature(String); CorruptData(String) }
pub(all) suberror EncodeError { InvalidDimensions(String); InvalidData(String) }
```

## License

Apache-2.0
