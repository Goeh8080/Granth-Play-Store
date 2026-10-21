import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api.dart';
import 'events.dart';
import 'image_cache.dart';
import 'storage.dart';

enum SyncStatus { booting, ready, offline, syncing, error }

class ImageProgress {
  const ImageProgress(this.done, this.total, this.running);
  final int done;
  final int total;
  final bool running;
}

const kNoDataError = 'डेटा नहीं आ पाया। इंटरनेट चेक करके फिर सिंक करें।';
const kStaleError = 'नया डेटा नहीं मिला। सेव की हुई कॉपी चल रही है।';

/// The zustand store `cn` from the web bundle: boot → cached catalog → sync → save pages offline.
class CatalogStore extends ChangeNotifier {
  CatalogStore({Api? api, Stream<List<ConnectivityResult>>? connectivity}) : _api = api ?? Api(), _connectivity = connectivity;
  static CatalogStore? _instance;
  static CatalogStore get I => _instance ??= CatalogStore();
  static set I(CatalogStore v) => _instance = v;

  final Api _api;
  final Stream<List<ConnectivityResult>>? _connectivity;
  Catalog _catalog = Catalog.empty();
  SyncStatus status = SyncStatus.booting;
  bool online = true;
  String? error;
  ImageProgress images = const ImageProgress(0, 0, false);
  bool booted = false;
  Set<String> offlineIds = {};
  int _saveRun = 0;
  Future<void>? _boot;
  StreamSubscription<List<ConnectivityResult>>? _sub;
  Timer? _timer;

  List<Topic> get topics => _catalog.topics;
  List<Granth> get granths => _catalog.granths;
  List<Praman> get pramans => _catalog.pramans;
  int? get syncedAt => _catalog.syncedAt;
  bool get hasData => topics.isNotEmpty || granths.isNotEmpty;

  @visibleForTesting
  void debugSetCatalog(Catalog c) {
    _catalog = c;
    status = SyncStatus.ready;
    booted = true;
    notifyListeners();
  }

  Future<void> boot() => _boot ??= _doBoot();

  Future<void> _doBoot() async {
    booted = true;
    offlineIds = _loadOfflineIds();
    try {
      final res = await Connectivity().checkConnectivity().timeout(const Duration(seconds: 3));
      online = !res.contains(ConnectivityResult.none);
    } catch (_) {
      online = true;
    }
    notifyListeners();
    try {
      final cached = Catalog.fromJson(await Store.I.readJson('catalog.json').timeout(const Duration(seconds: 8)));
      if (cached != null) {
        _catalog = cached;
        status = online ? SyncStatus.ready : SyncStatus.offline;
        images = ImageProgress(ImageStore.I.countSync(), _allImagePaths().length, false);
        notifyListeners();
      }
    } catch (_) {}
    _listen();
    if (online) {
      await sync();
      if (hasData) savePages();
    } else if (hasData) {
      status = SyncStatus.offline;
      error = null;
      notifyListeners();
    } else {
      status = SyncStatus.error;
      error = kNoDataError;
      notifyListeners();
    }
  }

  void _listen() {
    try {
      _sub ??= (_connectivity ?? Connectivity().onConnectivityChanged).listen((r) {
        final now = !r.contains(ConnectivityResult.none);
        if (now && !online) {
          online = true;
          notifyListeners();
          sync().then((_) => savePages());
        } else if (!now && online) {
          online = false;
          status = syncedAt != null ? SyncStatus.offline : SyncStatus.error;
          notifyListeners();
        }
      });
    } catch (_) {}
    // Every 3 minutes while online, like the web app.
    _timer ??= Timer.periodic(const Duration(minutes: 3), (_) {
      if (online) sync().then((_) => savePages());
    });
  }

  /// Retry button on the home screen.
  Future<void> retry() async {
    online = true;
    await sync();
    if (hasData) savePages();
  }

  DateTime _lastResume = DateTime.now();
  void onResume() {
    final now = DateTime.now();
    if (now.difference(_lastResume).inMilliseconds < 3000) return;
    _lastResume = now;
    sync().then((_) => savePages());
  }

