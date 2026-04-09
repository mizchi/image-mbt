# mizchi/image

Image codec primitives for MoonBit (no external dependencies except `mizchi/zlib`).

## Features

- **PNG** decode / encode (RGBA8, adaptive row filtering)
- **BMP** decode / encode (24-bit uncompressed)
- **JPEG** baseline decode / encode
- **GIF** encode (single-frame, indexed palette, binary transparency)
- **WebP** lossless encode (still image, MVP)
- **Resize** with Nearest / Bilinear / Bicubic interpolation

All decoded images are normalized to `ImageData` (RGBA8 buffer).

## Install

```bash
moon add mizchi/image
```

## Usage

```moonbit
// PNG decode → resize → encode
let img = @image.decode_png(png_bytes)
let resized = @image.resize(img, 128, 128, Bilinear)
let out = @image.encode_png(resized)

// JPEG encode (quality defaults to 85)
let jpg = @image.encode_jpeg(resized)

// GIF encode (<= 256 colors, alpha 0/255 only)
let gif = @image.encode_gif(resized)

// WebP lossless encode
let webp = @image.encode_webp(resized)

// Stream decode (PNG/BMP auto detect)
let rows : Array[Bytes] = []
let info = @image.decode_image_stream(
  image_bytes,
  on_row=fn(_y, row) { rows.push(row) },
)
inspect((info.format, info.width, info.height))
```

## API

```
pub fn decode_png(Bytes) -> ImageData raise DecodeError
pub fn decode_png_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> IhdrData raise DecodeError
pub fn decode_image_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> StreamImageInfo raise DecodeError
pub fn encode_png(ImageData) -> Bytes raise EncodeError
pub fn decode_bmp(Bytes) -> ImageData raise DecodeError
pub fn decode_bmp_stream(Bytes, on_row~ : (Int, Bytes) -> Unit) -> (Int, Int) raise DecodeError
pub fn encode_bmp(ImageData) -> Bytes raise EncodeError
pub fn decode_jpeg(Bytes) -> ImageData raise DecodeError
pub fn encode_jpeg(ImageData, quality? : Int = 85) -> Bytes raise EncodeError
pub fn encode_gif(ImageData) -> Bytes raise EncodeError
pub fn encode_webp(ImageData) -> Bytes raise EncodeError
pub fn resize(ImageData, Int, Int, ResizeMethod) -> ImageData raise EncodeError
```

### Types

```
pub(all) struct ImageData { width : Int; height : Int; data : Bytes }
pub(all) enum ResizeMethod { Nearest; Bilinear; Bicubic }
```

## Targets

Works on `js`, `native`, and `wasm-gc` backends.

## License

Apache-2.0
