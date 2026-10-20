import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:image/image.dart' as img;

void main() {
  testWidgets('builds a valid multi-page PDF (cover + text + picture)', (tester) async {
    final pic = img.Image(width: 300, height: 400);
    img.fill(pic, color: img.ColorRgb8(200, 180, 120));
    final jpg = Uint8List.fromList(img.encodeJpg(pic));
    Uint8List? preview;
    var pages = 0;
    final bytes = await tester.runAsync(() => BookPdfBuilder(onPage: (d, t) => pages = t, onPreview: (b) => preview = b).build([
          PdfSpec(title: 'गीता ज्ञान', subtitle: 'विषय', body: 'आत्मा का रहस्य', meta: '1 प्रमाण', topicCover: true),
          PdfSpec(title: 'अध्याय 15 श्लोक 4', body: 'परम पद ' * 40, meta: 'श्रीमद्भगवद्गीता')..image = jpg,
        ], PdfStyle.fill90));
    expect(bytes, isNotNull);
    expect(String.fromCharCodes(bytes!.sublist(0, 4)), '%PDF');
    expect(pages, 2);
    expect(preview, isNotNull);
  });
}
