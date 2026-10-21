# Feature parity: ashok8090/Granth-Play-Store → Flutter

**Source audited:** upstream `main` of ashok8090/Granth-Play-Store (221 files):
- the shipped web bundle `mobile/android/app/src/main/assets/web/index.html`;
- its TypeScript sources in `src/` (`components/granth/*`, `lib/granth/*`, `styles.css`, `routes/*`);
- the Expo / React Native shell `mobile/App.tsx` and `app.json`;
- the native Kotlin `MainActivity` / `DownloadsModule` / `GranthBack`;
- `AndroidManifest.xml`, the `public/open` share page and `assetlinks.json`.

**Tools:** REA `analyze_javascript_application` on the extracted bundle, then a line-by-line read of the sources.

**Rule followed:** same UI and behaviour; animations are smoother. Where the original had a bug, the correct behaviour was built instead (see the last section).

**Legend:** ✅ done (same behaviour) · ➕ done and improved · ⏭ not ported (with the reason).

## App shell / platform

| Feature (original) | Status | Notes |
| --- | --- | --- |
| Package `com.wnm.granthprabandhan`, label ग्रंथ प्रबंधन, portrait, light | ✅ | Same id. Different signing key, so it cannot update the Play Store install. |
| Splash (white + mark) | ➕ | Native white launch + animated Flutter splash. It never waits more than 3.5 s for the network. |
| Hardware back (`__granthBack`): close overlay → menu → previous screen → double-back on Dashboard → exit confirm | ✅ | Same order, same 80–900 ms double-tap window, same "क्या आप बाहर निकलना चाहते हैं?" card. |
| Exit (`exit-app` → `finishAffinity`) | ✅ | MethodChannel `exitApp`. |
| Resume (`granth-resume`, reload if the WebView went blank) | ➕ | No WebView, so there is no blank state to reload. Resume syncs silently when the app was away ≥ 30 s or the data is > 2 min old. |
| Deep links `granth://open?topic|granth|id=…` and `https://granth.grok.me/open?...` | ➕ | Cold start (`getInitialLink`) and warm start (`onNewIntent` + `setIntent`). Not-found shows a message with a Dashboard button. Tested. |
| `public/open` web page / `assetlinks.json` | ⏭ | Server-side files; nothing to port into the app. |
| Startup permission prompt (notifications, media) | ⏭ (on purpose) | The original asks for notifications at start but never posts any. Here, notifications are asked once on Android 13+, the first time a PDF starts; PDFs still work if denied. Storage permission is asked only when saving on Android ≤ 9; MediaStore needs none on Android 10+. |
| Whole-app pinch zoom (WebView viewport `maximum-scale=5, user-scalable=yes`, `touch-action: manipulation`) | ✅ | `AppZoom` wraps every screen: two-finger pinch 1–5× at the fingers, the layout never reflows (it is a transform), taps land on the right spot, one-finger sideways drag pans while zoomed, vertical drags still scroll lists, snaps back to 1× near 1. No double-tap zoom, same as the original (`touch-action: manipulation`). The picture viewer's own zoom wins inside the viewer. |
| Status bar maroon, safe-area padding | ✅ | |

## Data, sync, storage

