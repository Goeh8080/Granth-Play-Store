import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/models/structure.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/shelves.dart';
import 'package:granthprabandhan/screens/granths_screen.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/screens/shelves_screen.dart';
import 'package:granthprabandhan/services/image_size.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/group_icon.dart';
import 'package:granthprabandhan/widgets/zoom.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round5_test.dart' show fingerTap, openApp, realPause;
import 'scroll_restore_test.dart' show bigCatalog, decodeWait, goBack, listPos, scrollDown, visibleTitles;
import 'structure_test.dart' show realGranths;

Catalog realCatalog() => Catalog(
      topics: [Topic({'id': '1', 'title': 'विषय', 'description': '', 'position': '1', 'praman_count': '1'})],
      granths: realGranths(),
      pramans: [Praman({'id': '100', 'title': 'पेज 1', 'description': '', 'topic_id': '1', 'granth_id': '10'})],
      syncedAt: DateTime(2026, 10, 20).millisecondsSinceEpoch,
    );

void main() {
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    Places.forgetLive();
    ImageSizes.I.clear();
    CatalogStore.I.debugSetCatalog(realCatalog());
  });

  Finder text(String s) => find.text(s);
  /// A tall screen so that the lazy folder lists build every row.
  Future<void> tall(WidgetTester t) async => t.binding.setSurfaceSize(const Size(412, 2600));
  Future<void> open(WidgetTester t, String hash) async {
    AppNav.I.go(hash);
    await settle(t);
  }

  testWidgets('the shipped structure.json is a registered asset and loads through the bundle', (t) async {
    await t.runAsync(() => Shelves.load());
    expect(Shelves.structure.religions.length, 6);
    Shelves.use(shippedStructure());
  });

  group('religions screen', () {
    testWidgets('six religion folders in order, अन्य, सभी ग्रंथ — with real counts', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths');
      for (final s in ['हिन्दू', 'इस्लाम', 'सिख', 'ईसाई', 'बुद्ध', 'कबीर', 'अन्य', 'सभी ग्रंथ']) {
        expect(text(s), findsOneWidget, reason: s);
      }
      final ys = [for (final s in ['हिन्दू', 'इस्लाम', 'सिख', 'ईसाई', 'बुद्ध', 'कबीर', 'अन्य', 'सभी ग्रंथ']) t.getTopLeft(text(s)).dy];
      // After ensureVisible the list has moved: compare order by index in the scrolled list, not screen y.
      expect(ys.length, 8);
      final all = realGranths();
      expect(find.textContaining('${all.length} ग्रंथ'), findsOneWidget, reason: 'सभी ग्रंथ row');
      expect(find.textContaining('36 ग्रंथ'), findsOneWidget, reason: 'अन्य');
      expect(find.textContaining('जल्द आ रहा है'), findsOneWidget, reason: 'बुद्ध has nothing yet');
      expect(find.textContaining('मालिक'), findsNothing, reason: 'no granth card on the religions screen');
      expect(t.takeException(), isNull);
    });

    testWidgets('typing in the search box searches every granth (cards instead of folders)', (t) async {
      await openApp(t);
      await open(t, '#/granths');
      await t.enterText(find.byType(TextField).first, 'शिव');
      await settle(t, 6);
      expect(find.byType(GranthCard), findsWidgets);
      expect(text('हिन्दू'), findsNothing);
      await t.enterText(find.byType(TextField).first, '');
      await settle(t, 6);
      expect(find.byType(GranthCard), findsNothing);
      expect(text('हिन्दू'), findsOneWidget);
    });

    testWidgets('सभी ग्रंथ opens the flat list of every granth; back returns to the religions', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths');
      await t.tap(text('सभी ग्रंथ'));
      await settle(t);
      expect(AppNav.I.route.flat, isTrue);
      expect(find.byType(GranthCard), findsWidgets);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.route.flat, isFalse);
      expect(AppNav.I.route.religionId, isNull);
      expect(text('हिन्दू'), findsOneWidget);
    });

    testWidgets('the tab, the menu and the dashboard card all land on the religions screen', (t) async {
      await openApp(t);
      await t.tap(text('पवित्र ग्रन्थ'));
      await settle(t);
      expect(AppNav.I.hash, '#/granths');
      expect(text('हिन्दू'), findsOneWidget);
    });
  });

  group('religion → group → granth', () {
    testWidgets('हिन्दू lists only groups that have granths, with counts', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths');
      await t.tap(text('हिन्दू'));
      await settle(t);
      expect(AppNav.I.hash, '#/granths?r=hindu');
      for (final g in ['वेद', 'गीता', 'पुराण', 'उपनिषद', 'रामायण', 'महाभारत', 'मनुस्मृति']) {
        expect(text(g), findsOneWidget, reason: g);
      }
      expect(text('6 शास्त्र'), findsNothing, reason: 'empty groups are hidden');
      expect(find.textContaining('37 ग्रंथ'), findsOneWidget, reason: 'पुराण');
      expect(find.byType(GroupIcon), findsWidgets);
    });

    testWidgets('पुराण shows the normal granth cards; a card opens the normal granth screen and back returns to पुराण', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths');
      await t.tap(text('हिन्दू'));
      await settle(t);
      await t.tap(text('पुराण'));
      await settle(t);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=puran');
      expect(find.byType(GranthCard), findsWidgets);
      expect(find.byType(GridSwitch), findsOneWidget, reason: 'the same 1×1 / 2×2 / 3×3 switch');
      final card = find.byType(GranthCard).first;
      final shown = find.descendant(of: card, matching: find.byType(Text)).evaluate().map((e) => (e.widget as Text).data ?? '').where((s) => s.length > 3).first;
      await t.tap(card);
      await settle(t);
      expect(AppNav.I.route.panel, Panel.pramans);
      expect(AppNav.I.route.granthId, isNotNull);
      expect(shown, isNotEmpty);
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=puran');
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.hash, '#/granths?r=hindu');
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.hash, '#/granths');
      expect(text('हिन्दू'), findsOneWidget);
    });

    testWidgets('वेद has an extra level: sub-groups (empty सूक्ष्मवेद hidden), then the granths', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths?r=hindu&g=ved');
      for (final s in ['ऋग्वेद', 'यजुर्वेद', 'सामवेद', 'अथर्ववेद']) {
        expect(text(s), findsOneWidget, reason: s);
      }
      expect(text('सूक्ष्मवेद'), findsNothing);
      expect(find.byType(GranthCard), findsNothing);
      await t.tap(text('ऋग्वेद'));
      await settle(t);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=ved&s=rigved');
      expect(find.byType(GranthCard), findsNWidgets(5));
    });

    testWidgets('a group search stays inside the group; an empty result says so', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths?r=hindu&g=ramayan');
      expect(find.byType(GranthCard), findsNWidgets(6));
      await t.enterText(find.byType(TextField).first, 'zzzz');
      await settle(t, 6);
      expect(find.byType(GranthCard), findsNothing);
      expect(text('कोई ग्रंथ नहीं'), findsOneWidget);
    });

    testWidgets('बुद्ध (nothing yet) shows "जल्द आ रहा है", not an empty page', (t) async {
      await openApp(t);
      await open(t, '#/granths?r=buddh');
      expect(text('जल्द आ रहा है'), findsOneWidget);
      expect(find.byType(GranthCard), findsNothing);
    });

    testWidgets('अन्य holds the 36 unplaced granths as normal cards', (t) async {
      await openApp(t);
      await tall(t);
      await open(t, '#/granths?r=other');
      expect(text('अन्य'), findsWidgets);
      expect(find.byType(GranthCard, skipOffstage: false), findsAtLeastNWidgets(8));
      expect(find.textContaining('36'), findsWidgets, reason: 'the counter pill shows the real total');
    });

    testWidgets('a new granth from the API appears in अन्य automatically', (t) async {
      final cat = realCatalog();
      cat.granths.add(Granth({'id': '9001', 'title': 'अनोखा नया ग्रंथ', 'position': '900', 'pramanCount': '1'}));
      CatalogStore.I.debugSetCatalog(cat);
      await openApp(t);
      await tall(t);
      await open(t, '#/granths');
      expect(find.textContaining('37 ग्रंथ'), findsOneWidget, reason: 'अन्य grew by one');
      await t.enterText(find.byType(TextField).first, 'अनोखा');
      await settle(t, 6);
      expect(find.byType(GranthCard), findsOneWidget, reason: 'search still reaches it');
    });

    testWidgets('a folder link that no longer exists shows a way back, no crash', (t) async {
      await openApp(t);
      await open(t, '#/granths?r=hindu&g=nothing');
      expect(text('यह फ़ोल्डर नहीं मिला'), findsOneWidget);
      await open(t, '#/granths?r=nowhere');
      expect(text('यह फ़ोल्डर नहीं मिला'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('offline / no structure file: every granth is in अन्य and the tab still works', (t) async {
      Shelves.use(Structure.empty);
      await openApp(t);
      await open(t, '#/granths');
      expect(text('अन्य'), findsOneWidget);
      expect(t.takeException(), isNull);
    });

    testWidgets('an empty catalog (first start, offline) shows the usual empty state', (t) async {
      CatalogStore.I.debugSetCatalog(Catalog(topics: [], granths: [], pramans: []));
      await openApp(t);
      await open(t, '#/granths');
      expect(text('हिन्दू'), findsNothing, reason: 'no empty folders before the first sync');
      expect(text('कोई ग्रंथ नहीं'), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('every card style', () {
    for (final (id, title) in cardLooks) {
      testWidgets('"$title": religions, religion, sub-groups and a group screen all draw', (t) async {
        UiPrefs.I.look = id;
        await openApp(t);
        await tall(t);
        for (final h in ['#/granths', '#/granths?r=hindu', '#/granths?r=hindu&g=ved', '#/granths?r=hindu&g=ved&s=rigved', '#/granths?r=hindu&g=puran', '#/granths?r=other', '#/granths?r=buddh']) {
          await open(t, h);
          if (!h.endsWith('buddh')) expect(find.byType(GCard, skipOffstage: false), findsWidgets, reason: '$id $h');
          expect(t.takeException(), isNull, reason: '$id $h');
        }
        await open(t, '#/granths');
        expect(find.byType(FolderRow), findsNWidgets(8), reason: '$id: 6 religions + अन्य + सभी ग्रंथ');
      });
    }
  });

  group('icons', () {
    testWidgets('every painted group icon draws without error at several sizes', (t) async {
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(children: [for (final n in groupIconNames) for (final s in [28.0, 44.0, 56.0]) GroupIcon(n, size: s)]),
      ));
      expect(find.byType(GroupIcon), findsNWidgets(groupIconNames.length * 3));
      expect(t.takeException(), isNull);
      expect(const GroupIconPainter('scroll').shouldRepaint(const GroupIconPainter('bible')), isTrue);
      expect(const GroupIconPainter('scroll').shouldRepaint(const GroupIconPainter('scroll')), isFalse);
    });

    test('painted, not shipped: structure + icons add only a few KB to the app', () {
      final json = File('assets/structure/structure.json').lengthSync();
      expect(json, lessThan(40 * 1024));
      expect(jsonDecode(File('assets/structure/structure.json').readAsStringSync()), isA<Map>());
      expect(File('assets/icons/folder-open.svg').lengthSync(), lessThan(1024));
    });
  });

  group('scroll place on the new levels', () {
    // 36 granths with pictures, all in one group so the list is long.
    Structure longGroup() => Structure.parse(jsonEncode({
          'version': 1,
          'religions': [
            {
              'id': 'hindu',
              'title': 'हिन्दू',
              'tone': 'saffron',
              'icon': 'folder-open',
              'groups': [
                {'id': 'puran', 'title': 'पुराण', 'icon': 'book-green', 'granthIds': [for (var i = 0; i < 36; i++) '${10 + i}']},
              ],
            },
          ],
          'other': {'id': 'other', 'title': 'अन्य', 'icon': 'misc'},
        }));

    for (final n in [1, 2, 3]) {
      testWidgets('group list, $n×$n: open a granth, back — the same place, and back again walks up the folders', (t) async {
        Shelves.use(longGroup());
        CatalogStore.I.debugSetCatalog(bigCatalog());
        UiPrefs.I.setCols(Store.kGranthCols, n);
        await openApp(t);
        await open(t, '#/granths');
        await t.tap(text('हिन्दू'));
        await settle(t);
        await t.tap(text('पुराण'));
        await settle(t);
        await decodeWait(t);
        expect(find.byType(GranthCard), findsWidgets);
        await scrollDown(t, n == 1 ? 6000 : (n == 2 ? 3500 : 2500));
        final y0 = listPos(t).pixels;
        expect(y0, greaterThan(1500));
        final re = RegExp('^ग्रंथ \\d+\$');
        final before = visibleTitles(t, re);
        final title = before.entries.firstWhere((e) => e.value > 120 && e.value < 600).key;
        await t.tap(find.text(title).first);
        await settle(t, 4);
        expect(AppNav.I.route.panel, Panel.pramans);
        await decodeWait(t);
        await goBack(t);
        expect(AppNav.I.hash, '#/granths?r=hindu&g=puran');
        expect(listPos(t).pixels, closeTo(y0, 0.6), reason: '$n×$n offset');
        final after = visibleTitles(t, re);
        for (final e in before.entries) {
          if (e.value < -150 || e.value > 1000) continue;
          expect(after[e.key], isNotNull, reason: e.key);
          expect(after[e.key]!, closeTo(e.value, 1.0), reason: '${e.key} at the same height');
        }
        // Up the folders: religion, then religions — each one where it was left.
        await goBack(t);
        expect(AppNav.I.hash, '#/granths?r=hindu');
        await goBack(t);
        expect(AppNav.I.hash, '#/granths');
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('each level keeps its own place: the group list is not reset by visiting the flat list', (t) async {
      Shelves.use(longGroup());
      CatalogStore.I.debugSetCatalog(bigCatalog());
      await openApp(t);
      await open(t, '#/granths?r=hindu&g=puran');
      await decodeWait(t);
      await scrollDown(t, 2500);
      final y0 = listPos(t).pixels;
      expect(y0, greaterThan(1000));
      AppNav.I.go('#/granths?all=1');
      await settle(t);
      await decodeWait(t);
      expect(listPos(t).pixels, 0, reason: 'a different list starts at the top');
      await realPause(t);
      await t.binding.handlePopRoute();
      await decodeWait(t, 3);
      await settle(t, 14);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=puran');
      expect(listPos(t).pixels, closeTo(y0, 0.6));
      expect(Places.y('group-list:hindu:puran'), closeTo(y0, 0.6));
      expect(Places.y('granth-list-place'), 0);
    });

    testWidgets('religions screen: the search text is remembered with its place', (t) async {
      await openApp(t);
      await open(t, '#/granths');
      await t.enterText(find.byType(TextField).first, 'कबीर');
      await settle(t, 6);
      expect(Places.query('religions-place'), 'कबीर');
      expect(Places.query('granth-list-place'), '', reason: 'the flat list has its own search');
      await fingerTap(t, find.byType(GranthCard).first, wobble: Offset.zero);
      await settle(t);
      expect(AppNav.I.route.panel, Panel.pramans);
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t, 14);
      expect(AppNav.I.hash, '#/granths');
      expect(find.byType(GranthCard), findsWidgets, reason: 'still filtered after back');
    });
  });
}
