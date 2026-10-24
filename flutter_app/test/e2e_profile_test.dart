// End-to-end Granth PDF profile against the REAL server (opt-in: GRANTH_E2E=1, needs
// internet and the API dumps in /tmp/bench). Runs the real PdfQueue.granthPdf pipeline:
// page pictures fetched by ImageStore → BookPdfBuilder → move + gallery copy.
// Scenarios: cold (nothing saved), cold while the background download of the whole
// library runs, warm/offline (everything saved). Prints PROFILE lines with phase times.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/pdf_builder.dart';
import 'package:granthprabandhan/services/pdf_queue.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'helpers.dart';
import 'pdf_render_test.dart' show loadFonts;

void main() {
  final dir = Directory(Platform.environment['GRANTH_BENCH'] ?? '/tmp/bench');
  final ok = Platform.environment['GRANTH_E2E'] == '1' && File('${dir.path}/getPramans.json').existsSync();
  List<Map<String, dynamic>> load(String n) => ((jsonDecode(File('${dir.path}/$n.json').readAsStringSync()) as Map)['data'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  setUp(setUpApp);
  testWidgets('granth PDF end to end (real server)', (t) async {
    await t.runAsync(loadFonts);
    HttpOverrides.global = null;
    final cat = Catalog(topics: const [], granths: load('getGranths').map(Granth.new).toList(), pramans: load('getPramans').map(Praman.new).toList(), syncedAt: 0);
    CatalogStore.I.debugSetCatalog(cat);
    PdfQueue.I.debugReset();
    PdfQueue.I.freeBytes = () async => null;
    final ids = (Platform.environment['GRANTH_E2E_IDS'] ?? '7,4,47').split(',');
    final style = Platform.environment['GRANTH_E2E_STYLE'] == 'fill90' ? PdfStyle.fill90 : PdfStyle.original;

    Future<void> run(String scenario, String id) async {
      final g = cat.granths.firstWhere((e) => e.id == id);
      final marks = <String, int>{};
      final sw = Stopwatch()..start();
      void tick() {
        final j = PdfQueue.I.jobs.isEmpty ? null : PdfQueue.I.jobs.first;
        if (j == null) return;
        marks.putIfAbsent(j.phase.name, () => sw.elapsedMilliseconds);
      }

      PdfQueue.I.addListener(tick);
      await t.runAsync(() async {
        PdfQueue.I.granthPdf(g, style);
        final job = PdfQueue.I.jobs.first;
        while (job.active) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      final job = PdfQueue.I.jobs.first;
      PdfQueue.I.removeListener(tick);
      final total = sw.elapsedMilliseconds;
      final imgs = (marks['pages'] ?? total) - (marks['images'] ?? 0);
      final pages = (marks['save'] ?? total) - (marks['pages'] ?? total);
      final save = total - (marks['save'] ?? total);
      // ignore: avoid_print
      print('PROFILE scenario=$scenario granth=$id style=${style.name} specs=${job.total} result=${job.phase.name} missing=${job.missingImages} '
          'total=${total}ms fetch=${imgs}ms build=${pages}ms save=${save}ms size=${((job.size ?? 0) / 1048576).toStringAsFixed(1)}MB err=${job.error}');
      PdfQueue.I.debugReset();
      PdfQueue.I.freeBytes = () async => null;
    }

    Future<void> wipe() => t.runAsync(() async {
          final d = Directory(Store.I.imagesDir);
          if (d.existsSync()) d.deleteSync(recursive: true);
          d.createSync(recursive: true);
        });

    final scen = (Platform.environment['GRANTH_E2E_SCEN'] ?? 'cold,coldbg,warm').split(',');
    for (final id in ids) {
      if (scen.contains('cold')) {
        await wipe();
        await run('cold', id);
      }
      if (scen.contains('coldbg')) {
        await wipe();
        await t.runAsync(() async {
          CatalogStore.I.savePages(); // whole library downloading at the same time (phone just opened)
          await Future<void>.delayed(const Duration(seconds: 2));
        });
        await run('cold+bg', id);
        await t.runAsync(() async {
          CatalogStore.I.stopSave();
          await Future<void>.delayed(const Duration(seconds: 2));
        });
      }
      if (scen.contains('warm')) {
        // Every page of this granth saved; no network at all.
        final sv = ImageStore.I.urlFor;
        ImageStore.I.urlFor = (p) => 'http://127.0.0.1:9/$p';
        await run('warm-offline', id);
        ImageStore.I.urlFor = sv;
      }
    }
  }, skip: !ok, timeout: const Timeout(Duration(minutes: 30)));
}
