import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/order.dart';
import '../services/search.dart';
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
import '../widgets/video_block.dart';

/// `Hh` — प्रमाण list, optionally filtered by topic / granth / id.
class PramansPanel extends StatefulWidget {
  const PramansPanel({super.key, required this.route});
  final GRoute route;
  @override
  State<PramansPanel> createState() => _PramansPanelState();
}

class _PramansPanelState extends State<PramansPanel> with LivePanel {
  late final String _key = Places.keyFor(widget.route) ?? 'praman-list::';
  late String _q = Places.query(_key);
  final _log = SearchLogger();
  final _ledger = PopLedger();
  List<Praman>? _src;
  List<Praman>? _filteredSrc;
  String _filteredKey = '';
  List<Praman> _filtered = const [];

  @override
  void dispose() {
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = CatalogStore.I;
    final e = widget.route;
    final all = s.pramans;
    if (!identical(all, _src)) {
      _src = all;
    }
    Topic? topic;
    Granth? granth;
    for (final t in s.topics) {
      if (t.id == e.topicId) topic = t;
    }
    for (final g in s.granths) {
      if (g.id == e.granthId) granth = g;
    }
    // Re-filter when the data OR the route changes (a shared link can switch the topic /
    // granth / praman while this screen stays mounted).
    final key = '${e.topicId}|${e.granthId}|${e.pramanId}';
    if (!identical(_filteredSrc, all) || key != _filteredKey) {
      _filteredSrc = all;
      if (key != _filteredKey) _ledger.clear(); // a new page of pramans = a new visit
      _filteredKey = key;
      _filtered = orderPramans(
        all.where((t) => !((e.topicId != null && t.topicId != e.topicId) || (e.granthId != null && t.granthId != e.granthId) || (e.pramanId != null && t.id != e.pramanId))).toList(),
        granth?.title ?? '',
      );
    }
    final rows = searchRows(_filtered, _q, CatalogStore.I.pramanDoc);
    _log.track(_q, rows.length);
    final cols = UiPrefs.I.cols(Store.kPramanCols, allowed: const [1, 2], fallback: 2);
    final dx = panelDx();
    return SliverMainAxisGroup(slivers: [
      StickyHeader(
        child: Entry(
          index: 0,
          dx: dx,
          child: PageHeader(
            tone: Tone.gold,
            icon: 'image',
            title: 'प्रमाण',
            subtitle: 'शास्त्र प्रमाण',
            tools: Tools(
              grid: GridSwitch(options: const [1, 2], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kPramanCols, v)),
              search: SearchField(placeholder: 'प्रमाण खोजें — mans, मृत्यु', initial: _q, onChanged: (v) { Places.setQuery(_key, v); setState(() => _q = v); }),
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      if (topic != null || granth != null)
        SliverToBoxAdapter(
          child: Entry(
            index: 1,
            dx: dx,
            child: Container(
              margin: const EdgeInsets.only(bottom: 14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: themedSurface(BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.maroon, width: 2), borderRadius: BorderRadius.circular(14)), keepColor: true),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      if (topic != null) ...[
                        const TextSpan(text: 'विषय:', style: TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: ' ${topic.title}'),
                      ],
                      if (granth != null) ...[
                        const TextSpan(text: 'ग्रंथ:', style: TextStyle(fontWeight: FontWeight.w700)),
                        TextSpan(text: ' ${granth.title}'),
                      ],
                    ]),
                    style: GText.script(size: 16, color: GColors.maroon),
                  ),
                ),
                const SizedBox(width: 12),
                Pill(label: 'सभी प्रमाण', onTap: () => AppNav.I.go('#/pramans')),
              ]),
            ),
          ),
        ),
      // Keyed by the column count: switching 1×1 / 2×2 / 3×3 re-lays out the grid and
      // replays the staggered card entry, so the change is visible and animated.
      KeyedSubtree(key: ValueKey('grid-$cols'), child: gridSliver(
        count: rows.length,
        cols: cols,
        gap: 14,
        item: (context, i) {
          final id = '$cols:${rows[i].id}';
          return Entry(
            index: i + 2,
            dx: dx,
            ledger: _ledger,
            id: id,
            child: CardPop(ledger: _ledger, id: id, group: '$cols', index: i + 2, child: PramanCard(praman: rows[i], index: i + 1, total: rows.length)),
          );
        },
      )),
      if (rows.isEmpty && _linkMissing(s, e, topic, granth))
        SliverToBoxAdapter(
          child: Column(children: [
            const EmptyState(title: 'लिंक वाला विषय/ग्रंथ/प्रमाण नहीं मिला', body: 'यह शायद हटा दिया गया है या अभी सिंक नहीं हुआ। सिंक के बाद फिर खोलें।'),
            const SizedBox(height: 12),
            Pill(label: 'Dashboard पर जाएँ', tone: PillTone.maroon, onTap: () => AppNav.I.go('#/dashboard')),
          ]),
        )
      else if (rows.isEmpty)
        const SliverToBoxAdapter(child: EmptyState(title: 'कोई प्रमाण नहीं', body: 'इस चयन में प्रमाण नहीं मिले, या सिंक अभी चल रहा है।')),
    ]);
  }
}

