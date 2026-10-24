import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Round 10 — the small coloured icons of the granth groups (omma's look: a rounded cream
/// tile with a little illustration). Drawn here with [CustomPainter], so they are crisp at
/// any size, follow no theme on purpose, and add nothing to the APK.
///
/// Names: `scroll` (वेद, मनुस्मृति), `book-red` (गीता), `book-green` (पुराण),
/// `book-blue` (उपनिषद), `book-orange` (रामायण), `swords` (महाभारत), `books` (6 शास्त्र),
/// `quran`, `hadees`, `granth-sahib`, `dasam`, `bible`, `tripitak`, `dhammapad`,
/// `kabir-sagar`, `bijak`, `shabdavali`, `misc` (अन्य).
const List<String> groupIconNames = [
  'scroll', 'book-red', 'book-green', 'book-blue', 'book-orange', 'swords', 'books', 'quran', 'hadees',
  'granth-sahib', 'dasam', 'bible', 'tripitak', 'dhammapad', 'kabir-sagar', 'bijak', 'shabdavali', 'misc',
];

class GroupIcon extends StatelessWidget {
  const GroupIcon(this.name, {super.key, this.size = 56});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: GroupIconPainter(name)),
      );
}

const _ink = Color(0xFF5A3A1A);
const _gold = Color(0xFFD9A233);
const _goldDark = Color(0xFFB07A14);
const _page = Color(0xFFFCF4E4);

class GroupIconPainter extends CustomPainter {
  const GroupIconPainter(this.name);
  final String name;

