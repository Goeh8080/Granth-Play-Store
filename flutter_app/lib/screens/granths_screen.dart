import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../models/structure.dart';
import '../services/api.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/order.dart';
import '../services/search.dart';
import '../services/shelves.dart';
import '../services/storage.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/live_panel.dart';
import '../widgets/granth_image.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';
import '../widgets/pop.dart';
import '../widgets/pdf_sheets.dart';

/// `Dh` — Granths / Sacred texts and scriptures.
///
/// Round 10: the same panel (header, search, 1×1/2×2/3×3 grid, [GranthCard]s) serves every
/// granth list: the flat list of all granths (the default), one folder ([scope]) and the
/// religions screen ([idle] shows the folders until something is typed in the search box,
/// then the matching granths — search always covers every granth).
class GranthsPanel extends StatefulWidget {
  const GranthsPanel({
    super.key,
    this.placeKey = 'granth-list-place',
    this.scope,
    this.title = 'Granths',
    this.subtitle = 'Sacred texts and scriptures',
    this.leading,
    this.idle,
    this.emptyNote = '',
  });

  /// [Places] key of the list (scroll position + search text).
  final String placeKey;
  final ShelfScope? scope;
  final String title;
  final String subtitle;
  final Widget? leading;

  /// Remote config `coming_soon` of the folder: shown instead of "कोई ग्रंथ नहीं" when it is empty.
  final String emptyNote;

  /// Slivers shown instead of the card grid while the search box is empty.
  final Widget Function(BuildContext context, double dx, PopLedger ledger)? idle;
  @override
  State<GranthsPanel> createState() => _GranthsPanelState();
}

class _GranthsPanelState extends State<GranthsPanel> with LivePanel {
  late String _q = Places.query(widget.placeKey);
  final _log = SearchLogger();
  final _ledger = PopLedger();
  List<Granth>? _src;

  @override
  void dispose() {
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = CatalogStore.I.granths;
    if (!identical(all, _src)) {
      _src = all;
    }
    final scope = widget.scope;
    // The folder's granths are resolved once per catalog (Shelves caches the index).
    final pool = scope == null || widget.idle != null ? all : scope.resolve(Shelves.indexFor(all));
    final idleOn = widget.idle != null && _q.trim().isEmpty;
    var rows = searchRows(pool, _q, CatalogStore.I.granthDoc);
    if (_q.trim().isEmpty) {
      rows = [...rows];
      stableSort(rows, (a, b) => numericCompare(a.position, b.position));
    }
    _log.track(_q, rows.length);
    final cols = UiPrefs.I.cols(Store.kGranthCols, allowed: const [1, 2, 3], fallback: 2);
    final dx = panelDx();
    return SliverMainAxisGroup(slivers: [
      StickyHeader(
        child: Entry(
          index: 0,
          dx: dx,
          child: PageHeader(
            tone: Tone.maroon,
            icon: 'library',
            title: widget.title,
            subtitle: widget.subtitle,
            leading: widget.leading,
            trailingLow: true,
            trailing: Pressable(
              onTap: () => showPop<void>(context, (ctx) => _MultiGranthSheet(granths: rows.isEmpty ? pool : rows)),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.maroon), borderRadius: BorderRadius.circular(999)),
                child: Text('Multiple granth PDF', style: GText.sans(size: 12, weight: FontWeight.w700, color: GColors.maroon, height: 1.2)),
              ),
            ),
            tools: Tools(
              grid: GridSwitch(options: const [1, 2, 3], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kGranthCols, v)),
              search: SearchField(placeholder: 'ग्रंथ का नाम — gita, kabir', initial: _q, onChanged: (v) { Places.setQuery(widget.placeKey, v); setState(() => _q = v); }),
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      // Keyed by the column count: switching 1×1 / 2×2 / 3×3 re-lays out the grid and
      // replays the staggered card entry, so the change is visible and animated.
      if (idleOn) widget.idle!(context, dx, _ledger),
      if (!idleOn) KeyedSubtree(key: ValueKey('grid-$cols'), child: gridSliver(
        count: rows.length,
        cols: cols,
        gap: cols == 1 ? 14 : (cols == 2 ? 10 : 8),
        item: (context, i) {
          final id = '$cols:${rows[i].id}';
          return Entry(
            index: i + 1,
            dx: dx,
            ledger: _ledger,
            id: id,
            child: CardPop(ledger: _ledger, id: id, group: '$cols', index: i + 1, tailMs: GranthCard.innerMs, child: GranthCard(granth: rows[i], index: i + 1, total: rows.length, cols: cols)),
          );
        },
      )),
      if (rows.isEmpty && !idleOn)
        SliverToBoxAdapter(
          child: widget.emptyNote.isNotEmpty && _q.trim().isEmpty
              ? EmptyState(title: 'जल्द आ रहा है', body: widget.emptyNote)
              : const EmptyState(title: 'कोई ग्रंथ नहीं', body: 'सिंक के बाद पवित्र ग्रंथ यहाँ खुलेंगे।'),
        ),
    ]);
  }
}

