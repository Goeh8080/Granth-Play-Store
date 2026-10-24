import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// One drawing step on a PDF page. Plain data so it can be sent to the writer isolate.
/// Coordinates are PDF points with the origin at the bottom-left (like the `pdf` package).
class PdfOp {
  const PdfOp.fill(this.x, this.y, this.w, this.h, this.r, this.g, this.b, {this.alpha = 1})
      : kind = 0,
        image = -1,
        text = '',
        size = 0,
        line = 0;
  const PdfOp.stroke(this.x, this.y, this.w, this.h, this.r, this.g, this.b, {this.line = 1})
      : kind = 1,
        image = -1,
        text = '',
        size = 0,
        alpha = 1;
  /// [orient]: EXIF orientation of a JPEG embedded untouched (kept in [size]); the picture
  /// is turned upright on the page by the placement matrix, not by re-encoding.
  const PdfOp.image(this.image, this.x, this.y, this.w, this.h, {double orient = 1})
      : kind = 2,
        r = 0,
        g = 0,
        b = 0,
        text = '',
        size = orient,
        line = 0,
        alpha = 1;

  /// Helvetica text (only ASCII — used for page numbers).
  const PdfOp.text(this.text, this.size, this.x, this.y, this.r, this.g, this.b)
      : kind = 3,
        image = -1,
        w = 0,
        h = 0,
        line = 0,
        alpha = 1;

  final int kind;
  final double x, y, w, h, r, g, b, alpha, size, line;
  final int image;
  final String text;
}

/// A picture placed on a page: an existing JPEG (embedded as-is, no re-encoding), an
/// existing PNG's compressed pixel data (embedded as-is, lossless) or raw RGBA pixels
/// (text rendered with HarfBuzz, flattened PNGs; stored losslessly with Flate).
class PdfPicture {
  const PdfPicture.jpeg(this.bytes, this.w, this.h, {this.orientation = 1})
      : rgba = false,
        png = null;
  const PdfPicture.rgba(this.bytes, this.w, this.h)
      : rgba = true,
        png = null,
        orientation = 1;

  /// [bytes] = the PNG's joined IDAT data (zlib, PNG row filters).
  const PdfPicture.png(this.bytes, this.w, this.h, PngLayout this.png)
      : rgba = false,
        orientation = 1;
  final Uint8List bytes;
  final int w, h;
  final bool rgba;
  final PngLayout? png;

  /// EXIF orientation (1–8) of an untouched JPEG.
  final int orientation;
}

/// How a PNG's pixel data is laid out (what the PDF reader needs to undo the row filters).
class PngLayout {
  const PngLayout({required this.colors, required this.bits, this.palette});

  /// 1 = grey or palette index, 3 = RGB.
  final int colors;
  final int bits;

  /// RGB triples for a palette PNG.
  final Uint8List? palette;
}

