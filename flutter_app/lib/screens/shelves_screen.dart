import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/structure.dart';
import '../services/catalog_store.dart';
import '../services/storage.dart';
import '../state/ui_prefs.dart';
import '../services/shelves.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/group_icon.dart';
import '../widgets/religion_symbol.dart';
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
        emptyNote: Shelves.structure.other.comingSoon,
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
      emptyNote: leaf.comingSoon,
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

/// The folder grid uses the same persisted 1×1 / 2×2 / 3×3 choice as the granth cards
/// (`Store.kGranthCols`; until the user chooses: the admin's `ui.grid`, else 2×2), so one switch
/// lays out the whole Granth tab.
int folderCols() => UiPrefs.I.granthCols;

/// The size of a folder's picture for a column count: big and clear in 2×2.
double folderPicSize(int cols) => switch (cols) {
      1 => 60,
      2 => 84,
      _ => 58,
    };

/// One folder card: the normal card (so every card style / theme applies) with a picture,
/// the folder name and its real counts. 1×1 is the wide row (picture, text, ›); 2×2 and 3×3
/// are tiles (picture on top, name and counts centred under it). Names wrap to two lines and
/// then end in "…", so a long Hindi name never overflows at any width or text size.
class FolderRow extends StatelessWidget {
  const FolderRow({super.key, required this.leading, required this.title, required this.subtitle, required this.onTap, this.dim = false, this.cols = 1});

  /// Builds the picture for the size this layout wants ([folderPicSize]).
  final Widget Function(double size) leading;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  /// "जल्द आ रहा है" folders are a little paler.
  final bool dim;
  final int cols;

  @override
  Widget build(BuildContext context) {
    final pic = leading(folderPicSize(cols));
    final titleColor = dim ? GColors.muted : GColors.maroon;
    final subColor = dim ? GColors.muted : GColors.saffronDark;
    if (cols == 1) {
      return GCard(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        onTap: onTap,
        child: Row(children: [
          pic,
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(title, maxLines: 2, overflow: TextOverflow.ellipsis, style: GText.script(size: 19, color: titleColor)),
              const SizedBox(height: 3),
              Text(subtitle, maxLines: 2, overflow: TextOverflow.ellipsis, style: GText.sans(size: 13, weight: FontWeight.w600, color: subColor)),
            ]),
          ),
          const SizedBox(width: 8),
          const GIcon('chevron-right', size: 20, color: GColors.muted),
        ]),
      );
    }
    final small = cols >= 3;
    return GCard(
      padding: EdgeInsets.symmetric(horizontal: small ? 6 : 10, vertical: small ? 10 : 14),
      onTap: onTap,
      child: SizedBox(
        width: double.infinity,
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          pic,
          SizedBox(height: small ? 8 : 10),
          Text(title,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GText.script(size: small ? 14.5 : 18, color: titleColor, height: 1.3)),
          const SizedBox(height: 2),
          // 3×3 is narrow: "37 ग्रंथ • 551 प्रमाण" becomes two short lines
          Text(small ? subtitle.replaceAll(' • ', '\n') : subtitle,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: GText.sans(size: small ? 11 : 12.5, weight: FontWeight.w600, color: subColor, height: 1.3)),
        ]),
      ),
    );
  }
}

/// The [FolderRow]s as the app's grid (1/2/3 columns, [gridSliver]) with the staggered entry
/// + scale-pop. Keyed by the column count so switching replays the entry like the granth cards.
Widget folderSliver({required List<Widget> rows, required List<String> ids, required int cols, required double dx, required PopLedger ledger}) {
  return KeyedSubtree(
    key: ValueKey('folders-$cols'),
    child: gridSliver(
      count: rows.length,
      cols: cols,
      gap: cols == 1 ? 12 : (cols == 2 ? 10 : 8),
      item: (context, i) {
        final id = 'f$cols:${ids[i]}';
        return Entry(
          index: i + 1,
          dx: dx,
          ledger: ledger,
          id: id,
          child: CardPop(ledger: ledger, id: id, group: 'folders-$cols', index: i + 1, child: rows[i]),
        );
      },
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
    final cols = folderCols();
    final rows = <Widget>[];
    final ids = <String>[];
    for (final r in index.structure.religions) {
      if (!r.visible) continue; // the admin hid the tile (its granths stay reachable elsewhere)
      final list = index.inReligion(r.id);
      ids.add(r.id);
      rows.add(FolderRow(
        cols: cols,
        leading: (size) => ReligionSymbol(r.icon, tone: _tone(r.tone), size: size),
        title: r.title,
        subtitle: list.isEmpty ? (r.comingSoon.isNotEmpty ? r.comingSoon : 'जल्द आ रहा है') : _count(list.length, ShelfIndex.pramans(list)),
        dim: list.isEmpty,
        onTap: () => AppNav.I.go(GRoute.folderHash(religion: r.id)),
      ));
    }
    final other = index.other;
    if (other.isNotEmpty || index.structure.other.comingSoon.isNotEmpty) {
      ids.add(kOtherId);
      rows.add(FolderRow(
        cols: cols,
        leading: (size) => ReligionSymbol(index.structure.other.icon, tone: Tone.gold, size: size),
        title: index.structure.other.title,
        subtitle: other.isEmpty ? index.structure.other.comingSoon : _count(other.length, ShelfIndex.pramans(other)),
        dim: other.isEmpty,
        onTap: () => AppNav.I.go(GRoute.folderHash(religion: kOtherId)),
      ));
    }
    if (all.isNotEmpty) {
      ids.add('all');
      rows.add(FolderRow(
        cols: cols,
        leading: (size) => IconBox(tone: Tone.saffron, icon: 'library', size: size, radius: size * 0.26, iconSize: size * 0.5),
        title: 'सभी ग्रंथ',
        subtitle: '${all.length} ग्रंथ • एक सूची में',
        onTap: () => AppNav.I.go('#/granths?all=1'),
      ));
    }
    return SliverMainAxisGroup(slivers: [
      folderSliver(rows: rows, ids: ids, cols: cols, dx: dx, ledger: ledger),
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
    final cols = folderCols();
    final rows = <Widget>[];
    final ids = <String>[];
    for (final c in children) {
      final list = group == null ? index.inGroup(religion.id, c.id) : index.inLeaf(leafKey(religion.id, group.id, c.id));
      ids.add(c.id);
      rows.add(FolderRow(
        cols: cols,
        leading: (size) => GroupIcon(c.icon, size: size),
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
            leading: group == null ? ReligionSymbol(religion.icon, tone: _tone(religion.tone), size: 44) : GroupIcon(group.icon, size: 44),
            tools: Align(
              alignment: Alignment.centerLeft,
              child: GridSwitch(options: const [1, 2, 3], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kGranthCols, v)),
            ),
            title: group?.title ?? religion.title,
            subtitle: group == null ? _count(inside.length, ShelfIndex.pramans(inside)) : '${religion.title} • ${_count(inside.length, ShelfIndex.pramans(inside))}',
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      folderSliver(rows: rows, ids: ids, cols: cols, dx: dx, ledger: _ledger),
      if (rows.isEmpty)
        SliverToBoxAdapter(
          child: EmptyState(
            title: 'जल्द आ रहा है',
            body: (group?.comingSoon.isNotEmpty ?? false)
                ? group!.comingSoon
                : (group == null && religion.comingSoon.isNotEmpty ? religion.comingSoon : '${group?.title ?? religion.title} के ग्रंथ अभी उपलब्ध नहीं हैं।'),
          ),
        ),
    ]);
  }
}
