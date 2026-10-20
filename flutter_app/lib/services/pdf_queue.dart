import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../models/models.dart';
import 'api.dart';
import 'catalog_store.dart';
import 'events.dart';
import 'file_actions.dart';
import 'gallery_service.dart';
import 'image_cache.dart';
import 'order.dart';
import 'pdf_builder.dart';
import 'storage.dart';

enum PdfPhase { queue, images, pages, save, done, cancelled, error }

class PdfJob {
  PdfJob({required this.id, required this.title, required this.fileName, required this.galleryId, this.topic = '', this.granth = '', this.granthId = '', this.text = ''});
  final String id;
  final String title;
  final String fileName;
  final String galleryId;
  final String topic;
  final String granth;
  final String granthId;
  final String text;
  PdfPhase phase = PdfPhase.queue;
  int done = 0;
  int total = 1;
  int percent = 0;
  int? etaMs;
  int startedAt = DateTime.now().millisecondsSinceEpoch;
  int? finishedAt;
  String? filePath;
  int? size;
  Uint8List? preview;
  String? error;
  bool cancelled = false;
  bool retried = false;

  bool get active => phase == PdfPhase.queue || phase == PdfPhase.images || phase == PdfPhase.pages || phase == PdfPhase.save;
}

typedef _Run = Future<Uint8List> Function(PdfJob job, void Function(PdfPhase, int, int) report);

/// `Nt`/`Ft` — PDF job queue: one job at a time, one automatic retry, cancel, ETA, max 12 rows.
class PdfQueue extends ChangeNotifier {
  PdfQueue._();
  static final PdfQueue I = PdfQueue._();

  final List<PdfJob> jobs = [];
  final List<(PdfJob, _Run)> _pending = [];
  bool _running = false;
  int _peak = 0;

  /// Fired when a job finishes (the "PDF तैयार" card).
  final ValueNotifier<PdfJob?> finished = ValueNotifier(null);

  int get activeCount => jobs.where((j) => j.active).length;

  String _id() => 'pdf-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 20).toRadixString(36)}';

  int _percent(PdfPhase p, int done, int total) {
    if (p == PdfPhase.done) return 100;
    if (p == PdfPhase.save) return 99;
    final r = done / math.max(1, total);
    final i = (p == PdfPhase.images ? r * 15 : r * 99).round();
    _peak = math.max(_peak, math.min(99, i));
    return _peak;
  }

  int? _eta(int started, int pct) {
    if (pct < 4) return null;
    final n = DateTime.now().millisecondsSinceEpoch - started;
    return n < 500 ? null : math.max(1000, ((100 - pct) / pct * n).round());
  }

  void _enqueue(PdfJob job, _Run run) {
    jobs.insert(0, job);
    if (jobs.length > 12) jobs.removeRange(12, jobs.length);
    _pending.add((job, run));
    notifyListeners();
    _pump();
  }

  void cancel(String id) {
    for (final j in jobs) {
      if (j.id == id) {
        j.cancelled = true;
        j.phase = PdfPhase.cancelled;
        j.etaMs = 0;
      }
    }
    notifyListeners();
  }

  Future<void> _pump() async {
    if (_running) return;
    _running = true;
    try {
      while (_pending.isNotEmpty) {
        final (job, run) = _pending.removeAt(0);
        if (job.cancelled) continue;
        final started = DateTime.now().millisecondsSinceEpoch;
        _peak = 0;
        job
          ..phase = PdfPhase.pages
          ..startedAt = started
          ..percent = 0
          ..done = 0
          ..total = 1;
        notifyListeners();
        try {
          final bytes = await run(job, (p, d, t) {
            if (job.cancelled) return;
            final pct = _percent(p, d, t);
            job
              ..phase = p
              ..done = d
              ..total = t
              ..percent = pct
              ..etaMs = _eta(started, pct);
            notifyListeners();
          });
          if (job.cancelled) {
            job.phase = PdfPhase.cancelled;
            notifyListeners();
            continue;
          }
          final file = await FileActions.writeLocal(bytes, job.fileName);
          job
            ..phase = PdfPhase.done
            ..percent = 100
            ..etaMs = 0
            ..filePath = file.path
            ..size = bytes.length
            ..finishedAt = DateTime.now().millisecondsSinceEpoch;
          notifyListeners();
          finished.value = job;
          EventLog.I.log('pdf_download', job.granthId.isNotEmpty ? job.granthId : job.id, job.fileName);
        } catch (e) {
          if (job.cancelled || e is PdfCancelled) {
            job.phase = PdfPhase.cancelled;
            job.etaMs = 0;
          } else if (job.retried) {
            job
              ..phase = PdfPhase.error
              ..etaMs = 0
              ..error = e is StateError ? e.message : 'PDF नहीं बनी';
          } else {
            job.retried = true;
            _pending.insert(0, (job, run));
          }
          notifyListeners();
        }
      }
    } finally {
      _running = false;
      if (_pending.isNotEmpty) unawaited(_pump());
    }
  }

  // ---------- spec builders (Nh / Ph / Fh) ----------

