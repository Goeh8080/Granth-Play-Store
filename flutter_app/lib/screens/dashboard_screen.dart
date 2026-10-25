import 'package:flutter/material.dart';

import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../state/router.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/announcement_banner.dart';
import '../widgets/common.dart';
import '../widgets/live_panel.dart';
import '../widgets/panel.dart';

/// `wh` — Dashboard.
class DashboardPanel extends StatefulWidget {
  const DashboardPanel({super.key});
  @override
  State<DashboardPanel> createState() => _DashboardPanelState();
}

class _DashboardPanelState extends State<DashboardPanel> with LivePanel {
  @override
  void initState() {
    super.initState();
    // A fresh dashboard open counts up from 0 once; data that arrives later animates on
    // from the number on screen.
    CountUp.replay('dash:');
  }

  @override
  Widget build(BuildContext context) {
    final s = CatalogStore.I;
    final dx = panelDx();
    return SliverList.list(children: [
      Entry(
        index: 0,
        dx: dx,
        child: const Padding(
          padding: EdgeInsets.only(bottom: 18),
          child: PageHeader(tone: Tone.saffron, icon: 'landmark', title: 'Dashboard', subtitle: 'Overview of your Granth collection'),
        ),
      ),
      const AnnouncementBanner(),
      Entry(index: 1, dx: dx, child: _DashCard(tone: Tone.saffron, icon: 'clipboard-list', count: s.topics.length, label: 'Topics', hash: '#/topics')),
      const SizedBox(height: 14),
      Entry(index: 2, dx: dx, child: _DashCard(tone: Tone.maroon, icon: 'library', count: s.granths.length, label: 'Granths', hash: '#/granths')),
      const SizedBox(height: 14),
      Entry(index: 3, dx: dx, child: _DashCard(tone: Tone.gold, icon: 'image', count: s.pramans.length, label: 'प्रमाण', hash: '#/pramans')),
      Entry(index: 4, dx: dx, child: const _NoteCard()),
    ]);
  }
}

class _DashCard extends StatelessWidget {
  const _DashCard({required this.tone, required this.icon, required this.count, required this.label, required this.hash});
  final Tone tone;
  final String icon;
  final int count;
  final String label;
  final String hash;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: UiPrefs.I,
        builder: (context, _) => Pressable(
          onTap: () => AppNav.I.go(hash),
          scale: 0.97,
          child: Container(
            padding: const EdgeInsets.all(18),
            decoration: cardDecoration(UiPrefs.I.look, dash: true),
            child: Row(children: [
              IconBox(tone: tone, icon: icon, size: 60, radius: 14, iconSize: 28),
              const SizedBox(width: 16),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                // Count-up micro-animation.
                CountUp(value: count, memo: 'dash:$label', style: GText.display(size: 36, color: GColors.maroon, height: 1)),
                const SizedBox(height: 4),
                Text(label, style: GText.sans(size: 15, weight: FontWeight.w700, color: GColors.muted)),
              ]),
            ]),
          ),
        ),
      );
}

class _NoteCard extends StatelessWidget {
  const _NoteCard();
  @override
  Widget build(BuildContext context) => LookBuilder(builder: (context, _) => _box());

  Widget _box() => Container(
        margin: const EdgeInsets.only(top: 18),
        padding: const EdgeInsets.all(18),
        decoration: themedSurface(BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.creamDark), borderRadius: BorderRadius.circular(14))),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('सत साहेब जी', style: GText.display(size: 22, color: GColors.maroon)),
          const SizedBox(height: 8),
          const SizedBox(height: 8),
          Text(
            'जो प्रमाण समय पर याद नहीं रहते, यह ग्रंथ प्रबंधन उन्हें विषय और ग्रंथ के साथ एक जगह रखता है। पहली बार इंटरनेट पर खुलते ही विषय, ग्रंथ और प्रमाण इस डिवाइस पर सेव हो जाते हैं — उसके बाद ऐप बिना नेट के खुलता है।',
            style: GText.sans(size: 16, color: GColors.text, height: 1.6),
          ),
          const SizedBox(height: 8),
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text('संपर्क: ', style: GText.sans(size: 16, color: GColors.text, height: 1.6)),
            GestureDetector(
              onTap: () => FileActions.openMail('sadgranthpraman@gmail.com'),
              child: Text('sadgranthpraman@gmail.com',
                  style: GText.sans(size: 16, weight: FontWeight.w600, color: GColors.saffronDark, height: 1.6)
                      .copyWith(decoration: TextDecoration.underline, decorationColor: GColors.saffronDark)),
            ),
          ]),
        ]),
      );
}
