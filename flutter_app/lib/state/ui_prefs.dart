import 'package:flutter/foundation.dart';

import '../services/pdf_builder.dart';
import '../services/storage.dart';

/// Card looks from the hidden "कार्ड स्टाइल" setting (`granth-look`).
const cardLooks = <(String, String)>[
  ('combo', 'Bento + Clay'),
  ('classic', 'सादा'),
  ('glass', 'Glassmorphism'),
  ('neu', 'Neumorphism'),
  ('clay', 'Claymorphism'),
  ('material', 'Material'),
  ('flat', 'Flat'),
  ('bento', 'Bento'),
];

/// Persisted UI preferences (same localStorage keys as the web app).
class UiPrefs extends ChangeNotifier {
  UiPrefs._();
  static final UiPrefs I = UiPrefs._();

  String get look => (Store.I.ready ? Store.I.getString(Store.kLook) : null) ?? 'classic';
  set look(String v) {
    Store.I.setString(Store.kLook, v);
    notifyListeners();
  }

  int cols(String key, {required List<int> allowed, required int fallback}) {
    if (!Store.I.ready) return fallback;
    final n = Store.I.getInt(key);
    return n != null && allowed.contains(n) ? n : fallback;
  }

  void setCols(String key, int v) {
    Store.I.setString(key, '$v');
    notifyListeners();
  }

  int get uiCols => cols(Store.kUiCols, allowed: const [1, 2], fallback: 2);

  /// `tg()` — the global layout switch in settings.
  void setLayout(int v) {
    for (final k in [Store.kUiCols, Store.kTopicCols, Store.kGranthCols, Store.kPramanCols, Store.kGalleryCols]) {
      Store.I.setString(k, '$v');
    }
    notifyListeners();
  }

  PdfStyle get pdfStyle => pdfStyleFrom(Store.I.ready ? Store.I.getString(Store.kPdfStyle) : null);
  set pdfStyle(PdfStyle s) {
    Store.I.setString(Store.kPdfStyle, pdfStyleId(s));
    notifyListeners();
  }
}
