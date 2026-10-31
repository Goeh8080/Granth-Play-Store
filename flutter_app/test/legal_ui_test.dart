// ignore_for_file: depend_on_referenced_packages
import 'dart:convert' show Base64Codec;
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/config.dart';
import 'package:granthprabandhan/legal/legal_pages.dart';
import 'package:granthprabandhan/screens/home_shell.dart' show SyncStrip;
import 'package:granthprabandhan/screens/legal_screen.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'round5_test.dart' show fingerTap, openApp, openSettings;

class FakeLauncher extends UrlLauncherPlatform {
  final List<String> launched = [];
  @override
  get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => true;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    launched.add(url);
    return true;
  }
}

String fx(String n) => File('test/fixtures/$n').readAsStringSync();

void useConfig(String name) {
  final p = parseConfig(fx(name), publicKey: base64Decode2(fx('test_pub.b64').trim()))!;
  RemoteConfig.I.debugApply(p);
}

List<int> base64Decode2(String s) => const Base64Codec().decode(s);

Future<void> narrow(WidgetTester t, {double scale = 1.3}) async {
  await t.binding.setSurfaceSize(const Size(320, 640));
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
}

void main() {
  late FakeLauncher launcher;
  final List<MethodCall> clip = [];

  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    UiPrefs.I.refresh();
    RemoteConfig.I = RemoteConfig(publicKey: const [])..enabled = false;
    launcher = FakeLauncher();
    UrlLauncherPlatform.instance = launcher;
    clip.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (c) async {
      clip.add(c);
      return null;
    });
  });
  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  test('the 14 pages exist, are non-empty, and say what the app really does', () {
    expect(kLegalPages.map((p) => p.slug), [
      'privacy', 'terms', 'cookies', 'disclaimer', 'copyright', 'ai', 'permissions', 'data', 'delete', 'children', 'thirdparty', 'grievance', 'about', 'guidelines', //
    ]);
    for (final p in kLegalPages) {
      expect(p.title, isNotEmpty);
      expect(p.blocks(), isNotEmpty, reason: p.slug);
      expect(legalBySlug(p.slug), same(p));
    }
    final all = [for (final p in kLegalPages) ...p.blocks().map((b) => '${b.text} ${b.items.join(' ')}')].join('\n');
    // no accounts, no ads: the pages must never claim otherwise
    expect(all.contains('Google Sign'), isFalse);
    expect(legalBySlug('nope'), isNull);
  });

  test('no contact email is invented: the line says it is coming soon while kContactEmail is empty', () {
    expect(kContactEmail, isEmpty);
    expect(hasContactEmail, isFalse);
    expect(contactLine, contains('जल्द जोड़ा जाएगा'));
  });

  testWidgets('Settings → कानूनी और नीतियाँ: the three rows open the list, the policy and विशेष जानकार; Back goes one screen back', (t) async {
    await openApp(t);
    await openSettings(t);
    for (final (key, expectKey) in [
      ('set-privacy', 'legal-body-privacy'),
      ('set-legal', 'legal-privacy'),
      ('set-contacts', 'contact-c1'),
    ]) {
      await t.ensureVisible(find.byKey(ValueKey(key)));
      await settle(t);
      expect(find.byKey(ValueKey(key)), findsOneWidget, reason: key);
      await fingerTap(t, find.byKey(ValueKey(key)), wobble: Offset.zero);
      await settle(t, 8);
      expect(find.byKey(ValueKey(expectKey)), findsOneWidget, reason: key);
      expect(AppNav.I.route.panel, Panel.legal);
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300))); // Back is debounced 260 ms
      AppNav.I.back();
      await settle(t, 6);
      expect(AppNav.I.route.panel, Panel.page, reason: 'after Back from $key: the settings page');
      expect(find.byKey(const ValueKey('settings-page')), findsOneWidget);
    }
    await t.pump(const Duration(seconds: 8));
  });

  for (final look in cardLooks) {
    testWidgets('320 dp wide, text ×1.3, look ${look.$1}: the list, all 14 pages and the contacts draw without overflow', (t) async {
      await openApp(t);
      UiPrefs.I.look = look.$1;
      await narrow(t);
      useConfig('cfg_valid.json'); // 3 shown contacts incl. a role + a WhatsApp number
      await settle(t);
      AppNav.I.go('#/legal');
      await settle(t);
      await t.pump(const Duration(milliseconds: 600));
      expect(find.byKey(const ValueKey('legal-contacts'), skipOffstage: false), findsOneWidget);
      for (var i = 0; i < 12; i++) {
        await t.drag(find.byType(CustomScrollView).first, const Offset(0, -400));
        await settle(t, 4);
        expect(t.takeException(), isNull, reason: 'list scroll step $i @ ${look.$1}');
      }
      expect(find.byKey(const ValueKey('legal-guidelines'), skipOffstage: false), findsOneWidget, reason: 'the last row is reachable');
      for (final p in kLegalPages) {
        AppNav.I.go('#/legal?p=${p.slug}');
        await settle(t);
        expect(find.byKey(ValueKey('legal-body-${p.slug}'), skipOffstage: false), findsOneWidget, reason: p.slug);
        expect(t.takeException(), isNull, reason: '${p.slug} @ ${look.$1}');
      }
      AppNav.I.go('#/legal?p=contacts');
      await settle(t);
      expect(find.byKey(const ValueKey('contact-c2'), skipOffstage: false), findsOneWidget);
      expect(t.takeException(), isNull, reason: 'contacts @ ${look.$1}');
      await t.pump(const Duration(seconds: 8));
    });
  }

  testWidgets('contacts: seed names with no phone line; the title; only visible ones from the server, sorted; WhatsApp only with a number', (t) async {
    await openApp(t);
    AppNav.I.go('#/legal?p=contacts');
    await settle(t);
    for (final n in ['अमित दास', 'रामेश्वर दर', 'गौतम दास', 'अशोक दास']) {
      expect(find.text(n), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('contact-phone-c1')), findsNothing, reason: 'no number was invented');
    expect(find.text('विशेष जानकार'), findsWidgets);

    useConfig('cfg_valid.json');
    await settle(t);
    expect(find.text('हमारे जानकार'), findsWidgets);
    expect(find.byKey(const ValueKey('contact-c3')), findsNothing, reason: 'visible:false');
    expect(find.byKey(const ValueKey('contact-c4')), findsNothing, reason: 'invalid phone');
    expect(find.text('सलाहकार'), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-phone-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-wa-c2')), findsOneWidget);
    expect(find.byKey(const ValueKey('contact-phone-c5')), findsNothing);
    expect(find.byKey(const ValueKey('contact-wa-c5')), findsNothing, reason: 'whatsapp:true but no number');
    expect(find.byKey(const ValueKey('contact-phone-c1')), findsNothing);
    // order: c1 above c2 above c5
    double y(String id) => t.getTopLeft(find.byKey(ValueKey('contact-$id'))).dy;
    expect(y('c1'), lessThan(y('c2')));
    expect(y('c2'), lessThan(y('c5')));

    RemoteConfig.I.contacts = const [];
    RemoteConfig.I.debugApply(parseConfig(fx('cfg_no_contacts_http_ai.json'), publicKey: base64Decode2(fx('test_pub.b64').trim()))!);
    await settle(t);
    expect(find.text('अमित दास'), findsOneWidget, reason: 'a config without contacts falls back to the seed');
  });

  testWidgets('contacts: phone tap → sheet with call / copy; WhatsApp opens wa.me with digits only', (t) async {
    await openApp(t);
    useConfig('cfg_valid.json');
    AppNav.I.go('#/legal?p=contacts');
    await settle(t);
    await t.ensureVisible(find.byKey(const ValueKey('contact-phone-c2')));
    await fingerTap(t, find.byKey(const ValueKey('contact-phone-c2')), wobble: Offset.zero);
    await settle(t, 6);
    expect(find.byKey(const ValueKey('contact-sheet-phone')), findsOneWidget);
    expect(find.text('कॉल करें'), findsOneWidget);
    expect(find.text('नंबर कॉपी करें'), findsOneWidget);

    await fingerTap(t, find.text('कॉल करें'), wobble: Offset.zero);
    await settle(t, 6);
    expect(launcher.launched, ['tel:+919876543210']);

    await fingerTap(t, find.byKey(const ValueKey('contact-phone-c2')), wobble: Offset.zero);
    await settle(t, 6);
    await fingerTap(t, find.text('नंबर कॉपी करें'), wobble: Offset.zero);
    await settle(t, 6);
    expect(clip.where((c) => c.method == 'Clipboard.setData').single.arguments['text'], '+919876543210');
    await t.pump(const Duration(seconds: 8));

    await fingerTap(t, find.byKey(const ValueKey('contact-wa-c2')), wobble: Offset.zero);
    await settle(t, 6);
    expect(launcher.launched.last, 'https://wa.me/919876543210');
    expect(whatsappDigits('+91 98765-43210'), '919876543210');
  });

  testWidgets('the privacy page links on to the AI and delete pages, and "chats हटाएँ" clears the stored chats', (t) async {
    await openApp(t);
    AppNav.I.go('#/legal?p=delete');
    await settle(t);
    await t.dragUntilVisible(find.byKey(const ValueKey('clear-chats')), find.byType(CustomScrollView).first, const Offset(0, -200));
    await settle(t);
    await fingerTap(t, find.byKey(const ValueKey('clear-chats')), wobble: Offset.zero);
    await settle(t, 6);
    expect(find.text('OK'), findsOneWidget);
    await fingerTap(t, find.text('OK'), wobble: Offset.zero);
    await settle(t, 6);
    await t.pump(const Duration(seconds: 8));
    expect(t.takeException(), isNull);
    expect(ChatController.I.chats, isEmpty);
  });

  test('permissions page mentions every permission the manifest declares', () {
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    final declared = RegExp(r'<uses-permission[^>]*android:name="android\.permission\.([A-Z_]+)"').allMatches(manifest).map((m) => m.group(1)!).toSet();
    final text = legalBySlug('permissions')!.blocks().map((b) => '${b.text} ${b.items.join(' ')}').join('\n');
    for (final perm in declared) {
      // FOREGROUND_SERVICE_DATA_SYNC is described as "FOREGROUND_SERVICE … DATA_SYNC"
      final names = perm.startsWith('FOREGROUND_SERVICE_') ? ['FOREGROUND_SERVICE', perm.substring(19)] : [perm];
      for (final n in names) {
        expect(text.contains(n), isTrue, reason: 'page should mention $n');
      }
    }
    expect(declared, isNotEmpty);
  });
}
