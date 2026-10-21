// Photo Highlighter (self-contained module; to be replaced by a Flutter version later).
//
// A tiny web server on 127.0.0.1 that serves the bundled `photo_highlighter.html` to the
// WebView, with its libraries:
//   /                 the page (original file, with the small patches in [patchHighlighterHtml])
//   /lib/…            pdf.js 3.11.174 (+ worker) and jsPDF 2.5.1, bundled in the APK
//   /hl-shim.js       the Android bridge (downloads, share, Tesseract paths)
//   /cdn/<host>/<p>   OpenCV.js and Tesseract (worker, core): fetched once, then kept in
//                     app storage and served from there — works offline afterwards
//   /tessdata/<l>.traineddata.gz   OCR language data (eng, hin), same files as the CDN
// A fixed port keeps the page's own storage (album in IndexedDB, theme) between visits.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The big libraries the page loads from the internet, cached on first use.
class HlRemote {
  const HlRemote(this.key, this.url, this.bytes, this.label);
  final String key; // local path under /cdn/ or /tessdata/
  final String url; // upstream https URL
  final int bytes; // approximate size, for progress
  final String label;
}

const kHlTesseractVersion = '5.1.1';

/// Everything OCR and auto-scan need offline (≈19 MB). Prefetched on the first open.
const kHlRemotes = [
  HlRemote('/cdn/docs.opencv.org/4.x/opencv.js', 'https://docs.opencv.org/4.x/opencv.js', 10964323, 'OpenCV'),
  HlRemote('/cdn/cdn.jsdelivr.net/npm/tesseract.js@$kHlTesseractVersion/dist/tesseract.min.js', 'https://cdn.jsdelivr.net/npm/tesseract.js@$kHlTesseractVersion/dist/tesseract.min.js', 66695, 'OCR'),
  HlRemote('/cdn/cdn.jsdelivr.net/npm/tesseract.js@v$kHlTesseractVersion/dist/worker.min.js', 'https://cdn.jsdelivr.net/npm/tesseract.js@v$kHlTesseractVersion/dist/worker.min.js', 123724, 'OCR'),
  HlRemote(
    '/cdn/cdn.jsdelivr.net/npm/tesseract.js-core@v$kHlTesseractVersion/tesseract-core-simd-lstm.wasm.js',
    'https://cdn.jsdelivr.net/npm/tesseract.js-core@v$kHlTesseractVersion/tesseract-core-simd-lstm.wasm.js',
    3938657,
    'OCR',
  ),
  HlRemote('/tessdata/eng.traineddata.gz', 'https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz', 2952873, 'English'),
  HlRemote('/tessdata/hin.traineddata.gz', 'https://cdn.jsdelivr.net/npm/@tesseract.js-data/hin/4.0.0_best_int/hin.traineddata.gz', 1389692, 'हिन्दी'),
];

/// Hosts the proxy may fetch from (nothing else is reachable through it).
const _hosts = {'docs.opencv.org', 'cdn.jsdelivr.net'};

/// The page as shipped, with only Android-compatibility changes (see docs/HIGHLIGHTER.md):
/// the four CDN `<script src>` become local URLs (Tesseract pinned to the version its CDN
/// default resolves to, so worker/core match), and the bridge script is added after
/// Tesseract. Nothing else in the file changes.
String patchHighlighterHtml(String html) {
  const subs = {
    'https://docs.opencv.org/4.x/opencv.js': '/cdn/docs.opencv.org/4.x/opencv.js',
    'https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js': '/cdn/cdn.jsdelivr.net/npm/tesseract.js@$kHlTesseractVersion/dist/tesseract.min.js',
    'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js': '/lib/pdf.min.js',
    'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js': '/lib/jspdf.umd.min.js',
  };
  var out = html;
  subs.forEach((from, to) => out = out.replaceFirst('src="$from"', 'src="$to"'));
  const tess = '/dist/tesseract.min.js"></script>';
  final i = out.indexOf(tess);
  if (i >= 0) {
    final at = i + tess.length;
    out = '${out.substring(0, at)}\n<script src="/hl-shim.js"></script>${out.substring(at)}';
  }
  return out;
}

/// Content type by file name.
String hlContentType(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.html') || p == '/' || p.isEmpty) return 'text/html; charset=utf-8';
  if (p.endsWith('.js')) return 'text/javascript; charset=utf-8';
  if (p.endsWith('.wasm')) return 'application/wasm';
  if (p.endsWith('.gz')) return 'application/gzip';
  if (p.endsWith('.json')) return 'application/json';
  return 'application/octet-stream';
}

class HighlighterServer {
  HighlighterServer({this.cacheDir, this.loadAsset, this.fetchUpstream});
  static HighlighterServer I = HighlighterServer();

  /// Where the downloaded libraries are kept (set before [start]; default: app storage).
  Directory? cacheDir;

  /// Bundled files (tests replace these).
  Future<ByteData> Function(String key)? loadAsset;

  /// Upstream download: writes [url] to [into]; throws when offline (tests replace it).
  Future<void> Function(String url, File into)? fetchUpstream;

  static const ports = [47811, 47812, 47813, 47814, 47815];
  HttpServer? _server;
  final Map<String, Future<File?>> _inflight = {};

  /// Bytes of [kHlRemotes] on the phone / total, while the first-time download runs.
  final ValueNotifier<({int done, int total, bool running})> prefetch = ValueNotifier((done: 0, total: 0, running: false));

  /// A library the page asked for could not be fetched (no internet, not saved yet).
  final ValueNotifier<bool> missedOffline = ValueNotifier(false);

  int? get port => _server?.port;
  Uri get origin => Uri.parse('http://127.0.0.1:${_server!.port}');

