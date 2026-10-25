/// The state of "तत्त्व AI से पूछे", kept for the whole session so that opening a praman from an
/// answer and pressing Back returns to the same chat (nothing here lives in a widget).
library;

import 'package:flutter/widgets.dart';

import '../models/models.dart';
import '../services/analytics.dart';
import '../services/catalog_store.dart';
import 'ai_client.dart';
import 'chat_store.dart';
import 'retriever.dart';

class ChatController extends ChangeNotifier {
  ChatController({AiClient? client, ChatStore? store, List<Praman> Function()? pramans, int Function()? version})
      : _client = client,
        _store = store,
        _pramans = pramans,
        _version = version;

  static ChatController I = ChatController();

  final AiClient? _client;
  final ChatStore? _store;
  final List<Praman> Function()? _pramans;
  final int Function()? _version;

  AiClient get client => _client ?? AiClient();
  ChatStore get store => _store ?? ChatStore.I;
  List<Praman> get pramans => (_pramans ?? () => CatalogStore.I.pramans)();
  int get version => (_version ?? () => CatalogStore.I.catalogVersion)();

  /// The text box of the composer lives here so a draft survives a visit to a praman.
  final TextEditingController input = TextEditingController();

  Conversation? current;
  List<ConversationInfo> chats = [];
  bool sending = false;
  AiException? error;
  bool loaded = false;

  /// Bumped when something was added to the open chat (the screen scrolls on it).
  int tick = 0;
  int _run = 0;
  Future<void>? _loading;

  List<ChatMsg> get messages => current?.messages ?? const [];

  /// Loads the history list and reopens the newest chat (once).
  Future<void> load() => _loading ??= _load();

  Future<void> _load() async {
    chats = await store.list();
    if (current == null && chats.isNotEmpty) current = await store.load(chats.first.id);
    loaded = true;
    notifyListeners();
    // Build the retrieval index in the background so the first question is quick.
    if (pramans.isNotEmpty) Retriever.I.ensure(pramans, version).ignore();
  }

  /// Starts an empty chat (the old one stays in the history).
  void newChat() {
    _run++;
    current = null;
    sending = false;
    error = null;
    tick++;
    notifyListeners();
  }

  Future<void> open(String id) async {
    final c = await store.load(id);
    if (c == null) {
      chats = await store.list();
      notifyListeners();
      return;
    }
    _run++;
    current = c;
    sending = false;
    error = null;
    tick++;
    notifyListeners();
  }

  Future<void> delete(String id) async {
    chats = await store.delete(id);
    if (current?.id == id) newChat();
    notifyListeners();
  }

  Future<void> clearAll() async {
    await store.clearAll();
    chats = [];
    newChat();
  }

  /// Asks [raw]. Returns false when nothing was sent (empty text or a question is on its way).
  Future<bool> send(String raw) async {
    final q = raw.trim();
    if (q.isEmpty || sending) return false;
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = current ??= Conversation(id: newChatId(), title: titleFor(q), created: now, updated: now);
    c.messages.add(ChatMsg(role: 'user', text: q.length > kQuestionMax ? q.substring(0, kQuestionMax) : q, at: now));
    c.updated = now;
    error = null;
    sending = true; // locks the composer at once (the save below is asynchronous)
    tick++;
    notifyListeners();
    Analytics.I.aiAsked();
    await _persist(c);
    await _ask(c);
    return true;
  }

  /// "फिर कोशिश करें": asks the last question again.
  Future<void> retry() async {
    final c = current;
    if (c == null || sending || !c.pending) return;
    error = null;
    notifyListeners();
    await _ask(c);
  }

  Future<void> _ask(Conversation c) async {
    final run = ++_run;
    sending = true;
    notifyListeners();
    final question = c.messages.last.text;
    final earlier = c.messages.sublist(0, c.messages.length - 1);
    final history = [for (final m in earlier) AiTurn(m.role, m.text)];
    try {
      final ps = pramans;
      final context = earlier.where((m) => m.isUser).isEmpty ? null : earlier.lastWhere((m) => m.isUser).text;
      final cands = await Retriever.I.candidates(ps, version, question, context: context);
      final a = await client.ask(question, history, cands);
      if (run != _run) return; // the user switched chat meanwhile: this answer is dropped
      final known = <int>[
        for (final id in a.cited)
          if (Retriever.I.praman(id) != null) id,
      ];
      final now = DateTime.now().millisecondsSinceEpoch;
      c.messages.add(ChatMsg(role: 'assistant', text: a.answer.length > kMaxMessageChars ? a.answer.substring(0, kMaxMessageChars) : a.answer, cited: known, at: now));
      c.updated = now;
      sending = false;
      tick++;
      Analytics.I.aiAnswered();
      notifyListeners();
      await _persist(c);
    } on AiException catch (e) {
      if (run != _run) return;
      error = e;
      sending = false;
      notifyListeners();
    } catch (_) {
      if (run != _run) return;
      error = const AiException(AiFailure.unavailable, 'कुछ गड़बड़ हो गई। कृपया फिर कोशिश करें।');
      sending = false;
      notifyListeners();
    }
  }

  Future<void> _persist(Conversation c) async {
    try {
      chats = await store.save(c);
      notifyListeners();
    } catch (_) {
      // A full disk must not break the chat: the conversation just stays in memory.
    }
  }

  @visibleForTesting
  void debugReset() {
    current = null;
    chats = [];
    sending = false;
    error = null;
    loaded = false;
    _loading = null;
    _run++;
    input.clear();
  }
}
