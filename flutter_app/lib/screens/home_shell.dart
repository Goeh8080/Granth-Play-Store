import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter/services.dart';

import '../highlighter/highlighter_launcher.dart';
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/native_bridge.dart';
import '../services/pdf_notify.dart';
import '../services/pdf_queue.dart';
import '../state/places.dart';
import '../state/router.dart';
import '../state/toast.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/bounded_scroll.dart';
import '../widgets/common.dart';
import '../widgets/pdf_sheets.dart';
import 'dashboard_screen.dart';
import 'ai_screen.dart';
import 'gallery_screen.dart';
import 'shelves_screen.dart';
import 'pramans_screen.dart';
import 'topics_screen.dart';

/// `cg` — the app root: mast, stats bar, hamburger nav, sync strip, panel, to-top, toast.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});
  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with TickerProviderStateMixin {
  final ScrollController _scroll = ScrollController();
  late final AnimationController _panelIn = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);
  final ValueNotifier<bool> _showTop = ValueNotifier(false);
  String _routeKey = '';
  bool _deckOpen = false;
  bool _exitOpen = false;

  AppNav get nav => AppNav.I;

  @override
  void initState() {
    super.initState();
    _routeKey = nav.route.key;
    nav.addListener(_onNav);
    nav.beforeLeave = _savePlace;
    nav.onExitRequest = _askExit;
    PdfQueue.I.addListener(_onQueue);
    PdfQueue.I.finished.addListener(_onFinished);
    PdfNotify.I.attach();
    PdfNotify.I.hint.addListener(_onNotifHint);
    _scroll.addListener(() => _showTop.value = _scroll.hasClients && _scroll.offset > 480);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _restorePlace();
    });
  }

  @override
  void dispose() {
    nav.removeListener(_onNav);
    PdfQueue.I.removeListener(_onQueue);
    PdfQueue.I.finished.removeListener(_onFinished);
    PdfNotify.I.hint.removeListener(_onNotifHint);
    _deckSel.dispose();
    _scroll.dispose();
    _panelIn.dispose();
    super.dispose();
  }

  // ---------- scroll places (`xh`) ----------
  void _savePlace() {
    final k = Places.keyFor(nav.route);
    if (k == null || !_scroll.hasClients) return;
    Places.save(k, _scroll.offset);
  }

  int _restoreRun = 0;

  /// Puts the list back where it was left. The list is rebuilt from the top, so it is only
  /// as tall as what has been laid out so far: keep setting the position every frame until
  /// it holds (content settled), the person touches the list, or ~2 s have passed.
  void _restorePlace() {
    final k = Places.keyFor(nav.route);
    final y = k == null ? 0.0 : Places.y(k);
    final run = ++_restoreRun;
    var frames = 0;
    var held = 0;
    void step() {
      if (!mounted || run != _restoreRun || !_scroll.hasClients) return;
      final p = _scroll.position;
      if (p.userScrollDirection != ScrollDirection.idle) return; // the person took over
      final to = math.min(y, p.maxScrollExtent);
      if ((p.pixels - to).abs() > 0.5) {
        _scroll.jumpTo(to);
        held = 0;
      } else if ((y - to).abs() <= 0.5) {
        held++; // exactly there; wait a few frames for late layout changes
      }
      frames++;
      if (y <= 0 || held >= 4 || frames >= 120) return;
      WidgetsBinding.instance.addPostFrameCallback((_) => step());
      WidgetsBinding.instance.scheduleFrame();
    }

    step();
  }

  void _onNav() {
    final k = nav.route.key;
    if (k != _routeKey) {
      _routeKey = k;
      _panelIn.forward(from: 0);
      WidgetsBinding.instance.addPostFrameCallback((_) => _restorePlace());
    }
    setState(() {});
  }

  // ---------- PDF progress → arrow + deck / done (`PdfDock`, ashok's `Zh`) ----------
  final LayerLink _deckLink = LayerLink();
  static final GlobalKey arrowKey = GlobalKey();

  /// The PDF the deck shows; set to a PDF the moment it starts (ashok: `i(r)` + `n(true)`).
  final ValueNotifier<String?> _deckSel = ValueNotifier<String?>(null);

  /// Ids of PDFs already met: a PDF opens the deck once, when it first shows up as running.
  /// (ashok re-opens it whenever the first running PDF changes, so with a queue the card keeps
  /// jumping up in front of the reader as each one ends — not copied.)
  final Set<String> _seenJobs = {};
  bool _doneOpen = false;

  void _onQueue() {
    if (!mounted) return;
    PdfJob? fresh;
    for (final j in PdfQueue.I.jobs) {
      if (_seenJobs.add(j.id) && j.active && fresh == null) fresh = j;
    }
    if (PdfQueue.I.jobs.isEmpty) _deckOpen = false;
    if (fresh != null && !_doneOpen) {
      _deckSel.value = fresh.id;
      _deckOpen = true;
    }
    setState(() {});
  }

  void _openDeck([int? index]) => setState(() => _deckOpen = !_deckOpen);

  void _closeDeck() {
    if (_deckOpen) setState(() => _deckOpen = false);
  }

  void _onNotifHint() {
    if (!mounted || PdfNotify.I.hint.value == 0) return;
    openNotifHint(context);
  }

  void _onFinished() {
    final j = PdfQueue.I.finished.value;
    if (j == null || j.filePath == null || !mounted) return;
    // Auto-save every finished PDF to Downloads, like `xe()` in the original. Never throws.
    final uri = FileActions.exportToDeviceUri(j.filePath!, j.fileName).catchError((Object _) => null);
    final exported = uri.then((u) => u != null);
    uri.then((u) => PdfNotify.I.done(j, u));
    // ashok: a finished PDF closes the deck and the "PDF तैयार" popup takes over. Only one such
    // popup at a time — PDFs that end while it is open (a queue of many) get a toast, not a stack.
    if (_deckOpen) setState(() => _deckOpen = false);
    if (_doneOpen) {
      exported.then((ok) => Toast.show(ok ? 'PDF तैयार: ${j.fileName} — Downloads में सेव' : 'PDF तैयार: ${j.fileName}'));
      return;
    }
    _doneOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _doneOpen = false;
        return;
      }
      openDone(context, j, exported).whenComplete(() => _doneOpen = false);
    });
  }

  Future<void> _askExit() async {
    if (_exitOpen) return;
    _exitOpen = true;
    final yes = await openExit(context);
    _exitOpen = false;
    if (yes) await NativeBridge.exitApp();
  }

  // ---------- back (`__granthBack`) ----------
  void _onBack() {
    final f = FocusManager.instance.primaryFocus;
    if (f != null && f.context != null && f.context!.widget is EditableText) {
      f.unfocus();
      return;
    }
    if (f != null && f.hasPrimaryFocus && f.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      f.unfocus();
      return;
    }
    if (_deckOpen) {
      _closeDeck();
      return;
    }
    if (SyncStrip.open.value) {
      SyncStrip.open.value = false;
      return;
    }
    if (nav.menuOpen) {
      nav.toggleMenu();
      return;
    }
    nav.back();
  }

  Widget _panel(GRoute r) => switch (r.panel) {
        Panel.dashboard => const DashboardPanel(),
        Panel.topics => const TopicsPanel(),
        Panel.granths => ShelvesPanel(route: r),
        Panel.pramans => PramansPanel(route: r),
        Panel.gallery => const GalleryPanel(),
        Panel.ai => const AiPanel(),
      };

  @override
  Widget build(BuildContext context) {
    final r = nav.route;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light.copyWith(statusBarColor: GColors.maroon),
        child: Scaffold(
          backgroundColor: GColors.cream,
          body: Stack(
            children: [
              const Positioned.fill(child: _RootBackground()),
              ListenableBuilder(
                listenable: Listenable.merge([CatalogStore.I, UiPrefs.I]),
                builder: (context, _) {
                  final s = CatalogStore.I;
                  final total = s.topics.length + s.granths.length + s.pramans.length;
                  return CustomScrollView(
                    controller: _scroll,
                    physics: const BoundedScrollPhysics(),
                    slivers: [
                      SliverToBoxAdapter(
                        child: _Mast(deckOpen: _deckOpen, onDeck: () => _openDeck(0), link: _deckLink),
                      ),
                      SliverToBoxAdapter(child: _Hamburger(open: nav.menuOpen)),
                      SliverToBoxAdapter(child: _NavMenu(open: nav.menuOpen)),
                      const SliverToBoxAdapter(child: SyncStrip()),
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 72),
                        sliver: SliverMainAxisGroup(
                          slivers: [
                            if (s.status == SyncStatus.booting && total == 0) const SliverToBoxAdapter(child: EmptyState(title: 'सेव की हुई प्रति खोली जा रही है…', spinner: true)),
                            if (s.status == SyncStatus.syncing && total == 0) const SliverToBoxAdapter(child: EmptyState(title: 'डेटा लोड हो रहा है…', spinner: true)),
                            if (s.error != null && s.status == SyncStatus.error && total == 0)
                              SliverToBoxAdapter(
                                child: EmptyState(title: 'अभी खाली है', body: s.error, actionLabel: 'फिर कोशिश करें', onAction: () => CatalogStore.I.retry()),
                              ),
                            SliverFadeTransition(
                              key: const ValueKey('panel'),
                              opacity: CurvedAnimation(parent: _panelIn, curve: Curves.easeOutCubic),
                              sliver: KeyedSubtree(key: ValueKey(r.key), child: _panel(r)),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              ),
              _ScrollRail(controller: _scroll),
              Positioned(
                right: 48,
                bottom: 36,
                child: ValueListenableBuilder<bool>(
                  valueListenable: _showTop,
                  builder: (context, show, _) => AnimatedSlide(
                    offset: show ? Offset.zero : const Offset(0, 0.6),
                    duration: const Duration(milliseconds: 240),
                    curve: Curves.easeOutCubic,
                    child: AnimatedOpacity(
                      opacity: show ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: IgnorePointer(
                        ignoring: !show,
                        child: Pressable(
                          onTap: () => _scroll.animateTo(0, duration: const Duration(milliseconds: 520), curve: Curves.easeOutCubic),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                            decoration: BoxDecoration(color: GColors.maroon, borderRadius: BorderRadius.circular(8)),
                            child: Text(
                              'Top',
                              style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.paper),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // ashok's PDF deck: a centred modal over a scrim (it also covers the header).
              if (_deckOpen && PdfQueue.I.jobs.isNotEmpty) Positioned.fill(child: PdfDeckLayer(key: const ValueKey('pdf-deck-layer'), selected: _deckSel, onClose: _closeDeck)),
              const _ToastLayer(),
            ],
          ),
        ),
      ),
    );
  }
}

class _RootBackground extends StatelessWidget {
  const _RootBackground();
  @override
  Widget build(BuildContext context) => const DecoratedBox(
        decoration: BoxDecoration(color: GColors.cream),
        child: Stack(
          fit: StackFit.expand,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: Alignment(-0.8, -0.84), radius: 0.92, colors: [Color(0x1FE8821A), Color(0x00E8821A)]),
              ),
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(center: Alignment(0.84, 0.8), radius: 0.84, colors: [Color(0x147B1F2E), Color(0x007B1F2E)]),
              ),
            ),
          ],
        ),
      );
}

/// `.mast`
class _Mast extends StatelessWidget {
  const _Mast({required this.deckOpen, required this.onDeck, required this.link});
  final bool deckOpen;
  final VoidCallback onDeck;
  final LayerLink link;

  @override
  Widget build(BuildContext context) {
    final s = CatalogStore.I;
    final nav = AppNav.I;
    final top = MediaQuery.paddingOf(context).top;
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [GColors.maroon, GColors.brown, GColors.maroonLight], stops: [0, 0.52, 1]),
        boxShadow: [BoxShadow(color: GColors.shadow(0.35), blurRadius: 20, offset: const Offset(0, 4))],
      ),
      padding: EdgeInsets.only(top: top),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: 4,
            decoration: const BoxDecoration(gradient: LinearGradient(colors: [GColors.saffronDark, GColors.saffron, GColors.gold, GColors.saffron, GColors.saffronDark])),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Pressable(
                        onTap: () => nav.go('#/dashboard'),
                        behavior: HitTestBehavior.deferToChild,
                        child: Row(
                          children: [
                            const Hero(tag: 'granth-logo', child: LogoIcon()),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Text('ग्रंथ प्रबंधन', style: GText.display(size: 26, color: GColors.goldLight, height: 1.15, letterSpacing: 0.5)),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ListenableBuilder(
                      listenable: PdfQueue.I,
                      builder: (context, _) {
                        final jobs = PdfQueue.I.jobs;
                        final h = PdfQueue.I.activeCount;
                        return AnimatedSwitcher(
                          duration: const Duration(milliseconds: 260),
                          transitionBuilder: (c, a) => ScaleTransition(
                            scale: a,
                            child: FadeTransition(opacity: a, child: c),
                          ),
                          child: jobs.isEmpty
                              ? const SizedBox.shrink()
                              : Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: CompositedTransformTarget(
                                    key: _HomeShellState.arrowKey,
                                    link: link,
                                    child: Pressable(
                                    key: const ValueKey('pdf-arrow'),
                                    onTap: onDeck,
                                    child: Container(
                                      height: 44,
                                      constraints: const BoxConstraints(minWidth: 44),
                                      padding: const EdgeInsets.symmetric(horizontal: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(alpha: 0.16),
                                        borderRadius: BorderRadius.circular(12),
                                        border: Border.all(color: GColors.gold.withValues(alpha: 0.55)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          AnimatedRotation(
                                            turns: deckOpen ? 0.5 : 0,
                                            duration: const Duration(milliseconds: 240),
                                            child: const GIcon('chevron-down', size: 18, color: GColors.goldLight),
                                          ),
                                          if (h > 0) ...[
                                            const SizedBox(width: 4),
                                            Text(
                                              '$h',
                                              style: GText.sans(size: 13, weight: FontWeight.w700, color: GColors.goldLight),
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                  ),
                                  ),
                                ),
                        );
                      },
                    ),
                    _MastBtn(icon: 'images', onTap: () => nav.go('#/gallery')),
                    const SizedBox(width: 6),
                    _MastBtn(icon: 'settings', onTap: () => openSettings(context)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _Stat(n: s.topics.length, label: 'विषय / प्रश्नोत्तरी', active: nav.isActive(Panel.topics), onTap: () => nav.go('#/topics')),
                    const SizedBox(width: 10),
                    _Stat(n: s.granths.length, label: 'पवित्र ग्रन्थ', active: nav.isActive(Panel.granths), onTap: () => nav.go('#/granths')),
                    const SizedBox(width: 10),
                    _Stat(n: s.pramans.length, label: 'नए प्रमाण', active: nav.isActive(Panel.pramans), onTap: () => nav.go('#/pramans')),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MastBtn extends StatelessWidget {
  const _MastBtn({required this.icon, required this.onTap});
  final String icon;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.9,
        child: Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: GColors.gold.withValues(alpha: 0.45)),
          ),
          child: GIcon(icon, size: 20, color: GColors.goldLight),
        ),
      );
}

/// `.stat-item` — glows when its panel is active.
class _Stat extends StatelessWidget {
  const _Stat({required this.n, required this.label, required this.active, required this.onTap});
  final int n;
  final String label;
  final bool active;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Expanded(
        child: Pressable(
          onTap: onTap,
          scale: 0.95,
          // `.stat-item.active` glow, exactly as the original CSS:
          //   box-shadow: 0 0 0 2px var(--color-gold),
          //               0 0 18px color-mix(in srgb, var(--color-gold-light) 80%, transparent);
          // A CSS box-shadow is only painted OUTSIDE the box, so the translucent tile stays
          // clear; Flutter's BoxShadow would also paint under it, so a painter draws the ring
          // and the glow outside the rounded rect only. It fades in/out (the original snaps).
          child: TweenAnimationBuilder<double>(
            tween: Tween(end: active ? 1 : 0),
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            builder: (context, t, child) => CustomPaint(painter: StatGlowPainter(t), child: child),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
              decoration: BoxDecoration(
                // .stat-item: rgba(255,255,255,.06) / gold 35% border; active: gold 28% / gold-light border.
                color: active ? GColors.gold.withValues(alpha: 0.28) : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: active ? GColors.goldLight : GColors.gold.withValues(alpha: 0.35)),
              ),
              child: Column(
                children: [
                  CountUp(value: n, memo: 'mast:$label', style: GText.display(size: 22, color: GColors.goldLight, height: 1.1)),
                  const SizedBox(height: 2),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    style: GText.sans(size: 12, color: GColors.paper, height: 1.25),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

/// Outside-only ring + glow of the active header stat (see [_Stat]). [t] is 0…1.
class StatGlowPainter extends CustomPainter {
  StatGlowPainter(this.t);
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    if (t <= 0.001) return;
    final box = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(8));
    canvas.save();
    // Clip away the box itself: CSS never paints a box-shadow under the element.
    canvas.clipPath(Path()
      ..fillType = PathFillType.evenOdd
      ..addRect((Offset.zero & size).inflate(60))
      ..addRRect(box));
    // 0 0 18px gold-light 80% → Gaussian sigma = 18 / 2.
    canvas.drawRRect(
      box,
      Paint()
        ..color = GColors.goldLight.withValues(alpha: 0.8 * t)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 9),
    );
    // 0 0 0 2px gold → a solid 2 px ring hugging the border (radius 8 + 2).
    canvas.drawRRect(box.inflate(2), Paint()..color = GColors.gold.withValues(alpha: t));
    canvas.restore();
  }

  @override
  bool shouldRepaint(StatGlowPainter old) => old.t != t;
}

/// `.hamburger` — menu ⇄ x morph.
class _Hamburger extends StatelessWidget {
  const _Hamburger({required this.open});
  final bool open;
  @override
  Widget build(BuildContext context) => Align(
        alignment: Alignment.centerLeft,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
          child: Semantics(
            button: true,
            label: open ? 'मेनू बंद करें' : 'मेनू खोलें',
            child: Pressable(
              onTap: AppNav.I.toggleMenu,
              child: Container(
                width: 44,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: GColors.paper,
                  border: Border.all(color: GColors.creamDark),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  transitionBuilder: (c, a) => RotationTransition(
                    turns: Tween(begin: 0.75, end: 1.0).animate(a),
                    child: FadeTransition(opacity: a, child: c),
                  ),
                  child: GIcon(open ? 'x' : 'menu', key: ValueKey(open), size: 22, color: GColors.maroon),
                ),
              ),
            ),
          ),
        ),
      );
}

/// `nav` (phone layout) — slides open under the hamburger.
class _NavMenu extends StatelessWidget {
  const _NavMenu({required this.open});
  final bool open;
  static const _items = [
    ('landmark', 'Dashboard', '#/dashboard', Panel.dashboard),
    ('clipboard-list', 'Topics', '#/topics', Panel.topics),
    ('library', 'Granths', '#/granths', Panel.granths),
    ('image', 'प्रमाण', '#/pramans', Panel.pramans),
    // Round 11: तत्त्व AI (coming soon) sits directly above the Photo Highlighter.
    ('sparkles', 'तत्त्व AI से पूछे', '#/ai', Panel.ai),
    // Round 6: opens the Photo Highlighter (its own full-screen page, lib/highlighter/).
    ('highlighter', 'Photo Highlighter', '', null),
  ];

  @override
  Widget build(BuildContext context) => AnimatedSize(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        alignment: Alignment.topCenter,
        child: !open
            ? const SizedBox(width: double.infinity)
            : Container(
                decoration: const BoxDecoration(
                  color: GColors.brown,
                  border: Border(bottom: BorderSide(color: GColors.gold, width: 2)),
                ),
                padding: const EdgeInsets.fromLTRB(8, 6, 8, 10),
                child: Column(
                  children: [
                    for (var i = 0; i < _items.length; i++) ...[if (i > 0) const SizedBox(height: 4), Entry(index: i, dx: -16, child: _navBtn(_items[i]))],
                  ],
                ),
              ),
      );

  Widget _navBtn((String, String, String, Panel?) it) {
    final active = it.$4 != null && AppNav.I.route.panel == it.$4;
    final color = active ? GColors.goldLight : GColors.cream.withValues(alpha: 0.68);
    return Builder(builder: (context) => Pressable(
      key: ValueKey('nav-${it.$1}'),
      onTap: () {
        if (it.$4 != null) {
          AppNav.I.go(it.$3);
          return;
        }
        if (AppNav.I.menuOpen) AppNav.I.toggleMenu();
        HighlighterLauncher.open(context);
      },
      scale: 0.98,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
            child: Row(
              children: [
                GIcon(it.$1, size: 16, color: color),
                const SizedBox(width: 8),
                Text(
                  it.$2.toUpperCase(),
                  style: GText.sans(size: 14, weight: FontWeight.w600, color: color, letterSpacing: 0.6),
                ),
              ],
            ),
          ),
          if (active)
            Positioned(
              left: 12,
              right: 12,
              bottom: -2,
              height: 2,
              child: const DecoratedBox(
                decoration: BoxDecoration(gradient: LinearGradient(colors: [GColors.saffron, GColors.gold])),
              ),
            ),
        ],
      ),
    ));
  }
}

const _hiMonths = ['जन॰', 'फ़र॰', 'मार्च', 'अप्रैल', 'मई', 'जून', 'जुल॰', 'अग॰', 'सित॰', 'अक्तू॰', 'नव॰', 'दिस॰'];

/// `og()` — hi-IN "day month, hh:mm am/pm".
String hiDate(int? ms) {
  if (ms == null) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  final h12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  return '${d.day} ${_hiMonths[d.month - 1]}, ${h12.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')} ${d.hour < 12 ? 'am' : 'pm'}';
}

/// `.sync-strip` — status line + सिंक button, and the sync card that opens under it.
///
/// It listens to the store itself. (It used to be a `const` child of the scroll view, so a
/// store change never rebuilt it: the सिंक tap ran, but the spinner, the text and the page
/// count stayed frozen — the "sync button does nothing" bug.)
class SyncStrip extends StatelessWidget {
  const SyncStrip({super.key});

  /// Sync card open / closed (opens on a सिंक tap, the arrow closes it).
  static final ValueNotifier<bool> open = ValueNotifier(false);

  static void tapSync() {
    open.value = true;
    CatalogStore.I.manualSync();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([CatalogStore.I, CatalogStore.I.progress, CatalogStore.I.lastSync, open, UiPrefs.I]),
        builder: (context, _) {
          final s = CatalogStore.I;
          final u = s.progress.value;
          final syncing = s.status == SyncStatus.syncing;
          final busy = syncing || (u.manual && u.running);
          final phase = u.total > 0 ? (u.running && !(u.checking && !u.manual) ? 1 : (u.done >= u.total ? 2 : 3)) : (syncing ? 4 : 0);
          final ce = switch (phase) {
            1 => 'पेज सेव हो रहे हैं ${u.done}/${u.total}',
            2 => 'सभी पेज इस डिवाइस पर सेव हैं',
            3 => 'सेव पेज ${u.done}/${u.total}',
            4 => 'सूची सेव हो रही है…',
            _ => '',
          };
          final main = syncing
              ? 'ऑनलाइन सिंक हो रहा है — सूची डिवाइस पर लिखी जा रही है'
              : (s.error ?? (s.online ? 'ऑफलाइन तैयार${s.syncedAt != null ? ' · ${hiDate(s.syncedAt)}' : ''}' : 'इंटरनेट नहीं · सेव किया डेटा चल रहा है'));
          final t = themedSurface(const BoxDecoration(color: GColors.syncStrip));
          return Container(
            // The strip takes the style's colour only (it is a full-width bar).
            decoration: BoxDecoration(
              color: t.gradient == null ? t.color : null,
              gradient: t.gradient,
              border: const Border(bottom: BorderSide(color: GColors.creamDark)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 300),
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(color: s.online ? GColors.online : GColors.maroon, shape: BoxShape.circle),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 220),
                        layoutBuilder: (cur, prev) => Stack(alignment: Alignment.topLeft, children: [...prev, ?cur]),
                        child: Text(
                          '$main${ce.isNotEmpty ? ' · $ce' : ''}',
                          // Cross-fades when the message changes, not on every page count.
                          key: ValueKey('$main|$phase'),
                          style: GText.sans(size: 13, color: GColors.brown, height: 1.4),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Pressable(
                      key: const ValueKey('sync-card-toggle'),
                      onTap: () => open.value = !open.value,
                      scale: 0.9,
                      child: Padding(
                        padding: const EdgeInsets.all(6),
                        child: AnimatedRotation(
                          turns: open.value ? 0.5 : 0,
                          duration: const Duration(milliseconds: 240),
                          child: const GIcon('chevron-down', size: 16, color: GColors.maroon),
                        ),
                      ),
                    ),
                    const SizedBox(width: 4),
                    _SyncButton(syncing: busy),
                  ],
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: open.value ? _SyncCard(s: s) : const SizedBox(width: double.infinity),
              ),
            ]),
          );
        },
      );
}

