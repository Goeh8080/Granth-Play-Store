// Round 8 item 10: the embedded Photo Highlighter must open and run like the original page in a
// normal browser. Causes found (see docs/HIGHLIGHTER.md "Speed"): every library was re-sent on
// every open (`no-cache` and no validators → the 11 MB OpenCV came through Dart each time, and
// its compiled code could never be reused), bundled files were re-read and re-inflated from the
// APK per request, the WebView was composited by texture copy under the app-zoom clip layer,
// and the background page download kept running next to it.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/highlighter/highlighter_server.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

Future<HttpClientResponse> req(Uri u, {String method = 'GET', Map<String, String> headers = const {}}) async {
  final c = HttpClient();
  final rq = await c.openUrl(method, u);
  headers.forEach(rq.headers.set);
  final r = await rq.close();
  addTearDown(() => c.close(force: true));
  return r;
}

Future<List<int>> bodyOf(HttpClientResponse r) => r.fold<List<int>>([], (a, b) => a..addAll(b));

void main() {
  late Directory cache;
  late HighlighterServer s;
  final loads = <String>[];
  setUp(() async {
    HttpOverrides.global = null;
    cache = Directory.systemTemp.createTempSync('hlspeed');
    loads.clear();
    s = HighlighterServer(
      cacheDir: cache,
      loadAsset: (k) async {
        loads.add(k);
        return ByteData.sublistView(File(k).readAsBytesSync());
      },
      fetchUpstream: (url, into) async => into.writeAsBytes(List.filled(5000, 7)),
    );
    await s.start();
  });
  tearDown(() async {
    await s.stop();
    cache.deleteSync(recursive: true);
  });

  group('server caching', () {
    test('cache policy per kind of file', () {
      expect(HighlighterServer.cacheControlFor('/'), 'no-cache');
      expect(HighlighterServer.cacheControlFor('/hl-shim.js'), 'no-cache');
      expect(HighlighterServer.cacheControlFor('/lib/pdf.min.js'), contains('max-age=86400'));
      for (final p in ['/cdn/docs.opencv.org/4.x/opencv.js', '/tessdata/eng.traineddata.gz', '/cdn/cdn.jsdelivr.net/npm/tesseract.js-core@v5.1.1/tesseract-core-simd-lstm.wasm.js']) {
        expect(HighlighterServer.cacheControlFor(p), 'public, max-age=31536000, immutable', reason: p);
      }
    });

    test('big saved libraries: immutable + ETag; a revisit gets a bodiless 304', () async {
      final u = s.origin.resolve('/cdn/docs.opencv.org/4.x/opencv.js');
      final a = await req(u);
      expect(a.statusCode, 200);
      expect(a.headers.value('cache-control'), contains('immutable'));
      final tag = a.headers.value('etag')!;
      expect((await bodyOf(a)).length, 5000);
      final b = await req(u, headers: {'if-none-match': tag});
      expect(b.statusCode, 304);
      expect(await bodyOf(b), isEmpty);
      final c = await req(u, headers: {'if-none-match': '"stale"'});
      expect(c.statusCode, 200);
      expect((await bodyOf(c)).length, 5000);
    });

    test('page and bridge: always revalidated (an app update shows at once) but cheap (304)', () async {
      for (final p in ['/', '/hl-shim.js']) {
        final u = s.origin.resolve(p);
        final a = await req(u);
        expect(a.headers.value('cache-control'), 'no-cache', reason: p);
        final tag = a.headers.value('etag');
        expect(tag, isNotNull);
        await bodyOf(a);
        final b = await req(u, headers: {'if-none-match': tag!});
        expect(b.statusCode, 304, reason: p);
      }
    });

    test('bundled files are read from the APK once per run, not per request', () async {
      for (var i = 0; i < 4; i++) {
        await bodyOf(await req(s.origin));
        await bodyOf(await req(s.origin.resolve('/lib/pdf.worker.min.js')));
        await bodyOf(await req(s.origin.resolve('/hl-shim.js')));
      }
      expect(loads.where((k) => k.endsWith('index.html')), hasLength(1));
      expect(loads.where((k) => k.endsWith('pdf.worker.min.js')), hasLength(1));
      expect(loads.where((k) => k.endsWith('hl-shim.js')), hasLength(1));
    });

    test('content type of wasm stays application/wasm (streaming compile), body is sent as is', () async {
      expect(hlContentType('/x/core.wasm'), 'application/wasm');
      final r = await req(s.origin.resolve('/lib/pdf.min.js'), headers: {'accept-encoding': 'gzip'});
      expect(r.headers.value('content-encoding'), isNull, reason: 'loopback: no pointless gzip of big scripts');
      expect(r.headers.contentLength, File('assets/highlighter/lib/pdf.min.js').lengthSync());
      await bodyOf(r);
    });

    test('HEAD sends headers only', () async {
      final r = await req(s.origin.resolve('/lib/pdf.min.js'), method: 'HEAD');
      expect(r.statusCode, 200);
      expect(await bodyOf(r), isEmpty);
    });

    test('an updated saved library gets a new validator', () async {
      final u = s.origin.resolve('/tessdata/eng.traineddata.gz');
      final a = await req(u);
      final t1 = a.headers.value('etag');
      await bodyOf(a);
      final f = cache.listSync().whereType<File>().firstWhere((f) => f.path.contains('eng.traineddata'));
      f.writeAsBytesSync(List.filled(9000, 1));
      final b = await req(u);
      expect(b.headers.value('etag'), isNot(t1));
      expect((await bodyOf(b)).length, 9000);
    });
  });

  group('the app steps aside for the WebView', () {
    testWidgets('app zoom is switched off while the highlighter is open: no clip layer, zoom reset', (t) async {
      AppZoom.suspended.value = 0;
      await t.pumpWidget(const Directionality(textDirection: TextDirection.ltr, child: AppZoom(child: SizedBox.expand())));
      ClipRect clip() => t.widget<ClipRect>(find.descendant(of: find.byType(AppZoom), matching: find.byType(ClipRect)));
      expect(clip().clipBehavior, Clip.hardEdge);
      AppZoom.suspended.value++;
      await t.pump();
      expect(clip().clipBehavior, Clip.none);
      AppZoom.suspended.value--;
      await t.pump();
      expect(clip().clipBehavior, Clip.hardEdge);
    });

    test('the background page download waits while the highlighter holds it, and resumes after', () async {
      final store = ImageStore.I;
      expect(store.priorityActive, 0);
      final release = store.holdBackground();
      expect(store.priorityActive, 1);
      var turned = false;
      final turn = store.backgroundTurn().then((_) => turned = true);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(turned, isFalse);
      release();
      release(); // idempotent
      await turn;
      expect(turned, isTrue);
      expect(store.priorityActive, 0);
    });
  });
}
