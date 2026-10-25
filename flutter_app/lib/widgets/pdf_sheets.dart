import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/models.dart';
import '../services/api.dart' show kPlayStoreUrl;
import '../services/catalog_store.dart';
import '../services/file_actions.dart';
import '../services/gallery_service.dart';
import '../services/pdf_builder.dart';
import '../services/pdf_notify.dart';
import '../services/pdf_queue.dart';
import '../services/remote_config.dart';
import '../state/router.dart';
import '../services/storage.dart';
import '../state/motion.dart';
import '../state/toast.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import 'common.dart';
import 'overlays.dart';
import 'pop.dart';

/// What the user asked a PDF of (`zh({kind…})`).
sealed class PdfRequest {}

class GranthPdfRequest extends PdfRequest {
  GranthPdfRequest(this.granth);
  final Granth granth;
}

class TopicPdfRequest extends PdfRequest {
  TopicPdfRequest(this.topic);
  final Topic topic;
}

class PramanPdfRequest extends PdfRequest {
  PramanPdfRequest(this.praman);
  final Praman praman;
}

/// Several granths at once (multi-select on the Granths screen): one PDF per granth,
/// all made in parallel, each with its own progress row.
class MultiGranthPdfRequest extends PdfRequest {
  MultiGranthPdfRequest(this.granths);
  final List<Granth> granths;
}

void _run(PdfRequest r, PdfStyle s) {
  switch (r) {
    case MultiGranthPdfRequest(:final granths):
      PdfQueue.I.granthPdfs(granths, s);
    case GranthPdfRequest(:final granth):
      PdfQueue.I.granthPdf(granth, s);
    case TopicPdfRequest(:final topic):
      PdfQueue.I.topicPdf(topic, s);
    case PramanPdfRequest(:final praman):
      PdfQueue.I.pramanPdf(praman, s);
  }
}

/// `Bh` — "PDF शैली" picker, then queue the job.
Future<void> askPdf(BuildContext context, PdfRequest req) async {
  final style = await showPop<PdfStyle>(context, (ctx) => _StyleSheet(initial: UiPrefs.I.pdfStyle));
  if (style == null) return;
  UiPrefs.I.pdfStyle = style;
  _run(req, style);
}

class _StyleSheet extends StatefulWidget {
  const _StyleSheet({required this.initial});
  final PdfStyle initial;
  @override
  State<_StyleSheet> createState() => _StyleSheetState();
}

class _StyleSheetState extends State<_StyleSheet> {
  late PdfStyle _s = widget.initial;
  @override
  Widget build(BuildContext context) => SheetCard(
        children: [
          SheetHead(title: 'PDF शैली', onBack: () => Navigator.pop(context)),
          for (final o in pdfStyleOptions) ...[
            StyleOption(title: o.title, hint: o.hint, on: _s == o.style, onTap: () => setState(() => _s = o.style)),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: 4),
          Row(children: [
            Expanded(child: SheetButton(label: 'पीछे', onTap: () => Navigator.pop(context))),
            const SizedBox(width: 10),
            Expanded(child: SheetButton(label: 'OK', primary: true, onTap: () => Navigator.pop(context, _s))),
          ]),
        ],
      );
}

/// `.pdf-style`
class StyleOption extends StatelessWidget {
  const StyleOption({super.key, required this.title, required this.hint, required this.on, required this.onTap});
  final String title;
  final String hint;
  final bool on;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.98,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: on ? const Color(0xFFFFF8EA) : Colors.white,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: on ? GColors.gold : const Color(0xFFEAD9BC), width: on ? 2 : 1),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.brown)),
            const SizedBox(height: 2),
            Text(hint, style: GText.sans(size: 13, color: GColors.muted)),
          ]),
        ),
      );
}

/// Animated `.pdf-meter`.
class PdfMeter extends StatelessWidget {
  const PdfMeter({super.key, required this.percent});
  final int percent;
  @override
  Widget build(BuildContext context) => Container(
        height: 8,
        margin: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(color: GColors.meterTrack, borderRadius: BorderRadius.circular(999)),
        clipBehavior: Clip.antiAlias,
        child: TweenAnimationBuilder<double>(
          tween: Tween(end: percent / 100),
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          builder: (context, v, _) => FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: v.clamp(0, 1),
            child: const DecoratedBox(decoration: BoxDecoration(gradient: LinearGradient(colors: [GColors.saffron, GColors.maroon]))),
          ),
        ),
      );
}

