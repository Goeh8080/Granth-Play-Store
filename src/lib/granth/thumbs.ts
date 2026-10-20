/**
 * Display-sized copies of page photos for the lists.
 *
 * Upstream photos are ~1200×1800 (some 6000×5500). Showing them as 52px
 * thumbnails made the browser decode and rasterize full-size images while
 * scrolling, which was the main cost of the praman/granth lists on phones.
 * Here each picture is decoded once in a worker, downscaled to what the card
 * needs and kept as a small JPEG object URL (memory LRU, ~40 MB).
 */
import { shotPool } from "@/lib/granth/image-pool";

const LIMIT_BYTES = 40 * 1024 * 1024;
const QUALITY = 0.78;

type Entry = { url: string; bytes: number; refs: number };

const cache = new Map<string, Entry>();
const inflight = new Map<string, Promise<Entry | null>>();
let total = 0;

function evict() {
  if (total <= LIMIT_BYTES) return;
  for (const [key, entry] of cache) {
    if (total <= LIMIT_BYTES) break;
    if (entry.refs > 0) continue;
    URL.revokeObjectURL(entry.url);
    cache.delete(key);
    total -= entry.bytes;
  }
}

async function build(blob: Blob, maxEdge: number): Promise<Entry> {
  const shot = await shotPool()
    .prepare(blob, maxEdge, QUALITY)
    .catch(() => null);
  const out = shot ? new Blob([shot.bytes as BlobPart], { type: shot.kind === "png" ? "image/png" : "image/jpeg" }) : blob;
  return { url: URL.createObjectURL(out), bytes: out.size, refs: 0 };
}

/**
 * Object URL of `path` scaled to at most `maxEdge` px. Call the returned
 * release() when the image unmounts. `maxEdge` 0 = original blob.
 */
export async function sizedImage(
  path: string,
  maxEdge: number,
  load: () => Promise<Blob | null>,
): Promise<{ url: string; release: () => void } | null> {
  const key = `${maxEdge}:${path}`;
  let entry = cache.get(key) ?? null;
  if (entry) {
    // refresh LRU position
    cache.delete(key);
    cache.set(key, entry);
  } else {
    let job = inflight.get(key);
    if (!job) {
      job = (async () => {
        const blob = await load();
        if (!blob) return null;
        const made = maxEdge > 0 ? await build(blob, maxEdge) : { url: URL.createObjectURL(blob), bytes: blob.size, refs: 0 };
        cache.set(key, made);
        total += made.bytes;
        return made;
      })().finally(() => inflight.delete(key));
      inflight.set(key, job);
    }
    entry = await job;
    if (!entry) return null;
  }
  const held = entry;
  held.refs += 1;
  evict();
  let released = false;
  return {
    url: held.url,
    release: () => {
      if (released) return;
      released = true;
      held.refs = Math.max(0, held.refs - 1);
      evict();
    },
  };
}

/** Forget a picture (e.g. after its cached original was replaced). */
export function dropSized(path: string) {
  for (const [key, entry] of cache) {
    if (!key.endsWith(`:${path}`) || entry.refs > 0) continue;
    URL.revokeObjectURL(entry.url);
    cache.delete(key);
    total -= entry.bytes;
  }
}

// One shared observer: images start loading when they come within ~1.5 screens.
type Watch = (near: boolean) => void;
const watchers = new WeakMap<Element, Watch>();
let observer: IntersectionObserver | null = null;

export function watchNear(node: Element, onNear: () => void): () => void {
  if (typeof IntersectionObserver === "undefined") {
    onNear();
    return () => undefined;
  }
  if (!observer) {
    observer = new IntersectionObserver(
      (entries) => {
        for (const item of entries) {
          if (!item.isIntersecting) continue;
          const watch = watchers.get(item.target);
          observer?.unobserve(item.target);
          watchers.delete(item.target);
          watch?.(true);
        }
      },
      { rootMargin: "1200px 0px" },
    );
  }
  watchers.set(node, () => onNear());
  observer.observe(node);
  return () => {
    watchers.delete(node);
    observer?.unobserve(node);
  };
}
