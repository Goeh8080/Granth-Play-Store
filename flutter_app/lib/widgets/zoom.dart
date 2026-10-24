import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import 'common.dart' show TouchCount;

/// Scale + offset of a zoomed view. The child is drawn at `offset + point * scale`
/// (origin top-left), so its layout size never changes.
@immutable
class ZoomView {
  const ZoomView(this.scale, this.offset);
  static const identity = ZoomView(1, Offset.zero);
  final double scale;
  final Offset offset;

  Matrix4 get matrix => Matrix4.identity()
    ..translateByDouble(offset.dx, offset.dy, 0, 1)
    ..scaleByDouble(scale, scale, 1, 1);

  /// Keeps the zoomed content covering the box: it can never drift off-screen or show a gap.
  ZoomView clamp(Size box) {
    final s = scale < 1 ? 1.0 : scale;
    final minX = box.width - box.width * s;
    final minY = box.height - box.height * s;
    return ZoomView(s, Offset(offset.dx.clamp(minX, 0.0), offset.dy.clamp(minY, 0.0)));
  }

  /// Zoom to [s] keeping [focal] (a point in the box) still.
  ZoomView zoomAt(double s, Offset focal) {
    final q = (focal - offset) / scale;
    return ZoomView(s, focal - q * s);
  }

  static ZoomView lerp(ZoomView a, ZoomView b, double t) => ZoomView(a.scale + (b.scale - a.scale) * t, Offset.lerp(a.offset, b.offset, t)!);
}

/// Picture viewer stage (`PinchView` / `.zoom-stage` in the original): pinch 1–4×, pan when
/// zoomed, bounded to the stage, snaps back to 1× below 1.08×. Like a phone gallery it also
/// zooms in / out with a double tap at the tapped point, and a flick keeps gliding a little.
///
/// Gestures: two fingers on the stage always belong to the stage (the original sets
/// `touch-action: none`), so the list around it or the app-wide zoom can't steal the pinch.
/// At 1× one finger still scrolls the page; once zoomed, one finger pans the picture.
class ZoomStage extends StatefulWidget {
  const ZoomStage({super.key, required this.child, this.maxScale = 4, this.doubleTapScale = 2.5});
  final Widget child;
  final double maxScale;
  final double doubleTapScale;

  @override
  State<ZoomStage> createState() => ZoomStageState();
}

class ZoomStageState extends State<ZoomStage> with SingleTickerProviderStateMixin {
  ZoomView _v = ZoomView.identity;
  ZoomView _start = ZoomView.identity;
  Offset _focal0 = Offset.zero;
  Size _box = Size.zero;
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 280));
  ZoomView _animFrom = ZoomView.identity;
  ZoomView _animTo = ZoomView.identity;
  Curve _curve = Curves.easeOutCubic;

  // double tap
  int _tapDownAt = 0;
  Offset _tapDownPos = Offset.zero;
  int _lastTapAt = 0;
  Offset _lastTapPos = Offset.zero;
  int _pointers = 0;
  bool _multi = false;

  @visibleForTesting
  ZoomView get view => _v;

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => setState(() => _v = ZoomView.lerp(_animFrom, _animTo, _curve.transform(_anim.value))));
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  void _animateTo(ZoomView to, {Duration ms = const Duration(milliseconds: 280), Curve curve = Curves.easeOutCubic}) {
    _animFrom = _v;
    _animTo = to.clamp(_box);
    _curve = curve;
    _anim.duration = ms;
    _anim.forward(from: 0);
  }

  bool _moved = false;

  void _onStart(ScaleStartDetails d) {
    _moved = false;
    _start = _v;
    _focal0 = d.localFocalPoint;
  }

  void _onUpdate(ScaleUpdateDetails d) {
    if (!_moved) {
      // First real movement: take over from any running animation (double tap / snap).
      _moved = true;
      _anim.stop();
      _start = _v;
      _focal0 = d.localFocalPoint - (d.localFocalPoint - _focal0);
    }
    final s = (_start.scale * d.scale).clamp(1.0, widget.maxScale);
    final q = (_focal0 - _start.offset) / _start.scale;
    final next = ZoomView(s, d.localFocalPoint - q * s).clamp(_box);
    if (next.scale != _v.scale || next.offset != _v.offset) setState(() => _v = next);
  }

  void _onEnd(ScaleEndDetails d) {
    if (!_moved) return; // a plain tap (e.g. part of a double tap)
    _moved = false;
    if (_v.scale <= 1.08) {
      _animateTo(ZoomView.identity);
      return;
    }
    final vel = d.velocity.pixelsPerSecond;
    if (vel.distance > 200 && d.pointerCount == 0) {
      // Short glide after a flick, then stops at the edge.
      _animateTo(ZoomView(_v.scale, _v.offset + vel * 0.18), ms: const Duration(milliseconds: 420), curve: Curves.decelerate);
    }
  }

  void _doubleTap(Offset at) {
    if (_v.scale > 1.05) {
      _animateTo(ZoomView.identity);
    } else {
      _animateTo(_v.zoomAt(widget.doubleTapScale, at));
    }
  }

  void _down(PointerDownEvent e) {
    _pointers++;
    if (_pointers > 1) _multi = true;
    _tapDownAt = e.timeStamp.inMilliseconds;
    _tapDownPos = e.localPosition;
  }

  void _up(PointerEvent e) {
    _pointers = math.max(0, _pointers - 1);
    final wasMulti = _multi;
    if (_pointers == 0) _multi = false;
    if (e is! PointerUpEvent || wasMulti) return;
    final t = e.timeStamp.inMilliseconds;
    if (t - _tapDownAt > 260 || (e.localPosition - _tapDownPos).distance > kTouchSlop) return;
    if (t - _lastTapAt < 320 && (e.localPosition - _lastTapPos).distance < 48) {
      _lastTapAt = 0;
      _doubleTap(e.localPosition);
    } else {
      _lastTapAt = t;
      _lastTapPos = e.localPosition;
    }
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        _box = c.biggest;
        return Listener(
          onPointerDown: _down,
          onPointerUp: _up,
          onPointerCancel: _up,
          child: RawGestureDetector(
            behavior: HitTestBehavior.opaque,
            gestures: {
              StageScaleRecognizer: GestureRecognizerFactoryWithHandlers<StageScaleRecognizer>(
                () => StageScaleRecognizer(zoomed: () => _v.scale > 1.01),
                (r) => r
                  ..onStart = _onStart
                  ..onUpdate = _onUpdate
                  ..onEnd = _onEnd,
              ),
            },
            child: ClipRect(
              clipBehavior: AppZoom.suspended.value > 0 ? Clip.none : Clip.hardEdge,
              child: Transform(transform: _v.matrix, child: RepaintBoundary(child: widget.child)),
            ),
          ),
        );
      });
}

