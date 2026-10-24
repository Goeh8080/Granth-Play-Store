import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/services/pdf_notify.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/pdf_sheets.dart';
import 'package:granthprabandhan/widgets/pop.dart';

import 'helpers.dart';
import 'round3_test.dart' show frames, pjob;

/// Round 8 — items 2 and 6: ashok's PDF progress card and popup (centred modal, auto-open,
/// scrim / back / बंद / arrow, blur-focus 520 ms), the "PDF तैयार" popup and what it does to the deck.
/// A real (tiny) file for a PDF run to hand back: the queue moves it into place.
String pdfFile(String name) {
  final f = File('${Directory.systemTemp.path}/r8_${name}_${DateTime.now().microsecondsSinceEpoch}.pdf')..writeAsBytesSync([37, 80, 68, 70, 45, 49, 46, 52]);
  return f.path;
}

/// What the queue does when a run ends well (see `_runJob`), without the real file work.
void finish(PdfJob j) {
  j
    ..phase = PdfPhase.done
    ..percent = 100
    ..etaMs = 0
    ..filePath = pdfFile(j.id)
    ..size = 8
    ..finishedAt = DateTime.now().millisecondsSinceEpoch;
  PdfQueue.I.dismiss('-'); // notifies
  PdfQueue.I.finished.value = j;
}

