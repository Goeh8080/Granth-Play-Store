import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'common.dart';
import 'religion_paths.dart';

/// Round 11 — the symbol of each dharm folder, drawn as vectors (no font glyph, no emoji,
/// no asset): the same on every phone, crisp at any size, and tinted from the app palette
/// ([Tone] gradient tile, [toneColors] ink) so it follows every card look.
///
/// Names: `om` (हिन्दू), `crescent` (इस्लाम — चाँद-तारा), `khanda` (सिख), `cross` (ईसाई),
/// `dharma` (बुद्ध — धर्मचक्र), `ektara` (कबीर), `misc` (अन्य — neutral).
const List<String> religionSymbolNames = ['om', 'crescent', 'khanda', 'cross', 'dharma', 'ektara', 'misc'];

/// A rounded gradient tile with the symbol large inside it.
class ReligionSymbol extends StatelessWidget {
  const ReligionSymbol(this.name, {super.key, this.tone = Tone.maroon, this.size = 72});
  final String name;
  final Tone tone;
  final double size;

  @override
  Widget build(BuildContext context) {
    final (colors, ink) = toneColors(tone);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.26),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
        boxShadow: [BoxShadow(color: colors.last.withValues(alpha: 0.28), blurRadius: size * 0.12, offset: Offset(0, size * 0.04))],
      ),
      child: CustomPaint(
        painter: ReligionSymbolPainter(name, ink),
        size: Size.square(size),
      ),
    );
  }
}

class ReligionSymbolPainter extends CustomPainter {
  const ReligionSymbolPainter(this.name, this.ink);
  final String name;
  final Color ink;

  @override
  bool shouldRepaint(ReligionSymbolPainter old) => old.name != name || old.ink != ink;

  static final Map<String, Path> _cache = {};

  /// The tiny SVG path subset the baked outlines use: M L C Q Z (absolute), 0..1000 box.
  static Path parse(String d) {
    final path = Path();
    final t = RegExp(r'([MLCQZ])|(-?\d+(?:\.\d+)?)').allMatches(d).map((m) => m[0]!).toList();
    var i = 0;
    double n() => double.parse(t[i++]);
    while (i < t.length) {
      final c = t[i++];
      switch (c) {
        case 'M':
          path.moveTo(n(), n());
        case 'L':
          path.lineTo(n(), n());
        case 'Q':
          path.quadraticBezierTo(n(), n(), n(), n());
        case 'C':
          path.cubicTo(n(), n(), n(), n(), n(), n());
        case 'Z':
          path.close();
      }
    }
    return path;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.translate((size.width - s) / 2, (size.height - s) / 2);
    canvas.scale(s, s);
    // a soft round "glow" behind the symbol, so it sits in the tile instead of floating
    canvas.drawCircle(const Offset(0.5, 0.5), 0.45, Paint()..color = ink.withValues(alpha: 0.13));
    switch (name) {
      case 'om':
        _glyph(canvas, 'om', kPathOm, 0.68, const Offset(0.5, 0.5));
      case 'khanda':
        _glyph(canvas, 'khanda', kPathKhanda, 0.74, const Offset(0.5, 0.5));
      case 'crescent':
        _crescent(canvas);
      case 'cross':
        _cross(canvas);
      case 'dharma':
        _dharma(canvas);
      case 'ektara':
        _ektara(canvas);
      default:
        _misc(canvas);
    }
    canvas.restore();
  }

  Paint get _fill => Paint()..color = ink..isAntiAlias = true;
  Paint _stroke(double w) => Paint()
    ..color = ink
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  void _glyph(Canvas c, String key, String d, double extent, Offset centre) {
    final p = _cache.putIfAbsent(key, () => parse(d));
    c.save();
    c.translate(centre.dx - extent / 2, centre.dy - extent / 2);
    c.scale(extent / 1000);
    c.drawPath(p, _fill);
    c.restore();
  }

  void _crescent(Canvas c) {
    final moon = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: const Offset(0.44, 0.52), radius: 0.31)),
      Path()..addOval(Rect.fromCircle(center: const Offset(0.545, 0.47), radius: 0.255)),
    );
    c.drawPath(moon, _fill);
    c.drawPath(_star(const Offset(0.665, 0.495), 0.105, -math.pi / 2 + 0.3), _fill);
  }

  Path _star(Offset o, double r, double rot) {
    final p = Path();
    final inner = r * 0.4;
    for (var i = 0; i < 10; i++) {
      final a = rot + i * math.pi / 5;
      final rr = i.isEven ? r : inner;
      final pt = Offset(o.dx + rr * math.cos(a), o.dy + rr * math.sin(a));
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    return p..close();
  }

  void _cross(Canvas c) {
    final v = RRect.fromRectAndRadius(const Rect.fromLTRB(0.435, 0.17, 0.565, 0.84), const Radius.circular(0.035));
    final h = RRect.fromRectAndRadius(const Rect.fromLTRB(0.25, 0.33, 0.75, 0.46), const Radius.circular(0.035));
    c.drawPath(Path.combine(PathOperation.union, Path()..addRRect(v), Path()..addRRect(h)), _fill);
  }

  void _dharma(Canvas c) {
    const o = Offset(0.5, 0.5);
    c.drawCircle(o, 0.335, _stroke(0.055));
    c.drawCircle(o, 0.075, _fill);
    c.drawCircle(o, 0.125, _stroke(0.022));
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      final d = Offset(math.cos(a), math.sin(a));
      c.drawLine(o + d * 0.1, o + d * 0.31, _stroke(0.034));
      // little rim knob between two spokes
      final b = a + math.pi / 8;
      c.drawCircle(o + Offset(math.cos(b), math.sin(b)) * 0.265, 0.02, _fill);
    }
  }

  void _ektara(Canvas c) {
    c.save();
    c.translate(0.5, 0.5);
    c.rotate(0.62);
    c.translate(-0.5, -0.5);
    // gourd body with a sound-hole
    final body = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCenter(center: const Offset(0.5, 0.72), width: 0.36, height: 0.32)),
      Path()..addOval(Rect.fromCircle(center: const Offset(0.5, 0.72), radius: 0.055)),
    );
    c.drawPath(body, _fill);
    // neck, head and the single string beside it
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(0.465, 0.14, 0.51, 0.62), const Radius.circular(0.02)), _fill);
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTRB(0.43, 0.08, 0.57, 0.17), const Radius.circular(0.03)), _fill);
    c.drawLine(const Offset(0.55, 0.15), const Offset(0.55, 0.66), _stroke(0.014));
    c.drawLine(const Offset(0.5, 0.62), const Offset(0.6, 0.62), _stroke(0.026));
    c.restore();
  }

  void _misc(Canvas c) {
    for (var i = 0; i < 4; i++) {
      final x = 0.25 + (i % 2) * 0.275;
      final y = 0.25 + (i ~/ 2) * 0.275;
      final r = Rect.fromLTWH(x, y, 0.225, 0.225);
      c.drawRRect(RRect.fromRectAndRadius(r, Radius.circular(i == 3 ? 0.1125 : 0.05)), _fill);
    }
  }
}
