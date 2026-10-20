import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';

import '../theme/colors.dart';

/// Port of the web app's `buildBookPdf` (pdf-lib + canvas). Text is drawn with Flutter's
/// text engine (correct Devanagari shaping with Noto Sans Devanagari) into images, exactly like
/// the original drew text on a <canvas> before embedding it.

enum PdfStyle { fill90, original }

PdfStyle pdfStyleFrom(String? v) => v == 'original' ? PdfStyle.original : PdfStyle.fill90;
String pdfStyleId(PdfStyle s) => s == PdfStyle.original ? 'original' : 'fill90';

class PdfStyleOption {
  const PdfStyleOption(this.style, this.title, this.hint);
  final PdfStyle style;
  final String title;
  final String hint;
}

const pdfStyleOptions = [
  PdfStyleOption(PdfStyle.fill90, 'PDF विषय के साथ', 'बड़ा चित्र, विषय ऊपर और पेज नीचे'),
  PdfStyleOption(PdfStyle.original, 'केवल चित्र', 'सिर्फ़ मूल चित्र, पूरी गुणवत्ता, कोई लिखावट नहीं'),
];

class PdfSpec {
  PdfSpec({required this.title, this.subtitle = '', this.body = '', this.meta = '', this.path, this.cover = false, this.topicCover = false, this.image});
  final String title;
  final String subtitle;
  final String body;
  final String meta;
  final String? path;
  final bool cover;
  final bool topicCover;
  Uint8List? image;
}

class PreparedImage {
  PreparedImage(this.bytes, this.w, this.h);
  final Uint8List bytes; // always JPEG
  final int w;
  final int h;
}

const double _a4w = 595.28;
const double _a4h = 841.89;

class PdfCancelled implements Exception {}

/// `Bm` — read PNG/JPEG dimensions from the header.
({int w, int h, String kind})? imageHeader(Uint8List e) {
  if (e.length >= 24 && e[0] == 137 && e[1] == 80 && e[2] == 78 && e[3] == 71) {
    final w = (e[16] << 24) | (e[17] << 16) | (e[18] << 8) | e[19];
    final h = (e[20] << 24) | (e[21] << 16) | (e[22] << 8) | e[23];
    if (w > 0 && h > 0) return (w: w, h: h, kind: 'png');
  }
  if (e.length < 4 || e[0] != 255 || e[1] != 216) return null;
  var t = 2;
  while (t + 9 < e.length) {
    if (e[t] != 255) {
      t += 1;
      continue;
    }
    final n = e[t + 1];
    if (n == 255) {
      t += 1;
      continue;
    }
    if (n >= 192 && n <= 207 && n != 196 && n != 200 && n != 204) {
      final h = (e[t + 5] << 8) | e[t + 6];
      final w = (e[t + 7] << 8) | e[t + 8];
      if (w > 0 && h > 0) return (w: w, h: h, kind: 'jpg');
    }
    if (n == 216) {
      t += 2;
      continue;
    }
    if (n == 217 || n == 218) break;
    final r = (e[t + 2] << 8) | e[t + 3];
    if (r < 2) break;
    t += 2 + r;
  }
  return null;
}

/// `Hm`/`Um` — keep small JPEGs untouched, otherwise flatten on white, cap at 1800 px, JPEG q90.
PreparedImage? prepareImageSync(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final head = imageHeader(bytes);
  const cap = 1800;
  if (head != null && head.kind == 'jpg' && head.w <= cap && head.h <= cap && bytes.length < 1100000) {
    return PreparedImage(bytes, head.w, head.h);
  }
  try {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    final scale = math.min(1.0, cap / math.max(im.width, im.height));
    if (scale < 1) {
      im = img.copyResize(im, width: math.max(1, (im.width * scale).round()), height: math.max(1, (im.height * scale).round()), interpolation: img.Interpolation.average);
    }
    if (im.hasAlpha) {
      final bg = img.Image(width: im.width, height: im.height);
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(bg, im);
      im = bg;
    }
    return PreparedImage(Uint8List.fromList(img.encodeJpg(im, quality: 90)), im.width, im.height);
  } catch (_) {
    return null;
  }
}

