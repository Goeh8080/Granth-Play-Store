import { test } from "node:test";
import assert from "node:assert/strict";
import { imageSize, PAGE_MAX_EDGE, targetSize } from "./pdf-image.ts";

function png(w: number, h: number) {
  const bytes = new Uint8Array(32);
  bytes.set([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], 0);
  new DataView(bytes.buffer).setUint32(16, w);
  new DataView(bytes.buffer).setUint32(20, h);
  return bytes;
}

function jpeg(w: number, h: number, sof = 0xc0) {
  // SOI, APP0 (len 16), SOFn (len 17)
  const app0 = [0xff, 0xe0, 0x00, 0x10, ...new Array(14).fill(0)];
  const sofSeg = [0xff, sof, 0x00, 0x11, 0x08, h >> 8, h & 255, w >> 8, w & 255, 0x03, ...new Array(9).fill(0)];
  return new Uint8Array([0xff, 0xd8, ...app0, ...sofSeg, 0xff, 0xd9]);
}

test("imageSize reads PNG and JPEG headers", () => {
  assert.deepEqual(imageSize(png(1200, 1800)), { w: 1200, h: 1800, kind: "png" });
  assert.deepEqual(imageSize(jpeg(5973, 5449)), { w: 5973, h: 5449, kind: "jpg" });
  assert.deepEqual(imageSize(jpeg(800, 600, 0xc2)), { w: 800, h: 600, kind: "jpg" });
  assert.equal(imageSize(new TextEncoder().encode("<html>not an image</html>")), null);
});

test("targetSize caps the long edge and never upscales", () => {
  assert.deepEqual(targetSize(5973, 5449), { w: PAGE_MAX_EDGE, h: Math.round((5449 * PAGE_MAX_EDGE) / 5973) });
  assert.deepEqual(targetSize(1200, 1800), { w: 1000, h: 1500 });
  assert.deepEqual(targetSize(640, 480), { w: 640, h: 480 });
});
