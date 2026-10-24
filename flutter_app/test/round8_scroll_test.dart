import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:granthprabandhan/widgets/bounded_scroll.dart';

/// Round 8 item 4: finger scroll has a bounded range — a hard flick never flies away.
void main() {
  Future<double> flick(WidgetTester t, ScrollPhysics? physics, double speed) async {
    final c = ScrollController();
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(MaterialApp(
      scrollBehavior: physics == null ? null : const BoundedScrollBehavior(),
      home: ListView.builder(controller: c, itemCount: 2000, itemExtent: 80, itemBuilder: (_, i) => Text('$i')),
    ));
    await t.fling(find.byType(ListView), const Offset(0, -300), speed);
    await t.pumpAndSettle();
    return c.offset;
  }

  testWidgets('a hardest flick travels far less than the unbounded default, and stays on the list', (t) async {
    final free = await flick(t, null, 12000);
    final bounded = await flick(t, const BoundedScrollPhysics(), 12000);
    expect(bounded, lessThan(free * 0.9), reason: 'free $free vs bounded $bounded');
    expect(bounded, greaterThan(300), reason: 'still a real flick');
    expect(bounded, lessThan(160000));
  });

  testWidgets('round 9: the cap is flingier than round 8 (3600) but still bounded below the default', (t) async {
    expect(kMaxFling, inInclusiveRange(6000, 7000));
    final hard = await flick(t, const BoundedScrollPhysics(), 20000);
    final old = await flick(t, const BoundedScrollPhysics(), 3600);
    final free = await flick(t, null, 20000);
    expect(hard, greaterThan(old * 1.4), reason: 'clearly flingier than 3600: $hard vs $old');
    expect(hard, lessThan(free), reason: 'still bounded');
    // Same flick twice lands in the same place (deterministic, smooth decay, no overshoot).
    expect(await flick(t, const BoundedScrollPhysics(), 20000), hard);
  });

  testWidgets('a gentle flick is untouched (below the cap)', (t) async {
    final free = await flick(t, null, 1500);
    final bounded = await flick(t, const BoundedScrollPhysics(), 1500);
    expect(bounded, closeTo(free, 1));
  });

  testWidgets('dragging follows the finger exactly; the ends stay clamped', (t) async {
    final c = ScrollController();
    await t.pumpWidget(MaterialApp(
      scrollBehavior: const BoundedScrollBehavior(),
      home: ListView.builder(controller: c, itemCount: 20, itemExtent: 80, itemBuilder: (_, i) => Text('$i')),
    ));
    await t.drag(find.byType(ListView), const Offset(0, -200));
    await t.pumpAndSettle();
    expect(c.offset, closeTo(200, 25), reason: 'slop is the only difference');
    await t.drag(find.byType(ListView), const Offset(0, 900));
    await t.pumpAndSettle();
    expect(c.offset, 0, reason: 'no overscroll stretch at the top');
  });

  test('the cap and the physics', () {
    expect(const BoundedScrollPhysics().maxFlingVelocity, kMaxFling);
    expect(const BoundedScrollPhysics().applyTo(null), isA<BoundedScrollPhysics>());
  });
}
