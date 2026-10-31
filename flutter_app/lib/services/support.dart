/// Support tickets (CONTRACT §5.1): a daily IST token per ticket, admin replies, follow-ups.
/// Anonymous: identified only by the install id. Offline → a Hindi error, nothing is lost
/// (the text stays in the box until it is sent).
library;

import 'dart:convert';
import 'dart:io' show Platform;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import 'analytics.dart';

class SupportMsg {
  const SupportMsg(this.fromAdmin, this.text, this.at);
  final bool fromAdmin;
  final String text, at;
}

class SupportTicket {
  SupportTicket(this.raw);
  final Map<String, dynamic> raw;
  int get id => (raw['id'] as num?)?.toInt() ?? 0;
  int get token => (raw['token'] as num?)?.toInt() ?? 0;
  String get date => '${raw['date'] ?? ''}';
  String get subject => '${raw['subject'] ?? ''}';
  String get message => '${raw['message'] ?? ''}';
  bool get open => raw['status'] != 'closed';
  bool get hasNewReply => raw['has_new_reply'] == true;
  List<SupportMsg> get messages => [
    for (final m in (raw['messages'] is List ? raw['messages'] as List : const []))
      if (m is Map) SupportMsg(m['from'] == 'admin', '${m['text'] ?? ''}', '${m['at'] ?? ''}'),
  ];

  /// "टोकन #3 · 31-10-2026" (date is the IST date from the server).
  String get label {
    final p = date.split('-');
    final d = p.length == 3 ? '${p[2]}-${p[1]}-${p[0]}' : date;
    return 'टोकन #$token · $d';
  }
}

class SupportService extends ChangeNotifier {
  SupportService({Dio? dio, String? base, String Function()? iid, bool? enabled})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              sendTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 10),
              responseType: ResponseType.plain,
              validateStatus: (s) => s != null && s < 600,
            ),
          ),
      base = (base ?? kAdminBase).replaceAll(RegExp(r'/+$'), ''),
      _iid = iid,
      enabled = enabled ?? !Platform.environment.containsKey('FLUTTER_TEST');
  static SupportService I = SupportService();

  final Dio _dio;
  final String base;
  final String Function()? _iid;
  bool enabled;
  List<SupportTicket> tickets = [];
  int unread = 0;
  bool loading = false;
  String? error;

  String get iid => _iid?.call() ?? Analytics.I.iid;
  Map<String, String> get _headers => {'Content-Type': 'application/json', if (kAppKey.isNotEmpty) 'X-App-Key': kAppKey.trim()};

  static String errorText(int? status, String body) {
    if (status == 429) return 'आज की सीमा पूरी हो गई। कृपया कल फिर लिखें।';
    if (status == 409) return 'यह टिकट बंद हो चुका है। नया टिकट बनाएँ।';
    if (status == 400) return 'संदेश 2 से 2000 अक्षरों का होना चाहिए।';
    if (status == 413) return 'संदेश बहुत लंबा है।';
    if (status == 503) return 'सहायता सेवा अभी उपलब्ध नहीं है। थोड़ी देर बाद कोशिश करें।';
    return 'नेटवर्क नहीं मिला। कृपया फिर कोशिश करें।';
  }

  Future<({int? status, Object? json})> _call(String method, String path, [Map<String, dynamic>? body]) async {
    if (!enabled || base.isEmpty) return (status: null, json: null);
    try {
      final r = await _dio.request<String>(
        '$base$path',
        data: body == null ? null : jsonEncode(body),
        options: Options(method: method, headers: _headers),
      );
      Object? j;
      try {
        j = jsonDecode(r.data ?? '');
      } catch (_) {}
      return (status: r.statusCode, json: j);
    } catch (_) {
      return (status: null, json: null);
    }
  }

  Future<void> refresh() async {
    loading = true;
    error = null;
    notifyListeners();
    final r = await _call('GET', '/support/tickets/mine?iid=$iid');
    loading = false;
    final j = r.json;
    if (r.status == 200 && j is Map && j['items'] is List) {
      tickets = [
        for (final e in j['items'] as List)
          if (e is Map<String, dynamic>) SupportTicket(e),
      ];
      unread = (j['unread'] as num?)?.toInt() ?? 0;
    } else {
      error = errorText(r.status, '');
    }
    notifyListeners();
  }

  /// New ticket. Returns null (ok) or a Hindi error.
  Future<String?> create(String message, {String subject = '', String name = '', String contact = ''}) async {
    final m = message.trim();
    if (m.runes.length < 2 || m.runes.length > 2000) return errorText(400, '');
    final r = await _call('POST', '/support/tickets', {
      'iid': iid,
      'message': m,
      if (subject.trim().isNotEmpty) 'subject': _cut(subject.trim(), 120),
      if (name.trim().isNotEmpty) 'name': _cut(name.trim(), 60),
      if (contact.trim().isNotEmpty) 'contact': _cut(contact.trim(), 100),
      'app_version': kAppVersion,
    });
    if (r.status == 201 || r.status == 200) {
      await refresh();
      return null;
    }
    return errorText(r.status, '');
  }

  Future<String?> reply(int id, String message) async {
    final m = message.trim();
    if (m.runes.length < 2 || m.runes.length > 2000) return errorText(400, '');
    final r = await _call('POST', '/support/tickets/$id/messages', {'iid': iid, 'message': m});
    if (r.status == 201 || r.status == 200) {
      await refresh();
      return null;
    }
    return errorText(r.status, '');
  }

  /// Marks the admin replies as seen.
  Future<void> ack(List<int> ids) async {
    if (ids.isEmpty) return;
    final r = await _call('POST', '/support/tickets/ack', {'iid': iid, 'ids': ids.take(50).toList()});
    if (r.status == 200) {
      for (final t in tickets) {
        if (ids.contains(t.id)) t.raw['has_new_reply'] = false;
      }
      unread = tickets.where((t) => t.hasNewReply).length;
      notifyListeners();
    }
  }

  static String _cut(String s, int n) => s.runes.length <= n ? s : String.fromCharCodes(s.runes.take(n));
}
