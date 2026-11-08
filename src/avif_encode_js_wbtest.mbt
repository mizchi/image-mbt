// js only: decode the encoder's output with ffmpeg (dav1d / libaom) and
// compare it with the encoder's own reconstruction.

///|
#borrow(data)
extern "js" fn avif_test_ffmpeg(data : Bytes, pix_fmt : String) -> Bytes =
  #| (data, pix_fmt) => {
  #|   const fs = require("node:fs");
  #|   const os = require("node:os");
  #|   const path = require("node:path");
  #|   const cp = require("node:child_process");
  #|   const dir = fs.mkdtempSync(path.join(os.tmpdir(), "image-mbt-avif-"));
  #|   const input = path.join(dir, "in.avif");
  #|   fs.writeFileSync(input, Buffer.from(data));
  #|   try {
  #|     const out = cp.execFileSync("ffmpeg", ["-v", "error", "-i", input,
  #|       "-f", "rawvideo", "-pix_fmt", pix_fmt, "-"], { maxBuffer: 1 << 28 });
  #|     return new Uint8Array(out);
  #|   } finally {
  #|     fs.rmSync(dir, { recursive: true, force: true });
  #|   }
  #| }

///|
test "AVIF reconstruction equals the ffmpeg decode (no loop filter)" {
  for size in [(37, 29), (130, 70), (64, 64)] {
    let (w, h) = size
    let img = avif_wb_image(w, h)
    for qidx in [30, 140, 250] {
      let (seq, frame, enc) = av1_encode_still(
        avif_rgb_to_yuv420(img),
        w,
        h,
        qidx,
        loop_filter=false,
      )
      let avif = avif_container(w, h, seq, frame, None)
      let dec = avif_test_ffmpeg(avif, "yuv420p")
      let cw = (w + 1) / 2
      let ch = (h + 1) / 2
      assert_eq(dec.length(), w * h + 2 * cw * ch)
      let mut o = 0
      for p in 0..<3 {
        let pw = if p == 0 { w } else { cw }
        let ph = if p == 0 { h } else { ch }
        for y in 0..<ph {
          for x in 0..<pw {
            assert_eq(dec[o].to_int(), enc.rec[p][y * enc.stride[p] + x])
            o += 1
          }
        }
      }
    }
  }
}

///|
test "AVIF decodes close to the source" {
  let img = avif_wb_image(96, 80)
  let avif = encode_avif(img, quality=90)
  let rgb = avif_test_ffmpeg(avif, "gray")
  // Luma of the source.
  let mut se = 0.0
  for i in 0..<(96 * 80) {
    let r = img.data[i * 4].to_int()
    let g = img.data[i * 4 + 1].to_int()
    let b = img.data[i * 4 + 2].to_int()
    let y = (19595 * r + 38470 * g + 7471 * b + 32768) >> 16
    let d = (rgb[i].to_int() - y).to_double()
    se = se + d * d
  }
  let mse = se / (96.0 * 80.0)
  // > 35 dB luma PSNR.
  assert_true(mse < 20.6)
}

///|
fn avif_wb_image(w : Int32, h : Int32) -> ImageData {
  let data = FixedArray::make(w * h * 4, b'\x00')
  let mut seed = 5U
  for y in 0..<h {
    for x in 0..<w {
      seed = seed * 1103515245U + 12345U
      let n = ((seed >> 16) & 7U).reinterpret_as_int()
      let i = (y * w + x) * 4
      data[i] = ((x * 3 + n) & 255).to_byte()
      data[i + 1] = ((y * 4 + x / 3) & 255).to_byte()
      data[i + 2] = (((x + y) * 2 + n * 3) & 255).to_byte()
      data[i + 3] = b'\xff'
    }
  }
  { width: w, height: h, data: Bytes::from_array(data), }
}
