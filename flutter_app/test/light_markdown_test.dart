import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/widgets/light_markdown.dart';

void main() {
  test('blocks: headings, bullets, numbers, paragraphs', () {
    final b = parseMarkdown('## शीर्षक\n\nपहली पंक्ति\nदूसरी पंक्ति\n\n- एक\n* दो\n• तीन\n\n1. पहला\n2) दूसरा\n\n**मोटा** शुरू');
    expect(b.map((e) => e.kind), [MdKind.heading, MdKind.paragraph, MdKind.bullet, MdKind.bullet, MdKind.bullet, MdKind.number, MdKind.number, MdKind.paragraph]);
    expect(b[0].text, 'शीर्षक');
    expect(b[1].text, 'पहली पंक्ति\nदूसरी पंक्ति');
    expect(b[6].number, 2);
    expect(b.last.text, '**मोटा** शुरू', reason: '"**bold**" at the start of a line is not a bullet');
  });

  test('bold spans, stray markers are dropped, nothing else becomes markup', () {
    const base = TextStyle();
    final s = inlineSpan('यह **ज़रूरी** है और __यह भी__ `कोड` ** अधूरा [link](http://x)', base);
    expect(s.toPlainText(), 'यह ज़रूरी है और यह भी कोड  अधूरा [link](http://x)');
    final bold = s.children!.whereType<TextSpan>().where((e) => e.style?.fontWeight == FontWeight.w700).map((e) => e.text).toList();
    expect(bold, ['ज़रूरी', 'यह भी']);
  });

  test('plain text for copy / share', () {
    expect(markdownPlain('# नमस्ते\n**तथ्य:** एक\n- क\n- ख\n1. ग'), 'नमस्ते\n\nतथ्य: एक\n• क\n• ख\n1. ग');
    expect(markdownPlain(''), '');
  });

  testWidgets('renders and is selectable inside a SelectionArea', (t) async {
    await t.pumpWidget(const MaterialApp(home: Scaffold(body: SelectionArea(child: LightMarkdown('**मोटा** पाठ\n- बिंदु एक\n- बिंदु दो')))));
    expect(find.textContaining('बिंदु एक', findRichText: true), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
  });
}
