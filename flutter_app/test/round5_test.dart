import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as w;
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/granth_image.dart';
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show firstRowCards, settle;
import 'offline_test.dart' show FakeNet, pictureCatalog;
import 'round3_test.dart' show FakeApi;

/// A real finger: lands, wobbles [wobble] (12 px — more than Android's 8 dp touch slop, so
/// the scroll view under it wins the gesture arena), lifts.
Future<void> fingerTap(WidgetTester t, Finder f, {Offset wobble = const Offset(0, 12)}) async {
  // Like a person: scroll it into view first (the settings sheet is taller than a phone).
  if (t.getRect(f).bottom > t.view.physicalSize.height / t.view.devicePixelRatio - 8 || t.getRect(f).top < 0) {
    await t.ensureVisible(f);
    for (var i = 0; i < 3; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }
  final g = await t.startGesture(t.getCenter(f));
  await t.pump(const Duration(milliseconds: 16));
  await g.moveBy(wobble / 2);
  await t.pump(const Duration(milliseconds: 16));
  await g.moveBy(wobble / 2);
  await t.pump(const Duration(milliseconds: 16));
  await g.up();
  await t.pump(const Duration(milliseconds: 16));
}

/// Navigation keeps ashok's wall-clock debounces (back 260 ms, same link 400 ms).
Future<void> realPause(WidgetTester t) => t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 450)));

/// Phone screen with the device's 8 dp touch slop (Flutter tests default to 18).
Future<void> phone(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(412, 915));
  t.view.gestureSettings = ui.GestureSettings(physicalTouchSlop: 8 * t.view.devicePixelRatio);
  addTearDown(t.view.resetGestureSettings);
}

Future<void> openApp(WidgetTester t) async {
  await phone(t);
  await t.pumpWidget(const GranthApp(splash: false, links: false));
  await settle(t);
  expect(find.byType(AppZoom), findsOneWidget, reason: 'taps go through the whole-app zoom layer');
}

Future<void> openSettings(WidgetTester t) async {
  await fingerTap(t, find.byWidgetPredicate((x) => x is GIcon && x.name == 'settings'), wobble: Offset.zero);
  await settle(t, 6);
  expect(find.byKey(const ValueKey('set-layout-1')), findsOneWidget);
}

