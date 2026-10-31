// Round 14 (expanded): Settings page, Account, Support tickets, FCM topics, feature switches.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/services/analytics.dart';
import 'package:granthprabandhan/services/firebase_bridge.dart';
import 'package:granthprabandhan/services/support.dart';
import 'package:granthprabandhan/state/router.dart';

import 'helpers.dart';

class Api implements HttpClientAdapter {
  final List<(int, Object)> replies;
  final List<RequestOptions> seen = [];
  final List<Object?> bodies = [];
  Api(this.replies);
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    seen.add(o);
    if (s != null) {
      final b = <int>[];
      await for (final x in s) {
        b.addAll(x);
      }
      bodies.add(b.isEmpty ? null : jsonDecode(utf8.decode(b)));
    } else {
      bodies.add(null);
    }
    final (code, body) = replies.isEmpty ? (200, <String, Object>{}) : replies.removeAt(0);
    return ResponseBody.fromString(jsonEncode(body), code, headers: {Headers.contentTypeHeader: ['application/json']});
  }

  @override
  void close({bool force = false}) {}
}

Future<void> settle(WidgetTester t, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

Future<void> narrow(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(320, 640));
  t.platformDispatcher.textScaleFactorTestValue = 1.3;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  setUp(() async {
    await setUpApp();
  });

  group('support tickets (CONTRACT §5.1)', () {
    test('create → 201, then mine lists tickets with the IST token label; reply and ack use the exact shapes', () async {
      final api = Api([
        (201, {'id': 12, 'token': 3, 'date': '2026-10-31', 'status': 'open', 'created_at': '2026-10-31T09:35:21Z'}),
        (200, {
          'items': [
            {'id': 12, 'token': 3, 'date': '2026-10-31', 'subject': 'PDF', 'message': 'नहीं खुलती', 'status': 'open', 'has_new_reply': true,
             'messages': [{'id': 1, 'from': 'user', 'text': 'नहीं खुलती', 'at': 'x'}, {'id': 2, 'from': 'admin', 'text': 'देखते हैं', 'at': 'y'}]},
          ],
          'count': 1,
          'unread': 1,
        }),
        (201, {'ok': true, 'id': 3, 'at': 'z'}),
        (200, {'items': [], 'count': 0, 'unread': 0}),
        (200, {'ok': true, 'updated': 1}),
        (200, {'items': [], 'count': 0, 'unread': 0}),
      ]);
      final dio = Dio(BaseOptions(responseType: ResponseType.plain, validateStatus: (s) => s != null && s < 600))..httpClientAdapter = api;
      final s = SupportService(dio: dio, base: 'https://h.example', iid: () => 'a' * 32, enabled: true);
      expect(await s.create('x'), isNotNull, reason: 'message must be 2..2000');
      expect(api.seen, isEmpty);
      expect(await s.create('PDF नहीं खुलती', subject: 'PDF'), isNull);
      expect(api.seen[0].method, 'POST');
      expect(api.seen[0].path, 'https://h.example/support/tickets');
      final b = api.bodies[0] as Map;
      expect(b['iid'], 'a' * 32);
      expect(b['message'], 'PDF नहीं खुलती');
      expect(b['subject'], 'PDF');
      expect(b.containsKey('app_version'), isTrue);
      expect(api.seen[1].uri.toString(), 'https://h.example/support/tickets/mine?iid=${'a' * 32}');
      expect(s.tickets.single.label, 'टोकन #3 · 31-10-2026');
      expect(s.tickets.single.hasNewReply, isTrue);
      expect(s.tickets.single.messages.last.fromAdmin, isTrue);
      expect(s.unread, 1);
      expect(await s.reply(12, 'धन्यवाद'), isNull);
      expect(api.seen[2].path, 'https://h.example/support/tickets/12/messages');
      expect(api.bodies[2], {'iid': 'a' * 32, 'message': 'धन्यवाद'});
      await s.ack([12]);
      final ackAt = api.seen.indexWhere((o) => o.path.endsWith('/support/tickets/ack'));
      expect(ackAt, greaterThan(0));
      expect(api.bodies[ackAt], {'iid': 'a' * 32, 'ids': [12]});
    });

    test('errors read in Hindi: 429 limit, 409 closed, 503 unavailable, no network', () {
      expect(SupportService.errorText(429, ''), contains('सीमा'));
      expect(SupportService.errorText(409, ''), contains('बंद'));
      expect(SupportService.errorText(503, ''), contains('उपलब्ध नहीं'));
      expect(SupportService.errorText(null, ''), contains('नेटवर्क'));
    });
  });

  test('Firebase events carry folder_id / granth_id / praman_id as strings; app_open is not double-logged', () {
    final got = <(String, Map<String, Object>)>[];
    final old = Analytics.forward;
    Analytics.forward = (n, p) => got.add((n, p));
    addTearDown(() => Analytics.forward = old);
    Analytics.I.named('folder_open', id: '7');
    Analytics.I.named('granth_open', id: '44');
    Analytics.I.named('pdf_download', id: '44');
    Analytics.I.named('app_open');
    expect(got.map((e) => e.$1), ['folder_open', 'granth_open', 'pdf_download']);
    expect(got[0].$2, {'folder_id': '7'});
    expect(got[1].$2, {'granth_id': '44'});
  });

  group('FCM (CONTRACT §6.3)', () {
    test('exact topic names; all is always kept; data.id opens the right screen', () {
      expect(PushTopics.every, ['all', 'daily', 'new_praman', 'new_topic', 'trending']);
      expect(FirebaseBridge.I.topics, {...PushTopics.every});
      expect(FirebaseBridge.linkFor({'topic': 'new_praman', 'id': '345'}), '#/pramans?id=345');
      expect(FirebaseBridge.linkFor({'topic': 'daily', 'id': '345'}), '#/pramans?id=345');
      expect(FirebaseBridge.linkFor({'topic': 'new_topic', 'id': 'vrat'}), '#/pramans?topic=vrat');
      expect(FirebaseBridge.linkFor({'topic': 'trending', 'id': '12'}), '#/pramans?topic=12');
      expect(FirebaseBridge.linkFor({'topic': 'all', 'id': '9', 'kind': 'granth'}), '#/pramans?granth=9');
      expect(FirebaseBridge.linkFor({'topic': 'all'}), isNull);
      expect(FirebaseBridge.linkFor({'topic': 'all', 'id': '../x'}), isNull);
    });
  });

  group('pages', () {
    testWidgets('Settings is a full page with every section (320dp × 1.3); Account and Support open from it; Back goes one screen back', (t) async {
      await narrow(t);
      await t.pumpWidget(const GranthApp(splash: false, links: false));
      await settle(t);
      AppNav.I.go('#/topics');
      await settle(t);
      AppNav.I.openLink('#/settings');
      await settle(t);
      expect(AppNav.I.route.panel, Panel.page);
      expect(find.byKey(const ValueKey('settings-page'), skipOffstage: false), findsOneWidget);
      for (final s in ['display', 'downloads', 'notify', 'account', 'ai', 'about']) {
        expect(find.byKey(ValueKey('set-sec-$s'), skipOffstage: false), findsOneWidget, reason: s);
      }
      for (final p in ['daily', 'new_praman', 'new_topic', 'trending']) {
        expect(find.byKey(ValueKey('set-push-$p-on'), skipOffstage: false), findsOneWidget, reason: p);
      }
      expect(t.takeException(), isNull);

      await t.ensureVisible(find.byKey(const ValueKey('set-account'), skipOffstage: false));
      await settle(t, 4);
      await t.tap(find.byKey(const ValueKey('set-account'), skipOffstage: false));
      await settle(t);
      expect(find.byKey(const ValueKey('account-page'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const ValueKey('account-google'), skipOffstage: false), findsOneWidget, reason: 'signed out: optional login button');
      expect(find.byKey(const ValueKey('account-logout'), skipOffstage: false), findsNothing);
      expect(t.takeException(), isNull);

      await FirebaseBridge.I.debugSetAccount(const AccountInfo(email: 'bhakt@gmail.com', name: 'राम दास', photo: ''));
      await settle(t, 4);
      expect(find.text('bhakt@gmail.com', skipOffstage: false), findsOneWidget);
      expect(find.text('राम दास', skipOffstage: false), findsOneWidget);
      expect(find.byKey(const ValueKey('account-bhakt-id'), skipOffstage: false), findsNothing, reason: 'hidden unless config enables it');
      expect(t.takeException(), isNull);

      await t.ensureVisible(find.byKey(const ValueKey('account-support'), skipOffstage: false));
      await settle(t, 4);
      await t.tap(find.byKey(const ValueKey('account-support'), skipOffstage: false));
      await settle(t);
      expect(find.byKey(const ValueKey('support-page'), skipOffstage: false), findsOneWidget);
      expect(find.byKey(const ValueKey('support-message'), skipOffstage: false), findsOneWidget);
      expect(t.takeException(), isNull);

      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.byKey(const ValueKey('account-page'), skipOffstage: false), findsOneWidget);
      await t.ensureVisible(find.byKey(const ValueKey('account-logout'), skipOffstage: false));
      await settle(t, 4);
      await t.tap(find.byKey(const ValueKey('account-logout'), skipOffstage: false));
      await settle(t);
      expect(FirebaseBridge.I.signedIn, isFalse);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.binding.handlePopRoute();
      await settle(t);
      expect(find.byKey(const ValueKey('settings-page'), skipOffstage: false), findsOneWidget);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.route.panel, Panel.topics);
      await t.pump(const Duration(seconds: 8));
    });
  });
}
