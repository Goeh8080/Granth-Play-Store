import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/order.dart';
import '../services/search.dart';
import '../services/storage.dart';
import '../state/router.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/granth_image.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';
import '../widgets/pdf_sheets.dart';

/// `Dh` — Granths / Sacred texts and scriptures.
class GranthsPanel extends StatefulWidget {
  const GranthsPanel({super.key});
  @override
  State<GranthsPanel> createState() => _GranthsPanelState();
}

class _GranthsPanelState extends State<GranthsPanel> {
  String _q = '';
  final _log = SearchLogger();
  final Map<String, SearchDoc> _docs = {};
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
      _docs.clear();
    }
    var rows = searchRows(all, _q, (g) => _docs[g.id] ??= docOf([g.title, g.author, g.description]));
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
            title: 'Granths',
            subtitle: 'Sacred texts and scriptures',
            tools: Tools(
              grid: GridSwitch(options: const [1, 2, 3], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kGranthCols, v)),
              search: SearchField(placeholder: 'ग्रंथ का नाम — gita, kabir', onChanged: (v) => setState(() => _q = v)),
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      gridSliver(
        count: rows.length,
        cols: cols,
        gap: cols == 1 ? 14 : (cols == 2 ? 10 : 8),
        item: (context, i) => Entry(index: i + 1, dx: dx, child: GranthCard(granth: rows[i], index: i + 1, total: rows.length, cols: cols)),
      ),
      if (rows.isEmpty) const SliverToBoxAdapter(child: EmptyState(title: 'कोई ग्रंथ नहीं', body: 'सिंक के बाद पवित्र ग्रंथ यहाँ खुलेंगे।')),
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
                GranthImage(
                  path: g.imagePath,
                  kind: ShotKind.cover,
                  heroTag: heroTag,
                  onView: paths.isEmpty ? null : () => openLightbox(context, paths, heroTag: heroTag),
                  save: SaveMeta(title: g.title, text: g.description, granth: g.title),
                ),
                Container(
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
              ]);
            }),
          ),
        );
      },
    );
  }
}
