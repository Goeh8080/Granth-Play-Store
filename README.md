# ग्रंथ प्रबंधन (Granth Prabandhan)

Website and Android app for browsing topics (विषय), granths (ग्रंथ) and pramans (प्रमाण),
saving pages offline and making PDFs.

- Version: see `mobile/version.properties` (currently **1.0.2**, versionCode **22**) — the single source for Gradle, CI, `app.json` and the in-app “संस्करण”.
- Package: `com.wnm.granthprabandhan`, one APK for `armeabi-v7a` + `arm64-v8a`.

## Layout

| Path | What |
| --- | --- |
| `src/` | The app UI (React 19, TanStack Start, Tailwind 4, Zustand + IndexedDB). Used by the website and inside the APK. |
| `src/routes/api/*` | Website-only proxy to the Granth API (the API sends no CORS headers). |
| `apk-shell/main.tsx`, `vite.apk.config.ts` | Builds the same UI into one self-contained HTML file for the APK. |
| `mobile/` | Expo / React Native shell: a WebView that shows `android/app/src/main/assets/web/index.html`, plus native save/share/open (`DownloadsModule.kt`). |

## Commands (Node ≥ 22.6, see `.nvmrc`)

```bash
npm ci
npm run dev          # website on :8080
npm run typecheck
npm run lint
npm test
npm run build        # website (Vercel preset)
npm run build:apk    # regenerate mobile/android/app/src/main/assets/web/index.html
```

## Android release

```bash
npm run build:apk
cd mobile && npm ci && cd android
export GRANTH_KEYSTORE_FILE=/path/to/granth-release.jks
export GRANTH_KEYSTORE_PASSWORD=…   GRANTH_KEY_ALIAS=granth-release   GRANTH_KEY_PASSWORD=…
./gradlew assembleRelease bundleRelease -PreactNativeArchitectures=armeabi-v7a,arm64-v8a
```

Without the signing variables Gradle prints a warning and signs with the debug key.

CI (`.github/workflows/android-apk.yml`) runs the web checks, rebuilds the embedded web
bundle and signs with these repository secrets:

| Secret | Value |
| --- | --- |
| `ANDROID_KEYSTORE_BASE64` | `base64 -w0 granth-release.jks` |
| `ANDROID_KEYSTORE_PASSWORD` | keystore password |
| `ANDROID_KEY_ALIAS` | `granth-release` |
| `ANDROID_KEY_PASSWORD` | key password (same as the keystore password for PKCS12) |

If they are missing the workflow still builds, marks the artifact `debug-signed` and shows a warning.
Never commit keystores or passwords.

Phone screenshots: `mobile/play-store/screenshots/`

Created by Faisal Rafi
