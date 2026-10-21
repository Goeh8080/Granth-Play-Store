import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import 'api.dart';
import 'storage.dart';

/// Offline image store (IndexedDB `images` store in the web app).
/// Images are kept under app documents and re-used forever; the network is only a fallback.
class ImageStore {
  ImageStore._();
  static final ImageStore I = ImageStore._();

  /// Where a picture is fetched from (tests point it at a local server).
  @visibleForTesting
  String Function(String path) urlFor = mediaUrl;

  // One keep-alive connection pool for the whole download (8 at a time to one host): no
  // new TLS handshake per page.
  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 90)))
    ..httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () => HttpClient()
        ..maxConnectionsPerHost = 8
        ..idleTimeout = const Duration(seconds: 30),
    );
  final Map<String, Future<File?>> _inflight = {};

  File fileFor(String path) => File('${Store.I.imagesDir}/${keyFor(path)}');

  /// File name of a picture inside the images folder.
  static String keyFor(String path) => path.replaceAll('/', '__');

  final StreamController<(String, bool)> _changes = StreamController.broadcast();

  /// Every picture saved (true) or removed as damaged (false), from any part of the app:
  /// the background download, a page opened on screen, the repair check.
  Stream<(String, bool)> get changes => _changes.stream;

  /// Names of the saved picture files, from one folder listing (no image is opened).
  /// Unfinished `.part` downloads don't count.
  Set<String> savedNamesSync() {
    try {
      final out = <String>{};
      for (final e in Directory(Store.I.imagesDir).listSync(followLinks: false)) {
        final n = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (!n.endsWith('.part')) out.add(n);
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Same, off the UI thread's critical path, and only files with real content (> 32 bytes).
  Future<Set<String>> savedNames() async {
    final out = <String>{};
    try {
      await for (final e in Directory(Store.I.imagesDir).list(followLinks: false)) {
        final n = e.path.substring(e.path.lastIndexOf('/') + 1);
        if (n.endsWith('.part') || e is! File) continue;
        try {
          if ((await e.stat()).size > 32) out.add(n);
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  Future<File?> cached(String path) async {
    final f = fileFor(path);
    try {
      if (await f.exists() && await f.length() > 32) return f;
    } catch (_) {}
    return null;
  }

  File? cachedSync(String path) {
    final f = fileFor(path);
    try {
      if (f.existsSync() && f.lengthSync() > 32) return f;
    } catch (_) {}
    return null;
  }

  /// Which of [paths] are saved (one folder listing, not one disk check per picture).
  Future<Set<String>> which(Iterable<String> paths) async {
    final names = await savedNames();
    return {for (final p in paths) if (names.contains(keyFor(p))) p};
  }

  /// Repair check: a saved picture is good when it exists, is not tiny and starts with a
  /// JPEG / PNG / GIF / WEBP header (a JPEG must also end with its end marker, which a cut-off
  /// download does not). Bad files are deleted so the download fetches them again.
  /// [onProgress] gets how many pictures were checked so far.
  Future<Set<String>> verify(List<String> paths, {void Function(int checked)? onProgress}) async {
    final good = <String>{};
    var n = 0;
    for (final p in paths) {
      final f = fileFor(p);
      if (await fileLooksGood(f)) {
        good.add(p);
      } else {
        try {
          if (await f.exists()) {
            await f.delete();
            _changes.add((p, false));
          }
        } catch (_) {}
      }
      n++;
      if (onProgress != null && (n % 25 == 0 || n == paths.length)) onProgress(n);
    }
    return good;
  }

  static Future<bool> fileLooksGood(File f) async {
    RandomAccessFile? r;
    try {
      if (!await f.exists()) return false;
      final len = await f.length();
      if (len <= 32) return false;
      r = await f.open();
      final head = await r.read(12);
      if (!_looksLikeImage(head)) return false;
      if (head[0] == 0xFF && head[1] == 0xD8) {
        final k = len < 256 ? len : 256;
        await r.setPosition(len - k);
        final tail = await r.read(k);
        for (var i = tail.length - 2; i >= 0; i--) {
          if (tail[i] == 0xFF && tail[i + 1] == 0xD9) return true;
        }
        return false;
      }
      return true;
    } catch (_) {
      return false;
    } finally {
      await r?.close();
    }
  }

  int countSync() {
    try {
      return Directory(Store.I.imagesDir).listSync().whereType<File>().where((f) => !f.path.endsWith('.part')).length;
    } catch (_) {
      return 0;
    }
  }

  /// `sn()` / `Oh()`: cached file, otherwise download once and keep.
  Future<File?> get(String path) {
    final hit = cachedSync(path);
    if (hit != null) return Future.value(hit);
    // The cleanup must not hand back the removed entry: whenComplete waits for a
    // returned Future, and that entry is this very future, so get() would never finish.
    return _inflight.putIfAbsent(path, () => _download(path).whenComplete(() {
          _inflight.remove(path);
        }));
  }

  Future<File?> _download(String path) async {
    try {
      final r = await _dio.get<List<int>>(urlFor(path), options: Options(responseType: ResponseType.bytes));
      final type = r.headers.value('content-type') ?? '';
      final bytes = r.data;
      if (bytes == null || bytes.length < 32) return null;
      if (type.isNotEmpty && !type.startsWith('image/') && !_looksLikeImage(bytes)) return null;
      final f = fileFor(path);
      final part = File('${f.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(f.path);
      _stampServerTime(f, r.headers.value('last-modified'));
      _changes.add((path, true));
      return f;
    } catch (_) {
      return null;
    }
  }

  /// The file's time becomes the server's Last-Modified, so a later re-upload under the
  /// same name is noticed by [changedOnServer] (whatever the phone's clock says).
  static void _stampServerTime(File f, String? lastModified) {
    if (lastModified == null) return;
    try {
      f.setLastModifiedSync(HttpDate.parse(lastModified));
    } catch (_) {}
  }

  /// True when the server has a newer copy of a saved picture (HEAD, Last-Modified newer
  /// than our file). Unknown / offline / not saved → false.
  Future<bool> changedOnServer(String path) async {
    final f = cachedSync(path);
    if (f == null) return false;
    try {
      final r = await _dio.head<void>(urlFor(path));
      final lm = r.headers.value('last-modified');
      if (lm == null) return false;
      final server = HttpDate.parse(lm);
      return server.difference(f.lastModifiedSync()) > const Duration(seconds: 2);
    } catch (_) {
      return false;
    }
  }

  /// Removes a saved picture (it is downloaded again by the next pass).
  Future<void> drop(String path) async {
    try {
      final f = fileFor(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    _changes.add((path, false));
  }

  Future<Uint8List?> bytes(String path) async {
    final f = await get(path);
    return f?.readAsBytes();
  }

  static bool _looksLikeImage(List<int> b) =>
      b.length > 4 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50) || (b[0] == 0x52 && b[1] == 0x49) || (b[0] == 0x47 && b[1] == 0x49));
}
