import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/config.dart';
import 'package:granthprabandhan/models/structure.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/ed25519.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/services/shelves.dart';
import 'package:granthprabandhan/services/storage.dart';

import 'helpers.dart';
import 'round10_folders_test.dart' show realCatalog;

String fx(String n) => File('test/fixtures/$n').readAsStringSync();
final List<int> testKey = base64Decode(fx('test_pub.b64').trim());

/// A scripted server: each call pops the next reply.
class Server implements HttpClientAdapter {
  final List<({int status, String body, String? etag, bool fail})> replies = [];
  final List<RequestOptions> seen = [];
  void ok(String body, {String etag = '"e1"'}) => replies.add((status: 200, body: body, etag: etag, fail: false));
  void notModified() => replies.add((status: 304, body: '', etag: null, fail: false));
  void down() => replies.add((status: 0, body: '', etag: null, fail: true));

  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    seen.add(options);
    final r = replies.removeAt(0);
    if (r.fail) throw DioException.connectionError(requestOptions: options, reason: 'offline');
    return ResponseBody.fromString(r.body, r.status, headers: {
      Headers.contentTypeHeader: ['text/html'], // like the real server: JSON text, odd content type
      if (r.etag != null) 'etag': [r.etag!],
    });
  }

  @override
  void close({bool force = false}) {}
}

RemoteConfig make(Server s, {int build = 1}) {
  final dio = Dio()..httpClientAdapter = s;
  return RemoteConfig(dio: dio, url: 'https://cfg.test/config.json', build: build, publicKey: testKey)..enabled = true;
}

