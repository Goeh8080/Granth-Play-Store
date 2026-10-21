import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/widgets/pdf_sheets.dart';

import 'helpers.dart';

/// Catalog whose granths and pramans have pictures, like the live one.
Catalog pictureCatalog({int extra = 0}) => Catalog(
      topics: [Topic({'id': '1', 'title': 'गीता ज्ञान', 'position': '1'})],
      granths: [
        Granth({'id': '10', 'title': 'श्रीमद्भगवद्गीता', 'position': '1', 'imagePath': 'granths/g10.jpg', 'editorImagePath': 'granths/e10.jpg'}),
        Granth({'id': '11', 'title': 'कबीर सागर', 'position': '2', 'imagePath': 'granths/g11.jpg'}),
      ],
      pramans: [
        for (var i = 0; i < 8 + extra; i++)
          Praman({'id': '${100 + i}', 'title': 'पेज $i', 'topic_id': '1', 'granth_id': i.isEven ? '10' : '11', 'image_path': 'uploads/p$i.jpg', 'granth_image': i == 0 ? 'granths/g10.jpg' : ''}),
      ],
      syncedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
    );

/// Wires a fake network/disk into the store.
class FakeNet {
  FakeNet(this.store, {this.free = 4 << 30}) {
    store.fetchPage = (p) async {
      calls[p] = (calls[p] ?? 0) + 1;
      await Future<void>.value();
      if (gate != null) await gate!.future;
      final f = failTimes[p] ?? 0;
      if (calls[p]! <= f) return false;
      saved.add(p);
      return true;
    };
    store.havePages = (all) async => all.where(saved.contains).toSet();
    store.freeBytes = () async => free;
    store.retryBase = Duration.zero;
  }
  final CatalogStore store;
  int? free;
  Completer<void>? gate;
  final saved = <String>{};
  final calls = <String, int>{};
  final failTimes = <String, int>{};
}

Future<void> drain(CatalogStore s) async {
  for (var i = 0; i < 400 && (s.images.running || s.images.total == 0); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 2));
  }
  await Future<void>.delayed(Duration.zero);
}

void main() {
  setUp(setUpApp);

  test('full download: every granth + praman picture, deduplicated', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    s.savePages();
    await drain(s);
    // 3 granth pictures (g10 shared with praman 0) + 8 praman pages.
    expect(net.saved.length, 11);
    expect(s.images.done, 11);
    expect(s.images.total, 11);
    expect(s.images.complete, isTrue);
    expect(s.images.failed, 0);
    expect(s.offlineIds, {'10', '11'});
  });

  test('incremental + resumable: saved pictures are never fetched again', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    net.saved.addAll(['granths/g10.jpg', 'uploads/p1.jpg', 'uploads/p2.jpg']);
    s.savePages();
    await drain(s);
    expect(net.calls.keys, isNot(contains('uploads/p1.jpg')));
    expect(net.calls.length, 8);
    expect(s.images.done, 11);
  });

  test('flaky pictures are retried; permanent failures are counted, not marked offline', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    net.failTimes['uploads/p2.jpg'] = 2; // ok on 3rd try
    net.failTimes['uploads/p3.jpg'] = 99; // never
    s.savePages();
    await drain(s);
    expect(net.calls['uploads/p2.jpg'], 3);
    expect(net.saved, contains('uploads/p2.jpg'));
    // 3 tries + 3 in the second pass.
    expect(net.calls['uploads/p3.jpg'], 6);
    expect(s.images.done, 10);
    expect(s.images.failed, 1);
    expect(s.images.complete, isFalse);
    // p3 belongs to granth 11: only granth 10 is fully offline.
    expect(s.offlineIds, {'10'});
    expect(s.offlineReady.value, isNull);
  });

  test('low storage stops the download with a message', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s, free: 40 << 20);
    s.savePages();
    await drain(s);
    expect(net.calls, isEmpty);
    expect(s.images.lowSpace, isTrue);
    expect(s.images.running, isFalse);
    expect(s.error, kLowSpaceStop);
    expect(s.offlineIds, isEmpty);
  });

  test('offline-ready fires once per completed library, again after new content', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    FakeNet(s);
    s.savePages();
    await drain(s);
    final r = s.offlineReady.value;
    expect(r, isNotNull);
    expect(r!.pages, 11);
    expect(r.granths, 2);
    s.ackOfflineReady();
    expect(Store.I.getString(Store.kOfflineReady), r.signature);

    // Re-open / re-sync with the same library: no card.
    s.savePages();
    await drain(s);
    expect(s.offlineReady.value, isNull);

    // New pramans arrive and finish downloading: card again.
    s.debugSetCatalog(pictureCatalog(extra: 2));
    s.savePages();
    await drain(s);
    expect(s.offlineReady.value?.pages, 13);
  });

  test('not acknowledged (app killed before the card showed) → shown next start', () async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    s.savePages();
    await drain(s);
    expect(s.offlineReady.value, isNotNull);
    final fresh = CatalogStore(connectivity: const Stream.empty());
    fresh.debugSetCatalog(pictureCatalog());
    FakeNet(fresh).saved.addAll(net.saved);
    fresh.havePages = (all) async => all.where(net.saved.contains).toSet();
    fresh.savePages();
    await drain(fresh);
    expect(fresh.offlineReady.value, isNotNull);
  });

  testWidgets('no floating pill while downloading: progress shows in the strip, card after', (tester) async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    await tester.binding.setSurfaceSize(const Size(412, 915));
    await tester.pumpWidget(const GranthApp(splash: false, links: false));
    await tester.pump(const Duration(milliseconds: 500));
    net.gate = Completer<void>();
    s.savePages();
    await tester.pump(const Duration(milliseconds: 400));
    // Round 5: the bottom-left pill is gone for good.
    expect(find.byKey(const ValueKey('sync-pill')), findsNothing);
    expect(find.textContaining('सिंक हो रहा है…'), findsNothing);
    expect(find.textContaining('पेज सेव हो रहे हैं 0/11'), findsOneWidget);

    net.gate!.complete();
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
    expect(s.images.running, isFalse, reason: '${s.images.done}/${s.images.total} ${net.calls} ${net.saved.length}');
    // And the offline-ready card popped up once.
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.text('सारे ग्रंथ ऑफलाइन हो गए हैं — अब बिना इंटरनेट के चलेंगे'), findsOneWidget);
    expect(find.byType(OfflineReadyCard), findsOneWidget);
    await tester.tap(find.text('ठीक है'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(OfflineReadyCard), findsNothing);
    expect(s.offlineReady.value, isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('offline-ready card is not shown again on the next open', (tester) async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    FakeNet(s);
    s.savePages();
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.offlineReady.value, isNotNull);
    s.ackOfflineReady();
    s.savePages();
    await tester.pump(const Duration(milliseconds: 100));
    expect(s.images.complete, isTrue);
    await tester.pumpWidget(const GranthApp(splash: false, links: false));
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(OfflineReadyCard), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