/// What is saved on this phone: "985 में से 985 पेज सेव", a bar, and the last sync time.
class _SyncCard extends StatelessWidget {
  const _SyncCard({required this.s});
  final CatalogStore s;

  @override
  Widget build(BuildContext context) {
    final u = s.progress.value;
    final total = u.total;
    final done = u.done.clamp(0, total == 0 ? 0 : total);
    final syncing = s.status == SyncStatus.syncing;
    final working = syncing || u.running;
    final head = syncing ? 'सूची सिंक हो रही है…' : (working ? 'पेज जाँचे और सेव हो रहे हैं…' : (total > 0 && done >= total ? 'सब पेज फ़ोन में सेव हैं' : 'पेज सेव'));
    return Container(
      key: const ValueKey('sync-card'),
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: themedSurface(BoxDecoration(
        color: GColors.paper,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: GColors.gold.withValues(alpha: 0.6)),
        boxShadow: [BoxShadow(color: GColors.brown.withValues(alpha: 0.10), blurRadius: 10, offset: const Offset(0, 3))],
      )),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(head, style: GText.sans(size: 14, weight: FontWeight.w700, color: GColors.maroon)),
        const SizedBox(height: 6),
        Text(total > 0 ? '$total में से $done पेज सेव' : 'पेज की सूची अभी नहीं आई', style: GText.display(size: 20, color: GColors.maroon, height: 1.2)),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            // The number is always the real saved count; while the सिंक button's check runs,
            // the bar shows how far the check has got.
            value: syncing && total == 0 ? null : (total == 0 ? 0 : ((u.checking && u.manual ? u.checked : done) / total).clamp(0.0, 1.0)),
            minHeight: 6,
            backgroundColor: GColors.creamDark,
            valueColor: const AlwaysStoppedAnimation(GColors.saffron),
          ),
        ),
        const SizedBox(height: 8),
        Text(s.syncedAt != null ? 'आख़िरी सिंक: ${hiDate(s.syncedAt)}' : 'अभी सिंक नहीं हुआ', style: GText.sans(size: 13, color: GColors.muted)),
      ]),
    );
  }
}