/// The route came from a link whose topic / granth / praman is not in the (loaded) catalog.
bool _linkMissing(CatalogStore s, GRoute e, Topic? topic, Granth? granth) {
  if (!s.hasData || s.status == SyncStatus.syncing || s.status == SyncStatus.booting) return false;
  if (e.topicId != null && topic == null) return true;
  if (e.granthId != null && granth == null) return true;
  if (e.pramanId != null && !s.pramans.any((p) => p.id == e.pramanId)) return true;
  return false;
}

/// `Uh`
class PramanCard extends StatelessWidget {
  const PramanCard({super.key, required this.praman, required this.index, required this.total});
  final Praman praman;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final e = praman;
    final vid = youtubeId(e.youtubeUrl);
    final paths = [e.imagePath, e.granthImage, e.editorImagePath].map(mediaPath).whereType<String>().toList();
    final hero = 'praman-${e.id}';
    void open() => openLightbox(context, paths, heroTag: hero);
    return GCard(
      padding: EdgeInsets.zero,
      clip: true,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(children: [
                  GranthImage(
                    path: e.granthImage,
                    kind: ShotKind.thumb,
                    onTap: open,
                    save: SaveMeta(title: e.granthTitle, text: e.title, topic: e.topicTitle, granth: e.granthTitle),
                  ),
                  if (mediaPath(e.granthImage) != null) const SizedBox(width: 8),
                  GranthImage(path: e.editorImagePath, kind: ShotKind.thumb, onTap: open),
                  const Spacer(),
                  if (e.isFavorite) Text('मुख्य', style: GText.sans(size: 12, weight: FontWeight.w700, color: GColors.maroon)),
                ]),
              ),
            Text(e.title, style: GText.script(size: 18, color: GColors.maroon)),
            if (e.description.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 8), child: Text(e.description, style: GText.sans(size: 14, color: GColors.muted, height: 1.55))),
          ]),
        ),
        GranthImage(
          path: e.imagePath,
          kind: ShotKind.proof,
          heroTag: hero,
          onTap: open,
          save: SaveMeta(title: e.title, text: e.description, topic: e.topicTitle, granth: e.granthTitle),
        ),
        if (vid != null) VideoBlock(videoId: vid, start: e.youtubeStart, desc: e.youtubeDesc, title: e.title),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            padding: const EdgeInsets.only(top: 12, bottom: 16),
            decoration: const BoxDecoration(border: Border(top: BorderSide(color: GColors.creamDark))),
            margin: const EdgeInsets.only(top: 16),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              if (e.topicTitle.isNotEmpty) Pill(label: e.topicTitle, tone: PillTone.topic, onTap: () => AppNav.I.go('#/pramans?topic=${e.topicId}')),
              if (e.granthTitle.isNotEmpty) Pill(icon: 'library', label: e.granthTitle, onTap: () => AppNav.I.go('#/pramans?granth=${e.granthId}')),
              Pill(icon: 'library', label: '$index/$total'),
              Pill(icon: 'share-2', label: 'Share', onTap: () => FileActions.shareText(e.title, shareLink('praman', e.id))),
              Pill(label: 'PDF', tone: PillTone.maroon, onTap: () => askPdf(context, PramanPdfRequest(e))),
            ]),
          ),
        ),
      ]),
    );
  }
}
