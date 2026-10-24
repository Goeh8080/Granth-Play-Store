import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/image_size.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round5_test.dart' show openApp, realPause;

/// A valid PNG of [w]×[h] (all black): tiny on disk, real to the picture decoder.
Uint8List png(int w, int h) {
  final crcTable = List<int>.generate(256, (n) {
    var c = n;
    for (var k = 0; k < 8; k++) {
      c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
    }
    return c;
  });
  int crc(List<int> b) {
    var c = 0xFFFFFFFF;
    for (final x in b) {
      c = crcTable[(c ^ x) & 0xFF] ^ (c >> 8);
    }
    return c ^ 0xFFFFFFFF;
  }

  List<int> be(int v) => [(v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255];
  List<int> chunk(String type, List<int> data) {
    final td = [...type.codeUnits, ...data];
    return [...be(data.length), ...td, ...be(crc(td))];
  }

  final raw = Uint8List(h * (w + 1)); // filter 0 + w grey bytes per row
  return Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    ...chunk('IHDR', [...be(w), ...be(h), 8, 0, 0, 0, 0]),
    ...chunk('IDAT', zlib.encode(raw)),
    ...chunk('IEND', const []),
  ]);
}

/// Pictures of every height (like page scans), saved the way the app saves them.
int heightOf(int i) => 260 + (i * 97) % 900;

Catalog bigCatalog() {
  void save(String p, int i) {
    final f = ImageStore.I.fileFor(p);
    f.parent.createSync(recursive: true);
    f.writeAsBytesSync(png(600, heightOf(i)));
  }

  final granths = <Granth>[];
  for (var i = 0; i < 36; i++) {
    save('granths/g$i.png', i);
    granths.add(Granth({'id': '${10 + i}', 'title': 'ग्रंथ $i', 'author': 'लेखक $i', 'position': '${i + 1}', 'imagePath': 'granths/g$i.png', 'pramanCount': '4'}));
  }
  final pramans = <Praman>[];
  for (var i = 0; i < 120; i++) {
    save('uploads/p$i.png', i + 3);
    pramans.add(Praman({
      'id': '${100 + i}',
      'title': 'पेज $i',
      'description': i % 3 == 0 ? 'विवरण ' * (4 + i % 9) : '',
      'topic_id': '${1 + i % 5}',
      'granth_id': i < 70 ? '10' : '${11 + i % 35}',
      'image_path': 'uploads/p$i.png',
    }));
  }
  return Catalog(
    topics: [for (var i = 0; i < 60; i++) Topic({'id': '${1 + i}', 'title': 'विषय $i', 'description': 'ब्योरा ' * (1 + i % 6), 'position': '${i + 1}', 'praman_count': '2'})],
    granths: granths,
    pramans: pramans,
    syncedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
  );
}

ScrollPosition listPos(WidgetTester t) =>
    t.state<ScrollableState>(find.descendant(of: find.byType(CustomScrollView).first, matching: find.byType(Scrollable)).first).position;

/// Pictures decode on another thread in real time; let them finish between frames, as they
/// do on a phone.
Future<void> decodeWait(WidgetTester t, [int rounds = 4]) async {
  for (var i = 0; i < rounds; i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
    await t.pump(const Duration(milliseconds: 100));
  }
}

/// What a person sees: every card title on screen and where it sits.
Map<String, double> visibleTitles(WidgetTester t, RegExp re) {
  final out = <String, double>{};
  final h = t.view.physicalSize.height / t.view.devicePixelRatio;
  for (final e in find.byType(Text).evaluate()) {
    final w = e.widget as Text;
    final s = w.data;
    if (s == null || !re.hasMatch(s)) continue;
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.attached) continue;
    final y = box.localToGlobal(Offset.zero).dy;
    if (y > -200 && y < h + 200) out[s] = y;
  }
  return out;
}

