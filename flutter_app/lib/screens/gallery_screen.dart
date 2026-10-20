import 'dart:io';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/file_actions.dart';
import '../services/gallery_service.dart';
import '../services/search.dart';
import '../services/storage.dart';
import '../state/toast.dart';
import '../state/ui_prefs.dart';
import '../theme/colors.dart';
import '../widgets/common.dart';
import '../widgets/overlays.dart';
import '../widgets/panel.dart';

/// `qh` — Gallery: saved pictures and PDFs, with folders.
class GalleryPanel extends StatefulWidget {
  const GalleryPanel({super.key});
  @override
  State<GalleryPanel> createState() => _GalleryPanelState();
}

class _GalleryPanelState extends State<GalleryPanel> {
  List<GalleryItem> _items = [];
  List<GalleryFolder> _folders = [];
  String _folder = '';
  String _q = '';
  GalleryKind _tab = GalleryKind.pdf;

  @override
  void initState() {
    super.initState();
    GalleryService.I.addListener(_reload);
    _reload();
  }

  @override
  void dispose() {
    GalleryService.I.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final r = await Future.wait([GalleryService.I.items(), GalleryService.I.folders()]);
    if (!mounted) return;
    setState(() {
      _items = r[0] as List<GalleryItem>;
      _folders = r[1] as List<GalleryFolder>;
    });
  }

  Future<void> _newFolder() async {
    final name = await promptPop(context, 'फोल्डर का नाम');
    if (name == null || name.trim().isEmpty) return;
    await GalleryService.I.putFolder(GalleryFolder(id: 'f-${DateTime.now().millisecondsSinceEpoch}', name: name.trim()));
  }

  Future<void> _rename() async {
    final f = _folders.where((e) => e.id == _folder).firstOrNull;
    if (f == null) return;
    final name = await promptPop(context, 'नया नाम', initial: f.name);
    if (name == null || name.trim().isEmpty) return;
    await GalleryService.I.putFolder(GalleryFolder(id: f.id, name: name.trim()));
  }

  Future<void> _removeFolder() async {
    final id = _folder;
    await GalleryService.I.removeFolder(id);
    if (mounted) setState(() => _folder = '');
  }

  Future<void> _delete(GalleryItem e) async {
    if (e.kind == GalleryKind.pdf) {
      final t = e.fileName.isNotEmpty ? e.fileName : e.title;
      if (!await confirmPop(context, 'क्या आप यह PDF हटाना चाहते हैं?\n$t')) return;
    }
    await GalleryService.I.remove(e.id);
    Toast.show('हटा दिया');
  }

