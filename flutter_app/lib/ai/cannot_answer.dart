/// When does the AI "not know"? The rule (also in docs/AI.md), from what the app already has:
///
/// The Worker may only cite candidates it was given, and its system prompt says: when the sources
/// do not answer the question, say "दिए गए प्रमाणों में इसका सीधा उत्तर नहीं मिला", add the general
/// part under "सामान्य जानकारी:" and cite nothing (`cited: []`). So the AI **cannot answer** when
///
///  1. it cited no real source — no praman of the catalog, no admin note and no topic — or
///  2. its text says it did not find the answer ("उत्तर नहीं मिला", …) and it did not lean on an
///     admin note.
///
/// Errors (offline, rate limit, …) are not "cannot answer": they have their own retry card.
library;

import 'extra_sources.dart';

const List<String> kRefusalPhrases = [
  'सीधा उत्तर नहीं मिला',
  'उत्तर नहीं मिला',
  'जानकारी उपलब्ध नहीं',
  'प्रमाणों में नहीं',
];

/// [cited]: the ids the Worker returned; [isPraman]: whether an id is a praman of this catalog.
bool aiCannotAnswer({
  required String answer,
  required List<int> cited,
  required bool Function(int id) isPraman,
}) {
  final real = [
    for (final id in cited)
      if (isPraman(id) || isNoteId(id) || isTopicId(id)) id,
  ];
  if (real.isEmpty) return true;
  final refused = kRefusalPhrases.any(answer.contains);
  return refused && !real.any(isNoteId);
}