bool _sharing = false;

Future<void> _share(PdfJob j, VoidCallback refresh) async {
  if (j.filePath == null || _sharing) return;
  _sharing = true;
  refresh();
  try {
    await FileActions.shareFile(j.filePath!, j.fileName);
  } finally {
    _sharing = false;
    refresh();
  }
}

/// `Jh`
Future<void> _saveToGallery(BuildContext context, PdfJob j) async {
  if (j.filePath == null) return;
  if (!await confirmPop(context, 'क्या आप इस PDF को ऐप गैलरी में सेव करना चाहते हैं?\n${j.fileName}')) return;
  final bytes = await FileActionsBytes.read(j.filePath!);
  await GalleryService.I.put(
    id: j.galleryId,
    kind: GalleryKind.pdf,
    title: j.title,
    text: j.text,
    topic: j.topic,
    granth: j.granth,
    fileName: j.fileName,
    bytes: bytes,
    preview: j.preview,
  );
  Toast.show('ऐप गैलरी में सेव हो गया');
}

Widget _doneActions(BuildContext context, PdfJob j, VoidCallback refresh) => Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(children: [
        Row(children: [
          Expanded(child: SheetButton(label: 'PDF खोलें', primary: true, onTap: () => FileActions.open(j.filePath!, j.fileName))),
          const SizedBox(width: 10),
          Expanded(child: SheetButton(label: _sharing ? 'खुल रहा है…' : 'शेयर', icon: 'share-2', enabled: !_sharing, onTap: () => _share(j, refresh))),
        ]),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: SheetButton(label: 'सेव', icon: 'folder-down', onTap: () => _saveToGallery(context, j))),
          const SizedBox(width: 10),
          const Expanded(child: SizedBox()),
        ]),
      ]),
    );

/// ashok's `.pdf-pop` + `.pdf-deck-center` (round 8, measured from his CSS / `Zh`): a centred modal
/// card over a 28 % brown scrim (fade 0.22 s). It opens by itself when a new PDF starts, by the header
/// arrow, and closes by the scrim, the system back, "बंद", the arrow, or when a PDF finishes (the
/// "PDF तैयार" popup takes over). The card comes in out of a blur (520 ms); the scrim, nothing else.
class PdfDeckLayer extends StatefulWidget {
  const PdfDeckLayer({super.key, required this.selected, required this.onClose});
  final ValueNotifier<String?> selected;
  final VoidCallback onClose;
  static const shadeKey = ValueKey('pdf-shade');
  @override
  State<PdfDeckLayer> createState() => _PdfDeckLayerState();
}

class _PdfDeckLayerState extends State<PdfDeckLayer> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(vsync: this, duration: kFocusTime);
  bool _started = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_started) return;
    _started = true;
    // "एनिमेशन: कम" / phone no-animation: the card is simply there.
    if (Motion.on(context)) {
      _c.forward();
    } else {
      _c.value = 1;
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final shade = CurvedAnimation(parent: _c, curve: const Interval(0, 220 / 520, curve: Curves.easeOut));
    final focus = CurvedAnimation(parent: _c, curve: kRise);
    return Stack(children: [
      Positioned.fill(
        child: FadeTransition(
          opacity: shade,
          child: GestureDetector(
            key: PdfDeckLayer.shadeKey,
            behavior: HitTestBehavior.opaque,
            onTap: widget.onClose,
            child: ColoredBox(color: GColors.brown.withValues(alpha: 0.28)),
          ),
        ),
      ),
      SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: BlurFocus(
              animation: focus,
              // Taps on the card are the card's own (the scrim is behind it).
              child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () {}, child: PdfDeck(selected: widget.selected, onClose: widget.onClose)),
            ),
          ),
        ),
      ),
    ]);
  }
}

/// The deck card: ONE PDF at a time (round 7) in ashok's layout — "n/N" + %, title, bar, two
/// info lines, [बंद] [पिछला] [अगला], then रोकें or PDF खोलें / शेयर / सेव.
class PdfDeck extends StatefulWidget {
  const PdfDeck({super.key, required this.selected, required this.onClose});

  /// The PDF on show (an id); the home screen sets it when a new PDF starts.
  final ValueNotifier<String?> selected;
  final VoidCallback onClose;
  @override
  State<PdfDeck> createState() => _PdfDeckState();
}

