// Round 6: page pictures go into the PDF at their original resolution and quality.
// JPEGs are embedded byte for byte, PNGs keep their own (lossless) pixel data; the
// rendered PDF is compared with the source pixels when poppler (pdftoppm) is installed.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_stream.dart';
import 'package:image/image.dart' as img;

img.Image pattern(int w, int h, {int channels = 3}) {
  final im = img.Image(width: w, height: h, numChannels: channels);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      im.setPixelRgba(x, y, (x * 7 + y) & 255, (y * 5) & 255, ((x ^ y) * 3) & 255, channels == 4 ? ((x + y) % 3 == 0 ? 0 : 255) : 255);
    }
  }
  return im;
}

bool get poppler {
  try {
    return Process.runSync('pdftoppm', ['-v']).exitCode == 0 && Process.runSync('pdfimages', ['-v']).exitCode == 0;
  } catch (_) {
    return false;
  }
}

/// One-page PDF with the picture filling a page of exactly its pixel size (1 pt = 1 px at 72 dpi).
Future<String> onePage(PdfPicture pic, Directory dir) async {
  final path = '${dir.path}/p.pdf';
  final w = PdfStreamWriter(path);
  final page = PdfPageData(pic.w.toDouble(), pic.h.toDouble());
  page.ops.add(PdfOp.image(page.addPicture(pic), 0, 0, pic.w.toDouble(), pic.h.toDouble()));
  w.addPage(page);
  w.close();
  return path;
}

/// The picture as a PDF reader decodes it (poppler's pdfimages), after checking that the
/// page itself renders without errors.
Future<img.Image> render(String pdf, Directory dir) async {
  final r = await Process.run('pdftoppm', ['-r', '20', '-png', '-singlefile', pdf, '${dir.path}/r']);
  expect(r.exitCode, 0, reason: '${r.stderr}');
  expect('${r.stderr}'.trim(), isEmpty, reason: 'no reader warnings');
  final x = await Process.run('pdfimages', ['-png', pdf, '${dir.path}/x']);
  expect(x.exitCode, 0, reason: '${x.stderr}');
  return img.decodePng(File('${dir.path}/x-000.png').readAsBytesSync())!;
}

void main() {
  late Directory dir;
  setUp(() => dir = Directory.systemTemp.createTempSync('pdfq'));
  tearDown(() => dir.deleteSync(recursive: true));

  test('a big JPEG (3000×4000, 2 MB) is embedded byte for byte at full size', () {
    final jpg = Uint8List.fromList(img.encodeJpg(pattern(3000, 4000), quality: 97));
    expect(jpg.length, greaterThan(1500000), reason: 'over the old 1.5 MB re-encode limit');
    final p = prepareImageSync(jpg)!;
    expect(identical(p.bytes, jpg), isTrue);
    expect((p.w, p.h, p.png, p.rgba), (3000, 4000, null, false));
  });

  test('progressive and grey JPEGs pass through; a 12-bit / arithmetic one would not', () {
    final grey = Uint8List.fromList(img.encodeJpg(img.grayscale(pattern(64, 48)), quality: 90));
    expect(passthrough(grey), isNotNull);
    final fake = Uint8List.fromList([0xFF, 0xD8, 0xFF, 0xC9, 0, 17, 8, 0, 20, 0, 30, 3, 1, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1, ...List.filled(40, 0), 0xFF, 0xD9]);
    expect(jpegPassthrough(fake), isFalse, reason: 'SOF9 (arithmetic) is converted instead');
  });

  for (final kind in ['rgb', 'grey', 'palette']) {
    test('$kind PNG keeps its own pixel data and renders pixel-identical', () async {
      final src = switch (kind) {
        'rgb' => pattern(257, 131),
        'grey' => img.grayscale(pattern(257, 131)),
        _ => img.quantize(pattern(257, 131), numberOfColors: 16),
      };
      final png = Uint8List.fromList(img.encodePng(src));
      final p = passthrough(png);
      expect(p, isNotNull);
      expect(p!.png, isNotNull, reason: 'no decode, no re-encode');
      expect((p.w, p.h), (257, 131));
      if (!poppler) return;
      final out = await render(await onePage(p.picture, dir), dir);
      expect((out.width, out.height), (257, 131));
      final want = img.decodePng(png)!;
      var diff = 0;
      for (var y = 0; y < 131; y++) {
        for (var x = 0; x < 257; x++) {
          final a = out.getPixel(x, y), b = want.getPixel(x, y);
          diff = [diff, (a.r - b.r).abs().toInt(), (a.g - b.g).abs().toInt(), (a.b - b.b).abs().toInt()].reduce((m, v) => m > v ? m : v);
        }
      }
      expect(diff, 0);
    });
  }

  test('a transparent PNG is flattened on white and stored losslessly (not as JPEG)', () async {
    final png = Uint8List.fromList(img.encodePng(pattern(120, 90, channels: 4)));
    expect(passthrough(png), isNull);
    final p = prepareImageSync(png)!;
    expect(p.rgba, isTrue);
    expect((p.w, p.h), (120, 90));
    if (!poppler) return;
    final out = await render(await onePage(p.picture, dir), dir);
    // A transparent pixel is white; an opaque one keeps its exact colour.
    expect(out.getPixel(0, 0).r, 255);
    final o = out.getPixel(1, 0);
    expect((o.r.toInt(), o.g.toInt(), o.b.toInt()), (7, 0, 3));
  });

  test('only what PDF cannot take directly is converted, at full size and q95', () {
    // BMP: not embeddable directly.
    final bmp = Uint8List.fromList(img.encodeBmp(pattern(300, 200)));
    final p = prepareImageSync(bmp)!;
    expect((p.w, p.h, p.png, p.rgba), (300, 200, null, false));
    expect(jpegInfo(p.bytes), isNotNull);
  });
}
