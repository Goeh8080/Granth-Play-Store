import { ClipboardList, Image as ImageIcon, Images, Landmark, Library, Menu, RefreshCw, Settings, X } from "lucide-react";
import { useEffect, useRef, useState } from "react";
import { closeTop, pushCloser } from "@/lib/granth/back";
import { deliverFile, exitNativeApp, ping, type ToastPayload } from "@/lib/granth/files";
import { imageProgressLabel } from "@/lib/granth/offline-plan";
import { useGranth } from "@/lib/granth/store";
import type { AppRoute, Panel } from "@/lib/granth/types";
import { Dashboard, GranthScreen, Lightbox, PdfHost, PramanScreen, TopicScreen, captureListPlace } from "./screens";
import { GalleryScreen } from "./gallery";
import { PdfDock } from "./pdf-tray";
import { applySavedLook, SettingsSheet } from "./settings";
import { MalaMark, ScrollRail } from "./ui";

const NAV: Array<{ panel: Panel; hash: string; label: string; icon: typeof Landmark }> = [
  { panel: "dashboard", hash: "#/dashboard", label: "मुख्य पृष्ठ", icon: Landmark },
  { panel: "topics", hash: "#/topics", label: "विषय", icon: ClipboardList },
  { panel: "granths", hash: "#/granths", label: "ग्रंथ", icon: Library },
  { panel: "pramans", hash: "#/pramans", label: "प्रमाण", icon: ImageIcon },
];