class _SyncButton extends StatefulWidget {
  const _SyncButton({required this.syncing});
  final bool syncing;
  @override
  State<_SyncButton> createState() => _SyncButtonState();
}

class _SyncButtonState extends State<_SyncButton> with SingleTickerProviderStateMixin {
  late final AnimationController _spin = AnimationController(vsync: this, duration: const Duration(milliseconds: 800));

  @override
  void initState() {
    super.initState();
    if (widget.syncing) _spin.repeat();
  }

  @override
  void didUpdateWidget(covariant _SyncButton old) {
    super.didUpdateWidget(old);
    if (widget.syncing && !_spin.isAnimating) _spin.repeat();
    if (!widget.syncing && _spin.isAnimating) _spin.animateTo(1).then((_) => _spin.value = 0);
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Pressable(
        key: const ValueKey('sync-button'),
        // While a sync runs, a tap just opens the sync card (the original disabled the button).
        onTap: widget.syncing ? () => SyncStrip.open.value = true : SyncStrip.tapSync,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: GColors.paper,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: GColors.maroon.withValues(alpha: 0.25)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              RotationTransition(
                turns: _spin,
                child: const GIcon('refresh-cw', size: 14, color: GColors.maroon),
              ),
              const SizedBox(width: 6),
              Text(
                'सिंक',
                style: GText.sans(size: 13, weight: FontWeight.w600, color: GColors.maroon),
              ),
            ],
          ),
        ),
      );
}

