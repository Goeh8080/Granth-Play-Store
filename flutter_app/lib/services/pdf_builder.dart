import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:image/image.dart' as img;

import '../theme/colors.dart';
import 'api.dart' show mediaPath;
import 'image_cache.dart';
import 'native_bridge.dart';
import 'pdf_stream.dart';

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
  PdfSpec({required this.title, this.subtitle = '', this.body = '', this.meta = '', this.path, this.cover = false, this.topicCover = false, this.image, this.file});
  final String title;
  final String subtitle;
  final String body;
  final String meta;
  final String? path;
  final bool cover;
  final bool topicCover;

  /// Raw picture bytes, or [file] to read them lazily (keeps big granths out of memory).
  Uint8List? image;
  String? file;

  /// The page should have had a picture but it could not be loaded or decoded. Round 7:
  /// such a page is never drawn (no placeholder); the PDF fails with a clear message.
  bool missing = false;

  /// This page shows a picture (it has a media path, or bytes / a file were given).
  bool get wantsPicture => image != null || file != null || missing || mediaPath(path) != null;
}

class PreparedImage {
  /// [w]/[h] are the picture as shown (after [orientation]); the JPEG itself is untouched.
  PreparedImage(this.bytes, this.w, this.h, {this.orientation = 1}) : png = null, rgba = false;

  /// A PNG's own compressed pixel data, embedded losslessly as it is.
  PreparedImage.png(this.bytes, this.w, this.h, PngLayout this.png) : rgba = false, orientation = 1;

  /// Decoded pixels (RGBA, flattened on white), stored losslessly.
  PreparedImage.rgba(this.bytes, this.w, this.h) : png = null, rgba = true, orientation = 1;

  /// JPEG bytes, unless [png] / [rgba] says otherwise.
  final Uint8List bytes;
  final int w;
  final int h;
  final PngLayout? png;
  final bool rgba;
  final int orientation;

  PdfPicture get picture => rgba ? PdfPicture.rgba(bytes, w, h) : (png != null ? PdfPicture.png(bytes, w, h, png!) : PdfPicture.jpeg(bytes, w, h, orientation: orientation));
}

const double _a4w = 595.28;
const double _a4h = 841.89;

class PdfCancelled implements Exception {}

/// Round 7: a page's picture could not be put into the PDF (not on the phone and not
/// downloadable, or damaged beyond repair). The PDF is NOT finished with a blank page —
/// the job fails with a clear message and can be retried.
class PdfPageFailed implements Exception {
  PdfPageFailed(this.pages, {this.offline = false});

  /// Page numbers (1-based, in the PDF's page list) that are missing.
  final List<int> pages;
  final bool offline;
  @override
  String toString() => 'PdfPageFailed(${pages.length} pages${offline ? ', offline' : ''})';
}

/// Drawing a page did not finish in time (for example the phone stopped the GPU while
/// the app was in the background). The job is retried as a whole once the app is back.
class PdfRenderStalled implements Exception {
  @override
  String toString() => 'PdfRenderStalled';
}

const _renderTimeout = Duration(seconds: 40);

Future<T> _guardRender<T>(Future<T> f) => f.timeout(_renderTimeout, onTimeout: () => throw PdfRenderStalled());

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

/// Round 6 — original quality: page pictures go into the PDF exactly as saved, at their
/// own resolution. Every normal JPEG (any size) is embedded byte for byte (DCTDecode); a
/// PNG without transparency keeps its own compressed pixels (lossless). Only what a PDF
/// reader cannot take directly is converted: transparent PNGs are flattened on white and
/// stored losslessly; other formats (WebP…) become a full-resolution JPEG q95.
/// (Before: anything over 2600 px / 1.5 MB was scaled to 1800 px and re-encoded at q85.)
const kPassBytes = 1500000; // kept for callers; no longer limits pass-through pictures
/// Largest side a converted (non pass-through) picture keeps; bounds decode memory.
const kPdfImageSide = 4096;
const kConvertQuality = 95;

