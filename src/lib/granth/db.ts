import type { Catalog, GalleryFolder, GalleryItem } from "./types";

const DB_NAME = "granth-offline";
const DB_VERSION = 2;

let dbPromise: Promise<IDBDatabase> | null = null;

/**
 * One shared IndexedDB connection for the whole app. Opening a new connection
 * per call (thousands of times while caching images) was slow and could block a
 * future DB_VERSION upgrade, so the connection is cached and closed when another
 * tab asks for a version change.
 */
function openDb(): Promise<IDBDatabase> {
  if (typeof indexedDB === "undefined") {
    return Promise.reject(new Error("offline store unavailable"));
  }
  if (dbPromise) return dbPromise;
  const opening = new Promise<IDBDatabase>((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, DB_VERSION);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains("meta")) db.createObjectStore("meta");
      if (!db.objectStoreNames.contains("images")) db.createObjectStore("images");
      if (!db.objectStoreNames.contains("gallery")) db.createObjectStore("gallery", { keyPath: "id" });
      if (!db.objectStoreNames.contains("folders")) db.createObjectStore("folders", { keyPath: "id" });
    };
    request.onblocked = () => {
      /* another tab still holds the old version; it closes on versionchange */
    };
    request.onsuccess = () => {
      const db = request.result;
      db.onversionchange = () => {
        db.close();
        dbPromise = null;
      };
      db.onclose = () => {
        dbPromise = null;
      };
      resolve(db);
    };
    request.onerror = () => reject(request.error ?? new Error("idb open failed"));
  });
  dbPromise = opening;
  opening.catch(() => {
    if (dbPromise === opening) dbPromise = null;
  });
  return opening;
}

function txDone(tx: IDBTransaction): Promise<void> {
  return new Promise((resolve, reject) => {
    tx.oncomplete = () => resolve();
    tx.onerror = () => reject(tx.error ?? new Error("idb tx failed"));
    tx.onabort = () => reject(tx.error ?? new Error("idb tx aborted"));
  });
}

export async function readCatalog(): Promise<Catalog | null> {
  const db = await openDb();
  const tx = db.transaction("meta", "readonly");
  const value = await new Promise<Catalog | undefined>((resolve, reject) => {
    const request = tx.objectStore("meta").get("catalog");
    request.onsuccess = () => resolve(request.result as Catalog | undefined);
    request.onerror = () => reject(request.error);
  });
  await txDone(tx);
  if (!value || !Array.isArray(value.topics)) return null;
  return value;
}

export async function writeCatalog(catalog: Catalog): Promise<void> {
  const db = await openDb();
  const tx = db.transaction("meta", "readwrite");
  tx.objectStore("meta").put(catalog, "catalog");
  await txDone(tx);
}

export async function readImage(path: string): Promise<Blob | null> {
  const found = await readImages([path]);
  return found.get(path) ?? null;
}

export async function readImages(paths: string[]): Promise<Map<string, Blob>> {
  const unique = [...new Set(paths.filter(Boolean))];
  const found = new Map<string, Blob>();
  if (!unique.length) return found;
  const db = await openDb();
  const tx = db.transaction("images", "readonly");
  const store = tx.objectStore("images");
  await Promise.all(
    unique.map(
      (path) =>
        new Promise<void>((resolve) => {
          const request = store.get(path);
          request.onsuccess = () => {
            const value = request.result as Blob | undefined;
            if (value && value.size > 32) found.set(path, value);
            resolve();
          };
          request.onerror = () => resolve();
        }),
    ),
  );
  await txDone(tx);
  return found;
}

export async function hasImage(path: string): Promise<boolean> {
  const found = await savedImagePaths([path]);
  return found.has(path);
}

export async function savedImagePaths(paths: string[]): Promise<Set<string>> {
  const unique = [...new Set(paths.filter(Boolean))];
  const found = new Set<string>();
  if (!unique.length) return found;
  const db = await openDb();
  const tx = db.transaction("images", "readonly");
  const store = tx.objectStore("images");
  await Promise.all(
    unique.map(
      (path) =>
        new Promise<void>((resolve) => {
          const request = store.count(path);
          request.onsuccess = () => {
            if (request.result > 0) found.add(path);
            resolve();
          };
          request.onerror = () => resolve();
        }),
    ),
  );
  await txDone(tx);
  return found;
}

export async function writeImage(path: string, blob: Blob): Promise<void> {
  const db = await openDb();
  const tx = db.transaction("images", "readwrite");
  tx.objectStore("images").put(blob, path);
  await txDone(tx);
}

export async function countImages(): Promise<number> {
  const db = await openDb();
  const tx = db.transaction("images", "readonly");
  const value = await new Promise<number>((resolve, reject) => {
    const request = tx.objectStore("images").count();
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
  await txDone(tx);
  return value;
}

export async function listFolders(): Promise<GalleryFolder[]> {
  const db = await openDb();
  const tx = db.transaction("folders", "readonly");
  const value = await new Promise<GalleryFolder[]>((resolve, reject) => {
    const request = tx.objectStore("folders").getAll();
    request.onsuccess = () => resolve((request.result as GalleryFolder[]) ?? []);
    request.onerror = () => reject(request.error);
  });
  await txDone(tx);
  return value.sort((a, b) => a.name.localeCompare(b.name, "hi"));
}

export async function saveFolder(folder: GalleryFolder): Promise<void> {
  const db = await openDb();
  const tx = db.transaction("folders", "readwrite");
  tx.objectStore("folders").put(folder);
  await txDone(tx);
}

export async function removeFolder(id: string): Promise<void> {
  const db = await openDb();
  const tx = db.transaction(["folders", "gallery"], "readwrite");
  tx.objectStore("folders").delete(id);
  const gallery = tx.objectStore("gallery");
  const items = await new Promise<GalleryItem[]>((resolve, reject) => {
    const request = gallery.getAll();
    request.onsuccess = () => resolve((request.result as GalleryItem[]) ?? []);
    request.onerror = () => reject(request.error);
  });
  for (const item of items) {
    if (item.folderId === id) gallery.put({ ...item, folderId: "" });
  }
  await txDone(tx);
}

export async function listGallery(): Promise<GalleryItem[]> {
  const db = await openDb();
  const tx = db.transaction("gallery", "readonly");
  const value = await new Promise<GalleryItem[]>((resolve, reject) => {
    const request = tx.objectStore("gallery").getAll();
    request.onsuccess = () => resolve((request.result as GalleryItem[]) ?? []);
    request.onerror = () => reject(request.error);
  });
  await txDone(tx);
  return value.sort((a, b) => b.createdAt - a.createdAt);
}

export async function saveGalleryItem(item: GalleryItem): Promise<void> {
  const db = await openDb();
  const tx = db.transaction("gallery", "readwrite");
  tx.objectStore("gallery").put(item);
  await txDone(tx);
}

export async function removeGalleryItem(id: string): Promise<void> {
  const db = await openDb();
  const tx = db.transaction("gallery", "readwrite");
  tx.objectStore("gallery").delete(id);
  await txDone(tx);
}
