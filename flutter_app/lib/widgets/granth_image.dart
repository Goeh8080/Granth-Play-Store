import 'dart:io';

import 'package:flutter/material.dart';

import '../models/models.dart';
import '../services/api.dart';
import '../services/events.dart';
import '../services/file_actions.dart';
import '../services/gallery_service.dart';
import '../services/image_cache.dart';
import '../services/image_size.dart';
import '../state/toast.dart';
import '../theme/colors.dart';
import 'common.dart';

class SaveMeta {
  const SaveMeta({required this.title, this.text = '', this.topic = '', this.granth = ''});
  final String title;
  final String text;
  final String topic;
  final String granth;
}

enum ShotKind { cover, proof, thumb, lightbox }

/// `Gn` — offline-first page image with the ↓ save and 👁 view buttons.
class GranthImage extends StatefulWidget {
  const GranthImage({super.key, required this.path, this.kind = ShotKind.cover, this.onTap, this.onView, this.save, this.heroTag});
  final String? path;
  final ShotKind kind;
  final VoidCallback? onTap;
  final VoidCallback? onView;
  final SaveMeta? save;
  final Object? heroTag;

  @override
  State<GranthImage> createState() => _GranthImageState();
}

class _GranthImageState extends State<GranthImage> {
  String? _p;
  File? _file;
  bool _failed = false;
  double? _ratio;
  final GlobalKey _imgKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant GranthImage old) {
    super.didUpdateWidget(old);
    if (old.path != widget.path) _load();
  }

  bool get _wantsRatio => widget.kind == ShotKind.cover || widget.kind == ShotKind.proof;

  /// First time this picture is shown without a readable header: remember its shape once
  /// it is on screen, so the next time its row has the right height from the start.
  void _learn() {
    final f = _file;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || f == null || _file != f) return;
      final sz = _imgKey.currentContext?.size;
      if (sz != null && sz.height > 1 && sz.width > 1) ImageSizes.I.learn(f, sz.width / sz.height);
    });
  }

  void _load() {
    _p = mediaPath(widget.path);
    _failed = false;
    final p = _p;
    if (p == null) {
      _file = null;
      return;
    }
    _file = ImageStore.I.cachedSync(p);
    if (_file != null) {
      _ratio = _wantsRatio ? ImageSizes.I.ratioOf(_file!) : null;
      return;
    }
    ImageStore.I.get(p).then((f) {
      if (!mounted || _p != p) return;
      setState(() {
        _file = f;
        _failed = f == null;
        _ratio = f != null && _wantsRatio ? ImageSizes.I.ratioOf(f) : null;
      });
    });
  }

  Future<void> _saveImage() async {
    final p = _p;
    final meta = widget.save;
    if (p == null || meta == null) return;
    try {
      final f = await ImageStore.I.get(p);
      if (f == null) throw StateError('image');
      final bytes = await f.readAsBytes();
      final name = p.split('/').last.isEmpty ? 'image.jpg' : p.split('/').last;
      await GalleryService.I.put(
        id: 'img-$p',
        kind: GalleryKind.image,
        title: meta.title,
        text: meta.text,
        topic: meta.topic,
        granth: meta.granth,
        fileName: name,
        bytes: bytes,
      );
      await FileActions.exportToDevice(f.path, name);
      EventLog.I.log('praman_download', p);
      Toast.show('एल्बम और ऐप गैलरी में सेव हो गया');
    } catch (_) {
      Toast.show('Download failed');
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_p == null) return const SizedBox.shrink();
    final thumb = widget.kind == ShotKind.thumb;
    final radius = thumb ? 6.0 : (widget.kind == ShotKind.lightbox ? 12.0 : 8.0);
    Widget img;
    if (_file == null) {
      img = thumb ? Skeleton(height: 52, width: 52, radius: radius) : Skeleton(radius: radius);
      if (_failed) img = Skeleton(height: thumb ? 52 : 120, width: thumb ? 52 : null, radius: radius);
    } else {
      img = Image.file(
        _file!,
        width: thumb ? 52 : double.infinity,
        height: thumb ? 52 : null,
        fit: thumb ? BoxFit.cover : (widget.kind == ShotKind.lightbox ? BoxFit.contain : BoxFit.fitWidth),
        gaplessPlayback: true,
        cacheWidth: thumb ? 156 : (widget.kind == ShotKind.lightbox ? null : 1080),
        frameBuilder: (context, child, frame, sync) {
          if (frame != null && _ratio == null && _wantsRatio) _learn();
          return sync
            ? child
            : AnimatedOpacity(opacity: frame == null ? 0 : 1, duration: const Duration(milliseconds: 320), curve: Curves.easeOutCubic, child: child);
        },
        errorBuilder: (context, error, stack) => Skeleton(height: thumb ? 52 : 120, width: thumb ? 52 : null, radius: radius),
      );
      if (_ratio != null) {
        // Final height known before the picture is decoded: the list never changes height
        // while pictures load, so a saved scroll position is always reachable.
        img = AspectRatio(aspectRatio: _ratio!, child: img);
      } else if (_wantsRatio) {
        img = KeyedSubtree(key: _imgKey, child: img);
      }
      if (widget.heroTag != null) img = Hero(tag: widget.heroTag!, child: img);
    }
    final decorated = Container(
      decoration: BoxDecoration(
        color: widget.kind == ShotKind.lightbox ? GColors.paper : (thumb ? GColors.cream : GColors.creamDark),
        border: widget.kind == ShotKind.lightbox ? null : Border.all(color: GColors.creamDark),
        borderRadius: BorderRadius.circular(radius),
      ),
      clipBehavior: Clip.antiAlias,
      child: img,
    );
    final tapTarget = widget.onTap == null ? decorated : Pressable(onTap: widget.onTap, scale: 0.98, child: decorated);
    final showButtons = _file != null;
    return Padding(
      padding: EdgeInsets.only(top: widget.kind == ShotKind.cover || widget.kind == ShotKind.proof ? 12 : 0),
      child: Stack(
        children: [
          tapTarget,
          if (showButtons && widget.onView != null)
            Positioned(right: 8, bottom: 56, child: _RoundBtn(size: 40, onTap: widget.onView!, child: const GIcon('eye', size: 20, color: GColors.paper))),
          if (showButtons && widget.save != null)
            Positioned(
              right: thumb ? 2 : 8,
              bottom: thumb ? 2 : 8,
              child: _RoundBtn(
                size: thumb ? 22 : 40,
                onTap: _saveImage,
                child: Text('↓', style: GText.sans(size: thumb ? 12 : 16, weight: FontWeight.w700, color: GColors.paper, height: 1)),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoundBtn extends StatelessWidget {
  const _RoundBtn({required this.size, required this.onTap, required this.child});
  final double size;
  final VoidCallback onTap;
  final Widget child;
  @override
  Widget build(BuildContext context) => Pressable(
        onTap: onTap,
        scale: 0.85,
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: GColors.brown.withValues(alpha: 0.46), shape: BoxShape.circle),
          child: child,
        ),
      );
}
