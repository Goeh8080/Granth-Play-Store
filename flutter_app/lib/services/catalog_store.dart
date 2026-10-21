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
  const ImageProgress(this.done, this.total, this.running, {this.failed = 0, this.lowSpace = false, this.checking = false, this.manual = false, this.checked = 0});

  /// Pages saved on this phone right now (live: every saved file counts the moment it lands).
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

  /// How many saved pages the सिंक button's check has gone through (its progress bar).
  final int checked;

  bool get complete => total > 0 && done >= total;

  ImageProgress copyWith({int? done, int? total, bool? running, int? failed, bool? lowSpace, bool? checking, bool? manual, int? checked}) => ImageProgress(
        done ?? this.done,
        total ?? this.total,
        running ?? this.running,
        failed: failed ?? this.failed,
        lowSpace: lowSpace ?? this.lowSpace,
        checking: checking ?? this.checking,
        manual: manual ?? this.manual,
        checked: checked ?? this.checked,
      );

  @override
  bool operator ==(Object other) =>
      other is ImageProgress &&
      other.done == done &&
      other.total == total &&
      other.running == running &&
      other.failed == failed &&
      other.lowSpace == lowSpace &&
      other.checking == checking &&
      other.manual == manual &&
      other.checked == checked;

  @override
  int get hashCode => Object.hash(done, total, running, failed, lowSpace, checking, manual, checked);

  @override
  String toString() => 'ImageProgress($done/$total running=$running checking=$checking manual=$manual)';
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
  ImageProgress _images = const ImageProgress(0, 0, false);

  /// Page counts right now (always current, for logic).
  ImageProgress get images => _images;
  set images(ImageProgress v) {
    _images = v;
    _countTimer?.cancel();
    _countTimer = null;
    progress.value = v;
  }

  /// What the sync strip / sync card show. Only these few widgets listen to it: a saved
  /// page used to notify the whole store, which rebuilt the entire home screen (~330
  /// widgets) 8 times a second during a download — the jank in build 1.0.0. Live counts
  /// are batched to ~3 updates a second; state changes (start / stop / check) show at once.
  final ValueNotifier<ImageProgress> progress = ValueNotifier(const ImageProgress(0, 0, false));

  /// Time of the last good sync, for the strip / sync card only. A quiet 2-minute sync with
  /// unchanged data updates just this (it used to rebuild the whole home screen).
  final ValueNotifier<int?> lastSync = ValueNotifier(null);
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
    _allSet = null;
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
      _net = res;
    } catch (_) {
      online = true;
    }
    notifyListeners();
    try {
      // Decoded off the UI thread; a damaged / old-format file is ignored and a fresh sync
      // replaces it.
      final text = await Store.I.readText('catalog.json').timeout(const Duration(seconds: 8));
      Catalog? cached;
      try {
        // Decode + compare key off the UI thread for a real (~1.5 MB) catalog.
        if (text != null) cached = text.length > 100000 ? await compute(loadCatalogText, text) : loadCatalogText(text);
      } catch (e) {
        debugPrint('catalog.json unreadable, will sync fresh: $e');
      }
      if (cached != null && cached.topics.isEmpty && cached.granths.isEmpty) cached = null;
      if (cached != null) {
        _catalog = cached;
        _lastJson = cached.contentKey;
        _catalogChanged();
        status = online ? SyncStatus.ready : SyncStatus.offline;
        // Real count at once, from one folder listing (no picture is opened).
        _seedSaved(indexPagesSync(_all));
        _indexed = true;
        images = ImageProgress(savedPages, _all.length, false);
        notifyListeners();
      }
    } catch (_) {}
    _listen();
    _watchSaves();
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
        final wasWifi = onWifi;
        _net = r;
        // "Download only on WiFi": the waiting download starts when WiFi comes back.
        if (now && online && !wasWifi && onWifi && _wifiOnly() && hasData) savePages();
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
    // Every 2 minutes while the app is on screen (the web app: every 3 minutes).
    _timer ??= Timer.periodic(autoSyncEvery, (_) => autoSync());
  }

  /// Every page the app can save (covers + praman pages).
  int get allPages => _all.length;

  /// Last connection types (null = not known yet).
  List<ConnectivityResult>? _net;

  /// On WiFi (or a cable). Unknown counts as WiFi so nothing is blocked by mistake.
  bool get onWifi => _net == null || _net!.contains(ConnectivityResult.wifi) || _net!.contains(ConnectivityResult.ethernet);

  /// Settings, read from the stored values (replaceable in tests).
  @visibleForTesting
  bool Function() autoSyncOn = () => Store.I.getString(Store.kAutoSync) != '0';
  bool _wifiOnly() => Store.I.getString(Store.kWifiOnly) == '1';

  /// For tests: pretend the phone is on these networks.
  @visibleForTesting
  void debugSetNet(List<ConnectivityResult> r) => _net = r;

  /// How often the lists are fetched again while the app is open.
  static const autoSyncEvery = Duration(minutes: 2);

  bool _foreground = true;

  /// Light background sync: fetch the lists quietly (no "सिंक हो रहा है" flash), then
  /// download only what is new or still missing. Skipped while another sync is running,
  /// while the app is in the background, or offline.
  Future<void> autoSync() async {
    if (!online || !_foreground || _syncing != null || !autoSyncOn()) return;
    final changed = await sync(silent: true);
    if (!hasData) return;
    if (changed || (!_saveActive && savedPages < _all.length)) savePages();
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
  void onPause() {
    _pausedAt = DateTime.now();
    _foreground = false;
  }

  /// Back from the background: sync silently when the app was away for a while (≥ 30 s)
  /// or the last sync is older than 2 minutes. The saved data stays on screen meanwhile.
  void onResume() {
    final now = DateTime.now();
    _foreground = true;
    if (now.difference(_lastResume).inMilliseconds < 3000) return;
    _lastResume = now;
    final away = _pausedAt == null ? Duration.zero : now.difference(_pausedAt!);
    _pausedAt = null;
    final stale = _lastSyncAt == null || now.difference(_lastSyncAt!) > const Duration(minutes: 2);
    if (away < const Duration(seconds: 30) && !stale) return;
    autoSync();
  }

  /// JSON of the catalog on screen; an identical download changes nothing (no rebuild,
  /// no re-index, no disk write).
  String? _lastJson;

  static String _contentKey(Catalog c) => catalogContentKey(c);

  Future<bool>? _syncing;

  /// Fetch the three lists. Returns true when the data changed. A second call while one is
  /// running waits for that one (never two at once). [silent]: background sync — the strip
  /// does not switch to "सिंक हो रहा है" and a failed fetch keeps the screen as it is.
  Future<bool> sync({bool silent = false}) {
    final running = _syncing;
    if (running != null) return running;
    final f = _doSync(silent);
    _syncing = f;
    f.whenComplete(() {
      if (identical(_syncing, f)) _syncing = null;
    });
    return f;
  }

  Future<bool> _doSync(bool silent) async {
    if (!online) {
      final had = hasData || syncedAt != null;
      status = had ? SyncStatus.offline : SyncStatus.error;
      error = had ? null : kNoDataError;
      notifyListeners();
      return false;
    }
    if (!silent) {
      status = SyncStatus.syncing;
      error = null;
      notifyListeners();
    }
    var changed = false;
    final was = (status, error);
    try {
      final c = await _api.fetchCatalog();
      _lastSyncAt = DateTime.now();
      final enc = c.contentKey ?? _contentKey(c);
      if (enc != _lastJson || !hasData) {
        final file = c.fileText;
        await (file != null ? Store.I.writeText('catalog.json', file) : Store.I.writeJson('catalog.json', c.toJson()));
        _lastJson = enc;
        _catalog = c;
        _catalogChanged();
        changed = true;
      } else {
        // Same data: keep the lists (and every screen) as they are, just refresh the time.
        _catalog = _catalog.withSyncedAt(c.syncedAt);
      }
      status = SyncStatus.ready;
      error = null;
      if (changed) {
        if (!_indexed) {
          // First lists on this phone (or the saved copy was unreadable): count what is
          // already in the images folder.
          _indexed = true;
          _seedSaved(indexPagesSync(_all));
        }
        images = images.copyWith(done: savedPages, total: _all.length);
      }
      EventLog.I.log('sync', 'catalog');
      lastSync.value = syncedAt;
      if (silent && !changed && was == (status, error)) return false;
    } catch (e) {
      debugPrint('sync failed: $e');
      if (silent && hasData) {
        // Quiet retry in 2 minutes; nothing on screen changes.
        return false;
      }
      final had = syncedAt != null;
      status = had ? SyncStatus.ready : SyncStatus.error;
      error = had ? kStaleError : kNoDataError;
    }
    notifyListeners();
    return changed;
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

  // ---------- live page count (one source of truth) ----------

  /// Pictures known to be saved on this phone. Fed by the start-up folder listing, the
  /// background download, pictures opened on screen and the repair check, so every screen
  /// (strip, pill, sync card) shows the same live number without pressing सिंक.
  final Set<String> _saved = {};
  Set<String>? _allSet;
  Set<String> get _all => _allSet ??= _allImagePaths().toSet();
  StreamSubscription<(String, bool)>? _saveSub;
  Timer? _countTimer;

  /// Saved pages of the current lists.
  int get savedPages {
    final all = _all;
    var n = 0;
    for (final p in _saved) {
      if (all.contains(p)) n++;
    }
    return n;
  }

  bool _indexed = false;

  void _seedSaved(Set<String> have) {
    _saved
      ..clear()
      ..addAll(have);
  }

  void _watchSaves() {
    try {
      _saveSub ??= ImageStore.I.changes.listen((e) => pageSaved(e.$1, e.$2));
    } catch (_) {}
  }

  /// One picture landed on (or was removed from) the phone: the count moves at once.
  @visibleForTesting
  void pageSaved(String path, bool saved) {
    final changed = saved ? _saved.add(path) : _saved.remove(path);
    if (!changed || !_all.contains(path)) return;
    _images = _images.copyWith(done: savedPages, total: _all.length);
    _showSoon();
  }

  /// Many pictures land (or are checked) close together: the number on screen moves
  /// ~3 times a second instead of once per picture.
  void _showSoon() {
    _countTimer ??= Timer(countEvery, () {
      _countTimer = null;
      progress.value = _images;
    });
  }

  /// How often the live page count on screen moves during a download.
  static const countEvery = Duration(milliseconds: 300);

  void _setImages(ImageProgress next) {
    if (next == _images && next == progress.value) return;
    images = next;
  }

  // ---------- full offline download ----------

  /// Fetches one picture; true when it is on the device. Replaceable in tests.
  @visibleForTesting
  Future<bool> Function(String path) fetchPage = (p) async => (await ImageStore.I.get(p)) != null;

  /// Pictures already on the device. Replaceable in tests.
  @visibleForTesting
  Future<Set<String>> Function(List<String> paths) havePages = (p) => ImageStore.I.which(p);

  /// Instant start-up count: saved pictures from one folder listing. Replaceable in tests.
  @visibleForTesting
  Set<String> Function(Iterable<String> paths) indexPagesSync = (paths) {
    final names = ImageStore.I.savedNamesSync();
    return {for (final p in paths) if (names.contains(ImageStore.keyFor(p))) p};
  };

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
    images = images.copyWith(running: true, manual: true, checking: true, checked: 0);
    online = true; // like the original button: always try the network
    notifyListeners();
    await sync();
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
    // Settings → "सिर्फ़ WiFi पर डाउनलोड": background downloads wait for WiFi. A tap on
    // सिंक (manual) is the user's own choice and always runs.
    if (!manual && _wifiOnly() && !onWifi) {
      _images = _images.copyWith(running: false);
      return;
    }
    final g = _imageGroups();
    final all = [...g.first, ...g.rest];
    if (all.isEmpty) {
      if (manual) _setImages(const ImageProgress(0, 0, false, manual: true));
      return;
    }
    // A background pass is already running: it is incremental, so just run once more after it
    // (never two downloads at once, and the running one is not thrown away).
    if (_saveActive && !manual && !verify) {
      _saveAgain = true;
      return;
    }
    final run = ++_saveRun;
    _saveActive = true;
    _saveAgain = false;
    final shownAt = DateTime.now();
    if (manual) {
      _setImages(images.copyWith(done: savedPages, total: all.length, running: true, checking: verify, manual: true, checked: 0, failed: 0, lowSpace: false));
    }
    () async {
      try {
        await _savePass(run, g.first, g.rest, all, verify: verify, manual: manual, shownAt: shownAt);
      } catch (e) {
        debugPrint('savePages: $e');
      } finally {
        if (run == _saveRun) {
          _saveActive = false;
          if (_saveAgain) {
            _saveAgain = false;
            savePages();
          }
        }
      }
    }();
  }

  bool _saveActive = false;
  bool _saveAgain = false;

  /// Pictures that failed recently: background passes leave them alone for a while (so the
  /// 2-minute sync doesn't keep popping up the progress pill); the सिंक button tries them.
  final Map<String, DateTime> _failedAt = {};
  static const _failedPause = Duration(minutes: 15);

  Future<void> _savePass(int run, List<String> first, List<String> rest, List<String> all,
      {required bool verify, required bool manual, required DateTime shownAt}) async {
    final Set<String> have;
    if (verify) {
      // Repair pass: every saved picture is checked; missing / empty / damaged files are
      // deleted here and downloaded again below. The count shown stays the real one.
      have = await verifyPages(all, (n) {
        if (run != _saveRun || !manual) return;
        _images = _images.copyWith(checked: n);
        _showSoon();
      });
    } else {
      have = await havePages(all);
    }
    if (run != _saveRun) return;
    // The disk is the truth (keeps what landed meanwhile from pictures opened on screen).
    _saved
      ..removeWhere((p) => _all.contains(p) && !have.contains(p))
      ..addAll(have);
    final now = DateTime.now();
    _failedAt.removeWhere((_, t) => now.difference(t) > _failedPause);
    bool want(String p) => !_saved.contains(p) && (manual || !_failedAt.containsKey(p));
    final a = first.where(want).toList();
    final b = rest.where(want).toList();
    if (!online || error == kStaleError) {
      // No internet right now: only the check ran; missing pictures download on the next sync.
      a.clear();
      b.clear();
    }
    final missing = a.length + b.length;
    _setImages(images.copyWith(done: savedPages, total: all.length, running: missing > 0 || manual, checking: false, manual: manual));
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
            _failedAt.remove(list[i]);
            pageSaved(list[i], true);
          } else {
            failed.add(list[i]);
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
    final at = DateTime.now();
    for (final p in failed) {
      _failedAt[p] = at;
    }
    if (manual) {
      // A tap on सिंक always shows its result (e.g. 985 / 985) for a moment.
      final left = minManualShow - DateTime.now().difference(shownAt);
      if (left > Duration.zero) {
        _setImages(images.copyWith(done: savedPages, total: all.length, running: true, failed: failed.length, manual: true, checking: false));
        await Future<void>.delayed(left);
        if (run != _saveRun) return;
      }
    }
    final done = savedPages;
    images = images.copyWith(done: done, total: all.length, running: false, failed: failed.length, lowSpace: lowSpace, manual: manual, checking: false);
    if (lowSpace) error = kLowSpaceStop;
    // A granth is offline when all of its pictures are saved.
    markOffline(granths.where((e) => _granthPaths(e).every(_saved.contains)).map((e) => e.id));
    notifyListeners();
    if (done >= all.length) _celebrate(all);
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
    _saveActive = false;
    _saveAgain = false;
    images = images.copyWith(running: false, checking: false);
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
    _saveSub?.cancel();
    _countTimer?.cancel();
    progress.dispose();
    lastSync.dispose();
    super.dispose();
  }
}
