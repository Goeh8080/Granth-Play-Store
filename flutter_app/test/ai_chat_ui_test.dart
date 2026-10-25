import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/ai/chat_store.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/screens/ai_screen.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/common.dart';

import 'ai_retrieval_test.dart' show realPramans;
import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round5_test.dart' show fingerTap, openApp;

/// Answers on demand: the test decides when (and whether) the "server" replies.
class GateClient extends AiClient {
  GateClient() : super(endpoint: 'http://x');
  final List<String> questions = [];
  Completer<AiAnswer>? gate;
  AiAnswer? next;
  AiException? fail;
  @override
  Future<AiAnswer> ask(String question, List<AiTurn> history, List<Candidate> candidates) {
    questions.add(question);
    if (fail != null) return Future.error(fail!);
    if (next != null) return Future.value(next!);
    gate = Completer<AiAnswer>();
    return gate!.future;
  }
}

Catalog catalog() => Catalog(topics: [], granths: [], pramans: realPramans(), syncedAt: DateTime(2026, 10, 25).millisecondsSinceEpoch);

/// Real time (disk + isolate work is not driven by `pump`).
Future<void> until(WidgetTester t, bool Function() done) async {
  for (var i = 0; i < 1500 && !done(); i++) {
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
    await t.pump(const Duration(milliseconds: 50));
  }
  await settle(t, 5);
}