  Future<void> sync() async {
    if (status == SyncStatus.syncing) return;
    if (!online) {
      final had = hasData || syncedAt != null;
      status = had ? SyncStatus.offline : SyncStatus.error;
      error = had ? null : kNoDataError;
      notifyListeners();
      return;
    }
    status = SyncStatus.syncing;
    error = null;
    notifyListeners();
    try {
      final c = await _api.fetchCatalog();
      await Store.I.writeJson('catalog.json', c.toJson());
      _catalog = c;
      status = SyncStatus.ready;
      error = null;
      images = ImageProgress(ImageStore.I.countSync(), _allImagePaths().length, images.running);
      EventLog.I.log('sync', 'catalog');
    } catch (e) {
      debugPrint('sync failed: $e');
      final had = syncedAt != null;
      status = had ? SyncStatus.ready : SyncStatus.error;
      error = had ? kStaleError : kNoDataError;
    }
    notifyListeners();
  }

  ({List<String> first, List<String> rest}) _imageGroups() {
    final seen = <String>{};
    final first = <String>[];
    final rest = <String>[];
    void add(List<String> into, String? p) {
      final r = mediaPath(p);
      if (r != null && seen.add(r)) into.add(r);
    }

    for (final g in granths) {
      add(first, g.imagePath);
      add(first, g.editorImagePath);
    }
    for (final p in pramans) {
      add(rest, p.granthImage);
      add(rest, p.imagePath);
      add(rest, p.editorImagePath);
    }
    return (first: first, rest: rest);
  }

  List<String> _allImagePaths() {
    final g = _imageGroups();
    return [...g.first, ...g.rest];
  }

  /// `savePages` — download every page image (granth covers first) with 6 workers.
  void savePages() {
    final g = _imageGroups();
    final all = [...g.first, ...g.rest];
    if (all.isEmpty) return;
    final run = ++_saveRun;
    images = ImageProgress(images.done, all.length, true);
    notifyListeners();
    () async {
      final have = await ImageStore.I.which(all);
      var done = 0;
      final a = <String>[];
      final b = <String>[];
      for (final e in g.first) {
        have.contains(e) ? done++ : a.add(e);
      }
      for (final e in g.rest) {
        have.contains(e) ? done++ : b.add(e);
      }
      if (run != _saveRun) return;
      images = ImageProgress(done, all.length, a.length + b.length > 0);
      notifyListeners();
      Future<void> pool(List<String> list) async {
        var next = 0;
        Future<void> worker() async {
          while (run == _saveRun) {
            final i = next++;
            if (i >= list.length) return;
            try {
              await ImageStore.I.get(list[i]);
            } catch (_) {}
            done++;
            if (run == _saveRun && (done % 3 == 0 || done == all.length)) {
              images = ImageProgress(done, all.length, done < all.length);
              notifyListeners();
            }
          }
        }

        final n = list.length < 6 ? list.length : 6;
        await Future.wait(List.generate(n, (_) => worker()));
      }

      await pool(a);
      await pool(b);
      if (run == _saveRun) {
        images = ImageProgress(all.length, all.length, false);
        markOffline(granths.map((e) => e.id));
        notifyListeners();
      }
    }();
  }

  void stopSave() {
    _saveRun++;
    images = ImageProgress(images.done, images.total, false);
    notifyListeners();
  }

  Set<String> _loadOfflineIds() {
    try {
      final raw = Store.I.getString(Store.kOfflineIds);
      final list = raw == null ? const [] : jsonDecode(raw) as List;
      return list.map((e) => '$e').toSet();
    } catch (_) {
      return {};
    }
  }

  /// `Ot()` — remember granths that are fully available offline.
  void markOffline(Iterable<String> ids) {
    var changed = false;
    for (final id in ids) {
      if (id.isNotEmpty && offlineIds.add(id)) changed = true;
    }
    if (changed) {
      Store.I.setString(Store.kOfflineIds, jsonEncode(offlineIds.toList()));
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    _timer?.cancel();
    super.dispose();
  }
}
