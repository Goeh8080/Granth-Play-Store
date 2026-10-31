/// The state of "तत्त्व AI से पूछे", kept for the whole session so that opening a praman from an
/// answer and pressing Back returns to the same chat (nothing here lives in a widget).
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import '../models/models.dart';
import '../services/admin_sync.dart';
import '../services/analytics.dart';
import '../services/catalog_store.dart';
import '../services/pdf_notify.dart';
import 'ai_client.dart';
import 'cannot_answer.dart';
import 'sanitize.dart';
import 'chat_store.dart';
import 'extra_sources.dart';
import 'retriever.dart';

/// "क्या आप यह प्रश्न admin को भेजना चाहेंगे?" — shown under an answer the AI could not give.
/// Shown when the model's reply was empty (or only ids).
const kEmptyAnswer = 'क्षमा करें, इस प्रश्न का सीधा उत्तर नहीं मिला।';

class AdminOffer {
  AdminOffer(this.convId, this.question, {this.reason});

  /// The worker's not-found `reason`, sent as `context: "ai_not_found:<reason>"`.
  final String? reason;
  final String convId;
  final String question;
  bool sending = false;

  /// A friendly reason the last try did not go through (offline, limit, …).
  String? message;
  bool canRetry = true;
}

/// "ज्ञान चर्चा": a question taken from the admin's notes (or a praman's topic), its answer and the
/// pramans — revealed on a tap.
class GyanCard {
  GyanCard({required this.convId, required this.question, required this.answer, required this.cited, this.fromNote = false});
  final String convId;
  final String question;
  final String answer;
  final List<int> cited; // praman ids
  final bool fromNote;
}

class ChatController extends ChangeNotifier {
  ChatController({
    AiClient? client,
    ChatStore? store,
    List<Praman> Function()? pramans,
    int Function()? version,
    AdminSync? admin,
    AdminKnowledge? knowledge,
    List<Topic> Function()? topics,
    math.Random? random,
  }) : _client = client,
       _store = store,
       _pramans = pramans,
       _version = version,
       _admin = admin,
       _knowledge = knowledge,
       _topics = topics,
       _rng = random;

  static ChatController I = ChatController();

  final AiClient? _client;
  final ChatStore? _store;
  final List<Praman> Function()? _pramans;
  final int Function()? _version;
  final AdminSync? _admin;
  final AdminKnowledge? _knowledge;
  final List<Topic> Function()? _topics;
  final math.Random? _rng;

  AdminSync get admin => _admin ?? AdminSync.I;
  AdminKnowledge get knowledge => _knowledge ?? AdminKnowledge.I;
  List<Topic> get topics => (_topics ?? () => CatalogStore.I.topics)();
  math.Random get rng => _rng ?? math.Random();

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

  /// Set when the last answer could not answer the question; null otherwise (not saved with the chat).
  AdminOffer? offer;

