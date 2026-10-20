import {
  ClipboardList,
  Image as ImageIcon,
  Landmark,
  Library,
  PenLine,
  Share2,
  X,
} from "lucide-react";
import { useDeferredValue, useEffect, useLayoutEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent, type PointerEvent as ReactPointerEvent } from "react";
import { sortPramans } from "@/lib/granth/order";
import { prepareFields, rankPrepared, type PreparedDoc } from "@/lib/granth/search";
import { readImage, readImages, saveGalleryItem, writeImage } from "@/lib/granth/db";
import { isImageBlob, useGranth } from "@/lib/granth/store";
import { openExternal, publicLink, shareLink as sharePublic } from "@/lib/granth/files";
import { pushCloser } from "@/lib/granth/back";
import { mediaPath, mediaUrl, youtubeId } from "@/lib/granth/media";
import { enqueuePdf, markGranthsOffline, useOfflineIds } from "@/lib/granth/pdf-jobs";
import { PDF_STYLES, rememberPdfStyle, savedPdfStyle, type PdfStyle } from "@/lib/granth/pdf-style";
import type { BookPage } from "@/lib/granth/pdf";
import { PinchView } from "./zoom";
import type { AppRoute, Granth, Praman, Topic } from "@/lib/granth/types";
import { MediaImage } from "./media-image";
import { IconBox, RichText } from "./ui";

/**
 * Render a long list in growing slices. The observer is re-armed after every
 * batch: IntersectionObserver only reports *changes*, so when the sentinel was
 * still inside the 1200px margin after a batch rendered (short cards, fast
 * fling) the old code never fired again and the list stopped growing — the
 * "scroll limit" users saw at 16/24/… items.
 */
function useSlice(resetKey: string, total: number, step = 18, keep?: number) {
  const [count, setCount] = useState(() => Math.max(step, keep ?? step));
  const ref = useRef<HTMLDivElement | null>(null);
  useLayoutEffect(() => {
    setCount(Math.max(step, keep ?? step));
  }, [resetKey, step, keep]);
  const shown = Math.min(count, total);
  useEffect(() => {
    const node = ref.current;
    if (!node || shown >= total) return;
    const observer = new IntersectionObserver(
      (entries) => {
        if (entries.some((entry) => entry.isIntersecting)) {
          observer.disconnect();
          setCount((value) => Math.min(total, Math.max(value, shown) + step));
        }
      },
      { rootMargin: "1200px 0px" },
    );
    observer.observe(node);
    return () => observer.disconnect();
  }, [resetKey, step, total, shown]);
  return { count: shown, ref };
}

function cardKeys(onOpen: () => void) {
  return {
    tabIndex: 0,
    onKeyDown(event: React.KeyboardEvent) {
      if (event.target !== event.currentTarget) return;
      if (event.key === "Enter" || event.key === " ") {
        event.preventDefault();
        onOpen();
      }
    },
  };
}

/** Column choice per screen; Settings → लेआउट updates every open screen at once. */
function useCols<T extends number>(key: string, allowed: readonly T[], fallback: T) {
  const read = () => {
    try {
      const saved = Number(localStorage.getItem(key)) as T;
      return allowed.includes(saved) ? saved : fallback;
    } catch {
      return fallback;
    }
  };
  const [cols, setCols] = useState<T>(() => (typeof window === "undefined" ? fallback : read()));
  useEffect(() => {
    setCols(read());
    const onLayout = () => setCols(read());
    window.addEventListener("granth-layout", onLayout);
    return () => window.removeEventListener("granth-layout", onLayout);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key]);
  const pick = (next: T) => {
    setCols(next);
    try {
      localStorage.setItem(key, String(next));
    } catch {
      /* private mode */
    }
  };
  return [cols, pick] as const;
}

async function shareLink(title: string, hash: string) {
  const params = new URLSearchParams((hash.split("?")[1] || "").split("#")[0]);
  const topic = params.get("topic");
  const granth = params.get("granth");
  const id = params.get("id");
  const url = topic ? publicLink("topic", topic) : granth ? publicLink("granth", granth) : publicLink("praman", id || "");
  await sharePublic(title, url);
}

function readPlace(key: string) {
  try {
    const parsed = JSON.parse(localStorage.getItem(key) || sessionStorage.getItem(key) || "null") as { y?: number; count?: number; id?: string; anchor?: number } | null;
    if (!parsed || typeof parsed.y !== "number") return null;
    return {
      y: parsed.y,
      count: Math.max(8, Number(parsed.count) || 8),
      id: typeof parsed.id === "string" ? parsed.id : "",
      anchor: typeof parsed.anchor === "number" ? parsed.anchor : 0,
    };
  } catch {
    return null;
  }
}

function writePlace(key: string, value: { y: number; count: number; id?: string; anchor?: number }) {
  const raw = JSON.stringify(value);
  try {
    localStorage.setItem(key, raw);
  } catch {
    /* ignore */
  }
  try {
    sessionStorage.setItem(key, raw);
  } catch {
    /* ignore */
  }
}

let activeSave: ((hint?: { id?: string }) => void) | null = null;
let lastScrollAt = 0;
if (typeof window !== "undefined") {
  window.addEventListener("scroll", () => { lastScrollAt = Date.now(); }, { passive: true });
}

export function captureListPlace(hint?: { id?: string }) {
  activeSave?.(hint);
}

