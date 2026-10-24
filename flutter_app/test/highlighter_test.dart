// Round 6: Photo Highlighter (lib/highlighter/) — the page patches, the local server /
// offline cache, the Hindi notices, the Android bridge script, and the menu entry.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/highlighter/highlighter_launcher.dart';
import 'package:granthprabandhan/highlighter/highlighter_server.dart';
import 'package:granthprabandhan/widgets/common.dart';

import 'helpers.dart';
import 'round5_test.dart' show fingerTap, openApp, realPause;

final original = File('assets/highlighter/index.html').readAsStringSync();

Future<ByteData> diskAsset(String key) async => ByteData.sublistView(File(key).readAsBytesSync());

Future<(int, String, String?)> get(Uri u, [String method = 'GET']) async {
  final c = HttpClient();
  try {
    final r = await (await c.openUrl(method, u)).close();
    final body = await r.transform(const Utf8Decoder(allowMalformed: true)).join();
    return (r.statusCode, body, r.headers.contentType?.mimeType);
  } finally {
    c.close(force: true);
  }
}

void main() {
  group('page patches (no feature changes)', () {
    test('the bundled page is the original file, byte for byte', () {
      final src = File('/workspace/inputs/photo_highlighter.html');
      if (src.existsSync()) expect(File('assets/highlighter/index.html').readAsBytesSync(), src.readAsBytesSync());
      expect(original, contains('tesseract.js@5/dist/tesseract.min.js'));
    });

    test('only the 4 CDN script sources change, plus one bridge script line and the OCR-overlay memo', () {
      final p = patchHighlighterHtml(original);
      for (final cdn in ['docs.opencv.org/4.x/opencv.js"', 'tesseract.js@5/dist', 'cdnjs.cloudflare.com']) {
        expect(p.contains('src="https://$cdn'), isFalse, reason: cdn);
      }
      expect(p, contains('<script async src="/cdn/docs.opencv.org/4.x/opencv.js">'));
      expect(p, contains('src="/cdn/cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js"></script>\n<script src="/hl-shim.js"></script>'));
      expect(p, contains('src="/lib/pdf.min.js"'));
      expect(p, contains('src="/lib/jspdf.umd.min.js"'));
      expect('/hl-shim.js'.allMatches(p), hasLength(1));
      // Undo the patches: the rest of the page is unchanged.
      final back = p
          .replaceFirst('\n<script src="/hl-shim.js"></script>', '')
          .replaceFirst('/cdn/docs.opencv.org/4.x/opencv.js', 'https://docs.opencv.org/4.x/opencv.js')
          .replaceFirst('/cdn/cdn.jsdelivr.net/npm/tesseract.js@5.1.1/dist/tesseract.min.js', 'https://cdn.jsdelivr.net/npm/tesseract.js@5/dist/tesseract.min.js')
          .replaceFirst('/lib/pdf.min.js', 'https://cdnjs.cloudflare.com/ajax/libs/pdf.js/3.11.174/pdf.min.js')
          .replaceFirst('/lib/jspdf.umd.min.js', 'https://cdnjs.cloudflare.com/ajax/libs/jspdf/2.5.1/jspdf.umd.min.js');
      final fn = RegExp(r'function renderOCROverlay\(\) \{[\s\S]*?overlay\.innerHTML = "";');
      final undone = back.replaceFirstMapped(fn, (_) => fn.firstMatch(original)!.group(0)!);
      expect(undone, original, reason: 'the memo is the only other change');
    });

    test('OCR overlay memo (Round 9): present once, guards the rebuild, no-op on a different page', () {
      final p = patchHighlighterHtml(original);
      expect(kHlOcrPatchMarker.allMatches(p), hasLength(1));
      final fn = p.substring(p.indexOf('function renderOCROverlay()'));
      expect(fn.indexOf('return;'), lessThan(fn.indexOf('overlay.innerHTML = "";')), reason: 'early return comes before the rebuild');
      expect(fn, contains('ocrWords'));
      for (final k in ['panX', 'panY', 'zoomScale', 'scanCanvas.width']) {
        expect(fn.substring(0, fn.indexOf('overlay.innerHTML = "";')), contains(k), reason: 'signature covers $k');
      }
      // A page without that function is served untouched (apart from the other patches).
      final other = original.replaceFirst('function renderOCROverlay()', 'function renderOCROverlay2()');
      expect(patchHighlighterHtml(other), isNot(contains(kHlOcrPatchMarker)));
    });

    test('pdf.js finds its worker next to it (pdf.worker.min.js is bundled)', () {
      expect(File('assets/highlighter/lib/pdf.worker.min.js').lengthSync(), greaterThan(500000));
      expect(File('assets/highlighter/lib/pdf.min.js').readAsStringSync(), contains('3.11.174'));
      expect(File('assets/highlighter/lib/jspdf.umd.min.js').readAsStringSync(), contains('2.5.1'));
    });
  });

  group('local server + offline cache', () {
    late Directory cache;
    late HighlighterServer s;
    var online = true;
    final fetched = <String>[];
    setUp(() async {
      HttpOverrides.global = null;
      cache = Directory.systemTemp.createTempSync('hlcache');
      online = true;
      fetched.clear();
      s = HighlighterServer(
        cacheDir: cache,
        loadAsset: diskAsset,
        fetchUpstream: (url, into) async {
          if (!online) throw const SocketException('offline');
          fetched.add(url);
          await into.writeAsString('/* $url */');
        },
      );
      await s.start();
    });
    tearDown(() async {
      await s.stop();
      cache.deleteSync(recursive: true);
    });

    test('fixed local port (keeps the album / theme storage of the page)', () {
      expect(HighlighterServer.ports, contains(s.port));
    });

    test('serves the patched page, the bundled libraries and the bridge', () async {
      final page = await get(s.origin);
      expect(page.$1, 200);
      expect(page.$3, 'text/html');
      expect(page.$2, contains('/hl-shim.js'));
      final pdf = await get(s.origin.resolve('/lib/pdf.min.js'));
      expect((pdf.$1, pdf.$3), (200, 'text/javascript'));
      expect(pdf.$2, contains('3.11.174'));
      expect((await get(s.origin.resolve('/lib/pdf.worker.min.js'))).$1, 200);
      expect((await get(s.origin.resolve('/hl-shim.js'))).$2, contains('GranthHL'));
      expect((await get(s.origin.resolve('/lib/../index.html'))).$1, anyOf(200, 404)); // normalised by the URI parser
      expect((await get(s.origin.resolve('/lib/nope.js'))).$1, 500);
      expect(fetched, isEmpty, reason: 'nothing from the internet for the bundled parts');
    });

    test('/__status: the Hindi notice for the native page (empty when nothing to say)', () async {
      var a = await get(s.origin.resolve('/__status'));
      expect((a.$1, a.$2, a.$3), (200, '', 'text/plain'));
      s.notice = () => 'पहली बार: सेव हो रही हैं — 25%';
      a = await get(s.origin.resolve('/__status'));
      expect(a.$2, 'पहली बार: सेव हो रही हैं — 25%');
      s.notice = () => null;
      expect((await get(s.origin.resolve('/__status'))).$2, '');
      expect(fetched, isEmpty);
    });

    test('OpenCV / Tesseract: fetched once, then served from the phone even offline', () async {
      const p = '/cdn/docs.opencv.org/4.x/opencv.js';
      final a = await get(s.origin.resolve(p));
      expect(a.$1, 200);
      expect(fetched, ['https://docs.opencv.org/4.x/opencv.js']);
      online = false;
      final b = await get(s.origin.resolve(p));
      expect(b.$1, 200);
      expect(b.$2, a.$2);
      expect(fetched, hasLength(1));
      expect(s.missedOffline.value, isFalse);
    });

    test('not saved yet and no internet: 503 and the offline notice', () async {
      online = false;
      final r = await get(s.origin.resolve('/tessdata/hin.traineddata.gz'));
      expect(r.$1, 503);
      expect(s.missedOffline.value, isTrue);
      expect(cache.listSync(), isEmpty, reason: 'no half file is kept');
    });

    test('language data and core map to the same CDN files Tesseract uses by default', () {
      expect(HighlighterServer.upstreamFor('/tessdata/eng.traineddata.gz'), 'https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz');
      expect(HighlighterServer.upstreamFor('/cdn/cdn.jsdelivr.net/npm/tesseract.js-core@v5.1.1/tesseract-core-lstm.wasm.js'), 'https://cdn.jsdelivr.net/npm/tesseract.js-core@v5.1.1/tesseract-core-lstm.wasm.js');
      expect(HighlighterServer.upstreamFor('/cdn/evil.example.com/x.js'), isNull);
      expect(HighlighterServer.upstreamFor('/cdn/cdn.jsdelivr.net/../../etc/passwd'), isNull);
      expect(HighlighterServer.upstreamFor('/tessdata/../x'), isNull);
      expect(hlContentType('/x/core.wasm'), 'application/wasm');
      expect(hlContentType('/tessdata/eng.traineddata.gz'), 'application/gzip');
    });

    test('other hosts are not reachable through the server', () async {
      expect((await get(s.origin.resolve('/cdn/evil.example.com/x.js'))).$1, 404);
      expect(fetched, isEmpty);
    });

    test('first open: everything OCR / scan need is saved, with progress', () async {
      final seen = <int>[];
      s.prefetch.addListener(() => seen.add(s.prefetch.value.done));
      expect(s.allCached, isFalse);
      expect(await s.prefetchAll(), isTrue);
      expect(s.allCached, isTrue);
      expect(fetched, hasLength(kHlRemotes.length));
      expect(seen.last, s.prefetch.value.total);
      expect(s.prefetch.value.running, isFalse);
      // Second open: nothing to download.
      fetched.clear();
      expect(await s.prefetchAll(), isTrue);
      expect(fetched, isEmpty);
    });
  });

  group('Hindi notice above the page', () {
    const idle = (done: 0, total: 0, running: false);
    test('nothing when OCR / scan are saved', () {
      expect(highlighterNotice(allCached: true, online: false, wifiOnlyWaiting: false, prefetch: idle, missed: true), isNull);
    });
    test('progress while saving, offline explanation, WiFi-only wait', () {
      expect(highlighterNotice(allCached: false, online: true, wifiOnlyWaiting: false, prefetch: (done: 50, total: 200, running: true), missed: false), contains('25%'));
      final off = highlighterNotice(allCached: false, online: false, wifiOnlyWaiting: false, prefetch: idle, missed: false)!;
      expect(off, startsWith('इंटरनेट नहीं है'));
      expect(off, contains('बिना इंटरनेट चलते हैं'));
      expect(highlighterNotice(allCached: false, online: true, wifiOnlyWaiting: true, prefetch: idle, missed: false), contains('WiFi'));
      expect(highlighterNotice(allCached: false, online: true, wifiOnlyWaiting: false, prefetch: idle, missed: false), isNull);
    });
  });

  test('bridge script: downloads in pieces, normal links untouched, Tesseract paths local', () async {
    final node = await Process.run('node', ['--version']).then((r) => r.exitCode == 0).catchError((Object _) => false);
    if (!node) return; // no Node on this machine
    final r = await Process.run('node', ['test/support/shim_harness.cjs', 'assets/highlighter/hl-shim.js']);
    expect(r.exitCode, 0, reason: '${r.stderr}');
    final o = jsonDecode('${r.stdout}'.trim()) as Map<String, dynamic>;
    expect(o['worker'], 'worker');
    expect(o['opts'], {
      'workerPath': 'http://127.0.0.1:47811/cdn/cdn.jsdelivr.net/npm/tesseract.js@v5.1.1/dist/worker.min.js',
      'corePath': 'http://127.0.0.1:47811/cdn/cdn.jsdelivr.net/npm/tesseract.js-core@v5.1.1',
      'langPath': 'http://127.0.0.1:47811/tessdata',
    });
    expect(o['dispatchResult'], isFalse, reason: 'FileSaver click is taken over');
    expect(o['canShare'], isTrue);
    final posted = (o['posted'] as List).cast<Map<String, dynamic>>();
    expect(posted.where((p) => p['t'] == 'native-click'), hasLength(1));
    final pdf = posted.firstWhere((p) => p['t'] == 'begin' && p['name'] == 'Album.pdf');
    expect((pdf['mime'], pdf['size'], pdf['mode']), ('application/pdf', 2000000, 'save'));
    final pieces = posted.where((p) => p['t'] == 'chunk' && p['id'] == pdf['id']).map((p) => p['len'] as int).toList();
    expect(pieces.length, greaterThan(1));
    expect(pieces.fold<int>(0, (a, b) => a + b), 2000000);
    expect(posted.where((p) => p['t'] == 'end' && p['id'] == pdf['id']), hasLength(1));
    expect(posted.any((p) => p['t'] == 'begin' && p['name'] == 'p.jpg'), isTrue);
  });

  group('launcher (native Activity)', () {
    late Directory cache;
    late HighlighterServer s;
    setUp(() {
      HttpOverrides.global = null;
      cache = Directory.systemTemp.createTempSync('hllaunch');
      s = HighlighterServer(cacheDir: cache, loadAsset: diskAsset, fetchUpstream: (url, into) async => into.writeAsString('x'));
    });
    tearDown(() async {
      await s.stop();
      cache.deleteSync(recursive: true);
    });

    test('starts the server, pauses the background download until the Activity closes, gives it the page URL', () async {
      var held = 0, released = 0;
      String? url;
      bool? awake;
      String? noticeWhileOpen;
      await HighlighterLauncher.openWith(
        server: s,
        net: () async => (online: false, wifiOnlyWaiting: false),
        keepAwake: true,
        hold: () {
          held++;
          return () => released++;
        },
        launch: (u, k) async {
          expect(released, 0, reason: 'download stays paused while the page is open');
          url = u;
          awake = k;
          noticeWhileOpen = (await get(Uri.parse('$u/__status'))).$2;
          expect((await get(Uri.parse(u))).$2, contains('/hl-shim.js'));
          return true;
        },
      );
      expect((held, released), (1, 1));
      expect(url, 'http://127.0.0.1:${s.port}');
      expect(awake, isTrue);
      expect(noticeWhileOpen, startsWith('इंटरनेट नहीं है'));
    });

    test('a failed launch still lets the download continue and a second tap is ignored while opening', () async {
      var released = 0;
      final gate = Completer<bool>();
      final first = HighlighterLauncher.openWith(
        server: s,
        net: () async => (online: true, wifiOnlyWaiting: true),
        keepAwake: false,
        hold: () => () => released++,
        launch: (u, k) => gate.future,
      );
      var launches = 0;
      await HighlighterLauncher.openWith(server: s, launch: (u, k) async { launches++; return true; });
      expect(launches, 0);
      gate.complete(false);
      await first;
      expect(released, 1);
      await HighlighterLauncher.openWith(server: s, net: () async => (online: true, wifiOnlyWaiting: true), keepAwake: false, hold: () => () {}, launch: (u, k) async { launches++; return true; });
      expect(launches, 1, reason: 'usable again afterwards');
    });
  });

  group('menu', () {
    setUp(setUpApp);
    testWidgets('5th menu entry, same style; opens the native Photo Highlighter', (t) async {
      var opened = 0;
      HighlighterLauncher.opener = (_) async => opened++;
      addTearDown(() => HighlighterLauncher.opener = (_) => HighlighterLauncher.openWith());
      await openApp(t);
      await fingerTap(t, find.byWidgetPredicate((w) => w is GIcon && w.name == 'menu'), wobble: Offset.zero);
      await realPause(t);
      await t.pumpAndSettle();
      expect(find.text('PHOTO HIGHLIGHTER'), findsOneWidget);
      for (final k in ['landmark', 'clipboard-list', 'library', 'image', 'highlighter']) {
        expect(find.byKey(ValueKey('nav-$k')), findsOneWidget);
      }
      // Same row style as the others: same height and icon size.
      final h1 = t.getSize(find.byKey(const ValueKey('nav-image'))).height;
      final h2 = t.getSize(find.byKey(const ValueKey('nav-highlighter'))).height;
      expect(h2, h1);
      await fingerTap(t, find.byKey(const ValueKey('nav-highlighter')), wobble: Offset.zero);
      await t.pumpAndSettle();
      expect(opened, 1);
      expect(find.text('PHOTO HIGHLIGHTER'), findsNothing, reason: 'menu closes as the page opens');
    });
  });
}
