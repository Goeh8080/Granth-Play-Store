import { cacheDirectory, deleteAsync, documentDirectory, EncodingType, getContentUriAsync, getInfoAsync, makeDirectoryAsync, writeAsStringAsync } from "expo-file-system/legacy";
import * as Sharing from "expo-sharing";
import { StatusBar } from "expo-status-bar";
import { useEffect, useRef, useState } from "react";
import { AppState, BackHandler, Image, Linking, NativeModules, Share, StyleSheet, View } from "react-native";
import { SafeAreaProvider, useSafeAreaInsets } from "react-native-safe-area-context";
import { WebView } from "react-native-webview";

const ORIGIN = "https://granth.wnmsolutions.com";
const LISTS = new Set(["getTopics", "getGranths", "getPramans"]);
const APP_PAGE = "file:///android_asset/web/index.html";

/**
 * Per-launch secret. The bridge script keeps it in a closure and stamps it on
 * every message from the app page; messages without it (for example from an
 * embedded YouTube iframe, which can also reach ReactNativeWebView) are ignored.
 */
const TOKEN = `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`;

type Reply = { ok: boolean; error?: string; uri?: string };

type SaveChunk = {
  type: "save-chunk" | "share-chunk" | "open-chunk";
  id: string;
  reqId?: string;
  name: string;
  mime: string;
  index: number;
  total: number;
  data: string;
};

type NetRequest = { type: "net"; id: string; path: string };
type OpenMail = { type: "open-mail"; email: string };
type OpenUrl = { type: "open-url"; url: string };
type OpenSaved = { type: "open-saved"; name: string; reqId?: string };
type ShareText = { type: "share-text"; title?: string; text?: string; url?: string };
type ShareSaved = { type: "share-saved"; name: string; reqId?: string };
type ExportSaved = { type: "export-saved"; name: string; reqId?: string };
type ExitApp = { type: "exit-app" };
type BridgeMessage = (SaveChunk | NetRequest | OpenMail | OpenUrl | OpenSaved | ShareText | ShareSaved | ExportSaved | ExitApp) & { token?: string };

type NativeFiles = {
  getAppVersion?: () => Promise<string>;
  beginWrite?: (path: string) => Promise<boolean>;
  appendWrite?: (path: string, data: string) => Promise<number>;
  finishWrite?: (path: string) => Promise<number>;
  copyToDownloads?: (path: string, name: string, mime: string) => Promise<string>;
  copyToPictures?: (path: string, name: string, mime: string) => Promise<string>;
  viewUri?: (uri: string, mime: string) => Promise<boolean>;
  exitApp?: () => void;
};

const files = () => NativeModules.GranthDownloads as NativeFiles | undefined;

