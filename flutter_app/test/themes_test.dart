import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'dart:async';

import 'package:granthprabandhan/services/pdf_notify.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/theme/colors.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/overlays.dart';
import 'package:granthprabandhan/widgets/pdf_sheets.dart' show PdfDropdown;
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round3_test.dart' show pjob;
import 'round5_test.dart' show fingerTap, openApp, openSettings;

/// Every box decoration on screen.
List<BoxDecoration> decos(WidgetTester t) => [
      for (final e in find.byWidgetPredicate((w) => w is DecoratedBox || w is Container || w is AnimatedContainer).evaluate())
        if (switch (e.widget) {
          DecoratedBox(:final decoration) => decoration,
          Container(:final decoration) => decoration,
          _ => null,
        }
            case final BoxDecoration d)
          d,
      // AnimatedContainer paints through a DecoratedBox, counted above.
    ];

/// Signature of each card style (ashok's CSS `html.ui-<id> .card`).
bool isLook(BoxDecoration d, String look) {
  final sh = d.boxShadow ?? const <BoxShadow>[];
  final b = d.border;
  final g = d.gradient;
  return switch (look) {
    'glass' => d.color != null && d.color!.r == 1 && d.color!.g == 1 && d.color!.b == 1 && d.color!.a < 0.8 && sh.any((s) => s.blurRadius == 28),
    'neu' => sh.length == 2 && sh.first.offset == const Offset(8, 8),
    'clay' => sh.any((s) => s.color == const Color(0xFFD6B69B)) || (b is Border && b.bottom.color == const Color(0xFFD6B69B)),
    'material' => sh.isNotEmpty && sh.first.color == const Color(0x2E000000),
    'flat' => d.color == GColors.cream && ((b is Border && b.top.color == GColors.maroon) || sh.any((s) => s.color == GColors.maroon)),
    'bento' => g is LinearGradient && g.colors.length == 2 && g.colors.first == GColors.paper && g.colors.last == GColors.creamDark,
    'combo' => g is LinearGradient && g.colors.first == const Color(0xFFFFFDF8),
    _ => false,
  };
}

int count(WidgetTester t, String look) => decos(t).where((d) => isLook(d, look)).length;

Future<void> pickLook(WidgetTester t, String id) async {
  await openSettings(t);
  for (var i = 0; i < 5; i++) {
    await fingerTap(t, find.byKey(const ValueKey('set-version')), wobble: Offset.zero);
    await t.pump(const Duration(milliseconds: 60));
  }
  await settle(t, 4);
  final f = find.byKey(ValueKey('set-look-$id'));
  await t.ensureVisible(f);
  await settle(t, 2);
  await fingerTap(t, f);
  await settle(t, 3);
  expect(UiPrefs.I.look, id);
}

void main() {
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
  });

  for (final (id, title) in cardLooks.where((l) => l.$1 != 'classic')) {
    testWidgets('card style "$title" reaches every screen and survives a restart', (t) async {
      await openApp(t);
      expect(count(t, id), 0, reason: 'starts as सादा');
      await pickLook(t, id);
      // The settings sheet itself follows at once.
      expect(count(t, id), greaterThanOrEqualTo(1), reason: 'settings sheet');
      await fingerTap(t, find.text('पीछे'));
      await settle(t, 6);

      // Dashboard: 3 stat cards + note card.
      expect(count(t, id), greaterThanOrEqualTo(4), reason: 'dashboard');
      // Sync strip + its card.
      await t.tap(find.byKey(const ValueKey('sync-card-toggle')));
      await settle(t, 6);
      final card = find.byKey(const ValueKey('sync-card'));
      expect(isLook(t.widget<Container>(card).decoration! as BoxDecoration, id), isTrue, reason: 'sync card');
      await t.tap(find.byKey(const ValueKey('sync-card-toggle')));
      await settle(t, 6);

      // Granths grid: cards + search box.
      AppNav.I.go('#/granths');
      await settle(t);
      expect(count(t, id), greaterThanOrEqualTo(3), reason: 'granths: 2 cards + search');
      // Granth view (its pramans + banner).
      await t.tap(find.text('कबीर सागर').first);
      await settle(t);
      expect(AppNav.I.route.granthId, '11');
      expect(count(t, id), greaterThanOrEqualTo(2), reason: 'granth view: banner + praman card (+ search)');
      // Topics.
      AppNav.I.go('#/topics');
      await settle(t);
      expect(count(t, id), greaterThanOrEqualTo(3), reason: 'topics: 2 cards + search');
      expect(t.takeException(), isNull);

      // Saved, and still applied after the app is started again.
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(Store.kLook), id);
      await t.pumpWidget(const SizedBox());
      AppNav.I = AppNav();
      await t.pumpWidget(const GranthApp(splash: false, links: false));
      await settle(t);
      expect(count(t, id), greaterThanOrEqualTo(4), reason: 'after restart');
    });
  }

  testWidgets('back to सादा removes the style everywhere', (t) async {
    await openApp(t);
    await pickLook(t, 'bento');
    await fingerTap(t, find.byKey(const ValueKey('set-look-classic')));
    await settle(t, 3);
    await fingerTap(t, find.text('पीछे'));
    await settle(t, 6);
    for (final (id, _) in cardLooks) {
      expect(count(t, id), 0, reason: id);
    }
  });

  for (final id in ['bento', 'flat', 'clay']) {
    testWidgets('card style "$id" also reaches the PDF list and dialogs', (t) async {
      PdfQueue.I.debugReset();
      PdfNotify.I.debugReset();
      PdfNotify.I.call = (m, a) async {};
      PdfNotify.I.query = (m, a) async => null;
      await openApp(t);
      UiPrefs.I.look = id;
      final gate = Completer<String>();
      PdfQueue.I.start(pjob('run'), (j, r) => gate.future);
      PdfQueue.I.dismiss('-');
      await settle(t, 4);
      await t.tap(find.byKey(const ValueKey('pdf-arrow')));
      await settle(t, 4);
      final dd = t.widget<Container>(find.byKey(const ValueKey('pdf-dropdown')));
      expect(isLook(dd.decoration! as BoxDecoration, id), isTrue, reason: 'PDF list');
      await t.tap(find.byKey(const ValueKey('pdf-arrow')));
      await settle(t, 4);
      // A dialog (window.confirm style).
      unawaited(confirmPop(t.element(find.byType(HomeShell)), 'जाँच?'));
      await settle(t, 4);
      final sheet = find.ancestor(of: find.text('जाँच?'), matching: find.byType(Container));
      expect(sheet.evaluate().map((e) => (e.widget as Container).decoration).whereType<BoxDecoration>().any((d) => isLook(d, id)), isTrue, reason: 'dialog');
      await t.tap(find.text('OK'));
      await settle(t, 4);
      expect(find.byType(PdfDropdown), findsNothing);
      gate.complete('x');
      await t.pump(const Duration(seconds: 4));
      await t.pumpWidget(const SizedBox());
    });
  }
}