Future<PreparedImage?> prepareImage(Uint8List? bytes) async {
  if (bytes == null || bytes.length < 32) return null;
  return compute(prepareImageSync, bytes);
}

/// Small JPEG used as the gallery preview (`sh`): max 720 px on #fffdf7, q82.
Uint8List? previewFromJpegSync(Uint8List bytes) {
  try {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    final s = math.min(1.0, 720 / math.max(im.width, im.height));
    if (s < 1) im = img.copyResize(im, width: math.max(1, (im.width * s).round()), height: math.max(1, (im.height * s).round()));
    return Uint8List.fromList(img.encodeJpg(im, quality: 82));
  } catch (_) {
    return null;
  }
}

({Uint8List? jpeg, Uint8List? preview}) _coverJpeg(({Uint8List rgba, int w, int h}) a) {
  try {
    final full = img.Image.fromBytes(width: a.w, height: a.h, bytes: a.rgba.buffer, numChannels: 4);
    final jpeg = Uint8List.fromList(img.encodeJpg(full, quality: 92));
    final s = math.min(1.0, 720 / math.max(full.width, full.height));
    final small = img.copyResize(full, width: math.max(1, (full.width * s).round()), height: math.max(1, (full.height * s).round()));
    return (jpeg: jpeg, preview: Uint8List.fromList(img.encodeJpg(small, quality: 82)));
  } catch (_) {
    return (jpeg: null, preview: null);
  }
}

class _Line {
  _Line(this.text, this.size, this.color, this.weight);
  final String text;
  final double size;
  final Color color;
  final FontWeight weight;
}

class _TextImage {
  _TextImage(this.rgba, this.pxW, this.pxH, this.w, this.h);
  final Uint8List rgba;
  final int pxW;
  final int pxH;
  final double w; // points
  final double h; // points
}

ui.ParagraphStyle _pStyle({TextAlign align = TextAlign.left}) => ui.ParagraphStyle(textAlign: align, textDirection: TextDirection.ltr);

ui.TextStyle _uiStyle({required double size, required Color color, FontWeight weight = FontWeight.w400, String family = GFonts.sans, List<String>? fallback, List<ui.Shadow>? shadows}) => ui.TextStyle(
      color: color,
      fontSize: size,
      fontWeight: weight,
      fontFamily: family,
      fontFamilyFallback: fallback ?? const ['NotoDeva', 'DMSans', 'NotoDevaFull'],
      shadows: shadows,
    );

ui.Paragraph _para(String text, ui.TextStyle style, double width, {TextAlign align = TextAlign.left}) {
  final b = ui.ParagraphBuilder(_pStyle(align: align))
    ..pushStyle(style)
    ..addText(text);
  return b.build()..layout(ui.ParagraphConstraints(width: width));
}

/// Word-wrap `text` to `maxWidth` px (like `Gm`/`Qm`), returning one string per visual line.
List<String> wrapText(String text, ui.TextStyle style, double maxWidth) {
  final out = <String>[];
  for (final raw in text.split('\n')) {
    final line = raw.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).join(' ');
    if (line.isEmpty) continue;
    final p = _para(line, style, math.max(8, maxWidth));
    var off = 0;
    while (off < line.length) {
      final b = p.getLineBoundary(TextPosition(offset: off));
      final end = b.end <= off ? off + 1 : b.end;
      final piece = line.substring(off, end.clamp(0, line.length)).trim();
      if (piece.isNotEmpty) out.add(piece);
      off = end;
    }
  }
  return out;
}

Future<_TextImage?> _renderLines(List<_Line> lines, double widthPt, Color bg) async {
  final rows = lines.where((l) => l.text.trim().isNotEmpty).toList();
  if (rows.isEmpty || widthPt < 24) return null;
  final pxW = math.max(80, (widthPt * 2).round());
  final wrapped = <_Line>[];
  for (final l in rows) {
    final st = _uiStyle(size: l.size * 2, color: l.color, weight: l.weight);
    for (final t in wrapText(l.text.replaceAll(RegExp(r'[ \t]+'), ' ').trim(), st, pxW - 56.0)) {
      wrapped.add(_Line(t, l.size, l.color, l.weight));
    }
  }
  if (wrapped.isEmpty) return null;
  double lh(_Line l) => (l.size * 1.62 * 2).ceilToDouble();
  final pxH = math.max(8, wrapped.fold<double>(32, (s, l) => s + lh(l)).round());
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(ui.Rect.fromLTWH(0, 0, pxW.toDouble(), pxH.toDouble()), ui.Paint()..color = bg);
  var y = 16.0;
  for (final l in wrapped) {
    final p = _para(l.text, _uiStyle(size: l.size * 2, color: l.color, weight: l.weight), 100000);
    c.drawParagraph(p, ui.Offset(24, y + (lh(l) - p.height) / 2));
    y += lh(l);
  }
  final image = await rec.endRecording().toImage(pxW, pxH);
  final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  image.dispose();
  if (data == null) return null;
  return _TextImage(data.buffer.asUint8List(), pxW, pxH, widthPt, pxH / 2);
}

