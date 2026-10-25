import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import '../services/search.dart' show foldLatin, normalizeText, skeleton, stopWords, synonymClusters, transliterate;

/// On-device retrieval for "तत्त्व AI से पूछे": BM25 over the cached catalog (823 pramans). The
/// best candidates go to the AI Worker with the question; nothing leaves the phone before the user
/// presses send, and nothing but the question and ≤12 short excerpts is sent.
///
///  * Fields (weights): topic title ×3, description ×2, praman title ×1.5, granth title ×1, author ×.3.
///    26% of the pramans are only a picture with a title: they are found by title / topic / granth.
///  * Devanagari normalisation: nukta, chandrabindu, anusvara, halant dropped; long vowels folded
///    (ी→ि ू→ु), ण→न श/ष→स; light suffix stripping (-ों -ें -ता -ना …); consonant 3-grams as a weak
///    second signal (spelling variants, joined words).
///  * Synonyms / transliteration: the search.dart clusters + the AI-specific clusters below; Latin
///    words ("geeta", "kabir") are matched through the transliteration skeleton of the vocabulary.
///  * The index is plain lists/maps, built once per catalog version in an isolate ([compute]).

// ------------------------------------------------------------------ normalisation

final RegExp _drop = RegExp('[\u093c\u0901\u0902\u094d\u200c\u200d]');
final RegExp _devanagari = RegExp('[\u0900-\u097f]');
final RegExp _latinWord = RegExp(r'^[a-z0-9]+$');

/// Folds spelling variants of one Devanagari word to one form (NFC text in, lowercase).
String devFold(String w) {
  var s = w.replaceAll(_drop, '');
  s = s
      .replaceAll('ी', 'ि')
      .replaceAll('ू', 'ु')
      .replaceAll('ई', 'इ')
      .replaceAll('ऊ', 'उ')
      .replaceAll('ॉ', 'ा')
      .replaceAll('ऑ', 'आ')
      .replaceAll('ृ', 'रि')
      .replaceAll('ऋ', 'रि')
      .replaceAll('ण', 'न')
      .replaceAll('ष', 'स')
      .replaceAll('श', 'स');
  return s;
}

// Longest first. A stem must keep at least 2 characters.
const List<String> _suffixes = [
  'ताओ', 'वाला', 'वाले', 'वाली', 'ाता', 'ाती', 'ाते', 'िया', 'ियो', 'ाओ', 'ाए', 'ता', 'ती', 'ते', 'ना', 'ने', 'ो', 'े',
];

String devStem(String folded) {
  if (folded.length < 4) return folded;
  for (final s in _suffixes) {
    if (folded.length - s.length >= 2 && folded.endsWith(s)) return folded.substring(0, folded.length - s.length);
  }
  return folded;
}

/// Hindi question words and function words that carry no topic.
final Set<String> aiStopWords = {
  'क्या', 'कैसे', 'क्यों', 'क्यूँ', 'कौन', 'किस', 'किसे', 'किसने', 'किसका', 'किसकी', 'किसके', 'कहाँ', 'कहां', 'कब', 'कितना', 'कितने', 'कितनी',
  'कोई', 'कुछ', 'बताओ', 'बताइए', 'बताएं', 'बताएँ', 'बतायें', 'बारे', 'बात', 'मैं', 'मुझे', 'हम', 'हमें', 'आप', 'तुम', 'हैं', 'हूँ', 'था', 'थे', 'थी',
  'थीं', 'होता', 'होती', 'होते', 'होना', 'जो', 'जिस', 'जिसे', 'इस', 'उस', 'इन', 'उन', 'तो', 'ही', 'नहीं', 'नही', 'अनुसार', 'द्वारा', 'लिए',
  'लिये', 'साथ', 'वाले', 'वाला', 'वाली', 'कर', 'करना', 'करते', 'करता', 'करती', 'करें', 'करे', 'कहते', 'कहा', 'कहती', 'कहता', 'ये', 'वे', 'वो',
  'अपने', 'अपना', 'अपनी', 'सकता', 'सकते', 'सकती', 'चाहिए', 'चाहिये', 'तक', 'ऐसा', 'ऐसे', 'कैसा', 'जी', 'ग्रंथ', 'ग्रन्थ', 'ग्रंथों', 'प्रमाण', 'प्रमाणों',
  'में', 'मे', 'पर', 'से', 'को', 'का', 'की', 'के', 'है', 'हो', 'और', 'या', 'एक', 'भी', 'यह', 'वह', 'ने', 'कि', 'हुआ', 'हुई', 'हुए', 'गया', 'गई', 'गये',
  'what', 'is', 'are', 'the', 'of', 'in', 'to', 'a', 'an', 'how', 'why', 'who', 'where', 'when', 'does', 'do', 'about', 'tell', 'me', 'ke', 'ka', 'ki', 'mein',
  'kya', 'hai', 'hain', 'ko', 'se', 'par', 'aur', 'ya', 'kaise', 'kyon', 'kaun', 'batao', 'bataiye',
};

