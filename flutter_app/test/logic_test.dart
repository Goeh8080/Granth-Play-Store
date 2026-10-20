import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/order.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/search.dart';
import 'package:granthprabandhan/state/router.dart';

import 'helpers.dart';

void main() {
  group('routes', () {
    test('parses hash routes like ig()', () {
      expect(GRoute.parse('#/pramans?topic=5').topicId, '5');
      expect(GRoute.parse('#/pramans?granth=9').granthId, '9');
      expect(GRoute.parse('#/gallery').panel, Panel.gallery);
      expect(GRoute.parse('').panel, Panel.dashboard);
    });

    test('deep links map to hashes', () {
      expect(hashFromLink(Uri.parse('https://granth.grok.me/open?topic=3')), '#/pramans?topic=3');
      expect(hashFromLink(Uri.parse('granth://open?id=7')), '#/pramans?id=7');
      expect(hashFromLink(Uri.parse('https://evil.example/open?id=7')), isNull);
    });

    test('back walks the history then lands on the dashboard', () async {
      await setUpApp();
      final nav = AppNav.I;
      nav.go('#/granths');
      await Future<void>.delayed(const Duration(milliseconds: 450));
      nav.go('#/pramans?granth=10');
      expect(nav.debugStack, ['#/dashboard', '#/granths']);
      nav.back();
      expect(nav.hash, '#/granths');
      await Future<void>.delayed(const Duration(milliseconds: 300));
      nav.back();
      expect(nav.hash, '#/dashboard');
    });

    test('double back on the dashboard asks to exit', () async {
      await setUpApp();
      var asked = 0;
      AppNav.I.onExitRequest = () => asked++;
      AppNav.I.back();
      await Future<void>.delayed(const Duration(milliseconds: 120));
      AppNav.I.back();
      expect(asked, 1);
    });
  });

  group('search', () {
    test('finds Devanagari and transliterated queries', () {
      final rows = sampleCatalog().topics;
      expect(searchRows(rows, 'गीता', (t) => docOf([t.title, t.description])).first.id, '2');
      expect(searchRows(rows, 'geeta', (t) => docOf([t.title, t.description])).map((e) => e.id), contains('2'));
      expect(searchRows(rows, '', (t) => docOf([t.title])).length, 2);
    });
  });

  group('ordering', () {
    test('pramans sort by chapter/verse numbers', () {
      final p = orderPramans(sampleCatalog().pramans.where((e) => e.granthId == '10').toList());
      expect(p.map((e) => e.id), ['101', '100']);
    });
  });

  group('helpers', () {
    test('media paths are whitelisted', () {
      expect(mediaPath('granths/a.jpg'), 'granths/a.jpg');
      expect(mediaPath('https://granth.wnmsolutions.com/uploads/x.png'), 'uploads/x.png');
      expect(mediaPath('../etc/passwd'), isNull);
    });

    test('youtube ids', () {
      expect(youtubeId('https://youtu.be/dQw4w9WgXcQ'), 'dQw4w9WgXcQ');
      expect(youtubeId('https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=3'), 'dQw4w9WgXcQ');
    });

    test('pdf file names and texts', () {
      expect(PdfQueue.fileNameFor('a/b:c', 'x'), 'a b c.pdf');
      expect(PdfQueue.fileNameFor('   ', 'granth-1'), 'granth-1.pdf');
      expect(formatBytes(2048), '2.0 KB');
      expect(etaText(null, PdfPhase.pages), 'समय गिना जा रहा है');
    });

    test('jpeg/png header sizes', () {
      final png = [137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 1, 0, 0, 0, 0, 200];
      final h = imageHeader(Uint8List.fromList(png));
      expect(h?.w, 256);
      expect(h?.h, 200);
    });
  });
}

