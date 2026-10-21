import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../state/ui_prefs.dart';
import '../theme/colors.dart';

/// Lucide icons extracted from the original bundle (stroke icons, coloured at runtime).
class GIcon extends StatelessWidget {
  const GIcon(this.name, {super.key, this.size = 16, this.color = GColors.brown});
  final String name;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SvgPicture.asset(
        'assets/icons/$name.svg',
        width: size,
        height: size,
        colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
      );
}

/// Micro-interaction: a gentle press-scale (+ opacity) used on every tappable surface.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.96, this.enabled = true, this.behavior = HitTestBehavior.opaque});
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool enabled;
  final HitTestBehavior behavior;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (_down != v && mounted) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.enabled && widget.onTap != null;
    return GestureDetector(
      behavior: widget.behavior,
      onTapDown: on ? (_) => _set(true) : null,
      onTapUp: on ? (_) => _set(false) : null,
      onTapCancel: on ? () => _set(false) : null,
      onTap: on ? widget.onTap : null,
      child: AnimatedScale(
        scale: _down ? widget.scale : 1,
        duration: Duration(milliseconds: _down ? 90 : 220),
        curve: _down ? Curves.easeOut : Curves.elasticOut,
        child: AnimatedOpacity(
          opacity: widget.enabled ? 1 : 0.6,
          duration: const Duration(milliseconds: 150),
          child: widget.child,
        ),
      ),
    );
  }
}

enum PillTone { plain, maroon, topic }

/// `.pill`
class Pill extends StatelessWidget {
  const Pill({
    super.key,
    this.icon,
    this.trailingIcon,
    required this.label,
    this.tone = PillTone.plain,
    this.onTap,
    this.minHeight = 0,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.fontSize = 12,
    this.weight = FontWeight.w600,
    this.iconSize = 13,
    this.enabled = true,
    this.maxLines,
  });
  final String? icon;
  final String? trailingIcon;
  final String label;
  final PillTone tone;
  final VoidCallback? onTap;
  final double minHeight;
  final EdgeInsets padding;
  final double fontSize;
  final FontWeight weight;
  final double iconSize;
  final bool enabled;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final (bg, fg) = switch (tone) {
      PillTone.maroon => (GColors.pillMaroon, GColors.maroon),
      PillTone.topic => (GColors.pillTopic, GColors.saffronDark),
      PillTone.plain => (GColors.pill, GColors.brown),
    };
    final body = Container(
      constraints: BoxConstraints(minHeight: minHeight),
      padding: padding,
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(999)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[GIcon(icon!, size: iconSize, color: fg), SizedBox(width: 4 + fontSize * 0.25)],
          Flexible(
            child: Text(label,
                maxLines: maxLines,
                overflow: maxLines == null ? null : TextOverflow.ellipsis,
                style: GText.sans(size: fontSize, weight: weight, color: fg, height: 1.3)),
          ),
          if (trailingIcon != null) ...[SizedBox(width: 4 + fontSize * 0.25), GIcon(trailingIcon!, size: iconSize, color: fg)],
        ],
      ),
    );
    if (onTap == null) return body;
    return Pressable(onTap: enabled ? onTap : null, enabled: enabled, scale: 0.93, child: body);
  }
}

enum Tone { saffron, maroon, gold }

/// `.icon-box.tone-*`
class IconBox extends StatelessWidget {
  const IconBox({super.key, required this.tone, required this.icon, this.size = 44, this.radius = 10, this.iconSize = 22});
  final Tone tone;
  final String icon;
  final double size;
  final double radius;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final (colors, fg) = switch (tone) {
      Tone.saffron => ([GColors.saffron, GColors.saffronDark], GColors.paper),
      Tone.maroon => ([GColors.maroonLight, GColors.maroon], GColors.paper),
      Tone.gold => ([GColors.goldLight, GColors.gold], GColors.brown),
    };
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: colors),
      ),
      child: GIcon(icon, size: iconSize, color: fg),
    );
  }
}

