/// Extra things the AI can lean on besides the pramans: the admin's Key Notes
/// (`GET /ai/knowledge.json`, cached on disk with its ETag) and the catalog's topics.
///
/// They go to the Worker as ordinary `/ask` candidates (the Worker is unchanged) with ids that can
/// never clash with a praman id: notes are [kNoteIdBase] + id, topics [kTopicIdBase] + id.
/// Offline or on any error the AI simply has no extra candidates.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../config.dart';
import '../models/models.dart';
import '../services/storage.dart';
import 'retriever.dart';

const int kNoteIdBase = 1000000000;
const int kTopicIdBase = 1500000000;
const String kNoteLabel = 'admin नोट';
const String kTopicLabel = 'विषय';

/// How many extra candidates are added to an ask (the Worker takes 12 in all).
const int kMaxNoteCands = 2;
const int kMaxTopicCands = 2;

bool isNoteId(int id) => id >= kNoteIdBase && id < kTopicIdBase;
bool isTopicId(int id) => id >= kTopicIdBase;

class AdminNote {
  const AdminNote({
    required this.id,
    required this.question,
    required this.answer,
    this.tags = const [],
  });
  final int id;
  final String question;
  final String answer;
  final List<String> tags;

  static AdminNote? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'], q = j['question'], a = j['answer'];
    if (id is! int ||
        id <= 0 ||
        id >= kNoteIdBase ||
        q is! String ||
        a is! String) {
      return null;
    }
    if (q.trim().isEmpty || a.trim().isEmpty) return null;
    return AdminNote(
      id: id,
      question: q.trim(),
      answer: a.trim(),
      tags: [
        if (j['tags'] is List)
          for (final t in j['tags'] as List)
            if (t is String && t.trim().isNotEmpty) t.trim(),
      ],
    );
  }
}

/// Parses a `knowledge.json` body; null when it is not a schema-1 document. Never throws.
({int version, List<AdminNote> notes})? parseKnowledge(String body) {
  try {
    if (body.length > 2 * 1024 * 1024) return null;
    final j = jsonDecode(body);
    if (j is! Map || j['schema'] != 1 || j['items'] is! List) return null;
    final notes = <AdminNote>[];
    final seen = <int>{};
    for (final e in j['items'] as List) {
      final n = AdminNote.fromJson(e);
      if (n != null && seen.add(n.id)) notes.add(n);
      if (notes.length >= 500) break;
    }
    return (
      version: j['version'] is int ? j['version'] as int : 0,
      notes: notes,
    );
  } catch (_) {
    return null;
  }
}