class _PdfDeckState extends State<PdfDeck> {
  Timer? _tick;

  int _index(List<PdfJob> jobs) {
    var i = widget.selected.value == null ? -1 : jobs.indexWhere((j) => j.id == widget.selected.value);
    if (i < 0) {
      // Removed / first time: the running one, else the newest.
      final first = jobs.indexWhere((j) => j.active);
      i = first >= 0 ? first : jobs.length - 1;
    }
    widget.selected.value = jobs[i].id;
    return i;
  }

  void _go(List<PdfJob> jobs, int to) => widget.selected.value = jobs[to.clamp(0, jobs.length - 1)].id;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  Future<void> _remove(PdfJob j) async {
    if (j.active && !await confirmPop(context, 'यह PDF अभी बन रही है। रोककर सूची से हटाएँ?\n${j.title}')) return;
    PdfQueue.I.remove(j.id);
    if (PdfQueue.I.jobs.isEmpty) widget.onClose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([PdfQueue.I, UiPrefs.I, widget.selected]),
        builder: (context, _) {
          final jobs = PdfQueue.I.jobs;
          if (jobs.isEmpty) return const SizedBox.shrink();
          final now = DateTime.now().millisecondsSinceEpoch;
          final at = _index(jobs);
          final m = jobs[at];
          final finished = jobs.where((j) => !j.active).length;
          final done = m.phase == PdfPhase.done && m.filePath != null;
          return KeyedSubtree(
            key: const ValueKey('pdf-dropdown'),
            child: FrostCard(
              maxWidth: 440,
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
                // .pdf-deck-top: n/N … %  (× removes this PDF — kept from round 7, ashok has none)
                Row(children: [
                  Text('${at + 1}/${jobs.length}', key: const ValueKey('pdf-pos'), style: GText.sans(size: 15, weight: FontWeight.w700)),
                  const Spacer(),
                  TweenAnimationBuilder<double>(
                    tween: Tween(end: m.percent.toDouble()),
                    duration: const Duration(milliseconds: 420),
                    builder: (context, v, _) => Text('${v.round()}%', key: const ValueKey('pdf-pct'), style: GText.sans(size: 15)),
                  ),
                  const SizedBox(width: 8),
                  Pressable(
                    key: ValueKey('pdf-x-${m.id}'),
                    onTap: () => _remove(m),
                    scale: 0.85,
                    child: Container(
                      width: 30,
                      height: 30,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(color: GColors.pill, borderRadius: BorderRadius.circular(999)),
                      child: const GIcon('x', size: 14, color: GColors.maroon),
                    ),
                  ),
                ]),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(m.title, key: const ValueKey('pdf-title'), style: GText.display(size: 22, color: GColors.maroon, height: 1.25)),
                ),
                PdfMeter(percent: m.percent),
                Padding(padding: const EdgeInsets.only(top: 4), child: Text(jobLine(m, now), key: const ValueKey('pdf-facts'), style: GText.sans(size: 14))),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(phaseText(m), key: const ValueKey('pdf-phase'), style: GText.sans(size: 14, color: m.phase == PdfPhase.error ? GColors.maroon : GColors.text, weight: m.phase == PdfPhase.error ? FontWeight.w700 : FontWeight.w400)),
                ),
                if (m.phase == PdfPhase.done && m.missingImages > 0)
                  Padding(padding: const EdgeInsets.only(top: 4), child: Text('${m.missingImages} चित्र लोड नहीं हुए — उनकी जगह खाली फ्रेम है', style: GText.sans(size: 13, color: GColors.muted))),
                const SizedBox(height: 8),
                // .pdf-deck-nav
                Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                  Pill(key: const ValueKey('pdf-close'), label: 'बंद', onTap: widget.onClose),
                  Pill(key: const ValueKey('pdf-prev'), label: 'पिछला', icon: 'chevron-left', enabled: at > 0, onTap: () => _go(jobs, at - 1)),
                  Pill(key: const ValueKey('pdf-next'), label: 'अगला', trailingIcon: 'chevron-right', enabled: at < jobs.length - 1, onTap: () => _go(jobs, at + 1)),
                ]),
                if (m.active)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Align(alignment: Alignment.centerLeft, child: IntrinsicWidth(child: SheetButton(key: const ValueKey('pdf-stop'), label: 'रोकें', onTap: () => PdfQueue.I.cancel(m.id)))),
                  ),
                if (m.canRetry)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Align(alignment: Alignment.centerLeft, child: IntrinsicWidth(child: SheetButton(label: 'फिर कोशिश करें', icon: 'refresh-cw', onTap: () => PdfQueue.I.retry(m.id)))),
                  ),
                if (done) _doneActions(context, m, () => setState(() {})),
                if (finished > 1)
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Align(alignment: Alignment.centerLeft, child: Pill(key: const ValueKey('pdf-clear'), label: 'तैयार हटाएँ', onTap: PdfQueue.I.clearFinished)),
                  ),
              ]),
            ),
          );
        },
      );
}

