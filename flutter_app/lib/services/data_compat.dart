import 'package:flutter/foundation.dart';

import 'storage.dart';

/// Layout version of the data this app keeps on the phone (settings, `catalog.json`,
/// `gallery.json`, `folders.json`, saved pictures, PDFs). It is NOT the app's version code:
/// it only changes when the layout of the data changes, so any app version (any version
/// code, older or newer) can read what another one left behind.
///
/// Rules (round 7):
///  * nothing the user has is ever deleted by a migration; files are only read and, where a
///    value needs another shape, re-written in place (settings) — pictures / PDFs / gallery
///    rows are never touched;
///  * data without a version (everything written by the first releases) is version 0;
///  * data with a HIGHER version (written by a newer app, then this older one installed) is
///    read as far as it can be understood, left exactly as it is, and the version is not
///    lowered — so the newer app finds it intact again;
///  * a migration that fails is skipped (the app still opens); it is tried again next start.
const int kDataSchema = 1;

class MigrationReport {
  MigrationReport(this.from, this.to, this.ran, this.newerData);

  /// Version found on the phone (0 = unversioned / first releases).
  final int from;

  /// Version after this run.
  final int to;
  final List<String> ran;

  /// The data was written by a newer layout: nothing was changed.
  final bool newerData;

  @override
  String toString() => 'MigrationReport(from=$from to=$to ran=$ran newer=$newerData)';
}

class DataCompat {
  DataCompat._();

  /// Settings that are stored as text (kept identical to the original web app's keys).
  static const List<String> textKeys = [
    Store.kTopicCols, Store.kGranthCols, Store.kPramanCols, Store.kGalleryCols, Store.kUiCols,
    Store.kPdfStyle, Store.kLook, Store.kTextSize, Store.kWifiOnly, Store.kAutoSync, Store.kKeepAwake,
    Store.kHash, Store.kOfflineIds, Store.kDevice, Store.kNotifAsked, Store.kNotifHint,
    Store.kAnimations,
  ];

  /// Keys older builds wrote that nothing reads any more (round 9 removed the "सारे ग्रंथ ऑफलाइन"
  /// card). They are left in place and ignored: harmless, and an older build over this data still works.
  static const List<String> retiredKeys = ['granth-offline-ready', 'granth-offline-card-seen'];

  /// Each step takes the layout from version `n` to `n + 1`. Idempotent: running one twice
  /// is the same as once.
  static final List<Future<void> Function()> _steps = [
    _v0to1,
  ];

  static MigrationReport? last;

  /// Runs the pending migrations. Never throws.
  static Future<MigrationReport> migrate() async {
    var from = 0;
    try {
      from = Store.I.getInt(Store.kSchema) ?? 0;
      if (from < 0) from = 0;
    } catch (_) {}
    final ran = <String>[];
    if (from > kDataSchema) {
      return last = MigrationReport(from, from, ran, true);
    }
    var at = from;
    while (at < kDataSchema) {
      try {
        await _steps[at]();
        ran.add('v$at→v${at + 1}');
        at++;
      } catch (e) {
        debugPrint('DataCompat: step v$at failed, will retry next start: $e');
        break;
      }
    }
    if (at != from) {
      try {
        await Store.I.setString(Store.kSchema, '$at');
      } catch (_) {}
    }
    return last = MigrationReport(from, at, ran, false);
  }

  /// v0 → v1: the settings the app reads as text are text. A restored backup (or an older /
  /// newer app) can hold a number or a flag under one of them; it is converted, keeping its
  /// meaning (`true` → `1`). Keys this version doesn't know are left alone.
  static Future<void> _v0to1() async {
    for (final k in textKeys) {
      final v = Store.I.getRaw(k);
      if (v == null || v is String) continue;
      final text = switch (v) {
        bool b => b ? '1' : '0',
        num n => n is int ? '$n' : (n == n.truncate() ? '${n.truncate()}' : '$n'),
        _ => '$v',
      };
      await Store.I.setString(k, text);
    }
  }
}
