import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/structure.dart';
import '../services/catalog_store.dart';
import '../services/shelves.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/group_icon.dart';
import '../widgets/live_panel.dart';
import '../widgets/panel.dart';
import '../widgets/pop.dart';
import 'granths_screen.dart';

/// Round 10 — the folder levels of the Granth tab (omma-style structure, built natively):
///
///   religions  `#/granths`                       → [GranthsPanel] with the religion folders
///   religion   `#/granths?r=hindu`               → its groups (वेद, गीता, पुराण …)
///   group      `#/granths?r=hindu&g=puran`       → the granths in it ([GranthCard]s)
///   sub-group  `#/granths?r=hindu&g=ved&s=rigved`
///   अन्य       `#/granths?r=other`               → granths the structure file does not place
///   all        `#/granths?all=1`                 → the old flat list of every granth
///
/// A group that holds no granth is hidden. Every level keeps its own scroll place
/// (`Places.keyFor`) and the leaf lists are the normal granth list, so a card opens the
/// normal granth screen with its PDF buttons.
class ShelvesPanel extends StatelessWidget {
  const ShelvesPanel({super.key, required this.route});
  final GRoute route;

  @override
  Widget build(BuildContext context) {
    final r = route;
    if (r.flat) return const GranthsPanel();
    if (r.religionId == null) {
      return GranthsPanel(placeKey: Places.keyFor(r)!, idle: (context, dx, ledger) => _ReligionFolders(dx: dx, ledger: ledger));
    }
    if (r.religionId == kOtherId) {
      return GranthsPanel(
        placeKey: Places.keyFor(r)!,
        scope: const ShelfScope.other(),
        title: Shelves.structure.other.title,
        subtitle: 'बाकी सभी ग्रंथ',
        leading: const GroupIcon('misc', size: 44),
      );
    }
    final religion = Shelves.structure.religion(r.religionId!);
    if (religion == null) return const _Missing();
    if (r.groupId == null) return _FolderScreen(key: ValueKey('religion-${religion.id}'), religion: religion);
    final group = religion.groups.where((g) => g.id == r.groupId).firstOrNull;
    if (group == null) return const _Missing();
    if (group.hasSubgroups && r.subId == null) return _FolderScreen(key: ValueKey('group-${religion.id}-${group.id}'), religion: religion, group: group);
    final leaf = group.hasSubgroups ? group.subgroups.where((s) => s.id == r.subId).firstOrNull : group;
    if (leaf == null) return const _Missing();
    return GranthsPanel(
      placeKey: Places.keyFor(r)!,
      scope: ShelfScope(religion.id, group.id, group.hasSubgroups ? leaf.id : null),
      title: leaf.title,
      subtitle: group.hasSubgroups ? '${religion.title} • ${group.title}' : religion.title,
      leading: GroupIcon(leaf.icon, size: 44),
    );
  }
}

/// A link to a folder that does not exist (old bookmark, edited structure): say so, with a way back.
class _Missing extends StatelessWidget {
  const _Missing();
  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
        child: EmptyState(title: 'यह फ़ोल्डर नहीं मिला', actionLabel: 'सभी फ़ोल्डर', onAction: () => AppNav.I.go('#/granths')),
      );
}

Tone _tone(String t) => switch (t) {
      'saffron' => Tone.saffron,
      'gold' => Tone.gold,
      _ => Tone.maroon,
    };

String _count(int granths, int pramans) => pramans > 0 ? '$granths ग्रंथ • $pramans प्रमाण' : '$granths ग्रंथ';

/// One folder row: the normal card (so every card style / theme applies) with an icon, the
/// folder name and its real counts.
class FolderRow extends StatelessWidget {
  const FolderRow({super.key, required this.leading, required this.title, required this.subtitle, required this.onTap, this.dim = false});
  final Widget leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// "जल्द आ रहा है" folders are a little paler.
  final bool dim;

  @override
  Widget build(BuildContext context) => GCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(children: [
          leading,
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, style: GText.script(size: 19, color: dim ? GColors.muted : GColors.maroon)),
              const SizedBox(height: 3),
              Text(subtitle, style: GText.sans(size: 13, weight: FontWeight.w600, color: dim ? GColors.muted : GColors.saffronDark)),
            ]),
          ),
          const SizedBox(width: 8),
          const GIcon('chevron-right', size: 20, color: GColors.muted),
        ]),
      );
}

/// A list of [FolderRow]s with the app's staggered entry + scale-pop.
Widget folderSliver({required List<Widget> rows, required List<String> ids, required double dx, required PopLedger ledger}) {
  return SliverList.separated(
    itemCount: rows.length,
    separatorBuilder: (_, _) => const SizedBox(height: 12),
    itemBuilder: (context, i) => Entry(
      index: i + 1,
      dx: dx,
      ledger: ledger,
      id: 'f:${ids[i]}',
      child: CardPop(ledger: ledger, id: 'f:${ids[i]}', group: 'folders', index: i + 1, child: rows[i]),
    ),
  );
}

