import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/screens/splash_screen.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';

import 'helpers.dart';

enum Mode { ok, fail, hang, gated }

/// Answers like the real server: JSON text with `Content-Type: text/html`.
class FakeAdapter implements HttpClientAdapter {
  Mode mode = Mode.ok;
  int calls = 0;

  /// For [Mode.gated]: requests wait here until the test releases them.
  Completer<void> gate = Completer<void>();

  static final Map<String, Object> bodies = {
    'getTopics': {
      'success': true,
      'data': [
        {'id': '1', 'title': 'गीता ज्ञान', 'position': '1'},
      ],
    },
    'getGranths': {
      'success': true,
      'data': [
        {'id': '10', 'title': 'श्रीमद्भगवद्गीता', 'position': '1', 'topic_id': '1'},
      ],
    },
    'getPramans': {
      'success': true,
      'data': [
        {'id': '100', 'title': 'अध्याय 15', 'topic_id': '1', 'granth_id': '10'},
      ],
    },
  };

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    calls++;
    switch (mode) {
      case Mode.hang:
        return Completer<ResponseBody>().future;
      case Mode.gated:
        await gate.future;
        throw DioException.connectionError(requestOptions: options, reason: 'released as failure');
      case Mode.fail:
        throw DioException.connectionError(requestOptions: options, reason: 'offline');
      case Mode.ok:
        final r = options.queryParameters['request'] as String;
        return ResponseBody.fromString('\uFEFF${jsonEncode(bodies[r])}', 200, headers: {
          Headers.contentTypeHeader: ['text/html; charset=UTF-8'],
        });
    }
  }

  @override
  void close({bool force = false}) {}
}

Api fakeApi(FakeAdapter a, {Duration timeout = const Duration(seconds: 2)}) => Api(dio: Dio()..httpClientAdapter = a, timeout: timeout);

void main() {
  setUp(setUpApp);

  test('API JSON served as text/html is parsed (the real server does this)', () async {
    final c = await fakeApi(FakeAdapter()).fetchCatalog();
    expect(c.topics.length, 1);
    expect(c.granths.length, 1);
    expect(c.pramans.length, 1);
  });

  test('decodeApiList accepts maps, strings and BOM, rejects junk', () {
    expect(decodeApiList({'success': true, 'data': []}, 'x'), isEmpty);
    expect(decodeApiList('\uFEFF {"success":true,"data":[{"id":"1"}]}', 'x').single['id'], '1');
    expect(() => decodeApiList('<html>', 'x'), throwsFormatException);
    expect(() => decodeApiList({'success': false}, 'x'), throwsStateError);
  });

  test('a hanging network times out instead of blocking sync', () async {
    final a = FakeAdapter()..mode = Mode.hang;
    final store = CatalogStore(api: fakeApi(a, timeout: const Duration(milliseconds: 200)), connectivity: const Stream.empty());
    await store.sync().timeout(const Duration(seconds: 2));
    expect(store.status, SyncStatus.error);
    expect(store.error, kNoDataError);
    store.dispose();
  });

  Future<void> bootWith(WidgetTester tester, FakeAdapter a, {Duration timeout = const Duration(seconds: 2)}) async {
    await tester.binding.setSurfaceSize(const Size(412, 915));
    final store = CatalogStore(api: fakeApi(a, timeout: timeout), connectivity: const Stream.empty());
    CatalogStore.I = store;
    addTearDown(store.dispose);
    // boot() touches real files, so it runs outside the fake clock.
    late Future<void> boot;
    await tester.runAsync(() {
      boot = store.boot(); // started, not awaited
      return Future<void>.value();
    });
    await tester.pumpWidget(GranthApp(ready: boot, links: false));
  }

  /// Lets real file I/O and real network timeouts progress, then flushes frames.
  Future<void> realWait(WidgetTester tester, Duration d) async {
    await tester.runAsync(() => Future<void>.delayed(d));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> advance(WidgetTester tester, Duration d) async {
    final end = d.inMilliseconds ~/ 100;
    for (var i = 0; i < end; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('splash reaches home within 4 s while the network is silent, then shows error + retry', (tester) async {
    // The network stays silent until the test releases it (well after the splash is gone).
    final a = FakeAdapter()..mode = Mode.gated;
    await bootWith(tester, a, timeout: const Duration(seconds: 20));
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byKey(AnimatedSplash.overlayKey), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget); // home is built underneath

    await advance(tester, const Duration(seconds: 4));
    // The splash overlay is gone: only the home shell remains.
    expect(find.byKey(AnimatedSplash.overlayKey), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    await realWait(tester, const Duration(milliseconds: 300));
    expect(CatalogStore.I.status, SyncStatus.syncing);
    expect(find.text('डेटा लोड हो रहा है…'), findsOneWidget);

    // Now let the fetch fail (the timeout itself is covered by the unit test above).
    a.gate.complete();
    for (var i = 0; i < 30 && CatalogStore.I.status == SyncStatus.syncing; i++) {
      await realWait(tester, const Duration(milliseconds: 100));
    }
    expect(find.text('अभी खाली है'), findsOneWidget);
    expect(find.text('फिर कोशिश करें'), findsOneWidget);

    a.mode = Mode.ok;
    // Tap on the real clock: the retry does real file I/O when it saves the catalog.
    await tester.runAsync(() async {
      await tester.tap(find.text('फिर कोशिश करें'));
    });
    for (var i = 0; i < 30 && CatalogStore.I.status != SyncStatus.ready; i++) {
      await realWait(tester, const Duration(milliseconds: 100));
    }
    expect(CatalogStore.I.status, SyncStatus.ready);
    expect(CatalogStore.I.pramans.length, 1);
    expect(find.text('फिर कोशिश करें'), findsNothing);
  });

  testWidgets('splash reaches home when the network fails immediately', (tester) async {
    final a = FakeAdapter()..mode = Mode.fail;
    await bootWith(tester, a);
    await advance(tester, const Duration(milliseconds: 3600));
    expect(find.byKey(AnimatedSplash.overlayKey), findsNothing);
    expect(find.byType(HomeShell), findsOneWidget);
    await realWait(tester, const Duration(milliseconds: 500));
    expect(find.text('फिर कोशिश करें'), findsOneWidget);
  });

  testWidgets('splash gives up even if its ready future never completes', (tester) async {
    await tester.pumpWidget(MaterialApp(home: AnimatedSplash(ready: Completer<void>().future, child: const Text('home'))));
    await advance(tester, const Duration(milliseconds: 3600));
    expect(find.byKey(AnimatedSplash.overlayKey), findsNothing);
    expect(find.text('ग्रंथ प्रबंधन'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
