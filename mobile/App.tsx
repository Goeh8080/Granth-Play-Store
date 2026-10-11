import { cacheDirectory, deleteAsync, documentDirectory, EncodingType, getContentUriAsync, getInfoAsync, makeDirectoryAsync, writeAsStringAsync } from "expo-file-system/legacy";
import * as IntentLauncher from "expo-intent-launcher";
import * as MediaLibrary from "expo-media-library";
import * as Sharing from "expo-sharing";
import { StatusBar } from "expo-status-bar";
import { useEffect, useRef, useState } from "react";
import { AppState, BackHandler, Image, Linking, NativeModules, PermissionsAndroid, Platform, Share, StyleSheet, View } from "react-native";
import { SafeAreaProvider, useSafeAreaInsets } from "react-native-safe-area-context";
import { WebView } from "react-native-webview";

const ORIGIN = "https://granth.wnmsolutions.com";
const LISTS = new Set(["getTopics", "getGranths", "getPramans"]);

type SaveChunk = {
  type: "save-chunk" | "share-chunk" | "open-chunk";
  id: string;
  name: string;
  mime: string;
  index: number;
  total: number;
  data: string;
};

type NetRequest = { type: "net"; id: string; path: string };
type OpenMail = { type: "open-mail"; email: string };
type OpenUrl = { type: "open-url"; url: string };
type OpenSaved = { type: "open-saved"; name: string };
type ShareText = { type: "share-text"; title?: string; text?: string; url?: string };
type ShareSaved = { type: "share-saved"; name: string };
type ExportSaved = { type: "export-saved"; name: string };
type ExitApp = { type: "exit-app" };

