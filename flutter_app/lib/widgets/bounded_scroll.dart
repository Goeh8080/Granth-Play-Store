import 'package:flutter/material.dart' show MaterialScrollBehavior;
import 'package:flutter/widgets.dart';

/// Finger scrolling with a bounded range: a flick can carry the list at most [kMaxFling] px/s,
/// so one swipe never throws a long list from top to bottom (ashok's WebView has the same
/// ~"momentum scrolling" cap of a normal phone browser). Dragging follows the finger exactly;
/// only the release velocity is limited. Edges stay clamped (no overscroll stretch).
const double kMaxFling = 6500;

class BoundedScrollPhysics extends ClampingScrollPhysics {
  const BoundedScrollPhysics({super.parent});

  @override
  BoundedScrollPhysics applyTo(ScrollPhysics? ancestor) => BoundedScrollPhysics(parent: buildParent(ancestor));

  @override
  double get maxFlingVelocity => kMaxFling;

  @override
  Simulation? createBallisticSimulation(ScrollMetrics position, double velocity) =>
      super.createBallisticSimulation(position, velocity.clamp(-kMaxFling, kMaxFling));
}

/// Gives every scrollable below it [BoundedScrollPhysics] (Android look: clamped, no glow change).
class BoundedScrollBehavior extends MaterialScrollBehavior {
  const BoundedScrollBehavior();
  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const BoundedScrollPhysics();
}
