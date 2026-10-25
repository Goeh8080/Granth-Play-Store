import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/retriever.dart';
import 'package:granthprabandhan/models/models.dart';

/// The 823 real pramans of the API (Round 12 snapshot; only the fields retrieval reads).
List<Praman> realPramans() => [
  for (final e
      in jsonDecode(File('test/fixtures/pramans_823.json').readAsStringSync())
          as List)
    Praman((e as Map).cast<String, dynamic>()),
];

/// A realistic question and what makes a praman relevant to it. Relevance is a pattern over the
/// praman's own topic title / title / description, written by hand from the real data (not from the
/// retriever's output). Some patterns are broad on purpose (a topic with 100+ pramans).
const List<(String, String)> kQuestions = [
  ('श्राद्ध क्यों नहीं करना चाहिए?', 'श्राद्ध|पित(र|्र|ृ)'),
  ('मूर्ति पूजा से क्या लाभ है?', 'मूर्ति'),
  ('गीता ज्ञान दाता कौन है?', 'गीता ज्ञान ?दाता'),
  (
    'ब्रह्मा विष्णु शिव के माता पिता कौन हैं?',
    'ब्रह्मा.*(विष्णु|शिव|महेश)|दुर्गा.*(माता|पुत्र)',
  ),
  ('शराब पीने के बारे में कुरआन क्या कहता है?', 'शराब|मदिरा'),
  ('कबीर साहेब कौन थे?', 'कबीर (साहेब|साहिब|जी|परमेश्वर)'),
  ('परमात्मा साकार है या निराकार?', 'साकार|निराकार'),
  ('मांस खाना पाप है क्या?', 'मांस|माँस|बलि|गोश्त'),
  ('शिवलिंग क्या है?', 'शिवलिंग|जलहरी|लिंग'),
  ('sikandar lodhi ne gaay ka kya kiya', 'सिकंदर|गाय'),
  (
    'दयानन्द सरस्वती ने कृष्ण के बारे में क्या लिखा?',
    'दयानन्द.*कृष्ण|कृष्ण.*दयानन्द',
  ),
  ('भूत प्रेत बाधा का कारण', 'भूत|प्रेत'),
  (
    'पुनर्जन्म और जन्म मरण से मुक्ति कैसे मिलती है?',
    'जन्म.?मरण|पुनर्जन्म|मोक्ष|मुक्ति',
  ),
  ('सतलोक क्या है?', 'सतलोक|सत्यलोक'),
  ('रामायण में श्री राम के बारे में क्या लिखा है?', 'रामायण|श्री राम|रामचरित'),
  ('बाइबल में परमेश्वर का नाम क्या है?', 'बाइबल|यहोवा'),
  ('क्या अल्लाह जन्म लेता है?', 'अल्लाह'),
  ('नर्मदा जी का विवाह किससे हुआ?', 'नर्मदा'),
  ('द्वादश पंथ कौन से हैं?', 'पंथ'),
  ('व्रत उपवास रखना चाहिए या नहीं?', 'व्रत|उपवास|रोज'),
  ('तीर्थ यात्रा से क्या मिलता है?', 'तीर्थ|हज'),
  ('स्त्री का अपमान किसने किया?', 'स्त्री|नारी'),
  ('kabir parmeshwar kaun hai', 'कबीर'),
  ('संत रामपाल जी महाराज जेल में क्यों हैं?', 'रामपाल'),
  ('मानव शरीर में चक्र और कमल', 'चक्र|कमल'),
  ('महाभारत युद्ध के बारे में बताओ', 'महाभारत'),
  ('मीरा के गुरु कौन थे?', 'मीरा'),
];

/// Harder: the question does not use the words of the praman (paraphrase, other script, spelling).
const List<(String, String)> kParaphrases = [
  ('भगवान का कोई रूप या आकार होता है क्या?', 'साकार|निराकार|आकार|राजा के समान'),
  (
    'हमारे मरे हुए बाप दादा के नाम पर खाना खिलाना सही है?',
    'श्राद्ध|पित(र|्र|ृ)',
  ),
  ('जानवर काटकर देवी को चढ़ाना ठीक है?', 'बलि|मांस|माँस|पशु'),
  ('gita mein kaal ka zikr', 'काल|गीता'),
  (
    'कुर्बानी और मांस खाने पर इस्लाम क्या कहता है',
    'मांस|माँस|कुर्बानी|क़ुर्बानी|बलि',
  ),
  (
    'आवागमन का चक्कर कैसे खत्म हो',
    'जन्म.?मरण|पुनर्जन्म|मोक्ष|मुक्ति|चौरासी|आवागमन',
  ),
  ('ईश्वर ने सृष्टि कैसे बनाई?', 'सृष्टि|उत्पत्ति|रचना'),
  ('shivling ka matlab', 'शिवलिंग|जलहरी|लिंग'),
];

