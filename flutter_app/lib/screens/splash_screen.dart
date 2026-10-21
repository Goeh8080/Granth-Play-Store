import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/colors.dart';
import '../widgets/common.dart';

/// Animated opening: the native white splash hands over to this — the mala beads string
/// themselves around the logo, a saffron glow blooms, the title rises, then the whole
/// card zooms out to reveal the app (the original only showed a static splash for 2.6 s).
class AnimatedSplash extends StatefulWidget {
  const AnimatedSplash({
    super.key,
    required this.child,
    this.ready,
    this.duration = const Duration(milliseconds: 1900),
    this.maxWait = const Duration(milliseconds: 2600),
    this.hardLimit = const Duration(milliseconds: 3500),
  });
  final Widget child;

  /// Optional work the splash may wait for, but only until [maxWait] after start.
  final Future<void>? ready;
  final Duration duration;

  /// Latest moment the zoom-out starts, whatever [ready] is doing (network, cache…).
  final Duration maxWait;

  /// Fail-safe: the app is shown at this point even if an animation never completes.
  final Duration hardLimit;

  /// Present only while the opening overlay is on screen (used by tests).
  static const overlayKey = ValueKey('splash-overlay');
  @override
  State<AnimatedSplash> createState() => _AnimatedSplashState();
}

class _AnimatedSplashState extends State<AnimatedSplash> with TickerProviderStateMixin {
  late final AnimationController _intro = AnimationController(vsync: this, duration: widget.duration);
  late final AnimationController _out = AnimationController(vsync: this, duration: const Duration(milliseconds: 520));
  bool _done = false;
  Timer? _failSafe;
  Timer? _gateTimer;

  /// Completes [AnimatedSplash.maxWait] after start, or as soon as the splash finishes.
  final Completer<void> _gate = Completer<void>();

  @override
  void initState() {
    super.initState();
    _failSafe = Timer(widget.hardLimit, _finish);
    _gateTimer = Timer(widget.maxWait, _openGate);
    _run();
  }

  void _openGate() {
    if (!_gate.isCompleted) _gate.complete();
  }

  void _finish() {
    _failSafe?.cancel();
    _gateTimer?.cancel();
    _openGate();
    if (mounted && !_done) setState(() => _done = true);
  }

  /// Completes with [f] or with the gate, whichever is first; never throws.
  Future<void> _orGate(Future<void> f) => Future.any<void>([f.catchError((Object _) {}), _gate.future]);

  Future<void> _run() async {
    try {
      // Intro (1.9 s) → wait for [ready] only until maxWait → zoom out (0.52 s).
      await _orGate(_intro.forward().orCancel);
      await _orGate(widget.ready ?? Future<void>.value());
      if (!mounted || _done) return;
      _gateTimer?.cancel();
      await _out.forward().orCancel.catchError((Object _) {});
    } catch (_) {
      // Never let the opening animation block the app.
    }
    _finish();
  }

  @override
  void dispose() {
    _failSafe?.cancel();
    _gateTimer?.cancel();
    _intro.dispose();
    _out.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_done) return widget.child;
    return Stack(key: AnimatedSplash.overlayKey, fit: StackFit.expand, children: [
      // The app underneath scales up into place as the splash leaves.
      AnimatedBuilder(
        animation: _out,
        child: widget.child,
        builder: (context, child) {
          final t = Curves.easeOutCubic.transform(_out.value);
          return Opacity(opacity: t, child: Transform.scale(scale: 0.94 + 0.06 * t, child: child));
        },
      ),
      AnimatedBuilder(
        animation: Listenable.merge([_intro, _out]),
        builder: (context, _) {
          final v = _intro.value;
          final o = Curves.easeInCubic.transform(_out.value);
          final beads = Curves.easeInOut.transform((v / 0.6).clamp(0, 1));
          final pop = Curves.elasticOut.transform(((v - 0.05) / 0.5).clamp(0, 1));
          final glow = Curves.easeOut.transform(((v - 0.45) / 0.4).clamp(0, 1));
          final title = Curves.easeOutCubic.transform(((v - 0.55) / 0.4).clamp(0, 1));
          return IgnorePointer(
            ignoring: _out.value > 0.3,
            child: Opacity(
              opacity: 1 - o,
              child: Container(
                color: Colors.white,
                alignment: Alignment.center,
                child: Transform.scale(
                  scale: 1 + 0.35 * o,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(36),
                        boxShadow: [BoxShadow(color: GColors.saffron.withValues(alpha: 0.45 * glow), blurRadius: 48 * glow, spreadRadius: 6 * glow)],
                      ),
                      child: Transform.scale(scale: 0.6 + 0.4 * pop, child: LogoIcon(size: 144, progress: beads)),
                    ),
                    const SizedBox(height: 28),
                    Opacity(
                      opacity: title,
                      child: Transform.translate(
                        offset: Offset(0, 16 * (1 - title)),
                        child: Text('ग्रंथ प्रबंधन', style: GText.display(size: 34, color: GColors.maroon, letterSpacing: 0.5)),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          );
        },
      ),
    ]);
  }
}
