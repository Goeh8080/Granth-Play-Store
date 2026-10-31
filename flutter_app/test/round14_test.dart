import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/sanitize.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/ai_feedback.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/today_card.dart';

import 'package:granthprabandhan/widgets/common.dart';
import 'helpers.dart';
import 'round5_test.dart' show fingerTap, realPause;

class Fake implements HttpClientAdapter {
  final List<int> codes;
  final List<RequestOptions> seen = [];
  Fake(this.codes);
  @override
  Future<ResponseBody> fetch(RequestOptions o, Stream<Uint8List>? s, Future<void>? c) async {
    seen.add(o);
    if (s != null) await s.drain<void>();
    final code = codes.isEmpty ? 200 : codes.removeAt(0);
    return ResponseBody.fromString('{}', code, headers: {Headers.contentTypeHeader: ['application/json']});
  }
  @override
  void close({bool force = false}) {}
}

Future<void> settle(WidgetTester t, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(setUpApp);

  group('sanitizer', () {
    String name(int id) => id == 467 ? 'जीव हमारी जाति है' : '';
    test('id-467 becomes the praman name; unknown ids vanish', () {
      expect(sanitizeAiText('देखें id-467 में।', (i) => i == 467 ? 'जीव' : null), 'देखें “जीव” में।');
      expect(sanitizeAiText('प्रमाण (ID: 999) है', (_) => null), 'प्रमाण है');
      expect(sanitizeAiText('[id=467]', name), '(“जीव हमारी जाति है”)');
      expect(sanitizeAiText('सादा पाठ 467 बार', name), 'सादा पाठ 467 बार');
    });
  });

  group('AI feedback queue', () {
    AiFeedback make(Fake f) => AiFeedback(dio: Dio()..httpClientAdapter = f, base: 'https://a.test', appKey: 'k', iid: () => 'iid1', enabled: true);
    test('404 keeps the flag queued; a later 200 sends and removes it', () async {
      final f = Fake([404, 200]);
      final fb = make(f);
      await fb.down('c-1', question: 'प्रश्न', answer: 'उत्तर', reason: 'गलत');
      expect(fb.vote('c-1'), -1);
      expect(f.seen.single.uri.toString(), 'https://a.test/ai/flags');
      final body = f.seen.single.data is String ? jsonDecode(f.seen.single.data as String) : f.seen.single.data;
      expect(body['kind'], 'thumbs_down');
      expect(body['reason'], 'गलत');
      expect(await fb.flush(), 1); // the 200 sends it
      expect(f.seen.length, 2);
      expect(await fb.flush(), 0);
      expect(f.seen.length, 2); // queue is empty now
    });
    test('thumbs up toggles', () {
      final fb = make(Fake([]));
      fb.up('x');
      expect(fb.vote('x'), 1);
      fb.up('x');
      expect(fb.vote('x'), 0);
    });
  });

  group('daily praman', () {
    final ps = [for (var i = 1; i <= 9; i++) Praman({'id': '$i', 'title': 'P$i'})];
    test('deterministic per date; config pick wins on its date only', () {
      final d = DateTime(2026, 10, 31);
      expect(dailyPraman(ps, null, d)!.id, dailyPraman(ps.reversed.toList(), null, d)!.id);
      expect(dailyPraman(ps, const DailyPick('5', '2026-10-31'), d)!.id, '5');
      expect(dailyPraman(ps, const DailyPick('5', '2026-10-30'), d)!.id, dailyPraman(ps, null, d)!.id);
      expect(dailyPraman(ps, const DailyPick('77', ''), d)!.id, dailyPraman(ps, null, d)!.id);
      expect(dailyPraman(const [], null, d), isNull);
    });
  });

  group('floating Ask Tatv AI', () {
    testWidgets('opens AI from topics; Back returns to topics; hidden on AI (320dp × 1.3)', (t) async {
      await t.binding.setSurfaceSize(const Size(320, 640));
      t.platformDispatcher.textScaleFactorTestValue = 1.3;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
      await t.pumpWidget(const GranthApp(splash: false, links: false));
      await settle(t);
      AppNav.I.go('#/topics');
      await settle(t);
      final fab = find.byKey(const ValueKey('ask-ai-fab'));
      expect(fab, findsOneWidget);
      expect(t.takeException(), isNull);
      await t.tap(fab);
      await settle(t);
      expect(AppNav.I.route.panel, Panel.ai);
      expect(fab, findsNothing);
      await t.binding.handlePopRoute();
      await settle(t);
      expect(AppNav.I.route.panel, Panel.topics);
      expect(RemoteConfig.I.aiEnabled, isTrue);
    });
  });

  testWidgets('menu Topic opens the today sheet; all-topics goes to Topics (320dp × 1.3)', (t) async {
    await t.binding.setSurfaceSize(const Size(320, 640));
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await settle(t);
    await fingerTap(t, find.byWidgetPredicate((w) => w is GIcon && w.name == 'menu'), wobble: Offset.zero);
    await realPause(t);
    await t.pumpAndSettle();
    final nav = find.byKey(const ValueKey('nav-trending-up'));
    expect(t.getTopLeft(nav).dy, greaterThan(t.getTopLeft(find.byKey(const ValueKey('nav-highlighter'))).dy));
    await fingerTap(t, nav, wobble: Offset.zero);
    await realPause(t);
    await settle(t);
    expect(find.byKey(const ValueKey('today-all-topics')), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.tap(find.byKey(const ValueKey('today-all-topics')));
    await settle(t);
    expect(AppNav.I.route.panel, Panel.topics);
  });
}