function pinPlace(saved: { y: number; id?: string; anchor?: number } | null) {
  if (saved?.id) {
    const card = document.querySelector(`[data-granth="${CSS.escape(saved.id)}"]`);
    if (card) {
      const delta = card.getBoundingClientRect().top - (saved.anchor ?? 0);
      if (Math.abs(delta) > 1) window.scrollTo(0, window.scrollY + delta);
      return;
    }
  }
  window.scrollTo(0, saved ? saved.y : 0);
}

function useRememberList(storageKey: string, active: boolean, query: string) {
  const countRef = useRef(0);
  const totalRef = useRef(0);
  const yRef = useRef(0);
  const frozen = useRef(false);
  const place = useRef<{ y: number; count: number; id?: string; anchor?: number } | null>(null);
  const seen = useRef("");
  const restored = useRef(false);
  const token = active && !query ? storageKey : "";
  if (seen.current !== token) {
    seen.current = token;
    place.current = token ? readPlace(token) : null;
    yRef.current = place.current?.y ?? 0;
    restored.current = false;
  }
  useLayoutEffect(() => {
    if (!token || restored.current) return;
    const saved = place.current;
    if (saved && countRef.current < Math.min(saved.count, totalRef.current || saved.count)) return;
    restored.current = true;
    pinPlace(saved);
  });
  useEffect(() => {
    if (!token) return;
    let timer = 0;
    const persist = (hint?: { id?: string }) => {
      const id = hint?.id || "";
      const card = id ? document.querySelector(`[data-granth="${CSS.escape(id)}"]`) : null;
      const anchor = card ? card.getBoundingClientRect().top : 0;
      writePlace(storageKey, { y: yRef.current, count: countRef.current, id, anchor });
    };
    const snapshot = (hint?: { id?: string }) => {
      if (frozen.current) return;
      yRef.current = window.scrollY;
      frozen.current = true;
      persist(hint);
    };
    activeSave = snapshot;
    const onScroll = () => {
      if (frozen.current) return;
      yRef.current = window.scrollY;
      window.clearTimeout(timer);
      timer = window.setTimeout(() => persist(), 120);
    };
    window.addEventListener("scroll", onScroll, { passive: true });
    const saved = place.current;
    const timers: number[] = [];
    const onLoad = (event: Event) => {
      if (!(event.target instanceof HTMLImageElement)) return;
      pinPlace(saved);
    };
    if (saved?.id) {
      document.addEventListener("load", onLoad, true);
      for (const wait of [40, 160, 400]) timers.push(window.setTimeout(() => pinPlace(saved), wait));
    }
    return () => {
      if (!frozen.current) persist();
      window.clearTimeout(timer);
      for (const wait of timers) window.clearTimeout(wait);
      window.removeEventListener("scroll", onScroll);
      document.removeEventListener("load", onLoad, true);
      if (activeSave === snapshot) activeSave = null;
    };
  }, [storageKey, token]);
  return {
    keep: token ? place.current?.count : undefined,
    track(count: number, total: number) {
      countRef.current = count;
      totalRef.current = total;
    },
  };
}

function tappedControl(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest("button, a, input, textarea, select"));
}

function bindOpen(onOpen: () => void) {
  const start = { x: 0, y: 0, scroll: 0, moved: false };
  const open = (target: EventTarget | null) => {
    if (start.moved || tappedControl(target)) return;
    if (Math.abs(window.scrollY - start.scroll) > 6) return;
    if (Date.now() - lastScrollAt < 220) return;
    onOpen();
  };
  return {
    onPointerDown(event: ReactPointerEvent) {
      start.x = event.clientX;
      start.y = event.clientY;
      start.scroll = window.scrollY;
      start.moved = false;
    },
    onPointerMove(event: ReactPointerEvent) {
      if (Math.hypot(event.clientX - start.x, event.clientY - start.y) > 12) start.moved = true;
    },
    onPointerCancel() {
      start.moved = true;
    },
    onPointerUp(event: ReactPointerEvent) {
      if (event.pointerType === "mouse") return;
      open(event.target);
    },
    onClick(event: ReactMouseEvent) {
      open(event.target);
    },
  };
}

export function Dashboard({ go }: { go: (hash: string) => void }) {
  const topics = useGranth((state) => state.topics.length);
  const granths = useGranth((state) => state.granths.length);
  const pramans = useGranth((state) => state.pramans.length);
  return (
    <section>
      <header className="page-header">
        <div className="page-title">
          <IconBox tone="saffron">
            <Landmark />
          </IconBox>
          <div>
            <h2>मुख्य पृष्ठ</h2>
            <p className="subtitle">आपके ग्रंथ संग्रह का सार</p>
          </div>
        </div>
      </header>
      <div className="dash-grid">
        <button className="dash-card" type="button" onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/topics"); }} onClick={() => go("#/topics")}>
          <IconBox tone="saffron" className="dash-glyph">
            <ClipboardList />
          </IconBox>
          <div>
            <div className="dash-num">{topics || "—"}</div>
            <div className="dash-lbl">विषय</div>
          </div>
        </button>
        <button className="dash-card" type="button" onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/granths"); }} onClick={() => go("#/granths")}>
          <IconBox tone="maroon" className="dash-glyph">
            <Library />
          </IconBox>
          <div>
            <div className="dash-num">{granths || "—"}</div>
            <div className="dash-lbl">ग्रंथ</div>
          </div>
        </button>
        <button className="dash-card" type="button" onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/pramans"); }} onClick={() => go("#/pramans")}>
          <IconBox tone="gold" className="dash-glyph">
            <ImageIcon />
          </IconBox>
          <div>
            <div className="dash-num">{pramans || "—"}</div>
            <div className="dash-lbl">प्रमाण</div>
          </div>
        </button>
      </div>
      <article className="note-card">
        <h3>सत साहेब जी</h3>
        <p>
          जो प्रमाण समय पर याद नहीं रहते, यह ग्रंथ प्रबंधन उन्हें विषय और ग्रंथ के साथ एक जगह रखता है। पहली बार
          इंटरनेट पर खुलते ही विषय, ग्रंथ और प्रमाण इस डिवाइस पर सेव हो जाते हैं — उसके बाद ऐप बिना नेट के खुलता है।
        </p>
        <p>
          संपर्क:{" "}
          <a href="mailto:sadgranthpraman@gmail.com">sadgranthpraman@gmail.com</a>
        </p>
      </article>
    </section>
  );
}