  /// A ज्ञान चर्चा question waiting for its answer to be revealed.
  GyanCard? gyan;

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
    unawaited(knowledge.loadCached()); // the admin's notes (disk copy) are ready for the first question
  }

  /// Starts an empty chat (the old one stays in the history).
  void newChat() {
    _run++;
    current = null;
    sending = false;
    error = null;
    offer = null;
    gyan = null;
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
    offer = null;
    gyan = null;
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
    offer = null;
    gyan = null;
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
    final history = [
      for (final m in earlier)
        if (!m.isAdmin) AiTurn(m.role, m.text),
    ]; // admin messages are not AI turns
    try {
      final ps = pramans;
      final context = earlier.where((m) => m.isUser).isEmpty ? null : earlier.lastWhere((m) => m.isUser).text;
      // Extras (additive; empty when offline or nothing matches): the admin's notes, the topics.
      await knowledge.loadCached();
      final notes = await knowledge.candidates(question);
      final tops = await TopicSource.I.candidates(topics, version, question);
      final room = (kCandidatesMax - notes.length - tops.length).clamp(1, kCandidatesMax);
      final prs = await Retriever.I.candidates(ps, version, question, context: context, k: room);
      final cands = [...notes, ...prs, ...tops];
      final a = await client.ask(question, history, cands);
      if (run != _run) return; // the user switched chat meanwhile: this answer is dropped
      final known = <int>[
        for (final id in a.cited)
          if (Retriever.I.praman(id) != null) id,
      ];
      final now = DateTime.now().millisecondsSinceEpoch;
      // Never show raw candidate ids ("id-467"): the praman / note / topic name instead.
      final names = {for (final x in cands) x.id: x.granth.isEmpty ? x.title : '${x.title} (${x.granth})'};
      var text = sanitizeAiText(a.answer, (id) => names[id], sourceName: (n) => n >= 1 && n <= cands.length ? names[cands[n - 1].id] : null);
      if (text.isEmpty) text = kEmptyAnswer;
      c.messages.add(
        ChatMsg(
          role: 'assistant',
          text: text.length > kMaxMessageChars ? text.substring(0, kMaxMessageChars) : text,
          cited: known,
          at: now,
          sources: a.sources,
        ),
      );
      c.updated = now;
      sending = false;
      offer = aiCannotAnswer(answer: text, cited: a.cited, isPraman: (id) => Retriever.I.praman(id) != null, notFound: a.offerAdmin)
          ? AdminOffer(c.id, question, reason: a.found == false ? (a.reason ?? 'no_source') : null)
          : null;
      if (a.found == false) Analytics.I.aiFailed(question, a.reason ?? 'no_source');
      tick++;
      Analytics.I.aiAnswered();
      notifyListeners();
      await _persist(c);
    } on AiException catch (e) {
      if (run != _run) return;
      Analytics.I.aiFailed(question, e.kind.name);
      error = e;
      sending = false;
      notifyListeners();
    } catch (_) {
      if (run != _run) return;
      Analytics.I.aiFailed(question, 'error');
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
    offer = null;
    gyan = null;
    loaded = false;
    _loading = null;
    _run++;
    input.clear();
  }
  // ---- ask the admin (round 13) ------------------------------------------------------------

  /// "हाँ": sends the question the AI could not answer to the admin.
  Future<void> askAdmin() async {
    final o = offer;
    if (o == null || o.sending) return;
    o.sending = true;
    o.message = null;
    notifyListeners();
    final r = await admin.sendQuestion(o.question, convId: o.convId, context: o.reason == null ? null : 'ai_not_found:${o.reason}');
    o.sending = false;
    if (r.ok) {
      if (identical(offer, o)) offer = null;
      final c = await _conv(o.convId);
      if (c != null) {
        final now = DateTime.now().millisecondsSinceEpoch;
        c.messages.add(ChatMsg(role: 'assistant', text: r.message, at: now));
        c.updated = now;
        if (identical(c, current)) tick++;
        await _persist(c);
      }
      unawaited(PdfNotify.I.ensurePermission()); // so the "उत्तर आ गया" notification can be seen
    } else {
      o.message = r.message;
      o.canRetry = r.canRetry;
    }
    notifyListeners();
  }

  /// "नहीं".
  void declineOffer() {
    if (offer == null || offer!.sending) return;
    offer = null;
    notifyListeners();
  }

  Future<Conversation?> _conv(String id) async {
    if (current?.id == id) return current;
    return store.load(id);
  }

  /// Stores an admin answer in the chat it belongs to (or a new one). True only when it is saved
  /// — or was saved before (a repeated poll): the caller acks the server only then.
  Future<bool> deliverAdminAnswer(AdminAnswer a, String? convId) async {
    try {
      final ref = a.ref;
      Conversation? c = convId == null ? null : await _conv(convId);
      if (c == null) {
        // The chat is gone (deleted) or unknown: a chat of its own, so nothing is lost.
        final now = DateTime.now().millisecondsSinceEpoch;
        c = Conversation(id: newChatId(), title: 'admin का उत्तर', created: now, updated: now);
      }
      if (c.messages.any((m) => m.ref == ref)) return true;
      final now = DateTime.now().millisecondsSinceEpoch;
      c.messages.add(
        ChatMsg(
          role: 'admin',
          text: a.answer.length > kMaxMessageChars ? a.answer.substring(0, kMaxMessageChars) : a.answer,
          at: now,
          ref: ref,
          ask: a.question.isEmpty ? null : a.question,
        ),
      );
      c.updated = now;
      chats = await store.save(c);
      if (current == null && !sending) current = c;
      if (identical(c, current)) tick++;
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---- ज्ञान चर्चा (round 13) --------------------------------------------------------------

  /// Asks a question from the admin's notes — else from a praman's topic — and keeps its answer
  /// for [revealGyan]. False when there is nothing to ask.
  Future<bool> startGyan() async {
    if (sending) return false;
    final ps = pramans;
    await knowledge.loadCached();
    final notes = knowledge.notes;
    GyanCard? card;
    final id = current?.id ?? newChatId();
    if (notes.isNotEmpty) {
      final n = notes[rng.nextInt(notes.length)];
      var cited = <int>[];
      if (ps.isNotEmpty) {
        final cs = await Retriever.I.candidates(ps, version, '${n.question} ${n.tags.join(' ')}', k: 3);
        cited = [
          for (final c in cs)
            if (Retriever.I.praman(c.id) != null) c.id,
        ];
      }
      card = GyanCard(convId: id, question: n.question, answer: n.answer, cited: cited, fromNote: true);
    } else {
      final withTopic = [
        for (final p in ps)
          if (p.topicTitle.trim().isNotEmpty && p.granthTitle.trim().isNotEmpty) p,
      ];
      if (withTopic.isEmpty) return false;
      final p = withTopic[rng.nextInt(withTopic.length)];
      await Retriever.I.ensure(ps, version);
      final same = [
        for (final x in withTopic)
          if (x.topicId == p.topicId && x.id != p.id) x,
      ].take(2);
      final all = [p, ...same];
      final names = {for (final x in all) x.granthTitle}.join(', ');
      card = GyanCard(
        convId: id,
        question: 'इस बात का प्रमाण किस ग्रंथ में है — “${p.topicTitle.trim()}”?',
        answer: 'इसका प्रमाण **$names** में मिलता है।',
        cited: [for (final x in all) int.tryParse(x.id) ?? -1].where((e) => e > 0).toList(),
      );
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final c = current ??= Conversation(id: id, title: 'ज्ञान चर्चा', created: now, updated: now);
    c.messages.add(ChatMsg(role: 'assistant', text: '**ज्ञान चर्चा**\n\n❓ ${card.question}\n\nपहले खुद सोचिए, फिर “उत्तर और प्रमाण देखें” दबाइए।', at: now));
    c.updated = now;
    offer = null;
    gyan = card;
    error = null;
    tick++;
    notifyListeners();
    await _persist(c);
    return true;
  }

  /// "उत्तर और प्रमाण देखें": the answer and the granths that hold its pramans.
  Future<void> revealGyan() async {
    final g = gyan;
    if (g == null) return;
    gyan = null;
    final c = await _conv(g.convId);
    if (c == null) {
      notifyListeners();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final tail = g.cited.isEmpty ? '\n\n_इस उत्तर का प्रमाण अभी ऐप में नहीं मिला।_' : '';
    c.messages.add(ChatMsg(role: 'assistant', text: '${g.answer}$tail${g.fromNote ? '\n\n_(admin का नोट)_' : ''}', cited: g.cited, at: now));
    c.updated = now;
    if (identical(c, current)) tick++;
    notifyListeners();
    await _persist(c);
  }
}
