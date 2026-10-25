import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/retriever.dart';

import 'ai_retrieval_test.dart' show realPramans;

const _cand = Candidate(id: 5, title: 'अध्याय 18 श्लोक 62', text: 'गीता — शरण में जा', granth: 'श्रीमद्भगवद्गीता');

typedef Step = FutureOr<(int, String)> Function();

void main() {
  group('parseAskResponse', () {
    test('a good answer, with cited ids as numbers or numeric strings, de-duplicated', () {
      final a = parseAskResponse(200, jsonEncode({'answer': ' **नमस्ते** ', 'cited': [5, '7', 5, 'x', -1, 0, 9.0, null], 'provider': 'cloudflare'}));
      expect(a.answer, '**नमस्ते**');
      expect(a.cited, [5, 7, 9]);
      expect(a.provider, 'cloudflare');
    });
    test('missing cited / provider is fine', () {
      final a = parseAskResponse(200, '{"answer":"ठीक"}');
      expect(a.cited, isEmpty);
      expect(a.provider, '');
      expect(parseCited('nope'), isEmpty);
    });
    test('an empty or odd body with 200 is a bad reply', () {
      for (final b in ['', 'not json', '[]', '{"answer":""}', '{"answer":5}', '{"error":"x","answer":"y"}']) {
        expect(() => parseAskResponse(200, b), throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiFailure.badReply)), reason: b);
      }
    });
    test('error statuses map to the right failure and retryability', () {
      AiException of(int s) {
        try {
          parseAskResponse(s, '{"error":"e"}');
        } on AiException catch (e) {
          return e;
        }
        throw StateError('no throw');
      }

      expect(of(429).kind, AiFailure.rateLimited);
      expect(of(429).retryable, isTrue);
      expect(of(503).kind, AiFailure.unavailable);
      expect(of(500).retryable, isTrue);
      expect(of(400).kind, AiFailure.rejected);
      expect(of(400).retryable, isFalse);
      expect(of(403).retryable, isFalse);
      expect(of(413).kind, AiFailure.tooLarge);
      expect(of(413).retryable, isFalse);
      for (final s in [400, 403, 413, 429, 503]) {
        expect(of(s).message, matches(RegExp('[\u0900-\u097F]')), reason: 'Hindi message for $s');
      }
    });
  });

  group('buildAskBody', () {
    test('applies every limit of the contract', () {
      final long = 'क' * 900;
      final history = [for (var i = 0; i < 7; i++) AiTurn(i.isEven ? 'user' : 'assistant', '$i $long'), const AiTurn('system', 'x'), const AiTurn('user', '  ')];
      final cands = [for (var i = 1; i <= 20; i++) Candidate(id: i, title: 't', text: 'x', granth: 'g')];
      final b = buildAskBody('${'ख' * 800} ', history, cands);
      expect((b['question'] as String).runes.length, 500);
      final h = b['history'] as List;
      expect(h.length, 4);
      expect((h.first as Map)['text'].toString().runes.length, 600);
      expect((h.last as Map)['text'].toString().startsWith('6 '), isTrue);
      expect((b['candidates'] as List).length, 12);
      expect(jsonEncode(b).length, lessThan(64 * 1024));
      expect((h.first as Map).keys, {'role', 'text'});
    });
    test('real candidates stay far below the 64 KB the Worker accepts', () {
      final ps = realPramans().take(12).map(candidateOf).toList();
      expect(utf8.encode(jsonEncode(buildAskBody('प्रश्न', const [], ps))).length, lessThan(30 * 1024));
    });
  });

  group('AiClient against a local server', () {
    late HttpServer server;
    late List<Map<String, Object?>> seen;
    late List<Step> script;

    setUp(() async {
      seen = [];
      script = [];
      server = await HttpServer.bind('127.0.0.1', 0);
      server.listen((req) async {
        final body = await utf8.decoder.bind(req).join();
        seen.add({'path': req.uri.path, 'method': req.method, 'header': req.headers.value('x-granth-client'), 'body': body});
        final Step step = script.isEmpty ? (() => (200, '{"answer":"ok","cited":[5],"provider":"p"}')) : script.removeAt(0);
        final (s, t) = await step();
        req.response
          ..statusCode = s
          ..headers.contentType = ContentType.json
          ..add(utf8.encode(t));
        await req.response.close();
      });
    });
    tearDown(() => server.close(force: true));

    AiClient client({Duration timeout = const Duration(seconds: 5)}) =>
        AiClient(endpoint: 'http://127.0.0.1:${server.port}/', timeout: timeout, backoff: const Duration(milliseconds: 10));

    test('POST /ask with the client header and the JSON body', () async {
      final a = await client().ask('कर्म योग क्या है?', const [AiTurn('user', 'पहले')], [_cand]);
      expect(a.answer, 'ok');
      expect(a.cited, [5]);
      expect(seen.single['path'], '/ask');
      expect(seen.single['method'], 'POST');
      expect(seen.single['header'], 'granth-app-1');
      final body = jsonDecode(seen.single['body']! as String) as Map;
      expect(body['question'], 'कर्म योग क्या है?');
      expect((body['candidates'] as List).single['id'], 5);
    });

    test('retries once after a 503, then succeeds', () async {
      script = [() => (503, '{"error":"all providers failed"}')];
      final a = await client().ask('q', const [], [_cand]);
      expect(a.answer, 'ok');
      expect(seen.length, 2);
    });

    test('retries once after a 429 with a longer wait, then gives the Hindi message', () async {
      script = [() => (429, '{"error":"rate"}'), () => (429, '{"error":"rate"}')];
      await expectLater(client().ask('q', const [], [_cand]), throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiFailure.rateLimited)));
      expect(seen.length, 2);
    });

    test('does not retry a 400 / 403 / 413', () async {
      for (final s in [400, 403, 413]) {
        seen.clear();
        script = [() => (s, '{"error":"no"}')];
        await expectLater(client().ask('q', const [], [_cand]), throwsA(isA<AiException>().having((e) => e.status, 'status', s)));
        expect(seen.length, 1, reason: '$s');
      }
    });

    test('a slow server is a timeout (after one retry)', () async {
      script = [
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return (200, '{"answer":"late"}');
        },
        () async {
          await Future<void>.delayed(const Duration(milliseconds: 400));
          return (200, '{"answer":"late"}');
        },
      ];
      await expectLater(client(timeout: const Duration(milliseconds: 100)).ask('q', const [], [_cand]), throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiFailure.timeout)));
    });

    test('nothing listening is "offline"', () async {
      final port = server.port;
      await server.close(force: true);
      final c = AiClient(endpoint: 'http://127.0.0.1:$port', timeout: const Duration(seconds: 2), backoff: const Duration(milliseconds: 10));
      await expectLater(c.ask('q', const [], [_cand]), throwsA(isA<AiException>().having((e) => e.kind, 'kind', AiFailure.offline)));
    });
  });

  // The live check against the deployed Worker (only with AI_LIVE=1; it is a real network call).
  test('LIVE: real questions with real catalog candidates', skip: Platform.environment['AI_LIVE'] == null, timeout: const Timeout(Duration(seconds: 300)), () async {
    final ps = realPramans();
    final ix = buildIndex(rawDocsOf(ps));
    final byId = {for (final p in ps) int.parse(p.id): p};
    final out = StringBuffer();
    var anyCited = 0;
    for (final q in ['श्राद्ध क्यों नहीं करना चाहिए?', 'गीता ज्ञान दाता कौन है?', 'मूर्ति पूजा करना चाहिए या नहीं?']) {
      final cands = [for (final h in searchIndex(ix, q)) candidateOf(byId[h.id]!)];
      final sw = Stopwatch()..start();
      final a = await AiClient().ask(q, const [], cands);
      sw.stop();
      if (a.cited.isNotEmpty) anyCited++;
      out
        ..writeln('--- question: $q')
        ..writeln('candidates: ${cands.map((c) => c.id).toList()}')
        ..writeln('elapsed_ms: ${sw.elapsedMilliseconds}  provider: ${a.provider}')
        ..writeln('cited: ${a.cited}  (all in candidates: ${a.cited.every((c) => cands.any((x) => x.id == c))})')
        ..writeln('answer:\n${a.answer}\n');
    }
    File('/tmp/ai_live.txt').writeAsStringSync(out.toString());
    expect(anyCited, greaterThan(0));
  });
}