/// `Vh` — granth card with the "book opening" effect when tapped.
class GranthCard extends StatefulWidget {
  const GranthCard({super.key, required this.granth, required this.index, required this.total, required this.cols});
  final Granth granth;
  final int index;
  final int total;
  final int cols;

  /// Extra time after the pop for the inner stagger (image → title → buttons).
  static const int innerMs = 360;
  @override
  State<GranthCard> createState() => _GranthCardState();
}

class _GranthCardState extends State<GranthCard> with SingleTickerProviderStateMixin {
  late final AnimationController _open = AnimationController(vsync: this, duration: const Duration(milliseconds: 260));
  bool _busy = false;

  @override
  void dispose() {
    _open.dispose();
    super.dispose();
  }

  Future<void> _go() async {
    if (_busy) return;
    _busy = true;
    await _open.forward();
    AppNav.I.go('#/pramans?granth=${widget.granth.id}');
    if (mounted) {
      _open.value = 0;
      _busy = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.granth;
    final s = g.pramanCount;
    final url = g.granthUrl;
    final cols = widget.cols;
    final heroTag = 'granth-cover-${g.id}';
    return ListenableBuilder(
      listenable: CatalogStore.I,
      builder: (context, _) {
        final offline = CatalogStore.I.offlineIds.contains(g.id);
        return AnimatedBuilder(
          animation: _open,
          builder: (context, child) {
            // A book-cover swing: tilt on Y, slight lift and scale.
            final t = Curves.easeInOutCubic.transform(_open.value);
            return Transform(
              alignment: Alignment.centerLeft,
              transform: Matrix4.identity()
                ..setEntry(3, 2, 0.0012)
                ..rotateY(-t * math.pi / 9)
                ..scaleByDouble(1 + 0.03 * t, 1 + 0.03 * t, 1, 1),
              child: Opacity(opacity: 1 - 0.25 * t, child: child),
            );
          },
          child: GCard(
            padding: EdgeInsets.all(cols == 1 ? 16 : 10),
            clip: true,
            onTap: _go,
            child: Builder(builder: (context) {
              // `@container (width<=155px)` — computed from the grid instead of LayoutBuilder
              // (LayoutBuilder can't report intrinsic sizes inside the equal-height grid row).
              final screen = MediaQuery.sizeOf(context).width;
              final gap = cols == 1 ? 14.0 : (cols == 2 ? 10.0 : 8.0);
              final inner = (screen - 32 - gap * (cols - 1)) / cols - (cols == 1 ? 32 : 20) - 2;
              final tiny = inner <= 155;
              final titleSize = tiny ? 12.0 : (cols == 1 ? 18.0 : (cols == 2 ? 15.0 : 13.0));
              final authorSize = cols == 1 ? 13.0 : 12.0;
              final (pillH, pillPad, pillFont) = tiny
                  ? (34.0, const EdgeInsets.symmetric(horizontal: 8, vertical: 7), 12.0)
                  : cols == 3
                      ? (36.0, const EdgeInsets.symmetric(horizontal: 9, vertical: 8), 13.0)
                      : (42.0, const EdgeInsets.symmetric(horizontal: 14, vertical: 10), 15.0);
              Widget pill(String label, {String? icon, PillTone tone = PillTone.plain, VoidCallback? onTap}) => Pill(
                    label: label,
                    icon: icon,
                    tone: tone,
                    onTap: onTap,
                    minHeight: pillH,
                    padding: pillPad,
                    fontSize: pillFont,
                    weight: FontWeight.w700,
                    iconSize: 16,
                  );
              final paths = [g.imagePath, g.editorImagePath].map(mediaPath).whereType<String>().toList();
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Reveal(
                  fromMs: 200,
                  toMs: 500,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                    Text(g.title, maxLines: tiny ? 4 : null, overflow: tiny ? TextOverflow.ellipsis : null, style: GText.script(size: titleSize, color: GColors.maroon)),
                    if (g.author.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(padding: const EdgeInsets.only(top: 2), child: GIcon('pen-line', size: 14, color: GColors.saffronDark)),
                          const SizedBox(width: 6),
                          Flexible(
                            child: Text(g.author,
                                maxLines: tiny ? 2 : null,
                                overflow: tiny ? TextOverflow.ellipsis : null,
                                style: GText.sans(size: authorSize, weight: FontWeight.w700, color: GColors.saffronDark)),
                          ),
                        ]),
                      ),
                    if (g.description.isNotEmpty)
                      Padding(padding: const EdgeInsets.only(top: 8), child: Text(g.description, style: GText.sans(size: 14, color: GColors.muted, height: 1.55))),
                  ]),
                ),
                Reveal(
                  fromMs: 80,
                  toMs: 380,
                  child: GranthImage(
                  path: g.imagePath,
                  kind: ShotKind.cover,
                  heroTag: heroTag,
                  onView: paths.isEmpty ? null : () => openLightbox(context, paths, heroTag: heroTag),
                  save: SaveMeta(title: g.title, text: g.description, granth: g.title),
                ),
                ),
                Reveal(
                  fromMs: 320,
                  toMs: 780,
                  child: Container(
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.only(top: 12),
                  width: double.infinity,
                  decoration: const BoxDecoration(border: Border(top: BorderSide(color: GColors.creamDark))),
                  child: Wrap(spacing: 8, runSpacing: 8, children: [
                    if (s > 0) pill('$s प्रमाण', icon: 'image', tone: PillTone.maroon, onTap: _go),
                    pill('${widget.index}/${widget.total}', icon: 'library'),
                    pill('Share', icon: 'share-2', onTap: () => FileActions.shareText(g.title, shareLink('granth', g.id))),
                    if (url.isNotEmpty) pill('Original PDF', onTap: () => FileActions.openUrl(url)),
                    pill('हाईलाइट PDF', tone: PillTone.maroon, onTap: () => askPdf(context, GranthPdfRequest(g))),
                    if (offline) pill('ऑफलाइन'),
                  ]),
                ),
                ),
              ]);
            }),
          ),
        );
      },
    );
  }
}

