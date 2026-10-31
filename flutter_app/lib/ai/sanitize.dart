/// Client-side filter for AI text: the model sometimes leaks the internal candidate ids
/// ("id-467", "[id=467]", "(ID: 467)", "प्रमाण id 467"). The user must never see them: each
/// is replaced by the praman's name (from [nameOf]) or dropped when the id is unknown.
library;

final RegExp _idRef = RegExp(
  r'(?:[\[\(（]\s*)?\b(?:id|ID|Id|आईडी)\s*[-=:#\s]\s*(\d{1,10})(?:\s*,\s*(?:(?:id|ID|Id)\s*[-=:#\s]\s*)?\d{1,10})*(?:\s*[\]\)）])?',
);
final RegExp _num = RegExp(r'\d{1,10}');

String sanitizeAiText(String text, String? Function(int id) nameOf) {
  var out = text.replaceAllMapped(_idRef, (m) {
    final names = <String>[];
    for (final n in _num.allMatches(m[0]!)) {
      final name = nameOf(int.parse(n[0]!));
      if (name != null && name.trim().isNotEmpty && !names.contains(name.trim())) names.add(name.trim());
    }
    final open = m[0]!.trimLeft().startsWith(RegExp(r'[\[\(（]'));
    if (names.isEmpty) return '';
    final s = names.map((e) => '“$e”').join(', ');
    return open ? '($s)' : s;
  });
  // Tidy what the removal leaves behind: empty brackets, doubled spaces, space before punctuation.
  out = out
      .replaceAll(RegExp(r'\(\s*\)|\[\s*\]'), '')
      .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
      .replaceAll(RegExp(r' +([,।.!?;:])'), r'$1')
      .replaceAll(RegExp(r' +\n'), '\n');
  return out.trim();
}
