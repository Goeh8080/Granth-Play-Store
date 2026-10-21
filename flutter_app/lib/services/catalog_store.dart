import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api.dart';
import 'events.dart';
import 'image_cache.dart';
import 'search.dart';
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
  CatalogStore({Api? api, Stream<List<ConnectivityResult>>? connectivity})
      : _api = api ?? Api(),
        _connectivity = connectivity;
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

  // ---------- search index (built once per catalog, off the UI thread) ----------

  /// Bumped whenever the catalog lists are replaced; screens rebuild only then.
  int catalogVersion = 0;
  final Map<String, SearchDoc> _pDocs = {};
  final Map<String, SearchDoc> _tDocs = {};
  final Map<String, SearchDoc> _gDocs = {};

  static List<String?> pramanFields(Praman p) => [p.title, p.description, p.topicTitle, p.granthTitle, p.granthAuthor, p.youtubeDesc];
  static List<String?> topicFields(Topic t) => [t.title, t.description];
  static List<String?> granthFields(Granth g) => [g.title, g.author, g.description];

  SearchDoc pramanDoc(Praman p) => _pDocs[p.id] ??= docOf(pramanFields(p));
  SearchDoc topicDoc(Topic t) => _tDocs[t.id] ??= docOf(topicFields(t));
  SearchDoc granthDoc(Granth g) => _gDocs[g.id] ??= docOf(granthFields(g));

  void _catalogChanged({bool warm = true}) {
    catalogVersion++;
    _pDocs.clear();
    _tDocs.clear();
    _gDocs.clear();
    if (warm) unawaited(_warmIndex());
  }

  static String _join(List<String?> f) => f.whereType<String>().where((x) => x.isNotEmpty).join('\n');

  /// Normalizing + transliterating 1,200 rows takes ~0.6 s, so do it in a background isolate.
  Future<void> _warmIndex() async {
    final v = catalogVersion;
    final ps = pramans, ts = topics, gs = granths;
    try {
      final texts = [...ps.map((p) => _join(pramanFields(p))), ...ts.map((t) => _join(topicFields(t))), ...gs.map((g) => _join(granthFields(g)))];
      final docs = await compute(makeDocs, texts);
      if (v != catalogVersion || docs.length != texts.length) return;
      var i = 0;
      for (final p in ps) {
        _pDocs[p.id] = docs[i++];
      }
      for (final t in ts) {
        _tDocs[t.id] = docs[i++];
      }
      for (final g in gs) {
        _gDocs[g.id] = docs[i++];
      }
    } catch (e) {
      debugPrint('search index: $e');
    }
  }

  @visibleForTesting
  void debugSetCatalog(Catalog c) {
    _catalog = c;
    _catalogChanged(warm: false);
    status = SyncStatus.ready;
    booted = true;
    notifyListeners();
  }

  Future<void> boot() => _boot ??= _doBoot();

  Future<void> _doBoot() async {
    booted = true;
    offlineIds = _loadOfflineIds();
    // Settings restored by Android backup on a new install can say "saved offline" while the
    // pictures are not on this phone yet: start from a clean list then.
    if (offlineIds.isNotEmpty && ImageStore.I.countSync() == 0) {
      offlineIds = {};
      try {
        Store.I.setString(Store.kOfflineIds, '[]');
      } catch (_) {}
    }
    try {
      final res = await Connectivity().checkConnectivity().timeout(const Duration(seconds: 3));
      online = !res.contains(ConnectivityResult.none);
    } catch (_) {
      online = true;
    }
    notifyListeners();
    try {
      // Decoded off the UI thread; a damaged / old-format file is ignored and a fresh sync
      // replaces it.
      final raw = await Store.I.readJson('catalog.json', background: true).timeout(const Duration(seconds: 8));
      Catalog? cached;
      try {
        cached = Catalog.fromJson(raw);
      } catch (e) {
        debugPrint('catalog.json unreadable, will sync fresh: $e');
      }
      if (cached != null && cached.topics.isEmpty && cached.granths.isEmpty) cached = null;
      if (cached != null) {
        _catalog = cached;
        try {
          _lastJson = _contentKey(cached);
        } catch (_) {}
        _catalogChanged();
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
  DateTime? _pausedAt;
  DateTime? _lastSyncAt;

  /// App went to the background.
  void onPause() => _pausedAt = DateTime.now();

  /// Back from the background: sync silently when the app was away for a while (≥ 30 s)
  /// or the last sync is older than 2 minutes. The saved data stays on screen meanwhile.
  void onResume() {
    final now = DateTime.now();
    if (now.difference(_lastResume).inMilliseconds < 3000) return;
    _lastResume = now;
    final away = _pausedAt == null ? Duration.zero : now.difference(_pausedAt!);
    _pausedAt = null;
    final stale = _lastSyncAt == null || now.difference(_lastSyncAt!) > const Duration(minutes: 2);
    if (away < const Duration(seconds: 30) && !stale) return;
    sync().then((_) => savePages());
  }

  /// JSON of the catalog on screen; an identical download changes nothing (no rebuild,
  /// no re-index, no disk write).
  String? _lastJson;

  static String _contentKey(Catalog c) {
    final j = c.toJson()..remove('syncedAt');
    return jsonEncode(j);
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
      _lastSyncAt = DateTime.now();
      final enc = _contentKey(c);
      if (enc != _lastJson || !hasData) {
        await Store.I.writeJson('catalog.json', c.toJson());
        _lastJson = enc;
        _catalog = c;
        _catalogChanged();
      } else {
        // Same data: keep the lists (and every screen) as they are, just refresh the time.
        _catalog = _catalog.withSyncedAt(c.syncedAt);
      }
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
