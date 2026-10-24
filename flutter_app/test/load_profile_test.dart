// Data-loading profile on the REAL catalog (opt-in: needs the API dumps in /tmp/bench, skipped
// otherwise, e.g. on CI). Prints PROFILE lines:
//   open        = cold start: catalog.json on disk → lists usable (CatalogStore.boot, no network)
//   open+files  = same with thousands of saved pictures in the images folder
//   granth view = filter + order the प्रमाण of one granth (what PramansPanel does on build)
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';
import 'package:granthprabandhan/services/order.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'helpers.dart';

class _Never extends Api {
  @override
  Future<Catalog> fetchCatalog() => Completer0().future;
}

class Completer0 {
  final future = Future<Catalog>.delayed(const Duration(hours: 1));
}

void main() {
  final dir = Directory(Platform.environment['GRANTH_BENCH'] ?? '/tmp/bench');
  final ok = ['getTopics', 'getGranths', 'getPramans'].every((n) => File('${dir.path}/$n.json').existsSync());
  String body(String n) => File('${dir.path}/$n.json').readAsStringSync();

  test('data loading profile (real catalog)', () async {
    await setUpApp();
    final sw = Stopwatch()..start();
    final cat = parseCatalog([body('getTopics'), body('getGranths'), body('getPramans'), 1]);
    final parse = sw.elapsedMilliseconds;
    await Store.I.writeText('catalog.json', cat.fileText ?? jsonEncode(cat.toJson()));
    final bytes = File('${Store.I.root.path}/catalog.json').lengthSync();

    Future<int> boot() async {
      final s = CatalogStore(api: _Never(), connectivity: const Stream.empty());
      CatalogStore.I = s;
      final t = Stopwatch()..start();
      unawaited0(s.boot());
      while (!s.hasData) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final ms = t.elapsedMilliseconds;
      s.dispose();
      return ms;
    }

    final cold = await boot();
    // ignore: avoid_print
    print('PROFILE open topics=${cat.topics.length} granths=${cat.granths.length} pramans=${cat.pramans.length} catalog.json=${(bytes / 1024).toStringAsFixed(0)}KB '
        'parse(sync, main isolate)=${parse}ms boot→data=${cold}ms');

    // A phone that has finished the full download: one file per picture.
    final paths = <String>{};
    for (final g in cat.granths) {
      for (final p in [g.imagePath, g.editorImagePath]) {
        final r = mediaPath(p);
        if (r != null) paths.add(r);
      }
    }
    for (final p in cat.pramans) {
      for (final q in [p.granthImage, p.imagePath, p.editorImagePath]) {
        final r = mediaPath(q);
        if (r != null) paths.add(r);
      }
    }
    Directory(Store.I.imagesDir).createSync(recursive: true);
    for (final p in paths) {
      File(ImageStore.I.fileFor(p).path).writeAsBytesSync(List.filled(64, 1));
    }
    final warm = await boot();
    // ignore: avoid_print
    print('PROFILE open+files pictures=${paths.length} boot→data=${warm}ms');

    for (final g in cat.granths.take(3).toList() + [cat.granths.reduce((a, b) => cat.pramans.where((p) => p.granthId == a.id).length >= cat.pramans.where((p) => p.granthId == b.id).length ? a : b)]) {
      final t = Stopwatch()..start();
      final rows = orderPramans(cat.pramans.where((p) => p.granthId == g.id).toList(), g.title);
      // ignore: avoid_print
      print('PROFILE granth-view granth=${g.id} pramans=${rows.length} filter+order=${t.elapsedMicroseconds / 1000}ms');
    }
  }, skip: ok ? false : 'no /tmp/bench data');

  // Whole library from the real server into an empty phone (GRANTH_E2E=1 also needed).
  test('full download profile (real server)', () async {
    await setUpApp();
    HttpOverrides.global = null;
    final cat = parseCatalog([body('getTopics'), body('getGranths'), body('getPramans'), 1]);
    final s = CatalogStore(api: _Never(), connectivity: const Stream.empty());
    CatalogStore.I = s;
    s.debugSetCatalog(cat);
    s.pageNotice = (_, _) async {};
    final total = s.allPages;
    final t = Stopwatch()..start();
    s.savePages();
    var firstAt = -1;
    while (s.images.running || s.images.done < total) {
      if (firstAt < 0 && s.savedPages > 0) firstAt = t.elapsedMilliseconds;
      if (t.elapsed > const Duration(minutes: 12)) break;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    final ms = t.elapsedMilliseconds;
    final mb = Directory(Store.I.imagesDir).listSync().whereType<File>().fold<int>(0, (n, f) => n + f.lengthSync()) / 1048576;
    // ignore: avoid_print
    print('PROFILE full-download pictures=${s.savedPages}/$total failed=${s.images.failed} total=${(ms / 1000).toStringAsFixed(1)}s first=${firstAt}ms size=${mb.toStringAsFixed(1)}MB (${(mb / (ms / 1000)).toStringAsFixed(1)} MB/s, workers=${CatalogStore.saveWorkers})');
    s.dispose();
  }, skip: ok && Platform.environment['GRANTH_E2E'] == '1' ? false : 'GRANTH_E2E=1 + /tmp/bench needed', timeout: const Timeout(Duration(minutes: 15)));
}

void unawaited0(Future<void> f) {}