/// PNG → [PdfPicture.png] data without decoding: works for non-interlaced grey (1–8 bit),
/// RGB (8 bit) and palette PNGs with no transparency. Null otherwise (alpha, 16 bit,
/// interlaced, damaged): those are decoded and flattened instead.
({int w, int h, Uint8List idat, PngLayout layout})? pngPassthrough(Uint8List b) {
  if (b.length < 45 || b[0] != 0x89 || b[1] != 0x50 || b[2] != 0x4E || b[3] != 0x47) return null;
  int u32(int i) => (b[i] << 24) | (b[i + 1] << 16) | (b[i + 2] << 8) | b[i + 3];
  final w = u32(16), h = u32(20);
  final bits = b[24], type = b[25], interlace = b[28];
  if (w <= 0 || h <= 0 || interlace != 0 || b[26] != 0 || b[27] != 0) return null;
  final okBits = switch (type) {
    0 => bits == 1 || bits == 2 || bits == 4 || bits == 8,
    2 => bits == 8,
    3 => bits == 1 || bits == 2 || bits == 4 || bits == 8,
    _ => false,
  };
  if (!okBits) return null;
  final idat = BytesBuilder(copy: false);
  Uint8List? palette;
  var i = 8;
  var ended = false;
  while (i + 8 <= b.length) {
    final len = u32(i);
    final t = String.fromCharCodes(b, i + 4, i + 8);
    if (len < 0 || i + 12 + len > b.length) return null;
    final data = Uint8List.sublistView(b, i + 8, i + 8 + len);
    if (t == 'IDAT') {
      idat.add(data);
    } else if (t == 'PLTE') {
      palette = Uint8List.fromList(data);
    } else if (t == 'tRNS') {
      return null; // transparency: flatten on white instead
    } else if (t == 'IEND') {
      ended = true;
      break;
    }
    i += 12 + len;
  }
  if (!ended || idat.isEmpty) return null;
  if (type == 3 && (palette == null || palette.isEmpty || palette.length % 3 != 0)) return null;
  final colors = type == 2 ? 3 : 1;
  final data = idat.takeBytes();
  // Round 7: the compressed rows must really unpack to the full picture (every row there,
  // valid row filters) — a damaged PNG is decoded / re-fetched instead of becoming a broken page.
  try {
    final rows = ZLibDecoder().convert(data);
    final stride = 1 + (w * bits * colors + 7) ~/ 8;
    if (rows.length < stride * h) return null;
    for (var r = 0; r < h; r++) {
      if (rows[r * stride] > 4) return null;
    }
  } catch (_) {
    return null;
  }
  return (w: w, h: h, idat: data, layout: PngLayout(colors: colors, bits: bits, palette: type == 3 ? palette : null));
}

class PdfPageData {
  PdfPageData(this.w, this.h);
  final double w, h;
  final List<PdfOp> ops = [];
  final List<PdfPicture> pictures = [];

  int addPicture(PdfPicture p) {
    pictures.add(p);
    return pictures.length - 1;
  }
}

/// Helvetica advance width (1/1000 em) for the characters used in page numbers.
double helveticaWidth(String s, double size) => s.length * 0.556 * size;

/// Minimal PDF 1.4 writer that streams every page straight to disk. Only the page being
/// written is in memory, so a 1,000-page granth needs no more RAM than a 1-page one.
class PdfStreamWriter {
  PdfStreamWriter(String path) : _f = File(path).openSync(mode: FileMode.write) {
    _raw(const [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]); // %PDF-1.4 + binary marker
    _obj(_font, '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>');
    _obj(_gs, '<< /Type /ExtGState /ca 0.92 /CA 0.92 >>');
  }

  static const _catalog = 1, _pages = 2, _font = 3, _gs = 4;
  final RandomAccessFile _f;
  final Map<int, int> _offsets = {};
  final List<int> _kids = [];
  int _pos = 0;
  int _next = 5;
  bool _closed = false;

  int get pageCount => _kids.length;

  void _raw(List<int> b) {
    _f.writeFromSync(b);
    _pos += b.length;
  }

  void _s(String s) => _raw(latin1.encode(s));

  void _obj(int id, String body) {
    _offsets[id] = _pos;
    _s('$id 0 obj\n$body\nendobj\n');
  }

  void _stream(int id, String dict, List<int> data) {
    _offsets[id] = _pos;
    _s('$id 0 obj\n<< $dict /Length ${data.length} >>\nstream\n');
    _raw(data);
    _s('\nendstream\nendobj\n');
  }

  static String _n(double v) {
    final s = v.toStringAsFixed(3);
    var e = s.length;
    while (e > 0 && s[e - 1] == '0') {
      e--;
    }
    if (e > 0 && s[e - 1] == '.') e--;
    final r = s.substring(0, e);
    return r == '-0' || r.isEmpty ? '0' : r;
  }

  static final _deflate = ZLibEncoder(level: 6);

