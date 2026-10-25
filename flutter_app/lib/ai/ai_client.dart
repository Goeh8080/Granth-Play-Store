/// The network half of "तत्त्व AI से पूछे": one POST to the AI Worker. Plain `dart:io` (no new
/// package). The app never holds a provider key: the Worker does.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../config.dart';
import '../services/remote_config.dart';
import 'retriever.dart';

/// One earlier turn sent along as context.
class AiTurn {
  const AiTurn(this.role, this.text);
  final String role; // 'user' | 'assistant'
  final String text;
  Map<String, String> toJson() => {'role': role, 'text': text};
}

/// What the Worker answered.
class AiAnswer {
  const AiAnswer({required this.answer, required this.cited, required this.provider});
  final String answer;
  final List<int> cited;
  final String provider;
}

enum AiFailure { offline, timeout, rateLimited, unavailable, rejected, tooLarge, badReply }

/// A failure with a message the user can read (Hindi) and whether trying again may help.
class AiException implements Exception {
  const AiException(this.kind, this.message, {this.status});
  final AiFailure kind;
  final String message;
  final int? status;

  bool get retryable => kind != AiFailure.rejected && kind != AiFailure.tooLarge;
  @override
  String toString() => 'AiException($kind, status=$status)';
}

const int kQuestionMax = 500;
const int kHistoryTurns = 4;
const int kHistoryTextMax = 600;
const int kCandidatesMax = 12;

String _cut(String s, int max) {
  final r = s.runes.toList();
  return r.length <= max ? s : String.fromCharCodes(r.take(max));
}

/// The JSON body of `POST /ask`, with every limit of the contract applied.
Map<String, Object> buildAskBody(String question, List<AiTurn> history, List<Candidate> candidates) {
  final turns = history.where((t) => t.text.trim().isNotEmpty && (t.role == 'user' || t.role == 'assistant')).toList();
  final last = turns.length > kHistoryTurns ? turns.sublist(turns.length - kHistoryTurns) : turns;
  return {
    'question': _cut(question.trim(), kQuestionMax),
    'history': [for (final t in last) AiTurn(t.role, _cut(t.text.trim(), kHistoryTextMax)).toJson()],
    'candidates': [for (final c in candidates.take(kCandidatesMax)) c.toJson()],
  };
}

/// Praman ids from the `cited` field: numbers or numeric strings, no repeats, no junk.
List<int> parseCited(Object? raw) {
  if (raw is! List) return const [];
  final out = <int>[];
  for (final e in raw) {
    final v = e is num ? e.toInt() : int.tryParse('$e'.trim());
    if (v != null && v > 0 && !out.contains(v)) out.add(v);
  }
  return out;
}

String _messageFor(AiFailure k) => switch (k) {
      AiFailure.offline => 'इंटरनेट से जुड़ नहीं पाया। कनेक्शन जाँचकर फिर कोशिश करें।',
      AiFailure.timeout => 'उत्तर आने में बहुत समय लग रहा है। कृपया फिर कोशिश करें।',
      AiFailure.rateLimited => 'अभी बहुत प्रश्न आ रहे हैं। थोड़ी देर बाद फिर कोशिश करें।',
      AiFailure.unavailable => 'AI सेवा अभी उपलब्ध नहीं है। थोड़ी देर बाद फिर कोशिश करें।',
      AiFailure.rejected => 'यह प्रश्न स्वीकार नहीं हुआ। कृपया इसे छोटा या अलग तरह से लिखें।',
      AiFailure.tooLarge => 'प्रश्न बहुत बड़ा है। कृपया इसे छोटा करके पूछें।',
      AiFailure.badReply => 'AI से समझ न आने वाला उत्तर मिला। कृपया फिर कोशिश करें।',
    };

/// Turns an HTTP status + body into an answer or an [AiException]. Pure, so it is unit-tested.
AiAnswer parseAskResponse(int status, String body) {
  Object? json;
  try {
    json = jsonDecode(body);
  } catch (_) {
    json = null;
  }
  if (status == 200) {
    if (json is Map && json['error'] == null) {
      final a = json['answer'];
      if (a is String && a.trim().isNotEmpty) {
        final p = json['provider'];
        return AiAnswer(answer: a.trim(), cited: parseCited(json['cited']), provider: p is String ? p : '');
      }
    }
    throw AiException(AiFailure.badReply, _messageFor(AiFailure.badReply), status: status);
  }
  final k = switch (status) {
    429 => AiFailure.rateLimited,
    413 => AiFailure.tooLarge,
    400 || 403 || 404 || 405 => AiFailure.rejected,
    _ => AiFailure.unavailable,
  };
  throw AiException(k, _messageFor(k), status: status);
}

class AiClient {
  AiClient({
    String? endpoint,
    this.timeout = const Duration(seconds: 45),
    this.backoff = const Duration(milliseconds: 1500),
    this.header = kAiClientHeader,
  }) : endpoint = (endpoint ?? RemoteConfig.I.aiEndpoint ?? kAiEndpoint).replaceAll(RegExp(r'/+$'), '');

  final String endpoint;
  final Duration timeout;
  final Duration backoff;
  final String header;

  /// Asks once; on a timeout, a network error, a 429 or a 5xx it waits a little and asks once more.
  Future<AiAnswer> ask(String question, List<AiTurn> history, List<Candidate> candidates) async {
    final body = jsonEncode(buildAskBody(question, history, candidates));
    try {
      return await _once(body);
    } on AiException catch (e) {
      if (!e.retryable) rethrow;
      await Future<void>.delayed(e.kind == AiFailure.rateLimited ? backoff * 2 : backoff);
      return _once(body);
    }
  }

  Future<AiAnswer> _once(String body) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
    try {
      return await _send(client, body).timeout(timeout);
    } on TimeoutException {
      throw AiException(AiFailure.timeout, _messageFor(AiFailure.timeout));
    } on SocketException {
      throw AiException(AiFailure.offline, _messageFor(AiFailure.offline));
    } on HandshakeException {
      throw AiException(AiFailure.offline, _messageFor(AiFailure.offline));
    } on HttpException {
      throw AiException(AiFailure.unavailable, _messageFor(AiFailure.unavailable));
    } finally {
      client.close(force: true);
    }
  }

  Future<AiAnswer> _send(HttpClient client, String body) async {
    final req = await client.postUrl(Uri.parse('$endpoint/ask'));
    req.headers
      ..contentType = ContentType('application', 'json', charset: 'utf-8')
      ..set('X-Granth-Client', header)
      ..set('Accept', 'application/json');
    final bytes = utf8.encode(body);
    req.contentLength = bytes.length;
    req.add(bytes);
    final res = await req.close();
    final text = await res.transform(utf8.decoder).join();
    return parseAskResponse(res.statusCode, text);
  }
}
