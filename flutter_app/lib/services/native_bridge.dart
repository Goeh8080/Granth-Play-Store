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

  /// `exitApp` — finishes the task only after the in-app confirm.
  static Future<void> exitApp() async {
    try {
      await _ch.invokeMethod<void>('exitApp');
    } catch (_) {
      await SystemNavigator.pop();
    }
  }
}
