import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/pdf_notify.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';

import 'helpers.dart';

/// Round 8 item 7: no spammy notifications. ONE progress notification while PDFs are made and ONE
/// summary afterwards, with a monochrome status-bar icon on every notification.
PdfJob job(String id, {String? error}) => PdfJob(id: id, title: 'ग्रंथ $id', fileName: '$id.pdf', galleryId: 'g-$id', dedupeKey: id)
  ..total = 53
  ..error = error;

void main() {
  late List<(String, Map<String, Object?>)> calls;
  setUp(() async {
    await setUpApp();
    PdfQueue.I.debugReset();
    PdfNotify.I.debugReset();
    PdfNotify.summaryDelay = const Duration(milliseconds: 60);
    calls = [];
    PdfNotify.I.call = (m, a) async => calls.add((m, a));
    PdfNotify.I.query = (m, a) async => m == 'notifState' ? {'sdk': 34, 'granted': true, 'enabled': true} : null;
    PdfNotify.I.attach();
  });
  tearDown(() {
    PdfQueue.I.debugReset();
    PdfNotify.I.debugReset();
  });

  int count(String m) => calls.where((c) => c.$1 == m).length;

  test('50 PDFs: one progress notification stream, NO per-PDF announcement, ONE summary at the end', () async {
    final q = PdfQueue.I;
    for (var i = 0; i < 50; i++) {
      q.start(job('p$i'), (j, r) => Completer<String>().future);
    }
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(count('pdfProgress'), greaterThan(0));
    // All 50 finish one after another while the run is still going.
    for (final j in List.of(q.jobs)) {
      PdfNotify.I.done(j, 'content://dl/${j.id}');
      await Future<void>.delayed(const Duration(milliseconds: 2));
    }
    expect(count('pdfSummary'), 0, reason: 'nothing is announced while PDFs are still being made');
    expect(calls.map((c) => c.$1).toSet().difference({'pdfProgress'}), isEmpty, reason: 'only progress so far');
    for (final j in List.of(q.jobs)) {
      q.cancel(j.id);
    }
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(count('pdfStop'), 1);
    expect(count('pdfSummary'), 1, reason: '50 finished PDFs → exactly one notification');
    final s = calls.firstWhere((c) => c.$1 == 'pdfSummary').$2;
    expect(s['done'], 50);
    expect(s['failed'], 0);
    expect((s['names']! as List).length, lessThanOrEqualTo(5));
    expect(s['uri'], isNull, reason: 'more than one PDF: a tap opens the app, not one PDF');
    // Progress updates are throttled (≈2 a second), so a long run never floods the status bar.
    expect(count('pdfProgress'), lessThan(12));
    // Nothing else is posted later.
    final n = calls.length;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(calls.length, n);
  });

  test('one PDF: summary carries its Downloads link; a failure then a retry success is one "done"', () async {
    final j = job('solo');
    PdfNotify.I.failed(job('solo', error: 'पेज नहीं मिले'));
    PdfNotify.I.done(j, 'content://dl/solo');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(count('pdfSummary'), 1);
    final s = calls.single.$2;
    expect([s['done'], s['failed'], s['uri']], [1, 0, 'content://dl/solo']);
  });

  test('failures only: one summary with the reason; mixed run counts both', () async {
    PdfNotify.I.failed(job('x', error: 'इंटरनेट नहीं'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    var s = calls.single.$2;
    expect([s['done'], s['failed'], s['error']], [0, 1, 'इंटरनेट नहीं']);
    calls.clear();
    PdfNotify.I.done(job('a'), null);
    PdfNotify.I.done(job('b'), null);
    PdfNotify.I.failed(job('c', error: 'e'));
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(count('pdfSummary'), 1);
    s = calls.single.$2;
    expect([s['done'], s['failed'], s['error']], [2, 1, '']);
  });

  test('a summary is never posted while another run is going; it follows that run\'s end', () async {
    final q = PdfQueue.I;
    q.start(job('live'), (j, r) => Completer<String>().future);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    PdfNotify.I.done(job('old'), null);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(count('pdfSummary'), 0);
    q.cancel(q.jobs.first.id);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(count('pdfSummary'), 1);
  });

  group('Android side (read from the sources, the Kotlin JVM tests check the texts)', () {
    final main = Directory('android/app/src/main');
    String read(String p) => File('${main.path}/$p').readAsStringSync();
    final pdf = read('kotlin/com/wnm/granthprabandhan/PdfService.kt');
    final sync = read('kotlin/com/wnm/granthprabandhan/PageSyncService.kt');

    test('every notification uses the one monochrome icon, and the old page icon is gone', () {
      for (final src in [pdf, sync]) {
        expect(src, contains('R.drawable.ic_stat_granth'));
        expect(src, isNot(contains('ic_stat_pdf')));
      }
      expect(File('${main.path}/res/drawable/ic_stat_pdf.xml').existsSync(), isFalse);
    });

    test('icon is one flat white shape (alpha-only), no stroke / gradient / colour', () {
      final xml = read('res/drawable/ic_stat_granth.xml').replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');
      final fills = RegExp(r'android:fillColor="([^"]+)"').allMatches(xml).map((m) => m.group(1)!.toUpperCase()).toList();
      expect(fills, isNotEmpty);
      expect(fills.toSet(), {'#FFFFFFFF'});
      for (final bad in ['strokeColor', 'gradient', 'android:tint', 'fillAlpha']) {
        expect(xml, isNot(contains(bad)));
      }
      expect(RegExp(r'android:width="24dp"').hasMatch(xml) && RegExp(r'android:viewportWidth="24"').hasMatch(xml), isTrue);
    });

    test('the summary has one fixed id and the progress notes are quiet and grouped', () {
      expect(pdf, contains('SUMMARY_ID = 4101'));
      expect(pdf, isNot(contains('doneId')));
      expect(pdf, isNot(contains('fun done(')));
      expect(RegExp(r'notify\(SUMMARY_ID').allMatches(pdf).length, 1);
      for (final src in [pdf, sync]) {
        expect(src, contains('setOnlyAlertOnce(true)'));
        expect(src, contains('GROUP'));
      }
      expect(read('kotlin/com/wnm/granthprabandhan/MainActivity.kt'), isNot(contains('"pdfDone"')));
      expect(read('kotlin/com/wnm/granthprabandhan/MainActivity.kt'), contains('"pdfSummary"'));
    });
  });
}
