// Photo Highlighter benchmark host: runs the REAL HighlighterServer on a fixed port with the
// bundled assets and a seeded library cache, until /tmp/hlbench/stop appears. Driven by
// tool/hl_bench.mjs (headless Chrome). Skipped unless HL_BENCH=1.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/highlighter/highlighter_server.dart';

void main() {
  test('highlighter bench host', () async {
    final s = HighlighterServer(
      cacheDir: Directory('/tmp/hlbench/cache'),
      loadAsset: (k) async => ByteData.sublistView(Uint8List.fromList(File(k).readAsBytesSync())),
    );
    final stop = File('/tmp/hlbench/stop');
    if (stop.existsSync()) stop.deleteSync();
    HighlighterServer.I = s;
    final u = await s.start();
    File('/tmp/hlbench/port').writeAsStringSync('${u.port}');
    while (!stop.existsSync()) {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    await s.stop();
  }, skip: Platform.environment['HL_BENCH'] == '1' ? false : 'HL_BENCH=1 needed', timeout: const Timeout(Duration(minutes: 20)));
}
