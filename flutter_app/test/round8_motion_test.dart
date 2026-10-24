import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/screens/granths_screen.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/pop.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round5_test.dart' show fingerTap, openApp, openSettings;
import 'scroll_restore_test.dart' show bigCatalog, decodeWait, listPos, scrollDown;

/// Round 8 — item 1 (scale-pop), item 3 (Granth inner stagger), item 8 (एनिमेशन setting).
List<double> popScales(WidgetTester t) => [
      for (final e in find.byKey(kCardPopKey).evaluate()) (e.widget as ScaleTransition).scale.value,
    ];

Widget host(PopLedger ledger, String id, int index, {bool disableAnimations = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: Center(child: CardPop(ledger: ledger, id: id, index: index, child: const SizedBox(key: ValueKey('card'), width: 100, height: 60))),
      ),
    );

void main() {
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    Places.forgetLive();
    UiPrefs.I.refresh();
  });

  group('CardPop (scale-pop)', () {
    testWidgets('ScaleTransition + easeOutBack over 420 ms: starts small, overshoots, lands on exactly 1', (t) async {
      final l = PopLedger();
      await t.pumpWidget(host(l, 'a', 0));
      final st = find.byKey(kCardPopKey);
      expect(st, findsOneWidget);
      double v() => (t.widget<ScaleTransition>(st).scale).value;
      expect(v(), closeTo(CardPop.from, 0.01));
      var peak = 0.0;
      for (var i = 0; i < 30; i++) {
        await t.pump(const Duration(milliseconds: 16));
        peak = peak < v() ? v() : peak;
      }
      expect(peak, greaterThan(1.02), reason: 'easeOutBack overshoots');
      expect(v(), 1.0);
      expect(find.byType(RepaintBoundary), findsWidgets);
    });

    testWidgets('stagger by index for the first cards only', (t) async {
      final l = PopLedger();
      await t.pumpWidget(Column(textDirection: TextDirection.ltr, children: [
        for (final i in [0, 6, 12, 40])
          Directionality(textDirection: TextDirection.ltr, child: CardPop(ledger: l, id: '$i', index: i, child: const SizedBox(width: 10, height: 10))),
      ]));
      await t.pump(const Duration(milliseconds: 200));
      final s = popScales(t);
      expect(s.length, 4);
      expect(s[0], greaterThan(0.9), reason: 'index 0 is well into its pop');
      expect(s[1], lessThan(s[0]), reason: 'index 6 waits 270 ms');
      expect(s[1], closeTo(CardPop.from, 0.01));
      // Cards far down wait no longer than the 12th: the delay is capped, not growing.
      await t.pump(const Duration(milliseconds: 400));
      expect(popScales(t)[3], closeTo(popScales(t)[2], 0.0001));
      await t.pump(const Duration(seconds: 2));
      expect(popScales(t), everyElement(1.0));
    });

    testWidgets('plays once per card per visit: a re-created card (scroll back up) is just there', (t) async {
      final l = PopLedger();
      await t.pumpWidget(host(l, 'a', 0));
      await t.pump(const Duration(seconds: 2));
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(l, 'a', 0));
      expect(find.byKey(kCardPopKey), findsNothing);
      // A new visit (new ledger / cleared) plays again.
      l.clear();
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(l, 'a', 0));
      expect(find.byKey(kCardPopKey), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('a rebuild or a data tick mid-pop does not restart it', (t) async {
      final l = PopLedger();
      await t.pumpWidget(host(l, 'a', 0));
      await t.pump(const Duration(milliseconds: 250));
      final mid = popScales(t).single;
      await t.pumpWidget(host(l, 'a', 0));
      expect(popScales(t).single, closeTo(mid, 0.001));
      await t.pump(const Duration(seconds: 1));
      expect(popScales(t).single, 1.0);
    });

    testWidgets('layout is untouched: same size and place from the first frame to the last (no layout shift)', (t) async {
      final l = PopLedger();
      await t.pumpWidget(host(l, 'a', 0));
      final box = t.renderObject<RenderBox>(find.byKey(const ValueKey('card')));
      final size0 = box.size;
      final at0 = t.getTopLeft(find.byType(CardPop));
      await t.pump(const Duration(milliseconds: 200));
      expect(box.size, size0);
      expect(t.getTopLeft(find.byType(CardPop)), at0);
    });

    testWidgets('"कम" and the phone\'s remove-animations switch it off completely', (t) async {
      UiPrefs.I.animations = false;
      await t.pumpWidget(host(PopLedger(), 'a', 0));
      expect(find.byKey(kCardPopKey), findsNothing);
      UiPrefs.I.animations = true;
      await t.pumpWidget(host(PopLedger(), 'b', 0, disableAnimations: true));
      expect(find.byKey(kCardPopKey), findsNothing);
      await t.pumpWidget(const SizedBox());
      await t.pumpWidget(host(PopLedger(), 'c', 0));
      expect(find.byKey(kCardPopKey), findsOneWidget);
      await t.pump(const Duration(seconds: 2));
    });

    testWidgets('only cards built while the screen opens pop; one that scrolls in later is simply there', (t) async {
      final l = PopLedger();
      Widget two(bool late) => MaterialApp(
            home: Column(children: [
              CardPop(ledger: l, id: 'x', index: 0, child: const SizedBox(height: 10)),
              if (late) CardPop(ledger: l, id: 'y', index: 1, child: const SizedBox(height: 10)),
            ]),
          );
      await t.pumpWidget(two(false));
      await t.pump(const Duration(seconds: 1));
      await t.pumpWidget(two(true));
      expect(popScales(t).length, 1, reason: 'y built a second later: no pop');
    });
  });

  group('lists', () {
    testWidgets('Granths tab: cards pop once; scrolling away and back up never replays; the scroll offset is exact', (t) async {
      CatalogStore.I.debugSetCatalog(bigCatalog());
      await openApp(t);
      AppNav.I.go('#/granths?all=1');
      await t.pump(const Duration(milliseconds: 60));
      await t.pump(const Duration(milliseconds: 60));
      final first = popScales(t);
      expect(first, isNotEmpty);
      expect(first.every((s) => s < 1.0), isTrue, reason: 'visible cards are mid-pop');
      await settle(t, 14);
      expect(popScales(t).every((s) => s == 1.0), isTrue);
      await decodeWait(t);
      await scrollDown(t, 3000);
      final y = listPos(t).pixels;
      expect(y, greaterThan(1500));
      // Scroll back to the very top: the first cards are re-created; nothing pops again.
      await t.drag(find.byType(CustomScrollView).first, const Offset(0, 5000), warnIfMissed: false);
      for (var i = 0; i < 4; i++) {
        await t.drag(find.byType(CustomScrollView).first, const Offset(0, 5000), warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 30));
      }
      expect(listPos(t).pixels, 0);
      await t.pump(const Duration(milliseconds: 30));
      expect(popScales(t).where((s) => s < 1.0), isEmpty, reason: 'no replay on scroll-back-up');
      expect(find.byType(GranthCard), findsWidgets);
      expect(t.takeException(), isNull);
    });

    testWidgets('Granth card: image, then title, then buttons fade in staggered; layout never moves', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths?all=1');
      await t.pump(const Duration(milliseconds: 20));
      final card = find.byType(GranthCard).first;
      List<double> fades() => [
            for (final e in find.descendant(of: card, matching: find.byKey(kRevealKey)).evaluate()) (e.widget as FadeTransition).opacity.value,
          ];
      final size0 = t.getSize(card);
      expect(fades().length, greaterThanOrEqualTo(3));
      await t.pump(const Duration(milliseconds: 330));
      final mid = fades();
      // Order of the Reveals in the tree is title block, image, buttons.
      final byRole = {'title': mid[0], 'image': mid[1], 'buttons': mid[2]};
      expect(byRole['image']!, greaterThan(byRole['title']!), reason: 'image first');
      expect(byRole['title']!, greaterThan(byRole['buttons']!), reason: 'buttons last');
      expect(t.getSize(card), size0, reason: 'no layout shift');
      await t.pump(const Duration(seconds: 2));
      expect(fades().every((v) => v == 1.0), isTrue);
    });

    testWidgets('"कम": cards and inner parts are plain from the first frame', (t) async {
      UiPrefs.I.animations = false;
      await openApp(t);
      AppNav.I.go('#/granths?all=1');
      await t.pump(const Duration(milliseconds: 20));
      expect(popScales(t), isEmpty);
      expect(find.descendant(of: find.byType(GranthCard).first, matching: find.byKey(kRevealKey)), findsNothing);
    });

    testWidgets('the granth-open tilt works together with the entrance animations (even mid-pop)', (t) async {
      await openApp(t);
      AppNav.I.go('#/granths?all=1');
      await t.pump(const Duration(milliseconds: 100));
      await t.tap(find.byType(GranthCard).first, warnIfMissed: false);
      await settle(t, 6);
      expect(AppNav.I.route.panel, Panel.pramans);
      expect(AppNav.I.route.granthId, isNotNull);
      expect(t.takeException(), isNull);
    });

    testWidgets('Topics and Pramans tabs pop too, once', (t) async {
      await openApp(t);
      for (final h in ['#/topics', '#/pramans']) {
        AppNav.I.go(h);
        await t.pump(const Duration(milliseconds: 80));
        expect(popScales(t), isNotEmpty, reason: h);
        await settle(t, 14);
        expect(popScales(t).every((s) => s == 1.0), isTrue, reason: h);
      }
    });
  });

  group('एनिमेशन setting', () {
    testWidgets('चालू by default; कम persists, resets with "सेटिंग रीसेट"; the row sits in Settings', (t) async {
      expect(UiPrefs.I.animations, isTrue);
      await openApp(t);
      await openSettings(t);
      expect(find.text('एनिमेशन'), findsOneWidget);
      await fingerTap(t, find.byKey(const ValueKey('set-anim-low')), wobble: Offset.zero);
      await settle(t, 3);
      expect(UiPrefs.I.animations, isFalse);
      expect(Store.I.getString(Store.kAnimations), '0');
      await fingerTap(t, find.byKey(const ValueKey('set-anim-on')), wobble: Offset.zero);
      await settle(t, 3);
      expect(UiPrefs.I.animations, isTrue);
      expect(Store.I.getString(Store.kAnimations), '1');
      UiPrefs.I.animations = false;
      await t.runAsync(UiPrefs.I.resetAll);
      expect(UiPrefs.I.animations, isTrue, reason: 'reset restores चालू');
      await t.pumpWidget(const SizedBox());
      await t.pump(const Duration(seconds: 1));
    });

    testWidgets('no Test/Normal switch exists', (t) async {
      await openApp(t);
      await openSettings(t);
      expect(find.textContaining('Test'), findsNothing);
      expect(find.textContaining('Normal'), findsNothing);
    });
  });
}
