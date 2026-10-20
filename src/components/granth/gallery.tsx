import { FolderPlus, Images, Trash2 } from "lucide-react";
import { useDeferredValue, useEffect, useMemo, useRef, useState } from "react";
import { listFolders, listGallery, removeFolder, removeGalleryItem, saveFolder, saveGalleryItem } from "@/lib/granth/db";
import { rankBySearch } from "@/lib/granth/search";
import type { GalleryFolder, GalleryItem } from "@/lib/granth/types";
import { openBlob, ping, saveBlob, shareBlob } from "@/lib/granth/files";
import { pushCloser } from "@/lib/granth/back";
import { IconBox } from "./ui";
import { PinchView } from "./zoom";

function BlobView({ blob, alt, className }: { blob: Blob; alt: string; className?: string }) {
  const [src, setSrc] = useState("");
  useEffect(() => {
    const url = URL.createObjectURL(blob);
    setSrc(url);
    return () => URL.revokeObjectURL(url);
  }, [blob]);
  if (!src) return null;
  return <img className={className} alt={alt} src={src} loading="lazy" decoding="async" />;
}

const PAGE = 24;

export function GalleryScreen() {
  const [items, setItems] = useState<GalleryItem[]>([]);
  const [folders, setFolders] = useState<GalleryFolder[]>([]);
  const [folderId, setFolderId] = useState("");
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [cols, setCols] = useState<1 | 2>(2);
  const [open, setOpen] = useState<GalleryItem | null>(null);
  const [loading, setLoading] = useState(true);
  const [failed, setFailed] = useState(false);
  const [limit, setLimit] = useState(PAGE);
  const more = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    if (!open) return;
    return pushCloser(() => setOpen(null));
  }, [open]);
  const [tab, setTab] = useState<"pdf" | "image">("pdf");

  const reload = async () => {
    try {
      const [nextItems, nextFolders] = await Promise.all([listGallery(), listFolders()]);
      setItems(nextItems);
      setFolders(nextFolders);
      setFailed(false);
    } catch {
      setFailed(true);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => {
    const saved = Number(localStorage.getItem("gallery-cols"));
    if (saved === 1 || saved === 2) setCols(saved);
    void reload();
    const onLayout = () => {
      const saved = Number(localStorage.getItem("gallery-cols"));
      if (saved === 1 || saved === 2) setCols(saved);
    };
    window.addEventListener("granth-layout", onLayout);
    return () => window.removeEventListener("granth-layout", onLayout);
  }, []);

  const visible = useMemo(() => {
    const inFolder = items.filter((item) => (folderId ? item.folderId === folderId : true) && item.kind === tab);
    return rankBySearch(inFolder, search, (item) => [item.title, item.topic, item.granth, item.fileName]);
  }, [folderId, items, search, tab]);

  useEffect(() => setLimit(PAGE), [folderId, search, tab]);
  // Only PAGE cards (and their object URLs) at a time; more as the user scrolls.
  const shown = Math.min(limit, visible.length);
  useEffect(() => {
    const node = more.current;
    if (!node || shown >= visible.length) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          observer.disconnect();
          setLimit((value) => value + PAGE);
        }
      },
      { rootMargin: "1200px 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [shown, visible.length]);

  const removeItem = (item: GalleryItem) => {
    const name = item.fileName || item.title;
    const what = item.kind === "pdf" ? "यह PDF" : "यह चित्र";
    if (!window.confirm(`क्या आप ${what} ऐप गैलरी से हटाना चाहते हैं?\n${name}`)) return;
    void removeGalleryItem(item.id)
      .then(() => {
        ping("हटा दिया");
        return reload();
      })
      .catch(() => ping("हटाया नहीं जा सका — फिर कोशिश करें"));
  };

  const addFolder = async () => {
    const name = window.prompt("फोल्डर का नाम");
    if (!name?.trim()) return;
    try {
      await saveFolder({ id: `f-${Date.now()}`, name: name.trim() });
      ping("फोल्डर बन गया");
    } catch {
      ping("फोल्डर नहीं बना — फिर कोशिश करें");
    }
    await reload();
  };

  return (
    <section>
      <header className="page-header">
        <div className="page-title">
          <IconBox tone="gold">
            <Images />
          </IconBox>
          <div>
            <h2>गैलरी</h2>
            <p className="subtitle">सेव चित्र और PDF</p>
          </div>
        </div>
        <div className="granth-tools">
          <div className="grid-switch" role="group" aria-label="गैलरी ग्रिड">
            {([1, 2] as const).map((size) => (
              <button
                key={size}
                type="button"
                className={cols === size ? "active" : ""}
                aria-pressed={cols === size}
                onClick={() => {
                  setCols(size);
                  localStorage.setItem("gallery-cols", String(size));
                }}
              >
                {size}×{size}
              </button>
            ))}
          </div>
          <form className="search-row" onSubmit={(event) => event.preventDefault()}>
            <input
              className="form-control"
              value={query}
              lang="hi"
              type="search"
              aria-label="गैलरी खोजें"
              placeholder="गैलरी खोजें — mans, गीता"
              onChange={(event) => setQuery(event.target.value)}
            />
          </form>
        </div>
      </header>
      <div className="gallery-tabs" role="tablist" aria-label="गैलरी प्रकार">
        <button type="button" role="tab" aria-selected={tab === "pdf"} className={tab === "pdf" ? "active" : ""} onClick={() => setTab("pdf")}>
          PDF
        </button>
        <button type="button" role="tab" aria-selected={tab === "image"} className={tab === "image" ? "active" : ""} onClick={() => setTab("image")}>
          चित्र
        </button>
      </div>
      <div className="folder-row">
        <button type="button" aria-pressed={folderId === ""} className={`pill ${folderId === "" ? "pill-maroon" : ""}`} onClick={() => setFolderId("")}>
          सभी
        </button>
        {folders.map((folder) => (
          <button
            key={folder.id}
            type="button"
            aria-pressed={folderId === folder.id}
            className={`pill ${folderId === folder.id ? "pill-maroon" : ""}`}
            onClick={() => setFolderId(folder.id)}
          >
            {folder.name}
          </button>
        ))}
        <button type="button" className="pill" onClick={() => void addFolder()}>
          <FolderPlus /> फोल्डर
        </button>
        {folderId ? (
          <button
            type="button"
            className="pill"
            onClick={() => {
              const folder = folders.find((item) => item.id === folderId);
              const name = window.prompt("नया नाम", folder?.name ?? "");
              if (!name?.trim() || !folder) return;
              void saveFolder({ ...folder, name: name.trim() })
                .then(reload)
                .catch(() => ping("नाम नहीं बदला — फिर कोशिश करें"));
            }}
          >
            नाम बदलें
          </button>
        ) : null}
        {folderId ? (
          <button
            type="button"
            className="pill"
            onClick={() => {
              const folder = folders.find((item) => item.id === folderId);
              if (!window.confirm(`फोल्डर “${folder?.name ?? ""}” हटाएँ? इसकी फ़ाइलें गैलरी में रहेंगी।`)) return;
              void removeFolder(folderId)
                .then(() => {
                  setFolderId("");
                  return reload();
                })
                .catch(() => ping("फोल्डर नहीं हटा — फिर कोशिश करें"));
            }}
          >
            फोल्डर हटाएँ
          </button>
        ) : null}
      </div>
      <div className={`card-grid gallery-grid cols-${cols}`}>
        {visible.slice(0, shown).map((item) => (
          <article
            key={item.id}
            className={`card gallery-card${item.kind === "pdf" ? " is-pdf" : ""}`}
            aria-label={item.title}
            tabIndex={0}
            onKeyDown={(event) => {
              if (event.target !== event.currentTarget || (event.key !== "Enter" && event.key !== " ")) return;
              event.preventDefault();
              if (item.kind === "pdf") void openBlob(item.blob, item.fileName);
              else setOpen(item);
            }}
            onClick={() => {
              if (item.kind === "pdf") void openBlob(item.blob, item.fileName);
              else setOpen(item);
            }}
          >
            {item.kind === "image" ? (
              <BlobView className="cover" alt={item.title} blob={item.blob} />
            ) : item.preview ? (
              <div className="pdf-preview">
                <BlobView className="cover" alt={item.title} blob={item.preview} />
              </div>
            ) : (
              <div className="pdf-tile">PDF</div>
            )}
            <h3 className="card-title">{item.title}</h3>
            {item.kind === "pdf" ? null : (
              <>
                {item.text ? <p className="card-desc">{item.text}</p> : null}
                {item.topic ? <p className="fine">{item.topic}</p> : null}
                {item.granth ? <p className="fine">{item.granth}</p> : null}
                <p className="fine">{new Date(item.createdAt).toLocaleDateString("hi-IN")}</p>
              </>
            )}
            <div className="card-meta" onClick={(event) => event.stopPropagation()}>
              <button
                type="button"
                className="pill"
                onClick={() => {
                  if (item.kind === "pdf") void openBlob(item.blob, item.fileName);
                  else setOpen(item);
                }}
              >
                {item.kind === "pdf" ? "PDF खोलें" : "खोलें"}
              </button>
              <button
                type="button"
                className="pill"
                onClick={() =>
                  void saveBlob(item.blob, item.fileName).then((result) =>
                    ping(
                      result === "failed"
                        ? "सेव नहीं हुआ — फिर कोशिश करें"
                        : item.kind === "pdf"
                          ? result === "device"
                            ? "Downloads में सेव हो गया"
                            : "डाउनलोड हो गया"
                          : result === "device"
                            ? "फ़ोन की गैलरी में सेव हो गया"
                            : "डाउनलोड हो गया",
                    ),
                  )
                }
              >
                सेव
              </button>
              <button type="button" className="pill" onClick={() => void shareBlob(item.blob, item.fileName)}>
                शेयर
              </button>
              {folders.length ? (
                <select
                  className="form-control folder-select"
                  aria-label="फोल्डर चुनें"
                  value={item.folderId}
                  onChange={(event) => {
                    void saveGalleryItem({ ...item, folderId: event.target.value })
                      .then(reload)
                      .catch(() => ping("फोल्डर नहीं बदला — फिर कोशिश करें"));
                  }}
                >
                  <option value="">कोई फोल्डर नहीं</option>
                  {folders.map((folder) => (
                    <option key={folder.id} value={folder.id}>
                      {folder.name}
                    </option>
                  ))}
                </select>
              ) : null}
              <button
                type="button"
                className="pill"
                onClick={() => removeItem(item)}
              >
                <Trash2 /> हटाएँ
              </button>
            </div>
          </article>
        ))}
      </div>
      <div ref={more} className="scroll-sentinel" />
      {loading ? (
        <div className="loading">
          <div className="spinner" />
          <p>गैलरी खुल रही है…</p>
        </div>
      ) : failed ? (
        <div className="empty">
          <h3>गैलरी नहीं खुली</h3>
          <p>फ़ोन की स्टोरेज पढ़ी नहीं जा सकी।</p>
          <button type="button" className="pill pill-maroon" onClick={() => void reload()}>
            फिर कोशिश करें
          </button>
        </div>
      ) : visible.length === 0 ? (
        <div className="empty">
          <h3>{search.trim() ? "कोई परिणाम नहीं" : "अभी खाली है"}</h3>
          <p>{search.trim() ? "दूसरा शब्द आज़माएँ।" : "किसी चित्र के ↓ या कार्ड के PDF बटन से यहाँ सेव होगा।"}</p>
        </div>
      ) : null}
      {open ? (
        <div className="lightbox" role="dialog" aria-modal="true" aria-label={open.title}>
          <button className="lightbox-close" type="button" onClick={() => setOpen(null)}>
            बंद
          </button>
          <div className="lightbox-scroll">
            {open.kind === "image" ? (
              <PinchView>
                <BlobView className="lightbox-img" alt={open.title} blob={open.blob} />
              </PinchView>
            ) : null}
            <article className="note-card">
              <h3>{open.title}</h3>
              {open.text ? <p>{open.text}</p> : null}
              {open.topic ? <p>विषय: {open.topic}</p> : null}
              {open.granth ? <p>ग्रंथ: {open.granth}</p> : null}
            </article>
          </div>
        </div>
      ) : null}
    </section>
  );
}
