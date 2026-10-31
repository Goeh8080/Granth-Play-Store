/// Client-side filter for AI text: the model sometimes leaks the internal candidate ids
/// ("id-467", "[id=467]", "(ID: 467)", "प्रमाण id 467"). The user must never see them: each
/// is replaced by the praman's name (from [nameOf]) or dropped when the id is unknown.
library;

// Keyword forms: "id-467", "(id = 759)", "id: 759", "ID-759", "IDs 3, 4", "[id=467]", "#759 id",
// "आईडी 12", "स्रोत 3", "source 3". Case-insensitive; lists joined by "," "/" "and" "और" "व".
const String _kw = r'(?:ids?|आई\.?डी\.?|स्रोत|sources?|src)';
const String _sep = r'[\s]*[-=:#.]?[\s]*';
const String _list = r'(?:\s*(?:,|/|&|\band\b|और|व)\s*(?:' + _kw + _sep + r')?#?\d{1,10})*';
final RegExp _idRef = RegExp(
  r'(?:[\[\(（【]\s*)?(?<![\p{L}\p{M}\p{N}])' + _kw + r'(?![\p{L}\p{M}])' + _sep + r'#?(\d{1,10})' + _list + r'(?:\s*[\]\)）】])?',
  caseSensitive: false,
  unicode: true,
);
// Numbered sources from the server ("[1]", "[1, 3]", "【2】"): 1-based positions in the candidates.
final RegExp _numRef = RegExp(r'[\[【]\s*\d{1,3}(?:\s*[,–-]\s*\d{1,3})*\s*[\]】]');
final RegExp _num = RegExp(r'\d{1,10}');

String _names(Iterable<String?> raw, bool open) {
  final names = <String>[];
  for (final n in raw) {
    if (n != null && n.trim().isNotEmpty && !names.contains(n.trim())) names.add(n.trim());
  }
  if (names.isEmpty) return '';
  final s = names.map((e) => '“$e”').join(', ');
  return open ? '($s)' : s;
}

/// [nameOf] maps a praman/candidate id to its name; [sourceName] maps a 1-based source number
/// ("[2]") to its name. Unknown ids or numbers are dropped.
String sanitizeAiText(String text, String? Function(int id) nameOf, {String? Function(int n)? sourceName}) {
  var out = text.replaceAllMapped(_idRef, (m) {
    final open = m[0]!.trimLeft().startsWith(RegExp(r'[\[\(（【]'));
    return _names([for (final n in _num.allMatches(m[0]!)) nameOf(int.parse(n[0]!))], open);
  });
  out = out.replaceAllMapped(_numRef, (m) {
    final ns = [for (final n in _num.allMatches(m[0]!)) int.parse(n[0]!)];
    return _names([for (final n in ns) sourceName?.call(n) ?? nameOf(n)], true);
  });
  // Tidy what the removal leaves behind: empty brackets, doubled spaces, space before punctuation.
  out = out
      .replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r' +([,।.!?;:])'), r'$1')
      .replaceAll(RegExp(r' +\n'), '\n');
  return out.trim();
}