class AdminKnowledge extends ChangeNotifier {
  AdminKnowledge({Dio? dio, String? base, bool? enabled})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 8),
              responseType: ResponseType.plain,
            ),
          ),
      base = (base ?? kAdminBase).replaceAll(RegExp(r'/+$'), ''),
      enabled = enabled ?? !Platform.environment.containsKey('FLUTTER_TEST');
  static AdminKnowledge I = AdminKnowledge();

  static const fileName = 'ai_knowledge.json';
  static const kEtag = 'granth-ai-kb-etag';

  final Dio _dio;
  final String base;

  /// Off under `flutter test` unless a test builds its own instance.
  bool enabled;

  List<AdminNote> notes = const [];
  int version = 0;
  bool _loaded = false;
  bool _haveCopy =
      false; // a valid copy is on disk (so a 304 has something to mean)
  Future<bool>? _running;
  String lastResult = 'none';

  /// Reads the saved copy once (no network).
  Future<void> loadCached() async {
    if (_loaded) return;
    _loaded = true;
    final text = await Store.I.readText(fileName);
    final p = text == null ? null : parseKnowledge(text);
    if (p == null) {
      if (text != null) unawaited(Store.I.remove(kEtag));
      return;
    }
    _haveCopy = true;
    _set(p.version, p.notes);
  }

  void _set(int v, List<AdminNote> n) {
    version = v;
    notes = n;
    _ix = null;
    notifyListeners();
  }

  /// Conditional GET. True when the notes changed. Never throws; offline keeps the saved copy.
  Future<bool> refresh() =>
      _running ??= _refresh().whenComplete(() => _running = null);

  Future<bool> _refresh() async {
    if (!enabled) return false;
    try {
      await loadCached();
      final etag = Store.I.getString(kEtag);
      final r = await _dio.get<String>(
        '$base/ai/knowledge.json',
        options: Options(
          headers: {
            if (etag != null && etag.isNotEmpty && _haveCopy)
              'If-None-Match': etag,
          },
          validateStatus: (s) => s != null && (s == 200 || s == 304),
        ),
      );
      if (r.statusCode == 304) {
        lastResult = 'unchanged';
        return false;
      }
      final body = r.data ?? '';
      final p = parseKnowledge(body);
      if (p == null) {
        lastResult = 'ignored';
        return false;
      }
      final changed = p.version != version || p.notes.length != notes.length;
      final tag = r.headers.value('etag');
      await Store.I.writeText(fileName, body);
      if (tag != null && tag.isNotEmpty) await Store.I.setString(kEtag, tag);
      _haveCopy = true;
      lastResult = 'updated';
      if (changed) _set(p.version, p.notes);
      return changed;
    } catch (_) {
      lastResult = 'failed';
      return false;
    }
  }

  // ---- retrieval over the notes ------------------------------------------------------------

  RetrievalIndex? _ix;
  Future<RetrievalIndex>? _building;

  Future<RetrievalIndex> _index() {
    final ix = _ix;
    if (ix != null) return Future.value(ix);
    final mine = notes;
    final f = _building ??=
        compute(buildIndexFromMaps, [
          for (final n in mine)
            <String>['${n.id}', n.question, n.answer, n.tags.join(' '), '', ''],
        ]).then((v) {
          if (identical(notes, mine)) _ix = v;
          return v;
        });
    f.whenComplete(() {
      if (identical(_building, f)) _building = null;
    });
    return f;
  }

  /// The best notes for [question] (at most [max]); each must be a real match, not one stray word.
  Future<List<AdminNote>> best(
    String question, {
    int max = kMaxNoteCands,
  }) async {
    if (notes.isEmpty) return const [];
    final ix = await _index();
    final hits = searchIndex(ix, question, k: max + 2);
    if (hits.isEmpty) return const [];
    final byId = {for (final n in notes) n.id: n};
    final top = hits.first.score;
    return [
      for (final h in hits)
        if (h.score >= math.max(1.0, top * 0.5) && byId[h.id] != null)
          byId[h.id]!,
    ].take(max).toList();
  }

  /// The notes as `/ask` candidates: id [kNoteIdBase] + note id, labelled as admin notes.
  Future<List<Candidate>> candidates(String question) async {
    try {
      return [
        for (final n in await best(question))
          Candidate(
            id: kNoteIdBase + n.id,
            title: _clip(n.question, 160),
            text: _clip(n.answer, 500),
            granth: kNoteLabel,
          ),
      ];
    } catch (_) {
      return const [];
    }
  }

  @visibleForTesting
  void debugReset() {
    notes = const [];
    version = 0;
    _loaded = false;
    _haveCopy = false;
    _ix = null;
    _building = null;
    lastResult = 'none';
  }
}

String _clip(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length <= max ? t : '${t.substring(0, max - 1).trimRight()}…';
}

/// The catalog's topics as candidates (a topic is a claim that pramans prove): id [kTopicIdBase] + id.
class TopicSource {
  TopicSource._();
  static final TopicSource I = TopicSource._();

  RetrievalIndex? _ix;
  int _version = -1;
  Map<int, Topic> _byId = const {};
  Future<RetrievalIndex>? _building;

  void reset() {
    _ix = null;
    _version = -1;
    _building = null;
  }

  Future<List<Candidate>> candidates(
    List<Topic> topics,
    int version,
    String question, {
    int max = kMaxTopicCands,
  }) async {
    try {
      if (topics.isEmpty) return const [];
      if (_ix == null || _version != version) {
        _version = version;
        _byId = {
          for (final t in topics)
            if (int.tryParse(t.id) != null) int.parse(t.id): t,
        };
        final v = version;
        final f = compute(buildIndexFromMaps, [
          for (final t in topics)
            <String>[t.id, t.title, t.description, '', '', ''],
        ]);
        _building = f;
        final ix = await f;
        if (_version != v) return const [];
        _ix = ix;
      }
      final hits = searchIndex(_ix ?? await _building!, question, k: max + 2);
      if (hits.isEmpty) return const [];
      final top = hits.first.score;
      final out = <Candidate>[];
      for (final h in hits) {
        final t = _byId[h.id];
        if (t == null || h.score < math.max(1.0, top * 0.5)) continue;
        final text = t.description.trim().isEmpty
            ? '${t.title} — ${t.pramanCount} प्रमाण'
            : '${t.title} — ${t.description}';
        out.add(
          Candidate(
            id: kTopicIdBase + h.id,
            title: _clip(t.title, 160),
            text: _clip(text, 500),
            granth: kTopicLabel,
          ),
        );
        if (out.length >= max) break;
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
