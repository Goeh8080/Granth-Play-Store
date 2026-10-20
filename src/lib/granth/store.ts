import { create } from "zustand";
import { hasImage, readCatalog, readImage, savedImagePaths, writeCatalog, writeImage } from "./db";
import { mediaPath, mediaUrl } from "./media";
import { fullyCachedGranths, granthImagePaths } from "./offline-plan";
import { setOfflineGranths } from "./pdf-jobs";
import type { ApiEnvelope, Catalog, Granth, Praman, Topic } from "./types";

export type SyncStatus = "booting" | "syncing" | "ready" | "offline" | "error";

type ImageJob = {
  /** Images really stored in IndexedDB. */
  done: number;
  /** Images that could not be downloaded in the last pass. */
  failed: number;
  total: number;
  running: boolean;
};

type GranthState = {
  topics: Topic[];
  granths: Granth[];
  pramans: Praman[];
  syncedAt: number | null;
  status: SyncStatus;
  online: boolean;
  error: string | null;
  images: ImageJob;
  booted: boolean;
  boot: () => Promise<void>;
  sync: () => Promise<void>;
  savePages: () => void;
  stopSave: () => void;
};

let bootOnce: Promise<void> | null = null;
let saveToken = 0;
let syncing: Promise<void> | null = null;

const ORIGIN = "https://granth.wnmsolutions.com";

function inApk(): boolean {
  return typeof location !== "undefined" && location.protocol === "file:";
}

async function pullList<T>(request: string): Promise<T[]> {
  const url = inApk()
    ? `${ORIGIN}/api/index.php?request=${encodeURIComponent(request)}`
    : `/api/granth?request=${request}`;
  const response = await fetch(url);
  if (!response.ok) throw new Error(`${request} failed`);
  const body = (await response.json()) as ApiEnvelope<T>;
  if (!body.success || !Array.isArray(body.data)) throw new Error(`${request} empty`);
  return body.data;
}

async function pullCatalog(): Promise<Catalog> {
  if (inApk()) {
    const [topics, granths, pramans] = await Promise.all([
      pullList<Topic>("getTopics"),
      pullList<Granth>("getGranths"),
      pullList<Praman>("getPramans"),
    ]);
    return { topics, granths, pramans, syncedAt: Date.now() };
  }
  try {
    const response = await fetch("/api/granth?request=bundle");
    if (response.ok) {
      const body = (await response.json()) as {
        success?: boolean;
        data?: { topics?: Topic[]; granths?: Granth[]; pramans?: Praman[] };
      };
      if (body.success && Array.isArray(body.data?.topics) && Array.isArray(body.data?.granths) && Array.isArray(body.data?.pramans)) {
        return { topics: body.data.topics, granths: body.data.granths, pramans: body.data.pramans, syncedAt: Date.now() };
      }
    }
  } catch {
    /* older server — fall through */
  }
  const [topics, granths, pramans] = await Promise.all([
    pullList<Topic>("getTopics"),
    pullList<Granth>("getGranths"),
    pullList<Praman>("getPramans"),
  ]);
  return { topics, granths, pramans, syncedAt: Date.now() };
}

function imageGroups(catalog: Catalog): { first: string[]; rest: string[] } {
  const seen = new Set<string>();
  const take = (bucket: string[], value: string | null | undefined) => {
    const path = mediaPath(value);
    if (!path || seen.has(path)) return;
    seen.add(path);
    bucket.push(path);
  };
  const first: string[] = [];
  const rest: string[] = [];
  for (const granth of catalog.granths) {
    take(first, granth.imagePath);
    take(first, granth.editorImagePath);
  }
  for (const praman of catalog.pramans) {
    take(rest, praman.granth_image);
    take(rest, praman.image_path);
    take(rest, praman.editorImagePath);
  }
  return { first, rest };
}

function collectImagePaths(catalog: Catalog): string[] {
  const groups = imageGroups(catalog);
  return [...groups.first, ...groups.rest];
}

/** True only when the image is (now) stored on the device. */
export async function cacheImage(path: string): Promise<boolean> {
  try {
    if (await hasImage(path)) return true;
    const response = await fetch(mediaUrl(path));
    if (!response.ok) return false;
    const blob = await response.blob();
    if (!isImageBlob(blob)) return false;
    await writeImage(path, blob);
    return true;
  } catch {
    return false;
  }
}

export function isImageBlob(blob: Blob | null | undefined): blob is Blob {
  return Boolean(blob && blob.size >= 32 && (!blob.type || blob.type.startsWith("image/")));
}

async function refreshOfflineGranths(catalog: Pick<Catalog, "granths" | "pramans">) {
  const needs = granthImagePaths(catalog.granths, catalog.pramans);
  const all = [...new Set([...needs.values()].flat())];
  const saved = await savedImagePaths(all).catch(() => new Set<string>());
  setOfflineGranths(fullyCachedGranths(needs, saved));
}

