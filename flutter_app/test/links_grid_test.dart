import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/screens/topics_screen.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/common.dart';

import 'helpers.dart';

Future<void> settle(WidgetTester tester, [int frames = 14]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Number of cards in the first visible grid row.
int firstRowCards(WidgetTester tester) {
  final rows = find.byType(IntrinsicHeight);
  if (rows.evaluate().isEmpty) return 1;
  return find.descendant(of: rows.first, matching: find.byType(Expanded)).evaluate().length;
}

void main() {
  setUp(setUpApp);

  group('shared links', () {
    testWidgets('cold start: the link that opened the app is shown after the splash (no white screen)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      final links = StreamController<Uri>();
      await tester.pumpWidget(GranthApp(ready: Future.value(), linkStream: links.stream, initialLink: Future.value(Uri.parse('https://granth.grok.me/open?topic=2'))));
      await settle(tester, 40); // splash
      expect(tester.takeException(), isNull);
      expect(find.byType(HomeShell), findsOneWidget);
      expect(AppNav.I.route.panel, Panel.pramans);
      expect(AppNav.I.route.topicId, '2');
      expect(find.text('अध्याय 15 श्लोक 4'), findsOneWidget);
      await links.close();
    });

    testWidgets('warm start: a link opened while the app runs switches the screen', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      final links = StreamController<Uri>();
      await tester.pumpWidget(GranthApp(splash: false, linkStream: links.stream, initialLink: Future.value(null)));
      await settle(tester);
      expect(AppNav.I.route.panel, Panel.dashboard);
      links.add(Uri.parse('granth://open?granth=11'));
      await settle(tester);
      expect(AppNav.I.route.granthId, '11');
      expect(find.text('पेज 10'), findsOneWidget);
      // A second link to a different topic while the prāmaṇ screen is open re-filters it.
      links.add(Uri.parse('granth://open?topic=1'));
      await settle(tester);
      expect(AppNav.I.route.topicId, '1');
      expect(find.text('अध्याय 2 श्लोक 22'), findsOneWidget);
      expect(find.text('अध्याय 15 श्लोक 4'), findsNothing);
      expect(tester.takeException(), isNull);
      await links.close();
    });

    testWidgets('a link to something that no longer exists shows a message and a way home', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      final links = StreamController<Uri>();
      await tester.pumpWidget(GranthApp(splash: false, linkStream: links.stream, initialLink: Future.value(Uri.parse('granth://open?id=99999'))));
      await settle(tester);
      expect(find.text('लिंक वाला विषय/ग्रंथ/प्रमाण नहीं मिला'), findsOneWidget);
      await tester.tap(find.text('Dashboard पर जाएँ'));
      await settle(tester);
      expect(AppNav.I.route.panel, Panel.dashboard);
      await links.close();
    });

    testWidgets('foreign or broken links are ignored, the app keeps working', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      final links = StreamController<Uri>();
      await tester.pumpWidget(GranthApp(splash: false, linkStream: links.stream, initialLink: Future<Uri?>.delayed(const Duration(milliseconds: 10), () => throw StateError('no intent'))));
      await settle(tester);
      links.add(Uri.parse('https://evil.example/open?topic=1'));
      links.add(Uri.parse('granth://open'));
      await settle(tester);
      expect(AppNav.I.route.panel, Panel.dashboard);
      expect(tester.takeException(), isNull);
      await links.close();
    });

    test('link → screen mapping', () {
      expect(hashFromLink(Uri.parse('granth://open?topic=5')), '#/pramans?topic=5');
      expect(hashFromLink(Uri.parse('https://granth.grok.me/open?granth=7')), '#/pramans?granth=7');
      expect(hashFromLink(Uri.parse('https://granth.grok.me/open?id=100')), '#/pramans?id=100');
      expect(hashFromLink(Uri.parse('https://granth.grok.me/elsewhere?id=1')), isNull);
    });
  });

  group('grid and settings', () {
    testWidgets('1×1 / 2×2 switch changes the visible columns live and persists', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      await settle(tester);
      AppNav.I.go('#/topics');
      await settle(tester);
      expect(find.byType(TopicsPanel), findsOneWidget);
      expect(firstRowCards(tester), 2);
      await tester.tap(find.text('1×1'));
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(Store.I.getInt(Store.kTopicCols), 1);
      expect(find.byType(IntrinsicHeight), findsNothing); // one card per row
      await tester.tap(find.text('2×2'));
      await settle(tester);
      expect(firstRowCards(tester), 2);
    });

    testWidgets('granths 3×3 shows three per row', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      AppNav.I.go('#/granths');
      await settle(tester);
      await tester.tap(find.text('3×3'));
      await settle(tester);
      expect(Store.I.getInt(Store.kGranthCols), 3);
      expect(firstRowCards(tester), 3);
    });

    testWidgets('सेटिंग: layout applies to every screen at once; card style applies live', (tester) async {
      await tester.binding.setSurfaceSize(const Size(412, 915));
      await tester.pumpWidget(const GranthApp(splash: false, links: false));
      AppNav.I.go('#/topics');
      await settle(tester);
      await tester.tap(find.byWidgetPredicate((w) => w is GIcon && w.name == 'settings'));
      await settle(tester);
      expect(find.text('सेटिंग'), findsWidgets);
      await tester.tap(find.text('1×1').last);
      await settle(tester, 4);
      for (final k in [Store.kUiCols, Store.kTopicCols, Store.kGranthCols, Store.kPramanCols, Store.kGalleryCols]) {
        expect(Store.I.getInt(k), 1, reason: k);
      }
      // Hidden card styles after 5 taps on the version.
      await tester.ensureVisible(find.textContaining('Version'));
      await settle(tester, 3);
      for (var i = 0; i < 5; i++) {
        await tester.tap(find.textContaining('Version'));
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester, 4);
      await tester.ensureVisible(find.text('Glassmorphism'));
      await settle(tester, 3);
      await tester.tap(find.text('Glassmorphism'));
      await settle(tester, 4);
      expect(Store.I.getString(Store.kLook), 'glass');
      await tester.binding.handlePopRoute();
      await settle(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(IntrinsicHeight), findsNothing); // topics now 1 per row, without leaving the screen
    });
  });
}
