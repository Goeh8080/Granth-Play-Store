/// 👍 / 👎 under each AI reply (round 14). A 👎 (with an optional reason) is meant for the
/// admin: it is queued on the phone and sent to `POST {kAdminBase}/ai/flags` (see
/// /workspace/round14_backend_needs.md). That endpoint does not exist yet: a 404/405/5xx or no
/// net keeps the item queued (≤ [kMaxQueue], newest kept) and the next sync tries again. Never
/// throws, never shows an error; the user's own vote is stored locally either way.
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import 'analytics.dart';
import 'storage.dart';

const int kMaxQueue = 50;

class AiFeedback extends ChangeNotifier {
  AiFeedback({Dio? dio, String? base, String? appKey, String Function()? iid, bool? enabled})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 600,
            ),
          ),
      base = (base ?? kAdminBase).replaceAll(RegExp(r'/+$'), ''),
      appKey = (appKey ?? kAppKey).trim(),
      _iid = iid,
      enabled = enabled ?? !Platform.environment.containsKey('FLUTTER_TEST');
  static AiFeedback I = AiFeedback();

  static const kVotes = 'granth-ai-votes'; // {"<msg key>": 1 | -1}
  static const kQueue = 'granth-ai-flagq'; // [ {question, answer, reason, at, ...} ]

  final Dio _dio;
  final String base;
  final String appKey;
  final String Function()? _iid;
  bool enabled;
  bool _flushing = false;

  String get iid => (_iid ?? () => Analytics.I.iid)();

  Map<String, dynamic> _map(String k) {
    try {
      final j = jsonDecode(Store.I.getString(k) ?? '');
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return {};
  }

  List<Map<String, dynamic>> get queue {
    try {
      final j = jsonDecode(Store.I.getString(kQueue) ?? '');
      if (j is List) {
        return [
          for (final e in j)
            if (e is Map<String, dynamic>) e,
        ];
      }
    } catch (_) {}
    return [];
  }

  /// 1, -1 or 0 (no vote).
  int vote(String key) => switch (_map(kVotes)[key]) {
    1 => 1,
    -1 => -1,
    _ => 0,
  };

  void up(String key) => _setVote(key, vote(key) == 1 ? 0 : 1);

  void _setVote(String key, int v) {
    final m = _map(kVotes);
    if (v == 0) {
      m.remove(key);
    } else {
      m[key] = v;
    }
    // Keep the map small: the 300 newest votes are plenty.
    while (m.length > 300) {
      m.remove(m.keys.first);
    }
    Store.I.setString(kVotes, jsonEncode(m));
    notifyListeners();
  }

  /// 👎: records the vote, queues the report and tries to send it now.
  Future<void> down(String key, {required String question, required String answer, String reason = '', String chat = ''}) async {
    _setVote(key, -1);
    final q = queue
      ..removeWhere((e) => e['key'] == key)
      ..add({'key': key, 'question': _cut(question, 500), 'answer': _cut(answer, 2000), 'reason': _cut(reason.trim(), 300), 'chat': chat, 'at': DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000});
    while (q.length > kMaxQueue) {
      q.removeAt(0);
    }
    Store.I.setString(kQueue, jsonEncode(q));
    await flush();
  }

  static String _cut(String s, int n) => s.runes.length > n ? String.fromCharCodes(s.runes.take(n)) : s;

  /// Sends the queued reports; each one leaves the queue only after a 2xx (or a 400, which a
  /// retry can never fix). Returns how many were sent.
  Future<int> flush() async {
    if (!enabled || _flushing || base.isEmpty) return 0;
    _flushing = true;
    var sent = 0;
    try {
      for (final item in queue) {
        int? status;
        try {
          final r = await _dio.post<String>(
            '$base/ai/flags',
            data: jsonEncode({'iid': iid, 'kind': 'thumbs_down', 'lang': 'hi', 'app_version': kAppVersion, ...item}..remove('key')),
            options: Options(contentType: 'application/json', headers: {if (appKey.isNotEmpty) 'X-App-Key': appKey}, responseType: ResponseType.plain, validateStatus: (s) => s != null && s < 600),
          );
          status = r.statusCode;
        } catch (_) {
          status = null;
        }
        final done = status != null && ((status >= 200 && status < 300) || status == 400 || status == 413);
        if (!done) break; // offline / endpoint missing / busy: keep the rest for later
        final rest = queue..removeWhere((e) => e['key'] == item['key']);
        Store.I.setString(kQueue, jsonEncode(rest));
        sent++;
      }
    } finally {
      _flushing = false;
    }
    return sent;
  }

  @visibleForTesting
  void debugReset() {
    Store.I.remove(kVotes);
    Store.I.remove(kQueue);
  }
}