| Feature | Status | Notes |
| --- | --- | --- |
| `getTopics` / `getGranths` / `getPramans` from granth.wnmsolutions.com | ✅ | Same API and `text/html` JSON handling. 20 s overall timeout (the bridge used 50 s), so a dead network never keeps the spinner up. |
| Boot: show the saved copy instantly, then sync, then save pages | ✅ | `CatalogStore.boot` mirrors the zustand `cn.boot`. |
| Sync every 3 min, on reconnect, on resume, सिंक button | ➕ | An identical download changes nothing (no rebuild or re-index). JSON is decoded off the UI thread. |
| सिंक button (`sync().then(savePages)`, spinning icon, live strip text) | ✅ ➕ | Tap re-fetches all three lists, spins, then checks every saved page on disk (exists, real size, valid JPEG/PNG/GIF/WEBP header, JPEG end marker) and quietly re-downloads missing or damaged ones. It always shows progress, even when everything is already saved (counts up to 985/985, then done). A collapsible sync card (chevron) shows "985 में से 985 पेज सेव", a bar and "आख़िरी सिंक". No missing/failed counts are shown. The silent check also runs at app start. Cached data still shows instantly. |
| Status texts (सिंक हो रहा है, इंटरनेट नहीं · सेव किया डेटा चल रहा है, नया डेटा नहीं मिला…) | ✅ | |
| Background page download (`savePages`): covers first, then pages, 6 workers, progress | ✅ ➕ | App-level service (`CatalogStore`), not tied to a screen. Runs on any screen, like the original. Downloads every picture the app shows (granth cover + प्रकाशन, every praman page + its granth picture), visited or not: 985 files / ≈570 MB for the live catalog on 2026-10-21. Incremental and resumable (saved files are skipped). 3 tries per picture plus a second pass. Stops below 150 MB free with a message. A granth is marked offline only when all of its pictures are saved. |
| Visible download progress | ➕ (new) | Floating pill on every screen: "सिंक हो रहा है… 245 / 985 पेज" with a bar. It does not block taps and hides when done. |
| "सारे ग्रंथ ऑफलाइन हो गए हैं" card | ➕ (new) | Same card as PDF-done. Shown once per completed library and again only after new content finishes downloading. The library signature is saved when the card is shown. |
| Online-only by design | ℹ️ | YouTube videos and the external "मूल ग्रंथ" links (`granthURL`: 63 archive.org, 3 share.google, 2 pCloud) open in the browser, as in the original. Fonts are bundled. |
| Storage: IndexedDB `granth-offline` (meta/images/gallery/folders) + localStorage keys | ✅ | App documents dir (`app_flutter/granth`), not the cache dir: `catalog.json`, `images/`, `gallery/`, `gallery.json`, `folders.json`. SharedPreferences use the same key names (`ui-cols`, `topic-cols`, `granth-cols`, `praman-cols`, `gallery-cols`, `granth-look`, `pdf-style`, `granth-hash`, `granth-nav`, `granth-offline-ids`). |
| Damaged / restored data | ➕ | Bad JSON → ignored, fresh sync. Gallery rows whose file is gone are dropped. Offline ids are reset when no pictures exist (restored backup). |
| Keep data on uninstall / reinstall | ➕ (new) | `hasFragileUserData=true` (Android 10+ "keep app data"). Auto Backup is on for settings + catalog only (no pictures/PDFs). The original had `allowBackup=false`. |
| Atomic writes | ➕ | Every JSON/PDF/gallery file is written as `.part` then renamed. Leftovers are cleaned at start. |

## Screens

