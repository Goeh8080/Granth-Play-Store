import { PDFDocument, rgb, StandardFonts, type PDFDocument as PdfDoc, type PDFFont, type PDFImage, type PDFPage } from "pdf-lib";
import type { PdfStyle } from "@/lib/granth/pdf-style";
import { PAGE_MAX_EDGE, PAGE_QUALITY, prepareShot, type Shot } from "@/lib/granth/pdf-image";
import ImageWorker from "@/lib/granth/pdf-image.worker.ts?worker&inline";

export type { PdfStyle } from "@/lib/granth/pdf-style";

export type BookPage = {
  title: string;
  subtitle?: string;
  body?: string;
  meta?: string;
  /** Media path of the page picture; loaded through `options.loadImage`. */
  imagePath?: string | null;
  cover?: boolean;
  topicCover?: boolean;
};

export type PdfBuildOptions = {
  /** Pages finished so far (real progress, pages are assembled as their pictures arrive). */
  onPage?: (done: number, total: number) => void;
  onPreview?: (blob: Blob) => void;
  isCancelled?: () => boolean;
  /** Read a picture (IndexedDB first, network second). Null = unavailable. */
  loadImage?: (path: string) => Promise<Blob | null>;
  /** Called once at the end with the number of pictures that could not be loaded. */
  onMissing?: (count: number) => void;
};

type Caption = { bytes: Uint8Array; w: number; h: number };
type LineSpec = { text: string; size: number; color: string; weight: number };

const SCALE = 2;
const CAPTION_SCALE = 2;
const PAPER = "#fffdf7";
const FONT_STACK = '"Noto Sans Devanagari", sans-serif';
/** Text that forces the Devanagari subset (unicode-range) to download, including conjuncts. */
const DEVANAGARI_SAMPLE = "ग्रंथ प्रबंधन क्षत्रज्ञ श्री द्ध ट्र ॐ १२३";

/* ------------------------------------------------------------------ fonts */

let fontsReady: Promise<void> | null = null;

/**
 * Load the Devanagari faces once per session. `document.fonts.load()` only
 * fetches a face whose unicode-range matches the sample text, so a Devanagari
 * sample is passed explicitly; otherwise canvas text could fall back to a
 * system font. Never blocks longer than 5 s (offline first run).
 */
function ensureFonts() {
  if (!fontsReady) {
    const loads = Promise.all([
      document.fonts.load(`700 32px "Noto Sans Devanagari"`, DEVANAGARI_SAMPLE),
      document.fonts.load(`600 28px "Noto Sans Devanagari"`, DEVANAGARI_SAMPLE),
      document.fonts.load(`500 22px "Noto Sans Devanagari"`, DEVANAGARI_SAMPLE),
      document.fonts.load(`400 72px "Yatra One"`, DEVANAGARI_SAMPLE),
    ]).then(() => undefined);
    fontsReady = Promise.race([
      loads.catch(() => undefined),
      new Promise<void>((resolve) => window.setTimeout(resolve, 5000)),
    ]);
  }
  return fontsReady;
}

/* ---------------------------------------------------------- image workers */

type Pending = { resolve: (shot: Shot | null) => void; timer: number };

class ShotPool {
  private workers: Worker[] = [];
  private broken = false;
  private next = 0;
  private seq = 0;
  private pending = new Map<number, Pending>();

  constructor(size: number) {
    try {
      for (let index = 0; index < size; index += 1) {
        const worker = new ImageWorker();
        worker.onmessage = (event: MessageEvent<{ id: number; shot: Shot | null }>) => {
          const job = this.pending.get(event.data.id);
          if (!job) return;
          this.pending.delete(event.data.id);
          window.clearTimeout(job.timer);
          job.resolve(event.data.shot);
        };
        worker.onerror = () => {
          this.broken = true;
        };
        this.workers.push(worker);
      }
    } catch {
      this.broken = true;
    }
  }