/// Pictures above this many pixels are not decoded in Dart (memory); on Android the
/// native codec converts them.
const kDartDecodeMaxPixels = 24000000;

/// True when a JPEG can go into the PDF unchanged: baseline / extended / progressive,
/// 8-bit, grey / RGB, whole (every segment through the end marker), with its own Huffman
/// tables. CMYK / YCCK (Adobe inverts the ink values — readers disagree), 12-bit,
/// arithmetic-coded or cut-off files are converted (or re-fetched) instead.
bool jpegPassthrough(Uint8List bytes) => _jpegPass(bytes) != null;

/// One header read + one structure scan (the whole-file check) for a JPEG that can be
/// embedded as it is; null when it must be converted (or is damaged).
PreparedImage? _jpegPass(Uint8List bytes) {
  final i = jpegInfo(bytes);
  if (i == null || i.w <= 0 || i.h <= 0 || !(i.sof == 0xC0 || i.sof == 0xC1 || i.sof == 0xC2) || i.precision != 8 || !(i.components == 1 || i.components == 3)) return null;
  final scan = jpegScan(bytes);
  if (scan == null || !scan.complete || !scan.hasHuffman) return null;
  final o = scan.orientation;
  final turned = o >= 5;
  return PreparedImage(bytes, turned ? i.h : i.w, turned ? i.w : i.h, orientation: o);
}

/// The picture as it can be embedded without any decoding, or null. A JPEG with an EXIF
/// rotation is still embedded untouched; it is turned upright by its placement on the page
/// (the app shows it upright too).
PreparedImage? passthrough(Uint8List bytes) {
  if (bytes.length < 32) return null;
  final j = _jpegPass(bytes);
  if (j != null) return j;
  final p = pngPassthrough(bytes);
  if (p != null) return PreparedImage.png(p.idat, p.w, p.h, p.layout);
  return null;
}

/// `Hm`/`Um` — what goes into the PDF for one page picture (see [kConvertQuality]).
/// [maxBytes] is kept for callers and ignored.
PreparedImage? prepareImageSync(Uint8List bytes, [int maxBytes = kPassBytes]) {
  if (bytes.length < 32) return null;
  final pass = passthrough(bytes);
  if (pass != null) return pass;
  // A cut-off / damaged file must never be decoded into a half-grey page: null → re-fetch.
  if (!ImageStore.bytesLookComplete(bytes)) return null;
  final head = imageHeader(bytes);
  // A huge picture would need hundreds of MB to decode in Dart: skip it here (it becomes
  // a placeholder); on Android the native path converts it.
  if (head != null && head.w * head.h > kDartDecodeMaxPixels) return null;
  try {
    var src = img.decodeImage(bytes);
    if (src == null || src.width * src.height > kDartDecodeMaxPixels) return null;
    src = img.bakeOrientation(src); // upright, as the app shows it
    final png = head?.kind == 'png';
    if (src.hasAlpha) {
      final bg = img.Image(width: src.width, height: src.height);
      img.fill(bg, color: img.ColorRgb8(255, 255, 255));
      img.compositeImage(bg, src);
      src = bg;
    }
    if (png) {
      // Lossless (text scans stay sharp): raw pixels, compressed by the PDF writer.
      final rgba = src.convert(format: img.Format.uint8, numChannels: 4, alpha: 255);
      return PreparedImage.rgba(rgba.getBytes(order: img.ChannelOrder.rgba), rgba.width, rgba.height);
    }
    final scale = math.min(1.0, kPdfImageSide / math.max(src.width, src.height));
    final im = scale < 1 ? img.copyResize(src, width: math.max(1, (src.width * scale).round()), height: math.max(1, (src.height * scale).round()), interpolation: img.Interpolation.average) : src;
    return PreparedImage(Uint8List.fromList(img.encodeJpg(im, quality: kConvertQuality)), im.width, im.height);
  } catch (_) {
    return null;
  }
}

