/// "Card PDF" (round 14): the card exactly as it looks in the app — the widget under a
/// [RepaintBoundary] is drawn to a picture, put on a white page and written as a one-page PDF
/// with the app's own PDF writer. Everything stays on the phone (temp file → share / save).
library;

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'file_actions.dart';
import 'pdf_stream.dart';

class CardPdf {
  /// Page margin around the card, in PDF points.
  static const double margin = 18;

  /// Draws the boundary under [key] and writes `<dir>/<name>`. Returns the file, or null when the
  /// card is not on screen.
  static Future<File?> build(GlobalKey key, String name, {double pixelRatio = 3, Directory? dir}) async {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary || !ro.hasSize) return null;
    final shot = await ro.toImage(pixelRatio: pixelRatio);
    final w = shot.width, h = shot.height;
    // Flatten onto white (the card's rounded corners are transparent).
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()), Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawImage(shot, Offset.zero, Paint());
    final flat = await rec.endRecording().toImage(w, h);
    shot.dispose();
    final data = await flat.toByteData(format: ui.ImageByteFormat.rawRgba);
    flat.dispose();
    if (data == null) return null;
    final out = dir ?? await getTemporaryDirectory();
    final f = File('${out.path}/$name');
    // 1 logical pixel = 1 pt, so the card prints at its on-screen size.
    final cw = w / pixelRatio, ch = h / pixelRatio;
    final page = PdfPageData(cw + margin * 2, ch + margin * 2);
    page.ops.add(PdfOp.fill(0, 0, page.w, page.h, 1, 1, 1));
    final i = page.addPicture(PdfPicture.rgba(data.buffer.asUint8List(), w, h));
    page.ops.add(PdfOp.image(i, margin, margin, cw, ch));
    final pdf = PdfStreamWriter(f.path);
    try {
      pdf.addPage(page);
      pdf.close();
    } catch (_) {
      pdf.abort();
      rethrow;
    }
    return f;
  }

  static String fileName(String title) {
    final t = title.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]+'), ' ').trim();
    final short = t.runes.length > 40 ? String.fromCharCodes(t.runes.take(40)).trim() : t;
    return '${short.isEmpty ? 'card' : short}.pdf';
  }

  static Future<void> share(File f) => FileActions.shareFile(f.path, f.uri.pathSegments.last);
  static Future<bool> save(File f) => FileActions.exportToDevice(f.path, f.uri.pathSegments.last);
}
