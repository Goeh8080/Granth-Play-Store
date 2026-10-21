import 'dart:async';
import 'dart:convert';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api.dart';
import 'events.dart';
import 'image_cache.dart';
import 'native_bridge.dart';
import 'search.dart';
import 'storage.dart';

enum SyncStatus { booting, ready, offline, syncing, error }

class ImageProgress {
  const ImageProgress(this.done, this.total, this.running, {this.failed = 0, this.lowSpace = false, this.checking = false, this.manual = false});
  final int done;
  final int total;
  final bool running;

  /// Saved pictures are being checked (exists, size, image header) before missing ones download.
  final bool checking;

  /// Started from the सिंक button: progress is always shown, even when nothing is missing.
  final bool manual;

  /// Pictures that could not be fetched after every retry (tried again on the next sync).
  final int failed;

  /// Stopped because the phone is almost full.
  final bool lowSpace;

  bool get complete => total > 0 && done >= total;
}

/// Shown once each time the whole library finishes downloading.
class OfflineReady {
  const OfflineReady({required this.pages, required this.granths, required this.bytes, required this.signature});
  final String signature;
  final int pages;
  final int granths;
  final int bytes;
}

const kLowSpaceStop = 'फ़ोन में जगह कम है — पेज डाउनलोड रुका। जगह खाली करके सिंक दबाएँ।';

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
        images = ImageProgress(_haveCount(), _allImagePaths().length, false);
        notifyListeners();
      }
    } catch (_) {}
    _listen();
    if (online) {
      await sync();
      if (hasData) savePages(verify: true);
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
      images = ImageProgress(_haveCount(), _allImagePaths().length, images.running);
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

  int _haveCount() {
    var n = 0;
    for (final p in _allImagePaths()) {
      if (ImageStore.I.cachedSync(p) != null) n++;
    }
    return n;
  }

  // ---------- full offline download ----------

  /// Fetches one picture; true when it is on the device. Replaceable in tests.
  @visibleForTesting
  Future<bool> Function(String path) fetchPage = (p) async => (await ImageStore.I.get(p)) != null;

  /// Pictures already on the device. Replaceable in tests.
  @visibleForTesting
  Future<Set<String>> Function(List<String> paths) havePages = (p) => ImageStore.I.which(p);

  /// Free bytes on the app volume (null = unknown). Replaceable in tests.
  @visibleForTesting
  Future<int?> Function() freeBytes = NativeBridge.freeBytes;

  /// Checks saved pictures; returns the good ones (bad files are deleted). Replaceable in tests.
  @visibleForTesting
  Future<Set<String>> Function(List<String> paths, void Function(int checked) progress) verifyPages = (p, f) => ImageStore.I.verify(p, onProgress: f);

  /// How long the result of a manual sync stays on screen at least.
  @visibleForTesting
  Duration minManualShow = const Duration(milliseconds: 900);

  /// सिंक button (`sync().then(savePages)` in the original): fetch the lists again, then
  /// check every saved picture and download anything missing or damaged.
  Future<void> manualSync() async {
    images = ImageProgress(images.done, images.total, true, manual: true, checking: true);
    online = true; // like the original button: always try the network
    notifyListeners();
    if (status != SyncStatus.syncing) await sync();
    savePages(verify: true, manual: true);
  }

  /// Wait between retries of one picture (1×, 3×) and before the second pass.
  @visibleForTesting
  Duration retryBase = const Duration(seconds: 1);

  /// Download stops below this much free space (the catalog and settings still save).
  static const lowSpaceBytes = 150 << 20;

  /// Fires each time the whole library has just become available offline.
  final ValueNotifier<OfflineReady?> offlineReady = ValueNotifier(null);

  Future<bool> _fetchWithRetry(String path, int run) async {
    for (var i = 0; i < 3; i++) {
      if (run != _saveRun) return false;
      try {
        if (await fetchPage(path)) return true;
      } catch (_) {}
      if (i < 2) await Future<void>.delayed(retryBase * (i == 0 ? 1 : 3));
    }
    return false;
  }

  /// `savePages` — download every picture the app shows (granth covers and प्रकाशन
  /// pages first, then every praman page), so every granth works with no internet.
  ///
  /// Incremental and resumable: pictures already saved are skipped, so a stopped
  /// download continues where it left off on the next start / sync. Each picture is
  /// tried 3 times, and failures get a second pass; the rest wait for the next sync.
  /// Stops (with a message) when the phone is almost full.
  void savePages({bool verify = false, bool manual = false}) {
    final g = _imageGroups();
    final all = [...g.first, ...g.rest];
    if (all.isEmpty) {
      if (manual) {
        images = const ImageProgress(0, 0, false, manual: true);
        notifyListeners();
      }
      return;
    }
    final run = ++_saveRun;
    final shownAt = DateTime.now();
    images = ImageProgress(manual ? 0 : images.done, all.length, true, checking: verify, manual: manual);
    notifyListeners();
    () async {
      final Set<String> have;
      if (verify) {
        // Repair pass: every saved picture is checked; missing / empty / damaged files are
        // deleted here and downloaded again below. Counts update live.
        have = await verifyPages(all, (n) {
          if (run != _saveRun) return;
          images = ImageProgress(n, all.length, true, checking: true, manual: manual);
          notifyListeners();
        });
      } else {
        have = await havePages(all);
      }
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
      if (!online || error == kStaleError) {
        // No internet right now: only the check ran; missing pictures download on the next sync.
        a.clear();
        b.clear();
      }
      final missing = a.length + b.length;
      images = ImageProgress(done, all.length, missing > 0 || manual, manual: manual);
      notifyListeners();
      var lowSpace = false;
      if (missing > 0) {
        final free = await freeBytes().catchError((Object _) => null);
        if (free != null && free < lowSpaceBytes) lowSpace = true;
      }
      final failed = <String>[];
      var sinceCheck = 0;
      Future<void> pool(List<String> list) async {
        var next = 0;
        Future<void> worker() async {
          while (run == _saveRun && !lowSpace) {
            final i = next++;
            if (i >= list.length) return;
            if (++sinceCheck >= 25) {
              sinceCheck = 0;
              final free = await freeBytes().catchError((Object _) => null);
              if (free != null && free < lowSpaceBytes) {
                lowSpace = true;
                return;
              }
            }
            if (await _fetchWithRetry(list[i], run)) {
              done++;
            } else {
              failed.add(list[i]);
            }
            if (run == _saveRun && (done % 3 == 0 || done == all.length)) {
              images = ImageProgress(done, all.length, done < all.length, failed: failed.length, manual: manual);
              notifyListeners();
            }
          }
        }

        final n = list.length < 6 ? list.length : 6;
        await Future.wait(List.generate(n, (_) => worker()));
      }

      await pool(a);
      await pool(b);
      if (failed.isNotEmpty && run == _saveRun && !lowSpace && online) {
        // Second pass for flaky networks.
        await Future<void>.delayed(retryBase * 5);
        final again = [...failed];
        failed.clear();
        await pool(again);
      }
      if (run != _saveRun) return;
      if (manual) {
        // A tap on सिंक always shows its result (e.g. 985 / 985) for a moment.
        final left = minManualShow - DateTime.now().difference(shownAt);
        if (left > Duration.zero) {
          images = ImageProgress(done, all.length, true, failed: failed.length, manual: true);
          notifyListeners();
          await Future<void>.delayed(left);
          if (run != _saveRun) return;
        }
      }
      images = ImageProgress(done, all.length, false, failed: failed.length, lowSpace: lowSpace, manual: manual);
      if (lowSpace) error = kLowSpaceStop;
      // A granth is offline when all of its pictures are saved.
      final missingNow = {...failed, if (lowSpace) ...all.where((p) => ImageStore.I.cachedSync(p) == null)};
      markOffline(granths.where((e) => _granthPaths(e).every((p) => !missingNow.contains(p))).map((e) => e.id));
      notifyListeners();
      if (done >= all.length) _celebrate(all);
    }();
  }

  Iterable<String> _granthPaths(Granth g) sync* {
    for (final p in [g.imagePath, g.editorImagePath]) {
      final r = mediaPath(p);
      if (r != null) yield r;
    }
    for (final p in pramans) {
      if (p.granthId != g.id) continue;
      for (final q in [p.granthImage, p.imagePath, p.editorImagePath]) {
        final r = mediaPath(q);
        if (r != null) yield r;
      }
    }
  }

  /// Shows the "सारे ग्रंथ ऑफलाइन" card once per completed library: the first time,
  /// and again only when new content has finished downloading.
  void _celebrate(List<String> all) {
    final sorted = [...all]..sort();
    var h = 0;
    for (final p in sorted) {
      for (final c in p.codeUnits) {
        h = (h * 31 + c) & 0x3fffffff;
      }
    }
    final key = '${all.length}-$h';
    if (Store.I.getString(Store.kOfflineReady) == key || offlineReady.value?.signature == key) return;
    var bytes = 0;
    for (final p in all) {
      try {
        bytes += ImageStore.I.cachedSync(p)?.lengthSync() ?? 0;
      } catch (_) {}
    }
    offlineReady.value = OfflineReady(pages: all.length, granths: granths.length, bytes: bytes, signature: key);
  }

  /// The card was shown: remember it so it is not shown again for the same library
  /// (only saved once seen, so a kill before it shows brings it back next start).
  void ackOfflineReady() {
    final r = offlineReady.value;
    if (r == null) return;
    Store.I.setString(Store.kOfflineReady, r.signature);
    offlineReady.value = null;
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