/// Pictures that need scaling go to the platform codec on a native worker thread (fast,
/// and big photos are decoded at reduced size). Null = use the Dart path.
Future<PreparedImage?> _prepareNative(File f, Uint8List raw, int maxBytes) async {
  if (!NativeBridge.nativeImages) return null;
  if (passthrough(raw) != null) return null; // embedded as-is
  if (!ImageStore.bytesLookComplete(raw)) return null; // damaged: re-fetched instead
  final head = imageHeader(raw);
  // Transparent PNGs of normal size: the lossless Dart path (keeps text scans sharp).
  if (head?.kind == 'png' && head!.w * head.h <= 12000000) return null;
  final out = '${Directory.systemTemp.path}/granth-prep-${f.hashCode}-${DateTime.now().microsecondsSinceEpoch}.jpg';
  try {
    final r = await NativeBridge.prepareImage(f.path, out, maxSide: kPdfImageSide, quality: kConvertQuality);
    if (r == null) return null;
    return PreparedImage(await File(out).readAsBytes(), r.w, r.h);
  } catch (_) {
    return null;
  } finally {
    try {
      final o = File(out);
      if (await o.exists()) await o.delete();
    } catch (_) {}
  }
}

PreparedImage? _prepareEntry((Uint8List, int) a) => prepareImageSync(a.$1, a.$2);

/// Last resort: Flutter's own image decoder (the one that shows the page in the app, with
/// EXIF rotation) → lossless pixels flattened on white. Null when even that can't read it.
Future<PreparedImage?> prepareWithEngine(Uint8List bytes) async {
  if (!ImageStore.bytesLookComplete(bytes)) return null;
  ui.Codec? codec;
  ui.Image? im;
  try {
    final head = imageHeader(bytes);
    final big = head != null && math.max(head.w, head.h) > kPdfImageSide;
    codec = await ui.instantiateImageCodec(bytes, targetWidth: big && head.w >= head.h ? kPdfImageSide : null, targetHeight: big && head.h > head.w ? kPdfImageSide : null);
    im = (await codec.getNextFrame()).image;
    final data = await im.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
    if (data == null) return null;
    final px = data.buffer.asUint8List();
    for (var i = 0; i < px.length; i += 4) {
      final a = px[i + 3];
      if (a == 255) continue;
      px[i] = (px[i] * a + 255 * (255 - a)) ~/ 255;
      px[i + 1] = (px[i + 1] * a + 255 * (255 - a)) ~/ 255;
      px[i + 2] = (px[i + 2] * a + 255 * (255 - a)) ~/ 255;
      px[i + 3] = 255;
    }
    return PreparedImage.rgba(px, im.width, im.height);
  } catch (_) {
    return null;
  } finally {
    im?.dispose();
    codec?.dispose();
  }
}

/// Round 7 — every page picture that goes into a PDF is checked first: the whole file
/// (structure through the end marker), then on Android a quick reduced-size decode by the
/// phone's own codec. Embedded untouched when possible; otherwise converted (native codec →
/// Dart decoder → Flutter's engine). Null only when nothing can read it.
Future<PreparedImage?> preparePagePicture(Uint8List raw, {String? file, int maxBytes = kPassBytes}) async {
  if (raw.length < 32) return null;
  // Fast path (saved pages): a JPEG/PNG that passes its whole-file structure check is
  // embedded untouched — no decode, no extra work compared with before.
  final pass = passthrough(raw);
  if (pass != null) return pass;
  if (!ImageStore.bytesLookComplete(raw)) return null; // cut off / damaged → re-fetch
  if (file != null) {
    final n = await _prepareNative(File(file), raw, maxBytes);
    if (n != null) return n;
  }
  final r = await compute(_prepareEntry, (raw, maxBytes)).timeout(const Duration(seconds: 60), onTimeout: () => null);
  if (r != null) return r;
  return prepareWithEngine(raw);
}

