import "regenerator-runtime/runtime";
import { PDFDocument, rgb, StandardFonts, type PDFDocument as PdfDoc, type PDFFont, type PDFImage, type PDFPage } from "pdf-lib";
import type { PdfStyle } from "@/lib/granth/pdf-style";

export type { PdfStyle } from "@/lib/granth/pdf-style";

export type CardPdfInput = {
  title: string;
  subtitle?: string;
  body?: string;
  meta?: string;
  imageBlob?: Blob | null;
  fileName: string;
};

export type BookPage = {
  title: string;
  subtitle?: string;
  body?: string;
  meta?: string;
  imageBlob?: Blob | null;
  cover?: boolean;
  topicCover?: boolean;
};

export type PdfBuildOptions = {
  onPage?: (done: number, total: number) => void;
  onPreview?: (blob: Blob) => void;
  isCancelled?: () => boolean;
};

type Shot = { bytes: Uint8Array; w: number; h: number; kind: "jpg" | "png" };
type Caption = { bytes: Uint8Array; w: number; h: number };
type LineSpec = { text: string; size: number; color: string; weight: number };

const SCALE = 2;
let fontsReady: Promise<void> | null = null;

function ensureFonts() {
  if (!fontsReady) {
    fontsReady = (async () => {
      await document.fonts.load("700 32px 'Noto Sans Devanagari'");
      await document.fonts.load("600 28px 'Noto Sans Devanagari'");
      await document.fonts.load("500 22px 'Noto Sans Devanagari'");
      await document.fonts.load("400 72px 'Yatra One'");
      await document.fonts.ready;
    })();
  }
  return fontsReady;
}

function imageSize(bytes: Uint8Array): { w: number; h: number; kind: "jpg" | "png" } | null {
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

async function canvasBlob(canvas: HTMLCanvasElement, type: string, quality?: number): Promise<Uint8Array> {
  const mime = type.includes("png") ? "image/png" : "image/jpeg";
  const q = quality ?? 0.92;
  try {
    const blob = await new Promise<Blob | null>((resolve) => {
      try {
        canvas.toBlob((value) => resolve(value), mime, q);
      } catch {
        resolve(null);
      }
    });
    if (blob && blob.size > 32) return new Uint8Array(await blob.arrayBuffer());
  } catch {
    /* WebView toBlob can return null */
  }
  const data = canvas.toDataURL(mime, q);
  const binary = atob(data.slice(data.indexOf(",") + 1));
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes;
}

async function readShot(blob: Blob | null | undefined): Promise<Shot | null> {
  if (!blob || blob.size < 32) return null;
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const parsed = imageSize(bytes);
  if (parsed) return fitShot({ bytes, ...parsed });
  try {
    const bitmap = await createImageBitmap(blob);
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, bitmap.width);
    canvas.height = Math.max(1, bitmap.height);
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      bitmap.close();
      return null;
    }
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(bitmap, 0, 0);
    const shot = await fitShot({
      bytes: await canvasBlob(canvas, "image/jpeg", 0.9),
      w: bitmap.width,
      h: bitmap.height,
      kind: "jpg",
    });
    bitmap.close();
    return shot;
  } catch {
    return null;
  }
}

async function fitShot(shot: Shot): Promise<Shot> {
  const maxEdge = 1800;
  if (shot.kind === "jpg" && shot.w <= maxEdge && shot.h <= maxEdge && shot.bytes.length < 1_100_000) return shot;
  try {
    const bitmap = await createImageBitmap(new Blob([shot.bytes]));
    const scale = Math.min(1, maxEdge / Math.max(bitmap.width, bitmap.height));
    const canvas = document.createElement("canvas");
    canvas.width = Math.max(1, Math.round(bitmap.width * scale));
    canvas.height = Math.max(1, Math.round(bitmap.height * scale));
    const ctx = canvas.getContext("2d");
    if (!ctx) {
      bitmap.close();
      return shot;
    }
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
    bitmap.close();
    return {
      bytes: await canvasBlob(canvas, "image/jpeg", 0.9),
      w: canvas.width,
      h: canvas.height,
      kind: "jpg",
    };
  } catch {
    return shot;
  }
}