Future<_TextImage?> _textBlock(String text, double widthPt, double size, Color color, FontWeight weight) async {
  final t = text.trim();
  if (t.isEmpty) return null;
  return _renderLines([_Line(t, size, color, weight)], widthPt, GColors.paper);
}

List<String> _linesFor(String text, double widthPt, double size, FontWeight weight) {
  final t = text.trim();
  if (t.isEmpty) return [];
  return wrapText(t, _uiStyle(size: size * 2, color: GColors.text, weight: weight), math.max(80, (widthPt * 2).round()) - 56.0);
}

List<List<String>> _pagesOf(List<String> lines, double size, double maxH) {
  final r = size * 1.62;
  final pages = <List<String>>[];
  var cur = <String>[];
  var o = 12.0;
  for (final t in lines) {
    if (cur.isNotEmpty && o + r > maxH) {
      pages.add(cur);
      cur = [];
      o = 12;
    }
    cur.add(t);
    o += r;
  }
  if (cur.isNotEmpty) pages.add(cur);
  return pages.isEmpty ? [[]] : pages;
}

({double w, double h}) _fit(double maxW, double maxH, num w, num h) {
  final i = math.min(maxW / w, maxH / h);
  return (w: w * i, h: h * i);
}

PdfColor _pc(Color c) => PdfColor(c.r, c.g, c.b);

class BookPdfBuilder {
  BookPdfBuilder({this.isCancelled, this.onPage, this.onPreview});
  final bool Function()? isCancelled;
  final void Function(int done, int total)? onPage;
  final void Function(Uint8List jpeg)? onPreview;

  late PdfDocument _doc;
  late PdfFont _font;

  void _check() {
    if (isCancelled?.call() ?? false) throw PdfCancelled();
  }

  PdfImage _rgbaImage(_TextImage t) => PdfImage(_doc, image: _rgb(t.rgba, t.pxW * t.pxH), width: t.pxW, height: t.pxH, alpha: false);

  static Uint8List _rgb(Uint8List rgba, int n) {
    final out = Uint8List(n * 3);
    for (var i = 0, j = 0; i < n; i++, j += 4) {
      out[i * 3] = rgba[j];
      out[i * 3 + 1] = rgba[j + 1];
      out[i * 3 + 2] = rgba[j + 2];
    }
    return out;
  }

  PdfPage _page(double w, double h, Color fill) {
    final p = PdfPage(_doc, pageFormat: PdfPageFormat(w, h));
    final g = p.getGraphics();
    g.setFillColor(_pc(fill));
    g.drawRect(0, 0, w, h);
    g.fillPath();
    return p;
  }

  void _stamp(PdfPage page, int n) {
    final s = '$n';
    final m = _font.stringMetrics(s);
    final tw = m.advanceWidth * 11;
    final w = page.pageFormat.width;
    final g = page.getGraphics();
    g.saveContext();
    g.setGraphicState(PdfGraphicState(opacity: 0.92));
    g.setFillColor(const PdfColor(1, 0.984, 0.953));
    g.drawRect(w - tw - 16, 6, tw + 10, 16);
    g.fillPath();
    g.restoreContext();
    g.setFillColor(const PdfColor(0.482, 0.122, 0.18));
    g.drawString(_font, 11, s, w - tw - 11, 9);
  }

