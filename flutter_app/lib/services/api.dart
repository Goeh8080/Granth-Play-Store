import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../models/models.dart';

const kOrigin = 'https://granth.wnmsolutions.com';
const kShareBase = 'https://granth.grok.me/open';

final RegExp _mediaPath = RegExp(r'^(granths|uploads)/[A-Za-z0-9_.-]+$');

/// Same rules as `Kt()` in the web bundle: only `granths/…` and `uploads/…` are images.
String? mediaPath(String? input) {
  if (input == null) return null;
  var t = input.trim();
  if (t.isEmpty) return null;
  if (t.startsWith('http://') || t.startsWith('https://')) {
    final u = Uri.tryParse(t);
    if (u == null) return null;
    t = u.path;
  }
  t = t.replaceFirst(RegExp(r'^/+'), '');
  return _mediaPath.hasMatch(t) ? t : null;
}

String mediaUrl(String path) => '$kOrigin/$path';

/// `ge()` — share link used by the original app.
String shareLink(String kind, String id) => id.isEmpty ? 'granth://open' : '$kShareBase?${kind == 'praman' ? 'id' : kind}=${Uri.encodeComponent(id)}';

/// `Xt()` — YouTube id extraction.
String? youtubeId(String? input) {
  final t = (input ?? '').trim();
  if (t.isEmpty) return null;
  if (RegExp(r'^[\w-]{11}$').hasMatch(t)) return t;
  return RegExp(r'(?:embed/|v=|youtu\.be/)([\w-]{11})').firstMatch(t)?.group(1);
}

class Api {
  Api({Dio? dio, this.timeout = const Duration(seconds: 20)})
      : dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 10),
              receiveTimeout: const Duration(seconds: 15),
            ));
  final Dio dio;

  /// Upper bound for one whole catalog fetch, so a stalled network can never hang a sync.
  final Duration timeout;

  Future<List<Map<String, dynamic>>> _list(String request) async {
    // The server answers JSON with `Content-Type: text/html`, so Dio would hand back a raw
    // String for ResponseType.json. Always read plain text and decode it ourselves.
    final r = await dio.get<dynamic>(
      '$kOrigin/api/index.php',
      queryParameters: {'request': request},
      options: Options(responseType: ResponseType.plain),
    );
    return decodeApiList(r.data, request);
  }

  Future<Catalog> fetchCatalog() async {
    final res = await Future.wait([_list('getTopics'), _list('getGranths'), _list('getPramans')]).timeout(timeout);
    return applyCatalogRules(Catalog(
      topics: res[0].map(Topic.new).toList(),
      granths: res[1].map(Granth.new).toList(),
      pramans: res[2].map(Praman.new).toList(),
      syncedAt: DateTime.now().millisecondsSinceEpoch,
    ));
  }
}

/// Accepts the API body as a decoded Map or as raw JSON text (any content type, optional BOM)
/// and returns the `data` list, or throws a [FormatException]/[StateError].
@visibleForTesting
List<Map<String, dynamic>> decodeApiList(Object? data, String request) {
  Object? body = data;
  if (body is List<int>) body = utf8.decode(body, allowMalformed: true);
  if (body is String) {
    var t = body.trim();
    if (t.startsWith('\uFEFF')) t = t.substring(1);
    body = jsonDecode(t);
  }
  if (body is! Map || body['success'] != true || body['data'] is! List) throw StateError('$request empty');
  return (body['data'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
}

/// `qe()` with no local drafts: drop pramans whose granth is missing and recompute counts.
Catalog applyCatalogRules(Catalog c) {
  final granthIds = c.granths.map((g) => g.id).toSet();
  final pramans = c.pramans.where((p) => p.granthId.isEmpty || granthIds.contains(p.granthId)).toList();
  final byGranth = <String, int>{};
  final byTopic = <String, int>{};
  for (final p in pramans) {
    byGranth[p.granthId] = (byGranth[p.granthId] ?? 0) + 1;
    byTopic[p.topicId] = (byTopic[p.topicId] ?? 0) + 1;
  }
  final granthByTopic = <String, int>{};
  for (final g in c.granths) {
    final t = '${g.raw['topic_id'] ?? ''}';
    if (t.isNotEmpty && t != 'null') granthByTopic[t] = (granthByTopic[t] ?? 0) + 1;
  }
  return Catalog(
    topics: c.topics
        .map((t) => Topic({...t.raw, 'granth_count': '${granthByTopic[t.id] ?? 0}', 'praman_count': '${byTopic[t.id] ?? 0}'}))
        .toList(),
    granths: c.granths.map((g) => Granth({...g.raw, 'pramanCount': '${byGranth[g.id] ?? 0}'})).toList(),
    pramans: pramans,
    syncedAt: c.syncedAt,
  );
}
