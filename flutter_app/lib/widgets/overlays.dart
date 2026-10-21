import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import 'common.dart';
import 'granth_image.dart';
import 'zoom.dart';

/// `.pdf-pop` + `.pdf-sheet` animation (sheet-fade .22s + sheet-rise .28s cubic(.22,1,.36,1)).
const Curve kRise = Cubic(0.22, 1, 0.36, 1);

Future<T?> showPop<T>(BuildContext context, WidgetBuilder builder, {bool dismissible = true}) {
  return showGeneralDialog<T>(
    context: context,
    barrierDismissible: dismissible,
    barrierLabel: 'close',
    barrierColor: GColors.brown.withValues(alpha: 0.28),
    transitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (ctx, a, b) => SafeArea(
      child: Center(
        child: Padding(padding: const EdgeInsets.all(16), child: Material(type: MaterialType.transparency, child: builder(ctx))),
      ),
    ),
    transitionBuilder: (ctx, a, b, child) {
      final rise = CurvedAnimation(parent: a, curve: kRise, reverseCurve: Curves.easeIn);
      return FadeTransition(
        opacity: CurvedAnimation(parent: a, curve: const Interval(0, 0.8)),
        child: AnimatedBuilder(
          animation: rise,
          child: child,
          builder: (context, child) => Transform.translate(
            offset: Offset(0, 18 * (1 - rise.value)),
            child: Transform.scale(scale: 0.98 + 0.02 * rise.value, child: child),
          ),
        ),
      );
    },
  );
}

/// `.pdf-sheet`
class SheetCard extends StatelessWidget {
  const SheetCard({super.key, required this.children, this.maxWidth = 520, this.scroll = true});
  final List<Widget> children;
  final double maxWidth;
  final bool scroll;
  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    final body = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: (h * 0.86).clamp(0, 720)),
      child: LookBuilder(
        builder: (context, look) => Container(
          padding: const EdgeInsets.all(16),
          decoration: themedSurface(
            BoxDecoration(
              color: GColors.paper,
              borderRadius: BorderRadius.circular(18),
              boxShadow: [BoxShadow(color: GColors.shadow(0.28), blurRadius: 40, offset: const Offset(0, 16))],
            ),
            look: look,
          ),
          child: scroll ? SingleChildScrollView(child: body) : body,
        ),
      ),
    );
  }
}

/// `.pdf-sheet-head` — h3 + "✕ पीछे" pill.
class SheetHead extends StatelessWidget {
  const SheetHead({super.key, required this.title, required this.onBack, this.direct = false});
  final String title;
  final VoidCallback onBack;

  /// "पीछे" taps via [TapTarget] (see [Pressable.direct]).
  final bool direct;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: Row(
          children: [
            Expanded(child: Text(title, style: GText.display(size: 26, color: GColors.maroon, height: 1.3))),
            const SizedBox(width: 12),
            Pill(icon: 'x', label: 'पीछे', onTap: onBack, direct: direct),
          ],
        ),
      );
}

/// Frosted panel used by `.pdf-deck` and `.pdf-done`.
class FrostCard extends StatelessWidget {
  const FrostCard({super.key, required this.child, this.maxWidth = 440, this.alpha = 0.82, this.border, this.radius = 20});
  final Widget child;
  final double maxWidth;
  final double alpha;
  final Color? border;
  final double radius;
  @override
  Widget build(BuildContext context) {
    final h = MediaQuery.sizeOf(context).height;
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: (h * 0.86).clamp(0, 720)),
      child: LookBuilder(builder: (context, look) {
        final frosted = look == 'classic' || look == 'glass';
        final deco = themedSurface(
          BoxDecoration(
            color: GColors.paper.withValues(alpha: alpha),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: border ?? Color.lerp(Colors.white, GColors.gold, 0.3)!),
          ),
          look: look,
          keepColor: border != null,
        );
        final box = Container(padding: const EdgeInsets.all(18), decoration: deco, child: SingleChildScrollView(child: child));
        // Solid styles need no backdrop blur (cheaper to draw); the shadows stay outside.
        if (!frosted) return box;
        return ClipRRect(
          borderRadius: deco.borderRadius?.resolve(TextDirection.ltr) ?? BorderRadius.zero,
          child: BackdropFilter(filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16), child: box),
        );
      }),
    );
  }
}

