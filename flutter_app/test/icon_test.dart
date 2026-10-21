// Round 6: the launcher icon keeps the logo inside the adaptive-icon safe zone (never
// clipped by circle / squircle masks), legacy icons are proper squares / circles, and the
// Play Store icon is 512×512.
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

const res = 'android/app/src/main/res';
const dens = {'mdpi': 1.0, 'hdpi': 1.5, 'xhdpi': 2.0, 'xxhdpi': 3.0, 'xxxhdpi': 4.0};

img.Image load(String p) => img.decodePng(File(p).readAsBytesSync())!;

bool ink(img.Pixel p) => p.a > 20 && (p.r < 230 || p.g < 230 || p.b < 230);

void main() {
  for (final e in dens.entries) {
    test('${e.key}: logo inside the 66 dp safe circle of the adaptive icon', () {
      final fg = load('$res/mipmap-${e.key}/ic_launcher_foreground.png');
      final s = (108 * e.value).round();
      expect((fg.width, fg.height), (s, s));
      final r = s * 33 / 108;
      var far = 0.0;
      var any = false;
      for (final p in fg) {
        if (!ink(p)) continue;
        any = true;
        far = math.max(far, math.sqrt(math.pow(p.x + .5 - s / 2, 2) + math.pow(p.y + .5 - s / 2, 2)));
      }
      expect(any, isTrue);
      expect(far, lessThanOrEqualTo(r), reason: 'farthest logo pixel ${far.toStringAsFixed(1)} px, safe radius ${r.toStringAsFixed(1)} px');
      expect(far, greaterThan(r * 0.85), reason: 'and not needlessly small');
    });

    test('${e.key}: legacy icons are a full white square and a real circle', () {
      final sq = load('$res/mipmap-${e.key}/ic_launcher.png');
      final l = (48 * e.value).round();
      expect((sq.width, sq.height), (l, l));
      for (final c in [sq.getPixel(0, 0), sq.getPixel(l - 1, l - 1)]) {
        expect((c.r, c.g, c.b, c.a), (255, 255, 255, 255));
      }
      final rd = load('$res/mipmap-${e.key}/ic_launcher_round.png');
      expect((rd.width, rd.height), (l, l));
      expect(rd.getPixel(0, 0).a, 0, reason: 'corners outside the circle are clear');
      expect(rd.getPixel(l ~/ 2, 1).a, greaterThan(200));
    });
  }

  test('adaptive icon: white background + the padded foreground', () {
    final xml = File('$res/mipmap-anydpi-v26/ic_launcher.xml').readAsStringSync();
    expect(xml, contains('@color/iconBackground'));
    expect(xml, contains('@mipmap/ic_launcher_foreground'));
    expect(File('$res/values/colors.xml').readAsStringSync(), contains('<color name="iconBackground">#FFFFFF</color>'));
  });

  test('Play Store icon: 512×512 PNG, opaque, under 1 MB', () {
    final f = File('assets/store/icon-512.png');
    expect(f.lengthSync(), lessThan(1024 * 1024));
    final im = img.decodePng(f.readAsBytesSync())!;
    expect((im.width, im.height, im.numChannels), (512, 512, 3));
  });
}