export function TopicScreen({ go }: { go: (hash: string) => void }) {
  const topics = useGranth((state) => state.topics);
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [cols, setCols] = useCols<1 | 2>("topic-cols", [1, 2], 2);
  const [multiOpen, setMultiOpen] = useState(false);
  const [picked, setPicked] = useState<string[]>([]);
  const docs = useMemo(() => {
    const map = new Map<string, PreparedDoc>();
    for (const topic of topics) map.set(topic.id, prepareFields([topic.title, topic.description]));
    return map;
  }, [topics]);
  const filtered = useMemo(() => {
    const ranked = rankPrepared(topics, search, (topic) => docs.get(topic.id) ?? prepareFields([topic.title]));
    if (search.trim()) return ranked;
    return [...ranked].sort((a, b) => Number(a.position) - Number(b.position));
  }, [docs, search, topics]);
  const memory = useRememberList("topic-list-place", true, search);
  const { count, ref } = useSlice(`${search}|${cols}`, filtered.length, cols === 1 ? 12 : 16, memory.keep);
  memory.track(count, filtered.length);
  const total = filtered.length;
  useEffect(() => {
    if (!multiOpen) return;
    return pushCloser(() => setMultiOpen(false));
  }, [multiOpen]);
  const toggleTopic = (id: string) => {
    setPicked((current) => (current.includes(id) ? current.filter((item) => item !== id) : [...current, id]));
  };
  return (
    <section>
      <header className="page-header sticky-bar">
        <div className="topic-head-row">
        <div className="page-title">
          <IconBox tone="saffron">
            <ClipboardList />
          </IconBox>
          <div>
            <h2>विषय</h2>
            <p className="subtitle">विषय / प्रश्नोत्तरी</p>
          </div>
        </div>
        <button type="button" className="multi-pdf" onClick={() => setMultiOpen(true)}>
          कई विषयों की PDF
        </button>
        </div>
        <div className="granth-tools">
          <div className="grid-switch" role="group" aria-label="विषय ग्रिड">
            {([1, 2] as const).map((size) => (
              <button
                key={size}
                type="button"
                className={cols === size ? "active" : ""}
                aria-pressed={cols === size}
                onClick={() => setCols(size)}
              >
                {size}×{size}
              </button>
            ))}
          </div>
          <form
            className="search-row"
            onSubmit={(event) => {
              event.preventDefault();
            }}
          >
            <input
              className="form-control"
              value={query}
              lang="hi"
              type="search"
              aria-label="विषय खोजें"
              placeholder="विषय खोजें — mans, गीता, मृत्यु"
              onChange={(event) => setQuery(event.target.value)}
            />
          </form>
        </div>
      </header>
      <div className={`card-grid topic-grid cols-${cols}`}>
        {filtered.slice(0, count).map((topic, index) => (
          <TopicCard
            key={topic.id}
            topic={topic}
            index={index + 1}
            total={total}
            onOpen={() => go(`#/pramans?topic=${topic.id}`)}
            onShare={() => void shareLink(topic.title, `#/pramans?topic=${topic.id}`)}
            onPdf={() => askPdf({ kind: "topic", topic })}
          />
        ))}
      </div>
      {filtered.length === 0 ? (
        search.trim() ? (
          <Empty title="कोई परिणाम नहीं" body={`“${search.trim()}” से कोई विषय नहीं मिला। दूसरा शब्द आज़माएँ।`} />
        ) : (
          <Empty title="कोई विषय नहीं" body="सिंक पूरा होने पर विषय यहाँ दिखेंगे।" />
        )
      ) : null}
      <div ref={ref} className="scroll-sentinel" />
      {multiOpen ? (
        <div className="pdf-pop" role="presentation" onClick={() => setMultiOpen(false)}>
          <div className="pdf-sheet multi-sheet" role="dialog" aria-modal="true" aria-label="कई विषयों की PDF" onClick={(event) => event.stopPropagation()}>
            <div className="pdf-sheet-head">
              <h3>कई विषयों की PDF</h3>
              <button type="button" className="pill" onClick={() => setMultiOpen(false)}>
                <X /> पीछे
              </button>
            </div>
            <p className="subtitle">जिन विषयों की PDF चाहिए उन्हें चुनें। आखिर में एक ही जोड़ी हुई PDF बनेगी।</p>
            <div className="multi-actions">
              <button type="button" className="pill" onClick={() => setPicked(topics.map((topic) => topic.id))}>
                सभी
              </button>
              <button type="button" className="pill" onClick={() => setPicked([])}>
                साफ
              </button>
              <button
                type="button"
                className="pdf-ok"
                disabled={picked.length === 0}
                onClick={() => {
                  const order = new Map(picked.map((id, index) => [id, index]));
                  const chosen = topics
                    .filter((topic) => picked.includes(topic.id))
                    .sort((a, b) => (order.get(a.id) ?? 0) - (order.get(b.id) ?? 0));
                  beginTopicsPdf(chosen);
                  setMultiOpen(false);
                }}
              >
                एक PDF बनाएँ ({picked.length})
              </button>
            </div>
            <div className="multi-list">
              {topics.map((topic, index) => {
                const on = picked.includes(topic.id);
                return (
                  <button key={topic.id} type="button" className={on ? "multi-row on" : "multi-row"} aria-pressed={on} onClick={() => toggleTopic(topic.id)}>
                    <span>{on ? "✓" : index + 1}</span>
                    <strong>{topic.title}</strong>
                  </button>
                );
              })}
            </div>
          </div>
        </div>
      ) : null}
    </section>
  );
}

