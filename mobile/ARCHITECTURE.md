# Architecture

```
WebView (react-native-webview)
  └─ file:///android_asset/web/index.html   ← the web UI from ../src, built by `npm run build:apk`
        │  fetch() to https://granth.wnmsolutions.com (needs allowUniversalAccessFromFileURLs: the API sends no CORS headers)
        │  IndexedDB: catalog, offline page images, gallery, PDFs
        │
        └─ window.__granthNative.postMessage(…)   (main frame only, per-launch token)
              ↓
App.tsx (bridge)  ── replies with window.__granthReply(reqId, { ok, error, uri })
  ├─ save-chunk / share-chunk / open-chunk   → file in app storage, then
  │     PDF → Downloads (MediaStore), picture → Pictures/Granth (MediaStore)
  │     share → expo-sharing, open → ACTION_VIEW (falls back to share when no viewer)
  ├─ open-saved / share-saved / export-saved → reuse the stored copy ("missing" if absent)
  ├─ net            → legacy relative /api/* fetches proxied natively
  ├─ open-url / open-mail / share-text / exit-app
  └─ hardware Back  → window.__granthBack() (MainActivity / back/GranthBack.kt)
```

## Native module `GranthDownloads` (`DownloadsModule.kt`)

| Method | Use |
| --- | --- |
| `beginWrite` / `appendWrite` / `finishWrite` | stream base64 chunks to a file, verify size and `%PDF` header |
| `copyToDownloads` | PDF → Downloads via MediaStore (no permission on Android 10+) |
| `copyToPictures` | picture → Pictures/Granth via MediaStore |
| `viewUri` | open a content:// URI; rejects `no-viewer` when nothing can open it |
| `getAppVersion`, `exitApp` | settings / exit dialog |

## Permissions

`INTERNET` only on Android 10+. Legacy storage permissions are limited to Android 9 and older.
No media-read or notification permissions are requested.

## Version and signing

`version.properties` is read by `android/app/build.gradle`; release signing comes from
`GRANTH_KEYSTORE_*` environment variables or Gradle properties (see the root README).