const BRIDGE = `(function(){
  if (window.__granthBridge) return true;
  if (window.top !== window) return true;
  window.__granthBridge = true;
  var token = ${JSON.stringify(TOKEN)};
  var pending = new Map();
  var queue = [];
  function send(raw){
    if (window.ReactNativeWebView && window.ReactNativeWebView.postMessage) window.ReactNativeWebView.postMessage(raw);
    else queue.push(raw);
  }
  function post(obj){
    obj.token = token;
    send(JSON.stringify(obj));
  }
  window.__granthNative = {
    postMessage: function(raw){
      var obj;
      try { obj = JSON.parse(raw); } catch (e) { return; }
      if (!obj || typeof obj !== "object") return;
      post(obj);
    }
  };
  setInterval(function(){
    if (!window.ReactNativeWebView || !queue.length) return;
    var batch = queue.splice(0, queue.length);
    for (var i = 0; i < batch.length; i++) window.ReactNativeWebView.postMessage(batch[i]);
  }, 40);
  window.__granthChunk = function(msg){
    var job = pending.get(msg.id);
    if (!job) return;
    job.chunks[msg.index] = msg.data;
    var got = 0;
    for (var i = 0; i < msg.total; i++) if (job.chunks[i] != null) got++;
    if (got < msg.total) return;
    pending.delete(msg.id);
    clearTimeout(job.timer);
    var data = job.chunks.join("");
    var body = data;
    if (msg.encoding === "base64") {
      var binary = atob(data);
      var bytes = new Uint8Array(binary.length);
      for (var j = 0; j < binary.length; j++) bytes[j] = binary.charCodeAt(j);
      body = bytes;
    }
    job.done(new Response(body, { status: msg.status || 200, headers: { "content-type": msg.contentType || "application/octet-stream" } }));
  };
  var orig = window.fetch.bind(window);
  window.fetch = function(input, init){
    var url = typeof input === "string" ? input : (input && input.url) || "";
    if (url.indexOf("https://") === 0 || url.indexOf("http://") === 0) return orig(input, init);
    var at = url.indexOf("/api/");
    if (at < 0) return orig(input, init);
    var path = url.slice(at);
    if (path.indexOf("/api/granth") !== 0 && path.indexOf("/api/media") !== 0) return orig(input, init);
    var id = Date.now().toString(36) + Math.random().toString(36).slice(2);
    return new Promise(function(resolve, reject){
      var timer = setTimeout(function(){ pending.delete(id); reject(new Error("network timeout")); }, 50000);
      pending.set(id, { chunks: [], timer: timer, done: resolve });
      post({ type: "net", id: id, path: path });
    });
  };
  document.addEventListener("click", function(event){
    var node = event.target;
    while (node && node.tagName !== "A") node = node.parentElement;
    if (!node) return;
    var href = node.getAttribute("href") || "";
    if (href.indexOf("mailto:") === 0) {
      event.preventDefault();
      post({ type: "open-mail", email: decodeURIComponent(href.replace(/^mailto:/i, "").split("?")[0]) });
    }
  }, true);
  window.open = function(url){
    if (url) post({ type: "open-url", url: String(url) });
    return null;
  };
  if (!window.__granthOpenLink) {
    window.__granthOpenLink = function(hash){ window.__granthPendingHash = hash; };
  }
  return true;
})();`;

export function App() {
  return (
    <SafeAreaProvider>
      <Shell />
    </SafeAreaProvider>
  );
}

