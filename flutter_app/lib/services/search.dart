import 'package:unorm_dart/unorm_dart.dart' as unorm;

/// Offline Hindi/Latin fuzzy search — a line-by-line port of the web app's
/// `En/Dn/On/kn/jn/Mn/Nn/Pn/Fn/In/Ln/Rn` functions (see ARCHITECTURE.md "Offline search").

final RegExp _matra = RegExp('[\u093e\u093f\u0940\u0941\u0942\u0943\u0944\u0947\u0948\u094b\u094c\u0902\u0901\u094d\u093c\u200c\u200d]');
final RegExp _punct = RegExp(r'[^\p{L}\p{M}\p{N}\s]', unicode: true);
final RegExp _ws = RegExp(r'\s+');
final RegExp _alnum = RegExp(r'[a-z0-9]');
final RegExp _skel = RegExp(r'[aeiou\s]');

const List<List<String>> synonymClusters = [
  ['मांस', 'माँस', 'mans', 'maans', 'maas', 'meat'],
  ['मृत्यु', 'मरण', 'मौत', 'mrityu', 'mrutyu', 'maran', 'maut', 'death'],
  ['ब्रह्मा', 'ब्रह्म', 'brahma', 'brahm', 'bramha', 'brahmaa'],
  ['कृष्ण', 'krishna', 'krishan', 'kishan', 'krishn'],
  ['कबीर', 'kabir', 'kabeer', 'kavir'],
  ['गीता', 'gita', 'geeta', 'geetaa', 'githa'],
  ['भगवद्गीता', 'भगवदगीता', 'भगवद्', 'भगवद', 'bhagavad', 'bhagvad', 'bhagwat', 'bhagwad', 'bhagvat'],
  ['भगवान', 'bhagwan', 'bhagavan', 'bhagwaan'],
  ['गुरु', 'गुरू', 'सद्गुरु', 'सतगुरु', 'गुरुदेव', 'guru', 'guruji', 'gurudev', 'sadguru', 'satguru'],
  ['मोक्ष', 'मुक्ति', 'moksh', 'moksha', 'mukti'],
  ['तीर्थ', 'teerth', 'tirth', 'tirtha'],
  ['राम', 'raam', 'ram', 'rama'],
  ['रामायण', 'ramayan', 'ramayana'],
  ['महाभारत', 'mahabharat', 'mahabharata'],
  ['शिव', 'shiv', 'shiva'],
  ['वेद', 'ved', 'veda', 'vedas'],
  ['हनुमान', 'hanuman', 'hanumaan'],
  ['विष्णु', 'vishnu', 'vishnoo'],
  ['गणेश', 'ganesh', 'ganesha'],
  ['दुर्गा', 'durga'],
  ['कर्म', 'karma', 'karm'],
  ['धर्म', 'dharma', 'dharm'],
  ['आत्मा', 'atma', 'atman'],
  ['भक्ति', 'bhakti'],
  ['ज्ञान', 'gyan', 'gyaan', 'jnana'],
  ['संत', 'सन्त', 'sant', 'saint'],
  ['साधु', 'sadhu'],
  ['स्वर्ग', 'swarg', 'svarg', 'heaven'],
  ['नरक', 'nark', 'narak', 'hell'],
  ['पाप', 'paap', 'pap', 'sin'],
  ['पुण्य', 'punya'],
  ['उपनिषद', 'upanishad'],
  ['पुराण', 'puran', 'purana'],
];

const Map<String, String> _cons = {
  'क': 'k',
  'ख': 'kh',
  'ग': 'g',
  'घ': 'gh',
  'ङ': 'ng',
  'च': 'ch',
  'छ': 'chh',
  'ज': 'j',
  'झ': 'jh',
  'ञ': 'ny',
  'ट': 't',
  'ठ': 'th',
  'ड': 'd',
  'ढ': 'dh',
  'ण': 'n',
  'त': 't',
  'थ': 'th',
  'द': 'd',
  'ध': 'dh',
  'न': 'n',
  'प': 'p',
  'फ': 'ph',
  'ब': 'b',
  'भ': 'bh',
  'म': 'm',
  'य': 'y',
  'र': 'r',
  'ल': 'l',
  'व': 'v',
  'श': 'sh',
  'ष': 'sh',
  'स': 's',
  'ह': 'h',
  'क्ष': 'ksh',
  'त्र': 'tr',
  'ज्ञ': 'gy',
};
const Map<String, String> _vowelSigns = {'ा': 'a', 'ि': 'i', 'ी': 'i', 'ु': 'u', 'ू': 'u', 'ृ': 'ri', 'े': 'e', 'ै': 'ai', 'ो': 'o', 'ौ': 'au'};
const Set<String> stopWords = {'की', 'के', 'का', 'कि', 'में', 'से', 'को', 'और', 'या', 'है', 'पर', 'यह', 'वह', 'एक', 'भी', 'हो', 'ने', 'the', 'of', 'and', 'in', 'to', 'a'};

