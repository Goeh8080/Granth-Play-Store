/**
 * Pure helpers for the offline image cache. Kept free of browser APIs and
 * path aliases so `node --test` can exercise them directly.
 */

const SAFE_PATH = /^(granths|uploads)\/[A-Za-z0-9_.-]+$/;

export function safeMediaPath(input: string | null | undefined): string | null {
  if (!input) return null;
  let path = input.trim();
  if (!path) return null;
  if (path.startsWith("http://") || path.startsWith("https://")) {
    try {
      path = new URL(path).pathname;
    } catch {
      return null;
    }
  }
  path = path.replace(/^\/+/, "");
  return SAFE_PATH.test(path) ? path : null;
}

type GranthLike = { id: string; imagePath?: string | null; editorImagePath?: string | null };
type PramanLike = {
  granth_id: string;
  granth_image?: string | null;
  image_path?: string | null;
  editorImagePath?: string | null;
};

/** Every image a granth needs to be fully readable offline (covers + its pramans). */
export function granthImagePaths(granths: GranthLike[], pramans: PramanLike[]): Map<string, string[]> {
  const out = new Map<string, Set<string>>();
  const add = (id: string, value: string | null | undefined) => {
    const path = safeMediaPath(value);
    if (!id || !path) return;
    let bucket = out.get(id);
    if (!bucket) {
      bucket = new Set();
      out.set(id, bucket);
    }
    bucket.add(path);
  };
  for (const granth of granths) {
    if (!out.has(granth.id)) out.set(granth.id, new Set());
    add(granth.id, granth.imagePath);
    add(granth.id, granth.editorImagePath);
  }
  for (const praman of pramans) {
    add(praman.granth_id, praman.granth_image);
    add(praman.granth_id, praman.image_path);
    add(praman.granth_id, praman.editorImagePath);
  }
  return new Map([...out].map(([id, paths]) => [id, [...paths]]));
}

/** Granths whose every image is stored on the device. A granth with no images is not "offline". */
export function fullyCachedGranths(needs: Map<string, string[]>, saved: Set<string>): string[] {
  const ids: string[] = [];
  for (const [id, paths] of needs) {
    if (paths.length && paths.every((path) => saved.has(path))) ids.push(id);
  }
  return ids;
}

export type ImageProgress = { done: number; failed: number; total: number; running: boolean };

/** Hindi status line for the sync strip. Only counts images that were really stored. */
export function imageProgressLabel(images: ImageProgress, syncing: boolean): string {
  if (!images.total) return syncing ? "सूची सेव हो रही है…" : "";
  if (images.running) return `पेज सेव हो रहे हैं ${images.done}/${images.total}`;
  if (images.done >= images.total) return "सभी पेज इस डिवाइस पर सेव हैं";
  if (images.failed > 0) return `${images.failed} पेज सेव नहीं हुए — सिंक दबाकर फिर कोशिश करें`;
  return `सेव पेज ${images.done}/${images.total}`;
}
