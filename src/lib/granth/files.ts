export type ToastFile = {
  blob: Blob;
  name: string;
};

export type ToastPayload = {
  message: string;
  file?: ToastFile;
};

export function ping(message: string | ToastPayload) {
  const detail: ToastPayload = typeof message === "string" ? { message } : message;
  window.dispatchEvent(new CustomEvent("granth-toast", { detail }));
}

type NativeBridge = { postMessage: (message: string) => void };

/** What the Android shell answers for every file request. */
export type NativeReply = { ok: boolean; error?: string; uri?: string };

type GranthWindow = Window & {
  /** Token-checked bridge installed by the Android shell (main frame only). */
  __granthNative?: NativeBridge;
  ReactNativeWebView?: NativeBridge;
  __granthReply?: (id: string, reply: NativeReply) => void;
};

/** The Android app bridge, or null on the web. */
export function nativeBridge(): NativeBridge | null {
  if (typeof window === "undefined") return null;
  const host = window as GranthWindow;
  const bridge = host.__granthNative ?? host.ReactNativeWebView;
  return bridge && typeof bridge.postMessage === "function" ? bridge : null;
}

export function inNativeApp() {
  return nativeBridge() !== null;
}

const replies = new Map<string, (reply: NativeReply) => void>();

function installReply() {
  const host = window as GranthWindow;
  if (host.__granthReply) return;
  host.__granthReply = (id, reply) => {
    const done = replies.get(id);
    if (!done) return;
    replies.delete(id);
    done(reply);
  };
}

let seq = 0;
function requestId() {
  seq += 1;
  return `${Date.now().toString(36)}-${seq}`;
}

/** Send one request to the Android shell and wait for its answer. */
function callNative(message: Record<string, unknown>, timeoutMs: number): Promise<NativeReply> {
  const bridge = nativeBridge();
  if (!bridge) return Promise.resolve({ ok: false, error: "no-bridge" });
  installReply();
  const reqId = (message.reqId as string) || requestId();
  return new Promise<NativeReply>((resolve) => {
    const timer = window.setTimeout(() => {
      replies.delete(reqId);
      resolve({ ok: false, error: "timeout" });
    }, timeoutMs);
    replies.set(reqId, (reply) => {
      window.clearTimeout(timer);
      resolve(reply);
    });
    bridge.postMessage(JSON.stringify({ ...message, reqId }));
  });
}

const SITE = "https://granth.grok.me/open";

export function publicLink(kind: "topic" | "granth" | "praman", id: string) {
  if (!id) return "https://granth.grok.me/";
  const key = kind === "praman" ? "id" : kind;
  return `${SITE}?${key}=${encodeURIComponent(id)}`;
}

export function openExternal(url: string) {
  const bridge = nativeBridge();
  if (bridge) {
    bridge.postMessage(JSON.stringify({ type: "open-url", url }));
    return;
  }
  window.open(url, "_blank", "noopener,noreferrer");
}

export async function shareLink(title: string, url: string) {
  const text = url ? `${title}\n${url}` : title;
  const bridge = nativeBridge();
  if (bridge) {
    bridge.postMessage(JSON.stringify({ type: "share-text", title, url, text }));
    return;
  }
  if (typeof navigator.share === "function") {
    try {
      await navigator.share({ title, text, url: url || undefined });
      return;
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
    }
  }
  try {
    await navigator.clipboard.writeText(text);
    ping("लिंक कॉपी हो गया");
  } catch {
    ping(text);
  }
}

export function openMail(email: string) {
  const bridge = nativeBridge();
  if (bridge) {
    bridge.postMessage(JSON.stringify({ type: "open-mail", email }));
    return;
  }
  window.location.href = `mailto:${email}`;
}

/** Ask the Android app to close (exit dialog). Returns false on the web, where a page cannot close itself. */
export function exitNativeApp() {
  const bridge = nativeBridge();
  if (!bridge) return false;
  bridge.postMessage(JSON.stringify({ type: "exit-app" }));
  return true;
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const size = 0x8000;
  for (let index = 0; index < bytes.length; index += size) {
    binary += String.fromCharCode(...bytes.subarray(index, index + size));
  }
  return btoa(binary);
}

type Mode = "save" | "share" | "open";

/** ~256 KB per message: 5× fewer bridge round trips than before, still well inside WebView limits. */
const CHUNK_BYTES = 3 * 87_381;

/**
 * Stream a file to the Android app in base64 chunks. Resolves with the
 * native result (written, copied to Downloads/Gallery, opened, shared).
 */