/// Extra synonym / spelling clusters (on top of search.dart's), for the questions people ask of
/// this catalog. Members are matched after folding, so matras / spelling variants need not be listed.
const List<List<String>> aiClusters = [
  ['परमात्मा', 'परमेश्वर', 'ईश्वर', 'भगवान', 'प्रभु', 'खुदा', 'अल्लाह', 'god', 'allah', 'parmatma', 'parmeshwar', 'ishwar', 'khuda', 'ईलाह', 'यहोवा'],
  ['कबीर', 'कविर्देव', 'कविर', 'कबीर साहेब', 'कबीर साहब', 'kabir', 'kabeer'],
  ['सतलोक', 'सत्यलोक', 'सतलोक', 'satlok', 'satyalok', 'सनातन परमधाम'],
  ['श्राद्ध', 'पितर', 'पित्र', 'पितृ', 'पूर्वज', 'पुरखे', 'बापदादा', 'दादा', 'बाप', 'मृतक', 'shraddh', 'shradh', 'pitar', 'pitra'],
  ['मूर्ति', 'मूर्ती', 'मूर्तिपूजा', 'murti', 'idol'],
  ['गीता', 'गीताजी', 'gita', 'geeta', 'bhagavadgita', 'भगवद्गीता', 'गीताज्ञान', 'गीता ज्ञान दाता'],
  ['काल', 'ब्रह्म', 'क्षर', 'kaal', 'kal'],
  ['अवतार', 'avatar', 'autar'],
  ['साकार', 'निराकार', 'आकार', 'रूप', 'सूरत', 'शरीर', 'sakar', 'nirakar'],
  ['शिवलिंग', 'लिंग', 'जलहरी', 'shivling', 'shivlinga', 'lingam', 'ling'],
  ['चढ़ावा', 'चढ़ाना', 'भेंट', 'अर्पण', 'नैवेद्य', 'भोग', 'प्रसाद'],
  ['तीन गुण', 'रजगुण', 'सतगुण', 'तमगुण', 'त्रिगुण'],
  ['माया', 'दुर्गा', 'अष्टांगी', 'प्रकृति', 'maya'],
  ['पाप', 'पापी', 'दोष'],
  ['नरक', 'narak', 'हेल', 'जहन्नम', 'दोजख'],
  ['स्वर्ग', 'जन्नत', 'swarg', 'jannat', 'heaven'],
  ['शराब', 'मदिरा', 'सुरा', 'दारू', 'नशा', 'sharab', 'alcohol', 'wine', 'तम्बाकू', 'तंबाकू'],
  ['मांस', 'माँस', 'गोश्त', 'शिकार', 'बलि', 'हिंसा', 'meat', 'mans', 'kurbani', 'क़ुर्बानी', 'कुर्बानी', 'जानवर', 'पशु', 'कुर्बान', 'हलाल', 'झटका', 'ज़बह', 'zabah'],
  ['गाय', 'गौ', 'गऊ', 'cow', 'gaay'],
  ['विवाह', 'शादी', 'ब्याह', 'vivah', 'shadi', 'marriage'],
  ['स्त्री', 'नारी', 'औरत', 'महिला', 'पत्नी', 'stri', 'nari'],
  ['पुनर्जन्म', 'जन्ममरण', 'जन्म मरण', 'आवागमन', 'चौरासी', 'punarjanm'],
  ['दयानन्द', 'दयानंद', 'सत्यार्थ', 'आर्यसमाज', 'dayanand', 'satyarth'],
  ['रामपाल', 'rampal', 'संत रामपाल'],
  ['सृष्टि', 'उत्पत्ति', 'रचना', 'srishti', 'creation'],
  ['मुहम्मद', 'मोहम्मद', 'पैगंबर', 'पैगम्बर', 'रसूल', 'muhammad', 'mohammad', 'mohammed'],
  ['कुरआन', 'क़ुरान', 'कुरान', 'क़ुरआन', 'quran', 'koran', 'kuran', 'qur\'an'],
  ['बाइबल', 'बाईबल', 'bible', 'बाइबिल', 'यीशु', 'ईसा', 'jesus', 'isa', 'masih', 'मसीह'],
  ['गुरु ग्रंथ साहिब', 'ग्रंथ साहिब', 'नानक', 'गुरु नानक', 'nanak', 'sikh', 'सिख'],
  ['वेद', 'ऋग्वेद', 'यजुर्वेद', 'सामवेद', 'अथर्ववेद', 'veda'],
  ['पूजा', 'साधना', 'उपासना', 'भक्ति', 'puja', 'sadhna', 'pooja'],
  ['योग', 'योगी', 'yoga', 'yog'],
  ['चक्र', 'कमल', 'chakra', 'kamal'],
  ['भूत', 'प्रेत', 'bhoot', 'pret', 'ghost'],
  ['व्रत', 'उपवास', 'वरत', 'vrat', 'fasting', 'roza', 'रोज़ा', 'रोजा'],
  ['तीर्थ', 'हज', 'कुंभ', 'गंगा', 'तीर्थयात्रा', 'tirth', 'haj'],
  ['बुद्ध', 'बौद्ध', 'गौतम बुद्ध', 'buddha', 'buddh', 'बुध'],
  ['जैन', 'महावीर', 'जिन', 'jain', 'mahavir'],
];

