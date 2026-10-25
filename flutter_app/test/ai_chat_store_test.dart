import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/ai/chat_store.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'ai_retrieval_test.dart' show realPramans;
import 'helpers.dart';

Conversation conv(String q, {int at = 1000, String? id}) => Conversation(
      id: id ?? newChatId(),
      title: titleFor(q),
      created: at,
      updated: at,
      messages: [ChatMsg(role: 'user', text: q, at: at), ChatMsg(role: 'assistant', text: 'उत्तर: $q', cited: const [5, 7], at: at + 1)],
    );

class FakeClient extends AiClient {
  FakeClient(this.script) : super(endpoint: 'http://x');
  final List<Object> script; // AiAnswer | AiException
  final List<List<AiTurn>> histories = [];
  final List<int> candidateCounts = [];
  @override
  Future<AiAnswer> ask(String question, List<AiTurn> history, List<Candidate> candidates) async {
    histories.add(history);
    candidateCounts.add(candidates.length);
    final r = script.removeAt(0);
    if (r is AiException) throw r;
    return r as AiAnswer;
  }
}

void main() {
  late ChatStore store;
  setUp(() async {
    await setUpApp();
    store = ChatStore.fresh();
  });

  test('titles: first question, one line, cut at a word', () {
    expect(titleFor('  गीता में  कर्म योग क्या है? '), 'गीता में कर्म योग क्या है?');
    expect(titleFor(''), 'नई बातचीत');
    final t = titleFor('${'शब्द ' * 30}अंत');
    expect(t.runes.length, lessThanOrEqualTo(kTitleChars + 1));
    expect(t.endsWith('…'), isTrue);
    expect(t.contains('\n'), isFalse);
  });

  test('save → list → load survives a "restart" (a new store object, same folder)', () async {
    final a = conv('पहला प्रश्न', at: 1000);
    final b = conv('दूसरा प्रश्न', at: 2000);
    await store.save(a);
    await store.save(b);
    final again = ChatStore.fresh();
    final list = await again.list();
    expect(list.map((e) => e.title), ['दूसरा प्रश्न', 'पहला प्रश्न']);
    expect(list.first.count, 2);
    final c = await again.load(a.id);
    expect(c!.messages.length, 2);
    expect(c.messages.last.cited, [5, 7]);
    expect(c.messages.last.text, 'उत्तर: पहला प्रश्न');
  });

  test('writes are atomic: no temp files stay, the index is valid JSON', () async {
    await store.save(conv('क'));
    final files = Directory('${Store.I.root.path}/chats').listSync().map((e) => e.path.split('/').last).toList();
    expect(files.where((f) => f.endsWith('.tmp')), isEmpty);
    expect(jsonDecode(File('${Store.I.root.path}/chats/index.json').readAsStringSync()), isA<List>());
  });

  test('delete one and clear all', () async {
    final a = conv('एक');
    final b = conv('दो', at: 2000);
    await store.save(a);
    await store.save(b);
    final left = await store.delete(a.id);
    expect(left.map((e) => e.id), [b.id]);
    expect(await store.load(a.id), isNull);
    expect(File('${Store.I.root.path}/chats/${a.id}.json').existsSync(), isFalse);
    await store.clearAll();
    expect(await store.list(), isEmpty);
    expect(Directory('${Store.I.root.path}/chats').existsSync(), isFalse);
    await store.save(conv('फिर'));
    expect((await store.list()).length, 1);
  });

  test('capped: $kMaxChats chats, $kMaxMessages messages each, the oldest go', () async {
    for (var i = 0; i < kMaxChats + 5; i++) {
      await store.save(conv('प्रश्न $i', at: 1000 + i));
    }
    final list = await store.list();
    expect(list.length, kMaxChats);
    expect(list.first.title, 'प्रश्न ${kMaxChats + 4}');
    expect(list.any((e) => e.title == 'प्रश्न 0'), isFalse);
    expect(Directory('${Store.I.root.path}/chats').listSync().length, kMaxChats + 1); // + index.json
    final big = conv('लंबी', at: 99999);
    for (var i = 0; i < 100; i++) {
      big.messages.add(ChatMsg(role: i.isEven ? 'user' : 'assistant', text: 'm$i'));
    }
    await store.save(big);
    final back = await store.load(big.id);
    expect(back!.messages.length, kMaxMessages);
    expect(back.messages.last.text, 'm99');
  });

  test('a damaged index is rebuilt from the files; a damaged chat file is skipped', () async {
    final a = conv('सुरक्षित', at: 3000);
    await store.save(a);
    await store.save(conv('दूसरा', at: 1000));
    File('${Store.I.root.path}/chats/index.json').writeAsStringSync('{not json');
    File('${Store.I.root.path}/chats/zzzzzzzz.json').writeAsStringSync('garbage');
    final list = await ChatStore.fresh().list();
    expect(list.length, 2);
    expect(list.first.id, a.id);
  });

  test('unsafe ids are refused (the id becomes a file name)', () async {
    expect(await store.load('../../etc/passwd'), isNull);
    expect(await store.delete('../x'), isEmpty);
    expect(Conversation.fromJson({'id': '../x', 'messages': []}), isNull);
  });

  test('two quick saves of the same chat never interleave', () async {
    final a = conv('तेज़');
    final fs = [for (var i = 0; i < 10; i++) store.save(a..updated = 1000 + i)];
    await Future.wait(fs);
    expect((await store.list()).length, 1);
    expect((await store.load(a.id))!.messages.length, 2);
  });

  group('ChatController', () {
    late List<Praman> ps;
    setUp(() => ps = realPramans());

    ChatController make(FakeClient c) => ChatController(client: c, store: store, pramans: () => ps, version: () => 7);

    test('send → answer: saved, cited ids kept only if they exist, history sent', () async {
      final fc = FakeClient([
        const AiAnswer(answer: 'पहला', cited: [85, 99999, 95], provider: 'p'),
        const AiAnswer(answer: 'दूसरा', cited: [], provider: 'p'),
      ]);
      final c = make(fc);
      await c.load();
      expect(await c.send('  श्राद्ध क्यों नहीं करना चाहिए?  '), isTrue);
      expect(c.sending, isFalse);
      expect(c.error, isNull);
      expect(c.messages.map((m) => m.role), ['user', 'assistant']);
      expect(c.messages.last.cited, [85, 95]);
      expect(fc.candidateCounts.single, 12);
      expect(fc.histories.single, isEmpty);
      await c.send('और बताइए');
      expect(fc.histories.last.map((t) => t.role), ['user', 'assistant']);
      expect(c.chats.length, 1);
      expect(c.chats.single.title, 'श्राद्ध क्यों नहीं करना चाहिए?');
      // a "restart": a new controller reopens the newest chat
      final c2 = make(FakeClient([]));
      await c2.load();
      expect(c2.messages.length, 4);
    });

    test('a failure keeps the question; retry asks again and then the answer arrives', () async {
      final fc = FakeClient([
        const AiException(AiFailure.timeout, 'देर हुई'),
        const AiAnswer(answer: 'अब मिला', cited: [], provider: 'p'),
      ]);
      final c = make(fc);
      await c.send('गीता ज्ञान दाता कौन है?');
      expect(c.error?.kind, AiFailure.timeout);
      expect(c.sending, isFalse);
      expect(c.messages.single.text, 'गीता ज्ञान दाता कौन है?');
      expect(c.current!.pending, isTrue);
      // the question survives a restart too
      final c2 = make(FakeClient([]));
      await c2.load();
      expect(c2.current!.pending, isTrue);
      await c.retry();
      expect(c.error, isNull);
      expect(c.messages.map((m) => m.role), ['user', 'assistant']);
      expect(c.messages.length, 2, reason: 'retry must not duplicate the question');
    });

    test('empty text and a second send while one is on its way do nothing', () async {
      final c = make(FakeClient([const AiAnswer(answer: 'ok', cited: [], provider: 'p')]));
      expect(await c.send('   '), isFalse);
      final first = c.send('एक');
      expect(c.sending, isTrue);
      expect(await c.send('दो'), isFalse);
      await first;
      expect(c.messages.length, 2);
    });

    test('new chat, open, delete, clear all', () async {
      final c = make(FakeClient([for (var i = 0; i < 3; i++) const AiAnswer(answer: 'ok', cited: [], provider: 'p')]));
      await c.send('पहली');
      final firstId = c.current!.id;
      c.newChat();
      expect(c.messages, isEmpty);
      await c.send('दूसरी');
      expect(c.chats.length, 2);
      await c.open(firstId);
      expect(c.messages.first.text, 'पहली');
      await c.delete(firstId);
      expect(c.current, isNull);
      expect(c.chats.length, 1);
      await c.clearAll();
      expect(c.chats, isEmpty);
      expect(await store.list(), isEmpty);
    });

    test('an answer that arrives after switching chat is dropped', () async {
      final c = make(FakeClient([const AiAnswer(answer: 'late', cited: [], provider: 'p')]));
      final f = c.send('धीमा प्रश्न');
      await Future<void>.delayed(Duration.zero);
      c.newChat();
      await f;
      expect(c.messages, isEmpty);
    });
  });
}
