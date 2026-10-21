import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/order.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';

import 'pdf_render_test.dart' show loadFonts;

/// PDF speed for granths that are already saved offline (pictures on disk, no network).
/// Needs the API dumps in /tmp/bench and the page pictures in /tmp/bench/img
/// (file name = media path with '/' → '_'); skipped otherwise (e.g. on CI).
void main() {
  final dir = Directory(Platform.environment['GRANTH_BENCH'] ?? '/tmp/bench');
  final ok = File('${dir.path}/getPramans.json').existsSync() && File('${dir.path}/getGranths.json').existsSync() && Directory('${dir.path}/img').existsSync();
  List<Map<String, dynamic>> load(String n) => ((jsonDecode(File('${dir.path}/$n.json').readAsStringSync()) as Map)['data'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  testWidgets('offline granth PDF benchmark', (tester) async {
    await tester.runAsync(loadFonts);
    final pramans = load('getPramans').map(Praman.new).toList();
    final granths = load('getGranths').map(Granth.new).toList();
    final ids = (Platform.environment['GRANTH_BENCH_IDS'] ?? '7,82,40').split(',');
    for (final style in [PdfStyle.fill90, PdfStyle.original]) {
      for (final id in ids) {
        final g = granths.firstWhere((e) => e.id == id);
        final proofs = orderPramans(pramans.where((p) => p.granthId == id).toList(), g.title);
        final specs = [...PdfQueue.granthSpecs(g), ...proofs.map(PdfQueue.pramanSpec)];
        for (final s in specs) {
          final f = File('${dir.path}/img/${(s.path ?? '').replaceAll('/', '_')}');
          if (f.existsSync()) s.file = f.path;
        }
        final out = '${dir.path}/out-$id-${style.name}.pdf';
        final sw = Stopwatch()..start();
        final size = await tester.runAsync(() => BookPdfBuilder().buildToFile(specs, style, out));
        sw.stop();
        // ignore: avoid_print
        print('PDFBENCH granth=$id style=${style.name} specs=${specs.length} ms=${sw.elapsedMilliseconds} size=${((size ?? 0) / 1048576).toStringAsFixed(1)}MB');
      }
    }
  }, skip: !ok, timeout: const Timeout(Duration(minutes: 10)));
}