class _ClusterMap {
  _ClusterMap._(this.byToken, this.clusters);
  final Map<String, List<int>> byToken;
  final List<List<String>> clusters; // normalised member stems

  static _ClusterMap? _i;
  static _ClusterMap get I => _i ??= _build();

  static String stemOf(String raw) {
    final w = normalizeText(raw);
    if (_devanagari.hasMatch(w)) return devStem(devFold(w.replaceAll(' ', '')));
    return foldLatin(w.replaceAll(' ', ''));
  }

  static _ClusterMap _build() {
    final all = <List<String>>[...synonymClusters, ...aiClusters];
    final by = <String, List<int>>{};
    final cl = <List<String>>[];
    for (final c in all) {
      final i = cl.length;
      cl.add([for (final m in c) stemOf(m)]);
      for (final m in cl.last) {
        if (m.length < 2) continue;
        (by[m] ??= []).add(i);
      }
    }
    return _ClusterMap._(by, cl);
  }
}

/// Words of [text] as normalised stems (stop words removed).
List<String> aiTokens(String text) {
  final out = <String>[];
  for (final w in normalizeText(text).split(' ')) {
    if (w.isEmpty || aiStopWords.contains(w) || stopWords.contains(w)) continue;
    if (_devanagari.hasMatch(w)) {
      final f = devFold(w);
      if (f.length < 2) continue;
      out.add(devStem(f));
    } else {
      final l = foldLatin(w);
      if (l.length < 2 || aiStopWords.contains(w)) continue;
      out.add(l);
    }
  }
  return out;
}

List<String> _grams(String stem) {
  if (stem.length < 4 || !_devanagari.hasMatch(stem)) return const [];
  return [for (var i = 0; i + 3 <= stem.length; i++) stem.substring(i, i + 3)];
}