void main() {
  late GateClient client;
  late List<Praman> pramans;
  setUp(() async {
    await setUpApp();
    Places.forgetLive();
    Retriever.I.reset();
    CatalogStore.I.debugSetCatalog(catalog());
    pramans = CatalogStore.I.pramans;
    client = GateClient();
    ChatController.I = ChatController(client: client, store: ChatStore.fresh());
  });

  Future<void> openAi(WidgetTester t) async {
    await openApp(t);
    AppNav.I.go('#/ai');
    await settle(t);
    await until(t, () => ChatController.I.loaded);
    await settle(t, 4);
  }

  AiAnswer answer({List<int>? cited}) => AiAnswer(
        answer: '**कर्म योग** का अर्थ है फल की चिंता किए बिना कर्म करना।\n- पहला बिंदु\n- दूसरा बिंदु',
        cited: cited ?? [for (final p in pramans.take(3)) int.parse(p.id)],
        provider: 'test',
      );

  testWidgets('empty chat: intro, suggestion chips, text box, the AI-can-be-wrong note', (t) async {
    await openAi(t);
    expect(find.text('तत्त्व AI से पूछे'), findsWidgets);
    expect(find.byKey(const ValueKey('ai-intro')), findsOneWidget);
    for (final s in kAiSuggestions) {
      expect(find.byKey(ValueKey('ai-sug-$s')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('ai-input')), findsOneWidget);
    expect(find.textContaining('AI गलती कर सकता है, मूल ग्रंथ से मिलाएँ', findRichText: true), findsWidgets);
    expect(find.textContaining('AI उपयोग नीति', findRichText: true), findsWidgets);
    expect(t.takeException(), isNull);
  });

  testWidgets('send: bubble on the right, thinking indicator, answer with markdown, citations, 2 previews, copy', (t) async {
    final clip = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      if (c.method == 'Clipboard.setData') clip.add((c.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => t.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await openAi(t);
    await t.enterText(find.byKey(const ValueKey('ai-input')), 'गीता में कर्म योग क्या है?');
    await t.pump();
    await fingerTap(t, find.byKey(const ValueKey('ai-send')), wobble: Offset.zero);
    await until(t, () => client.questions.isNotEmpty);
    // The user's question is on the right; the "thinking" bubble shows; the box is empty again.
    final bubble = find.widgetWithText(UserBubble, 'गीता में कर्म योग क्या है?');
    expect(bubble, findsOneWidget);
    expect(t.getTopRight(bubble).dx, greaterThan(300), reason: 'user bubble hugs the right edge');
    expect(find.byKey(const ValueKey('ai-thinking')), findsOneWidget);
    expect(find.text('सोच रहा हूँ'), findsOneWidget);
    expect(t.widget<TextField>(find.byKey(const ValueKey('ai-input'))).controller!.text, isEmpty);

    client.gate!.complete(answer());
    await until(t, () => !ChatController.I.sending);
    expect(find.byKey(const ValueKey('ai-thinking')), findsNothing);
    expect(find.textContaining('फल की चिंता किए बिना', findRichText: true), findsOneWidget);
    expect(find.textContaining('**'), findsNothing, reason: 'markdown markers are not shown');
    for (final p in pramans.take(3)) {
      expect(find.byKey(ValueKey('ai-cite-${p.id}')), findsOneWidget);
    }
    expect(find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('ai-preview-')), findsNWidgets(2), reason: 'only the first 2 cited get a preview card');
    expect(find.textContaining('📖', findRichText: true), findsNWidgets(3));

    await fingerTap(t, find.byKey(const ValueKey('ai-copy')), wobble: Offset.zero);
    await settle(t, 3);
    expect(clip.single, startsWith('कर्म योग का अर्थ है'));
    expect(clip.single, contains('• पहला बिंदु'));
    await t.pump(const Duration(seconds: 8)); // the "copied" toast leaves
    expect(t.takeException(), isNull);
  });

  testWidgets('a citation opens the praman; Back returns to the chat with its messages', (t) async {
    client.next = answer();
    await openAi(t);
    unawaited(askQuestion('श्राद्ध क्यों नहीं करना चाहिए?'));
    await until(t, () => ChatController.I.messages.length == 2);
    final p = pramans.first;
    await t.ensureVisible(find.byKey(ValueKey('ai-cite-${p.id}')));
    await settle(t, 3);
    await fingerTap(t, find.byKey(ValueKey('ai-cite-${p.id}')), wobble: Offset.zero);
    await settle(t, 6);
    expect(AppNav.I.hash, '#/pramans?id=${p.id}');
    await t.binding.handlePopRoute();
    await settle(t, 8);
    expect(AppNav.I.hash, '#/ai');
    expect(find.textContaining('फल की चिंता किए बिना', findRichText: true), findsOneWidget);
    expect(ChatController.I.messages.length, 2);
    // Back from the chat itself goes one screen back (not out of the app).
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 320))); // the router ignores a double Back
    await t.binding.handlePopRoute();
    await settle(t, 6);
    expect(AppNav.I.hash, '#/dashboard');
  });

  testWidgets('failure: friendly message + "फिर कोशिश करें" keeps the question; one tap retries', (t) async {
    client.fail = const AiException(AiFailure.unavailable, 'AI अभी उपलब्ध नहीं है। थोड़ी देर बाद फिर कोशिश करें।', status: 503);
    await openAi(t);
    unawaited(askQuestion('सतलोक क्या है?'));
    await until(t, () => ChatController.I.error != null);
    expect(find.byKey(const ValueKey('ai-error')), findsOneWidget);
    expect(find.textContaining('AI अभी उपलब्ध नहीं है'), findsOneWidget);
    expect(find.text('सतलोक क्या है?'), findsOneWidget, reason: 'the question stays in the chat');
    client.fail = null;
    client.next = answer(cited: []);
    await t.ensureVisible(find.byKey(const ValueKey('ai-retry')));
    await settle(t, 3);
    await fingerTap(t, find.byKey(const ValueKey('ai-retry')), wobble: Offset.zero);
    await until(t, () => ChatController.I.messages.length == 2);
    expect(client.questions, ['सतलोक क्या है?', 'सतलोक क्या है?']);
    expect(find.byKey(const ValueKey('ai-error')), findsNothing);
    expect(find.text('सतलोक क्या है?'), findsOneWidget, reason: 'asked twice, shown once');
  });

  testWidgets('no catalog yet: nothing is sent', (t) async {
    await openAi(t);
    CatalogStore.I.debugSetCatalog(Catalog(topics: [], granths: [], pramans: []));
    expect(await t.runAsync(() => askQuestion('कुछ भी')), isFalse);
    expect(client.questions, isEmpty);
    expect(ChatController.I.messages, isEmpty);
    await t.pump(const Duration(seconds: 8)); // toasts leave
  });

  testWidgets('history sheet: open an old chat, delete one, clear all', (t) async {
    client.next = answer(cited: []);
    await openAi(t);
    unawaited(askQuestion('पहला प्रश्न'));
    await until(t, () => ChatController.I.messages.length == 2);
    ChatController.I.newChat();
    await settle(t, 3);
    unawaited(askQuestion('दूसरा प्रश्न'));
    await until(t, () => ChatController.I.messages.length == 2 && ChatController.I.chats.length == 2);
    await fingerTap(t, find.byKey(const ValueKey('ai-history')), wobble: Offset.zero);
    await settle(t, 6);
    expect(find.text('पहला प्रश्न'), findsOneWidget);
    await fingerTap(t, find.text('पहला प्रश्न'), wobble: Offset.zero);
    await until(t, () => ChatController.I.current?.title == 'पहला प्रश्न');
    expect(find.byType(UserBubble), findsOneWidget);
    expect(find.widgetWithText(UserBubble, 'पहला प्रश्न'), findsOneWidget);

    await fingerTap(t, find.byKey(const ValueKey('ai-history')), wobble: Offset.zero);
    await settle(t, 6);
    final del = find.byWidgetPredicate((w) => w.key is ValueKey && (w.key as ValueKey).value.toString().startsWith('chat-del-'));
    expect(del, findsNWidgets(2));
    await fingerTap(t, del.first, wobble: Offset.zero);
    await settle(t, 6);
    await fingerTap(t, find.text('OK'), wobble: Offset.zero);
    await until(t, () => ChatController.I.chats.length == 1);
    expect(del, findsOneWidget);
    await fingerTap(t, find.byKey(const ValueKey('chat-clear-all')), wobble: Offset.zero);
    await settle(t, 6);
    await fingerTap(t, find.text('OK'), wobble: Offset.zero);
    await until(t, () => ChatController.I.chats.isEmpty);
    expect(await t.runAsync(() => ChatStore.fresh().list()), isEmpty, reason: 'gone from disk too');
    expect(ChatController.I.messages, isEmpty);
    await t.pump(const Duration(seconds: 8)); // toasts leave
  });

  testWidgets('narrow phone, large text: the chat draws without overflow', (t) async {
    client.next = AiAnswer(answer: 'एक बहुत लंबा उत्तर ${'शब्द ' * 80}\n- बिंदु\n1. क्रम', cited: [for (final p in pramans.take(4)) int.parse(p.id)], provider: 'x');
    await openApp(t);
    await t.binding.setSurfaceSize(const Size(320, 640));
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    AppNav.I.go('#/ai');
    await settle(t);
    await until(t, () => ChatController.I.loaded);
    unawaited(askQuestion('प्रश्न'));
    await until(t, () => ChatController.I.messages.length == 2);
    expect(t.takeException(), isNull);
    expect(find.byType(GCard), findsWidgets);
  });
}