function parseHash(hash: string): AppRoute {
  const raw = hash.replace(/^#/, "") || "/dashboard";
  const [pathPart, queryPart] = raw.split("?");
  const path = pathPart || "/dashboard";
  const params = new URLSearchParams(queryPart ?? "");
  const topicId = params.get("topic") || undefined;
  const granthId = params.get("granth") || undefined;
  const pramanId = params.get("id") || undefined;
  if (path.startsWith("/gallery")) return { panel: "gallery" };
  if (path.startsWith("/topics")) return { panel: "topics" };
  if (path.startsWith("/granths")) return { panel: "granths" };
  if (path.startsWith("/pramans")) return { panel: "pramans", topicId, granthId, pramanId };
  return { panel: "dashboard" };
}

function replaceHash(hash: string) {
  const next = hash.startsWith("#") ? hash : `#${hash}`;
  const url = `${window.location.pathname}${window.location.search}${next}`;
  const changed = window.location.hash !== next;
  history.replaceState({ granth: 1 }, "", url);
  if (changed) window.dispatchEvent(new HashChangeEvent("hashchange"));
}

function formatWhen(stamp: number | null): string {
  if (!stamp) return "";
  return new Intl.DateTimeFormat("hi-IN", {
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
  }).format(stamp);
}

/** Exit button of the exit dialog. A web page cannot close its own tab, so say so instead of doing nothing. */
function leaveApp(close: () => void) {
  if (exitNativeApp()) return;
  close();
  ping("ब्राउज़र में ऐप बंद करने के लिए यह टैब बंद करें");
}

/** Full catalog pull is ~1 MB: do it on resume/online and every 15 minutes, not every 3. */
const SYNC_EVERY_MS = 15 * 60 * 1000;
const RESUME_MIN_GAP_MS = 2 * 60 * 1000;

export function GranthApp() {
  const boot = useGranth((state) => state.boot);
  const sync = useGranth((state) => state.sync);
  const savePages = useGranth((state) => state.savePages);
  const topics = useGranth((state) => state.topics.length);
  const granths = useGranth((state) => state.granths.length);
  const pramans = useGranth((state) => state.pramans.length);
  const status = useGranth((state) => state.status);
  const syncedAt = useGranth((state) => state.syncedAt);
  const online = useGranth((state) => state.online);
  const error = useGranth((state) => state.error);
  const images = useGranth((state) => state.images);
  const [route, setRoute] = useState<AppRoute>({ panel: "dashboard" });
  const [menuOpen, setMenuOpen] = useState(false);
  const [shots, setShots] = useState<string[] | null>(null);
  const [toast, setToast] = useState<ToastPayload | null>(null);
  const [showTop, setShowTop] = useState(false);
  const [exitAsk, setExitAsk] = useState(false);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const navStack = useRef<string[]>([]);
  const lastSync = useRef(Date.now());
  const lastBack = useRef(0);
  const lastDash = useRef(0);
  const skipPop = useRef(0);
  const pendingHash = useRef("");
  const exitAskRef = useRef(false);
  exitAskRef.current = exitAsk;

  const saveNav = () => {
    try {
      localStorage.setItem("granth-nav", JSON.stringify(navStack.current.slice(-24)));
    } catch {
      /* ignore */
    }
  };

  useEffect(() => {
    applySavedLook();
    navStack.current = [];
    try {
      localStorage.removeItem("granth-nav");
    } catch {
      /* ignore */
    }
    if (!window.location.hash) {
      const saved = localStorage.getItem("granth-hash");
      if (saved?.startsWith("#/")) replaceHash(saved);
    }
    const read = () => {
      const hash = window.location.hash || "#/dashboard";
      try {
        localStorage.setItem("granth-hash", hash);
      } catch {
        /* ignore */
      }
      setRoute(parseHash(hash));
    };
    read();
    window.addEventListener("hashchange", read);
    return () => window.removeEventListener("hashchange", read);
  }, []);

  useEffect(() => {
    void boot();
    const onOnline = () => {
      useGranth.setState({ online: true });
    };
    const onOffline = () => {
      useGranth.setState({
        online: false,
        status: useGranth.getState().syncedAt ? "offline" : "error",
      });
    };
    window.addEventListener("online", onOnline);
    window.addEventListener("offline", onOffline);
    const onResume = () => {
      const now = Date.now();
      if (now - lastSync.current < RESUME_MIN_GAP_MS) return;
      lastSync.current = now;
      void sync().then(() => savePages());
    };
    window.addEventListener("granth-resume", onResume);
    const onVisible = () => {
      if (document.visibilityState === "visible") onResume();
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => {
      window.removeEventListener("online", onOnline);
      window.removeEventListener("offline", onOffline);
      window.removeEventListener("granth-resume", onResume);
      document.removeEventListener("visibilitychange", onVisible);
    };
  }, [boot, savePages, sync]);

  useEffect(() => {
    const tick = () => {
      if (!navigator.onLine) return;
      lastSync.current = Date.now();
      void sync().then(() => savePages());
    };
    const timer = window.setInterval(tick, SYNC_EVERY_MS);
    window.addEventListener("online", tick);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("online", tick);
    };
  }, [savePages, sync]);

  const toastTimer = useRef<number | null>(null);
  useEffect(() => {
    const onToast = (event: Event) => {
      const detail = (event as CustomEvent<ToastPayload>).detail;
      setToast(detail);
      if (toastTimer.current) window.clearTimeout(toastTimer.current);
      toastTimer.current = window.setTimeout(() => setToast(null), detail.file ? 14000 : 2400);
    };
    window.addEventListener("granth-toast", onToast);
    return () => window.removeEventListener("granth-toast", onToast);
  }, []);

  useEffect(() => {
    const host = window as unknown as {
      __granthBack?: () => void;
      __granthOpenLink?: (hash: string) => void;
    };
    host.__granthBack = () => {
      const active = document.activeElement as HTMLElement | null;
      const typing = Boolean(active && (active.tagName === "INPUT" || active.tagName === "TEXTAREA" || active.isContentEditable));
      if (typing) {
        active?.blur();
        return;
      }
      pendingHash.current = "";
      skipPop.current = 0;
      const now = Date.now();
      if (closeTop()) return;
      if (exitAskRef.current) {
        setExitAsk(false);
        return;
      }
      const here = window.location.hash || "#/dashboard";
      const onDash = here === "#/dashboard" || here === "#/" || here === "";
      if (onDash) {
        navStack.current = [];
        saveNav();
        if (now - lastDash.current > 80 && now - lastDash.current < 900) setExitAsk(true);
        else lastDash.current = now;
        return;
      }
      if (now - lastBack.current < 260) return;
      lastBack.current = now;
      captureListPlace();
      while (navStack.current.length) {
        const prev = navStack.current.pop();
        if (!prev || prev === here) continue;
        const dash = prev === "#/dashboard" || prev === "#/" || prev.startsWith("#/dashboard");
        if (dash) navStack.current = [];
        saveNav();
        replaceHash(dash ? "#/dashboard" : prev);
        return;
      }
      navStack.current = [];
      saveNav();
      replaceHash("#/dashboard");
    };
    host.__granthOpenLink = (hash: string) => {
      const stamp = host as { __granthLinkHash?: string; __granthLinkAt?: number };
      const now = Date.now();
      if (stamp.__granthLinkHash === hash && now - (stamp.__granthLinkAt || 0) < 5000) return;
      stamp.__granthLinkHash = hash;
      stamp.__granthLinkAt = now;
      pendingHash.current = hash;
      skipPop.current = now + 800;
      const current = window.location.hash || "#/dashboard";
      if (current !== hash) navStack.current.push(current);
      saveNav();
      replaceHash(hash);
    };
    const queued = (window as unknown as { __granthPendingHash?: string }).__granthPendingHash;
    if (queued) {
      (window as unknown as { __granthPendingHash?: string }).__granthPendingHash = "";
      host.__granthOpenLink?.(queued);
    }
    const trap = () => {
      history.replaceState({ granth: 1 }, "", window.location.href);
    };
    trap();
    const onPop = () => {
      const want = pendingHash.current;
      if (want && Date.now() < skipPop.current) {
        trap();
        if ((window.location.hash || "#/dashboard") !== want) replaceHash(want);
        return;
      }
      trap();
      host.__granthBack?.();
    };
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, []);

  useEffect(() => {
    if (!menuOpen) return;
    return pushCloser(() => setMenuOpen(false));
  }, [menuOpen]);

  useEffect(() => {
    if (!settingsOpen) return;
    return pushCloser(() => setSettingsOpen(false));
  }, [settingsOpen]);

  useEffect(() => {
    if (!shots) return;
    return pushCloser(() => setShots(null));
  }, [shots]);

  useEffect(() => {
    setMenuOpen(false);
    if (route.panel === "dashboard" || route.panel === "gallery" || route.pramanId) window.scrollTo({ top: 0 });
  }, [route.panel, route.topicId, route.granthId, route.pramanId]);

  useEffect(() => {
    const onScroll = () => setShowTop(window.scrollY > 480);
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  const lastGo = useRef({ hash: "", at: 0 });
  const go = (hash: string) => {
    const now = Date.now();
    if (lastGo.current.hash === hash && now - lastGo.current.at < 400) return;
    lastGo.current = { hash, at: now };
    const until = now + 500;
    const stopGhost = (event: Event) => {
      window.removeEventListener("click", stopGhost, true);
      if (Date.now() > until) return;
      event.preventDefault();
      event.stopPropagation();
    };
    window.addEventListener("click", stopGhost, true);
    pendingHash.current = hash;
    skipPop.current = now + 450;
    const granthId = new URLSearchParams((hash.split("?")[1] || "").split("#")[0]).get("granth") || "";
    captureListPlace(granthId ? { id: granthId } : undefined);
    const current = window.location.hash || "#/dashboard";
    if (current === hash) {
      setRoute(parseHash(hash));
      return;
    }
    const roots = new Set(["#/dashboard", "#/topics", "#/granths", "#/pramans", "#/gallery"]);
    if (hash === "#/dashboard" || hash === "#/") {
      navStack.current = [];
    } else if (roots.has(hash)) {
      navStack.current = ["#/dashboard"];
    } else if (current === "#/dashboard" || current === "#/" || current === "") {
      navStack.current = ["#/dashboard"];
    } else if (navStack.current[navStack.current.length - 1] !== current) {
      navStack.current.push(current);
    }
    saveNav();
    replaceHash(hash);
  };

  const goRef = useRef(go);
  goRef.current = go;
  useEffect(() => {
    // In-app links from components that do not get `go` (e.g. "गैलरी में देखें" in the PDF dialog).
    const onGo = (event: Event) => {
      const hash = (event as CustomEvent<string>).detail;
      if (typeof hash === "string" && hash.startsWith("#/")) goRef.current(hash);
    };
    window.addEventListener("granth-go", onGo);
    return () => window.removeEventListener("granth-go", onGo);
  }, []);

  const headerOn = (which: "topics" | "granths" | "pramans") => {
    if (which === "topics") return route.panel === "topics" || (route.panel === "pramans" && Boolean(route.topicId) && !route.granthId);
    if (which === "granths") return route.panel === "granths" || (route.panel === "pramans" && Boolean(route.granthId));
    return route.panel === "pramans" && !route.topicId && !route.granthId;
  };

  const imageLabel = imageProgressLabel(images, status === "syncing");

  return (
    <div className="app-root">
      <header className="mast">
        <div className="mast-gold" />
        <div className="mast-row">
          <div className="brand-row">
            <div className="brand">
              <button className="logo-icon" type="button" aria-label="ग्रंथ प्रबंधन" onClick={() => go("#/dashboard")}>
                <MalaMark />
              </button>
              <button className="brand-title" type="button" onClick={() => go("#/dashboard")}>
                <h1>ग्रंथ प्रबंधन</h1>
              </button>
            </div>
            <div className="mast-tools">
              <PdfDock />
              <button className="gallery-btn" type="button" aria-label="गैलरी" onClick={() => go("#/gallery")}>
                <Images />
              </button>
              <button className="gallery-btn" type="button" aria-label="सेटिंग" onClick={() => setSettingsOpen(true)}>
                <Settings />
              </button>
            </div>
          </div>
          <div className="stats-bar">
            <button type="button" className={`stat-item ${headerOn("topics") ? "active" : ""}`} onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/topics"); }} onClick={() => go("#/topics")}>
              <span className="stat-num">{topics || "—"}</span>
              <span className="stat-label">विषय / प्रश्नोत्तरी</span>
            </button>
            <button type="button" className={`stat-item ${headerOn("granths") ? "active" : ""}`} onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/granths"); }} onClick={() => go("#/granths")}>
              <span className="stat-num">{granths || "—"}</span>
              <span className="stat-label">पवित्र ग्रन्थ</span>
            </button>
            <button type="button" className={`stat-item ${headerOn("pramans") ? "active" : ""}`} onPointerUp={(event) => { if (event.pointerType !== "mouse") go("#/pramans"); }} onClick={() => go("#/pramans")}>
              <span className="stat-num">{pramans || "—"}</span>
              <span className="stat-label">नए प्रमाण</span>
            </button>
          </div>
        </div>
      </header>

      <button
        className={`hamburger ${menuOpen ? "open" : ""}`}
        type="button"
        aria-label={menuOpen ? "मेनू बंद करें" : "मेनू खोलें"}
        aria-expanded={menuOpen}
        onClick={() => setMenuOpen((open) => !open)}
      >
        {menuOpen ? <X /> : <Menu />}
      </button>

      <nav className={menuOpen ? "open" : ""}>
        <ul className="nav-menu">
          {NAV.map((item) => {
            const Icon = item.icon;
            const active = route.panel === item.panel;
            return (
              <li key={item.panel}>
                <button
                  type="button"
                  className={`nav-btn ${active ? "active" : ""}`}
                  aria-current={active ? "page" : undefined}
                  onClick={() => go(item.hash)}
                >
                  <Icon /> {item.label}
                </button>
              </li>
            );
          })}
        </ul>
      </nav>

      <div className={`sync-strip ${status}`}>
        <p role="status" aria-live="polite">
          <span className={`dot ${online ? "on" : "off"}`} />
          {status === "syncing"
            ? "ऑनलाइन सिंक हो रहा है — सूची डिवाइस पर लिखी जा रही है"
            : error
              ? error
              : !online
                ? "इंटरनेट नहीं · सेव किया डेटा चल रहा है"
                : `ऑफलाइन तैयार${syncedAt ? ` · ${formatWhen(syncedAt)}` : ""}`}
          {imageLabel ? ` · ${imageLabel}` : ""}
        </p>
        <button
          className="sync-btn"
          type="button"
          onClick={() => {
            lastSync.current = Date.now();
            void sync().then(() => savePages());
          }}
          disabled={status === "syncing"}
        >
          <RefreshCw className={status === "syncing" ? "spin" : ""} />
          सिंक
        </button>
      </div>

      <main className="screen-in" key={`${route.panel}:${route.topicId || ""}:${route.granthId || ""}:${route.pramanId || ""}`}>
        {status === "booting" && topics + granths + pramans === 0 ? (
          <div className="loading">
            <div className="spinner" />
            <p>सेव की हुई प्रति खोली जा रही है…</p>
          </div>
        ) : null}
        {error && status === "error" && topics + granths + pramans === 0 ? (
          <div className="empty">
            <h3>अभी खाली है</h3>
            <p>{error}</p>
          </div>
        ) : null}
        {route.panel === "dashboard" ? <Dashboard go={go} /> : null}
        {route.panel === "topics" ? <TopicScreen go={go} /> : null}
        {route.panel === "granths" ? <GranthScreen go={go} onOpen={setShots} /> : null}
        {route.panel === "pramans" ? <PramanScreen route={route} go={go} onOpen={setShots} /> : null}
        {route.panel === "gallery" ? <GalleryScreen /> : null}
      </main>

      <ScrollRail hidden={Boolean(shots || settingsOpen || exitAsk)} />
      {showTop ? (
        <button className="to-top" type="button" aria-label="सबसे ऊपर जाएँ" onClick={() => window.scrollTo({ top: 0, behavior: "smooth" })}>
          ऊपर
        </button>
      ) : null}
      {/* Always mounted so screen readers announce every new message. */}
      <div className={toast ? "toast show" : "toast-idle"} role="status" aria-live="polite">
        {toast ? (
          <>
            <span>{toast.message}</span>
            {toast.file ? (
              <button
                type="button"
                onClick={() => {
                  if (toast.file) void deliverFile(toast.file.blob, toast.file.name);
                }}
              >
                डाउनलोड
              </button>
            ) : null}
          </>
        ) : null}
      </div>
      {shots ? <Lightbox paths={shots} onClose={() => setShots(null)} /> : null}
      {settingsOpen ? <SettingsSheet onClose={() => setSettingsOpen(false)} /> : null}
      {exitAsk ? (
        <div className="pdf-pop" role="presentation" onClick={() => setExitAsk(false)}>
          <div className="exit-card" role="dialog" aria-modal="true" aria-labelledby="exit-title" onClick={(event) => event.stopPropagation()}>
            <h3 id="exit-title">क्या आप बाहर निकलना चाहते हैं?</h3>
            <p>ऐप बंद होगा। सेव किए हुए ग्रंथ और PDF फ़ोन पर रहेंगे।</p>
            <div className="pdf-actions">
              <button type="button" className="pdf-ok" onClick={() => leaveApp(() => setExitAsk(false))}>
                हाँ, बाहर जाएँ
              </button>
              <button type="button" className="pdf-back" onClick={() => setExitAsk(false)}>
                नहीं, यहीं रहें
              </button>
            </div>
          </div>
        </div>
      ) : null}
      <PdfHost />
    </div>
  );
}
