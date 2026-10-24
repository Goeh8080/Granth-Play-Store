import 'package:flutter/foundation.dart';

import '../services/catalog_store.dart';
import '../services/native_bridge.dart';
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
///
/// Like the original (`useState` first, then `localStorage.setItem`), a tap changes the
/// value on screen at once: reads come from memory, the file write follows.
class UiPrefs extends ChangeNotifier {
  UiPrefs._();
  static final UiPrefs I = UiPrefs._();

  String get look => Store.I.getString(Store.kLook) ?? 'classic';
  set look(String v) {
    Store.I.setString(Store.kLook, v);
    notifyListeners();
  }

  int cols(String key, {required List<int> allowed, required int fallback}) {
    final n = Store.I.getInt(key);
    return n != null && allowed.contains(n) ? n : fallback;
  }

  void setCols(String key, int v) {
    if (cols(key, allowed: const [1, 2, 3], fallback: -1) == v) return;
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

  PdfStyle get pdfStyle => pdfStyleFrom(Store.I.getString(Store.kPdfStyle));
  set pdfStyle(PdfStyle s) {
    Store.I.setString(Store.kPdfStyle, pdfStyleId(s));
    notifyListeners();
  }

  // ---- Extra settings (added in round 5; the web app has none of these) ----

  /// Reading text size: small / normal / large.
  String get textSize => switch (Store.I.getString(Store.kTextSize)) { 'small' => 'small', 'large' => 'large', _ => 'normal' };
  set textSize(String v) {
    Store.I.setString(Store.kTextSize, v);
    textFactor.value = _factor(v);
    notifyListeners();
  }

  static double _factor(String v) => switch (v) { 'small' => 0.9, 'large' => 1.15, _ => 1.0 };

  /// Multiplier on the phone's own text size; only the app's text scaler listens to it.
  late final ValueNotifier<double> textFactor = ValueNotifier(_factor(textSize));

  /// Re-read the stored values (app start, reset). [start]: send keep-screen-on to
  /// the window (at start only when it is on — the window starts without it).
  void refresh({bool start = false}) {
    textFactor.value = _factor(textSize);
    if (!start || keepAwake) NativeBridge.keepScreenOn(keepAwake);
    notifyListeners();
  }

  bool _flag(String k, bool def) => switch (Store.I.getString(k)) { '1' || 'true' => true, '0' || 'false' => false, _ => def };

  /// Picture download for offline use only on WiFi (default off: download on any network).
  bool get wifiOnly => _flag(Store.kWifiOnly, false);
  set wifiOnly(bool v) {
    Store.I.setString(Store.kWifiOnly, v ? '1' : '0');
    notifyListeners();
    // Turned off while on mobile data: the waiting download can go now.
    final s = CatalogStore.I;
    if (!v && s.hasData && s.savedPages < s.allPages) s.savePages();
  }

  /// The 2-minute / on-resume refresh (default on).
  bool get autoSync => _flag(Store.kAutoSync, true);
  set autoSync(bool v) {
    Store.I.setString(Store.kAutoSync, v ? '1' : '0');
    notifyListeners();
  }

  /// Keep the screen on while the app is open (default off).
  bool get keepAwake => _flag(Store.kKeepAwake, false);
  set keepAwake(bool v) {
    Store.I.setString(Store.kKeepAwake, v ? '1' : '0');
    NativeBridge.keepScreenOn(v);
    notifyListeners();
  }

  /// Settings → "एनिमेशन" चालू / कम (default चालू). "कम" switches off the decorative entrance
  /// animations added in round 8 (card scale-pop, blur-focus, inner stagger); the dashboard
  /// count-up, the menu, the tilt on opening a granth and the splash are not touched.
  bool get animations => _flag(Store.kAnimations, true);
  set animations(bool v) {
    Store.I.setString(Store.kAnimations, v ? '1' : '0');
    notifyListeners();
  }

  /// Settings → "सेटिंग रीसेट करें": every setting back to its default. Downloaded granths,
  /// pages, gallery and PDFs are never touched.
  static const settingKeys = [
    Store.kLook, Store.kUiCols, Store.kTopicCols, Store.kGranthCols, Store.kPramanCols, Store.kGalleryCols, //
    Store.kPdfStyle, Store.kTextSize, Store.kWifiOnly, Store.kAutoSync, Store.kKeepAwake, Store.kAnimations,
  ];
  Future<void> resetAll() async {
    for (final k in settingKeys) {
      await Store.I.remove(k);
    }
    refresh();
  }
}
