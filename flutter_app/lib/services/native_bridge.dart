import 'dart:io';

import 'package:flutter/services.dart';

/// Dart side of `MainActivity.kt` — replaces the React Native `GranthDownloads` module.
class NativeBridge {
  NativeBridge._();
  static const _ch = MethodChannel('com.wnm.granthprabandhan/downloads');

  /// Copies a finished file into the public Downloads folder (MediaStore on Android 10+).
  static Future<String?> copyToDownloads(String path, String name, String mime) async {
    try {
      return await _ch.invokeMethod<String>('copyToDownloads', {'path': path, 'name': name, 'mime': mime});
    } catch (_) {
      return null;
    }
  }

  /// Saves an image into Pictures/ग्रंथ प्रबंधन (MediaStore album).
  static Future<String?> saveImageToAlbum(String path, String name, String mime) async {
    try {
      return await _ch.invokeMethod<String>('saveImage', {'path': path, 'name': name, 'mime': mime});
    } catch (_) {
      return null;
    }
  }

  /// Native picture scaling is used on Android; tests / other platforms use the Dart path.
  static bool nativeImages = Platform.isAndroid;

  /// Scales [src] to at most [maxSide] px and writes a JPEG to [out] on a native worker
  /// thread. Returns (w, h) or null on failure.
  static Future<({int w, int h})?> prepareImage(String src, String out, {int maxSide = 4096, int quality = 95}) async {
    if (!nativeImages) return null;
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('prepareImage', {'src': src, 'out': out, 'maxSide': maxSide, 'quality': quality}).timeout(const Duration(seconds: 60));
      final w = r?['w'], h = r?['h'];
      return w is int && h is int && w > 0 && h > 0 ? (w: w, h: h) : null;
    } catch (_) {
      return null;
    }
  }

  /// Keeps the screen awake while the app is on screen (window flag; off-device: no-op).
  static Future<void> keepScreenOn(bool on) async {
    try {
      await _ch.invokeMethod<void>('keepScreenOn', {'on': on}).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// SDK level, low-RAM flag and memory class from `ActivityManager` (null off-device).
  static Future<Map<String, Object?>?> deviceInfo() async {
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('deviceInfo').timeout(const Duration(seconds: 3));
      return r?.map((k, v) => MapEntry('$k', v));
    } catch (_) {
      return null;
    }
  }

  /// Notification questions that need an answer: `notifState` → {sdk, granted, enabled},
  /// `askNotifications` → bool (waits for the Android 13+ permission dialog),
  /// `openNotificationSettings` → bool. Null off-device or on error; never throws.
  static Future<Object?> pdfQuery(String method, Map<String, Object?> args) async {
    try {
      // The permission dialog waits for the user, so no short timeout there.
      final t = method == 'askNotifications' ? const Duration(minutes: 10) : const Duration(seconds: 5);
      return await _ch.invokeMethod<Object?>(method, args).timeout(t);
    } catch (_) {
      return null;
    }
  }

  /// PDF foreground service / notifications (`pdfProgress`, `pdfStop`, `pdfDone`).
  /// Never throws; does nothing off-device.
  static Future<void> pdfNotice(String method, Map<String, Object?> args) async {
    try {
      await _ch.invokeMethod<void>(method, args).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Page-download keep-alive service (`pagesProgress` {done,total}, `pagesStop`): keeps
  /// the full download running after the app is closed or swiped away. Never throws.
  static Future<void> pagesNotice(String method, Map<String, Object?> args) async {
    if (!Platform.isAndroid) return; // the service exists only on Android (and not in tests)
    try {
      await _ch.invokeMethod<void>(method, args).timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  /// Opens the native Photo Highlighter Activity (a plain WebView, no Flutter view in the touch
  /// path) on [url]; completes when it is closed. False when it could not be opened.
  static Future<bool> openHighlighter(String url, {bool keepAwake = false}) async {
    try {
      final r = await _ch.invokeMethod<bool>('openHighlighter', {'url': url, 'keepAwake': keepAwake});
      return r ?? false;
    } catch (_) {
      return false;
    }
  }

  /// Free bytes on the volume holding the app's files (null when unknown).
  static Future<int?> freeBytes() async {
    try {
      final r = await _ch.invokeMethod<Object?>('freeBytes').timeout(const Duration(seconds: 3));
      final n = r is int ? r : (r is num ? r.toInt() : null);
      return n == null || n < 0 ? null : n;
    } catch (_) {
      return null;
    }
  }

  /// `exitApp` — finishes the task only after the in-app confirm.
  static Future<void> exitApp() async {
    try {
      await _ch.invokeMethod<void>('exitApp');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }
}
