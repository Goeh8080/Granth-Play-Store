import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, gzip;
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';

import '../config.dart';
import '../models/structure.dart' show kOtherId;
import '../state/router.dart';
import 'device_profile.dart';
import 'remote_config.dart';
import 'storage.dart';

/// Anonymous usage counts for the admin's dashboard (docs/AI.md → "Analytics").
///
/// What leaves the phone — and nothing else — is the body of `POST /events` described in the
/// server contract: a random install id, app version, Android API level, config version, the UTC
/// day, foreground seconds, session count, how many times each granth / folder / topic / praman
/// was opened, foreground seconds per granth / folder / screen, sync and PDF success/failure
/// counts, and AI ask/answer/citation-tap counts. No account, name, phone number, device id, IP
/// (the server does not keep it), question text or chat text.
///
/// Everything is fire-and-forget: nothing here awaits on the UI path, any error is swallowed,
/// and nothing is sent unless the remote config's `analytics_enabled` is on and this install is
/// inside `analytics_sample`.
class Analytics with WidgetsBindingObserver {
  Analytics({Dio? dio, DateTime Function()? now, RemoteConfig Function()? config, String? url, bool? enabled})
      : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8), sendTimeout: const Duration(seconds: 8), receiveTimeout: const Duration(seconds: 8))),
        _now = now ?? DateTime.now,
        _cfg = config ?? (() => RemoteConfig.I),
        url = url ?? kEventsUrl,
        enabledByBuild = enabled ?? !Platform.environment.containsKey('FLUTTER_TEST');

  static Analytics I = Analytics();

  static const kIid = 'granth-iid';
  static const kDayCount = 'granth-an-day';
  static const queueFile = 'analytics_queue.json';
  static const maxQueue = 20;
  static const maxBatchesPerDay = 5; // the server accepts 6 per install per day
  static const maxBody = 7500; // the server's limit is 8192 B after gunzip

  final Dio _dio;
  final DateTime Function() _now;
  final RemoteConfig Function() _cfg;
  final String url;

  /// False under `flutter test` unless a test builds its own instance.
  final bool enabledByBuild;

  String? _iid;
  bool _started = false;
  bool _foreground = true;
  List<Map<String, dynamic>> _queue = [];

  // ---- accumulators of the current UTC day ----
  String _day = '';
  int _sessions = 0;
  int _fgMs = 0;
  final Map<String, int> _openG = {}, _openF = {}, _openT = {}, _openP = {};
  final Map<String, int> _watchG = {}, _watchF = {}, _watchScr = {}; // milliseconds
  int _syncOk = 0, _syncFail = 0, _pdfOk = 0, _pdfFail = 0, _aiAsked = 0, _aiAnswered = 0, _aiCite = 0;
  final Map<String, int> _syncKinds = {}, _pdfKinds = {};

  // ---- the segment being timed (foreground only) ----
  DateTime? _segStart;
  String _scr = 'home';
  String? _segGranth, _segFolder;
  String _lastRouteKey = '';

  String get day => _day;

  // ------------------------------------------------------------------ switches
  bool get enabled {
    if (!enabledByBuild) return false;
    final c = _cfg();
    return c.analyticsEnabled && sampled;
  }

  /// Decided once per install: a stable hash of the install id against `analytics_sample`.
  bool get sampled {
    final s = _cfg().analyticsSample;
    if (s >= 1) return true;
    if (s <= 0) return false;
    final id = _iid ?? iid;
    final h = int.parse(id.substring(0, 8), radix: 16) / 0x100000000;
    return h < s;
  }

  /// Random 128-bit install id (32 hex). Not derived from anything on the phone.
  String get iid {
    var v = _iid ?? Store.I.getString(kIid);
    if (v == null || !RegExp(r'^[0-9a-f]{32}$').hasMatch(v)) {
      v = _hex(16);
      unawaited(Store.I.setString(kIid, v));
    }
    return _iid = v;
  }

  static String _hex(int bytes) {
    final r = math.Random.secure();
    return [for (var i = 0; i < bytes; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  // ------------------------------------------------------------------ lifecycle
  /// Called once after the first frame. Never blocks startup.
  void start() {
    if (_started) return;
    _started = true;
    try {
      WidgetsBinding.instance.addObserver(this);
      AppNav.I.addListener(_onNav);
      _foreground = true;
      unawaited(_loadQueue());
      _rollDay();
      if (enabled) _sessions++;
      _segStart = _now();
      _onNav();
      // The first upload attempt waits a little: the first screen comes first.
      Timer(const Duration(seconds: 20), () => unawaited(flush(force: false)));
    } catch (e) {
      debugPrint('analytics: start: $e');
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    try {
      if (state == AppLifecycleState.resumed) {
        if (!_foreground) {
          _foreground = true;
          _segStart = _now();
          if (enabled) _sessions++;
        }
      } else if (state == AppLifecycleState.paused || state == AppLifecycleState.detached) {
        if (_foreground) {
          _closeSeg();
          _foreground = false;
          unawaited(flush(force: true));
        }
      }
    } catch (e) {
      debugPrint('analytics: lifecycle: $e');
    }
  }

  // ------------------------------------------------------------------ events
  void _onNav() {
    try {
      final r = AppNav.I.route;
      if (r.key == _lastRouteKey) return;
      _lastRouteKey = r.key;
      _closeSeg();
      _scr = screenName(r);
      _segGranth = r.granthId;
      _segFolder = r.religionId == null || r.groupId == null ? null : [r.religionId, r.groupId, r.subId].nonNulls.join('/');
      if (r.religionId == kOtherId) _segFolder = kOtherId;
      if (!enabled) return;
      _rollDay();
      if (r.granthId != null) _bump(_openG, r.granthId!);
      if (_segFolder != null) _bump(_openF, _segFolder!);
      if (r.topicId != null) _bump(_openT, 't');
      if (r.pramanId != null) _bump(_openP, 'p');
      if (_segStart == null && _foreground) _segStart = _now();
    } catch (e) {
      debugPrint('analytics: nav: $e');
    }
  }

  static String screenName(GRoute r) => switch (r.panel) {
        Panel.dashboard => 'home',
        Panel.topics => 'topics',
        Panel.granths => r.religionId == null ? (r.flat ? 'granths' : 'folders') : 'folder',
        Panel.pramans => (r.granthId != null || r.pramanId != null) ? 'reader' : 'pramans',
        Panel.gallery => 'gallery',
        Panel.ai => 'ai',
        Panel.legal => r.legalPage == 'contacts' ? 'contacts' : 'legal',
      };

  /// Counts are clamped at 5000 (the server's limit); time maps hold milliseconds and are clamped
  /// at 2 h (the server's 7200 s) via [cap].
  void _bump(Map<String, int> m, String k, [int by = 1, int cap = 5000]) {
    if (m.containsKey(k) || m.length < 200) m[k] = math.min(cap, (m[k] ?? 0) + by);
  }

  void _closeSeg() {
    final s = _segStart;
    _segStart = null;
    if (s == null || !enabled) return;
    final ms = _now().difference(s).inMilliseconds;
    if (ms <= 0) return;
    // A segment longer than 2 h is a phone left on a table: cap it.
    final c = math.min(ms, 7200000);
    _rollDay();
    _fgMs += c;
    _bump(_watchScr, _scr, c, 7200000);
    if (_segGranth != null) _bump(_watchG, _segGranth!, c, 7200000);
    if (_segFolder != null) _bump(_watchF, _segFolder!, c, 7200000);
  }

  void syncResult(bool ok, [String kind = 'other']) {
    if (!enabled) return;
    if (ok) {
      _syncOk = math.min(5000, _syncOk + 1);
    } else {
      _syncFail = math.min(5000, _syncFail + 1);
      _bump(_syncKinds, _kind(kind));
    }
  }

  void pdfResult(bool ok, [String kind = 'other']) {
    if (!enabled) return;
    if (ok) {
      _pdfOk = math.min(5000, _pdfOk + 1);
    } else {
      _pdfFail = math.min(5000, _pdfFail + 1);
      _bump(_pdfKinds, _kind(kind));
    }
  }

  void aiAsked() {
    if (enabled) _aiAsked = math.min(5000, _aiAsked + 1);
  }

  void aiAnswered() {
    if (enabled) _aiAnswered = math.min(5000, _aiAnswered + 1);
  }

  void aiCiteTap() {
    if (enabled) _aiCite = math.min(5000, _aiCite + 1);
  }

  static String _kind(String k) {
    final s = k.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_]'), '_');
    return s.isEmpty ? 'other' : (s.length > 24 ? s.substring(0, 24) : s);
  }

  /// Classify an exception into a short, fixed kind (never the message text).
  static String kindOf(Object e) {
    if (e is DioException) {
      return switch (e.type) {
        DioExceptionType.connectionTimeout || DioExceptionType.sendTimeout || DioExceptionType.receiveTimeout => 'timeout',
        DioExceptionType.connectionError => 'network',
        DioExceptionType.badResponse => 'http_${e.response?.statusCode ?? 0}',
        _ => 'other',
      };
    }
    final m = '$e'.toLowerCase();
    if (m.contains('space') || m.contains('enospc')) return 'nospace';
    if (m.contains('timeout')) return 'timeout';
    if (m.contains('socket') || m.contains('network') || m.contains('connection')) return 'network';
    if (m.contains('format') || m.contains('parse')) return 'parse';
    return 'other';
  }

  // ------------------------------------------------------------------ batches
  String _utcDay() {
    final u = _now().toUtc();
    return '${u.year.toString().padLeft(4, '0')}-${u.month.toString().padLeft(2, '0')}-${u.day.toString().padLeft(2, '0')}';
  }

  /// A new UTC day: the old day's counts become a batch of their own.
  void _rollDay() {
    final d = _utcDay();
    if (_day.isEmpty) {
      _day = d;
      return;
    }
    if (d != _day) {
      final seg = _segStart; // keep timing across midnight
      _enqueueCurrent();
      _day = d;
      _segStart = seg;
    }
  }

  bool get _hasData => _fgMs >= 1000 || _openG.isNotEmpty || _openF.isNotEmpty || _openT.isNotEmpty || _openP.isNotEmpty || _syncOk + _syncFail + _pdfOk + _pdfFail + _aiAsked + _aiAnswered + _aiCite > 0;

  Map<String, int> _secs(Map<String, int> ms) {
    final e = ms.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return {
      for (final x in e.take(60))
        if (x.value >= 1000) x.key: math.min(7200, (x.value / 1000).round()),
    };
  }

  Map<String, int> _top(Map<String, int> m) {
    final e = m.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return {for (final x in e.take(60)) x.key: math.min(5000, x.value)};
  }

  Map<String, dynamic> _build() => {
        'v': 1,
        'batch_id': _hex(16),
        'iid': iid,
        'app': kAppFull,
        'os': 'android',
        'sdk': DeviceProfile.I.sdk.clamp(0, 99),
        'cfg': _cfg().cfgVersion,
        'day': _day,
        'fg_s': math.min(21600, (_fgMs / 1000).round()),
        'sessions': math.min(5000, _sessions),
        'open': {'g': _top(_openG), 'f': _top(_openF), 't': _top(_openT), 'p': _top(_openP)},
        'watch_s': {'g': _secs(_watchG), 'f': _secs(_watchF), 'scr': _secs(_watchScr)},
        'sync': {'ok': _syncOk, 'fail': _syncFail, 'kinds': _top(_syncKinds)},
        'pdf': {'ok': _pdfOk, 'fail': _pdfFail, 'kinds': _top(_pdfKinds)},
        'ai': {'asked': _aiAsked, 'answered': _aiAnswered, 'cite_tap': _aiCite},
      };

  void _resetAcc() {
    _sessions = 0;
    _fgMs = 0;
    for (final m in [_openG, _openF, _openT, _openP, _watchG, _watchF, _watchScr, _syncKinds, _pdfKinds]) {
      m.clear();
    }
    _syncOk = _syncFail = _pdfOk = _pdfFail = _aiAsked = _aiAnswered = _aiCite = 0;
  }

  /// Day counter in prefs: "YYYY-MM-DD:n" — batches made on that UTC day.
  int _madeToday() {
    final v = Store.I.getString(kDayCount) ?? '';
    final p = v.split(':');
    return p.length == 2 && p[0] == _utcDay() ? (int.tryParse(p[1]) ?? 0) : 0;
  }

  void _enqueueCurrent() {
    if (!enabled || !_hasData || _day.isEmpty) return;
    if (_madeToday() >= maxBatchesPerDay) return; // keep counting; goes out with a later batch
    final b = _build();
    if (utf8.encode(jsonEncode(b)).length > maxBody) {
      for (final k in const ['f', 'g']) {
        (b['watch_s'] as Map)[k] = <String, int>{};
      }
      (b['open'] as Map)['p'] = <String, int>{};
    }
    _queue.add(b);
    while (_queue.length > maxQueue) {
      _queue.removeAt(0);
    }
    _resetAcc();
    unawaited(Store.I.setString(kDayCount, '${_utcDay()}:${_madeToday() + 1}'));
    unawaited(_saveQueue());
  }

  Future<void>? _loading;
  Future<void> _loadQueue() => _loading ??= _doLoad();

  Future<void> _doLoad() async {
    try {
      final t = await Store.I.readText(queueFile);
      if (t != null) {
        final l = jsonDecode(t);
        if (l is List) _queue = [for (final e in l) if (e is Map) e.cast<String, dynamic>()] + _queue;
      }
    } catch (_) {}
  }

  Future<void> _saveQueue() async {
    try {
      await _loadQueue();
      await Store.I.writeText(queueFile, jsonEncode(_queue));
    } catch (_) {}
  }

  bool _sending = false;

  /// Close the current day's counts into a batch (if [force] and there is something) and try to
  /// upload every waiting batch. Never throws.
  Future<void> flush({bool force = false}) async {
    try {
      if (!enabled) {
        if (_queue.isNotEmpty) {
          _queue.clear();
          unawaited(_saveQueue());
        }
        return;
      }
      await _loadQueue();
      if (_foreground) {
        // Time the foreground segment up to now, then keep timing.
        _closeSeg();
        _segStart = _now();
      }
      if (force || _fgMs >= 600000) _enqueueCurrent();
      await _send();
    } catch (e) {
      debugPrint('analytics: flush: $e');
    }
  }

  Future<void> _send() async {
    if (_sending) return;
    _sending = true;
    try {
      while (_queue.isNotEmpty && enabled) {
        final b = _queue.first;
        // The server only takes days within ±2 of today; older ones would just be dropped.
        final d = DateTime.tryParse('${b['day']}T00:00:00Z');
        if (d == null || _now().toUtc().difference(d).inDays > 2) {
          _queue.removeAt(0);
          continue;
        }
        final bytes = gzip.encode(utf8.encode(jsonEncode(b)));
        try {
          final res = await _dio.post<void>(
            url,
            data: Uint8List.fromList(bytes),
            options: Options(
              headers: {'Content-Type': 'application/json', 'Content-Encoding': 'gzip'},
              validateStatus: (_) => true,
              responseType: ResponseType.plain,
            ),
          );
          final code = res.statusCode ?? 0;
          if (code == 204 || (code >= 200 && code < 300) || (code >= 400 && code < 500 && code != 429)) {
            _queue.removeAt(0); // accepted, or refused for its content: never resend
          } else {
            break; // 429 / 5xx: try again next time, same batch_id
          }
        } catch (_) {
          break; // offline: keep the batch (same batch_id) for the next attempt
        }
      }
    } finally {
      _sending = false;
      await _saveQueue();
    }
  }

  // ------------------------------------------------------------------ tests
  List<Map<String, dynamic>> get debugQueue => List.unmodifiable(_queue);
  void debugReset() {
    _resetAcc();
    _queue = [];
    _loading = null;
    _day = '';
    _segStart = null;
    _lastRouteKey = '';
    _iid = null;
  }
}
