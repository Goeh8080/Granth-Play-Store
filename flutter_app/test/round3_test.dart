import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/screens/splash_screen.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/pdf_notify.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/pdf_sheets.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

import 'helpers.dart';
import 'offline_test.dart' show FakeNet, pictureCatalog;

class FakeApi extends Api {
  FakeApi(this.c);
  Catalog c;
  int calls = 0;
  @override
  Future<Catalog> fetchCatalog() async {
    calls++;
    return c;
  }
}

Future<void> frames(WidgetTester t, [int n = 10, int ms = 100]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(Duration(milliseconds: ms));
  }
}

PdfJob pjob(String id, {PdfPhase phase = PdfPhase.waiting, int percent = 0}) => PdfJob(id: id, title: 'श्रीमद्भगवत गीता code 17', fileName: '$id.pdf', galleryId: 'g-$id', dedupeKey: id)
  ..phase = phase
  ..percent = percent
  ..total = 53
  ..done = phase == PdfPhase.done ? 53 : 9;

void main() {
  setUp(() async {
    await setUpApp();
    PdfQueue.I.debugReset();
    PdfNotify.I.debugReset();
    PdfNotify.I.call = (m, a) async {};
    CountUp.debugClear();
    SyncStrip.open.value = false;
    AppZoom.current.value = ZoomView.identity;
  });

  // ---------------- 1. sync button ----------------
  group('sync button', () {
    testWidgets('tap re-fetches, checks every page, shows the card and n / total even when all is saved', (tester) async {
      final api = FakeApi(pictureCatalog());
      final s = CatalogStore(api: api, connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog());
      CatalogStore.I = s;
      final net = FakeNet(s);
      net.saved.addAll([for (final g in pictureCatalog().granths) ...[g.imagePath, g.editorImagePath]].where((e) => e.isNotEmpty));
      for (var i = 0; i < 8; i++) {
        net.saved.add('uploads/p$i.jpg');
      }
      s.verifyPages = (all, progress) async {
        progress(all.length);
        return all.where(net.saved.contains).toSet();
      };
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await frames(tester, 5);
      expect(find.byKey(const ValueKey('sync-card')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('sync-button')));
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byKey(const ValueKey('sync-card')), findsOneWidget, reason: 'instant feedback');
      // The catalog file write is real disk I/O.
      for (var i = 0; i < 20 && (s.status == SyncStatus.syncing || s.images.total == 0); i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
        await tester.pump(const Duration(milliseconds: 10));
      }
      await tester.pump(const Duration(milliseconds: 50));
      expect(api.calls, 1, reason: 'the button fetches the lists again');
      expect(find.byKey(const ValueKey('sync-card')), findsOneWidget);
      // Everything was already saved: the count is still shown (pill + card), then it ends.
      expect(find.text('सिंक हो रहा है… 11 / 11 पेज'), findsOneWidget);
      expect(find.text('11 में से 11 पेज सेव'), findsOneWidget);
      expect(net.calls, isEmpty);
      await frames(tester, 15);
      expect(s.images.running, isFalse);
      expect(find.textContaining('आख़िरी सिंक'), findsOneWidget);
      // The strip text follows the store (it used to be frozen).
      expect(find.textContaining('सभी पेज इस डिवाइस पर सेव हैं'), findsOneWidget);
      // (First complete library → the "सारे ग्रंथ ऑफलाइन" card; close it.)
      if (find.text('ठीक है').evaluate().isNotEmpty) {
        await tester.tap(find.text('ठीक है'));
        await frames(tester, 6);
      }
      // The arrow folds the card.
      await tester.tap(find.byKey(const ValueKey('sync-card-toggle')));
      await frames(tester, 4);
      expect(find.byKey(const ValueKey('sync-card')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });

    test('verify + repair: damaged / missing files are found and downloaded again', () async {
      final s = CatalogStore(api: FakeApi(pictureCatalog()), connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog());
      final net = FakeNet(s);
      s.minManualShow = Duration.zero;
      // 11 on disk, but the check finds 2 broken.
      s.verifyPages = (paths, progress) async => paths.where((p) => p != 'uploads/p3.jpg' && p != 'granths/g11.jpg').toSet();
      s.savePages(verify: true, manual: true);
      for (var i = 0; i < 200 && (s.images.running || s.images.total == 0); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(net.calls.keys.toSet(), {'uploads/p3.jpg', 'granths/g11.jpg'});
      expect(s.images.done, 11);
      expect(s.images.complete, isTrue);
    });

    test('ImageStore.verify keeps good pictures and deletes empty / cut-off / non-image files', () async {
      final st = ImageStore.I;
      Directory(Store.I.imagesDir).createSync(recursive: true);
      final jpg = [0xFF, 0xD8, 0xFF, 0xE0, ...List.filled(100, 7), 0xFF, 0xD9];
      final png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ...List.filled(100, 1)];
      st.fileFor('uploads/good.jpg').writeAsBytesSync(jpg);
      st.fileFor('uploads/good.png').writeAsBytesSync(png);
      st.fileFor('uploads/cut.jpg').writeAsBytesSync(jpg.sublist(0, 80));
      st.fileFor('uploads/empty.jpg').writeAsBytesSync([]);
      st.fileFor('uploads/html.jpg').writeAsBytesSync('<html>error page from a proxy ......................</html>'.codeUnits);
      final paths = ['uploads/good.jpg', 'uploads/good.png', 'uploads/cut.jpg', 'uploads/empty.jpg', 'uploads/html.jpg', 'uploads/missing.jpg'];
      final seen = <int>[];
      final ok = await st.verify(paths, onProgress: seen.add);
      expect(ok, {'uploads/good.jpg', 'uploads/good.png'});
      expect(seen.last, 2);
      expect(st.fileFor('uploads/cut.jpg').existsSync(), isFalse);
      expect(st.fileFor('uploads/html.jpg').existsSync(), isFalse);
      expect(st.fileFor('uploads/good.jpg').existsSync(), isTrue);
    });

    test('offline: the check runs, nothing is downloaded, and it finishes quickly', () async {
      final s = CatalogStore(connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog());
      final net = FakeNet(s);
      s.online = false;
      s.minManualShow = Duration.zero;
      s.verifyPages = (paths, progress) async => <String>{};
      s.savePages(verify: true);
      for (var i = 0; i < 100 && s.images.running; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 2));
      }
      expect(net.calls, isEmpty);
      expect(s.images.running, isFalse);
    });
  });

  // ---------------- 7. counters ----------------
  group('count-up', () {
    testWidgets('waits for data, counts 0 → value once, later changes go from the shown number', (tester) async {
      final n = ValueNotifier(0);
      Widget app() => MaterialApp(home: ValueListenableBuilder<int>(valueListenable: n, builder: (_, v, _) => CountUp(value: v, memo: 't:a', style: const TextStyle())));
      await tester.pumpWidget(app());
      expect(find.text('—'), findsOneWidget);
      n.value = 104;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      final mid = int.parse((tester.widget<Text>(find.byType(Text)).data)!);
      expect(mid, inInclusiveRange(1, 103));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('104'), findsOneWidget);
      n.value = 330;
      await tester.pump();
      for (var i = 0; i < 9; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        final v = int.parse((tester.widget<Text>(find.byType(Text)).data)!);
        expect(v, greaterThanOrEqualTo(104), reason: 'never restarts from 0');
      }
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('330'), findsOneWidget);
      // Re-created (e.g. a rebuild of the screen): stays at 330, no replay.
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(app());
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('330'), findsOneWidget);
    });

    testWidgets('the splash leaving does not rebuild the app under it (counters ran twice)', (tester) async {
      var inits = 0;
      await tester.pumpWidget(MaterialApp(
        home: AnimatedSplash(
          duration: const Duration(milliseconds: 200),
          maxWait: const Duration(milliseconds: 300),
          hardLimit: const Duration(milliseconds: 600),
          child: _InitCounter(onInit: () => inits++),
        ),
      ));
      await frames(tester, 20);
      expect(find.byKey(AnimatedSplash.overlayKey), findsNothing);
      expect(inits, 1);
    });

    testWidgets('dashboard counters reach the catalog numbers and do not restart on a data update', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await frames(tester, 15);
      final s = CatalogStore.I;
      expect(find.text('${s.pramans.length}'), findsWidgets);
      final c = sampleCatalog();
      s.debugSetCatalog(Catalog(topics: c.topics, granths: c.granths, pramans: [...c.pramans, ...c.pramans.map((p) => Praman({...p.raw, 'id': '9${p.id}'}))], syncedAt: c.syncedAt));
      await tester.pump(const Duration(milliseconds: 100));
      for (final t in tester.widgetList<CountUp>(find.byType(CountUp))) {
        expect(t.value, greaterThan(0));
      }
      final texts = tester.widgetList<Text>(find.descendant(of: find.byType(CountUp), matching: find.byType(Text))).map((e) => e.data).toList();
      expect(texts.where((e) => e == '0' || e == '1'), isEmpty, reason: 'no restart from 0: $texts');
      await frames(tester, 12);
      expect(find.text('6'), findsWidgets);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------- 2 + 3. zoom ----------------
  group('zoom', () {
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

    testWidgets('picture stage inside a scrolling list: pinch zooms (list does not steal it), pan is bounded, snaps back', (tester) async {
      final key = GlobalKey<ZoomStageState>();
      final scroll = ScrollController();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(
        home: ListView(controller: scroll, children: [
          SizedBox(height: 600, child: ZoomStage(key: key, child: Container(color: Colors.brown))),
          const SizedBox(height: 900),
        ]),
      ));
      await pinch(tester, const Offset(200, 300), 100, 300);
      expect(key.currentState!.view.scale, greaterThan(2.5));
      expect(scroll.offset, 0);
      // One finger now pans the picture, never past its edges.
      await tester.dragFrom(const Offset(200, 300), const Offset(2000, 2000));
      await tester.pumpAndSettle();
      final v = key.currentState!.view;
      expect(v.offset.dx, lessThanOrEqualTo(0));
      expect(v.offset.dy, lessThanOrEqualTo(0));
      expect(v.offset.dx, 0);
      expect(scroll.offset, 0);
      // Pinch back below 1.08× → snaps to 1×.
      await pinch(tester, const Offset(200, 300), 300, 80);
      await tester.pumpAndSettle();
      expect(key.currentState!.view.scale, 1);
      expect(key.currentState!.view.offset, Offset.zero);
      // At 1× one finger scrolls the list as before.
      await tester.dragFrom(const Offset(200, 500), const Offset(0, -200));
      await tester.pumpAndSettle();
      expect(scroll.offset, greaterThan(0));
    });

    testWidgets('double tap zooms in at the tap point and out again', (tester) async {
      final key = GlobalKey<ZoomStageState>();
      await tester.binding.setSurfaceSize(const Size(400, 800));
      await tester.pumpWidget(MaterialApp(home: SizedBox(height: 600, child: ZoomStage(key: key, child: Container(color: Colors.brown)))));
      await tester.tapAt(const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();
      final v = key.currentState!.view;

      expect(v.scale, closeTo(2.5, 0.01));
      // The tapped point stays under the finger.
      final q = (const Offset(100, 100) - v.offset) / v.scale;
      expect(q.dx, closeTo(100, 1));
      await tester.tapAt(const Offset(100, 100));
      await tester.pump(const Duration(milliseconds: 100));
      await tester.tapAt(const Offset(100, 100));
      await tester.pumpAndSettle();
      expect(key.currentState!.view.scale, 1);
    });

    testWidgets('whole app: two fingers zoom any screen, layout keeps its size, taps land on the zoomed content', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await frames(tester, 12);
      final cardSize = tester.getSize(find.text('Granths').first);
      await pinch(tester, const Offset(206, 450), 100, 250);
      await tester.pump(const Duration(milliseconds: 300));
      expect(AppZoom.current.value.scale, greaterThan(2));
      // Layout did not re-flow (same logical size), only the paint is scaled.
      expect(tester.getSize(find.text('Granths').first), cardSize);
      // Tap where the "Granths" card now is on screen → it opens.
      final at = tester.getCenter(find.text('Granths').first);
      expect(at.dx, inInclusiveRange(0, 412));
      await tester.tapAt(at);
      await frames(tester, 8);
      expect(AppNav.I.route.panel, Panel.granths);
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------- 4. PDF arrow + dropdown ----------------
  group('PDF list', () {
    testWidgets('collapsed by default; the arrow opens / closes it; × removes rows; running asks first', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await frames(tester, 8);
      final q = PdfQueue.I;
      final gate = Completer<String>();
      final running = q.start(pjob('run'), (j, r) => gate.future);
      q.jobs.addAll([pjob('d1', phase: PdfPhase.done, percent: 100), pjob('d2', phase: PdfPhase.done, percent: 100)]);
      q.dismiss('-');
      await frames(tester, 4);
      expect(find.byKey(const ValueKey('pdf-arrow')), findsOneWidget);
      expect(find.byType(PdfDropdown), findsNothing, reason: 'no list covering the screen');

      await tester.tap(find.byKey(const ValueKey('pdf-arrow')));
      await frames(tester, 4);
      expect(find.byType(PdfDropdown), findsOneWidget);
      // Two separate PDFs of the same granth stay two entries.
      expect(q.jobs.length, 3);
      expect(find.text('श्रीमद्भगवत गीता code 17'), findsAtLeastNWidgets(2));

      await tester.tap(find.byKey(const ValueKey('pdf-x-d1')));
      await frames(tester, 3);
      expect(q.jobs.map((e) => e.id), isNot(contains('d1')));

      await tester.tap(find.byKey(ValueKey('pdf-x-${running.id}')));
      await frames(tester, 4);
      expect(find.textContaining('रोककर सूची से हटाएँ'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await frames(tester, 4);
      expect(running.cancelled, isTrue);
      expect(q.jobs.map((e) => e.id), ['d2']);

      await tester.tap(find.byKey(const ValueKey('pdf-arrow')));
      await frames(tester, 4);
      expect(find.byType(PdfDropdown), findsNothing);
      gate.complete('x');
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpWidget(const SizedBox());
    });
  });

  // ---------------- background PDF notification ----------------
  test('status-bar notification follows the PDFs and stops when they end', () async {
    final calls = <String, Map<String, Object?>>{};
    final order = <String>[];
    PdfNotify.I.call = (m, a) async {
      calls[m] = a;
      order.add(m);
    };
    PdfNotify.I.attach();
    final q = PdfQueue.I;
    final g1 = Completer<String>(), g2 = Completer<String>();
    q.start(pjob('a'), (j, r) => g1.future);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    q.start(pjob('b'), (j, r) => g2.future);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    expect(order.first, 'askNotifications');
    expect(calls['pdfProgress']!['text'], startsWith('2 PDF बन रही हैं — '));
    q.cancel(q.jobs.first.id);
    q.cancel(q.jobs.last.id);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order.last, 'pdfStop');
    // Asked only once.
    order.clear();
    q.start(pjob('c'), (j, r) => Completer<String>().future);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(order, isNot(contains('askNotifications')));
    q.cancel(q.jobs.first.id);
  });

  // ---------------- 5. Granths header ----------------
  for (final scale in [1.0, 1.3]) {
    testWidgets('Granths title stays on one line at 360 dp (text scale $scale)', (tester) async {
      tester.view.physicalSize = const Size(360 * 3, 780 * 3);
      tester.view.devicePixelRatio = 3;
      tester.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(tester.view.reset);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      AppNav.I.go('#/granths');
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await frames(tester, 12);
      final title = find.text('Granths').first;
      final h = tester.getSize(title).height;
      expect(h, lessThan(28 * scale * 1.1 * 1.5), reason: 'one line');
      final btn = tester.getRect(find.byKey(const ValueKey('header-trailing')));
      final t = tester.getRect(title);
      expect(btn.top, greaterThanOrEqualTo(t.bottom - 1), reason: 'button sits below the title line');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _InitCounter extends StatefulWidget {
  const _InitCounter({required this.onInit});
  final VoidCallback onInit;
  @override
  State<_InitCounter> createState() => _InitCounterState();
}

class _InitCounterState extends State<_InitCounter> {
  @override
  void initState() {
    super.initState();
    widget.onInit();
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}
