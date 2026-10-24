import 'dart:io';

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'file_actions.dart';
import 'storage.dart';

/// In-app gallery (IndexedDB `gallery` + `folders` stores in the web app).
class GalleryService extends ChangeNotifier {
  GalleryService._();
  static final GalleryService I = GalleryService._();

  List<GalleryItem>? _items;
  List<GalleryFolder>? _folders;

  // Round 7 (version-tolerant kept data): the index is never "cleaned" behind the user's back.
  // Rows that can't be shown now (the file is not there at the moment, or the row was written by
  // another app version in a shape this one doesn't know) are kept in the index file as they
  // are, and fields this version doesn't know are written back too. Only the user removing an
  // item (or folder) takes it out.
  final List<Map<String, dynamic>> _hiddenItems = [];
  final Map<String, Map<String, dynamic>> _rawItems = {};
  final List<Map<String, dynamic>> _hiddenFolders = [];
  final Map<String, Map<String, dynamic>> _rawFolders = {};

  /// The file of a row: where it says, else the same name in this install's gallery / PDF
  /// folders (the app's data folder can have another path after a restore or a move).
  static String? _resolve(String path) {
    if (path.isEmpty) return null;
    if (File(path).existsSync()) return path;
    final name = path.substring(path.lastIndexOf('/') + 1);
    if (name.isEmpty || !Store.I.ready) return null;
    for (final d in [Store.I.galleryDir, Store.I.pdfDir]) {
      final f = '$d/$name';
      if (File(f).existsSync()) return f;
    }
    return null;
  }