/// "Multiple granth PDF" — tick several granths; each gets its own PDF, made in parallel.
class _MultiGranthSheet extends StatefulWidget {
  const _MultiGranthSheet({required this.granths});
  final List<Granth> granths;
  @override
  State<_MultiGranthSheet> createState() => _MultiGranthSheetState();
}

class _MultiGranthSheetState extends State<_MultiGranthSheet> {
  final List<String> _sel = [];

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 520, maxHeight: (h * 0.78).clamp(0, 720)),
      child: SheetCard(scroll: false, children: [
        SheetHead(title: 'Multiple granth PDF', onBack: () => Navigator.pop(context)),
        Text('जिन ग्रंथों की PDF चाहिए उन्हें चुनें। हर ग्रंथ की अलग PDF एक साथ बनेगी।', style: GText.sans(size: 13, color: GColors.muted)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Pill(label: 'सभी', onTap: () => setState(() => _sel
            ..clear()
            ..addAll(widget.granths.map((e) => e.id)))),
          Pill(label: 'साफ', onTap: () => setState(_sel.clear)),
          SizedBox(
            width: 200,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _sel.isEmpty ? 0.45 : 1,
              child: SheetButton(
                label: 'PDF बनाएँ (${_sel.length})',
                primary: true,
                enabled: _sel.isNotEmpty,
                onTap: () {
                  final picked = [for (final id in _sel) ...widget.granths.where((g) => g.id == id)];
                  final nav = Navigator.of(context);
                  final ctx = nav.context;
                  nav.pop();
                  askPdf(ctx, MultiGranthPdfRequest(picked));
                },
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: widget.granths.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final g = widget.granths[i];
              final on = _sel.contains(g.id);
              return Pressable(
                scale: 0.98,
                onTap: () => setState(() => on ? _sel.remove(g.id) : _sel.add(g.id)),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: on ? const Color(0xFFFFF4EA) : GColors.paper,
                    border: Border.all(color: on ? GColors.maroon : const Color(0xFFE7D7B8)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: on ? GColors.maroon : Colors.white,
                        border: Border.all(color: GColors.maroon, width: 1.5),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: on ? const Icon(Icons.check, size: 16, color: Colors.white) : null,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(g.title, style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.text)),
                        if (g.pramanCount > 0) Text('${g.pramanCount} प्रमाण', style: GText.sans(size: 12, color: GColors.muted)),
                      ]),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
      ]),
    );
  }
}
