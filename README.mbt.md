# mizchi/image

Image codec primitives for MoonBit: decode PNG / APNG / JPEG / GIF / BMP / ICO / TIFF, encode PNG / JPEG / GIF / BMP / WebP / ICO / AVIF, and resize. Core codecs have no external dependencies except `mizchi/zlib`; the AVIF js-target MVP uses browser AVIF canvas support or local `ffmpeg`.

All decoded images are normalized to `ImageData` (RGBA8 buffer).

## Install

```bash
moon add mizchi/image
```

## Usage

```moonbit
// Auto-detect PNG / JPEG / GIF / BMP / ICO / TIFF
let img = @image.decode_image(image_bytes)

// Resize and re-encode
let resized = @image.resize(img, 128, 128, Bilinear)
let png = @image.encode_png(resized)

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

// Stream decode, row by row (PNG / BMP)
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
| PNG | yes | yes (RGBA8) | APNG decode | yes |
| JPEG | yes | yes | n/a | no |
| GIF | yes | yes (single frame) | decode | no |
| BMP | yes | yes (32-bit) | n/a | yes |
| ICO / CUR | yes | yes (ICO, PNG payload) | n/a | no |
| TIFF | yes (first image) | no | n/a | no |
| WebP | no | yes (lossless) | no | no |
| AVIF | no | yes (`js` only) | no | no |

All codecs except AVIF run on every target: `js`, `native`, `wasm` and `wasm-gc`.

### Details

- **PNG** decode: grayscale / RGB / palette / gray+alpha / RGBA at 1, 2, 4, 8 and 16 bits (16-bit uses the high byte), `tRNS` transparency, Adam7 interlace. **APNG** (`decode_png_frames`): `fcTL` / `fdAT`, dispose none / background / previous, blend source / over; `decode_png` returns the default image. Encode: RGBA8 with adaptive row filtering.
- **JPEG** decode: baseline, extended sequential and progressive (8-bit, Huffman), any sampling factors, multiple scans, restart markers. Output is identical to libjpeg / libjpeg-turbo (islow IDCT, fancy upsampling, fixed-point color conversion). Encode: baseline with 4:4:4 / 4:2:2 / 4:2:0; the entropy-coded data is identical to libjpeg's for the same quality and subsampling (standard Huffman tables).
- **GIF** decode: GIF87a / 89a, global and local color tables, interlace, transparency, animation with disposal 1-3, delays and the NETSCAPE loop count (frames are composited onto a transparent canvas, like browsers). Encode: single frame, at most 256 colors, alpha 0 or 255.
- **BMP** decode: 1 / 2 / 4 / 8-bit palette, RLE4 / RLE8, 16 / 24 / 32-bit, `BI_BITFIELDS` / `BI_ALPHABITFIELDS`, V2-V5 and OS/2 headers. Encode: 32-bit BGRA.
- **ICO / CUR** decode: PNG or BMP (DIB) payloads with the AND mask; `decode_ico` returns the largest image, `decode_ico_all` every image. Encode: one image up to 256x256 with a PNG payload.
- **TIFF** decode (first image): little / big endian, strips and tiles, chunky and planar samples, None / LZW / Deflate / PackBits with the horizontal predictor, WhiteIsZero / BlackIsZero / RGB / palette / CMYK, 1-16 bits per sample, extra alpha (associated alpha is un-premultiplied).
- **WebP** encode: lossless (VP8L) still images.
- **AVIF** encode: `js` target MVP for opaque images; needs browser AVIF canvas support or a local `ffmpeg`.
- **Resize**: Nearest, and fixed-point separable Bilinear / Bicubic.

### Not supported

- JPEG: arithmetic coding, lossless and hierarchical modes, 12-bit samples, CMYK / Adobe 4-component files; EXIF orientation is not applied.
- TIFF: JPEG / CCITT and other compressions, BigTIFF, floating-point samples, pages after the first.
- WebP and AVIF decode; animated GIF / APNG encode.
- Color management (ICC profiles, gamma) is not applied.

Unsupported inputs raise `DecodeError::UnsupportedFeature`.

## Robustness and compatibility

- Decoders raise `DecodeError` on malformed input instead of panicking. This is covered by a mutation fuzz test over every format.
- Images larger than 2^27 pixels (134M) are rejected with `UnsupportedFeature("image too large")`.
- Decoders are tested against Pillow (libjpeg-turbo, libtiff, libpng) fixtures. JPEG decode and encode are checked for exact equality with libjpeg.
- On the `wasm` (linear memory) target, hot loops use 128-bit SIMD through inline WAT: PNG filters and color expansion, JPEG IDCT / FDCT, and resize. Other targets run scalar code that gives identical output. A wasm runtime with SIMD support is required.

## API

```
// Auto-detect
pub fn decode_image(Bytes) -> ImageData raise DecodeError
pub fn decode_image_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> StreamImageInfo raise DecodeError

// PNG / APNG
pub fn decode_png(Bytes) -> ImageData raise DecodeError
pub fn decode_png_frames(Bytes) -> Animation raise DecodeError
pub fn decode_png_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> IhdrData raise DecodeError
pub fn encode_png(ImageData) -> Bytes raise EncodeError

// JPEG
pub fn decode_jpeg(Bytes) -> ImageData raise DecodeError
pub fn encode_jpeg(ImageData, quality? : Int = 85, subsampling? : JpegSubsampling = Yuv444) -> Bytes raise EncodeError

// GIF
pub fn decode_gif(Bytes) -> ImageData raise DecodeError
pub fn decode_gif_frames(Bytes) -> GifAnimation raise DecodeError
pub fn encode_gif(ImageData) -> Bytes raise EncodeError

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

// WebP / AVIF
pub fn encode_webp(ImageData) -> Bytes raise EncodeError
pub fn encode_avif(ImageData) -> Bytes raise EncodeError

// Resize
pub fn resize(ImageData, Int, Int, ResizeMethod) -> ImageData raise EncodeError
```

### Types

```
pub(all) struct ImageData { width : Int; height : Int; data : Bytes } // RGBA8
pub(all) enum ResizeMethod { Nearest; Bilinear; Bicubic }
pub(all) enum JpegSubsampling { Yuv444; Yuv422; Yuv420 }
pub(all) struct Animation { width : Int; height : Int; frames : Array[AnimationFrame]; plays : Int } // plays: 0 = forever
pub(all) struct AnimationFrame { image : ImageData; delay_ms : Int }
pub(all) struct GifAnimation { width : Int; height : Int; frames : Array[GifFrame]; loop_count : Int? }
pub(all) struct GifFrame { image : ImageData; delay_ms : Int }
pub(all) suberror DecodeError { InvalidSignature(String); InvalidChunkCrc(String); MissingChunk(String); UnsupportedFeature(String); CorruptData(String) }
pub(all) suberror EncodeError { InvalidDimensions(String); InvalidData(String) }
```

## License

Apache-2.0