  String _fileKey(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');

  Future<List<GalleryItem>> items() async {
    if (_items == null) {
      final raw = await Store.I.readJson('gallery.json');
      // Tolerate a damaged or restored index: skip bad rows and rows whose file is gone.
      final out = <GalleryItem>[];
      _hiddenItems.clear();
      _rawItems.clear();
      if (raw is List) {
        for (final e in raw.whereType<Map>()) {
          final m = Map<String, dynamic>.from(e);
          try {
            final it = GalleryItem.fromJson(m);
            final at = it.id.isEmpty ? null : _resolve(it.filePath);
            if (at != null) {
              out.add(at == it.filePath ? it : it.withFile(at));
              _rawItems[it.id] = m;
            } else {
              _hiddenItems.add(m);
            }
          } catch (_) {
            _hiddenItems.add(m);
          }
        }
      }
      _items = out;
    }
    final out = [..._items!]..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<List<GalleryFolder>> folders() async {
    if (_folders == null) {
      final raw = await Store.I.readJson('folders.json');
      final out = <GalleryFolder>[];
      _hiddenFolders.clear();
      _rawFolders.clear();
      if (raw is List) {
        for (final e in raw.whereType<Map>()) {
          final m = Map<String, dynamic>.from(e);
          try {
            final f = GalleryFolder.fromJson(m);
            if (f.id.isEmpty) {
              _hiddenFolders.add(m);
            } else {
              out.add(f);
              _rawFolders[f.id] = m;
            }
          } catch (_) {
            _hiddenFolders.add(m);
          }
        }
      }
      _folders = out;
    }
    return [..._folders!]..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _persist() async {
    final shown = {for (final e in _items!) e.id};
    await Store.I.writeJson('gallery.json', [
      for (final e in _items!) {...?_rawItems[e.id], ...e.toJson()},
      ..._hiddenItems.where((m) => !shown.contains('${m['id']}')),
    ]);
    final shownF = {for (final e in _folders ?? <GalleryFolder>[]) e.id};
    await Store.I.writeJson('folders.json', [
      for (final e in _folders ?? <GalleryFolder>[]) {...?_rawFolders[e.id], ...e.toJson()},
      ..._hiddenFolders.where((m) => !shownF.contains('${m['id']}')),
    ]);
    notifyListeners();
  }

  /// Like [put] but copies an existing file (big PDFs are never loaded into memory).
  Future<GalleryItem> putFile({
    required String id,
    required GalleryKind kind,
    required String title,
    String text = '',
    String topic = '',
    String granth = '',
    String folderId = '',
    required String fileName,
    required String source,
    Uint8List? preview,
  }) async {
    await items();
    await folders();
    final ext = kind == GalleryKind.pdf ? 'pdf' : (fileName.contains('.') ? fileName.split('.').last : 'jpg');
    final file = File('${Store.I.galleryDir}/${_fileKey(id)}.$ext');
    final part = File('${file.path}.part');
    try {
      await File(source).copy(part.path);
      await part.rename(file.path);
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
    return _record(id: id, kind: kind, title: title, text: text, topic: topic, granth: granth, folderId: folderId, fileName: fileName, file: file, size: await file.length(), preview: preview);
  }

  /// `Be()` — put (insert or replace) a gallery item, writing its bytes to disk.
  Future<GalleryItem> put({
    required String id,
    required GalleryKind kind,
    required String title,
    String text = '',
    String topic = '',
    String granth = '',
    String folderId = '',
    required String fileName,
    required Uint8List bytes,
    Uint8List? preview,
  }) async {
    await items();
    await folders();
    final ext = kind == GalleryKind.pdf ? 'pdf' : (fileName.contains('.') ? fileName.split('.').last : 'jpg');
    final file = File('${Store.I.galleryDir}/${_fileKey(id)}.$ext');
    await FileActions.writeAtomic(file, bytes);
    return _record(id: id, kind: kind, title: title, text: text, topic: topic, granth: granth, folderId: folderId, fileName: fileName, file: file, size: bytes.length, preview: preview);
  }

  Future<GalleryItem> _record({
    required String id,
    required GalleryKind kind,
    required String title,
    required String text,
    required String topic,
    required String granth,
    required String folderId,
    required String fileName,
    required File file,
    required int size,
    Uint8List? preview,
  }) async {
    String? previewPath;
    if (preview != null) {
      try {
        final p = File('${Store.I.galleryDir}/${_fileKey(id)}.preview.jpg');
        await FileActions.writeAtomic(p, preview);
        previewPath = p.path;
      } catch (_) {}
    }
    final item = GalleryItem(
      id: id,
      kind: kind,
      title: title,
      text: text,
      topic: topic,
      granth: granth,
      folderId: folderId,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      size: size,
      fileName: fileName,
      filePath: file.path,
      previewPath: previewPath,
    );
    _items!.removeWhere((e) => e.id == id);
    _items!.add(item);
    await _persist();
    return item;
  }

  Future<void> setFolder(GalleryItem item, String folderId) async {
    await items();
    final i = _items!.indexWhere((e) => e.id == item.id);
    if (i >= 0) _items![i] = _items![i].copyWith(folderId: folderId);
    await _persist();
  }

  /// `Ve()`
  Future<void> remove(String id) async {
    await items();
    final hit = _items!.where((e) => e.id == id).toList();
    _items!.removeWhere((e) => e.id == id);
    for (final h in hit) {
      for (final p in [h.filePath, h.previewPath]) {
        if (p == null) continue;
        try {
          final f = File(p);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
    await _persist();
  }

  /// `Le()`
  Future<void> putFolder(GalleryFolder f) async {
    await folders();
    await items();
    _folders!.removeWhere((e) => e.id == f.id);
    _folders!.add(f);
    await _persist();
  }

  /// `Re()` — delete folder; its items move back to "no folder".
  Future<void> removeFolder(String id) async {
    await folders();
    await items();
    _folders!.removeWhere((e) => e.id == id);
    for (var i = 0; i < _items!.length; i++) {
      if (_items![i].folderId == id) _items![i] = _items![i].copyWith(folderId: '');
    }
    await _persist();
  }

  @visibleForTesting
  void debugReset() {
    _items = null;
    _folders = null;
    _hiddenItems.clear();
    _rawItems.clear();
    _hiddenFolders.clear();
    _rawFolders.clear();
  }
}
