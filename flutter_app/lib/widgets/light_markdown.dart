/// A tiny markdown renderer for the AI answers and the legal pages. It knows only what those need:
/// `#`/`##`/`###` headings, `-`/`*`/`•` bullets, `1.` numbered items, paragraphs, `**bold**`
/// (and `__bold__`), `` `code` `` (shown plain). No images, no links, no HTML: whatever else the
/// AI writes shows as ordinary text, never as markup.
library;

import 'package:flutter/material.dart';

import '../theme/colors.dart';

enum MdKind { paragraph, heading, bullet, number }

class MdBlock {
  const MdBlock(this.kind, this.text, {this.level = 0, this.number = 0});
  final MdKind kind;
  final String text;
  final int level; // heading level 1..3
  final int number; // 1-based item number
  @override
  String toString() => '$kind($text)';
}

final RegExp _headRe = RegExp(r'^\s{0,3}(#{1,6})\s+(.*)$');
final RegExp _bulletRe = RegExp(r'^\s*[-*•–]\s+(.*)$');
final RegExp _numRe = RegExp(r'^\s*(\d{1,3})[.)]\s+(.*)$');

List<MdBlock> parseMarkdown(String src) {
  final out = <MdBlock>[];
  final para = <String>[];
  void flush() {
    if (para.isNotEmpty) out.add(MdBlock(MdKind.paragraph, para.join('\n')));
    para.clear();
  }

  for (final raw in src.replaceAll('\r\n', '\n').split('\n')) {
    final line = raw.trimRight();
    if (line.trim().isEmpty) {
      flush();
      continue;
    }
    if (RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$').hasMatch(line)) {
      flush();
      continue;
    }
    final h = _headRe.firstMatch(line);
    if (h != null) {
      flush();
      out.add(MdBlock(MdKind.heading, h.group(2)!.replaceAll(RegExp(r'\s*#+\s*$'), '').trim(), level: h.group(1)!.length.clamp(1, 3)));
      continue;
    }
    final b = _bulletRe.firstMatch(line);
    // "**bold** text" starts with * but is not a bullet.
    if (b != null && !line.trimLeft().startsWith('**')) {
      flush();
      out.add(MdBlock(MdKind.bullet, b.group(1)!.trim()));
      continue;
    }
    final n = _numRe.firstMatch(line);
    if (n != null) {
      flush();
      out.add(MdBlock(MdKind.number, n.group(2)!.trim(), number: int.parse(n.group(1)!)));
      continue;
    }
    para.add(line.trim());
  }
  flush();
  return out;
}

final RegExp _boldRe = RegExp(r'\*\*(.+?)\*\*|__(.+?)__', dotAll: true);

/// Inline spans: bold stays bold, a stray `**` / backtick is dropped.
TextSpan inlineSpan(String text, TextStyle base, {TextStyle? bold}) {
  final b = bold ?? base.copyWith(fontWeight: FontWeight.w700, color: GColors.maroon);
  final kids = <InlineSpan>[];
  var i = 0;
  String clean(String s) => s.replaceAll('`', '').replaceAll('**', '');
  for (final m in _boldRe.allMatches(text)) {
    if (m.start > i) kids.add(TextSpan(text: clean(text.substring(i, m.start))));
    kids.add(TextSpan(text: clean(m.group(1) ?? m.group(2)!), style: b));
    i = m.end;
  }
  if (i < text.length) kids.add(TextSpan(text: clean(text.substring(i))));
  return TextSpan(style: base, children: kids);
}

/// The answer as plain text (for copy and share): no markers, bullets as "•".
String markdownPlain(String src) {
  final lines = <String>[];
  for (final b in parseMarkdown(src)) {
    final t = inlineSpan(b.text, const TextStyle()).toPlainText();
    switch (b.kind) {
      case MdKind.bullet:
        lines.add('• $t');
      case MdKind.number:
        lines.add('${b.number}. $t');
      case MdKind.heading:
        lines..add('')..add(t);
      case MdKind.paragraph:
        lines
          ..add('')
          ..add(t);
    }
  }
  return lines.join('\n').trim().replaceAll(RegExp(r'\n{3,}'), '\n\n');
}

/// Blocks on screen. Wrap in a `SelectionArea` to make the text selectable.
class LightMarkdown extends StatelessWidget {
  const LightMarkdown(this.text, {super.key, this.size = 16, this.color = GColors.text, this.height = 1.65});
  final String text;
  final double size;
  final Color color;
  final double height;

  @override
  Widget build(BuildContext context) {
    final base = GText.sans(size: size, color: color, height: height);
    final blocks = parseMarkdown(text);
    final kids = <Widget>[];
    for (var i = 0; i < blocks.length; i++) {
      final b = blocks[i];
      final top = i == 0 ? 0.0 : (b.kind == MdKind.heading ? 12.0 : (b.kind == MdKind.bullet || b.kind == MdKind.number) && blocks[i - 1].kind == b.kind ? 4.0 : 8.0);
      kids.add(Padding(padding: EdgeInsets.only(top: top), child: _block(b, base)));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: kids);
  }

  Widget _block(MdBlock b, TextStyle base) {
    switch (b.kind) {
      case MdKind.heading:
        final s = b.level == 1 ? size + 4 : (b.level == 2 ? size + 2 : size + 0.5);
        return Text.rich(inlineSpan(b.text, GText.sans(size: s, weight: FontWeight.w700, color: GColors.maroon, height: 1.4)));
      case MdKind.bullet:
        return _item('•', b.text, base);
      case MdKind.number:
        return _item('${b.number}.', b.text, base);
      case MdKind.paragraph:
        return Text.rich(inlineSpan(b.text, base));
    }
  }

  Widget _item(String mark, String t, TextStyle base) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: mark.length > 2 ? 30 : 22, child: Text(mark, style: base.copyWith(color: GColors.saffronDark, fontWeight: FontWeight.w700))),
          Expanded(child: Text.rich(inlineSpan(t, base))),
        ],
      );
}