/// Scale recognizer that claims the gesture as soon as a second finger is down (or at once
/// when the picture is zoomed), so a scrolling parent can't take a pinch away.
class StageScaleRecognizer extends ScaleGestureRecognizer {
  StageScaleRecognizer({required this.zoomed});
  final bool Function() zoomed;
  final Set<int> _down = {};

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    _down.add(event.pointer);
    if (_down.length >= 2 || zoomed()) resolve(GestureDisposition.accepted);
  }

  @override
  void handleEvent(PointerEvent event) {
    super.handleEvent(event);
    if (event is PointerUpEvent || event is PointerCancelEvent) _down.remove(event.pointer);
  }

  @override
  void rejectGesture(int pointer) {
    _down.remove(pointer);
    super.rejectGesture(pointer);
  }
}

/// App-wide "desktop mode" zoom. The original runs in a WebView with
/// `<meta name="viewport" content="width=device-width, initial-scale=1, minimum-scale=1,
/// maximum-scale=5, user-scalable=yes">` and `builtInZoomControls`, so every screen can be
/// pinched 1–5× while the layout stays the same. `touch-action: manipulation` turns off
/// double-tap zoom there, so there is none here either.
///
/// Two fingers anywhere zoom / pan the whole app (layout never re-flows; taps land on the
/// zoomed content). When zoomed, a sideways one-finger drag pans; up / down still scrolls
/// the lists. Pinch on a picture viewer zooms the picture, not the app.
class AppZoom extends StatefulWidget {
  const AppZoom({super.key, required this.child, this.maxScale = 5});
  final Widget child;
  final double maxScale;

  /// Current app zoom (for tests / debugging).
  static final ValueNotifier<ZoomView> current = ValueNotifier(ZoomView.identity);

  /// Screens that bring their own zoom and a native view (the Photo Highlighter WebView) turn
  /// the app zoom off while they are open: no pinch recogniser in the way and no clip layer
  /// over the platform view. Counter, so nested users are safe.
  static final ValueNotifier<int> suspended = ValueNotifier(0);

  @override
  State<AppZoom> createState() => _AppZoomState();
}