Future<PreparedImage?> prepareImage(Uint8List? bytes, {int maxBytes = kPassBytes}) async {
  if (bytes == null || bytes.length < 32) return null;
  // Fast path (almost every saved page): embedded as-is, with no decode and no isolate hop.
  final pass = passthrough(bytes);
  if (pass != null) return pass;
  return compute(_prepareEntry, (bytes, maxBytes));
}

/// Small JPEG used as the gallery preview (`sh`): max 720 px on #fffdf7, q82.
Uint8List? previewFromJpegSync(Uint8List bytes) {
  try {
    var im = img.decodeImage(bytes);
    if (im == null) return null;
    im = img.bakeOrientation(im);
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
  final image = await _guardRender(rec.endRecording().toImage(pxW, pxH));
  final data = await _guardRender(image.toByteData(format: ui.ImageByteFormat.rawRgba));
  image.dispose();
  if (data == null) return null;
  return _TextImage(data.buffer.asUint8List(), pxW, pxH, widthPt, pxH / 2);
}

Future<_TextImage?> _textBlock(String text, double widthPt, double size, Color color, FontWeight weight, {Color bg = GColors.paper}) async {
  final t = text.trim();
  if (t.isEmpty) return null;
  return _renderLines([_Line(t, size, color, weight)], widthPt, bg);
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

class BookPdfBuilder {
  BookPdfBuilder({this.isCancelled, this.onPage, this.onPreview, this.repair, this.lookAhead = 8, this.maxImageBytes = kPassBytes, this.maxHeldBytes = 64 << 20});

  /// Round 7: a page picture that fails its checks is handed here once (delete it, download
  /// it again with priority); returns the fresh file, or null when that is impossible now.
  final Future<String?> Function(PdfSpec spec)? repair;

  /// Prepared pictures waiting for their page stay under about this many bytes.
  final int maxHeldBytes;

  /// How many pictures may be prepared ahead of the page being assembled.
  final int lookAhead;

  /// Largest JPEG kept per page picture (see [prepareImageSync]).
  final int maxImageBytes;
  final bool Function()? isCancelled;
  final void Function(int done, int total)? onPage;
  final void Function(Uint8List jpeg)? onPreview;

  final List<PdfPageData> _pending = [];
  int _pageCount = 0;

  void _check() {
    if (isCancelled?.call() ?? false) throw PdfCancelled();
  }

  static PdfPicture _rgbaImage(_TextImage t) => PdfPicture.rgba(t.rgba, t.pxW, t.pxH);

  static void _img(PdfPageData p, PdfPicture pic, double x, double y, double w, double h) =>
      p.ops.add(PdfOp.image(p.addPicture(pic), x, y, w, h, orient: pic.orientation.toDouble()));

  static void _rect(PdfPageData p, double x, double y, double w, double h, Color c, {double alpha = 1}) => p.ops.add(PdfOp.fill(x, y, w, h, c.r, c.g, c.b, alpha: alpha));

  PdfPageData _newPage(double w, double h) {
    final p = PdfPageData(w, h);
    _pending.add(p);
    return p;
  }

  PdfPageData _page(double w, double h, Color fill) {
    final p = _newPage(w, h);
    _rect(p, 0, 0, w, h, fill);
    return p;
  }

  void _stamp(PdfPageData page, int n) {
    final s = '$n';
    final tw = helveticaWidth(s, 11);
    final w = page.w;
    _rect(page, w - tw - 16, 6, tw + 10, 16, const Color(0xFFFFFBF3), alpha: 0.92);
    page.ops.add(PdfOp.text(s, 11, w - tw - 11, 9, 0.482, 0.122, 0.18));
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
    final c = head?.h ?? 0;
    final l = foot?.h ?? 0;
    if (head != null) _img(page, _rgbaImage(head), s0, o - c - 4, s, c);
    if (foot != null) _img(page, _rgbaImage(foot), s0, 20, s, l);
    if (picture != null) {
      final t = c + 8;
      final n = l + 20 + 4;
      final area = math.max(48.0, o - t - n);
      final f = _fit(s, area, picture.w, picture.h);
      final x = s0 + (s - f.w) / 2;
      final y = n + (area - f.h) / 2;
      _rect(page, x - 1, y - 1, f.w + 2, f.h + 2, const Color(0xFF000000));
      _img(page, picture.picture, x, y, f.w, f.h);
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
    if (n == null && spec.wantsPicture) throw PdfPageFailed(const []);
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
    final vignette = ui.Paint()..shader = ui.Gradient.radial(ui.Offset(s / 2, c / 2), c * 0.72, [const Color.fromRGBO(0, 0, 0, 0), const Color.fromRGBO(92, 48, 22, 0.22)], [0.22 / 0.72, 1]);
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
    cv.drawLine(
        ui.Offset(s / 2 - 110, h),
        ui.Offset(s / 2 + 110, h),
        ui.Paint()
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
    final image = await _guardRender(rec.endRecording().toImage(s.toInt(), c.toInt()));
    final data = await _guardRender(image.toByteData(format: ui.ImageByteFormat.rawRgba));
    image.dispose();
    final page = _newPage(_a4w, _a4h);
    if (data == null) throw StateError('cover not drawn'); // retried; never a blank cover
    final rgba = data.buffer.asUint8List();
    final enc = await compute(_coverJpeg, (rgba: rgba, w: s.toInt(), h: c.toInt()));
    if (enc.jpeg == null) throw StateError('cover not encoded');
    _img(page, PdfPicture.jpeg(enc.jpeg!, s.toInt(), c.toInt()), 0, 0, _a4w, _a4h);
    if (first && onPreview != null && enc.preview != null) onPreview!(enc.preview!);
  }

  /// `rh`
  Future<void> _spec(PdfSpec spec, PreparedImage? n, PdfStyle style, bool first) async {
    if (spec.topicCover) return _topicCover(spec, first);
    if (style == PdfStyle.original) {
      if (n == null) {
        // Only pages that never had a picture get here (a missing picture fails the PDF).
        if (spec.wantsPicture) throw PdfPageFailed(const []);
        return;
      }
      final land = n.w > n.h * 1.05;
      final r = land ? _a4h : _a4w;
      final a = land ? _a4w : _a4h;
      final f = _fit(r - 20, a - 20, n.w, n.h);
      final page = _page(r, a, const Color(0xFFFFFFFF));
      _img(page, n.picture, (r - f.w) / 2, (a - f.h) / 2, f.w, f.h);
      await _preview(n, first);
      return;
    }
    await _fill(spec, n, first);
  }

  /// Builds the PDF in memory and returns its bytes (small PDFs and tests).
  Future<Uint8List> build(List<PdfSpec> specs, PdfStyle style) async {
    final dir = await Directory.systemTemp.createTemp('granth-pdf');
    try {
      final path = '${dir.path}/out.pdf';
      await buildToFile(specs, style, path, isolate: false);
      return await File(path).readAsBytes();
    } finally {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// `ch` — build the whole book straight into [path].
  ///
  /// Pictures are prepared by up to 6 workers ahead of page assembly (at most [lookAhead]
  /// pages ahead); each finished page goes to a background writer isolate that compresses
  /// it and appends it to the file, so memory stays flat however big the granth is.
  /// On failure or cancel the partial file is deleted. Returns the file size.
  Future<int> buildToFile(List<PdfSpec> specs, PdfStyle style, String path, {bool isolate = true}) async {
    _pending.clear();
    _pageCount = 0;
    final sink = await PdfSink.open(path, isolate: isolate);
    var ok = false;
    Future<void> lastWrite = Future.value();
    Future<void> flush() async {
      for (final p in _pending) {
        await lastWrite; // one page in flight: drawing the next page overlaps with writing this one
        lastWrite = sink.addPage(p)..ignore();
        _pageCount++;
      }
      _pending.clear();
    }

    try {
      final o = specs.isNotEmpty ? specs : [PdfSpec(title: 'कोई प्रमाण नहीं')];
      final prepared = List<Future<PreparedImage?>?>.filled(o.length, null);
      final held = List<int>.filled(o.length, 0);
      var heldBytes = 0;
      var next = 0;
      var assembled = 0;
      Future<PreparedImage?> once(PdfSpec spec) async {
        try {
          var raw = spec.image;
          if (raw == null && spec.file != null) {
            final f = File(spec.file!);
            if (await f.exists()) raw = await f.readAsBytes();
          }
          if (raw == null) return null;
          return await preparePagePicture(raw, file: spec.image == null ? spec.file : null, maxBytes: maxImageBytes);
        } catch (_) {
          return null;
        }
      }

      Future<PreparedImage?> prep(PdfSpec spec) async {
        if (!spec.wantsPicture) return null;
        var r = await once(spec);
        if (r == null && repair != null && spec.path != null) {
          // Missing or damaged on the phone: fetch it again right now, then check again.
          final fresh = await repair!(spec);
          if (fresh != null) {
            spec
              ..image = null
              ..file = fresh;
            r = await once(spec);
          }
        }
        spec.image = null; // release raw bytes as soon as they are converted
        spec.missing = r == null;
        return r;
      }

      Future<void> worker() async {
        while (next < o.length) {
          if (isCancelled?.call() ?? false) return;
          // Stay at most [lookAhead] pages ahead of assembly so big granths never hold every picture at once.
          // …and within a memory budget: original-size pictures can be several MB each.
          if (next - assembled > lookAhead || (heldBytes > maxHeldBytes && next > assembled)) {
            await Future<void>.delayed(const Duration(milliseconds: 8));
            continue;
          }
          final i = next++;
          prepared[i] = prep(o[i]);
          final r = await prepared[i];
          if (i >= assembled && r != null) {
            held[i] = r.bytes.length;
            heldBytes += held[i];
          }
        }
      }

      final workers = List.generate(math.min(6, o.length), (_) => worker());
      for (var e = 0; e < o.length; e++) {
        _check();
        while (prepared[e] == null) {
          await Future<void>.delayed(const Duration(milliseconds: 4));
          _check();
        }
        _pending.clear();
        final pic = await prepared[e];
        if (o[e].wantsPicture && pic == null) {
          // Never a blank / placeholder page: this PDF is not finished (the job shows why).
          throw PdfPageFailed([e + 1]);
        }
        // A drawing error fails the whole PDF (retried by the queue) — never a blank page.
        await _spec(o[e], pic, style, e == 0);
        if (style != PdfStyle.original || o[e].topicCover) {
          for (var t = 0; t < _pending.length; t++) {
            _stamp(_pending[t], _pageCount + t + 1);
          }
        }
        await flush();
        prepared[e] = Future.value(null); // drop the prepared picture (it now lives in the PDF)
        heldBytes -= held[e];
        held[e] = 0;
        assembled = e + 1;
        onPage?.call(e + 1, o.length);
      }
      await Future.wait(workers);
      _check();
      if (_pageCount == 0) {
        _page(_a4w, _a4h, const Color(0xFFFFFFFF));
        await flush();
      }
      await lastWrite;
      final size = await sink.close();
      final f = File(path);
      final head = await f.openRead(0, 5).fold<List<int>>([], (a, b) => a..addAll(b));
      if (size < 64 || head.length < 4 || head[0] != 37 || head[1] != 80 || head[2] != 68 || head[3] != 70) {
        throw StateError('PDF खाली रह गई');
      }
      ok = true;
      return size;
    } finally {
      _pending.clear();
      if (!ok) await sink.abort();
    }
  }
}
