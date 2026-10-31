import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/ai/ai_client.dart';
import 'package:granthprabandhan/ai/chat_store.dart';

AiAnswer p(Map<String, Object?> m) => parseAskResponse(200, jsonEncode({'answer': 'उत्तर', 'cited': <int>[], 'provider': 'x', ...m}));

void main() {
  test('found:false + ask_admin → offer, reason kept', () {
    final a = p({'found': false, 'reason': 'out_of_scope', 'ask_admin': true});
    expect(a.found, false);
    expect(a.reason, 'out_of_scope');
    expect(a.offerAdmin, true);
  });
  test('found:true with empty cited is a valid answer (no offer)', () {
    expect(p({'found': true, 'ask_admin': false}).offerAdmin, false);
  });
  test('ask_admin:true alone offers', () => expect(p({'ask_admin': true}).offerAdmin, true));
  test('found absent → null (heuristic decides); aliases still work', () {
    expect(p({}).offerAdmin, null);
    expect(p({'not_found': true}).offerAdmin, true);
  });
  test('sources parsed; bad entries dropped; only http(s) links tappable', () {
    final a = p({
      'found': true,
      'sources': [
        {'book': 'ज्ञान गंगा', 'chapter': 'अध्याय 3', 'url': 'https://example.org/gg#3'},
        {'book': 'जीने की राह', 'url': 'javascript:alert(1)'},
        {'chapter': 'no book'},
        'junk',
      ],
    });
    expect(a.sources.map((s) => s.label), ['ज्ञान गंगा · अध्याय 3', 'जीने की राह']);
    expect(a.sources.map((s) => s.hasLink), [true, false]);
  });
  test('sources survive ChatMsg persistence', () {
    final m = ChatMsg(role: 'assistant', text: 't', sources: const [BookSource(book: 'b', chapter: 'c', url: 'https://x.org')]);
    final back = ChatMsg.fromJson(jsonDecode(jsonEncode(m.toJson())))!;
    expect(back.sources.single.label, 'b · c');
    expect(back.sources.single.url, 'https://x.org');
  });
}
