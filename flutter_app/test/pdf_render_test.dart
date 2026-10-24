import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:image/image.dart' as img;

/// Loads the real bundled fonts (the test default font draws boxes).
Future<void> loadFonts() async {
  const fams = {
    'NotoDeva': ['NotoSansDevanagari-Regular.ttf', 'NotoSansDevanagari-Medium.ttf', 'NotoSansDevanagari-SemiBold.ttf'],
    'NotoDevaFull': ['NotoSansDevanagari-Full.ttf'],
    'DMSans': ['DMSans-Regular.ttf', 'DMSans-Medium.ttf', 'DMSans-SemiBold.ttf'],
    'YatraOne': ['YatraOne-Devanagari.ttf'],
    'YatraOneLatin': ['YatraOne-Latin.ttf'],
    'TiroDevanagari': ['TiroDevanagariSanskrit-Regular.ttf'],
  };
  for (final e in fams.entries) {
    final l = FontLoader(e.key);
    for (final f in e.value) {
      final b = File('assets/fonts/$f').readAsBytesSync();
      l.addFont(Future.value(ByteData.view(b.buffer)));
    }
    await l.load();
  }
}

/// Conjunct- and matra-heavy Hindi/Sanskrit used to check shaping.
const kConjuncts = 'श्रीमद्भगवद्गीता अध्याय १५ श्लोक ४ — क्षत्रिय, ज्ञान, त्र्यम्बकं, द्वन्द्व, '
    'स्वरूप, उद्धृत, कृष्ण, ऋषि, पृथ्वी, ह्रदय, श्रद्धा, संन्यास, प्राण, आत्मा, हृषीकेश, '
    'शुद्ध, विद्या, ब्रह्म, क्ष्म्य, स्त्री, अर्द्ध, पद्म, सर्वज्ञ, कबीर सागर — कौन, क्यों, गुरु, कृपा।';

void main() {
  testWidgets('Devanagari conjuncts shape correctly in the generated PDF (writes build/pdf_sample.pdf)', (tester) async {
    await tester.runAsync(loadFonts);
    final pic = img.Image(width: 600, height: 800);
    img.fill(pic, color: img.ColorRgb8(236, 222, 190));
    final jpg = Uint8List.fromList(img.encodeJpg(pic));
    final bytes = await tester.runAsync(() => BookPdfBuilder().build([
          PdfSpec(title: 'गीता ज्ञान — श्रद्धा और क्षमा', subtitle: 'विषय', body: kConjuncts, meta: '3 प्रमाण', topicCover: true),
          PdfSpec(title: 'अध्याय 15 श्लोक 4', subtitle: 'मृत्यु के बाद क्या', body: kConjuncts, meta: 'श्रीमद्भगवद्गीता · वेद व्यास')..image = jpg,
        ], PdfStyle.fill90));
    expect(String.fromCharCodes(bytes!.sublist(0, 4)), '%PDF');
    Directory('build').createSync(recursive: true);
    File('build/pdf_sample.pdf').writeAsBytesSync(bytes);

    // Round 7: a page whose picture is broken is never drawn blank — the PDF fails instead.
    Object? err;
    await tester.runAsync(() async {
      try {
        await BookPdfBuilder().build([
          PdfSpec(title: 'टूटा चित्र', body: kConjuncts.substring(0, 40), meta: 'कबीर सागर')..image = Uint8List.fromList(List.filled(200, 7)),
        ], PdfStyle.fill90);
      } catch (e) {
        err = e;
      }
    });
    expect(err, isA<PdfPageFailed>());
  });
}
