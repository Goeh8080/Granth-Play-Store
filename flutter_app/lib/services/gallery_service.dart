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

  String _fileKey(String id) => id.replaceAll(RegExp(r'[^A-Za-z0-9_.-]+'), '_');

  Future<List<GalleryItem>> items() async {
    if (_items == null) {
      final raw = await Store.I.readJson('gallery.json');
      // Tolerate a damaged or restored index: skip bad rows and rows whose file is gone.
      final out = <GalleryItem>[];
      if (raw is List) {
        for (final e in raw.whereType<Map>()) {
          try {
            final it = GalleryItem.fromJson(Map<String, dynamic>.from(e));
            if (it.filePath.isNotEmpty && File(it.filePath).existsSync()) out.add(it);
          } catch (_) {}
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
      if (raw is List) {
        for (final e in raw.whereType<Map>()) {
          try {
            out.add(GalleryFolder.fromJson(Map<String, dynamic>.from(e)));
          } catch (_) {}
        }
      }
      _folders = out;
    }
    return [..._folders!]..sort((a, b) => a.name.compareTo(b.name));
  }

  Future<void> _persist() async {
    await Store.I.writeJson('gallery.json', _items!.map((e) => e.toJson()).toList());
    await Store.I.writeJson('folders.json', (_folders ?? []).map((e) => e.toJson()).toList());
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
  }
}
