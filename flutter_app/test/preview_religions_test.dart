import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/state/router.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round10_folders_test.dart' show realCatalog;

/// Golden-free preview: renders the religions screen (2×2) to a PNG with the app's real fonts.
/// Only runs when PREVIEW_OUT is set, e.g.
///   PREVIEW_OUT=/workspace/preview_religions.png flutter test test/preview_religions_test.dart
void main() {
  final out = Platform.environment['PREVIEW_OUT'];
  setUp(setUpApp);
  testWidgets('render the religions screen in 2×2', skip: out == null, (t) async {
    CatalogStore.I.debugSetCatalog(realCatalog());
    const fonts = {
      'NotoDeva': ['NotoSansDevanagari-Regular', 'NotoSansDevanagari-Medium', 'NotoSansDevanagari-SemiBold'],
      'DMSans': ['DMSans-Regular', 'DMSans-Medium', 'DMSans-SemiBold'],
      'YatraOne': ['YatraOne-Devanagari'],
      'YatraOneLatin': ['YatraOne-Latin'],
      'NotoDevaFull': ['NotoSansDevanagari-Full'],
      'TiroDevanagari': ['TiroDevanagariSanskrit-Regular'],
    };
    await t.runAsync(() async {
      for (final e in fonts.entries) {
        final l = FontLoader(e.key);
        for (final f in e.value) {
          l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
        }
        await l.load();
      }
    });
    const w = 412.0, h = 915.0;
    await t.binding.setSurfaceSize(const Size(w * 2, h * 2));
    t.view.devicePixelRatio = 2;
    addTearDown(() => t.binding.setSurfaceSize(null));
    addTearDown(t.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: key, child: const GranthApp(splash: false, links: false)));
    await settle(t);
    AppNav.I.go('#/granths');
    await settle(t, 20);
    await t.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
      final d = await img.toByteData(format: ui.ImageByteFormat.png);
      File(out!).writeAsBytesSync(d!.buffer.asUint8List());
    });
    expect(File(out!).lengthSync(), greaterThan(10000));
  });
}
