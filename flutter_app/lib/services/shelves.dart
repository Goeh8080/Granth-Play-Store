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

  /// The bundled structure, kept so the remote one can be dropped again.
  static Structure bundled = Structure.empty;

  /// Remote config: granth id → leaf key (highest placement priority). Empty = none.
  static Map<String, String> overrides = const {};

  static Future<void> load() async {
    try {
      bundled = structure = Structure.parse(await rootBundle.loadString(asset));
    } catch (e) {
      // Never block the app: without the file every granth simply lands in अन्य.
      debugPrint('structure: $e');
      bundled = structure = Structure.empty;
    }
    overrides = const {};
    _src = null;
  }

  /// Remote config on top of the bundled file (null structure = back to the bundled one).
  static void useRemote(Structure? remote, Map<String, String> ov) {
    structure = remote ?? bundled;
    overrides = ov;
    _src = null;
  }

  /// Tests / tools: use a structure directly.
  @visibleForTesting
  static void use(Structure s) {
    structure = s;
    bundled = s;
    overrides = const {};
    _src = null;
  }

  static List<Granth>? _src;
  static int _srcLen = -1;
  static Structure? _srcStructure;
  static Map<String, String>? _srcOv;
  static ShelfIndex? _idx;
  static int builds = 0;

  /// The catalog's granth list is replaced (not edited) on every sync, so identity + length
  /// tells whether the cached index is still right.
  static ShelfIndex indexFor(List<Granth> granths) {
    final cached = _idx;
    if (cached != null && identical(_src, granths) && _srcLen == granths.length && identical(_srcStructure, structure) && identical(_srcOv, overrides)) return cached;
    builds++;
    _src = granths;
    _srcLen = granths.length;
    _srcStructure = structure;
    _srcOv = overrides;
    return _idx = ShelfIndex.build(structure, granths, overrides: overrides);
  }
}
