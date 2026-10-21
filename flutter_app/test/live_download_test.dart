// The real download path (ImageStore + Dio + files) against a local server:
// ImageStore.get must finish, and the strip's saved-pages count must move while
// pages land, not only when the whole run ends.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/api.dart' show mediaUrl;
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/image_cache.dart';

import 'helpers.dart';
import 'offline_test.dart' show pictureCatalog;

final _jpeg = Uint8List.fromList([0xFF, 0xD8, ...List.filled(2000, 7), 0xFF, 0xD9]);

void main() {
  late HttpServer server;
  var hits = 0;
  var active = 0, peak = 0, delayMs = 40;
  var lastModified = DateTime.utc(2026, 10, 1, 10);
  setUp(() async {
    await setUpApp();
    HttpOverrides.global = null;
    hits = 0;
    active = 0;
    peak = 0;
    delayMs = 40;
    lastModified = DateTime.utc(2026, 10, 1, 10);
    server = await HttpServer.bind('127.0.0.1', 0);
    server.listen((r) async {
      r.response.headers.set('last-modified', HttpDate.format(lastModified));
      r.response.headers.contentType = ContentType('image', 'jpeg');
      if (r.method == 'HEAD') {
        await r.response.close();
        return;
      }
      hits++;
      active++;
      if (active > peak) peak = active;
      await Future<void>.delayed(Duration(milliseconds: delayMs));
      active--;
      r.response.add(_jpeg);
      await r.response.close();
    });
    ImageStore.I.urlFor = (p) => 'http://127.0.0.1:${server.port}/$p';
  });
  tearDown(() async {
    ImageStore.I.urlFor = mediaUrl;
    await server.close(force: true);
  });

  test('ImageStore.get finishes after a real download (it used to wait on itself forever)', () async {
    final a = ImageStore.I.get('uploads/one.jpg');
    final b = ImageStore.I.get('uploads/one.jpg'); // shares the same download
    final got = await Future.wait([a, b]).timeout(const Duration(seconds: 5));
    expect(got[0], isNotNull);
    expect(got[1]!.path, got[0]!.path);
    expect(hits, 1);
    // A later call is a cache hit and also finishes.
    expect(await ImageStore.I.get('uploads/one.jpg').timeout(const Duration(seconds: 2)), isNotNull);
  });

  test('saved-pages count ticks live during a real full download', () async {
    delayMs = 120; // ~1.4 s for 91 pages, 8 at a time: several 300 ms count updates
    final s = CatalogStore(connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog(extra: 80));
    CatalogStore.I = s;
    s.freeBytes = () async => 4 << 30;
    final shown = <int>[];
    s.progress.addListener(() => shown.add(s.progress.value.done));
    s.savePages(verify: true);
    for (var i = 0; i < 150 && (s.images.running || s.images.done < 91); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(s.images.done, 91);
    expect(s.images.running, isFalse);
    final middle = shown.where((d) => d > 0 && d < 91).toSet();
    expect(middle.length, greaterThanOrEqualTo(2), reason: 'count moved only at the end: $shown');
    expect(hits, 91);
  });

  test('8 pages download at the same time; the keep-alive service follows the count', () async {
    final s = CatalogStore(connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog(extra: 80));
    CatalogStore.I = s;
    s.freeBytes = () async => 4 << 30;
    final notes = <String>[];
    s.pageNotice = (m, a) async => notes.add(m == 'pagesStop' ? m : '$m ${a['done']}/${a['total']}');
    s.savePages();
    for (var i = 0; i < 150 && (s.images.running || s.images.done < 91); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    expect(s.images.done, 91);
    expect(peak, CatalogStore.saveWorkers);
    expect(CatalogStore.saveWorkers, 8);
    expect(notes.first, startsWith('pagesProgress '));
    expect(notes.last, 'pagesStop');
    expect(notes.where((n) => n == 'pagesStop'), hasLength(1));
    // At most about one notification update per second (plus the first one).
    expect(notes.where((n) => n.startsWith('pagesProgress')).length, lessThanOrEqualTo(4));
  });

  test('a picture re-uploaded on the server under the same name is noticed (HEAD, Last-Modified)', () async {
    final f = await ImageStore.I.get('uploads/same.jpg');
    expect(f, isNotNull);
    // The file carries the server time, not the phone's clock.
    expect(f!.lastModifiedSync().toUtc(), lastModified);
    expect(await ImageStore.I.changedOnServer('uploads/same.jpg'), isFalse);
    lastModified = lastModified.add(const Duration(days: 3));
    expect(await ImageStore.I.changedOnServer('uploads/same.jpg'), isTrue);
    expect(await ImageStore.I.changedOnServer('uploads/not-saved.jpg'), isFalse);
  });
}
