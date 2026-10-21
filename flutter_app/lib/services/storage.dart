import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Replaces the web app's localStorage + IndexedDB (`granth-offline`).
/// Keys are kept identical to the original so behaviour maps 1:1.
class Store {
  Store._();
  static final Store I = Store._();

  SharedPreferences? _prefs;
  Directory? _root;

  static const kTopicCols = 'topic-cols';
  static const kGranthCols = 'granth-cols';
  static const kPramanCols = 'praman-cols';
  static const kGalleryCols = 'gallery-cols';
  static const kUiCols = 'ui-cols';
  static const kPdfStyle = 'pdf-style';
  static const kLook = 'granth-look';
  static const kHash = 'granth-hash';
  static const kOfflineIds = 'granth-offline-ids';
  static const kDevice = 'granth-device';

  /// Never throws and never hangs: each step has a timeout, and if the app documents
  /// directory is unavailable the cache falls back to a temp directory so the app still opens.
  Future<void> init() async {
    try {
      _prefs ??= await SharedPreferences.getInstance().timeout(const Duration(seconds: 4));
    } catch (e, st) {
      debugPrint('Store: prefs unavailable: $e\n$st');
    }
    if (_root == null) {
      try {
        final docs = await getApplicationDocumentsDirectory().timeout(const Duration(seconds: 4));
        _root = Directory('${docs.path}/granth');
      } catch (e) {
        debugPrint('Store: documents dir unavailable: $e');
        _root = Directory('${Directory.systemTemp.path}/granth');
      }
      for (final d in ['images', 'gallery', 'pdfs', 'Granth']) {
        try {
          await Directory('${_root!.path}/$d').create(recursive: true);
        } catch (_) {}
      }
    }
  }

  /// For tests: use an in-memory prefs instance and a temp directory.
  Future<void> initForTest(SharedPreferences prefs, Directory root) async {
    _prefs = prefs;
    _root = root;
    for (final d in ['images', 'gallery', 'pdfs', 'Granth']) {
      await Directory('${root.path}/$d').create(recursive: true);
    }
  }

  bool get ready => _prefs != null && _root != null;
  SharedPreferences get prefs => _prefs!;
  Directory get root => _root!;
  String get imagesDir => '${root.path}/images';
  String get galleryDir => '${root.path}/gallery';
  String get pdfDir => '${root.path}/Granth';

  String? getString(String k) => _prefs?.getString(k);
  Future<void> setString(String k, String v) async => _prefs?.setString(k, v);
  int? getInt(String k) {
    final v = _prefs?.get(k);
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  Future<void> setInt(String k, int v) async => _prefs?.setInt(k, v);

  Future<Object?> readJson(String name) async {
    final f = File('${root.path}/$name');
    if (!await f.exists()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } catch (_) {
      return null;
    }
  }

  Future<void> writeJson(String name, Object? value) async {
    final f = File('${root.path}/$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }
}
