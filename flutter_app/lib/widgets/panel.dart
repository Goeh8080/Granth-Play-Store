import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../services/events.dart';
import '../state/router.dart';
import '../theme/colors.dart';
import 'common.dart';

/// Horizontal offset for the incoming panel (shared-axis feel: in from the right when drilling in).
double panelDx() => 28.0 * AppNav.I.direction;

/// `.page-header` (+ `.sticky-bar` when [sticky]).
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.tone, required this.icon, required this.title, required this.subtitle, this.trailing, this.tools});
  final Tone tone;
  final String icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget? tools;

  @override
  Widget build(BuildContext context) {
    final titleRow = Row(children: [
      IconBox(tone: tone, icon: icon),
      const SizedBox(width: 12),
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text(title, style: GText.display(size: 28, color: GColors.maroon, height: 1.1)),
          const SizedBox(height: 2),
          Text(subtitle, style: GText.sans(size: 13, color: GColors.muted, height: 1.5)),
        ]),
      ),
      if (trailing != null) ...[const SizedBox(width: 10), trailing!],
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
      titleRow,
      if (tools != null) ...[const SizedBox(height: 16), tools!],
    ]);
  }
}

/// Sticky header sliver: pinned with the frosted `#fdf7e6` bar.
class StickyHeader extends StatelessWidget {
  const StickyHeader({super.key, required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) => PinnedHeaderSliver(
        child: ClipRect(
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
            child: Container(
              color: GColors.stickyBar.withValues(alpha: 0.96),
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: child,
            ),
          ),
        ),
      );
}

/// `.granth-tools` — grid switch + search, space-between.
class Tools extends StatelessWidget {
  const Tools({super.key, required this.grid, required this.search});
  final Widget grid;
  final Widget search;
  @override
  Widget build(BuildContext context) => Row(children: [grid, const SizedBox(width: 10), Expanded(child: search)]);
}

/// CSS-grid emulation: rows of equal-height cells.
Widget gridSliver({required int count, required int cols, required double gap, required Widget Function(BuildContext, int) item}) {
  final rows = (count / cols).ceil();
  return SliverList.builder(
    itemCount: rows,
    itemBuilder: (context, r) {
      final cells = <Widget>[];
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        if (c > 0) cells.add(SizedBox(width: gap));
        cells.add(Expanded(child: i < count ? item(context, i) : const SizedBox.shrink()));
      }
      final row = cols == 1 ? cells.first : IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells));
      return Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : gap), child: row);
    },
  );
}

/// `dt()` — local search analytics (search / search_empty after 800 ms).
class SearchLogger {
  Timer? _t;
  String _last = '';
  void track(String q, int hits) {
    _t?.cancel();
    final r = q.trim();
    if (r.length < 2) return;
    _t = Timer(const Duration(milliseconds: 800), () {
      final k = '$r|${hits == 0 ? 'empty' : 'hit'}';
      if (_last == k) return;
      _last = k;
      EventLog.I.log(hits == 0 ? 'search_empty' : 'search', 'search', r);
    });
  }

  void dispose() => _t?.cancel();
}

/// Card text that keeps the original's line breaks (`Jn`).
class MultiLine extends StatelessWidget {
  const MultiLine(this.text, {super.key, required this.style, this.maxLines});
  final String text;
  final TextStyle style;
  final int? maxLines;
  @override
  Widget build(BuildContext context) => Text(text, style: style, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
}
