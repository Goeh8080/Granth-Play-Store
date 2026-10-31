/// The user ↔ admin question channel (round 13), all anonymous (the install id of the analytics).
///
/// * [AdminSync.sendQuestion]: "क्या आप यह प्रश्न admin को भेजना चाहेंगे?" → `POST /ai/questions`.
///   At most [kDailyQuestions] new questions a day per install, checked here too.
/// * [AdminSync.poll]: `GET /ai/answers` inside the 2-minute sync cycle and on start / resume. Each
///   answer is handed to [deliver] (it must store it in the chat); only after that it is marked done
///   and `POST /ai/answers/ack`ed. A duplicate poll never adds a second message.
///
/// Offline, a 4xx/5xx or a bad reply never throws and never shows an error out of the blue.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../ai/chat_controller.dart';
import '../config.dart';
import 'analytics.dart';
import 'native_bridge.dart';
import 'storage.dart';

const int kDailyQuestions = 5;
const String kAnswerNoticeTitle = 'आपका उत्तर आ गया है';

enum AskResult {
  sent,
  duplicate,
  dailyLimit,
  rateLimited,
  offline,
  invalid,
  unavailable,
}

class AskOutcome {
  const AskOutcome(this.result, this.message, {this.id});
  final AskResult result;

  /// Friendly Hindi text for the user.
  final String message;
  final int? id;
  bool get ok => result == AskResult.sent || result == AskResult.duplicate;

  /// Trying again later can work (so the Yes button stays).
  bool get canRetry =>
      result == AskResult.offline ||
      result == AskResult.unavailable ||
      result == AskResult.rateLimited;
}

const _msgSent =
    'आपका प्रश्न admin को भेज दिया गया है। उत्तर आते ही वह यहीं इस चैट में दिखेगा, और सूचना भी आएगी।';
const _msgDup =
    'यह प्रश्न admin को पहले ही भेजा जा चुका है। उत्तर आते ही वह यहीं दिखेगा।';
const _msgDaily =
    'आज आप $kDailyQuestions प्रश्न भेज चुके हैं। कृपया कल फिर भेजिए।';
const _msgRate =
    'अभी admin तक प्रश्न नहीं पहुँच पाया — कुछ देर बाद फिर कोशिश कीजिए। (आज की सीमा पूरी हो चुकी हो सकती है।)';
const _msgOffline =
    'इंटरनेट नहीं मिला, इसलिए प्रश्न नहीं भेजा जा सका। नेट चालू करके फिर कोशिश कीजिए।';
const _msgInvalid =
    'यह प्रश्न भेजा नहीं जा सका। कृपया उसे छोटा और साफ़ करके लिखिए।';
const _msgDown =
    'admin की सेवा अभी तैयार नहीं है। कुछ देर बाद फिर कोशिश कीजिए।';

/// One answer from the server.
class AdminAnswer {
  const AdminAnswer({
    required this.id,
    required this.question,
    required this.answer,
    required this.answeredAt,
  });
  final int id;
  final String question;
  final String answer;
  final int answeredAt;

  /// The dedupe key (a re-answered question comes back with a new `answered_at`).
  String get ref => '$id@$answeredAt';

  static AdminAnswer? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], a = j['answer'];
    if (id is! int || id <= 0 || a is! String || a.trim().isEmpty) return null;
    return AdminAnswer(
      id: id,
      question: j['question'] is String ? (j['question'] as String).trim() : '',
      answer: a.trim(),
      answeredAt: j['answered_at'] is int ? j['answered_at'] as int : 0,
    );
  }
}

/// Stores one answer in the chat; true only when it is safely saved (or was already there).
typedef AnswerSink = Future<bool> Function(AdminAnswer a, String? convId);

bool _anyStatus(int? s) => s != null && s < 600;

class AdminSync {
  AdminSync({
    Dio? dio,
    String? base,
    String? appKey,
    String Function()? iid,
    DateTime Function()? now,
    bool? enabled,
    AnswerSink? deliver,
    Future<void> Function(int count, String text)? notify,
  }) : _dio =
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
       _now = now ?? DateTime.now,
       enabled = enabled ?? !Platform.environment.containsKey('FLUTTER_TEST'),
       _deliver = deliver,
       _notify = notify;
  static AdminSync I = AdminSync();

