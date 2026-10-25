import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/panel.dart';

/// Round 11: तत्त्व AI से पूछे — a placeholder until the feature is built. No chat UI, no
/// network: just a themed "coming soon" card. It uses the same page header, card look and
/// entry animation as every other screen, so it follows the chosen card style.
class AiPanel extends StatelessWidget {
  const AiPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final dx = panelDx();
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Entry(
          index: 0,
          dx: dx,
          child: const Padding(
            padding: EdgeInsets.only(bottom: 18),
            child: PageHeader(tone: Tone.saffron, icon: 'sparkles', title: 'तत्त्व AI से पूछे', subtitle: 'अपना प्रश्न पूछिए, प्रमाण पाइए'),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Entry(
          index: 1,
          dx: dx,
          child: GCard(
            key: const ValueKey('ai-soon'),
            padding: const EdgeInsets.fromLTRB(20, 28, 20, 28),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const IconBox(tone: Tone.saffron, icon: 'sparkles', size: 64, radius: 16, iconSize: 32),
              const SizedBox(height: 16),
              Text('जल्द आ रहा है', textAlign: TextAlign.center, style: GText.display(size: 26, color: GColors.maroon, height: 1.3)),
              const SizedBox(height: 8),
              Text(
                'जल्द ही आप यहाँ अपना प्रश्न पूछ सकेंगे और उससे मिलता हुआ ग्रंथ व प्रमाण पा सकेंगे।',
                textAlign: TextAlign.center,
                style: GText.sans(size: 16, color: GColors.muted, height: 1.6),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}
