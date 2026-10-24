import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/services/pdf_notify.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/widgets/pdf_sheets.dart' show PdfDeck;

import 'helpers.dart';
import 'round3_test.dart' show frames, pjob;

/// Round 7: the PDF card shows ONE PDF at a time with पिछला / अगला (like ashok's deck).
void main() {
  setUp(() async {
    await setUpApp();
    PdfQueue.I.debugReset();
    PdfNotify.I.debugReset();
    PdfNotify.I.call = (m, a) async {};
    PdfNotify.I.query = (m, a) async => null;
  });

  Future<void> boot(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(412, 915));
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await frames(t, 8);
  }

  testWidgets('one card, अगला / पिछला disabled at the ends, counter n/N, focus on the running PDF', (t) async {
    await boot(t);
    final q = PdfQueue.I;
    q.jobs.addAll([pjob('a', phase: PdfPhase.done, percent: 100), pjob('b', phase: PdfPhase.done, percent: 100)]);
    final gate = Completer<String>();
    final run = q.start(pjob('run'), (j, r) => gate.future);
    q.dismiss('-');
    await frames(t, 12);
    // Round 8 (ashok): a new running PDF opens the deck by itself.
    expect(find.byKey(const ValueKey('pdf-dropdown')), findsOneWidget);
    // The running PDF (newest, first in the list) is the one on show.
    expect(find.text('1/3'), findsOneWidget);
    expect(find.byKey(ValueKey('pdf-x-${run.id}')), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-x-a')), findsNothing);
    await t.tap(find.byKey(const ValueKey('pdf-prev')));
    await frames(t, 3);
    expect(find.text('1/3'), findsOneWidget, reason: 'पिछला at the start does nothing');
    await t.tap(find.byKey(const ValueKey('pdf-next')));
    await frames(t, 4);
    expect(find.text('2/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-x-a')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pdf-next')));
    await frames(t, 4);
    expect(find.text('3/3'), findsOneWidget);
    expect(find.byKey(const ValueKey('pdf-x-b')), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pdf-next')));
    await frames(t, 3);
    expect(find.text('3/3'), findsOneWidget, reason: 'अगला at the end does nothing');
    // A tick while browsing must not yank the card back.
    await t.pump(const Duration(seconds: 3));
    expect(find.text('3/3'), findsOneWidget);
    await t.runAsync(() async => gate.complete('x'));
    await t.pump(const Duration(seconds: 4));
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('a newly started PDF is brought up once; a failed one shows the Hindi message + retry', (t) async {
    await boot(t);
    final q = PdfQueue.I;
    final one = pjob('one', phase: PdfPhase.done, percent: 100);
    one.filePath = '/tmp/one.pdf';
    q.jobs.add(one);
    final bad = pjob('bad')
      ..phase = PdfPhase.error
      ..error = pdfPagesMissingMessage(3);
    q.jobs.add(bad);
    q.dismiss('-');
    await frames(t, 4);
    // Neither is running (added as done / failed): the deck stays shut until the arrow is tapped.
    expect(find.byType(PdfDeck), findsNothing);
    await t.tap(find.byKey(const ValueKey('pdf-arrow')));
    await frames(t, 12);
    expect(find.text('2/2'), findsOneWidget);
    expect(find.textContaining('कुछ पेज डाउनलोड नहीं हुए'), findsOneWidget);
    expect(find.textContaining('(3 पेज बाकी)'), findsOneWidget);
    expect(find.text('फिर कोशिश करें'), findsOneWidget);
    expect(find.text('PDF खोलें'), findsNothing);
    await t.tap(find.byKey(const ValueKey('pdf-prev')));
    await frames(t, 4);
    expect(find.text('1/2'), findsOneWidget);
    expect(find.text('PDF खोलें'), findsOneWidget);
    expect(find.text('फिर कोशिश करें'), findsNothing);
    // A new running PDF jumps in front once.
    final gate = Completer<String>();
    q.start(pjob('new'), (j, r) => gate.future);
    await frames(t, 4);
    expect(find.text('1/3'), findsOneWidget);
    await t.runAsync(() async => gate.complete('x'));
    await t.pump(const Duration(seconds: 4));
    await t.pumpWidget(const SizedBox());
  });
}
