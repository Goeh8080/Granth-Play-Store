import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/chat_controller.dart';
import 'package:granthprabandhan/ai/chat_store.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/ai_screen.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';

import 'ai_chat_ui_test.dart' show GateClient, catalog, until;
import 'helpers.dart';
import 'legal_ui_test.dart' show useConfig;
import 'links_grid_test.dart' show settle;

/// Golden-free previews of the Round 12 screens (real fonts), only when PREVIEW_DIR is set:
///   PREVIEW_DIR=/workspace flutter test test/preview_screens_test.dart
void main() {
  final dir = Platform.environment['PREVIEW_DIR'];
  late GateClient client;
  setUp(() async {
    await setUpApp();
    Places.forgetLive();
    Retriever.I.reset();
    CatalogStore.I.debugSetCatalog(catalog());
    client = GateClient();
    ChatController.I = ChatController(client: client, store: ChatStore.fresh());
    RemoteConfig.I = RemoteConfig(publicKey: const [])..enabled = false;
  });

  Future<GlobalKey> boot(WidgetTester t, {double w = 412, double h = 915, double scale = 1}) async {
    const fonts = {
      'NotoDeva': ['NotoSansDevanagari-Regular', 'NotoSansDevanagari-Medium', 'NotoSansDevanagari-SemiBold'],
      'DMSans': ['DMSans-Regular', 'DMSans-Medium', 'DMSans-SemiBold'],
      'YatraOne': ['YatraOne-Devanagari'],
      'YatraOneLatin': ['YatraOne-Latin'],
      'NotoDevaFull': ['NotoSansDevanagari-Full'],
      'TiroDevanagari': ['TiroDevanagariSanskrit-Regular'],
    };
    await t.runAsync(() async {
      for (final e in fonts.entries) {
        final l = FontLoader(e.key);
        for (final f in e.value) {
          l.addFont(Future.value(ByteData.sublistView(File('assets/fonts/$f.ttf').readAsBytesSync())));
        }
        await l.load();
      }
    });
    await t.binding.setSurfaceSize(Size(w * 2, h * 2));
    t.view.devicePixelRatio = 2;
    if (scale != 1) {
      t.platformDispatcher.textScaleFactorTestValue = scale;
      addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    }
    addTearDown(() => t.binding.setSurfaceSize(null));
    addTearDown(t.view.resetDevicePixelRatio);
    final key = GlobalKey();
    await t.pumpWidget(RepaintBoundary(key: key, child: const GranthApp(splash: false, links: false)));
    await settle(t);
    return key;
  }

  Future<void> snap(WidgetTester t, GlobalKey key, String name) async {
    await t.runAsync(() async {
      final img = await (key.currentContext!.findRenderObject() as RenderRepaintBoundary).toImage(pixelRatio: 1);
      final d = await img.toByteData(format: ui.ImageByteFormat.png);
      File('$dir/$name').writeAsBytesSync(d!.buffer.asUint8List());
    });
    expect(File('$dir/$name').lengthSync(), greaterThan(8000));
  }

  testWidgets('legal list, a policy page, contacts', skip: dir == null, (t) async {
    final key = await boot(t);
    useConfig('cfg_valid.json');
    AppNav.I.go('#/legal');
    await settle(t, 20);
    await snap(t, key, 'preview_legal.png');
    AppNav.I.go('#/legal?p=privacy');
    await settle(t, 20);
    await snap(t, key, 'preview_legal_page.png');
    AppNav.I.go('#/legal?p=contacts');
    await settle(t, 20);
    await snap(t, key, 'preview_contacts.png');
    await t.pump(const Duration(seconds: 8));
  });

  testWidgets('contacts at 320 dp, text x1.3', skip: dir == null, (t) async {
    final key = await boot(t, w: 320, h: 640, scale: 1.3);
    useConfig('cfg_valid.json');
    AppNav.I.go('#/legal?p=contacts');
    await settle(t, 20);
    await snap(t, key, 'preview_contacts_320.png');
    await t.pump(const Duration(seconds: 8));
  });

  testWidgets('AI chat with a fake answer', skip: dir == null, (t) async {
    final key = await boot(t);
    final p = CatalogStore.I.pramans;
    client.next = AiAnswer(
      answer: '**कर्म योग** का अर्थ है फल की चिंता किए बिना कर्म करना।\n- पहला बिंदु: कर्म करना हमारा अधिकार है।\n- दूसरा बिंदु: फल पर अधिकार नहीं।',
      cited: [for (final x in p.take(3)) int.parse(x.id)],
      provider: 'preview',
    );
    AppNav.I.go('#/ai');
    await settle(t);
    await until(t, () => ChatController.I.loaded);
    unawaited(askQuestion('कर्म योग क्या है?'));
    await until(t, () => ChatController.I.messages.length == 2);
    await settle(t, 10);
    await snap(t, key, 'preview_ai_chat.png');
    await t.pump(const Duration(seconds: 8));
  });
}
