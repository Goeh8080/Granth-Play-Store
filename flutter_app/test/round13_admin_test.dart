// Round 13: AI "ask the admin", answers polling, admin key notes, ui.grid, pinned banner.
// Everything runs against fakes (no network).
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/cannot_answer.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/ai/chat_store.dart';
import 'package:granthprabandhan/ai/extra_sources.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/screens/ai_screen.dart';
import 'package:granthprabandhan/services/admin_sync.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/announcement_banner.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'remote_config_test.dart' as rct;
import 'round5_test.dart' show openApp;

/// A scripted server that also keeps a shared event log (to check the ORDER of calls).
class Fake implements HttpClientAdapter {
  Fake([this.log]);
  final List<String>? log;
  final List<({int status, String body, bool fail, String? etag})> replies = [];
  final List<RequestOptions> seen = [];
  void reply(int status, [Object body = const {}, String? etag]) => replies.add((
    status: status,
    body: body is String ? body : jsonEncode(body),
    fail: false,
    etag: etag,
  ));
  void down() => replies.add((status: 0, body: '', fail: true, etag: null));

  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? req, Future<void>? cancel) async {
    seen.add(o);
    log?.add(
      '${o.method} ${o.uri.path}${o.method == 'POST' && o.uri.path.endsWith('ack') ? ' ${jsonDecode(o.data as String)['ids']}' : ''}',
    );
    final r = replies.isEmpty
        ? (status: 503, body: '{}', fail: false, etag: null)
        : replies.removeAt(0);
    if (r.fail) {
      throw DioException.connectionError(requestOptions: o, reason: 'offline');
    }
    return ResponseBody.fromString(
      r.body,
      r.status,
      headers: {
        Headers.contentTypeHeader: ['application/json'],
        if (r.etag != null) 'etag': [r.etag!],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

const iid = 'abcdef0123456789abcdef0123456789';
DateTime clock = DateTime.utc(2026, 10, 25, 10);

AdminSync syncWith(
  Fake f, {
  String appKey = '',
  AnswerSink? deliver,
  Future<void> Function(int, String)? notify,
}) => AdminSync(
  dio: Dio()..httpClientAdapter = f,
  base: 'https://adm.test',
  appKey: appKey,
  iid: () => iid,
  now: () => clock,
  enabled: true,
  deliver: deliver,
  notify: notify ?? (_, _) async {},
);

AdminKnowledge knowledgeWith(Fake f) =>
    AdminKnowledge(dio: Dio()..httpClientAdapter = f, base: 'https://adm.test', enabled: true);

String kb(List<Map<String, Object>> items, {int version = 3}) => jsonEncode({
  'schema': 1,
  'version': version,
  'updated_at': 1,
  'count': items.length,
  'items': items,
});

Map<String, Object> answerItem(int id, {String answer = 'यह admin का उत्तर है', int at = 1000}) => {
  'id': id,
  'question': 'प्रश्न $id?',
  'answer': answer,
  'answered_at': at,
  'seen': false,
};

class CapClient extends AiClient {
  CapClient() : super(endpoint: 'http://x');
  List<Candidate> last = const [];
  AiAnswer? next;
  @override
  Future<AiAnswer> ask(String question, List<AiTurn> history, List<Candidate> candidates) async {
    last = candidates;
    return next ?? const AiAnswer(answer: 'ठीक है', cited: [], provider: 'test');
  }
}

const cannot = AiAnswer(
  answer: 'दिए गए प्रमाणों में इसका सीधा उत्तर नहीं मिला।\n\nसामान्य जानकारी: कुछ।',
  cited: [],
  provider: 'test',
);

void main() {
  late List<String> log;
  setUp(() async {
    await setUpApp();
    Places.forgetLive();
    Retriever.I.reset();
    TopicSource.I.reset();
    clock = DateTime.utc(2026, 10, 25, 10);
    log = [];
    RemoteConfig.I.debugReset();
  });

  group('config: ui.grid + pinned announcement (signed mock configs)', () {
    ParsedConfig? parse(String n) =>
        parseConfig(rct.fx(n), cachedVersion: 0, appBuild: 1, publicKey: rct.testKey);

    test(
      'signed config with ui.grid=1 and a pinned announcement parses; unknown ui keys are ignored',
      () {
        final p = parse('cfg_ui_pinned.json')!;
        expect(p.uiGrid, 1);
        expect(p.announcement!.pinned, isTrue);
      },
    );

    test('old configs: no ui → grid null, announcement not pinned', () {
      final p = parse('cfg_valid.json')!;
      expect(p.uiGrid, isNull);
      expect(p.announcement!.pinned, isFalse);
    });

    test('bad values: grid 9 is clamped to 3, pinned:"yes" is not true', () {
      final p = parse('cfg_ui_bad.json')!;
      expect(p.uiGrid, 3);
      expect(p.announcement!.pinned, isFalse);
    });

    test(
      'the new fields are read only from a verified config (a tampered one is dropped whole)',
      () {
        final tampered = rct
            .fx('cfg_ui_pinned.json')
            .replaceFirst('"grid":1', '"grid":3')
            .replaceFirst('"grid": 1', '"grid": 3');
        expect(tampered, isNot(rct.fx('cfg_ui_pinned.json')));
        expect(
          parseConfig(tampered, cachedVersion: 0, appBuild: 1, publicKey: rct.testKey),
          isNull,
        );
      },
    );

    test(
      'grid default: nothing set → 2; admin ui.grid is the default; the user\'s own choice always wins',
      () async {
        expect(UiPrefs.I.granthCols, 2);
        final s = rct.Server()..ok(rct.fx('cfg_ui_pinned.json'));
        RemoteConfig.I = rct.make(s);
        await RemoteConfig.I.refresh();
        expect(RemoteConfig.I.uiGrid, 1);
        expect(UiPrefs.I.granthCols, 1);
        UiPrefs.I.setLayout(3); // the user picks a layout
        expect(UiPrefs.I.granthCols, 3);
        s.ok(rct.fx('cfg_ui_bad.json'), etag: '"e9"');
        await RemoteConfig.I.refresh();
        expect(UiPrefs.I.granthCols, 3);
      },
    );

    Future<void> banner(WidgetTester t, String cfg, double scale) async {
      final s = rct.Server()..ok(rct.fx(cfg));
      RemoteConfig.I = rct.make(s);
      await t.runAsync(() => RemoteConfig.I.refresh());
      t.view.physicalSize = const Size(320, 640);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.reset);
      await t.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(size: const Size(320, 640), textScaler: TextScaler.linear(scale)),
            child: const Scaffold(
              body: SingleChildScrollView(
                child: Padding(padding: EdgeInsets.all(12), child: AnnouncementBanner()),
              ),
            ),
          ),
        ),
      );
      await t.pump();
    }

    testWidgets('pinned banner: shown, NO close button, 320dp × 1.3 text, no overflow', (t) async {
      await banner(t, 'cfg_ui_pinned.json', 1.3);
      expect(find.byKey(const ValueKey('announcement')), findsOneWidget);
      expect(find.text('यह सूचना हटाई नहीं जा सकती'), findsOneWidget);
      expect(find.byKey(const ValueKey('announcement-close')), findsNothing);
      expect(t.takeException(), isNull);
      await RemoteConfig.I.dismissBanner(); // ignored for a pinned one
      await t.pump();
      expect(find.byKey(const ValueKey('announcement')), findsOneWidget);
    });

    testWidgets('a normal banner still has its close button (320dp × 1.3, no overflow)', (t) async {
      await banner(t, 'cfg_valid.json', 1.3);
      expect(find.byKey(const ValueKey('announcement-close')), findsOneWidget);
      expect(t.takeException(), isNull);
    });
  });

  group('AdminSync.sendQuestion', () {
    test(
      '202 → sent; body has iid/question; no X-App-Key when the key is empty; counted; Hindi message',
      () async {
        final f = Fake()..reply(202, {'id': 7});
        final s = syncWith(f);
        final r = await s.sendQuestion('सतलोक क्या है?', convId: 'c1');
        expect(r.result, AskResult.sent);
        expect(r.message, contains('admin को भेज दिया'));
        expect(f.seen.single.uri.toString(), 'https://adm.test/ai/questions');
        final body = jsonDecode(f.seen.single.data as String) as Map;
        expect(body['iid'], iid);
        expect(body['question'], 'सतलोक क्या है?');
        expect(f.seen.single.headers.containsKey('X-App-Key'), isFalse);
        expect(s.sentToday, 1);
        expect(s.hasAsked, isTrue);
      },
    );

    test('the app key is sent only when there is one', () async {
      final f = Fake()..reply(202, {'id': 1});
      await syncWith(f, appKey: 'test-key-value').sendQuestion('प्रश्न तीन');
      expect(f.seen.single.headers['X-App-Key'], 'test-key-value');
    });

    test('duplicate → friendly, not counted', () async {
      final f = Fake()..reply(202, {'id': 7, 'duplicate': true});
      final s = syncWith(f);
      final r = await s.sendQuestion('वही प्रश्न');
      expect(r.result, AskResult.duplicate);
      expect(r.ok, isTrue);
      expect(s.sentToday, 0);
    });

    test('5 a day: the 6th is refused locally with no request; next day it works', () async {
      final f = Fake();
      for (var i = 0; i < 6; i++) {
        f.reply(202, {'id': i + 1});
      }
      final s = syncWith(f);
      for (var i = 0; i < 5; i++) {
        expect((await s.sendQuestion('प्रश्न नंबर $i')).result, AskResult.sent);
      }
      final r = await s.sendQuestion('छठा प्रश्न');
      expect(r.result, AskResult.dailyLimit);
      expect(r.message, contains('कल फिर'));
      expect(f.seen.length, 5);
      clock = clock.add(const Duration(days: 1));
      expect((await s.sendQuestion('छठा प्रश्न')).result, AskResult.sent);
    });

    test(
      'server 429 → friendly "later"; 400 → invalid; 503 → unavailable; none auto-retried',
      () async {
        final f = Fake()
          ..reply(429, {'error': 'rate_limited'})
          ..reply(400, {'error': 'invalid_question'})
          ..reply(503, {'error': 'unavailable'});
        final s = syncWith(f);
        final a = await s.sendQuestion('प्रश्न एक');
        expect(a.result, AskResult.rateLimited);
        expect(a.canRetry, isTrue);
        expect((await s.sendQuestion('प्रश्न दो')).result, AskResult.invalid);
        expect((await s.sendQuestion('प्रश्न तीन')).result, AskResult.unavailable);
        expect(f.seen.length, 3);
        expect(s.sentToday, 0);
      },
    );

    test('offline → friendly Hindi message, nothing counted, can retry', () async {
      final f = Fake()..down();
      final s = syncWith(f);
      final r = await s.sendQuestion('इंटरनेट बंद');
      expect(r.result, AskResult.offline);
      expect(r.message, contains('इंटरनेट'));
      expect(r.canRetry, isTrue);
      expect(s.sentToday, 0);
      expect(s.hasAsked, isFalse);
    });

    test('too short / disabled never touch the network', () async {
      final f = Fake();
      final s = syncWith(f);
      expect((await s.sendQuestion('  ए ')).result, AskResult.invalid);
      s.enabled = false;
      expect((await s.sendQuestion('ठीक प्रश्न')).result, AskResult.unavailable);
      expect(f.seen, isEmpty);
    });
  });

  group('AdminSync.poll', () {
    Future<void> asked() => Store.I.setString(AdminSync.kAsked, '1');

    test('nothing is fetched until the user has asked something', () async {
      final f = Fake();
      expect(await syncWith(f).poll(force: true), 0);
      expect(f.seen, isEmpty);
    });

    test('ORDER: GET → each answer stored → ONE ack with the ids → notification', () async {
      await asked();
      final f = Fake(log)
        ..reply(200, {
          'items': [answerItem(1), answerItem(2)],
          'next_since': 2,
          'has_more': false,
          'pending': 0,
        })
        ..reply(200, {'ok': true, 'acked': 2});
      final s = syncWith(
        f,
        deliver: (a, c) async {
          log.add('store ${a.id}');
          return true;
        },
        notify: (n, t) async => log.add('notify $n'),
      );
      expect(await s.poll(force: true), 2);
      expect(log, [
        'GET /ai/answers',
        'store 1',
        'store 2',
        'POST /ai/answers/ack [1, 2]',
        'notify 2',
      ]);
      expect(f.seen.first.queryParameters['iid'], iid);
    });

    test('a failed store is not acked and not marked: it comes again; then it is', () async {
      await asked();
      final f = Fake(log)
        ..reply(200, {
          'items': [answerItem(1)],
        })
        ..reply(200, {
          'items': [answerItem(1)],
        })
        ..reply(200, {'ok': true});
      var ok = false;
      final s = syncWith(f, deliver: (a, c) async => ok);
      expect(await s.poll(force: true), 0);
      expect(log, ['GET /ai/answers']); // no ack
      ok = true;
      expect(await s.poll(force: true), 1);
      expect(log.last, 'POST /ai/answers/ack [1]');
    });

    test(
      'duplicate poll never duplicates; an ack that failed is retried without a second message',
      () async {
        await asked();
        var stored = 0;
        final f = Fake(log)
          ..reply(200, {
            'items': [answerItem(5)],
          })
          ..down() // the ack fails
          ..reply(200, {
            'items': [answerItem(5)],
          }) // the server sends it again
          ..reply(200, {'ok': true});
        var notified = 0;
        final s = syncWith(
          f,
          deliver: (a, c) async {
            stored++;
            return true;
          },
          notify: (n, t) async => notified++,
        );
        expect(await s.poll(force: true), 1);
        expect(await s.poll(force: true), 0);
        expect(stored, 1);
        expect(notified, 1, reason: 'the second poll brought nothing new: no second notification');
        expect(log.where((e) => e.startsWith('POST /ai/answers/ack')).length, 2);
      },
    );

    test('pagination: has_more → next page with since=next_since', () async {
      await asked();
      final f = Fake()
        ..reply(200, {
          'items': [answerItem(1)],
          'next_since': 11,
          'has_more': true,
        })
        ..reply(200, {'ok': true})
        ..reply(200, {
          'items': [answerItem(2)],
          'next_since': 12,
          'has_more': false,
        })
        ..reply(200, {'ok': true});
      final s = syncWith(f, deliver: (a, c) async => true);
      expect(await s.poll(force: true), 2);
      final gets = f.seen.where((o) => o.method == 'GET').toList();
      expect(gets.length, 2);
      expect(gets.last.queryParameters['since'], '11');
    });

    test('throttle ~100 s unless forced; 429 backs off ~30 min even when forced', () async {
      await asked();
      final f = Fake()
        ..reply(200, {'items': []})
        ..reply(429, {'error': 'rate_limited'});
      final s = syncWith(f, deliver: (a, c) async => true);
      await s.poll();
      await s.poll(); // too soon
      expect(f.seen.length, 1);
      clock = clock.add(const Duration(minutes: 5));
      await s.poll(force: true); // 429
      expect(s.lastResult, 'limited');
      await s.poll(force: true);
      expect(f.seen.length, 2, reason: 'blocked for 30 min');
      clock = clock.add(const Duration(minutes: 31));
      f.reply(200, {'items': []});
      await s.poll(force: true);
      expect(f.seen.length, 3);
    });

    test('offline / bad JSON never throws', () async {
      await asked();
      final f = Fake()
        ..down()
        ..reply(200, 'not json');
      final s = syncWith(f, deliver: (a, c) async => true);
      expect(await s.poll(force: true), 0);
      expect(await s.poll(force: true), 0);
      expect(s.lastResult, 'failed');
    });

    test(
      'the notification goes through the existing native channel: answerNotice + the Hindi title',
      () async {
        await asked();
        final calls = <MethodCall>[];
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
          const MethodChannel('com.wnm.granthprabandhan/downloads'),
          (c) async {
            calls.add(c);
            return null;
          },
        );
        addTearDown(
          () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .setMockMethodCallHandler(
                const MethodChannel('com.wnm.granthprabandhan/downloads'),
                null,
              ),
        );
        final f = Fake()
          ..reply(200, {
            'items': [answerItem(1, answer: 'उत्तर यह है')],
          })
          ..reply(200, {'ok': true});
        final s = AdminSync(
          dio: Dio()..httpClientAdapter = f,
          base: 'https://adm.test',
          appKey: '',
          iid: () => iid,
          now: () => clock,
          enabled: true,
          deliver: (a, c) async => true,
        );
        await s.poll(force: true);
        expect(calls.single.method, 'answerNotice');
        expect((calls.single.arguments as Map)['title'], 'आपका उत्तर आ गया है');
        expect((calls.single.arguments as Map)['text'], 'उत्तर यह है');
      },
    );
  });

  group('ChatController: admin messages', () {
    test(
      'delivered into the chat it was asked in; saved; shown as role admin; the same answer twice = one message; a re-answer shows again',
      () async {
        final store = ChatStore.fresh();
        final ctl = ChatController(client: CapClient(), store: store);
        final c = Conversation(id: 'chatcv1', title: 'पुरानी', created: 1, updated: 1)
          ..messages.add(const ChatMsg(role: 'user', text: 'प्रश्न 1?', at: 1));
        await store.save(c);
        const a = AdminAnswer(
          id: 1,
          question: 'प्रश्न 1?',
          answer: 'admin उत्तर',
          answeredAt: 1000,
        );
        expect(await ctl.deliverAdminAnswer(a, 'chatcv1'), isTrue);
        expect(await ctl.deliverAdminAnswer(a, 'chatcv1'), isTrue);
        var saved = (await store.load('chatcv1'))!;
        expect(saved.messages.where((m) => m.isAdmin).length, 1);
        final m = saved.messages.last;
        expect(m.isAdmin, isTrue);
        expect(m.text, 'admin उत्तर');
        expect(m.ask, 'प्रश्न 1?');
        expect(m.ref, '1@1000');
        await ctl.deliverAdminAnswer(
          const AdminAnswer(id: 1, question: 'प्रश्न 1?', answer: 'नया उत्तर', answeredAt: 2000),
          'chatcv1',
        );
        saved = (await store.load('chatcv1'))!;
        expect(saved.messages.where((m) => m.isAdmin).length, 2);
      },
    );

    test(
      'a deleted / unknown chat → a chat of its own, nothing lost; admin messages are not AI history',
      () async {
        final store = ChatStore.fresh();
        final client = CapClient();
        final ctl = ChatController(client: client, store: store);
        await ctl.deliverAdminAnswer(
          const AdminAnswer(id: 9, question: 'क्या?', answer: 'यह उत्तर', answeredAt: 5),
          'gone',
        );
        final list = await store.list();
        expect(list.length, 1);
        expect(list.single.title, 'admin का उत्तर');
        expect(ctl.current!.messages.single.isAdmin, isTrue);
      },
    );
  });

  group('cannot-answer rule + "ask the admin?" offer', () {
    test(
      'rule: no real source cited → cannot; refusal wording without an admin note → cannot; note cited → can',
      () {
        bool isP(int id) => id == 100;
        expect(aiCannotAnswer(answer: 'उत्तर', cited: const [], isPraman: isP), isTrue);
        expect(
          aiCannotAnswer(answer: 'उत्तर', cited: const [555], isPraman: isP),
          isTrue,
          reason: 'an id that is nothing we sent',
        );
        expect(aiCannotAnswer(answer: 'उत्तर यह है', cited: const [100], isPraman: isP), isFalse);
        expect(
          aiCannotAnswer(
            answer: 'दिए गए प्रमाणों में इसका सीधा उत्तर नहीं मिला',
            cited: const [100],
            isPraman: isP,
          ),
          isTrue,
        );
        expect(
          aiCannotAnswer(answer: 'सीधा उत्तर नहीं मिला', cited: [kNoteIdBase + 1], isPraman: isP),
          isFalse,
        );
        expect(aiCannotAnswer(answer: 'ठीक', cited: [kTopicIdBase + 1], isPraman: isP), isFalse);
      },
    );

    Future<ChatController> ctlWith(Fake f, CapClient client, {AdminKnowledge? kn}) async {
      final ctl = ChatController(
        client: client,
        store: ChatStore.fresh(),
        admin: syncWith(f),
        knowledge: kn ?? knowledgeWith(Fake()),
      );
      return ctl;
    }

    test(
      'cannot answer → offer; Yes sends (iid, question), shows the confirmation, offer gone',
      () async {
        final f = Fake()..reply(202, {'id': 3});
        final client = CapClient()..next = cannot;
        final ctl = await ctlWith(f, client);
        await ctl.send('अनजाना प्रश्न क्या है');
        expect(ctl.offer, isNotNull);
        await ctl.askAdmin();
        expect(ctl.offer, isNull);
        expect(jsonDecode(f.seen.single.data as String)['question'], 'अनजाना प्रश्न क्या है');
        expect(ctl.messages.last.text, contains('admin को भेज दिया'));
        expect(Store.I.getString(AdminSync.kConvMap), contains(ctl.current!.id));
      },
    );

    test('No → offer gone and nothing is sent; a normal answer has no offer', () async {
      final f = Fake();
      final client = CapClient()..next = cannot;
      final ctl = await ctlWith(f, client);
      await ctl.send('अनजाना प्रश्न क्या है');
      ctl.declineOffer();
      expect(ctl.offer, isNull);
      expect(f.seen, isEmpty);
      client.next = AiAnswer(answer: 'यह रहा उत्तर', cited: [100], provider: 't');
      await ctl.send('गीता क्या है');
      expect(ctl.offer, isNull);
    });

    test(
      'limit / offline: the offer stays with a friendly Hindi reason; Yes can be pressed again',
      () async {
        final f = Fake()
          ..down()
          ..reply(202, {'id': 4});
        final client = CapClient()..next = cannot;
        final ctl = await ctlWith(f, client);
        await ctl.send('अनजाना प्रश्न क्या है');
        await ctl.askAdmin();
        expect(ctl.offer!.message, contains('इंटरनेट'));
        await ctl.askAdmin();
        expect(ctl.offer, isNull);
        // the daily limit
        for (var i = 0; i < 4; i++) {
          f.reply(202, {'id': 10 + i});
          await ctl.send('दूसरा प्रश्न नंबर $i');
          await ctl.askAdmin();
        }
        await ctl.send('छठा प्रश्न है यह');
        await ctl.askAdmin();
        expect(ctl.offer!.message, contains('कल फिर'));
        expect(ctl.offer!.canRetry, isFalse);
      },
    );
  });

  group('admin notes + topics as /ask candidates', () {
    test(
      'ETag cache: 200 saved with its ETag; 304 keeps the copy and sends If-None-Match; a fresh instance uses the disk copy offline',
      () async {
        final f = Fake()
          ..reply(
            200,
            kb([
              {
                'id': 1,
                'question': 'सतलोक क्या है',
                'answer': 'सनातन परमधाम',
                'tags': ['सतलोक'],
              },
            ]),
            '"v3"',
          )
          ..reply(304, '');
        final k = knowledgeWith(f);
        expect(await k.refresh(), isTrue);
        expect(f.seen.first.headers.containsKey('If-None-Match'), isFalse);
        expect(k.notes.single.id, 1);
        expect(await k.refresh(), isFalse);
        expect(f.seen.last.headers['If-None-Match'], '"v3"');
        expect(k.lastResult, 'unchanged');
        expect(k.notes.length, 1);
        final off = Fake()..down();
        final k2 = knowledgeWith(off);
        await k2.loadCached();
        expect(k2.notes.single.question, 'सतलोक क्या है');
        expect(await k2.refresh(), isFalse); // offline: keeps the copy
        expect(k2.notes.length, 1);
      },
    );

    test('a bad body (wrong schema) is ignored and does not replace the good copy', () async {
      final f = Fake()
        ..reply(
          200,
          kb([
            {'id': 1, 'question': 'प्रश्न', 'answer': 'उत्तर'},
          ]),
          '"a"',
        )
        ..reply(200, jsonEncode({'schema': 2, 'items': []}), '"b"');
      final k = knowledgeWith(f);
      await k.refresh();
      await k.refresh();
      expect(k.lastResult, 'ignored');
      expect(k.notes.length, 1);
      expect(Store.I.getString(AdminKnowledge.kEtag), '"a"');
    });

    test(
      'the best notes + topics join the ask as marked candidates with ids that cannot clash; ≤ 12 in all',
      () async {
        final f = Fake()
          ..reply(
            200,
            kb([
              {
                'id': 1,
                'question': 'श्रीमद्भगवद्गीता अध्याय 15 में परम पद क्या है',
                'answer': 'परम पद सतलोक है',
                'tags': ['गीता'],
              },
              {'id': 2, 'question': 'बिल्कुल अलग विषय', 'answer': 'कुछ और'},
            ]),
          );
        final k = knowledgeWith(f);
        await k.refresh();
        final client = CapClient();
        final ctl = ChatController(
          client: client,
          store: ChatStore.fresh(),
          admin: syncWith(Fake()),
          knowledge: k,
        );
        await ctl.send('गीता अध्याय 15 में परम पद क्या है');
        final notes = client.last.where((c) => isNoteId(c.id)).toList();
        expect(notes.map((c) => c.id), [kNoteIdBase + 1]);
        expect(notes.single.granth, kNoteLabel);
        expect(notes.single.text, contains('सतलोक'));
        expect(client.last.where((c) => isTopicId(c.id)), isNotEmpty);
        expect(
          client.last
              .where((c) => !isNoteId(c.id) && !isTopicId(c.id))
              .every((c) => c.id < kNoteIdBase),
          isTrue,
        );
        expect(client.last.length, lessThanOrEqualTo(12));
        expect({for (final c in client.last) c.id}.length, client.last.length);
      },
    );

    test('nothing cached / offline → the ask still works with just the pramans', () async {
      final client = CapClient();
      final ctl = ChatController(
        client: client,
        store: ChatStore.fresh(),
        admin: syncWith(Fake()),
        knowledge: knowledgeWith(Fake()),
      );
      await ctl.send('गीता क्या है');
      expect(client.last.where((c) => isNoteId(c.id)), isEmpty);
      expect(client.last, isNotEmpty);
    });
  });

  group('ज्ञान चर्चा', () {
    test(
      'from an admin note: asks its question first; reveal shows the answer and the granth of its praman',
      () async {
        final f = Fake()
          ..reply(
            200,
            kb([
              {
                'id': 1,
                'question': 'गीता अध्याय 15 में परम पद क्या है',
                'answer': 'परम पद सतलोक है',
                'tags': [],
              },
            ]),
          );
        final k = knowledgeWith(f);
        await k.refresh();
        final ctl = ChatController(
          client: CapClient(),
          store: ChatStore.fresh(),
          admin: syncWith(Fake()),
          knowledge: k,
        );
        expect(await ctl.startGyan(), isTrue);
        expect(ctl.messages.last.text, contains('गीता अध्याय 15 में परम पद क्या है'));
        expect(
          ctl.messages.last.text,
          isNot(contains('सतलोक है')),
          reason: 'the answer waits for the reveal',
        );
        expect(ctl.gyan, isNotNull);
        await ctl.revealGyan();
        expect(ctl.gyan, isNull);
        expect(ctl.messages.last.text, contains('परम पद सतलोक है'));
        expect(ctl.messages.last.cited, isNotEmpty);
        expect(ctl.messages.last.cited.every((id) => Retriever.I.praman(id) != null), isTrue);
      },
    );

    test(
      'without notes: a topic is asked and the granths that hold its pramans are named',
      () async {
        final ctl = ChatController(
          client: CapClient(),
          store: ChatStore.fresh(),
          admin: syncWith(Fake()),
          knowledge: knowledgeWith(Fake()),
        );
        expect(await ctl.startGyan(), isTrue);
        expect(ctl.messages.last.text, contains('किस ग्रंथ में'));
        await ctl.revealGyan();
        expect(ctl.messages.last.text, contains('में मिलता है'));
        expect(ctl.messages.last.cited, isNotEmpty);
      },
    );
  });

  group('AI screen', () {
    testWidgets(
      'cannot answer → card → हाँ sends → confirmation; then the admin answer appears as its own bubble',
      (t) async {
        final f = Fake()..reply(202, {'id': 3});
        final client = CapClient()..next = cannot;
        final store = ChatStore.fresh();
        ChatController.I = ChatController(
          client: client,
          store: store,
          admin: syncWith(f),
          knowledge: knowledgeWith(Fake()),
        );
        await openApp(t);
        AppNav.I.go('#/ai');
        await settle(t);
        for (var i = 0; i < 400 && !ChatController.I.loaded; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
          await t.pump(const Duration(milliseconds: 50));
        }
        await settle(t, 4);
        // Not inside runAsync: the retrieval index was started in the widget zone.
        ChatController.I.send('अनजाना प्रश्न क्या है').ignore();
        for (
          var i = 0;
          i < 200 && (ChatController.I.sending || ChatController.I.offer == null);
          i++
        ) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
          await t.pump(const Duration(milliseconds: 50));
        }
        await settle(t, 6);
        expect(find.byKey(const ValueKey('ask-admin')), findsOneWidget);
        expect(find.text('क्या आप यह प्रश्न admin को भेजना चाहेंगे?'), findsOneWidget);
        await t.ensureVisible(find.byKey(const ValueKey('ask-admin-yes')));
        await t.tap(find.byKey(const ValueKey('ask-admin-yes')));
        for (var i = 0; i < 100 && ChatController.I.offer != null; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
          await t.pump(const Duration(milliseconds: 50));
        }
        await settle(t, 6);
        expect(find.byKey(const ValueKey('ask-admin')), findsNothing);
        expect(find.textContaining('admin को भेज दिया गया है'), findsOneWidget);
        expect(f.seen.length, 1);
        // Not inside runAsync: the chat store's queue lives in the widget zone.
        var delivered = false;
        ChatController.I
            .deliverAdminAnswer(
              const AdminAnswer(
                id: 3,
                question: 'अनजाना प्रश्न क्या है',
                answer: 'यह admin का जवाब',
                answeredAt: 7,
              ),
              ChatController.I.current!.id,
            )
            .then((_) => delivered = true);
        for (var i = 0; i < 200 && !delivered; i++) {
          await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 8)));
          await t.pump(const Duration(milliseconds: 50));
        }
        await settle(t, 6);
        expect(find.byKey(const ValueKey('admin-msg')), findsOneWidget);
        expect(find.text('admin का संदेश आया'), findsOneWidget);
        expect(find.textContaining('यह admin का जवाब'), findsOneWidget);
        expect(find.textContaining('आपका प्रश्न: अनजाना प्रश्न क्या है'), findsOneWidget);
      },
    );
  });

  testWidgets('ask-admin card + admin message + ज्ञान चर्चा pill: 320dp × 1.3 text, no overflow', (
    t,
  ) async {
    t.view.physicalSize = const Size(320, 640);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final o = AdminOffer('chatabc1', 'प्रश्न')
      ..message = 'आज के 5 प्रश्न भेजे जा चुके हैं। कल फिर कोशिश करें।';
    await t.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(1.3)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  AskAdminCard(offer: o, onYes: () {}, onNo: () {}),
                  const AdminBubble(
                    ChatMsg(
                      role: 'admin',
                      text: 'यह admin का लंबा उत्तर है जो कई पंक्तियों में जाता है',
                      ask: 'एक लंबा प्रश्न जो छोटी स्क्रीन पर टूटेगा',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await t.pump();
    expect(t.takeException(), isNull);
    expect(find.text('क्या आप यह प्रश्न admin को भेजना चाहेंगे?'), findsOneWidget);
  });
}