/// The religion folders (+ अन्य, + "सभी ग्रंथ") under the Granth tab's search box.
class _ReligionFolders extends StatelessWidget {
  const _ReligionFolders({required this.dx, required this.ledger});
  final double dx;
  final PopLedger ledger;

  @override
  Widget build(BuildContext context) {
    final all = CatalogStore.I.granths;
    // Nothing synced yet: say so once, instead of six empty folders.
    if (all.isEmpty) return const SliverToBoxAdapter(child: EmptyState(title: 'कोई ग्रंथ नहीं', body: 'सिंक के बाद पवित्र ग्रंथ यहाँ खुलेंगे।'));
    final index = Shelves.indexFor(all);
    final rows = <Widget>[];
    final ids = <String>[];
    for (final r in index.structure.religions) {
      final list = index.inReligion(r.id);
      ids.add(r.id);
      rows.add(FolderRow(
        leading: IconBox(tone: _tone(r.tone), icon: r.icon, size: 52, radius: 12, iconSize: 26),
        title: r.title,
        subtitle: list.isEmpty ? 'जल्द आ रहा है' : _count(list.length, ShelfIndex.pramans(list)),
        dim: list.isEmpty,
        onTap: () => AppNav.I.go(GRoute.folderHash(religion: r.id)),
      ));
    }
    final other = index.other;
    if (other.isNotEmpty) {
      ids.add(kOtherId);
      rows.add(FolderRow(
        leading: IconBox(tone: Tone.gold, icon: 'folder-open', size: 52, radius: 12, iconSize: 26),
        title: index.structure.other.title,
        subtitle: _count(other.length, ShelfIndex.pramans(other)),
        onTap: () => AppNav.I.go(GRoute.folderHash(religion: kOtherId)),
      ));
    }
    if (all.isNotEmpty) {
      ids.add('all');
      rows.add(FolderRow(
        leading: const IconBox(tone: Tone.saffron, icon: 'library', size: 52, radius: 12, iconSize: 26),
        title: 'सभी ग्रंथ',
        subtitle: '${all.length} ग्रंथ • एक सूची में',
        onTap: () => AppNav.I.go('#/granths?all=1'),
      ));
    }
    return SliverMainAxisGroup(slivers: [
      folderSliver(rows: rows, ids: ids, dx: dx, ledger: ledger),
    ]);
  }
}

/// A religion (its groups) or a group with sub-groups (वेद, 6 शास्त्र): folders only.
class _FolderScreen extends StatefulWidget {
  const _FolderScreen({super.key, required this.religion, this.group});
  final ShelfReligion religion;
  final ShelfGroup? group;
  @override
  State<_FolderScreen> createState() => _FolderScreenState();
}

class _FolderScreenState extends State<_FolderScreen> with LivePanel {
  final _ledger = PopLedger();

  @override
  Widget build(BuildContext context) {
    final religion = widget.religion;
    final group = widget.group;
    final index = Shelves.indexFor(CatalogStore.I.granths);
    final dx = panelDx();
    final List<Granth> inside = group == null ? index.inReligion(religion.id) : index.inGroup(religion.id, group.id);
    final children = group == null ? index.visibleGroups(religion.id) : index.visibleSubgroups(religion.id, group.id);
    final rows = <Widget>[];
    final ids = <String>[];
    for (final c in children) {
      final list = group == null ? index.inGroup(religion.id, c.id) : index.inLeaf(leafKey(religion.id, group.id, c.id));
      ids.add(c.id);
      rows.add(FolderRow(
        leading: GroupIcon(c.icon, size: 56),
        title: c.title,
        subtitle: _count(list.length, ShelfIndex.pramans(list)),
        onTap: () => AppNav.I.go(GRoute.folderHash(religion: religion.id, group: group?.id ?? c.id, sub: group == null ? null : c.id)),
      ));
    }
    return SliverMainAxisGroup(slivers: [
      StickyHeader(
        child: Entry(
          index: 0,
          dx: dx,
          child: PageHeader(
            tone: _tone(religion.tone),
            icon: religion.icon,
            leading: group == null ? null : GroupIcon(group.icon, size: 44),
            title: group?.title ?? religion.title,
            subtitle: group == null ? _count(inside.length, ShelfIndex.pramans(inside)) : '${religion.title} • ${_count(inside.length, ShelfIndex.pramans(inside))}',
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      folderSliver(rows: rows, ids: ids, dx: dx, ledger: _ledger),
      if (rows.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            title: 'जल्द आ रहा है',
            body: '${group?.title ?? religion.title} के ग्रंथ अभी उपलब्ध नहीं हैं।',
          ),
        ),
    ]);
  }
}
