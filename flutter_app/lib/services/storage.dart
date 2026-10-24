import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data_compat.dart';

/// Replaces the web app's localStorage + IndexedDB (`granth-offline`).
/// Keys are kept identical to the original so behaviour maps 1:1.
class Store {
  Store._();
  static final Store I = Store._();

  SharedPreferences? _prefs;
  Future<SharedPreferences>? _prefsLoad;
  Directory? _root;

  /// Values written in this session. Reads see them at once, so a setting changes on
  /// screen the moment it is tapped even while the preferences file is still opening (a
  /// slow cold start) or cannot be opened at all; they are written through when it is ready.
  final Map<String, Object> _mem = {};

  static const kTopicCols = 'topic-cols';
  static const kGranthCols = 'granth-cols';
  static const kPramanCols = 'praman-cols';
  static const kGalleryCols = 'gallery-cols';
  static const kUiCols = 'ui-cols';
  static const kPdfStyle = 'pdf-style';
  static const kLook = 'granth-look';

  // Extra settings (not in the web app). Stored as text like the others.
  static const kTextSize = 'granth-text-size';
  static const kWifiOnly = 'granth-wifi-only';
  static const kAutoSync = 'granth-auto-sync';
  static const kKeepAwake = 'granth-keep-awake';
  /// Round 8: "एनिमेशन" चालू ('1', default) / कम ('0') — the decorative entrance animations.
  static const kAnimations = 'granth-animations';

  static const kHash = 'granth-hash';
  static const kOfflineIds = 'granth-offline-ids';
  static const kDevice = 'granth-device';

  /// Layout version of the data kept on the phone (see data_compat.dart).
  static const kSchema = 'granth-schema';

  /// Notification permission asked once (first PDF).
  static const kNotifAsked = 'granth-notif-asked';

  /// The "notifications are off" hint was shown once.
  static const kNotifHint = 'granth-notif-hint';

  /// Never throws and never hangs: each step has a timeout, and if the app documents
  /// directory is unavailable the cache falls back to a temp directory so the app still opens.
  Future<void> init() async {
    if (_prefs == null) {
      final load = _prefsLoad ??= SharedPreferences.getInstance();
      try {
        _adopt(await load.timeout(const Duration(seconds: 4)));
      } catch (e) {
        // Too slow (or failed) at start-up: the app opens anyway, settings live in memory,
        // and the preferences are picked up (and written) as soon as they do arrive.
        debugPrint('Store: prefs not ready yet: $e');
        load.then(_adopt).catchError((Object e) => debugPrint('Store: prefs unavailable: $e'));
      }
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
    await DataCompat.migrate();
  }

  static Object? _safeGet(SharedPreferences p, String k) {
    try {
      return p.get(k);
    } catch (_) {
      return null;
    }
  }

  void _adopt(SharedPreferences p) {
    if (_prefs != null) return;
    _prefs = p;
    for (final e in _mem.entries) {
      if (e.key == kSchema) {
        // Never lower the layout version of data that a newer app left in the file.
        final have = int.tryParse('${_safeGet(p, kSchema)}') ?? 0;
        if (have > (int.tryParse('${e.value}') ?? 0)) continue;
      }
      final v = e.value;
      if (v is String) p.setString(e.key, v);
      if (v is int) p.setInt(e.key, v);
    }
  }

  /// For tests: use an in-memory prefs instance and a temp directory.
  Future<void> initForTest(SharedPreferences? prefs, Directory root) async {
    _mem.clear();
    _prefsLoad = null;
    _prefs = prefs;
    _root = root;
    for (final d in ['images', 'gallery', 'pdfs', 'Granth']) {
      await Directory('${root.path}/$d').create(recursive: true);
    }
  }

  /// Folders are there. Settings work even without the preferences file (memory first).
  bool get ready => _root != null;

  /// The preferences file is open (settings survive a restart).
  bool get persistent => _prefs != null;
  Directory get root => _root!;
  String get imagesDir => '${root.path}/images';
  String get galleryDir => '${root.path}/gallery';
  String get pdfDir => '${root.path}/Granth';

  /// For tests: preferences that arrive late (slow phone start-up).
  @visibleForTesting
  void debugAdoptPrefs(SharedPreferences p) => _adopt(p);

  /// A value of another type (an int / bool / list written by another app version and
  /// restored with the backup) reads as its text, never as an error.
  String? getString(String k) {
    final m = _mem[k];
    if (m != null) return m is String ? m : '$m';
    try {
      return _prefs?.getString(k);
    } catch (_) {
      try {
        final v = _prefs?.get(k);
        return v == null ? null : '$v';
      } catch (_) {
        return null;
      }
    }
  }

  Future<void> setString(String k, String v) async {
    _mem[k] = v;
    await _prefs?.setString(k, v);
  }

  /// Forget a setting (back to its default).
  Future<void> remove(String k) async {
    _mem.remove(k);
    await _prefs?.remove(k);
  }

  int? getInt(String k) {
    Object? v;
    try {
      v = _mem[k] ?? _prefs?.get(k);
    } catch (_) {}
    if (v is int) return v;
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v);
    return null;
  }

  /// Every key in the preferences file (this session's writes included).
  Set<String> get keys {
    try {
      return {...?_prefs?.getKeys(), ..._mem.keys};
    } catch (_) {
      return {..._mem.keys};
    }
  }

  /// The raw stored value of any type (null when unset or unreadable).
  Object? getRaw(String k) {
    try {
      return _mem[k] ?? _prefs?.get(k);
    } catch (_) {
      return null;
    }
  }

  /// Copies a saved file next to itself as `<name>.<tag>` (once) so something the app can't
  /// read is never lost when it is replaced by fresh data. Never throws.
  Future<void> keepCopy(String name, String tag) async {
    if (_root == null) return;
    try {
      final f = File('${root.path}/$name');
      final c = File('${root.path}/$name.$tag');
      if (await f.exists() && !await c.exists()) await f.copy(c.path);
    } catch (_) {}
  }

  Future<void> setInt(String k, int v) async {
    _mem[k] = v;
    await _prefs?.setInt(k, v);
  }

  /// Reads a JSON file; a missing or damaged file gives null (never throws).
  Future<Object?> readJson(String name) async {
    if (_root == null) return null;
    final f = File('${root.path}/$name');
    try {
      if (!await f.exists()) return null;
      final text = await f.readAsString();
      return jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  Future<String?> readText(String name) async {
    if (_root == null) return null;
    try {
      final f = File('${root.path}/$name');
      return await f.exists() ? await f.readAsString() : null;
    } catch (_) {
      return null;
    }
  }

  /// Bytes used by the saved pages (images folder), counted off the UI thread.
  Future<int> imagesBytes() async {
    if (_root == null) return 0;
    return compute(_dirBytes, imagesDir);
  }

  Future<void> writeJson(String name, Object? value) => writeText(name, jsonEncode(value));

  /// Atomic write of already-encoded text (the catalog is encoded off the UI thread).
  Future<void> writeText(String name, String text) async {
    final f = File('${root.path}/$name');
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(text, flush: true);
    await tmp.rename(f.path);
  }
}

int _dirBytes(String path) {
  var n = 0;
  try {
    for (final e in Directory(path).listSync(recursive: true, followLinks: false)) {
      if (e is File) {
        try {
          n += e.lengthSync();
        } catch (_) {}
      }
    }
  } catch (_) {}
  return n;
}
