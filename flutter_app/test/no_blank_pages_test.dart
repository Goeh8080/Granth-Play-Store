// Round 7, item 1: a generated PDF never has blank pages. Every page picture is checked
// (whole file, decodable) before it goes in; odd-but-valid pictures (CMYK, progressive,
// EXIF-rotated, 16-bit PNG) are embedded or converted, never dropped; a page that can't be
// fetched fails the job with a clear Hindi message and is retried when the net is back.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/api.dart' show mediaUrl;
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/pdf_stream.dart';

import 'helpers.dart';
import 'offline_test.dart' show pictureCatalog;
import 'pdf_render_test.dart' show loadFonts;

Uint8List fx(String n) => File('test/fixtures/pages/$n').readAsBytesSync();

/// Pages in a finished PDF (counts `/Type /Page` objects, not `/Pages`).
int pdfPages(Uint8List pdf) => RegExp(r'/Type\s*/Page(?![s\w])').allMatches(String.fromCharCodes(pdf)).length;

void main() {
  group('page pictures', () {
    test('a normal and a progressive JPEG are embedded as they are', () {
      for (final n in ['normal.jpg', 'progressive.jpg']) {
        final b = fx(n);
        final p = passthrough(b);
        expect(p, isNotNull, reason: n);
        expect(identical(p!.bytes, b), isTrue, reason: '$n: no re-encoding');
        expect((p.w, p.h), (120, 80));
      }
    });

    test('an EXIF-rotated JPEG keeps its bytes and is turned upright on the page', () {
      final b = fx('rotated6.jpg');
      expect(jpegScan(b)!.orientation, 6);
      final p = passthrough(b)!;
      expect(p.orientation, 6);
      expect((p.w, p.h), (80, 120), reason: 'shown size is the upright size');
      // Orientation 6 (turn 90° clockwise): the matrix rotates, it does not just scale.
      final m = orientedMatrix(6, 0, 0, 80, 120);
      expect(m[0], 0);
      expect(m[3], 0);
    });

    test('a CMYK JPEG is not embedded raw (colours would invert) but converted, never dropped', () {
      final b = fx('cmyk.jpg');
      expect(passthrough(b), isNull);
      final p = prepareImageSync(b);
      expect(p, isNotNull);
      expect(p!.png == null ? p.bytes[0] : 0xFF, 0xFF, reason: 'converted to an ordinary JPEG');
    });

    test('a 16-bit PNG and a transparent PNG still give a picture', () {
      expect(prepareImageSync(fx('gray16.png')), isNotNull);
      expect(prepareImageSync(fx('alpha.png')), isNotNull);
    });

    test('a cut-off or damaged JPEG is refused (re-fetched), never drawn half-grey', () async {
      expect(ImageStore.bytesLookComplete(fx('truncated.jpg')), isFalse);
      expect(passthrough(fx('truncated.jpg')), isNull);
      expect(prepareImageSync(fx('truncated.jpg')), isNull);
      expect(passthrough(fx('garbled.jpg')), isNull);
      expect(await preparePagePicture(fx('truncated.jpg')), isNull);
    });
  });

  group('builder', () {
    testWidgets('missing, cut-off and garbage pictures fail the PDF instead of blank pages', (tester) async {
      await tester.runAsync(loadFonts);
      for (final bad in <PdfSpec Function()>[
        () => PdfSpec(title: 'नहीं मिला', path: 'uploads/none.jpg'),
        () => PdfSpec(title: 'आधा', path: 'uploads/t.jpg')..image = fx('truncated.jpg'),
        () => PdfSpec(title: 'कचरा', path: 'uploads/x.jpg')..image = Uint8List.fromList(List.filled(300, 9)),
        () => PdfSpec(title: 'फ़ाइल नहीं', path: 'uploads/f.jpg')..file = '/nonexistent/f.jpg',
      ]) {
        for (final style in PdfStyle.values) {
          Object? err;
          await tester.runAsync(() async {
            try {
              await BookPdfBuilder().build([PdfSpec(title: 'ठीक', path: 'uploads/ok.jpg')..image = fx('normal.jpg'), bad()], style);
            } catch (e) {
              err = e;
            }
          });
          expect(err, isA<PdfPageFailed>(), reason: '${bad().title} / ${style.name}');
        }
      }
    });

    testWidgets('every kind of valid picture gives exactly one page each (no blanks, none dropped)', (tester) async {
      await tester.runAsync(loadFonts);
      for (final style in PdfStyle.values) {
        final names = ['normal.jpg', 'progressive.jpg', 'rotated6.jpg', 'cmyk.jpg', 'gray16.png', 'alpha.png'];
        final pdf = await tester.runAsync(() => BookPdfBuilder().build([for (final n in names) PdfSpec(title: n, path: 'uploads/$n')..image = fx(n)], style));
        expect(pdf, isNotNull);
        expect(pdfPages(pdf!), names.length, reason: style.name);
      }
    });

    testWidgets('a damaged saved picture is downloaded again (repair) and the PDF completes', (tester) async {
      await tester.runAsync(loadFonts);
      final dir = Directory.systemTemp.createTempSync('nb');
      final bad = File('${dir.path}/p.jpg')..writeAsBytesSync(fx('truncated.jpg'));
      final good = File('${dir.path}/fresh.jpg')..writeAsBytesSync(fx('normal.jpg'));
      var repairs = 0;
      final pdf = await tester.runAsync(() => BookPdfBuilder(repair: (s) async {
            repairs++;
            return good.path;
          }).build([PdfSpec(title: 'पेज', path: 'uploads/p.jpg')..file = bad.path], PdfStyle.original));
      expect(repairs, 1);
      expect(pdfPages(pdf!), 1);
    });
  });

  group('PDF job', () {
    late HttpServer server;
    var serve = true;
    var hits = 0;
    setUp(() async {
      await setUpApp();
      HttpOverrides.global = null;
      PdfQueue.I.debugReset();
      PdfQueue.fetchBackoff = const [Duration(milliseconds: 10), Duration(milliseconds: 20)];
      PdfQueue.I.netCheckEvery = const Duration(milliseconds: 50);
      serve = true;
      hits = 0;
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((r) async {
        if (r.method != 'HEAD') hits++;
        if (!serve) {
          r.response.statusCode = 503;
          await r.response.close();
          return;
        }
        r.response.headers.contentType = ContentType('image', 'jpeg');
        r.response.add(fx('normal.jpg'));
        await r.response.close();
      });
      ImageStore.I.urlFor = (p) => 'http://127.0.0.1:${server.port}/$p';
      CatalogStore.I.debugSetCatalog(pictureCatalog());
    });
    tearDown(() async {
      PdfQueue.I.debugReset();
      ImageStore.I.urlFor = mediaUrl;
      await server.close(force: true);
    });

    Future<PdfJob> settle(WidgetTester tester, {bool Function(PdfJob j)? until}) async {
      final job = PdfQueue.I.jobs.first;
      await tester.runAsync(() async {
        for (var i = 0; i < 600 && (until == null ? job.active : !until(job)); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      return job;
    }

    testWidgets('pages not saved yet are downloaded first; the PDF has all of them', (tester) async {
      await tester.runAsync(loadFonts);
      final g = CatalogStore.I.granths.firstWhere((e) => e.id == '10');
      await tester.runAsync(() async => PdfQueue.I.granthPdf(g, PdfStyle.original));
      final job = await settle(tester);
      expect(job.phase, PdfPhase.done, reason: job.error);
      expect(hits, 6, reason: 'g10, e10 + 4 praman pages');
      final pdf = await tester.runAsync(() => File(job.filePath!).readAsBytes());
      expect(pdfPages(pdf!), 6);
    });

    testWidgets('all pages saved: no network at all (fast path)', (tester) async {
      await tester.runAsync(loadFonts);
      final g = CatalogStore.I.granths.firstWhere((e) => e.id == '10');
      await tester.runAsync(() async {
        for (final p in ['granths/g10.jpg', 'granths/e10.jpg', 'uploads/p0.jpg', 'uploads/p2.jpg', 'uploads/p4.jpg', 'uploads/p6.jpg']) {
          final f = ImageStore.I.fileFor(p);
          await f.parent.create(recursive: true);
          await f.writeAsBytes(fx('normal.jpg'));
        }
      });
      await tester.runAsync(() => server.close(force: true)); // any request would fail
      await tester.runAsync(() async => PdfQueue.I.granthPdf(g, PdfStyle.fill90));
      final job = await settle(tester);
      expect(job.phase, PdfPhase.done, reason: job.error);
      expect(hits, 0);
    });

    testWidgets('offline: no PDF with blank pages — clear Hindi error, then auto-retry when online', (tester) async {
      await tester.runAsync(loadFonts);
      serve = false;
      final g = CatalogStore.I.granths.firstWhere((e) => e.id == '10');
      await tester.runAsync(() async => PdfQueue.I.granthPdf(g, PdfStyle.fill90));
      final job = await settle(tester);
      expect(job.phase, PdfPhase.error);
      expect(job.filePath, isNull, reason: 'no PDF is saved');
      expect(job.error, startsWith(kPdfPagesMissing));
      expect(job.waitsForNet, isTrue);
      expect(job.canRetry, isTrue, reason: 'the card shows “फिर कोशिश करें”');

      // Net comes back: the job runs again by itself and finishes with every page.
      serve = true;
      CatalogStore.I.online = false;
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 120)));
      CatalogStore.I.online = true;
      await tester.runAsync(() async => PdfQueue.I.networkBack());
      final again = await settle(tester, until: (j) => j.phase == PdfPhase.done || (j.phase == PdfPhase.error && j.attempts > 1 && !j.active && hits > 12));
      expect(again.phase, PdfPhase.done, reason: again.error);
      final pdf = await tester.runAsync(() => File(again.filePath!).readAsBytes());
      expect(pdfPages(pdf!), 6);
    });
  });
}