  @override
  bool shouldRepaint(GroupIconPainter old) => old.name != name;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide;
    canvas.save();
    canvas.scale(s, s);
    _tile(canvas);
    switch (name) {
      case 'scroll':
        _scroll(canvas);
      case 'book-red':
        _book(canvas, const Color(0xFFD93A45), emblem: _lines);
      case 'book-green':
        _book(canvas, const Color(0xFF2E9F5B), emblem: _lines);
      case 'book-blue':
        _book(canvas, const Color(0xFF3B73D9), emblem: _lines);
      case 'book-orange':
        _book(canvas, const Color(0xFFEE8A24), emblem: _lines);
      case 'swords':
        _swords(canvas);
      case 'books':
        _stack(canvas);
      case 'quran':
        _book(canvas, const Color(0xFF1F7A4D), emblem: _crescent);
      case 'hadees':
        _openBook(canvas);
      case 'granth-sahib':
        _book(canvas, const Color(0xFF2F58B8), emblem: _ring, trim: true);
      case 'dasam':
        _book(canvas, const Color(0xFF8C2B3A), emblem: _sword, trim: true);
      case 'bible':
        _book(canvas, const Color(0xFF2B2F4A), emblem: _cross);
      case 'tripitak':
        _pothi(canvas);
      case 'dhammapad':
        _book(canvas, const Color(0xFFE5871C), emblem: _wheel);
      case 'kabir-sagar':
        _book(canvas, const Color(0xFF1C7C8C), emblem: _waves);
      case 'bijak':
        _book(canvas, const Color(0xFF8A5A2C), emblem: _sprout);
      case 'shabdavali':
        _book(canvas, const Color(0xFF7B4FB0), emblem: _words);
      default:
        _folder(canvas);
    }
    canvas.restore();
  }

  // ---- the tile ----------------------------------------------------------------------
  void _tile(Canvas c) {
    final r = RRect.fromRectAndRadius(const Rect.fromLTWH(0.02, 0.02, 0.96, 0.96), const Radius.circular(0.27));
    c.drawRRect(r.shift(const Offset(0, 0.025)), Paint()..color = const Color(0x1F8A5A1E)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.03));
    c.drawRRect(
      r,
      Paint()
        ..shader = const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [Color(0xFFFFF8EC), Color(0xFFFAE6CB)]).createShader(const Rect.fromLTWH(0, 0, 1, 1)),
    );
    c.drawRRect(r, Paint()..style = PaintingStyle.stroke..strokeWidth = 0.012..color = const Color(0xFFEBD2AE));
  }

  Paint _fill(Color col) => Paint()..color = col..isAntiAlias = true;
  Paint _line(Color col, double w) => Paint()
    ..color = col
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..isAntiAlias = true;

  Color _shade(Color c, double by) {
    final h = HSLColor.fromColor(c);
    return h.withLightness((h.lightness + by).clamp(0.0, 1.0)).toColor();
  }

  // ---- shapes ------------------------------------------------------------------------
  void _scroll(Canvas c) {
    // paper
    final paper = RRect.fromRectAndRadius(const Rect.fromLTWH(0.29, 0.2, 0.42, 0.6), const Radius.circular(0.02));
    c.drawRRect(paper, _fill(const Color(0xFFF7E3B4)));
    c.drawRRect(paper, _line(const Color(0xFFD9B46A), 0.012));
    for (var i = 0; i < 4; i++) {
      final y = 0.34 + i * 0.1;
      c.drawLine(Offset(0.36, y), Offset(i.isOdd ? 0.58 : 0.64, y), _line(const Color(0xFFB07A2A), 0.022));
    }
    // two rolls
    for (final y in [0.13, 0.73]) {
      final roll = RRect.fromRectAndRadius(Rect.fromLTWH(0.22, y, 0.56, 0.12), const Radius.circular(0.06));
      c.drawRRect(
        roll,
        Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFEBB94A), Color(0xFFC98A1C)]).createShader(roll.outerRect),
      );
      c.drawOval(Rect.fromLTWH(0.2, y + 0.01, 0.07, 0.10), _fill(const Color(0xFFA86F12)));
      c.drawOval(Rect.fromLTWH(0.73, y + 0.01, 0.07, 0.10), _fill(const Color(0xFFA86F12)));
      c.drawCircle(Offset(0.235, y + 0.06), 0.014, _fill(const Color(0xFFF3D88F)));
      c.drawCircle(Offset(0.765, y + 0.06), 0.014, _fill(const Color(0xFFF3D88F)));
    }
  }

  void _book(Canvas c, Color color, {void Function(Canvas, Color)? emblem, bool trim = false}) {
    // pages (peek out right and bottom)
    final pages = RRect.fromRectAndRadius(const Rect.fromLTWH(0.27, 0.17, 0.57, 0.72), const Radius.circular(0.04));
    c.drawRRect(pages, _fill(_page));
    c.drawRRect(pages, _line(const Color(0xFFE2CFA6), 0.01));
    c.drawLine(const Offset(0.82, 0.24), const Offset(0.82, 0.82), _line(const Color(0xFFE2CFA6), 0.01));
    final cover = RRect.fromRectAndRadius(const Rect.fromLTWH(0.19, 0.11, 0.58, 0.72), const Radius.circular(0.05));
    c.drawRRect(
      cover,
      Paint()..shader = LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [_shade(color, 0.07), _shade(color, -0.05)]).createShader(cover.outerRect),
    );
    // spine
    final spine = RRect.fromRectAndCorners(const Rect.fromLTWH(0.19, 0.11, 0.1, 0.72), topLeft: const Radius.circular(0.05), bottomLeft: const Radius.circular(0.05));
    c.drawRRect(spine, _fill(_shade(color, -0.14)));
    c.drawLine(const Offset(0.31, 0.15), const Offset(0.31, 0.79), _line(_shade(color, 0.16).withValues(alpha: 0.55), 0.01));
    // bookmark ribbon
    final ribbon = Path()
      ..moveTo(0.62, 0.11)
      ..lineTo(0.62, 0.27)
      ..lineTo(0.655, 0.235)
      ..lineTo(0.69, 0.27)
      ..lineTo(0.69, 0.11)
      ..close();
    c.drawPath(ribbon, _fill(_gold));
    if (trim) {
      for (final (x, y, dx, dy) in [(0.34, 0.17, 1.0, 1.0), (0.72, 0.17, -1.0, 1.0), (0.34, 0.77, 1.0, -1.0), (0.72, 0.77, -1.0, -1.0)]) {
        c.drawPath(
          Path()
            ..moveTo(x, y + dy * 0.06)
            ..lineTo(x, y)
            ..lineTo(x + dx * 0.06, y),
          _line(_gold, 0.014),
        );
      }
    }
    emblem?.call(c, color);
  }

  // emblems sit on the cover, inside (0.34..0.70, 0.30..0.70)
  void _lines(Canvas c, Color color) {
    final p = _line(Colors.white.withValues(alpha: 0.9), 0.024);
    c.drawLine(const Offset(0.37, 0.4), const Offset(0.68, 0.4), p);
    c.drawLine(const Offset(0.37, 0.5), const Offset(0.62, 0.5), p);
    c.drawLine(const Offset(0.37, 0.6), const Offset(0.66, 0.6), p);
    c.drawCircle(const Offset(0.5, 0.71), 0.018, _fill(_gold));
  }

  void _words(Canvas c, Color color) {
    final p = _line(Colors.white.withValues(alpha: 0.92), 0.026);
    c.drawLine(const Offset(0.37, 0.38), const Offset(0.5, 0.38), p);
    c.drawLine(const Offset(0.56, 0.38), const Offset(0.68, 0.38), p);
    c.drawLine(const Offset(0.37, 0.49), const Offset(0.46, 0.49), p);
    c.drawLine(const Offset(0.52, 0.49), const Offset(0.68, 0.49), p);
    c.drawLine(const Offset(0.37, 0.6), const Offset(0.6, 0.6), p);
    c.drawCircle(const Offset(0.5, 0.71), 0.018, _fill(_gold));
  }

  void _crescent(Canvas c, Color color) {
    final moon = Path.combine(
      PathOperation.difference,
      Path()..addOval(Rect.fromCircle(center: const Offset(0.5, 0.47), radius: 0.15)),
      Path()..addOval(Rect.fromCircle(center: const Offset(0.555, 0.43), radius: 0.125)),
    );
    c.drawPath(moon, _fill(_gold));
    _star(c, const Offset(0.6, 0.46), 0.045, _gold);
  }

  void _star(Canvas c, Offset o, double r, Color col) {
    final p = Path();
    for (var i = 0; i < 10; i++) {
      final rad = i.isEven ? r : r * 0.42;
      final a = -math.pi / 2 + i * math.pi / 5;
      final pt = Offset(o.dx + rad * math.cos(a), o.dy + rad * math.sin(a));
      i == 0 ? p.moveTo(pt.dx, pt.dy) : p.lineTo(pt.dx, pt.dy);
    }
    c.drawPath(p..close(), _fill(col));
  }

  void _ring(Canvas c, Color color) {
    c.drawCircle(const Offset(0.48, 0.47), 0.14, _line(_gold, 0.026));
    c.drawCircle(const Offset(0.48, 0.47), 0.05, _fill(_gold));
    c.drawLine(const Offset(0.37, 0.7), const Offset(0.59, 0.7), _line(_gold, 0.018));
  }

  void _sword(Canvas c, Color color) {
    c.save();
    c.translate(0.48, 0.47);
    c.rotate(math.pi / 5);
    final blade = Path()
      ..moveTo(0, -0.2)
      ..lineTo(0.032, -0.16)
      ..lineTo(0.032, 0.08)
      ..lineTo(-0.032, 0.08)
      ..lineTo(-0.032, -0.16)
      ..close();
    c.drawPath(blade, _fill(const Color(0xFFE6EAF0)));
    c.drawLine(const Offset(0, -0.16), const Offset(0, 0.07), _line(const Color(0xFFAAB3C0), 0.01));
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-0.08, 0.08, 0.16, 0.026), const Radius.circular(0.012)), _fill(_gold));
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-0.014, 0.106, 0.028, 0.075), const Radius.circular(0.01)), _fill(_gold));
    c.restore();
  }

  void _cross(Canvas c, Color color) {
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.455, 0.27, 0.07, 0.34), const Radius.circular(0.012)), _fill(_gold));
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.38, 0.35, 0.22, 0.07), const Radius.circular(0.012)), _fill(_gold));
    c.drawLine(const Offset(0.38, 0.71), const Offset(0.6, 0.71), _line(_gold, 0.016));
  }

  void _wheel(Canvas c, Color color) {
    const o = Offset(0.48, 0.47);
    c.drawCircle(o, 0.15, _line(const Color(0xFFFFE08A), 0.024));
    c.drawCircle(o, 0.03, _fill(const Color(0xFFFFE08A)));
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4;
      c.drawLine(Offset(o.dx + 0.035 * math.cos(a), o.dy + 0.035 * math.sin(a)), Offset(o.dx + 0.14 * math.cos(a), o.dy + 0.14 * math.sin(a)), _line(const Color(0xFFFFE08A), 0.016));
    }
  }

  void _waves(Canvas c, Color color) {
    final p = _line(Colors.white.withValues(alpha: 0.92), 0.024);
    for (final y in [0.4, 0.51, 0.62]) {
      final path = Path()..moveTo(0.36, y);
      path.quadraticBezierTo(0.42, y - 0.055, 0.48, y);
      path.quadraticBezierTo(0.54, y + 0.055, 0.6, y);
      path.quadraticBezierTo(0.63, y - 0.03, 0.67, y - 0.012);
      c.drawPath(path, p);
    }
  }

  void _sprout(Canvas c, Color color) {
    c.drawLine(const Offset(0.5, 0.68), const Offset(0.5, 0.45), _line(const Color(0xFF9BE08A), 0.026));
    final left = Path()
      ..moveTo(0.5, 0.52)
      ..quadraticBezierTo(0.36, 0.5, 0.36, 0.36)
      ..quadraticBezierTo(0.5, 0.36, 0.5, 0.52);
    final right = Path()
      ..moveTo(0.5, 0.46)
      ..quadraticBezierTo(0.5, 0.31, 0.64, 0.3)
      ..quadraticBezierTo(0.66, 0.44, 0.5, 0.46);
    c.drawPath(left, _fill(const Color(0xFF8FE07C)));
    c.drawPath(right, _fill(const Color(0xFFB4EE9B)));
  }

  void _swords(Canvas c) {
    for (final a in [-math.pi / 4.2, math.pi / 4.2]) {
      c.save();
      c.translate(0.5, 0.5);
      c.rotate(a);
      c.scale(1.12);
      final blade = Path()
        ..moveTo(0, -0.37)
        ..lineTo(0.045, -0.3)
        ..lineTo(0.045, 0.1)
        ..lineTo(-0.045, 0.1)
        ..lineTo(-0.045, -0.3)
        ..close();
      c.drawPath(blade, _fill(const Color(0xFFD5DAE2)));
      c.drawPath(
        Path()
          ..moveTo(0, -0.37)
          ..lineTo(0.045, -0.3)
          ..lineTo(0.045, 0.1)
          ..lineTo(0, 0.1)
          ..close(),
        _fill(const Color(0xFFB1B9C6)),
      );
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-0.12, 0.1, 0.24, 0.04), const Radius.circular(0.02)), _fill(_gold));
      c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(-0.02, 0.14, 0.04, 0.12), const Radius.circular(0.015)), _fill(const Color(0xFF7A4A22)));
      c.drawCircle(const Offset(0, 0.285), 0.033, _fill(_goldDark));
      c.restore();
    }
  }

  void _stack(Canvas c) {
    const cols = [Color(0xFF3B73D9), Color(0xFF2E9F5B), Color(0xFFD93A45)];
    const ys = [0.2, 0.41, 0.62];
    const xs = [0.2, 0.27, 0.18];
    for (var i = 0; i < 3; i++) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(xs[i], ys[i], 0.58, 0.19), const Radius.circular(0.035));
      c.drawRRect(r, _fill(_page));
      final cover = RRect.fromRectAndCorners(Rect.fromLTWH(xs[i], ys[i], 0.5, 0.19), topLeft: const Radius.circular(0.035), bottomLeft: const Radius.circular(0.035), topRight: const Radius.circular(0.01), bottomRight: const Radius.circular(0.01));
      c.drawRRect(cover, _fill(cols[i]));
      c.drawLine(Offset(xs[i] + 0.06, ys[i] + 0.04), Offset(xs[i] + 0.06, ys[i] + 0.15), _line(_gold, 0.016));
      c.drawLine(Offset(xs[i] + 0.12, ys[i] + 0.095), Offset(xs[i] + 0.4, ys[i] + 0.095), _line(Colors.white.withValues(alpha: 0.7), 0.016));
      c.drawLine(Offset(xs[i] + 0.52, ys[i] + 0.04), Offset(xs[i] + 0.52, ys[i] + 0.15), _line(const Color(0xFFE2CFA6), 0.008));
    }
  }

  void _openBook(Canvas c) {
    c.drawRRect(RRect.fromRectAndRadius(const Rect.fromLTWH(0.12, 0.3, 0.76, 0.5), const Radius.circular(0.05)), _fill(const Color(0xFF1C8C86)));
    final left = Path()
      ..moveTo(0.5, 0.3)
      ..quadraticBezierTo(0.33, 0.2, 0.16, 0.26)
      ..lineTo(0.16, 0.72)
      ..quadraticBezierTo(0.33, 0.66, 0.5, 0.76)
      ..close();
    final right = Path()
      ..moveTo(0.5, 0.3)
      ..quadraticBezierTo(0.67, 0.2, 0.84, 0.26)
      ..lineTo(0.84, 0.72)
      ..quadraticBezierTo(0.67, 0.66, 0.5, 0.76)
      ..close();
    c.drawPath(left, _fill(_page));
    c.drawPath(right, _fill(const Color(0xFFF6EBD2)));
    c.drawLine(const Offset(0.5, 0.3), const Offset(0.5, 0.76), _line(const Color(0xFFD7C292), 0.012));
    final p = _line(const Color(0xFF1C8C86).withValues(alpha: 0.75), 0.018);
    for (final y in [0.37, 0.46, 0.55]) {
      c.drawLine(Offset(0.23, y), Offset(0.43, y + 0.015), p);
      c.drawLine(Offset(0.57, y + 0.015), Offset(0.77, y), p);
    }
  }

  void _pothi(Canvas c) {
    const cols = [Color(0xFFE9C474), Color(0xFFDDB05A), Color(0xFFE9C474), Color(0xFFDDB05A)];
    for (var i = 0; i < 4; i++) {
      final r = RRect.fromRectAndRadius(Rect.fromLTWH(0.12, 0.2 + i * 0.15, 0.76, 0.12), const Radius.circular(0.03));
      c.drawRRect(r, _fill(cols[i]));
      c.drawRRect(r, _line(const Color(0xFFB98A2E), 0.008));
      c.drawLine(Offset(0.2, 0.26 + i * 0.15), Offset(0.78, 0.26 + i * 0.15), _line(const Color(0xFFB98A2E).withValues(alpha: 0.55), 0.01));
    }
    for (final x in [0.3, 0.7]) {
      c.drawLine(Offset(x, 0.16), Offset(x, 0.84), _line(const Color(0xFFC0392B), 0.016));
      c.drawCircle(Offset(x, 0.16), 0.022, _fill(const Color(0xFFC0392B)));
    }
  }

  void _folder(Canvas c) {
    final back = Path()
      ..moveTo(0.14, 0.3)
      ..quadraticBezierTo(0.14, 0.24, 0.2, 0.24)
      ..lineTo(0.4, 0.24)
      ..lineTo(0.47, 0.32)
      ..lineTo(0.8, 0.32)
      ..quadraticBezierTo(0.86, 0.32, 0.86, 0.38)
      ..lineTo(0.86, 0.7)
      ..quadraticBezierTo(0.86, 0.76, 0.8, 0.76)
      ..lineTo(0.2, 0.76)
      ..quadraticBezierTo(0.14, 0.76, 0.14, 0.7)
      ..close();
    c.drawPath(back, _fill(const Color(0xFFD2A262)));
    final front = RRect.fromRectAndRadius(const Rect.fromLTWH(0.12, 0.4, 0.76, 0.38), const Radius.circular(0.05));
    c.drawRRect(
      front,
      Paint()..shader = const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFFF0CD92), Color(0xFFE2B26C)]).createShader(front.outerRect),
    );
    for (final x in [0.4, 0.5, 0.6]) {
      c.drawCircle(Offset(x, 0.6), 0.02, _fill(_ink.withValues(alpha: 0.65)));
    }
  }
}