/// `.pdf-done` — shown when a PDF finishes; it is also copied to Downloads automatically.
Future<void> openDone(BuildContext context, PdfJob job, Future<bool> exported) => showPop(context, (ctx) => _Done(job: job, exported: exported), blurFocus: true);

class _Done extends StatefulWidget {
  const _Done({required this.job, required this.exported});
  final PdfJob job;
  final Future<bool> exported;
  @override
  State<_Done> createState() => _DoneState();
}

class _DoneState extends State<_Done> {
  bool _saved = false;
  @override
  void initState() {
    super.initState();
    widget.exported.then((v) {
      if (mounted) setState(() => _saved = true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.job;
    return FrostCard(
      maxWidth: 480,
      alpha: 0.92,
      radius: 18,
      border: GColors.gold,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
        Align(alignment: Alignment.centerRight, child: Pill(icon: 'x', label: 'पीछे', onTap: () => Navigator.pop(context))),
        const SizedBox(height: 6),
        Text(a.fileName, style: GText.display(size: 22, color: GColors.maroon, height: 1.25)),
        const SizedBox(height: 6),
        Text('${a.total} पृष्ठ · ${formatDuration((a.finishedAt ?? DateTime.now().millisecondsSinceEpoch) - a.startedAt)} · ${formatBytes(a.size ?? 0)}', style: GText.sans(size: 16)),
        const SizedBox(height: 4),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child:
              Text(_saved ? 'Downloads और फ़ाइल मैनेजर में सेव हो गया' : 'डिवाइस में सेव हो रहा है', key: ValueKey(_saved), style: GText.sans(size: 16, color: _saved ? GColors.online : GColors.text)),
        ),
        _doneActions(context, a, () => setState(() {})),
      ]),
    );
  }
}

/// One-time hint when PDF notifications can't be seen (permission refused or switched off).
Future<void> openNotifHint(BuildContext context) => showPop(context, (ctx) => const NotifHintCard());

class NotifHintCard extends StatelessWidget {
  const NotifHintCard({super.key});

  @override
  Widget build(BuildContext context) => FrostCard(
        key: const ValueKey('notif-hint'),
        maxWidth: 480,
        alpha: 0.92,
        radius: 18,
        border: GColors.gold,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
          Text('PDF की सूचना बंद है', style: GText.display(size: 22, color: GColors.maroon, height: 1.25)),
          const SizedBox(height: 8),
          Text('PDF बनने की प्रगति और “PDF तैयार” की सूचना देखने के लिए इस ऐप की सूचनाएँ (Notifications) चालू करें। PDF फिर भी बनती रहेगी।',
              style: GText.sans(size: 15, color: GColors.brown, height: 1.5)),
          const SizedBox(height: 14),
          Row(children: [
            Expanded(
              child: SheetButton(
                label: 'सेटिंग खोलें',
                primary: true,
                onTap: () {
                  Navigator.pop(context);
                  PdfNotify.I.openSettings();
                },
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: SheetButton(label: 'अभी नहीं', onTap: () => Navigator.pop(context))),
          ]),
        ]),
      );
}

/// `ng` — सेटिंग sheet (PDF style, layout, hidden card style after 5 taps on Version).
Future<void> openSettings(BuildContext context) => showPop(context, (ctx) => const _Settings());

/// Close the settings sheet, then go to a legal page (the sheet is a dialog above the page).
void _openLegal(BuildContext context, String link) {
  Navigator.pop(context);
  AppNav.I.openLink(link);
}