  /// `Xm`
  ({String header, String footer}) _texts(PdfSpec e) {
    final header = (e.body.isNotEmpty ? e.body : (e.subtitle.isNotEmpty ? e.subtitle : (e.title.isNotEmpty ? e.title : 'ग्रंथ'))).trim();
    final parts = [e.body.isNotEmpty ? e.title : '', e.meta, e.body.isNotEmpty ? '' : e.subtitle].map((x) => x.trim()).where((x) => x.isNotEmpty && x != 'आवरण').toList();
    final seen = <String>{};
    return (header: header, footer: parts.where(seen.add).join('\n'));
  }

  Future<void> _drawPage(double a, double o, _TextImage? head, _TextImage? foot, PreparedImage? picture) async {
    const s0 = 8.0;
    final s = a - 16;
    final page = _page(a, o, GColors.paper);
    final g = page.getGraphics();
    final c = head?.h ?? 0;
    final l = foot?.h ?? 0;
    if (head != null) g.drawImage(_rgbaImage(head), s0, o - c - 4, s, c);
    if (foot != null) g.drawImage(_rgbaImage(foot), s0, 20, s, l);
    if (picture != null) {
      final t = c + 8;
      final n = l + 20 + 4;
      final area = math.max(48.0, o - t - n);
      final f = _fit(s, area, picture.w, picture.h);
      final x = s0 + (s - f.w) / 2;
      final y = n + (area - f.h) / 2;
      g.setFillColor(const PdfColor(0, 0, 0));
      g.drawRect(x - 1, y - 1, f.w + 2, f.h + 2);
      g.fillPath();
      g.drawImage(PdfImage.jpeg(_doc, image: picture.bytes), x, y, f.w, f.h);
    }
  }

  Future<void> _preview(PreparedImage? p, bool first) async {
    if (!first || p == null || onPreview == null) return;
    final b = await compute(previewFromJpegSync, p.bytes);
    if (b != null) onPreview!(b);
  }

  /// `nh` — "PDF विषय के साथ": header text, page picture, footer text; long text flows onto extra pages.
  Future<void> _fill(PdfSpec spec, PreparedImage? n, bool first) async {
    final t = _texts(spec);
    final land = n != null && n.w > n.h * 1.02;
    final a = land ? _a4h : _a4w;
    final o = land ? _a4w : _a4h;
    final s = a - 16;
    var c = land ? 16.0 : 17.0;
    var l = land ? 14.0 : 15.0;
    final u = n != null ? (land ? 140.0 : 190.0) : 0.0;
    var d = await _textBlock(t.header, s, c, GColors.maroon, FontWeight.w700);
    var f = await _textBlock(t.footer, s, l, GColors.brown, FontWeight.w600);
    while (c > 13 && (d?.h ?? 0) + (f?.h ?? 0) + u + 20 + 12 > o) {
      c -= 1;
      l = math.max(13, l - 1);
      d = await _textBlock(t.header, s, c, GColors.maroon, FontWeight.w700);
      f = await _textBlock(t.footer, s, l, GColors.brown, FontWeight.w600);
    }
    if ((d?.h ?? 0) + (f?.h ?? 0) + u + 20 + 12 <= o) {
      await _drawPage(a, o, d, f, n);
      await _preview(n, first);
      return;
    }
    final m = _linesFor(t.header, s, c, FontWeight.w700);
    final h = _linesFor(t.footer, s, l, FontWeight.w600);
    final g = n != null ? math.max(80.0, o * 0.24) : o - 20 - 16;
    final firstHead = _pagesOf(m, c, g).first;
    final v = firstHead.isNotEmpty ? await _renderLines(firstHead.map((e) => _Line(e, c, GColors.maroon, FontWeight.w700)).toList(), s, GColors.paper) : null;
    final y = math.max(70.0, o - (v?.h ?? 0) - (n != null ? u : 0) - 20 - 12);
    final firstFoot = _pagesOf(h, l, y).first;
    await _drawPage(a, o, v, firstFoot.isNotEmpty ? await _renderLines(firstFoot.map((e) => _Line(e, l, GColors.brown, FontWeight.w600)).toList(), s, GColors.paper) : null, n);
    await _preview(n, first);
    final rest = [
      ...m.skip(firstHead.length).map((e) => _Line(e, c, GColors.maroon, FontWeight.w700)),
      ...h.skip(firstFoot.length).map((e) => _Line(e, l, GColors.brown, FontWeight.w600)),
    ];
    final maxH = o - 20 - 24;
    var i = 0;
    while (i < rest.length) {
      _check();
      final chunk = <_Line>[];
      var used = 12.0;
      while (i < rest.length) {
        final r = rest[i].size * 1.62;
        if (chunk.isNotEmpty && used + r > maxH) break;
        chunk.add(rest[i]);
        used += r;
        i++;
      }
      await _drawPage(a, o, await _renderLines(chunk, s, GColors.paper), null, null);
    }
  }