| Feature | Status | Notes |
| --- | --- | --- |
| Mast: gradient, gold strip, logo, title, gallery + settings buttons | ✅ | Same CSS values. |
| Header stats (विषय / पवित्र ग्रन्थ / नए प्रमाण) with active glow | ✅ | Exact CSS: `0 0 0 2px gold, 0 0 18px gold-light 80%`, painted outside the tile only (like CSS). Fades in instead of snapping. |
| Hamburger menu (Dashboard / Topics / Granths / प्रमाण / Gallery) | ✅ | |
| Dashboard cards + note card | ➕ | Counts now update live after the first sync (they stayed 0 before). Numbers (cards and header stats) count up 0 → final once, when real data arrives. Later changes animate from the shown value. No replay on rebuild or settings change; it replays only on a fresh Dashboard open. |
| Topics: position sort, search, 1×1/2×2, card pills (प्रमाण, n/total, Share, PDF) | ✅ | |
| Multiple topic PDF (ordered pick, one combined PDF) | ✅ | |
| Granths header: "Multiple granth PDF" sits ~8 px lower so "Granths" stays on one line (checked at 360 dp, font scale 1.0 and 1.3) | ➕ | |
| Granths: position sort, search, 1×1/2×2/3×3, book-open animation, offline badge, granth URL, share, PDF | ✅ | |
| Multiple granth PDF | ➕ (new, requested) | Tick several granths; one PDF each, built in parallel. |
| Pramans: filters by topic / granth / id, chip with सभी प्रमाण, order rules (`order.ts`), card actions (zoom, save picture, share, PDF, YouTube) | ✅ | |
| Picture zoom (`PinchView`: pinch 1–4×, pan when zoomed, kept inside the frame, snaps to 1 near 1) | ✅ ➕ | `ZoomStage` in the praman viewer and the Gallery viewer. Pinch at the fingers 1–4×, pan when zoomed, edges kept in bounds, snaps back, flick glide. Double-tap zooms 2.5× at the tap point or back to 1× (gallery-style, requested; the original has none). The viewer claims the gesture, so the list behind it can no longer steal the pinch (that was the bug). |
| YouTube block | ✅ | |
| Gallery: PDF / picture tabs, folders, search, open / share / save / delete, 1×1/2×2 | ✅ | |
| सेटिंग: PDF सेटिंग, लेआउट 1×1/2×2 (all screens), hidden कार्ड स्टाइल (5 taps on Version), पीछे | ➕ | Every option now applies live and persists (before, the screens did not rebuild). |
| Card looks (combo, सादा, glass, neu, clay, material, flat, bento) | ✅ | |
| Search: Hindi + Roman (Hinglish) transliteration, fuzzy, synonyms | ➕ | Same matching; ~170× faster. 200 ms debounce; index built once per catalog, in the background. |
| Search analytics (search / search_empty after 800 ms) | ✅ | Same rule. Kept in a local event log (the original wrote it to its own admin DB layer). |
| Toasts, empty states, spinners, Hindi copy | ✅ | |
| Fonts: Noto Sans Devanagari, Yatra One, Tiro Devanagari Sanskrit, DM Sans | ✅ | Bundled. |

## PDF

| Feature | Status | Notes |
| --- | --- | --- |
| Styles "PDF विषय के साथ" (fill90) and "केवल चित्र" (original), remembered (`pdf-style`) | ✅ | |
| Content order: topic cover → for each granth (first time it appears): cover page + प्रकाशन page → its pramans (`order.ts`) | ✅ | |
| fill90 page: header text (maroon 17/16 pt), picture with 1 pt black border, footer (title · meta, brown 15/14 pt), font shrinks to 13 pt, long text flows on extra pages, landscape for wide pictures | ✅ | |
| original: picture only, white page, 10 pt margin, landscape when wide; text page only when the picture is missing | ✅ | |
| Decorated topic cover (radial blobs, vignette, triple frame, Yatra One title, body, "ग्रंथ प्रबंधन") | ✅ | |
| Page number stamp (Helvetica 11, maroon, cream tab) | ✅ | |
| Picture prep: JPEG kept as-is when it fits, else flatten on white + scale to 1800 px + JPEG | ➕ | Done natively (Android codec, worker threads, reduced-size decode of huge photos). JPEGs up to 2600 px / 1.5 MB are embedded untouched (faster). |
| Progress tray: phases, %, ETA, रोकें, open / share / save, auto-save to Downloads | ➕ | No queue: up to 3 at once (1–2 on low-RAM phones), each with its own row and retry. |
| `PdfDock` arrow (`⌄ N`, rotates when open) toggling the task list | ✅ ➕ | Same arrow in the header. The list is a compact dropdown under the arrow. It is **collapsed by default** and does not auto-open (deliberate, requested; the original auto-opens its deck). Each row has × to remove it for good (a running PDF asks first, then stops). "तैयार हटाएँ" clears finished rows. Asking for the same PDF twice on purpose makes two entries; only a double tap within 1.5 s is ignored. |
| Background PDF + notification | ➕ (new) | Android foreground service (`PdfService`, type `dataSync`, `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_DATA_SYNC`). One ongoing notification ("2 PDF बन रही हैं — 45%"), plus a completion notification that opens the PDF (or the app). The service stops when no PDF is running. Android 15 `onTimeout` stops it cleanly. The Flutter engine is cached and kept while the service runs, so swiping the app away does not end a running PDF. Device-only behaviour (OEM killers, background rendering) is not verified in CI. |
| File names from title (70 chars), gallery ids `pdf-granth-/pdf-topic-/pdf-topics-/pdf-praman-`, marks granths offline | ✅ | |
| Save to Downloads (MediaStore on 10+, public folder + scan on ≤ 9) | ➕ | A failed copy deletes the pending MediaStore row or partial file. |