/// `En`
String normalizeText(String e) => unorm.nfc(e).toLowerCase().replaceAll(_punct, ' ').replaceAll(_ws, ' ').trim();

/// `Dn`
String stripMatras(String e) => normalizeText(e).replaceAll(_matra, '');

/// `On`
String foldLatin(String e) =>
    e.replaceAll('aa', 'a').replaceAll('ee', 'i').replaceAll('oo', 'u').replaceAll('ai', 'e').replaceAll('au', 'o').replaceAll('w', 'v').replaceAll('ph', 'f').replaceAll('q', 'k');

/// `kn` — Devanagari → Latin.
String transliterate(String input) {
  final t = normalizeText(input).runes.map(String.fromCharCode).toList();
  final b = StringBuffer();
  String at(int i) => i < t.length ? t[i] : '';
  for (var e = 0; e < t.length; e++) {
    final r = t[e];
    if (r == ' ') {
      b.write(' ');
      continue;
    }
    switch (r) {
      case 'अ':
      case 'आ':
        b.write('a');
        continue;
      case 'इ':
      case 'ई':
        b.write('i');
        continue;
      case 'उ':
      case 'ऊ':
        b.write('u');
        continue;
      case 'ए':
        b.write('e');
        continue;
      case 'ऐ':
        b.write('ai');
        continue;
      case 'ओ':
        b.write('o');
        continue;
      case 'औ':
        b.write('au');
        continue;
      case 'ऋ':
        b.write('ri');
        continue;
      case 'ं':
      case 'ँ':
        b.write('n');
        continue;
      case '्':
      case '़':
        continue;
    }
    final pair = r + at(e + 1);
    final a = _cons[pair] ?? _cons[r];
    if (a == null) {
      if (_alnum.hasMatch(r)) b.write(r);
      continue;
    }
    if (_cons.containsKey(pair)) e += 1;
    b.write(a);
    final o = at(e + 1);
    if (o == '्') {
      e += 1;
      continue;
    }
    if (_vowelSigns.containsKey(o)) {
      b.write(_vowelSigns[o]);
      e += 1;
      final n = at(e + 1);
      if (n == 'ं' || n == 'ँ') {
        b.write('n');
        e += 1;
      }
      continue;
    }
    if (o == 'ं' || o == 'ँ') {
      b.write('n');
      e += 1;
      continue;
    }
    final s = at(e + 1);
    if (s.isNotEmpty && s != ' ') b.write('a');
  }
  return foldLatin(b.toString().replaceAll(_ws, ' ').trim());
}

/// `An`
String skeleton(String e) => e.replaceAll(_skel, '');

/// Synonym clusters normalized once (was redone for every row and keystroke).
final List<({List<String> norm, List<String> roman})> _clusters = [
  for (final c in synonymClusters) (norm: c.map(normalizeText).toList(), roman: c.map((m) => foldLatin(transliterate(m))).toList()),
];

/// `jn` — expand a query token with synonyms.
List<String> expandToken(String e) {
  final t = normalizeText(e);
  final n = foldLatin(transliterate(t));
  final r = <String>{t, n, stripMatras(t)};
  for (final c in _clusters) {
    if (c.norm.contains(t) || c.roman.contains(n)) r.addAll(c.norm);
  }
  return r.where((s) => s.isNotEmpty).toList();
}

/// `Mn` — Levenshtein distance.
int levenshtein(String e, String t) {
  if (e == t) return 0;
  if (e.isEmpty) return t.length;
  if (t.isEmpty) return e.length;
  final n = List<int>.generate(t.length + 1, (i) => i);
  for (var r = 1; r <= e.length; r++) {
    var i = r - 1;
    n[0] = r;
    for (var a = 1; a <= t.length; a++) {
      final o = n[a];
      final s = e[r - 1] == t[a - 1] ? 0 : 1;
      final del = n[a] + 1;
      final ins = n[a - 1] + 1;
      final sub = i + s;
      n[a] = del < ins ? (del < sub ? del : sub) : (ins < sub ? ins : sub);
      i = o;
    }
  }
  return n[t.length];
}

class SearchDoc {
  SearchDoc(this.norm, this.bare, this.roman, this.skel, this.tokens);
  final String norm;
  final String bare;
  final String roman;
  final String skel;
  final List<String> tokens;
}

/// `Nn`
SearchDoc makeDoc(String e) {
  final t = normalizeText(e);
  final n = transliterate(t);
  return SearchDoc(t, stripMatras(t), n, skeleton(n), n.split(' ').where((x) => x.length > 1).toList());
}

/// Builds docs for many texts at once (runs in a background isolate).
List<SearchDoc> makeDocs(List<String> texts) => [for (final t in texts) makeDoc(t)];

/// `Fn`
SearchDoc docOf(List<String?> fields) => makeDoc(fields.whereType<String>().where((f) => f.isNotEmpty).join('\n'));