/// `.toast` — slides up from the bottom.
class _ToastLayer extends StatelessWidget {
  const _ToastLayer();
  @override
  Widget build(BuildContext context) => Positioned(
        left: 0,
        right: 0,
        bottom: 24 + MediaQuery.paddingOf(context).bottom,
        child: IgnorePointer(
          child: ValueListenableBuilder<String?>(
            valueListenable: Toast.message,
            builder: (context, msg, _) => AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutBack,
              switchOutCurve: Curves.easeIn,
              transitionBuilder: (c, a) => FadeTransition(
                opacity: a,
                child: SlideTransition(
                  position: Tween(begin: const Offset(0, 0.6), end: Offset.zero).animate(a),
                  child: c,
                ),
              ),
              child: msg == null
                  ? const SizedBox.shrink()
                  : Center(
                      key: ValueKey('${Toast.serial}'),
                      child: Container(
                        constraints: BoxConstraints(maxWidth: math.min(MediaQuery.sizeOf(context).width * 0.92, 420)),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        decoration: BoxDecoration(
                          color: GColors.brown,
                          borderRadius: BorderRadius.circular(10),
                          border: const Border(left: BorderSide(color: GColors.saffron, width: 3)),
                        ),
                        child: Text(
                          msg,
                          style: GText.sans(size: 16, weight: FontWeight.w600, color: GColors.goldLight),
                        ),
                      ),
                    ),
            ),
          ),
        ),
      );
}

