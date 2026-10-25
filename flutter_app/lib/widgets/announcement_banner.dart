import 'package:flutter/material.dart';

import '../services/remote_config.dart';
import '../theme/colors.dart';
import 'common.dart';

/// The admin's announcement (remote config), shown on the dashboard. Dismissible: the same
/// announcement id does not come back; a new id shows again. Nothing is shown when there is none.
class AnnouncementBanner extends StatelessWidget {
  const AnnouncementBanner({super.key});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: RemoteConfig.I,
        builder: (context, _) {
          final a = RemoteConfig.I.banner;
          if (a == null) return const SizedBox.shrink();
          final (bg, border, fg, icon) = switch (a.level) {
            'critical' => (const Color(0xFFFBE9E7), const Color(0xFFD4574A), const Color(0xFF8E1B10), 'alert-triangle'),
            'warn' => (const Color(0xFFFFF4DC), GColors.gold, GColors.brown, 'alert-triangle'),
            _ => (GColors.pillTopic, GColors.saffron, GColors.brown, 'bell'),
          };
          return Padding(
            key: const ValueKey('announcement'),
            padding: const EdgeInsets.only(bottom: 16),
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
              decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(14), border: Border.all(color: border, width: 1.2)),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(padding: const EdgeInsets.only(top: 2), child: GIcon(icon, size: 20, color: fg)),
                const SizedBox(width: 10),
                Expanded(child: Text(a.text, style: GText.sans(size: 14.5, weight: FontWeight.w600, color: fg, height: 1.45))),
                Semantics(
                  button: true,
                  label: 'बंद करें',
                  child: InkResponse(
                    key: const ValueKey('announcement-close'),
                    onTap: RemoteConfig.I.dismissBanner,
                    radius: 24,
                    child: Padding(padding: const EdgeInsets.all(10), child: GIcon('x', size: 18, color: fg)),
                  ),
                ),
              ]),
            ),
          );
        },
      );
}
