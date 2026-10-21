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
  const PdfOp.image(this.image, this.x, this.y, this.w, this.h)
      : kind = 2,
        r = 0,
        g = 0,
        b = 0,
        text = '',
        size = 0,
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

/// A picture placed on a page: an existing JPEG (embedded as-is, no re-encoding) or raw
/// RGBA pixels (text rendered with HarfBuzz; stored losslessly with Flate).
class PdfPicture {
  const PdfPicture.jpeg(this.bytes, this.w, this.h) : rgba = false;
  const PdfPicture.rgba(this.bytes, this.w, this.h) : rgba = true;
  final Uint8List bytes;
  final int w, h;
  final bool rgba;
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
          c.write('q ${_n(o.w)} 0 0 ${_n(o.h)} ${_n(o.x)} ${_n(o.y)} cm /I${o.image} Do Q\n');
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
({int w, int h, int components})? jpegInfo(Uint8List b) {
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
      return (w: w, h: h, components: b[i + 9]);
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
