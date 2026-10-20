import { useEffect, useState } from "react";
import { readImage, saveGalleryItem, writeImage } from "@/lib/granth/db";
import { mediaPath, mediaUrl } from "@/lib/granth/media";
import { ping, saveBlob } from "@/lib/granth/files";
import { isImageBlob } from "@/lib/granth/store";

type SaveMeta = {
  title: string;
  text: string;
  topic: string;
  granth: string;
};

type MediaImageProps = {
  path: string | null | undefined;
  alt: string;
  className?: string;
  onClick?: () => void;
  onView?: () => void;
  save?: SaveMeta | null;
  /** Lightbox images should load right away; list thumbnails stay lazy. */
  eager?: boolean;
};

async function loadBlob(path: string): Promise<Blob | null> {
  const cached = await readImage(path).catch(() => null);
  if (cached) return cached;
  const response = await fetch(mediaUrl(path));
  if (!response.ok) return null;
  const fetched = await response.blob();
  if (!isImageBlob(fetched)) return null;
  await writeImage(path, fetched).catch(() => undefined);
  return fetched;
}

export function MediaImage({ path, alt, className, onClick, onView, save, eager }: MediaImageProps) {
  const normalized = mediaPath(path);
  const [src, setSrc] = useState<string | null>(null);
  const [failed, setFailed] = useState(false);
  const [attempt, setAttempt] = useState(0);

  useEffect(() => {
    if (!normalized) return;
    let blobUrl: string | null = null;
    let cancel = false;
    setFailed(false);
    void (async () => {
      try {
        const blob = await loadBlob(normalized);
        if (cancel) return;
        if (!blob) {
          setFailed(true);
          return;
        }
        blobUrl = URL.createObjectURL(blob);
        setSrc(blobUrl);
      } catch {
        if (!cancel) setFailed(true);
      }
    })();
    return () => {
      cancel = true;
      if (blobUrl) URL.revokeObjectURL(blobUrl);
    };
  }, [normalized, attempt]);

  // Coming back online retries pictures that failed while offline.
  useEffect(() => {
    if (!failed) return;
    const retry = () => setAttempt((value) => value + 1);
    window.addEventListener("online", retry);
    return () => window.removeEventListener("online", retry);
  }, [failed]);

  if (!normalized) return null;
  if (!src && failed) {
    return (
      <span className={`shot shot-missing ${className ?? ""}`} role="img" aria-label={`${alt || "चित्र"} — उपलब्ध नहीं`}>
        <span className="shot-missing-text">चित्र उपलब्ध नहीं</span>
        <button
          type="button"
          className="pill"
          onClick={(event) => {
            event.stopPropagation();
            setAttempt((value) => value + 1);
          }}
        >
          फिर कोशिश करें
        </button>
      </span>
    );
  }
  if (!src) return <div className={`img-skeleton ${className ?? ""}`} aria-hidden="true" />;

  const onSave = async () => {
    if (!save) return;
    try {
      const blob = await loadBlob(normalized);
      if (!blob) throw new Error("image");
      const fileName = normalized.split("/").pop() || "image.jpg";
      await saveGalleryItem({
        id: `img-${normalized}`,
        kind: "image",
        title: save.title,
        text: save.text,
        topic: save.topic,
        granth: save.granth,
        folderId: "",
        createdAt: Date.now(),
        size: blob.size,
        fileName,
        blob,
      });
      const result = await saveBlob(blob, fileName);
      ping(result === "device" ? "फ़ोन की गैलरी और ऐप गैलरी में सेव हो गया" : result === "download" ? "डाउनलोड हो गया · ऐप गैलरी में भी सेव" : "ऐप गैलरी में सेव हो गया");
    } catch {
      ping("चित्र सेव नहीं हुआ — फिर कोशिश करें");
    }
  };

  const open = onClick;
  return (
    <span className={`shot ${className ?? ""}`}>
      {open ? (
        <button type="button" className="shot-open" aria-label={alt ? `${alt} — बड़ा देखें` : "चित्र बड़ा देखें"} onClick={open}>
          <img src={src} alt={alt} className="shot-img" loading={eager ? "eager" : "lazy"} decoding="async" />
        </button>
      ) : (
        <img src={src} alt={alt} className="shot-img" loading={eager ? "eager" : "lazy"} decoding="async" />
      )}
      {onView ? (
        <button
          className="shot-view"
          type="button"
          aria-label="ग्रंथ का चित्र देखें"
          onClick={(event) => {
            event.stopPropagation();
            onView();
          }}
        >
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M2 12s3.5-6 10-6 10 6 10 6-3.5 6-10 6S2 12 2 12z" fill="none" stroke="currentColor" strokeWidth="2" />
            <circle cx="12" cy="12" r="3" fill="none" stroke="currentColor" strokeWidth="2" />
          </svg>
        </button>
      ) : null}
      {save ? (
        <button
          className="shot-save"
          type="button"
          aria-label="चित्र सेव करें"
          onClick={(event) => {
            event.stopPropagation();
            void onSave();
          }}
        >
          ↓
        </button>
      ) : null}
    </span>
  );
}