void main() {
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
  });

  group('grid switch (1×1 / 2×2 / 3×3 under ग्रंथ)', () {
    testWidgets('a wobbly finger changes the columns at once and the choice is saved', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      expect(firstRowCards(t), 2);
      for (final (n, cards) in [(3, 3), (1, 1), (2, 2), (3, 3)]) {
        await fingerTap(t, find.byKey(ValueKey('grid-$n')));
        // Immediate: the very next frame already has the new grid.
        await t.pump();
        expect(UiPrefs.I.cols(Store.kGranthCols, allowed: const [1, 2, 3], fallback: 2), n);
        expect(Store.I.getInt(Store.kGranthCols), n, reason: 'saved');
        await settle(t, 4);
        expect(firstRowCards(t), cards, reason: '$n×$n');
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('a plain tap and a tap while the app is pinch-zoomed both work', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await fingerTap(t, find.byKey(const ValueKey('grid-1')), wobble: Offset.zero);
      await settle(t, 4);
      expect(find.byType(IntrinsicHeight), findsNothing);
      AppZoom.current.value = const ZoomView(2, Offset(-100, -100));
      await settle(t, 3);
      await fingerTap(t, find.byKey(const ValueKey('grid-3')), wobble: const Offset(5, 5));
      await settle(t, 4);
      expect(Store.I.getInt(Store.kGranthCols), 3);
      AppZoom.current.value = ZoomView.identity;
    });

    testWidgets('a pinch that starts on a grid button zooms and does not switch the grid', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      final c = t.getCenter(find.byKey(const ValueKey('grid-3')));
      final a = await t.startGesture(c, pointer: 7);
      final b = await t.startGesture(c + const Offset(0, 60), pointer: 8);
      await t.pump(const Duration(milliseconds: 16));
      await b.moveBy(const Offset(0, 4));
      await t.pump(const Duration(milliseconds: 16));
      await a.up();
      await b.up();
      await settle(t, 4);
      expect(Store.I.getInt(Store.kGranthCols), isNull);
      expect(firstRowCards(t), 2);
      AppZoom.current.value = ZoomView.identity;
    });

    testWidgets('a real scroll that starts on the switch does not count as a tap', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await fingerTap(t, find.byKey(const ValueKey('grid-3')), wobble: const Offset(0, -120));
      await settle(t, 4);
      expect(Store.I.getInt(Store.kGranthCols), isNull);
    });

    testWidgets('settings survive when the phone hands over saved settings late', (t) async {
      // SharedPreferences not there yet at start (slow phone).
      final prefs = await SharedPreferences.getInstance(); // (empty mock from setUp)
      await t.runAsync(() async => Store.I.initForTest(null, await Directory.systemTemp.createTemp('granth_late')));
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await fingerTap(t, find.byKey(const ValueKey('grid-3')));
      await settle(t, 4);
      expect(firstRowCards(t), 3, reason: 'works before the saved settings arrive');
      expect(Store.I.persistent, isFalse);
      Store.I.debugAdoptPrefs(prefs);
      expect(prefs.getString(Store.kGranthCols), '3', reason: 'written once storage is there');
      expect(Store.I.persistent, isTrue);
    });
  });

  group('सेटिंग sheet — every control', () {
    testWidgets('PDF style, layout, hidden card styles and पीछे all work through the full app', (t) async {
      await openApp(t);
      await openSettings(t);
      for (final o in pdfStyleOptions.reversed) {
        await fingerTap(t, find.byKey(ValueKey('set-pdf-${pdfStyleId(o.style)}')));
        await t.pump();
        expect(UiPrefs.I.pdfStyle, o.style);
        expect(Store.I.getString(Store.kPdfStyle), isNotNull);
      }
      for (final n in [1, 2, 1]) {
        await fingerTap(t, find.byKey(ValueKey('set-layout-$n')));
        await t.pump();
        for (final k in [Store.kUiCols, Store.kTopicCols, Store.kGranthCols, Store.kPramanCols, Store.kGalleryCols]) {
          expect(Store.I.getInt(k), n, reason: '$k after $n×$n');
        }
      }
      expect(find.byKey(const ValueKey('set-look-glass')), findsNothing);
      for (var i = 0; i < 5; i++) {
        await fingerTap(t, find.byKey(const ValueKey('set-version')), wobble: const Offset(3, 9));
        await t.pump(const Duration(milliseconds: 60));
      }
      await settle(t, 4);
      for (final (id, _) in cardLooks) {
        final f = find.byKey(ValueKey('set-look-$id'));
        await t.ensureVisible(f);
        await settle(t, 2);
        await fingerTap(t, f);
        await t.pump();
        expect(UiPrefs.I.look, id);
        expect(Store.I.getString(Store.kLook), id);
      }
      await fingerTap(t, find.text('पीछे'));
      await settle(t, 6);
      expect(find.byKey(const ValueKey('set-layout-1')), findsNothing, reason: 'पीछे closes the sheet');
      // Layout 1×1 applied to the screen underneath without leaving it.
      AppNav.I.go('#/granths');
      await settle(t);
      expect(find.byType(IntrinsicHeight), findsNothing);
      expect(t.takeException(), isNull);
    });
  });

  group('smoothness', () {
    testWidgets('no floating pill; an idle app draws no frames', (t) async {
      await openApp(t);
      await settle(t, 40);
      expect(find.byKey(const ValueKey('sync-pill')), findsNothing);
      expect(find.byType(LinearProgressIndicator), findsNothing);
      await t.pump(const Duration(seconds: 2));
      expect(t.binding.hasScheduledFrame, isFalse, reason: 'nothing animates forever');
    });

    testWidgets('a download (50 pages a second) rebuilds only the counters, ~3 times a second', (t) async {
      final s = CatalogStore.I..debugSetCatalog(pictureCatalog(extra: 60));
      FakeNet(s);
      await openApp(t);
      SyncStrip.open.value = true;
      await settle(t, 10);
      var storeTicks = 0, shown = 0, rebuilds = 0;
      s.addListener(() => storeTicks++);
      s.progress.addListener(() => shown++);
      w.debugOnRebuildDirtyWidget = (e, _) => rebuilds++;
      addTearDown(() => w.debugOnRebuildDirtyWidget = null);
      for (var i = 0; i < 50; i++) {
        s.pageSaved('uploads/p$i.jpg', true);
        await t.pump(const Duration(milliseconds: 20));
      }
      await t.pump(const Duration(milliseconds: 400));
      w.debugOnRebuildDirtyWidget = null;
      expect(s.images.done, 50, reason: 'the number itself is always exact');
      expect(s.progress.value.done, 50);
      expect(storeTicks, 0, reason: 'a saved page no longer rebuilds the whole app');
      expect(shown, inInclusiveRange(3, 5));
      expect(rebuilds, lessThan(150), reason: 'was ~330 widgets × 8 a second');
      SyncStrip.open.value = false;
      await settle(t, 6);
    });

    testWidgets('the 2-minute sync with unchanged data rebuilds nothing', (t) async {
      final api = FakeApi(sampleCatalog());
      final s = CatalogStore(api: api, connectivity: const Stream.empty())..debugSetCatalog(sampleCatalog());
      CatalogStore.I = s;
      FakeNet(s);
      await openApp(t);
      await t.runAsync(() => s.sync(silent: true)); // first sync stores the compare key
      await settle(t, 20);
      final before = s.granths;
      var rebuilds = 0;
      w.debugOnRebuildDirtyWidget = (e, _) => rebuilds++;
      addTearDown(() => w.debugOnRebuildDirtyWidget = null);
      await t.runAsync(() => s.sync(silent: true));
      await settle(t, 5);
      w.debugOnRebuildDirtyWidget = null;
      expect(api.calls, 2);
      // ignore: avoid_print
      print('rebuilds on an unchanged sync: $rebuilds');
      expect(identical(s.granths, before), isTrue, reason: 'same data → nothing replaced');
      expect(rebuilds, lessThan(40));
    });

    testWidgets('round-3 scrolling and page transitions are back', (t) async {
      await openApp(t);
      final list = t.widget<CustomScrollView>(find.byType(CustomScrollView).first);
      expect(list.physics, isA<ClampingScrollPhysics>());
      final theme = Theme.of(t.element(find.byType(HomeShell)));
      expect(theme.pageTransitionsTheme.builders[TargetPlatform.android], isA<FadeForwardsPageTransitionsBuilder>());
    });
  });

  group('regression pass (full app, zoom layer in place)', () {
    testWidgets('home cards open every list; back returns home', (t) async {
      await openApp(t);
      for (final (card, panel) in [('विषय / प्रश्नोत्तरी', Panel.topics), ('पवित्र ग्रन्थ', Panel.granths), ('नए प्रमाण', Panel.pramans)]) {
        await t.tap(find.text(card));
        await settle(t);
        expect(AppNav.I.route.panel, panel, reason: card);
        await realPause(t);
        await t.binding.handlePopRoute();
        await settle(t);
        expect(AppNav.I.route.panel, Panel.dashboard);
      }
      expect(t.takeException(), isNull);
    });

    testWidgets('granth view: a granth opens its pramans in every grid size', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      for (final n in [1, 2, 3]) {
        await fingerTap(t, find.byKey(ValueKey('grid-$n')));
        await settle(t, 4);
        await realPause(t);
        await t.ensureVisible(find.text('कबीर सागर').first);
        await settle(t, 3);
        await t.tap(find.text('कबीर सागर').first);
        await settle(t);
        expect(AppNav.I.route.granthId, '11', reason: '$n×$n');
        expect(find.text('पेज 10'), findsOneWidget);
        await realPause(t);
        await t.binding.handlePopRoute();
        await settle(t);
        expect(AppNav.I.route.panel, Panel.granths);
      }
    });

    testWidgets('search filters granths and pramans', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths');
      await settle(t);
      await t.enterText(find.byType(TextField).first, 'kabir');
      await settle(t, 5);
      expect(find.text('कबीर सागर'), findsWidgets);
      expect(find.text('श्रीमद्भगवद्गीता'), findsNothing);
      AppNav.I.go('#/pramans');
      await settle(t);
      await t.enterText(find.byType(TextField).first, 'श्लोक 22');
      await settle(t, 5);
      expect(find.text('अध्याय 2 श्लोक 22'), findsOneWidget);
      expect(find.text('अध्याय 15 श्लोक 4'), findsNothing);
    });

    testWidgets('picture view opens from a praman, pinch-zooms and closes', (t) async {
      final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
      FakeNet(s);
      await openApp(t);
      AppNav.I.go('#/pramans');
      await settle(t);
      final img = find.byWidgetPredicate((x) => x is GranthImage && x.heroTag == 'praman-100');
      expect(img, findsOneWidget);
      await t.tap(img);
      await settle(t, 8);
      final stage = find.byType(ZoomStage);
      expect(stage, findsWidgets);
      final st = t.state<ZoomStageState>(stage.first);
      final c = t.getCenter(stage.first);
      final a = await t.startGesture(c - const Offset(40, 0), pointer: 11);
      final b = await t.startGesture(c + const Offset(40, 0), pointer: 12);
      for (var i = 1; i <= 10; i++) {
        await a.moveTo(c - Offset(40.0 + 12 * i, 0));
        await b.moveTo(c + Offset(40.0 + 12 * i, 0));
        await t.pump(const Duration(milliseconds: 16));
      }
      await a.up();
      await b.up();
      await settle(t, 4);
      expect(st.view.scale, greaterThan(1.5));
      await t.binding.handlePopRoute();
      await settle(t, 8);
      expect(find.byType(ZoomStage), findsNothing);
      expect(t.takeException(), isNull);
      AppZoom.current.value = ZoomView.identity;
    });

    testWidgets('sync strip opens its card; no pill anywhere', (t) async {
      await openApp(t);
      expect(find.byKey(const ValueKey('sync-card')), findsNothing);
      await t.tap(find.byKey(const ValueKey('sync-card-toggle')));
      await settle(t, 6);
      expect(find.byKey(const ValueKey('sync-card')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-button')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-pill')), findsNothing);
      await t.tap(find.byKey(const ValueKey('sync-card-toggle')));
      await settle(t, 6);
      expect(find.byKey(const ValueKey('sync-card')), findsNothing);
    });
  });
}