  /** Decode/downscale off the main thread; falls back to the main thread if workers are unavailable. */
  prepare(blob: Blob): Promise<Shot | null> {
    const worker = this.workers[this.next % Math.max(1, this.workers.length)];
    this.next += 1;
    if (this.broken || !worker) return prepareShot(blob, PAGE_MAX_EDGE, PAGE_QUALITY);
    const id = (this.seq += 1);
    return new Promise<Shot | null>((resolve) => {
      const timer = window.setTimeout(() => {
        // A wedged worker must never stall the PDF: do this one on the main thread.
        this.pending.delete(id);
        resolve(prepareShot(blob, PAGE_MAX_EDGE, PAGE_QUALITY));
      }, 20_000);
      this.pending.set(id, { resolve, timer });
      try {
        worker.postMessage({ id, blob, maxEdge: PAGE_MAX_EDGE, quality: PAGE_QUALITY });
      } catch {
        window.clearTimeout(timer);
        this.pending.delete(id);
        this.broken = true;
        resolve(prepareShot(blob, PAGE_MAX_EDGE, PAGE_QUALITY));
      }
    });
  }
}

let pool: ShotPool | null = null;
function shotPool() {
  if (!pool) {
    const cores = typeof navigator !== "undefined" ? navigator.hardwareConcurrency || 4 : 4;
    pool = new ShotPool(Math.max(1, Math.min(3, cores - 1)));
  }
  return pool;
}

/* Page-ready pictures survive between PDFs (same granth covers appear in many topics). */
const SHOT_CACHE_BYTES = 40 * 1024 * 1024;
const shotCache = new Map<string, Shot>();
let shotCacheBytes = 0;

function rememberShot(path: string, shot: Shot) {
  if (shotCache.has(path) || shot.bytes.length > SHOT_CACHE_BYTES / 4) return;
  shotCache.set(path, shot);
  shotCacheBytes += shot.bytes.length;
  for (const [key, value] of shotCache) {
    if (shotCacheBytes <= SHOT_CACHE_BYTES) break;
    shotCache.delete(key);
    shotCacheBytes -= value.bytes.length;
  }
}

function cachedShot(path: string) {
  const shot = shotCache.get(path);
  if (!shot) return null;
  shotCache.delete(path);
  shotCache.set(path, shot);
  return shot;
}

function limiter(size: number) {
  let active = 0;
  const waiting: Array<() => void> = [];
  return async function run<T>(task: () => Promise<T>): Promise<T> {
    if (active >= size) await new Promise<void>((resolve) => waiting.push(resolve));
    active += 1;
    try {
      return await task();
    } finally {
      active -= 1;
      waiting.shift()?.();
    }
  };
}

function yieldToUi() {
  const host = globalThis as unknown as { scheduler?: { yield?: () => Promise<void> } };
  if (host.scheduler?.yield) return host.scheduler.yield();
  return new Promise<void>((resolve) => window.setTimeout(resolve, 0));
}

/* ----------------------------------------------------------------- canvas */

