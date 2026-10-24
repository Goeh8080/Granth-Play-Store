import 'dart:async';

import 'package:flutter/material.dart';

import '../services/events.dart';
import '../state/router.dart';
import '../theme/colors.dart';
import 'common.dart';

/// Horizontal offset for the incoming panel (shared-axis feel: in from the right when drilling in).
double panelDx() => 28.0 * AppNav.I.direction;

/// `.page-header` (+ `.sticky-bar` when [sticky]).
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.tone, required this.icon, required this.title, required this.subtitle, this.trailing, this.tools, this.trailingLow = false, this.leading});
  final Tone tone;
  final String icon;
  final String title;
  final String subtitle;
  final Widget? trailing;
  final Widget? tools;

  /// Replaces the [icon] box (the granth folders show their painted group icon here).
  final Widget? leading;

  /// Put [trailing] a little lower, beside the subtitle, so the title keeps the full width
  /// and stays on one line (Granths: "Multiple granth PDF" made "Granths" wrap at 360 dp).
  final bool trailingLow;

  @override
  Widget build(BuildContext context) {
    if (trailing != null && trailingLow) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [
          leading ?? IconBox(tone: tone, icon: icon),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(title, maxLines: 1, softWrap: false, style: GText.display(size: 28, color: GColors.maroon, height: 1.1)),
              ),
              const SizedBox(height: 2),
              LayoutBuilder(
                builder: (context, c) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(child: Text(subtitle, style: GText.sans(size: 13, color: GColors.muted, height: 1.5))),
                  const SizedBox(width: 10),
                  // Large font sizes: the button shrinks a little instead of overflowing.
                  ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: c.maxWidth * 0.62),
                    child: FittedBox(fit: BoxFit.scaleDown, child: KeyedSubtree(key: const ValueKey('header-trailing'), child: trailing!)),
                  ),
                ]),
              ),
            ]),
          ),
        ]),
        if (tools != null) ...[const SizedBox(height: 16), tools!],
      ]);
    }
    final titleRow = Row(children: [
      leading ?? IconBox(tone: tone, icon: icon),
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
        // The bar is 96 % opaque, so the old backdrop blur behind it was invisible but was
        // re-rendered on every scroll frame (a full-width blur pass): dropped for smoothness.
        child: RepaintBoundary(
          child: Container(
            color: GColors.stickyBar.withValues(alpha: 0.96),
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: child,
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
      // 1×1: the card itself. (Wrapping it in `Expanded` outside a Row threw a layout error,
      // which a release build shows as an empty screen — the "1×1 does nothing" bug.)
      if (cols == 1) return Padding(padding: EdgeInsets.only(top: r == 0 ? 0 : gap), child: item(context, r));
      final cells = <Widget>[];
      for (var c = 0; c < cols; c++) {
        final i = r * cols + c;
        if (c > 0) cells.add(SizedBox(width: gap));
        cells.add(Expanded(child: i < count ? item(context, i) : const SizedBox.shrink()));
      }
      final row = IntrinsicHeight(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: cells));
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
