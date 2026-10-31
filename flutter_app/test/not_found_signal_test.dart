import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/cannot_answer.dart';

void main() {
  test('parseNotFound shapes', () {
    expect(parseNotFound({'not_found': true}), true);
    expect(parseNotFound({'found': false}), true);
    expect(parseNotFound({'answer_found': true}), false);
    expect(parseNotFound({'status': 'not-found'}), true);
    expect(parseNotFound({'cannot_answer': false}), false);
    expect(parseNotFound({'answer': 'x'}), null);
  });
  test('explicit signal wins, heuristic fallback', () {
    expect(aiCannotAnswer(answer: 'ok', cited: [1], isPraman: (_) => true, notFound: true), true);
    expect(aiCannotAnswer(answer: 'उत्तर नहीं मिला', cited: [], isPraman: (_) => true, notFound: false), false);
    expect(aiCannotAnswer(answer: 'ok', cited: [], isPraman: (_) => true), true);
    expect(aiCannotAnswer(answer: 'ok', cited: [1], isPraman: (_) => true), false);
  });
}