void main() {
  setUp(() async {
    await setUpApp();
    CatalogStore.I.debugSetCatalog(realCatalog());
    Shelves.useRemote(null, const {});
  });

  group('parseConfig', () {
    ParsedConfig? parse(String name, {int cached = 0, int build = 1, void Function(String)? why}) => parseConfig(fx(name), cachedVersion: cached, appBuild: build, publicKey: testKey, why: why);

    test('a valid config: structure, hidden ids, announcement, ai endpoint, contacts', () {
      final p = parse('cfg_valid.json')!;
      expect(p.version, 5);
      expect(p.hidden, {'7'});
      expect(p.announcement!.level, 'warn');
      expect(p.announcement!.id, 'ann1');
      expect(p.aiEndpoint, 'https://ai.example.test');
      expect(p.contactsTitle, 'हमारे जानकार');
      expect(p.aiEnabled && p.analyticsEnabled, isTrue);
      expect(p.analyticsSample, 1);
      final byId = {for (final r in p.structure!.religions) r.id: r};
      expect(byId['kabir']!.icon, 'kabir', reason: "legacy 'ektara' draws as kabir");
      expect(byId['jain']!.icon, 'misc', reason: 'unknown icon → misc');
      expect(byId['christian']!.visible, isFalse);
      expect(byId['christian']!.groups.first.icon, 'misc', reason: 'unknown group icon → misc');
      expect(byId['sikh']!.comingSoon, 'सिख ग्रंथ जल्द जोड़े जाएँगे');
      expect(p.overrides['69'], 'buddh/tripitak');
    });

    test('contacts: visible only, sorted by order, bad entries dropped one by one, no phone ⇒ no WhatsApp', () {
      final c = parse('cfg_valid.json')!.contacts!;
      expect([for (final x in c) x.id], ['c1', 'c2', 'c5', 'c7']);
      expect(c[1].phone, '+919876543210');
      expect(c[1].whatsapp, isTrue);
      expect(c[2].whatsapp, isFalse, reason: 'whatsapp needs a number');
      expect(c.any((x) => x.id == 'c3'), isFalse, reason: 'visible:false');
      expect(c.any((x) => x.id == 'c4'), isFalse, reason: 'phone with spaces is invalid');
      expect(c.any((x) => x.id == 'c6'), isFalse, reason: 'name > 80');
    });

    test('a bad signature, a missing signature, an old app, a lower version and another schema are all ignored', () {
      for (final (name, cached, build, reason) in [
        ('cfg_bad_sig.json', 0, 1, 'bad signature'),
        ('cfg_no_sig.json', 0, 1, 'no signature'),
        ('cfg_old_app.json', 0, 1, 'min_app'),
        ('cfg_lower.json', 5, 1, 'older version'),
        ('cfg_schema2.json', 0, 1, 'schema'),
      ]) {
        String? why;
        expect(parse(name, cached: cached, build: build, why: (m) => why = m), isNull, reason: name);
        expect(why, reason, reason: name);
      }
      // the same old-app file is fine for an app new enough (build 2)
      expect(parse('cfg_old_app.json', build: 2), isNotNull);
    });

    test('garbage never throws', () {
      for (final t in ['', 'nope', '[]', '{}', '{"sig":1}', '{"sig":"AAAA"}', '\u0000', '{' * 5000]) {
        expect(() => parseConfig(t, publicKey: testKey), returnsNormally, reason: t);
        expect(parseConfig(t, publicKey: testKey), isNull);
      }
      expect(parseConfig('x' * 80000, publicKey: testKey), isNull);
    });

    test('flags off, an http (not https) ai endpoint is refused, missing contacts → null (bundled seed)', () {
      final off = parse('cfg_flags_off.json')!;
      expect(off.aiEnabled, isFalse);
      expect(off.analyticsEnabled, isFalse);
      expect(off.analyticsSample, 0.5);
      final w = parse('cfg_no_contacts_http_ai.json')!;
      expect(w.aiEndpoint, isNull);
      expect(w.contacts, isNull);
    });

    test('the real live config (v4) verifies with the embedded public key', () {
      final p = parseConfig(fx('live_config.json'));
      expect(p, isNotNull);
      expect(p!.version, 4);
      // …and a test-key config does NOT verify with the embedded key
      expect(parseConfig(fx('cfg_valid.json')), isNull);
    });

    test('the live config (v3, structure v2) verifies, applies, places every granth once; jain and kabir icons are set', () {
      final p = parseConfig(fx('live_config_v3.json'));
      expect(p, isNotNull, reason: 'signature, schema, structure');
      expect(p!.version, 3);
      final bundledIdx = ShelfIndex.build(Shelves.bundled, CatalogStore.I.granths);
      RemoteConfig.I.debugApply(p);
      final idx = Shelves.indexFor(CatalogStore.I.granths);
      final moved = {
        for (final e in idx.placements.entries)
          if (bundledIdx.placements[e.key]?.key != e.value.key) e.key: '${bundledIdx.placements[e.key]?.key} → ${e.value.key}',
      };
      // ignore: avoid_print
      print('live v3 vs bundled placements: $moved');
      expect(idx.placements.length, bundledIdx.placements.length, reason: 'every granth is still placed exactly once');
      expect(Shelves.structure.religion('jain')?.icon, 'jain');
      expect(Shelves.structure.religion('kabir')?.icon, 'kabir');
      expect(RemoteConfig.I.hidden, isEmpty);
      expect(RemoteConfig.I.aiEnabled && RemoteConfig.I.analyticsEnabled, isTrue);
    });

    test('icon keys', () {
      expect(religionIconKey('ektara'), 'kabir');
      expect(religionIconKey('kabir'), 'kabir');
      expect(religionIconKey('jain'), 'jain');
      expect(religionIconKey('whatever'), 'misc');
      expect(religionIconKey(null), 'misc');
      expect(groupIconKey('nope'), 'misc');
      expect(groupIconKey('scroll'), 'scroll');
    });

    test('the public key and the signing path agree with the contract', () {
      expect(kConfigPublicKey, 'kdPKX/LfjdbPxugpPnpeEejTZlXKzrcoOg88IK83Fb4=');
      expect(base64Decode(kConfigPublicKey).length, 32);
      expect(ed25519Verify(base64Decode(kConfigPublicKey), const [], Uint8List(64)), isFalse);
    });
  });

  group('refresh (mocked server)', () {
    test('200 → applied and cached; 304 → unchanged; the ETag is sent back', () async {
      final s = Server()..ok(fx('cfg_valid.json'), etag: '"e5"');
      final rc = make(s);
      expect(await rc.refresh(), isTrue);
      expect(rc.lastResult, 'updated');
      expect(rc.version, 5);
      expect(rc.hidden, {'7'});
      expect(rc.contacts.map((c) => c.id), ['c1', 'c2', 'c5', 'c7']);
      expect(rc.aiEndpoint, 'https://ai.example.test');
      expect(await Store.I.readText(RemoteConfig.fileName), fx('cfg_valid.json'));

      s.notModified();
      expect(await rc.refresh(), isFalse);
      expect(rc.lastResult, 'unchanged');
      expect(s.seen.last.headers['If-None-Match'], '"e5"');
      expect(s.seen.first.headers.containsKey('If-None-Match'), isFalse, reason: 'nothing cached yet');

      // a weak validator for the same tag counts as the same
      s.ok(fx('cfg_valid.json'), etag: 'W/"e5"');
      expect(await rc.refresh(), isFalse);
      expect(rc.lastResult, 'unchanged');
    });

    test('a hidden granth leaves the catalog (so lists, search and AI retrieval); an empty hidden set brings it back', () async {
      expect(CatalogStore.I.granths.any((g) => g.id == '7'), isTrue);
      final s = Server()..ok(fx('cfg_valid.json'));
      final rc = make(s);
      await rc.refresh();
      expect(CatalogStore.I.granths.any((g) => g.id == '7'), isFalse);
      s.ok(fx('cfg_flags_off.json'), etag: '"e6"');
      await rc.refresh();
      expect(rc.hidden, isEmpty);
      expect(CatalogStore.I.granths.any((g) => g.id == '7'), isTrue);
    });

    test('bad signature / old app / network down: nothing changes, nothing throws', () async {
      final s = Server()..ok(fx('cfg_valid.json'));
      final rc = make(s);
      await rc.refresh();
      for (final bad in ['cfg_bad_sig.json', 'cfg_old_app.json', 'cfg_schema2.json', 'cfg_lower.json']) {
        s.ok(fx(bad), etag: '"x-$bad"');
        expect(await rc.refresh(), isFalse, reason: bad);
        expect(rc.lastResult, startsWith('ignored'), reason: bad);
        expect(rc.version, 5);
        expect(rc.hidden, {'7'});
      }
      s.down();
      expect(await rc.refresh(), isFalse);
      expect(rc.lastResult, 'failed');
      expect(rc.version, 5);
      // a bad config is never cached over the good one
      final cached = await Store.I.readText(RemoteConfig.fileName);
      expect(cached, fx('cfg_valid.json'));
    });

    test('old app (build 1 < min_app 2) with nothing cached stays on the bundled structure', () async {
      final s = Server()..ok(fx('cfg_old_app.json'));
      final rc = make(s);
      expect(await rc.refresh(), isFalse);
      expect(rc.version, 0);
      expect(rc.hidden, isEmpty);
      expect(rc.contacts.map((c) => c.name), ['अमित दास', 'रामेश्वर दर', 'गौतम दास', 'अशोक दास']);
      expect(identical(Shelves.structure, Shelves.bundled), isTrue);
    });

    test('the cached config is used at the next start (re-verified), without any network', () async {
      final s = Server()..ok(fx('cfg_valid.json'));
      await make(s).refresh();
      Shelves.useRemote(null, const {});
      final rc2 = make(Server());
      await rc2.load();
      expect(rc2.version, 5);
      expect(rc2.hidden, {'7'});
      // a tampered cache is dropped
      await Store.I.writeText(RemoteConfig.fileName, fx('cfg_bad_sig.json'));
      final rc3 = make(Server());
      await rc3.load();
      expect(rc3.version, 0);
    });

    test('disabled (analytics/remote off in tests, or never configured) makes no request', () async {
      final s = Server();
      final rc = make(s)..enabled = false;
      expect(await rc.refresh(), isFalse);
      expect(s.seen, isEmpty);
    });

    test('announcement: shown once, dismissible', () async {
      final s = Server()..ok(fx('cfg_valid.json'));
      final rc = make(s);
      await rc.refresh();
      expect(rc.banner?.id, 'ann1');
      await rc.dismissBanner();
      expect(rc.banner, isNull);
    });
  });
}