function TopicCard({
  topic,
  index,
  total,
  onOpen,
  onShare,
  onPdf,
}: {
  topic: Topic;
  index: number;
  total: number;
  onOpen: () => void;
  onShare: () => void;
  onPdf: () => void;
}) {
  const proofs = Number(topic.praman_count) || 0;
  return (
    <article className="card topic-card" aria-label={topic.title} {...bindOpen(onOpen)} {...cardKeys(onOpen)}>
      <div className="card-header">
        <h3 className="card-title">
          <span>
            {topic.position}. <RichText text={topic.title} />
          </span>
        </h3>
      </div>
      {topic.description ? (
        <p className="card-desc">
          <RichText text={topic.description} />
        </p>
      ) : null}
      <div className="card-meta" onClick={(event) => event.stopPropagation()} onPointerUp={(event) => event.stopPropagation()}>
        {proofs > 0 ? (
          <button className="pill pill-maroon" type="button" onClick={onOpen}>
            <ImageIcon /> {proofs} प्रमाण
          </button>
        ) : null}
        {proofs > 0 ? (
          <button className="pill" type="button" onClick={onOpen}>
            <Library /> {index}/{total}
          </button>
        ) : null}
        <button className="pill" type="button" onClick={onShare}>
          <Share2 /> शेयर
        </button>
        <button className="pill pill-maroon" type="button" aria-label={`${topic.title} की PDF`} onClick={onPdf}>
          PDF
        </button>
      </div>
    </article>
  );
}

