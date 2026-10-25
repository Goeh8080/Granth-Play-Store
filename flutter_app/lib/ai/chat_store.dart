/// Local chat history for "तत्त्व AI से पूछे": one JSON file per conversation under
/// `<app folder>/chats/` plus a small `index.json`. Every write is atomic (temp file + rename,
/// via [Store]); no database. The history never leaves the phone except the last few turns that
/// go with a question (see docs/AI.md).
library;

import 'dart:async';
import 'dart:io';

import '../services/storage.dart';

const int kMaxChats = 50;
const int kMaxMessages = 60;
const int kMaxMessageChars = 8000;
const int kTitleChars = 48;

class ChatMsg {
  const ChatMsg({required this.role, required this.text, this.cited = const [], this.at = 0});
  final String role; // 'user' | 'assistant'
  final String text;

  /// Praman ids the answer cited (assistant messages only).
  final List<int> cited;
  final int at;

  bool get isUser => role == 'user';

  Map<String, Object> toJson() => {'role': role, 'text': text, if (cited.isNotEmpty) 'cited': cited, 'at': at};

  static ChatMsg? fromJson(Object? j) {
    if (j is! Map) return null;
    final role = j['role'];
    final text = j['text'];
    if ((role != 'user' && role != 'assistant') || text is! String) return null;
    final c = j['cited'];
    return ChatMsg(
      role: role as String,
      text: text.length > kMaxMessageChars ? text.substring(0, kMaxMessageChars) : text,
      cited: [if (c is List) for (final e in c) if (e is int) e],
      at: j['at'] is int ? j['at'] as int : 0,
    );
  }
}

class Conversation {
  Conversation({required this.id, required this.title, required this.created, required this.updated, List<ChatMsg>? messages}) : messages = messages ?? [];
  final String id;
  String title;
  final int created;
  int updated;
  final List<ChatMsg> messages;

  /// The last message is a question that has no answer yet (the answer failed or the app was closed).
  bool get pending => messages.isNotEmpty && messages.last.isUser;

  Map<String, Object> toJson() => {'id': id, 'title': title, 'created': created, 'updated': updated, 'messages': [for (final m in messages) m.toJson()]};

  static Conversation? fromJson(Object? j) {
    if (j is! Map) return null;
    final id = j['id'];
    if (id is! String || !_validId(id)) return null;
    final msgs = <ChatMsg>[
      if (j['messages'] is List)
        for (final e in j['messages'] as List)
          ?ChatMsg.fromJson(e),
    ];
    return Conversation(
      id: id,
      title: j['title'] is String ? j['title'] as String : titleFor(msgs.isEmpty ? '' : msgs.first.text),
      created: j['created'] is int ? j['created'] as int : 0,
      updated: j['updated'] is int ? j['updated'] as int : 0,
      messages: msgs,
    );
  }

  ConversationInfo get info => ConversationInfo(id: id, title: title, updated: updated, count: messages.length);
}

/// A row of the conversations list.
class ConversationInfo {
  const ConversationInfo({required this.id, required this.title, required this.updated, required this.count});
  final String id;
  final String title;
  final int updated;
  final int count;
  Map<String, Object> toJson() => {'id': id, 'title': title, 'updated': updated, 'count': count};
  static ConversationInfo? fromJson(Object? j) {
    if (j is! Map || j['id'] is! String || !_validId(j['id'] as String)) return null;
    return ConversationInfo(
      id: j['id'] as String,
      title: j['title'] is String ? j['title'] as String : '',
      updated: j['updated'] is int ? j['updated'] as int : 0,
      count: j['count'] is int ? j['count'] as int : 0,
    );
  }
}

bool _validId(String s) => RegExp(r'^[a-z0-9]{6,32}$').hasMatch(s);

/// The auto-title: the first question, one line, cut at a word boundary where possible.
String titleFor(String firstQuestion) {
  final t = firstQuestion.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return 'नई बातचीत';
  final r = t.runes.toList();
  if (r.length <= kTitleChars) return t;
  var cut = String.fromCharCodes(r.take(kTitleChars));
  final sp = cut.lastIndexOf(' ');
  if (sp > kTitleChars ~/ 2) cut = cut.substring(0, sp);
  return '$cut…';
}

class ChatStore {
  ChatStore._();
  static ChatStore I = ChatStore._();