  void addPage(PdfPageData p) {
    if (_closed) throw StateError('closed');
    final names = <String>[];
    for (final pic in p.pictures) {
      final id = _next++;
      names.add('/I${names.length} $id 0 R');
      if (pic.rgba) {
        final n = pic.w * pic.h;
        final rgb = Uint8List(n * 3);
        final src = pic.bytes;
        for (var i = 0, j = 0, k = 0; i < n; i++, j += 4, k += 3) {
          rgb[k] = src[j];
          rgb[k + 1] = src[j + 1];
          rgb[k + 2] = src[j + 2];
        }
        _stream(id, '/Type /XObject /Subtype /Image /Width ${pic.w} /Height ${pic.h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode', _deflate.convert(rgb));
      } else if (pic.png != null) {
        final l = pic.png!;
        final String cs;
        if (l.palette != null) {
          final hex = StringBuffer();
          for (final v in l.palette!) {
            hex.write(v.toRadixString(16).padLeft(2, '0'));
          }
          cs = '[/Indexed /DeviceRGB ${l.palette!.length ~/ 3 - 1} <$hex>]';
        } else {
          cs = l.colors == 3 ? '/DeviceRGB' : '/DeviceGray';
        }
        _stream(id, '/Type /XObject /Subtype /Image /Width ${pic.w} /Height ${pic.h} /ColorSpace $cs /BitsPerComponent ${l.bits} /Filter /FlateDecode /DecodeParms << /Predictor 15 /Colors ${l.colors} /BitsPerComponent ${l.bits} /Columns ${pic.w} >>', pic.bytes);
      } else {
        final info = jpegInfo(pic.bytes);
        final comps = info?.components ?? 3;
        final cs = comps == 1 ? '/DeviceGray' : (comps == 4 ? '/DeviceCMYK /Decode [1 0 1 0 1 0 1 0]' : '/DeviceRGB');
        _stream(id, '/Type /XObject /Subtype /Image /Width ${info?.w ?? pic.w} /Height ${info?.h ?? pic.h} /ColorSpace $cs /BitsPerComponent 8 /Filter /DCTDecode', pic.bytes);
      }
    }
    final c = StringBuffer();
    for (final o in p.ops) {
      switch (o.kind) {
        case 0:
          c.write('q ${o.alpha < 1 ? '/G1 gs ' : ''}${_n(o.r)} ${_n(o.g)} ${_n(o.b)} rg ${_n(o.x)} ${_n(o.y)} ${_n(o.w)} ${_n(o.h)} re f Q\n');
        case 1:
          c.write('q ${_n(o.r)} ${_n(o.g)} ${_n(o.b)} RG ${_n(o.line)} w ${_n(o.x)} ${_n(o.y)} ${_n(o.w)} ${_n(o.h)} re S Q\n');
        case 2:
          if (o.size > 1) {
            final m = orientedMatrix(o.size.round(), o.x, o.y, o.w, o.h);
            c.write('q ${m.map(_n).join(' ')} cm /I${o.image} Do Q\n');
          } else {
            c.write('q ${_n(o.w)} 0 0 ${_n(o.h)} ${_n(o.x)} ${_n(o.y)} cm /I${o.image} Do Q\n');
          }
        case 3:
          final t = o.text.replaceAll(r'\', r'\\').replaceAll('(', r'\(').replaceAll(')', r'\)');
          c.write('q ${_n(o.r)} ${_n(o.g)} ${_n(o.b)} rg BT /F1 ${_n(o.size)} Tf ${_n(o.x)} ${_n(o.y)} Td ($t) Tj ET Q\n');
      }
    }
    final contentId = _next++;
    _stream(contentId, '/Filter /FlateDecode', _deflate.convert(latin1.encode(c.toString())));
    final pageId = _next++;
    _obj(
        pageId,
        '<< /Type /Page /Parent $_pages 0 R /MediaBox [0 0 ${_n(p.w)} ${_n(p.h)}] '
        '/Resources << /XObject << ${names.join(' ')} >> /Font << /F1 $_font 0 R >> /ExtGState << /G1 $_gs 0 R >> >> '
        '/Contents $contentId 0 R >>');
    _kids.add(pageId);
  }

  /// Finishes the file (page tree, catalog, xref) and returns its size in bytes.
  int close() {
    if (_closed) return _pos;
    _obj(_pages, '<< /Type /Pages /Kids [${_kids.map((k) => '$k 0 R').join(' ')}] /Count ${_kids.length} >>');
    _obj(_catalog, '<< /Type /Catalog /Pages $_pages 0 R >>');
    final infoId = _next++;
    _obj(infoId, '<< /Producer (Granth Prabandhan) /Creator (Granth Prabandhan) >>');
    final xref = _pos;
    final b = StringBuffer('xref\n0 $_next\n0000000000 65535 f \n');
    for (var i = 1; i < _next; i++) {
      b.write('${(_offsets[i] ?? 0).toString().padLeft(10, '0')} 00000 n \n');
    }
    b.write('trailer\n<< /Size $_next /Root $_catalog 0 R /Info $infoId 0 R >>\nstartxref\n$xref\n%%EOF\n');
    _s(b.toString());
    _f.flushSync();
    _f.closeSync();
    _closed = true;
    return _pos;
  }

  void abort() {
    if (_closed) return;
    _closed = true;
    try {
      _f.closeSync();
    } catch (_) {}
  }
}

/// Width, height and colour components from a JPEG's SOF marker (null if not a JPEG).
({int w, int h, int components, int sof, int precision})? jpegInfo(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  while (i + 9 < b.length) {
    if (b[i] != 0xFF) {
      i++;
      continue;
    }
    final m = b[i + 1];
    if (m == 0xD8 || m == 0x01 || (m >= 0xD0 && m <= 0xD7) || m == 0xFF) {
      i += m == 0xFF ? 1 : 2;
      continue;
    }
    final len = (b[i + 2] << 8) | b[i + 3];
    if ((m >= 0xC0 && m <= 0xC3) || (m >= 0xC5 && m <= 0xC7) || (m >= 0xC9 && m <= 0xCB) || (m >= 0xCD && m <= 0xCF)) {
      final h = (b[i + 5] << 8) | b[i + 6];
      final w = (b[i + 7] << 8) | b[i + 8];
      return (w: w, h: h, components: b[i + 9], sof: m, precision: b[i + 4]);
    }
    i += 2 + len;
  }
  return null;
}

/// Writes pages on a background isolate: compression and disk IO never touch the UI thread.
/// Falls back to writing on the calling isolate if a worker cannot be started.
class PdfSink {
  PdfSink._();

