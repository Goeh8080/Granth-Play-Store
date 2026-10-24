// Round 8 frame-cost profile (opt-in: R8_FRAMES=1). Measures the wall time of every pumped frame
// (build + layout + paint recording; no GPU raster in flutter_test) while the app opens on the
// 36-granth catalog, with the new decorative animations ON vs OFF (एनिमेशन चालू / कम).
// Numbers are relative (desktop CPU, not a phone); they show what the animations ADD per frame.
import 'dart:io';

import 'package:flutter/material.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:granthprabandhan/state/places.dart';

import 'helpers.dart';
import 'round5_test.dart' show phone;
import 'scroll_restore_test.dart' show bigCatalog;

void main() {
  final on = Platform.environment['R8_FRAMES'] == '1';
  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    Places.forgetLive();
  });

  Future<List<double>> trial(WidgetTester t, bool anim) async {
    await t.runAsync(() async {
      UiPrefs.I.animations = anim;
    });
    Places.forgetLive();
    CatalogStore.I.debugSetCatalog(bigCatalog());
    final ms = <double>[];
    final sw = Stopwatch();
    // openApp pumps the first frames itself: time the whole opening with a stopwatch per pump.
    await t.pumpWidget(const SizedBox());
    final start = DateTime.now();
    await phone(t);
    sw
      ..reset()
      ..start();
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    ms.add(sw.elapsedMicroseconds / 1000);
    for (var i = 0; i < 40; i++) {
      sw
        ..reset()
        ..start();
      await t.pump(const Duration(milliseconds: 16));
      ms.add(sw.elapsedMicroseconds / 1000);
    }
    // ignore: avoid_print
    print('   (open took ${DateTime.now().difference(start).inMilliseconds} ms wall)');
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(seconds: 1));
    return ms;
  }

  String line(String tag, List<double> v) {
    final s = [...v]..sort();
    final mean = v.reduce((a, b) => a + b) / v.length;
    return 'PROFILE frames $tag mean=${mean.toStringAsFixed(2)}ms p95=${s[(s.length * .95).floor()].toStringAsFixed(2)}ms max=${s.last.toStringAsFixed(2)}ms over16=${v.where((x) => x > 16.6).length}/${v.length}';
  }

  testWidgets('frame cost of the opening animations: ON vs OFF', (t) async {
    final offAll = <double>[], onAll = <double>[];
    await trial(t, false); // warm-up (first mount compiles everything), not counted
    await trial(t, true);
    for (var r = 0; r < 4; r++) {
      offAll.addAll(await trial(t, false));
      onAll.addAll(await trial(t, true));
    }
    // ignore: avoid_print
    print(line('animations OFF (कम)', offAll));
    // ignore: avoid_print
    print(line('animations ON  (चालू)', onAll));
  }, skip: !on, timeout: const Timeout(Duration(minutes: 5)));
}
