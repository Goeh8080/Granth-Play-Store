# Photo Highlighter

The 5th hamburger-menu entry (**PHOTO HIGHLIGHTER**) opens `assets/highlighter/index.html`, a byte-for-byte copy of the
provided `photo_highlighter.html`, in a full-screen **native Android Activity** (Round 9): `HighlighterActivity.kt` hosts one plain
`android.webkit.WebView`, with no Flutter view or PlatformView in the touch path (it behaves like the page in Chrome).
Code: `lib/highlighter/` (server, patches, launcher), `assets/highlighter/`, and in `android/.../granthprabandhan/`
`HighlighterActivity`, `HlLogic` (pure helpers), `HlTransfer` (bridge downloads), `HlSaver` (Downloads / album) and
`HlFileProvider`. Nothing else in the app depends on it.

## Native Activity (Round 9)

- The menu item calls `HighlighterLauncher.open`: Flutter starts the local server (and the background save of OCR /
  scan libraries), then the `openHighlighter` MethodChannel call does `startActivityForResult`. The call completes when
  the Activity closes. The page still comes from the Dart server, so the origin and its IndexedDB are unchanged and
  existing albums / themes persist (same app WebView data directory).
- WebView: JS, DOM storage, hardware acceleration, `useWideViewPort` (the page's own viewport zoom is kept),
  pinch zoom allowed, file access off, text zoom 100 %, camera / mic permission requests denied.
- File chooser: gallery / files, multiple selection, camera only when the input has `capture` and accepts images.
- Downloads / share: `GranthHL` JavaScript interface (the same bridge shim as before) + a `DownloadListener` for
  `blob:` / `data:` links. Files are written in pieces to `cache/hl-out/`, then saved to Downloads (fallback: share
  sheet) or shared through a read-only `HlFileProvider` URI.
- Back: WebView history first, then the Activity closes (predictive-back callback on Android 13+).
- Insets: edge-to-edge with padding for system bars, cutout and keyboard (Android 11+); the platform default below.
- Keep-screen-on follows the app's setting. The background page download is paused while the Activity is open.
- The Hindi progress / offline notice is a native banner fed by `GET /__status` on the local server (polled every 2 s,
  tap hides it).
- The Activity only finishes when the process was killed (the local server is gone); it is `exported=false`, portrait.

### Drag lag: measured cause and fix

`tool/hl_drag_bench.mjs` drives the page in headless Chrome 156 (CDP touch events, 4× CPU throttle, DPR 2.6, a
1028×771 px layer, 120 touchMoves ~8 ms apart) and checks that the layer ends exactly under the finger. Results are in
`docs/bench/hl-drag-before.json` / `hl-drag-after.json`.

| scenario (OCR on page, 400 word boxes) | before | after |
| --- | --- | --- |
| draw-scan per move | 6.38 ms (max 49) | 1.26–1.36 ms |
| input → handler | 63.4 ms (p95 82.5) | 24.1 ms (p95 26.3) |
| frame interval | 22.9 ms mean, max 100 | 16.46 ms, max 16.8 |
| frames over 33 ms | 32 | 0 |
| total drag time | 7918 ms | 3124 ms |

Plain pages (one layer) were already at ~1.3 ms, so there the page was not the problem. The page rebuilt the whole OCR
overlay DOM on every pointermove; a minimal patch (`/*granth:ocr-overlay-memo*/`, in `highlighter_server.dart`) skips the
rebuild when nothing changed. The most likely extra cause on the phone is the Flutter hybrid PlatformView touch path
(gesture arena, re-sent MotionEvents, frame timing); the Activity removes it. That cannot be measured here.

## How it runs

- A tiny HTTP server on `127.0.0.1` (fixed ports 47811–47815, so the page's own album and theme storage is kept between
  visits) serves the patched page, the bundled libraries and a cache of the two big libraries.
- The WebView has JavaScript on, DOM storage on and text zoom fixed at 100 %. Navigation is limited to the local server,
  `blob:`, `data:` and `about:`. `alert` / `confirm` / `prompt` appear as app dialogs.
- **File inputs.** `<input type=file>` opens the system picker (gallery / files; multi-select works). With
  `capture` it opens the camera (`ACTION_IMAGE_CAPTURE` into the app's private cache via `HlFileProvider`). No CAMERA
  permission is added.
- **Exports.** The page saves with `<a download>` on `blob:` / `data:` URLs (jsPDF `save()`, FileSaver, canvas
  exports). `hl-shim.js` reads the file and sends it to the app in 768 KB pieces. The app writes it to **Downloads**
  (toast "Downloads में सेव हुआ"), or opens the share sheet if that fails. `navigator.share({files})` opens the share
  sheet.
- **Back.** Back first goes back inside the page's own history, then returns to the app.

## Libraries

| Library | Where | Size |
| --- | --- | --- |
| pdf.js 3.11.174 (+ worker) | bundled `assets/highlighter/lib/` | ≈1.4 MB |
| jsPDF 2.5.1 | bundled | ≈0.36 MB |
| OpenCV.js 4.x (auto-scan / perspective) | downloaded once, cached in app storage (`highlighter/`) | ≈11 MB |
| Tesseract.js 5.1.1 + worker + SIMD-LSTM core + `eng` / `hin` 4.0.0_best_int | downloaded once, cached | ≈8.5 MB |

OpenCV and Tesseract are not bundled because the arm64 APK must stay under 25 MB.

## Offline behaviour

- **First open with internet.** Everything OCR and auto-scan need (≈19 MB) is downloaded in the background. A
  thin strip shows "पहली बार: OCR और स्कैन की फ़ाइलें फ़ोन में सेव हो रही हैं — N%". Files are written as `.part` and
  renamed, so a cut connection never leaves a broken file. A request the page makes while the download is running joins
  that download (no double download).
- **After that.** Everything works with no internet.
- **No internet before the first download.** Adding photos, highlighting, the album and PDF export all still work.
  The strip says: "इंटरनेट नहीं है — OCR (टेक्स्ट पहचान) और ऑटो-स्कैन पहली बार इंटरनेट से एक बार डाउनलोड होंगे।
  फ़ोटो जोड़ना, हाइलाइट और PDF बिना इंटरनेट चलते हैं।" The page's own OCR / OpenCV loaders get an HTTP 503 and show
  their normal "not loaded" state. The strip can be closed (×).
- **"सिर्फ़ WiFi पर डाउनलोड" on and not on WiFi.** The download waits and the strip says so.
- **What the proxy can reach.** Only `docs.opencv.org` and `cdn.jsdelivr.net`. `..` paths and other hosts get 404.

## Patches to the HTML (served copy only; the asset file is untouched)

`patchHighlighterHtml` makes exactly five changes:

1. `https://docs.opencv.org/4.x/opencv.js` → `/cdn/docs.opencv.org/4.x/opencv.js` (cached proxy).
2. `https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js` → `/cdn/cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js`.
   Pinned to the version `@5` resolves to today, so the cached worker and core always match.
3. pdf.js `https://cdnjs.cloudflare.com/.../pdf.min.js` → `/lib/pdf.min.js` (bundled). The page sets the worker
   next to it.
4. jsPDF `https://cdnjs.cloudflare.com/.../jspdf.umd.min.js` → `/lib/jspdf.umd.min.js` (bundled).
5. `<script src="/hl-shim.js"></script>` is added after the Tesseract script. It does three things:
   - points `Tesseract.createWorker` at the local worker, core and language paths;
   - sends `blob:` / `data:` downloads to the app;
   - adds `navigator.share` with files.

No page logic, styles or text are changed. `test/highlighter_test.dart` checks that undoing these five changes gives
back the original file exactly.

## Speed (round 8)

The page itself is unchanged; the slowness was in how the app served and hosted it.

| Cause found | Fix |
| --- | --- |
| Every response said `Cache-Control: no-cache` with **no validator**, so the WebView re-downloaded ALL libraries on every open: 19 MB per open (OpenCV 11 MB, Tesseract core 3.9 MB, English data 3 MB) through Dart on the UI isolate, and a script that is re-fetched can never reuse its compiled (V8 code-cache) copy. | Saved libraries: `public, max-age=31536000, immutable` + `ETag`. Page and bridge: `no-cache` + `ETag` (a bodiless 304 per open, so an app update shows at once). `/lib/*` (pdf.js, jsPDF): 1 day + `ETag`. |
| Bundled files (`pdf.worker` 1 MB, pdf.js, jsPDF, the page patch + UTF-8 round trip) were re-read from the APK and re-inflated on every request. | Read once per run, kept in memory; the patched page is built once. |
| `HttpServer.autoCompress` could gzip big scripts on the phone's CPU for a loopback client. | Switched off; `Content-Length` always set. |
| The WebView sat under the app-wide zoom layer (`ClipRect` + `Transform` + pinch recogniser) and was composited by the default texture-layer path (a GPU copy of the page into a Flutter texture each frame, extra touch / keyboard latency). | App zoom steps aside while the highlighter is open (`AppZoom.suspended`: no clip, zoom reset) and the WebView uses hybrid composition (`displayWithHybridComposition: true`). |
| The background page download kept running next to the page (CPU + network). | `ImageStore.holdBackground()` while the highlighter is open; released on close. |

Measured with headless Chrome 156 on this box (4× CPU throttle, persistent profile = the WebView's HTTP + code
cache, the REAL `HighlighterServer`, `tool/hl_bench.mjs` + `test/hl_bench_test.dart`, results in `docs/bench/`):

| (warm open = 2nd–4th open) | before | after |
| --- | --- | --- |
| bytes served by the app per open | 19.0 MB | ≈ 0.5 KB (two 304s) |
| page `load` event | 2.24–2.34 s | 1.47–1.60 s |
| OpenCV ready (`cv.Mat`) | 2.55–2.60 s | 1.79–1.89 s |
| 4000×3000 photo → in the page | 1.14–1.26 s | 1.07–1.22 s (page code, unchanged) |
| Merged PDF export | 0.20–0.21 s | 0.21–0.25 s (page code, unchanged) |

The photo and PDF steps are the page's own JavaScript and match, as intended. What the phone adds on top (hybrid
composition, WASM SIMD) needs a real device to measure.

## Not verifiable without a phone

The drag feel of the native WebView, real camera and gallery pickers, back button / insets on real devices, OCR and OpenCV speed inside the Android WebView (WASM SIMD support differs by
WebView version), and saving to Downloads on each Android version. The server, cache, offline paths, patches and the
download bridge are covered by tests.