  void _view(GalleryItem d) {
    Navigator.of(context).push(PageRouteBuilder<void>(
      opaque: false,
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, a, b) => _GalleryViewer(item: d),
      transitionsBuilder: (ctx, a, b, child) => FadeTransition(opacity: a, child: child),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final cols = UiPrefs.I.cols(Store.kGalleryCols, allowed: const [1, 2], fallback: 2);
    final rows = searchFields(
      _items.where((e) => (_folder.isEmpty || e.folderId == _folder) && e.kind == _tab).toList(),
      _q,
      (e) => [e.title, e.topic, e.granth, e.fileName],
    );
    final dx = panelDx();
    Widget tab(String label, GalleryKind k) => Pressable(
          onTap: () => setState(() => _tab = k),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: _tab == k ? GColors.maroon : GColors.paper,
              border: Border.all(color: _tab == k ? GColors.maroon : GColors.creamDark),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(label, style: GText.sans(size: 16, weight: FontWeight.w700, color: _tab == k ? GColors.paper : GColors.maroon)),
          ),
        );
    return SliverMainAxisGroup(slivers: [
      SliverToBoxAdapter(
        child: Entry(
          index: 0,
          dx: dx,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 18),
            child: PageHeader(
              tone: Tone.gold,
              icon: 'images',
              title: 'Gallery',
              subtitle: 'सेव चित्र और PDF',
              tools: Tools(
                grid: GridSwitch(options: const [1, 2], value: cols, onChanged: (v) => UiPrefs.I.setCols(Store.kGalleryCols, v)),
                search: SearchField(placeholder: 'गैलरी खोजें — mans, गीता', onChanged: (v) => setState(() => _q = v)),
              ),
            ),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Entry(
          index: 1,
          dx: dx,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Row(children: [tab('PDF', GalleryKind.pdf), const SizedBox(width: 8), tab('चित्र', GalleryKind.image)]),
          ),
        ),
      ),
      SliverToBoxAdapter(
        child: Entry(
          index: 2,
          dx: dx,
          child: Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Wrap(spacing: 8, runSpacing: 8, children: [
              Pill(label: 'सभी', tone: _folder.isEmpty ? PillTone.maroon : PillTone.plain, onTap: () => setState(() => _folder = '')),
              for (final f in _folders) Pill(label: f.name, tone: _folder == f.id ? PillTone.maroon : PillTone.plain, onTap: () => setState(() => _folder = f.id)),
              Pill(icon: 'folder-plus', label: 'फोल्डर', onTap: _newFolder),
              if (_folder.isNotEmpty) Pill(label: 'नाम बदलें', onTap: _rename),
              if (_folder.isNotEmpty) Pill(label: 'फोल्डर हटाएँ', onTap: _removeFolder),
            ]),
          ),
        ),
      ),
      gridSliver(
        count: rows.length,
        cols: cols,
        gap: 14,
        item: (context, i) => Entry(index: i + 3, dx: dx, child: _card(rows[i])),
      ),
      if (rows.isEmpty) const SliverToBoxAdapter(child: EmptyState(title: 'अभी खाली है', body: 'किसी चित्र के ↓ या कार्ड के PDF बटन से यहाँ सेव होगा।')),
    ]);
  }

  Widget _card(GalleryItem e) {
    final pdf = e.kind == GalleryKind.pdf;
    Widget media;
    if (!pdf) {
      media = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(File(e.filePath), width: double.infinity, fit: BoxFit.fitWidth, cacheWidth: 900, errorBuilder: (_, _, _) => const Skeleton()),
      );
    } else if (e.previewPath != null && File(e.previewPath!).existsSync()) {
      media = ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Container(
          color: GColors.paper,
          height: 180,
          width: double.infinity,
          child: Image.file(File(e.previewPath!), fit: BoxFit.cover, alignment: Alignment.topCenter),
        ),
      );
    } else {
      media = Container(
        constraints: const BoxConstraints(minHeight: 120),
        width: double.infinity,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: GColors.maroon, borderRadius: BorderRadius.circular(8)),
        child: Text('PDF', style: GText.display(size: 28, color: GColors.goldLight)),
      );
    }
    final d = DateTime.fromMillisecondsSinceEpoch(e.createdAt);
    return GCard(
      onTap: pdf ? () => FileActions.open(e.filePath, e.fileName) : null,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: EdgeInsets.only(top: pdf && (e.previewPath == null) ? 0 : 12), child: media),
        Text(e.title, style: GText.script(size: 18, color: GColors.maroon)),
        if (!pdf) ...[
          if (e.text.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(e.text, style: GText.sans(size: 14, color: GColors.muted, height: 1.55))),
          if (e.topic.isNotEmpty) _fine(e.topic),
          if (e.granth.isNotEmpty) _fine(e.granth),
          _fine('${d.day}/${d.month}/${d.year}'),
        ],
        Container(
          margin: const EdgeInsets.only(top: 12),
          padding: const EdgeInsets.only(top: 12),
          width: double.infinity,
          decoration: const BoxDecoration(border: Border(top: BorderSide(color: GColors.creamDark))),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Pill(label: pdf ? 'PDF खोलें' : 'खोलें', onTap: () => pdf ? FileActions.open(e.filePath, e.fileName) : _view(e)),
            Pill(label: 'सेव', onTap: () async {
              final ok = await FileActions.exportToDevice(e.filePath, e.fileName);
              Toast.show(ok ? (pdf ? 'Downloads में सेव हो गया' : 'एल्बम में सेव हो गया') : 'Download failed');
            }),
            Pill(label: 'शेयर', onTap: () => FileActions.shareFile(e.filePath, e.fileName)),
            if (_folders.isNotEmpty) _FolderSelect(item: e, folders: _folders),
            Pill(icon: 'trash-2', label: 'हटाएँ', onTap: () => _delete(e)),
          ]),
        ),
      ]),
    );
  }

  Widget _fine(String t) => Padding(padding: const EdgeInsets.only(top: 6), child: Text(t, style: GText.sans(size: 12, color: GColors.muted)));
}

/// `select.folder-select`
class _FolderSelect extends StatelessWidget {
  const _FolderSelect({required this.item, required this.folders});
  final GalleryItem item;
  final List<GalleryFolder> folders;
  @override
  Widget build(BuildContext context) {
    final value = folders.any((f) => f.id == item.folderId) ? item.folderId : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.creamDark, width: 1.5), borderRadius: BorderRadius.circular(10)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          style: GText.sans(size: 12, color: GColors.text),
          dropdownColor: GColors.paper,
          items: [
            const DropdownMenuItem(value: '', child: Text('कोई फोल्डर नहीं')),
            for (final f in folders) DropdownMenuItem(value: f.id, child: Text(f.name)),
          ],
          onChanged: (v) => GalleryService.I.setFolder(item, v ?? ''),
        ),
      ),
    );
  }
}

class _GalleryViewer extends StatelessWidget {
  const _GalleryViewer({required this.item});
  final GalleryItem item;
  @override
  Widget build(BuildContext context) {
    final d = item;
    final h = (MediaQuery.sizeOf(context).height * 0.78).clamp(0.0, 920.0);
    return Material(
      color: GColors.lightbox,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Align(
              alignment: Alignment.centerRight,
              child: Pressable(
                onTap: () => Navigator.pop(context),
                child: Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(color: GColors.paper, borderRadius: BorderRadius.circular(999)),
                  child: Text('बंद', style: GText.sans(size: 16, weight: FontWeight.w700, color: GColors.maroon)),
                ),
              ),
            ),
            Expanded(
              child: ListView(children: [
                if (d.kind == GalleryKind.image)
                  SizedBox(
                    height: h,
                    child: ClipRect(
                      child: InteractiveViewer(
                        minScale: 1,
                        maxScale: 4,
                        child: Center(
                          child: ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.file(File(d.filePath), fit: BoxFit.contain)),
                        ),
                      ),
                    ),
                  ),
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(18),
                  decoration: BoxDecoration(color: GColors.paper, border: Border.all(color: GColors.creamDark), borderRadius: BorderRadius.circular(14)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(d.title, style: GText.display(size: 22, color: GColors.maroon)),
                    for (final t in [d.text, if (d.topic.isNotEmpty) 'विषय: ${d.topic}', if (d.granth.isNotEmpty) 'ग्रंथ: ${d.granth}'])
                      if (t.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(t, style: GText.sans(size: 16, height: 1.6))),
                  ]),
                ),
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}
