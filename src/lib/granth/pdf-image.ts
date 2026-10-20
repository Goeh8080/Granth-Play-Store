/**
 * Image preparation for PDF pages: parse the header, and only when the picture
 * is larger than a page needs, decode → downscale → re-encode as JPEG.
 *
 * This module has no DOM-only dependencies so it runs both inside the PDF image
 * Web Worker (OffscreenCanvas) and on the main thread as a fallback.
 */

export type Shot = { bytes: Uint8Array; w: number; h: number; kind: "jpg" | "png" };

/** A4 at ~170 dpi. Enough for scripture photos, a fraction of the original bytes. */
export const PAGE_MAX_EDGE = 1500;
export const PAGE_QUALITY = 0.8;
/** JPEGs already this small (and within PAGE_MAX_EDGE) are embedded untouched: no decode at all. */
export const PASS_THROUGH_BYTES = 360_000;

export function imageSize(bytes: Uint8Array): { w: number; h: number; kind: "jpg" | "png" } | null {
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const w = ((bytes[16] ?? 0) << 24) | ((bytes[17] ?? 0) << 16) | ((bytes[18] ?? 0) << 8) | (bytes[19] ?? 0);
    const h = ((bytes[20] ?? 0) << 24) | ((bytes[21] ?? 0) << 16) | ((bytes[22] ?? 0) << 8) | (bytes[23] ?? 0);
    if (w > 0 && h > 0) return { w, h, kind: "png" };
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = bytes[offset + 1] ?? 0;
    if (marker === 0xff) {
      offset += 1;
      continue;
    }
    const sof = marker >= 0xc0 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc;
    if (sof) {
      const h = ((bytes[offset + 5] ?? 0) << 8) | (bytes[offset + 6] ?? 0);
      const w = ((bytes[offset + 7] ?? 0) << 8) | (bytes[offset + 8] ?? 0);
      if (w > 0 && h > 0) return { w, h, kind: "jpg" };
    }
    if (marker === 0xd8) {
      offset += 2;
      continue;
    }
    if (marker === 0xd9 || marker === 0xda) break;
    const length = ((bytes[offset + 2] ?? 0) << 8) | (bytes[offset + 3] ?? 0);
    if (length < 2) break;
    offset += 2 + length;
  }
  return null;
}

/** Progressive / arithmetic-coded JPEGs are re-encoded too: some PDF viewers choke on them. */
function isBaselineFriendly(bytes: Uint8Array) {
  for (let offset = 2; offset + 3 < bytes.length; ) {
    if (bytes[offset] !== 0xff) {
      offset += 1;
      continue;
    }
    const marker = bytes[offset + 1] ?? 0;
    if (marker === 0xc0 || marker === 0xc1) return true;
    if (marker === 0xc2 || (marker >= 0xc3 && marker <= 0xcf && marker !== 0xc4 && marker !== 0xc8 && marker !== 0xcc)) return false;
    if (marker === 0xda || marker === 0xd9) return false;
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) {
      offset += 2;
      continue;
    }
    const length = ((bytes[offset + 2] ?? 0) << 8) | (bytes[offset + 3] ?? 0);
    if (length < 2) return false;
    offset += 2 + length;
  }
  return false;
}

export function targetSize(w: number, h: number, maxEdge = PAGE_MAX_EDGE) {
  const scale = Math.min(1, maxEdge / Math.max(w, h));
  return { w: Math.max(1, Math.round(w * scale)), h: Math.max(1, Math.round(h * scale)) };
}

type AnyCanvas = OffscreenCanvas | HTMLCanvasElement;

function makeCanvas(w: number, h: number): AnyCanvas {
  if (typeof OffscreenCanvas !== "undefined") return new OffscreenCanvas(w, h);
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  return canvas;
}

async function encodeJpeg(canvas: AnyCanvas, quality: number): Promise<Uint8Array | null> {
  if ("convertToBlob" in canvas) {
    const blob = await canvas.convertToBlob({ type: "image/jpeg", quality });
    return new Uint8Array(await blob.arrayBuffer());
  }
  const html = canvas as HTMLCanvasElement;
  const blob = await new Promise<Blob | null>((resolve) => {
    try {
      html.toBlob(resolve, "image/jpeg", quality);
    } catch {
      resolve(null);
    }
  });
  if (blob && blob.size > 32) return new Uint8Array(await blob.arrayBuffer());
  // Some old WebViews return null from toBlob; dataURL always works.
  const data = html.toDataURL("image/jpeg", quality);
  const binary = atob(data.slice(data.indexOf(",") + 1));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function decode(blob: Blob, size: { w: number; h: number } | null): Promise<ImageBitmap> {
  if (size) {
    try {
      // Let the decoder downscale while decoding: far less memory than full size + drawImage.
      return await createImageBitmap(blob, { resizeWidth: size.w, resizeHeight: size.h, resizeQuality: "medium" });
    } catch {
      /* older engines reject the resize options */
    }
  }
  return createImageBitmap(blob);
}

/**
 * Turn a cached/fetched picture into page-ready JPEG bytes.
 * Returns null for anything that is not a decodable image (the page then gets a placeholder).
 */
export async function prepareShot(blob: Blob | null | undefined, maxEdge = PAGE_MAX_EDGE, quality = PAGE_QUALITY): Promise<Shot | null> {
  if (!blob || blob.size < 32) return null;
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const parsed = imageSize(bytes);
  if (
    parsed &&
    parsed.kind === "jpg" &&
    Math.max(parsed.w, parsed.h) <= maxEdge &&
    bytes.length <= PASS_THROUGH_BYTES &&
    isBaselineFriendly(bytes)
  ) {
    return { bytes, ...parsed };
  }
  try {
    const want = parsed ? targetSize(parsed.w, parsed.h, maxEdge) : null;
    const bitmap = await decode(new Blob([bytes]), want);
    const size = targetSize(bitmap.width, bitmap.height, maxEdge);
    const canvas = makeCanvas(size.w, size.h);
    const ctx = canvas.getContext("2d") as CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D | null;
    if (!ctx) {
      bitmap.close();
      return null;
    }
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, size.w, size.h);
    ctx.drawImage(bitmap, 0, 0, size.w, size.h);
    bitmap.close();
    const out = await encodeJpeg(canvas, quality);
    if (!out || out.length < 32) return null;
    return { bytes: out, w: size.w, h: size.h, kind: "jpg" };
  } catch {
    // Undecodable bytes: embed as-is only if pdf-lib can read the header, else give up.
    return parsed ? { bytes, ...parsed } : null;
  }
}