// ------------------------------------------------------------------ index

/// What the isolate builds. Only lists, maps, numbers and strings: it is sent back as it is.
class RetrievalIndex {
  RetrievalIndex(this.ids, this.dl, this.avgdl, this.postings, this.roman);
  final List<int> ids; // praman id per document
  final List<double> dl;
  final double avgdl;

  /// term → [doc, tf, doc, tf …]
  final Map<String, List<double>> postings;

  /// transliteration skeleton → Devanagari stems of the vocabulary
  final Map<String, List<String>> roman;
  int get length => ids.length;
}

/// One document = the fields of one praman: [id, topicTitle, description, title, granthTitle, author].
typedef RawDoc = List<String>;

const List<double> _fieldWeights = [3, 2, 1.5, 1, 0.3];
const double _gramWeight = 0.2;

RetrievalIndex buildIndex(List<RawDoc> docs) {
  final post = <String, List<double>>{};
  final ids = <int>[];
  final dl = <double>[];
  final vocab = <String>{};
  for (var d = 0; d < docs.length; d++) {
    final f = docs[d];
    ids.add(int.tryParse(f[0]) ?? -1);
    final tf = <String, double>{};
    var len = 0.0;
    for (var k = 0; k < _fieldWeights.length; k++) {
      final w = _fieldWeights[k];
      for (final t in aiTokens(f[k + 1])) {
        tf[t] = (tf[t] ?? 0) + w;
        len += w;
        if (_devanagari.hasMatch(t)) vocab.add(t);
        for (final g in _grams(t)) {
          tf['#$g'] = (tf['#$g'] ?? 0) + w * _gramWeight;
        }
      }
    }
    dl.add(len);
    tf.forEach((t, v) => (post[t] ??= <double>[]).addAll([d.toDouble(), v]));
  }
  final avg = dl.isEmpty ? 1.0 : math.max(1.0, dl.reduce((a, b) => a + b) / dl.length);
  final roman = <String, List<String>>{};
  for (final v in vocab) {
    final key = skeleton(foldLatin(transliterate(v)));
    if (key.length >= 2) (roman[key] ??= []).add(v);
  }
  return RetrievalIndex(ids, dl, avg, post, roman);
}

/// Called in an isolate.
RetrievalIndex buildIndexFromMaps(List<RawDoc> docs) => buildIndex(docs);

class Hit {
  const Hit(this.id, this.score);
  final int id;
  final double score;
  @override
  String toString() => '$id:${score.toStringAsFixed(2)}';
}

const double _k1 = 1.2, _b = 0.75;

/// Weighted query terms (term → weight) for [question]; [context] (the previous question) adds weak terms.
Map<String, double> queryTerms(RetrievalIndex ix, String question, {String? context}) {
  final q = <String, double>{};
  void add(String t, double w) {
    if ((q[t] ?? 0) < w) q[t] = w;
  }

  void feed(String text, double scale) {
    final cm = _ClusterMap.I;
    final raw = normalizeText(text);
    final words = raw.split(' ').where((w) => w.isNotEmpty).toList();
    final toks = aiTokens(text);
    for (final t in toks) {
      add(t, 1.0 * scale);
      for (final g in _grams(t)) {
        add('#$g', 0.3 * scale);
      }
      final cs = cm.byToken[t];
      if (cs != null) {
        for (final c in cs) {
          for (final m in cm.clusters[c]) {
            if (m.length >= 2 && m != t) add(m, 0.7 * scale);
          }
        }
      }
      if (_latinWord.hasMatch(t) && t.length >= 3) {
        final key = skeleton(t);
        final hit = ix.roman[key];
        if (hit != null && hit.length <= 12) {
          for (final s in hit) {
            add(s, 0.6 * scale);
          }
        }
      }
    }
    // Multi-word cluster members ("कबीर साहेब", "गुरु नानक"): the whole phrase in the question.
    final joined = _ClusterMap.stemOf(words.join(' '));
    if (joined.length >= 4) {
      final cs = cm.byToken[joined];
      if (cs != null) {
        for (final c in cs) {
          for (final m in cm.clusters[c]) {
            add(m, 0.8 * scale);
          }
        }
      }
    }
  }

  feed(question, 1.0);
  if (context != null && context.trim().isNotEmpty && q.length < 6) feed(context, 0.5);
  return q;
}

