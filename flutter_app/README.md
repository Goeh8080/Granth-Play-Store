# ग्रंथ प्रबंधन — Flutter

A native Flutter/Dart port of **ग्रंथ प्रबंधन** (Play Store 1.0.1, originally `com.wnm.granthprabandhan`)
by [ashok8090](https://github.com/ashok8090/Granth-Play-Store). The original was an Expo / React Native
shell around a React WebView (`index.html`). This port draws every screen natively in Flutter. It keeps the
same layout, colours, fonts (Noto Sans Devanagari, Yatra One, Tiro Devanagari Sanskrit), icons and Hindi text.
The only intended change is smoother animations.

This build is versioned **1.0.0 (versionCode 1)** for external testing; split APKs report the same versionCode.

This repository builds with the Android package / application id **`com.wnm.granthprabandhan`** — the same id as the Play Store app. It is signed with a different key, so Android will not install it over the Play Store build (uninstall one first). Deep links are unchanged: `granth://open?...` and `https://granth.grok.me/open?...`.

See [docs/PARITY.md](docs/PARITY.md) for the full feature-parity checklist against the original app, and the original bugs that were not copied.

## Features (ported from the web bundle)

| Area | What works |
| --- | --- |
| Catalog | `getTopics` / `getGranths` / `getPramans` from `granth.wnmsolutions.com`. Cached on the device (`catalog.json`) so the app opens offline. Syncs again every 2 min, when the app resumes (3 s debounce) and when the connection comes back. The सिंक button syncs on demand. |
| Offline pages | Every granth cover and praman page is downloaded in the background on open (8 parallel, kept-alive connections), covers first, and keeps going after the app is closed (quiet foreground notification). Pages changed on the server are re-downloaded (daily `Last-Modified` check). Progress shows in the sync strip (`पेज सेव हो रहे हैं d/t`). Granths that are fully saved get an `ऑफलाइन` pill. |
| Dashboard | Counts, note card, mail link to `sadgranthpraman@gmail.com` (tries Gmail first, then `mailto:`). |
| Topics | 1×1 / 2×2 grid, fuzzy Hindi/Hinglish search (a port of the original search pipeline), share link, topic PDF, **Multiple topic PDF** that merges several topics into one book. |
| Granths | 1×1 / 2×2 / 3×3 grid, cover viewer, image save, Share, Original PDF link, हाईलाइट PDF, **Multiple granth PDF** (one PDF per ticked granth, made in parallel). |
| प्रमाण | Filter by topic / granth / id. Ordered by chapter, verse and page, the same way the original orders them, including the Kabir Sagar book order. Thumbnails, मुख्य badge, YouTube player, topic and granth pills, Share, PDF. |
| Gallery | PDF / चित्र tabs, folders (create, rename, delete), move items to a folder, open, save to the phone, share, delete with confirmation. |
| PDF engine | A port of the original `buildBookPdf`. It has both styles: “PDF विषय के साथ” and “केवल चित्र”. It draws the decorated topic cover page, shapes Devanagari text with Flutter’s text engine, adds page numbers and a gallery preview. Pages stream to disk from a background isolate (flat memory). Pictures are embedded at full quality: JPEGs and PNGs untouched, other formats converted at full resolution (JPEG q95, max 4096 px). Up to 3 PDFs build at once (1–2 on low-RAM phones). Each has its own progress, ETA, रोकें, one automatic retry and a “फिर कोशिश करें” button. Free space is checked first, and partial files are always cleaned up. Finished PDFs are copied to **Downloads** and also saved in the app gallery. |
| Android | Deep links `granth://open?...` and `https://granth.grok.me/open?...`. Back button: closes the open overlay, then walks the history, then a double back on the Dashboard asks before exiting. The last screen is restored when the app starts again. Pictures are saved to *Pictures/ग्रंथ प्रबंधन*. |
| Photo Highlighter | 5th menu entry. The bundled `photo_highlighter.html` in a full-screen WebView (gallery/camera picker, Downloads / share for its exports, OCR + auto-scan downloaded once and kept). See [docs/HIGHLIGHTER.md](docs/HIGHLIGHTER.md). |
| Settings | PDF style, global layout, hidden **कार्ड स्टाइल** setting (tap *Version* 5 times) with all 8 looks: Bento + Clay, सादा, Glass, Neu, Clay, Material, Flat, Bento (applies to the whole app). Also: text size, auto sync on/off, download only on WiFi, keep screen on, storage (saved pages, space, check + repair), share app, reset settings. |

## Animations added

- **Opening:** the beads of the mala string themselves around the logo, a saffron glow appears, then the title rises. The splash then zooms out while the app scales into place.
- **Moving between screens:** the next panel fades in and slides sideways. It comes from the right when you go deeper and from the left when you go back. Cards then appear one after another, each fading and sliding in.
- **Opening a granth:** the card swings open like a book cover (a 3-D tilt with a slight lift) before its प्रमाण list appears.
- **Images:** a Hero animation carries the tapped cover or page into the full-screen pinch-zoom viewer. Images fade in once loaded, and a shimmer shows while they load.
- **Small touches:**
  - buttons and cards shrink slightly when pressed;
  - the 1×1 / 2×2 / 3×3 switch slides between options;
  - the hamburger icon turns into ✕, and the menu slides open;
  - counts on the stats and dashboard count up;
  - the sync icon spins while syncing;
  - the PDF progress bar fills smoothly;
  - the PDF button in the header pops in, and its arrow turns when the progress panel opens;
  - toasts slide up;
  - dialogs rise into place (the original's own rise curve, `cubic(.22,1,.36,1)`);
  - the Top button slides in.

## Build

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release   # universal: build/app/outputs/flutter-apk/app-release.apk
flutter build apk --release --split-per-abi --target-platform android-arm64
                              # arm64 only: build/app/outputs/flutter-apk/app-arm64-v8a-release.apk
```

Requirements: Flutter 3.35+ (Dart ^3.9) and JDK 17. The release build is signed with the local Flutter
debug key. No signing keys are kept in this repository. Add your own `key.properties` to sign for the Play Store.

GitHub Actions (`.github/workflows/android-apk.yml`) builds the APK on every push and uploads it as the
`granth-flutter-apk` (universal) and `granth-flutter-apk-arm64` artifacts.

## Known gaps

- The admin/editor screens of the web bundle (`granth-admin` IndexedDB drafts) are not ported. They were empty in the APK build.
- The YouTube player is an embedded WebView iframe. Some videos may refuse to play when embedded.
- Storage permission is asked only when it is needed, and only on Android 9 and older.
