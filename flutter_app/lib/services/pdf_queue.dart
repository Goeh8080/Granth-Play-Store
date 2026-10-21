import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../models/models.dart';
import 'api.dart';
import 'catalog_store.dart';
import 'device_profile.dart';
import 'events.dart';
import 'file_actions.dart';
import 'gallery_service.dart';
import 'image_cache.dart';
import 'native_bridge.dart';
import 'order.dart';
import 'pdf_builder.dart';
import 'storage.dart';

enum PdfPhase { waiting, images, pages, save, done, cancelled, error }

/// Clear Hindi message shown on a failed PDF row (with a "फिर कोशिश करें" button).
const kPdfFailed = 'PDF नहीं बन पाई। इंटरनेट और फ़ोन की जगह जाँचकर “फिर कोशिश करें” दबाएँ।';

/// Shown when the phone has too little free space for the PDF (no automatic retry).
String pdfNoSpaceMessage(int? freeBytes) {
  final free = freeBytes == null ? '' : ' (अभी ${formatBytes(freeBytes)} खाली)';
  return 'फ़ोन में जगह कम है$free। कुछ जगह खाली करके “फिर कोशिश करें” दबाएँ।';
}

/// Not enough free storage for the PDF and its copies.
class PdfNoSpace implements Exception {
  PdfNoSpace(this.freeBytes);
  final int? freeBytes;
  @override
  String toString() => 'PdfNoSpace($freeBytes)';
}

bool _isNoSpace(Object e) {
  if (e is PdfNoSpace) return true;
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    final msg = '${e.message} ${e.osError?.message}'.toLowerCase();
    return code == 28 || msg.contains('no space') || msg.contains('enospc');
  }
  return false;
}

/// Builds the PDF and returns the path of the finished (temporary) file.
typedef PdfRun = Future<String> Function(PdfJob job, void Function(PdfPhase, int, int) report);

class PdfJob {
  PdfJob({required this.id, required this.title, required this.fileName, required this.galleryId, this.topic = '', this.granth = '', this.granthId = '', this.text = '', this.weight = 1, this.pages = 1, String? dedupeKey})
      : dedupeKey = dedupeKey ?? galleryId;
  final String id;
  final String title;
  final String fileName;
  final String galleryId;
  final String topic;
  final String granth;
  final String granthId;
  final String text;

  /// Concurrency slots this job uses (very large books take two so memory stays bounded).
  final int weight;

  /// Number of page specs — used for the free-space check and the memory budget.
  final int pages;

  /// Two taps that ask for the same PDF while it is still being made share one job.
  final String dedupeKey;
  PdfPhase phase = PdfPhase.waiting;
  int done = 0;
  int total = 1;
  int percent = 0;
  int peak = 0;
  int? etaMs;
  int startedAt = DateTime.now().millisecondsSinceEpoch;
  int? finishedAt;
  String? filePath;
  int? size;
  Uint8List? preview;
  String? error;
  int missingImages = 0;
  bool cancelled = false;
  int attempts = 0;
  PdfRun? run;

  bool get active => phase == PdfPhase.waiting || phase == PdfPhase.images || phase == PdfPhase.pages || phase == PdfPhase.save;
  bool get canRetry => phase == PdfPhase.error || phase == PdfPhase.cancelled;
}

/// PDF maker. There is no visible queue any more: every requested PDF starts right away
/// and gets its own progress row. Internally at most [maxSlots] build at the same time
/// (to avoid running out of memory on big granths); each job retries once on its own, and
/// a failed job can be retried without touching the others.
class PdfQueue extends ChangeNotifier {
  PdfQueue._();
  static final PdfQueue I = PdfQueue._();

  /// Fresh state for tests.
  @visibleForTesting
  void debugReset() {
    for (final j in jobs) {
      j.cancelled = true;
    }
    jobs.clear();
    _waiting.clear();
    _busy = 0;
    slotsOverride = null;
    freeBytes = NativeBridge.freeBytes;
    retryDelay = const Duration(milliseconds: 800);
    finished.value = null;
  }

  /// PDFs built at the same time: 3 on ordinary phones, 1–2 on low-RAM phones.
  int get maxSlots => slotsOverride ?? DeviceProfile.I.pdfSlots;
  @visibleForTesting
  int? slotsOverride;
  static const maxRows = 40;

  /// Two requests for the same PDF closer than this are one tap (a double tap).
  static const doubleTapWindowMs = 1500;

  /// Free-space probe (native StatFs). Replaceable in tests.
  @visibleForTesting
  Future<int?> Function() freeBytes = NativeBridge.freeBytes;

  /// Rough bytes needed: the PDF (~300 KB a page) is kept in the app folder, in the
  /// in-app gallery and copied to Downloads, plus a safety margin.
  static int bytesNeeded(int pages) => math.max(1, pages) * 300 * 1024 * 3 + (25 << 20);