  Isolate? _iso;
  SendPort? _to;
  ReceivePort? _from;
  PdfStreamWriter? _local;
  final Map<int, Completer<Object?>> _wait = {};
  int _seq = 0;
  late String path;

  static Future<PdfSink> open(String path, {bool isolate = true}) async {
    final s = PdfSink._()..path = path;
    await File(path).parent.create(recursive: true);
    if (isolate) {
      try {
        final from = ReceivePort();
        final ready = Completer<SendPort>();
        from.listen((m) {
          if (m is SendPort) {
            ready.complete(m);
          } else if (m is List && m.length == 3) {
            final c = s._wait.remove(m[0]);
            if (c == null) return;
            m[1] == true ? c.complete(m[2]) : c.completeError(StateError('${m[2]}'));
          }
        });
        s._from = from;
        s._iso = await Isolate.spawn(_worker, from.sendPort, errorsAreFatal: false);
        s._to = await ready.future.timeout(const Duration(seconds: 10));
        await s._call('open', path);
        return s;
      } catch (_) {
        s._kill();
      }
    }
    s._local = PdfStreamWriter(path);
    return s;
  }

  Future<Object?> _call(String cmd, Object? arg) {
    final id = ++_seq;
    final c = Completer<Object?>();
    _wait[id] = c;
    _to!.send([id, cmd, arg]);
    return c.future.timeout(const Duration(seconds: 90));
  }

