# Photo Highlighter

The 5th hamburger-menu entry (**PHOTO HIGHLIGHTER**) opens `assets/highlighter/index.html`, a byte-for-byte copy of the
provided `photo_highlighter.html`, in a full-screen WebView. All the code lives in `lib/highlighter/`, plus
`assets/highlighter/`, the `pickFiles` handler in `MainActivity.kt` and `HlFileProvider.kt`. Nothing else in the app
depends on it.

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

## Not verifiable without a phone

Real camera and gallery pickers, OCR and OpenCV speed inside the Android WebView (WASM SIMD support differs by
WebView version), and saving to Downloads on each Android version. The server, cache, offline paths, patches and the
download bridge are covered by tests.
