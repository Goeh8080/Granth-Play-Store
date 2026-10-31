import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/login_screen.dart';
import 'package:granthprabandhan/services/firebase_bridge.dart';
import 'package:granthprabandhan/services/local_stats.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'helpers.dart';

Future<void> settle(WidgetTester t, [int n = 14]) async {
  for (var i = 0; i < n; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  setUp(setUpApp);
  tearDown(() => LoginGate.enabled = false);

  test('ui.grid_pages: known pages only, invalid values ignored (CONTRACT §4.1.1), numbers only', () {
    final m = parseGridPages({
      'grid_pages': {'granths': 3, 'shelves': 1, 'topics': 9, 'gallery': 0, 'bogus': 2, 'pramans': 'x', 'dashboard': 2},
    });
    expect(m, {'granths': 3, 'shelves': 1, 'dashboard': 2});
    expect(parseGridPages(null), isEmpty);
    expect(parseGridPages({'grid_pages': 'no'}), isEmpty);
  });

  test('gridFor: page value, then ui.grid', () {
    RemoteConfig.I.uiGridPages = {'topics': 1};
    RemoteConfig.I.uiGrid = 2;
    expect(RemoteConfig.I.gridFor('topics'), 1);
    expect(RemoteConfig.I.gridFor('gallery'), 2);
    RemoteConfig.I.uiGrid = null;
    expect(RemoteConfig.I.gridFor('gallery'), isNull);
  });

  test('LocalStats counts only known events and days active', () {
    final s = LocalStats.I;
    s.record('app_open', now: DateTime(2026, 10, 30));
    s.record('app_open', now: DateTime(2026, 10, 30, 20));
    s.record('app_open', now: DateTime(2026, 10, 31));
    s.record('ai_ask');
    s.record('something_else');
    expect(s.count('app_open'), 3);
    expect(s.count('ai_ask'), 1);
    expect(s.count('something_else'), 0);
    expect(s.daysActive, 2);
    expect(s.since, '2026-10-30');
  });

  testWidgets('Login page: shows on first launch, बाद में skips and is remembered', (t) async {
    LoginGate.enabled = true;
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await settle(t);
    expect(find.byKey(const ValueKey('login-page')), findsOneWidget);
    expect(find.text('Sign in with Google'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('login-skip')));
    await settle(t);
    expect(find.byKey(const ValueKey('login-page')), findsNothing);
    expect(LoginGate.seen, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await settle(t);
    expect(find.byKey(const ValueKey('login-page')), findsNothing);
  });

  testWidgets('Login page: signed-in users skip it', (t) async {
    LoginGate.enabled = true;
    await FirebaseBridge.I.debugSetAccount(const AccountInfo(email: 'a@gmail.com', name: 'A'));
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await settle(t);
    expect(find.byKey(const ValueKey('login-page')), findsNothing);
    expect(find.byKey(const ValueKey('mast-account')), findsOneWidget);
    await FirebaseBridge.I.debugSetAccount(null);
  });

  testWidgets('Login page: Back exits the app', (t) async {
    LoginGate.enabled = true;
    final calls = <String>[];
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.wnm.granthprabandhan/downloads'), (c) async {
      calls.add(c.method);
      return null;
    });
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await settle(t);
    await t.binding.handlePopRoute();
    await settle(t);
    expect(calls, contains('exitApp'));
    expect(find.byKey(const ValueKey('login-page')), findsOneWidget);
    t.binding.defaultBinaryMessenger.setMockMethodCallHandler(const MethodChannel('com.wnm.granthprabandhan/downloads'), null);
  });
}
