import 'dart:convert';

import 'package:unorm_dart/unorm_dart.dart' as unorm;

import '../services/order.dart' show numericCompare;
import '../services/search.dart' show stableSort;
import 'models.dart';

/// Round 10 — the omma-style folder structure of the Granth tab.
///
/// `assets/structure/structure.json` says which API granth sits in which religion → group
/// (→ sub-group). The API itself is flat (no religion field); this file ships with the app,
/// so the structure works offline. A granth the file does not place goes to **अन्य**
/// automatically, so nothing the API returns can ever disappear.

/// Reserved ids of the automatic fallback folder.
const String kOtherId = 'other';

String _fold(String e) {
  // NFD + dropping the nukta makes क़ुरान == कुरान and फ़ == फ; the rest mirrors search.dart.
  final s = unorm.nfd(e).replaceAll('\u093c', '').replaceAll('\u200c', '').replaceAll('\u200d', '').replaceAll('\u0901', '\u0902');
  return unorm.nfc(s).toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// One folder that holds granths: a leaf group, or a sub-group.
class ShelfGroup {
  const ShelfGroup({
    required this.id,
    required this.title,
    this.icon = 'misc',
    this.granthIds = const [],
    this.keywords = const [],
    this.notKeywords = const [],
    this.subgroups = const [],
    this.visible = true,
    this.comingSoon = '',
  });

  final String id;
  final String title;

  /// Remote config: `false` hides this folder's tile only (never its granths).
  final bool visible;

  /// Remote config: a note shown on the folder (and instead of "no granths" when it is empty).
  final String comingSoon;

  /// Name of a painted group icon (see `GroupIcon`).
  final String icon;
  final List<String> granthIds;
  final List<String> keywords;
  final List<String> notKeywords;
  final List<ShelfGroup> subgroups;

  bool get hasSubgroups => subgroups.isNotEmpty;

  factory ShelfGroup.fromJson(Map<String, dynamic> j) => ShelfGroup(
        id: '${j['id']}',
        title: '${j['title']}',
        icon: '${j['icon'] ?? 'misc'}',
        granthIds: _strings(j['granthIds'] ?? j['forceIds']),
        keywords: _strings(j['keywords']),
        notKeywords: _strings(j['notKeywords']),
        subgroups: [for (final s in (j['subgroups'] as List? ?? const [])) ShelfGroup.fromJson((s as Map).cast<String, dynamic>())],
        visible: j['visible'] != false,
        comingSoon: j['coming_soon'] is String ? (j['coming_soon'] as String).trim() : '',
      );
}

class ShelfReligion {
  const ShelfReligion({required this.id, required this.title, this.tone = 'maroon', this.icon = 'folder-open', this.groups = const [], this.visible = true, this.comingSoon = ''});
  final String id;
  final String title;

  /// Remote config: `false` hides the religion's tile only.
  final bool visible;
  final String comingSoon;

  /// `saffron` / `maroon` / `gold` — resolved to a theme colour by the screen.
  final String tone;
  final String icon;
  final List<ShelfGroup> groups;

  factory ShelfReligion.fromJson(Map<String, dynamic> j) => ShelfReligion(
        id: '${j['id']}',
        title: '${j['title']}',
        tone: '${j['tone'] ?? 'maroon'}',
        icon: '${j['icon'] ?? 'folder-open'}',
        groups: [for (final g in (j['groups'] as List? ?? const [])) ShelfGroup.fromJson((g as Map).cast<String, dynamic>())],
        visible: j['visible'] != false,
        comingSoon: j['coming_soon'] is String ? (j['coming_soon'] as String).trim() : '',
      );
}

List<String> _strings(Object? v) => [for (final e in (v as List? ?? const [])) '$e'];

/// The parsed JSON. Immutable; the file is tiny.
class Structure {
  const Structure({this.religions = const [], this.other = const ShelfGroup(id: kOtherId, title: 'अन्य', icon: 'misc')});

  /// No structure at all: every granth lands in अन्य (used only if the asset cannot be read).
  static const Structure empty = Structure();

  final List<ShelfReligion> religions;
  final ShelfGroup other;

  factory Structure.parse(String source) => Structure.fromMap(jsonDecode(source) as Map<String, dynamic>);

  factory Structure.fromMap(Map<String, dynamic> j) {
    return Structure(
      religions: [for (final r in (j['religions'] as List? ?? const [])) ShelfReligion.fromJson((r as Map).cast<String, dynamic>())],
      other: j['other'] is Map ? ShelfGroup.fromJson((j['other'] as Map).cast<String, dynamic>()) : const ShelfGroup(id: kOtherId, title: 'अन्य', icon: 'misc'),
    );
  }

  ShelfReligion? religion(String id) {
    for (final r in religions) {
      if (r.id == id) return r;
    }
    return null;
  }

  /// Every leaf (a group with no sub-groups, or a sub-group) with its path key.
  Iterable<({String key, ShelfReligion religion, ShelfGroup? parent, ShelfGroup leaf})> leaves() sync* {
    for (final r in religions) {
      for (final g in r.groups) {
        if (g.hasSubgroups) {
          for (final s in g.subgroups) {
            yield (key: leafKey(r.id, g.id, s.id), religion: r, parent: g, leaf: s);
          }
        } else {
          yield (key: leafKey(r.id, g.id), religion: r, parent: null, leaf: g);
        }
      }
    }
  }
}

/// `religion/group` or `religion/group/sub`; the fallback folder is just [kOtherId].
String leafKey(String religion, [String? group, String? sub]) => [religion, ?group, ?sub].join('/');

/// Where one granth was placed.
class Placement {
  const Placement(this.key, this.how);

  /// A [leafKey], or [kOtherId].
  final String key;

  /// `override` (remote config), `id` (listed in the JSON), `keyword`, `forced` (listed under अन्य), `fallback`.
  final String how;
  bool get isOther => key == kOtherId;
}

/// The structure resolved against one catalog: built once per catalog and cached
/// (see `Shelves`), so opening a folder never re-matches titles.
class ShelfIndex {
  ShelfIndex._(this.structure, this.granths, this._byLeaf, this.placements);

  final Structure structure;
  final List<Granth> granths;
  final Map<String, List<Granth>> _byLeaf;
  final Map<String, Placement> placements;

  /// [overrides] (remote config: granth id → leaf key) win over everything else; [hidden] granths
  /// are dropped after placement.
  factory ShelfIndex.build(Structure structure, List<Granth> granths, {Map<String, String> overrides = const {}, Set<String> hidden = const {}}) {
    final leaves = structure.leaves().toList();
    final byId = <String, String>{};
    for (final l in leaves) {
      for (final id in l.leaf.granthIds) {
        byId.putIfAbsent(id, () => l.key);
      }
    }
    final forced = {...structure.other.granthIds};
    final leafKeys = {for (final l in leaves) l.key};
    final folded = {for (final l in leaves) l.key: (kw: [for (final k in l.leaf.keywords) _fold(k)], no: [for (final k in l.leaf.notKeywords) _fold(k)])};
    final buckets = <String, List<Granth>>{};
    final placements = <String, Placement>{};
    for (final g in granths) {
      if (hidden.contains(g.id)) continue;
      Placement p;
      final ov = overrides[g.id];
      if (ov != null && (leafKeys.contains(ov) || ov == kOtherId)) {
        p = Placement(ov, 'override');
      } else if (byId.containsKey(g.id)) {
        p = Placement(byId[g.id]!, 'id');
      } else if (forced.contains(g.id)) {
        p = const Placement(kOtherId, 'forced');
      } else {
        // Title keywords: exactly one group may claim it. Two claimants = ambiguous = अन्य
        // (a wrong shelf is worse than अन्य).
        final t = _fold(g.title);
        final hits = <String>[];
        for (final l in leaves) {
          final f = folded[l.key]!;
          if (f.kw.any((k) => k.isNotEmpty && t.contains(k)) && !f.no.any((k) => k.isNotEmpty && t.contains(k))) hits.add(l.key);
        }
        p = hits.length == 1 ? Placement(hits.first, 'keyword') : const Placement(kOtherId, 'fallback');
      }
      placements[g.id] = p;
      (buckets[p.key] ??= []).add(g);
    }
    for (final list in buckets.values) {
      stableSort<Granth>(list, (a, b) => numericCompare(a.position, b.position));
    }
    return ShelfIndex._(structure, granths, buckets, placements);
  }

  /// Granths directly in one folder (a leaf group / sub-group / अन्य), by API position.
  List<Granth> inLeaf(String key) => _byLeaf[key] ?? const [];
  List<Granth> get other => inLeaf(kOtherId);

  /// Every granth inside a religion, a group (with its sub-groups) or one sub-group.
  List<Granth> inGroup(String religion, String group, [String? sub]) {
    final r = structure.religion(religion);
    final g = r?.groups.where((e) => e.id == group).firstOrNull;
    if (g == null) return const [];
    if (sub != null || !g.hasSubgroups) return inLeaf(leafKey(religion, group, sub));
    return _merge([for (final s in g.subgroups) inLeaf(leafKey(religion, group, s.id))]);
  }

  List<Granth> inReligion(String religion) {
    final r = structure.religion(religion);
    if (r == null) return const [];
    return _merge([for (final g in r.groups) inGroup(religion, g.id)]);
  }

  List<Granth> _merge(List<List<Granth>> parts) {
    final out = [for (final p in parts) ...p];
    stableSort<Granth>(out, (a, b) => numericCompare(a.position, b.position));
    return out;
  }

  /// Groups of a religion that hold at least one granth — empty ones are hidden.
  List<ShelfGroup> visibleGroups(String religion) {
    final r = structure.religion(religion);
    if (r == null) return const [];
    return [for (final g in r.groups) if (g.visible && (inGroup(religion, g.id).isNotEmpty || g.comingSoon.isNotEmpty)) g];
  }

  /// Sub-groups of a group that hold at least one granth.
  List<ShelfGroup> visibleSubgroups(String religion, String group) {
    final g = structure.religion(religion)?.groups.where((e) => e.id == group).firstOrNull;
    if (g == null) return const [];
    return [for (final s in g.subgroups) if (s.visible && (inLeaf(leafKey(religion, group, s.id)).isNotEmpty || s.comingSoon.isNotEmpty)) s];
  }

  /// Number of pramans in a list of granths (API `pramanCount`s).
  static int pramans(Iterable<Granth> list) => list.fold(0, (a, g) => a + g.pramanCount);

  /// Placement summary for docs and tests: leaf key → ids.
  Map<String, List<String>> get idsByLeaf => {for (final e in _byLeaf.entries) e.key: [for (final g in e.value) g.id]};
}

/// Which granths a granth-list screen shows: one group / sub-group, or the अन्य folder.
class ShelfScope {
  const ShelfScope(this.religion, this.group, [this.sub]) : isOther = false;
  const ShelfScope.other() : religion = kOtherId, group = null, sub = null, isOther = true;
  final String religion;
  final String? group;
  final String? sub;
  final bool isOther;

  List<Granth> resolve(ShelfIndex index) => isOther ? index.other : (group == null ? index.inReligion(religion) : index.inGroup(religion, group!, sub));
}
