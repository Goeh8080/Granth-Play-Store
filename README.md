# Granth-Play-Store

ग्रंथ प्रबंधन 1.0.1

Download the phone APK from the GitHub Release, not from a desktop screenshot pack.

- Package: `com.wnm.granthprabandhan`
- versionName: `1.0.1`
- versionCode: `20`
- One APK for every phone: `armeabi-v7a` and `arm64-v8a`
- Sideload APK uses the old debug signature so it can update the test install. AAB is signed with the satlok keystore for Play Console.

Phone screenshots: `mobile/play-store/screenshots/`

Created by Faisal Rafi

## Flutter port (`flutter_app/`)

`flutter_app/` is a native Flutter/Dart rewrite of the same app: same package id, name, Hindi text, fonts, icons and layout, but drawn natively instead of in a WebView, with smoother animations. The React Native code above is unchanged.

```bash
cd flutter_app
flutter pub get
flutter analyze
flutter test
flutter build apk --release   # flutter_app/build/app/outputs/flutter-apk/app-release.apk
```

GitHub Actions (`.github/workflows/android-apk.yml`) now builds the Flutter APK and uploads it as the `granth-flutter-apk` artifact. See `flutter_app/README.md` for the full feature list, animations and known gaps.