  /// `Zm` — decorated topic cover page.
  Future<void> _topicCover(PdfSpec t, bool first) async {
    const scale = 2.0;
    final s = (_a4w * scale).roundToDouble();
    final c = (_a4h * scale).roundToDouble();
    final rec = ui.PictureRecorder();
    final cv = ui.Canvas(rec);
    cv.drawRect(ui.Rect.fromLTWH(0, 0, s, c), ui.Paint()..color = const Color(0xFFF6EFE2));
    final blobs = <(double, double, double, Color)>[
      (s * 0.18, c * 0.16, s * 0.42, const Color.fromRGBO(232, 130, 26, 0.34)),
      (s * 0.84, c * 0.2, s * 0.36, const Color.fromRGBO(123, 31, 46, 0.2)),
      (s * 0.48, c * 0.48, s * 0.58, const Color.fromRGBO(243, 186, 146, 0.62)),
      (s * 0.16, c * 0.78, s * 0.4, const Color.fromRGBO(201, 168, 76, 0.28)),
      (s * 0.8, c * 0.74, s * 0.34, const Color.fromRGBO(232, 168, 124, 0.48)),
      (s * 0.55, c * 0.88, s * 0.3, const Color.fromRGBO(176, 92, 58, 0.16)),
    ];
    for (final (x, y, r, col) in blobs) {
      final paint = ui.Paint()..shader = ui.Gradient.radial(ui.Offset(x, y), r, [col, const Color.fromRGBO(246, 239, 226, 0)], [8 / r, 1]);
      cv.drawCircle(ui.Offset(x, y), r, paint);
    }
    final vignette = ui.Paint()
      ..shader = ui.Gradient.radial(ui.Offset(s / 2, c / 2), c * 0.72, [const Color.fromRGBO(0, 0, 0, 0), const Color.fromRGBO(92, 48, 22, 0.22)], [0.22 / 0.72, 1]);
    cv.drawRect(ui.Rect.fromLTWH(0, 0, s, c), vignette);
    void frame(double inset, double w, Color col) => cv.drawRect(
        ui.Rect.fromLTWH(inset, inset, s - inset * 2, c - inset * 2),
        ui.Paint()
          ..style = ui.PaintingStyle.stroke
          ..strokeWidth = w
          ..color = col);
    frame(26, 16, GColors.maroon);
    frame(46, 7, const Color(0xFFE7B089));
    frame(60, 3, GColors.gold);

    final title = t.title.trim().isEmpty ? 'विषय' : t.title.trim();
    var f = 86.0;
    var lines = <String>[];
    while (f >= 32) {
      lines = wrapText(title, _uiStyle(size: f, color: const Color(0xFF6D1826), family: GFonts.display, fallback: GFonts.displayFallback), s - 170);
      if (lines.length * f * 1.16 < c * 0.42) break;
      f -= 2;
    }
    final m = lines.length * f * 1.16;
    var h = math.max(c * 0.22, c * 0.4 - m / 2);
    final titleStyle = _uiStyle(
      size: f,
      color: const Color(0xFF6D1826),
      family: GFonts.display,
      fallback: GFonts.displayFallback,
      shadows: const [ui.Shadow(color: Color.fromRGBO(255, 236, 214, 0.85), blurRadius: 8)],
    );
    for (final line in lines) {
      cv.drawParagraph(_para(line, titleStyle, s, align: TextAlign.center), ui.Offset(0, h));
      h += f * 1.16;
    }
    h += 16;
    cv.drawLine(ui.Offset(s / 2 - 110, h), ui.Offset(s / 2 + 110, h), ui.Paint()
      ..color = GColors.maroon
      ..strokeWidth = 2);
    final body = t.body.trim();
    if (body.isNotEmpty && body != title) {
      final st = _uiStyle(size: 34, color: GColors.brown, weight: FontWeight.w600);
      h += 28;
      for (final line in wrapText(body, st, s - 180).take(7)) {
        cv.drawParagraph(_para(line, st, s, align: TextAlign.center), ui.Offset(0, h));
        h += 46;
      }
    }
    cv.drawParagraph(_para('ग्रंथ प्रबंधन', _uiStyle(size: 28, color: GColors.maroon, weight: FontWeight.w700), s, align: TextAlign.center), ui.Offset(0, c - 120));
    final image = await rec.endRecording().toImage(s.toInt(), c.toInt());
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    image.dispose();
    final page = PdfPage(_doc, pageFormat: const PdfPageFormat(_a4w, _a4h));
    if (data == null) {
      final g = page.getGraphics();
      g.setFillColor(const PdfColor(0.965, 0.937, 0.886));
      g.drawRect(0, 0, _a4w, _a4h);
      g.fillPath();
      return;
    }
    final rgba = data.buffer.asUint8List();
    final enc = await compute(_coverJpeg, (rgba: rgba, w: s.toInt(), h: c.toInt()));
    if (enc.jpeg != null) page.getGraphics().drawImage(PdfImage.jpeg(_doc, image: enc.jpeg!), 0, 0, _a4w, _a4h);
    if (first && onPreview != null && enc.preview != null) onPreview!(enc.preview!);
  }

