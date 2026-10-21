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
  static Future<({int w, int h})?> prepareImage(String src, String out, {int maxSide = 1800, int quality = 85}) async {
    if (!nativeImages) return null;
    try {
      final r = await _ch.invokeMethod<Map<Object?, Object?>>('prepareImage', {'src': src, 'out': out, 'maxSide': maxSide, 'quality': quality}).timeout(const Duration(seconds: 60));
      final w = r?['w'], h = r?['h'];
      return w is int && h is int && w > 0 && h > 0 ? (w: w, h: h) : null;
    } catch (_) {
      return null;
    }
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
