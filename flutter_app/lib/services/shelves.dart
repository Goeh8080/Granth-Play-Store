import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import '../models/structure.dart';

/// Holds the bundled folder structure and the index built from the current catalog.
///
/// The structure loads once at start (a few KB from the APK — no network, so it works
/// offline). [indexFor] resolves the catalog against it once and keeps the result until
/// the catalog list itself changes, so opening a folder is a map lookup.
class Shelves {
  Shelves._();

  static const String asset = 'assets/structure/structure.json';
  static Structure structure = Structure.empty;

  static Future<void> load() async {
    try {
      structure = Structure.parse(await rootBundle.loadString(asset));
    } catch (e) {
      // Never block the app: without the file every granth simply lands in अन्य.
      debugPrint('structure: $e');
      structure = Structure.empty;
    }
    _src = null;
  }

  /// Tests / tools: use a structure directly.
  @visibleForTesting
  static void use(Structure s) {
    structure = s;
    _src = null;
  }

  static List<Granth>? _src;
  static int _srcLen = -1;
  static Structure? _srcStructure;
  static ShelfIndex? _idx;
  static int builds = 0;

  /// The catalog's granth list is replaced (not edited) on every sync, so identity + length
  /// tells whether the cached index is still right.
  static ShelfIndex indexFor(List<Granth> granths) {
    final cached = _idx;
    if (cached != null && identical(_src, granths) && _srcLen == granths.length && identical(_srcStructure, structure)) return cached;
    builds++;
    _src = granths;
    _srcLen = granths.length;
    _srcStructure = structure;
    return _idx = ShelfIndex.build(structure, granths);
  }
}
