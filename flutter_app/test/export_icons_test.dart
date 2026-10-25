import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/group_icon.dart';
import 'package:granthprabandhan/widgets/religion_symbol.dart';

/// Exports every religion symbol (3 tones) and group icon as 256/512 PNGs, transparent outside
/// the rounded tile. Only runs when ICONS_OUT is set, e.g.
///   ICONS_OUT=/workspace/admin_icons flutter test test/export_icons_test.dart
void main() {
  final out = Platform.environment['ICONS_OUT'];
  testWidgets('export religion symbols and group icons', skip: out == null, (t) async {
    final files = <String, List<String>>{'religion': [], 'group': []};
    Future<void> shot(Widget w, int px, String path) async {
      await t.binding.setSurfaceSize(Size(px.toDouble(), px.toDouble()));
      t.view.devicePixelRatio = 1;
      final key = GlobalKey();
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: RepaintBoundary(key: key, child: SizedBox(width: px.toDouble(), height: px.toDouble(), child: w)),
      ));
      await t.runAsync(() async {
        final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
        final d = await img.toByteData(format: ui.ImageByteFormat.png);
        File(path).createSync(recursive: true);
        File(path).writeAsBytesSync(d!.buffer.asUint8List());
      });
    }

    for (final px in [256, 512]) {
      for (final n in religionSymbolNames) {
        for (final tone in Tone.values) {
          final (colors, ink) = toneColors(tone);
          final f = 'religion-$n-${tone.name}.png';
          // the same tile as [ReligionSymbol] (gradient + radius 0.26), without the drop shadow, so the
          // outside of the tile is fully transparent
          await shot(
            Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(px * 0.26),
                gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
              ),
              child: CustomPaint(painter: ReligionSymbolPainter(n, ink), size: Size.square(px.toDouble())),
            ),
            px,
            '$out/$px/$f',
          );
          if (px == 256) files['religion']!.add(f);
        }
      }
      for (final n in groupIconNames) {
        final f = 'group-$n.png';
        await shot(GroupIcon(n, size: px.toDouble()), px, '$out/$px/$f');
        if (px == 256) files['group']!.add(f);
      }
    }
    await t.binding.setSurfaceSize(null);
    File('$out/index.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert({
      'about': 'Granth app icons, rendered from the app\'s own painters (lib/widgets/religion_symbol.dart, lib/widgets/group_icon.dart).',
      'layout': {
        'sizes': [256, 512],
        'folders': '<size>/ (256/ and 512/), same file names in both',
        'religion_files': 'religion-<key>-<tone>.png',
        'group_files': 'group-<key>.png',
        'transparency': 'transparent outside the rounded tile (no drop shadow baked in; group icons keep their own soft inner tile shadow)',
      },
      'religion_keys': religionSymbolNames,
      'religion_tones': Tone.values.map((e) => e.name).toList(),
      'group_keys': groupIconNames,
      'religion_key_notes': {'ektara': 'old alias of kabir', 'unknown': 'falls back to misc'},
      'files': {'religion': files['religion'], 'group': files['group']},
    }));
  });
}
