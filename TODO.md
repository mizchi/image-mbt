# TODO (image-mbt)

## P0: PNG first

- [ ] PNG decoder (IHDR/PLTE/IDAT/IEND)
- [ ] PNG encoder (RGBA8 baseline)
- [ ] zlib/deflate integration point
- [ ] Color type conversion to RGBA8
- [ ] Error model and diagnostics

## P1: Runtime integration

- [ ] Engine-ready `ImageData` contract
- [ ] Zero-copy decode path for js/wasm where possible
- [ ] Streaming decode API for large assets
- [ ] Golden tests with fixture corpus

## P2: Extended formats

- [ ] JPEG decode (minimum baseline)
- [ ] Optional WebP decode adapter
- [ ] Metadata handling policy (gamma/sRGB/ICC)

## Packaging

- [ ] Split reusable codec core from engine-specific adapters
- [ ] Stabilize public API and add compatibility tests
