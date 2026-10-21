import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/search.dart';

/// Search benchmark on the real catalog (823 pramans / 330 topics).
/// Needs the API dumps in /tmp/bench (skipped otherwise, e.g. on CI):
///   curl '.../api/index.php?request=getPramans' > /tmp/bench/getPramans.json
void main() {
  final dir = Directory(Platform.environment['GRANTH_BENCH'] ?? '/tmp/bench');
  final ok = File('${dir.path}/getPramans.json').existsSync() && File('${dir.path}/getTopics.json').existsSync();
  List<Map<String, dynamic>> load(String n) => ((jsonDecode(File('${dir.path}/$n.json').readAsStringSync()) as Map)['data'] as List).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();

  test('search benchmark', () {
    final pramans = load('getPramans').map(Praman.new).toList();
    final topics = load('getTopics').map(Topic.new).toList();
    // Every prefix the user types, like the search box sees it.
    const queries = ['mrityu ke baad', 'kabir sagar', 'gita gyan', 'satlok', 'parmatma', 'मृत्यु', 'गीता अध्याय', 'brahma vishnu mahesh', 'moksh', 'kabeer'];
    final sw = Stopwatch()..start();
    final pDocs = SearchIndex<Praman>(pramans, (p) => [p.title, p.description, p.topicTitle, p.granthTitle, p.granthAuthor, p.youtubeDesc]);
    final tDocs = SearchIndex<Topic>(topics, (t) => [t.title, t.description]);
    final index = sw.elapsedMicroseconds;
    var keystrokes = 0;
    var worst = 0;
    final total = Stopwatch()..start();
    for (final q in queries) {
      for (var n = 1; n <= q.length; n++) {
        final k = Stopwatch()..start();
        pDocs.search(q.substring(0, n));
        tDocs.search(q.substring(0, n));
        k.stop();
        worst = worst < k.elapsedMicroseconds ? k.elapsedMicroseconds : worst;
        keystrokes++;
      }
    }
    total.stop();
    // ignore: avoid_print
    print('BENCH index=${(index / 1000).toStringAsFixed(1)}ms keystrokes=$keystrokes '
        'avg=${(total.elapsedMicroseconds / keystrokes / 1000).toStringAsFixed(2)}ms worst=${(worst / 1000).toStringAsFixed(2)}ms '
        'hits(mrityu ke baad)=${pDocs.search('mrityu ke baad').length} hits(kabeer)=${pDocs.search('kabeer').length}');
  }, skip: ok ? false : 'no /tmp/bench data');
}