void main() {
  setUp(() async {
    await setUpApp();
    PdfQueue.I.debugReset();
    PdfNotify.I.debugReset();
    PdfNotify.I.call = (m, a) async {};
    PdfNotify.I.query = (m, a) async => null;
    UiPrefs.I.refresh();
  });

  Future<void> boot(WidgetTester t, {bool disableAnimations = false}) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    t.platformDispatcher.accessibilityFeaturesTestValue = FakeAccessibilityFeatures(disableAnimations: disableAnimations);
    addTearDown(t.platformDispatcher.clearAccessibilityFeaturesTestValue);
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await frames(t, 8);
  }

  Finder blur() => find.descendant(of: find.byKey(const ValueKey('pdf-deck-layer')), matching: find.byType(ImageFiltered));

  Future<void> end(WidgetTester t) async {
    await t.pump(const Duration(seconds: 4));
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 4));
  }

  testWidgets('a PDF that starts opens the deck by itself: centred card, 440 max, scrim, ashok order', (t) async {
    await boot(t);
    expect(find.byType(PdfDeck), findsNothing);
    final gate = Completer<String>();
    final j = PdfQueue.I.start(pjob('run'), (_, _) => gate.future);
    await frames(t, 12);
    expect(find.byType(PdfDeck), findsOneWidget);
    final card = t.getRect(find.byType(PdfDeck));
    expect(card.width, lessThanOrEqualTo(440));
    expect(card.width, closeTo(380, 1), reason: 'min(440, screen − 2×16 padding)');
    expect((card.center.dx - 206).abs(), lessThan(1), reason: 'centred sideways');
    expect((card.center.dy - 457.5).abs(), lessThan(40), reason: 'centred vertically');
    // n/N + %, title, bar, two info lines, then [बंद] [पिछला] [अगला], then रोकें.
    final ys = [
      t.getTopLeft(find.byKey(const ValueKey('pdf-pos'))).dy,
      t.getTopLeft(find.byKey(const ValueKey('pdf-title'))).dy,
      t.getTopLeft(find.byKey(const ValueKey('pdf-facts'))).dy,
      t.getTopLeft(find.byKey(const ValueKey('pdf-phase'))).dy,
      t.getTopLeft(find.byKey(const ValueKey('pdf-close'))).dy,
      t.getTopLeft(find.byKey(const ValueKey('pdf-stop'))).dy,
    ];
    expect(ys, orderedEquals([...ys]..sort()));
    expect(find.text('1/1'), findsOneWidget);
    expect(t.getSize(find.byKey(const ValueKey('pdf-stop'))).height, greaterThanOrEqualTo(52), reason: '.pdf-back is 52 px high');
    // The scrim covers the whole screen.
    expect(t.getSize(find.byKey(PdfDeckLayer.shadeKey)), const Size(412, 915));
    expect(j.id, isNotEmpty);
    await end(t);
  });

  testWidgets('comes in out of a blur (520 ms); no filter left once it sits', (t) async {
    await boot(t);
    final gate = Completer<String>();
    PdfQueue.I.start(pjob('run'), (_, _) => gate.future);
    await t.pump();
    await t.pump(const Duration(milliseconds: 60));
    expect(blur(), findsOneWidget, reason: 'blur-focus while arriving');
    final early = t.widget<ImageFiltered>(blur());
    expect(early, isNotNull);
    final op = t.widget<Opacity>(find.descendant(of: find.byKey(const ValueKey('pdf-deck-layer')), matching: find.byType(Opacity)).first);
    expect(op.opacity, lessThan(1));
    await t.pump(const Duration(milliseconds: 200));
    expect(blur(), findsOneWidget);
    await t.pump(const Duration(milliseconds: 700));
    expect(blur(), findsNothing, reason: 'at t == 1 the filter is skipped');
    expect(find.byType(PdfDeck), findsOneWidget);
    await end(t);
  });

  testWidgets('the pager keeps its place while the blur drops its layer', (t) async {
    await boot(t);
    final q = PdfQueue.I;
    q.jobs.addAll([pjob('a', phase: PdfPhase.done, percent: 100)]);
    final gate = Completer<String>();
    q.start(pjob('run'), (_, _) => gate.future);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.byKey(const ValueKey('pdf-next')));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('2/2'), findsOneWidget);
    await t.pump(const Duration(milliseconds: 700)); // blur layer goes away here
    expect(find.text('2/2'), findsOneWidget);
    await end(t);
  });

  testWidgets('एनिमेशन कम and the phone\'s no-animation: the card is simply there', (t) async {
    UiPrefs.I.animations = false;
    await boot(t);
    final gate = Completer<String>();
    PdfQueue.I.start(pjob('run'), (_, _) => gate.future);
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byType(PdfDeck), findsOneWidget);
    expect(blur(), findsNothing);
    await end(t);
    UiPrefs.I.animations = true;
    await boot(t, disableAnimations: true);
    final g2 = Completer<String>();
    PdfQueue.I.start(pjob('run2'), (_, _) => g2.future);
    await t.pump();
    await t.pump(const Duration(milliseconds: 16));
    expect(find.byType(PdfDeck), findsOneWidget);
    expect(blur(), findsNothing);
    await end(t);
  });

  testWidgets('dismiss: scrim, system back, बंद, arrow; taps on the card do not dismiss', (t) async {
    await boot(t);
    final gate = Completer<String>();
    PdfQueue.I.start(pjob('run'), (_, _) => gate.future);
    await frames(t, 12);
    // A tap on the card's own text keeps it open.
    await t.tap(find.byKey(const ValueKey('pdf-title')));
    await frames(t, 3);
    expect(find.byType(PdfDeck), findsOneWidget);
    // Scrim (top-left corner, outside the card).
    await t.tapAt(const Offset(4, 300));
    await frames(t, 3);
    expect(find.byType(PdfDeck), findsNothing);
    // Arrow brings it back; system back closes it.
    await t.tap(find.byKey(const ValueKey('pdf-arrow')));
    await frames(t, 12);
    expect(find.byType(PdfDeck), findsOneWidget);
    await t.binding.handlePopRoute();
    await frames(t, 3);
    expect(find.byType(PdfDeck), findsNothing);
    // बंद.
    await t.tap(find.byKey(const ValueKey('pdf-arrow')));
    await frames(t, 12);
    await t.tap(find.byKey(const ValueKey('pdf-close')));
    await frames(t, 3);
    expect(find.byType(PdfDeck), findsNothing);
    // The same running PDF does not re-open it on its own (updates, ticks).
    await t.pump(const Duration(seconds: 3));
    expect(find.byType(PdfDeck), findsNothing);
    // A second new PDF does.
    final g2 = Completer<String>();
    PdfQueue.I.start(pjob('run2'), (_, _) => g2.future);
    await frames(t, 12);
    expect(find.byType(PdfDeck), findsOneWidget);
    expect(find.text('1/2'), findsOneWidget, reason: 'the new PDF is the one on show');
    await end(t);
  });

  testWidgets('50 PDFs at once: the deck opens ONCE, the list stays 50 long', (t) async {
    await boot(t);
    final gates = [for (var i = 0; i < 50; i++) Completer<String>()];
    var opens = 0;
    for (var i = 0; i < 50; i++) {
      PdfQueue.I.start(pjob('p$i'), (_, _) => gates[i].future);
      await t.pump(const Duration(milliseconds: 10));
      if (find.byType(PdfDeck).evaluate().isNotEmpty) opens++;
      if (i == 0) {
        await t.tap(find.byKey(const ValueKey('pdf-close')));
        await t.pump(const Duration(milliseconds: 10));
      }
    }
    expect(opens, greaterThan(0));
    await frames(t, 12);
    // Only the 2nd PDF (new, running) opened it again, no more than once per new PDF.
    expect(find.byType(PdfDeck), findsOneWidget);
    await end(t);
  });

  testWidgets('a PDF finishing closes the deck and the तैयार popup comes in out of a blur; a second one is a toast', (t) async {
    await boot(t);
    final g1 = Completer<String>();
    final g2 = Completer<String>();
    final a = PdfQueue.I.start(pjob('one'), (_, _) => g1.future);
    await frames(t, 12);
    final b = PdfQueue.I.start(pjob('two'), (_, _) => g2.future);
    await frames(t, 12);
    expect(find.byType(PdfDeck), findsOneWidget);
    finish(a);
    await t.pump(const Duration(milliseconds: 50));
    await t.pump(const Duration(milliseconds: 80));
    expect(find.byType(PdfDeck), findsNothing, reason: 'the deck folds away');
    expect(find.text('one.pdf'), findsOneWidget, reason: 'PDF तैयार popup');
    expect(find.byType(BlurFocus), findsOneWidget);
    expect(find.descendant(of: find.byType(BlurFocus), matching: find.byType(ImageFiltered)), findsOneWidget);
    await t.pump(const Duration(milliseconds: 700));
    expect(find.descendant(of: find.byType(BlurFocus), matching: find.byType(ImageFiltered)), findsNothing);
    // While it is open, the next finished PDF does not stack another popup.
    finish(b);
    await t.pump(const Duration(milliseconds: 40));
    expect(find.text('two.pdf'), findsNothing);
    expect(find.byType(BlurFocus), findsOneWidget);
    await t.tap(find.text('पीछे').last);
    await frames(t, 8);
    expect(find.text('one.pdf'), findsNothing);
    await end(t);
  });
}
