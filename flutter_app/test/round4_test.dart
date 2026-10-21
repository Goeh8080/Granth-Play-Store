import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

import 'helpers.dart';
import 'offline_test.dart' show FakeNet, pictureCatalog;

/// Lists that answer when [gate] opens (or at once).
class SlowApi extends Api {
  SlowApi(this.c);
  Catalog c;
  int calls = 0;
  Completer<void>? gate;
  @override
  Future<Catalog> fetchCatalog() async {
    calls++;
    if (gate != null) await gate!.future;
    return c;
  }
}

const jpg = [0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 0xFF, 0xD9];

Future<void> until(bool Function() ok, [int ms = 3000]) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (!ok() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(setUpApp);

  group('live page count', () {
    test('at start-up the count is the real number of saved files (folder listing), before any download', () async {
      final c = pictureCatalog();
      await Store.I.writeJson('catalog.json', c.toJson());
      Directory(Store.I.imagesDir).createSync(recursive: true);
      for (final p in ['granths/g10.jpg', 'uploads/p1.jpg', 'uploads/p2.jpg']) {
        ImageStore.I.fileFor(p).writeAsBytesSync(jpg);
      }
      // A damaged file and an unfinished download.
      ImageStore.I.fileFor('uploads/p3.jpg').writeAsBytesSync(jpg.sublist(0, 20));
      File('${ImageStore.I.fileFor('uploads/p4.jpg').path}.part').writeAsBytesSync(jpg);

      final api = SlowApi(c)..gate = Completer<void>();
      final s = CatalogStore(api: api, connectivity: const Stream.empty());
      CatalogStore.I = s;
      final net = FakeNet(s);
      s.verifyPages = (paths, progress) async => paths.where(net.saved.contains).toSet();
      final booting = s.boot();
      await until(() => s.images.total > 0);
      expect(s.images.total, 11);
      // The .part file never counts; the damaged one is in the folder, so the instant
      // count includes it until the background check removes it.
      expect(s.images.done, 4);
      expect(api.calls, 1, reason: 'the network sync is still on its way');

      // The silent check deletes the damaged file → the count drops by itself.
      await ImageStore.I.verify(['uploads/p3.jpg']);
      await until(() => s.images.done == 3);
      expect(s.images.done, 3);
      api.gate!.complete();
      await booting;
      await until(() => !s.images.running && s.images.done == 11);
      expect(s.images.done, 11, reason: 'then the download fills the rest');
    });

    test('background download counts up live, one page at a time, with no button press', () async {
      final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
      final net = FakeNet(s);
      final fetch = s.fetchPage;
      s.fetchPage = (p) async {
        await Future<void>.delayed(const Duration(milliseconds: 150));
        return fetch(p);
      };
      final seen = <int>[];
      // Round 5: the on-screen count comes from the throttled progress notifier.
      s.progress.addListener(() => seen.add(s.progress.value.done));
      s.savePages();
      await until(() => !s.images.running && s.images.done == 11);
      expect(net.saved.length, 11);
      expect(s.images.done, 11);
      expect(s.images.manual, isFalse);
      // Moved through in-between values (not 0 … then 11).
      expect(seen.toSet().where((n) => n > 0 && n < 11), isNotEmpty);
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]), reason: 'never jumps back to 0');
      }
    });

    test('a page opened on screen counts at once; a removed one is taken off', () async {
      final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
      FakeNet(s);
      s.pageSaved('uploads/p5.jpg', true);
      expect(s.images.done, 1);
      s.pageSaved('uploads/p5.jpg', true);
      expect(s.images.done, 1, reason: 'counted once');
      s.pageSaved('not/in/the/lists.jpg', true);
      expect(s.images.done, 1);
      s.pageSaved('uploads/p5.jpg', false);
      expect(s.images.done, 0);
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });

    test('the silent start-up check never shows the count from 0', () async {
      final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
      final net = FakeNet(s);
      net.saved.addAll(['granths/g10.jpg', 'granths/e10.jpg', 'granths/g11.jpg', 'uploads/p0.jpg']);
      for (final p in net.saved) {
        s.pageSaved(p, true);
      }
      expect(s.images.done, 4);
      final gate = Completer<void>();
      s.verifyPages = (paths, progress) async {
        progress(5);
        await gate.future;
        return paths.where(net.saved.contains).toSet();
      };
      final seen = <int>[];
      s.addListener(() => seen.add(s.images.done));
      s.savePages(verify: true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s.images.done, 4);
      gate.complete();
      await until(() => !s.images.running && s.images.done == 11);
      expect(seen.where((n) => n < 4), isEmpty);
    });
  });

  group('auto sync every 2 minutes', () {
    test('interval is 2 minutes', () {
      expect(CatalogStore.autoSyncEvery, const Duration(minutes: 2));
    });

    test('quiet: no "syncing" state, no pill when nothing changed, never two at once', () async {
      final c = pictureCatalog();
      final api = SlowApi(c);
      final s = CatalogStore(api: api, connectivity: const Stream.empty());
      CatalogStore.I = s;
      final net = FakeNet(s);
      await s.sync();
      net.saved.addAll(s.granths.expand((g) => [g.imagePath, g.editorImagePath]).whereType<String>());
      s.savePages();
      await until(() => !s.images.running && s.images.done == 11);
      expect(s.images.done, 11);

      final statuses = <SyncStatus>[];
      final running = <bool>[];
      s.addListener(() {
        statuses.add(s.status);
        running.add(s.images.running);
      });
      api.gate = Completer<void>();
      final a = s.autoSync();
      final b = s.autoSync();
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(api.calls, 2, reason: 'one initial sync + one auto sync (the second auto sync was skipped)');
      api.gate!.complete();
      await Future.wait([a, b]);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(statuses, isNot(contains(SyncStatus.syncing)));
      expect(running, isNot(contains(true)), reason: 'nothing to download → the pill never shows');
      expect(net.calls.values.fold<int>(0, (a, b) => a + b), 11 - 3, reason: 'no page fetched again');
      s.dispose();
    });

    test('new content: fetched quietly and only the new pages download', () async {
      final api = SlowApi(pictureCatalog());
      final s = CatalogStore(api: api, connectivity: const Stream.empty());
      CatalogStore.I = s;
      final net = FakeNet(s);
      await s.sync();
      s.savePages();
      await until(() => !s.images.running && s.images.done == 11);
      net.calls.clear();
      api.c = pictureCatalog(extra: 2);
      await s.autoSync();
      await until(() => !s.images.running && s.images.done == 13);
      expect(s.images.total, 13);
      expect(net.calls.keys.toSet(), {'uploads/p8.jpg', 'uploads/p9.jpg'});
      s.dispose();
    });

    test('in the background or offline it does nothing; back on screen it runs again', () async {
      final api = SlowApi(pictureCatalog());
      final s = CatalogStore(api: api, connectivity: const Stream.empty());
      CatalogStore.I = s;
      FakeNet(s);
      s.onPause();
      await s.autoSync();
      expect(api.calls, 0);
      s.onResume();
      await s.autoSync();
      expect(api.calls, 1);
      s.online = false;
      await s.autoSync();
      expect(api.calls, 1);
      s.stopSave();
      s.dispose();
    });

    test('a failed quiet sync leaves the screen as it was', () async {
      final s = CatalogStore(api: _FailApi(), connectivity: const Stream.empty());
      CatalogStore.I = s;
      s.debugSetCatalog(pictureCatalog());
      FakeNet(s);
      await s.autoSync();
      expect(s.error, isNull);
      expect(s.status, SyncStatus.ready);
      s.stopSave();
      s.dispose();
    });
  });

  group('smoothness', () {
    testWidgets('lists scroll like round 3 (no bounce) and the picture zoom still wins over the list', (tester) async {
      final key = GlobalKey<ZoomStageState>();
      final scroll = ScrollController();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(
        home: ListView(controller: scroll, children: [
          SizedBox(height: 600, child: ZoomStage(key: key, child: Container(color: Colors.brown))),
          const SizedBox(height: 900),
        ]),
      ));
      // Round 5: round-4 iOS bounce reverted (it made Android scrolling feel buffered).
      expect(scroll.position.physics, isNot(isA<BouncingScrollPhysics>()));
      await pinch(tester, const Offset(200, 300), 100, 300);
      expect(key.currentState!.view.scale, greaterThan(2.5));
      expect(scroll.offset, 0);
      await pinch(tester, const Offset(200, 300), 300, 80);
      await tester.pumpAndSettle();
      expect(key.currentState!.view.scale, 1);
      // Pulled past the top it stays at 0 (Android stretch, like round 3).
      final g = await tester.startGesture(const Offset(200, 700));
      for (var i = 0; i < 10; i++) {
        await g.moveBy(const Offset(0, 15));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(scroll.offset, 0);
      await g.up();
      await tester.pumpAndSettle();
      expect(scroll.offset, 0);
    });

    testWidgets('home screen scrolls (round-3 physics) with one finger and still pinch-zooms as a whole', (tester) async {
      AppZoom.current.value = ZoomView.identity;
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final list = tester.widget<CustomScrollView>(find.byType(CustomScrollView).first);
      expect(list.physics, isA<ClampingScrollPhysics>());
      final pos = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      await tester.dragFrom(const Offset(206, 700), const Offset(0, -300));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(pos.pixels, greaterThan(0));
      await pinch(tester, const Offset(206, 450), 100, 250);
      await tester.pump(const Duration(milliseconds: 300));
      expect(AppZoom.current.value.scale, greaterThan(2));
      AppZoom.current.value = ZoomView.identity;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 1));
    });
  });

  testWidgets('strip and sync card show the same live number (no pill)', (tester) async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    net.gate = Completer<void>();
    await tester.pumpWidget(const GranthApp(splash: false, links: false));
    await tester.pump(const Duration(milliseconds: 300));
    SyncStrip.open.value = true;
    s.savePages();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    // Let 3 pages land.
    for (final p in ['granths/g10.jpg', 'granths/e10.jpg', 'granths/g11.jpg']) {
      s.pageSaved(p, true);
    }
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.text('11 में से 3 पेज सेव'), findsOneWidget);
    expect(find.byKey(const ValueKey('sync-pill')), findsNothing);
    expect(find.textContaining('पेज सेव हो रहे हैं 3/11'), findsOneWidget);
    net.gate!.complete();
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('11 में से 11 पेज सेव'), findsOneWidget);
    SyncStrip.open.value = false;
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}

Future<void> pinch(WidgetTester t, Offset center, double from, double to) async {
  final a = await t.startGesture(center - Offset(from / 2, 0), pointer: 7);
  final b = await t.startGesture(center + Offset(from / 2, 0), pointer: 8);
  for (var i = 1; i <= 10; i++) {
    final d = from + (to - from) * i / 10;
    await a.moveTo(center - Offset(d / 2, 0));
    await b.moveTo(center + Offset(d / 2, 0));
    await t.pump(const Duration(milliseconds: 16));
  }
  await a.up();
  await b.up();
  await t.pump();
}

class _FailApi extends Api {
  @override
  Future<Catalog> fetchCatalog() async => throw const SocketException('offline');
}
