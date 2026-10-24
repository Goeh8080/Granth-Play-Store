import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../state/motion.dart';

/// Remembers which cards of ONE screen visit have already played their entrance, so
/// scrolling back up, a rebuild, a sync tick or a re-created sliver child never replays it.
/// Each list screen owns one ledger (its State lives exactly as long as the visit).
class PopLedger {
  final Set<String> _done = {};
  bool played(String key) => _done.contains(key);
  void mark(String key) => _done.add(key);
  void clear() {
    _done.clear();
    _opened.clear();
  }

  final Map<String, Duration> _opened = {};

  /// Only cards built while a screen (or a re-laid-out grid, [group]) is opening pop. A card
  /// that scrolls into view later is simply there: nothing animates under the finger, and a
  /// card measured while it scrolls is where it will rest.
  bool opening(
    String group,
    Duration now, [
    Duration window = const Duration(milliseconds: 400),
  ]) {
    final start = _opened.putIfAbsent(group, () => now);
    return now - start <= window;
  }

  int get length => _done.length;
}

/// How many of the first cards get a staggered delay; later cards pop without waiting.
const ValueKey<String> kCardPopKey = ValueKey('card-pop');
const ValueKey<String> kRevealKey = ValueKey('card-reveal');
const int kPopStagger = 12;
const Duration kPopStep = Duration(milliseconds: 45);
const Duration kPopTime = Duration(milliseconds: 420);

/// Timeline of one card's entrance, shared with [Reveal] (the Granth card's inner stagger).
class PopTimeline extends InheritedWidget {
  const PopTimeline({
    super.key,
    required this.animation,
    required this.delayMs,
    required this.totalMs,
    required super.child,
  });
  final Animation<double> animation;
  final int delayMs;
  final int totalMs;

  static PopTimeline? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<PopTimeline>();

  /// Interval of [fromMs]..[toMs] measured from the moment this card's turn starts.
  Animation<double> span(
    int fromMs,
    int toMs, [
    Curve curve = Curves.easeOut,
  ]) => CurvedAnimation(
    parent: animation,
    curve: Interval(
      ((delayMs + fromMs) / totalMs).clamp(0.0, 1.0),
      ((delayMs + toMs) / totalMs).clamp(0.0, 1.0),
      curve: curve,
    ),
  );

  @override
  bool updateShouldNotify(PopTimeline old) => old.animation != animation;
}

/// Scale-pop of a list card: `ScaleTransition` over a `CurvedAnimation` (420 ms, `easeOutBack`),
/// staggered by index for the first [kPopStagger] cards only, once per card per screen visit.
///
/// Paint-only (a transform inside a `RepaintBoundary`): no layout shift, so the scroll offset
/// that Round 7 restores is untouched. Off when "एनिमेशन" is कम or the phone asks for no
/// animation. [tailMs] lengthens the timeline for children that fade in after the pop.
class CardPop extends StatefulWidget {
  const CardPop({
    super.key,
    required this.ledger,
    required this.id,
    this.group = '',
    required this.index,
    this.tailMs = 0,
    required this.child,
  });
  final PopLedger ledger;
  final String id;
  final String group;
  final int index;
  final int tailMs;
  final Widget child;

  /// Where the card starts from. Not 0: a card growing out of a point looks like a glitch on a
  /// small phone; 0.6 is clearly a "pop" and keeps the matrix invertible for hit-testing.
  static const double from = 0.6;

  @override
  State<CardPop> createState() => _CardPopState();
}

class _CardPopState extends State<CardPop> with SingleTickerProviderStateMixin {
  AnimationController? _c;
  Animation<double>? _scale;
  PopTimeline? _timeline;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final key = 'p:${widget.id}';
    if (!Motion.on(context) || widget.ledger.played(key)) return;
    widget.ledger.mark(key);
    if (!widget.ledger.opening(widget.group, SchedulerBinding.instance.currentFrameTimeStamp)) {
      return;
    }
    final delay = math.min(widget.index, kPopStagger) * kPopStep.inMilliseconds;
    final total = delay + kPopTime.inMilliseconds + widget.tailMs;
    final c = _c = AnimationController(
      vsync: this,
      duration: Duration(milliseconds: total),
    );
    _scale = Tween<double>(begin: CardPop.from, end: 1).animate(
      CurvedAnimation(
        parent: c,
        curve: Interval(
          delay / total,
          (delay + kPopTime.inMilliseconds) / total,
          curve: Curves.easeOutBack,
        ),
      ),
    );
    _timeline = PopTimeline(
      animation: c,
      delayMs: delay,
      totalMs: total,
      child: const SizedBox(),
    );
    c.forward();
  }

  @override
  void dispose() {
    _c?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scale = _scale;
    if (scale == null) return RepaintBoundary(child: widget.child);
    final t = _timeline!;
    return RepaintBoundary(
      child: PopTimeline(
        animation: t.animation,
        delayMs: t.delayMs,
        totalMs: t.totalMs,
        child: ScaleTransition(key: kCardPopKey, scale: scale, child: widget.child),
      ),
    );
  }
}

/// A part of a card that fades in on the card's [PopTimeline] (the Granth card's inner
/// stagger: image, then title, then buttons). Opacity only: layout never changes. Without a
/// timeline (animations off, or already played) it is just the child.
class Reveal extends StatefulWidget {
  const Reveal({
    super.key,
    required this.fromMs,
    required this.toMs,
    required this.child,
  });
  final int fromMs;
  final int toMs;
  final Widget child;
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  Animation<double>? _a;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_decided) return;
    _decided = true;
    final t = PopTimeline.maybeOf(context);
    if (t != null) _a = t.span(widget.fromMs, widget.toMs);
  }

  @override
  Widget build(BuildContext context) => _a == null
      ? widget.child
      : FadeTransition(key: kRevealKey, opacity: _a!, child: widget.child);
}

/// Blur-focus entrance: `ImageFiltered(blur 12·(1−t))` + `Opacity(t)`. At t == 1 the filter and
/// the opacity layer are dropped (no cost while the popup just sits there); the child keeps its
/// State across that switch (GlobalKey), so a pager or a field inside never resets.
class BlurFocus extends StatefulWidget {
  const BlurFocus({
    super.key,
    required this.animation,
    required this.child,
    this.maxBlur = 12,
  });
  final Animation<double> animation;
  final Widget child;
  final double maxBlur;
  @override
  State<BlurFocus> createState() => _BlurFocusState();
}

class _BlurFocusState extends State<BlurFocus> {
  final GlobalKey _slot = GlobalKey();

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.animation,
    child: KeyedSubtree(key: _slot, child: widget.child),
    builder: (context, child) {
      final t = widget.animation.value.clamp(0.0, 1.0);
      if (t >= 1) return child!;
      final s = widget.maxBlur * (1 - t);
      return Opacity(
        opacity: t,
        child: s < 0.05
            ? child
            : ImageFiltered(
                imageFilter: ui.ImageFilter.blur(
                  sigmaX: s,
                  sigmaY: s,
                  tileMode: ui.TileMode.decal,
                ),
                child: child,
              ),
      );
    },
  );
}