async function canvasJpeg(canvas: HTMLCanvasElement, quality: number): Promise<Uint8Array> {
  try {
    const blob = await new Promise<Blob | null>((resolve) => {
      try {
        canvas.toBlob((value) => resolve(value), "image/jpeg", quality);
      } catch {
        resolve(null);
      }
    });
    if (blob && blob.size > 32) return new Uint8Array(await blob.arrayBuffer());
  } catch {
    /* WebView toBlob can return null */
  }
  const data = canvas.toDataURL("image/jpeg", quality);
  const binary = atob(data.slice(data.indexOf(",") + 1));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

let measureCtx: CanvasRenderingContext2D | null = null;
function measurer() {
  if (!measureCtx) measureCtx = document.createElement("canvas").getContext("2d");
  return measureCtx;
}

function breakWord(ctx: CanvasRenderingContext2D, word: string, maxWidth: number): string[] {
  if (ctx.measureText(word).width <= maxWidth) return [word];
  const parts: string[] = [];
  let chunk = "";
  // Split on grapheme clusters so a conjunct (क्ष, द्ध…) or a matra is never cut in half.
  const segmenter = typeof Intl !== "undefined" && "Segmenter" in Intl ? new Intl.Segmenter("hi", { granularity: "grapheme" }) : null;
  const pieces = segmenter ? Array.from(segmenter.segment(word), (part) => part.segment) : Array.from(word);
  for (const ch of pieces) {
    const next = chunk + ch;
    if (ctx.measureText(next).width <= maxWidth) chunk = next;
    else {
      if (chunk) parts.push(chunk);
      chunk = ch;
    }
  }
  if (chunk) parts.push(chunk);
  return parts.length ? parts : [word];
}

function wrapText(ctx: CanvasRenderingContext2D, text: string, maxWidth: number): string[] {
  const lines: string[] = [];
  for (const paragraph of text.split(/\n/)) {
    const words = paragraph.split(/\s+/).filter(Boolean).flatMap((word) => breakWord(ctx, word, maxWidth));
    if (!words.length) continue;
    let line = "";
    for (const word of words) {
      const next = line ? `${line} ${word}` : word;
      if (ctx.measureText(next).width <= maxWidth) line = next;
      else {
        if (line) lines.push(line);
        line = word;
      }
    }
    if (line) lines.push(line);
  }
  return lines;
}

/**
 * Text is drawn by the browser (HarfBuzz shaping: correct matras, conjuncts and
 * reph) onto a canvas and embedded as a JPEG. pdf-lib cannot shape Devanagari,
 * so this is what keeps Hindi correct in every PDF viewer.
 */
async function makeCaption(lines: LineSpec[], widthPt: number, bg: string): Promise<Caption | null> {
  const usable = lines
    .map((line) => ({ ...line, text: line.text.replace(/[ \t]+/g, " ").trim() }))
    .filter((line) => line.text);
  if (!usable.length || widthPt < 24) return null;
  await ensureFonts();
  const scale = CAPTION_SCALE;
  const widthPx = Math.max(80, Math.round(widthPt * scale));
  const measure = measurer();
  if (!measure) return null;
  const rows: LineSpec[] = [];
  for (const line of usable) {
    measure.font = `${line.weight} ${line.size * scale}px ${FONT_STACK}`;
    for (const text of wrapText(measure, line.text, widthPx - 28 * scale)) rows.push({ text, size: line.size, color: line.color, weight: line.weight });
  }
  if (!rows.length) return null;
  const lineBox = (row: LineSpec) => Math.ceil(row.size * 1.62 * scale);
  const heightPx = rows.reduce((sum, row) => sum + lineBox(row), Math.round(16 * scale));
  const canvas = document.createElement("canvas");
  canvas.width = widthPx;
  canvas.height = Math.max(8, heightPx);
  const ctx = canvas.getContext("2d");
  if (!ctx) return null;
  ctx.fillStyle = bg;
  ctx.fillRect(0, 0, canvas.width, canvas.height);
  ctx.textBaseline = "top";
  let y = 8 * scale;
  for (const row of rows) {
    ctx.font = `${row.weight} ${row.size * scale}px ${FONT_STACK}`;
    ctx.fillStyle = row.color;
    ctx.fillText(row.text, 12 * scale, y);
    y += lineBox(row);
  }
  return { bytes: await canvasJpeg(canvas, 0.92), w: widthPt, h: canvas.height / scale };
}

function contain(boxW: number, boxH: number, imgW: number, imgH: number) {
  const scale = Math.min(boxW / imgW, boxH / imgH);
  return { w: imgW * scale, h: imgH * scale };
}

type Embedder = {
  doc: PdfDoc;
  images: Map<string, Promise<PDFImage>>;
  captions: Map<string, Promise<PDFImage>>;
};

async function embedShot(kit: Embedder, shot: Shot, key: string): Promise<PDFImage> {
  const known = kit.images.get(key);
  if (known) return known;
  const job = (async () => {
    try {
      if (shot.kind === "png") return await kit.doc.embedPng(shot.bytes);
      return await kit.doc.embedJpg(shot.bytes);
    } catch {
      const fixed = await prepareShot(new Blob([shot.bytes as BlobPart]), PAGE_MAX_EDGE, PAGE_QUALITY);
      if (!fixed || fixed.kind !== "jpg") throw new Error("image");
      return kit.doc.embedJpg(fixed.bytes);
    }
  })();
  kit.images.set(key, job);
  job.catch(() => kit.images.delete(key));
  return job;
}

function embedCaption(kit: Embedder, caption: Caption, key: string) {
  const known = kit.captions.get(key);
  if (known) return known;
  const job = kit.doc.embedJpg(caption.bytes);
  kit.captions.set(key, job);
  return job;
}

function drawBordered(page: PDFPage, image: PDFImage, x: number, y: number, w: number, h: number) {
  const border = 1;
  page.drawRectangle({ x: x - border, y: y - border, width: w + border * 2, height: h + border * 2, color: rgb(0, 0, 0) });
  page.drawImage(image, { x, y, width: w, height: h });
}

/** Shown where a picture could not be loaded, so one bad image never fails the PDF. */
async function drawMissing(kit: Embedder, page: PDFPage, x: number, y: number, w: number, h: number) {
  page.drawRectangle({ x, y, width: w, height: h, color: rgb(0.961, 0.902, 0.784), borderColor: rgb(0.788, 0.659, 0.298), borderWidth: 1.5 });
  const label = await missingLabel();
  if (!label) return;
  const image = await embedCaption(kit, label, "__missing__");
  const lw = Math.min(w - 16, label.w);
  const lh = (label.h * lw) / label.w;
  page.drawImage(image, { x: x + (w - lw) / 2, y: y + (h - lh) / 2, width: lw, height: lh });
}

let missingCaption: Promise<Caption | null> | null = null;
function missingLabel() {
  if (!missingCaption) {
    missingCaption = makeCaption(
      [
        { text: "चित्र उपलब्ध नहीं", size: 18, color: "#7b1f2e", weight: 700 },
        { text: "इंटरनेट से सिंक करके PDF फिर बनाएँ", size: 12, color: "#4a2c0a", weight: 500 },
      ],
      260,
      "#f5e6c8",
    );
  }
  return missingCaption;
}

function pageCopy(input: BookPage) {
  const header = (input.body || input.subtitle || input.title || "ग्रंथ").trim();
  const footer = [input.body ? input.title : "", input.meta || "", !input.body ? input.subtitle || "" : ""]
    .map((part) => part.trim())
    .filter((part) => part && part !== "आवरण")
    .filter((part, index, all) => all.indexOf(part) === index)
    .join("\n");
  return { header, footer };
}

async function paintTopicCover(doc: PdfDoc, input: BookPage, onPreview?: (canvas: HTMLCanvasElement) => void | Promise<void>) {
  await ensureFonts();
  const pageW = 595.28;
  const pageH = 841.89;
  const canvas = document.createElement("canvas");
  canvas.width = Math.round(pageW * SCALE);
  canvas.height = Math.round(pageH * SCALE);
  const ctx = canvas.getContext("2d");
  if (!ctx) return;
  const w = canvas.width;
  const h = canvas.height;
  ctx.fillStyle = "#f6efe2";
  ctx.fillRect(0, 0, w, h);
  const blooms: Array<[number, number, number, string]> = [
    [w * 0.18, h * 0.16, w * 0.42, "rgba(232, 130, 26, 0.34)"],
    [w * 0.84, h * 0.2, w * 0.36, "rgba(123, 31, 46, 0.2)"],
    [w * 0.48, h * 0.48, w * 0.58, "rgba(243, 186, 146, 0.62)"],
    [w * 0.16, h * 0.78, w * 0.4, "rgba(201, 168, 76, 0.28)"],
    [w * 0.8, h * 0.74, w * 0.34, "rgba(232, 168, 124, 0.48)"],
    [w * 0.55, h * 0.88, w * 0.3, "rgba(176, 92, 58, 0.16)"],
  ];
  for (const [x, y, radius, color] of blooms) {
    const wash = ctx.createRadialGradient(x, y, 8, x, y, radius);
    wash.addColorStop(0, color);
    wash.addColorStop(1, "rgba(246, 239, 226, 0)");
    ctx.fillStyle = wash;
    ctx.beginPath();
    ctx.arc(x, y, radius, 0, Math.PI * 2);
    ctx.fill();
  }
  const burn = ctx.createRadialGradient(w / 2, h / 2, h * 0.22, w / 2, h / 2, h * 0.72);
  burn.addColorStop(0, "rgba(0,0,0,0)");
  burn.addColorStop(1, "rgba(92, 48, 22, 0.22)");
  ctx.fillStyle = burn;
  ctx.fillRect(0, 0, w, h);
  ctx.strokeStyle = "#7b1f2e";
  ctx.lineWidth = 16;
  ctx.strokeRect(26, 26, w - 52, h - 52);
  ctx.strokeStyle = "#e7b089";
  ctx.lineWidth = 7;
  ctx.strokeRect(46, 46, w - 92, h - 92);
  ctx.strokeStyle = "#c9a84c";
  ctx.lineWidth = 3;
  ctx.strokeRect(60, 60, w - 120, h - 120);
  const title = (input.title || "विषय").trim();
  let size = 86;
  ctx.textAlign = "center";
  ctx.textBaseline = "top";
  let rows: string[] = [];
  while (size >= 32) {
    ctx.font = `400 ${size}px "Yatra One", "Noto Sans Devanagari", serif`;
    rows = coverLines(ctx, title, w - 170);
    if (rows.length * size * 1.16 < h * 0.42) break;
    size -= 2;
  }
  const block = rows.length * size * 1.16;
  let y = Math.max(h * 0.22, h * 0.4 - block / 2);
  ctx.fillStyle = "#6d1826";
  ctx.shadowColor = "rgba(255, 236, 214, 0.85)";
  ctx.shadowBlur = 8;
  for (const row of rows) {
    ctx.fillText(row, w / 2, y);
    y += size * 1.16;
  }
  ctx.shadowBlur = 0;
  y += 16;
  ctx.strokeStyle = "#7b1f2e";
  ctx.lineWidth = 2;
  ctx.beginPath();
  ctx.moveTo(w / 2 - 110, y);
  ctx.lineTo(w / 2 + 110, y);
  ctx.stroke();
  const note = (input.body || "").trim();
  if (note && note !== title) {
    ctx.font = "600 34px 'Noto Sans Devanagari', sans-serif";
    ctx.fillStyle = "#4a2c0a";
    const noteRows = coverLines(ctx, note, w - 180).slice(0, 7);
    y += 28;
    for (const row of noteRows) {
      ctx.fillText(row, w / 2, y);
      y += 46;
    }
  }
  ctx.font = "700 28px 'Noto Sans Devanagari', sans-serif";
  ctx.fillStyle = "#7b1f2e";
  ctx.fillText("ग्रंथ प्रबंधन", w / 2, h - 120);
  await onPreview?.(canvas);
  try {
    const jpg = await canvasJpeg(canvas, 0.9);
    const image = await doc.embedJpg(jpg);
    const page = doc.addPage([pageW, pageH]);
    page.drawImage(image, { x: 0, y: 0, width: pageW, height: pageH });
  } catch {
    const page = doc.addPage([pageW, pageH]);
    page.drawRectangle({ x: 0, y: 0, width: pageW, height: pageH, color: rgb(0.965, 0.937, 0.886) });
  }
}

function coverLines(ctx: CanvasRenderingContext2D, text: string, max: number) {
  const clean = text.replace(/\s+/g, " ").trim();
  if (!clean) return [];
  const out: string[] = [];
  let line = "";
  for (const word of clean.split(" ")) {
    const next = line ? `${line} ${word}` : word;
    if (ctx.measureText(next).width <= max) {
      line = next;
      continue;
    }
    if (line) out.push(line);
    if (ctx.measureText(word).width <= max) {
      line = word;
      continue;
    }
    line = "";
    for (const ch of Array.from(word)) {
      const trial = line + ch;
      if (line && ctx.measureText(trial).width > max) {
        out.push(line);
        line = ch;
      } else line = trial;
    }
  }
  if (line) out.push(line);
  return out;
}

async function fullCaption(kit: BuildKit, text: string, widthPt: number, size: number, color: string, weight: number) {
  const clean = text.trim();
  if (!clean) return null;
  return captionFor(kit, [{ text: clean, size, color, weight }], widthPt);
}

type BuildKit = Embedder & { captionJobs: Map<string, Promise<Caption | null>> };

function captionKey(lines: LineSpec[], widthPt: number) {
  return `${widthPt}|${lines.map((line) => `${line.size}/${line.weight}/${line.color}/${line.text}`).join("\n")}`;
}

/** Same header/footer text (granth covers repeat in multi-topic PDFs) is drawn and embedded once. */
function captionFor(kit: BuildKit, lines: LineSpec[], widthPt: number) {
  const key = captionKey(lines, widthPt);
  let job = kit.captionJobs.get(key);
  if (!job) {
    job = makeCaption(lines, widthPt, PAPER);
    kit.captionJobs.set(key, job);
  }
  return job.then((caption) => (caption ? { caption, key } : null));
}

async function wrappedLines(text: string, widthPt: number, size: number, weight: number): Promise<string[]> {
  const clean = text.trim();
  if (!clean) return [];
  await ensureFonts();
  const measure = measurer();
  if (!measure) return [clean];
  measure.font = `${weight} ${size * CAPTION_SCALE}px ${FONT_STACK}`;
  return wrapText(measure, clean, Math.max(80, Math.round(widthPt * CAPTION_SCALE)) - 56);
}

function chunkLines(lines: string[], size: number, maxHeight: number): string[][] {
  const step = size * 1.62;
  const pages: string[][] = [];
  let current: string[] = [];
  let used = 12;
  for (const line of lines) {
    if (current.length && used + step > maxHeight) {
      pages.push(current);
      current = [];
      used = 12;
    }
    current.push(line);
    used += step;
  }
  if (current.length) pages.push(current);
  return pages.length ? pages : [[]];
}

type Placed = { caption: Caption; key: string } | null;
type PagePicture = { shot: Shot | null; key: string; missing: boolean };

async function paintFilled(kit: BuildKit, copy: { header: string; footer: string }, picture: PagePicture) {
  const shot = picture.shot;
  const hasPicture = Boolean(shot) || picture.missing;
  const landscape = Boolean(shot && shot.w > shot.h * 1.02);
  const pageW = landscape ? 841.89 : 595.28;
  const pageH = landscape ? 595.28 : 841.89;
  const width = pageW - 16;
  const band = 20;
  let headerSize = landscape ? 16 : 17;
  let footerSize = landscape ? 14 : 15;
  const minImage = hasPicture ? (landscape ? 140 : 190) : 0;
  let header = await fullCaption(kit, copy.header, width, headerSize, "#7b1f2e", 700);
  let footer = await fullCaption(kit, copy.footer, width, footerSize, "#4a2c0a", 600);
  while (headerSize > 13 && (header?.caption.h ?? 0) + (footer?.caption.h ?? 0) + minImage + band + 12 > pageH) {
    headerSize -= 1;
    footerSize = Math.max(13, footerSize - 1);
    header = await fullCaption(kit, copy.header, width, headerSize, "#7b1f2e", 700);
    footer = await fullCaption(kit, copy.footer, width, footerSize, "#4a2c0a", 600);
  }

  const drawPage = async (head: Placed, foot: Placed, withPicture: boolean) => {
    const page = kit.doc.addPage([pageW, pageH]);
    page.drawRectangle({ x: 0, y: 0, width: pageW, height: pageH, color: rgb(1, 0.992, 0.969) });
    const headerH = head?.caption.h ?? 0;
    const footerH = foot?.caption.h ?? 0;
    if (head) {
      const image = await embedCaption(kit, head.caption, head.key);
      page.drawImage(image, { x: 8, y: pageH - headerH - 4, width, height: headerH });
    }
    if (foot) {
      const image = await embedCaption(kit, foot.caption, foot.key);
      page.drawImage(image, { x: 8, y: band, width, height: footerH });
    }
    if (withPicture) {
      const top = headerH + 8;
      const bottom = footerH + band + 4;
      const boxH = Math.max(48, pageH - top - bottom);
      if (shot) {
        const fit = contain(width, boxH, shot.w, shot.h);
        try {
          const embedded = await embedShot(kit, shot, picture.key);
          drawBordered(page, embedded, 8 + (width - fit.w) / 2, bottom + (boxH - fit.h) / 2, fit.w, fit.h);
        } catch {
          await drawMissing(kit, page, 8 + width * 0.1, bottom + boxH * 0.2, width * 0.8, boxH * 0.6);
        }
      } else {
        const w = Math.min(width * 0.8, 420);
        const h = Math.min(boxH * 0.6, 300);
        await drawMissing(kit, page, 8 + (width - w) / 2, bottom + (boxH - h) / 2, w, h);
      }
    }
  };

  if ((header?.caption.h ?? 0) + (footer?.caption.h ?? 0) + minImage + band + 12 <= pageH) {
    await drawPage(header, footer, hasPicture);
    return;
  }

  const headerLines = await wrappedLines(copy.header, width, headerSize, 700);
  const footerLines = await wrappedLines(copy.footer, width, footerSize, 600);
  const headerRoom = hasPicture ? Math.max(80, pageH * 0.24) : pageH - band - 16;
  const headerPages = chunkLines(headerLines, headerSize, headerRoom);
  const firstHeader = headerPages[0] ?? [];
  const headerCaption = firstHeader.length
    ? await captionFor(kit, firstHeader.map((text) => ({ text, size: headerSize, color: "#7b1f2e", weight: 700 })), width)
    : null;
  const footerRoom = Math.max(70, pageH - (headerCaption?.caption.h ?? 0) - minImage - band - 12);
  const footerPages = chunkLines(footerLines, footerSize, footerRoom);
  const firstFooter = footerPages[0] ?? [];
  const footerCaption = firstFooter.length
    ? await captionFor(kit, firstFooter.map((text) => ({ text, size: footerSize, color: "#4a2c0a", weight: 600 })), width)
    : null;
  await drawPage(headerCaption, footerCaption, hasPicture);
  const rest = [
    ...headerLines.slice(firstHeader.length).map((text) => ({ text, size: headerSize, color: "#7b1f2e", weight: 700 })),
    ...footerLines.slice(firstFooter.length).map((text) => ({ text, size: footerSize, color: "#4a2c0a", weight: 600 })),
  ];
  const room = pageH - band - 24;
  let index = 0;
  while (index < rest.length) {
    const batch: LineSpec[] = [];
    let used = 12;
    while (index < rest.length) {
      const row = rest[index];
      if (!row) break;
      const step = row.size * 1.62;
      if (batch.length && used + step > room) break;
      batch.push(row);
      used += step;
      index += 1;
    }
    await drawPage(await captionFor(kit, batch, width), null, false);
  }
}

async function paintOriginal(kit: BuildKit, input: BookPage, picture: PagePicture) {
  const shot = picture.shot;
  if (!shot) {
    if (!picture.missing) return;
    // Keep page order and say what is missing instead of silently dropping the page.
    const page = kit.doc.addPage([595.28, 841.89]);
    page.drawRectangle({ x: 0, y: 0, width: 595.28, height: 841.89, color: rgb(1, 1, 1) });
    const title = await captionFor(kit, [{ text: input.title || "प्रमाण", size: 16, color: "#7b1f2e", weight: 700 }], 579.28);
    if (title) page.drawImage(await embedCaption(kit, title.caption, title.key), { x: 8, y: 841.89 - title.caption.h - 8, width: 579.28, height: title.caption.h });
    await drawMissing(kit, page, 88, 300, 420, 260);
    return;
  }
  const wide = shot.w > shot.h * 1.05;
  const pageW = wide ? 841.89 : 595.28;
  const pageH = wide ? 595.28 : 841.89;
  const margin = 10;
  const fit = contain(pageW - margin * 2, pageH - margin * 2, shot.w, shot.h);
  const page = kit.doc.addPage([pageW, pageH]);
  page.drawRectangle({ x: 0, y: 0, width: pageW, height: pageH, color: rgb(1, 1, 1) });
  const photo = await embedShot(kit, shot, picture.key);
  page.drawImage(photo, { x: (pageW - fit.w) / 2, y: (pageH - fit.h) / 2, width: fit.w, height: fit.h });
}

async function shotCanvas(shot: Shot) {
  const img = await createImageBitmap(new Blob([shot.bytes as BlobPart], { type: shot.kind === "png" ? "image/png" : "image/jpeg" }));
  const max = 900;
  const scale = Math.min(1, max / Math.max(img.width, img.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(img.width * scale));
  canvas.height = Math.max(1, Math.round(img.height * scale));
  canvas.getContext("2d")?.drawImage(img, 0, 0, canvas.width, canvas.height);
  img.close();
  return canvas;
}

function styleOf(style: PdfStyle): "fill90" | "original" {
  return style === "original" ? "original" : "fill90";
}

function stampAt(page: PDFPage, number: number, font: PDFFont) {
  const label = String(number);
  const size = 11;
  const width = font.widthOfTextAtSize(label, size);
  const box = page.getSize();
  page.drawRectangle({ x: box.width - width - 16, y: 6, width: width + 10, height: 16, color: rgb(1, 0.984, 0.953), opacity: 0.92 });
  page.drawText(label, { x: box.width - width - 11, y: 9, size, font, color: rgb(0.482, 0.122, 0.18) });
}

async function previewJpeg(canvas: HTMLCanvasElement): Promise<Blob | null> {
  const max = 720;
  const scale = Math.min(1, max / Math.max(canvas.width, canvas.height));
  const out = document.createElement("canvas");
  out.width = Math.max(1, Math.round(canvas.width * scale));
  out.height = Math.max(1, Math.round(canvas.height * scale));
  const ctx = out.getContext("2d");
  if (!ctx) return null;
  ctx.fillStyle = PAPER;
  ctx.fillRect(0, 0, out.width, out.height);
  ctx.drawImage(canvas, 0, 0, out.width, out.height);
  try {
    return new Blob([(await canvasJpeg(out, 0.82)) as BlobPart], { type: "image/jpeg" });
  } catch {
    return null;
  }
}

/**
 * Build the PDF as a stream: pictures are read (IndexedDB first), downscaled in
 * Web Workers and assembled page by page in order while later pictures are
 * still loading. A picture that fails gets a placeholder instead of failing the
 * whole document.
 */
export async function buildBookPdf(pages: BookPage[], style: PdfStyle = "fill90", options: PdfBuildOptions = {}): Promise<Blob> {
  const cancelled = () => Boolean(options.isCancelled?.());
  const doc = await PDFDocument.create();
  doc.setCreator("ग्रंथ प्रबंधन");
  doc.setProducer("ग्रंथ प्रबंधन");
  const kit: BuildKit = { doc, images: new Map(), captions: new Map(), captionJobs: new Map() };
  const fontPromise = doc.embedFont(StandardFonts.Helvetica);
  const source = pages.length ? pages : [{ title: "कोई प्रमाण नहीं" }];
  const mode = styleOf(style);
  const workers = shotPool();
  const fetchSlot = limiter(6);
  const loads = new Map<string, Promise<Shot | null>>();
  let missing = 0;

  const loadShot = (path: string) => {
    const known = loads.get(path);
    if (known) return known;
    const job = fetchSlot(async () => {
      if (cancelled()) return null;
      const hit = cachedShot(path);
      if (hit) return hit;
      let blob: Blob | null = null;
      try {
        blob = (await options.loadImage?.(path)) ?? null;
      } catch {
        blob = null;
      }
      if (!blob) return null;
      const shot = await workers.prepare(blob).catch(() => null);
      if (shot) rememberShot(path, shot);
      return shot;
    });
    loads.set(path, job);
    return job;
  };

  // Kick off every picture now (limited to 6 in flight, in page order) so the
  // network/decoders stay busy while earlier pages are being assembled.
  const pictures: Array<Promise<PagePicture>> = source.map((input) => {
    const path = input.topicCover ? null : input.imagePath;
    if (!path) return Promise.resolve({ shot: null, key: "", missing: false });
    return loadShot(path).then((shot) => ({ shot, key: path, missing: !shot }));
  });
  for (const picture of pictures) picture.catch(() => undefined);

  const [font] = await Promise.all([fontPromise, ensureFonts()]);
  for (let index = 0; index < source.length; index += 1) {
    if (cancelled()) throw new DOMException("cancelled", "AbortError");
    const input = source[index] ?? { title: "ग्रंथ" };
    const before = doc.getPageCount();
    const picture = await (pictures[index] ?? Promise.resolve({ shot: null, key: "", missing: false }));
    if (picture.missing) missing += 1;
    try {
      if (input.topicCover) {
        await paintTopicCover(doc, input, index === 0 && options.onPreview ? async (canvas) => {
          const blob = await previewJpeg(canvas);
          if (blob) options.onPreview?.(blob);
        } : undefined);
      } else if (mode === "original") {
        await paintOriginal(kit, input, picture);
      } else {
        await paintFilled(kit, pageCopy(input), picture);
      }
      if (index === 0 && options.onPreview && picture.shot && !input.topicCover) {
        void shotCanvas(picture.shot)
          .then(previewJpeg)
          .then((blob) => {
            if (blob) options.onPreview?.(blob);
          })
          .catch(() => undefined);
      }
    } catch (error) {
      if (cancelled() || (error instanceof DOMException && error.name === "AbortError")) throw error;
      const page = doc.addPage([595.28, 841.89]);
      page.drawRectangle({ x: 0, y: 0, width: 595.28, height: 841.89, color: rgb(1, 0.984, 0.953) });
    }
    if (mode !== "original" || input.topicCover) {
      const made = doc.getPages();
      for (let pageIndex = before; pageIndex < made.length; pageIndex += 1) {
        const page = made[pageIndex];
        if (page) stampAt(page, pageIndex + 1, font);
      }
    }
    options.onPage?.(index + 1, source.length);
    // Pictures already decoded: keep the UI responsive between pages.
    if (index % 2 === 1) await yieldToUi();
  }
  if (cancelled()) throw new DOMException("cancelled", "AbortError");
  if (doc.getPageCount() === 0) doc.addPage([595.28, 841.89]);
  options.onMissing?.(missing);
  // Object streams only shrink the (tiny) page dictionaries but cost a full extra pass.
  const bytes = await doc.save({ useObjectStreams: false, addDefaultPage: false });
  if (bytes.length < 64 || bytes[0] !== 0x25 || bytes[1] !== 0x50 || bytes[2] !== 0x44 || bytes[3] !== 0x46) {
    throw new Error("PDF खाली रह गई");
  }
  return new Blob([bytes as BlobPart], { type: "application/pdf" });
}
