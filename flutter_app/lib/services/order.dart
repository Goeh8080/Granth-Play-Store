import '../models/models.dart';
import 'search.dart' show stableSort;

/// Port of `bn()` — pramans inside a granth are ordered by भाग/खण्ड/स्कन्ध/मण्डल/अध्याय/सूक्त/श्लोक/मंत्र/पेज,
/// and कबीर सागर uses its fixed book order.

const _devDigits = '०१२३४५६७८९';
const int _un = 1000000000;
const _dn = r'(?:\s*(?:नं\.?|नंबर|संख्या|number))?\s*[:\-–]?\s*(\d+)';
final List<RegExp> _fields = [
  RegExp('भाग$_dn'),
  RegExp('ख(?:ण्ड|ंड)$_dn'),
  RegExp('स्क(?:न्ध|ंध)$_dn'),
  RegExp('(?:मण्डल|मंडल)$_dn'),
  RegExp('अध्याय$_dn'),
  RegExp('सूक्त$_dn'),
  RegExp('श्लोक$_dn'),
  RegExp('(?:मंत्र|मन्त्र)$_dn'),
  RegExp('(?:पेज|पृष्ठ|page)$_dn', caseSensitive: false),
];
const _pageIdx = 8;

final RegExp _devRe = RegExp('[०-९]');
String latinDigits(String e) => e.replaceAllMapped(_devRe, (m) => '${_devDigits.indexOf(m[0]!)}');

final RegExp _kabirSagar = RegExp(r'कबीर\s*सागर|kabir\s*sagar', caseSensitive: false);
bool isKabirSagar(String e) => _kabirSagar.hasMatch(e);

List<int> orderKey(String title) {
  final t = latinDigits(title);
  final n = _fields.map((r) {
    final m = r.firstMatch(t);
    return m != null ? int.parse(m.group(1)!) : _un;
  }).toList();
  if (!n.any((e) => e != _un)) {
    final m = _anyDigits.firstMatch(t);
    n.add(m != null ? int.parse(m.group(1)!) : _un);
  }
  return n;
}

const List<String> kabirBooks = [
  'ज्ञानसागर', 'अनुरागसागर', 'अम्बुसागर', 'विवेकसागर', 'सर्वज्ञसागर', 'ज्ञानप्रकाश', 'अमरसिंह बोध', 'बीरसिंह बोध',
  'भोपाल बोध', 'जगजीवन बोध', 'गरुड़ बोध', 'हनुमान बोध', 'लक्ष्मण बोध', 'मोहम्मद बोध', 'काफिर बोध', 'सुल्तान बोध',
  'निरंजन बोध', 'ज्ञानबोध', 'भवतारण बोध', 'मुक्तिबोध', 'चौकास्वरोदय', 'अलिफनामा', 'कबीरबानी', 'कर्मबोध', 'अमरमूल',
  'उग्रगीता', 'ज्ञानस्थिति बोध', 'संतोष बोध', 'कायापांजी', 'पंचमुद्रा', 'आत्मबोध', 'जैनधर्म बोध', 'स्वसमवेद बोध',
  'धर्मबोध', 'कमाल बोध', 'स्वाश गुंजार', 'अगमनिगम बोध', 'सुमिरन बोध', 'कबीरचरित्र बोध', 'गुरु महात्म्य', 'जीवधर्म बोध',
];

// Built once (round 7): the book list sorted longest first, its names without spaces, and the
// patterns. kabirKey used to rebuild all of them on every comparison of the sort.
final RegExp _spaces = RegExp(r'\s+');
final List<(String, String, int)> _booksLongFirst = (() {
  final sorted = [...kabirBooks]..sort((a, b) => b.length.compareTo(a.length));
  return [for (final e in sorted) (e, e.replaceAll(_spaces, ''), kabirBooks.indexOf(e))];
})();
final RegExp _kabirPage = RegExp(r'(?:पेज|पृष्ठ|page)\s*(?:नं\.?|नंबर|संख्या|number)?\s*[:\-–]?\s*(\d+)', caseSensitive: false);
final RegExp _anyDigits = RegExp(r'(\d+)');

({int order, int page}) kabirKey(String title) {
  final t = latinDigits(title).replaceAll('\u093C', '');
  final n = t.replaceAll(_spaces, '');
  var r = kabirBooks.length + 5;
  for (final (name, bare, index) in _booksLongFirst) {
    if (t.contains(name) || n.contains(bare)) {
      r = index;
      break;
    }
  }
  final a = _kabirPage.firstMatch(t);
  final digits = a?.group(1) ?? _anyDigits.firstMatch(t)?.group(1);
  final o = digits != null ? int.parse(digits) : _un;
  return (order: r, page: o);
}

int _cmpKeys(List<int> e, List<int> t, List<int> order) {
  int at(List<int> l, int i) => i < l.length ? l[i] : _un;
  for (final r in order) {
    final n = at(e, r) - at(t, r);
    if (n != 0) return n;
  }
  return at(e, _fields.length) - at(t, _fields.length);
}

/// localeCompare(…, 'en', {numeric: true}) for ids.
int numericCompare(String a, String b) {
  final x = int.tryParse(a);
  final y = int.tryParse(b);
  if (x != null && y != null) return x.compareTo(y);
  return a.compareTo(b);
}

List<Praman> orderPramans(List<Praman> rows, [String granthTitle = '']) {
  final groups = <String, List<Praman>>{};
  for (final r in rows) {
    final key = '${r.granthId}|${granthTitle.isNotEmpty ? granthTitle : r.granthTitle}';
    (groups[key] ??= []).add(r);
  }
  List<Praman> sortGroup(List<Praman> list, String title) {
    final out = [...list];
    if (isKabirSagar(title)) {
      final ks = {for (final p in out) p: kabirKey(p.title)};
      stableSort<Praman>(out, (a, b) {
        final n = ks[a]!;
        final r = ks[b]!;
        if (n.order != r.order) return n.order - r.order;
        if (n.page != r.page) return n.page - r.page;
        return numericCompare(a.id, b.id);
      });
      return out;
    }
    const order = [_pageIdx, 4, 6, 7, 0, 1, 5, 2, 3];
    final keys = {for (final p in out) p: orderKey(p.title)};
    stableSort<Praman>(out, (a, b) {
      final c = _cmpKeys(keys[a]!, keys[b]!, order);
      return c != 0 ? c : numericCompare(a.id, b.id);
    });
    return out;
  }

  if (groups.length <= 1) {
    return sortGroup(rows, granthTitle.isNotEmpty ? granthTitle : (rows.isNotEmpty ? rows.first.granthTitle : ''));
  }
  final entries = groups.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return entries.expand((e) => sortGroup(e.value, e.key.split('|').skip(1).join('|'))).toList();
}
