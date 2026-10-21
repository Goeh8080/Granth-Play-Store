// Round 6: changed pictures on the server are downloaded again (once a day, quietly),
// and the WiFi-only setting stops a running background download when WiFi goes.
import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'helpers.dart';
import 'offline_test.dart' show FakeNet, pictureCatalog;
import 'round4_test.dart' show SlowApi, until;

void main() {
  setUp(setUpApp);

  CatalogStore make(Set<String> disk, {Stream<List<ConnectivityResult>>? net}) {
    final s = CatalogStore(connectivity: net ?? const Stream.empty())..debugSetCatalog(pictureCatalog(extra: 10));
    s.freeBytes = () async => 4 << 30;
    s.retryBase = Duration.zero;
    s.havePages = (p) async => {...disk.where(p.contains)};
    s.verifyPages = (p, _) async => {...disk.where(p.contains)};
    s.fetchPage = (p) async {
      disk.add(p);
      return true;
    };
    s.dropPage = (p) async => disk.remove(p);
    s.pageNotice = (_, _) async {};
    return s;
  }

  Future<void> settle(CatalogStore s) async {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (var i = 0; i < 100 && s.images.running; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('changed pictures are dropped and downloaded again; then not checked again for a day', () async {
    final disk = <String>{};
    final s = make(disk);
    s.savePages();
    await settle(s);
    final all = s.allPages;
    expect(s.images.done, all);
    await Future<void>.delayed(const Duration(milliseconds: 50)); // the automatic check after completion
    final asked = <String>[];
    final changed = disk.take(2).toSet();
    final fetched = <String>[];
    s.fetchPage = (p) async {
      fetched.add(p);
      disk.add(p);
      return true;
    };
    s.changedOnServer = (p) async {
      asked.add(p);
      return changed.contains(p);
    };
    expect(await s.revalidate(force: true), 2);
    expect(asked.toSet().length, all);
    await settle(s);
    expect(fetched.toSet(), changed);
    expect(s.images.done, all);
    asked.clear();
    expect(await s.revalidate(), 0, reason: 'checked less than a day ago');
    expect(asked, isEmpty);
    expect(Store.I.getString(CatalogStore.kRevalidatedAt), isNotNull);
  });

  test('the check waits for WiFi when "WiFi only" is on', () async {
    final disk = <String>{};
    final s = make(disk);
    s.savePages();
    await settle(s);
    Store.I.setString(Store.kWifiOnly, '1');
    s.debugSetNet([ConnectivityResult.mobile]);
    var asked = 0;
    s.changedOnServer = (p) async {
      asked++;
      return false;
    };
    expect(await s.revalidate(force: true), 0);
    expect(asked, 0);
  });

  test('"WiFi only": leaving WiFi stops a running background download', () async {
    final net = StreamController<List<ConnectivityResult>>.broadcast();
    final disk = <String>{};
    final s = make(disk, net: net.stream);
    Store.I.setString(Store.kWifiOnly, '1');
    s.debugSetNet([ConnectivityResult.wifi]);
    final gate = Completer<void>();
    s.fetchPage = (p) async {
      await gate.future;
      disk.add(p);
      return true;
    };
    s.debugListen();
    s.savePages();
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(s.images.running, isTrue);
    net.add([ConnectivityResult.mobile]);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(s.images.running, isFalse);
    gate.complete();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(s.images.running, isFalse);
    expect(disk.length, lessThanOrEqualTo(CatalogStore.saveWorkers), reason: 'only the pages already on their way land');
    await net.close();
    s.dispose();
  });

  test('on open the full download starts from the saved lists at once, before the sync answers', () async {
    final c = pictureCatalog();
    await Store.I.writeJson('catalog.json', c.toJson());
    final api = SlowApi(c)..gate = Completer<void>();
    final s = CatalogStore(api: api, connectivity: const Stream.empty());
    CatalogStore.I = s;
    final net = FakeNet(s);
    s.verifyPages = (paths, _) async => paths.where(net.saved.contains).toSet();
    s.pageNotice = (_, _) async {};
    final booting = s.boot();
    await until(() => s.images.done == 11);
    expect(s.images.done, 11, reason: 'pages saved while the lists were still being fetched');
    expect(api.calls, 1);
    api.gate!.complete();
    await booting;
    await until(() => !s.images.running);
    expect(s.images.done, 11);
  });
}
