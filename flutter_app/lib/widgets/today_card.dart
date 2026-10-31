/// Round 14: "आज का प्रमाण" (daily praman) and "चर्चित विषय" (trending topics).
///
/// * Daily: the signed config's optional `daily_praman {id, date}` when its date is today (or it has
///   no date) and that praman is on the phone; otherwise a local pick that is the same for
///   everyone on a given day (hash of the date over the pramans sorted by id).
/// * Trending: the config's optional `trending.topic_ids` (in order, only topics on the phone);
///   nothing at all when the admin has not set it.
/// Notifications for these wait for push (Firebase) — not in this round.
library;

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/catalog_store.dart';
import '../services/remote_config.dart';
import '../state/router.dart';
import '../theme/colors.dart';
import 'common.dart';
import 'overlays.dart';

String _ymd(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// FNV-1a, so the pick never depends on Dart's per-run String.hashCode.
int _fnv(String s) {
  var h = 0x811c9dc5;
  for (final c in s.codeUnits) {
    h ^= c;
    h = (h * 0x01000193) & 0xffffffff;
  }
  return h;
}

Praman? dailyPraman(List<Praman> pramans, DailyPick? pick, DateTime now) {
  if (pramans.isEmpty) return null;
  final today = _ymd(now);
  if (pick != null && (pick.date.isEmpty || pick.date == today)) {
    for (final p in pramans) {
      if (p.id == pick.id) return p;
    }
  }
  int key(Praman p) => int.tryParse(p.id) ?? 0;
  final sorted = [...pramans]
    ..sort((a, b) {
      final c = key(a).compareTo(key(b));
      return c != 0 ? c : a.id.compareTo(b.id);
    });
  return sorted[_fnv(today) % sorted.length];
}

List<Topic> trendingTopics(List<Topic> topics, List<String> ids) {
  final byId = {for (final t in topics) t.id: t};
  return [for (final id in ids) ?byId[id]];
}

void _openPraman(Praman p) => AppNav.I.openLink('#/pramans?id=${Uri.encodeComponent(p.id)}');

/// Daily praman + trending chips (used on the dashboard and in the "Topic" sheet).
class TodayCard extends StatelessWidget {
  const TodayCard({super.key, this.now, this.inSheet = false});
  final DateTime Function()? now;
  final bool inSheet;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([RemoteConfig.I, CatalogStore.I]),
    builder: (context, _) {
      final s = CatalogStore.I;
      final p = !RemoteConfig.I.dailyEnabled ? null : dailyPraman(s.pramans, RemoteConfig.I.dailyPraman, (now ?? DateTime.now)());
      final trend = RemoteConfig.I.trendingEnabled ? trendingTopics(s.topics, RemoteConfig.I.trendingTopics) : const <Topic>[];
      if (p == null && trend.isEmpty) return const SizedBox.shrink();
      void close() {
        if (inSheet) Navigator.of(context).maybePop();
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (p != null)
            Pressable(
              key: const ValueKey('daily-praman'),
              onTap: () {
                close();
                _openPraman(p);
              },
              scale: 0.98,
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: GColors.cream,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: GColors.creamDark),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const IconBox(tone: Tone.gold, icon: 'calendar-days', size: 44, radius: 12, iconSize: 22),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'आज का प्रमाण',
                            style: GText.sans(size: 13, weight: FontWeight.w700, color: GColors.saffronDark),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            p.title,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: GText.script(size: 17, color: GColors.maroon),
                          ),
                          if (p.granthTitle.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 2),
                              child: Text(
                                '📖 ${p.granthTitle}',
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: GText.sans(size: 13, color: GColors.muted),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (trend.isNotEmpty) ...[
            const SizedBox(height: 14),
            Row(
              children: [
                const GIcon('trending-up', size: 16, color: GColors.brown),
                const SizedBox(width: 6),
                Text(
                  'चर्चित विषय',
                  style: GText.sans(size: 14, weight: FontWeight.w700, color: GColors.brown),
                ),
              ],
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, c) => Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final t in trend)
                    ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: c.maxWidth),
                      child: Pill(
                        key: ValueKey('trend-${t.id}'),
                        label: t.title,
                        tone: PillTone.topic,
                        maxLines: 2,
                        onTap: () {
                          close();
                          AppNav.I.openLink('#/pramans?topic=${Uri.encodeComponent(t.id)}');
                        },
                      ),
                    ),
                ],
              ),
            ),
          ],
        ],
      );
    },
  );
}

/// The "Topic" menu entry (below Photo Highlighter): today's praman, trending topics, all topics.
Future<void> openTodaySheet(BuildContext context) => showPop(context, (ctx) => const _TodaySheet());

class _TodaySheet extends StatelessWidget {
  const _TodaySheet();
  @override
  Widget build(BuildContext context) => FrostCard(
    child: ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Topic', style: GText.script(size: 20, color: GColors.maroon)),
            const SizedBox(height: 10),
            const TodayCard(inSheet: true),
            const SizedBox(height: 14),
            SheetButton(
              key: const ValueKey('today-all-topics'),
              label: 'सभी Topics देखें',
              icon: 'clipboard-list',
              primary: true,
              onTap: () {
                Navigator.pop(context);
                AppNav.I.go('#/topics');
              },
            ),
          ],
        ),
      ),
    ),
  );
}