const BRIDGE = `(function(){
  if (window.__granthBridge) return true;
  window.__granthBridge = true;
  var pending = new Map();
  var queue = [];
  function post(obj){
    var raw = JSON.stringify(obj);
    if (window.ReactNativeWebView && window.ReactNativeWebView.postMessage) window.ReactNativeWebView.postMessage(raw);
    else queue.push(raw);
  }
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
    const timer = setTimeout(() => setSplash(false), 2600);
    return () => clearTimeout(timer);
  }, []);
  useEffect(() => {
    const timer = setTimeout(() => {
      void askDevicePermissions();
    }, 2800);
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
        source={{ uri: "file:///android_asset/web/index.html" }}
        style={styles.fill}
        originWhitelist={["*"]}
        javaScriptEnabled
        domStorageEnabled
        allowFileAccess
        allowFileAccessFromFileURLs
        allowUniversalAccessFromFileURLs
        mixedContentMode="always"
        cacheEnabled
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
          if (request.url.startsWith("mailto:")) {
            void openMail(request.url.replace(/^mailto:/i, "").split("?")[0]);
            return false;
          }
          return true;
        }}
        onMessage={(event) => {
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

async function askDevicePermissions() {
  if (Platform.OS !== "android") return;
  const names: Array<(typeof PermissionsAndroid.PERMISSIONS)[keyof typeof PermissionsAndroid.PERMISSIONS]> = [];
  if (Number(Platform.Version) >= 33) {
    names.push(PermissionsAndroid.PERMISSIONS.POST_NOTIFICATIONS, PermissionsAndroid.PERMISSIONS.READ_MEDIA_IMAGES);
  } else {
    names.push(PermissionsAndroid.PERMISSIONS.READ_EXTERNAL_STORAGE, PermissionsAndroid.PERMISSIONS.WRITE_EXTERNAL_STORAGE);
  }
  await PermissionsAndroid.requestMultiple(names).catch(() => undefined);
  await MediaLibrary.requestPermissionsAsync(false, ["photo"]).catch(() => undefined);
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

function openDeepLink(view: WebView | null, url: string) {
  const hash = hashFromShareUrl(url);
  if (!hash || !view) return;
  view.injectJavaScript(`window.__granthOpenLink&&window.__granthOpenLink(${JSON.stringify(hash)});true;`);
}

async function onBridge(raw: string, view: WebView | null, parts: Map<string, string[]>) {
  let message: SaveChunk | NetRequest | OpenMail | OpenUrl | OpenSaved | ShareText | ShareSaved | ExportSaved | ExitApp;
  try {
    message = JSON.parse(raw) as SaveChunk | NetRequest | OpenMail | OpenUrl | OpenSaved | ShareText | ShareSaved | ExportSaved | ExitApp;
  } catch {
    return;
  }
  if (message.type === "exit-app") {
    const granth = NativeModules.GranthDownloads as { exitApp?: () => void } | undefined;
    if (granth?.exitApp) granth.exitApp();
    else BackHandler.exitApp();
    return;
  }
  if (message.type === "share-text") {
    const text = message.text || message.url || message.title || "";
    if (text) await Share.share({ title: message.title, message: text });
    return;
  }
  if (message.type === "share-saved") {
    await shareSaved(message.name, view);
    return;
  }
  if (message.type === "export-saved") {
    await exportSaved(message.name, view);
    return;
  }
  if (message.type === "open-saved") {
    await openSaved(message.name, view);
    return;
  }
  if (message.type === "save-chunk" || message.type === "share-chunk" || message.type === "open-chunk") {
    await placeFile(message, parts);
    return;
  }
  if (message.type === "net") {
    await proxyNet(view, message.id, message.path);
    return;
  }
  if (message.type === "open-mail") {
    await openMail(message.email);
    return;
  }
  if (message.type === "open-url" && /^https?:\/\//i.test(message.url)) {
    await Linking.openURL(message.url);
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

async function shareSaved(rawName: string, view: WebView | null) {
  const name = safeName(rawName);
  const uri = documentDirectory ? `${documentDirectory}Granth/${name}` : "";
  const info = uri ? await getInfoAsync(uri).catch(() => null) : null;
  const size = info && "exists" in info && info.exists && "size" in info ? Number(info.size) : 0;
  const ready = size > 64;
  view?.injectJavaScript(
    `window.__granthShare${ready ? "Hit" : "Miss"}&&window.__granthShare${ready ? "Hit" : "Miss"}(${JSON.stringify(rawName)});true;`,
  );
  if (!ready || !uri) return;
  if (await Sharing.isAvailableAsync()) {
    await Sharing.shareAsync(uri, { mimeType: "application/pdf", dialogTitle: name });
  }
}

async function exportSaved(rawName: string, view: WebView | null) {
  const name = safeName(rawName);
  const uri = documentDirectory ? `${documentDirectory}Granth/${name}` : "";
  const info = uri ? await getInfoAsync(uri).catch(() => null) : null;
  const size = info && "exists" in info && info.exists && "size" in info ? Number(info.size) : 0;
  const ready = size > 64;
  view?.injectJavaScript(
    `window.__granthExport${ready ? "Hit" : "Miss"}&&window.__granthExport${ready ? "Hit" : "Miss"}(${JSON.stringify(rawName)});true;`,
  );
  if (!ready || !uri) return;
  const writer = NativeModules.GranthDownloads as { copyToDownloads?: (path: string, name: string, mime: string) => Promise<string> } | undefined;
  const mime = name.toLowerCase().endsWith(".pdf") ? "application/pdf" : "image/jpeg";
  if (writer?.copyToDownloads) await writer.copyToDownloads(uri, name, mime).catch(() => undefined);
}

async function openSaved(rawName: string, view: WebView | null) {
  const name = safeName(rawName);
  const pending = writing.get(name);
  if (pending) {
    try {
      await viewPdf(await pending);
      return;
    } catch {
      /* write again below if the file is still missing */
    }
  }
  const uri = documentDirectory ? `${documentDirectory}Granth/${name}` : "";
  if (uri) {
    const info = await getInfoAsync(uri).catch(() => null);
    if (info && "exists" in info && info.exists && "size" in info && Number(info.size) > 64) {
      await viewPdf(uri);
      return;
    }
  }
  view?.injectJavaScript(`window.__granthOpenMiss&&window.__granthOpenMiss(${JSON.stringify(rawName)});true;`);
}

async function placeFile(message: SaveChunk, parts: Map<string, string[]>) {
  const bucket = parts.get(message.id) ?? [];
  bucket[message.index] = message.data;
  parts.set(message.id, bucket);
  if (bucket.filter((part) => part != null && part.length > 0).length < message.total) return;
  parts.delete(message.id);
  const name = safeName(message.name);
  const job = writeFile(message, name, bucket);
  writing.set(name, job);
  try {
    await job;
  } finally {
    if (writing.get(name) === job) writing.delete(name);
  }
}

async function writeFile(message: SaveChunk, name: string, chunks: string[]) {
  const pdf = (message.mime || "").includes("pdf") || name.toLowerCase().endsWith(".pdf");
  const root = pdf ? documentDirectory || cacheDirectory : cacheDirectory;
  if (!root) return "";
  if (pdf && documentDirectory) {
    await makeDirectoryAsync(`${documentDirectory}Granth`, { intermediates: true }).catch(() => undefined);
  }
  const uri = pdf && documentDirectory ? `${documentDirectory}Granth/${name}` : `${root}${name}`;
  const writer = NativeModules.GranthDownloads as {
    beginWrite?: (path: string) => Promise<boolean>;
    appendWrite?: (path: string, data: string) => Promise<number>;
    finishWrite?: (path: string) => Promise<number>;
    copyToDownloads?: (path: string, name: string, mime: string) => Promise<string>;
  } | undefined;
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
  if (pdf) {
    if (writer?.copyToDownloads && message.type === "save-chunk") {
      await writer.copyToDownloads(uri, name, "application/pdf").catch(() => undefined);
    }
  }
  if (message.type === "share-chunk") {
    if (await Sharing.isAvailableAsync()) {
      await Sharing.shareAsync(uri, { mimeType: message.mime || (pdf ? "application/pdf" : "image/jpeg"), dialogTitle: name });
    }
    return uri;
  }
  if (message.type === "open-chunk") {
    await viewPdf(uri);
    return uri;
  }
  if (!pdf) {
    try {
      const permission = await MediaLibrary.requestPermissionsAsync(true, ["photo"]);
      if (permission.granted) await MediaLibrary.saveToLibraryAsync(uri);
    } catch {
      /* album permission can be denied; the in-app gallery copy remains */
    }
  }
  return uri;
}

async function viewPdf(uri: string) {
  const contentUri = await getContentUriAsync(uri);
  void IntentLauncher.startActivityAsync("android.intent.action.VIEW", {
    data: contentUri,
    type: "application/pdf",
    flags: 1,
  }).catch(() => undefined);
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