/// Decoration for `.card` honouring the hidden `granth-look` styles.
BoxDecoration cardDecoration(String look, {double radius = 12, bool dash = false}) {
  final base = dash
      ? BoxDecoration(
          color: GColors.paper,
          border: Border.all(color: GColors.creamDark),
          borderRadius: BorderRadius.circular(14),
          boxShadow: [BoxShadow(color: GColors.shadow(0.08), blurRadius: 10, offset: const Offset(0, 2))],
        )
      : BoxDecoration(
          color: GColors.paper,
          border: Border.all(color: GColors.creamDark),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: [BoxShadow(color: GColors.shadow(0.08), blurRadius: 8, offset: const Offset(0, 2))],
        );
  if (dash && look != 'combo') return base;
  switch (look) {
    case 'glass':
      return BoxDecoration(
        color: Colors.white.withValues(alpha: 0.42),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(radius),
        boxShadow: [BoxShadow(color: GColors.shadow(0.14), blurRadius: 28, offset: const Offset(0, 10))],
      );
    case 'neu':
      return BoxDecoration(
        color: GColors.cream,
        borderRadius: BorderRadius.circular(18),
        boxShadow: const [
          BoxShadow(color: Color(0xFFE6D3B4), blurRadius: 16, offset: Offset(8, 8)),
          BoxShadow(color: Color(0xFFFFFDF8), blurRadius: 14, offset: Offset(-6, -6)),
        ],
      );
    case 'clay':
      return BoxDecoration(
        color: GColors.paper,
        borderRadius: BorderRadius.circular(28),
        border: const Border(bottom: BorderSide(color: Color(0xFFD6B69B), width: 8)),
        boxShadow: [BoxShadow(color: GColors.shadow(0.14), blurRadius: 24, offset: const Offset(0, 14))],
      );
    case 'material':
      return BoxDecoration(
        color: GColors.paper,
        borderRadius: BorderRadius.circular(4),
        boxShadow: const [
          BoxShadow(color: Color(0x2E000000), blurRadius: 4, offset: Offset(0, 2)),
          BoxShadow(color: Color(0x14000000), blurRadius: 16, offset: Offset(0, 8)),
        ],
      );
    case 'flat':
      return BoxDecoration(color: GColors.cream, border: Border.all(color: GColors.maroon, width: 2));
    case 'bento':
      return BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [GColors.paper, GColors.creamDark]),
        border: Border.all(color: GColors.gold.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(24),
        boxShadow: [BoxShadow(color: GColors.shadow(0.08), blurRadius: 8, offset: const Offset(0, 2))],
      );
    case 'combo':
      return BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment(-0.42, -1),
          end: Alignment(0.42, 1),
          colors: [Color(0xFFFFFDF8), Color(0xFFF8E7CF)],
        ),
        borderRadius: BorderRadius.circular(26),
        border: const Border(top: BorderSide(color: Color(0xE6FFFFFF), width: 1), bottom: BorderSide(color: Color(0xFFD3AA89), width: 8)),
        boxShadow: [BoxShadow(color: GColors.shadow(0.12), blurRadius: 18, offset: const Offset(0, 10))],
      );
    default:
      return base;
  }
}

/// `.card` container.
class GCard extends StatelessWidget {
  const GCard({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.onTap, this.clip = false});
  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final bool clip;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: UiPrefs.I,
      builder: (context, _) {
        final deco = cardDecoration(UiPrefs.I.look);
        final radius = deco.borderRadius?.resolve(TextDirection.ltr) ?? BorderRadius.zero;
        Widget c = DecoratedBox(
          decoration: deco,
          child: clip ? ClipRRect(borderRadius: radius, child: Padding(padding: padding, child: child)) : Padding(padding: padding, child: child),
        );
        if (onTap != null) c = Pressable(onTap: onTap, scale: 0.985, child: c);
        return c;
      },
    );
  }
}

/// `.img-skeleton` — shimmering placeholder.
class Skeleton extends StatefulWidget {
  const Skeleton({super.key, this.height = 120, this.width, this.radius = 8});
  final double height;
  final double? width;
  final double radius;
  @override
  State<Skeleton> createState() => _SkeletonState();
}

class _SkeletonState extends State<Skeleton> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (context, _) => Container(
          height: widget.height,
          width: widget.width ?? double.infinity,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            gradient: LinearGradient(
              colors: const [GColors.creamDark, GColors.cream, GColors.creamDark],
              tileMode: TileMode.repeated,
              transform: _Shift(_c.value),
            ),
          ),
        ),
      );
}

class _Shift extends GradientTransform {
  const _Shift(this.t);
  final double t;
  @override
  Matrix4? transform(Rect bounds, {TextDirection? textDirection}) => Matrix4.translationValues(-bounds.width * 2 * t, 0, 0);
}

/// `.spinner`
class GSpinner extends StatefulWidget {
  const GSpinner({super.key, this.size = 36});
  final double size;
  @override
  State<GSpinner> createState() => _GSpinnerState();
}