export const useGranth = create<GranthState>((set, get) => ({
  topics: [],
  granths: [],
  pramans: [],
  syncedAt: null,
  status: "booting",
  online: true,
  error: null,
  images: { done: 0, failed: 0, total: 0, running: false },
  booted: false,
  boot: () => {
    if (bootOnce) return bootOnce;
    bootOnce = (async () => {
      const online = typeof navigator === "undefined" ? true : navigator.onLine;
      set({ online, booted: true });
      try {
        const cached = await readCatalog();
        if (cached) {
          const paths = collectImagePaths(cached);
          const saved = await savedImagePaths(paths).catch(() => new Set<string>());
          set({
            topics: cached.topics,
            granths: cached.granths,
            pramans: cached.pramans,
            syncedAt: cached.syncedAt,
            status: online ? "ready" : "offline",
            images: { done: saved.size, failed: 0, total: paths.length, running: false },
          });
          void refreshOfflineGranths(cached);
        }
      } catch {
        /* first run has no store */
      }
      if (online) {
        void get().sync().finally(() => {
          if (get().topics.length || get().granths.length) get().savePages();
        });
      } else if (get().topics.length || get().granths.length) {
        set({ status: "offline", online: false, error: null });
      } else {
        set({
          status: "error",
          online: false,
          error: "डेटा नहीं आ पाया। इंटरनेट चेक करके फिर सिंक करें।",
        });
      }
    })();
    return bootOnce;
  },
  sync: () => {
    // Timer, resume, the online event and the button can all ask at once;
    // share one request instead of pulling the whole catalog several times.
    if (syncing) return syncing;
    const job = (async () => {
      const online = typeof navigator === "undefined" ? true : navigator.onLine;
      if (!online) {
        const hasCache = Boolean(get().topics.length || get().granths.length || get().syncedAt);
        set({
          online: false,
          status: hasCache ? "offline" : "error",
          error: hasCache ? null : "डेटा नहीं आ पाया। इंटरनेट चेक करके फिर सिंक करें।",
        });
        return;
      }
      set({ status: "syncing", online: true, error: null });
      try {
        const catalog = await pullCatalog();
        await writeCatalog(catalog);
        const paths = collectImagePaths(catalog);
        const saved = await savedImagePaths(paths).catch(() => new Set<string>());
        set({
          topics: catalog.topics,
          granths: catalog.granths,
          pramans: catalog.pramans,
          syncedAt: catalog.syncedAt,
          status: "ready",
          error: null,
          images: { ...get().images, done: saved.size, total: paths.length },
        });
      } catch {
        const hasCache = Boolean(get().syncedAt);
        set({
          status: hasCache ? "ready" : "error",
          error: hasCache
            ? "नया डेटा नहीं मिला। सेव की हुई कॉपी चल रही है।"
            : "डेटा नहीं आ पाया। इंटरनेट चेक करके फिर सिंक करें।",
        });
      }
    })();
    syncing = job.finally(() => {
      syncing = null;
    });
    return syncing;
  },
  savePages: () => {
    const catalog: Catalog = {
      topics: get().topics,
      granths: get().granths,
      pramans: get().pramans,
      syncedAt: get().syncedAt ?? Date.now(),
    };
    const groups = imageGroups(catalog);
    const paths = [...groups.first, ...groups.rest];
    if (!paths.length) return;
    const token = ++saveToken;
    set({ images: { done: get().images.done, failed: 0, total: paths.length, running: true } });
    void (async () => {
      const have = await savedImagePaths(paths).catch(() => new Set<string>());
      let done = 0;
      let failed = 0;
      const pendingFirst: string[] = [];
      const pendingRest: string[] = [];
      for (const path of groups.first) {
        if (have.has(path)) done += 1;
        else pendingFirst.push(path);
      }
      for (const path of groups.rest) {
        if (have.has(path)) done += 1;
        else pendingRest.push(path);
      }
      if (token !== saveToken) return;
      const pending = pendingFirst.length + pendingRest.length;
      set({ images: { done, failed, total: paths.length, running: pending > 0 } });
      let settled = 0;
      const drain = async (queue: string[]) => {
        let cursor = 0;
        const worker = async () => {
          while (token === saveToken) {
            const index = cursor;
            cursor += 1;
            if (index >= queue.length) return;
            const path = queue[index];
            if (!path) return;
            // Count an image as saved only when it is really in IndexedDB.
            if (await cacheImage(path)) done += 1;
            else failed += 1;
            settled += 1;
            if (token === saveToken && (settled % 4 === 0 || settled === pending)) {
              set({ images: { done, failed, total: paths.length, running: settled < pending } });
            }
          }
        };
        const width = Math.min(6, queue.length);
        if (width > 0) await Promise.all(Array.from({ length: width }, () => worker()));
      };
      await drain(pendingFirst);
      await drain(pendingRest);
      if (token !== saveToken) return;
      set({ images: { done, failed, total: paths.length, running: false } });
      await refreshOfflineGranths(catalog);
    })();
  },
  stopSave: () => {
    saveToken += 1;
    set({ images: { ...get().images, running: false } });
  },
}));

export async function cachedObjectUrl(path: string): Promise<string | null> {
  const blob = await readImage(path);
  if (!blob) return null;
  return URL.createObjectURL(blob);
}
