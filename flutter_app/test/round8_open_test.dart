import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/screens/splash_screen.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';

import 'helpers.dart';

/// Round 8 — item 3: app-open fade + blur-focus right after the splash, bigger splash title.
Widget app({bool disable = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: disable),
        child: const AnimatedSplash(duration: Duration(milliseconds: 300), maxWait: Duration(milliseconds: 400), child: Text('home')),
      ),
    );

int blurs(WidgetTester t) => find.descendant(of: find.byKey(AnimatedSplash.overlayKey), matching: find.byType(ImageFiltered)).evaluate().length;

void main() {
  setUp(() async {
    await setUpApp();
    UiPrefs.I.refresh();
  });

  testWidgets('splash title is bigger than before (was 34)', (t) async {
    await t.pumpWidget(app());
    await t.pump(const Duration(milliseconds: 250));
    final text = t.widget<Text>(find.text('ग्रंथ प्रबंधन'));
    expect(text.style!.fontSize, 44);
    expect(kSplashTitleSize, greaterThan(34));
    await t.pump(const Duration(seconds: 3));
  });

  testWidgets('the app fades in and comes into focus after the splash; no filter once done', (t) async {
    await t.pumpWidget(app());
    // intro 300 ms, then the zoom-out (520 ms) begins; the blur is live during it.
    await t.pump(const Duration(milliseconds: 350));
    await t.pump(const Duration(milliseconds: 150));
    expect(blurs(t), 1, reason: 'blur-focus while the app comes in');
    final f = t.widget<ImageFiltered>(find.descendant(of: find.byKey(AnimatedSplash.overlayKey), matching: find.byType(ImageFiltered)));
    expect(f, isNotNull);
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(seconds: 3));
    expect(find.byKey(AnimatedSplash.overlayKey), findsNothing);
    expect(find.byType(ImageFiltered), findsNothing);
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('एनिमेशन कम / phone no-animation: no blur, app still appears', (t) async {
    UiPrefs.I.animations = false;
    await t.pumpWidget(app());
    await t.pump(const Duration(milliseconds: 500));
    expect(blurs(t), 0);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('home'), findsOneWidget);
    UiPrefs.I.animations = true;
    await t.pumpWidget(app(disable: true));
    await t.pump(const Duration(milliseconds: 500));
    expect(blurs(t), 0);
    await t.pump(const Duration(seconds: 3));
    expect(find.text('home'), findsOneWidget);
  });
}