  static PdfSpec pramanSpec(Praman e) => PdfSpec(
        title: e.title,
        subtitle: e.topicTitle,
        body: e.description.isNotEmpty ? e.description : (e.topicTitle.isNotEmpty ? e.topicTitle : e.title),
        meta: [e.granthTitle, e.granthAuthor].where((x) => x.isNotEmpty).join(' · '),
        path: e.imagePath,
      );

  static List<PdfSpec> granthSpecs(Granth e) => [
        PdfSpec(title: e.title, subtitle: e.author, body: e.description.isNotEmpty ? e.description : e.title, path: e.imagePath, cover: true),
        if (mediaPath(e.editorImagePath) != null)
          PdfSpec(
            title: e.title,
            subtitle: 'प्रकाशन',
            body: e.author.isNotEmpty ? 'प्रकाशन · ${e.author}' : 'प्रकाशन विवरण',
            meta: 'प्रकाशन विवरण',
            path: e.editorImagePath,
            cover: true,
          ),
      ];

  static ({List<Praman> proofs, List<PdfSpec> specs, List<String> granthIds}) topicSpecs(Topic t) {
    final store = CatalogStore.I;
    final proofs = orderPramans(store.pramans.where((p) => p.topicId == t.id).toList());
    final byId = {for (final g in store.granths) g.id: g};
    final specs = <PdfSpec>[PdfSpec(title: t.title, subtitle: 'विषय', body: t.description, meta: '${proofs.length} प्रमाण', topicCover: true)];
    final ids = <String>[];
    final seen = <String>{};
    for (final p in proofs) {
      if (seen.add(p.granthId)) {
        ids.add(p.granthId);
        final g = byId[p.granthId];
        if (g != null) specs.addAll(granthSpecs(g));
      }
      specs.add(pramanSpec(p));
    }
    return (proofs: proofs, specs: specs, granthIds: ids);
  }