## Not ported (not part of the shipped app)

| Item | Why |
| --- | --- |
| `src/components/admin/*` (desk, inbox, manage), `admin-db`, roles, merge | Web-only admin/editor. Not in the APK bundle. |
| `feedback.tsx` (feedback / request form) | Present in the sources but not referenced by `app.tsx` and not in the shipped bundle. |
| `mobile/src/*` (old React Native screens, SQLite `db.ts`, ResourcePackService) | Dead code: `mobile/App.tsx` only hosts the WebView. |
| Web PWA (`sw.js`, `__grok` install page, auth/multiplayer libs, preview scripts) | Web hosting only. |

## Bugs found in the original app (not copied)

1. **PDF memory grows with the book.** `buildBookPdf` keeps every prepared picture in `shots[]` and the whole PDF in memory. It is then base64-chunked through the WebView bridge, which takes 3–4× the PDF size. Big granths can run out of memory.
   - Here: at most 3–8 pictures are held at a time, and pages stream to disk from a background isolate.
2. **Huge photos.** `fitShot` returns the original image when the canvas decode fails. A 60-megapixel page is then embedded as-is, or crashes the WebView.
   - Here: native reduced-size decode. Without native support, a placeholder page is used instead of decoding it.
3. **A failed picture is silent.** It becomes a page without the picture and nothing says why.
   - Here: the page shows "चित्र उपलब्ध नहीं…" and the row reports how many pictures were missing.
4. **Error text.** A failed PDF shows `error.message`, often English or technical.
   - Here: a clear Hindi message with "फिर कोशिश करें". Low storage gets its own message.
5. **Only one PDF at a time.** A long granth blocks every other request in the कतार.
   - Here: parallel slots.
6. **Tray cap of 12 rows.** `tasks.slice(0, 12)` could drop a still-running job from the list.
   - Here: only finished rows are trimmed.
7. **Finished PDFs stay in memory.** Their `Blob`s stay in RAM in the task list.
   - Here: files on disk only.
8. **Same link opened twice.** `sentLink` de-duplicates by exact URL forever, so opening the same shared link a second time does nothing.
   - Here: a 5 s de-dup window.
9. **Shared links could reach a blank screen.** A link delivered before the WebView was ready, and resume after the WebView renderer died, both needed a reload hack.
   - Here: native routing. The link is applied before the first frame.
10. **Dead layout controls.**
    - The Flutter port's own regression: 1×1 crashed into an empty screen, and the settings did not refresh open screens.
    - The original's grid worked; the port now matches it.
11. **Partial files.** No cleanup after a crash mid-save; MediaStore rows could stay pending.
    - Here: `.part` files, cleanup at start, and delete-on-failure.
12. **No free-space check.** A full disk fails late with a generic error.
    - Here: space is checked first, and ENOSPC is mapped to a clear message.
14. **Failed downloads counted as saved.** The original `savePages` counted a failed picture as done and always ended with done = total, with no retry. The strip then said "सभी पेज इस डिवाइस पर सेव हैं" even when pictures were missing.
    - Here: 3 tries plus a second pass. Failures are counted and tried again on the next sync. A granth is marked offline only when all of its pictures are saved.
15. **No storage guard for page downloads.** The original kept downloading until the disk was full.
    - Here: the download stops below 150 MB free.
16. **Frozen sync strip.** In the port the strip was a `const` child inside the store listener, so its spinner and text never changed after a tap ("tap does nothing"). When all pages were saved, the page step ended at once, so no progress showed. Fixed: the strip rebuilds from the store, and manual sync always checks pages visibly.
17. **Counters restarting from 0.** The splash returned its child in a different tree position when it finished, which rebuilt the whole shell. Fixed with a stable key; counters remember what they already showed.
13. **Dashboard counts.** They stayed at 0 until you navigated away and back after the first sync (port regression, fixed).
