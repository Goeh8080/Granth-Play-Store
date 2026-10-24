import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter/foundation.dart';

import 'api.dart';
import 'pdf_stream.dart' show jpegComplete;
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
  final Dio _dio = _client();

  // Round 7: pictures someone is waiting for (a PDF being made, a page on screen) use their
  // own connections, so they never queue behind the background download of the library.
  final Dio _fast = _client();

  static Dio _client() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 20),
        // Time without any data arriving (not the whole download): a slow but moving
        // download of a big page is never cut off; a dead connection fails in 30 s.
        receiveTimeout: const Duration(seconds: 30),
      ))
        ..httpClientAdapter = IOHttpClientAdapter(
          createHttpClient: () => HttpClient()
            ..maxConnectionsPerHost = 8
            ..idleTimeout = const Duration(seconds: 30),
        );

  final Map<String, Future<File?>> _inflight = {};

  /// Priority fetches running now; the background download waits while any run.
  int _priority = 0;
  Completer<void>? _idle;

  @visibleForTesting
  int get priorityActive => _priority;

  void _enterPriority() => _priority++;

  /// A screen that needs the phone's CPU / network for itself (the Photo Highlighter) asks the
  /// background download to wait its turn; call the returned function when done (idempotent).
  VoidCallback holdBackground() {
    _enterPriority();
    var released = false;
    return () {
      if (released) return;
      released = true;
      _leavePriority();
    };
  }
  void _leavePriority() {
    _priority--;
    if (_priority <= 0) {
      _priority = 0;
      _idle?.complete();
      _idle = null;
    }
  }

  /// The background download calls this before each picture: it waits while a PDF or the
  /// screen needs pictures (at most [max], so a stuck foreground job never stops it).
  Future<void> backgroundTurn({Duration max = const Duration(seconds: 20)}) async {
    if (_priority == 0) return;
    _idle ??= Completer<void>();
    await _idle!.future.timeout(max, onTimeout: () {});
  }

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
  /// [priority]: someone is waiting for this picture (PDF, screen) — own connections, and
  /// the background download pauses meanwhile.
  Future<File?> get(String path, {bool priority = false}) {
    final hit = cachedSync(path);
    if (hit != null) return Future.value(hit);
    if (priority) {
      _enterPriority();
      // A background download of the same picture already running: wait for it (it is
      // already on the wire); otherwise fetch on the priority connections.
      final f = _inflight[path] ?? _start(path, _fast);
      return f.whenComplete(_leavePriority);
    }
    return _start(path, _dio);
  }

  // The cleanup must not hand back the removed entry: whenComplete waits for a
  // returned Future, and that entry is this very future, so get() would never finish.
  Future<File?> _start(String path, Dio via) => _inflight.putIfAbsent(path, () => _download(path, via).whenComplete(() {
        _inflight.remove(path);
      }));

  Future<File?> _download(String path, Dio via) async {
    try {
      final r = await via.get<List<int>>(urlFor(path), options: Options(responseType: ResponseType.bytes));
      final type = r.headers.value('content-type') ?? '';
      final raw = r.data;
      if (raw == null || raw.length < 32) return null;
      if (type.isNotEmpty && !type.startsWith('image/') && !_looksLikeImage(raw)) return null;
      final bytes = raw is Uint8List ? raw : Uint8List.fromList(raw);
      // Round 7: a cut-off or damaged download is never saved (it would become a broken page).
      if (!bytesLookComplete(bytes)) return null;
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

  /// Whole-file check of a downloaded / saved picture: JPEG marker structure through to its
  /// end marker, PNG chunks through IEND, WEBP/GIF size and trailer. False = cut off or damaged.
  static bool bytesLookComplete(Uint8List b) {
    if (b.length < 32) return false;
    if (b[0] == 0xFF && b[1] == 0xD8) return jpegComplete(b);
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) return _pngComplete(b);
    if (b[0] == 0x52 && b[1] == 0x49 && b[2] == 0x46 && b[3] == 0x46) {
      final size = b[4] | (b[5] << 8) | (b[6] << 16) | (b[7] << 24);
      return b.length >= size + 8;
    }
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) return b.last == 0x3B;
    // Another format (HEIC, AVIF, BMP…): no cheap check here — the decoders decide.
    return true;
  }

  static bool _pngComplete(Uint8List b) {
    var i = 8;
    var idat = false;
    while (i + 12 <= b.length) {
      final len = (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
      final type = String.fromCharCodes(b.sublist(i + 4, i + 8));
      if (len < 0 || i + 12 + len > b.length) return false;
      if (type == 'IDAT') idat = true;
      if (type == 'IEND') return idat;
      i += 12 + len;
    }
    return false;
  }

  static bool _looksLikeImage(List<int> b) =>
      b.length > 4 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50) || (b[0] == 0x52 && b[1] == 0x49) || (b[0] == 0x47 && b[1] == 0x49));
}