  Future<void> addPage(PdfPageData p) async {
    if (_local != null) {
      _local!.addPage(p);
      return;
    }
    await _call('page', p);
  }

  /// Completes the file; returns its size.
  Future<int> close() async {
    try {
      if (_local != null) return _local!.close();
      final r = await _call('close', null);
      return r is int ? r : 0;
    } finally {
      _kill();
    }
  }

  /// Stops and deletes the partial file.
  Future<void> abort() async {
    try {
      if (_local != null) {
        _local!.abort();
      } else if (_to != null) {
        await _call('abort', null).timeout(const Duration(seconds: 5));
      }
    } catch (_) {
    } finally {
      _kill();
      try {
        final f = File(path);
        if (await f.exists()) await f.delete();
      } catch (_) {}
    }
  }

  void _kill() {
    _iso?.kill(priority: Isolate.immediate);
    _iso = null;
    _from?.close();
    _from = null;
    for (final c in _wait.values) {
      if (!c.isCompleted) c.completeError(StateError('writer stopped'));
    }
    _wait.clear();
  }

  static void _worker(SendPort out) {
    final inbox = ReceivePort();
    out.send(inbox.sendPort);
    PdfStreamWriter? w;
    inbox.listen((m) {
      final l = m as List;
      final id = l[0];
      try {
        switch (l[1]) {
          case 'open':
            w = PdfStreamWriter(l[2] as String);
            out.send([id, true, null]);
          case 'page':
            w!.addPage(l[2] as PdfPageData);
            out.send([id, true, null]);
          case 'close':
            final n = w!.close();
            out.send([id, true, n]);
            inbox.close();
          case 'abort':
            w?.abort();
            out.send([id, true, null]);
            inbox.close();
        }
      } catch (e) {
        out.send([id, false, '$e']);
      }
    });
  }
}

/// Round 7 — one pass over a JPEG's whole structure (no pixel decoding): every marker
/// segment fits, the entropy-coded scans contain only valid escapes, and the file reaches
/// its end marker. Also reports what matters for embedding it untouched in a PDF.
class JpegScan {
  const JpegScan({required this.complete, required this.hasHuffman, required this.orientation, required this.adobe});

  /// Structure is whole: SOI … SOF … SOS (scan data) … EOI, nothing cut off.
  final bool complete;

  /// Has its own Huffman tables (a few camera / video JPEGs rely on implicit ones).
  final bool hasHuffman;

  /// EXIF orientation 1–8 (1 = upright / none).
  final int orientation;