  /// `rh`
  Future<void> _spec(PdfSpec spec, PreparedImage? n, PdfStyle style, bool first) async {
    if (spec.topicCover) return _topicCover(spec, first);
    if (style == PdfStyle.original) {
      if (n == null) return;
      final land = n.w > n.h * 1.05;
      final r = land ? _a4h : _a4w;
      final a = land ? _a4w : _a4h;
      final f = _fit(r - 20, a - 20, n.w, n.h);
      final page = _page(r, a, const Color(0xFFFFFFFF));
      page.getGraphics().drawImage(PdfImage.jpeg(_doc, image: n.bytes), (r - f.w) / 2, (a - f.h) / 2, f.w, f.h);
      await _preview(n, first);
      return;
    }
    await _fill(spec, n, first);
  }

  /// `ch` — build the whole book. Images are prepared by 6 workers ahead of page assembly.
  Future<Uint8List> build(List<PdfSpec> specs, PdfStyle style) async {
    _doc = PdfDocument();
    _font = PdfFont.helvetica(_doc);
    final o = specs.isNotEmpty ? specs : [PdfSpec(title: 'कोई प्रमाण नहीं')];
    final prepared = List<Future<PreparedImage?>?>.filled(o.length, null);
    var next = 0;
    Future<void> worker() async {
      while (next < o.length) {
        if (isCancelled?.call() ?? false) return;
        final i = next++;
        prepared[i] = prepareImage(o[i].image);
        await prepared[i];
      }
    }

    final workers = List.generate(math.min(6, o.length), (_) => worker());
    for (var e = 0; e < o.length; e++) {
      _check();
      while (prepared[e] == null) {
        await Future<void>.delayed(const Duration(milliseconds: 4));
        _check();
      }
      final before = _doc.pdfPageList.pages.length;
      try {
        await _spec(o[e], await prepared[e], style, e == 0);
      } on PdfCancelled {
        rethrow;
      } catch (_) {
        _page(_a4w, _a4h, const Color(0xFFFFFBF3));
      }
      if (style != PdfStyle.original || o[e].topicCover) {
        final pages = _doc.pdfPageList.pages;
        for (var t = before; t < pages.length; t++) {
          _stamp(pages[t], t + 1);
        }
      }
      onPage?.call(e + 1, o.length);
    }
    await Future.wait(workers);
    _check();
    if (_doc.pdfPageList.pages.isEmpty) _page(_a4w, _a4h, const Color(0xFFFFFFFF));
    final bytes = await _doc.save();
    if (bytes.length < 64 || bytes[0] != 37 || bytes[1] != 80 || bytes[2] != 68 || bytes[3] != 70) {
      throw StateError('PDF खाली रह गई');
    }
    return bytes;
  }
}