/// `qn` — the custom scroll rail (arrows + draggable thumb, hides after 700 ms).
class _ScrollRail extends StatefulWidget {
  const _ScrollRail({required this.controller});
  final ScrollController controller;
  @override
  State<_ScrollRail> createState() => _ScrollRailState();
}

class _ScrollRailState extends State<_ScrollRail> {
  bool _show = false;
  bool _drag = false;
  Timer? _hide;

  ScrollController get c => widget.controller;

  @override
  void initState() {
    super.initState();
    c.addListener(_onScroll);
  }

  @override
  void dispose() {
    c.removeListener(_onScroll);
    _hide?.cancel();
    super.dispose();
  }

  void _onScroll() {
    if (!mounted) return;
    setState(() => _show = true);
    _hide?.cancel();
    _hide = Timer(const Duration(milliseconds: 700), () {
      if (mounted && !_drag) setState(() => _show = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!c.hasClients || !c.position.hasContentDimensions) return const SizedBox.shrink();
    final p = c.position;
    final max = p.maxScrollExtent;
    if (max <= 8) return const SizedBox.shrink();
    final pad = MediaQuery.paddingOf(context);
    final view = p.viewportDimension;
    // Rail starts below the mast/nav/sync strip while they are on screen (~ 260 px of header).
    final top = math.max(8.0 + pad.top, 300 - p.pixels + pad.top);
    final railH = view - top - 8 - 56;
    if (railH < 48) return const SizedBox.shrink();
    final total = max + view;
    final thumbH = math.max(64.0, math.min(railH, view / total * railH));
    final thumbTop = (p.pixels / max).clamp(0.0, 1.0) * (railH - thumbH);
    void page(int dir) => c.animateTo((p.pixels + dir * view * 0.82).clamp(0, max), duration: const Duration(milliseconds: 360), curve: Curves.easeOutCubic);
    Widget arrow(bool up) => GestureDetector(
          onTap: () => page(up ? -1 : 1),
          child: Container(
            height: 28,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: GColors.maroon,
              border: up ? const Border(bottom: BorderSide(color: Color(0xFFA66A3F))) : const Border(top: BorderSide(color: Color(0xFFA66A3F))),
            ),
            child: Icon(up ? Icons.keyboard_arrow_up_rounded : Icons.keyboard_arrow_down_rounded, size: 16, color: GColors.goldLight),
          ),
        );
    return Positioned(
      right: 4,
      top: top,
      bottom: 8,
      width: 18,
      child: IgnorePointer(
        ignoring: !_show,
        child: AnimatedOpacity(
          opacity: _show ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Column(
              children: [
                arrow(true),
                Expanded(
                  child: GestureDetector(
                    onVerticalDragStart: (_) => _drag = true,
                    onVerticalDragEnd: (_) {
                      _drag = false;
                      _onScroll();
                    },
                    onVerticalDragUpdate: (d) => c.jumpTo((p.pixels + d.delta.dy / math.max(1, railH - thumbH) * max).clamp(0, max)),
                    onTapDown: (d) => c.jumpTo(((d.localPosition.dy - thumbH / 2) / math.max(1, railH - thumbH)).clamp(0.0, 1.0) * max),
                    child: Container(
                      color: GColors.paper,
                      child: Stack(
                        children: [
                          Positioned(
                            left: 2,
                            right: 2,
                            top: thumbTop,
                            height: thumbH,
                            child: Container(
                              decoration: BoxDecoration(color: GColors.maroon.withValues(alpha: 0.55), borderRadius: BorderRadius.circular(7)),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [for (var i = 0; i < 3; i++) Container(width: 12, height: 1.5, margin: const EdgeInsets.symmetric(vertical: 1.25), color: GColors.goldLight)],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                arrow(false),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
