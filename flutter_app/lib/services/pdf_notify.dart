import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'pdf_queue.dart';
import 'storage.dart';

/// Status-bar side of PDF making (Android foreground service `PdfService`).
///
/// While PDFs are being made: one ongoing notification "2 PDF बन रही हैं — 45%" that keeps
/// the app alive in the background. When the last one ends the service stops.
///
/// Round 8 — no spam: finished / failed PDFs are NOT announced one by one. They are counted, and
/// ONE summary notification ("50 PDF तैयार") is posted after the last PDF has ended (fixed id on
/// Android, so it is replaced, never stacked). Fifty PDFs = one progress notification + one summary.
class PdfNotify {
  PdfNotify._();
  static final PdfNotify I = PdfNotify._();

  /// Native calls; replaceable in tests.
  @visibleForTesting
  Future<void> Function(String method, Map<String, Object?> args) call = NativeBridge.pdfNotice;

  /// Native questions with an answer (`notifState`, `askNotifications`); replaceable in tests.
  @visibleForTesting
  Future<Object?> Function(String method, Map<String, Object?> args) query = NativeBridge.pdfQuery;

  /// Bumped when the one-time "notifications are off" hint should be shown (HomeShell shows it).
  final ValueNotifier<int> hint = ValueNotifier(0);

  /// Last check, for logs / tests.
  String lastCheck = '';

  bool _attached = false;
  bool _running = false;
  int _lastPercent = -1;
  int _lastCount = -1;
  int _lastAt = 0;
  Timer? _trail;
  bool _trailing = false;

  /// How long after the last PDF ended (and its Downloads copy was saved) the summary is posted.
  @visibleForTesting
  static Duration summaryDelay = const Duration(milliseconds: 900);
  final List<String> _doneNames = [];
  final Map<String, String> _failed = {}; // job id → title
  String? _lastUri;
  String _lastError = '';
  Timer? _flush;

  void attach() {
    if (_attached) return;
    _attached = true;
    PdfQueue.I.addListener(_onQueue);
  }

  @visibleForTesting
  void debugReset() {
    if (_attached) PdfQueue.I.removeListener(_onQueue);
    _attached = false;
    _running = false;
    _lastPercent = -1;
    _lastCount = -1;
    _lastAt = 0;
    _trail?.cancel();
    _flush?.cancel();
    _doneNames.clear();
    _failed.clear();
    _lastUri = null;
    _lastError = '';
    hint.value = 0;
    lastCheck = '';
  }

  static void _log(String m) => debugPrint('[GranthPdf] $m');

  static String text(int count, int percent) => count == 1 ? '1 PDF बन रही है — $percent%' : '$count PDF बन रही हैं — $percent%';

  void _onQueue() {
    final q = PdfQueue.I;
    final count = q.activeCount;
    if (count == 0) {
      _trail?.cancel();
      if (_running) {
        _running = false;
        _lastPercent = -1;
        _lastCount = -1;
        _log('all PDFs ended → stop service');
        call('pdfStop', const {});
        _schedule();
      }
      return;
    }
    if (!_running) {
      _running = true;
      unawaited(ensurePermission());
    }
    final pct = q.overallPercent;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (count == _lastCount && pct == _lastPercent) return;
    // At most ~2 updates a second, also when the count changes (50 PDFs ending together made 50
    // updates before; Android drops faster ones anyway). The trailing timer posts the last state.
    if (!_trailing && now - _lastAt < 500) {
      _trail ??= Timer(const Duration(milliseconds: 520), () {
        _trail = null;
        _trailing = true; // the trailing post itself is never throttled again
        try {
          _onQueue();
        } finally {
          _trailing = false;
        }
      });
      return;
    }
    _lastAt = now;
    if (count != _lastCount) _log('$count PDF active → progress notification');
    _lastCount = count;
    _lastPercent = pct;
    final first = q.jobs.where((j) => j.active).firstOrNull;
    final waiting = q.jobs.where((j) => j.active).every((j) => j.phase == PdfPhase.waiting && j.attempts > 0);
    call('pdfProgress', {
      'title': count == 1 && first != null ? first.title : text(count, pct),
      'text': waiting ? 'ऐप खोलने पर आगे बनेगी' : text(count, pct),
      'percent': pct,
    });
  }

  /// The first time a PDF starts: make sure its notifications can be seen.
  /// Android 13+: the real permission dialog (once). If notifications are still off (refused,
  /// or switched off by the phone — Vivo-style phones ship new apps with them off), a themed
  /// hint with a button to the app's notification settings is shown, once. PDFs are made the
  /// same way either way.
  Future<void> ensurePermission() async {
    try {
      final st = await query('notifState', const {});
      if (st is! Map) {
        lastCheck = 'no-native';
        return;
      }
      final sdk = st['sdk'] is int ? st['sdk'] as int : 0;
      var enabled = st['enabled'] == true;
      _log('notifState sdk=$sdk granted=${st['granted']} enabled=$enabled');
      if (enabled) {
        lastCheck = 'enabled';
        return;
      }
      if (sdk >= 33 && st['granted'] != true && Store.I.getString(Store.kNotifAsked) != '1') {
        Store.I.setString(Store.kNotifAsked, '1');
        _log('asking POST_NOTIFICATIONS');
        enabled = await query('askNotifications', const {}) == true;
        _log('permission answer: $enabled');
        if (enabled) {
          lastCheck = 'granted';
          return;
        }
      }
      if (Store.I.getString(Store.kNotifHint) == '1') {
        lastCheck = 'off-hint-already-shown';
        return;
      }
      Store.I.setString(Store.kNotifHint, '1');
      lastCheck = 'off-hint';
      hint.value++;
    } catch (e) {
      _log('permission check failed: $e');
    }
  }

  Future<void> openSettings() => query('openNotificationSettings', const {});

  /// A PDF could not be finished (e.g. pages missing, no internet). Counted for the summary; a later
  /// successful retry of the same job takes it back out.
  void failed(PdfJob job) {
    _failed[job.id] = job.title;
    _lastError = job.error ?? '';
    _schedule();
  }

  /// A PDF is finished; [uri] is its Downloads copy (opens the PDF when the summary is tapped and
  /// it is the only one).
  void done(PdfJob job, String? uri) {
    _failed.remove(job.id);
    _doneNames.add(job.fileName);
    _lastUri = uri;
    _schedule();
  }

  void _schedule() {
    _flush?.cancel();
    if (_running) return; // posted when the run ends
    if (_doneNames.isEmpty && _failed.isEmpty) return;
    _flush = Timer(summaryDelay, _post);
  }

  void _post() {
    _flush = null;
    if (_running) return;
    final d = _doneNames.length, f = _failed.length;
    if (d + f == 0) return;
    final names = [..._doneNames.reversed, ..._failed.values].take(5).toList();
    final args = <String, Object?>{
      'done': d,
      'failed': f,
      'names': names,
      'uri': d == 1 && f == 0 ? _lastUri : null,
      'error': d == 0 && f == 1 ? _lastError : '',
    };
    _doneNames.clear();
    _failed.clear();
    _lastUri = null;
    _lastError = '';
    _log('one summary notification: $d done, $f failed');
    call('pdfSummary', args);
  }
}
