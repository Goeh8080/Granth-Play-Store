import 'dart:convert';

import '../services/storage.dart';
import 'router.dart';

/// Where each list was left (scroll position + search text), so coming back from an opened
/// item shows exactly what was on screen. Stored in the original's `xh` shape
/// `{y, count, id, anchor}`; `q` (the search text the position belongs to) is an addition
/// that older data simply lacks.
class Places {
  Places._();

  /// Storage key of the list a route shows (null: a single item, nothing to restore).
  static String? keyFor(GRoute r) => switch (r.panel) {
        Panel.dashboard => 'dashboard-place',
        Panel.topics => 'topic-list-place',
        Panel.granths when r.flat => 'granth-list-place',
        Panel.granths when r.religionId == null => 'religions-place',
        Panel.granths when r.groupId == null => 'religion-list:${r.religionId}',
        Panel.granths => 'group-list:${[r.religionId, r.groupId, r.subId].whereType<String>().join(':')}',
        Panel.gallery => 'gallery-list-place',
        Panel.pramans when r.pramanId == null => 'praman-list:${r.granthId ?? ''}:${r.topicId ?? ''}',
        _ => null,
      };

  static Map<String, dynamic>? _read(String key) {
    try {
      final raw = Store.I.getString(key);
      final j = raw == null ? null : jsonDecode(raw);
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }

  static double y(String key) {
    final v = _read(key)?['y'];
    return v is num && v.isFinite && v > 0 ? v.toDouble() : 0;
  }

  /// Search text of the list (what the list was filtered by when it was left).
  static final Map<String, String> _live = {};

  static String query(String key) {
    final m = _live[key];
    if (m != null) return m;
    final q = _read(key)?['q'];
    return q is String ? q : '';
  }

  /// The search box changed (kept so the position saved next belongs to this filter).
  static void setQuery(String key, String q) => _live[key] = q;

  static void save(String key, double y) {
    Store.I.setString(key, jsonEncode({'y': y, 'count': 8, 'id': '', 'anchor': 0, 'q': query(key)}));
  }

  @pragma('vm:prefer-inline')
  static void forgetLive() => _live.clear();
}