class _AppZoomState extends State<AppZoom> with SingleTickerProviderStateMixin {
  ZoomView _v = ZoomView.identity;
  Size _box = Size.zero;
  late final AnimationController _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 240));
  ZoomView _from = ZoomView.identity;
  ZoomView _to = ZoomView.identity;

  void _onSuspend() {
    if (AppZoom.suspended.value > 0 && _v.scale != 1) {
      _anim.stop();
      _set(ZoomView.identity);
    } else if (mounted) {
      setState(() {});
    }
  }

  @override
  void initState() {
    super.initState();
    _anim.addListener(() => _set(ZoomView.lerp(_from, _to, Curves.easeOutCubic.transform(_anim.value))));
    AppZoom.suspended.addListener(_onSuspend);
  }

  @override
  void dispose() {
    AppZoom.suspended.removeListener(_onSuspend);
    _anim.dispose();
    super.dispose();
  }

  void _set(ZoomView v) {
    if (!mounted) return;
    setState(() => _v = v);
    AppZoom.current.value = v;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, c) {
        _box = c.biggest;
        if (_v.scale > 1) {
          final k = _v.clamp(_box);
          if (k.offset != _v.offset) _v = k;
        }
        // Counts fingers for the whole app, so a tap button can tell a pinch from a tap.
        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) => TouchCount.down(),
          onPointerUp: (_) => TouchCount.up(),
          onPointerCancel: (_) => TouchCount.up(),
          child: RawGestureDetector(
            behavior: HitTestBehavior.translucent,
            gestures: {
              AppPinchRecognizer: GestureRecognizerFactoryWithHandlers<AppPinchRecognizer>(
                () => AppPinchRecognizer(),
                (r) => r
                  ..zoomed = (() => _v.scale > 1.01)
                  ..onBegin = () {
                    _anim.stop();
                    return _v;
                  }
                  ..onChange = (start, scale, focal0, focal) {
                    final s = (start.scale * scale).clamp(1.0, widget.maxScale);
                    final q = (focal0 - start.offset) / start.scale;
                    _set(ZoomView(s, focal - q * s).clamp(_box));
                  }
                  ..onFinish = () {
                    if (_v.scale <= 1.05 && _v.scale != 1) {
                      _from = _v;
                      _to = ZoomView.identity;
                      _anim.forward(from: 0);
                    }
                  },
              ),
            },
            child: ClipRect(
              clipBehavior: AppZoom.suspended.value > 0 ? Clip.none : Clip.hardEdge,
              child: Transform(transform: _v.matrix, child: RepaintBoundary(child: widget.child)),
            ),
          ),
        );
      });
}

typedef ZoomChange = void Function(ZoomView start, double scale, Offset focal0, Offset focal);

/// Accepts two-finger gestures (pinch + pan) at once; one finger only when zoomed and the
/// drag is mostly sideways. Never takes a single tap or a vertical scroll.
class AppPinchRecognizer extends OneSequenceGestureRecognizer {
  AppPinchRecognizer();

  bool Function() zoomed = () => false;
  ZoomView Function()? onBegin;
  ZoomChange? onChange;
  VoidCallback? onFinish;

  final Map<int, Offset> _pts = {};
  final Map<int, Offset> _downAt = {};
  bool _accepted = false;
  ZoomView _start = ZoomView.identity;
  Offset _focal0 = Offset.zero;
  double _dist0 = 0;

  Offset get _focal {
    var o = Offset.zero;
    for (final p in _pts.values) {
      o += p;
    }
    return _pts.isEmpty ? o : o / _pts.length.toDouble();
  }

  double get _dist {
    if (_pts.length < 2) return 0;
    final v = _pts.values.toList();
    return (v[0] - v[1]).distance;
  }

  void _baseline() {
    _start = onBegin?.call() ?? ZoomView.identity;
    _focal0 = _focal;
    _dist0 = _dist;
  }

  @override
  void addAllowedPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer, event.transform);
    _pts[event.pointer] = event.position;
    _downAt[event.pointer] = event.position;
    if (_accepted) {
      _baseline();
    } else if (_pts.length >= 2) {
      resolve(GestureDisposition.accepted);
    }
  }

  @override
  void handleEvent(PointerEvent event) {
    if (event is PointerMoveEvent) {
      _pts[event.pointer] = event.position;
      if (_accepted) {
        final scale = (_dist0 > 0 && _pts.length >= 2) ? _dist / _dist0 : 1.0;
        onChange?.call(_start, scale, _focal0, _focal);
      } else if (_pts.length == 1 && zoomed()) {
        final d = event.position - (_downAt[event.pointer] ?? event.position);
        if (d.dx.abs() > kTouchSlop && d.dx.abs() > d.dy.abs() * 1.2) {
          resolve(GestureDisposition.accepted);
        } else if (d.dy.abs() > kTouchSlop) {
          resolve(GestureDisposition.rejected);
        }
      }
    } else if (event is PointerUpEvent || event is PointerCancelEvent) {
      _pts.remove(event.pointer);
      _downAt.remove(event.pointer);
      if (_accepted && _pts.isNotEmpty) _baseline();
      stopTrackingPointer(event.pointer);
    }
  }

  @override
  void acceptGesture(int pointer) {
    // Arena sweep after the finger is already up (nobody else wanted a plain tap): ignore.
    if (_accepted || _pts.isEmpty) return;
    _accepted = true;
    _baseline();
  }

  @override
  void rejectGesture(int pointer) {
    _pts.remove(pointer);
    _downAt.remove(pointer);
    stopTrackingPointer(pointer);
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    if (_accepted) onFinish?.call();
    _accepted = false;
    _pts.clear();
    _downAt.clear();
  }

  @override
  String get debugDescription => 'app pinch';
}