  final List<PdfJob> jobs = [];
  final List<PdfJob> _waiting = [];
  int _busy = 0;

  /// Fired when a job finishes (the "PDF तैयार" card / auto-save to Downloads).
  final ValueNotifier<PdfJob?> finished = ValueNotifier(null);

  int get activeCount => jobs.where((j) => j.active).length;

  @visibleForTesting
  int get runningSlots => _busy;

  String _id() => 'pdf-${DateTime.now().millisecondsSinceEpoch}-${math.Random().nextInt(1 << 20).toRadixString(36)}';

  int _percent(PdfJob j, PdfPhase p, int done, int total) {
    if (p == PdfPhase.done) return 100;
    if (p == PdfPhase.save) return 99;
    final r = done / math.max(1, total);
    final i = (p == PdfPhase.images ? r * 15 : r * 99).round();
    j.peak = math.max(j.peak, math.min(99, i));
    return j.peak;
  }

  int? _eta(int started, int pct) {
    if (pct < 4) return null;
    final n = DateTime.now().millisecondsSinceEpoch - started;
    return n < 500 ? null : math.max(1000, ((100 - pct) / pct * n).round());
  }

  /// Starts [job] (as soon as a slot is free). Exposed for tests.
  @visibleForTesting
  PdfJob start(PdfJob job, PdfRun run) {
    // Accidental double tap (same PDF asked twice within a moment): keep the first job.
    // A PDF asked for again on purpose later gets its own entry, even while the first runs.
    final now = DateTime.now().millisecondsSinceEpoch;
    final same = jobs.where((j) => j.active && j.dedupeKey == job.dedupeKey && now - j.startedAt < doubleTapWindowMs).firstOrNull;
    if (same != null) return same;
    job.run = run;
    jobs.insert(0, job);
    _trim();
    _waiting.add(job);
    notifyListeners();
    _pump();
    return job;
  }

  void _trim() {
    while (jobs.length > maxRows) {
      final i = jobs.lastIndexWhere((j) => !j.active);
      if (i < 0) break;
      jobs.removeAt(i);
    }
  }

  void cancel(String id) {
    for (final j in jobs) {
      if (j.id == id && j.active) {
        j.cancelled = true;
        j.phase = PdfPhase.cancelled;
        j.etaMs = 0;
        _waiting.remove(j);
      }
    }
    notifyListeners();
  }

  /// Re-runs one failed or stopped PDF; the other rows are not affected.
  void retry(String id) {
    final j = jobs.where((e) => e.id == id).firstOrNull;
    if (j == null || !j.canRetry || j.run == null) return;
    j
      ..cancelled = false
      ..error = null
      ..attempts = 0
      ..phase = PdfPhase.waiting
      ..percent = 0
      ..peak = 0
      ..done = 0
      ..etaMs = null
      ..finishedAt = null;
    _waiting.add(j);
    notifyListeners();
    _pump();
  }

  /// Removes a finished / failed row from the list.
  void dismiss(String id) {
    jobs.removeWhere((j) => j.id == id && !j.active);
    notifyListeners();
  }

  /// × on a row: a running PDF is stopped first (the UI asks before), then the row is gone
  /// for good — the list lives only in memory, so nothing brings it back after a restart.
  void remove(String id) {
    final j = jobs.where((e) => e.id == id).firstOrNull;
    if (j == null) return;
    if (j.active) cancel(id);
    jobs.remove(j);
    _waiting.remove(j);
    notifyListeners();
  }

  /// "तैयार हटाएँ": drops every finished / failed / stopped row.
  void clearFinished() {
    jobs.removeWhere((j) => !j.active);
    notifyListeners();
  }

  /// Overall progress of the PDFs being made (for the status-bar notification).
  int get overallPercent {
    final a = jobs.where((j) => j.active).toList();
    if (a.isEmpty) return 100;
    return (a.fold<int>(0, (n, j) => n + j.percent) / a.length).round();
  }

  void _pump() {
    while (_waiting.isNotEmpty) {
      final next = _waiting.first;
      final w = math.min(next.weight, maxSlots);
      if (_busy > 0 && _busy + w > maxSlots) return;
      _waiting.removeAt(0);
      if (next.cancelled) continue;
      _busy += w;
      unawaited(_runJob(next).whenComplete(() {
        _busy -= w;
        _pump();
      }));
    }
  }

