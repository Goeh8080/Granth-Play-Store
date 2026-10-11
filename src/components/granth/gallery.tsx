import { FolderPlus, Images, Trash2 } from "lucide-react";
import { useDeferredValue, useEffect, useMemo, useState } from "react";
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
  return <img className={className} alt={alt} src={src} />;
}

export function GalleryScreen() {
  const [items, setItems] = useState<GalleryItem[]>([]);
  const [folders, setFolders] = useState<GalleryFolder[]>([]);
  const [folderId, setFolderId] = useState("");
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [cols, setCols] = useState<1 | 2>(2);
  const [open, setOpen] = useState<GalleryItem | null>(null);
  useEffect(() => {
    if (!open) return;
    return pushCloser(() => setOpen(null));
  }, [open]);
  const [tab, setTab] = useState<"pdf" | "image">("pdf");

  const reload = async () => {
    const [nextItems, nextFolders] = await Promise.all([listGallery(), listFolders()]);
    setItems(nextItems);
    setFolders(nextFolders);
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

  const addFolder = async () => {
    const name = window.prompt("फोल्डर का नाम");
    if (!name?.trim()) return;
    await saveFolder({ id: `f-${Date.now()}`, name: name.trim() });
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
            <h2>Gallery</h2>
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
              placeholder="गैलरी खोजें — mans, गीता"
              onChange={(event) => setQuery(event.target.value)}
            />
          </form>
        </div>
      </header>
      <div className="gallery-tabs" role="tablist">
        <button type="button" className={tab === "pdf" ? "active" : ""} onClick={() => setTab("pdf")}>
          PDF
        </button>
        <button type="button" className={tab === "image" ? "active" : ""} onClick={() => setTab("image")}>
          चित्र
        </button>
      </div>
      <div className="folder-row">
        <button type="button" className={`pill ${folderId === "" ? "pill-maroon" : ""}`} onClick={() => setFolderId("")}>
          सभी
        </button>
        {folders.map((folder) => (
          <button
            key={folder.id}
            type="button"
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
              void saveFolder({ ...folder, name: name.trim() }).then(reload);
            }}
          >
            नाम बदलें
          </button>
        ) : null}
        {folderId ? (
          <button
            type="button"
            className="pill"
            onClick={() => void removeFolder(folderId).then(() => { setFolderId(""); return reload(); })}
          >
            फोल्डर हटाएँ
          </button>
        ) : null}
      </div>
      <div className={`card-grid gallery-grid cols-${cols}`}>
        {visible.map((item) => (
          <article
            key={item.id}
            className={`card gallery-card${item.kind === "pdf" ? " is-pdf" : ""}`}
            onClick={() => {
              if (item.kind === "pdf") void openBlob(item.blob, item.fileName);
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
              <button type="button" className="pill" onClick={() => void saveBlob(item.blob, item.fileName)}>
                सेव
              </button>
              <button type="button" className="pill" onClick={() => void shareBlob(item.blob, item.fileName)}>
                शेयर
              </button>
              {folders.length ? (
                <select
                  className="form-control folder-select"
                  value={item.folderId}
                  onChange={(event) => {
                    void saveGalleryItem({ ...item, folderId: event.target.value }).then(reload);
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
                onClick={() => {
                  if (item.kind === "pdf") {
                    const name = item.fileName || item.title;
                    if (!window.confirm(`क्या आप यह PDF हटाना चाहते हैं?\n${name}`)) return;
                  }
                  void removeGalleryItem(item.id).then(() => {
                    ping("हटा दिया");
                    return reload();
                  });
                }}
              >
                <Trash2 /> हटाएँ
              </button>
            </div>
          </article>
        ))}
      </div>
      {visible.length === 0 ? (
        <div className="empty">
          <h3>अभी खाली है</h3>
          <p>किसी चित्र के ↓ या कार्ड के PDF बटन से यहाँ सेव होगा।</p>
        </div>
      ) : null}
      {open ? (
        <div className="lightbox" role="dialog">
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