class _Settings extends StatefulWidget {
  const _Settings();
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  int _taps = 0;
  bool _looks = false;
  String _version = '1.0.0';

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((p) {
      if (mounted && p.version.isNotEmpty) setState(() => _version = p.version);
    }).catchError((_) {});
  }

  Widget _block(String title, List<Widget> picks) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: picks),
        ]),
      );

  /// Two pills "चालू" / "बंद" under a heading (same look as the layout picks).
  Widget _toggle(String id, String title, bool on, ValueChanged<bool> set) => _block(title, [
        Pill(key: ValueKey('set-$id-on'), direct: true, label: 'चालू', tone: on ? PillTone.maroon : PillTone.plain, onTap: () => set(true)),
        Pill(key: ValueKey('set-$id-off'), direct: true, label: 'बंद', tone: on ? PillTone.plain : PillTone.maroon, onTap: () => set(false)),
      ]);

  Future<void> _reset(BuildContext context) async {
    final ok = await confirmPop(context, 'सारी सेटिंग पहले जैसी (डिफ़ॉल्ट) हो जाएँगी। डाउनलोड किए ग्रंथ, पेज और PDF नहीं हटेंगे।');
    if (!ok) return;
    await UiPrefs.I.resetAll();
    Toast.show('सेटिंग रीसेट हो गई');
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: UiPrefs.I,
        builder: (context, _) => SheetCard(children: [
          // Every control here taps directly (TapTarget): a finger that wobbles a little, the
          // sheet's scroll view or the app-wide pinch layer can no longer swallow the tap.
          SheetHead(title: 'सेटिंग', onBack: () => Navigator.pop(context), direct: true),
          _block('PDF सेटिंग', [
            for (final o in pdfStyleOptions)
              Pill(key: ValueKey('set-pdf-${pdfStyleId(o.style)}'), direct: true, label: o.title, tone: UiPrefs.I.pdfStyle == o.style ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.pdfStyle = o.style),
          ]),
          _block('लेआउट', [
            for (final n in [1, 2])
              Pill(key: ValueKey('set-layout-$n'), direct: true, label: '$n×$n', tone: UiPrefs.I.uiCols == n ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.setLayout(n)),
          ]),
          // ---- Extra settings (not in the web app), same pills and headings ----
          _block('अक्षर का आकार', [
            for (final (id, title) in const [('small', 'छोटा'), ('normal', 'सामान्य'), ('large', 'बड़ा')])
              Pill(key: ValueKey('set-text-$id'), direct: true, label: title, tone: UiPrefs.I.textSize == id ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.textSize = id),
          ]),
          _block('एनिमेशन', [
            Pill(key: const ValueKey('set-anim-on'), direct: true, label: 'चालू', tone: UiPrefs.I.animations ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.animations = true),
            Pill(key: const ValueKey('set-anim-low'), direct: true, label: 'कम', tone: UiPrefs.I.animations ? PillTone.plain : PillTone.maroon, onTap: () => UiPrefs.I.animations = false),
          ]),
          _toggle('auto-sync', 'अपने-आप सिंक (हर 2 मिनट)', UiPrefs.I.autoSync, (v) => UiPrefs.I.autoSync = v),
          _toggle('wifi-only', 'पेज डाउनलोड सिर्फ़ WiFi पर', UiPrefs.I.wifiOnly, (v) => UiPrefs.I.wifiOnly = v),
          _toggle('keep-awake', 'पढ़ते समय स्क्रीन चालू रखें', UiPrefs.I.keepAwake, (v) => UiPrefs.I.keepAwake = v),
          const _StorageBlock(),
          _block('कानूनी और नीतियाँ', [
            Pill(key: const ValueKey('set-privacy'), direct: true, icon: 'shield', label: 'गोपनीयता नीति', onTap: () => _openLegal(context, '#/legal?p=privacy')),
            Pill(key: const ValueKey('set-legal'), direct: true, icon: 'file-text', label: 'सभी नीतियाँ और शर्तें', onTap: () => _openLegal(context, '#/legal')),
            ListenableBuilder(
              listenable: RemoteConfig.I,
              builder: (context, _) => Pill(key: const ValueKey('set-contacts'), direct: true, icon: 'users', label: RemoteConfig.I.contactsTitle, onTap: () => _openLegal(context, '#/legal?p=contacts')),
            ),
          ]),
          _block('ऐप के बारे में', [
            Pill(
              key: const ValueKey('set-share-app'),
              direct: true,
              icon: 'share-2',
              label: 'ऐप शेयर करें',
              onTap: () => FileActions.shareText('ग्रंथ प्रबंधन — सत ग्रंथों के प्रमाण', kPlayStoreUrl),
            ),
            Pill(key: const ValueKey('set-reset'), direct: true, label: 'सेटिंग रीसेट करें', onTap: () => _reset(context)),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: TapTarget(
              key: const ValueKey('set-version'),
              onTap: () => setState(() {
                _taps++;
                if (_taps >= 5) _looks = true;
              }),
              child: Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 8),
                child: Text('Version $_version', style: GText.sans(size: 12, color: GColors.muted)),
              ),
            ),
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: kRise,
            child: _looks
                ? _block('कार्ड स्टाइल', [
                    for (final (id, title) in cardLooks)
                      Pill(key: ValueKey('set-look-$id'), direct: true, label: title, tone: UiPrefs.I.look == id ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.look = id),
                  ])
                : const SizedBox(width: double.infinity),
          ),
        ]),
      );
}