function Shell() {
  const insets = useSafeAreaInsets();
  const web = useRef<WebView>(null);
  const parts = useRef(new Map<string, string[]>());
  const pendingLink = useRef<string | null>(null);
  const sentLink = useRef("");
  const webReady = useRef(false);
  const [splash, setSplash] = useState(true);
  const pad = `document.documentElement.style.setProperty('--apk-top','${Math.max(insets.top, 28)}px');document.documentElement.style.setProperty('--apk-bottom','${insets.bottom}px');document.body.classList.add('apk');true;`;
  useEffect(() => {
    // Safety net only: the splash is normally hidden as soon as the page has loaded.
    const timer = setTimeout(() => setSplash(false), 6000);
    return () => clearTimeout(timer);
  }, []);
  useEffect(() => {
    const onBack = () => {
      web.current?.injectJavaScript(
        "if(window.__granthBack){window.__granthBack();}true;",
      );
      return true;
    };
    const sub = BackHandler.addEventListener("hardwareBackPress", onBack);
    return () => sub.remove();
  }, []);
  useEffect(() => {
    const sub = AppState.addEventListener("change", (state) => {
      if (state !== "active") return;
      web.current?.injectJavaScript(
        "(function(){try{var root=document.getElementById('root');if(!root||root.childElementCount===0){location.reload();return;}window.dispatchEvent(new Event('granth-resume'));document.body.style.transform='translateZ(0)';requestAnimationFrame(function(){document.body.style.transform='';});}catch(e){}})();true;",
      );
    });
    return () => sub.remove();
  }, []);
  useEffect(() => {
    const deliver = (url: string | null) => {
      if (!url || !webReady.current || !web.current || sentLink.current === url) return;
      const hash = hashFromShareUrl(url);
      if (!hash) return;
      sentLink.current = url;
      web.current.injectJavaScript(`window.__granthOpenLink&&window.__granthOpenLink(${JSON.stringify(hash)});true;`);
    };
    const apply = (url: string | null) => {
      if (!url || sentLink.current === url) return;
      pendingLink.current = url;
      deliver(url);
    };
    const sub = Linking.addEventListener("url", (event) => apply(event.url));
    void Linking.getInitialURL().then(apply);
    return () => sub.remove();
  }, []);
  useEffect(() => {
    web.current?.injectJavaScript(pad);
  }, [pad]);
  return (
    <View style={styles.fill}>
      <StatusBar style="dark" />
      <WebView
        ref={web}
        source={{ uri: APP_PAGE }}
        style={styles.fill}
        originWhitelist={["file://*", "https://*", "about:blank"]}
        javaScriptEnabled
        domStorageEnabled
        allowFileAccess
        allowFileAccessFromFileURLs
        // The Granth API sends no CORS headers; the bundled page needs this to read it.
        allowUniversalAccessFromFileURLs
        mixedContentMode="never"
        cacheEnabled
        overScrollMode="never"
        nestedScrollEnabled={false}
        androidLayerType="hardware"
        textZoom={100}
        onContentProcessDidTerminate={() => web.current?.reload()}
        onRenderProcessGone={() => {
          web.current?.reload();
        }}
        setSupportMultipleWindows={false}
        setBuiltInZoomControls
        setDisplayZoomControls={false}
        scalesPageToFit={false}
        injectedJavaScriptBeforeContentLoaded={BRIDGE}
        injectedJavaScript={pad}
        onLoadEnd={() => {
          webReady.current = true;
          web.current?.injectJavaScript(BRIDGE);
          web.current?.injectJavaScript(pad);
          setTimeout(() => setSplash(false), 350);
          void files()?.getAppVersion?.().then((version) => {
            if (!version) return;
            web.current?.injectJavaScript(`window.__granthVersion=${JSON.stringify(version)};window.dispatchEvent(new Event("granth-version"));true;`);
          });
          if (pendingLink.current && sentLink.current !== pendingLink.current) {
            const url = pendingLink.current;
            const hash = hashFromShareUrl(url);
            if (hash) {
              sentLink.current = url;
              web.current?.injectJavaScript(`window.__granthOpenLink&&window.__granthOpenLink(${JSON.stringify(hash)});true;`);
            }
          }
        }}
        onShouldStartLoadWithRequest={(request) => {
          const url = request.url;
          if (url.startsWith("mailto:")) {
            void openMail(url.replace(/^mailto:/i, "").split("?")[0]);
            return false;
          }
          // Embedded frames (YouTube) may load what they need.
          if (request.isTopFrame === false) return true;
          // The app page itself, and in-page hash navigation.
          if (url.startsWith("file:///android_asset/") || url === "about:blank") return true;
          // Anything else would replace the app inside the WebView: hand it to the system instead.
          if (/^(https?|intent|market|tel|whatsapp):/i.test(url)) void Linking.openURL(url).catch(() => undefined);
          return false;
        }}
        onMessage={(event) => {
          if (!event.nativeEvent.url?.startsWith("file:///android_asset/")) return;
          void onBridge(event.nativeEvent.data, web.current, parts.current);
        }}
      />
      {splash ? (
        <View style={styles.splash}>
          <Image source={require("./assets/splash.png")} style={styles.logo} resizeMode="contain" />
        </View>
      ) : null}
    </View>
  );
}

