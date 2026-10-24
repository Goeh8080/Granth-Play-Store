import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/order.dart';
import '../services/pdf_queue.dart';
import '../services/search.dart';
import '../services/storage.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/live_panel.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';
import '../widgets/pop.dart';
import '../widgets/pdf_sheets.dart';

/// `Th` — Topics / विषय / प्रश्नोत्तरी.
class TopicsPanel extends StatefulWidget {
  const TopicsPanel({super.key});
  @override
  State<TopicsPanel> createState() => _TopicsPanelState();
}

class _TopicsPanelState extends State<TopicsPanel> with LivePanel {
  String _q = Places.query('topic-list-place');
  final _log = SearchLogger();
  final _ledger = PopLedger();
  List<Topic>? _src;

  SearchDoc _doc(Topic t) => CatalogStore.I.topicDoc(t);

  @override
  void dispose() {
    _log.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = CatalogStore.I.topics;
    if (!identical(all, _src)) {
      _src = all;
    }
    var rows = searchRows(all, _q, _doc);
    if (_q.trim().isEmpty) {
      rows = [...rows];
      stableSort(rows, (a, b) => numericCompare(a.position, b.position));
    }
    _log.track(_q, rows.length);
    final cols = UiPrefs.I.cols(Store.kTopicCols, allowed: const [1, 2], fallback: 2);
    final dx = panelDx();
    return SliverMainAxisGroup(slivers: [
      StickyHeader(
        child: Entry(
          index: 0,
          dx: dx,
          child: PageHeader(
            tone: Tone.saffron,
            icon: 'clipboard-list',
            title: 'Topics',
            subtitle: 'विषय / प्रश्नोत्तरी',
            trailing: Pressable(
              onTap: () => _openMulti(context, all),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.maroon), borderRadius: BorderRadius.circular(999)),
                child: Text('Multiple topic PDF', style: GText.sans(size: 12, weight: FontWeight.w700, color: GColors.maroon, height: 1.2)),
              ),
            ),
            tools: Tools(
              grid: GridSwitch(options: const [1, 2], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kTopicCols, v)),
              search: SearchField(placeholder: 'विषय खोजें — mans, गीता, मृत्यु', initial: _q, onChanged: (v) { Places.setQuery('topic-list-place', v); setState(() => _q = v); }),
            ),
          ),
        ),
      ),
      const SliverToBoxAdapter(child: SizedBox(height: 18)),
      // Keyed by the column count: switching 1×1 / 2×2 / 3×3 re-lays out the grid and
      // replays the staggered card entry, so the change is visible and animated.
      KeyedSubtree(key: ValueKey('grid-$cols'), child: gridSliver(
        count: rows.length,
        cols: cols,
        gap: 14,
        item: (context, i) {
          final id = '$cols:${rows[i].id}';
          return Entry(
            index: i + 1,
            dx: dx,
            ledger: _ledger,
            id: id,
            child: CardPop(
              ledger: _ledger,
              id: id,
              group: '$cols',
              index: i + 1,
              child: TopicCard(
                topic: rows[i],
                index: i + 1,
                total: rows.length,
                padding: cols == 2 ? 12 : 16,
              ),
            ),
          );
        },
      )),
      if (rows.isEmpty) const SliverToBoxAdapter(child: EmptyState(title: 'कोई विषय नहीं', body: 'सिंक पूरा होने पर विषय यहाँ दिखेंगे।')),
    ]);
  }

  void _openMulti(BuildContext context, List<Topic> topics) {
    showPop(context, (ctx) => _MultiSheet(topics: topics));
  }
}

class TopicCard extends StatelessWidget {
  const TopicCard({super.key, required this.topic, required this.index, required this.total, this.padding = 16});
  final Topic topic;
  final int index;
  final int total;
  final double padding;

  @override
  Widget build(BuildContext context) {
    final t = topic;
    final n = t.pramanCount;
    void open() => AppNav.I.go('#/pramans?topic=${t.id}');
    return GCard(
      padding: EdgeInsets.all(padding),
      onTap: open,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('${t.position}. ${t.title}', style: GText.script(size: 18, color: GColors.maroon)),
        if (t.description.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(t.description, style: GText.sans(size: 14, color: GColors.muted, height: 1.55)),
        ],
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.only(top: 12),
          width: double.infinity,
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: GColors.creamDark))),
          child: Wrap(spacing: 8, runSpacing: 8, children: [
            if (n > 0) Pill(icon: 'image', label: '$n प्रमाण', tone: PillTone.maroon, onTap: open),
            if (n > 0) Pill(icon: 'library', label: '$index/$total', onTap: open),
            Pill(icon: 'share-2', label: 'Share', onTap: () => FileActions.shareText(t.title, shareLink('topic', t.id))),
            Pill(label: 'PDF', tone: PillTone.maroon, onTap: () => askPdf(context, TopicPdfRequest(t))),
          ]),
        ),
      ]),
    );
  }
}

class _MultiSheet extends StatefulWidget {
  const _MultiSheet({required this.topics});
  final List<Topic> topics;
  @override
  State<_MultiSheet> createState() => _MultiSheetState();
}

class _MultiSheetState extends State<_MultiSheet> {
  final List<String> _sel = [];

  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: 520, maxHeight: (h * 0.78).clamp(0, 720)),
      child: SheetCard(scroll: false, children: [
        SheetHead(title: 'Multiple topic PDF', onBack: () => Navigator.pop(context)),
        Text('जिन विषयों की PDF चाहिए उन्हें चुनें। आखिर में एक ही जोड़ी हुई PDF बनेगी।', style: GText.sans(size: 13, color: GColors.muted)),
        const SizedBox(height: 10),
        Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Pill(label: 'सभी', onTap: () => setState(() => _sel
            ..clear()
            ..addAll(widget.topics.map((e) => e.id)))),
          Pill(label: 'साफ', onTap: () => setState(_sel.clear)),
          SizedBox(
            width: 200,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: _sel.isEmpty ? 0.45 : 1,
              child: SheetButton(
                label: 'एक PDF बनाएँ (${_sel.length})',
                primary: true,
                enabled: _sel.isNotEmpty,
                onTap: () {
                  final order = {for (var i = 0; i < _sel.length; i++) _sel[i]: i};
                  final picked = widget.topics.where((t) => order.containsKey(t.id)).toList()..sort((a, b) => order[a.id]!.compareTo(order[b.id]!));
                  Navigator.pop(context);
                  PdfQueue.I.multiTopicPdf(picked);
                },
              ),
            ),
          ),
        ]),
        const SizedBox(height: 10),
        Flexible(
          child: ListView.separated(
            shrinkWrap: true,
            itemCount: widget.topics.length,
            separatorBuilder: (_, _) => const SizedBox(height: 8),
            itemBuilder: (context, i) {
              final t = widget.topics[i];
              final on = _sel.contains(t.id);
              return Pressable(
                scale: 0.98,
                onTap: () => setState(() => on ? _sel.remove(t.id) : _sel.add(t.id)),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 180),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: on ? const Color(0xFFFFF4EA) : GColors.paper,
                    border: Border.all(color: on ? GColors.maroon : const Color(0xFFE7D7B8)),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(
                      width: 22,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 180),
                        transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                        child: Text(on ? '✓' : '${i + 1}', key: ValueKey(on), style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon)),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(child: Text(t.title, style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.text))),
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