export function GranthScreen({
  go,
  onOpen,
}: {
  go: (hash: string) => void;
  onOpen: (paths: string[]) => void;
}) {
  const granths = useGranth((state) => state.granths);
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [cols, pickCols] = useCols<1 | 2 | 3>("granth-cols", [1, 2, 3], 2);
  const docs = useMemo(() => {
    const map = new Map<string, PreparedDoc>();
    for (const granth of granths) map.set(granth.id, prepareFields([granth.title, granth.author, granth.description]));
    return map;
  }, [granths]);
  const filtered = useMemo(() => {
    const ranked = rankPrepared(granths, search, (granth) => docs.get(granth.id) ?? prepareFields([granth.title]));
    if (search.trim()) return ranked;
    return [...ranked].sort((a, b) => Number(a.position) - Number(b.position));
  }, [docs, granths, search]);
  const step = cols === 1 ? 8 : cols === 2 ? 12 : 18;
  const memory = useRememberList("granth-list-place", true, search);
  const { count, ref } = useSlice(`${search}|${cols}`, filtered.length, step, memory.keep);
  memory.track(count, filtered.length);
  return (
    <section>
      <header className="page-header sticky-bar">
        <div className="page-title">
          <IconBox tone="maroon">
            <Library />
          </IconBox>
          <div>
            <h2>ग्रंथ</h2>
            <p className="subtitle">पवित्र ग्रंथ और शास्त्र</p>
          </div>
        </div>
        <div className="granth-tools">
          <div className="grid-switch" role="group" aria-label="ग्रंथ ग्रिड">
            {([1, 2, 3] as const).map((size) => (
              <button
                key={size}
                type="button"
                className={cols === size ? "active" : ""}
                aria-pressed={cols === size}
                onClick={() => pickCols(size)}
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
              aria-label="ग्रंथ खोजें"
              placeholder="ग्रंथ का नाम — gita, kabir"
              onChange={(event) => setQuery(event.target.value)}
            />
          </form>
        </div>
      </header>
      <div className={`card-grid granth-grid cols-${cols}`}>
        {filtered.slice(0, count).map((granth, index) => (
          <GranthCard
            key={granth.id}
            granth={granth}
            index={index + 1}
            total={filtered.length}
            onOpen={() => go(`#/pramans?granth=${granth.id}`)}
            onShare={() => void shareLink(granth.title, `#/pramans?granth=${granth.id}`)}
            onImage={() => {
              const paths = [granth.imagePath, granth.editorImagePath].map(mediaPath).filter(Boolean) as string[];
              if (paths.length) onOpen(paths);
            }}
          />
        ))}
      </div>
      {filtered.length === 0 ? (
        search.trim() ? (
          <Empty title="कोई परिणाम नहीं" body={`“${search.trim()}” से कोई ग्रंथ नहीं मिला। दूसरा शब्द आज़माएँ।`} />
        ) : (
          <Empty title="कोई ग्रंथ नहीं" body="सिंक के बाद पवित्र ग्रंथ यहाँ खुलेंगे।" />
        )
      ) : null}
      <div ref={ref} className="scroll-sentinel" />
    </section>
  );
}

/** Picture for a PDF page: IndexedDB copy first, network second, never throws. */
async function loadShot(path: string, ready?: Map<string, Blob>): Promise<Blob | null> {
  const safe = mediaPath(path);
  if (!safe) return null;
  try {
    const cached = ready?.get(safe) ?? (await readImage(safe));
    if (cached && cached.size > 32) return cached;
  } catch {
    /* fall through to the network */
  }
  try {
    const response = await fetch(mediaUrl(safe));
    if (!response.ok) return null;
    const blob = await response.blob();
    if (!isImageBlob(blob)) return null;
    void writeImage(safe, blob).catch(() => undefined);
    return blob;
  } catch {
    return null;
  }
}

function pdfName(title: string, fallback: string) {
  const clean = title.replace(/[\\/:*?"<>|]+/g, " ").replace(/\s+/g, " ").trim().slice(0, 70);
  return `${clean || fallback}.pdf`;
}

type PageSpec = BookPage & { path?: string | null };

async function renderSpecs(
  specs: PageSpec[],
  style: PdfStyle,
  report: (phase: "images" | "pages", done: number, total: number) => void,
  isCancelled: () => boolean,
  onPreview?: (blob: Blob) => void,
  onMissing?: (count: number) => void,
) {
  const total = Math.max(1, specs.length);
  report("pages", 0, total);
  // One IndexedDB read for every cached picture of the document.
  const ready = await readImages(specs.map((spec) => mediaPath(spec.path)).filter((path): path is string => Boolean(path))).catch(
    () => new Map<string, Blob>(),
  );
  if (isCancelled()) throw new DOMException("cancelled", "AbortError");
  const pages: BookPage[] = specs.map((spec) => ({
    title: spec.title,
    subtitle: spec.subtitle,
    body: spec.body,
    meta: spec.meta,
    imagePath: mediaPath(spec.path),
    cover: spec.cover,
    topicCover: spec.topicCover,
  }));
  const { buildBookPdf } = await import("@/lib/granth/pdf");
  return buildBookPdf(pages, style, {
    isCancelled,
    onPreview,
    onMissing,
    loadImage: (path) => loadShot(path, ready),
    onPage: (done, pagesTotal) => report("pages", done, pagesTotal),
  });
}

async function storePdf(blob: Blob, fileName: string, item: {
  id: string;
  title: string;
  text: string;
  topic: string;
  granth: string;
  preview?: Blob;
}) {
  if (blob.size < 64) throw new Error("PDF खाली रह गई");
  await saveGalleryItem({
    id: item.id,
    kind: "pdf",
    title: item.title,
    text: item.text,
    topic: item.topic,
    granth: item.granth,
    folderId: "",
    createdAt: Date.now(),
    size: blob.size,
    fileName,
    blob,
    preview: item.preview,
  });
}

function pramanSpec(praman: Praman): PageSpec {
  return {
    title: praman.title,
    subtitle: praman.topic_title,
    body: praman.description || praman.topic_title || praman.title,
    meta: [praman.granth_title, praman.granth_auther].filter(Boolean).join(" · "),
    path: praman.image_path,
  };
}

function coverSpecs(granth: Granth): PageSpec[] {
  const specs: PageSpec[] = [
    {
      title: granth.title,
      subtitle: granth.author,
      body: granth.description || granth.title,
      meta: "",
      path: granth.imagePath,
      cover: true,
    },
  ];
  if (mediaPath(granth.editorImagePath)) {
    specs.push({
      title: granth.title,
      subtitle: "प्रकाशन",
      body: granth.author ? `प्रकाशन · ${granth.author}` : "प्रकाशन विवरण",
      meta: "प्रकाशन विवरण",
      path: granth.editorImagePath,
      cover: true,
    });
  }
  return specs;
}

type PdfJob =
  | { kind: "granth"; granth: Granth }
  | { kind: "topic"; topic: Topic }
  | {
      kind: "praman";
      title: string;
      subtitle: string;
      body: string;
      meta: string;
      image: string;
      id: string;
      topic: string;
      granth: string;
      granthId?: string;
    };

function topicBundle(topic: Topic) {
  const state = useGranth.getState();
  const proofs = sortPramans(state.pramans.filter((praman) => praman.topic_id === topic.id));
  const byId = new Map(state.granths.map((granth) => [granth.id, granth]));
  const specs: PageSpec[] = [
    {
      title: topic.title,
      subtitle: "विषय",
      body: topic.description || "",
      meta: `${proofs.length} प्रमाण`,
      topicCover: true,
    },
  ];
  const granthIds: string[] = [];
  const seen = new Set<string>();
  for (const praman of proofs) {
    if (!seen.has(praman.granth_id)) {
      seen.add(praman.granth_id);
      granthIds.push(praman.granth_id);
      const granth = byId.get(praman.granth_id);
      if (granth) specs.push(...coverSpecs(granth));
    }
    specs.push(pramanSpec(praman));
  }
  return { proofs, specs, granthIds };
}

type PdfMeta = {
  /** One id for the queue entry and the gallery copy, so a PDF is never stored twice. */
  galleryId: string;
  title: string;
  fileName: string;
  topic: string;
  granth: string;
  granthId?: string;
  text: string;
  galleryText: string;
  granthIds: string[];
};

function runPdfJob(specs: PageSpec[], style: PdfStyle, meta: PdfMeta) {
  enqueuePdf({
    title: meta.title,
    fileName: meta.fileName,
    galleryId: meta.galleryId,
    topic: meta.topic,
    granth: meta.granth,
    granthId: meta.granthId,
    text: meta.text,
    run: async ({ report, isCancelled, setPreview, setMissing }) => {
      let preview: Blob | undefined;
      let missing = 0;
      const blob = await renderSpecs(
        specs,
        style,
        report,
        isCancelled,
        (shot) => {
          preview = shot;
          setPreview(shot);
        },
        (count) => {
          missing = count;
          setMissing(count);
        },
      );
      report("save", specs.length, specs.length);
      try {
        // The PDF lands in the app gallery automatically (the "सेव" button later just opens it there).
        await storePdf(blob, meta.fileName, {
          id: meta.galleryId,
          title: meta.title,
          text: meta.galleryText,
          topic: meta.topic,
          granth: meta.granth,
          preview,
        });
      } catch {
        /* the device copy is the one that must open, even if gallery storage is full */
      }
      // Only claim "offline" when every picture really made it into the PDF.
      if (missing === 0) markGranthsOffline(meta.granthIds);
      return blob;
    },
  });
}

function beginTopicsPdf(topics: Topic[], style: PdfStyle = savedPdfStyle()) {
  if (!topics.length) return;
  const bundles = topics.map(topicBundle);
  const specs = bundles.flatMap((bundle) => bundle.specs);
  const titles = topics.map((topic) => topic.title).join(" · ");
  const title = topics.length === 1 ? topics[0]?.title || "विषय" : `${topics.length} विषय`;
  const stamp = Date.now();
  runPdfJob(specs, style, {
    galleryId: topics.length === 1 ? `pdf-topic-${topics[0]?.id}` : `pdf-topics-${stamp}`,
    title,
    fileName: pdfName(title, topics.length === 1 ? `topic-${topics[0]?.id}` : `topics-${stamp}`),
    topic: titles,
    granth: "",
    text: [
      ...topics.map((topic) => topic.title),
      ...bundles.flatMap((bundle) => bundle.proofs.map((praman) => praman.title)),
    ]
      .filter(Boolean)
      .join("\n"),
    galleryText: topics.map((topic) => topic.description).filter(Boolean).join("\n"),
    granthIds: [...new Set(bundles.flatMap((bundle) => bundle.granthIds))],
  });
}

function beginPdf(job: PdfJob, style: PdfStyle) {
  if (job.kind === "granth") {
    const proofs = sortPramans(
      useGranth.getState().pramans.filter((praman) => praman.granth_id === job.granth.id),
      job.granth.title,
    );
    runPdfJob([...coverSpecs(job.granth), ...proofs.map(pramanSpec)], style, {
      galleryId: `pdf-granth-${job.granth.id}`,
      title: job.granth.title,
      fileName: pdfName(job.granth.title, `granth-${job.granth.id}`),
      topic: "",
      granth: job.granth.title,
      granthId: job.granth.id,
      text: [job.granth.description, ...proofs.map((praman) => praman.title)].filter(Boolean).join("\n"),
      galleryText: job.granth.description,
      granthIds: [job.granth.id],
    });
    return;
  }
  if (job.kind === "topic") {
    beginTopicsPdf([job.topic], style);
    return;
  }
  runPdfJob([{ title: job.title, subtitle: job.subtitle, body: job.body, meta: job.meta, path: job.image }], style, {
    galleryId: `pdf-${job.id}`,
    title: job.title,
    fileName: pdfName(job.title, job.id),
    topic: job.topic,
    granth: job.granth,
    granthId: job.granthId,
    text: job.body,
    galleryText: job.body,
    granthIds: [],
  });
}

let openPdfJob: ((job: PdfJob) => void) | null = null;

function askPdf(job: PdfJob) {
  if (openPdfJob) openPdfJob(job);
  else beginPdf(job, savedPdfStyle());
}

export function PdfHost() {
  const [job, setJob] = useState<PdfJob | null>(null);
  const [picked, setPicked] = useState<PdfStyle>("fill90");
  useEffect(() => {
    openPdfJob = (next) => {
      setPicked(savedPdfStyle());
      setJob(next);
    };
    return () => {
      openPdfJob = null;
    };
  }, []);
  useEffect(() => {
    if (!job) return;
    return pushCloser(() => setJob(null));
  }, [job]);
  if (!job) return null;
  return (
    <div className="pdf-pop" role="presentation" onClick={() => setJob(null)}>
      <div className="pdf-sheet" role="dialog" aria-modal="true" aria-label="PDF शैली" onClick={(event) => event.stopPropagation()}>
        <div className="pdf-sheet-head">
          <h3>PDF शैली</h3>
          <button type="button" className="pill" onClick={() => setJob(null)}>
            <X /> पीछे
          </button>
        </div>
        <div className="pdf-style-list">
          {PDF_STYLES.map((style) => (
            <button
              key={style.id}
              type="button"
              className={`pdf-style ${picked === style.id ? "on" : ""}`}
              onClick={() => setPicked(style.id)}
            >
              <strong>{style.title}</strong>
              <span>{style.hint}</span>
            </button>
          ))}
        </div>
        <div className="pdf-actions">
          <button type="button" className="pdf-back" onClick={() => setJob(null)}>
            पीछे
          </button>
          <button
            type="button"
            className="pdf-ok"
            onClick={() => {
              const current = job;
              rememberPdfStyle(picked);
              setJob(null);
              beginPdf(current, picked);
            }}
          >
            OK
          </button>
        </div>
      </div>
    </div>
  );
}

function GranthCard({
  granth,
  index,
  total,
  onOpen,
  onShare,
  onImage,
}: {
  granth: Granth;
  index: number;
  total: number;
  onOpen: () => void;
  onShare: () => void;
  onImage: () => void;
}) {
  const offline = useOfflineIds();
  const proofs = Number(granth.pramanCount) || 0;
  const link = granth.granthURL?.trim();
  return (
    <article className="card granth-card" data-granth={granth.id} aria-label={granth.title} {...bindOpen(onOpen)} {...cardKeys(onOpen)}>
      <div className="card-header">
        <h3 className="card-title">
          <span>
            <RichText text={granth.title} />
          </span>
        </h3>
      </div>
      {granth.author ? (
        <p className="author">
          <PenLine /> {granth.author}
        </p>
      ) : null}
      {granth.description ? (
        <p className="card-desc">
          <RichText text={granth.description} />
        </p>
      ) : null}
      <MediaImage
        path={granth.imagePath}
        alt={granth.title}
        className="cover"
        onView={onImage}
        save={{ title: granth.title, text: granth.description, topic: "", granth: granth.title }}
      />
      <div className="card-meta" onClick={(event) => event.stopPropagation()} onPointerUp={(event) => event.stopPropagation()}>
        {proofs > 0 ? (
          <button className="pill pill-maroon" type="button" onClick={onOpen}>
            <ImageIcon /> {proofs} <span className="pill-word">प्रमाण</span>
          </button>
        ) : null}
        <span className="pill">
          <Library /> {index}/{total}
        </span>
        <button
          className="pill"
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            onShare();
          }}
        >
          <Share2 /> शेयर
        </button>
        {link ? (
          <button
            className="pill"
            type="button"
            aria-label="ग्रंथ लिंक"
            onClick={(event) => {
              event.stopPropagation();
              openExternal(link);
            }}
          >
            मूल PDF
          </button>
        ) : null}
        <button
          className="pill pill-maroon"
          type="button"
          onClick={(event) => {
            event.stopPropagation();
            askPdf({ kind: "granth", granth });
          }}
        >
          हाईलाइट PDF
        </button>
        {offline.has(granth.id) ? <span className="pill">ऑफलाइन</span> : null}
      </div>
    </article>
  );
}

export function PramanScreen({
  route,
  go,
  onOpen,
}: {
  route: AppRoute;
  go: (hash: string) => void;
  onOpen: (paths: string[]) => void;
}) {
  const pramans = useGranth((state) => state.pramans);
  const topics = useGranth((state) => state.topics);
  const granths = useGranth((state) => state.granths);
  const [query, setQuery] = useState("");
  const search = useDeferredValue(query);
  const [cols, setCols] = useCols<1 | 2>("praman-cols", [1, 2], 2);
  const topic = topics.find((item) => item.id === route.topicId);
  const granth = granths.find((item) => item.id === route.granthId);
  const docs = useMemo(() => {
    const map = new Map<string, PreparedDoc>();
    for (const praman of pramans) {
      map.set(
        praman.id,
        prepareFields([
          praman.title,
          praman.description,
          praman.topic_title,
          praman.granth_title,
          praman.granth_auther,
          praman.youtube_desc,
        ]),
      );
    }
    return map;
  }, [pramans]);
  const filtered = useMemo(() => {
    const rows = pramans.filter((praman) => {
      if (route.topicId && praman.topic_id !== route.topicId) return false;
      if (route.granthId && praman.granth_id !== route.granthId) return false;
      if (route.pramanId && praman.id !== route.pramanId) return false;
      return true;
    });
    return sortPramans(rows, granth?.title ?? "");
  }, [granth?.title, pramans, route.granthId, route.pramanId, route.topicId]);
  const ranked = useMemo(
    () => rankPrepared(filtered, search, (praman) => docs.get(praman.id) ?? prepareFields([praman.title])),
    [docs, filtered, search],
  );
  const listKey = `praman-list:${route.granthId ?? ""}:${route.topicId ?? ""}`;
  const memory = useRememberList(listKey, !route.pramanId, search);
  const resetKey = `${search}|${cols}|${route.topicId ?? ""}|${route.granthId ?? ""}|${route.pramanId ?? ""}`;
  const step = cols === 1 ? 8 : 12;
  const { count, ref } = useSlice(resetKey, ranked.length, step, memory.keep);
  memory.track(count, ranked.length);

  return (
    <section>
      <header className="page-header sticky-bar">
        <div className="page-title">
          <IconBox tone="gold">
            <ImageIcon />
          </IconBox>
          <div>
            <h2>प्रमाण</h2>
            <p className="subtitle">शास्त्र प्रमाण</p>
          </div>
        </div>
        <div className="granth-tools">
          <div className="grid-switch" role="group" aria-label="प्रमाण ग्रिड">
            {([1, 2] as const).map((size) => (
              <button
                key={size}
                type="button"
                className={cols === size ? "active" : ""}
                aria-pressed={cols === size}
                onClick={() => setCols(size)}
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
              aria-label="प्रमाण खोजें"
              placeholder="प्रमाण खोजें — mans, मृत्यु"
              onChange={(event) => setQuery(event.target.value)}
            />
          </form>
        </div>
      </header>
      {topic || granth ? (
        <div className="filter-banner">
          <p>
            {topic ? (
              <>
                <b>विषय:</b> {topic.title}
              </>
            ) : null}
            {granth ? (
              <>
                <b>ग्रंथ:</b> {granth.title}
              </>
            ) : null}
          </p>
          <button className="pill" type="button" onClick={() => go("#/pramans")}>
            सभी प्रमाण
          </button>
        </div>
      ) : null}
      <div className={`card-grid praman-grid cols-${cols}`}>
        {ranked.slice(0, count).map((praman, index) => (
          <PramanCard
            key={praman.id}
            praman={praman}
            index={index + 1}
            total={ranked.length}
            onOpen={onOpen}
            onTopic={() => go(`#/pramans?topic=${praman.topic_id}`)}
            onGranth={() => go(`#/pramans?granth=${praman.granth_id}`)}
            onShare={() => void shareLink(praman.title, `#/pramans?id=${praman.id}`)}
          />
        ))}
      </div>
      {ranked.length === 0 ? (
        search.trim() ? (
          <Empty title="कोई परिणाम नहीं" body={`“${search.trim()}” से कोई प्रमाण नहीं मिला। दूसरा शब्द आज़माएँ।`} />
        ) : (
          <Empty title="कोई प्रमाण नहीं" body="इस चयन में प्रमाण नहीं मिले, या सिंक अभी चल रहा है।" />
        )
      ) : null}
      <div ref={ref} className="scroll-sentinel" />
    </section>
  );
}

function PramanCard({
  praman,
  index,
  total,
  onOpen,
  onTopic,
  onGranth,
  onShare,
}: {
  praman: Praman;
  index: number;
  total: number;
  onOpen: (paths: string[]) => void;
  onTopic: () => void;
  onGranth: () => void;
  onShare: () => void;
}) {
  const [play, setPlay] = useState(false);
  const video = youtubeId(praman.youtube_url);
  const shots = [praman.image_path, praman.granth_image, praman.editorImagePath]
    .map(mediaPath)
    .filter((value): value is string => Boolean(value));
  const start = Number(praman.youtube_start) || 0;
  return (
    <article className="card praman-card">
      <div className="praman-body">
        <div className="thumb-row">
          <MediaImage
            path={praman.granth_image}
            alt={praman.granth_title ? `${praman.granth_title} — आवरण` : "ग्रंथ आवरण"}
            className="thumb"
            onClick={() => onOpen(shots)}
            save={{ title: praman.granth_title, text: praman.title, topic: praman.topic_title, granth: praman.granth_title }}
          />
          <MediaImage
            path={praman.editorImagePath}
            alt={praman.granth_title ? `${praman.granth_title} — प्रकाशन` : "प्रकाशन विवरण"}
            className="thumb"
            onClick={() => onOpen(shots)}
          />
          {praman.is_favorate === "1" ? <span className="fav">मुख्य</span> : null}
        </div>
        <h3 className="card-title">
          <RichText text={praman.title} />
        </h3>
        {praman.description ? (
          <p className="card-desc">
            <RichText text={praman.description} />
          </p>
        ) : null}
      </div>
      <MediaImage
        path={praman.image_path}
        alt={praman.title}
        className="proof"
        onClick={() => onOpen(shots)}
        save={{ title: praman.title, text: praman.description, topic: praman.topic_title, granth: praman.granth_title }}
      />
      {video ? (
        <div className="video-block">
          {play ? (
            <iframe
              title={praman.title}
              src={`https://www.youtube.com/embed/${video}${start ? `?start=${start}` : ""}`}
              allow="accelerometer; autoplay; clipboard-write; encrypted-media; gyroscope; picture-in-picture"
              allowFullScreen
            />
          ) : (
            <button className="pill pill-maroon" type="button" onClick={() => setPlay(true)}>
              वीडियो चलाएँ {start ? `(${start}s)` : ""}
            </button>
          )}
          {praman.youtube_desc ? <p className="card-desc">{praman.youtube_desc}</p> : null}
          <p className="fine">वीडियो चलाने के लिए इंटरनेट चाहिए। पेज की तस्वीर ऑफलाइन रहती है।</p>
        </div>
      ) : null}
      <div className="praman-body">
        <div className="card-meta">
          {praman.topic_title ? (
            <button className="pill pill-topic" type="button" onClick={onTopic}>
              {praman.topic_title}
            </button>
          ) : null}
          {praman.granth_title ? (
            <button className="pill" type="button" onClick={onGranth}>
              <Library /> {praman.granth_title}
            </button>
          ) : null}
          <span className="pill">
            <Library /> {index}/{total}
          </span>
          <button className="pill" type="button" onClick={onShare}>
            <Share2 /> शेयर
          </button>
          <button
            className="pill pill-maroon"
            type="button"
            onClick={() =>
              askPdf({
                kind: "praman",
                title: praman.title,
                subtitle: praman.granth_title,
                body: praman.description,
                meta: praman.topic_title,
                image: praman.image_path,
                id: `praman-${praman.id}`,
                topic: praman.topic_title,
                granth: praman.granth_title,
                granthId: praman.granth_id,
              })
            }
          >
            PDF
          </button>
        </div>
      </div>
    </article>
  );
}

function Empty({ title, body }: { title: string; body: string }) {
  return (
    <div className="empty">
      <h3>{title}</h3>
      <p>{body}</p>
    </div>
  );
}

export function Lightbox({ paths, onClose }: { paths: string[]; onClose: () => void }) {
  useEffect(() => {
    return pushCloser(onClose);
  }, [onClose]);
  return (
    <div className="lightbox" role="dialog" aria-modal="true" aria-label="प्रमाण चित्र">
      <button className="lightbox-close" type="button" onClick={onClose}>
        <X /> बंद
      </button>
      <div className="lightbox-scroll" tabIndex={-1}>
        {paths.map((path) => (
          <PinchView key={path}>
            <MediaImage path={path} alt="प्रमाण" className="lightbox-img" eager />
          </PinchView>
        ))}
      </div>
    </div>
  );
}
