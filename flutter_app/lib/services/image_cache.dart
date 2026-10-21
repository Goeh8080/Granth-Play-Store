import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'api.dart';
import 'storage.dart';

/// Offline image store (IndexedDB `images` store in the web app).
/// Images are kept under app documents and re-used forever; the network is only a fallback.
class ImageStore {
  ImageStore._();
  static final ImageStore I = ImageStore._();

  final Dio _dio = Dio(BaseOptions(connectTimeout: const Duration(seconds: 20), receiveTimeout: const Duration(seconds: 90)));
  final Map<String, Future<File?>> _inflight = {};

  File fileFor(String path) => File('${Store.I.imagesDir}/${path.replaceAll('/', '__')}');

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

  Future<Set<String>> which(Iterable<String> paths) async {
    final out = <String>{};
    for (final p in paths) {
      if (cachedSync(p) != null) out.add(p);
    }
    return out;
  }

  /// Repair check: a saved picture is good when it exists, is not tiny and starts with a
  /// JPEG / PNG / GIF / WEBP header (a JPEG must also end with its end marker, which a cut-off
  /// download does not). Bad files are deleted so the download fetches them again.
  Future<Set<String>> verify(List<String> paths, {void Function(int checked)? onProgress}) async {
    final good = <String>{};
    var n = 0;
    for (final p in paths) {
      final f = fileFor(p);
      if (await fileLooksGood(f)) {
        good.add(p);
      } else {
        try {
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      n++;
      if (onProgress != null && (n % 25 == 0 || n == paths.length)) onProgress(good.length);
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
    return _inflight.putIfAbsent(path, () => _download(path).whenComplete(() => _inflight.remove(path)));
  }

  Future<File?> _download(String path) async {
    try {
      final r = await _dio.get<List<int>>(mediaUrl(path), options: Options(responseType: ResponseType.bytes));
      final type = r.headers.value('content-type') ?? '';
      final bytes = r.data;
      if (bytes == null || bytes.length < 32) return null;
      if (type.isNotEmpty && !type.startsWith('image/') && !_looksLikeImage(bytes)) return null;
      final f = fileFor(path);
      final part = File('${f.path}.part');
      await part.writeAsBytes(bytes, flush: true);
      await part.rename(f.path);
      return f;
    } catch (_) {
      return null;
    }
  }

  Future<Uint8List?> bytes(String path) async {
    final f = await get(path);
    return f?.readAsBytes();
  }

  static bool _looksLikeImage(List<int> b) =>
      b.length > 4 && ((b[0] == 0xFF && b[1] == 0xD8) || (b[0] == 0x89 && b[1] == 0x50) || (b[0] == 0x52 && b[1] == 0x49) || (b[0] == 0x47 && b[1] == 0x49));
}