function hashFromShareUrl(url: string) {
  const normalized = url.replace(/^granth:\/\//, "https://granth.local/");
  let parsed: URL;
  try {
    parsed = new URL(normalized);
  } catch {
    return "";
  }
  const granth = parsed.searchParams.get("granth");
  const topic = parsed.searchParams.get("topic");
  const id = parsed.searchParams.get("id");
  if (granth) return `#/pramans?granth=${encodeURIComponent(granth)}`;
  if (topic) return `#/pramans?topic=${encodeURIComponent(topic)}`;
  if (id) return `#/pramans?id=${encodeURIComponent(id)}`;
  if (parsed.hash.startsWith("#/")) return parsed.hash;
  return "";
}

function reply(view: WebView | null, reqId: string | undefined, answer: Reply) {
  if (!view || !reqId) return;
  view.injectJavaScript(`window.__granthReply&&window.__granthReply(${JSON.stringify(reqId)},${JSON.stringify(answer)});true;`);
}

function errorCode(error: unknown, fallback: string) {
  const code = (error as { code?: string } | null)?.code;
  return typeof code === "string" && code ? code : fallback;
}

async function onBridge(raw: string, view: WebView | null, parts: Map<string, string[]>) {
  let message: BridgeMessage;
  try {
    message = JSON.parse(raw) as BridgeMessage;
  } catch {
    return;
  }
  if (!message || message.token !== TOKEN) return;
  if (message.type === "exit-app") {
    const granth = files();
    if (granth?.exitApp) granth.exitApp();
    else BackHandler.exitApp();
    return;
  }
  if (message.type === "share-text") {
    const text = message.text || message.url || message.title || "";
    if (text) await Share.share({ title: message.title, message: text }).catch(() => undefined);
    return;
  }
  if (message.type === "share-saved") {
    reply(view, message.reqId, await shareSaved(message.name));
    return;
  }
  if (message.type === "export-saved") {
    reply(view, message.reqId, await exportSaved(message.name));
    return;
  }
  if (message.type === "open-saved") {
    reply(view, message.reqId, await openSaved(message.name));
    return;
  }
  if (message.type === "save-chunk" || message.type === "share-chunk" || message.type === "open-chunk") {
    const answer = await placeFile(message, parts);
    if (answer) reply(view, message.reqId, answer);
    return;
  }
  if (message.type === "net") {
    await proxyNet(view, message.id, message.path);
    return;
  }
  if (message.type === "open-mail") {
    await openMail(message.email).catch(() => undefined);
    return;
  }
  if (message.type === "open-url" && /^https?:\/\//i.test(message.url)) {
    await Linking.openURL(message.url).catch(() => undefined);
  }
}

async function openMail(email: string) {
  const to = email.trim();
  if (!to) return;
  const gmail = `googlegmail://co?to=${encodeURIComponent(to)}`;
  try {
    if (await Linking.canOpenURL(gmail)) {
      await Linking.openURL(gmail);
      return;
    }
  } catch {
    /* Gmail scheme is optional */
  }
  await Linking.openURL(`mailto:${to}`);
}

function upstream(path: string): string | null {
  if (path.startsWith("/api/granth")) {
    const request = new URLSearchParams(path.split("?")[1] ?? "").get("request") ?? "";
    if (request === "bundle" || LISTS.has(request)) return request;
    return null;
  }
  if (path.startsWith("/api/media")) {
    const src = new URLSearchParams(path.split("?")[1] ?? "").get("src") ?? "";
    if (!/^(granths|uploads)\/[A-Za-z0-9_.-]+$/.test(src)) return null;
    return `${ORIGIN}/${src}`;
  }
  return null;
}

async function proxyNet(view: WebView | null, id: string, path: string) {
  if (!view) return;
  try {
    const target = upstream(path);
    if (!target) {
      sendChunks(view, id, JSON.stringify({ success: false }), "text", 404, "application/json");
      return;
    }
    if (target === "bundle") {
      const names = ["getTopics", "getGranths", "getPramans"];
      const bodies = await Promise.all(
        names.map((name) => fetch(`${ORIGIN}/api/index.php?request=${encodeURIComponent(name)}`).then((item) => item.json())),
      );
      sendChunks(
        view,
        id,
        JSON.stringify({
          success: true,
          data: { topics: bodies[0]?.data ?? [], granths: bodies[1]?.data ?? [], pramans: bodies[2]?.data ?? [] },
        }),
        "text",
        200,
        "application/json",
      );
      return;
    }
    const response = await fetch(path.startsWith("/api/media") ? target : `${ORIGIN}/api/index.php?request=${encodeURIComponent(target)}`);
    if (path.startsWith("/api/media")) {
      const bytes = new Uint8Array(await response.arrayBuffer());
      const type = response.headers.get("content-type") || "image/jpeg";
      sendChunks(view, id, toBase64(bytes), "base64", response.status, type);
      return;
    }
    const text = await response.text();
    sendChunks(view, id, text, "text", response.status, "application/json");
  } catch {
    sendChunks(view, id, JSON.stringify({ success: false, error: "offline" }), "text", 502, "application/json");
  }
}

function sendChunks(view: WebView, id: string, data: string, encoding: string, status: number, contentType: string) {
  const size = 120_000;
  const total = Math.max(1, Math.ceil(data.length / size) || 1);
  for (let index = 0; index < total; index += 1) {
    const msg = {
      id,
      index,
      total,
      encoding,
      status,
      contentType,
      data: data.slice(index * size, (index + 1) * size),
    };
    view.injectJavaScript(`window.__granthChunk&&window.__granthChunk(${JSON.stringify(msg)});true;`);
  }
}

function toBase64(bytes: Uint8Array): string {
  let binary = "";
  const size = 0x8000;
  for (let index = 0; index < bytes.length; index += size) {
    binary += String.fromCharCode(...bytes.subarray(index, index + size));
  }
  return btoa(binary);
}

const writing = new Map<string, Promise<string>>();

function safeName(name: string) {
  return name.replace(/[^\w.\-\u0900-\u097F ]+/g, "_").slice(0, 80) || "granth.pdf";
}

function mimeOf(name: string, given?: string) {
  if (given) return given;
  return name.toLowerCase().endsWith(".pdf") ? "application/pdf" : "image/jpeg";
}

function isPdf(name: string, mime?: string) {
  return (mime || "").includes("pdf") || name.toLowerCase().endsWith(".pdf");
}

/** Where a file was written: PDFs in app documents/Granth, pictures in the cache. */
function savedUri(name: string) {
  if (isPdf(name)) return documentDirectory ? `${documentDirectory}Granth/${name}` : "";
  return cacheDirectory ? `${cacheDirectory}${name}` : "";
}

async function existing(name: string): Promise<string> {
  const pending = writing.get(name);
  if (pending) {
    try {
      return await pending;
    } catch {
      /* fall through to the disk check */
    }
  }
  const uri = savedUri(name);
  if (!uri) return "";
  const info = await getInfoAsync(uri).catch(() => null);
  return info && "exists" in info && info.exists && "size" in info && Number(info.size) > 64 ? uri : "";
}

async function shareFile(uri: string, name: string, mime?: string): Promise<Reply> {
  if (!(await Sharing.isAvailableAsync())) return { ok: false, error: "no-share" };
  try {
    await Sharing.shareAsync(uri, { mimeType: mimeOf(name, mime), dialogTitle: name });
    return { ok: true, uri };
  } catch (error) {
    return { ok: false, error: errorCode(error, "share") };
  }
}

/** Public copy: PDFs → Downloads, pictures → Pictures/Granth (MediaStore, no permission needed on Android 10+). */
async function publish(uri: string, name: string, mime?: string): Promise<Reply> {
  const writer = files();
  const pdf = isPdf(name, mime);
  const copy = pdf ? writer?.copyToDownloads : writer?.copyToPictures;
  if (!copy) return { ok: false, error: "unsupported" };
  try {
    const where = await copy(uri, name, mimeOf(name, mime));
    return { ok: true, uri: where };
  } catch (error) {
    return { ok: false, error: errorCode(error, "copy") };
  }
}

async function viewFile(uri: string, name: string, mime?: string): Promise<Reply> {
  try {
    const contentUri = await getContentUriAsync(uri);
    const viewer = files()?.viewUri;
    if (!viewer) return { ok: false, error: "unsupported" };
    await viewer(contentUri, mimeOf(name, mime));
    return { ok: true, uri: contentUri };
  } catch (error) {
    const code = errorCode(error, "open");
    if (code === "no-viewer") {
      // No PDF viewer installed: offer the share sheet (Drive, Files, …) instead.
      void shareFile(uri, name, mime);
    }
    return { ok: false, error: code };
  }
}

async function shareSaved(rawName: string): Promise<Reply> {
  const name = safeName(rawName);
  const uri = await existing(name);
  if (!uri) return { ok: false, error: "missing" };
  return shareFile(uri, name);
}

async function exportSaved(rawName: string): Promise<Reply> {
  const name = safeName(rawName);
  const uri = await existing(name);
  if (!uri) return { ok: false, error: "missing" };
  return publish(uri, name);
}

async function openSaved(rawName: string): Promise<Reply> {
  const name = safeName(rawName);
  const uri = await existing(name);
  if (!uri) return { ok: false, error: "missing" };
  return viewFile(uri, name);
}

/** Collects chunks; once the file is complete, writes it and performs the requested action. */
async function placeFile(message: SaveChunk, parts: Map<string, string[]>): Promise<Reply | null> {
  const bucket = parts.get(message.id) ?? [];
  bucket[message.index] = message.data;
  parts.set(message.id, bucket);
  if (bucket.filter((part) => part != null && part.length > 0).length < message.total) return null;
  parts.delete(message.id);
  const name = safeName(message.name);
  const job = writeFile(message, name, bucket);
  writing.set(name, job);
  let uri = "";
  try {
    uri = await job;
  } catch (error) {
    return { ok: false, error: errorCode(error, "write") };
  } finally {
    if (writing.get(name) === job) writing.delete(name);
  }
  if (!uri) return { ok: false, error: "write" };
  if (message.type === "share-chunk") return shareFile(uri, name, message.mime);
  if (message.type === "open-chunk") return viewFile(uri, name, message.mime);
  return publish(uri, name, message.mime);
}

async function writeFile(message: SaveChunk, name: string, chunks: string[]) {
  const pdf = isPdf(name, message.mime);
  if (pdf && documentDirectory) {
    await makeDirectoryAsync(`${documentDirectory}Granth`, { intermediates: true }).catch(() => undefined);
  }
  const uri = savedUri(name);
  if (!uri) return "";
  const writer = files();
  try {
    if (writer?.beginWrite && writer.appendWrite && writer.finishWrite) {
      await writer.beginWrite(uri);
      let expect = 0;
      for (const part of chunks) {
        if (!part) throw new Error("missing chunk");
        const pad = part.endsWith("==") ? 2 : part.endsWith("=") ? 1 : 0;
        expect += Math.floor((part.length * 3) / 4) - pad;
        await writer.appendWrite(uri, part);
      }
      const size = await writer.finishWrite(uri);
      if (!size || size < 64 || size + 8 < expect) throw new Error("short file");
    } else {
      await writeAsStringAsync(uri, chunks.join(""), { encoding: EncodingType.Base64 });
      const info = await getInfoAsync(uri);
      if (!info.exists || !("size" in info) || Number(info.size) < 64) throw new Error("empty file");
    }
  } catch (error) {
    await deleteAsync(uri, { idempotent: true }).catch(() => undefined);
    throw error;
  }
  return uri;
}

const styles = StyleSheet.create({
  fill: { flex: 1, backgroundColor: "#FFFFFF" },
  splash: {
    position: "absolute",
    top: 0,
    right: 0,
    bottom: 0,
    left: 0,
    backgroundColor: "#FFFFFF",
    alignItems: "center",
    justifyContent: "center",
  },
  logo: { width: 320, height: 300 },
});