/// Scrolls down like a person: drag, let pictures load, drag again.
Future<void> scrollDown(WidgetTester t, double px) async {
  var left = px;
  while (left > 0) {
    final d = left > 420 ? 420.0 : left;
    await t.drag(find.byType(CustomScrollView).first, Offset(0, -d), warnIfMissed: false);
    left -= d;
    await decodeWait(t, 2);
  }
  await decodeWait(t, 3);
}

Future<void> goBack(WidgetTester t) async {
  await realPause(t);
  await t.binding.handlePopRoute();
  await decodeWait(t, 3);
  await settle(t, 14); // the first 13 cards replay their 0.4–0.9 s entry slide
}

void main() {
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    Places.forgetLive();
    ImageSizes.I.clear();
    PaintingBinding.instance.imageCache.clear();
    CatalogStore.I.debugSetCatalog(bigCatalog());
  });

  void exact(WidgetTester t, double y0, Map<String, double> before, RegExp re, String why) {
    final p = listPos(t);
    expect(p.pixels, closeTo(y0, 0.6), reason: '$why: offset');
    final after = visibleTitles(t, re);
    expect(after.isNotEmpty, isTrue, reason: why);
    for (final e in before.entries) {
      if (e.value < -150 || e.value > 1000) continue;
      expect(after[e.key], isNotNull, reason: '$why: ${e.key} is back on screen');
      expect(after[e.key]!, closeTo(e.value, 1.0), reason: '$why: ${e.key} at the same height');
    }
    expect(t.takeException(), isNull);
  }

  group('back returns to the exact place', () {
    for (final n in [1, 2, 3]) {
      testWidgets('granth list, $n×$n: open a granth, back', (t) async {
        UiPrefs.I.setCols(Store.kGranthCols, n);
        await openApp(t);
        AppNav.I.go('#/granths');
        await settle(t);
        await decodeWait(t);
        await scrollDown(t, n == 1 ? 6000 : (n == 2 ? 3500 : 2500));
        final y0 = listPos(t).pixels;
        expect(y0, greaterThan(1500));
        final reG = RegExp('^ग्रंथ \\d+\$');
        final before = visibleTitles(t, reG);
        expect(before, isNotEmpty);
        // Tap a visible granth like a person.
        final title = before.entries.firstWhere((e) => e.value > 120 && e.value < 600).key;
        await t.tap(find.text(title).first);
        await settle(t, 4);
        expect(AppNav.I.route.panel, Panel.pramans);
        expect(AppNav.I.route.granthId, isNotNull);
        await decodeWait(t);
        await goBack(t);
        expect(AppNav.I.route.panel, Panel.granths);
        exact(t, y0, before, reG, '$n×$n');
      });
    }

    for (final n in [1, 2, 3]) {
      testWidgets('topic list, $n×$n: open a topic, back', (t) async {
        UiPrefs.I.setCols(Store.kTopicCols, n);
        await openApp(t);
        AppNav.I.go('#/topics');
        await settle(t);
        await decodeWait(t);
        await scrollDown(t, n == 1 ? 5000 : 3000);
        final y0 = listPos(t).pixels;
        expect(y0, greaterThan(1500));
        final re = RegExp(r'^\d+\. विषय \d+$');
        final before = visibleTitles(t, re);
        expect(before, isNotEmpty);
        AppNav.I.go('#/pramans?topic=${before.keys.first.split(' ').last}');
        await settle(t, 4);
        await decodeWait(t);
        await goBack(t);
        expect(AppNav.I.route.panel, Panel.topics);
        exact(t, y0, before, re, 'topics $n×$n');
      });
    }

    for (final n in [1, 2, 3]) {
      testWidgets('praman list, $n×$n: open one page, back', (t) async {
        UiPrefs.I.setCols(Store.kPramanCols, n);
        await openApp(t);
        AppNav.I.go('#/pramans');
        await settle(t);
        await decodeWait(t);
        await scrollDown(t, n == 1 ? 9000 : 6000);
        final y0 = listPos(t).pixels;
        expect(y0, greaterThan(3000));
        final re = RegExp(r'^पेज \d+$');
        final before = visibleTitles(t, re);
        expect(before, isNotEmpty);
        final id = 100 + int.parse(before.keys.first.split(' ').last);
        AppNav.I.go('#/pramans?id=$id');
        await settle(t, 4);
        await decodeWait(t);
        await goBack(t);
        expect(AppNav.I.route.pramanId, isNull);
        exact(t, y0, before, re, 'pramans $n×$n');
      });
    }

    testWidgets('home → granths → a granth → back → back → forward again', (t) async {
      UiPrefs.I.setCols(Store.kGranthCols, 2);
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await decodeWait(t);
      await scrollDown(t, 3000);
      final yG = listPos(t).pixels;
      final reG = RegExp(r'^ग्रंथ \d+$');
      final bG = visibleTitles(t, reG);
      final tt = bG.entries.firstWhere((e) => e.value > 120 && e.value < 600).key;
      await settle(t, 14);
      await t.tap(find.text(tt).first);
      await settle(t, 8);
      await decodeWait(t);
      await goBack(t);
      expect(AppNav.I.route.panel, Panel.granths);
      exact(t, yG, bG, reG, 'granth list');
      await goBack(t);
      expect(AppNav.I.route.panel, Panel.dashboard);
      expect(listPos(t).pixels, 0);
    });

    testWidgets('inside a big granth: scroll its pages, open one, back; then back to the granth list', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await decodeWait(t);
      await scrollDown(t, 500);
      final yG = listPos(t).pixels;
      final reG = RegExp(r'^ग्रंथ \d+$');
      final bG = visibleTitles(t, reG);
      AppNav.I.go('#/pramans?granth=10');
      await settle(t, 4);
      await decodeWait(t);
      await scrollDown(t, 5000);
      final yP = listPos(t).pixels;
      expect(yP, greaterThan(3000));
      final reP = RegExp(r'^पेज \d+$');
      final bP = visibleTitles(t, reP);
      expect(bP, isNotEmpty);
      AppNav.I.go('#/pramans?id=${100 + int.parse(bP.keys.first.split(' ').last)}&granth=10');
      await settle(t, 4);
      await decodeWait(t);
      await goBack(t);
      exact(t, yP, bP, reP, 'inside the granth');
      await goBack(t);
      expect(AppNav.I.route.panel, Panel.granths);
      exact(t, yG, bG, reG, 'granth list');
    });

    testWidgets('pinch-zoomed: scroll, open, back — same place, still zoomed', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await decodeWait(t);
      AppZoom.current.value = const ZoomView(1.8, Offset(-120, -200));
      await t.pump();
      await scrollDown(t, 2600);
      final y0 = listPos(t).pixels;
      expect(y0, greaterThan(1200));
      final re = RegExp(r'^ग्रंथ \d+$');
      final before = visibleTitles(t, re);
      AppNav.I.go('#/pramans?granth=${10 + 7}');
      await settle(t, 4);
      await decodeWait(t);
      await goBack(t);
      expect(AppNav.I.route.panel, Panel.granths);
      final p = listPos(t);
      expect(p.pixels, closeTo(y0, 0.6));
      final after = visibleTitles(t, re);
      expect(after.keys.toSet(), before.keys.toSet());
      for (final k in before.keys) {
        expect(after[k]!, closeTo(before[k]!, 1.0), reason: k);
      }
      expect(t.takeException(), isNull);
      AppZoom.current.value = ZoomView.identity;
    });

    testWidgets('right away, before a single picture has decoded, the place is already reached', (t) async {
      UiPrefs.I.setCols(Store.kGranthCols, 2);
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await decodeWait(t);
      await scrollDown(t, 9000);
      await settle(t, 14);
      final y0 = listPos(t).pixels;
      expect(y0, greaterThan(4000));
      AppNav.I.go('#/pramans?id=101');
      await settle(t, 4);
      await decodeWait(t);
      // The very end of the list: the saved place only exists when every row is full height.
      // Back with nothing decoded (a phone that is still busy reading the files):
      // no real-time pause, so no picture finishes decoding between these frames.
      PaintingBinding.instance.imageCache.clear();
      await t.binding.handlePopRoute();
      for (var i = 0; i < 6; i++) {
        await t.pump(const Duration(milliseconds: 16));
      }
      expect(AppNav.I.route.panel, Panel.granths);
      expect(listPos(t).pixels, closeTo(y0, 0.6), reason: 'at the saved place on the first frames');
      expect(listPos(t).maxScrollExtent, greaterThanOrEqualTo(y0), reason: 'the list is as tall as it was');
    });

    testWidgets('search text comes back with the position it belongs to', (t) async {
      await openApp(t);
      AppNav.I.go('#/pramans');
      await settle(t);
      await decodeWait(t);
      await t.enterText(find.byType(TextField).first, 'पेज 1');
      await settle(t, 5);
      await decodeWait(t);
      await scrollDown(t, 1400);
      await settle(t, 14);
      final y0 = listPos(t).pixels;
      expect(y0, greaterThan(500));
      final re = RegExp(r'^पेज \d+$');
      final before = visibleTitles(t, re);
      AppNav.I.go('#/pramans?id=101');
      await settle(t, 4);
      await decodeWait(t);
      await goBack(t);
      expect(Places.query('praman-list::'), 'पेज 1');
      expect(find.text('पेज 2'), findsNothing, reason: 'still filtered');
      exact(t, y0, before, re, 'search');
    });
  });

  group('places', () {
    testWidgets('saved in the original shape; old data without a search text still restores', (t) async {
      Store.I.setString('granth-list-place', jsonEncode({'y': 1234.5, 'count': 8, 'id': '', 'anchor': 0}));
      expect(Places.y('granth-list-place'), 1234.5);
      expect(Places.query('granth-list-place'), '');
      Places.setQuery('granth-list-place', 'gita');
      Places.save('granth-list-place', 99);
      final j = jsonDecode(Store.I.getString('granth-list-place')!) as Map;
      expect(j['y'], 99);
      expect(j['q'], 'gita');
      expect(j['count'], 8);
      Places.forgetLive();
      expect(Places.query('granth-list-place'), 'gita', reason: 'survives a restart');
      Store.I.setString('granth-list-place', 'not json');
      expect(Places.y('granth-list-place'), 0);
      Store.I.setString('granth-list-place', jsonEncode({'y': 'x'}));
      expect(Places.y('granth-list-place'), 0);
    });

    test('every list has its own place; a single page has none', () {
      final keys = {
        for (final h in ['#/dashboard', '#/topics', '#/granths', '#/gallery', '#/pramans', '#/pramans?granth=3', '#/pramans?topic=2', '#/pramans?granth=3&topic=2'])
          Places.keyFor(GRoute.parse(h))
      };
      expect(keys.length, 8);
      expect(Places.keyFor(GRoute.parse('#/pramans?id=5')), isNull);
    });

    test('picture shape from the file header (PNG, rotated and unrotated JPEG, junk)', () {
      expect(ratioOfHeader(png(600, 300)), 2.0);
      final fx = Directory('test/fixtures/pages');
      final n = ratioOfHeader(File('${fx.path}/normal.jpg').readAsBytesSync());
      expect(n, isNotNull);
      expect(n! > 0, isTrue);
      expect(ratioOfHeader(File('${fx.path}/rotated6.jpg').readAsBytesSync()), isNull, reason: 'EXIF-rotated: measured after decoding');
      expect(ratioOfHeader(Uint8List.fromList(List.filled(64, 7))), isNull);
      expect(ratioOfHeader(Uint8List(3)), isNull);
    });
  });
}
