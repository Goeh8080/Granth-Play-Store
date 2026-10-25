import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/ai/chat_store.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/models/structure.dart';
import 'package:granthprabandhan/screens/shelves_screen.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/shelves.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/religion_paths.dart';
import 'package:granthprabandhan/widgets/religion_symbol.dart';
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:granthprabandhan/services/image_size.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round10_folders_test.dart' show realCatalog;
import 'round5_test.dart' show fingerTap, openApp, realPause;

/// Round 11 — 2×2 folder cards, religion symbols, and Back after a resume / recreate.
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

  Future<void> surface(WidgetTester t, double w, [double h = 2600]) async {
    await t.binding.setSurfaceSize(Size(w, h));
    addTearDown(() => t.binding.setSurfaceSize(null));
  }

  Future<void> open(WidgetTester t, String hash) async {
    AppNav.I.go(hash);
    await settle(t);
  }

  Finder text(String s) => find.text(s);

  // ------------------------------------------------------------------------------------
  group('folder grid: 2×2 by default, the 1×1 / 2×2 / 3×3 switch still works', () {
    testWidgets('religions screen: two folders per row by default', (t) async {
      await openApp(t);
      await surface(t, 412);
      await open(t, '#/granths');
      expect(folderCols(), 2);
      final a = t.getTopLeft(text('हिन्दू')), b = t.getTopLeft(text('इस्लाम')), c = t.getTopLeft(text('सिख'));
      expect((a.dy - b.dy).abs(), lessThan(2), reason: 'हिन्दू and इस्लाम share a row');
      expect(b.dx, greaterThan(a.dx + 120), reason: 'side by side');
      expect(c.dy, greaterThan(a.dy + 100), reason: 'सिख starts the next row');
      expect(find.byType(FolderRow), findsNWidgets(9));
      expect(t.takeException(), isNull);
    });

    testWidgets('religion and group-with-sub-groups screens are 2×2 too, and have the switch', (t) async {
      await openApp(t);
      await surface(t, 412);
      for (final h in ['#/granths?r=hindu', '#/granths?r=hindu&g=ved']) {
        await open(t, h);
        expect(find.byKey(const ValueKey('grid-2')), findsOneWidget, reason: '$h has the switch');
        final rows = find.byType(FolderRow);
        expect(rows, findsWidgets);
        final first = t.getTopLeft(rows.at(0)), second = t.getTopLeft(rows.at(1));
        expect((first.dy - second.dy).abs(), lessThan(2), reason: '$h: two per row');
        expect(t.takeException(), isNull);
      }
    });

    for (final n in [1, 2, 3]) {
      testWidgets('switch to $n×$n: the folders re-lay out and the choice is saved', (t) async {
        await openApp(t);
        await surface(t, 412);
        await open(t, '#/granths');
        await fingerTap(t, find.byKey(ValueKey('grid-$n')), wobble: Offset.zero);
        await settle(t, 8);
        expect(Store.I.getInt(Store.kGranthCols), n);
        final rows = find.byType(FolderRow);
        final y0 = t.getTopLeft(rows.at(0)).dy;
        var perRow = 0;
        for (var i = 0; i < 8; i++) {
          if ((t.getTopLeft(rows.at(i)).dy - y0).abs() < 2) perRow++;
        }
        expect(perRow, n, reason: '$n per row');
        // The same switch is on the next folder level and shows the same choice.
        await open(t, '#/granths?r=hindu');
        final rows2 = find.byType(FolderRow);
        final yy = t.getTopLeft(rows2.at(0)).dy;
        var per2 = 0;
        for (var i = 0; i < rows2.evaluate().length && i < 4; i++) {
          if ((t.getTopLeft(rows2.at(i)).dy - yy).abs() < 2) per2++;
        }
        expect(per2, n);
        expect(t.takeException(), isNull);
      });
    }

    testWidgets('the settings layout switch (1 or 2) also lays out the folders', (t) async {
      await openApp(t);
      await surface(t, 412);
      UiPrefs.I.setLayout(1);
      await open(t, '#/granths');
      final rows = find.byType(FolderRow);
      expect((t.getTopLeft(rows.at(0)).dy - t.getTopLeft(rows.at(1)).dy).abs(), greaterThan(40));
    });
  });

  // ------------------------------------------------------------------------------------
  group('folder cards never overflow', () {
    const longNames = [
      'श्रीमद्भगवद्गीता यथारूप — संक्षिप्त संस्करण सहित सम्पूर्ण टीका और भाष्य',
      'श्रीमद्भगवद्गीतायथारूपसंक्षिप्तसंस्करणसहितसम्पूर्णटीकाऔरभाष्य',
      'गुरु ग्रंथ साहिब',
      '6 शास्त्र',
    ];
    Structure longStructure() => Structure.parse(jsonEncode({
          'version': 1,
          'religions': [
            {
              'id': 'hindu',
              'title': longNames[0],
              'tone': 'saffron',
              'icon': 'om',
              'groups': [
                for (var i = 0; i < longNames.length; i++)
                  {'id': 'g$i', 'title': longNames[i], 'icon': 'book-green', 'granthIds': [for (var k = 0; k < 6; k++) '${10 + i * 6 + k}']},
              ],
            },
            {'id': 'islam', 'title': longNames[1], 'tone': 'maroon', 'icon': 'crescent', 'groups': []},
          ],
          'other': {'id': 'other', 'title': longNames[0], 'icon': 'misc'},
        }));

    for (final w in [320.0, 360.0, 412.0]) {
      for (final scale in [1.0, 1.3]) {
        for (final n in [1, 2, 3]) {
          testWidgets('long Hindi names at ${w.toInt()} dp, text ×$scale, $n×$n', (t) async {
            Shelves.use(longStructure());
            UiPrefs.I.setCols(Store.kGranthCols, n);
            await openApp(t);
            await surface(t, w);
            t.platformDispatcher.textScaleFactorTestValue = scale;
            addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
            for (final h in ['#/granths', '#/granths?r=hindu', '#/granths?r=other']) {
              await open(t, h);
              expect(t.takeException(), isNull, reason: '$h $n×$n at $w ×$scale');
              // every card sits inside the screen width
              for (final e in find.byType(FolderRow).evaluate()) {
                final r = t.getRect(find.byWidget(e.widget));
                expect(r.left, greaterThanOrEqualTo(0));
                expect(r.right, lessThanOrEqualTo(w + 0.5));
              }
            }
          });
        }
      }
    }

    for (final (id, title) in cardLooks) {
      testWidgets('"$title" (light): 2×2 religions + religion + sub-group folders at 360 dp, text ×1.3', (t) async {
        UiPrefs.I.look = id;
        await openApp(t);
        await surface(t, 360);
        t.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        for (final h in ['#/granths', '#/granths?r=hindu', '#/granths?r=hindu&g=ved', '#/granths?r=sikh']) {
          await open(t, h);
          expect(find.byType(GCard), findsWidgets, reason: '$id $h');
          expect(t.takeException(), isNull, reason: '$id $h');
        }
        await open(t, '#/granths');
        expect(find.byType(ReligionSymbol), findsNWidgets(8), reason: '$id: 7 religions + अन्य');
      });
    }
  });

  // ------------------------------------------------------------------------------------
  group('religion symbols', () {
    test('one symbol per religion, in the shipped structure', () {
      final s = shippedStructure();
      expect([for (final r in s.religions) r.icon], ['om', 'crescent', 'khanda', 'cross', 'dharma', 'jain', 'kabir']);
      expect(s.other.icon, 'misc');
      expect(religionSymbolNames.toSet(), {...[for (final r in s.religions) r.icon], 'misc'});
    });

    test('the baked ॐ and ☬ outlines parse and are tiny', () {
      for (final d in [kPathOm, kPathKhanda]) {
        final b = ReligionSymbolPainter.parse(d).getBounds();
        expect(b.width, inInclusiveRange(700, 1000.5));
        expect(b.height, inInclusiveRange(700, 1000.5));
        expect(d.length, lessThan(2000));
      }
      expect(File('lib/widgets/religion_paths.dart').lengthSync(), lessThan(4 * 1024));
    });

    testWidgets('every symbol draws, in every tone and size, without error', (t) async {
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Wrap(children: [
          for (final n in religionSymbolNames) for (final tone in Tone.values) for (final s in [24.0, 44.0, 84.0, 160.0]) ReligionSymbol(n, tone: tone, size: s),
          const ReligionSymbol('unknown-name'),
        ]),
      ));
      expect(find.byType(ReligionSymbol), findsNWidgets(religionSymbolNames.length * 3 * 4 + 1));
      expect(t.takeException(), isNull);
      expect(const ReligionSymbolPainter('om', Colors.white).shouldRepaint(const ReligionSymbolPainter('cross', Colors.white)), isTrue);
      expect(const ReligionSymbolPainter('om', Colors.white).shouldRepaint(const ReligionSymbolPainter('om', Colors.black)), isTrue);
      expect(const ReligionSymbolPainter('om', Colors.white).shouldRepaint(const ReligionSymbolPainter('om', Colors.white)), isFalse);
    });

    testWidgets('the symbols really paint ink (not blank) and are different from each other', (t) async {
      Future<List<int>> pixels(String name) async {
        final key = GlobalKey();
        await t.pumpWidget(Directionality(textDirection: TextDirection.ltr, child: RepaintBoundary(key: key, child: ReligionSymbol(name, tone: Tone.maroon, size: 64))));
        return (await t.runAsync(() async {
          final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage();
          final d = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
          return d!.buffer.asUint8List().toList();
        }))!;
      }

      final seen = <int>{};
      for (final n in religionSymbolNames) {
        final px = await pixels(n);
        var light = 0; // paper-coloured ink on a dark maroon tile
        for (var i = 0; i < px.length; i += 4) {
          if (px[i] > 235 && px[i + 1] > 235 && px[i + 2] > 215) light++;
        }
        expect(light, greaterThan(150), reason: '$n has visible ink');
        seen.add(Object.hashAll(px));
      }
      expect(seen.length, religionSymbolNames.length, reason: 'all symbols look different');
    });

    testWidgets('religions screen shows a symbol on each religion folder, in the right order', (t) async {
      await openApp(t);
      await surface(t, 412);
      await open(t, '#/granths');
      final names = [for (final e in find.byType(ReligionSymbol).evaluate()) (e.widget as ReligionSymbol).name];
      expect(names, ['om', 'crescent', 'khanda', 'cross', 'dharma', 'jain', 'kabir', 'misc']);
      // and the religion screen's header carries the same symbol
      await open(t, '#/granths?r=sikh');
      expect([for (final e in find.byType(ReligionSymbol).evaluate()) (e.widget as ReligionSymbol).name], contains('khanda'));
    });
  });

  // ------------------------------------------------------------------------------------
  group('Back never leaves the app from an inner screen', () {
    final platformCalls = <String>[];
    setUp(() {
      platformCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'SystemNavigator.pop' || call.method == 'SystemNavigator.setFrameworkHandlesBack') platformCalls.add('${call.method}:${call.arguments}');
        return null;
      });
    });
    tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    Future<void> back(WidgetTester t) async {
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t, 6);
    }

    Future<void> toRecentsAndBack(WidgetTester t) async {
      final b = t.binding;
      for (final s in [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused, AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]) {
        b.handleAppLifecycleStateChanged(s);
        await t.pump(const Duration(milliseconds: 50));
      }
      await settle(t, 3);
    }

    Future<void> dive(WidgetTester t) async {
      await open(t, '#/granths');
      await open(t, '#/granths?r=hindu');
      await open(t, '#/granths?r=hindu&g=ved');
      await open(t, '#/granths?r=hindu&g=ved&s=rigved');
    }

    testWidgets('each resume tells Android that Flutter handles Back (the cause of the bug)', (t) async {
      await openApp(t);
      platformCalls.clear();
      await toRecentsAndBack(t);
      expect(platformCalls, contains('SystemNavigator.setFrameworkHandlesBack:true'));
    });

    testWidgets('after recents: Back goes up one level at a time, down to the dashboard, never out', (t) async {
      await openApp(t);
      await surface(t, 412);
      await dive(t);
      await toRecentsAndBack(t);
      for (final expected in ['#/granths?r=hindu&g=ved', '#/granths?r=hindu', '#/granths', '#/dashboard']) {
        await back(t);
        expect(AppNav.I.hash, expected);
        expect(platformCalls.where((c) => c.startsWith('SystemNavigator.pop')), isEmpty, reason: 'never exits');
        expect(t.takeException(), isNull);
      }
    });

    testWidgets('several trips to recents and back in a row do not change how Back walks', (t) async {
      await openApp(t);
      await surface(t, 412);
      await dive(t);
      for (var i = 0; i < 3; i++) {
        await toRecentsAndBack(t);
      }
      await back(t);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=ved');
      await toRecentsAndBack(t);
      await back(t);
      expect(AppNav.I.hash, '#/granths?r=hindu');
    });

    testWidgets('a granth screen and a deep link: Back after a resume goes up, not out', (t) async {
      await openApp(t);
      await surface(t, 412);
      await open(t, '#/granths?r=hindu&g=puran');
      AppNav.I.openLink('#/pramans?granth=10');
      await settle(t);
      await toRecentsAndBack(t);
      await back(t);
      expect(AppNav.I.hash, '#/granths?r=hindu&g=puran');
      expect(platformCalls.where((c) => c.startsWith('SystemNavigator.pop')), isEmpty);
    });

    testWidgets('after the app is killed and restarted on a folder screen, Back still walks up (stack restored)', (t) async {
      await openApp(t);
      await surface(t, 412);
      await dive(t);
      final before = AppNav.I.debugStack;
      expect(before, ['#/dashboard', '#/granths', '#/granths?r=hindu', '#/granths?r=hindu&g=ved']);
      // process death: a brand-new AppNav reads what was saved
      await t.pumpWidget(const SizedBox());
      AppNav.I = AppNav();
      AppNav.I.restore();
      expect(AppNav.I.hash, '#/granths?r=hindu&g=ved&s=rigved');
      expect(AppNav.I.debugStack, before);
      await t.pumpWidget(const GranthApp(splash: false, links: false));
      await settle(t);
      for (final expected in ['#/granths?r=hindu&g=ved', '#/granths?r=hindu', '#/granths', '#/dashboard']) {
        await back(t);
        expect(AppNav.I.hash, expected);
      }
      expect(platformCalls.where((c) => c.startsWith('SystemNavigator.pop')), isEmpty);
    });

    testWidgets('restart with no saved stack (older install): the stack is rebuilt from the screen itself', (t) async {
      await Store.I.setString(Store.kHash, '#/granths?r=hindu&g=ved&s=rigved');
      AppNav.I = AppNav();
      AppNav.I.restore();
      expect(AppNav.I.debugStack, ['#/dashboard', '#/granths', '#/granths?r=hindu', '#/granths?r=hindu&g=ved']);
      await Store.I.setString(Store.kHash, '#/granths?r=other');
      await Store.I.setString('granth-nav', '["junk", 5, "#/granths?r=hindu"]');
      AppNav.I = AppNav();
      AppNav.I.restore();
      expect(AppNav.I.debugStack, ['#/dashboard', '#/granths'], reason: 'a stack that does not start at the dashboard is not trusted');
    });

    test('ancestorsOf', () {
      expect(AppNav.ancestorsOf('#/dashboard'), isEmpty);
      expect(AppNav.ancestorsOf('#/topics'), ['#/dashboard']);
      expect(AppNav.ancestorsOf('#/granths?all=1'), ['#/dashboard']);
      expect(AppNav.ancestorsOf('#/granths?r=hindu'), ['#/dashboard', '#/granths']);
      expect(AppNav.ancestorsOf('#/granths?r=hindu&g=puran'), ['#/dashboard', '#/granths', '#/granths?r=hindu']);
      expect(AppNav.ancestorsOf('#/pramans?topic=3'), ['#/dashboard', '#/topics']);
      expect(AppNav.ancestorsOf('#/pramans?granth=10'), ['#/dashboard', '#/granths']);
    });

    testWidgets('on the dashboard, after a resume, Back still shows the same exit card — and only "हाँ" leaves', (t) async {
      await openApp(t);
      await surface(t, 412);
      await dive(t);
      await toRecentsAndBack(t);
      for (var i = 0; i < 4; i++) {
        await back(t);
      }
      expect(AppNav.I.hash, '#/dashboard');
      expect(text('क्या आप बाहर निकलना चाहते हैं?'), findsNothing);
      await back(t); // the existing exit rule: a second Back soon after the first
      await back(t);
      expect(text('क्या आप बाहर निकलना चाहते हैं?'), findsOneWidget);
      expect(platformCalls.where((c) => c.startsWith('SystemNavigator.pop')), isEmpty, reason: 'nothing closed yet');
      await fingerTap(t, text('नहीं, यहीं रहें'), wobble: Offset.zero);
      await settle(t, 6);
      expect(text('क्या आप बाहर निकलना चाहते हैं?'), findsNothing);
      expect(AppNav.I.hash, '#/dashboard', reason: 'still in the app');
    });
  });

  // ------------------------------------------------------------------------------------
  group('menu: तत्त्व AI से पूछे (the chat)', () {
    setUp(() {
      Retriever.I.reset();
      ChatController.I = ChatController(client: AiClient(endpoint: 'http://x'), store: ChatStore.fresh());
    });

    Future<void> openMenu(WidgetTester t) async {
      await fingerTap(t, find.byWidgetPredicate((w) => w is GIcon && w.name == 'menu'), wobble: Offset.zero);
      await realPause(t);
      await t.pumpAndSettle();
    }

    testWidgets('sits directly above Photo Highlighter, same row style, the other entries untouched', (t) async {
      await openApp(t);
      await openMenu(t);
      const order = ['landmark', 'clipboard-list', 'library', 'image', 'sparkles', 'highlighter'];
      final ys = [for (final k in order) t.getTopLeft(find.byKey(ValueKey('nav-$k'))).dy];
      for (var i = 1; i < ys.length; i++) {
        expect(ys[i], greaterThan(ys[i - 1]), reason: '${order[i]} below ${order[i - 1]}');
      }
      expect(find.text('तत्त्व AI से पूछे'), findsOneWidget);
      expect(find.text('PHOTO HIGHLIGHTER'), findsOneWidget);
      final h = t.getSize(find.byKey(const ValueKey('nav-image'))).height;
      expect(t.getSize(find.byKey(const ValueKey('nav-sparkles'))).height, h);
      expect(t.takeException(), isNull);
    });

    testWidgets('opens the chat (header, text box); Back goes to the dashboard', (t) async {
      await openApp(t);
      await openMenu(t);
      await fingerTap(t, find.byKey(const ValueKey('nav-sparkles')), wobble: Offset.zero);
      await settle(t, 10);
      expect(AppNav.I.hash, '#/ai');
      expect(AppNav.I.menuOpen, isFalse);
      expect(find.text('तत्त्व AI से पूछे'), findsWidgets);
      expect(find.byType(TextField), findsOneWidget, reason: 'the real chat box');
      expect(t.takeException(), isNull);
      await realPause(t);
      await t.binding.handlePopRoute();
      await settle(t, 8);
      expect(AppNav.I.hash, '#/dashboard');
      expect(find.byType(TextField), findsNothing);
    });

    for (final (id, title) in cardLooks) {
      testWidgets('"$title": the chat screen draws at 320 dp, text ×1.3', (t) async {
        UiPrefs.I.look = id;
        await openApp(t);
        await surface(t, 320, 915);
        t.platformDispatcher.textScaleFactorTestValue = 1.3;
        addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
        await open(t, '#/ai');
        expect(find.byType(TextField), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }

    test('route: #/ai is a top screen whose parent is the dashboard', () {
      expect(GRoute.parse('#/ai').panel, Panel.ai);
      expect(AppNav.ancestorsOf('#/ai'), ['#/dashboard']);
    });
  });
}