class _GSpinnerState extends State<GSpinner> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 800))..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RotationTransition(
        turns: _c,
        child: CustomPaint(size: Size.square(widget.size), painter: _SpinPainter()),
      );
}

class _SpinPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final r = Rect.fromLTWH(1.5, 1.5, size.width - 3, size.height - 3);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = GColors.creamDark;
    canvas.drawOval(r, p);
    canvas.drawArc(r, -math.pi * 3 / 4, math.pi / 2, false, p..color = GColors.saffron);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// `.empty` / `.loading`
class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.title, this.body, this.spinner = false, this.actionLabel, this.onAction});
  final String title;
  final String? body;
  final bool spinner;
  final String? actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 12),
        child: Column(
          children: [
            if (spinner) ...[const GSpinner(), const SizedBox(height: 12)],
            Text(title, textAlign: TextAlign.center, style: GText.display(size: 20, color: GColors.brown)),
            const SizedBox(height: 6),
            if (body != null) Text(body!, textAlign: TextAlign.center, style: GText.sans(size: 16, color: GColors.muted, height: 1.5)),
            if (actionLabel != null && onAction != null) ...[
              const SizedBox(height: 16),
              Pressable(
                onTap: onAction,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  decoration: BoxDecoration(color: GColors.maroon, borderRadius: BorderRadius.circular(8)),
                  child: Text(actionLabel!, style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.paper)),
                ),
              ),
            ],
          ],
        ),
      );
}

/// The mala logo (`Kn`): ring, 14 beads and the guru bead.
class MalaLogo extends StatelessWidget {
  const MalaLogo({super.key, this.size = 32, this.progress = 1});
  final double size;

  /// 0..1 — how many beads are drawn (used by the opening animation).
  final double progress;
  @override
  Widget build(BuildContext context) => CustomPaint(size: Size.square(size), painter: _MalaPainter(progress));
}

class _MalaPainter extends CustomPainter {
  _MalaPainter(this.progress);
  final double progress;
  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 48;
    canvas.scale(s);
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..color = GColors.maroon;
    canvas.drawArc(Rect.fromCircle(center: const Offset(24, 24), radius: 15), -math.pi / 2, math.pi * 2 * progress.clamp(0, 1), false, ring);
    final bead = Paint()..color = GColors.maroon;
    final shown = (14 * progress).ceil().clamp(0, 14);
    for (var t = 0; t < shown; t++) {
      final n = (t / 14) * math.pi * 2 - math.pi / 2;
      final local = ((14 * progress) - t).clamp(0.0, 1.0);
      canvas.drawCircle(Offset(24 + math.cos(n) * 15, 24 + math.sin(n) * 15), 2.15 * Curves.easeOutBack.transform(local), bead);
    }
    if (progress >= 0.98) {
      canvas.drawCircle(const Offset(24, 7.2), 3.3, Paint()..color = GColors.goldLight);
      canvas.drawCircle(
          const Offset(24, 7.2),
          3.3,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = GColors.maroon);
    }
  }

  @override
  bool shouldRepaint(covariant _MalaPainter old) => old.progress != progress;
}

/// `.logo-icon`
class LogoIcon extends StatelessWidget {
  const LogoIcon({super.key, this.size = 48, this.progress = 1});
  final double size;
  final double progress;
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(size / 4),
          gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [GColors.saffron, GColors.gold]),
        ),
        child: MalaLogo(size: size * 2 / 3, progress: progress),
      );
}