/// One expanded form of a query token, with every derived string computed once.
class SearchVariant {
  SearchVariant(String r)
      : e = normalizeText(r),
        i = foldLatin(transliterate(r)) {
    a = skeleton(i);
    o = stripMatras(e);
  }
  final String e;
  final String i;
  late final String a;
  late final String o;
}

/// A query compiled once per keystroke (instead of once per row).
class QueryPlan {
  QueryPlan(String query) {
    final n = query.trim();
    empty = n.isEmpty;
    if (empty) return;
    final r = normalizeText(n).split(' ').where((e) => e.length > 1 && !stopWords.contains(e)).toList();
    final i = r.isNotEmpty ? r : [normalizeText(n)].where((e) => e.isNotEmpty).toList();
    tokens = [for (final t in i) expandToken(t).map(SearchVariant.new).toList()];
  }
  late final bool empty;
  List<List<SearchVariant>> tokens = const [];
}

int _scoreVariants(List<SearchVariant> vs, SearchDoc t) {
  var n = 0;
  for (final v in vs) {
    final e = v.e, i = v.i, a = v.a, o = v.o;
    if (n < 100 && e.length >= 2 && t.norm.contains(e)) n = 100;
    if (n < 90 && o.length >= 4 && t.bare.contains(o)) n = 90;
    if (n < 92 && i.length >= 4 && t.roman.contains(i)) n = 92;
    if (n < 88 && i.length >= 2 && i.length <= 3 && t.tokens.any((x) => x == i || x.startsWith(i))) n = 88;
    if (n < 80 && a.length >= 4 && t.skel.contains(a)) n = 80;
    if (n < 66 && i.length >= 4) {
      for (final tok in t.tokens) {
        if (tok.isNotEmpty && tok.codeUnitAt(0) == i.codeUnitAt(0) && (tok.length - i.length).abs() <= 2 && levenshtein(i, tok) <= 1) {
          n = 66;
          break;
        }
      }
    }
    if (n >= 100) break;
  }
  return n;
}

int scorePlan(QueryPlan p, SearchDoc t) {
  if (p.empty) return 1;
  final i = p.tokens;
  if (i.isEmpty) return 0;
  var a = 0;
  var o = 0;
  for (final e in i) {
    final s = _scoreVariants(e, t);
    if (s > 0) a += 1;
    o += s;
  }
  if (a == 0 || (i.length > 1 && a / i.length < 0.5)) return 0;
  final s = o / i.length;
  return i.length > 1 && a < i.length ? (s * 0.65).round() : s.round();
}

/// `Ln` — exact substring hits first (by position), else fuzzy-scored results.
List<T> searchRows<T>(List<T> rows, String query, SearchDoc Function(T) doc) {
  final r = query.trim();
  if (r.isEmpty) return rows;
  final i = normalizeText(r);
  final a = stripMatras(i);
  final hits = <MapEntry<T, int>>[];
  for (final row in rows) {
    final d = doc(row);
    final at = i.isNotEmpty ? d.norm.indexOf(i) : -1;
    if (at >= 0) {
      hits.add(MapEntry(row, at));
      continue;
    }
    if (a.length >= 2) {
      final b = d.bare.indexOf(a);
      if (b >= 0) hits.add(MapEntry(row, 1000 + b));
    }
  }
  if (hits.isNotEmpty) {
    final sorted = [...hits];
    _stableSort(sorted, (x, y) => x.value.compareTo(y.value));
    return sorted.map((e) => e.key).toList();
  }
  final plan = QueryPlan(r);
  final scored = rows.map((e) => MapEntry(e, scorePlan(plan, doc(e)))).where((e) => e.value > 0).toList();
  _stableSort(scored, (x, y) => y.value.compareTo(x.value));
  return scored.map((e) => e.key).toList();
}

/// `Rn`
List<T> searchFields<T>(List<T> rows, String query, List<String?> Function(T) fields) {
  final r = query.trim();
  return r.isEmpty ? rows : searchRows(rows, r, (e) => docOf(fields(e)));
}

/// JS Array.prototype.sort is stable; Dart's List.sort is not guaranteed to be.
void _stableSort<T>(List<T> list, int Function(T, T) cmp) {
  final indexed = List.generate(list.length, (i) => MapEntry(i, list[i]));
  indexed.sort((a, b) {
    final c = cmp(a.value, b.value);
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  for (var i = 0; i < list.length; i++) {
    list[i] = indexed[i].value;
  }
}

void stableSort<T>(List<T> list, int Function(T, T) cmp) => _stableSort(list, cmp);

/// Pre-built search docs for one list (built once per catalog, not per keystroke).
class SearchIndex<T> {
  SearchIndex(this.rows, List<String?> Function(T) fields) : docs = [for (final r in rows) docOf(fields(r))];
  final List<T> rows;
  final List<SearchDoc> docs;
  late final Map<T, SearchDoc> _byRow = {for (var i = 0; i < rows.length; i++) rows[i]: docs[i]};

  List<T> search(String query) => searchRows(rows, query, (r) => _byRow[r]!);
}
