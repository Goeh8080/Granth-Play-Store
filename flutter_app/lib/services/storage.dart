import 'dart:convert';
import 'dart:io';

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

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    if (_root == null) {
      final docs = await getApplicationDocumentsDirectory();
      _root = Directory('${docs.path}/granth');
      for (final d in ['images', 'gallery', 'pdfs', 'Granth']) {
        await Directory('${_root!.path}/$d').create(recursive: true);
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