void main() {
  final pramans = realPramans();
  late RetrievalIndex ix;
  late Map<int, Praman> byId;
  setUpAll(() {
    ix = buildIndex(rawDocsOf(pramans));
    byId = {for (final p in pramans) int.parse(p.id): p};
  });

  String hay(Praman p) => '${p.topicTitle} ${p.title} ${p.description}';

  test(
    'the real catalog: 823 pramans, ~26% are only a picture and a title',
    () {
      expect(pramans.length, 823);
      final imageOnly = pramans
          .where((p) => p.description.trim().isEmpty)
          .length;
      expect(imageOnly / pramans.length, inInclusiveRange(0.2, 0.35));
      expect(ix.length, 823);
    },
  );

  test(
    'normalisation: spelling variants, long vowels, anusvara, plurals, Latin names',
    () {
      expect(aiTokens('पुराणों'), aiTokens('पुरान'));
      expect(devFold('गीता'), devFold('गिता'));
      expect(devFold('ज़िन्दगी'), devFold('जिन्दगी'));
      expect(aiTokens('क्या कर्म योग है'), ['करम', 'योग']);
      expect(aiTokens('कबीर साहेब कौन थे'), isNot(contains('कौन')));
      expect(aiTokens('geeta ka gyan'), contains('gita'));
    },
  );

  test(
    'synonyms / transliteration: Latin and Devanagari spellings find the same pramans',
    () {
      final a = searchIndex(ix, 'कबीर परमेश्वर').map((h) => h.id).toList();
      final b = searchIndex(ix, 'kabir parmeshwar').map((h) => h.id).toList();
      expect(
        a.toSet().intersection(b.toSet()).length,
        greaterThanOrEqualTo(6),
        reason: 'a=$a b=$b',
      );
      final g1 = searchIndex(ix, 'gita gyan data').map((h) => h.id).toSet();
      final g2 = searchIndex(ix, 'गीता ज्ञान दाता').map((h) => h.id).toSet();
      expect(g1.intersection(g2).length, greaterThanOrEqualTo(4));
    },
  );

  test('empty or stop-word-only questions find nothing and never throw', () {
    expect(searchIndex(ix, ''), isEmpty);
    expect(searchIndex(ix, 'क्या है'), isEmpty);
    expect(searchIndex(ix, '???'), isEmpty);
    expect(searchIndex(RetrievalIndex([], [], 1, {}, {}), 'कबीर'), isEmpty);
  });

  test('a one-word follow-up borrows the previous question', () {
    final alone = searchIndex(ix, 'और बताओ');
    expect(alone, isEmpty);
    final withCtx = searchIndex(
      ix,
      'और बताओ',
      context: 'श्राद्ध क्यों नहीं करना चाहिए?',
    );
    expect(withCtx, isNotEmpty);
    expect(hay(byId[withCtx.first.id]!), matches(RegExp('श्राद्ध|पित')));
  });

  test(
    'candidates are what the Worker accepts: ≤12, text ≤500, ids, granth',
    () {
      final hits = searchIndex(ix, 'शिवलिंग का रहस्य');
      expect(hits.length, 12);
      for (final h in hits) {
        final c = candidateOf(byId[h.id]!);
        expect(c.id, h.id);
        expect(c.text.length, lessThanOrEqualTo(500));
        expect(c.title.length, lessThanOrEqualTo(160));
        expect(c.text, isNotEmpty);
        expect(c.granth, isNotEmpty);
        expect(c.toJson().keys, {'id', 'title', 'text', 'granth'});
      }
    },
  );

  for (final (name, list, min5) in [
    ('realistic', kQuestions, 0.8),
    ('paraphrase / other-script', kParaphrases, 0.6),
  ]) {
    test(
      'hit rate over ${list.length} $name questions (relevant praman in the top 5 / top 12)',
      () {
        var top1 = 0, top5 = 0, top12 = 0;
        var prec = 0.0;
        final report = StringBuffer();
        for (final (q, pat) in list) {
          final re = RegExp(pat);
          final relevantTotal = pramans
              .where((p) => re.hasMatch(hay(p)))
              .length;
          final hits = searchIndex(ix, q);
          final rel = [for (final h in hits) re.hasMatch(hay(byId[h.id]!))];
          final h1 = rel.isNotEmpty && rel.first;
          final h5 = rel.take(5).any((e) => e);
          final h12 = rel.any((e) => e);
          if (h1) top1++;
          if (h5) top5++;
          if (h12) top12++;
          prec += rel.take(5).where((e) => e).length / 5;
          report.writeln(
            '${h5 ? 'HIT ' : 'MISS'} [${rel.take(5).where((e) => e).length}/5 in top5, $relevantTotal relevant in catalog] $q',
          );
        }
        final n = list.length;
        final summary =
            'top1 $top1/$n, top5 $top5/$n, top12 $top12/$n, mean precision@5 ${(prec / n).toStringAsFixed(2)}';
        // ignore: avoid_print
        print('\n$report$summary');
        File(
          '/tmp/ai_retrieval_${list == kQuestions ? 'realistic' : 'paraphrase'}.txt',
        ).writeAsStringSync('$report$summary\n');
        expect(top5, greaterThanOrEqualTo((n * min5).ceil()), reason: summary);
      },
    );
  }
}
