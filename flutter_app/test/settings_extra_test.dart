import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/main.dart';
import 'package:granthprabandhan/screens/home_shell.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/state/ui_prefs.dart';
import 'package:granthprabandhan/widgets/common.dart';
import 'package:granthprabandhan/widgets/zoom.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers.dart';
import 'links_grid_test.dart' show settle;
import 'offline_test.dart' show FakeNet, pictureCatalog;
import 'round3_test.dart' show FakeApi;
import 'round5_test.dart' show fingerTap, openApp, openFolder, openSettings, realPause;

const _native = MethodChannel('com.wnm.granthprabandhan/downloads');
const _share = MethodChannel('dev.fluttercommunity.plus/share');

double scaleAt(WidgetTester t, Finder f) => MediaQuery.textScalerOf(t.element(f)).scale(10);

void main() {
  late List<MethodCall> native;
  late List<MethodCall> shared;

  setUp(() async {
    await setUpApp();
    TouchCount.reset();
    AppZoom.current.value = ZoomView.identity;
    SyncStrip.open.value = false;
    UiPrefs.I.refresh();
    native = [];
    shared = [];
    PackageInfo.setMockInitialValues(appName: 'ग्रंथ प्रबंधन', packageName: 'com.wnm.granthprabandhan', version: '1.0.0', buildNumber: '1', buildSignature: '');
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_native, (c) async {
      native.add(c);
      return null;
    });
    m.setMockMethodCallHandler(_share, (c) async {
      shared.add(c);
      return 'dev.fluttercommunity.plus/share/unavailable';
    });
  });

  tearDown(() {
    final m = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_native, null);
    m.setMockMethodCallHandler(_share, null);
  });

  testWidgets("all of ashok's settings are still there, in his order, before the new ones", (t) async {
    await openApp(t);
    await openSettings(t);
    double y(String key) => t.getTopLeft(find.byKey(ValueKey(key))).dy;
    expect(y('set-pdf-fill90'), lessThan(y('set-layout-1')));
    expect(y('set-layout-1'), lessThan(y('set-text-normal')));
    expect(y('set-text-normal'), lessThan(y('set-anim-on')));
    await t.binding.handlePopRoute();
    await settle(t, 6);
    await openFolder(t, 'about');
    expect(find.text('Version 1.0.0', skipOffstage: false), findsOneWidget, reason: 'from package info');
  });

  testWidgets('अक्षर का आकार: small / large / normal change text app-wide and are saved', (t) async {
    await openApp(t);
    final dash = find.text('Dashboard');
    expect(scaleAt(t, dash), 10);
    await openSettings(t);
    for (final (id, s) in [('large', 11.5), ('small', 9.0), ('normal', 10.0), ('large', 11.5)]) {
      await fingerTap(t, find.byKey(ValueKey('set-text-$id')));
      await settle(t, 2);
      expect(UiPrefs.I.textSize, id);
      expect(Store.I.getString(Store.kTextSize), id);
      expect(scaleAt(t, find.byKey(ValueKey('set-text-$id'))), closeTo(s, 0.001), reason: 'settings sheet itself');
    }
    await fingerTap(t, find.text('पीछे'));
    await settle(t, 6);
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300))); // Back is debounced 260 ms
    await fingerTap(t, find.text('पीछे'));
    await settle(t, 6);
    expect(scaleAt(t, dash), closeTo(11.5, 0.001), reason: 'dashboard');
    // Large text on every screen: nothing overflows.
    for (final h in ['#/topics', '#/granths', '#/pramans', '#/granths?granth=11']) {
      AppNav.I.go(h);
      await settle(t);
      expect(t.takeException(), isNull, reason: h);
    }
    // With the phone's own text already large, the 1.3 cap still holds.
    t.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
    await settle(t, 3);
    expect(scaleAt(t, find.text('Granths').first), closeTo(13, 0.001));
    expect(t.takeException(), isNull);
  });

  testWidgets('अपने-आप सिंक बंद: the 2-minute sync stops; चालू: it runs again', (t) async {
    final api = FakeApi(sampleCatalog());
    final s = CatalogStore(api: api, connectivity: const Stream.empty())..debugSetCatalog(sampleCatalog());
    CatalogStore.I = s;
    FakeNet(s);
    await openApp(t);
    await openSettings(t, 'downloads');
    expect(UiPrefs.I.autoSync, isTrue, reason: 'default on');
    await fingerTap(t, find.byKey(const ValueKey('set-auto-sync-off')));
    await t.pump();
    expect(Store.I.getString(Store.kAutoSync), '0');
    await t.runAsync(s.autoSync);
    expect(api.calls, 0);
    await fingerTap(t, find.byKey(const ValueKey('set-auto-sync-on')));
    await t.pump();
    await t.runAsync(s.autoSync);
    expect(api.calls, 1);
  });

  testWidgets('सिर्फ़ WiFi पर: on mobile data background downloads wait; turning it off starts them; सिंक still works', (t) async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    s.debugSetNet([ConnectivityResult.mobile]);
    await openApp(t);
    await openSettings(t, 'downloads');
    expect(UiPrefs.I.wifiOnly, isFalse, reason: 'default off: downloads as before');
    await fingerTap(t, find.byKey(const ValueKey('set-wifi-only-on')));
    await t.pump();
    expect(Store.I.getString(Store.kWifiOnly), '1');
    s.savePages();
    await settle(t, 5);
    expect(net.calls, isEmpty, reason: 'no download on mobile data');
    // On WiFi it downloads.
    s.debugSetNet([ConnectivityResult.wifi]);
    s.savePages();
    await settle(t, 5);
    expect(net.saved.length, 11);
  });

  testWidgets('सिर्फ़ WiFi पर → बंद while on mobile data: the waiting download starts at once', (t) async {
    final s = CatalogStore.I..debugSetCatalog(pictureCatalog());
    final net = FakeNet(s);
    s.debugSetNet([ConnectivityResult.mobile]);
    UiPrefs.I.wifiOnly = true;
    await openApp(t);
    s.savePages();
    await settle(t, 3);
    expect(net.calls, isEmpty);
    await openSettings(t, 'downloads');
    await fingerTap(t, find.byKey(const ValueKey('set-wifi-only-off')));
    await settle(t, 5);
    expect(net.saved.length, 11);
  });

  testWidgets('स्क्रीन चालू रखें: sends keep-screen-on to Android and is saved', (t) async {
    await openApp(t);
    await openSettings(t, 'downloads');
    expect(UiPrefs.I.keepAwake, isFalse, reason: 'default off');
    await fingerTap(t, find.byKey(const ValueKey('set-keep-awake-on')));
    await t.pump();
    expect(native.where((c) => c.method == 'keepScreenOn').last.arguments, {'on': true});
    expect(Store.I.getString(Store.kKeepAwake), '1');
    await fingerTap(t, find.byKey(const ValueKey('set-keep-awake-off')));
    await t.pump();
    expect(native.where((c) => c.method == 'keepScreenOn').last.arguments, {'on': false});
    // Applied again at the next start.
    await fingerTap(t, find.byKey(const ValueKey('set-keep-awake-on')));
    await t.pump();
    native.clear();
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(const GranthApp(splash: false, links: false));
    await t.pump();
    expect(native.where((c) => c.method == 'keepScreenOn').single.arguments, {'on': true});
  });

  testWidgets('स्टोरेज: saved pages n / total + space; "जाँचें और ठीक करें" runs the check and repair', (t) async {
    final api = FakeApi(pictureCatalog());
    final s = CatalogStore(api: api, connectivity: const Stream.empty())..debugSetCatalog(pictureCatalog());
    CatalogStore.I = s;
    final net = FakeNet(s);
    var verified = 0;
    s.verifyPages = (all, progress) async {
      verified++;
      progress(all.length);
      return all.where(net.saved.contains).toSet();
    };
    s.minManualShow = Duration.zero;
    await t.runAsync(() => File('${Store.I.imagesDir}/x.jpg').writeAsBytes(List.filled(3 << 20, 1)));
    await openApp(t);
    await openSettings(t, 'downloads');
    await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 300)));
    await settle(t, 2);
    expect(find.text('सेव पेज 0 / 11 · 3.0 MB'), findsOneWidget);
    await fingerTap(t, find.byKey(const ValueKey('set-repair')));
    for (var i = 0; i < 30 && (s.images.running || verified == 0); i++) {
      await t.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await t.pump(const Duration(milliseconds: 50));
    }
    expect(api.calls, 1, reason: 'same as the सिंक button: lists again');
    expect(verified, 1, reason: 'every saved page checked');
    expect(net.saved.length, 11, reason: 'missing pages downloaded');
    await settle(t, 3);
    expect(find.textContaining('सेव पेज 11 / 11'), findsOneWidget);
  });

  testWidgets('ऐप के बारे में: share sends the app link', (t) async {
    await openApp(t);
    await openSettings(t, 'about');
    await fingerTap(t, find.byKey(const ValueKey('set-share-app')));
    await t.pump(const Duration(milliseconds: 100));
    expect(shared, isNotEmpty);
    expect('${shared.last.arguments}', contains(kPlayStoreUrl));
    expect(t.takeException(), isNull);
  });

  testWidgets('सेटिंग रीसेट: asks first; resets every setting; never deletes saved data', (t) async {
    await openApp(t);
    final page = File('${Store.I.imagesDir}/keep.jpg');
    await t.runAsync(() => page.writeAsBytes([1, 2, 3]));
    UiPrefs.I.look = 'bento';
    UiPrefs.I.textSize = 'large';
    UiPrefs.I.autoSync = false;
    UiPrefs.I.wifiOnly = true;
    UiPrefs.I.keepAwake = true;
    UiPrefs.I.setLayout(1);
    await settle(t, 2);
    await openSettings(t, 'about');
    // Cancel keeps everything.
    await fingerTap(t, find.byKey(const ValueKey('set-reset')));
    await settle(t, 5);
    await t.tap(find.text('रद्द करें'));
    await settle(t, 5);
    expect(UiPrefs.I.look, 'bento');
    await realPause(t);
    await fingerTap(t, find.byKey(const ValueKey('set-reset')));
    await settle(t, 5);
    await t.tap(find.text('OK'));
    await settle(t, 8);
    expect(UiPrefs.I.look, 'classic');
    expect(UiPrefs.I.textSize, 'normal');
    expect(UiPrefs.I.textFactor.value, 1.0);
    expect(UiPrefs.I.autoSync, isTrue);
    expect(UiPrefs.I.wifiOnly, isFalse);
    expect(UiPrefs.I.keepAwake, isFalse);
    expect(UiPrefs.I.uiCols, 2);
    final prefs = await SharedPreferences.getInstance();
    for (final k in UiPrefs.settingKeys) {
      expect(prefs.get(k), isNull, reason: k);
    }
    expect(native.where((c) => c.method == 'keepScreenOn').last.arguments, {'on': false});
    expect(await t.runAsync(page.exists), isTrue, reason: 'saved pages stay');
    expect(CatalogStore.I.granths, isNotEmpty, reason: 'granth data stays');
    expect(find.text('सेटिंग रीसेट हो गई'), findsOneWidget);
    await t.pump(const Duration(seconds: 5)); // toast leaves
  });
}
