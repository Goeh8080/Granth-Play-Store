import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/religion_symbol.dart';

/// Renders every religion symbol at 160 px (and the new two small) to a PNG.
///   PREVIEW_SYMBOLS=/workspace/r12/symbols.png flutter test test/preview_symbols_test.dart
void main() {
  final out = Platform.environment['PREVIEW_SYMBOLS'];
  testWidgets('render the religion symbols', skip: out == null, (t) async {
    final key = GlobalKey();
    const tones = [Tone.saffron, Tone.maroon, Tone.gold, Tone.saffron, Tone.maroon, Tone.saffron, Tone.gold, Tone.gold];
    await t.binding.setSurfaceSize(const Size(8 * 150.0, 300));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(Directionality(
      textDirection: TextDirection.ltr,
      child: RepaintBoundary(
        key: key,
        child: Container(
          color: const Color(0xFFFDF6E3),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (var i = 0; i < 8; i++) ReligionSymbol(religionSymbolNames[i], tone: tones[i], size: 130),
            ]),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
              for (var i = 0; i < 8; i++) ReligionSymbol(religionSymbolNames[i], tone: tones[i], size: 44),
            ]),
          ]),
        ),
      ),
    ));
    await t.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
      final d = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out!).writeAsBytesSync(d!.buffer.asUint8List());
    });
  });
}