/// Settings → स्टोरेज: saved pages n / total, space used, and the सिंक button's check +
/// repair (every saved picture is checked; damaged or missing ones download again).
class _StorageBlock extends StatefulWidget {
  const _StorageBlock();
  @override
  State<_StorageBlock> createState() => _StorageBlockState();
}

class _StorageBlockState extends State<_StorageBlock> {
  int? _bytes;

  @override
  void initState() {
    super.initState();
    _measure();
  }

  Future<void> _measure() async {
    try {
      final b = await Store.I.imagesBytes();
      if (mounted) setState(() => _bytes = b);
    } catch (_) {}
  }

  static String mb(int b) => b >= 1 << 30 ? '${(b / (1 << 30)).toStringAsFixed(1)} GB' : '${(b / (1 << 20)).toStringAsFixed(b < 10 << 20 ? 1 : 0)} MB';

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<ImageProgress>(
        valueListenable: CatalogStore.I.progress,
        builder: (context, p, _) {
          final s = CatalogStore.I;
          final total = s.allPages;
          final done = s.savedPages;
          final busy = p.running && p.manual;
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('स्टोरेज', style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon)),
              const SizedBox(height: 6),
              Text(
                key: const ValueKey('set-storage-text'),
                total > 0 ? 'सेव पेज $done / $total · ${_bytes == null ? '…' : mb(_bytes!)}' : 'पेज की सूची अभी नहीं आई',
                style: GText.sans(size: 14, color: GColors.brown),
              ),
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                Pill(
                  key: const ValueKey('set-repair'),
                  direct: true,
                  icon: 'refresh-cw',
                  label: busy ? (p.checking ? 'जाँच हो रही है… ${p.checked}/${p.total}' : 'ठीक हो रहा है… ${p.done}/${p.total}') : 'डेटा जाँचें और ठीक करें',
                  tone: busy ? PillTone.maroon : PillTone.plain,
                  onTap: busy
                      ? null
                      : () async {
                          await s.manualSync();
                          _measure();
                        },
                ),
              ]),
            ]),
          );
        },
      );
}

/// Exit confirmation (`.exit-card`).
Future<bool> openExit(BuildContext context) async {
  final r = await showPop<bool>(
    context,
    (ctx) => ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 440),
      child: Container(
        padding: const EdgeInsets.fromLTRB(22, 26, 22, 22),
        decoration: BoxDecoration(
          color: GColors.paper,
          border: Border.all(color: GColors.gold),
          borderRadius: BorderRadius.circular(22),
          boxShadow: [BoxShadow(color: GColors.shadow(0.32), blurRadius: 50, offset: const Offset(0, 22))],
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text('क्या आप बाहर निकलना चाहते हैं?', style: GText.display(size: 30, color: GColors.maroon, height: 1.3)),
          const SizedBox(height: 8),
          Text('ऐप बंद होगा। सेव किए हुए ग्रंथ और PDF फ़ोन पर रहेंगे।', style: GText.sans(size: 16, color: GColors.brown)),
          const SizedBox(height: 16),
          Row(children: [
            Expanded(child: SheetButton(label: 'हाँ, बाहर जाएँ', primary: true, onTap: () => Navigator.pop(ctx, true))),
            const SizedBox(width: 10),
            Expanded(child: SheetButton(label: 'नहीं, यहीं रहें', onTap: () => Navigator.pop(ctx, false))),
          ]),
        ]),
      ),
    ),
  );
  return r ?? false;
}
