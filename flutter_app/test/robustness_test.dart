import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/gallery_service.dart';
import 'package:granthprabandhan/services/file_actions.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/pdf_stream.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'helpers.dart';

/// A run that waits until the test releases it, then writes a tiny valid PDF.
class Gate {
  final c = Completer<void>();
  bool fail = false;
  int calls = 0;
  Future<String> run(PdfJob job, void Function(PdfPhase, int, int) report) async {
    calls++;
    report(PdfPhase.pages, 1, 2);
    await c.future;
    if (fail) throw StateError('boom');
    final path = PdfQueue.workPath(job);
    final w = PdfStreamWriter(path);
    w.addPage(PdfPageData(100, 100)..ops.add(const PdfOp.fill(0, 0, 100, 100, 1, 1, 1)));
    w.close();
    return path;
  }
}

PdfJob job(String id, {int pages = 3, String? key}) => PdfJob(id: id, title: id, fileName: '$id.pdf', galleryId: 'pdf-granth-$id', pages: pages, dedupeKey: key);

Future<void> until(bool Function() f) async {
  for (var i = 0; i < 400 && !f(); i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

void main() {
  setUp(() async {
    await setUpApp();
    PdfQueue.I.debugReset();
    PdfQueue.I.freeBytes = () async => null;
    PdfQueue.I.retryDelay = Duration.zero;
  });

  group('PDF jobs', () {
    test('no queue: up to 3 build at once, the rest start as slots free up', () async {
      final q = PdfQueue.I..slotsOverride = 3;
      final gates = List.generate(5, (_) => Gate());
      for (var i = 0; i < 5; i++) {
        q.start(job('j$i'), gates[i].run);
      }
      await until(() => q.runningSlots == 3);
      expect(q.runningSlots, 3);
      expect(gates.where((g) => g.calls == 1).length, 3);
      expect(q.activeCount, 5);
      gates[0].c.complete();
      await until(() => gates[3].calls == 1);
      expect(gates[3].calls, 1);
      for (final g in gates.skip(1)) {
        if (!g.c.isCompleted) g.c.complete();
      }
      await until(() => q.jobs.every((j) => j.phase == PdfPhase.done));
      expect(q.jobs.every((j) => j.phase == PdfPhase.done), isTrue);
      expect(q.jobs.every((j) => File(j.filePath!).existsSync()), isTrue);
      // The temp .part files were moved, none left behind.
      expect(Directory(Store.I.pdfDir).listSync().where((f) => f.path.endsWith('.part')), isEmpty);
    });

    test('low-RAM phone: one PDF at a time', () async {
      final q = PdfQueue.I..slotsOverride = 1;
      final a = Gate(), b = Gate();
      q.start(job('a'), a.run);
      q.start(job('b'), b.run);
      await until(() => a.calls == 1);
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(b.calls, 0);
      a.c.complete();
      await until(() => b.calls == 1);
      b.c.complete();
      await until(() => q.activeCount == 0);
      expect(q.jobs.every((j) => j.phase == PdfPhase.done), isTrue);
    });

    test('a failing PDF retries once, then shows the Hindi error; others are not affected; retry works', () async {
      final q = PdfQueue.I..slotsOverride = 3;
      final bad = Gate()..fail = true;
      final good = Gate();
      bad.c.complete();
      final jb = q.start(job('bad'), bad.run);
      q.start(job('good'), good.run);
      await until(() => jb.phase == PdfPhase.error);
      expect(bad.calls, 2); // one automatic retry
      expect(jb.error, kPdfFailed);
      expect(jb.canRetry, isTrue);
      good.c.complete();
      await until(() => q.jobs.firstWhere((j) => j.id == 'good').phase == PdfPhase.done);
      bad.fail = false;
      q.retry('bad');
      await until(() => jb.phase == PdfPhase.done);
      expect(jb.phase, PdfPhase.done);
    });

    test('too little free space: clear message, no work, no automatic retry', () async {
      final q = PdfQueue.I..freeBytes = () async => 5 << 20;
      final g = Gate()..c.complete();
      final j = q.start(job('big', pages: 200), g.run);
      await until(() => j.phase == PdfPhase.error);
      expect(j.error, contains('जगह कम'));
      expect(g.calls, 0);
      expect(j.attempts, 1);
    });

    test('disk full while saving (ENOSPC) gives the free-space message', () async {
      final q = PdfQueue.I;
      final j = q.start(job('full'), (job, r) async => throw const FileSystemException('write failed', 'x', OSError('No space left on device', 28)));
      await until(() => j.phase == PdfPhase.error);
      expect(j.error, contains('जगह कम'));
      expect(j.attempts, 1);
    });

    test('cancel stops the job and leaves no file', () async {
      final q = PdfQueue.I;
      final g = Gate();
      final j = q.start(job('c'), g.run);
      await until(() => g.calls == 1);
      q.cancel('c');
      g.c.complete();
      await until(() => q.runningSlots == 0);
      expect(j.phase, PdfPhase.cancelled);
      expect(File('${Store.I.pdfDir}/c.pdf').existsSync(), isFalse);
      expect(File(PdfQueue.workPath(j)).existsSync(), isFalse);
    });

    test('double tap on the same PDF makes one job', () async {
      final q = PdfQueue.I;
      final g = Gate();
      final a = q.start(job('x', key: 'k'), g.run);
      final b = q.start(job('y', key: 'k'), g.run);
      expect(identical(a, b), isTrue);
      expect(q.jobs.length, 1);
      g.c.complete();
      await until(() => q.activeCount == 0);
    });

    test('the same PDF asked again on purpose gets its own entry', () async {
      final q = PdfQueue.I;
      final g = Gate();
      final a = q.start(job('x', key: 'k'), g.run);
      a.startedAt -= PdfQueue.doubleTapWindowMs + 1;
      final b = q.start(job('y', key: 'k'), g.run);
      expect(identical(a, b), isFalse);
      expect(q.jobs.length, 2);
      g.c.complete();
      await until(() => q.activeCount == 0);
      expect(q.jobs.length, 2);
    });

    test('× removes a row for good; a running PDF is stopped first; clear finished', () async {
      final q = PdfQueue.I;
      final g = Gate();
      final a = q.start(job('a', key: 'a'), g.run);
      final b = q.start(job('b', key: 'b'), g.run);
      q.remove(a.id);
      expect(a.cancelled, isTrue);
      expect(q.jobs.map((e) => e.id), ['b']);
      g.c.complete();
      await until(() => q.activeCount == 0);
      expect(b.phase, PdfPhase.done);
      q.clearFinished();
      expect(q.jobs, isEmpty);
    });

    test('free-space estimate grows with the book', () {
      expect(PdfQueue.bytesNeeded(500), greaterThan(PdfQueue.bytesNeeded(10)));
    });
  });

  group('files', () {
    test('atomic write: an interrupted write never leaves a broken file under the real name', () async {
      final dir = Directory('${Store.I.root.path}/ro')..createSync();
      final f = File('${dir.path}/a.pdf');
      await FileActions.writeAtomic(f, [1, 2, 3]);
      expect(f.readAsBytesSync(), [1, 2, 3]);
      File('${dir.path}/b.pdf.part').writeAsBytesSync([9]);
      File('${Store.I.pdfDir}/old.pdf.part').writeAsBytesSync([9]);
      expect(await FileActions.cleanupPartials(), greaterThanOrEqualTo(1));
      expect(File('${Store.I.pdfDir}/old.pdf.part').existsSync(), isFalse);
    });

    test('aborting a PDF deletes the partial file', () async {
      final path = '${Store.I.pdfDir}/p.pdf.part';
      final sink = await PdfSink.open(path, isolate: false);
      await sink.addPage(PdfPageData(10, 10));
      expect(File(path).existsSync(), isTrue);
      await sink.abort();
      expect(File(path).existsSync(), isFalse);
    });

    test('streamed PDF is well-formed (header, xref, trailer, page count)', () async {
      final path = '${Store.I.pdfDir}/w.pdf';
      final sink = await PdfSink.open(path); // background isolate
      for (var i = 0; i < 3; i++) {
        final p = PdfPageData(595.28, 841.89);
        p.ops.add(const PdfOp.fill(0, 0, 595.28, 841.89, 1, 0.99, 0.97));
        final id = p.addPicture(PdfPicture.rgba(Uint8List(4 * 4 * 4), 4, 4));
        p.ops.add(PdfOp.image(id, 10, 10, 40, 40));
        p.ops.add(const PdfOp.text('12', 11, 500, 9, 0.48, 0.12, 0.18));
        await sink.addPage(p);
      }
      final size = await sink.close();
      final bytes = File(path).readAsBytesSync();
      expect(bytes.length, size);
      final text = String.fromCharCodes(bytes);
      expect(text.startsWith('%PDF-1.4'), isTrue);
      expect(text.contains('/Count 3'), isTrue);
      expect(text.trimRight().endsWith('%%EOF'), isTrue);
      final sx = int.parse(RegExp(r'startxref\n(\d+)').firstMatch(text)!.group(1)!);
      expect(text.substring(sx, sx + 4), 'xref');
    });

    test('damaged JSON files read as empty, never throw', () async {
      File('${Store.I.root.path}/catalog.json').writeAsStringSync('{"topics": [1, 2');
      expect(await Store.I.readJson('catalog.json'), isNull);
      File('${Store.I.root.path}/gallery.json').writeAsStringSync('[{"id": 5}, "x", {"id":"a","kind":"pdf","title":"t","fileName":"f.pdf","filePath":"/nope/f.pdf"}]');
      expect(await GalleryService.I.items(), isEmpty);
    });

    test('jpegInfo reads size and colour components', () {
      final jpg = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, 0, 20, 0, 30, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, 0xFF, 0xD9]);
      final i = jpegInfo(jpg)!;
      expect((i.w, i.h, i.components), (30, 20, 3));
    });

    test('a huge JPEG goes into the PDF as it is: original size, never decoded (round 6)', () {
      // JPEG header claiming 6000×6000 (36 MP).
      final jpg = Uint8List.fromList([
        0xFF, 0xD8, 0xFF, 0xC0, 0, 17, 8, 0x17, 0x70, 0x17, 0x70, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, //
        0xFF, 0xC4, 0, 4, 0, 0, // Huffman table segment (contents not read)
        0xFF, 0xDA, 0, 12, 3, 1, 0, 2, 0x11, 3, 0x11, 0, 0x3F, 0, // start of scan
        ...List.filled(40, 0), 0xFF, 0xD9,
      ]);
      final p = prepareImageSync(jpg)!;
      expect(identical(p.bytes, jpg), isTrue, reason: 'no re-encoding');
      expect((p.w, p.h), (6000, 6000));
    });

    test('a huge picture that would need decoding is not decoded in Dart (memory)', () {
      // PNG header claiming 6000×6000 RGBA (needs decoding to flatten transparency).
      final png = Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0x17, 0x70, 0, 0, 0x17, 0x70, 8, 6, 0, 0, 0, 0, 0, 0, 0, ...List.filled(40, 0)]);
      expect(prepareImageSync(png), isNull);
    });
  });
}