  /// `kh`
  static String fileNameFor(String title, String fallback) {
    final t = title.replaceAll(RegExp(r'[\\/:*?"<>|]+'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
    final cut = t.length > 70 ? t.substring(0, 70) : t;
    return '${cut.isEmpty ? fallback : cut}.pdf';
  }

  static PdfStyle currentStyle() => pdfStyleFrom(Store.I.getString(Store.kPdfStyle));

  /// `jh` — load page images (8 at a time) then assemble.
  static Future<Uint8List> _assemble(List<PdfSpec> specs, PdfStyle style, PdfJob job, void Function(PdfPhase, int, int) report) async {
    final a = math.max(1, specs.length);
    report(PdfPhase.pages, 0, a);
    var loaded = 0;
    var next = 0;
    Future<void> worker() async {
      while (next < specs.length) {
        if (job.cancelled) return;
        final s = specs[next++];
        final p = mediaPath(s.path);
        if (p != null) {
          final f = await ImageStore.I.get(p);
          if (f != null) s.image = await File(f.path).readAsBytes();
        }
        loaded++;
        report(PdfPhase.images, loaded, a);
      }
    }

    await Future.wait(List.generate(math.min(8, specs.length), (_) => worker()));
    if (job.cancelled) throw PdfCancelled();
    final builder = BookPdfBuilder(
      isCancelled: () => job.cancelled,
      onPage: (d, t) => report(PdfPhase.pages, d, t),
      onPreview: (b) => job.preview = b,
    );
    return builder.build(specs, style);
  }

  /// `Mh` — keep every finished PDF in the in-app gallery.
  static Future<void> _toGallery(PdfJob job, Uint8List bytes, {required String id, required String title, String text = '', String topic = '', String granth = ''}) async {
    if (bytes.length < 64) throw StateError('PDF खाली रह गई');
    try {
      await GalleryService.I.put(id: id, kind: GalleryKind.pdf, title: title, text: text, topic: topic, granth: granth, fileName: job.fileName, bytes: bytes, preview: job.preview);
    } catch (_) {}
  }

  void granthPdf(Granth g, PdfStyle style) {
    final proofs = orderPramans(CatalogStore.I.pramans.where((p) => p.granthId == g.id).toList(), g.title);
    final specs = [...granthSpecs(g), ...proofs.map(pramanSpec)];
    final job = PdfJob(
      id: _id(),
      title: g.title,
      fileName: fileNameFor(g.title, 'granth-${g.id}'),
      galleryId: 'pdf-granth-${g.id}',
      granth: g.title,
      granthId: g.id,
      text: [g.description, ...proofs.map((e) => e.title)].where((e) => e.isNotEmpty).join('\n'),
    );
    _enqueue(job, (job, report) async {
      final bytes = await _assemble(specs, style, job, report);
      report(PdfPhase.save, specs.length, specs.length);
      await _toGallery(job, bytes, id: 'pdf-granth-${g.id}', title: g.title, text: g.description, granth: g.title);
      CatalogStore.I.markOffline([g.id]);
      return bytes;
    });
  }

  void topicPdf(Topic t, PdfStyle style) {
    final r = topicSpecs(t);
    final job = PdfJob(
      id: _id(),
      title: t.title,
      fileName: fileNameFor(t.title, 'topic-${t.id}'),
      galleryId: 'pdf-topic-${t.id}',
      topic: t.title,
      text: [t.description, ...r.proofs.map((e) => e.title)].where((e) => e.isNotEmpty).join('\n'),
    );
    _enqueue(job, (job, report) async {
      final bytes = await _assemble(r.specs, style, job, report);
      report(PdfPhase.save, r.specs.length, r.specs.length);
      await _toGallery(job, bytes, id: 'pdf-topic-${t.id}', title: t.title, text: t.description, topic: t.title);
      CatalogStore.I.markOffline(r.granthIds);
      return bytes;
    });
  }

  /// `Ih` — one combined PDF for several topics.
  void multiTopicPdf(List<Topic> topics) {
    if (topics.isEmpty) return;
    final style = currentStyle();
    final parts = topics.map(topicSpecs).toList();
    final specs = parts.expand((e) => e.specs).toList();
    final ids = parts.expand((e) => e.granthIds).toSet().toList();
    final title = topics.length == 1 ? (topics.first.title.isEmpty ? 'विषय' : topics.first.title) : '${topics.length} विषय';
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final job = PdfJob(
      id: _id(),
      title: title,
      fileName: fileNameFor(title, 'topics-$stamp'),
      galleryId: 'pdf-topics-$stamp',
      topic: topics.map((e) => e.title).join(' · '),
      text: topics.map((e) => e.title).join('\n'),
    );
    _enqueue(job, (job, report) async {
      final bytes = await _assemble(specs, style, job, report);
      report(PdfPhase.save, specs.length, specs.length);
      await _toGallery(job, bytes,
          id: 'pdf-topics-${DateTime.now().millisecondsSinceEpoch}',
          title: title,
          text: topics.map((e) => e.description).where((e) => e.isNotEmpty).join('\n'),
          topic: topics.map((e) => e.title).join(' · '));
      CatalogStore.I.markOffline(ids);
      return bytes;
    });
  }

  void pramanPdf(Praman p, PdfStyle style) {
    final spec = PdfSpec(title: p.title, subtitle: p.granthTitle, body: p.description, meta: p.topicTitle, path: p.imagePath);
    final job = PdfJob(
      id: _id(),
      title: p.title,
      fileName: fileNameFor(p.title, 'praman-${p.id}'),
      galleryId: 'pdf-praman-${p.id}',
      topic: p.topicTitle,
      granth: p.granthTitle,
      granthId: p.granthId,
      text: p.description,
    );
    _enqueue(job, (job, report) async {
      final bytes = await _assemble([spec], style, job, report);
      report(PdfPhase.save, 1, 1);
      await _toGallery(job, bytes, id: 'pdf-praman-${p.id}', title: p.title, text: p.description, topic: p.topicTitle, granth: p.granthTitle);
      if (p.granthId.isNotEmpty) CatalogStore.I.markOffline([p.granthId]);
      return bytes;
    });
  }
}

/// `It`
String formatBytes(int e) => e < 1024 ? '$e B' : (e < 1048576 ? '${(e / 1024).toStringAsFixed(1)} KB' : '${(e / 1048576).toStringAsFixed(1)} MB');

/// `Lt`
String formatDuration(int ms) {
  final t = math.max(0, (ms / 1000).round());
  final n = t ~/ 60;
  final r = t % 60;
  return n > 0 ? '$n मि $r से' : '$t सेकंड';
}

/// `Rt`
String etaText(int? e, PdfPhase t) {
  switch (t) {
    case PdfPhase.done:
      return 'पूरा हो गया';
    case PdfPhase.cancelled:
      return 'रुक गया';
    case PdfPhase.error:
      return 'रुका — त्रुटि';
    case PdfPhase.queue:
      return 'कतार में';
    default:
      break;
  }
  if (e == null) return 'समय गिना जा रहा है';
  final n = math.max(1, (e / 1000).round());
  return n < 60 ? '$n सेकंड शेष' : '${n ~/ 60} मि ${n % 60} से शेष';
}

/// `Yh`
String jobLine(PdfJob e, int now) {
  final end = e.finishedAt ?? now;
  final took = formatDuration(math.max(0, end - e.startedAt));
  final first = (e.phase == PdfPhase.pages || e.phase == PdfPhase.done)
      ? '${e.phase == PdfPhase.done ? e.total : e.done}/${e.total} पृष्ठ'
      : (e.phase == PdfPhase.images ? '${e.done}/${e.total} चित्र' : '');
  return [first, '$took लगे', etaText(e.etaMs, e.phase)].where((s) => s.isNotEmpty).join(' · ');
}

String phaseText(PdfJob m) {
  if (m.error != null) return m.error!;
  final p = switch (m.phase) {
    PdfPhase.images => 'चित्र बन रहे हैं',
    PdfPhase.pages => 'पृष्ठ जुड़ रहे हैं',
    PdfPhase.save => 'सेव हो रहा है',
    PdfPhase.done => 'तैयार',
    _ => 'कतार में',
  };
  return '${m.percent}% · $p';
}
