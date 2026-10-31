import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'storage.dart';

/// The user's own on-device usage numbers for the Account page (never sent anywhere, not GA4).
/// Fed from [Analytics.fb], so every event the app logs is counted once, here, on the phone.
class LocalStats extends ChangeNotifier {
  LocalStats._();
  static final LocalStats I = LocalStats._();

  static const kStats = 'granth-local-stats';
  static const counted = {'app_open', 'granth_open', 'praman_open', 'pdf_download', 'pdf_generate', 'ai_ask'};
  static const _maxDays = 4000;

  Map<String, Object?>? _m;
  Map<String, Object?> get _data {
    if (_m != null) return _m!;
    Object? j;
    try {
      j = jsonDecode(Store.I.getString(kStats) ?? '{}');
    } catch (_) {}
    return _m = j is Map ? Map<String, Object?>.from(j) : <String, Object?>{};
  }

  int count(String event) => (_data[event] as num?)?.toInt() ?? 0;

  /// Distinct calendar days (device time) on which the app was opened.
  int get daysActive => (_data['days'] as List?)?.length ?? 0;

  /// First day the app was opened (yyyy-mm-dd), or null.
  String? get since => (_data['days'] as List?)?.cast<String>().firstOrNull;

  static String _day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  void record(String event, {DateTime? now}) {
    if (!counted.contains(event)) return;
    final d = _data;
    d[event] = count(event) + 1;
    if (event == 'app_open') {
      final days = [...((d['days'] as List?)?.cast<String>() ?? const <String>[])];
      final t = _day(now ?? DateTime.now());
      if (!days.contains(t)) days.add(t);
      d['days'] = days.length > _maxDays ? days.sublist(days.length - _maxDays) : days;
    }
    Store.I.setString(kStats, jsonEncode(d));
    notifyListeners();
  }

  @visibleForTesting
  void debugReset() => _m = null;
}