  static const kDay =
      'granth-ai-qday'; // "YYYY-MM-DD:n" (UTC day, like the server's)
  static const kAsked =
      'granth-ai-asked'; // '1' once a question was sent: only then is the server polled
  static const kDone = 'granth-ai-ans-done'; // answer refs already stored
  static const kConvMap = 'granth-ai-qconv'; // {"<question id>": "<chat id>"}

  /// Poll at most this often unless forced (start / resume): the server allows 60 an hour.
  static const minPollGap = Duration(seconds: 100);
  static const backoff = Duration(minutes: 30);

  final Dio _dio;
  final String base;
  final String appKey;
  final String Function()? _iid;
  final DateTime Function() _now;
  final AnswerSink? _deliver;
  final Future<void> Function(int count, String text)? _notify;

  /// Off under `flutter test` unless a test builds its own instance.
  bool enabled;

  bool _polling = false;
  DateTime? _lastPoll;
  DateTime? _blockedUntil;
  String lastResult = 'none';

  String get iid => (_iid ?? () => Analytics.I.iid)();

  // ---- sending a question ------------------------------------------------------------------

  String _today() {
    final d = _now().toUtc();
    return '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// Questions sent today (UTC day).
  int get sentToday {
    final v = Store.I.getString(kDay);
    if (v == null) return 0;
    final i = v.indexOf(':');
    if (i < 0 || v.substring(0, i) != _today()) return 0;
    return int.tryParse(v.substring(i + 1)) ?? 0;
  }

  bool get limitReached => sentToday >= kDailyQuestions;
  bool get hasAsked => Store.I.getString(kAsked) == '1';

  Future<void> _setToday(int n) => Store.I.setString(kDay, '${_today()}:$n');

  /// Sends [question] to the admin ([convId]: the chat the answer should come back to).
  Future<AskOutcome> sendQuestion(String question, {String? convId}) async {
    final q = question.trim();
    if (q.runes.length < 3) {
      return const AskOutcome(AskResult.invalid, _msgInvalid);
    }
    if (limitReached) return const AskOutcome(AskResult.dailyLimit, _msgDaily);
    if (!enabled) return const AskOutcome(AskResult.unavailable, _msgDown);
    try {
      final body = {
        'iid': iid,
        'question': String.fromCharCodes(q.runes.take(500)),
        'lang': 'hi',
      };
      final r = await _dio.post<String>(
        '$base/ai/questions',
        data: jsonEncode(body),
        options: Options(
          contentType: 'application/json',
          responseType: ResponseType.plain,
          validateStatus: _anyStatus,
          headers: {if (appKey.isNotEmpty) 'X-App-Key': appKey},
        ),
      );
      final s = r.statusCode ?? 0;
      if (s == 202 || s == 200 || s == 201) {
        final j = _json(r.data);
        final id = j is Map && j['id'] is int ? j['id'] as int : null;
        final dup = j is Map && j['duplicate'] == true;
        if (!dup) await _setToday(sentToday + 1);
        await Store.I.setString(kAsked, '1');
        if (id != null && convId != null) await _rememberConv(id, convId);
        return AskOutcome(
          dup ? AskResult.duplicate : AskResult.sent,
          dup ? _msgDup : _msgSent,
          id: id,
        );
      }
      if (s == 429) return const AskOutcome(AskResult.rateLimited, _msgRate);
      if (s == 400 || s == 413 || s == 422) {
        return const AskOutcome(AskResult.invalid, _msgInvalid);
      }
      return const AskOutcome(AskResult.unavailable, _msgDown);
    } on DioException catch (e) {
      final offline =
          e.type == DioExceptionType.connectionError ||
          e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.sendTimeout ||
          e.type == DioExceptionType.receiveTimeout ||
          e.error != null && e.response == null;
      return AskOutcome(
        offline ? AskResult.offline : AskResult.unavailable,
        offline ? _msgOffline : _msgDown,
      );
    } catch (_) {
      return const AskOutcome(AskResult.unavailable, _msgDown);
    }
  }

  Object? _json(String? t) {
    try {
      return t == null || t.isEmpty ? null : jsonDecode(t);
    } catch (_) {
      return null;
    }
  }

  Map<String, String> _convMap() {
    final j = _json(Store.I.getString(kConvMap));
    return j is Map
        ? {
            for (final e in j.entries)
              if (e.key is String && e.value is String)
                e.key as String: e.value as String,
          }
        : {};
  }

  Future<void> _rememberConv(int qid, String convId) async {
    final m = _convMap()..['$qid'] = convId;
    while (m.length > 50) {
      m.remove(m.keys.first);
    }
    await Store.I.setString(kConvMap, jsonEncode(m));
  }

  // ---- answers -----------------------------------------------------------------------------

  Set<String> _doneSet() => {
    for (final r in (Store.I.getString(kDone) ?? '').split(','))
      if (r.isNotEmpty) r,
  };

  Future<void> _markDone(String ref) async {
    final l = _doneSet().toList()..add(ref);
    final keep = l.length > 300 ? l.sublist(l.length - 300) : l;
    await Store.I.setString(kDone, keep.join(','));
  }

  /// Fetches the answers; returns how many NEW messages were stored. Never throws.
  Future<int> poll({bool force = false}) async {
    if (!enabled || _polling) return 0;
    if (!hasAsked) return 0;
    final now = _now();
    if (_blockedUntil != null && now.isBefore(_blockedUntil!)) return 0;
    if (!force && _lastPoll != null && now.difference(_lastPoll!) < minPollGap) {
      return 0;
    }
    _polling = true;
    _lastPoll = now;
    var added = 0;
    String? firstText;
    try {
      String? since;
      for (var page = 0; page < 5; page++) {
        final r = await _dio.get<String>(
          '$base/ai/answers',
          queryParameters: {'iid': iid, 'limit': 20, 'since': ?since},
          options: Options(responseType: ResponseType.plain, validateStatus: _anyStatus),
        );
        final s = r.statusCode ?? 0;
        if (s == 429) {
          _blockedUntil = _now().add(backoff);
          lastResult = 'limited';
          break;
        }
        final j = _json(r.data);
        if (s != 200 || j is! Map || j['items'] is! List) {
          lastResult = 'failed';
          break;
        }
        lastResult = 'ok';
        final done = _doneSet();
        final conv = _convMap();
        final ack = <int>[];
        for (final e in (j['items'] as List).take(20)) {
          final a = AdminAnswer.fromJson(e);
          if (a == null) continue;
          if (done.contains(a.ref)) {
            ack.add(a.id); // stored earlier, the ack just did not get through
            continue;
          }
          bool stored;
          try {
            stored = await (_deliver ?? _defaultDeliver)(a, conv['${a.id}']);
          } catch (_) {
            stored = false;
          }
          if (!stored) {
            continue; // not saved → not marked, not acked: it comes again
          }
          await _markDone(a.ref);
          done.add(a.ref);
          ack.add(a.id);
          added++;
          firstText ??= a.answer;
        }
        if (ack.isNotEmpty) await _ack(ack);
        final next = j['next_since'];
        if (j['has_more'] == true && next != null && '$next' != since) {
          since = '$next';
          continue;
        }
        break;
      }
    } catch (_) {
      lastResult = 'failed';
    } finally {
      _polling = false;
    }
    if (added > 0) {
      try {
        await (_notify ?? _defaultNotify)(added, firstText ?? '');
      } catch (_) {}
    }
    return added;
  }

  Future<void> _ack(List<int> ids) async {
    try {
      await _dio.post<String>(
        '$base/ai/answers/ack',
        data: jsonEncode({'iid': iid, 'ids': ids.take(50).toList()}),
        options: Options(contentType: 'application/json', responseType: ResponseType.plain, validateStatus: _anyStatus),
      );
    } catch (_) {
      // Not acked: the server sends them again and the done-set drops the duplicates.
    }
  }

  Future<bool> _defaultDeliver(AdminAnswer a, String? convId) =>
      ChatController.I.deliverAdminAnswer(a, convId);

  Future<void> _defaultNotify(int count, String text) {
    final one = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final body = count > 1
        ? 'admin के $count संदेश आए हैं — ऐप खोलकर देखें'
        : (one.length > 90 ? '${one.substring(0, 89)}…' : one);
    return NativeBridge.pdfNotice('answerNotice', {
      'title': kAnswerNoticeTitle,
      'text': body.isEmpty ? 'admin का संदेश आया है' : body,
    });
  }

  @visibleForTesting
  void debugReset() {
    _lastPoll = null;
    _blockedUntil = null;
    _polling = false;
    lastResult = 'none';
  }
}