/// Animated `.grid-switch` — the maroon pill slides between "1×1 / 2×2 / 3×3".
class GridSwitch extends StatelessWidget {
  const GridSwitch({super.key, required this.options, required this.value, required this.onChanged});
  final List<int> options;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    const w = 44.0;
    const h = 36.0;
    final idx = math.max(0, options.indexOf(value));
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.creamDark), borderRadius: BorderRadius.circular(10)),
      child: SizedBox(
        width: options.length * w + (options.length - 1) * 2,
        height: h,
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic,
              left: idx * (w + 2),
              top: 0,
              width: w,
              height: h,
              child: DecoratedBox(decoration: BoxDecoration(color: GColors.maroon, borderRadius: BorderRadius.circular(8))),
            ),
            Row(
              children: [
                for (var i = 0; i < options.length; i++) ...[
                  if (i > 0) const SizedBox(width: 2),
                  Semantics(
                    button: true,
                    selected: options[i] == value,
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () => onChanged(options[i]),
                      child: SizedBox(
                        width: w,
                        height: h,
                        child: Center(
                          child: AnimatedDefaultTextStyle(
                            duration: const Duration(milliseconds: 200),
                            style: GText.sans(size: 13, weight: FontWeight.w700, color: options[i] == value ? GColors.paper : GColors.maroon),
                            child: Text('${options[i]}×${options[i]}'),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// `.form-control` search input with the saffron focus ring.
class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.placeholder, required this.onChanged, this.initial = '', this.debounce = const Duration(milliseconds: 200)});
  final String placeholder;

  /// Called [debounce] after the last keystroke (immediately when cleared or on "search"),
  /// so typing stays smooth while the list filters.
  final ValueChanged<String> onChanged;
  final String initial;
  final Duration debounce;
  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  late final TextEditingController _c = TextEditingController(text: widget.initial);
  final FocusNode _f = FocusNode();
  Timer? _t;
  late String _sent = widget.initial;

  void _changed(String v) {
    _t?.cancel();
    if (v.trim().isEmpty || widget.debounce == Duration.zero) {
      _emit(v);
    } else {
      _t = Timer(widget.debounce, () => _emit(v));
    }
  }

  void _emit(String v) {
    _t?.cancel();
    if (!mounted || v == _sent) return;
    _sent = v;
    widget.onChanged(v);
  }

  @override
  void initState() {
    super.initState();
    _f.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    _c.dispose();
    _f.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final focus = _f.hasFocus;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      decoration: BoxDecoration(
        color: GColors.paper,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: focus ? GColors.saffron : GColors.creamDark, width: 1.5),
        boxShadow: focus ? [BoxShadow(color: GColors.saffron.withValues(alpha: 0.18), spreadRadius: 3)] : const [],
      ),
      child: TextField(
        controller: _c,
        focusNode: _f,
        onChanged: _changed,
        onSubmitted: _emit,
        onTapOutside: (_) => _f.unfocus(),
        style: GText.sans(size: 16, color: GColors.text),
        cursorColor: GColors.saffron,
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          isDense: true,
          border: InputBorder.none,
          hintText: widget.placeholder,
          hintStyle: GText.sans(size: 16, color: GColors.muted.withValues(alpha: 0.8)),
          contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
        ),
      ),
    );
  }
}

/// `.pdf-ok` / `.pdf-back`
class SheetButton extends StatelessWidget {
  const SheetButton({super.key, required this.label, this.primary = false, this.onTap, this.icon, this.enabled = true});
  final String label;
  final bool primary;
  final VoidCallback? onTap;
  final String? icon;
  final bool enabled;
  @override
  Widget build(BuildContext context) {
    final fg = primary ? GColors.paper : GColors.maroon;
    return Pressable(
      onTap: enabled ? onTap : null,
      enabled: enabled,
      child: Container(
        constraints: const BoxConstraints(minHeight: 52),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: primary ? GColors.maroon : Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: primary ? null : Border.all(color: GColors.gold),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[GIcon(icon!, size: 18, color: fg), const SizedBox(width: 8)],
            Flexible(child: Text(label, textAlign: TextAlign.center, style: GText.sans(size: 17, weight: FontWeight.w700, color: fg))),
          ],
        ),
      ),
    );
  }
}

/// Staggered entry: fades and slides each list item in, offset by its index.
class Entry extends StatefulWidget {
  const Entry({super.key, required this.index, required this.child, this.dx = 0});
  final int index;
  final Widget child;
  final double dx;
  @override
  State<Entry> createState() => _EntryState();
}

class _EntryState extends State<Entry> with SingleTickerProviderStateMixin {
  late final AnimationController _c;
  late final Animation<double> _a;

  @override
  void initState() {
    super.initState();
    final i = widget.index.clamp(0, 12);
    _c = AnimationController(vsync: this, duration: Duration(milliseconds: 380 + i * 45));
    _a = CurvedAnimation(parent: _c, curve: Interval(i * 45 / (380 + i * 45), 1, curve: Curves.easeOutCubic));
    if (widget.index > 12) {
      _c.value = 1;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _a,
        child: widget.child,
        builder: (context, child) {
          final t = _a.value;
          if (t >= 1) return child!;
          return Opacity(
            opacity: t,
            child: Transform.translate(offset: Offset(widget.dx * (1 - t), 18 * (1 - t)), child: child),
          );
        },
      );
}