function breakWord(ctx: CanvasRenderingContext2D, word: string, maxWidth: number): string[] {
  if (ctx.measureText(word).width <= maxWidth) return [word];
  const parts: string[] = [];
  let chunk = "";
  for (const ch of word) {
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

async function makeCaption(lines: LineSpec[], widthPt: number, bg: string): Promise<Caption | null> {
  const usable = lines
    .map((line) => ({ ...line, text: line.text.replace(/[ \t]+/g, " ").trim() }))
    .filter((line) => line.text);
  if (!usable.length || widthPt < 24) return null;
  await ensureFonts();
  const scale = 2;
  const widthPx = Math.max(80, Math.round(widthPt * scale));
  const measure = document.createElement("canvas").getContext("2d");
  if (!measure) return null;
  const rows: LineSpec[] = [];
  for (const line of usable) {
    measure.font = `${line.weight} ${line.size * scale}px "Noto Sans Devanagari", sans-serif`;
    let wrapped = wrapText(measure, line.text, widthPx - 28 * scale);
    for (const text of wrapped) rows.push({ text, size: line.size, color: line.color, weight: line.weight });
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
    ctx.font = `${row.weight} ${row.size * scale}px "Noto Sans Devanagari", sans-serif`;
    ctx.fillStyle = row.color;
    ctx.fillText(row.text, 12 * scale, y);
    y += lineBox(row);
  }
  return { bytes: await canvasBlob(canvas, "image/png"), w: widthPt, h: canvas.height / scale };
}

function contain(boxW: number, boxH: number, imgW: number, imgH: number) {
  const scale = Math.min(boxW / imgW, boxH / imgH);
  return { w: imgW * scale, h: imgH * scale };
}

async function embedShot(doc: PdfDoc, shot: Shot): Promise<PDFImage> {
  try {
    if (shot.kind === "png") return await doc.embedPng(shot.bytes);
    return await doc.embedJpg(shot.bytes);
  } catch {
    const bitmap = await createImageBitmap(new Blob([shot.bytes]));
    const canvas = document.createElement("canvas");
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    const ctx = canvas.getContext("2d");
    if (!ctx) throw new Error("canvas");
    ctx.fillStyle = "#ffffff";
    ctx.fillRect(0, 0, canvas.width, canvas.height);
    ctx.drawImage(bitmap, 0, 0);
    bitmap.close();
    return doc.embedJpg(await canvasBlob(canvas, "image/jpeg", 1));
  }
}

function drawBordered(page: PDFPage, image: PDFImage, x: number, y: number, w: number, h: number) {
  const border = 1;
  page.drawRectangle({
    x: x - border,
    y: y - border,
    width: w + border * 2,
    height: h + border * 2,
    color: rgb(0, 0, 0),
  });
  page.drawImage(image, { x, y, width: w, height: h });
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
    const png = await canvasBlob(canvas, "image/png");
    const image = await doc.embedPng(png);
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

async function fullCaption(text: string, widthPt: number, size: number, color: string, weight: number): Promise<Caption | null> {
  const clean = text.trim();
  if (!clean) return null;
  return makeCaption([{ text: clean, size, color, weight }], widthPt, "#fffdf7");
}

async function wrappedLines(text: string, widthPt: number, size: number, weight: number): Promise<string[]> {
  const clean = text.trim();
  if (!clean) return [];
  await ensureFonts();
  const scale = 2;
  const measure = document.createElement("canvas").getContext("2d");
  if (!measure) return [clean];
  measure.font = `${weight} ${size * scale}px "Noto Sans Devanagari", sans-serif`;
  return wrapText(measure, clean, Math.max(80, Math.round(widthPt * scale) - 56));
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

async function paintFilled(
  doc: PdfDoc,
  copy: { header: string; footer: string },
  shot: Shot | null,
  onPreview?: (canvas: HTMLCanvasElement) => void | Promise<void>,
) {
  const landscape = Boolean(shot && shot.w > shot.h * 1.02);
  const pageW = landscape ? 841.89 : 595.28;
  const pageH = landscape ? 595.28 : 841.89;
  const width = pageW - 16;
  const band = 20;
  let headerSize = landscape ? 16 : 17;
  let footerSize = landscape ? 14 : 15;
  const minImage = shot ? (landscape ? 140 : 190) : 0;
  let header = await fullCaption(copy.header, width, headerSize, "#7b1f2e", 700);
  let footer = await fullCaption(copy.footer, width, footerSize, "#4a2c0a", 600);
  while (headerSize > 13 && (header?.h ?? 0) + (footer?.h ?? 0) + minImage + band + 12 > pageH) {
    headerSize -= 1;
    footerSize = Math.max(13, footerSize - 1);
    header = await fullCaption(copy.header, width, headerSize, "#7b1f2e", 700);
    footer = await fullCaption(copy.footer, width, footerSize, "#4a2c0a", 600);
  }

  const drawPage = async (head: Caption | null, foot: Caption | null, photo: Shot | null) => {
    const page = doc.addPage([pageW, pageH]);
    page.drawRectangle({ x: 0, y: 0, width: pageW, height: pageH, color: rgb(1, 0.992, 0.969) });
    const headerH = head?.h ?? 0;
    const footerH = foot?.h ?? 0;
    if (head) {
      const image = await doc.embedPng(head.bytes);
      page.drawImage(image, { x: 8, y: pageH - headerH - 4, width, height: headerH });
    }
    if (foot) {
      const image = await doc.embedPng(foot.bytes);
      page.drawImage(image, { x: 8, y: band, width, height: footerH });
    }
    if (photo) {
      const top = headerH + 8;
      const bottom = footerH + band + 4;
      const boxH = Math.max(48, pageH - top - bottom);
      const fit = contain(width, boxH, photo.w, photo.h);
      const embedded = await embedShot(doc, photo);
      drawBordered(page, embedded, 8 + (width - fit.w) / 2, bottom + (boxH - fit.h) / 2, fit.w, fit.h);
    }
  };

  if ((header?.h ?? 0) + (footer?.h ?? 0) + minImage + band + 12 <= pageH) {
    await drawPage(header, footer, shot);
    if (onPreview && shot) {
      try {
        await onPreview(await shotCanvas(shot));
      } catch {
        /* cover is optional */
      }
    }
    return;
  }

  const headerLines = await wrappedLines(copy.header, width, headerSize, 700);
  const footerLines = await wrappedLines(copy.footer, width, footerSize, 600);
  const headerRoom = shot ? Math.max(80, pageH * 0.24) : pageH - band - 16;
  const headerPages = chunkLines(headerLines, headerSize, headerRoom);
  const firstHeader = headerPages[0] ?? [];
  const headerCaption = firstHeader.length
    ? await makeCaption(firstHeader.map((text) => ({ text, size: headerSize, color: "#7b1f2e", weight: 700 })), width, "#fffdf7")
    : null;
  const footerRoom = Math.max(70, pageH - (headerCaption?.h ?? 0) - (shot ? minImage : 0) - band - 12);
  const footerPages = chunkLines(footerLines, footerSize, footerRoom);
  const firstFooter = footerPages[0] ?? [];
  const footerCaption = firstFooter.length
    ? await makeCaption(firstFooter.map((text) => ({ text, size: footerSize, color: "#4a2c0a", weight: 600 })), width, "#fffdf7")
    : null;
  await drawPage(headerCaption, footerCaption, shot);
  if (onPreview && shot) {
    try {
      await onPreview(await shotCanvas(shot));
    } catch {
      /* cover is optional */
    }
  }
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
    await drawPage(await makeCaption(batch, width, "#fffdf7"), null, null);
  }
}

async function paintPage(
  doc: PdfDoc,
  input: BookPage,
  shot: Shot | null,
  style: "fill90" | "original",
  onPreview?: (canvas: HTMLCanvasElement) => void | Promise<void>,
) {
  const copy = pageCopy(input);
  if (input.topicCover) {
    await paintTopicCover(doc, input, onPreview);
    return;
  }
  if (style === "original") {
    if (!shot) return;
    const wide = shot.w > shot.h * 1.05;
    const pageW = wide ? 841.89 : 595.28;
    const pageH = wide ? 595.28 : 841.89;
    const margin = 10;
    const fit = contain(pageW - margin * 2, pageH - margin * 2, shot.w, shot.h);
    const page = doc.addPage([pageW, pageH]);
    page.drawRectangle({ x: 0, y: 0, width: pageW, height: pageH, color: rgb(1, 1, 1) });
    const photo = await embedShot(doc, shot);
    page.drawImage(photo, {
      x: (pageW - fit.w) / 2,
      y: (pageH - fit.h) / 2,
      width: fit.w,
      height: fit.h,
    });
    if (onPreview) {
      try {
        await onPreview(await shotCanvas(shot));
      } catch {
        /* cover is optional */
      }
    }
    return;
  }
  await paintFilled(doc, copy, shot, onPreview);
}

async function shotCanvas(shot: Shot) {
  const img = await createImageBitmap(new Blob([shot.bytes], { type: shot.kind === "png" ? "image/png" : "image/jpeg" }));
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
  page.drawRectangle({
    x: box.width - width - 16,
    y: 6,
    width: width + 10,
    height: 16,
    color: rgb(1, 0.984, 0.953),
    opacity: 0.92,
  });
  page.drawText(label, {
    x: box.width - width - 11,
    y: 9,
    size,
    font,
    color: rgb(0.482, 0.122, 0.18),
  });
}

async function previewJpeg(canvas: HTMLCanvasElement): Promise<Blob | null> {
  const max = 720;
  const scale = Math.min(1, max / Math.max(canvas.width, canvas.height));
  const out = document.createElement("canvas");
  out.width = Math.max(1, Math.round(canvas.width * scale));
  out.height = Math.max(1, Math.round(canvas.height * scale));
  const ctx = out.getContext("2d");
  if (!ctx) return null;
  ctx.fillStyle = "#fffdf7";
  ctx.fillRect(0, 0, out.width, out.height);
  ctx.drawImage(canvas, 0, 0, out.width, out.height);
  try {
    return new Blob([await canvasBlob(out, "image/jpeg", 0.82)], { type: "image/jpeg" });
  } catch {
    return null;
  }
}

export async function buildBookPdf(pages: BookPage[], style: PdfStyle = "fill90", options: PdfBuildOptions = {}): Promise<Blob> {
  const doc = await PDFDocument.create();
  const fontPromise = doc.embedFont(StandardFonts.Helvetica);
  const fontsPromise = ensureFonts();
  const source = pages.length ? pages : [{ title: "कोई प्रमाण नहीं" }];
  const mode = styleOf(style);
  const font = await Promise.all([fontsPromise, fontPromise]).then(() => fontPromise);
  const shots: Array<Shot | null | undefined> = new Array(source.length);
  let cursor = 0;
  let painted = 0;
  let painting = false;
  const paintReady = async () => {
    if (painting) return;
    painting = true;
    try {
      while (painted < source.length && shots[painted] !== undefined) {
        if (options.isCancelled?.()) throw new DOMException("cancelled", "AbortError");
        const index = painted;
        painted += 1;
        const input = source[index] ?? { title: "ग्रंथ" };
        const before = doc.getPageCount();
        const shot = shots[index] ?? null;
        const preview = index === 0 && options.onPreview
          ? async (canvas: HTMLCanvasElement) => {
              const blob = await previewJpeg(canvas);
              if (blob) options.onPreview?.(blob);
            }
          : undefined;
        try {
          await paintPage(doc, input, shot, mode, preview);
        } catch (error) {
          if (options.isCancelled?.() || (error instanceof DOMException && error.name === "AbortError")) throw error;
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
      }
    } finally {
      painting = false;
    }
    if (painted < source.length && shots[painted] !== undefined) await paintReady();
  };
  const readers = Array.from({ length: Math.min(6, source.length) }, async () => {
    while (cursor < source.length) {
      const index = cursor;
      cursor += 1;
      if (options.isCancelled?.()) return;
      shots[index] = (await readShot(source[index]?.imageBlob)) ?? null;
      if (index === painted) await paintReady();
    }
  });
  await Promise.all(readers);
  await paintReady();
  if (options.isCancelled?.()) throw new DOMException("cancelled", "AbortError");
  if (doc.getPageCount() === 0) doc.addPage([595.28, 841.89]);
  const bytes = await doc.save();
  if (bytes.length < 64 || bytes[0] !== 0x25 || bytes[1] !== 0x50 || bytes[2] !== 0x44 || bytes[3] !== 0x46) {
    throw new Error("PDF खाली रह गई");
  }
  return new Blob([bytes], { type: "application/pdf" });
}

export async function buildCardPdf(input: CardPdfInput, style: PdfStyle = "fill90", options: PdfBuildOptions = {}): Promise<Blob> {
  return buildBookPdf([input], style, options);
}
