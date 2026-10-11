import { useSyncExternalStore } from "react";
import { noteEvent } from "./metrics";

export type PdfPhase = "queue" | "images" | "pages" | "save" | "done" | "error" | "cancelled";

export type PdfTask = {
  id: string;
  title: string;
  fileName: string;
  galleryId: string;
  topic: string;
  granth: string;
  text: string;
  granthId?: string;
  phase: PdfPhase;
  done: number;
  total: number;
  percent: number;
  etaMs: number | null;
  startedAt: number;
  finishedAt?: number;
  error?: string;
  blob?: Blob;
  preview?: Blob;
  size?: number;
};

type RunContext = {
  report: (phase: PdfPhase, done: number, total: number) => void;
  isCancelled: () => boolean;
  setPreview: (blob: Blob | undefined) => void;
};

type Queued = {
  id: string;
  cancelled: boolean;
  retried: boolean;
  run: (ctx: RunContext) => Promise<Blob>;
};

const OFFLINE_KEY = "granth-offline-ids";
let tasks: PdfTask[] = [];
let queue: Queued[] = [];
let pumping = false;
const listeners = new Set<() => void>();
const offlineListeners = new Set<() => void>();
let readyListener: ((task: PdfTask) => void) | null = null;

function loadOffline(): Set<string> {
  try {
    const raw = JSON.parse(localStorage.getItem(OFFLINE_KEY) || "[]") as unknown;
    return new Set(Array.isArray(raw) ? raw.map(String) : []);
  } catch {
    return new Set();
  }
}

let offlineIds = loadOffline();

function emitTasks() {
  for (const listener of listeners) listener();
}

function emitOffline() {
  for (const listener of offlineListeners) listener();
}

export function subscribePdf(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

export function getPdfTasks() {
  return tasks;
}

export function usePdfTasks() {
  return useSyncExternalStore(subscribePdf, getPdfTasks, getPdfTasks);
}

export function listenPdfReady(listener: (task: PdfTask) => void) {
  readyListener = listener;
  return () => {
    if (readyListener === listener) readyListener = null;
  };
}

export function useOfflineIds() {
  return useSyncExternalStore(
    (listener) => {
      offlineListeners.add(listener);
      return () => offlineListeners.delete(listener);
    },
    () => offlineIds,
    () => offlineIds,
  );
}

export function markGranthsOffline(ids: string[]) {
  const next = new Set(offlineIds);
  let changed = false;
  for (const id of ids) {
    if (!id || next.has(id)) continue;
    next.add(id);
    changed = true;
  }
  if (!changed) return;
  offlineIds = next;
  try {
    localStorage.setItem(OFFLINE_KEY, JSON.stringify([...offlineIds]));
  } catch {
    /* ignore */
  }
  emitOffline();
}

function patch(id: string, next: Partial<PdfTask>) {
  tasks = tasks.map((task) => (task.id === id ? { ...task, ...next } : task));
  emitTasks();
}

let progressFloor = 0;

function percentFor(phase: PdfPhase, done: number, total: number) {
  if (phase === "done") return 100;
  if (phase === "save") return 99;
  const ratio = done / Math.max(1, total);
  const value = phase === "images" ? Math.round(ratio * 15) : Math.round(ratio * 99);
  progressFloor = Math.max(progressFloor, Math.min(99, value));
  return progressFloor;
}

function estimateEta(startedAt: number, percent: number) {
  if (percent < 4) return null;
  const elapsed = Date.now() - startedAt;
  if (elapsed < 500) return null;
  return Math.max(1000, ((100 - percent) / percent) * elapsed);
}

export function enqueuePdf(input: {
  title: string;
  fileName: string;
  galleryId: string;
  topic: string;
  granth: string;
  text: string;
  granthId?: string;
  run: (ctx: RunContext) => Promise<Blob>;
}) {
  const id = `pdf-${Date.now()}-${Math.random().toString(36).slice(2, 6)}`;
  const task: PdfTask = {
    id,
    title: input.title,
    fileName: input.fileName,
    galleryId: input.galleryId,
    topic: input.topic,
    granth: input.granth,
    text: input.text,
    granthId: input.granthId,
    phase: "queue",
    done: 0,
    total: 1,
    percent: 0,
    etaMs: null,
    startedAt: Date.now(),
  };
  tasks = [task, ...tasks].slice(0, 12);
  queue.push({ id, cancelled: false, retried: false, run: input.run });
  emitTasks();
  void pump();
  return id;
}

export function cancelPdf(id: string) {
  const item = queue.find((entry) => entry.id === id);
  if (item) item.cancelled = true;
  patch(id, { phase: "cancelled", etaMs: 0 });
}

export function dismissPdf(id: string) {
  cancelPdf(id);
  tasks = tasks.filter((task) => task.id !== id);
  emitTasks();
}

async function pump() {
  if (pumping) return;
  pumping = true;
  try {
    while (queue.length) {
      const next = queue[0];
      queue = queue.slice(1);
      if (!next || next.cancelled) continue;
      const startedAt = Date.now();
      progressFloor = 0;
      patch(next.id, { phase: "pages", startedAt, percent: 0, done: 0, total: 1 });
      try {
        const blob = await next.run({
          isCancelled: () => next.cancelled,
          setPreview: (preview) => {
            if (preview) patch(next.id, { preview });
          },
          report: (phase, done, total) => {
            if (next.cancelled) return;
            const percent = percentFor(phase, done, total);
            patch(next.id, { phase, done, total, percent, etaMs: estimateEta(startedAt, percent) });
          },
        });
        if (next.cancelled) {
          patch(next.id, { phase: "cancelled", etaMs: 0 });
          continue;
        }
        patch(next.id, { phase: "done", percent: 100, etaMs: 0, blob, size: blob.size, finishedAt: Date.now() });
        const saved = tasks.find((task) => task.id === next.id);
        if (saved) {
          readyListener?.(saved);
          noteEvent("pdf_download", saved.granthId || saved.id, saved.fileName);
        }
      } catch (error) {
        if (next.cancelled || (error instanceof DOMException && error.name === "AbortError")) {
          patch(next.id, { phase: "cancelled", etaMs: 0 });
        } else if (!next.retried) {
          next.retried = true;
          queue.unshift(next);
        } else {
          patch(next.id, {
            phase: "error",
            etaMs: 0,
            error: error instanceof Error ? error.message : "PDF नहीं बनी",
          });
        }
      }
    }
  } finally {
    pumping = false;
    if (queue.length) void pump();
  }
}

export function formatBytes(size: number) {
  if (size < 1024) return `${size} B`;
  if (size < 1024 * 1024) return `${(size / 1024).toFixed(1)} KB`;
  return `${(size / (1024 * 1024)).toFixed(1)} MB`;
}

export function formatClock(ms: number) {
  const seconds = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  if (!minutes) return `${seconds} सेकंड`;
  return `${minutes} मि ${rest} से`;
}

export function formatEta(ms: number | null, phase: PdfPhase) {
  if (phase === "done") return "पूरा हो गया";
  if (phase === "cancelled") return "रुक गया";
  if (phase === "error") return "रुका — त्रुटि";
  if (phase === "queue") return "कतार में";
  if (ms == null) return "समय गिना जा रहा है";
  const seconds = Math.max(1, Math.round(ms / 1000));
  if (seconds < 60) return `${seconds} सेकंड शेष`;
  const minutes = Math.floor(seconds / 60);
  const rest = seconds % 60;
  return `${minutes} मि ${rest} से शेष`;
}
