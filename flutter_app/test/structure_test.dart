import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/models/structure.dart';
import 'package:granthprabandhan/services/shelves.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:granthprabandhan/widgets/group_icon.dart';
import 'package:granthprabandhan/widgets/religion_symbol.dart';

import 'helpers.dart';

/// The 104 granths of Ashok's API (id, title, position, pramanCount), as of Round 10.
List<Granth> realGranths() => [
      for (final e in jsonDecode(File('test/fixtures/granths_104.json').readAsStringSync()) as List) Granth((e as Map).cast<String, dynamic>()),
    ];

Granth granth(String id, String title, [String position = '1']) => Granth({'id': id, 'title': title, 'position': position, 'pramanCount': '3'});

Structure mini(String json) => Structure.parse(json);

void main() {
  final structure = shippedStructure();
  final granths = realGranths();

  group('structure.json (the file the APK ships)', () {
    test('six religions in the agreed order, with the agreed groups', () {
      expect([for (final r in structure.religions) r.title], ['हिन्दू', 'इस्लाम', 'सिख', 'ईसाई', 'बुद्ध', 'कबीर']);
      List<String> groups(String r) => [for (final g in structure.religion(r)!.groups) g.title];
      expect(groups('hindu'), ['वेद', 'गीता', 'पुराण', 'उपनिषद', 'रामायण', 'महाभारत', 'मनुस्मृति', '6 शास्त्र']);
      expect(groups('islam'), ['क़ुरान', 'हदीस']);
      expect(groups('sikh'), ['गुरु ग्रंथ साहिब', 'दसम ग्रंथ']);
      expect(groups('christian'), ['बाइबल']);
      expect(groups('buddh'), ['त्रिपिटक', 'धम्मपद']);
      expect(groups('kabir'), ['कबीर सागर', 'बीजक', 'शब्दावली']);
      List<String> subs(String g) => [for (final s in structure.religion('hindu')!.groups.firstWhere((e) => e.id == g).subgroups) s.title];
      expect(subs('ved'), ['ऋग्वेद', 'यजुर्वेद', 'सामवेद', 'अथर्ववेद', 'सूक्ष्मवेद']);
      expect(subs('shastra'), ['न्याय', 'वैशेषिक', 'सांख्य', 'योग', 'मीमांसा', 'वेदांत']);
      expect(structure.other.title, 'अन्य');
    });

    test('ids are unique across the whole file and all exist in the API data', () {
      final seen = <String, String>{};
      for (final l in structure.leaves()) {
        for (final id in l.leaf.granthIds) {
          expect(seen.containsKey(id), isFalse, reason: 'id $id listed under ${seen[id]} and ${l.key}');
          seen[id] = l.key;
        }
      }
      for (final id in structure.other.granthIds) {
        expect(seen.containsKey(id), isFalse, reason: 'id $id is both mapped (${seen[id]}) and forced into अन्य');
        seen[id] = kOtherId;
      }
      final known = {for (final g in granths) g.id};
      for (final id in seen.keys) {
        expect(known.contains(id), isTrue, reason: 'id $id does not exist in the API data');
      }
    });

    test('group ids are unique per religion; every icon is one that is painted or shipped as an svg', () {
      for (final r in structure.religions) {
        expect(religionSymbolNames, contains(r.icon), reason: 'religion symbol ${r.icon}');
        expect({for (final g in r.groups) g.id}.length, r.groups.length, reason: r.id);
        for (final g in r.groups) {
          expect(groupIconNames, contains(g.icon), reason: '${r.id}/${g.id}');
          expect({for (final s in g.subgroups) s.id}.length, g.subgroups.length);
          for (final s in g.subgroups) {
            expect(groupIconNames, contains(s.icon), reason: '${r.id}/${g.id}/${s.id}');
          }
        }
      }
      expect(groupIconNames, contains(structure.other.icon));
      expect(religionSymbolNames, contains(structure.other.icon), reason: 'अन्य shows the neutral symbol');
      expect({for (final r in structure.religions) r.icon}.length, structure.religions.length, reason: 'every religion has its own symbol');
    });
  });

  group('mapping of the 104 real granths', () {
    final index = ShelfIndex.build(structure, granths);

    test('there are 104 granths, each placed exactly once', () {
      expect(granths.length, 104);
      expect(index.placements.length, 104);
      final all = <String>[
        for (final l in structure.leaves()) ...index.inLeaf(l.key).map((g) => g.id),
        ...index.other.map((g) => g.id),
      ];
      expect(all.length, 104);
      expect(all.toSet().length, 104, reason: 'no granth in two folders');
      expect(all.toSet(), {for (final g in granths) g.id}, reason: 'none lost');
    });

    test('counts per group (the numbers on the cards are real)', () {
      int n(String r, String g, [String? s]) => index.inGroup(r, g, s).length;
      expect(n('hindu', 'puran'), 37);
      expect(n('hindu', 'ramayan'), 6);
      expect(n('hindu', 'mahabharat'), 4);
      expect(n('hindu', 'geeta'), 2);
      expect(n('hindu', 'ved'), 9);
      expect(n('hindu', 'ved', 'rigved'), 5);
      expect(n('hindu', 'ved', 'sukshmved'), 0);
      expect(n('hindu', 'upanishad'), 1);
      expect(n('hindu', 'manusmriti'), 1);
      expect(n('hindu', 'shastra'), 0);
      expect(n('islam', 'quran'), 1);
      expect(n('sikh', 'guru-granth'), 2);
      expect(n('christian', 'bible'), 1);
      expect(n('kabir', 'kabir-sagar'), 2);
      expect(n('kabir', 'bijak'), 1);
      expect(n('kabir', 'shabdavali'), 1);
      expect(index.other.length, 36);
      final inReligions = structure.religions.fold<int>(0, (a, r) => a + index.inReligion(r.id).length);
      expect(inReligions + index.other.length, 104);
    });

    test('titles that look like a match but are not stay in अन्य (a wrong shelf is worse)', () {
      String title(String id) => granths.firstWhere((g) => g.id == id).title;
      final other = {for (final g in index.other) g.id};
      // घट रामायण (a Sant-mat text), भविष्य मालिक पुराण, योगवशिष्ट, पाराशर स्मृति, a biography of Muhammad …
      for (final id in ['18', '97', '98', '36', '89', '59', '69', '55', '86']) {
        expect(other, contains(id), reason: '$id ${title(id)}');
      }
    });

    test('a granth sits where the structure says: शिव पुराण in पुराण', () {
      final shiv = granths.firstWhere((g) => g.title.contains('शिव') && g.title.contains('पुराण'));
      expect(index.placements[shiv.id]!.key, 'hindu/puran');
      expect(index.inGroup('hindu', 'puran').map((g) => g.id), contains(shiv.id));
    });

    test('lists are in the API order (position), numerically', () {
      for (final l in structure.leaves()) {
        final p = [for (final g in index.inLeaf(l.key)) int.parse(g.position)];
        expect(p, [...p]..sort(), reason: l.key);
      }
      final p = [for (final g in index.inReligion('hindu')) int.parse(g.position)];
      expect(p, [...p]..sort());
    });

    test('empty groups are hidden, groups with granths are shown in file order', () {
      expect([for (final g in index.visibleGroups('hindu')) g.id], ['ved', 'geeta', 'puran', 'upanishad', 'ramayan', 'mahabharat', 'manusmriti']);
      expect([for (final s in index.visibleSubgroups('hindu', 'ved')) s.id], ['rigved', 'yajurved', 'samved', 'atharvved']);
      expect(index.visibleSubgroups('hindu', 'shastra'), isEmpty);
      expect([for (final g in index.visibleGroups('islam')) g.id], ['quran']);
      expect([for (final g in index.visibleGroups('sikh')) g.id], ['guru-granth']);
      expect(index.visibleGroups('buddh'), isEmpty, reason: 'बुद्ध has no granth yet: the religion folder says जल्द आ रहा है');
      expect(index.inReligion('buddh'), isEmpty);
    });
  });

  group('placement rules', () {
    const two = '''
{"version":1,"religions":[
 {"id":"a","title":"क","tone":"saffron","icon":"folder-open","groups":[
   {"id":"g1","title":"एक","icon":"bible","granthIds":["1"],"keywords":["अलफा"],"notKeywords":["नहीं"]},
   {"id":"g2","title":"दो","icon":"bible","granthIds":[],"keywords":["अलफा","बीटा"]}]}],
 "other":{"id":"other","title":"अन्य","icon":"misc","forceIds":["5"]}}
''';

    test('an id in the file wins over keywords; a forced id goes to अन्य even if a keyword fits', () {
      final idx = ShelfIndex.build(mini(two), [granth('1', 'बीटा ग्रंथ'), granth('5', 'बीटा दूसरा')]);
      expect(idx.placements['1']!.key, 'a/g1');
      expect(idx.placements['1']!.how, 'id');
      expect(idx.placements['5']!.key, kOtherId);
      expect(idx.placements['5']!.how, 'forced');
    });

    test('exactly one keyword hit places the granth', () {
      final idx = ShelfIndex.build(mini(two), [granth('7', 'पुराना बीटा')]);
      expect(idx.placements['7']!.key, 'a/g2');
      expect(idx.placements['7']!.how, 'keyword');
    });

    test('two groups claiming one title = ambiguous = अन्य', () {
      final idx = ShelfIndex.build(mini(two), [granth('8', 'अलफा ग्रंथ')]);
      expect(idx.placements['8']!.key, kOtherId);
      expect(idx.placements['8']!.how, 'fallback');
    });

    test('notKeywords veto a match', () {
      // "अलफा" would be ambiguous (g1 and g2); g1 vetoes "नहीं", so g2 is the only claimant.
      final idx = ShelfIndex.build(mini(two), [granth('9', 'अलफा नहीं वाला'), granth('10', 'अलफा वाला')]);
      expect(idx.placements['9']!.key, 'a/g2');
      expect(idx.placements['10']!.key, kOtherId, reason: 'without the veto both claim it');
    });

    test('spelling variants still match (nukta / chandrabindu / spaces)', () {
      final s = mini('{"religions":[{"id":"i","title":"इ","tone":"maroon","icon":"folder-open","groups":[{"id":"q","title":"क़","icon":"quran","granthIds":[],"keywords":["क़ुरआन"]}]}],"other":{"id":"other","title":"अन्य","icon":"misc"}}');
      final idx = ShelfIndex.build(s, [granth('1', 'पवित्र कुरआन  शरीफ'), granth('2', 'पवित्र क़ुरआन')]);
      expect(idx.placements['1']!.key, 'i/q');
      expect(idx.placements['2']!.key, 'i/q');
    });

    test('a granth the structure has never heard of lands in अन्य, with the real structure', () {
      final withNew = [...granths, granth('9001', 'बिल्कुल नया ग्रंथ', '500'), granth('9002', '', '501')];
      final idx = ShelfIndex.build(structure, withNew);
      expect(idx.placements['9001']!.key, kOtherId);
      expect(idx.placements['9002']!.key, kOtherId);
      expect(idx.other.map((g) => g.id), containsAll(['9001', '9002']));
      expect(idx.other.length, 38);
      expect(idx.placements.length, 106);
    });

    test('a new granth whose title says "शिव पुराण" is placed by keyword, a new "कबीर" one is not guessed', () {
      final idx = ShelfIndex.build(structure, [granth('9003', 'लिंग पुराण (नया संस्करण)'), granth('9004', 'कबीर की उलटबांसी')]);
      expect(idx.placements['9003']!.key, 'hindu/puran');
      expect(idx.placements['9004']!.key, kOtherId);
    });

    test('with no structure file at all every granth is in अन्य', () {
      final idx = ShelfIndex.build(Structure.empty, granths);
      expect(idx.other.length, 104);
      expect(idx.visibleGroups('hindu'), isEmpty);
    });

    test('an empty file is an empty structure; junk throws (Shelves.load catches it → everything in अन्य)', () {
      expect(Structure.parse('{}').religions, isEmpty);
      expect(() => Structure.parse('not json'), throwsA(anything));
      expect(() => Structure.parse('[]'), throwsA(anything));
    });
  });

  group('Shelves cache', () {
    setUp(() => Shelves.use(structure));
    test('the index is built once per catalog list', () {
      final before = Shelves.builds;
      final a = Shelves.indexFor(granths);
      expect(identical(Shelves.indexFor(granths), a), isTrue);
      expect(Shelves.builds, before + 1);
      final replaced = [...granths];
      expect(identical(Shelves.indexFor(replaced), a), isFalse, reason: 'a sync replaces the list → rebuilt');
      expect(Shelves.builds, before + 2);
      final shorter = [...granths]..removeLast();
      expect(Shelves.indexFor(shorter).placements.length, 103);
    });

    test('a different structure rebuilds', () {
      final a = Shelves.indexFor(granths);
      Shelves.use(Structure.empty);
      expect(Shelves.indexFor(granths).other.length, 104);
      expect(identical(Shelves.indexFor(granths), a), isFalse);
    });
  });

  group('routes and scroll places of every level', () {
    test('folder hashes round-trip', () {
      for (final (h, r, g, s, flat) in [
        ('#/granths', null, null, null, false),
        ('#/granths?r=hindu', 'hindu', null, null, false),
        ('#/granths?r=hindu&g=puran', 'hindu', 'puran', null, false),
        ('#/granths?r=hindu&g=ved&s=rigved', 'hindu', 'ved', 'rigved', false),
        ('#/granths?r=other', 'other', null, null, false),
        ('#/granths?all=1', null, null, null, true),
      ]) {
        final route = GRoute.parse(h);
        expect(route.panel, Panel.granths, reason: h);
        expect(route.religionId, r, reason: h);
        expect(route.groupId, g, reason: h);
        expect(route.subId, s, reason: h);
        expect(route.flat, flat, reason: h);
        if (!flat) expect(GRoute.folderHash(religion: r, group: g, sub: s), h);
      }
    });

    test('a group or sub-group without its parent is ignored', () {
      expect(GRoute.parse('#/granths?g=puran').groupId, isNull);
      expect(GRoute.parse('#/granths?r=hindu&s=rigved').subId, isNull);
    });

    test('every level has its own route key (the panel re-mounts) and its own saved place', () {
      final hashes = [
        '#/granths',
        '#/granths?all=1',
        '#/granths?r=hindu',
        '#/granths?r=islam',
        '#/granths?r=hindu&g=puran',
        '#/granths?r=hindu&g=geeta',
        '#/granths?r=hindu&g=ved',
        '#/granths?r=hindu&g=ved&s=rigved',
        '#/granths?r=hindu&g=ved&s=samved',
        '#/granths?r=other',
      ];
      expect({for (final h in hashes) GRoute.parse(h).key}.length, hashes.length);
      final places = [for (final h in hashes) Places.keyFor(GRoute.parse(h))];
      expect(places.toSet().length, hashes.length);
      expect(places[0], 'religions-place');
      expect(places[1], 'granth-list-place', reason: 'the old flat list keeps its old key (saved places survive the update)');
      expect(places[2], 'religion-list:hindu');
      expect(places[4], 'group-list:hindu:puran');
      expect(places[7], 'group-list:hindu:ved:rigved');
    });

    test('old routes keep their old keys', () {
      for (final h in ['#/dashboard', '#/topics', '#/pramans', '#/pramans?granth=3', '#/gallery']) {
        expect(GRoute.parse(h).key, isNot(contains('|')), reason: h);
      }
      expect(GRoute.parse('#/granths').key, isNot(contains('|')));
    });

    test('the Granth tab is active on every folder level', () {
      for (final h in ['#/granths', '#/granths?r=hindu', '#/granths?r=hindu&g=puran', '#/granths?all=1']) {
        final nav = AppNav()..route = GRoute.parse(h);
        expect(nav.isActive(Panel.granths), isTrue, reason: h);
        expect(nav.isActive(Panel.topics), isFalse, reason: h);
      }
    });
  });
}