  Future<ByteData> _asset(String key) => (loadAsset ?? rootBundle.load)(key);

  Future<Uri> start() async {
    if (_server != null) return origin;
    for (final p in [...ports, 0]) {
      try {
        _server = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
        break;
      } catch (_) {}
    }
    final s = _server!;
    s.listen(_handle, onError: (Object _) {});
    return origin;
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    await s?.close(force: true);
  }

  File _cacheFile(String key) {
    final dir = cacheDir!;
    final safe = key.replaceAll(RegExp(r'[^A-Za-z0-9._@-]'), '_');
    return File('${dir.path}/$safe');
  }

  /// True when every library is saved (OCR and scan work offline).
  bool get allCached => cacheDir != null && kHlRemotes.every((r) => _cacheFile(r.key).existsSync());

  int get cachedBytes => cacheDir == null ? 0 : kHlRemotes.fold(0, (n, r) => n + (_cacheFile(r.key).existsSync() ? _cacheFile(r.key).lengthSync() : 0));

  /// Downloads whatever is not saved yet, one after another. Returns true when all are saved.
  Future<bool> prefetchAll() async {
    if (prefetch.value.running) return false;
    final total = kHlRemotes.fold(0, (n, r) => n + r.bytes);
    var done = 0;
    var ok = true;
    prefetch.value = (done: cachedBytes, total: total, running: true);
    try {
      for (final r in kHlRemotes) {
        final f = await _ensure(r.key, r.url);
        if (f == null) ok = false;
        done += f == null ? 0 : r.bytes;
        prefetch.value = (done: done, total: total, running: true);
      }
    } finally {
      prefetch.value = (done: done, total: total, running: false);
    }
    if (ok) missedOffline.value = false;
    return ok;
  }

  /// The upstream URL for a request path, or null when it is not allowed.
  static String? upstreamFor(String path) {
    for (final r in kHlRemotes) {
      if (r.key == path) return r.url;
    }
    if (path.startsWith('/cdn/')) {
      final rest = path.substring(5);
      final slash = rest.indexOf('/');
      if (slash <= 0) return null;
      final host = rest.substring(0, slash);
      final p = rest.substring(slash);
      if (!_hosts.contains(host) || p.contains('..')) return null;
      return 'https://$host$p';
    }
    final m = RegExp(r'^/tessdata/([a-z_]{3,10})\.traineddata\.gz$').firstMatch(path);
    if (m != null) {
      final l = m.group(1)!;
      return 'https://cdn.jsdelivr.net/npm/@tesseract.js-data/$l/4.0.0_best_int/$l.traineddata.gz';
    }
    return null;
  }

  Future<File?> _ensure(String key, String url) {
    final f = _cacheFile(key);
    if (f.existsSync() && f.lengthSync() > 0) return Future.value(f);
    return _inflight.putIfAbsent(
      key,
      () => _fetchOnce(key, url, f).whenComplete(() {
        _inflight.remove(key);
      }),
    );
  }

  Future<File?> _fetchOnce(String key, String url, File f) async {
    final part = File('${f.path}.part');
    {
      try {
        await f.parent.create(recursive: true);
        await (fetchUpstream ?? _download)(url, part);
        if (await part.length() == 0) throw const FileSystemException('empty');
        await part.rename(f.path);
        return f;
      } catch (e) {
        debugPrint('highlighter: $url: $e');
        try {
          if (await part.exists()) await part.delete();
        } catch (_) {}
        missedOffline.value = true;
        return null;
      }
    }
  }

  static Future<void> _download(String url, File into) async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 20);
    try {
      final req = await c.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      final sink = into.openWrite();
      try {
        await res.timeout(const Duration(seconds: 60)).pipe(sink);
      } catch (e) {
        await sink.close();
        rethrow;
      }
    } finally {
      c.close(force: true);
    }
  }

  Future<void> _handle(HttpRequest r) async {
    final res = r.response;
    try {
      final path = r.uri.path;
      res.headers.set('cache-control', 'no-cache');
      if (r.method != 'GET' && r.method != 'HEAD') {
        res.statusCode = 405;
        return;
      }
      if (path == '/' || path == '/index.html') {
        final html = utf8.decode((await _asset('assets/highlighter/index.html')).buffer.asUint8List(), allowMalformed: true);
        res.headers.contentType = ContentType.parse(hlContentType('/'));
        res.add(utf8.encode(patchHighlighterHtml(html)));
        return;
      }
      if (path == '/hl-shim.js' || path.startsWith('/lib/')) {
        final name = path == '/hl-shim.js' ? 'hl-shim.js' : 'lib/${path.substring(5)}';
        if (name.contains('..') || name.contains('/', name == 'hl-shim.js' ? 0 : 4)) {
          res.statusCode = 404;
          return;
        }
        final b = await _asset('assets/highlighter/$name');
        res.headers.contentType = ContentType.parse(hlContentType(name));
        res.add(b.buffer.asUint8List(b.offsetInBytes, b.lengthInBytes));
        return;
      }
      final up = upstreamFor(path);
      if (up == null) {
        res.statusCode = 404;
        return;
      }
      final f = await _ensure(path, up);
      if (f == null) {
        res.statusCode = 503; // not saved yet and no internet
        res.headers.contentType = ContentType.text;
        res.write('offline');
        return;
      }
      res.headers.contentType = ContentType.parse(hlContentType(path));
      res.headers.contentLength = await f.length();
      if (r.method == 'HEAD') return;
      await res.addStream(f.openRead());
    } catch (e) {
      try {
        res.statusCode = 500;
      } catch (_) {}
    } finally {
      try {
        await res.close();
      } catch (_) {}
    }
  }
}