/// `window.confirm` in the app's own style.
Future<bool> confirmPop(BuildContext context, String message) async {
  final r = await showPop<bool>(
    context,
    (ctx) => SheetCard(
      maxWidth: 440,
      children: [
        Text(message, style: GText.sans(size: 16, color: GColors.brown, height: 1.5)),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: SheetButton(label: 'OK', primary: true, onTap: () => Navigator.pop(ctx, true))),
          const SizedBox(width: 10),
          Expanded(child: SheetButton(label: 'रद्द करें', onTap: () => Navigator.pop(ctx, false))),
        ]),
      ],
    ),
  );
  return r ?? false;
}

/// `window.prompt` in the app's own style.
Future<String?> promptPop(BuildContext context, String title, {String initial = ''}) {
  final c = TextEditingController(text: initial);
  return showPop<String>(
    context,
    (ctx) => SheetCard(
      maxWidth: 440,
      children: [
        Text(title, style: GText.display(size: 22, color: GColors.maroon)),
        const SizedBox(height: 12),
        Container(
          decoration: BoxDecoration(
            color: GColors.paper,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: GColors.saffron, width: 1.5),
          ),
          child: TextField(
            controller: c,
            autofocus: true,
            style: GText.sans(size: 16),
            cursorColor: GColors.saffron,
            onSubmitted: (v) => Navigator.pop(ctx, v),
            decoration: const InputDecoration(border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(horizontal: 14, vertical: 11)),
          ),
        ),
        const SizedBox(height: 16),
        Row(children: [
          Expanded(child: SheetButton(label: 'OK', primary: true, onTap: () => Navigator.pop(ctx, c.text))),
          const SizedBox(width: 10),
          Expanded(child: SheetButton(label: 'रद्द करें', onTap: () => Navigator.pop(ctx))),
        ]),
      ],
    ),
  );
}

/// `Gh` — full-screen page viewer; [ZoomStage] per picture (pinch 1–4×, double tap, pan), Hero from the tapped card.
Future<void> openLightbox(BuildContext context, List<String> paths, {Object? heroTag, Widget? footer, bool closeIcon = true}) {
  return Navigator.of(context).push(PageRouteBuilder<void>(
    opaque: false,
    barrierColor: Colors.transparent,
    transitionDuration: const Duration(milliseconds: 360),
    reverseTransitionDuration: const Duration(milliseconds: 260),
    pageBuilder: (ctx, a, b) => _Lightbox(paths: paths, heroTag: heroTag, footer: footer, closeIcon: closeIcon),
    transitionsBuilder: (ctx, a, b, child) => FadeTransition(opacity: CurvedAnimation(parent: a, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic), child: child),
  ));
}

class _Lightbox extends StatelessWidget {
  const _Lightbox({required this.paths, this.heroTag, this.footer, required this.closeIcon});
  final List<String> paths;
  final Object? heroTag;
  final Widget? footer;
  final bool closeIcon;
  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final stageH = (size.height * 0.78).clamp(0.0, 920.0);
    return Material(
      color: GColors.lightbox,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Pressable(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                    decoration: BoxDecoration(color: GColors.paper, borderRadius: BorderRadius.circular(999)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (closeIcon) ...[const GIcon('x', size: 16, color: GColors.maroon), const SizedBox(width: 6)],
                      Text('बंद', style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon)),
                    ]),
                  ),
                ),
              ),
              Expanded(
                child: ListView(
                  children: [
                    for (var i = 0; i < paths.length; i++) ...[
                      if (i > 0) const SizedBox(height: 12),
                      SizedBox(
                        height: stageH,
                        child: ZoomStage(
                          key: ValueKey('zoom-$i'),
                          child: Center(
                            child: GranthImage(path: paths[i], kind: ShotKind.lightbox, heroTag: i == 0 ? heroTag : null),
                          ),
                        ),
                      ),
                    ],
                    if (footer != null) ...[const SizedBox(height: 12), footer!],
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
