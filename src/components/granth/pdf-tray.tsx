import { ChevronDown, ChevronLeft, ChevronRight, Images, Share2, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { deliverFile, inNativeApp, openBlob, shareBlob } from "@/lib/granth/files";
import { pushCloser } from "@/lib/granth/back";
import {
  cancelPdf,
  formatBytes,
  formatClock,
  formatEta,
  listenPdfReady,
  usePdfTasks,
  type PdfTask,
} from "@/lib/granth/pdf-jobs";

/** Every finished PDF is already stored in the app gallery; this just takes the user there. */
function showInGallery() {
  // Go through the app's own navigation (a raw location.hash change would be read as Back).
  window.dispatchEvent(new CustomEvent("granth-go", { detail: "#/gallery" }));
}

function pdfFacts(task: PdfTask, now: number) {
  const end = task.finishedAt || (task.phase === "done" ? now : now);
  const elapsed = formatClock(Math.max(0, end - task.startedAt));
  const pages =
    task.phase === "pages" || task.phase === "done"
      ? `${task.phase === "done" ? task.total : task.done}/${task.total} पृष्ठ`
      : task.phase === "images"
        ? `${task.done}/${task.total} चित्र`
        : "";
  return [pages, `${elapsed} लगे`, formatEta(task.etaMs, task.phase)].filter(Boolean).join(" · ");
}

function live(task: PdfTask) {
  return task.phase === "queue" || task.phase === "images" || task.phase === "pages" || task.phase === "save";
}

export function PdfDock() {
  const tasks = usePdfTasks();
  const [open, setOpen] = useState(false);
  const [index, setIndex] = useState(0);
  const [ready, setReady] = useState<PdfTask | null>(null);
  const [onDevice, setOnDevice] = useState<"saving" | "saved" | "failed">("saving");
  const [sharing, setSharing] = useState(false);
  const [now, setNow] = useState(() => Date.now());
  const openedFor = useRef("");
  useEffect(() => {
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, []);
  useEffect(
    () =>
      listenPdfReady((task) => {
        setReady(task);
        setOpen(false);
        setOnDevice("saving");
        if (!task.blob) return;
        // Resolves only after the native side really wrote the file (or the browser download started).
        void deliverFile(task.blob, task.fileName).then((reply) => setOnDevice(reply.ok ? "saved" : "failed"));
      }),
    [],
  );
  useEffect(() => {
    const current = tasks.find((item) => live(item));
    if (!current || openedFor.current === current.id) return;
    openedFor.current = current.id;
    const at = tasks.findIndex((item) => item.id === current.id);
    if (at >= 0) setIndex(at);
    setOpen(true);
  }, [tasks]);
  useEffect(() => {
    if (!ready) return;
    return pushCloser(() => setReady(null));
  }, [ready]);
  useEffect(() => {
    if (!open) return;
    return pushCloser(() => setOpen(false));
  }, [open]);
  useEffect(() => {
    if (index > tasks.length - 1) setIndex(Math.max(0, tasks.length - 1));
  }, [index, tasks.length]);
  const task = tasks[index];
  const active = tasks.filter((item) => live(item)).length;
  const shareNow = (item: PdfTask) => {
    if (!item.blob || sharing) return;
    setSharing(true);
    void shareBlob(item.blob, item.fileName).finally(() => setSharing(false));
  };
  return (
    <>
      {tasks.length ? (
        <div className="pdf-anchor">
          <button
            className={`pdf-arrow${open ? " open" : ""}`}
            type="button"
            aria-expanded={open}
            aria-label="PDF प्रगति"
            onClick={() => setOpen((value) => !value)}
          >
            <ChevronDown />
            {active ? <span>{active}</span> : null}
          </button>
          {open && task ? (
            <div className="pdf-pop" role="presentation" onClick={() => setOpen(false)}>
              <div className="pdf-deck pdf-deck-center" role="dialog" aria-modal="true" aria-label="PDF प्रगति" onClick={(event) => event.stopPropagation()}>
                <div className="pdf-deck-top">
                  <strong>
                    {index + 1}/{tasks.length}
                  </strong>
                  <span>{task.percent}%</span>
                </div>
                <h3>{task.title}</h3>
                <div className="pdf-meter" role="progressbar" aria-valuemin={0} aria-valuemax={100} aria-valuenow={task.percent} aria-label="PDF प्रगति">
                  <span style={{ width: `${task.percent}%` }} />
                </div>
                <p>{pdfFacts(task, now)}</p>
                <p>{task.error || `${task.percent}% · ${task.phase === "images" ? "चित्र बन रहे हैं" : task.phase === "pages" ? "पृष्ठ जुड़ रहे हैं" : task.phase === "save" ? "सेव हो रहा है" : task.phase === "done" ? "तैयार" : "कतार में"}`}</p>
                <div className="pdf-deck-nav">
                  <button type="button" className="pill" onClick={() => setOpen(false)}>
                    बंद
                  </button>
                  <button type="button" className="pill" disabled={index <= 0} onClick={() => setIndex((value) => Math.max(0, value - 1))}>
                    <ChevronLeft /> पिछला
                  </button>
                  <button
                    type="button"
                    className="pill"
                    disabled={index >= tasks.length - 1}
                    onClick={() => setIndex((value) => Math.min(tasks.length - 1, value + 1))}
                  >
                    अगला <ChevronRight />
                  </button>
                </div>
                {live(task) ? (
                  <button type="button" className="pdf-back" onClick={() => cancelPdf(task.id)}>
                    रोकें
                  </button>
                ) : null}
                {task.blob && task.phase === "done" ? (
                  <div className="pdf-actions">
                    <button type="button" className="pdf-ok" onClick={() => void openBlob(task.blob as Blob, task.fileName)}>
                      PDF खोलें
                    </button>
                    <button type="button" className="pdf-back" disabled={sharing} onClick={() => shareNow(task)}>
                      <Share2 /> {sharing ? "खुल रहा है…" : "शेयर"}
                    </button>
                    <button type="button" className="pdf-back" onClick={() => { setOpen(false); showInGallery(); }}>
                      <Images /> गैलरी में देखें
                    </button>
                  </div>
                ) : null}
              </div>
            </div>
          ) : null}
        </div>
      ) : null}
      {ready?.blob ? (
        <div className="pdf-pop" role="presentation" onClick={() => setReady(null)}>
          <div className="pdf-done" role="dialog" aria-modal="true" aria-label="PDF तैयार" onClick={(event) => event.stopPropagation()}>
            <button className="pill pdf-done-x" type="button" onClick={() => setReady(null)}>
              <X /> पीछे
            </button>
            <h3>{ready.fileName}</h3>
            <p>
              {ready.total} पृष्ठ · {formatClock(Math.max(0, (ready.finishedAt || now) - ready.startedAt))} · {formatBytes(ready.size || ready.blob.size)}
            </p>
            <p role="status" aria-live="polite">
              {onDevice === "saved"
                ? inNativeApp()
                  ? "Downloads और फ़ाइल मैनेजर में सेव हो गया · ऐप गैलरी में भी है"
                  : "डाउनलोड हो गया · ऐप गैलरी में भी है"
                : onDevice === "failed"
                  ? "फ़ोन में सेव नहीं हुआ — ऐप गैलरी में है, वहाँ से फिर सेव करें"
                  : "डिवाइस में सेव हो रहा है…"}
            </p>
            {ready.missing ? <p className="pdf-warn">{ready.missing} चित्र नहीं मिले — उनकी जगह सूचना पेज लगाया है</p> : null}
            <div className="pdf-actions">
              <button type="button" className="pdf-ok" onClick={() => void openBlob(ready.blob as Blob, ready.fileName)}>
                PDF खोलें
              </button>
              <button type="button" className="pdf-back" disabled={sharing} onClick={() => shareNow(ready)}>
                <Share2 /> {sharing ? "खुल रहा है…" : "शेयर"}
              </button>
              <button type="button" className="pdf-back" onClick={() => { setReady(null); showInGallery(); }}>
                <Images /> गैलरी में देखें
              </button>
            </div>
          </div>
        </div>
      ) : null}
    </>
  );
}
