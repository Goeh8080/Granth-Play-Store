import 'dart:async';

import 'package:flutter/foundation.dart';

import 'native_bridge.dart';
import 'pdf_queue.dart';
import 'storage.dart';

/// Status-bar side of PDF making (Android foreground service `PdfService`).
///
/// While PDFs are being made: one ongoing notification "2 PDF बन रही हैं — 45%" that keeps
/// the app alive in the background. When the last one ends the service stops. Each
/// finished PDF gets a "PDF तैयार" notification that opens it.
class PdfNotify {
  PdfNotify._();
  static final PdfNotify I = PdfNotify._();

  /// Native calls; replaceable in tests.
  @visibleForTesting
  Future<void> Function(String method, Map<String, Object?> args) call = NativeBridge.pdfNotice;

  bool _attached = false;
  bool _running = false;
  int _lastPercent = -1;
  int _lastCount = -1;
  int _lastAt = 0;
  Timer? _trail;

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
  }

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
        call('pdfStop', const {});
      }
      return;
    }
    if (!_running) {
      _running = true;
      _askOnce();
    }
    final pct = q.overallPercent;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (count == _lastCount && pct == _lastPercent) return;
    // At most ~2 updates a second (Android drops faster ones anyway).
    if (count == _lastCount && now - _lastAt < 500) {
      _trail ??= Timer(const Duration(milliseconds: 520), () {
        _trail = null;
        _onQueue();
      });
      return;
    }
    _lastAt = now;
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

  /// Android 13+: ask for the notification permission the first time a PDF starts. PDFs are
  /// made the same way if it is refused.
  void _askOnce() {
    try {
      if (Store.I.getString(Store.kNotifAsked) == '1') return;
      Store.I.setString(Store.kNotifAsked, '1');
    } catch (_) {}
    call('askNotifications', const {});
  }

  /// "PDF तैयार" notification; [uri] is the Downloads copy (opens the PDF when tapped).
  void done(PdfJob job, String? uri) => call('pdfDone', {'id': job.id.hashCode & 0x7fffffff, 'name': job.fileName, 'uri': uri});
}