  /// For tests: a fresh store.
  static ChatStore fresh() => ChatStore._();

  Future<void>? _tail;

  /// Runs [job] after every earlier write, so two quick saves never interleave.
  Future<T> _queue<T>(Future<T> Function() job) {
    final c = Completer<T>();
    Future<void> run() async {
      try {
        c.complete(await job());
      } catch (e, s) {
        c.completeError(e, s);
      }
    }

    final prev = _tail;
    _tail = prev == null ? run() : prev.then((_) => run());
    return c.future;
  }

  Directory get _dir => Directory('${Store.I.root.path}/chats');
  static const _index = 'chats/index.json';
  String _file(String id) => 'chats/$id.json';

  Future<void> _ensureDir() async {
    if (!await _dir.exists()) await _dir.create(recursive: true);
  }

  /// Newest first. A missing or damaged index is rebuilt from the conversation files.
  Future<List<ConversationInfo>> list() => _queue(_list);

  Future<List<ConversationInfo>> _list() async {
    if (!Store.I.ready) return [];
    final j = await Store.I.readJson(_index);
    List<ConversationInfo>? out;
    if (j is List) {
      out = [
        for (final e in j)
          ?ConversationInfo.fromJson(e),
      ];
    }
    if (out == null) {
      out = [];
      try {
        if (await _dir.exists()) {
          for (final f in _dir.listSync()) {
            if (f is! File || !f.path.endsWith('.json') || f.path.endsWith('/index.json')) continue;
            final id = f.uri.pathSegments.last.replaceAll('.json', '');
            final c = await _read(id);
            if (c != null) out.add(c.info);
          }
        }
      } catch (_) {}
    }
    out.sort((a, b) => b.updated.compareTo(a.updated));
    return out;
  }

  Future<Conversation?> load(String id) => _queue(() => _read(id));

  Future<Conversation?> _read(String id) async {
    if (!Store.I.ready || !_validId(id)) return null;
    return Conversation.fromJson(await Store.I.readJson(_file(id)));
  }

  /// Saves [c] (trimmed to the caps) and returns the new list. Old conversations beyond [kMaxChats] go.
  Future<List<ConversationInfo>> save(Conversation c) => _queue(() async {
        if (!Store.I.ready) return <ConversationInfo>[];
        await _ensureDir();
        if (c.messages.length > kMaxMessages) c.messages.removeRange(0, c.messages.length - kMaxMessages);
        await Store.I.writeJson(_file(c.id), c.toJson());
        final all = (await _list()).where((e) => e.id != c.id).toList()..add(c.info);
        all.sort((a, b) => b.updated.compareTo(a.updated));
        for (final old in all.skip(kMaxChats).toList()) {
          await _remove(old.id);
        }
        final kept = all.take(kMaxChats).toList();
        await Store.I.writeJson(_index, [for (final e in kept) e.toJson()]);
        return kept;
      });

  Future<void> _remove(String id) async {
    try {
      final f = File('${Store.I.root.path}/${_file(id)}');
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  Future<List<ConversationInfo>> delete(String id) => _queue(() async {
        if (!Store.I.ready || !_validId(id)) return <ConversationInfo>[];
        await _remove(id);
        final left = (await _list()).where((e) => e.id != id).toList();
        await _ensureDir();
        await Store.I.writeJson(_index, [for (final e in left) e.toJson()]);
        return left;
      });

  /// "चैट इतिहास मिटाएँ": every conversation file and the index.
  Future<void> clearAll() => _queue(() async {
        if (!Store.I.ready) return;
        try {
          if (await _dir.exists()) await _dir.delete(recursive: true);
        } catch (_) {}
      });

  /// How much room the history takes (shown next to the clear button).
  Future<int> bytes() => _queue(() async {
        var n = 0;
        try {
          if (await _dir.exists()) {
            for (final f in _dir.listSync()) {
              if (f is File) n += f.lengthSync();
            }
          }
        } catch (_) {}
        return n;
      });
}

/// A fresh id: time + counter, lower-case letters and digits only (it becomes a file name).
String newChatId() {
  final t = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
  _seq = (_seq + 1) % 1296;
  return '$t${_seq.toRadixString(36).padLeft(2, '0')}';
}

int _seq = 0;