  Future<void> _runJob(PdfJob job) async {
    var stalls = 0;
    while (true) {
      final started = DateTime.now().millisecondsSinceEpoch;
      job
        ..attempts += 1
        ..phase = PdfPhase.images
        ..startedAt = started
        ..percent = 0
        ..peak = 0
        ..done = 0
        ..total = 1
        ..missingImages = 0;
      notifyListeners();
      try {
        // Check storage before doing any work (clear message instead of a half-written file).
        final free = await freeBytes().catchError((Object _) => null);
        if (free != null && free < bytesNeeded(job.pages)) throw PdfNoSpace(free);
        final built = await job.run!(job, (p, d, t) {
          if (job.cancelled) return;
          final pct = _percent(job, p, d, t);
          job
            ..phase = p
            ..done = d
            ..total = t
            ..percent = pct
            ..etaMs = _eta(started, pct);
          notifyListeners();
        });
        if (job.cancelled) {
          await _deleteQuietly(built);
          throw PdfCancelled();
        }
        final file = await FileActions.moveLocal(built, job.fileName);
        final size = await file.length();
        if (job.cancelled) {
          // Stopped while saving: do not leave the file behind.
          try {
            await file.delete();
          } catch (_) {}
          throw PdfCancelled();
        }
        job
          ..phase = PdfPhase.done
          ..percent = 100
          ..etaMs = 0
          ..filePath = file.path
          ..size = size
          ..finishedAt = DateTime.now().millisecondsSinceEpoch;
        notifyListeners();
        finished.value = job;
        try {
          EventLog.I.log('pdf_download', job.granthId.isNotEmpty ? job.granthId : job.id, job.fileName);
        } catch (_) {}
        return;
      } catch (e, st) {
        if (job.cancelled || e is PdfCancelled) {
          job
            ..phase = PdfPhase.cancelled
            ..etaMs = 0;
          notifyListeners();
          return;
        }
        debugPrint('PDF "${job.title}" attempt ${job.attempts} failed: $e\n$st');
        if (_isNoSpace(e)) {
          final free = e is PdfNoSpace ? e.freeBytes : await freeBytes().catchError((Object _) => null);
          _fail(job, pdfNoSpaceMessage(free));
          return;
        }
        if (e is PdfRenderStalled && stalls < 3) {
          // Drawing stopped while the app was in the background: continue when it is back.
          stalls++;
          job.phase = PdfPhase.waiting;
          notifyListeners();
          await waitForeground();
          if (job.cancelled) return;
          job.attempts -= 1;
          continue;
        }
        if (job.attempts < 2) {
          await Future<void>.delayed(retryDelay);
          if (job.cancelled) return;
          continue; // one automatic retry
        }
        _fail(job, e is OutOfMemoryError ? 'फ़ोन की मेमोरी कम पड़ गई। दूसरे ऐप बंद करके “फिर कोशिश करें” दबाएँ।' : kPdfFailed);
        return;
      }
    }
  }

