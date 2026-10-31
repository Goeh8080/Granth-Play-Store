import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/config.dart';
import 'package:granthprabandhan/services/analytics.dart';
import 'package:granthprabandhan/services/remote_config.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/state/router.dart';

import 'helpers.dart';

/// Records every POST; answers with the next scripted status (default 204) or a network failure.
class Ingest implements HttpClientAdapter {
  final List<Map<String, dynamic>> bodies = [];
  final List<RequestOptions> opts = [];
  final List<int> script = []; // 0 = network failure
  @override
  Future<ResponseBody> fetch(RequestOptions options, Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    final raw = <int>[];
    await for (final c in requestStream ?? const Stream<Uint8List>.empty()) {
      raw.addAll(c);
    }
    final code = script.isEmpty ? 204 : script.removeAt(0);
    if (code == 0) throw DioException.connectionError(requestOptions: options, reason: 'offline');
    opts.add(options);
    bodies.add(jsonDecode(utf8.decode(gzip.decode(raw))) as Map<String, dynamic>);
    return ResponseBody.fromString('', code);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Ingest net;
  late RemoteConfig cfg;
  late DateTime clock;
  late Analytics an;

  Analytics make({bool enabled = true}) => Analytics(dio: Dio()..httpClientAdapter = net, now: () => clock, config: () => cfg, url: 'https://ev.test/events', enabled: enabled);

  setUp(() async {
    await setUpApp();
    net = Ingest();
    cfg = RemoteConfig(publicKey: const [])..enabled = false;
    clock = DateTime.utc(2026, 10, 25, 9);
    an = make();
  });

  Future<void> start() async {
    an.start();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  /// The router tells its listeners a moment later; let that happen before the clock moves on.
  Future<void> nav(String h) async {
    AppNav.I.openLink(h);
    await Future<void>.delayed(Duration.zero);
  }

  void tick(int s) => clock = clock.add(Duration(seconds: s));

  test('a batch has exactly the contract shape, goes out gzipped to the events URL, then the queue is empty', () async {
    await start();
    await nav('#/pramans?granth=44');
    tick(30);
    await nav('#/granths?r=hindu&g=puran');
    tick(20);
    an.syncResult(true);
    an.syncResult(false, 'Timeout!');
    an.pdfResult(false, 'nospace');
    an.aiAsked();
    an.aiAnswered();
    an.aiCiteTap();
    an.named('app_open');
    tick(5);
    await an.flush(force: true);

    expect(net.bodies, hasLength(1));
    final b = net.bodies.single;
    expect(net.opts.single.uri.toString(), 'https://ev.test/events');
    expect(net.opts.single.headers['Content-Encoding'], 'gzip');
    expect(b.keys.toSet(), {'v', 'batch_id', 'iid', 'app', 'app_version', 'build', 'os', 'sdk', 'cfg', 'day', 'fg_s', 'sessions', 'open', 'watch_s', 'sync', 'pdf', 'ai', 'events'});
    final ev = (b['events'] as List).cast<Map>();
    expect(ev.every((e) => {'folder_open', 'granth_open', 'ai_answer', 'ai_fail', 'pdf_download', 'app_open'}.contains(e['name'])), isTrue);
    expect(ev.where((e) => e['name'] == 'app_open').single['n'], 1);
    expect(b['v'], 1);
    expect(b['batch_id'], matches(RegExp(r'^[0-9A-Za-z_-]{8,64}$')));
    expect(b['iid'], matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(b['app'], '1.0.0+1');
    expect(b['app_version'], '1.0.0');
    expect(b['app_version'], matches(RegExp(r'^[0-9A-Za-z.+_-]{1,24}$')));
    expect(b['build'], 1);
    expect(b['app'], matches(RegExp(r'^[0-9A-Za-z.+_-]{1,24}$')));
    expect(b['os'], 'android');
    expect(b['sdk'], inInclusiveRange(0, 99));
    expect(b['cfg'], isA<int>());
    expect(b['day'], '2026-10-25');
    expect(b['sessions'], 1);
    expect(b['fg_s'], 55);
    expect((b['open'] as Map)['g'], {'44': 1});
    expect((b['open'] as Map)['f'], {'hindu/puran': 1});
    expect((b['open'] as Map).keys.toSet(), {'g', 'f', 't', 'p'});
    final w = b['watch_s'] as Map;
    expect((w['g'] as Map)['44'], 30);
    expect((w['f'] as Map)['hindu/puran'], 25);
    expect((w['scr'] as Map).keys.every((k) => RegExp(r'^[a-z0-9_-]{1,24}$').hasMatch(k)), isTrue);
    expect(b['sync'], {'ok': 1, 'fail': 1, 'kinds': {'timeout_': 1}});
    expect(b['pdf'], {'ok': 0, 'fail': 1, 'kinds': {'nospace': 1}});
    expect(b['ai'], {'asked': 1, 'answered': 1, 'cite_tap': 1});
    expect(utf8.encode(jsonEncode(b)).length, lessThan(8192));
    expect(an.debugQueue, isEmpty);
    expect(jsonDecode(await Store.I.readText(Analytics.queueFile) ?? '[]'), isEmpty);
  });

  test('nothing personal can appear: only the contract keys, no free text, a stable random iid', () async {
    await start();
    an.aiAsked();
    tick(10);
    await an.flush(force: true);
    final text = jsonEncode(net.bodies.single);
    expect(text.contains('http'), isFalse);
    final iid1 = net.bodies.single['iid'];
    expect(Store.I.getString(Analytics.kIid), iid1);
    // a new object in the same install reuses it
    expect(make().iid, iid1);
    // …and a bad stored value is replaced by a fresh random one
    await Store.I.setString(Analytics.kIid, 'not-hex');
    final fresh = make().iid;
    expect(fresh, matches(RegExp(r'^[0-9a-f]{32}$')));
    expect(fresh, isNot(iid1));
  });

  test('analytics_enabled=false or the build switch off: nothing is counted or sent', () async {
    cfg.analyticsEnabled = false;
    await start();
    an.aiAsked();
    an.syncResult(true);
    tick(60);
    await an.flush(force: true);
    expect(net.bodies, isEmpty);
    expect(an.debugQueue, isEmpty);

    cfg.analyticsEnabled = true;
    final off = make(enabled: false);
    off.aiAsked();
    await off.flush(force: true);
    expect(net.bodies, isEmpty);
  });

  test('analytics_sample: 0 never sends, 1 always, and the choice is stable per install', () async {
    cfg.analyticsSample = 0;
    expect(an.enabled, isFalse);
    cfg.analyticsSample = 1;
    expect(an.enabled, isTrue);
    cfg.analyticsSample = 0.5;
    final first = an.sampled;
    for (var i = 0; i < 5; i++) {
      expect(an.sampled, first);
    }
    // across many installs about the sampled fraction is in
    var in_ = 0;
    for (var i = 0; i < 400; i++) {
      await Store.I.remove(Analytics.kIid);
      if (make().sampled) in_++;
    }
    expect(in_, inInclusiveRange(140, 260));
  });

  test('offline: the batch stays queued with the SAME batch_id and is sent on the next try; 429/5xx also retry; 4xx never', () async {
    await start();
    an.aiAsked();
    tick(10);
    net.script.addAll([0]);
    await an.flush(force: true);
    expect(net.bodies, isEmpty);
    expect(an.debugQueue, hasLength(1));
    final id = an.debugQueue.single['batch_id'];
    expect(jsonDecode(await Store.I.readText(Analytics.queueFile) ?? '[]'), hasLength(1), reason: 'survives a restart');

    net.script.add(503);
    await an.flush();
    expect(an.debugQueue, hasLength(1));
    net.script.add(429);
    await an.flush();
    expect(an.debugQueue, hasLength(1));
    await an.flush();
    expect(net.bodies.last['batch_id'], id);
    expect(an.debugQueue, isEmpty);

    // a content refusal (400) is not retried
    an.aiAsked();
    tick(5);
    net.script.add(400);
    await an.flush(force: true);
    expect(an.debugQueue, isEmpty);
  });

  test('a queue saved by an earlier run is uploaded after a restart', () async {
    await start();
    an.aiAsked();
    tick(10);
    net.script.add(0);
    await an.flush(force: true);
    final id = an.debugQueue.single['batch_id'];
    final an2 = make();
    await an2.flush();
    expect(net.bodies.single['batch_id'], id);
  });

  test('at most 5 batches are made per UTC day (the server takes 6); counts keep accumulating for the next one', () async {
    await start();
    for (var i = 0; i < 8; i++) {
      an.aiAsked();
      tick(5);
      await an.flush(force: true);
    }
    expect(net.bodies, hasLength(Analytics.maxBatchesPerDay));
    // next UTC day: allowed again, and it carries what was held back
    clock = DateTime.utc(2026, 10, 26, 9);
    tick(5);
    await an.flush(force: true);
    // the held-back counts leave as a batch of their own day, then the new day's batch
    expect(net.bodies, hasLength(Analytics.maxBatchesPerDay + 2));
    expect(net.bodies[5]['day'], '2026-10-25');
    expect((net.bodies[5]['ai'] as Map)['asked'], 3);
    expect(net.bodies.last['day'], '2026-10-26');
  });

  test('the offline queue is capped, and batches older than 2 days are dropped instead of sent', () async {
    await start();
    an.aiAsked();
    tick(5);
    net.script.add(0);
    await an.flush(force: true);
    expect(an.debugQueue, hasLength(1));
    an.didChangeAppLifecycleState(AppLifecycleState.paused); // (app in the background meanwhile)
    net.script.add(0);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    clock = clock.add(const Duration(days: 4));
    await an.flush();
    expect(net.bodies, isEmpty, reason: 'too old for the server window');
    expect(an.debugQueue, isEmpty);
  });

  test('time only counts in the foreground: nothing is added while the app is paused', () async {
    await start();
    tick(10);
    an.didChangeAppLifecycleState(AppLifecycleState.paused); // closes the segment and flushes
    await Future<void>.delayed(const Duration(milliseconds: 20));
    tick(3600); // an hour in the background
    an.didChangeAppLifecycleState(AppLifecycleState.resumed);
    tick(7);
    await an.flush(force: true);
    final fg = net.bodies.fold<int>(0, (a, b) => a + (b['fg_s'] as int));
    expect(fg, 17);
    expect(net.bodies.fold<int>(0, (a, b) => a + (b['sessions'] as int)), 2);
  });

  test('a day change starts a new batch for the old day', () async {
    await start();
    an.aiAsked();
    clock = DateTime.utc(2026, 10, 25, 23, 59, 50);
    tick(20); // now 26th, 00:00:10
    an.aiAsked();
    await an.flush(force: true);
    final days = net.bodies.map((b) => b['day']).toList();
    expect(days, ['2026-10-25', '2026-10-26']);
  });

  test('error kinds are short fixed words, never message text', () {
    expect(Analytics.kindOf(DioException.connectionError(requestOptions: RequestOptions(), reason: 'x')), 'network');
    expect(Analytics.kindOf(DioException.connectionTimeout(requestOptions: RequestOptions(), timeout: const Duration(seconds: 1))), 'timeout');
    expect(Analytics.kindOf(const FormatException('secret text')), 'parse');
    expect(Analytics.kindOf(Exception('No space left on device')), 'nospace');
    expect(Analytics.kindOf(Exception('weird')), 'other');
  });

  test('screen names are valid contract names', () {
    for (final h in ['#/', '#/topics', '#/granths?all=1', '#/granths', '#/granths?r=hindu&g=ved', '#/pramans?granth=1', '#/gallery', '#/ai', '#/legal?p=privacy', '#/legal?p=contacts']) {
      expect(Analytics.screenName(GRoute.parse(h)), matches(RegExp(r'^[a-z0-9_-]{1,24}$')), reason: h);
    }
  });

  group('app key (X-App-Key)', () {
    Analytics withKey(String? key) => Analytics(dio: Dio()..httpClientAdapter = net, now: () => clock, config: () => cfg, url: 'https://ev.test/events', enabled: true, appKey: key);

    Future<void> oneBatch(Analytics a) async {
      a.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await nav('#/pramans?granth=44');
      tick(30);
      await a.flush(force: true);
    }

    test('with a key configured, every POST carries it as the X-App-Key header (and it is not in the body)', () async {
      final a = withKey('test-key');
      await oneBatch(a);
      expect(net.opts, hasLength(1));
      expect(net.opts.single.headers['X-App-Key'], 'test-key');
      expect(net.opts.single.headers['Content-Encoding'], 'gzip');
      expect(jsonEncode(net.bodies.single).contains('test-key'), isFalse);
      expect(jsonEncode(await Store.I.readText(Analytics.queueFile) ?? '').contains('test-key'), isFalse);
      // a second POST (retry path) also carries it
      a.debugReset();
      net.script.addAll([0, 204]);
      a.aiAsked();
      await a.flush(force: true);
      await a.flush();
      for (final o in net.opts) {
        expect(o.headers['X-App-Key'], 'test-key');
      }
    });

    test('with an empty key (CI / tests) the header is omitted and the batch still goes out', () async {
      for (final k in [null, '', '   ']) {
        net = Ingest();
        await oneBatch(withKey(k));
        expect(net.opts, hasLength(1), reason: 'key=$k');
        expect(net.opts.single.headers.containsKey('X-App-Key'), isFalse, reason: 'key=$k');
        await setUpApp();
        clock = DateTime.utc(2026, 10, 25, 9);
      }
    });

    test('the default key is the compile-time APP_KEY (empty under flutter test), so the header is omitted', () async {
      expect(Analytics(enabled: true).appKey, kAppKey);
      expect(kAppKey, isA<String>());
    });

    test('failures with a key configured never throw and keep the batch: network error, 5xx, 4xx', () async {
      final a = withKey('test-key');
      net.script.addAll([0, 500, 403]);
      a.start();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await nav('#/pramans?granth=44');
      tick(30);
      await expectLater(a.flush(force: true), completes); // offline
      expect(a.debugQueue, hasLength(1));
      await expectLater(a.flush(), completes); // 500: retry later
      expect(a.debugQueue, hasLength(1));
      await expectLater(a.flush(), completes); // 403: dropped, never resent
      expect(a.debugQueue, isEmpty);
      expect(net.opts.every((o) => o.headers['X-App-Key'] == 'test-key'), isTrue);
    });
  });
}
