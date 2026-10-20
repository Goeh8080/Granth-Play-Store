import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../models/models.dart';
import '../services/file_actions.dart';
import '../services/gallery_service.dart';
import '../services/pdf_builder.dart';
import '../services/pdf_queue.dart';
import '../state/toast.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import 'common.dart';
import 'overlays.dart';

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

void _run(PdfRequest r, PdfStyle s) {
  switch (r) {
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

/// `.pdf-deck` — progress of every queued PDF with पिछला / अगला navigation.
Future<void> openDeck(BuildContext context, {int? index}) => showPop(context, (ctx) => _Deck(start: index ?? 0));

class _Deck extends StatefulWidget {
  const _Deck({required this.start});
  final int start;
  @override
  State<_Deck> createState() => _DeckState();
}

class _DeckState extends State<_Deck> {
  late int _i = widget.start;
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) => mounted ? setState(() {}) : null);
    PdfQueue.I.finished.addListener(_onDone);
  }

  void _onDone() {
    if (mounted && Navigator.of(context).canPop()) Navigator.of(context).pop();
  }

  @override
  void dispose() {
    _tick?.cancel();
    PdfQueue.I.finished.removeListener(_onDone);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: PdfQueue.I,
        builder: (context, _) {
          final jobs = PdfQueue.I.jobs;
          if (jobs.isEmpty) return const SizedBox.shrink();
          final i = _i.clamp(0, jobs.length - 1);
          final m = jobs[i];
          final now = DateTime.now().millisecondsSinceEpoch;
          return FrostCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Text('${i + 1}/${jobs.length}', style: GText.sans(size: 16, weight: FontWeight.w700)),
                TweenAnimationBuilder<double>(
                  tween: Tween(end: m.percent.toDouble()),
                  duration: const Duration(milliseconds: 420),
                  builder: (context, v, _) => Text('${v.round()}%', style: GText.sans(size: 16)),
                ),
              ]),
              const SizedBox(height: 6),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Text(m.title, key: ValueKey(m.id), style: GText.display(size: 22, color: GColors.maroon, height: 1.25)),
              ),
              const SizedBox(height: 6),
              PdfMeter(percent: m.percent),
              Text(jobLine(m, now), style: GText.sans(size: 14)),
              const SizedBox(height: 4),
              Text(phaseText(m), style: GText.sans(size: 14)),
              const SizedBox(height: 10),
              Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                Pill(label: 'बंद', onTap: () => Navigator.pop(context)),
                Pill(icon: 'chevron-left', label: 'पिछला', enabled: i > 0, onTap: () => setState(() => _i = (i - 1).clamp(0, jobs.length - 1))),
                Pill(trailingIcon: 'chevron-right', label: 'अगला', enabled: i < jobs.length - 1, onTap: () => setState(() => _i = (i + 1).clamp(0, jobs.length - 1))),
              ]),
              if (m.active) ...[const SizedBox(height: 10), SheetButton(label: 'रोकें', onTap: () => PdfQueue.I.cancel(m.id))],
              if (m.phase == PdfPhase.done && m.filePath != null) _doneActions(context, m, () => setState(() {})),
            ]),
          );
        },
      );
}

/// `.pdf-done` — shown when a PDF finishes; it is also copied to Downloads automatically.
Future<void> openDone(BuildContext context, PdfJob job, Future<bool> exported) =>
    showPop(context, (ctx) => _Done(job: job, exported: exported));

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
        Text('${a.total} पृष्ठ · ${formatDuration((a.finishedAt ?? DateTime.now().millisecondsSinceEpoch) - a.startedAt)} · ${formatBytes(a.size ?? 0)}',
            style: GText.sans(size: 16)),
        const SizedBox(height: 4),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: Text(_saved ? 'Downloads और फ़ाइल मैनेजर में सेव हो गया' : 'डिवाइस में सेव हो रहा है',
              key: ValueKey(_saved), style: GText.sans(size: 16, color: _saved ? GColors.online : GColors.text)),
        ),
        _doneActions(context, a, () => setState(() {})),
      ]),
    );
  }
}

/// `ng` — सेटिंग sheet (PDF style, layout, hidden card style after 5 taps on Version).
Future<void> openSettings(BuildContext context) => showPop(context, (ctx) => const _Settings());

class _Settings extends StatefulWidget {
  const _Settings();
  @override
  State<_Settings> createState() => _SettingsState();
}

class _SettingsState extends State<_Settings> {
  int _taps = 0;
  bool _looks = false;
  String _version = '1.0.1';

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

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: UiPrefs.I,
        builder: (context, _) => SheetCard(children: [
          SheetHead(title: 'सेटिंग', onBack: () => Navigator.pop(context)),
          _block('PDF सेटिंग', [
            for (final o in pdfStyleOptions)
              Pill(label: o.title, tone: UiPrefs.I.pdfStyle == o.style ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.pdfStyle = o.style),
          ]),
          _block('लेआउट', [
            for (final n in [1, 2]) Pill(label: '$n×$n', tone: UiPrefs.I.uiCols == n ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.setLayout(n)),
          ]),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
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
                      Pill(label: title, tone: UiPrefs.I.look == id ? PillTone.maroon : PillTone.plain, onTap: () => UiPrefs.I.look = id),
                  ])
                : const SizedBox(width: double.infinity),
          ),
        ]),
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