async function handoff(blob: Blob, name: string, mode: Mode): Promise<NativeReply> {
  const bridge = nativeBridge();
  if (!bridge) return { ok: false, error: "no-bridge" };
  if (blob.size < 64) return { ok: false, error: "empty" };
  const total = Math.max(1, Math.ceil(blob.size / CHUNK_BYTES));
  const id = `${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
  const type = mode === "share" ? "share-chunk" : mode === "open" ? "open-chunk" : "save-chunk";
  const mime = blob.type || (name.toLowerCase().endsWith(".pdf") ? "application/pdf" : "image/jpeg");
  installReply();
  const reqId = requestId();
  const answer = new Promise<NativeReply>((resolve) => {
    const timer = window.setTimeout(() => {
      replies.delete(reqId);
      resolve({ ok: false, error: "timeout" });
    }, 180_000);
    replies.set(reqId, (reply) => {
      window.clearTimeout(timer);
      resolve(reply);
    });
  });
  for (let index = 0; index < total; index += 1) {
    const slice = blob.slice(index * CHUNK_BYTES, (index + 1) * CHUNK_BYTES);
    const data = toBase64(new Uint8Array(await slice.arrayBuffer()));
    bridge.postMessage(JSON.stringify({ type, id, reqId, name, mime, index, total, data }));
    if (index % 4 === 3) await new Promise((resolve) => window.setTimeout(resolve, 0));
  }
  return answer;
}

function browserDownload(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = fileName;
  document.body.appendChild(link);
  link.click();
  link.remove();
  window.setTimeout(() => URL.revokeObjectURL(url), 60_000);
}

const saving = new Map<string, Promise<NativeReply>>();

/**
 * Put a file on the device: in the app → private copy + Downloads (PDF) or the
 * phone gallery (image); on the web → a normal browser download.
 */
export function deliverFile(blob: Blob, fileName: string): Promise<NativeReply> {
  const job = (async (): Promise<NativeReply> => {
    await new Promise((resolve) => window.setTimeout(resolve, 0));
    if (nativeBridge()) return handoff(blob, fileName, "save");
    browserDownload(blob, fileName);
    return { ok: true };
  })();
  saving.set(fileName, job);
  void job.finally(() => {
    if (saving.get(fileName) === job) saving.delete(fileName);
  });
  return job;
}

async function waitSaved(fileName: string) {
  const pending = saving.get(fileName);
  if (!pending) return;
  try {
    await pending;
  } catch {
    /* fall through and use the bytes we still have */
  }
}

export async function shareBlob(blob: Blob, fileName: string) {
  if (nativeBridge()) {
    await waitSaved(fileName);
    const known = await callNative({ type: "share-saved", name: fileName }, 8000);
    const reply = known.ok ? known : await handoff(blob, fileName, "share");
    if (!reply.ok && reply.error !== "cancelled") ping("शेयर नहीं हो पाया — फिर कोशिश करें");
    return;
  }
  const file = new File([blob], fileName, { type: blob.type || "application/pdf" });
  if (typeof navigator.share === "function") {
    const canFiles = typeof navigator.canShare === "function" && navigator.canShare({ files: [file] });
    try {
      if (canFiles) {
        await navigator.share({ files: [file], title: fileName });
        return;
      }
    } catch (error) {
      if (error instanceof DOMException && error.name === "AbortError") return;
    }
  }
  // Desktop browsers cannot share files: download it instead and say so.
  browserDownload(blob, fileName);
  ping("इस ब्राउज़र में शेयर नहीं होता — फ़ाइल डाउनलोड कर दी है");
}

/**
 * Open a PDF (or image) in the phone's viewer. In the app the saved copy is
 * opened through a content:// URI; when no viewer app exists the shell offers
 * the share sheet instead. On the web the PDF opens in a new browser tab.
 */
export async function openBlob(blob: Blob, fileName: string) {
  if (nativeBridge()) {
    await waitSaved(fileName);
    let reply = await callNative({ type: "open-saved", name: fileName }, 15000);
    if (!reply.ok && reply.error === "missing") reply = await handoff(blob, fileName, "open");
    if (!reply.ok) {
      ping(reply.error === "no-viewer" ? "PDF खोलने वाला ऐप नहीं मिला — शेयर से Drive/Files में खोलें" : "PDF नहीं खुली — फिर कोशिश करें");
    }
    return;
  }
  const url = URL.createObjectURL(blob);
  const opened = window.open(url, "_blank", "noopener,noreferrer");
  if (!opened) {
    // Pop-up blocked (common on mobile browsers): navigate a link instead.
    const link = document.createElement("a");
    link.href = url;
    link.target = "_blank";
    link.rel = "noopener";
    document.body.appendChild(link);
    link.click();
    link.remove();
  }
  window.setTimeout(() => URL.revokeObjectURL(url), 120_000);
}

/** Where `saveBlob` put the file. */
export type SaveResult = "device" | "download" | "failed";

export async function saveBlob(blob: Blob, fileName: string): Promise<SaveResult> {
  if (nativeBridge()) {
    await waitSaved(fileName);
    const known = await callNative({ type: "export-saved", name: fileName }, 20000);
    if (known.ok) return "device";
    const reply = await deliverFile(blob, fileName);
    return reply.ok ? "device" : "failed";
  }
  browserDownload(blob, fileName);
  return "download";
}
