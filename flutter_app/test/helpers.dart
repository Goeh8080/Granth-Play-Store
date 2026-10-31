import 'dart:io';

import 'package:granthprabandhan/screens/login_screen.dart';
import 'package:granthprabandhan/services/local_stats.dart';
import 'package:granthprabandhan/models/models.dart';
import 'package:granthprabandhan/services/catalog_store.dart';
import 'package:granthprabandhan/models/structure.dart';
import 'package:granthprabandhan/services/shelves.dart';
import 'package:granthprabandhan/services/storage.dart';
import 'package:granthprabandhan/services/image_size.dart';
import 'package:granthprabandhan/state/places.dart';
import 'package:granthprabandhan/state/router.dart';
import 'package:shared_preferences/shared_preferences.dart';

Catalog sampleCatalog() => Catalog(
      topics: [
        Topic({'id': '1', 'title': 'मृत्यु के बाद क्या', 'description': 'आत्मा का रहस्य', 'position': '2', 'praman_count': '2'}),
        Topic({'id': '2', 'title': 'गीता ज्ञान', 'description': 'श्रीमद्भगवद्गीता', 'position': '1', 'praman_count': '1'}),
      ],
      granths: [
        Granth({'id': '10', 'title': 'श्रीमद्भगवद्गीता', 'author': 'वेद व्यास', 'description': 'गीता', 'position': '1', 'pramanCount': '2', 'granthURL': ''}),
        Granth({'id': '11', 'title': 'कबीर सागर', 'author': 'कबीर साहेब', 'description': '', 'position': '2', 'pramanCount': '1', 'granthURL': 'https://example.org/k.pdf'}),
      ],
      pramans: [
        Praman({'id': '100', 'title': 'अध्याय 15 श्लोक 4', 'description': 'परम पद', 'topic_id': '2', 'granth_id': '10', 'topic_title': 'गीता ज्ञान', 'granth_title': 'श्रीमद्भगवद्गीता', 'is_favorate': '1'}),
        Praman({'id': '101', 'title': 'अध्याय 2 श्लोक 22', 'description': 'वस्त्र', 'topic_id': '1', 'granth_id': '10', 'topic_title': 'मृत्यु के बाद क्या', 'granth_title': 'श्रीमद्भगवद्गीता'}),
        Praman({'id': '102', 'title': 'पेज 10', 'description': '', 'topic_id': '1', 'granth_id': '11', 'topic_title': 'मृत्यु के बाद क्या', 'granth_title': 'कबीर सागर'}),
      ],
      syncedAt: DateTime(2026, 10, 20, 9, 30).millisecondsSinceEpoch,
    );

/// The structure file the APK ships (read from disk: tests have no asset bundle at this point).
Structure shippedStructure() => Structure.parse(File('assets/structure/structure.json').readAsStringSync());

Future<void> setUpApp() async {
  Shelves.use(shippedStructure());
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final dir = await Directory.systemTemp.createTemp('granth_test');
  await Store.I.initForTest(prefs, dir);
  AppNav.I = AppNav();
  Places.forgetLive(); // the search text of a list is remembered in memory for the session
  ImageSizes.I.clear();
  LocalStats.I.debugReset();
  LoginGate.enabled = false;
  final store = CatalogStore(connectivity: const Stream.empty());
  CatalogStore.I = store;
  store.debugSetCatalog(sampleCatalog());
}