/// Top [k] pramans for [question] by BM25.
List<Hit> searchIndex(RetrievalIndex ix, String question, {int k = 12, String? context}) {
  if (ix.length == 0) return const [];
  final q = queryTerms(ix, question, context: context);
  if (q.isEmpty) return const [];
  final n = ix.length;
  final score = <int, double>{};
  q.forEach((term, qw) {
    final p = ix.postings[term];
    if (p == null) return;
    final df = p.length ~/ 2;
    final idf = math.log(1 + (n - df + 0.5) / (df + 0.5));
    for (var i = 0; i < p.length; i += 2) {
      final d = p[i].toInt();
      final tf = p[i + 1];
      final norm = tf * (_k1 + 1) / (tf + _k1 * (1 - _b + _b * ix.dl[d] / ix.avgdl));
      score[d] = (score[d] ?? 0) + qw * idf * norm;
    }
  });
  final top = score.entries.toList()
    ..sort((a, b) {
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  return [for (final e in top.take(k)) Hit(ix.ids[e.key], e.value)];
}

// ------------------------------------------------------------------ the retriever the app uses

/// The excerpt the Worker gets for a praman.
class Candidate {
  const Candidate({required this.id, required this.title, required this.text, required this.granth});
  final int id;
  final String title;
  final String text;
  final String granth;

  Map<String, Object> toJson() => {'id': id, 'title': title, 'text': text, 'granth': granth};
}

String _clip(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max - 1).trimRight()}…';
}

Candidate candidateOf(Praman p) {
  // The topic title is the claim the praman proves; the description explains it; for a picture-only
  // praman that is all there is.
  final text = [p.topicTitle, p.description].where((e) => e.trim().isNotEmpty).join(' — ');
  return Candidate(
    id: int.tryParse(p.id) ?? -1,
    title: _clip(p.title, 160),
    text: _clip(text.isEmpty ? p.title : text, 500),
    granth: _clip(p.granthTitle, 120),
  );
}

List<RawDoc> rawDocsOf(List<Praman> pramans) => [
      for (final p in pramans) [p.id, p.topicTitle, p.description, p.title, p.granthTitle, p.granthAuthor],
    ];

class Retriever {
  Retriever._();
  static final Retriever I = Retriever._();

  RetrievalIndex? _ix;
  int _version = -1;
  Future<RetrievalIndex>? _building;
  final Map<int, Praman> _byId = {};

  Praman? praman(int id) => _byId[id];

  /// Forgets the index (tests; also used when the visible set of granths changes).
  void reset() {
    _ix = null;
    _building = null;
    _version = -1;
  }

  /// Builds (or reuses) the index for [version] of [pramans]. The heavy part runs in an isolate.
  Future<RetrievalIndex> ensure(List<Praman> pramans, int version) {
    if (_ix != null && _version == version) return Future.value(_ix!);
    if (_building != null && _version == version) return _building!;
    _version = version;
    _byId
      ..clear()
      ..addEntries([for (final p in pramans) MapEntry(int.tryParse(p.id) ?? -1, p)]);
    final docs = rawDocsOf(pramans);
    final f = compute(buildIndexFromMaps, docs).then((ix) {
      if (_version == version) _ix = ix;
      return ix;
    });
    _building = f;
    f.whenComplete(() {
      if (identical(_building, f)) _building = null;
    });
    return f;
  }

  /// Up to [k] candidates for [question] ([history] only adds context for very short follow-ups).
  Future<List<Candidate>> candidates(List<Praman> pramans, int version, String question, {String? context, int k = 12}) async {
    final ix = await ensure(pramans, version);
    final hits = searchIndex(ix, question, k: k, context: context);
    return [
      for (final h in hits)
        if (_byId[h.id] != null) candidateOf(_byId[h.id]!),
    ];
  }
}
