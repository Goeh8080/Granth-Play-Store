import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/splash_screen.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/common.dart';

import 'helpers.dart';

Future<void> settle(WidgetTester tester, [int frames = 12]) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> pumpApp(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(412, 915));
  await tester.pumpWidget(const GranthApp(splash: false, links: false));
  await settle(tester);
}

void main() {
  setUp(setUpApp);

  testWidgets('dashboard shows the original mast, stats and cards', (tester) async {
    await pumpApp(tester);
    expect(find.text('ग्रंथ प्रबंधन'), findsOneWidget);
    expect(find.text('विषय / प्रश्नोत्तरी'), findsOneWidget);
    expect(find.text('पवित्र ग्रन्थ'), findsOneWidget);
    expect(find.text('नए प्रमाण'), findsOneWidget);
    expect(find.text('Dashboard'), findsOneWidget);
    expect(find.text('सत साहेब जी'), findsOneWidget);
    expect(find.text('3'), findsWidgets); // praman count (count-up finished)
  });

  testWidgets('topics list sorts by position, grid switch persists', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('विषय / प्रश्नोत्तरी'));
    await settle(tester);
    expect(find.text('Topics'), findsOneWidget);
    expect(find.text('1. गीता ज्ञान'), findsOneWidget);
    expect(find.text('2. मृत्यु के बाद क्या'), findsOneWidget);
    await tester.tap(find.text('1×1'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(Store.I.getInt(Store.kTopicCols), 1);
  });

  testWidgets('opening a granth filters pramans and back returns', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.text('पवित्र ग्रन्थ'));
    await settle(tester);
    expect(find.text('Granths'), findsOneWidget);
    await tester.tap(find.text('कबीर सागर').first);
    await settle(tester);
    expect(AppNav.I.route.granthId, '11');
    expect(find.text('पेज 10'), findsOneWidget);
    expect(find.text('सभी प्रमाण'), findsOneWidget);
    await tester.binding.handlePopRoute();
    await settle(tester);
    expect(AppNav.I.route.panel, Panel.granths);
  });

  testWidgets('menu opens and PDF style sheet shows both styles', (tester) async {
    await pumpApp(tester);
    await tester.tap(find.byWidgetPredicate((w) => w is GIcon && w.name == 'menu'));
    await settle(tester, 7);
    expect(find.text('TOPICS'), findsOneWidget);
    await tester.tap(find.text('TOPICS'));
    await settle(tester);
    await tester.tap(find.text('PDF').first);
    await settle(tester, 7);
    expect(find.text('PDF शैली'), findsOneWidget);
    expect(find.text('PDF विषय के साथ'), findsOneWidget);
    expect(find.text('केवल चित्र'), findsOneWidget);
    await tester.tap(find.text('पीछे').last);
    await settle(tester, 7);
    expect(find.text('PDF शैली'), findsNothing);
  });

  testWidgets('animated splash hands over to the app', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AnimatedSplash(duration: Duration(milliseconds: 300), child: Text('home'))));
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('ग्रंथ प्रबंधन'), findsOneWidget);
    await tester.pump(const Duration(seconds: 2));
    await settle(tester);
    expect(find.text('ग्रंथ प्रबंधन'), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });
}