  /// Adobe APP14 marker present (CMYK files from Photoshop store inverted ink values).
  final bool adobe;
}

JpegScan? jpegScan(Uint8List b) {
  if (b.length < 4 || b[0] != 0xFF || b[1] != 0xD8) return null;
  var i = 2;
  var sof = false;
  var sos = false;
  var dht = false;
  var adobe = false;
  var orientation = 1;
  final n = b.length;
  while (i < n) {
    if (b[i] != 0xFF) return JpegScan(complete: false, hasHuffman: dht, orientation: orientation, adobe: adobe);
    // fill bytes
    while (i < n && b[i] == 0xFF) {
      i++;
    }
    if (i >= n) break;
    final m = b[i];
    i++;
    if (m == 0xD9) return JpegScan(complete: sof && sos, hasHuffman: dht, orientation: orientation, adobe: adobe);
    if (m == 0x01 || (m >= 0xD0 && m <= 0xD7)) continue;
    if (m == 0xD8 || m == 0x00) break;
    if (i + 2 > n) break;
    final len = (b[i] << 8) | b[i + 1];
    if (len < 2 || i + len > n) break;
    final seg = i + 2;
    if ((m >= 0xC0 && m <= 0xCF) && m != 0xC4 && m != 0xC8 && m != 0xCC) sof = true;
    if (m == 0xC4) dht = true;
    if (m == 0xEE && len >= 7 && b[seg] == 0x41 && b[seg + 1] == 0x64 && b[seg + 2] == 0x6F && b[seg + 3] == 0x62 && b[seg + 4] == 0x65) adobe = true;
    if (m == 0xE1 && len > 16) orientation = _exifOrientation(b, seg, i + len) ?? orientation;
    i += len;
    if (m == 0xDA) {
      if (!sof) break;
      sos = true;
      // Entropy-coded data: runs until the next real marker.
      var j = i;
      var found = false;
      while (j + 1 < n) {
        if (b[j] != 0xFF) {
          j++;
          continue;
        }
        final x = b[j + 1];
        if (x == 0x00 || (x >= 0xD0 && x <= 0xD7)) {
          j += 2;
          continue;
        }
        if (x == 0xFF) {
          j++;
          continue;
        }
        found = true;
        break;
      }
      if (!found) break; // cut off inside the picture data
      i = j;
    }
  }
  return JpegScan(complete: false, hasHuffman: dht, orientation: orientation, adobe: adobe);
}

/// Orientation tag (0x0112) from an APP1 "Exif" segment [from, to).
int? _exifOrientation(Uint8List b, int from, int to) {
  if (to - from < 14 || b[from] != 0x45 || b[from + 1] != 0x78 || b[from + 2] != 0x69 || b[from + 3] != 0x66) return null;
  final t = from + 6; // TIFF header
  final le = b[t] == 0x49 && b[t + 1] == 0x49;
  if (!le && !(b[t] == 0x4D && b[t + 1] == 0x4D)) return null;
  int u16(int o) => o + 2 > to ? -1 : (le ? b[o] | (b[o + 1] << 8) : (b[o] << 8) | b[o + 1]);
  int u32(int o) => o + 4 > to ? -1 : (le ? b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24) : (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3]);
  final ifd = u32(t + 4);
  if (ifd < 8) return null;
  final count = u16(t + ifd);
  if (count < 0 || count > 200) return null;
  for (var k = 0; k < count; k++) {
    final e = t + ifd + 2 + k * 12;
    if (e + 12 > to) return null;
    if (u16(e) == 0x0112) {
      final v = u16(e + 8);
      return v >= 1 && v <= 8 ? v : null;
    }
  }
  return null;
}

/// True when the JPEG is whole (see [jpegScan]).
bool jpegComplete(Uint8List b) => jpegScan(b)?.complete ?? false;

/// Placement of a stored picture turned upright by EXIF [orientation] inside the box
/// (x, y, w, h) on the page (PDF coordinates, y up). Returns the `cm` matrix a b c d e f
/// that maps the image's unit square there.
List<double> orientedMatrix(int orientation, double x, double y, double w, double h) {
  // Stored pixel (s, t) — s left→right, t top→bottom, both 0…1 — appears at display
  // position (X, Y) (top-left origin) according to EXIF.
  (double, double) disp(double s, double t) => switch (orientation) {
        2 => (1 - s, t),
        3 => (1 - s, 1 - t),
        4 => (s, 1 - t),
        5 => (t, s),
        6 => (1 - t, s),
        7 => (1 - t, 1 - s),
        8 => (t, 1 - s),
        _ => (s, t),
      };
  // PDF image space: u = s, v = 1 − t (row 0 at the top).
  (double, double) page(double u, double v) {
    final (X, Y) = disp(u, 1 - v);
    return (x + w * X, y + h * (1 - Y));
  }

  final o = page(0, 0);
  final pu = page(1, 0);
  final pv = page(0, 1);
  return [pu.$1 - o.$1, pu.$2 - o.$2, pv.$1 - o.$1, pv.$2 - o.$2, o.$1, o.$2];
}
