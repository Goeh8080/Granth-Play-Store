import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/api.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/services/data_compat.dart';
import 'package:granthprabandhan/services/gallery_service.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:shared_preferences/shared_preferences.dart';


/// Round 7: data kept on the phone (settings, catalog.json, gallery / folders) reads with any
/// app version, is migrated by layout version (not version code), and is never deleted.
Future<Directory> boot(Map<String, Object> prefs) async {
  SharedPreferences.setMockInitialValues(prefs);
  final p = await SharedPreferences.getInstance();
  final dir = await Directory.systemTemp.createTemp('granth_compat');
  await Store.I.initForTest(p, dir);
  GalleryService.I.debugReset();
  return dir;
}

List<String> tree(Directory d) => d.listSync(recursive: true).whereType<File>().map((f) => '${f.path}:${f.lengthSync()}').toList()..sort();

void main() {
  group('settings', () {
    test('a value of another type reads as text, never throws', () async {
      await boot({Store.kUiCols: 3, Store.kWifiOnly: true, Store.kLook: 'bento', 'granth-from-the-future': 'x'});
      expect(Store.I.getString(Store.kUiCols), '3');
      expect(Store.I.getString(Store.kWifiOnly), 'true');
      expect(Store.I.getString(Store.kLook), 'bento');
      expect(Store.I.getInt(Store.kUiCols), 3);
      expect(Store.I.getInt('missing'), isNull);
    });

    test('unversioned data (first releases) is migrated to the current layout, meaning kept', () async {
      await boot({Store.kUiCols: 3, Store.kWifiOnly: true, Store.kAutoSync: false, Store.kLook: 'flat', 'granth-from-the-future': 'x', 'zz-list': <String>['a', 'b']});
      final r = await DataCompat.migrate();
      expect(r.from, 0);
      expect(r.to, kDataSchema);
      expect(r.ran, isNotEmpty);
      expect(Store.I.getString(Store.kUiCols), '3');
      expect(Store.I.getString(Store.kWifiOnly), '1');
      expect(Store.I.getString(Store.kAutoSync), '0');
      expect(Store.I.getString(Store.kLook), 'flat', reason: 'text stays as it was');
      expect(Store.I.getString('granth-from-the-future'), 'x', reason: 'unknown keys are left alone');
      expect(Store.I.getRaw('zz-list'), ['a', 'b']);
      expect(Store.I.getInt(Store.kSchema), kDataSchema);
    });

    test('running it again changes nothing (idempotent)', () async {
      await boot({Store.kUiCols: 2});
      await DataCompat.migrate();
      final before = {for (final k in Store.I.keys) k: Store.I.getRaw(k)};
      final r = await DataCompat.migrate();
      expect(r.ran, isEmpty);
      expect(r.from, kDataSchema);
      expect({for (final k in Store.I.keys) k: Store.I.getRaw(k)}, before);
    });

    test('data from a NEWER layout is read but left exactly as it is; the version is not lowered', () async {
      await boot({Store.kSchema: '99', Store.kUiCols: 3, Store.kWifiOnly: true, 'granth-new-thing': 'y'});
      final r = await DataCompat.migrate();
      expect(r.newerData, isTrue);
      expect(r.ran, isEmpty);
      expect(Store.I.getString(Store.kSchema), '99');
      expect(Store.I.getRaw(Store.kWifiOnly), true, reason: 'untouched');
      expect(Store.I.getRaw(Store.kUiCols), 3);
      expect(Store.I.getString('granth-new-thing'), 'y');
      // Still readable.
      expect(Store.I.getString(Store.kWifiOnly), 'true');
    });

    test('a schema stored as a number or junk is understood', () async {
      await boot({Store.kSchema: 1});
      expect((await DataCompat.migrate()).from, 1);
      await boot({Store.kSchema: 'garbage'});
      expect((await DataCompat.migrate()).from, 0);
    });

    test('a late prefs file (slow start) never lowers a newer layout version', () async {
      SharedPreferences.setMockInitialValues({Store.kSchema: '7'});
      final late = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('granth_compat');
      await Store.I.initForTest(null, dir);
      await Store.I.setString(Store.kSchema, '1');
      Store.I.debugAdoptPrefs(late);
      expect(late.getString(Store.kSchema), '7');
    });
  });

  group('catalog.json', () {
    final base = {
      'topics': [
        {'id': '1', 'title': 'विषय'}
      ],
      'granths': [
        {'id': '9', 'title': 'ग्रंथ', 'unknownNewField': {'a': 1}}
      ],
      'pramans': [
        {'id': '5', 'title': 'पेज 3', 'granth_id': '9', 'topic_id': '1'}
      ],
    };

    test('older / newer / odd files all load', () {
      expect(loadCatalogText(jsonEncode({...base, 'syncedAt': 1700000000000}))!.syncedAt, 1700000000000);
      expect(loadCatalogText(jsonEncode({...base, 'syncedAt': '1700000000000'}))!.syncedAt, 1700000000000, reason: 'number as text');
      expect(loadCatalogText(jsonEncode({...base, 'syncedAt': 'soon'}))!.syncedAt, isNull);
      expect(loadCatalogText(jsonEncode(base))!.granths.single.raw['unknownNewField'], {'a': 1}, reason: 'extra fields survive');
      expect(loadCatalogText(jsonEncode({...base, 'schema': 5, 'v': 'x', 'extra': []}))!.pramans, hasLength(1));
      expect(loadCatalogText('\uFEFF${jsonEncode(base)}')!.topics, hasLength(1), reason: 'BOM');
      expect(loadCatalogText(jsonEncode({'topics': [], 'granths': [], 'pramans': []}))!.topics, isEmpty);
      expect(loadCatalogText(jsonEncode({'topics': base['topics']}))!.granths, isEmpty, reason: 'an old file with only topics');
      expect(loadCatalogText(jsonEncode({'topics': [1, 'x', null, base['topics']![0]]}))!.topics, hasLength(1), reason: 'junk rows skipped');
      expect(loadCatalogText(jsonEncode([1, 2])), isNull);
    });

    test('a file that cannot be read is set aside, never deleted, and the app still starts', () async {
      final dir = await boot({});
      File('${dir.path}/catalog.json').writeAsStringSync('{"format":"v9","data":"???"}');
      final s = CatalogStore(api: _Off(), connectivity: const Stream.empty());
      CatalogStore.I = s;
      await s.boot();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(s.hasData, isFalse);
      expect(File('${dir.path}/catalog.json').existsSync(), isTrue, reason: 'not deleted');
      expect(File('${dir.path}/catalog.json.unreadable').readAsStringSync(), contains('v9'));
      s.dispose();
    });

    test('a readable file from another version boots the lists', () async {
      final dir = await boot({});
      File('${dir.path}/catalog.json').writeAsStringSync(jsonEncode({...base, 'syncedAt': '1', 'zzz': 1}));
      final s = CatalogStore(api: _Off(), connectivity: const Stream.empty());
      CatalogStore.I = s;
      await s.boot();
      expect(s.hasData, isTrue);
      expect(s.granths.single.title, 'ग्रंथ');
      s.dispose();
    });
  });

  group('gallery + folders', () {
    test('rows that cannot be shown now stay in the index; unknown fields are written back; only the user removes', () async {
      final dir = await boot({});
      final have = File('${dir.path}/Granth/a.pdf')..writeAsStringSync('pdf');
      final moved = File('${dir.path}/Granth/moved.pdf')..writeAsStringSync('pdf');
      File('${dir.path}/gallery.json').writeAsStringSync(jsonEncode([
        {'id': 'a', 'kind': 'pdf', 'title': 'A', 'createdAt': 5, 'size': 3, 'fileName': 'a.pdf', 'filePath': have.path, 'newFeature': {'star': true}},
        {'id': 'gone', 'kind': 'pdf', 'title': 'file missing now', 'createdAt': 4, 'size': 3, 'fileName': 'gone.pdf', 'filePath': '/sdcard/missing/gone.pdf', 'tag': 'keep me'},
        {'id': 'm', 'kind': 'pdf', 'title': 'path changed', 'createdAt': 3, 'size': 3, 'fileName': 'moved.pdf', 'filePath': '/data/user/9/old/granth/Granth/moved.pdf'},
        'junk row',
        {'weird': 'a row from another version'},
        {'id': 'n', 'kind': 'hologram', 'title': 'new kind', 'createdAt': 'tomorrow', 'filePath': 7},
      ]));
      File('${dir.path}/folders.json').writeAsStringSync(jsonEncode([
        {'id': 'f1', 'name': 'पहला', 'color': 'red'},
        {'name': 'no id'},
        42,
      ]));
      final g = GalleryService.I;
      final shown = await g.items();
      expect(shown.map((e) => e.id), containsAll(['a', 'm']));
      expect(shown.firstWhere((e) => e.id == 'm').filePath, moved.path, reason: 'found again by name in this install');
      expect(shown.map((e) => e.id), isNot(contains('gone')));
      await g.folders();
      // A change (new item + a move) re-writes the index files.
      await g.setFolder(shown.firstWhere((e) => e.id == 'a'), 'f1');
      final out = (jsonDecode(File('${dir.path}/gallery.json').readAsStringSync()) as List).whereType<Map>().toList();
      expect(out.where((m) => m['id'] == 'gone').single['tag'], 'keep me');
      expect(out.where((m) => m['id'] == 'a').single['newFeature'], {'star': true});
      expect(out.where((m) => m['id'] == 'a').single['folderId'], 'f1');
      expect(out.any((m) => m['weird'] != null), isTrue);
      expect(out.any((m) => m['id'] == 'n'), isTrue);
      await g.putFolder(GalleryFolder(id: 'f2', name: 'दूसरा'));
      final fo = (jsonDecode(File('${dir.path}/folders.json').readAsStringSync()) as List).whereType<Map>().toList();
      expect(fo.where((m) => m['id'] == 'f1').single['color'], 'red');
      expect(fo.any((m) => m['name'] == 'no id'), isTrue);
      expect(fo.any((m) => m['id'] == 'f2'), isTrue);
      // The user removes one: only it goes.
      await g.remove('a');
      final after = (jsonDecode(File('${dir.path}/gallery.json').readAsStringSync()) as List).whereType<Map>().toList();
      expect(after.any((m) => m['id'] == 'a'), isFalse);
      expect(after.any((m) => m['id'] == 'gone'), isTrue);
      expect(have.existsSync(), isFalse, reason: 'the user deleted it');
      expect(moved.existsSync(), isTrue);
    });
  });

  test('migration never deletes or rewrites a file', () async {
    final dir = await boot({Store.kUiCols: 3, Store.kWifiOnly: true});
    File('${dir.path}/images/x__y.jpg').writeAsBytesSync(List.filled(100, 1));
    File('${dir.path}/Granth/x.pdf').writeAsBytesSync(List.filled(100, 2));
    File('${dir.path}/catalog.json').writeAsStringSync('{"topics":[]}');
    File('${dir.path}/gallery.json').writeAsStringSync('[]');
    File('${dir.path}/random.dat').writeAsStringSync('from a newer app');
    final before = tree(dir);
    await DataCompat.migrate();
    await DataCompat.migrate();
    expect(tree(dir), before);
  });
}

class _Off extends Api {
  @override
  Future<Catalog> fetchCatalog() => Future<Catalog>.error(StateError('offline'));
}