  static Future<void> _deleteQuietly(String path) async {
    try {
      final f = File(path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// Temporary file a job builds into (`*.part`, removed on failure / next start).
  static String workPath(PdfJob job) => '${Store.I.pdfDir}/${job.id}.pdf.part';

  void _fail(PdfJob job, String message) {
    job
      ..phase = PdfPhase.error
      ..etaMs = 0
      ..error = message
      ..finishedAt = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  @visibleForTesting
  Duration retryDelay = const Duration(milliseconds: 800);

  /// Resolves when the app is in the foreground (or after 10 minutes at most).
  static Future<void> waitForeground() async {
    for (var i = 0; i < 600; i++) {
      final s = WidgetsBinding.instance.lifecycleState;
      if (s == null || s == AppLifecycleState.resumed) return;
      await Future<void>.delayed(const Duration(seconds: 1));
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

  /// Fetches one page picture: cached file, otherwise download with a timeout and
  /// up to 3 attempts. Returns null instead of failing the PDF.
  static Future<String?> fetchImage(String path, {int attempts = 3, Duration timeout = const Duration(seconds: 45)}) async {
    for (var i = 0; i < attempts; i++) {
      try {
        final f = await ImageStore.I.get(path).timeout(timeout);
        if (f != null) return f.path;
      } catch (_) {}
      if (i < attempts - 1) await Future<void>.delayed(Duration(milliseconds: 600 * (i + 1)));
    }
    return null;
  }

  /// `jh` — make sure page images are on the device (8 at a time) then assemble.
  /// A picture that cannot be fetched becomes a placeholder; it never fails the PDF.
  static Future<String> _assemble(List<PdfSpec> specs, PdfStyle style, PdfJob job, void Function(PdfPhase, int, int) report) async {
    final a = math.max(1, specs.length);
    report(PdfPhase.images, 0, a);
    var loaded = 0;
    var next = 0;
    var missing = 0;
    Future<void> worker() async {
      while (next < specs.length) {
        if (job.cancelled) return;
        final s = specs[next++];
        s.missing = false;
        final p = mediaPath(s.path);
        if (p != null && s.image == null) {
          final f = await fetchImage(p);
          if (f != null) {
            s.file = f;
          } else {
            s.missing = true;
            missing++;
          }
        }
        loaded++;
        report(PdfPhase.images, loaded, a);
      }
    }

    final p = DeviceProfile.I;
    await Future.wait(List.generate(math.min(p.imageWorkers, specs.length), (_) => worker()));
    if (job.cancelled) throw PdfCancelled();
    job.missingImages = missing;
    final builder = BookPdfBuilder(
      lookAhead: p.pdfLookAhead,
      maxHeldBytes: p.pdfHeldBytes,
      isCancelled: () => job.cancelled,
      onPage: (d, t) => report(PdfPhase.pages, d, t),
      onPreview: (b) => job.preview = b,
    );
    final out = workPath(job);
    await builder.buildToFile(specs, style, out);
    return out;
  }

  /// `Mh` — keep every finished PDF in the in-app gallery.
  static Future<void> _toGallery(PdfJob job, String path, {required String id, required String title, String text = '', String topic = '', String granth = ''}) async {
    try {
      await GalleryService.I.putFile(id: id, kind: GalleryKind.pdf, title: title, text: text, topic: topic, granth: granth, fileName: job.fileName, source: path, preview: job.preview);
    } catch (e) {
      // The PDF itself is fine; only the in-app gallery copy failed (e.g. low space).
      if (_isNoSpace(e)) rethrow;
    }
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
      weight: specs.length > 150 ? 2 : 1,
      pages: specs.length,
    );
    start(job, (job, report) async {
      final built = await _assemble(specs, style, job, report);
      report(PdfPhase.save, specs.length, specs.length);
      await _toGallery(job, built, id: 'pdf-granth-${g.id}', title: g.title, text: g.description, granth: g.title);
      CatalogStore.I.markOffline([g.id]);
      return built;
    });
  }

  /// Several granth PDFs at once (multi-select on the Granths screen). Each one is a
  /// separate PDF with its own progress row; they build in parallel.
  void granthPdfs(List<Granth> granths, PdfStyle style) {
    for (final g in granths) {
      granthPdf(g, style);
    }
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
      weight: r.specs.length > 150 ? 2 : 1,
      pages: r.specs.length,
    );
    start(job, (job, report) async {
      final built = await _assemble(r.specs, style, job, report);
      report(PdfPhase.save, r.specs.length, r.specs.length);
      await _toGallery(job, built, id: 'pdf-topic-${t.id}', title: t.title, text: t.description, topic: t.title);
      CatalogStore.I.markOffline(r.granthIds);
      return built;
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
      weight: specs.length > 150 ? 2 : 1,
      pages: specs.length,
      dedupeKey: 'pdf-topics:${(topics.map((e) => e.id).toList()..sort()).join(',')}',
    );
    start(job, (job, report) async {
      final built = await _assemble(specs, style, job, report);
      report(PdfPhase.save, specs.length, specs.length);
      await _toGallery(job, built,
          id: 'pdf-topics-${DateTime.now().millisecondsSinceEpoch}',
          title: title,
          text: topics.map((e) => e.description).where((e) => e.isNotEmpty).join('\n'),
          topic: topics.map((e) => e.title).join(' · '));
      CatalogStore.I.markOffline(ids);
      return built;
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
    start(job, (job, report) async {
      final built = await _assemble([spec], style, job, report);
      report(PdfPhase.save, 1, 1);
      await _toGallery(job, built, id: 'pdf-praman-${p.id}', title: p.title, text: p.description, topic: p.topicTitle, granth: p.granthTitle);
      if (p.granthId.isNotEmpty) CatalogStore.I.markOffline([p.granthId]);
      return built;
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
    case PdfPhase.waiting:
      return 'शुरू हो रहा है';
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
  final first =
      (e.phase == PdfPhase.pages || e.phase == PdfPhase.done) ? '${e.phase == PdfPhase.done ? e.total : e.done}/${e.total} पृष्ठ' : (e.phase == PdfPhase.images ? '${e.done}/${e.total} चित्र' : '');
  return [first, '$took लगे', etaText(e.etaMs, e.phase)].where((s) => s.isNotEmpty).join(' · ');
}

String phaseText(PdfJob m) {
  if (m.error != null) return m.error!;
  final p = switch (m.phase) {
    PdfPhase.images => 'चित्र बन रहे हैं',
    PdfPhase.pages => 'पृष्ठ जुड़ रहे हैं',
    PdfPhase.save => 'सेव हो रहा है',
    PdfPhase.done => 'तैयार',
    _ => 'शुरू हो रहा है',
  };
  return '${m.percent}% · $p';
}
